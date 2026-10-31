// Cloud 3D-generation adapters: Meshy, Tripo, Stability (Stable Fast 3D).
// All produce GLB files saved into app storage; the original output is never modified later.
import type { Provider, ProviderModel } from '@/types';
import { ZinoError } from '@/services/errors';
import { authFor, trimSlash } from '../types';
import { request, requestJson } from '../http';
import { poll, staticModels, type ThreeDModelOptions, type ThreeDProviderAdapter, type ThreeDResult } from '../media';
import { stabilityTest } from '../image';

const caps = (...c: ProviderModel['capabilities']) => c;

async function download(url: string, saveTo: string, p: Provider, signal?: AbortSignal, withAuth = false) {
  await request({ url, responseType: 'file', saveTo, signal, provider: p.name, timeoutSeconds: 900, auth: withAuth ? authFor(p) : undefined });
}

// --- Meshy -------------------------------------------------------------------------------------

const MESHY_STATUS_DONE = 'SUCCEEDED';
const MESHY_FAILED = ['FAILED', 'CANCELED', 'EXPIRED'];

export const meshy3D: ThreeDProviderAdapter = {
  async testConnection(p) {
    const r = await requestJson<{ balance?: number }>({ url: `${trimSlash(p.baseUrl)}/openapi/v1/balance`, auth: authFor(p), provider: p.name });
    return { ok: true, message: `Connected${typeof r.balance === 'number' ? ` · ${r.balance} credits` : ''}.` };
  },
  async listModels(p) {
    return staticModels(p, [
      { id: 'latest', name: 'Meshy (latest model)', caps: caps('threed_generation') },
      { id: 'meshy-5', name: 'Meshy-5', caps: caps('threed_generation') },
      { id: 'meshy-4', name: 'Meshy-4', caps: caps('threed_generation') },
    ]);
  },
  options(): ThreeDModelOptions {
    return { modes: ['text', 'image'], topologies: ['triangle', 'quad'], polycount: { min: 100, max: 300_000, default: 30_000 },
      supportsTexture: true, supportsPBR: true, outputFormats: ['glb'],
      notes: ['Text-to-3D runs a preview (geometry) stage, then a texture "refine" stage when texturing is on.'] };
  },
  async generate(p, req): Promise<ThreeDResult> {
    const base = trimSlash(p.baseUrl);
    const auth = authFor(p);
    const waitFor = (path: string, from: number, to: number, label: string) =>
      poll(async () => {
        const t = await requestJson<any>({ url: `${base}${path}`, auth, signal: req.signal, provider: p.name });
        req.onProgress?.({ progress: from + ((t.progress ?? 0) / 100) * (to - from), label });
        if (t.status === MESHY_STATUS_DONE) return t;
        if (MESHY_FAILED.includes(t.status)) throw new ZinoError('GENERATION_FAILED', `Meshy task ${t.status.toLowerCase()}: ${t.task_error?.message ?? 'no details'}`);
        return null;
      }, { signal: req.signal });

    let result: any;
    if (req.mode === 'image') {
      if (!req.reference) throw new ZinoError('INVALID_ARGUMENT', 'Choose a reference image for image-to-3D.');
      const id = req.resumeExternalId ?? (await requestJson<{ result: string }>({
        url: `${base}/openapi/v1/image-to-3d`, auth, signal: req.signal, provider: p.name,
        json: {
          image_url: `data:${req.reference.mime};base64,${req.reference.base64}`, ai_model: req.model,
          topology: req.topology ?? 'triangle', target_polycount: req.targetPolycount, should_texture: req.texture, enable_pbr: req.pbr && req.texture,
        },
      })).result;
      req.onProgress?.({ progress: 0.02, label: 'Queued at Meshy', externalId: id });
      result = await waitFor(`/openapi/v1/image-to-3d/${id}`, 0.02, 0.95, 'Generating');
    } else {
      const previewId = req.resumeExternalId ?? (await requestJson<{ result: string }>({
        url: `${base}/openapi/v2/text-to-3d`, auth, signal: req.signal, provider: p.name,
        json: { mode: 'preview', prompt: req.prompt, ai_model: req.model, topology: req.topology ?? 'triangle', target_polycount: req.targetPolycount },
      })).result;
      req.onProgress?.({ progress: 0.02, label: 'Generating geometry', externalId: previewId });
      result = await waitFor(`/openapi/v2/text-to-3d/${previewId}`, 0.02, req.texture ? 0.5 : 0.95, 'Generating geometry');
      if (req.texture) {
        const refineId = (await requestJson<{ result: string }>({
          url: `${base}/openapi/v2/text-to-3d`, auth, signal: req.signal, provider: p.name,
          json: { mode: 'refine', preview_task_id: previewId, enable_pbr: req.pbr },
        })).result;
        result = await waitFor(`/openapi/v2/text-to-3d/${refineId}`, 0.5, 0.95, 'Texturing');
      }
    }
    const glb = result?.model_urls?.glb;
    if (!glb) throw new ZinoError('GENERATION_FAILED', 'Meshy finished but returned no GLB file.');
    const appPath = `${req.outputBase}.glb`;
    req.onProgress?.({ progress: 0.97, label: 'Downloading model' });
    await download(glb, appPath, p, req.signal);
    return { appPath, format: 'glb' };
  },
};

