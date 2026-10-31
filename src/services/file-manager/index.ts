// AI file manager. The model never touches the file system: it requests structured tools, this
// executor validates them, applies the safety policy, and calls the native plugin, which validates
// every path again against the authorised folder. All changes are journaled for undo.
import type { FileOperation } from '@/types';
import { ZinoFiles, type FileEntry } from '@/native';
import { fileOpsRepo, uid } from '@/database/repositories';
import { ZinoError, toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import type { ToolDefinition } from '@/providers/types';

export const FILE_CATEGORIES: Record<string, string[]> = {
  Images: ['png', 'jpg', 'jpeg', 'heic', 'heif', 'webp', 'gif', 'tif', 'tiff', 'bmp', 'svg', 'raw', 'dng'],
  '3D Models': ['glb', 'gltf', 'obj', 'fbx', 'usdz', 'usd', 'stl', 'ply', '3mf', 'blend', 'dae'],
  Documents: ['pdf', 'doc', 'docx', 'txt', 'md', 'rtf', 'pages', 'odt', 'xls', 'xlsx', 'csv', 'numbers', 'ppt', 'pptx', 'key', 'json'],
  Videos: ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm'],
  Audio: ['mp3', 'm4a', 'wav', 'aac', 'flac', 'aiff'],
  Archives: ['zip', 'rar', '7z', 'tar', 'gz'],
};
const KIND_ALIASES: Record<string, string> = { image: 'Images', images: 'Images', model3d: '3D Models', '3d': '3D Models', pdf: 'pdf', document: 'Documents', documents: 'Documents', video: 'Videos', videos: 'Videos', audio: 'Audio' };

export function categoryOf(ext: string): string {
  for (const [cat, exts] of Object.entries(FILE_CATEGORIES)) if (exts.includes(ext.toLowerCase())) return cat;
  return 'Other';
}

/** Defense in depth: the native layer re-validates, but reject obviously bad paths early. */
export function cleanPath(p: unknown, allowEmpty = true): string {
  if (p === undefined || p === null || p === '' || p === '.' || p === '/') {
    if (allowEmpty) return '';
    throw new ZinoError('INVALID_PATH', 'A path is required.');
  }
  if (typeof p !== 'string') throw new ZinoError('INVALID_PATH', 'Paths must be strings.');
  const parts = p.replace(/\\/g, '/').split('/').filter((x) => x && x !== '.');
  if (parts.some((x) => x === '..')) throw new ZinoError('PATH_OUTSIDE_FOLDER', 'Paths may not contain "..".');
  if (/^[a-z]+:/i.test(p) || p.includes('\0')) throw new ZinoError('INVALID_PATH', 'Only paths inside the authorised folder are allowed.');
  return parts.join('/');
}

export function validateName(name: unknown): string {
  if (typeof name !== 'string' || !name.trim() || name === '.' || name === '..' || /[/:\0]/.test(name) || name.length > 255) {
    throw new ZinoError('INVALID_NAME', 'Invalid file name. Names cannot be empty or contain "/" or ":".');
  }
  return name.trim();
}

const dirname = (p: string) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '');
const basename = (p: string) => p.split('/').pop() ?? p;

// ---------------------------------------------------------------------------------------------
// Tool schema exposed to models

