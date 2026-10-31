// Shared contracts for image, 3D and video generation adapters (cloud and local).
import type { Provider, ProviderModel } from '@/types';
import { ZinoError } from '@/services/errors';
import type { ConnectionTestResult } from './types';
import { sleep } from './http';

export interface ReferenceImage { appPath: string; mime: string; base64: string }

export interface ProgressInfo { progress: number; label?: string; externalId?: string }

/** Describes which controls a model supports. The UI renders only these. */
export interface ImageModelOptions {
  modes: ('text' | 'image' | 'edit')[];
  sizes?: string[];
  aspectRatios?: string[];
  qualities?: string[];
  supportsSeed: boolean;
  supportsNegativePrompt: boolean;
  maxCount: number;
  supportsStrength?: boolean;
  steps?: { min: number; max: number; default: number };
  guidance?: { min: number; max: number; default: number };
  notes?: string[];
}

export interface ImageRequest {
  model: string;
  mode: 'text' | 'image' | 'edit';
  prompt: string;
  negativePrompt?: string;
  reference?: ReferenceImage;
  size?: string;
  aspectRatio?: string;
  quality?: string;
  seed?: number;
  count?: number;
  strength?: number;
  steps?: number;
  guidance?: number;
  signal?: AbortSignal;
  onProgress?: (p: ProgressInfo) => void;
}

export interface GeneratedImage { base64?: string; appPath?: string; mime: string; width?: number; height?: number }
export interface ImageResult { images: GeneratedImage[]; seed?: number; revisedPrompt?: string; notes?: string[] }

export interface ImageProviderAdapter {
  testConnection(p: Provider): Promise<ConnectionTestResult>;
  listModels(p: Provider): Promise<ProviderModel[]>;
  options(model: ProviderModel): ImageModelOptions;
  generate(p: Provider, req: ImageRequest): Promise<ImageResult>;
}

export interface ThreeDModelOptions {
  modes: ('text' | 'image')[];
  topologies?: ('triangle' | 'quad')[];
  polycount?: { min: number; max: number; default: number };
  textureResolutions?: number[];
  supportsTexture: boolean;
  supportsPBR: boolean;
  geometryQualities?: string[];
  outputFormats: string[];
  notes?: string[];
}

export interface ThreeDRequest {
  model: string;
  mode: 'text' | 'image';
  prompt: string;
  reference?: ReferenceImage;
  topology?: 'triangle' | 'quad';
  targetPolycount?: number;
  texture: boolean;
  pbr: boolean;
  textureResolution?: number;
  geometryQuality?: string;
  /** Where to save the resulting model (app-relative, without extension). */
  outputBase: string;
  signal?: AbortSignal;
  onProgress?: (p: ProgressInfo) => void;
  resumeExternalId?: string;
}

export interface ThreeDResult { appPath: string; format: 'glb' | 'gltf' | 'obj'; thumbnailBase64?: string; notes?: string[] }

export interface ThreeDProviderAdapter {
  testConnection(p: Provider): Promise<ConnectionTestResult>;
  listModels(p: Provider): Promise<ProviderModel[]>;
  options(model: ProviderModel): ThreeDModelOptions;
  generate(p: Provider, req: ThreeDRequest): Promise<ThreeDResult>;
}

export interface VideoModelOptions {
  modes: ('text' | 'image')[];
  durations?: number[];
  sizes?: string[];
  resolutions?: string[];
  aspectRatios?: string[];
  fps?: number[];
  supportsNegativePrompt: boolean;
  notes?: string[];
}

export interface VideoRequest {
  model: string;
  mode: 'text' | 'image';
  prompt: string;
  negativePrompt?: string;
  reference?: ReferenceImage;
  durationSec?: number;
  size?: string;
  resolution?: string;
  aspectRatio?: string;
  fps?: number;
  outputBase: string;
  signal?: AbortSignal;
  onProgress?: (p: ProgressInfo) => void;
  resumeExternalId?: string;
}

export interface VideoResult { appPath: string; mime: string; durationSec?: number; width?: number; height?: number }

export interface VideoProviderAdapter {
  testConnection(p: Provider): Promise<ConnectionTestResult>;
  listModels(p: Provider): Promise<ProviderModel[]>;
  options(model: ProviderModel): VideoModelOptions;
  generate(p: Provider, req: VideoRequest): Promise<VideoResult>;
}

export function staticModels(p: Provider, list: { id: string; name: string; caps: ProviderModel['capabilities']; meta?: Record<string, unknown> }[]): ProviderModel[] {
  const now = Date.now();
  return list.map((m) => ({
    id: `${p.id}:${m.id}`, providerId: p.id, modelId: m.id, displayName: m.name, capabilities: m.caps,
    contextLength: null, outputLimit: null, metadata: { static: true, ...(m.meta ?? {}) }, fetchedAt: now,
  }));
}

/** Poll an async job until done. `check` returns null while still running. */
export async function poll<T>(check: () => Promise<T | null>, opts: { signal?: AbortSignal; intervalMs?: number; timeoutMs?: number }): Promise<T> {
  const start = Date.now();
  let interval = opts.intervalMs ?? 4000;
  for (;;) {
    const r = await check();
    if (r !== null) return r;
    if (Date.now() - start > (opts.timeoutMs ?? 45 * 60_000)) throw new ZinoError('NETWORK_TIMEOUT', 'The provider did not finish in time. The job may still complete on their side.');
    await sleep(interval, opts.signal);
    interval = Math.min(15_000, Math.round(interval * 1.2));
  }
}
