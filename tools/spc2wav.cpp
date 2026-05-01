#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <csignal>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "types.h"
#include "DSP.h"
#include "APU.h"
#include "SPC700.h"
#include "snesapu_call_bridge.h"

namespace {

constexpr u32 kAmp100 = 65536;
constexpr u32 kDefaultRate = 32000;
constexpr u32 kDefaultSeconds = 120;
constexpr u32 kDefaultSpeed = 65536;
constexpr u32 kDefaultPitch = 32000;
constexpr u32 kDefaultStereo = 32768;
constexpr u32 kDefaultFeedback = 0;
constexpr u32 kDefaultUserDSPOpts = 0;
constexpr u32 kRequiredDSPOpts = DSP_FLOAT;
constexpr u32 kDefaultDSPOpts = kDefaultUserDSPOpts | kRequiredDSPOpts;
constexpr u32 kDefaultInterpolation = INT_GAUSS;
constexpr u32 kDefaultOutputChannels = 2;
constexpr s32 kDefaultOutputBits = 16;
constexpr u32 kCyclesPerSecond = 24576000;
constexpr u32 kRenderChunkSamples = kDefaultRate / 10;
constexpr size_t kSpcSize = 0x10200;
constexpr u64 kInitProbeSpinLimit = 500000000ULL;
constexpr size_t kSongLenOffset = 0xA9;
constexpr size_t kSongLenTextSize = 3;
constexpr size_t kFadeLenOffset = 0xAC;
constexpr size_t kFadeLenTextSize = 5;

enum class Id666TagFormat : u8 {
    kUnknown = 0,
    kText = 1,
    kBinary = 2,
};

struct SpcTiming {
    Id666TagFormat tag_format = Id666TagFormat::kUnknown;
    u32 song_seconds = 0;
    u32 fade_milliseconds = 0;
};

struct DspTraceEvent {
    u32 t64_count = 0;
    u16 pc = 0;
    u8 a = 0;
    u8 y = 0;
    u8 x = 0;
    u8 psw = 0;
    u8 sp = 0;
    u8 reg = 0;
    u8 val = 0;
    u8 voice_mode = 0;
    u8 voice_flags = 0;
    u8 voice_kon_delay = 0;
    u32 voice_counter = 0;
    u32 voice_env = 0;
};

constexpr size_t kMaxDspTraceEvents = 32768;
static DspTraceEvent g_dsp_trace[kMaxDspTraceEvents];
static size_t g_dsp_trace_count = 0;
static u32 g_dsp_trace_voice_index = 3;

#if defined(_WIN32) && defined(_M_X64)
extern "C" u32 apuDbgStage;
extern "C" u32 apuCbMask;
extern "C" uintptr_t apuCbFunc;
extern "C" u32 apuOutBufGuard;
extern "C" u32 outCur;
extern "C" u32 outLen;
extern "C" void trace_dsp_write_bridge(void);
#endif

#if defined(__x86_64__) && !defined(_WIN32)
extern "C" float mixBuf[] asm("mixBuf");
extern "C" u32 firCur asm("firCur");
extern "C" u32 firRate asm("firRate");
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
#endif

#if defined(__aarch64__) && !defined(_WIN32)
extern "C" u32 SNESAPUArm64DebugEcho(u32 *meta, float *echo, u32 echo_pairs, float *fir, u32 fir_pairs);
extern "C" u32 SNESAPUArm64DebugLastMix(float *values, u32 count);
extern "C" u32 SNESAPUArm64DebugVolumes(float *values, u32 count);
#endif

struct WavHeader {
    char riff[4];
    u32 riff_size;
    char wave[4];
    char fmt_[4];
    u32 fmt_size;
    u16 audio_format;
    u16 channel_count;
    u32 sample_rate;
    u32 byte_rate;
    u16 block_align;
    u16 bits_per_sample;
    char data[4];
    u32 data_size;
};

u32 float_bits(float value) {
    u32 bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

bool parse_u32(const char *text, u32 &value) {
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(text, &end, 10);
    if (!text[0] || !end || *end != '\0') {
        return false;
    }
    value = static_cast<u32>(parsed);
    return true;
}

bool parse_s32(const char *text, s32 &value) {
    char *end = nullptr;
    const long parsed = std::strtol(text, &end, 10);
    if (!text[0] || !end || *end != '\0') {
        return false;
    }
    value = static_cast<s32>(parsed);
    return true;
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

size_t bytes_per_sample_for_bits(s32 bits) {
    switch (bits) {
        case 8:
            return 1;
        case 16:
            return 2;
        case 24:
            return 3;
        case 32:
        case -32:
            return 4;
        default:
            return 2;
    }
}

bool write_wav(const std::string &path, const std::vector<u8> &pcm, u32 sample_rate, u32 channels, s32 bits) {
    const size_t bytes_per_sample = bytes_per_sample_for_bits(bits);
    const u16 wav_bits = static_cast<u16>(std::abs(bits));
    const u16 block_align = static_cast<u16>(channels * bytes_per_sample);
    WavHeader header = {
        {'R', 'I', 'F', 'F'},
        static_cast<u32>(sizeof(WavHeader) - 8 + pcm.size()),
        {'W', 'A', 'V', 'E'},
        {'f', 'm', 't', ' '},
        16,
        static_cast<u16>(bits == -32 ? 3 : 1),
        static_cast<u16>(channels),
        sample_rate,
        sample_rate * block_align,
        block_align,
        wav_bits,
        {'d', 'a', 't', 'a'},
        static_cast<u32>(pcm.size()),
    };

    std::ofstream output(path, std::ios::binary);
    if (!output) {
        return false;
    }
    output.write(reinterpret_cast<const char *>(&header), sizeof(header));
    output.write(reinterpret_cast<const char *>(pcm.data()), static_cast<std::streamsize>(pcm.size()));
    return static_cast<bool>(output);
}

bool env_flag_enabled(const char *name) {
    const char *value = std::getenv(name);
    return value && value[0] && value[0] != '0';
}

#if defined(_WIN32) && defined(_M_X64)
u32 current_apu_dbg_stage() {
    return apuDbgStage;
}

void print_callback_state_if_enabled(const char *label) {
    if (!env_flag_enabled("SNESAPU_PRINT_CALLBACK_STATE")) {
        return;
    }

    std::cerr << label
              << " apuCbMask=0x" << std::hex << apuCbMask
              << " apuCbFunc=0x" << static_cast<uintptr_t>(apuCbFunc)
              << " apuOutBufGuard=0x" << apuOutBufGuard
              << " outCur=0x" << outCur
              << " outLen=0x" << outLen
              << " apuDbgStage=0x" << apuDbgStage
              << std::dec << "\n";
}
#else
u32 current_apu_dbg_stage() {
    return 0;
}

void print_callback_state_if_enabled(const char *) {}
#endif

#if defined(_WIN32) && defined(_M_IX86)
extern "C" void __cdecl trace_dsp_write(volatile u8 *reg, volatile u8 val) {
#else
extern "C" void trace_dsp_write_impl(volatile u8 *reg, volatile u8 val) {
#endif
    if (g_dsp_trace_count >= kMaxDspTraceEvents) {
        return;
    }

    const volatile u8 *base = &dsp.reg[0];
    const ptrdiff_t index = reg - base;
    const u8 kon_reg = static_cast<u8>(offsetof(DSPReg, kon));
    const u8 kof_reg = static_cast<u8>(offsetof(DSPReg, kof));
    const u8 endx_reg = static_cast<u8>(offsetof(DSPReg, endx));
    if (!env_flag_enabled("SNESAPU_TRACE_DSP_ALL") &&
        index != kon_reg && index != kof_reg && index != endx_reg) {
        return;
    }

    DspTraceEvent &event = g_dsp_trace[g_dsp_trace_count++];
    event.t64_count = t64Cnt;
    if (env_flag_enabled("SNESAPU_TRACE_DSP_REGS")) {
        call_GetSPCRegs(&event.pc, &event.a, &event.y, &event.x, &event.psw, &event.sp);
    }
    event.reg = static_cast<u8>(index);
    event.val = val;
    const u32 voice_index = std::min<u32>(g_dsp_trace_voice_index, 7);
    event.voice_mode = mix[voice_index].eMode;
    event.voice_flags = mix[voice_index].mFlg;
    event.voice_kon_delay = mix[voice_index].mKOn;
    event.voice_counter = mix[voice_index].eCnt;
    event.voice_env = mix[voice_index].eVal;
}

#if !defined(_WIN32) && defined(__x86_64__)
extern "C" __attribute__((naked)) void trace_dsp_write_bridge(void) {
    asm volatile(
        "movq 8(%rsp), %rdi\n\t"
        "movzbl 16(%rsp), %esi\n\t"
        "movq %rsp, %rbx\n\t"
        "andq $-16, %rsp\n\t"
        "callq _trace_dsp_write_impl\n\t"
        "movq %rbx, %rsp\n\t"
        "retq\n\t");
}
#endif

void maybe_enable_dsp_trace() {
    if (!env_flag_enabled("SNESAPU_TRACE_DSP_WRITES")) {
        return;
    }

    if (const char *voice = std::getenv("SNESAPU_TRACE_DSP_VOICE_INDEX")) {
        char *end = nullptr;
        const unsigned long parsed = std::strtoul(voice, &end, 10);
        if (voice[0] && end && *end == '\0') {
            g_dsp_trace_voice_index = static_cast<u32>(std::min<unsigned long>(parsed, 7));
        }
    }

    g_dsp_trace_count = 0;
#if defined(_WIN32) && defined(_M_IX86)
    call_SetDSPDbg(reinterpret_cast<DSPDebug *>(reinterpret_cast<void *>(&trace_dsp_write)));
#elif (defined(_WIN32) && defined(_M_X64)) || (defined(__x86_64__) && !defined(_WIN32))
    call_SetDSPDbg(reinterpret_cast<DSPDebug *>(reinterpret_cast<void *>(&trace_dsp_write_bridge)));
#else
    call_SetDSPDbg(reinterpret_cast<DSPDebug *>(reinterpret_cast<void *>(&trace_dsp_write_impl)));
#endif
}

void maybe_print_dsp_trace() {
    if (!env_flag_enabled("SNESAPU_TRACE_DSP_WRITES")) {
        return;
    }

    const u8 kon_reg = static_cast<u8>(offsetof(DSPReg, kon));
    const u8 kof_reg = static_cast<u8>(offsetof(DSPReg, kof));
    const u8 endx_reg = static_cast<u8>(offsetof(DSPReg, endx));
    for (size_t i = 0; i < g_dsp_trace_count; ++i) {
        const DspTraceEvent &event = g_dsp_trace[i];
        const char *name = "reg";
        if (event.reg == kon_reg) {
            name = "kon";
        } else if (event.reg == kof_reg) {
            name = "kof";
        } else if (event.reg == endx_reg) {
            name = "endx";
        } else if (event.reg == 0x0d) {
            name = "efb";
        } else if (event.reg == 0x2d) {
            name = "pmon";
        } else if (event.reg == 0x3d) {
            name = "non";
        } else if (event.reg == 0x4d) {
            name = "eon";
        } else if (event.reg == 0x5d) {
            name = "dir";
        } else if (event.reg == 0x6c) {
            name = "flg";
        } else if (event.reg == 0x6d) {
            name = "esa";
        } else if (event.reg == 0x7d) {
            name = "edl";
        }
        std::cout << "dsp_trace[" << i << "]"
                  << " t64Cnt=" << event.t64_count
                  << " reg=" << name
                  << " addr=0x" << std::hex << static_cast<unsigned>(event.reg) << std::dec
                  << " val=" << static_cast<unsigned>(event.val)
                  << " pc=0x" << std::hex << static_cast<unsigned>(event.pc)
                  << " a=0x" << static_cast<unsigned>(event.a)
                  << " y=0x" << static_cast<unsigned>(event.y)
                  << " x=0x" << static_cast<unsigned>(event.x)
                  << " psw=0x" << static_cast<unsigned>(event.psw)
                  << " sp=0x" << static_cast<unsigned>(event.sp)
                  << " voice=" << (g_dsp_trace_voice_index + 1)
                  << " vMode=0x" << std::hex << static_cast<unsigned>(event.voice_mode)
                  << " vCnt=0x" << event.voice_counter
                  << " vEnv=0x" << event.voice_env
                  << " vFlg=0x" << static_cast<unsigned>(event.voice_flags)
                  << " vKOn=0x" << static_cast<unsigned>(event.voice_kon_delay)
                  << std::dec
                  << "\n";
    }
}

u32 env_mask_or_default(const char *name, u32 fallback) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return fallback;
    }

    char *end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 0);
    if (!end || *end != '\0') {
        std::cerr << "invalid " << name << ": " << value << "\n";
        std::exit(1);
    }
    return static_cast<u32>(parsed) & 0xffu;
}

void print_voice_snapshot(
    const char *phase,
    u32 frame,
    u32 t64_count,
    u32 voice_mask) {
    u16 pc = 0;
    u8 a = 0;
    u8 y = 0;
    u8 x = 0;
    u8 psw = 0;
    u8 sp = 0;
    call_GetSPCRegs(&pc, &a, &y, &x, &psw, &sp);
    u8 *ram = nullptr;
    u8 *xram = nullptr;
    u8 *out_port = nullptr;
    u32 *t64_count_ptr = nullptr;
    DSPReg *dsp_regs = nullptr;
    Voice *voices = nullptr;
    u32 *v_mmax_l = nullptr;
    u32 *v_mmax_r = nullptr;
    call_GetAPUData(&ram, &xram, &out_port, &t64_count_ptr, &dsp_regs, &voices, &v_mmax_l, &v_mmax_r);
    const u8 opcode = ram ? ram[pc] : 0;
    std::cout << "frame_trace"
              << " phase=" << phase
              << " frame=" << frame
              << " t64=0x" << std::hex << std::setfill('0') << std::setw(8) << t64_count
              << " pc=0x" << std::setw(4) << pc
              << " op=0x" << std::setw(2) << static_cast<unsigned>(opcode)
              << " a=0x" << std::setw(2) << static_cast<unsigned>(a)
              << " y=0x" << std::setw(2) << static_cast<unsigned>(y)
              << " x=0x" << std::setw(2) << static_cast<unsigned>(x)
              << " psw=0x" << std::setw(2) << static_cast<unsigned>(psw)
              << " sp=0x" << std::setw(2) << static_cast<unsigned>(sp)
              << " kon=0x" << std::setw(2) << static_cast<unsigned>(dsp.kon)
              << " kof=0x" << std::setw(2) << static_cast<unsigned>(dsp.kof)
              << " endx=0x" << std::setw(2) << static_cast<unsigned>(dsp.endx)
              << std::dec << std::setfill(' ') << "\n";

    for (u32 i = 0; i < 8; ++i) {
        if ((voice_mask & (1u << i)) == 0) {
            continue;
        }
        const Voice &voice = mix[i];
        const DSPVoice &dsp_voice = dsp.voice[i];
        std::cout << "frame_voice"
                  << " frame=" << frame
                  << " voice=" << (i + 1)
                  << " srcn=0x" << std::hex << std::setfill('0') << std::setw(2)
                  << static_cast<unsigned>(dsp_voice.srcn)
                  << " pitch=0x" << std::setw(4) << dsp_voice.pitch
                  << " envx=0x" << std::setw(2)
                  << static_cast<unsigned>(static_cast<u8>(dsp_voice.envx))
                  << " outx=0x" << std::setw(2)
                  << static_cast<unsigned>(static_cast<u8>(dsp_voice.outx))
                  << " vAdsr=0x" << std::setw(4) << voice.vAdsr
                  << " vGain=0x" << std::setw(2) << static_cast<unsigned>(voice.vGain)
                  << " vRsv=0x" << std::setw(2) << static_cast<unsigned>(voice.vRsv)
                  << " sIdx=0x" << std::setw(8) << voice.sIdx
                  << " bCur=0x" << std::setw(8) << voice.bCur
                  << " bHdr=0x" << std::setw(2) << static_cast<unsigned>(voice.bHdr)
                  << " mRate=0x" << std::setw(8) << voice.mRate
                  << " mDec=0x" << std::setw(4) << voice.mDec
                  << " mSrc=0x" << std::setw(2) << static_cast<unsigned>(voice.mSrc)
                  << " mKOn=0x" << std::setw(2) << static_cast<unsigned>(voice.mKOn)
                  << " mFlg=0x" << std::setw(2) << static_cast<unsigned>(voice.mFlg)
                  << " mOrgP=0x" << std::setw(8) << voice.mOrgP
                  << " mOut=0x" << std::setw(8) << static_cast<u32>(voice.mOut)
                  << " mChnL=0x" << std::setw(8) << static_cast<u32>(voice.mChnL)
                  << " mChnR=0x" << std::setw(8) << static_cast<u32>(voice.mChnR)
                  << " mTgtL=0x" << std::setw(8) << float_bits(voice.mTgtL)
                  << " mTgtR=0x" << std::setw(8) << float_bits(voice.mTgtR)
                  << " eMode=0x" << std::setw(2) << static_cast<unsigned>(voice.eMode)
                  << " eRIdx=0x" << std::setw(2) << static_cast<unsigned>(voice.eRIdx)
                  << " eRate=0x" << std::setw(8) << voice.eRate
                  << " eCnt=0x" << std::setw(8) << voice.eCnt
                  << " eVal=0x" << std::setw(8) << voice.eVal
                  << " eAdj=0x" << std::setw(8) << static_cast<u32>(voice.eAdj)
                  << " eDest=0x" << std::setw(8) << voice.eDest
                  << " sP1=0x" << std::setw(4) << static_cast<u16>(voice.sP1)
                  << " sP2=0x" << std::setw(4) << static_cast<u16>(voice.sP2)
                  << std::dec << std::setfill(' ') << "\n";
    }
}

bool trace_chunk_range_allows(u32 frame) {
    u32 start = 0;
    u32 end = ~0U;
    if (const char *text = std::getenv("SNESAPU_TRACE_CHUNK_START")) {
        parse_u32(text, start);
    }
    if (const char *text = std::getenv("SNESAPU_TRACE_CHUNK_END")) {
        parse_u32(text, end);
    }
    return frame >= start && frame <= end;
}

u32 trace_pair_count_or_default() {
    u32 pair_count = 4;
    if (const char *text = std::getenv("SNESAPU_TRACE_ECHO_PAIRS")) {
        parse_u32(text, pair_count);
    }
    return std::clamp<u32>(pair_count, 1, 32);
}

u32 trace_echo_back_pairs_or_default() {
    u32 back_pairs = 0;
    if (const char *text = std::getenv("SNESAPU_DUMP_ECHO_BACK_PAIRS")) {
        parse_u32(text, back_pairs);
    }
    return back_pairs;
}

void print_float_pair_line(const char *label, const std::vector<float> &pairs) {
    std::cout << label << "=";
    for (size_t i = 0; i + 1 < pairs.size(); i += 2) {
        if (i) {
            std::cout << ";";
        }
        std::cout << std::setprecision(10) << pairs[i] << "," << pairs[i + 1];
    }
    std::cout << "\n";
}

void print_echo_snapshot_if_enabled(const char *phase, u32 frame) {
    if (!env_flag_enabled("SNESAPU_TRACE_ECHO") || !trace_chunk_range_allows(frame)) {
        return;
    }

    const u32 pair_count = trace_pair_count_or_default();
#if defined(__x86_64__) && !defined(_WIN32)
    const u32 echo_len = echoLenD == 0 ? 8u : echoLenD;
    const u32 echo_offset = (echoMaxD - echoCurD) % echo_len;
    const u32 back_bytes = (trace_echo_back_pairs_or_default() * 8u) % echo_len;
    const u32 echo_start = (echo_offset + echo_len - back_bytes) % echo_len;
    const auto *echo_bytes = reinterpret_cast<const u8 *>(echoBuf);
    const auto *fir_bytes = reinterpret_cast<const u8 *>(firBuf);
    std::vector<float> echo(static_cast<size_t>(pair_count) * 2u);
    std::vector<float> fir(static_cast<size_t>(pair_count) * 2u);
    for (u32 i = 0; i < pair_count; ++i) {
        const u32 byte_offset = (echo_start + i * 8u) % echo_len;
        const auto *sample = reinterpret_cast<const float *>(echo_bytes + byte_offset);
        echo[i * 2] = sample[0];
        echo[i * 2 + 1] = sample[1];

        const u32 fir_offset = ((firCur & 0xffu) * 2u + i * 8u);
        const auto *fir_sample = reinterpret_cast<const float *>(fir_bytes + fir_offset);
        fir[i * 2] = fir_sample[0];
        fir[i * 2 + 1] = fir_sample[1];
    }
    std::cout << "echo_trace"
              << " phase=" << phase
              << " frame=" << frame
              << " echoLenD=" << echoLenD
              << " echoMaxD=" << echoMaxD
              << " echoCurD=" << echoCurD
              << " echoOffset=" << echo_start
              << " echoLenM=" << echoLenM
              << " echoMaxM=" << echoMaxM
              << " echoCurM=" << echoCurM
              << " echoDecM=" << echoDecM
              << " echoFB=" << std::setprecision(10) << echoFB
              << " echoFBCT=" << echoFBCT
              << " firCur=" << firCur
              << " firRate=" << firRate
              << " mainL=" << nowMainL
              << " mainR=" << nowMainR
              << " echoL=" << nowEchoL
              << " echoR=" << nowEchoR
              << "\n";
    print_float_pair_line("echo_pairs", echo);
    print_float_pair_line("fir_pairs", fir);
#elif defined(__aarch64__) && !defined(_WIN32)
    u32 meta[8] {};
    std::vector<float> echo(static_cast<size_t>(pair_count) * 2u);
    std::vector<float> fir(static_cast<size_t>(pair_count) * 2u);
    float volumes[8] {};
    if (SNESAPUArm64DebugEcho(meta, echo.data(), pair_count, fir.data(), pair_count) &&
        SNESAPUArm64DebugVolumes(volumes, 8)) {
        std::cout << "echo_trace"
                  << " phase=" << phase
                  << " frame=" << frame
                  << " echoLenD=" << meta[0]
                  << " echoPendingD=" << meta[1]
                  << " echoCurD=" << meta[2]
                  << " echoOffset=" << meta[3]
                  << " firPos=" << meta[4]
                  << " echoLenM=" << meta[5]
                  << " echoCurM=" << meta[6]
                  << " echoDecM=" << meta[7]
                  << " mainL=" << std::setprecision(10) << volumes[0]
                  << " mainR=" << volumes[1]
                  << " echoL=" << volumes[2]
                  << " echoR=" << volumes[3]
                  << " targetMainL=" << volumes[4]
                  << " targetMainR=" << volumes[5]
                  << " targetEchoL=" << volumes[6]
                  << " targetEchoR=" << volumes[7]
                  << "\n";
        print_float_pair_line("echo_pairs", echo);
        print_float_pair_line("fir_pairs", fir);
    }
#else
    (void)phase;
    (void)frame;
#endif
}

void print_mix_snapshot_if_enabled(
    const char *phase,
    u32 frame,
    const u8 *pcm,
    size_t frame_bytes,
    u32 chunk_samples) {
    if (!env_flag_enabled("SNESAPU_TRACE_MIX") || !trace_chunk_range_allows(frame)) {
        return;
    }

    u32 mix_index = 0;
    if (const char *text = std::getenv("SNESAPU_TRACE_MIX_INDEX")) {
        parse_u32(text, mix_index);
    }
    u32 pcm_index = chunk_samples == 0 ? 0 : chunk_samples - 1;
    if (const char *text = std::getenv("SNESAPU_TRACE_PCM_INDEX")) {
        parse_u32(text, pcm_index);
    }
    if (chunk_samples != 0) {
        pcm_index = std::min(pcm_index, chunk_samples - 1);
    }

    float values[2] = {0.0f, 0.0f};
#if defined(__x86_64__) && !defined(_WIN32)
    constexpr u32 kMixSize = 1024;
    mix_index = std::min(mix_index, kMixSize - 1);
    values[0] = mixBuf[mix_index * 4];
    values[1] = mixBuf[mix_index * 4 + 1];
#elif defined(__aarch64__) && !defined(_WIN32)
    SNESAPUArm64DebugLastMix(values, 2);
#endif

    const u8 *pcm_frame = pcm + static_cast<size_t>(pcm_index) * frame_bytes;
    const s16 pcm_left = static_cast<s16>(
        static_cast<u16>(pcm_frame[0]) | (static_cast<u16>(pcm_frame[1]) << 8));
    const s16 pcm_right = static_cast<s16>(
        static_cast<u16>(pcm_frame[2]) | (static_cast<u16>(pcm_frame[3]) << 8));
    u32 left_bits = 0;
    u32 right_bits = 0;
    std::memcpy(&left_bits, &values[0], sizeof(left_bits));
    std::memcpy(&right_bits, &values[1], sizeof(right_bits));
    std::cout << "frame_mix"
              << " phase=" << phase
              << " frame=" << frame
              << " mix_index=" << mix_index
              << " pcm_index=" << pcm_index
              << " left=" << std::setprecision(10) << values[0]
              << " right=" << values[1]
              << " left_bits=0x" << std::hex << std::setw(8) << std::setfill('0') << left_bits
              << " right_bits=0x" << std::setw(8) << right_bits
              << std::dec << std::setfill(' ')
              << " pcm=" << pcm_left << ":" << pcm_right
              << "\n";
}

void apply_voice_flags_from_env() {
    const u32 mute_mask = env_mask_or_default("SNESAPU_MUTE_MASK", 0);
    const u32 noise_mask = env_mask_or_default("SNESAPU_NOISE_MASK", 0);
    for (int i = 0; i < 8; ++i) {
        mix[i].mFlg &= static_cast<u8>(~MFLG_USER);
        if ((mute_mask & (1u << i)) != 0) {
            mix[i].mFlg |= MFLG_MUTE;
        }
        if ((noise_mask & (1u << i)) != 0) {
            mix[i].mFlg |= MFLG_NOISE;
        }
    }
}

u32 env_u32_or_default(const char *name, u32 fallback) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return fallback;
    }

    u32 parsed = 0;
    return parse_u32(value, parsed) ? parsed : fallback;
}

