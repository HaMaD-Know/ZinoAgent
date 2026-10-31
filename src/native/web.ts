// Browser implementations of the native plugins, used when running `npm run dev` on a desktop.
// They exist so the UI and services can be developed on Windows. Features that need iPadOS
// (llama.cpp, Core ML, background downloads, Keychain) reject with NATIVE_ONLY instead of faking it.
import { WebPlugin } from '@capacitor/core';
import type {
  FileEntry, HttpRequestOptions, HttpResponse, ImportedFile, ResourceSnapshot, MultipartPart,
} from './definitions';

const nativeOnly = (what: string) =>
  Object.assign(new Error(`${what} requires the iPad app (not available in the browser preview).`), { code: 'NATIVE_ONLY' });

// ---------------------------------------------------------------------------------------------
// Tiny IndexedDB key/value store

const DB_NAME = 'zinoagent-web';
let dbPromise: Promise<IDBDatabase> | null = null;
function idb(): Promise<IDBDatabase> {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = () => {
        req.result.createObjectStore('files');
        req.result.createObjectStore('kv');
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  return dbPromise;
}
async function idbOp<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await idb();
  return new Promise<T>((resolve, reject) => {
    const tx = db.transaction(store, mode);
    const req = fn(tx.objectStore(store));
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
export const webKV = {
  get: <T>(key: string) => idbOp<T | undefined>('kv', 'readonly', (s) => s.get(key) as IDBRequest<T | undefined>),
  set: (key: string, value: unknown) => idbOp('kv', 'readwrite', (s) => s.put(value, key)),
  del: (key: string) => idbOp('kv', 'readwrite', (s) => s.delete(key)),
};
const files = {
  get: (path: string) => idbOp<Blob | undefined>('files', 'readonly', (s) => s.get(path) as IDBRequest<Blob | undefined>),
  set: (path: string, blob: Blob) => idbOp('files', 'readwrite', (s) => s.put(blob, path)),
  del: (path: string) => idbOp('files', 'readwrite', (s) => s.delete(path)),
  keys: () => idbOp<IDBValidKey[]>('files', 'readonly', (s) => s.getAllKeys()),
};

function b64ToBlob(b64: string, type = 'application/octet-stream'): Blob {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type });
}
async function blobToB64(blob: Blob): Promise<string> {
  const buf = new Uint8Array(await blob.arrayBuffer());
  let s = '';
  for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return btoa(s);
}
async function sha256Hex(data: ArrayBuffer): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
const mimeFor = (path: string) => {
  const ext = path.split('.').pop()?.toLowerCase() ?? '';
  return ({ png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', glb: 'model/gltf-binary',
    gltf: 'model/gltf+json', obj: 'text/plain', mp4: 'video/mp4', mov: 'video/quicktime', json: 'application/json',
    txt: 'text/plain', md: 'text/markdown' } as Record<string, string>)[ext] ?? 'application/octet-stream';
};

// ---------------------------------------------------------------------------------------------

/** Development-only secret store. The iPad build uses the iOS Keychain instead. */
const DEV_SECRETS_KEY = 'zino.dev.secrets';
function devSecrets(): Record<string, string> {
  try { return JSON.parse(sessionStorage.getItem(DEV_SECRETS_KEY) ?? '{}'); } catch { return {}; }
}
export class ZinoKeychainWeb extends WebPlugin {
  async set(o: { account: string; secret: string }) {
    const s = devSecrets(); s[o.account] = o.secret.trim();
    sessionStorage.setItem(DEV_SECRETS_KEY, JSON.stringify(s)); // session only: cleared when the tab closes
    return { masked: mask(o.secret) };
  }
  async has(o: { account: string }) {
    const v = devSecrets()[o.account];
    return v ? { exists: true, masked: mask(v) } : { exists: false };
  }
  async remove(o: { account: string }) {
    const s = devSecrets(); delete s[o.account];
    sessionStorage.setItem(DEV_SECRETS_KEY, JSON.stringify(s));
  }
}
const mask = (s: string) => (s.length > 8 ? '••••' + s.slice(-4) : '••••');

export class ZinoHttpWeb extends WebPlugin {
  private controllers = new Map<string, AbortController>();

  async cancel(o: { id: string }) {
    const c = this.controllers.get(o.id);
    c?.abort();
    return { cancelled: !!c };
  }

  async request(o: HttpRequestOptions): Promise<HttpResponse> {
    const id = o.id ?? crypto.randomUUID();
    const url = new URL(o.url);
    const headers: Record<string, string> = { ...(o.headers ?? {}) };
    if (o.auth) {
      const secret = devSecrets()[o.auth.account];
      if (!secret) throw Object.assign(new Error('No API key is stored for this provider.'), { code: 'MISSING_API_KEY' });
      if (o.auth.type === 'query') url.searchParams.set(o.auth.name ?? 'key', secret);
      else headers[o.auth.name ?? 'Authorization'] = (o.auth.prefix ?? '') + secret;
    }
    let body: BodyInit | undefined;
    if (o.multipart) {
      const fd = new FormData();
      for (const p of o.multipart as MultipartPart[]) {
        if (p.value !== undefined) fd.append(p.name, p.value);
        else if (p.base64) fd.append(p.name, b64ToBlob(p.base64, p.contentType), p.filename ?? 'file');
        else if (p.appPath) {
          const blob = await files.get(p.appPath);
          if (blob) fd.append(p.name, blob, p.filename ?? 'file');
        }
      }
      body = fd;
    } else if (o.bodyBase64) body = b64ToBlob(o.bodyBase64);
    else if (o.body !== undefined) body = o.body;

    const ctrl = new AbortController();
    this.controllers.set(id, ctrl);
    try {
      let res: Response;
      try {
        res = await fetch(url, { method: o.method ?? 'GET', headers, body, signal: ctrl.signal });
      } catch (e) {
        if ((e as Error).name === 'AbortError') throw Object.assign(new Error('Request cancelled'), { code: 'CANCELLED' });
        throw Object.assign(new Error(`Network request failed (in the browser preview this is often CORS): ${(e as Error).message}`), { code: 'NETWORK_ERROR' });
      }
      const hdrs: Record<string, string> = {};
      res.headers.forEach((v, k) => { hdrs[k] = v; });
      if (o.stream && res.ok && res.body) {
        this.notifyListeners('httpStart', { id, status: res.status, headers: hdrs });
        const reader = res.body.getReader();
        const dec = new TextDecoder();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          this.notifyListeners('httpChunk', { id, chunk: dec.decode(value, { stream: true }) });
        }
        return { status: res.status, headers: hdrs, streamed: true };
      }
      if (o.responseType === 'file' && res.ok && o.saveTo) {
        const blob = await res.blob();
        await files.set(o.saveTo, blob);
        return { status: res.status, headers: hdrs, path: o.saveTo, size: blob.size };
      }
      if (o.responseType === 'base64' && res.ok) {
        return { status: res.status, headers: hdrs, base64: await blobToB64(await res.blob()) };
      }
      return { status: res.status, headers: hdrs, body: await res.text() };
    } catch (e) {
      if ((e as Error).name === 'AbortError') throw Object.assign(new Error('Request cancelled'), { code: 'CANCELLED' });
      throw e;
    } finally {
      this.controllers.delete(id);
    }
  }
}

