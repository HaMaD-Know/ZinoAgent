// Provider & API-key management. Keys go straight to the iOS Keychain; SQLite only stores the
// Keychain account name and a masked hint. Connection tests make real requests — nothing is
// reported as connected unless the provider answered successfully.
import type { Capability, ModelCategory, Provider, ProviderKind, ProviderModel, ProviderOptions } from '@/types';
import { providersRepo, uid } from '@/database/repositories';
import { ZinoKeychain } from '@/native';
import { ZinoError, toZinoError } from '@/services/errors';
import { capabilityUnion, kindInfo, trimSlash, type ConnectionTestResult, type ProviderAdapter, type ChatAdapter } from '@/providers/types';
import { openaiAdapter } from '@/providers/chat/openai';
import { anthropicAdapter } from '@/providers/chat/anthropic';
import { geminiAdapter } from '@/providers/chat/gemini';
import { imageAdapterFor } from '@/providers/image';
import { threeDAdapterFor } from '@/providers/three-d';
import { videoAdapterFor } from '@/providers/video';

export const CATEGORY_CAPABILITY: Record<ModelCategory, Capability> = {
  chat: 'chat',
  image: 'image_generation',
  threed: 'threed_generation',
  video: 'video_generation',
};

export function chatAdapterFor(kind: ProviderKind): ChatAdapter {
  switch (kind) {
    case 'openai':
    case 'openai_compatible': return openaiAdapter;
    case 'anthropic': return anthropicAdapter;
    case 'gemini': return geminiAdapter;
    default: throw new ZinoError('UNSUPPORTED_PROVIDER', 'This provider does not offer chat in ZinoAgent.');
  }
}

function adapterFor(p: Provider): ProviderAdapter {
  switch (p.category) {
    case 'chat': return chatAdapterFor(p.kind) as unknown as ProviderAdapter;
    case 'image': return imageAdapterFor(p);
    case 'threed': return threeDAdapterFor(p);
    case 'video': return videoAdapterFor(p);
  }
}

function validateBaseUrl(kind: ProviderKind, url: string): string {
  let u: URL;
  try { u = new URL(url.trim()); } catch { throw new ZinoError('INVALID_ARGUMENT', 'Enter a valid URL, e.g. https://api.example.com/v1'); }
  if (u.protocol === 'http:') {
    const host = u.hostname;
    const local = /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host) || host.endsWith('.local');
    if (!local) throw new ZinoError('INVALID_ARGUMENT', 'Plain http:// is only allowed for local-network servers. Use https:// for internet endpoints.');
  } else if (u.protocol !== 'https:') {
    throw new ZinoError('INVALID_ARGUMENT', 'Only http(s) URLs are supported.');
  }
  if (kind !== 'openai_compatible' && u.protocol !== 'https:') throw new ZinoError('INVALID_ARGUMENT', 'This provider requires https://.');
  return trimSlash(u.toString());
}

export interface AddProviderInput {
  category: ModelCategory;
  kind: ProviderKind;
  name?: string;
  baseUrl?: string;
  apiKey?: string;
  /** Reuse the Keychain entry of another provider of the same kind (e.g. same OpenAI key for chat + images). */
  reuseKeyFromProviderId?: string;
  options?: ProviderOptions;
}

