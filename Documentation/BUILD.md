# ZinoAgent 2.0 — Build & IPA Export Guide (No Mac Required)

ZinoAgent 2.0 is designed to be built, tested, archived, and packaged on **GitHub Actions macOS runners** (`macos-15`), so you do not need to own a Mac.

## Quick Start with GitHub Actions

1. Push this repository to GitHub (`https://github.com/HaMaD-Know/ZinoAgent`).
2. Open the **Actions** tab in your GitHub repository.
3. Select **ZinoAgent 2.0 iOS Build & IPA Pipeline** (`.github/workflows/ios-build.yml`).
4. Click **Run workflow** and choose a `build_mode`:
   - `all`: Simulator compile check + Unit & Integration tests on iPad Simulator + unsigned device `.ipa` (+ signed `.ipa` if signing secrets are configured).
   - `simulator`: Fast unsigned iOS Simulator `.app` compile check.
   - `test`: Runs `ZinoAgentUnitTests` and `ZinoAgentIntegrationTests` on an iPad Simulator and uploads `TestResults.xcresult`.
   - `unsigned-device`: Builds a Release `iphoneos` archive and packages `ZinoAgent-2.0-unsigned.ipa`.
   - `development-ipa`: Builds and exports a Development-signed `.ipa` using your GitHub Actions secrets.
   - `distribution-ipa`: Builds and exports an Ad-Hoc or App Store Distribution `.ipa` using your GitHub Actions secrets.

## Important Notice About Unsigned IPAs

An **unsigned `.ipa`** (`ZinoAgent-2.0-unsigned.ipa`) is a genuine compiled `arm64` iPadOS/iOS binary, **NOT directly installable on a stock physical iPad** without signing. iPadOS requires a valid Apple signature and provisioning profile.

You have two legitimate ways to install ZinoAgent 2.0 on your iPad Pro M2:

### Option A — Re-sign the Unsigned IPA Locally (Free Apple ID or Paid Developer Account)
1. Download `ZinoAgent-2.0-unsigned.ipa` from the GitHub Actions run artifacts.
2. Re-sign and install it onto your iPad using a standard re-signing tool such as **Sideloadly** or **AltStore** from Windows.
   - Free Apple ID signatures expire after 7 days and do not support the `Increased Memory Limit` entitlement.
   - Paid Apple Developer accounts ($99/year) sign for 1 year and support `Increased Memory Limit` (highly recommended for 7B local GGUF models on 8 GB RAM).

### Option B — Automated Signed IPA in GitHub Actions (Recommended for Paid Apple Developer Accounts)
Add the following **Repository Secrets** in GitHub (`Settings → Secrets and variables → Actions`):

| Secret Name | Required | Description |
|---|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | Yes | Base64-encoded Apple Development or Distribution `.p12` certificate (`base64 -i cert.p12`). |
| `IOS_CERTIFICATE_PASSWORD` | Yes | Password protecting your `.p12` certificate. |
| `IOS_PROVISIONING_PROFILE_BASE64` | Yes | Base64-encoded `.mobileprovision` file matching your Bundle ID and certificate. |
| `APPLE_TEAM_ID` | Yes | Your 10-character Apple Developer Team ID. |
| `IOS_BUNDLE_IDENTIFIER` | Optional | Custom bundle ID matching your provisioning profile (defaults to `com.zinoagent.app`). |
| `IOS_EXPORT_METHOD` | Optional | `development`, `ad-hoc`, or `app-store` (defaults to `development` / `ad-hoc`). |
| `IOS_INCREASED_MEMORY_LIMIT` | Optional | Set to `true` **only** if your App ID and Provisioning Profile have the `Increased Memory Limit` capability enabled in Apple Developer Portal. |

> **Security rule:** Never commit `.p12`, `.cer`, `.key`, `.mobileprovision`, or API keys to Git. All of these patterns are ignored in `.gitignore`.

## Building Locally on macOS (Optional)

If you have access to a Mac with Xcode 16+:

```bash
brew install xcodegen cmake
bash scripts/build-llama-xcframework.sh
bash scripts/generate-xcodeproj.sh
open ZinoAgent.xcodeproj
```

## Dependencies & Pinning

| Dependency | Version / Pin | Purpose |
|---|---|---|
| `ggml-org/llama.cpp` | Tag `b12020` (`0ec4027a...`) | Offline GGUF LLM inference with Metal acceleration |
| `apple/ml-stable-diffusion` | `1.1.1` | Optional offline Core ML Stable Diffusion (SD 1.5 / 2.1 / SDXL) |
| `weichsel/ZIPFoundation` | `>= 0.9.19` | ZIP archive inspection/extraction & DOCX XML text extraction |
| Apple System Frameworks | iOS 17+ SDK | SwiftUI, SQLite3, PDFKit, SceneKit, ModelIO, Metal, CoreML, NaturalLanguage, Security, BackgroundTasks |
