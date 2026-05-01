#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

#include "types.h"
#include "DSP.h"
#include "APU.h"
#include "SPC700.h"
#include "snesapu_call_bridge.h"

namespace {

constexpr size_t kSpcSize = 0x10200;
constexpr u32 kDefaultRate = 32000;
constexpr u32 kDefaultSpeed = 65536;
constexpr u32 kDefaultPitch = 32000;
constexpr u32 kDefaultStereo = 32768;
constexpr s32 kDefaultEfbct = 32768;
constexpr u32 kDefaultAmp = 65536;
constexpr u32 kDefaultDspOpts = DSP_ANALOG | DSP_ECHOFIR | DSP_FLOAT;
constexpr u32 kDefaultInterpolation = INT_GAUSS;
constexpr u64 kCyclesPerSecond = 24576000ULL;
constexpr u64 kFnvOffset = 14695981039346656037ULL;
constexpr u64 kFnvPrime = 1099511628211ULL;

bool g_trace_dsp_writes = false;
u32 g_trace_dsp_voice = 0;
DSPReg *g_trace_dsp_regs = nullptr;
Voice *g_trace_voices = nullptr;
u32 *g_trace_t64_count = nullptr;

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

bool parse_u32(const char *text, u32 &value) {
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(text, &end, 0);
    if (!text[0] || !end || *end != '\0') {
        return false;
    }
    value = static_cast<u32>(parsed);
    return true;
}

bool env_enabled(const char *name, bool default_value) {
    const char *value = std::getenv(name);
    if (!value) {
        return default_value;
    }
    return value[0] && value[0] != '0';
}

u32 env_u32(const char *name, u32 default_value) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return default_value;
    }
    u32 parsed = 0;
    return parse_u32(value, parsed) ? parsed : default_value;
}

u64 fnv1a(const void *data, size_t size) {
    const auto *bytes = static_cast<const u8 *>(data);
    u64 hash = kFnvOffset;
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= kFnvPrime;
    }
    return hash;
}

void dsp_write_trace_callback(volatile u8 *reg, volatile u8 val) {
    if (!g_trace_dsp_writes || !g_trace_dsp_regs || !g_trace_voices) {
        return;
    }
    auto *base = g_trace_dsp_regs->reg;
    auto *ptr = const_cast<u8 *>(reg);
    if (ptr < base || ptr >= base + 128) {
        return;
    }
    const u32 reg_index = static_cast<u32>(ptr - base);
    if (reg_index != 0x4c && reg_index != 0x5c && reg_index != 0x7c) {
        return;
    }
    const u8 voice_index = static_cast<u8>(std::min<u32>(g_trace_dsp_voice, 7));
    const Voice &voice = g_trace_voices[voice_index];
    std::cout << "dsp_write"
              << " t64=0x" << std::hex << std::setfill('0') << std::setw(8)
              << (g_trace_t64_count ? *g_trace_t64_count : 0)
              << " reg=0x" << std::setw(2) << reg_index
              << " old=0x" << std::setw(2) << static_cast<unsigned>(*reg)
              << " val=0x" << std::setw(2) << static_cast<unsigned>(val)
              << " voice=" << std::dec << static_cast<unsigned>(voice_index + 1)
              << " eMode=0x" << std::hex << std::setw(2) << static_cast<unsigned>(voice.eMode)
              << " eCnt=0x" << std::setw(8) << voice.eCnt
              << " eVal=0x" << std::setw(8) << voice.eVal
              << " mFlg=0x" << std::setw(2) << static_cast<unsigned>(voice.mFlg)
              << std::dec << std::setfill(' ') << "\n";
}

void print_hex64(const char *name, u64 value) {
    std::cout << name << "=0x"
              << std::hex << std::setfill('0') << std::setw(16) << value
              << std::dec << std::setfill(' ') << "\n";
}

void print_hex32(const char *name, u32 value) {
    std::cout << name << "=0x"
              << std::hex << std::setfill('0') << std::setw(8) << value
              << std::dec << std::setfill(' ') << "\n";
}

void print_hex16(const char *name, u16 value) {
    std::cout << name << "=0x"
              << std::hex << std::setfill('0') << std::setw(4) << value
              << std::dec << std::setfill(' ') << "\n";
}

void print_hex8(const char *name, u8 value) {
    std::cout << name << "=0x"
              << std::hex << std::setfill('0') << std::setw(2)
              << static_cast<unsigned>(value)
              << std::dec << std::setfill(' ') << "\n";
}