export const providerManager = {
  async list(category?: ModelCategory) { return providersRepo.list(category); },

  async add(input: AddProviderInput): Promise<Provider> {
    const info = kindInfo(input.kind);
    if (!info.categories.includes(input.category)) {
      throw new ZinoError('INVALID_ARGUMENT', `${info.label} is not available for this category.`);
    }
    const id = uid();
    let keyAccount = `zino.provider.${id}`;
    let keyMasked: string | null = null;
    if (input.reuseKeyFromProviderId) {
      const other = await providersRepo.get(input.reuseKeyFromProviderId);
      if (!other || other.kind !== input.kind) throw new ZinoError('INVALID_ARGUMENT', 'Can only reuse a key from a provider of the same type.');
      keyAccount = other.keyAccount;
      keyMasked = other.keyMasked;
    } else if (input.apiKey?.trim()) {
      keyMasked = (await ZinoKeychain.set({ account: keyAccount, secret: input.apiKey.trim() })).masked;
    } else if (info.keyRequired) {
      throw new ZinoError('MISSING_API_KEY', `${info.label} needs an API key.`);
    }
    const provider: Provider = {
      id, category: input.category, kind: input.kind, name: input.name?.trim() || info.label,
      baseUrl: validateBaseUrl(input.kind, input.baseUrl?.trim() || info.defaultBaseUrl), keyAccount, keyMasked,
      status: 'untested', lastTestedAt: null, lastError: null, capabilities: [], defaultModel: null,
      options: input.options ?? {}, createdAt: Date.now(),
    };
    await providersRepo.save(provider);
    return provider;
  },

  async update(id: string, patch: { name?: string; baseUrl?: string; options?: ProviderOptions; defaultModel?: string | null }) {
    const p = await providersRepo.get(id);
    if (!p) throw new ZinoError('NOT_FOUND', 'Provider not found.');
    const next: Provider = {
      ...p,
      name: patch.name?.trim() || p.name,
      baseUrl: patch.baseUrl ? validateBaseUrl(p.kind, patch.baseUrl) : p.baseUrl,
      options: patch.options ?? p.options,
      defaultModel: patch.defaultModel !== undefined ? patch.defaultModel : p.defaultModel,
    };
    if (patch.baseUrl && next.baseUrl !== p.baseUrl) next.status = 'untested';
    await providersRepo.save(next);
    return next;
  },

  /** Replace the API key. If the Keychain entry is shared, the new key applies to all sharers. */
  async setKey(id: string, apiKey: string) {
    const p = await providersRepo.get(id);
    if (!p) throw new ZinoError('NOT_FOUND', 'Provider not found.');
    if (!apiKey.trim()) throw new ZinoError('MISSING_API_KEY', 'The API key is empty.');
    const { masked } = await ZinoKeychain.set({ account: p.keyAccount, secret: apiKey.trim() });
    for (const other of await providersRepo.list()) {
      if (other.keyAccount === p.keyAccount) await providersRepo.save({ ...other, keyMasked: masked, status: 'untested', lastError: null });
    }
  },

  async remove(id: string) {
    const p = await providersRepo.get(id);
    if (!p) return;
    await providersRepo.remove(id);
    const stillUsed = (await providersRepo.list()).some((o) => o.keyAccount === p.keyAccount);
    if (!stillUsed) await ZinoKeychain.remove({ account: p.keyAccount });
  },

  /** Make a real authenticated request and refresh the model list. */
  async test(id: string): Promise<ConnectionTestResult> {
    const p = await providersRepo.get(id);
    if (!p) throw new ZinoError('NOT_FOUND', 'Provider not found.');
    try {
      const adapter = adapterFor(p);
      const result = await adapter.testConnection(p);
      const models = await this.refreshModels(id).catch(() => null);
      await providersRepo.save({ ...(await providersRepo.get(id))!, status: 'ok', lastError: null, lastTestedAt: Date.now() });
      return { ...result, modelCount: models?.length ?? result.modelCount };
    } catch (e) {
      const err = toZinoError(e);
      await providersRepo.save({ ...p, status: 'error', lastError: err.message, lastTestedAt: Date.now() });
      return { ok: false, message: err.message };
    }
  },

  async refreshModels(id: string): Promise<ProviderModel[]> {
    const p = await providersRepo.get(id);
    if (!p) throw new ZinoError('NOT_FOUND', 'Provider not found.');
    const models = await adapterFor(p).listModels(p);
    const relevant = models.filter((m) => m.capabilities.includes(CATEGORY_CAPABILITY[p.category]));
    await providersRepo.replaceModels(id, relevant);
    const capabilities = capabilityUnion(relevant);
    const defaultModel = p.defaultModel && relevant.some((m) => m.modelId === p.defaultModel) ? p.defaultModel : relevant[0]?.modelId ?? null;
    await providersRepo.save({ ...p, capabilities, defaultModel });
    return relevant;
  },

  async models(providerId?: string) { return providersRepo.models(providerId); },

  async hasKey(id: string) {
    const p = await providersRepo.get(id);
    if (!p) return false;
    return (await ZinoKeychain.has({ account: p.keyAccount })).exists;
  },
};
