;===================================================================================================
;Program:    SNES Digital Signal Processor (DSP) Emulator
;Platform:   Intel 80386
;Programmer: Anti Resonance (Alpha-II Productions), sunburst (degrade-factory)
;
;"SNES" and "Super Nintendo Entertainment System" are trademarks of Nintendo Co., Limited and its
;subsidiary companies.
;
;This program is free software; you can redistribute it and/or modify it under the terms of the
;GNU General Public License as published by the Free Software Foundation; either version 2 of
;the License, or (at your option) any later version.
;
;This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
;without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;See the GNU General Public License for more details.
;
;You should have received a copy of the GNU General Public License along with this program;
;if not, write to the Free Software Foundation, Inc.
;59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
;
;                                                   Copyright (C) 1999-2006 Alpha-II Productions
;                                                   Copyright (C) 2003-2025 degrade-factory
;
;List of users and dates who/when modified this file:
;   - degrade-factory in 2025-05-31
;   - Zenith in 2024-06-19
;===================================================================================================

%ifidn __OUTPUT_FORMAT__,macho64
CPU     X64
BITS    64
DEFAULT REL
%elifidn __OUTPUT_FORMAT__,elf64
CPU     X64
BITS    64
DEFAULT REL
%elifidn __OUTPUT_FORMAT__,win64
CPU     X64
BITS    64
DEFAULT REL
%else
CPU     386
BITS    32
%endif

;===================================================================================================
;Header files

%include "macro.inc"
%include "SNESAPU.inc"
%include "SPC700.inc"
%include "APU.inc"
%define INTERNAL
%include "DSP.inc"

GLOBAL  pOutBuf
GLOBAL  outLeft
GLOBAL  outCnt
GLOBAL  outDec
GLOBAL  brrTab
GLOBAL  mixBuf
GLOBAL  dspMix
GLOBAL  dspChn
GLOBAL  dspSize
GLOBAL  dspOpts
GLOBAL  nowMainL
GLOBAL  nowMainR
GLOBAL  nowEchoL
GLOBAL  nowEchoR
GLOBAL  pInter
GLOBAL  pDecomp
GLOBAL  dspInter
GLOBAL  voiceMix
GLOBAL  dspMute
GLOBAL  disFlag
GLOBAL  dspPMod
GLOBAL  dspNoise
GLOBAL  dspNoiseF
GLOBAL  konRsv
GLOBAL  koffRsv
GLOBAL  konRun
GLOBAL  dbgDecompCount
GLOBAL  dbgDecompHdr
GLOBAL  dbgDecompSP1
GLOBAL  dbgDecompSP2
GLOBAL  dbgDecompBuf0
GLOBAL  dbgDecompBuf1
GLOBAL  dbgDecompBuf2
GLOBAL  dbgDecompBuf3
GLOBAL  dbgUnpckHdr
GLOBAL  dbgUnpckByte0
GLOBAL  dbgUnpckByte1
GLOBAL  dbgUnpckIdx0
GLOBAL  dbgUnpckOut0
GLOBAL  dbgUnpckOut1
GLOBAL  dbgRKOnCount
GLOBAL  dbgRKOnBL
GLOBAL  dbgRKOnPreAL
GLOBAL  dbgRKOnPostAL
GLOBAL  dbgDSPInBKonCount
GLOBAL  dbgDSPInBKonBL
GLOBAL  dbgDSPInBKonAL
GLOBAL  dspRate
GLOBAL  firCur
GLOBAL  firRate
GLOBAL  firTaps
GLOBAL  echoLenD
GLOBAL  echoMaxD
GLOBAL  echoCurD
GLOBAL  echoLenM
GLOBAL  echoMaxM
GLOBAL  echoCurM
GLOBAL  echoDecM
GLOBAL  echoFB
GLOBAL  echoFBCT
GLOBAL  echoBuf
GLOBAL  firBuf


;===================================================================================================
;Equates

    ;Envelope mode masks ------------------------
    E_TYPE      EQU 00001b                                                      ;Type of adj: Constant(1/64 or 1/256) / Exp.(255/256)
    E_DIR       EQU 00010b                                                      ;Direction: Decrease / Increase
    E_DEST      EQU 00100b                                                      ;Destination: Default(0 or 1) / Other(x/8 or .75)
    E_ADSR      EQU 01000b                                                      ;Envelope mode: Gain/ADSR
    E_IDLE      EQU 80h                                                         ;Envelope speed is set to 0
    E_DEC       EQU 00000b                                                      ;Linear decrease
    E_EXP       EQU 00001b                                                      ;Exponential decrease
    E_INC       EQU 00010b                                                      ;Linear increase
    E_BENT      EQU 00110b                                                      ;Bent line increase
    E_DIRECT    EQU 00111b                                                      ;Direct gain
    E_ATT       EQU 01010b                                                      ;Attack mode
    E_DECAY     EQU 01101b                                                      ;Decay mode
    E_SUST      EQU 01001b                                                      ;Sustain mode
    E_REL       EQU 01000b                                                      ;Release mode

    ;Envelope precision -------------------------
    E_SHIFT     EQU 4                                                           ;Amount to shift envelope to get 8-bit signed value

    ;Envelope adjustment rates ------------------
    A_GAIN      EQU (1 << E_SHIFT)                                              ;Amount to adjust envelope values
    A_LIN       EQU (128*A_GAIN)/64                                             ;Linear rate to increase/decrease envelope
    A_KOFF      EQU (128*A_GAIN)/256                                            ;Rate to decrease envelope during release
    A_BENT      EQU (128*A_GAIN)/256                                            ;Rate to increase envelope after bend
    A_NOATT     EQU (128*A_GAIN)-1                                              ;Rate to increase if attack rate is set to 0ms
    A_DIRECT    EQU (128*A_GAIN)-1                                              ;Rate to increase/decrease if envelope is set directly
    A_EXP       EQU 0                                                           ;Rate to decrease envelope exponentially (Not used)

    ;Envelope destination values ----------------
    D_MAX       EQU (128*A_GAIN)-1                                              ;Maximum envelope value
    D_BENT      EQU (128*A_GAIN*3)/4                                            ;First destination of bent line
    D_EXP       EQU (128*A_GAIN)/8                                              ;Minimum decay destination value
    D_MIN       EQU 0                                                           ;Minimum envelope value

    ;Array sizes --------------------------------
    MIX_SIZE    EQU 1024                                                        ;Size of mixing buffer in samples
    FIRBUF      EQU 2*2*64                                                      ;Stereo * Ring loop * 256kHz / 32kHz
    ECHOBUF     EQU 2*((192000*240)/1000)                                       ;Size of echo buffer (stereo * 192kHz * 240ms)
    LOWBUF1     EQU 384                                                         ;Size of BASS-BOOST buffer (base 192kHz)
    LOWBUF2     EQU 1152
    LOWLEN1     EQU LOWBUF1*2+LOWBUF2*2                                         ;Total size of BASS-BOOST buffer (without lowSize, lowLv)
    LOWLEN2     EQU 10


;===================================================================================================
;Structures



;===================================================================================================
;Data

%ifndef WIN32
SECTION .data ALIGN=256
%else
SECTION .data ALIGN=32
%endif

                ;12-bit Gaussian curve generated by SNES DSP
    gaussTab    DW      0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0 ;s0
                DW     16,   16,   16,   16,   16,   16,   16,   16,   16,   16,   16,   32,   32,   32,   32,   32
                DW     32,   32,   48,   48,   48,   48,   48,   64,   64,   64,   64,   64,   80,   80,   80,   80
                DW     96,   96,   96,   96,  112,  112,  112,  128,  128,  128,  144,  144,  144,  160,  160,  160
                DW    176,  176,  176,  192,  192,  208,  208,  224,  224,  240,  240,  240,  256,  256,  272,  272
                DW    288,  304,  304,  320,  320,  336,  336,  352,  368,  368,  384,  384,  400,  416,  432,  432
                DW    448,  464,  464,  480,  496,  512,  512,  528,  544,  560,  576,  576,  592,  608,  624,  640
                DW    656,  672,  688,  704,  720,  736,  752,  768,  784,  800,  816,  832,  848,  864,  880,  896
                DW    928,  944,  960,  976,  992, 1024, 1040, 1056, 1072, 1104, 1120, 1136, 1168, 1184, 1216, 1232
                DW   1248, 1280, 1296, 1328, 1344, 1376, 1392, 1424, 1440, 1472, 1504, 1520, 1552, 1584, 1600, 1632
                DW   1664, 1696, 1712, 1744, 1776, 1808, 1840, 1872, 1888, 1920, 1952, 1984, 2016, 2048, 2080, 2112
                DW   2144, 2192, 2224, 2256, 2288, 2320, 2352, 2400, 2432, 2464, 2496, 2544, 2576, 2608, 2656, 2688
                DW   2736, 2768, 2800, 2848, 2880, 2928, 2976, 3008, 3056, 3088, 3136, 3184, 3216, 3264, 3312, 3360
                DW   3392, 3440, 3488, 3536, 3584, 3632, 3680, 3728, 3776, 3824, 3872, 3920, 3968, 4016, 4064, 4112
                DW   4160, 4208, 4272, 4320, 4368, 4416, 4480, 4528, 4576, 4640, 4688, 4752, 4800, 4864, 4912, 4976
                DW   5024, 5088, 5136, 5200, 5248, 5312, 5376, 5424, 5488, 5552, 5616, 5664, 5728, 5792, 5856, 5920 ;e0
                DW   5984, 6048, 6096, 6160, 6224, 6288, 6352, 6416, 6480, 6560, 6624, 6688, 6752, 6816, 6880, 6944 ;s1
                DW   7024, 7088, 7152, 7216, 7296, 7360, 7424, 7504, 7568, 7632, 7712, 7776, 7856, 7920, 7984, 8064
                DW   8128, 8208, 8272, 8352, 8432, 8496, 8576, 8640, 8720, 8800, 8864, 8944, 9008, 9088, 9168, 9232
                DW   9312, 9392, 9472, 9536, 9616, 9696, 9776, 9840, 9920,10000,10080,10160,10240,10304,10384,10464
                DW  10544,10624,10704,10784,10848,10928,11008,11088,11168,11248,11328,11408,11488,11568,11648,11712
                DW  11792,11872,11952,12032,12112,12192,12272,12352,12432,12512,12592,12672,12752,12832,12896,12976
                DW  13056,13136,13216,13296,13376,13456,13536,13616,13680,13760,13840,13920,14000,14080,14144,14224
                DW  14304,14384,14464,14528,14608,14688,14768,14832,14912,14992,15056,15136,15216,15280,15360,15440
                DW  15504,15584,15648,15728,15808,15872,15952,16016,16080,16160,16224,16304,16368,16432,16512,16576
                DW  16640,16720,16784,16848,16912,16976,17056,17120,17184,17248,17312,17376,17440,17504,17568,17632
                DW  17696,17744,17808,17872,17936,18000,18048,18112,18176,18224,18288,18336,18400,18448,18512,18560
                DW  18624,18672,18720,18784,18832,18880,18928,18976,19040,19088,19136,19184,19232,19280,19312,19360
                DW  19408,19456,19504,19536,19584,19632,19664,19712,19744,19792,19824,19856,19904,19936,19968,20016
                DW  20048,20080,20112,20144,20176,20208,20240,20272,20304,20320,20352,20384,20400,20432,20464,20480
                DW  20512,20528,20544,20576,20592,20608,20640,20656,20672,20688,20704,20720,20736,20752,20752,20768
                DW  20784,20800,20800,20816,20832,20832,20848,20848,20848,20864,20864,20864,20864,20864,20880,20880 ;e1
                DW  20880,20880,20864,20864,20864,20864,20864,20848,20848,20848,20832,20832,20816,20800,20800,20784 ;s2
                DW  20768,20752,20752,20736,20720,20704,20688,20672,20656,20640,20608,20592,20576,20544,20528,20512
                DW  20480,20464,20432,20400,20384,20352,20320,20304,20272,20240,20208,20176,20144,20112,20080,20048
                DW  20016,19968,19936,19904,19856,19824,19792,19744,19712,19664,19632,19584,19536,19504,19456,19408
                DW  19360,19312,19280,19232,19184,19136,19088,19040,18976,18928,18880,18832,18784,18720,18672,18624
                DW  18560,18512,18448,18400,18336,18288,18224,18176,18112,18048,18000,17936,17872,17808,17744,17696
                DW  17632,17568,17504,17440,17376,17312,17248,17184,17120,17056,16976,16912,16848,16784,16720,16640
                DW  16576,16512,16432,16368,16304,16224,16160,16080,16016,15952,15872,15808,15728,15648,15584,15504
                DW  15440,15360,15280,15216,15136,15056,14992,14912,14832,14768,14688,14608,14528,14464,14384,14304
                DW  14224,14144,14080,14000,13920,13840,13760,13680,13616,13536,13456,13376,13296,13216,13136,13056
                DW  12976,12896,12832,12752,12672,12592,12512,12432,12352,12272,12192,12112,12032,11952,11872,11792
                DW  11712,11648,11568,11488,11408,11328,11248,11168,11088,11008,10928,10848,10784,10704,10624,10544
                DW  10464,10384,10304,10240,10160,10080,10000, 9920, 9840, 9776, 9696, 9616, 9536, 9472, 9392, 9312
                DW   9232, 9168, 9088, 9008, 8944, 8864, 8800, 8720, 8640, 8576, 8496, 8432, 8352, 8272, 8208, 8128
                DW   8064, 7984, 7920, 7856, 7776, 7712, 7632, 7568, 7504, 7424, 7360, 7296, 7216, 7152, 7088, 7024
                DW   6944, 6880, 6816, 6752, 6688, 6624, 6560, 6480, 6416, 6352, 6288, 6224, 6160, 6096, 6048, 5984 ;e2
                DW   5920, 5856, 5792, 5728, 5664, 5616, 5552, 5488, 5424, 5376, 5312, 5248, 5200, 5136, 5088, 5024 ;s3
                DW   4976, 4912, 4864, 4800, 4752, 4688, 4640, 4576, 4528, 4480, 4416, 4368, 4320, 4272, 4208, 4160
                DW   4112, 4064, 4016, 3968, 3920, 3872, 3824, 3776, 3728, 3680, 3632, 3584, 3536, 3488, 3440, 3392
                DW   3360, 3312, 3264, 3216, 3184, 3136, 3088, 3056, 3008, 2976, 2928, 2880, 2848, 2800, 2768, 2736
                DW   2688, 2656, 2608, 2576, 2544, 2496, 2464, 2432, 2400, 2352, 2320, 2288, 2256, 2224, 2192, 2144
                DW   2112, 2080, 2048, 2016, 1984, 1952, 1920, 1888, 1872, 1840, 1808, 1776, 1744, 1712, 1696, 1664
                DW   1632, 1600, 1584, 1552, 1520, 1504, 1472, 1440, 1424, 1392, 1376, 1344, 1328, 1296, 1280, 1248
                DW   1232, 1216, 1184, 1168, 1136, 1120, 1104, 1072, 1056, 1040, 1024,  992,  976,  960,  944,  928
                DW    896,  880,  864,  848,  832,  816,  800,  784,  768,  752,  736,  720,  704,  688,  672,  656
                DW    640,  624,  608,  592,  576,  576,  560,  544,  528,  512,  512,  496,  480,  464,  464,  448
                DW    432,  432,  416,  400,  384,  384,  368,  368,  352,  336,  336,  320,  320,  304,  304,  288
                DW    272,  272,  256,  256,  240,  240,  240,  224,  224,  208,  208,  192,  192,  176,  176,  176
                DW    160,  160,  160,  144,  144,  144,  128,  128,  128,  112,  112,  112,   96,   96,   96,   96
                DW     80,   80,   80,   80,   64,   64,   64,   64,   64,   48,   48,   48,   48,   48,   32,   32
                DW     32,   32,   32,   32,   32,   16,   16,   16,   16,   16,   16,   16,   16,   16,   16,   16
                DW      0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0 ;e3

                ;Jump table for DSP register writes (see DSPIn)
%ifdef HOST64
    dspRegs     DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  RMVolL, REFB,   RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  RMVolR, RNull,  RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  REVolL, RPMOn,  RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  REVolR, RNull,  RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  RKOn,   RNull,  RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  RKOff,  RNull,  RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  RFlg,   REDl,   RNull,  RFCf
                DQ  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DQ  RNull,  RNull,  RNull,  RNull,  RNull,  REDl,   RNull,  RFCf
%else
    dspRegs     DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  RMVolL, REFB,   RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  RMVolR, RNull,  RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  REVolL, RPMOn,  RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  REVolR, RNull,  RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  RKOn,   RNull,  RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  RKOff,  RNull,  RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  RFlg,   REDl,   RNull,  RFCf
                DD  RVolL,  RVolR,  RPitch, RPitch, RNull,  RADSR,  RADSR,  RGain
                DD  RNull,  RNull,  RNull,  RNull,  RNull,  REDl,   RNull,  RFCf
%endif

                ;Pointers to interpolation functions for each mixing routine
%ifdef HOST64
    intRout     DQ  NoneInt,    LinearInt,  Point4Int,  Point4Int,  Point8Int,  Point4Int,  Point4Int,  Point4Int
%else
    intRout     DD  NoneInt,    LinearInt,  Point4Int,  Point4Int,  Point8Int,  Point4Int,  Point4Int,  Point4Int
%endif

                ;Pointers to interpolation table for each interpolation type
%ifdef HOST64
    tabRout     DQ  0,          0,          cubicTab,   gaussTab,   sincTab,    gauss4Tab,  gauss4Tab,  gauss4Tab
%else
    tabRout     DD  0,          0,          cubicTab,   gaussTab,   sincTab,    gauss4Tab,  gauss4Tab,  gauss4Tab
%endif

    ;Frequency table -------------------------
    freqTab     DD     0
                DD  2048, 1536, 1280                                            ;Number of samples between updates.  Used to determine
                DD  1024,  768,  640                                            ; envelope rates and noise frequencies
                DD   512,  384,  320
                DD   256,  192,  160
                DD   128,   96,   80
                DD    64,   48,   40
                DD    32,   24,   20
                DD    16,   12,   10
                DD     8,    6,    5
                DD     4,    3
                DD     2
                DD     1

    ;Floating point constants ----------------
    fn2_5       DD  -2.5                                                        ;Cubic interpolation
    fn1_5       DD  -1.5
    fn0_5       DD  -0.5
    fp0_5       DD  0.5
    fp1_5       DD  1.5

    fpA         DD  20534.298825777156115789949213172                           ;(sqrt(2 * pi) * 32768) / 4
    fp32km1     DD  32767.0                                                     ;Cubic interpolation
    fpMaxLv     DD  8589934592.0                                                ;(2 ^ 31) * 4
    fpLowRt     DD  192000.0                                                    ;BASS-BOOST base sampling rate
    fpLowLv1    DD  0.003                                                       ;BASS-BOOST level (base 192kHz)
    fpLowLv2    DD  0.003
    fpLowBs1    DD  0.002                                                       ;BASS-BOOST buffer size (base 192kHz) (=LOWBUF1/192000)
    fpLowBs2    DD  0.006                                                       ;                                     (=LOWBUF2/192000)
    fpAafCF1    DD  8038.1284389846                                             ;Anti-Alies 1st filter cut-off frequency
    fpAafCF2    DD  16176.421441299                                             ;Anti-Alies 2nd filter cut-off frequency

    Scale32 fp64k,16                                                            ;Various
    Scale32 fp32k,15                                                            ;Sinc interpolation
    Scale32 fp512,9                                                             ;Gaussian interpolation
    Scale32 fp256,8                                                             ;Number of points of interpolation between samples
    Scale32 fp128,7                                                             ;Stereo separation
    Scale32 fpShR1,-1                                                           ;Cubic interpolation
    Scale32 fpShR7,-7                                                           ;Voice volume
    Scale32 fpShR8,-8                                                           ;Main/Echo volume(7), 8 voices(3), Echo + Main(1)
    Scale32 fpShR10,-10                                                         ;Gaussian interpolation
    Scale32 fpShR15,-15                                                         ;Cubic interpolation
    Scale32 fpShR16,-16
    Scale32 fpShR19,-19                                                         ;Denormalized number check for echo feedback
    Scale32 fpShR23,-23                                                         ;EFBCT(16), EFB(7)
    Scale32 fpShR31,-31                                                         ;32bit-float (IEEE754) output
    Scale32 fpEShR,-(E_SHIFT+7)


;===================================================================================================
;Variables

%ifndef WIN32
SECTION .bss ALIGN=256
%else
SECTION .bss ALIGN=64

;The BSS must be aligned on at least a 256-byte boundary.  (If it's not, you'll know as soon as you
; play a song.)  This is tricky in Windows because the win32 object files can only specify 64-byte
; alignment.  Try padding with multiples of 64 until it works.

    resb    DSP_ALIGN                                                           ;Force page alignment

%endif

;Be careful when touching!  All arrays are carefully aligned on large boundaries to facillitate easier
; indexing and better cache utilization.

    ;DSP Core ---------------------------- [0]
    mix         resb    1024                                                    ;<VoiceMix> Mixing settings for each voice
    dsp         resb    128                                                     ;<DSPRAM> DSP registers

    ;Look-up Tables -------------------- [480]
    rateTab     resd    32                                                      ;Update Rate Table
    brrTab      resd    1024                                                    ;All possible range/nybble values for BRR
    cubicTab    resq    256                                                     ;Cubic interpolation
    sincTab     resq    512                                                     ;8-point Sinc interpolation with Hanning window
    gauss4Tab   resq    256                                                     ;4-point Gauss interpolation
    interTab    resq    512                                                     ;Interpolation Table

    ;Globals -------------------------- [4500]
%ifdef HOST64
    pTrace      resq    1                                                       ;-> Debugging vector
    pOutBuf     resq    1                                                       ;-> output buffer
%else
    pTrace      resd    1                                                       ;-> Debugging vector
    pOutBuf     resd    1                                                       ;-> output buffer
%endif
    outLeft     resd    1                                                       ;Number of samples left to fill output buffer
    outCnt      resd    1                                                       ;t64 count at last call to EmuDSP
    outDec      resd    1                                                       ;Fractional number of samples to be generated
                resd    3

    ;DSP Options ---------------------- [4520]
    dspMix      resb    1                                                       ;Mixing routine
    dspChn      resb    1                                                       ;Number of channels being output
    dspSize     resb    1                                                       ;Size of samples in bytes
                resb    1

    dspRate     resd    1                                                       ;Sample rate (max 32kHz in actual emulation mode)
    dspOpts     resd    1                                                       ;Option flags passed to SetDSPOpt
    pitchBas    resd    1                                                       ;Base sample rate
    pitchAdj    resd    1                                                       ;Amount to adjust pitch rates [16.16]
%ifdef HOST64
    pInter      resq    1                                                       ;-> interpolation function
    pDecomp     resq    1                                                       ;-> sample decompression routine
%else
    pInter      resd    1                                                       ;-> interpolation function
    pDecomp     resd    1                                                       ;-> sample decompression routine
%endif

    dspInter    resb    1                                                       ;Interpolation method
    voiceMix    resb    1                                                       ;Voices that are currently being mixed
    surround    resb    1                                                       ;Turn on surround sound  (OFF:0x00 / ON:0xFF)
    surroff     resb    1                                                       ;Turn off surround sound (OFF:0x00 / ON:0x80)

    ;Volume --------------------------- [4540]
    volSepar    resd    1                                                       ;Stereo separation
    volRamp1    resd    1                                                       ;Amount to ramp volume per sample
    volRamp2    resd    1                                                       ;Amount to ramp volume per sample
    volAmp      resd    1                                                       ;Amplification [16.16]
    volAtten    resd    1                                                       ;Global volume attenuation [1.16]
    volAdj      resd    1                                                       ;Amount to adjust main volumes [-15.16]
    volMainL    resd    1                                                       ;Main volumes
    volMainR    resd    1
    nowMainL    resd    1
    nowMainR    resd    1
    volEchoL    resd    1                                                       ;Echo volumes
    volEchoR    resd    1
    nowEchoL    resd    1
    nowEchoR    resd    1
    vMMaxL      resd    1                                                       ;Maximum absolute sample output
    vMMaxR      resd    1

    ;Noise ---------------------------- [4580]
    nRate       resd    1                                                       ;Noise sample rate reciprocal [.32]
    nfRate      resd    1
    nAcc        resd    1                                                       ;Noise accumulator [.32] (>= 1 generate a new sample)
    nfAcc       resd    1
    nSmp        resd    1                                                       ;Current Noise sample
    nfSmp       resd    1
    nSeed       resd    1                                                       ;Noise random seed
                resd    1

    ;Echo filtering ------------------- [45A0]
    firCur      resd    1                                                       ;Index of the first sample to feed into the filter
    firRate     resd    1                                                       ;Rate to feed samples into filter
                resd    2
    firTaps     resd    8                                                       ;Filter coefficents

    ;Echo ----------------------------- [45D0]
    echoLenD    resd    1                                                       ;Size of delay in echo area (in bytes)
    echoMaxD    resd    1                                                       ;Maximum position in echo area (in bytes)
    echoCurD    resd    1                                                       ;Writing position counter (in bytes)
                resd    1
    echoLenM    resd    1                                                       ;Size of delay in echo memory (in bytes)
    echoMaxM    resd    1                                                       ;Maximum position in echo memory (in bytes)
    echoCurM    resd    1                                                       ;Writing position counter (in bytes)
    echoDecM    resd    1                                                       ;Decimal counter

    efbct       resd    1                                                       ;User specified echo feedback crosstalk
    echoFB      resd    1                                                       ;Echo feedback
    echoFBCT    resd    1                                                       ;Echo feedback crosstalk
                resd    1

    ;Single source playback ----------- [4600]
    tBRR        resb    8                                                       ;Temporary buffer for storing BRR block
                resw    4                                                       ;Temporary buffer for single sound playback
    tBuf        resw    16
    tRate       resd    1
    tDec        resd    1
    tLoop       resd    1
    tBlk        resd    1
    tIdx        resd    1
    tP1         resd    1
    tP2         resd    1
                resd    1

    ;Emulation work ------------------- [4650]
    songLen     resd    1                                                       ;Length of song (in ticks)
    fadeLen     resd    1                                                       ;Length of fade (in ticks)
    outRate     resd    1                                                       ;Out sampling rate
    envCrt      resd    1                                                       ;Current envelope level
    envVal      resd    1                                                       ;MAX envelope level
    dspPMod     resb    1                                                       ;DSP pitch modulation flags
    dspNoise    resb    1                                                       ;DSP noise flags
    dspNoiseF   resb    1                                                       ;DSP noise flags (force)
    dspMute     resb    1                                                       ;DSP mute flags
    disFlag     resb    1                                                       ;DSP disabled channel flags (see EmuDSP)
    konRsv      resb    1                                                       ;Reserved KON flags
    koffRsv     resb    1                                                       ;Reserved KOFF flags
    konRun      resb    1                                                       ;Running KON process flags
    envFlag     resb    1                                                       ;DSP envelope flags
                                                                                ;   [1] - Suspended envelope by frontend
                                                                                ;   [5] - Suspended envelope by SetSPCDbg
                resb    3
                resd    4
    dbgDecompCount  resd    1
    dbgDecompHdr    resd    8
    dbgDecompSP1    resd    8
    dbgDecompSP2    resd    8
    dbgDecompBuf0   resd    8
    dbgDecompBuf1   resd    8
    dbgDecompBuf2   resd    8
    dbgDecompBuf3   resd    8
    dbgUnpckHdr     resd    1
    dbgUnpckByte0   resd    1
    dbgUnpckByte1   resd    1
    dbgUnpckIdx0    resd    1
    dbgUnpckOut0    resd    1
    dbgUnpckOut1    resd    1
    dbgRKOnCount    resd    1
    dbgRKOnBL       resd    1
    dbgRKOnPreAL    resd    1
    dbgRKOnPostAL   resd    1
    dbgDSPInBKonCount resd  1
    dbgDSPInBKonBL    resd  1
    dbgDSPInBKonAL    resd  1

    ;BASS BOOST ----------------------- [4680]
    lowRstL1    resd    1                                                       ;BASS-BOOST reset counter (Left)
    lowRstL2    resd    1
    lowRstR1    resd    1                                                       ;BASS-BOOST reset counter (Right)
    lowRstR2    resd    1
    lowSumL1    resd    1                                                       ;BASS-BOOST sum (Left)
    lowSumL2    resd    1
    lowSumR1    resd    1                                                       ;BASS-BOOST sum (Right)
    lowSumR2    resd    1
    lowCnt1     resd    1                                                       ;BASS-BOOST index counter
    lowCnt2     resd    1
    lowSize1    resd    1                                                       ;BASS-BOOST buffer size
    lowSize2    resd    1
    lowLv1      resd    1                                                       ;BASS-BOOST level
    lowLv2      resd    1
                resd    2

    ;Anti-Alies filter ---------------- [46C0]
    aaf1A1      resd    1                                                       ;Anti-Alies 1st filter coefficients
    aaf1B0      resd    1
    aaf1B1      resd    1
    aaf2A1      resd    1                                                       ;Anti-Alies 2nd filter coefficients
    aaf2B0      resd    1
    aaf2B1      resd    1
    aafBufL     resd    3                                                       ;Anti-Alies filter buffer (Left)
    aafBufR     resd    3                                                       ;Anti-Alies filter buffer (Right)

    ;ADSR/Gain ------------------------ [46F0]
    adsrAdj     resd    1                                                       ;Update envelope rate adjustment (16.16)
    adsrClk     resw    1                                                       ;Update envelope rate clock
    adsrCnt     resw    1                                                       ;Number of times to update envelope
    adsrUpd     resb    1                                                       ;Number of updates executed by UpdateEnv
                resb    3
                resd    1

    ;Sampling rate converter ---------- [4700]
    smpBuf      resd    8                                                       ;Sample history buffer
    smpRate     resd    1                                                       ;Sample rate (max 192kHz)
    smpAdj      resd    1                                                       ;Sample rate adjustment
    smpDec      resd    1                                                       ;Sample rate (decimal)
    smpCur      resd    1                                                       ;Ratio between samples
    smpCnt      resd    1                                                       ;Ratio adjustment rate counter
    smpDen      resd    1                                                       ;Ratio adjustment reset timing
    smpRst      resd    1                                                       ;Ratio adjustment reset counter
                resd    1

    ;Storage buffers ------------------ [4740]
    mixBuf      resd    MIX_SIZE*4                                              ;Temporary mixing buffer (linear buffer)
    echoBuf     resd    ECHOBUF                                                 ;External echo memory, 240ms @ 192kHz (ring buffer)
    firBuf      resd    FIRBUF                                                  ;Unaltered echo samples fed into FIR filter (ring buffer)
                resw    FIRBUF                                                  ;   Triple buffer
    lowBufL1    resd    LOWBUF1                                                 ;BASS-BOOST buffer (Left)
    lowBufL2    resd    LOWBUF2
    lowBufR1    resd    LOWBUF1                                                 ;BASS-BOOST buffer (Right)
    lowBufR2    resd    LOWBUF2

    dspVarEP    resd    1                                                       ;Endpoint of DSP.asm variables


;===================================================================================================
;Code

%ifndef WIN32
SECTION .text ALIGN=256
%else
SECTION .text ALIGN=16
%endif


;===================================================================================================
;Calculate Power of e
;
;Desc:
;   Calculates e to the power of x by using the formula:
;
;    2^(x * log2(e))
;
;   Where 2^x is calculated by:
;
;    2^int(x) * 2^frac(x)
;
;In:
;   ST = x
;
;Out:
;   ST = e^x

PROC Exp
LOCALS fpuCWCur, fpuCWTrunc

    FStCW   [fpuCWCur]                                                          ;Save control state
    FStCW   [fpuCWTrunc]                                                        ;Set FPU to truncate when rounding
    Or      byte [fpuCWTrunc+1],1100b
    FLdCW   [fpuCWTrunc]

    FLdL2e                                                                      ;                                   |x Log2(e)
    FMulP   ST1,ST                                                              ;                                   |x*Log2(e)

    FLd     ST                                                                  ;                                   |ex ex
    FRndInt                                                                     ;Get the integer portion            |ex floor(ex)

    FXch    ST1                                                                 ;                                   |iex ex
    FSub    ST,ST1                                                              ;Get the fractional portion         |iex ex-iex

    F2XM1                                                                       ;Compute 2^frac                     |iex pow(2,fex)-1
    FLd1                                                                        ;                                   |iex p 1
    FAddP   ST1,ST                                                              ;                                   |iex p+1

    FXch                                                                        ;Compute 2^int                      |f iex
    FLd1                                                                        ;                                   |f iex 1
    FScale                                                                      ;                                   |f iex 1<<iex
    FStp    ST1                                                                 ;                                   |f i

    FMulP   ST1,ST                                                              ;                                   |f*i

    FLdCW   [fpuCWCur]                                                          ;Restore control state

ENDP


;===================================================================================================
;Initialize DSP

PROC InitDSP
LOCALS ipD                                                                      ;Integer, positive, delta
USES ECX,EDX,EBX,ESI,EDI

    Mov     dword [apuDbgStage],200h
    XOr     EAX,EAX                                                             ;Reset values so SetDSPOpt will create new ones
    Mov     [dspOpts],EAX
    Mov     [volSepar],EAX

    Dec     EAX
    Mov     [dspMix],AL
    Mov     [dspChn],AL
    Mov     [dspSize],AL
    Mov     [dspInter],AL
    Mov     [dspRate],EAX
    Mov     [smpRate],EAX

    Mov     EAX,10000h
    Mov     [efbct],EAX
    Mov     [volAmp],EAX
    Mov     [volAtten],EAX
    Mov     [volAdj],EAX

    Mov     dword [pitchBas],32000
    Mov     EAX,5Fh                                                             ;Always envelope is 75% when DSP_NOENV is enabled
    ShL     EAX,E_SHIFT
    Mov     [envVal],EAX

%ifdef HOST64
    Lea     RDI,[rel mix]
%else
    Mov     EDI,mix                                                             ;Erase all mixer settings
%endif
    XOr     EAX,EAX
    Mov     ECX,256
    Rep     StoSD

    ;Build a look-up table for all possible expanded values in a BRR block.
%ifdef HOST64
    Lea     RDI,[rel brrTab]
%else
    Mov     EDI,brrTab
%endif
    XOr     EBX,EBX                                                             ;EBX = Nybble to shift right by range
    Mov     CL,28                                                               ;ECX = Max range (+16 for 32-bit numbers)

    .Range:
        .Nybble:
            Mov     EAX,EBX                                                     ;EAX = Nybble >> Range
            SAR     EAX,CL
            And     EAX,~1                                                      ;All numbers used by DSP are even
%ifdef HOST64
            Mov     [RDI],EAX
            Add     RDI,4
%else
            Mov     [EDI],EAX
            Add     EDI,4
%endif

        Add     EBX,10000000h                                                   ;Add 1 to uppermost nybble
        JNZ     short .Nybble

%ifdef HOST64
        Add     RDI,0C0h
%else
        Add     EDI,0C0h
%endif

    Dec     CL
    Cmp     CL,15
    JA      short .Range

    Mov     BL,3
    XOr     ECX,ECX

    .Invalid:
        XOr     EAX,EAX                                                         ;Positive nybbles turn into 0 when range > 12
        Mov     CL,8
        Rep     StoSD

        Mov     EAX,-4096                                                       ;Negative nybbles turn into -4096 when range > 12
        Mov     CL,8
        Rep     StoSD

%ifdef HOST64
        Add     RDI,0C0h
%else
        Add     EDI,0C0h
%endif

    Dec     BL
    JNZ     short .Invalid
    Mov     dword [apuDbgStage],201h

    ;Build a look-up table to calculate a cubic spline with only four integer multiplies.
    ;The table is built from the following equation, simplified for s:
    ;
    ; y = ax^3 + bx^2 + cx + d
    ;
    ;     3 (s[0] - s[1]) - s[-1] + s[2]
    ; a = ------------------------------
    ;                   2
    ;
    ;                      5 s[0] + s[2]
    ; b = 2 s[1] + s[-1] - -------------
    ;                            2
    ;
    ;     s[1] - s[-1]
    ; c = ------------
    ;          2
    ;
    ; d = s[0]
    ;
    ;y is the return sample
    ;x is the delta from current sample
    ;s is a four sample array with [0] being the current sample

    FInit                                                                       ;Reset FPU, otherwise there'll be problems
    Mov     dword [ipD],0                                                       ;Start with a delta of 0 (calculate 256 points)

