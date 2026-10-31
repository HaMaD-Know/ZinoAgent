# ZinoAgent development log

## 2026-10-31 — Initial build

### Environment
* Repository was empty. Development container: Linux, Node 22.23, npm 10.9 — no Swift/Xcode, so all
  native compilation is verified on GitHub's `macos-26` runner (Xcode 26.6, Swift 6.3.3).
* Hugging Face and api.github.com were blocked from the container; GitHub git access worked, so
  llama.cpp and apple/ml-stable-diffusion were cloned at pinned tags to write the Swift bridges against
  their real headers/APIs.

### Key decisions
* **Native integration via a local Capacitor SPM plugin** (`native/zino-native`). Capacitor 8's CLI adds
  it to `CapApp-SPM` and registers every `@objc` plugin class, so the Swift code is genuinely compiled
  into the App target without hand-editing the pbxproj.
* **llama.cpp pinned to `b12020`** (commit `0ec4027a…`). Its official release xcframework no longer
  contains a simulator slice, so CI builds `llama.xcframework` (device + simulator, Metal) from source
  and caches it. The bridge was written against this tag's `llama.h` — notably `llama_model_params`
  no longer has `use_mmap`, and `llama_sampler_init_penalties` now takes `n_vocab` first.
* **Own SQLite plugin** over system SQLite3 instead of a SQLCipher-based community plugin: fewer
  dependencies, full control over errors. sql.js provides the same driver interface for the browser
  preview and tests.
* **Keys never enter JavaScript on iPad**: `ZinoHttp`/`ZinoDownloads` inject Keychain secrets natively
  and scrub them from errors. Raw HTTP is used for all providers for that reason (no SDK in the WebView).
* **Anthropic**: adaptive thinking + `output_config.effort` on models that report it (4.6+);
  `budget_tokens` only for older models; no sampling parameters; refusals surfaced as errors.
* **Honesty over coverage**: no on-device 3D/video generation runtime exists for iPadOS, so those
  libraries inspect imported Core ML packages and report "Unsupported" via an empty adapter registry
  rather than pretending.

### Verification so far
* CI run #1: llama.xcframework built (~8 min); `** BUILD SUCCEEDED **` for both the iOS Simulator and
  the iphoneos (device) builds; unsigned IPA artifact produced. Signed build skipped (no secrets).
* 55 Vitest tests: SmartContextEngine (compaction, verification retry/verbatim fallback, retrieval,
  original preservation, roll-ups), provider manager (Keychain-only keys, capability filtering, key
  reuse), streaming adapters (OpenAI/Anthropic/Gemini SSE incl. tool calls, thinking, signatures),
  effort mapping, Auto mode guarantees, file tools (path safety, confirmations, privacy gating, undo),
  chat history, migrations and crash recovery.
* Browser end-to-end (Playwright + mock OpenAI-compatible server): add provider → connection test →
  select model → streamed reply → persistence across reload; all seven sections render without errors.

### Bugs found by tests / runs and fixed
* `INSERT OR REPLACE` on `providers` cascade-deleted the fetched model list (REPLACE deletes the row
  first). Switched to `ON CONFLICT DO UPDATE`.
* Batch planner's hard size cap could split a tool call from its result.
* File-operation journal ordered only by millisecond timestamp, so undo could run out of order.
* zustand v5 selectors returning fresh arrays caused an infinite render loop in the studios.
* Auto-effort under-weighted prompts with several reasoning signals.

### Not yet done / next
* First run on a physical iPad Pro M2: load a GGUF model, benchmark, test memory warnings, Files
  picker bookmarks, Core ML diffusion, share sheet.
* Live tests with real provider keys (Gemini, OpenAI, Claude, Stability, Meshy, Tripo, Runway, Veo).
