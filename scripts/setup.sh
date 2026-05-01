#!/usr/bin/env bash
# One-time setup: deps + initial builds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

echo "==> Rust build (ai_debug crate)"
cargo build -p ai_debug

echo "==> Flutter pub get (package)"
(cd flutter/packages/ai_debug && flutter pub get)

if [[ -d examples/minimal_app ]]; then
  echo "==> Flutter pub get (example)"
  (cd examples/minimal_app && flutter pub get)
fi

echo
echo "ai_debug ready. Next:"
echo "  cd examples/minimal_app && flutter run -d macos"
echo "  curl http://localhost:9999/api/logs"
