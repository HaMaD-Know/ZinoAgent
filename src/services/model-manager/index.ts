// Offline model libraries (chat / image / 3D / video): import, inspect, compatibility, load,
// unload, benchmark and delete. Model files are untrusted data: they are only parsed by the
// inference runtimes (llama.cpp, Core ML) and never executed.
import type { Compatibility, LocalModel, LocalModelSettings, ModelCategory } from '@/types';
import { modelsRepo, uid } from '@/database/repositories';
import { ZinoCoreML, ZinoDiffusion, ZinoLlama, ZinoStorage, type GGUFInfo } from '@/native';
import { ZinoError, toZinoError } from '@/services/errors';
import { assessGGUF, DEFAULT_BUDGET_BYTES, estimateMemory, quantLabel } from '@/models/chat/gguf';
import {
  loadedModel, markUsed, prepareForHeavyLoad, refreshSnapshot, registerLoaded, setLoading, unloadModel, useResources,
} from '@/services/resources';
import { LOCAL_GENERATION_ADAPTERS } from '@/models/adapters';

const DIRS: Record<ModelCategory, string> = { chat: 'models/chat', image: 'models/image', threed: 'models/threed', video: 'models/video' };

async function memoryBudget(): Promise<number> {
  const snap = await refreshSnapshot();
  if (snap && !snap.estimated && snap.availableMemory > 0) {
    // Memory already held by a loaded heavy model would be released before loading another.
    const held = useResources.getState().loaded.reduce((a, m) => a + (m.estimatedBytes ?? 0), 0);
    return snap.availableMemory + held;
  }
  return DEFAULT_BUDGET_BYTES;
}

function baseModel(category: ModelCategory, partial: Partial<LocalModel> & { name: string; path: string; format: LocalModel['format'] }): LocalModel {
  return {
    id: uid(), category, sizeBytes: 0, sha256: null, sourceUrl: null, license: null, attribution: null, quantization: null,
    architecture: null, contextLength: null, parameters: null, compatibility: 'experimental', compatibilityNotes: [], metadata: {},
    installedAt: Date.now(), benchmark: null, settings: {}, ...partial,
  };
}

/** Register a GGUF file that is already in app storage. */
export async function registerGGUF(path: string, extra: Partial<LocalModel> = {}): Promise<LocalModel> {
  const fileName = path.split('/').pop() ?? path;
  if (!/\.gguf$/i.test(fileName)) throw new ZinoError('UNSUPPORTED_FORMAT', `${fileName} is not a .gguf file. Chat models must be GGUF.`);
  let info: GGUFInfo;
  try { info = await ZinoLlama.inspect({ path }); } catch (e) {
    throw new ZinoError('UNSUPPORTED_FORMAT', `Could not read ${fileName} as GGUF: ${toZinoError(e).message}`);
  }
  const budget = await memoryBudget();
  const a = assessGGUF(info, fileName, budget, 4096);
  const model = baseModel('chat', {
    name: info.name || fileName.replace(/\.gguf$/i, ''), path, format: 'gguf', sizeBytes: info.fileSize, architecture: info.architecture,
    quantization: quantLabel(info, fileName), contextLength: info.contextLength ?? null, license: info.license ?? extra.license ?? null,
    compatibility: a.compatibility, compatibilityNotes: a.notes,
    metadata: { gguf: { ...info, chatTemplate: undefined }, estimatedBytes: a.estimatedBytes, sizeLabel: info.sizeLabel },
    settings: { contextLength: a.recommendedContext || Math.min(4096, info.contextLength ?? 4096) },
    ...extra,
  });
  await modelsRepo.save(model);
  return model;
}

/** Register a Core ML Stable Diffusion resource folder. */
export async function registerDiffusion(path: string, extra: Partial<LocalModel> = {}): Promise<LocalModel> {
  const v = await ZinoDiffusion.validate({ path });
  const size = (await ZinoStorage.directorySize({ path })).size;
  const notes: string[] = [];
  let compatibility: Compatibility = 'compatible';
  if (!v.valid) {
    compatibility = 'unsupported';
    notes.push(v.hasUncompiledPackages
      ? 'This folder contains uncompiled .mlpackage files. ZinoAgent needs the compiled (.mlmodelc) Core ML Stable Diffusion resources.'
      : `Missing required files: ${v.missing.join(', ')}.`);
  } else {
    if (v.isXL) { compatibility = 'experimental'; notes.push('SDXL on an 8 GB iPad is very memory-intensive; generation may fail or be slow.'); }
    if (!v.supportsImageToImage) notes.push('No VAEEncoder: image-to-image is not available with this model.');
    if (!v.chunkedUnet && size > 1.8 * 1024 ** 3) notes.push('Large non-chunked UNet: the "split_einsum" variant is recommended for iPad.');
    if (v.nativeSize) notes.push(`Native resolution: ${v.nativeSize}×${v.nativeSize}. Core ML diffusion models are compiled for a fixed size.`);
  }
  const model = baseModel('image', {
    name: extra.name ?? path.split('/').pop() ?? 'Core ML diffusion model', path: v.resourcePath || path, format: 'coreml-diffusion', sizeBytes: size,
    architecture: v.isXL ? 'stable-diffusion-xl' : 'stable-diffusion', compatibility, compatibilityNotes: notes,
    metadata: { validation: v }, settings: { computeUnits: 'cpuAndNeuralEngine' }, ...extra,
  });
  await modelsRepo.save(model);
  return model;
}

