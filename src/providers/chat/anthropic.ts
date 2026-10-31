// Anthropic Messages API adapter (raw HTTP so the key stays in the Keychain).
// Thinking: adaptive thinking + output_config.effort on models that report adaptive support
// (4.6+); budget_tokens only on older models that require it; no sampling params are sent.
import type { Capability, Provider, ProviderModel } from '@/types';
import { ZinoError } from '@/services/errors';
import { authFor, trimSlash, type ChatAdapter, type ChatRequest, type ChatResult, type ConnectionTestResult, type ProviderAdapter, type ProviderMessage, type StreamEvent } from '../types';
import { requestJson, streamSSE } from '../http';

const VERSION_HEADERS = { 'anthropic-version': '2023-06-01' };

interface AnthropicModel {
  id: string;
  display_name?: string;
  max_input_tokens?: number;
  max_tokens?: number;
  capabilities?: Record<string, any>;
}

const supported = (node: any): boolean => !!node && node.supported === true;

export function anthropicThinkingMode(info: ProviderModel | null | undefined, modelId: string): 'adaptive' | 'budget' | 'none' {
  const caps = info?.metadata?.capabilities as Record<string, any> | undefined;
  if (caps?.thinking) {
    if (supported(caps.thinking?.types?.adaptive)) return 'adaptive';
    if (supported(caps.thinking?.types?.enabled) || supported(caps.thinking)) return 'budget';
    return 'none';
  }
  // Fallback when the Models API did not report capabilities: infer from the model id.
  const m = modelId.toLowerCase();
  if (/claude-(opus|sonnet|haiku|fable|mythos)-(4-[6-9]|[5-9])/.test(m)) return 'adaptive';
  if (/claude-(3-7|sonnet-4|opus-4|haiku-4-5|sonnet-4-5|opus-4-[015])/.test(m)) return 'budget';
  return 'none';
}

export function anthropicEffortLevels(info: ProviderModel | null | undefined): string[] {
  const e = (info?.metadata?.capabilities as Record<string, any> | undefined)?.effort;
  if (!e) return ['low', 'medium', 'high', 'max'];
  return ['low', 'medium', 'high', 'xhigh', 'max'].filter((l) => supported(e[l]));
}

function toAnthropic(messages: ProviderMessage[]) {
  const system = messages.filter((m) => m.role === 'system').map((m) => m.content).join('\n\n');
  const out: { role: 'user' | 'assistant'; content: any[] }[] = [];
  const push = (role: 'user' | 'assistant', blocks: any[]) => {
    const last = out[out.length - 1];
    if (last && last.role === role) last.content.push(...blocks);
    else out.push({ role, content: blocks });
  };
  for (const m of messages) {
    if (m.role === 'system') continue;
    if (m.role === 'tool') {
      push('user', [{ type: 'tool_result', tool_use_id: m.toolCallId, content: m.content }]);
    } else if (m.role === 'assistant') {
      if (m.raw?.kind === 'anthropic' && Array.isArray(m.raw.content)) {
        push('assistant', m.raw.content as any[]);
      } else {
        const blocks: any[] = [];
        if (m.content) blocks.push({ type: 'text', text: m.content });
        for (const c of m.toolCalls ?? []) blocks.push({ type: 'tool_use', id: c.id, name: c.name, input: c.arguments });
        if (blocks.length) push('assistant', blocks);
      }
    } else {
      const blocks: any[] = (m.images ?? []).map((i) => ({ type: 'image', source: { type: 'base64', media_type: i.mime, data: i.base64 } }));
      blocks.push({ type: 'text', text: m.content || ' ' });
      push('user', blocks);
    }
  }
  return { system, messages: out };
}