%ifdef HOST64
    Lea     RDI,[rel cubicTab]
%else
    Mov     EDI,cubicTab                                                        ;EDI->Cubic array                   |FPU Stack after execution
%endif
    .NextC:
        ;x1=(n/256)  x2=(n/256)^2  x3=(n/256)^3
        FILd    dword [ipD]                                                     ;Load (int) delta                   |D
        FMul    dword [fpShR8]                                                  ;Divide delta by 256                |D/256=X1
        FLd     ST                                                              ;Copy top of stack                  |X1 X1
        FMul    ST,ST1                                                          ;Square point                       |X1 X1*X1=X2
        FLd     ST                                                              ;                                   |X1 X2 X2
        FMul    ST,ST2                                                          ;Cube point                         |X1 X2 X2*X1=X3

        ;s[-1] *= -.5(x^3) + (x^2) - .5x ------
        FLd     dword [fn0_5]                                                   ;                                   |X1 X2 X3 -0.5
        FMul    ST,ST3                                                          ;                                   |X1 X2 X3 -0.5*X1=T1
        FAdd    ST,ST2                                                          ;                                   |X1 X2 X3 T1+X2
        FLd     dword [fn0_5]                                                   ;                                   |X1 X2 X3 T1 -0.5
        FMul    ST,ST2                                                          ;                                   |X1 X2 X3 T1 -0.5*X3=T2
        FAddP   ST1,ST                                                          ;                                   |X1 X2 X3 T1+T2
        FMul    dword [fp32km1]                                                 ;Convert to fixed point (-.15)      |X1 X2 X3 (T1+T2)*32767
%ifdef HOST64
        FIStP   word [RDI]                                                      ;Store value in cubicTab            |X1 X2 X3
%else
        FIStP   word [EDI]                                                      ;Store value in cubicTab            |X1 X2 X3
%endif

        ;s[0] *= 1.5(x^3) - 2.5(x^2) + 1 ------
        FLd     dword [fn2_5]                                                   ;                                   |X1 X2 X3 -2.5
        FMul    ST,ST2                                                          ;                                   |X1 X2 X3 -2.5*X2=T1
        FLd     dword [fp1_5]                                                   ;                                   |X1 X2 X3 T1 1.5
        FMul    ST,ST2                                                          ;                                   |X1 X2 X3 T1 1.5*X3=T2
        FLd1                                                                    ;                                   |X1 X2 X3 T1 T2 1.0
        FAddP   ST1,ST                                                          ;                                   |X1 X2 X3 T1 T2+1
        FAddP   ST1,ST                                                          ;                                   |X1 X2 X3 T1+T2
        FMul    dword [fp32km1]                                                 ;                                   |X1 X2 X3 (T1+T2)*32767
%ifdef HOST64
        FIStP   word [RDI+2]                                                    ;                                   |X1 X2 X3
%else
        FIStP   word [2+EDI]                                                    ;                                   |X1 X2 X3
%endif

        ;s[1] *= -1.5(x^3) + 2(x^2) + .5x -----
        FLd     dword [fp0_5]                                                   ;                                   |X1 X2 X3 0.5
        FMul    ST,ST3                                                          ;                                   |X1 X2 X3 0.5*X1=T1
        FLd     ST2                                                             ;                                   |X1 X2 X3 T1 X2
        FAdd    ST,ST3                                                          ;                                   |X1 X2 X3 T1 X2+X2=T2
        FLd     dword [fn1_5]                                                   ;                                   |X1 X2 X3 T1 T2 -1.5
        FMul    ST,ST3                                                          ;                                   |X1 X2 X3 T1 T2 -1.5*X3=T3
        FAddP   ST1,ST                                                          ;                                   |X1 X2 X3 T1 T2+T3
        FAddP   ST1,ST                                                          ;                                   |X1 X2 X3 T1+T2
        FMul    dword [fp32km1]                                                 ;                                   |X1 X2 X3 (T1+T2)*32767
%ifdef HOST64
        FIStP   word [RDI+4]                                                    ;                                   |X1 X2 X3
%else
        FIStP   word [4+EDI]                                                    ;                                   |X1 X2 X3
%endif

        ;s[2] *= .5(x^3) - .5(x^2) ------------
        FLd     dword [fn0_5]                                                   ;                                   |X1 X2 X3 -0.5
        FMul    ST,ST2                                                          ;                                   |X1 X2 X3 -0.5*X2=T1
        FLd     dword [fp0_5]                                                   ;                                   |X1 X2 X3 T1 0.5
        FMul    ST,ST2                                                          ;                                   |X1 X2 X3 T1 0.5*X3=T2
        FAddP   ST1,ST                                                          ;                                   |X1 X2 X3 T1+T2
        FMul    dword [fp32km1]                                                 ;                                   |X1 X2 X3 (T1+T2)*32767
%ifdef HOST64
        FIStP   word [RDI+6]                                                    ;                                   |X1 X2 X3
        Add     RDI,8
%else
        FIStP   word [6+EDI]                                                    ;                                   |X1 X2 X3
        Add     EDI,8
%endif

        FStP    ST                                                              ;Pop X's off stack                  |X1 X2
        FStP    ST                                                              ;                                   |X1
        FStP    ST                                                              ;                                   |(empty)

    Inc     byte [ipD]
    JNZ     .NextC
    Mov     dword [apuDbgStage],202h

    ;Interleave Gaussian table ---------------
%ifdef HOST64
    Lea     RSI,[rel gaussTab]
    Lea     RDI,[rel mixBuf]
%else
    Mov     ESI,gaussTab
    Mov     EDI,mixBuf
%endif
    Mov     ECX,512
    Rep     MovSD
%ifdef HOST64
    Lea     RSI,[rel mixBuf]
    Lea     RDI,[rel gaussTab]
%else
    Mov     ESI,mixBuf
    Mov     EDI,gaussTab
%endif

    XOr     CL,CL
    .NextG:
%ifdef HOST64
        Mov     AX,[RSI]
        Mov     [RDI+6],AX
        Mov     AX,[RSI+512]
        Mov     [RDI+4],AX
        Mov     AX,[RSI+1024]
        Mov     [RDI+2],AX
        Mov     AX,[RSI+1536]
        Mov     [RDI+0],AX
        Add     RDI,8
        Add     RSI,2
%else
        Mov     AX,[ESI]
        Mov     [6+EDI],AX
        Mov     AX,[512+ESI]
        Mov     [4+EDI],AX
        Mov     AX,[1024+ESI]
        Mov     [2+EDI],AX
        Mov     AX,[1536+ESI]
        Mov     [0+EDI],AX
        Add     EDI,8
        Add     ESI,2
%endif

    Dec     CL
    JNZ     short .NextG
    Mov     dword [apuDbgStage],203h

    ;Build a look-up table for 8-point sinc interpolation with a Hanning window.
    ;
    ;  sin(4pi x)
    ;  ---------- * (0.5 + 0.5cos(pi x))
    ;    4pi x
    ;

    ;If ipD were initialized to -768 (-3.0), a divide by zero error would occur when building the table.
    ;So we manually initialize the first row, which is easy to do.

%ifdef HOST64
    Lea     RDI,[rel sincTab]
%else
    Mov     EDI,sincTab
%endif
    XOr     EAX,EAX
%ifdef HOST64
    Mov     [RDI],EAX
    Mov     [RDI+4],EAX
    Mov     [RDI+8],EAX
    Mov     [RDI+12],EAX
    Mov     word [RDI+6],32767                                                  ;Set first row to 0 0 0 1 0 0 0 0
    Add     RDI,16
%else
    Mov     [EDI],EAX
    Mov     [4+EDI],EAX
    Mov     [8+EDI],EAX
    Mov     [12+EDI],EAX
    Mov     word [6+EDI],32767                                                  ;Set first row to 0 0 0 1 0 0 0 0
    Add     EDI,16
%endif
    Mov     dword [ipD],-769                                                    ;Fill remaining rows -769 to -1023 (-3.004 to -3.996)

    Mov     CH,255
    .NextS:
        Mov     CL,8
        .NextSS:
            FILd    dword [ipD]                                                 ;                                   |x
            FMul    dword [fpShR8]                                              ;(x >> 10) * 4pi                    |x>>8
            FLdPi                                                               ;                                   |x pi
            FMulP   ST1,ST                                                      ;                                   |x*pi
            FLd     ST                                                          ;                                   |x x

            FSin                                                                ;Sinc function                      |x sin(x)
            FDivRP  ST1,ST                                                      ;sin(x) / x                         |x/sin(x)

            FILd    dword [ipD]                                                 ;Hanning window                     |sinc x
            FMul    dword [fpShR10]                                             ;cos((x >> 10) * pi)                |sinc x>>10
            FLdPi                                                               ;                                   |sinc x pi
            FMulP   ST1,ST                                                      ;                                   |sinc x*pi
            FCos                                                                ;                                   |sinc cos(x*pi)
            FLd1                                                                ;(1.0 + cos) * 0.5                  |sinc cos 1.0
            FAddP   ST1,ST                                                      ;                                   |sinc cos+1.0
            FMul    dword [fp0_5]                                               ;                                   |sinc cos*0.5

            FMulP   ST1,ST                                                      ;Multiply by window                 |sinc*window
            FMul    dword [fp32k]                                               ;Convert to integer                 |sinc<<15
%ifdef HOST64
            FIStP   word [RDI]                                                  ;Store                              |(empty)
            Add     RDI,2
%else
            FIStP   word [EDI]                                                  ;Store                              |(empty)
            Add     EDI,2
%endif

        Add     dword [ipD],256                                                 ;Move to next point of interpolation (x += 256)
        Dec     CL
        JNZ     .NextSS

    Sub     dword [ipD],801h
    Dec     CH
    JNZ     .NextS
    Mov     dword [apuDbgStage],204h

    ;Build a look-up table for 4-point Gaussian interpolation.
    ;
    ;                                2
    ;       ____               (x/pi)
    ;     \| 2pi * (2^15)    - -------
    ; y = --------------- * e     2
    ;            4

    Mov     dword [ipD],-512
%ifdef HOST64
    Lea     RDI,[rel gauss4Tab]
%else
    Mov     EDI,gauss4Tab                                                       ;EDI->Gauss array                   |FPU Stack after execution
%endif
    FLd     dword [fpA]                                                         ;(sqrt(2 * pi) * 32768) / 4         |A = 20534.29882577715611578994921317
    FLd     dword [fp512]                                                       ;                                   |A 512
    FLdPi                                                                       ;                                   |A 512 3.14
    FDivP   ST1,ST                                                              ;                                   |A 512/3.14
    FLd     dword [fp256]                                                       ;Load 256 into FPU                  |A pi 256.0

    .NextG4:
        FILd    dword [ipD]                                                     ;Load (int) delta                   |A pi 256 x

        FLd     ST                                                              ;                                   |A pi 256 x x
        FDiv    ST,ST3                                                          ;                                   |A pi 256 x x/pi
        FMul    ST,ST                                                           ;                                   |A pi 256 x p^2
        FMul    dword [fpShR1]                                                  ;                                   |A pi 256 x p/2
        FChS                                                                    ;                                   |A pi 256 x -p
        Call    Exp                                                             ;                                   |A pi 256 x e^p
        FMul    ST,ST4                                                          ;                                   |A pi 256 x e*A
%ifdef HOST64
        FIStP   word [RDI+6]                                                    ;                                   |A pi 256 x
%else
        FIStP   word [6+EDI]                                                    ;                                   |A pi 256 x
%endif

        FAdd    ST,ST1                                                          ;                                   |A pi 256 x+256
        FLd     ST                                                              ;                                   |A pi 256 x x
        FDiv    ST,ST3                                                          ;                                   |A pi 256 x x/pi
        FMul    ST,ST                                                           ;                                   |A pi 256 x p^2
        FMul    dword [fpShR1]                                                  ;                                   |A pi 256 x p/2
        FChS                                                                    ;                                   |A pi 256 x -p
        Call    Exp                                                             ;                                   |A pi 256 x e^p
        FMul    ST,ST4                                                          ;                                   |A pi 256 x e*A
%ifdef HOST64
        FIStP   word [RDI+4]                                                    ;                                   |A pi 256 x
%else
        FIStP   word [4+EDI]                                                    ;                                   |A pi 256 x
%endif

        FAdd    ST,ST1                                                          ;                                   |A pi 256 x+256
        FLd     ST                                                              ;                                   |A pi 256 x x
        FDiv    ST,ST3                                                          ;                                   |A pi 256 x x/pi
        FMul    ST,ST                                                           ;                                   |A pi 256 x p^2
        FMul    dword [fpShR1]                                                  ;                                   |A pi 256 x p/2
        FChS                                                                    ;                                   |A pi 256 x -p
        Call    Exp                                                             ;                                   |A pi 256 x e^p
        FMul    ST,ST4                                                          ;                                   |A pi 256 x e*A
%ifdef HOST64
        FIStP   word [RDI+2]                                                    ;                                   |A pi 256 x
%else
        FIStP   word [2+EDI]                                                    ;                                   |A pi 256 x
%endif

        FAdd    ST,ST1                                                          ;                                   |A pi 256 x+256
        FDiv    ST,ST2                                                          ;                                   |A pi 256 x/pi
        FMul    ST,ST                                                           ;                                   |A pi 256 p^2
        FMul    dword [fpShR1]                                                  ;                                   |A pi 256 p/2
        FChS                                                                    ;                                   |A pi 256 -p
        Call    Exp                                                             ;                                   |A pi 256 e^p
        FMul    ST,ST3                                                          ;                                   |A pi 256 e*A
%ifdef HOST64
        FIStP   word [RDI]                                                      ;                                   |A pi 256
        Add     RDI,8
%else
        FIStP   word [EDI]                                                      ;                                   |A pi 256
        Add     EDI,8
%endif

    Inc     byte [ipD]
    JNZ     .NextG4

    FStP    ST                                                                  ;                                   |A pi
    FStP    ST                                                                  ;                                   |A
    FStP    ST                                                                  ;                                   |(empty)

    Mov     dword [apuDbgStage],205h
    Call    SetDSPOpt,1,2,16,32000,INT_GAUSS,0
    Mov     dword [apuDbgStage],206h
    Call    SetDSPDbg,0
    Mov     dword [apuDbgStage],20Fh

ENDP


;===================================================================================================
;Erase echo filter memory

PROC ResetEcho

    XOr     EAX,EAX

%ifdef HOST64
    Lea     RDI,[rel echoBuf]
%else
    Mov     EDI,echoBuf
%endif
    Mov     ECX,ECHOBUF
    Rep     StoSD

%ifdef HOST64
    Lea     RDI,[rel firBuf]
%else
    Mov     EDI,firBuf
%endif
    Mov     ECX,FIRBUF
    Add     ECX,FIRBUF/2
    Rep     StoSD

ENDP


;===================================================================================================
;Erase BASS-BOOST memory

PROC ResetLow

    XOr     EAX,EAX

%ifdef HOST64
    Lea     RDI,[rel lowBufL1]
%else
    Mov     EDI,lowBufL1
%endif
    Mov     ECX,LOWLEN1
    Rep     StoSD
%ifdef HOST64
    Lea     RDI,[rel lowRstL1]
%else
    Mov     EDI,lowRstL1
%endif
    Mov     ECX,LOWLEN2
    Rep     StoSD
    Inc     dword [lowRstL1]
    Inc     dword [lowRstL2]
    Inc     dword [lowRstR1]
    Inc     dword [lowRstR2]

%ifdef HOST64
    Lea     RDI,[rel aafBufL]
%else
    Mov     EDI,aafBufL
%endif
    Mov     ECX,6
    Rep     StoSD

ENDP


;===================================================================================================
;Erase sampling rate converter memory

PROC ResetResamp

    Mov     EAX,[smpDen]
    Mov     [smpRst],EAX

    XOr     EAX,EAX
    Mov     [smpCur],EAX
    Mov     [smpCnt],EAX

%ifdef HOST64
    Lea     RDI,[rel smpBuf]
%else
    Mov     EDI,smpBuf
%endif
    Mov     ECX,8
    Rep     StoSD

ENDP


;===================================================================================================
;Reset master and echo volume

PROC ResetVol

    Mov     EAX,[volMainL]
    Mov     [nowMainL],EAX
    Mov     EAX,[volMainR]
    Mov     [nowMainR],EAX
    Mov     EAX,[volEchoL]
    Mov     [nowEchoL],EAX
    Mov     EAX,[volEchoR]
    Mov     [nowEchoR],EAX

ENDP


;===================================================================================================
;Reset DSP Settings

PROC ResetDSP
USES ECX,EBX,EDI

    XOr     EAX,EAX

    ;Erase DSP Registers ---------------------
%ifdef HOST64
    Lea     RDI,[rel dsp]
%else
    Mov     EDI,dsp
%endif
    Mov     ECX,32
    Rep     StoSD
    Mov     byte [dsp+flg],0E0h                                                 ;Place DSP in power up mode

    ;Erase internal mixing settings ----------
    Mov     BH,8
%ifdef HOST64
    Lea     RDI,[rel mix]
%else
    Mov     EDI,mix
%endif

    .ClrMix:
%ifdef HOST64
        Mov     BL,[RDI+mFlg]
        And     BL,MFLG_USER                                                    ;Leave user voice flags (mute and noise)
        Or      BL,MFLG_OFF                                                     ;Set voice to inactive

        Mov     CL,32
        Rep     StoSD
        Mov     [RDI-80h+mFlg],BL
%else
        Mov     BL,[EDI+mFlg]
        And     BL,MFLG_USER                                                    ;Leave user voice flags (mute and noise)
        Or      BL,MFLG_OFF                                                     ;Set voice to inactive

        Mov     CL,32
        Rep     StoSD
        Mov     [EDI-80h+mFlg],BL
%endif

    Dec     BH
    JNZ     short .ClrMix

    ;Erase global volume settings ------------
    Mov     [volMainL],EAX
    Mov     [volMainR],EAX
    Mov     [volEchoL],EAX
    Mov     [volEchoR],EAX

    ;Erase noise settings --------------------
    Mov     [nRate],EAX
    Mov     [nAcc],EAX
    Mov     [nSmp],EAX
    Mov     dword [nSeed],1

    ;Erase echo settings --------------------
    Mov     [echoDecM],EAX                                                      ;Reset echo variables
    Mov     [echoFB],EAX
    Mov     [echoFBCT],EAX
    Mov     EAX,4
    Mov     [echoLenM],EAX                                                      ;Minimum value of echoLenM is 4byte (16-bit, stereo)
    Mov     [echoMaxM],EAX
    Mov     [echoCurM],EAX
    Add     EAX,EAX
    Mov     [echoLenD],EAX                                                      ;Minimum value of echoLenD is 8byte (32-bit, stereo)
    Mov     [echoMaxD],EAX
    Mov     [echoCurD],EAX

    Call    ResetVol
    Call    ResetEcho
    Call    ResetLow
    Call    ResetResamp

%ifdef HOST64
    Lea     RDI,[rel firTaps]                                                  ;Reset filter coefficients
%else
    Mov     EDI,firTaps                                                         ;Reset filter coefficients
%endif
    Mov     CL,8
    Rep     StoSD
    Mov     [firCur],EAX                                                        ;Reset filter variables

    ;Disable voices --------------------------
    Mov     [voiceMix],AL
    Mov     [vMMaxL],EAX
    Mov     [vMMaxR],EAX

    ;Reset times -----------------------------
    Mov     [outLeft],EAX
    Mov     [outCnt],EAX
    Mov     [outDec],EAX
    Mov     [dspPMod],EAX                                                       ;Clear dspPMod, dspNoise, dspNoiseF, dspMute
    Mov     [disFlag],EAX                                                       ;Clear disFlag, konRsv, koffRsv, konRun
    Mov     [dbgDecompCount],EAX
    Mov     [envFlag],EAX                                                       ;Clear envFlag
    Mov     [adsrClk],EAX                                                       ;Clear adsrClk, adsrCnt
    Mov     dword [songLen],-1
    Mov     dword [fadeLen],1

    ;Reset noise settings (user) ------
    Mov     [nfAcc],EAX
    Mov     [nfSmp],EAX
    Mov     EAX,-1
    Mov     EDX,65535
    Div     dword [31*4+rateTab]
    Mov     [nfRate],EAX

    ;Reset fade volume -----------------------
    Call    SetDSPVol,10000h

ENDP


;===================================================================================================
;Set DSP Options

PROC SetDSPOpt, mixType, numChn, bits, rate, inter, opts
LOCALS fixVol, tmpVal
USES ALL

    Mov     dword [apuDbgStage],300h
    XOr     EAX,EAX
    Mov     [fixVol],EAX

    ;=========================================
    ;Verify parameters

    ;mixType ---------------------------------
    MovZX   EAX,byte [dspMix]
    Mov     EDX,[mixType]
    Cmp     EDX,-1
    JE      short .DefMix
        XOr     EAX,EAX
        Test    EDX,EDX
        SetNZ   AL

    .DefMix:
    Mov     [mixType],EAX

    ;numChn ----------------------------------
    MovZX   EAX,byte [dspChn]
    Mov     EDX,[numChn]
    Cmp     EDX,-1
    JE      short .DefChn
        Mov     EAX,EDX

        Cmp     EDX,1
        JE      short .DefChn
        Cmp     EDX,2
        JE      short .DefChn
;       Cmp     EDX,4
;       JE      short .DefChn

        Mov     EAX,2

    .DefChn:
    Mov     [numChn],EAX

    ;bits ------------------------------------
    MovZX   EAX,byte [dspSize]
    Mov     EDX,[bits]
    Cmp     EDX,-1
    JE      short .DefBits
        Mov     EAX,EDX
        SAR     EAX,3

        Cmp     EDX,8
        JE      short .DefBits
        Cmp     EDX,16
        JE      short .DefBits
        Cmp     EDX,24
        JE      short .DefBits
        Cmp     EDX,32
        JE      short .DefBits
        Cmp     EDX,-32
        JE      short .DefBits

        Mov     EAX,2

    .DefBits:
    Mov     [bits],EAX

    ;rate ------------------------------------
    Mov     EAX,[smpRate]
    Mov     EDX,[rate]
    Cmp     EDX,-1
    JE      short .DefRate
        Mov     EAX,EDX
        XOr     ECX,ECX

        Cmp     EDX,8000
        SetB    CL
        Cmp     EDX,192000
        SetA    CH
        Test    ECX,ECX
        JZ      short .DefRate

        Mov     EAX,32000

    .DefRate:
    Mov     [rate],EAX

    ;inter -----------------------------------
    MovZX   EAX,byte [dspInter]
    Mov     EDX,[inter]
    Cmp     EDX,-1
    JE      short .DefInter
        Mov     EAX,EDX
        Cmp     EDX,7
        JBE     short .DefInter

        Mov     EAX,3

    .DefInter:
    Mov     [inter],EAX

%ifdef HOST64
    ShL     EAX,3
    Lea     R8,[rel tabRout]
    Mov     RSI,[R8+RAX]
    Test    RSI,RSI
%else
    ShL     EAX,2
    Mov     ESI,[tabRout+EAX]
    Test    ESI,ESI
%endif
    JZ      short .NoCopyTable
%ifdef HOST64
        Lea     RDI,[rel interTab]
%else
        Mov     EDI,interTab
%endif
        Mov     ECX,1024
        Rep     MovSD

    .NoCopyTable:
    Mov     dword [apuDbgStage],301h

    ;opts ------------------------------------
    Mov     EDX,[dspOpts]
    Mov     EAX,[opts]
    Cmp     EAX,-1
    JE      short .DefOpts
        Mov     EDX,EAX

    .DefOpts:
    Mov     [opts],EDX

    ;=========================================
    ;Options

    ;Select ADPCM routine --------------------
%ifdef HOST64
    Lea     RAX,[rel UnpckSrc]
    Mov     [pDecomp],RAX
%else
    Mov     dword [pDecomp],UnpckSrc
%endif
    Test    EDX,DSP_OLDSMP
    JZ      short .NewSmp
%ifdef HOST64
        Lea     RAX,[rel UnpckSrcOld]
        Mov     [pDecomp],RAX
%else
        Mov     dword [pDecomp],UnpckSrcOld
%endif

    .NewSmp:

    ;DSP option adjustment -------------------
    Mov     ECX,[dspOpts]
    XOr     ECX,EDX                                                             ;ECX = Changed DSP flags
    Mov     [dspOpts],EDX                                                       ;Save option flags

    Test    ECX,DSP_ECHOFIR                                                     ;If the DSP_ECHOFIR flag changes, force sampling rate
    SetZ    AL                                                                  ; processing (smpRate = -1)
    MovZX   EAX,AL
    Dec     EAX
    Or      [smpRate],EAX

    And     ECX,DSP_SURND+DSP_NOSURND+DSP_REVERSE                               ;If surround/reverse flag changes, reset volume settings
    SetNZ   AL
    Or      [fixVol+0],AL

    Cmp     byte [numChn],1
    SetE    AH

    Test    EDX,DSP_SURND                                                       ;If channel is 1, or surround is disabled,
    SetZ    AL                                                                  ; then surround equals 0x00, else 0xFF
    Or      AL,AH
    Dec     AL
    Mov     [surround],AL

    Test    EDX,DSP_NOSURND                                                     ;If channel is 1, or surround is disabled,
    SetNZ   AL                                                                  ; then surroff equals 0x80, else 0x00
    Or      AL,AH
    ShL     AL,7
    Mov     [surroff],AL

    Test    EDX,DSP_NOECHO                                                      ;If echo is disable, clear echo buffer
    SetNZ   AL
    Or      [fixVol+1],AL

    Test    EDX,DSP_BASS                                                        ;If BASS BOOST is disable, clear BASS-BOOST buffer
    SetZ    AL
    Or      [fixVol+2],AL

    ;=========================================
    ;Interpolation method

    MovZX   EAX,byte [inter]                                                    ;Save interpolation type
    Mov     [dspInter],AL

    MovZX   EDX,byte [mixType]                                                  ;If mixType != MIX_NONE
    Test    EDX,EDX
    JZ      short .NoMix
%ifdef HOST64
        Lea     R8,[rel intRout]
        Mov     RAX,[R8+RAX*8]
        Mov     [pInter],RAX
%else
        Mov     EAX,[EAX*4+intRout]
        Mov     [pInter],EAX
%endif

    .NoMix:
    Mov     dword [apuDbgStage],302h

    ;=========================================
    ;Calculate sample rate change

    Mov     EAX,[rate]
    Cmp     EAX,[smpRate]                                                       ;Has sample rate changed?
    JE      .SameRate                                                           ;   No
        Mov     dword [apuDbgStage],303h
        Mov     [smpRate],EAX                                                   ;smpRate,dspRate = rate
        XOr     EDX,EDX                                                         ;smpAdj = 0

%if INTBK
        Test    dword [dspOpts],DSP_ECHOFIR                                     ;Is actual emulation mode?
        JZ      short .SMPROK                                                   ;   No

        Cmp     EAX,32000                                                       ;Is the sampling rate less than 32kHz?
        JBE     short .SMPROK                                                   ;   Yes
            Mov     EAX,32000                                                   ;EAX = Least common multiple of 32000 and smpRate
            Mov     ECX,[smpRate]

            .LoopGCM:
            XOr     EDX,EDX
            Div     ECX
            Mov     EAX,ECX
            Test    EDX,EDX
            JZ      short .ExitGCM
                Mov     ECX,EDX
                Jmp     short .LoopGCM

            .ExitGCM:
            Mov     ECX,EAX                                                     ;smpDen = Reduced denominator of 32000 / smpRate
            Mov     EAX,[smpRate]
            Div     ECX
            Mov     [smpDen],EAX

            Mov     EDX,32000                                                   ;smpAdj = 32000 * (2^32) / smpRate
            Mov     ECX,[smpRate]
            XOr     EAX,EAX
            Div     ECX
            Mov     EDX,EAX

            Mov     EAX,32000                                                   ;dspRate = 32000
            Mov     ECX,[smpRate]
            Sub     ECX,EAX                                                     ;smpDec = smpRate - 32000
            Mov     [smpDec],ECX

        .SMPROK:
%endif

        Mov     [dspRate],EAX
        Mov     [smpAdj],EDX

        ;Calculate amount to adjust SPC pitch values
        XOr     EDX,EDX                                                         ;EDX:EAX = Base pitch << 20
        Mov     EAX,[pitchBas]
        ShLD    EDX,EAX,20
        ShL     EAX,20

        Div     dword [dspRate]
        Mov     [pitchAdj],EAX

        ;Calculate update rate for envelopes and noise
%ifdef HOST64
        Lea     RSI,[rel freqTab]
        Lea     RDI,[rel rateTab]
%else
        Mov     ESI,freqTab
        Mov     EDI,rateTab
%endif
        Mov     EBX,32000
        Mov     ECX,31

        .CalcRT:
%ifdef HOST64
            Mov     EAX,[RSI+RCX*4]
%else
            Mov     EAX,[ECX*4+ESI]
%endif
            ShL     EAX,16
            Mul     dword [dspRate]
            Div     EBX

            Cmp     EAX,10000h
            JAE     short .RTOK
                Mov     EAX,10000h

            .RTOK:
%ifdef HOST64
            Mov     [RDI+RCX*4],EAX
%else
            Mov     [ECX*4+EDI],EAX
%endif

        Dec     ECX
        JNZ     short .CalcRT
%ifdef HOST64
        Mov     [RDI],ECX
%else
        Mov     [EDI],ECX
%endif
        Mov     dword [apuDbgStage],304h

        ;Volume ramping rate ------------------
        Mov     dword [tmpVal],32000
        FILd    dword [tmpVal]
        FIDiv   dword [dspRate]
        FMul    dword [fpShR8]
        FSt     dword [volRamp1]
        FIMul   dword [volAmp]
        FStP    dword [volRamp2]

        ;Reset FIR info -----------------------
        XOr     EAX,EAX
        Mov     [firCur],EAX

        Mov     EAX,[dspRate]
        MovZX   EDX,word [2+dspRate]
        ShL     EAX,16
        Mov     ECX,32000
        Div     ECX
        Mov     [firRate],EAX                                                   ;firRate = (dspRate<<16) / 32kHz

        ;Adjust voice rates -------------------
        Mov     EBX,7*80h                                                       ;Adjust the current rates in each voice incase the
                                                                                ; sample rate is being changed during emulation
%ifdef HOST64
        Lea     R8,[rel mix]
        Lea     R9,[rel scr700det]
        Lea     R10,[rel rateTab]
%endif
        .Voice:
%ifdef HOST64
            Mov     EAX,[R8+RBX+mOrgP]                                           ;Set pitch
            MovZX   EDX,byte [R8+RBX+mSrc]                                       ;EDX = Source
            Add     EAX,[R9+RDX*4]                                               ;EAX += Detune[EDX]
%else
            Mov     EAX,[EBX+mix+mOrgP]                                         ;Set pitch
            MovZX   EDX,byte [EBX+mix+mSrc]                                     ;EDX = Source
            Add     EAX,[scr700det+EDX*4]                                       ;EAX += Detune[EDX]
%endif

            Mul     dword [pitchAdj]
            ShRD    EAX,EDX,16
            AdC     EAX,0
%ifdef HOST64
            Mov     [R8+RBX+mRate],EAX

            MovZX   EDI,byte [R8+RBX+eRIdx]                                      ;Set envelope adjustment
            Mov     EAX,[R10+RDI*4]
            Mov     [R8+RBX+eRate],EAX
            Mov     [R8+RBX+eCnt],EAX
%else
            Mov     [EBX+mix+mRate],EAX

            MovZX   EDI,byte [EBX+mix+eRIdx]                                    ;Set envelope adjustment
            Mov     EAX,[EDI*4+rateTab]
            Mov     [EBX+mix+eRate],EAX
            Mov     [EBX+mix+eCnt],EAX
%endif

        Add     EBX,-80h
        JNS     short .Voice

        ;Adjust echo delay --------------------
        Call    REDl
        Mov     dword [apuDbgStage],305h

        ;BASS-BOOST buffer level ---------
        FLd     dword [fpLowRt]                                                 ;Level = (fpLowRt / dspRate) * fpLowLv
        FIDiv   dword [dspRate]
        FMul    dword [fpLowLv1]
        FStP    dword [lowLv1]

        FLd     dword [fpLowRt]
        FIDiv   dword [dspRate]
        FMul    dword [fpLowLv2]
        FStP    dword [lowLv2]

        ;BASS-BOOST buffer size ----------
        FILd    dword [dspRate]                                                 ;Size = dspRate * fpLowBs * 4
        FMul    dword [fpLowBs1]
        FIStP   dword [lowSize1]
        ShL     dword [lowSize1],2

        FILd    dword [dspRate]
        FMul    dword [fpLowBs2]
        FIStP   dword [lowSize2]
        ShL     dword [lowSize2],2

        Or      dword [fixVol],-1                                               ;Force volumes to be recalculated

        ;Anti-Alies 1st filter ---------
        ;Omega * Delta-T (wdt) = (2 * PI * cut-off frequency) * (1 / dspRate)
        FLdPi                                                                   ;                                   |pi
        FAdd    ST,ST                                                           ;                                   |pi*2
        FMul    dword [fpAafCF1]                                                ;                                   |pi*2*cf=Omega
        FLd1                                                                    ;                                   |Omega 1
        FIDiv   dword [dspRate]                                                 ;                                   |Omega 1/dspRate=Delta-T
        FMulP   ST1,ST                                                          ;                                   |Omega*Delta-T=wdt

        ;A0 = 1 (omit), A1 = (-2 + wdt) / (2 + wdt)
        FLd     ST                                                              ;                                   |wdt wdt
        Mov     dword [tmpVal],2
        FISub   dword [tmpVal]                                                  ;                                   |wdt -2+wdt
        FILd    dword [tmpVal]                                                  ;                                   |wdt -2+wdt 2
        FAdd    ST,ST2                                                          ;                                   |wdt -2+wdt 2+wdt
        FDivP   ST1,ST                                                          ;                                   |wdt -2+wdt/2+wdt
        FStP    dword [aaf1A1]                                                  ;                                   |wdt

        ;B0 = B1 = wdt / (2 + wdt)
        Mov     dword [tmpVal],2
        FILd    dword [tmpVal]                                                  ;                                   |wdt 2
        FAdd    ST,ST1                                                          ;                                   |wdt 2+wdt
        FDivP   ST1,ST                                                          ;                                   |wdt/2+wdt
        FSt     dword [aaf1B0]                                                  ;                                   |wdt/2+wdt
        FStP    dword [aaf1B1]                                                  ;                                   |(empty)

        ;Anti-Alies 2nd filter ---------
        ;Omega * Delta-T (wdt) = (2 * PI * cut-off frequency) * (1 / dspRate)
        FLdPi                                                                   ;                                   |pi
        FAdd    ST,ST                                                           ;                                   |pi*2
        FMul    dword [fpAafCF2]                                                ;                                   |pi*2*cf=Omega
        FLd1                                                                    ;                                   |Omega 1
        FIDiv   dword [dspRate]                                                 ;                                   |Omega 1/dspRate=Delta-T
        FMulP   ST1,ST                                                          ;                                   |Omega*Delta-T=wdt

        ;A0 = 1 (omit), A1 = (-2 + wdt) / (2 + wdt)
        FLd     ST                                                              ;                                   |wdt wdt
        Mov     dword [tmpVal],2
        FISub   dword [tmpVal]                                                  ;                                   |wdt -2+wdt
        FILd    dword [tmpVal]                                                  ;                                   |wdt -2+wdt 2
        FAdd    ST,ST2                                                          ;                                   |wdt -2+wdt 2+wdt
        FDivP   ST1,ST                                                          ;                                   |wdt -2+wdt/2+wdt
        FStP    dword [aaf2A1]                                                  ;                                   |wdt

        ;B0 = B1 = wdt / (2 + wdt)
        Mov     dword [tmpVal],2
        FILd    dword [tmpVal]                                                  ;                                   |wdt 2
        FAdd    ST,ST1                                                          ;                                   |wdt 2+wdt
        FDivP   ST1,ST                                                          ;                                   |wdt/2+wdt
        FSt     dword [aaf2B0]                                                  ;                                   |wdt/2+wdt
        FStP    dword [aaf2B1]                                                  ;                                   |(empty)
        Mov     dword [apuDbgStage],306h

    .SameRate:
    Mov     dword [apuDbgStage],307h

    ;=========================================
    ;Set sample size

    Mov     AL,[bits]
    Cmp     AL,[dspSize]                                                        ;If the sample size has changed, CL = 1
    JE      short .SameBits
        Mov     [dspSize],AL

    .SameBits:

    ;=========================================
    ;Set number of channels

    Mov     AL,[numChn]
    Cmp     AL,[dspChn]                                                         ;If the number of channels has changed, CL = 1
    SetNE   CL
    Or      [fixVol+0],CL
    Mov     [dspChn],AL

    ;=========================================
    ;Update areas affected by the mix type

    Mov     AL,[mixType]
    Cmp     AL,[dspMix]
    JE      short .SameMix
        Mov     [dspMix],AL
        Or      dword [fixVol],-1                                               ;Force volumes to be recalculated

    .SameMix:

    ;=========================================
    ;Erase sample buffers

    Test    byte [fixVol+1],-1
    JZ      short .NoEraseBuf
        Call    ResetEcho

    .NoEraseBuf:
    Test    byte [fixVol+2],-1
    JZ      short .NoEraseLow
        Call    ResetLow

    .NoEraseLow:
    Test    byte [fixVol+3],-1
    JZ      short .NoEraseResamp
        Call    ResetResamp

    .NoEraseResamp:

    ;=========================================
    ;Fixup volume handlers

    Test    byte [fixVol+0],-1
    JZ      .Done
        ;Reinitialize registers ---------------
        XOr     EDX,EDX
    Mov     ECX,70h
