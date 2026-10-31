# ZinoAgent

An AI workspace for iPad Pro (M2, 8 GB) that works **offline and online**: chat with local GGUF
models or cloud APIs, manage files with an AI agent, and generate images, 3D models and video —
with a context engine that makes small local context windows genuinely useful.

Built with **Capacitor 8 · React 19 · TypeScript · native Swift plugins · SQLite · llama.cpp (Metal)
· Core ML · Three.js**, and compiled into an iPad app by **GitHub Actions** so you can develop
entirely from Windows.

> **Honest status.** Everything below marked *Implemented* exists in code and compiles; *Tested*
> means automated tests and/or CI builds — **not** on-device verification. Nothing has been run on a
> physical iPad yet, and no performance numbers are published until you measure them with the
> built-in benchmark. The same table is in the app under **Settings → Feature status**.

| Area | Feature | Status | Notes |
|---|---|---|---|
| Foundation | 7-section iPad layout, light/dark, portrait/landscape | Implemented | Typechecked, built, smoke-tested in Chromium. |
| Foundation | SQLite + migrations + crash recovery | Implemented, Tested | Native SQLite3 plugin compiles in CI; schema tested with sql.js. |
| Chat | History: new, rename, search, pin, archive, folders, export, delete (three-dot menu) | Implemented, Tested | |
| Chat | Offline GGUF chat (llama.cpp b12020, Metal) | Implemented, Experimental | Swift bridge compiles for device + simulator. Needs on-device run. |
| Chat | Cloud chat: Gemini, OpenAI, Claude, OpenAI-compatible | Implemented, Requires configuration | Streaming/tool-call parsing unit-tested; end-to-end tested against a mock OpenAI-compatible server. Not verified with live accounts. |
| Chat | Tool calling: cloud (native function calling) / offline (prompt protocol) | Implemented / Experimental | |
| Models | Unified model selector, defaults, Auto mode (offline-first, never cloud without permission) | Implemented, Tested | |
| Models | Effort levels mapped to each model's real controls | Implemented, Tested | Unsupported controls are reported, not faked. |
| Context | SmartContextEngine (adaptive batches, verified summaries, originals preserved, retrieval, compaction, multi-level memory) | Implemented, Tested | |
| Files | Files picker, security-scoped bookmarks, path validation, coordinated I/O | Implemented | Compiles; needs on-device testing. |
| Files | AI file tools, safety policy, cloud privacy gating, undo journal | Implemented, Tested | |
| Image | Offline: Core ML Stable Diffusion (apple/ml-stable-diffusion 1.1.1) | Implemented, Experimental | Requires a compiled Core ML model. |
| Image | Cloud: OpenAI Images, Gemini / Imagen, Stability AI, OpenAI-compatible | Implemented, Requires configuration | |
| 3D | Three.js viewer: GLB/GLTF/OBJ, orbit/zoom/pan, wireframe/solid/textured, lighting, materials, stats, animations, fullscreen | Implemented | |
| 3D | Cloud: Meshy, Tripo, Stable Fast 3D | Implemented, Requires configuration | |
| 3D | **Offline 3D generation** | **Not implemented** | No iPadOS-compatible runtime exists in this build. Imported models are inspected and reported *Unsupported*. |
| Video | Cloud: OpenAI Sora, Google Veo, Runway (image→video) | Implemented, Requires configuration | Jobs resume after an app restart. |
| Video | **Offline video generation** | **Not implemented** | Not feasible within an 8 GB iPad app memory budget. |
| Assets | Unified library: search, sort, filter, preview, rename, delete, export, chat links, metadata | Implemented | |
| Downloads | Pause/resume, SHA-256 + size verification, storage checks | Implemented | Checksums come from Hugging Face metadata. |
| Resources | RAM / pressure / thermal monitoring, one heavy model, idle unload, queue pausing | Implemented | |
| Security | API keys in Keychain, injected natively; never in DB, logs, chats or exports | Implemented, Tested | |
| Build | GitHub Actions: simulator build, unsigned device IPA, signed IPA | Implemented, Tested | Simulator + unsigned device builds succeed in CI. Signed IPA needs your Apple secrets. |

---

## 1. Windows → GitHub → iPad

You never need a Mac. Every push builds the app on a GitHub macOS runner.

1. **Push** to any branch (or run **Actions → iOS build → Run workflow** and pick a mode).
2. The workflow runs: typecheck → unit tests → web build → builds `llama.xcframework` from llama.cpp
   `b12020` (cached after the first run, ~8 min) → `cap sync` → Xcode builds.
3. Download the artifacts from the workflow run page:

| Artifact | What it is | Installable on iPad? |
|---|---|---|
| `ZinoAgent-simulator-app` | iOS Simulator build | **No** — compile check only |
| `ZinoAgent-unsigned-ipa` | Real iPad build, not signed | Only after re-signing (see 2a) |
| `ZinoAgent-signed-ipa` | Signed with your certificate + profile | **Yes** (see 2b) |
| `xcodebuild-logs` | Full build logs | — |

### 2a. Install without a paid Apple Developer account

