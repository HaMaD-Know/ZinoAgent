// Cloud image-generation adapters: OpenAI Images, Gemini (native image models + Imagen),
// Stability AI, and OpenAI-compatible /images endpoints.
import type { Provider, ProviderModel } from '@/types';
import { ZinoError } from '@/services/errors';
import { authFor, trimSlash } from '../types';
import { request, requestJson } from '../http';
import { openaiAdapter } from '../chat/openai';
import { geminiAdapter } from '../chat/gemini';
import { staticModels, type ImageModelOptions, type ImageProviderAdapter, type ImageRequest, type ImageResult } from '../media';

const onlyImageModels = (models: ProviderModel[]) => models.filter((m) => m.capabilities.includes('image_generation'));

// --- OpenAI ------------------------------------------------------------------------------------

function openaiImageOptions(model: ProviderModel): ImageModelOptions {
  const id = model.modelId.toLowerCase();
  if (id.startsWith('dall-e-3')) {
    return { modes: ['text'], sizes: ['1024x1024', '1792x1024', '1024x1792'], qualities: ['standard', 'hd'], supportsSeed: false, supportsNegativePrompt: false, maxCount: 1 };
  }
  if (id.startsWith('dall-e-2')) {
    return { modes: ['text'], sizes: ['256x256', '512x512', '1024x1024'], supportsSeed: false, supportsNegativePrompt: false, maxCount: 4 };
  }
  return {
    modes: ['text', 'edit'], sizes: ['auto', '1024x1024', '1536x1024', '1024x1536'], qualities: ['auto', 'low', 'medium', 'high'],
    supportsSeed: false, supportsNegativePrompt: false, maxCount: 4,
    notes: ['Edit mode sends your reference image to OpenAI.'],
  };
}

export const openaiImages: ImageProviderAdapter = {
  testConnection: (p) => openaiAdapter.testConnection(p),
  listModels: async (p) => onlyImageModels(await openaiAdapter.listModels(p)),
  options: openaiImageOptions,
  async generate(p: Provider, req: ImageRequest): Promise<ImageResult> {
    const base = trimSlash(p.baseUrl);
    const id = req.model.toLowerCase();
    const isGptImage = !id.startsWith('dall-e');
    let res: { data?: { b64_json?: string; revised_prompt?: string }[] };
    if (req.mode === 'edit') {
      if (!req.reference) throw new ZinoError('INVALID_ARGUMENT', 'Choose a reference image to edit.');
      const parts = [
        { name: 'model', value: req.model },
        { name: 'prompt', value: req.prompt },
        { name: 'n', value: String(req.count ?? 1) },
        { name: 'image[]', filename: req.reference.appPath.split('/').pop() ?? 'image.png', contentType: req.reference.mime, base64: req.reference.base64 },
      ];
      if (req.size && req.size !== 'auto') parts.push({ name: 'size', value: req.size });
      if (req.quality && req.quality !== 'auto') parts.push({ name: 'quality', value: req.quality });
      const r = await request({ url: `${base}/images/edits`, method: 'POST', multipart: parts, auth: authFor(p), signal: req.signal, provider: p.name, timeoutSeconds: 600 });
      res = JSON.parse(r.body ?? '{}');
    } else {
      const body: Record<string, unknown> = { model: req.model, prompt: req.prompt, n: req.count ?? 1 };
      if (req.size && req.size !== 'auto') body.size = req.size;
      if (req.quality && req.quality !== 'auto') body.quality = req.quality;
      if (!isGptImage) body.response_format = 'b64_json';
      res = await requestJson({ url: `${base}/images/generations`, json: body, auth: authFor(p), signal: req.signal, provider: p.name, timeoutSeconds: 600 });
    }
    const images = (res.data ?? []).filter((d) => d.b64_json).map((d) => ({ base64: d.b64_json!, mime: 'image/png' }));
    if (!images.length) throw new ZinoError('GENERATION_FAILED', `${p.name} returned no image.`);
    return { images, revisedPrompt: res.data?.[0]?.revised_prompt };
  },
};

// --- Gemini / Imagen ---------------------------------------------------------------------------

