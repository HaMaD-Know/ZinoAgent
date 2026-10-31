import { beforeEach, describe, expect, it, vi } from 'vitest';

// In-memory file system with the same rules as the native ZinoFiles plugin (no overwrite, trash folder).
const fs = new Map<string, { dir: boolean; data: string }>();
const parent = (p: string) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '');
const base = (p: string) => p.split('/').pop()!;
const exists = (p: string) => p === '' || fs.has(p);
const err = (code: string, message: string) => Object.assign(new Error(message), { code });
function moveTree(from: string, to: string, copy = false) {
  for (const [k, v] of [...fs.entries()]) {
    if (k === from || k.startsWith(from + '/')) {
      fs.set(to + k.slice(from.length), { ...v });
      if (!copy) fs.delete(k);
    }
  }
}
function mkdirp(p: string) { const parts = p.split('/').filter(Boolean); let cur = ''; for (const x of parts) { cur = cur ? `${cur}/${x}` : x; if (!fs.has(cur)) fs.set(cur, { dir: true, data: '' }); } }
let trashCounter = 0;

vi.mock('@/native', () => ({
  isNative: () => false,
  ZinoFiles: {
    list: async ({ path = '', recursive }: { path?: string; recursive?: boolean }) => {
      if (!exists(path)) throw err('FILE_NOT_FOUND', 'Folder not found.');
      const entries = [...fs.entries()]
        .filter(([k]) => parent(k) === path || (recursive && (path === '' || k.startsWith(path + '/'))))
        .filter(([k]) => !k.includes('.ZinoAgent Trash'))
        .map(([k, v]) => ({ path: k, name: base(k), isDirectory: v.dir, size: v.data.length, modified: null, ext: v.dir ? '' : (base(k).split('.').pop() ?? '').toLowerCase() }));
      return { entries, truncated: false };
    },
    stat: async ({ path }: { path: string }) => {
      const v = fs.get(path);
      return v ? { exists: true, path, name: base(path), isDirectory: v.dir, size: v.data.length, modified: null, ext: '' } : { exists: false };
    },
    readText: async ({ path }: { path: string }) => ({ text: fs.get(path)!.data, truncated: false, format: 'text' }),
    hash: async ({ path }: { path: string }) => ({ sha256: `h:${fs.get(path)!.data}` }),
    mkdir: async ({ path }: { path: string }) => { if (fs.has(path)) throw err('FILE_EXISTS', 'exists'); mkdirp(path); return { path }; },
    rename: async ({ path, newName }: { path: string; newName: string }) => {
      if (!fs.has(path)) throw err('FILE_NOT_FOUND', 'not found');
      const to = parent(path) ? `${parent(path)}/${newName}` : newName;
      if (fs.has(to)) throw err('FILE_EXISTS', `'${newName}' already exists. Nothing was overwritten.`);
      moveTree(path, to); return { from: path, to };
    },
    move: async ({ path, destinationDir }: { path: string; destinationDir: string }) => {
      if (!fs.has(path)) throw err('FILE_NOT_FOUND', 'not found');
      const to = destinationDir ? `${destinationDir}/${base(path)}` : base(path);
      if (fs.has(to)) throw err('FILE_EXISTS', 'exists in destination. Nothing was overwritten.');
      moveTree(path, to); return { from: path, to };
    },
    copy: async ({ path, destinationDir }: { path: string; destinationDir: string }) => {
      let name = base(path); let n = 2;
      const target = () => (destinationDir ? `${destinationDir}/${name}` : name);
      while (fs.has(target())) name = base(path).replace(/(\.[^.]*)?$/, ` ${n++}$1`);
      moveTree(path, target(), true); return { from: path, to: target() };
    },
    trash: async ({ path }: { path: string }) => {
      const to = `.ZinoAgent Trash/${++trashCounter}/${base(path)}`;
      mkdirp(parent(to)); moveTree(path, to); return { from: path, to };
    },
    restore: async ({ path, to }: { path: string; to: string }) => {
      if (!fs.has(path)) throw err('FILE_NOT_FOUND', 'gone');
      if (fs.has(to)) throw err('FILE_EXISTS', 'Something already exists at the original location.');
      moveTree(path, to); return { from: path, to };
    },
  },
}));

import { freshDb } from './helpers/db';
import { FileToolExecutor, cleanPath, undoGroup, undoOperation, planOrganize } from '@/services/file-manager';
import { fileOpsRepo } from '@/database/repositories';
import { uiBridge } from '@/services/ui-bridge';

const file = (p: string, data = 'x') => { mkdirp(parent(p)); fs.set(p, { dir: false, data }); };

