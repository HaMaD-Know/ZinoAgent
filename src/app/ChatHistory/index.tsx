import { useEffect, useState } from 'react';
import { Archive, ArchiveRestore, Download, Folder, FolderInput, MoreHorizontal, Pencil, Pin, PinOff, Plus, Search, Trash2 } from 'lucide-react';
import type { Chat, ChatFolder } from '@/types';
import { chatsRepo, foldersRepo } from '@/database/repositories';
import { uiBridge } from '@/services/ui-bridge';
import { toZinoError } from '@/services/errors';
import { Dialog, Menu } from '@/components/ui';
import { exportChat } from './export';

export function ChatHistory({ currentId, onSelect, onNew, refreshKey, className }: {
  currentId: string | null; onSelect: (id: string) => void; onNew: () => void; refreshKey: number; className?: string;
}) {
  const [chats, setChats] = useState<Chat[]>([]);
  const [folders, setFolders] = useState<ChatFolder[]>([]);
  const [search, setSearch] = useState('');
  const [archived, setArchived] = useState(false);
  const [folderFilter, setFolderFilter] = useState<string | null>(null);
  const [rename, setRename] = useState<Chat | null>(null);
  const [moveChat, setMoveChat] = useState<Chat | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let alive = true;
    const t = setTimeout(async () => {
      const [c, f] = await Promise.all([chatsRepo.list({ archived, search }), foldersRepo.list()]);
      if (alive) { setChats(c); setFolders(f); }
    }, search ? 200 : 0);
    return () => { alive = false; clearTimeout(t); };
  }, [archived, search, refreshKey, tick]);

  const refresh = () => setTick((t) => t + 1);
  const run = async (fn: () => Promise<unknown>) => { try { await fn(); refresh(); } catch (e) { uiBridge.toast('error', toZinoError(e).message); } };
  const visible = folderFilter ? chats.filter((c) => c.folderId === folderFilter) : chats;
  const pinned = visible.filter((c) => c.pinned);
  const rest = visible.filter((c) => !c.pinned);

  const item = (c: Chat) => (
    <div key={c.id} className={`chat-item ${c.id === currentId ? 'active' : ''}`} onClick={() => onSelect(c.id)}>
      <div className="title truncate">{c.title}</div>
      {c.pinned && <Pin size={13} className="faint" />}
      <Menu trigger={(t) => <button className="icon-btn sm" aria-label="Chat options" onClick={(e) => { e.stopPropagation(); t(); }}><MoreHorizontal size={16} /></button>} items={[
        { label: 'Rename', icon: <Pencil size={15} />, onSelect: () => setRename(c) },
        { label: c.pinned ? 'Unpin' : 'Pin', icon: c.pinned ? <PinOff size={15} /> : <Pin size={15} />, onSelect: () => run(() => chatsRepo.update(c.id, { pinned: !c.pinned, updatedAt: c.updatedAt })) },
        { label: 'Move to folder', icon: <FolderInput size={15} />, onSelect: () => setMoveChat(c) },
        { label: c.archived ? 'Unarchive' : 'Archive', icon: c.archived ? <ArchiveRestore size={15} /> : <Archive size={15} />, onSelect: () => run(() => chatsRepo.update(c.id, { archived: !c.archived, updatedAt: c.updatedAt })) },
        { label: 'Export conversation', icon: <Download size={15} />, onSelect: () => run(() => exportChat(c.id)) },
        'sep',
        { label: 'Delete', icon: <Trash2 size={15} />, danger: true, onSelect: async () => {
          const ok = await uiBridge.confirm({ title: `Delete "${c.title}"?`, message: 'The conversation, its summaries and context data will be permanently deleted from this iPad. Generated assets stay in the Assets library.', confirmLabel: 'Delete chat', destructive: true });
          if (ok) await run(async () => { await chatsRepo.remove(c.id); if (c.id === currentId) onNew(); });
        } },
      ]} />
    </div>
  );

  return (
    <aside className={`chat-list ${className ?? ''}`}>
      <div className="chat-list-header">
        <div className="row"><h3 className="grow">Chats</h3><button className="btn primary sm" onClick={onNew}><Plus size={15} /> New chat</button></div>
        <div className="row"><Search size={15} className="faint" /><input className="input" placeholder="Search chats and messages" value={search} onChange={(e) => setSearch(e.target.value)} style={{ minHeight: 34 }} /></div>
        <div className="row wrap" style={{ gap: 6 }}>
          <button className={`chip`} style={{ cursor: 'pointer', borderColor: !folderFilter && !archived ? 'var(--accent)' : undefined }} onClick={() => { setFolderFilter(null); setArchived(false); }}>All</button>
          {folders.map((f) => <button key={f.id} className="chip" style={{ cursor: 'pointer', borderColor: folderFilter === f.id ? 'var(--accent)' : undefined }} onClick={() => setFolderFilter(folderFilter === f.id ? null : f.id)}><Folder size={13} />{f.name}</button>)}
          <button className="chip" style={{ cursor: 'pointer', borderColor: archived ? 'var(--accent)' : undefined }} onClick={() => setArchived(!archived)}><Archive size={13} />Archived</button>
        </div>
      </div>
      <div className="chat-list-body">
        {pinned.length > 0 && <div className="section-title" style={{ margin: '6px 10px' }}>Pinned</div>}
        {pinned.map(item)}
        {pinned.length > 0 && rest.length > 0 && <div className="section-title" style={{ margin: '10px 10px 6px' }}>Recent</div>}
        {rest.map(item)}
        {visible.length === 0 && <p className="small muted" style={{ padding: 12 }}>{search ? 'No matching chats.' : archived ? 'No archived chats.' : 'No chats yet.'}</p>}
      </div>
      {rename && <RenameDialog chat={rename} onClose={() => setRename(null)} onSave={(t) => run(() => chatsRepo.update(rename.id, { title: t, titleAuto: false, updatedAt: rename.updatedAt }))} />}
      {moveChat && <MoveDialog chat={moveChat} folders={folders} onClose={() => setMoveChat(null)} onMove={(fid) => run(() => chatsRepo.update(moveChat.id, { folderId: fid, updatedAt: moveChat.updatedAt }))}
        onCreate={async (name) => { const f = await foldersRepo.create(name); await chatsRepo.update(moveChat.id, { folderId: f.id, updatedAt: moveChat.updatedAt }); refresh(); }}
        onDeleteFolder={(id) => run(() => foldersRepo.remove(id))} />}
    </aside>
  );
}

