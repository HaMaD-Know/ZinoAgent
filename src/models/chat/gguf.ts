// GGUF compatibility assessment for the bundled llama.cpp build (pinned tag b12020).
import type { Compatibility } from '@/types';
import type { GGUFInfo } from '@/native';

/** Architectures known to the pinned llama.cpp build (from src/llama-arch.cpp at b12020). */
export const LLAMA_CPP_ARCHITECTURES = new Set(('clip llama llama4 deci falcon grok gpt2 gptj gptneox mpt baichuan starcoder refact bert modern-bert nomic-bert nomic-bert-moe neo-bert jina-bert-v2 jina-bert-v3 eurobert bloom stablelm qwen qwen2 qwen2moe qwen2vl sensenova_u1 qwen3 flint qwen3moe qwen3next qwen3vl qwen3vlmoe qwen35 qwen35moe clef vllm-decision2 qwen4exp phi2 phi3 phimoe plamo plamo2 plamo3 codeshell orion internlm2 minicpm minicpm3 gemma gemma2 gemma3 gemma3n gemma4 gemma4-assistant gemma-embedding gemma-embedding2 starcoder2 mamba mamba2 maple jamba falcon-h1 xverse command-r cohere2 cohere2moe dbrx olmo olmo2 olmoe muse-glimmer muse-spark openelm arctic deepseek deepseek2 deepseek2-ocr deepseek32 deepseek4 deepseek41 chatglm glm4 glm4moe glm-dsa bitnet t5 t5encoder jais jais2 nemotron nemotron_h nemotron_h_moe exaone exaone4 exaone-moe rwkv6 rwkv6qwen2 rwkv7 arwkv7 granite granitemoe granitehybrid graniteswitch granite_swa chameleon wavtokenizer-dec plm bailingmoe bailingmoe2 bailingmoe3 dots1 dots3note arcee afmoe laguna ernie4_5 ernie4_5-moe hunyuan-moe hunyuan-dense hunyuan_vl hy_v3 hy_v4 smollm3 gpt-oss lfm2 lfm2moe lfm3 dream smallthinker llada llada-moe seed_oss grovemoe apertus minimax-01 hrm_text limite minimax-m2 minimax-m3 cogvlm rnd1 pangu-embedded mistral3 eagle3 dflash mistral4 mistral-large4 paddleocr mimo2 step35 spark2_5 llama-embed maincoder maion-coder kimi-linear kimi-k3 glm5-next talkie mellum nanbeige qwen3tts pockettts k2-horizon beam kolibri1').split(' '));

/** Architectures that load in llama.cpp but are not text chat models. */
const NON_CHAT = /^(clip|bert|modern-bert|nomic-bert.*|neo-bert|jina-bert.*|eurobert|gemma-embedding.*|t5encoder|wavtokenizer-dec|llama-embed|qwen3tts|pockettts|eagle3|dflash|paddleocr|deepseek2-ocr)$/;

/** llama_ftype enum → human label (subset; unknown values are shown numerically). */
const FTYPES: Record<number, string> = {
  0: 'F32', 1: 'F16', 2: 'Q4_0', 3: 'Q4_1', 7: 'Q8_0', 8: 'Q5_0', 9: 'Q5_1', 10: 'Q2_K', 11: 'Q3_K_S', 12: 'Q3_K_M', 13: 'Q3_K_L',
  14: 'Q4_K_S', 15: 'Q4_K_M', 16: 'Q5_K_S', 17: 'Q5_K_M', 18: 'Q6_K', 19: 'IQ2_XXS', 20: 'IQ2_XS', 21: 'Q2_K_S', 22: 'IQ3_XS',
  23: 'IQ3_XXS', 24: 'IQ1_S', 25: 'IQ4_NL', 26: 'IQ3_S', 27: 'IQ3_M', 28: 'IQ2_S', 29: 'IQ2_M', 30: 'IQ4_XS', 31: 'IQ1_M', 32: 'BF16',
  36: 'TQ1_0', 37: 'TQ2_0', 38: 'MXFP4_MOE',
};

export function quantLabel(info: Pick<GGUFInfo, 'fileType'>, fileName = ''): string | null {
  if (info.fileType !== undefined && FTYPES[info.fileType]) return FTYPES[info.fileType];
  const m = fileName.match(/(IQ\d_[A-Z]+|Q\d_K_[SML]|Q\d_K|Q\d_\d|BF16|F16|F32)/i);
  return m ? m[1].toUpperCase() : info.fileType !== undefined ? `type ${info.fileType}` : null;
}

