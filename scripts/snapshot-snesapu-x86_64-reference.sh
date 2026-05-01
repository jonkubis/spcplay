#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_DIR="${1:-$ROOT_DIR/reference-macos/x86_64-snesapu-reference-$STAMP}"
BUILD_DIR="$ROOT_DIR/build-macos-x86_64"

CORE_FILES=(
  "snesapu.dll/APU.asm"
  "snesapu.dll/DSP.asm"
  "snesapu.dll/SPC700.asm"
  "snesapu.dll/SNESAPU.cpp"
  "snesapu.dll/APU.h"
  "snesapu.dll/DSP.h"
  "snesapu.dll/SPC700.h"
  "snesapu.dll/SNESAPU.h"
  "snesapu.dll/types.h"
  "snesapu.dll/APU.inc"
  "snesapu.dll/DSP.inc"
  "snesapu.dll/SPC700.inc"
  "snesapu.dll/SNESAPU.inc"
  "snesapu.dll/macro.inc"
  "tools/spc2wav.cpp"
  "scripts/build-snesapu-dylib.sh"
  "scripts/build-spc2wav.sh"
)

ARTIFACT_FILES=(
  "build-macos-x86_64/libsnesapu.dylib"
  "build-macos-x86_64/spc2wav"
)

copy_file() {
  local rel="$1"
  local src="$ROOT_DIR/$rel"
  local dst="$SNAPSHOT_DIR/$rel"
  if [[ ! -f "$src" ]]; then
    echo "missing required file: $rel" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

hash_manifest() {
  local manifest="$1"
  shift
  : > "$manifest"
  local rel
  for rel in "$@"; do
    shasum -a 256 "$ROOT_DIR/$rel" >> "$manifest"
  done
}

"$ROOT_DIR/scripts/build-spc2wav.sh"

mkdir -p "$SNAPSHOT_DIR"

for rel in "${CORE_FILES[@]}"; do
  copy_file "$rel"
done

for rel in "${ARTIFACT_FILES[@]}"; do
  copy_file "$rel"
done

hash_manifest "$SNAPSHOT_DIR/source-sha256.txt" "${CORE_FILES[@]}"
hash_manifest "$SNAPSHOT_DIR/artifact-sha256.txt" "${ARTIFACT_FILES[@]}"

cat > "$SNAPSHOT_DIR/README.md" <<EOF
# x86_64 SNESAPU Reference Snapshot

Created: $STAMP

This snapshot preserves the current macOS x86_64 SNESAPU reference backend for
the ARM64 porting effort.

The source files are copied with their repository-relative paths. The artifacts
under \`build-macos-x86_64\` were rebuilt immediately before this snapshot.

Manifests:

- \`source-sha256.txt\`
- \`artifact-sha256.txt\`

EOF

echo "Wrote $SNAPSHOT_DIR"

