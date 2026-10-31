// Image, 3D and video generation services built on the queue. Each request names its model
// explicitly (offline or a specific cloud provider): nothing switches providers silently.
import type { Asset, GenerationTask, ModelRef, ProviderModel } from '@/types';
import { modelsRepo, providersRepo } from '@/database/repositories';
import { ZinoDiffusion } from '@/native';
import { ZinoError } from '@/services/errors';
import { assetManager } from '@/services/asset-manager';
import { ensureImageModel } from '@/services/model-manager';
import { markUsed } from '@/services/resources';
import { imageAdapterFor } from '@/providers/image';
import { threeDAdapterFor } from '@/providers/three-d';
import { videoAdapterFor } from '@/providers/video';
import type { ImageModelOptions, ReferenceImage, ThreeDModelOptions, VideoModelOptions } from '@/providers/media';
import { LOCAL_GENERATION_ADAPTERS } from '@/models/adapters';
import { enqueue, registerRunner, type TaskRunner } from './queue';

export * from './queue';

async function reference(assetId: unknown): Promise<ReferenceImage | undefined> {
  if (typeof assetId !== 'string' || !assetId) return undefined;
  const a = await assetManager.get(assetId);
  if (!a) throw new ZinoError('FILE_NOT_FOUND', 'The reference image is no longer in the asset library.');
  return { appPath: a.path, mime: a.mime, base64: await assetManager.readBase64(a) };
}

async function cloudContext(ref: ModelRef) {
  if (ref.source !== 'cloud') throw new ZinoError('INVALID_ARGUMENT', 'Expected a cloud model.');
  const p = await providersRepo.get(ref.providerId);
  if (!p) throw new ZinoError('NOT_FOUND', 'That provider was removed.', { recovery: ['open_settings_providers'] });
  const info = (await providersRepo.models(p.id)).find((m) => m.modelId === ref.modelId);
  const model: ProviderModel = info ?? { id: `${p.id}:${ref.modelId}`, providerId: p.id, modelId: ref.modelId, displayName: ref.modelId, capabilities: [], contextLength: null, outputLimit: null, metadata: {}, fetchedAt: 0 };
  return { p, model };
}

// --- Image ---------------------------------------------------------------------------------------

export const LOCAL_IMAGE_STEPS = { minimal: 10, low: 15, medium: 25, high: 35, maximum: 50 } as const;

export async function imageOptions(ref: ModelRef | null): Promise<ImageModelOptions | null> {
  if (!ref || ref.source === 'auto') return null;
  if (ref.source === 'local') {
    const m = await modelsRepo.get(ref.modelId);
    if (!m) return null;
    const v = m.metadata.validation as { supportsImageToImage?: boolean; nativeSize?: number | null; isXL?: boolean } | undefined;
    const size = v?.nativeSize ?? (v?.isXL ? 1024 : null);
    return {
      modes: v?.supportsImageToImage ? ['text', 'image'] : ['text'], sizes: size ? [`${size}x${size}`] : undefined,
      supportsSeed: true, supportsNegativePrompt: true, maxCount: 4, supportsStrength: !!v?.supportsImageToImage,
      steps: { min: 4, max: 60, default: 25 }, guidance: { min: 1, max: 15, default: 7.5 },
      notes: [size ? `This Core ML model is compiled for ${size}×${size}; other sizes need a different model.` : 'Output size is fixed by the compiled model.'],
    };
  }
  const { p, model } = await cloudContext(ref);
  return imageAdapterFor(p).options(model);
}