// --- Tripo -------------------------------------------------------------------------------------

export const tripo3D: ThreeDProviderAdapter = {
  async testConnection(p) {
    const r = await requestJson<{ code: number; data?: { balance?: number } }>({ url: `${trimSlash(p.baseUrl)}/user/balance`, auth: authFor(p), provider: p.name });
    if (r.code !== 0) throw new ZinoError('PROVIDER_REJECTED', `Tripo returned code ${r.code}.`);
    return { ok: true, message: `Connected${r.data?.balance !== undefined ? ` · balance ${r.data.balance}` : ''}.` };
  },
  async listModels(p) {
    return staticModels(p, [{ id: 'default', name: 'Tripo (account default model version)', caps: caps('threed_generation') }]);
  },
  options(): ThreeDModelOptions {
    return { modes: ['text', 'image'], polycount: { min: 1000, max: 200_000, default: 0 }, supportsTexture: true, supportsPBR: true,
      geometryQualities: ['standard', 'detailed'], outputFormats: ['glb'],
      notes: ['Polycount 0 lets Tripo choose. "detailed" texture quality costs more credits.'] };
  },
  async generate(p, req) {
    const base = trimSlash(p.baseUrl);
    const auth = authFor(p);
    let taskId = req.resumeExternalId;
    if (!taskId) {
      const body: Record<string, unknown> = { texture: req.texture, pbr: req.pbr && req.texture };
      if (req.model !== 'default') body.model_version = req.model;
      if (req.targetPolycount) body.face_limit = req.targetPolycount;
      if (req.geometryQuality) body.texture_quality = req.geometryQuality;
      if (req.mode === 'image') {
        if (!req.reference) throw new ZinoError('INVALID_ARGUMENT', 'Choose a reference image for image-to-3D.');
        const ext = req.reference.mime.includes('png') ? 'png' : 'jpg';
        const up = await request({
          url: `${base}/upload`, method: 'POST', auth, signal: req.signal, provider: p.name,
          multipart: [{ name: 'file', filename: `reference.${ext}`, contentType: req.reference.mime, base64: req.reference.base64 }],
        });
        const token = JSON.parse(up.body ?? '{}')?.data?.image_token;
        if (!token) throw new ZinoError('GENERATION_FAILED', 'Tripo did not accept the reference image.');
        Object.assign(body, { type: 'image_to_model', file: { type: ext, file_token: token } });
      } else {
        Object.assign(body, { type: 'text_to_model', prompt: req.prompt });
      }
      const created = await requestJson<{ code: number; data?: { task_id: string }; message?: string }>({ url: `${base}/task`, json: body, auth, signal: req.signal, provider: p.name });
      if (created.code !== 0 || !created.data?.task_id) throw new ZinoError('PROVIDER_REJECTED', `Tripo: ${created.message ?? `code ${created.code}`}`);
      taskId = created.data.task_id;
    }
    req.onProgress?.({ progress: 0.02, label: 'Queued at Tripo', externalId: taskId });
    const done = await poll(async () => {
      const r = await requestJson<any>({ url: `${base}/task/${taskId}`, auth, signal: req.signal, provider: p.name });
      const d = r.data ?? {};
      req.onProgress?.({ progress: 0.02 + ((d.progress ?? 0) / 100) * 0.93, label: d.status === 'queued' ? 'Queued' : 'Generating' });
      if (d.status === 'success') return d;
      if (['failed', 'cancelled', 'banned', 'expired', 'unknown'].includes(d.status)) throw new ZinoError('GENERATION_FAILED', `Tripo task ${d.status}.`);
      return null;
    }, { signal: req.signal });
    const url = done.output?.pbr_model ?? done.output?.model ?? done.output?.base_model;
    if (!url) throw new ZinoError('GENERATION_FAILED', 'Tripo finished but returned no model file.');
    const appPath = `${req.outputBase}.glb`;
    req.onProgress?.({ progress: 0.97, label: 'Downloading model' });
    await download(url, appPath, p, req.signal);
    return { appPath, format: 'glb' };
  },
};

