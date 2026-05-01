#!/usr/bin/env python3
"""Compare SNESAPU renderer outputs across a corpus using parallel workers."""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import hashlib
import os
from pathlib import Path
import subprocess
import sys


ROOT_DIR = Path(__file__).resolve().parents[1]
SPC_SUFFIXES = {".spc"} | {f".sp{i}" for i in range(10)}


@dataclasses.dataclass(frozen=True)
class Options:
    reference: Path
    candidate: Path
    out_dir: Path
    seconds: str | None
    keep_matching: bool
    stop_on_mismatch: bool
    render_mode: str
    chunk_samples: str


@dataclasses.dataclass(frozen=True)
class Result:
    status: str
    index: int
    total: int
    spc: Path
    reference_hash: str
    candidate_hash: str
    message: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare SNESAPU renderer WAV output across a corpus in parallel."
    )
    parser.add_argument(
        "--reference",
        default=str(ROOT_DIR / "build-macos-x86_64" / "spc2wav"),
        help="Reference renderer.",
    )
    parser.add_argument("--candidate", required=True, help="Candidate renderer.")
    parser.add_argument(
        "--spc",
        action="append",
        required=True,
        help="SPC file or directory. May be supplied more than once.",
    )
    parser.add_argument("--seconds", help="Force render length instead of ID666/defaults.")
    parser.add_argument(
        "--out-dir",
        default=str(ROOT_DIR / "build-snesapu-compare" / "parallel"),
        help="Output directory for logs and mismatch WAVs.",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=max(1, min((os.cpu_count() or 4), 8)),
        help="Number of files to compare concurrently.",
    )
    parser.add_argument(
        "--keep-matching",
        action="store_true",
        help="Keep matching WAV pairs instead of deleting them.",
    )
    parser.add_argument(
        "--stop-on-mismatch",
        action="store_true",
        help="Stop after the first mismatch or render error.",
    )
    parser.add_argument(
        "--render-mode",
        choices=("samples", "cycles"),
        default="samples",
        help="Render in sample-chunk or cycle mode.",
    )
    parser.add_argument(
        "--chunk-samples",
        default="3200",
        help="spc2wav chunk size for sample-mode renders.",
    )
    return parser.parse_args()


def expand_spc_inputs(inputs: list[str]) -> list[Path]:
    files: list[Path] = []
    for input_name in inputs:
        path = Path(input_name)
        if path.is_dir():
            files.extend(
                sorted(
                    p
                    for p in path.rglob("*")
                    if p.is_file() and p.suffix.lower() in SPC_SUFFIXES
                )
            )
        elif path.is_file():
            files.append(path)
        else:
            raise SystemExit(f"SPC input does not exist: {path}")
    if not files:
        raise SystemExit("no SPC files found")
    return files


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def render_backend(exe: Path, spc: Path, wav: Path, log: Path, opts: Options) -> int:
    cmd = [str(exe), str(spc), str(wav)]
    if opts.seconds:
        cmd.append(opts.seconds)

    env = os.environ.copy()
    env["SNESAPU_RENDER_SAMPLES"] = "1" if opts.render_mode == "samples" else "0"
    env["SNESAPU_RENDER_CYCLES"] = "0" if opts.render_mode == "samples" else "1"
    env["SNESAPU_CHUNK_SAMPLES"] = opts.chunk_samples

    with log.open("wb") as handle:
        completed = subprocess.run(
            cmd,
            env=env,
            stdout=handle,
            stderr=subprocess.STDOUT,
            check=False,
        )
    return completed.returncode


