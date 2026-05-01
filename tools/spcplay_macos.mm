#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreServices/CoreServices.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <math.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

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
constexpr u32 kDefaultFeedback = 0;
constexpr u32 kDefaultUserDSPOpts = 0;
constexpr u32 kRequiredDSPOpts = DSP_FLOAT;
constexpr u32 kDefaultDSPOpts = kDefaultUserDSPOpts | kRequiredDSPOpts;
constexpr u32 kDefaultInterpolation = INT_GAUSS;
constexpr u32 kDefaultOutputChannels = 2;
constexpr u32 kDefaultOutputBits = 16;
constexpr size_t kSpcSize = 0x10200;
constexpr u32 kLiveWaveBufferTimeMs = 17;
constexpr size_t kLiveWaveBufferPrefillCount = 8;
constexpr size_t kLiveWaveBufferCapacityCount = 24;
constexpr size_t kCommandLineStartupPrefillCount = 20;
constexpr u32 kLiveRenderChunkCycles = (APU_CLK / 1000) * kLiveWaveBufferTimeMs;
constexpr size_t kLiveRenderSlackFrames = 64;
constexpr UInt32 kLiveAudioQueueBufferCount = 4;
constexpr UInt32 kLiveAudioQueueFramesPerBuffer = 1024;
bool gLiveSmokeDiagnostics = false;

constexpr u32 FixedPercent(u32 percent) {
    return static_cast<u32>((65536ULL * percent) / 100ULL);
}

constexpr u32 FixedBasis(u32 basisPoints) {
    return static_cast<u32>((65536ULL * basisPoints) / 10000ULL);
}

u32 PercentFromFixed(u32 value) {
    return static_cast<u32>((static_cast<uint64_t>(value) * 100ULL + 32768ULL) / 65536ULL);
}

u32 EffectiveDSPOptions(u32 userOptions) {
    return userOptions | kRequiredDSPOpts;
}

s32 FeedbackToEfbct(u32 feedback) {
    return static_cast<s32>(32768) - static_cast<s32>(feedback);
}

size_t BytesPerSampleForBits(u32 bits) {
    switch (static_cast<s32>(bits)) {
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

u32 SanitizedOutputChannels(u32 channels) {
    return channels == 1 ? 1 : 2;
}

u32 SanitizedOutputRate(u32 rate) {
    if (rate < 8000 || rate > 192000) {
        return kDefaultRate;
    }
    return rate;
}

u32 SanitizedOutputBits(u32 bits) {
    switch (static_cast<s32>(bits)) {
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

u32 SanitizedInterpolation(u32 interpolation) {
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

u32 InterpolationFromEnvironment() {
    const char *value = std::getenv("SNESAPU_INTERPOLATION");
    if (!value || !value[0]) {
        return kDefaultInterpolation;
    }

    char *end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (!end || *end != '\0') {
        return kDefaultInterpolation;
    }
    return SanitizedInterpolation(static_cast<u32>(parsed));
}

u32 EnvU32OrDefault(const char *name, u32 defaultValue) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return defaultValue;
    }

    char *end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (!end || *end != '\0') {
        return defaultValue;
    }
    return static_cast<u32>(parsed);
}

u32 EnvBitsOrDefault(const char *name, u32 defaultValue) {
    const char *value = std::getenv(name);
    if (!value || !value[0]) {
        return defaultValue;
    }

    char *end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (!end || *end != '\0') {
        return defaultValue;
    }
    return static_cast<u32>(static_cast<s32>(parsed));
}

NSString *AudioObjectStringProperty(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(objectID, &address, 0, nullptr, &size, &value);
    if (status != noErr || !value) {
        return @"";
    }
    return CFBridgingRelease(value);
}

BOOL AudioDeviceHasOutput(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &address, 0, nullptr, &size) != noErr || size == 0) {
        return NO;
    }
    std::vector<u8> data(size);
    AudioBufferList *bufferList = reinterpret_cast<AudioBufferList *>(data.data());
    if (AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, bufferList) != noErr) {
        return NO;
    }
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        if (bufferList->mBuffers[i].mNumberChannels > 0) {
            return YES;
        }
    }
    return NO;
}

NSArray<NSDictionary *> *AvailableOutputDevices() {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr || size == 0) {
        return @[];
    }

    const UInt32 count = size / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> devices(count);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, devices.data()) != noErr) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (AudioDeviceID deviceID : devices) {
        if (!AudioDeviceHasOutput(deviceID)) {
            continue;
        }
        NSString *name = AudioObjectStringProperty(deviceID, kAudioObjectPropertyName);
        if (name.length == 0) {
            name = [NSString stringWithFormat:@"Device %u", deviceID];
        }
        [result addObject:@{
            @"id": @(deviceID),
            @"name": name,
        }];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    return result;
}

void liveSmokeLog(const char *message) {
    if (gLiveSmokeDiagnostics) {
        fprintf(stderr, "%s\n", message);
        fflush(stderr);
    }
}

#if defined(__x86_64__)

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

u32 call_SetAPULength(u32 song, u32 fade) {
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

void call_SeekAPU(u32 time, u8 fast) {
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

CBFUNC call_SNESAPUCallback(CBFUNC callback, u32 mask) {
    u64 ret = 0;
    const u64 arg0 = reinterpret_cast<u64>(callback);
    const u64 arg1 = mask;
    asm volatile(
        "pushq %[arg1]\n\t"
        "pushq %[arg0]\n\t"
        "call _SNESAPUCallback\n\t"
        "add $16, %%rsp\n\t"
        : "=a"(ret)
        : [arg0] "m"(arg0), [arg1] "m"(arg1)
        : SNESAPU_CALL_CLOBBERS);
    return reinterpret_cast<CBFUNC>(ret);
}

#elif defined(__aarch64__)

u32 call_InitAPU(u32 reason) {
    return InitAPU(reason);
}

void call_SetAPUOpt(u32 mix_type, u32 num_channels, u32 bits, u32 rate, u32 inter, u32 opts) {
    SetAPUOpt(mix_type, num_channels, bits, rate, inter, opts);
}

void call_SetAPUSmpClk(u32 speed) {
    SetAPUSmpClk(speed);
}

u32 call_SetAPULength(u32 song, u32 fade) {
    return SetAPULength(song, fade);
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

void call_SeekAPU(u32 time, u8 fast) {
    SeekAPU(time, static_cast<b8>(fast));
}

void call_GetSPCRegs(u16 *pc, u8 *a, u8 *y, u8 *x, u8 *psw, u8 *sp) {
    GetSPCRegs(pc, a, y, x, psw, sp);
}

CBFUNC call_SNESAPUCallback(CBFUNC callback, u32 mask) {
    return SNESAPUCallback(callback, mask);
}

#else
#error Unsupported SNESAPU call bridge architecture.
#endif

struct TempoHistory {
    u8 channel = 0;
    u8 source = 0;
    u8 volume = 0;
    u16 pitch = 0;
};

struct TempoSnapshot {
    u8 bpm = 0;
    u8 min_bpm = 0;
    u8 max_bpm = 0;
    u8 mode = 0;
    u8 kon_count = 0;
    u8 kon_count_old = 0;
};

class TempoAnalyzer {
public:
    void reset(u32 t64 = 0) {
        disabled_ = false;
        bpm_ = 0;
        min_bpm_ = 0;
        max_bpm_ = 0;
        mode_ = 0;
        kon_ = 0;
        kon_count_ = 0;
        kon_count_old_ = 0;
        start_time_ = t64;
        kon_time_ = t64;
        min_time_ = t64;
        max_time_ = t64;
        triple_time_ = 0;
        count_.fill(0);
        t64_count_.fill(0);
        volume_.fill(0);
        history_index_ = 0;
        trace_count_ = 0;
        history_.fill(TempoHistory{});
    }

    void setDisabled(bool disabled) {
        disabled_ = disabled;
    }

    TempoSnapshot snapshot() const {
        return TempoSnapshot{bpm_, min_bpm_, max_bpm_, mode_, kon_count_, kon_count_old_};
    }

    u32 handleDSPRegisterWrite(u32 effect, u32 addr, u32 value) {
        if (effect != CBE_DSPREG) {
            return value;
        }

        const u8 reg = static_cast<u8>(addr & 0x7f);
        const u8 val = static_cast<u8>(value & 0xff);
        switch (reg) {
            case 0x4c:
                analyzeKeyOn(val);
                break;
            case 0x5c:
                kon_ = static_cast<u8>(kon_ & static_cast<u8>(val ^ 0xffu));
                break;
            default:
                break;
        }
        return value;
    }

private:
    static u8 roundedAverageVolume(s8 left, s8 right) {
        const u32 sum = static_cast<u32>(std::abs(static_cast<int>(left))) +
                        static_cast<u32>(std::abs(static_cast<int>(right)));
        return static_cast<u8>((sum >> 1) + (sum & 1u));
    }

    static int signedPitchDelta(u16 previous, u16 current) {
        return static_cast<int>(static_cast<int16_t>(static_cast<u16>(previous - current)));
    }

    static bool traceEnabled() {
        return std::getenv("SNESAPU_BPM_TRACE") != nullptr;
    }

    void addWeightedBPM(u32 bpm) {
        auto add = [&](u32 index, u32 amount) {
            if (index < count_.size()) {
                count_[index] += amount;
            }
        };

        if (bpm >= 521 && bpm <= 800) add((bpm >> 2) + ((bpm >> 1) & 1u), 1);
        if (bpm >= 240 && bpm <= 520) add((bpm >> 2) + ((bpm >> 1) & 1u), 2);
        if (bpm >= 261 && bpm <= 400) add((bpm >> 1) + (bpm & 1u), 2);
        if (bpm >= 120 && bpm <= 260) add((bpm >> 1) + (bpm & 1u), 3);
        if (bpm >= 131 && bpm <= 200) add(bpm, 3);
        if (bpm >= 60 && bpm <= 130) add(bpm, 4);
        if (bpm >= 66 && bpm <= 100) add(bpm + bpm, 4);
        if (bpm >= 30 && bpm <= 65) add(bpm + bpm, 5);
    }

    void analyzeKeyOn(u8 new_kon) {
        if (disabled_) {
            return;
        }

        u8 enabled = static_cast<u8>((new_kon ^ kon_) & new_kon);
        const u8 raw_enabled = enabled;
        kon_ = new_kon;
        if (enabled == 0) {
            return;
        }

        const u32 now = t64Cnt;
        u8 bit = 1;
        for (u8 i = 0; i < 8; ++i) {
            if ((enabled & bit) != 0) {
                const DSPVoice &voice = dsp.voice[i];
                const u8 vol = roundedAverageVolume(voice.volL, voice.volR);
                volume_[i] = vol;
                if (vol != 0) {
                    history_[history_index_] = TempoHistory{i, voice.srcn, vol, voice.pitch};
                    history_index_ = (history_index_ + 1u) & 15u;
                } else {
                    enabled = static_cast<u8>(enabled ^ bit);
                }
            }
            bit = static_cast<u8>(bit << 1);
        }
        if (enabled == 0) {
            if (traceEnabled() && trace_count_ < 256) {
                fprintf(stderr,
                        "tempo filtered t64=%u raw=%02X kept=00 reason=volume\n",
                        now,
                        raw_enabled);
                ++trace_count_;
            }
            return;
        }

        bit = 1;
        for (u8 i = 0; i < 8; ++i) {
            if ((enabled & bit) != 0) {
                const u32 previous = t64_count_[i];
                if (previous != 0) {
                    const u32 delta = now - previous;
                    if (delta != 0) {
                        addWeightedBPM(7680000u / delta);
                    }
                }
                t64_count_[i] = now;

                const DSPVoice &voice = dsp.voice[i];
                for (const TempoHistory &entry : history_) {
                    if (entry.channel == i) continue;
                    if (entry.source != voice.srcn) continue;
                    if (entry.volume <= volume_[i]) continue;
                    if (std::abs(signedPitchDelta(entry.pitch, voice.pitch)) >= 80) continue;
                    enabled = static_cast<u8>(enabled ^ bit);
                    break;
                }
            }
            bit = static_cast<u8>(bit << 1);
        }
        if (enabled == 0) {
            if (traceEnabled() && trace_count_ < 256) {
                fprintf(stderr,
                        "tempo filtered t64=%u raw=%02X kept=00 reason=echo\n",
                        now,
                        raw_enabled);
                ++trace_count_;
            }
            return;
        }

        u32 count1 = 0;
        u32 count2 = 0;
        u32 count3 = now - kon_time_;
        u32 bpm = 0;

        if (count3 >= 4800) {
            kon_time_ = now;
            ++kon_count_;
            bpm = 7680000u / count3;
            bpm = (bpm >> 1) + (bpm & 1u);
            while (bpm != 0 && bpm <= 56) bpm += bpm;
            while (bpm != 0 && bpm >= 204) bpm >>= 1;
            if (bpm < 60) bpm = 60;
            if (bpm > 200) bpm = 200;

            count1 = bpm <= 70 ? 64 : bpm - 6;
            if (min_bpm_ != 0) {
                const u32 scan = min_bpm_;
                if (count1 <= scan || (now - min_time_) >= 480000) {
                    min_time_ = now;
                } else {
                    count1 = scan + 1;
                }
            }

            if (count1 >= 184) {
                count2 = bpm >= 194 ? 200 : bpm + 6;
            } else if (bpm >= 190) {
                count2 = 196;
            } else {
                count2 = bpm + 6;
            }
            if (max_bpm_ != 0) {
                const u32 scan = max_bpm_;
                if (count2 >= scan || (now - max_time_) >= 320000) {
                    max_time_ = now;
                } else {
                    count2 = scan - (kon_count_ & 1u);
                }
            }
            if (count2 <= 76) {
                count1 = 60;
            }
            min_bpm_ = static_cast<u8>(count1);
            max_bpm_ = static_cast<u8>(count2);
        } else {
            if (min_bpm_ == 0) min_bpm_ = 120;
            if (max_bpm_ == 0) max_bpm_ = 140;
            count1 = min_bpm_;
            count2 = max_bpm_;
        }

        if (traceEnabled() && trace_count_ < 256) {
            fprintf(stderr,
                    "tempo kon t64=%u raw=%02X kept=%02X gap=%u window=%u-%u instant=%u kon=%u old=%u current=%u\n",
                    now,
                    raw_enabled,
                    enabled,
                    count3,
                    count1,
                    count2,
                    bpm,
                    kon_count_,
                    kon_count_old_,
                    bpm_);
            ++trace_count_;
        }

        u32 scan2 = now - start_time_;
        if (scan2 < 64000) {
            return;
        }

        u8 mode = 0x31;
        if (count2 >= 140) {
            const u32 threshold = ((count2 * 6553u) >> 16) - (count2 >= 170 ? 1u : 0u) - 4u;
            if (kon_count_old_ == 0 && kon_count_ <= threshold) {
                count1 >>= 1;
                if (count1 < 64) count1 = 64;
                mode = 0x41;
            } else if (kon_count_old_ != 0 && kon_count_old_ <= threshold) {
                count1 >>= 1;
                count2 = (count2 >> 1) + 3;
                if (count1 < 64) count1 = 64;
                if (count2 < 127) count2 = 127;
                mode = 0x41;
            } else if (count1 <= static_cast<u32>(bpm_ + 12u)) {
                bpm = static_cast<u32>(bpm_ - 2u);
                if (count1 > bpm) {
                    count1 = bpm;
                    if (count1 < 64) count1 = 64;
                    mode = 0x35;
                }
            }
        }

        u32 best_bpm = 0;
        u32 best_count = 0;
        const u8 bpm1 = static_cast<u8>(count1);
        const u8 bpm2 = static_cast<u8>(count2);
        for (u32 i = count1; i <= count2 && i < count_.size(); ++i) {
            const u32 hits = count_[i];
            if (best_count < hits) {
                best_bpm = i;
                best_count = hits;
                mode_ = mode;
            }
        }

        u32 scan1 = best_bpm > 5 ? best_bpm - 5 : 0;
        scan2 = best_bpm + 5;
        if (scan1 < 60) scan1 = 60;
        if (scan2 > 200) scan2 = 200;
        bpm = 0;
        count1 = 0;
        for (u32 i = scan1; i <= scan2; ++i) {
            count3 = count_[i];
            bpm += (i + i) * count3;
            count1 += count3;
        }
        if (count1 != 0) {
            bpm /= count1;
            bpm = (bpm >> 1) + (bpm & 1u);
        }

        if (bpm >= 96 && ((bpm <= 128) || (bpm >= 176)) && count1 >= 16) {
            scan1 = ((bpm << (1 + (bpm <= 150 ? 1u : 0u))) * 21845u) >> 16;
            if (triple_time_ != 0 || (scan1 >= min_bpm_ && scan1 <= max_bpm_)) {
                scan2 = scan1 + 5;
                scan1 = scan1 > 5 ? scan1 - 5 : 0;
                if (scan1 < 60) scan1 = 60;
                if (scan2 > 200) scan2 = 200;
                const u32 saved_bpm = bpm;
                bpm = 0;
                count2 = 0;
                for (u32 i = scan1; i <= scan2; ++i) {
                    count3 = count_[i];
                    bpm += (i + i) * count3;
                    count2 += count3;
                }
                count3 = triple_time_ != 0 ? 10 : 30;
                if (count2 >= count3 && count2 >= (count1 >> 3)) {
                    bpm /= count2;
                    bpm = (bpm >> 1) + (bpm & 1u);
                    count1 = count2 << 2;
                    mode_ = static_cast<u8>(mode + 1u);
                    triple_time_ = 640000;
                } else {
                    bpm = saved_bpm;
                }
            }
        }

        if (bpm_ == 0 && bpm == 0) {
            if ((bpm2 - bpm1) <= 20) {
                bpm = (bpm1 + bpm2) >> 1;
                mode_ = static_cast<u8>(mode + 2u);
            } else {
                scan2 = 0;
                for (u32 i = 60; i <= 200; ++i) {
                    count3 = count_[i];
                    if (scan2 < count3) {
                        scan2 = count3;
                        bpm = i;
                        mode_ = static_cast<u8>(mode + 3u);
                    }
                }
                if (bpm != 0) {
                    bpm <= 70 ? min_bpm_ = 60 : min_bpm_ = static_cast<u8>(bpm - 10);
                    bpm >= 190 ? max_bpm_ = 200 : max_bpm_ = static_cast<u8>(bpm + 10);
                }
            }
        }

        count2 = now - start_time_;
        if (bpm_ != 0 && (count1 >= 600 || count2 >= 240000 || bpm_ < bpm1 || bpm_ > bpm2)) {
            if (bpm_ < bpm1 || bpm_ > bpm2) {
                if (bpm != 0 && (count1 >= 30 || count2 >= 120000)) {
                    bpm_ = static_cast<u8>(bpm);
                } else if (kon_count_old_ == 0) {
                    bpm_ = static_cast<u8>(bpm);
                }
                kon_count_old_ = 0;
            } else {
                if (bpm != 0 && count1 >= 30) {
                    bpm_ = static_cast<u8>(bpm);
                }
                kon_count_old_ = kon_count_;
                if (mode == 0x41) {
                    --kon_count_old_;
                } else {
                    ++kon_count_old_;
                }
            }

            kon_count_ = 0;
            start_time_ = now;
            triple_time_ = triple_time_ > count2 ? triple_time_ - count2 : 0;
            count_.fill(0);
            if (bpm >= min_bpm_ && bpm <= max_bpm_) {
                count3 = count_[bpm] >> 2;
                if (now < 720000) count3 >>= 1;
                if (!(count1 >= 60 || count2 >= 240000)) count3 >>= 1;
                count_[bpm] = count3;
            }
            return;
        }

        if (bpm != 0 && (count1 >= 60 || count2 >= 240000)) {
            bpm_ = static_cast<u8>(bpm);
            if (bpm >= min_bpm_ && bpm <= max_bpm_) {
                count_[bpm] += 2;
            }
        }
    }

    bool disabled_ = false;
    u8 bpm_ = 0;
    u8 min_bpm_ = 0;
    u8 max_bpm_ = 0;
    u8 mode_ = 0;
    u8 kon_ = 0;
    u8 kon_count_ = 0;
    u8 kon_count_old_ = 0;
    u32 start_time_ = 0;
    u32 kon_time_ = 0;
    u32 min_time_ = 0;
    u32 max_time_ = 0;
    u32 triple_time_ = 0;
    std::array<u32, 201> count_ {};
    std::array<u32, 8> t64_count_ {};
    std::array<u8, 8> volume_ {};
    u32 history_index_ = 0;
    u32 trace_count_ = 0;
    std::array<TempoHistory, 16> history_ {};
};

static TempoAnalyzer *g_activeTempoAnalyzer = nullptr;

extern "C" u32 SNESAPUCallbackImpl(u32 effect, u32 addr, u32 value, void *data) {
    (void)data;
    TempoAnalyzer *analyzer = g_activeTempoAnalyzer;
    return analyzer ? analyzer->handleDSPRegisterWrite(effect, addr, value) : value;
}

#if defined(__x86_64__)
extern "C" u32 SNESAPUCallbackThunk(void);
__asm__(
    ".globl _SNESAPUCallbackThunk\n"
    "_SNESAPUCallbackThunk:\n"
    "pushq %rbp\n"
    "movq %rsp, %rbp\n"
    "pushq %rbx\n"
    "pushq %rcx\n"
    "pushq %rdx\n"
    "pushq %rsi\n"
    "pushq %rdi\n"
    "pushq %r8\n"
    "pushq %r9\n"
    "pushq %r10\n"
    "pushq %r11\n"
    "andq $-16, %rsp\n"
    "movl 16(%rbp), %edi\n"
    "movl 24(%rbp), %esi\n"
    "movl 32(%rbp), %edx\n"
    "movq 40(%rbp), %rcx\n"
    "call _SNESAPUCallbackImpl\n"
    "leaq -72(%rbp), %rsp\n"
    "popq %r11\n"
    "popq %r10\n"
    "popq %r9\n"
    "popq %r8\n"
    "popq %rdi\n"
    "popq %rsi\n"
    "popq %rdx\n"
    "popq %rcx\n"
    "popq %rbx\n"
    "popq %rbp\n"
    "ret\n"
);
#else
extern "C" u32 SNESAPUCallbackThunk(u32 effect, u32 addr, u32 value, void *data) {
    return SNESAPUCallbackImpl(effect, addr, value, data);
}
#endif

struct LiveMeterSnapshot {
    double master_peak_left = 0.0;
    double master_peak_right = 0.0;
    s8 master_volume_left = 0;
    s8 master_volume_right = 0;
    s8 echo_volume_left = 0;
    s8 echo_volume_right = 0;
    u8 echo_delay = 0;
    s8 echo_feedback = 0;
    double voice_peak_left[8] = {};
    double voice_peak_right[8] = {};
    s8 voice_volume_left[8] = {};
    s8 voice_volume_right[8] = {};
    u8 voice_source[8] = {};
    u8 voice_adsr1[8] = {};
    u8 voice_adsr2[8] = {};
    u8 voice_gain[8] = {};
    s8 voice_env[8] = {};
    s8 voice_output[8] = {};
    u16 voice_pitch[8] = {};
    u8 voice_mix_flags[8] = {};
    u8 voice_envelope_mode[8] = {};
    u8 voice_block_header[8] = {};
    u16 voice_current_block[8] = {};
    u16 voice_source_start[8] = {};
    u16 voice_source_loop[8] = {};
    u8 echo_on = 0;
    u8 pitch_mod_on = 0;
    u8 noise_on = 0;
    u8 key_on = 0;
    u8 key_off = 0;
    u8 end_waveform = 0;
    u8 source_directory = 0;
    u8 flags = 0;
    u8 echo_waveform = 0;
    s8 fir[8] = {};
    u8 apu_ports[4] = {};
    u8 out_ports[4] = {};
    u16 spc_pc = 0;
    u8 spc_a = 0;
    u8 spc_y = 0;
    u8 spc_x = 0;
    u8 spc_psw = 0;
    u8 spc_sp = 0;
    u32 script_work[8] = {};
    u32 script_cmp[2] = {};
    u32 script_wait_count = 0;
    u32 script_pointer = 0;
    u8 script_status_flags = 0;
    u8 script_int_in_port = 0;
    u8 script_int_out_port = 0;
    u32 script_data = 0;
    u32 script_stack = 0;
    u8 bpm = 0;
    u8 bpm_min = 0;
    u8 bpm_max = 0;
    u8 bpm_mode = 0;
    u8 bpm_kon_count = 0;
    u8 bpm_kon_count_old = 0;
    u32 t64_count = 0;
};

static double PositiveFloatFromBits(u32 bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    if (!std::isfinite(value) || value < 0.0f) {
        return 0.0;
    }
    return value;
}

class LiveSNESAPUCore {
public:
    LiveSNESAPUCore() {
        resizeAudioBuffersForCurrentFormatLocked();
    }

    ~LiveSNESAPUCore() {
        pause_streaming();
        if (g_activeTempoAnalyzer == &tempo_) {
            g_activeTempoAnalyzer = nullptr;
        }
    }

    bool load(const u8 *bytes, size_t size, u32 song_seconds, u32 fade_milliseconds, u32 display_seconds) {
        if (!bytes || size < kSpcSize) {
            return false;
        }

        pause_streaming();
        std::lock_guard<std::mutex> lock(mutex_);
        loaded_ = false;
        loaded_atomic_.store(false, std::memory_order_release);
        underrun_count_.store(0, std::memory_order_release);
        clearBufferedAudio();
        spc_.assign(bytes, bytes + kSpcSize);
        if (!initialized_) {
            liveSmokeLog("live core InitAPU");
            initialized_ = call_InitAPU(1) != 0;
            if (!initialized_) {
                return false;
            }
        }

        song_length_t64_ = song_seconds > 0 ? song_seconds * 64000U : 0;
        fade_length_t64_ = fade_milliseconds << 6;
        if (!reloadSPCStateLocked()) {
            return false;
        }
        clearBufferedAudio();
        song_seconds_ = display_seconds;
        loaded_ = true;
        loaded_atomic_.store(true, std::memory_order_release);
        return true;
    }

    void render(AudioBufferList *audio_buffer_list, AVAudioFrameCount frame_count) {
        if (!audio_buffer_list) {
            return;
        }

        if (!loaded_atomic_.load(std::memory_order_acquire)) {
            clearAudio(audio_buffer_list, frame_count);
            return;
        }

        AVAudioFrameCount frames_done = 0;
        while (frames_done < frame_count) {
            const AVAudioFrameCount copied =
                popBufferedFloat(audio_buffer_list, frames_done, frame_count - frames_done);
            if (copied == 0) {
                underrun_count_.fetch_add(1, std::memory_order_relaxed);
                clearAudioRange(audio_buffer_list, frames_done, frame_count - frames_done);
                return;
            }
            frames_done += copied;
        }
    }

    bool start_streaming(size_t prefill_chunks = kLiveWaveBufferPrefillCount,
                         size_t steady_chunks = kLiveWaveBufferPrefillCount) {
        if (!loaded_atomic_.load(std::memory_order_acquire)) {
            return false;
        }

        {
            std::lock_guard<std::mutex> lock(buffer_mutex_);
            if (producer_active_) {
                return true;
            }
        }
        pause_streaming();

        while (bufferedFrameCount() < prefillFrameCount(prefill_chunks)) {
            if (!produceOneChunk()) {
                return false;
            }
        }

        {
            std::lock_guard<std::mutex> lock(buffer_mutex_);
            producer_target_frames_ = prefillFrameCountLocked(steady_chunks);
            producer_stop_ = false;
            producer_active_ = true;
        }
        producer_thread_ = std::thread(&LiveSNESAPUCore::producerLoop, this);
        producer_cv_.notify_one();
        return true;
    }

    bool analyze_for_seconds(double seconds) {
        if (!loaded_atomic_.load(std::memory_order_acquire)) {
            return false;
        }
        pause_streaming();
        std::lock_guard<std::mutex> lock(mutex_);
        if (!loaded_) {
            return false;
        }
        if (!std::isfinite(seconds) || seconds <= 0.0) {
            return true;
        }

        const uint64_t delta_t64 =
            std::min<uint64_t>(static_cast<uint64_t>(std::llround(seconds * 64000.0)), UINT32_MAX);
        const uint64_t target_t64 = std::min<uint64_t>(static_cast<uint64_t>(t64Cnt) + delta_t64, UINT32_MAX);
        while (static_cast<uint64_t>(t64Cnt) < target_t64) {
            const u32 before = t64Cnt;
            if (!renderChunkLocked() || t64Cnt == before) {
                return false;
            }
        }
        return true;
    }

    void pause_streaming() {
        {
            std::lock_guard<std::mutex> lock(buffer_mutex_);
            if (!producer_active_ && !producer_thread_.joinable()) {
                return;
            }
            producer_stop_ = true;
        }
        producer_cv_.notify_all();
        if (producer_thread_.joinable()) {
            producer_thread_.join();
        }
        {
            std::lock_guard<std::mutex> lock(buffer_mutex_);
            producer_active_ = false;
            producer_stop_ = false;
        }
    }

    bool seek_seconds(double seconds, bool fast) {
        if (!loaded_atomic_.load(std::memory_order_acquire)) {
            return false;
        }
        pause_streaming();
        std::lock_guard<std::mutex> lock(mutex_);
        if (!loaded_) {
            return false;
        }

        if (!std::isfinite(seconds)) {
            seconds = 0.0;
        }
        const double max_seconds = static_cast<double>(song_seconds_ ? song_seconds_ : 3600);
        seconds = std::clamp(seconds, 0.0, max_seconds);
        const uint64_t max_target_t64 =
            std::min<uint64_t>(static_cast<uint64_t>(max_seconds * 64000.0), UINT32_MAX);
        const uint64_t requested_t64 =
            std::min<uint64_t>(static_cast<uint64_t>(std::llround(seconds * 64000.0)), max_target_t64);
        const u32 target_t64 = static_cast<u32>(requested_t64);

        u32 current_t64 = t64Cnt;
        if (target_t64 == 0 || target_t64 < current_t64) {
            if (!reloadSPCStateLocked()) {
                loaded_ = false;
                loaded_atomic_.store(false, std::memory_order_release);
                return false;
            }
            current_t64 = 0;
        }

        if (target_t64 > current_t64) {
            tempo_.setDisabled(true);
            call_SeekAPU(target_t64 - current_t64, fast ? 1 : 0);
        }
        tempo_.reset(t64Cnt);
        clearBufferedAudio();
        resetMetersLocked();
        return true;
    }

    void set_amp_percent(u32 percent) {
        percent = std::clamp<u32>(percent, 5, 400);
        set_amp_value(FixedPercent(percent));
    }

    void set_amp_value(u32 value) {
        std::lock_guard<std::mutex> lock(mutex_);
        amp_ = value;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetDSPAmp(amp_);
        }
    }

    void set_speed_percent(u32 percent) {
        percent = std::clamp<u32>(percent, 25, 400);
        set_speed_value(FixedPercent(percent));
    }

    void set_speed_value(u32 value) {
        std::lock_guard<std::mutex> lock(mutex_);
        speed_ = value;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetAPUSmpClk(speed_);
            call_SetDSPPitch(effectivePitchLocked());
        }
    }

    void set_interpolation(u32 interpolation) {
        std::lock_guard<std::mutex> lock(mutex_);
        interpolation_ = SanitizedInterpolation(interpolation);
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetAPUOpt(MIX_INT, output_channels_, output_bits_, output_rate_, interpolation_, EffectiveDSPOptions(dsp_options_));
        }
    }

    void set_pitch(u32 pitch) {
        std::lock_guard<std::mutex> lock(mutex_);
        pitch_ = std::clamp<u32>(pitch, 16384, 262144);
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetDSPPitch(effectivePitchLocked());
        }
    }

    void set_pitch_async(bool async) {
        std::lock_guard<std::mutex> lock(mutex_);
        pitch_async_ = async;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetDSPPitch(effectivePitchLocked());
        }
    }

    void set_stereo_separation(u32 separation) {
        std::lock_guard<std::mutex> lock(mutex_);
        stereo_separation_ = separation;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetDSPStereo(stereo_separation_);
        }
    }

    void set_feedback(u32 feedback) {
        std::lock_guard<std::mutex> lock(mutex_);
        feedback_ = feedback;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetDSPEFBCT(FeedbackToEfbct(feedback_));
        }
    }

    void set_dsp_options(u32 options) {
        std::lock_guard<std::mutex> lock(mutex_);
        dsp_options_ = options;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetAPUOpt(MIX_INT, output_channels_, output_bits_, output_rate_, interpolation_, EffectiveDSPOptions(dsp_options_));
        }
    }

    void set_output_format(u32 channels, u32 bits, u32 rate) {
        std::lock_guard<std::mutex> lock(mutex_);
        output_channels_ = SanitizedOutputChannels(channels);
        output_bits_ = SanitizedOutputBits(bits);
        output_rate_ = SanitizedOutputRate(rate);
        resizeAudioBuffersForCurrentFormatLocked();
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            call_SetAPUOpt(MIX_INT, output_channels_, output_bits_, output_rate_, interpolation_, EffectiveDSPOptions(dsp_options_));
        }
    }

    void set_mute_mask(u32 mask) {
        std::lock_guard<std::mutex> lock(mutex_);
        mute_mask_ = mask & 0xffu;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            applyVoiceFlagsLocked();
        }
    }

    void set_noise_mask(u32 mask) {
        std::lock_guard<std::mutex> lock(mutex_);
        noise_mask_ = mask & 0xffu;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            applyVoiceFlagsLocked();
        }
    }

    void set_voice_masks(u32 muteMask, u32 noiseMask) {
        std::lock_guard<std::mutex> lock(mutex_);
        mute_mask_ = muteMask & 0xffu;
        noise_mask_ = noiseMask & 0xffu;
        if (loaded_atomic_.load(std::memory_order_acquire)) {
            applyVoiceFlagsLocked();
        }
    }

    LiveMeterSnapshot snapshot() {
        std::lock_guard<std::mutex> lock(mutex_);
        LiveMeterSnapshot snapshot;
        if (!loaded_atomic_.load(std::memory_order_acquire)) {
            return snapshot;
        }
        snapshot.t64_count = t64Cnt;
        snapshot.master_peak_left = PositiveFloatFromBits(vMMaxL) / 65536.0;
        snapshot.master_peak_right = PositiveFloatFromBits(vMMaxR) / 65536.0;
        snapshot.master_volume_left = dsp.mvolL;
        snapshot.master_volume_right = dsp.mvolR;
        snapshot.echo_volume_left = dsp.evolL;
        snapshot.echo_volume_right = dsp.evolR;
        snapshot.echo_delay = dsp.edl;
        snapshot.echo_feedback = dsp.efb;
        snapshot.echo_on = dsp.eon;
        snapshot.pitch_mod_on = dsp.pmon;
        snapshot.noise_on = dsp.non;
        snapshot.key_on = dsp.kon;
        snapshot.key_off = dsp.kof;
        snapshot.end_waveform = dsp.endx;
        snapshot.source_directory = dsp.dir;
        snapshot.flags = dsp.flg;
        snapshot.echo_waveform = dsp.esa;
        const u8 *ram = reinterpret_cast<const u8 *>(pAPURAM);
        for (int i = 0; i < 8; ++i) {
            snapshot.voice_peak_left[i] = PositiveFloatFromBits(static_cast<u32>(mix[i].vMaxL));
            snapshot.voice_peak_right[i] = PositiveFloatFromBits(static_cast<u32>(mix[i].vMaxR));
            snapshot.voice_volume_left[i] = dsp.voice[i].volL;
            snapshot.voice_volume_right[i] = dsp.voice[i].volR;
            snapshot.voice_source[i] = dsp.voice[i].srcn;
            snapshot.voice_adsr1[i] = dsp.voice[i].adsr[0];
            snapshot.voice_adsr2[i] = dsp.voice[i].adsr[1];
            snapshot.voice_gain[i] = dsp.voice[i].gain;
            snapshot.voice_env[i] = dsp.voice[i].envx;
            snapshot.voice_output[i] = dsp.voice[i].outx;
            snapshot.voice_pitch[i] = dsp.voice[i].pitch;
            snapshot.voice_mix_flags[i] = mix[i].mFlg;
            snapshot.voice_envelope_mode[i] = mix[i].eMode;
            snapshot.voice_block_header[i] = mix[i].bHdr;
            snapshot.voice_current_block[i] = static_cast<u16>(mix[i].bCur & 0xffffu);
            if (ram) {
                const u16 src_entry = static_cast<u16>((static_cast<u16>(dsp.dir) << 8) +
                                                       static_cast<u16>(dsp.voice[i].srcn) * 4u);
                snapshot.voice_source_start[i] =
                    static_cast<u16>(ram[src_entry] | (static_cast<u16>(ram[static_cast<u16>(src_entry + 1)]) << 8));
                snapshot.voice_source_loop[i] =
                    static_cast<u16>(ram[static_cast<u16>(src_entry + 2)] |
                                     (static_cast<u16>(ram[static_cast<u16>(src_entry + 3)]) << 8));
            }
        }
        for (int i = 0; i < 8; ++i) {
            snapshot.fir[i] = dsp.fir[i].c;
        }
        for (int i = 0; i < 4; ++i) {
            snapshot.apu_ports[i] = ram ? ram[0x00f4u + static_cast<u16>(i)] : 0;
            snapshot.out_ports[i] = outPort[i];
        }
        call_GetSPCRegs(&snapshot.spc_pc,
                        &snapshot.spc_a,
                        &snapshot.spc_y,
                        &snapshot.spc_x,
                        &snapshot.spc_psw,
                        &snapshot.spc_sp);
        for (int i = 0; i < 8; ++i) {
            snapshot.script_work[i] = scr700wrk[i];
        }
        snapshot.script_cmp[0] = scr700cmp[0];
        snapshot.script_cmp[1] = scr700cmp[1];
        snapshot.script_wait_count = scr700cnt;
        snapshot.script_pointer = scr700ptr;
        snapshot.script_status_flags = scr700stf;
        snapshot.script_int_in_port = scr700int[0];
        snapshot.script_int_out_port = scr700int[1];
        snapshot.script_data = scr700dat;
        snapshot.script_stack = static_cast<u32>(scr700stp & 0xffffffffu);
        const TempoSnapshot tempo = tempo_.snapshot();
        snapshot.bpm = tempo.bpm;
        snapshot.bpm_min = tempo.min_bpm;
        snapshot.bpm_max = tempo.max_bpm;
        snapshot.bpm_mode = tempo.mode;
        snapshot.bpm_kon_count = tempo.kon_count;
        snapshot.bpm_kon_count_old = tempo.kon_count_old;
        return snapshot;
    }

    bool loaded() const {
        return loaded_atomic_.load(std::memory_order_acquire);
    }

    u32 song_seconds() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return song_seconds_;
    }

    u32 amp_percent() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return PercentFromFixed(amp_);
    }

    u32 speed_percent() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return PercentFromFixed(speed_);
    }

    u32 interpolation() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return interpolation_;
    }

    u32 mute_mask() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return mute_mask_;
    }

    uint64_t underrun_count() const {
        return underrun_count_.load(std::memory_order_acquire);
    }