/** Register a 3D or video model: inspect it with Core ML and match against local adapters. */
export async function registerCoreMLGenerator(category: 'threed' | 'video', path: string, extra: Partial<LocalModel> = {}): Promise<LocalModel> {
  const notes: string[] = [];
  let metadata: Record<string, unknown> = {};
  let compatibility: Compatibility = 'unsupported';
  const size = (await ZinoStorage.directorySize({ path })).size;
  try {
    const d = await ZinoCoreML.inspect({ path });
    metadata = { coreml: d };
    const adapter = LOCAL_GENERATION_ADAPTERS.filter((a) => a.category === category).find((a) => a.matches(d));
    if (adapter) { compatibility = adapter.compatibility; notes.push(`Matched local adapter: ${adapter.name}.`); }
    else notes.push(`ZinoAgent has no on-device ${category === 'threed' ? '3D' : 'video'} generation adapter for this model's inputs/outputs (${d.inputs.map((i) => i.name).join(', ')} → ${d.outputs.map((o) => o.name).join(', ')}). It is stored but cannot generate.`);
  } catch (e) {
    notes.push(`Core ML could not open this model: ${toZinoError(e).message}`);
  }
  const model = baseModel(category, { name: extra.name ?? path.split('/').pop() ?? 'Model', path, format: 'coreml', sizeBytes: size, compatibility, compatibilityNotes: notes, metadata, ...extra });
  await modelsRepo.save(model);
  return model;
}

export async function importModels(category: ModelCategory): Promise<{ imported: LocalModel[]; errors: string[] }> {
  const kind = category === 'chat' ? 'gguf' : 'coreml';
  const { files } = await ZinoStorage.pickAndImport({ kind, destDir: DIRS[category], multiple: category === 'chat' });
  const imported: LocalModel[] = [];
  const errors: string[] = [];
  for (const f of files) {
    try {
      let path = f.path;
      if (category !== 'chat' && /\.zip$/i.test(f.name)) {
        const dest = path.replace(/\.zip$/i, '');
        await ZinoStorage.unzip({ path, destination: dest });
        await ZinoStorage.remove({ path });
        path = dest;
      }
      if (category === 'chat') imported.push(await registerGGUF(path));
      else if (category === 'image') imported.push(await registerDiffusion(path, { name: f.originalName.replace(/\.zip$/i, '') }));
      else imported.push(await registerCoreMLGenerator(category, path, { name: f.originalName }));
    } catch (e) {
      errors.push(`${f.originalName}: ${toZinoError(e).message}`);
      // Do not keep files we could not register as a model.
      await ZinoStorage.remove({ path: f.path }).catch(() => {});
    }
  }
  return { imported, errors };
}

export async function deleteModel(id: string) {
  const m = await modelsRepo.get(id);
  if (!m) return;
  const kind = m.category === 'chat' ? 'llama' : m.category === 'image' ? 'diffusion' : null;
  if (kind && loadedModel(kind)?.modelId === id) await unloadModel(kind, { force: true });
  await ZinoStorage.remove({ path: m.path }).catch(() => {});
  await modelsRepo.remove(id);
}

export async function updateModelSettings(id: string, settings: LocalModelSettings) {
  const m = await modelsRepo.get(id);
  if (!m) throw new ZinoError('NOT_FOUND', 'Model not found.');
  await modelsRepo.save({ ...m, settings: { ...m.settings, ...settings } });
}

