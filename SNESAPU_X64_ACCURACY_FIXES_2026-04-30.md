# SNESAPU x64 Accuracy Fix Log - 2026-04-30

This is the living handoff log for the x86 oracle vs x64 SNESAPU byte-accuracy work.
The goal is byte-identical WAV output from the 64-bit port against the original 32-bit
assembly oracle.

## Current Test Harness

- Corpus under test: `Z:\SPCs`
- Corpus size at verifier launch: 4,406 flat `.spc` paths.
- Corpus size after the run completed: 4,377 live `.spc` files.
- x86 oracle renderer: `C:\Temp\spc-check-20260430-oracle-x86\spc2wav.exe`
- x64 current renderer: `C:\Temp\spc-check-20260430-current-x64\spc2wav.exe`
- x86 oracle state dumper: `C:\Temp\spc-check-20260430-oracle-x86\spcstate.exe`
- x64 current state dumper: `C:\Temp\spc-check-20260430-current-x64\spcstate.exe`
- Limited verifier: `C:\Temp\verify-spc-oracle-vs-x64-limited.ps1`
- Active source root: `Z:\spcplay\spcplay-develop`
- Active x64 ASM source: `Z:\spcplay\spcplay-develop\snesapu.dll`

Current fresh large-corpus run:

- Output root: `C:\Temp\spc-large-corpus-20260430\after-fixes-20260430-041529`
- Shards: 4 parallel verifier processes, one for each `ShardIndex` 0..3.
- Final result: 4,377 valid renders matched byte-identically, 0 mismatches, 29 input errors, 0 saved mismatch pairs.
- Cross-check after completion: `Z:\SPCs` currently enumerates 4,377 `.spc` files, and every current live file appears in a `match` row.
- Interpretation: the x64 port matches the x86 oracle for 100% of the currently live `Z:\SPCs` corpus. The 29 errors were stale, empty, or vanished entries from the initial directory enumeration, not x64 audio mismatches.

## Fix 1: SPC700 CLRP/SETP Clobbered Live YA

Files changed:

- `Z:\spcplay\spcplay-develop\snesapu.dll\SPC700.asm`

Symptom:

- First stale mismatch: `Z:\SPCs\004 Title.spc`
- First WAV diff before fix: byte `41296`, frame `10313`.
- State bisection found first CPU-state divergence at cycle `4815169`.
- Previous matching state at cycle `4815168`:
  - `regs pc=3716 a=255 y=0 x=4 psw=129 sp=203`
- Divergent state at cycle `4815169` before fix:
  - x86: `regs pc=3717 a=255 y=0 x=4 psw=161 sp=203`
  - x64: `regs pc=3717 a=0 y=1 x=4 psw=161 sp=203`

Root cause:

- SPC PC `0x0e84` was executing `SETP` (`0x40`).
- `SETP` should only set the direct-page PSW bit.
- The x64 HOST64 path rebuilt `dpBase` using `RAX`.
- In the SPC700 interpreter, `AL/AH` are the live SPC `A/Y` registers, so using `RAX` clobbered `YA`.
- The original x86 source did not need a live `EAX` write here because it packed direct-page base into `PSW+P-1`.

Patch:

- In `Opc20` / `CLRP`, rebuild `dpBase` with `RBX` instead of `RAX`.
- In `Opc40` / `SETP`, rebuild `dpBase` with `RBX` instead of `RAX`.

Current key locations:

- `SPC700.asm:4208` `Opc20`
- `SPC700.asm:4211` `Mov RBX,[pAPURAM]`
- `SPC700.asm:5959` `Opc40`
- `SPC700.asm:5962` `Mov RBX,[pAPURAM]`

Validation:

- `spcstate` now matches at cycles `4815168`, `4815169`, and `7920384` for `004 Title.spc`.
- Re-rendered `004 Title.spc`:
  - oracle SHA-256 `EE2131A167DDAB9351FB91F62A695C3A0682B60B4F40B1DDB63FFB7E64D5010B`
  - x64 SHA-256 `EE2131A167DDAB9351FB91F62A695C3A0682B60B4F40B1DDB63FFB7E64D5010B`
- This also cleared many stale mismatches from the first saved batch.

## Fix 2: DSP ChgGain Clobbered GAIN Mode Bits in DL

Files changed:

- `Z:\spcplay\spcplay-develop\snesapu.dll\DSP.asm`

Symptom:

- Next stale mismatch after Fix 1: `Z:\SPCs\01 Capcom Logo.spc`
- First WAV diff before fix: byte `6228`, frame `1546`.
- State bisection found first state divergence at cycle `1185721`.
- SPC CPU registers still matched exactly, so the divergence was in DSP state.
- Voice 7 before fix at cycle `1185721`:
  - x86: `eMode=17 eRIdx=28 eVal=2047 eAdj=0 eDest=0`
  - x64: `eMode=16 eRIdx=28 eVal=2047 eAdj=32 eDest=0`
- The x86 mode `17` is `E_EXP | E_ADSR`; the x64 mode `16` showed ADSR state preserved but the low GAIN envelope mode was wrong.

Root cause:

- In `ChgGain`, `DL` holds the GAIN control bits used by the mode-selection tests:
  - `Test DL,60h`
  - `Test DL,40h`
  - `Test DL,20h`
- The original x86 path used `ESI` as the temporary when loading `rateTab`, preserving `DL`.
- The HOST64 path used `EDX` for the `rateTab` load:
  - `Mov EDX,[R8+RAX*4]`
- That overwrote `DL` just before the GAIN branch tests, selecting the wrong envelope mode.

Patch:

- In the HOST64 `ChgGain` direct/rate path, load `rateTab` into `ESI` instead of `EDX`.
- Store `ESI` into `eRate`/`eCnt`, mirroring the original x86 behavior.

