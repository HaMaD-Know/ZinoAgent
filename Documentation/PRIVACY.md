# ZinoAgent 2.0 — Privacy & Security Architecture

## Privacy Guarantees

1. **Offline-First by Default**: Core file management, document preview, 3D Studio, local GGUF chat, SmartContextEngine, and local Core ML image generation require no internet connection and no account or subscription.
2. **Zero Telemetry**: ZinoAgent includes no analytics SDKs, no crash uploaders, no advertising identifiers, and no background cloud syncing of user files.
3. **Strict iPadOS Sandbox Scope**: ZinoAgent only accesses folders you explicitly select through Apple's Files document picker using security-scoped bookmarks. Path traversal (`..`) and symlink escapes outside permitted folders are blocked by `SecurityScopedBookmarkManager.ensureInsideScope`.
4. **No Silent External Uploads**: Online AI providers are strictly optional. When you attach files in Online mode, ZinoAgent displays a confirmation dialog showing the exact filenames and target provider before transmitting any file content.
5. **Keychain-Only Secrets**: Provider API keys are stored exclusively in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Keys are never saved in SQLite, never written to diagnostic logs, never placed in URL query parameters (Google Gemini uses the `x-goog-api-key` header), and automatically scrubbed by `SecretRedactor` before conversation/workspace exports.
6. **HTTPS Enforced**: `HTTPClient` rejects unencrypted `http://` connections to remote hosts. Plain HTTP is permitted solely for explicitly configured local-network endpoints (`localhost`, `127.0.0.1`, `.local`, RFC 1918 LAN addresses such as Ollama or LM Studio).
7. **Permission-Aware AI File Tools**: AI cannot execute arbitrary file operations. Users control global and per-folder permissions (`Read-only`, `Suggest`, `Confirm`, `Authorized non-destructive`). Every tool invocation and approval decision is recorded in `tool_activity_log`.
8. **Data Ownership**: Users can export all conversations and settings (scrubbed of credentials) or delete all local conversations and clear safe caches at any time from Settings → Privacy. Clearing caches never touches user-imported models or 3D projects.