private:
    u32 effectivePitchLocked() const {
        u32 pitch = std::clamp<u32>(pitch_, 16384, 262144);
        if (pitch_async_) {
            pitch = static_cast<u32>((static_cast<uint64_t>(speed_) * pitch) / kDefaultSpeed);
        }
        return pitch;
    }

    void applyVoiceFlagsLocked() {
        for (int i = 0; i < 8; ++i) {
            u8 flags = mix[i].mFlg & static_cast<u8>(~MFLG_USER);
            if ((mute_mask_ & (1u << i)) != 0) {
                flags |= MFLG_MUTE;
            }
            if ((noise_mask_ & (1u << i)) != 0) {
                flags |= MFLG_NOISE;
            }
            mix[i].mFlg = flags;
        }
    }

    bool reloadSPCStateLocked() {
        if (spc_.size() < kSpcSize) {
            return false;
        }
        clearTempoCallbackLocked();
        liveSmokeLog("live core LoadSPCFile");
        call_LoadSPCFile(spc_.data());
        liveSmokeLog("live core SetAPUOpt");
        call_SetAPUOpt(MIX_INT, output_channels_, output_bits_, output_rate_, interpolation_, EffectiveDSPOptions(dsp_options_));
        liveSmokeLog("live core SetAPUSmpClk");
        call_SetAPUSmpClk(speed_);
        liveSmokeLog("live core SetDSPPitch");
        call_SetDSPPitch(effectivePitchLocked());
        liveSmokeLog("live core SetDSPStereo");
        call_SetDSPStereo(stereo_separation_);
        liveSmokeLog("live core SetDSPEFBCT");
        call_SetDSPEFBCT(FeedbackToEfbct(feedback_));
        liveSmokeLog("live core SetDSPAmp");
        call_SetDSPAmp(amp_);
        if (song_length_t64_ > 0) {
            liveSmokeLog("live core SetAPULength");
            call_SetAPULength(song_length_t64_, fade_length_t64_);
        }
        if (mute_mask_ != 0 || noise_mask_ != 0) {
            applyVoiceFlagsLocked();
        }
        tempo_.reset(t64Cnt);
        installTempoCallbackLocked();
        resetMetersLocked();
        return true;
    }

    void clearTempoCallbackLocked() {
        if (g_activeTempoAnalyzer == &tempo_) {
            g_activeTempoAnalyzer = nullptr;
        }
        tempo_.setDisabled(true);
        call_SNESAPUCallback(nullptr, 0);
    }

    void installTempoCallbackLocked() {
        tempo_.setDisabled(false);
        g_activeTempoAnalyzer = &tempo_;
        call_SNESAPUCallback(reinterpret_cast<CBFUNC>(SNESAPUCallbackThunk), CBE_DSPREG);
    }

    void resetMetersLocked() {
        vMMaxL = 0;
        vMMaxR = 0;
        for (int i = 0; i < 8; ++i) {
            mix[i].vMaxL = 0;
            mix[i].vMaxR = 0;
        }
    }

    bool renderChunkLocked() {
        installTempoCallbackLocked();
        resetMetersLocked();
        liveSmokeLog("live core EmuAPU begin");
        void *end = call_EmuAPU(render_chunk_.data(), kLiveRenderChunkCycles, 0);
        liveSmokeLog("live core EmuAPU end");
        const size_t produced_bytes = static_cast<u8 *>(end) - render_chunk_.data();
        const size_t frame_bytes = outputFrameBytesLocked();
        if (frame_bytes == 0 ||
            produced_bytes == 0 ||
            produced_bytes > renderChunkCapacityBytesLocked() ||
            (produced_bytes % frame_bytes) != 0) {
            return false;
        }
        rendered_chunk_frames_ = produced_bytes / frame_bytes;
        return true;
    }

    static float decodeSample(const u8 *sample, u32 bits) {
        switch (static_cast<s32>(bits)) {
            case 8:
                return static_cast<float>(static_cast<int>(sample[0]) - 128) / 128.0f;
            case 16: {
                const int16_t value = static_cast<int16_t>(sample[0] | (sample[1] << 8));
                return static_cast<float>(value) / 32768.0f;
            }
            case 24: {
                int32_t value = static_cast<int32_t>(sample[0] | (sample[1] << 8) | (sample[2] << 16));
                if ((value & 0x00800000) != 0) {
                    value |= static_cast<int32_t>(0xff000000);
                }
                return static_cast<float>(value) / 8388608.0f;
            }
            case 32: {
                const int32_t value = static_cast<int32_t>(sample[0] |
                                                           (sample[1] << 8) |
                                                           (sample[2] << 16) |
                                                           (sample[3] << 24));
                return static_cast<float>(static_cast<double>(value) / 2147483648.0);
            }
            case -32: {
                float value = 0.0f;
                memcpy(&value, sample, sizeof(value));
                return std::clamp(value, -1.0f, 1.0f);
            }
            default:
                return 0.0f;
        }
    }

    static void clearAudio(AudioBufferList *audio_buffer_list, AVAudioFrameCount frame_count) {
        for (UInt32 i = 0; i < audio_buffer_list->mNumberBuffers; ++i) {
            AudioBuffer &buffer = audio_buffer_list->mBuffers[i];
            if (buffer.mData) {
                (void)frame_count;
                memset(buffer.mData, 0, buffer.mDataByteSize);
            }
        }
    }

    static void clearAudioRange(AudioBufferList *audio_buffer_list, AVAudioFrameCount offset, AVAudioFrameCount frame_count) {
        for (UInt32 i = 0; i < audio_buffer_list->mNumberBuffers; ++i) {
            AudioBuffer &buffer = audio_buffer_list->mBuffers[i];
            if (!buffer.mData) {
                continue;
            }
            const UInt32 channels = std::max<UInt32>(buffer.mNumberChannels, 1);
            float *samples = static_cast<float *>(buffer.mData) + offset * channels;
            memset(samples, 0, static_cast<size_t>(frame_count) * channels * sizeof(float));
        }
    }

    AVAudioFrameCount popBufferedFloat(AudioBufferList *audio_buffer_list,
                                       AVAudioFrameCount offset,
                                       AVAudioFrameCount frame_count) {
        AVAudioFrameCount copied = 0;
        {
            std::lock_guard<std::mutex> lock(buffer_mutex_);
            copied = static_cast<AVAudioFrameCount>(
                std::min<size_t>(frame_count, ring_count_frames_));
            if (copied == 0) {
                return 0;
            }

            copyRingFloatToOutputLocked(audio_buffer_list, offset, copied);
            ring_read_frame_ = (ring_read_frame_ + copied) % ringCapacityFrames();
            ring_count_frames_ -= copied;
        }
        producer_cv_.notify_one();
        return copied;
    }

    void copyRingFloatToOutputLocked(AudioBufferList *audio_buffer_list,
                                     AVAudioFrameCount offset,
                                     AVAudioFrameCount frame_count) {
        const size_t source_channels = std::max<size_t>(buffer_channels_, 1);
        if (audio_buffer_list->mNumberBuffers >= 2 &&
            audio_buffer_list->mBuffers[0].mData &&
            audio_buffer_list->mBuffers[1].mData) {
            float *left = static_cast<float *>(audio_buffer_list->mBuffers[0].mData) + offset;
            float *right = static_cast<float *>(audio_buffer_list->mBuffers[1].mData) + offset;
            for (AVAudioFrameCount i = 0; i < frame_count; ++i) {
                const size_t source_frame = (ring_read_frame_ + i) % ringCapacityFrames();
                left[i] = ring_buffer_[source_frame * source_channels];
                right[i] = source_channels > 1 ?
                    ring_buffer_[source_frame * source_channels + 1] :
                    left[i];
            }
            return;
        }

        if (audio_buffer_list->mNumberBuffers == 1 && audio_buffer_list->mBuffers[0].mData) {
            AudioBuffer &buffer = audio_buffer_list->mBuffers[0];
            const UInt32 destination_channels = std::max<UInt32>(buffer.mNumberChannels, 1);
            float *interleaved = static_cast<float *>(buffer.mData) + offset * destination_channels;
            for (AVAudioFrameCount i = 0; i < frame_count; ++i) {
                const size_t source_frame = (ring_read_frame_ + i) % ringCapacityFrames();
                const float left = ring_buffer_[source_frame * source_channels];
                const float right = source_channels > 1 ?
                    ring_buffer_[source_frame * source_channels + 1] :
                    left;
                for (UInt32 channel = 0; channel < destination_channels; ++channel) {
                    interleaved[i * destination_channels + channel] = channel == 0 ? left : right;
                }
            }
        }
    }

    bool produceOneChunk() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!loaded_) {
                return false;
            }
            if (!renderChunkLocked()) {
                loaded_ = false;
                loaded_atomic_.store(false, std::memory_order_release);
                return false;
            }
        }
        return appendRenderedChunk();
    }

    bool appendRenderedChunk() {
        std::lock_guard<std::mutex> lock(buffer_mutex_);
        if (ringFreeFramesLocked() < rendered_chunk_frames_) {
            return false;
        }

        const size_t source_channels = std::max<size_t>(buffer_channels_, 1);
        const size_t bytes_per_sample = BytesPerSampleForBits(buffer_bits_);
        for (size_t i = 0; i < rendered_chunk_frames_; ++i) {
            const size_t destination_frame =
                (ring_read_frame_ + ring_count_frames_ + i) % ringCapacityFrames();
            for (size_t channel = 0; channel < source_channels; ++channel) {
                const size_t source_index = (i * source_channels + channel) * bytes_per_sample;
                ring_buffer_[destination_frame * source_channels + channel] =
                    decodeSample(render_chunk_.data() + source_index, buffer_bits_);
            }
        }
        ring_count_frames_ += rendered_chunk_frames_;
        return true;
    }

    void producerLoop() {
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(buffer_mutex_);
                producer_cv_.wait(lock, [&] {
                    return producer_stop_ ||
                        (ring_count_frames_ < producer_target_frames_ &&
                         ringFreeFramesLocked() >= render_chunk_capacity_frames_);
                });
                if (producer_stop_) {
                    producer_active_ = false;
                    return;
                }
            }

            if (!produceOneChunk()) {
                std::lock_guard<std::mutex> lock(buffer_mutex_);
                producer_active_ = false;
                return;
            }
        }
    }

    size_t ringCapacityFrames() const {
        return ring_capacity_frames_;
    }

    size_t ringFreeFramesLocked() const {
        return ringCapacityFrames() - ring_count_frames_;
    }

    size_t bufferedFrameCount() const {
        std::lock_guard<std::mutex> lock(buffer_mutex_);
        return ring_count_frames_;
    }

    size_t prefillFrameCount(size_t chunk_count) const {
        std::lock_guard<std::mutex> lock(buffer_mutex_);
        return prefillFrameCountLocked(chunk_count);
    }

    size_t prefillFrameCountLocked(size_t chunk_count) const {
        const size_t sanitized_chunks =
            std::clamp<size_t>(chunk_count, 1, kLiveWaveBufferCapacityCount);
        return std::min(render_chunk_frames_ * sanitized_chunks, ringCapacityFrames());
    }

    void clearBufferedAudio() {
        std::lock_guard<std::mutex> lock(buffer_mutex_);
        ring_read_frame_ = 0;
        ring_count_frames_ = 0;
    }

    size_t outputFrameBytesLocked() const {
        return buffer_channels_ * BytesPerSampleForBits(buffer_bits_);
    }

    size_t renderChunkCapacityBytesLocked() const {
        return render_chunk_capacity_frames_ * outputFrameBytesLocked();
    }

    void resizeAudioBuffersForCurrentFormatLocked() {
        std::lock_guard<std::mutex> lock(buffer_mutex_);
        buffer_channels_ = SanitizedOutputChannels(output_channels_);
        buffer_bits_ = SanitizedOutputBits(output_bits_);
        const u32 rate = SanitizedOutputRate(output_rate_);
        render_chunk_frames_ = std::max<size_t>(1, (static_cast<size_t>(rate) * kLiveWaveBufferTimeMs) / 1000);
        render_chunk_capacity_frames_ = render_chunk_frames_ + kLiveRenderSlackFrames;
        rendered_chunk_frames_ = 0;
        ring_capacity_frames_ = render_chunk_capacity_frames_ * kLiveWaveBufferCapacityCount;
        render_chunk_.assign(renderChunkCapacityBytesLocked(), 0);
        ring_buffer_.assign(ring_capacity_frames_ * buffer_channels_, 0.0f);
        ring_read_frame_ = 0;
        ring_count_frames_ = 0;
        producer_target_frames_ = prefillFrameCountLocked(kLiveWaveBufferPrefillCount);
    }

    mutable std::mutex mutex_;
    mutable std::mutex buffer_mutex_;
    std::condition_variable producer_cv_;
    std::thread producer_thread_;
    std::vector<u8> spc_;
    TempoAnalyzer tempo_;
    std::vector<u8> render_chunk_;
    std::vector<float> ring_buffer_;
    std::atomic<bool> loaded_atomic_ = false;
    std::atomic<uint64_t> underrun_count_ = 0;
    bool initialized_ = false;
    bool loaded_ = false;
    bool producer_stop_ = false;
    bool producer_active_ = false;
    u32 song_seconds_ = 0;
    u32 song_length_t64_ = 0;
    u32 fade_length_t64_ = 0;
    u32 amp_ = kAmp100;
    u32 speed_ = kDefaultSpeed;
    u32 pitch_ = kDefaultPitch;
    bool pitch_async_ = false;
    u32 stereo_separation_ = kDefaultStereo;
    u32 feedback_ = kDefaultFeedback;
    u32 dsp_options_ = kDefaultUserDSPOpts;
    u32 interpolation_ = kDefaultInterpolation;
    u32 output_channels_ = kDefaultOutputChannels;
    u32 output_bits_ = kDefaultOutputBits;
    u32 output_rate_ = kDefaultRate;
    u32 mute_mask_ = 0;
    u32 noise_mask_ = 0;
    u32 buffer_channels_ = kDefaultOutputChannels;
    u32 buffer_bits_ = kDefaultOutputBits;
    size_t render_chunk_frames_ = 0;
    size_t render_chunk_capacity_frames_ = 0;
    size_t rendered_chunk_frames_ = 0;
    size_t ring_capacity_frames_ = 0;
    size_t ring_read_frame_ = 0;
    size_t ring_count_frames_ = 0;
    size_t producer_target_frames_ = 0;
};

}  // namespace

@interface SPCPlaylistItem : NSObject
@property(nonatomic, copy) NSString *sourcePath;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *titleText;
@property(nonatomic, copy) NSString *gameText;
@property(nonatomic, copy) NSString *artistText;
@property(nonatomic, copy) NSString *dumperText;
@property(nonatomic, copy) NSString *dateText;
@property(nonatomic, copy) NSString *commentText;
@property(nonatomic, copy) NSString *fileHeaderText;
@property(nonatomic, copy) NSString *renderedPath;
@property(nonatomic) NSUInteger songSeconds;
@property(nonatomic) NSUInteger fadeMilliseconds;
@property(nonatomic) NSUInteger renderSeconds;
@property(nonatomic) NSUInteger spcVersion;
@property(nonatomic) NSUInteger tagFormat;
@property(nonatomic) NSUInteger emulatorCode;
@end

@implementation SPCPlaylistItem
@end

static NSString *TrimmedSPCString(NSData *data, NSUInteger offset, NSUInteger length) {
    if (data.length < offset + length) {
        return @"";
    }
    NSData *slice = [data subdataWithRange:NSMakeRange(offset, length)];
    NSString *raw = [[NSString alloc] initWithData:slice encoding:NSISOLatin1StringEncoding];
    if (!raw) {
        return @"";
    }
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:
        @"\0\r\n\t "];
    return [raw stringByTrimmingCharactersInSet:trim];
}