void apply_dsp_register_overrides_from_env() {
    if (const char *efb = std::getenv("SNESAPU_FORCE_EFB")) {
        u32 value = 0;
        if (parse_u32(efb, value)) {
            call_SetDSPReg(0x0d, static_cast<u8>(value & 0xffu));
        }
    }
    if (env_flag_enabled("SNESAPU_FORCE_ECHO_VOLUME_ZERO")) {
        call_SetDSPReg(0x2c, 0);
        call_SetDSPReg(0x3c, 0);
    }
}

s32 env_s32_or_default(const char *name, s32 fallback) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return fallback;
    }

    s32 parsed = 0;
    return parse_s32(value, parsed) ? parsed : fallback;
}

u32 sanitized_output_channels(u32 channels) {
    return channels == 1 ? 1 : 2;
}

s32 sanitized_output_bits(s32 bits) {
    switch (bits) {
        case 8:
        case 16:
        case 24:
        case 32:
        case -32:
            return bits;
        default:
            return kDefaultOutputBits;
    }
}

u32 sanitized_output_rate(u32 rate) {
    if (rate < 8000 || rate > 192000) {
        return kDefaultRate;
    }
    return rate;
}

u32 sanitized_interpolation(u32 interpolation) {
    switch (interpolation) {
        case INT_NONE:
        case INT_LINEAR:
        case INT_CUBIC:
        case INT_GAUSS:
        case INT_SINC:
        case INT_GAUSS4:
            return interpolation;
        default:
            return kDefaultInterpolation;
    }
}

