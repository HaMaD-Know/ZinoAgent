import { useMemo } from 'react';
import { Cpu, Thermometer } from 'lucide-react';
import { formatBytes, unloadModel, useResources } from '@/services/resources';
import { useTasks } from '@/services/generation/queue';
import { Progress } from '../ui';

/** Compact sidebar meter. */
export function RamMeter() {
  const snap = useResources((s) => s.snapshot);
  const loading = useResources((s) => s.loading);
  if (!snap) return null;
  const used = snap.appFootprint;
  const limit = snap.availableMemory > 0 ? used + snap.availableMemory : snap.physicalMemory;
  const ratio = limit > 0 && used > 0 ? used / limit : 0;
  const hot = snap.thermalState === 'serious' || snap.thermalState === 'critical';
  return (
    <div className="meter" title="App memory vs. what iPadOS currently allows">
      <div className="row"><Cpu size={14} /><span className="meter-text grow">{formatBytes(used)} used</span>{hot && <Thermometer size={14} color="var(--danger)" />}</div>
      <div className="bar"><Progress value={ratio} tone={ratio > 0.85 ? 'danger' : ratio > 0.65 ? 'warn' : undefined} /></div>
      {loading && <div className="meter-text tiny muted" style={{ marginTop: 4 }}>Loading {loading.name}… {Math.round(loading.progress * 100)}%</div>}
    </div>
  );
}

/** Full resource dashboard. */
export function ResourceDashboard() {
  const { snapshot: s, loaded, pressure, paused, pauseReason, history } = useResources();
  const allTasks = useTasks((t) => t.tasks);
  const tasks = useMemo(() => allTasks.filter((x) => x.status === 'queued' || x.status === 'running'), [allTasks]);
  if (!s) return <p className="muted">Collecting device metrics…</p>;
  const limit = s.availableMemory > 0 ? s.appFootprint + s.availableMemory : -1;
  const max = Math.max(1, ...history.map((h) => h.footprint));
  return (
    <div className="stack">
      {s.estimated && <div className="notice warning small">Browser preview: values are approximations. On iPad these come from iPadOS (task_vm_info, os_proc_available_memory, thermal state).</div>}
      <div className="grid-3">
        <div className="card stat"><span className="value">{formatBytes(s.physicalMemory)}</span><span className="label">Device RAM ({s.deviceModel})</span></div>
        <div className="card stat"><span className="value">{formatBytes(s.appFootprint)}</span><span className="label">App memory footprint</span></div>
        <div className="card stat"><span className="value">{formatBytes(s.availableMemory)}</span><span className="label">More memory iPadOS allows now</span></div>
        <div className="card stat"><span className="value" style={{ textTransform: 'capitalize' }}>{pressure}</span><span className="label">Memory pressure</span></div>
        <div className="card stat"><span className="value" style={{ textTransform: 'capitalize', color: s.thermalState === 'serious' || s.thermalState === 'critical' ? 'var(--danger)' : undefined }}>{s.thermalState}</span><span className="label">Thermal state{s.lowPowerMode ? ' · Low Power Mode' : ''}</span></div>
        <div className="card stat"><span className="value">{formatBytes(s.storageAvailable)}</span><span className="label">Free storage of {formatBytes(s.storageTotal)}</span></div>
      </div>
      {limit > 0 && (
        <div className="card stack-sm">
          <div className="row"><strong className="grow small">App memory (last {history.length * 5}s)</strong><span className="tiny muted">limit now ≈ {formatBytes(limit)}</span></div>
          <svg viewBox={`0 0 ${Math.max(1, history.length - 1)} 40`} preserveAspectRatio="none" style={{ width: '100%', height: 60 }}>
            <polyline fill="none" stroke="var(--accent)" strokeWidth="0.6" vectorEffect="non-scaling-stroke"
              points={history.map((h, i) => `${i},${40 - (h.footprint / max) * 38}`).join(' ')} />
          </svg>
        </div>
      )}
      {paused && <div className="notice warning small">{pauseReason}</div>}
      <div className="card">
        <div className="section-title" style={{ marginTop: 0 }}>Loaded models</div>
        {loaded.length === 0 ? <p className="muted small">No heavy model is loaded.</p> : loaded.map((m) => (
          <div key={m.kind} className="row" style={{ padding: '6px 0' }}>
            <div className="grow"><strong>{m.name}</strong><div className="tiny muted">{m.kind === 'llama' ? 'Chat (llama.cpp)' : 'Image (Core ML)'} · {m.busy ? 'busy' : 'idle'}{m.contextLength ? ` · ${m.contextLength} ctx` : ''}{m.loadMs ? ` · loaded in ${(m.loadMs / 1000).toFixed(1)}s` : ''}</div></div>
            <button className="btn sm" onClick={() => unloadModel(m.kind)}>Unload</button>
          </div>
        ))}
      </div>
      <div className="card">
        <div className="section-title" style={{ marginTop: 0 }}>Generation queue</div>
        {tasks.length === 0 ? <p className="muted small">Nothing queued.</p> : tasks.map((t) => (
          <div key={t.id} className="stack-sm" style={{ padding: '6px 0' }}>
            <div className="row small"><span className="grow">{t.kind} · {t.modelRef.source}</span><span className="muted">{t.progressLabel}</span></div>
            <Progress value={t.progress} />
          </div>
        ))}
      </div>
    </div>
  );
}