void apply_engine_options() {
    if (!env_enabled("SPC_EXECSTATE_APPLY_OPTIONS", true)) {
        return;
    }

    const u32 interpolation = env_u32("SPC_EXECSTATE_INTERPOLATION", kDefaultInterpolation);
    const u32 dsp_options = env_u32("SPC_EXECSTATE_DSP_OPTIONS", kDefaultDspOpts);
    call_SetAPUOpt(MIX_INT, 2, 16, kDefaultRate, interpolation, dsp_options);
    call_SetAPUSmpClk(kDefaultSpeed);
    call_SetDSPPitch(kDefaultPitch);
    call_SetDSPStereo(kDefaultStereo);
    call_SetDSPEFBCT(kDefaultEfbct);
    call_SetDSPAmp(kDefaultAmp);
}

void apply_voice_flags_from_env() {
    const u32 mute_mask = env_u32("SPC_EXECSTATE_MUTE_MASK", 0) & 0xffu;
    for (u32 i = 0; i < 8; ++i) {
        mix[i].mFlg &= static_cast<u8>(~MFLG_USER);
        if ((mute_mask & (1u << i)) != 0) {
            mix[i].mFlg |= MFLG_MUTE;
        }
    }
}

void print_voice_trace_line(
    const char *phase,
    u32 chunk_index,
    u32 done,
    const Voice *voices,
    const DSPReg *dsp_regs,
    const u32 *t64_count,
    u8 voice_index) {
    if (!voices || !dsp_regs || voice_index >= 8) {
        return;
    }

    const Voice &voice = voices[voice_index];
    const DSPVoice &dsp_voice = dsp_regs->voice[voice_index];
    std::cout << "voice_trace"
              << " phase=" << phase
              << " chunk=" << chunk_index
              << " done=" << done
              << " t64=0x" << std::hex << std::setfill('0') << std::setw(8)
              << (t64_count ? *t64_count : 0)
              << " voice=" << std::dec << static_cast<unsigned>(voice_index + 1)
              << " pitch=0x" << std::hex << std::setw(4) << dsp_voice.pitch
              << " srcn=0x" << std::setw(2) << static_cast<unsigned>(dsp_voice.srcn)
              << " envx=0x" << std::setw(2) << static_cast<unsigned>(static_cast<u8>(dsp_voice.envx))
              << " outx=0x" << std::setw(2) << static_cast<unsigned>(static_cast<u8>(dsp_voice.outx))
              << " sIdx=0x" << std::setw(8) << voice.sIdx
              << " bCur=0x" << std::setw(4) << static_cast<unsigned>(voice.bCur)
              << " bHdr=0x" << std::setw(2) << static_cast<unsigned>(voice.bHdr)
              << " mRate=0x" << std::setw(8) << voice.mRate
              << " mDec=0x" << std::setw(4) << voice.mDec
              << " mOrgP=0x" << std::setw(8) << voice.mOrgP
              << " mSrc=0x" << std::setw(2) << static_cast<unsigned>(voice.mSrc)
              << " mKOn=0x" << std::setw(2) << static_cast<unsigned>(voice.mKOn)
              << " mFlg=0x" << std::setw(2) << static_cast<unsigned>(voice.mFlg)
              << " eMode=0x" << std::setw(2) << static_cast<unsigned>(voice.eMode)
              << " eCnt=0x" << std::setw(8) << voice.eCnt
              << " eVal=0x" << std::setw(8) << voice.eVal
              << " sP1=0x" << std::setw(4) << static_cast<u16>(voice.sP1)
              << " sP2=0x" << std::setw(4) << static_cast<u16>(voice.sP2)
              << " mOut=0x" << std::setw(8) << static_cast<u32>(voice.mOut)
              << std::dec << std::setfill(' ') << "\n";
}