static uint32_t ParseDecimalField(NSData *data, NSUInteger offset, NSUInteger length) {
    if (data.length < offset + length) {
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes + offset;
    uint32_t value = 0;
    BOOL sawDigit = NO;
    for (NSUInteger i = 0; i < length; ++i) {
        uint8_t ch = bytes[i];
        if (ch >= '0' && ch <= '9') {
            sawDigit = YES;
            value = value * 10u + (uint32_t)(ch - '0');
        } else if (ch == 0 || ch == ' ' || ch == '\r' || ch == '\n' || ch == '\t') {
            continue;
        } else {
            return 0;
        }
    }
    return sawDigit ? value : 0;
}

static uint16_t ReadLE16(NSData *data, NSUInteger offset) {
    if (data.length < offset + 2) {
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes + offset;
    return (uint16_t)(bytes[0] | (uint16_t)(bytes[1] << 8));
}

static uint32_t ReadLE32(NSData *data, NSUInteger offset) {
    if (data.length < offset + 4) {
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes + offset;
    return (uint32_t)(bytes[0] |
                      ((uint32_t)bytes[1] << 8) |
                      ((uint32_t)bytes[2] << 16) |
	                      ((uint32_t)bytes[3] << 24));
}

static NSUInteger DetectSPCTagFormat(NSData *data) {
    if (data.length < 256) {
        return 0;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (bytes[0x23] != 0x1A &&
        ((((bytes[0x2E] | bytes[0x4E] | bytes[0x6E] | bytes[0x7E] | bytes[0xB0] | bytes[0xB1]) & 0xE0) |
          bytes[0x24] | bytes[0x9E] | bytes[0xA9] | bytes[0xAC] | bytes[0xD1] | bytes[0xD2]) == 0)) {
        return 0;
    }

    if (((bytes[0xA2] | bytes[0xA3] | bytes[0xA4] | bytes[0xA5] | bytes[0xA6] |
          bytes[0xA7] | bytes[0xA8] | bytes[0xAB] | bytes[0xAF]) < 0x20) &&
        ((bytes[0xB0] >= 0x20) || (bytes[0xB1] < 0x20)) &&
        (bytes[0xD2] < 0x30)) {
        return 2;
    }

    return 1;
}

static NSString *SPCBinaryDateString(NSData *data) {
    if (data.length < 0xA2) {
        return @"";
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    const uint8_t day = bytes[0x9E];
    const uint8_t month = bytes[0x9F];
    const uint16_t year = ReadLE16(data, 0xA0);
    if (year == 0 || year >= 10000 || month == 0 || month >= 13 || day == 0 || day >= 32) {
        return @"";
    }
    return [NSString stringWithFormat:@"%04u/%02u/%02u", year, month, day];
}

static void ReadSPCTiming(NSData *data, uint32_t *songSecondsOut, uint32_t *fadeMillisecondsOut) {
    if (songSecondsOut) {
        *songSecondsOut = 0;
    }
    if (fadeMillisecondsOut) {
        *fadeMillisecondsOut = 0;
    }
    if (data.length < 256) {
        return;
    }

    const NSUInteger tagFormat = DetectSPCTagFormat(data);

    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    if (tagFormat == 2) {
        songSeconds = MIN((uint32_t)ReadLE16(data, 0xA9), 999u);
        fadeMilliseconds = MIN(ReadLE32(data, 0xAC) & 0x00FFFFFFu, 99999u);
    } else if (tagFormat == 1) {
        songSeconds = ParseDecimalField(data, 0xA9, 3);
        fadeMilliseconds = ParseDecimalField(data, 0xAC, 5);
    }

    if (songSecondsOut) {
        *songSecondsOut = songSeconds;
    }
    if (fadeMillisecondsOut) {
        *fadeMillisecondsOut = fadeMilliseconds;
    }
}

static NSUInteger SuggestedRenderSeconds(NSData *data) {
    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    ReadSPCTiming(data, &songSeconds, &fadeMilliseconds);
    if (songSeconds == 0) {
        return 120;
    }

    uint64_t totalMilliseconds = (uint64_t)songSeconds * 1000ULL + fadeMilliseconds;
    NSUInteger totalSeconds = (NSUInteger)((totalMilliseconds + 999ULL) / 1000ULL);
    if (totalSeconds < 1) {
        totalSeconds = 120;
    }
    return totalSeconds;
}

static SPCPlaylistItem *LoadPlaylistItemFromURL(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data || data.length < 0x10200) {
        return nil;
    }

    SPCPlaylistItem *item = [SPCPlaylistItem new];
    item.sourcePath = url.path;
    item.displayName = url.lastPathComponent ?: @"";
    item.fileHeaderText = TrimmedSPCString(data, 0x00, 33);
    item.spcVersion = data.length > 0x24 ? ((const uint8_t *)data.bytes)[0x24] : 0;
    item.tagFormat = DetectSPCTagFormat(data);
    item.titleText = TrimmedSPCString(data, 0x2E, 32);
    item.gameText = TrimmedSPCString(data, 0x4E, 32);
    item.dumperText = TrimmedSPCString(data, 0x6E, 16);
    item.commentText = TrimmedSPCString(data, 0x7E, 32);
    item.dateText = item.tagFormat == 2 ? SPCBinaryDateString(data) : TrimmedSPCString(data, 0x9E, 11);
    item.artistText = TrimmedSPCString(data, 0xB1, 32);
    item.emulatorCode = data.length > 0xD2 ? (((const uint8_t *)data.bytes)[0xD2] & 0x0F) : 0;
    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    ReadSPCTiming(data, &songSeconds, &fadeMilliseconds);
    item.songSeconds = songSeconds;
    item.fadeMilliseconds = fadeMilliseconds;
    item.renderSeconds = SuggestedRenderSeconds(data);

    if (item.titleText.length == 0) {
        item.titleText = item.displayName.stringByDeletingPathExtension;
    }
    if (item.gameText.length == 0) {
        item.gameText = @"(Unknown)";
    }
    if (item.artistText.length == 0) {
        item.artistText = @"(Unknown)";
    }

    return item;
}

static BOOL IsSPCFileURL(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"spc"]) {
        return YES;
    }
    return ext.length == 3 &&
        [ext hasPrefix:@"sp"] &&
        [ext characterAtIndex:2] >= '0' &&
        [ext characterAtIndex:2] <= '9';
}

static BOOL IsPlaylistFileURL(NSURL *url) {
    return [url.pathExtension.lowercaseString isEqualToString:@"lst"];
}

static NSString *CanonicalFilePath(NSString *path) {
    if (path.length == 0) {
        return @"";
    }
    return [path stringByStandardizingPath];
}

static NSString *CanonicalFileURLPath(NSURL *url) {
    return CanonicalFilePath(url.path);
}

static NSArray<NSURL *> *RegisteredApplicationURLsForBundleIdentifier(NSString *bundleID) {
    if (bundleID.length == 0) {
        return @[];
    }

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if (@available(macOS 10.10, *)) {
        CFErrorRef copyError = nullptr;
        CFArrayRef registeredURLsRef =
            LSCopyApplicationURLsForBundleIdentifier((__bridge CFStringRef)bundleID, &copyError);
        NSArray<NSURL *> *registeredURLs = CFBridgingRelease(registeredURLsRef);
        if (copyError) {
            CFRelease(copyError);
        }
        if (registeredURLs) {
            [urls addObjectsFromArray:registeredURLs];
        }
    } else {
        CFURLRef appURL = nullptr;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        OSStatus status = LSFindApplicationForInfo(kLSUnknownCreator,
                                                   (__bridge CFStringRef)bundleID,
                                                   nullptr,
                                                   nullptr,
                                                   &appURL);
#pragma clang diagnostic pop
        if (status == noErr && appURL) {
            [urls addObject:CFBridgingRelease(appURL)];
        } else if (appURL) {
            CFRelease(appURL);
        }
    }
    return urls;
}

static OSStatus EnsureLaunchServicesRegistration(BOOL *alreadyRegistered) {
    if (alreadyRegistered) {
        *alreadyRegistered = NO;
    }

    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *bundleURL = bundle.bundleURL;
    NSString *bundleID = bundle.bundleIdentifier;
    if (!bundleURL || bundleID.length == 0) {
        return paramErr;
    }

    NSString *currentPath = CanonicalFileURLPath([bundleURL URLByResolvingSymlinksInPath]);
    NSArray<NSURL *> *registeredURLs = RegisteredApplicationURLsForBundleIdentifier(bundleID);

    for (NSURL *registeredURL in registeredURLs) {
        NSString *registeredPath = CanonicalFileURLPath([registeredURL URLByResolvingSymlinksInPath]);
        if (registeredPath.length > 0 && [registeredPath isEqualToString:currentPath]) {
            if (alreadyRegistered) {
                *alreadyRegistered = YES;
            }
            return noErr;
        }
    }

    OSStatus status = LSRegisterURL((__bridge CFURLRef)bundleURL, true);
    if (status != noErr) {
        fprintf(stderr,
                "Launch Services registration failed for %s: %d\n",
                currentPath.UTF8String,
                static_cast<int>(status));
    }
    return status;
}

static void AppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = {
        static_cast<uint8_t>(value & 0xff),
        static_cast<uint8_t>((value >> 8) & 0xff),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint16_t ReadLE16Bytes(const uint8_t *bytes) {
    return static_cast<uint16_t>(bytes[0] | (static_cast<uint16_t>(bytes[1]) << 8));
}

static NSString *StringFromPlaylistBytes(NSData *data, NSStringEncoding primaryEncoding) {
    NSString *value = [[NSString alloc] initWithData:data encoding:primaryEncoding];
    if (!value) {
        value = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!value) {
        return @"";
    }
    NSRange nul = [value rangeOfString:@"\0"];
    if (nul.location != NSNotFound) {
        value = [value substringToIndex:nul.location];
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSColor *ClassicWindowColor() {
    return [NSColor colorWithCalibratedRed:0.93 green:0.93 blue:0.90 alpha:1.0];
}

static NSColor *ClassicMenuStripColor() {
    return [NSColor colorWithCalibratedRed:0.97 green:0.97 blue:0.95 alpha:1.0];
}

static NSColor *ClassicTextColor() {
    return [NSColor blackColor];
}

static NSColor *ClassicMeterBackgroundColor() {
    return ClassicWindowColor();
}

static NSColor *ClassicPlaylistBackgroundColor() {
    return [NSColor colorWithCalibratedWhite:0.96 alpha:1.0];
}

static NSColor *ClassicChannelEnableTextColor() {
    return [NSColor colorWithCalibratedRed:0.0 green:0.45 blue:0.0 alpha:1.0];
}

static NSAttributedString *ClassicButtonTitle(NSString *title, NSFont *font, NSColor *color) {
    return [[NSAttributedString alloc] initWithString:title ?: @""
                                          attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    }];
}

static NSFont *ClassicMainFont(CGFloat size) {
    return [NSFont fontWithName:@"Monaco" size:size] ?:
        [NSFont fontWithName:@"Menlo" size:size] ?:
        [NSFont userFixedPitchFontOfSize:size] ?:
        [NSFont systemFontOfSize:size];
}

static NSFont *ClassicMainBoldFont(CGFloat size) {
    if (@available(macOS 10.15, *)) {
        NSFont *font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightBold];
        if (font) {
            return font;
        }
    }
    NSFont *font = [NSFont fontWithName:@"Menlo-Bold" size:size] ?:
        [NSFont fontWithName:@"Monaco" size:size] ?:
        [NSFont userFixedPitchFontOfSize:size] ?:
        [NSFont boldSystemFontOfSize:size];
    return [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask] ?: font;
}

static dispatch_queue_t ClassicBackgroundQueue() {
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
}

static BOOL ClassicLaunchTask(NSTask *task, NSError **error) {
    @try {
        [task launch];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"Failed to launch task";
            *error = [NSError errorWithDomain:@"local.codex.spcplay.task"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}

static NSDictionary<NSAttributedStringKey, id> *ClassicBoldTextAttributes(CGFloat size, NSColor *color) {
    NSColor *textColor = color ?: ClassicTextColor();
    return @{
        NSFontAttributeName: ClassicMainBoldFont(size),
        NSForegroundColorAttributeName: textColor,
    };
}

static NSAttributedString *ClassicBoldText(NSString *text, CGFloat size, NSColor *color) {
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                          attributes:ClassicBoldTextAttributes(size, color)];
}

static NSString *ClassicHex(u32 value, NSUInteger digits) {
    NSString *format = [NSString stringWithFormat:@"%%0%luX", (unsigned long)digits];
    return [NSString stringWithFormat:format, value & (digits >= 8 ? 0xffffffffu : ((1u << (digits * 4u)) - 1u))];
}

static NSString *ClassicDec(u32 value, NSUInteger digits) {
    NSString *format = [NSString stringWithFormat:@"%%0%lud", (unsigned long)digits];
    return [NSString stringWithFormat:format, value];
}

static NSMutableString *ClassicInfoLine(NSString *text) {
    NSMutableString *line = [NSMutableString stringWithString:text ?: @""];
    while (line.length < 48) {
        [line appendString:@" "];
    }
    return line;
}

static void ClassicPut(NSMutableArray<NSMutableString *> *lines, NSUInteger row, NSUInteger column, NSString *text) {
    if (row >= lines.count || text.length == 0) {
        return;
    }
    NSMutableString *line = lines[row];
    while (line.length < column + text.length) {
        [line appendString:@" "];
    }
    [line replaceCharactersInRange:NSMakeRange(column, text.length) withString:text];
}

static NSString *ClassicJoinLines(NSArray<NSString *> *lines) {
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *ClassicUnknownIfEmpty(NSString *text) {
    return text.length ? text : @"(Unknown)";
}

static NSString *ClassicKnownTagText(SPCPlaylistItem *item, NSString *text) {
    return (item.tagFormat != 0 && text.length) ? text : @"(Unknown)";
}

static NSString *ClassicEmulatorName(NSUInteger emulatorCode) {
    switch (emulatorCode & 0x0F) {
        case 1: return @"ZSNES";
        case 2: return @"Snes9x";
        case 3: return @"ZST2SPC";
        case 4: return @"etc.";
        case 5: return @"SNEShout";
        case 6: return @"ZSNES/W";
        case 7: return @"Snes9xpp";
        case 8: return @"SNESGT";
        case 0: return @"(Unknown)";
        default: return @"(Undefined)";
    }
}

static NSString *ClassicTagFormatName(NSUInteger tagFormat) {
    switch (tagFormat) {
        case 1: return @"ID666 Text Format";
        case 2: return @"ID666 Binary Format";
        default: return @"(Unknown)";
    }
}

static NSString *ClassicFlag(BOOL enabled, unichar glyph) {
    if (!enabled) {
        return @"-";
    }
    return [NSString stringWithCharacters:&glyph length:1];
}

static NSString *ClassicPSWFlags(u8 psw) {
    static const u8 masks[8] = {0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01};
    NSMutableString *flags = [NSMutableString stringWithCapacity:8];
    for (u8 mask : masks) {
        [flags appendString:(psw & mask) ? @"0" : @"-"];
    }
    return flags;
}

static u32 ClassicFeedbackPercent(s8 feedback) {
    const int value = static_cast<int>(feedback);
    if (value < 0) {
        return static_cast<u32>(std::lround(200.0 - static_cast<double>(static_cast<u8>(feedback)) * 0.78125));
    }
    return static_cast<u32>(std::lround(static_cast<double>(value) * 0.7874015748031496));
}

static NSString *ClassicDSPFlagGlyph(BOOL enabled) {
    return enabled ? @"■" : @"-";
}

static NSArray<NSMutableString *> *ClassicInfoBaseLines(NSInteger infoMode) {
    switch (infoMode) {
        case 1:
            return @[
                ClassicInfoLine(@"MainLv   : L=    R=      EchoLv   : L=    R="),
                ClassicInfoLine(@"Delay    :    (    ms)   Feedback :    (    %)"),
                ClassicInfoLine(@"SrcAddr  :     -   _     EchoAddr :     -"),
                ClassicInfoLine(@"DSPFlags : R=  M=  E=    NoiseClk :       Hz"),
                ClassicInfoLine(@"FIR      :                            BPM :"),
            ];
        case 2:
            return @[
                ClassicInfoLine(@"    Src VL VR Pitch EX       Src VL VR Pitch EX"),
                ClassicInfoLine(@"1 :                      5 :"),
                ClassicInfoLine(@"2 :                      6 :"),
                ClassicInfoLine(@"3 :                      7 :"),
                ClassicInfoLine(@"4 :                      8 :"),
            ];
        case 3:
            return @[
                ClassicInfoLine(@"    Src ADSR/Gain   EX       Src ADSR/Gain   EX"),
                ClassicInfoLine(@"1 :                      5 :"),
                ClassicInfoLine(@"2 :                      6 :"),
                ClassicInfoLine(@"3 :                      7 :"),
                ClassicInfoLine(@"4 :                      8 :"),
            ];
        case 4:
            return @[
                ClassicInfoLine(@"    Src On Flags   F R       Src On Flags   F R"),
                ClassicInfoLine(@"1 :                      5 :"),
                ClassicInfoLine(@"2 :                      6 :"),
                ClassicInfoLine(@"3 :                      7 :"),
                ClassicInfoLine(@"4 :                      8 :"),
            ];
        case 5:
            return @[
                ClassicInfoLine(@"    Src Addr Loop Read       Src Addr Loop Read"),
                ClassicInfoLine(@"1 :                      5 :"),
                ClassicInfoLine(@"2 :                      6 :"),
                ClassicInfoLine(@"3 :                      7 :"),
                ClassicInfoLine(@"4 :                      8 :"),
            ];
        case 6:
            return @[
                ClassicInfoLine(@"Artist   : "),
                ClassicInfoLine(@"Dumper   : "),
                ClassicInfoLine(@"Date     : "),
                ClassicInfoLine(@"Comment  : "),
                ClassicInfoLine(@"PlayTime : "),
            ];
        case 7:
            return @[
                ClassicInfoLine(@"Header   : "),
                ClassicInfoLine(@"Version  : "),
                ClassicInfoLine(@"TagType  : "),
                ClassicInfoLine(@"Emulator : "),
                ClassicInfoLine(@"Register : PC=     YA=     X=   SP=   "),
            ];
        case 8:
            return @[
                ClassicInfoLine(@"Port  In :                Out :"),
                ClassicInfoLine(@"Work 0-3 :"),
                ClassicInfoLine(@"     4-7 :"),
                ClassicInfoLine(@"CmpParam :                     Wait :"),
                ClassicInfoLine(@"UsedSize :        (Ptr=      Data=      SP=   )"),
            ];
        default:
            return @[
                ClassicInfoLine(@""),
                ClassicInfoLine(@""),
                ClassicInfoLine(@""),
                ClassicInfoLine(@""),
                ClassicInfoLine(@""),
            ];
    }
}

static NSString *ClassicInfoText(NSInteger infoMode, SPCPlaylistItem *item, const LiveMeterSnapshot &snapshot, BOOL loaded) {
    NSMutableArray<NSMutableString *> *lines = [ClassicInfoBaseLines(infoMode) mutableCopy];
    static const char *noiseRates[32] = {
        "00000", "00016", "00021", "00025", "00031", "00042", "00050", "00063",
        "00083", "00100", "00125", "00167", "00200", "00250", "00333", "00400",
        "00500", "00667", "00800", "01000", "01333", "01600", "02000", "02667",
        "03200", "04000", "05333", "06400", "08000", "10667", "16000", "32000",
    };

    switch (infoMode) {
        case 1: {
            ClassicPut(lines, 0, 13, ClassicHex(static_cast<u8>(snapshot.master_volume_left), 2));
            ClassicPut(lines, 0, 19, ClassicHex(static_cast<u8>(snapshot.master_volume_right), 2));
            ClassicPut(lines, 0, 38, ClassicHex(static_cast<u8>(snapshot.echo_volume_left), 2));
            ClassicPut(lines, 0, 44, ClassicHex(static_cast<u8>(snapshot.echo_volume_right), 2));
            ClassicPut(lines, 1, 11, ClassicHex(snapshot.echo_delay, 2));
            ClassicPut(lines, 1, 15, ClassicDec((snapshot.echo_delay & 0x0F) << 4, 3));
            ClassicPut(lines, 1, 36, ClassicHex(static_cast<u8>(snapshot.echo_feedback), 2));
            ClassicPut(lines, 1, 40, ClassicDec(ClassicFeedbackPercent(snapshot.echo_feedback), 3));
            u32 sourceStart = static_cast<u32>(snapshot.source_directory) << 8;
            u32 sourceEnd = snapshot.t64_count ? sourceStart + 0x3ffu : sourceStart;
            u32 echoStart = static_cast<u32>(snapshot.echo_waveform) << 8;
            u32 echoEnd = echoStart;
            if (snapshot.t64_count) {
                echoEnd += snapshot.echo_delay ? (((snapshot.echo_delay & 0x0F) << 11) - 1u) : 3u;
            }
            ClassicPut(lines, 2, 11, ClassicHex(sourceStart, 4));
            ClassicPut(lines, 2, 16, ClassicHex(sourceEnd, 4));
            ClassicPut(lines, 2, 36, ClassicHex(echoStart, 4));
            ClassicPut(lines, 2, 41, ClassicHex(echoEnd, 4));
            ClassicPut(lines, 3, 13, ClassicDSPFlagGlyph((snapshot.flags & 0x80) != 0));
            ClassicPut(lines, 3, 17, ClassicDSPFlagGlyph((snapshot.flags & 0x40) != 0));
            ClassicPut(lines, 3, 21, ClassicDSPFlagGlyph((snapshot.flags & 0x20) != 0));
            ClassicPut(lines, 3, 36, [NSString stringWithUTF8String:noiseRates[snapshot.flags & 0x1F]]);
            for (NSUInteger i = 0; i < 8; ++i) {
                ClassicPut(lines, 4, 11 + i * 3, ClassicHex(static_cast<u8>(snapshot.fir[i]), 2));
            }
            ClassicPut(lines, 4, 44, snapshot.bpm ? ClassicDec(snapshot.bpm, 3) : @"---");
            break;
        }
        case 2:
            for (NSUInteger i = 0; i < 8; ++i) {
                const NSUInteger x = (i / 4) * 25 + 4;
                const NSUInteger row = (i % 4) + 1;
                ClassicPut(lines, row, x, ClassicHex(snapshot.voice_source[i], 2));
                ClassicPut(lines, row, x + 4, ClassicHex(static_cast<u8>(snapshot.voice_volume_left[i]), 2));
                ClassicPut(lines, row, x + 7, ClassicHex(static_cast<u8>(snapshot.voice_volume_right[i]), 2));
                ClassicPut(lines, row, x + 10, ClassicHex(snapshot.voice_pitch[i], 4));
                ClassicPut(lines, row, x + 16, ClassicHex(static_cast<u8>(snapshot.voice_env[i]), 2));
            }
            break;
        case 3:
            for (NSUInteger i = 0; i < 8; ++i) {
                const NSUInteger x = (i / 4) * 25 + 4;
                const NSUInteger row = (i % 4) + 1;
                const u8 adsr1 = snapshot.voice_adsr1[i];
                const u8 adsr2 = snapshot.voice_adsr2[i];
                const u8 gain = snapshot.voice_gain[i];
                const u8 envMode = snapshot.voice_envelope_mode[i] & 0x0F;
                ClassicPut(lines, row, x, ClassicHex(snapshot.voice_source[i], 2));
                if (!loaded || snapshot.t64_count == 0) {
                    ClassicPut(lines, row, x + 4, @"VV");
                    ClassicPut(lines, row, x + 7, @"V");
                    ClassicPut(lines, row, x + 9, @"V");
                    ClassicPut(lines, row, x + 11, @"V");
                    ClassicPut(lines, row, x + 13, @"00");
                } else if (adsr1 & 0x80) {
                    const u16 adsr = static_cast<u16>((adsr1 << 8) | adsr2);
                    ClassicPut(lines, row, x + 4, @"AD");
                    ClassicPut(lines, row, x + 7, ClassicHex((adsr >> 8) & 0x0F, 1));
                    ClassicPut(lines, row, x + 8, envMode == 0x0A ? @"A" : @"-");
                    ClassicPut(lines, row, x + 9, ClassicHex((adsr >> 12) & 0x07, 1));
                    ClassicPut(lines, row, x + 10, envMode == 0x0D ? @"D" : @"-");
                    ClassicPut(lines, row, x + 11, ClassicHex((adsr >> 5) & 0x07, 1));
                    ClassicPut(lines, row, x + 12, envMode == 0x09 ? @"S" : @"-");
                    ClassicPut(lines, row, x + 13, ClassicHex(adsr & 0x1F, 2));
                } else {
                    const u8 releaseMode = static_cast<u8>(envMode | (snapshot.voice_mix_flags[i] & MFLG_OFF));
                    ClassicPut(lines, row, x + 4, @"GN");
                    ClassicPut(lines, row, x + 7, ClassicHex((gain >> 7) & 0x01, 1));
                    if (gain & 0x80) {
                        ClassicPut(lines, row, x + 9, ClassicHex((gain >> 6) & 0x01, 1));
                        ClassicPut(lines, row, x + 10, (releaseMode == 0x02 || releaseMode == 0x06) ? @"D" :
                                                    ((releaseMode == 0x00 || releaseMode == 0x01) ? @"I" : @"-"));
                        ClassicPut(lines, row, x + 11, ClassicHex((gain >> 5) & 0x01, 1));
                        ClassicPut(lines, row, x + 12, (releaseMode == 0x02 || releaseMode == 0x00) ? @"L" :
                                                    (releaseMode == 0x06 ? @"B" : (releaseMode == 0x01 ? @"E" : @"-")));
                        ClassicPut(lines, row, x + 13, ClassicHex(gain & 0x1F, 2));
                    } else {
                        ClassicPut(lines, row, x + 9, @"V");
                        ClassicPut(lines, row, x + 11, @"V");
                        ClassicPut(lines, row, x + 12, releaseMode == 0x07 ? @"D" : @"-");
                        ClassicPut(lines, row, x + 13, ClassicHex(gain & 0x7F, 2));
                    }
                }
                ClassicPut(lines, row, x + 16, ClassicHex(static_cast<u8>(snapshot.voice_env[i]), 2));
            }
            break;
        case 4:
            for (NSUInteger i = 0; i < 8; ++i) {
                const NSUInteger x = (i / 4) * 25 + 4;
                const NSUInteger row = (i % 4) + 1;
                const u8 bit = static_cast<u8>(1u << i);
                const BOOL audible = snapshot.voice_peak_left[i] > 0.0 || snapshot.voice_peak_right[i] > 0.0;
                const u8 block = snapshot.voice_block_header[i];
                NSString *flagText = [NSString stringWithFormat:@"%@%@%@%@%@%@",
                    ClassicFlag((snapshot.echo_on & bit) != 0, 'E'),
                    ClassicFlag((snapshot.pitch_mod_on & bit) != 0, 'P'),
                    ClassicFlag((snapshot.noise_on & bit) != 0, 'N'),
                    ClassicFlag((snapshot.key_on & bit) != 0, 'K'),
                    ClassicFlag((snapshot.key_off & bit) != 0, 'O'),
                    ClassicFlag((snapshot.end_waveform & bit) != 0, 'X')];
                u8 rangeFlag = 0;
                if ((block & 0x0C) == 0) {
                    rangeFlag = 0;
                } else if ((block & 0x08) == 0) {
                    rangeFlag = 1;
                } else if ((block & 0x04) == 0) {
                    rangeFlag = 2;
                } else {
                    rangeFlag = 3;
                }
                ClassicPut(lines, row, x, ClassicHex(snapshot.voice_source[i], 2));
                ClassicPut(lines, row, x + 4, audible ? @"♪" : @"--");
                ClassicPut(lines, row, x + 7, flagText);
                ClassicPut(lines, row, x + 15, ClassicHex(rangeFlag, 1));
                ClassicPut(lines, row, x + 17, ClassicHex(block >> 4, 1));
            }
            break;
        case 5:
            for (NSUInteger i = 0; i < 8; ++i) {
                const NSUInteger x = (i / 4) * 25 + 4;
                const NSUInteger row = (i % 4) + 1;
                ClassicPut(lines, row, x, ClassicHex(snapshot.voice_source[i], 2));
                ClassicPut(lines, row, x + 4, ClassicHex(snapshot.voice_source_start[i], 4));
                ClassicPut(lines, row, x + 9, ClassicHex(snapshot.voice_source_loop[i], 4));
                ClassicPut(lines, row, x + 14, ClassicHex(snapshot.voice_current_block[i], 4));
            }
            break;
        case 6: {
            ClassicPut(lines, 0, 11, ClassicKnownTagText(item, item.artistText));
            ClassicPut(lines, 1, 11, ClassicKnownTagText(item, item.dumperText));
            ClassicPut(lines, 2, 11, ClassicKnownTagText(item, item.dateText));
            ClassicPut(lines, 3, 11, ClassicKnownTagText(item, item.commentText));
            if (item.tagFormat == 0 || item.songSeconds == 0) {
                ClassicPut(lines, 4, 11, @"(Unknown)");
            } else {
                NSString *song = [NSString stringWithFormat:@"%lu s  ",
                                  (unsigned long)item.songSeconds];
                ClassicPut(lines, 4, 11, song);
                if (item.fadeMilliseconds == 0) {
                    ClassicPut(lines, 4, 25, @"(No Fadeout)");
                } else {
                    ClassicPut(lines, 4, 25, [NSString stringWithFormat:@"FadeTime : %lu ms",
                                               (unsigned long)item.fadeMilliseconds]);
                }
            }
            break;
        }
        case 7: {
            static constexpr NSUInteger kPSWFlagColumn = 39;
            ClassicPut(lines, 0, 11, ClassicUnknownIfEmpty(item.fileHeaderText));
            ClassicPut(lines, 1, 11, item.spcVersion ? [NSString stringWithFormat:@"%lu", (unsigned long)item.spcVersion] : @"(Unknown)");
            ClassicPut(lines, 2, 11, ClassicTagFormatName(item.tagFormat));
            NSString *emulator = item.tagFormat == 0 ? @"(Unknown)" : ClassicEmulatorName(item.emulatorCode);
            ClassicPut(lines, 3, 11, emulator);
            ClassicPut(lines, 3, kPSWFlagColumn, @"NVPBHIZC");
            ClassicPut(lines, 4, 14, ClassicHex(snapshot.spc_pc, 4));
            ClassicPut(lines, 4, 22, ClassicHex((snapshot.spc_y << 8) | snapshot.spc_a, 4));
            ClassicPut(lines, 4, 29, ClassicHex(snapshot.spc_x, 2));
            ClassicPut(lines, 4, 35, ClassicHex(snapshot.spc_sp, 2));
            ClassicPut(lines, 4, kPSWFlagColumn, ClassicPSWFlags(snapshot.spc_psw));
            break;
        }
        case 8:
            for (NSUInteger i = 0; i < 4; ++i) {
                ClassicPut(lines, 0, i * 3 + 11, ClassicHex(snapshot.apu_ports[i], 2));
                NSString *inputWait = ((i == 0 && (snapshot.script_status_flags & 0x0C)) ||
                                       snapshot.script_int_in_port == 0x80 + i) ? @"o" : @" ";
                ClassicPut(lines, 0, i * 3 + 13, inputWait);
                ClassicPut(lines, 0, i * 3 + 32, ClassicHex(snapshot.out_ports[i], 2));
                NSString *outputWait = snapshot.script_int_out_port == 0x80 + i ? @"o" : @" ";
                ClassicPut(lines, 0, i * 3 + 34, outputWait);
            }
            for (NSUInteger i = 0; i < 4; ++i) {
                ClassicPut(lines, 1, i * 9 + 11, ClassicHex(snapshot.script_work[i], 8));
                ClassicPut(lines, 2, i * 9 + 11, ClassicHex(snapshot.script_work[i + 4], 8));
            }
            ClassicPut(lines, 3, 11, ClassicHex(snapshot.script_cmp[0], 8));
            ClassicPut(lines, 3, 20, ClassicHex(snapshot.script_cmp[1], 8));
            ClassicPut(lines, 3, 38, ClassicHex(snapshot.script_wait_count, 8));
            ClassicPut(lines, 4, 11, ClassicHex(0, 6));
            ClassicPut(lines, 4, 23, ClassicHex(snapshot.script_pointer, 5));
            ClassicPut(lines, 4, 34, ClassicHex(snapshot.script_data, 5));
            ClassicPut(lines, 4, 43, [NSString stringWithFormat:@"%@%@%@",
                ClassicHex(snapshot.script_stack, 2),
                (snapshot.script_status_flags & 0x01) ? @"U" : @"V",
                @""]);
            break;
        default:
            break;
    }

    return ClassicJoinLines(lines);
}

static void SetClassicButtonTitleColor(NSButton *button, NSString *title, NSColor *color) {
    button.title = title ?: @"";
    button.attributedTitle = ClassicButtonTitle(button.title,
                                                button.font ?: ClassicMainFont(10.0),
                                                color ?: ClassicTextColor());
}

static void SetClassicButtonTitle(NSButton *button, NSString *title) {
    SetClassicButtonTitleColor(button, title, ClassicTextColor());
}

static NSTextField *MakeLabel(NSRect frame, BOOL selectable) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.selectable = selectable;
    label.alignment = NSTextAlignmentLeft;
    label.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.font = ClassicMainFont(13.0);
    label.textColor = ClassicTextColor();
    label.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    return label;
}

static NSButton *MakeButton(NSRect frame, NSString *title, SEL action, id target) {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.bezelStyle = NSBezelStyleSmallSquare;
    button.cell.controlSize = NSControlSizeSmall;
    button.font = ClassicMainFont(10.0);
    button.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    SetClassicButtonTitle(button, title);
    button.target = target;
    button.action = action;
    return button;
}

static NSButton *MakeMenuButton(NSRect frame, NSString *title, SEL action, id target) {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.bordered = NO;
    button.transparent = NO;
    button.font = [NSFont systemFontOfSize:12.0];
    button.alignment = NSTextAlignmentLeft;
    button.focusRingType = NSFocusRingTypeNone;
    button.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    SetClassicButtonTitle(button, title);
    button.target = target;
    button.action = action;
    return button;
}

@interface ClassicInfoTextView : NSView
@property(nonatomic, copy) NSString *text;
@property(nonatomic) NSInteger infoMode;
@end

@implementation ClassicInfoTextView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _text = @"";
        _infoMode = 0;
        self.wantsLayer = YES;
        self.layer.backgroundColor = ClassicMeterBackgroundColor().CGColor;
        self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setText:(NSString *)text {
    _text = [text copy] ?: @"";
    self.needsDisplay = YES;
}

- (void)setInfoMode:(NSInteger)infoMode {
    _infoMode = infoMode;
    self.needsDisplay = YES;
}

- (BOOL)isBoldValueAtRow:(NSUInteger)row column:(NSUInteger)column {
    auto inRange = [&](NSUInteger start, NSUInteger length) -> BOOL {
        return column >= start && column < start + length;
    };

    if (self.infoMode == 1) {
        switch (row) {
            case 0:
                return inRange(13, 2) || inRange(19, 2) || inRange(38, 2) || inRange(44, 2);
            case 1:
                return inRange(11, 2) || inRange(15, 3) || inRange(36, 2) || inRange(40, 3);
            case 2:
                return inRange(11, 4) || inRange(16, 4) || inRange(36, 4) || inRange(41, 4);
            case 3:
                return inRange(36, 5);
            case 4:
                return inRange(11, 23) || inRange(44, 3);
            default:
                return NO;
        }
    }

    if (self.infoMode == 7) {
        return row == 4 && (inRange(14, 4) || inRange(22, 4) || inRange(29, 2) ||
                            inRange(35, 2) || inRange(39, 8));
    }

    if (self.infoMode == 8) {
        switch (row) {
            case 0:
                return inRange(11, 2) || inRange(14, 2) || inRange(17, 2) || inRange(20, 2) ||
                       inRange(32, 2) || inRange(35, 2) || inRange(38, 2) || inRange(41, 2);
            case 1:
            case 2:
                return inRange(11, 8) || inRange(20, 8) || inRange(29, 8) || inRange(38, 8);
            case 3:
                return inRange(11, 8) || inRange(20, 8) || inRange(38, 8);
            case 4:
                return inRange(11, 6) || inRange(23, 5) || inRange(34, 5) || inRange(43, 2);
            default:
                return NO;
        }
    }

    if (self.infoMode < 2 || self.infoMode > 5 || row == 0) {
        return NO;
    }

    const NSUInteger base = column < 25 ? 4 : 29;
    switch (self.infoMode) {
        case 2:
            return inRange(base, 2) || inRange(base + 4, 2) || inRange(base + 7, 2) ||
                   inRange(base + 10, 4) || inRange(base + 16, 2);
        case 3:
            return inRange(base, 2) || inRange(base + 7, 1) || inRange(base + 9, 1) ||
                   inRange(base + 11, 1) || inRange(base + 13, 2) || inRange(base + 16, 2);
        case 4:
            return inRange(base, 2) || inRange(base + 4, 2) || inRange(base + 7, 6) ||
                   inRange(base + 15, 1) || inRange(base + 17, 1);
        case 5:
            return inRange(base, 2) || inRange(base + 4, 4) || inRange(base + 9, 4) ||
                   inRange(base + 14, 4);
        default:
            return NO;
    }
}

- (BOOL)isChannelEnableFlagAtRow:(NSUInteger)row column:(NSUInteger)column character:(unichar)ch {
    if (self.infoMode != 4 || row == 0 || ch != 'E') {
        return NO;
    }
    const NSUInteger base = column < 25 ? 4 : 29;
    return column == base + 7;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [ClassicMeterBackgroundColor() setFill];
    NSRectFill(self.bounds);

    NSFont *regularFont = ClassicMainFont(9.0);
    NSFont *boldValueFont = ClassicMainBoldFont(9.0);
    NSDictionary *regularAttrs = @{
        NSFontAttributeName: regularFont,
        NSForegroundColorAttributeName: ClassicTextColor(),
    };
    NSDictionary *boldValueAttrs = @{
        NSFontAttributeName: boldValueFont,
        NSForegroundColorAttributeName: ClassicTextColor(),
    };
    NSDictionary *boldGreenValueAttrs = @{
        NSFontAttributeName: boldValueFont,
        NSForegroundColorAttributeName: ClassicChannelEnableTextColor(),
    };
    NSArray<NSString *> *lines = [self.text componentsSeparatedByString:@"\n"];
    const CGFloat lineHeight = 14.0;
    const CGFloat cellWidth = [@"0" sizeWithAttributes:regularAttrs].width;
    for (NSUInteger i = 0; i < lines.count; ++i) {
        NSString *line = lines[i];
        if ((self.infoMode < 1 || self.infoMode > 5) && self.infoMode != 7 && self.infoMode != 8) {
            [line drawAtPoint:NSMakePoint(0.0, i * lineHeight) withAttributes:regularAttrs];
            continue;
        }

        for (NSUInteger column = 0; column < line.length; ++column) {
            unichar ch = [line characterAtIndex:column];
            if (ch == ' ') {
                continue;
            }
            NSString *text = [NSString stringWithCharacters:&ch length:1];
            NSDictionary *attrs = [self isChannelEnableFlagAtRow:i column:column character:ch] ? boldGreenValueAttrs :
                                  ([self isBoldValueAtRow:i column:column] ? boldValueAttrs : regularAttrs);
            [text drawAtPoint:NSMakePoint(column * cellWidth, i * lineHeight) withAttributes:attrs];
        }
    }
}

@end

struct ClassicMenuChoice {
    const char *title;
    NSInteger value;
};

static constexpr NSInteger kMenuToggleAllEnable = 1;
static constexpr NSInteger kMenuToggleAllDisable = 2;
static constexpr NSInteger kMenuToggleAllReverse = 3;
static constexpr NSInteger kPlayTimeEndless = 0;
static constexpr NSInteger kPlayTimeID666 = 1;
static constexpr NSInteger kPlayTimeDefault = 2;

static NSMenuItem *AddMenuItem(NSMenu *menu, NSString *title, SEL action, NSInteger tag, id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    item.tag = tag;
    [menu addItem:item];
    return item;
}

static NSMenu *AddSubmenu(NSMenu *parent, NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = submenu;
    [parent addItem:item];
    return submenu;
}

static void AddMenuChoices(NSMenu *menu, const ClassicMenuChoice *choices, size_t count, SEL action, id target) {
    for (size_t i = 0; i < count; ++i) {
        if (!choices[i].title) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }
        AddMenuItem(menu, [NSString stringWithUTF8String:choices[i].title], action, choices[i].value, target);
    }
}

static constexpr ClassicMenuChoice kOutputChannelChoices[] = {
    {"1 Channel  (Monaural)", 1},
    {"2 Channels  (Stereo)", 2},
};

static constexpr ClassicMenuChoice kOutputBitChoices[] = {
    {"8-Bit", 8},
    {"16-Bit [Normal]", 16},
    {"24-Bit", 24},
    {"32-Bit  (int)", 32},
    {"32-Bit  (float) [HQ]", -32},
};

static constexpr ClassicMenuChoice kOutputRateChoices[] = {
    {"8,000 Hz", 8000},
    {"10,000 Hz", 10000},
    {"11,025 Hz", 11025},
    {"12,000 Hz", 12000},
    {"16,000 Hz", 16000},
    {"20,000 Hz", 20000},
    {"22,050 Hz", 22050},
    {"24,000 Hz", 24000},
    {"32,000 Hz [Normal]", 32000},
    {"40,000 Hz", 40000},
    {"44,100 Hz [CD]", 44100},
    {"48,000 Hz [DVD]", 48000},
    {"64,000 Hz", 64000},
    {"80,000 Hz", 80000},
    {"88,200 Hz", 88200},
    {"96,000 Hz", 96000},
};

static constexpr ClassicMenuChoice kInterpolationChoices[] = {
    {"Disable", INT_NONE},
    {"Liner", INT_LINEAR},
    {"Cubic Spline", INT_CUBIC},
    {"SNES Gaussian Table [Normal]", INT_GAUSS},
    {"Sinc Function [HQ]", INT_SINC},
    {"Gaussian Function", INT_GAUSS4},
};

static constexpr ClassicMenuChoice kPitchChoices[] = {
    {"Normal", 32000},
    {"OLD Sound Blaster Card", 32458},
    {"OLD ZSNES, Snes9x", 32768},
};

static constexpr ClassicMenuChoice kPitchKeyChoices[] = {
    {"+ 6", 45255},
    {"+ 5", 42715},
    {"+ 4", 40317},
    {"+ 3", 38055},
    {"+ 2", 35919},
    {"+ 1", 33903},
    {" 0 ", 32000},
    {"- 1", 30204},
    {"- 2", 28509},
    {"- 3", 26909},
    {"- 4", 25398},
    {"- 5", 23973},
    {"- 6", 22627},
};

static constexpr ClassicMenuChoice kStereoSeparationChoices[] = {
    {"0 % [Mix]", FixedPercent(0)},
    {"10 %", FixedPercent(10)},
    {"20 %", FixedPercent(20)},
    {"25 %", FixedPercent(25)},
    {"30 %", FixedPercent(30)},
    {"33 %", FixedPercent(33)},
    {"40 %", FixedPercent(40)},
    {"50 % [Normal]", FixedPercent(50)},
    {"60 %", FixedPercent(60)},
    {"67 %", FixedPercent(67)},
    {"70 %", FixedPercent(70)},
    {"75 %", FixedPercent(75)},
    {"80 %", FixedPercent(80)},
    {"90 %", FixedPercent(90)},
    {"100 % [Separate]", FixedPercent(100)},
};

static constexpr ClassicMenuChoice kFeedbackChoices[] = {
    {"0 % [Normal]", FixedPercent(0)},
    {"10 %", FixedPercent(10)},
    {"20 %", FixedPercent(20)},
    {"25 %", FixedPercent(25)},
    {"30 %", FixedPercent(30)},
    {"33 %", FixedPercent(33)},
    {"40 %", FixedPercent(40)},
    {"50 % [Mix]", FixedPercent(50)},
    {"60 %", FixedPercent(60)},
    {"67 %", FixedPercent(67)},
    {"70 %", FixedPercent(70)},
    {"75 %", FixedPercent(75)},
    {"80 %", FixedPercent(80)},
    {"90 %", FixedPercent(90)},
    {"100 % [Reverse]", FixedPercent(100)},
};

static constexpr ClassicMenuChoice kSpeedChoices[] = {
    {"1 % [Very Slow]", FixedBasis(100)},
    {"5 %", FixedBasis(500)},
    {"10 %", FixedBasis(1000)},
    {"20 %", FixedBasis(2000)},
    {nullptr, 0},
    {"25 % [Slow]", FixedBasis(2500)},
    {"33 %", FixedBasis(3333)},
    {"40 %", FixedBasis(4000)},
    {"50 %", FixedBasis(5000)},
    {"67 %", FixedBasis(6667)},
    {"75 %", FixedBasis(7500)},
    {"80 %", FixedBasis(8000)},
    {"90 %", FixedBasis(9000)},
    {"100 % [Normal]", FixedPercent(100)},
    {"110 %", FixedPercent(110)},
    {"125 %", FixedPercent(125)},
    {"133 %", FixedPercent(133)},
    {"150 %", FixedPercent(150)},
    {"200 %", FixedPercent(200)},
    {"250 %", FixedPercent(250)},
    {"300 %", FixedPercent(300)},
    {"400 % [Fast]", FixedPercent(400)},
    {nullptr, 0},
    {"500 %", FixedPercent(500)},
    {"600 %", FixedPercent(600)},
    {"700 %", FixedPercent(700)},
    {"800 % [Very Fast]", FixedPercent(800)},
};

static constexpr ClassicMenuChoice kAmpChoices[] = {
    {"5 % [Very Low]", FixedBasis(500)},
    {"10 %", FixedBasis(1000)},
    {"15 %", FixedBasis(1500)},
    {"20 %", FixedBasis(2000)},
    {nullptr, 0},
    {"25 % [Low]", FixedBasis(2500)},
    {"33 %", FixedBasis(3333)},
    {"40 %", FixedBasis(4000)},
    {"50 %", FixedBasis(5000)},
    {"67 %", FixedBasis(6667)},
    {"75 %", FixedBasis(7500)},
    {"80 %", FixedBasis(8000)},
    {"90 %", FixedBasis(9000)},
    {"100 % [Normal]", FixedPercent(100)},
    {"110 %", FixedPercent(110)},
    {"125 %", FixedPercent(125)},
    {"133 %", FixedPercent(133)},
    {"150 %", FixedPercent(150)},
    {"200 %", FixedPercent(200)},
    {"250 %", FixedPercent(250)},
    {"300 %", FixedPercent(300)},
    {"400 % [High]", FixedPercent(400)},
};

static constexpr ClassicMenuChoice kExpansionFlagChoices[] = {
    {"SNES Low-Pass Filter", DSP_ANALOG},
    {"SNES Echo/FIR Method", DSP_ECHOFIR},
    {nullptr, 0},
    {"BASS BOOST", DSP_BASS},
    {"Old ADPCM Decoder", DSP_OLDSMP},
    {"Opposite-Phase Surround", DSP_SURND},
    {"Reverse Stereo", DSP_REVERSE},
    {"Synchronize Envelope with Speed", DSP_ENVSPD},
    {nullptr, 0},
    {"Disable Surround", DSP_NOSURND},
    {"Disable Main", DSP_NOMAIN},
    {"Disable Echo", DSP_NOECHO},
    {"Disable FIR Filter", DSP_NOFIR},
    {"Disable Pitch Modulation", DSP_NOPMOD},
    {"Disable Pitch Bend", DSP_NOPREAD},
    {"Disable Pitch Limit", DSP_NOPLMT},
    {"Disable Envelope", DSP_NOENV},
    {"Disable Noise Flags", DSP_NONOISE},
};

static constexpr ClassicMenuChoice kPlayOrderChoices[] = {
    {"Stop", 0},
    {"Next Item", 1},
    {"Previous Item", 2},
    {"Random", 3},
    {"Shuffle", 4},
    {"Repeat", 5},
};

static constexpr ClassicMenuChoice kSeekChoices[] = {
    {"1 s", 1000},
    {"2 s", 2000},
    {"3 s", 3000},
    {"4 s", 4000},
    {"5 s", 5000},
    {"10 s", 10000},
};

static constexpr ClassicMenuChoice kInfoChoices[] = {
    {"Graphic Indicator", 0},
    {"DSP/BPM", 1},
    {"Channel 1", 2},
    {"Channel 2", 3},
    {"Channel 3", 4},
    {"Channel 4", 5},
    {"SPC Tags 1", 6},
    {"SPC Tags 2", 7},
    {"Script700 Debug", 8},
};

static constexpr ClassicMenuChoice kNumericFontChoices[] = {
    {"Analog like", 0},
    {"Digital/7-segment like", 1},
};

static constexpr ClassicMenuChoice kPriorityChoices[] = {
    {"Realtime", 0},
    {"High", 1},
    {"Above Normal", 2},
    {"Normal", 3},
    {"Below Normal", 4},
    {"Low", 5},
};

static NSString *FormatPlaybackTime(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0.0) {
        seconds = 0.0;
    }
    NSUInteger total = (NSUInteger)floor(seconds);
    NSUInteger hours = total / 3600;
    NSUInteger minutes = (total / 60) % 60;
    NSUInteger secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%lu:%02lu:%02lu",
                                          (unsigned long)hours,
                                          (unsigned long)minutes,
                                          (unsigned long)secs];
    }
    return [NSString stringWithFormat:@"%lu:%02lu",
                                      (unsigned long)minutes,
                                      (unsigned long)secs];
}

