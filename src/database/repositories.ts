// Typed repositories over the SQLite schema. JSON columns are (de)serialised here only.
import { db } from './index';
import type { SqlValue, Statement } from './driver';
import type {
  Asset, Batch, Chat, ChatFolder, ChatMessage, DownloadRecord, FileOperation, GenerationTask, LocalModel,
  MemoryRecord, Provider, ProviderModel, Summary,
} from '@/types';

type Row = Record<string, unknown>;
const j = <T>(v: unknown, fallback: T): T => {
  if (v === null || v === undefined || v === '') return fallback;
  try { return JSON.parse(String(v)) as T; } catch { return fallback; }
};
const s = (v: unknown) => JSON.stringify(v ?? null);
const n = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
const b = (v: unknown) => Number(v) === 1;

export const uid = () =>
  (globalThis.crypto?.randomUUID?.() ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`).replace(/[^A-Za-z0-9-]/g, '');

// ---------------------------------------------------------------------------------------------
// Chats & folders

const toChat = (r: Row): Chat => ({
  id: String(r.id), title: String(r.title), titleAuto: b(r.title_auto), folderId: (r.folder_id as string) ?? null,
  pinned: b(r.pinned), archived: b(r.archived), createdAt: Number(r.created_at), updatedAt: Number(r.updated_at),
  modelRef: j(r.model_ref, null), effort: (r.effort as Chat['effort']) ?? null, settings: j(r.settings, {}),
});

export const chatsRepo = {
  async list(opts: { archived?: boolean; search?: string } = {}): Promise<Chat[]> {
    const where: string[] = ['archived = ?'];
    const vals: SqlValue[] = [opts.archived ? 1 : 0];
    if (opts.search?.trim()) {
      where.push(`(title LIKE ? OR id IN (SELECT chat_id FROM messages WHERE content LIKE ? AND role IN ('user','assistant')))`);
      const like = `%${opts.search.trim()}%`;
      vals.push(like, like);
    }
    const rows = await db().query<Row>(`SELECT * FROM chats WHERE ${where.join(' AND ')} ORDER BY pinned DESC, updated_at DESC`, vals);
    return rows.map(toChat);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM chats WHERE id = ?', [id]);
    return r ? toChat(r) : null;
  },
  async create(partial: Partial<Chat> = {}): Promise<Chat> {
    const now = Date.now();
    const chat: Chat = {
      id: uid(), title: partial.title ?? 'New chat', titleAuto: partial.titleAuto ?? true, folderId: partial.folderId ?? null,
      pinned: false, archived: false, createdAt: now, updatedAt: now, modelRef: partial.modelRef ?? null,
      effort: partial.effort ?? null, settings: partial.settings ?? {},
    };
    await db().run(
      'INSERT INTO chats (id,title,title_auto,folder_id,pinned,archived,created_at,updated_at,model_ref,effort,settings) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [chat.id, chat.title, chat.titleAuto ? 1 : 0, chat.folderId, 0, 0, now, now, s(chat.modelRef), chat.effort, s(chat.settings)],
    );
    return chat;
  },
  async update(id: string, patch: Partial<Omit<Chat, 'id' | 'createdAt'>>) {
    const cols: string[] = [];
    const vals: SqlValue[] = [];
    const map: Record<string, [string, (v: unknown) => SqlValue]> = {
      title: ['title', (v) => String(v)], titleAuto: ['title_auto', (v) => (v ? 1 : 0)], folderId: ['folder_id', (v) => (v as string) ?? null],
      pinned: ['pinned', (v) => (v ? 1 : 0)], archived: ['archived', (v) => (v ? 1 : 0)], modelRef: ['model_ref', s],
      effort: ['effort', (v) => (v as string) ?? null], settings: ['settings', s], updatedAt: ['updated_at', (v) => Number(v)],
    };
    for (const [k, v] of Object.entries(patch)) {
      const m = map[k];
      if (m) { cols.push(`${m[0]} = ?`); vals.push(m[1](v)); }
    }
    if (!('updatedAt' in patch)) { cols.push('updated_at = ?'); vals.push(Date.now()); }
    if (!cols.length) return;
    vals.push(id);
    await db().run(`UPDATE chats SET ${cols.join(', ')} WHERE id = ?`, vals);
  },
  async remove(id: string) {
    await db().run('DELETE FROM chats WHERE id = ?', [id]);
  },
};

export const foldersRepo = {
  async list(): Promise<ChatFolder[]> {
    return (await db().query<Row>('SELECT * FROM chat_folders ORDER BY name')).map((r) => ({ id: String(r.id), name: String(r.name), createdAt: Number(r.created_at) }));
  },
  async create(name: string): Promise<ChatFolder> {
    const f = { id: uid(), name: name.trim() || 'Folder', createdAt: Date.now() };
    await db().run('INSERT INTO chat_folders (id,name,created_at) VALUES (?,?,?)', [f.id, f.name, f.createdAt]);
    return f;
  },
  async rename(id: string, name: string) { await db().run('UPDATE chat_folders SET name = ? WHERE id = ?', [name, id]); },
  async remove(id: string) {
    await db().batch([
      { sql: 'UPDATE chats SET folder_id = NULL WHERE folder_id = ?', values: [id] },
      { sql: 'DELETE FROM chat_folders WHERE id = ?', values: [id] },
    ]);
  },
};

// ---------------------------------------------------------------------------------------------
// Messages

const toMessage = (r: Row): ChatMessage => ({
  id: String(r.id), chatId: String(r.chat_id), seq: Number(r.seq), role: r.role as ChatMessage['role'], content: String(r.content),
  reasoning: (r.reasoning as string) ?? null, createdAt: Number(r.created_at), tokenCount: n(r.token_count), tokenExact: b(r.token_exact),
  tokenModel: (r.token_model as string) ?? null, batchId: (r.batch_id as string) ?? null, status: r.status as ChatMessage['status'],
  modelRef: j(r.model_ref, null), attachments: j(r.attachments, []), toolCalls: j(r.tool_calls, []),
  toolCallId: (r.tool_call_id as string) ?? null, toolName: (r.tool_name as string) ?? null, meta: j(r.meta, {}),
});

export const messagesRepo = {
  async list(chatId: string): Promise<ChatMessage[]> {
    return (await db().query<Row>('SELECT * FROM messages WHERE chat_id = ? ORDER BY seq', [chatId])).map(toMessage);
  },
  async byIds(ids: string[]): Promise<ChatMessage[]> {
    if (!ids.length) return [];
    const ph = ids.map(() => '?').join(',');
    return (await db().query<Row>(`SELECT * FROM messages WHERE id IN (${ph}) ORDER BY seq`, ids)).map(toMessage);
  },
  async nextSeq(chatId: string): Promise<number> {
    const [r] = await db().query<Row>('SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM messages WHERE chat_id = ?', [chatId]);
    return Number(r?.next ?? 1);
  },
  async insert(m: Omit<ChatMessage, 'id' | 'seq' | 'createdAt'> & Partial<Pick<ChatMessage, 'id' | 'seq' | 'createdAt'>>): Promise<ChatMessage> {
    const msg: ChatMessage = { ...m, id: m.id ?? uid(), seq: m.seq ?? (await messagesRepo.nextSeq(m.chatId)), createdAt: m.createdAt ?? Date.now() } as ChatMessage;
    await db().run(
      `INSERT INTO messages (id,chat_id,seq,role,content,reasoning,created_at,token_count,token_exact,token_model,batch_id,status,model_ref,attachments,tool_calls,tool_call_id,tool_name,meta)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [msg.id, msg.chatId, msg.seq, msg.role, msg.content, msg.reasoning, msg.createdAt, msg.tokenCount, msg.tokenExact ? 1 : 0,
        msg.tokenModel, msg.batchId, msg.status, s(msg.modelRef), s(msg.attachments), s(msg.toolCalls), msg.toolCallId, msg.toolName, s(msg.meta)],
    );
    await db().run('UPDATE chats SET updated_at = ? WHERE id = ?', [Date.now(), msg.chatId]);
    return msg;
  },
  async update(id: string, patch: Partial<Pick<ChatMessage, 'content' | 'reasoning' | 'status' | 'tokenCount' | 'tokenExact' | 'tokenModel' | 'batchId' | 'toolCalls' | 'meta' | 'attachments'>>) {
    const cols: string[] = []; const vals: SqlValue[] = [];
    if (patch.content !== undefined) { cols.push('content = ?'); vals.push(patch.content); }
    if (patch.reasoning !== undefined) { cols.push('reasoning = ?'); vals.push(patch.reasoning); }
    if (patch.status !== undefined) { cols.push('status = ?'); vals.push(patch.status); }
    if (patch.tokenCount !== undefined) { cols.push('token_count = ?'); vals.push(patch.tokenCount); }
    if (patch.tokenExact !== undefined) { cols.push('token_exact = ?'); vals.push(patch.tokenExact ? 1 : 0); }
    if (patch.tokenModel !== undefined) { cols.push('token_model = ?'); vals.push(patch.tokenModel); }
    if (patch.batchId !== undefined) { cols.push('batch_id = ?'); vals.push(patch.batchId); }
    if (patch.toolCalls !== undefined) { cols.push('tool_calls = ?'); vals.push(s(patch.toolCalls)); }
    if (patch.meta !== undefined) { cols.push('meta = ?'); vals.push(s(patch.meta)); }
    if (patch.attachments !== undefined) { cols.push('attachments = ?'); vals.push(s(patch.attachments)); }
    if (!cols.length) return;
    vals.push(id);
    await db().run(`UPDATE messages SET ${cols.join(', ')} WHERE id = ?`, vals);
  },
  async setTokenCounts(updates: { id: string; count: number; exact: boolean; model: string }[]) {
    if (!updates.length) return;
    await db().batch(updates.map((u) => ({ sql: 'UPDATE messages SET token_count=?, token_exact=?, token_model=? WHERE id=?', values: [u.count, u.exact ? 1 : 0, u.model, u.id] })));
  },
};

