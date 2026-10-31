// SmartContextEngine: makes small local context windows useful without losing information.
//
//  * Original messages are never deleted: batches and summaries reference their message ids.
//  * Compaction starts at a configurable fraction (default 85%) of the usable budget.
//  * Summaries are verified (names, numbers, files, instructions, tasks); failed summaries are
//    retried with feedback, then augmented with verbatim original sentences, and otherwise the
//    batch's original messages stay in the active prompt.
//  * Summaries that themselves grow large are rolled up into higher-level summaries.
//  * Relevant original batches are retrieved for questions that need exact earlier details.
//
// Summarisation does NOT extend a model's native context limit; it only decides what fits.
import type { Batch, ChatMessage, MemoryKind, MemoryRecord, ModelRef, Summary, VerificationReport } from '@/types';
import { planBatches, isImportant, type BatchCandidate } from './batcher';
import { sentencesForMissing, stripUnsupportedNumbers, verificationFeedback, verifySummary } from './verifier';
import { bm25, classifyQuery } from './retrieval';
import { MESSAGE_OVERHEAD, type Tokenizer } from './tokenizer';

export interface ContextStore {
  listMessages(chatId: string): Promise<ChatMessage[]>;
  batches(chatId: string): Promise<Batch[]>;
  summaries(chatId: string): Promise<Summary[]>;
  memory(chatId: string): Promise<MemoryRecord[]>;
  saveBatchWithSummary(batch: Batch, summary: Summary | null, memories: MemoryRecord[]): Promise<void>;
  saveRollup(summary: Summary): Promise<void>;
  setTokenCounts(updates: { id: string; count: number; exact: boolean; model: string }[]): Promise<void>;
}

export interface SummarizeInput {
  transcript: string;
  level: number;
  feedback?: string[];
  maxTokens: number;
}

export interface Summarizer {
  readonly modelRef: ModelRef | null;
  summarize(input: SummarizeInput): Promise<string>;
  /** Optional model-based check. Returns notes listing missing/changed facts, or '' when OK. */
  crossCheck?(transcript: string, summary: string): Promise<string>;
}

export interface EngineSettings {
  compactionThreshold: number;
  compactionTarget: number;
  batchReferenceSize: number;
  retrieval: 'smart' | 'recent_only';
  summaryVerification: boolean;
  minRecentMessages: number;
}

export interface PrepareArgs {
  chatId: string;
  systemPrompt: string;
  contextLength: number;
  reservedOutput: number;
  /** The user's latest message text (already stored as a message), used for retrieval. */
  query: string;
  retrievalBatches: number;
  llmVerification: boolean;
  memoryPressure?: boolean;
  /** When false, only report — never summarise (e.g. offline model not loaded). */
  allowCompaction?: boolean;
  onStatus?: (s: string) => void;
}

export interface ContextReport {
  capacity: number;
  reservedOutput: number;
  usable: number;
  systemTokens: number;
  memoryTokens: number;
  summaryTokens: number;
  retrievedTokens: number;
  recentTokens: number;
  toolTokens: number;
  total: number;
  remaining: number;
  percent: number;
  exact: boolean;
  tokenizer: string;
  summaryCount: number;
  summarisedMessageCount: number;
  preservedRawBatches: number;
  retrievedBatchIds: string[];
  queryType: 'simple' | 'complex';
  compaction: { before: number; after: number; batches: number; failedVerification: number } | null;
  warnings: string[];
}

export interface AssembledContext {
  system: string;
  history: ChatMessage[];
  report: ContextReport;
}

const MEMORY_KINDS: MemoryKind[] = ['instruction', 'decision', 'preference', 'project', 'fact', 'task'];

export function renderTranscript(messages: ChatMessage[]): string {
  return messages
    .filter((m) => m.role !== 'system')
    .map((m) => {
      if (m.role === 'tool') return `[Tool result: ${m.toolName ?? 'tool'}] ${m.content.slice(0, 2000)}`;
      const calls = m.toolCalls.length ? ` [called tools: ${m.toolCalls.map((c) => `${c.name}(${JSON.stringify(c.arguments)})`).join(', ')}]` : '';
      return `${m.role === 'user' ? 'User' : 'Assistant'}: ${m.content}${calls}`;
    })
    .join('\n\n');
}

