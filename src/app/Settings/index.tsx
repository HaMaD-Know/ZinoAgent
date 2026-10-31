import { useEffect, useState } from 'react';
import { Pin, Trash2 } from 'lucide-react';
import type { EffortLevel, MemoryRecord, Studio } from '@/types';
import { EFFORT_LEVELS } from '@/types';
import { useApp } from '@/app/store';
import { contextRepo, uid } from '@/database/repositories';
import { ZinoKeychain, ZinoStorage } from '@/native';
import { HF_TOKEN_ACCOUNT } from '@/services/download-manager';
import { DEFAULT_SYSTEM_PROMPT } from '@/services/settings';
import { formatBytes } from '@/services/resources';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { ResourceDashboard } from '@/components/RamMonitor';
import { EFFORT_LABEL } from '@/components/EffortSelector';
import { Field, Segmented, Toggle, useAsync } from '@/components/ui';
import { ProvidersSettings } from './Providers';
import { FeatureStatus } from './Status';

const TABS = [
  ['providers', 'AI providers & keys'], ['effort', 'Effort'], ['context', 'Context engine'], ['memory', 'Memory'],
  ['resources', 'RAM & resources'], ['privacy', 'Privacy'], ['appearance', 'Appearance'], ['status', 'Feature status'],
] as const;
type Tab = (typeof TABS)[number][0];

function EffortSelect({ value, onChange, allowInherit }: { value: EffortLevel | undefined; onChange: (v: EffortLevel | undefined) => void; allowInherit?: boolean }) {
  return (
    <select className="select" value={value ?? ''} onChange={(e) => onChange((e.target.value || undefined) as EffortLevel | undefined)} style={{ maxWidth: 220 }}>
      {allowInherit && <option value="">Use default</option>}
      {EFFORT_LEVELS.map((l) => <option key={l} value={l}>{EFFORT_LABEL[l]}</option>)}
    </select>
  );
}

function MemorySettings() {
  const [tick, setTick] = useState(0);
  const { data } = useAsync(() => contextRepo.allMemory(), [tick]);
  const [text, setText] = useState('');
  const [kind, setKind] = useState<MemoryRecord['kind']>('instruction');
  const save = async (m: MemoryRecord) => { await contextRepo.upsertMemory(m); setTick((t) => t + 1); };
  return (
    <div className="stack">
      <p className="small muted">Long-term memory is extracted from verified summaries (instructions, decisions, preferences, project facts) and included in future context. Items without a chat apply to every chat.</p>
      <div className="row wrap">
        <select className="select" style={{ width: 150 }} value={kind} onChange={(e) => setKind(e.target.value as MemoryRecord['kind'])}>
          {['instruction', 'preference', 'decision', 'project', 'fact', 'task'].map((k) => <option key={k}>{k}</option>)}
        </select>
        <input className="input grow" placeholder="Add a global memory, e.g. 'Use metric units'" value={text} onChange={(e) => setText(e.target.value)} />
        <button className="btn primary" disabled={!text.trim()} onClick={async () => {
          await save({ id: uid(), chatId: null, kind, content: text.trim(), sourceMessageIds: [], pinned: true, active: true, createdAt: Date.now(), updatedAt: Date.now() });
          setText('');
        }}>Add</button>
      </div>
      {(data ?? []).map((m) => (
        <div key={m.id} className="card row">
          <span className="badge">{m.kind}</span>
          <div className="grow small selectable" style={{ opacity: m.active ? 1 : 0.5 }}>{m.content}<div className="tiny faint">{m.chatId ? 'This chat only' : 'All chats'} · {m.sourceMessageIds.length ? `from ${m.sourceMessageIds.length} messages` : 'added manually'}</div></div>
          <button className="icon-btn sm" title={m.pinned ? 'Unpin' : 'Pin'} onClick={() => save({ ...m, pinned: !m.pinned, updatedAt: Date.now() })}><Pin size={15} color={m.pinned ? 'var(--accent)' : undefined} /></button>
          <Toggle on={m.active} onChange={(v) => save({ ...m, active: v, updatedAt: Date.now() })} label="Active" />
          <button className="icon-btn sm" title="Delete" onClick={async () => { await contextRepo.deleteMemory(m.id); setTick((t) => t + 1); }}><Trash2 size={15} /></button>
        </div>
      ))}
      {data?.length === 0 && <p className="muted small">No memory records yet.</p>}
    </div>
  );
}