const str = (description: string) => ({ type: 'string', description });
export const FILE_TOOLS: ToolDefinition[] = [
  { name: 'list_files', description: 'List files and folders in the authorised folder (paths are relative to it).',
    parameters: { type: 'object', properties: { path: str('Folder path, empty for the root'), recursive: { type: 'boolean' }, limit: { type: 'integer' } }, additionalProperties: false } },
  { name: 'search_files', description: 'Find files by name text and/or type. kind: image, model3d, pdf, document, video, audio.',
    parameters: { type: 'object', properties: { query: str('Text contained in the file name'), kind: str('File kind'), extensions: { type: 'array', items: { type: 'string' } }, path: str('Folder to search in') }, additionalProperties: false } },
  { name: 'read_file', description: 'Read a text or PDF document (truncated for large files).',
    parameters: { type: 'object', properties: { path: str('File path'), max_chars: { type: 'integer' } }, required: ['path'], additionalProperties: false } },
  { name: 'file_info', description: 'Get size and dates of a file or folder.',
    parameters: { type: 'object', properties: { path: str('Path') }, required: ['path'], additionalProperties: false } },
  { name: 'create_folder', description: 'Create a new folder.',
    parameters: { type: 'object', properties: { path: str('New folder path') }, required: ['path'], additionalProperties: false } },
  { name: 'rename_item', description: 'Rename one file or folder (never overwrites).',
    parameters: { type: 'object', properties: { path: str('Existing path'), new_name: str('New name only, not a path') }, required: ['path', 'new_name'], additionalProperties: false } },
  { name: 'move_items', description: 'Move files/folders into a destination folder (never overwrites).',
    parameters: { type: 'object', properties: { paths: { type: 'array', items: { type: 'string' } }, destination: str('Destination folder (created if missing)') }, required: ['paths', 'destination'], additionalProperties: false } },
  { name: 'copy_items', description: 'Copy files/folders into a destination folder (copies get unique names if needed).',
    parameters: { type: 'object', properties: { paths: { type: 'array', items: { type: 'string' } }, destination: str('Destination folder') }, required: ['paths', 'destination'], additionalProperties: false } },
  { name: 'delete_items', description: 'Move items to the ZinoAgent Trash inside the folder (reversible). Always asks the user.',
    parameters: { type: 'object', properties: { paths: { type: 'array', items: { type: 'string' } } }, required: ['paths'], additionalProperties: false } },
  { name: 'find_duplicates', description: 'Find files with identical content (SHA-256).',
    parameters: { type: 'object', properties: { path: str('Folder'), kind: str('Optional file kind filter') }, additionalProperties: false } },
  { name: 'storage_report', description: 'Report storage usage by file type and the largest files.',
    parameters: { type: 'object', properties: { path: str('Folder') }, additionalProperties: false } },
  { name: 'organize_by_type', description: 'Plan (and after user approval, perform) moving files into folders by type: Images, 3D Models, Documents, Videos, Audio, Archives.',
    parameters: { type: 'object', properties: { path: str('Folder to organise'), recursive: { type: 'boolean' } }, additionalProperties: false } },
];

// ---------------------------------------------------------------------------------------------
// Journal + low-level operations (also used directly by the File Explorer UI)

async function journal(op: Omit<FileOperation, 'id' | 'createdAt' | 'undoneAt' | 'status'> & { status?: FileOperation['status'] }) {
  const rec: FileOperation = { ...op, id: uid(), status: op.status ?? 'done', createdAt: Date.now(), undoneAt: null };
  await fileOpsRepo.insert(rec);
  return rec;
}

export interface OpContext { rootId: string; chatId?: string | null; groupId?: string | null }

async function ensureFolder(ctx: OpContext, path: string): Promise<boolean> {
  if (!path) return false;
  const s = await ZinoFiles.stat({ rootId: ctx.rootId, path });
  if (s.exists) {
    if (!s.isDirectory) throw new ZinoError('FILE_EXISTS', `"${path}" exists and is not a folder.`);
    return false;
  }
  await ZinoFiles.mkdir({ rootId: ctx.rootId, path });
  await journal({ rootId: ctx.rootId, op: 'mkdir', srcPath: path, dstPath: null, groupId: ctx.groupId ?? null, chatId: ctx.chatId ?? null, metadata: {} });
  return true;
}