export class ZinoStorageWeb extends WebPlugin {
  private urls = new Map<string, string>();

  async info() {
    const est = await navigator.storage?.estimate?.();
    return { root: 'indexeddb://zinoagent', available: est ? (est.quota ?? 0) - (est.usage ?? 0) : -1, total: est?.quota ?? -1 };
  }
  async writeBase64(o: { path: string; data: string; overwrite?: boolean }) {
    if (!o.overwrite && (await files.get(o.path))) throw Object.assign(new Error('File already exists.'), { code: 'FILE_EXISTS' });
    const blob = b64ToBlob(o.data, mimeFor(o.path));
    await files.set(o.path, blob);
    return { path: o.path, size: blob.size };
  }
  async readBase64(o: { path: string }) {
    const b = await files.get(o.path);
    if (!b) throw Object.assign(new Error('File not found'), { code: 'FILE_NOT_FOUND' });
    return { data: await blobToB64(b) };
  }
  async writeText(o: { path: string; text: string }) { await files.set(o.path, new Blob([o.text], { type: 'text/plain' })); return { path: o.path }; }
  async readText(o: { path: string }) {
    const b = await files.get(o.path);
    if (!b) throw Object.assign(new Error('File not found'), { code: 'FILE_NOT_FOUND' });
    return { text: await b.text() };
  }
  async stat(o: { path: string }) {
    const b = await files.get(o.path);
    if (b) return { exists: true, isDirectory: false, size: b.size, modified: null };
    const keys = (await files.keys()).map(String);
    const prefix = o.path.endsWith('/') ? o.path : o.path + '/';
    const inside = keys.filter((k) => k.startsWith(prefix));
    if (!inside.length) return { exists: false };
    let size = 0;
    for (const k of inside) size += (await files.get(k))?.size ?? 0;
    return { exists: true, isDirectory: true, size, modified: null };
  }
  async list(o: { path: string }) {
    const prefix = o.path ? (o.path.endsWith('/') ? o.path : o.path + '/') : '';
    const keys = (await files.keys()).map(String).filter((k) => k.startsWith(prefix));
    const seen = new Map<string, { path: string; name: string; isDirectory: boolean; size: number }>();
    for (const k of keys) {
      const rest = k.slice(prefix.length);
      const [head, ...tail] = rest.split('/');
      const path = prefix + head;
      if (!seen.has(path)) seen.set(path, { path, name: head, isDirectory: tail.length > 0, size: tail.length ? 0 : (await files.get(k))?.size ?? 0 });
    }
    return { entries: [...seen.values()] };
  }
  async remove(o: { path: string }) {
    const keys = (await files.keys()).map(String).filter((k) => k === o.path || k.startsWith(o.path + '/'));
    for (const k of keys) await files.del(k);
    const u = this.urls.get(o.path); if (u) { URL.revokeObjectURL(u); this.urls.delete(o.path); }
    return { removed: true };
  }
  async copy(o: { from: string; to: string }) {
    const b = await files.get(o.from);
    if (!b) throw Object.assign(new Error('File not found'), { code: 'FILE_NOT_FOUND' });
    if (await files.get(o.to)) throw Object.assign(new Error('Destination exists'), { code: 'FILE_EXISTS' });
    await files.set(o.to, b);
    return { path: o.to };
  }
  async move(o: { from: string; to: string }) { await this.copy(o); await files.del(o.from); return { path: o.to }; }
  async fileUrl(o: { path: string }) {
    const cached = this.urls.get(o.path);
    if (cached) return { url: cached };
    const b = await files.get(o.path);
    if (!b) throw Object.assign(new Error('File not found'), { code: 'FILE_NOT_FOUND' });
    const url = URL.createObjectURL(b.type ? b : new Blob([b], { type: mimeFor(o.path) }));
    this.urls.set(o.path, url);
    return { url };
  }
  async hash(o: { path: string }) {
    const b = await files.get(o.path);
    if (!b) throw Object.assign(new Error('File not found'), { code: 'FILE_NOT_FOUND' });
    return { sha256: await sha256Hex(await b.arrayBuffer()) };
  }
  async unzip(): Promise<{ path: string }> { throw nativeOnly('Unzipping model archives'); }
  async directorySize(o: { path: string }) { return { size: (await this.stat(o)).size ?? 0 }; }
  async clearTemp() {
    const keys = (await files.keys()).map(String).filter((k) => k.startsWith('tmp/'));
    let freed = 0;
    for (const k of keys) { freed += (await files.get(k))?.size ?? 0; await files.del(k); }
    return { freed };
  }
  async pickAndImport(o: { kind: string; destDir: string; multiple?: boolean }): Promise<{ files: ImportedFile[] }> {
    if (o.kind === 'folder' || o.kind === 'coreml') throw nativeOnly('Importing model folders');
    const accept = ({ gguf: '.gguf', image: 'image/*', model3d: '.glb,.gltf,.obj', video: 'video/*', zip: '.zip' } as Record<string, string>)[o.kind] ?? '';
    const picked = await new Promise<File[]>((resolve, reject) => {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = accept;
      input.multiple = !!o.multiple;
      input.onchange = () => resolve([...(input.files ?? [])]);
      input.oncancel = () => reject(Object.assign(new Error('Import cancelled'), { code: 'CANCELLED' }));
      input.click();
    });
    const out: ImportedFile[] = [];
    for (const f of picked) {
      let name = f.name; let n = 2;
      while (await files.get(`${o.destDir}/${name}`)) { name = f.name.replace(/(\.[^.]*)?$/, `-${n++}$1`); }
      await files.set(`${o.destDir}/${name}`, f);
      out.push({ path: `${o.destDir}/${name}`, name, originalName: f.name, size: f.size, isDirectory: false });
    }
    return { files: out };
  }
  async share(o: { path: string }) {
    const { url } = await this.fileUrl(o);
    const a = document.createElement('a');
    a.href = url; a.download = o.path.split('/').pop() ?? 'export';
    a.click();
    return { completed: true };
  }
}

