# ZinoAgent 2.0 — System Architecture

## Overview

ZinoAgent 2.0 is a ground-up native **Swift & SwiftUI** rebuild for **iPadOS 17+** (primary target: iPad Pro M2, 8 GB RAM, Apple Silicon, Metal) and **iOS 17+**. It replaces the earlier v1 Capacitor/React/TypeScript prototype (`claude/zinoagent-build` branch) with a modular native MVVM + services architecture.

## Architectural Layers

```text
ZinoAgent/
├── App/            # SwiftUI App entry, AppCoordinator DI container, adaptive RootNavigationView
├── Core/           # Theme, ZinoError & SecretRedactor, AppLogger, Keychain, SQLite3 + Migrations,
│                   # AppStoragePaths, SystemResourceMonitor, HTTPClient (HTTPS + SSE), DocumentTextExtractor
├── AI/
│   ├── Core/       # Shared domain models & OnlineAIProviderAdapter protocol
│   ├── OfflineEngine/      # llama.cpp b12020 Metal runtime + ChatTemplateFormatter
│   ├── OnlineEngine/       # OnlineAIEngine streaming/image dispatcher
│   ├── Providers/          # OpenAI (+ OpenAI-compatible), Anthropic, Google Gemini adapters & ProviderRegistry
│   ├── ModelRegistry/      # Pure-Swift GGUF v2/v3 header parser, RAM compatibility check, DownloadManager, Catalog
│   ├── SmartContextEngine/ # Model-aware tokenizer, adaptive batching, NaturalLanguage + TF-IDF retrieval,
│   │                       # summary generator & fact-retention verifier
│   └── ToolSystem/         # 11 permission-aware AI file tools with preview-and-confirm workflow
├── Services/
│   ├── FileAccessService/      # Security-scoped bookmarks, scoped file ops, recoverable .zino_trash undo journal
│   ├── PermissionService/      # Global + per-folder AI permissions, online upload consent, audit log
│   ├── ImageGenerationService/ # Online image adapters + optional offline Core ML Stable Diffusion (SD 1.5/2.1/XL)
│   ├── ThreeDService/          # Native Swift glTF 2.0/GLB parser + ModelIO/SceneKit (USDZ, OBJ, STL) + project persistence
│   └── ExportService/          # Secret-scrubbed Markdown/JSON conversation & workspace exports
├── Features/       # 7 MVVM SwiftUI feature modules (Home, FileManager, AIChat, ModelManager, ImageStudio, ThreeDStudio, Settings)
├── Resources/      # Info.plist, ZinoAgent.entitlements, Assets.xcassets, Localizations
└── Tests/          # UnitTests, IntegrationTests, UITests
```

## Key Technical Decisions

1. **Pure Native Swift/SwiftUI (iOS 17+)**: Eliminates WebView/Capacitor bridge overhead, unlocks direct Metal access, native PDFKit, native SceneKit/ModelIO rendering, native SwiftUI adaptive `NavigationSplitView` / `TabView`, and direct Keychain/SQLite integration.
2. **Local LLM Engine (`llama.cpp` pinned at `b12020`)**: Packaged via local SwiftPM binary target (`Packages/ZinoLlama`) built by `scripts/build-llama-xcframework.sh` with Metal GPU acceleration for device + simulator slices. Serialized on a dedicated worker queue with KV-cache prefix reuse across multi-turn chats.
3. **Pure-Swift GGUF Header Verification**: `GGUFHeaderParser` reads GGUF v2/v3 binary headers without allocating tensor weights, validating architecture compatibility and estimating RAM (weights + KV cache + Metal buffers) against live `os_proc_available_memory()` before loading.
4. **Native glTF 2.0 / GLB Parser + ModelIO/SceneKit**: Preserves complete scene/node hierarchies, local transforms, PBR materials, embedded/external textures, and animation metadata without flattening or automatic decimation.
5. **SQLite3 + Versioned Migrations**: Uses Apple's system `libsqlite3` in WAL mode with foreign keys enabled. Large binary weights, generated images, and 3D project copies stay on disk under `Application Support/ZinoAgent/` (excluded from iCloud backup for models), never bloated into SQLite BLOBs.
6. **Zero-Leak Credential Isolation**: Provider API keys are stored solely in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and registered with `SecretRedactor` so keys never appear in SQLite, logs, error messages, or exports.
7. **XcodeGen (`project.yml`) + GitHub Actions macOS Runners**: Guarantees reproducible `ZinoAgent.xcodeproj` generation without merge conflicts or hand-edited `.pbxproj` corruption, enabling full macOS builds and test execution from Windows.
