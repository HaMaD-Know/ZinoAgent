#!/usr/bin/env bash
set -euo pipefail

# Builds llama.xcframework (Metal-accelerated, iOS device + iOS simulator) from a pinned
# llama.cpp tag for ZinoAgent 2.0.
LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-b12020}"
LLAMA_CPP_COMMIT="${LLAMA_CPP_COMMIT:-0ec4027a2a0183de87c007069adddc06e665f7de}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/ZinoLlama/Frameworks/llama.xcframework"
WORK="${LLAMA_BUILD_DIR:-$ROOT/.build/llama.cpp-$LLAMA_CPP_TAG}"

if [[ -d "$DEST" && -f "$DEST/.zino-tag" && "$(cat "$DEST/.zino-tag")" == "$LLAMA_CPP_TAG" ]]; then
  echo "llama.xcframework for $LLAMA_CPP_TAG is already installed at $DEST."
  exit 0
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: llama.xcframework must be built on macOS (run via GitHub Actions workflow)." >&2
  exit 1
fi

if [[ ! -d "$WORK/.git" ]]; then
  rm -rf "$WORK"
  git clone --depth 1 --branch "$LLAMA_CPP_TAG" https://github.com/ggml-org/llama.cpp "$WORK"
fi

if [[ -n "$LLAMA_CPP_COMMIT" ]]; then
  actual="$(git -C "$WORK" rev-parse HEAD)"
  if [[ "$actual" != "$LLAMA_CPP_COMMIT" ]]; then
    echo "error: tag $LLAMA_CPP_TAG resolved to $actual, expected $LLAMA_CPP_COMMIT" >&2
    exit 1
  fi
fi

pushd "$WORK" >/dev/null
# Build iOS device + simulator slices with Metal enabled (iPadOS 17+ / iOS 17+).
./build-xcframework.sh ios-device ios-sim
popd >/dev/null

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$WORK/build-apple/llama.xcframework" "$DEST"
echo "$LLAMA_CPP_TAG" > "$DEST/.zino-tag"
echo "Successfully built and installed $DEST"