export const fileOps = {
  async mkdir(ctx: OpContext, path: string) {
    const p = cleanPath(path, false);
    validateName(basename(p));
    await ZinoFiles.mkdir({ rootId: ctx.rootId, path: p });
    return journal({ rootId: ctx.rootId, op: 'mkdir', srcPath: p, dstPath: null, groupId: ctx.groupId ?? null, chatId: ctx.chatId ?? null, metadata: {} });
  },
  async rename(ctx: OpContext, path: string, newName: string) {
    const r = await ZinoFiles.rename({ rootId: ctx.rootId, path: cleanPath(path, false), newName: validateName(newName) });
    return journal({ rootId: ctx.rootId, op: 'rename', srcPath: r.from, dstPath: r.to, groupId: ctx.groupId ?? null, chatId: ctx.chatId ?? null, metadata: {} });
  },
  async move(ctx: OpContext, path: string, destination: string) {
    const dest = cleanPath(destination);
    await ensureFolder(ctx, dest);
    const r = await ZinoFiles.move({ rootId: ctx.rootId, path: cleanPath(path, false), destinationDir: dest });
    return journal({ rootId: ctx.rootId, op: 'move', srcPath: r.from, dstPath: r.to, groupId: ctx.groupId ?? null, chatId: ctx.chatId ?? null, metadata: {} });
  },
  async copy(ctx: OpContext, path: string, destination: string) {
    const dest = cleanPath(destination);
    await ensureFolder(ctx, dest);
    const r = await ZinoFiles.copy({ rootId: ctx.rootId, path: cleanPath(path, false), destinationDir: dest });
    return journal({ rootId: ctx.rootId, op: 'copy', srcPath: r.from, dstPath: r.to, groupId: ctx.groupId ?? null, chatId: ctx.chatId ?? null, metadata: {} });
  },
  async trash(ctx: OpContext, path: string) {
    const r = await ZinoFiles.trash({ rootId: ctx.rootId, path: cleanPath(path, false) });
    return journal({ rootId: ctx.rootId, op: 'trash', srcPath: r.from, dstPath: r.to, groupId: ctx.groupId ?? null, chatId: ctx.chatId ?? null, metadata: {} });
  },
};

/** Undo one journaled operation after checking the current state of the files. */
export async function undoOperation(op: FileOperation): Promise<string> {
  if (op.status !== 'done') throw new ZinoError('INVALID_ARGUMENT', 'This operation was already undone.');
  const ctx = { rootId: op.rootId };
  switch (op.op) {
    case 'mkdir': {
      const list = await ZinoFiles.list({ rootId: op.rootId, path: op.srcPath, includeHidden: true }).catch(() => null);
      if (!list) throw new ZinoError('FILE_NOT_FOUND', `Folder "${op.srcPath}" no longer exists.`);
      if (list.entries.length) throw new ZinoError('NOT_EMPTY', `Folder "${op.srcPath}" is not empty any more, so it was left in place.`);
      await ZinoFiles.trash({ ...ctx, path: op.srcPath });
      break;
    }
    case 'rename':
      await ZinoFiles.rename({ ...ctx, path: op.dstPath!, newName: basename(op.srcPath) });
      break;
    case 'move':
      await ZinoFiles.move({ ...ctx, path: op.dstPath!, destinationDir: dirname(op.srcPath) });
      break;
    case 'copy':
      await ZinoFiles.trash({ ...ctx, path: op.dstPath! });
      break;
    case 'trash':
      await ZinoFiles.restore({ ...ctx, path: op.dstPath!, to: op.srcPath });
      break;
  }
  await fileOpsRepo.markUndone(op.id);
  return `Undid ${op.op} of ${op.srcPath}`;
}

/** Undo a whole group (e.g. one agent turn) in reverse order. Stops at the first failure. */
export async function undoGroup(groupId: string): Promise<{ undone: number; error?: string }> {
  const ops = (await fileOpsRepo.group(groupId)).filter((o) => o.status === 'done');
  let undone = 0;
  for (const op of ops) {
    try { await undoOperation(op); undone++; } catch (e) { return { undone, error: toZinoError(e).message }; }
  }
  return { undone };
}

// ---------------------------------------------------------------------------------------------
// Read helpers

export async function walk(rootId: string, path = '', limit = 20000): Promise<{ entries: FileEntry[]; truncated: boolean }> {
  return ZinoFiles.list({ rootId, path: cleanPath(path), recursive: true, limit });
}

