// Google Gemini API adapter (generativelanguage.googleapis.com, v1beta).
import type { Capability, Provider, ProviderModel } from '@/types';
import { ZinoError } from '@/services/errors';
import { authFor, trimSlash, type ChatAdapter, type ChatRequest, type ChatResult, type ConnectionTestResult, type ProviderAdapter, type ProviderMessage, type StreamEvent } from '../types';
import { requestJson, streamSSE } from '../http';

interface GeminiModel {
  name: string;
  displayName?: string;
  inputTokenLimit?: number;
  outputTokenLimit?: number;
  supportedGenerationMethods?: string[];
  thinking?: boolean;
}

export function geminiCapabilities(m: GeminiModel): Capability[] {
  const id = m.name.replace(/^models\//, '').toLowerCase();
  const methods = m.supportedGenerationMethods ?? [];
  const caps: Capability[] = [];
  if (/veo/.test(id) && methods.includes('predictLongRunning')) caps.push('video_generation');
  if (/imagen/.test(id) && methods.includes('predict')) caps.push('image_generation');
  if (methods.includes('generateContent')) {
    if (/image/.test(id)) caps.push('image_generation', 'image_editing');
    else if (!/(embedding|aqa|tts|audio|live|robotics|computer-use)/.test(id)) {
      caps.push('chat', 'tool_calling', 'vision');
      if (m.thinking || /gemini-(2\.5|[3-9])/.test(id)) caps.push('reasoning');
    }
  }
  return caps;
}

/** Gemini function declarations accept an OpenAPI subset; drop keywords it rejects. */
function sanitizeSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(sanitizeSchema);
  if (!schema || typeof schema !== 'object') return schema;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(schema)) {
    if (k === 'additionalProperties' || k === '$schema') continue;
    out[k] = sanitizeSchema(v);
  }
  return out;
}

function toGemini(messages: ProviderMessage[]) {
  const system = messages.filter((m) => m.role === 'system').map((m) => m.content).join('\n\n');
  const contents: { role: 'user' | 'model'; parts: any[] }[] = [];
  const push = (role: 'user' | 'model', parts: any[]) => {
    const last = contents[contents.length - 1];
    if (last && last.role === role) last.parts.push(...parts);
    else contents.push({ role, parts });
  };
  for (const m of messages) {
    if (m.role === 'system') continue;
    if (m.role === 'tool') {
      let response: unknown;
      try { response = JSON.parse(m.content); } catch { response = { result: m.content }; }
      if (typeof response !== 'object' || response === null || Array.isArray(response)) response = { result: response };
      push('user', [{ functionResponse: { name: m.toolName ?? 'tool', response } }]);
    } else if (m.role === 'assistant') {
      if (m.raw?.kind === 'gemini' && Array.isArray(m.raw.content)) push('model', m.raw.content as any[]);
      else {
        const parts: any[] = [];
        if (m.content) parts.push({ text: m.content });
        for (const c of m.toolCalls ?? []) parts.push({ functionCall: { name: c.name, args: c.arguments } });
        if (parts.length) push('model', parts);
      }
    } else {
      const parts: any[] = (m.images ?? []).map((i) => ({ inlineData: { mimeType: i.mime, data: i.base64 } }));
      parts.push({ text: m.content || ' ' });
      push('user', parts);
    }
  }
  return { system, contents };
}

