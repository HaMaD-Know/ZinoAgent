// Core domain types shared across ZinoAgent.

export type Studio = 'agent' | 'image' | 'threed' | 'video';
export type ModelCategory = 'chat' | 'image' | 'threed' | 'video';

export const STUDIO_CATEGORY: Record<Studio, ModelCategory> = {
  agent: 'chat',
  image: 'image',
  threed: 'threed',
  video: 'video',
};

export type Capability =
  | 'chat'
  | 'reasoning'
  | 'vision'
  | 'tool_calling'
  | 'image_generation'
  | 'image_editing'
  | 'threed_generation'
  | 'video_generation';

export type Compatibility = 'compatible' | 'limited' | 'experimental' | 'unsupported';

/** Reference to a model, local or cloud. Stored as JSON per chat / per studio. */
export type ModelRef =
  | { source: 'local'; modelId: string }
  | { source: 'cloud'; providerId: string; modelId: string }
  | { source: 'auto' };

export type EffortLevel = 'minimal' | 'low' | 'medium' | 'high' | 'maximum' | 'auto';
export const EFFORT_LEVELS: EffortLevel[] = ['minimal', 'low', 'medium', 'high', 'maximum', 'auto'];

export interface LocalModel {
  id: string;
  category: ModelCategory;
  name: string;
  /** App-relative path to the model file or folder. */
  path: string;
  format: 'gguf' | 'coreml-diffusion' | 'coreml' | 'other';
  sizeBytes: number;
  sha256: string | null;
  sourceUrl: string | null;
  license: string | null;
  attribution: string | null;
  quantization: string | null;
  architecture: string | null;
  contextLength: number | null;
  parameters: number | null;
  compatibility: Compatibility;
  compatibilityNotes: string[];
  metadata: Record<string, unknown>;
  installedAt: number;
  benchmark: BenchmarkResult | null;
  settings: LocalModelSettings;
}

export interface LocalModelSettings {
  contextLength?: number;
  gpuLayers?: number;
  threads?: number;
  batchSize?: number;
  temperature?: number;
  topP?: number;
  topK?: number;
  minP?: number;
  repeatPenalty?: number;
  compactionThreshold?: number;
  computeUnits?: 'cpuAndNeuralEngine' | 'cpuAndGPU' | 'all' | 'cpuOnly';
}

export interface BenchmarkResult {
  measuredAt: number;
  loadMs?: number;
  promptTokensPerSecond?: number;
  generationTokensPerSecond?: number;
  appFootprintBytes?: number;
  contextLength?: number;
  device?: string;
}

export type ProviderKind =
  | 'openai'
  | 'anthropic'
  | 'gemini'
  | 'openai_compatible'
  | 'stability'
  | 'meshy'
  | 'tripo'
  | 'runway';

export interface Provider {
  id: string;
  category: ModelCategory;
  kind: ProviderKind;
  name: string;
  baseUrl: string;
  /** Keychain account that holds the API key. Never the key itself. */
  keyAccount: string;
  keyMasked: string | null;
  status: 'untested' | 'ok' | 'error';
  lastTestedAt: number | null;
  lastError: string | null;
  capabilities: Capability[];
  defaultModel: string | null;
  options: ProviderOptions;
  createdAt: number;
}

export interface ProviderOptions {
  /** For OpenAI-compatible endpoints: whether to send reasoning_effort. */
  supportsReasoningEffort?: boolean;
  /** For OpenAI-compatible endpoints: whether to send tools. */
  supportsTools?: boolean;
  /** Extra static headers (non-secret), e.g. OpenRouter's HTTP-Referer. */
  headers?: Record<string, string>;
  /** Default model context length override for endpoints that do not report it. */
  contextLength?: number;
}

export interface ProviderModel {
  id: string;
  providerId: string;
  modelId: string;
  displayName: string;
  capabilities: Capability[];
  contextLength: number | null;
  outputLimit: number | null;
  metadata: Record<string, unknown>;
  fetchedAt: number;
}

export type Role = 'system' | 'user' | 'assistant' | 'tool';

export interface ToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

export interface MessageAttachment {
  assetId: string;
  kind: AssetKind;
  name: string;
}

