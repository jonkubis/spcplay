## macOS port status

This repository was unpacked on April 26, 2026 and is being ported on an `arm64` Mac.

### Current milestone

1. `snesapu.dll/APU.asm`, `DSP.asm`, and `SPC700.asm` now all assemble as `macho64`.
2. The SNESAPU core now links into an `x86_64` macOS dynamic library at `build-macos-x86_64/libsnesapu.dylib`.
3. The macOS-side runtime harness now builds at `build-macos-x86_64/spc2wav` and renders byte-identical output to the verified Windows x64 SNESAPU port for the current reference SPC.
4. A live SNESAPU-backed macOS app bundle now builds at `build-macos-x86_64/spcplay-macos.app`, with a compact SPCPlay-style window, playlist loading/editing, WAV export, live playback, seek, channel mute buttons, master/voice meters, amp/speed controls, and native `File` / `Settings` / `Playlist` menus.
5. A provisional native Apple Silicon backend now builds at `build-macos-arm64/libsnesapu.dylib`, and the app build script can produce `x86_64`, `arm64`, or `universal` app bundles.
6. The original player and tools are still Delphi/Windows frontends (`spcplay.dpr`, `spccmd.dpr`, `spcbpm.dpr`), so the remaining product-level work is native polish and deeper parity for the long-tail Windows options.

### Work completed so far

1. The Windows source archive was extracted into this workspace.
2. `nasm` was installed locally so the original assembly could be ported instead of replaced.
3. The shared NASM helper macros were updated for 64-bit register mapping and Mach-O symbol naming.
4. The public headers now expose pointer-sized `uptr`/`sptr` types and the obvious pointer-as-integer declarations have been widened.
5. `APU.asm` and `DSP.asm` were ported to `macho64`.
6. `SPC700.asm` was ported to `macho64`, including:
   - 64-bit opcode/function dispatch tables
   - Script700 pointer/table access fixes
   - callback and debug-path operand-size cleanup
   - shared `EBP` continuation-path conversion to `RBP`
   - explicit replacements for `DAA` and `DAS`, which are unavailable in 64-bit mode
7. A reproducible core build script now exists at `scripts/build-snesapu-dylib.sh`.
8. A reproducible `x86_64` macOS render harness now exists at `scripts/build-spc2wav.sh` with source in `tools/spc2wav.cpp`.
9. A reproducible macOS app-bundle build now exists at `scripts/build-spcplay-macos-app.sh` with source in `tools/spcplay_macos.mm`.

### Latest verified checkpoint (Apr 29, 2026)

The Windows handoff in `MAC_GUI_HANDOFF_2026-04-29.md` brought over a fully tested x64 SNESAPU port. The Mac build was rebuilt from that source and then checked against the Windows x64 reference artifact:

```sh
./build-macos-x86_64/spc2wav "/Volumes/Dropbox SSD/Dropbox/SNES/Secret of Mana (EMU).zophar/01 Fear of the Heavens.spc" ./build-macos-x86_64/fear-of-the-heavens-mac.wav
shasum -a 256 reference-windows/artifacts/fear-x64-clean.wav build-macos-x86_64/fear-of-the-heavens-mac.wav
cmp reference-windows/artifacts/fear-x64-clean.wav build-macos-x86_64/fear-of-the-heavens-mac.wav
```

Result:

```text
ef796973af9fd7a67474d9d267f0a5b27d1c4ff1c4446ebc1baa471bc5f2ec02  reference-windows/artifacts/fear-x64-clean.wav
ef796973af9fd7a67474d9d267f0a5b27d1c4ff1c4446ebc1baa471bc5f2ec02  build-macos-x86_64/fear-of-the-heavens-mac.wav
```

The embedded helper inside `build-macos-x86_64/spcplay-macos.app/Contents/MacOS/spc2wav` was also rendered and compared with the same hash, confirming the app launches the verified core path.

### Latest Mac UI checkpoint (Apr 30, 2026)

The AppKit frontend has been moved from a generic test shell toward the original compact SPCPlay surface:

