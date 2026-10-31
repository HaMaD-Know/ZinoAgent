// Model downloads. Before downloading, the exact size and SHA-256 are read from the Hugging Face
// API (the publisher's LFS metadata); after downloading, the native layer verifies both and
// discards the file on mismatch. Downloads can be paused/resumed and survive app restarts as
// "paused" (iPadOS resume data permitting).
import { create } from 'zustand';
import type { DownloadRecord, ModelCategory } from '@/types';
import { downloadsRepo, uid } from '@/database/repositories';
import { ZinoDownloads, ZinoKeychain, ZinoStorage } from '@/native';
import { requestJson } from '@/providers/http';
import { ZinoError, toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { hfResolveUrl, type CatalogEntry } from '@/models/catalog';
import { modelDir, registerDiffusion, registerGGUF } from '@/services/model-manager';

export const HF_TOKEN_ACCOUNT = 'zino.huggingface';

export interface HFFile { path: string; size: number; sha256: string | null }

interface DownloadState {
  items: DownloadRecord[];
  speed: Record<string, number>;
}
export const useDownloads = create<DownloadState>(() => ({ items: [], speed: {} }));

async function reload() { useDownloads.setState({ items: await downloadsRepo.list() }); }
async function patch(id: string, p: Partial<DownloadRecord>) {
  const d = await downloadsRepo.get(id);
  if (!d) return null;
  const next = { ...d, ...p, updatedAt: Date.now() };
  await downloadsRepo.save(next);
  useDownloads.setState((s) => ({ items: s.items.map((x) => (x.id === id ? next : x)) }));
  return next;
}

async function hfAuth() {
  const has = await ZinoKeychain.has({ account: HF_TOKEN_ACCOUNT }).catch(() => ({ exists: false }));
  return has.exists ? { account: HF_TOKEN_ACCOUNT, name: 'Authorization', prefix: 'Bearer ' } : undefined;
}

/** List files in a Hugging Face model repo (with LFS sha256). */
export async function listHFFiles(repo: string): Promise<HFFile[]> {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) throw new ZinoError('INVALID_ARGUMENT', 'Enter a repository as owner/name, e.g. bartowski/Llama-3.2-3B-Instruct-GGUF');
  const auth = await hfAuth();
  const entries = await requestJson<{ type: string; path: string; size: number; lfs?: { oid: string; size: number } }[]>({
    url: `https://huggingface.co/api/models/${repo}/tree/main?recursive=true`, auth, provider: 'Hugging Face',
  });
  return entries.filter((e) => e.type === 'file').map((e) => ({ path: e.path, size: e.lfs?.size ?? e.size, sha256: e.lfs?.oid ?? null }));
}

let listening = false;
export async function initDownloads() {
  await reload();
  if (listening) return;
  listening = true;
  await ZinoDownloads.addListener('progress', (e) => {
    useDownloads.setState((s) => ({
      speed: { ...s.speed, [e.id]: e.bytesPerSecond },
      items: s.items.map((x) => (x.id === e.id ? { ...x, receivedBytes: e.received, totalBytes: e.total > 0 ? e.total : x.totalBytes, status: 'downloading' } : x)),
    }));
  }).catch(() => {});
  await ZinoDownloads.addListener('verifying', (e) => { void patch(e.id, { status: 'verifying' }); }).catch(() => {});
  await ZinoDownloads.addListener('complete', (e) => { void onComplete(e.id, e.path, e.sha256, e.size); }).catch(() => {});
  await ZinoDownloads.addListener('error', (e) => {
    void patch(e.id, { status: e.resumable ? 'paused' : 'failed', error: e.message });
    uiBridge.toast('error', `Download failed: ${e.message}${e.resumable ? ' You can resume it.' : ''}`);
  }).catch(() => {});
}