// ---------------------------------------------------------------------------------------------
// Batches, summaries, memory (SmartContextEngine persistence)

const toBatch = (r: Row): Batch => ({
  id: String(r.id), chatId: String(r.chat_id), startSeq: Number(r.start_seq), endSeq: Number(r.end_seq),
  messageIds: j(r.message_ids, []), tokenCount: Number(r.token_count), status: r.status as Batch['status'], createdAt: Number(r.created_at),
});
const toSummary = (r: Row): Summary => ({
  id: String(r.id), chatId: String(r.chat_id), batchId: (r.batch_id as string) ?? null, level: Number(r.level),
  parentSummaryIds: j(r.parent_summary_ids, []), sourceMessageIds: j(r.source_message_ids, []), sourceBatchIds: j(r.source_batch_ids, []),
  content: String(r.content), tokenCount: Number(r.token_count), verification: j(r.verification, null), verified: b(r.verified),
  modelRef: j(r.model_ref, null), createdAt: Number(r.created_at), supersededBy: (r.superseded_by as string) ?? null,
});
const toMemory = (r: Row): MemoryRecord => ({
  id: String(r.id), chatId: (r.chat_id as string) ?? null, kind: r.kind as MemoryRecord['kind'], content: String(r.content),
  sourceMessageIds: j(r.source_message_ids, []), pinned: b(r.pinned), active: b(r.active), createdAt: Number(r.created_at), updatedAt: Number(r.updated_at),
});