const imageRunner = (task: GenerationTask): TaskRunner => async ({ signal, progress }) => {
  const prm = task.params as Record<string, any>;
  const ref = task.modelRef;
  const ids: string[] = [];
  const meta = { prompt: prm.prompt, negativePrompt: prm.negativePrompt, mode: prm.mode, model: prm.modelLabel, seed: prm.seed, settings: prm };
  if (ref.source === 'local') {
    progress(0.01, 'Loading model');
    await ensureImageModel(ref.modelId);
    const refAsset = typeof prm.referenceAssetId === 'string' ? await assetManager.get(prm.referenceAssetId) : null;
    const handle = await ZinoDiffusion.addListener('progress', (e) => {
      if (e.id === task.id) progress(0.05 + (e.step / Math.max(1, e.stepCount)) * 0.9, `Step ${e.step}/${e.stepCount}`);
    });
    const onAbort = () => { void ZinoDiffusion.cancel({ id: task.id }); };
    signal.addEventListener('abort', onAbort, { once: true });
    markUsed('diffusion', true);
    try {
      const r = await ZinoDiffusion.generate({
        id: task.id, prompt: prm.prompt, negativePrompt: prm.negativePrompt, steps: prm.steps, guidanceScale: prm.guidance,
        imageCount: prm.count ?? 1, seed: typeof prm.seed === 'number' ? prm.seed : undefined, scheduler: prm.scheduler ?? 'dpmpp',
        startingImage: prm.mode === 'image' && refAsset ? refAsset.path : undefined, strength: prm.strength, outputDir: 'assets/image',
      });
      if (r.filteredBySafetyChecker) progress(0.97, `${r.filteredBySafetyChecker} image(s) blocked by the model's safety checker`);
      for (const img of r.images) {
        const a = await assetManager.save({ kind: 'image', name: String(prm.prompt).slice(0, 60) || 'Image', mime: 'image/png', path: img.path,
          width: img.width, height: img.height, chatId: task.chatId, taskId: task.id, parentAssetId: refAsset?.id ?? null,
          metadata: { ...meta, seed: r.seed, durationMs: r.durationMs, engine: 'Core ML Stable Diffusion (on device)' } });
        ids.push(a.id);
      }
      if (!ids.length) throw new ZinoError('GENERATION_FAILED', 'All images were blocked by the model\'s safety checker.');
    } finally {
      signal.removeEventListener('abort', onAbort);
      markUsed('diffusion', false);
      await handle.remove();
    }
    return ids;
  }
  const { p } = await cloudContext(ref);
  progress(0.05, `Sending to ${p.name}`);
  const r = await imageAdapterFor(p).generate(p, {
    model: ref.source === 'cloud' ? ref.modelId : '', mode: prm.mode, prompt: prm.prompt, negativePrompt: prm.negativePrompt,
    reference: await reference(prm.referenceAssetId), size: prm.size, aspectRatio: prm.aspectRatio, quality: prm.quality,
    seed: prm.seed, count: prm.count, strength: prm.strength, signal,
  });
  progress(0.95, 'Saving');
  for (const img of r.images) {
    const a = await assetManager.save({ kind: 'image', name: String(prm.prompt).slice(0, 60) || 'Image', mime: img.mime, base64: img.base64, path: img.appPath,
      chatId: task.chatId, taskId: task.id, parentAssetId: typeof prm.referenceAssetId === 'string' ? prm.referenceAssetId : null,
      metadata: { ...meta, seed: r.seed ?? prm.seed, revisedPrompt: r.revisedPrompt, notes: r.notes, engine: p.name } });
    ids.push(a.id);
  }
  return ids;
};
registerRunner('image', imageRunner);

export function generateImage(modelRef: ModelRef, params: Record<string, unknown>, chatId?: string | null) {
  return enqueue({ kind: 'image', modelRef, params, chatId });
}

// --- 3D ------------------------------------------------------------------------------------------

export async function threeDOptions(ref: ModelRef | null): Promise<ThreeDModelOptions | null> {
  if (!ref || ref.source === 'auto') return null;
  if (ref.source === 'local') {
    return { modes: [], supportsTexture: false, supportsPBR: false, outputFormats: [],
      notes: ['No on-device 3D generation runtime is available for iPadOS in this build. Imported models are stored and inspected only.'] };
  }
  const { p, model } = await cloudContext(ref);
  return threeDAdapterFor(p).options(model);
}

