#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <utility>

#include "../snesapu.dll/types.h"
#include "../snesapu.dll/DSP.h"
#include "../snesapu.dll/APU.h"
#include "../snesapu.dll/SPC700.h"

extern "C" {
extern u8 inPortCp[4];
extern u8 outPortCp[4];
extern u8 flushPort[4];
extern u8 portMod;
extern u8 tControl;
extern u8 outPort[4];
extern u32 cycLeft;
}

extern "C" void apply_fade_volume();
extern "C" void apply_fade_volume_at(u32 now_t64);

namespace {

constexpr u32 kApuClock = 24576000;
constexpr s32 kSpcCycle = 24;
constexpr u32 kT64Cycles = 384;
constexpr u32 kT8Cycles = kT64Cycles * 8;
constexpr u32 kDefaultRate = 32000;
constexpr u32 kDefaultSpeed = 65536;
constexpr u32 kDefaultPitch = 32000;
constexpr u32 kDefaultAmp = 65536;
constexpr u32 kDefaultStereo = 32768;
constexpr u32 kDefaultEfbct = 65536;
constexpr u32 kDefaultChannels = 2;
constexpr s32 kDefaultBits = 16;
constexpr u32 kApuVersion = 0x00020000;
constexpr u32 kApuCompatibleVersion = 0x00011000;
constexpr u8 kKonDelay = 19;
constexpr u8 kKonCheckKoff = 13;
constexpr u8 kKonSaveEnvelope = kKonDelay;
constexpr u32 kEnvelopeMax = (128u << 4) - 1;
constexpr u32 kEnvelopeDirectAdj = (128u << 4) - 1;
constexpr u32 kEnvelopeLinearAdj = (128u << 4) / 64;
constexpr u32 kEnvelopeBentAdj = (128u << 4) / 256;
constexpr u32 kEnvelopeReleaseAdj = (128u << 4) / 256;
constexpr u32 kEnvelopeDecayBase = (128u << 4) / 8;
constexpr u32 kEnvelopeBentDest = (128u << 4) * 3 / 4;
constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double kAafCutoff1 = 8038.1284389846;
constexpr double kAafCutoff2 = 16176.421441299;
constexpr u8 kEnvType = 0x01;
constexpr u8 kEnvDir = 0x02;
constexpr u8 kEnvDest = 0x04;
constexpr u8 kEnvAdsr = 0x08;
constexpr u8 kEnvIdle = 0x80;
constexpr u8 kEnvDec = 0x00;
constexpr u8 kEnvExp = 0x01;
constexpr u8 kEnvInc = 0x02;
constexpr u8 kEnvBent = 0x06;
constexpr u8 kEnvDirect = 0x07;
constexpr u8 kEnvRel = 0x08;
constexpr u8 kEnvSustain = 0x09;
constexpr u8 kEnvAttack = 0x0a;
constexpr u8 kEnvDecay = 0x0d;
constexpr u32 kApuOptions =
    (24u << 24) | SA_DEBUG | SA_DSPINTEG | SA_VMETERM | SA_VMETERC |
    SA_SNESINT | SA_STEREO | SA_HALFC | SA_IPLW | SA_INTBK;
constexpr size_t kEchoBufferSamples = 192000 * 240 / 1000;
constexpr std::array<u32, 32> kEnvelopeFreq {
    0, 2048, 1536, 1280, 1024, 768, 640, 512,
    384, 320, 256, 192, 160, 128, 96, 80,
    64, 48, 40, 32, 24, 20, 16, 12,
    10, 8, 6, 5, 4, 3, 2, 1,
};
constexpr std::array<s16, 512> kGaussBase {
        0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,
       16,    16,    16,    16,    16,    16,    16,    16,    16,    16,    16,    32,    32,    32,    32,    32,
       32,    32,    48,    48,    48,    48,    48,    64,    64,    64,    64,    64,    80,    80,    80,    80,
       96,    96,    96,    96,   112,   112,   112,   128,   128,   128,   144,   144,   144,   160,   160,   160,
      176,   176,   176,   192,   192,   208,   208,   224,   224,   240,   240,   240,   256,   256,   272,   272,
      288,   304,   304,   320,   320,   336,   336,   352,   368,   368,   384,   384,   400,   416,   432,   432,
      448,   464,   464,   480,   496,   512,   512,   528,   544,   560,   576,   576,   592,   608,   624,   640,
      656,   672,   688,   704,   720,   736,   752,   768,   784,   800,   816,   832,   848,   864,   880,   896,
      928,   944,   960,   976,   992,  1024,  1040,  1056,  1072,  1104,  1120,  1136,  1168,  1184,  1216,  1232,
     1248,  1280,  1296,  1328,  1344,  1376,  1392,  1424,  1440,  1472,  1504,  1520,  1552,  1584,  1600,  1632,
     1664,  1696,  1712,  1744,  1776,  1808,  1840,  1872,  1888,  1920,  1952,  1984,  2016,  2048,  2080,  2112,
     2144,  2192,  2224,  2256,  2288,  2320,  2352,  2400,  2432,  2464,  2496,  2544,  2576,  2608,  2656,  2688,
     2736,  2768,  2800,  2848,  2880,  2928,  2976,  3008,  3056,  3088,  3136,  3184,  3216,  3264,  3312,  3360,
     3392,  3440,  3488,  3536,  3584,  3632,  3680,  3728,  3776,  3824,  3872,  3920,  3968,  4016,  4064,  4112,
     4160,  4208,  4272,  4320,  4368,  4416,  4480,  4528,  4576,  4640,  4688,  4752,  4800,  4864,  4912,  4976,
     5024,  5088,  5136,  5200,  5248,  5312,  5376,  5424,  5488,  5552,  5616,  5664,  5728,  5792,  5856,  5920,
     5984,  6048,  6096,  6160,  6224,  6288,  6352,  6416,  6480,  6560,  6624,  6688,  6752,  6816,  6880,  6944,
     7024,  7088,  7152,  7216,  7296,  7360,  7424,  7504,  7568,  7632,  7712,  7776,  7856,  7920,  7984,  8064,
     8128,  8208,  8272,  8352,  8432,  8496,  8576,  8640,  8720,  8800,  8864,  8944,  9008,  9088,  9168,  9232,
     9312,  9392,  9472,  9536,  9616,  9696,  9776,  9840,  9920, 10000, 10080, 10160, 10240, 10304, 10384, 10464,
    10544, 10624, 10704, 10784, 10848, 10928, 11008, 11088, 11168, 11248, 11328, 11408, 11488, 11568, 11648, 11712,
    11792, 11872, 11952, 12032, 12112, 12192, 12272, 12352, 12432, 12512, 12592, 12672, 12752, 12832, 12896, 12976,
    13056, 13136, 13216, 13296, 13376, 13456, 13536, 13616, 13680, 13760, 13840, 13920, 14000, 14080, 14144, 14224,
    14304, 14384, 14464, 14528, 14608, 14688, 14768, 14832, 14912, 14992, 15056, 15136, 15216, 15280, 15360, 15440,
    15504, 15584, 15648, 15728, 15808, 15872, 15952, 16016, 16080, 16160, 16224, 16304, 16368, 16432, 16512, 16576,
    16640, 16720, 16784, 16848, 16912, 16976, 17056, 17120, 17184, 17248, 17312, 17376, 17440, 17504, 17568, 17632,
    17696, 17744, 17808, 17872, 17936, 18000, 18048, 18112, 18176, 18224, 18288, 18336, 18400, 18448, 18512, 18560,
    18624, 18672, 18720, 18784, 18832, 18880, 18928, 18976, 19040, 19088, 19136, 19184, 19232, 19280, 19312, 19360,
    19408, 19456, 19504, 19536, 19584, 19632, 19664, 19712, 19744, 19792, 19824, 19856, 19904, 19936, 19968, 20016,
    20048, 20080, 20112, 20144, 20176, 20208, 20240, 20272, 20304, 20320, 20352, 20384, 20400, 20432, 20464, 20480,
    20512, 20528, 20544, 20576, 20592, 20608, 20640, 20656, 20672, 20688, 20704, 20720, 20736, 20752, 20752, 20768,
    20784, 20800, 20800, 20816, 20832, 20832, 20848, 20848, 20848, 20864, 20864, 20864, 20864, 20864, 20880, 20880
};

alignas(65536) std::array<u8, APURAMSIZE> g_apu_ram {};
alignas(16) std::array<u8, SCR700SIZE> g_script_ram {};
std::array<uptr, 16> g_spc_reg_buffer {};
std::array<u8, 32> g_version_string {
    '2', '.', '0', '0', '.', '0', '0', '\0',
};
std::array<float, kEchoBufferSamples> g_echo_left {};
std::array<float, kEchoBufferSamples> g_echo_right {};
std::array<float, 8> g_fir_left {};
std::array<float, 8> g_fir_right {};
std::array<std::array<s16, 4>, 256> g_cubic_table {};
std::array<std::array<s16, 8>, 256> g_sinc_table {};
std::array<std::array<s16, 4>, 256> g_gauss4_table {};
size_t g_echo_len = 1;
size_t g_echo_pending_len = 1;
size_t g_echo_remaining = 1;
size_t g_echo_mem_pos = 0;
size_t g_echo_mem_len = 1;
s32 g_echo_mem_dec = 0;
size_t g_fir_pos = 0;
bool g_interpolation_tables_ready = false;

u16 g_pc = 0;
u8 g_a = 0;
u8 g_y = 0;
u8 g_x = 0;
u8 g_psw = 0;
u8 g_sp = 0;
u32 g_t64_remaining = kT64Cycles - 1;
u32 g_t8_remaining = kT8Cycles - 1;
u8 g_t0_step = 0xff;
u8 g_t1_step = 0xff;
u8 g_t2_step = 0xff;

u32 g_speed = kDefaultSpeed;
u32 g_pitch = kDefaultPitch;
u32 g_stereo = kDefaultStereo;
float g_volume_separation = 0.0f;
u8 g_surround_off = 0;
s32 g_efbct = static_cast<s32>(kDefaultEfbct);
float g_echo_feedback = 0.0f;
float g_echo_feedback_crosstalk = 0.0f;
u32 g_amp = kDefaultAmp;
u32 g_volume = kDefaultAmp;
float g_main_target_left = 0.0f;
float g_main_target_right = 0.0f;
float g_echo_target_left = 0.0f;
float g_echo_target_right = 0.0f;
float g_main_current_left = 0.0f;
float g_main_current_right = 0.0f;
float g_echo_current_left = 0.0f;
float g_echo_current_right = 0.0f;
u32 g_song_len = 0xffffffffu;
u32 g_fade_len = 0;
DSPDebug *g_dsp_debug = nullptr;
SPCDebug *g_spc_debug = nullptr;
u32 g_spc_debug_opts = 0;
CBFUNC g_callback = nullptr;
u32 g_callback_mask = 0;

u8 rawChn = static_cast<u8>(kDefaultChannels);
u8 rawBits = static_cast<u8>(kDefaultBits);
u8 rawByte = 4;
u32 rawRate = kDefaultRate;
u32 dspOpts = 0;
u8 dspMix = MIX_INT;
u8 dspChn = static_cast<u8>(kDefaultChannels);
u8 dspSize = static_cast<u8>(kDefaultBits);
u8 dspInter = INT_GAUSS;
u8 voiceMix = 0xff;
u8 dspMute = 0;
u8 disFlag = 0;
u8 dspPMod = 0;
u8 dspNoise = 0;
u8 dspNoiseF = 0;
u8 konRsv = 0;
u8 koffRsv = 0;
std::array<u8, 8> g_kon_skip_decrement {};
u8 g_deferred_key_on_mask = 0;
bool g_defer_key_on_reset = false;
u8 *g_auto_out = nullptr;
bool g_auto_out_active = false;
u32 g_auto_out_left = 0;
u32 g_auto_out_count = 0;
u32 g_auto_out_dec = 0;
u32 g_auto_out_rate = 0;
float g_debug_last_mix_left = 0.0f;
float g_debug_last_mix_right = 0.0f;
std::array<u32, 32> g_rate_table {};
u32 g_pitch_adj = 0x100000;
u32 g_noise_rate = 0;
u32 g_forced_noise_rate = 0;
u32 g_noise_acc = 0;
u32 g_forced_noise_acc = 0;
s32 g_noise_sample = 0;
s32 g_forced_noise_sample = 0;
u32 g_noise_seed = 1;
float g_aaf1_a1 = 0.0f;
float g_aaf1_b0 = 1.0f;
float g_aaf1_b1 = 1.0f;
float g_aaf2_a1 = 0.0f;
float g_aaf2_b0 = 1.0f;
float g_aaf2_b1 = 1.0f;
float g_aaf_state_left = 0.0f;
float g_aaf_state_right = 0.0f;

u32 bytes_per_frame() {
    const s32 bits = static_cast<s8>(rawBits);
    const u32 abs_bits = bits < 0 ? static_cast<u32>(-bits) : static_cast<u32>(bits);
    const u32 bytes_per_sample = std::max<u32>(1, abs_bits / 8);
    return std::max<u32>(1, rawChn) * bytes_per_sample;
}

u32 samples_for_cycles(u32 cycles) {
    return static_cast<u32>((static_cast<u64>(cycles) * rawRate) / kApuClock);
}

u32 t64_for_samples(u32 samples) {
    if (rawRate == 0) {
        return 0;
    }
    return static_cast<u32>((static_cast<u64>(samples) * 64000u) / rawRate);
}

void run_spc_for_apu_cycles(u32 cycles) {
    const s64 adjusted = static_cast<s64>(cycles) + static_cast<s32>(cycLeft);
    if (adjusted <= 0) {
        cycLeft = static_cast<u32>(static_cast<s32>(adjusted));
        return;
    }

    const s32 remaining = EmuSPC(static_cast<s32>(adjusted));
    cycLeft = static_cast<u32>(remaining);
}

void reset_echo_buffers() {
    std::fill(g_echo_left.begin(), g_echo_left.end(), 0);
    std::fill(g_echo_right.begin(), g_echo_right.end(), 0);
    std::fill(g_fir_left.begin(), g_fir_left.end(), 0);
    std::fill(g_fir_right.begin(), g_fir_right.end(), 0);
}

void reset_echo_state() {
    g_echo_len = 1;
    g_echo_pending_len = 1;
    g_echo_remaining = 1;
    g_echo_mem_pos = 0;
    g_echo_mem_dec = 0;
    g_fir_pos = 0;
    reset_echo_buffers();
}

void restart_echo_buffers_at_current_delay() {
    g_echo_len = g_echo_pending_len;
    g_echo_remaining = g_echo_len;
    g_echo_mem_pos = 0;
    g_echo_mem_dec = 0;
    g_fir_pos = 0;
    reset_echo_buffers();
}

void rebuild_analog_filter() {
    const long double rate = static_cast<long double>(rawRate == 0 ? kDefaultRate : rawRate);
    auto configure = [rate](double cutoff, float &a1, float &b0, float &b1) {
        const long double cutoff_f = static_cast<long double>(static_cast<float>(cutoff));
        const long double wdt = 2.0L * static_cast<long double>(kPi) * cutoff_f / rate;
        a1 = static_cast<float>((wdt - 2.0L) / (wdt + 2.0L));
        b0 = static_cast<float>(wdt / (wdt + 2.0L));
        b1 = b0;
    };
    configure(kAafCutoff1, g_aaf1_a1, g_aaf1_b0, g_aaf1_b1);
    configure(kAafCutoff2, g_aaf2_a1, g_aaf2_b0, g_aaf2_b1);
}

void update_echo_length() {
    const u32 delay = static_cast<u32>(dsp.edl) & 0x0f;
    g_echo_mem_len = std::max<size_t>(1, static_cast<size_t>(delay == 0 ? 1u : delay * 512u));
    g_echo_mem_pos = 0;
    g_echo_mem_dec = 0;
    u64 samples = delay == 0 ? 1 : static_cast<u64>(delay) * 512u;
    samples = samples * (rawRate == 0 ? kDefaultRate : rawRate) / kDefaultRate;
    g_echo_pending_len = std::max<size_t>(1, std::min<size_t>(kEchoBufferSamples, static_cast<size_t>(samples)));
}

s32 clamp_echo_sample(s64 value) {
    if (value > 32767) {
        return 32767;
    }
    if (value < -32768) {
        return -32768;
    }
    return static_cast<s32>(value);
}

s32 round_shift_signed(s64 value, u8 bits) {
    const s64 half = 1ll << (bits - 1);
    const u64 magnitude = value < 0
        ? static_cast<u64>(-(value + 1)) + 1u
        : static_cast<u64>(value);
    const s64 rounded = static_cast<s64>((magnitude + static_cast<u64>(half)) >> bits);
    return static_cast<s32>(value < 0 ? -rounded : rounded);
}

float float_from_bits(s32 bits) {
    float value = 0.0f;
    const u32 raw = static_cast<u32>(bits);
    std::memcpy(&value, &raw, sizeof(value));
    return value;
}

s32 bits_from_float(float value) {
    u32 raw = 0;
    std::memcpy(&raw, &value, sizeof(raw));
    return static_cast<s32>(raw);
}

float f32(float value) {
    return value;
}

s32 round_float_to_i32(float value) {
    return static_cast<s32>(std::lrint(value));
}

double fir_cut16(double value) {
    const s32 rounded = static_cast<s32>(std::lrint(value));
    if (rounded >= -32768 && rounded <= 32767) {
        return value;
    }
    return static_cast<double>(static_cast<s32>(static_cast<s16>(rounded)) & ~1);
}

double fir_clamp16(double value) {
    const s32 rounded = static_cast<s32>(std::lrint(value));
    if (rounded >= -32768 && rounded <= 32767) {
        return value;
    }
    return rounded < 0 ? -32768.0 : 32766.0;
}

double fir_clamp17(double value) {
    const s32 rounded = static_cast<s32>(std::lrint(value));
    if (rounded >= -65536 && rounded <= 65535) {
        return value;
    }
    return rounded < 0 ? -65536.0 : 65535.0;
}

s16 fistp_word(float value) {
    const long rounded = std::lrint(value);
    if (rounded < -32768 || rounded > 32767) {
        return static_cast<s16>(0x8000);
    }
    return static_cast<s16>(rounded);
}

void advance_echo_memory_cursor() {
    g_echo_mem_pos = (g_echo_mem_pos + 1) % g_echo_mem_len;
}

void write_echo_memory(float left, float right) {
    s32 dec = g_echo_mem_dec - static_cast<s32>(kDefaultRate);
    if (dec >= 0) {
        g_echo_mem_dec = dec;
        return;
    }

    u16 packed_left = static_cast<u16>(fistp_word(left));
    u16 packed_right = static_cast<u16>(fistp_word(right));
    packed_left = static_cast<u16>(packed_left & 0xfffeu);
    packed_right = static_cast<u16>(packed_right & 0xfffeu);

    const u32 dsp_rate = rawRate == 0 ? kDefaultRate : std::min<u32>(rawRate, kDefaultRate);
    do {
        const u32 address = (static_cast<u32>(dsp.esa) << 8) + static_cast<u32>(g_echo_mem_pos * 4);
        g_apu_ram[(address + 0) & 0xffffu] = static_cast<u8>(packed_left & 0xff);
        g_apu_ram[(address + 1) & 0xffffu] = static_cast<u8>(packed_left >> 8);
        g_apu_ram[(address + 2) & 0xffffu] = static_cast<u8>(packed_right & 0xff);
        g_apu_ram[(address + 3) & 0xffffu] = static_cast<u8>(packed_right >> 8);
        advance_echo_memory_cursor();
        dec += static_cast<s32>(dsp_rate);
    } while (dec < 0);

    g_echo_mem_dec = dec;
}

size_t current_echo_index() {
    if (g_echo_remaining == 0 || g_echo_remaining > g_echo_len) {
        g_echo_remaining = g_echo_len;
    }
    return g_echo_len - g_echo_remaining;
}

void advance_echo_delay_cursor() {
    if (g_echo_remaining > 0) {
        --g_echo_remaining;
    }
    if (g_echo_remaining == 0) {
        g_echo_len = g_echo_pending_len;
        g_echo_remaining = g_echo_len;
    }
}

float clamp_output_fixed(float value) {
    constexpr float kOutputLimit = 2147418112.0f;  // 32767 << 16
    if (value > kOutputLimit) {
        return kOutputLimit;
    }
    if (value < -kOutputLimit) {
        return -kOutputLimit;
    }
    return value;
}

void update_dsp_x_registers() {
    for (u8 i = 0; i < 8; ++i) {
        dsp.voice[i].envx = static_cast<s8>(std::min<u32>(0x7f, mix[i].eVal >> 4));
        dsp.voice[i].outx = static_cast<s8>(
            static_cast<u8>((static_cast<u32>(mix[i].mOut) >> 8) & 0xffu));
    }
}

s32 scale_master_sample(s32 sample, s8 volume) {
    const s64 volume_adjust = static_cast<s64>((static_cast<u64>(g_amp) * g_volume) >> 16);
    return round_shift_signed(
        static_cast<s64>(sample) * static_cast<s32>(volume) * volume_adjust,
        23);
}

float global_volume_adjustment() {
    return static_cast<float>((static_cast<u64>(g_amp) * g_volume) >> 16);
}

u32 snesapu_reciprocal_rate(u8 rate_index) {
    const u32 rate = g_rate_table[rate_index & 0x1f];
    if (rate == 0) {
        return 0;
    }
    const u64 dividend = (static_cast<u64>(0xffff) << 32) | 0xffffffffull;
    return static_cast<u32>(dividend / rate);
}

void update_noise_rate_from_flg() {
    const u8 index = static_cast<u8>(dsp.flg & 0x1f);
    g_noise_rate = index == 0 ? 0 : snesapu_reciprocal_rate(index);
}

void update_forced_noise_rate() {
    g_forced_noise_rate = snesapu_reciprocal_rate(31);
}

void reset_noise_state() {
    g_noise_rate = 0;
    g_noise_acc = 0;
    g_noise_sample = 0;
    g_noise_seed = 1;
    g_forced_noise_acc = 0;
    g_forced_noise_sample = 0;
    update_forced_noise_rate();
}

void reset_analog_filter_state() {
    g_aaf_state_left = 0.0f;
    g_aaf_state_right = 0.0f;
}

void set_nz_8(u8 value) {
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x02));
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if ((value & 0x80) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
}