1. The main window is fixed-size and laid out around the Windows-style `File`, `Settings`, and `Playlist` header labels.
2. Title, game, and precise elapsed time are shown in the same tight ID666 metadata area as the original player.
3. The right-side playlist uses a compact no-header table with append/remove/clear/up/down controls.
4. The lower transport row now has `OPEN`, `SAVE`, `PLAY`/`PAUSE`, `RESTART`, `STOP`, channel `1`-`8`, `VL-`/`VL+`, `SP-`/`SP+`, `REW`, and `FF`.
5. The meter view now draws a black classic-style master/voice meter strip instead of modern horizontal bars.
6. The native macOS menu bar now exposes the high-value player actions under `File`, `Settings`, and `Playlist`.
7. The window title updates to `<filename> - SNES SPC700 Player`, matching the Windows title-bar convention.
8. Drag/drop loading now accepts SPC files, `.sp0`-`.sp9` variants, folders, and `.lst` playlists; playlist saving writes SPCPlay type-B UTF-8 `.lst` files.
9. The live audio path now mirrors Windows SPCPlay's default `waveOut` model more closely: 8 queued buffers, 17 ms per buffer, and `EmuAPU(..., type=0)` cycle-count rendering on a producer thread. The CoreAudio real-time callback only drains queued PCM, including odd device requests such as 371 frames.

The packaged helper path was rechecked after this UI work:

```sh
./build-macos-x86_64/spcplay-macos.app/Contents/MacOS/spc2wav "/Users/jonkubis/Downloads/Secret of Mana (EMU).zophar/01 Fear of the Heavens.spc" build-macos-x86_64/fear-gui-regression.wav
SNESAPU_RENDER_CYCLES=1 SNESAPU_CHUNK_SAMPLES=544 ./build-macos-x86_64/spc2wav "/Users/jonkubis/Downloads/Secret of Mana (EMU).zophar/01 Fear of the Heavens.spc" build-macos-x86_64/fear-cycles-17ms-full.wav
shasum -a 256 reference-windows/artifacts/fear-x64-clean.wav build-macos-x86_64/fear-gui-regression.wav
shasum -a 256 reference-windows/artifacts/fear-x64-clean.wav build-macos-x86_64/fear-cycles-17ms-full.wav
cmp reference-windows/artifacts/fear-x64-clean.wav build-macos-x86_64/fear-gui-regression.wav
cmp reference-windows/artifacts/fear-x64-clean.wav build-macos-x86_64/fear-cycles-17ms-full.wav
./build-macos-x86_64/spcplay-macos.app/Contents/MacOS/spcplay-macos --smoke-live-render "/Users/jonkubis/Downloads/Secret of Mana (EMU).zophar/01 Fear of the Heavens.spc"
```

Result:

```text
ef796973af9fd7a67474d9d267f0a5b27d1c4ff1c4446ebc1baa471bc5f2ec02  reference-windows/artifacts/fear-x64-clean.wav
ef796973af9fd7a67474d9d267f0a5b27d1c4ff1c4446ebc1baa471bc5f2ec02  build-macos-x86_64/fear-gui-regression.wav
ef796973af9fd7a67474d9d267f0a5b27d1c4ff1c4446ebc1baa471bc5f2ec02  build-macos-x86_64/fear-cycles-17ms-full.wav
```

All three WAV files are `11904044` bytes.

The live-render smoke test also passes, covering the CoreAudio-style pull sequence `{371, 512, 128, 544, 371, 735, 64, 1024, 512, 371}` without calling SNESAPU with unsafe arbitrary sample counts and without any detected live-buffer underruns.

### Runtime checkpoint

1. A real SPC test case is now in use:
   - `/Volumes/Dropbox SSD/Dropbox/SNES/Secret of Mana (EMU).zophar/01 Fear of the Heavens.spc`
2. The runtime now gets through:
   - `InitAPU`
   - `SetAPUOpt`
   - `SetDSPAmp`
   - `LoadSPCFile`
   - `EmuAPU`
   - live SPC opcode execution
   - Script700 command execution
   - the full `RunDSP` voice-mixing loop
   - the `RunDSP` output packing path
   - `EmuDSP` writeback through `XRegs`
   - real WAV output through `spc2wav`
3. Verified outputs now exist at:
   - `build-macos-x86_64/fear-of-the-heavens-mac.wav`
   - `build-macos-x86_64/fear-of-the-heavens-bundle-helper.wav`
   - `reference-windows/artifacts/fear-x64-clean.wav`
