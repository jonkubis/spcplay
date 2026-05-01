#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE="$ROOT_DIR/build-macos-x86_64/spc2wav"
CANDIDATE=""
OUT_DIR="$ROOT_DIR/build-snesapu-compare/$(date +%Y%m%d-%H%M%S)"
SECONDS_ARG=""
KEEP_MATCHING=0
STOP_ON_MISMATCH=0
RENDER_MODE="samples"
CHUNK_SAMPLES="3200"
SPC_INPUTS=()

usage() {
  cat <<EOF
usage: $0 --candidate PATH --spc FILE_OR_DIR [options]

options:
  --reference PATH      Reference renderer (default: build-macos-x86_64/spc2wav)
  --candidate PATH      Candidate renderer to test
  --spc FILE_OR_DIR     SPC file or folder. Can be passed more than once.
  --seconds N           Force render length instead of using ID666/defaults
  --out-dir DIR         Output directory for logs and mismatch WAVs
  --keep-matching       Keep matching WAV pairs instead of deleting them
  --stop-on-mismatch    Stop after the first mismatch or render error
  --render-mode MODE    samples or cycles (default: samples)
  --chunk-samples N     spc2wav chunk size for sample-mode renders (default: 3200)
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
    --seconds)
      SECONDS_ARG="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --keep-matching)
      KEEP_MATCHING=1
      shift
      ;;
    --stop-on-mismatch)
      STOP_ON_MISMATCH=1
      shift
      ;;
    --render-mode)
      RENDER_MODE="$2"
      shift 2
      ;;
    --chunk-samples)
      CHUNK_SAMPLES="$2"
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

if [[ -z "$CANDIDATE" ]]; then
  echo "missing --candidate" >&2
  usage >&2
  exit 1
fi

if [[ ${#SPC_INPUTS[@]} -eq 0 ]]; then
  echo "missing --spc" >&2
  usage >&2
  exit 1
fi

if [[ "$RENDER_MODE" != "samples" && "$RENDER_MODE" != "cycles" ]]; then
  echo "--render-mode must be samples or cycles" >&2
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

if [[ ${#SPC_FILES[@]} -eq 0 ]]; then
  echo "no SPC files found" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.tsv"
printf "status\tindex\tspc\treference_sha256\tcandidate_sha256\n" > "$SUMMARY"

render_backend() {
  local exe="$1"
  local spc="$2"
  local wav="$3"
  local log="$4"
  local -a cmd=("$exe" "$spc" "$wav")
  if [[ -n "$SECONDS_ARG" ]]; then
    cmd+=("$SECONDS_ARG")
  fi

  if [[ "$RENDER_MODE" == "samples" ]]; then
    env SNESAPU_RENDER_SAMPLES=1 \
        SNESAPU_RENDER_CYCLES=0 \
        SNESAPU_CHUNK_SAMPLES="$CHUNK_SAMPLES" \
        "${cmd[@]}" > "$log" 2>&1
  else
    env SNESAPU_RENDER_SAMPLES=0 \
        SNESAPU_RENDER_CYCLES=1 \
        SNESAPU_CHUNK_SAMPLES="$CHUNK_SAMPLES" \
        "${cmd[@]}" > "$log" 2>&1
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
  ref_wav="$OUT_DIR/$prefix.reference.wav"
  cand_wav="$OUT_DIR/$prefix.candidate.wav"
  ref_log="$OUT_DIR/$prefix.reference.log"
  cand_log="$OUT_DIR/$prefix.candidate.log"

  echo "[$index/${#SPC_FILES[@]}] $spc"

  if ! render_backend "$REFERENCE" "$spc" "$ref_wav" "$ref_log"; then
    printf "ERROR\t%d\t%s\treference-render-failed\t\n" "$index" "$spc" >> "$SUMMARY"
    echo "  reference render failed: $ref_log"
    errors=$((errors + 1))
    if [[ "$STOP_ON_MISMATCH" -ne 0 ]]; then
      break
    fi
    continue
  fi

  if ! render_backend "$CANDIDATE" "$spc" "$cand_wav" "$cand_log"; then
    ref_hash="$(shasum -a 256 "$ref_wav" | awk '{print $1}')"
    printf "ERROR\t%d\t%s\t%s\tcandidate-render-failed\n" "$index" "$spc" "$ref_hash" >> "$SUMMARY"
    echo "  candidate render failed: $cand_log"
    errors=$((errors + 1))
    if [[ "$STOP_ON_MISMATCH" -ne 0 ]]; then
      break
    fi
    continue
  fi

  ref_hash="$(shasum -a 256 "$ref_wav" | awk '{print $1}')"
  cand_hash="$(shasum -a 256 "$cand_wav" | awk '{print $1}')"

  if cmp -s "$ref_wav" "$cand_wav"; then
    printf "MATCH\t%d\t%s\t%s\t%s\n" "$index" "$spc" "$ref_hash" "$cand_hash" >> "$SUMMARY"
    echo "  match $ref_hash"
    matches=$((matches + 1))
    if [[ "$KEEP_MATCHING" -eq 0 ]]; then
      rm -f "$ref_wav" "$cand_wav"
    fi
  else
    printf "MISMATCH\t%d\t%s\t%s\t%s\n" "$index" "$spc" "$ref_hash" "$cand_hash" >> "$SUMMARY"
    echo "  mismatch"
    echo "    reference $ref_hash"
    echo "    candidate $cand_hash"
    mismatches=$((mismatches + 1))
    if [[ "$STOP_ON_MISMATCH" -ne 0 ]]; then
      break
    fi
  fi
done

cat > "$OUT_DIR/report.txt" <<EOF
reference: $REFERENCE
candidate: $CANDIDATE
render_mode: $RENDER_MODE
chunk_samples: $CHUNK_SAMPLES
seconds: ${SECONDS_ARG:-auto}
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
