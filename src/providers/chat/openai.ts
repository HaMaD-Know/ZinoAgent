// OpenAI Chat Completions adapter (also used for OpenAI-compatible endpoints).
import type { Capability, Provider, ProviderModel } from '@/types';
import { ZinoError } from '@/services/errors';
import { authFor, trimSlash, type ChatAdapter, type ChatRequest, type ChatResult, type ConnectionTestResult, type ProviderAdapter, type ProviderMessage, type StreamEvent } from '../types';
import { requestJson, streamSSE } from '../http';

/** OpenAI reasoning model families (accept reasoning_effort, reject temperature). */
export const isOpenAIReasoningModel = (id: string) => /^(o\d|gpt-5)/i.test(id);

export function openAICapabilities(id: string): Capability[] {
  const m = id.toLowerCase();
  if (/^(gpt-image|dall-e)/.test(m)) return m.startsWith('dall-e-3') ? ['image_generation'] : ['image_generation', 'image_editing'];
  if (/^sora/.test(m)) return ['video_generation'];
  if (/(embedding|whisper|tts|transcribe|audio|realtime|moderation|search|computer-use|davinci|babbage)/.test(m)) return [];
  if (/^(gpt-|o\d|chatgpt-)/.test(m)) {
    const caps: Capability[] = ['chat', 'tool_calling'];
    if (isOpenAIReasoningModel(m)) caps.push('reasoning');
    if (/^(gpt-4o|gpt-4\.1|gpt-5|o1|o3|o4|chatgpt-4o)/.test(m)) caps.push('vision');
    return caps;
  }
  return [];
}

function toOpenAIMessages(messages: ProviderMessage[]) {
  return messages.map((m) => {
    if (m.role === 'tool') return { role: 'tool', tool_call_id: m.toolCallId, content: m.content };
    if (m.role === 'assistant') {
      const out: Record<string, unknown> = { role: 'assistant', content: m.content || null };
      if (m.toolCalls?.length) {
        out.tool_calls = m.toolCalls.map((c) => ({ id: c.id, type: 'function', function: { name: c.name, arguments: JSON.stringify(c.arguments) } }));
      }
      return out;
    }
    if (m.role === 'user' && m.images?.length) {
      return {
        role: 'user',
        content: [
          { type: 'text', text: m.content },
          ...m.images.map((i) => ({ type: 'image_url', image_url: { url: `data:${i.mime};base64,${i.base64}` } })),
        ],
      };
    }
    return { role: m.role, content: m.content };
  });
}

export const openaiAdapter: ChatAdapter & ProviderAdapter = {
  async testConnection(p: Provider): Promise<ConnectionTestResult> {
    const models = await this.listModels(p);
    return { ok: true, message: `Connected. ${models.length} models available.`, modelCount: models.length };
  },

  async listModels(p: Provider): Promise<ProviderModel[]> {
    const res = await requestJson<{ data?: { id: string; context_length?: number; name?: string; owned_by?: string }[] }>({
      url: `${trimSlash(p.baseUrl)}/models`, auth: authFor(p), headers: p.options.headers, provider: p.name,
    });
    const now = Date.now();
    const compatible = p.kind === 'openai_compatible';
    return (res.data ?? []).map((m) => {
      let caps = compatible ? (['chat'] as Capability[]) : openAICapabilities(m.id);
      if (compatible && p.options.supportsTools) caps = [...caps, 'tool_calling'];
      if (compatible && p.options.supportsReasoningEffort) caps = [...caps, 'reasoning'];
      return {
        id: `${p.id}:${m.id}`, providerId: p.id, modelId: m.id, displayName: m.name ?? m.id, capabilities: caps,
        contextLength: m.context_length ?? p.options.contextLength ?? null, outputLimit: null,
        metadata: { ownedBy: m.owned_by, capabilitiesInferred: !compatible }, fetchedAt: now,
      };
    }).filter((m) => m.capabilities.length > 0);
  },

  async chat(p: Provider, req: ChatRequest, onEvent: (e: StreamEvent) => void): Promise<ChatResult> {
    const compatible = p.kind === 'openai_compatible';
    const reasoning = !compatible && isOpenAIReasoningModel(req.model);
    const body: Record<string, unknown> = {
      model: req.model,
      messages: toOpenAIMessages(req.messages),
      stream: true,
    };
    if (!compatible) body.stream_options = { include_usage: true };
    if (compatible) body.max_tokens = req.effort.maxOutputTokens;
    else body.max_completion_tokens = req.effort.maxOutputTokens;
    if (req.effort.openaiReasoningEffort && (reasoning || (compatible && p.options.supportsReasoningEffort))) {
      body.reasoning_effort = req.effort.openaiReasoningEffort;
    }
    if (!reasoning && req.effort.temperature !== undefined) body.temperature = req.effort.temperature;
    if (req.tools?.length && (!compatible || p.options.supportsTools)) {
      body.tools = req.tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } }));
    }

    let text = '';
    let reasoningText = '';
    let stopReason = 'stop';
    const usage: ChatResult['usage'] = {};
    const calls = new Map<number, { id: string; name: string; args: string }>();
    let streamError: ZinoError | null = null;

    await streamSSE({ url: `${trimSlash(p.baseUrl)}/chat/completions`, json: body, auth: authFor(p), headers: p.options.headers, signal: req.signal, provider: p.name }, (data) => {
      if (data === '[DONE]') return;
      let j: any;
      try { j = JSON.parse(data); } catch { return; }
      if (j.error) { streamError = new ZinoError('PROVIDER_REJECTED', `${p.name}: ${j.error.message ?? 'stream error'}`); return; }
      if (j.usage) {
        usage.inputTokens = j.usage.prompt_tokens;
        usage.outputTokens = j.usage.completion_tokens;
        onEvent({ type: 'usage', ...usage });
      }
      const choice = j.choices?.[0];
      if (!choice) return;
      const d = choice.delta ?? {};
      if (typeof d.content === 'string' && d.content) { text += d.content; onEvent({ type: 'text', text: d.content }); }
      const r = d.reasoning_content ?? d.reasoning;
      if (typeof r === 'string' && r) { reasoningText += r; onEvent({ type: 'reasoning', text: r }); }
      for (const tc of d.tool_calls ?? []) {
        const idx = tc.index ?? 0;
        const cur = calls.get(idx) ?? { id: '', name: '', args: '' };
        if (tc.id) cur.id = tc.id;
        if (tc.function?.name) cur.name += tc.function.name;
        if (tc.function?.arguments) cur.args += tc.function.arguments;
        calls.set(idx, cur);
      }
      if (choice.finish_reason) stopReason = choice.finish_reason;
    });
    if (streamError) throw streamError;

    const toolCalls = [...calls.values()].map((c, i) => {
      let args: Record<string, unknown> = {};
      try { args = c.args ? JSON.parse(c.args) : {}; } catch { args = { __invalid_json: c.args }; }
      const call = { id: c.id || `call_${i}`, name: c.name, arguments: args };
      onEvent({ type: 'tool_call', call });
      return call;
    });
    return { text, reasoning: reasoningText, toolCalls, usage, stopReason };
  },
};
