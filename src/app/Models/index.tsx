import type { ReactNode } from 'react';
import { useState } from 'react';
import { Box, Clapperboard, Cpu, Download, FileUp, Gauge, Image, MessageSquare, Pause, Play, Search, Settings2, Trash2, X } from 'lucide-react';
import type { LocalModel, ModelCategory } from '@/types';
import { modelsRepo } from '@/database/repositories';
import { MODEL_CATALOG, type CatalogEntry } from '@/models/catalog';
import { benchmarkChatModel, deleteModel, ensureChatModel, ensureImageModel, importModels, updateModelSettings } from '@/services/model-manager';
import { cancelDownload, listHFFiles, pauseDownload, removeDownloadRecord, resumeDownload, startCatalogDownload, startDownload, useDownloads, type HFFile } from '@/services/download-manager';
import { formatBytes, loadedModel, unloadModel, useResources } from '@/services/resources';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { ResourceDashboard } from '@/components/RamMonitor';
import { CompatBadge, Dialog, Empty, Field, Progress, Spinner, useAsync } from '@/components/ui';

type Tab = ModelCategory | 'downloads' | 'resources';
const TABS: { id: Tab; label: string; icon: ReactNode }[] = [
  { id: 'chat', label: 'Chat (GGUF)', icon: <MessageSquare size={16} /> },
  { id: 'image', label: 'Image', icon: <Image size={16} /> },
  { id: 'threed', label: '3D', icon: <Box size={16} /> },
  { id: 'video', label: 'Video', icon: <Clapperboard size={16} /> },
  { id: 'downloads', label: 'Downloads', icon: <Download size={16} /> },
  { id: 'resources', label: 'RAM & resources', icon: <Cpu size={16} /> },
];

const INTRO: Record<ModelCategory, string> = {
  chat: 'GGUF models run fully offline through llama.cpp with Metal acceleration. Compatibility is checked against this llama.cpp build and the memory iPadOS currently allows.',
  image: 'Compiled Core ML Stable Diffusion models (Apple ml-stable-diffusion format). Import a folder or .zip containing TextEncoder/Unet/VAEDecoder .mlmodelc files.',
  threed: 'No iPadOS-compatible on-device 3D generation runtime is integrated yet. You can import Core ML packages to inspect them; they are reported honestly as unsupported unless an adapter matches. Use a cloud 3D provider to generate.',
  video: 'On-device video diffusion needs far more memory than an 8 GB iPad gives an app, and no on-device runtime is integrated. Imported Core ML packages are inspected only. Use a cloud video provider to generate.',
};

async function run(fn: () => Promise<unknown>, ok?: string) {
  try { await fn(); if (ok) uiBridge.toast('success', ok); } catch (e) { const err = toZinoError(e); if (err.code !== 'CANCELLED') uiBridge.toast('error', err.message); }
}