export const contextRepo = {
  async batches(chatId: string): Promise<Batch[]> {
    return (await db().query<Row>('SELECT * FROM batches WHERE chat_id = ? ORDER BY start_seq', [chatId])).map(toBatch);
  },
  async summaries(chatId: string, includeSuperseded = false): Promise<Summary[]> {
    const sql = includeSuperseded
      ? 'SELECT * FROM summaries WHERE chat_id = ? ORDER BY created_at'
      : 'SELECT * FROM summaries WHERE chat_id = ? AND superseded_by IS NULL ORDER BY created_at';
    return (await db().query<Row>(sql, [chatId])).map(toSummary);
  },
  async memory(chatId: string | null): Promise<MemoryRecord[]> {
    const rows = await db().query<Row>('SELECT * FROM memory_records WHERE active = 1 AND (chat_id = ? OR chat_id IS NULL) ORDER BY pinned DESC, updated_at DESC', [chatId]);
    return rows.map(toMemory);
  },
  async allMemory(): Promise<MemoryRecord[]> {
    return (await db().query<Row>('SELECT * FROM memory_records ORDER BY updated_at DESC')).map(toMemory);
  },
  /** Persist a batch + its summary atomically and link the original messages to the batch. */
  async saveBatchWithSummary(batch: Batch, summary: Summary | null, memories: MemoryRecord[]) {
    const st: Statement[] = [
      { sql: 'INSERT OR REPLACE INTO batches (id,chat_id,start_seq,end_seq,message_ids,token_count,status,created_at) VALUES (?,?,?,?,?,?,?,?)',
        values: [batch.id, batch.chatId, batch.startSeq, batch.endSeq, s(batch.messageIds), batch.tokenCount, batch.status, batch.createdAt] },
      ...batch.messageIds.map((id) => ({ sql: 'UPDATE messages SET batch_id = ? WHERE id = ?', values: [batch.id, id] as SqlValue[] })),
    ];
    if (summary) st.push(summaryInsert(summary));
    for (const m of memories) st.push(memoryUpsert(m));
    await db().batch(st);
  },
  /** Store a higher-level summary and mark its children as superseded (children are kept). */
  async saveRollup(summary: Summary) {
    await db().batch([
      summaryInsert(summary),
      ...summary.parentSummaryIds.map((id) => ({ sql: 'UPDATE summaries SET superseded_by = ? WHERE id = ?', values: [summary.id, id] as SqlValue[] })),
    ]);
  },
  async upsertMemory(m: MemoryRecord) { await db().batch([memoryUpsert(m)]); },
  async deleteMemory(id: string) { await db().run('DELETE FROM memory_records WHERE id = ?', [id]); },
};