/** Load (or reuse) a chat model in llama.cpp. */
export async function ensureChatModel(modelId: string): Promise<{ model: LocalModel; contextLength: number }> {
  const model = await modelsRepo.get(modelId);
  if (!model) throw new ZinoError('NOT_FOUND', 'That offline model is no longer installed.', { recovery: ['open_models'] });
  if (model.compatibility === 'unsupported') {
    throw new ZinoError('UNSUPPORTED_MODEL', `${model.name} is marked unsupported on this device: ${model.compatibilityNotes.join(' ')}`);
  }
  const ctx = model.settings.contextLength ?? 4096;
  const current = loadedModel('llama');
  if (current && current.modelId === modelId && current.contextLength === ctx) {
    markUsed('llama', false);
    return { model, contextLength: ctx };
  }
  const gguf = model.metadata.gguf as GGUFInfo | undefined;
  const estimatedBytes = gguf ? estimateMemory(gguf, ctx).total : model.sizeBytes;
  if (!(await prepareForHeavyLoad({ kind: 'llama', name: model.name, estimatedBytes }))) {
    throw new ZinoError('CANCELLED', 'Model loading was cancelled.');
  }
  setLoading({ kind: 'llama', name: model.name, progress: 0 });
  const handle = await ZinoLlama.addListener('loadProgress', (e) => setLoading({ kind: 'llama', name: model.name, progress: e.progress }));
  try {
    const info = await ZinoLlama.load({
      path: model.path, contextLength: ctx, gpuLayers: model.settings.gpuLayers, threads: model.settings.threads, batchSize: model.settings.batchSize,
    });
    registerLoaded({ kind: 'llama', modelId, name: model.name, path: model.path, contextLength: info.contextLength, estimatedBytes, loadMs: info.loadMs });
    const snap = await refreshSnapshot();
    await modelsRepo.save({
      ...model,
      benchmark: { ...(model.benchmark ?? { measuredAt: Date.now() }), loadMs: info.loadMs, appFootprintBytes: snap?.appFootprint, contextLength: info.contextLength, device: snap?.deviceModel, measuredAt: Date.now() },
    });
    return { model, contextLength: info.contextLength };
  } catch (e) {
    setLoading(null);
    const err = toZinoError(e);
    throw new ZinoError(err.code === 'NATIVE_ERROR' ? 'MODEL_LOAD_FAILED' : err.code, err.message);
  } finally {
    await handle.remove();
  }
}

export async function ensureImageModel(modelId: string): Promise<{ model: LocalModel; nativeSize: number | null; supportsImageToImage: boolean }> {
  const model = await modelsRepo.get(modelId);
  if (!model) throw new ZinoError('NOT_FOUND', 'That offline image model is no longer installed.', { recovery: ['open_models'] });
  if (model.compatibility === 'unsupported') throw new ZinoError('UNSUPPORTED_MODEL', `${model.name}: ${model.compatibilityNotes.join(' ')}`);
  const v = model.metadata.validation as { nativeSize: number | null; supportsImageToImage: boolean } | undefined;
  const current = loadedModel('diffusion');
  if (current?.modelId === modelId) { markUsed('diffusion', false); return { model, nativeSize: v?.nativeSize ?? null, supportsImageToImage: !!v?.supportsImageToImage }; }
  if (!(await prepareForHeavyLoad({ kind: 'diffusion', name: model.name, estimatedBytes: model.sizeBytes * 1.3 }))) {
    throw new ZinoError('CANCELLED', 'Model loading was cancelled.');
  }
  setLoading({ kind: 'diffusion', name: model.name, progress: 0 });
  try {
    const r = await ZinoDiffusion.load({ path: model.path, computeUnits: model.settings.computeUnits ?? 'cpuAndNeuralEngine', reduceMemory: true });
    registerLoaded({ kind: 'diffusion', modelId, name: model.name, path: model.path, estimatedBytes: model.sizeBytes * 1.3, loadMs: r.loadMs });
    return { model, nativeSize: r.nativeSize, supportsImageToImage: r.supportsImageToImage };
  } catch (e) {
    setLoading(null);
    throw toZinoError(e, 'MODEL_LOAD_FAILED');
  }
}

/** Real on-device measurement; nothing here is estimated or invented. */
export async function benchmarkChatModel(modelId: string) {
  const { model } = await ensureChatModel(modelId);
  markUsed('llama', true);
  try {
    const r = await ZinoLlama.benchmark({ promptTokens: 256, genTokens: 64 });
    const snap = await refreshSnapshot();
    const fresh = (await modelsRepo.get(modelId)) ?? model;
    const benchmark = {
      ...(fresh.benchmark ?? {}), measuredAt: Date.now(), promptTokensPerSecond: r.promptTokensPerSecond,
      generationTokensPerSecond: r.generationTokensPerSecond, appFootprintBytes: snap?.appFootprint, device: snap?.deviceModel,
      contextLength: fresh.settings.contextLength,
    };
    await modelsRepo.save({ ...fresh, benchmark });
    return benchmark;
  } finally {
    markUsed('llama', false);
  }
}

export const modelDir = (c: ModelCategory) => DIRS[c];