export interface ChatMessage {
  id: string;
  chatId: string;
  seq: number;
  role: Role;
  content: string;
  reasoning: string | null;
  createdAt: number;
  tokenCount: number | null;
  tokenExact: boolean;
  tokenModel: string | null;
  batchId: string | null;
  status: 'complete' | 'streaming' | 'error' | 'cancelled';
  modelRef: ModelRef | null;
  attachments: MessageAttachment[];
  toolCalls: ToolCall[];
  toolCallId: string | null;
  toolName: string | null;
  meta: Record<string, unknown>;
}

export interface Chat {
  id: string;
  title: string;
  titleAuto: boolean;
  folderId: string | null;
  pinned: boolean;
  archived: boolean;
  createdAt: number;
  updatedAt: number;
  modelRef: ModelRef | null;
  effort: EffortLevel | null;
  settings: ChatSettings;
}

export interface ChatSettings {
  systemPrompt?: string;
  fileToolsRootId?: string | null;
  /** Explicit permission for cloud models to receive file names / contents in this chat. */
  cloudFileAccess?: 'never' | 'ask' | 'allowed';
  allowCloudInAuto?: boolean;
}

export interface ChatFolder {
  id: string;
  name: string;
  createdAt: number;
}

export interface Batch {
  id: string;
  chatId: string;
  startSeq: number;
  endSeq: number;
  messageIds: string[];
  tokenCount: number;
  status: 'open' | 'summarised' | 'preserved_raw';
  createdAt: number;
}

export interface VerificationReport {
  passed: boolean;
  attempts: number;
  missingNumbers: string[];
  missingNames: string[];
  missingFiles: string[];
  missingInstructions: string[];
  missingTasks: string[];
  unsupportedNumbers: string[];
  coverage: number;
  llmCheck?: { ran: boolean; passed: boolean; notes: string };
}

export interface Summary {
  id: string;
  chatId: string;
  batchId: string | null;
  level: number;
  parentSummaryIds: string[];
  sourceMessageIds: string[];
  sourceBatchIds: string[];
  content: string;
  tokenCount: number;
  verification: VerificationReport | null;
  verified: boolean;
  modelRef: ModelRef | null;
  createdAt: number;
  supersededBy: string | null;
}

export type MemoryKind = 'instruction' | 'decision' | 'preference' | 'project' | 'fact' | 'task';

export interface MemoryRecord {
  id: string;
  chatId: string | null;
  kind: MemoryKind;
  content: string;
  sourceMessageIds: string[];
  pinned: boolean;
  active: boolean;
  createdAt: number;
  updatedAt: number;
}

export type AssetKind = 'image' | 'model3d' | 'video' | 'import' | 'export';

export interface Asset {
  id: string;
  kind: AssetKind;
  name: string;
  path: string;
  mime: string;
  sizeBytes: number;
  width: number | null;
  height: number | null;
  durationSec: number | null;
  chatId: string | null;
  messageId: string | null;
  taskId: string | null;
  parentAssetId: string | null;
  metadata: Record<string, unknown>;
  createdAt: number;
}

export type TaskKind = 'image' | 'threed' | 'video';
export type TaskStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'interrupted' | 'paused';

export interface GenerationTask {
  id: string;
  kind: TaskKind;
  status: TaskStatus;
  modelRef: ModelRef;
  params: Record<string, unknown>;
  progress: number;
  progressLabel: string | null;
  error: string | null;
  resultAssetIds: string[];
  chatId: string | null;
  externalId: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface FileOperation {
  id: string;
  rootId: string;
  op: 'mkdir' | 'rename' | 'move' | 'copy' | 'trash';
  srcPath: string;
  dstPath: string | null;
  status: 'done' | 'undone' | 'failed';
  groupId: string | null;
  chatId: string | null;
  metadata: Record<string, unknown>;
  createdAt: number;
  undoneAt: number | null;
}

export interface DownloadRecord {
  id: string;
  category: ModelCategory;
  name: string;
  url: string;
  destPath: string;
  totalBytes: number | null;
  receivedBytes: number;
  sha256Expected: string | null;
  status: 'queued' | 'downloading' | 'paused' | 'verifying' | 'completed' | 'failed' | 'cancelled';
  error: string | null;
  meta: Record<string, unknown>;
  createdAt: number;
  updatedAt: number;
}