export const geminiAdapter: ChatAdapter & ProviderAdapter = {
  async testConnection(p: Provider): Promise<ConnectionTestResult> {
    const models = await this.listModels(p);
    return { ok: true, message: `Connected. ${models.length} Gemini models available.`, modelCount: models.length };
  },

  async listModels(p: Provider): Promise<ProviderModel[]> {
    const all: GeminiModel[] = [];
    let token: string | undefined;
    for (let page = 0; page < 10; page++) {
      const url = `${trimSlash(p.baseUrl)}/models?pageSize=1000${token ? `&pageToken=${encodeURIComponent(token)}` : ''}`;
      const res = await requestJson<{ models?: GeminiModel[]; nextPageToken?: string }>({ url, auth: authFor(p), provider: p.name });
      all.push(...(res.models ?? []));
      if (!res.nextPageToken) break;
      token = res.nextPageToken;
    }
    const now = Date.now();
    return all
      .map((m) => ({
        id: `${p.id}:${m.name.replace(/^models\//, '')}`, providerId: p.id, modelId: m.name.replace(/^models\//, ''),
        displayName: m.displayName ?? m.name, capabilities: geminiCapabilities(m), contextLength: m.inputTokenLimit ?? null,
        outputLimit: m.outputTokenLimit ?? null, metadata: { methods: m.supportedGenerationMethods ?? [], thinking: !!m.thinking }, fetchedAt: now,
      }))
      .filter((m) => m.capabilities.length > 0);
  },

  async chat(p: Provider, req: ChatRequest, onEvent: (e: StreamEvent) => void): Promise<ChatResult> {
    const { system, contents } = toGemini(req.messages);
    const generationConfig: Record<string, unknown> = { maxOutputTokens: req.effort.maxOutputTokens };
    if (req.effort.temperature !== undefined) generationConfig.temperature = req.effort.temperature;
    const th = req.effort.geminiThinking;
    if (th && 'budget' in th) generationConfig.thinkingConfig = { thinkingBudget: th.budget, includeThoughts: th.budget !== 0 };
    else if (th && 'level' in th) generationConfig.thinkingConfig = { thinkingLevel: th.level, includeThoughts: true };
    const body: Record<string, unknown> = { contents, generationConfig };
    if (system) body.systemInstruction = { parts: [{ text: system }] };
    if (req.tools?.length) {
      body.tools = [{ functionDeclarations: req.tools.map((t) => ({ name: t.name, description: t.description, parameters: sanitizeSchema(t.parameters) })) }];
    }

    let text = '';
    let reasoning = '';
    let stopReason = 'STOP';
    const usage: ChatResult['usage'] = {};
    const modelParts: any[] = [];
    const toolCalls: ChatResult['toolCalls'] = [];
    let blocked: string | null = null;

    await streamSSE({ url: `${trimSlash(p.baseUrl)}/models/${encodeURIComponent(req.model)}:streamGenerateContent?alt=sse`, json: body, auth: authFor(p), signal: req.signal, provider: p.name, timeoutSeconds: 1800 }, (data) => {
      let j: any;
      try { j = JSON.parse(data); } catch { return; }
      if (j.error) { blocked = j.error.message ?? 'stream error'; return; }
      if (j.promptFeedback?.blockReason) blocked = `Prompt blocked (${j.promptFeedback.blockReason}).`;
      if (j.usageMetadata) {
        usage.inputTokens = j.usageMetadata.promptTokenCount;
        usage.outputTokens = (j.usageMetadata.candidatesTokenCount ?? 0) + (j.usageMetadata.thoughtsTokenCount ?? 0);
        onEvent({ type: 'usage', ...usage });
      }
      const cand = j.candidates?.[0];
      if (!cand) return;
      if (cand.finishReason) stopReason = cand.finishReason;
      for (const part of cand.content?.parts ?? []) {
        modelParts.push(part);
        if (part.functionCall) {
          const call = { id: `call_${toolCalls.length}_${Date.now().toString(36)}`, name: part.functionCall.name, arguments: part.functionCall.args ?? {} };
          toolCalls.push(call);
          onEvent({ type: 'tool_call', call });
        } else if (typeof part.text === 'string') {
          if (part.thought) { reasoning += part.text; onEvent({ type: 'reasoning', text: part.text }); }
          else { text += part.text; onEvent({ type: 'text', text: part.text }); }
        }
      }
    });
    if (blocked) throw new ZinoError('PROVIDER_REJECTED', `${p.name}: ${blocked}`);
    if (stopReason === 'SAFETY' && !text) throw new ZinoError('PROVIDER_REFUSED', `${p.name} blocked the response for safety reasons.`, { recovery: [] });
    // Merge consecutive text parts to keep the replayed history compact (signatures preserved).
    return { text, reasoning, toolCalls, usage, stopReason, raw: { kind: 'gemini', content: modelParts } };
  },
};