u32 env_interpolation_or_default() {
    return sanitized_interpolation(env_u32_or_default("SNESAPU_INTERPOLATION", kDefaultInterpolation));
}

u32 effective_dsp_options_from_env() {
    return env_u32_or_default("SNESAPU_DSP_OPTIONS", kDefaultUserDSPOpts) | kRequiredDSPOpts;
}

u32 effective_pitch_from_env(u32 speed) {
    const u32 pitch = env_u32_or_default("SNESAPU_PITCH_VALUE", kDefaultPitch);
    if (!env_flag_enabled("SNESAPU_PITCH_ASYNC")) {
        return std::clamp<u32>(pitch, 16384, 262144);
    }
    return static_cast<u32>((static_cast<uint64_t>(speed) * std::clamp<u32>(pitch, 16384, 262144)) / kDefaultSpeed);
}

s32 feedback_to_efbct(u32 feedback) {
    return static_cast<s32>(32768) - static_cast<s32>(feedback);
}

void write_timeout_stage(u32 stage) {
    char buffer[] = "InitAPU timeout stage=0x00000000\n";
    static constexpr char kHex[] = "0123456789abcdef";
    for (int i = 0; i < 8; ++i) {
        const unsigned shift = static_cast<unsigned>((7 - i) * 4);
        buffer[24 + i] = kHex[(stage >> shift) & 0x0f];
    }
#if defined(_WIN32)
    (void)!::_write(2, buffer, static_cast<unsigned>(sizeof(buffer) - 1));
#else
    (void)!::write(STDERR_FILENO, buffer, sizeof(buffer) - 1);
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
#if defined(_WIN32) && defined(_M_X64)
                  << " apuCbMask=0x" << apuCbMask
                  << " apuCbFunc=0x" << static_cast<uintptr_t>(apuCbFunc)
                  << " apuOutBufGuard=0x" << apuOutBufGuard
                  << " outCur=0x" << outCur
                  << " outLen=0x" << outLen
#endif
                  << std::dec << "\n";
        return nullptr;
    }
}
#else
void *call_emuapu_checked(void *buffer, u32 length, u8 type) {
    return call_EmuAPU(buffer, length, type);
}
#endif