// ---------------------------------------------------------------------------------------------
// File System Access API (Chrome/Edge on Windows) for developing the AI file manager.

type DirHandle = FileSystemDirectoryHandle & {
  values(): AsyncIterable<FileSystemHandle>;
  queryPermission?(o: { mode: string }): Promise<string>;
  requestPermission?(o: { mode: string }): Promise<string>;
};

export class ZinoFilesWeb extends WebPlugin {
  private async roots(): Promise<{ id: string; name: string; handle: DirHandle }[]> {
    return (await webKV.get<{ id: string; name: string; handle: DirHandle }[]>('roots')) ?? [];
  }
  private async root(rootId: string): Promise<DirHandle> {
    const r = (await this.roots()).find((x) => x.id === rootId);
    if (!r) throw Object.assign(new Error('This folder is not authorised.'), { code: 'FOLDER_NOT_AUTHORIZED' });
    if (r.handle.queryPermission && (await r.handle.queryPermission({ mode: 'readwrite' })) !== 'granted') {
      const p = await r.handle.requestPermission?.({ mode: 'readwrite' });
      if (p !== 'granted') throw Object.assign(new Error('Permission denied'), { code: 'PERMISSION_DENIED' });
    }
    return r.handle;
  }
  private parts(path: string): string[] {
    const p = path.split('/').filter(Boolean);
    if (p.some((x) => x === '..' || x === '.')) throw Object.assign(new Error('Path outside folder'), { code: 'PATH_OUTSIDE_FOLDER' });
    return p;
  }
  private async dirAt(root: DirHandle, parts: string[], create = false): Promise<DirHandle> {
    let d = root;
    for (const p of parts) d = (await d.getDirectoryHandle(p, { create })) as DirHandle;
    return d;
  }
  private async handleAt(root: DirHandle, path: string): Promise<{ parent: DirHandle; name: string; handle: FileSystemHandle }> {
    const parts = this.parts(path);
    const name = parts.pop();
    if (!name) throw Object.assign(new Error('Invalid path'), { code: 'INVALID_PATH' });
    const parent = await this.dirAt(root, parts);
    try { return { parent, name, handle: await parent.getFileHandle(name) }; } catch { /* maybe a dir */ }
    try { return { parent, name, handle: await parent.getDirectoryHandle(name) }; } catch {
      throw Object.assign(new Error('File not found'), { code: 'FILE_NOT_FOUND' });
    }
  }
  private async exists(dir: DirHandle, name: string) {
    try { await dir.getFileHandle(name); return true; } catch { /* */ }
    try { await dir.getDirectoryHandle(name); return true; } catch { return false; }
  }
  private async copyInto(src: FileSystemHandle, destDir: DirHandle, name: string) {
    if (src.kind === 'file') {
      const file = await (src as FileSystemFileHandle).getFile();
      const fh = await destDir.getFileHandle(name, { create: true });
      const w = await fh.createWritable(); await w.write(file); await w.close();
    } else {
      const sub = (await destDir.getDirectoryHandle(name, { create: true })) as DirHandle;
      for await (const child of (src as DirHandle).values()) await this.copyInto(child, sub, child.name);
    }
  }

