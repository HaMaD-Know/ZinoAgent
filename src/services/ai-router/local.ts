// Offline chat through llama.cpp, including an experimental prompt-based tool-calling protocol
// for local models (GGUF models have no standard function-calling API).
import { ZinoLlama } from '@/native';
import { ZinoError, toZinoError } from '@/services/errors';
import { uid } from '@/database/repositories';
import type { ChatResult, ProviderMessage, StreamEvent, ToolDefinition } from '@/providers/types';
import { markUsed } from '@/services/resources';

export const TOOL_OPEN = '<tool_call>';
export const TOOL_CLOSE = '</tool_call>';

export function localToolInstructions(tools: ToolDefinition[]): string {
  return [
    '## Tools',
    'You can use these tools. To call one, reply with ONLY this on its own line and then stop:',
    `${TOOL_OPEN}{"name": "tool_name", "arguments": {...}}${TOOL_CLOSE}`,
    'After a tool result is returned, continue. Never invent tool results.',
    ...tools.map((t) => `- ${t.name}: ${t.description} Parameters: ${JSON.stringify((t.parameters as { properties?: unknown }).properties ?? {})}`),
  ].join('\n');
}

/** Generic ChatML fallback when the GGUF has no template llama.cpp understands. */
export function chatML(messages: { role: string; content: string }[]): string {
  return messages.map((m) => `<|im_start|>${m.role}\n${m.content}<|im_end|>\n`).join('') + '<|im_start|>assistant\n';
}

/** Splits streamed text into visible text and <think>…</think> reasoning. */
export class ThinkSplitter {
  private buf = '';
  private inThink = false;
  constructor(private readonly emit: (kind: 'text' | 'reasoning', s: string) => void) {}
  push(chunk: string) {
    this.buf += chunk;
    for (;;) {
      const tag = this.inThink ? '</think>' : '<think>';
      const i = this.buf.indexOf(tag);
      if (i >= 0) {
        if (i > 0) this.emit(this.inThink ? 'reasoning' : 'text', this.buf.slice(0, i));
        this.buf = this.buf.slice(i + tag.length);
        this.inThink = !this.inThink;
        continue;
      }
      // Hold back the longest suffix that could be the start of the tag.
      let hold = 0;
      for (let k = Math.min(tag.length - 1, this.buf.length); k > 0; k--) {
        if (tag.startsWith(this.buf.slice(-k))) { hold = k; break; }
      }
      const out = this.buf.slice(0, this.buf.length - hold);
      if (out) this.emit(this.inThink ? 'reasoning' : 'text', out);
      this.buf = this.buf.slice(this.buf.length - hold);
      return;
    }
  }
  end() { if (this.buf) this.emit(this.inThink ? 'reasoning' : 'text', this.buf); this.buf = ''; }
}

export function parseLocalToolCall(text: string): { visible: string; call: ChatResult['toolCalls'][number] | null; error?: string } {
  const i = text.indexOf(TOOL_OPEN);
  if (i < 0) return { visible: text, call: null };
  const visible = text.slice(0, i).trim();
  let raw = text.slice(i + TOOL_OPEN.length).replace(TOOL_CLOSE, '').trim();
  raw = raw.replace(/^```(?:json)?/, '').replace(/```$/, '').trim();
  try {
    const j = JSON.parse(raw);
    if (typeof j?.name !== 'string') return { visible, call: null, error: 'Tool call is missing "name".' };
    return { visible, call: { id: `local_${uid().slice(0, 8)}`, name: j.name, arguments: j.arguments ?? {} } };
  } catch {
    return { visible, call: null, error: 'Tool call was not valid JSON.' };
  }
}

