// Cloud video-generation adapters: OpenAI (Sora), Google (Veo via the Gemini API), Runway.
import type { Provider } from '@/types';
import { ZinoError } from '@/services/errors';
import { authFor, trimSlash } from '../types';
import { request, requestJson } from '../http';
import { openaiAdapter } from '../chat/openai';
import { geminiAdapter } from '../chat/gemini';
import { poll, staticModels, type VideoModelOptions, type VideoProviderAdapter, type VideoResult } from '../media';

// --- OpenAI Sora -------------------------------------------------------------------------------

export const openaiVideo: VideoProviderAdapter = {
  testConnection: (p) => openaiAdapter.testConnection(p),
  listModels: async (p) => (await openaiAdapter.listModels(p)).filter((m) => m.capabilities.includes('video_generation')),
  options(model): VideoModelOptions {
    const pro = /pro/i.test(model.modelId);
    return {
      modes: ['text', 'image'], durations: [4, 8, 12],
      sizes: pro ? ['1280x720', '720x1280', '1792x1024', '1024x1792'] : ['1280x720', '720x1280'],
      supportsNegativePrompt: false, notes: ['Image-to-video uses your image as the first frame; it is resized to the chosen size.'],
    };
  },
  async generate(p, req): Promise<VideoResult> {
    const base = trimSlash(p.baseUrl);
    const auth = authFor(p);
    let id = req.resumeExternalId;
    if (!id) {
      const parts: { name: string; value?: string; filename?: string; contentType?: string; base64?: string }[] = [
        { name: 'model', value: req.model }, { name: 'prompt', value: req.prompt },
      ];
      if (req.durationSec) parts.push({ name: 'seconds', value: String(req.durationSec) });
      if (req.size) parts.push({ name: 'size', value: req.size });
      if (req.mode === 'image' && req.reference) parts.push({ name: 'input_reference', filename: 'reference', contentType: req.reference.mime, base64: req.reference.base64 });
      const r = await request({ url: `${base}/videos`, method: 'POST', multipart: parts, auth, signal: req.signal, provider: p.name });
      id = JSON.parse(r.body ?? '{}').id as string;
      if (!id) throw new ZinoError('GENERATION_FAILED', 'OpenAI did not return a video job id.');
    }
    req.onProgress?.({ progress: 0.02, label: 'Queued', externalId: id });
    await poll(async () => {
      const v = await requestJson<any>({ url: `${base}/videos/${id}`, auth, signal: req.signal, provider: p.name });
      req.onProgress?.({ progress: 0.02 + ((v.progress ?? 0) / 100) * 0.9, label: v.status === 'queued' ? 'Queued' : 'Rendering' });
      if (v.status === 'completed') return v;
      if (v.status === 'failed') throw new ZinoError('GENERATION_FAILED', `Video generation failed: ${v.error?.message ?? 'no details'}`);
      return null;
    }, { signal: req.signal, intervalMs: 8000 });
    const appPath = `${req.outputBase}.mp4`;
    req.onProgress?.({ progress: 0.95, label: 'Downloading video' });
    await request({ url: `${base}/videos/${id}/content`, auth, responseType: 'file', saveTo: appPath, signal: req.signal, provider: p.name, timeoutSeconds: 900 });
    const [w, h] = (req.size ?? '').split('x').map(Number);
    return { appPath, mime: 'video/mp4', durationSec: req.durationSec, width: w || undefined, height: h || undefined };
  },
};

// --- Google Veo --------------------------------------------------------------------------------

export const geminiVideo: VideoProviderAdapter = {
  testConnection: (p) => geminiAdapter.testConnection(p),
  listModels: async (p) => (await geminiAdapter.listModels(p)).filter((m) => m.capabilities.includes('video_generation')),
  options(): VideoModelOptions {
    return { modes: ['text', 'image'], durations: [4, 6, 8], aspectRatios: ['16:9', '9:16'], resolutions: ['720p', '1080p'], supportsNegativePrompt: true,
      notes: ['Supported durations and resolutions vary by Veo version; the provider rejects unsupported combinations.'] };
  },
  async generate(p, req): Promise<VideoResult> {
    const base = trimSlash(p.baseUrl);
    const auth = authFor(p);
    let name = req.resumeExternalId;
    if (!name) {
      const instance: Record<string, unknown> = { prompt: req.prompt };
      if (req.mode === 'image' && req.reference) instance.image = { bytesBase64Encoded: req.reference.base64, mimeType: req.reference.mime };
      const parameters: Record<string, unknown> = {};
      if (req.aspectRatio) parameters.aspectRatio = req.aspectRatio;
      if (req.resolution) parameters.resolution = req.resolution;
      if (req.durationSec) parameters.durationSeconds = req.durationSec;
      if (req.negativePrompt) parameters.negativePrompt = req.negativePrompt;
      const op = await requestJson<{ name: string }>({
        url: `${base}/models/${encodeURIComponent(req.model)}:predictLongRunning`, auth, signal: req.signal, provider: p.name,
        json: { instances: [instance], parameters },
      });
      name = op.name;
      if (!name) throw new ZinoError('GENERATION_FAILED', 'Google did not return an operation id.');
    }
    req.onProgress?.({ progress: 0.05, label: 'Rendering', externalId: name });
    let tick = 0;
    const done = await poll(async () => {
      const op = await requestJson<any>({ url: `${base}/${name}`, auth, signal: req.signal, provider: p.name });
      tick++;
      req.onProgress?.({ progress: Math.min(0.9, 0.05 + tick * 0.04), label: 'Rendering (Google does not report progress)' });
      if (op.error) throw new ZinoError('GENERATION_FAILED', `Veo: ${op.error.message ?? 'failed'}`);
      return op.done ? op : null;
    }, { signal: req.signal, intervalMs: 10_000 });
    const sample = done.response?.generateVideoResponse?.generatedSamples?.[0];
    const uri: string | undefined = sample?.video?.uri;
    if (!uri) {
      const filtered = done.response?.generateVideoResponse?.raiMediaFilteredReasons?.[0];
      throw new ZinoError(filtered ? 'PROVIDER_REFUSED' : 'GENERATION_FAILED', filtered ? `Veo filtered the result: ${filtered}` : 'Veo returned no video.');
    }
    const appPath = `${req.outputBase}.mp4`;
    req.onProgress?.({ progress: 0.95, label: 'Downloading video' });
    await request({ url: uri, auth, responseType: 'file', saveTo: appPath, signal: req.signal, provider: p.name, timeoutSeconds: 900 });
    return { appPath, mime: 'video/mp4', durationSec: req.durationSec };
  },
};