// --- Stability: Stable Fast 3D ---------------------------------------------------------------

export const stability3D: ThreeDProviderAdapter = {
  testConnection: stabilityTest,
  async listModels(p) {
    return staticModels(p, [{ id: 'stable-fast-3d', name: 'Stable Fast 3D (image → 3D)', caps: caps('threed_generation') }]);
  },
  options(): ThreeDModelOptions {
    return { modes: ['image'], topologies: ['triangle', 'quad'], polycount: { min: 100, max: 20_000, default: -1 }, textureResolutions: [512, 1024, 2048],
      supportsTexture: true, supportsPBR: false, outputFormats: ['glb'], notes: ['Image-to-3D only. Returns a textured GLB in one request.'] };
  },
  async generate(p, req) {
    if (req.mode !== 'image' || !req.reference) throw new ZinoError('INVALID_ARGUMENT', 'Stable Fast 3D needs a reference image.');
    const parts = [
      { name: 'image', filename: 'reference.png', contentType: req.reference.mime, base64: req.reference.base64 },
      { name: 'texture_resolution', value: String(req.textureResolution ?? 1024) },
      { name: 'remesh', value: req.topology === 'quad' ? 'quad' : req.topology === 'triangle' ? 'triangle' : 'none' },
    ];
    if (req.targetPolycount && req.targetPolycount > 0) parts.push({ name: 'vertex_count', value: String(req.targetPolycount) });
    req.onProgress?.({ progress: 0.1, label: 'Generating (single request)' });
    const appPath = `${req.outputBase}.glb`;
    await request({ url: `${trimSlash(p.baseUrl)}/v2beta/3d/stable-fast-3d`, method: 'POST', multipart: parts, auth: authFor(p),
      responseType: 'file', saveTo: appPath, signal: req.signal, provider: p.name, timeoutSeconds: 600 });
    return { appPath, format: 'glb' };
  },
};

export function threeDAdapterFor(p: Provider): ThreeDProviderAdapter {
  switch (p.kind) {
    case 'meshy': return meshy3D;
    case 'tripo': return tripo3D;
    case 'stability': return stability3D;
    default: throw new ZinoError('UNSUPPORTED_PROVIDER', `${p.name} does not offer 3D generation in ZinoAgent.`);
  }
}
