import { beforeEach, describe, expect, it, vi } from 'vitest';

// Mock native HTTP: records the request and streams a scripted SSE body in random-sized chunks.
let script = '';
let lastRequest: { url: string; body?: string; headers?: Record<string, string>; auth?: unknown } | null = null;
const listeners: ((e: { id: string; chunk: string }) => void)[] = [];
vi.mock('@/native', () => ({
  isNative: () => false,
  ZinoHttp: {
    addListener: async (_: string, fn: (e: { id: string; chunk: string }) => void) => { listeners.push(fn); return { remove: async () => { listeners.splice(listeners.indexOf(fn), 1); } }; },
    request: async (o: { id: string; url: string; body?: string; stream?: boolean; headers?: Record<string, string>; auth?: unknown }) => {
      lastRequest = o;
      if (o.stream) {
        let i = 0;
        while (i < script.length) { const n = 1 + Math.floor(Math.random() * 40); const c = script.slice(i, i + n); i += n; listeners.forEach((l) => l({ id: o.id, chunk: c })); }
        return { status: 200, headers: {}, streamed: true };
      }
      return { status: 200, headers: {}, body: '{}' };
    },
    cancel: async () => ({ cancelled: true }),
  },
}));

import { SSEParser, httpError } from '@/providers/http';
import { openaiAdapter } from '@/providers/chat/openai';
import { anthropicAdapter, anthropicThinkingMode } from '@/providers/chat/anthropic';
import { geminiAdapter, geminiCapabilities } from '@/providers/chat/gemini';
import { planEffort, classifyComplexity } from '@/services/ai-router/effort';
import { ThinkSplitter, parseLocalToolCall, chatML } from '@/services/ai-router/local';
import { assessGGUF, quantLabel } from '@/models/chat/gguf';
import type { Provider } from '@/types';
import type { StreamEvent } from '@/providers/types';

const provider = (kind: Provider['kind'], baseUrl: string): Provider => ({
  id: 'p1', category: 'chat', kind, name: kind, baseUrl, keyAccount: 'acct', keyMasked: '••••1234', status: 'ok', lastTestedAt: null,
  lastError: null, capabilities: [], defaultModel: null, options: {}, createdAt: 0,
});
const sse = (events: unknown[], named = false) => events.map((e) => (named ? `event: ${(e as { type: string }).type}\n` : '') + `data: ${JSON.stringify(e)}\n\n`).join('');

describe('SSE parsing', () => {
  it('handles multi-line data, comments, CRLF and arbitrary chunk boundaries', () => {
    const got: string[] = [];
    const p = new SSEParser((d) => got.push(d));
    const raw = ': keepalive\r\ndata: {"a":1}\r\n\r\ndata: line1\ndata: line2\n\n';
    for (const ch of raw) p.push(ch);
    p.end();
    expect(got).toEqual(['{"a":1}', 'line1\nline2']);
  });
  it('maps HTTP errors to useful codes without leaking keys', () => {
    expect(httpError(401, '{"error":{"message":"bad key sk-abcdefghijklmnop1234"}}', 'OpenAI').message).not.toContain('sk-abcdefghijklmnop1234');
    expect(httpError(429, '{}', 'X', { 'retry-after': '20' }).message).toMatch(/retry after 20s/);
    expect(httpError(503, '', 'X').code).toBe('PROVIDER_UNAVAILABLE');
  });
});

