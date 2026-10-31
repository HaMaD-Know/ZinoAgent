import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('@/native', () => ({ isNative: () => false }));

import { freshDb } from './helpers/db';
import { db, migrate, recoverAfterRestart } from '@/database';
import { chatsRepo, contextRepo, foldersRepo, messagesRepo, modelsRepo, providersRepo, tasksRepo } from '@/database/repositories';
import { autoSelect } from '@/services/ai-router/models';
import { loadSettings, saveSettings, DEFAULT_SETTINGS } from '@/services/settings';
import type { ChatMessage, LocalModel } from '@/types';

const msg = (chatId: string, role: ChatMessage['role'], content: string, status: ChatMessage['status'] = 'complete') => messagesRepo.insert({
  chatId, role, content, reasoning: null, tokenCount: null, tokenExact: false, tokenModel: null, batchId: null, status, modelRef: null,
  attachments: [], toolCalls: [], toolCallId: null, toolName: null, meta: {},
});

describe('chat history', () => {
  beforeEach(async () => { await freshDb(); });

  it('supports rename, pin ordering, folders, archive, search and delete with cascade', async () => {
    const a = await chatsRepo.create({ title: 'Hot Wheels catalogue' });
    const b = await chatsRepo.create({ title: 'Budget' });
    await msg(b.id, 'user', 'The quarterly budget is 12,500 USD');
    await chatsRepo.update(a.id, { pinned: true });
    expect((await chatsRepo.list())[0].id).toBe(a.id);
    const f = await foldersRepo.create('Projects');
    await chatsRepo.update(b.id, { folderId: f.id, title: 'Finance', titleAuto: false });
    expect((await chatsRepo.get(b.id))?.folderId).toBe(f.id);
    expect((await chatsRepo.list({ search: 'quarterly' })).map((c) => c.id)).toEqual([b.id]); // matches message content
    await chatsRepo.update(a.id, { archived: true });
    expect((await chatsRepo.list()).map((c) => c.id)).toEqual([b.id]);
    expect((await chatsRepo.list({ archived: true })).map((c) => c.id)).toEqual([a.id]);
    await foldersRepo.remove(f.id);
    expect((await chatsRepo.get(b.id))?.folderId).toBeNull();
    await chatsRepo.remove(b.id);
    expect(await messagesRepo.list(b.id)).toEqual([]);
  });

  it('restores the chat model, effort and settings when reopened', async () => {
    const c = await chatsRepo.create({ modelRef: { source: 'cloud', providerId: 'p', modelId: 'm' }, effort: 'high', settings: { fileToolsRootId: 'r1' } });
    const again = await chatsRepo.get(c.id);
    expect(again?.modelRef).toEqual({ source: 'cloud', providerId: 'p', modelId: 'm' });
    expect(again?.effort).toBe('high');
    expect(again?.settings.fileToolsRootId).toBe('r1');
  });
});

