#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/snesapu.arm64"
BUILD_DIR="$ROOT_DIR/build-macos-arm64"
BACKEND_SOURCE="$BACKEND_DIR/SNESAPUArm64.cpp"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET_ARM64:-11.0}"

mkdir -p "$BUILD_DIR"

echo "Checking shared spc2wav frontend for arm64..."
clang++ \
  -arch arm64 \
  -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -std=c++17 \
  -I"$ROOT_DIR/snesapu.dll" \
  -fsyntax-only \
  "$ROOT_DIR/tools/spc2wav.cpp"

if [[ ! -f "$BACKEND_SOURCE" ]]; then
  cat >&2 <<EOF
ARM64 frontend check passed, but no backend exists yet:
  $BACKEND_SOURCE

Create that backend when porting SNESAPU semantics, then rerun this script to
build:
  $BUILD_DIR/libsnesapu.dylib
  $BUILD_DIR/spc2wav
EOF
  exit 2
fi

clang++ \
  -arch arm64 \
  -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -std=c++17 \
  -Wno-ignored-attributes \
  -I"$ROOT_DIR/snesapu.dll" \
  -dynamiclib \
  -Wl,-install_name,@rpath/libsnesapu.dylib \
  "$BACKEND_SOURCE" \
  -o "$BUILD_DIR/libsnesapu.dylib"

clang++ \
  -arch arm64 \
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