static NSString *FormatPlaybackTimePrecise(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0.0) {
        seconds = 0.0;
    }
    NSUInteger whole = (NSUInteger)floor(seconds);
    NSUInteger milliseconds = (NSUInteger)llround((seconds - floor(seconds)) * 1000.0);
    if (milliseconds >= 1000) {
        milliseconds = 0;
        ++whole;
    }
    NSUInteger hours = whole / 3600;
    NSUInteger minutes = (whole / 60) % 60;
    NSUInteger secs = whole % 60;
    return [NSString stringWithFormat:@"%lu:%02lu:%02lu.%03lu",
                                      (unsigned long)hours,
                                      (unsigned long)minutes,
                                      (unsigned long)secs,
                                      (unsigned long)milliseconds];
}

static constexpr u8 kClassicMeterHeight = 48;
static constexpr u8 kClassicMeterDecay = 1;
static constexpr double kClassicChannelHideMilliseconds = 1000.0;
static constexpr double kClassicMeterTickMilliseconds = 1000.0 / 60.0;

enum ClassicMeterColorIndex : int {
    ClassicMeterGreen = 0,
    ClassicMeterOrange = 1,
    ClassicMeterWater = 2,
    ClassicMeterRed = 3,
    ClassicMeterBlue = 4,
    ClassicMeterPurple = 5,
};

struct ClassicChannelMeterState {
    u8 channel_level_left = 0;
    u8 channel_level_right = 0;
    u8 channel_volume_left = 0;
    u8 channel_volume_right = 0;
    u8 channel_pitch = 0;
    u8 channel_envelope = 0;
    bool channel_show = false;
    bool echo_on = false;
    bool pitch_mod_on = false;
    bool noise_on = false;
    double silent_milliseconds = kClassicChannelHideMilliseconds;
};

struct ClassicMeterState {
    u8 master_level_left = 0;
    u8 master_level_right = 0;
    u8 master_volume_left = 0;
    u8 master_volume_right = 0;
    u8 master_echo_left = 0;
    u8 master_echo_right = 0;
    u8 master_delay = 0;
    u8 master_feedback = 0;
    ClassicChannelMeterState channel[8];
};

static u8 ClassicLevelAbs(s8 level) {
    return static_cast<u8>(std::min<int>(kClassicMeterHeight, (std::abs(static_cast<int>(level)) * 49) >> 7));
}

static u8 ClassicLevelDelay(u8 level) {
    return static_cast<u8>(std::min<int>(kClassicMeterHeight, ((level & 0x0f) * 52) >> 4));
}

static u8 ClassicVolumeLevel(double level) {
    return static_cast<u8>(std::clamp<int>(static_cast<int>(std::lround(18.0 * std::log10(level * 0.005 + 1.0))),
                                           0,
                                           kClassicMeterHeight));
}

static u8 ClassicPitchLevel(u16 level) {
    return static_cast<u8>(std::clamp<int>(static_cast<int>(std::lround(22.0 * std::log10((level & 0x3fff) + 1.0))) - 44,
                                           0,
                                           kClassicMeterHeight));
}

static u8 ClassicDecayLevel(u8 current, u8 target) {
    const u8 decayed = current > kClassicMeterDecay ? current - kClassicMeterDecay : 0;
    return std::max(decayed, target);
}

static NSColor *ClassicMeterFrameColor() {
    return [NSColor blackColor];
}

static NSColor *ClassicMeterColor(ClassicMeterColorIndex colorIndex, u8 sourceRow) {
    static const int startR[] = {0, 224, 0, 212, 0, 120};
    static const int startG[] = {164, 112, 112, 0, 0, 0};
    static const int startB[] = {0, 0, 224, 0, 240, 240};
    static const int endR[] = {0, 160, 0, 112, 0, 64};
    static const int endG[] = {96, 80, 80, 0, 0, 0};
    static const int endB[] = {0, 0, 160, 0, 128, 128};
    const int index = std::clamp<int>(colorIndex, 0, 5);
    const double t = std::clamp<double>(sourceRow, 0, kClassicMeterHeight - 1) / 47.0;
    const double r = (startR[index] + (endR[index] - startR[index]) * t) / 255.0;
    const double g = (startG[index] + (endG[index] - startG[index]) * t) / 255.0;
    const double b = (startB[index] + (endB[index] - startB[index]) * t) / 255.0;
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
}

@interface VoiceMeterView : NSView {
    ClassicMeterState _level;
    u32 _muteMask;
}
- (void)resetLevels;
- (void)updateWithSnapshot:(const LiveMeterSnapshot &)snapshot muteMask:(u32)muteMask active:(BOOL)active;
@end

@implementation VoiceMeterView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = ClassicMeterBackgroundColor().CGColor;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)resetLevels {
    _level = ClassicMeterState();
    _muteMask = 0;
    self.needsDisplay = YES;
}

- (void)updateWithSnapshot:(const LiveMeterSnapshot &)snapshot muteMask:(u32)muteMask active:(BOOL)active {
    _muteMask = muteMask;
    if (active) {
        _level.master_level_left = ClassicDecayLevel(_level.master_level_left, ClassicVolumeLevel(snapshot.master_peak_left));
        _level.master_level_right = ClassicDecayLevel(_level.master_level_right, ClassicVolumeLevel(snapshot.master_peak_right));
        _level.master_volume_left = ClassicLevelAbs(snapshot.master_volume_left);
        _level.master_volume_right = ClassicLevelAbs(snapshot.master_volume_right);
        _level.master_echo_left = ClassicLevelAbs(snapshot.echo_volume_left);
        _level.master_echo_right = ClassicLevelAbs(snapshot.echo_volume_right);
        _level.master_delay = ClassicLevelDelay(snapshot.echo_delay);
        _level.master_feedback = ClassicLevelAbs(snapshot.echo_feedback);

        for (int i = 0; i < 8; ++i) {
            ClassicChannelMeterState &channel = _level.channel[i];
            channel.channel_level_left = ClassicDecayLevel(channel.channel_level_left,
                                                          ClassicVolumeLevel(snapshot.voice_peak_left[i]));
            channel.channel_level_right = ClassicDecayLevel(channel.channel_level_right,
                                                           ClassicVolumeLevel(snapshot.voice_peak_right[i]));
            channel.channel_volume_left = ClassicLevelAbs(snapshot.voice_volume_left[i]);
            channel.channel_volume_right = ClassicLevelAbs(snapshot.voice_volume_right[i]);
            channel.channel_pitch = ClassicPitchLevel(snapshot.voice_pitch[i]);
            channel.channel_envelope = ClassicLevelAbs(snapshot.voice_env[i]);

            if (snapshot.voice_peak_left[i] <= 0.0 && snapshot.voice_peak_right[i] <= 0.0) {
                channel.silent_milliseconds = std::min(kClassicChannelHideMilliseconds,
                                                       channel.silent_milliseconds + kClassicMeterTickMilliseconds);
            } else {
                channel.silent_milliseconds = 0.0;
            }

            const u8 bit = static_cast<u8>(1u << i);
            const bool muted = ((snapshot.voice_mix_flags[i] & MFLG_MUTE) != 0) || ((_muteMask & bit) != 0);
            channel.channel_show = !muted && channel.silent_milliseconds < kClassicChannelHideMilliseconds;
            channel.echo_on = (snapshot.echo_on & bit) != 0;
            channel.pitch_mod_on = (snapshot.pitch_mod_on & bit) != 0;
            channel.noise_on = (snapshot.noise_on & bit) != 0;
        }
    }
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [ClassicMeterBackgroundColor() setFill];
    NSRectFill(self.bounds);

    NSDictionary *blueAttrs =
        ClassicBoldTextAttributes(10.0, [NSColor colorWithCalibratedRed:0.12 green:0.17 blue:0.95 alpha:1.0]);
    NSDictionary *blackAttrs = ClassicBoldTextAttributes(9.0, ClassicTextColor());
    NSDictionary *greenAttrs = ClassicBoldTextAttributes(9.0, ClassicChannelEnableTextColor());

    auto drawVerticalLine = ^(CGFloat x) {
        [ClassicMeterFrameColor() setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        line.lineWidth = 1.0;
        [line moveToPoint:NSMakePoint(x + 0.5, 17.0)];
        [line lineToPoint:NSMakePoint(x + 0.5, self.bounds.size.height - 2.0)];
        [line stroke];
    };

    drawVerticalLine(0);
    drawVerticalLine(2);
    drawVerticalLine(44);
    drawVerticalLine(46);
    for (int i = 0; i < 8; ++i) {
        drawVerticalLine(76 + i * 30);
    }

    [@"MIXER" drawAtPoint:NSMakePoint(7, 0) withAttributes:blueAttrs];
    for (int i = 0; i < 8; ++i) {
        const CGFloat groupX = 48 + i * 30;
        NSString *label = [NSString stringWithFormat:@"%d", i + 1];
        [label drawAtPoint:NSMakePoint(groupX, 1) withAttributes:blackAttrs];
        const ClassicChannelMeterState &channel = _level.channel[i];
        if (channel.channel_show) {
            unichar effectChars[3] = {
                static_cast<unichar>(channel.echo_on ? 'E' : '-'),
                static_cast<unichar>(channel.pitch_mod_on ? 'P' : '-'),
                static_cast<unichar>(channel.noise_on ? 'N' : '-'),
            };
            NSString *effectText = [NSString stringWithCharacters:effectChars length:3];
            [effectText drawAtPoint:NSMakePoint(groupX + 10, 1) withAttributes:greenAttrs];
        }
    }

    const CGFloat barTop = 20.0;
    const CGFloat barBottom = self.bounds.size.height - 2.0;
    const CGFloat barHeight = MAX(1.0, barBottom - barTop);
    const CGFloat rowHeight = barHeight / kClassicMeterHeight;
    auto drawBar = ^(CGFloat x, CGFloat width, u8 level, ClassicMeterColorIndex colorIndex) {
        level = std::min<u8>(level, kClassicMeterHeight);
        if (level == 0) {
            return;
        }
        const u8 startRow = kClassicMeterHeight - level;
        for (u8 row = startRow; row < kClassicMeterHeight; ++row) {
            [ClassicMeterColor(colorIndex, row) setFill];
            const CGFloat y = barTop + rowHeight * row;
            NSRectFill(NSMakeRect(x, y, width, ceil(rowHeight)));
        }
    };

    drawBar(4, 3, _level.master_volume_left, ClassicMeterGreen);
    drawBar(8, 3, _level.master_volume_right, ClassicMeterGreen);
    drawBar(12, 3, _level.master_echo_left, ClassicMeterOrange);
    drawBar(16, 3, _level.master_echo_right, ClassicMeterOrange);
    drawBar(20, 3, _level.master_delay, ClassicMeterWater);
    drawBar(24, 3, _level.master_feedback, ClassicMeterRed);
    drawBar(28, 7, _level.master_level_left, ClassicMeterBlue);
    drawBar(36, 7, _level.master_level_right, ClassicMeterBlue);

    for (int i = 0; i < 8; ++i) {
        const ClassicChannelMeterState &channel = _level.channel[i];
        if (!channel.channel_show) {
            continue;
        }
        const CGFloat groupX = 48 + i * 30;
        drawBar(groupX, 3, channel.channel_volume_left, ClassicMeterGreen);
        drawBar(groupX + 4, 3, channel.channel_volume_right, ClassicMeterGreen);
        drawBar(groupX + 8, 3, channel.channel_pitch, ClassicMeterOrange);
        drawBar(groupX + 12, 3, channel.channel_envelope, ClassicMeterRed);
        drawBar(groupX + 16, 5, channel.channel_level_left, ClassicMeterBlue);
        drawBar(groupX + 22, 5, channel.channel_level_right, ClassicMeterBlue);
    }
}

@end

@interface ClassicSeekSliderCell : NSSliderCell
@end

@implementation ClassicSeekSliderCell

- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    [super drawBarInside:rect flipped:flipped];

    const double range = self.maxValue - self.minValue;
    if (range <= 0.0) {
        return;
    }

    const double ratio = std::clamp((self.doubleValue - self.minValue) / range, 0.0, 1.0);
    NSRect fillRect = rect;
    fillRect.size.width = std::floor(NSWidth(rect) * static_cast<CGFloat>(ratio));
    if (NSWidth(fillRect) <= 0.5) {
        return;
    }

    const CGFloat trackHeight = std::min<CGFloat>(4.0, NSHeight(rect));
    fillRect.origin.y += (NSHeight(rect) - trackHeight) / 2.0;
    fillRect.size.height = trackHeight;
    [ClassicTextColor() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fillRect
                                     xRadius:trackHeight / 2.0
                                     yRadius:trackHeight / 2.0] fill];
}

@end

@interface ClassicSeekSlider : NSSlider
@end

@implementation ClassicSeekSlider

+ (Class)cellClass {
    return ClassicSeekSliderCell.class;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) {
        [super mouseDown:event];
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self.cell isKindOfClass:NSSliderCell.class]) {
        NSSliderCell *sliderCell = (NSSliderCell *)self.cell;
        if (NSPointInRect(point, [sliderCell knobRectFlipped:self.isFlipped])) {
            [super mouseDown:event];
            return;
        }
    }

    const CGFloat width = NSWidth(self.bounds);
    if (width > 0.0) {
        const CGFloat ratio = std::clamp(point.x / width, static_cast<CGFloat>(0.0), static_cast<CGFloat>(1.0));
        self.doubleValue = self.minValue + (self.maxValue - self.minValue) * ratio;
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

@end

@interface SPCFileDropView : NSView
#if __has_feature(objc_arc)
@property(nonatomic, weak) id<NSDraggingDestination> dragDestination;
#else
@property(nonatomic, assign) id<NSDraggingDestination> dragDestination;
#endif
@end

@implementation SPCFileDropView

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if ([self.dragDestination respondsToSelector:@selector(draggingEntered:)]) {
        return [self.dragDestination draggingEntered:sender];
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if ([self.dragDestination respondsToSelector:@selector(draggingUpdated:)]) {
        return [self.dragDestination draggingUpdated:sender];
    }
    return [self draggingEntered:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if ([self.dragDestination respondsToSelector:@selector(performDragOperation:)]) {
        return [self.dragDestination performDragOperation:sender];
    }
    return NO;
}

@end

enum class CommandLineControlAction {
    None,
    PlayPause,
    Restart,
    Stop,
    Quit,
    VolumeLow,
    Next,
    Previous,
    Random,
};

static NSArray<NSURL *> *gCommandLineOpenURLs = nil;
static CommandLineControlAction gCommandLineControlAction = CommandLineControlAction::None;
static constexpr NSTimeInterval kCommandLineOpenDelaySeconds = 0.15;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, AVAudioPlayerDelegate, NSDraggingDestination> {
    LiveSNESAPUCore *_liveCore;
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioQueueBuffers[kLiveAudioQueueBufferCount];
    BOOL _audioQueueRunning;
    BOOL _audioQueuePriming;
    u32 _audioQueueOutputChannels;
    u32 _audioQueueOutputRate;
    AudioDeviceID _audioQueueDeviceID;
}
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *gameLabel;
@property(nonatomic, strong) NSTextField *artistLabel;
@property(nonatomic, strong) NSTextField *pathLabel;
@property(nonatomic, strong) NSButton *playButton;
@property(nonatomic, strong) NSButton *restartButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic, strong) NSButton *rewButton;
@property(nonatomic, strong) NSButton *ffButton;
@property(nonatomic, strong) NSButton *listAddButton;
@property(nonatomic, strong) NSButton *listRemoveButton;
@property(nonatomic, strong) NSButton *listClearButton;
@property(nonatomic, strong) NSButton *listUpButton;
@property(nonatomic, strong) NSButton *listDownButton;
@property(nonatomic, strong) NSSlider *positionSlider;
@property(nonatomic, strong) NSTextField *timeLabel;
@property(nonatomic, strong) NSTextField *optionLabel;
@property(nonatomic, strong) VoiceMeterView *meterView;
@property(nonatomic, strong) ClassicInfoTextView *infoTextView;
@property(nonatomic, strong) NSProgressIndicator *renderSpinner;
@property(nonatomic, strong) NSMenu *filePopupMenu;
@property(nonatomic, strong) NSMenu *settingsPopupMenu;
@property(nonatomic, strong) NSMenu *soundDeviceMenu;
@property(nonatomic, strong) NSMenu *playlistPopupMenu;
@property(nonatomic, strong) NSMutableArray<NSButton *> *voiceButtons;
@property(nonatomic, strong) NSMutableArray<SPCPlaylistItem *> *playlist;
@property(nonatomic, strong) SPCPlaylistItem *currentItem;
@property(nonatomic, strong) SPCPlaylistItem *displayedItem;
@property(nonatomic, strong) AVAudioPlayer *player;
@property(nonatomic, strong) NSTask *activeRenderTask;
@property(nonatomic, strong) NSTimer *playbackTimer;
@property(nonatomic, strong) NSTimer *meterTimer;
@property(nonatomic) NSInteger currentIndex;
@property(nonatomic) NSUInteger renderGeneration;
@property(nonatomic) u32 muteMask;
@property(nonatomic) u32 noiseMask;
@property(nonatomic) u32 ampValue;
@property(nonatomic) u32 speedValue;
@property(nonatomic) u32 interpolationMode;
@property(nonatomic) u32 pitchValue;
@property(nonatomic) BOOL pitchAsync;
@property(nonatomic) u32 stereoSeparation;
@property(nonatomic) u32 feedbackValue;
@property(nonatomic) u32 dspOptions;
@property(nonatomic) u32 outputChannels;
@property(nonatomic) u32 outputBits;
@property(nonatomic) u32 outputRate;
@property(nonatomic) AudioDeviceID selectedOutputDeviceID;
@property(nonatomic) NSInteger playTimeMode;
@property(nonatomic) NSInteger playOrder;
@property(nonatomic) u32 seekTimeMilliseconds;
@property(nonatomic) BOOL seekFast;
@property(nonatomic) BOOL seekAsync;
@property(nonatomic) NSInteger infoMode;
@property(nonatomic) NSInteger numericFontMode;
@property(nonatomic) BOOL hideMutedChannels;
@property(nonatomic) NSInteger priorityMode;
@property(nonatomic) BOOL alwaysOnTop;
@property(nonatomic) BOOL noSleepDuringPlayback;
@property(nonatomic) BOOL livePaused;
@property(nonatomic) NSUInteger nextPlaybackPrefillChunks;
@property(nonatomic, strong) NSSet<NSString *> *commandLineLaunchOpenPathSet;
- (BOOL)openExternalFileURLs:(NSArray<NSURL *> *)urls activate:(BOOL)activate;
- (NSArray<NSURL *> *)fileURLsFromDraggingInfo:(id<NSDraggingInfo>)sender;
- (NSDragOperation)dragOperationForDraggingInfo:(id<NSDraggingInfo>)sender;
- (BOOL)draggingLocationIsInPlaylist:(id<NSDraggingInfo>)sender;
- (BOOL)addURLsToPlaylist:(NSArray<NSURL *> *)urls skipExisting:(BOOL)skipExisting;
- (void)applyCommandLineLaunchRequests;
- (void)disposeLiveAudioQueue;
- (void)stopLiveAudioOutput;
- (BOOL)fillLiveAudioQueueBuffer:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue;
@end

static void LiveAudioQueueOutputCallback(void *userData,
                                         AudioQueueRef queue,
                                         AudioQueueBufferRef buffer) {
    AppDelegate *delegate = (__bridge AppDelegate *)userData;
    [delegate fillLiveAudioQueueBuffer:buffer queue:queue];
}

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _liveCore = new LiveSNESAPUCore();
        _playlist = [NSMutableArray array];
        _voiceButtons = [NSMutableArray array];
        _currentIndex = -1;
        _ampValue = kAmp100;
        _speedValue = kDefaultSpeed;
        id savedInterpolation = [[NSUserDefaults standardUserDefaults] objectForKey:@"InterpolationMode"];
        _interpolationMode = [savedInterpolation respondsToSelector:@selector(unsignedIntValue)] ?
            SanitizedInterpolation((u32)[savedInterpolation unsignedIntValue]) :
            kDefaultInterpolation;
        _pitchValue = kDefaultPitch;
        _pitchAsync = NO;
        _stereoSeparation = kDefaultStereo;
        _feedbackValue = kDefaultFeedback;
        _dspOptions = kDefaultUserDSPOpts;
        _outputChannels = kDefaultOutputChannels;
        _outputBits = kDefaultOutputBits;
        _outputRate = kDefaultRate;
        _selectedOutputDeviceID = kAudioObjectUnknown;
        _playTimeMode = kPlayTimeID666;
        _playOrder = 1;
        _seekTimeMilliseconds = 5000;
        _seekFast = YES;
        _seekAsync = YES;
        _infoMode = 0;
        _numericFontMode = 0;
        _hideMutedChannels = YES;
        _priorityMode = 3;
        _alwaysOnTop = NO;
        _noSleepDuringPlayback = NO;
        _liveCore->set_interpolation(_interpolationMode);
    }
    return self;
}

