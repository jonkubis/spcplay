#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include "types.h"
#include "DSP.h"
#include "APU.h"
#include "SPC700.h"

namespace {

constexpr u32 kAmp100 = 65536;
constexpr u32 kDefaultRate = 32000;
constexpr u32 kDefaultSpeed = 65536;
constexpr u32 kDefaultPitch = 32000;
constexpr u32 kDefaultStereo = 32768;
constexpr s32 kDefaultEfbct = 32768;
constexpr u32 kDefaultDSPOpts = DSP_ANALOG | DSP_ECHOFIR | DSP_FLOAT;
constexpr size_t kSpcSize = 0x10200;
constexpr uintptr_t kApuRamSize = 65536;

#define SNESAPU_CALL_CLOBBERS \
    "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory", "cc"

#if defined(_WIN32) && defined(_M_X64)
extern "C" u32 call_InitAPU(u32 reason);
extern "C" void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts);
extern "C" void call_SetAPUSmpClk(u32 speed);
extern "C" void call_SetDSPPitch(u32 pitch);
extern "C" void call_SetDSPStereo(u32 separation);
extern "C" void call_SetDSPEFBCT(s32 leak);
extern "C" void call_SetDSPAmp(u32 amp);
extern "C" void call_LoadSPCFile(void *spc);
extern "C" void *call_EmuAPU(void *buffer, u32 length, u8 type);
extern "C" void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp);
extern "C" u32 cycLeft;
extern "C" u32 smpDec;
extern "C" u32 smpRate;
extern "C" u32 smpRAdj;
extern "C" u32 smpREmu;
extern "C" u32 outCur;
extern "C" u32 outLen;
extern "C" u32 clkTotal;
extern "C" u32 clkExec;
extern "C" u32 clkLeft;
extern "C" u32 t8kHz;
extern "C" u32 t64kHz;
extern "C" u32 dbgOpt;
extern "C" uptr pOutBuf;
extern "C" u32 outLeft;
extern "C" u32 outCnt;
extern "C" u32 outDec;
extern "C" u32 brrTab[1024];
extern "C" u8 dspMix;
extern "C" u8 dspChn;
extern "C" u8 dspSize;
extern "C" u32 dspOpts;
extern "C" uptr pInter;
extern "C" uptr pDecomp;
extern "C" u8 dspInter;
extern "C" u8 voiceMix;
extern "C" u8 dspMute;
extern "C" u8 disFlag;
extern "C" u8 dspPMod;
extern "C" u8 dspNoise;
extern "C" u8 dspNoiseF;
extern "C" u8 konRsv;
extern "C" u8 koffRsv;
extern "C" u8 konRun;
extern "C" char SPCFetch;
extern "C" char SPCTrace;
extern "C" uptr pOpFetch;
extern "C" uptr regPC;
extern "C" uptr regSP;
extern "C" uptr dpBase;
extern "C" u32 dbgFetchCount;
extern "C" u32 dbgTimerCount;
extern "C" u32 dbgFetchPC[8];
extern "C" u32 dbgFetchOpc[8];
extern "C" u32 dbgFetchClk[8];
extern "C" u32 dbgStartPC;
extern "C" u32 dbgFetchEntryCount;
extern "C" u32 dbgFetchEntryPC[8];
extern "C" u32 dbgFetchEntryClk[8];
extern "C" u32 dbgDecompCount;
extern "C" u32 dbgDecompHdr[8];
extern "C" u32 dbgDecompSP1[8];
extern "C" u32 dbgDecompSP2[8];
extern "C" u32 dbgDecompBuf0[8];
extern "C" u32 dbgDecompBuf1[8];
extern "C" u32 dbgDecompBuf2[8];
extern "C" u32 dbgDecompBuf3[8];
extern "C" u32 dbgUnpckHdr;
extern "C" u32 dbgUnpckByte0;
extern "C" u32 dbgUnpckByte1;
extern "C" u32 dbgUnpckIdx0;
extern "C" u32 dbgUnpckOut0;
extern "C" u32 dbgUnpckOut1;
extern "C" u32 dbgRKOnCount;
extern "C" u32 dbgRKOnBL;
extern "C" u32 dbgRKOnPreAL;
extern "C" u32 dbgRKOnPostAL;
extern "C" u32 dbgDSPInBKonCount;
extern "C" u32 dbgDSPInBKonBL;
extern "C" u32 dbgDSPInBKonAL;
extern "C" u32 dbgFunc2Count;
extern "C" u32 dbgFunc2Addr;
extern "C" u32 dbgFunc2KonCount;
extern "C" u32 dbgFunc3Count;
extern "C" u32 dbgFunc3Addr;
extern "C" u32 dbgFunc3Val;
extern "C" u32 dbgFunc3KonCount;
extern "C" u32 dbgFunc3KonVal;
extern "C" u32 dbgWrFuncCount;
extern "C" u32 dbgWrFuncAddr;
extern "C" u32 dbgWrFunc2Count;
extern "C" u32 dbgWrFunc3Count;
extern "C" u32 dbgMovXF4Count;
extern "C" u32 dbgMovXF4PC;
extern "C" u32 dbgMovXF4Val;
extern "C" u32 dbgCntReadCount;
extern "C" u32 dbgCntReadPC;
extern "C" u32 dbgCntReadAddr;
extern "C" u32 dbgCntReadVal;
extern "C" u32 dbgT0WriteCount;
extern "C" u32 dbgT0WriteSrc;
extern "C" u32 dbgT0WriteVal;
extern "C" u32 dbgT0PrevSrc;
extern "C" u32 dbgT0PrevVal;
extern "C" u8 inPortCp[4];
extern "C" u8 outPortCp[4];
extern "C" u8 flushPort[4];
extern "C" u8 portMod;
extern "C" u8 tControl;
extern "C" u8 t0Step;
extern "C" u8 t1Step;
extern "C" u8 t2Step;
extern "C" u32 scr700cmp[2];
extern "C" u32 scr700cnt;
extern "C" u32 scr700ptr;
extern "C" u8 scr700int[2];
extern "C" u8 scr700stf;
extern "C" u8 rawChn;
extern "C" u8 rawBits;
extern "C" u8 rawByte;
extern "C" u32 rawRate;
extern "C" u32 apuDbgStage;
extern "C" uptr apuDbgLastBuf;
extern "C" u32 apuDbgLastLen;
extern "C" u32 apuDbgLastType;
extern "C" uptr apuDbgSampleBuf;
extern "C" u32 apuDbgSampleLen;
extern "C" u32 apuCbMask;
extern "C" uintptr_t apuCbFunc;
extern "C" void trace_dsp_write_impl(volatile u8 *, volatile u8) {}
#elif defined(_WIN32)
#pragma comment(linker, "/alternatename:_dspInter=dspInter")
#pragma comment(linker, "/alternatename:_voiceMix=voiceMix")
#pragma comment(linker, "/alternatename:_dspMute=dspMute")
#pragma comment(linker, "/alternatename:_disFlag=disFlag")
#pragma comment(linker, "/alternatename:_brrTab=brrTab")
#pragma comment(linker, "/alternatename:_dspPMod=dspPMod")
#pragma comment(linker, "/alternatename:_dspNoise=dspNoise")
#pragma comment(linker, "/alternatename:_dspNoiseF=dspNoiseF")
#pragma comment(linker, "/alternatename:_konRsv=konRsv")
#pragma comment(linker, "/alternatename:_koffRsv=koffRsv")
#pragma comment(linker, "/alternatename:_konRun=konRun")
#pragma comment(linker, "/alternatename:_dbgDecompCount=dbgDecompCount")
#pragma comment(linker, "/alternatename:_dbgUnpckHdr=dbgUnpckHdr")
#pragma comment(linker, "/alternatename:_dbgUnpckByte0=dbgUnpckByte0")
#pragma comment(linker, "/alternatename:_dbgUnpckByte1=dbgUnpckByte1")
#pragma comment(linker, "/alternatename:_dbgUnpckIdx0=dbgUnpckIdx0")
#pragma comment(linker, "/alternatename:_dbgUnpckOut0=dbgUnpckOut0")
#pragma comment(linker, "/alternatename:_dbgUnpckOut1=dbgUnpckOut1")
#pragma comment(linker, "/alternatename:_dbgRKOnCount=dbgRKOnCount")
#pragma comment(linker, "/alternatename:_dbgRKOnBL=dbgRKOnBL")
#pragma comment(linker, "/alternatename:_dbgRKOnPreAL=dbgRKOnPreAL")
#pragma comment(linker, "/alternatename:_dbgRKOnPostAL=dbgRKOnPostAL")
#pragma comment(linker, "/alternatename:_dbgDSPInBKonCount=dbgDSPInBKonCount")
#pragma comment(linker, "/alternatename:_dbgDSPInBKonBL=dbgDSPInBKonBL")
#pragma comment(linker, "/alternatename:_dbgDSPInBKonAL=dbgDSPInBKonAL")
#pragma comment(linker, "/alternatename:_dbgFunc2Count=dbgFunc2Count")
#pragma comment(linker, "/alternatename:_dbgFunc2Addr=dbgFunc2Addr")
#pragma comment(linker, "/alternatename:_dbgFunc2KonCount=dbgFunc2KonCount")
#pragma comment(linker, "/alternatename:_dbgFunc3Count=dbgFunc3Count")
#pragma comment(linker, "/alternatename:_dbgFunc3Addr=dbgFunc3Addr")
#pragma comment(linker, "/alternatename:_dbgFunc3Val=dbgFunc3Val")
#pragma comment(linker, "/alternatename:_dbgFunc3KonCount=dbgFunc3KonCount")
#pragma comment(linker, "/alternatename:_dbgFunc3KonVal=dbgFunc3KonVal")
#pragma comment(linker, "/alternatename:_dbgWrFuncCount=dbgWrFuncCount")
#pragma comment(linker, "/alternatename:_dbgWrFuncAddr=dbgWrFuncAddr")
#pragma comment(linker, "/alternatename:_dbgWrFunc2Count=dbgWrFunc2Count")
#pragma comment(linker, "/alternatename:_dbgWrFunc3Count=dbgWrFunc3Count")
#pragma comment(linker, "/alternatename:_dbgMovXF4Count=dbgMovXF4Count")
#pragma comment(linker, "/alternatename:_dbgMovXF4PC=dbgMovXF4PC")
#pragma comment(linker, "/alternatename:_dbgMovXF4Val=dbgMovXF4Val")
#pragma comment(linker, "/alternatename:_dbgCntReadCount=dbgCntReadCount")
#pragma comment(linker, "/alternatename:_dbgCntReadPC=dbgCntReadPC")
#pragma comment(linker, "/alternatename:_dbgCntReadAddr=dbgCntReadAddr")
#pragma comment(linker, "/alternatename:_dbgCntReadVal=dbgCntReadVal")
#pragma comment(linker, "/alternatename:_dbgT0WriteCount=dbgT0WriteCount")
#pragma comment(linker, "/alternatename:_dbgT0WriteSrc=dbgT0WriteSrc")
#pragma comment(linker, "/alternatename:_dbgT0WriteVal=dbgT0WriteVal")
#pragma comment(linker, "/alternatename:_dbgT0PrevSrc=dbgT0PrevSrc")
#pragma comment(linker, "/alternatename:_dbgT0PrevVal=dbgT0PrevVal")
#pragma comment(linker, "/alternatename:_inPortCp=inPortCp")
#pragma comment(linker, "/alternatename:_outPortCp=outPortCp")
#pragma comment(linker, "/alternatename:_flushPort=flushPort")
#pragma comment(linker, "/alternatename:_portMod=portMod")
#pragma comment(linker, "/alternatename:_tControl=tControl")
#pragma comment(linker, "/alternatename:_t0Step=t0Step")
#pragma comment(linker, "/alternatename:_t1Step=t1Step")
#pragma comment(linker, "/alternatename:_t2Step=t2Step")
#pragma comment(linker, "/alternatename:_scr700cmp=scr700cmp")
#pragma comment(linker, "/alternatename:_scr700cnt=scr700cnt")
#pragma comment(linker, "/alternatename:_scr700ptr=scr700ptr")
#pragma comment(linker, "/alternatename:_scr700int=scr700int")
#pragma comment(linker, "/alternatename:_scr700stf=scr700stf")
extern "C" u32 call_InitAPU(u32 reason);
extern "C" void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts);
extern "C" void call_SetAPUSmpClk(u32 speed);
extern "C" void call_SetDSPPitch(u32 pitch);
extern "C" void call_SetDSPStereo(u32 separation);
extern "C" void call_SetDSPEFBCT(s32 leak);
extern "C" void call_SetDSPAmp(u32 amp);
extern "C" void call_LoadSPCFile(void *spc);
extern "C" void *call_EmuAPU(void *buffer, u32 length, u8 type);
extern "C" void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp);
extern "C" u32 brrTab[1024];
extern "C" u8 dspInter;
extern "C" u8 voiceMix;
extern "C" u8 dspMute;
extern "C" u8 disFlag;
extern "C" u8 dspPMod;
extern "C" u8 dspNoise;
extern "C" u8 dspNoiseF;
extern "C" u8 konRsv;
extern "C" u8 koffRsv;
extern "C" u8 konRun;
extern "C" u32 dbgDecompCount;
extern "C" u32 dbgUnpckHdr;
extern "C" u32 dbgUnpckByte0;
extern "C" u32 dbgUnpckByte1;
extern "C" u32 dbgUnpckIdx0;
extern "C" u32 dbgUnpckOut0;
extern "C" u32 dbgUnpckOut1;
extern "C" u32 dbgRKOnCount;
extern "C" u32 dbgRKOnBL;
extern "C" u32 dbgRKOnPreAL;
extern "C" u32 dbgRKOnPostAL;
extern "C" u32 dbgDSPInBKonCount;
extern "C" u32 dbgDSPInBKonBL;
extern "C" u32 dbgDSPInBKonAL;
extern "C" u32 dbgFunc2Count;
extern "C" u32 dbgFunc2Addr;
extern "C" u32 dbgFunc2KonCount;
extern "C" u32 dbgFunc3Count;
extern "C" u32 dbgFunc3Addr;
extern "C" u32 dbgFunc3Val;
extern "C" u32 dbgFunc3KonCount;
extern "C" u32 dbgFunc3KonVal;
extern "C" u32 dbgWrFuncCount;
extern "C" u32 dbgWrFuncAddr;
extern "C" u32 dbgWrFunc2Count;
extern "C" u32 dbgWrFunc3Count;
extern "C" u32 dbgMovXF4Count;
extern "C" u32 dbgMovXF4PC;
extern "C" u32 dbgMovXF4Val;
extern "C" u32 dbgCntReadCount;
extern "C" u32 dbgCntReadPC;
extern "C" u32 dbgCntReadAddr;
extern "C" u32 dbgCntReadVal;
extern "C" u32 dbgT0WriteCount;
extern "C" u32 dbgT0WriteSrc;
extern "C" u32 dbgT0WriteVal;
extern "C" u32 dbgT0PrevSrc;
extern "C" u32 dbgT0PrevVal;
extern "C" u8 inPortCp[4];
extern "C" u8 outPortCp[4];
extern "C" u8 flushPort[4];
extern "C" u8 portMod;
extern "C" u8 tControl;
extern "C" u8 t0Step;
extern "C" u8 t1Step;
extern "C" u8 t2Step;
extern "C" u32 scr700cmp[2];
extern "C" u32 scr700cnt;
extern "C" u32 scr700ptr;
extern "C" u8 scr700int[2];
extern "C" u8 scr700stf;
#elif defined(__x86_64__)
u32 call_InitAPU(u32 reason) {
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

void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
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

void call_SetAPUSmpClk(u32 speed) {
    const u64 arg0 = speed;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetAPUSmpClk\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void call_SetDSPPitch(u32 pitch) {
    const u64 arg0 = pitch;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPPitch\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void call_SetDSPStereo(u32 separation) {
    const u64 arg0 = separation;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPStereo\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void call_SetDSPEFBCT(s32 leak) {
    const s64 arg0 = leak;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPEFBCT\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void call_SetDSPAmp(u32 amp) {
    const u64 arg0 = amp;
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetDSPAmp\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void call_LoadSPCFile(void *spc) {
    const u64 arg0 = reinterpret_cast<u64>(spc);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _LoadSPCFile\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void *call_EmuAPU(void *buffer, u32 length, u8 type) {
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

void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp) {
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
#else
u32 call_InitAPU(u32 reason) {
    return InitAPU(reason);
}

void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
    SetAPUOpt(mix_type, num_channels, bits, rate, inter, opts);
}

void call_SetAPUSmpClk(u32 speed) {
    SetAPUSmpClk(speed);
}

void call_SetDSPPitch(u32 pitch) {
    SetDSPPitch(pitch);
}

void call_SetDSPStereo(u32 separation) {
    SetDSPStereo(separation);
}

void call_SetDSPEFBCT(s32 leak) {
    SetDSPEFBCT(leak);
}

void call_SetDSPAmp(u32 amp) {
    SetDSPAmp(amp);
}

void call_LoadSPCFile(void *spc) {
    LoadSPCFile(spc);
}

void *call_EmuAPU(void *buffer, u32 length, u8 type) {
    return EmuAPU(buffer, length, type);
}

void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp) {
    GetSPCRegs(pc, a, y, x, psw, sp);
}
#endif

#if !defined(_WIN32) && defined(__x86_64__)
extern "C" u32 dspRate asm("dspRate");
extern "C" u32 firCur asm("firCur");
extern "C" u32 firRate asm("firRate");
extern "C" float firTaps[8] asm("firTaps");
extern "C" u32 echoLenD asm("echoLenD");
extern "C" u32 echoMaxD asm("echoMaxD");
extern "C" u32 echoCurD asm("echoCurD");
extern "C" u32 echoLenM asm("echoLenM");
extern "C" u32 echoMaxM asm("echoMaxM");
extern "C" u32 echoCurM asm("echoCurM");
extern "C" u32 echoDecM asm("echoDecM");
extern "C" float echoFB asm("echoFB");
extern "C" float echoFBCT asm("echoFBCT");
extern "C" float nowMainL asm("nowMainL");
extern "C" float nowMainR asm("nowMainR");
extern "C" float nowEchoL asm("nowEchoL");
extern "C" float nowEchoR asm("nowEchoR");
extern "C" float echoBuf[] asm("echoBuf");
extern "C" float firBuf[] asm("firBuf");
#elif !defined(_WIN32)
extern "C" u32 SNESAPUArm64DebugEcho(u32 *meta, float *echo, u32 echo_pairs, float *fir, u32 fir_pairs);
extern "C" u32 SNESAPUArm64DebugVolumes(float *values, u32 count);
#endif

bool parse_u32(const char *text, u32 &value) {
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(text, &end, 10);
    if (!text[0] || !end || *end != '\0') {
        return false;
    }
    value = static_cast<u32>(parsed);
    return true;
}

bool env_flag_enabled(const char *name) {
    const char *value = std::getenv(name);
    return value && value[0] && value[0] != '0';
}

u32 env_u32_or_default(const char *name, u32 fallback) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return fallback;
    }

    u32 parsed = 0;
    return parse_u32(value, parsed) ? parsed : fallback;
}

void print_float_pairs(const char *label, const std::vector<float> &pairs) {
    std::cout << label << "=";
    for (size_t i = 0; i + 1 < pairs.size(); i += 2) {
        if (i) {
            std::cout << ",";
        }
        std::cout << pairs[i] << ":" << pairs[i + 1];
    }
    std::cout << "\n";
}

void print_indexed_float_pairs(const char *label, const float *pairs, u32 first, u32 count) {
    std::cout << label << " first=" << first << " data=";
    for (u32 i = 0; i < count; ++i) {
        if (i) {
            std::cout << ",";
        }
        const u32 pair = first + i;
        std::cout << pair << ":" << pairs[pair * 2] << ":" << pairs[pair * 2 + 1];
    }
    std::cout << "\n";
}

void print_echo_debug_if_enabled() {
    if (!env_flag_enabled("SNESAPU_DUMP_ECHO")) {
        return;
    }

    const u32 pair_count = std::min<u32>(env_u32_or_default("SNESAPU_DUMP_ECHO_PAIRS", 12), 64);
#if !defined(_WIN32) && defined(__x86_64__)
    std::vector<float> echo(static_cast<size_t>(pair_count) * 2u);
    std::vector<float> fir(static_cast<size_t>(pair_count) * 2u);
    const u32 echo_len = echoLenD == 0 ? 8u : echoLenD;
    const u32 echo_offset = (echoMaxD - echoCurD) % echo_len;
    const u32 echo_back_pairs = env_u32_or_default("SNESAPU_DUMP_ECHO_BACK_PAIRS", 0);
    const u32 echo_start =
        (echo_offset + echo_len - ((echo_back_pairs * 8u) % echo_len)) % echo_len;
    const auto *echo_bytes = reinterpret_cast<const u8 *>(echoBuf);
    for (u32 i = 0; i < pair_count; ++i) {
        const u32 byte_offset = (echo_start + i * 8u) % echo_len;
        const auto *sample = reinterpret_cast<const float *>(echo_bytes + byte_offset);
        echo[i * 2] = sample[0];
        echo[i * 2 + 1] = sample[1];
    }
    const auto *fir_bytes = reinterpret_cast<const u8 *>(firBuf);
    const u32 fir_offset = (firCur & 0xffu) * 2u;
    for (u32 i = 0; i < pair_count; ++i) {
        const auto *sample = reinterpret_cast<const float *>(fir_bytes + fir_offset + i * 8u);
        fir[i * 2] = sample[0];
        fir[i * 2 + 1] = sample[1];
    }
    std::cout << "echoDebug"
              << " dspRate=" << dspRate
              << " echoLenD=" << echoLenD
              << " echoMaxD=" << echoMaxD
              << " echoCurD=" << echoCurD
              << " echoOffset=" << echo_start
              << " echoLenM=" << echoLenM
              << " echoMaxM=" << echoMaxM
              << " echoCurM=" << echoCurM
              << " echoDecM=" << echoDecM
              << " echoFB=" << echoFB
              << " echoFBCT=" << echoFBCT
              << " firCur=" << firCur
              << " firRate=" << firRate
              << "\n";
    print_float_pairs("echoPairs", echo);
    print_float_pairs("firPairs", fir);
    if (env_flag_enabled("SNESAPU_DUMP_FIR_COPY")) {
        const u32 first = env_u32_or_default("SNESAPU_DUMP_FIR_FIRST", 48);
        const u32 count = std::min<u32>(env_u32_or_default("SNESAPU_DUMP_FIR_COUNT", 16), 64);
        print_indexed_float_pairs("firBase", firBuf, first, count);
        print_indexed_float_pairs("firCopy1", firBuf, 64 + first, count);
        print_indexed_float_pairs("firCopy2", firBuf, 128 + first, count);
    }
    std::cout << "firTaps=";
    for (size_t i = 0; i < 8; ++i) {
        if (i) {
            std::cout << ",";
        }
        std::cout << firTaps[i];
    }
    std::cout << "\n";
    std::cout << "volumes"
              << " mainL=" << nowMainL
              << " mainR=" << nowMainR
              << " echoL=" << nowEchoL
              << " echoR=" << nowEchoR
              << "\n";
#elif !defined(_WIN32)
    u32 meta[8] {};
    std::vector<float> echo(static_cast<size_t>(pair_count) * 2u);
    std::vector<float> fir(static_cast<size_t>(pair_count) * 2u);
    if (SNESAPUArm64DebugEcho(meta, echo.data(), pair_count, fir.data(), pair_count)) {
        std::cout << "echoDebug"
                  << " echoLenD=" << meta[0]
                  << " echoPendingD=" << meta[1]
                  << " echoCurD=" << meta[2]
                  << " echoOffset=" << meta[3]
                  << " firPos=" << meta[4]
                  << " echoLenM=" << meta[5]
                  << " echoCurM=" << meta[6]
                  << " echoDecM=" << meta[7]
                  << "\n";
        print_float_pairs("echoPairs", echo);
        print_float_pairs("firPairs", fir);
    }
    float volumes[8] {};
    if (SNESAPUArm64DebugVolumes(volumes, 8)) {
        std::cout << "volumes"
                  << " mainL=" << volumes[0]
                  << " mainR=" << volumes[1]
                  << " echoL=" << volumes[2]
                  << " echoR=" << volumes[3]
                  << " targetMainL=" << volumes[4]
                  << " targetMainR=" << volumes[5]
                  << " targetEchoL=" << volumes[6]
                  << " targetEchoR=" << volumes[7]
                  << "\n";
    }
#endif
}

bool read_file(const std::string &path, std::vector<u8> &data) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return false;
    }
    input.seekg(0, std::ios::end);
    const std::streamsize size = input.tellg();
    input.seekg(0, std::ios::beg);
    if (size < 0) {
        return false;
    }
    data.resize(static_cast<size_t>(size));
    return static_cast<bool>(input.read(reinterpret_cast<char *>(data.data()), size));
}

void apply_engine_options() {
    const u32 inter = env_u32_or_default("SNESAPU_INTERPOLATION", INT_GAUSS);
    const u32 opts = env_u32_or_default("SNESAPU_DSP_OPTIONS", kDefaultDSPOpts) | DSP_FLOAT;
    call_SetAPUOpt(MIX_INT, 2, 16, kDefaultRate, inter, opts);
    call_SetAPUSmpClk(kDefaultSpeed);
    call_SetDSPPitch(kDefaultPitch);
    call_SetDSPStereo(kDefaultStereo);
    call_SetDSPEFBCT(kDefaultEfbct);
    call_SetDSPAmp(kAmp100);
}

void apply_voice_mute_mask_from_env() {
    const char *value = std::getenv("SNESAPU_MUTE_MASK");
    if (!value || !value[0]) {
        return;
    }

    char *end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 0);
    if (!end || *end != '\0') {
        std::cerr << "invalid SNESAPU_MUTE_MASK: " << value << "\n";
        std::exit(1);
    }

    const u32 mute_mask = static_cast<u32>(parsed);
    for (int i = 0; i < 8; ++i) {
        if ((mute_mask & (1u << i)) != 0) {
            mix[i].mFlg |= MFLG_MUTE;
        }
    }
}

void print_hex_byte(const char *label, u8 value) {
    std::cout << label << "=0x"
              << std::hex << std::setw(2) << std::setfill('0') << static_cast<unsigned>(value)
              << std::dec;
}

void print_layout_if_enabled() {
    if (std::getenv("SNESAPU_PRINT_LAYOUT") == nullptr) {
        return;
    }

    std::cout << "layout"
              << " ptr_size=" << sizeof(void *)
              << " sizeof_DSPVoice=" << sizeof(DSPVoice)
              << " sizeof_DSPReg=" << sizeof(DSPReg)
              << " sizeof_Voice=" << sizeof(Voice)
              << "\n";
    std::cout << "layout Voice"
              << " vAdsr=" << offsetof(Voice, vAdsr)
              << " vGain=" << offsetof(Voice, vGain)
              << " vRsv=" << offsetof(Voice, vRsv)
              << " sIdx=" << offsetof(Voice, sIdx)
              << " bCur=" << offsetof(Voice, bCur)
              << " bHdr=" << offsetof(Voice, bHdr)
              << " mFlg=" << offsetof(Voice, mFlg)
              << " eMode=" << offsetof(Voice, eMode)
              << " eRIdx=" << offsetof(Voice, eRIdx)
              << " eRate=" << offsetof(Voice, eRate)
              << " eCnt=" << offsetof(Voice, eCnt)
              << " eVal=" << offsetof(Voice, eVal)
              << " eAdj=" << offsetof(Voice, eAdj)
              << " eDest=" << offsetof(Voice, eDest)
              << " vMaxL=" << offsetof(Voice, vMaxL)
              << " vMaxR=" << offsetof(Voice, vMaxR)
              << " sP1=" << offsetof(Voice, sP1)
              << " sP2=" << offsetof(Voice, sP2)
              << " sBufP=" << offsetof(Voice, sBufP)
              << " sBuf=" << offsetof(Voice, sBuf)
              << " mTgtL=" << offsetof(Voice, mTgtL)
              << " mTgtR=" << offsetof(Voice, mTgtR)
              << " mChnL=" << offsetof(Voice, mChnL)
              << " mChnR=" << offsetof(Voice, mChnR)
              << " mRate=" << offsetof(Voice, mRate)
              << " mDec=" << offsetof(Voice, mDec)
              << " mSrc=" << offsetof(Voice, mSrc)
              << " mKOn=" << offsetof(Voice, mKOn)
              << " mOrgP=" << offsetof(Voice, mOrgP)
              << " mOut=" << offsetof(Voice, mOut)
              << "\n";
    std::cout << "layout DSPVoice"
              << " volL=" << offsetof(DSPVoice, volL)
              << " volR=" << offsetof(DSPVoice, volR)
              << " pitch=" << offsetof(DSPVoice, pitch)
              << " srcn=" << offsetof(DSPVoice, srcn)
              << " adsr=" << offsetof(DSPVoice, adsr)
              << " gain=" << offsetof(DSPVoice, gain)
              << " envx=" << offsetof(DSPVoice, envx)
              << " outx=" << offsetof(DSPVoice, outx)
              << "\n";
    std::cout << "layout DSPReg"
              << " voice0=" << offsetof(DSPReg, voice)
              << " voice1=" << offsetof(DSPReg, voice[1])
              << " mvolL=" << offsetof(DSPReg, mvolL)
              << " mvolR=" << offsetof(DSPReg, mvolR)
              << " evolL=" << offsetof(DSPReg, evolL)
              << " evolR=" << offsetof(DSPReg, evolR)
              << " kon=" << offsetof(DSPReg, kon)
              << " kof=" << offsetof(DSPReg, kof)
              << " endx=" << offsetof(DSPReg, endx)
              << " fir0=" << offsetof(DSPReg, fir[0])
              << " fir7=" << offsetof(DSPReg, fir[7])
              << "\n";
}

#if defined(_WIN32) && defined(_M_X64)
u32 current_apu_dbg_stage() {
    return apuDbgStage;
}

uintptr_t apu_offset_or_zero(uptr ptr_value) {
    const uintptr_t base = static_cast<uintptr_t>(pAPURAM);
    const uintptr_t value = static_cast<uintptr_t>(ptr_value);
    if (value < base || value >= base + kApuRamSize) {
        return 0;
    }
    return value - base;
}

void print_internal_state_if_enabled() {
    if (std::getenv("SNESAPU_PRINT_INTERNALS") == nullptr) {
        return;
    }

    std::cout << "internal cycLeft=" << cycLeft
              << " smpDec=" << smpDec
              << " smpRate=" << smpRate
              << " smpRAdj=" << smpRAdj
              << " smpREmu=" << smpREmu
              << " outCur=" << outCur
              << " outLen=" << outLen
              << "\n";
    std::cout << "internal rawChn=" << static_cast<unsigned>(rawChn)
              << " rawBits=" << static_cast<int>(static_cast<int8_t>(rawBits))
              << " rawByte=" << static_cast<unsigned>(rawByte)
              << " rawRate=" << rawRate
              << "\n";
    std::cout << "internal clkTotal=" << clkTotal
              << " clkExec=" << clkExec
              << " clkLeft=" << clkLeft
              << " t8kHz=" << t8kHz
              << " t64kHz=" << t64kHz
              << " dbgOpt=0x" << std::hex << dbgOpt << std::dec
              << "\n";
    std::cout << "internal timer"
              << " control=0x" << std::hex << static_cast<unsigned>(tControl)
              << " t0Step=0x" << static_cast<unsigned>(t0Step)
              << " t1Step=0x" << static_cast<unsigned>(t1Step)
              << " t2Step=0x" << static_cast<unsigned>(t2Step)
              << std::dec
              << " t64Cnt=" << t64Cnt
              << "\n";
    std::cout << "internal pOutBuf=0x" << static_cast<uintptr_t>(pOutBuf)
              << " pInter=0x" << static_cast<uintptr_t>(pInter)
              << " pDecomp=0x" << static_cast<uintptr_t>(pDecomp)
              << " brrTab=0x" << reinterpret_cast<uintptr_t>(&brrTab[0])
              << std::dec << "\n";
    std::cout << "internal brrTab[0..7]=";
    for (int i = 0; i < 8; ++i) {
        if (i) {
            std::cout << ",";
        }
        std::cout << static_cast<std::int32_t>(brrTab[i]);
    }
    std::cout << " brrTab[32..39]=";
    for (int i = 32; i < 40; ++i) {
        if (i != 32) {
            std::cout << ",";
        }
        std::cout << static_cast<std::int32_t>(brrTab[i]);
    }
    std::cout << " brrTab[512..519]=";
    for (int i = 512; i < 520; ++i) {
        if (i != 512) {
            std::cout << ",";
        }
        std::cout << static_cast<std::int32_t>(brrTab[i]);
    }
    std::cout << "\n";
    std::cout << "internal outLeft=" << outLeft
              << " outCnt=" << outCnt
              << " outDec=" << outDec
              << " dspMix=" << static_cast<unsigned>(dspMix)
              << " dspChn=" << static_cast<unsigned>(dspChn)
              << " dspSize=" << static_cast<unsigned>(dspSize)
              << " dspOpts=0x" << std::hex << dspOpts
              << std::dec << "\n";
    std::cout << "internal apuCbMask=0x" << std::hex << apuCbMask
              << " apuCbFunc=0x" << static_cast<uintptr_t>(apuCbFunc)
              << " apuDbgStage=0x" << apuDbgStage
              << " apuDbgLastBuf=0x" << static_cast<uintptr_t>(apuDbgLastBuf)
              << " apuDbgLastLen=0x" << apuDbgLastLen
              << " apuDbgLastType=0x" << apuDbgLastType
              << " apuDbgSampleBuf=0x" << static_cast<uintptr_t>(apuDbgSampleBuf)
              << " apuDbgSampleLen=0x" << apuDbgSampleLen
              << std::dec << "\n";
    std::cout << "internal dspInter=" << static_cast<unsigned>(dspInter)
              << " voiceMix=0x" << std::hex << static_cast<unsigned>(voiceMix)
              << " dspMute=0x" << static_cast<unsigned>(dspMute)
              << " disFlag=0x" << static_cast<unsigned>(disFlag)
              << " dspPMod=0x" << static_cast<unsigned>(dspPMod)
              << " dspNoise=0x" << static_cast<unsigned>(dspNoise)
              << " dspNoiseF=0x" << static_cast<unsigned>(dspNoiseF)
              << " konRsv=0x" << static_cast<unsigned>(konRsv)
              << " koffRsv=0x" << static_cast<unsigned>(koffRsv)
              << " konRun=0x" << static_cast<unsigned>(konRun)
              << std::dec << "\n";
    std::cout << "internal regPC=apu+0x" << std::hex << apu_offset_or_zero(regPC)
              << " regSP=apu+0x" << apu_offset_or_zero(regSP)
              << " dpBase=apu+0x" << apu_offset_or_zero(dpBase)
              << " pOpFetch=0x" << static_cast<uintptr_t>(pOpFetch)
              << " SPCFetch=0x" << reinterpret_cast<uintptr_t>(&SPCFetch)
              << " SPCTrace=0x" << reinterpret_cast<uintptr_t>(&SPCTrace)
              << std::dec << "\n";
    std::cout << "internal dbgFetchCount=" << dbgFetchCount
              << " dbgTimerCount=" << dbgTimerCount
              << " dbgStartPC=" << dbgStartPC
              << " dbgFetchEntryCount=" << dbgFetchEntryCount
              << "\n";
    const u32 entry_dump_count = dbgFetchEntryCount < 8 ? dbgFetchEntryCount : 8;
    for (u32 i = 0; i < entry_dump_count; ++i) {
        std::cout << "internal fetch_entry[" << i << "]"
                  << " pc=" << dbgFetchEntryPC[i]
                  << " clkLeft=" << static_cast<std::int32_t>(dbgFetchEntryClk[i])
                  << "\n";
    }
    const u32 fetch_dump_count = dbgFetchCount < 8 ? dbgFetchCount : 8;
    for (u32 i = 0; i < fetch_dump_count; ++i) {
        std::cout << "internal fetch[" << i << "]"
                  << " pc=" << dbgFetchPC[i]
                  << " opc=0x" << std::hex << std::setw(2) << std::setfill('0') << dbgFetchOpc[i]
                  << std::dec << std::setfill(' ')
                  << " clkLeft=" << static_cast<std::int32_t>(dbgFetchClk[i])
                  << "\n";
    }
    std::cout << "internal dbgDecompCount=" << dbgDecompCount << "\n";
    std::cout << "internal dbgUnpck"
              << " hdr=0x" << std::hex << std::setw(2) << std::setfill('0') << dbgUnpckHdr
              << " byte0=0x" << std::setw(2) << dbgUnpckByte0
              << " byte1=0x" << std::setw(2) << dbgUnpckByte1
              << " idx0=0x" << std::setw(8) << dbgUnpckIdx0
              << std::dec << std::setfill(' ')
              << " out0=" << static_cast<std::int32_t>(dbgUnpckOut0)
              << " out1=" << static_cast<std::int32_t>(dbgUnpckOut1)
              << "\n";
    std::cout << "internal dbgRKOn"
              << " count=" << dbgRKOnCount
              << " reg=0x" << std::hex << dbgRKOnBL
              << " preAL=0x" << dbgRKOnPreAL
              << " postAL=0x" << dbgRKOnPostAL
              << " dbgDSPInBKon"
              << " count=" << std::dec << dbgDSPInBKonCount
              << " reg=0x" << std::hex << dbgDSPInBKonBL
              << " al=0x" << dbgDSPInBKonAL
              << std::dec << "\n";
    std::cout << "internal dbgFunc23"
              << " f2count=" << dbgFunc2Count
              << " f2addr=0x" << std::hex << dbgFunc2Addr
              << " f2kon=" << std::dec << dbgFunc2KonCount
              << " f3count=" << dbgFunc3Count
              << " f3addr=0x" << std::hex << dbgFunc3Addr
              << " f3val=0x" << dbgFunc3Val
              << " f3kon=" << std::dec << dbgFunc3KonCount
              << " f3konVal=0x" << std::hex << dbgFunc3KonVal
              << std::dec << "\n";
    std::cout << "internal dbgWrFunc"
              << " count=" << dbgWrFuncCount
              << " addr=0x" << std::hex << dbgWrFuncAddr
              << " f2=" << std::dec << dbgWrFunc2Count
              << " f3=" << dbgWrFunc3Count
              << std::dec << "\n";
    std::cout << "internal dbgMovXF4"
              << " count=" << dbgMovXF4Count
              << " pc=0x" << std::hex << dbgMovXF4PC
              << " val=0x" << dbgMovXF4Val
              << std::dec << "\n";
    std::cout << "internal dbgCntRead"
              << " count=" << dbgCntReadCount
              << " pc=0x" << std::hex << dbgCntReadPC
              << " addr=0x" << dbgCntReadAddr
              << " val=0x" << dbgCntReadVal
              << std::dec << "\n";
    std::cout << "internal dbgT0Write"
              << " count=" << dbgT0WriteCount
              << " src=" << dbgT0WriteSrc
              << " val=0x" << std::hex << dbgT0WriteVal
              << " prevSrc=" << std::dec << dbgT0PrevSrc
              << " prevVal=0x" << std::hex << dbgT0PrevVal
              << std::dec << "\n";
    std::cout << "internal ports"
              << " in=" << static_cast<unsigned>(inPortCp[0])
              << "," << static_cast<unsigned>(inPortCp[1])
              << "," << static_cast<unsigned>(inPortCp[2])
              << "," << static_cast<unsigned>(inPortCp[3])
              << " outcp=" << static_cast<unsigned>(outPortCp[0])
              << "," << static_cast<unsigned>(outPortCp[1])
              << "," << static_cast<unsigned>(outPortCp[2])
              << "," << static_cast<unsigned>(outPortCp[3])
              << " flush=" << static_cast<unsigned>(flushPort[0])
              << "," << static_cast<unsigned>(flushPort[1])
              << "," << static_cast<unsigned>(flushPort[2])
              << "," << static_cast<unsigned>(flushPort[3])
              << " portMod=0x" << std::hex << static_cast<unsigned>(portMod)
              << std::dec << "\n";
    std::cout << "internal scr700"
              << " stf=0x" << std::hex << static_cast<unsigned>(scr700stf)
              << " int=" << static_cast<unsigned>(scr700int[0])
              << "," << static_cast<unsigned>(scr700int[1])
              << " ptr=0x" << scr700ptr
              << std::dec
              << " cnt=" << static_cast<std::int32_t>(scr700cnt)
              << " cmp=" << static_cast<std::int32_t>(scr700cmp[0])
              << "," << static_cast<std::int32_t>(scr700cmp[1])
              << "\n";
    const u32 decomp_dump_count = dbgDecompCount < 8 ? dbgDecompCount : 8;
    for (u32 i = 0; i < decomp_dump_count; ++i) {
        std::cout << "internal decomp[" << i << "]"
                  << " hdr=0x" << std::hex << std::setw(2) << std::setfill('0') << dbgDecompHdr[i]
                  << std::dec << std::setfill(' ')
                  << " sp1=" << static_cast<std::int32_t>(dbgDecompSP1[i])
                  << " sp2=" << static_cast<std::int32_t>(dbgDecompSP2[i])
                  << " buf=" << static_cast<std::int32_t>(dbgDecompBuf0[i])
                  << "," << static_cast<std::int32_t>(dbgDecompBuf1[i])
                  << "," << static_cast<std::int32_t>(dbgDecompBuf2[i])
                  << "," << static_cast<std::int32_t>(dbgDecompBuf3[i])
                  << "\n";
    }
}

#elif defined(_WIN32)
u32 current_apu_dbg_stage() {
    return 0;
}

void print_internal_state_if_enabled() {
    if (std::getenv("SNESAPU_PRINT_INTERNALS") == nullptr) {
        return;
    }

    std::cout << "internal timer"
              << " control=0x" << std::hex << static_cast<unsigned>(tControl)
              << " t0Step=0x" << static_cast<unsigned>(t0Step)
              << " t1Step=0x" << static_cast<unsigned>(t1Step)
              << " t2Step=0x" << static_cast<unsigned>(t2Step)
              << std::dec
              << " t64Cnt=" << t64Cnt
              << "\n";
    std::cout << "internal dspInter=" << static_cast<unsigned>(dspInter)
              << " voiceMix=0x" << std::hex << static_cast<unsigned>(voiceMix)
              << " dspMute=0x" << static_cast<unsigned>(dspMute)
              << " disFlag=0x" << static_cast<unsigned>(disFlag)
              << " dspPMod=0x" << static_cast<unsigned>(dspPMod)
              << " dspNoise=0x" << static_cast<unsigned>(dspNoise)
              << " dspNoiseF=0x" << static_cast<unsigned>(dspNoiseF)
              << " konRsv=0x" << static_cast<unsigned>(konRsv)
              << " koffRsv=0x" << static_cast<unsigned>(koffRsv)
              << " konRun=0x" << static_cast<unsigned>(konRun)
              << std::dec << "\n";
    std::cout << "internal brrTab=0x" << std::hex << reinterpret_cast<uintptr_t>(&brrTab[0])
              << std::dec << "\n";
    std::cout << "internal dbgDecompCount=" << dbgDecompCount << "\n";
    std::cout << "internal dbgUnpck"
              << " hdr=0x" << std::hex << std::setw(2) << std::setfill('0') << dbgUnpckHdr
              << " byte0=0x" << std::setw(2) << dbgUnpckByte0
              << " byte1=0x" << std::setw(2) << dbgUnpckByte1
              << " idx0=0x" << std::setw(8) << dbgUnpckIdx0
              << std::dec << std::setfill(' ')
              << " out0=" << static_cast<std::int32_t>(dbgUnpckOut0)
              << " out1=" << static_cast<std::int32_t>(dbgUnpckOut1)
              << "\n";
    std::cout << "internal dbgRKOn"
              << " count=" << dbgRKOnCount
              << " reg=0x" << std::hex << dbgRKOnBL
              << " preAL=0x" << dbgRKOnPreAL
              << " postAL=0x" << dbgRKOnPostAL
              << " dbgDSPInBKon"
              << " count=" << std::dec << dbgDSPInBKonCount
              << " reg=0x" << std::hex << dbgDSPInBKonBL
              << " al=0x" << dbgDSPInBKonAL
              << std::dec << "\n";
    std::cout << "internal dbgFunc23"
              << " f2count=" << dbgFunc2Count
              << " f2addr=0x" << std::hex << dbgFunc2Addr
              << " f2kon=" << std::dec << dbgFunc2KonCount
              << " f3count=" << dbgFunc3Count
              << " f3addr=0x" << std::hex << dbgFunc3Addr
              << " f3val=0x" << dbgFunc3Val
              << " f3kon=" << std::dec << dbgFunc3KonCount
              << " f3konVal=0x" << std::hex << dbgFunc3KonVal
              << std::dec << "\n";
    std::cout << "internal dbgWrFunc"
              << " count=" << dbgWrFuncCount
              << " addr=0x" << std::hex << dbgWrFuncAddr
              << " f2=" << std::dec << dbgWrFunc2Count
              << " f3=" << dbgWrFunc3Count
              << std::dec << "\n";
    std::cout << "internal dbgMovXF4"
              << " count=" << dbgMovXF4Count
              << " pc=0x" << std::hex << dbgMovXF4PC
              << " val=0x" << dbgMovXF4Val
              << std::dec << "\n";
    std::cout << "internal dbgCntRead"
              << " count=" << dbgCntReadCount
              << " pc=0x" << std::hex << dbgCntReadPC
              << " addr=0x" << dbgCntReadAddr
              << " val=0x" << dbgCntReadVal
              << std::dec << "\n";
    std::cout << "internal dbgT0Write"
              << " count=" << dbgT0WriteCount
              << " src=" << dbgT0WriteSrc
              << " val=0x" << std::hex << dbgT0WriteVal
              << " prevSrc=" << std::dec << dbgT0PrevSrc
              << " prevVal=0x" << std::hex << dbgT0PrevVal
              << std::dec << "\n";
    std::cout << "internal ports"
              << " in=" << static_cast<unsigned>(inPortCp[0])
              << "," << static_cast<unsigned>(inPortCp[1])
              << "," << static_cast<unsigned>(inPortCp[2])
              << "," << static_cast<unsigned>(inPortCp[3])
              << " outcp=" << static_cast<unsigned>(outPortCp[0])
              << "," << static_cast<unsigned>(outPortCp[1])
              << "," << static_cast<unsigned>(outPortCp[2])
              << "," << static_cast<unsigned>(outPortCp[3])
              << " flush=" << static_cast<unsigned>(flushPort[0])
              << "," << static_cast<unsigned>(flushPort[1])
              << "," << static_cast<unsigned>(flushPort[2])
              << "," << static_cast<unsigned>(flushPort[3])
              << " portMod=0x" << std::hex << static_cast<unsigned>(portMod)
              << std::dec << "\n";
    std::cout << "internal scr700"
              << " stf=0x" << std::hex << static_cast<unsigned>(scr700stf)
              << " int=" << static_cast<unsigned>(scr700int[0])
              << "," << static_cast<unsigned>(scr700int[1])
              << " ptr=0x" << scr700ptr
              << std::dec
              << " cnt=" << static_cast<std::int32_t>(scr700cnt)
              << " cmp=" << static_cast<std::int32_t>(scr700cmp[0])
              << "," << static_cast<std::int32_t>(scr700cmp[1])
              << "\n";
}

#else
u32 current_apu_dbg_stage() {
    return 0;
}

void print_internal_state_if_enabled() {}
#endif

uintptr_t voice_sidx_value(const Voice &voice) {
#if defined(_WIN64) || defined(__LP64__) || defined(__x86_64__) || defined(__aarch64__)
    return static_cast<uintptr_t>(voice.sIdx);
#else
    const uintptr_t base = reinterpret_cast<uintptr_t>(voice.sBuf);
    const uintptr_t current = reinterpret_cast<uintptr_t>(voice.sIdx);
    if (current >= base && current <= base + sizeof(voice.sBuf)) {
        return current - base;
    }
    return current;
#endif
}

uintptr_t voice_bcur_value(const Voice &voice, uintptr_t apu_base) {
#if defined(_WIN64) || defined(__LP64__) || defined(__x86_64__) || defined(__aarch64__)
    return static_cast<uintptr_t>(voice.bCur);
#else
    const uintptr_t current = reinterpret_cast<uintptr_t>(voice.bCur);
    if (current >= apu_base && current < apu_base + kApuRamSize) {
        return current - apu_base;
    }
    return current;
#endif
}

bool voice_bcur_in_apu(const Voice &voice, uintptr_t apu_base) {
#if defined(_WIN64) || defined(__LP64__) || defined(__x86_64__) || defined(__aarch64__)
    return static_cast<uintptr_t>(voice.bCur) < kApuRamSize;
#else
    const uintptr_t current = reinterpret_cast<uintptr_t>(voice.bCur);
    return current >= apu_base && current < apu_base + kApuRamSize;
#endif
}

#if defined(_WIN32)
void *call_emuapu_checked(void *buffer, u32 length, u8 type) {
    __try {
        return call_EmuAPU(buffer, length, type);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        std::cerr << "EmuAPU exception code=0x"
                  << std::hex << static_cast<unsigned long>(GetExceptionCode())
                  << " stage=0x" << current_apu_dbg_stage()
                  << std::dec << "\n";
        return nullptr;
    }
}
#else
void *call_emuapu_checked(void *buffer, u32 length, u8 type) {
    return call_EmuAPU(buffer, length, type);
}
#endif

}  // namespace

