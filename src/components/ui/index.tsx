// Small, dependency-free UI primitives.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { X } from 'lucide-react';
import { RECOVERY_LABELS, type RecoveryAction, type ZinoError } from '@/services/errors';

export function Toggle({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return <button type="button" role="switch" aria-checked={on} aria-label={label} className={`toggle ${on ? 'on' : ''}`} disabled={disabled} onClick={() => onChange(!on)} />;
}

export function Segmented<T extends string>({ value, options, onChange, disabled }: {
  value: T; options: { value: T; label: ReactNode; disabled?: boolean; title?: string }[]; onChange: (v: T) => void; disabled?: boolean;
}) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={o.value === value} title={o.title}
          className={o.value === value ? 'active' : ''} disabled={disabled || o.disabled} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

export function Field({ label, hint, children }: { label: ReactNode; hint?: ReactNode; children: ReactNode }) {
  return <div className="field"><label>{label}</label>{children}{hint && <div className="hint">{hint}</div>}</div>;
}

export function Progress({ value, tone }: { value: number; tone?: 'warn' | 'danger' }) {
  return <div className={`progress ${tone ?? ''}`}><div style={{ width: `${Math.max(0, Math.min(100, value * 100))}%` }} /></div>;
}

export function Spinner() { return <span className="spinner" aria-label="Loading" />; }

export function Empty({ icon, title, children }: { icon?: ReactNode; title: string; children?: ReactNode }) {
  return <div className="empty">{icon}<h3>{title}</h3>{children && <div className="small" style={{ maxWidth: 440 }}>{children}</div>}</div>;
}

/** Popover anchored to its trigger; closes on outside tap. */
export function Popover({ trigger, children, align = 'left', open: controlled, onOpenChange, width }: {
  trigger: (toggle: () => void, open: boolean) => ReactNode; children: ReactNode | ((close: () => void) => ReactNode);
  align?: 'left' | 'right'; open?: boolean; onOpenChange?: (o: boolean) => void; width?: number;
}) {
  const [inner, setInner] = useState(false);
  const open = controlled ?? inner;
  const setOpen = (o: boolean) => { setInner(o); onOpenChange?.(o); };
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const h = (e: PointerEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('pointerdown', h);
    return () => document.removeEventListener('pointerdown', h);
  });
  return (
    <div className="popover-anchor" ref={ref}>
      {trigger(() => setOpen(!open), open)}
      {open && (
        <div className={`popover ${align === 'right' ? 'right' : ''}`} style={width ? { width } : undefined}>
          {typeof children === 'function' ? children(() => setOpen(false)) : children}
        </div>
      )}
    </div>
  );
}

export function Menu({ trigger, items, align = 'right' }: {
  trigger: (toggle: () => void) => ReactNode;
  items: ({ label: string; icon?: ReactNode; onSelect: () => void; danger?: boolean; disabled?: boolean } | 'sep')[];
  align?: 'left' | 'right';
}) {
  return (
    <Popover align={align} trigger={(t) => trigger(t)}>
      {(close) => items.map((it, i) => it === 'sep'
        ? <div className="menu-sep" key={i} />
        : <button key={i} className={`menu-item ${it.danger ? 'danger' : ''}`} disabled={it.disabled}
            onClick={(e) => { e.stopPropagation(); close(); it.onSelect(); }}>{it.icon}{it.label}</button>)}
    </Popover>
  );
}

export function Dialog({ title, children, onClose, actions, wide }: { title: ReactNode; children: ReactNode; onClose: () => void; actions?: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', h);
    return () => window.removeEventListener('keydown', h);
  }, [onClose]);
  return (
    <div className="backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={`dialog ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true">
        <div className="row" style={{ marginBottom: 14 }}>
          <h2 className="grow">{title}</h2>
          <button className="icon-btn sm" onClick={onClose} aria-label="Close"><X size={18} /></button>
        </div>
        {children}
        {actions && <div className="dialog-actions">{actions}</div>}
      </div>
    </div>
  );
}

export function ErrorNotice({ error, onRecovery }: { error: ZinoError | null; onRecovery?: (a: RecoveryAction) => void }) {
  if (!error) return null;
  return (
    <div className="notice danger">
      <div className="stack-sm grow">
        <div>{error.message}</div>
        {onRecovery && error.recovery.length > 0 && (
          <div className="row wrap">{error.recovery.map((r) => <button key={r} className="btn sm" onClick={() => onRecovery(r)}>{RECOVERY_LABELS[r]}</button>)}</div>
        )}
      </div>
    </div>
  );
}

export function CompatBadge({ value }: { value: string | null | undefined }) {
  if (!value) return null;
  const map: Record<string, [string, string]> = {
    compatible: ['success', 'Compatible'], limited: ['warning', 'Compatible with limitations'],
    experimental: ['warning', 'Experimental'], unsupported: ['danger', 'Unsupported'],
  };
  const [tone, label] = map[value] ?? ['', value];
  return <span className={`badge ${tone}`}>{label}</span>;
}

export function useAsync<T>(fn: () => Promise<T>, deps: unknown[]): { data: T | null; loading: boolean; error: unknown; reload: () => void } {
  const [state, setState] = useState<{ data: T | null; loading: boolean; error: unknown }>({ data: null, loading: true, error: null });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setState((s) => ({ ...s, loading: true }));
    fn().then((data) => { if (alive) setState({ data, loading: false, error: null }); })
      .catch((error) => { if (alive) setState({ data: null, loading: false, error }); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { ...state, reload: () => setTick((t) => t + 1) };
}