  async pickFolder() {
    const picker = (window as unknown as { showDirectoryPicker?: (o: unknown) => Promise<DirHandle> }).showDirectoryPicker;
    if (!picker) throw nativeOnly('Folder access (use Chrome or Edge for the browser preview)');
    const handle = await picker({ mode: 'readwrite' }).catch(() => { throw Object.assign(new Error('Selection cancelled'), { code: 'CANCELLED' }); });
    const roots = await this.roots();
    const id = crypto.randomUUID();
    roots.push({ id, name: handle.name, handle });
    await webKV.set('roots', roots);
    return { id, name: handle.name };
  }
  async listRoots() { return { roots: (await this.roots()).map((r) => ({ id: r.id, name: r.name, accessible: true })) }; }
  async removeRoot(o: { rootId: string }) { await webKV.set('roots', (await this.roots()).filter((r) => r.id !== o.rootId)); }

  async list(o: { rootId: string; path?: string; recursive?: boolean; includeHidden?: boolean; limit?: number }) {
    const root = await this.root(o.rootId);
    const limit = o.limit ?? 5000;
    const out: FileEntry[] = [];
    let truncated = false;
    const walk = async (dir: DirHandle, prefix: string) => {
      for await (const h of dir.values()) {
        if (!o.includeHidden && h.name.startsWith('.')) continue;
        if (out.length >= limit) { truncated = true; return; }
        const path = prefix ? `${prefix}/${h.name}` : h.name;
        if (h.kind === 'file') {
          const f = await (h as FileSystemFileHandle).getFile();
          out.push({ path, name: h.name, isDirectory: false, size: f.size, modified: new Date(f.lastModified).toISOString(), ext: h.name.includes('.') ? h.name.split('.').pop()!.toLowerCase() : '' });
        } else {
          out.push({ path, name: h.name, isDirectory: true, size: 0, modified: null, ext: '' });
          if (o.recursive) await walk(h as DirHandle, path);
        }
      }
    };
    await walk(await this.dirAt(root, this.parts(o.path ?? '')), o.path ?? '');
    return { entries: out, truncated };
  }
  async stat(o: { rootId: string; path: string }) {
    const root = await this.root(o.rootId);
    try {
      const { handle, name } = await this.handleAt(root, o.path);
      if (handle.kind === 'file') {
        const f = await (handle as FileSystemFileHandle).getFile();
        return { exists: true as const, path: o.path, name, isDirectory: false, size: f.size, modified: new Date(f.lastModified).toISOString(), ext: name.split('.').pop()?.toLowerCase() ?? '' };
      }
      return { exists: true as const, path: o.path, name, isDirectory: true, size: 0, modified: null, ext: '' };
    } catch { return { exists: false as const }; }
  }
  async readText(o: { rootId: string; path: string; maxBytes?: number }) {
    const { handle } = await this.handleAt(await this.root(o.rootId), o.path);
    if (handle.kind !== 'file') throw Object.assign(new Error('Not a file'), { code: 'UNSUPPORTED_FORMAT' });
    const f = await (handle as FileSystemFileHandle).getFile();
    if (f.name.toLowerCase().endsWith('.pdf')) throw nativeOnly('Reading PDF text');
    const max = o.maxBytes ?? 512_000;
    const buf = new Uint8Array(await f.slice(0, max).arrayBuffer());
    if (buf.subarray(0, 8000).includes(0)) throw Object.assign(new Error('Binary file'), { code: 'UNSUPPORTED_FORMAT' });
    return { text: new TextDecoder().decode(buf), truncated: f.size > max, format: 'text' };
  }
  async hash(o: { rootId: string; path: string }) {
    const { handle } = await this.handleAt(await this.root(o.rootId), o.path);
    const f = await (handle as FileSystemFileHandle).getFile();
    return { sha256: await sha256Hex(await f.arrayBuffer()) };
  }
  async mkdir(o: { rootId: string; path: string }) {
    const root = await this.root(o.rootId);
    const parts = this.parts(o.path);
    const name = parts.pop()!;
    const parent = await this.dirAt(root, parts, true);
    if (await this.exists(parent, name)) throw Object.assign(new Error('Already exists'), { code: 'FILE_EXISTS' });
    await parent.getDirectoryHandle(name, { create: true });
    return { path: o.path };
  }
  async rename(o: { rootId: string; path: string; newName: string }) {
    const root = await this.root(o.rootId);
    if (/[/:]/.test(o.newName) || !o.newName.trim()) throw Object.assign(new Error('Invalid name'), { code: 'INVALID_NAME' });
    const { parent, handle } = await this.handleAt(root, o.path);
    if (await this.exists(parent, o.newName)) throw Object.assign(new Error(`'${o.newName}' already exists. Nothing was overwritten.`), { code: 'FILE_EXISTS' });
    await this.copyInto(handle, parent, o.newName);
    await parent.removeEntry(handle.name, { recursive: true });
    const to = [...this.parts(o.path).slice(0, -1), o.newName].join('/');
    return { from: o.path, to };
  }
  async move(o: { rootId: string; path: string; destinationDir: string }) {
    const root = await this.root(o.rootId);
    const { parent, handle, name } = await this.handleAt(root, o.path);
    const dest = await this.dirAt(root, this.parts(o.destinationDir));
    if (await this.exists(dest, name)) throw Object.assign(new Error('Exists in destination. Nothing was overwritten.'), { code: 'FILE_EXISTS' });
    await this.copyInto(handle, dest, name);
    await parent.removeEntry(name, { recursive: true });
    return { from: o.path, to: [o.destinationDir, name].filter(Boolean).join('/') };
  }
  async copy(o: { rootId: string; path: string; destinationDir: string; newName?: string }) {
    const root = await this.root(o.rootId);
    const { handle, name } = await this.handleAt(root, o.path);
    const dest = await this.dirAt(root, this.parts(o.destinationDir));
    let target = o.newName ?? name; let n = 2;
    while (await this.exists(dest, target)) target = (o.newName ?? name).replace(/(\.[^.]*)?$/, ` ${n++}$1`);
    await this.copyInto(handle, dest, target);
    return { from: o.path, to: [o.destinationDir, target].filter(Boolean).join('/') };
  }
  async trash(o: { rootId: string; path: string }) {
    const bucket = `.ZinoAgent Trash/${Date.now()}`;
    const root = await this.root(o.rootId);
    await this.dirAt(root, this.parts(bucket), true);
    return this.move({ rootId: o.rootId, path: o.path, destinationDir: bucket });
  }
  async restore(o: { rootId: string; path: string; to: string }) {
    const root = await this.root(o.rootId);
    const parts = this.parts(o.to);
    const name = parts.pop()!;
    const destDir = await this.dirAt(root, parts, true);
    if (await this.exists(destDir, name)) throw Object.assign(new Error('Something already exists at the original location.'), { code: 'FILE_EXISTS' });
    const { parent, handle } = await this.handleAt(root, o.path);
    await this.copyInto(handle, destDir, name);
    await parent.removeEntry(handle.name, { recursive: true });
    return { from: o.path, to: o.to };
  }
  async importToApp(o: { rootId: string; path: string; dest: string }) {
    const { handle } = await this.handleAt(await this.root(o.rootId), o.path);
    await files.set(o.dest, await (handle as FileSystemFileHandle).getFile());
    return { path: o.dest };
  }
}

