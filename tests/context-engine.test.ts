import { beforeEach, describe, expect, it } from 'vitest';
import { freshDb } from './helpers/db';
import { chatsRepo, contextRepo, messagesRepo } from '@/database/repositories';
import {
  SmartContextEngine, EstimateTokenizer, planBatches, verifySummary, extractFacts, repoContextStore, parseMemory, bm25, classifyQuery,
  type Summarizer, type SummarizeInput, type EngineSettings,
} from '@/services/context-engine';
import type { ChatMessage } from '@/types';

const settings: EngineSettings = {
  compactionThreshold: 0.85, compactionTarget: 0.5, batchReferenceSize: 5, retrieval: 'smart', summaryVerification: true, minRecentMessages: 4,
};

async function addMessage(chatId: string, role: ChatMessage['role'], content: string) {
  return messagesRepo.insert({
    chatId, role, content, reasoning: null, tokenCount: null, tokenExact: false, tokenModel: null, batchId: null, status: 'complete',
    modelRef: null, attachments: [], toolCalls: [], toolCallId: null, toolName: null, meta: {},
  });
}

/** Summariser that copies key lines (simulates a faithful model). */
class FaithfulSummarizer implements Summarizer {
  readonly modelRef = null;
  calls: SummarizeInput[] = [];
  async summarize(input: SummarizeInput) {
    this.calls.push(input);
    const lines = input.transcript.split('\n').filter(Boolean).map((l) => `- ${l.replace(/^(User|Assistant): /, '')}`);
    return `## Summary\n${lines.join('\n')}\n## Memory\n- [instruction] Always export models as GLB`;
  }
}

/** Summariser that drops numbers and invents one (simulates a lossy model). */
class LossySummarizer implements Summarizer {
  readonly modelRef = null;
  attempts = 0;
  async summarize() {
    this.attempts++;
    return '## Summary\n- The user talked about a project and some budget of 999 dollars.';
  }
}

describe('adaptive batching', () => {
  const mk = (i: number, role: 'user' | 'assistant', tokens: number) => ({ id: `m${i}`, seq: i, role, tokens, hasToolCalls: false, important: false });

  it('uses ~5 messages as a reference but ends on complete exchanges', () => {
    const msgs = Array.from({ length: 12 }, (_, i) => mk(i + 1, i % 2 === 0 ? 'user' : 'assistant', 60));
    const batches = planBatches(msgs, { usableTokens: 4000 });
    expect(batches.length).toBeGreaterThan(0);
    for (const b of batches) {
      const last = msgs.find((m) => m.id === b.messageIds[b.messageIds.length - 1])!;
      expect(last.role).toBe('assistant');
    }
  });

  it('makes smaller batches when messages are long', () => {
    const msgs = Array.from({ length: 8 }, (_, i) => mk(i + 1, i % 2 === 0 ? 'user' : 'assistant', 400));
    const batches = planBatches(msgs, { usableTokens: 4000 });
    expect(batches.every((b) => b.messageIds.length <= 2)).toBe(true);
  });

  it('makes larger batches when messages are short', () => {
    const msgs = Array.from({ length: 20 }, (_, i) => mk(i + 1, i % 2 === 0 ? 'user' : 'assistant', 10));
    const batches = planBatches(msgs, { usableTokens: 32000 });
    expect(batches[0].messageIds.length).toBeGreaterThan(5);
  });

  it('never ends a batch between a tool call and its result', () => {
    const msgs = [
      mk(1, 'user', 300), { id: 'm2', seq: 2, role: 'assistant' as const, tokens: 300, hasToolCalls: true, important: false },
      { id: 'm3', seq: 3, role: 'tool' as const, tokens: 300, hasToolCalls: false, important: false }, mk(4, 'assistant', 50),
    ];
    const batches = planBatches(msgs, { usableTokens: 3000 });
    for (const b of batches) expect(b.messageIds[b.messageIds.length - 1]).not.toBe('m2');
  });
});