- (void)dealloc {
    [self disposeLiveAudioQueue];
    delete _liveCore;
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    ++self.renderGeneration;
    [self cancelActiveRender];
    [self stopPlaybackTimer];
    [self stopMeterTimer];
    [self.player stop];
    [self disposeLiveAudioQueue];
    _liveCore->pause_streaming();
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    BOOL alreadyRegistered = NO;
    EnsureLaunchServicesRegistration(&alreadyRegistered);
    [self buildMenu];
    [self buildWindow];
    [NSApp activateIgnoringOtherApps:YES];
    [self applyCommandLineLaunchRequests];
}

- (void)applyCommandLineLaunchRequests {
    if (gCommandLineOpenURLs.count == 0) {
        return;
    }
    NSArray<NSURL *> *launchURLs = gCommandLineOpenURLs;
    gCommandLineOpenURLs = nil;
    self.commandLineLaunchOpenPathSet = [self canonicalPathSetForURLs:launchURLs];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kCommandLineOpenDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSSet<NSString *> *launchPathSet = self.commandLineLaunchOpenPathSet;
        self.nextPlaybackPrefillChunks = kCommandLineStartupPrefillCount;
        [self openExternalFileURLs:launchURLs activate:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if ([self.commandLineLaunchOpenPathSet isEqualToSet:launchPathSet]) {
                self.commandLineLaunchOpenPathSet = nil;
            }
        });
    });
}

- (NSSet<NSString *> *)canonicalPathSetForURLs:(NSArray<NSURL *> *)urls {
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (NSURL *url in urls) {
        if (url.isFileURL) {
            [paths addObject:CanonicalFileURLPath(url)];
        }
    }
    return [paths copy];
}

- (BOOL)shouldSuppressDuplicateCommandLineOpenURLs:(NSArray<NSURL *> *)urls {
    NSSet<NSString *> *launchPathSet = self.commandLineLaunchOpenPathSet;
    if (launchPathSet.count == 0 && gCommandLineOpenURLs.count > 0) {
        launchPathSet = [self canonicalPathSetForURLs:gCommandLineOpenURLs];
    }
    if (launchPathSet.count == 0) {
        return NO;
    }

    NSSet<NSString *> *candidatePathSet = [self canonicalPathSetForURLs:urls];
    if (candidatePathSet.count == 0) {
        return NO;
    }
    for (NSString *path in candidatePathSet) {
        if (![launchPathSet containsObject:path]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    (void)sender;
    if (filename.length == 0) {
        return NO;
    }
    NSArray<NSURL *> *urls = @[[NSURL fileURLWithPath:filename]];
    if ([self shouldSuppressDuplicateCommandLineOpenURLs:urls]) {
        return YES;
    }
    return [self openExternalFileURLs:urls activate:YES];
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:filenames.count];
    for (NSString *filename in filenames) {
        if (filename.length > 0) {
            [urls addObject:[NSURL fileURLWithPath:filename]];
        }
    }
    if ([self shouldSuppressDuplicateCommandLineOpenURLs:urls]) {
        [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
        return;
    }
    const BOOL didOpen = [self openExternalFileURLs:urls activate:YES];
    [sender replyToOpenOrPrint:didOpen ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    if ([self shouldSuppressDuplicateCommandLineOpenURLs:urls]) {
        return;
    }
    [self openExternalFileURLs:urls activate:YES];
}

- (void)buildMenu {
    NSMenu *menuBar = [NSMenu new];
    NSMenuItem *appMenuItem = [NSMenuItem new];
    [menuBar addItem:appMenuItem];

    NSMenu *appMenu = [NSMenu new];
    NSString *appName = @"spcplay-macos";
    NSMenuItem *quitItem =
        [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                   action:@selector(terminate:)
                            keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [appMenuItem setSubmenu:appMenu];

    NSMenuItem *fileMenuItem = [NSMenuItem new];
    fileMenuItem.title = @"File";
    [menuBar addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open..."
                                                      action:@selector(openFiles:)
                                               keyEquivalent:@""];
    openItem.target = self;
    [fileMenu addItem:openItem];
    NSMenuItem *saveItem = [[NSMenuItem alloc] initWithTitle:@"Save..."
                                                      action:@selector(saveCurrentAsWav:)
                                               keyEquivalent:@""];
    saveItem.target = self;
    [fileMenu addItem:saveItem];
    NSMenuItem *saveWavItem = [[NSMenuItem alloc] initWithTitle:@"Save to WAV..."
                                                         action:@selector(saveCurrentAsWav:)
                                                  keyEquivalent:@""];
    saveWavItem.target = self;
    [fileMenu addItem:saveWavItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *playItem = [[NSMenuItem alloc] initWithTitle:@"Play"
                                                      action:@selector(playFromFileMenu:)
                                               keyEquivalent:@""];
    playItem.target = self;
    [fileMenu addItem:playItem];
    NSMenuItem *pauseItem = [[NSMenuItem alloc] initWithTitle:@"Pause"
                                                       action:@selector(pauseFromFileMenu:)
                                                keyEquivalent:@""];
    pauseItem.target = self;
    [fileMenu addItem:pauseItem];
    NSMenuItem *restartItem = [[NSMenuItem alloc] initWithTitle:@"Restart"
                                                         action:@selector(restartTrack:)
                                                  keyEquivalent:@""];
    restartItem.target = self;
    [fileMenu addItem:restartItem];
    NSMenuItem *stopItem = [[NSMenuItem alloc] initWithTitle:@"Stop"
                                                      action:@selector(stopPlayback:)
                                               keyEquivalent:@""];
    stopItem.target = self;
    [fileMenu addItem:stopItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *exitItem = [[NSMenuItem alloc] initWithTitle:@"Exit"
                                                      action:@selector(exitApplication:)
                                               keyEquivalent:@""];
    exitItem.target = self;
    [fileMenu addItem:exitItem];
    self.filePopupMenu = fileMenu;
    [fileMenuItem setSubmenu:fileMenu];

    NSMenuItem *settingsMenuItem = [NSMenuItem new];
    settingsMenuItem.title = @"Settings";
    [menuBar addItem:settingsMenuItem];
    NSMenu *settingsMenu = [[NSMenu alloc] initWithTitle:@"Settings"];

    NSMenu *deviceMenu = AddSubmenu(settingsMenu, @"Sound Devices");
    self.soundDeviceMenu = deviceMenu;
    [self rebuildSoundDeviceMenu];

    NSMenu *outputChannelMenu = AddSubmenu(settingsMenu, @"Channels");
    AddMenuChoices(outputChannelMenu,
                   kOutputChannelChoices,
                   sizeof(kOutputChannelChoices) / sizeof(kOutputChannelChoices[0]),
                   @selector(chooseOutputChannels:),
                   self);

    NSMenu *bitMenu = AddSubmenu(settingsMenu, @"Bit");
    AddMenuChoices(bitMenu,
                   kOutputBitChoices,
                   sizeof(kOutputBitChoices) / sizeof(kOutputBitChoices[0]),
                   @selector(chooseOutputBits:),
                   self);

    NSMenu *rateMenu = AddSubmenu(settingsMenu, @"Sampling Rate");
    AddMenuChoices(rateMenu,
                   kOutputRateChoices,
                   sizeof(kOutputRateChoices) / sizeof(kOutputRateChoices[0]),
                   @selector(chooseOutputRate:),
                   self);

    [settingsMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *interpolationMenu = AddSubmenu(settingsMenu, @"Interpolation");
    AddMenuChoices(interpolationMenu,
                   kInterpolationChoices,
                   sizeof(kInterpolationChoices) / sizeof(kInterpolationChoices[0]),
                   @selector(chooseInterpolationMode:),
                   self);

    NSMenu *pitchMenu = AddSubmenu(settingsMenu, @"Pitch");
    AddMenuChoices(pitchMenu,
                   kPitchChoices,
                   sizeof(kPitchChoices) / sizeof(kPitchChoices[0]),
                   @selector(choosePitchValue:),
                   self);
    [pitchMenu addItem:[NSMenuItem separatorItem]];
    NSMenu *pitchKeyMenu = AddSubmenu(pitchMenu, @"Key Shift");
    AddMenuChoices(pitchKeyMenu,
                   kPitchKeyChoices,
                   sizeof(kPitchKeyChoices) / sizeof(kPitchKeyChoices[0]),
                   @selector(choosePitchValue:),
                   self);
    AddMenuItem(pitchMenu, @"Multiply by Speed", @selector(togglePitchAsync:), 0, self);

    NSMenu *stereoMenu = AddSubmenu(settingsMenu, @"Stereo Separator");
    AddMenuChoices(stereoMenu,
                   kStereoSeparationChoices,
                   sizeof(kStereoSeparationChoices) / sizeof(kStereoSeparationChoices[0]),
                   @selector(chooseStereoSeparation:),
                   self);

    NSMenu *feedbackMenu = AddSubmenu(settingsMenu, @"Feedback Mixer");
    AddMenuChoices(feedbackMenu,
                   kFeedbackChoices,
                   sizeof(kFeedbackChoices) / sizeof(kFeedbackChoices[0]),
                   @selector(chooseFeedbackMixer:),
                   self);

    NSMenu *speedMenu = AddSubmenu(settingsMenu, @"Speed");
    AddMenuChoices(speedMenu,
                   kSpeedChoices,
                   sizeof(kSpeedChoices) / sizeof(kSpeedChoices[0]),
                   @selector(chooseSpeedValue:),
                   self);

    NSMenu *ampMenu = AddSubmenu(settingsMenu, @"Volume");
    AddMenuChoices(ampMenu,
                   kAmpChoices,
                   sizeof(kAmpChoices) / sizeof(kAmpChoices[0]),
                   @selector(chooseAmpValue:),
                   self);

    NSMenu *muteMenu = AddSubmenu(settingsMenu, @"Channel Mute");
    AddMenuItem(muteMenu, @"Enable All", @selector(setAllMute:), kMenuToggleAllEnable, self);
    AddMenuItem(muteMenu, @"Disable All", @selector(setAllMute:), kMenuToggleAllDisable, self);
    AddMenuItem(muteMenu, @"Reverse All", @selector(setAllMute:), kMenuToggleAllReverse, self);
    [muteMenu addItem:[NSMenuItem separatorItem]];
    for (NSInteger i = 0; i < 8; ++i) {
        AddMenuItem(muteMenu,
                    [NSString stringWithFormat:@"Channel %ld", (long)i + 1],
                    @selector(toggleVoiceMute:),
                    i,
                    self);
    }

    NSMenu *noiseMenu = AddSubmenu(settingsMenu, @"Channel Noise");
    AddMenuItem(noiseMenu, @"Enable All", @selector(setAllNoise:), kMenuToggleAllEnable, self);
    AddMenuItem(noiseMenu, @"Disable All", @selector(setAllNoise:), kMenuToggleAllDisable, self);
    AddMenuItem(noiseMenu, @"Reverse All", @selector(setAllNoise:), kMenuToggleAllReverse, self);
    [noiseMenu addItem:[NSMenuItem separatorItem]];
    for (NSInteger i = 0; i < 8; ++i) {
        AddMenuItem(noiseMenu,
                    [NSString stringWithFormat:@"Channel %ld", (long)i + 1],
                    @selector(toggleVoiceNoise:),
                    i,
                    self);
    }

    NSMenu *expansionMenu = AddSubmenu(settingsMenu, @"Expansion Flags");
    AddMenuChoices(expansionMenu,
                   kExpansionFlagChoices,
                   sizeof(kExpansionFlagChoices) / sizeof(kExpansionFlagChoices[0]),
                   @selector(toggleExpansionFlag:),
                   self);

    [settingsMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *playTimeMenu = AddSubmenu(settingsMenu, @"Play Time");
    AddMenuItem(playTimeMenu, @"Disable/Endless", @selector(choosePlayTimeMode:), kPlayTimeEndless, self);
    AddMenuItem(playTimeMenu, @"Enable ID666 Time", @selector(choosePlayTimeMode:), kPlayTimeID666, self);
    AddMenuItem(playTimeMenu, @"Always Default Time", @selector(choosePlayTimeMode:), kPlayTimeDefault, self);
    [playTimeMenu addItem:[NSMenuItem separatorItem]];
    AddMenuItem(playTimeMenu, @"Set Start Position Mark", @selector(setStartTimeMark:), 0, self);
    AddMenuItem(playTimeMenu, @"Set Limit Position Mark", @selector(setLimitTimeMark:), 0, self);
    [playTimeMenu addItem:[NSMenuItem separatorItem]];
    AddMenuItem(playTimeMenu, @"Reset Position Marks", @selector(resetTimeMarks:), 0, self);

    NSMenu *playOrderMenu = AddSubmenu(settingsMenu, @"Play Order");
    AddMenuChoices(playOrderMenu,
                   kPlayOrderChoices,
                   sizeof(kPlayOrderChoices) / sizeof(kPlayOrderChoices[0]),
                   @selector(choosePlayOrder:),
                   self);

    NSMenu *seekMenu = AddSubmenu(settingsMenu, @"Seek Time");
    AddMenuChoices(seekMenu,
                   kSeekChoices,
                   sizeof(kSeekChoices) / sizeof(kSeekChoices[0]),
                   @selector(chooseSeekTime:),
                   self);
    [seekMenu addItem:[NSMenuItem separatorItem]];
    AddMenuItem(seekMenu, @"Fast Seek", @selector(toggleFastSeek:), 0, self);
    AddMenuItem(seekMenu, @"Multiply by Speed", @selector(toggleSeekAsync:), 0, self);

    NSMenu *infoMenu = AddSubmenu(settingsMenu, @"Information Viewer");
    AddMenuChoices(infoMenu,
                   kInfoChoices,
                   sizeof(kInfoChoices) / sizeof(kInfoChoices[0]),
                   @selector(chooseInfoMode:),
                   self);
    [infoMenu addItem:[NSMenuItem separatorItem]];
    NSMenu *fontMenu = AddSubmenu(infoMenu, @"Numeric Font");
    AddMenuChoices(fontMenu,
                   kNumericFontChoices,
                   sizeof(kNumericFontChoices) / sizeof(kNumericFontChoices[0]),
                   @selector(chooseNumericFont:),
                   self);
    AddMenuItem(infoMenu, @"Hide Muted Channels", @selector(toggleHideMutedChannels:), 0, self);

    NSMenu *priorityMenu = AddSubmenu(settingsMenu, @"CPU Priority");
    AddMenuChoices(priorityMenu,
                   kPriorityChoices,
                   sizeof(kPriorityChoices) / sizeof(kPriorityChoices[0]),
                   @selector(choosePriority:),
                   self);

    NSMenu *othersMenu = AddSubmenu(settingsMenu, @"Other Flags");
    AddMenuItem(othersMenu, @"Always on Top", @selector(toggleAlwaysOnTop:), 0, self);
    AddMenuItem(othersMenu, @"Not Turn Off Display", @selector(toggleNoSleepDuringPlayback:), 0, self);

    self.settingsPopupMenu = settingsMenu;
    [settingsMenuItem setSubmenu:settingsMenu];

    NSMenuItem *playlistMenuItem = [NSMenuItem new];
    playlistMenuItem.title = @"Playlist";
    [menuBar addItem:playlistMenuItem];
    NSMenu *playlistMenu = [[NSMenu alloc] initWithTitle:@"Playlist"];
    NSArray<NSMenuItem *> *playlistItems = @[
        [[NSMenuItem alloc] initWithTitle:@"Previous" action:@selector(previousTrack:) keyEquivalent:@"["],
        [[NSMenuItem alloc] initWithTitle:@"Next" action:@selector(nextTrack:) keyEquivalent:@"]"],
        [NSMenuItem separatorItem],
        [[NSMenuItem alloc] initWithTitle:@"Append" action:@selector(appendCurrentToPlaylist:) keyEquivalent:@"a"],
        [[NSMenuItem alloc] initWithTitle:@"Save Playlist..." action:@selector(savePlaylistAs:) keyEquivalent:@"l"],
        [[NSMenuItem alloc] initWithTitle:@"Remove Selected" action:@selector(removeSelectedTracks:) keyEquivalent:@"\b"],
        [[NSMenuItem alloc] initWithTitle:@"Clear" action:@selector(clearPlaylist:) keyEquivalent:@""],
        [[NSMenuItem alloc] initWithTitle:@"Move Up" action:@selector(moveSelectedTrackUp:) keyEquivalent:@"↑"],
        [[NSMenuItem alloc] initWithTitle:@"Move Down" action:@selector(moveSelectedTrackDown:) keyEquivalent:@"↓"],
    ];
    for (NSMenuItem *item in playlistItems) {
        item.target = self;
        [playlistMenu addItem:item];
    }
    self.playlistPopupMenu = playlistMenu;
    [playlistMenuItem setSubmenu:playlistMenu];

    [NSApp setMainMenu:menuBar];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 523, 190);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"SNES SPC700 Player";
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [self.window center];

    SPCFileDropView *content = [[SPCFileDropView alloc] initWithFrame:frame];
    content.dragDestination = self;
    self.window.contentView = content;
    content.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    content.wantsLayer = YES;
    content.layer.backgroundColor = ClassicWindowColor().CGColor;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [content registerForDraggedTypes:@[NSFilenamesPboardType, NSURLPboardType, @"public.file-url"]];
#pragma clang diagnostic pop

    NSView *menuStrip = [[NSView alloc] initWithFrame:NSMakeRect(0, 166, 523, 22)];
    menuStrip.wantsLayer = YES;
    menuStrip.layer.backgroundColor = ClassicMenuStripColor().CGColor;
    [content addSubview:menuStrip];

    NSButton *fileMenuButton = MakeMenuButton(NSMakeRect(7, 171, 28, 14), @"File", @selector(showFilePopupMenu:), self);
    NSButton *settingsMenuButton = MakeMenuButton(NSMakeRect(39, 171, 58, 14), @"Settings", @selector(showSettingsPopupMenu:), self);
    NSButton *playlistMenuButton = MakeMenuButton(NSMakeRect(94, 171, 58, 14), @"Playlist", @selector(showPlaylistPopupMenu:), self);
    [content addSubview:fileMenuButton];
    [content addSubview:settingsMenuButton];
    [content addSubview:playlistMenuButton];

    NSTextField *titleCaption = MakeLabel(NSMakeRect(7, 152, 80, 13), NO);
    titleCaption.font = ClassicMainFont(10.0);
    titleCaption.stringValue = @"Title    :";
    self.titleLabel = MakeLabel(NSMakeRect(72, 152, 219, 13), YES);
    self.titleLabel.font = ClassicMainFont(10.0);

    NSTextField *gameCaption = MakeLabel(NSMakeRect(7, 137, 80, 13), NO);
    gameCaption.font = ClassicMainFont(10.0);
    gameCaption.stringValue = @"Game     :";
    self.gameLabel = MakeLabel(NSMakeRect(72, 137, 219, 13), YES);
    self.gameLabel.font = ClassicMainFont(10.0);

    NSTextField *timeCaption = MakeLabel(NSMakeRect(7, 122, 80, 13), NO);
    timeCaption.font = ClassicMainFont(10.0);
    timeCaption.stringValue = @"Time     :";
    self.timeLabel = MakeLabel(NSMakeRect(72, 122, 110, 13), NO);
    self.timeLabel.font = ClassicMainBoldFont(10.0);
    self.timeLabel.attributedStringValue = ClassicBoldText(@"0:00:00.000", 10.0, ClassicTextColor());

    self.positionSlider = [[ClassicSeekSlider alloc] initWithFrame:NSMakeRect(145, 119, 147, 16)];
    self.positionSlider.minValue = 0.0;
    self.positionSlider.maxValue = 1.0;
    self.positionSlider.doubleValue = 0.0;
    self.positionSlider.enabled = NO;
    self.positionSlider.continuous = YES;
    self.positionSlider.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.positionSlider.target = self;
    self.positionSlider.action = @selector(seekSliderChanged:);
    self.meterView = [[VoiceMeterView alloc] initWithFrame:NSMakeRect(6, 47, 288, 70)];
    self.infoTextView = [[ClassicInfoTextView alloc] initWithFrame:NSMakeRect(6, 47, 288, 70)];
    self.infoTextView.hidden = YES;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(304, 29, 213, 136)];
    scrollView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = ClassicPlaylistBackgroundColor();
    scrollView.contentView.backgroundColor = ClassicPlaylistBackgroundColor();
    scrollView.autoresizingMask = NSViewNotSizable;

    self.tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    self.tableView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.tableView.backgroundColor = ClassicPlaylistBackgroundColor();
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.tableView.headerView = nil;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.doubleAction = @selector(playSelectedRow:);
    self.tableView.rowHeight = 16.0;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"track"];
    column.width = 195;
    [self.tableView addTableColumn:column];
    scrollView.documentView = self.tableView;

    NSButton *openButton = MakeButton(NSMakeRect(7, 26, 52, 20), @"OPEN", @selector(openFiles:), self);
    NSButton *saveButton = MakeButton(NSMakeRect(63, 26, 55, 20), @"SAVE", @selector(saveCurrentAsWav:), self);
    self.playButton = MakeButton(NSMakeRect(126, 26, 52, 20), @"PAUSE", @selector(togglePlayPause:), self);
    self.restartButton = MakeButton(NSMakeRect(181, 26, 58, 20), @"RESTART", @selector(restartTrack:), self);
    self.stopButton = MakeButton(NSMakeRect(242, 26, 51, 20), @"STOP", @selector(stopPlayback:), self);

    [content addSubview:openButton];
    [content addSubview:saveButton];
    [content addSubview:self.playButton];
    [content addSubview:self.restartButton];
    [content addSubview:self.stopButton];

    for (NSInteger i = 0; i < 8; ++i) {
        NSButton *voice = MakeButton(NSMakeRect(5 + i * 14, 3, 14, 20),
                                     [NSString stringWithFormat:@"%ld", (long)i + 1],
                                     @selector(toggleVoiceMute:),
                                     self);
        voice.buttonType = NSButtonTypePushOnPushOff;
        voice.tag = i;
        voice.state = NSControlStateValueOn;
        [self.voiceButtons addObject:voice];
        [content addSubview:voice];
    }

    NSButton *ampDown = MakeButton(NSMakeRect(126, 3, 26, 20), @"VL-", @selector(decreaseAmp:), self);
    NSButton *ampUp = MakeButton(NSMakeRect(154, 3, 26, 20), @"VL+", @selector(increaseAmp:), self);
    NSButton *speedDown = MakeButton(NSMakeRect(182, 3, 26, 20), @"SP-", @selector(decreaseSpeed:), self);
    NSButton *speedUp = MakeButton(NSMakeRect(210, 3, 26, 20), @"SP+", @selector(increaseSpeed:), self);
    self.rewButton = MakeButton(NSMakeRect(238, 3, 26, 20), @"REW", @selector(seekBackward:), self);
    self.ffButton = MakeButton(NSMakeRect(266, 3, 26, 20), @"FF", @selector(seekForward:), self);
    [content addSubview:ampDown];
    [content addSubview:ampUp];
    [content addSubview:speedDown];
    [content addSubview:speedUp];
    [content addSubview:self.rewButton];
    [content addSubview:self.ffButton];

    self.listAddButton = MakeButton(NSMakeRect(304, 3, 53, 20), @"APPEND", @selector(appendCurrentToPlaylist:), self);
    self.listRemoveButton = MakeButton(NSMakeRect(360, 3, 53, 20), @"REMOVE", @selector(removeSelectedTracks:), self);
    self.listClearButton = MakeButton(NSMakeRect(416, 3, 53, 20), @"CLEAR", @selector(clearPlaylist:), self);
    self.listUpButton = MakeButton(NSMakeRect(474, 3, 20, 20), @"UP", @selector(moveSelectedTrackUp:), self);
    self.listDownButton = MakeButton(NSMakeRect(497, 3, 20, 20), @"DN", @selector(moveSelectedTrackDown:), self);
    [content addSubview:self.listAddButton];
    [content addSubview:self.listRemoveButton];
    [content addSubview:self.listClearButton];
    [content addSubview:self.listUpButton];
    [content addSubview:self.listDownButton];

    self.statusLabel = MakeLabel(NSMakeRect(304, 168, 175, 14), NO);
    self.statusLabel.font = ClassicMainFont(10.0);
    self.statusLabel.stringValue = @"Ready";
    self.statusLabel.hidden = YES;

    self.renderSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(486, 166, 16, 16)];
    self.renderSpinner.style = NSProgressIndicatorStyleSpinning;
    self.renderSpinner.controlSize = NSControlSizeSmall;
    self.renderSpinner.displayedWhenStopped = NO;
    self.renderSpinner.hidden = YES;

    self.optionLabel = MakeLabel(NSMakeRect(171, 171, 118, 13), NO);
    self.optionLabel.font = ClassicMainFont(9.0);
    self.optionLabel.hidden = YES;

    self.artistLabel = MakeLabel(NSMakeRect(-2000, -2000, 1, 1), YES);
    self.pathLabel = MakeLabel(NSMakeRect(-2000, -2000, 1, 1), YES);

    [content addSubview:self.statusLabel];
    [content addSubview:self.renderSpinner];
    [content addSubview:titleCaption];
    [content addSubview:self.titleLabel];
    [content addSubview:gameCaption];
    [content addSubview:self.gameLabel];
    [content addSubview:timeCaption];
    [content addSubview:self.timeLabel];
    [content addSubview:self.positionSlider];
    [content addSubview:self.optionLabel];
    [content addSubview:self.meterView];
    [content addSubview:self.infoTextView];
    [content addSubview:scrollView];

    [self resetLabels];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showMenu:(NSMenu *)menu fromButton:(NSButton *)button {
    if (!menu || !button) {
        return;
    }
    [self updateControlState];
    [self updateMenuItemStates];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(button.bounds) + 2) inView:button];
}

- (void)showFilePopupMenu:(id)sender {
    [self showMenu:self.filePopupMenu fromButton:[sender isKindOfClass:NSButton.class] ? sender : nil];
}

- (void)showSettingsPopupMenu:(id)sender {
    [self rebuildSoundDeviceMenu];
    [self showMenu:self.settingsPopupMenu fromButton:[sender isKindOfClass:NSButton.class] ? sender : nil];
}

- (void)showPlaylistPopupMenu:(id)sender {
    [self showMenu:self.playlistPopupMenu fromButton:[sender isKindOfClass:NSButton.class] ? sender : nil];
}

- (BOOL)isTransportActive {
    return (_audioQueueRunning && !self.livePaused) || self.livePaused || self.player.playing;
}

- (BOOL)isTransportPlaying {
    return (_audioQueueRunning && !self.livePaused) || self.player.playing;
}

- (void)updateControlState {
    const BOOL hasOpenSPC = self.currentItem != nil || _liveCore->loaded() || self.player != nil;
    const BOOL transportActive = [self isTransportActive];
    const BOOL transportPlaying = [self isTransportPlaying];
    const NSInteger selectedRow = self.tableView.selectedRow;
    const NSInteger playlistCount = (NSInteger)self.playlist.count;
    const BOOL hasPlaylistSelection = selectedRow >= 0 && selectedRow < playlistCount;

    self.playButton.enabled = hasOpenSPC || playlistCount > 0;
    self.restartButton.enabled = transportActive;
    self.stopButton.enabled = transportActive;
    self.rewButton.enabled = transportPlaying;
    self.ffButton.enabled = transportPlaying;

    self.listAddButton.enabled = hasOpenSPC;
    self.listRemoveButton.enabled = hasPlaylistSelection;
    self.listClearButton.enabled = playlistCount > 0;
    self.listUpButton.enabled = hasPlaylistSelection && selectedRow > 0;
    self.listDownButton.enabled = hasPlaylistSelection && selectedRow + 1 < playlistCount;
}

- (void)rebuildSoundDeviceMenu {
    if (!self.soundDeviceMenu) {
        return;
    }
    [self.soundDeviceMenu removeAllItems];
    AddMenuItem(self.soundDeviceMenu, @"System Default", @selector(chooseSoundDevice:), kAudioObjectUnknown, self);
    NSArray<NSDictionary *> *devices = AvailableOutputDevices();
    if (devices.count > 0) {
        [self.soundDeviceMenu addItem:[NSMenuItem separatorItem]];
    }
    for (NSDictionary *device in devices) {
        AudioDeviceID deviceID = (AudioDeviceID)[device[@"id"] unsignedIntValue];
        NSString *name = device[@"name"] ?: [NSString stringWithFormat:@"Device %u", deviceID];
        AddMenuItem(self.soundDeviceMenu, name, @selector(chooseSoundDevice:), deviceID, self);
    }
}

- (BOOL)syncSettingMenuItemState:(NSMenuItem *)item {
    SEL action = item.action;
    item.state = NSControlStateValueOff;

    if (action == @selector(chooseSoundDevice:)) {
        item.state = self.selectedOutputDeviceID == (AudioDeviceID)item.tag ?
            NSControlStateValueOn :
            NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseOutputChannels:)) {
        item.state = (self.outputChannels == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return ![self isTransportActive];
    }
    if (action == @selector(chooseOutputBits:)) {
        item.state = (self.outputBits == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return ![self isTransportActive];
    }
    if (action == @selector(chooseOutputRate:)) {
        item.state = (self.outputRate == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return ![self isTransportActive];
    }
    if (action == @selector(chooseInterpolationMode:)) {
        item.state = SanitizedInterpolation((u32)item.tag) == self.interpolationMode ?
            NSControlStateValueOn :
            NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(choosePitchValue:)) {
        item.state = (self.pitchValue == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(togglePitchAsync:)) {
        item.state = self.pitchAsync ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseStereoSeparation:)) {
        item.state = (self.stereoSeparation == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseFeedbackMixer:)) {
        item.state = (self.feedbackValue == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseSpeedValue:)) {
        item.state = (self.speedValue == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseAmpValue:)) {
        item.state = (self.ampValue == (u32)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleVoiceMute:)) {
        const u32 bit = 1u << (u32)item.tag;
        item.state = (self.muteMask & bit) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleVoiceNoise:)) {
        const u32 bit = 1u << (u32)item.tag;
        item.state = (self.noiseMask & bit) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleExpansionFlag:)) {
        item.state = (self.dspOptions & (u32)item.tag) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(choosePlayTimeMode:)) {
        item.state = self.playTimeMode == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(setStartTimeMark:) || action == @selector(setLimitTimeMark:) || action == @selector(resetTimeMarks:)) {
        return NO;
    }
    if (action == @selector(choosePlayOrder:)) {
        item.state = self.playOrder == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseSeekTime:)) {
        item.state = self.seekTimeMilliseconds == (u32)item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleFastSeek:)) {
        item.state = self.seekFast ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleSeekAsync:)) {
        item.state = self.seekAsync ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseInfoMode:)) {
        item.state = self.infoMode == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(chooseNumericFont:)) {
        item.state = self.numericFontMode == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleHideMutedChannels:)) {
        item.state = self.hideMutedChannels ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(choosePriority:)) {
        item.state = self.priorityMode == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleAlwaysOnTop:)) {
        item.state = self.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleNoSleepDuringPlayback:)) {
        item.state = self.noSleepDuringPlayback ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    return YES;
}