describe('migrations and recovery', () => {
  it('migrations are idempotent', async () => {
    const d = await freshDb();
    expect(await migrate(d)).toEqual([]);
  });

  it('marks interrupted work after an unexpected termination', async () => {
    await freshDb();
    const c = await chatsRepo.create();
    const m = await msg(c.id, 'assistant', 'partial ans', 'streaming');
    await tasksRepo.save({ id: 't1', kind: 'image', status: 'running', modelRef: { source: 'local', modelId: 'x' }, params: {}, progress: 0.4, progressLabel: null, error: null, resultAssetIds: [], chatId: null, externalId: null, createdAt: 1, updatedAt: 1 });
    await tasksRepo.save({ id: 't2', kind: 'video', status: 'running', modelRef: { source: 'cloud', providerId: 'p', modelId: 'sora-2' }, params: {}, progress: 0.4, progressLabel: null, error: null, resultAssetIds: [], chatId: null, externalId: 'video_123', createdAt: 1, updatedAt: 1 });
    await recoverAfterRestart(db());
    const [after] = await messagesRepo.byIds([m.id]);
    expect(after.status).toBe('error');
    expect(after.meta.interrupted).toBe(1);
    expect(after.content).toBe('partial ans'); // partial text is kept
    expect((await tasksRepo.get('t1'))?.status).toBe('interrupted');
    expect((await tasksRepo.get('t2'))?.status).toBe('running'); // cloud job keeps its id and resumes polling
  });

  it('settings round-trip and preserveOriginals cannot be disabled', async () => {
    await freshDb();
    await saveSettings({ ...DEFAULT_SETTINGS, theme: 'dark', context: { ...DEFAULT_SETTINGS.context, preserveOriginals: false as unknown as true } });
    const s = await loadSettings();
    expect(s.theme).toBe('dark');
    expect(s.context.preserveOriginals).toBe(true);
  });

  it('summaries keep links to their original messages and batches', async () => {
    await freshDb();
    const c = await chatsRepo.create();
    const m1 = await msg(c.id, 'user', 'a'); const m2 = await msg(c.id, 'assistant', 'b');
    await contextRepo.saveBatchWithSummary(
      { id: 'b1', chatId: c.id, startSeq: 1, endSeq: 2, messageIds: [m1.id, m2.id], tokenCount: 10, status: 'summarised', createdAt: 1 },
      { id: 's1', chatId: c.id, batchId: 'b1', level: 1, parentSummaryIds: [], sourceMessageIds: [m1.id, m2.id], sourceBatchIds: ['b1'], content: 'sum', tokenCount: 2, verification: null, verified: true, modelRef: null, createdAt: 1, supersededBy: null },
      [],
    );
    const msgs = await messagesRepo.list(c.id);
    expect(msgs.map((m) => m.batchId)).toEqual(['b1', 'b1']);
    expect(msgs.map((m) => m.content)).toEqual(['a', 'b']); // originals untouched
    await contextRepo.saveRollup({ id: 's2', chatId: c.id, batchId: null, level: 2, parentSummaryIds: ['s1'], sourceMessageIds: [m1.id, m2.id], sourceBatchIds: ['b1'], content: 'roll', tokenCount: 1, verification: null, verified: true, modelRef: null, createdAt: 2, supersededBy: null });
    expect((await contextRepo.summaries(c.id)).map((s) => s.id)).toEqual(['s2']);
    expect((await contextRepo.summaries(c.id, true)).find((s) => s.id === 's1')?.supersededBy).toBe('s2');
  });
});

describe('Auto mode', () => {
  const local = (id: string, compat: LocalModel['compatibility'], size: number): LocalModel => ({
    id, category: 'chat', name: id, path: `models/chat/${id}.gguf`, format: 'gguf', sizeBytes: size, sha256: null, sourceUrl: null, license: null,
    attribution: null, quantization: 'Q4_K_M', architecture: 'llama', contextLength: 8192, parameters: null, compatibility: compat, compatibilityNotes: [],
    metadata: {}, installedAt: Date.now(), benchmark: null, settings: { contextLength: 4096 },
  });
  beforeEach(async () => {
    await freshDb();
    await providersRepo.save({ id: 'p1', category: 'chat', kind: 'openai', name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', keyAccount: 'a', keyMasked: '••••1', status: 'ok', lastTestedAt: 1, lastError: null, capabilities: ['chat'], defaultModel: 'gpt-5', options: {}, createdAt: 1 });
    await providersRepo.replaceModels('p1', [{ id: 'p1:gpt-5', providerId: 'p1', modelId: 'gpt-5', displayName: 'GPT-5', capabilities: ['chat', 'tool_calling'], contextLength: 400000, outputLimit: null, metadata: {}, fetchedAt: 1 }]);
  });

  it('prefers a compatible offline model and never picks cloud without permission', async () => {
    await modelsRepo.save(local('small', 'compatible', 1e9));
    await modelsRepo.save(local('huge', 'unsupported', 9e9));
    const d = await autoSelect('agent', 'Analyze and design a step by step migration plan, compare trade-offs', { allowCloud: false, online: true });
    expect(d.choice?.source).toBe('local');
    expect(d.choice?.name).toBe('small');
  });

  it('returns only a suggestion (no choice) when no offline model exists and cloud is not allowed', async () => {
    const d = await autoSelect('agent', 'hello', { allowCloud: false, online: true });
    expect(d.choice).toBeNull();
    expect(d.cloudSuggestion?.name).toBe('GPT-5');
  });

  it('uses cloud only when explicitly allowed', async () => {
    const d = await autoSelect('agent', 'hello', { allowCloud: true, online: true });
    expect(d.choice?.source).toBe('cloud');
  });

  it('offers no cloud suggestion while offline', async () => {
    const d = await autoSelect('agent', 'hello', { allowCloud: true, online: false });
    expect(d.choice).toBeNull();
    expect(d.cloudSuggestion).toBeNull();
  });
});