%ifdef HOST64
    Lea     R8,[rel dsp]
    Lea     R9,[rel mix]
%endif
    .NextVoice:
        LEA     EBX,[ECX+volL]
%ifdef HOST64
        Mov     AL,[R8+RCX+volL]
%else
        Mov     AL,[ECX+dsp+volL]
%endif
        Call    InitReg
%ifdef HOST64
        Lea     R9,[rel mix]
        Mov     EAX,[R9+RCX*8+mTgtL]
        Mov     [R9+RCX*8+mChnL],EAX
%else
        Mov     EAX,[ECX*8+mix+mTgtL]
        Mov     [ECX*8+mix+mChnL],EAX
%endif

        LEA     EBX,[ECX+volR]
%ifdef HOST64
        Lea     R8,[rel dsp]
        Mov     AL,[R8+RCX+volR]
%else
        Mov     AL,[ECX+dsp+volR]
%endif
        Call    InitReg
%ifdef HOST64
        Lea     R9,[rel mix]
        Mov     EAX,[R9+RCX*8+mTgtR]
        Mov     [R9+RCX*8+mChnR],EAX
%else
        Mov     EAX,[ECX*8+mix+mTgtR]
        Mov     [ECX*8+mix+mChnR],EAX
%endif

        LEA     EBX,[ECX+fc]
%ifdef HOST64
        Lea     R8,[rel dsp]
        Mov     AL,[R8+RCX+fc]
%else
        Mov     AL,[ECX+dsp+fc]
%endif
        Call    InitReg

        Sub     CL,10h
        JNC     short .NextVoice

        Mov     EBX,mvolL
        Mov     AL,[dsp+mvolL]
        Call    InitReg

        Mov     EBX,mvolR
        Mov     AL,[dsp+mvolR]
        Call    InitReg

        Mov     EBX,evolL
        Mov     AL,[dsp+evolL]
        Call    InitReg

        Mov     EBX,evolR
        Mov     AL,[dsp+evolR]
        Call    InitReg

        Mov     EBX,efb
        Mov     AL,[dsp+efb]
        Call    InitReg

        Call    ResetVol

    .Done:

ENDP


;===================================================================================================
;Debug DSP

PROC SetDSPDbg, pTraceFunc
%ifdef HOST64
    Mov     RDX,[pTrace]

    Mov     RAX,[pTraceFunc]
    Cmp     RAX,-1
    JE      short .NoFunc64
        Mov     [pTrace],RAX

    .NoFunc64:
    Mov     RAX,RDX
%else
USES EDX

    Mov     EDX,[pTrace]

    Mov     EAX,[pTraceFunc]
    Cmp     EAX,-1
    JE      short .NoFunc
        Mov     [pTrace],EAX

    .NoFunc:
    Mov     EAX,EDX
%endif

ENDP


;===================================================================================================
;Fix DSP After Loading Saved State

PROC FixDSP
USES ALL

    ;Enable voices currently keyed on --------
    Mov     byte [voiceMix],0

    Mov     EBX,kon
    Mov     AL,[dsp+kon]
    Call    InitReg

    ;Setup global paramaters -----------------
    Mov     EBX,mvolL
    Mov     AL,[dsp+mvolL]
    Call    InitReg

    Mov     EBX,mvolR
    Mov     AL,[dsp+mvolR]
    Call    InitReg

    Mov     EBX,evolL
    Mov     AL,[dsp+evolL]
    Call    InitReg

    Mov     EBX,evolR
    Mov     AL,[dsp+evolR]
    Call    InitReg

    Mov     EBX,flg
    Mov     AL,[dsp+flg]
    Call    InitReg

    Mov     EBX,efb
    Mov     AL,[dsp+efb]
    Call    InitReg

    Mov     EBX,edl
    Mov     AL,[dsp+edl]
    Call    InitReg

    Mov     ECX,70h
%ifdef HOST64
    Lea     R8,[rel dsp]
    Lea     R9,[rel mix]
%endif
    .NextTap:
        LEA     EBX,[ECX+volL]
%ifdef HOST64
        Mov     AL,[R8+RCX+volL]
%else
        Mov     AL,[ECX+dsp+volL]
%endif
        Call    InitReg
%ifdef HOST64
        Lea     R9,[rel mix]
        Mov     EAX,[R9+RCX*8+mTgtL]
        Mov     [R9+RCX*8+mChnL],EAX
%else
        Mov     EAX,[ECX*8+mix+mTgtL]
        Mov     [ECX*8+mix+mChnL],EAX
%endif

        LEA     EBX,[ECX+volR]
%ifdef HOST64
        Lea     R8,[rel dsp]
        Mov     AL,[R8+RCX+volR]
%else
        Mov     AL,[ECX+dsp+volR]
%endif
        Call    InitReg
%ifdef HOST64
        Lea     R9,[rel mix]
        Mov     EAX,[R9+RCX*8+mTgtR]
        Mov     [R9+RCX*8+mChnR],EAX
%else
        Mov     EAX,[ECX*8+mix+mTgtR]
        Mov     [ECX*8+mix+mChnR],EAX
%endif

        LEA     EBX,[ECX+fc]
%ifdef HOST64
        Lea     R8,[rel dsp]
        Mov     AL,[R8+RCX+fc]
%else
        Mov     AL,[ECX+dsp+fc]
%endif
        Call    InitReg

    Sub     CL,10h
    JNC     short .NextTap

    Call    ResetVol

%if INTBK && DSPINTEG
    Call    ResetKON
%endif

ENDP


;===================================================================================================
;Fix DSP After Seeking

PROC FixSeek, reset
USES ECX,EDI

    Mov     AL,[reset]
    Test    AL,AL
    JZ      .NoReset
        ;Turn off all voices ------------------
        Mov     AL,[dsp+kon]                                                    ;Mark all playing voices as ended
        Mov     [dsp+endx],AL

        XOr     EAX,EAX
        Mov     [dsp+kon],AL                                                    ;Reset key registers
        Mov     [dsp+kof],AL
        Mov     [voiceMix],AL
        Mov     [konRsv],AX                                                     ;Reset konRsv, koffRsv

        Mov     CL,8
%ifdef HOST64
        Lea     RDI,[rel mix]
%else
        Mov     EDI,mix
%endif

        .ResetMix:
%ifdef HOST64
            Mov     [RDI+eVal],EAX
            Mov     [RDI+mOut],EAX
            And     byte [RDI+mFlg],MFLG_USER                                   ;Leave user voice flags (mute and noise)
            Or      byte [RDI+mFlg],MFLG_OFF                                    ;Set voice to inactive
            Sub     RDI,-80h
%else
            Mov     [EDI+eVal],EAX
            Mov     [EDI+mOut],EAX
            And     byte [EDI+mFlg],MFLG_USER                                   ;Leave user voice flags (mute and noise)
            Or      byte [EDI+mFlg],MFLG_OFF                                    ;Set voice to inactive
            Sub     EDI,-80h
%endif

        Dec     CL
        JNZ     short .ResetMix

        Mov     CL,8
%ifdef HOST64
        Lea     RDI,[rel dsp]
%else
        Mov     EDI,dsp
%endif

        .ResetDSP:
%ifdef HOST64
            Mov     [RDI+envx],AL
            Mov     [RDI+outx],AL
            Add     RDI,10h
%else
            Mov     [EDI+envx],AL
            Mov     [EDI+outx],AL
            Add     EDI,10h
%endif

        Dec     CL
        JNZ     short .ResetDSP

        Call    FixDSP

    .NoReset:
    Call    ResetEcho
    Call    ResetLow
;   Call    ResetResamp                                                         ;Do not reset because noise occurs by seek
    Call    SetFade

ENDP


;===================================================================================================
;DSP Pitch Adjustment

PROC SetDSPPitch, base
USES EDX,EBX

    ;Calculate amount to adjust SPC pitch values
    XOr     EDX,EDX
    Mov     EAX,[base]
    Mov     [pitchBas],EAX
    ShLD    EDX,EAX,20
    ShL     EAX,20

    Div     dword [dspRate]
    Mov     [pitchAdj],EAX

    ;Adjust voice rates to new pitch ---------
    Mov     EBX,7*80h                                                           ;Adjust the current rates in each voice incase the
%ifdef HOST64
    Lea     R8,[rel mix]
    Lea     R9,[rel scr700det]
%endif
    .Voice:                                                                     ; sample rate is being changed during emulation
%ifdef HOST64
        Mov     EAX,[R8+RBX+mOrgP]                                              ;Set pitch
        MovZX   EDX,byte [R8+RBX+mSrc]                                          ;EDX = Source
        Add     EAX,[R9+RDX*4]                                                  ;EAX += Detune[EDX]
%else
        Mov     EAX,[EBX+mix+mOrgP]                                             ;Set pitch
        MovZX   EDX,byte [EBX+mix+mSrc]                                         ;EDX = Source
        Add     EAX,[scr700det+EDX*4]                                           ;EAX += Detune[EDX]
%endif

        Mul     dword [pitchAdj]
        ShRD    EAX,EDX,16
        AdC     EAX,0
%ifdef HOST64
        Mov     [R8+RBX+mRate],EAX
%else
        Mov     [EBX+mix+mRate],EAX
%endif

    Add     EBX,-80h
    JNS     short .Voice

ENDP


;===================================================================================================
;DSP Amplification

PROC SetDSPAmp, amp
USES ECX,EDX,EBX

    Mov     EAX,[amp]                                                           ;If amp < 0, amp = 0
    CDQ
    Not     EDX
    And     EAX,EDX

    Cmp     EAX,256
    JA      short .NewScale
        ShL     EAX,12

    .NewScale:
    Mov     [volAmp],EAX

    ;Multiply by volume ----------------------
    Mul     dword [volAtten]
    ShRD    EAX,EDX,16
    Mov     [volAdj],EAX

    ;Update global volumes -------------------
    Mov     EBX,mvolL
    Mov     AL,[dsp+mvolL]
    Call    InitReg

    Mov     EBX,mvolR
    Mov     AL,[dsp+mvolR]
    Call    InitReg

    Mov     EBX,evolL
    Mov     AL,[dsp+evolL]
    Call    InitReg

    Mov     EBX,evolR
    Mov     AL,[dsp+evolR]
    Call    InitReg

    FLd     dword [volRamp1]
    FIMul   dword [volAmp]
    FStP    dword [volRamp2]

    Call    ResetVol

ENDP


;===================================================================================================
;DSP Fade Volume

PROC SetDSPVol, vol
USES ECX,EDX,EBX

    Mov     EAX,[vol]                                                           ;If EAX < 0, EAX = 0
    CDQ
    Not     EDX
    And     EAX,EDX
    Mov     [volAtten],EAX
    Mul     dword [volAmp]
    ShRD    EAX,EDX,16
    Mov     [volAdj],EAX

    ;Update global volumes -------------------
    Mov     EBX,mvolL
    Mov     AL,[dsp+mvolL]
    Call    InitReg

    Mov     EBX,mvolR
    Mov     AL,[dsp+mvolR]
    Call    InitReg

    Mov     EBX,evolL
    Mov     AL,[dsp+evolL]
    Call    InitReg

    Mov     EBX,evolR
    Mov     AL,[dsp+evolR]
    Call    InitReg

    ;Call   ResetVol                                                            ;Don't call ResetVol to smooth fade-out

ENDP


;===================================================================================================
;Set Song Length

PROC SetDSPLength, song, fade
USES EDX

    Mov     EDX,[fade]
    XOr     EAX,EAX                                                             ;If fadeLen = 0, fadeLen = 1
    Test    EDX,EDX                                                             ;0 will cause a division error
    SetZ    AL
    Or      EDX,EAX
    Mov     [fadeLen],EDX

    Mov     EAX,[song]
    Add     EDX,EAX
    Mov     [songLen],EAX

    Cmp     EAX,[t64Cnt]                                                        ;If t64Cnt > songLen
    JB      short .SetFade
        Call    SetDSPVol,10000h
        RetN    EDX

    .SetFade:
        Push    EDX
        Call    SetFade                                                         ;If song is in fade mode, set fade volume
        Pop     EAX
;       Mov     EAX,EDX

ENDP


;===================================================================================================
;Set Fade Volume
;
;Calls SetDSPVol to fade the song out based on t64Cnt, songLen, and fadeLen.

PROC SetFade

    Mov     EAX,[t64Cnt]                                                        ;EAX = T64Cnt - songLen;
    Sub     EAX,[songLen]                                                       ;If T64Cnt <= songLen, do nothing
    JBE     .Done

    XOr     EDX,EDX                                                             ;If EAX >= fadeLen, call SetDSPVol(0)
    Cmp     EAX,[fadeLen]
    JAE     .SetVol

%ifdef HOST64
    Mov     [RSP-4],EAX                                                         ;EDX = 65536 - 65536 * sin(EAX / fadeLen * pi / 2)
    FILd    dword [RSP-4]                                                       ;                                   |EAX
%else
    Mov     [ESP-4],EAX                                                         ;EDX = 65536 - 65536 * sin(EAX / fadeLen * pi / 2)
    FILd    dword [ESP-4]                                                       ;                                   |EAX
%endif
    FIDiv   dword [fadeLen]                                                     ;                                   |EAX/fadeLen
    FLdPi                                                                       ;                                   |EAX/fadeLen pi
    FMulP   ST1,ST                                                              ;                                   |EAX/fadeLen*pi
    FMul    dword [fp0_5]                                                       ;                                   |EAX/fadeLen*pi/2=x
    FSin                                                                        ;                                   |sin(x)
    Mov     EDX,65536
%ifdef HOST64
    Mov     [RSP-4],EDX
    FILd    dword [RSP-4]                                                       ;                                   |sin(x) 65536
    FMul                                                                        ;                                   |sin(x)*65536
    FIStP   dword [RSP-4]                                                       ;                                   |(empty)
    Mov     EAX,[RSP-4]                                                         ;EAX = 65536 * sin(x)
%else
    Mov     [ESP-4],EDX
    FILd    dword [ESP-4]                                                       ;                                   |sin(x) 65536
    FMul                                                                        ;                                   |sin(x)*65536
    FIStP   dword [ESP-4]                                                       ;                                   |(empty)
    Mov     EAX,[ESP-4]                                                         ;EAX = 65536 * sin(x)
%endif
    Sub     EDX,EAX                                                             ;EDX = 65536 - EAX

    .SetVol:
    Call    SetDSPVol,EDX                                                       ;SetDSPVol(EDX);

    .Done:

ENDP


;===================================================================================================
;Adjust Voice Volume for Stereo Separation
;
;A big nasty function to adjust the left and right channel volumes for stereo separation control
;
;In:
;   EBX = Indexes current voice

%if STEREO
;Channel separator for floating-point routines
PROC ChnSep
RVolL:
RVolR:
USES ECX,EBX

    ShR     EBX,3
%ifdef HOST64
    Lea     R8,[rel dsp]
    Lea     R9,[rel mix]
    Mov     AL,[R8+RBX+volL]
    Mov     DL,[R8+RBX+volR]
%else
    Mov     AL,[EBX+dsp+volL]
    Mov     DL,[EBX+dsp+volR]
%endif

    Test    dword [dspOpts],DSP_REVERSE                                         ;Swap left, right?
    JZ      short .NoReverse                                                    ;   No
        XChg    AL,DL
    .NoReverse:

    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH
    MovSX   EAX,AL

    Test    DL,[surroff]
    SetZ    DH
    Dec     DH
    XOr     DL,DH
    Sub     DL,DH
    Mov     DH,[surroff]
    Cmp     DX,8080h
    SetE    DH
    Sub     DL,DH
    MovSX   EDX,DL

%ifdef HOST64
    LEA     RBX,[R9+RBX*8]
%else
    LEA     EBX,[EBX*8+mix]
%endif
%ifdef HOST64
    Mov     [RBX+mTgtL],EAX
    Mov     [RBX+mTgtR],EDX
%else
    Mov     [EBX+mTgtL],EAX
    Mov     [EBX+mTgtR],EDX
%endif

    Cmp     EAX,EDX
    JE      .NoSep

    Mov     ECX,[volSepar]
    Test    ECX,ECX
    JZ      .NoSep

    FInit

    And     AL,80h                                                              ;Save sign bit of each volume
    And     DL,80h
    ShL     EAX,24
    ShL     EDX,24

    ;Convert left/right into vol/pan ---------
%ifdef HOST64
    FILd    dword [RBX+mTgtR]
    FMul    dword [fpShR7]
    FLd     ST
    FMul    ST,ST
    FILd    dword [RBX+mTgtL]
    FMul    dword [fpShR7]
%else
    FILd    dword [EBX+mTgtR]
    FMul    dword [fpShR7]
    FLd     ST
    FMul    ST,ST
    FILd    dword [EBX+mTgtL]
    FMul    dword [fpShR7]
%endif
    FMul    ST,ST
    FAddP   ST1,ST
    FSqrt
    FXch
    FAbs
    FDiv    ST,ST1
    FMul    ST,ST
    FSub    dword [fp0_5]

    ;Adjust panning --------------------------
    FLd     ST
    Test    byte [3+volSepar],80h
    JNZ     short .Center
%ifdef HOST64
        FSt     qword [RSP-8]
        FLd     dword [fp0_5]
        Test    byte [RSP-1],80h
%else
        FSt     qword [ESP-8]
        FLd     dword [fp0_5]
        Test    byte [ESP-1],80h
%endif
        JZ      short .Right
            FChS
        .Right:
        FSubRP  ST1,ST

    .Center:
    FMul    dword [volSepar]
    FAddP   ST1,ST
    FLd     ST

    ;Convert vol/pan back into left/right ----
    FAdd    dword [fp0_5]
    FSqrt
    FMul    ST,ST2
%ifdef HOST64
    FStP    dword [RBX+mTgtR]
    Or      [RBX+mTgtR],EDX
%else
    FStP    dword [EBX+mTgtR]
    Or      [EBX+mTgtR],EDX
%endif

    FSubR   dword [fp0_5]
    FSqrt
    FMulP   ST1,ST
%ifdef HOST64
    FStP    dword [RBX+mTgtL]
    Or      [RBX+mTgtL],EAX
%else
    FStP    dword [EBX+mTgtL]
    Or      [EBX+mTgtL],EAX
%endif

    XOr     EAX,EAX
    RetN

.NoSep:
%ifdef HOST64
    FILd    dword [RBX+mTgtL]
    FMul    dword [fpShR7]
    FStP    dword [RBX+mTgtL]

    FILd    dword [RBX+mTgtR]
    FMul    dword [fpShR7]
    FStP    dword [RBX+mTgtR]
%else
    FILd    dword [EBX+mTgtL]
    FMul    dword [fpShR7]
    FStP    dword [EBX+mTgtL]

    FILd    dword [EBX+mTgtR]
    FMul    dword [fpShR7]
    FStP    dword [EBX+mTgtR]
%endif

    XOr     EAX,EAX

ENDP
%endif


;===================================================================================================
;Set Stereo Separation

PROC SetDSPStereo, sep
USES EDX,EBX

%if STEREO
    Sub     dword [sep],32768                                                   ;Convert fixed point unsigned value to signed float
    FILd    dword [sep]
    FMul    dword [fpShR15]
    FStP    dword [volSepar]

    ;Update each voice with new separation ---
    Mov     EBX,7*80h

    .Float:
        Call    ChnSep
%ifdef HOST64
        Lea     R8,[rel mix]
        Mov     EAX,[R8+RBX+mTgtL]
        Mov     EDX,[R8+RBX+mTgtR]
        Mov     [R8+RBX+mChnL],EAX
        Mov     [R8+RBX+mChnR],EDX
%else
        Mov     EAX,[EBX+mix+mTgtL]
        Mov     EDX,[EBX+mix+mTgtR]
        Mov     [EBX+mix+mChnL],EAX
        Mov     [EBX+mix+mChnR],EDX
%endif

    Add     EBX,-80h
    JNS     short .Float
%endif

ENDP


;===================================================================================================
;Set Echo Stereo Separation

PROC SetDSPEFBCT, leak
USES EDX,EBX

    Mov     EAX,[leak]
    Add     EAX,32768                                                           ;Unsign crosstalk
    Mov     [efbct],EAX

    ;Update echo feedback --------------------
    Mov     EBX,efb
    Mov     AL,[dsp+efb]
    Call    InitReg

ENDP


;===================================================================================================
;Start Sound Source Decompression
;
;Called when a voice is keyed on to set up the internal data for waveform mixing and decompress the
;first block.
;
;In:
;   EBX-> mix[voice]
;   ESI-> dsp.voice[voice]
;
;Out:
;   nothing
;
;Destroys:
;   EAX,EDX

PROC StartSrc

    Push    ESI,EDI,EBP
%ifdef HOST64
    MovZX   EAX,byte [RBX+mSrc]                                                 ;EAX = Source
%else
    MovZX   EAX,byte [EBX+mSrc]                                                 ;EAX = Source
%endif
%ifdef HOST64
    Lea     R8,[rel scr700chg]
    Mov     AL,[R8+RAX]                                                         ;AL = NoteChange[EAX]
%else
    Mov     AL,[scr700chg+EAX]                                                  ;AL = NoteChange[EAX]
%endif

    ShL     EAX,2
    Add     AH,[dsp+dir]                                                        ;EAX -> Source directory
%ifdef HOST64
    Mov     R8,[pAPURAM]
    MovZX   ESI,word [R8+RAX]                                                   ;ESI = First block offset in APU RAM
    Lea     RDI,[RBX+sBuf]                                                      ;RDI -> Uncompressed sample buffer
    Mov     [RBX+bCur],ESI                                                      ;Save waveform block offset
    Mov     dword [RBX+sIdx],0                                                  ;Sample index is an offset in sBuf
    Lea     RSI,[R8+RSI]                                                        ;RSI -> First block of waveform
%else
    Mov     ESI,[pAPURAM]
    Mov     SI,[EAX+ESI]                                                        ;ESI -> First block of waveform
    LEA     EDI,[EBX+sBuf]                                                      ;EDI -> Uncompressed sample buffer
    Mov     [EBX+bCur],ESI                                                      ;Save physical pointers to wave data
    Mov     [EBX+sIdx],EDI
%endif

    ;Decompress first block ------------------
%ifdef HOST64
	    Mov     AL,[RSI]
	    Push    ECX,EBX
	    Mov     [RBX+bHdr],AL                                                       ;Save block header
	    MovSX   EDX,word [RBX+sP1]
	    MovSX   EBX,word [RBX+sP2]
	    Call    [pDecomp]
	    Mov     EAX,EBX
	    Pop     EBX,ECX
	    Mov     [RBX+sP1],DX
	    Mov     [RBX+sP2],AX
        Inc     dword [dbgDecompCount]
%else
    Mov     AL,[ESI]
    Push    EBX
    Mov     [EBX+bHdr],AL                                                       ;Save block header
    MovSX   EDX,word [EBX+sP1]
    MovSX   EBX,word [EBX+sP2]
    Call    [pDecomp]
    Mov     EAX,EBX
    Pop     EBX
    Mov     [EBX+sP1],DX
    Mov     [EBX+sP2],AX
%endif

    ;Initialize interpolation ----------------
    XOr     EAX,EAX
%ifdef HOST64
    Mov     [RBX+sBuf-4],EAX
    Mov     [RBX+sBuf-8],EAX
    Mov     [RBX+sBuf-12],EAX
    Mov     [RBX+sBuf-16],EAX
%else
    Mov     [EBX+sBuf-4],EAX
    Mov     [EBX+sBuf-8],EAX
    Mov     [EBX+sBuf-12],EAX
    Mov     [EBX+sBuf-16],EAX
%endif

    Cmp     byte [dspInter],2                                                   ;Is interpolation enabled?
    JB      short .NoInter
%ifdef HOST64
        Add     byte [RBX+sIdx],6                                               ;Update sample index offset
%else
        Add     byte [EBX+sIdx],6                                               ;Update sample index
%endif

    .NoInter:
    Pop     EBP,EDI,ESI

ENDP


;===================================================================================================
;Start Envelope
;
;Called when a voice is keyed on to set up the internal data to begin envelope modification based on
;the values in ADSR/Gain.
;
;In:
;   EBX-> mix[voice]
;   ESI-> dsp.voice[voice]
;
;Out:
;   mix.e???       = correct values for envelope routine in mixer
;   dsp.voice.envx = 0
;
;Destroys:
;   EAX,EDX

PROC StartEnv
USES ESI

%ifdef HOST64
    XOr     EAX,EAX
    Mov     [RBX+eVal],EAX                                                      ;Envelope starts at 0
    Mov     [RBX+mOut],EAX
    Mov     [RBX+eRIdx],AL                                                      ;Reset envelope counter
    Mov     EDX,[rel rateTab]
    Mov     [RBX+eRate],EDX                                                     ;Reset rate of adjustment
    Mov     [RBX+eCnt],EDX
    Mov     [RSI+envx],AL                                                       ;Reset envelope height
    Mov     [RSI+outx],AL
    Mov     byte [RBX+eMode],E_ATT << 4                                         ;If envelope gets switched out of gain mode, start ADSR

    Test    byte [RSI+adsr],80h                                                 ;Is the envelope in ADSR mode?
    JZ      ChgGain                                                             ;   No, It's in gain mode

ChgAtt:
        Cmp     dword [RBX+eVal],D_MAX                                          ;Did envelope reach destination value?
        JGE     short .ChgDec                                                   ;   Yes, change decay mode

        Mov     byte [RBX+eMode],E_ATT                                          ;Set envelope mode to attack
        Mov     dword [RBX+eDest],D_MAX                                         ;Set destination to 1.0

        Mov     AL,byte [RSI+adsr]
        And     AL,0Fh
        Add     AL,AL                                                           ;Adjust AL to index rateTab
        Inc     AL
        Cmp     AL,1Fh                                                          ;Is there an attack?
        JE      short .NoAtt                                                    ;   Yes

        Mov     dword [RBX+eAdj],A_LIN                                          ;Set adjustment rate to linear
        Cmp     [RBX+eRIdx],AL
        JE      short .AttNext

        Mov     [RBX+eRIdx],AL
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
        Mov     [RBX+eRate],EDX
        Mov     [RBX+eCnt],EDX

    .AttNext:
        RetN                                                                    ;Exit

    .NoAtt:
        Mov     dword [RBX+eAdj],A_NOATT                                        ;Set adjustment rate to 1.0
        Cmp     [RBX+eRIdx],AL
        JE      short .AttNext

        Mov     [RBX+eRIdx],AL
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
        Mov     [RBX+eRate],EDX
        Mov     [RBX+eCnt],EDX

        RetN                                                                    ;Exit

    .ChgDec:
        MovZX   EAX,byte [RBX+eRIdx]
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
        Mov     [RBX+eRate],EDX
        Mov     [RBX+eCnt],EDX

ChgDec:
        Mov     AL,[RSI+adsr+1]                                                 ;Set destination to AL/8
        ShR     AL,5
        Inc     AL
;       Test    AL,8                                                            ;Is destination of envelope D_MAX?
;       JNZ     .ChgSus                                                         ;   Yes, change sustain mode

        IMul    EAX,D_EXP
        XOr     EDX,EDX                                                         ;Adjust value for internal precision
        Dec     EAX
        SetS    DL
        Add     EAX,EDX

        Cmp     byte [RBX+eMode],E_DECAY                                        ;If DR changes in the middle of DECAY,
        JNE     short .DecSkip                                                  ;   and DR is higher than current envelope value,
        Cmp     [RBX+eVal],EAX                                                  ;   does not change to sustain mode
        JGE     short .DecSkip

        Mov     dword [RBX+eDest],D_MIN                                         ;Destination to 0 instead of changing to sustain mode,
        Jmp     short .DecReset                                                 ;   prevents changing to sustain mode by UpdateEnv

    .DecSkip:
        Cmp     [RBX+eVal],EAX                                                  ;Did envelope reach destination value?
        JLE     short .ChgSus                                                   ;   Yes, change sustain mode

        Mov     dword [RBX+eAdj],A_EXP                                          ;Set adjustment rate to exponential
        Mov     byte [RBX+eMode],E_DECAY                                        ;Set envelope mode to decay
        Mov     [RBX+eDest],EAX

    .DecReset:
        MovZX   EAX,byte [RSI+adsr]
        And     AL,70h
        ShR     AL,3
        Add     AL,10h                                                          ;Adjust AL to index rateTab
        Cmp     [RBX+eRIdx],AL
        JE      short .DecNext

        Mov     [RBX+eRIdx],AL
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
        Mov     [RBX+eRate],EDX
        Mov     [RBX+eCnt],EDX

    .DecNext:
        RetN                                                                    ;Exit

    .ChgSus:
        MovZX   EAX,byte [RBX+eRIdx]
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
        Mov     [RBX+eRate],EDX
        Mov     [RBX+eCnt],EDX

ChgSus:
        Mov     dword [RBX+eAdj],A_EXP                                          ;Set adjustment rate to exponential
        Mov     dword [RBX+eDest],D_MIN                                         ;Set destination to 0

        Mov     AL,[RSI+adsr+1]
        Mov     AH,E_IDLE
        And     AL,1Fh                                                          ;Is index zero?
        JZ      short .SusNext                                                  ;   Yes, change idle mode

        Cmp     dword [RBX+eVal],D_MIN                                          ;Did envelope reach destination value?
        JLE     short .SusNext                                                  ;   Yes, change idle mode

        XOr     AH,AH
        Cmp     [RBX+eRIdx],AL
        JE      short .SusNext

        Mov     [RBX+eRIdx],AL
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]
        Mov     [RBX+eRate],EDX                                                 ;Set rate of change
        Mov     [RBX+eCnt],EDX

    .SusNext:
        Or      AH,E_SUST
        Mov     [RBX+eMode],AH                                                  ;Set envelope mode to sustain
        RetN                                                                    ;Exit

ChgGain:
    Mov     AL,[RSI+gain]
    Test    AL,80h                                                              ;Is gain direct?
    JNZ     short .GainMode                                                     ;   No, program envelope
        Mov     dword [RBX+eAdj],A_DIRECT                                       ;Set adjustment rate to 1.0

        And     AL,7Fh                                                          ;Isolate direct value
        Mov     EDX,EAX                                                         ;Adjust value for internal precision
        ShR     DL,7-E_SHIFT                                                    ;EAX = LEVEL * A_GAIN + LEVEL / 128 * A_GAIN
        ShL     EAX,E_SHIFT                                                     ; If LEVEL = 0x00, EAX = 0
        Add     EAX,EDX                                                         ; If LEVEL = 0x7F, EAX = D_MAX (128 * A_GAIN - 1)
        Mov     [RBX+eDest],EAX                                                 ;  EAX = 127 * A_GAIN + 127 / 128 * A_GAIN

        Mov     byte [RBX+eRIdx],31                                             ;Envelope is set
        Mov     ESI,[rel 31*4+rateTab]
        Mov     [RBX+eRate],ESI
        Mov     [RBX+eCnt],ESI

        Mov     DL,[RBX+eMode]
        And     DL,70h
        Or      DL,E_DIRECT                                                     ;Set mode to direct
        Mov     [RBX+eMode],DL
        RetN

    .GainMode:
        Mov     DL,AL
        Mov     AH,E_IDLE
        And     AL,1Fh                                                          ;Is index zero?
        JZ      short .GainNext

        XOr     AH,AH
        Cmp     [RBX+eRIdx],AL
        JE      short .GainNext

        Mov     [RBX+eRIdx],AL
        Lea     R8,[rel rateTab]
        Mov     ESI,[R8+RAX*4]
        Mov     [RBX+eRate],ESI                                                 ;Set rate of change
        Mov     [RBX+eCnt],ESI

    .GainNext:
        Mov     AL,[RBX+eMode]                                                  ;Preserve ADSR mode
        And     AL,70h
        Or      AL,AH

        Test    DL,60h                                                          ;Jump to the right mode
        JZ      short .GainDec
        Test    DL,40h
        JZ      short .GainExp
        Test    DL,20h
        JZ      short .GainInc

    .GainBent:
        Mov     dword [RBX+eAdj],A_LIN
        Mov     dword [RBX+eDest],D_BENT
        Or      AL,E_BENT                                                       ;Set mode to bent line increase
        Mov     [RBX+eMode],AL
        RetN

    .GainInc:
        Mov     dword [RBX+eAdj],A_LIN
        Mov     dword [RBX+eDest],D_MAX
        Or      AL,E_INC                                                        ;Set mode to linear increase
        Mov     [RBX+eMode],AL
        RetN

    .GainExp:
        Mov     dword [RBX+eAdj],A_EXP
        Mov     dword [RBX+eDest],D_MIN
        Or      AL,E_EXP                                                        ;Set mode to exponential decrease
        Mov     [RBX+eMode],AL
        RetN

    .GainDec:
        Mov     dword [RBX+eAdj],A_LIN
        Mov     dword [RBX+eDest],D_MIN
        Or      AL,E_DEC                                                        ;Set mode to linear decrease
        Mov     [RBX+eMode],AL
        RetN
%else
    XOr     EAX,EAX
    Mov     [EBX+eVal],EAX                                                      ;Envelope starts at 0
    Mov     [EBX+mOut],EAX
    Mov     [EBX+eRIdx],AL                                                      ;Reset envelope counter
    Mov     EDX,[rateTab]
    Mov     [EBX+eRate],EDX                                                     ;Reset rate of adjustment
    Mov     [EBX+eCnt],EDX
    Mov     [ESI+envx],AL                                                       ;Reset envelope height
    Mov     [ESI+outx],AL
    Mov     byte [EBX+eMode],E_ATT << 4                                         ;If envelope gets switched out of gain mode, start ADSR

    Test    byte [ESI+adsr],80h                                                 ;Is the envelope in ADSR mode?
    JZ      ChgGain                                                             ;   No, It's in gain mode

ChgAtt:
        Cmp     dword [EBX+eVal],D_MAX                                          ;Did envelope reach destination value?
        JGE     short .ChgDec                                                   ;   Yes, change decay mode

        Mov     byte [EBX+eMode],E_ATT                                          ;Set envelope mode to attack
        Mov     dword [EBX+eDest],D_MAX                                         ;Set destination to 1.0

        Mov     AL,byte [ESI+adsr]
        And     AL,0Fh
        Add     AL,AL                                                           ;Adjust AL to index rateTab
        Inc     AL
        Cmp     AL,1Fh                                                          ;Is there an attack?
        JE      short .NoAtt                                                    ;   Yes

        Mov     dword [EBX+eAdj],A_LIN                                          ;Set adjustment rate to linear
        Cmp     [EBX+eRIdx],AL
        JE      short .AttNext

        Mov     [EBX+eRIdx],AL
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
%else
        Mov     EDX,[EAX*4+rateTab]                                             ;Set rate of adjustment
