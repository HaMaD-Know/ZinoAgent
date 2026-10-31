// Effort Level → concrete per-engine parameters. Every plan lists what it actually changed and
// what the selected model/provider cannot do, so the UI never claims an effect that did not happen.
import type { EffortLevel, ProviderKind, ProviderModel, ProviderOptions } from '@/types';
import type { EffortParams } from '@/providers/types';
import { anthropicEffortLevels, anthropicThinkingMode } from '@/providers/chat/anthropic';
import { isOpenAIReasoningModel } from '@/providers/chat/openai';

export type ResolvedEffort = Exclude<EffortLevel, 'auto'>;
const ORDER: ResolvedEffort[] = ['minimal', 'low', 'medium', 'high', 'maximum'];

export interface EffortPlan {
  requested: EffortLevel;
  level: ResolvedEffort;
  autoReason?: string;
  params: EffortParams;
  /** Local llama.cpp sampling (only for offline models). */
  local?: { temperature: number; topP: number; topK: number; minP: number; repeatPenalty: number };
  /** SmartContextEngine knobs driven by effort. */
  context: { retrievalBatches: number; llmVerification: boolean };
  applied: string[];
  notApplied: string[];
}

/** Heuristic task complexity for Auto effort. Pure function — unit tested. */
export function classifyComplexity(prompt: string, opts: { attachments?: number; toolsAvailable?: boolean } = {}): { level: ResolvedEffort; reason: string } {
  const p = prompt.trim();
  const words = p.split(/\s+/).filter(Boolean).length;
  let score = 0;
  const reasons: string[] = [];
  if (words > 250) { score += 2; reasons.push('long request'); } else if (words > 60) { score += 1; reasons.push('detailed request'); }
  if (/```|\bfunction\b|\bclass\b|=>|\bimport\b|\bdef\b/.test(p)) { score += 2; reasons.push('code'); }
  const reasoningTerms = new Set((p.match(/\b(analy[sz]e|compare|design|architect\w*|prove|derive|debug|optimi[sz]e|step[- ]by[- ]step|plan|trade-?offs?|evaluate|refactor|why does|root cause)\b/gi) ?? []).map((t) => t.toLowerCase()));
  if (reasoningTerms.size) { score += 1 + Math.min(3, reasoningTerms.size); reasons.push('reasoning task'); }
  if ((p.match(/\?/g) ?? []).length >= 3) { score += 1; reasons.push('several questions'); }
  if ((opts.attachments ?? 0) > 0) { score += 1; reasons.push('attachments'); }
  if (/\b(organi[sz]e|rename|move|find|duplicates?)\b/i.test(p) && opts.toolsAvailable) { score += 1; reasons.push('file operations'); }
  if (words <= 12 && score === 0) return { level: 'low', reason: 'short, simple message' };
  const level: ResolvedEffort = score >= 5 ? 'high' : score >= 2 ? 'medium' : 'low';
  return { level, reason: reasons.join(', ') || 'general request' };
}

const LOCAL_TOKENS: Record<ResolvedEffort, number> = { minimal: 384, low: 768, medium: 1536, high: 3072, maximum: 6144 };
const CLOUD_TOKENS: Record<ResolvedEffort, number> = { minimal: 1024, low: 2048, medium: 8192, high: 16000, maximum: 32000 };
const RETRIEVAL: Record<ResolvedEffort, number> = { minimal: 0, low: 1, medium: 2, high: 4, maximum: 6 };

export interface EffortInput {
  requested: EffortLevel;
  prompt: string;
  engine: 'local' | ProviderKind;
  modelId: string;
  modelInfo?: ProviderModel | null;
  providerOptions?: ProviderOptions;
  outputLimit?: number | null;
  contextLength?: number | null;
  attachments?: number;
  toolsAvailable?: boolean;
  /** 'auto' | 'always' | 'never' from settings. */
  llmVerification?: 'auto' | 'always' | 'never';
}

export function planEffort(i: EffortInput): EffortPlan {
  let level: ResolvedEffort;
  let autoReason: string | undefined;
  if (i.requested === 'auto') {
    const c = classifyComplexity(i.prompt, { attachments: i.attachments, toolsAvailable: i.toolsAvailable });
    level = c.level; autoReason = c.reason;
  } else level = i.requested;

  const applied: string[] = [];
  const notApplied: string[] = [];
  const idx = ORDER.indexOf(level);
  const llmVerification = i.llmVerification === 'always' || (i.llmVerification !== 'never' && idx >= 3);
  const context = { retrievalBatches: RETRIEVAL[level], llmVerification };
  applied.push(`History retrieval depth: ${RETRIEVAL[level]} batch${RETRIEVAL[level] === 1 ? '' : 'es'}`);
  if (llmVerification) applied.push('Summaries get an extra model-based verification pass');

  if (i.engine === 'local') {
    const ctx = i.contextLength ?? 4096;
    const maxOut = Math.min(LOCAL_TOKENS[level], Math.max(256, Math.floor(ctx * 0.35)));
    const local = {
      temperature: idx <= 1 ? 0.5 : 0.7,
      topP: idx >= 3 ? 0.9 : 0.95,
      topK: 40,
      minP: 0.05,
      repeatPenalty: 1.1,
    };
    applied.push(`Max output: ${maxOut} tokens`, `Sampling: temperature ${local.temperature}, top-p ${local.topP}`);
    notApplied.push('Local GGUF models have no separate reasoning-effort control; effort changes output budget, sampling and context retrieval.');
    return { requested: i.requested, level, autoReason, params: { maxOutputTokens: maxOut }, local, context, applied, notApplied };
  }

  const cap = (n: number) => (i.outputLimit ? Math.min(n, i.outputLimit) : n);
  const params: EffortParams = { maxOutputTokens: cap(CLOUD_TOKENS[level]) };
  const id = i.modelId.toLowerCase();

  switch (i.engine) {
    case 'openai': {
      if (isOpenAIReasoningModel(id)) {
        const gpt5Base = /^gpt-5(-mini|-nano)?($|-\d{4})/.test(id);
        const gpt5x = /^gpt-5\.\d/.test(id);
        const map: Record<ResolvedEffort, EffortParams['openaiReasoningEffort']> = {
          minimal: gpt5Base ? 'minimal' : gpt5x ? 'none' : 'low',
          low: 'low', medium: 'medium', high: 'high', maximum: 'high',
        };
        params.openaiReasoningEffort = map[level];
        applied.push(`reasoning_effort = "${params.openaiReasoningEffort}"`);
        if (level === 'maximum') notApplied.push('OpenAI\'s highest generally available setting is "high"; Maximum also raises the output budget.');
        if (level === 'minimal' && !gpt5Base && !gpt5x) notApplied.push('This model has no "minimal" setting; "low" is used.');
      } else {
        notApplied.push('This OpenAI model does not support reasoning effort; only the output budget changes.');
      }
      break;
    }
    case 'anthropic': {
      const mode = anthropicThinkingMode(i.modelInfo, id);
      if (mode === 'adaptive') {
        const supported = anthropicEffortLevels(i.modelInfo);
        const want: Record<ResolvedEffort, string> = { minimal: 'low', low: 'low', medium: 'medium', high: 'high', maximum: 'max' };
        let e = want[level];
        if (!supported.includes(e)) e = [...supported].reverse().find((x) => ['low', 'medium', 'high', 'xhigh', 'max'].indexOf(x) <= ['low', 'medium', 'high', 'xhigh', 'max'].indexOf(e)) ?? 'high';
        params.anthropicThinking = { mode: 'adaptive', effort: e as 'low' };
        params.maxOutputTokens = cap(Math.max(params.maxOutputTokens, { minimal: 4096, low: 8192, medium: 16000, high: 32000, maximum: 64000 }[level]));
        applied.push(`Adaptive thinking with effort "${e}"`);
        if (level === 'minimal') notApplied.push('Claude has no "minimal" effort; "low" is the lowest setting (thinking cannot be fully disabled on newer models).');
      } else if (mode === 'budget') {
        if (level === 'minimal') {
          params.anthropicThinking = { mode: 'off' };
          applied.push('Extended thinking off');
        } else {
          const budget = { low: 1024, medium: 4096, high: 12000, maximum: 24000 }[level as Exclude<ResolvedEffort, 'minimal'>];
          params.anthropicThinking = { mode: 'budget', budgetTokens: budget };
          params.maxOutputTokens = cap(budget + params.maxOutputTokens);
          applied.push(`Extended thinking budget: ${budget} tokens`);
        }
      } else {
        notApplied.push('This Claude model does not support extended thinking; only the output budget changes.');
      }
      break;
    }
    case 'gemini': {
      if (/gemini-([3-9])/.test(id)) {
        const lvl = idx >= 3 ? 'high' : 'low';
        params.geminiThinking = { level: lvl };
        applied.push(`thinkingLevel = "${lvl}"`);
        notApplied.push('Gemini 3 exposes two thinking levels; Minimal/Low/Medium use "low", High/Maximum use "high".');
      } else if (/gemini-2\.5/.test(id)) {
        const pro = /pro/.test(id);
        const budgets: Record<ResolvedEffort, number> = { minimal: pro ? 128 : 0, low: 1024, medium: 4096, high: 16384, maximum: pro ? 32768 : 24576 };
        params.geminiThinking = { budget: budgets[level] };
        applied.push(`thinkingBudget = ${budgets[level]}`);
        if (pro && level === 'minimal') notApplied.push('Gemini 2.5 Pro cannot turn thinking off; 128 is its minimum budget.');
      } else {
        notApplied.push('This Gemini model has no thinking controls; only the output budget changes.');
      }
      break;
    }
    case 'openai_compatible': {
      if (i.providerOptions?.supportsReasoningEffort) {
        params.openaiReasoningEffort = idx <= 1 ? 'low' : idx === 2 ? 'medium' : 'high';
        applied.push(`reasoning_effort = "${params.openaiReasoningEffort}" (enabled for this endpoint in settings)`);
      } else {
        notApplied.push('Reasoning effort is not enabled for this endpoint (turn it on in the provider settings if the server supports it).');
      }
      break;
    }
    default:
      break;
  }
  applied.unshift(`Max output: ${params.maxOutputTokens} tokens`);
  return { requested: i.requested, level, autoReason, params, context, applied, notApplied };
}

export function resolveRequestedEffort(opts: {
  chatEffort?: EffortLevel | null;
  modelKey: string;
  studio: 'agent' | 'image' | 'threed' | 'video';
  online: boolean;
  settings: { offlineDefault: EffortLevel; onlineDefault: EffortLevel; perStudio: Partial<Record<string, EffortLevel>>; perModel: Record<string, EffortLevel> };
}): EffortLevel {
  return opts.chatEffort
    ?? opts.settings.perModel[opts.modelKey]
    ?? opts.settings.perStudio[opts.studio]
    ?? (opts.online ? opts.settings.onlineDefault : opts.settings.offlineDefault);
}
