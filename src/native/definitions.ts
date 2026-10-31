// TypeScript contracts for the ZinoNative Swift plugins (native/zino-native/ios/Sources/ZinoNative).
import type { PluginListenerHandle } from '@capacitor/core';

export interface ZinoDatabasePlugin {
  open(o: { name: string }): Promise<{ path: string }>;
  close(): Promise<void>;
  execute(o: { sql: string }): Promise<{ changes: number }>;
  run(o: { sql: string; values: unknown[] }): Promise<{ changes: number; lastId: number }>;
  query(o: { sql: string; values: unknown[] }): Promise<{ rows: Record<string, unknown>[] }>;
  batch(o: { statements: { sql: string; values: unknown[] }[] }): Promise<{ changes: number }>;
}

export interface ZinoKeychainPlugin {
  set(o: { account: string; secret: string }): Promise<{ masked: string }>;
  has(o: { account: string }): Promise<{ exists: boolean; masked?: string }>;
  remove(o: { account: string }): Promise<void>;
}

export interface HttpAuth {
  account: string;
  type?: 'header' | 'query';
  name?: string;
  prefix?: string;
}

export interface MultipartPart {
  name: string;
  value?: string;
  filename?: string;
  contentType?: string;
  base64?: string;
  appPath?: string;
}

export interface HttpRequestOptions {
  id?: string;
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  bodyBase64?: string;
  multipart?: MultipartPart[];
  auth?: HttpAuth;
  stream?: boolean;
  responseType?: 'text' | 'base64' | 'file';
  saveTo?: string;
  timeoutSeconds?: number;
}

export interface HttpResponse {
  status: number;
  headers: Record<string, string>;
  body?: string;
  base64?: string;
  path?: string;
  size?: number;
  streamed?: boolean;
}

