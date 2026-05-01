#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/snesapu.dll"
OUT="$ROOT/build-probe"

mkdir -p "$OUT"

echo "Probing SNESAPU assembly for macho64 compatibility..."

(
  cd "$SRC"
  nasm -f macho64 APU.asm -o "$OUT/APU.o"
) || true

(
  cd "$SRC"
  nasm -f macho64 DSP.asm -o "$OUT/DSP.o"
) || true

(
  cd "$SRC"
  nasm -f macho64 SPC700.asm -o "$OUT/SPC700.o"
) || true