u32 parse_decimal_field(const u8 *text, size_t length) {
    u32 value = 0;
    bool saw_digit = false;
    for (size_t i = 0; i < length; ++i) {
        const u8 ch = text[i];
        if (ch >= '0' && ch <= '9') {
            saw_digit = true;
            value = value * 10 + static_cast<u32>(ch - '0');
        } else if (ch == 0 || ch == ' ' || ch == '\r' || ch == '\n' || ch == '\t') {
            continue;
        } else {
            return 0;
        }
    }
    return saw_digit ? value : 0;
}

u16 read_le16(const u8 *data) {
    return static_cast<u16>(data[0] | (static_cast<u16>(data[1]) << 8));
}

u32 read_le32(const u8 *data) {
    return static_cast<u32>(data[0] |
                            (static_cast<u32>(data[1]) << 8) |
                            (static_cast<u32>(data[2]) << 16) |
                            (static_cast<u32>(data[3]) << 24));
}

Id666TagFormat detect_id666_tag_format(const u8 *data, size_t size) {
    if (size < 256) {
        return Id666TagFormat::kUnknown;
    }

    const bool phase1 =
        data[0x23] == 0x1a ||
        (((data[0x2e] | data[0x4e] | data[0x6e] | data[0x7e] | data[0xb0] | data[0xb1]) & 0xe0) |
         data[0x24] | data[0x9e] | data[0xa9] | data[0xac] | data[0xd1] | data[0xd2]);
    if (!phase1) {
        return Id666TagFormat::kUnknown;
    }

    const bool phase2 =
        (data[0xa2] | data[0xa3] | data[0xa4] | data[0xa5] | data[0xa6] |
         data[0xa7] | data[0xa8] | data[0xab] | data[0xaf]) < 0x20;
    const bool phase3 = (data[0xb0] >= 0x20) || (data[0xb1] < 0x20);
    const bool phase4 = data[0xd2] < 0x30;
    if (phase2 && phase3 && phase4) {
        return Id666TagFormat::kBinary;
    }
    return Id666TagFormat::kText;
}