void set_nz_16(u16 value) {
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x02));
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if ((value & 0x8000) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
}

void set_adc_flags(u8 lhs, u8 rhs, u8 carry, u16 result) {
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x40 | 0x08 | 0x02 | 0x01));
    const u8 value = static_cast<u8>(result & 0xff);
    if ((value & 0x80) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if (result > 0xff) {
        g_psw = static_cast<u8>(g_psw | 0x01);
    }
    if (((lhs & 0x0f) + (rhs & 0x0f) + carry) > 0x0f) {
        g_psw = static_cast<u8>(g_psw | 0x08);
    }
    if (((~(lhs ^ rhs) & (lhs ^ value)) & 0x80) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x40);
    }
}

void set_sbc_flags(u8 lhs, u8 rhs, u8 borrow, s16 result) {
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x40 | 0x08 | 0x02 | 0x01));
    const u8 value = static_cast<u8>(result & 0xff);
    if ((value & 0x80) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if (result >= 0) {
        g_psw = static_cast<u8>(g_psw | 0x01);
    }
    if ((static_cast<s16>((lhs & 0x0f) - (rhs & 0x0f) - borrow)) >= 0) {
        g_psw = static_cast<u8>(g_psw | 0x08);
    }
    if (((lhs ^ rhs) & (lhs ^ value) & 0x80) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x40);
    }
}

void set_addw_flags(u16 lhs, u16 rhs, u32 result) {
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x40 | 0x08 | 0x02 | 0x01));
    const u16 value = static_cast<u16>(result & 0xffff);
    if ((value & 0x8000) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if (result > 0xffff) {
        g_psw = static_cast<u8>(g_psw | 0x01);
    }
    if (((lhs & 0x000f) + (rhs & 0x000f)) > 0x000f) {
        g_psw = static_cast<u8>(g_psw | 0x08);
    }
    if (((~(lhs ^ rhs) & (lhs ^ value)) & 0x8000) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x40);
    }
}

void set_subw_flags(u16 lhs, u16 rhs, s32 result) {
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x40 | 0x08 | 0x02 | 0x01));
    const u16 value = static_cast<u16>(result & 0xffff);
    if ((value & 0x8000) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if (result >= 0) {
        g_psw = static_cast<u8>(g_psw | 0x01);
    }
    if (static_cast<s32>(lhs & 0x000f) - static_cast<s32>(rhs & 0x000f) >= 0) {
        g_psw = static_cast<u8>(g_psw | 0x08);
    }
    if (((lhs ^ rhs) & (lhs ^ value) & 0x8000) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x40);
    }
}

void set_cmp_flags(u8 lhs, u8 rhs) {
    const u8 value = static_cast<u8>(lhs - rhs);
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x02 | 0x01));
    if ((value & 0x80) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if (lhs >= rhs) {
        g_psw = static_cast<u8>(g_psw | 0x01);
    }
}

void set_cmpw_flags(u16 lhs, u16 rhs) {
    const u16 value = static_cast<u16>(lhs - rhs);
    g_psw = static_cast<u8>(g_psw & ~(0x80 | 0x02 | 0x01));
    if ((value & 0x8000) != 0) {
        g_psw = static_cast<u8>(g_psw | 0x80);
    }
    if (value == 0) {
        g_psw = static_cast<u8>(g_psw | 0x02);
    }
    if (lhs >= rhs) {
        g_psw = static_cast<u8>(g_psw | 0x01);
    }
}

u16 direct_page_base() {
    return (g_psw & 0x20) ? 0x0100 : 0x0000;
}

u16 direct_page_addr(u8 addr) {
    return static_cast<u16>(direct_page_base() + addr);
}

u16 direct_page_indexed_addr(u8 addr, u8 index) {
    return direct_page_addr(static_cast<u8>(addr + index));
}

u16 read_direct_word_wrapped(u8 addr) {
    const u16 dp_base = direct_page_base();
    const u8 low = g_apu_ram[static_cast<u16>(dp_base + addr)];
    const u8 high = g_apu_ram[static_cast<u16>(dp_base + static_cast<u8>(addr + 1))];
    return static_cast<u16>(low | (static_cast<u16>(high) << 8));
}

u8 timer_target_step(u16 addr) {
    return static_cast<u8>(g_apu_ram[addr] - 1);
}

void increment_timer_counter(u16 target_addr, u16 counter_addr, u8 &step) {
    if (step == 0) {
        step = timer_target_step(target_addr);
        g_apu_ram[counter_addr] = static_cast<u8>((g_apu_ram[counter_addr] + 1) & 0x0f);
    } else {
        step = static_cast<u8>(step - 1);
    }
}

void on_64khz_timer_pulse() {
    ++t64Cnt;
    if ((tControl & 0x04) != 0) {
        increment_timer_counter(0x00fcu, 0x00ffu, g_t2_step);
    }
}

void on_8khz_timer_pulse() {
    if ((tControl & 0x01) != 0) {
        increment_timer_counter(0x00fau, 0x00fdu, g_t0_step);
    }
    if ((tControl & 0x02) != 0) {
        increment_timer_counter(0x00fbu, 0x00feu, g_t1_step);
    }
}

void advance_timers(u32 cycles) {
    u32 remaining = cycles;
    while (remaining != 0) {
        const u32 next = std::min(g_t64_remaining, g_t8_remaining);
        if (remaining <= next) {
            g_t64_remaining -= remaining;
            g_t8_remaining -= remaining;
            break;
        }

        const u32 elapsed = next + 1;
        remaining -= elapsed;

        const bool pulse64 = g_t64_remaining == next;
        const bool pulse8 = g_t8_remaining == next;
        if (pulse64) {
            g_t64_remaining = kT64Cycles - 1;
            on_64khz_timer_pulse();
        } else {
            g_t64_remaining -= elapsed;
        }
        if (pulse8) {
            g_t8_remaining = kT8Cycles - 1;
            on_8khz_timer_pulse();
        } else {
            g_t8_remaining -= elapsed;
        }
    }
}

void reset_started_timers(u8 newly_enabled) {
    if ((newly_enabled & 0x01) != 0) {
        g_t0_step = timer_target_step(0x00fau);
        g_apu_ram[0x00fdu] = 0;
    }
    if ((newly_enabled & 0x02) != 0) {
        g_t1_step = timer_target_step(0x00fbu);
        g_apu_ram[0x00feu] = 0;
    }
    if ((newly_enabled & 0x04) != 0) {
        g_t2_step = timer_target_step(0x00fcu);
        g_apu_ram[0x00ffu] = 0;
    }
}

void handle_control_register_write(u8 value) {
    const u8 old_control = tControl;

    if ((value & 0x10) != 0) {
        g_apu_ram[0x00f4u] = 0;
        g_apu_ram[0x00f5u] = 0;
        inPortCp[0] = 0;
        inPortCp[1] = 0;
        flushPort[0] = 0;
        flushPort[1] = 0;
    }
    if ((value & 0x20) != 0) {
        g_apu_ram[0x00f6u] = 0;
        g_apu_ram[0x00f7u] = 0;
        inPortCp[2] = 0;
        inPortCp[3] = 0;
        flushPort[2] = 0;
        flushPort[3] = 0;
    }

    tControl = static_cast<u8>(value & 0x87);
    g_apu_ram[0x00f1u] = tControl;
    reset_started_timers(static_cast<u8>((~old_control) & tControl & 0x07));
}

void update_spc_reg_buffer() {
    g_spc_reg_buffer[0] = g_pc;
    g_spc_reg_buffer[1] = static_cast<uptr>(g_a) | (static_cast<uptr>(g_y) << 8);
    g_spc_reg_buffer[2] = g_x;
    g_spc_reg_buffer[3] = g_psw;
    g_spc_reg_buffer[4] = g_sp;
}

bool is_function_register(u16 addr) {
    return addr >= 0x00f0 && addr <= 0x00ff;
}

void refresh_dsp_data_register() {
    g_apu_ram[0x00f3u] = dsp.reg[g_apu_ram[0x00f2u] & 0x7f];
}

void set_envelope_rate(Voice &voice, u8 index);
void set_voice_pitch(u8 voice_index);
void reset_pitch_modulation_rates();
void set_voice_volume(u8 voice_index);
float ramp_channel_volume(s32 &current_bits, float target);
void update_global_volume_targets();
void snap_global_volumes_to_targets();
void process_key_off_reservations();
void advance_key_delays();
void update_echo_feedback();
void change_envelope_attack(Voice &voice, const DSPVoice &dsp_voice);
void change_envelope_gain(Voice &voice, const DSPVoice &dsp_voice);
void advance_envelope(u8 voice_index);
void handle_adsr_register_change(u8 voice_index);
void handle_gain_register_change(u8 voice_index);
void update_noise_rate_from_flg();
void reset_echo_buffers();
void render_dsp_samples(void *buffer, u32 samples);

void clear_auto_dsp() {
    g_auto_out = nullptr;
    g_auto_out_active = false;
    g_auto_out_left = 0;
    g_auto_out_count = 0;
    g_auto_out_dec = 0;
    g_auto_out_rate = 0;
}

void set_auto_dsp(void *buffer, u32 samples, u32 rate) {
    if (samples == 0 || rate == 0) {
        clear_auto_dsp();
        return;
    }

    g_auto_out_active = true;
    g_auto_out = static_cast<u8 *>(buffer);
    g_auto_out_left = samples;
    g_auto_out_count = t64Cnt >> 1;
    g_auto_out_dec = 0;
    g_auto_out_rate = static_cast<u32>((static_cast<u64>(rate) << 16) / kDefaultRate);
}

void catch_up_dsp() {
    if (!g_auto_out_active || g_auto_out_left == 0 || g_auto_out_rate == 0) {
        return;
    }

    const u32 current_count = t64Cnt >> 1;
    const u32 elapsed = current_count - g_auto_out_count;
    if (elapsed == 0) {
        return;
    }
    g_auto_out_count = current_count;

    const u64 sample_accum =
        static_cast<u64>(elapsed) * g_auto_out_rate + g_auto_out_dec;
    u32 samples = static_cast<u32>(sample_accum >> 16);
    g_auto_out_dec = static_cast<u32>(sample_accum & 0xffffu);
    process_key_off_reservations();
    if (samples != 0) {
        samples = std::min(samples, g_auto_out_left);

        render_dsp_samples(g_auto_out, samples);
        refresh_dsp_data_register();
        if (g_auto_out) {
            g_auto_out += static_cast<size_t>(samples) * bytes_per_frame();
        }
        g_auto_out_left -= samples;
    }
}

bool key_on_reset_can_defer() {
    return g_auto_out_active &&
        g_auto_out &&
        g_auto_out_left != 0 &&
        g_auto_out_rate == 0x10000 &&
        g_auto_out_dec == 0 &&
        g_auto_out_count == (t64Cnt >> 1);
}

u8 *finish_auto_dsp() {
    if (g_auto_out_active && g_auto_out_left != 0) {
        render_dsp_samples(g_auto_out, g_auto_out_left);
        if (g_auto_out) {
            g_auto_out += static_cast<size_t>(g_auto_out_left) * bytes_per_frame();
        }
        g_auto_out_left = 0;
    }
    u8 *end = g_auto_out;
    clear_auto_dsp();
    return end;
}

void reset_voice_for_key_on(u8 voice_index, u8 bit, bool skip_initial_decrement) {
    Voice &voice = mix[voice_index];
    voice.mFlg &= MFLG_USER;
    voice.mKOn = kKonDelay;
    g_kon_skip_decrement[voice_index] = skip_initial_decrement ? 1 : 0;
    voice.eVal = 0;
    voice.mOut = 0;
    dsp.voice[voice_index].envx = 0;
    dsp.voice[voice_index].outx = 0;
    dsp.endx = static_cast<u8>(dsp.endx & ~bit);
}

void save_key_on_envelope_snapshot(u8 voice_index) {
    Voice &voice = mix[voice_index];
    const DSPVoice &dsp_voice = dsp.voice[voice_index];
    voice.vAdsr = static_cast<u16>(
        dsp_voice.adsr[0] | (static_cast<u16>(dsp_voice.adsr[1]) << 8));
    voice.vGain = dsp_voice.gain;
    voice.vRsv = 0;
}

void schedule_key_on(u8 mask) {
    dsp.kon = mask;
    konRsv = mask;
    g_defer_key_on_reset = false;
}

void apply_deferred_key_on_resets() {
    const u8 mask = g_deferred_key_on_mask;
    if (mask == 0) {
        return;
    }
    g_deferred_key_on_mask = 0;
    for (u8 i = 0; i < 8; ++i) {
        const u8 bit = static_cast<u8>(1u << i);
        if ((mask & bit) != 0) {
            reset_voice_for_key_on(i, bit, true);
        }
    }
}

void process_key_off_reservations() {
    const u8 mask = koffRsv;
    if (mask == 0) {
        return;
    }
    koffRsv = 0;
    for (u8 i = 0; i < 8; ++i) {
        const u8 bit = static_cast<u8>(1u << i);
        if ((mask & bit) == 0) {
            continue;
        }
        Voice &voice = mix[i];
        if ((voiceMix & bit) != 0 && (voice.mFlg & MFLG_KOFF) == 0) {
            if ((voice.mFlg & MFLG_MUTE) == 0) {
                ramp_channel_volume(voice.mChnL, voice.mTgtL);
                ramp_channel_volume(voice.mChnR, voice.mTgtR);
            }
            const u32 old_counter_high = voice.eCnt >> 16;
            const bool apply_pending_envelope_tick =
                old_counter_high == 1 &&
                (voice.eMode & kEnvIdle) == 0;
            if (apply_pending_envelope_tick) {
                advance_envelope(i);
            }
            set_envelope_rate(voice, 31);
            voice.eCnt += 0x00010000u;
            voice.eAdj = static_cast<s32>(kEnvelopeReleaseAdj);
            voice.eDest = 0;
            voice.eMode = kEnvRel;
            voice.mFlg = static_cast<u8>(voice.mFlg | MFLG_KOFF);
            voice.vRsv = 0;
        }
        voice.mKOn = 0;
        g_kon_skip_decrement[i] = 0;
        g_deferred_key_on_mask = static_cast<u8>(g_deferred_key_on_mask & ~bit);
    }
}

void schedule_key_off(u8 mask) {
    dsp.kof = mask;
    koffRsv = mask;
    if ((t64Cnt & 1u) != 0) {
        process_key_off_reservations();
    }
}

void apply_dsp_register_write(u8 reg, u8 value, bool from_spc = false) {
    reg &= 0x7f;
    if (g_dsp_debug) {
        g_dsp_debug(&dsp.reg[reg], value);
    }
    if ((g_callback_mask & CBE_DSPREG) != 0 && g_callback) {
        value = static_cast<u8>(g_callback(CBE_DSPREG, reg, value, nullptr) & 0xffu);
    }
    if (reg != 0x4c && reg != 0x5c && reg != 0x7c && dsp.reg[reg] == value) {
        return;
    }

    const bool delayed_special_register = reg == 0x4c || reg == 0x5c || reg == 0x7c;
    if (from_spc && delayed_special_register) {
        catch_up_dsp();
        if (reg == 0x4c && value != 0) {
            g_defer_key_on_reset = key_on_reset_can_defer();
        }
    }

    dsp.reg[reg] = value;

    const u8 voice_index = static_cast<u8>(reg >> 4);
    if (voice_index < 8) {
        Voice &voice = mix[voice_index];
        const u8 inactive_mask = static_cast<u8>((~reg) & MFLG_OFF);
        if ((voice.mFlg & inactive_mask) != 0) {
            return;
        }
    }

    if (from_spc && !delayed_special_register) {
        catch_up_dsp();
    }

    switch (reg) {
        case 0x4c:
            schedule_key_on(value);
            break;
        case 0x5c:
            schedule_key_off(value);
            break;
        case 0x7c:
            dsp.endx = 0;
            break;
        case 0x0c:
        case 0x1c:
        case 0x2c:
        case 0x3c:
            update_global_volume_targets();
            break;
        case 0x2d:
            reset_pitch_modulation_rates();
            break;
        case 0x0d:
            update_echo_feedback();
            break;
        case 0x6c:
            if ((value & 0x80) != 0) {
                dsp.flg = static_cast<s8>((value & ~0x80u) | 0x60u);
                dsp.endx = 0;
                dsp.kon = 0;
                dsp.kof = 0;
                voiceMix = 0;
                for (u8 i = 0; i < 8; ++i) {
                    mix[i].mFlg = static_cast<u8>((mix[i].mFlg & MFLG_USER) | MFLG_OFF);
                }
            }
            update_noise_rate_from_flg();
            break;
        case 0x6d:
            update_echo_length();
            break;
        case 0x7d:
            update_echo_length();
            break;
        default:
            break;
    }

    const u8 voice_reg = static_cast<u8>(reg & 0x0f);
    if (voice_index >= 8) {
        return;
    }

    switch (voice_reg) {
        case 0x00:
        case 0x01:
            set_voice_volume(voice_index);
            break;
        case 0x02:
        case 0x03:
            set_voice_pitch(voice_index);
            break;
        case 0x05:
        case 0x06:
            handle_adsr_register_change(voice_index);
            break;
        case 0x07:
            handle_gain_register_change(voice_index);
            break;
        default:
            break;
    }
}

void write_apu_byte(u16 addr, u8 value) {
    g_apu_ram[addr] = value;

    if (!is_function_register(addr)) {
        return;
    }

    switch (static_cast<u8>(addr & 0x0f)) {
        case 1:
            handle_control_register_write(value);
            break;
        case 2:
            refresh_dsp_data_register();
            break;
        case 3:
            if ((g_spc_debug_opts & SPC_NODSP) != 0) {
                dsp.reg[g_apu_ram[0x00f2u] & 0x7fu] = value;
                break;
            }
            apply_dsp_register_write(g_apu_ram[0x00f2u], value, true);
            break;
        case 4:
        case 5:
        case 6:
        case 7: {
            const u8 port = static_cast<u8>((addr & 0x0f) - 4);
            outPort[port] = value;
            outPortCp[port] = value;
            g_apu_ram[addr] = inPortCp[port];
            break;
        }
        case 13:
        case 14:
        case 15:
            g_apu_ram[addr] = 0;
            break;
        default:
            break;
    }
}

u8 read_apu_byte(u16 addr) {
    const u8 value = g_apu_ram[addr];
    if (addr >= 0x00fdu && addr <= 0x00ffu) {
        g_apu_ram[addr] = 0;
    }
    return value;
}

void push_word(u16 value) {
    g_apu_ram[static_cast<u16>(0x0100u + g_sp)] = static_cast<u8>(value >> 8);
    g_sp = static_cast<u8>(g_sp - 1);
    g_apu_ram[static_cast<u16>(0x0100u + g_sp)] = static_cast<u8>(value & 0xff);
    g_sp = static_cast<u8>(g_sp - 1);
}

void push_byte(u8 value) {
    g_apu_ram[static_cast<u16>(0x0100u + g_sp)] = value;
    g_sp = static_cast<u8>(g_sp - 1);
}

