import { useState } from 'react';
import { Upload } from 'lucide-react';
import type { Asset, AssetKind } from '@/types';
import { assetManager } from '@/services/asset-manager';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { AssetMedia } from './AssetMedia';
import { Dialog, Empty, useAsync } from './ui';

export function AssetPicker({ kind, title, onPick, onClose }: { kind: AssetKind; title?: string; onPick: (a: Asset) => void; onClose: () => void }) {
  const [tick, setTick] = useState(0);
  const { data } = useAsync(() => assetManager.list({ kind }), [kind, tick]);
  const importFiles = async () => {
    try {
      const added = await assetManager.importFromFiles(kind === 'image' ? 'image' : kind === 'video' ? 'video' : kind === 'model3d' ? 'model3d' : 'any');
      const match = added.find((a) => a.kind === kind);
      if (match) { onPick(match); onClose(); } else setTick((t) => t + 1);
    } catch (e) { const err = toZinoError(e); if (err.code !== 'CANCELLED') uiBridge.toast('error', err.message); }
  };
  return (
    <Dialog wide title={title ?? 'Choose from Assets'} onClose={onClose} actions={<button className="btn" onClick={importFiles}><Upload size={16} /> Import from Files</button>}>
      {data && data.length === 0 ? <Empty title="Nothing here yet">Import a file from the Files app, or generate one in a studio.</Empty> : (
        <div className="gallery" style={{ maxHeight: '60vh', overflow: 'auto' }}>
          {(data ?? []).map((a) => (
            <div key={a.id} className="gallery-item" onClick={() => { onPick(a); onClose(); }}>
              <div className="media"><AssetMedia asset={a} /></div>
              <div className="caption truncate">{a.name}</div>
            </div>
          ))}
        </div>
      )}
    </Dialog>
  );
}
