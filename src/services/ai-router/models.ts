// Model catalogue for selectors + Auto mode. Auto never picks a cloud provider unless the user has
// explicitly allowed it; when no local model fits, it returns a recommendation that the UI must
// confirm with the user before anything is sent online.
import type { Capability, Compatibility, LocalModel, ModelCategory, ModelRef, Provider, ProviderModel, Studio } from '@/types';
import { STUDIO_CATEGORY } from '@/types';
import { modelsRepo, providersRepo } from '@/database/repositories';
import { CATEGORY_CAPABILITY } from '@/services/provider-manager';
import { loadedModel } from '@/services/resources';
import { classifyComplexity } from './effort';

export interface SelectableModel {
  ref: ModelRef;
  key: string;
  source: 'local' | 'cloud';
  name: string;
  providerName: string;
  providerKind?: Provider['kind'];
  capabilities: Capability[];
  compatibility: Compatibility | null;
  contextLength: number | null;
  memoryBytes: number | null;
  status: 'ready' | 'loaded' | 'error' | 'untested' | 'unsupported';
  statusText: string | null;
  local?: LocalModel;
  cloud?: { provider: Provider; model: ProviderModel };
}

const LOCAL_CAPS: Record<ModelCategory, Capability[]> = {
  chat: ['chat', 'tool_calling'],
  image: ['image_generation'],
  threed: ['threed_generation'],
  video: ['video_generation'],
};

export async function listSelectableModels(category: ModelCategory): Promise<SelectableModel[]> {
  const out: SelectableModel[] = [];
  const locals = await modelsRepo.list(category);
  const loadedChat = loadedModel('llama');
  const loadedImage = loadedModel('diffusion');
  for (const m of locals) {
    const isLoaded = (category === 'chat' && loadedChat?.modelId === m.id) || (category === 'image' && loadedImage?.modelId === m.id);
    const caps = [...LOCAL_CAPS[category]];
    if (category === 'image' && (m.metadata.validation as { supportsImageToImage?: boolean } | undefined)?.supportsImageToImage) caps.push('image_editing');
    if (category === 'chat' && /qwen3|deepseek-r1|qwq|gpt-oss/i.test(`${m.name} ${m.architecture}`)) caps.push('reasoning');
    out.push({
      ref: { source: 'local', modelId: m.id }, key: `local:${m.id}`, source: 'local', name: m.name, providerName: 'On device',
      capabilities: caps, compatibility: m.compatibility, contextLength: m.settings.contextLength ?? m.contextLength,
      memoryBytes: (m.metadata.estimatedBytes as number | undefined) ?? m.sizeBytes,
      status: m.compatibility === 'unsupported' ? 'unsupported' : isLoaded ? 'loaded' : 'ready',
      statusText: m.compatibility === 'unsupported' ? m.compatibilityNotes[0] ?? 'Unsupported on this device' : null, local: m,
    });
  }
  const providers = await providersRepo.list(category);
  const models = await providersRepo.models();
  const needed = CATEGORY_CAPABILITY[category];
  for (const p of providers) {
    for (const pm of models.filter((x) => x.providerId === p.id && x.capabilities.includes(needed))) {
      out.push({
        ref: { source: 'cloud', providerId: p.id, modelId: pm.modelId }, key: `cloud:${p.id}:${pm.modelId}`, source: 'cloud',
        name: pm.displayName, providerName: p.name, providerKind: p.kind, capabilities: pm.capabilities, compatibility: null,
        contextLength: pm.contextLength ?? p.options.contextLength ?? null, memoryBytes: null,
        status: p.status === 'error' ? 'error' : p.status === 'untested' ? 'untested' : 'ready',
        statusText: p.status === 'error' ? p.lastError : p.status === 'untested' ? 'Connection not tested yet' : null,
        cloud: { provider: p, model: pm },
      });
    }
  }
  return out;
}

export async function findSelectable(ref: ModelRef | null, category: ModelCategory): Promise<SelectableModel | null> {
  if (!ref || ref.source === 'auto') return null;
  const all = await listSelectableModels(category);
  const key = ref.source === 'local' ? `local:${ref.modelId}` : `cloud:${ref.providerId}:${ref.modelId}`;
  return all.find((m) => m.key === key) ?? null;
}

export interface AutoDecision {
  choice: SelectableModel | null;
  reason: string;
  /** A cloud model Auto would recommend; only usable after explicit user permission. */
  cloudSuggestion: SelectableModel | null;
}

const COMPAT_RANK: Record<Compatibility, number> = { compatible: 3, limited: 2, experimental: 1, unsupported: 0 };

/** Pick a model for a task. Local first; cloud only if `allowCloud` (an explicit user setting/consent). */
export async function autoSelect(studio: Studio, prompt: string, opts: { allowCloud: boolean; online: boolean; needs?: Capability[] }): Promise<AutoDecision> {
  const category = STUDIO_CATEGORY[studio];
  const all = await listSelectableModels(category);
  const needs = opts.needs ?? [];
  const usable = all.filter((m) => m.status !== 'unsupported' && needs.every((n) => m.capabilities.includes(n)));
  const complexity = studio === 'agent' ? classifyComplexity(prompt).level : 'medium';
  const locals = usable.filter((m) => m.source === 'local').sort((a, b) => {
    // Prefer an already-loaded model (no load time, no extra RAM), then compatibility, then size for hard tasks.
    const loaded = Number(b.status === 'loaded') - Number(a.status === 'loaded');
    if (loaded) return loaded;
    const compat = COMPAT_RANK[b.compatibility ?? 'experimental'] - COMPAT_RANK[a.compatibility ?? 'experimental'];
    if (compat) return compat;
    const size = (b.memoryBytes ?? 0) - (a.memoryBytes ?? 0);
    return complexity === 'high' ? size : -size;
  });
  const clouds = usable.filter((m) => m.source === 'cloud' && m.status !== 'error');
  const cloudSuggestion = opts.online ? clouds.find((m) => m.status === 'ready') ?? clouds[0] ?? null : null;
  if (locals.length && !(complexity === 'high' && opts.allowCloud && cloudSuggestion)) {
    const m = locals[0];
    return { choice: m, reason: `On-device ${m.name}${m.status === 'loaded' ? ' (already loaded)' : ''} — ${complexity} complexity task, no data leaves the iPad.`, cloudSuggestion };
  }
  if (opts.allowCloud && cloudSuggestion) {
    return { choice: cloudSuggestion, reason: `${cloudSuggestion.providerName} · ${cloudSuggestion.name} (cloud use is allowed in Auto settings).`, cloudSuggestion };
  }
  return {
    choice: null,
    reason: locals.length ? 'A cloud model may handle this better, but Auto needs your permission to go online.' : 'No compatible offline model is installed.',
    cloudSuggestion,
  };
}
