import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowUp, FolderOpen, ImagePlus, Layers, MessageSquare, PanelRight, Square, X, Bot, PanelLeft } from 'lucide-react';
import type { Asset, Chat, ChatMessage, EffortLevel, MessageAttachment, ModelRef } from '@/types';
import { chatsRepo, messagesRepo, assetsRepo } from '@/database/repositories';
import { ZinoFiles, type FolderRoot } from '@/native';
import { runAgentTurn, previewContext, autoSelect, type EffortPlan } from '@/services/ai-router';
import type { ContextReport } from '@/services/context-engine';
import { ZinoError, toZinoError, type RecoveryAction } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { loadedModel, unloadModel } from '@/services/resources';
import { generateImage, useTasks } from '@/services/generation';
import { useApp } from '@/app/store';
import { ModelSelector, refKey } from '@/components/ModelSelector';
import { EffortSelector } from '@/components/EffortSelector';
import { ContextMonitor, ContextBreakdown } from '@/components/ContextMonitor';
import { FileExplorer } from '@/components/FileExplorer';
import { AssetPicker } from '@/components/AssetPicker';
import { AssetMedia } from '@/components/AssetMedia';
import { ChatHistory } from '@/app/ChatHistory';
import { MessageView } from './MessageView';

export function AgentView() {
  const settings = useApp((s) => s.settings);
  const online = useApp((s) => s.online);
  const pendingChatId = useApp((s) => s.pendingChatId);
  const setSection = useApp((s) => s.setSection);
  const openSettings = useApp((s) => s.openSettings);
  const setStudioModel = useApp((s) => s.setStudioModel);

  const [chat, setChat] = useState<Chat | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [draft, setDraft] = useState('');
  const [attachments, setAttachments] = useState<Asset[]>([]);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [report, setReport] = useState<ContextReport | null>(null);
  const [plan, setPlan] = useState<EffortPlan | null>(null);
  const [panel, setPanel] = useState<'files' | 'context' | null>(null);
  const [roots, setRoots] = useState<FolderRoot[]>([]);
  const [picker, setPicker] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);
  const abort = useRef<AbortController | null>(null);
  const scroller = useRef<HTMLDivElement>(null);

  const modelRef: ModelRef = chat?.modelRef ?? settings.studioModels.agent ?? settings.defaultModels.agent ?? { source: 'auto' };
  const effort: EffortLevel = chat?.effort ?? (modelRef.source === 'cloud' ? settings.effort.onlineDefault : settings.effort.offlineDefault);
  const rootId = chat?.settings.fileToolsRootId ?? null;
  const root = roots.find((r) => r.id === rootId) ?? null;

  const openChat = useCallback(async (id: string) => {
    if (busy) {
      const ok = await uiBridge.confirm({ title: 'A reply is still running', message: 'Switching chats will stop it.', confirmLabel: 'Stop and switch' });
      if (!ok) return;
      abort.current?.abort();
    }
    const c = await chatsRepo.get(id);
    if (!c) return;
    setChat(c);
    setMessages(await messagesRepo.list(id));
    setAttachments([]);
    setHistoryOpen(false);
  }, [busy]);

  useEffect(() => { void ZinoFiles.listRoots().then((r) => setRoots(r.roots)).catch(() => {}); }, [panel]);
  useEffect(() => { if (pendingChatId) { void openChat(pendingChatId); useApp.setState({ pendingChatId: null }); } }, [pendingChatId, openChat]);
  useEffect(() => {
    // Open the most recent chat on first load.
    if (!chat && !pendingChatId) void chatsRepo.list().then((cs) => { if (cs[0]) void openChat(cs[0].id); });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => { scroller.current?.scrollTo({ top: scroller.current.scrollHeight }); }, [messages.length]);
  useEffect(() => {
    if (!chat || busy) return;
    void previewContext(chat.id, modelRef, effort).then((r) => { if (r) { setReport(r.report); setPlan(r.plan); } else { setReport(null); setPlan(null); } }).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat?.id, refKey(modelRef), effort, messages.length]);

  const ensureChat = async (): Promise<Chat> => {
    if (chat) return chat;
    const c = await chatsRepo.create({ modelRef: settings.studioModels.agent ?? settings.defaultModels.agent ?? null });
    setChat(c); setMessages([]); setRefreshKey((k) => k + 1);
    return c;
  };
  const updateChat = async (patch: Partial<Chat>) => {
    const c = await ensureChat();
    await chatsRepo.update(c.id, { ...patch, updatedAt: c.updatedAt });
    setChat({ ...c, ...patch });
  };

  const changeModel = async (ref: ModelRef) => {
    if (busy) {
      const ok = await uiBridge.confirm({ title: 'Switch model?', message: 'A reply is being generated. Switching will stop it. Your conversation is kept.', confirmLabel: 'Stop and switch' });
      if (!ok) return;
      abort.current?.abort();
    }
    const current = loadedModel('llama');
    if (current && ref.source === 'local' && ref.modelId !== current.modelId) {
      uiBridge.toast('info', `${current.name} will be unloaded when the new offline model loads (one heavy model at a time).`);
    }
    await setStudioModel('agent', ref);
    if (chat) await updateChat({ modelRef: ref });
  };

  /** Resolve Auto without ever going online silently. */
  const resolveAuto = async (text: string): Promise<ModelRef | null> => {
    const allowCloud = settings.auto.allowCloud || !!chat?.settings.allowCloudInAuto;
    const d = await autoSelect('agent', text, { allowCloud, online, needs: ['chat'] });
    if (d.choice) { uiBridge.toast('info', `Auto: ${d.reason}`); return d.choice.ref; }
    if (d.cloudSuggestion) {
      const ok = await uiBridge.confirm({
        title: 'Use a cloud model?', message: `${d.reason} Auto suggests ${d.cloudSuggestion.providerName} · ${d.cloudSuggestion.name}. Your message and the conversation context will be sent to ${d.cloudSuggestion.providerName}, which may charge your account.`,
        confirmLabel: 'Use cloud for this chat', cancelLabel: 'Stay offline',
      });
      if (ok) { await updateChat({ settings: { ...(chat?.settings ?? {}), allowCloudInAuto: true } }); return d.cloudSuggestion.ref; }
      return null;
    }
    throw new ZinoError('NO_MODEL', `${d.reason} Download or import an offline model in Models, or add a cloud provider in Settings.`, { recovery: ['open_models', 'open_settings_providers'] });
  };

  const onRecovery = (a: RecoveryAction) => {
    if (a === 'open_settings_providers' || a === 'check_api_key') openSettings('providers');
    else if (a === 'open_models' || a === 'choose_smaller_model' || a === 'redownload') setSection('models');
    else if (a === 'reduce_context') setPanel('context');
    else if (a === 'unload_models') void unloadModel('diffusion', { force: false });
    else if (a === 'retry') void send(true);
    else if (a === 'reauthorize_folder') setPanel('files');
  };

  const handleImageCommand = async (c: Chat, prompt: string) => {
    const ref = settings.studioModels.image;
    if (!ref || ref.source === 'auto') throw new ZinoError('NO_MODEL', 'Choose an image model in Image Studio first. /image uses that model.');
    const user = await messagesRepo.insert({ chatId: c.id, role: 'user', content: `/image ${prompt}`, reasoning: null, tokenCount: null, tokenExact: false, tokenModel: null, batchId: null, status: 'complete', modelRef: null, attachments: [], toolCalls: [], toolCallId: null, toolName: null, meta: {} });
    setMessages((ms) => [...ms, user]);
    const task = await generateImage(ref, { mode: 'text', prompt, count: 1, steps: 25, guidance: 7.5, modelLabel: 'Image Studio model' }, c.id);
    const done = await new Promise<typeof task>((resolve) => {
      const unsub = useTasks.subscribe((s) => {
        const t = s.tasks.find((x) => x.id === task.id);
        if (t && ['succeeded', 'failed', 'cancelled'].includes(t.status)) { unsub(); resolve(t); }
      });
    });
    const assets = await assetsRepo.byIds(done.resultAssetIds);
    const reply = await messagesRepo.insert({ chatId: c.id, role: 'assistant', content: done.status === 'succeeded' ? `Generated ${assets.length} image(s).` : `Image generation ${done.status}: ${done.error ?? ''}`,
      reasoning: null, tokenCount: null, tokenExact: false, tokenModel: null, batchId: null, status: 'complete', modelRef: ref,
      attachments: assets.map((a) => ({ assetId: a.id, kind: a.kind, name: a.name })), toolCalls: [], toolCallId: null, toolName: null, meta: { model: 'Image Studio', generatedTaskId: done.id } });
    for (const a of assets) await assetsRepo.save({ ...a, messageId: reply.id });
    setMessages((ms) => [...ms, reply]);
  };

  const send = async (retry = false) => {
    const text = retry ? [...messages].reverse().find((m) => m.role === 'user')?.content ?? '' : draft.trim();
    if (!text && !attachments.length) return;
    if (busy) return;
    const c = await ensureChat();
    setBusy(true);
    if (!retry) setDraft('');
    const atts: MessageAttachment[] = attachments.map((a) => ({ assetId: a.id, kind: a.kind, name: a.name }));
    setAttachments([]);
    const ctrl = new AbortController();
    abort.current = ctrl;
    try {
      if (text.startsWith('/image ')) { await handleImageCommand(c, text.slice(7).trim()); return; }
      let ref = modelRef;
      if (ref.source === 'auto') {
        const r = await resolveAuto(text);
        if (!r) { setDraft(text); return; }
        ref = r;
      }
      if (ref.source === 'cloud' && !online) throw new ZinoError('NETWORK_OFFLINE', 'You are offline. Choose an offline model to keep working without internet.', { recovery: ['open_models'] });
      await runAgentTurn({
        chatId: c.id, text, attachments: atts, modelRef: ref, effort, fileRoot: root ? { id: root.id, name: root.name } : null, signal: ctrl.signal,
        cb: {
          onMessage: (m) => setMessages((ms) => { const i = ms.findIndex((x) => x.id === m.id); if (i < 0) return [...ms, m]; const n = [...ms]; n[i] = { ...n[i], ...m }; return n; }),
          onDelta: (id, d) => setMessages((ms) => ms.map((m) => m.id === id ? { ...m, content: m.content + (d.text ?? ''), reasoning: d.reasoning ? (m.reasoning ?? '') + d.reasoning : m.reasoning } : m)),
          onStatus: setStatus,
          onContext: (r, p) => { setReport(r); setPlan(p); },
          onChatUpdated: () => { setRefreshKey((k) => k + 1); void chatsRepo.get(c.id).then((fresh) => { if (fresh) setChat((cur) => (cur?.id === fresh.id ? fresh : cur)); }); },
        },
      });
    } catch (e) {
      const err = toZinoError(e);
      if (err.code !== 'CANCELLED') uiBridge.toast('error', err.message, err.recovery[0] ? { label: 'Fix', run: () => onRecovery(err.recovery[0]) } : undefined);
    } finally {
      setBusy(false); setStatus(null); abort.current = null;
      setChat((await chatsRepo.get(c.id)) ?? c);
      setMessages(await messagesRepo.list(c.id));
      setRefreshKey((k) => k + 1);
    }
  };

  const newChat = () => { setChat(null); setMessages([]); setReport(null); setAttachments([]); setHistoryOpen(false); };

  return (
    <div className="split" style={{ position: 'relative' }}>
      <ChatHistory currentId={chat?.id ?? null} onSelect={openChat} onNew={newChat} refreshKey={refreshKey} className={historyOpen ? '' : 'hidden-narrow'} />
      <section className="chat-main">
        <div className="chat-toolbar">
          <button className="icon-btn only-narrow" onClick={() => setHistoryOpen(!historyOpen)} aria-label="Chats"><PanelLeft size={18} /></button>
          <ModelSelector studio="agent" value={modelRef} onChange={changeModel} />
          <EffortSelector value={effort} plan={plan} onChange={(e) => void updateChat({ effort: e })} />
          <span className="grow" />
          <ContextMonitor report={report} />
          <button className={`btn sm ${root ? '' : 'ghost'}`} onClick={() => setPanel(panel === 'files' ? null : 'files')} title="AI file manager">
            <FolderOpen size={15} /> <span className="truncate" style={{ maxWidth: 120 }}>{root ? root.name : 'Files'}</span>
          </button>
          <button className="icon-btn" onClick={() => setPanel(panel === 'context' ? null : 'context')} aria-label="Context details"><PanelRight size={18} /></button>
        </div>
        <div className="messages" ref={scroller}>
          {messages.length === 0 ? (
            <div className="empty" style={{ height: '100%' }}>
              <MessageSquare size={36} />
              <h2>What can I help with?</h2>
              <div className="small muted" style={{ maxWidth: 520 }}>
                Chat with an offline GGUF model or a cloud model. Authorise a folder (Files button) to let the AI find, organise and rename files — every change is validated, confirmed when risky, and undoable.
                Type <code>/image</code> followed by a prompt to generate an image with the Image Studio model.
              </div>
            </div>
          ) : messages.map((m) => <MessageView key={m.id} m={m} onRecovery={onRecovery} />)}
          {status && <div className="message"><div className="avatar"><Bot size={16} /></div><div className="content row small muted"><span className="spinner" /> {status}</div></div>}
        </div>
        <div className="composer">
          <div className="composer-inner">
            {attachments.length > 0 && (
              <div className="row wrap">
                {attachments.map((a) => (
                  <div key={a.id} className="thumb" style={{ width: 64, height: 64, position: 'relative' }}>
                    <AssetMedia asset={a} />
                    <button className="icon-btn sm" style={{ position: 'absolute', top: -6, right: -6, background: 'var(--surface)' }} onClick={() => setAttachments((x) => x.filter((y) => y.id !== a.id))} aria-label="Remove"><X size={13} /></button>
                  </div>
                ))}
              </div>
            )}
            <div className="composer-box">
              <button className="icon-btn sm" onClick={() => setPicker(true)} aria-label="Attach image" title="Attach an image"><ImagePlus size={18} /></button>
              <textarea rows={1} value={draft} placeholder={modelRef.source === 'local' ? 'Message (offline — stays on this iPad)' : 'Message'}
                onChange={(e) => { setDraft(e.target.value); e.target.style.height = 'auto'; e.target.style.height = `${Math.min(220, e.target.scrollHeight)}px`; }}
                onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); void send(); } }} />
              {busy ? (
                <button className="btn sm" onClick={() => abort.current?.abort()} aria-label="Stop"><Square size={14} /> Stop</button>
              ) : (
                <button className="btn primary sm" onClick={() => void send()} disabled={!draft.trim() && !attachments.length} aria-label="Send"><ArrowUp size={16} /></button>
              )}
            </div>
            <div className="tiny faint row">
              <span className="grow">{modelRef.source === 'cloud' ? 'Cloud model: messages are sent to the provider.' : modelRef.source === 'local' ? 'Offline: nothing leaves this iPad.' : 'Auto: offline first; asks before using the cloud.'}</span>
              {root && <span>Files: {root.name}</span>}
            </div>
          </div>
        </div>
      </section>
      {panel && (
        <aside className="side-panel">
          <div className="row" style={{ padding: '10px 14px', borderBottom: '1px solid var(--border)' }}>
            {panel === 'files' ? <FolderOpen size={16} /> : <Layers size={16} />}
            <strong className="grow">{panel === 'files' ? 'AI File Manager' : 'Context'}</strong>
            <button className="icon-btn sm" onClick={() => setPanel(null)} aria-label="Close"><X size={16} /></button>
          </div>
          <div className="side-panel-body">
            {panel === 'files' ? (
              <FileExplorer rootId={rootId} onRootChange={(r) => { void updateChat({ settings: { ...(chat?.settings ?? {}), fileToolsRootId: r?.id ?? null } }); if (r) setRoots((x) => x.some((y) => y.id === r.id) ? x : [...x, r]); }} />
            ) : report ? (
              <div className="stack">
                <ContextBreakdown report={report} />
                {plan && (
                  <div className="card stack-sm"><strong className="small">Effort: {plan.level}{plan.autoReason ? ` (auto: ${plan.autoReason})` : ''}</strong>
                    {plan.applied.map((a, i) => <div key={i} className="tiny">✓ {a}</div>)}
                    {plan.notApplied.map((a, i) => <div key={i} className="tiny" style={{ color: 'var(--warning)' }}>• {a}</div>)}
                  </div>
                )}
              </div>
            ) : <p className="small muted">Select a specific model to see its context usage.</p>}
          </div>
        </aside>
      )}
      {picker && <AssetPicker kind="image" title="Attach an image" onPick={(a) => setAttachments((x) => [...x, a])} onClose={() => setPicker(false)} />}
    </div>
  );
}
