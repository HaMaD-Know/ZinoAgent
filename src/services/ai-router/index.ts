// AI router: runs one agent turn end to end.
//  model resolution → effort plan → SmartContextEngine (compaction/retrieval) → stream from the
//  local or cloud engine → tool calls (validated, permission-gated) → persistence → auto title.
import type { ChatMessage, EffortLevel, MessageAttachment, ModelRef, ToolCall } from '@/types';
import { assetsRepo, chatsRepo, messagesRepo, modelsRepo, providersRepo, uid } from '@/database/repositories';
import { ZinoStorage } from '@/native';
import { ZinoError, toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { loadSettings, modelKey, type AppSettings } from '@/services/settings';
import { chatAdapterFor } from '@/services/provider-manager';
import { ensureChatModel } from '@/services/model-manager';
import {
  SmartContextEngine, EstimateTokenizer, LlamaTokenizer, repoContextStore, SUMMARY_SYSTEM_PROMPT, CROSSCHECK_PROMPT,
  type AssembledContext, type ContextReport, type Summarizer,
} from '@/services/context-engine';
import { FILE_TOOLS, FileToolExecutor } from '@/services/file-manager';
import type { ChatResult, ProviderMessage, StreamEvent, ToolDefinition } from '@/providers/types';
import { planEffort, resolveRequestedEffort, type EffortPlan } from './effort';
import { localChat, localComplete } from './local';
import { useResources } from '@/services/resources';

export * from './effort';
export * from './models';

export interface TurnCallbacks {
  onMessage(msg: ChatMessage): void;
  onDelta(id: string, d: { text?: string; reasoning?: string }): void;
  onStatus(status: string | null): void;
  onContext(report: ContextReport, plan: EffortPlan): void;
  /** Chat metadata changed after the turn (e.g. an auto-generated title). */
  onChatUpdated?(): void;
}

export interface RunTurnOptions {
  chatId: string;
  text: string;
  attachments?: MessageAttachment[];
  modelRef: ModelRef;
  effort: EffortLevel;
  fileRoot?: { id: string; name: string } | null;
  signal: AbortSignal;
  cb: TurnCallbacks;
}

interface Target {
  kind: 'local' | 'cloud';
  label: string;
  contextLength: number;
  tokenizer: EstimateTokenizer | LlamaTokenizer;
  modelId: string;
  providerId?: string;
  providerName?: string;
  supportsTools: boolean;
  supportsVision: boolean;
}

const DEFAULT_CLOUD_CONTEXT = 128_000;

async function resolveTarget(ref: ModelRef, settings: AppSettings, onStatus: (s: string | null) => void): Promise<Target> {
  if (ref.source === 'auto') throw new ZinoError('INVALID_ARGUMENT', 'Auto must be resolved before running a turn.');
  if (ref.source === 'local') {
    onStatus('Loading offline model…');
    const { model, contextLength } = await ensureChatModel(ref.modelId);
    onStatus(null);
    return {
      kind: 'local', label: model.name, contextLength, tokenizer: new LlamaTokenizer(`llama:${model.id}`), modelId: model.id,
      supportsTools: true, supportsVision: false,
    };
  }
  const provider = await providersRepo.get(ref.providerId);
  if (!provider) throw new ZinoError('NOT_FOUND', 'That provider was removed. Choose another model.', { recovery: ['open_settings_providers'] });
  const info = (await providersRepo.models(provider.id)).find((m) => m.modelId === ref.modelId) ?? null;
  const ctx = Math.min(info?.contextLength ?? provider.options.contextLength ?? DEFAULT_CLOUD_CONTEXT, settings.contextCloudCap ?? DEFAULT_CLOUD_CONTEXT);
  const supportsTools = provider.kind === 'openai_compatible' ? !!provider.options.supportsTools : (info?.capabilities.includes('tool_calling') ?? true);
  return {
    kind: 'cloud', label: `${provider.name} · ${info?.displayName ?? ref.modelId}`, contextLength: ctx,
    tokenizer: new EstimateTokenizer(`estimate:${provider.kind}`), modelId: ref.modelId, providerId: provider.id, providerName: provider.name,
    supportsTools, supportsVision: info?.capabilities.includes('vision') ?? false,
  };
}

/** Summariser bound to the same model the chat uses (so data never goes anywhere new). */
function makeSummarizer(target: Target, ref: ModelRef): Summarizer {
  const run = async (system: string, user: string, maxTokens: number) => {
    if (target.kind === 'local') return localComplete(system, user, maxTokens);
    const provider = (await providersRepo.get(target.providerId!))!;
    const info = (await providersRepo.models(provider.id)).find((m) => m.modelId === target.modelId) ?? null;
    const plan = planEffort({ requested: 'low', prompt: '', engine: provider.kind, modelId: target.modelId, modelInfo: info, providerOptions: provider.options, outputLimit: info?.outputLimit });
    const r = await chatAdapterFor(provider.kind).chat(provider, {
      model: target.modelId, messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
      effort: { ...plan.params, maxOutputTokens: Math.max(maxTokens, plan.params.maxOutputTokens) }, modelInfo: info,
    }, () => {});
    return r.text;
  };
  return {
    modelRef: ref,
    summarize: ({ transcript, feedback, maxTokens, level }) => run(
      SUMMARY_SYSTEM_PROMPT,
      `${level > 1 ? 'Combine these partial summaries into one.' : 'Summarise this part of the conversation.'}\n\n${transcript}` +
        (feedback?.length ? `\n\nYour previous summary failed verification. Fix it:\n- ${feedback.join('\n- ')}` : ''),
      maxTokens),
    crossCheck: (transcript, summary) => run(CROSSCHECK_PROMPT, `ORIGINAL:\n${transcript}\n\nSUMMARY:\n${summary}`, 400),
  };
}

async function toProviderMessages(history: ChatMessage[], target: Target): Promise<ProviderMessage[]> {
  const out: ProviderMessage[] = [];
  for (const m of history) {
    if (m.role === 'tool') { out.push({ role: 'tool', content: m.content, toolCallId: m.toolCallId ?? undefined, toolName: m.toolName ?? undefined }); continue; }
    if (m.role === 'assistant') {
      const raw = m.meta.raw as ProviderMessage['raw'] | undefined;
      const sameProvider = raw && target.kind === 'cloud' && m.modelRef?.source === 'cloud' && m.modelRef.providerId === target.providerId;
      out.push({ role: 'assistant', content: m.content, toolCalls: m.toolCalls, raw: sameProvider ? raw : undefined });
      continue;
    }
    if (m.role === 'user') {
      const images: { mime: string; base64: string }[] = [];
      const notes: string[] = [];
      for (const a of m.attachments) {
        const asset = await assetsRepo.get(a.assetId);
        if (!asset) continue;
        if (asset.kind === 'image' && target.supportsVision) {
          try { images.push({ mime: asset.mime, base64: (await ZinoStorage.readBase64({ path: asset.path })).data }); } catch { notes.push(`[Attachment ${asset.name} could not be read]`); }
        } else notes.push(`[Attached ${asset.kind}: ${asset.name}]`);
      }
      out.push({ role: 'user', content: [m.content, ...notes].filter(Boolean).join('\n'), images: images.length ? images : undefined });
    }
  }
  return out;
}

const baseMessage = (chatId: string, role: ChatMessage['role'], content: string, ref: ModelRef | null): Omit<ChatMessage, 'id' | 'seq' | 'createdAt'> => ({
  chatId, role, content, reasoning: null, tokenCount: null, tokenExact: false, tokenModel: null, batchId: null, status: 'complete',
  modelRef: ref, attachments: [], toolCalls: [], toolCallId: null, toolName: null, meta: {},
});

export async function runAgentTurn(o: RunTurnOptions): Promise<void> {
  const settings = await loadSettings();
  const chat = await chatsRepo.get(o.chatId);
  if (!chat) throw new ZinoError('NOT_FOUND', 'Chat not found.');

  const userMsg = await messagesRepo.insert({ ...baseMessage(o.chatId, 'user', o.text, null), attachments: o.attachments ?? [] });
  o.cb.onMessage(userMsg);
  await chatsRepo.update(o.chatId, { modelRef: o.modelRef });

  const target = await resolveTarget(o.modelRef, settings, o.cb.onStatus);
  const provider = target.providerId ? await providersRepo.get(target.providerId) : null;
  const providerModel = provider ? (await providersRepo.models(provider.id)).find((m) => m.modelId === target.modelId) ?? null : null;

  const requested = resolveRequestedEffort({ chatEffort: o.effort, modelKey: modelKey(o.modelRef), studio: 'agent', online: target.kind === 'cloud', settings: settings.effort });
  const plan = planEffort({
    requested, prompt: o.text, engine: target.kind === 'local' ? 'local' : provider!.kind, modelId: target.modelId, modelInfo: providerModel,
    providerOptions: provider?.options, outputLimit: providerModel?.outputLimit, contextLength: target.contextLength,
    attachments: o.attachments?.length, toolsAvailable: !!o.fileRoot, llmVerification: settings.context.llmVerification,
  });

  const useTools = !!o.fileRoot && settings.agent.fileToolsEnabled && target.supportsTools;
  const tools: ToolDefinition[] = useTools ? FILE_TOOLS : [];
  const groupId = uid();
  const executor = o.fileRoot ? new FileToolExecutor({
    rootId: o.fileRoot.id, rootName: o.fileRoot.name, chatId: o.chatId, groupId,
    cloudProvider: target.kind === 'cloud' ? target.providerName : null,
    ensureCloudMetadataAccess: async () => {
      const c = await chatsRepo.get(o.chatId);
      if (c?.settings.cloudFileAccess === 'allowed') return true;
      const ok = await uiBridge.confirm({
        title: `Let ${target.providerName} see your files?`,
        message: `The AI wants to look at "${o.fileRoot!.name}". File names, sizes and folder structure will be sent to ${target.providerName}. File contents are asked for separately.`,
        confirmLabel: 'Allow for this chat', cancelLabel: 'Not now',
      });
      if (ok) await chatsRepo.update(o.chatId, { settings: { ...(c?.settings ?? {}), cloudFileAccess: 'allowed' } });
      return ok;
    },
  }) : null;

  const engine = new SmartContextEngine(repoContextStore, target.tokenizer, makeSummarizer(target, o.modelRef), {
    compactionThreshold: settings.context.perModelThreshold[modelKey(o.modelRef)] ?? settings.context.compactionThreshold,
    compactionTarget: settings.context.compactionTarget, batchReferenceSize: settings.context.batchReferenceSize,
    retrieval: settings.context.retrieval, summaryVerification: settings.context.summaryVerification, minRecentMessages: settings.context.minRecentMessages,
  });
  const systemPrompt = [
    chat.settings.systemPrompt || settings.agent.systemPrompt,
    useTools ? `The user authorised the folder "${o.fileRoot!.name}". Use the file tools for file questions; paths are relative to that folder.` : '',
    o.fileRoot && !useTools ? 'File tools are not available with the selected model.' : '',
  ].filter(Boolean).join('\n\n');
  const reservedOutput = Math.min(plan.params.maxOutputTokens, Math.floor(target.contextLength * 0.5));
  const pressure = useResources.getState().pressure !== 'normal';

  for (let iteration = 0; iteration <= settings.agent.maxToolIterations; iteration++) {
    if (o.signal.aborted) throw new ZinoError('CANCELLED', 'Cancelled.');
    let ctx: AssembledContext;
    try {
      ctx = await engine.prepare({
        chatId: o.chatId, systemPrompt, contextLength: target.contextLength, reservedOutput, query: o.text,
        retrievalBatches: plan.context.retrievalBatches, llmVerification: plan.context.llmVerification, memoryPressure: pressure,
        onStatus: o.cb.onStatus,
      });
    } finally { o.cb.onStatus(null); }
    o.cb.onContext(ctx.report, plan);
    for (const w of ctx.report.warnings) if (iteration === 0) uiBridge.toast('warning', w);

    const messages: ProviderMessage[] = [{ role: 'system', content: ctx.system }, ...(await toProviderMessages(ctx.history, target))];
    const assistant = await messagesRepo.insert({ ...baseMessage(o.chatId, 'assistant', '', o.modelRef), status: 'streaming',
      meta: { model: target.label, effort: { level: plan.level, applied: plan.applied, notApplied: plan.notApplied, autoReason: plan.autoReason } } });
    o.cb.onMessage(assistant);

    let text = '';
    let reasoning = '';
    let lastSave = 0;
    const onEvent = (e: StreamEvent) => {
      if (e.type === 'text') { text += e.text; o.cb.onDelta(assistant.id, { text: e.text }); }
      else if (e.type === 'reasoning') { reasoning += e.text; o.cb.onDelta(assistant.id, { reasoning: e.text }); }
      if (Date.now() - lastSave > 1000) { lastSave = Date.now(); void messagesRepo.update(assistant.id, { content: text, reasoning: reasoning || null }); }
    };

    let result: ChatResult & { tokensPerSecond?: number; templateFallback?: boolean };
    const started = Date.now();
    try {
      if (target.kind === 'local') {
        result = await localChat({ messages, tools, maxTokens: plan.params.maxOutputTokens, sampling: plan.local!, signal: o.signal, onEvent });
      } else {
        result = await chatAdapterFor(provider!.kind).chat(provider!, {
          model: target.modelId, messages, tools: tools.length ? tools : undefined, effort: plan.params, signal: o.signal, modelInfo: providerModel,
        }, onEvent);
      }
    } catch (e) {
      const err = toZinoError(e);
      const cancelled = err.code === 'CANCELLED';
      await messagesRepo.update(assistant.id, {
        content: text, reasoning: reasoning || null, status: cancelled ? 'cancelled' : 'error',
        meta: { ...assistant.meta, error: cancelled ? undefined : { code: err.code, message: err.message, recovery: err.recovery } },
      });
      o.cb.onMessage({ ...(await messagesRepo.byIds([assistant.id]))[0] });
      throw err;
    }

    const toolCalls: ToolCall[] = result.toolCalls.map((c) => ({ id: c.id, name: c.name, arguments: c.arguments }));
    const final: Partial<ChatMessage> = {
      content: result.text, reasoning: result.reasoning || null, status: 'complete', toolCalls,
      meta: {
        ...assistant.meta, usage: result.usage, stopReason: result.stopReason, durationMs: Date.now() - started,
        tokensPerSecond: result.tokensPerSecond, templateFallback: result.templateFallback, raw: result.raw,
      },
    };
    await messagesRepo.update(assistant.id, final as Parameters<typeof messagesRepo.update>[1]);
    o.cb.onMessage({ ...assistant, ...final } as ChatMessage);

    if (!toolCalls.length || !executor) break;
    if (iteration === settings.agent.maxToolIterations) {
      uiBridge.toast('warning', 'Stopped after the maximum number of tool steps. Ask the assistant to continue if needed.');
      break;
    }
    for (const call of toolCalls) {
      o.cb.onStatus(`Running ${call.name.replace(/_/g, ' ')}…`);
      const outcome = await executor.execute(call.name, call.arguments);
      const toolMsg = await messagesRepo.insert({ ...baseMessage(o.chatId, 'tool', outcome.content, o.modelRef), toolCallId: call.id, toolName: call.name,
        meta: { ok: outcome.ok, changed: outcome.changed, groupId } });
      o.cb.onMessage(toolMsg);
    }
    o.cb.onStatus(null);
  }

  void maybeAutoTitle(o.chatId, target, o.modelRef, settings).then((changed) => { if (changed) o.cb.onChatUpdated?.(); });
}

function heuristicTitle(text: string) {
  const clean = text.replace(/\s+/g, ' ').replace(/[#*`>]/g, '').trim();
  const words = clean.split(' ').slice(0, 7).join(' ');
  return (words.length > 48 ? words.slice(0, 48) + '…' : words) || 'New chat';
}

async function maybeAutoTitle(chatId: string, target: Target, ref: ModelRef, settings: AppSettings): Promise<boolean> {
  const chat = await chatsRepo.get(chatId);
  if (!chat || !chat.titleAuto || !settings.agent.autoTitle) return false;
  const msgs = (await messagesRepo.list(chatId)).filter((m) => m.role === 'user' || m.role === 'assistant');
  if (msgs.length < 2 || msgs.length > 6) return false;
  const firstUser = msgs.find((m) => m.role === 'user')?.content ?? '';
  let title = heuristicTitle(firstUser);
  try {
    const prompt = `Write a 3-6 word title for this conversation. Reply with the title only.\n\nUser: ${firstUser.slice(0, 1500)}\nAssistant: ${(msgs.find((m) => m.role === 'assistant')?.content ?? '').slice(0, 800)}`;
    const raw = await makeSummarizer(target, ref).summarize({ transcript: prompt, level: 0, maxTokens: 24 }).catch(() => '');
    const t = raw.split('\n').map((l) => l.replace(/^#+\s*|^title:\s*/i, '').replace(/^["'*]+|["'*.]+$/g, '').trim()).find((l) => l.length > 2 && l.length < 70);
    if (t) title = t;
  } catch { /* keep heuristic */ }
  // Keep the chat's position in the list: only the title changes.
  await chatsRepo.update(chatId, { title, updatedAt: chat.updatedAt });
  return true;
}

/** Context dashboard without sending anything (used when opening a chat or switching models). */
export async function previewContext(chatId: string, ref: ModelRef, effort: EffortLevel): Promise<{ report: ContextReport; plan: EffortPlan } | null> {
  if (ref.source === 'auto') return null;
  const settings = await loadSettings();
  const chat = await chatsRepo.get(chatId);
  if (!chat) return null;
  let contextLength = 4096;
  let tokenizer: EstimateTokenizer | LlamaTokenizer = new EstimateTokenizer();
  let engineKind: 'local' | import('@/types').ProviderKind = 'local';
  let modelInfo = null;
  let provider = null;
  if (ref.source === 'local') {
    const loaded = useResources.getState().loaded.find((m) => m.kind === 'llama' && m.modelId === ref.modelId);
    const m = await modelsRepo.get(ref.modelId);
    if (!m) return null;
    contextLength = loaded?.contextLength ?? m.settings.contextLength ?? 4096;
    tokenizer = loaded ? new LlamaTokenizer(`llama:${m.id}`) : new EstimateTokenizer();
  } else {
    provider = await providersRepo.get(ref.providerId);
    if (!provider) return null;
    modelInfo = (await providersRepo.models(provider.id)).find((m) => m.modelId === ref.modelId) ?? null;
    contextLength = Math.min(modelInfo?.contextLength ?? provider.options.contextLength ?? DEFAULT_CLOUD_CONTEXT, settings.contextCloudCap ?? DEFAULT_CLOUD_CONTEXT);
    tokenizer = new EstimateTokenizer(`estimate:${provider.kind}`);
    engineKind = provider.kind;
  }
  const requested = resolveRequestedEffort({ chatEffort: effort, modelKey: modelKey(ref), studio: 'agent', online: ref.source === 'cloud', settings: settings.effort });
  const plan = planEffort({ requested, prompt: '', engine: engineKind, modelId: ref.modelId, modelInfo, providerOptions: provider?.options, outputLimit: modelInfo?.outputLimit, contextLength });
  const engine = new SmartContextEngine(repoContextStore, tokenizer, null, {
    compactionThreshold: settings.context.compactionThreshold, compactionTarget: settings.context.compactionTarget,
    batchReferenceSize: settings.context.batchReferenceSize, retrieval: settings.context.retrieval,
    summaryVerification: settings.context.summaryVerification, minRecentMessages: settings.context.minRecentMessages,
  });
  const ctx = await engine.prepare({
    chatId, systemPrompt: chat.settings.systemPrompt || settings.agent.systemPrompt, contextLength,
    reservedOutput: Math.min(plan.params.maxOutputTokens, Math.floor(contextLength * 0.5)), query: '', retrievalBatches: 0, llmVerification: false, allowCompaction: false,
  });
  return { report: ctx.report, plan };
}
