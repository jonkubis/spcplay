#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build-macos-x86_64"

"$ROOT_DIR/scripts/build-snesapu-dylib.sh"

clang++ \
  -arch x86_64 \
  -std=c++17 \
  -I"$ROOT_DIR/snesapu.dll" \
  "$ROOT_DIR/tools/spcstate.cpp" \
  -L"$BUILD_DIR" \
  -lsnesapu \
  -Wl,-rpath,@executable_path \
  -Wl,-rpath,@loader_path \
  -o "$BUILD_DIR/spcstate"

echo "Built $BUILD_DIR/spcstate"
