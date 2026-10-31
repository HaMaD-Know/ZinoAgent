// Registry of on-device generation adapters for model architectures beyond chat and image.
//
// Each adapter declares which imported Core ML models it can drive (by inspecting inputs/outputs)
// and how to run them. As of this build there is no iPadOS-compatible text-to-3D or video
// diffusion runtime integrated, so the 3D and video registries are intentionally empty: imported
// models are inspected and stored, and the UI reports them as "Unsupported" instead of pretending.
// To add one, implement LocalGenerationAdapter and append it here.
import type { Compatibility } from '@/types';
import type { CoreMLFeature } from '@/native';

export interface CoreMLDescription { inputs: CoreMLFeature[]; outputs: CoreMLFeature[]; author: string; description: string; license: string; version: string }

export interface LocalGenerationAdapter {
  id: string;
  name: string;
  category: 'threed' | 'video';
  compatibility: Compatibility;
  matches(d: CoreMLDescription): boolean;
  /** Runs generation; returns an app-relative output path. */
  generate(opts: { modelPath: string; prompt: string; referenceImage?: string; outputBase: string; signal?: AbortSignal; onProgress?: (p: number) => void }): Promise<{ appPath: string }>;
}

export const LOCAL_GENERATION_ADAPTERS: LocalGenerationAdapter[] = [];