SpcTiming parse_spc_timing(const std::vector<u8> &spc) {
    SpcTiming timing;
    timing.tag_format = detect_id666_tag_format(spc.data(), spc.size());

    if (timing.tag_format == Id666TagFormat::kBinary) {
        timing.song_seconds = std::min<u32>(read_le16(spc.data() + kSongLenOffset), 999);
        timing.fade_milliseconds = std::min<u32>(read_le32(spc.data() + kFadeLenOffset) & 0x00ffffff, 99999);
        return timing;
    }

    if (timing.tag_format == Id666TagFormat::kText) {
        timing.song_seconds = parse_decimal_field(spc.data() + kSongLenOffset, kSongLenTextSize);
        timing.fade_milliseconds = parse_decimal_field(spc.data() + kFadeLenOffset, kFadeLenTextSize);
    }
    return timing;
}

u32 choose_render_seconds(const SpcTiming &timing) {
    if (!timing.song_seconds) {
        return kDefaultSeconds;
    }

    const u64 total_milliseconds =
        static_cast<u64>(timing.song_seconds) * 1000ULL + timing.fade_milliseconds;
    const u32 total_seconds = static_cast<u32>((total_milliseconds + 999ULL) / 1000ULL);
    return total_seconds ? total_seconds : kDefaultSeconds;
}

