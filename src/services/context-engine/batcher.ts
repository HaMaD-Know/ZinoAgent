// Adaptive batching. Five messages is the *reference* size, not a rule: batches grow when
// messages are short and shrink when they are long, important, or memory is tight.

export interface BatchCandidate {
  id: string;
  seq: number;
  role: 'system' | 'user' | 'assistant' | 'tool';
  tokens: number;
  hasToolCalls: boolean;
  important: boolean;
}

export interface BatchPlanOptions {
  /** Usable context budget of the active model (context length minus reserved output). */
  usableTokens: number;
  referenceSize?: number;
  /** When memory is under pressure, prefer smaller batches (smaller summarisation prompts). */
  memoryPressure?: boolean;
}

export interface PlannedBatch { messageIds: string[]; startSeq: number; endSeq: number; tokens: number }

const IMPORTANT = /\b(always|never|must|don't|do not|make sure|remember|from now on|prefer|important|deadline|decid(?:e|ed)|agreed|requirement)\b/i;
export const isImportant = (text: string) => IMPORTANT.test(text);

export function batchTokenTarget(usableTokens: number, memoryPressure = false): number {
  const base = Math.round(usableTokens * (memoryPressure ? 0.08 : 0.12));
  return Math.max(250, Math.min(memoryPressure ? 1500 : 3000, base));
}

/**
 * Group messages (oldest first) into batches. Only complete exchanges are batched: a batch never
 * ends on a user message or on an assistant message whose tool calls have not been answered,
 * unless it has grown far beyond its target. Trailing messages that do not form a closed batch
 * are left for later.
 */
export function planBatches(messages: BatchCandidate[], opts: BatchPlanOptions): PlannedBatch[] {
  const ref = opts.referenceSize ?? 5;
  const target = batchTokenTarget(opts.usableTokens, opts.memoryPressure);
  const hardCap = Math.round(target * 1.6);
  const maxCount = ref * 2;
  const out: PlannedBatch[] = [];
  let cur: BatchCandidate[] = [];
  let tokens = 0;

  const isBoundary = (m: BatchCandidate, next: BatchCandidate | undefined) =>
    (m.role === 'assistant' && !m.hasToolCalls) || (m.role === 'tool' && next?.role !== 'tool' && next?.role !== 'assistant');

  const close = () => {
    out.push({ messageIds: cur.map((m) => m.id), startSeq: cur[0].seq, endSeq: cur[cur.length - 1].seq, tokens });
    cur = [];
    tokens = 0;
  };

  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    cur.push(m);
    tokens += m.tokens;
    const boundary = isBoundary(m, messages[i + 1]);
    const hasImportant = cur.some((x) => x.important);
    const wantClose =
      tokens >= target ||
      (cur.length >= ref && tokens >= target * 0.4) ||
      cur.length >= maxCount ||
      (hasImportant && cur.length >= 2 && tokens >= target * 0.6);
    // The hard cap may end a batch mid-exchange, but never between a tool call and its result.
    const splitsToolCall = m.hasToolCalls || messages[i + 1]?.role === 'tool';
    if ((wantClose && boundary) || (tokens >= hardCap && !splitsToolCall)) close();
  }
  // Leftover messages stay unbatched (they are recent or form an incomplete exchange).
  return out;
}