// --- Runway ------------------------------------------------------------------------------------

const RUNWAY_HEADERS = { 'X-Runway-Version': '2024-11-06' };

export const runwayVideo: VideoProviderAdapter = {
  async testConnection(p) {
    const r = await requestJson<{ creditBalance?: number }>({ url: `${trimSlash(p.baseUrl)}/organization`, auth: authFor(p), headers: RUNWAY_HEADERS, provider: p.name });
    return { ok: true, message: `Connected${typeof r.creditBalance === 'number' ? ` · ${r.creditBalance} credits` : ''}.` };
  },
  async listModels(p) {
    return staticModels(p, [
      { id: 'gen4_turbo', name: 'Gen-4 Turbo (image → video)', caps: ['video_generation'] },
      { id: 'gen3a_turbo', name: 'Gen-3 Alpha Turbo (image → video)', caps: ['video_generation'] },
    ]);
  },
  options(model): VideoModelOptions {
    const ratios = model.modelId === 'gen3a_turbo' ? ['1280:768', '768:1280'] : ['1280:720', '720:1280', '1104:832', '832:1104', '960:960', '1584:672'];
    return { modes: ['image'], durations: [5, 10], sizes: ratios, supportsNegativePrompt: false,
      notes: ['These Runway models animate a starting image; text-only generation is not offered here.'] };
  },
  async generate(p, req): Promise<VideoResult> {
    const base = trimSlash(p.baseUrl);
    const auth = authFor(p);
    let id = req.resumeExternalId;
    if (!id) {
      if (!req.reference) throw new ZinoError('INVALID_ARGUMENT', 'Runway needs a starting image.');
      const created = await requestJson<{ id: string }>({
        url: `${base}/image_to_video`, auth, headers: RUNWAY_HEADERS, signal: req.signal, provider: p.name,
        json: { model: req.model, promptImage: `data:${req.reference.mime};base64,${req.reference.base64}`, promptText: req.prompt || undefined,
          ratio: req.size, duration: req.durationSec ?? 5 },
      });
      id = created.id;
    }
    req.onProgress?.({ progress: 0.02, label: 'Queued', externalId: id });
    const done = await poll(async () => {
      const t = await requestJson<any>({ url: `${base}/tasks/${id}`, auth, headers: RUNWAY_HEADERS, signal: req.signal, provider: p.name });
      req.onProgress?.({ progress: 0.02 + (t.progress ?? 0) * 0.9, label: t.status === 'RUNNING' ? 'Rendering' : 'Queued' });
      if (t.status === 'SUCCEEDED') return t;
      if (t.status === 'FAILED' || t.status === 'CANCELLED') throw new ZinoError('GENERATION_FAILED', `Runway task ${t.status.toLowerCase()}: ${t.failure ?? ''}`);
      return null;
    }, { signal: req.signal, intervalMs: 6000 });
    const url = done.output?.[0];
    if (!url) throw new ZinoError('GENERATION_FAILED', 'Runway returned no video.');
    const appPath = `${req.outputBase}.mp4`;
    await request({ url, responseType: 'file', saveTo: appPath, signal: req.signal, provider: p.name, timeoutSeconds: 900 });
    return { appPath, mime: 'video/mp4', durationSec: req.durationSec };
  },
};

export function videoAdapterFor(p: Provider): VideoProviderAdapter {
  switch (p.kind) {
    case 'openai': return openaiVideo;
    case 'gemini': return geminiVideo;
    case 'runway': return runwayVideo;
    default: throw new ZinoError('UNSUPPORTED_PROVIDER', `${p.name} does not offer video generation in ZinoAgent.`);
  }
}
