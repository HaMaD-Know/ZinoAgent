// swift-tools-version: 5.9
import PackageDescription

// Local Swift package wrapping llama.xcframework built from pinned llama.cpp (tag b12020).
// Run `scripts/build-llama-xcframework.sh` on macOS (or via GitHub Actions) before resolving.
let package = Package(
    name: "ZinoLlama",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        )
    ]
)