4. The recent host64 fixes included:
   - dedicated 64-bit direct-page base state in `SPC700.asm`
   - promotion of direct-page dereferences from `EBX` to `RBX`
   - promotion of main APU RAM access from `EDI` to `RDI` on `HOST64`
   - Script700 program/data/RAM pointer cleanup so it no longer truncates `pSCRRAM`/`pAPURAM`
   - counter reset/speed-hack cleanup in `ResetCnt` and `CntHack`
   - host64 DSP voice-state cleanup so `sIdx`/`bCur` now behave as offsets instead of truncated absolute pointers
   - `RunDSP` stack-frame and return-path fixes for `RSP`/`RAX`
   - first host64 fixes for the live mix loop in `MixSample`, `MixVoice`, `PitchMod`, `UpdateSrc`, `UpdateEnv`, `CalRamp1`, and `CalRamp2`
   - host64 fixes for `MixMaster`, `MixEchoDSP`, `MixEchoMem`, `MixBASS`, `ApplyLevel`, `MixAAF`, `Resampling`, and the mono/stereo output packers
   - host64 FIR-filter cleanup for `FIRFilter`, `FIRCut16`, `FIRClampL`, and `FIRClampH`
   - output-buffer pointer cleanup in `SetEmuDSP` and `EmuDSP` so `pOutBuf` no longer truncates to 32 bits
   - `EmuDSP.XRegs` and `StartSrc` host64 pointer cleanup so the render loop can return to another source block
   - interpolation helper cleanup in `LinearInt`, `Point4Int`, and `Point8Int` so table and stack references no longer truncate on `HOST64`
   - `MixSample`/`MixVoice` table-pointer cleanup for `nSmp`, `envCrt`, `scr700dsp`, and `scr700vol`
   - SPC700 stack macro cleanup in `PushB`, `PushW`, `PopB`, and `PopW`
   - BRR block-transition cleanup in `UpdateSrc`, including `RSI`-based block-header reads and a host64-safe loop-point offset calculation
   - a final `UpdateSrc` loop-point fix where a host64 `ECX` scratch register was overwriting `CH`, the active voice bitmask for `RunDSP`, and causing a fake ninth-voice walk into `dsp`
5. The current host-side state is:
   - the faithful SNESAPU core renders successfully on macOS `x86_64`
   - `spc2wav` is now a working regression harness for future runtime changes
   - the Mac helper now defaults to the original Windows wave-export style path: sample-unit `EmuAPU(..., type=1)` calls with 100 ms (`3200` sample at `32 kHz`) chunks, and the AppKit frontend now requests that path explicitly
   - the Mac UI now links directly to `libsnesapu.dylib` and streams live audio through `AVAudioSourceNode`; the bundled `spc2wav` helper remains for WAV export and regression checks
   - live UI controls now include seek, restart, previous/next, playlist add/remove/clear/up/down, drag/drop loading, playlist save/load, per-channel mute toggles, amp/speed buttons, native menus, and DSP master/voice meters
   - the Mac UI now uses a compact classic SPCPlay-style layout with the active filename in the title bar
   - the old "thin / wrong instrument / wrong section" suspicion is retired for the verified sample-render path because Mac output is byte-identical to the Windows x64 oracle

### Latest host64 audit pass (Apr 28, 2026)

A static audit of every `[E-reg + ...]` memory operand inside HOST64-active assembly found and fixed five classes of latent bugs where 32-bit addressing modes had been left in code paths reachable on macOS, where the shared library lives above the 4 GB boundary and pointers cannot be truncated:

1. **`SetFade` (DSP.asm)** — the song-fade sine calculation used `[ESP-4]` to spill a 32-bit integer to the red zone. On HOST64 this aliased a low-32 fragment of the actual `RSP`, so the value reloaded for the `FILd`/`FIStP` cycle was garbage. Wrapped the four affected lines in `%ifdef HOST64` and switched to `[RSP-4]` on HOST64.
2. **`ChnSep` (DSP.asm)** — the floating-point body of the stereo-separation routine read `mTgtR`/`mTgtL` through `[EBX+...]` after the prologue had already been promoted to `[RBX+...]`. With non-zero `volSepar`, this pulled garbage into the FPU and stored a corrupt mTgtL/mTgtR back into the voice. Promoted the two `FILd dword [EBX+mTgtR/L]` lines under `%ifdef HOST64`.
3. **`RFlg` (DSP.asm)** — the soft-reset path of the FLG register handler unconditionally wrote `[EBX+flg]`, `[EBX+endx]`, `[EBX+kon]`, `[EBX+kof]` even though the prologue had `Lea RBX,[rel dsp]` for HOST64. Triggered any time an SPC strobed FLG bit 7. Promoted the four stores to `[RBX+...]` on HOST64.
4. **`Func1` IPL toggle (SPC700.asm)** — the ROM-readable transition wrote and read `extraRAM`/`iplROM` through `Lea EDX,[rel extraRAM]` (note `EDX`, not `RDX`). The `lea r/m32` form sign-extends RIP+disp to the low 32 bits and zeroes the upper 32 — so on macOS the resulting "pointer" was a low-32 fragment that landed nowhere near the actual data section. Replaced with `Lea RDX,[rel ...]` and updated indexed reads/writes to `[RDX+RCX]`.
5. **`InPort` (SPC700.asm)** — same `Lea EDX,[rel inPortCp/flushPort]` truncation, and additionally the trailing `Mov [ECX+0F4h],AL` that wrote into APU RAM after `Add RCX,R8` used the 32-bit `ECX` form (truncating the just-formed full pointer). Promoted the LEAs to `RDX`, the indexed stores to `[RDX+RCX]`, and moved the `[ECX+0F4h]` store inside the `%ifdef HOST64` branch using `[RCX+0F4h]`.

