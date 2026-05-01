#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE="$ROOT_DIR/build-macos-x86_64/spc_execstate"
CANDIDATE="$ROOT_DIR/build-macos-arm64/spc_execstate"
OUT_DIR="$ROOT_DIR/build-snesapu-compare/execstate-$(date +%Y%m%d-%H%M%S)"
MODE="spc"
TOTAL="1"
CHUNK="1"
SPC_INPUTS=()

usage() {
  cat <<EOF
usage: $0 --spc FILE_OR_DIR [options]

options:
  --reference PATH      Reference execution probe (default: build-macos-x86_64/spc_execstate)
  --candidate PATH      Candidate execution probe (default: build-macos-arm64/spc_execstate)
  --spc FILE_OR_DIR     SPC file or folder. Can be passed more than once.
  --out-dir DIR         Output directory for reports
  --mode MODE           spc, cycles, or samples (default: spc)
  --total N             Total samples/cycles to emulate (default: 1)
  --chunk N             Chunk size passed to each EmuAPU call (default: 1)
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reference)
      REFERENCE="$2"
      shift 2
      ;;
    --candidate)
      CANDIDATE="$2"
      shift 2
      ;;
    --spc)
      SPC_INPUTS+=("$2")
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --total)
      TOTAL="$2"
      shift 2
      ;;
    --chunk)
      CHUNK="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${#SPC_INPUTS[@]} -eq 0 ]]; then
  echo "missing --spc" >&2
  usage >&2
  exit 1
fi

if [[ "$MODE" != "spc" && "$MODE" != "samples" && "$MODE" != "cycles" ]]; then
  echo "--mode must be spc, samples, or cycles" >&2
  exit 1
fi

if [[ ! -x "$REFERENCE" ]]; then
  echo "reference is not executable: $REFERENCE" >&2
  exit 1
fi

if [[ ! -x "$CANDIDATE" ]]; then
  echo "candidate is not executable: $CANDIDATE" >&2
  exit 1
fi

SPC_FILES=()
for input in "${SPC_INPUTS[@]}"; do
  if [[ -d "$input" ]]; then
    while IFS= read -r path; do
      SPC_FILES+=("$path")
    done < <(find "$input" -type f \( -iname '*.spc' -o -iname '*.sp0' -o -iname '*.sp1' -o -iname '*.sp2' -o -iname '*.sp3' -o -iname '*.sp4' -o -iname '*.sp5' -o -iname '*.sp6' -o -iname '*.sp7' -o -iname '*.sp8' -o -iname '*.sp9' \) | sort)
  elif [[ -f "$input" ]]; then
    SPC_FILES+=("$input")
  else
    echo "SPC input does not exist: $input" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.tsv"
printf "status\tindex\tspc\n" > "$SUMMARY"

matches=0
mismatches=0
errors=0
index=0

for spc in "${SPC_FILES[@]}"; do
  index=$((index + 1))
  stem="$(basename "$spc")"
  stem="${stem%.*}"
  prefix="$(printf '%04d' "$index")-$stem"
  ref_out="$OUT_DIR/$prefix.reference.txt"
  cand_out="$OUT_DIR/$prefix.candidate.txt"

  echo "[$index/${#SPC_FILES[@]}] $spc"
  if ! "$REFERENCE" "$spc" "$MODE" "$TOTAL" "$CHUNK" > "$ref_out" 2>&1; then
    printf "ERROR\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  reference failed: $ref_out"
    errors=$((errors + 1))
    continue
  fi

  if ! "$CANDIDATE" "$spc" "$MODE" "$TOTAL" "$CHUNK" > "$cand_out" 2>&1; then
    printf "ERROR\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  candidate failed: $cand_out"
    errors=$((errors + 1))
    continue
  fi

  if cmp -s "$ref_out" "$cand_out"; then
    printf "MATCH\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  match"
    matches=$((matches + 1))
    rm -f "$ref_out" "$cand_out"
  else
    printf "MISMATCH\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  mismatch"
    mismatches=$((mismatches + 1))
  fi
done

cat > "$OUT_DIR/report.txt" <<EOF
reference: $REFERENCE
candidate: $CANDIDATE
mode: $MODE
total: $TOTAL
chunk: $CHUNK
spc_total: ${#SPC_FILES[@]}
matches: $matches
mismatches: $mismatches
errors: $errors
summary: $SUMMARY
EOF

cat "$OUT_DIR/report.txt"

if [[ "$mismatches" -ne 0 || "$errors" -ne 0 ]]; then
  exit 1
fi