The unsigned IPA has to be signed before iPadOS will run it. On Windows you can use a sideloading tool
such as **Sideloadly** or **AltStore** with your Apple ID. With a free Apple ID, apps expire after
7 days and must be re-signed, and capabilities like the increased memory limit are unavailable.
These are third-party tools: review them before giving them your Apple ID.

### 2b. Signed builds (paid Apple Developer account)

Everything below is done in a browser + OpenSSL on Windows.

1. **Certificate**: create a key and CSR, upload the CSR at *developer.apple.com → Certificates → +
   → Apple Development* (or *Apple Distribution* for Ad Hoc), download the `.cer`, then:
   ```powershell
   openssl req -new -newkey rsa:2048 -nodes -keyout zino.key -out zino.csr -subj "/CN=Your Name/emailAddress=you@example.com"
   # …upload zino.csr, download development.cer…
   openssl x509 -inform DER -in development.cer -out zino.pem
   openssl pkcs12 -export -legacy -inkey zino.key -in zino.pem -out zino.p12
   ```
2. **App ID**: register an explicit App ID (e.g. `com.yourname.zinoagent`). Optionally enable
   **Increased Memory Limit** (recommended for 7B models).
3. **Device**: register your iPad's UDID (*Devices → +*).
4. **Profile**: create an *iOS App Development* (or *Ad Hoc*) profile for that App ID + certificate +
   iPad, and download the `.mobileprovision`.
5. **GitHub secrets** (*Settings → Secrets and variables → Actions*):

   | Secret | Value |
   |---|---|
   | `IOS_CERTIFICATE_P12_BASE64` | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("zino.p12"))` |
   | `IOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
   | `IOS_PROVISIONING_PROFILE_BASE64` | base64 of the `.mobileprovision` |

   Optional **variables**: `IOS_EXPORT_METHOD` (`development` default, `release-testing` for Ad Hoc),
   `IOS_INCREASED_MEMORY_LIMIT=true` if the App ID has that capability.
6. Run the workflow with mode `signed-device`. The bundle identifier is taken from your profile.
   From Windows, install the signed IPA with a tool that can install an already-signed IPA over
   USB (several sideloading tools can), or use an Ad Hoc over-the-air install page or your MDM.
   For TestFlight, export with `app-store-connect` and upload with Apple's Transporter tooling.

Signing material is only ever decoded into a temporary keychain on the runner and deleted afterwards.
Never commit certificates, keys or profiles (they are git-ignored).

---

## 2. Models you need

ZinoAgent ships **no** models. Import your own (Files picker) or download from **Models**.

| Library | Format | Where to get it | Notes |
|---|---|---|---|
| Chat | `.gguf` (Q4_K_M or Q5_K_M recommended) | Hugging Face, e.g. `bartowski/Llama-3.2-3B-Instruct-GGUF` | Compatibility is checked against llama.cpp b12020 and the memory iPadOS currently allows. 1–4B models are comfortable on 8 GB; 7B is borderline. |
| Image | Compiled Core ML Stable Diffusion (`TextEncoder.mlmodelc`, `Unet*.mlmodelc`, `VAEDecoder.mlmodelc`, `vocab.json`, `merges.txt`) | `apple/coreml-stable-diffusion-2-1-base-palettized` (split_einsum, compiled zip) | Fixed resolution per model (512×512 for SD 2.1 base). Image-to-image needs `VAEEncoder.mlmodelc`. |
| 3D / Video | Core ML packages | — | Inspected only; no on-device generation runtime (see status). |

Downloads read the exact size and SHA-256 from the Hugging Face API, verify both after download and
discard mismatches. Gated repositories need a Hugging Face token (Settings → Privacy, stored in the
Keychain). Check each model's licence.

## 3. Provider credentials

Add providers in **Settings → AI providers & keys**. Each of the four categories (Chat, Image, 3D,
Video) has its own providers; one key can be reused across categories.

| Category | Providers | Key from |
|---|---|---|
| Chat | Google Gemini, OpenAI, Anthropic Claude, any OpenAI-compatible endpoint (OpenRouter, Groq, LM Studio, Ollama…) | aistudio.google.com · platform.openai.com · platform.claude.com · your provider |
| Image | OpenAI Images, Gemini / Imagen, Stability AI, OpenAI-compatible | as above · platform.stability.ai |
| 3D | Meshy, Tripo, Stability (Stable Fast 3D) | meshy.ai · platform.tripo3d.ai · platform.stability.ai |
| Video | OpenAI (Sora), Google (Veo), Runway | as above · dev.runwayml.com |

"Test connection" makes a real authenticated request and refreshes the model list; capabilities
come from the provider's model API where available (Anthropic and Gemini report them; OpenAI's are
inferred from model ids; Stability/Meshy/Tripo/Runway use a built-in list — marked as such).
Calls go directly from the iPad to the provider with your own key — there is no ZinoAgent server.
Plain `http://` is allowed only for local-network servers.

---

## 4. Architecture