- (void)updateMenuItemStatesInMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        [self syncSettingMenuItemState:item];
        if (item.submenu) {
            [self updateMenuItemStatesInMenu:item.submenu];
        }
    }
}

- (void)updateMenuItemStates {
    [self updateMenuItemStatesInMenu:self.filePopupMenu];
    [self updateMenuItemStatesInMenu:self.settingsPopupMenu];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = menuItem.action;
    const BOOL hasOpenSPC = self.currentItem != nil || _liveCore->loaded() || self.player != nil;
    const BOOL transportActive = [self isTransportActive];
    const BOOL transportPlaying = [self isTransportPlaying];
    const NSInteger selectedRow = self.tableView.selectedRow;
    const NSInteger playlistCount = (NSInteger)self.playlist.count;
    const BOOL hasPlaylistSelection = selectedRow >= 0 && selectedRow < playlistCount;

    if (action == @selector(saveCurrentAsWav:)) {
        return hasOpenSPC;
    }
    if (action == @selector(playFromFileMenu:)) {
        return (hasOpenSPC || playlistCount > 0) && !transportPlaying;
    }
    if (action == @selector(pauseFromFileMenu:)) {
        return transportPlaying;
    }
    if (action == @selector(togglePlayPause:)) {
        return hasOpenSPC || playlistCount > 0;
    }
    if (action == @selector(restartTrack:) || action == @selector(stopPlayback:)) {
        return transportActive;
    }
    if (action == @selector(seekBackward:) || action == @selector(seekForward:)) {
        return transportPlaying;
    }
    if (action == @selector(appendCurrentToPlaylist:)) {
        return hasOpenSPC;
    }
    if (action == @selector(removeSelectedTracks:)) {
        return hasPlaylistSelection;
    }
    if (action == @selector(clearPlaylist:) || action == @selector(savePlaylistAs:)) {
        return playlistCount > 0;
    }
    if (action == @selector(moveSelectedTrackUp:)) {
        return hasPlaylistSelection && selectedRow > 0;
    }
    if (action == @selector(moveSelectedTrackDown:)) {
        return hasPlaylistSelection && selectedRow + 1 < playlistCount;
    }
    if (action == @selector(previousTrack:) || action == @selector(nextTrack:)) {
        return playlistCount > 1;
    }
    return [self syncSettingMenuItemState:menuItem];
}

- (void)resetLabels {
    self.window.title = @"SNES SPC700 Player";
    self.statusLabel.stringValue = @"Ready";
    self.titleLabel.stringValue = @"";
    self.gameLabel.stringValue = @"";
    self.artistLabel.stringValue = @"";
    self.pathLabel.stringValue = @"";
    self.currentItem = nil;
    self.displayedItem = nil;
    SetClassicButtonTitle(self.playButton, @"PLAY");
    self.positionSlider.enabled = NO;
    self.positionSlider.doubleValue = 0.0;
    self.timeLabel.attributedStringValue = ClassicBoldText(@"0:00:00.000", 10.0, ClassicTextColor());
    [self updateOptionLabel];
    [self updateVoiceButtons];
    [self.meterView resetLevels];
    [self updateClassicInfoText];
    [self setRenderingActive:NO];
    [self updateControlState];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return self.playlist.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    (void)tableView;
    (void)tableColumn;
    NSTextField *cell = [self.tableView makeViewWithIdentifier:@"TrackCell" owner:self];
    if (!cell) {
        cell = MakeLabel(NSMakeRect(0, 0, 260, 22), NO);
        cell.identifier = @"TrackCell";
        cell.font = ClassicMainFont(10.0);
    }
    SPCPlaylistItem *item = self.playlist[(NSUInteger)row];
    cell.stringValue = item.titleText.length ? item.titleText : item.displayName;
    cell.textColor = (row == self.tableView.selectedRow) ? [NSColor whiteColor] : ClassicTextColor();
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self.tableView reloadData];
    NSInteger row = self.tableView.selectedRow;
    if (row >= 0 && row < (NSInteger)self.playlist.count) {
        [self updateMetadataForItem:self.playlist[(NSUInteger)row] status:self.statusLabel.stringValue];
    }
    [self updateControlState];
}

- (void)updateMetadataForItem:(SPCPlaylistItem *)item status:(NSString *)status {
    self.displayedItem = item;
    self.statusLabel.stringValue = status ?: @"";
    NSString *filename = item.sourcePath.lastPathComponent;
    self.window.title = filename.length ?
        [NSString stringWithFormat:@"%@ - SNES SPC700 Player", filename] :
        @"SNES SPC700 Player";
    self.titleLabel.stringValue = item.titleText ?: @"";
    self.gameLabel.stringValue = item.gameText ?: @"";
    self.artistLabel.stringValue = item.artistText ?: @"";
    self.pathLabel.stringValue = item.sourcePath ?: @"";
    [self updateClassicInfoText];
}

- (void)setRenderingActive:(BOOL)active {
    self.renderSpinner.hidden = !active;
    if (active) {
        [self.renderSpinner startAnimation:nil];
    } else {
        [self.renderSpinner stopAnimation:nil];
    }
}

- (void)cancelActiveRender {
    NSTask *task = self.activeRenderTask;
    self.activeRenderTask = nil;
    if (task.isRunning) {
        [task terminate];
    }
    [self setRenderingActive:NO];
}

- (void)updateOptionLabel {
    self.optionLabel.stringValue = [NSString stringWithFormat:@"A%03u S%03u M%02X",
                                                              PercentFromFixed(self.ampValue),
                                                              PercentFromFixed(self.speedValue),
                                                              self.muteMask & 0xffu];
}

- (void)applyCurrentAudioSettingsToCore {
    _liveCore->set_output_format(self.outputChannels, self.outputBits, self.outputRate);
    _liveCore->set_interpolation(self.interpolationMode);
    _liveCore->set_dsp_options(self.dspOptions);
    _liveCore->set_speed_value(self.speedValue);
    _liveCore->set_pitch(self.pitchValue);
    _liveCore->set_pitch_async(self.pitchAsync);
    _liveCore->set_stereo_separation(self.stereoSeparation);
    _liveCore->set_feedback(self.feedbackValue);
    _liveCore->set_amp_value(self.ampValue);
    _liveCore->set_voice_masks(self.muteMask, self.noiseMask);
}

- (u32)nextChoiceValue:(const ClassicMenuChoice *)choices
                 count:(size_t)count
               current:(u32)current
             direction:(NSInteger)direction
              fallback:(u32)fallback {
    NSInteger found = -1;
    for (size_t i = 0; i < count; ++i) {
        if (choices[i].title && (u32)choices[i].value == current) {
            found = (NSInteger)i;
            break;
        }
    }
    if (found < 0) {
        return fallback;
    }

    NSInteger next = found + direction;
    while (next >= 0 && next < (NSInteger)count) {
        if (choices[next].title) {
            return (u32)choices[next].value;
        }
        next += direction;
    }
    return current;
}

- (void)updateVoiceButtons {
    for (NSButton *button in self.voiceButtons) {
        const u32 bit = 1u << (u32)button.tag;
        const BOOL muted = (self.muteMask & bit) != 0;
        button.state = muted ? NSControlStateValueOff : NSControlStateValueOn;
        if (@available(macOS 10.14, *)) {
            button.contentTintColor = nil;
        }
        SetClassicButtonTitleColor(button,
                                   [NSString stringWithFormat:@"%ld", (long)button.tag + 1],
                                   muted ? [NSColor colorWithCalibratedWhite:0.35 alpha:1.0] : ClassicTextColor());
    }
}

- (BOOL)applySelectedOutputDeviceWithError:(NSError **)error {
    if (!_audioQueue || self.selectedOutputDeviceID == kAudioObjectUnknown) {
        return YES;
    }
    NSString *deviceUID = AudioObjectStringProperty(self.selectedOutputDeviceID, kAudioDevicePropertyDeviceUID);
    if (deviceUID.length == 0) {
        return YES;
    }
    CFStringRef deviceUIDRef = (__bridge CFStringRef)deviceUID;
    OSStatus status = AudioQueueSetProperty(_audioQueue,
                                            kAudioQueueProperty_CurrentDevice,
                                            &deviceUIDRef,
                                            sizeof(deviceUIDRef));
    if (status == noErr) {
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                     code:status
                                 userInfo:@{NSLocalizedDescriptionKey: @"Could not select that audio output device"}];
    }
    return NO;
}

- (void)disposeLiveAudioQueue {
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
    for (UInt32 i = 0; i < kLiveAudioQueueBufferCount; ++i) {
        _audioQueueBuffers[i] = NULL;
    }
    _audioQueueRunning = NO;
    _audioQueuePriming = NO;
    _audioQueueOutputChannels = 0;
    _audioQueueOutputRate = 0;
    _audioQueueDeviceID = kAudioObjectUnknown;
}

- (void)discardLiveAudioOutputForFormatChange {
    [self disposeLiveAudioQueue];
}

- (BOOL)createLiveAudioQueueWithError:(NSError **)error {
    const u32 channels = SanitizedOutputChannels(self.outputChannels);
    const u32 rate = SanitizedOutputRate(self.outputRate);
    if (_audioQueue &&
        _audioQueueOutputChannels == channels &&
        _audioQueueOutputRate == rate &&
        _audioQueueDeviceID == self.selectedOutputDeviceID) {
        return YES;
    }

    [self disposeLiveAudioQueue];

    AudioStreamBasicDescription description = {};
    description.mSampleRate = rate;
    description.mFormatID = kAudioFormatLinearPCM;
    description.mFormatFlags = kAudioFormatFlagIsFloat |
        kAudioFormatFlagIsPacked |
        kAudioFormatFlagsNativeEndian;
    description.mBytesPerPacket = channels * sizeof(float);
    description.mFramesPerPacket = 1;
    description.mBytesPerFrame = channels * sizeof(float);
    description.mChannelsPerFrame = channels;
    description.mBitsPerChannel = 8 * sizeof(float);

    OSStatus status = AudioQueueNewOutput(&description,
                                          LiveAudioQueueOutputCallback,
                                          (__bridge void *)self,
                                          NULL,
                                          NULL,
                                          0,
                                          &_audioQueue);
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create audio output"}];
        }
        return NO;
    }

    if (![self applySelectedOutputDeviceWithError:error]) {
        return NO;
    }

    const UInt32 bufferBytes = kLiveAudioQueueFramesPerBuffer * channels * sizeof(float);
    for (UInt32 i = 0; i < kLiveAudioQueueBufferCount; ++i) {
        status = AudioQueueAllocateBuffer(_audioQueue, bufferBytes, &_audioQueueBuffers[i]);
        if (status != noErr) {
            if (error) {
                *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                             code:status
                                         userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate audio output buffers"}];
            }
            [self disposeLiveAudioQueue];
            return NO;
        }
    }

    _audioQueueOutputChannels = channels;
    _audioQueueOutputRate = rate;
    _audioQueueDeviceID = self.selectedOutputDeviceID;
    return YES;
}

- (BOOL)fillLiveAudioQueueBuffer:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue {
    if (!buffer || queue != _audioQueue || (!_audioQueueRunning && !_audioQueuePriming)) {
        return NO;
    }

    const UInt32 channels = std::max<u32>(_audioQueueOutputChannels, 1);
    const UInt32 byteCount = kLiveAudioQueueFramesPerBuffer * channels * sizeof(float);
    buffer->mAudioDataByteSize = byteCount;

    AudioBufferList audioBufferList = {};
    audioBufferList.mNumberBuffers = 1;
    audioBufferList.mBuffers[0].mNumberChannels = channels;
    audioBufferList.mBuffers[0].mDataByteSize = byteCount;
    audioBufferList.mBuffers[0].mData = buffer->mAudioData;
    _liveCore->render(&audioBufferList, kLiveAudioQueueFramesPerBuffer);

    const OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    return status == noErr;
}

- (void)stopLiveAudioOutput {
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueReset(_audioQueue);
    }
    _audioQueueRunning = NO;
    _audioQueuePriming = NO;
}

- (BOOL)startLiveEngineWithPrefillChunks:(NSUInteger)prefillChunks error:(NSError **)error {
    [self stopLiveAudioOutput];
    _liveCore->pause_streaming();

    if (![self createLiveAudioQueueWithError:error]) {
        return NO;
    }

    const size_t requestedPrefill = prefillChunks > 0 ?
        static_cast<size_t>(prefillChunks) :
        kLiveWaveBufferPrefillCount;
    if (!_liveCore->start_streaming(requestedPrefill, kLiveWaveBufferPrefillCount)) {
        if (error) {
            *error = [NSError errorWithDomain:@"SPCPlayMac"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"SNESAPU failed to prebuffer audio"}];
        }
        return NO;
    }

    _audioQueuePriming = YES;
    for (UInt32 i = 0; i < kLiveAudioQueueBufferCount; ++i) {
        if (![self fillLiveAudioQueueBuffer:_audioQueueBuffers[i] queue:_audioQueue]) {
            _audioQueuePriming = NO;
            _liveCore->pause_streaming();
            if (error) {
                *error = [NSError errorWithDomain:@"SPCPlayMac"
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Could not prime audio output"}];
            }
            return NO;
        }
    }
    _audioQueuePriming = NO;

    _audioQueueRunning = YES;
    const OSStatus status = AudioQueueStart(_audioQueue, NULL);
    if (status != noErr) {
        _audioQueueRunning = NO;
        _liveCore->pause_streaming();
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not start audio output"}];
        }
        return NO;
    }
    self.livePaused = NO;
    [self startPlaybackTimer];
    [self startMeterTimer];
    return YES;
}

- (BOOL)startLiveEngineWithError:(NSError **)error {
    return [self startLiveEngineWithPrefillChunks:kLiveWaveBufferPrefillCount error:error];
}

- (void)stopLiveEngine {
    [self stopLiveAudioOutput];
    _liveCore->pause_streaming();
    [self stopPlaybackTimer];
    self.livePaused = NO;
}

- (void)updatePlaybackPosition {
    NSTimeInterval duration = _liveCore->loaded() ? _liveCore->song_seconds() : (self.player ? self.player.duration : 0.0);
    NSTimeInterval current = _liveCore->loaded() ? (_liveCore->snapshot().t64_count / 64000.0) : (self.player ? self.player.currentTime : 0.0);
    if (!isfinite(duration) || duration < 0.0) {
        duration = 0.0;
    }
    if (!isfinite(current) || current < 0.0) {
        current = 0.0;
    }
    if (duration > 0.0 && current > duration) {
        current = duration;
    }

    self.positionSlider.enabled = (_liveCore->loaded() || self.player != nil);
    self.positionSlider.maxValue = duration > 0.0 ? duration : 1.0;
    self.positionSlider.doubleValue = current;
    self.timeLabel.attributedStringValue =
        ClassicBoldText(FormatPlaybackTimePrecise(current), 10.0, ClassicTextColor());
    [self updateClassicInfoText];
}

- (void)startPlaybackTimer {
    if (self.playbackTimer) {
        return;
    }
    self.playbackTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0
                                                 target:self
                                               selector:@selector(playbackTimerFired:)
                                               userInfo:nil
                                                repeats:YES];
    self.playbackTimer.tolerance = 0.005;
    [[NSRunLoop mainRunLoop] addTimer:self.playbackTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPlaybackTimer {
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
}

- (void)playbackTimerFired:(NSTimer *)timer {
    (void)timer;
    [self updatePlaybackPosition];
}

- (void)seekSliderChanged:(id)sender {
    (void)sender;
    if (_liveCore->loaded()) {
        const BOOL wasRunning = _audioQueueRunning && !self.livePaused;
        const double target = std::clamp(self.positionSlider.doubleValue, 0.0, self.positionSlider.maxValue);
        if (!_liveCore->seek_seconds(target, true)) {
            self.statusLabel.stringValue = @"SNESAPU failed to seek";
            return;
        }
        if (wasRunning) {
            NSError *error = nil;
            if (![self startLiveEngineWithError:&error]) {
                self.statusLabel.stringValue = error.localizedDescription ?: @"SNESAPU failed to prebuffer audio";
            }
        }
        [self updatePlaybackPosition];
        [self updateLiveMeters];
        return;
    }
    if (!self.player) {
        return;
    }
    self.player.currentTime = std::clamp(self.positionSlider.doubleValue, 0.0, self.positionSlider.maxValue);
    [self updatePlaybackPosition];
}

- (void)startMeterTimer {
    if (self.meterTimer) {
        return;
    }
    self.meterTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                              target:self
                                            selector:@selector(meterTimerFired:)
                                            userInfo:nil
                                             repeats:YES];
    self.meterTimer.tolerance = 0.003;
    [[NSRunLoop mainRunLoop] addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
}

- (void)stopMeterTimer {
    [self.meterTimer invalidate];
    self.meterTimer = nil;
}

- (void)meterTimerFired:(NSTimer *)timer {
    (void)timer;
    [self updateLiveMeters];
    if (_liveCore->loaded() && _liveCore->song_seconds() > 0) {
        const double current = _liveCore->snapshot().t64_count / 64000.0;
        if (current >= _liveCore->song_seconds()) {
            [self finishCurrentTrackAndAdvance];
        }
    }
}

- (void)updateLiveMeters {
    [self updateInfoDisplayVisibility];
    if (self.infoMode != 0) {
        [self updateClassicInfoText];
        return;
    }
    if (!_liveCore->loaded()) {
        [self.meterView resetLevels];
        return;
    }
    if (![self isTransportActive]) {
        [self.meterView resetLevels];
        return;
    }
    LiveMeterSnapshot snapshot = _liveCore->snapshot();
    [self.meterView updateWithSnapshot:snapshot muteMask:self.muteMask active:[self isTransportPlaying]];
}

- (void)updateInfoDisplayVisibility {
    const BOOL textMode = self.infoMode != 0;
    self.infoTextView.hidden = !textMode;
    self.meterView.hidden = textMode;
}

- (void)updateClassicInfoText {
    [self updateInfoDisplayVisibility];
    if (self.infoMode == 0) {
        return;
    }
    LiveMeterSnapshot snapshot;
    const BOOL loaded = _liveCore->loaded();
    if (loaded) {
        snapshot = _liveCore->snapshot();
    }
    SPCPlaylistItem *displayItem = self.displayedItem ?: self.currentItem;
    self.infoTextView.infoMode = self.infoMode;
    self.infoTextView.text = ClassicInfoText(self.infoMode, displayItem, snapshot, loaded);
}

- (void)toggleVoiceMute:(id)sender {
    const NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    const u32 bit = 1u << (u32)tag;
    if ([sender isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)sender;
        if (button.state == NSControlStateValueOn) {
            self.muteMask &= ~bit;
        } else {
            self.muteMask |= bit;
        }
    } else {
        self.muteMask ^= bit;
    }
    _liveCore->set_voice_masks(self.muteMask, self.noiseMask);
    [self updateVoiceButtons];
    [self updateOptionLabel];
    [self updateMenuItemStates];
    [self updateLiveMeters];
}

- (void)decreaseAmp:(id)sender {
    (void)sender;
    self.ampValue = [self nextChoiceValue:kAmpChoices
                                    count:sizeof(kAmpChoices) / sizeof(kAmpChoices[0])
                                  current:self.ampValue
                                direction:-1
                                 fallback:kAmp100];
    _liveCore->set_amp_value(self.ampValue);
    [self updateOptionLabel];
    [self updateMenuItemStates];
}

- (void)increaseAmp:(id)sender {
    (void)sender;
    self.ampValue = [self nextChoiceValue:kAmpChoices
                                    count:sizeof(kAmpChoices) / sizeof(kAmpChoices[0])
                                  current:self.ampValue
                                direction:1
                                 fallback:kAmp100];
    _liveCore->set_amp_value(self.ampValue);
    [self updateOptionLabel];
    [self updateMenuItemStates];
}

- (void)decreaseSpeed:(id)sender {
    (void)sender;
    self.speedValue = [self nextChoiceValue:kSpeedChoices
                                      count:sizeof(kSpeedChoices) / sizeof(kSpeedChoices[0])
                                    current:self.speedValue
                                  direction:-1
                                   fallback:kDefaultSpeed];
    _liveCore->set_speed_value(self.speedValue);
    [self updateOptionLabel];
    [self updateMenuItemStates];
}

- (void)increaseSpeed:(id)sender {
    (void)sender;
    self.speedValue = [self nextChoiceValue:kSpeedChoices
                                      count:sizeof(kSpeedChoices) / sizeof(kSpeedChoices[0])
                                    current:self.speedValue
                                  direction:1
                                   fallback:kDefaultSpeed];
    _liveCore->set_speed_value(self.speedValue);
    [self updateOptionLabel];
    [self updateMenuItemStates];
}

- (void)chooseSoundDevice:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    const BOOL wasPlaying = [self isTransportPlaying];
    if (wasPlaying) {
        [self stopLiveAudioOutput];
        _liveCore->pause_streaming();
    }
    self.selectedOutputDeviceID = (AudioDeviceID)[sender tag];
    [self disposeLiveAudioQueue];
    NSError *error = nil;
    if (wasPlaying) {
        if (![self startLiveEngineWithError:&error]) {
            self.statusLabel.stringValue = error.localizedDescription ?: @"Could not restart audio output";
        }
    }
    [self updateMenuItemStates];
}

- (void)chooseOutputChannels:(id)sender {
    if (![sender respondsToSelector:@selector(tag)] || [self isTransportActive]) {
        return;
    }
    self.outputChannels = SanitizedOutputChannels((u32)[sender tag]);
    [self discardLiveAudioOutputForFormatChange];
    [self applyCurrentAudioSettingsToCore];
    [self updateMenuItemStates];
}

- (void)chooseOutputBits:(id)sender {
    if (![sender respondsToSelector:@selector(tag)] || [self isTransportActive]) {
        return;
    }
    self.outputBits = SanitizedOutputBits((u32)[sender tag]);
    [self applyCurrentAudioSettingsToCore];
    [self updateMenuItemStates];
}

- (void)chooseOutputRate:(id)sender {
    if (![sender respondsToSelector:@selector(tag)] || [self isTransportActive]) {
        return;
    }
    self.outputRate = SanitizedOutputRate((u32)[sender tag]);
    [self discardLiveAudioOutputForFormatChange];
    [self applyCurrentAudioSettingsToCore];
    [self updateMenuItemStates];
}

- (void)chooseInterpolationMode:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }

    self.interpolationMode = SanitizedInterpolation((u32)[sender tag]);
    [[NSUserDefaults standardUserDefaults] setInteger:self.interpolationMode forKey:@"InterpolationMode"];
    _liveCore->set_interpolation(self.interpolationMode);
    [self updateMenuItemStates];
}

- (void)choosePitchValue:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.pitchValue = (u32)[sender tag];
    _liveCore->set_pitch(self.pitchValue);
    [self updateMenuItemStates];
}

- (void)togglePitchAsync:(id)sender {
    (void)sender;
    self.pitchAsync = !self.pitchAsync;
    _liveCore->set_pitch_async(self.pitchAsync);
    [self updateMenuItemStates];
}

- (void)chooseStereoSeparation:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.stereoSeparation = (u32)[sender tag];
    _liveCore->set_stereo_separation(self.stereoSeparation);
    [self updateMenuItemStates];
}

- (void)chooseFeedbackMixer:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.feedbackValue = (u32)[sender tag];
    _liveCore->set_feedback(self.feedbackValue);
    [self updateMenuItemStates];
}

- (void)chooseSpeedValue:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.speedValue = (u32)[sender tag];
    _liveCore->set_speed_value(self.speedValue);
    [self updateOptionLabel];
    [self updateMenuItemStates];
}

- (void)chooseAmpValue:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.ampValue = (u32)[sender tag];
    _liveCore->set_amp_value(self.ampValue);
    [self updateOptionLabel];
    [self updateMenuItemStates];
}

- (void)setAllMute:(id)sender {
    const NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    if (tag == kMenuToggleAllEnable) {
        self.muteMask = 0xffu;
    } else if (tag == kMenuToggleAllDisable) {
        self.muteMask = 0;
    } else if (tag == kMenuToggleAllReverse) {
        self.muteMask ^= 0xffu;
    }
    _liveCore->set_voice_masks(self.muteMask, self.noiseMask);
    [self updateVoiceButtons];
    [self updateOptionLabel];
    [self updateMenuItemStates];
    [self updateLiveMeters];
}

- (void)setAllNoise:(id)sender {
    const NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    if (tag == kMenuToggleAllEnable) {
        self.noiseMask = 0xffu;
    } else if (tag == kMenuToggleAllDisable) {
        self.noiseMask = 0;
    } else if (tag == kMenuToggleAllReverse) {
        self.noiseMask ^= 0xffu;
    }
    _liveCore->set_voice_masks(self.muteMask, self.noiseMask);
    [self updateMenuItemStates];
}

- (void)toggleVoiceNoise:(id)sender {
    const NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
    self.noiseMask ^= 1u << (u32)tag;
    _liveCore->set_voice_masks(self.muteMask, self.noiseMask);
    [self updateMenuItemStates];
}

- (void)toggleExpansionFlag:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.dspOptions ^= (u32)[sender tag];
    _liveCore->set_dsp_options(self.dspOptions);
    [self updateMenuItemStates];
}

- (void)choosePlayTimeMode:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.playTimeMode = [sender tag];
    [self updateMenuItemStates];
}

- (void)setStartTimeMark:(id)sender {
    (void)sender;
    self.statusLabel.stringValue = @"Start position marks are not wired yet";
}

- (void)setLimitTimeMark:(id)sender {
    (void)sender;
    self.statusLabel.stringValue = @"Limit position marks are not wired yet";
}

- (void)resetTimeMarks:(id)sender {
    (void)sender;
    self.statusLabel.stringValue = @"Position marks are not wired yet";
}

- (void)choosePlayOrder:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.playOrder = [sender tag];
    [self updateMenuItemStates];
}

