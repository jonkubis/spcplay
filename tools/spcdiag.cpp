#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "../snesapu.dll/types.h"
#include "../snesapu.dll/DSP.h"
#include "../snesapu.dll/APU.h"

namespace {

constexpr u32 kAmp100 = 65536;
constexpr u32 kDefaultRate = 32000;
constexpr u32 kDefaultSpeed = 65536;
constexpr u32 kDefaultPitch = 32000;
constexpr u32 kDefaultStereo = 32768;
constexpr s32 kDefaultEfbct = 32768;
constexpr u32 kDefaultDSPOpts = DSP_ANALOG | DSP_ECHOFIR | DSP_FLOAT;
constexpr u32 kCyclesPerSecond = 24576000;
constexpr size_t kSpcSize = 0x10200;
bool g_debug = false;

#define SNESAPU_CALL_CLOBBERS \
    "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory", "cc"

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

u32 call_GetSNESAPUContextSize() {
    u64 ret = 0;
    asm volatile(
        "call _GetSNESAPUContextSize\n\t"
        : "=a"(ret)
        :
        : SNESAPU_CALL_CLOBBERS);
    return static_cast<u32>(ret);
}

void call_GetSNESAPUContext(void *ctx) {
    const u64 arg0 = reinterpret_cast<u64>(ctx);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _GetSNESAPUContext\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
}

void call_SetSNESAPUContext(void *ctx) {
    const u64 arg0 = reinterpret_cast<u64>(ctx);
    asm volatile(
        "pushq %[arg0]\n\t"
        "call _SetSNESAPUContext\n\t"
        "add $8, %%rsp\n\t"
        :
        : [arg0] "m"(arg0)
        : "rax", SNESAPU_CALL_CLOBBERS);
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

bool parse_u32(const char *text, u32 &value) {
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(text, &end, 10);
    if (!text[0] || !end || *end != '\0') {
        return false;
    }
    value = static_cast<u32>(parsed);
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

void debug_log(const std::string &message) {
    if (!g_debug) {
        return;
    }
    std::cerr << message << std::endl;
}

struct RunResult {
    std::vector<u8> pcm;
    std::vector<u8> ctx;
    u16 pc = 0;
    u8 a = 0;
    u8 y = 0;
    u8 x = 0;
    u8 psw = 0;
    u8 sp = 0;
};

void apply_engine_options() {
    call_SetAPUOpt(MIX_INT, 2, 16, kDefaultRate, INT_GAUSS, kDefaultDSPOpts);
    call_SetAPUSmpClk(kDefaultSpeed);
    call_SetDSPPitch(kDefaultPitch);
    call_SetDSPStereo(kDefaultStereo);
    call_SetDSPEFBCT(kDefaultEfbct);
    call_SetDSPAmp(kAmp100);
}

RunResult run_cycles(
    const std::vector<u8> &initial_ctx,
    std::vector<u8> &scratch,
    u32 total_cycles,
    u32 chunk_cycles,
    u32 ctx_size) {
    debug_log("run_cycles: restore context");
    call_SetSNESAPUContext(const_cast<u8 *>(initial_ctx.data()));
    const u64 sample_cap = (static_cast<u64>(total_cycles) + 767ULL) / 768ULL + 32ULL;
    RunResult result;
    result.ctx.resize(ctx_size);
    scratch.resize(static_cast<size_t>(sample_cap) * 4ULL);

    u8 *cursor = scratch.data();
    u32 remaining = total_cycles;
    while (remaining) {
        const u32 step = std::min(remaining, chunk_cycles);
        if (g_debug) {
            std::cerr << "run_cycles: EmuAPU step=" << step << " remaining=" << remaining << std::endl;
        }
        void *end = call_EmuAPU(cursor, step, 0);
        cursor = static_cast<u8 *>(end);
        remaining -= step;
    }
    debug_log("run_cycles: capture context");
    result.pcm.assign(scratch.data(), cursor);
    debug_log("run_cycles: call_GetSNESAPUContext");
    call_GetSNESAPUContext(result.ctx.data());
    debug_log("run_cycles: call_GetSPCRegs");
    call_GetSPCRegs(&result.pc, &result.a, &result.y, &result.x, &result.psw, &result.sp);
    debug_log("run_cycles: done");
    return result;
}

size_t first_diff(const std::vector<u8> &lhs, const std::vector<u8> &rhs) {
    const size_t shared = std::min(lhs.size(), rhs.size());
    for (size_t i = 0; i < shared; ++i) {
        if (lhs[i] != rhs[i]) {
            return i;
        }
    }
    return lhs.size() == rhs.size() ? shared : shared;
}

bool compare_runs(
    const std::vector<u8> &initial_ctx,
    u32 total_cycles,
    u32 chunk_a,
    u32 chunk_b,
    u32 ctx_size,
    bool verbose) {
    std::vector<u8> scratch;
    const RunResult a = run_cycles(initial_ctx, scratch, total_cycles, chunk_a, ctx_size);
    const RunResult b = run_cycles(initial_ctx, scratch, total_cycles, chunk_b, ctx_size);

    const bool pcm_same = a.pcm == b.pcm;
    const bool ctx_same = a.ctx == b.ctx;
    const bool regs_same = a.pc == b.pc && a.a == b.a && a.y == b.y && a.x == b.x &&
        a.psw == b.psw && a.sp == b.sp;

    if (!verbose) {
        return pcm_same && ctx_same && regs_same;
    }

    const size_t pcm_diff = first_diff(a.pcm, b.pcm);
    const size_t ctx_diff = first_diff(a.ctx, b.ctx);

    std::cout << "cycles=" << total_cycles
              << " chunkA=" << chunk_a
              << " chunkB=" << chunk_b
              << " pcm_same=" << (pcm_same ? "yes" : "no")
              << " ctx_same=" << (ctx_same ? "yes" : "no")
              << " regs_same=" << (regs_same ? "yes" : "no")
              << "\n";

    std::cout << "pcm_bytes_a=" << a.pcm.size()
              << " pcm_bytes_b=" << b.pcm.size()
              << " first_pcm_diff=" << pcm_diff
              << "\n";

    std::cout << "ctx_size=" << ctx_size
              << " first_ctx_diff=" << ctx_diff
              << "\n";

    std::cout << "regs_a pc=" << a.pc
              << " a=" << static_cast<unsigned>(a.a)
              << " y=" << static_cast<unsigned>(a.y)
              << " x=" << static_cast<unsigned>(a.x)
              << " psw=" << static_cast<unsigned>(a.psw)
              << " sp=" << static_cast<unsigned>(a.sp)
              << "\n";
    std::cout << "regs_b pc=" << b.pc
              << " a=" << static_cast<unsigned>(b.a)
              << " y=" << static_cast<unsigned>(b.y)
              << " x=" << static_cast<unsigned>(b.x)
              << " psw=" << static_cast<unsigned>(b.psw)
              << " sp=" << static_cast<unsigned>(b.sp)
              << "\n";

    return pcm_same && ctx_same && regs_same;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 5 && argc != 6) {
        std::cerr << "usage: spcdiag <file.spc> <chunkA_cycles> <chunkB_cycles> <max_cycles> [step_cycles]\n";
        return 1;
    }

    const std::string spc_path = argv[1];
    u32 chunk_a = 0;
    u32 chunk_b = 0;
    u32 max_cycles = 0;
    u32 step_cycles = 1;
    if (!parse_u32(argv[2], chunk_a) || !parse_u32(argv[3], chunk_b) ||
        !parse_u32(argv[4], max_cycles) || (argc == 6 && !parse_u32(argv[5], step_cycles)) ||
        !chunk_a || !chunk_b || !max_cycles || !step_cycles) {
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

    g_debug = std::getenv("SPCDIAG_DEBUG") != nullptr;
    debug_log("main: init engine");
    call_InitAPU(1);
    debug_log("main: load SPC");
    call_LoadSPCFile(spc.data());
    debug_log("main: apply engine options");
    apply_engine_options();
    debug_log("main: get context size");
    const u32 ctx_size = call_GetSNESAPUContextSize();
    if (!ctx_size) {
        std::cerr << "GetSNESAPUContextSize returned 0\n";
        return 1;
    }
    if (g_debug) {
        std::cerr << "main: ctx_size=" << ctx_size << std::endl;
    }
    std::vector<u8> initial_ctx(ctx_size);
    debug_log("main: snapshot initial context");
    call_GetSNESAPUContext(initial_ctx.data());

    u32 first_bad = 0;
    u32 previous = 0;
    for (u32 total = step_cycles; total <= max_cycles; total += step_cycles) {
        if (!compare_runs(initial_ctx, total, chunk_a, chunk_b, ctx_size, false)) {
            first_bad = total;
            break;
        }
        previous = total;
    }

    if (!first_bad) {
        std::cout << "no divergence up to " << max_cycles << " cycles\n";
        return 0;
    }

    std::cout << "first divergence at or before " << first_bad << " cycles";
    if (previous) {
        std::cout << " (previous clean " << previous << ")";
    }
    std::cout << "\n";

    compare_runs(initial_ctx, first_bad, chunk_a, chunk_b, ctx_size, true);
    return 0;
}