describe('AI file manager', () => {
  let confirmAnswer = true;
  const confirms: string[] = [];
  beforeEach(async () => {
    await freshDb();
    fs.clear(); trashCounter = 0; confirms.length = 0; confirmAnswer = true;
    uiBridge.setConfirmHandler(async (r) => { confirms.push(r.title); return confirmAnswer; });
    file('photos/IMG_1.jpg', 'aaa'); file('photos/IMG_2.jpg', 'bbb'); file('car.glb', 'mesh'); file('car copy.glb', 'mesh');
    file('docs/report.pdf', 'pdf'); file('notes.txt', 'hello');
  });
  const exec = (opts: Partial<ConstructorParameters<typeof FileToolExecutor>[0]> = {}) =>
    new FileToolExecutor({ rootId: 'r1', rootName: 'Root', chatId: 'c1', groupId: 'g1', ...opts });

  it('rejects paths that escape the authorised folder', () => {
    expect(() => cleanPath('../etc/passwd')).toThrow(/\.\./);
    expect(() => cleanPath('a/../../b')).toThrow();
    expect(() => cleanPath('file:///private')).toThrow();
    expect(cleanPath('./photos//IMG_1.jpg')).toBe('photos/IMG_1.jpg');
  });

  it('finds GLB files and PDFs by kind', async () => {
    const r = JSON.parse((await exec().execute('search_files', { kind: 'model3d' })).content);
    expect(r.files.map((f: { path: string }) => f.path).sort()).toEqual(['car copy.glb', 'car.glb']);
    const p = JSON.parse((await exec().execute('search_files', { kind: 'pdf' })).content);
    expect(p.files.map((f: { path: string }) => f.path)).toEqual(['docs/report.pdf']);
  });

  it('detects duplicates by content hash', async () => {
    const r = JSON.parse((await exec().execute('find_duplicates', {})).content);
    expect(r.groups).toHaveLength(1);
    expect(r.groups[0].paths.sort()).toEqual(['car copy.glb', 'car.glb']);
  });

  it('never overwrites on rename and reports the conflict to the model', async () => {
    const r = await exec().execute('rename_item', { path: 'car copy.glb', new_name: 'car.glb' });
    expect(r.ok).toBe(false);
    expect(r.content).toMatch(/already exists/);
    expect(fs.get('car.glb')!.data).toBe('mesh');
  });

  it('journals changes and undoes a whole agent turn in reverse order', async () => {
    const e = exec();
    expect((await e.execute('create_folder', { path: 'Hot Wheels' })).ok).toBe(true);
    expect((await e.execute('move_items', { paths: ['car.glb'], destination: 'Hot Wheels' })).ok).toBe(true);
    expect((await e.execute('rename_item', { path: 'Hot Wheels/car.glb', new_name: 'twin-mill.glb' })).ok).toBe(true);
    expect(fs.has('Hot Wheels/twin-mill.glb')).toBe(true);
    expect((await fileOpsRepo.group('g1')).length).toBe(3);
    const r = await undoGroup('g1');
    expect(r).toEqual({ undone: 3 });
    expect(fs.has('car.glb')).toBe(true);
    expect([...fs.keys()].some((k) => k.startsWith('Hot Wheels'))).toBe(false); // empty folder moved to trash
  });

  it('requires confirmation to delete, and respects "no"', async () => {
    confirmAnswer = false;
    const r = await exec().execute('delete_items', { paths: ['notes.txt'] });
    expect(r.ok).toBe(false);
    expect(fs.has('notes.txt')).toBe(true);
    expect(confirms[0]).toMatch(/Delete 1 item/);
    confirmAnswer = true;
    expect((await exec().execute('delete_items', { paths: ['notes.txt'] })).ok).toBe(true);
    expect(fs.has('notes.txt')).toBe(false);
    const [op] = await fileOpsRepo.list();
    await undoOperation(op);
    expect(fs.get('notes.txt')!.data).toBe('hello');
  });

  it('refuses to undo when the original location is now occupied', async () => {
    await exec().execute('move_items', { paths: ['notes.txt'], destination: 'docs' });
    file('notes.txt', 'new file with same name');
    const [op] = await fileOpsRepo.list();
    await expect(undoOperation(op)).rejects.toThrow(/exists/);
    expect(fs.get('notes.txt')!.data).toBe('new file with same name');
  });

  it('asks before large moves and before organising', async () => {
    const plan = await planOrganize('r1', '', true);
    expect(plan.map((m) => m.to)).toEqual(expect.arrayContaining(['Images', '3D Models', 'Documents']));
    confirmAnswer = false;
    const r = await exec().execute('organize_by_type', { recursive: true });
    expect(r.ok).toBe(false);
    expect(fs.has('car.glb')).toBe(true);
  });

  it('gates cloud models: metadata needs chat permission, contents need per-file consent', async () => {
    let allowMeta = false;
    const cloud = exec({ cloudProvider: 'OpenAI', ensureCloudMetadataAccess: async () => allowMeta });
    expect((await cloud.execute('list_files', {})).content).toMatch(/PERMISSION_DENIED/);
    allowMeta = true;
    expect((await cloud.execute('list_files', {})).ok).toBe(true);
    confirmAnswer = false;
    const read = await cloud.execute('read_file', { path: 'notes.txt' });
    expect(read.content).toMatch(/chose not to send/);
    expect(confirms.some((c) => /Send file contents to OpenAI/.test(c))).toBe(true);
    confirmAnswer = true;
    expect(JSON.parse((await cloud.execute('read_file', { path: 'notes.txt' })).content).text).toBe('hello');
  });

  it('local models read files without cloud prompts', async () => {
    const r = await exec().execute('read_file', { path: 'notes.txt' });
    expect(JSON.parse(r.content).text).toBe('hello');
    expect(confirms).toHaveLength(0);
  });
});
