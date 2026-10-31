// Application settings persisted in SQLite (`settings` table). Never contains secrets.
import type { EffortLevel, ModelRef, Studio } from '@/types';
import { settingsRepo } from '@/database/repositories';

export interface ContextSettings {
  /** Fraction of the usable context at which compaction starts (0.85–0.90 recommended). */
  compactionThreshold: number;
  /** Target fraction after compaction. */
  compactionTarget: number;
  batching: 'adaptive';
  batchReferenceSize: number;
  retrieval: 'smart' | 'recent_only';
  /** Always true: originals are never deleted after summarisation. Kept as a visible, locked setting. */
  preserveOriginals: true;
  summaryVerification: boolean;
  /** Extra LLM verification pass: auto = only at High/Maximum effort. */
  llmVerification: 'auto' | 'always' | 'never';
  minRecentMessages: number;
  /** Per-model overrides of compaction threshold, keyed by model key. */
  perModelThreshold: Record<string, number>;
}

export interface EffortSettings {
  offlineDefault: EffortLevel;
  onlineDefault: EffortLevel;
  perStudio: Partial<Record<Studio, EffortLevel>>;
  perModel: Record<string, EffortLevel>;
}

export interface ResourceSettings {
  singleHeavyModel: boolean;
  idleUnloadMinutes: number;
  pauseHeavyTasksAt: 'serious' | 'critical' | 'never';
  warnBeforeHighMemory: boolean;
}

export interface AppSettings {
  theme: 'system' | 'light' | 'dark';
  studioModels: Record<Studio, ModelRef | null>;
  defaultModels: Record<Studio, ModelRef | null>;
  effort: EffortSettings;
  context: ContextSettings;
  resources: ResourceSettings;
  agent: { systemPrompt: string; autoTitle: boolean; fileToolsEnabled: boolean; maxToolIterations: number };
  auto: { allowCloud: boolean };
  /** Upper bound on prompt size sent to cloud models (controls cost; models may support more). */
  contextCloudCap: number;
  onboardingDone: boolean;
}

export const DEFAULT_SYSTEM_PROMPT =
  'You are ZinoAgent, a helpful AI assistant running on the user\'s iPad. Be accurate and concise. ' +
  'When you use file tools, only act inside the folder the user authorised, explain what you will change, and never invent file names or results.';

export const DEFAULT_SETTINGS: AppSettings = {
  theme: 'system',
  studioModels: { agent: null, image: null, threed: null, video: null },
  defaultModels: { agent: null, image: null, threed: null, video: null },
  effort: { offlineDefault: 'medium', onlineDefault: 'medium', perStudio: {}, perModel: {} },
  context: {
    compactionThreshold: 0.85,
    compactionTarget: 0.5,
    batching: 'adaptive',
    batchReferenceSize: 5,
    retrieval: 'smart',
    preserveOriginals: true,
    summaryVerification: true,
    llmVerification: 'auto',
    minRecentMessages: 4,
    perModelThreshold: {},
  },
  resources: { singleHeavyModel: true, idleUnloadMinutes: 10, pauseHeavyTasksAt: 'serious', warnBeforeHighMemory: true },
  agent: { systemPrompt: DEFAULT_SYSTEM_PROMPT, autoTitle: true, fileToolsEnabled: true, maxToolIterations: 8 },
  auto: { allowCloud: false },
  contextCloudCap: 128_000,
  onboardingDone: false,
};

function deepMerge<T>(base: T, patch: unknown): T {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) return (patch as T) ?? base;
  const out: Record<string, unknown> = { ...(base as Record<string, unknown>) };
  for (const [k, v] of Object.entries(patch as Record<string, unknown>)) {
    const b = (base as Record<string, unknown>)[k];
    out[k] = b && typeof b === 'object' && !Array.isArray(b) && v && typeof v === 'object' && !Array.isArray(v) ? deepMerge(b, v) : v;
  }
  return out as T;
}

export async function loadSettings(): Promise<AppSettings> {
  const stored = await settingsRepo.all();
  const merged = deepMerge(DEFAULT_SETTINGS, stored.app ?? {});
  merged.context.preserveOriginals = true; // cannot be disabled
  return merged;
}

export async function saveSettings(s: AppSettings) {
  await settingsRepo.set('app', { ...s, context: { ...s.context, preserveOriginals: true } });
}

export const modelKey = (ref: ModelRef | null | undefined) =>
  !ref ? 'none' : ref.source === 'auto' ? 'auto' : ref.source === 'local' ? `local:${ref.modelId}` : `cloud:${ref.providerId}:${ref.modelId}`;