function ModelCard({ m, onChange }: { m: LocalModel; onChange: () => void }) {
  const loaded = useResources((s) => s.loaded.find((x) => x.modelId === m.id));
  const loading = useResources((s) => s.loading);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const bench = m.benchmark;
  const canLoad = (m.category === 'chat' || m.category === 'image') && m.compatibility !== 'unsupported';
  const act = async (fn: () => Promise<unknown>, ok?: string) => { setBusy(true); await run(fn, ok); setBusy(false); onChange(); };
  return (
    <div className="card stack-sm">
      <div className="card-row">
        <div className="grow stack-sm" style={{ gap: 4 }}>
          <div className="row wrap"><strong>{m.name}</strong><CompatBadge value={m.compatibility} />{loaded && <span className="badge success">Loaded</span>}</div>
          <div className="tiny muted">
            {[m.architecture, m.quantization, m.parameters ? `${(m.parameters / 1e9).toFixed(1)}B params` : (m.metadata.sizeLabel as string | undefined),
              formatBytes(m.sizeBytes), m.contextLength ? `trained ctx ${m.contextLength.toLocaleString()}` : null,
              m.metadata.estimatedBytes ? `~${formatBytes(m.metadata.estimatedBytes as number)} RAM at ${m.settings.contextLength ?? 4096} ctx` : null].filter(Boolean).join(' · ')}
          </div>
          {(m.license || m.attribution) && <div className="tiny faint">{[m.license && `Licence: ${m.license}`, m.attribution].filter(Boolean).join(' · ')}</div>}
          {m.sha256 && <div className="tiny faint mono truncate">SHA-256 {m.sha256}</div>}
          {m.compatibilityNotes.map((n, i) => <div key={i} className="tiny" style={{ color: m.compatibility === 'unsupported' ? 'var(--danger)' : 'var(--text-2)' }}>• {n}</div>)}
          {bench && (bench.generationTokensPerSecond || bench.loadMs) && (
            <div className="tiny" style={{ color: 'var(--success)' }}>
              Measured on {bench.device ?? 'this device'}: {bench.loadMs ? `load ${(bench.loadMs / 1000).toFixed(1)}s` : ''}
              {bench.promptTokensPerSecond ? ` · prompt ${bench.promptTokensPerSecond.toFixed(0)} tok/s` : ''}{bench.generationTokensPerSecond ? ` · generation ${bench.generationTokensPerSecond.toFixed(1)} tok/s` : ''}
              {bench.appFootprintBytes ? ` · app memory ${formatBytes(bench.appFootprintBytes)}` : ''} ({new Date(bench.measuredAt).toLocaleDateString()})
            </div>
          )}
        </div>
      </div>
      <div className="row wrap">
        {canLoad && (loaded
          ? <button className="btn sm" disabled={busy} onClick={() => act(() => unloadModel(m.category === 'chat' ? 'llama' : 'diffusion'), 'Unloaded')}>Unload</button>
          : <button className="btn sm" disabled={busy || !!loading} onClick={() => act(() => (m.category === 'chat' ? ensureChatModel(m.id) : ensureImageModel(m.id)), 'Loaded')}>{busy ? <Spinner /> : <Play size={14} />} Load</button>)}
        {m.category === 'chat' && m.compatibility !== 'unsupported' && <button className="btn sm" disabled={busy} onClick={() => act(() => benchmarkChatModel(m.id), 'Benchmark complete')}><Gauge size={14} /> Benchmark</button>}
        {(m.category === 'chat' || m.category === 'image') && <button className="btn sm" onClick={() => setSettingsOpen(true)}><Settings2 size={14} /> Settings</button>}
        <span className="grow" />
        <button className="btn sm danger" disabled={busy} onClick={async () => {
          const ok = await uiBridge.confirm({ title: `Delete ${m.name}?`, message: `This removes ${formatBytes(m.sizeBytes)} from this iPad. Conversations and generated assets are kept.`, confirmLabel: 'Delete model', destructive: true });
          if (ok) await act(() => deleteModel(m.id), 'Model deleted');
        }}><Trash2 size={14} /> Delete</button>
      </div>
      {settingsOpen && <ModelSettings m={m} onClose={() => { setSettingsOpen(false); onChange(); }} />}
    </div>
  );
}

function ModelSettings({ m, onClose }: { m: LocalModel; onClose: () => void }) {
  const [ctx, setCtx] = useState(m.settings.contextLength ?? 4096);
  const [gpu, setGpu] = useState(m.settings.gpuLayers ?? 999);
  const [threads, setThreads] = useState(m.settings.threads ?? 4);
  const [units, setUnits] = useState(m.settings.computeUnits ?? 'cpuAndNeuralEngine');
  const max = m.contextLength ?? 32768;
  const save = async () => {
    await run(() => updateModelSettings(m.id, m.category === 'chat' ? { contextLength: ctx, gpuLayers: gpu, threads } : { computeUnits: units }), 'Saved. Changes apply the next time the model loads.');
    if (loadedModel(m.category === 'chat' ? 'llama' : 'diffusion')?.modelId === m.id) uiBridge.toast('info', 'Unload and load the model again to apply.');
    onClose();
  };
  return (
    <Dialog title={`${m.name} settings`} onClose={onClose} actions={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={save}>Save</button></>}>
      {m.category === 'chat' ? (
        <div className="stack">
          <Field label={`Context length: ${ctx.toLocaleString()} tokens`} hint={`Trained maximum ${max.toLocaleString()}. Larger contexts use more RAM (KV cache). SmartContextEngine compacts automatically near the limit.`}>
            <input type="range" min={1024} max={Math.min(max, 131072)} step={512} value={ctx} onChange={(e) => setCtx(+e.target.value)} />
          </Field>
          <Field label="GPU (Metal) layers" hint="999 offloads all layers to the GPU (recommended on M2). 0 = CPU only."><input className="input" type="number" value={gpu} onChange={(e) => setGpu(+e.target.value)} /></Field>
          <Field label="CPU threads"><input className="input" type="number" min={1} max={8} value={threads} onChange={(e) => setThreads(+e.target.value)} /></Field>
        </div>
      ) : (
        <Field label="Compute units" hint="Neural Engine is usually fastest and most memory-efficient for split-einsum models.">
          <select className="select" value={units} onChange={(e) => setUnits(e.target.value as typeof units)}>
            <option value="cpuAndNeuralEngine">CPU + Neural Engine</option><option value="cpuAndGPU">CPU + GPU</option><option value="all">All</option><option value="cpuOnly">CPU only</option>
          </select>
        </Field>
      )}
    </Dialog>
  );
}