describe('summary verification', () => {
  const originals = [
    { role: 'user', content: 'My project is called Falcon Ridge. The budget is 12,500 USD and the deadline is 14 March. Always export as GLB.' },
    { role: 'assistant', content: 'Noted. I will create car_model_v2.glb at 30000 polygons. We still need to choose textures later.' },
  ];

  it('extracts names, numbers, files, instructions and tasks', () => {
    const f = extractFacts(originals);
    expect(f.numbers).toEqual(expect.arrayContaining(['12500usd', '30000']));
    expect(f.files).toContain('car_model_v2.glb');
    expect(f.instructions.join(' ')).toMatch(/Always export as GLB/);
    expect(f.tasks.join(' ')).toMatch(/still need/);
  });

  it('passes a faithful summary', () => {
    const summary = 'Project Falcon Ridge, budget 12,500 USD, deadline 14 March. Instruction: always export as GLB. ' +
      'Created car_model_v2.glb at 30000 polygons. Open task: still need to choose textures later.';
    const r = verifySummary(originals, summary);
    expect(r.passed).toBe(true);
    expect(r.coverage).toBe(1);
  });

  it('fails when numbers change or disappear', () => {
    const r = verifySummary(originals, 'Project Falcon Ridge with a budget of 13,000 USD. Export as GLB. car_model_v2.glb. Choose textures later.');
    expect(r.passed).toBe(false);
    expect(r.missingNumbers).toContain('12500usd');
    expect(r.unsupportedNumbers).toContain('13000');
  });
});