function PrivacySettings() {
  const settings = useApp((s) => s.settings);
  const update = useApp((s) => s.updateSettings);
  const [hf, setHf] = useState<{ exists: boolean; masked?: string } | null>(null);
  const [token, setToken] = useState('');
  useEffect(() => { void ZinoKeychain.has({ account: HF_TOKEN_ACCOUNT }).then(setHf).catch(() => setHf({ exists: false })); }, []);
  return (
    <div className="stack">
      <div className="card stack-sm">
        <div className="row"><strong className="grow">Let Auto use cloud models</strong>
          <Toggle on={settings.auto.allowCloud} onChange={async (v) => {
            if (v) {
              const ok = await uiBridge.confirm({ title: 'Allow Auto to use cloud models?', message: 'When enabled, Auto may send your messages to a configured cloud provider (which may charge you) when it judges a task too hard for offline models. You can still pick models manually at any time.', confirmLabel: 'Allow' });
              if (!ok) return;
            }
            await update((s) => ({ ...s, auto: { allowCloud: v } }));
          }} /></div>
        <p className="small muted">Off by default. When off, Auto stays offline and asks you before suggesting a cloud model for a chat.</p>
      </div>
      <div className="card stack-sm">
        <strong>Data handling</strong>
        <ul className="small muted" style={{ margin: 0, paddingLeft: 18 }}>
          <li>Conversations, summaries, assets and models are stored only on this iPad (app-private storage).</li>
          <li>API keys live in the iOS Keychain and are injected natively; JavaScript never reads them back.</li>
          <li>Cloud models never get file-system access. The first time a cloud model wants to see file names in a chat you are asked; file contents are asked for per file.</li>
          <li>Offline models never send data anywhere. ZinoAgent has no analytics or telemetry.</li>
        </ul>
      </div>
      <div className="card stack-sm">
        <strong>Hugging Face token (optional)</strong>
        <p className="small muted">Needed only for gated model repositories. Stored in the Keychain. {hf?.exists ? `Current: ${hf.masked}` : 'Not set.'}</p>
        <div className="row"><input className="input mono" type="password" value={token} onChange={(e) => setToken(e.target.value)} placeholder="hf_…" autoComplete="off" />
          <button className="btn" disabled={!token.trim()} onClick={async () => { try { await ZinoKeychain.set({ account: HF_TOKEN_ACCOUNT, secret: token.trim() }); setToken(''); setHf(await ZinoKeychain.has({ account: HF_TOKEN_ACCOUNT })); uiBridge.toast('success', 'Saved'); } catch (e) { uiBridge.toast('error', toZinoError(e).message); } }}>Save</button>
          {hf?.exists && <button className="btn danger" onClick={async () => { await ZinoKeychain.remove({ account: HF_TOKEN_ACCOUNT }); setHf({ exists: false }); }}>Remove</button>}</div>
      </div>
    </div>
  );
}