int __cdecl main(int argc, char **argv) {
    if (argc != 4) {
        std::cerr << "usage: spcstate <file.spc> <total_cycles> <chunk_cycles>\n"
                  << "       set SNESAPU_STATE_SAMPLES=1 to treat the numeric arguments as samples\n";
        return 1;
    }

    const std::string spc_path = argv[1];
    u32 total_cycles = 0;
    u32 chunk_cycles = 0;
    if (!parse_u32(argv[2], total_cycles) || !parse_u32(argv[3], chunk_cycles) ||
        !chunk_cycles) {
        std::cerr << "invalid numeric argument\n";
        return 1;
    }

    std::vector<u8> spc;
    if (!read_file(spc_path, spc)) {
        std::cerr << "failed to read SPC file: " << spc_path << "\n";
        return 1;
    }
    if (spc.size() < kSpcSize) {
        std::cerr << "SPC file is too small\n";
        return 1;
    }

    print_layout_if_enabled();

    call_InitAPU(1);
    call_LoadSPCFile(spc.data());
    apply_engine_options();
    apply_voice_mute_mask_from_env();

    const bool skip_reg_dump = env_flag_enabled("SNESAPU_SKIP_REG_DUMP");

    if (std::getenv("SNESAPU_PRINT_INTERNALS") && !skip_reg_dump) {
        u16 pre_pc = 0;
        u8 pre_a = 0;
        u8 pre_y = 0;
        u8 pre_x = 0;
        u8 pre_psw = 0;
        u8 pre_sp = 0;
        call_GetSPCRegs(&pre_pc, &pre_a, &pre_y, &pre_x, &pre_psw, &pre_sp);
        std::cout << "pre_regs pc=" << pre_pc
                  << " a=" << static_cast<unsigned>(pre_a)
                  << " y=" << static_cast<unsigned>(pre_y)
                  << " x=" << static_cast<unsigned>(pre_x)
                  << " psw=" << static_cast<unsigned>(pre_psw)
                  << " sp=" << static_cast<unsigned>(pre_sp)
                  << "\n";
    }

    const bool render_in_samples = std::getenv("SNESAPU_STATE_SAMPLES") != nullptr;
    const u64 min_sample_cap = render_in_samples
        ? static_cast<u64>(total_cycles)
        : (static_cast<u64>(total_cycles) + 255ULL) / 256ULL;
    const u64 sample_cap = std::max<u64>(min_sample_cap + 65536ULL, 65536ULL);
    std::vector<u8> scratch(static_cast<size_t>(sample_cap) * 4ULL);
    u8 *cursor = scratch.data();
    u32 remaining = total_cycles;
    while (remaining) {
        const u32 step = remaining < chunk_cycles ? remaining : chunk_cycles;
        void *end = call_emuapu_checked(cursor, step, render_in_samples ? 1 : 0);
        if (!end) {
            return 1;
        }
        cursor = static_cast<u8 *>(end);
        remaining -= step;
        if (cursor < scratch.data() || cursor > scratch.data() + scratch.size()) {
            std::cerr << "EmuAPU returned an invalid buffer pointer\n";
            return 1;
        }
    }

    std::cout << "cycles=" << total_cycles
              << " chunk=" << chunk_cycles
              << " pcm_bytes=" << static_cast<size_t>(cursor - scratch.data())
              << "\n";
    if (skip_reg_dump) {
        std::cout << "regs skipped\n";
    } else {
        u16 pc = 0;
        u8 a = 0;
        u8 y = 0;
        u8 x = 0;
        u8 psw = 0;
        u8 sp_reg = 0;
        call_GetSPCRegs(&pc, &a, &y, &x, &psw, &sp_reg);
        std::cout << "regs pc=" << pc
                  << " a=" << static_cast<unsigned>(a)
                  << " y=" << static_cast<unsigned>(y)
                  << " x=" << static_cast<unsigned>(x)
                  << " psw=" << static_cast<unsigned>(psw)
                  << " sp=" << static_cast<unsigned>(sp_reg)
                  << "\n";
    }

    u8 *apu_ram = reinterpret_cast<u8 *>(pAPURAM);
    if (!apu_ram) {
        std::cerr << "pAPURAM is null\n";
        return 1;
    }
    std::cout << "t64Cnt=" << t64Cnt << "\n";
    print_hex_byte("out0", outPort[0]);
    std::cout << " ";
    print_hex_byte("out1", outPort[1]);
    std::cout << " ";
    print_hex_byte("out2", outPort[2]);
    std::cout << " ";
    print_hex_byte("out3", outPort[3]);
    std::cout << "\n";
    std::cout << "ram"
              << " af=" << static_cast<unsigned>(apu_ram[0xAF])
              << " b0=" << static_cast<unsigned>(apu_ram[0xB0])
              << " b1=" << static_cast<unsigned>(apu_ram[0xB1])
              << " fa=" << static_cast<unsigned>(apu_ram[0xFA])
              << " fb=" << static_cast<unsigned>(apu_ram[0xFB])
              << " fc=" << static_cast<unsigned>(apu_ram[0xFC])
              << " fd=" << static_cast<unsigned>(apu_ram[0xFD])
              << " fe=" << static_cast<unsigned>(apu_ram[0xFE])
              << " ff=" << static_cast<unsigned>(apu_ram[0xFF])
              << " f2=" << static_cast<unsigned>(apu_ram[0xF2])
              << " f3=" << static_cast<unsigned>(apu_ram[0xF3])
              << " f4=" << static_cast<unsigned>(apu_ram[0xF4])
              << " f5=" << static_cast<unsigned>(apu_ram[0xF5])
              << " f6=" << static_cast<unsigned>(apu_ram[0xF6])
              << "\n";
    if (std::getenv("SNESAPU_DUMP_RAM_ADDR") != nullptr) {
        const u32 dump_addr = env_u32_or_default("SNESAPU_DUMP_RAM_ADDR", 0) & 0xffffu;
        const u32 dump_len = std::min<u32>(env_u32_or_default("SNESAPU_DUMP_RAM_LEN", 64), 1024);
        std::cout << "ramdump addr=0x" << std::hex << dump_addr << std::dec
                  << " len=" << dump_len << " data=";
        for (u32 i = 0; i < dump_len; ++i) {
            if (i) {
                std::cout << ",";
            }
            std::cout << std::hex << std::setw(2) << std::setfill('0')
                      << static_cast<unsigned>(apu_ram[(dump_addr + i) & 0xffffu]);
        }
        std::cout << std::dec << std::setfill(' ') << "\n";
    }
    std::cout << "vmMaxL=" << vMMaxL
              << " vmMaxR=" << vMMaxR
              << "\n";
    std::cout << "dsp"
              << " mvolL=" << static_cast<int>(dsp.mvolL)
              << " mvolR=" << static_cast<int>(dsp.mvolR)
              << " evolL=" << static_cast<int>(dsp.evolL)
              << " evolR=" << static_cast<int>(dsp.evolR)
              << " efb=" << static_cast<int>(dsp.efb)
              << " pmon=" << static_cast<unsigned>(dsp.pmon)
              << " non=" << static_cast<unsigned>(dsp.non)
              << " kon=" << static_cast<unsigned>(dsp.kon)
              << " kof=" << static_cast<unsigned>(dsp.kof)
              << " eon=" << static_cast<unsigned>(dsp.eon)
              << " dir=" << static_cast<unsigned>(dsp.dir)
              << " flg=" << static_cast<unsigned>(dsp.flg)
              << " esa=" << static_cast<unsigned>(dsp.esa)
              << " edl=" << static_cast<unsigned>(dsp.edl)
              << " endx=" << static_cast<unsigned>(dsp.endx)
              << "\n";
    print_echo_debug_if_enabled();

    const uintptr_t apu_base = reinterpret_cast<uintptr_t>(apu_ram);
    const bool print_bcur_bytes = std::getenv("SNESAPU_PRINT_BCUR") != nullptr;
    for (int i = 0; i < 8; ++i) {
        const Voice &voice = mix[i];
        const DSPVoice &dsp_voice = dsp.voice[i];
        const uintptr_t sidx_offset = voice_sidx_value(voice);
        const uintptr_t bcur_offset = voice_bcur_value(voice, apu_base);
        const bool bcur_in_apu = voice_bcur_in_apu(voice, apu_base);

        std::cout << "voice[" << i << "]"
                  << " srcn=" << static_cast<unsigned>(dsp_voice.srcn)
                  << " mSrc=" << static_cast<unsigned>(voice.mSrc)
                  << " pitch=" << dsp_voice.pitch
                  << " mRate=" << voice.mRate
                  << " mOrgP=" << voice.mOrgP
                  << " mDec=" << voice.mDec
                  << " volL=" << static_cast<int>(dsp_voice.volL)
                  << " volR=" << static_cast<int>(dsp_voice.volR)
                  << " envx=" << static_cast<int>(dsp_voice.envx)
                  << " outx=" << static_cast<int>(dsp_voice.outx)
                  << " eMode=" << static_cast<unsigned>(voice.eMode)
                  << " eRIdx=" << static_cast<unsigned>(voice.eRIdx)
                  << " eVal=" << voice.eVal
                  << " eAdj=" << voice.eAdj
                  << " eDest=" << voice.eDest
                  << " mOut=" << voice.mOut
                  << " mFlg=0x" << std::hex << std::setw(2) << std::setfill('0')
                  << static_cast<unsigned>(voice.mFlg) << std::dec
                  << " mKOn=" << static_cast<unsigned>(voice.mKOn)
                  << " adsr=0x" << std::hex << std::setw(4) << std::setfill('0')
                  << voice.vAdsr << std::dec
                  << " gain=" << static_cast<unsigned>(voice.vGain)
                  << " vRsv=" << static_cast<unsigned>(voice.vRsv)
                  << " sP1=" << voice.sP1
                  << " sP2=" << voice.sP2
                  << " sBuf0=" << voice.sBuf[0]
                  << " sBuf1=" << voice.sBuf[1]
                  << " sBuf2=" << voice.sBuf[2]
                  << " sBuf3=" << voice.sBuf[3]
                  << " sIdx=0x" << std::hex << sidx_offset << std::dec
                  << " bHdr=0x" << std::hex << std::setw(2) << std::setfill('0')
                  << static_cast<unsigned>(voice.bHdr) << std::dec
                  << " bCur=";
        if (bcur_in_apu) {
            std::cout << "apu+0x" << std::hex << bcur_offset << std::dec;
        } else {
            std::cout << "0x" << std::hex << bcur_offset << std::dec;
        }
        std::cout << " mTgtL=" << voice.mTgtL
                  << " mTgtR=" << voice.mTgtR
                  << " mChnL=" << voice.mChnL
                  << " mChnR=" << voice.mChnR
                  << " vMaxL=" << voice.vMaxL
                  << " vMaxR=" << voice.vMaxR
                  << "\n";
        if (print_bcur_bytes && bcur_in_apu && bcur_offset + 9 <= kApuRamSize) {
            std::cout << "voice[" << i << "] bCurBytes=";
            for (size_t j = 0; j < 9; ++j) {
                if (j) {
                    std::cout << ",";
                }
                std::cout << "0x" << std::hex << std::setw(2) << std::setfill('0')
                          << static_cast<unsigned>(apu_ram[bcur_offset + j]);
            }
            std::cout << std::dec << std::setfill(' ') << "\n";
        }
    }

    std::cout << "xram[0..7]=";
    for (int i = 0; i < 8; ++i) {
        if (i) {
            std::cout << ",";
        }
        std::cout << static_cast<unsigned>(extraRAM[i]);
    }
    std::cout << "\n";
    std::cout << "pcm[0..15]=";
    const size_t pcm_dump = std::min<size_t>(16, static_cast<size_t>(cursor - scratch.data()));
    for (size_t i = 0; i < pcm_dump; ++i) {
        if (i) {
            std::cout << ",";
        }
        std::cout << static_cast<unsigned>(scratch[i]);
    }
    std::cout << "\n";
    if (std::getenv("SNESAPU_DUMP_PCM_TAIL_FRAMES") != nullptr) {
        const size_t frame_count = static_cast<size_t>(
            env_u32_or_default("SNESAPU_DUMP_PCM_TAIL_FRAMES", 8));
        const size_t bytes_written = static_cast<size_t>(cursor - scratch.data());
        const size_t available_frames = bytes_written / 4;
        const size_t frames_to_dump = std::min(frame_count, available_frames);
        const size_t first_frame = available_frames - frames_to_dump;
        std::cout << "pcmtail first_frame=" << first_frame
                  << " frames=" << frames_to_dump
                  << " data=";
        const u8 *pcm = scratch.data() + first_frame * 4;
        for (size_t frame = 0; frame < frames_to_dump; ++frame) {
            const s16 left = static_cast<s16>(
                static_cast<u16>(pcm[frame * 4]) |
                (static_cast<u16>(pcm[frame * 4 + 1]) << 8));
            const s16 right = static_cast<s16>(
                static_cast<u16>(pcm[frame * 4 + 2]) |
                (static_cast<u16>(pcm[frame * 4 + 3]) << 8));
            if (frame) {
                std::cout << ",";
            }
            std::cout << left << ":" << right;
        }
        std::cout << "\n";
    }

    print_internal_state_if_enabled();
    return 0;
}