describe('SmartContextEngine', () => {
  let chatId: string;
  beforeEach(async () => {
    await freshDb();
    chatId = (await chatsRepo.create({ title: 'test' })).id;
  });

  it('does not compact below the threshold', async () => {
    for (let i = 0; i < 4; i++) { await addMessage(chatId, 'user', `question ${i}`); await addMessage(chatId, 'assistant', `answer ${i}`); }
    const s = new FaithfulSummarizer();
    const engine = new SmartContextEngine(repoContextStore, new EstimateTokenizer(), s, settings);
    const r = await engine.prepare({ chatId, systemPrompt: 'sys', contextLength: 8000, reservedOutput: 1000, query: 'hi', retrievalBatches: 2, llmVerification: false });
    expect(r.report.compaction).toBeNull();
    expect(s.calls.length).toBe(0);
    expect(r.history.length).toBe(8);
  });

  it('compacts at ~85% usage, keeps originals, and frees context', async () => {
    const long = 'The Falcon Ridge render uses 4096 px textures and the file hero_car.glb. '.repeat(12);
    for (let i = 0; i < 14; i++) { await addMessage(chatId, 'user', `Step ${i}: ${long}`); await addMessage(chatId, 'assistant', `Done step ${i}. ${long}`); }
    const tokenizer = new EstimateTokenizer();
    const s = new FaithfulSummarizer();
    // Faithful-but-compressing summariser: keep unique facts only.
    s.summarize = async (input) => {
      s.calls.push(input);
      const steps = [...input.transcript.matchAll(/Step (\d+)/g)].map((m) => m[1]);
      return `## Summary\n- Steps ${steps.join(', ')} completed for Falcon Ridge.\n## Facts and numbers\n- Textures are 4096 px; file hero_car.glb.\n## Memory\n- [project] Falcon Ridge car render`;
    };
    const engine = new SmartContextEngine(repoContextStore, tokenizer, s, { ...settings });
    const before = await engine.prepare({ chatId, systemPrompt: 'sys', contextLength: 1_000_000, reservedOutput: 1000, query: 'x', retrievalBatches: 0, llmVerification: false, allowCompaction: false });
    const ctx = Math.round(before.report.total / 0.9) + 1000;
    const r = await engine.prepare({ chatId, systemPrompt: 'sys', contextLength: ctx, reservedOutput: 1000, query: 'continue', retrievalBatches: 0, llmVerification: false });

    expect(r.report.compaction).not.toBeNull();
    expect(r.report.compaction!.batches).toBeGreaterThan(0);
    expect(r.report.total).toBeLessThan(before.report.total);
    expect(r.report.percent).toBeLessThan(0.85);
    // Originals are preserved in SQLite and linked to batches.
    const all = await messagesRepo.list(chatId);
    expect(all.length).toBe(28);
    const batches = await contextRepo.batches(chatId);
    const summaries = await contextRepo.summaries(chatId);
    expect(summaries.every((x) => x.sourceMessageIds.length > 0 && x.batchId)).toBe(true);
    expect(batches.flatMap((b) => b.messageIds).every((id) => all.find((m) => m.id === id)?.batchId)).toBe(true);
    // Recent messages remain verbatim.
    expect(r.history.slice(-4).map((m) => m.seq)).toEqual([25, 26, 27, 28]);
    // Long-term memory extracted.
    expect((await contextRepo.memory(chatId)).some((m) => m.kind === 'project')).toBe(true);
  });

  it('keeps originals in context when a summary fails verification', async () => {
    const text = 'Budget is 12,500 USD for Falcon Ridge and the file is hero_car.glb. Always export GLB. ';
    for (let i = 0; i < 10; i++) { await addMessage(chatId, 'user', `${text} item ${i}`.repeat(3)); await addMessage(chatId, 'assistant', `ok ${i} ${text}`.repeat(3)); }
    const lossy = new LossySummarizer();
    const engine = new SmartContextEngine(repoContextStore, new EstimateTokenizer(), lossy, settings);
    const probe = await engine.prepare({ chatId, systemPrompt: 's', contextLength: 1_000_000, reservedOutput: 500, query: 'q', retrievalBatches: 0, llmVerification: false, allowCompaction: false });
    const r = await engine.prepare({ chatId, systemPrompt: 's', contextLength: Math.round(probe.report.total / 0.9) + 500, reservedOutput: 500, query: 'q', retrievalBatches: 0, llmVerification: false });
    expect(lossy.attempts).toBeGreaterThanOrEqual(2); // retried with feedback
    const batches = await contextRepo.batches(chatId);
    expect(batches.length).toBeGreaterThan(0);
    // Each batch is either a verified summary (after verbatim augmentation) or preserved raw — never a lossy summary.
    const summaries = await contextRepo.summaries(chatId);
    for (const s of summaries.filter((x) => x.verified)) {
      expect(s.content).toContain('12,500');
      expect(s.content).not.toMatch(/\b999\b/);
    }
    expect(r.system).not.toMatch(/\b999\b/);
  });

  it('retrieves original batches for questions about earlier details', async () => {
    await addMessage(chatId, 'user', 'The serial number of my scanner is ZX-48213 and it was bought in Lahore.');
    await addMessage(chatId, 'assistant', 'Got it, scanner serial ZX-48213 from Lahore.');
    for (let i = 0; i < 12; i++) { await addMessage(chatId, 'user', `Unrelated topic ${i} about painting landscapes with oils. `.repeat(8)); await addMessage(chatId, 'assistant', `Painting advice ${i}. `.repeat(10)); }
    const s = new FaithfulSummarizer();
    s.summarize = async (input) => {
      const serial = input.transcript.includes('ZX-48213') ? '- Scanner serial ZX-48213, bought in Lahore.\n' : '';
      return `## Summary\n${serial}- Discussion about painting.\n`;
    };
    const engine = new SmartContextEngine(repoContextStore, new EstimateTokenizer(), s, { ...settings, summaryVerification: false });
    const probe = await engine.prepare({ chatId, systemPrompt: 's', contextLength: 1_000_000, reservedOutput: 500, query: 'q', retrievalBatches: 0, llmVerification: false, allowCompaction: false });
    const ctx = Math.round(probe.report.total / 0.9) + 500;
    await engine.prepare({ chatId, systemPrompt: 's', contextLength: ctx, reservedOutput: 500, query: 'go on', retrievalBatches: 0, llmVerification: false });
    const r = await engine.prepare({ chatId, systemPrompt: 's', contextLength: ctx, reservedOutput: 500, query: 'What exactly was the serial number of my scanner I mentioned earlier?', retrievalBatches: 2, llmVerification: false });
    expect(r.report.queryType).toBe('complex');
    expect(r.report.retrievedBatchIds.length).toBeGreaterThan(0);
    expect(r.system).toContain('Retrieved original messages');
    expect(r.system).toContain('ZX-48213');
  });
});

describe('helpers', () => {
  it('parses memory sections', () => {
    expect(parseMemory('## Summary\nx\n## Memory\n- [instruction] Use metric units\n- [bogus] nope\n- [decision] Ship v2 first')).toEqual([
      { kind: 'instruction', content: 'Use metric units' }, { kind: 'decision', content: 'Ship v2 first' },
    ]);
  });
  it('ranks relevant documents with BM25', () => {
    const r = bm25('scanner serial', [{ id: 'a', text: 'painting with oils' }, { id: 'b', text: 'the scanner serial number' }]);
    expect(r.find((x) => x.id === 'b')!.score).toBeGreaterThan(r.find((x) => x.id === 'a')!.score);
  });
  it('classifies simple vs complex queries', () => {
    expect(classifyQuery('hello', 2)).toBe('simple');
    expect(classifyQuery('what did we decide earlier about the budget?', 2)).toBe('complex');
    expect(classifyQuery('what did we decide earlier?', 0)).toBe('simple');
  });
});