function summaryInsert(x: Summary): Statement {
  return {
    sql: `INSERT OR REPLACE INTO summaries (id,chat_id,batch_id,level,parent_summary_ids,source_message_ids,source_batch_ids,content,token_count,verification,verified,model_ref,created_at,superseded_by)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
    values: [x.id, x.chatId, x.batchId, x.level, s(x.parentSummaryIds), s(x.sourceMessageIds), s(x.sourceBatchIds), x.content, x.tokenCount,
      s(x.verification), x.verified ? 1 : 0, s(x.modelRef), x.createdAt, x.supersededBy],
  };
}
function memoryUpsert(m: MemoryRecord): Statement {
  return {
    sql: `INSERT OR REPLACE INTO memory_records (id,chat_id,kind,content,source_message_ids,pinned,active,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)`,
    values: [m.id, m.chatId, m.kind, m.content, s(m.sourceMessageIds), m.pinned ? 1 : 0, m.active ? 1 : 0, m.createdAt, m.updatedAt],
  };
}

// ---------------------------------------------------------------------------------------------
// Local models

const toModel = (r: Row): LocalModel => ({
  id: String(r.id), category: r.category as LocalModel['category'], name: String(r.name), path: String(r.path), format: r.format as LocalModel['format'],
  sizeBytes: Number(r.size_bytes), sha256: (r.sha256 as string) ?? null, sourceUrl: (r.source_url as string) ?? null, license: (r.license as string) ?? null,
  attribution: (r.attribution as string) ?? null, quantization: (r.quantization as string) ?? null, architecture: (r.architecture as string) ?? null,
  contextLength: n(r.context_length), parameters: n(r.parameters), compatibility: r.compatibility as LocalModel['compatibility'],
  compatibilityNotes: j(r.compatibility_notes, []), metadata: j(r.metadata, {}), installedAt: Number(r.installed_at), benchmark: j(r.benchmark, null),
  settings: j(r.settings, {}),
});

export const modelsRepo = {
  async list(category?: LocalModel['category']): Promise<LocalModel[]> {
    const rows = category
      ? await db().query<Row>('SELECT * FROM models WHERE category = ? ORDER BY installed_at DESC', [category])
      : await db().query<Row>('SELECT * FROM models ORDER BY installed_at DESC');
    return rows.map(toModel);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM models WHERE id = ?', [id]);
    return r ? toModel(r) : null;
  },
  async save(m: LocalModel) {
    await db().run(
      `INSERT OR REPLACE INTO models (id,category,name,path,format,size_bytes,sha256,source_url,license,attribution,quantization,architecture,context_length,parameters,compatibility,compatibility_notes,metadata,installed_at,benchmark,settings)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [m.id, m.category, m.name, m.path, m.format, m.sizeBytes, m.sha256, m.sourceUrl, m.license, m.attribution, m.quantization, m.architecture,
        m.contextLength, m.parameters, m.compatibility, s(m.compatibilityNotes), s(m.metadata), m.installedAt, s(m.benchmark), s(m.settings)],
    );
  },
  async remove(id: string) { await db().run('DELETE FROM models WHERE id = ?', [id]); },
};

