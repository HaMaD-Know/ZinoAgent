# ZinoAgent 2.0

**Offline-First AI-Powered iPad File Manager & Personal AI Workspace**

Built natively in **Swift & SwiftUI** for **iPadOS 17+** (primary target: iPad Pro M2, 8 GB RAM, Apple Silicon, Metal) and **iOS 17+**.

## Highlights

- **Offline-First & Private**: No mandatory subscription, no mandatory cloud API, zero telemetry. Run local GGUF LLMs with Metal GPU acceleration via `llama.cpp` or optionally connect your own online providers (OpenAI, Anthropic, Google Gemini, Ollama, LM Studio, or any OpenAI-compatible server).
- **Advanced Scoped File Manager**: Mount folders explicitly from Apple's Files app using security-scoped bookmarks with stale-permission recovery, Grid/List browsing, search/sort/filtering, rich previews (PDF, Images, Code, Markdown, DOCX, ZIP), and reversible delete/undo.
- **SmartContextEngine**: Real/calibrated token tracking, tool-safe adaptive batching, on-device `NaturalLanguage` + TF-IDF history retrieval, pinned context items, verified structured summarization, and strict preservation of original messages.
- **Permission-Aware AI File Tools**: 11 scoped tools (`list_files`, `search_files`, `read_supported_document`, `create_folder`, `rename_file`, `copy_file`, `move_file`, `generate_file`, etc.) with 4 permission tiers, preview-and-confirm approval cards, and an audit log.
- **3D Studio**: Interactive Metal-backed 3D viewer supporting **GLB, GLTF, USDZ, OBJ, and STL** with full non-flattened object hierarchy, show/hide nodes, tap selection, wireframe mode, lighting/environment controls, and PBR material/texture inspection.
- **Image Studio**: Capability-driven online image generation plus optional local Core ML Stable Diffusion (`apple/ml-stable-diffusion`).
- **Build Without a Mac**: Includes `project.yml` (XcodeGen) and `.github/workflows/ios-build.yml` for GitHub Actions macOS runners (Simulator builds, automated iPad Simulator tests, unsigned device IPAs, and Development/Distribution signed IPAs).

## Documentation

- [Architecture](Documentation/ARCHITECTURE.md)
- [Features](Documentation/FEATURES.md)
- [Build & IPA Guide (GitHub Actions)](Documentation/BUILD.md)
- [Privacy & Security](Documentation/PRIVACY.md)
- [Development Status & Test Report](Documentation/DEVELOPMENT_STATUS.md)
