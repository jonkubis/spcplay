#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/snesapu.dll"
BUILD_DIR="$ROOT_DIR/build-macos-x86_64"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET_X86_64:-10.9}"

mkdir -p "$BUILD_DIR"

pushd "$SRC_DIR" >/dev/null

nasm -f macho64 APU.asm -o "$BUILD_DIR/APU.o"
nasm -f macho64 DSP.asm -o "$BUILD_DIR/DSP.o"
nasm -f macho64 SPC700.asm -o "$BUILD_DIR/SPC700.o"

clang++ \
  -arch x86_64 \
  -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -Wno-ignored-attributes \
  -c SNESAPU.cpp \
  -o "$BUILD_DIR/SNESAPU.o"

clang++ \
  -arch x86_64 \
  -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -dynamiclib \
  -Wl,-install_name,@rpath/libsnesapu.dylib \
  "$BUILD_DIR/SNESAPU.o" \
  "$BUILD_DIR/APU.o" \
  "$BUILD_DIR/DSP.o" \
  "$BUILD_DIR/SPC700.o" \
  -o "$BUILD_DIR/libsnesapu.dylib"

popd >/dev/null

echo "Built $BUILD_DIR/libsnesapu.dylib"