const threeDRunner = (task: GenerationTask): TaskRunner => async ({ signal, progress }) => {
  const prm = task.params as Record<string, any>;
  const ref = task.modelRef;
  const outputBase = `assets/model3d/${task.id}`;
  if (ref.source === 'local') {
    const m = await modelsRepo.get(ref.modelId);
    const adapter = m && LOCAL_GENERATION_ADAPTERS.find((a) => a.category === 'threed' && m.metadata.coreml && a.matches(m.metadata.coreml as never));
    if (!m || !adapter) throw new ZinoError('UNSUPPORTED_MODEL', 'This offline 3D model cannot run on iPad in ZinoAgent (no compatible runtime). Choose a cloud 3D provider — ZinoAgent will not switch automatically.');
    const r = await adapter.generate({ modelPath: m.path, prompt: prm.prompt, outputBase, signal, onProgress: (x) => progress(x) });
    const a = await assetManager.save({ kind: 'model3d', name: String(prm.prompt || 'Model').slice(0, 60), mime: 'model/gltf-binary', path: r.appPath, chatId: task.chatId, taskId: task.id, metadata: { ...prm, engine: adapter.name } });
    return [a.id];
  }
  const { p } = await cloudContext(ref);
  const r = await threeDAdapterFor(p).generate(p, {
    model: ref.source === 'cloud' ? ref.modelId : '', mode: prm.mode, prompt: prm.prompt ?? '', reference: await reference(prm.referenceAssetId),
    topology: prm.topology, targetPolycount: prm.targetPolycount, texture: !!prm.texture, pbr: !!prm.pbr, textureResolution: prm.textureResolution,
    geometryQuality: prm.geometryQuality, outputBase, signal, resumeExternalId: prm.resumeExternalId,
    onProgress: (x) => progress(x.progress, x.label, x.externalId),
  });
  const a = await assetManager.save({ kind: 'model3d', name: String(prm.prompt || 'Image to 3D').slice(0, 60), mime: 'model/gltf-binary', path: r.appPath,
    chatId: task.chatId, taskId: task.id, parentAssetId: typeof prm.referenceAssetId === 'string' ? prm.referenceAssetId : null,
    metadata: { ...prm, engine: p.name, format: r.format } });
  return [a.id];
};
registerRunner('threed', threeDRunner);

export function generate3D(modelRef: ModelRef, params: Record<string, unknown>, chatId?: string | null) {
  return enqueue({ kind: 'threed', modelRef, params, chatId });
}

// --- Video ---------------------------------------------------------------------------------------

export async function videoOptions(ref: ModelRef | null): Promise<VideoModelOptions | null> {
  if (!ref || ref.source === 'auto') return null;
  if (ref.source === 'local') {
    return { modes: [], supportsNegativePrompt: false,
      notes: ['Video diffusion models need far more memory than an 8 GB iPad allows, and no on-device video runtime is integrated. Imported models are stored and inspected only.'] };
  }
  const { p, model } = await cloudContext(ref);
  return videoAdapterFor(p).options(model);
}

const videoRunner = (task: GenerationTask): TaskRunner => async ({ signal, progress }) => {
  const prm = task.params as Record<string, any>;
  const ref = task.modelRef;
  if (ref.source === 'local') {
    throw new ZinoError('UNSUPPORTED_MODEL', 'On-device video generation is not available on iPad in ZinoAgent. Choose a cloud video provider — ZinoAgent will not switch automatically.');
  }
  const { p } = await cloudContext(ref);
  const r = await videoAdapterFor(p).generate(p, {
    model: ref.source === 'cloud' ? ref.modelId : '', mode: prm.mode, prompt: prm.prompt ?? '', negativePrompt: prm.negativePrompt,
    reference: await reference(prm.referenceAssetId), durationSec: prm.durationSec, size: prm.size, resolution: prm.resolution,
    aspectRatio: prm.aspectRatio, fps: prm.fps, outputBase: `assets/video/${task.id}`, signal, resumeExternalId: prm.resumeExternalId,
    onProgress: (x) => progress(x.progress, x.label, x.externalId),
  });
  const a = await assetManager.save({ kind: 'video', name: String(prm.prompt || 'Video').slice(0, 60), mime: r.mime, path: r.appPath, durationSec: r.durationSec ?? null,
    width: r.width ?? null, height: r.height ?? null, chatId: task.chatId, taskId: task.id, metadata: { ...prm, engine: p.name } });
  return [a.id];
};
registerRunner('video', videoRunner);

export function generateVideo(modelRef: ModelRef, params: Record<string, unknown>, chatId?: string | null) {
  return enqueue({ kind: 'video', modelRef, params, chatId });
}

export type { Asset };