const num = (v: number | { arrayLength: number } | undefined) => (typeof v === 'number' ? v : undefined);

/** Estimated resident memory (bytes) for weights + f16 KV cache + compute buffers. */
export function estimateMemory(info: GGUFInfo, contextLength: number): { weights: number; kvCache: number; overhead: number; total: number } {
  const weights = info.fileSize;
  const layers = info.blockCount ?? 32;
  const heads = num(info.headCount) ?? 32;
  const kvHeads = num(info.headCountKv) ?? heads;
  const headDim = info.keyLength ?? (info.embeddingLength ? info.embeddingLength / heads : 128);
  const valueDim = info.valueLength ?? headDim;
  // K and V per layer, f16 (2 bytes). Sliding-window/hybrid models use less; this is an upper bound.
  const kvCache = layers * contextLength * kvHeads * (headDim + valueDim) * 2;
  const overhead = 350 * 1024 * 1024 + Math.min(512 * 1024 * 1024, contextLength * 32 * 1024);
  return { weights, kvCache, overhead, total: weights + kvCache + overhead };
}

export interface ChatCompatibility {
  compatibility: Compatibility;
  notes: string[];
  estimatedBytes: number;
  recommendedContext: number;
}

/**
 * @param budgetBytes memory the app can realistically use. On iPad this comes from
 *   os_proc_available_memory() at runtime; before a model is loaded we use that snapshot.
 */
export function assessGGUF(info: GGUFInfo, fileName: string, budgetBytes: number, requestedContext = 4096): ChatCompatibility {
  const notes: string[] = [];
  const arch = info.architecture;
  if (!arch) return { compatibility: 'unsupported', notes: ['The file has no architecture metadata.'], estimatedBytes: info.fileSize, recommendedContext: 0 };
  if (!LLAMA_CPP_ARCHITECTURES.has(arch)) {
    return { compatibility: 'unsupported', notes: [`Architecture "${arch}" is not supported by the bundled llama.cpp build (b12020).`], estimatedBytes: info.fileSize, recommendedContext: 0 };
  }
  if (NON_CHAT.test(arch)) {
    return { compatibility: 'unsupported', notes: [`"${arch}" is not a text chat model (embedding/vision/audio component).`], estimatedBytes: info.fileSize, recommendedContext: 0 };
  }
  if (info.isSplit) notes.push('This is one shard of a split GGUF; all shards must be imported into the same folder.');
  if (!info.hasChatTemplate) notes.push('No chat template in the file; ZinoAgent will use a generic ChatML format, which may reduce quality.');
  const trained = info.contextLength ?? requestedContext;
  let ctx = Math.min(requestedContext, trained);
  let est = estimateMemory(info, ctx);
  // Find the largest context (power of two steps) that fits ~85% of the budget.
  while (ctx > 1024 && est.total > budgetBytes * 0.85) { ctx = Math.floor(ctx / 2); est = estimateMemory(info, ctx); }
  const ratio = est.total / budgetBytes;
  let compatibility: Compatibility;
  if (ratio <= 0.6) compatibility = 'compatible';
  else if (ratio <= 0.85) { compatibility = 'limited'; notes.push('Fits, but leaves little memory headroom. Close other apps and avoid very long contexts.'); }
  else if (ratio <= 1.1) { compatibility = 'experimental'; notes.push('Estimated memory is at or above what iPadOS usually allows this app. Loading may fail or the app may be terminated.'); }
  else { compatibility = 'unsupported'; notes.push(`Needs about ${(est.total / 1024 ** 3).toFixed(1)} GB, more than the ~${(budgetBytes / 1024 ** 3).toFixed(1)} GB available to the app.`); }
  if (ctx < requestedContext) notes.push(`Recommended context length on this device: ${ctx} tokens.`);
  if (/^(F32|F16|BF16)$/.test(quantLabel(info, fileName) ?? '')) notes.push('Unquantised weights are large and slow on iPad; a Q4_K_M or Q5_K_M quantisation is recommended.');
  return { compatibility, notes, estimatedBytes: est.total, recommendedContext: ctx };
}

/** Default memory budget used when no live measurement exists (documented estimate for an 8 GB iPad). */
export const DEFAULT_BUDGET_BYTES = 5 * 1024 ** 3;