async function onComplete(id: string, path: string, sha256: string, size: number) {
  const d = await patch(id, { status: 'verifying', receivedBytes: size });
  if (!d) return;
  try {
    const meta = d.meta as { format?: string; license?: string; attribution?: string; repo?: string; name?: string };
    if (meta.format === 'coreml-diffusion-zip') {
      const dest = path.replace(/\.zip$/i, '');
      await ZinoStorage.unzip({ path, destination: dest });
      await ZinoStorage.remove({ path });
      await registerDiffusion(dest, { name: d.name, sourceUrl: d.url, license: meta.license ?? null, attribution: meta.attribution ?? null, sha256 });
    } else {
      await registerGGUF(path, { sourceUrl: d.url, license: meta.license ?? null, attribution: meta.attribution ?? null, sha256 });
    }
    await patch(id, { status: 'completed', error: null });
    uiBridge.toast('success', `${d.name} downloaded and verified (SHA-256 matched).`);
  } catch (e) {
    await patch(id, { status: 'failed', error: toZinoError(e).message });
    uiBridge.toast('error', `${d.name} downloaded but could not be installed: ${toZinoError(e).message}`);
  }
}

export interface StartDownloadInput {
  category: ModelCategory;
  name: string;
  repo: string;
  file: HFFile;
  format: 'gguf' | 'coreml-diffusion-zip';
  license?: string;
  attribution?: string;
}

export async function startDownload(input: StartDownloadInput): Promise<DownloadRecord> {
  if (!input.file.sha256) {
    const ok = await uiBridge.confirm({
      title: 'No checksum published',
      message: `Hugging Face does not list a SHA-256 for ${input.file.path}, so ZinoAgent can only verify its size.`,
      confirmLabel: 'Download anyway',
    });
    if (!ok) throw new ZinoError('CANCELLED', 'Download cancelled.');
  }
  const info = await ZinoStorage.info();
  if (info.available >= 0 && input.file.size + 1e9 > info.available) {
    throw new ZinoError('INSUFFICIENT_STORAGE', `Not enough free space: needs ${(input.file.size / 1e9).toFixed(1)} GB plus 1 GB headroom.`);
  }
  const id = uid();
  const fileName = input.file.path.split('/').pop()!;
  const destPath = `${modelDir(input.category)}/${id.slice(0, 8)}-${fileName}`;
  const url = hfResolveUrl(input.repo, input.file.path);
  const rec: DownloadRecord = {
    id, category: input.category, name: input.name, url, destPath, totalBytes: input.file.size, receivedBytes: 0,
    sha256Expected: input.file.sha256, status: 'downloading', error: null,
    meta: { repo: input.repo, format: input.format, license: input.license, attribution: input.attribution }, createdAt: Date.now(), updatedAt: Date.now(),
  };
  await downloadsRepo.save(rec);
  useDownloads.setState((s) => ({ items: [rec, ...s.items] }));
  const auth = await hfAuth();
  try {
    await ZinoDownloads.start({ id, url, dest: destPath, expectedSize: input.file.size, sha256: input.file.sha256 ?? undefined, authAccount: auth?.account });
  } catch (e) {
    await patch(id, { status: 'failed', error: toZinoError(e).message });
    throw toZinoError(e);
  }
  return rec;
}

export async function startCatalogDownload(entry: CatalogEntry) {
  const files = await listHFFiles(entry.repo);
  const file = entry.file
    ? files.find((f) => f.path === entry.file)
    : files.find((f) => new RegExp(entry.filePattern ?? '$^', 'i').test(f.path));
  if (!file) throw new ZinoError('MODEL_NOT_FOUND', `The file was not found in ${entry.repo}. The repository may have changed.`);
  return startDownload({ category: entry.category, name: entry.name, repo: entry.repo, file, format: entry.format, license: entry.license, attribution: entry.attribution });
}

export async function pauseDownload(id: string) {
  const r = await ZinoDownloads.pause({ id });
  await patch(id, { status: 'paused', error: r.resumable === false ? 'The server does not support resuming; it will restart.' : null });
}

export async function resumeDownload(id: string) {
  const d = await downloadsRepo.get(id);
  if (!d) return;
  await patch(id, { status: 'downloading', error: null });
  try {
    const auth = await hfAuth();
    await ZinoDownloads.start({ id, url: d.url, dest: d.destPath, expectedSize: d.totalBytes ?? undefined, sha256: d.sha256Expected ?? undefined, authAccount: auth?.account });
  } catch (e) {
    await patch(id, { status: 'failed', error: toZinoError(e).message });
    throw toZinoError(e);
  }
}

export async function cancelDownload(id: string) {
  await ZinoDownloads.cancel({ id }).catch(() => {});
  await patch(id, { status: 'cancelled' });
}

export async function removeDownloadRecord(id: string) {
  await downloadsRepo.remove(id);
  await reload();
}