export function SettingsView() {
  const initial = useApp((s) => s.settingsTab);
  const [tab, setTab] = useState<Tab>((initial as Tab) ?? 'providers');
  const settings = useApp((s) => s.settings);
  const update = useApp((s) => s.updateSettings);
  useEffect(() => { if (initial) { setTab(initial as Tab); useApp.setState({ settingsTab: null }); } }, [initial]);
  const c = settings.context;
  const setCtx = (patch: Partial<typeof c>) => update((s) => ({ ...s, context: { ...s.context, ...patch } }));
  const r = settings.resources;
  const setRes = (patch: Partial<typeof r>) => update((s) => ({ ...s, resources: { ...s.resources, ...patch } }));

  return (
    <div className="page">
      <div className="page-header"><div><h1>Settings</h1><div className="subtitle">Providers, keys, effort, context, memory, resources and privacy</div></div></div>
      <div className="tabs">{TABS.map(([id, label]) => <button key={id} className={tab === id ? 'active' : ''} onClick={() => setTab(id)}>{label}</button>)}</div>
      <div style={{ maxWidth: 900 }}>
        {tab === 'providers' && <ProvidersSettings />}
        {tab === 'effort' && (
          <div className="stack">
            <p className="small muted">Effort maps to each model's real controls (reasoning effort, thinking budget/level, output budget, sampling, context retrieval depth, summary verification). Models that lack a control are reported as such — nothing is faked.</p>
            <div className="grid-2">
              <Field label="Offline default"><EffortSelect value={settings.effort.offlineDefault} onChange={(v) => update((s) => ({ ...s, effort: { ...s.effort, offlineDefault: v ?? 'medium' } }))} /></Field>
              <Field label="Online default"><EffortSelect value={settings.effort.onlineDefault} onChange={(v) => update((s) => ({ ...s, effort: { ...s.effort, onlineDefault: v ?? 'medium' } }))} /></Field>
            </div>
            <div className="section-title">Per studio</div>
            <div className="grid-2">
              {(['agent', 'image', 'threed', 'video'] as Studio[]).map((st) => (
                <Field key={st} label={st === 'agent' ? 'Agent' : st === 'image' ? 'Image Studio (quality)' : st === 'threed' ? '3D Studio' : 'Video Studio'}>
                  <EffortSelect allowInherit value={settings.effort.perStudio[st]} onChange={(v) => update((s) => ({ ...s, effort: { ...s.effort, perStudio: { ...s.effort.perStudio, [st]: v } } }))} />
                </Field>
              ))}
            </div>
            <div className="section-title">Per model overrides</div>
            {Object.keys(settings.effort.perModel).length === 0 && <p className="small muted">None. A chat's own effort choice is remembered with the chat.</p>}
            {Object.entries(settings.effort.perModel).map(([k, v]) => (
              <div key={k} className="row"><span className="grow mono tiny">{k}</span><EffortSelect value={v} onChange={(nv) => update((s) => { const pm = { ...s.effort.perModel }; if (nv) pm[k] = nv; else delete pm[k]; return { ...s, effort: { ...s.effort, perModel: pm } }; })} allowInherit /></div>
            ))}
            {settings.defaultModels.agent && settings.defaultModels.agent.source !== 'auto' && (
              <button className="btn sm" onClick={() => {
                const ref = settings.defaultModels.agent!;
                const key = ref.source === 'local' ? `local:${ref.modelId}` : ref.source === 'cloud' ? `cloud:${ref.providerId}:${ref.modelId}` : 'auto';
                void update((s) => ({ ...s, effort: { ...s.effort, perModel: { ...s.effort.perModel, [key]: 'high' } } }));
              }}>Add override for the default Agent model</button>
            )}
          </div>
        )}
        {tab === 'context' && (
          <div className="stack">
            <div className="notice small">SmartContextEngine keeps every original message in SQLite, summarises older batches when usage reaches the threshold, verifies each summary, and retrieves original batches when a question needs exact details. It does not increase a model's native context limit.</div>
            <Field label={`Compaction threshold: ${Math.round(c.compactionThreshold * 100)}% of usable context`} hint="Recommended 85–90%.">
              <input type="range" min={0.6} max={0.95} step={0.01} value={c.compactionThreshold} onChange={(e) => setCtx({ compactionThreshold: +e.target.value })} /></Field>
            <Field label={`Target after compaction: ${Math.round(c.compactionTarget * 100)}%`}><input type="range" min={0.2} max={0.75} step={0.05} value={c.compactionTarget} onChange={(e) => setCtx({ compactionTarget: +e.target.value })} /></Field>
            <Field label="Batch size" hint={`Adaptive, using ${c.batchReferenceSize} messages as a reference and adjusting for token count, importance and memory pressure.`}><span className="chip">Adaptive</span></Field>
            <Field label="History retrieval"><Segmented value={c.retrieval} onChange={(v) => setCtx({ retrieval: v })} options={[{ value: 'smart', label: 'Smart' }, { value: 'recent_only', label: 'Summaries + recent only' }]} /></Field>
            <div className="row"><div className="grow"><strong className="small">Preserve original messages</strong><div className="hint">Always on — originals are never deleted because they were summarised.</div></div><Toggle on disabled onChange={() => {}} /></div>
            <div className="row"><div className="grow"><strong className="small">Summary verification</strong><div className="hint">Checks names, numbers, files, decisions, instructions and open tasks; retries or keeps originals on failure.</div></div><Toggle on={c.summaryVerification} onChange={(v) => setCtx({ summaryVerification: v })} /></div>
            <Field label="Model-based cross-check of summaries"><Segmented value={c.llmVerification} onChange={(v) => setCtx({ llmVerification: v })} options={[{ value: 'auto', label: 'At High/Maximum effort' }, { value: 'always', label: 'Always' }, { value: 'never', label: 'Never' }]} /></Field>
            <Field label={`Always keep the last ${c.minRecentMessages} messages verbatim`}><input type="range" min={2} max={12} value={c.minRecentMessages} onChange={(e) => setCtx({ minRecentMessages: +e.target.value })} /></Field>
            <Field label={`Cloud prompt cap: ${settings.contextCloudCap.toLocaleString()} tokens`} hint="Limits how much history is sent to paid APIs even if the model accepts more.">
              <input type="range" min={8000} max={1000000} step={8000} value={settings.contextCloudCap} onChange={(e) => update((s) => ({ ...s, contextCloudCap: +e.target.value }))} /></Field>
            <Field label="Default system prompt"><textarea className="textarea" value={settings.agent.systemPrompt} onChange={(e) => update((s) => ({ ...s, agent: { ...s.agent, systemPrompt: e.target.value } }))} /></Field>
            <div className="row"><button className="btn sm" onClick={() => update((s) => ({ ...s, agent: { ...s.agent, systemPrompt: DEFAULT_SYSTEM_PROMPT } }))}>Reset system prompt</button>
              <span className="grow" /><span className="small">Auto-title chats</span><Toggle on={settings.agent.autoTitle} onChange={(v) => update((s) => ({ ...s, agent: { ...s.agent, autoTitle: v } }))} /></div>
            <div className="row"><span className="grow small">AI file tools (when a folder is authorised)</span><Toggle on={settings.agent.fileToolsEnabled} onChange={(v) => update((s) => ({ ...s, agent: { ...s.agent, fileToolsEnabled: v } }))} /></div>
          </div>
        )}
        {tab === 'memory' && <MemorySettings />}
        {tab === 'resources' && (
          <div className="stack">
            <div className="card stack">
              <div className="row"><div className="grow"><strong className="small">One heavy model at a time</strong><div className="hint">Unloads the chat model before loading an image model and vice versa (recommended on 8 GB).</div></div><Toggle on={r.singleHeavyModel} onChange={(v) => setRes({ singleHeavyModel: v })} /></div>
              <Field label={`Unload idle models after ${r.idleUnloadMinutes} min`}><input type="range" min={0} max={60} step={5} value={r.idleUnloadMinutes} onChange={(e) => setRes({ idleUnloadMinutes: +e.target.value })} /></Field>
              <Field label="Pause queued heavy tasks when the iPad is"><Segmented value={r.pauseHeavyTasksAt} onChange={(v) => setRes({ pauseHeavyTasksAt: v })} options={[{ value: 'serious', label: 'Hot (serious)' }, { value: 'critical', label: 'Critical only' }, { value: 'never', label: 'Never' }]} /></Field>
              <div className="row"><div className="grow"><strong className="small">Warn before loading a model that may exceed memory</strong></div><Toggle on={r.warnBeforeHighMemory} onChange={(v) => setRes({ warnBeforeHighMemory: v })} /></div>
              <div><button className="btn sm" onClick={async () => { try { const { freed } = await ZinoStorage.clearTemp(); uiBridge.toast('success', `Cleared ${formatBytes(freed)} of temporary files. Models, assets and chats were not touched.`); } catch (e) { uiBridge.toast('error', toZinoError(e).message); } }}>Clear temporary caches</button></div>
            </div>
            <ResourceDashboard />
          </div>
        )}
        {tab === 'privacy' && <PrivacySettings />}
        {tab === 'appearance' && (
          <Field label="Theme"><Segmented value={settings.theme} onChange={(v) => update((s) => ({ ...s, theme: v }))} options={[{ value: 'system', label: 'System' }, { value: 'light', label: 'Light' }, { value: 'dark', label: 'Dark' }]} /></Field>
        )}
        {tab === 'status' && <FeatureStatus />}
      </div>
    </div>
  );
}