u16 pop_word() {
    g_sp = static_cast<u8>(g_sp + 1);
    const u8 low = g_apu_ram[static_cast<u16>(0x0100u + g_sp)];
    g_sp = static_cast<u8>(g_sp + 1);
    const u8 high = g_apu_ram[static_cast<u16>(0x0100u + g_sp)];
    return static_cast<u16>(low | (static_cast<u16>(high) << 8));
}

u8 pop_byte() {
    g_sp = static_cast<u8>(g_sp + 1);
    return g_apu_ram[static_cast<u16>(0x0100u + g_sp)];
}

s32 sanitized_bits(u32 bits) {
    const s32 signed_bits = static_cast<s32>(bits);
    switch (signed_bits) {
        case 8:
        case 16:
        case 24:
        case 32:
        case -32:
            return signed_bits;
        default:
            return kDefaultBits;
    }
}

void rebuild_rate_table() {
    const u32 dsp_rate = rawRate == 0 ? kDefaultRate : rawRate;
    for (size_t i = 0; i < g_rate_table.size(); ++i) {
        if (kEnvelopeFreq[i] == 0) {
            g_rate_table[i] = 0;
            continue;
        }
        u32 rate = static_cast<u32>(
            (static_cast<u64>(kEnvelopeFreq[i]) << 16) * dsp_rate / kDefaultRate);
        g_rate_table[i] = std::max<u32>(rate, 0x10000u);
    }
}

void rebuild_pitch_adjustment() {
    const u32 dsp_rate = rawRate == 0 ? kDefaultRate : rawRate;
    g_pitch_adj = static_cast<u32>((static_cast<u64>(g_pitch) << 20) / dsp_rate);
}

void set_envelope_rate(Voice &voice, u8 index) {
    voice.eRIdx = index;
    voice.eRate = g_rate_table[index & 0x1f];
    voice.eCnt = voice.eRate;
}

u32 direct_envelope_value(u8 level) {
    return (static_cast<u32>(level) << 4) + (static_cast<u32>(level) >> 3);
}

void change_envelope_sustain(Voice &voice, const DSPVoice &dsp_voice);

void change_envelope_decay(Voice &voice, const DSPVoice &dsp_voice) {
    const u32 destination = static_cast<u32>(((dsp_voice.adsr[1] >> 5) + 1) * kEnvelopeDecayBase - 1);

    if (voice.eMode == kEnvDecay && voice.eVal < destination) {
        voice.eDest = 0;
    } else {
        if (voice.eVal <= destination) {
            change_envelope_sustain(voice, dsp_voice);
            return;
        }
        voice.eAdj = 0;
        voice.eMode = kEnvDecay;
        voice.eDest = destination;
    }

    const u8 index = static_cast<u8>(((dsp_voice.adsr[0] & 0x70) >> 3) + 0x10);
    if (voice.eRIdx != index) {
        set_envelope_rate(voice, index);
    }
}

void change_envelope_attack(Voice &voice, const DSPVoice &dsp_voice) {
    if (voice.eVal >= kEnvelopeMax) {
        change_envelope_decay(voice, dsp_voice);
        return;
    }

    voice.eMode = kEnvAttack;
    voice.eDest = kEnvelopeMax;

    const u8 index = static_cast<u8>(((dsp_voice.adsr[0] & 0x0f) * 2) + 1);
    voice.eAdj = index == 0x1f ? static_cast<s32>(kEnvelopeDirectAdj) : static_cast<s32>(kEnvelopeLinearAdj);
    if (voice.eRIdx != index) {
        set_envelope_rate(voice, index);
    }
}

void change_envelope_sustain(Voice &voice, const DSPVoice &dsp_voice) {
    voice.eAdj = 0;
    voice.eDest = 0;

    const u8 index = static_cast<u8>(dsp_voice.adsr[1] & 0x1f);
    u8 idle = kEnvIdle;
    if (index != 0 && voice.eVal > 0) {
        idle = 0;
        if (voice.eRIdx != index) {
            set_envelope_rate(voice, index);
        }
    }
    voice.eMode = static_cast<u8>(idle | kEnvSustain);
}

void change_envelope_gain(Voice &voice, const DSPVoice &dsp_voice) {
    const u8 gain = dsp_voice.gain;
    if ((gain & 0x80) == 0) {
        voice.eAdj = static_cast<s32>(kEnvelopeDirectAdj);
        voice.eDest = direct_envelope_value(static_cast<u8>(gain & 0x7f));
        set_envelope_rate(voice, 31);
        voice.eMode = static_cast<u8>((voice.eMode & 0x70) | kEnvDirect);
        return;
    }

    const u8 index = static_cast<u8>(gain & 0x1f);
    u8 mode = static_cast<u8>(voice.eMode & 0x70);
    if (index == 0) {
        mode = static_cast<u8>(mode | kEnvIdle);
    } else if (voice.eRIdx != index) {
        set_envelope_rate(voice, index);
    }

    switch (gain & 0x60) {
        case 0x00:
            voice.eAdj = static_cast<s32>(kEnvelopeLinearAdj);
            voice.eDest = 0;
            voice.eMode = static_cast<u8>(mode | kEnvDec);
            break;
        case 0x20:
            voice.eAdj = 0;
            voice.eDest = 0;
            voice.eMode = static_cast<u8>(mode | kEnvExp);
            break;
        case 0x40:
            voice.eAdj = static_cast<s32>(kEnvelopeLinearAdj);
            voice.eDest = kEnvelopeMax;
            voice.eMode = static_cast<u8>(mode | kEnvInc);
            break;
        default:
            voice.eAdj = static_cast<s32>(kEnvelopeLinearAdj);
            voice.eDest = kEnvelopeBentDest;
            voice.eMode = static_cast<u8>(mode | kEnvBent);
            break;
    }
}

void change_current_adsr_mode(Voice &voice, const DSPVoice &dsp_voice) {
    switch (voice.eMode & 0x0f) {
        case kEnvAttack:
            change_envelope_attack(voice, dsp_voice);
            break;
        case kEnvDecay:
            change_envelope_decay(voice, dsp_voice);
            break;
        case kEnvSustain:
            change_envelope_sustain(voice, dsp_voice);
            break;
        default:
            break;
    }
}

void handle_gain_register_change(u8 voice_index) {
    Voice &voice = mix[voice_index];
    const DSPVoice &dsp_voice = dsp.voice[voice_index];

    if ((voice.mFlg & MFLG_KOFF) != 0) {
        return;
    }
    if (voice.mKOn != 0) {
        voice.vRsv = static_cast<u8>(voice.vRsv | 0x02);
        return;
    }
    if ((dsp_voice.adsr[0] & 0x80) != 0) {
        return;
    }
    change_envelope_gain(voice, dsp_voice);
}

void handle_adsr_register_change(u8 voice_index) {
    Voice &voice = mix[voice_index];
    const DSPVoice &dsp_voice = dsp.voice[voice_index];

    if ((voice.mFlg & MFLG_KOFF) != 0) {
        return;
    }
    if (voice.mKOn != 0) {
        voice.vRsv = static_cast<u8>(voice.vRsv | 0x01);
        return;
    }

    const bool was_adsr = (voice.eMode & kEnvAdsr) != 0;
    const bool wants_adsr = (dsp_voice.adsr[0] & 0x80) != 0;
    if (!was_adsr && !wants_adsr) {
        return;
    }
    if (!wants_adsr) {
        voice.eMode = static_cast<u8>(voice.eMode << 4);
        handle_gain_register_change(voice_index);
        return;
    }
    if (!was_adsr) {
        voice.eMode = static_cast<u8>((voice.eMode >> 4) | kEnvAdsr);
    }
    change_current_adsr_mode(voice, dsp_voice);
}

void start_envelope(u8 voice_index) {
    Voice &voice = mix[voice_index];
    DSPVoice &dsp_voice = dsp.voice[voice_index];

    voice.eVal = 0;
    voice.mOut = 0;
    voice.eRIdx = 0;
    voice.eRate = g_rate_table[0];
    voice.eCnt = voice.eRate;
    dsp_voice.envx = 0;
    dsp_voice.outx = 0;
    voice.eMode = static_cast<u8>(kEnvAttack << 4);

    if ((dsp_voice.adsr[0] & 0x80) != 0) {
        change_envelope_attack(voice, dsp_voice);
    } else {
        change_envelope_gain(voice, dsp_voice);
    }
}

bool envelope_counter_elapsed(Voice &voice) {
    const u16 next_high = static_cast<u16>((voice.eCnt >> 16) - 1);
    voice.eCnt = (voice.eCnt & 0x0000ffffu) | (static_cast<u32>(next_high) << 16);
    if (next_high != 0) {
        return false;
    }
    voice.eCnt += voice.eRate;
    return true;
}

void finish_zero_envelope(u8 voice_index) {
    Voice &voice = mix[voice_index];
    voice.eMode = static_cast<u8>((voice.eMode & ~0x70) | (kEnvSustain << 4) | kEnvIdle);
    if ((voice.mFlg & MFLG_KOFF) != 0) {
        voice.mFlg = static_cast<u8>((voice.mFlg | MFLG_OFF) & ~MFLG_KOFF);
        voiceMix = static_cast<u8>(voiceMix & ~(1u << voice_index));
    }
}

void envelope_reached_destination(u8 voice_index, u8 previous_mode) {
    Voice &voice = mix[voice_index];
    DSPVoice &dsp_voice = dsp.voice[voice_index];

    if ((previous_mode & kEnvAdsr) != 0) {
        if ((dsp_voice.adsr[0] & 0x80) == 0) {
            return;
        }
        voice.vRsv = 0;
        if ((previous_mode & kEnvDest) != 0) {
            change_envelope_sustain(voice, dsp_voice);
        } else {
            change_envelope_decay(voice, dsp_voice);
        }
        return;
    }

    voice.eMode = static_cast<u8>(voice.eMode | kEnvIdle);
    if ((previous_mode & kEnvDest) != 0 && voice.eDest != kEnvelopeMax) {
        voice.eMode = static_cast<u8>(voice.eMode & ~kEnvIdle);
        voice.eAdj = static_cast<s32>(kEnvelopeBentAdj);
        voice.eDest = kEnvelopeMax;
    }
}

void apply_pending_envelope_register_change(u8 voice_index) {
    Voice &voice = mix[voice_index];
    DSPVoice &dsp_voice = dsp.voice[voice_index];
    const u8 pending = voice.vRsv;
    if ((pending & 0x01) != 0) {
        voice.vRsv = 0;
        handle_adsr_register_change(voice_index);
    } else if ((pending & 0x02) != 0) {
        voice.vRsv = 0;
        handle_gain_register_change(voice_index);
    }
}

void catch_key_on_load(u8 mask) {
    dsp.kon = mask;
    konRsv = 0;

    for (u8 i = 0; i < 8; ++i) {
        const u8 voice_bit = static_cast<u8>(1u << i);
        if ((mask & voice_bit) == 0) {
            continue;
        }

        Voice &voice = mix[i];
        voice.mFlg &= MFLG_USER;
        voice.mKOn = kKonDelay;
        voice.eVal = 0;
        voice.mOut = 0;
        dsp.voice[i].envx = 0;
        dsp.voice[i].outx = 0;
        dsp.endx = static_cast<u8>(dsp.endx & ~voice_bit);
    }
}

s16 clamp_s16(s32 value) {
    if (value > 32767) {
        return 32767;
    }
    if (value < -32768) {
        return -32768;
    }
    return static_cast<s16>(value);
}

s16 clamp_table_s16(long value) {
    return static_cast<s16>(std::clamp<long>(value, -32768, 32767));
}

void build_interpolation_tables() {
    if (g_interpolation_tables_ready) {
        return;
    }

    for (size_t i = 0; i < 256; ++i) {
        const double x = static_cast<double>(i) / 256.0;
        const double x2 = x * x;
        const double x3 = x2 * x;
        g_cubic_table[i][0] = clamp_table_s16(std::lrint((-0.5 * x + x2 - 0.5 * x3) * 32767.0));
        g_cubic_table[i][1] = clamp_table_s16(std::lrint((1.0 - 2.5 * x2 + 1.5 * x3) * 32767.0));
        g_cubic_table[i][2] = clamp_table_s16(std::lrint((0.5 * x + 2.0 * x2 - 1.5 * x3) * 32767.0));
        g_cubic_table[i][3] = clamp_table_s16(std::lrint((-0.5 * x2 + 0.5 * x3) * 32767.0));
    }

    g_sinc_table[0].fill(0);
    g_sinc_table[0][3] = 32767;
    for (size_t row = 1; row < 256; ++row) {
        s32 position = -768 - static_cast<s32>(row);
        for (size_t tap = 0; tap < 8; ++tap) {
            const double sinc_x = (static_cast<double>(position) / 256.0) * kPi;
            const double sinc = std::sin(sinc_x) / sinc_x;
            const double window =
                (1.0 + std::cos((static_cast<double>(position) / 1024.0) * kPi)) * 0.5;
            g_sinc_table[row][tap] = clamp_table_s16(std::lrint(sinc * window * 32768.0));
            position += 256;
        }
    }

    constexpr double gauss_scale = 20534.298825777156115789949213172;
    constexpr double gauss_domain = 512.0 / kPi;
    for (size_t row = 0; row < 256; ++row) {
        double position = -512.0 + static_cast<double>(row);
        for (int tap = 3; tap >= 0; --tap) {
            const double normalized = position / gauss_domain;
            const double coefficient = gauss_scale * std::exp(-(normalized * normalized) * 0.5);
            g_gauss4_table[row][static_cast<size_t>(tap)] =
                clamp_table_s16(std::lrint(coefficient));
            position += 256.0;
        }
    }

    g_interpolation_tables_ready = true;
}

u32 absolute_s32(s32 value) {
    return value < 0 ? static_cast<u32>(-value) : static_cast<u32>(value);
}

s32 arithmetic_shift_right(s32 value, u8 bits) {
    return value >> bits;
}

s32 brr_delta(u8 range, u8 nibble) {
    const s32 signed_nibble = (nibble & 0x08) ? static_cast<s32>(nibble) - 16 : nibble;
    s32 value = 0;
    if (range <= 12) {
        value = signed_nibble << range;
    } else {
        value = signed_nibble < 0 ? -4096 : 0;
    }
    return value & ~1;
}

s16 brr_clip_sample(s32 value) {
    const s32 probe = value + 65536;
    if ((probe >> 17) == 0) {
        return static_cast<s16>(value);
    }
    return value < 0 ? 0 : -2;
}

s16 brr_filtered_sample(u8 filter, s32 delta, s16 prev1, s16 prev2) {
    s32 sample = delta;
    switch (filter) {
        case 1:
            sample += prev1 + 2 * arithmetic_shift_right(-prev1, 5);
            break;
        case 2:
            sample += -prev2 + 2 * arithmetic_shift_right(prev2, 5);
            sample += 2 * prev1 + 2 * arithmetic_shift_right(-3 * prev1, 6);
            break;
        case 3:
            sample += -prev2 + 2 * arithmetic_shift_right(3 * prev2, 5);
            sample += 2 * prev1 + 2 * arithmetic_shift_right(-13 * prev1, 7);
            break;
        default:
            break;
    }
    return brr_clip_sample(sample);
}

u16 source_directory_entry(u8 source, bool loop) {
    const u16 dir = static_cast<u16>(dsp.dir) << 8;
    const u8 mapped_source = scr700chg[source];
    const u16 entry = static_cast<u16>(
        dir + static_cast<u16>(mapped_source) * 4u + (loop ? 2u : 0u));
    return static_cast<u16>(g_apu_ram[entry] | (static_cast<u16>(g_apu_ram[static_cast<u16>(entry + 1)]) << 8));
}

void decode_brr_block(u8 voice_index) {
    Voice &voice = mix[voice_index];
    const u16 block = static_cast<u16>(voice.bCur);
    const u8 header = g_apu_ram[block];
    voice.bHdr = header;

    const u8 range = static_cast<u8>(header >> 4);
    const u8 filter = static_cast<u8>((header >> 2) & 0x03);
    s16 prev1 = voice.sP1;
    s16 prev2 = voice.sP2;

    for (u8 i = 0; i < 8; ++i) {
        const u8 packed = g_apu_ram[static_cast<u16>(block + 1 + i)];
        const u8 high = static_cast<u8>(packed >> 4);
        const u8 low = static_cast<u8>(packed & 0x0f);

        const s16 sample0 = brr_filtered_sample(filter, brr_delta(range, high), prev1, prev2);
        voice.sBuf[i * 2] = sample0;
        prev2 = prev1;
        prev1 = sample0;

        const s16 sample1 = brr_filtered_sample(filter, brr_delta(range, low), prev1, prev2);
        voice.sBuf[i * 2 + 1] = sample1;
        prev2 = prev1;
        prev1 = sample1;
    }

    voice.sP1 = prev1;
    voice.sP2 = prev2;
}

void copy_previous_block_tail(Voice &voice) {
    for (u8 i = 0; i < 8; ++i) {
        voice.sBufP[i] = voice.sBuf[i + 8];
    }
}

u32 limited_register_pitch(u32 pitch) {
    if ((dspOpts & DSP_NOPLMT) == 0) {
        pitch &= 0x3fff;
    }
    return pitch & 0xffffu;
}

u32 pitch_rate_for_source(u32 pitch, u8 source) {
    const u32 adjusted_pitch = static_cast<u32>(pitch + scr700det[source]);
    const u64 adjusted = static_cast<u64>(adjusted_pitch) * g_pitch_adj;
    return static_cast<u32>((adjusted >> 16) + ((adjusted & 0xffffu) != 0 ? 1u : 0u));
}

void set_voice_pitch(u8 voice_index) {
    Voice &voice = mix[voice_index];
    const DSPVoice &dsp_voice = dsp.voice[voice_index];
    const u32 pitch = limited_register_pitch(dsp_voice.pitch);
    voice.mOrgP = pitch;
    voice.mRate = pitch_rate_for_source(pitch, voice.mSrc);
}

void reset_pitch_modulation_rates() {
    for (u8 i = 0; i < 8; ++i) {
        Voice &voice = mix[i];
        voice.mRate = pitch_rate_for_source(voice.mOrgP, voice.mSrc);
    }
}

s32 surround_adjusted_volume(u8 volume) {
    const s8 signed_volume = static_cast<s8>(volume);
    if ((g_surround_off & 0x80) == 0 || signed_volume >= 0) {
        return signed_volume;
    }
    return signed_volume == -128 ? 127 : -signed_volume;
}

std::pair<float, float> separated_voice_targets(u8 left_volume, u8 right_volume) {
    if ((dspOpts & DSP_REVERSE) != 0) {
        std::swap(left_volume, right_volume);
    }

    const s32 left = surround_adjusted_volume(left_volume);
    const s32 right = surround_adjusted_volume(right_volume);
    const float left_scaled = static_cast<float>(left) / 128.0f;
    const float right_scaled = static_cast<float>(right) / 128.0f;

    if (left == right || g_volume_separation == 0.0f) {
        return {left_scaled, right_scaled};
    }

    const float volume = std::sqrt(left_scaled * left_scaled + right_scaled * right_scaled);
    if (volume == 0.0f) {
        return {left_scaled, right_scaled};
    }

    float pan = (std::fabs(right_scaled) / volume);
    pan = pan * pan - 0.5f;

    float pan_delta = pan;
    if (g_volume_separation > 0.0f) {
        pan_delta = (pan < 0.0f ? -0.5f : 0.5f) - pan;
    }
    pan = std::clamp(pan + pan_delta * g_volume_separation, -0.5f, 0.5f);

    float target_right = std::sqrt(std::max(0.0f, pan + 0.5f)) * volume;
    float target_left = std::sqrt(std::max(0.0f, 0.5f - pan)) * volume;
    if (right < 0) {
        target_right = -target_right;
    }
    if (left < 0) {
        target_left = -target_left;
    }
    return {target_left, target_right};
}

void set_voice_volume(u8 voice_index) {
    Voice &voice = mix[voice_index];
    const DSPVoice &dsp_voice = dsp.voice[voice_index];
    const auto [target_left, target_right] =
        separated_voice_targets(dsp_voice.volL, dsp_voice.volR);
    voice.mTgtL = target_left;
    voice.mTgtR = target_right;
}

void snap_voice_volume_to_target(u8 voice_index) {
    Voice &voice = mix[voice_index];
    voice.mChnL = bits_from_float(voice.mTgtL);
    voice.mChnR = bits_from_float(voice.mTgtR);
}

void update_stereo_state() {
    const s32 signed_separation = static_cast<s32>(g_stereo) - static_cast<s32>(kDefaultStereo);
    g_volume_separation = static_cast<float>(signed_separation) / static_cast<float>(kDefaultStereo);
    const bool mono_output = rawChn == 1 || dspChn == 1;
    g_surround_off = ((dspOpts & DSP_NOSURND) != 0 || mono_output) ? 0x80 : 0x00;
}

