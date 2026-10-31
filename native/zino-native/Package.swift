// swift-tools-version: 5.9
import PackageDescription

// ZinoAgent native plugins. Capacitor's CLI adds this package to ios/App/CapApp-SPM
// (because native/zino-native/package.json declares `capacitor.ios.src`), which links it
// into the App target. Plugin classes are registered via `packageClassList`.
//
// llama.xcframework is NOT committed: scripts/build-llama-xcframework.sh builds it from a
// pinned llama.cpp tag (device + simulator slices, Metal enabled) into ios/Frameworks/.
let package = Package(
    name: "ZinoNative",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ZinoNative", targets: ["ZinoNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", exact: "1.1.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .binaryTarget(name: "llama", path: "ios/Frameworks/llama.xcframework"),
        .target(
            name: "ZinoNative",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "llama"
            ],
            path: "ios/Sources/ZinoNative",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("PDFKit"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