// ---------------------------------------------------------------------------------------------
// Providers

const toProvider = (r: Row): Provider => ({
  id: String(r.id), category: r.category as Provider['category'], kind: r.kind as Provider['kind'], name: String(r.name), baseUrl: String(r.base_url),
  keyAccount: String(r.key_account), keyMasked: (r.key_masked as string) ?? null, status: r.status as Provider['status'],
  lastTestedAt: n(r.last_tested_at), lastError: (r.last_error as string) ?? null, capabilities: j(r.capabilities, []),
  defaultModel: (r.default_model as string) ?? null, options: j(r.options, {}), createdAt: Number(r.created_at),
});
const toProviderModel = (r: Row): ProviderModel => ({
  id: String(r.id), providerId: String(r.provider_id), modelId: String(r.model_id), displayName: String(r.display_name),
  capabilities: j(r.capabilities, []), contextLength: n(r.context_length), outputLimit: n(r.output_limit), metadata: j(r.metadata, {}), fetchedAt: Number(r.fetched_at),
});

export const providersRepo = {
  async list(category?: Provider['category']): Promise<Provider[]> {
    const rows = category
      ? await db().query<Row>('SELECT * FROM providers WHERE category = ? ORDER BY created_at', [category])
      : await db().query<Row>('SELECT * FROM providers ORDER BY created_at');
    return rows.map(toProvider);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM providers WHERE id = ?', [id]);
    return r ? toProvider(r) : null;
  },
  async save(p: Provider) {
    await db().run(
      // A true upsert: INSERT OR REPLACE would delete the row first and cascade-delete its provider_models.
      `INSERT INTO providers (id,category,kind,name,base_url,key_account,key_masked,status,last_tested_at,last_error,capabilities,default_model,options,created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
       ON CONFLICT(id) DO UPDATE SET category=excluded.category, kind=excluded.kind, name=excluded.name, base_url=excluded.base_url,
         key_account=excluded.key_account, key_masked=excluded.key_masked, status=excluded.status, last_tested_at=excluded.last_tested_at,
         last_error=excluded.last_error, capabilities=excluded.capabilities, default_model=excluded.default_model, options=excluded.options`,
      [p.id, p.category, p.kind, p.name, p.baseUrl, p.keyAccount, p.keyMasked, p.status, p.lastTestedAt, p.lastError, s(p.capabilities), p.defaultModel, s(p.options), p.createdAt],
    );
  },
  async remove(id: string) { await db().run('DELETE FROM providers WHERE id = ?', [id]); },
  async models(providerId?: string): Promise<ProviderModel[]> {
    const rows = providerId
      ? await db().query<Row>('SELECT * FROM provider_models WHERE provider_id = ? ORDER BY display_name', [providerId])
      : await db().query<Row>('SELECT * FROM provider_models ORDER BY display_name');
    return rows.map(toProviderModel);
  },
  async replaceModels(providerId: string, models: ProviderModel[]) {
    await db().batch([
      { sql: 'DELETE FROM provider_models WHERE provider_id = ?', values: [providerId] },
      ...models.map((m) => ({
        sql: 'INSERT INTO provider_models (id,provider_id,model_id,display_name,capabilities,context_length,output_limit,metadata,fetched_at) VALUES (?,?,?,?,?,?,?,?,?)',
        values: [m.id, providerId, m.modelId, m.displayName, s(m.capabilities), m.contextLength, m.outputLimit, s(m.metadata), m.fetchedAt] as SqlValue[],
      })),
    ]);
  },
};

