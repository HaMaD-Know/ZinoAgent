import type { Capability, ModelCategory, Provider, ProviderKind, ProviderModel } from '@/types';
import type { HttpAuth } from '@/native';

/** Unified message format sent to chat adapters (each adapter converts to its API's shape). */
export interface ProviderMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  images?: { mime: string; base64: string }[];
  toolCalls?: { id: string; name: string; arguments: Record<string, unknown> }[];
  toolCallId?: string;
  toolName?: string;
  /** Provider-native assistant content (e.g. Anthropic thinking signatures, Gemini thought
   *  signatures) replayed verbatim when the same provider continues a tool-use loop. */
  raw?: { kind: ProviderKind; content: unknown };
}

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>; // JSON Schema object
}

export type StreamEvent =
  | { type: 'text'; text: string }
  | { type: 'reasoning'; text: string }
  | { type: 'tool_call'; call: { id: string; name: string; arguments: Record<string, unknown> } }
  | { type: 'usage'; inputTokens?: number; outputTokens?: number };

export interface ChatResult {
  text: string;
  reasoning: string;
  toolCalls: { id: string; name: string; arguments: Record<string, unknown> }[];
  usage: { inputTokens?: number; outputTokens?: number };
  stopReason: string;
  raw?: { kind: ProviderKind; content: unknown };
}

/** Concrete, provider-specific parameters produced by the effort mapper. */
export interface EffortParams {
  maxOutputTokens: number;
  openaiReasoningEffort?: 'minimal' | 'low' | 'medium' | 'high' | 'none';
  anthropicThinking?: { mode: 'adaptive'; effort: 'low' | 'medium' | 'high' | 'xhigh' | 'max' } | { mode: 'budget'; budgetTokens: number } | { mode: 'off' };
  geminiThinking?: { budget: number } | { level: 'low' | 'high' };
  temperature?: number;
}

export interface ChatRequest {
  model: string;
  messages: ProviderMessage[];
  tools?: ToolDefinition[];
  effort: EffortParams;
  signal?: AbortSignal;
  modelInfo?: ProviderModel | null;
}

export interface ConnectionTestResult { ok: boolean; message: string; modelCount?: number }

export interface ChatAdapter {
  chat(p: Provider, req: ChatRequest, onEvent: (e: StreamEvent) => void): Promise<ChatResult>;
}

export interface ProviderAdapter {
  testConnection(p: Provider): Promise<ConnectionTestResult>;
  listModels(p: Provider): Promise<ProviderModel[]>;
}

export interface ProviderKindInfo {
  kind: ProviderKind;
  label: string;
  categories: ModelCategory[];
  defaultBaseUrl: string;
  keyRequired: boolean;
  keyHelp: string;
  notes?: string;
}

export const PROVIDER_KINDS: ProviderKindInfo[] = [
  { kind: 'openai', label: 'OpenAI', categories: ['chat', 'image', 'video'], defaultBaseUrl: 'https://api.openai.com/v1', keyRequired: true,
    keyHelp: 'Create a key at platform.openai.com → API keys.' },
  { kind: 'anthropic', label: 'Anthropic Claude', categories: ['chat'], defaultBaseUrl: 'https://api.anthropic.com/v1', keyRequired: true,
    keyHelp: 'Create a key at platform.claude.com → API keys.' },
  { kind: 'gemini', label: 'Google Gemini', categories: ['chat', 'image', 'video'], defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta', keyRequired: true,
    keyHelp: 'Create a key in Google AI Studio (aistudio.google.com → Get API key).' },
  { kind: 'openai_compatible', label: 'OpenAI-compatible endpoint', categories: ['chat', 'image'], defaultBaseUrl: 'http://192.168.1.10:11434/v1', keyRequired: false,
    keyHelp: 'For OpenRouter, Groq, Together, LM Studio, Ollama and similar. Some local servers need no key.',
    notes: 'Plain http:// is allowed only for local-network addresses.' },
  { kind: 'stability', label: 'Stability AI', categories: ['image', 'threed'], defaultBaseUrl: 'https://api.stability.ai', keyRequired: true,
    keyHelp: 'Create a key at platform.stability.ai → Account → API keys.' },
  { kind: 'meshy', label: 'Meshy', categories: ['threed'], defaultBaseUrl: 'https://api.meshy.ai', keyRequired: true,
    keyHelp: 'Create a key at meshy.ai → Settings → API.' },
  { kind: 'tripo', label: 'Tripo', categories: ['threed'], defaultBaseUrl: 'https://api.tripo3d.ai/v2/openapi', keyRequired: true,
    keyHelp: 'Create a key at platform.tripo3d.ai → API keys.' },
  { kind: 'runway', label: 'Runway', categories: ['video'], defaultBaseUrl: 'https://api.dev.runwayml.com/v1', keyRequired: true,
    keyHelp: 'Create a key at dev.runwayml.com.' },
];

export const kindInfo = (k: ProviderKind) => PROVIDER_KINDS.find((x) => x.kind === k)!;

/** How each provider expects its key. Used by ZinoHttp to inject the Keychain secret natively. */
export function authFor(p: Provider): HttpAuth | undefined {
  if (!p.keyMasked && p.kind === 'openai_compatible') return undefined; // keyless local server
  switch (p.kind) {
    case 'anthropic': return { account: p.keyAccount, name: 'x-api-key' };
    case 'gemini': return { account: p.keyAccount, name: 'x-goog-api-key' };
    default: return { account: p.keyAccount, name: 'Authorization', prefix: 'Bearer ' };
  }
}

export const trimSlash = (u: string) => u.replace(/\/+$/, '');

export function capabilityUnion(models: { capabilities: Capability[] }[]): Capability[] {
  const set = new Set<Capability>();
  for (const m of models) for (const c of m.capabilities) set.add(c);
  return [...set];
}
