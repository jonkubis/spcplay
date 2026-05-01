#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build-macos-x86_64"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET_X86_64:-10.9}"

"$ROOT_DIR/scripts/build-snesapu-dylib.sh"

clang++ \
  -arch x86_64 \
  -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -std=c++17 \
  -I"$ROOT_DIR/snesapu.dll" \
  "$ROOT_DIR/tools/spc2wav.cpp" \
  -L"$BUILD_DIR" \
  -lsnesapu \
  -Wl,-rpath,@executable_path \
  -Wl,-rpath,@loader_path \
  -o "$BUILD_DIR/spc2wav"

echo "Built $BUILD_DIR/spc2wav"