/** Parse the "## Memory" section of a summary into long-term memory items. */
export function parseMemory(summary: string): { kind: MemoryKind; content: string }[] {
  const section = summary.split(/^##\s+Memory\s*$/im)[1];
  if (!section) return [];
  const body = section.split(/^##\s+/m)[0];
  const out: { kind: MemoryKind; content: string }[] = [];
  for (const line of body.split('\n')) {
    const m = line.match(/^\s*[-*]\s*\[(\w+)\]\s*(.+)$/);
    if (!m) continue;
    const kind = m[1].toLowerCase() as MemoryKind;
    if (MEMORY_KINDS.includes(kind) && m[2].trim().length > 3) out.push({ kind, content: m[2].trim() });
  }
  return out;
}

const uid = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`);

export class SmartContextEngine {
  constructor(
    private readonly store: ContextStore,
    private readonly tokenizer: Tokenizer,
    private readonly summarizer: Summarizer | null,
    private readonly settings: EngineSettings,
  ) {}

  /** Ensure every message has a token count for the current tokenizer. */
  private async countMessages(messages: ChatMessage[]): Promise<Map<string, number>> {
    const counts = new Map<string, number>();
    const stale = messages.filter((m) => m.tokenCount === null || m.tokenModel !== this.tokenizer.key);
    if (stale.length) {
      const texts = stale.map((m) => m.content + (m.toolCalls.length ? JSON.stringify(m.toolCalls) : ''));
      const n = await this.tokenizer.count(texts);
      const updates = stale.map((m, i) => ({ id: m.id, count: n[i], exact: this.tokenizer.exact, model: this.tokenizer.key }));
      await this.store.setTokenCounts(updates);
      stale.forEach((m, i) => { m.tokenCount = n[i]; m.tokenModel = this.tokenizer.key; m.tokenExact = this.tokenizer.exact; });
    }
    for (const m of messages) counts.set(m.id, (m.tokenCount ?? 0) + MESSAGE_OVERHEAD);
    return counts;
  }

  private async countText(text: string): Promise<number> {
    if (!text) return 0;
    return (await this.tokenizer.count([text]))[0] + MESSAGE_OVERHEAD;
  }

  private renderSummaries(summaries: Summary[]): string {
    if (!summaries.length) return '';
    return '## Earlier conversation (verified summaries; originals are stored on this device)\n\n' +
      summaries.map((s, i) => `### Part ${i + 1}${s.level > 1 ? ` (combined level ${s.level})` : ''}\n${s.content.replace(/^##\s+Memory[\s\S]*$/im, '').trim()}`).join('\n\n');
  }

  private renderMemory(memory: MemoryRecord[]): string {
    if (!memory.length) return '';
    return '## Long-term memory (instructions, decisions and preferences to keep following)\n' +
      memory.map((m) => `- [${m.kind}] ${m.content}`).join('\n');
  }

  /** Summarise one batch with verification, retries and verbatim preservation. */
  async summarizeBatch(chatId: string, messages: ChatMessage[], llmVerification: boolean, budgetTokens: number, level = 1):
    Promise<{ content: string; report: VerificationReport; usable: boolean }> {
    if (!this.summarizer) throw new Error('No summariser available');
    const transcript = renderTranscript(messages);
    const originals = messages.filter((m) => m.role !== 'system').map((m) => ({ role: m.role, content: m.content }));
    const originalTokens = await this.countText(transcript);
    const maxTokens = Math.max(200, Math.min(budgetTokens, Math.round(originalTokens * 0.6) + 200));
    let feedback: string[] | undefined;
    let content = '';
    let report: VerificationReport | null = null;
    for (let attempt = 1; attempt <= 2; attempt++) {
      content = (await this.summarizer.summarize({ transcript, level, feedback, maxTokens })).trim();
      if (!this.settings.summaryVerification) {
        return { content, report: { passed: true, attempts: attempt, missingNumbers: [], missingNames: [], missingFiles: [], missingInstructions: [], missingTasks: [], unsupportedNumbers: [], coverage: 1 }, usable: true };
      }
      report = verifySummary(originals, content, attempt);
      if (report.passed && llmVerification && this.summarizer.crossCheck) {
        const notes = (await this.summarizer.crossCheck(transcript, content)).trim();
        const ok = !notes || /^ok\b/i.test(notes);
        report.llmCheck = { ran: true, passed: ok, notes: ok ? '' : notes.slice(0, 1000) };
        if (!ok) report.passed = false;
      }
      if (report.passed) return { content, report, usable: true };
      feedback = [...verificationFeedback(report), ...(report.llmCheck && !report.llmCheck.passed ? [`Fix these problems: ${report.llmCheck.notes}`] : [])];
    }
    // Last resort: keep the best summary, drop invented numbers, and append the original sentences verbatim.
    const r = report!;
    let augmented = stripUnsupportedNumbers(content, r.unsupportedNumbers);
    const verbatim = sentencesForMissing(originals, r);
    if (verbatim.length) augmented += `\n\n## Preserved original details (verbatim)\n${verbatim.map((s) => `- ${s}`).join('\n')}`;
    const final = verifySummary(originals, augmented, r.attempts + 1);
    final.llmCheck = r.llmCheck;
    const augmentedTokens = await this.countText(augmented);
    const compresses = augmentedTokens < originalTokens * 0.75;
    // The deterministic checks must pass; an unresolved model cross-check also blocks use.
    const usable = final.passed && compresses && (!r.llmCheck || r.llmCheck.passed || verbatim.length > 0);
    void chatId;
    return { content: augmented, report: final, usable };
  }

  /**
   * Assemble the prompt for the next model call, compacting first if usage crosses the threshold.
   */
  async prepare(args: PrepareArgs): Promise<AssembledContext> {
    const warnings: string[] = [];
    const usable = Math.max(256, args.contextLength - args.reservedOutput);
    const all = await this.store.listMessages(args.chatId);
    const counts = await this.countMessages(all);
    let batches = await this.store.batches(args.chatId);
    let summaries = (await this.store.summaries(args.chatId)).filter((s) => s.verified && !s.supersededBy);
    const memory = await this.store.memory(args.chatId);

    const systemTokens = await this.countText(args.systemPrompt);
    const memoryText = this.renderMemory(memory);
    const memoryTokens = await this.countText(memoryText);

    const summarisedIds = () => new Set(batches.filter((b) => b.status === 'summarised').flatMap((b) => b.messageIds));
    const activeMessages = () => {
      const s = summarisedIds();
      return all.filter((m) => !s.has(m.id) && m.role !== 'system' && m.status !== 'streaming');
    };
    const tokensOf = (ms: ChatMessage[]) => ms.reduce((a, m) => a + (counts.get(m.id) ?? 0), 0);
    const summaryTokens = async () => this.countText(this.renderSummaries(summaries));

    let compaction: ContextReport['compaction'] = null;
    let total = systemTokens + memoryTokens + (await summaryTokens()) + tokensOf(activeMessages());
    const threshold = this.settings.compactionThreshold;

    if (total >= usable * threshold && args.allowCompaction !== false && this.summarizer) {
      const before = total;
      let done = 0;
      let failed = 0;
      args.onStatus?.('Compacting conversation…');
      // Keep the most recent messages verbatim.
      const active = activeMessages();
      const keepFrom = Math.max(0, active.length - this.settings.minRecentMessages);
      const batchedIds = new Set(batches.flatMap((b) => b.messageIds));
      const candidates: BatchCandidate[] = active.slice(0, keepFrom)
        .filter((m) => !batchedIds.has(m.id))
        .map((m) => ({ id: m.id, seq: m.seq, role: m.role, tokens: counts.get(m.id) ?? 0, hasToolCalls: m.toolCalls.length > 0, important: m.role === 'user' && isImportant(m.content) }));
      const plans = planBatches(candidates, { usableTokens: usable, referenceSize: this.settings.batchReferenceSize, memoryPressure: args.memoryPressure });
      const byId = new Map(all.map((m) => [m.id, m]));
      for (const plan of plans) {
        if (total <= usable * this.settings.compactionTarget) break;
        const msgs = plan.messageIds.map((id) => byId.get(id)!).filter(Boolean);
        args.onStatus?.(`Summarising messages ${plan.startSeq}–${plan.endSeq}…`);
        const batch: Batch = { id: uid(), chatId: args.chatId, startSeq: plan.startSeq, endSeq: plan.endSeq, messageIds: plan.messageIds,
          tokenCount: plan.tokens, status: 'open', createdAt: Date.now() };
        let result: Awaited<ReturnType<SmartContextEngine['summarizeBatch']>>;
        try {
          result = await this.summarizeBatch(args.chatId, msgs, args.llmVerification, Math.round(usable * 0.25));
        } catch (e) {
          warnings.push(`Summarisation failed: ${(e as Error).message}. Original messages were kept.`);
          break;
        }
        const summary: Summary = {
          id: uid(), chatId: args.chatId, batchId: batch.id, level: 1, parentSummaryIds: [], sourceMessageIds: plan.messageIds,
          sourceBatchIds: [batch.id], content: result.content, tokenCount: await this.countText(result.content),
          verification: result.report, verified: result.usable, modelRef: this.summarizer.modelRef, createdAt: Date.now(), supersededBy: null,
        };
        batch.status = result.usable ? 'summarised' : 'preserved_raw';
        const memories: MemoryRecord[] = result.usable
          ? parseMemory(result.content).map((m) => ({ id: uid(), chatId: args.chatId, kind: m.kind, content: m.content, sourceMessageIds: plan.messageIds,
            pinned: false, active: true, createdAt: Date.now(), updatedAt: Date.now() }))
          : [];
        await this.store.saveBatchWithSummary(batch, summary, memories);
        batches = [...batches, batch];
        if (result.usable) { summaries = [...summaries, summary]; done++; } else {
          failed++;
          warnings.push(`A summary of messages ${plan.startSeq}–${plan.endSeq} did not pass verification, so the original messages stay in context.`);
        }
        memory.push(...memories);
        total = systemTokens + (await this.countText(this.renderMemory(memory))) + (await summaryTokens()) + tokensOf(activeMessages());
      }

      // Multi-level memory: roll up when summaries alone take more than ~30% of the budget.
      if ((await summaryTokens()) > usable * 0.3 && summaries.length >= 3) {
        const rolled = await this.rollUp(args.chatId, summaries.slice(0, Math.min(4, summaries.length - 1)), args.llmVerification, usable);
        if (rolled) {
          summaries = [rolled, ...summaries.filter((s) => !rolled.parentSummaryIds.includes(s.id))];
          total = systemTokens + (await this.countText(this.renderMemory(memory))) + (await summaryTokens()) + tokensOf(activeMessages());
        }
      }
      compaction = { before, after: total, batches: done, failedVerification: failed };
      if (plans.length === 0) warnings.push('Context is high but the remaining messages are too recent to summarise.');
    }

    // Smart retrieval of original messages for questions that need exact earlier details.
    const retrievalCap = this.settings.retrieval === 'smart' ? args.retrievalBatches : 0;
    const queryType = classifyQuery(args.query, retrievalCap);
    let retrievedBatchIds: string[] = [];
    let retrievedText = '';
    if (queryType === 'complex') {
      const summarised = batches.filter((b) => b.status === 'summarised');
      const byId = new Map(all.map((m) => [m.id, m]));
      const docs = summarised.map((b) => ({ id: b.id, text: renderTranscript(b.messageIds.map((id) => byId.get(id)!).filter(Boolean)) }));
      const scored = bm25(args.query, docs).filter((s) => s.score > 0).sort((a, b) => b.score - a.score).slice(0, retrievalCap);
      const budget = Math.round(usable * 0.25);
      const free = usable - total;
      let used = 0;
      const parts: string[] = [];
      for (const s of scored) {
        const doc = docs.find((d) => d.id === s.id)!;
        const t = await this.countText(doc.text);
        if (used + t > Math.min(budget, free - 64)) continue;
        used += t;
        parts.push(doc.text);
        retrievedBatchIds.push(s.id);
      }
      if (parts.length) retrievedText = `## Retrieved original messages from earlier in this conversation\n\n${parts.join('\n\n---\n\n')}`;
      if (!parts.length && scored.length) warnings.push('Relevant earlier messages were found but did not fit in the remaining context.');
    }
    const retrievedTokens = await this.countText(retrievedText);

    // Final assembly. If still over budget, drop oldest active messages from the *prompt only*.
    let history = activeMessages();
    let recentTokens = tokensOf(history);
    const summaryText = this.renderSummaries(summaries);
    const sTokens = await this.countText(summaryText);
    const fixed = systemTokens + memoryTokens + sTokens + retrievedTokens;
    if (fixed + recentTokens > usable) {
      const pruned: ChatMessage[] = [...history];
      while (pruned.length > 1 && fixed + tokensOf(pruned) > usable) pruned.shift();
      // Never start the history with a tool result whose call was pruned.
      while (pruned.length > 1 && pruned[0].role === 'tool') pruned.shift();
      const dropped = history.length - pruned.length;
      if (dropped > 0) warnings.push(`${dropped} older message(s) did not fit and were left out of this request (they remain saved).`);
      history = pruned;
      recentTokens = tokensOf(history);
    }
    const toolTokens = tokensOf(history.filter((m) => m.role === 'tool'));
    const system = [args.systemPrompt, memoryText, summaryText, retrievedText].filter(Boolean).join('\n\n');
    const totalFinal = fixed + recentTokens;
    const report: ContextReport = {
      capacity: args.contextLength, reservedOutput: args.reservedOutput, usable,
      systemTokens, memoryTokens, summaryTokens: sTokens, retrievedTokens, recentTokens: recentTokens - toolTokens, toolTokens,
      total: totalFinal, remaining: Math.max(0, usable - totalFinal), percent: Math.min(1, totalFinal / usable),
      exact: this.tokenizer.exact, tokenizer: this.tokenizer.key, summaryCount: summaries.length,
      summarisedMessageCount: summarisedIds().size, preservedRawBatches: batches.filter((b) => b.status === 'preserved_raw').length,
      retrievedBatchIds, queryType, compaction, warnings,
    };
    return { system, history, report };
  }

  private async rollUp(chatId: string, children: Summary[], llmVerification: boolean, usable: number): Promise<Summary | null> {
    if (!this.summarizer || children.length < 2) return null;
    const transcript = children.map((s, i) => `Summary part ${i + 1}:\n${s.content}`).join('\n\n');
    const pseudo: ChatMessage[] = [{ id: 'rollup', chatId, seq: 0, role: 'assistant', content: transcript, reasoning: null, createdAt: 0, tokenCount: null,
      tokenExact: false, tokenModel: null, batchId: null, status: 'complete', modelRef: null, attachments: [], toolCalls: [], toolCallId: null, toolName: null, meta: {} }];
    const r = await this.summarizeBatch(chatId, pseudo, llmVerification, Math.round(usable * 0.2), Math.max(...children.map((c) => c.level)) + 1);
    if (!r.usable) return null;
    const summary: Summary = {
      id: uid(), chatId, batchId: null, level: Math.max(...children.map((c) => c.level)) + 1, parentSummaryIds: children.map((c) => c.id),
      sourceMessageIds: children.flatMap((c) => c.sourceMessageIds), sourceBatchIds: children.flatMap((c) => c.sourceBatchIds),
      content: r.content, tokenCount: await this.countText(r.content), verification: r.report, verified: true,
      modelRef: this.summarizer.modelRef, createdAt: Date.now(), supersededBy: null,
    };
    await this.store.saveRollup(summary);
    return summary;
  }
}

export const SUMMARY_SYSTEM_PROMPT = `You compress part of a conversation into a faithful summary that will replace it in a small context window.
Rules:
- Never change facts. Copy names, numbers, units, file names, paths, URLs and model settings EXACTLY as written.
- Keep every user instruction and preference, every decision, and every unfinished task.
- Do not add anything that is not in the conversation. Do not speculate.
- Be compact: bullet points, no filler.
Output exactly these sections (omit a section only if empty):
## Summary
## Facts and numbers
## User instructions and preferences
## Decisions
## Open tasks
## Files, names and references
## Memory
Under "## Memory" list durable items as "- [instruction] ...", "- [decision] ...", "- [preference] ...", "- [project] ...", "- [task] ..." or "- [fact] ...".`;

export const CROSSCHECK_PROMPT = `Compare the SUMMARY with the ORIGINAL conversation. List every fact, name, number, decision, user instruction or unfinished task that is missing from or changed in the summary, one per line. If nothing is missing or changed, reply with exactly: OK`;