void snap_all_voice_volumes_to_targets() {
    update_stereo_state();
    for (u8 i = 0; i < 8; ++i) {
        set_voice_volume(i);
        snap_voice_volume_to_target(i);
    }
}

float ramp_channel_volume(s32 &current_bits, float target) {
    float current = float_from_bits(current_bits);
    if (current == target) {
        return current;
    }

    const float rate = rawRate == 0 ? static_cast<float>(kDefaultRate) : static_cast<float>(rawRate);
    const float step = 32000.0f / rate / 256.0f;
    if (current < target) {
        current = std::min(current + step, target);
    } else {
        current = std::max(current - step, target);
    }
    current_bits = bits_from_float(current);
    return current;
}

float current_channel_volume(s32 &current_bits, float target, bool keying_off) {
    if (keying_off) {
        return float_from_bits(current_bits);
    }
    return ramp_channel_volume(current_bits, target);
}

s32 surround_inverted_volume(s32 volume) {
    return volume == -128 ? 127 : -volume;
}

float global_volume_target(u8 volume, bool right_channel) {
    s32 adjusted = surround_adjusted_volume(volume);
    const bool mono_output = rawChn == 1 || dspChn == 1;
    if (right_channel && (dspOpts & DSP_SURND) != 0 && !mono_output) {
        adjusted = surround_inverted_volume(adjusted);
    }

    return static_cast<float>(adjusted) * global_volume_adjustment() / 128.0f;
}

void update_global_volume_targets() {
    g_main_target_left = global_volume_target(dsp.mvolL, false);
    g_main_target_right = global_volume_target(dsp.mvolR, true);
    g_echo_target_left = global_volume_target(dsp.evolL, false);
    g_echo_target_right = global_volume_target(dsp.evolR, true);
}

void snap_global_volumes_to_targets() {
    update_global_volume_targets();
    g_main_current_left = g_main_target_left;
    g_main_current_right = g_main_target_right;
    g_echo_current_left = g_echo_target_left;
    g_echo_current_right = g_echo_target_right;
}

void update_echo_feedback() {
    const float feedback = static_cast<float>(static_cast<s8>(dsp.efb));
    g_echo_feedback = feedback * static_cast<float>(g_efbct) /
        static_cast<float>(128u * 65536u);
    g_echo_feedback_crosstalk =
        feedback * static_cast<float>(static_cast<s32>(65536) - g_efbct) /
        static_cast<float>(128u * 65536u);
}

float global_volume_ramp_step() {
    const float rate = rawRate == 0 ? static_cast<float>(kDefaultRate) : static_cast<float>(rawRate);
    return 32000.0f / rate / 256.0f * static_cast<float>(g_amp);
}

float current_global_volume(float &current, float target, bool force_when_zero) {
    if (voiceMix == 0 || (force_when_zero && current == 0.0f)) {
        current = target;
        return current;
    }
    if (current == target) {
        return current;
    }

    const float step = global_volume_ramp_step();
    if (current < target) {
        current = std::min(current + step, target);
    } else {
        current = std::max(current - step, target);
    }
    return current;
}

void start_voice(u8 voice_index) {
    Voice &voice = mix[voice_index];
    DSPVoice &dsp_voice = dsp.voice[voice_index];
    g_kon_skip_decrement[voice_index] = 0;
    voice.mSrc = dsp_voice.srcn;
    voice.bCur = source_directory_entry(voice.mSrc, false);
    std::fill(voice.sBufP, voice.sBufP + 8, 0);
    voice.sIdx = dspInter >= INT_CUBIC ? 6 : 0;
    voice.mDec = 0;
    voice.mOut = 0;
    voice.eVal = 0;
    voice.mFlg = static_cast<u8>(voice.mFlg & MFLG_USER);
    set_voice_volume(voice_index);
    snap_voice_volume_to_target(voice_index);
    set_voice_pitch(voice_index);
    decode_brr_block(voice_index);

    const u8 current_adsr0 = dsp_voice.adsr[0];
    const u8 current_adsr1 = dsp_voice.adsr[1];
    const u8 current_gain = dsp_voice.gain;
    dsp_voice.adsr[0] = static_cast<u8>(voice.vAdsr & 0xffu);
    dsp_voice.adsr[1] = static_cast<u8>(voice.vAdsr >> 8);
    dsp_voice.gain = voice.vGain;
    start_envelope(voice_index);
    dsp_voice.adsr[0] = current_adsr0;
    dsp_voice.adsr[1] = current_adsr1;
    dsp_voice.gain = current_gain;

    voiceMix = static_cast<u8>(voiceMix | (1u << voice_index));
}

void advance_key_delays() {
    const u8 pending_key_on = konRsv;
    u8 started_key_on = 0;
    for (u8 i = 0; i < 8; ++i) {
        const u8 bit = static_cast<u8>(1u << i);
        if ((pending_key_on & bit) == 0 || mix[i].mKOn != 0) {
            continue;
        }
        reset_voice_for_key_on(i, bit, false);
        started_key_on = static_cast<u8>(started_key_on | bit);
    }
    konRsv = 0;

    for (u8 i = 0; i < 8; ++i) {
        const u8 bit = static_cast<u8>(1u << i);
        if ((started_key_on & bit) != 0) {
            continue;
        }
        Voice &voice = mix[i];
        if (voice.mKOn == 0) {
            g_kon_skip_decrement[i] = 0;
            continue;
        }
        if (g_kon_skip_decrement[i] != 0) {
            g_kon_skip_decrement[i] = 0;
            continue;
        }
        if (voice.mKOn <= kKonCheckKoff && (dsp.kof & bit) != 0) {
            voice.mFlg = static_cast<u8>(voice.mFlg | MFLG_KOFF);
            voice.mKOn = 0;
            g_kon_skip_decrement[i] = 0;
            continue;
        }
        if (voice.mKOn == kKonSaveEnvelope) {
            save_key_on_envelope_snapshot(i);
        }
        --voice.mKOn;
        if (voice.mKOn == 0) {
            if ((dsp.kof & bit) != 0) {
                voice.mFlg = static_cast<u8>(voice.mFlg | MFLG_KOFF);
                continue;
            }
            start_voice(i);
        }
    }
}

void advance_envelope(u8 voice_index) {
    Voice &voice = mix[voice_index];
    DSPVoice &dsp_voice = dsp.voice[voice_index];
    if ((voice.mFlg & MFLG_OFF) != 0) {
        return;
    }

    if (voice.mKOn != 0) {
        return;
    }

    if ((voice.eMode & kEnvIdle) == 0 && envelope_counter_elapsed(voice)) {
        const u8 previous_mode = voice.eMode;
        const u8 mode = static_cast<u8>(previous_mode & 0x0f);
        bool reached = false;

        if (mode == kEnvDirect) {
            if (voice.eDest == voice.eVal) {
                reached = true;
            } else if (voice.eDest < voice.eVal) {
                voice.eVal = voice.eVal > static_cast<u32>(voice.eAdj)
                    ? voice.eVal - static_cast<u32>(voice.eAdj)
                    : 0;
                if (voice.eVal <= voice.eDest) {
                    voice.eVal = voice.eDest;
                    reached = true;
                }
            } else {
                voice.eVal = std::min<u32>(kEnvelopeMax, voice.eVal + static_cast<u32>(voice.eAdj));
                if (voice.eVal >= voice.eDest) {
                    voice.eVal = voice.eDest;
                    reached = true;
                }
            }
            if (reached) {
                voice.eMode = static_cast<u8>(voice.eMode | kEnvIdle);
            }
        } else if ((previous_mode & kEnvType) != 0) {
            voice.eVal = static_cast<u32>(
                static_cast<s32>(voice.eVal) + (-(static_cast<s32>(voice.eVal)) >> 8));
            if (voice.eVal <= voice.eDest) {
                voice.eVal = voice.eDest;
                reached = true;
            }
        } else if ((previous_mode & kEnvDir) != 0) {
            voice.eVal = std::min<u32>(kEnvelopeMax, voice.eVal + static_cast<u32>(voice.eAdj));
            if (voice.eVal >= voice.eDest) {
                voice.eVal = voice.eDest;
                reached = true;
            }
        } else {
            voice.eVal = voice.eVal > static_cast<u32>(voice.eAdj)
                ? voice.eVal - static_cast<u32>(voice.eAdj)
                : 0;
            if (voice.eVal <= voice.eDest) {
                voice.eVal = voice.eDest;
                reached = true;
            }
        }

        if (reached && mode != kEnvDirect) {
            if (voice.eDest == 0) {
                finish_zero_envelope(voice_index);
            } else {
                envelope_reached_destination(voice_index, previous_mode);
            }
        }
    }

    apply_pending_envelope_register_change(voice_index);
    dsp_voice.envx = static_cast<s8>(std::min<u32>(0x7f, voice.eVal >> 4));
}

s16 sample_at_byte_offset(const Voice &voice, s32 byte_offset) {
    const s32 sample_index = byte_offset / 2;
    if (sample_index < 0) {
        const s32 previous_index = 8 + sample_index;
        return previous_index >= 0 ? voice.sBufP[previous_index] : 0;
    }
    if (sample_index < 16) {
        return voice.sBuf[sample_index];
    }
    return 0;
}

s16 interpolate_point4(const Voice &voice, const std::array<s16, 4> &coefficients) {
    const s32 offset = static_cast<s32>(voice.sIdx);
    const s64 sample =
        static_cast<s64>(sample_at_byte_offset(voice, offset - 6)) * coefficients[0] +
        static_cast<s64>(sample_at_byte_offset(voice, offset - 4)) * coefficients[1] +
        static_cast<s64>(sample_at_byte_offset(voice, offset - 2)) * coefficients[2] +
        static_cast<s64>(sample_at_byte_offset(voice, offset)) * coefficients[3];
    return clamp_s16(round_shift_signed(sample, 15));
}

double interpolate_point4_value(const Voice &voice, const std::array<s16, 4> &coefficients) {
    const s32 offset = static_cast<s32>(voice.sIdx);
    const s64 sample =
        static_cast<s64>(sample_at_byte_offset(voice, offset - 6)) * coefficients[0] +
        static_cast<s64>(sample_at_byte_offset(voice, offset - 4)) * coefficients[1] +
        static_cast<s64>(sample_at_byte_offset(voice, offset - 2)) * coefficients[2] +
        static_cast<s64>(sample_at_byte_offset(voice, offset)) * coefficients[3];
    return static_cast<double>(sample) / 32768.0;
}

s16 interpolate_point8(const Voice &voice, const std::array<s16, 8> &coefficients) {
    const s32 offset = static_cast<s32>(voice.sIdx);
    s64 sample = 0;
    for (size_t i = 0; i < coefficients.size(); ++i) {
        sample += static_cast<s64>(sample_at_byte_offset(
            voice,
            offset - 14 + static_cast<s32>(i * 2))) * coefficients[i];
    }
    return clamp_s16(round_shift_signed(sample, 15));
}

double interpolate_point8_value(const Voice &voice, const std::array<s16, 8> &coefficients) {
    const s32 offset = static_cast<s32>(voice.sIdx);
    s64 sample = 0;
    for (size_t i = 0; i < coefficients.size(); ++i) {
        sample += static_cast<s64>(sample_at_byte_offset(
            voice,
            offset - 14 + static_cast<s32>(i * 2))) * coefficients[i];
    }
    return static_cast<double>(sample) / 32768.0;
}

s16 interpolate_voice_sample(const Voice &voice) {
    const s32 offset = static_cast<s32>(voice.sIdx);
    const s32 frac = static_cast<s32>(voice.mDec);

    if (dspInter == INT_LINEAR) {
        const s32 previous = sample_at_byte_offset(voice, offset - 2);
        const s32 current = sample_at_byte_offset(voice, offset);
        return clamp_s16(previous + (((current - previous) * frac) >> 16));
    }

    if (dspInter == INT_CUBIC) {
        build_interpolation_tables();
        return interpolate_point4(voice, g_cubic_table[voice.mDec >> 8]);
    }

    if (dspInter == INT_GAUSS) {
        const u16 point = static_cast<u16>(voice.mDec >> 8);
        const s32 sample =
            sample_at_byte_offset(voice, offset - 6) * kGaussBase[255 - point] +
            sample_at_byte_offset(voice, offset - 4) * kGaussBase[511 - point] +
            sample_at_byte_offset(voice, offset - 2) * kGaussBase[256 + point] +
            sample_at_byte_offset(voice, offset) * kGaussBase[point];
        return clamp_s16(sample >> 15);
    }

    if (dspInter == INT_SINC) {
        build_interpolation_tables();
        return interpolate_point8(voice, g_sinc_table[voice.mDec >> 8]);
    }

    if (dspInter == INT_GAUSS4) {
        build_interpolation_tables();
        return interpolate_point4(voice, g_gauss4_table[voice.mDec >> 8]);
    }

    return sample_at_byte_offset(voice, offset);
}

double interpolate_voice_sample_value(const Voice &voice) {
    const s32 offset = static_cast<s32>(voice.sIdx);
    const s32 frac = static_cast<s32>(voice.mDec);

    if (dspInter == INT_LINEAR) {
        const s32 previous = sample_at_byte_offset(voice, offset - 2);
        const s32 current = sample_at_byte_offset(voice, offset);
        return static_cast<double>(previous) +
            (static_cast<double>(current - previous) * static_cast<double>(frac) / 65536.0);
    }

    if (dspInter == INT_CUBIC) {
        build_interpolation_tables();
        return interpolate_point4_value(voice, g_cubic_table[voice.mDec >> 8]);
    }

    if (dspInter == INT_GAUSS) {
        const u16 point = static_cast<u16>(voice.mDec >> 8);
        const s64 sample =
            static_cast<s64>(sample_at_byte_offset(voice, offset - 6)) * kGaussBase[255 - point] +
            static_cast<s64>(sample_at_byte_offset(voice, offset - 4)) * kGaussBase[511 - point] +
            static_cast<s64>(sample_at_byte_offset(voice, offset - 2)) * kGaussBase[256 + point] +
            static_cast<s64>(sample_at_byte_offset(voice, offset)) * kGaussBase[point];
        return static_cast<double>(sample) / 32768.0;
    }

    if (dspInter == INT_SINC) {
        build_interpolation_tables();
        return interpolate_point8_value(voice, g_sinc_table[voice.mDec >> 8]);
    }

    if (dspInter == INT_GAUSS4) {
        build_interpolation_tables();
        return interpolate_point4_value(voice, g_gauss4_table[voice.mDec >> 8]);
    }

    return static_cast<double>(sample_at_byte_offset(voice, offset));
}

void advance_voice_source(u8 voice_index) {
    Voice &voice = mix[voice_index];
    u8 whole = static_cast<u8>((voice.mRate >> 16) & 0xff);
    const u16 fraction = static_cast<u16>(voice.mRate & 0xffff);
    const u16 old_decimal = voice.mDec;
    voice.mDec = static_cast<u16>(voice.mDec + fraction);
    if (voice.mDec < old_decimal) {
        ++whole;
    }
    if (whole == 0) {
        return;
    }

    voice.sIdx += static_cast<u32>(whole) * 2u;
    if ((voice.sIdx & 0x20u) == 0) {
        return;
    }

    voice.sIdx &= ~0x20u;
    copy_previous_block_tail(voice);
    voice.bCur = static_cast<u16>(voice.bCur + 9);

    const u8 bit = static_cast<u8>(1u << voice_index);
    if ((voice.bHdr & 0x01) != 0) {
        dsp.endx = static_cast<u8>(dsp.endx | bit);
        if ((voice.bHdr & 0x02) == 0) {
            voice.eVal = 0;
            voice.mOut = 0;
            voice.mFlg = static_cast<u8>((voice.mFlg | MFLG_OFF) & ~MFLG_KOFF);
            voiceMix = static_cast<u8>(voiceMix & ~bit);
            return;
        }

        if ((voice.mFlg & MFLG_KOFF) == 0) {
            voice.mSrc = dsp.voice[voice_index].srcn;
        }
        voice.bCur = source_directory_entry(voice.mSrc, true);
    }

    decode_brr_block(voice_index);
    if ((voice.bHdr & 0x03) == 0x01) {
        std::fill(voice.sBuf + 8, voice.sBuf + 16, 0);
    }
}

void generate_noise(u8 forced_noise_mask) {
    const u32 old_noise_acc = g_noise_acc;
    g_noise_acc += g_noise_rate;
    if (g_noise_acc < old_noise_acc) {
        u32 seed = g_noise_seed << 1;
        if ((seed & 0x80000000u) != 0) {
            seed ^= 0x00040001u;
        }
        g_noise_seed = seed;
        g_noise_sample = static_cast<s32>(seed) >> 16;
    }

    if (forced_noise_mask == 0) {
        return;
    }
    const u32 old_forced_acc = g_forced_noise_acc;
    g_forced_noise_acc += g_forced_noise_rate;
    if (g_forced_noise_acc < old_forced_acc) {
        const u32 next = static_cast<u32>(
            static_cast<s32>(g_forced_noise_sample) * 27865 + 7263);
        g_forced_noise_sample = static_cast<s16>(next & 0xffffu);
    }
}

void apply_pitch_modulation(u8 voice_index) {
    if (voice_index == 0 || (dspOpts & DSP_NOPMOD) != 0 || (dsp.pmon & (1u << voice_index)) == 0) {
        return;
    }

    Voice &voice = mix[voice_index];
    const s32 modulated = (static_cast<s32>(voice.mOrgP) * (mix[voice_index - 1].mOut + 32768)) >> 15;
    const s32 max_pitch = (dspOpts & DSP_NOPLMT) != 0 ? 0xffff : 0x3fff;
    const u32 clamped = static_cast<u32>(std::clamp<s32>(modulated, 0, max_pitch));
    voice.mRate = pitch_rate_for_source(clamped, voice.mSrc);
}

s16 next_voice_sample(u8 voice_index, bool was_mixing) {
    Voice &voice = mix[voice_index];
    if (voice.mKOn != 0) {
        if (was_mixing) {
            advance_voice_source(voice_index);
        }
        return 0;
    }
    if (!was_mixing && (voice.mFlg & MFLG_OFF) != 0) {
        return 0;
    }

    const s16 sample = interpolate_voice_sample(voice);
    advance_voice_source(voice_index);
    return sample;
}

double next_voice_sample_value(u8 voice_index, bool was_mixing) {
    Voice &voice = mix[voice_index];
    if (voice.mKOn != 0) {
        if (was_mixing) {
            advance_voice_source(voice_index);
        }
        return 0.0;
    }
    if (!was_mixing && (voice.mFlg & MFLG_OFF) != 0) {
        return 0.0;
    }

    const double sample = interpolate_voice_sample_value(voice);
    advance_voice_source(voice_index);
    return sample;
}

double current_voice_sample_value(u8 voice_index, bool was_mixing, bool &advance_source) {
    Voice &voice = mix[voice_index];
    advance_source = false;
    if (voice.mKOn != 0) {
        advance_source = was_mixing;
        return 0.0;
    }
    if (!was_mixing && (voice.mFlg & MFLG_OFF) != 0) {
        return 0.0;
    }

    advance_source = true;
    return interpolate_voice_sample_value(voice);
}

