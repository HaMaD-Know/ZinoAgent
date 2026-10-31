// Lexical (BM25) retrieval over summarised batches. Runs fully offline; no embeddings needed.

const STOP = new Set('the a an and or but of to in on at by for with from is are was were be this that it you i we they what how why when where which who do does did can could would should will about please me my your our'.split(' '));
export const terms = (s: string) => (s.toLowerCase().match(/[a-z0-9][a-z0-9._-]*/g) ?? []).filter((t) => t.length > 1 && !STOP.has(t));

export interface RetrievalDoc { id: string; text: string }

export function bm25(query: string, docs: RetrievalDoc[], k1 = 1.4, b = 0.75): { id: string; score: number }[] {
  const q = [...new Set(terms(query))];
  if (!q.length || !docs.length) return docs.map((d) => ({ id: d.id, score: 0 }));
  const tokenized = docs.map((d) => terms(d.text));
  const avg = tokenized.reduce((a, t) => a + t.length, 0) / tokenized.length || 1;
  const df = new Map<string, number>();
  for (const t of tokenized) for (const term of new Set(t)) df.set(term, (df.get(term) ?? 0) + 1);
  return docs.map((d, i) => {
    const tf = new Map<string, number>();
    for (const t of tokenized[i]) tf.set(t, (tf.get(t) ?? 0) + 1);
    let score = 0;
    for (const term of q) {
      const f = tf.get(term) ?? 0;
      if (!f) continue;
      const n = df.get(term) ?? 0;
      const idf = Math.log(1 + (docs.length - n + 0.5) / (n + 0.5));
      score += idf * ((f * (k1 + 1)) / (f + k1 * (1 - b + (b * tokenized[i].length) / avg)));
    }
    return { id: d.id, score };
  });
}

const BACKREF = /\b(earlier|before|previous(ly)?|you said|i said|we (discussed|talked|decided|agreed)|remind me|recap|exact(ly)?|quote|verbatim|originally|at the (start|beginning)|what was|what were|which (one|file)|last time)\b/i;

/** Simple questions use summaries + recent messages; complex ones also pull original batches. */
export function classifyQuery(query: string, effortRetrieval: number): 'simple' | 'complex' {
  if (effortRetrieval <= 0) return 'simple';
  if (BACKREF.test(query)) return 'complex';
  if (/\d{2,}|[\w-]+\.\w{2,4}\b/.test(query) && terms(query).length >= 3) return 'complex';
  return effortRetrieval >= 4 && terms(query).length >= 6 ? 'complex' : 'simple';
}
