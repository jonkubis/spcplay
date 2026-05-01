# SNESAPU ARM64 Backend

This directory contains the native Apple Silicon SNESAPU backend in
`SNESAPUArm64.cpp`.

The ARM64 backend exports the same public SNESAPU symbols and public state
globals consumed by the macOS tools, but uses the normal ARM64 C ABI instead of
the x86 stack-argument ABI. The AppKit frontend and command-line tools select
the correct call path at compile time.

Important status caveat: this backend is functional and buildable, but it is not
yet declared bit-perfect. The `x86_64` NASM/Mach-O backend remains the
compatibility slice for the universal app, and the ARM64 DSP work should keep
ratcheting against the corrected x86 reference once the pending x86 fixes from
the Windows session are available.

Build commands:

```sh
./scripts/build-spc2wav-arm64-candidate.sh
./scripts/build-spcplay-macos-app.sh arm64
./scripts/build-spcplay-macos-app.sh universal
```

The ARM64 output packer currently supports the same WAV sample formats exposed
through the UI/helper path: mono or stereo, 8/16/24/32-bit integer PCM, and
32-bit float WAV.