export class ZinoResourcesWeb extends WebPlugin {
  async snapshot(): Promise<ResourceSnapshot> {
    const perf = performance as unknown as { memory?: { usedJSHeapSize: number; jsHeapSizeLimit: number } };
    const nav = navigator as unknown as { deviceMemory?: number; hardwareConcurrency?: number };
    const est = await navigator.storage?.estimate?.();
    const physical = (nav.deviceMemory ?? 8) * 1024 ** 3;
    return {
      physicalMemory: physical,
      appFootprint: perf.memory?.usedJSHeapSize ?? -1,
      availableMemory: perf.memory ? perf.memory.jsHeapSizeLimit - perf.memory.usedJSHeapSize : -1,
      thermalState: 'unknown',
      lowPowerMode: false,
      processorCount: nav.hardwareConcurrency ?? 0,
      storageAvailable: est ? (est.quota ?? 0) - (est.usage ?? 0) : -1,
      storageTotal: est?.quota ?? -1,
      deviceModel: 'Browser preview',
      systemVersion: navigator.userAgent,
      timestamp: Date.now(),
      estimated: true,
    };
  }
}

export class NativeOnlyWeb extends WebPlugin {
  constructor(private readonly feature: string) { super(); }
  // Any method call rejects; status-style calls report "not loaded".
  async status() { return { loaded: false }; }
  async active() { return { running: [], resumable: [] }; }
  async unload() { return { unloaded: true }; }
  async cancel() { /* nothing running */ }
  async inspect(): Promise<never> { throw nativeOnly(this.feature); }
  async load(): Promise<never> { throw nativeOnly(this.feature); }
  async generate(): Promise<never> { throw nativeOnly(this.feature); }
  async validate(): Promise<never> { throw nativeOnly(this.feature); }
  async tokenize(): Promise<never> { throw nativeOnly(this.feature); }
  async applyTemplate(): Promise<never> { throw nativeOnly(this.feature); }
  async benchmark(): Promise<never> { throw nativeOnly(this.feature); }
  async start(): Promise<never> { throw nativeOnly(this.feature); }
  async pause(): Promise<never> { throw nativeOnly(this.feature); }
}