%endif
        Mov     [EBX+eRate],EDX
        Mov     [EBX+eCnt],EDX

    .AttNext:
        RetN                                                                    ;Exit

    .NoAtt:
        Mov     dword [EBX+eAdj],A_NOATT                                        ;Set adjustment rate to 1.0
        Cmp     [EBX+eRIdx],AL
        JE      short .AttNext

        Mov     [EBX+eRIdx],AL
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
%else
        Mov     EDX,[EAX*4+rateTab]                                             ;Set rate of adjustment
%endif
        Mov     [EBX+eRate],EDX
        Mov     [EBX+eCnt],EDX

        RetN                                                                    ;Exit

    .ChgDec:
        MovZX   EAX,byte [EBX+eRIdx]
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
%else
        Mov     EDX,[EAX*4+rateTab]                                             ;Set rate of adjustment
%endif
        Mov     [EBX+eRate],EDX
        Mov     [EBX+eCnt],EDX

ChgDec:
        Mov     AL,[ESI+adsr+1]                                                 ;Set destination to AL/8
        ShR     AL,5
        Inc     AL
;       Test    AL,8                                                            ;Is destination of envelope D_MAX?
;       JNZ     .ChgSus                                                         ;   Yes, change sustain mode

        IMul    EAX,D_EXP
        XOr     EDX,EDX                                                         ;Adjust value for internal precision
        Dec     EAX
        SetS    DL
        Add     EAX,EDX

        Cmp     byte [EBX+eMode],E_DECAY                                        ;If DR changes in the middle of DECAY,
        JNE     short .DecSkip                                                  ;   and DR is higher than current envelope value,
        Cmp     [EBX+eVal],EAX                                                  ;   does not change to sustain mode
        JGE     short .DecSkip

        Mov     dword [EBX+eDest],D_MIN                                         ;Destination to 0 instead of changing to sustain mode,
        Jmp     short .DecReset                                                 ;   prevents changing to sustain mode by UpdateEnv

    .DecSkip:
        Cmp     [EBX+eVal],EAX                                                  ;Did envelope reach destination value?
        JLE     short .ChgSus                                                   ;   Yes, change sustain mode

        Mov     dword [EBX+eAdj],A_EXP                                          ;Set adjustment rate to exponential
        Mov     byte [EBX+eMode],E_DECAY                                        ;Set envelope mode to decay
        Mov     [EBX+eDest],EAX

    .DecReset:
        MovZX   EAX,byte [ESI+adsr]
        And     AL,70h
        ShR     AL,3
        Add     AL,10h                                                          ;Adjust AL to index rateTab
        Cmp     [EBX+eRIdx],AL
        JE      short .DecNext

        Mov     [EBX+eRIdx],AL
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
%else
        Mov     EDX,[EAX*4+rateTab]                                             ;Set rate of adjustment
%endif
        Mov     [EBX+eRate],EDX
        Mov     [EBX+eCnt],EDX

    .DecNext:
        RetN                                                                    ;Exit

    .ChgSus:
        MovZX   EAX,byte [EBX+eRIdx]
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]                                                  ;Set rate of adjustment
%else
        Mov     EDX,[EAX*4+rateTab]                                             ;Set rate of adjustment
%endif
        Mov     [EBX+eRate],EDX
        Mov     [EBX+eCnt],EDX

ChgSus:
        Mov     dword [EBX+eAdj],A_EXP                                          ;Set adjustment rate to exponential
        Mov     dword [EBX+eDest],D_MIN                                         ;Set destination to 0

        Mov     AL,[ESI+adsr+1]
        Mov     AH,E_IDLE
        And     AL,1Fh                                                          ;Is index zero?
        JZ      short .SusNext                                                  ;   Yes, change idle mode

        Cmp     dword [EBX+eVal],D_MIN                                          ;Did envelope reach destination value?
        JLE     short .SusNext                                                  ;   Yes, change idle mode

        XOr     AH,AH
        Cmp     [EBX+eRIdx],AL
        JE      short .SusNext

        Mov     [EBX+eRIdx],AL
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     EDX,[R8+RAX*4]
%else
        Mov     EDX,[EAX*4+rateTab]
%endif
        Mov     [EBX+eRate],EDX                                                 ;Set rate of change
        Mov     [EBX+eCnt],EDX

    .SusNext:
        Or      AH,E_SUST
        Mov     [EBX+eMode],AH                                                  ;Set envelope mode to sustain
        RetN                                                                    ;Exit

ChgGain:
    Mov     AL,[ESI+gain]
    Test    AL,80h                                                              ;Is gain direct?
    JNZ     short .GainMode                                                     ;   No, program envelope
        Mov     dword [EBX+eAdj],A_DIRECT                                       ;Set adjustment rate to 1.0

        And     AL,7Fh                                                          ;Isolate direct value
        Mov     EDX,EAX                                                         ;Adjust value for internal precision
        ShR     DL,7-E_SHIFT                                                    ;EAX = LEVEL * A_GAIN + LEVEL / 128 * A_GAIN
        ShL     EAX,E_SHIFT                                                     ; If LEVEL = 0x00, EAX = 0
        Add     EAX,EDX                                                         ; If LEVEL = 0x7F, EAX = D_MAX (128 * A_GAIN - 1)
        Mov     [EBX+eDest],EAX                                                 ;  EAX = 127 * A_GAIN + 127 / 128 * A_GAIN

        Mov     byte [EBX+eRIdx],31                                             ;Envelope is set
        Mov     ESI,[31*4+rateTab]
        Mov     [EBX+eRate],ESI
        Mov     [EBX+eCnt],ESI

        Mov     DL,[EBX+eMode]
        And     DL,70h
        Or      DL,E_DIRECT                                                     ;Set mode to direct
        Mov     [EBX+eMode],DL
        RetN

    .GainMode:
        Mov     DL,AL
        Mov     AH,E_IDLE
        And     AL,1Fh                                                          ;Is index zero?
        JZ      short .GainNext

        XOr     AH,AH
        Cmp     [EBX+eRIdx],AL
        JE      short .GainNext

        Mov     [EBX+eRIdx],AL
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Mov     ESI,[R8+RAX*4]
%else
        Mov     ESI,[EAX*4+rateTab]
%endif
        Mov     [EBX+eRate],ESI                                                 ;Set rate of change
        Mov     [EBX+eCnt],ESI

    .GainNext:
        Mov     AL,[EBX+eMode]                                                  ;Preserve ADSR mode
        And     AL,70h
        Or      AL,AH

        Test    DL,60h                                                          ;Jump to the right mode
        JZ      short .GainDec
        Test    DL,40h
        JZ      short .GainExp
        Test    DL,20h
        JZ      short .GainInc

    .GainBent:
        Mov     dword [EBX+eAdj],A_LIN
        Mov     dword [EBX+eDest],D_BENT
        Or      AL,E_BENT                                                       ;Set mode to bent line increase
        Mov     [EBX+eMode],AL
        RetN

    .GainInc:
        Mov     dword [EBX+eAdj],A_LIN
        Mov     dword [EBX+eDest],D_MAX
        Or      AL,E_INC                                                        ;Set mode to linear increase
        Mov     [EBX+eMode],AL
        RetN

    .GainExp:
        Mov     dword [EBX+eAdj],A_EXP
        Mov     dword [EBX+eDest],D_MIN
        Or      AL,E_EXP                                                        ;Set mode to exponential decrease
        Mov     [EBX+eMode],AL
        RetN

    .GainDec:
        Mov     dword [EBX+eAdj],A_LIN
        Mov     dword [EBX+eDest],D_MIN
        Or      AL,E_DEC                                                        ;Set mode to linear decrease
        Mov     [EBX+eMode],AL
        RetN
%endif
ENDP


;===================================================================================================
;Change Envelope
;
;Called when the ADSR registers are written to while an envelope is in progress.  Control is
;transfered to StartEnv where the envelope is updated.
;
;In:
;   EBX = Voice << 4
;
;Destroys:
;   EAX,EDX,EBX

PROC ChgADSR

    Push    ESI                                                                 ;ESI will get popped on return from StartEnv
%ifdef HOST64
    Lea     R8,[rel dsp]
    LEA     RSI,[R8+RBX]
    Lea     R9,[rel mix]
    LEA     RBX,[R9+RBX*8]
%else
    LEA     ESI,[EBX+dsp]
    LEA     EBX,[EBX*8+mix]
%endif

    XOr     EAX,EAX
%ifdef HOST64
    Mov     DL,[RBX+eMode]
%else
    Mov     DL,[EBX+eMode]
%endif
    And     DL,0Fh

    Cmp     DL,E_ATT                                                            ;If the envelope isn't in attack, decay, or sustain
    JE      ChgAtt                                                              ; mode, changes to the ADSR registers have no effect
    Cmp     DL,E_DECAY
    JE      ChgDec
    Cmp     DL,E_SUST
    JE      ChgSus

    Pop     ESI                                                                 ;No changes were made, pop ESI and return

ENDP


;===================================================================================================
;DSP Data Port

;--------------------------------------------
;External procedure for users of SNESAPU.DLL
;
;Out:
;   EAX = not 0: success, 0: failure

PROC SetDSPReg, dReg, dVal
USES ECX,EDX,EBX

    MovZX   EBX,byte [dReg]
    MovZX   EAX,byte [dVal]

    XOr     CL,CL                                                               ;CL = Don't emulate DSP
    Call    DSPInB                                                              ;Process register write without calling debug function

ENDP


;--------------------------------------------
;Internal procedure for initialzing DSP registers
;
;In:
;   EBX = DSP register number
;   AL  = Write value
;
;Out:
;   EAX = DSP register is enabled
;
;Destroys:
;   EBX,EDX

PROC InitReg
USES ECX

    XOr     CL,CL                                                               ;CL = Don't emulate DSP
    Call    DSPInC                                                              ;Process register regardless of current register value

ENDP


;--------------------------------------------
;Procedure for writing to the DSP from the SPC700
;
;In:
;   EBX = DSP register number
;   AL  = Write value
;
;Out:
;   EAX = DSP register is enabled
;
;Destroys:
;   EBX,EDX

PROC DSPIn

%if DEBUG
%ifdef HOST64
    Mov     RDX,[pTrace]
    Test    RDX,RDX
%else
    Mov     EDX,[pTrace]
    Test    EDX,EDX
%endif
    JZ      short .NoDbg
        MovZX   EAX,AL
%ifdef HOST64
        Lea     R8,[rel dsp]
        Add     RBX,R8

        Push    ECX,ESI,EDI                                                     ;Save these registers
        Push    EAX                                                             ;Pass these as parameters
        Push    EBX

        Call    EDX

        Pop     EBX
        Pop     EAX
        Pop     EDI,ESI,ECX
%else
        Add     EBX,dsp

        Push    ECX,ESI,EDI                                                     ;Save these registers
        Push    EAX                                                             ;Pass these as parameters
        Push    EBX

        Call    EDX

        Pop     EBX
        Pop     EAX
        Pop     EDI,ESI,ECX
%endif

        MovZX   EBX,BL

    .NoDbg:
%endif

    Test    dword [apuCbMask],CBE_DSPREG
    JZ      short .NoCallback

%ifdef HOST64
    Mov     RDX,[apuCbFunc]
    Test    RDX,RDX
%else
    Mov     EDX,[apuCbFunc]
    Test    EDX,EDX
%endif
    JZ      short .NoCallback
    Test    BL,80h                                                              ;Writes to 80-FFh have no effect (reads are mirrored
    JNZ     short .NoCallback                                                   ; from lower mem)
        Push    ECX,EBX,EAX                                                     ;STDCALL is destroy EAX,ECX,EDX
        MovZX   EBX,BL
        MovZX   EAX,AL
        Call    EDX,CBE_DSPREG,EBX,EAX,0
        Mov     BL,AL                                                           ;Copy overwrote value
        Pop     EAX
        Mov     AL,BL
        Pop     EBX,ECX

    .NoCallback:
    Mov     CL,1                                                                ;CL = Emulate DSP to catch up to current state

DSPInB:
    Test    BL,80h                                                              ;Writes to 80-FFh have no effect (reads are mirrored
    JNZ     DSPDone                                                             ; from lower mem)

    Cmp     BL,kon
    JNE     short .NoKOn
        Mov     [dbgDSPInBKonBL],BL
        Mov     [dbgDSPInBKonAL],AL
        Inc     dword [dbgDSPInBKonCount]
        Jmp     RKOn
    .NoKOn:
    Cmp     BL,kof                                                              ;Check for registers that can have duplicate data
    JE      RKOff                                                               ; written
    Cmp     BL,endx
    JE      REndX

%ifdef HOST64
    Lea     R8,[rel dsp]
    Cmp     AL,[R8+RBX]                                                         ;Is the new data the same as the current data?
    JZ      short DSPDone                                                       ;   Yes, don't bother updating

    Mov     [R8+RBX],AL                                                         ;Update DSP RAM

DSPInC:
    Lea     R9,[rel dspRegs]
    Mov     RDX,[R9+RBX*8]                                                      ;Get the pointer to the register handler
%else
    Cmp     AL,[EBX+dsp]                                                        ;Is the new data the same as the current data?
    JZ      short DSPDone                                                       ;   Yes, don't bother updating

    Mov     [EBX+dsp],AL                                                        ;Update DSP RAM

DSPInC:
    Mov     EDX,[EBX*4+dspRegs]                                                 ;Get the pointer to the register handler
%endif

    Mov     AH,BL
    And     EBX,70h
    Not     AH
    ShL     EBX,3                                                               ;EBX indexes mix (needed by some handlers)
    And     AH,MFLG_OFF                                                         ;AH = 08h if the register is in dsp.voice

%ifdef HOST64
    Push    RDI
    Lea     RDI,[rel mix]
    Test    [RDI+RBX+mFlg],AH                                                   ;Is the voice inactive?
    Pop     RDI
%else
    Test    [EBX+mix+mFlg],AH                                                   ;Is the voice inactive?
%endif
    JNZ     short DSPDone                                                       ;   Yes, don't bother updating

%if DSPBK && DSPINTEG
    Test    CL,CL                                                               ;If write was from SPC700, emulate DSP before
    JZ      short .NoOutput                                                     ; processing new register data
        Call    CatchUp

    .NoOutput:
%endif

%ifdef HOST64
    Jmp     RDX
%else
    Jmp     EDX
%endif

DSPDone:
    XOr     EAX,EAX                                                             ;DSP state didn't change

ENDP


;===================================================================================================
;Emulate the KON/KOFF delay processing of DSP
;
;Destroys:
;   EAX,EBX,ECX,EDX

%macro CatchKOff 0
    ;KOff process ----------------------
    MovZX   ECX,byte [koffRsv]                                                  ;Set CH = 0 for use with CatchKOn
    Test    CL,CL
    JZ      short %%Done

    Push    ESI

    Mov     CH,1
%ifdef HOST64
    Lea     RBX,[rel mix]
    Lea     RSI,[rel dsp]
    Lea     R8,[rel rateTab]
    Mov     EDX,[R8+31*4]
%else
%ifdef HOST64
    Lea     RBX,[rel mix]
    Lea     RSI,[rel dsp]
%else
%ifdef HOST64
    Lea     EBX,[rel mix]
%else
%ifdef HOST64
    Lea     EBX,[rel mix]
%else
    Mov     EBX,mix
%endif
%endif
    Mov     ESI,dsp
%endif
    Mov     EDX,[31*4+rateTab]
%endif
    XOr     EAX,EAX

    %%Next:
        Test    CL,CH
        JZ      short %%Skip

        Test    [voiceMix],CH                                                   ;Is voice currently playing?
        JZ      short %%Skip                                                    ;   No, do nothing

        Test    byte [RBX+mFlg],MFLG_KOFF                                       ;Is already voice in key off mode?
        JNZ     short %%Skip                                                    ;   Yes, do nothing
            Mov     byte [RBX+eRIdx],31                                         ;Place envelope in release mode
            Mov     [RBX+eRate],EDX
            Mov     [RBX+eCnt],EDX
            Mov     dword [RBX+eAdj],A_KOFF
            Mov     dword [RBX+eDest],D_MIN
            Mov     byte [RBX+eMode],E_REL
            Or      byte [RBX+mFlg],MFLG_KOFF                                   ;Flag voice as keying off
            Mov     [RBX+vRsv],AL                                               ;Reset ADSR/Gain changed flag
            Mov     [RBX+mKOn],AL                                               ;Reset delay time

        %%Skip:
%ifdef HOST64
        Add     RSI,10h
        Sub     RBX,-80h
%else
        Add     ESI,10h
        Sub     EBX,-80h
%endif

    Add     CH,CH
    JNZ     %%Next

    Pop     ESI

    %%Done:
    Mov     [koffRsv],CH                                                        ;CH = 0
%endmacro

%macro CatchKOn 0
    ;KOn process -----------------------
    Mov     CL,[konRsv]
    Or      CL,[konRun]
    JZ      %%Done

%ifdef HOST64
    Push    RDI
%endif
    Push    ESI

    Mov     CL,[konRsv]
    Mov     CH,1
%ifdef HOST64
    Lea     R9,[rel mix]
    Lea     RBX,[rel mix]
    Lea     RSI,[rel dsp]
    Lea     R10,[rel scr700det]
%else
    Mov     EBX,mix
    Mov     ESI,dsp
%endif

    %%Next:
%if INTBK
%ifdef HOST64
        Lea     RDI,[rel dsp]
%endif
        Test    byte [RBX+mKOn],-1                                              ;Is already voice in key on mode?
        JNZ     short %%CheckKOff                                               ;   Yes
            Test    CL,CH
            JZ      %%Skip

            XOr     EDX,EDX
            And     byte [RBX+mFlg],MFLG_USER                                   ;Leave user voice flags (mute and noise)
            Mov     byte [RBX+mKOn],KON_DELAY                                   ;Set delay time from writing KON to output
            Mov     [RBX+eVal],EDX                                              ;Reset envelope and wave height, because noise may be
            Mov     [RBX+mOut],EDX                                              ; mixed in when the channel volume is changed immediately
            Mov     [RSI+envx],DL                                               ; after KON.
            Mov     [RSI+outx],DL

            Or      [konRun],CH                                                 ;Start KON working
            Not     CH
%ifdef HOST64
            And     [RDI+endx],CH                                               ;Clear ENDX register if started KON
%else
            And     [dsp+endx],CH                                               ;Clear ENDX register if started KON
%endif
            Not     CH
            Jmp     %%Skip

        %%CheckKOff:
        Cmp     byte [RBX+mKOn],KON_CHKKOFF                                     ;Did time for checked KOFF after KON had been written?
        JA      short %%CheckEnv                                                ;   No

%ifdef HOST64
        Test    [RDI+kof],CH                                                    ;Is KOFF still written?
%else
        Test    [dsp+kof],CH                                                    ;Is KOFF still written?
%endif
        JZ      short %%CheckEnv                                                ;   No
            Or      byte [RBX+mFlg],MFLG_KOFF                                   ;Flag voice as keying off
            Mov     byte [RBX+mKOn],0                                           ;Reset delay time

            Not     CH
            And     [konRun],CH                                                 ;Cancel KON working
            Not     CH
            Jmp     %%Skip

        %%CheckEnv:
        Cmp     byte [RBX+mKOn],KON_SAVEENV                                     ;Did time for saved envelope pass after KON had been
        JNE     short %%StartKON                                                ; written?  No
            Mov     DX,[RSI+adsr]                                               ;Save ADSR parameters
            Mov     [RBX+vAdsr],DX
            MovZX   DX,byte [RSI+gain]                                          ;Save Gain parameters
            Mov     [RBX+vGain],DL
            Mov     [RBX+vRsv],DH                                               ;Reset ADSR/Gain changed flag

        %%StartKON:
        Dec     byte [RBX+mKOn]                                                 ;Did time for enabled voice pass after KON had been
        JNZ     %%Skip                                                          ; written?  No, do nothing
            And     byte [RBX+mFlg],MFLG_USER                                   ;Leave user voice flags (mute and noise)
%else
        Test    CL,CH
        JZ      %%Skip
            XOr     EDX,EDX
            And     byte [RBX+mFlg],MFLG_USER                                   ;Leave user voice flags (mute and noise)
            Or      byte [RBX+mFlg],MFLG_KOFF                                   ;Flag voice as keying off
            Mov     [RBX+mKOn],DL                                               ;Start playing immediately

%ifdef HOST64
        Test    [RDI+kof],CH                                                    ;Is KOFF still written?
%else
        Test    [dsp+kof],CH                                                    ;Is KOFF still written?
%endif
        JNZ     %%Skip                                                          ;   No
            And     byte [RBX+mFlg],~MFLG_KOFF                                  ;Cancel keying off flag

            Or      [konRun],CH                                                 ;Start KON working
            Not     CH
%ifdef HOST64
            And     [RDI+endx],CH                                               ;Clear ENDX register if started KON
%else
            And     [dsp+endx],CH                                               ;Clear ENDX register if started KON
%endif
            Not     CH

            Mov     DX,[RSI+adsr]                                               ;Save ADSR parameters
            Mov     [RBX+vAdsr],DX
            MovZX   DX,byte [RSI+gain]                                          ;Save Gain parameters
            Mov     [RBX+vGain],DL
            Mov     [RBX+vRsv],DH                                               ;Reset ADSR/Gain changed flag
%endif

            ;Set voice volume ------------------
%if STEREO
%ifdef HOST64
            Sub     RBX,R9
%else
            Sub     EBX,mix
%endif
            Call    RVolL
%ifdef HOST64
            Add     RBX,R9
%else
            Add     EBX,mix
%endif
            Mov     EAX,[RBX+mTgtL]
            Mov     [RBX+mChnL],EAX
            Mov     EAX,[RBX+mTgtR]
            Mov     [RBX+mChnR],EAX
%else
%ifdef HOST64
            Sub     RBX,R9
            Mov     AL,[RSI+volL]
%else
            Sub     EBX,mix
            Mov     AL,[ESI+volL]
%endif
            Call    RVolL
%ifdef HOST64
            Mov     AL,[RSI+volR]
%else
            Mov     AL,[ESI+volR]
%endif
            Call    RVolR
%ifdef HOST64
            Add     RBX,R9
%else
            Add     EBX,mix
%endif
%endif

            ;Set pitch -------------------------
            MovZX   EAX,word [RSI+pitch]
            Test    dword [dspOpts],DSP_NOPLMT                                  ;If do not remove the pitch limit, the highest
            SetZ    DL                                                          ; pitch value is 3FFF
            Dec     DL
            Or      DL,3Fh
            And     AH,DL
            Mov     [RBX+mOrgP],EAX
            MovZX   EDX,byte [RSI+srcn]                                         ;EDX = Source
            Mov     [RBX+mSrc],DL                                               ;Save source number
%ifdef HOST64
            Add     EAX,[R10+RDX*4]                                             ;EAX += Detune[EDX]
%else
            Add     EAX,[scr700det+EDX*4]                                       ;EAX += Detune[EDX]
%endif

            Mul     dword [pitchAdj]
            ShRD    EAX,EDX,16
            AdC     EAX,0
            Mov     [RBX+mRate],EAX
            Mov     word [RBX+mDec],0

            ;Key ON ----------------------------
            Mov     AX,[RSI+adsr]                                               ;Save now ADSR/Gain parameters
            Mov     DL,[RSI+gain]
            Push    EAX,EDX
            Mov     AX,[RBX+vAdsr]                                              ;Restore ADSR/Gain parameters
            Mov     [RSI+adsr],AX
            Mov     DL,[RBX+vGain]
            Mov     [RSI+gain],DL

            Call    StartSrc                                                    ;Start waveform decompression
            Call    StartEnv                                                    ;Start envelope

            Pop     EDX,EAX                                                     ;Restore ADSR/Gain parameters
            Mov     [RSI+adsr],AX
            Mov     [RSI+gain],DL

            Or      [voiceMix],CH                                               ;Mark voice as being on internally
            Not     CH
            And     [konRun],CH                                                 ;KON working was finished
            Not     CH

        %%Skip:
        Add     RSI,10h
        Sub     RBX,-80h

    Add     CH,CH
    JNZ     %%Next

    Pop     ESI                                                                 ;Now, CH = 0
%ifdef HOST64
    Pop     RDI
%endif

    %%Done:
    Mov     [konRsv],CH
%endmacro


;===================================================================================================
;Set the Denormalized Numbers to 0
;
;Calculating denormalized numbers requires a many number of CPU clocks.  If the CPU does not support
;denormalized numbers, will take more processing time more because using software emulation.
;
;However, when it comes to audio data, denormalized numbers have very small outputs that are
;inaudible, so they can be treated as 0.
;
;Destroys:
;   EAX
%macro ZeroDN 1
    Mov     EAX,[%1]
    And     EAX,7F800000h                                                       ;Is the exponent part zero (denormalized)?
    JNZ     short %%Normal                                                      ;   No
        Mov     [%1],EAX                                                        ;EAX = 0

    %%Normal:
%endmacro

%macro ZeroDNEFB 1
    FLd     dword [%1]
    FMul    dword [fpShR19]
%ifdef HOST64
    FStP    dword [RSP-4]
    ZeroDN  RSP-4
%else
    FStP    dword [ESP-4]
    ZeroDN  ESP-4
%endif
%endmacro


;===================================================================================================
;DSP Register Handlers

;============================================
;End block decoded

REndX:
%if DSPBK && DSPINTEG
    Test    CL,CL                                                               ;If write was from SPC700, emulate DSP before
    JZ      short .NoOutput                                                     ; processing new register data
        Call    CatchUp
    .NoOutput:
%endif

    XOr     EAX,EAX
    Or      AL,[dsp+endx]
    Mov     [dsp+endx],AH                                                       ;Reset the ENDX register
    SetNZ   AL
    Ret

;============================================
;Key Off

RKOff:
%if DSPBK && DSPINTEG
    Test    CL,CL                                                               ;If write was from SPC700, emulate DSP before
    JZ      short .NoOutput                                                     ; processing new register data
        Call    CatchUp
    .NoOutput:
%endif

    MovZX   EAX,AL
    Mov     [dsp+kof],AL
    Mov     [koffRsv],AL

%if DSPBK && DSPINTEG
    Push    EAX,EBX,ECX,EDX
    CatchKOff
    Pop     EDX,ECX,EBX,EAX
%endif

    Ret

;============================================
;Key On

RKOn:
    Mov     [dbgRKOnBL],BL
    Mov     [dbgRKOnPreAL],AL
%if DSPBK && DSPINTEG
    Test    CL,CL                                                               ;If write was from SPC700, emulate DSP before
    JZ      short .NoOutput                                                     ; processing new register data
        Call    CatchUp
    .NoOutput:
%endif
    Mov     [dbgRKOnPostAL],AL
    Inc     dword [dbgRKOnCount]

    MovZX   EAX,AL
    Mov     [dsp+kon],AL
    Mov     [konRsv],AL

%if DSPBK && DSPINTEG
    Push    EAX,EBX,ECX,EDX
    Mov     CH,AH                                                               ;Set CH = 0 for use with CatchKOn
    CatchKOn
    Pop     EDX,ECX,EBX,EAX
%endif

    Ret

%if INTBK && DSPINTEG
ResetKON:
    XOr     CH,CH                                                               ;Set CH = 0 for use with CatchKOn
    CatchKOn
    Ret
%endif

;============================================
;Voice volume

%if STEREO=0
RVolL:
    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH
    MovSX   EAX,AL

%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FMul    dword [fpShR7]                                                      ;Convert volume from fixed to floating-point
    FSt     dword [EBX+mix+mTgtL]
    FStP    dword [EBX+mix+mChnL]

    XOr     EAX,EAX
    Inc     EAX
    Ret

RVolR:
    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH
    MovSX   EAX,AL

%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FMul    dword [fpShR7]
    FSt     dword [EBX+mix+mTgtR]
    FStP    dword [EBX+mix+mChnR]

    XOr     EAX,EAX
    Inc     EAX
    Ret
%endif

;============================================
;Pitch

RPitch:
    XOr     EAX,EAX
    Test    dword [dspOpts],DSP_NOPREAD                                         ;Is pitch read enabled?
    JNZ     short .NoRead                                                       ;   No
        ShR     EBX,3
%ifdef HOST64
        Lea     R8,[rel dsp]
        MovZX   EAX,word [R8+RBX+pitch]
%else
        MovZX   EAX,word [EBX+dsp+pitch]
%endif
        Test    dword [dspOpts],DSP_NOPLMT                                      ;If do not remove the pitch limit, the highest
        SetZ    DL                                                              ; pitch value is 3FFF
        Dec     DL
        Or      DL,3Fh
        And     AH,DL
        ShL     EBX,3
%ifdef HOST64
        Lea     R9,[rel mix]
        Lea     R10,[rel scr700det]
        Mov     [R9+RBX+mOrgP],EAX

        MovZX   EDX,byte [R9+RBX+mSrc]                                          ;EDX = Source
        Add     EAX,[R10+RDX*4]                                                 ;EAX += Detune[EDX]
%else
        Mov     [EBX+mix+mOrgP],EAX

        MovZX   EDX,byte [EBX+mix+mSrc]                                         ;EDX = Source
        Add     EAX,[scr700det+EDX*4]                                           ;EAX += Detune[EDX]
%endif

        Mul     dword [pitchAdj]                                                ;Convert the pitch into a more meaningful value
        ShRD    EAX,EDX,16                                                      ;Remove 16-bit fraction from pitchAdj
        AdC     EAX,0
%ifdef HOST64
        Mov     [R9+RBX+mRate],EAX
%else
        Mov     [EBX+mix+mRate],EAX
%endif

        XOr     EAX,EAX
        Inc     EAX

    .NoRead:
    Ret

;============================================
;Envelope

RADSR:
    XOr     EAX,EAX
%ifdef HOST64
    Lea     R8,[rel mix]
    Test    byte [R8+RBX+mFlg],MFLG_KOFF                                        ;Is voice in key off mode?
%else
    Test    byte [EBX+mix+mFlg],MFLG_KOFF                                       ;Is voice in key off mode?
%endif
    JNZ     short .NoChg                                                        ;   Yes, envelope setting can't be changed now

%ifdef HOST64
    Test    byte [R8+RBX+mKOn],-1
%else
    Test    byte [EBX+mix+mKOn],-1
%endif
    SetNZ   AL
%ifdef HOST64
    Or      [R8+RBX+vRsv],AL
%else
    Or      [EBX+mix+vRsv],AL
%endif
    Test    AL,AL                                                               ;Has time passed since KON was written?
    JNZ     short .NoChg                                                        ;   No, update ADSR parameters later
%ifdef HOST64
        Mov     AL,[R8+RBX+eMode]                                               ;AL = ADSR or Gain mode
%else
        Mov     AL,[EBX+mix+eMode]                                              ;AL = ADSR or Gain mode
%endif
        ShR     EBX,3
        And     AL,E_ADSR
%ifdef HOST64
        Push    RDI
        Lea     RDI,[rel dsp]
        Mov     AH,[RDI+RBX+adsr]
        Pop     RDI
%else
        Mov     AH,[EBX+dsp+adsr]
%endif
        And     AH,80h
        Or      AL,AH

        Test    AL,80h + E_ADSR
        JZ      short .NoChg                                                    ;Envelope is already in gain mode, do nothing
        Test    AL,80h
        JZ      short .SetGain                                                  ;Switched from ADSR to Gain
        Test    AL,E_ADSR
        JNZ     short .Change                                                   ;Envelope is in ADSR mode, update settings

%ifdef HOST64
        Lea     R8,[rel mix]
        Mov     AL,[R8+RBX*8+eMode]                                             ;Switched from Gain to ADSR, restore previous ADSR
        ShR     AL,4                                                            ; state then update settings
        Or      AL,E_ADSR
        Mov     [R8+RBX*8+eMode],AL
%else
        Mov     AL,[EBX*8+mix+eMode]                                            ;Switched from Gain to ADSR, restore previous ADSR
        ShR     AL,4                                                            ; state then update settings
        Or      AL,E_ADSR
        Mov     [EBX*8+mix+eMode],AL
%endif

        .Change:
        Call    ChgADSR
        XOr     EAX,EAX
        Inc     EAX

    .NoChg:
    Ret

    .SetGain:
        ShL     EBX,3
%ifdef HOST64
        Lea     R8,[rel mix]
        ShL     byte [R8+RBX+eMode],4                                           ;Save ADSR state, ChgGain will set bits 7 and 3-0
%else
        ShL     byte [EBX+mix+eMode],4                                          ;Save ADSR state, ChgGain will set bits 7 and 3-0
%endif

RGain:
    XOr     EAX,EAX
%ifdef HOST64
    Lea     R8,[rel mix]
    Test    byte [R8+RBX+mFlg],MFLG_KOFF                                        ;Is voice in key off mode?
%else
    Test    byte [EBX+mix+mFlg],MFLG_KOFF                                       ;Is voice in key off mode?
%endif
    JNZ     short .NoChg                                                        ;   Yes, envelope setting can't be changed now

%ifdef HOST64
    Test    byte [R8+RBX+mKOn],-1
%else
    Test    byte [EBX+mix+mKOn],-1
%endif
    SetNZ   AL
    Add     AL,AL
%ifdef HOST64
    Or      [R8+RBX+vRsv],AL
%else
    Or      [EBX+mix+vRsv],AL
%endif
    Test    AL,AL                                                               ;Has time passed since KON was written?
    JNZ     short .NoChg                                                        ;   No, update GAIN parameters later

    ShR     EBX,3
%ifdef HOST64
    Lea     R9,[rel dsp]
    Test    byte [R9+RBX+adsr],80h                                              ;Is envelope in gain mode?
%else
        Test    byte [EBX+dsp+adsr],80h                                             ;Is envelope in gain mode?
%endif
    JNZ     short .NoChg                                                        ;   No, setting gain register has no effect
%ifdef HOST64
        Lea     RDX,[rel .Return]
        Push    EDX
%else
        Push    .Return
%endif
        Push    ESI                                                             ;StartEnv will pop ESI on return
%ifdef HOST64
        LEA     RSI,[R9+RBX]
        Lea     R8,[rel mix]
        LEA     RBX,[R8+RBX*8]
%else
        LEA     ESI,[EBX+dsp]
        LEA     EBX,[EBX*8+mix]
%endif
        Jmp     ChgGain                                                         ;Begin ADSR envelope

        .Return:
        XOr     EAX,EAX
        Inc     EAX

    .NoChg:
    Ret

;============================================
;Main volumes

RMVolL:
    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH
    MovSX   EAX,AL

%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FIMul   dword [volAdj]
    FMul    dword [fpShR7]                                                      ;>> 7 to turn MVOL into a float
    FStP    dword [volMainL]                                                    ;Leave the 16-bits added by volAdj so the final

    XOr     EAX,EAX                                                             ; output will be 32-bit instead of 16-bit
    Inc     EAX
    Ret

RMVolR:
    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH

    XOr     AL,[surround]
    Sub     AL,[surround]
    Cmp     AL,80h
    SetE    AH
    And     AH,[surround]
    Sub     AL,AH
    MovSX   EAX,AL

%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FIMul   dword [volAdj]
    FMul    dword [fpShR7]
    FStP    dword [volMainR]

    XOr     EAX,EAX
    Inc     EAX
    Ret

REVolL:
    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH
    MovSX   EAX,AL

%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FIMul   dword [volAdj]
    FMul    dword [fpShR7]
    FStP    dword [volEchoL]

    XOr     EAX,EAX
    Inc     EAX
    Ret

REVolR:
    Test    AL,[surroff]
    SetZ    AH
    Dec     AH
    XOr     AL,AH
    Sub     AL,AH
    Mov     AH,[surroff]
    Cmp     AX,8080h
    SetE    AH
    Sub     AL,AH

    XOr     AL,[surround]
    Sub     AL,[surround]
    Cmp     AL,80h
    SetE    AH
    And     AH,[surround]
    Sub     AL,AH
    MovSX   EAX,AL

%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FIMul   dword [volAdj]
    FMul    dword [fpShR7]
    FStP    dword [volEchoR]

    XOr     EAX,EAX
    Inc     EAX
    Ret

;============================================
;Echo settings

REFB:
    MovSX   EAX,AL
%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif

%if STEREO
    FLd     ST
    FIMul   dword [efbct]
    FMul    dword [fpShR23]                                                     ;Convert from fixed to floating-point
    FStP    dword [echoFB]                                                      ;7-bits (efb) + 16-bits (efbct) = 23-bits

    FLd     dword [fp64k]
    FISub   dword [efbct]
    FMulP   ST1,ST
    FMul    dword [fpShR23]
    FStP    dword [echoFBCT]
%else
    FMul    dword [fpShR7]
    FStP    dword [echoFB]
%endif

    XOr     EAX,EAX
    Inc     EAX
    Ret

REDl:
    Push    ECX
    Mov     AL,byte [dsp+edl]
    And     EAX,0Fh
    ShL     EAX,9                                                               ;EAX = Number of samples to delay
    Push    EAX

    Test    EAX,EAX                                                             ;If EAX = 0, EAX = 1
    SetZ    CL
    Or      AL,CL
    ShL     EAX,2                                                               ;Multiply by 4, since original echo is stored in
    Mov     [echoLenM],EAX                                                      ; 16-bit stereo

%if ECHOMEM=0
    ;Normally, the current pointer is NOT initialized by changing the EDL, but when the playing speed
    ;is set other than 100%, the current pointer is initialized to rewrite memory in unexpected places.
    Mov     [echoMaxM],EAX
    Mov     [echoCurM],EAX
%endif

    Pop     EAX
    Mul     dword [dspRate]                                                     ;EAX *= Rate / 32kHz
    Mov     ECX,32000
    Div     ECX

    Test    EAX,EAX                                                             ;If EAX = 0, EAX = 1
    SetZ    CL
    Or      AL,CL
    ShL     EAX,3                                                               ;Multiply by 8, since SNESAPU echo is stored in
    Mov     [echoLenD],EAX                                                      ; 32-bit stereo
    Pop     ECX

    XOr     EAX,EAX
    Inc     EAX
    Ret

RFCf:
    ShR     EBX,5
    MovSX   EAX,AL
%ifdef HOST64
    Mov     [RSP-4],EAX
    FILd    dword [RSP-4]
%else
    Mov     [ESP-4],EAX
    FILd    dword [ESP-4]
%endif
    FMul    dword [fpShR7]
%ifdef HOST64
    Lea     R8,[rel firTaps]
    FStP    dword [R8+RBX]
%else
    FStP    dword [EBX+firTaps]
%endif

    XOr     EAX,EAX                                                             ;DSP state changed if echo was enabled
    Inc     EAX
    Ret

;============================================
;Other

RPMOn:
    ;Reset all pitch on all voices -----------
    Push    ECX
%ifdef HOST64
    Lea     RBX,[rel mix]
    Lea     R8,[rel scr700det]
%else
    Mov     EBX,mix
%endif
    Mov     CL,8

	    .Next:
%ifdef HOST64
	        Mov     EAX,[RBX+mOrgP]
	        MovZX   EDX,byte [RBX+mSrc]                                             ;EDX = Source
	        Add     EAX,[R8+RDX*4]                                                  ;EAX += Detune[EDX]
%else
	        Mov     EAX,[EBX+mOrgP]
	        MovZX   EDX,byte [EBX+mSrc]                                             ;EDX = Source
	        Add     EAX,[scr700det+EDX*4]                                           ;EAX += Detune[EDX]
%endif
	
	        Mul     dword [pitchAdj]
	        ShRD    EAX,EDX,16
	        AdC     EAX,0
%ifdef HOST64
	        Mov     [RBX+mRate],EAX
	        Sub     RBX,-80h
%else
	        Mov     [EBX+mRate],EAX
	        Sub     EBX,-80h
%endif
	
	    Dec     CL
	    JNZ     short .Next
	    Pop     ECX

    XOr     EAX,EAX
    Inc     EAX
    Ret

RFlg:
    Test    AL,80h                                                              ;Has a soft reset been initialized?
    JZ      short .NoSRst                                                       ;   No
%ifdef HOST64
        Lea     RBX,[rel dsp]
        XOr     EDX,EDX
%else
        Mov     EBX,dsp
%endif
        And     AL,~80h
        Or      AL,60h                                                          ;Turn on mute and disable echo
%ifdef HOST64
        Mov     [RBX+flg],AL
        Mov     [RBX+endx],DL                                                   ;Clear end block flags
        Mov     [RBX+kon],DL
        Mov     [RBX+kof],DL
%else
        Mov     [EBX+flg],AL
        Mov     [EBX+endx],BL                                                   ;Clear end block flags
        Mov     [EBX+kon],BL
        Mov     [EBX+kof],BL
%endif
%ifdef HOST64
        Mov     [voiceMix],DL
%else
        Mov     [voiceMix],BL
%endif

        ;Reset internal voice settings --------
%ifdef HOST64
        Lea     RBX,[rel mix+mFlg]
%else
        Mov     EBX,mix+mFlg
%endif
        Mov     AL,8

	        .MFlg:
%ifdef HOST64
	            And     byte [RBX],MFLG_USER                                        ;Leave user voice flags (mute and noise)
	            Or      byte [RBX],MFLG_OFF                                         ;Set voice to inactive
	            Sub     RBX,-80h
%else
	            And     byte [EBX],MFLG_USER                                        ;Leave user voice flags (mute and noise)
	            Or      byte [EBX],MFLG_OFF                                         ;Set voice to inactive
	            Sub     EBX,-80h
%endif
	
	        Dec     AL
	        JNZ     .MFlg
    .NoSRst:

    ;Update noise clock ----------------------
    Mov     dword [nRate],0
    And     EAX,1Fh
    JZ      short .NoNoise
        Mov     EBX,EAX
        Mov     EAX,-1
        Mov     EDX,65535
%ifdef HOST64
        Lea     R8,[rel rateTab]
        Div     dword [R8+RBX*4]
%else
        Div     dword [EBX*4+rateTab]
%endif
        Mov     [nRate],EAX

    .NoNoise:
    XOr     EAX,EAX
    Inc     EAX
    Ret

;============================================
;Null register

RNull:
    XOr     EAX,EAX
    Ret


;===================================================================================================
;No Interpolation

PROC NoneInt

%ifdef HOST64
    FILd    word [RSI]
%else
    FILd    word [ESI]
%endif

ENDP


;===================================================================================================
;Linear Interpolation

PROC LinearInt

%ifdef HOST64
	    FILd    word [RSI-2]
	    FILd    word [RSI]
	    Mov     [RSP-4],EAX
	    FSub    ST,ST1                                                              ;Difference between samples
	    FIMul   dword [RSP-4]                                                       ;Multiply by delta x from last sample
%else
	    FILd    word [ESI-2]
	    FILd    word [ESI]
	    Mov     [ESP-4],EAX
	    FSub    ST,ST1                                                              ;Difference between samples
	    FIMul   dword [ESP-4]                                                       ;Multiply by delta x from last sample
%endif
	    FMul    dword [fpShR16]
	    FAddP   ST1,ST

ENDP


;===================================================================================================
;Cubic/Gauss (Use 4-point) Interpolation

PROC Point4Int

    ShR     EAX,8                                                               ;EAX indexes interpolation table value
%ifdef HOST64
	    Lea     R8,[rel interTab]
	    LEA     RAX,[R8+RAX*8]
	    FILd    word [RSI-6]                                                        ;Get first sample
	    FIMul   word [RAX+0]
	    FILd    word [RSI-4]
	    FIMul   word [RAX+2]
	    FILd    word [RSI-2]
	    FIMul   word [RAX+4]
	    FILd    word [RSI]
	    FIMul   word [RAX+6]
%else
	    LEA     EAX,[EAX*8+interTab]
	    FILd    word [ESI-6]                                                        ;Get first sample
    FIMul   word [EAX+0]
    FILd    word [ESI-4]
    FIMul   word [EAX+2]
    FILd    word [ESI-2]
    FIMul   word [EAX+4]
    FILd    word [ESI]
    FIMul   word [EAX+6]
%endif
    FAddP   ST1,ST
    FAddP   ST1,ST
    FAddP   ST1,ST
    FMul    dword [fpShR15]

ENDP


;===================================================================================================
;Sinc (Use 8-point) Interpolation

PROC Point8Int

    ShR     EAX,4                                                               ;EAX indexes interpolation table value
    And     EAX,-16
%ifdef HOST64
	    Lea     R8,[rel interTab]
	    Add     RAX,R8
	    FILd    word [RSI-14]
	    FIMul   word [RAX+0]
	    FILd    word [RSI-12]
	    FIMul   word [RAX+2]
	    FILd    word [RSI-10]
	    FIMul   word [RAX+4]
	    FILd    word [RSI-8]
	    FIMul   word [RAX+6]
	    FILd    word [RSI-6]
	    FIMul   word [RAX+8]
	    FILd    word [RSI-4]
	    FIMul   word [RAX+10]
	    FILd    word [RSI-2]
	    FIMul   word [RAX+12]
	    FILd    word [RSI-0]
	    FIMul   word [RAX+14]
%else
	    Add     EAX,interTab
    FILd    word [ESI-14]
    FIMul   word [EAX+0]
    FILd    word [ESI-12]
    FIMul   word [EAX+2]
    FILd    word [ESI-10]
    FIMul   word [EAX+4]
    FILd    word [ESI-8]
    FIMul   word [EAX+6]
    FILd    word [ESI-6]
    FIMul   word [EAX+8]
    FILd    word [ESI-4]
    FIMul   word [EAX+10]
    FILd    word [ESI-2]
    FIMul   word [EAX+12]
    FILd    word [ESI-0]
    FIMul   word [EAX+14]
%endif
    FAddP   ST1,ST
    FAddP   ST1,ST
    FAddP   ST1,ST
    FAddP   ST1,ST
    FAddP   ST1,ST
    FAddP   ST1,ST
    FAddP   ST1,ST
    FMul    dword [fpShR15]

ENDP


;===================================================================================================
;Noise Generator
;
;Generates white noise samples
;
;Out:
;   nSmp = Random 16-bit sample
;
;Destroys:
;   EAX,EDX

%macro NoiseGen 0
    Mov     EAX,[nRate]
    Add     [nAcc],EAX
    JNC     short %%NoNInc
        Mov     EAX,[nSeed]
        Add     EAX,EAX
        JNS     short %%NoiseOK
            XOr     EAX,40001h

        %%NoiseOK:
        Mov     [nSeed],EAX

        SAR     EAX,16
        Mov     [nSmp],EAX

    %%NoNInc:
    Test    dword [dspNoiseF],-1
    JZ      short %%NoNIncF
    Mov     EAX,[nfRate]
    Add     [nfAcc],EAX
    JNC     short %%NoNIncF
        IMul    EAX,[nfSmp],27865                                               ;X=(AX+C)%M  Where: X<M and 2<=A<M and 0<C<M
        Add     EAX,7263                                                        ;Add C
        CWDE                                                                    ;Modulus M (32768)
        Mov     [nfSmp],EAX

    %%NoNIncF:
%endmacro


;===================================================================================================
;Pitch Modulation
;
;Changes the pitch based on the output of the previous voice:
;
; P' = (P * (OUTX + 32768)) >> 15
;
;Pitch modulation in the SNES uses the full 16-bit sample value, not the 8-bit value in OUTX as
;previously believed.
;
;In:
;   CH  = Bitmask for current voice
;   EBX-> Current voice in 'mix'
;
;Destroys:
;   EAX,EDX

%macro PitchMod 0
    ;Adjust pitch by sample value ---------
%ifdef HOST64
    Mov     EAX,[RBX+mOut-80h]                                                  ;EAX = Wave height of last voice (-16.15)
%else
    Mov     EAX,[EBX+mOut-80h]                                                  ;EAX = Wave height of last voice (-16.15)
%endif
    Add     EAX,32768                                                           ;Unsign sample
%ifdef HOST64
    IMul    EAX,dword [RBX+mOrgP]                                               ;Apply sample height to pitch
%else
    IMul    EAX,dword [EBX+mOrgP]                                               ;Apply sample height to pitch
%endif
    SAR     EAX,15

    Push    ECX
    Test    dword [dspOpts],DSP_NOPLMT
    SetNZ   CL
    Add     CL,CL
    Add     CL,14

    ;Clamp pitch to 14-bits ---------------
    Mov     EDX,EAX
    SAR     EDX,CL
    JZ      short %%PitchOK
        SetS    AL
        MovZX   EAX,AL
        Dec     EAX
        Test    dword [dspOpts],DSP_NOPLMT                                      ;If do not remove the pitch limit, the highest
        SetZ    DL                                                              ; pitch value is 3FFF
        Dec     DL
        Or      DL,3Fh
        And     AH,DL
        MovZX   EAX,AX

    %%PitchOK:
    Pop     ECX

    ;Convert pitch to sample rate ---------
%ifdef HOST64
    MovZX   EDX,byte [RBX+mSrc]                                                 ;EDX = Source
%else
    MovZX   EDX,byte [EBX+mSrc]                                                 ;EDX = Source
%endif
%ifdef HOST64
    Lea     R8,[rel scr700det]
    Add     EAX,[R8+RDX*4]                                                     ;EAX += Detune[EDX]
%else
    Add     EAX,[scr700det+EDX*4]                                               ;EAX += Detune[EDX]
%endif

    Mul     dword [pitchAdj]
    ShRD    EAX,EDX,16
    AdC     EAX,0
%ifdef HOST64
    Mov     [RBX+mRate],EAX
%else
    Mov     [EBX+mRate],EAX
%endif
%endmacro


;===================================================================================================
;Process Sound Source
;
;Updates the current sample position and decompresses the next block if necessary
;
;In:
;   CH  = Bitmask for current voice
;   EBX-> Current voice in 'mix'
;
;Destroys:
;   EAX,EDX,CL,ESI

%macro UpdateSrc 0
    ;Update sample index ---------------------
%ifdef HOST64
    Mov     CL,[RBX+mRate+2]                                                    ;CL = Number of whole samples to increase index by
    Mov     EAX,[RBX+mRate]                                                     ;AX = Fraction of sample to increase index by
    Add     [RBX+mDec],AX                                                       ;Add AX to the decimal counter
%else
    Mov     CL,[EBX+mRate+2]                                                    ;CL = Number of whole samples to increase index by
    Mov     EAX,[EBX+mRate]                                                     ;AX = Fraction of sample to increase index by
    Add     [EBX+mDec],AX                                                       ;Add AX to the decimal counter
%endif
    AdC     CL,0                                                                ;Add carry, if any, to increase amount
    JZ      %%NoSInc                                                            ;If the amount is zero, index didn't increase

    ;Check for end of block ------------------
    Add     CL,CL                                                               ;CL <<= 1  (for 16-bit samples)
%ifdef HOST64
    Add     [RBX+sIdx],CL                                                       ;Increase sample index offset
    Test    byte [RBX+sIdx],20h                                                 ;Have we reached the end of the block?
%else
    Add     [EBX+sIdx],CL                                                       ;Increase sample index
    Test    byte [EBX+sIdx],20h                                                 ;Have we reached the end of the block?
%endif
    JZ      %%NoSInc                                                            ;   No
%ifdef HOST64
        And     byte [RBX+sIdx],~20h                                            ;Adjust sample index for wrap around
        Mov     EAX,[RBX+sBuf+16]                                               ;Copy last four samples of buffer
        Mov     EDX,[RBX+sBuf+20]                                               ; (needed for interpolation)
        Mov     [RBX+sBuf-16],EAX
        Mov     [RBX+sBuf-12],EDX
        Mov     EAX,[RBX+sBuf+24]
        Mov     EDX,[RBX+sBuf+28]
        Mov     [RBX+sBuf-8],EAX
        Mov     [RBX+sBuf-4],EDX
        Add     word [RBX+bCur],9                                               ;Move to next sample block offset

        Test    byte [RBX+bHdr],1                                               ;Was this the end block?
%else
        And     byte [EBX+sIdx],~20h                                            ;Adjust sample index for wrap around
        Mov     EAX,[EBX+sBuf+16]                                               ;Copy last four samples of buffer
        Mov     EDX,[EBX+sBuf+20]                                               ; (needed for interpolation)
        Mov     [EBX+sBuf-16],EAX
        Mov     [EBX+sBuf-12],EDX
        Mov     EAX,[EBX+sBuf+24]
        Mov     EDX,[EBX+sBuf+28]
        Mov     [EBX+sBuf-8],EAX
        Mov     [EBX+sBuf-4],EDX
        Add     word [EBX+bCur],9                                               ;Move to next sample block

        Test    byte [EBX+bHdr],1                                               ;Was this the end block?
%endif
        JZ      %%NotEndB                                                       ;   No, decompress next block
        Or      [dsp+endx],CH                                                   ;Set flag in ENDX
%ifdef HOST64
        Test    byte [RBX+bHdr],2                                               ;Is this source looped?
%else
        Test    byte [EBX+bHdr],2                                               ;Is this source looped?
%endif
        JNZ     short %%LoopB                                                   ;   Yes, start over at loop point

        ;End voice playback -------------------
        %%EndPlay:
            Not     CH
            And     [voiceMix],CH                                               ;Don't include voice in mixing process
            Not     CH

%ifdef HOST64
            Mov     dword [RBX+eVal],0                                          ;Reset envelope and wave height
            Mov     dword [RBX+mOut],0
            Or      byte [RBX+mFlg],MFLG_OFF                                    ;Set voice to inactive
            And     byte [RBX+mFlg],~MFLG_KOFF
%else
            Mov     dword [EBX+eVal],0                                          ;Reset envelope and wave height
            Mov     dword [EBX+mOut],0
            Or      byte [EBX+mFlg],MFLG_OFF                                    ;Set voice to inactive
            And     byte [EBX+mFlg],~MFLG_KOFF
%endif
            Jmp     .VoiceDone

        ;Restart loop -------------------------
        %%LoopB:
%ifdef HOST64
            MovZX   EDX,byte [RBX+mSrc]                                         ;EDX = Source
            Test    byte [RBX+mFlg],MFLG_KOFF                                   ;Is voice in key off mode?
%else
            MovZX   EDX,byte [EBX+mSrc]                                         ;EDX = Source
            Test    byte [EBX+mFlg],MFLG_KOFF                                   ;Is voice in key off mode?
%endif
            JNZ     short %%NoSrc                                               ;   Yes
%ifdef HOST64
                Lea     R8,[rel mix]
                Lea     R9,[rel dsp]
                Mov     RAX,RBX
                Sub     RAX,R8
                ShR     RAX,3
                Add     RAX,R9
                Mov     DL,[RAX+srcn]                                           ;DL = Source
%else
                Mov     EAX,EBX
                Sub     EAX,mix
                ShR     EAX,3
                Add     EAX,dsp
                Mov     DL,[EAX+srcn]                                           ;DL = Source
%endif
%ifdef HOST64
                Mov     [RBX+mSrc],DL                                           ;Save source number
%else
                Mov     [EBX+mSrc],DL                                           ;Save source number
%endif

	        %%NoSrc:
%ifdef HOST64
	            Lea     R8,[rel scr700chg]
	            Mov     DL,[R8+RDX]                                                 ;DL = NoteChange[EDX]
	            Lea     R9,[rel dsp]
	            MovZX   EAX,DL
	            ShL     EAX,2
	            MovZX   EDX,byte [R9+dir]
	            ShL     EDX,8
	            Add     EAX,EDX                                                    ;EAX = Source directory entry offset
	            Mov     R8,[pAPURAM]
	            MovZX   EAX,word [R8+RAX+2]
%else
	            Mov     DL,[scr700chg+EDX]                                          ;DL = NoteChange[EDX]
	            Mov     EAX,[pAPURAM]
            Mov     AH,[dsp+dir]                                                ;EAX -> Source directory
            Mov     AX,[EDX*4+EAX+2]
%endif
%ifdef HOST64
            Mov     [RBX+bCur],EAX                                              ;Store loop point offset in current block pointer
%else
            Mov     [EBX+bCur],EAX                                              ;Store loop point in current block pointer
%endif

        ;Decompress next block ----------------
	        %%NotEndB:
%ifdef HOST64
	            Mov     ESI,[RBX+bCur]                                              ;ESI = Current sample block offset
	            Mov     RAX,[pAPURAM]
	            Lea     RSI,[RAX+RSI]                                               ;RSI -> Current sample block
%else
	            Mov     ESI,[EBX+bCur]                                              ;ESI -> Current sample block
%endif
	            Push    ECX,EDI,EBX
%ifdef HOST64
	            Mov     AL,[RSI]                                                    ;Get block header
%else
	            Mov     AL,[ESI]                                                    ;Get block header
%endif
%ifdef HOST64
	            LEA     RDI,[RBX+sBuf]                                              ;RDI -> location to store samples
	            Mov     [RBX+bHdr],AL                                               ;Save header byte
            MovSX   EDX,word [RBX+sP1]                                          ;Load previous two samples
            MovSX   EBX,word [RBX+sP2]
%else
            LEA     EDI,[EBX+sBuf]                                              ;EDI -> location to store samples
            Mov     [EBX+bHdr],AL                                               ;Save header byte
            MovSX   EDX,word [EBX+sP1]                                          ;Load previous two samples
            MovSX   EBX,word [EBX+sP2]
%endif
	            Call    [pDecomp]                                                   ;Call user selected decompression routine

	            Mov     EAX,EBX
	            Pop     EBX,EDI,ECX
%ifdef HOST64
	            Mov     [RBX+sP1],DX                                                ;Save last two samples in 16-bit form
	            Mov     [RBX+sP2],AX
            Inc     dword [dbgDecompCount]

            Mov     AL,[RBX+bHdr]
%else
            Mov     [EBX+sP1],DX                                                ;Save last two samples in 16-bit form
            Mov     [EBX+sP2],AX

            Mov     AL,[EBX+bHdr]
%endif
            And     AL,3
            Cmp     AL,1
            JNE     short %%NoSInc

            XOr     EAX,EAX
%ifdef HOST64
            Mov     [RBX+sBuf+16],EAX
            Mov     [RBX+sBuf+20],EAX
            Mov     [RBX+sBuf+24],EAX
            Mov     [RBX+sBuf+28],EAX
%else
            Mov     [EBX+sBuf+16],EAX
            Mov     [EBX+sBuf+20],EAX
            Mov     [EBX+sBuf+24],EAX
            Mov     [EBX+sBuf+28],EAX
%endif

    %%NoSInc:
%endmacro


;===================================================================================================
;Calculate Envelope Modification
;
;Changes the current height of the volume envelope based on its programming.
;
;In:
;   EBX-> Current voice in mix
;   CH  = Current voice bit mask
;
;Destroys:
;   EAX,CL,EDX,ESI

%macro UpdateEnv 0
%ifdef HOST64
    Test    byte [RBX+mKOn],-1                                                  ;Did time pass after KON had been written?
%else
    Test    byte [EBX+mKOn],-1                                                  ;Did time pass after KON had been written?
%endif
    JNZ     %%Done                                                              ;   No, quit

    Mov     AL,[adsrCnt]
    Test    AL,AL                                                               ;Should update envelope?
    JZ      %%Done                                                              ;   No, quit
    Mov     [adsrUpd],AL

    %%Loop:
%ifdef HOST64
    Mov     CL,[RBX+eMode]
%else
    Mov     CL,[EBX+eMode]
%endif
    Test    CL,E_IDLE                                                           ;Is the envelope constant?
    JNZ     %%EnvDone                                                           ;   Yes, go to ADSR/Gain check

%ifdef HOST64
    Dec     word [2+RBX+eCnt]                                                   ;Decrease sample counter, is it zero?
%else
    Dec     word [2+EBX+eCnt]                                                   ;Decrease sample counter, is it zero?
%endif
    JNZ     %%LoopDone                                                          ;   No, go to next loop

%ifdef HOST64
    Mov     EAX,[RBX+eRate]                                                     ;Restore sample counter
    Add     [RBX+eCnt],EAX
%else
    Mov     EAX,[EBX+eRate]                                                     ;Restore sample counter
    Add     [EBX+eCnt],EAX
%endif

    Mov     AL,CL
    And     AL,E_ADSR|E_DIRECT
    Cmp     AL,E_DIRECT                                                         ;Is the envelope direct mode?
    JE      %%EnvDirect                                                         ;   Yes

    ;Adjust Envelope -------------------------
    %%AdjExp:
    Test    CL,E_TYPE                                                           ;Is the adjustment an exponential decrease?
    JZ      short %%AdjLin                                                      ;   No, go to linear
%ifdef HOST64
        Mov     EAX,[RBX+eVal]                                                  ;Get now envelope height
%else
        Mov     EAX,[EBX+eVal]                                                  ;Get now envelope height
%endif
        Neg     EAX
        SAR     EAX,8
%ifdef HOST64
        Add     [RBX+eVal],EAX                                                  ;Subtract 1/256th of envelope height
        Mov     EDX,[RBX+eDest]                                                 ;Get destination
        Cmp     EDX,[RBX+eVal]                                                  ;Has height reached destination?
%else
        Add     [EBX+eVal],EAX                                                  ;Subtract 1/256th of envelope height
        Mov     EDX,[EBX+eDest]                                                 ;Get destination
        Cmp     EDX,[EBX+eVal]                                                  ;Has height reached destination?
%endif
        JL      %%EnvDone                                                       ;   No
        Jmp     short %%AdjOff

    %%AdjLin:
    Test    CL,E_DIR                                                            ;Is the adjustment up or down?
    JZ      short %%AdjDec
%ifdef HOST64
        Mov     EAX,[RBX+eVal]                                                  ;Get now envelope height
        Add     EAX,[RBX+eAdj]
        Mov     [RBX+eVal],EAX                                                  ;Add adjustment to height
        Mov     EDX,[RBX+eDest]                                                 ;Get destination
%else
        Mov     EAX,[EBX+eVal]                                                  ;Get now envelope height
        Add     EAX,[EBX+eAdj]
        Mov     [EBX+eVal],EAX                                                  ;Add adjustment to height
        Mov     EDX,[EBX+eDest]                                                 ;Get destination
%endif
        Cmp     EDX,EAX                                                         ;Has height reached destination?
        JG      %%EnvDone                                                       ;   No

%ifdef HOST64
        Mov     [RBX+eVal],EDX                                                  ;Set destination
%else
        Mov     [EBX+eVal],EDX                                                  ;Set destination
%endif
        Jmp     short %%AdjDone                                                 ;Change to decay mode

    %%AdjDec:
%ifdef HOST64
        Mov     EAX,[RBX+eVal]                                                  ;Get now envelope height
        Sub     EAX,[RBX+eAdj]
        Mov     [RBX+eVal],EAX                                                  ;Subtract adjustment to height
        Mov     EDX,[RBX+eDest]                                                 ;Get destination
%else
        Mov     EAX,[EBX+eVal]                                                  ;Get now envelope height
        Sub     EAX,[EBX+eAdj]
        Mov     [EBX+eVal],EAX                                                  ;Subtract adjustment to height
        Mov     EDX,[EBX+eDest]                                                 ;Get destination
%endif
        Cmp     EDX,EAX                                                         ;Has height reached destination?
        JL      %%EnvDone                                                       ;   No

    %%AdjOff:
%ifdef HOST64
        Mov     [RBX+eVal],EDX                                                  ;Set destination
%else
        Mov     [EBX+eVal],EDX                                                  ;Set destination
%endif
        Test    EDX,EDX                                                         ;If destination isn't 0, change to sustain mode
        JNZ     short %%AdjDone

%ifdef HOST64
        Mov     AL,[RBX+eMode]                                                  ;If the envelope started out in ADSR mode, but was
%else
        Mov     AL,[EBX+eMode]                                                  ;If the envelope started out in ADSR mode, but was
%endif
        And     AL,~70h                                                         ; switched to Gain w/ linear decrease, the ADSR state
        Or      AL,E_SUST << 4                                                  ; will become sustain if ADSR is re-enabled.
%ifdef HOST64
        Mov     [RBX+eMode],AL
%else
        Mov     [EBX+eMode],AL
%endif

%ifdef HOST64
        Mov     AL,[RBX+mFlg]                                                   ;If the voice was getting keyed off, set MFLG_OFF to
%else
        Mov     AL,[EBX+mFlg]                                                   ;If the voice was getting keyed off, set MFLG_OFF to
%endif
        And     AL,MFLG_KOFF                                                    ; mark the voice as now being inactive
        Add     AL,AL
        SetZ    AH
%ifdef HOST64
        Or      [RBX+mFlg],AL
        And     byte [RBX+mFlg],~MFLG_KOFF
%else
        Or      [EBX+mFlg],AL
        And     byte [EBX+mFlg],~MFLG_KOFF
%endif

        Dec     AH
        And     AH,CH
        Not     AH
        And     [voiceMix],AH                                                   ;Disable voice mixing if keyed off

%ifdef HOST64
        Or      byte [RBX+eMode],E_IDLE                                         ;Envelope is no longer changing
%else
        Or      byte [EBX+eMode],E_IDLE                                         ;Envelope is no longer changing
%endif
        Jmp     %%EnvDone

    %%AdjDone:

    ;Change adjustment mode ------------------
    ;(see StartEnv)
    Test    CL,E_ADSR                                                           ;Is envelope in ADSR mode?
    JZ      %%EnvGain                                                           ;   No, jump to Gain

%ifdef HOST64
    Lea     R8,[rel mix]
    Lea     R9,[rel dsp]
    Mov     RSI,RBX
    Sub     RSI,R8
    XOr     EAX,EAX
    ShR     RSI,3                                                               ;RSI indexes current voice in dsp
    Add     RSI,R9
%else
    Mov     ESI,EBX
    Sub     ESI,mix
    XOr     EAX,EAX
    ShR     ESI,3                                                               ;ESI indexes current voice in dsp
    Add     ESI,dsp
%endif

%ifdef HOST64
    Test    byte [RSI+adsr],80h                                                 ;Is envelope flag in ADSR?
%else
    Test    byte [ESI+adsr],80h                                                 ;Is envelope flag in ADSR?
%endif
    JZ      %%EnvDone                                                           ;   No

%ifdef HOST64
    Mov     [RBX+vRsv],AL                                                       ;Reset ADSR/Gain changed flag
%else
    Mov     [EBX+vRsv],AL                                                       ;Reset ADSR/Gain changed flag
%endif
    Test    CL,E_DEST                                                           ;Switch to next mode
    JNZ     short %%EnvSust

    %%EnvDecay:
%ifdef HOST64
        Lea     RDX,[rel %%EnvDone]
        Push    EDX
%else
        Push    %%EnvDone
%endif
        Push    ESI                                                             ;ESI will get popped on return from StartEnv
        Jmp     ChgDec                                                          ;see StartEnv

    %%EnvSust:
%ifdef HOST64
        Lea     RDX,[rel %%EnvDone]
        Push    EDX
%else
        Push    %%EnvDone
%endif
        Push    ESI                                                             ;ESI will get popped on return from StartEnv
        Jmp     ChgSus                                                          ;see StartEnv

    %%EnvGain:
%ifdef HOST64
        Or      byte [RBX+eMode],E_IDLE                                         ;Envelope is now constant
%else
        Or      byte [EBX+eMode],E_IDLE                                         ;Envelope is now constant
%endif

        Test    CL,E_DEST                                                       ;If gain is in "bent line" mode and line has reached
        JZ      short %%EnvDone                                                 ; bend point, adjust envelope settings, otherwise
                                                                                ; envelope is done.
%ifdef HOST64
        Cmp     dword [RBX+eDest],D_MAX
%else
        Cmp     dword [EBX+eDest],D_MAX
%endif
        JE      short %%EnvDone

%ifdef HOST64
        And     byte [RBX+eMode],~E_IDLE                                        ;Undo idle flag
        Mov     dword [RBX+eAdj],A_BENT                                         ;Slow down increase rate
        Mov     dword [RBX+eDest],D_MAX                                         ;Set destination to max
%else
        And     byte [EBX+eMode],~E_IDLE                                        ;Undo idle flag
        Mov     dword [EBX+eAdj],A_BENT                                         ;Slow down increase rate
        Mov     dword [EBX+eDest],D_MAX                                         ;Set destination to max
%endif
        Jmp     short %%EnvDone

    %%EnvDirect:
%ifdef HOST64
        Mov     EAX,[RBX+eVal]
        Mov     EDX,[RBX+eDest]
%else
        Mov     EAX,[EBX+eVal]
        Mov     EDX,[EBX+eDest]
%endif
        Cmp     EDX,EAX
        JE      short %%EnvDirectE
        JG      short %%EnvDirectH

%ifdef HOST64
        Sub     EAX,[RBX+eAdj]                                                  ;Sub adjustment to height
        Mov     [RBX+eVal],EAX
%else
        Sub     EAX,[EBX+eAdj]                                                  ;Sub adjustment to height
        Mov     [EBX+eVal],EAX
%endif
        Cmp     EDX,EAX                                                         ;Has height reached destination?
        JL      short %%EnvDone                                                 ;   No

%ifdef HOST64
        Mov     [RBX+eVal],EDX                                                  ;Set destination
%else
        Mov     [EBX+eVal],EDX                                                  ;Set destination
%endif
        Jmp     short %%EnvDirectE

    %%EnvDirectH:
%ifdef HOST64
        Add     EAX,[RBX+eAdj]                                                  ;Add adjustment to height
        Mov     [RBX+eVal],EAX
%else
        Add     EAX,[EBX+eAdj]                                                  ;Add adjustment to height
        Mov     [EBX+eVal],EAX
%endif
        Cmp     EDX,EAX                                                         ;Has height reached destination?
        JG      short %%EnvDone                                                 ;   No

%ifdef HOST64
        Mov     [RBX+eVal],EDX                                                  ;Set destination
%else
        Mov     [EBX+eVal],EDX                                                  ;Set destination
%endif

    %%EnvDirectE:
%ifdef HOST64
        Or      byte [RBX+eMode],E_IDLE                                         ;Envelope is now constant
%else
        Or      byte [EBX+eMode],E_IDLE                                         ;Envelope is now constant
%endif

    %%EnvDone:
%ifdef HOST64
    Mov     AL,[RBX+vRsv]
%else
    Mov     AL,[EBX+vRsv]
%endif
    Test    AL,1
    JZ      short %%ChkGain
%ifdef HOST64
        Mov     byte [RBX+vRsv],0
%else
        Mov     byte [EBX+vRsv],0
%endif
        Push    EBX                                                             ;Update new ADSR parameters
%ifdef HOST64
        Lea     R8,[rel mix]
        Sub     RBX,R8
%else
        Sub     EBX,mix
%endif
        Call    RADSR
        Pop     EBX
        Jmp     short %%LoopDone

    %%ChkGain:
    Test    AL,2
    JZ      short %%LoopDone
%ifdef HOST64
        Mov     byte [RBX+vRsv],0
%else
        Mov     byte [EBX+vRsv],0
%endif
        Push    EBX                                                             ;Update new Gain parameters
%ifdef HOST64
        Lea     R8,[rel mix]
        Sub     RBX,R8
%else
        Sub     EBX,mix
%endif
        Call    RGain
        Pop     EBX

    %%LoopDone:
    Dec     byte [adsrUpd]
    JNZ     %%Loop

    %%Done:
%endmacro


;===================================================================================================
;Finite Impulse Response Echo Filter
;
;Filters the echo using an eight tap FIR filter:
;
;        7
;       ---
;   x = \   c  * s
;       /    n    n
;       ---
;       n=0
;
;   x = output sample
;   c = filter coefficient (-.7)
;   s = unfiltered sample
;   n = 0 is the oldest sample and 7 is the most recent
;
;FIR filters are based on the sample rate.  This was fine in the SNES, because the sample rate was
;always 32kHz, but in the case of an emulator the sample rate can change.  So measures have to be
;taken to ensure the filter will have the same effect, regardless of the output sample rate.
;
;To overcome this problem, I figured each tap of the filter is applied every 31250ns.  So the
;solution is to calculate when 31250ns have gone by, and use the sample at that point.  Of course
;this method really only works if the output rate is a multiple of 32k.  In order to get accurate
;results, some sort of interpolation method needs to be introduced.  I went the cheap route and used
;linear interpolation.
;
;In:
;   ST0,1 = Input samples
;
;Out:
;   ST0,1 = Filtered samples
;
;Destroys:
;   EAX,EDX,EBX,CL

%macro FIRCut16 1
%ifdef HOST64
    FISt    dword [RSP-4]
    Mov     EAX,[RSP-4]
%else
    FISt    dword [ESP-4]
    Mov     EAX,[ESP-4]