// ---------------------------------------------------------------------------------------------
// Generation tasks & assets

const toTask = (r: Row): GenerationTask => ({
  id: String(r.id), kind: r.kind as GenerationTask['kind'], status: r.status as GenerationTask['status'], modelRef: j(r.model_ref, { source: 'auto' }),
  params: j(r.params, {}), progress: Number(r.progress), progressLabel: (r.progress_label as string) ?? null, error: (r.error as string) ?? null,
  resultAssetIds: j(r.result_asset_ids, []), chatId: (r.chat_id as string) ?? null, externalId: (r.external_id as string) ?? null,
  createdAt: Number(r.created_at), updatedAt: Number(r.updated_at),
});
const toAsset = (r: Row): Asset => ({
  id: String(r.id), kind: r.kind as Asset['kind'], name: String(r.name), path: String(r.path), mime: String(r.mime), sizeBytes: Number(r.size_bytes),
  width: n(r.width), height: n(r.height), durationSec: n(r.duration_sec), chatId: (r.chat_id as string) ?? null, messageId: (r.message_id as string) ?? null,
  taskId: (r.task_id as string) ?? null, parentAssetId: (r.parent_asset_id as string) ?? null, metadata: j(r.metadata, {}), createdAt: Number(r.created_at),
});

export const tasksRepo = {
  async list(kind?: GenerationTask['kind'], limit = 100): Promise<GenerationTask[]> {
    const rows = kind
      ? await db().query<Row>('SELECT * FROM generation_tasks WHERE kind = ? ORDER BY created_at DESC LIMIT ?', [kind, limit])
      : await db().query<Row>('SELECT * FROM generation_tasks ORDER BY created_at DESC LIMIT ?', [limit]);
    return rows.map(toTask);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM generation_tasks WHERE id = ?', [id]);
    return r ? toTask(r) : null;
  },
  async save(t: GenerationTask) {
    await db().run(
      `INSERT OR REPLACE INTO generation_tasks (id,kind,status,model_ref,params,progress,progress_label,error,result_asset_ids,chat_id,external_id,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [t.id, t.kind, t.status, s(t.modelRef), s(t.params), t.progress, t.progressLabel, t.error, s(t.resultAssetIds), t.chatId, t.externalId, t.createdAt, t.updatedAt],
    );
  },
  async remove(id: string) { await db().run('DELETE FROM generation_tasks WHERE id = ?', [id]); },
};

export const assetsRepo = {
  async list(opts: { kind?: Asset['kind']; search?: string; chatId?: string } = {}): Promise<Asset[]> {
    const where: string[] = []; const vals: SqlValue[] = [];
    if (opts.kind) { where.push('kind = ?'); vals.push(opts.kind); }
    if (opts.chatId) { where.push('chat_id = ?'); vals.push(opts.chatId); }
    if (opts.search?.trim()) { where.push('(name LIKE ? OR metadata LIKE ?)'); vals.push(`%${opts.search.trim()}%`, `%${opts.search.trim()}%`); }
    const sql = `SELECT * FROM assets ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY created_at DESC`;
    return (await db().query<Row>(sql, vals)).map(toAsset);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM assets WHERE id = ?', [id]);
    return r ? toAsset(r) : null;
  },
  async byIds(ids: string[]) {
    if (!ids.length) return [];
    return (await db().query<Row>(`SELECT * FROM assets WHERE id IN (${ids.map(() => '?').join(',')})`, ids)).map(toAsset);
  },
  async save(a: Asset) {
    await db().run(
      `INSERT OR REPLACE INTO assets (id,kind,name,path,mime,size_bytes,width,height,duration_sec,chat_id,message_id,task_id,parent_asset_id,metadata,created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [a.id, a.kind, a.name, a.path, a.mime, a.sizeBytes, a.width, a.height, a.durationSec, a.chatId, a.messageId, a.taskId, a.parentAssetId, s(a.metadata), a.createdAt],
    );
  },
  async rename(id: string, name: string) { await db().run('UPDATE assets SET name = ? WHERE id = ?', [name, id]); },
  async remove(id: string) { await db().run('DELETE FROM assets WHERE id = ?', [id]); },
};

// ---------------------------------------------------------------------------------------------
// File operation journal, downloads, settings

const toFileOp = (r: Row): FileOperation => ({
  id: String(r.id), rootId: String(r.root_id), op: r.op as FileOperation['op'], srcPath: String(r.src_path), dstPath: (r.dst_path as string) ?? null,
  status: r.status as FileOperation['status'], groupId: (r.group_id as string) ?? null, chatId: (r.chat_id as string) ?? null,
  metadata: j(r.metadata, {}), createdAt: Number(r.created_at), undoneAt: n(r.undone_at),
});

export const fileOpsRepo = {
  async list(limit = 200): Promise<FileOperation[]> {
    return (await db().query<Row>('SELECT * FROM file_operations ORDER BY created_at DESC LIMIT ?', [limit])).map(toFileOp);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM file_operations WHERE id = ?', [id]);
    return r ? toFileOp(r) : null;
  },
  async group(groupId: string) {
    return (await db().query<Row>('SELECT * FROM file_operations WHERE group_id = ? ORDER BY created_at DESC', [groupId])).map(toFileOp);
  },
  async insert(op: FileOperation) {
    await db().run(
      'INSERT INTO file_operations (id,root_id,op,src_path,dst_path,status,group_id,chat_id,metadata,created_at,undone_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [op.id, op.rootId, op.op, op.srcPath, op.dstPath, op.status, op.groupId, op.chatId, s(op.metadata), op.createdAt, op.undoneAt],
    );
  },
  async markUndone(id: string) { await db().run("UPDATE file_operations SET status='undone', undone_at=? WHERE id=?", [Date.now(), id]); },
};

const toDownload = (r: Row): DownloadRecord => ({
  id: String(r.id), category: r.category as DownloadRecord['category'], name: String(r.name), url: String(r.url), destPath: String(r.dest_path),
  totalBytes: n(r.total_bytes), receivedBytes: Number(r.received_bytes), sha256Expected: (r.sha256_expected as string) ?? null,
  status: r.status as DownloadRecord['status'], error: (r.error as string) ?? null, meta: j(r.meta, {}), createdAt: Number(r.created_at), updatedAt: Number(r.updated_at),
});

export const downloadsRepo = {
  async list(): Promise<DownloadRecord[]> {
    return (await db().query<Row>('SELECT * FROM downloads ORDER BY created_at DESC')).map(toDownload);
  },
  async get(id: string) {
    const [r] = await db().query<Row>('SELECT * FROM downloads WHERE id = ?', [id]);
    return r ? toDownload(r) : null;
  },
  async save(d: DownloadRecord) {
    await db().run(
      `INSERT OR REPLACE INTO downloads (id,category,name,url,dest_path,total_bytes,received_bytes,sha256_expected,status,error,meta,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [d.id, d.category, d.name, d.url, d.destPath, d.totalBytes, d.receivedBytes, d.sha256Expected, d.status, d.error, s(d.meta), d.createdAt, d.updatedAt],
    );
  },
  async remove(id: string) { await db().run('DELETE FROM downloads WHERE id = ?', [id]); },
};

export const settingsRepo = {
  async all(): Promise<Record<string, unknown>> {
    const rows = await db().query<Row>('SELECT key, value FROM settings');
    return Object.fromEntries(rows.map((r) => [String(r.key), j(r.value, null)]));
  },
  async set(key: string, value: unknown) {
    await db().run('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', [key, s(value)]);
  },
};
