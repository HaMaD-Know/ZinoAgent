import { beforeEach, describe, expect, it, vi } from 'vitest';

// In-memory stand-ins for the native Keychain + HTTP plugins.
const keychain = new Map<string, string>();
const requests: { url: string; headers: Record<string, string> }[] = [];
vi.mock('@/native', () => ({
  isNative: () => false,
  ZinoKeychain: {
    set: async ({ account, secret }: { account: string; secret: string }) => { keychain.set(account, secret); return { masked: '••••' + secret.slice(-4) }; },
    has: async ({ account }: { account: string }) => ({ exists: keychain.has(account) }),
    remove: async ({ account }: { account: string }) => { keychain.delete(account); },
  },
  ZinoHttp: {
    request: async (o: { url: string; headers?: Record<string, string>; auth?: { account: string; name?: string; prefix?: string } }) => {
      const headers = { ...(o.headers ?? {}) };
      if (o.auth) headers[o.auth.name ?? 'Authorization'] = (o.auth.prefix ?? '') + (keychain.get(o.auth.account) ?? '');
      requests.push({ url: o.url, headers });
      if (o.url.endsWith('/models')) {
        if (headers.Authorization !== 'Bearer sk-good-key-123456') return { status: 401, headers: {}, body: JSON.stringify({ error: { message: 'Incorrect API key provided: sk-good-key-123456' } }) };
        return { status: 200, headers: {}, body: JSON.stringify({ data: [{ id: 'gpt-5-mini' }, { id: 'gpt-image-1' }, { id: 'text-embedding-3-small' }, { id: 'sora-2' }] }) };
      }
      return { status: 404, headers: {}, body: '{}' };
    },
    cancel: async () => ({ cancelled: true }),
    addListener: async () => ({ remove: async () => {} }),
  },
}));

import { freshDb } from './helpers/db';
import { providerManager } from '@/services/provider-manager';
import { providersRepo } from '@/database/repositories';
import { db } from '@/database';

describe('provider manager', () => {
  beforeEach(async () => { await freshDb(); keychain.clear(); requests.length = 0; });

  it('stores keys only in the keychain, tests the connection and fetches category-relevant models', async () => {
    const p = await providerManager.add({ category: 'chat', kind: 'openai', apiKey: 'sk-good-key-123456' });
    expect(keychain.get(p.keyAccount)).toBe('sk-good-key-123456');
    const dump = JSON.stringify(await db().query('SELECT * FROM providers'));
    expect(dump).not.toContain('sk-good-key');

    const r = await providerManager.test(p.id);
    expect(r.ok).toBe(true);
    const models = await providerManager.models(p.id);
    expect(models.map((m) => m.modelId)).toEqual(['gpt-5-mini']); // chat only; image/video/embedding models excluded
    const saved = await providersRepo.get(p.id);
    expect(saved?.status).toBe('ok');
    expect(saved?.defaultModel).toBe('gpt-5-mini');
    expect(saved?.capabilities).toEqual(expect.arrayContaining(['chat', 'reasoning', 'tool_calling']));
  });

  it('detects image and video capabilities for the same provider in other categories, reusing the key', async () => {
    const chat = await providerManager.add({ category: 'chat', kind: 'openai', apiKey: 'sk-good-key-123456' });
    const img = await providerManager.add({ category: 'image', kind: 'openai', reuseKeyFromProviderId: chat.id });
    const vid = await providerManager.add({ category: 'video', kind: 'openai', reuseKeyFromProviderId: chat.id });
    expect(img.keyAccount).toBe(chat.keyAccount);
    expect((await providerManager.refreshModels(img.id)).map((m) => m.modelId)).toEqual(['gpt-image-1']);
    expect((await providerManager.refreshModels(vid.id)).map((m) => m.modelId)).toEqual(['sora-2']);
    // Removing one sharer keeps the shared key; removing the last deletes it.
    await providerManager.remove(chat.id);
    await providerManager.remove(img.id);
    expect(keychain.has(vid.keyAccount)).toBe(true);
    await providerManager.remove(vid.id);
    expect(keychain.has(vid.keyAccount)).toBe(false);
  });

  it('reports invalid keys as an error without leaking the key', async () => {
    const p = await providerManager.add({ category: 'chat', kind: 'openai', apiKey: 'sk-bad-key-999999999' });
    const r = await providerManager.test(p.id);
    expect(r.ok).toBe(false);
    expect(r.message).toMatch(/rejected the API key/);
    const saved = await providersRepo.get(p.id);
    expect(saved?.status).toBe('error');
    expect(saved?.lastError).not.toContain('sk-good-key-123456');
  });

  it('rejects plain http for internet hosts but allows local servers for compatible endpoints', async () => {
    await expect(providerManager.add({ category: 'chat', kind: 'openai_compatible', baseUrl: 'http://example.com/v1' })).rejects.toThrow(/local-network/);
    const local = await providerManager.add({ category: 'chat', kind: 'openai_compatible', baseUrl: 'http://192.168.1.20:11434/v1' });
    expect(local.baseUrl).toBe('http://192.168.1.20:11434/v1');
    await expect(providerManager.add({ category: 'chat', kind: 'anthropic' })).rejects.toThrow(/needs an API key/);
  });
});
