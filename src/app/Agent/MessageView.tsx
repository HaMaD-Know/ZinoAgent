import { useState } from 'react';
import { AlertTriangle, Bot, ChevronDown, ChevronRight, Copy, Undo2, User, Wrench } from 'lucide-react';
import type { ChatMessage } from '@/types';
import { Markdown } from '@/components/Markdown';
import { AssetMedia } from '@/components/AssetMedia';
import { RECOVERY_LABELS, type RecoveryAction } from '@/services/errors';
import { undoGroup } from '@/services/file-manager';
import { uiBridge } from '@/services/ui-bridge';
import { useAsync } from '@/components/ui';
import { assetsRepo } from '@/database/repositories';
import { useApp } from '@/app/store';

function Attachments({ m }: { m: ChatMessage }) {
  const { data } = useAsync(() => assetsRepo.byIds(m.attachments.map((a) => a.assetId)), [m.attachments.map((a) => a.assetId).join(',')]);
  const openAsset = useApp((s) => s.openAsset);
  if (!m.attachments.length) return null;
  return (
    <div className="row wrap" style={{ marginTop: 8 }}>
      {(data ?? []).map((a) => (
        <div key={a.id} className="thumb" style={{ width: a.kind === 'image' ? 140 : 88, height: a.kind === 'image' ? 140 : 88 }} onClick={() => openAsset(a.id)} title={a.name}>
          <AssetMedia asset={a} />
        </div>
      ))}
      {data && data.length < m.attachments.length && <span className="tiny faint">{m.attachments.length - data.length} attachment(s) were deleted from the library.</span>}
    </div>
  );
}

export function MessageView({ m, onRecovery }: { m: ChatMessage; onRecovery: (a: RecoveryAction) => void }) {
  const [showReasoning, setShowReasoning] = useState(false);
  const [showTool, setShowTool] = useState(false);

  if (m.role === 'tool') {
    const changed = Number(m.meta.changed ?? 0);
    const groupId = m.meta.groupId as string | undefined;
    return (
      <div className="message">
        <div className="avatar" style={{ background: 'transparent' }}><Wrench size={15} /></div>
        <div className="content">
          <div className="tool-card">
            <div className="row">
              <button className="btn ghost sm" onClick={() => setShowTool(!showTool)}>{showTool ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                {m.toolName?.replace(/_/g, ' ')} {m.meta.ok === false ? <span className="badge danger">failed</span> : <span className="badge success">done</span>}</button>
              <span className="grow" />
              {changed > 0 && groupId && (
                <button className="btn sm" onClick={async () => {
                  const r = await undoGroup(groupId);
                  uiBridge.toast(r.error ? 'warning' : 'success', r.error ? `Undid ${r.undone} change(s), then stopped: ${r.error}` : `Undid ${r.undone} file change(s).`);
                }}><Undo2 size={14} /> Undo changes</button>
              )}
            </div>
            {showTool && <pre className="selectable" style={{ whiteSpace: 'pre-wrap', maxHeight: 260, overflow: 'auto', margin: '6px 0 0' }}>{m.content}</pre>}
          </div>
        </div>
      </div>
    );
  }

  const isUser = m.role === 'user';
  const err = m.meta.error as { code: string; message: string; recovery: RecoveryAction[] } | undefined;
  const effort = m.meta.effort as { level: string; applied: string[]; notApplied: string[] } | undefined;
  const usage = m.meta.usage as { inputTokens?: number; outputTokens?: number } | undefined;
  return (
    <div className={`message ${isUser ? 'user' : 'assistant'}`}>
      <div className="avatar">{isUser ? <User size={16} /> : <Bot size={16} />}</div>
      <div className="content">
        {m.reasoning && (
          <div>
            <button className="btn ghost sm" onClick={() => setShowReasoning(!showReasoning)}>{showReasoning ? <ChevronDown size={14} /> : <ChevronRight size={14} />} Reasoning</button>
            {showReasoning && <div className="reasoning selectable">{m.reasoning}</div>}
          </div>
        )}
        <div className={isUser ? 'bubble' : ''}>
          {m.content ? <Markdown text={m.content} /> : m.status === 'streaming' ? <span className="faint">…</span> : null}
          {m.toolCalls.length > 0 && !isUser && (
            <div className="tiny muted" style={{ marginTop: 6 }}>Requested: {m.toolCalls.map((c) => c.name.replace(/_/g, ' ')).join(', ')}</div>
          )}
          <Attachments m={m} />
        </div>
        {err && (
          <div className="notice danger small" style={{ marginTop: 8 }}>
            <AlertTriangle size={16} />
            <div className="stack-sm grow"><div>{err.message}</div>
              {err.recovery?.length > 0 && <div className="row wrap">{err.recovery.map((r) => <button key={r} className="btn sm" onClick={() => onRecovery(r)}>{RECOVERY_LABELS[r]}</button>)}</div>}
            </div>
          </div>
        )}
        {m.status === 'cancelled' && <div className="tiny faint" style={{ marginTop: 4 }}>Stopped.</div>}
        {!!m.meta.interrupted && <div className="tiny" style={{ color: 'var(--warning)', marginTop: 4 }}>Interrupted — the app was closed before this reply finished.</div>}
        {!isUser && m.status === 'complete' && (
          <div className="meta">
            {m.meta.model ? <span>{String(m.meta.model)}</span> : null}
            {effort && <span title={[...effort.applied, ...effort.notApplied].join('\n')}>Effort: {effort.level}</span>}
            {typeof m.meta.tokensPerSecond === 'number' && m.meta.tokensPerSecond > 0 && <span>{(m.meta.tokensPerSecond as number).toFixed(1)} tok/s</span>}
            {usage?.outputTokens ? <span>{usage.inputTokens ?? '?'} in · {usage.outputTokens} out</span> : null}
            {!!m.meta.templateFallback && <span style={{ color: 'var(--warning)' }}>generic chat template</span>}
            {m.content && <button className="icon-btn sm" aria-label="Copy" onClick={() => { void navigator.clipboard?.writeText(m.content); uiBridge.toast('success', 'Copied'); }}><Copy size={13} /></button>}
          </div>
        )}
      </div>
    </div>
  );
}