Audit method: a static parser walks each `.asm` file, tracks the `%ifdef HOST64` / `%else` stack, and flags every `[E-reg ...]` memory operand reachable from HOST64-active code. After the five fixes above, the remaining matches are all either pure 32-bit LEA arithmetic (zero-extension is intended), `%if STEREO=0` dead code (we build with `STEREO=1`), the `UnpckSrcOld` path (only reached with `DSP_OLDSMP`, off by default), or the post-`Jmp %%Done` 32-bit fall-through inside `MixVoice`'s VMETERV macro.

Note on output level: with these fixes plus the existing PORTING_MACOS.md changes, `spc2wav` at the default `kAmp100 = 65536` (1.0× SNES native) renders SMW SPCs at 12-15 % peak amplitude, which is the mathematically correct level given those songs' DSP master/voice volumes — empirically setting `SetDSPAmp(65536*8)` saturates the output, confirming the volume chain is linear. If the original Win32 player sounds louder, the difference is in the player's amp slider or post-processing, not in the DLL.

### How to reproduce

Assembler probe:

```sh
./scripts/probe-macho64.sh
```

Build the current macOS core library:

```sh
./scripts/build-snesapu-dylib.sh
```

Build the current macOS render harness:

```sh
./scripts/build-spc2wav.sh
```

Build the first macOS app bundle:

```sh
./scripts/build-spcplay-macos-app.sh
```

Build native or universal app bundles:

```sh
./scripts/build-spcplay-macos-app.sh arm64
./scripts/build-spcplay-macos-app.sh universal
```

### What still blocks full Windows parity

1. The native Apple Silicon backend is functional but still provisional; do not call it bit-perfect until it is re-ratcheted against the corrected x86 reference backend.
2. The new AppKit frontend covers the primary player surface, but does not yet cover the full Windows feature set:
   - no Script700 file loading UI yet
   - no DSP register editor, SPC RAM/register editor, or cheat/debug panes yet
   - no full port of the original information/debug panes yet
3. The 64-bit callback/debug calling paths still need deeper runtime validation under macOS, even though they now assemble, link, and survive real rendering.
4. The NASM build still emits low-signal macro warnings; they are not blocking the link, but the build should be cleaned up before calling the port finished.

### Native Apple Silicon checkpoint (Apr 30, 2026)

The ARM64 porting effort has started by freezing the existing macOS `x86_64`
SNESAPU backend as the reference oracle instead of modifying it in place.

Update: the ARM64 backend now builds far enough to produce a native app bundle
and a universal app bundle. The universal package contains fat `spcplay-macos`,
`spc2wav`, and `libsnesapu.dylib` binaries. The default `x86_64` slice remains
the safer compatibility path while the x86 reference discrepancies found in the
parallel Windows session are being corrected.

New support files:

```sh
./scripts/snapshot-snesapu-x86_64-reference.sh
./scripts/compare-snesapu-backends.sh
./scripts/build-spc2wav-arm64-candidate.sh
./scripts/build-spc-loadstate.sh
./scripts/compare-snesapu-loadstate.sh
```

The intended universal build shape is:

1. Keep the verified NASM/Mach-O backend for the `x86_64` slice.
2. Build a separate ARM64 backend that exports the same SNESAPU public symbols
   with normal ARM64 C ABI.
3. Validate every ARM64 milestone by comparing `spc2wav` WAV bytes against the
   x86_64 reference renderer.

See `ARM64_PORTING_PLAN.md` for the current ratchet and backend milestones.

### Next faithful-port steps

1. Port the next layer of Windows settings UI:
   - Script700 loading
   - DSP register inspection/editing
   - SPC register/RAM inspection
   - channel/noise/echo option panes
2. Runtime-audit the linked `libsnesapu.dylib`, especially callback/debug paths and pointer-bearing DSP/SPC state, using `spc2wav` as the regression harness.
3. Decide whether the first Mac deliverable should remain `x86_64`-only under Rosetta or whether to begin a second-stage native Apple Silicon effort.