function matchesKind(e: FileEntry, kind?: string, extensions?: string[]): boolean {
  if (e.isDirectory) return false;
  if (extensions?.length) return extensions.map((x) => x.toLowerCase().replace(/^\./, '')).includes(e.ext);
  if (!kind || kind === 'any') return true;
  const alias = KIND_ALIASES[kind.toLowerCase()] ?? kind;
  if (alias === 'pdf') return e.ext === 'pdf';
  return categoryOf(e.ext) === alias;
}

export async function findDuplicates(rootId: string, path = '', kind?: string) {
  const { entries, truncated } = await walk(rootId, path);
  const bySize = new Map<number, FileEntry[]>();
  for (const e of entries) if (matchesKind(e, kind) && e.size > 0) bySize.set(e.size, [...(bySize.get(e.size) ?? []), e]);
  const groups: { sha256: string; size: number; paths: string[] }[] = [];
  let hashedBytes = 0;
  const HASH_BUDGET = 4 * 1024 ** 3;
  let skipped = 0;
  for (const [size, files] of bySize) {
    if (files.length < 2) continue;
    if (hashedBytes + size * files.length > HASH_BUDGET) { skipped += files.length; continue; }
    const byHash = new Map<string, string[]>();
    for (const f of files) {
      const { sha256 } = await ZinoFiles.hash({ rootId, path: f.path });
      hashedBytes += size;
      byHash.set(sha256, [...(byHash.get(sha256) ?? []), f.path]);
    }
    for (const [sha256, paths] of byHash) if (paths.length > 1) groups.push({ sha256, size, paths });
  }
  return { groups, scannedFiles: entries.filter((e) => !e.isDirectory).length, truncated, skippedLargeCandidates: skipped };
}

export async function storageReport(rootId: string, path = '') {
  const { entries, truncated } = await walk(rootId, path);
  const files = entries.filter((e) => !e.isDirectory);
  const byCategory: Record<string, { count: number; bytes: number }> = {};
  for (const f of files) {
    const c = categoryOf(f.ext);
    byCategory[c] = { count: (byCategory[c]?.count ?? 0) + 1, bytes: (byCategory[c]?.bytes ?? 0) + f.size };
  }
  const largest = [...files].sort((a, b) => b.size - a.size).slice(0, 10).map((f) => ({ path: f.path, bytes: f.size }));
  return { totalFiles: files.length, totalFolders: entries.length - files.length, totalBytes: files.reduce((a, f) => a + f.size, 0), byCategory, largest, truncated };
}

export async function planOrganize(rootId: string, path = '', recursive = false) {
  const base = cleanPath(path);
  const list = recursive ? await walk(rootId, base) : await ZinoFiles.list({ rootId, path: base });
  const moves: { from: string; to: string }[] = [];
  for (const e of list.entries) {
    if (e.isDirectory) continue;
    const cat = categoryOf(e.ext);
    if (cat === 'Other') continue;
    const target = base ? `${base}/${cat}` : cat;
    if (dirname(e.path) === target) continue;
    if (Object.keys(FILE_CATEGORIES).some((c) => e.path.split('/').includes(c))) continue; // already organised
    moves.push({ from: e.path, to: target });
  }
  return moves;
}

// ---------------------------------------------------------------------------------------------
// Executor for model tool calls

export interface ExecutorOptions {
  rootId: string;
  rootName: string;
  chatId: string;
  groupId: string;
  /** Present when the active chat model is a cloud provider (privacy gating applies). */
  cloudProvider?: string | null;
  /** Called once per chat to ask whether a cloud model may see file names/metadata. */
  ensureCloudMetadataAccess?: () => Promise<boolean>;
}

export interface ToolOutcome { ok: boolean; content: string; changed: number }

const MAX_RESULT_CHARS = 12000;
const asJson = (v: unknown) => {
  const s = JSON.stringify(v);
  return s.length > MAX_RESULT_CHARS ? s.slice(0, MAX_RESULT_CHARS) + '…(truncated)' : s;
};

export class FileToolExecutor {
  constructor(private readonly o: ExecutorOptions) {}