export interface ZinoHttpPlugin {
  request(o: HttpRequestOptions): Promise<HttpResponse>;
  cancel(o: { id: string }): Promise<{ cancelled: boolean }>;
  addListener(event: 'httpChunk', fn: (e: { id: string; chunk: string }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'httpStart', fn: (e: { id: string; status: number }) => void): Promise<PluginListenerHandle>;
}

export interface FileEntry {
  path: string;
  name: string;
  isDirectory: boolean;
  size: number;
  modified: string | null;
  created?: string | null;
  ext: string;
}

export interface FolderRoot { id: string; name: string; accessible: boolean }

export interface ZinoFilesPlugin {
  pickFolder(): Promise<{ id: string; name: string }>;
  listRoots(): Promise<{ roots: FolderRoot[] }>;
  removeRoot(o: { rootId: string }): Promise<void>;
  list(o: { rootId: string; path?: string; recursive?: boolean; includeHidden?: boolean; limit?: number }): Promise<{ entries: FileEntry[]; truncated: boolean }>;
  stat(o: { rootId: string; path: string }): Promise<(FileEntry & { exists: true }) | { exists: false }>;
  readText(o: { rootId: string; path: string; maxBytes?: number }): Promise<{ text: string; truncated: boolean; format: string; pages?: number }>;
  hash(o: { rootId: string; path: string }): Promise<{ sha256: string }>;
  mkdir(o: { rootId: string; path: string }): Promise<{ path: string }>;
  rename(o: { rootId: string; path: string; newName: string }): Promise<{ from: string; to: string }>;
  move(o: { rootId: string; path: string; destinationDir: string }): Promise<{ from: string; to: string }>;
  copy(o: { rootId: string; path: string; destinationDir: string; newName?: string }): Promise<{ from: string; to: string }>;
  trash(o: { rootId: string; path: string }): Promise<{ from: string; to: string }>;
  restore(o: { rootId: string; path: string; to: string }): Promise<{ from: string; to: string }>;
  importToApp(o: { rootId: string; path: string; dest: string }): Promise<{ path: string }>;
}

export interface ImportedFile { path: string; name: string; originalName: string; size: number; isDirectory: boolean }

export interface ZinoStoragePlugin {
  info(): Promise<{ root: string; available: number; total: number }>;
  writeBase64(o: { path: string; data: string; overwrite?: boolean }): Promise<{ path: string; size: number }>;
  readBase64(o: { path: string }): Promise<{ data: string }>;
  writeText(o: { path: string; text: string }): Promise<{ path: string }>;
  readText(o: { path: string }): Promise<{ text: string }>;
  stat(o: { path: string }): Promise<{ exists: boolean; isDirectory?: boolean; size?: number; modified?: string | null }>;
  list(o: { path: string }): Promise<{ entries: { path: string; name: string; isDirectory: boolean; size: number }[] }>;
  remove(o: { path: string }): Promise<{ removed: boolean }>;
  copy(o: { from: string; to: string }): Promise<{ path: string }>;
  move(o: { from: string; to: string }): Promise<{ path: string }>;
  fileUrl(o: { path: string }): Promise<{ url: string }>;
  hash(o: { path: string }): Promise<{ sha256: string }>;
  unzip(o: { path: string; destination: string }): Promise<{ path: string }>;
  directorySize(o: { path: string }): Promise<{ size: number }>;
  clearTemp(): Promise<{ freed: number }>;
  pickAndImport(o: { kind: 'gguf' | 'image' | 'model3d' | 'video' | 'coreml' | 'zip' | 'folder' | 'any'; destDir: string; multiple?: boolean }): Promise<{ files: ImportedFile[] }>;
  share(o: { path: string }): Promise<{ completed: boolean }>;
}

export interface GGUFInfo {
  architecture: string;
  version: number;
  tensorCount: number;
  fileSize: number;
  name?: string;
  basename?: string;
  sizeLabel?: string;
  license?: string;
  fileType?: number;
  contextLength?: number;
  blockCount?: number;
  embeddingLength?: number;
  headCount?: number | { arrayLength: number };
  headCountKv?: number | { arrayLength: number };
  keyLength?: number;
  valueLength?: number;
  slidingWindow?: number;
  expertCount?: number;
  hasChatTemplate: boolean;
  chatTemplate?: string;
  tokenizerModel?: string;
  isSplit: boolean;
}

export interface LlamaModelInfo {
  description: string;
  architecture: string;
  name: string;
  contextLength: number;
  trainedContextLength: number;
  parameters: number;
  modelBytes: number;
  layers: number;
  embedding: number;
  hasChatTemplate: boolean;
  gpuOffloadSupported: boolean;
  loadMs?: number;
  path?: string;
  loaded?: boolean;
}

export interface LlamaGenerateResult {
  text: string;
  promptTokens: number;
  reusedPromptTokens: number;
  completionTokens: number;
  stopReason: 'eos' | 'max_tokens' | 'stop' | 'cancelled' | 'context_full' | 'error';
  promptMs: number;
  generationMs: number;
  tokensPerSecond: number;
  contextUsed: number;
  contextLength: number;
}

export interface ZinoLlamaPlugin {
  inspect(o: { path: string }): Promise<GGUFInfo>;
  load(o: { path: string; contextLength?: number; batchSize?: number; threads?: number; gpuLayers?: number; flashAttention?: boolean }): Promise<LlamaModelInfo>;
  unload(): Promise<{ unloaded: boolean }>;
  status(): Promise<LlamaModelInfo | { loaded: false }>;
  tokenize(o: { text?: string; texts?: string[] }): Promise<{ counts: number[]; count: number }>;
  applyTemplate(o: { messages: { role: string; content: string }[]; addAssistant?: boolean }): Promise<{ prompt?: string; templateApplied: boolean }>;
  generate(o: {
    id: string; prompt: string; maxTokens?: number; temperature?: number; topK?: number; topP?: number;
    minP?: number; repeatPenalty?: number; repeatLastN?: number; seed?: number; stop?: string[];
  }): Promise<LlamaGenerateResult>;
  cancel(o: { id: string }): Promise<void>;
  benchmark(o: { promptTokens?: number; genTokens?: number }): Promise<{ promptTokens: number; promptTokensPerSecond: number; generatedTokens: number; generationTokensPerSecond: number }>;
  addListener(event: 'token', fn: (e: { id: string; text: string }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'loadProgress', fn: (e: { progress: number }) => void): Promise<PluginListenerHandle>;
}

export interface DiffusionValidation {
  valid: boolean;
  missing: string[];
  isXL: boolean;
  supportsImageToImage: boolean;
  chunkedUnet: boolean;
  hasSafetyChecker: boolean;
  hasUncompiledPackages: boolean;
  nativeSize: number | null;
  resourcePath: string;
}

export interface ZinoDiffusionPlugin {
  validate(o: { path: string }): Promise<DiffusionValidation>;
  load(o: { path: string; computeUnits?: string; reduceMemory?: boolean }): Promise<{ loaded: boolean; isXL: boolean; loadMs: number; nativeSize: number | null; supportsImageToImage: boolean }>;
  unload(): Promise<{ unloaded: boolean }>;
  status(): Promise<{ loaded: boolean; path: string | null; isXL: boolean; nativeSize: number | null }>;
  generate(o: {
    id: string; prompt: string; negativePrompt?: string; steps?: number; guidanceScale?: number; imageCount?: number;
    seed?: number; scheduler?: 'dpmpp' | 'pndm'; startingImage?: string; strength?: number; outputDir: string;
  }): Promise<{ images: { path: string; width: number; height: number }[]; seed: number; filteredBySafetyChecker: number; durationMs: number }>;
  cancel(o: { id: string }): Promise<void>;
  addListener(event: 'progress', fn: (e: { id: string; step: number; stepCount: number }) => void): Promise<PluginListenerHandle>;
}

export interface ZinoDownloadsPlugin {
  start(o: { id: string; url: string; dest: string; expectedSize?: number; sha256?: string; headers?: Record<string, string>; authAccount?: string }): Promise<{ started: boolean }>;
  pause(o: { id: string }): Promise<{ paused: boolean; resumable?: boolean }>;
  cancel(o: { id: string }): Promise<{ cancelled: boolean }>;
  active(): Promise<{ running: string[]; resumable: string[] }>;
  addListener(event: 'progress', fn: (e: { id: string; received: number; total: number; bytesPerSecond: number }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'verifying', fn: (e: { id: string }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'complete', fn: (e: { id: string; path: string; size: number; sha256: string; verified: boolean }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'error', fn: (e: { id: string; code: string; message: string; resumable: boolean }) => void): Promise<PluginListenerHandle>;
}

export interface ResourceSnapshot {
  physicalMemory: number;
  appFootprint: number;
  availableMemory: number;
  thermalState: 'nominal' | 'fair' | 'serious' | 'critical' | 'unknown';
  lowPowerMode: boolean;
  processorCount: number;
  storageAvailable: number;
  storageTotal: number;
  deviceModel: string;
  systemVersion: string;
  timestamp: number;
  /** True when values come from a browser approximation rather than iPadOS. */
  estimated?: boolean;
}

export interface ZinoResourcesPlugin {
  snapshot(): Promise<ResourceSnapshot>;
  addListener(event: 'memoryWarning', fn: (e: ResourceSnapshot) => void): Promise<PluginListenerHandle>;
  addListener(event: 'memoryPressure', fn: (e: ResourceSnapshot & { level: 'normal' | 'warning' | 'critical' }) => void): Promise<PluginListenerHandle>;
  addListener(event: 'thermalChange', fn: (e: { thermalState: ResourceSnapshot['thermalState'] }) => void): Promise<PluginListenerHandle>;
}

export interface CoreMLFeature { name: string; type: string; optional: boolean; shape?: number[]; width?: number; height?: number }

export interface ZinoCoreMLPlugin {
  inspect(o: { path: string }): Promise<{ compiledPath: string; inputs: CoreMLFeature[]; outputs: CoreMLFeature[]; author: string; description: string; license: string; version: string }>;
}