- (void)chooseSeekTime:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.seekTimeMilliseconds = (u32)[sender tag];
    [self updateMenuItemStates];
}

- (void)toggleFastSeek:(id)sender {
    (void)sender;
    self.seekFast = !self.seekFast;
    [self updateMenuItemStates];
}

- (void)toggleSeekAsync:(id)sender {
    (void)sender;
    self.seekAsync = !self.seekAsync;
    [self updateMenuItemStates];
}

- (void)chooseInfoMode:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.infoMode = [sender tag];
    [self updateClassicInfoText];
    [self updateMenuItemStates];
}

- (void)chooseNumericFont:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.numericFontMode = [sender tag];
    [self updateMenuItemStates];
}

- (void)toggleHideMutedChannels:(id)sender {
    (void)sender;
    self.hideMutedChannels = !self.hideMutedChannels;
    [self updateMenuItemStates];
}

- (void)choosePriority:(id)sender {
    if (![sender respondsToSelector:@selector(tag)]) {
        return;
    }
    self.priorityMode = [sender tag];
    [self updateMenuItemStates];
}

- (void)toggleAlwaysOnTop:(id)sender {
    (void)sender;
    self.alwaysOnTop = !self.alwaysOnTop;
    self.window.level = self.alwaysOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
    [self updateMenuItemStates];
}

- (void)toggleNoSleepDuringPlayback:(id)sender {
    (void)sender;
    self.noSleepDuringPlayback = !self.noSleepDuringPlayback;
    [self updateMenuItemStates];
}

- (void)removeSelectedTracks:(id)sender {
    (void)sender;
    NSIndexSet *rows = self.tableView.selectedRowIndexes;
    if (rows.count == 0) {
        return;
    }
    const BOOL removingCurrent = self.currentIndex >= 0 && [rows containsIndex:(NSUInteger)self.currentIndex];
    if (removingCurrent) {
        self.currentIndex = -1;
    }
    [self.playlist removeObjectsAtIndexes:rows];
    [self.tableView reloadData];
    if (self.playlist.count > 0) {
        NSUInteger next = MIN(rows.firstIndex, self.playlist.count - 1);
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
    }
    [self updateControlState];
}

- (void)clearPlaylist:(id)sender {
    (void)sender;
    self.currentIndex = -1;
    [self.playlist removeAllObjects];
    [self.tableView reloadData];
    [self updateControlState];
}

- (void)moveSelectedTrackUp:(id)sender {
    (void)sender;
    NSInteger row = self.tableView.selectedRow;
    if (row <= 0 || row >= (NSInteger)self.playlist.count) {
        return;
    }
    [self.playlist exchangeObjectAtIndex:(NSUInteger)row withObjectAtIndex:(NSUInteger)(row - 1)];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)(row - 1)] byExtendingSelection:NO];
    if (self.currentIndex == row) {
        self.currentIndex = row - 1;
    } else if (self.currentIndex == row - 1) {
        self.currentIndex = row;
    }
    [self updateControlState];
}

- (void)moveSelectedTrackDown:(id)sender {
    (void)sender;
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row + 1 >= (NSInteger)self.playlist.count) {
        return;
    }
    [self.playlist exchangeObjectAtIndex:(NSUInteger)row withObjectAtIndex:(NSUInteger)(row + 1)];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)(row + 1)] byExtendingSelection:NO];
    if (self.currentIndex == row) {
        self.currentIndex = row + 1;
    } else if (self.currentIndex == row + 1) {
        self.currentIndex = row;
    }
    [self updateControlState];
}

- (void)openFiles:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithObject:@"spc"];
    for (NSUInteger i = 0; i <= 9; ++i) {
        [types addObject:[NSString stringWithFormat:@"sp%lu", (unsigned long)i]];
    }
    [types addObject:@"lst"];
    panel.allowedFileTypes = types;

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            return;
        }
        if (panel.URLs.count == 1 && IsSPCFileURL(panel.URLs.firstObject)) {
            SPCPlaylistItem *item = LoadPlaylistItemFromURL(panel.URLs.firstObject);
            if (item) {
                [self playItem:item playlistIndex:-1 autoplay:YES];
            }
            return;
        }
        [self addURLsToPlaylist:panel.URLs];
    }];
}

- (NSURL *)playlistEntryURLForPath:(NSString *)path relativeToPlaylist:(NSURL *)playlistURL {
    if (path.length == 0) {
        return nil;
    }
    NSString *normalized = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSURL *baseURL = [playlistURL URLByDeletingLastPathComponent];
    if ([normalized hasPrefix:@"./"]) {
        return [baseURL URLByAppendingPathComponent:[normalized substringFromIndex:2]];
    }
    if ([normalized hasPrefix:@"/"]) {
        return [NSURL fileURLWithPath:normalized];
    }
    return [baseURL URLByAppendingPathComponent:normalized];
}

- (NSArray<NSURL *> *)urlsFromPlaylistURL:(NSURL *)playlistURL {
    NSData *data = [NSData dataWithContentsOfURL:playlistURL];
    if (!data.length) {
        return @[];
    }

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    const NSUInteger length = data.length;
    static const char kHeaderB[] = "SPCPLAY PLAYLIST";

    if (length >= 22 && memcmp(bytes, kHeaderB, 16) == 0) {
        NSUInteger offset = 16;
        uint16_t count = ReadLE16Bytes(bytes + offset);
        offset += 6;  // count, top index, selected index
        for (uint16_t i = 0; i < count && offset + 2 <= length; ++i) {
            uint16_t packedSize = ReadLE16Bytes(bytes + offset);
            offset += 2;
            uint16_t pathSize = 0;
            uint16_t titleSize = 0;
            NSStringEncoding encoding = NSISOLatin1StringEncoding;
            if (packedSize == 0xffff) {
                if (offset + 4 > length) {
                    break;
                }
                pathSize = ReadLE16Bytes(bytes + offset);
                titleSize = ReadLE16Bytes(bytes + offset + 2);
                offset += 4;
                encoding = NSUTF8StringEncoding;
            } else {
                pathSize = packedSize & 0x03ff;
                titleSize = (packedSize >> 10) & 0x003f;
            }
            if (offset + pathSize + titleSize > length) {
                break;
            }
            NSData *pathData = [NSData dataWithBytes:bytes + offset length:pathSize];
            offset += pathSize + titleSize;
            NSString *path = StringFromPlaylistBytes(pathData, encoding);
            NSURL *entryURL = [self playlistEntryURLForPath:path relativeToPlaylist:playlistURL];
            if (entryURL && IsSPCFileURL(entryURL)) {
                [urls addObject:entryURL];
            }
        }
        return urls;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *path = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (path.length == 0 || [path hasPrefix:@"#"]) {
            continue;
        }
        NSURL *entryURL = [self playlistEntryURLForPath:path relativeToPlaylist:playlistURL];
        if (entryURL && IsSPCFileURL(entryURL)) {
            [urls addObject:entryURL];
        }
    }
    return urls;
}

- (NSArray<NSURL *> *)expandURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSURL *> *expanded = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *url in urls) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) {
            NSDirectoryEnumerator<NSURL *> *enumerator =
                [fm enumeratorAtURL:url
          includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                        errorHandler:nil];
            NSMutableArray<NSURL *> *folderSPCs = [NSMutableArray array];
            for (NSURL *child in enumerator) {
                if (IsSPCFileURL(child)) {
                    [folderSPCs addObject:child];
                }
            }
            [folderSPCs sortUsingComparator:^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
                return [lhs.path localizedCaseInsensitiveCompare:rhs.path];
            }];
            [expanded addObjectsFromArray:folderSPCs];
        } else if (IsPlaylistFileURL(url)) {
            [expanded addObjectsFromArray:[self urlsFromPlaylistURL:url]];
        } else if (IsSPCFileURL(url)) {
            [expanded addObject:url];
        }
    }
    return expanded;
}

- (BOOL)openExternalFileURLs:(NSArray<NSURL *> *)urls activate:(BOOL)activate {
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        if (url.isFileURL) {
            [fileURLs addObject:url];
        }
    }
    if (fileURLs.count == 0) {
        return NO;
    }

    if (!self.window) {
        NSArray<NSURL *> *pendingURLs = [fileURLs copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openExternalFileURLs:pendingURLs activate:activate];
        });
        return YES;
    }

    if (activate) {
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }

    if (fileURLs.count == 1 && IsSPCFileURL(fileURLs.firstObject)) {
        SPCPlaylistItem *item = LoadPlaylistItemFromURL(fileURLs.firstObject);
        if (!item) {
            self.statusLabel.stringValue = @"Could not read SPC";
            return NO;
        }
        [self playItem:item playlistIndex:-1 autoplay:YES];
        return YES;
    }

    NSArray<NSURL *> *expanded = [self expandURLs:fileURLs];
    if (expanded.count == 0) {
        self.statusLabel.stringValue = @"No SPC files found";
        return NO;
    }

    [self addURLsToPlaylist:fileURLs];
    return YES;
}

- (BOOL)addURLsToPlaylist:(NSArray<NSURL *> *)urls skipExisting:(BOOL)skipExisting {
    NSArray<NSURL *> *expanded = [self expandURLs:urls];
    NSMutableSet<NSString *> *existingPaths = [NSMutableSet set];
    if (skipExisting) {
        for (SPCPlaylistItem *existingItem in self.playlist) {
            NSString *canonical = CanonicalFilePath(existingItem.sourcePath);
            if (canonical.length > 0) {
                [existingPaths addObject:canonical];
            }
        }
    }

    NSInteger firstAddedIndex = -1;
    for (NSURL *url in expanded) {
        NSString *canonical = CanonicalFileURLPath(url);
        if (skipExisting && canonical.length > 0 && [existingPaths containsObject:canonical]) {
            continue;
        }
        SPCPlaylistItem *item = LoadPlaylistItemFromURL(url);
        if (!item) {
            continue;
        }
        if (firstAddedIndex < 0) {
            firstAddedIndex = (NSInteger)self.playlist.count;
        }
        [self.playlist addObject:item];
        if (skipExisting && canonical.length > 0) {
            [existingPaths addObject:canonical];
        }
    }
    [self.tableView reloadData];
    if (firstAddedIndex >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)firstAddedIndex]
                    byExtendingSelection:NO];
    }
    [self updateControlState];
    return firstAddedIndex >= 0;
}

- (void)addURLsToPlaylist:(NSArray<NSURL *> *)urls {
    [self addURLsToPlaylist:urls skipExisting:NO];
}

- (void)appendCurrentToPlaylist:(id)sender {
    (void)sender;
    if (!self.currentItem) {
        return;
    }
    SPCPlaylistItem *item = LoadPlaylistItemFromURL([NSURL fileURLWithPath:self.currentItem.sourcePath]);
    if (!item) {
        return;
    }
    [self.playlist addObject:item];
    [self.tableView reloadData];
    NSInteger index = (NSInteger)self.playlist.count - 1;
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index]
                byExtendingSelection:NO];
    [self updateControlState];
}

- (BOOL)writePlaylistToURL:(NSURL *)url error:(NSError **)error {
    NSMutableData *data = [NSMutableData data];
    static const char kHeaderB[] = "SPCPLAY PLAYLIST";
    NSUInteger writableCount = 0;
    for (SPCPlaylistItem *item in self.playlist) {
        NSData *pathData = [item.sourcePath dataUsingEncoding:NSUTF8StringEncoding];
        NSString *title = item.titleText.length ? item.titleText : item.displayName;
        NSData *titleData = [title dataUsingEncoding:NSUTF8StringEncoding];
        if (pathData && titleData && pathData.length <= UINT16_MAX && titleData.length <= UINT16_MAX) {
            ++writableCount;
        }
    }

    [data appendBytes:kHeaderB length:16];
    AppendLE16(data, static_cast<uint16_t>(MIN(writableCount, (NSUInteger)UINT16_MAX)));
    AppendLE16(data, 0);
    AppendLE16(data, self.tableView.selectedRow >= 0 ?
        static_cast<uint16_t>(MIN((NSUInteger)self.tableView.selectedRow, (NSUInteger)UINT16_MAX)) : 0);

    for (SPCPlaylistItem *item in self.playlist) {
        NSData *pathData = [item.sourcePath dataUsingEncoding:NSUTF8StringEncoding];
        NSString *title = item.titleText.length ? item.titleText : item.displayName;
        NSData *titleData = [title dataUsingEncoding:NSUTF8StringEncoding];
        if (!pathData || pathData.length > UINT16_MAX || titleData.length > UINT16_MAX) {
            continue;
        }
        AppendLE16(data, 0xffff);
        AppendLE16(data, static_cast<uint16_t>(pathData.length));
        AppendLE16(data, static_cast<uint16_t>(titleData.length));
        [data appendData:pathData];
        [data appendData:titleData];
    }

    return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

- (void)savePlaylistAs:(id)sender {
    (void)sender;
    if (self.playlist.count == 0) {
        self.statusLabel.stringValue = @"Playlist is empty";
        return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"lst"];
    panel.nameFieldStringValue = @"spcplay.lst";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSError *error = nil;
        if (![self writePlaylistToURL:panel.URL error:&error]) {
            self.statusLabel.stringValue = error.localizedDescription ?: @"Failed to save playlist";
            return;
        }
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Saved %@", panel.URL.lastPathComponent];
    }];
}

- (NSArray<NSURL *> *)fileURLsFromDraggingInfo:(id<NSDraggingInfo>)sender {
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSArray<NSURL *> *urls =
        [pasteboard readObjectsForClasses:@[NSURL.class]
                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count > 0) {
        return urls;
    }

    NSMutableArray<NSURL *> *fallbackURLs = [NSMutableArray array];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<NSString *> *filenames = [pasteboard propertyListForType:NSFilenamesPboardType];
    if ([filenames isKindOfClass:NSArray.class]) {
        for (NSString *filename in filenames) {
            if ([filename isKindOfClass:NSString.class] && filename.length > 0) {
                [fallbackURLs addObject:[NSURL fileURLWithPath:filename]];
            }
        }
    }

    NSURL *url = [NSURL URLFromPasteboard:pasteboard];
#pragma clang diagnostic pop
    if (url.isFileURL) {
        [fallbackURLs addObject:url];
    }
    return fallbackURLs;
}

- (NSDragOperation)dragOperationForDraggingInfo:(id<NSDraggingInfo>)sender {
    return [self fileURLsFromDraggingInfo:sender].count > 0 ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)draggingLocationIsInPlaylist:(id<NSDraggingInfo>)sender {
    NSScrollView *scrollView = self.tableView.enclosingScrollView;
    NSView *contentView = self.window.contentView;
    if (!scrollView || !contentView) {
        return NO;
    }
    NSRect playlistRect = [contentView convertRect:scrollView.bounds fromView:scrollView];
    return NSPointInRect(sender.draggingLocation, playlistRect);
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self dragOperationForDraggingInfo:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self dragOperationForDraggingInfo:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [self fileURLsFromDraggingInfo:sender];
    if (urls.count == 0) {
        return NO;
    }
    if ([self draggingLocationIsInPlaylist:sender]) {
        BOOL didAdd = [self addURLsToPlaylist:urls skipExisting:YES];
        if (!didAdd) {
            self.statusLabel.stringValue = @"Already in playlist";
        }
        return YES;
    }

    NSURL *firstSPCURL = [self expandURLs:urls].firstObject;
    if (!firstSPCURL) {
        self.statusLabel.stringValue = @"No SPC files found";
        return NO;
    }

    SPCPlaylistItem *item = LoadPlaylistItemFromURL(firstSPCURL);
    if (!item) {
        self.statusLabel.stringValue = @"Could not read SPC";
        return NO;
    }
    [self playItem:item playlistIndex:-1 autoplay:YES];
    return YES;
}

- (NSString *)toolDirectory {
    return [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
}

- (NSString *)bundledSpc2wavPath {
    return [[self toolDirectory] stringByAppendingPathComponent:@"spc2wav"];
}

- (NSString *)temporaryRenderPathForItem:(SPCPlaylistItem *)item {
    NSString *renderDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"spcplay-macos-renders"];
    [[NSFileManager defaultManager] createDirectoryAtPath:renderDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *baseName = item.sourcePath.lastPathComponent.stringByDeletingPathExtension;
    NSString *safeName = [NSString stringWithFormat:@"%lu-%@.wav",
                          (unsigned long)item.sourcePath.hash,
                          baseName];
    return [renderDir stringByAppendingPathComponent:safeName];
}

- (void)playSelectedRow:(id)sender {
    (void)sender;
    NSInteger row = self.tableView.clickedRow >= 0 ? self.tableView.clickedRow : self.tableView.selectedRow;
    if (row >= 0) {
        [self playTrackAtIndex:row autoplay:YES];
    }
}

- (void)playTrackAtIndex:(NSInteger)index autoplay:(BOOL)autoplay {
    if (index < 0 || index >= (NSInteger)self.playlist.count) {
        return;
    }
    [self playItem:self.playlist[(NSUInteger)index] playlistIndex:index autoplay:autoplay];
}

- (void)playItem:(SPCPlaylistItem *)item playlistIndex:(NSInteger)playlistIndex autoplay:(BOOL)autoplay {
    if (!item) {
        return;
    }
    ++self.renderGeneration;
    [self cancelActiveRender];
    [self stopPlaybackTimer];
    [self stopMeterTimer];
    [self stopLiveAudioOutput];
    _liveCore->pause_streaming();
    [self.player stop];
    self.player = nil;

    self.currentIndex = playlistIndex;
    self.currentItem = item;
    if (playlistIndex >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)playlistIndex]
                    byExtendingSelection:NO];
    } else {
        [self.tableView deselectAll:nil];
    }

    [self updateMetadataForItem:item status:@"Loading SPC into SNESAPU..."];

    NSData *data = [NSData dataWithContentsOfFile:item.sourcePath];
    if (!data || data.length < kSpcSize) {
        [self updateMetadataForItem:item status:@"Could not read SPC"];
        [self updateControlState];
        return;
    }

    [self applyCurrentAudioSettingsToCore];
    if (!_liveCore->load(static_cast<const u8 *>(data.bytes),
                         data.length,
                         (u32)item.songSeconds,
                         (u32)item.fadeMilliseconds,
                         (u32)item.renderSeconds)) {
        [self updateMetadataForItem:item status:@"SNESAPU failed to load this SPC"];
        [self updateControlState];
        return;
    }

    [self updatePlaybackPosition];
    [self updateLiveMeters];
    if (!autoplay) {
        [self updateMetadataForItem:item status:@"Ready to play"];
        SetClassicButtonTitle(self.playButton, @"PLAY");
        [self updateControlState];
        return;
    }

    NSError *error = nil;
    const NSUInteger prefillChunks = self.nextPlaybackPrefillChunks > 0 ?
        self.nextPlaybackPrefillChunks :
        kLiveWaveBufferPrefillCount;
    self.nextPlaybackPrefillChunks = 0;
    if (![self startLiveEngineWithPrefillChunks:prefillChunks error:&error]) {
        [self updateMetadataForItem:item status:error.localizedDescription ?: @"Failed to start audio engine"];
        SetClassicButtonTitle(self.playButton, @"PLAY");
        [self updateControlState];
        return;
    }
    [self updateMetadataForItem:item status:@"Playing live"];
    SetClassicButtonTitle(self.playButton, @"PAUSE");
    [self updateControlState];
}

- (void)renderItem:(SPCPlaylistItem *)item
            toPath:(NSString *)outputPath
          autoplay:(BOOL)autoplay
        generation:(NSUInteger)generation {
    [self updateMetadataForItem:item
                         status:[NSString stringWithFormat:@"Rendering with SNESAPU (%lu sec)...",
                                                           (unsigned long)item.renderSeconds]];
    [self setRenderingActive:YES];
    SetClassicButtonTitle(self.playButton, @"PLAY");

    NSString *toolPath = [self bundledSpc2wavPath];
    NSString *seconds = [NSString stringWithFormat:@"%lu", (unsigned long)item.renderSeconds];
    NSTask *task = [NSTask new];
    task.launchPath = toolPath;
    task.arguments = @[item.sourcePath, outputPath, seconds];
    task.environment = @{
        @"SNESAPU_RENDER_SAMPLES": @"1",
        @"SNESAPU_CHUNK_SAMPLES": @"3200",
        @"SNESAPU_INTERPOLATION": [NSString stringWithFormat:@"%u", self.interpolationMode],
        @"SNESAPU_DSP_OPTIONS": [NSString stringWithFormat:@"%u", self.dspOptions],
        @"SNESAPU_SPEED_VALUE": [NSString stringWithFormat:@"%u", self.speedValue],
        @"SNESAPU_AMP_VALUE": [NSString stringWithFormat:@"%u", self.ampValue],
        @"SNESAPU_PITCH_VALUE": [NSString stringWithFormat:@"%u", self.pitchValue],
        @"SNESAPU_PITCH_ASYNC": self.pitchAsync ? @"1" : @"0",
        @"SNESAPU_STEREO_SEPARATION": [NSString stringWithFormat:@"%u", self.stereoSeparation],
        @"SNESAPU_FEEDBACK": [NSString stringWithFormat:@"%u", self.feedbackValue],
        @"SNESAPU_MUTE_MASK": [NSString stringWithFormat:@"%u", self.muteMask],
        @"SNESAPU_NOISE_MASK": [NSString stringWithFormat:@"%u", self.noiseMask],
        @"SNESAPU_OUTPUT_CHANNELS": [NSString stringWithFormat:@"%u", self.outputChannels],
        @"SNESAPU_OUTPUT_BITS": [NSString stringWithFormat:@"%d", (s32)self.outputBits],
        @"SNESAPU_OUTPUT_RATE": [NSString stringWithFormat:@"%u", self.outputRate],
    };

    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardError = stderrPipe;
    task.standardOutput = [NSPipe pipe];
    self.activeRenderTask = task;

    dispatch_async(ClassicBackgroundQueue(), ^{
        NSError *error = nil;
        BOOL launched = ClassicLaunchTask(task, &error);
        if (launched) {
            [task waitUntilExit];
        }

        NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
        NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
        if (!stderrText) {
            stderrText = @"";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.activeRenderTask == task) {
                self.activeRenderTask = nil;
            }
            if (generation != self.renderGeneration) {
                return;
            }

            [self setRenderingActive:NO];
            if (!launched || task.terminationStatus != 0) {
                NSString *message = error.localizedDescription ?: stderrText;
                if (message.length == 0) {
                    message = @"spc2wav failed";
                }
                [self updateMetadataForItem:item status:message];
                return;
            }

            item.renderedPath = outputPath;
            [self loadPlayerForPath:outputPath autoplay:autoplay];
        });
    });
}

- (void)loadPlayerForPath:(NSString *)path autoplay:(BOOL)autoplay {
    if (self.player) {
        [self.player stop];
    }
    [self stopPlaybackTimer];
    [self setRenderingActive:NO];
    NSError *error = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    self.player.delegate = self;
    if (!self.player || error) {
        self.statusLabel.stringValue = error.localizedDescription ?: @"Failed to open rendered audio";
        SetClassicButtonTitle(self.playButton, @"PLAY");
        [self updatePlaybackPosition];
        [self updateControlState];
        return;
    }

    [self.player prepareToPlay];
    [self updatePlaybackPosition];
    if (autoplay) {
        [self.player play];
        self.statusLabel.stringValue = @"Playing";
        SetClassicButtonTitle(self.playButton, @"PAUSE");
        [self startPlaybackTimer];
    } else {
        self.statusLabel.stringValue = @"Ready to play";
        SetClassicButtonTitle(self.playButton, @"PLAY");
    }
    [self updateControlState];
}

- (void)togglePlayPause:(id)sender {
    (void)sender;
    if (_liveCore->loaded() && _audioQueueRunning) {
        [self stopLiveAudioOutput];
        _liveCore->pause_streaming();
        self.livePaused = YES;
        [self stopPlaybackTimer];
        [self updatePlaybackPosition];
        SetClassicButtonTitle(self.playButton, @"PLAY");
        self.statusLabel.stringValue = @"Paused";
        [self updateControlState];
        return;
    }

    if (_liveCore->loaded()) {
        const double duration = _liveCore->song_seconds();
        const double current = _liveCore->snapshot().t64_count / 64000.0;
        if (duration > 0.0 && current >= duration) {
            _liveCore->seek_seconds(0.0, true);
        }
        NSError *error = nil;
        if (![self startLiveEngineWithError:&error]) {
            self.statusLabel.stringValue = error.localizedDescription ?: @"Failed to start audio engine";
            return;
        }
        SetClassicButtonTitle(self.playButton, @"PAUSE");
        self.statusLabel.stringValue = @"Playing live";
        [self updateControlState];
        return;
    }

    if (self.player.playing) {
        [self.player pause];
        [self stopPlaybackTimer];
        [self updatePlaybackPosition];
        SetClassicButtonTitle(self.playButton, @"PLAY");
        self.statusLabel.stringValue = @"Paused";
        [self updateControlState];
        return;
    }

    if (self.player) {
        if (self.player.duration > 0.0 && self.player.currentTime >= self.player.duration) {
            self.player.currentTime = 0.0;
        }
        [self.player play];
        [self startPlaybackTimer];
        SetClassicButtonTitle(self.playButton, @"PAUSE");
        self.statusLabel.stringValue = @"Playing";
        [self updateControlState];
        return;
    }

    NSInteger row = self.tableView.selectedRow >= 0 ? self.tableView.selectedRow : 0;
    [self playTrackAtIndex:row autoplay:YES];
}

- (void)playFromFileMenu:(id)sender {
    (void)sender;
    if ([self isTransportPlaying]) {
        return;
    }
    [self togglePlayPause:nil];
}

- (void)pauseFromFileMenu:(id)sender {
    (void)sender;
    if (![self isTransportPlaying]) {
        return;
    }
    [self togglePlayPause:nil];
}

- (void)exitApplication:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)stopPlayback:(id)sender {
    (void)sender;
    ++self.renderGeneration;
    [self cancelActiveRender];
    [self stopPlaybackTimer];
    [self stopMeterTimer];
    [self stopLiveAudioOutput];
    _liveCore->pause_streaming();
    self.livePaused = NO;
    if (_liveCore->loaded()) {
        _liveCore->seek_seconds(0.0, true);
    }
    if (self.player) {
        [self.player stop];
        self.player.currentTime = 0;
    }
    [self updatePlaybackPosition];
    [self updateLiveMeters];
    SetClassicButtonTitle(self.playButton, @"PLAY");
    if (self.currentIndex >= 0 && self.currentIndex < (NSInteger)self.playlist.count) {
        [self updateMetadataForItem:self.playlist[(NSUInteger)self.currentIndex] status:@"Stopped"];
    } else if (self.currentItem) {
        [self updateMetadataForItem:self.currentItem status:@"Stopped"];
    } else {
        self.statusLabel.stringValue = @"Stopped";
    }
    [self updateControlState];
}

- (void)restartTrack:(id)sender {
    (void)sender;
    if (_liveCore->loaded()) {
        if (!_liveCore->seek_seconds(0.0, true)) {
            self.statusLabel.stringValue = @"SNESAPU failed to restart";
            return;
        }
        NSError *error = nil;
        if (![self startLiveEngineWithError:&error]) {
            self.statusLabel.stringValue = error.localizedDescription ?: @"Failed to start audio engine";
            return;
        }
        SetClassicButtonTitle(self.playButton, @"PAUSE");
        self.statusLabel.stringValue = @"Playing live";
        [self updateControlState];
        return;
    }
    if (self.currentIndex >= 0 && self.currentIndex < (NSInteger)self.playlist.count) {
        [self playTrackAtIndex:self.currentIndex autoplay:YES];
    } else if (self.currentItem) {
        [self playItem:self.currentItem playlistIndex:-1 autoplay:YES];
    }
}

- (void)seekBySeconds:(NSTimeInterval)delta {
    if (![self isTransportPlaying]) {
        return;
    }
    NSTimeInterval target = self.positionSlider.doubleValue + delta;
    target = MAX(0.0, MIN(target, self.positionSlider.maxValue));
    if (_liveCore->loaded()) {
        if (!_liveCore->seek_seconds(target, self.seekFast)) {
            self.statusLabel.stringValue = @"SNESAPU failed to seek";
            return;
        }
        if (_audioQueueRunning && !self.livePaused) {
            NSError *error = nil;
            if (![self startLiveEngineWithError:&error]) {
                self.statusLabel.stringValue = error.localizedDescription ?: @"SNESAPU failed to prebuffer audio";
            }
        }
    } else if (self.player) {
        self.player.currentTime = target;
    }
    [self updatePlaybackPosition];
    [self updateLiveMeters];
}

- (void)seekBackward:(id)sender {
    (void)sender;
    double step = self.seekTimeMilliseconds / 1000.0;
    if (self.seekAsync) {
        step *= static_cast<double>(self.speedValue) / kDefaultSpeed;
    }
    [self seekBySeconds:-step];
}

- (void)seekForward:(id)sender {
    (void)sender;
    double step = self.seekTimeMilliseconds / 1000.0;
    if (self.seekAsync) {
        step *= static_cast<double>(self.speedValue) / kDefaultSpeed;
    }
    [self seekBySeconds:step];
}

- (void)previousTrack:(id)sender {
    (void)sender;
    if (self.playlist.count == 0) {
        return;
    }
    NSInteger nextIndex = self.currentIndex > 0 ? self.currentIndex - 1 : 0;
    [self playTrackAtIndex:nextIndex autoplay:YES];
}

- (void)nextTrack:(id)sender {
    (void)sender;
    if (self.playlist.count == 0) {
        return;
    }
    NSInteger nextIndex = self.currentIndex + 1;
    if (nextIndex >= (NSInteger)self.playlist.count) {
        nextIndex = (NSInteger)self.playlist.count - 1;
    }
    [self playTrackAtIndex:nextIndex autoplay:YES];
}

- (void)saveCurrentAsWav:(id)sender {
    (void)sender;
    SPCPlaylistItem *item = self.currentItem;
    if (!item) {
        self.statusLabel.stringValue = @"Open an SPC first";
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"wav"];
    panel.nameFieldStringValue =
        [[item.sourcePath.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:@"wav"];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) {
            return;
        }
        [self exportItem:item toPath:panel.URL.path];
    }];
}