void write_output_frame(u8 *&out, s32 left, s32 right) {
    const s32 bits = static_cast<s8>(rawBits);
    const u32 abs_bits = bits < 0 ? static_cast<u32>(-bits) : static_cast<u32>(bits);
    const u8 channels = rawChn == 1 ? 1 : 2;

    auto clamp_sample = [](s32 value) -> s32 {
        return static_cast<s32>(clamp_s16(value));
    };

    auto fixed_from_sample = [&clamp_sample](s32 value) -> s32 {
        return static_cast<s32>(static_cast<s64>(clamp_sample(value)) * 65536);
    };

    auto write_u8_fixed = [&out](s32 value) {
        *out++ = static_cast<u8>((static_cast<u32>(value) >> 24) + 0x80);
    };

    auto write_s16_fixed = [&out](s32 value) {
        const u32 sample = static_cast<u32>(value);
        *out++ = static_cast<u8>((sample >> 16) & 0xff);
        *out++ = static_cast<u8>((sample >> 24) & 0xff);
    };

    auto write_s24_fixed = [&out](s32 value) {
        const u32 sample = static_cast<u32>(value);
        *out++ = static_cast<u8>((sample >> 8) & 0xff);
        *out++ = static_cast<u8>((sample >> 16) & 0xff);
        *out++ = static_cast<u8>((sample >> 24) & 0xff);
    };

    auto write_s32_fixed = [&out](s32 value) {
        const u32 sample = static_cast<u32>(value);
        *out++ = static_cast<u8>(sample & 0xff);
        *out++ = static_cast<u8>((sample >> 8) & 0xff);
        *out++ = static_cast<u8>((sample >> 16) & 0xff);
        *out++ = static_cast<u8>((sample >> 24) & 0xff);
    };

    auto write_f32 = [&out, &clamp_sample](s32 value) {
        const float sample = static_cast<float>(clamp_sample(value)) / 32768.0f;
        std::memcpy(out, &sample, sizeof(sample));
        out += sizeof(sample);
    };

    if (channels == 1) {
        const s32 left_sample = clamp_sample(left);
        const s32 right_sample = clamp_sample(right);
        const s32 mono_fixed =
            static_cast<s32>((static_cast<s64>(left_sample) + right_sample) * 32768);
        if (bits == -32) {
            const float sample = static_cast<float>(left_sample + right_sample) / 65536.0f;
            std::memcpy(out, &sample, sizeof(sample));
            out += sizeof(sample);
        } else if (abs_bits == 8) {
            write_u8_fixed(mono_fixed);
        } else if (abs_bits == 16) {
            write_s16_fixed(mono_fixed);
        } else if (abs_bits == 24) {
            write_s24_fixed(mono_fixed);
        } else if (abs_bits == 32) {
            write_s32_fixed(mono_fixed);
        }
        return;
    }

    if (bits == -32) {
        write_f32(left);
        write_f32(right);
        return;
    }
    if (abs_bits == 8) {
        write_u8_fixed(fixed_from_sample(left));
        write_u8_fixed(fixed_from_sample(right));
        return;
    }
    if (abs_bits == 16) {
        write_s16_fixed(fixed_from_sample(left));
        write_s16_fixed(fixed_from_sample(right));
        return;
    }
    if (abs_bits == 24) {
        write_s24_fixed(fixed_from_sample(left));
        write_s24_fixed(fixed_from_sample(right));
        return;
    }
    if (abs_bits == 32) {
        write_s32_fixed(fixed_from_sample(left));
        write_s32_fixed(fixed_from_sample(right));
        return;
    }

    if (out) {
        write_s16_fixed(fixed_from_sample(left));
        if (channels == 2) {
            write_s16_fixed(fixed_from_sample(right));
        }
    }
}

void write_output_frame_fixed(u8 *&out, float left, float right) {
    const s32 bits = static_cast<s8>(rawBits);
    const u32 abs_bits = bits < 0 ? static_cast<u32>(-bits) : static_cast<u32>(bits);
    const u8 channels = rawChn == 1 ? 1 : 2;

    auto write_i8_from_i32 = [&out](s32 value) {
        *out++ = static_cast<u8>((static_cast<u32>(value) >> 24) + 0x80);
    };

    auto write_i16_from_i32 = [&out](s32 value) {
        const u32 sample = static_cast<u32>(value);
        *out++ = static_cast<u8>((sample >> 16) & 0xff);
        *out++ = static_cast<u8>((sample >> 24) & 0xff);
    };

    auto write_i24_from_i32 = [&out](s32 value) {
        const u32 sample = static_cast<u32>(value);
        *out++ = static_cast<u8>((sample >> 8) & 0xff);
        *out++ = static_cast<u8>((sample >> 16) & 0xff);
        *out++ = static_cast<u8>((sample >> 24) & 0xff);
    };

    auto write_i32 = [&out](s32 value) {
        const u32 sample = static_cast<u32>(value);
        *out++ = static_cast<u8>(sample & 0xff);
        *out++ = static_cast<u8>((sample >> 8) & 0xff);
        *out++ = static_cast<u8>((sample >> 16) & 0xff);
        *out++ = static_cast<u8>((sample >> 24) & 0xff);
    };

    auto write_f32 = [&out](float value) {
        const float sample = f32(value * (1.0f / 2147483648.0f));
        std::memcpy(out, &sample, sizeof(sample));
        out += sizeof(sample);
    };

    if (channels == 1) {
        if (bits == -32) {
            write_f32(f32((left + right) * 0.5f));
            return;
        }

        const float mixed = f32((clamp_output_fixed(left) + clamp_output_fixed(right)) * 0.5f);
        const s32 value = round_float_to_i32(mixed);
        if (abs_bits == 8) {
            write_i8_from_i32(value);
        } else if (abs_bits == 16) {
            write_i16_from_i32(value);
        } else if (abs_bits == 24) {
            write_i24_from_i32(value);
        } else if (abs_bits == 32) {
            write_i32(value);
        }
        return;
    }

    if (bits == -32) {
        write_f32(left);
        write_f32(right);
        return;
    }

    const s32 left_value = round_float_to_i32(clamp_output_fixed(left));
    const s32 right_value = round_float_to_i32(clamp_output_fixed(right));
    if (abs_bits == 8) {
        write_i8_from_i32(left_value);
        write_i8_from_i32(right_value);
    } else if (abs_bits == 16) {
        write_i16_from_i32(left_value);
        write_i16_from_i32(right_value);
    } else if (abs_bits == 24) {
        write_i24_from_i32(left_value);
        write_i24_from_i32(right_value);
    } else if (abs_bits == 32) {
        write_i32(left_value);
        write_i32(right_value);
    }
}

float apply_analog_filter_to_sample(float sample, float &state) {
    const long double input = static_cast<long double>(sample);

    const long double first_previous = static_cast<long double>(state);
    const long double first_state =
        input - first_previous * static_cast<long double>(g_aaf1_a1);
    state = f32(static_cast<float>(first_state));
    const float first_output = f32(static_cast<float>(
        first_state * static_cast<long double>(g_aaf1_b0) +
        first_previous * static_cast<long double>(g_aaf1_b1)));

    const long double second_previous = static_cast<long double>(state);
    const long double second_state_a =
        static_cast<long double>(first_output) -
        second_previous * static_cast<long double>(g_aaf2_a1);
    const long double second_output_a =
        second_state_a * static_cast<long double>(g_aaf2_b0) +
        second_previous * static_cast<long double>(g_aaf2_b1);
    const long double second_state_b =
        second_output_a - second_previous * static_cast<long double>(g_aaf2_a1);
    state = f32(static_cast<float>(second_state_b));
    const long double output =
        second_state_b * static_cast<long double>(g_aaf2_b0) +
        second_previous * static_cast<long double>(g_aaf2_b1);

    return f32(static_cast<float>(output));
}

void apply_analog_filter(float &left, float &right) {
    left = apply_analog_filter_to_sample(left, g_aaf_state_left);
    right = apply_analog_filter_to_sample(right, g_aaf_state_right);
}

void render_dsp_samples(void *buffer, u32 samples) {
    auto *out = static_cast<u8 *>(buffer);
    vMMaxL = 0;
    vMMaxR = 0;
    dspPMod = (dspOpts & DSP_NOPMOD) != 0 ? 0 : static_cast<u8>(dsp.pmon & 0xfe);
    dspNoise = (dspOpts & DSP_NONOISE) != 0 ? 0 : dsp.non;
    dspNoiseF = 0;
    for (u8 i = 0; i < 8; ++i) {
        if ((mix[i].mFlg & MFLG_NOISE) != 0) {
            dspNoiseF = static_cast<u8>(dspNoiseF | (1u << i));
        }
    }
    dspNoise = static_cast<u8>(dspNoise | dspNoiseF);

    for (u32 sample_index = 0; sample_index < samples; ++sample_index) {
        if (rawRate != 0 && g_song_len != static_cast<u32>(~0U)) {
            const u64 ticks_from_end =
                (static_cast<u64>(samples - sample_index) * 64000u) / rawRate;
            const u32 sample_t64 = static_cast<u32>(t64Cnt - static_cast<u32>(ticks_from_end));
            ::apply_fade_volume_at(sample_t64);
        }
        generate_noise(dspNoiseF);

        float dry_left = 0.0f;
        float dry_right = 0.0f;
        float echo_send_left = 0.0f;
        float echo_send_right = 0.0f;
        for (u8 i = 0; i < 8; ++i) {
            Voice &voice = mix[i];
            const bool was_mixing = (voiceMix & (1u << i)) != 0;
            apply_pitch_modulation(i);
            advance_envelope(i);
            bool advance_source = false;
            double raw = current_voice_sample_value(i, was_mixing, advance_source);
            if ((dspNoise & (1u << i)) != 0) {
                raw = static_cast<double>(
                    (dspNoiseF & (1u << i)) != 0 ? g_forced_noise_sample : g_noise_sample);
            }
            const double env_value =
                raw * static_cast<double>(voice.eVal) / 2048.0;
            const s32 env_sample = static_cast<s32>(std::lrint(env_value));
            voice.mOut = env_sample;
            dsp.voice[i].outx = static_cast<s8>(std::clamp<s32>(env_sample >> 8, -128, 127));
            if ((voice.mFlg & MFLG_MUTE) != 0) {
                if (advance_source) {
                    advance_voice_source(i);
                }
                continue;
            }
            const bool keying_off = (voice.mFlg & MFLG_KOFF) != 0;
            const float current_left =
                current_channel_volume(voice.mChnL, voice.mTgtL, keying_off);
            const float current_right =
                current_channel_volume(voice.mChnR, voice.mTgtR, keying_off);
            const double voice_left = env_value * static_cast<double>(current_left);
            const double voice_right = env_value * static_cast<double>(current_right);
            dry_left = f32(static_cast<float>(static_cast<double>(dry_left) + voice_left));
            dry_right = f32(static_cast<float>(static_cast<double>(dry_right) + voice_right));
            if ((dsp.eon & (1u << i)) != 0) {
                echo_send_left = f32(static_cast<float>(static_cast<double>(echo_send_left) + voice_left));
                echo_send_right = f32(static_cast<float>(static_cast<double>(echo_send_right) + voice_right));
            }
            voice.vMaxL = std::max<s32>(voice.vMaxL, bits_from_float(std::fabs(static_cast<float>(voice_left))));
            voice.vMaxR = std::max<s32>(voice.vMaxR, bits_from_float(std::fabs(static_cast<float>(voice_right))));
            if (advance_source) {
                advance_voice_source(i);
            }
        }

        double echo_left = 0.0;
        double echo_right = 0.0;
        const bool echo_enabled = (dspOpts & DSP_NOECHO) == 0 && (dsp.flg & 0x20) == 0;
        if (echo_enabled) {
            const size_t echo_index = current_echo_index();
            float delayed_left = g_echo_left[echo_index];
            float delayed_right = g_echo_right[echo_index];
            const bool emulate_snes_fir = (dspOpts & DSP_ECHOFIR) != 0;

            if ((dspOpts & DSP_NOFIR) != 0) {
                echo_left = static_cast<double>(delayed_left);
                echo_right = static_cast<double>(delayed_right);
            } else {
                if (emulate_snes_fir) {
                    delayed_left = f32(static_cast<float>(fir_clamp16(delayed_left)));
                    delayed_right = f32(static_cast<float>(fir_clamp16(delayed_right)));
                }
                g_fir_left[g_fir_pos] = delayed_left;
                g_fir_right[g_fir_pos] = delayed_right;

                double filtered_left = 0.0;
                double filtered_right = 0.0;
                for (size_t tap = 0; tap < 8; ++tap) {
                    const size_t history_index = (g_fir_pos + 1 + tap) & 7u;
                    const double coeff = static_cast<double>(dsp.fir[tap].c) / 128.0;
                    filtered_left += static_cast<double>(g_fir_left[history_index]) * coeff;
                    filtered_right += static_cast<double>(g_fir_right[history_index]) * coeff;
                    if (emulate_snes_fir) {
                        if (tap == 7) {
                            filtered_left = fir_clamp16(filtered_left);
                            filtered_right = fir_clamp16(filtered_right);
                        } else {
                            filtered_left = fir_cut16(filtered_left);
                            filtered_right = fir_cut16(filtered_right);
                        }
                    } else {
                        filtered_left = fir_clamp17(filtered_left);
                        filtered_right = fir_clamp17(filtered_right);
                    }
                }
                echo_left = filtered_left;
                echo_right = filtered_right;
            }

            if (g_efbct == static_cast<s32>(kDefaultEfbct) && g_echo_feedback_crosstalk == 0.0f) {
                g_echo_left[echo_index] = f32(static_cast<float>(
                    static_cast<long double>(echo_send_left) +
                    static_cast<long double>(echo_left) * static_cast<long double>(g_echo_feedback)));
                g_echo_right[echo_index] = f32(static_cast<float>(
                    static_cast<long double>(echo_send_right) +
                    static_cast<long double>(echo_right) * static_cast<long double>(g_echo_feedback)));
            } else {
                g_echo_left[echo_index] = f32(static_cast<float>(
                    static_cast<long double>(echo_send_left) +
                    static_cast<long double>(echo_left) * static_cast<long double>(g_echo_feedback) +
                    static_cast<long double>(echo_right) * static_cast<long double>(g_echo_feedback_crosstalk)));
                g_echo_right[echo_index] = f32(static_cast<float>(
                    static_cast<long double>(echo_send_right) +
                    static_cast<long double>(echo_right) * static_cast<long double>(g_echo_feedback) +
                    static_cast<long double>(echo_left) * static_cast<long double>(g_echo_feedback_crosstalk)));
            }

            if (emulate_snes_fir) {
                write_echo_memory(g_echo_left[echo_index], g_echo_right[echo_index]);
            }

            advance_echo_delay_cursor();
            if ((dspOpts & DSP_NOFIR) == 0) {
                g_fir_pos = (g_fir_pos + 1) & 7u;
            }
        }

        const float main_left_volume =
            current_global_volume(g_main_current_left, g_main_target_left, true);
        const float main_right_volume =
            current_global_volume(g_main_current_right, g_main_target_right, true);
        float echo_left_volume = g_echo_current_left;
        float echo_right_volume = g_echo_current_right;
        if (echo_enabled) {
            echo_left_volume = current_global_volume(g_echo_current_left, g_echo_target_left, false);
            echo_right_volume = current_global_volume(g_echo_current_right, g_echo_target_right, false);
        }

        float left = (dspOpts & DSP_NOMAIN) != 0
            ? 0.0f
            : f32(static_cast<float>(static_cast<double>(dry_left) * main_left_volume));
        float right = (dspOpts & DSP_NOMAIN) != 0
            ? 0.0f
            : f32(static_cast<float>(static_cast<double>(dry_right) * main_right_volume));
        left = f32(static_cast<float>(static_cast<double>(left) +
            echo_left * static_cast<double>(echo_left_volume)));
        right = f32(static_cast<float>(static_cast<double>(right) +
            echo_right * static_cast<double>(echo_right_volume)));
        if ((dsp.flg & 0x40) != 0) {
            left = 0.0f;
            right = 0.0f;
        }
        vMMaxL = std::max<u32>(vMMaxL, static_cast<u32>(bits_from_float(std::fabs(left))));
        vMMaxR = std::max<u32>(vMMaxR, static_cast<u32>(bits_from_float(std::fabs(right))));
        if ((dspOpts & DSP_ANALOG) != 0) {
            apply_analog_filter(left, right);
        }
        g_debug_last_mix_left = left;
        g_debug_last_mix_right = right;

        if (buffer) {
            write_output_frame_fixed(out, left, right);
        }
        apply_deferred_key_on_resets();
        advance_key_delays();
    }
    update_dsp_x_registers();
}