Current key locations:

- `DSP.asm:2780` HOST64 `ChgGain`
- `DSP.asm:2794` `Mov ESI,[rel 31*4+rateTab]`
- `DSP.asm:2816` `Mov ESI,[R8+RAX*4]`
- The x86-compatible path already used `ESI` at `DSP.asm:3039` and `DSP.asm:3062`.

Validation:

- `spcstate` now matches at cycles `1185720`, `1185721`, and `1187328` for `01 Capcom Logo.spc`.
- Re-rendered `01 Capcom Logo.spc`:
  - oracle SHA-256 `C924622EF9532E29B7596FB17EB0E5F831CA956CB23C7DDEF01DF2ED67A47D15`
  - x64 SHA-256 `C924622EF9532E29B7596FB17EB0E5F831CA956CB23C7DDEF01DF2ED67A47D15`
- After Fix 1 and Fix 2, all 24 sampled stale mismatches from the earlier 4-shard run matched byte-identically.

## Prior Current-Source Fixes Already Present

These were already present in the current source when the large-corpus pass was restarted.
Keep them in the handoff because they are important for byte-accuracy and should not be
accidentally reverted by the Mac or ARM work.

### DSP volume fixup volatile-register preservation

- File: `Z:\spcplay\spcplay-develop\snesapu.dll\DSP.asm`
- Context: DSP volume/fixup loops call `InitReg`; Win64 volatile registers such as `R8` and `R9` cannot be assumed preserved across the call.
- Current source reloads `R8`/`R9` around those `InitReg` calls in the relevant loops.
- Representative locations include the blocks around `DSP.asm:1781`, `DSP.asm:1803`, `DSP.asm:1932`, and `DSP.asm:1954`.

### SPC700 timer debug probe cleanup

- File: `Z:\spcplay\spcplay-develop\snesapu.dll\SPC700.asm`
- Context: timer debug probe globals remain declared, but the destructive probe writes were removed.
- Keep this as-is; do not reintroduce writes to `dbgT0Write*` from the emulated timer state path.

## Verification Notes

Rebuild command used after each patch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Z:\spcplay\spcplay-develop\scripts\build-spc-windows-tools.ps1" -Arch x64 -SourceRoot "Z:\spcplay\spcplay-develop" -OutDir "C:\Temp\spc-check-20260430-current-x64"
```

The NASM build emits many expected `pp-macro-params-multi` warnings from the opcode table. These warnings were present before these fixes and have not indicated build failure.

Fresh corpus verifier launch:

```powershell
$script = "C:\Temp\verify-spc-oracle-vs-x64-limited.ps1"
$oracle = "C:\Temp\spc-check-20260430-oracle-x86\spc2wav.exe"
$port = "C:\Temp\spc-check-20260430-current-x64\spc2wav.exe"
$outRoot = "C:\Temp\spc-large-corpus-20260430\after-fixes-20260430-041529"

for ($i = 0; $i -lt 4; $i++) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $script,
        "-InputDirs", "Z:\SPCs",
        "-OracleExe", $oracle,
        "-PortExe", $port,
        "-OutRoot", $outRoot,
        "-ShardIndex", "$i",
        "-ShardCount", "4",
        "-MaxSavedMismatches", "25"
    ) -WindowStyle Hidden
}
```

Important monitor detail:

- Count actual mismatches with `^\[\d+/\d+\] MISMATCH`.
- Do not count plain `MISMATCH`, because the header line contains `max_saved_mismatches`.

Input errors from the fresh run:

- Total input errors: 29.
- Current status after completion: none of these paths currently exists under `Z:\SPCs`.
- 14 of the error logs explicitly said `SPC file is too small: 0 bytes`.
- The remaining 15 error logs said `failed to read SPC file: ...`.
- Because these paths are not live corpus files after completion, and because they failed before any oracle/x64 comparison, do not count them as x64 audio mismatches.

Paths with `SPC file is too small: 0 bytes` in the oracle error log:

- `Z:\SPCs\01 Halken Logo.spc`
- `Z:\SPCs\201 Kemco Logo 3.spc`
- `Z:\SPCs\202 Title Screen 3.spc`
- `Z:\SPCs\203 Select Players 3.spc`
- `Z:\SPCs\204 Level Music 3.spc`
- `Z:\SPCs\205 Clear Level 3.spc`
- `Z:\SPCs\206 High Score! 3.spc`
- `Z:\SPCs\207 Ending 3.spc`
- `Z:\SPCs\208 The End.spc`
- `Z:\SPCs\209 Game Over.spc`
- `Z:\SPCs\210 Throw Bomb.spc`
- `Z:\SPCs\211 Boom!.spc`
- `Z:\SPCs\212 _Player 1, Get Ready!_.spc`
- `Z:\SPCs\213 _Player 2, Get Ready!_.spc`

Paths with `failed to read SPC file` in the oracle error log:

- `Z:\SPCs\99 Baked Pie 3.spc`
- `Z:\SPCs\99 Big Chance 3.spc`
- `Z:\SPCs\99 Burglers Comic 3.spc`
- `Z:\SPCs\99 Dark Side 3.spc`
- `Z:\SPCs\99 Good Man!.spc`
- `Z:\SPCs\99 Good Night.spc`
- `Z:\SPCs\99 Let's Exercise.spc`
- `Z:\SPCs\99 Lost Life 2.spc`
- `Z:\SPCs\99 Main Event.spc`
- `Z:\SPCs\99 Oh My God!.spc`
- `Z:\SPCs\99 Start.spc`
- `Z:\SPCs\99 Starting Point.spc`
- `Z:\SPCs\99 Thank You.spc`
- `Z:\SPCs\99 Trouble.spc`
- `Z:\SPCs\99 Zoom.spc`
