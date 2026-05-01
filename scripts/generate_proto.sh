#!/usr/bin/env bash
# Regenerate Dart protobuf classes from protos/*.proto.
# Rust proto codegen runs automatically via build.rs.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc not found. Install: brew install protobuf" >&2
  exit 1
fi

DART_PKG="flutter/packages/ai_debug"
OUT="$DART_PKG/lib/src/generated"
rm -rf "$OUT"
mkdir -p "$OUT"

# Ensure protoc-gen-dart is on PATH (via pub global).
if ! command -v protoc-gen-dart >/dev/null 2>&1; then
  echo "Installing protoc_plugin globally..."
  dart pub global activate protoc_plugin
fi

PUB_BIN="$(dart pub global list | awk '/^protoc_plugin/ {print $1}' || true)"
if [[ -z "${PUB_BIN}" ]]; then
  echo "protoc_plugin activation failed" >&2
  exit 1
fi

# protoc_plugin installs protoc-gen-dart into $HOME/.pub-cache/bin
export PATH="$HOME/.pub-cache/bin:$PATH"

protoc --dart_out="$OUT" --proto_path=protos protos/ai_debug.proto

echo "Dart proto classes generated at $OUT"
ls -la "$OUT"