describe('chat adapters', () => {
  beforeEach(() => { lastRequest = null; });

  it('OpenAI: streams text, assembles tool-call fragments, sends reasoning_effort only to reasoning models', async () => {
    script = sse([
      { choices: [{ delta: { content: 'Looking ' } }] },
      { choices: [{ delta: { content: 'now.' } }] },
      { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', function: { name: 'search_', arguments: '{"kind":' } }] } }] },
      { choices: [{ delta: { tool_calls: [{ index: 0, function: { name: 'files', arguments: '"model3d"}' } }] }, finish_reason: 'tool_calls' }] },
      { choices: [], usage: { prompt_tokens: 10, completion_tokens: 5 } },
    ]) + 'data: [DONE]\n\n';
    const events: StreamEvent[] = [];
    const r = await openaiAdapter.chat(provider('openai', 'https://api.openai.com/v1'), {
      model: 'gpt-5-mini', messages: [{ role: 'user', content: 'find glb' }], tools: [{ name: 'search_files', description: '', parameters: { type: 'object' } }],
      effort: { maxOutputTokens: 1000, openaiReasoningEffort: 'low', temperature: 0.7 },
    }, (e) => events.push(e));
    expect(r.text).toBe('Looking now.');
    expect(r.toolCalls).toEqual([{ id: 'call_1', name: 'search_files', arguments: { kind: 'model3d' } }]);
    expect(r.usage).toEqual({ inputTokens: 10, outputTokens: 5 });
    const body = JSON.parse(lastRequest!.body!);
    expect(body.reasoning_effort).toBe('low');
    expect(body.temperature).toBeUndefined(); // reasoning models reject temperature
    expect(body.max_completion_tokens).toBe(1000);
    expect(lastRequest!.auth).toEqual({ account: 'acct', name: 'Authorization', prefix: 'Bearer ' });
  });

  it('Anthropic: adaptive thinking + effort, thinking/text/tool_use blocks, raw blocks preserved for replay', async () => {
    script = sse([
      { type: 'message_start', message: { usage: { input_tokens: 30 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'Need files.' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'signature_delta', signature: 'sig123' } },
      { type: 'content_block_stop', index: 0 },
      { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '' } },
      { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: 'Checking.' } },
      { type: 'content_block_stop', index: 1 },
      { type: 'content_block_start', index: 2, content_block: { type: 'tool_use', id: 'tu_1', name: 'list_files', input: {} } },
      { type: 'content_block_delta', index: 2, delta: { type: 'input_json_delta', partial_json: '{"path":' } },
      { type: 'content_block_delta', index: 2, delta: { type: 'input_json_delta', partial_json: '"docs"}' } },
      { type: 'content_block_stop', index: 2 },
      { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 22 } },
      { type: 'message_stop' },
    ], true);
    const r = await anthropicAdapter.chat(provider('anthropic', 'https://api.anthropic.com/v1'), {
      model: 'claude-opus-5-5', messages: [{ role: 'system', content: 'sys' }, { role: 'user', content: 'hi' }],
      effort: { maxOutputTokens: 16000, anthropicThinking: { mode: 'adaptive', effort: 'medium' } },
    }, () => {});
    expect(r.reasoning).toBe('Need files.');
    expect(r.text).toBe('Checking.');
    expect(r.toolCalls).toEqual([{ id: 'tu_1', name: 'list_files', arguments: { path: 'docs' } }]);
    expect((r.raw!.content as { signature?: string }[])[0].signature).toBe('sig123');
    const body = JSON.parse(lastRequest!.body!);
    expect(body.thinking).toEqual({ type: 'adaptive', display: 'summarized' });
    expect(body.output_config).toEqual({ effort: 'medium' });
    expect(body.system).toBe('sys');
    expect(body.temperature).toBeUndefined();
    expect(lastRequest!.headers!['anthropic-version']).toBe('2023-06-01');
  });

  it('Anthropic: refusals surface as errors, not empty answers', async () => {
    script = sse([{ type: 'message_start', message: { usage: { input_tokens: 1 } } }, { type: 'message_delta', delta: { stop_reason: 'refusal' } }], true);
    await expect(anthropicAdapter.chat(provider('anthropic', 'https://api.anthropic.com/v1'), { model: 'claude-opus-5-5', messages: [{ role: 'user', content: 'x' }], effort: { maxOutputTokens: 100 } }, () => {}))
      .rejects.toThrow(/declined/);
  });

  it('Gemini: thought parts become reasoning, function calls become tool calls, thinking config is sent', async () => {
    script = sse([
      { candidates: [{ content: { parts: [{ text: 'Plan', thought: true }] } }] },
      { candidates: [{ content: { parts: [{ text: 'Answer' }] } }] },
      { candidates: [{ content: { parts: [{ functionCall: { name: 'storage_report', args: {} }, thoughtSignature: 'ts1' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 5, candidatesTokenCount: 3, thoughtsTokenCount: 2 } },
    ]);
    const r = await geminiAdapter.chat(provider('gemini', 'https://generativelanguage.googleapis.com/v1beta'), {
      model: 'gemini-2.5-flash', messages: [{ role: 'user', content: 'hi' }], tools: [{ name: 'storage_report', description: 'd', parameters: { type: 'object', additionalProperties: false } }],
      effort: { maxOutputTokens: 500, geminiThinking: { budget: 1024 } },
    }, () => {});
    expect(r.reasoning).toBe('Plan');
    expect(r.text).toBe('Answer');
    expect(r.toolCalls[0].name).toBe('storage_report');
    expect(r.usage).toEqual({ inputTokens: 5, outputTokens: 5 });
    expect((r.raw!.content as { thoughtSignature?: string }[]).some((p) => p.thoughtSignature === 'ts1')).toBe(true);
    const body = JSON.parse(lastRequest!.body!);
    expect(body.generationConfig.thinkingConfig).toEqual({ thinkingBudget: 1024, includeThoughts: true });
    expect(body.tools[0].functionDeclarations[0].parameters.additionalProperties).toBeUndefined();
    expect(lastRequest!.url).toContain(':streamGenerateContent?alt=sse');
  });

  it('Gemini capability detection distinguishes chat, image, and video models', () => {
    expect(geminiCapabilities({ name: 'models/gemini-2.5-flash', supportedGenerationMethods: ['generateContent'] })).toContain('chat');
    expect(geminiCapabilities({ name: 'models/gemini-2.5-flash-image', supportedGenerationMethods: ['generateContent'] })).toEqual(['image_generation', 'image_editing']);
    expect(geminiCapabilities({ name: 'models/veo-3.0-generate-001', supportedGenerationMethods: ['predictLongRunning'] })).toEqual(['video_generation']);
    expect(geminiCapabilities({ name: 'models/text-embedding-004', supportedGenerationMethods: ['embedContent'] })).toEqual([]);
  });
});

describe('effort mapping', () => {
  it('never claims unsupported controls', () => {
    const p = planEffort({ requested: 'high', prompt: '', engine: 'openai', modelId: 'gpt-4o' });
    expect(p.params.openaiReasoningEffort).toBeUndefined();
    expect(p.notApplied.join(' ')).toMatch(/does not support reasoning effort/);
  });
  it('maps Claude to adaptive effort on new models and budgets on older ones', () => {
    expect(planEffort({ requested: 'maximum', prompt: '', engine: 'anthropic', modelId: 'claude-opus-5-5' }).params.anthropicThinking).toEqual({ mode: 'adaptive', effort: 'max' });
    expect(planEffort({ requested: 'minimal', prompt: '', engine: 'anthropic', modelId: 'claude-opus-5-5' }).params.anthropicThinking).toEqual({ mode: 'adaptive', effort: 'low' });
    const old = planEffort({ requested: 'medium', prompt: '', engine: 'anthropic', modelId: 'claude-haiku-4-5' });
    expect(old.params.anthropicThinking).toEqual({ mode: 'budget', budgetTokens: 4096 });
    expect(old.params.maxOutputTokens).toBeGreaterThan(4096);
    // Models API capabilities take precedence over name heuristics.
    const info = { id: 'x', providerId: 'p', modelId: 'claude-x', displayName: 'x', capabilities: [], contextLength: null, outputLimit: 64000, fetchedAt: 0,
      metadata: { capabilities: { thinking: { supported: true, types: { adaptive: { supported: true } } }, effort: { low: { supported: true }, medium: { supported: true }, high: { supported: true }, xhigh: { supported: false }, max: { supported: false } } } } };
    expect(anthropicThinkingMode(info, 'claude-x')).toBe('adaptive');
    expect(planEffort({ requested: 'maximum', prompt: '', engine: 'anthropic', modelId: 'claude-x', modelInfo: info, outputLimit: 64000 }).params.anthropicThinking).toEqual({ mode: 'adaptive', effort: 'high' });
  });
  it('maps Gemini 2.5 to budgets and Gemini 3 to levels', () => {
    expect(planEffort({ requested: 'minimal', prompt: '', engine: 'gemini', modelId: 'gemini-2.5-pro' }).params.geminiThinking).toEqual({ budget: 128 });
    expect(planEffort({ requested: 'minimal', prompt: '', engine: 'gemini', modelId: 'gemini-2.5-flash' }).params.geminiThinking).toEqual({ budget: 0 });
    expect(planEffort({ requested: 'high', prompt: '', engine: 'gemini', modelId: 'gemini-3-pro-preview' }).params.geminiThinking).toEqual({ level: 'high' });
  });
  it('local effort changes output budget, sampling and retrieval depth', () => {
    const lo = planEffort({ requested: 'minimal', prompt: '', engine: 'local', modelId: 'm', contextLength: 4096 });
    const hi = planEffort({ requested: 'maximum', prompt: '', engine: 'local', modelId: 'm', contextLength: 8192 });
    expect(lo.params.maxOutputTokens).toBeLessThan(hi.params.maxOutputTokens);
    expect(lo.context.retrievalBatches).toBe(0);
    expect(hi.context.llmVerification).toBe(true);
    expect(hi.params.maxOutputTokens).toBeLessThanOrEqual(Math.floor(8192 * 0.35));
  });
  it('Auto effort classifies complexity', () => {
    expect(classifyComplexity('hi').level).toBe('low');
    expect(classifyComplexity('Analyze the trade-offs and design a step by step plan for migrating this architecture, then debug ```code```').level).toBe('high');
  });
});

describe('local model helpers', () => {
  it('splits <think> blocks across arbitrary chunk boundaries', () => {
    let text = ''; let reasoning = '';
    const s = new ThinkSplitter((k, x) => { if (k === 'text') text += x; else reasoning += x; });
    for (const ch of 'Hi <think>step 1, <step 2></think>Answer <thin') s.push(ch);
    s.end();
    expect(reasoning).toBe('step 1, <step 2>');
    expect(text).toBe('Hi Answer <thin');
  });
  it('parses the local tool-call protocol and tolerates code fences', () => {
    expect(parseLocalToolCall('Sure.\n<tool_call>```json\n{"name":"list_files","arguments":{"path":"a"}}\n```')).toMatchObject({ visible: 'Sure.', call: { name: 'list_files', arguments: { path: 'a' } } });
    expect(parseLocalToolCall('<tool_call>{oops').error).toMatch(/JSON/);
    expect(chatML([{ role: 'user', content: 'x' }])).toBe('<|im_start|>user\nx<|im_end|>\n<|im_start|>assistant\n');
  });
});

describe('GGUF compatibility', () => {
  const base = { architecture: 'llama', version: 3, tensorCount: 290, hasChatTemplate: true, isSplit: false, blockCount: 28, embeddingLength: 3072, headCount: 24, headCountKv: 8, contextLength: 131072, fileType: 15 };
  const GB = 1024 ** 3;
  it('rates a 3B Q4_K_M as compatible on a 5 GB budget', () => {
    const r = assessGGUF({ ...base, fileSize: 2.0 * GB }, 'Llama-3.2-3B-Instruct-Q4_K_M.gguf', 5 * GB, 4096);
    expect(r.compatibility).toBe('compatible');
    expect(quantLabel(base)).toBe('Q4_K_M');
  });
  it('flags models that do not fit and suggests a smaller context', () => {
    const r = assessGGUF({ ...base, fileSize: 4.7 * GB, blockCount: 28 }, 'Qwen2.5-7B-Q4_K_M.gguf', 5 * GB, 32768);
    expect(['experimental', 'limited']).toContain(r.compatibility);
    expect(r.recommendedContext).toBeLessThan(32768);
    expect(assessGGUF({ ...base, fileSize: 9 * GB }, 'big.gguf', 5 * GB).compatibility).toBe('unsupported');
  });
  it('rejects unknown and non-chat architectures', () => {
    expect(assessGGUF({ ...base, architecture: 'made-up-arch', fileSize: GB }, 'x.gguf', 5 * GB).compatibility).toBe('unsupported');
    expect(assessGGUF({ ...base, architecture: 'bert', fileSize: GB }, 'x.gguf', 5 * GB).notes[0]).toMatch(/not a text chat model/);
  });
});