export async function localChat(opts: {
  messages: ProviderMessage[];
  tools?: ToolDefinition[];
  maxTokens: number;
  sampling: { temperature: number; topP: number; topK: number; minP: number; repeatPenalty: number };
  signal?: AbortSignal;
  onEvent: (e: StreamEvent) => void;
}): Promise<ChatResult & { promptTokens: number; tokensPerSecond: number; templateFallback: boolean }> {
  const system = opts.messages.filter((m) => m.role === 'system').map((m) => m.content).join('\n\n');
  const sys = opts.tools?.length ? `${system}\n\n${localToolInstructions(opts.tools)}` : system;
  const turns: { role: string; content: string }[] = [{ role: 'system', content: sys }];
  for (const m of opts.messages) {
    if (m.role === 'system') continue;
    if (m.role === 'tool') turns.push({ role: 'user', content: `[Tool result: ${m.toolName ?? 'tool'}]\n${m.content}` });
    else if (m.role === 'assistant') {
      const calls = (m.toolCalls ?? []).map((c) => `${TOOL_OPEN}${JSON.stringify({ name: c.name, arguments: c.arguments })}${TOOL_CLOSE}`).join('\n');
      turns.push({ role: 'assistant', content: [m.content, calls].filter(Boolean).join('\n') });
    } else {
      const imgNote = m.images?.length ? `\n[${m.images.length} image(s) attached — this offline model cannot see images]` : '';
      turns.push({ role: 'user', content: m.content + imgNote });
    }
  }
  // Merge consecutive same-role turns (some templates require strict alternation).
  const merged: typeof turns = [];
  for (const t of turns) {
    const last = merged[merged.length - 1];
    if (last && last.role === t.role && t.role !== 'system') last.content += `\n\n${t.content}`; else merged.push({ ...t });
  }
  const tpl = await ZinoLlama.applyTemplate({ messages: merged, addAssistant: true });
  const templateFallback = !tpl.templateApplied || !tpl.prompt;
  const prompt = templateFallback ? chatML(merged) : tpl.prompt!;
  const stop = [...(opts.tools?.length ? [TOOL_CLOSE] : []), ...(templateFallback ? ['<|im_end|>'] : [])];

  const id = uid();
  let raw = '';
  let text = '';
  let reasoning = '';
  const splitter = new ThinkSplitter((kind, s) => {
    if (kind === 'reasoning') { reasoning += s; opts.onEvent({ type: 'reasoning', text: s }); }
    else {
      text += s;
      // Do not stream the tool-call JSON into the visible message.
      const visibleUpTo = text.indexOf(TOOL_OPEN);
      if (visibleUpTo < 0) opts.onEvent({ type: 'text', text: s });
      else {
        const before = text.length - s.length;
        if (before < visibleUpTo) opts.onEvent({ type: 'text', text: text.slice(before, visibleUpTo) });
      }
    }
  });
  const handle = await ZinoLlama.addListener('token', (e) => { if (e.id === id) { raw += e.text; splitter.push(e.text); } });
  const onAbort = () => { void ZinoLlama.cancel({ id }); };
  opts.signal?.addEventListener('abort', onAbort, { once: true });
  markUsed('llama', true);
  try {
    const r = await ZinoLlama.generate({
      id, prompt, maxTokens: opts.maxTokens, stop,
      temperature: opts.sampling.temperature, topP: opts.sampling.topP, topK: opts.sampling.topK, minP: opts.sampling.minP, repeatPenalty: opts.sampling.repeatPenalty,
    });
    // Token events can trail the resolve slightly; reconcile with the authoritative final text.
    if (r.text.length > raw.length) splitter.push(r.text.slice(raw.length));
    splitter.end();
    if (r.stopReason === 'cancelled' || opts.signal?.aborted) throw new ZinoError('CANCELLED', 'Cancelled.');
    if (r.stopReason === 'context_full') {
      opts.onEvent({ type: 'text', text: '\n\n[Stopped: the context window is full. ZinoAgent will compact earlier messages on your next message.]' });
    }
    const parsed = opts.tools?.length ? parseLocalToolCall(text) : { visible: text, call: null };
    const toolCalls = parsed.call ? [parsed.call] : [];
    toolCalls.forEach((call) => opts.onEvent({ type: 'tool_call', call }));
    opts.onEvent({ type: 'usage', inputTokens: r.promptTokens, outputTokens: r.completionTokens });
    return {
      text: parsed.visible.trim() || (parsed.error ? `${text}\n\n[${parsed.error}]` : text.trim()), reasoning, toolCalls,
      usage: { inputTokens: r.promptTokens, outputTokens: r.completionTokens }, stopReason: r.stopReason,
      promptTokens: r.promptTokens, tokensPerSecond: r.tokensPerSecond, templateFallback,
    };
  } catch (e) {
    throw toZinoError(e, 'INFERENCE_FAILED');
  } finally {
    opts.signal?.removeEventListener('abort', onAbort);
    markUsed('llama', false);
    await handle.remove();
  }
}

/** Plain (non-streaming to UI) local completion, used for summaries and titles. */
export async function localComplete(system: string, user: string, maxTokens: number, signal?: AbortSignal): Promise<string> {
  const r = await localChat({
    messages: [{ role: 'system', content: system }, { role: 'user', content: user }], maxTokens,
    sampling: { temperature: 0.2, topP: 0.9, topK: 40, minP: 0.05, repeatPenalty: 1.05 }, signal, onEvent: () => {},
  });
  return r.text;
}