extern "C" void handle_probe_alarm(int) {
    write_timeout_stage(current_apu_dbg_stage());
    _exit(2);
}

void print_usage(const char *argv0) {
    std::cerr << "usage: " << argv0 << " <input.spc> <output.wav> [seconds]\n"
              << "       seconds omitted -> use ID666 length/fade, or 120 seconds if unavailable\n";
}

}  // namespace

int __cdecl main(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        print_usage(argv[0]);
        return 1;
    }

    u32 seconds = kDefaultSeconds;
    if (argc == 4 && !parse_u32(argv[3], seconds)) {
        std::cerr << "invalid seconds value: " << argv[3] << "\n";
        return 1;
    }

    std::vector<u8> spc;
    if (!read_file(argv[1], spc)) {
        std::cerr << "failed to read SPC file: " << argv[1] << "\n";
        return 1;
    }
    if (spc.size() < kSpcSize) {
        std::cerr << "SPC file is too small: " << spc.size() << " bytes\n";
        return 1;
    }
    if (spc.size() > kSpcSize) {
        spc.resize(kSpcSize);
    }
    const SpcTiming timing = parse_spc_timing(spc);
    const u32 render_chunk_samples =
        std::max<u32>(1, env_u32_or_default("SNESAPU_CHUNK_SAMPLES", kRenderChunkSamples));
    bool render_in_cycles = false;
    if (env_flag_enabled("SNESAPU_RENDER_SAMPLES")) {
        render_in_cycles = false;
    }
    if (env_flag_enabled("SNESAPU_RENDER_CYCLES")) {
        render_in_cycles = true;
    }

    if (argc != 4) {
        seconds = choose_render_seconds(timing);
    }

    std::cerr << "InitAPU\n";
    if (env_flag_enabled("SNESAPU_PROBE_INIT")) {
        std::atomic<bool> init_done{false};
        u32 init_result = 0;
        std::thread init_thread([&]() {
            init_result = call_InitAPU(1);
            init_done.store(true, std::memory_order_release);
        });

        for (u64 spin = 0; spin < kInitProbeSpinLimit; ++spin) {
            if (init_done.load(std::memory_order_acquire)) {
                init_thread.join();
                if (!init_result) {
                    std::cerr << "InitAPU failed\n";
                    return 1;
                }
                goto init_done;
            }
        }

        write_timeout_stage(current_apu_dbg_stage());
        init_thread.detach();
        _exit(2);
init_done:
        if (!init_result) {
            std::cerr << "InitAPU failed\n";
            return 1;
        }
    } else if (!call_InitAPU(1)) {
        std::cerr << "InitAPU failed\n";
        return 1;
    }

    std::cerr << "LoadSPCFile\n";
    maybe_enable_dsp_trace();
    call_LoadSPCFile(spc.data());
    const u32 speed = env_u32_or_default("SNESAPU_SPEED_VALUE", kDefaultSpeed);
    const u32 output_channels =
        sanitized_output_channels(env_u32_or_default("SNESAPU_OUTPUT_CHANNELS", kDefaultOutputChannels));
    const s32 output_bits =
        sanitized_output_bits(env_s32_or_default("SNESAPU_OUTPUT_BITS", kDefaultOutputBits));
    const u32 output_rate =
        sanitized_output_rate(env_u32_or_default("SNESAPU_OUTPUT_RATE", kDefaultRate));
    const size_t frame_bytes =
        static_cast<size_t>(output_channels) * bytes_per_sample_for_bits(output_bits);
    std::cerr << "SetAPUOpt\n";
    call_SetAPUOpt(MIX_INT,
                   output_channels,
                   static_cast<u32>(output_bits),
                   output_rate,
                   env_interpolation_or_default(),
                   effective_dsp_options_from_env());
    std::cerr << "SetAPUSmpClk\n";
    call_SetAPUSmpClk(speed);
    std::cerr << "SetDSPPitch\n";
    call_SetDSPPitch(effective_pitch_from_env(speed));
    std::cerr << "SetDSPStereo\n";
    call_SetDSPStereo(env_u32_or_default("SNESAPU_STEREO_SEPARATION", kDefaultStereo));
    std::cerr << "SetDSPEFBCT\n";
    call_SetDSPEFBCT(feedback_to_efbct(env_u32_or_default("SNESAPU_FEEDBACK", kDefaultFeedback)));
    std::cerr << "SetDSPAmp\n";
    call_SetDSPAmp(env_u32_or_default("SNESAPU_AMP_VALUE", kAmp100));
    if (timing.song_seconds && !env_flag_enabled("SNESAPU_SKIP_LENGTH")) {
        std::cerr << "SetAPULength\n";
        call_SetAPULength(timing.song_seconds * 64000U, timing.fade_milliseconds << 6);
    }
    apply_dsp_register_overrides_from_env();
    apply_voice_flags_from_env();
    print_callback_state_if_enabled("before_render");

    const u32 sample_count = seconds * output_rate;
    const size_t pcm_bytes = static_cast<size_t>(sample_count) * frame_bytes;
    const size_t pcm_slack_bytes =
        static_cast<size_t>(env_u32_or_default("SNESAPU_PCM_SLACK_SAMPLES", 0)) * frame_bytes;
    const bool trace_frames = env_flag_enabled("SNESAPU_TRACE_FRAMES");
    const u32 trace_frame_start = env_u32_or_default("SNESAPU_TRACE_FRAME_START", 0);
    const u32 trace_frame_end = env_u32_or_default("SNESAPU_TRACE_FRAME_END", trace_frame_start);
    const u32 trace_voice_mask = env_mask_or_default("SNESAPU_TRACE_VOICE_MASK", 0xff);
    const bool trace_chunk_voices = env_flag_enabled("SNESAPU_TRACE_CHUNK_VOICES");
    const u32 trace_chunk_start = env_u32_or_default("SNESAPU_TRACE_CHUNK_START", 0);
    const u32 trace_chunk_end = env_u32_or_default("SNESAPU_TRACE_CHUNK_END", ~0U);
    const bool apply_mid_dsp_overrides = std::getenv("SNESAPU_FORCE_DSP_AFTER_SAMPLES") != nullptr;
    const u32 mid_dsp_override_sample =
        env_u32_or_default("SNESAPU_FORCE_DSP_AFTER_SAMPLES", 0);
    bool mid_dsp_overrides_applied = false;
    std::vector<u8> pcm(pcm_bytes + pcm_slack_bytes);
    std::fill(pcm.begin(), pcm.end(), 0xCC);
    std::cerr << "EmuAPU\n";
    u32 rendered_samples = 0;
    while (rendered_samples < sample_count) {
        u32 chunk_samples = std::min(render_chunk_samples, sample_count - rendered_samples);
        if (apply_mid_dsp_overrides &&
            !mid_dsp_overrides_applied &&
            rendered_samples < mid_dsp_override_sample &&
            rendered_samples + chunk_samples > mid_dsp_override_sample) {
            chunk_samples = mid_dsp_override_sample - rendered_samples;
        }
        if (trace_frames) {
            if (rendered_samples < trace_frame_start) {
                chunk_samples = std::min(chunk_samples, trace_frame_start - rendered_samples);
            } else if (rendered_samples <= trace_frame_end) {
                chunk_samples = 1;
            }
        }
        u8 *chunk_base = pcm.data() + (static_cast<size_t>(rendered_samples) * frame_bytes);
        void *chunk_end = nullptr;
        if (render_in_cycles) {
            const u32 chunk_cycles =
                static_cast<u32>((static_cast<uint64_t>(chunk_samples) * kCyclesPerSecond) / output_rate);
            chunk_end = call_emuapu_checked(chunk_base, chunk_cycles, 0);
        } else {
            chunk_end = call_emuapu_checked(chunk_base, chunk_samples, 1);
        }
        u8 *chunk_end_bytes = static_cast<u8 *>(chunk_end);
        if (!chunk_end_bytes || chunk_end_bytes < chunk_base) {
            std::cerr << "EmuAPU returned an invalid buffer pointer\n";
            return 1;
        }

        const size_t produced_bytes =
            static_cast<size_t>(chunk_end_bytes - chunk_base);
        const size_t expected_bytes = static_cast<size_t>(chunk_samples) * frame_bytes;
        if (produced_bytes != expected_bytes) {
            std::cerr << "EmuAPU produced " << produced_bytes
                      << " bytes, expected " << expected_bytes
                      << " at sample offset " << rendered_samples
                      << " chunk_samples=" << chunk_samples
                      << " chunk_base=" << static_cast<void *>(chunk_base)
                      << " chunk_end=" << chunk_end << "\n";
            return 1;
        }

        rendered_samples += chunk_samples;
        if (apply_mid_dsp_overrides &&
            !mid_dsp_overrides_applied &&
            rendered_samples >= mid_dsp_override_sample) {
            apply_dsp_register_overrides_from_env();
            mid_dsp_overrides_applied = true;
        }
        if (trace_frames &&
            rendered_samples >= trace_frame_start &&
            rendered_samples <= trace_frame_end) {
            print_voice_snapshot("after_chunk", rendered_samples, t64Cnt, trace_voice_mask);
            print_mix_snapshot_if_enabled(
                "after_chunk", rendered_samples, chunk_base, frame_bytes, chunk_samples);
        } else if (!trace_frames) {
            if (trace_chunk_voices &&
                rendered_samples >= trace_chunk_start &&
                rendered_samples <= trace_chunk_end) {
                print_voice_snapshot("after_chunk", rendered_samples, t64Cnt, trace_voice_mask);
            }
            print_mix_snapshot_if_enabled(
                "after_chunk", rendered_samples, chunk_base, frame_bytes, chunk_samples);
            print_echo_snapshot_if_enabled("after_chunk", rendered_samples);
        }
    }
    print_callback_state_if_enabled("after_render");
    if (pcm_slack_bytes != 0) {
        size_t first_overrun = pcm.size();
        size_t last_overrun = 0;
        for (size_t i = pcm_bytes; i < pcm.size(); ++i) {
            if (pcm[i] != 0xCC) {
                first_overrun = i;
                break;
            }
        }
        if (first_overrun != pcm.size()) {
            for (size_t i = pcm.size(); i-- > first_overrun;) {
                if (pcm[i] != 0xCC) {
                    last_overrun = i;
                    break;
                }
            }
            std::cerr << "PCM overrun first_byte=" << (first_overrun - pcm_bytes)
                      << " last_byte=" << (last_overrun - pcm_bytes)
                      << " total_bytes=" << (last_overrun - first_overrun + 1)
                      << "\n";
        }
    }
    pcm.resize(pcm_bytes);
    std::cerr << "write_wav\n";

    if (!write_wav(argv[2], pcm, output_rate, output_channels, output_bits)) {
        std::cerr << "failed to write WAV file: " << argv[2] << "\n";
        return 1;
    }

    maybe_print_dsp_trace();
    std::cout << "rendered " << argv[2] << "\n";
    return 0;
}
