// Curated download suggestions. Only metadata lives here: the exact file size and SHA-256 are
// fetched from the Hugging Face API at download time and verified after download, so nothing is
// trusted from this list except the repository name. Users can also enter any Hugging Face repo.
import type { ModelCategory } from '@/types';

export interface CatalogEntry {
  id: string;
  category: ModelCategory;
  name: string;
  repo: string;
  /** Exact file path, or a regex to choose among files (e.g. one quantisation or zip). */
  file?: string;
  filePattern?: string;
  format: 'gguf' | 'coreml-diffusion-zip';
  approxSizeGB: number;
  parameters?: string;
  license: string;
  attribution: string;
  notes: string;
}

export const MODEL_CATALOG: CatalogEntry[] = [
  { id: 'llama-3.2-1b-q4', category: 'chat', name: 'Llama 3.2 1B Instruct (Q4_K_M)', repo: 'bartowski/Llama-3.2-1B-Instruct-GGUF',
    file: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf', format: 'gguf', approxSizeGB: 0.8, parameters: '1B', license: 'Llama 3.2 Community License',
    attribution: 'Meta; GGUF by bartowski', notes: 'Very fast; good for summaries and simple chat.' },
  { id: 'llama-3.2-3b-q4', category: 'chat', name: 'Llama 3.2 3B Instruct (Q4_K_M)', repo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    file: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf', format: 'gguf', approxSizeGB: 2.0, parameters: '3B', license: 'Llama 3.2 Community License',
    attribution: 'Meta; GGUF by bartowski', notes: 'Balanced quality and speed on an 8 GB iPad.' },
  { id: 'qwen2.5-3b-q4', category: 'chat', name: 'Qwen2.5 3B Instruct (Q4_K_M)', repo: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
    file: 'qwen2.5-3b-instruct-q4_k_m.gguf', format: 'gguf', approxSizeGB: 2.1, parameters: '3B', license: 'Qwen Research License',
    attribution: 'Alibaba Qwen', notes: 'Strong multilingual model; check its licence for commercial use.' },
  { id: 'qwen3-4b-q4', category: 'chat', name: 'Qwen3 4B (Q4_K_M)', repo: 'Qwen/Qwen3-4B-GGUF', file: 'Qwen3-4B-Q4_K_M.gguf',
    format: 'gguf', approxSizeGB: 2.5, parameters: '4B', license: 'Apache-2.0', attribution: 'Alibaba Qwen',
    notes: 'Reasoning model (emits <think> blocks, shown separately).' },
  { id: 'gemma-3-4b-q4', category: 'chat', name: 'Gemma 3 4B IT (Q4_K_M)', repo: 'bartowski/google_gemma-3-4b-it-GGUF',
    file: 'google_gemma-3-4b-it-Q4_K_M.gguf', format: 'gguf', approxSizeGB: 2.5, parameters: '4B', license: 'Gemma Terms of Use',
    attribution: 'Google; GGUF by bartowski', notes: 'Good general assistant. Text only in ZinoAgent.' },
  { id: 'phi-3.5-mini-q4', category: 'chat', name: 'Phi-3.5 mini Instruct (Q4_K_M)', repo: 'bartowski/Phi-3.5-mini-instruct-GGUF',
    file: 'Phi-3.5-mini-instruct-Q4_K_M.gguf', format: 'gguf', approxSizeGB: 2.4, parameters: '3.8B', license: 'MIT',
    attribution: 'Microsoft; GGUF by bartowski', notes: 'Long trained context (128K); use a modest context on iPad.' },
  { id: 'qwen2.5-7b-q4', category: 'chat', name: 'Qwen2.5 7B Instruct (Q4_K_M)', repo: 'bartowski/Qwen2.5-7B-Instruct-GGUF',
    file: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf', format: 'gguf', approxSizeGB: 4.7, parameters: '7B', license: 'Apache-2.0',
    attribution: 'Alibaba Qwen; GGUF by bartowski', notes: 'Near the memory limit of an 8 GB iPad: expect "limited" or "experimental" compatibility.' },
  { id: 'sd21-base-coreml', category: 'image', name: 'Stable Diffusion 2.1 base (Core ML, palettized)', repo: 'apple/coreml-stable-diffusion-2-1-base-palettized',
    filePattern: 'split_einsum.*compiled.*\\.zip$', format: 'coreml-diffusion-zip', approxSizeGB: 1.6, license: 'CreativeML Open RAIL++-M',
    attribution: 'Stability AI; Core ML conversion by Apple', notes: '512×512. Split-einsum variant runs on the Neural Engine.' },
];

export const hfResolveUrl = (repo: string, path: string, revision = 'main') =>
  `https://huggingface.co/${repo}/resolve/${revision}/${path.split('/').map(encodeURIComponent).join('/')}`;