function RenameDialog({ chat, onClose, onSave }: { chat: Chat; onClose: () => void; onSave: (t: string) => void }) {
  const [t, setT] = useState(chat.title);
  const save = () => { if (t.trim()) { onSave(t.trim()); onClose(); } };
  return (
    <Dialog title="Rename chat" onClose={onClose} actions={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={save}>Save</button></>}>
      <input className="input" autoFocus value={t} onChange={(e) => setT(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && save()} />
    </Dialog>
  );
}

function MoveDialog({ chat, folders, onClose, onMove, onCreate, onDeleteFolder }: {
  chat: Chat; folders: ChatFolder[]; onClose: () => void; onMove: (id: string | null) => void; onCreate: (n: string) => Promise<void>; onDeleteFolder: (id: string) => void;
}) {
  const [name, setName] = useState('');
  return (
    <Dialog title={`Move "${chat.title}"`} onClose={onClose}>
      <div className="list">
        <div className={`list-item ${!chat.folderId ? 'active' : ''}`} onClick={() => { onMove(null); onClose(); }}>No folder</div>
        {folders.map((f) => (
          <div key={f.id} className={`list-item ${chat.folderId === f.id ? 'active' : ''}`} onClick={() => { onMove(f.id); onClose(); }}>
            <Folder size={16} /><span className="grow">{f.name}</span>
            <button className="icon-btn sm" aria-label="Delete folder" onClick={(e) => { e.stopPropagation(); onDeleteFolder(f.id); }}><Trash2 size={14} /></button>
          </div>
        ))}
      </div>
      <div className="row" style={{ marginTop: 12 }}>
        <input className="input" placeholder="New folder name" value={name} onChange={(e) => setName(e.target.value)} />
        <button className="btn" disabled={!name.trim()} onClick={async () => { await onCreate(name.trim()); onClose(); }}>Create & move</button>
      </div>
    </Dialog>
  );
}