function HFBrowser({ category, onClose }: { category: 'chat' | 'image'; onClose: () => void }) {
  const [repo, setRepo] = useState('');
  const [files, setFiles] = useState<HFFile[] | null>(null);
  const [loading, setLoading] = useState(false);
  const browse = async () => {
    setLoading(true); setFiles(null);
    try { setFiles((await listHFFiles(repo.trim())).filter((f) => (category === 'chat' ? /\.gguf$/i.test(f.path) : /\.zip$/i.test(f.path)))); }
    catch (e) { uiBridge.toast('error', toZinoError(e).message); } finally { setLoading(false); }
  };
  return (
    <Dialog wide title="Download from Hugging Face" onClose={onClose}>
      <div className="stack">
        <div className="row"><input className="input" placeholder="owner/repository" value={repo} onChange={(e) => setRepo(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && browse()} />
          <button className="btn primary" onClick={browse} disabled={!repo.includes('/')}><Search size={16} /> Browse</button></div>
        <p className="hint">ZinoAgent reads file sizes and SHA-256 checksums from Hugging Face and verifies the download. Check each model's licence before use. {category === 'chat' ? 'Showing .gguf files.' : 'Showing .zip archives (compiled Core ML Stable Diffusion).'}</p>
        {loading && <Spinner />}
        {files && files.length === 0 && <p className="muted small">No matching files in this repository.</p>}
        {files && files.length > 0 && (
          <table className="table"><thead><tr><th>File</th><th>Size</th><th /></tr></thead><tbody>
            {files.map((f) => (
              <tr key={f.path}><td className="small mono" style={{ wordBreak: 'break-all' }}>{f.path}{!f.sha256 && <div className="tiny" style={{ color: 'var(--warning)' }}>No checksum published</div>}</td><td className="small">{formatBytes(f.size)}</td>
                <td><button className="btn sm" onClick={() => run(async () => { await startDownload({ category, name: f.path.split('/').pop()!, repo: repo.trim(), file: f, format: category === 'chat' ? 'gguf' : 'coreml-diffusion-zip' }); onClose(); }, 'Download started')}>Download</button></td></tr>
            ))}
          </tbody></table>
        )}
      </div>
    </Dialog>
  );
}

function Downloads() {
  const items = useDownloads((s) => s.items);
  const speed = useDownloads((s) => s.speed);
  if (!items.length) return <Empty icon={<Download size={36} />} title="No downloads">Start one from the Chat or Image tab.</Empty>;
  return (
    <div className="stack">
      {items.map((d) => {
        const pct = d.totalBytes ? d.receivedBytes / d.totalBytes : 0;
        return (
          <div key={d.id} className="card stack-sm">
            <div className="row"><strong className="grow truncate">{d.name}</strong>
              <span className={`badge ${d.status === 'completed' ? 'success' : d.status === 'failed' ? 'danger' : d.status === 'paused' ? 'warning' : ''}`}>{d.status}</span></div>
            {(d.status === 'downloading' || d.status === 'paused' || d.status === 'verifying') && <Progress value={pct} />}
            <div className="tiny muted">{formatBytes(d.receivedBytes)} / {formatBytes(d.totalBytes)}{d.status === 'downloading' && speed[d.id] ? ` · ${formatBytes(speed[d.id])}/s` : ''}
              {d.status === 'verifying' ? ' · verifying SHA-256…' : ''}{d.sha256Expected ? ' · checksum will be verified' : ' · size check only'}</div>
            {d.error && <div className="tiny" style={{ color: 'var(--danger)' }}>{d.error}</div>}
            <div className="row">
              {d.status === 'downloading' && <button className="btn sm" onClick={() => run(() => pauseDownload(d.id))}><Pause size={14} /> Pause</button>}
              {(d.status === 'paused' || d.status === 'failed') && <button className="btn sm" onClick={() => run(() => resumeDownload(d.id))}><Play size={14} /> {d.status === 'failed' ? 'Retry' : 'Resume'}</button>}
              {(d.status === 'downloading' || d.status === 'paused') && <button className="btn sm danger" onClick={() => run(() => cancelDownload(d.id))}><X size={14} /> Cancel</button>}
              {(d.status === 'completed' || d.status === 'failed' || d.status === 'cancelled') && <button className="btn sm ghost" onClick={() => run(() => removeDownloadRecord(d.id))}>Remove from list</button>}
            </div>
          </div>
        );
      })}
    </div>
  );
}

export function ModelsView() {
  const [tab, setTab] = useState<Tab>('chat');
  const [tick, setTick] = useState(0);
  const [hf, setHf] = useState<'chat' | 'image' | null>(null);
  const category = (['chat', 'image', 'threed', 'video'] as Tab[]).includes(tab) ? (tab as ModelCategory) : null;
  const { data: models, loading } = useAsync(() => (category ? modelsRepo.list(category) : Promise.resolve([])), [category, tick]);
  const catalog = MODEL_CATALOG.filter((c) => c.category === category);
  const refresh = () => setTick((t) => t + 1);

  const doImport = () => run(async () => {
    const r = await importModels(category!);
    refresh();
    if (r.imported.length) uiBridge.toast('success', `Imported ${r.imported.map((m) => m.name).join(', ')}`);
    r.errors.forEach((e) => uiBridge.toast('error', e));
  });

  return (
    <div className="page">
      <div className="page-header"><div><h1>Models</h1><div className="subtitle">Offline model libraries, downloads and device resources</div></div></div>
      <div className="tabs">{TABS.map((t) => <button key={t.id} className={tab === t.id ? 'active' : ''} onClick={() => setTab(t.id)}><span className="row" style={{ gap: 6 }}>{t.icon}{t.label}</span></button>)}</div>
      {tab === 'downloads' && <Downloads />}
      {tab === 'resources' && <ResourceDashboard />}
      {category && (
        <div className="stack">
          <div className={`notice ${category === 'threed' || category === 'video' ? 'warning' : ''} small`}>{INTRO[category]}</div>
          <div className="row wrap">
            <button className="btn primary" onClick={doImport}><FileUp size={16} /> Import from Files</button>
            {(category === 'chat' || category === 'image') && <button className="btn" onClick={() => setHf(category)}><Search size={16} /> Hugging Face repository…</button>}
          </div>
          <div className="section-title">Installed</div>
          {loading ? <Spinner /> : models && models.length ? models.map((m) => <ModelCard key={m.id} m={m} onChange={refresh} />)
            : <p className="muted small">No {category === 'threed' ? '3D' : category} models installed.</p>}
          {catalog.length > 0 && (
            <>
              <div className="section-title">Suggested downloads</div>
              <div className="grid-2">
                {catalog.map((c: CatalogEntry) => (
                  <div key={c.id} className="card stack-sm">
                    <strong>{c.name}</strong>
                    <div className="tiny muted">~{c.approxSizeGB} GB · {c.license} · {c.attribution}</div>
                    <div className="small">{c.notes}</div>
                    <div className="tiny faint mono">{c.repo}</div>
                    <div><button className="btn sm" onClick={() => run(() => startCatalogDownload(c), 'Download started — see the Downloads tab')}><Download size={14} /> Download</button></div>
                  </div>
                ))}
              </div>
              <p className="hint">Sizes are approximate until the download starts; exact sizes and checksums come from Hugging Face.</p>
            </>
          )}
        </div>
      )}
      {hf && <HFBrowser category={hf} onClose={() => setHf(null)} />}
    </div>
  );
}