%endif
    Add     EAX,32768
    SAR     EAX,16                                                              ;Did a sample overflow signed-16bit?
    JZ      short %%OK                                                          ;   No, do nothing
%ifdef HOST64
        Mov     EAX,[RSP-4]                                                     ;There is no overflow because FIR is handled with
%else
        Mov     EAX,[ESP-4]                                                     ;There is no overflow because FIR is handled with
%endif
        MovSX   EAX,AX                                                          ; 32bit-float, emulates signed-16bit overflow here.
        And     EAX,~1                                                          ;All numbers used by DSP are even

%ifdef HOST64
        Mov     [RSP-4],EAX
        FSubP   %1,ST
        FILd    dword [RSP-4]
%else
        Mov     [ESP-4],EAX
        FSubP   %1,ST
        FILd    dword [ESP-4]
%endif
        FAdd    %1,ST

    %%OK:
%endmacro

%macro FIRClampL 1
%ifdef HOST64
    FISt    dword [RSP-4]
    Mov     EAX,[RSP-4]
%else
    FISt    dword [ESP-4]
    Mov     EAX,[ESP-4]
%endif
    Add     EAX,32768
    SAR     EAX,16                                                              ;Did a sample overflow signed-16bit?
    JZ      short %%OK                                                          ;   No, do nothing
%ifdef HOST64
        Mov     EAX,[RSP-4]                                                     ;If s < -32768, s = -32768
%else
        Mov     EAX,[ESP-4]                                                     ;If s < -32768, s = -32768
%endif
        SAR     EAX,31                                                          ;If s > 32767, s = 32767
        Not     EAX
        XOr     EAX,-32768
        And     EAX,~1                                                          ;All numbers used by DSP are even

%ifdef HOST64
        Mov     [RSP-4],EAX
        FSubP   %1,ST
        FILd    dword [RSP-4]
%else
        Mov     [ESP-4],EAX
        FSubP   %1,ST
        FILd    dword [ESP-4]
%endif
        FAdd    %1,ST

    %%OK:
%endmacro

%macro FIRClampH 1
%ifdef HOST64
    FISt    dword [RSP-4]
    Mov     EAX,[RSP-4]
%else
    FISt    dword [ESP-4]
    Mov     EAX,[ESP-4]
%endif
    Add     EAX,65536
    SAR     EAX,17                                                              ;Did a sample overflow signed-16bit?
    JZ      short %%OK                                                          ;   No, do nothing
%ifdef HOST64
        Mov     EAX,[RSP-4]                                                     ;If s < -65536, s = -65536
%else
        Mov     EAX,[ESP-4]                                                     ;If s < -65536, s = -65536
%endif
        SAR     EAX,31                                                          ;If s > 65535, s = 65535
        Not     EAX
        XOr     EAX,-65536

%ifdef HOST64
        Mov     [RSP-4],EAX
        FSubP   %1,ST
        FILd    dword [RSP-4]
%else
        Mov     [ESP-4],EAX
        FSubP   %1,ST
        FILd    dword [ESP-4]
%endif
        FAdd    %1,ST

    %%OK:
%endmacro

%macro FIRFilter 0
    Test    dword [dspOpts],DSP_ECHOFIR
    JZ      short %%NoZero

%ifdef HOST64
    Lea     RBX,[rel mix]
%else
    Mov     EBX,mix
%endif
    XOr     DX,DX
    Inc     DH
    Mov     CL,8

    %%ChMute:
%ifdef HOST64
        Test    byte [RBX+mFlg],MFLG_MUTE                                       ;Is voice muted by user?
%else
        Test    byte [EBX+mFlg],MFLG_MUTE                                       ;Is voice muted by user?
%endif
        SetZ    AL
        Dec     AL
        And     AL,DH
        Or      DL,AL

%ifdef HOST64
        Sub     RBX,-80h
%else
        Sub     EBX,-80h
%endif
        Add     DH,DH

    Dec     CL
    JNZ     short %%ChMute

    Test    DL,DL                                                               ;DL = Muted channels, are any channels muted?
    JZ      short %%NoZero                                                      ;   No

    Not     DL                                                                  ;DL = Not muted channels
%ifdef HOST64
    Lea     RAX,[rel dsp]
    Mov     DH,[RAX+eon]                                                        ;DH = Using echo channels
%else
    Mov     DH,[dsp+eon]                                                        ;DH = Using echo channels
%endif
    And     DH,DL                                                               ;Are all channels using echoes muted?
    JNZ     short %%NoZero                                                      ;   No
        FLd     dword [fpShR1]                                                  ;Force feedback in half, without echo. (If there is
        FMul    ST1,ST                                                          ; a loud feedback that causes clipping, mute the
        FMul    ST2,ST                                                          ; channel toprevent the sound from playing forever.)
        FStP    ST

    %%NoZero:
    Sub     byte [firCur],4                                                     ;Move index back one sample. (Index will wrap around
    Mov     EBX,[firCur]                                                        ; after 64 samples, enough for up to 256kHz output.)
%ifdef HOST64
    Lea     RAX,[rel firBuf]
    Lea     RBX,[RAX+RBX*2]                                                     ;RBX -> Current sample in filter buffer
%else
    Lea     EBX,[EBX*2+firBuf]                                                  ;EBX -> Current sample in filter buffer
%endif
                                                                                ;                                   |FBR FBL
    Test    dword [dspOpts],DSP_ECHOFIR
    JZ      short %%Skip
        FLd     ST                                                              ;Clamp 16-bit sample                |FBR FBL FBL
        FIRClampL   ST1
        FStP    ST                                                              ;                                   |FBR FBL

        FLd     ST1                                                             ;                                   |FBR FBL FBR
        FIRClampL   ST2
        FStP    ST                                                              ;                                   |FBR FBL

    %%Skip:
%ifdef HOST64
    FSt     dword [RBX]                                                         ;Store new samples in buffer
    FSt     dword [RBX+FIRBUF*2]
    FStP    dword [RBX+FIRBUF*4]                                                ;                                   |FBR
    FSt     dword [RBX+4]
    FSt     dword [RBX+FIRBUF*2+4]
    FStP    dword [RBX+FIRBUF*4+4]                                              ;                                   |(empty)
%else
    FSt     dword [EBX]                                                         ;Store new samples in buffer
    FSt     dword [FIRBUF*2+EBX]
    FStP    dword [FIRBUF*4+EBX]                                                ;                                   |FBR
    FSt     dword [4+EBX]
    FSt     dword [FIRBUF*2+4+EBX]
    FStP    dword [FIRBUF*4+4+EBX]                                              ;                                   |(empty)
%endif

    FLdZ                                                                        ;                                   |0
    FLdZ                                                                        ;                                   |0 0
    Test    dword [dspOpts],DSP_ECHOFIR
    SetNZ   CH

    MovZX   EDX,CH                                                              ;EBX -> Unfiltered sample
    Dec     EDX
    Not     EDX
    And     EDX,FIRBUF*2+56
%ifdef HOST64
    Add     RBX,RDX
%else
    Add     EBX,EDX
%endif

    MovZX   EDX,CH                                                              ;EDX -> Filter taps
    Dec     EDX
    And     EDX,28
%ifdef HOST64
    Lea     RAX,[rel firTaps]
    Add     RDX,RAX
%else
    Add     EDX,firTaps
%endif

%ifdef HOST64
    Mov     dword [RSP-8],0                                                     ;Reset decimal overflow, so filtering is consistant
%else
    Mov     dword [ESP-8],0                                                     ;Reset decimal overflow, so filtering is consistant
%endif
    Mov     CL,8                                                                ;8-tap FIR filter

    %%Tap:
%ifdef HOST64
        FILd    dword [RSP-8]                                                   ;                                   |0 0 firDec
        FMul    dword [fpShR16]                                                 ;                                   |0 0 firDec>>16=FD

        FLd     dword [RBX+8]                                                   ;Interpolate left sample            |0 0 FD S1
        FSub    dword [RBX]                                                     ;                                   |0 0 FD S1-S2
        FMul    ST1                                                             ;                                   |0 0 FD (S1-S2)*FD
        FAdd    dword [RBX]                                                     ;                                   |0 0 FD (S1-S2)*FD+S2
        FMul    dword [RDX]                                                     ;                                   |0 0 FD ((S1-S2)*FD+S2)*FT
        FAddP   ST2,ST                                                          ;                                   |0 ((S1-S2)*FD+S2)*FT FD

        FLd     dword [RBX+12]                                                  ;Interpolate right sample           |0 FBL FD S1
        FSub    dword [RBX+4]                                                   ;                                   |0 FBL FD S1-S2
        FMulP   ST1,ST                                                          ;                                   |0 FBL (S1-S2)*FD
        FAdd    dword [RBX+4]                                                   ;                                   |0 FBL (S1-S2)*FD+S2
        FMul    dword [RDX]                                                     ;                                   |0 FBL ((S1-S2)*FD+S2)*FT
        FAddP   ST2,ST                                                          ;                                   |FBR FBL
%else
        FILd    dword [ESP-8]                                                   ;                                   |0 0 firDec
        FMul    dword [fpShR16]                                                 ;                                   |0 0 firDec>>16=FD

        FLd     dword [8+EBX]                                                   ;Interpolate left sample            |0 0 FD S1
        FSub    dword [EBX]                                                     ;                                   |0 0 FD S1-S2
        FMul    ST1                                                             ;                                   |0 0 FD (S1-S2)*FD
        FAdd    dword [EBX]                                                     ;                                   |0 0 FD (S1-S2)*FD+S2
        FMul    dword [EDX]                                                     ;                                   |0 0 FD ((S1-S2)*FD+S2)*FT
        FAddP   ST2,ST                                                          ;                                   |0 ((S1-S2)*FD+S2)*FT FD

        FLd     dword [12+EBX]                                                  ;Interpolate right sample           |0 FBL FD S1
        FSub    dword [4+EBX]                                                   ;                                   |0 FBL FD S1-S2
        FMulP   ST1,ST                                                          ;                                   |0 FBL (S1-S2)*FD
        FAdd    dword [4+EBX]                                                   ;                                   |0 FBL (S1-S2)*FD+S2
        FMul    dword [EDX]                                                     ;                                   |0 FBL ((S1-S2)*FD+S2)*FT
        FAddP   ST2,ST                                                          ;                                   |FBR FBL
%endif

        Test    dword [dspOpts],DSP_ECHOFIR
        JZ      %%ClampH
        Dec     CL                                                              ;Is calculate the oldest sample (n=0)?
        JZ      short %%ClampL                                                  ;   Yes
            FLd     ST                                                          ;Cut high-order bits                |FBR FBL FBL
            FIRCut16    ST1
            FStP    ST                                                          ;                                   |FBR FBL

            FLd     ST1                                                         ;                                   |FBR FBL FBR
            FIRCut16    ST2
            FStP    ST                                                          ;                                   |FBR FBL

            Inc     CL                                                          ;Restore CL
            Jmp     %%Next

        %%ClampL:
            FLd     ST                                                          ;Clamp 16-bit sample                |FBR FBL FBL
            FIRClampL   ST1
            FStP    ST                                                          ;                                   |FBR FBL

            FLd     ST1                                                         ;                                   |FBR FBL FBR
            FIRClampL   ST2
            FStP    ST                                                          ;                                   |FBR FBL

            Inc     CL                                                          ;Restore CL
            Jmp     short %%Next

        %%ClampH:
            FLd     ST                                                          ;Clamp 17-bit sample                |FBR FBL FBL
            FIRClampH   ST1
            FStP    ST                                                          ;                                   |FBR FBL

            FLd     ST1                                                         ;                                   |FBR FBL FBR
            FIRClampH   ST2
            FStP    ST                                                          ;                                   |FBR FBL

        %%Next:
%ifdef HOST64
        Mov     EAX,[RSP-8]                                                     ;Determine next sample to use in filter
        Add     EAX,[firRate]
        Mov     [RSP-8],AX
        ShR     EAX,16

        Test    CH,CH
        JNZ     short %%NewFIR
            Lea     RBX,[RBX+RAX*8]                                             ;RBX -> Sample to use in filter
            Sub     RDX,4                                                       ;RDX -> Next filter tap

        Dec     CL
        JNZ     %%Tap
        Jmp     short %%Done

        %%NewFIR:
            ShL     EAX,3                                                       ;Multiply upper 16-bit by 8, not use 'ShR EAX,13'
            Sub     RBX,RAX                                                     ;RBX -> Sample to use in filter
            Add     RDX,4                                                       ;RDX -> Next filter tap
%else
        Mov     EAX,[ESP-8]                                                     ;Determine next sample to use in filter
        Add     EAX,[firRate]
        Mov     [ESP-8],AX
        ShR     EAX,16

        Test    CH,CH
        JNZ     short %%NewFIR
            Lea     EBX,[EAX*8+EBX]                                             ;EBX -> Sample to use in filter
            Sub     EDX,4                                                       ;EDX -> Next filter tap

        Dec     CL
        JNZ     %%Tap
        Jmp     short %%Done

        %%NewFIR:
            ShL     EAX,3                                                       ;Multiply upper 16-bit by 8, not use 'ShR EAX,13'
            Sub     EBX,EAX                                                     ;EBX -> Sample to use in filter
            Add     EDX,4                                                       ;EDX -> Next filter tap
%endif

        Dec     CL
        JNZ     %%Tap

    %%Done:
%endmacro


;===================================================================================================
;DSP Catch Up with the Processing of SPC700

PROC CatchUp

    Push    EAX

    Mov     EAX,[t64Cnt]
    ShR     EAX,1
    Sub     EAX,[outCnt]
    JZ      .Done

    Add     [outCnt],EAX

    Push    EDX
    Mul     dword [outRate]
    Add     EAX,[outDec]
    AdC     EDX,0
    Mov     [outDec],AX
    ShRD    EAX,EDX,16

    Sub     [outLeft],EAX
    JNC     short .Okay
        Add     EAX,[outLeft]
        Mov     dword [outLeft],0

    .Okay:
    Test    EAX,EAX
    JZ      short .Skip
        Call    EmuDSP,[pOutBuf],EAX
%ifdef HOST64
        Mov     [pOutBuf],RAX
%else
        Mov     [pOutBuf],EAX
%endif

    .Skip:
%if INTBK
    Push    ECX                                                                 ;Run KON/KOFF processing after emulate DSP
    CatchKOff
    CatchKOn
    Pop     ECX,EDX
%else
    Push    EBX,ECX                                                             ;Run KON processing after emulate DSP
    XOr     CH,CH                                                               ;Set CH = 0 for use with CatchKOn
    CatchKOn
    Pop     ECX,EBX,EDX
%endif

    .Done:
    Pop     EAX

ENDP


;===================================================================================================
;Set Automatic EmuDSP Parameters
;
;Destroys:
;   ECX,EDX

PROC SetEmuDSP, pBufD, numD, rateD

    Mov     EAX,[rateD]
    Test    EAX,EAX
    JZ      short .Final
        XOr     EDX,EDX
        Mov     [outDec],EDX

        ShLD    EDX,EAX,16
        ShL     EAX,16
        Mov     ECX,32000
        Div     ECX
        Mov     [outRate],EAX

        Mov     EAX,[numD]
        Mov     [outLeft],EAX
%ifdef HOST64
        Mov     RAX,[pBufD]
        Mov     [pOutBuf],RAX
%else
        Mov     EAX,[pBufD]
        Mov     [pOutBuf],EAX
%endif
        Mov     EAX,[t64Cnt]
        ShR     EAX,1
        Mov     [outCnt],EAX
        RetN

    .Final:
        Call    EmuDSP,[pOutBuf],[outLeft]
%ifdef HOST64
        Mov     [pOutBuf],RAX
%else
        Mov     [pOutBuf],EAX
%endif
        Mov     dword [outLeft],0

ENDP


;===================================================================================================
;Emulate SPC700

PROC EmuDSP, pBuf, num
USES ALL

%ifdef HOST64
    Mov     RAX,[pBuf]
%else
    Mov     EAX,[pBuf]
%endif
    Mov     EDX,[num]
    Test    EDX,EDX
    JZ      .Done

%ifdef HOST64
    Test    RAX,RAX
%else
    Test    EAX,EAX
%endif
    SetZ    BL                                                                  ;BL = 0 if output pointer is null, otherwise it indexes
    Dec     BL                                                                  ; the emulation routine
    And     BL,[dspMix]                                                         ;BL = 0 (mute) or 1 (output)
    Dec     BL
    Mov     BH,BL
    And     BL,8                                                                ;BL = 8 or 0
    Not     BH                                                                  ;BH = 0 or 0xFF

    Mov     DH,[dsp+flg]                                                        ;DH = disFlag
    And     DH,0E0h                                                             ;   [0] - Disabled write echo memory
    Or      DH,[dspMute]                                                        ;   [1] - (not used)
                                                                                ;   [2] - (not used)
    Mov     DL,[dspOpts]                                                        ;   [3] - Disabled DSP emulation (pBuf is NULL)
    And     DL,DSP_NOECHO                                                       ;   [4] - Disabled echo (user setting)
    Or      DH,DL                                                               ;   [5] - Disabled echo (DSP no echo flag)
                                                                                ;   [6] - Disabled DSP emulation (DSP mute flag)
    Or      DH,BL                                                               ;   [7] - Disabled DSP emulation (DSP reset flag)

    Test    dword [dspOpts],DSP_ECHOFIR                                         ;Is echo disabled?
    SetZ    DL
    Or      DH,DL
    Mov     [disFlag],DH

    Mov     DH,[dsp+pmon]                                                       ;Set DSP pitch modulation flags
    And     DH,0FEh
    Test    dword [dspOpts],DSP_NOPMOD                                          ;Is pitch modulation enabled?
    SetNZ   DL
    Dec     DL
    And     DH,DL
    And     DH,BH
    Mov     [dspPMod],DH

    Mov     DH,[dsp+non]                                                        ;Set DSP noise flags
    Test    dword [dspOpts],DSP_NONOISE                                         ;Is noise enabled?
    SetNZ   DL
    Dec     DL
    And     DH,DL
    Mov     BL,DH
    And     DH,BH
    Mov     [dspNoise],DH

    Push    EBX
    Mov     BH,8
    Mov     BL,1
    XOr     DH,DH
%ifdef HOST64
    Lea     RSI,[rel mix+mFlg]
%else
    Mov     ESI,mix+mFlg
%endif

    .Noise:
%ifdef HOST64
        Test    byte [RSI],MFLG_NOISE                                           ;Is noise enabled?
%else
        Test    byte [ESI],MFLG_NOISE                                           ;Is noise enabled?
%endif
        SetZ    DL
        Dec     DL
        And     DL,BL
        Or      DH,DL

        Add     BL,BL
%ifdef HOST64
        Sub     RSI,-80h
%else
        Sub     ESI,-80h
%endif

    Dec     BH
    JNZ     short .Noise
    Pop     EBX

    And     DH,BH
    Mov     [dspNoiseF],DH
    Or      [dspNoise],DH

    Test    dword [dspOpts],DSP_FLOAT                                           ;Is volume output floating-point?
    JNZ     short .Next                                                         ;   Yes
        FILd    dword [vMMaxL]
        FMul    dword [fp64k]                                                   ;Convert to a 32-bit sample (<< 16)
        FStP    dword [vMMaxL]                                                  ;Save as a float
        FILd    dword [vMMaxR]
        FMul    dword [fp64k]
        FStP    dword [vMMaxR]

    .Next:
        ;Verify output buffer length ----------
        Mov     EDX,[num]
        Test    EDX,EDX                                                         ;Is num > 0?
        JLE     .Quit                                                           ;   No

        Cmp     EDX,MIX_SIZE                                                    ;Is num <= size of internal buffer?
        JBE     short .NSmpOK
            Mov     EDX,MIX_SIZE

        .NSmpOK:
        Sub     [num],EDX

%ifdef SPC700_INC
        Test    byte [dbgOpt],DSP_HALT                                          ;Do nothing if APU is suspended
        JNZ     short .Mute
%endif

        ;Call emulation routine ---------------
        Call    RunDSP                                                          ;Run DSP emulation
        JC      short .Next                                                     ;Quit, if emulation produced output

    .Mute:
        ;Output silence -----------------------
%ifdef HOST64
        Mov     RDI,RAX                                                         ;RDI-> Buffer to store output
%else
        Mov     EDI,EAX                                                         ;EDI-> Buffer to store output
%endif

        Mov     ECX,EDX                                                         ;ECX = Size of output buffer in samples
        XOr     EAX,EAX
        MovSX   AX,byte [dspSize]
        XOr     AL,AH
        Sub     AL,AH
        XOr     AH,AH
        Mul     byte [dspChn]
        Mul     ECX
        Mov     EDX,EAX                                                         ;EDX = Size of output buffer in bytes

        XOr     EAX,EAX                                                         ;EAX = 80h if samples are unsigned, 0 otherwise
        Cmp     byte [dspSize],1
        SetNE   AL
        Dec     EAX
        And     EAX,80808080h

        Mov     ECX,EDX                                                         ;Fill output buffer with baseline samples
        And     EDX,3
        ShR     ECX,2
        Rep     StoSD
        Mov     ECX,EDX
        Rep     StoSB
%ifdef HOST64
        Mov     RAX,RDI                                                         ;RAX-> End of buffer
%else
        Mov     EAX,EDI                                                         ;EAX-> End of buffer
%endif

        Jmp     .Next

    .Quit:
    Test    dword [dspOpts],DSP_FLOAT                                           ;Is volume output floating-point?
    JNZ     short .OutFloat                                                     ;   Yes
        FLd     dword [vMMaxL]
        FMul    dword [fpShR16]
        FIStP   dword [vMMaxL]
        FLd     dword [vMMaxR]
        FMul    dword [fpShR16]
        FIStP   dword [vMMaxR]

    .OutFloat:
    Push    EAX
    Call    SetFade

    ;Update ENVX and OUTX registers ----------
%ifdef HOST64
    Lea     RBX,[rel mix]
    Lea     RSI,[rel dsp]
%else
    Mov     EBX,mix
    Mov     ESI,dsp
%endif
    Mov     DH,1

    .XRegs:
%ifdef HOST64
        Mov     EAX,[RBX+eVal]
        ShR     EAX,E_SHIFT
        Mov     [RSI+envx],AL

        Mov     AL,[RBX+mOut+1]
        Mov     [RSI+outx],AL

        Add     RSI,10h
        Sub     RBX,-80h
%else
        Mov     EAX,[EBX+eVal]
        ShR     EAX,E_SHIFT
        Mov     [ESI+envx],AL

        Mov     AL,[EBX+mOut+1]
        Mov     [ESI+outx],AL

        Add     ESI,10h
        Sub     EBX,-80h
%endif

    Add     DH,DH
    JNZ     short .XRegs

    ;Update DSP data register on SPC700 side -
%ifdef HOST64
    Mov     RBX,[pAPURAM]
    MovZX   EDX,byte [RBX+0F2h]
    Lea     R8,[rel dsp]
    Mov     DL,[R8+RDX]
    Mov     [RBX+0F3h],DL
%else
    Mov     EBX,[pAPURAM]
    MovZX   EDX,byte [0F2h+EBX]
    Mov     DL,[EDX+dsp]
    Mov     [0F3h+EBX],DL
%endif
    Pop     EAX

    .Done:

ENDP


%macro CalRamp1 0-1
%ifdef HOST64
    Mov     EAX,[RCX]
    Cmp     EAX,[RCX-8]
%else
    Mov     EAX,[ECX]
    Cmp     EAX,[ECX-8]
%endif
    JE      short %%OK

%ifdef HOST64
    FLd     dword [RCX]                                                         ;Current                            |Current
    FCom    dword [RCX-8]                                                       ;Target                             |Current
%else
    FLd     dword [ECX]                                                         ;Current                            |Current
    FCom    dword [ECX-8]                                                       ;Target                             |Current
%endif
    FNSTSW  AX
    Test    AH,1                                                                ;Is C0 = 0 (Current > Target)?,
    JZ      short %%Sub                                                         ;   Yes, subtraction

    %if %0                                                                      ;Current += volRamp
        FAdd    dword [%1]
    %else
        FAdd    dword [volRamp1]
    %endif

%ifdef HOST64
        FCom    dword [RCX-8]                                                   ;Target                             |Current
%else
        FCom    dword [ECX-8]                                                   ;Target                             |Current
%endif
        FNSTSW  AX
%ifdef HOST64
        FStP    dword [RCX]                                                     ;Update current                     |(empty)
%else
        FStP    dword [ECX]                                                     ;Update current                     |(empty)
%endif
        Test    AH,1                                                            ;Is C0 = 0 (Current > Target)?,
        JNZ     short %%OK                                                      ;   No, re-change with next tick
        Jmp     short %%Force

    %%Sub:
    %if %0                                                                      ;Current -= volRamp
        FSub    dword [%1]
    %else
        FSub    dword [volRamp1]
    %endif

%ifdef HOST64
        FCom    dword [RCX-8]                                                   ;Target                             |Current
%else
        FCom    dword [ECX-8]                                                   ;Target                             |Current
%endif
        FNSTSW  AX
%ifdef HOST64
        FStP    dword [RCX]                                                     ;Update current                     |(empty)
%else
        FStP    dword [ECX]                                                     ;Update current                     |(empty)
%endif
        Test    AH,1                                                            ;Is C0 = 0 (Current > Target)?,
        JZ      short %%OK                                                      ;   Yes, re-change with next tick

    %%Force:
%ifdef HOST64
        Mov     EAX,[RCX-8]
        Mov     [RCX],EAX
%else
        Mov     EAX,[ECX-8]
        Mov     [ECX],EAX
%endif

    %%OK:
%endmacro

%macro CalRamp2 0-1
    Mov     AL,[voiceMix]
    Test    AL,AL
    JZ      short %%Force

    %if %0
%ifdef HOST64
        Mov     EAX,[RCX]
%else
        Mov     EAX,[ECX]
%endif
        Test    EAX,EAX
        JZ      short %%Force
    %endif

        CalRamp1    volRamp2
        Jmp     short %%OK

    %%Force:
%ifdef HOST64
        Mov     EAX,[RCX-8]
        Mov     [RCX],EAX
%else
        Mov     EAX,[ECX-8]
        Mov     [ECX],EAX
%endif

    %%OK:
%endmacro

%macro MixSample 0
    ;Get sample ========================
%ifdef HOST64
    MovZX   ESI,byte [RBX+sIdx]
    Lea     RSI,[RBX+RSI+sBuf]
    MovZX   EAX,word [RBX+mDec]
%else
    Mov     ESI,[EBX+sIdx]
    MovZX   EAX,word [EBX+mDec]
%endif
    Call    [pInter]                                                            ;                                   |smp

    Test    [dspNoise],CH                                                       ;Is noise enabled?
    JZ      short %%NoNoise                                                     ;   No
        FStP    ST                                                              ;                                   |(empty)
        XOr     EAX,EAX
        Test    [dspNoiseF],CH
        SetNZ   AL
%ifdef HOST64
	        Lea     RDX,[rel nSmp]
	        FILd    dword [RDX+RAX*4]                                               ;                                   |noise
%else
	        FILd    dword [nSmp+EAX*4]                                              ;                                   |noise
%endif

    %%NoNoise:

    ;Mixing ============================
%ifdef HOST64
    Mov     EAX,[RBX+eVal]
%else
    Mov     EAX,[EBX+eVal]
%endif
    Mov     [envCrt],EAX
    XOr     EAX,EAX
    Test    dword [dspOpts],DSP_NOENV                                           ;Is envelope disabled?
    SetNZ   AL
%ifdef HOST64
	    Lea     RDX,[rel envCrt]
	    FIMul   dword [RDX+RAX*4]
%else
	    FIMul   dword [envCrt+EAX*4]
%endif
    FMul    dword [fpEShR]
%ifdef HOST64
    FISt    dword [RBX+mOut]
%else
    FISt    dword [EBX+mOut]
%endif

%ifdef HOST64
    Test    byte [RBX+mFlg],MFLG_MUTE                                           ;Is voice muted by user?
%else
    Test    byte [EBX+mFlg],MFLG_MUTE                                           ;Is voice muted by user?
%endif
    JNZ     .VoiceOff                                                           ;   Yes

%ifdef HOST64
    MovZX   EAX,byte [RBX+mSrc]                                                 ;EAX = Source
%else
    MovZX   EAX,byte [EBX+mSrc]                                                 ;EAX = Source
%endif
%ifdef HOST64
	    Lea     RDX,[rel scr700dsp]
	    Mov     AH,[RDX+RAX]                                                        ;AH = DSPFlag[EAX]
%else
	    Mov     AH,[scr700dsp+EAX]                                                  ;AH = DSPFlag[EAX]
%endif
    Test    AH,S700_MUTE                                                        ;AH and S700_MUTE = S700_MUTE?
    JNZ     .VoiceOff                                                           ;   Yes
%endmacro

%macro MixVoice 0
%if STEREO
%ifdef HOST64
    Test    byte [RBX+mFlg],MFLG_KOFF
%else
    Test    byte [EBX+mFlg],MFLG_KOFF
%endif
    JNZ     %%NoChVol
        Push    EAX,ECX,EDX
%ifdef HOST64
        LEA     RCX,[RBX+mChnL]
%else
        LEA     ECX,[EBX+mChnL]
%endif
        CalRamp1
%ifdef HOST64
        LEA     RCX,[RBX+mChnR]
%else
        LEA     ECX,[EBX+mChnR]
%endif
        CalRamp1
        Pop     EDX,ECX,EAX

    %%NoChVol:
%endif

%if VMETERV
%ifdef HOST64
    Sub     RSP,16                                                              ;Create a temporary stack space for samples
%else
    Sub     ESP,16                                                              ;Create a temporary stack space for samples
%endif
%endif
%ifdef HOST64
	    Lea     RDX,[rel scr700vol]
%endif
    FLd     ST
    Test    [dsp+eon],CH
    JNZ     short %%VoiceEcho
%ifdef HOST64
        FMul    dword [RBX+mChnL]
%else
        FMul    dword [EBX+mChnL]
%endif
        Test    AH,S700_VOLUME                                                  ;AH and S700_VOLUME = S700_VOLUME?
        JZ      short %%NoEchoL                                                 ;   No
            MovZX   ESI,AL                                                      ;ESI = AL
%ifdef HOST64
	            FIMul   dword [RDX+RSI*4]
%else
	            FIMul   dword [scr700vol+ESI*4]
%endif
            FMul    dword [fpShR16]

        %%NoEchoL:

%if VMETERV
%ifdef HOST64
        FISt    dword [RSP]                                                     ;Store sample as an integer
        FSt     dword [RSP+4]                                                   ;Store sample as an floating-point
%else
        FISt    dword [ESP]                                                     ;Store sample as an integer
        FSt     dword [4+ESP]                                                   ;Store sample as an floating-point
%endif
%endif
%ifdef HOST64
        FAdd    dword [RDI]
        FStP    dword [RDI]
%else
        FAdd    dword [EDI]
        FStP    dword [EDI]
%endif

%ifdef HOST64
        FMul    dword [RBX+mChnR]
%else
        FMul    dword [EBX+mChnR]
%endif
        Test    AH,S700_VOLUME                                                  ;AH and S700_VOLUME = S700_VOLUME?
        JZ      short %%NoEchoR                                                 ;   No
            MovZX   ESI,AL                                                      ;ESI = AL
%ifdef HOST64
	            FIMul   dword [RDX+RSI*4]
%else
	            FIMul   dword [scr700vol+ESI*4]
%endif
            FMul    dword [fpShR16]

        %%NoEchoR:

%if VMETERV
%ifdef HOST64
        FISt    dword [RSP+8]
        FSt     dword [RSP+12]
%else
        FISt    dword [8+ESP]
        FSt     dword [12+ESP]
%endif
%endif
%ifdef HOST64
        FAdd    dword [RDI+4]
        FSt     dword [RDI+4]
%else
        FAdd    dword [4+EDI]
        FSt     dword [4+EDI]
%endif
        Jmp     short %%NoVoiceEcho

    %%VoiceEcho:
%ifdef HOST64
        FMul    dword [RBX+mChnL]
%else
        FMul    dword [EBX+mChnL]
%endif
        Test    AH,S700_VOLUME                                                  ;AH and S700_VOLUME = S700_VOLUME?
        JZ      short %%EchoL                                                   ;   No
            MovZX   ESI,AL                                                      ;ESI = AL
%ifdef HOST64
	            FIMul   dword [RDX+RSI*4]
%else
	            FIMul   dword [scr700vol+ESI*4]
%endif
            FMul    dword [fpShR16]

        %%EchoL:

%if VMETERV
%ifdef HOST64
        FISt    dword [RSP]
        FSt     dword [RSP+4]
%else
        FISt    dword [ESP]
        FSt     dword [4+ESP]
%endif
%endif
        FLd     ST
%ifdef HOST64
        FAdd    dword [RDI]
        FStP    dword [RDI]
        FAdd    dword [RDI+8]
        FStP    dword [RDI+8]
%else
        FAdd    dword [EDI]
        FStP    dword [EDI]
        FAdd    dword [8+EDI]
        FStP    dword [8+EDI]
%endif

%ifdef HOST64
        FMul    dword [RBX+mChnR]
%else
        FMul    dword [EBX+mChnR]
%endif
        Test    AH,S700_VOLUME                                                  ;AH and S700_VOLUME = S700_VOLUME?
        JZ      short %%EchoR                                                   ;   No
            MovZX   ESI,AL                                                      ;ESI = AL
%ifdef HOST64
	            FIMul   dword [RDX+RSI*4]
%else
	            FIMul   dword [scr700vol+ESI*4]
%endif
            FMul    dword [fpShR16]

        %%EchoR:

%if VMETERV
%ifdef HOST64
        FISt    dword [RSP+8]
        FSt     dword [RSP+12]
%else
        FISt    dword [8+ESP]
        FSt     dword [12+ESP]
%endif
%endif
        FLd     ST
%ifdef HOST64
        FAdd    dword [RDI+4]
        FStP    dword [RDI+4]
        FAdd    dword [RDI+12]
        FSt     dword [RDI+12]
%else
        FAdd    dword [4+EDI]
        FStP    dword [4+EDI]
        FAdd    dword [12+EDI]
        FSt     dword [12+EDI]
%endif

    %%NoVoiceEcho:

%if VMETERV
    ;Save greatest sample output ----
    Test    dword [dspOpts],DSP_FLOAT                                           ;Is volume output floating-point?
    JNZ     short %%ChFloat                                                     ;   Yes
%ifdef HOST64
        Mov     EAX,[RSP]
        CDQ
        XOr     EAX,EDX
        Sub     EAX,EDX

        Sub     EAX,[RBX+vMaxL]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [RBX+vMaxL],EAX

        Mov     EAX,[RSP+8]
        CDQ
        XOr     EAX,EDX
        Sub     EAX,EDX

        Sub     EAX,[RBX+vMaxR]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [RBX+vMaxR],EAX

        Add     RSP,16
        Jmp     %%Done
%endif
        Pop     EAX                                                             ;Pop left sample off stack
        Pop     EDX                                                             ;Unused
        CDQ                                                                     ;EDX:EAX = EAX
        XOr     EAX,EDX
        Sub     EAX,EDX

        Sub     EAX,[EBX+vMaxL]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [EBX+vMaxL],EAX

        Pop     EAX                                                             ;Pop right sample off stack
        Pop     EDX                                                             ;Unused
        CDQ
        XOr     EAX,EDX
        Sub     EAX,EDX

        Sub     EAX,[EBX+vMaxR]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [EBX+vMaxR],EAX

        Jmp     short %%Done

    %%ChFloat:
%ifdef HOST64
        Mov     EAX,[RSP+4]
        And     EAX,7FFFFFFFh

        Sub     EAX,[RBX+vMaxL]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [RBX+vMaxL],EAX

        Mov     EAX,[RSP+12]
        And     EAX,7FFFFFFFh

        Sub     EAX,[RBX+vMaxR]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [RBX+vMaxR],EAX

        Add     RSP,16
        Jmp     %%Done
%endif
        Pop     EDX                                                             ;Unused
        Pop     EAX
        And     EAX,7FFFFFFFh

        Sub     EAX,[EBX+vMaxL]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [EBX+vMaxL],EAX

        Pop     EDX                                                             ;Unused
        Pop     EAX
        And     EAX,7FFFFFFFh

        Sub     EAX,[EBX+vMaxR]
        CDQ
        Not     EDX
        And     EAX,EDX
        Add     [EBX+vMaxR],EAX

    %%Done:
