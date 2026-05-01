#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE="$ROOT_DIR/build-macos-x86_64/spc_loadstate"
CANDIDATE="$ROOT_DIR/build-macos-arm64/spc_loadstate"
OUT_DIR="$ROOT_DIR/build-snesapu-compare/loadstate-$(date +%Y%m%d-%H%M%S)"
SCOPE="full"
SPC_INPUTS=()

usage() {
  cat <<EOF
usage: $0 --spc FILE_OR_DIR [options]

options:
  --reference PATH      Reference state probe (default: build-macos-x86_64/spc_loadstate)
  --candidate PATH      Candidate state probe (default: build-macos-arm64/spc_loadstate)
  --spc FILE_OR_DIR     SPC file or folder. Can be passed more than once.
  --out-dir DIR         Output directory for reports
  --scope SCOPE         full or core (core ignores DSP fixup/mixer hashes)
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
    --scope)
      SCOPE="$2"
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

if [[ "$SCOPE" != "full" && "$SCOPE" != "core" ]]; then
  echo "--scope must be full or core" >&2
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

filter_scope() {
  if [[ "$SCOPE" == "core" ]]; then
    grep -v -E '^(dsp_fnv1a|mix_fnv1a)=' "$1"
  else
    cat "$1"
  fi
}

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
  if ! "$REFERENCE" "$spc" > "$ref_out" 2>&1; then
    printf "ERROR\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  reference failed: $ref_out"
    errors=$((errors + 1))
    continue
  fi

  if ! "$CANDIDATE" "$spc" > "$cand_out" 2>&1; then
    printf "ERROR\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  candidate failed: $cand_out"
    errors=$((errors + 1))
    continue
  fi

  ref_cmp="$OUT_DIR/$prefix.reference.compare.txt"
  cand_cmp="$OUT_DIR/$prefix.candidate.compare.txt"
  filter_scope "$ref_out" > "$ref_cmp"
  filter_scope "$cand_out" > "$cand_cmp"

  if cmp -s "$ref_cmp" "$cand_cmp"; then
    printf "MATCH\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  match"
    matches=$((matches + 1))
    rm -f "$ref_out" "$cand_out" "$ref_cmp" "$cand_cmp"
  else
    printf "MISMATCH\t%d\t%s\n" "$index" "$spc" >> "$SUMMARY"
    echo "  mismatch"
    mismatches=$((mismatches + 1))
  fi
done

cat > "$OUT_DIR/report.txt" <<EOF
reference: $REFERENCE
candidate: $CANDIDATE
scope: $SCOPE
total: ${#SPC_FILES[@]}
matches: $matches
mismatches: $mismatches
errors: $errors
summary: $SUMMARY
EOF

cat "$OUT_DIR/report.txt"

if [[ "$mismatches" -ne 0 || "$errors" -ne 0 ]]; then
  exit 1
fi
