import { useCallback, useEffect, useState } from 'react';
import { ChevronRight, File, FileText, Folder, FolderPlus, History, Image, MoreHorizontal, Plus, RefreshCw, Trash2, Undo2, X, Box, Film } from 'lucide-react';
import type { FileOperation } from '@/types';
import { ZinoFiles, type FileEntry, type FolderRoot } from '@/native';
import { fileOpsRepo, uid } from '@/database/repositories';
import { categoryOf, fileOps, undoOperation } from '@/services/file-manager';
import { formatBytes } from '@/services/resources';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { Dialog, Menu, Spinner } from '../ui';

const iconFor = (e: FileEntry) => {
  if (e.isDirectory) return <Folder size={18} color="var(--accent)" />;
  const c = categoryOf(e.ext);
  return c === 'Images' ? <Image size={18} /> : c === '3D Models' ? <Box size={18} /> : c === 'Videos' ? <Film size={18} /> : c === 'Documents' ? <FileText size={18} /> : <File size={18} />;
};

export function FileExplorer({ rootId, onRootChange }: { rootId: string | null; onRootChange: (r: FolderRoot | null) => void }) {
  const [roots, setRoots] = useState<FolderRoot[]>([]);
  const [path, setPath] = useState('');
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [view, setView] = useState<'files' | 'history'>('files');
  const [ops, setOps] = useState<FileOperation[]>([]);
  const [prompt, setPrompt] = useState<{ title: string; value: string; onSubmit: (v: string) => Promise<void> } | null>(null);

  const loadRoots = useCallback(async () => {
    const r = (await ZinoFiles.listRoots()).roots;
    setRoots(r);
    return r;
  }, []);
  const load = useCallback(async () => {
    if (!rootId) return;
    setLoading(true);
    try { setEntries((await ZinoFiles.list({ rootId, path })).entries.sort((a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.name.localeCompare(b.name))); }
    catch (e) { uiBridge.toast('error', toZinoError(e).message); setEntries([]); }
    finally { setLoading(false); }
  }, [rootId, path]);

  useEffect(() => { void loadRoots(); }, [loadRoots]);
  useEffect(() => { setPath(''); }, [rootId]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (view === 'history') void fileOpsRepo.list(100).then(setOps); }, [view]);

  const root = roots.find((r) => r.id === rootId) ?? null;
  const ctx = () => ({ rootId: rootId!, groupId: uid() });
  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    try { await fn(); if (ok) uiBridge.toast('success', ok); await load(); } catch (e) { uiBridge.toast('error', toZinoError(e).message); }
  };

  const pick = async () => {
    try { const r = await ZinoFiles.pickFolder(); const all = await loadRoots(); onRootChange(all.find((x) => x.id === r.id) ?? null); }
    catch (e) { const err = toZinoError(e); if (err.code !== 'CANCELLED') uiBridge.toast('error', err.message); }
  };

  if (!rootId || !root) {
    return (
      <div className="stack">
        <p className="small muted">Choose a folder in the Files app. ZinoAgent (and the AI, through validated tools) can work only inside folders you authorise.</p>
        <button className="btn primary" onClick={pick}><FolderPlus size={16} /> Authorise a folder</button>
        {roots.length > 0 && <div className="section-title">Previously authorised</div>}
        {roots.map((r) => (
          <div key={r.id} className="list-item" onClick={() => onRootChange(r)}>
            <Folder size={18} /><span className="grow">{r.name}</span>{!r.accessible && <span className="badge warning">Access lost</span>}
            <button className="icon-btn sm" aria-label="Forget folder" onClick={async (e) => { e.stopPropagation(); await ZinoFiles.removeRoot({ rootId: r.id }); void loadRoots(); }}><X size={15} /></button>
          </div>
        ))}
      </div>
    );
  }

  const crumbs = path ? path.split('/') : [];
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="row">
        <Folder size={16} color="var(--accent)" /><strong className="grow truncate">{root.name}</strong>
        <button className={`icon-btn sm`} title="Operation history" onClick={() => setView(view === 'files' ? 'history' : 'files')}><History size={16} /></button>
        <button className="icon-btn sm" title="Refresh" onClick={() => void load()}><RefreshCw size={15} /></button>
        <button className="icon-btn sm" title="Stop using this folder" onClick={() => onRootChange(null)}><X size={16} /></button>
      </div>
      {view === 'history' ? (
        <div className="stack-sm">
          <div className="section-title" style={{ marginTop: 0 }}>Recent file operations</div>
          {ops.length === 0 && <p className="small muted">No operations yet.</p>}
          {ops.map((op) => (
            <div key={op.id} className="row small" style={{ padding: '4px 0' }}>
              <div className="grow"><strong style={{ textTransform: 'capitalize' }}>{op.op}</strong> <span className="mono tiny">{op.srcPath}{op.dstPath ? ` → ${op.dstPath}` : ''}</span>
                <div className="tiny faint">{new Date(op.createdAt).toLocaleString()} {op.status === 'undone' && '· undone'}</div></div>
              {op.status === 'done' && op.rootId === rootId && (
                <button className="btn sm" onClick={async () => {
                  try { uiBridge.toast('success', await undoOperation(op)); setOps(await fileOpsRepo.list(100)); await load(); }
                  catch (e) { uiBridge.toast('error', toZinoError(e).message); }
                }}><Undo2 size={14} /> Undo</button>
              )}
            </div>
          ))}
        </div>
      ) : (
        <>
          <div className="row wrap small" style={{ gap: 2 }}>
            <button className="btn ghost sm" onClick={() => setPath('')}>{root.name}</button>
            {crumbs.map((c, i) => (
              <span key={i} className="row" style={{ gap: 2 }}><ChevronRight size={14} className="faint" />
                <button className="btn ghost sm" onClick={() => setPath(crumbs.slice(0, i + 1).join('/'))}>{c}</button></span>
            ))}
            <span style={{ flex: 1 }} />
            <button className="icon-btn sm" title="New folder" onClick={() => setPrompt({ title: 'New folder', value: '', onSubmit: (v) => act(() => fileOps.mkdir(ctx(), path ? `${path}/${v}` : v), 'Folder created') })}><Plus size={16} /></button>
          </div>
          {loading ? <Spinner /> : entries.length === 0 ? <p className="small muted">This folder is empty.</p> : (
            <div className="list">
              {entries.map((e) => (
                <div key={e.path} className="list-item" onClick={() => e.isDirectory && setPath(e.path)}>
                  {iconFor(e)}
                  <div className="grow" style={{ minWidth: 0 }}><div className="truncate small">{e.name}</div>
                    <div className="tiny faint">{e.isDirectory ? 'Folder' : formatBytes(e.size)}{e.modified ? ` · ${new Date(e.modified).toLocaleDateString()}` : ''}</div></div>
                  <Menu trigger={(t) => <button className="icon-btn sm" onClick={(ev) => { ev.stopPropagation(); t(); }} aria-label="Actions"><MoreHorizontal size={16} /></button>} items={[
                    { label: 'Rename', onSelect: () => setPrompt({ title: `Rename "${e.name}"`, value: e.name, onSubmit: (v) => act(() => fileOps.rename(ctx(), e.path, v), 'Renamed') }) },
                    { label: 'Move to folder…', onSelect: () => setPrompt({ title: `Move "${e.name}" to (folder path)`, value: path, onSubmit: (v) => act(() => fileOps.move(ctx(), e.path, v), 'Moved') }) },
                    { label: 'Duplicate', onSelect: () => act(() => fileOps.copy(ctx(), e.path, path), 'Copied') },
                    'sep',
                    { label: 'Move to ZinoAgent Trash', icon: <Trash2 size={15} />, danger: true, onSelect: async () => {
                      const ok = await uiBridge.confirm({ title: `Delete "${e.name}"?`, message: 'It will be moved to ".ZinoAgent Trash" in this folder and can be restored from the operation history.', confirmLabel: 'Move to Trash', destructive: true });
                      if (ok) await act(() => fileOps.trash(ctx(), e.path), 'Moved to ZinoAgent Trash');
                    } },
                  ]} />
                </div>
              ))}
            </div>
          )}
        </>
      )}
      {prompt && (
        <Dialog title={prompt.title} onClose={() => setPrompt(null)} actions={<>
          <button className="btn" onClick={() => setPrompt(null)}>Cancel</button>
          <button className="btn primary" onClick={async () => { const p = prompt; setPrompt(null); await p.onSubmit(p.value.trim()); }}>OK</button>
        </>}>
          <input className="input" autoFocus value={prompt.value} onChange={(e) => setPrompt({ ...prompt, value: e.target.value })}
            onKeyDown={async (e) => { if (e.key === 'Enter') { const p = prompt; setPrompt(null); await p.onSubmit(p.value.trim()); } }} />
        </Dialog>
      )}
    </div>
  );
}
