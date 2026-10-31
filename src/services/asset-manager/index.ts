// Unified local asset library: generated images, 3D models, videos, imports and exports.
// Assets live in app storage; nothing is uploaded anywhere unless the user explicitly sends it.
import type { Asset, AssetKind } from '@/types';
import { assetsRepo, uid } from '@/database/repositories';
import { ZinoStorage, displayUrl } from '@/native';
import { ZinoError } from '@/services/errors';

const EXT: Record<string, string> = {
  'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif', 'image/heic': 'heic',
  'model/gltf-binary': 'glb', 'model/gltf+json': 'gltf', 'video/mp4': 'mp4', 'video/quicktime': 'mov',
};
export const MIME_BY_EXT: Record<string, string> = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif', heic: 'image/heic',
  glb: 'model/gltf-binary', gltf: 'model/gltf+json', obj: 'model/obj', usdz: 'model/vnd.usdz+zip', stl: 'model/stl', fbx: 'application/octet-stream',
  mp4: 'video/mp4', mov: 'video/quicktime', m4v: 'video/mp4',
};
export const kindForExt = (ext: string): AssetKind =>
  ['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic'].includes(ext) ? 'image'
    : ['glb', 'gltf', 'obj', 'usdz', 'stl', 'fbx', 'ply'].includes(ext) ? 'model3d'
      : ['mp4', 'mov', 'm4v'].includes(ext) ? 'video' : 'import';

/** Read width/height from PNG/JPEG bytes without decoding the image. */
export function imageSize(b64: string): { width: number; height: number } | null {
  try {
    const bin = atob(b64.slice(0, 64_000));
    const at = (i: number) => bin.charCodeAt(i);
    if (at(0) === 0x89 && bin.slice(1, 4) === 'PNG') {
      return { width: (at(16) << 24) | (at(17) << 16) | (at(18) << 8) | at(19), height: (at(20) << 24) | (at(21) << 16) | (at(22) << 8) | at(23) };
    }
    if (at(0) === 0xff && at(1) === 0xd8) {
      let i = 2;
      while (i < bin.length) {
        if (at(i) !== 0xff) return null;
        const marker = at(i + 1);
        const len = (at(i + 2) << 8) | at(i + 3);
        if (marker >= 0xc0 && marker <= 0xc3) return { height: (at(i + 5) << 8) | at(i + 6), width: (at(i + 7) << 8) | at(i + 8) };
        i += 2 + len;
      }
    }
  } catch { /* fallthrough */ }
  return null;
}

export interface SaveAssetInput {
  kind: AssetKind;
  name: string;
  mime: string;
  base64?: string;
  /** Existing app-storage path (e.g. a file the native layer already wrote). */
  path?: string;
  chatId?: string | null;
  messageId?: string | null;
  taskId?: string | null;
  parentAssetId?: string | null;
  width?: number | null;
  height?: number | null;
  durationSec?: number | null;
  metadata?: Record<string, unknown>;
}

export const assetManager = {
  list: assetsRepo.list,
  get: assetsRepo.get,
  byIds: assetsRepo.byIds,

  async save(input: SaveAssetInput): Promise<Asset> {
    const id = uid();
    let path = input.path;
    let size = 0;
    let width = input.width ?? null;
    let height = input.height ?? null;
    if (input.base64) {
      const ext = EXT[input.mime] ?? 'bin';
      path = `assets/${input.kind}/${id}.${ext}`;
      size = (await ZinoStorage.writeBase64({ path, data: input.base64 })).size;
      if (input.kind === 'image' && (!width || !height)) {
        const d = imageSize(input.base64);
        if (d) { width = d.width; height = d.height; }
      }
    } else if (path) {
      const s = await ZinoStorage.stat({ path });
      if (!s.exists) throw new ZinoError('FILE_NOT_FOUND', 'The generated file is missing.');
      size = s.size ?? 0;
    } else throw new ZinoError('INVALID_ARGUMENT', 'Nothing to save.');
    const asset: Asset = {
      id, kind: input.kind, name: input.name, path: path!, mime: input.mime, sizeBytes: size, width, height,
      durationSec: input.durationSec ?? null, chatId: input.chatId ?? null, messageId: input.messageId ?? null, taskId: input.taskId ?? null,
      parentAssetId: input.parentAssetId ?? null, metadata: input.metadata ?? {}, createdAt: Date.now(),
    };
    await assetsRepo.save(asset);
    return asset;
  },

  /** Import files from the Files app into the library (copies; originals are untouched). */
  async importFromFiles(kind: 'image' | 'model3d' | 'video' | 'any'): Promise<Asset[]> {
    const { files } = await ZinoStorage.pickAndImport({ kind, destDir: 'assets/import', multiple: true });
    const out: Asset[] = [];
    for (const f of files) {
      const ext = f.name.split('.').pop()?.toLowerCase() ?? '';
      const k = kindForExt(ext);
      const asset: Asset = {
        id: uid(), kind: k === 'import' ? 'import' : k, name: f.originalName, path: f.path, mime: MIME_BY_EXT[ext] ?? 'application/octet-stream',
        sizeBytes: f.size, width: null, height: null, durationSec: null, chatId: null, messageId: null, taskId: null, parentAssetId: null,
        metadata: { imported: true }, createdAt: Date.now(),
      };
      await assetsRepo.save(asset);
      out.push(asset);
    }
    return out;
  },

  async rename(id: string, name: string) {
    if (!name.trim()) throw new ZinoError('INVALID_NAME', 'Name cannot be empty.');
    await assetsRepo.rename(id, name.trim());
  },

  /** Delete the asset and its file. Callers must have confirmed with the user. */
  async remove(id: string) {
    const a = await assetsRepo.get(id);
    if (!a) return;
    await ZinoStorage.remove({ path: a.path }).catch(() => {});
    await assetsRepo.remove(id);
  },

  async exportAsset(id: string) {
    const a = await assetsRepo.get(id);
    if (!a) throw new ZinoError('NOT_FOUND', 'Asset not found.');
    return ZinoStorage.share({ path: a.path });
  },

  async readBase64(a: Asset) { return (await ZinoStorage.readBase64({ path: a.path })).data; },

  url: async (a: Asset) => displayUrl(a.path),
};