- (void)exportItem:(SPCPlaylistItem *)item toPath:(NSString *)outputPath {
    self.statusLabel.stringValue = @"Saving WAV...";

    NSString *toolPath = [self bundledSpc2wavPath];
    NSString *seconds = [NSString stringWithFormat:@"%lu", (unsigned long)item.renderSeconds];

    dispatch_async(ClassicBackgroundQueue(), ^{
        NSTask *task = [NSTask new];
        task.launchPath = toolPath;
        task.arguments = @[item.sourcePath, outputPath, seconds];
        task.environment = @{
            @"SNESAPU_RENDER_SAMPLES": @"1",
            @"SNESAPU_CHUNK_SAMPLES": @"3200",
            @"SNESAPU_INTERPOLATION": [NSString stringWithFormat:@"%u", self.interpolationMode],
            @"SNESAPU_DSP_OPTIONS": [NSString stringWithFormat:@"%u", self.dspOptions],
            @"SNESAPU_SPEED_VALUE": [NSString stringWithFormat:@"%u", self.speedValue],
            @"SNESAPU_AMP_VALUE": [NSString stringWithFormat:@"%u", self.ampValue],
            @"SNESAPU_PITCH_VALUE": [NSString stringWithFormat:@"%u", self.pitchValue],
            @"SNESAPU_PITCH_ASYNC": self.pitchAsync ? @"1" : @"0",
            @"SNESAPU_STEREO_SEPARATION": [NSString stringWithFormat:@"%u", self.stereoSeparation],
            @"SNESAPU_FEEDBACK": [NSString stringWithFormat:@"%u", self.feedbackValue],
            @"SNESAPU_MUTE_MASK": [NSString stringWithFormat:@"%u", self.muteMask],
            @"SNESAPU_NOISE_MASK": [NSString stringWithFormat:@"%u", self.noiseMask],
            @"SNESAPU_OUTPUT_CHANNELS": [NSString stringWithFormat:@"%u", self.outputChannels],
            @"SNESAPU_OUTPUT_BITS": [NSString stringWithFormat:@"%d", (s32)self.outputBits],
            @"SNESAPU_OUTPUT_RATE": [NSString stringWithFormat:@"%u", self.outputRate],
        };

        NSError *error = nil;
        BOOL launched = ClassicLaunchTask(task, &error);
        if (launched) {
            [task waitUntilExit];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!launched || task.terminationStatus != 0) {
                self.statusLabel.stringValue = error.localizedDescription ?: @"Failed to save WAV";
                return;
            }
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Saved %@", outputPath.lastPathComponent];
        });
    });
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player;
    (void)flag;
    [self finishCurrentTrackAndAdvance];
}

- (void)finishCurrentTrackAndAdvance {
    [self stopPlaybackTimer];
    [self stopMeterTimer];
    [self stopLiveAudioOutput];
    _liveCore->pause_streaming();
    [self updatePlaybackPosition];
    [self updateLiveMeters];
    SetClassicButtonTitle(self.playButton, @"PLAY");

    NSInteger nextIndex = -1;
    const NSInteger playlistCount = (NSInteger)self.playlist.count;
    if (self.currentIndex >= 0 && playlistCount > 0) {
        switch (self.playOrder) {
            case 1:
                nextIndex = self.currentIndex + 1;
                break;
            case 2:
                nextIndex = self.currentIndex - 1;
                break;
            case 3:
            case 4:
                nextIndex = (NSInteger)arc4random_uniform((uint32_t)playlistCount);
                break;
            case 5:
                nextIndex = self.currentIndex;
                break;
            case 0:
            default:
                nextIndex = -1;
                break;
        }
    }

    if (nextIndex >= 0 && nextIndex < playlistCount) {
        [self playTrackAtIndex:nextIndex autoplay:YES];
    } else {
        self.statusLabel.stringValue = @"Finished";
        [self updateControlState];
    }
}

@end

static int RunLiveRenderSmokeTest(NSString *path) {
    gLiveSmokeDiagnostics = true;
    fprintf(stderr, "live smoke read SPC\n");
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < kSpcSize) {
        fprintf(stderr, "failed to read SPC for live smoke test: %s\n", path.UTF8String);
        return 1;
    }

    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    ReadSPCTiming(data, &songSeconds, &fadeMilliseconds);

    LiveSNESAPUCore core;
    const u32 outputChannels = SanitizedOutputChannels(
        EnvU32OrDefault("SNESAPU_OUTPUT_CHANNELS", kDefaultOutputChannels));
    const u32 outputBits = SanitizedOutputBits(
        EnvBitsOrDefault("SNESAPU_OUTPUT_BITS", kDefaultOutputBits));
    const u32 outputRate = SanitizedOutputRate(
        EnvU32OrDefault("SNESAPU_OUTPUT_RATE", kDefaultRate));
    core.set_output_format(outputChannels, outputBits, outputRate);
    fprintf(stderr, "live smoke load\n");
    if (!core.load(static_cast<const u8 *>(data.bytes),
                   data.length,
                   songSeconds,
                   fadeMilliseconds,
                   (u32)SuggestedRenderSeconds(data))) {
        fprintf(stderr, "failed to load SPC into live core\n");
        return 1;
    }
    fprintf(stderr, "live smoke loaded\n");
    auto checkSeekPosition = [&](const char *label, double expected) {
        const double actual = core.snapshot().t64_count / 64000.0;
        if (std::fabs(actual - expected) > 0.05) {
            fprintf(stderr, "%s seek landed at %.3f seconds, expected %.3f\n", label, actual, expected);
            return false;
        }
        return true;
    };
    if (!core.seek_seconds(10.0, true) || !checkSeekPosition("forward", 10.0)) {
        return 1;
    }
    if (!core.seek_seconds(3.0, true) || !checkSeekPosition("backward", 3.0)) {
        return 1;
    }
    if (!core.seek_seconds(0.0, true) || !checkSeekPosition("restart", 0.0)) {
        return 1;
    }
    if (!core.start_streaming()) {
        fprintf(stderr, "failed to start live stream producer\n");
        return 1;
    }
    fprintf(stderr, "live smoke producer started\n");

    std::array<AVAudioFrameCount, 10> pulls = {371, 512, 128, 544, 371, 735, 64, 1024, 512, 371};
    std::vector<float> left(8192);
    std::vector<float> right(8192);
    struct StereoAudioBufferList {
        UInt32 mNumberBuffers;
        AudioBuffer mBuffers[2];
    } audioBufferStorage = {};
    AudioBufferList *audioBufferList = reinterpret_cast<AudioBufferList *>(&audioBufferStorage);
    audioBufferList->mNumberBuffers = 2;
    audioBufferList->mBuffers[0].mNumberChannels = 1;
    audioBufferList->mBuffers[0].mData = left.data();
    audioBufferList->mBuffers[1].mNumberChannels = 1;
    audioBufferList->mBuffers[1].mData = right.data();

    for (AVAudioFrameCount frames : pulls) {
        fprintf(stderr, "live smoke render %u\n", frames);
        audioBufferList->mBuffers[0].mDataByteSize = frames * sizeof(float);
        audioBufferList->mBuffers[1].mDataByteSize = frames * sizeof(float);
        core.render(audioBufferList, frames);
        if (!core.loaded()) {
            fprintf(stderr, "live render failed at %u frames\n", frames);
            return 1;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds((static_cast<uint64_t>(frames) * 1000 / outputRate) + 1));
    }
    if (core.underrun_count() != 0) {
        fprintf(stderr, "live render had %llu underruns\n",
                static_cast<unsigned long long>(core.underrun_count()));
        return 1;
    }

    fprintf(stderr, "live render smoke test passed\n");
    return 0;
}

static int RunDirectRenderSmokeTest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < kSpcSize) {
        fprintf(stderr, "failed to read SPC for direct smoke test: %s\n", path.UTF8String);
        return 1;
    }

    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    ReadSPCTiming(data, &songSeconds, &fadeMilliseconds);

    fprintf(stderr, "direct InitAPU\n");
    if (!call_InitAPU(1)) {
        fprintf(stderr, "direct InitAPU failed\n");
        return 1;
    }
    fprintf(stderr, "direct LoadSPCFile\n");
    call_LoadSPCFile(const_cast<void *>(data.bytes));
    fprintf(stderr, "direct SetAPUOpt\n");
    call_SetAPUOpt(MIX_INT, 2, 16, kDefaultRate, InterpolationFromEnvironment(), kDefaultDSPOpts);
    call_SetAPUSmpClk(kDefaultSpeed);
    call_SetDSPPitch(kDefaultPitch);
    call_SetDSPStereo(kDefaultStereo);
    call_SetDSPEFBCT(FeedbackToEfbct(kDefaultFeedback));
    call_SetDSPAmp(kAmp100);
    if (songSeconds > 0) {
        fprintf(stderr, "direct SetAPULength\n");
        call_SetAPULength(songSeconds * 64000U, fadeMilliseconds << 6);
    }

    std::vector<u8> pcm(static_cast<size_t>(kDefaultRate) * 4);
    fprintf(stderr, "direct EmuAPU\n");
    void *end = call_EmuAPU(pcm.data(), 3200, 1);
    const size_t produced = static_cast<u8 *>(end) - pcm.data();
    fprintf(stderr, "direct EmuAPU produced %zu bytes\n", produced);
    return produced == 3200U * 4U ? 0 : 1;
}

static int RunSeekSmokeTest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < kSpcSize) {
        fprintf(stderr, "failed to read SPC for seek smoke test: %s\n", path.UTF8String);
        return 1;
    }

    auto configureAPU = [&]() -> bool {
        if (!call_InitAPU(1)) {
            return false;
        }
        call_LoadSPCFile(const_cast<void *>(data.bytes));
        call_SetAPUOpt(MIX_INT, 2, 16, kDefaultRate, InterpolationFromEnvironment(), kDefaultDSPOpts);
        call_SetAPUSmpClk(kDefaultSpeed);
        call_SetDSPPitch(kDefaultPitch);
        call_SetDSPStereo(kDefaultStereo);
        call_SetDSPEFBCT(FeedbackToEfbct(kDefaultFeedback));
        call_SetDSPAmp(kAmp100);
        return true;
    };

    constexpr u32 kSmokeSamples = 4096;
    constexpr u32 kSeekTargetT64 = 10u * 64000u;
    std::vector<u8> opening(static_cast<size_t>(kSmokeSamples) * 4);
    std::vector<u8> sought(static_cast<size_t>(kSmokeSamples) * 4);

    if (!configureAPU()) {
        fprintf(stderr, "seek smoke initial configure failed\n");
        return 1;
    }
    void *openingEnd = call_EmuAPU(opening.data(), kSmokeSamples, 1);
    const size_t openingBytes = static_cast<u8 *>(openingEnd) - opening.data();
    if (openingBytes != opening.size()) {
        fprintf(stderr, "seek smoke opening render produced %zu bytes\n", openingBytes);
        return 1;
    }

    if (!configureAPU()) {
        fprintf(stderr, "seek smoke seek configure failed\n");
        return 1;
    }
    call_SeekAPU(kSeekTargetT64, 1);
    if (t64Cnt < kSeekTargetT64) {
        fprintf(stderr, "seek smoke backend clock did not advance: %u\n", t64Cnt);
        return 1;
    }

    void *seekEnd = call_EmuAPU(sought.data(), kSmokeSamples, 1);
    const size_t soughtBytes = static_cast<u8 *>(seekEnd) - sought.data();
    if (soughtBytes != sought.size()) {
        fprintf(stderr, "seek smoke post-seek render produced %zu bytes\n", soughtBytes);
        return 1;
    }
    if (std::equal(opening.begin(), opening.end(), sought.begin())) {
        fprintf(stderr, "seek smoke post-seek audio still matches the song opening\n");
        return 1;
    }

    fprintf(stderr, "seek smoke test passed\n");
    return 0;
}

static int RunInfoPanelSmokeTest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < kSpcSize) {
        fprintf(stderr, "failed to read SPC for info panel smoke test: %s\n", path.UTF8String);
        return 1;
    }
    SPCPlaylistItem *item = LoadPlaylistItemFromURL([NSURL fileURLWithPath:path]);
    if (!item) {
        fprintf(stderr, "failed to parse SPC metadata for info panel smoke test\n");
        return 1;
    }

    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    ReadSPCTiming(data, &songSeconds, &fadeMilliseconds);

    LiveSNESAPUCore core;
    if (!core.load(static_cast<const u8 *>(data.bytes),
                   data.length,
                   songSeconds,
                   fadeMilliseconds,
                   (u32)SuggestedRenderSeconds(data))) {
        fprintf(stderr, "failed to load SPC for info panel smoke test\n");
        return 1;
    }
    core.seek_seconds(2.0, true);
    LiveMeterSnapshot snapshot = core.snapshot();
    for (NSInteger mode = 1; mode <= 8; ++mode) {
        NSString *text = ClassicInfoText(mode, item, snapshot, core.loaded());
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        if (lines.count != 5 || text.length == 0) {
            fprintf(stderr, "info panel mode %ld produced invalid text\n", (long)mode);
            return 1;
        }
        if (mode == 7) {
            NSString *emulatorLine = lines[3];
            NSString *registerLine = lines[4];
            NSRange labelRange = [emulatorLine rangeOfString:@"NVPBHIZC"];
            NSString *flagReadout = registerLine.length >= 47 ? [registerLine substringWithRange:NSMakeRange(39, 8)] : @"";
            NSCharacterSet *unexpectedFlagChars = [[NSCharacterSet characterSetWithCharactersInString:@"0-"] invertedSet];
            if (labelRange.location != 39 ||
                registerLine.length < 47 ||
                [flagReadout rangeOfCharacterFromSet:unexpectedFlagChars].location != NSNotFound) {
                fprintf(stderr, "SPC Tags 2 did not preserve PSW flag header/readout layout\n");
                return 1;
            }
        }
    }
    fprintf(stderr, "info panel smoke test passed\n");
    return 0;
}

static int RunBPMSmokeTest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length < kSpcSize) {
        fprintf(stderr, "failed to read SPC for BPM smoke test: %s\n", path.UTF8String);
        return 1;
    }
    SPCPlaylistItem *item = LoadPlaylistItemFromURL([NSURL fileURLWithPath:path]);
    if (!item) {
        fprintf(stderr, "failed to parse SPC metadata for BPM smoke test\n");
        return 1;
    }

    uint32_t songSeconds = 0;
    uint32_t fadeMilliseconds = 0;
    ReadSPCTiming(data, &songSeconds, &fadeMilliseconds);

    LiveSNESAPUCore core;
    if (!core.load(static_cast<const u8 *>(data.bytes),
                   data.length,
                   songSeconds,
                   fadeMilliseconds,
                   (u32)SuggestedRenderSeconds(data))) {
        fprintf(stderr, "failed to load SPC for BPM smoke test\n");
        return 1;
    }
    double analysisSeconds = 5.0;
    if (const char *envSeconds = std::getenv("SNESAPU_BPM_SECONDS")) {
        const double requestedSeconds = std::atof(envSeconds);
        if (std::isfinite(requestedSeconds) && requestedSeconds > 0.0) {
            analysisSeconds = requestedSeconds;
        }
    }
    if (!core.analyze_for_seconds(analysisSeconds)) {
        fprintf(stderr, "failed to render analysis window for BPM smoke test\n");
        return 1;
    }

    LiveMeterSnapshot snapshot = core.snapshot();
    NSString *text = ClassicInfoText(1, item, snapshot, core.loaded());
    fprintf(stderr, "%s\n", text.UTF8String);
    if (snapshot.bpm == 0) {
        fprintf(stderr, "BPM smoke test did not detect a tempo\n");
        return 1;
    }
    fprintf(stderr,
            "BPM smoke test passed: %u BPM (range %u-%u mode %02X kon %u/%u t64 %u)\n",
            snapshot.bpm,
            snapshot.bpm_min,
            snapshot.bpm_max,
            snapshot.bpm_mode,
            snapshot.bpm_kon_count,
            snapshot.bpm_kon_count_old,
            snapshot.t64_count);
    return 0;
}

static int RunLaunchServicesSmokeTest() {
    BOOL alreadyRegistered = NO;
    OSStatus status = EnsureLaunchServicesRegistration(&alreadyRegistered);
    if (status != noErr) {
        fprintf(stderr, "launch services registration failed: %d\n", static_cast<int>(status));
        return 1;
    }
    fprintf(stderr,
            "launch services registration %s\n",
            alreadyRegistered ? "already present" : "registered current bundle");
    return 0;
}

static NSString *CommandLineString(const char *argument) {
    if (!argument) {
        return @"";
    }
    NSString *string = [NSString stringWithUTF8String:argument];
    return string ?: @"";
}

static BOOL CommandLineArgMatches(NSString *argument, NSArray<NSString *> *options) {
    for (NSString *option in options) {
        if ([argument caseInsensitiveCompare:option] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSURL *CommandLineFileURL(NSString *rawPath) {
    NSString *path = [rawPath stringByExpandingTildeInPath];
    if (!path.absolutePath) {
        path = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:path];
    }
    return [NSURL fileURLWithPath:path.stringByStandardizingPath];
}

static BOOL CommandLineLooksLikeUnhandledOption(NSString *argument) {
    return [argument hasPrefix:@"-"] && [argument rangeOfString:@"."].location == NSNotFound;
}

static u32 CommandLineChannelMaskFromString(NSString *channels) {
    u32 mask = 0;
    for (NSUInteger i = 0; i < channels.length; ++i) {
        const unichar c = [channels characterAtIndex:i];
        if (c >= '1' && c <= '8') {
            mask |= 1u << (c - '1');
        }
    }
    return mask;
}

static BOOL CommandLineParseUnsigned(NSString *text, unsigned long *value) {
    const char *start = text.UTF8String;
    if (!start || !start[0]) {
        return NO;
    }
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(start, &end, 10);
    if (!end || *end != '\0') {
        return NO;
    }
    *value = parsed;
    return YES;
}

static void PrintCommandLineUsage(const char *argv0) {
    NSString *name = CommandLineString(argv0).lastPathComponent;
    if (name.length == 0) {
        name = @"spcplay-macos";
    }
    fprintf(stdout,
            "Usage:\n"
            "  %s <SPC-or-LST-file>\n"
            "  %s -o <SPC-or-LST-file>\n"
            "  %s -wav [-o <WAV-file>] [-m <channels>] [-s <channels>] [-v <percent>] [-f] <SPC-file>\n"
            "\n"
            "Windows-compatible GUI arguments:\n"
            "  <file>              Open an SPC/SP0-SP9 file and play it, or load an LST playlist.\n"
            "  -wav, -wave         Save an SPC to WAV. Options match SPCplay: -o/-out, -m/-mute,\n"
            "                      -s/-solo, -v/-volume, and -f.\n"
            "  -p, -r, -s, -q, -l, -next, -prev, -rand\n"
            "                      Recognized as Windows existing-instance control commands.\n",
            name.UTF8String,
            name.UTF8String,
            name.UTF8String);
}

static NSString *BundledSpc2wavPathForCommandLine() {
    return [[[NSBundle mainBundle] executablePath].stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"spc2wav"];
}

static int RunCommandLineWaveSave(int argc, const char *argv[]) {
    NSString *inputPath = nil;
    NSString *outputPath = nil;
    NSString *channelText = nil;
    BOOL soloChannels = NO;
    BOOL forceOverwrite = NO;
    u32 ampValue = kAmp100;

    for (int i = 2; i < argc; ++i) {
        NSString *argument = CommandLineString(argv[i]);
        if (CommandLineArgMatches(argument, @[@"-o", @"-out"])) {
            if (++i >= argc) {
                fprintf(stderr, "[ERROR] WAV output path is required after %s.\n", argument.UTF8String);
                return 2;
            }
            outputPath = CommandLineString(argv[i]);
        } else if (CommandLineArgMatches(argument, @[@"-s", @"-solo"])) {
            if (++i >= argc) {
                fprintf(stderr, "[ERROR] Channel list is required after %s.\n", argument.UTF8String);
                return 2;
            }
            channelText = CommandLineString(argv[i]);
            soloChannels = YES;
        } else if (CommandLineArgMatches(argument, @[@"-m", @"-mute"])) {
            if (++i >= argc) {
                fprintf(stderr, "[ERROR] Channel list is required after %s.\n", argument.UTF8String);
                return 2;
            }
            channelText = CommandLineString(argv[i]);
            soloChannels = NO;
        } else if (CommandLineArgMatches(argument, @[@"-v", @"-volume"])) {
            if (++i >= argc) {
                fprintf(stderr, "[ERROR] Volume percent is required after %s.\n", argument.UTF8String);
                return 2;
            }
            unsigned long percent = 0;
            if (!CommandLineParseUnsigned(CommandLineString(argv[i]), &percent) || percent > 400) {
                fprintf(stderr, "[ERROR] Volume must be a whole percent from 0 to 400.\n");
                return 2;
            }
            ampValue = static_cast<u32>((percent * 65536UL) / 100UL);
        } else if (CommandLineArgMatches(argument, @[@"-f"])) {
            forceOverwrite = YES;
        } else if (!inputPath) {
            inputPath = argument;
        } else {
            fprintf(stderr, "[ERROR] Unexpected extra argument: %s\n", argument.UTF8String);
            return 2;
        }
    }

    if (inputPath.length == 0) {
        fprintf(stderr, "[ERROR] SPC file path is required.\n");
        return 2;
    }

    NSURL *inputURL = CommandLineFileURL(inputPath);
    if (!IsSPCFileURL(inputURL) || ![[NSFileManager defaultManager] isReadableFileAtPath:inputURL.path]) {
        fprintf(stderr, "[ERROR] This is not an SPC file, or file not found.\n");
        return 2;
    }

    NSURL *outputURL = nil;
    if (outputPath.length > 0) {
        outputURL = CommandLineFileURL(outputPath);
    } else {
        outputURL = [NSURL fileURLWithPath:[inputURL.path.stringByDeletingPathExtension stringByAppendingPathExtension:@"wav"]];
    }

    if (!forceOverwrite && [[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
        fprintf(stderr, "[ERROR] WAV file already exists. Add -f option to overwrite, or add -o option to output to another path.\n");
        return 2;
    }

    NSString *toolPath = BundledSpc2wavPathForCommandLine();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        fprintf(stderr, "[ERROR] Could not find bundled spc2wav helper: %s\n", toolPath.UTF8String);
        return 2;
    }

    u32 muteMask = 0;
    if (channelText.length > 0) {
        const u32 requestedMask = CommandLineChannelMaskFromString(channelText);
        muteMask = soloChannels ? (requestedMask ^ 0xFFu) : requestedMask;
    }

    NSMutableDictionary<NSString *, NSString *> *environment =
        [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"SNESAPU_RENDER_SAMPLES"] = @"1";
    environment[@"SNESAPU_CHUNK_SAMPLES"] = @"3200";
    environment[@"SNESAPU_INTERPOLATION"] = [NSString stringWithFormat:@"%u", kDefaultInterpolation];
    environment[@"SNESAPU_DSP_OPTIONS"] = [NSString stringWithFormat:@"%u", kDefaultUserDSPOpts];
    environment[@"SNESAPU_SPEED_VALUE"] = [NSString stringWithFormat:@"%u", kDefaultSpeed];
    environment[@"SNESAPU_AMP_VALUE"] = [NSString stringWithFormat:@"%u", ampValue];
    environment[@"SNESAPU_PITCH_VALUE"] = [NSString stringWithFormat:@"%u", kDefaultPitch];
    environment[@"SNESAPU_PITCH_ASYNC"] = @"0";
    environment[@"SNESAPU_STEREO_SEPARATION"] = [NSString stringWithFormat:@"%u", kDefaultStereo];
    environment[@"SNESAPU_FEEDBACK"] = [NSString stringWithFormat:@"%u", kDefaultFeedback];
    environment[@"SNESAPU_MUTE_MASK"] = [NSString stringWithFormat:@"%u", muteMask];
    environment[@"SNESAPU_NOISE_MASK"] = @"0";
    environment[@"SNESAPU_OUTPUT_CHANNELS"] = [NSString stringWithFormat:@"%u", kDefaultOutputChannels];
    environment[@"SNESAPU_OUTPUT_BITS"] = [NSString stringWithFormat:@"%d", (s32)kDefaultOutputBits];
    environment[@"SNESAPU_OUTPUT_RATE"] = [NSString stringWithFormat:@"%u", kDefaultRate];

    NSTask *task = [NSTask new];
    task.launchPath = toolPath;
    task.arguments = @[inputURL.path, outputURL.path];
    task.environment = environment;
    task.standardOutput = [NSFileHandle fileHandleWithStandardOutput];
    task.standardError = [NSFileHandle fileHandleWithStandardError];

    NSError *error = nil;
    if (!ClassicLaunchTask(task, &error)) {
        fprintf(stderr, "[ERROR] Failed to launch spc2wav: %s\n", error.localizedDescription.UTF8String);
        return 2;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        return task.terminationStatus;
    }

    fprintf(stderr, "Saved WAV: %s\n", outputURL.path.UTF8String);
    return 0;
}

static BOOL CommandLineIsKnownControlAction(NSString *argument, CommandLineControlAction *action) {
    if (CommandLineArgMatches(argument, @[@"-p", @"/p", @"-play"])) {
        *action = CommandLineControlAction::PlayPause;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-r", @"/r", @"-restart"])) {
        *action = CommandLineControlAction::Restart;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-s", @"/s", @"-stop"])) {
        *action = CommandLineControlAction::Stop;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-q", @"/q", @"-quit"])) {
        *action = CommandLineControlAction::Quit;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-l", @"/l", @"-low"])) {
        *action = CommandLineControlAction::VolumeLow;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-next"])) {
        *action = CommandLineControlAction::Next;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-prev"])) {
        *action = CommandLineControlAction::Previous;
        return YES;
    }
    if (CommandLineArgMatches(argument, @[@"-rand"])) {
        *action = CommandLineControlAction::Random;
        return YES;
    }
    return NO;
}

static int ParseCommandLineArguments(int argc, const char *argv[], BOOL *shouldExit) {
    *shouldExit = NO;
    NSMutableArray<NSURL *> *openURLs = [NSMutableArray array];
    BOOL parseOptions = YES;

    for (int i = 1; i < argc; ++i) {
        NSString *argument = CommandLineString(argv[i]);
        if (parseOptions && [argument isEqualToString:@"--"]) {
            parseOptions = NO;
            continue;
        }
        if (parseOptions && CommandLineArgMatches(argument, @[@"-?", @"/?", @"-h", @"/h", @"--help"])) {
            PrintCommandLineUsage(argv[0]);
            *shouldExit = YES;
            return 0;
        }
        if (parseOptions && CommandLineArgMatches(argument, @[@"-v", @"/v", @"--version"])) {
            fprintf(stdout, "spcplay-macos\n");
            *shouldExit = YES;
            return 0;
        }
        if (parseOptions && CommandLineArgMatches(argument, @[@"-o", @"/o", @"-open", @"--open"])) {
            if (++i >= argc) {
                fprintf(stderr, "[ERROR] File path is required after %s.\n", argument.UTF8String);
                *shouldExit = YES;
                return 2;
            }
            [openURLs addObject:CommandLineFileURL(CommandLineString(argv[i]))];
            continue;
        }
        if (parseOptions) {
            CommandLineControlAction action = CommandLineControlAction::None;
            if (CommandLineIsKnownControlAction(argument, &action)) {
                gCommandLineControlAction = action;
                continue;
            }
            if (CommandLineArgMatches(argument, @[@"-bp", @"-breakpoint", @"-dsp", @"-port"])) {
                fprintf(stderr, "[ERROR] %s is a Windows existing-instance debug/control command and is not implemented on macOS yet.\n",
                        argument.UTF8String);
                *shouldExit = YES;
                return 99;
            }
            if (CommandLineLooksLikeUnhandledOption(argument)) {
                fprintf(stderr, "[ERROR] Unknown command-line option: %s\n", argument.UTF8String);
                *shouldExit = YES;
                return 99;
            }
        }
        [openURLs addObject:CommandLineFileURL(argument)];
    }

    if (gCommandLineControlAction != CommandLineControlAction::None) {
        fprintf(stderr,
                "[ERROR] This Windows control command targets an already-running SPCplay instance. "
                "macOS command-line IPC is not implemented yet.\n");
        *shouldExit = YES;
        return 99;
    }

    gCommandLineOpenURLs = [openURLs copy];
    return 0;
}

static int RunCommandLineOpenParseSmokeTest(NSString *path) {
    const char *program = "spcplay-macos";
    const char *pathArgument = path.fileSystemRepresentation;
    const char *directArguments[] = {program, pathArgument};
    BOOL shouldExit = NO;

    gCommandLineOpenURLs = nil;
    gCommandLineControlAction = CommandLineControlAction::None;
    int result = ParseCommandLineArguments(2, directArguments, &shouldExit);
    if (result != 0 || shouldExit || gCommandLineOpenURLs.count != 1) {
        fprintf(stderr, "command-line direct file parse failed\n");
        return 1;
    }

    const char *openArguments[] = {program, "-o", pathArgument};
    gCommandLineOpenURLs = nil;
    gCommandLineControlAction = CommandLineControlAction::None;
    shouldExit = NO;
    result = ParseCommandLineArguments(3, openArguments, &shouldExit);
    if (result != 0 || shouldExit || gCommandLineOpenURLs.count != 1) {
        fprintf(stderr, "command-line -o file parse failed\n");
        return 1;
    }

    fprintf(stderr, "command-line open parse smoke test passed\n");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--smoke-launchservices") == 0) {
            return RunLaunchServicesSmokeTest();
        }
        if (argc == 3 && strcmp(argv[1], "--smoke-live-render") == 0) {
            return RunLiveRenderSmokeTest([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc == 3 && strcmp(argv[1], "--smoke-direct-render") == 0) {
            return RunDirectRenderSmokeTest([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc == 3 && strcmp(argv[1], "--smoke-seek") == 0) {
            return RunSeekSmokeTest([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc == 3 && strcmp(argv[1], "--smoke-info-panels") == 0) {
            return RunInfoPanelSmokeTest([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc == 3 && strcmp(argv[1], "--smoke-bpm") == 0) {
            return RunBPMSmokeTest([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc == 3 && strcmp(argv[1], "--smoke-cli-open") == 0) {
            return RunCommandLineOpenParseSmokeTest([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc >= 2) {
            NSString *firstArgument = CommandLineString(argv[1]);
            if (CommandLineArgMatches(firstArgument, @[@"-wav", @"-wave"])) {
                return RunCommandLineWaveSave(argc, argv);
            }
        }

        BOOL shouldExit = NO;
        const int parseResult = ParseCommandLineArguments(argc, argv, &shouldExit);
        if (shouldExit) {
            return parseResult;
        }

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