  private ctx(): OpContext { return { rootId: this.o.rootId, chatId: this.o.chatId, groupId: this.o.groupId }; }

  private async privacyGate(kind: 'metadata' | 'content', detail: string): Promise<boolean> {
    if (!this.o.cloudProvider) return true; // local model: data never leaves the device
    if (kind === 'metadata') return this.o.ensureCloudMetadataAccess ? this.o.ensureCloudMetadataAccess() : false;
    return uiBridge.confirm({
      title: `Send file contents to ${this.o.cloudProvider}?`,
      message: `The AI wants to read "${detail}". Its contents will be sent to ${this.o.cloudProvider}'s servers.`,
      confirmLabel: 'Send contents', cancelLabel: 'Keep private',
    });
  }

  async execute(name: string, args: Record<string, unknown>): Promise<ToolOutcome> {
    try {
      return await this.run(name, args ?? {});
    } catch (e) {
      const err = toZinoError(e);
      return { ok: false, content: asJson({ error: err.code, message: err.message }), changed: 0 };
    }
  }

  private async run(name: string, a: Record<string, unknown>): Promise<ToolOutcome> {
    const { rootId } = this.o;
    const readOnly = ['list_files', 'search_files', 'file_info', 'find_duplicates', 'storage_report', 'organize_by_type'];
    if (readOnly.includes(name) || name === 'read_file') {
      if (!(await this.privacyGate('metadata', ''))) {
        return { ok: false, content: asJson({ error: 'PERMISSION_DENIED', message: 'The user did not allow this cloud model to see their files.' }), changed: 0 };
      }
    }
    switch (name) {
      case 'list_files': {
        const r = await ZinoFiles.list({ rootId, path: cleanPath(a.path), recursive: !!a.recursive, limit: Math.min(Number(a.limit) || 500, 2000) });
        return { ok: true, content: asJson({ entries: r.entries.map((e) => ({ path: e.path, dir: e.isDirectory, size: e.size })), truncated: r.truncated }), changed: 0 };
      }
      case 'search_files': {
        const { entries, truncated } = await walk(rootId, cleanPath(a.path));
        const q = typeof a.query === 'string' ? a.query.toLowerCase() : '';
        const exts = Array.isArray(a.extensions) ? (a.extensions as string[]) : undefined;
        const hits = entries.filter((e) => matchesKind(e, a.kind as string | undefined, exts) && (!q || e.name.toLowerCase().includes(q)));
        return { ok: true, content: asJson({ count: hits.length, files: hits.slice(0, 500).map((e) => ({ path: e.path, size: e.size, modified: e.modified })), truncated }), changed: 0 };
      }
      case 'file_info': {
        return { ok: true, content: asJson(await ZinoFiles.stat({ rootId, path: cleanPath(a.path, false) })), changed: 0 };
      }
      case 'read_file': {
        const path = cleanPath(a.path, false);
        if (!(await this.privacyGate('content', path))) {
          return { ok: false, content: asJson({ error: 'PERMISSION_DENIED', message: 'The user chose not to send this file to the cloud model.' }), changed: 0 };
        }
        const max = Math.min(Number(a.max_chars) || 8000, 20000);
        const r = await ZinoFiles.readText({ rootId, path, maxBytes: max * 2 });
        return { ok: true, content: asJson({ path, format: r.format, pages: r.pages, truncated: r.truncated || r.text.length > max, text: r.text.slice(0, max) }), changed: 0 };
      }
      case 'create_folder': {
        const path = cleanPath(a.path, false);
        const s = await ZinoFiles.stat({ rootId, path });
        if (s.exists) return { ok: false, content: asJson({ error: 'FILE_EXISTS', message: `"${path}" already exists.` }), changed: 0 };
        await fileOps.mkdir(this.ctx(), path);
        return { ok: true, content: asJson({ created: path }), changed: 1 };
      }
      case 'rename_item': {
        const path = cleanPath(a.path, false);
        const op = await fileOps.rename(this.ctx(), path, validateName(a.new_name));
        return { ok: true, content: asJson({ renamed: op.srcPath, to: op.dstPath }), changed: 1 };
      }
      case 'move_items':
      case 'copy_items': {
        const paths = (Array.isArray(a.paths) ? a.paths : []).map((p) => cleanPath(p, false));
        const dest = cleanPath(a.destination);
        if (!paths.length) throw new ZinoError('INVALID_ARGUMENT', 'No paths given.');
        const isMove = name === 'move_items';
        if (isMove && paths.length > 3) {
          const ok = await uiBridge.confirm({
            title: `Move ${paths.length} items?`, message: `Move into "${dest || this.o.rootName}". This can be undone.`,
            details: paths.slice(0, 30), confirmLabel: 'Move',
          });
          if (!ok) return { ok: false, content: asJson({ error: 'DECLINED', message: 'The user declined this move.' }), changed: 0 };
        }
        const done: string[] = []; const failed: { path: string; error: string }[] = [];
        for (const p of paths) {
          try { const op = isMove ? await fileOps.move(this.ctx(), p, dest) : await fileOps.copy(this.ctx(), p, dest); done.push(op.dstPath!); }
          catch (e) { failed.push({ path: p, error: toZinoError(e).message }); }
        }
        return { ok: failed.length === 0, content: asJson({ [isMove ? 'moved' : 'copied']: done, failed }), changed: done.length };
      }
      case 'delete_items': {
        const paths = (Array.isArray(a.paths) ? a.paths : []).map((p) => cleanPath(p, false));
        if (!paths.length) throw new ZinoError('INVALID_ARGUMENT', 'No paths given.');
        const ok = await uiBridge.confirm({
          title: `Delete ${paths.length} item${paths.length > 1 ? 's' : ''}?`,
          message: `They will be moved to ".ZinoAgent Trash" inside "${this.o.rootName}" and can be restored with Undo.`,
          details: paths.slice(0, 30), confirmLabel: 'Move to Trash', destructive: true,
        });
        if (!ok) return { ok: false, content: asJson({ error: 'DECLINED', message: 'The user declined the deletion.' }), changed: 0 };
        const done: string[] = []; const failed: { path: string; error: string }[] = [];
        for (const p of paths) {
          try { await fileOps.trash(this.ctx(), p); done.push(p); } catch (e) { failed.push({ path: p, error: toZinoError(e).message }); }
        }
        return { ok: failed.length === 0, content: asJson({ trashed: done, failed }), changed: done.length };
      }
      case 'find_duplicates':
        return { ok: true, content: asJson(await findDuplicates(rootId, cleanPath(a.path), a.kind as string | undefined)), changed: 0 };
      case 'storage_report':
        return { ok: true, content: asJson(await storageReport(rootId, cleanPath(a.path))), changed: 0 };
      case 'organize_by_type': {
        const moves = await planOrganize(rootId, cleanPath(a.path), !!a.recursive);
        if (!moves.length) return { ok: true, content: asJson({ message: 'Nothing to organise.' }), changed: 0 };
        const ok = await uiBridge.confirm({
          title: `Organise ${moves.length} files by type?`,
          message: 'Files will be moved into type folders. Nothing is overwritten and this can be undone.',
          details: moves.slice(0, 40).map((m) => `${m.from} → ${m.to}/`), confirmLabel: 'Organise',
        });
        if (!ok) return { ok: false, content: asJson({ error: 'DECLINED', message: 'The user declined.', plan: moves.slice(0, 100) }), changed: 0 };
        const done: string[] = []; const failed: { path: string; error: string }[] = [];
        for (const m of moves) {
          try { await fileOps.move(this.ctx(), m.from, m.to); done.push(m.from); } catch (e) { failed.push({ path: m.from, error: toZinoError(e).message }); }
        }
        return { ok: failed.length === 0, content: asJson({ moved: done.length, failed }), changed: done.length };
      }
      default:
        throw new ZinoError('UNKNOWN_TOOL', `Unknown tool "${name}".`);
    }
  }
}