const GEMINI_ASPECTS = ['1:1', '2:3', '3:2', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9', '21:9'];
const IMAGEN_ASPECTS = ['1:1', '3:4', '4:3', '9:16', '16:9'];

export const geminiImages: ImageProviderAdapter = {
  testConnection: (p) => geminiAdapter.testConnection(p),
  listModels: async (p) => onlyImageModels(await geminiAdapter.listModels(p)),
  options(model) {
    if (/imagen/i.test(model.modelId)) {
      return { modes: ['text'], aspectRatios: IMAGEN_ASPECTS, supportsSeed: false, supportsNegativePrompt: false, maxCount: 4 };
    }
    return { modes: ['text', 'edit'], aspectRatios: GEMINI_ASPECTS, supportsSeed: false, supportsNegativePrompt: false, maxCount: 1,
      notes: ['Edit mode sends your reference image to Google.'] };
  },
  async generate(p, req) {
    const base = trimSlash(p.baseUrl);
    if (/imagen/i.test(req.model)) {
      const res = await requestJson<{ predictions?: { bytesBase64Encoded?: string; mimeType?: string }[] }>({
        url: `${base}/models/${encodeURIComponent(req.model)}:predict`, auth: authFor(p), signal: req.signal, provider: p.name, timeoutSeconds: 600,
        json: { instances: [{ prompt: req.prompt }], parameters: { sampleCount: req.count ?? 1, ...(req.aspectRatio ? { aspectRatio: req.aspectRatio } : {}) } },
      });
      const images = (res.predictions ?? []).filter((x) => x.bytesBase64Encoded).map((x) => ({ base64: x.bytesBase64Encoded!, mime: x.mimeType ?? 'image/png' }));
      if (!images.length) throw new ZinoError('GENERATION_FAILED', `${p.name} returned no image (the prompt may have been filtered).`);
      return { images };
    }
    const parts: unknown[] = [];
    if (req.mode === 'edit' && req.reference) parts.push({ inlineData: { mimeType: req.reference.mime, data: req.reference.base64 } });
    parts.push({ text: req.prompt });
    const res = await requestJson<any>({
      url: `${base}/models/${encodeURIComponent(req.model)}:generateContent`, auth: authFor(p), signal: req.signal, provider: p.name, timeoutSeconds: 600,
      json: {
        contents: [{ role: 'user', parts }],
        generationConfig: { responseModalities: ['TEXT', 'IMAGE'], ...(req.aspectRatio ? { imageConfig: { aspectRatio: req.aspectRatio } } : {}) },
      },
    });
    const outParts: any[] = res?.candidates?.[0]?.content?.parts ?? [];
    const images = outParts.filter((x) => x.inlineData?.data).map((x) => ({ base64: x.inlineData.data, mime: x.inlineData.mimeType ?? 'image/png' }));
    const notes = outParts.filter((x) => typeof x.text === 'string').map((x) => x.text as string);
    if (!images.length) throw new ZinoError('GENERATION_FAILED', `${p.name} returned no image.${notes.length ? ' ' + notes.join(' ').slice(0, 200) : ''}`);
    return { images, notes };
  },
};

// --- Stability AI ------------------------------------------------------------------------------

const STABILITY_ASPECTS = ['1:1', '16:9', '21:9', '2:3', '3:2', '4:5', '5:4', '9:16', '9:21'];
const STABILITY_MODELS = [
  { id: 'ultra', name: 'Stable Image Ultra', caps: ['image_generation', 'image_editing'] as ProviderModel['capabilities'] },
  { id: 'core', name: 'Stable Image Core', caps: ['image_generation'] as ProviderModel['capabilities'] },
  { id: 'sd3.5-large', name: 'Stable Diffusion 3.5 Large', caps: ['image_generation', 'image_editing'] as ProviderModel['capabilities'] },
  { id: 'sd3.5-large-turbo', name: 'Stable Diffusion 3.5 Large Turbo', caps: ['image_generation', 'image_editing'] as ProviderModel['capabilities'] },
  { id: 'sd3.5-medium', name: 'Stable Diffusion 3.5 Medium', caps: ['image_generation', 'image_editing'] as ProviderModel['capabilities'] },
];

export async function stabilityTest(p: Provider) {
  const r = await requestJson<{ email?: string; id?: string }>({ url: `${trimSlash(p.baseUrl)}/v1/user/account`, auth: authFor(p), provider: p.name });
  return { ok: true, message: `Connected${r.email ? ` as ${r.email}` : ''}.` };
}

export const stabilityImages: ImageProviderAdapter = {
  testConnection: stabilityTest,
  async listModels(p) { return staticModels(p, STABILITY_MODELS); },
  options(model) {
    const img2img = model.modelId !== 'core';
    return { modes: img2img ? ['text', 'image'] : ['text'], aspectRatios: STABILITY_ASPECTS, supportsSeed: true, supportsNegativePrompt: true,
      maxCount: 1, supportsStrength: img2img, notes: ['Model list is built in (Stability does not publish a model-list endpoint).'] };
  },
  async generate(p, req) {
    const endpoint = req.model === 'ultra' || req.model === 'core' ? req.model : 'sd3';
    const parts: { name: string; value?: string; filename?: string; contentType?: string; base64?: string }[] = [
      { name: 'prompt', value: req.prompt },
      { name: 'output_format', value: 'png' },
    ];
    if (endpoint === 'sd3') parts.push({ name: 'model', value: req.model });
    if (req.negativePrompt) parts.push({ name: 'negative_prompt', value: req.negativePrompt });
    if (req.seed !== undefined) parts.push({ name: 'seed', value: String(req.seed) });
    if (req.mode === 'image' && req.reference) {
      if (endpoint === 'sd3') parts.push({ name: 'mode', value: 'image-to-image' });
      parts.push({ name: 'image', filename: 'reference', contentType: req.reference.mime, base64: req.reference.base64 });
      parts.push({ name: 'strength', value: String(req.strength ?? 0.6) });
    } else if (req.aspectRatio) {
      parts.push({ name: 'aspect_ratio', value: req.aspectRatio });
    }
    const r = await request({
      url: `${trimSlash(p.baseUrl)}/v2beta/stable-image/generate/${endpoint}`, method: 'POST', multipart: parts,
      headers: { Accept: 'application/json' }, auth: authFor(p), signal: req.signal, provider: p.name, timeoutSeconds: 600,
    });
    const j = JSON.parse(r.body ?? '{}');
    if (j.finish_reason === 'CONTENT_FILTERED') throw new ZinoError('PROVIDER_REFUSED', 'Stability AI filtered this image.', { recovery: [] });
    if (!j.image) throw new ZinoError('GENERATION_FAILED', 'Stability AI returned no image.');
    return { images: [{ base64: j.image, mime: 'image/png' }], seed: j.seed };
  },
};

// --- OpenAI-compatible ---------------------------------------------------------------------------

export const compatibleImages: ImageProviderAdapter = {
  testConnection: (p) => openaiAdapter.testConnection(p),
  async listModels(p) {
    const models = await openaiAdapter.listModels(p);
    return models.map((m) => ({ ...m, capabilities: ['image_generation'], metadata: { ...m.metadata, capabilitiesAssumed: true } }));
  },
  options: () => ({ modes: ['text'], sizes: ['512x512', '1024x1024'], supportsSeed: false, supportsNegativePrompt: false, maxCount: 1,
    notes: ['OpenAI-compatible servers vary; only the standard /images/generations request is sent.'] }),
  async generate(p, req) {
    const res = await requestJson<{ data?: { b64_json?: string }[] }>({
      url: `${trimSlash(p.baseUrl)}/images/generations`, auth: authFor(p), headers: p.options.headers, signal: req.signal, provider: p.name, timeoutSeconds: 900,
      json: { model: req.model, prompt: req.prompt, n: 1, size: req.size ?? '1024x1024', response_format: 'b64_json' },
    });
    const images = (res.data ?? []).filter((d) => d.b64_json).map((d) => ({ base64: d.b64_json!, mime: 'image/png' }));
    if (!images.length) throw new ZinoError('GENERATION_FAILED', `${p.name} returned no image.`);
    return { images };
  },
};

export function imageAdapterFor(p: Provider): ImageProviderAdapter {
  switch (p.kind) {
    case 'openai': return openaiImages;
    case 'gemini': return geminiImages;
    case 'stability': return stabilityImages;
    case 'openai_compatible': return compatibleImages;
    default: throw new ZinoError('UNSUPPORTED_PROVIDER', `${p.name} does not offer image generation in ZinoAgent.`);
  }
}