export const anthropicAdapter: ChatAdapter & ProviderAdapter = {
  async testConnection(p: Provider): Promise<ConnectionTestResult> {
    const models = await this.listModels(p);
    return { ok: true, message: `Connected. ${models.length} Claude models available.`, modelCount: models.length };
  },

  async listModels(p: Provider): Promise<ProviderModel[]> {
    const all: AnthropicModel[] = [];
    let after: string | undefined;
    for (let page = 0; page < 10; page++) {
      const url = `${trimSlash(p.baseUrl)}/models?limit=1000${after ? `&after_id=${encodeURIComponent(after)}` : ''}`;
      const res = await requestJson<{ data: AnthropicModel[]; has_more?: boolean; last_id?: string }>({ url, auth: authFor(p), headers: VERSION_HEADERS, provider: p.name });
      all.push(...(res.data ?? []));
      if (!res.has_more || !res.last_id) break;
      after = res.last_id;
    }
    const now = Date.now();
    return all.map((m) => {
      const caps: Capability[] = ['chat', 'tool_calling'];
      if (!m.capabilities || supported(m.capabilities.thinking)) caps.push('reasoning');
      if (!m.capabilities || supported(m.capabilities.image_input)) caps.push('vision');
      return {
        id: `${p.id}:${m.id}`, providerId: p.id, modelId: m.id, displayName: m.display_name ?? m.id, capabilities: caps,
        contextLength: m.max_input_tokens ?? null, outputLimit: m.max_tokens ?? null,
        metadata: { capabilities: m.capabilities ?? null }, fetchedAt: now,
      };
    });
  },

  async chat(p: Provider, req: ChatRequest, onEvent: (e: StreamEvent) => void): Promise<ChatResult> {
    const { system, messages } = toAnthropic(req.messages);
    const body: Record<string, unknown> = { model: req.model, max_tokens: req.effort.maxOutputTokens, messages, stream: true };
    if (system) body.system = system;
    const th = req.effort.anthropicThinking;
    if (th?.mode === 'adaptive') {
      body.thinking = { type: 'adaptive', display: 'summarized' };
      body.output_config = { effort: th.effort };
    } else if (th?.mode === 'budget') {
      body.thinking = { type: 'enabled', budget_tokens: th.budgetTokens };
      body.max_tokens = Math.max(req.effort.maxOutputTokens, th.budgetTokens + 1024);
    }
    if (req.tools?.length) {
      body.tools = req.tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.parameters }));
    }

    const blocks: any[] = [];
    const partialJson = new Map<number, string>();
    let stopReason = 'end_turn';
    const usage: ChatResult['usage'] = {};
    let streamError: ZinoError | null = null;

    await streamSSE({ url: `${trimSlash(p.baseUrl)}/messages`, json: body, auth: authFor(p), headers: VERSION_HEADERS, signal: req.signal, provider: p.name, timeoutSeconds: 1800 }, (data, event) => {
      let j: any;
      try { j = JSON.parse(data); } catch { return; }
      const type = event ?? j.type;
      switch (type) {
        case 'message_start':
          usage.inputTokens = j.message?.usage?.input_tokens;
          break;
        case 'content_block_start':
          blocks[j.index] = { ...j.content_block };
          if (j.content_block?.type === 'text') blocks[j.index].text = j.content_block.text ?? '';
          if (j.content_block?.type === 'thinking') blocks[j.index].thinking = j.content_block.thinking ?? '';
          break;
        case 'content_block_delta': {
          const b = blocks[j.index];
          const d = j.delta ?? {};
          if (!b) break;
          if (d.type === 'text_delta') { b.text += d.text; onEvent({ type: 'text', text: d.text }); }
          else if (d.type === 'thinking_delta') { b.thinking += d.thinking; onEvent({ type: 'reasoning', text: d.thinking }); }
          else if (d.type === 'signature_delta') { b.signature = (b.signature ?? '') + d.signature; }
          else if (d.type === 'input_json_delta') partialJson.set(j.index, (partialJson.get(j.index) ?? '') + d.partial_json);
          break;
        }
        case 'content_block_stop': {
          const b = blocks[j.index];
          if (b?.type === 'tool_use') {
            const raw = partialJson.get(j.index) ?? '';
            try { b.input = raw ? JSON.parse(raw) : {}; } catch { b.input = { __invalid_json: raw }; }
          }
          break;
        }
        case 'message_delta':
          if (j.delta?.stop_reason) stopReason = j.delta.stop_reason;
          if (j.usage?.output_tokens !== undefined) usage.outputTokens = j.usage.output_tokens;
          onEvent({ type: 'usage', ...usage });
          break;
        case 'error':
          streamError = new ZinoError(j.error?.type === 'overloaded_error' ? 'PROVIDER_UNAVAILABLE' : 'PROVIDER_REJECTED',
            `${p.name}: ${j.error?.message ?? 'stream error'}`);
          break;
      }
    });
    if (streamError) throw streamError;
    if (stopReason === 'refusal') {
      throw new ZinoError('PROVIDER_REFUSED', `${p.name} declined to answer this request.`, { recovery: [] });
    }

    const finalBlocks = blocks.filter(Boolean);
    const text = finalBlocks.filter((b) => b.type === 'text').map((b) => b.text).join('');
    const reasoning = finalBlocks.filter((b) => b.type === 'thinking').map((b) => b.thinking).join('\n');
    const toolCalls = finalBlocks.filter((b) => b.type === 'tool_use').map((b) => ({ id: b.id, name: b.name, arguments: b.input ?? {} }));
    toolCalls.forEach((call) => onEvent({ type: 'tool_call', call }));
    return { text, reasoning, toolCalls, usage, stopReason, raw: { kind: 'anthropic', content: finalBlocks } };
  },
};
