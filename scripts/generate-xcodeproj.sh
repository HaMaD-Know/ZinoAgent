#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed. On macOS install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --spec "$ROOT/project.yml"
echo "Generated $ROOT/ZinoAgent.xcodeproj"
