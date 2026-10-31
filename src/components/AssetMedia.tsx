import { Box, FileQuestion, Film } from 'lucide-react';
import type { Asset } from '@/types';
import { displayUrl } from '@/native';
import { useAsync } from './ui';

export function useAssetUrl(asset: Asset | null | undefined) {
  return useAsync(async () => (asset ? displayUrl(asset.path) : null), [asset?.id, asset?.path]).data;
}

/** Thumbnail / inline preview for any asset kind. */
export function AssetMedia({ asset, controls }: { asset: Asset; controls?: boolean }) {
  const url = useAssetUrl(asset);
  if (asset.kind === 'image') return url ? <img src={url} alt={asset.name} loading="lazy" draggable={false} /> : null;
  if (asset.kind === 'video') return url ? <video src={url} controls={controls} muted={!controls} playsInline preload="metadata" /> : <Film size={28} />;
  if (asset.kind === 'model3d') return <Box size={32} className="faint" />;
  return <FileQuestion size={28} className="faint" />;
}
