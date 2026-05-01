#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-x86_64}"

sign_app_bundle() {
  local app_dir="$1"
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --deep "$app_dir"
  fi
}

build_single_arch() {
  local arch="$1"
  local build_dir="$ROOT_DIR/build-macos-$arch"
  local app_dir="$build_dir/spcplay-macos.app"
  local macos_dir="$app_dir/Contents/MacOS"
  local resources_dir="$app_dir/Contents/Resources"
  local deployment_target
  local objc_arc_flag=""

  case "$arch" in
    x86_64)
      deployment_target="${MACOSX_DEPLOYMENT_TARGET_X86_64:-10.9}"
      "$ROOT_DIR/scripts/build-spc2wav.sh"
      ;;
    arm64)
      deployment_target="${MACOSX_DEPLOYMENT_TARGET_ARM64:-11.0}"
      "$ROOT_DIR/scripts/build-spc2wav-arm64-candidate.sh"
      ;;
    *)
      echo "Unsupported architecture: $arch" >&2
      exit 2
      ;;
  esac

  if [[ "$arch" != "x86_64" ]]; then
    objc_arc_flag="-fobjc-arc"
  fi

  mkdir -p "$macos_dir" "$resources_dir"

  clang++ \
    -arch "$arch" \
    -mmacosx-version-min="$deployment_target" \
    -std=c++17 \
    ${objc_arc_flag:+"$objc_arc_flag"} \
    -I"$ROOT_DIR/snesapu.dll" \
    -framework AppKit \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework CoreServices \
    "$ROOT_DIR/tools/spcplay_macos.mm" \
    -L"$build_dir" \
    -lsnesapu \
    -Wl,-rpath,@executable_path \
    -Wl,-rpath,@loader_path \
    -o "$macos_dir/spcplay-macos"

  cp "$ROOT_DIR/macos/Info.plist" "$app_dir/Contents/Info.plist"
  printf 'APPL????' > "$app_dir/Contents/PkgInfo"
  cp "$ROOT_DIR/macos/spcplay.icns" "$resources_dir/spcplay.icns"
  cp "$build_dir/spc2wav" "$macos_dir/spc2wav"
  cp "$build_dir/libsnesapu.dylib" "$macos_dir/libsnesapu.dylib"
  sign_app_bundle "$app_dir"

  echo "Built $app_dir"
}

case "$ARCH" in
  x86_64|arm64)
    build_single_arch "$ARCH"
    ;;
  universal)
    build_single_arch x86_64
    build_single_arch arm64

    UNIVERSAL_BUILD_DIR="$ROOT_DIR/build-macos-universal"
    UNIVERSAL_APP_DIR="$UNIVERSAL_BUILD_DIR/spcplay-macos.app"
    UNIVERSAL_MACOS_DIR="$UNIVERSAL_APP_DIR/Contents/MacOS"
    UNIVERSAL_RESOURCES_DIR="$UNIVERSAL_APP_DIR/Contents/Resources"

    mkdir -p "$UNIVERSAL_MACOS_DIR" "$UNIVERSAL_RESOURCES_DIR"
    cp "$ROOT_DIR/macos/Info.plist" "$UNIVERSAL_APP_DIR/Contents/Info.plist"
    printf 'APPL????' > "$UNIVERSAL_APP_DIR/Contents/PkgInfo"
    cp "$ROOT_DIR/macos/spcplay.icns" "$UNIVERSAL_RESOURCES_DIR/spcplay.icns"

    lipo -create \
      "$ROOT_DIR/build-macos-x86_64/spcplay-macos.app/Contents/MacOS/spcplay-macos" \
      "$ROOT_DIR/build-macos-arm64/spcplay-macos.app/Contents/MacOS/spcplay-macos" \
      -output "$UNIVERSAL_MACOS_DIR/spcplay-macos"
    lipo -create \
      "$ROOT_DIR/build-macos-x86_64/spc2wav" \
      "$ROOT_DIR/build-macos-arm64/spc2wav" \
      -output "$UNIVERSAL_MACOS_DIR/spc2wav"
    lipo -create \
      "$ROOT_DIR/build-macos-x86_64/libsnesapu.dylib" \
      "$ROOT_DIR/build-macos-arm64/libsnesapu.dylib" \
      -output "$UNIVERSAL_MACOS_DIR/libsnesapu.dylib"

    sign_app_bundle "$UNIVERSAL_APP_DIR"

    echo "Built $UNIVERSAL_APP_DIR"
    ;;
  *)
    echo "Usage: $0 [x86_64|arm64|universal]" >&2
    exit 2
    ;;
esac