%endif
%endmacro

%macro MixMaster 0
    ;Multiply samples by main volume ------
%ifdef HOST64
    Lea     RCX,[rel nowMainL]
%else
    Mov     ECX,nowMainL
%endif
    CalRamp2    1
%ifdef HOST64
    Lea     RCX,[rel nowMainR]
%else
    Mov     ECX,nowMainR
%endif
    CalRamp2    1

%ifdef HOST64
    FLd     dword [RSI]
%else
    FLd     dword [ESI]
%endif
    FMul    dword [nowMainL]
    Mov     AH,[scr700mds+S700_MVOL_L]
    Test    AH,S700_VOLUME                                                      ;AH and S700_VOLUME = S700_VOLUME?
    JZ      short %%NoMainL                                                     ;   No
        FIMul   dword [scr700mvl+S700_MVOL_L*4]
        FMul    dword [fpShR16]

    %%NoMainL:
%ifdef HOST64
    FStP    dword [RSI]
%else
    FStP    dword [ESI]
%endif

%ifdef HOST64
    FLd     dword [RSI+4]
%else
    FLd     dword [4+ESI]
%endif
    FMul    dword [nowMainR]
    Mov     AH,[scr700mds+S700_MVOL_R]
    Test    AH,S700_VOLUME                                                      ;AH and S700_VOLUME = S700_VOLUME?
    JZ      short %%NoMainR                                                     ;   No
        FIMul   dword [scr700mvl+S700_MVOL_R*4]
        FMul    dword [fpShR16]

    %%NoMainR:
%ifdef HOST64
    FStP    dword [RSI+4]
%else
    FStP    dword [4+ESI]
%endif
%endmacro

%macro MixEchoDSP 0
    Mov     EDI,[echoMaxD]
    Sub     EDI,[echoCurD]
%ifdef HOST64
    Lea     RAX,[rel echoBuf]
    Add     RDI,RAX
%else
    Add     EDI,echoBuf
%endif

%ifdef HOST64
    ZeroDN  RDI+4
    ZeroDN  RDI
%else
    ZeroDN  4+EDI
    ZeroDN  EDI
%endif

%ifdef HOST64
    FLd     dword [RDI+4]                                                       ;                                   |FBR
    FLd     dword [RDI]                                                         ;                                   |FBR FBL
%else
    FLd     dword [4+EDI]                                                       ;                                   |FBR
    FLd     dword [EDI]                                                         ;                                   |FBR FBL
%endif

    ;Filter echo -----------------------
    Test    dword [dspOpts],DSP_NOFIR                                           ;Is FIR filter disabled?
    JNZ     %%NoFilter                                                          ;   Yes
        FIRFilter
    %%NoFilter:

    FLd     ST1                                                                 ;                                   |FBR FBL FBR
    FLd     ST1                                                                 ;                                   |FBR FBL FBR FBL

    ;Advance echo sample pointer -------
    Sub     dword [echoCurD],8
    JNZ     short %%NoReset
        Mov     EAX,[echoLenD]
        Mov     [echoMaxD],EAX
        Mov     [echoCurD],EAX

    %%NoReset:

    ;Add echo to main output -----------
%ifdef HOST64
    Lea     RCX,[rel nowEchoL]
%else
    Mov     ECX,nowEchoL
%endif
    CalRamp2
%ifdef HOST64
    Lea     RCX,[rel nowEchoR]
%else
    Mov     ECX,nowEchoR
%endif
    CalRamp2

    FMul    dword [nowEchoL]                                                    ;                                   |FBR FBL FBR FBL*EchoL
    Mov     AH,[scr700mds+S700_ECHO_L]
    Test    AH,S700_VOLUME                                                      ;AH and S700_VOLUME = S700_VOLUME?
    JZ      short %%NoEchoL                                                     ;   No
        FIMul   dword [scr700mvl+S700_ECHO_L*4]
        FMul    dword [fpShR16]

    %%NoEchoL:
%ifdef HOST64
    FAdd    dword [RSI]                                                         ;                                   |FBR FBL FBR EchoL+ML
    FStP    dword [RSI]                                                         ;                                   |FBR FBL FBR
%else
    FAdd    dword [ESI]                                                         ;                                   |FBR FBL FBR EchoL+ML
    FStP    dword [ESI]                                                         ;                                   |FBR FBL FBR
%endif

    FMul    dword [nowEchoR]                                                    ;                                   |FBR FBL FBR*EchoR
    Mov     AH,[scr700mds+S700_ECHO_R]
    Test    AH,S700_VOLUME                                                      ;AH and S700_VOLUME = S700_VOLUME?
    JZ      short %%NoEchoR                                                     ;   No
        FIMul   dword [scr700mvl+S700_ECHO_R*4]
        FMul    dword [fpShR16]

    %%NoEchoR:
%ifdef HOST64
    FAdd    dword [RSI+4]                                                       ;                                   |FBR FBL FBR+MR
    FStP    dword [RSI+4]                                                       ;                                   |FBR FBL
%else
    FAdd    dword [4+ESI]                                                       ;                                   |FBR FBL FBR+MR
    FStP    dword [4+ESI]                                                       ;                                   |FBR FBL
%endif

    ;Calculate echo feedback -----------
%if STEREO
    FLd     ST                                                                  ;                                   |FBR FBL FBL
    FMul    dword [echoFB]                                                      ;                                   |FBR FBL FBL*EchoFB
    FLd     ST2                                                                 ;                                   |FBR FBL EFBL FBR
    FMul    dword [echoFBCT]                                                    ;                                   |FBR FBL EFBL FBR*EchoFBCT
    FAddP   ST1,ST                                                              ;                                   |FBR FBL EFBL+EFBCR
%ifdef HOST64
    FAdd    dword [RSI+8]                                                       ;                                   |FBR FBL EFBL+EL
    FStP    dword [RDI]                                                         ;                                   |FBR FBL
    ZeroDNEFB   RDI
%else
    FAdd    dword [8+ESI]                                                       ;                                   |FBR FBL EFBL+EL
    FStP    dword [EDI]                                                         ;                                   |FBR FBL
    ZeroDNEFB   EDI
%endif

    FMul    dword [echoFBCT]                                                    ;                                   |FBR FBL*EchoFBCT
    FXCh    ST1                                                                 ;                                   |EFBCL FBR
    FMul    dword [echoFB]                                                      ;                                   |EFBCL FBR*EchoFB
    FAddP   ST1,ST                                                              ;                                   |EFBCL+EFBR
%ifdef HOST64
    FAdd    dword [RSI+12]                                                      ;                                   |EFBR+ER
    FStP    dword [RDI+4]                                                       ;                                   |(empty)
    ZeroDNEFB   RDI+4
%else
    FAdd    dword [12+ESI]                                                      ;                                   |EFBR+ER
    FStP    dword [4+EDI]                                                       ;                                   |(empty)
    ZeroDNEFB   4+EDI
%endif
%else
    FMul    dword [echoFB]                                                      ;                                   |FBR FBL*EchoFB
%ifdef HOST64
    FAdd    dword [RSI+8]                                                       ;                                   |FBR EFBL+EL
    FStP    dword [RDI]                                                         ;                                   |FBR
    ZeroDNEFB   RDI
%else
    FAdd    dword [8+ESI]                                                       ;                                   |FBR EFBL+EL
    FStP    dword [EDI]                                                         ;                                   |FBR
    ZeroDNEFB   EDI
%endif

    FMul    dword [echoFB]                                                      ;                                   |FBR*EchoFB
%ifdef HOST64
    FAdd    dword [RSI+12]                                                      ;                                   |EFBR+ER
    FStP    dword [RDI+4]                                                       ;                                   |(empty)
    ZeroDNEFB   RDI+4
%else
    FAdd    dword [12+ESI]                                                      ;                                   |EFBR+ER
    FStP    dword [4+EDI]                                                       ;                                   |(empty)
    ZeroDNEFB   4+EDI
%endif
%endif
%endmacro

%macro MixEchoMem 0
    Push    EBX,ECX
    Mov     EDX,[echoDecM]
    Sub     EDX,32000
    JNS     short %%Skip

    Push    ECX                                                                 ;Dummy stack
%ifdef HOST64
    FLd     dword [RDI]
    FIStP   word [RSP]
    FLd     dword [RDI+4]
    FIStP   word [RSP+2]
%else
    FLd     dword [EDI]
    FIStP   word [ESP]
    FLd     dword [4+EDI]
    FIStP   word [2+ESP]
%endif
    Pop     ECX                                                                 ;ECX = [ESP] (dword)
    And     ECX,~1 & ~10000h                                                    ;All numbers used by DSP are even

    %%Loop:
%ifdef HOST64
    Mov     R8,[pAPURAM]
    MovZX   EBX,byte [dsp+esa]
    ShL     EBX,8
    Mov     EAX,[echoMaxM]
    Sub     EAX,[echoCurM]
    Add     EBX,EAX
    Mov     [R8+RBX],ECX
%else
    Mov     EBX,[pAPURAM]
    Mov     BH,[dsp+esa]
    Mov     EAX,[echoMaxM]
    Sub     EAX,[echoCurM]
    Add     BX,AX
    Mov     [EBX],ECX
%endif

    Sub     dword [echoCurM],4
    JNZ     short %%NoReset
        Mov     EAX,[echoLenM]
        Mov     [echoMaxM],EAX
        Mov     [echoCurM],EAX

    %%NoReset:
    Add     EDX,[dspRate]
    JS      short %%Loop

    %%Skip:
    Mov     [echoDecM],EDX
    Pop     ECX,EBX
%endmacro

%macro NopEchoMem 0
    Mov     EDX,[echoDecM]
    Sub     EDX,32000
    JNS     short %%Skip

    %%Loop:
    Sub     dword [echoCurM],4
    JNZ     short %%NoReset
        Mov     EAX,[echoLenM]
        Mov     [echoMaxM],EAX
        Mov     [echoCurM],EAX

    %%NoReset:
    Add     EDX,[dspRate]
    JS      short %%Loop

    %%Skip:
    Mov     [echoDecM],EDX
%endmacro

%macro MixBASS 0
    ;Save Current Sample --------------
    Mov     ECX,[lowCnt1]                                                       ;ECX = Cnt1
    Mov     EDX,[lowCnt2]                                                       ;EDX = Cnt2

%ifdef HOST64
    Mov     EAX,[RSI]                                                           ;EAX = Current Sample (Left)
%else
    Mov     EAX,[ESI]                                                           ;EAX = Current Sample (Left)
%endif
%ifdef HOST64
    Lea     RBX,[rel lowBufL1]
    Mov     [RBX+RCX],EAX                                                       ;BufL1[ECX] = EAX
    Lea     RBX,[rel lowBufL2]
    Mov     [RBX+RDX],EAX                                                       ;BufL2[EDX] = EAX
%else
    Mov     [lowBufL1+ECX],EAX                                                  ;BufL1[ECX] = EAX
    Mov     [lowBufL2+EDX],EAX                                                  ;BufL2[EDX] = EAX
%endif
    Push    EAX                                                                 ;Push EAX (Save Current Sample)

%ifdef HOST64
    Mov     EAX,[RSI+4]                                                         ;EAX = Current Sample (Right)
%else
    Mov     EAX,[ESI+4]                                                         ;EAX = Current Sample (Right)
%endif
%ifdef HOST64
    Lea     RBX,[rel lowBufR1]
    Mov     [RBX+RCX],EAX                                                       ;BufR1[ECX] = EAX
    Lea     RBX,[rel lowBufR2]
    Mov     [RBX+RDX],EAX                                                       ;BufR2[EDX] = EAX
%else
    Mov     [lowBufR1+ECX],EAX                                                  ;BufR1[ECX] = EAX
    Mov     [lowBufR2+EDX],EAX                                                  ;BufR2[EDX] = EAX
%endif
    Push    EAX                                                                 ;Push EAX (Save Current Sample)

    Test    ECX,ECX                                                             ;ECX = 0x00?
    JNZ     short %%CountL                                                      ;   No
        Mov     ECX,[lowSize1]                                                  ;ECX = Size1

    %%CountL:
    Sub     ECX,4                                                               ;ECX -= 4
    Mov     [lowCnt1],ECX                                                       ;Cnt1 = ECX

    Test    EDX,EDX                                                             ;EDX = 0x00?
    JNZ     short %%CountR                                                      ;   No
        Mov     EDX,[lowSize2]                                                  ;EDX = Size2

    %%CountR:
    Sub     EDX,4                                                               ;EDX -= 4
    Mov     [lowCnt2],EDX                                                       ;Cnt2 = EDX

    ;Calculate BASS BOOST -------------
    FLd     dword [lowSumL1]                                                    ;Left                               |SumL1
%ifdef HOST64
    Lea     RBX,[rel lowBufL1]
    FSub    dword [RBX+RCX]                                                     ;                                   |SumL1-BufL1[ECX]
%else
    FSub    dword [lowBufL1+ECX]                                                ;                                   |SumL1-BufL1[ECX]
%endif
%ifdef HOST64
    FAdd    dword [RSI]                                                         ;                                   |SumL1-BufL1[ECX]+SampleL
%else
    FAdd    dword [ESI]                                                         ;                                   |SumL1-BufL1[ECX]+SampleL
%endif
    FSt     dword [lowSumL1]                                                    ;                                   |   "
    FMul    dword [lowLv1]                                                      ;                                   |BASS1=(SumL1-BufL1[EDX]+SampleL)*Lv1
    FLd     dword [lowSumL2]                                                    ;                                   |BASS1 SumL2
%ifdef HOST64
    Lea     RBX,[rel lowBufL2]
    FSub    dword [RBX+RDX]                                                     ;                                   |BASS1 SumL2-BufL2[EDX]
%else
    FSub    dword [lowBufL2+EDX]                                                ;                                   |BASS1 SumL2-BufL2[EDX]
%endif
%ifdef HOST64
    FAdd    dword [RSI]                                                         ;                                   |BASS1 SumL2-BufL2[EDX]+SampleL
%else
    FAdd    dword [ESI]                                                         ;                                   |BASS1 SumL2-BufL2[EDX]+SampleL
%endif
    FSt     dword [lowSumL2]                                                    ;                                   |   "
    FMul    dword [lowLv2]                                                      ;                                   |BASS1 BASS2=(SumL2-BufL2[EDX]+SampleL)*Lv2
    FSubP   ST1,ST                                                              ;                                   |BASS1-BASS2
%ifdef HOST64
    FAdd    dword [RSI]                                                         ;                                   |BASS1-BASS2+SampleL
    FStP    dword [RSI]                                                         ;                                   |(empty)
    ZeroDN  RSI
%else
    FAdd    dword [ESI]                                                         ;                                   |BASS1-BASS2+SampleL
    FStP    dword [ESI]                                                         ;                                   |(empty)
    ZeroDN  ESI
%endif

    FLd     dword [lowSumR1]                                                    ;Right                              |SumR1
%ifdef HOST64
    Lea     RBX,[rel lowBufR1]
    FSub    dword [RBX+RCX]                                                     ;                                   |SumR1-BufR1[ECX]
%else
    FSub    dword [lowBufR1+ECX]                                                ;                                   |SumR1-BufR1[ECX]
%endif
%ifdef HOST64
    FAdd    dword [RSI+4]                                                       ;                                   |SumR1-BufR1[ECX]+SampleR
%else
    FAdd    dword [ESI+4]                                                       ;                                   |SumR1-BufR1[ECX]+SampleR
%endif
    FSt     dword [lowSumR1]                                                    ;                                   |   "
    FMul    dword [lowLv1]                                                      ;                                   |BASS1=(SumR1-BufR1[EDX]+SampleR)*Lv1
    FLd     dword [lowSumR2]                                                    ;                                   |BASS1 SumR2
%ifdef HOST64
    Lea     RBX,[rel lowBufR2]
    FSub    dword [RBX+RDX]                                                     ;                                   |BASS1 SumR2-BufR2[EDX]
%else
    FSub    dword [lowBufR2+EDX]                                                ;                                   |BASS1 SumR2-BufR2[EDX]
%endif
%ifdef HOST64
    FAdd    dword [RSI+4]                                                       ;                                   |BASS1 SumR2-BufR2[EDX]+SampleR
%else
    FAdd    dword [ESI+4]                                                       ;                                   |BASS1 SumR2-BufR2[EDX]+SampleR
%endif
    FSt     dword [lowSumR2]                                                    ;                                   |   "
    FMul    dword [lowLv2]                                                      ;                                   |BASS1 BASS2=(SumR2-BufR2[EDX]+SampleR)*Lv2
    FSubP   ST1,ST                                                              ;                                   |BASS1-BASS2
%ifdef HOST64
    FAdd    dword [RSI+4]                                                       ;                                   |BASS1-BASS2+SampleR
    FStP    dword [RSI+4]                                                       ;                                   |(empty)
    ZeroDN  RSI+4
%else
    FAdd    dword [ESI+4]                                                       ;                                   |BASS1-BASS2+SampleR
    FStP    dword [ESI+4]                                                       ;                                   |(empty)
    ZeroDN  ESI+4
%endif

    ;Reset Buffer ---------------------
    Pop     EDX,ECX                                                             ;ECX = Current Sample (Left), EDX = (Right)

    Mov     EAX,[lowSize1]                                                      ;EAX = Size1
    Test    ECX,ECX                                                             ;ECX = 0x00?
    JNZ     short %%RstL1                                                       ;   No
        Mov     EAX,[lowRstL1]                                                  ;EAX = RstL1
        Dec     EAX                                                             ;EAX--, EAX = 0x00?
        JNZ     short %%RstL1                                                   ;   No
            Mov     [lowSumL1],EAX                                              ;SumL1 = EAX (0x00)
            Inc     EAX                                                         ;EAX++ (0x01)

    %%RstL1:
    Mov     [lowRstL1],EAX                                                      ;RstL1 = EAX

    Mov     EAX,[lowSize2]                                                      ;EAX = Size2
    Test    ECX,ECX                                                             ;ECX = 0x00?
    JNZ     short %%RstL2                                                       ;   No
        Mov     EAX,[lowRstL2]                                                  ;EAX = RstL2
        Dec     EAX                                                             ;EAX--, EAX = 0x00?
        JNZ     short %%RstL2                                                   ;   No
            Mov     [lowSumL2],EAX                                              ;SumL2 = EAX (0x00)
            Inc     EAX                                                         ;EAX++ (0x01)

    %%RstL2:
    Mov     [lowRstL2],EAX                                                      ;RstL2 = EAX

    Mov     EAX,[lowSize1]                                                      ;EAX = Size1
    Test    EDX,EDX                                                             ;EDX = 0x00?
    JNZ     short %%RstR1                                                       ;   No
        Mov     EAX,[lowRstR1]                                                  ;EAX = RstR1
        Dec     EAX                                                             ;EAX--, EAX = 0x00?
        JNZ     short %%RstR1                                                   ;   No
            Mov     [lowSumR1],EAX                                              ;SumR1 = EAX (0x00)
            Inc     EAX                                                         ;EAX++ (0x01)

    %%RstR1:
    Mov     [lowRstR1],EAX                                                      ;RstR1 = EAX

    Mov     EAX,[lowSize2]                                                      ;EAX = Size2
    Test    EDX,EDX                                                             ;EDX = 0x00?
    JNZ     short %%RstR2                                                       ;   No
        Mov     EAX,[lowRstR2]                                                  ;EAX = RstR2
        Dec     EAX                                                             ;EAX--, EAX = 0x00?
        JNZ     short %%RstR2                                                   ;   No
            Mov     [lowSumR2],EAX                                              ;SumR2 = EAX (0x00)
            Inc     EAX                                                         ;EAX++ (0x01)

    %%RstR2:
    Mov     [lowRstR2],EAX                                                      ;RstR2 = EAX
%endmacro

%macro ApplyLevel 0
%if VMETERM
%ifdef HOST64
    Mov     EAX,[RSI]                                                           ;EAX = |Left|
%else
    Mov     EAX,[ESI]                                                           ;EAX = |Left|
%endif
    And     EAX,7FFFFFFFh

    Test    dword [dspOpts],DSP_NOSAFE                                          ;Is volume safe disabled?
    JNZ     short %%NoMaxL                                                      ;   Yes
    Cmp     EAX,[fpMaxLv]
    JBE     short %%NoMaxL
        Mov     byte [dspMute],80h
        Or      byte [disFlag],80h

    %%NoMaxL:
    Sub     EAX,[vMMaxL]                                                        ;*** Positive floats can be operated on as integers ***
    CDQ
    Not     EDX
    And     EAX,EDX
    Add     [vMMaxL],EAX

%ifdef HOST64
    Mov     EAX,[RSI+4]                                                         ;EAX = |Right|
%else
    Mov     EAX,[4+ESI]                                                         ;EAX = |Right|
%endif
    And     EAX,7FFFFFFFh

    Test    dword [dspOpts],DSP_NOSAFE                                          ;Is volume safe disabled?
    JNZ     short %%NoMaxR                                                      ;   Yes
    Cmp     EAX,[fpMaxLv]
    JBE     short %%NoMaxR
        Mov     byte [dspMute],80h
        Or      byte [disFlag],80h

    %%NoMaxR:
    Sub     EAX,[vMMaxR]                                                        ;*** Positive floats can be operated on as integers ***
    CDQ
    Not     EDX
    And     EAX,EDX
    Add     [vMMaxR],EAX
%endif
%endmacro

%macro MixAAF 0
    Push    ESI,EBP

    %%Next:
        FLd     dword [aafBufL]                                                 ;Left:Filter1                       |z1
%ifdef HOST64
        FLd     dword [RSI]                                                     ;                                   |z1 in
%else
        FLd     dword [ESI]                                                     ;                                   |z1 in
%endif
        FLd     ST1                                                             ;                                   |z1 in z1
        FMul    dword [aaf1A1]                                                  ;                                   |z1 in z1*a1
        FSubP   ST1,ST                                                          ;                                   |z1 in-z1*a1
        FSt     dword [aafBufL]                                                 ;                                   |z1 in-z1*a1
        FMul    dword [aaf1B0]                                                  ;                                   |z1 (in-z1*a1)*b0
        FLd     ST1                                                             ;                                   |z1 (in-z1*a1)*b0 z1
        FMul    dword [aaf1B1]                                                  ;                                   |z1 (in-z1*a1)*b0 z1*b1
        FAddP   ST1,ST                                                          ;                                   |z1 (in-z1*a1)*b0+z1*b1=out
%ifdef HOST64
        FStP    dword [RSI]                                                     ;                                   |z1
%else
        FStP    dword [ESI]                                                     ;                                   |z1
%endif
        FStP    ST                                                              ;                                   |(empty)
%ifdef HOST64
        ZeroDN  RSI
%else
        ZeroDN  ESI
%endif

        FLd     dword [aafBufL]                                                 ;Left:Filter2                       |z1
%ifdef HOST64
        FLd     dword [RSI]                                                     ;                                   |z1 in
%else
        FLd     dword [ESI]                                                     ;                                   |z1 in
%endif
        FLd     ST1                                                             ;                                   |z1 in z1
        FMul    dword [aaf2A1]                                                  ;                                   |z1 in z1*a1
        FSubP   ST1,ST                                                          ;                                   |z1 in-z1*a1
        FMul    dword [aaf2B0]                                                  ;                                   |z1 (in-z1*a1)*b0
        FLd     ST1                                                             ;                                   |z1 (in-z1*a1)*b0 z1
        FMul    dword [aaf2B1]                                                  ;                                   |z1 (in-z1*a1)*b0 z1*b1
        FAddP   ST1,ST                                                          ;                                   |z1 (in-z1*a1)*b0+z1*b1=in
        FLd     ST1                                                             ;                                   |z1 in z1
        FMul    dword [aaf2A1]                                                  ;                                   |z1 in z1*a1
        FSubP   ST1,ST                                                          ;                                   |z1 in-z1*a1
        FSt     dword [aafBufL]                                                 ;                                   |z1 in-z1*a1
        FMul    dword [aaf2B0]                                                  ;                                   |z1 (in-z1*a1)*b0
        FLd     ST1                                                             ;                                   |z1 (in-z1*a1)*b0 z1
        FMul    dword [aaf2B1]                                                  ;                                   |z1 (in-z1*a1)*b0 z1*b1
        FAddP   ST1,ST                                                          ;                                   |z1 (in-z1*a1)*b0+z1*b1=out
%ifdef HOST64
        FStP    dword [RSI]                                                     ;                                   |z1
%else
        FStP    dword [ESI]                                                     ;                                   |z1
%endif
        FStP    ST                                                              ;                                   |(empty)
%ifdef HOST64
        ZeroDN  RSI
%else
        ZeroDN  ESI
%endif

        FLd     dword [aafBufR]                                                 ;Right:Filter1                      |z1
%ifdef HOST64
        FLd     dword [RSI+4]                                                   ;                                   |z1 in
%else
        FLd     dword [ESI+4]                                                   ;                                   |z1 in
%endif
        FLd     ST1                                                             ;                                   |z1 in z1
        FMul    dword [aaf1A1]                                                  ;                                   |z1 in z1*a1
        FSubP   ST1,ST                                                          ;                                   |z1 in-z1*a1
        FSt     dword [aafBufR]                                                 ;                                   |z1 in-z1*a1
        FMul    dword [aaf1B0]                                                  ;                                   |z1 (in-z1*a1)*b0
        FLd     ST1                                                             ;                                   |z1 (in-z1*a1)*b0 z1
        FMul    dword [aaf1B1]                                                  ;                                   |z1 (in-z1*a1)*b0 z1*b1
        FAddP   ST1,ST                                                          ;                                   |z1 (in-z1*a1)*b0+z1*b1=out
%ifdef HOST64
        FStP    dword [RSI+4]                                                   ;                                   |z1
%else
        FStP    dword [ESI+4]                                                   ;                                   |z1
%endif
        FStP    ST                                                              ;                                   |(empty)
%ifdef HOST64
        ZeroDN  RSI+4
%else
        ZeroDN  ESI+4
%endif

        FLd     dword [aafBufR]                                                 ;Right:Filter2                      |z1
%ifdef HOST64
        FLd     dword [RSI+4]                                                   ;                                   |z1 in
%else
        FLd     dword [ESI+4]                                                   ;                                   |z1 in
%endif
        FLd     ST1                                                             ;                                   |z1 in z1
        FMul    dword [aaf2A1]                                                  ;                                   |z1 in z1*a1
        FSubP   ST1,ST                                                          ;                                   |z1 in-z1*a1
        FMul    dword [aaf2B0]                                                  ;                                   |z1 (in-z1*a1)*b0
        FLd     ST1                                                             ;                                   |z1 (in-z1*a1)*b0 z1
        FMul    dword [aaf2B1]                                                  ;                                   |z1 (in-z1*a1)*b0 z1*b1
        FAddP   ST1,ST                                                          ;                                   |z1 (in-z1*a1)*b0+z1*b1=in
        FLd     ST1                                                             ;                                   |z1 in z1
        FMul    dword [aaf2A1]                                                  ;                                   |z1 in z1*a1
        FSubP   ST1,ST                                                          ;                                   |z1 in-z1*a1
        FSt     dword [aafBufR]                                                 ;                                   |z1 in-z1*a1
        FMul    dword [aaf2B0]                                                  ;                                   |z1 (in-z1*a1)*b0
        FLd     ST1                                                             ;                                   |z1 (in-z1*a1)*b0 z1
        FMul    dword [aaf2B1]                                                  ;                                   |z1 (in-z1*a1)*b0 z1*b1
        FAddP   ST1,ST                                                          ;                                   |z1 (in-z1*a1)*b0+z1*b1=out
%ifdef HOST64
        FStP    dword [RSI+4]                                                   ;                                   |z1
%else
        FStP    dword [ESI+4]                                                   ;                                   |z1
%endif
        FStP    ST                                                              ;                                   |(empty)
%ifdef HOST64
        ZeroDN  RSI+4
%else
        ZeroDN  ESI+4
%endif

%ifdef HOST64
        Add     RSI,16
%else
        Add     ESI,16
%endif

    Dec     EBP
    JNZ     %%Next

    Pop     EBP,ESI
%endmacro

%macro InitSampling 0
    XOr     EBX,EBX
    XOr     EDX,EDX

    Mov     EAX,[smpCnt]                                                        ;smpCnt = (smpCnt + smpDec) % smpRate
    Add     EAX,[smpDec]
    Cmp     EAX,[smpRate]
    SetB    BL
    Dec     EBX
    And     EBX,[smpRate]
    Sub     EAX,EBX                                                             ;If the number of times is the least common multiple of
    SetZ    DL                                                                  ; smpRate and dspRate, DL = 1
    Mov     [smpCnt],EAX

    Mov     EAX,[smpCur]                                                        ;smpCur += smpAdj
    Add     EAX,[smpAdj]
    SetC    BL                                                                  ;If the next sample is reached, BL = 1
    XOr     DL,BL                                                               ;If smpCur completes one cycle without error, DL = 0
    Mov     EBX,[smpAdj]
    Sub     EAX,EBX
    Add     EBX,EDX
    Add     EAX,EBX                                                             ;Add at once including error
    SetNC   DL                                                                  ;If don't have enough samples, DL = 1
    Mov     [smpCur],EAX

    XOr     EBX,EBX                                                             ;If smpRst completes one cycle,
    Dec     dword [smpRst]                                                      ;   reset smpCur, smpCnt, smpRst, and DL = 0
    SetZ    BL                                                                  ;   (probably DL is already 0, just to be sure)
    Dec     EBX
    And     [smpCur],EBX
    And     [smpCnt],EBX
    And     DL,BL
    Not     EBX
    And     EBX,[smpDen]
    Or      [smpRst],EBX

    Add     EBP,EDX
%endmacro

%macro Resampling 0
    Test    dword [smpAdj],-1                                                   ;Convert sample rate?
    JZ      %%Direct                                                            ;   No

    InitSampling

%ifdef HOST64
    Lea     RBX,[rel smpBuf]
%else
    Mov     EBX,smpBuf
%endif
    Dec     DL                                                                  ;Has the sample reference point moved?
    JZ      short %%Filter                                                      ;   No, don't move sample history
        Mov     DL,3

        %%Tap:
%ifdef HOST64
            Mov     EAX,[RBX+8]
            Mov     [RBX],EAX
            Mov     EAX,[RBX+12]
            Mov     [RBX+4],EAX

            Add     RBX,8
%else
            Mov     EAX,[8+EBX]
            Mov     [EBX],EAX
            Mov     EAX,[12+EBX]
            Mov     [4+EBX],EAX

            Add     EBX,8
%endif

        Dec     DL
        JNZ     short %%Tap

%ifdef HOST64
        Mov     EAX,[RSI]                                                       ;Store the latest sample to history
        Mov     [RBX],EAX
        Mov     EAX,[RSI+4]
        Mov     [RBX+4],EAX

        Add     RBX,-24
        Add     RSI,16
%else
        Mov     EAX,[ESI]                                                       ;Store the latest sample to history
        Mov     [EBX],EAX
        Mov     EAX,[4+ESI]
        Mov     [4+EBX],EAX

        Add     EBX,-24
        Add     ESI,16
%endif

    %%Filter:
        Mov     EAX,[smpCur]
        ShR     EAX,2                                                           ;Shift right by 2 bits to prevent the sign from
%ifdef HOST64
        Mov     [RSP-12],EAX                                                    ; entering (max = 40000000h)
        FILd    dword [RSP-12]
        Mov     dword [RSP-12],40000000h
        FILd    dword [RSP-12]
%else
        Mov     [ESP-12],EAX                                                    ; entering (max = 40000000h)
        FILd    dword [ESP-12]
        Mov     dword [ESP-12],40000000h
        FILd    dword [ESP-12]
%endif
        FDivP   ST1,ST
%ifdef HOST64
        FStP    dword [RSP-12]

        FLd     dword [RBX+24]                                                  ;A                                  |s3
        FSub    dword [RBX+16]                                                  ;                                   |s3-s2
        FSub    dword [RBX]                                                     ;                                   |s3-s2-s0
        FAdd    dword [RBX+8]                                                   ;                                   |s3-s2-s0+s1=A'
        FMul    dword [RSP-12]                                                  ;                                   |A'*Frac
        FMul    dword [RSP-12]                                                  ;                                   |A'*Frac^2
        FMul    dword [RSP-12]                                                  ;                                   |A'*Frac^3=A
        FLd     dword [RBX]                                                     ;B                                  |A s0
        FSub    dword [RBX+8]                                                   ;                                   |A s0-s1
%else
        FStP    dword [ESP-12]

        FLd     dword [24+EBX]                                                  ;A                                  |s3
        FSub    dword [16+EBX]                                                  ;                                   |s3-s2
        FSub    dword [EBX]                                                     ;                                   |s3-s2-s0
        FAdd    dword [8+EBX]                                                   ;                                   |s3-s2-s0+s1=A'
        FMul    dword [ESP-12]                                                  ;                                   |A'*Frac
        FMul    dword [ESP-12]                                                  ;                                   |A'*Frac^2
        FMul    dword [ESP-12]                                                  ;                                   |A'*Frac^3=A
        FLd     dword [EBX]                                                     ;B                                  |A s0
        FSub    dword [8+EBX]                                                   ;                                   |A s0-s1
%endif
        FSub    ST,ST1                                                          ;                                   |A s0-s1-A=B'
%ifdef HOST64
        FMul    dword [RSP-12]                                                  ;                                   |A B'*Frac
        FMul    dword [RSP-12]                                                  ;                                   |A B'*Frac^2=B
        FLd     dword [RBX+16]                                                  ;C                                  |A B s2
        FSub    dword [RBX]                                                     ;                                   |A B s2-s0=C'
        FMul    dword [RSP-12]                                                  ;                                   |A B C'*Frac=C
        FLd     dword [RBX+8]                                                   ;D                                  |A B C s1=D
%else
        FMul    dword [ESP-12]                                                  ;                                   |A B'*Frac
        FMul    dword [ESP-12]                                                  ;                                   |A B'*Frac^2=B
        FLd     dword [16+EBX]                                                  ;C                                  |A B s2
        FSub    dword [EBX]                                                     ;                                   |A B s2-s0=C'
        FMul    dword [ESP-12]                                                  ;                                   |A B C'*Frac=C
        FLd     dword [8+EBX]                                                   ;D                                  |A B C s1=D
%endif
        FAddP   ST1,ST                                                          ;                                   |A B C+D
        FAddP   ST1,ST                                                          ;                                   |A B+C+D
        FAddP   ST1,ST                                                          ;                                   |A+B+C+D
%ifdef HOST64
        FStP    dword [RSP-8]                                                   ;                                   |(empty)
        ZeroDN  RSP-8

        FLd     dword [RBX+28]                                                  ;A                                  |s3
        FSub    dword [RBX+20]                                                  ;                                   |s3-s2
        FSub    dword [RBX+4]                                                   ;                                   |s3-s2-s0
        FAdd    dword [RBX+12]                                                  ;                                   |s3-s2-s0+s1=A'
        FMul    dword [RSP-12]                                                  ;                                   |A'*Frac
        FMul    dword [RSP-12]                                                  ;                                   |A'*Frac^2
        FMul    dword [RSP-12]                                                  ;                                   |A'*Frac^3=A
        FLd     dword [RBX+4]                                                   ;B                                  |A s0
        FSub    dword [RBX+12]                                                  ;                                   |A s0-s1
%else
        FStP    dword [ESP-8]                                                   ;                                   |(empty)
        ZeroDN  ESP-8

        FLd     dword [28+EBX]                                                  ;A                                  |s3
        FSub    dword [20+EBX]                                                  ;                                   |s3-s2
        FSub    dword [4+EBX]                                                   ;                                   |s3-s2-s0
        FAdd    dword [12+EBX]                                                  ;                                   |s3-s2-s0+s1=A'
        FMul    dword [ESP-12]                                                  ;                                   |A'*Frac
        FMul    dword [ESP-12]                                                  ;                                   |A'*Frac^2
        FMul    dword [ESP-12]                                                  ;                                   |A'*Frac^3=A
        FLd     dword [4+EBX]                                                   ;B                                  |A s0
        FSub    dword [12+EBX]                                                  ;                                   |A s0-s1