void print_usage(const char *argv0) {
    std::cerr << "usage: " << argv0 << " <input.spc> <spc|cycles|samples> <total> <chunk>\n"
              << "       set SPC_EXECSTATE_APPLY_OPTIONS=0 to skip spc2wav-style options\n";
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 5) {
        print_usage(argv[0]);
        return 1;
    }

    const std::string mode = argv[2];
    const bool direct_spc_mode = mode == "spc";
    const bool sample_mode = mode == "samples";
    const bool cycle_mode = mode == "cycles";
    if (!direct_spc_mode && !sample_mode && !cycle_mode) {
        print_usage(argv[0]);
        return 1;
    }

    u32 total = 0;
    u32 chunk = 0;
    if (!parse_u32(argv[3], total) || !parse_u32(argv[4], chunk) || total == 0 || chunk == 0) {
        std::cerr << "invalid total/chunk\n";
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

    const bool cpu_only = env_enabled("SPC_EXECSTATE_CPU_ONLY", false);

    if (!call_InitAPU(1)) {
        std::cerr << "InitAPU failed\n";
        return 1;
    }
    call_LoadSPCFile(spc.data());
    apply_engine_options();
    apply_voice_flags_from_env();
    g_trace_dsp_writes = env_enabled("SPC_EXECSTATE_TRACE_DSP_WRITES", false);
    g_trace_dsp_voice = env_u32("SPC_EXECSTATE_TRACE_VOICE", 1);
    if (g_trace_dsp_voice > 0) {
        --g_trace_dsp_voice;
    }
    if (g_trace_dsp_writes) {
        u8 *ignored_ram = nullptr;
        call_GetAPUData(
            &ignored_ram,
            nullptr,
            nullptr,
            &g_trace_t64_count,
            &g_trace_dsp_regs,
            &g_trace_voices,
            nullptr,
            nullptr);
        call_SetDSPDbg(dsp_write_trace_callback);
    }

    const u32 trace_steps = env_u32("SPC_EXECSTATE_TRACE_STEPS", 0);
    if (trace_steps != 0) {
        if (!direct_spc_mode) {
            std::cerr << "SPC_EXECSTATE_TRACE_STEPS requires spc mode\n";
            return 1;
        }
        const u32 warmup = env_u32("SPC_EXECSTATE_TRACE_WARMUP", 0);
        if (warmup != 0) {
            call_EmuSPC(static_cast<s32>(warmup));
        }
        const u32 warmup_samples = env_u32("SPC_EXECSTATE_TRACE_WARMUP_SAMPLES", 0);
        if (warmup_samples != 0) {
            const u32 warmup_chunk = std::max<u32>(
                1, env_u32("SPC_EXECSTATE_TRACE_WARMUP_CHUNK", 3200));
            std::vector<u8> warmup_buffer(static_cast<size_t>(warmup_chunk) * 4);
            u32 done = 0;
            while (done < warmup_samples) {
                const u32 step = std::min(warmup_chunk, warmup_samples - done);
                call_EmuAPU(warmup_buffer.data(), step, 1);
                done += step;
            }
        }

        u8 *trace_ram = reinterpret_cast<u8 *>(pAPURAM);
        u32 *trace_t64 = nullptr;
        call_GetAPUData(&trace_ram, nullptr, nullptr, &trace_t64, nullptr, nullptr, nullptr, nullptr);

        std::cout << "trace_warmup=0x"
                  << std::hex << std::setfill('0') << std::setw(8) << warmup
                  << std::dec << std::setfill(' ')
                  << " warmup_samples=" << warmup_samples << "\n";
        for (u32 i = 0; i < trace_steps; ++i) {
            u16 pc = 0;
            u8 a = 0;
            u8 y = 0;
            u8 x = 0;
            u8 psw = 0;
            u8 sp_reg = 0;
            call_GetSPCRegs(&pc, &a, &y, &x, &psw, &sp_reg);
            const u8 opcode = trace_ram ? trace_ram[pc] : 0;
            std::cout << "trace"
                      << " step=" << i
                      << " pc=0x" << std::hex << std::setfill('0') << std::setw(4) << pc
                      << " op=0x" << std::setw(2) << static_cast<unsigned>(opcode)
                      << " a=0x" << std::setw(2) << static_cast<unsigned>(a)
                      << " y=0x" << std::setw(2) << static_cast<unsigned>(y)
                      << " x=0x" << std::setw(2) << static_cast<unsigned>(x)
                      << " psw=0x" << std::setw(2) << static_cast<unsigned>(psw)
                      << " sp=0x" << std::setw(2) << static_cast<unsigned>(sp_reg)
                      << " t64=0x" << std::setw(8) << (trace_t64 ? *trace_t64 : 0)
                      << std::dec << std::setfill(' ') << "\n";
            call_EmuSPC(1);
        }
        return 0;
    }

    const u64 estimated_samples = direct_spc_mode
        ? 0
        : sample_mode
        ? total
        : ((static_cast<u64>(total) * kDefaultRate) / kCyclesPerSecond) + 32ULL;
    std::vector<u8> pcm(static_cast<size_t>(estimated_samples) * 4ULL + 4096ULL);
    u8 *cursor = pcm.data();

    const u32 trace_voice_env = env_u32("SPC_EXECSTATE_TRACE_VOICE", 0);
    const bool trace_voice_enabled = trace_voice_env >= 1 && trace_voice_env <= 8;
    const u8 trace_voice_index = static_cast<u8>(trace_voice_env - 1);
    const u32 trace_voice_every = std::max<u32>(1, env_u32("SPC_EXECSTATE_TRACE_VOICE_EVERY", 1));
    DSPReg *trace_dsp_regs = nullptr;
    Voice *trace_voices = nullptr;
    u32 *trace_t64_count = nullptr;
    if (trace_voice_enabled) {
        u8 *ignored_ram = nullptr;
        call_GetAPUData(
            &ignored_ram,
            nullptr,
            nullptr,
            &trace_t64_count,
            &trace_dsp_regs,
            &trace_voices,
            nullptr,
            nullptr);
        print_voice_trace_line(
            "start",
            0,
            0,
            trace_voices,
            trace_dsp_regs,
            trace_t64_count,
            trace_voice_index);
    }

    u32 remaining = total;
    u32 done = 0;
    u32 chunk_index = 0;
    while (remaining != 0) {
        const u32 step = std::min(remaining, chunk);
        if (direct_spc_mode) {
            u32 step_remaining = step;
            while (step_remaining != 0) {
                const s32 returned = call_EmuSPC(static_cast<s32>(step_remaining));
                const u32 returned_cycles = returned > 0 ? static_cast<u32>(returned) : 0;
                if (returned_cycles >= step_remaining) {
                    break;
                }
                step_remaining = returned_cycles;
            }
        } else {
            void *end = call_EmuAPU(cursor, step, sample_mode ? 1 : 0);
            auto *end_bytes = static_cast<u8 *>(end);
            if (!end_bytes || end_bytes < cursor || end_bytes > pcm.data() + pcm.size()) {
                std::cerr << "EmuAPU returned an invalid buffer pointer\n";
                return 1;
            }
            cursor = end_bytes;
        }
        remaining -= step;
        done += step;
        ++chunk_index;
        if (trace_voice_enabled && chunk_index % trace_voice_every == 0) {
            print_voice_trace_line(
                "step",
                chunk_index,
                done,
                trace_voices,
                trace_dsp_regs,
                trace_t64_count,
                trace_voice_index);
        }
    }
    const size_t pcm_size = static_cast<size_t>(cursor - pcm.data());

    u8 *ram = nullptr;
    u8 *xram = nullptr;
    u8 *out_port = nullptr;
    u32 *t64_count = nullptr;
    DSPReg *dsp_regs = nullptr;
    Voice *voices = nullptr;
    u32 *v_mmax_l = nullptr;
    u32 *v_mmax_r = nullptr;
    call_GetAPUData(&ram, &xram, &out_port, &t64_count, &dsp_regs, &voices, &v_mmax_l, &v_mmax_r);
    if (!ram && pAPURAM) {
        ram = reinterpret_cast<u8 *>(pAPURAM);
    }
    if (const char *dump_ram_path = std::getenv("SPC_EXECSTATE_DUMP_RAM")) {
        if (ram) {
            std::ofstream dump(dump_ram_path, std::ios::binary);
            dump.write(reinterpret_cast<const char *>(ram), APURAMSIZE);
        }
    }

    u16 pc = 0;
    u8 a = 0;
    u8 y = 0;
    u8 x = 0;
    u8 psw = 0;
    u8 sp_reg = 0;
    call_GetSPCRegs(&pc, &a, &y, &x, &psw, &sp_reg);

    std::cout << "mode=" << mode << "\n";
    print_hex32("total", total);
    print_hex32("chunk", chunk);
    if (!cpu_only) {
        print_hex32("pcm_bytes", static_cast<u32>(pcm_size));
        print_hex64("pcm_fnv1a", fnv1a(pcm.data(), pcm_size));
    }
    print_hex16("pc", pc);
    print_hex8("a", a);
    print_hex8("y", y);
    print_hex8("x", x);
    print_hex8("psw", psw);
    print_hex8("sp", sp_reg);
    print_hex32("t64", t64_count ? *t64_count : 0);
    print_hex64("apuram_fnv1a", ram ? fnv1a(ram, APURAMSIZE) : 0);
    print_hex64("xram_fnv1a", xram ? fnv1a(xram, 64) : 0);
    print_hex64("outport_fnv1a", out_port ? fnv1a(out_port, 4) : 0);
    if (!cpu_only) {
        print_hex64("dsp_fnv1a", dsp_regs ? fnv1a(dsp_regs, sizeof(DSPReg)) : 0);
        print_hex64("mix_fnv1a", voices ? fnv1a(voices, sizeof(Voice) * 8) : 0);
        print_hex32("v_mmax_l", v_mmax_l ? *v_mmax_l : 0);
        print_hex32("v_mmax_r", v_mmax_r ? *v_mmax_r : 0);
    }
    return 0;
}
