import { useState } from 'react';
import { CheckCircle2, KeyRound, Plus, RefreshCw, Trash2, XCircle, Zap } from 'lucide-react';
import type { ModelCategory, Provider, ProviderKind } from '@/types';
import { providerManager } from '@/services/provider-manager';
import { PROVIDER_KINDS, kindInfo } from '@/providers/types';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { Dialog, Field, Segmented, Spinner, Toggle, useAsync } from '@/components/ui';

const CATS: { value: ModelCategory; label: string }[] = [
  { value: 'chat', label: 'Chat AI' }, { value: 'image', label: 'Image' }, { value: 'threed', label: '3D' }, { value: 'video', label: 'Video' },
];
const CAP: Record<string, string> = { chat: 'Chat', reasoning: 'Reasoning', vision: 'Vision', tool_calling: 'Tool calling', image_generation: 'Image generation', image_editing: 'Image editing', threed_generation: '3D generation', video_generation: 'Video generation' };

function ProviderCard({ p, onChange }: { p: Provider; onChange: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [edit, setEdit] = useState(false);
  const { data: models } = useAsync(() => providerManager.models(p.id), [p.id, p.status, p.lastTestedAt]);
  const act = async (label: string, fn: () => Promise<unknown>) => {
    setBusy(label);
    try { await fn(); } catch (e) { uiBridge.toast('error', toZinoError(e).message); } finally { setBusy(null); onChange(); }
  };
  return (
    <div className="card stack-sm">
      <div className="row wrap">
        <strong className="grow">{p.name}</strong>
        {p.status === 'ok' && <span className="badge success"><CheckCircle2 size={12} /> Connected</span>}
        {p.status === 'error' && <span className="badge danger"><XCircle size={12} /> Error</span>}
        {p.status === 'untested' && <span className="badge warning">Not tested</span>}
      </div>
      <div className="tiny muted">{kindInfo(p.kind).label} · <span className="mono">{p.baseUrl}</span> · key {p.keyMasked ?? 'none'}{p.lastTestedAt ? ` · tested ${new Date(p.lastTestedAt).toLocaleString()}` : ''}</div>
      {p.lastError && <div className="tiny" style={{ color: 'var(--danger)' }}>{p.lastError}</div>}
      {p.capabilities.length > 0 && <div className="row wrap" style={{ gap: 4 }}>{p.capabilities.map((c) => <span key={c} className="badge">{CAP[c] ?? c}</span>)}</div>}
      {models && models.length > 0 && (
        <Field label={`Default model (${models.length} available)`}>
          <select className="select" value={p.defaultModel ?? ''} onChange={(e) => act('default', () => providerManager.update(p.id, { defaultModel: e.target.value }))}>
            {models.map((m) => <option key={m.id} value={m.modelId}>{m.displayName}{m.contextLength ? ` · ${m.contextLength.toLocaleString()} ctx` : ''}</option>)}
          </select>
        </Field>
      )}
      {models && models.some((m) => m.metadata.capabilitiesInferred || m.metadata.static) && <div className="hint">Some capabilities are inferred from model names or are a built-in list because the provider does not report them.</div>}
      <div className="row wrap">
        <button className="btn sm" disabled={!!busy} onClick={() => act('test', async () => { const r = await providerManager.test(p.id); uiBridge.toast(r.ok ? 'success' : 'error', r.message); })}>{busy === 'test' ? <Spinner /> : <Zap size={14} />} Test connection</button>
        <button className="btn sm" disabled={!!busy} onClick={() => act('refresh', async () => { const m = await providerManager.refreshModels(p.id); uiBridge.toast('success', `${m.length} models`); })}>{busy === 'refresh' ? <Spinner /> : <RefreshCw size={14} />} Refresh models</button>
        <button className="btn sm" onClick={() => setEdit(true)}><KeyRound size={14} /> Edit</button>
        <span className="grow" />
        <button className="btn sm danger" onClick={async () => {
          const ok = await uiBridge.confirm({ title: `Remove ${p.name}?`, message: 'Its API key is deleted from the Keychain unless another provider shares it.', confirmLabel: 'Remove', destructive: true });
          if (ok) await act('remove', () => providerManager.remove(p.id));
        }}><Trash2 size={14} /> Remove</button>
      </div>
      {edit && <EditProvider p={p} onClose={() => { setEdit(false); onChange(); }} />}
    </div>
  );
}

function EditProvider({ p, onClose }: { p: Provider; onClose: () => void }) {
  const [name, setName] = useState(p.name);
  const [url, setUrl] = useState(p.baseUrl);
  const [key, setKey] = useState('');
  const [opts, setOpts] = useState(p.options);
  const save = async () => {
    try {
      await providerManager.update(p.id, { name, baseUrl: url, options: opts });
      if (key.trim()) await providerManager.setKey(p.id, key);
      uiBridge.toast('success', 'Saved. Test the connection to confirm.');
      onClose();
    } catch (e) { uiBridge.toast('error', toZinoError(e).message); }
  };
  return (
    <Dialog title={`Edit ${p.name}`} onClose={onClose} actions={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={save}>Save</button></>}>
      <div className="stack">
        <Field label="Name"><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Base URL"><input className="input mono" value={url} onChange={(e) => setUrl(e.target.value)} autoCapitalize="off" autoCorrect="off" /></Field>
        <Field label="Replace API key" hint={`Current key: ${p.keyMasked ?? 'none'}. Stored in the iOS Keychain; never shown again.`}>
          <input className="input mono" type="password" value={key} onChange={(e) => setKey(e.target.value)} placeholder="Leave empty to keep the current key" autoComplete="off" />
        </Field>
        {p.kind === 'openai_compatible' && <CompatibleOptions opts={opts} setOpts={setOpts} />}
      </div>
    </Dialog>
  );
}

function CompatibleOptions({ opts, setOpts }: { opts: Provider['options']; setOpts: (o: Provider['options']) => void }) {
  return (
    <div className="stack-sm">
      <div className="row"><span className="grow small">Endpoint supports tool calling</span><Toggle on={!!opts.supportsTools} onChange={(v) => setOpts({ ...opts, supportsTools: v })} /></div>
      <div className="row"><span className="grow small">Endpoint supports reasoning_effort</span><Toggle on={!!opts.supportsReasoningEffort} onChange={(v) => setOpts({ ...opts, supportsReasoningEffort: v })} /></div>
      <Field label="Context length (if the server does not report it)"><input className="input" type="number" value={opts.contextLength ?? ''} placeholder="e.g. 32768" onChange={(e) => setOpts({ ...opts, contextLength: e.target.value ? +e.target.value : undefined })} /></Field>
    </div>
  );
}

function AddProvider({ category, existing, onClose }: { category: ModelCategory; existing: Provider[]; onClose: () => void }) {
  const kinds = PROVIDER_KINDS.filter((k) => k.categories.includes(category));
  const [kind, setKind] = useState<ProviderKind>(kinds[0].kind);
  const info = kindInfo(kind);
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [key, setKey] = useState('');
  const [reuse, setReuse] = useState('');
  const [opts, setOpts] = useState<Provider['options']>({});
  const [busy, setBusy] = useState(false);
  const sameKind = existing.filter((p) => p.kind === kind && p.keyMasked);
  const add = async () => {
    setBusy(true);
    try {
      const p = await providerManager.add({ category, kind, name, baseUrl: url || undefined, apiKey: reuse ? undefined : key, reuseKeyFromProviderId: reuse || undefined, options: opts });
      const r = await providerManager.test(p.id);
      uiBridge.toast(r.ok ? 'success' : 'error', r.ok ? `${p.name}: ${r.message}` : `Saved, but the connection test failed: ${r.message}`);
      onClose();
    } catch (e) { uiBridge.toast('error', toZinoError(e).message); } finally { setBusy(false); }
  };
  return (
    <Dialog title="Add provider" onClose={onClose} actions={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy} onClick={add}>{busy ? <Spinner /> : null} Add and test</button></>}>
      <div className="stack">
        <Field label="Provider"><select className="select" value={kind} onChange={(e) => { setKind(e.target.value as ProviderKind); setReuse(''); }}>{kinds.map((k) => <option key={k.kind} value={k.kind}>{k.label}</option>)}</select></Field>
        <div className="hint">{info.keyHelp} {info.notes}</div>
        <Field label="Display name"><input className="input" value={name} placeholder={info.label} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Base URL" hint={kind === 'openai_compatible' ? 'Must include the API version path, e.g. https://openrouter.ai/api/v1 or http://192.168.1.20:11434/v1' : 'Leave as default unless you use a proxy.'}>
          <input className="input mono" value={url} placeholder={info.defaultBaseUrl} onChange={(e) => setUrl(e.target.value)} autoCapitalize="off" autoCorrect="off" />
        </Field>
        {sameKind.length > 0 && (
          <Field label="API key source"><select className="select" value={reuse} onChange={(e) => setReuse(e.target.value)}>
            <option value="">Enter a new key</option>{sameKind.map((p) => <option key={p.id} value={p.id}>Reuse key from {p.name} ({p.category}, {p.keyMasked})</option>)}
          </select></Field>
        )}
        {!reuse && (
          <Field label={`API key${info.keyRequired ? '' : ' (optional)'}`} hint="Stored only in the iOS Keychain on this iPad. It is never written to the database, logs, chats or exports.">
            <input className="input mono" type="password" value={key} onChange={(e) => setKey(e.target.value)} autoComplete="off" autoCapitalize="off" />
          </Field>
        )}
        {kind === 'openai_compatible' && <CompatibleOptions opts={opts} setOpts={setOpts} />}
      </div>
    </Dialog>
  );
}

