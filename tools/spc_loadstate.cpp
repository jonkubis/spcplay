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
constexpr u64 kFnvOffset = 14695981039346656037ULL;
constexpr u64 kFnvPrime = 1099511628211ULL;

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

u64 fnv1a(const void *data, size_t size) {
    const auto *bytes = static_cast<const u8 *>(data);
    u64 hash = kFnvOffset;
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= kFnvPrime;
    }
    return hash;
}

u32 float_bits(f32 value) {
    u32 bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
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

void print_bytes(const char *name, const void *data, size_t size) {
    const auto *bytes = static_cast<const u8 *>(data);
    std::cout << name << "_bytes=";
    for (size_t i = 0; i < size; ++i) {
        if (i != 0) {
            std::cout << (i % 16 == 0 ? "\n" : " ");
            if (i % 16 == 0) {
                std::cout << name << "_bytes=";
            }
        }
        std::cout << std::hex << std::setfill('0') << std::setw(2)
                  << static_cast<unsigned>(bytes[i]);
    }
    std::cout << std::dec << std::setfill(' ') << "\n";
}

void print_voice_fields(const Voice *voices) {
    for (int i = 0; i < 8; ++i) {
        const Voice &v = voices[i];
        std::cout << "voice" << i
                  << " vAdsr=0x" << std::hex << std::setfill('0') << std::setw(4) << v.vAdsr
                  << " vGain=0x" << std::setw(2) << static_cast<unsigned>(v.vGain)
                  << " vRsv=0x" << std::setw(2) << static_cast<unsigned>(v.vRsv)
                  << " mFlg=0x" << std::setw(2) << static_cast<unsigned>(v.mFlg)
                  << " eMode=0x" << std::setw(2) << static_cast<unsigned>(v.eMode)
                  << " eRIdx=0x" << std::setw(2) << static_cast<unsigned>(v.eRIdx)
                  << " eRate=0x" << std::setw(8) << v.eRate
                  << " eCnt=0x" << std::setw(8) << v.eCnt
                  << " eVal=0x" << std::setw(8) << v.eVal
                  << " eAdj=0x" << std::setw(8) << static_cast<u32>(v.eAdj)
                  << " eDest=0x" << std::setw(8) << v.eDest
                  << " mTgtL=0x" << std::setw(8) << float_bits(v.mTgtL)
                  << " mTgtR=0x" << std::setw(8) << float_bits(v.mTgtR)
                  << " mChnL=0x" << std::setw(8) << static_cast<u32>(v.mChnL)
                  << " mChnR=0x" << std::setw(8) << static_cast<u32>(v.mChnR)
                  << " mRate=0x" << std::setw(8) << v.mRate
                  << " mDec=0x" << std::setw(4) << v.mDec
                  << " mSrc=0x" << std::setw(2) << static_cast<unsigned>(v.mSrc)
                  << " mKOn=0x" << std::setw(2) << static_cast<unsigned>(v.mKOn)
                  << " mOrgP=0x" << std::setw(8) << v.mOrgP
                  << " mOut=0x" << std::setw(8) << static_cast<u32>(v.mOut)
                  << std::dec << std::setfill(' ') << "\n";
    }
}

void print_usage(const char *argv0) {
    std::cerr << "usage: " << argv0 << " <input.spc>\n";
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 2) {
        print_usage(argv[0]);
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

    if (!call_InitAPU(1)) {
        std::cerr << "InitAPU failed\n";
        return 1;
    }
    call_LoadSPCFile(spc.data());

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

    u16 pc = 0;
    u8 a = 0;
    u8 y = 0;
    u8 x = 0;
    u8 psw = 0;
    u8 sp_reg = 0;
    call_GetSPCRegs(&pc, &a, &y, &x, &psw, &sp_reg);

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
    print_hex64("dsp_fnv1a", dsp_regs ? fnv1a(dsp_regs, sizeof(DSPReg)) : 0);
    print_hex64("mix_fnv1a", voices ? fnv1a(voices, sizeof(Voice) * 8) : 0);
    print_hex32("v_mmax_l", v_mmax_l ? *v_mmax_l : 0);
    print_hex32("v_mmax_r", v_mmax_r ? *v_mmax_r : 0);

    if (std::getenv("SPC_LOADSTATE_DUMP_RAW")) {
        if (dsp_regs) {
            print_bytes("dsp", dsp_regs, sizeof(DSPReg));
        }
        if (voices) {
            print_bytes("mix", voices, sizeof(Voice) * 8);
        }
    }
    if (std::getenv("SPC_LOADSTATE_DUMP_FIELDS") && voices) {
        print_voice_fields(voices);
    }
    return 0;
}