%endif
        FSub    ST,ST1                                                          ;                                   |A s0-s1-A=B'
%ifdef HOST64
        FMul    dword [RSP-12]                                                  ;                                   |A B'*Frac
        FMul    dword [RSP-12]                                                  ;                                   |A B'*Frac^2=B
        FLd     dword [RBX+20]                                                  ;C                                  |A B s2
        FSub    dword [RBX+4]                                                   ;                                   |A B s2-s0=C'
        FMul    dword [RSP-12]                                                  ;                                   |A B C'*Frac=C
        FLd     dword [RBX+12]                                                  ;D                                  |A B C s1=D
%else
        FMul    dword [ESP-12]                                                  ;                                   |A B'*Frac
        FMul    dword [ESP-12]                                                  ;                                   |A B'*Frac^2=B
        FLd     dword [20+EBX]                                                  ;C                                  |A B s2
        FSub    dword [4+EBX]                                                   ;                                   |A B s2-s0=C'
        FMul    dword [ESP-12]                                                  ;                                   |A B C'*Frac=C
        FLd     dword [12+EBX]                                                  ;D                                  |A B C s1=D
%endif
        FAddP   ST1,ST                                                          ;                                   |A B C+D
        FAddP   ST1,ST                                                          ;                                   |A B+C+D
        FAddP   ST1,ST                                                          ;                                   |A+B+C+D
%ifdef HOST64
        FStP    dword [RSP-4]                                                   ;                                   |(empty)
        ZeroDN  RSP-4
%else
        FStP    dword [ESP-4]                                                   ;                                   |(empty)
        ZeroDN  ESP-4
%endif

        Jmp     short %%Exit

    %%Direct:
%ifdef HOST64
        Mov     EAX,[RSI]
        Mov     [RSP-8],EAX
        Mov     EAX,[RSI+4]
        Mov     [RSP-4],EAX

        Add     RSI,16
%else
        Mov     EAX,[ESI]
        Mov     [ESP-8],EAX
        Mov     EAX,[4+ESI]
        Mov     [ESP-4],EAX

        Add     ESI,16
%endif

    %%Exit:
%endmacro

%macro MuteSampling 0
    Test    dword [smpAdj],-1                                                   ;Convert sample rate?
    JZ      %%Exit                                                              ;   No

    InitSampling

%ifdef HOST64
    Lea     RBX,[rel smpBuf]
%else
    Mov     EBX,smpBuf
%endif
    Dec     DL                                                                  ;Has the sample reference point moved?
    JZ      short %%Exit                                                        ;   No, don't move sample history
        Mov     DL,3

        %%Tap:
%ifdef HOST64
            Mov     EAX,[RBX+8]
            Mov     [RBX],EAX
            Mov     EAX,[RBX+12]
            Mov     [RBX+4],EAX

            Add     RBX,8
%else
            Mov     EAX,[8+EBX]
            Mov     [EBX],EAX
            Mov     EAX,[12+EBX]
            Mov     [4+EBX],EAX

            Add     EBX,8
%endif

        Dec     DL
        JNZ     short %%Tap

%ifdef HOST64
        FSt     dword [RBX]                                                     ;Store the latest sample to history
        FSt     dword [RBX+4]
%else
        FSt     dword [EBX]                                                     ;Store the latest sample to history
        FSt     dword [4+EBX]
%endif

    %%Exit:
%endmacro

%macro DoneRunDSP 0
    Pop     EDX,EAX,EBX,EBP
    StC                                                                         ;Set carry
%ifdef HOST64
    Mov     RAX,RDI
    RetN
%else
    RetN    EDI
%endif
%endmacro

;===================================================================================================
;Run DSP emulation
;
;Emulates the DSP of the SNES using floating-point instructions.
;If no mixing flag is set on, except for pitch modulation, noise generator, and mixing.
;
;In:
;   EAX-> Buffer to store output
;   EDX = Number of samples to create (1 - MIX_SIZE)
;
;Out:
;   CF  = Set, samples were created
;   EAX-> End of buffer
;   EDX = Number of samples to create
;
;   CF  = Clear, DSP is muted
;   EDI-> Buffer to store output
;   EDX = Number of samples to create
;
;Destroys:
;   ECX,ESI,EDI,ST0-ST7

PROC RunDSP

    Push    EBP,EBX,EAX,EDX                                                     ;Last register must be EAX,EDX
    FInit

    Test    byte [disFlag],80h                                                  ;Is DSP reset or volume safe mode? (disFlag = [7])
    JNZ     .Mute                                                               ;   Yes

    ;=========================================
    ; Mix voices

%ifdef HOST64
    Mov     EBP,[RSP]
%else
    Mov     EBP,[ESP]
%endif
%ifdef HOST64
    Lea     RDI,[rel mixBuf]
%else
    Mov     EDI,mixBuf
%endif

    .NextEmu:
        ;Generate Noise -----------------------
        NoiseGen

        Mov     EAX,[adsrAdj]                                                   ;Calculate number of times to update envelope
        Add     [adsrClk],EAX

        Test    dword [dspOpts],DSP_ENVSPD                                      ;Is synchronize envelope updates enabled?
        SetZ    CL                                                              ;   When yes, adsrCnt is not cleared
        Dec     CL                                                              ;   When no, always adsrCnt is set 1
        And     [adsrCnt],CL
        Inc     CL
        Or      [adsrCnt],CL

        ;Voice Loop ---------------------------
        XOr     ECX,ECX
        XOr     EAX,EAX
%ifdef HOST64
        Lea     RBX,[rel mix]
%else
        Mov     EBX,mix
%endif
%ifdef HOST64
        Mov     [RDI],EAX
        Mov     [RDI+4],EAX
        Mov     [RDI+8],EAX
        Mov     [RDI+12],EAX
%else
        Mov     [EDI],EAX
        Mov     [4+EDI],EAX
        Mov     [8+EDI],EAX
        Mov     [12+EDI],EAX
%endif
        Mov     CH,1

        .VoiceMix:
            Test    [voiceMix],CH
            JZ      .VoiceDone

            Test    [dspPMod],CH                                                ;Is pitch modulation enabled?
            JZ      short .NoPMod                                               ;   No, pitch doesn't need to be adjusted
                PitchMod                                                        ;Apply pitch modulation
            .NoPMod:

	            Test    byte [envFlag],-1                                           ;Do nothing if envelope is suspended
	            JNZ     .NoEnv
	                Push    ECX
	                UpdateEnv                                                       ;Update envelope
	                Pop     ECX
	            .NoEnv:

            MixSample                                                           ;                                   |smp
            MixVoice

	        .VoiceOff:
	        FStP    ST                                                          ;                                   |(empty)
	        UpdateSrc                                                           ;Update sample position

	        .VoiceDone:
%ifdef HOST64
	        Sub     RBX,-80h
%else
	        Sub     EBX,-80h
%endif

	    Add     CH,CH
	    JNZ     .VoiceMix

        Mov     [adsrCnt],CH                                                    ;Clear number of times to update envelope
%ifdef HOST64
        Add     RDI,16
%else
        Add     EDI,16
%endif

    Dec     EBP
    JNZ     .NextEmu

    Test    byte [disFlag],8h                                                   ;Is pBuf NULL? (disFlag = [3])
    JNZ     .Mute                                                               ;   Yes

    ;=========================================
    ; Apply main volumes and mix in echo

%ifdef HOST64
    Mov     EBP,[RSP]
%else
    Mov     EBP,[ESP]
%endif
%ifdef HOST64
    Lea     RSI,[rel mixBuf]
%else
    Mov     ESI,mixBuf
%endif

    .NextSmp:
        Test    dword [dspOpts],DSP_NOMAIN                                      ;Is main output disabled?
        JNZ     .NoMain                                                         ;   Yes
            MixMaster
        .NoMain:

        Test    byte [disFlag],30h                                              ;Is echo disabled by DSP? (disFlag = [4][5])
        JNZ     .NoEchoDSP                                                      ;   Yes
            MixEchoDSP
        .NoEchoDSP:

        Test    byte [disFlag],31h                                              ;Is echo delay disabled? (disFlag = [0][4][5])
        JNZ     short .NoEchoMem                                                ;   Yes
            MixEchoMem
%if ECHOMEM
            Jmp     short .ExitEchoMem
%endif
        .NoEchoMem:
%if ECHOMEM
            NopEchoMem                                                          ;Increment cursor only
        .ExitEchoMem:
%endif

        Test    dword [dspOpts],DSP_BASS                                        ;Is BASS BOOST enabled?
        JZ      .NoBASS                                                         ;   No
            MixBASS
        .NoBASS:

        ApplyLevel
%ifdef HOST64
        Add     RSI,16
%else
        Add     ESI,16
%endif

    Dec     EBP
    JNZ     .NextSmp

    Test    byte [disFlag],40h                                                  ;Is DSP emulation disabled? (disFlag = [6])
    JNZ     .Mute                                                               ;   Yes

    ;=========================================
    ; Store output

%ifdef HOST64
    Lea     RSI,[rel mixBuf]
%else
    Mov     ESI,mixBuf
%endif
%ifdef HOST64
    Mov     RDI,[RSP+8]
    Mov     EBP,[RSP]
%else
    Mov     EDI,[ESP+4]
    Mov     EBP,[ESP]
%endif

    Test    dword [dspOpts],DSP_ANALOG                                          ;Is Anti-Alies filter enabled?
    JZ      .NoAAF                                                              ;   No
        MixAAF
    .NoAAF:

    Cmp     byte [dspChn],2
    JE      .OutStereo
    Cmp     byte [dspSize],-4
    JE      .OutMonoFloat

    Mov     ECX,4EFFFE00h                                                       ;ECX = 2147418112.0 (32767 << 16)

    .NextMonoInt:
        Resampling

        ;Clamp samples ------------------------
%ifdef HOST64
        Mov     EAX,[RSP-8]                                                     ;EAX = Sample
%else
        Mov     EAX,[ESP-8]                                                     ;EAX = Sample
%endif
        XOr     EDX,EDX
        XOr     EBX,EBX
        BTR     EAX,31                                                          ;EAX = Absolute value
        RCR     EDX,1                                                           ;EDX = Sign of sample
        Sub     EAX,ECX
        SetA    BL                                                              ;EBX = -1 if EAX < ECX
        Dec     EBX
        And     EAX,EBX                                                         ;Clamp EAX
        Add     EAX,ECX
        Or      EAX,EDX                                                         ;Restore sign
%ifdef HOST64
        Mov     [RSP-8],EAX
        FLd     dword [RSP-8]

        Mov     EAX,[RSP-4]
%else
        Mov     [ESP-8],EAX
        FLd     dword [ESP-8]

        Mov     EAX,[ESP-4]
%endif
        XOr     EDX,EDX
        XOr     EBX,EBX
        BTR     EAX,31
        RCR     EDX,1
        Sub     EAX,ECX
        SetA    BL
        Dec     EBX
        And     EAX,EBX
        Add     EAX,ECX
        Or      EAX,EDX
%ifdef HOST64
        Mov     [RSP-4],EAX
        FAdd    dword [RSP-4]
%else
        Mov     [ESP-4],EAX
        FAdd    dword [ESP-4]
%endif

        FMul    dword [fp0_5]

        ;Reduce to integer form ---------------
        Mov     AL,[dspSize]
        Dec     AL
        JZ      short .OutMono8
        Dec     AL
        JZ      short .OutMono16
        Dec     AL
        JZ      short .OutMono24

        .OutMono32:
%ifdef HOST64
            FIStP   dword [RDI]
            Add     RDI,4
%else
            FIStP   dword [EDI]
            Add     EDI,4
%endif

            Dec     EBP
            JNZ     .NextMonoInt
            DoneRunDSP

        .OutMono8:
%ifdef HOST64
            FIStP   dword [RSP-4]
            Mov     DL,[RSP-1]
            Add     DL,80h
            Mov     [RDI],DL
            Inc     RDI
%else
            FIStP   dword [ESP-4]
            Mov     DL,[ESP-1]
            Add     DL,80h
            Mov     [EDI],DL
            Inc     EDI
%endif

            Dec     EBP
            JNZ     .NextMonoInt
            DoneRunDSP

        .OutMono16:
%ifdef HOST64
            FIStP   dword [RSP-4]
            Mov     DX,[RSP-2]
            Mov     [RDI],DX
            Add     RDI,2
%else
            FIStP   dword [ESP-4]
            Mov     DX,[ESP-2]
            Mov     [EDI],DX
            Add     EDI,2
%endif

            Dec     EBP
            JNZ     .NextMonoInt
            DoneRunDSP

        .OutMono24:
%ifdef HOST64
            FIStP   dword [RSP-4]
            Mov     DX,[RSP-3]
            Mov     AL,[RSP-1]
            Mov     [RDI],DX
            Mov     [RDI+2],AL
            Add     RDI,3
%else
            FIStP   dword [ESP-4]
            Mov     DX,[ESP-3]
            Mov     AL,[ESP-1]
            Mov     [0+EDI],DX
            Mov     [2+EDI],AL
            Add     EDI,3
%endif

            Dec     EBP
            JNZ     .NextMonoInt
            DoneRunDSP

    ;32-bit floating-point -------------------
    .OutMonoFloat:
        Resampling

%ifdef HOST64
        FLd     dword [RSP-8]
        FAdd    dword [RSP-4]
        FMul    dword [fp0_5]
        FMul    dword [fpShR31]
        FStP    dword [RDI]
        ZeroDN  RDI
        Add     RDI,4
%else
        FLd     dword [ESP-8]
        FAdd    dword [ESP-4]
        FMul    dword [fp0_5]
        FMul    dword [fpShR31]
        FStP    dword [EDI]
        ZeroDN  EDI
        Add     EDI,4
%endif

        Dec     EBP
        JNZ     .OutMonoFloat
        DoneRunDSP

    .OutStereo:
    Cmp     byte [dspSize],-4
    JE      .OutStereoFloat

    Mov     ECX,4EFFFE00h                                                       ;ECX = 2147418112.0 (32767 << 16)

    .NextStereoInt:
        Resampling

        ;Clamp samples ------------------------
%ifdef HOST64
        Mov     EAX,[RSP-8]                                                     ;EAX = Sample
%else
        Mov     EAX,[ESP-8]                                                     ;EAX = Sample
%endif
        XOr     EDX,EDX
        XOr     EBX,EBX
        BTR     EAX,31                                                          ;EAX = Absolute value
        RCR     EDX,1                                                           ;EDX = Sign of sample
        Sub     EAX,ECX
        SetA    BL                                                              ;EBX = -1 if EAX < ECX
        Dec     EBX
        And     EAX,EBX                                                         ;Clamp EAX
        Add     EAX,ECX
        Or      EAX,EDX                                                         ;Restore sign
%ifdef HOST64
        Mov     [RSP-8],EAX
        FLd     dword [RSP-8]

        Mov     EAX,[RSP-4]
%else
        Mov     [ESP-8],EAX
        FLd     dword [ESP-8]

        Mov     EAX,[ESP-4]
%endif
        XOr     EDX,EDX
        XOr     EBX,EBX
        BTR     EAX,31
        RCR     EDX,1
        Sub     EAX,ECX
        SetA    BL
        Dec     EBX
        And     EAX,EBX
        Add     EAX,ECX
        Or      EAX,EDX
%ifdef HOST64
        Mov     [RSP-4],EAX
        FLd     dword [RSP-4]
%else
        Mov     [ESP-4],EAX
        FLd     dword [ESP-4]
%endif

        ;Reduce to integer form ---------------
        Mov     AL,[dspSize]
        Dec     AL
        JZ      short .OutStereo8
        Dec     AL
        JZ      short .OutStereo16
        Dec     AL
        JZ      short .OutStereo24

        .OutStereo32:
%ifdef HOST64
            FIStP   dword [RDI+4]
            FIStP   dword [RDI]
            Add     RDI,8
%else
            FIStP   dword [4+EDI]
            FIStP   dword [EDI]
            Add     EDI,8
%endif

            Dec     EBP
            JNZ     .NextStereoInt
            DoneRunDSP

        .OutStereo8:
%ifdef HOST64
            FIStP   dword [RSP-4]
            FIStP   dword [RSP-5]
            Mov     DX,[RSP-2]
            Add     DH,80h
            Add     DL,80h
            Mov     [RDI],DX
            Add     RDI,2
%else
            FIStP   dword [ESP-4]
            FIStP   dword [ESP-5]
            Mov     DX,[ESP-2]
            Add     DH,80h
            Add     DL,80h
            Mov     [EDI],DX
            Add     EDI,2
%endif

            Dec     EBP
            JNZ     .NextStereoInt
            DoneRunDSP

        .OutStereo16:
%ifdef HOST64
            FIStP   dword [RSP-4]
            FIStP   dword [RSP-6]
            Mov     EDX,[RSP-4]
            Mov     [RDI],EDX
            Add     RDI,4
%else
            FIStP   dword [ESP-4]
            FIStP   dword [ESP-6]
            Mov     EDX,[ESP-4]
            Mov     [EDI],EDX
            Add     EDI,4
%endif

            Dec     EBP
            JNZ     .NextStereoInt
            DoneRunDSP

        .OutStereo24:
%ifdef HOST64
            FIStP   dword [RSP-4]
            FIStP   dword [RSP-7]
            Mov     DX,[RSP-6]
            Mov     EAX,[RSP-4]
            Mov     [RDI],DX
            Mov     [RDI+2],EAX
            Add     RDI,6
%else
            FIStP   dword [ESP-4]
            FIStP   dword [ESP-7]
            Mov     DX,[ESP-6]
            Mov     EAX,[ESP-4]
            Mov     [0+EDI],DX
            Mov     [2+EDI],EAX
            Add     EDI,6
%endif

            Dec     EBP
            JNZ     .NextStereoInt
            DoneRunDSP

    ;32-bit floating-point -------------------
    .OutStereoFloat:
        Resampling

%ifdef HOST64
        FLd     dword [RSP-8]
        FMul    dword [fpShR31]
        FStP    dword [RDI]
        FLd     dword [RSP-4]
        FMul    dword [fpShR31]
        FStP    dword [RDI+4]
        ZeroDN  RDI
        ZeroDN  RDI+4
        Add     RDI,8
%else
        FLd     dword [ESP-8]
        FMul    dword [fpShR31]
        FStP    dword [EDI]
        FLd     dword [ESP-4]
        FMul    dword [fpShR31]
        FStP    dword [4+EDI]
        ZeroDN  EDI
        ZeroDN  4+EDI
        Add     EDI,8
%endif

        Dec     EBP
        JNZ     .OutStereoFloat
        DoneRunDSP

    .Mute:
%ifdef HOST64
    Mov     EBP,[RSP]
%else
    Mov     EBP,[ESP]
%endif
    XOr     EDI,EDI

    Test    byte [disFlag],8h                                                   ;Is pBuf NULL? (disFlag = [3])
    JZ      .MuteNext                                                           ;   No
    Test    dword [smpAdj],-1                                                   ;Convert sample rate?
    JZ      .MuteDone                                                           ;   No, done

    .SampleNext:
        InitSampling

    Dec     EBP
    JNZ     .SampleNext
    Jmp     .MuteDone

    .MuteNext:
        FLdZ
        MuteSampling
        FStP    ST
        Inc     EDI

    Dec     EBP
    JNZ     .MuteNext

    .MuteDone:
    Pop     EDX,EAX,EBX,EBP
    Mov     EDX,EDI
%ifdef HOST64
    Mov     RDI,RAX
    Cmp     RAX,1                                                               ;Set carry if pBuf is null, so EmuDSP doesn't crash
%else
    Mov     EDI,EAX
    Cmp     EAX,1                                                               ;Set carry if pBuf is null, so EmuDSP doesn't crash
%endif

ENDP


;===================================================================================================
;Decompress Sound Source
;
;Decompresses a 9-byte bit-rate reduced block into 16 16-bit samples
;
;In:
;   AL  = Block header
;   ESI-> Sample Block
;   EDI-> Output buffer
;   EDX = Last sample of previous block
;   EBX = Next to last sample
;
;Out:
;   ESI-> Next Block
;   EDI-> After last sample
;   EDX = Last sample
;   EBX = Next to last sample
;
;Destroys:
;   EAX

%macro UnpckFilter1 0
    ;Add 15/16 of second sample -----------
    Mov     EBX,EDX                                                             ;EBX = Next to last sample
    Neg     EDX
    SAR     EDX,5
    LEA     EAX,[EDX*2+EBX]                                                     ;s = ((-p1 >> 4) & ~1) + p1

    ;Add delta ----------------------------
%ifdef HOST64
    Add     EAX,[R8+RCX]                                                        ;s += delta
%else
    Add     EAX,[ECX]                                                           ;s += delta
%endif
    MovSX   EDX,AX                                                              ;EDX = Last sample
%endmacro

%macro UnpckFilter2 0
    ;Subtract 15/16 of second sample ------
    Mov     EAX,EBX
    Neg     EBX
    SAR     EAX,5
    LEA     EAX,[EAX*2+EBX]                                                     ;s = ((p2 >> 4) & ~1) + -p2
    Mov     EBX,EDX                                                             ;EBX = Next to last sample

    ;Add 61/32 of last sample -------------
    LEA     EAX,[EDX*2+EAX]                                                     ;s += 2 * p1
    LEA     EDX,[EDX*2+EDX]
    Neg     EDX
    SAR     EDX,6
    LEA     EAX,[EDX*2+EAX]                                                     ;s += ((-3 * p1) >> 5) & ~1

    ;Add delta ----------------------------
%ifdef HOST64
    Add     EAX,[R8+RCX]                                                        ;s += delta
%else
    Add     EAX,[ECX]                                                           ;s += delta
%endif
    MovSX   EDX,AX                                                              ;EDX = Last sample
%endmacro

%macro UnpckFilter3 0
    ;Subtract 52/64 of second sample ------
    Mov     EAX,EBX
    LEA     EBX,[EBX*2+EBX]
    SAR     EBX,5
    Neg     EAX
    LEA     EAX,[EBX*2+EAX]                                                     ;s = (((p2 * 3) >> 4) & ~1) + -p2
    Mov     EBX,EDX                                                             ;EBX = Next to last sample

    ;Add 115/64 of last sample ------------
    LEA     EAX,[EDX*2+EAX]                                                     ;s += 2 * p1
    LEA     EDX,[EBX*4+EBX]
    LEA     EDX,[EBX*8+EDX]
    Neg     EDX
    SAR     EDX,7
    LEA     EAX,[EDX*2+EAX]                                                     ;s += ((-13 * p1) >> 6) & ~1

    ;Add delta ----------------------------
%ifdef HOST64
    Add     EAX,[R8+RCX]                                                        ;s += delta
%else
    Add     EAX,[ECX]                                                           ;s += delta
%endif
    MovSX   EDX,AX                                                              ;EDX = Last sample
%endmacro

%macro UnpckClamp 0
    Add     EAX,65536                                                           ;Clamp 16-bit sample to a 17-bit value,
    SAR     EAX,17                                                              ; because restored value by BRR is used in doubles.
    JZ      short %%OK
        SetS    DL                                                              ;If s < -65536 (FFFF0000h), s = 0000h = 0
        MovZX   EDX,DL                                                          ;If s >  65534 (0000FFFEh), s = FFFEh = -2
        Dec     EDX
        Add     EDX,EDX

    %%OK:
%endmacro

UnpckSrc:

    Push    ECX,EBP
%ifdef HOST64
    push    r8
    MovZX   EAX,AL
    Mov     [dbgUnpckHdr],EAX
%endif

    Inc     SI                                                                  ;Inc SI so pointer will wrap around a 16-bit value
%ifdef HOST64
    MovZX   R8D,AL
    ShR     R8D,4
    ShL     R8D,8
%else
    XOr     ECX,ECX
    Mov     CH,AL
    ShR     CH,4
    Add     ECX,brrTab                                                          ;ECX -> Row in brrTab
%endif
    Mov     EBP,8                                                               ;Decompress 8 bytes (16 nybbles)

    Test    AL,0Ch                                                              ;Does block use ADPCM compression?
%ifdef HOST64
    JZ      .SetFilter0                                                         ;   No
    Test    AL,08h                                                              ;Does block use filter 1?
    JZ      .SetFilter1                                                         ;   Yes
    Test    AL,04h                                                              ;Does block use filter 2?
    JZ      .SetFilter2                                                         ;   Yes
    Jmp     .SetFilter3                                                         ;Then it must use filter 3

    .SetFilter0:
        Lea     RAX,[rel brrTab]
        Add     R8,RAX                                                          ;R8 -> Row in brrTab
        Jmp     .Filter0

    .SetFilter1:
        Lea     RAX,[rel brrTab]
        Add     R8,RAX                                                          ;R8 -> Row in brrTab
        Jmp     .Filter1

    .SetFilter2:
        Lea     RAX,[rel brrTab]
        Add     R8,RAX                                                          ;R8 -> Row in brrTab
        Jmp     .Filter2

    .SetFilter3:
        Lea     RAX,[rel brrTab]
        Add     R8,RAX                                                          ;R8 -> Row in brrTab
        Jmp     .Filter3
%else
    JZ      short .Filter0                                                      ;   No
    Test    AL,08h                                                              ;Does block use filter 1?
    JZ      short .Filter1                                                      ;   Yes
    Test    AL,04h                                                              ;Does block use filter 2?
    JZ      .Filter2                                                            ;   Yes
    Jmp     .Filter3                                                            ;Then it must use filter 3
%endif

    ;[Delta] ----------------------------------
    .Filter0:
%ifdef HOST64
        MovZX   EAX,byte [RSI]
        Mov     [dbgUnpckByte0],EAX
        MovZX   EAX,byte [RSI+1]
        Mov     [dbgUnpckByte1],EAX
        MovZX   ECX,byte [RSI]                                                  ;ECX indexes delta value
%else
        Mov     CL,[ESI]                                                        ;CL indexes delta value
%endif
%ifdef HOST64
        And     ECX,0F0h                                                        ;ECX -> value
        ShR     ECX,2
        Mov     [dbgUnpckIdx0],ECX
%else
        And     CL,0F0h                                                         ;ECX -> value
        ShR     CL,2
%ifdef HOST64
%endif
%endif

%ifdef HOST64
        Mov     EAX,[R8+RCX]                                                    ;EAX = delta
%else
        Mov     EAX,[ECX]                                                       ;EAX = delta
%endif
        MovSX   EBX,AX                                                          ;EBX = Next to last sample
%ifdef HOST64
        Mov     [RDI],EBX
%else
        Mov     [EDI],EBX
%endif

%ifdef HOST64
        MovZX   ECX,byte [RSI]
%else
        Mov     CL,[ESI]
%endif
        Inc     SI
%ifdef HOST64
        And     ECX,0Fh
        ShL     ECX,2
%else
        And     CL,0Fh
        ShL     CL,2
%endif

%ifdef HOST64
        Mov     EAX,[R8+RCX]
%else
        Mov     EAX,[ECX]
%endif
        MovSX   EDX,AX                                                          ;EDX = Last sample
%ifdef HOST64
        Mov     [RDI+2],DX
        Add     RDI,4
%else
        Mov     [2+EDI],DX
        Add     EDI,4
%endif

    Dec     EBP
    JNZ     short .Filter0
%ifdef HOST64
    MovSX   EAX,word [RDI-32]
    Mov     [dbgUnpckOut0],EAX
    MovSX   EAX,word [RDI-30]
    Mov     [dbgUnpckOut1],EAX
    pop     r8
%endif
    Pop     EBP,ECX
    Ret

    ;[Delta]+[Smp-1](15/16) ------------------
    .Filter1:
%ifdef HOST64
        MovZX   EAX,byte [RSI]
        Mov     [dbgUnpckByte0],EAX
        MovZX   EAX,byte [RSI+1]
        Mov     [dbgUnpckByte1],EAX
        MovZX   ECX,byte [RSI]                                                  ;ECX indexes delta value
%else
        Mov     CL,[ESI]                                                        ;CL indexes delta value
%endif
%ifdef HOST64
        And     ECX,0F0h                                                        ;ECX -> value
        ShR     ECX,2
        Mov     [dbgUnpckIdx0],ECX
%else
        And     CL,0F0h                                                         ;ECX -> value
        ShR     CL,2
%ifdef HOST64
%endif
%endif

        UnpckFilter1
        UnpckClamp

%ifdef HOST64
        Mov     [RDI],EDX
%else
        Mov     [EDI],EDX
%endif

%ifdef HOST64
        MovZX   ECX,byte [RSI]
%else
        Mov     CL,[ESI]
%endif
        Inc     SI
%ifdef HOST64
        And     ECX,0Fh
        ShL     ECX,2
%else
        And     CL,0Fh
        ShL     CL,2
%endif

        UnpckFilter1
        UnpckClamp

%ifdef HOST64
        Mov     [RDI+2],DX
        Add     RDI,4
%else
        Mov     [2+EDI],DX
        Add     EDI,4
%endif

    Dec     EBP
    JNZ     .Filter1
%ifdef HOST64
    MovSX   EAX,word [RDI-32]
    Mov     [dbgUnpckOut0],EAX
    MovSX   EAX,word [RDI-30]
    Mov     [dbgUnpckOut1],EAX
    pop     r8
%endif
    Pop     EBP,ECX
    Ret

    ;[Delta]+[Smp-1](61/32)-[Smp-2](15/16) ---
    .Filter2:
%ifdef HOST64
        MovZX   EAX,byte [RSI]
        Mov     [dbgUnpckByte0],EAX
        MovZX   EAX,byte [RSI+1]
        Mov     [dbgUnpckByte1],EAX
        MovZX   ECX,byte [RSI]
%else
        Mov     CL,[ESI]
%endif
%ifdef HOST64
        And     ECX,0F0h
        ShR     ECX,2
        Mov     [dbgUnpckIdx0],ECX
%else
        And     CL,0F0h
        ShR     CL,2
%ifdef HOST64
%endif
%endif

        UnpckFilter2
        UnpckClamp

%ifdef HOST64
        Mov     [RDI],EDX
%else
        Mov     [EDI],EDX
%endif

%ifdef HOST64
        MovZX   ECX,byte [RSI]
%else
        Mov     CL,[ESI]
%endif
        Inc     SI
%ifdef HOST64
        And     ECX,0Fh
        ShL     ECX,2
%else
        And     CL,0Fh
        ShL     CL,2
%endif

        UnpckFilter2
        UnpckClamp

%ifdef HOST64
        Mov     [RDI+2],DX
        Add     RDI,4
%else
        Mov     [2+EDI],DX
        Add     EDI,4
%endif

    Dec     EBP
    JNZ     .Filter2
%ifdef HOST64
    MovSX   EAX,word [RDI-32]
    Mov     [dbgUnpckOut0],EAX
    MovSX   EAX,word [RDI-30]
    Mov     [dbgUnpckOut1],EAX
    pop     r8
%endif
    Pop     EBP,ECX
    Ret

    ;[Delta]+[Smp-1](115/64)-[Smp-2](13/16) --
    .Filter3:
%ifdef HOST64
        MovZX   EAX,byte [RSI]
        Mov     [dbgUnpckByte0],EAX
        MovZX   EAX,byte [RSI+1]
        Mov     [dbgUnpckByte1],EAX
        MovZX   ECX,byte [RSI]
%else
        Mov     CL,[ESI]
%endif
%ifdef HOST64
        And     ECX,0F0h
        ShR     ECX,2
        Mov     [dbgUnpckIdx0],ECX
%else
        And     CL,0F0h
        ShR     CL,2
%ifdef HOST64
%endif
%endif

        UnpckFilter3
        UnpckClamp

%ifdef HOST64
        Mov     [RDI],EDX
%else
        Mov     [EDI],EDX
%endif

%ifdef HOST64
        MovZX   ECX,byte [RSI]
%else
        Mov     CL,[ESI]
%endif
        Inc     SI
%ifdef HOST64
        And     ECX,0Fh
        ShL     ECX,2
%else
        And     CL,0Fh
        ShL     CL,2
%endif

        UnpckFilter3
        UnpckClamp

%ifdef HOST64
        Mov     [RDI+2],DX
        Add     RDI,4
%else
        Mov     [2+EDI],DX
        Add     EDI,4
%endif

    Dec     EBP
    JNZ     .Filter3
%ifdef HOST64
    MovSX   EAX,word [RDI-32]
    Mov     [dbgUnpckOut0],EAX
    MovSX   EAX,word [RDI-30]
    Mov     [dbgUnpckOut1],EAX
    pop     r8
%endif
    Pop     EBP,ECX
    Ret


;===================================================================================================
;Decompress Sound Source (Old school method)

UnpckSrcOld:

    Push    ECX

    ;Get range -------------------------------
    Mov     CL,0CFh
    Inc     SI
    Sub     CL,AL                                                               ;CL = 12 - Range (change range from << to >>)
    SetNC   AH                                                                  ;If result is negative (invalid range) add 3
    Dec     AH
    And     AH,30h
    Add     CL,AH
    ShR     CL,4

    Mov     CH,8
    Test    AL,0Ch
    JZ      short .Filter0

    Add     CL,10                                                               ;Values will be shifted right from 32-bit values
    Test    AL,08h
    JZ      short .Filter1

    Test    AL,04h
    JZ      .Filter2

    Jmp     .Filter3

    ;[Delta] ---------------------------------
    .Filter0:
        XOr     EAX,EAX
        XOr     EDX,EDX
        Mov     AH,[ESI]
        Mov     DH,AH
        And     AH,0F0h
        ShL     DH,4

        SAR     AX,CL
        SAR     DX,CL
        Mov     [EDI],AX
        Mov     [2+EDI],DX
        Add     EDI,4

        Inc     SI

    Dec     CH
    JNZ     short .Filter0
    MovSX   EDX,DX
    MovSX   EBX,AX
    Pop     ECX
    Ret

    ;[Delta]+[Smp-1](15/16) ------------------
    .Filter1:
        Mov     EBX,[ESI]
        And     BL,0F0h
        ShL     EBX,24
        SAR     EBX,CL

        Mov     EAX,EDX
        IMul    EAX,60
        Add     EBX,EAX
        SAR     EBX,6

        Mov     [EDI],EBX

        Mov     EDX,[ESI]
        ShL     EDX,28
        SAR     EDX,CL

        Mov     EAX,EBX
        IMul    EAX,60
        Add     EDX,EAX
        SAR     EDX,6

        Mov     [2+EDI],DX
        Add     EDI,4

        Inc     SI

    Dec     CH
    JNZ     short .Filter1
    Pop     ECX
    Ret

    ;[Delta]+[Smp-1](61/32)-[Smp-2](30/32) ---
    .Filter2:
        Mov     EAX,[ESI]
        And     AL,0F0h
        ShL     EAX,24
        SAR     EAX,CL

        ;Subtract 15/16 of second sample ------
        IMul    EBX,60
        Sub     EAX,EBX
        Mov     EBX,EDX

        ;Add 61/32 of last sample -------------
        IMul    EDX,122
        Add     EAX,EDX
        SAR     EAX,6

        Mov     [EDI],EAX

        Mov     EDX,[ESI]
        ShL     EDX,28
        SAR     EDX,CL

        IMul    EBX,60
        Sub     EDX,EBX
        Mov     EBX,EAX

        IMul    EAX,122
        Add     EDX,EAX
        SAR     EDX,6

        Mov     [2+EDI],DX
        Add     EDI,4

        Inc     SI

    Dec     CH
    JNZ     .Filter2
    Pop     ECX
    Ret

    ;[Delta]+[Smp-1](115/64)-[Smp-2](52/64) --
    .Filter3:
        Mov     EAX,[ESI]
        And     AL,0F0h
        ShL     EAX,24
        SAR     EAX,CL

        ;Subtract 13/16 of second sample ------
        IMul    EBX,52
        Sub     EAX,EBX
        Mov     EBX,EDX

        ;Add 115/64 of last sample ------------
        IMul    EDX,115
        Add     EAX,EDX
        SAR     EAX,6

        Mov     [EDI],EAX

        Mov     EDX,[ESI]
        ShL     EDX,28
        SAR     EDX,CL

        IMul    EBX,52
        Sub     EDX,EBX
        Mov     EBX,EAX

        IMul    EAX,115
        Add     EDX,EAX
        SAR     EDX,6

        Mov     [2+EDI],DX
        Add     EDI,4

        Inc     SI

    Dec     CH
    JNZ     .Filter3
    Pop     ECX
    Ret
