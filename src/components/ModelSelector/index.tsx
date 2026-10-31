// Unified model selector: offline + online models for one studio, with search, provider,
// capabilities, compatibility, context, memory, connection status and default-model selection.
import { useMemo, useState } from 'react';
import { Check, ChevronDown, Cloud, Cpu, Search, Sparkles, Star, WifiOff } from 'lucide-react';
import type { Capability, ModelRef, Studio } from '@/types';
import { STUDIO_CATEGORY } from '@/types';
import { listSelectableModels, type SelectableModel } from '@/services/ai-router/models';
import { formatBytes } from '@/services/resources';
import { useApp } from '@/app/store';
import { CompatBadge, Popover, Spinner, useAsync } from '../ui';

const CAP_LABEL: Record<Capability, string> = {
  chat: 'Chat', reasoning: 'Reasoning', vision: 'Vision', tool_calling: 'Tools', image_generation: 'Image',
  image_editing: 'Edit', threed_generation: '3D', video_generation: 'Video',
};

export const refKey = (r: ModelRef | null | undefined) =>
  !r ? 'none' : r.source === 'auto' ? 'auto' : r.source === 'local' ? `local:${r.modelId}` : `cloud:${r.providerId}:${r.modelId}`;

export function ModelSelector({ studio, value, onChange, busy, allowAuto = true, compact }: {
  studio: Studio; value: ModelRef | null; onChange: (r: ModelRef) => void | Promise<void>; busy?: boolean; allowAuto?: boolean; compact?: boolean;
}) {
  const category = STUDIO_CATEGORY[studio];
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const { data, loading } = useAsync(() => listSelectableModels(category), [category, open]);
  const online = useApp((s) => s.online);
  const defaults = useApp((s) => s.settings.defaultModels[studio]);
  const updateSettings = useApp((s) => s.updateSettings);
  const openSettings = useApp((s) => s.openSettings);
  const setSection = useApp((s) => s.setSection);

  const models = data ?? [];
  const selected = models.find((m) => m.key === refKey(value));
  const filtered = useMemo(() => {
    const t = q.trim().toLowerCase();
    return t ? models.filter((m) => `${m.name} ${m.providerName} ${m.capabilities.join(' ')}`.toLowerCase().includes(t)) : models;
  }, [models, q]);
  const local = filtered.filter((m) => m.source === 'local');
  const cloud = filtered.filter((m) => m.source === 'cloud');

  const label = value?.source === 'auto' ? 'Auto' : selected ? selected.name : value ? 'Unavailable model' : 'Choose a model';
  const sub = value?.source === 'auto' ? 'Picks a model per task' : selected ? selected.providerName : 'No model selected';

  const choose = async (m: SelectableModel | 'auto', close: () => void) => {
    close();
    await onChange(m === 'auto' ? { source: 'auto' } : m.ref);
  };
  const setDefault = async (m: SelectableModel) => {
    await updateSettings((s) => ({ ...s, defaultModels: { ...s.defaultModels, [studio]: m.ref } }));
  };

  const row = (m: SelectableModel, close: () => void) => {
    const isSel = m.key === refKey(value);
    const disabled = m.status === 'unsupported' || (m.source === 'cloud' && !online);
    return (
      <div key={m.key} className={`list-item ${isSel ? 'active' : ''}`} style={{ alignItems: 'flex-start', opacity: disabled ? 0.55 : 1 }}
        onClick={() => !disabled && choose(m, close)} role="option" aria-selected={isSel} aria-disabled={disabled}>
        <div style={{ paddingTop: 2 }}>{m.source === 'local' ? <Cpu size={18} /> : <Cloud size={18} />}</div>
        <div className="grow stack-sm" style={{ gap: 3 }}>
          <div className="row"><strong className="truncate">{m.name}</strong>{m.status === 'loaded' && <span className="badge success">Loaded</span>}
            {refKey(defaults) === m.key && <span className="badge accent">Default</span>}</div>
          <div className="tiny muted row wrap" style={{ gap: 6 }}>
            <span>{m.providerName}</span>
            {m.contextLength ? <span>· {m.contextLength.toLocaleString()} ctx</span> : null}
            {m.memoryBytes ? <span>· ~{formatBytes(m.memoryBytes)} RAM</span> : null}
          </div>
          <div className="row wrap" style={{ gap: 4 }}>
            {m.capabilities.map((c) => <span key={c} className="badge">{CAP_LABEL[c]}</span>)}
            {m.compatibility && <CompatBadge value={m.compatibility} />}
            {m.status === 'error' && <span className="badge danger">Connection error</span>}
            {m.status === 'untested' && <span className="badge warning">Not tested</span>}
          </div>
          {m.statusText && <div className="tiny" style={{ color: m.status === 'error' || m.status === 'unsupported' ? 'var(--danger)' : 'var(--text-3)' }}>{m.statusText}</div>}
        </div>
        <div className="row" style={{ gap: 0 }}>
          {!disabled && refKey(defaults) !== m.key && (
            <button className="icon-btn sm" title="Set as default" aria-label="Set as default" onClick={(e) => { e.stopPropagation(); void setDefault(m); }}><Star size={15} /></button>
          )}
          {isSel && <Check size={18} color="var(--accent)" />}
        </div>
      </div>
    );
  };

  return (
    <Popover width={420} open={open} onOpenChange={setOpen} trigger={(toggle) => (
      <button className="btn" onClick={toggle} disabled={busy} aria-haspopup="listbox" style={{ maxWidth: compact ? 220 : 320, justifyContent: 'flex-start' }}>
        {value?.source === 'auto' ? <Sparkles size={16} /> : selected?.source === 'cloud' ? <Cloud size={16} /> : <Cpu size={16} />}
        <span className="stack-sm" style={{ gap: 0, minWidth: 0, textAlign: 'left' }}>
          <span className="truncate" style={{ fontSize: 14 }}>{label}</span>
          {!compact && <span className="tiny faint truncate">{sub}</span>}
        </span>
        <ChevronDown size={15} />
      </button>
    )}>
      {(close) => (
        <div className="stack-sm" role="listbox">
          <div className="row" style={{ padding: '4px 6px' }}>
            <Search size={16} className="faint" />
            <input className="input" autoFocus placeholder="Search models" value={q} onChange={(e) => setQ(e.target.value)} style={{ minHeight: 34 }} />
          </div>
          <div style={{ maxHeight: 440, overflow: 'auto' }}>
            {allowAuto && (
              <div className={`list-item ${value?.source === 'auto' ? 'active' : ''}`} onClick={() => choose('auto', close)}>
                <Sparkles size={18} />
                <div className="grow"><strong>Auto</strong><div className="tiny muted">Recommends an offline model by task, availability and RAM. Never goes online without asking.</div></div>
                {value?.source === 'auto' && <Check size={18} color="var(--accent)" />}
              </div>
            )}
            {loading && <div className="row" style={{ padding: 12 }}><Spinner /> <span className="muted small">Loading models…</span></div>}
            <div className="section-title" style={{ margin: '10px 8px 4px' }}>Offline · on this iPad</div>
            {local.length ? local.map((m) => row(m, close)) : (
              <div className="tiny muted" style={{ padding: '4px 10px 8px' }}>No offline models installed. <a href="#" onClick={(e) => { e.preventDefault(); close(); setSection('models'); }}>Open Models</a></div>
            )}
            <div className="section-title row" style={{ margin: '10px 8px 4px' }}>Online · cloud APIs {!online && <span className="badge warning"><WifiOff size={12} /> Offline</span>}</div>
            {cloud.length ? cloud.map((m) => row(m, close)) : (
              <div className="tiny muted" style={{ padding: '4px 10px 8px' }}>No cloud models for this studio. <a href="#" onClick={(e) => { e.preventDefault(); close(); openSettings('providers'); }}>Add a provider</a></div>
            )}
          </div>
        </div>
      )}
    </Popover>
  );
}
