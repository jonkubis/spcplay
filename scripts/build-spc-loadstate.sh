#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-x86_64}"

case "$ARCH" in
  x86_64)
    BUILD_DIR="$ROOT_DIR/build-macos-x86_64"
    "$ROOT_DIR/scripts/build-snesapu-dylib.sh"
    ;;
  arm64)
    BUILD_DIR="$ROOT_DIR/build-macos-arm64"
    "$ROOT_DIR/scripts/build-spc2wav-arm64-candidate.sh"
    ;;
  *)
    echo "usage: $0 [x86_64|arm64]" >&2
    exit 1
    ;;
esac

clang++ \
  -arch "$ARCH" \
  -std=c++17 \
  -I"$ROOT_DIR/snesapu.dll" \
  "$ROOT_DIR/tools/spc_loadstate.cpp" \
  -L"$BUILD_DIR" \
  -lsnesapu \
  -Wl,-rpath,@executable_path \
  -Wl,-rpath,@loader_path \
  -o "$BUILD_DIR/spc_loadstate"

echo "Built $BUILD_DIR/spc_loadstate"

