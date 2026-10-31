#!/usr/bin/env bash
# Builds llama.xcframework (iOS device + iOS simulator, Metal enabled) from a pinned
# llama.cpp release tag and places it where native/zino-native/Package.swift expects it.
#
# Requires macOS with Xcode + CMake (GitHub's macOS runners have both).
# Usage: scripts/build-llama-xcframework.sh            (uses LLAMA_CPP_TAG below)
#        LLAMA_CPP_TAG=b12020 scripts/build-llama-xcframework.sh
set -euo pipefail

LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-b12020}"
# Commit that tag pointed to when ZinoAgent was pinned; checked to detect a moved tag.
LLAMA_CPP_COMMIT="${LLAMA_CPP_COMMIT:-0ec4027a2a0183de87c007069adddc06e665f7de}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/native/zino-native/ios/Frameworks/llama.xcframework"
WORK="${LLAMA_BUILD_DIR:-$ROOT/.build/llama.cpp-$LLAMA_CPP_TAG}"

if [[ -d "$DEST" && -f "$DEST/.zino-tag" && "$(cat "$DEST/.zino-tag")" == "$LLAMA_CPP_TAG" ]]; then
  echo "llama.xcframework for $LLAMA_CPP_TAG already present."
  exit 0
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: llama.xcframework can only be built on macOS (use the GitHub Actions workflow)." >&2
  exit 1
fi

if [[ ! -d "$WORK/.git" ]]; then
  rm -rf "$WORK"
  git clone --depth 1 --branch "$LLAMA_CPP_TAG" https://github.com/ggml-org/llama.cpp "$WORK"
fi
if [[ -n "$LLAMA_CPP_COMMIT" ]]; then
  actual="$(git -C "$WORK" rev-parse HEAD)"
  if [[ "$actual" != "$LLAMA_CPP_COMMIT" ]]; then
    echo "error: tag $LLAMA_CPP_TAG resolves to $actual, expected $LLAMA_CPP_COMMIT" >&2
    exit 1
  fi
fi

pushd "$WORK" >/dev/null
# ZinoAgent targets iPadOS 17+; device + simulator slices only (keeps CI time down).
./build-xcframework.sh ios-device ios-sim
popd >/dev/null

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$WORK/build-apple/llama.xcframework" "$DEST"
echo "$LLAMA_CPP_TAG" > "$DEST/.zino-tag"
echo "Installed $DEST"