s32 execute_spc700(s32 cycles) {
    s32 clk_left = cycles;
    while (clk_left > 0) {
        const u8 opcode = g_apu_ram[g_pc];
        const s32 before = clk_left;
        switch (opcode) {
            case 0x00: {  // NOP
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x04: {  // OR A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_a = static_cast<u8>(g_a | read_apu_byte(static_cast<u16>(dp_base + addr)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x05: {  // OR A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a | read_apu_byte(addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x06: {  // OR A,(X)
                g_a = static_cast<u8>(g_a | read_apu_byte(direct_page_addr(g_x)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x07: {  // OR A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                g_a = static_cast<u8>(g_a | read_apu_byte(addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x08: {  // OR A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                g_a = static_cast<u8>(g_a | g_apu_ram[g_pc]);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x0a: {  // OR1 C,mem.bit
                const u16 operand = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(operand & 0x1fff);
                const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                const u8 value = read_apu_byte(addr);
                if (((value >> bit) & 0x01) != 0) {
                    g_psw = static_cast<u8>(g_psw | 0x01);
                }
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x02:
            case 0x22:
            case 0x42:
            case 0x62:
            case 0x82:
            case 0xa2:
            case 0xc2:
            case 0xe2: {  // SET1 dp.bit
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 bit = static_cast<u8>(opcode >> 5);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                write_apu_byte(effective, static_cast<u8>(g_apu_ram[effective] | (1u << bit)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x09: {  // OR dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 source_addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + source_addr));
                const u8 dest_addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 dest = static_cast<u16>(dp_base + dest_addr);
                const u8 value = static_cast<u8>(g_apu_ram[dest] | rhs);
                write_apu_byte(dest, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x14: {  // OR A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                g_a = static_cast<u8>(g_a | read_apu_byte(direct_page_addr(addr)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x15: {  // OR A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a | read_apu_byte(static_cast<u16>(base + g_x)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x16: {  // OR A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a | read_apu_byte(static_cast<u16>(base + g_y)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x17: {  // OR A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                g_a = static_cast<u8>(g_a | read_apu_byte(static_cast<u16>(base + g_y)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x18: {  // OR dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u16 effective = direct_page_addr(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                const u8 value = static_cast<u8>(read_apu_byte(effective) | rhs);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x19: {  // OR (X),(Y)
                const u8 rhs = read_apu_byte(direct_page_addr(g_y));
                const u16 dest = direct_page_addr(g_x);
                const u8 value = static_cast<u8>(read_apu_byte(dest) | rhs);
                write_apu_byte(dest, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x0d: {  // PUSH PSW
                push_byte(g_psw);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x0e: {  // TSET1 abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 old_value = g_apu_ram[addr];
                write_apu_byte(addr, static_cast<u8>(old_value | g_a));
                set_nz_8(static_cast<u8>(g_a - old_value));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x0b: {  // ASL dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 old_value = read_apu_byte(effective);
                const u8 value = static_cast<u8>(old_value << 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x0c: {  // ASL abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 old_value = read_apu_byte(addr);
                const u8 value = static_cast<u8>(old_value << 1);
                write_apu_byte(addr, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x10: {  // BPL rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x80) == 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0x13:
            case 0x33:
            case 0x53:
            case 0x73:
            case 0x93:
            case 0xb3:
            case 0xd3:
            case 0xf3: {  // BBC dp.bit,rel
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 bit = static_cast<u8>(opcode >> 5);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const s8 rel = static_cast<s8>(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                if ((read_apu_byte(static_cast<u16>(dp_base + addr)) & (1u << bit)) == 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 7 * kSpcCycle;
                } else {
                    clk_left -= 5 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 2);
                break;
            }

            case 0x1c: {  // ASL A
                const u8 carry = static_cast<u8>((g_a & 0x80) != 0);
                g_a = static_cast<u8>(g_a << 1);
                set_nz_8(g_a);
                g_psw = static_cast<u8>((g_psw & ~0x01) | carry);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x1b: {  // ASL dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 effective = direct_page_addr(addr);
                const u8 old_value = read_apu_byte(effective);
                const u8 value = static_cast<u8>(old_value << 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x1d: {  // DEC X
                g_x = static_cast<u8>(g_x - 1);
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x1e: {  // CMP X,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                set_cmp_flags(g_x, read_apu_byte(addr));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x1f: {  // JMP [abs+X]
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(base + g_x);
                g_pc = static_cast<u16>(
                    read_apu_byte(addr) |
                    (static_cast<u16>(read_apu_byte(static_cast<u16>(addr + 1))) << 8));
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x20: {  // CLRP
                g_psw = static_cast<u8>(g_psw & ~0x20);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x24: {  // AND A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_a = static_cast<u8>(g_a & read_apu_byte(static_cast<u16>(dp_base + addr)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x25: {  // AND A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a & read_apu_byte(addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x26: {  // AND A,(X)
                g_a = static_cast<u8>(g_a & read_apu_byte(direct_page_addr(g_x)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x27: {  // AND A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                g_a = static_cast<u8>(g_a & read_apu_byte(addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x28: {  // AND A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                g_a = static_cast<u8>(g_a & g_apu_ram[g_pc]);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x29: {  // AND dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 source_addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(direct_page_addr(source_addr));
                const u16 dest = direct_page_addr(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                const u8 value = static_cast<u8>(read_apu_byte(dest) & rhs);
                write_apu_byte(dest, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x2a: {  // OR1 C,/mem.bit
                const u16 operand = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(operand & 0x1fff);
                const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                const u8 value = read_apu_byte(addr);
                if (((value >> bit) & 0x01) == 0) {
                    g_psw = static_cast<u8>(g_psw | 0x01);
                }
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x2b: {  // ROL dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 old_value = g_apu_ram[effective];
                const u8 carry_in = static_cast<u8>(g_psw & 0x01);
                const u8 value = static_cast<u8>((old_value << 1) | carry_in);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x2c: {  // ROL abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 old_value = read_apu_byte(addr);
                const u8 carry_in = static_cast<u8>(g_psw & 0x01);
                const u8 value = static_cast<u8>((old_value << 1) | carry_in);
                write_apu_byte(addr, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x03:
            case 0x23:
            case 0x43:
            case 0x63:
            case 0x83:
            case 0xa3:
            case 0xc3:
            case 0xe3: {  // BBS dp.bit,rel
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 bit = static_cast<u8>(opcode >> 5);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const s8 rel = static_cast<s8>(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                if ((read_apu_byte(static_cast<u16>(dp_base + addr)) & (1u << bit)) != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 7 * kSpcCycle;
                } else {
                    clk_left -= 5 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 2);
                break;
            }

            case 0x12:
            case 0x32:
            case 0x52:
            case 0x72:
            case 0x92:
            case 0xb2:
            case 0xd2:
            case 0xf2: {  // CLR1 dp.bit
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 bit = static_cast<u8>(opcode >> 5);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(read_apu_byte(effective) & ~(1u << bit));
                write_apu_byte(effective, value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x2f: {  // BRA rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                g_pc = static_cast<u16>(g_pc + rel);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x2d: {  // PUSH A
                push_byte(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x4d: {  // PUSH X
                push_byte(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x6d: {  // PUSH Y
                push_byte(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x30: {  // BMI rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x80) != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0x2e: {  // CBNE dp,rel
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const s8 rel = static_cast<s8>(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                if (g_a != read_apu_byte(static_cast<u16>(dp_base + addr))) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 7 * kSpcCycle;
                } else {
                    clk_left -= 5 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 2);
                break;
            }

            case 0x1a: {  // DECW dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u8 low_addr = addr;
                const u8 high_addr = static_cast<u8>(addr + 1);
                const u16 value = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(dp_base + low_addr)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(dp_base + high_addr)]) << 8));
                const u16 result = static_cast<u16>(value - 1);
                write_apu_byte(static_cast<u16>(dp_base + high_addr), static_cast<u8>(result >> 8));
                write_apu_byte(static_cast<u16>(dp_base + low_addr), static_cast<u8>(result & 0xff));
                set_nz_16(result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x3a: {  // INCW dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u8 low_addr = addr;
                const u8 high_addr = static_cast<u8>(addr + 1);
                const u16 value = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(dp_base + low_addr)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(dp_base + high_addr)]) << 8));
                const u16 result = static_cast<u16>(value + 1);
                write_apu_byte(static_cast<u16>(dp_base + high_addr), static_cast<u8>(result >> 8));
                write_apu_byte(static_cast<u16>(dp_base + low_addr), static_cast<u8>(result & 0xff));
                set_nz_16(result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x3c: {  // ROL A
                const u8 carry_in = static_cast<u8>(g_psw & 0x01);
                const u8 old_value = g_a;
                g_a = static_cast<u8>((g_a << 1) | carry_in);
                set_nz_8(g_a);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x3b: {  // ROL dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 effective = direct_page_addr(addr);
                const u8 old_value = read_apu_byte(effective);
                const u8 carry_in = static_cast<u8>(g_psw & 0x01);
                const u8 value = static_cast<u8>((old_value << 1) | carry_in);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((old_value >> 7) & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x3e: {  // CMP X,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = g_apu_ram[g_pc];
                set_cmp_flags(g_x, read_apu_byte(direct_page_addr(addr)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x34: {  // AND A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                g_a = static_cast<u8>(g_a & read_apu_byte(direct_page_addr(addr)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x35: {  // AND A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a & read_apu_byte(static_cast<u16>(base + g_x)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x36: {  // AND A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a & read_apu_byte(static_cast<u16>(base + g_y)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x37: {  // AND A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                g_a = static_cast<u8>(g_a & read_apu_byte(static_cast<u16>(base + g_y)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x38: {  // AND dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(g_apu_ram[effective] & rhs);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x39: {  // AND (X),(Y)
                const u8 rhs = read_apu_byte(direct_page_addr(g_y));
                const u16 dest = direct_page_addr(g_x);
                const u8 value = static_cast<u8>(read_apu_byte(dest) & rhs);
                write_apu_byte(dest, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x3f: {  // CALL abs
                const u16 target = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                push_word(static_cast<u16>(g_pc + 3));
                g_pc = target;
                clk_left -= 8 * kSpcCycle;
                break;
            }

            case 0x40: {  // SETP
                g_psw = static_cast<u8>(g_psw | 0x20);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x3d: {  // INC X
                g_x = static_cast<u8>(g_x + 1);
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x44: {  // EOR A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_a = static_cast<u8>(g_a ^ read_apu_byte(static_cast<u16>(dp_base + addr)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x45: {  // EOR A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a ^ read_apu_byte(addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x46: {  // EOR A,(X)
                const u16 dp_base = direct_page_base();
                g_a = static_cast<u8>(g_a ^ read_apu_byte(static_cast<u16>(dp_base + g_x)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x47: {  // EOR A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                g_a = static_cast<u8>(g_a ^ read_apu_byte(addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x48: {  // EOR A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                g_a = static_cast<u8>(g_a ^ g_apu_ram[g_pc]);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x49: {  // EOR dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 source_addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + source_addr));
                const u8 dest_addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 dest = static_cast<u16>(dp_base + dest_addr);
                const u8 value = static_cast<u8>(read_apu_byte(dest) ^ rhs);
                write_apu_byte(dest, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x4a: {  // AND1 C,mem.bit
                if ((g_psw & 0x01) != 0) {
                    const u16 operand = static_cast<u16>(
                        g_apu_ram[static_cast<u16>(g_pc + 1)] |
                        (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                    const u16 addr = static_cast<u16>(operand & 0x1fff);
                    const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                    const u8 value = read_apu_byte(addr);
                    g_psw = static_cast<u8>((g_psw & ~0x01) | ((value >> bit) & 0x01));
                }
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x4e: {  // TCLR1 abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 old_value = read_apu_byte(addr);
                write_apu_byte(addr, static_cast<u8>(old_value & ~g_a));
                set_nz_8(static_cast<u8>(g_a - old_value));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x50: {  // BVC rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x40) == 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0x54: {  // EOR A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                g_a = static_cast<u8>(g_a ^ read_apu_byte(static_cast<u16>(dp_base + addr)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x55: {  // EOR A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a ^ read_apu_byte(static_cast<u16>(base + g_x)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x56: {  // EOR A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = static_cast<u8>(g_a ^ read_apu_byte(static_cast<u16>(base + g_y)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x57: {  // EOR A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                g_a = static_cast<u8>(g_a ^ read_apu_byte(static_cast<u16>(base + g_y)));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x58: {  // EOR dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(g_apu_ram[effective] ^ rhs);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x59: {  // EOR (X),(Y)
                const u16 dp_base = direct_page_base();
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + g_y));
                const u16 dest = static_cast<u16>(dp_base + g_x);
                const u8 value = static_cast<u8>(read_apu_byte(dest) ^ rhs);
                write_apu_byte(dest, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x5a: {  // CMPW YA,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 rhs = read_direct_word_wrapped(g_apu_ram[g_pc]);
                const u16 lhs = static_cast<u16>(g_a | (static_cast<u16>(g_y) << 8));
                set_cmpw_flags(lhs, rhs);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x5d: {  // MOV X,A
                g_x = g_a;
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x5e: {  // CMP Y,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                set_cmp_flags(g_y, read_apu_byte(addr));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x5c: {  // LSR A
                const u8 carry = static_cast<u8>(g_a & 0x01);
                g_a = static_cast<u8>(g_a >> 1);
                set_nz_8(g_a);
                g_psw = static_cast<u8>((g_psw & ~0x01) | carry);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x5b: {  // LSR dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 effective = direct_page_addr(addr);
                const u8 old_value = read_apu_byte(effective);
                const u8 value = static_cast<u8>(old_value >> 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x5f: {  // JMP abs
                g_pc = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x60: {  // CLRC
                g_psw = static_cast<u8>(g_psw & ~0x01);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x64: {  // CMP A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                set_cmp_flags(g_a, read_apu_byte(static_cast<u16>(dp_base + addr)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x65: {  // CMP A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                set_cmp_flags(g_a, read_apu_byte(addr));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x66: {  // CMP A,(X)
                set_cmp_flags(g_a, read_apu_byte(direct_page_addr(g_x)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x67: {  // CMP A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                set_cmp_flags(g_a, read_apu_byte(addr));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x6a: {  // AND1 C,/mem.bit
                if ((g_psw & 0x01) != 0) {
                    const u16 operand = static_cast<u16>(
                        g_apu_ram[static_cast<u16>(g_pc + 1)] |
                        (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                    const u16 addr = static_cast<u16>(operand & 0x1fff);
                    const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                    const u8 value = read_apu_byte(addr);
                    g_psw = static_cast<u8>(
                        (g_psw & ~0x01) | ((((value >> bit) & 0x01) == 0) ? 0x01 : 0x00));
                }
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x6b: {  // ROR dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 old_value = g_apu_ram[effective];
                const u8 carry_in = static_cast<u8>((g_psw & 0x01) << 7);
                const u8 value = static_cast<u8>((old_value >> 1) | carry_in);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x6c: {  // ROR abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 old_value = read_apu_byte(addr);
                const u8 carry_in = static_cast<u8>((g_psw & 0x01) << 7);
                const u8 value = static_cast<u8>((old_value >> 1) | carry_in);
                write_apu_byte(addr, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x6e: {  // DBNZ dp,rel
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const s8 rel = static_cast<s8>(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(read_apu_byte(effective) - 1);
                write_apu_byte(effective, value);
                if (value != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 7 * kSpcCycle;
                } else {
                    clk_left -= 5 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 2);
                break;
            }

            case 0x6f: {  // RET
                g_pc = pop_word();
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x7d: {  // MOV A,X
                g_a = g_x;
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x68: {  // CMP A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                set_cmp_flags(g_a, g_apu_ram[g_pc]);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x69: {  // CMP dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 rhs_addr = g_apu_ram[g_pc];
                const u8 lhs_addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + rhs_addr));
                const u8 lhs = read_apu_byte(static_cast<u16>(dp_base + lhs_addr));
                set_cmp_flags(lhs, rhs);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x7a: {  // ADDW YA,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 rhs = read_direct_word_wrapped(g_apu_ram[g_pc]);
                const u16 lhs = static_cast<u16>(g_a | (static_cast<u16>(g_y) << 8));
                const u32 result = static_cast<u32>(lhs) + rhs;
                g_a = static_cast<u8>(result & 0xff);
                g_y = static_cast<u8>((result >> 8) & 0xff);
                set_addw_flags(lhs, rhs, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x7e: {  // CMP Y,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                set_cmp_flags(g_y, read_apu_byte(static_cast<u16>(dp_base + addr)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x7c: {  // ROR A
                const u8 old_value = g_a;
                const u8 carry_in = static_cast<u8>((g_psw & 0x01) << 7);
                g_a = static_cast<u8>((g_a >> 1) | carry_in);
                set_nz_8(g_a);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x7b: {  // ROR dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 effective = direct_page_addr(addr);
                const u8 old_value = read_apu_byte(effective);
                const u8 carry_in = static_cast<u8>((g_psw & 0x01) << 7);
                const u8 value = static_cast<u8>((old_value >> 1) | carry_in);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x78: {  // CMP dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u8 lhs = read_apu_byte(static_cast<u16>(dp_base + addr));
                set_cmp_flags(lhs, rhs);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x74: {  // CMP A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                set_cmp_flags(g_a, read_apu_byte(static_cast<u16>(dp_base + addr)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x75: {  // CMP A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(base + g_x);
                const u8 rhs = read_apu_byte(addr);
                set_cmp_flags(g_a, rhs);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x70: {  // BVS rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x40) != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0x76: {  // CMP A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(base + g_y);
                const u8 rhs = read_apu_byte(addr);
                set_cmp_flags(g_a, rhs);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x77: {  // CMP A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                set_cmp_flags(g_a, read_apu_byte(static_cast<u16>(base + g_y)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x79: {  // CMP (X),(Y)
                const u8 rhs = read_apu_byte(direct_page_addr(g_y));
                const u8 lhs = read_apu_byte(direct_page_addr(g_x));
                set_cmp_flags(lhs, rhs);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x80: {  // SETC
                g_psw = static_cast<u8>(g_psw | 0x01);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x84: {  // ADC A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + addr));
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x85: {  // ADC A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 rhs = read_apu_byte(addr);
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x86: {  // ADC A,(X)
                const u8 rhs = read_apu_byte(direct_page_addr(g_x));
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0x88: {  // ADC A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x89: {  // ADC dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 source_addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + source_addr));
                const u8 dest_addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 dest = static_cast<u16>(dp_base + dest_addr);
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = read_apu_byte(dest);
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                write_apu_byte(dest, static_cast<u8>(result & 0xff));
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x8a: {  // EOR1 C,mem.bit
                const u16 operand = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(operand & 0x1fff);
                const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                const u8 value = read_apu_byte(addr);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((g_psw ^ (value >> bit)) & 0x01));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x4b: {  // LSR dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 old_value = read_apu_byte(effective);
                const u8 value = static_cast<u8>(old_value >> 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x4c: {  // LSR abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 old_value = read_apu_byte(addr);
                const u8 value = static_cast<u8>(old_value >> 1);
                write_apu_byte(addr, value);
                set_nz_8(value);
                g_psw = static_cast<u8>((g_psw & ~0x01) | (old_value & 0x01));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x8b: {  // DEC dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(read_apu_byte(effective) - 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x8c: {  // DEC abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 value = static_cast<u8>(read_apu_byte(addr) - 1);
                write_apu_byte(addr, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x8d: {  // MOV Y,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                g_y = g_apu_ram[g_pc];
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x8e: {  // POP PSW
                g_psw = pop_byte();
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x8f: {  // MOV dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 value = g_apu_ram[g_pc];
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                write_apu_byte(static_cast<u16>(dp_base + addr), value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x90: {  // BCC rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x01) == 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0x94: {  // ADC A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u8 rhs = read_apu_byte(direct_page_addr(addr));
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0x95: {  // ADC A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 rhs = read_apu_byte(static_cast<u16>(base + g_x));
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x96: {  // ADC A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 rhs = read_apu_byte(static_cast<u16>(base + g_y));
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x87: {  // ADC A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                const u8 rhs = read_apu_byte(addr);
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x97: {  // ADC A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                const u8 rhs = read_apu_byte(static_cast<u16>(base + g_y));
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_a;
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                g_a = static_cast<u8>(result & 0xff);
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0x98: {  // ADC dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = g_apu_ram[effective];
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                write_apu_byte(effective, static_cast<u8>(result & 0xff));
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x99: {  // ADC (X),(Y)
                const u8 rhs = read_apu_byte(direct_page_addr(g_y));
                const u16 dest = direct_page_addr(g_x);
                const u8 carry = static_cast<u8>(g_psw & 0x01);
                const u8 lhs = read_apu_byte(dest);
                const u16 result = static_cast<u16>(lhs + rhs + carry);
                write_apu_byte(dest, static_cast<u8>(result & 0xff));
                set_adc_flags(lhs, rhs, carry, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x9b: {  // DEC dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(g_apu_ram[effective] - 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x9c: {  // DEC A
                g_a = static_cast<u8>(g_a - 1);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0x9e: {  // DIV YA,X
                const u16 ya = static_cast<u16>(g_a | (static_cast<u16>(g_y) << 8));
                g_psw = static_cast<u8>(g_psw & ~(0x40 | 0x08));
                if (g_y >= g_x) {
                    g_psw = static_cast<u8>(g_psw | 0x40);
                }
                if ((g_y & 0x0f) >= (g_x & 0x0f)) {
                    g_psw = static_cast<u8>(g_psw | 0x08);
                }

                if (g_x == 0) {
                    const u8 old_a = g_a;
                    g_a = static_cast<u8>(~g_y);
                    g_y = old_a;
                    g_psw = static_cast<u8>(g_psw | 0x40);
                } else if (static_cast<u16>(g_y) < static_cast<u16>(g_x) * 2u) {
                    g_a = static_cast<u8>(ya / g_x);
                    g_y = static_cast<u8>(ya % g_x);
                } else {
                    const u16 dividend = static_cast<u16>(ya - (static_cast<u16>(g_x) << 9));
                    const u16 divisor = static_cast<u16>(256u - g_x);
                    const u16 quotient = static_cast<u16>(dividend / divisor);
                    const u16 remainder = static_cast<u16>(dividend % divisor);
                    g_a = static_cast<u8>(~quotient);
                    g_y = static_cast<u8>(g_x + remainder);
                }
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 12 * kSpcCycle;
                break;
            }

            case 0x9f: {  // XCN A
                g_a = static_cast<u8>((g_a >> 4) | (g_a << 4));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0x9a: {  // SUBW YA,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 rhs = read_direct_word_wrapped(g_apu_ram[g_pc]);
                const u16 lhs = static_cast<u16>(g_a | (static_cast<u16>(g_y) << 8));
                const s32 result = static_cast<s32>(lhs) - rhs;
                g_a = static_cast<u8>(result & 0xff);
                g_y = static_cast<u8>((result >> 8) & 0xff);
                set_subw_flags(lhs, rhs, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xaa: {  // MOV1 C,mem.bit
                const u16 operand = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(operand & 0x1fff);
                const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                const u8 value = read_apu_byte(addr);
                g_psw = static_cast<u8>((g_psw & ~0x01) | ((value >> bit) & 0x01));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xa8: {  // SBC A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xa4: {  // SBC A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + addr));
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xa5: {  // SBC A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 rhs = read_apu_byte(addr);
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xa6: {  // SBC A,(X)
                const u8 rhs = read_apu_byte(direct_page_addr(g_x));
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xa7: {  // SBC A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                const u8 rhs = read_apu_byte(addr);
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xa9: {  // SBC dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 source_addr = g_apu_ram[g_pc];
                const u8 rhs = read_apu_byte(direct_page_addr(source_addr));
                const u8 dest_addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 dest = direct_page_addr(dest_addr);
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = read_apu_byte(dest);
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                write_apu_byte(dest, static_cast<u8>(result & 0xff));
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xb4: {  // SBC A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u8 rhs = read_apu_byte(static_cast<u16>(dp_base + addr));
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xab: {  // INC dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(g_apu_ram[effective] + 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xac: {  // INC abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 value = static_cast<u8>(read_apu_byte(addr) + 1);
                write_apu_byte(addr, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xbc: {  // INC A
                g_a = static_cast<u8>(g_a + 1);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xc8: {  // CMP X,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                set_cmp_flags(g_x, g_apu_ram[g_pc]);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xc5: {  // MOV abs,A
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                write_apu_byte(addr, g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xc9: {  // MOV abs,X
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                write_apu_byte(addr, g_x);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xcc: {  // MOV abs,Y
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                write_apu_byte(addr, g_y);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xca: {  // MOV1 mem.bit,C
                const u16 operand = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(operand & 0x1fff);
                const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                u8 value = g_apu_ram[addr];
                if ((g_psw & 0x01) != 0) {
                    value = static_cast<u8>(value | (1u << bit));
                } else {
                    value = static_cast<u8>(value & ~(1u << bit));
                }
                write_apu_byte(addr, value);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xbb: {  // INC dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 effective = static_cast<u16>(dp_base + addr);
                const u8 value = static_cast<u8>(g_apu_ram[effective] + 1);
                write_apu_byte(effective, value);
                set_nz_8(value);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xbd: {  // MOV SP,X
                g_sp = g_x;
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xad: {  // CMP Y,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                set_cmp_flags(g_y, g_apu_ram[g_pc]);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xae: {  // POP A
                g_a = pop_byte();
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xce: {  // POP X
                g_x = pop_byte();
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xee: {  // POP Y
                g_y = pop_byte();
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xed: {  // NOTC
                g_psw = static_cast<u8>(g_psw ^ 0x01);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xb0: {  // BCS rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x01) != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0xb5: {  // SBC A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 rhs = read_apu_byte(static_cast<u16>(base + g_x));
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xb6: {  // SBC A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u8 rhs = read_apu_byte(static_cast<u16>(base + g_y));
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xb7: {  // SBC A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                const u8 rhs = read_apu_byte(static_cast<u16>(base + g_y));
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = g_a;
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                g_a = static_cast<u8>(result & 0xff);
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xb8: {  // SBC dp,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 rhs = g_apu_ram[g_pc];
                const u8 addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                const u16 effective = direct_page_addr(addr);
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = read_apu_byte(effective);
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                write_apu_byte(effective, static_cast<u8>(result & 0xff));
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xb9: {  // SBC (X),(Y)
                const u8 rhs = read_apu_byte(direct_page_addr(g_y));
                const u16 dest = direct_page_addr(g_x);
                const u8 borrow = static_cast<u8>((g_psw & 0x01) == 0 ? 1 : 0);
                const u8 lhs = read_apu_byte(dest);
                const s16 result = static_cast<s16>(lhs) - rhs - borrow;
                write_apu_byte(dest, static_cast<u8>(result & 0xff));
                set_sbc_flags(lhs, rhs, borrow, result);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xaf: {  // MOV (X)+,A
                const u16 dp_base = direct_page_base();
                const u16 effective = static_cast<u16>(dp_base + g_x);
                g_x = static_cast<u8>(g_x + 1);
                write_apu_byte(effective, g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xcd: {  // MOV X,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                g_x = g_apu_ram[g_pc];
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xcf: {  // MUL YA
                const u16 product = static_cast<u16>(g_y * g_a);
                g_a = static_cast<u8>(product & 0xff);
                g_y = static_cast<u8>(product >> 8);
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 9 * kSpcCycle;
                break;
            }

            case 0xd0: {  // BNE rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x02) == 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0xd4: {  // MOV dp+X,A
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                write_apu_byte(static_cast<u16>(dp_base + addr), g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xd5: {  // MOV abs+X,A
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                write_apu_byte(static_cast<u16>(base + g_x), g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xd6: {  // MOV abs+Y,A
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                write_apu_byte(static_cast<u16>(base + g_y), g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xd7: {  // MOV [dp]+Y,A
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 base = read_direct_word_wrapped(g_apu_ram[g_pc]);
                write_apu_byte(static_cast<u16>(base + g_y), g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 7 * kSpcCycle;
                break;
            }

            case 0xd8: {  // MOV dp,X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                write_apu_byte(static_cast<u16>(dp_base + addr), g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xd9: {  // MOV dp+Y,X
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_y);
                write_apu_byte(direct_page_addr(addr), g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xdc: {  // DEC Y
                g_y = static_cast<u8>(g_y - 1);
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xde: {  // CBNE dp+X,rel
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const s8 rel = static_cast<s8>(g_apu_ram[static_cast<u16>(g_pc + 1)]);
                if (g_a != read_apu_byte(static_cast<u16>(dp_base + addr))) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 8 * kSpcCycle;
                } else {
                    clk_left -= 6 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 2);
                break;
            }

            case 0xdd: {  // MOV A,Y
                g_a = g_y;
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xdb: {  // MOV dp+X,Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                write_apu_byte(static_cast<u16>(dp_base + addr), g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xe0: {  // CLRV
                g_psw = static_cast<u8>(g_psw & ~(0x40 | 0x08));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xe4: {  // MOV A,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_a = read_apu_byte(static_cast<u16>(dp_base + addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xe5: {  // MOV A,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = read_apu_byte(addr);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xe6: {  // MOV A,(X)
                const u16 dp_base = direct_page_base();
                g_a = read_apu_byte(static_cast<u16>(dp_base + g_x));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xe7: {  // MOV A,[dp+X]
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                g_a = read_apu_byte(addr);
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xeb: {  // MOV Y,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_y = read_apu_byte(static_cast<u16>(dp_base + addr));
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xec: {  // MOV Y,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_y = read_apu_byte(addr);
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xe8: {  // MOV A,#imm
                g_pc = static_cast<u16>(g_pc + 1);
                g_a = g_apu_ram[g_pc];
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xe9: {  // MOV X,abs
                const u16 addr = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_x = read_apu_byte(addr);
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xea: {  // NOT1 mem.bit
                const u16 operand = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                const u16 addr = static_cast<u16>(operand & 0x1fff);
                const u8 bit = static_cast<u8>((operand >> 13) & 0x07);
                write_apu_byte(addr, static_cast<u8>(g_apu_ram[addr] ^ (1u << bit)));
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xf4: {  // MOV A,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                g_a = read_apu_byte(static_cast<u16>(dp_base + addr));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xf5: {  // MOV A,abs+X
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = read_apu_byte(static_cast<u16>(base + g_x));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xf6: {  // MOV A,abs+Y
                const u16 base = static_cast<u16>(
                    g_apu_ram[static_cast<u16>(g_pc + 1)] |
                    (static_cast<u16>(g_apu_ram[static_cast<u16>(g_pc + 2)]) << 8));
                g_a = read_apu_byte(static_cast<u16>(base + g_y));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 3);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xf7: {  // MOV A,[dp]+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 pointer = read_direct_word_wrapped(g_apu_ram[g_pc]);
                g_a = read_apu_byte(static_cast<u16>(pointer + g_y));
                set_nz_8(g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 6 * kSpcCycle;
                break;
            }

            case 0xf8: {  // MOV X,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_x = read_apu_byte(static_cast<u16>(dp_base + addr));
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xf9: {  // MOV X,dp+Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_y);
                g_x = read_apu_byte(direct_page_addr(addr));
                set_nz_8(g_x);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xfa: {  // MOV dp,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 source_addr = g_apu_ram[g_pc];
                const u8 value = read_apu_byte(static_cast<u16>(dp_base + source_addr));
                const u8 dest_addr = g_apu_ram[static_cast<u16>(g_pc + 1)];
                write_apu_byte(static_cast<u16>(dp_base + dest_addr), value);
                g_pc = static_cast<u16>(g_pc + 2);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xfb: {  // MOV Y,dp+X
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                g_y = read_apu_byte(static_cast<u16>(dp_base + addr));
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xfc: {  // INC Y
                g_y = static_cast<u8>(g_y + 1);
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xfd: {  // MOV Y,A
                g_y = g_a;
                set_nz_8(g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 2 * kSpcCycle;
                break;
            }

            case 0xf0: {  // BEQ rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                if ((g_psw & 0x02) != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 4 * kSpcCycle;
                } else {
                    clk_left -= 2 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0xfe: {  // DBNZ Y,rel
                g_pc = static_cast<u16>(g_pc + 1);
                const s8 rel = static_cast<s8>(g_apu_ram[g_pc]);
                g_y = static_cast<u8>(g_y - 1);
                if (g_y != 0) {
                    g_pc = static_cast<u16>(g_pc + rel);
                    clk_left -= 6 * kSpcCycle;
                } else {
                    clk_left -= 4 * kSpcCycle;
                }
                g_pc = static_cast<u16>(g_pc + 1);
                break;
            }

            case 0xcb: {  // MOV dp,Y
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                write_apu_byte(static_cast<u16>(dp_base + addr), g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xba: {  // MOVW YA,dp
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                g_a = read_apu_byte(static_cast<u16>(dp_base + addr));
                g_y = read_apu_byte(static_cast<u16>(dp_base + static_cast<u8>(addr + 1)));
                set_nz_16(static_cast<u16>(g_a | (static_cast<u16>(g_y) << 8)));
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xc4: {  // MOV dp,A
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                write_apu_byte(static_cast<u16>(dp_base + addr), g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xc6: {  // MOV (X),A
                write_apu_byte(direct_page_addr(g_x), g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 4 * kSpcCycle;
                break;
            }

            case 0xc7: {  // MOV [dp+X],A
                g_pc = static_cast<u16>(g_pc + 1);
                const u8 pointer = static_cast<u8>(g_apu_ram[g_pc] + g_x);
                const u16 addr = read_direct_word_wrapped(pointer);
                write_apu_byte(addr, g_a);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 7 * kSpcCycle;
                break;
            }

            case 0xda: {  // MOVW dp,YA
                g_pc = static_cast<u16>(g_pc + 1);
                const u16 dp_base = direct_page_base();
                const u8 addr = g_apu_ram[g_pc];
                write_apu_byte(static_cast<u16>(dp_base + addr), g_a);
                write_apu_byte(static_cast<u16>(dp_base + static_cast<u8>(addr + 1)), g_y);
                g_pc = static_cast<u16>(g_pc + 1);
                clk_left -= 5 * kSpcCycle;
                break;
            }

            case 0xef: {  // SLEEP
                if ((portMod & 0x80) == 0) {
                    portMod = 0;
                }
                if ((portMod & 0x0f) != 0) {
                    portMod = 0;
                    g_pc = static_cast<u16>(g_pc + 1);
                } else {
                    portMod = static_cast<u8>(portMod | 0x80);
                }
                clk_left -= 3 * kSpcCycle;
                break;
            }

            case 0xff: {  // STOP
                clk_left -= 3 * kSpcCycle;
                break;
            }

            default:
                if (std::getenv("SNESAPU_TRACE_UNIMPLEMENTED")) {
                    static u32 trace_count = 0;
                    if (trace_count < 64) {
                        std::fprintf(stderr,
                                     "unimplemented_spc opcode=0x%02x pc=0x%04x a=0x%02x y=0x%02x x=0x%02x psw=0x%02x sp=0x%02x t64=0x%08x clk_left=%d\n",
                                     opcode,
                                     g_pc,
                                     g_a,
                                     g_y,
                                     g_x,
                                     g_psw,
                                     g_sp,
                                     t64Cnt,
                                     clk_left);
                        ++trace_count;
                    }
                }
                return clk_left;
        }
        advance_timers(static_cast<u32>(before - clk_left));
        catch_up_dsp();
    }
    return clk_left;
}

void reset_script700() {
    std::fill(scr700dsp, scr700dsp + 256, 0);
    std::fill(scr700mds, scr700mds + 32, 0);
    for (u32 i = 0; i < 256; ++i) {
        scr700chg[i] = static_cast<u8>(i);
    }
    std::fill(scr700det, scr700det + 256, 0);
    std::fill(scr700vol, scr700vol + 256, 0);
    std::fill(scr700mvl, scr700mvl + 32, 0);
    std::fill(scr700wrk, scr700wrk + 8, 0);
    std::fill(scr700cmp, scr700cmp + 2, 0);
    scr700cnt = 0;
    scr700ptr = 0;
    scr700stf = 0;
    scr700int[0] = 0;
    scr700int[1] = 0;
    scr700dat = 0;
    scr700stp = 0;
}

struct Arm64Context {
    std::array<u8, APURAMSIZE> apu_ram;
    std::array<u8, 64> extra_ram;
    std::array<u8, 4> out_port;
    std::array<u8, 4> in_port_cp;
    std::array<u8, 4> out_port_cp;
    std::array<u8, 4> flush_port;
    DSPReg dsp_regs;
    std::array<Voice, 8> voices;
    u32 t64_count;
    u32 t64_remaining;
    u32 t8_remaining;
    u16 pc;
    u8 a;
    u8 y;
    u8 x;
    u8 psw;
    u8 sp;
    u8 raw_chn;
    u8 raw_bits;
    u8 raw_byte;
    u8 dsp_mix;
    u8 dsp_chn;
    u8 dsp_size;
    u8 dsp_inter;
    u8 voice_mix;
    u8 dsp_mute;
    std::array<u8, 8> kon_skip_decrement;
    float aaf_state_left;
    float aaf_state_right;
    float main_target_left;
    float main_target_right;
    float echo_target_left;
    float echo_target_right;
    float main_current_left;
    float main_current_right;
    float echo_current_left;
    float echo_current_right;
    float echo_feedback;
    float echo_feedback_crosstalk;
    u32 raw_rate;
    u32 dsp_options;
    u32 speed;
    u32 pitch;
    u32 amp;
    u32 volume;
    u32 stereo;
    s32 efbct;
    u32 song_len;
    u32 fade_len;
    u8 port_mod;
    u8 timer_control;
    u8 t0_step;
    u8 t1_step;
    u8 t2_step;
};

}  // namespace

extern "C" {

u32 apuOpt = kApuOptions;
u8 scr700dsp[256] {};
u8 scr700mds[32] {};
u8 scr700chg[256] {};
u32 scr700det[256] {};
u32 scr700vol[256] {};
u32 scr700mvl[32] {};
u32 scr700wrk[8] {};
u32 scr700cmp[2] {};
u32 scr700cnt = 0;
u32 scr700ptr = 0;
u8 scr700stf = 0;
u8 scr700int[2] {};
u32 scr700dat = 0;
uptr scr700stp = 0;
uptr pAPURAM = reinterpret_cast<uptr>(g_apu_ram.data());
uptr pSCRRAM = reinterpret_cast<uptr>(g_script_ram.data());

u8 extraRAM[64] {};
u8 outPort[4] {};
u8 inPortCp[4] {};
u8 outPortCp[4] {};
u8 flushPort[4] {};
u8 portMod = 0;
u8 tControl = 0;
u32 t64Cnt = 0;
uptr pSPCReg = reinterpret_cast<uptr>(g_spc_reg_buffer.data());

DSPReg dsp {};
Voice mix[8] {};
u32 vMMaxL = 0;
u32 vMMaxR = 0;

u32 cycLeft = 0;
u32 smpDec = 0;
u32 smpRate = kDefaultRate;
u32 smpRAdj = kDefaultSpeed;
u32 smpREmu = kDefaultRate;
u32 outCur = 0;
u32 outLen = 0;
u32 apuOutBufGuard = 0xC0DEFACE;
u32 apuDbgStage = 0;
uptr apuDbgLastBuf = 0;
u32 apuDbgLastLen = 0;
u32 apuDbgLastType = 0;
uptr apuDbgSampleBuf = 0;
u32 apuDbgSampleLen = 0;
u32 apuCbMask = 0;
uptr apuCbFunc = 0;

u32 InitAPU(u32 reason) {
    if (reason != 1) {
        return 1;
    }

    apuDbgStage = 0x100;
    pAPURAM = reinterpret_cast<uptr>(g_apu_ram.data());
    pSCRRAM = reinterpret_cast<uptr>(g_script_ram.data());
    pSPCReg = reinterpret_cast<uptr>(g_spc_reg_buffer.data());
    apuOutBufGuard = 0xC0DEFACE;
    apuCbMask = 0;
    apuCbFunc = 0;
    g_callback = nullptr;
    g_callback_mask = 0;
    InitSPC();
    InitDSP();
    smpRate = kDefaultRate;
    smpRAdj = kDefaultSpeed;
    smpREmu = kDefaultRate;
    rawChn = static_cast<u8>(kDefaultChannels);
    rawBits = static_cast<u8>(kDefaultBits);
    rawByte = 4;
    rawRate = kDefaultRate;
    SetAPUSmpClk(kDefaultSpeed);
    ResetAPU(kDefaultAmp);
    SetScript700(nullptr);
    apuDbgStage = 0x12f;
    return 1;
}

void SNESAPUInfo(u32 *pVer, u32 *pMin, u32 *pOpt) {
    if (pVer) {
        *pVer = kApuVersion;
    }
    if (pMin) {
        *pMin = kApuCompatibleVersion;
    }
    if (pOpt) {
        *pOpt = apuOpt;
    }
}

CBFUNC SNESAPUCallback(CBFUNC pCbFunc, u32 cbMask) {
    CBFUNC previous = g_callback;
    g_callback = pCbFunc;
    g_callback_mask |= cbMask;
    apuCbFunc = reinterpret_cast<uptr>(pCbFunc);
    apuCbMask |= cbMask;
    return previous;
}

void GetAPUData(u8 **ppRAM, u8 **ppXRAM, u8 **ppOutPort, u32 **ppT64Cnt, DSPReg **ppDSP, Voice **ppVoice, u32 **ppVMMaxL, u32 **ppVMMaxR) {
    if (ppRAM) {
        *ppRAM = reinterpret_cast<u8 *>(pAPURAM);
    }
    if (ppXRAM) {
        *ppXRAM = extraRAM;
    }
    if (ppOutPort) {
        *ppOutPort = outPort;
    }
    if (ppT64Cnt) {
        *ppT64Cnt = &t64Cnt;
    }
    if (ppDSP) {
        *ppDSP = &dsp;
    }
    if (ppVoice) {
        *ppVoice = mix;
    }
    if (ppVMMaxL) {
        *ppVMMaxL = &vMMaxL;
    }
    if (ppVMMaxR) {
        *ppVMMaxR = &vMMaxR;
    }
}

u32 SNESAPUArm64DebugEcho(u32 *meta, float *echo, u32 echo_pairs, float *fir, u32 fir_pairs) {
    const size_t echo_index = g_echo_remaining == 0 || g_echo_remaining > g_echo_len
        ? 0
        : g_echo_len - g_echo_remaining;
    size_t echo_start = echo_index;
    if (const char *back_text = std::getenv("SNESAPU_DUMP_ECHO_BACK_PAIRS")) {
        char *end = nullptr;
        const unsigned long back = std::strtoul(back_text, &end, 0);
        if (end && *end == '\0' && g_echo_len != 0) {
            echo_start = (echo_index + g_echo_len - (back % g_echo_len)) % g_echo_len;
        }
    }
    if (meta) {
        meta[0] = static_cast<u32>(g_echo_len * 8u);
        meta[1] = static_cast<u32>(g_echo_pending_len * 8u);
        meta[2] = static_cast<u32>(g_echo_remaining * 8u);
        meta[3] = static_cast<u32>(echo_start * 8u);
        meta[4] = static_cast<u32>(g_fir_pos);
        meta[5] = static_cast<u32>(g_echo_mem_len * 4u);
        meta[6] = static_cast<u32>(g_echo_mem_pos * 4u);
        meta[7] = static_cast<u32>(g_echo_mem_dec);
    }
    if (echo) {
        for (u32 i = 0; i < echo_pairs; ++i) {
            const size_t index = (echo_start + i) % g_echo_len;
            echo[i * 2] = g_echo_left[index];
            echo[i * 2 + 1] = g_echo_right[index];
        }
    }
    if (fir) {
        for (u32 i = 0; i < fir_pairs; ++i) {
            const size_t index = (g_fir_pos + i) & 7u;
            fir[i * 2] = g_fir_left[index];
            fir[i * 2 + 1] = g_fir_right[index];
        }
    }
    return 1;
}

u32 SNESAPUArm64DebugVolumes(float *values, u32 count) {
    if (!values || count < 8) {
        return 0;
    }
    values[0] = g_main_current_left;
    values[1] = g_main_current_right;
    values[2] = g_echo_current_left;
    values[3] = g_echo_current_right;
    values[4] = g_main_target_left;
    values[5] = g_main_target_right;
    values[6] = g_echo_target_left;
    values[7] = g_echo_target_right;
    return 1;
}

u32 SNESAPUArm64DebugLastMix(float *values, u32 count) {
    if (!values || count < 2) {
        return 0;
    }
    values[0] = g_debug_last_mix_left;
    values[1] = g_debug_last_mix_right;
    return 1;
}

void GetScript700Data(char *pDLLVer, uptr **ppSPCReg, u8 **ppScript700) {
    if (pDLLVer) {
        std::memcpy(pDLLVer, g_version_string.data(), g_version_string.size());
    }
    if (ppSPCReg) {
        *ppSPCReg = reinterpret_cast<uptr *>(pSPCReg);
    }
    if (ppScript700) {
        *ppScript700 = reinterpret_cast<u8 *>(scr700wrk);
    }
}

void InitSPC() {
    pSPCReg = reinterpret_cast<uptr>(g_spc_reg_buffer.data());
}

void ResetSPC() {
    std::fill(g_apu_ram.begin(), g_apu_ram.end(), 0);
    std::fill(extraRAM, extraRAM + 64, 0);
    std::fill(outPort, outPort + 4, 0);
    std::fill(inPortCp, inPortCp + 4, 0);
    std::fill(outPortCp, outPortCp + 4, 0);
    std::fill(flushPort, flushPort + 4, 0);
    std::fill(g_spc_reg_buffer.begin(), g_spc_reg_buffer.end(), 0);
    portMod = 0;
    tControl = 0;
    t64Cnt = 0;
    g_t64_remaining = kT64Cycles - 1;
    g_t8_remaining = kT8Cycles - 1;
    g_t0_step = 0xff;
    g_t1_step = 0xff;
    g_t2_step = 0xff;
    g_pc = 0;
    g_a = 0;
    g_y = 0;
    g_x = 0;
    g_psw = 0;
    g_sp = 0xff;
}

SPCDebug *SetSPCDbg(SPCDebug *pTrace, u32 opts) {
    SPCDebug *previous = g_spc_debug;
    if (pTrace != reinterpret_cast<SPCDebug *>(static_cast<uptr>(~0ULL))) {
        g_spc_debug = pTrace;
    }
    if (opts != static_cast<u32>(~0U)) {
        g_spc_debug_opts = opts;
    }
    return previous;
}

void FixSPC(u16 pc, u8 a, u8 y, u8 x, u8 psw, u8 sp) {
    g_pc = pc;
    g_a = a;
    g_y = y;
    g_x = x;
    g_psw = psw;
    g_sp = sp;
    update_spc_reg_buffer();
    std::copy(g_apu_ram.begin() + 0x00f4, g_apu_ram.begin() + 0x00f8, inPortCp);
    std::copy(g_apu_ram.begin() + 0x00f4, g_apu_ram.begin() + 0x00f8, outPortCp);
    std::copy(g_apu_ram.begin() + 0x00f4, g_apu_ram.begin() + 0x00f8, flushPort);
    tControl = static_cast<u8>(g_apu_ram[0x00f1] & 0x87);
    g_apu_ram[0x00f1] = tControl;
    g_t0_step = timer_target_step(0x00fau);
    g_t1_step = timer_target_step(0x00fbu);
    g_t2_step = timer_target_step(0x00fcu);
}

void GetSPCRegs(u16 *pPC, u8 *pA, u8 *pY, u8 *pX, u8 *pPSW, u8 *pSP) {
    if (pPC) {
        *pPC = g_pc;
    }
    if (pA) {
        *pA = g_a;
    }
    if (pY) {
        *pY = g_y;
    }
    if (pX) {
        *pX = g_x;
    }
    if (pPSW) {
        *pPSW = g_psw;
    }
    if (pSP) {
        *pSP = g_sp;
    }
}

void SetAPURAM(u32 addr, u8 val) {
    g_apu_ram[addr & 0xffffu] = val;
}

void InPort(u8 port, u8 val) {
    if (port < 4) {
        const u8 mask = static_cast<u8>(1u << port);
        portMod = static_cast<u8>(portMod | mask);
        inPortCp[port] = val;
        flushPort[port] = val;
        g_apu_ram[0xf4u + port] = val;
    }
}

s32 EmuSPC(s32 cyc) {
    if (cyc <= 0) {
        return cyc;
    }
    const s32 remaining = execute_spc700(cyc);
    update_spc_reg_buffer();
    return remaining;
}

void InitDSP() {
    ResetDSP();
    SetDSPOpt(MIX_INT, 2, 16, kDefaultRate, INT_GAUSS, 0);
    SetDSPDbg(nullptr);
}

void ResetDSP() {
    std::array<u8, 8> user_flags {};
    for (size_t i = 0; i < user_flags.size(); ++i) {
        user_flags[i] = static_cast<u8>(mix[i].mFlg & MFLG_USER);
    }

    std::memset(&dsp, 0, sizeof(dsp));
    std::memset(mix, 0, sizeof(mix));
    dsp.flg = static_cast<s8>(0xe0);
    for (size_t i = 0; i < user_flags.size(); ++i) {
        mix[i].mFlg = static_cast<u8>(user_flags[i] | MFLG_OFF);
    }
    vMMaxL = 0;
    vMMaxR = 0;
    voiceMix = 0;
    dspMute = 0;
    disFlag = 0;
    dspPMod = 0;
    dspNoise = 0;
    dspNoiseF = 0;
    konRsv = 0;
    koffRsv = 0;
    g_main_target_left = 0.0f;
    g_main_target_right = 0.0f;
    g_echo_target_left = 0.0f;
    g_echo_target_right = 0.0f;
    g_main_current_left = 0.0f;
    g_main_current_right = 0.0f;
    g_echo_current_left = 0.0f;
    g_echo_current_right = 0.0f;
    g_echo_feedback = 0.0f;
    g_echo_feedback_crosstalk = 0.0f;
    g_kon_skip_decrement.fill(0);
    rebuild_rate_table();
    reset_noise_state();
    reset_analog_filter_state();
    update_noise_rate_from_flg();
    update_stereo_state();
    rebuild_analog_filter();
    update_echo_length();
    reset_echo_state();
}

void SetDSPOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
    const u8 previous_raw_channels = rawChn;
    const u8 previous_mix = dspMix;
    const u32 previous_rate = rawRate;
    const u32 previous_options = dspOpts;

    if (num_channels != static_cast<u32>(~0U)) {
        rawChn = num_channels == 1 ? 1 : 2;
        dspChn = rawChn;
    }

    if (bits != static_cast<u32>(~0U)) {
        const s32 signed_bits = sanitized_bits(bits);
        rawBits = static_cast<u8>(signed_bits);
        dspSize = rawBits;
    }

    if (rate != static_cast<u32>(~0U)) {
        rawRate = (rate >= 8000 && rate <= 192000) ? rate : kDefaultRate;
    }

    if (inter != static_cast<u32>(~0U)) {
        switch (inter) {
            case INT_NONE:
            case INT_LINEAR:
            case INT_CUBIC:
            case INT_GAUSS:
            case INT_SINC:
            case INT_GAUSS4:
                dspInter = static_cast<u8>(inter);
                break;
            default:
                dspInter = INT_GAUSS;
                break;
        }
    }

    if (opts != static_cast<u32>(~0U)) {
        dspOpts = opts;
    }

    if (mix_type != static_cast<u32>(~0U)) {
        dspMix = static_cast<u8>(mix_type);
    }

    rebuild_rate_table();
    rebuild_pitch_adjustment();
    rebuild_analog_filter();
    update_noise_rate_from_flg();
    update_forced_noise_rate();
    update_echo_length();
    update_stereo_state();
    for (u8 i = 0; i < 8; ++i) {
        Voice &voice = mix[i];
        set_envelope_rate(voice, voice.eRIdx);
        if ((voice.mFlg & MFLG_OFF) == 0) {
            set_voice_pitch(i);
        }
    }
    const u32 volume_option_mask = DSP_SURND | DSP_NOSURND | DSP_REVERSE;
    const bool reset_channel_volumes =
        rawChn != previous_raw_channels ||
        dspMix != previous_mix ||
        rawRate != previous_rate ||
        ((dspOpts ^ previous_options) & volume_option_mask) != 0;
    if (reset_channel_volumes) {
        snap_all_voice_volumes_to_targets();
        snap_global_volumes_to_targets();
    } else {
        update_global_volume_targets();
    }

    rawByte = static_cast<u8>(bytes_per_frame());
    outCur = 0;
    outLen = 0;
}

DSPDebug *SetDSPDbg(DSPDebug *pTrace) {
    DSPDebug *previous = g_dsp_debug;
    g_dsp_debug = pTrace;
    return previous;
}

void FixDSP() {
    voiceMix = 0;
    snap_global_volumes_to_targets();
    update_noise_rate_from_flg();
    update_echo_feedback();
    update_echo_length();
    reset_echo_buffers();
    catch_key_on_load(dsp.kon);
    vMMaxL = 0;
    vMMaxR = 0;
}

void FixSeek(u8 reset) {
    if (reset) {
        dsp.endx = dsp.kon;
        dsp.kon = 0;
        dsp.kof = 0;
        voiceMix = 0;
        konRsv = 0;
        koffRsv = 0;
        g_deferred_key_on_mask = 0;
        g_defer_key_on_reset = false;
        g_kon_skip_decrement.fill(0);
        for (u8 i = 0; i < 8; ++i) {
            Voice &voice = mix[i];
            voice.eVal = 0;
            voice.mOut = 0;
            voice.mFlg = static_cast<u8>((voice.mFlg & MFLG_USER) | MFLG_OFF);
            voice.mKOn = 0;
            voice.vRsv = 0;
            dsp.voice[i].envx = 0;
            dsp.voice[i].outx = 0;
        }
        FixDSP();
    }
    reset_echo_buffers();
    reset_analog_filter_state();
    apply_fade_volume();
}

void SetDSPPitch(u32 base) {
    g_pitch = base ? base : kDefaultPitch;
    rebuild_pitch_adjustment();
    for (u8 i = 0; i < 8; ++i) {
        set_voice_pitch(i);
    }
}

void SetDSPAmp(u32 level) {
    g_amp = level <= 256 ? level << 12 : level;
    snap_global_volumes_to_targets();
}

void SetDSPVol(u32 vol) {
    g_volume = vol;
    update_global_volume_targets();
}

void apply_fade_volume_at(u32 now_t64) {
    if (g_song_len == static_cast<u32>(~0U)) {
        return;
    }
    const u32 fade_len = g_fade_len == 0 ? 1 : g_fade_len;
    if (now_t64 <= g_song_len) {
        return;
    }

    const u32 elapsed = now_t64 - g_song_len;
    u32 volume = 0;
    if (elapsed < fade_len) {
        const double phase =
            (static_cast<double>(elapsed) / static_cast<double>(fade_len)) *
            (kPi * 0.5);
        const s32 faded = static_cast<s32>(std::lrint(std::sin(phase) * 65536.0));
        volume = static_cast<u32>(std::max<s32>(0, 65536 - faded));
    }
    SetDSPVol(volume);
}

void apply_fade_volume() {
    apply_fade_volume_at(t64Cnt);
}

void SetDSPStereo(u32 sep) {
    g_stereo = sep;
    snap_all_voice_volumes_to_targets();
}

void SetDSPEFBCT(s32 leak) {
    g_efbct = leak + 32768;
    update_echo_feedback();
}

b8 SetDSPReg(u8 reg, u8 val) {
    apply_dsp_register_write(reg, val);
    return 1;
}

void *EmuDSP(void *pBuf, s32 size) {
    if (size <= 0) {
        return pBuf;
    }
    render_dsp_samples(pBuf, static_cast<u32>(size));
    refresh_dsp_data_register();
    auto *out = static_cast<u8 *>(pBuf);
    return out ? out + static_cast<size_t>(size) * bytes_per_frame() : nullptr;
}

void ResetAPU(u32 amp) {
    ResetSPC();
    ResetDSP();
    if (amp != static_cast<u32>(~0U)) {
        SetDSPAmp(amp);
    }
    cycLeft = 0;
    smpDec = 0;
    outCur = 0;
    outLen = 0;
}

void FixAPU(u16 pc, u8 a, u8 y, u8 x, u8 psw, u8 sp) {
    FixSPC(pc, a, y, x, psw, sp);
    FixDSP();
}

void LoadSPCFile(void *pFile) {
    const auto *spc = static_cast<const u8 *>(pFile);
    ResetAPU(static_cast<u32>(~0U));
    std::memcpy(g_apu_ram.data(), spc + 0x100, APURAMSIZE);
    std::memcpy(&dsp, spc + 0x10100, sizeof(DSPReg));
    std::memcpy(extraRAM, spc + 0x101c0, sizeof(extraRAM));
    FixAPU(
        static_cast<u16>(spc[0x25] | (static_cast<u16>(spc[0x26]) << 8)),
        spc[0x27],
        spc[0x29],
        spc[0x28],
        spc[0x2a],
        spc[0x2b]);
}

void SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
    SetDSPOpt(mix_type, num_channels, bits, rate, inter, opts);
}

void SetAPUSmpClk(u32 speed) {
    if (speed == 0) {
        speed = kDefaultSpeed;
    }
    g_speed = std::clamp<u32>(speed, 1024u, 1048576u);
    smpRAdj = g_speed;
    smpRate = rawRate;
    smpREmu = rawRate;
}

u32 SetAPULength(u32 song, u32 fade) {
    g_song_len = song;
    g_fade_len = fade == 0 ? 1 : fade;
    if (song == static_cast<u32>(~0U)) {
        return song;
    }
    if (t64Cnt <= g_song_len) {
        SetDSPVol(65536);
    } else {
        apply_fade_volume();
    }
    return song + g_fade_len;
}

void *EmuAPU(void *pBuf, u32 len, u8 type) {
    apuDbgLastBuf = reinterpret_cast<uptr>(pBuf);
    apuDbgLastLen = len;
    apuDbgLastType = type;
    const bool cycle_units = type == 0 || (type & 0x80u) != 0;
    const u32 cycles = cycle_units
        ? len
        : (rawRate == 0
            ? 0
            : static_cast<u32>((static_cast<u64>(len) * kApuClock) / rawRate));
    const u32 samples = cycle_units ? samples_for_cycles(cycles) : len;
    const size_t bytes = static_cast<size_t>(samples) * bytes_per_frame();
    clear_auto_dsp();
    if (samples == 0) {
        run_spc_for_apu_cycles(cycles);
        apply_fade_volume();
        return pBuf ? static_cast<u8 *>(pBuf) + bytes : nullptr;
    }

    set_auto_dsp(pBuf, samples, rawRate);
    run_spc_for_apu_cycles(cycles);
    u8 *end = finish_auto_dsp();
    apply_fade_volume();
    refresh_dsp_data_register();
    if (type != 0 && (type & 0x80u) == 0) {
        apuDbgSampleBuf = reinterpret_cast<uptr>(pBuf);
        apuDbgSampleLen = len;
    }
    return end ? end : (pBuf ? static_cast<u8 *>(pBuf) + bytes : nullptr);
}

void SeekAPU(u32 time, b8 fast) {
    if (time == 0) {
        return;
    }

    const u32 seconds = time / 64000u;
    const u32 partial_cycles = (time % 64000u) * kT64Cycles;

    if (fast) {
        SetSPCDbg(reinterpret_cast<SPCDebug *>(static_cast<uptr>(~0ULL)), SPC_NODSP);
        if (partial_cycles != 0) {
            EmuSPC(static_cast<s32>(partial_cycles));
        }
        for (u32 i = 0; i < seconds; ++i) {
            EmuSPC(static_cast<s32>(kApuClock));
        }
        SetSPCDbg(reinterpret_cast<SPCDebug *>(static_cast<uptr>(~0ULL)), 0);
        FixSeek(1);
        return;
    }

    const u32 saved_options = dspOpts;
    const u32 saved_speed = smpRAdj;
    u32 seek_speed = saved_speed;
    if ((seek_speed >> 16) == 0) {
        seek_speed = kDefaultSpeed;
    }

    SetAPUOpt(
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        saved_options | DSP_ENVSPD | DSP_NOSAFE);

    if (partial_cycles != 0) {
        SetAPUSmpClk(seek_speed);
        EmuAPU(nullptr, partial_cycles, 0xff);
    }

    for (u32 remaining = seconds; remaining != 0; --remaining) {
        SetAPUSmpClk(remaining == 1 ? saved_speed : 0xffffffffu);
        EmuAPU(nullptr, kApuClock, 0xff);
    }

    SetAPUSmpClk(saved_speed);
    SetAPUOpt(
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        static_cast<u32>(~0U),
        saved_options);
    FixSeek(0);
}

void SetTimerTrick(u32, u32) {}

s32 SetScript700(void *pSource) {
    if (!pSource) {
        reset_script700();
        return 0;
    }
    scr700stf = 0x20;
    return 1;
}

s32 SetScript700Data(u32 addr, void *pData, u32 size) {
    if (!pData || addr >= g_script_ram.size()) {
        return 0;
    }
    const size_t count = std::min<size_t>(size, g_script_ram.size() - addr);
    std::memcpy(g_script_ram.data() + addr, pData, count);
    scr700dat = addr;
    return static_cast<s32>(addr + count);
}

u32 GetSNESAPUContextSize() {
    return static_cast<u32>(sizeof(Arm64Context));
}

u32 GetSNESAPUContext(void *pCtxOut) {
    if (!pCtxOut) {
        return 0;
    }
    auto *ctx = static_cast<Arm64Context *>(pCtxOut);
    ctx->apu_ram = g_apu_ram;
    std::copy(extraRAM, extraRAM + 64, ctx->extra_ram.begin());
    std::copy(outPort, outPort + 4, ctx->out_port.begin());
    std::copy(inPortCp, inPortCp + 4, ctx->in_port_cp.begin());
    std::copy(outPortCp, outPortCp + 4, ctx->out_port_cp.begin());
    std::copy(flushPort, flushPort + 4, ctx->flush_port.begin());
    ctx->dsp_regs = dsp;
    std::copy(mix, mix + 8, ctx->voices.begin());
    ctx->t64_count = t64Cnt;
    ctx->t64_remaining = g_t64_remaining;
    ctx->t8_remaining = g_t8_remaining;
    ctx->pc = g_pc;
    ctx->a = g_a;
    ctx->y = g_y;
    ctx->x = g_x;
    ctx->psw = g_psw;
    ctx->sp = g_sp;
    ctx->raw_chn = rawChn;
    ctx->raw_bits = rawBits;
    ctx->raw_byte = rawByte;
    ctx->dsp_mix = dspMix;
    ctx->dsp_chn = dspChn;
    ctx->dsp_size = dspSize;
    ctx->dsp_inter = dspInter;
    ctx->voice_mix = voiceMix;
    ctx->dsp_mute = dspMute;
    ctx->kon_skip_decrement = g_kon_skip_decrement;
    ctx->aaf_state_left = g_aaf_state_left;
    ctx->aaf_state_right = g_aaf_state_right;
    ctx->main_target_left = g_main_target_left;
    ctx->main_target_right = g_main_target_right;
    ctx->echo_target_left = g_echo_target_left;
    ctx->echo_target_right = g_echo_target_right;
    ctx->main_current_left = g_main_current_left;
    ctx->main_current_right = g_main_current_right;
    ctx->echo_current_left = g_echo_current_left;
    ctx->echo_current_right = g_echo_current_right;
    ctx->echo_feedback = g_echo_feedback;
    ctx->echo_feedback_crosstalk = g_echo_feedback_crosstalk;
    ctx->raw_rate = rawRate;
    ctx->dsp_options = dspOpts;
    ctx->speed = g_speed;
    ctx->pitch = g_pitch;
    ctx->amp = g_amp;
    ctx->volume = g_volume;
    ctx->stereo = g_stereo;
    ctx->efbct = g_efbct;
    ctx->song_len = g_song_len;
    ctx->fade_len = g_fade_len;
    ctx->port_mod = portMod;
    ctx->timer_control = tControl;
    ctx->t0_step = g_t0_step;
    ctx->t1_step = g_t1_step;
    ctx->t2_step = g_t2_step;
    return 0;
}

u32 SetSNESAPUContext(void *pCtxIn) {
    if (!pCtxIn) {
        return 0;
    }
    const auto *ctx = static_cast<const Arm64Context *>(pCtxIn);
    g_apu_ram = ctx->apu_ram;
    std::copy(ctx->extra_ram.begin(), ctx->extra_ram.end(), extraRAM);
    std::copy(ctx->out_port.begin(), ctx->out_port.end(), outPort);
    std::copy(ctx->in_port_cp.begin(), ctx->in_port_cp.end(), inPortCp);
    std::copy(ctx->out_port_cp.begin(), ctx->out_port_cp.end(), outPortCp);
    std::copy(ctx->flush_port.begin(), ctx->flush_port.end(), flushPort);
    dsp = ctx->dsp_regs;
    std::copy(ctx->voices.begin(), ctx->voices.end(), mix);
    t64Cnt = ctx->t64_count;
    g_t64_remaining = ctx->t64_remaining;
    g_t8_remaining = ctx->t8_remaining;
    FixSPC(ctx->pc, ctx->a, ctx->y, ctx->x, ctx->psw, ctx->sp);
    rawChn = ctx->raw_chn;
    rawBits = ctx->raw_bits;
    rawByte = ctx->raw_byte;
    dspMix = ctx->dsp_mix;
    dspChn = ctx->dsp_chn;
    dspSize = ctx->dsp_size;
    dspInter = ctx->dsp_inter;
    voiceMix = ctx->voice_mix;
    dspMute = ctx->dsp_mute;
    g_kon_skip_decrement = ctx->kon_skip_decrement;
    g_aaf_state_left = ctx->aaf_state_left;
    g_aaf_state_right = ctx->aaf_state_right;
    g_main_target_left = ctx->main_target_left;
    g_main_target_right = ctx->main_target_right;
    g_echo_target_left = ctx->echo_target_left;
    g_echo_target_right = ctx->echo_target_right;
    g_main_current_left = ctx->main_current_left;
    g_main_current_right = ctx->main_current_right;
    g_echo_current_left = ctx->echo_current_left;
    g_echo_current_right = ctx->echo_current_right;
    g_echo_feedback = ctx->echo_feedback;
    g_echo_feedback_crosstalk = ctx->echo_feedback_crosstalk;
    rawRate = ctx->raw_rate;
    dspOpts = ctx->dsp_options;
    g_speed = ctx->speed;
    g_pitch = ctx->pitch;
    g_amp = ctx->amp;
    g_volume = ctx->volume;
    g_stereo = ctx->stereo;
    g_efbct = ctx->efbct;
    g_song_len = ctx->song_len;
    g_fade_len = ctx->fade_len;
    portMod = ctx->port_mod;
    tControl = ctx->timer_control;
    g_t0_step = ctx->t0_step;
    g_t1_step = ctx->t1_step;
    g_t2_step = ctx->t2_step;
    update_stereo_state();
    rebuild_analog_filter();
    return 0;
}

}  // extern "C"
