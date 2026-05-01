#ifndef SPCPLAY_TOOLS_SNESAPU_CALL_BRIDGE_H
#define SPCPLAY_TOOLS_SNESAPU_CALL_BRIDGE_H

#include "types.h"
#include "DSP.h"
#include "APU.h"
#include "SPC700.h"

#if defined(_WIN32)

extern "C" u32 call_InitAPU(u32 reason);
extern "C" void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts);
extern "C" void call_SetAPUSmpClk(u32 speed);
extern "C" u32 call_SetAPULength(u32 song, u32 fade);
extern "C" void call_SetDSPPitch(u32 pitch);
extern "C" void call_SetDSPStereo(u32 separation);
extern "C" void call_SetDSPEFBCT(s32 leak);
extern "C" void call_SetDSPAmp(u32 amp);
extern "C" b8 call_SetDSPReg(u8 reg, u8 val);
extern "C" DSPDebug *call_SetDSPDbg(DSPDebug *trace);
extern "C" void call_LoadSPCFile(void *spc);
extern "C" void *call_EmuAPU(void *buffer, u32 length, u8 type);
extern "C" s32 call_EmuSPC(s32 cycles);
extern "C" void call_GetAPUData(u8 **ram, u8 **xram, u8 **out_port, u32 **t64_count, DSPReg **dsp_regs, Voice **voices, u32 **v_mmax_l, u32 **v_mmax_r);
extern "C" void call_SeekAPU(u32 time, u8 fast);
extern "C" u32 call_GetSNESAPUContextSize();
extern "C" void call_GetSNESAPUContext(void *ctx);
extern "C" void call_SetSNESAPUContext(void *ctx);
extern "C" void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp);

#elif defined(__aarch64__)

static inline u32 call_InitAPU(u32 reason) {
    return InitAPU(reason);
}

static inline void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
    SetAPUOpt(mix_type, num_channels, bits, rate, inter, opts);
}

static inline void call_SetAPUSmpClk(u32 speed) {
    SetAPUSmpClk(speed);
}

static inline u32 call_SetAPULength(u32 song, u32 fade) {
    return SetAPULength(song, fade);
}

static inline void call_SetDSPPitch(u32 pitch) {
    SetDSPPitch(pitch);
}

static inline void call_SetDSPStereo(u32 separation) {
    SetDSPStereo(separation);
}

static inline void call_SetDSPEFBCT(s32 leak) {
    SetDSPEFBCT(leak);
}

static inline void call_SetDSPAmp(u32 amp) {
    SetDSPAmp(amp);
}

static inline b8 call_SetDSPReg(u8 reg, u8 val) {
    return SetDSPReg(reg, val);
}

static inline DSPDebug *call_SetDSPDbg(DSPDebug *trace) {
    return SetDSPDbg(trace);
}

static inline void call_LoadSPCFile(void *spc) {
    LoadSPCFile(spc);
}

static inline void *call_EmuAPU(void *buffer, u32 length, u8 type) {
    return EmuAPU(buffer, length, type);
}

static inline s32 call_EmuSPC(s32 cycles) {
    return EmuSPC(cycles);
}

static inline void call_GetAPUData(u8 **ram, u8 **xram, u8 **out_port, u32 **t64_count, DSPReg **dsp_regs, Voice **voices, u32 **v_mmax_l, u32 **v_mmax_r) {
    GetAPUData(ram, xram, out_port, t64_count, dsp_regs, voices, v_mmax_l, v_mmax_r);
}

static inline void call_SeekAPU(u32 time, u8 fast) {
    SeekAPU(time, static_cast<b8>(fast));
}

static inline u32 call_GetSNESAPUContextSize() {
    return GetSNESAPUContextSize();
}

static inline void call_GetSNESAPUContext(void *ctx) {
    GetSNESAPUContext(ctx);
}

static inline void call_SetSNESAPUContext(void *ctx) {
    SetSNESAPUContext(ctx);
}

static inline void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp) {
    GetSPCRegs(pc, a, y, x, psw, sp);
}

#elif defined(__x86_64__)

#define SNESAPU_CALL_CLOBBERS \
    "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory", "cc"

static inline u32 call_InitAPU(u32 reason) {
    u64 ret = 0;
    const u64 arg0 = reason;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _InitAPU\n\t"
        "add $8, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0)
        : SNESAPU_CALL_CLOBBERS);
    return static_cast<u32>(ret);
}

