# ZinoAgent 2.0 — Features

## 1. Adaptive iPad & iPhone Workspace
- **iPad / Regular Width**: Collapsible `NavigationSplitView` sidebar with live AI mode, active model, thermal state, and RAM headroom indicator.
- **iPhone & Narrow Split View**: Compact `TabView` preserving state across orientation changes and multitasking.
- Supports Light Mode, Dark Mode, and System appearance.

## 2. Home Dashboard
- Live ZinoAgent branding, AI mode, selected model, and thermal status.
- Quick Actions wired to Files, New AI Chat, 3D Studio, Image Studio, Model Catalog, and AI Provider Setup.
- Real-time AI engine state, `SmartContextEngine` token usage, live `os_proc_available_memory()` headroom, and actual disk storage breakdown.
- Real recent activity populated directly from SQLite (recent conversations, files, 3D projects, generated images).

## 3. Advanced File Manager
- Explicit folder selection via Apple's Files document picker (`UIDocumentPickerViewController`).
- Multi-folder security-scoped bookmarks with stale-bookmark detection and one-tap folder reconnection.
- Grid & List views, breadcrumb navigation, real-time recursive search, sorting (Name, Date, Size, Kind), category filters, favorites, and multi-selection.
- File operations: Create Folder, Rename, Copy, Move, Duplicate, Import, Export/Share, Extract ZIP (with zip-slip protection), and reversible Delete (`.zino_trash` + Undo journal). Never silently overwrites existing files.
- Rich previews: PDFKit, Images, Source Code/Markdown/JSON/CSV/TXT, DOCX text extraction, ZIP archive browser, and direct handoff to AI Chat or 3D Studio.

## 4. AI Chat Engine
- Multi-conversation SQLite persistence with create, rename, delete, search, and Markdown/JSON export.
- Seamless **Offline ↔ Online** mode switching without losing conversation history.
- Markdown rendering with fenced code blocks and one-click Copy buttons.
- File and photo attachments, message editing, response regeneration, generation stop button, and message pinning to `SmartContextEngine`.
- Provider/model provenance labels on every assistant turn.

## 5. Offline AI Engine & Model Manager
- Metal-accelerated local GGUF inference via `llama.cpp` with streaming tokens, KV-cache prefix reuse, cancellation, and real device benchmarking.
- Curated GGUF catalog + custom HTTPS URL download with pause/resume (`URLSession` resumeData), speed/progress tracking, and SHA-256 prefix verification.
- Apple Files `.gguf` import with pre-load header inspection, architecture validation, and transparent RAM compatibility warnings (never silently downgrades user-selected models).

## 6. Online AI Engine
- Modular `OnlineAIProviderAdapter` architecture supporting:
  - **OpenAI** (chat streaming, tool calling, vision, image generation)
  - **Anthropic Claude** (Messages API streaming, thinking blocks, tool use, vision)
  - **Google Gemini** (SSE streaming, function calling, multimodal vision, Imagen/Gemini image generation)
  - **OpenAI-Compatible** endpoints (Ollama, LM Studio, OpenRouter, Groq, custom servers)
- Keychain-only credential storage, live connection test & model discovery, and per-conversation provider/model selection.

## 7. SmartContextEngine
- Defaults: Adaptive batching ON, Smart history retrieval ON, Preserve original messages ON, Summary verification ON, 4K baseline target, ~5-message initial batch.
- Exact tokenization via `llama_tokenize` when a local model is loaded; family-calibrated BPE/SentencePiece estimator for cloud models.
- Tool-pair-safe adaptive batching, on-device `NaturalLanguage` + TF-IDF history retrieval with user-pinned guarantees, verified structured summaries, and a full interactive Context Dashboard.

## 8. Image Studio
- Online generation (OpenAI, Google Gemini/Imagen, OpenAI-compatible) with capability-driven UI controls (only displays controls supported by the selected provider/model).
- Optional independent offline generation via Apple's Core ML `StableDiffusion` (SD 1.5 / 2.1 / SDXL compiled `.mlmodelc` packages) with memory checks, step progress, and cancellation.
- Persistent local gallery history, Photo Library export, Files share, and AI prompt enhancement handoff.

## 9. 3D Studio
- Supports **GLB, GLTF, USDZ, OBJ, STL** via native Swift glTF 2.0/GLB parser + Apple ModelIO/SceneKit on Metal.
- Interactive orbit, zoom, pan, tap-to-select objects, Reset Camera, Wireframe toggle, 4 lighting presets, 4 environment presets, intensity slider, and reference grid.
- Full non-flattened object hierarchy inspector (select, show/hide individual nodes, local transforms), PBR materials & textures inspector, geometry/animation metadata, large-file memory warning (never auto-decimates), and "Explain with AI".

## 10. Permission-Aware AI File Tool System
- 11 scoped tools: `list_files`, `search_files`, `get_file_metadata`, `read_supported_document`, `summarize_document`, `create_folder`, `rename_file`, `copy_file`, `move_file`, `export_file`, `generate_file`.
- Four permission tiers (`Read-only`, `Suggest`, `Confirm`, `Authorized non-destructive`), strict folder-scope & traversal validation, inline approval preview cards, and full SQLite audit log.
