// Token counting. Local GGUF models use llama.cpp's own tokenizer (exact). Cloud models use a
// calibrated estimate, clearly labelled as such in the context dashboard.

export interface Tokenizer {
  /** Stable key: counts are cached per message and recomputed when the key changes. */
  readonly key: string;
  readonly exact: boolean;
  count(texts: string[]): Promise<number[]>;
}

/** Per-message overhead for role markers / chat-template tokens (an estimate even for exact tokenizers). */
export const MESSAGE_OVERHEAD = 4;

/**
 * Heuristic estimate: ~4 chars/token for English prose, denser for code/CJK/numbers.
 * Deliberately errs slightly high so budgets are not exceeded.
 */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  let cjk = 0;
  let other = 0;
  let symbols = 0;
  for (const ch of text) {
    const c = ch.codePointAt(0)!;
    if ((c >= 0x3040 && c <= 0x30ff) || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af)) cjk++;
    else if (/[{}()[\];:=<>/\\|`~^*_#@$%&+-]/.test(ch)) symbols++;
    else other++;
  }
  const words = text.split(/\s+/).filter(Boolean).length;
  const byChars = other / 3.8 + symbols / 1.6 + cjk * 1.1;
  const byWords = words * 1.3 + cjk * 1.1;
  return Math.ceil(Math.max(byChars, byWords));
}

export class EstimateTokenizer implements Tokenizer {
  readonly exact = false;
  constructor(readonly key: string = 'estimate') {}
  async count(texts: string[]) { return texts.map(estimateTokens); }
}

/** Uses the loaded llama.cpp model's tokenizer. Falls back to estimates if the model is unloaded. */
export class LlamaTokenizer implements Tokenizer {
  readonly exact = true;
  constructor(readonly key: string) {}
  async count(texts: string[]) {
    const { ZinoLlama } = await import('@/native');
    const counts: number[] = [];
    // Chunk to keep bridge payloads reasonable.
    for (let i = 0; i < texts.length; i += 64) {
      const r = await ZinoLlama.tokenize({ texts: texts.slice(i, i + 64) });
      counts.push(...r.counts);
    }
    return counts;
  }
}