static inline void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
    const u64 arg0 = mix_type;
    const u64 arg1 = num_channels;
    const u64 arg2 = bits;
    const u64 arg3 = rate;
    const u64 arg4 = inter;
    const u64 arg5 = opts;
    asm volatile(
        "pushq %[arg5]\n\t"
        "pushq %[arg4]\n\t"
        "pushq %[arg3]\n\t"
        "pushq %[arg2]\n\t"
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _SetAPUOpt\n\t"
        "add $48, %%rsp\n\t"
        :
        : [arg0] "m"(arg0), [arg1] "m"(arg1), [arg2] "m"(arg2),
          [arg3] "m"(arg3), [arg4] "m"(arg4), [arg5] "m"(arg5)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_SetAPUSmpClk(u32 speed) {
    const u64 arg0 = speed;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetAPUSmpClk\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline u32 call_SetAPULength(u32 song, u32 fade) {
    u64 ret = 0;
    const u64 arg0 = song;
    const u64 arg1 = fade;
    asm volatile(
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _SetAPULength\n\t"
        "add $16, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0), [arg1] "m"(arg1)
        : SNESAPU_CALL_CLOBBERS);
    return static_cast<u32>(ret);
}

static inline void call_SetDSPPitch(u32 pitch) {
    const u64 arg0 = pitch;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPPitch\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_SetDSPStereo(u32 separation) {
    const u64 arg0 = separation;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPStereo\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_SetDSPEFBCT(s32 leak) {
    const s64 arg0 = leak;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPEFBCT\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_SetDSPAmp(u32 amp) {
    const u64 arg0 = amp;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPAmp\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline b8 call_SetDSPReg(u8 reg, u8 val) {
    u64 ret = 0;
    const u64 arg0 = reg;
    const u64 arg1 = val;
    asm volatile(
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _SetDSPReg\n\t"
        "add $16, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0), [arg1] "m"(arg1)
        : SNESAPU_CALL_CLOBBERS);
    return static_cast<b8>(ret);
}

static inline DSPDebug *call_SetDSPDbg(DSPDebug *trace) {
    u64 ret = 0;
    const u64 arg0 = reinterpret_cast<u64>(trace);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPDbg\n\t"
        "add $8, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0)
        : SNESAPU_CALL_CLOBBERS);
    return reinterpret_cast<DSPDebug *>(ret);
}

static inline void call_LoadSPCFile(void *spc) {
    const u64 arg0 = reinterpret_cast<u64>(spc);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _LoadSPCFile\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void *call_EmuAPU(void *buffer, u32 length, u8 type) {
    u64 ret = 0;
    const u64 arg0 = reinterpret_cast<u64>(buffer);
    const u64 arg1 = length;
    const u64 arg2 = type;
    asm volatile(
        "pushq %[arg2]\n\t"
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _EmuAPU\n\t"
        "add $24, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0), [arg1] "m"(arg1), [arg2] "m"(arg2)
        : SNESAPU_CALL_CLOBBERS);
    return reinterpret_cast<void *>(ret);
}

static inline s32 call_EmuSPC(s32 cycles) {
    u64 ret = 0;
    const s64 arg0 = cycles;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _EmuSPC\n\t"
        "add $8, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0)
        : SNESAPU_CALL_CLOBBERS);
    return static_cast<s32>(ret);
}

static inline void call_GetAPUData(u8 **ram, u8 **xram, u8 **out_port, u32 **t64_count, DSPReg **dsp_regs, Voice **voices, u32 **v_mmax_l, u32 **v_mmax_r) {
    const u64 arg0 = reinterpret_cast<u64>(ram);
    const u64 arg1 = reinterpret_cast<u64>(xram);
    const u64 arg2 = reinterpret_cast<u64>(out_port);
    const u64 arg3 = reinterpret_cast<u64>(t64_count);
    const u64 arg4 = reinterpret_cast<u64>(dsp_regs);
    const u64 arg5 = reinterpret_cast<u64>(voices);
    const u64 arg6 = reinterpret_cast<u64>(v_mmax_l);
    const u64 arg7 = reinterpret_cast<u64>(v_mmax_r);
    asm volatile(
        "pushq %[arg7]\n\t"
        "pushq %[arg6]\n\t"
        "pushq %[arg5]\n\t"
        "pushq %[arg4]\n\t"
        "pushq %[arg3]\n\t"
        "pushq %[arg2]\n\t"
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _GetAPUData\n\t"
        "add $64, %%rsp\n\t"
        :
        : [arg0] "m"(arg0), [arg1] "m"(arg1), [arg2] "m"(arg2),
          [arg3] "m"(arg3), [arg4] "m"(arg4), [arg5] "m"(arg5),
          [arg6] "m"(arg6), [arg7] "m"(arg7)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_SeekAPU(u32 time, u8 fast) {
    const u64 arg0 = time;
    const u64 arg1 = fast;
    asm volatile(
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _SeekAPU\n\t"
        "add $16, %%rsp\n\t"
        :
        : [arg0] "m"(arg0), [arg1] "m"(arg1)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline u32 call_GetSNESAPUContextSize() {
    u64 ret = 0;
    asm volatile(
        "call _GetSNESAPUContextSize\n\t"
        : "=a"(ret)
        :
        : SNESAPU_CALL_CLOBBERS);
    return static_cast<u32>(ret);
}

static inline void call_GetSNESAPUContext(void *ctx) {
    const u64 arg0 = reinterpret_cast<u64>(ctx);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _GetSNESAPUContext\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_SetSNESAPUContext(void *ctx) {
    const u64 arg0 = reinterpret_cast<u64>(ctx);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetSNESAPUContext\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

static inline void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp) {
    const u64 arg0 = reinterpret_cast<u64>(pc);
    const u64 arg1 = reinterpret_cast<u64>(a);
    const u64 arg2 = reinterpret_cast<u64>(y);
    const u64 arg3 = reinterpret_cast<u64>(x);
    const u64 arg4 = reinterpret_cast<u64>(psw);
    const u64 arg5 = reinterpret_cast<u64>(sp);
    asm volatile(
        "pushq %[arg5]\n\t"
        "pushq %[arg4]\n\t"
        "pushq %[arg3]\n\t"
        "pushq %[arg2]\n\t"
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _GetSPCRegs\n\t"
        "add $48, %%rsp\n\t"
        :
        : [arg0] "m"(arg0), [arg1] "m"(arg1), [arg2] "m"(arg2),
          [arg3] "m"(arg3), [arg4] "m"(arg4), [arg5] "m"(arg5)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

#undef SNESAPU_CALL_CLOBBERS

#else
#error Unsupported SNESAPU host architecture.
#endif

#endif
