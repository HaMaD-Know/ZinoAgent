import { useEffect, useState } from 'react';
import { AlertTriangle, CheckCircle2, Info, X, XCircle } from 'lucide-react';
import { uiBridge, type ConfirmRequest, type Toast } from '@/services/ui-bridge';
import { Dialog } from './ui';

/** Installs the confirm/toast handlers used by services and renders them. */
export function UIHost() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [queue, setQueue] = useState<{ req: ConfirmRequest; resolve: (v: boolean) => void }[]>([]);

  useEffect(() => {
    uiBridge.setToastHandler((t) => {
      setToasts((ts) => [...ts.slice(-3), t]);
      setTimeout(() => setToasts((ts) => ts.filter((x) => x.id !== t.id)), t.kind === 'error' ? 9000 : 5000);
    });
    uiBridge.setConfirmHandler((req) => new Promise<boolean>((resolve) => setQueue((q) => [...q, { req, resolve }])));
  }, []);

  const current = queue[0];
  const answer = (v: boolean) => { current?.resolve(v); setQueue((q) => q.slice(1)); };
  const icon = { error: <XCircle size={18} color="var(--danger)" />, warning: <AlertTriangle size={18} color="var(--warning)" />, success: <CheckCircle2 size={18} color="var(--success)" />, info: <Info size={18} color="var(--accent)" /> };

  return (
    <>
      <div className="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.kind}`}>
            {icon[t.kind]}
            <div className="grow">{t.message}{t.action && <div style={{ marginTop: 6 }}><button className="btn sm" onClick={t.action.run}>{t.action.label}</button></div>}</div>
            <button className="icon-btn sm" onClick={() => setToasts((ts) => ts.filter((x) => x.id !== t.id))} aria-label="Dismiss"><X size={16} /></button>
          </div>
        ))}
      </div>
      {current && (
        <Dialog title={current.req.title} onClose={() => answer(false)} actions={<>
          <button className="btn" onClick={() => answer(false)}>{current.req.cancelLabel ?? 'Cancel'}</button>
          <button className={`btn ${current.req.destructive ? 'danger solid' : 'primary'}`} onClick={() => answer(true)}>{current.req.confirmLabel ?? 'Continue'}</button>
        </>}>
          <p className="muted">{current.req.message}</p>
          {current.req.details && current.req.details.length > 0 && (
            <ul className="small mono" style={{ maxHeight: 220, overflow: 'auto', background: 'var(--surface-2)', borderRadius: 8, padding: '10px 10px 10px 28px', marginTop: 12 }}>
              {current.req.details.map((d, i) => <li key={i}>{d}</li>)}
            </ul>
          )}
        </Dialog>
      )}
    </>
  );
}
