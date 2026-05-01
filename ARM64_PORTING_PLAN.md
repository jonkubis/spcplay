# ARM64 SNESAPU Porting Plan

Started: 2026-04-30

The current macOS `x86_64` SNESAPU backend is our provisional reference
implementation. It is the Windows x64 assembly port adapted to Mach-O, and it
has rendered byte-identical WAV output against the Windows reference artifact
for the known-good `Fear of the Heavens` sample path.

As of April 30, 2026, a parallel Windows session has found discrepancies between
the original 32-bit x86 SNESAPU and the x64 port on other SPCs. Until those x64
fixes are handed back, use the current x64 backend as a compatibility slice and
local regression baseline, not as a final bit-perfect oracle for ambiguous DSP
behavior.

The ARM64 work should not rewrite or "clean up" that backend while the native
port is in progress. The safest shape for the universal Mac app is:

- `x86_64` slice: keep the existing NASM/Mach-O assembly backend and its
  stack-argument call shims.
- `arm64` slice: add a separate backend that exports the same SNESAPU symbols
  with the normal ARM64 C ABI.
- Shared app/tool layer: compare both through `spc2wav` until the ARM64 backend
  is byte-identical for the reference SPC corpus.

## Recommendation

Porting SNESAPU to clean C/C++ semantics first is the right move before writing
any hand ARM64 assembly.

The original code relies heavily on x86 register aliasing, flags, stack layout,
and custom calling behavior. A direct hand-ARM rewrite would force us to solve
translation and correctness at the same time. A clean semantic port lets us lock
down behavior against the x86_64 oracle, then decide later whether specific DSP
hot paths deserve NEON or hand assembly.

In other words: first make it exact, then make it fast.

## Reference Invariants

- Do not destabilize `snesapu.dll/APU.asm`, `DSP.asm`, `SPC700.asm`, or
  `SNESAPU.cpp` while working on ARM64.
- Keep the `build-macos-x86_64` outputs available as the Rosetta oracle.
- New ARM64 code should live in a separate backend path until it can replace
  nothing and compare against everything.
- Every ARM64 milestone should be validated by rendering with the same frontend
  settings as the x86_64 reference and comparing the WAV bytes.

## Validation Ratchet

The first correctness target is exact WAV equality through the existing
`spc2wav` harness.

Recommended initial corpus:

- `/Users/jonkubis/Downloads/Secret of Mana (EMU).zophar/01 Fear of the Heavens.spc`
- The full `/Users/jonkubis/Downloads/Secret of Mana (EMU).zophar` folder
- The Windows handoff corpus once copied/available on this Mac

For each candidate change:

1. Build the x86_64 reference renderer.
2. Build the ARM64 candidate renderer.
3. Render the same SPC inputs with the same output options.
4. Require byte-identical WAV files before treating the milestone as complete.

Use:

```sh
./scripts/compare-snesapu-backends.sh \
  --reference ./build-macos-x86_64/spc2wav \
  --candidate ./build-macos-arm64/spc2wav \
  --spc "/Users/jonkubis/Downloads/Secret of Mana (EMU).zophar"
```

## Backend Milestones

1. Freeze and snapshot the current x86_64 backend.
2. Isolate public API calls behind a tiny architecture-aware bridge in the tools
   and app.
3. Create an ARM64 backend that exports the SNESAPU public symbols and the state
   globals used by the current tools.
4. Port state layout exactly: APU RAM, extra RAM, DSP registers, voice state,
   timers, counters, Script700 state, and public debug/meter globals.
5. Port loader/reset/fixup paths first so SPC state snapshots match after
   `LoadSPCFile`.
6. Port deterministic stepping and context save/restore so `spcdiag` can compare
   CPU/DSP state before full audio rendering is correct.
7. Port DSP decode/mix/output in small pieces, validating short renders and then
   full-song renders.
8. Port the full SPC700 opcode engine and timing paths until the full corpus is
   byte-identical.
9. Only after byte equality: optimize ARM64 hotspots.

## Current First-Step Tools

- `scripts/snapshot-snesapu-x86_64-reference.sh` captures the current reference
  source files, build scripts, and x86_64 artifacts with SHA-256 manifests.
- `scripts/compare-snesapu-backends.sh` renders the same SPC inputs with two
  renderer binaries and reports byte-level WAV matches/mismatches.
- `scripts/build-spc2wav-arm64-candidate.sh` checks that the shared `spc2wav`
  frontend is ARM64-clean and builds the native ARM64 candidate renderer.
- `scripts/build-spcplay-macos-app.sh arm64` builds a native Apple Silicon app
  bundle, and `scripts/build-spcplay-macos-app.sh universal` packages fat app,
  helper, and SNESAPU dylib binaries.
- `scripts/build-spc-loadstate.sh` and `scripts/compare-snesapu-loadstate.sh`
  compare the deterministic `LoadSPCFile` state layer before the audio engine is
  expected to match. Use `--scope core` for the first loader/register/RAM
  milestone, and `--scope full` once `FixDSP` and mixer state are ported.