def compare_one(index: int, total: int, spc: Path, opts: Options) -> Result:
    stem = spc.stem
    prefix = f"{index:04d}-{stem}"
    ref_wav = opts.out_dir / f"{prefix}.reference.wav"
    cand_wav = opts.out_dir / f"{prefix}.candidate.wav"
    ref_log = opts.out_dir / f"{prefix}.reference.log"
    cand_log = opts.out_dir / f"{prefix}.candidate.log"

    ref_rc = render_backend(opts.reference, spc, ref_wav, ref_log, opts)
    if ref_rc != 0:
        return Result(
            "ERROR",
            index,
            total,
            spc,
            "reference-render-failed",
            "",
            f"reference render failed: {ref_log}",
        )

    cand_rc = render_backend(opts.candidate, spc, cand_wav, cand_log, opts)
    ref_hash = sha256_file(ref_wav)
    if cand_rc != 0:
        return Result(
            "ERROR",
            index,
            total,
            spc,
            ref_hash,
            "candidate-render-failed",
            f"candidate render failed: {cand_log}",
        )

    cand_hash = sha256_file(cand_wav)
    if ref_wav.read_bytes() == cand_wav.read_bytes():
        if not opts.keep_matching:
            ref_wav.unlink(missing_ok=True)
            cand_wav.unlink(missing_ok=True)
        return Result("MATCH", index, total, spc, ref_hash, cand_hash)

    return Result("MISMATCH", index, total, spc, ref_hash, cand_hash)


def print_result(result: Result, completed: int) -> None:
    print(f"[{completed}/{result.total}] #{result.index} {result.spc}", flush=True)
    if result.status == "MATCH":
        print(f"  match {result.reference_hash}", flush=True)
    elif result.status == "MISMATCH":
        print("  mismatch", flush=True)
        print(f"    reference {result.reference_hash}", flush=True)
        print(f"    candidate {result.candidate_hash}", flush=True)
    else:
        print(f"  {result.message}", flush=True)


def write_report(
    opts: Options,
    total: int,
    matches: int,
    mismatches: int,
    errors: int,
    summary: Path,
    jobs: int,
) -> None:
    report = opts.out_dir / "report.txt"
    report.write_text(
        "\n".join(
            [
                f"reference: {opts.reference}",
                f"candidate: {opts.candidate}",
                f"render_mode: {opts.render_mode}",
                f"chunk_samples: {opts.chunk_samples}",
                f"seconds: {opts.seconds or 'auto'}",
                f"jobs: {jobs}",
                f"total: {total}",
                f"matches: {matches}",
                f"mismatches: {mismatches}",
                f"errors: {errors}",
                f"summary: {summary}",
                "",
            ]
        )
    )
    print(report.read_text(), end="")


def main() -> int:
    args = parse_args()
    reference = Path(args.reference)
    candidate = Path(args.candidate)
    out_dir = Path(args.out_dir)

    if not reference.is_file() or not os.access(reference, os.X_OK):
        raise SystemExit(f"reference is not executable: {reference}")
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise SystemExit(f"candidate is not executable: {candidate}")
    if args.jobs < 1:
        raise SystemExit("--jobs must be at least 1")

    files = expand_spc_inputs(args.spc)
    out_dir.mkdir(parents=True, exist_ok=True)
    summary = out_dir / "summary.tsv"
    summary.write_text("status\tindex\tspc\treference_sha256\tcandidate_sha256\n")

    opts = Options(
        reference=reference,
        candidate=candidate,
        out_dir=out_dir,
        seconds=args.seconds,
        keep_matching=args.keep_matching,
        stop_on_mismatch=args.stop_on_mismatch,
        render_mode=args.render_mode,
        chunk_samples=args.chunk_samples,
    )

    matches = 0
    mismatches = 0
    errors = 0
    completed = 0
    should_stop = False

    executor = concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs)
    futures = [
        executor.submit(compare_one, index, len(files), spc, opts)
        for index, spc in enumerate(files, start=1)
    ]

    try:
        with summary.open("a") as summary_handle:
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                completed += 1
                print_result(result, completed)
                summary_handle.write(
                    f"{result.status}\t{result.index}\t{result.spc}\t"
                    f"{result.reference_hash}\t{result.candidate_hash}\n"
                )
                summary_handle.flush()

                if result.status == "MATCH":
                    matches += 1
                elif result.status == "MISMATCH":
                    mismatches += 1
                else:
                    errors += 1

                if opts.stop_on_mismatch and result.status != "MATCH":
                    should_stop = True
                    for pending in futures:
                        pending.cancel()
                    break
    finally:
        executor.shutdown(wait=True, cancel_futures=True)

    total = completed if should_stop else len(files)
    write_report(opts, total, matches, mismatches, errors, summary, args.jobs)
    return 1 if mismatches or errors else 0


if __name__ == "__main__":
    sys.exit(main())