export function ProvidersSettings() {
  const [category, setCategory] = useState<ModelCategory>('chat');
  const [tick, setTick] = useState(0);
  const [adding, setAdding] = useState(false);
  const { data: providers } = useAsync(() => providerManager.list(category), [category, tick]);
  const { data: all } = useAsync(() => providerManager.list(), [tick]);
  return (
    <div className="stack">
      <div className="row wrap">
        <Segmented value={category} onChange={setCategory} options={CATS} />
        <span className="grow" />
        <button className="btn primary" onClick={() => setAdding(true)}><Plus size={16} /> Add provider</button>
      </div>
      <p className="small muted">
        {category === 'chat' && 'The primary intelligence for the Agent: conversation, reasoning, tool calling. Google Gemini, OpenAI, Anthropic Claude and any OpenAI-compatible endpoint.'}
        {category === 'image' && 'Dedicated image generation: OpenAI Images, Gemini/Imagen, Stability AI, or OpenAI-compatible /images endpoints.'}
        {category === 'threed' && 'Text-to-3D and image-to-3D: Meshy, Tripo, Stability (Stable Fast 3D). Results are GLB files saved to Assets.'}
        {category === 'video' && 'Text-to-video and image-to-video: OpenAI (Sora), Google (Veo), Runway.'}
      </p>
      {providers?.length === 0 && <div className="notice small">No providers in this category yet.</div>}
      {providers?.map((p) => <ProviderCard key={p.id} p={p} onChange={() => setTick((t) => t + 1)} />)}
      <div className="notice small">Requests are sent directly from this iPad to the provider using your own key, injected natively from the Keychain. ZinoAgent has no server and adds no telemetry. Adapters follow each provider's published API; until you test with your key, a provider is shown as "Not tested".</div>
      {adding && <AddProvider category={category} existing={all ?? []} onClose={() => { setAdding(false); setTick((t) => t + 1); }} />}
    </div>
  );
}
