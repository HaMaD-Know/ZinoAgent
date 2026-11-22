# llama.xcframework Directory

`llama.xcframework` is intentionally not committed to Git because it is a large compiled binary (~30–60 MB).

To build it on macOS or in GitHub Actions:

```bash
bash scripts/build-llama-xcframework.sh
```

This builds `llama.cpp` at pinned tag `b12020` with Metal acceleration enabled for both `ios-device` (arm64) and `ios-sim` (arm64/x86_64) and places `llama.xcframework` inside this directory.