```
src/
  app/            Agent · Images · ThreeDStudio · VideoStudio · Models · Assets · Settings · ChatHistory
  components/     ModelSelector · EffortSelector · ContextMonitor · RamMonitor · FileExplorer · ThreeDViewer · …
  services/
    ai-router/        turn loop, effort mapping, Auto mode, local llama chat + tool protocol
    context-engine/   SmartContextEngine: batcher, verifier, retrieval (BM25), tokenizers
    file-manager/     tool schema, executor + safety policy, journal + undo
    provider-manager/ providers, Keychain keys, connection tests, model discovery
    model-manager/    import/inspect/load/benchmark offline models
    download-manager/ Hugging Face resolution, pause/resume, verification
    generation/       persistent queue + image/3D/video services
    asset-manager/    unified asset library
    resources/        RAM/thermal telemetry + heavy-model coordinator
  providers/      chat/ image/ three-d/ video/ adapters + native HTTP client + SSE parser
  models/         GGUF compatibility, download catalog, local adapter registry
  database/       driver (native SQLite / sql.js), migrations, repositories
  native/         plugin contracts + browser fallbacks for development
native/zino-native/            Swift package linked into the app by Capacitor (SPM)
  ios/Sources/ZinoNative/      Database · Keychain · Http · Files · Storage · Llama · Diffusion · Downloads · Resources · CoreML
ios/                           Capacitor iOS project (iPadOS 17+, iPad only)
.github/workflows/ios-build.yml
scripts/build-llama-xcframework.sh
tests/                         Vitest unit + integration tests
```

**How native code reaches the app target.** `native/zino-native` is a local Capacitor plugin with a
`Package.swift`. `npx cap sync ios` adds it to `ios/App/CapApp-SPM`, which the App target links, and
writes every `@objc` plugin class to `packageClassList` so Capacitor registers them at launch. CI
compiles all of it with Xcode for both simulator and device.

### SmartContextEngine
* **Adaptive batching** — 5 messages is a reference, not a rule: batch size follows token counts, the
  model's usable context, important instructions and memory pressure; batches end on complete
  exchanges and never split a tool call from its result.
* **Verified summaries** — names, numbers, file names, URLs, user instructions and open tasks are
  extracted from the originals and checked in the summary; invented numbers fail verification. On
  failure: retry with explicit feedback → append the original sentences verbatim → otherwise keep the
  batch's original messages in context. Optional model-based cross-check at High/Maximum effort.
* **Originals are never deleted** — every summary references its batch and message ids; exports
  include originals.
* **Smart retrieval** — simple questions use summaries + recent messages; questions about earlier
  details retrieve whole original batches (offline BM25).
* **Compaction** at a configurable 85–90% of the usable budget; summaries that grow large are rolled
  up into higher-level summaries; durable instructions/decisions become long-term memory.
* **Dashboard** — capacity, usage, remaining, and a breakdown by system/memory/summaries/retrieved/
  recent/tool tokens, labelled *exact* (llama.cpp tokenizer) or *estimated* (cloud).

Summarisation makes better use of the window; it does not raise the model's native context limit.

### Security & privacy
* API keys are written once to the iOS Keychain and **never returned to JavaScript**: the native HTTP
  and download plugins inject them per request and scrub them from error text.
* The AI never runs shell commands. File tools are structured requests validated in TypeScript and
  again in Swift (authorised folder only, no `..`, symlink-escape checks, no overwrites). Deletes go
  to a `.ZinoAgent Trash` folder; every change is journaled and undoable after checking current state.
* Cloud models get no file-system access; file names need per-chat permission, file contents per-file
  permission. Auto never goes online without explicit permission. No telemetry.
* Downloaded models are treated as untrusted data: verified, then only parsed by llama.cpp/Core ML.

---

## 5. Development on Windows

```bash
npm ci
npm run dev        # browser preview (Chrome/Edge): UI, cloud providers, folder tools via File System Access API
npm test           # 55 unit/integration tests
npm run typecheck
npm run build
```

The browser preview uses web fallbacks: sql.js persisted to IndexedDB, a session-only dev key store
(not the Keychain), and Chrome's folder picker. llama.cpp, Core ML and native downloads are
iPad-only and say so. Cloud calls from the browser are subject to the provider's CORS policy; on iPad
they go through native HTTP and are not.

## 6. Performance on iPad Pro M2

No numbers are claimed here. Use **Models → Chat → Benchmark** on the device: it loads the model and
measures real prompt-processing and generation tokens/second, load time and app memory, and stores
the result with the model. **Models → RAM & resources** shows live footprint, the memory iPadOS still
allows (`os_proc_available_memory`), pressure and thermal state.

## 7. Known limitations
* Not yet run on a physical iPad; first device runs may surface issues the simulator/CI cannot.
* Offline 3D and video generation are not available (see status table).
* Offline tool calling depends on the model following the `<tool_call>` protocol.
* Core ML diffusion models are compiled for a fixed resolution; other sizes need another model.
* Cloud adapters follow published APIs as of this build; providers change APIs — test connections.

See `docs/DEVLOG.md` for the build log and decisions.
