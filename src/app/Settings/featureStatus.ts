// Single source of truth for the feature status shown in Settings › Feature status and the README.
// "Tested" means automated tests and/or CI compilation; nothing here claims on-device verification
// unless it says so.

export type Status = 'implemented' | 'tested' | 'needs-config' | 'experimental' | 'not-implemented';

export interface FeatureRow { area: string; feature: string; status: Status[]; note: string }

export const FEATURES: FeatureRow[] = [
  { area: 'Foundation', feature: 'Navigation (7 sections), responsive iPad layout, light/dark', status: ['implemented'], note: 'Typechecked and built in CI; visual QA on device pending.' },
  { area: 'Foundation', feature: 'SQLite persistence + migrations + crash recovery', status: ['implemented', 'tested'], note: 'Native SQLite3 plugin compiles in CI; schema/repositories tested with sql.js.' },
  { area: 'Chat', feature: 'Chat history: new, rename, search, pin, archive, folders, export, delete', status: ['implemented', 'tested'], note: 'Repository behaviour unit-tested.' },
  { area: 'Chat', feature: 'Offline GGUF chat via llama.cpp (Metal)', status: ['implemented', 'experimental'], note: 'Swift bridge against llama.cpp b12020 compiles for device + simulator in CI. Needs on-device run to confirm speed/memory.' },
  { area: 'Chat', feature: 'Cloud chat: Gemini, OpenAI, Claude, OpenAI-compatible', status: ['implemented', 'needs-config'], note: 'Adapters follow published APIs; SSE parsing unit-tested. Requires your API key; not verified against live accounts in CI.' },
  { area: 'Chat', feature: 'Tool calling (file tools) — cloud', status: ['implemented', 'needs-config'], note: 'Native function calling for OpenAI, Anthropic, Gemini.' },
  { area: 'Chat', feature: 'Tool calling — offline models', status: ['implemented', 'experimental'], note: 'Prompt-based <tool_call> protocol; reliability depends on the model.' },
  { area: 'Models', feature: 'Unified model selector (offline/online, search, capabilities, compatibility, defaults)', status: ['implemented'], note: '' },
  { area: 'Models', feature: 'Auto mode (local-first, never cloud without permission)', status: ['implemented', 'tested'], note: '' },
  { area: 'Models', feature: 'Effort levels mapped to real provider/model controls', status: ['implemented', 'tested'], note: 'Unsupported controls are reported, not faked.' },
  { area: 'Context', feature: 'SmartContextEngine: adaptive batches, verified summaries, originals preserved, retrieval, compaction, multi-level memory', status: ['implemented', 'tested'], note: 'Covered by unit/integration tests with a mock summariser.' },
  { area: 'Context', feature: 'Exact token counts (llama.cpp tokenizer) / estimates for cloud', status: ['implemented'], note: 'Cloud counts are labelled "Estimated".' },
  { area: 'Files', feature: 'Native Files picker, security-scoped bookmarks, path validation, file coordination', status: ['implemented'], note: 'Compiles in CI; on-device testing pending.' },
  { area: 'Files', feature: 'AI file tools, safety policy, privacy gating, undo journal', status: ['implemented', 'tested'], note: 'Executor + journal + undo tested against an in-memory file system.' },
  { area: 'Image', feature: 'Offline image generation (Core ML Stable Diffusion)', status: ['implemented', 'experimental'], note: 'apple/ml-stable-diffusion 1.1.1 compiles in CI. Needs a compiled Core ML model and on-device testing.' },
  { area: 'Image', feature: 'Cloud image: OpenAI, Gemini/Imagen, Stability, OpenAI-compatible', status: ['implemented', 'needs-config'], note: 'Requires API keys; not verified against live accounts in CI.' },
  { area: '3D', feature: 'Three.js viewer (GLB/GLTF/OBJ, orbit/zoom/pan, modes, lighting, stats, materials, animations)', status: ['implemented'], note: '' },
  { area: '3D', feature: 'Cloud 3D: Meshy, Tripo, Stable Fast 3D', status: ['implemented', 'needs-config'], note: 'Requires API keys.' },
  { area: '3D', feature: 'Offline 3D generation', status: ['not-implemented'], note: 'No iPadOS-compatible runtime exists in this build; imported models are inspected and reported unsupported.' },
  { area: 'Video', feature: 'Cloud video: OpenAI Sora, Google Veo, Runway (image→video)', status: ['implemented', 'needs-config'], note: 'Requires API keys; long-running jobs resume after restart.' },
  { area: 'Video', feature: 'Offline video generation', status: ['not-implemented'], note: 'Not feasible within an 8 GB iPad app memory budget; no runtime integrated.' },
  { area: 'Assets', feature: 'Unified asset library (search, sort, filter, preview, rename, delete, export, chat links, metadata)', status: ['implemented'], note: '' },
  { area: 'Downloads', feature: 'Model downloads: pause/resume, SHA-256 + size verification, storage checks', status: ['implemented'], note: 'Native URLSession implementation compiles in CI; checksums come from Hugging Face metadata.' },
  { area: 'Resources', feature: 'RAM/thermal/pressure monitoring, one heavy model, idle unload, queue pausing', status: ['implemented'], note: 'Values come from iPadOS APIs on device.' },
  { area: 'Security', feature: 'API keys in Keychain, injected natively; never in DB/logs/chats', status: ['implemented'], note: '' },
  { area: 'Build', feature: 'GitHub Actions: simulator build, unsigned device IPA, signed IPA', status: ['implemented', 'tested'], note: 'Simulator + unsigned device builds succeed in CI. Signed IPA requires your Apple signing secrets.' },
  { area: 'Performance', feature: 'Benchmarks on iPad Pro M2', status: ['implemented', 'needs-config'], note: 'Benchmark tool measures real numbers on device; none are published until measured.' },
];

export const STATUS_LABEL: Record<Status, string> = {
  implemented: 'Implemented', tested: 'Tested', 'needs-config': 'Requires user configuration', experimental: 'Experimental', 'not-implemented': 'Not yet implemented',
};
