;===================================================================================================
;Program:    SNES Audio Processing Unit (APU) Emulator
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
;                                                   Copyright (C) 2003-2006 Alpha-II Productions
;                                                   Copyright (C) 2003-2025 degrade-factory
;
;List of users and dates who/when modified this file:
;   - degrade-factory in 2025-05-31
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
%include "DSP.inc"
%define INTERNAL
%include "APU.inc"

GLOBAL  cycLeft
GLOBAL  smpDec
GLOBAL  smpRate
GLOBAL  smpRAdj
GLOBAL  smpREmu
GLOBAL  rawChn
GLOBAL  rawBits
GLOBAL  rawByte
GLOBAL  rawRate
GLOBAL  outCur
GLOBAL  outLen
GLOBAL  apuOutBufGuard
GLOBAL  apuDbgStage
GLOBAL  apuDbgLastBuf
GLOBAL  apuDbgLastLen
GLOBAL  apuDbgLastType
GLOBAL  apuDbgSampleBuf
GLOBAL  apuDbgSampleLen


;===================================================================================================
;Data

%ifndef WIN32
SECTION .data ALIGN=256
%else
SECTION .data ALIGN=32
%endif

    apuOpt      DD  (CPU_CYC << 24) | (DEBUG << 16) | (DSPINTEG << 17) | (VMETERM << 8) | (VMETERV << 9) | (1 << 10) | (STEREO << 11) \
                    | (HALFC << 1) | (CNTBK << 2) | (SPEED << 3) | (IPLW << 4) | (DSPBK << 5) | (INTBK << 6)
    apuDllVer   DD  20000h                                                      ;SNESAPU.DLL Current Version
    apuCmpVer   DD  11000h                                                      ;SNESAPU.DLL Backwards Compatible Version
    apuVerStr   DD  "$CAP_FILE_VER"                                             ;SNESAPU.DLL Current Version (32byte String)
                DD  8


;===================================================================================================
;Variables

%ifndef WIN32
SECTION .bss ALIGN=256
%else
SECTION .bss ALIGN=64
%endif

    apuRAMBuf   resb    APURAMSIZE*2                                            ;SNESAPU 64KB APU RAM buffer
                resd    2                                                       ;   Overflow reference area
                resd    6                                                       ;Extend function pointer address
    scrRAMBuf   resb    SCR700SIZE                                              ;Script700 RAM buffer
                resd    4                                                       ;   Overflow reference area

    scr700lbl   resd    1024                                                    ;Script700 Label work area
    scr700dsp   resb    256                                                     ;Script700 DSP enable flags (Source)
    scr700mds   resb    32                                                      ;Script700 DSP enable flags (Master)
    scr700det   resd    256                                                     ;Script700 DSP rate detune
    scr700chg   resb    256                                                     ;Script700 DSP note change
    scr700vol   resd    256                                                     ;Script700 DSP volume change (Source)
    scr700mvl   resd    32                                                      ;Script700 DSP volume change (Master)

    scr700wrk   resd    8                                                       ;Script700 User work area
    scr700cmp   resd    2                                                       ;Script700 Compare parameters
    scr700cnt   resd    1                                                       ;Script700 Waiting count
    scr700ptr   resd    1                                                       ;Script700 Program pointer
    scr700stf   resb    1                                                       ;Script700 Status flags
                                                                                ;   [0] - Enable writing return address in stack
                                                                                ;   [1] - Enable always writing ports
                                                                                ;   [2] - Waiting output port 0 without SHVC-SOUND
                                                                                ;   [3] - Waiting output port 0 with SHVC-SOUND
                                                                                ;   [5] - Call RunScript700 before fetch
                                                                                ;   [6] - SHVC-SOUND transfer mode
                                                                                ;   [7] - Force abort Script700 (from frontend)
                resb    1
    scr700int   resb    2                                                       ;Script700 Interrupt ports
    scr700dat   resd    1                                                       ;Script700 Data area offset
%ifdef HOST64
    scr700stp   resq    1                                                       ;Script700 Stack pointer
%else
    scr700stp   resd    1                                                       ;Script700 Stack pointer
%endif

    scr700jmp   resq    1                                                       ;Script700 Jump address
    scr700inc   resd    3                                                       ;Script700 Include depth
    scr700tmp   resq    1                                                       ;Script700 Temporary
    scr700stk   resd    128                                                     ;Script700 Stack area
    scr700pth   resd    256                                                     ;Script700 Include path

    pAPURAM     resq    1                                                       ;Pointer to SNESAPU 64KB RAM
    pSCRRAM     resq    1                                                       ;Pointer to Script700 RAM
    cycLeft     resd    1                                                       ;Clock cycles left to emulate in EmuAPU loop
    smpDec      resd    1                                                       ;Unused clocks from cycle to sample conversion
    smpRate     resd    1                                                       ;Sample rate (max 32kHz in actual emulation mode)
    smpRAdj     resd    1                                                       ;Sample rate adjustment (16.16)
    smpREmu     resd    1                                                       ;Number of emulated samples per second

    rawChn      resb    1                                                       ;Number of channels being output
    rawBits     resb    1                                                       ;Size of samples in bits
    rawByte     resb    1                                                       ;Size of samples in bytes
                resb    1
    rawRate     resd    1                                                       ;Sample rate (max 192kHz)
    dspOpts     resd    1                                                       ;DSP option

    outCur      resd    1                                                       ;Temporary buffer cursor
    outLen      resd    1                                                       ;Temporary buffer used length
    outBuf      resd    1536                                                    ;Temporary buffer for 0x1000-cycle refill at 192kHz stereo 32-bit/float
    apuOutBufGuard resd 1                                                       ;Debug guard after temporary buffer

    apuCbMask   resd    1                                                       ;SNESAPU callback mask
    apuCbFunc   resq    1                                                       ;SNESAPU callback function
    apuDbgStage resd    1                                                       ;Temporary macOS port stage marker
    apuDbgLastBuf resq  1                                                       ;Last EmuAPU buffer argument
    apuDbgLastLen resd  1                                                       ;Last EmuAPU len argument
    apuDbgLastType resd 1                                                       ;Last EmuAPU type argument
    apuDbgSampleBuf resq 1                                                      ;Last sample-mode EmuAPU buffer argument
    apuDbgSampleLen resd 1                                                      ;Last sample-mode EmuAPU len argument

    apuVarEP    resd    1                                                       ;Endpoint of APU.asm variable


;===================================================================================================
;Code

%ifndef WIN32
SECTION .text ALIGN=256
%else
SECTION .text ALIGN=16
%endif


;===================================================================================================
;Initialize Audio Processing Unit

PROC InitAPU, reason

    Mov     dword [apuDbgStage],100h
    Mov     EAX,[reason]
    Dec     EAX                                                                 ;reason = DLL_PROCESS_ATTACH (1)?
    JNZ     .Quit                                                               ;   No

    Lea     RAX,[rel apuRAMBuf]
    Add     RAX,0FFFFh
    XOr     AX,AX
    Mov     [pAPURAM],RAX

    Add     RAX,10000h
    Mov     RDI,RAX
    XOr     EAX,EAX
    Mov     ECX,12
    Rep     StoSD

    Mov     [scr700inc],EAX
    Mov     dword [apuOutBufGuard],0C0DEFACEh
    Mov     [apuCbMask],EAX
    Mov     [apuDbgLastBuf],RAX
    Mov     [apuDbgLastLen],EAX
    Mov     [apuDbgLastType],EAX
    Mov     [apuDbgSampleBuf],RAX
    Mov     [apuDbgSampleLen],EAX
    Mov     [apuCbFunc],RAX
    Mov     [dspOpts],EAX

    Lea     RAX,[rel scrRAMBuf]
    Mov     [pSCRRAM],RAX

    Mov     dword [apuDbgStage],110h
    Call    InitSPC
    Mov     dword [apuDbgStage],120h
    Call    InitDSP
    Mov     dword [apuDbgStage],121h

    Mov     dword [smpRate],32000
    Mov     dword [smpRAdj],10000h
    Mov     byte [rawChn],2
    Mov     byte [rawBits],16
    Mov     byte [rawByte],4
    Mov     dword [rawRate],32000

    Mov     dword [apuDbgStage],122h
    Call    SetAPUSmpClk,[smpRAdj]
    Mov     dword [apuDbgStage],123h
    Call    ResetAPU,10000h                                                     ;Reset APU
    Mov     dword [apuDbgStage],124h
    Call    SetScript700,0                                                      ;Reset Script700

    .Quit:
    Mov     dword [apuDbgStage],12Fh
    Mov     EAX,1                                                               ;Return TRUE

ENDP


;===================================================================================================
;Get SNESAPU.DLL Version Information

PROC SNESAPUInfo, pVer, pMin, pOpt
USES EBX

    Mov     EBX,[pVer]
    Test    EBX,EBX
    JZ      short .pVerNext
        Mov     EAX,[apuDllVer]
        Mov     [EBX],EAX
    .pVerNext:

    Mov     EBX,[pMin]
    Test    EBX,EBX
    JZ      short .pMinNext
        Mov     EAX,[apuCmpVer]
        Mov     [EBX],EAX
    .pMinNext:

    Mov     EBX,[pOpt]
    Test    EBX,EBX
    JZ      short .pOptNext
        Mov     EAX,[apuOpt]
        Mov     [EBX],EAX
    .pOptNext:

ENDP


;===================================================================================================
;Set/Reset SNESAPU Callback Function

PROC SNESAPUCallback, pCbFunc, cbMask
USES EBX

    Mov     RAX,[apuCbFunc]

    Mov     RBX,[pCbFunc]
    Mov     [apuCbFunc],RBX

    Mov     EBX,[cbMask]
    Or      [apuCbMask],EBX                                                     ;OR method for chain call

ENDP


;===================================================================================================
;Get SNESAPU Data Pointers

PROC GetAPUData, ppRAM, ppXRAM, ppOutPort, ppT64Cnt, ppDSP, ppVoice, ppVMMaxL, ppVMMaxR
USES EBX

    Mov     RBX,[ppRAM]
    Test    RBX,RBX
    JZ      short .ppRAMNext
        Mov     RAX,[pAPURAM]
        Mov     [RBX],RAX
    .ppRAMNext:

%ifdef SPC700_INC
    Mov     RBX,[ppXRAM]
    Test    RBX,RBX
    JZ      short .ppXRAMNext
        Lea     RAX,[rel extraRAM]
        Mov     [RBX],RAX
    .ppXRAMNext:

    Mov     RBX,[ppOutPort]
    Test    RBX,RBX
    JZ      short .ppOutPortNext
        Lea     RAX,[rel outPort]
        Mov     [RBX],RAX
    .ppOutPortNext:

    Mov     RBX,[ppT64Cnt]
    Test    RBX,RBX
    JZ      short .ppT64CntNext
        Lea     RAX,[rel t64Cnt]
        Mov     [RBX],RAX
    .ppT64CntNext:
%endif

    Mov     RBX,[ppDSP]
    Test    RBX,RBX
    JZ      short .ppDSPNext
        Lea     RAX,[rel dsp]
        Mov     [RBX],RAX
    .ppDSPNext:

    Mov     RBX,[ppVoice]
    Test    RBX,RBX
    JZ      short .ppVoiceNext
        Lea     RAX,[rel mix]
        Mov     [RBX],RAX
    .ppVoiceNext:

%ifdef DSP_INC
    Mov     RBX,[ppVMMaxL]
    Test    RBX,RBX
    JZ      short .ppVMMaxLNext
        Lea     RAX,[rel vMMaxL]
        Mov     [RBX],RAX
    .ppVMMaxLNext:

    Mov     RBX,[ppVMMaxR]
    Test    RBX,RBX
    JZ      short .ppVMMaxRNext
        Lea     RAX,[rel vMMaxR]
        Mov     [RBX],RAX
    .ppVMMaxRNext:
%endif

ENDP


;===================================================================================================
;Get Script700 Data Pointers

PROC GetScript700Data, pDLLVer, ppSPCReg, ppScript700
USES EBX

    Mov     RBX,[pDLLVer]
    Test    RBX,RBX
    JZ      short .pDLLVerNext
        Mov     EAX,[apuVerStr+00h]
        Mov     [RBX+00h],EAX
        Mov     EAX,[apuVerStr+04h]
        Mov     [RBX+04h],EAX
        Mov     EAX,[apuVerStr+08h]
        Mov     [RBX+08h],EAX
        Mov     EAX,[apuVerStr+0Ch]
        Mov     [RBX+0Ch],EAX
        Mov     EAX,[apuVerStr+10h]
        Mov     [RBX+10h],EAX
        Mov     EAX,[apuVerStr+14h]
        Mov     [RBX+14h],EAX
        Mov     EAX,[apuVerStr+18h]
        Mov     [RBX+18h],EAX
        Mov     EAX,[apuVerStr+1Ch]
        Mov     [RBX+1Ch],EAX
    .pDLLVerNext:

%ifdef SPC700_INC
    Mov     RBX,[ppSPCReg]
    Test    RBX,RBX
    JZ      short .ppSPCRegNext
        Mov     RAX,[pSPCReg]
        Mov     [RBX],RAX
    .ppSPCRegNext:
%endif

    Mov     RBX,[ppScript700]
    Test    RBX,RBX
    JZ      short .ppScript700Next
        Lea     RAX,[rel scr700wrk]
        Mov     [RBX],RAX
    .ppScript700Next:

ENDP


;===================================================================================================
;Reset Audio Processor

PROC ResetAPU, amp

    Call    ResetSPC
    Call    ResetDSP

    Cmp     dword [amp],-1
    JE      short .NoAmp
        Call    SetDSPAmp,[amp]
    .NoAmp:

    XOr     EAX,EAX
    Mov     [cycLeft],EAX
    Mov     [smpDec],EAX
    Mov     [outCur],EAX
    Mov     [outLen],EAX

ENDP


;===================================================================================================
;Fix Audio Processor After Load

PROC FixAPU, pc, a, y, x, psw, s

    Call    FixSPC,[pc],[a],[y],[x],[psw],[s]
    Call    FixDSP

ENDP


;===================================================================================================
;Load SPC File

PROC LoadSPCFile, pFile
USES ECX,ESI,EDI

    Call    ResetAPU,-1

    Mov     RSI,[pFile]

    Add     RSI,100h                                                            ;memcpy(&apuRAM, &spc[0x100], 0x10000)
    Mov     RDI,[pAPURAM]
    Mov     ECX,4000h
    Rep     MovSD

    Lea     RDI,[rel dsp]                                                      ;memcpy(&dsp, &spc[0x10100], 128)
    Mov     ECX,32
    Rep     MovSD

    Add     RSI,40h                                                             ;memcpy(&xram, &spc[0x101C0], 64)
    Lea     RDI,[rel extraRAM]
    Mov     ECX,16
    Rep     MovSD

    Mov     RSI,[pFile]
    XOr     EAX,EAX
    Mov     AL,[RSI+2Bh]                                                        ;SP
    Push    EAX
    Mov     AL,[RSI+2Ah]                                                        ;PSW
    Push    EAX
    Mov     AL,[RSI+28h]                                                        ;X
    Push    EAX
    Mov     AL,[RSI+29h]                                                        ;Y
    Push    EAX
    Mov     AL,[RSI+27h]                                                        ;A
    Push    EAX
    Mov     AX,[RSI+25h]                                                        ;PC
    Push    EAX
    Call    FixAPU

ENDP


;===================================================================================================
;Set Audio Processor Options

PROC SetAPUOpt, mixType, numChn, bits, rate, inter, opts
USES ECX,EDX

    XOr     EDX,EDX

    ;numChn ----------------------------------
    Mov     AL,[rawChn]
    Mov     AH,[numChn]
    Cmp     AH,-1
    JE      short .DefChn
        Mov     AL,AH
        Mov     [outCur],EDX
        Mov     [outLen],EDX

    .DefChn:
    Mov     [rawChn],AL

    ;bits ------------------------------------
    Mov     CL,[rawBits]
    Mov     CH,[bits]
    Cmp     CH,-1
    JE      short .DefBits
        Mov     CL,CH
        Mov     [outCur],EDX
        Mov     [outLen],EDX

    .DefBits:
    Mov     [rawBits],CL

    ;bytes -----------------------------------
    Test    CL,CL                                                               ;rawByte = numChn * abs(bits) / 8
    SetNS   CH
    Dec     CH
    XOr     CL,CH
    Sub     CL,CH

    MovZX   EAX,AL
    MovZX   ECX,CL
    Mul     ECX
    ShR     AL,3
    Mov     [rawByte],AL

    ;rate ------------------------------------
    Mov     EAX,[rawRate]
    Mov     EDX,[rate]
    Cmp     EDX,-1
    JE      short .DefRate
        Mov     EAX,EDX

    .DefRate:
    Mov     [rate],EAX

    ;opts ------------------------------------
    Mov     EAX,[dspOpts]
    Mov     EDX,[opts]
    Cmp     EDX,-1
    JE      short .DefOpts
        Mov     EAX,EDX

    .DefOpts:
    Mov     [opts],EAX

    ;DSP option adjustment -------------------
    Mov     EDX,[dspOpts]
    XOr     EDX,EAX
    Mov     [dspOpts],EAX

    Test    EDX,DSP_ECHOFIR                                                     ;If the DSP_ECHOFIR flag changes,
    SetZ    AL                                                                  ; force sampling rate processing (rawRate = -1)
    MovZX   EAX,AL
    Dec     EAX
    Or      [rawRate],EAX

    Mov     EAX,[rate]
    Cmp     EAX,[rawRate]                                                       ;Has sample rate changed?
    JE      short .KeepRate                                                     ;   No
        Cmp     EAX,8000                                                        ;If rate < 8000, rate = 8000
        JAE     short .OKL
            Mov     EAX,8000

        .OKL:
        Cmp     EAX,192000                                                      ;If rate > 192000, rate = 192000
        JBE     short .OKH
            Mov     EAX,192000

        .OKH:
        Mov     [rawRate],EAX

%if INTBK
        Test    dword [dspOpts],DSP_ECHOFIR                                     ;Is actual emulation mode?
        JZ      short .OKA                                                      ;   No, smpRate = rawRate

        Cmp     EAX,32000                                                       ;If rate > 32000, rate = 32000
        JBE     short .OKA
            Mov     EAX,32000

        .OKA:
%endif

        Mov     [smpRate],EAX
        XOr     EAX,EAX
        Call    SetAPUSmpClk,[smpRAdj]                                          ;Calculate the number of clock cycles per sample

    .KeepRate:
    Call    SetDSPOpt,[mixType],[numChn],[bits],[rate],[inter],[opts]           ;Set options in DSP emulator

ENDP


;===================================================================================================
;Set Audio Processor Sample Clock

PROC SetAPUSmpClk, speed
USES EDX

    Mov     EAX,[speed]
    Cmp     EAX,1024                                                            ;If speed < 1024, speed = 1024 (~1.5%)
    JAE     short .OKL                                                          ;Note: If lower any more, will crash or noisy.
        Mov     EAX,1024

    .OKL:
    Cmp     EAX,1048576                                                         ;If speed > 1048576, speed = 1048576 (x16)
    JBE     short .OKH
        Mov     EAX,1048576

    .OKH:
    Mov     [smpRAdj],EAX
%ifdef DSP_INC
    Mov     [adsrAdj],EAX
%endif

    Mov     EAX,[smpRate]                                                       ;smpREmu = (smpRate << 16) / smpRAdj;
    MovZX   EDX,word [2+smpRate]
    ShL     EAX,16
    Div     dword [smpRAdj]
    Mov     [smpREmu],EAX

ENDP


;===================================================================================================
;Set Audio Processor Song Length

PROC SetAPULength

    Jmp     SetDSPLength

ENDP


;===================================================================================================
;Emulate Audio Processing Unit

PROC EmuAPU, pBuf, len, type
USES ECX,EDX,EBX,EDI

    Mov     RDI,[pBuf]
    Mov     [apuDbgLastBuf],RDI
    Mov     EAX,[len]
    Mov     [apuDbgLastLen],EAX
    MovZX   ECX,byte [type]
    Mov     [apuDbgLastType],ECX
    Test    ECX,ECX
    JZ      short .DbgTypeDone
        Mov     [apuDbgSampleBuf],RDI
        Mov     [apuDbgSampleLen],EAX

    .DbgTypeDone:
    Test    EAX,EAX
    JZ      .Done

    Test    byte [type],-1                                                      ;Is the unit of len samples?
    JS      short .NextSec                                                      ;   No, not adjust clock cycles (for seek)
    JZ      short .AdjCycles                                                    ;   No, adjust clock cycles to APU speed
        Call    EmuAPUBySmp                                                     ;   Yes
        Jmp     .Done

    .AdjCycles:
    XOr     EDX,EDX                                                             ;EAX = EAX * smpRAdj / 65536
    Mov     ECX,[smpRAdj]
    Mul     ECX
    ShRD    EAX,EDX,16

    .NextSec:
    Mov     ECX,APU_CLK
    XOr     EDX,EDX
    Mov     EBX,EAX

    ;Fixup cycles ----------------------------
    Sub     EAX,ECX                                                             ;If EAX > APU_CLK, EAX = APU_CLK
    CDQ
    And     EAX,EDX
    Add     EAX,ECX

    Sub     EBX,EAX                                                             ;len -= clock cycles
    Mov     EDX,EAX
    Add     EAX,[cycLeft]                                                       ;Is emulation completed?
    JLE     short .NoCycles                                                     ;   Yes

    ;Initialize DSP --------------------------
    Push    EAX

    Mov     EAX,EDX                                                             ;samples = ((smpREmu * cycles) + smpDec) / APU_CLK
    Mul     dword [smpREmu]
    Add     EAX,[smpDec]
    AdC     EDX,0
    Div     ECX
    Mov     [smpDec],EDX
    Inc     EAX                                                                 ;Adjusting for sample size error
    And     EAX,~1

%ifdef HOST64
    Call    SetEmuDSP,RDI,EAX,[smpREmu]
%else
    Call    SetEmuDSP,EDI,EAX,[smpREmu]
%endif
    Pop     EAX

    ;Emulate APU -----------------------------
    ;Note: For more accurate emulation, instead of waiting for cycles after doing 1 opcode processing,
    ; running opcode should be processed internally every cycle.
    ; However, this requires complex logic and sophisticated analysis.
    Call    EmuSPC,EAX
    Mov     ECX,EAX                                                             ;ECX = len - emulated clock cycles

    Call    SetEmuDSP,0,0,0                                                     ;Create any remaining samples
%ifdef HOST64
    Mov     RDI,RAX                                                             ;RDI = End of buffer
%else
    Mov     EDI,EAX                                                             ;EDI = End of buffer
%endif
    Mov     EAX,ECX

    .NoCycles:
    Mov     [cycLeft],EAX
    Mov     EAX,EBX
    Test    EBX,EBX                                                             ;Is emulation completed?
    JNZ     .NextSec                                                            ;   No, continue

    .Done:
%ifdef HOST64
    Mov     RAX,RDI                                                             ;RAX = End of buffer
%else
    Mov     EAX,EDI                                                             ;EAX = End of buffer
%endif

ENDP


;===================================================================================================
;Emulate Audio Processing Unit (by sample units)
;
;If the sampling rate is not divisible by 1000 (ex. 44100, 88200Hz), the length of the generated
;waveform data will not be constant, and forcibly interpolating waveform will cause noise.
;
;This procedure returns only the specified size, with adjusting the beginning and end of the
;generated waveform data.
;
;In:
;   EAX = len (sample units)
;   EDI-> Buffer to store output
;
;Out:
;   EAX-> End of buffer
;   EBX = Number of samples not output
;
;Destroys:
;   ECX,EDX

PROC EmuAPUBySmp
USES ESI

    Mov     EBX,EAX                                                             ;EBX = len (samples)
    Mov     EAX,[outLen]
    Test    EAX,EAX                                                             ;Has already been emulated?
    JZ      short .BefEnd                                                       ;   No, skip

    ;Copy before buffer ----------------------
    Lea     RSI,[rel outBuf]
%ifdef HOST64
    Mov     EDX,[outCur]
    Add     RSI,RDX
%else
    Add     ESI,[outCur]
%endif
    MovZX   EDX,byte [rawByte]

    .BefLoop:
        Mov     ECX,EDX                                                         ;Copy from outBuf to pBuf
        Rep     MovSB
        Add     [outCur],EDX
        Sub     [outLen],EDX

        Dec     EBX                                                             ;Is emulation completed?
        JZ      .Done                                                           ;   Yes, done

        Sub     EAX,EDX                                                         ;Is outBuf empty?
        JNZ     short .BefLoop                                                  ;   No, continue

    .BefEnd:
    Mov     [outCur],EAX                                                        ;EAX = 0

    ;Fixup samples ---------------------------
    XOr     EDX,EDX                                                             ;EAX = samples * APU_CLK / rawRate
    Mov     EAX,EBX                                                             ;EDX = samples * APU_CLK % rawRate .. (1)
    Mov     ECX,APU_CLK
    Mul     ECX
    Mov     ECX,[rawRate]
    Div     ECX
    Push    EDX

    XOr     EDX,EDX                                                             ;EAX = samples * smpRate / rawRate
    Mov     EAX,EBX                                                             ;EDX = samples * smpRate % rawRate .. (2)
    Mov     ECX,[smpRate]
    Mul     ECX
    Mov     ECX,[rawRate]
    Div     ECX

    Mov     EAX,EBX                                                             ;EAX = samples
    Pop     ECX
    Or      EDX,ECX                                                             ;Is (1) and (2) equal 0?
    JZ      short .MainEmu                                                      ;   Yes, not need fixup
        Sub     EAX,8                                                           ;Need more than 8 samples?
        JLE     short .AftEmu                                                   ;   No, skip

    ;Emulate to pBuf -------------------------
    .MainEmu:
    XOr     EDX,EDX                                                             ;EAX = samples to clock cycles
    Mov     ECX,APU_CLK
    Mul     ECX
    Mov     ECX,[rawRate]
    Div     ECX
%ifdef HOST64
    Push    EDI
    Call    EmuAPU,RDI,EAX,0
    Pop     RCX

    Mov     RDX,RAX
    Sub     RAX,RCX                                                             ;RAX = Emulated buffer size (bytes)
    Mov     RDI,RDX                                                             ;RDI = End of buffer
%else
    Call    EmuAPU,EDI,EAX,0

    Mov     EDX,EAX
    Sub     EAX,EDI                                                             ;EAX = Emulated buffer size (bytes)
    Mov     EDI,EDX                                                             ;EDI = End of buffer
%endif

    XOr     EDX,EDX                                                             ;EAX = Bytes to samples
    MovZX   ECX,byte [rawByte]
    Div     ECX
    Sub     EBX,EAX                                                             ;Is emulation completed?
    JZ      .Done                                                               ;   Yes, done

    ;Emulate to outBuf -----------------------
    .AftEmu:
    Mov     EAX,EBX                                                             ;EAX = samples
    Mov     dword [outCur],0                                                    ;Refills restart at the beginning of outBuf

    XOr     EDX,EDX                                                             ;EAX = samples to clock cycles
    Mov     ECX,APU_CLK
    Mul     ECX
    Mov     ECX,[rawRate]
    Div     ECX

    Lea     RSI,[rel outBuf]
    Mov     ECX,EAX                                                             ;ECX = clock cycles (min. 0x1000 = 16 samples at 96000Hz)
    Cmp     ECX,1000h                                                           ;Note: If clock cycles is less than 0x1000 and playback
    JAE     short .EmuLoop                                                      ; speed is below 25%, will crash or noisy.
        Mov     ECX,1000h

    .EmuLoop:
%ifdef HOST64
    Push    EDI
    Push    ESI
    Call    EmuAPU,RSI,ECX,0
    Pop     RCX
    Pop     RDX
    Sub     RAX,RCX                                                             ;RAX = Emulated buffer size (bytes)
    Mov     RSI,RCX                                                             ;Restore outBuf base for copy-out
    Mov     RDI,RDX                                                             ;Restore destination buffer pointer
%else
    Call    EmuAPU,ESI,ECX,0
    Sub     EAX,ESI                                                             ;EAX = Emulated buffer size (bytes)
%endif
    JZ      short .EmuLoop                                                      ;Continue until the waveform is output

    ;Copy after buffer -----------------------
    Mov     [outLen],EAX
    MovZX   EDX,byte [rawByte]

    .AftLoop:
        Mov     ECX,EDX                                                         ;Copy from outBuf to pBuf
        Rep     MovSB
        Add     [outCur],EDX
        Sub     [outLen],EDX

        Dec     EBX                                                             ;Is emulation completed?
        JZ      short .Done                                                     ;   Yes, done

        Sub     EAX,EDX                                                         ;Is outBuf empty?
        JNZ     short .AftLoop                                                  ;   No, continue
        Jmp     short .AftEmu                                                   ;   Yes, re-run emulation

    .Done:

ENDP


;===================================================================================================
;Seek to Position

PROC SeekAPU, time, fast
USES ECX,EDX

    XOr     EDX,EDX
    Mov     EAX,[time]                                                          ;numSeconds = time / 64000
    Test    EAX,EAX
    RetZF

    Mov     ECX,64000
    Div     ECX
    Mov     ECX,EAX                                                             ;ECX = time / 64000
    IMul    EDX,APU_CLK/64000                                                   ;EDX = (time % 64000) * (APU_CLK / 64000)

    Test    byte [fast],-1                                                      ;Fast mode completely bypasses the DSP emulation
    JZ      short .Slow
        Call    SetSPCDbg,-1,SPC_NODSP                                          ;Disable writes to the DSP registers

        Test    EDX,EDX
        JZ      short .EmuSPC

        Call    EmuSPC,EDX
        Test    ECX,ECX
        JZ      short .DoneSeek

        .EmuSPC:
        Call    EmuSPC,APU_CLK
        Dec     ECX
        JNZ     short .EmuSPC

        .DoneSeek:
        Call    SetSPCDbg,-1,0                                                  ;Re-enable writes to the DSP registers
        Jmp     .Done

    .Slow:
        Mov     EAX,[dspOpts]
        Push    EAX                                                             ;Save APU options
        Or      EAX,DSP_ENVSPD+DSP_NOSAFE
        Call    SetAPUOpt,-1,-1,-1,-1,-1,EAX
        Mov     EAX,[smpRAdj]
        Push    EAX                                                             ;Save APU speed

        Push    EDI
        Mov     EAX,EDI
        ShR     EAX,16
        JNZ     short .MinSpeed                                                 ;When APU speed is less than 100%, temporarily increase
            Mov     EDI,10000h                                                  ; it to 100% to speed up processing

        .MinSpeed:
        Test    EDX,EDX
        JZ      short .EmuAPU

        Call    SetAPUSmpClk,EDI
        Call    EmuAPU,0,EDX,-1                                                 ;Do not adjust clock cycles to APU speed
        Test    ECX,ECX
        JZ      short .DoneSlow

        .EmuAPU:
        XOr     EAX,EAX                                                         ;If last second then emulate at current speed
        Dec     ECX                                                             ; else at maximum speed for faster
        SetZ    AL
        Inc     ECX
        Dec     EAX
        Or      EAX,EDI
        Call    SetAPUSmpClk,EAX
        Call    EmuAPU,0,APU_CLK,-1                                             ;Do not adjust clock cycles to APU speed
        Dec     ECX
        JNZ     short .EmuAPU

        .DoneSlow:
        Pop     EDI,EAX
        Call    SetAPUSmpClk,EAX                                                ;Restore APU speed
        Pop     EAX
        Call    SetAPUOpt,-1,-1,-1,-1,-1,EAX                                    ;Restore APU options

    .Done:
    Call    FixSeek,[fast]                                                      ;Fixup DSP after seeking

ENDP


;===================================================================================================
;Set/Reset TimerTrick Compatible Function

PROC SetTimerTrick, port, wait
USES ECX,ESI

    Mov     CL,[scr700inc+02h]
    Test    CL,CL                                                               ;Include mode?
    JNZ     short .EXIT                                                         ;   Yes

    Call    SetScript700,0                                                      ;Reset Script700
    Mov     ECX,[wait]                                                          ;ECX = wait
    Test    ECX,ECX                                                             ;ECX = 0x00?
    JZ      short .EXIT                                                         ;   Yes
        ;---------- TimerTrick -> Script700 binary converter ----------

    Mov     RSI,[pSCRRAM]                                                       ;ESI = Script RAM Pointer
        Mov     [RSI+02h],ECX                                                   ;Program[0x02] = ECX
        Mov     CL,[port]                                                       ;CL = port
        Mov     [RSI+0Eh],CL                                                    ;Program[0x0E] = CL

        ;-------------------------------------------------------------------------------
        ; [Script700 Command]       [Binary]
        ; :0    w   (WAIT)      ->  0x00 : 0x01 0x00 ???? ???? ???? ????
        ;       a   #1  i(PORT) ->  0x06 : 0x04 0x00 0x00 0x01 0x00 0x00 0x00 0x02 ????
        ;       bra 0           ->  0x0F : 0x05 0x00 0x00
        ;       (EXIT)          ->  0x14 : 0x00
        ;-------------------------------------------------------------------------------

        Mov     word  [RSI+00h],0001h
        Mov     dword [RSI+06h],01000004h
        Mov     dword [RSI+0Ah],02000000h
        Mov     dword [RSI+0Fh],00000005h
        Mov     dword [scr700lbl],0

    .EXIT:

ENDP


;===================================================================================================
;Seek First Command
;   Uses: DH, AL
;   Z flag: OFF=Success, ON=Failure

PROC GetScript700First

    XOr     DH,DH                                                               ;DH = 0x00

    .RETURN:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      short .ERROR                                                        ;   Yes
    Cmp     AL,09h                                                              ;Is char TAB?
    JE      short .NEXT                                                         ;   Yes
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      short .ERROR                                                        ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      short .ERROR                                                        ;   Yes
    Cmp     AL,20h                                                              ;Is char SPACE?
    JE      short .NEXT                                                         ;   Yes
    Or      DH,01h                                                              ;DH = 0x01 (Success)
    Jmp     short .EXIT

    .NEXT:
    Inc     RCX                                                                 ;RCX++
    Jmp     short .RETURN

    .ERROR:
    XOr     DH,DH                                                               ;DH = 0x00 (Failure)

    .EXIT:
    Test    DH,DH                                                               ;DH = 0x00 (Failure)?

ENDP


;===================================================================================================
;Seek Next Command/Parameter
;   Uses: DH, AL
;   Z flag: OFF=Success, ON=Failure

PROC GetScript700Next

    XOr     DH,DH                                                               ;DH = 0x00

    .RETURN:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      short .ERROR                                                        ;   Yes
    Cmp     AL,09h                                                              ;Is char TAB?
    JE      short .NEXT                                                         ;   Yes
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      short .ERROR                                                        ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      short .ERROR                                                        ;   Yes
    Cmp     AL,20h                                                              ;Is char SPACE?
    JE      short .NEXT                                                         ;   Yes
    Jmp     short .EXIT

    .NEXT:
    Inc     RCX                                                                 ;RCX++
    Or      DH,01h                                                              ;DH = 0x01 (Success)
    Jmp     short .RETURN

    .ERROR:
    XOr     DH,DH                                                               ;DH = 0x00 (Failure)

    .EXIT:
    Test    DH,DH                                                               ;DH = 0x00 (Failure)?

ENDP


;===================================================================================================
;Skip Next Command/Parameter
;   Uses: AL

PROC GetScript700Skip

    .RETURN:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      short .EXIT                                                         ;   Yes
    Cmp     AL,09h                                                              ;Is char TAB?
    JE      short .EXIT                                                         ;   Yes
    Cmp     AL,20h                                                              ;Is char SPACE?
    JE      short .EXIT                                                         ;   Yes
    Inc     RCX                                                                 ;RCX++
    Jmp     short .RETURN

    .EXIT:

ENDP


;===================================================================================================
;Seek Next Line
;   Uses: DH, AL

PROC GetScript700NextLine

    .RETURN:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      short .EXIT                                                         ;   Yes
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      short .NEXT2                                                        ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      short .NEXT2                                                        ;   Yes
    Inc     RCX                                                                 ;RCX++
    Jmp     short .RETURN

    .NEXT:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      short .EXIT                                                         ;   Yes
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      short .NEXT2                                                        ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      short .NEXT2                                                        ;   Yes
    Jmp     short .EXIT

    .NEXT2:
    Inc     RCX                                                                 ;RCX++
    Jmp     short .NEXT

    .EXIT:

ENDP


;===================================================================================================
;Parse Number (Supported DEC or HEX, and Minus)
;   EAX = Number of Result
;   Uses: DH
;   Z flag: OFF=Success, ON=Failure

PROC GetScript700Number

    Push    EBX
    XOr     EAX,EAX                                                             ;EAX = 0x00
    XOr     EBX,EBX                                                             ;EBX = 0x00
    XOr     DH,DH                                                               ;DH = 0x00

    Mov     BL,[RCX]                                                            ;BL = [RCX]
    Cmp     BL,2Bh                                                              ;Is char "+"?
    JE      short .NOP                                                          ;   Yes
    Cmp     BL,2Dh                                                              ;Is char "-"?
    JE      short .MINUS                                                        ;   Yes

    .RETURNFIRST:
    Cmp     BL,30h                                                              ;Is char "0"?
    JE      short .HEXZ                                                         ;   Yes
    Cmp     BL,24h                                                              ;Is char "$"?
    JE      short .HEXOK                                                        ;   Yes

    .RETURN:
    Mov     BL,[RCX]                                                            ;BL = Char
    Sub     BL,30h                                                              ;BL -= 0x30
    Cmp     BL,10                                                               ;BL >= 10? (Is not char "0" to "9"?)
    JAE     short .HEXCHECK                                                     ;   Yes
    Jmp     short .RETURNNEXT

    .HEXCHECKNEXT:
    Add     BL,10                                                               ;BL += 10

    .RETURNNEXT:
    Test    DH,04h                                                              ;DH &= 0x04? (HEX mode?)
    JNZ     short .SETHEX                                                       ;   Yes
        LEA     EAX,[EAX+EAX*4]                                                 ;EAX *= 5
        Add     EAX,EAX                                                         ;EAX += EAX                         ;(EAX *= 10)
        Jmp     short .SETOK

    .SETHEX:
        ShL     EAX,4                                                           ;EAX << 4

    .SETOK:
    Add     EAX,EBX                                                             ;EAX += EBX
    Inc     RCX                                                                 ;RCX++
    Or      DH,01h                                                              ;DH |= 0x01 (Success)
    Jmp     short .RETURN

    .MINUS:
    Or      DH,02h                                                              ;DH |= 0x02 (MINUS mode)

    .NOP:
    Inc     RCX                                                                 ;RCX++
    Mov     BL,[RCX]                                                            ;BL = Char
    Jmp     short .RETURNFIRST

    .HEXZ:
    Inc     RCX                                                                 ;RCX++
    Mov     BL,[RCX]                                                            ;BL = Char
    And     BL,0DFh                                                             ;BL &= 0xDF
    Cmp     BL,58h                                                              ;Is char "X"?
    JE      short .HEXOK                                                        ;   Yes
    Dec     RCX                                                                 ;RCX--
    Jmp     short .RETURN

    .HEXOK:
    Or      DH,04h                                                              ;DH |= 0x04 (HEX mode)
    Inc     RCX                                                                 ;RCX++
    Jmp     short .RETURN

    .HEXCHECK:
    Test    DH,04h                                                              ;DH &= 0x04? (HEX mode?)
    JZ      short .NEXT                                                         ;   No
    Sub     BL,11h                                                              ;BL -= 0x11 (0x41)
    Cmp     BL,6                                                                ;BL < 6? (Is char "A" to "F"?)
    JB      short .HEXCHECKNEXT                                                 ;   Yes
    Sub     BL,20h                                                              ;BL -= 0x20 (0x61)
    Cmp     BL,6                                                                ;BL < 6? (Is char "a" to "f"?)
    JB      short .HEXCHECKNEXT                                                 ;   Yes

    .NEXT:
    Mov     BL,[RCX]                                                            ;BL = Char
    Cmp     BL,00h                                                              ;Is char NULL?
    JE      short .EXIT                                                         ;   Yes
    Cmp     BL,09h                                                              ;Is char TAB?
    JE      short .EXIT                                                         ;   Yes
    Cmp     BL,0Ah                                                              ;Is char RETURN?
    JE      short .EXIT                                                         ;   Yes
    Cmp     BL,0Dh                                                              ;Is char RETURN?
    JE      short .EXIT                                                         ;   Yes
    Cmp     BL,20h                                                              ;Is char SPACE?
    JE      short .EXIT                                                         ;   Yes
    XOr     DH,DH                                                               ;DH = 0x00 (Failure)

    .EXIT:
    Test    DH,02h                                                              ;DH &= 0x02? (MINUS mode?)
    JZ      short .PLUS                                                         ;   No
        Neg     EAX                                                             ;EAX = -EAX
    .PLUS:
    Pop     EBX
    And     DH,01h                                                              ;DH &= 0x01

ENDP


;===================================================================================================
;Check Last of Command/Parameter
;   Uses: DH, AL
;   Z flag: OFF=Success, ON=Failure

PROC GetScript700Last

    XOr     DH,DH                                                               ;DH = 0x00
    Or      DH,01h                                                              ;DH = 0x01 (Success)
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = Char
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      short .OK                                                           ;   Yes
    Cmp     AL,09h                                                              ;Is char TAB?
    JE      short .OK                                                           ;   Yes
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      short .OK                                                           ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      short .OK                                                           ;   Yes
    Cmp     AL,20h                                                              ;Is char SPACE?
    JE      short .OK                                                           ;   Yes
    XOr     DH,DH                                                               ;DH = 0x00 (Failure)

    .OK:
    Test    DH,DH                                                               ;DH = 0x00 (Failure)?

ENDP


;===================================================================================================
;Set/Reset Script700 Compatible Function
;   EAX = Free / Result of GetScript700Number / (AL) Use GetScript700xxx function
;   EBX = Index of Script700 binary area
;   ECX = Pointer of Script700 buffer
;   EDX = Free / (DH) Use GetScript700xxx function
;   ESI = Pointer base of Script700 binary area
;   EDI = Index of Script700 program area for rollback

PROC SetScript700, pSource
USES ECX,EDX,EBX,ESI,EDI

    ;---------- Initialize ----------

    Mov     RSI,[pSCRRAM]                                                       ;ESI = Script RAM Pointer

    Mov     AX,[scr700inc+02h]
    Test    AL,AL                                                               ;Include mode?
    JZ      short .INIT                                                         ;   No
        Mov     RCX,[pSource]                                                   ;RCX = Source Pointer
        Test    RCX,RCX                                                         ;RCX = NULL?
        JZ      .CRITICALERROR                                                  ;   Yes

        Mov     EBX,[scr700inc+04h]
        Mov     EDI,EBX
        Dec     AH
        JZ      .EXTRETURN
        Dec     AH
        JZ      .DATARETURN2
        Jmp     short .NORMALRETURN

    .INIT:
    XOr     EAX,EAX                                                             ;EAX = 0x00
    Mov     [RSI],AL                                                            ;Program[0] = AL
    Mov     [scr700ptr],EAX                                                     ;Reset Pointer
    Mov     [scr700dat],EAX
    Mov     [scr700inc],EAX

    XOr     EBX,EBX                                                             ;EBX = 0x00
    Inc     EBX                                                                 ;EBX++ (0x01)
    Mov     [scr700cnt],EBX

    Lea     RDI,[rel scr700dsp]
    Mov     ECX,328                                                             ;Channel(256/4) + Master(32/4) + Detune(256)
    Rep     StoSD

    Lea     RDI,[rel scr700chg]
    Mov     ECX,EAX                                                             ;ECX = EAX (0x00)

    .CLEARCHG:
        Dec     CL                                                              ;CL--
        Mov     [RDI+RCX],CL
    Dec     AL                                                                  ;AL--
    JNZ     short .CLEARCHG

    Lea     RDI,[rel scr700lbl]
    Dec     EAX                                                                 ;EAX-- (0xFFFFFFFF)
    Mov     ECX,1024                                                            ;4096byte
    Rep     StoSD

    Mov     RCX,[pSource]                                                       ;RCX = Source Pointer
    Test    RCX,RCX                                                             ;RCX = NULL?
    JZ      .CRITICALERROR                                                      ;   Yes
    XOr     EBX,EBX                                                             ;EBX = 0x00
    XOr     EDI,EDI                                                             ;EDI = 0x00

    ;---------- Script Command Zone ----------

    .NORMALRETURN:
    And     EBX,SCR700MASK                                                      ;EBX &= Program Mask
    Cmp     EBX,EDI                                                             ;EBX < EDI?
    JB      .CRITICALERROR                                                      ;   Yes

    Mov     EDI,EBX                                                             ;EDI = EBX
    Call    GetScript700First                                                   ;Seek First
    JZ      .NORMALERROR                                                        ;   Failure
    XOr     DL,DL                                                               ;DL = 0x00
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Ah                                                              ;Is char ":"?
    JE      .LABEL                                                              ;   Yes
    Cmp     AL,23h                                                              ;Is char "#"?
    JE      .Shp                                                                ;   Yes
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,45h                                                              ;Is char "E"?
    JE      short .E                                                            ;   Yes
    Cmp     AL,51h                                                              ;Is char "Q"?
    JE      short .Q                                                            ;   Yes
    Cmp     AL,57h                                                              ;Is char "W"?
    JE      .W                                                                  ;   Yes
    Cmp     AL,4Dh                                                              ;Is char "M"?
    JE      .M                                                                  ;   Yes
    Cmp     AL,43h                                                              ;Is char "C"?
    JE      .C                                                                  ;   Yes
    Cmp     AL,41h                                                              ;Is char "A"?
    JE      .A                                                                  ;   Yes
    Cmp     AL,53h                                                              ;Is char "S"?
    JE      .S                                                                  ;   Yes
    Cmp     AL,55h                                                              ;Is char "U"?
    JE      .U                                                                  ;   Yes
    Cmp     AL,44h                                                              ;Is char "D"?
    JE      .D                                                                  ;   Yes
    Cmp     AL,4Eh                                                              ;Is char "N"?
    JE      .N                                                                  ;   Yes
    Cmp     AL,42h                                                              ;Is char "B"?
    JE      .B                                                                  ;   Yes
    Cmp     AL,52h                                                              ;Is char "R"?
    JE      .R                                                                  ;   Yes
    Cmp     AL,46h                                                              ;Is char "F"?
    JE      .F                                                                  ;   Yes
    Jmp     .NORMALERROR                                                        ;   No

    .E:                                                                                                             ; e
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [scr700inc+03h],01h                                            ;Extension Command Zone
    Jmp     .EXTRETURN

    .Q:                                                                                                             ; q
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [RSI+RBX],00h                                                  ;Program[EBX] = 0x00
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .LABEL:
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Ah                                                              ;Is char ":"?
    JE      short .LABEL2                                                       ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)        ; :[LABEL]
    JZ      .NORMALERROR                                                        ;   Failure

    And     EAX,1023                                                            ;EAX &= 1023
%ifdef HOST64
    Lea     R8,[rel scr700lbl]
    Mov     [R8+RAX*4],EBX
%else
    Mov     [scr700lbl+EAX*4],EBX                                               ;Label[EAX] = EBX
%endif
    Jmp     .NORMALRETURN

    .LABEL2:                                                                                                        ; ::
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [scr700inc+03h],01h                                            ;Extension Command Zone
    Jmp     .EXTRETURN

    .NOP:                                                                                                           ; nop
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Test    AL,AL                                                               ;AL = 0x00?
    JZ      .NORMALERROR                                                        ;   Yes

    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,50h                                                              ;Is char "P"?
    JNE     .NORMALERROR                                                        ;   No

    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure
    Jmp     .NORMALRETURN

    .N:                                                                                                             ; n
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,4Fh                                                              ;Is char "O"?
    JE      short .NOP                                                          ;   Yes
    Mov     DL,04h                                                              ;DL = 0x04
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     [scr700tmp],RCX                                                     ;Temp = RCX (Save Param1 Pointer)
    Call    GetScript700Skip                                                    ;Skip
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     AL,[RCX]                                                            ;AL = [RCX]
    XOr     DH,DH                                                               ;DH = 0x00
    Cmp     AL,2Bh                                                              ;Is char "+"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x01)
    Cmp     AL,2Dh                                                              ;Is char "-"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x02)
    Cmp     AL,2Ah                                                              ;Is char "*"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x03)
    Cmp     AL,2Fh                                                              ;Is char "/"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x04)
    Cmp     AL,5Ch                                                              ;Is char "\"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x05)
    Cmp     AL,25h                                                              ;Is char "%"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x06)
    Cmp     AL,24h                                                              ;Is char "$"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x07)
    Cmp     AL,26h                                                              ;Is char "&"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x08)
    Cmp     AL,7Ch                                                              ;Is char "|"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x09)
    Cmp     AL,5Eh                                                              ;Is char "^"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x0A)
    Cmp     AL,3Ch                                                              ;Is char "<"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x0B)
    Cmp     AL,3Eh                                                              ;Is char ">"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x0C)
    Cmp     AL,5Fh                                                              ;Is char "_"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Inc     DH                                                                  ;DH++ (0x0D)
    Cmp     AL,21h                                                              ;Is char "!"?
    JE      short .NORMALNEXT                                                   ;   Yes
    Mov     DH,0FFh                                                             ;DH = 0xFF
    Jmp     short .NORMALNEXT

    .M:                                                                                                             ; m
    Mov     DL,02h                                                              ;DL = 0x02
    Jmp     short .NORMALNEXT

    .C:                                                                                                             ; c
    Mov     DL,03h                                                              ;DL = 0x03
    Jmp     short .NORMALNEXT

    .A:                                                                                                             ; a
    Mov     DX,0005h                                                            ;DL = 0x05, DH = 0x00
    Jmp     short .NORMALNEXT

    .S:                                                                                                             ; s
    Mov     DX,0105h                                                            ;DL = 0x05, DH = 0x01
    Jmp     short .NORMALNEXT

    .U:                                                                                                             ; u
    Mov     DX,0205h                                                            ;DL = 0x05, DH = 0x02
    Jmp     short .NORMALNEXT

    .D:                                                                                                             ; d
    Mov     DX,0305h                                                            ;DL = 0x05, DH = 0x03

    .NORMALNEXT:
    Cmp     DL,04h                                                              ;DL = 0x04? (Is command N?)
    JE      short .SETN                                                         ;   Yes
    Cmp     DL,05h                                                              ;DL = 0x05? (Is command A,S,U,D?)
    JE      short .SETASUD                                                      ;   Yes
        Mov     [RSI+RBX],DL                                                    ;Program[EBX] = DL
        Jmp     short .SETNE

    .SETN:
        Inc     DH                                                              ;DH++ (DH = 0xFF?)
        JZ      .NORMALERROR                                                    ;   Yes

        Dec     DH                                                              ;DH--
        Mov     [RSI+RBX],DL                                                    ;Program[EBX] = DL
        Inc     EBX                                                             ;EBX++
        Mov     [RSI+RBX],DH                                                    ;Program[EBX] = DH
        Jmp     short .SETNE

    .SETASUD:
        Inc     DH                                                              ;DH++ (DH = 0xFF?)
        JZ      .NORMALERROR                                                    ;   Yes

        Dec     DH                                                              ;DH--
        Mov     byte [RSI+RBX],04h                                              ;Program[EBX] = 0x04
        Inc     EBX                                                             ;EBX++
        Mov     [RSI+RBX],DH                                                    ;Program[EBX] = DH

    .SETNE:
    Inc     EBX                                                                 ;EBX++
    Cmp     DL,04h                                                              ;DL = 0x04? (Is command N?)
    JNE     short .NNEXT                                                        ;   No
        Call    GetScript700Last                                                ;Check Last
        JZ      .NORMALERROR                                                    ;   Failure

        Mov     RCX,[scr700tmp]                                                 ;RCX = Temp (Restore Param1 Pointer)
        Jmp     short .N1E

    .NNEXT:
        Inc     RCX                                                             ;RCX++
        Call    GetScript700Next                                                ;Seek Next
        JZ      .NORMALERROR                                                    ;   Failure

    .N1E:
    ShL     EDX,16                                                              ;EDX << 16
    Lea     RAX,[rel .N2]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    Inc     DH                                                                  ;DH++ (DH = 0x01)
    Jmp     short .SETVAL

    .W:                                                                                                             ; w
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,49h                                                              ;Is char "I"?
    JE      short .WI                                                           ;   Yes
    Cmp     AL,4Fh                                                              ;Is char "O"?
    JE      short .WO                                                           ;   Yes
    Dec     RCX                                                                 ;RCX--

    Mov     byte [RSI+RBX],01h                                                  ;Program[EBX] = 0x01
    Jmp     short .WNEXT

    .WI:                                                                                                            ; wi
    Mov     byte [RSI+RBX],16h                                                  ;Program[EBX] = 0x16
    Jmp     short .WNEXT

    .WO:                                                                                                            ; wo
    Mov     byte [RSI+RBX],17h                                                  ;Program[EBX] = 0x17

    .WNEXT:
    Inc     EBX                                                                 ;EBX++
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .NORMALERROR                                                        ;   Failure

    Lea     RAX,[rel .NORMALRETURN]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    XOr     DH,DH                                                               ;DH = 0x00
    Jmp     short .SETVAL

    .N2:
    ShR     EDX,16                                                              ;EDX >> 16
    Cmp     DL,04h                                                              ;DL = 0x04? (Is command N?)
    JNE     short .N2E                                                          ;   No
        Call    GetScript700Next                                                ;Seek Next
        JZ      .NORMALERROR                                                    ;   Failure
        Call    GetScript700Skip                                                ;Skip

    .N2E:
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .NORMALERROR                                                        ;   Failure

    Lea     RAX,[rel .NORMALRETURN]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    Mov     DH,01h                                                              ;DH = 0x01

    .SETVAL:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    XOr     DL,DL                                                               ;DL = 0x00
    Cmp     AL,23h                                                              ;Is char "#"?                       ; #[NUM]
    JE      short .SETVAL4B                                                     ;   Yes
    And     AL,0DFh                                                             ;AL &= 0xDF
    Add     DL,2                                                                ;DL += 2 (0x02)
    Cmp     AL,49h                                                              ;Is char "I"?                       ; i[PORT]
    JE      short .SETVAL1B                                                     ;   Yes
    Inc     DL                                                                  ;DL++ (0x03)
    Cmp     AL,4Fh                                                              ;Is char "O"?                       ; o[PORT]
    JE      short .SETVAL1B                                                     ;   Yes
    Inc     DL                                                                  ;DL++ (0x04)
    Cmp     AL,57h                                                              ;Is char "W"?                       ; w[WORK]
    JE      short .SETVAL1B                                                     ;   Yes
    Inc     DL                                                                  ;DL++ (0x05)
    Cmp     AL,58h                                                              ;Is char "X"?                       ; x[XRAM]
    JE      short .SETVAL1B                                                     ;   Yes
    XOr     AH,AH                                                               ;AH = 0x00
    Inc     DL                                                                  ;DL++ (0x06)
    Cmp     AL,52h                                                              ;Is char "R"?                       ; r(x)[RAM]
    JE      short .SETVALRD                                                     ;   Yes
    Inc     AH                                                                  ;AH++ (0x01)
    Add     DL,3                                                                ;DL += 3 (0x09)
    Cmp     AL,44h                                                              ;Is char "D"?                       ; d(x)[DATA]
    JE      short .SETVALRD                                                     ;   Yes
    Add     DL,3                                                                ;DL += 3 (0x0C)
    Cmp     AL,4Ch                                                              ;Is char "L"?                       ; l[LABEL]
    JE      short .SETVAL2B                                                     ;   Yes

    Dec     RCX                                                                 ;RCX--                              ; (#)[NUM]/[PORT]
    Mov     DL,DH                                                               ;DL = DH
    Dec     DH                                                                  ;DH-- (DH = 0x01?)
    JNZ     short .SETVAL4B                                                     ;   No (w command)
    Jmp     short .SETVAL1B                                                     ;   Yes (others command)

    .SETVALRD:
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,42h                                                              ;Is char "B"?                       ; rb[RAM], db[DATA]
    JE      short .SETVALRD2                                                    ;   Yes
    Inc     DL                                                                  ;DL++ (0x07 or 0x0A)
    Cmp     AL,57h                                                              ;Is char "W"?                       ; rw[RAM], dw[DATA]
    JE      short .SETVALRD2                                                    ;   Yes
    Inc     DL                                                                  ;DL++ (0x08 or 0x0B)
    Cmp     AL,44h                                                              ;Is char "D"?                       ; rd[RAM], dd[DATA]
    JE      short .SETVALRD2                                                    ;   Yes
    Dec     RCX                                                                 ;RCX--                              ; r[RAM], d[DATA]
    Sub     DL,2                                                                ;DL -= 2 (0x06 or 0x09)

    .SETVALRD2:
    Dec     AH                                                                  ;AH-- (AH = 0x01?)
    JNZ     short .SETVAL2B                                                     ;   No

    .SETVAL4B:                                                                                                      ; 4 byte method
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Fh                                                              ;Is char "?"?
    JE      short .SETVALCMP                                                    ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     [RSI+RBX],DL                                                        ;Program[EBX] = DL
    Inc     EBX                                                                 ;EBX++
    Mov     [RSI+RBX],EAX                                                       ;Program[EBX] = EAX
    Add     EBX,4                                                               ;EBX += 4
    Jmp     qword [scr700jmp]

    .SETVAL1B:                                                                                                      ; 1 byte method
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Fh                                                              ;Is char "?"?
    JE      short .SETVALCMP                                                    ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     [RSI+RBX],DL                                                        ;Program[EBX] = DL
    Inc     EBX                                                                 ;EBX++
    Mov     [RSI+RBX],AL                                                        ;Program[EBX] = AL
    Inc     EBX                                                                 ;EBX++
    Jmp     qword [scr700jmp]

    .SETVAL2B:                                                                                                      ; 2 byte method
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Fh                                                              ;Is char "?"?
    JE      short .SETVALCMP                                                    ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     [RSI+RBX],DL                                                        ;Program[EBX] = DL
    Inc     EBX                                                                 ;EBX++
    Mov     [RSI+RBX],AX                                                        ;Program[EBX] = AX
    Add     EBX,2                                                               ;EBX += 2
    Jmp     qword [scr700jmp]

    .SETVALCMP:                                                                                                     ; cmp method
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Add     DL,10h                                                              ;DL += 0x10
    Mov     [RSI+RBX],DL                                                        ;Program[EBX] = DL
    Inc     EBX                                                                 ;EBX++
    Jmp     qword [scr700jmp]

    .B:                                                                                                             ; bxx
    Inc     RCX                                                                 ;RCX++
    Mov     AH,[RCX]                                                            ;AH = [RCX]
    And     AH,0DFh                                                             ;AH &= 0xDF
    Test    AH,AH                                                               ;AH = 0x00?
    JZ      .NORMALERROR                                                        ;   Yes

    Cmp     AH,50h                                                              ;Is char "P"?
    JE      .BP                                                                 ;   Yes
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Test    AL,AL                                                               ;AL = 0x00?
    JZ      .NORMALERROR                                                        ;   Yes

    Mov     DL,05h                                                              ;DL = 0x05
    Cmp     AX,5241h                                                            ;Is string "BRA"?                   ; bra
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x06)
    Cmp     AX,4551h                                                            ;Is string "BEQ"?                   ; beq
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x07)
    Cmp     AX,4E45h                                                            ;Is string "BNE"?                   ; bne
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x08)
    Cmp     AX,4745h                                                            ;Is string "BGE"?                   ; bge
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x09)
    Cmp     AX,4C45h                                                            ;Is string "BLE"?                   ; ble
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x0A)
    Cmp     AX,4754h                                                            ;Is string "BGT"?                   ; bgt
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x0B)
    Cmp     AX,4C54h                                                            ;Is string "BLT"?                   ; blt
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x0C)
    Cmp     AX,4343h                                                            ;Is string "BCC"?                   ; bcc
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x0D)
    Cmp     AX,4C4Fh                                                            ;Is string "BLO"?                   ; blo
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x0E)
    Cmp     AX,4849h                                                            ;Is string "BHI"?                   ; bhi
    JE      short .BXXNEXT                                                      ;   Yes
    Inc     DL                                                                  ;DL++ (0x0F)
    Cmp     AX,4353h                                                            ;Is string "BCS"?                   ; bcs
    JE      short .BXXNEXT                                                      ;   Yes
    Jmp     .NORMALERROR                                                        ;   No

    .BXXNEXT:
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,23h                                                              ;Is char "#"?
    JE      short .BXXVALN                                                      ;   Yes
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,57h                                                              ;Is char "W"?
    JE      short .BXXVALW                                                      ;   Yes
    Dec     RCX                                                                 ;RCX--

    .BXXVALN:
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .NORMALERROR                                                        ;   Failure

    And     EAX,1023                                                            ;EAX &= 1023
    Mov     [RSI+RBX],DL                                                        ;Program[EBX] = DL
    Inc     EBX                                                                 ;EBX++
    Mov     [RSI+RBX],AX                                                        ;Program[EBX] = AX
    Add     EBX,2                                                               ;EBX += 2
    Jmp     .NORMALRETURN

    .BXXVALW:
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     AH,80h                                                              ;AH = 0x80
    Mov     [RSI+RBX],DL                                                        ;Program[EBX] = DL
    Inc     EBX                                                                 ;EBX++
    Mov     [RSI+RBX],AX                                                        ;Program[EBX] = AX
    Add     EBX,2                                                               ;EBX += 2
    Jmp     .NORMALRETURN

    .BP:                                                                                                            ; bp
    Test    dword [apuCbMask],CBE_REQBP                                         ;Is supported callback?
    JZ      .NORMALERROR                                                        ;   No
    Cmp     qword [apuCbFunc],0                                                 ;Is defined callback function?
    JE      .NORMALERROR                                                        ;   No

    Mov     byte [RSI+RBX],18h                                                  ;Program[EBX] = 0x18
    Inc     EBX                                                                 ;EBX++
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .NORMALERROR                                                        ;   Failure

    Lea     RAX,[rel .NORMALRETURN]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    XOr     DH,DH                                                               ;DH = 0x00
    Jmp     .SETVAL

    .R:                                                                                                             ; r
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,30h                                                              ;Is char "0"?
    JE      short .R0                                                           ;   Yes
    Cmp     AL,31h                                                              ;Is char "1"?
    JE      short .R1                                                           ;   Yes
    Dec     RCX                                                                 ;RCX--
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [RSI+RBX],10h                                                  ;Program[EBX] = 0x10
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .R0:                                                                                                            ; r0
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure
    Mov     byte [RSI+RBX],11h                                                  ;Program[EBX] = 0x11
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .R1:                                                                                                            ; r1
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [RSI+RBX],12h                                                  ;Program[EBX] = 0x12
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .F:                                                                                                             ; f
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,30h                                                              ;Is char "0"?
    JE      short .F0                                                           ;   Yes
    Cmp     AL,31h                                                              ;Is char "1"?
    JE      short .F1                                                           ;   Yes
    Dec     RCX                                                                 ;RCX--
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [RSI+RBX],13h                                                  ;Program[EBX] = 0x13
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .F0:                                                                                                            ; f0
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [RSI+RBX],14h                                                  ;Program[EBX] = 0x14
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .F1:                                                                                                            ; f1
    Call    GetScript700Last                                                    ;Check Last
    JZ      .NORMALERROR                                                        ;   Failure

    Mov     byte [RSI+RBX],15h                                                  ;Program[EBX] = 0x15
    Inc     EBX                                                                 ;EBX++
    Jmp     .NORMALRETURN

    .Shp:                                                                                                           ; #
    Test    dword [apuCbMask],CBE_INCS700 | CBE_INCDATA                         ;Is supported callback?
    JZ      .ShpERROR                                                           ;   No
    Cmp     qword [apuCbFunc],0                                                 ;Is defined callback function?
    JE      .ShpERROR                                                           ;   No

    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,49h                                                              ;Is char "I"?                       ; #i
    JE      short .ShpI                                                         ;   Yes
    Jmp     .ShpERROR                                                           ;   No

    .ShpI:
    Inc     RCX                                                                 ;RCX++
    Mov     DL,40h                                                              ;DL = 0x40 (TEXT mode)
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,09h                                                              ;AL = 0x09? (TAB)
    JE      short .ShpI1                                                        ;   Yes
    Cmp     AL,20h                                                              ;AL = 0x20? (SPACE)
    JE      short .ShpI1                                                        ;   Yes

    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,54h                                                              ;Is char "T"?                       ; #it
    JE      short .ShpIT                                                        ;   Yes

    Test    byte [scr700inc+03h],02h                                            ;Data Command Zone?
    JZ      .ShpERROR                                                           ;   No
    Mov     DL,20h                                                              ;DL = 0x20 (DATA mode)
    Cmp     AL,42h                                                              ;Is char "B"?                       ; #ib
    JE      short .ShpIB                                                        ;   Yes
    Jmp     .ShpERROR                                                           ;   No

    .ShpIT:
    Inc     RCX                                                                 ;RCX++

    .ShpI1:
    Test    byte [scr700inc+02h],-1                                             ;Include mode?
    JNZ     .ShpERROR                                                           ;   Yes
    Jmp     short .ShpI2

    .ShpIB:
    Inc     RCX                                                                 ;RCX++

    .ShpI2:
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .ShpERROR                                                           ;   Failure
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,22h                                                              ;Is char "\""?
    JNE     .ShpERROR                                                           ;   No

    Mov     [scr700inc],DL                                                      ;Include = 00h:NEW
    Inc     RCX                                                                 ;RCX++

    Push    EDI,ECX
    Lea     RDI,[rel scr700pth]
    XOr     EAX,EAX
    Mov     ECX,64
    Rep     StoSD
    Pop     ECX,EDI

    Lea     RDX,[rel scr700pth]

    .ShpI3:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;Is char NULL?
    JE      .ShpERROR                                                           ;   Yes
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      .ShpERROR                                                           ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      .ShpERROR                                                           ;   Yes
    Cmp     AL,22h                                                              ;Is char "\""?
    JE      short .ShpI4                                                        ;   Yes

    Inc     AH
    JZ      .ShpERROR
    Mov     [RDX],AL                                                            ;Path[RDX] = AL
    Inc     RDX                                                                 ;RDX++
    Inc     RCX                                                                 ;RCX++
    Jmp     short .ShpI3

    .ShpI4:
    Mov     [scr700inc+04h],EBX
    Inc     EBX                                                                 ;EBX++
    Mov     [scr700inc+08h],EBX                                                 ;Store pointer of successful for not call SetScript700

    MovZX   EDX,byte [scr700inc]                                                ;Include = 02h:OLD 01h:00h 00h:NEW
    ShR     word [scr700inc+01h],8                                              ;          02h:00h 01h:OLD 00h:NEW
    Mov     [scr700inc+02h],DL                                                  ;          02h:NEW 01h:OLD 00h:NEW
                                                                                ;EDX = 0x40 (TEXT) or 0x20 (DATA)
    ShL     EDX,24                                                              ;EDX << 24 (0x40000000 or 0x20000000)
    Test    dword [apuCbMask],EDX                                               ;Is supported callback?
    JZ      short .ShpERROR                                                     ;   No

    Push    EDI,EBX,ECX                                                         ;STDCALL is destroy EAX,ECX,EDX
    Mov     RDI,[apuCbFunc]
    Sub     EBX,[scr700dat]                                                     ;EBX -= Data Offset
    MovZX   EAX,AH                                                              ;EAX = Size of file name
    Lea     RCX,[rel scr700pth]                                                 ;ECX = Pointer of file name
    Call    EDI,EDX,EBX,EAX,ECX
    Pop     ECX,EBX,EDI

    ShL     word [scr700inc+01h],8                                              ;Include = 02h:OLD 01h:00h 00h:NEW

    Mov     EDX,[scr700inc+08h]                                                 ;EDX = Return value of SetScript700
    Test    EDX,EDX                                                             ;EDX = ?
    JS      .CRITICALERROR                                                      ;   < 0
    JZ      short .ShpEXIT                                                      ;   = 0
        Mov     EBX,EDX                                                         ;EBX = EDX

    .ShpEXIT:
    Dec     EBX                                                                 ;EBX--
    Call    GetScript700Last                                                    ;Check Last
    JZ      short .ShpERROR                                                     ;   Failure
    Mov     AH,[scr700inc+03h]
    Dec     AH
    JZ      .EXTRETURN
    Dec     AH
    JZ      .DATARETURN2
    Jmp     .NORMALRETURN

    .ShpERROR:
    Mov     AH,[scr700inc+03h]
    Dec     AH
    JZ      .EXTERROR
    Dec     AH
    JZ      .DATAERROR

    .NORMALERROR:
    Mov     EBX,EDI                                                             ;EBX = EDI
    Test    byte [RCX],-1                                                       ;Is char NULL?
    JZ      .EXIT                                                               ;   Yes
    Call    GetScript700NextLine                                                ;Next Line
    Jmp     .NORMALRETURN

    ;---------- Extension Command Zone ----------

    .EXTRETURN:
    Call    GetScript700First                                                   ;Seek First
    JZ      .EXTERROR                                                           ;   Failure
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Ah                                                              ;Is char ":"?
    JE      short .EXLABEL                                                      ;   Yes
    Cmp     AL,23h                                                              ;Is char "#"?
    JE      .Shp                                                                ;   Yes
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,45h                                                              ;Is char "E"?
    JE      short .EXE                                                          ;   Yes
    Cmp     AL,4Dh                                                              ;Is char "M"?
    JE      short .EXM                                                          ;   Yes
    Cmp     AL,43h                                                              ;Is char "C"?
    JE      .EXC                                                                ;   Yes
    Cmp     AL,44h                                                              ;Is char "D"?
    JE      .EXD                                                                ;   Yes
    Cmp     AL,56h                                                              ;Is char "V"?
    JE      .EXV                                                                ;   Yes
    Jmp     .EXTERROR                                                           ;   No

    .EXLABEL:                                                                                                       ; ::
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,3Ah                                                              ;Is char ":"?
    JNE     .EXTERROR                                                           ;   No

    Call    GetScript700Last                                                    ;Check Last
    JZ      .EXTERROR                                                           ;   Failure
    Jmp     short .EXTRETURN

    .EXE:                                                                                                           ; e
    Call    GetScript700Last                                                    ;Check Last
    JZ      .EXTERROR                                                           ;   Failure

    Mov     byte [scr700inc+03h],02h                                            ;Data Command Zone
    Jmp     .DATARETURN

    .EXM:                                                                                                           ; m
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure

    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,21h                                                              ;Is char "!"?
    JE      short .EXMALL                                                       ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    MovZX   EAX,AL                                                              ;EAX = AL
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    XOr     byte [R8+RAX],01h
%else
    XOr     byte [scr700dsp+EAX],01h                                            ;pDSPFlag[EAX] ^= 0x01
%endif
    Jmp     .EXTRETURN

    .EXMALL:                                                                                                        ; !
    Call    GetScript700Last                                                    ;Check Last
    JZ      .EXTERROR                                                           ;   Failure
    XOr     EDX,EDX                                                             ;EDX = 0x00

    .EXMALLRETURN:
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    XOr     dword [R8+RDX],01010101h
%else
    XOr     dword [scr700dsp+EDX],01010101h                                     ;pDSPFlag[EDX] ^= 0x01010101
%endif
    Add     EDX,4                                                               ;EDX += 4
    Cmp     EDX,256                                                             ;EDX = 256?
    JNE     short .EXMALLRETURN                                                 ;   No
    Jmp     .EXTRETURN

    .EXC:                                                                                                           ; c
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure

    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,21h                                                              ;Is char "!"?
    JE      short .EXCALL                                                       ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    Mov     DL,AL                                                               ;DL = AL
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    MovZX   EDX,DL                                                              ;EDX = DL
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      byte [R8+RDX],02h
    Lea     R8,[rel scr700chg]
    Mov     [R8+RDX],AL
%else
    Or      byte [scr700dsp+EDX],02h                                            ;pDSPFlag[EDX] |= 0x02
    Mov     [scr700chg+EDX],AL                                                  ;pDSPChange[EDX] = AL
%endif
    Jmp     .EXTRETURN

    .EXCALL:                                                                                                        ; !
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure
    XOr     EDX,EDX                                                             ;EDX = 0x00

    .EXCALLRETURN:
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      dword [R8+RDX],02020202h
    Lea     R8,[rel scr700chg]
    Mov     [R8+RDX+0],AL
    Mov     [R8+RDX+1],AL
    Mov     [R8+RDX+2],AL
    Mov     [R8+RDX+3],AL
%else
    Or      dword [scr700dsp+EDX],02020202h                                     ;pDSPFlag[EDX] |= 0x02020202
    Mov     [scr700chg+EDX+0],AL                                                ;pDSPChange[EDX+0] = AL
    Mov     [scr700chg+EDX+1],AL                                                ;pDSPChange[EDX+1] = AL
    Mov     [scr700chg+EDX+2],AL                                                ;pDSPChange[EDX+2] = AL
    Mov     [scr700chg+EDX+3],AL                                                ;pDSPChange[EDX+3] = AL
%endif
    Add     EDX,4                                                               ;EDX += 4
    Cmp     EDX,256                                                             ;EDX = 256?
    JNE     short .EXCALLRETURN                                                 ;   No
    Jmp     .EXTRETURN

    .EXD:                                                                                                           ; d
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure

    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,21h                                                              ;Is char "!"?
    JE      short .EXDALL                                                       ;   Yes
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    Mov     DL,AL                                                               ;DL = AL
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    MovZX   EDX,DL                                                              ;EDX = DL
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      byte [R8+RDX],04h
    Lea     R8,[rel scr700det]
    Mov     [R8+RDX*4],EAX
%else
    Or      byte [scr700dsp+EDX],04h                                            ;pDSPFlag[EDX] |= 0x04
    Mov     [scr700det+EDX*4],EAX                                               ;pDSPDetune[EDX] = EAX
%endif
    Jmp     .EXTRETURN

    .EXDALL:                                                                                                        ; !
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure
    XOr     EDX,EDX                                                             ;EDX = 0x00

    .EXDALLRETURN:
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      dword [R8+RDX],04040404h
    Lea     R8,[rel scr700det]
    Mov     [R8+RDX*4+0],EAX
    Mov     [R8+RDX*4+4],EAX
    Mov     [R8+RDX*4+8],EAX
    Mov     [R8+RDX*4+12],EAX
%else
    Or      dword [scr700dsp+EDX],04040404h                                     ;pDSPFlag[EDX] |= 0x04040404
    Mov     [scr700det+EDX*4+0],EAX                                             ;pDSPDetune[EDX+0] = EAX
    Mov     [scr700det+EDX*4+4],EAX                                             ;pDSPDetune[EDX+1] = EAX
    Mov     [scr700det+EDX*4+8],EAX                                             ;pDSPDetune[EDX+2] = EAX
    Mov     [scr700det+EDX*4+12],EAX                                            ;pDSPDetune[EDX+3] = EAX
%endif
    Add     EDX,4                                                               ;EDX += 4
    Cmp     EDX,256                                                             ;EDX = 256?
    JNE     short .EXDALLRETURN                                                 ;   No
    Jmp     .EXTRETURN

    .EXV:                                                                                                           ; v
    Inc     RCX                                                                 ;RCX++
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure

    XOr     DH,DH                                                               ;DH = 0x00
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Inc     RCX                                                                 ;RCX++
    Cmp     AL,21h                                                              ;Is char "!"?
    JE      .EXVALL                                                             ;   Yes
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,56h                                                              ;Is char "V"?
    JE      .EXVV                                                               ;   Yes
    Cmp     AL,45h                                                              ;Is char "E"?
    JE      .EXVE                                                               ;   Yes
    Mov     DL,S700_MVOL_L                                                      ;DL = MasterVolumeLeft
    Cmp     AL,4Ch                                                              ;Is char "L"?
    JE      short .EXVL                                                         ;   Yes
    Mov     DL,S700_MVOL_R                                                      ;DL = MasterVolumeRight
    Cmp     AL,52h                                                              ;Is char "R"?
    JE      short .EXVR                                                         ;   Yes
    Dec     RCX                                                                 ;RCX--
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    MovZX   DX,AL                                                               ;DL = AL, DH = 0x00
    Lea     RAX,[rel .EXTRETURN]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address

    .ENVSET:
    ShL     EDX,16                                                              ;EDX << 16
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    Push    EDX                                                                 ;Push EDX
    XOr     EDX,EDX                                                             ;EDX = 0
    Test    EAX,EAX                                                             ;If EAX < 0
    SetS    DL                                                                  ;   Yes, EDX = 1
    Dec     EDX                                                                 ;EDX--
    And     EAX,EDX                                                             ;EAX &= EDX
    Pop     EDX                                                                 ;Pop EDX
    ShR     EDX,16                                                              ;EDX >> 16
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      byte [R8+RDX],08h
    Lea     R8,[rel scr700vol]
    Mov     [R8+RDX*4],EAX
%else
    Or      byte [scr700dsp+EDX],08h                                            ;pDSPFlag[EDX] |= 0x08
    Mov     [scr700vol+EDX*4],EAX                                               ;pDSPVolume[EDX] = EAX
%endif
    Jmp     qword [scr700jmp]

    .EXVL:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Cmp     AL,52h                                                              ;Is char "R"?
    JE      short .EXVLR                                                        ;   Yes

    .EXVR:
    Inc     DH                                                                  ;DH++
    Lea     RAX,[rel .EXVLR3]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    Jmp     short .ENVSET

    .EXVLR:
    Inc     RCX                                                                 ;RCX++
    Inc     DH                                                                  ;DH++
    Lea     RAX,[rel .EXVLR2]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    Jmp     short .ENVSET

    .EXVLR2:
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      dword [R8+RDX],08080808h
    Lea     R8,[rel scr700vol]
    Mov     [R8+RDX*4+4],EAX
    Mov     [R8+RDX*4+12],EAX
%else
    Or      dword [scr700dsp+EDX],08080808h                                     ;pDSPFlag[EDX] |= 0x08080808
    Mov     [scr700vol+EDX*4+4],EAX                                             ;pDSPVolume[EDX+1] = EAX
    Mov     [scr700vol+EDX*4+12],EAX                                            ;pDSPVolume[EDX+3] = EAX
%endif

    .EXVLR3:
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      byte [R8+RDX+2],08h
    Lea     R8,[rel scr700vol]
    Mov     [R8+RDX*4+8],EAX
%else
    Or      byte [scr700dsp+EDX+2],08h                                          ;pDSPFlag[EDX+2] |= 0x08
    Mov     [scr700vol+EDX*4+8],EAX                                             ;pDSPVolume[EDX+2] = EAX
%endif
    Jmp     .EXTRETURN

    .EXVALL:
    Call    GetScript700Next                                                    ;Seek Next
    JZ      .EXTERROR                                                           ;   Failure
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)
    JZ      .EXTERROR                                                           ;   Failure

    XOr     EDX,EDX                                                             ;EDX = 0
    Test    EAX,EAX                                                             ;If EAX < 0
    SetS    DL                                                                  ;   Yes, EDX = 1
    Dec     EDX                                                                 ;EDX--
    And     EAX,EDX                                                             ;EAX &= EDX
    XOr     EDX,EDX

    .EXVALLRETURN:
%ifdef HOST64
    Lea     R8,[rel scr700dsp]
    Or      dword [R8+RDX],08080808h
    Lea     R8,[rel scr700vol]
    Mov     [R8+RDX*4+0],EAX
    Mov     [R8+RDX*4+4],EAX
    Mov     [R8+RDX*4+8],EAX
    Mov     [R8+RDX*4+12],EAX
%else
    Or      dword [scr700dsp+EDX],08080808h                                     ;pDSPFlag[EDX] |= 0x08080808
    Mov     [scr700vol+EDX*4+0],EAX                                             ;pDSPVolume[EDX+0] = EAX
    Mov     [scr700vol+EDX*4+4],EAX                                             ;pDSPVolume[EDX+1] = EAX
    Mov     [scr700vol+EDX*4+8],EAX                                             ;pDSPVolume[EDX+2] = EAX
    Mov     [scr700vol+EDX*4+12],EAX                                            ;pDSPVolume[EDX+3] = EAX
%endif
    Add     EDX,4                                                               ;EDX += 4
    Cmp     EDX,256                                                             ;EDX = 256?
    JNE     short .EXVALLRETURN                                                 ;   No
    Jmp     .EXTRETURN

    .EXVV:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Mov     DL,S700_MVOL_L                                                      ;DL = MasterVolumeLeft
    Cmp     AL,4Ch                                                              ;Is char "L"?
    JE      short .EXVCMD                                                       ;   Yes
    Mov     DL,S700_MVOL_R                                                      ;DL = MasterVolumeRight
    Cmp     AL,52h                                                              ;Is char "R"?
    JE      short .EXVCMD                                                       ;   Yes
    Jmp     short .EXTERROR

    .EXVE:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    And     AL,0DFh                                                             ;AL &= 0xDF
    Mov     DL,S700_ECHO_L                                                      ;DL = EchoVolumeLeft
    Cmp     AL,4Ch                                                              ;Is char "L"?
    JE      short .EXVCMD                                                       ;   Yes
    Mov     DL,S700_ECHO_R                                                      ;DL = EchoVolumeRight
    Cmp     AL,52h                                                              ;Is char "R"?
    JE      short .EXVCMD                                                       ;   Yes
    Jmp     short .EXTERROR

    .EXVCMD:
    Inc     RCX                                                                 ;RCX++
    Inc     DH                                                                  ;DH++
    Lea     RAX,[rel .EXTRETURN]
    Mov     [scr700jmp],RAX                                                     ;Set Return Address
    Jmp     .ENVSET

    .EXTERROR:
    Test    byte [RCX],-1                                                       ;Is char NULL?
    JZ      .EXIT                                                               ;   Yes
    Call    GetScript700NextLine                                                ;Next Line
    Jmp     .EXTRETURN

    ;---------- Data Command Zone ----------

    .DATARETURN:
    XOr     AH,AH                                                               ;AH = 0x00
    Mov     EDI,EBX                                                             ;EDI = EBX
    Mov     [RSI+RBX],AH                                                        ;Program[EBX] = AH
    Mov     [scr700dat],EBX                                                     ;Data Offset = EBX
    Inc     dword [scr700dat]                                                   ;Data Offset++
    Call    GetScript700First                                                   ;Seek First

    .DATARETURN2:
    Mov     DL,AH                                                               ;DL = AH (0x00)

    .DATARETURNLINE:
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Cmp     AL,00h                                                              ;AL = 0x00?
    JE      .EXIT                                                               ;   Yes
    Cmp     AL,3Ah                                                              ;Is char ":"?
    JE      short .DATALABEL                                                    ;   Yes
    Cmp     AL,23h                                                              ;Is char "#"?
    JE      .Shp                                                                ;   Yes
    Inc     RCX                                                                 ;RCX++
    Cmp     AL,0Ah                                                              ;Is char RETURN?
    JE      short .DATANEWLINE                                                  ;   Yes
    Cmp     AL,0Dh                                                              ;Is char RETURN?
    JE      short .DATANEWLINE                                                  ;   Yes
    Cmp     AL,09h                                                              ;AL = 0x09? (TAB)
    JE      short .DATARETURNLINE                                               ;   Yes
    Cmp     AL,20h                                                              ;AL = 0x20? (SPACE)
    JE      short .DATARETURNLINE                                               ;   Yes
    Sub     AL,30h                                                              ;AL -= 0x30
    Cmp     AL,10                                                               ;AL < 10? (Is char "0" to "9"?)
    JB      short .DATANUM                                                      ;   Yes
    Sub     AL,11h                                                              ;AL -= 0x11 (0x41)
    Cmp     AL,6                                                                ;AL < 6? (Is char "A" to "F"?)
    JB      short .DATAHEX                                                      ;   Yes
    Sub     AL,20h                                                              ;AL -= 0x20 (0x61)
    Cmp     AL,6                                                                ;AL < 6? (Is not char "a" to "f"?)
    JB      short .DATAHEX                                                      ;   Yes
    Dec     RCX                                                                 ;RCX--
    Call    GetScript700NextLine                                                ;Next Line
    Jmp     short .DATARETURNLINE

    .DATALABEL:
    Inc     RCX                                                                 ;RCX++
    Mov     AL,[RCX]                                                            ;AL = [RCX]
    Call    GetScript700Number                                                  ;Parse Number (EAX = result)        ; :[LABEL]
    JZ      .DATAERROR                                                          ;   Failure

    And     EAX,1023                                                            ;EAX &= 1023
    Mov     EDX,EBX                                                             ;EDX = EBX
    Sub     EDX,[scr700dat]                                                     ;EDX -= Data Offset
    Inc     EDX                                                                 ;EDX++
    Or      EDX,80000000h                                                       ;EDX |= 0x80000000
%ifdef HOST64
    Lea     R8,[rel scr700lbl]
    Mov     [R8+RAX*4],EDX
%else
    Mov     [scr700lbl+EAX*4],EDX                                               ;Label[EAX] = EDX
%endif

    .DATANEWLINE:
    XOr     AH,AH                                                               ;AH = 0x00
    Jmp     .DATARETURN2

    .DATAHEX:
    Add     AL,10                                                               ;AL += 10

    .DATANUM:
    Dec     DL                                                                  ;DL-- (DL = 0x00?)
    JZ      short .DATANUM2                                                     ;   Yes

    ShL     AX,12                                                               ;AX << 12 (Mov AH,AL; ShL AH,4)
    Add     DL,2                                                                ;DL += 2
    Jmp     .DATARETURNLINE

    .DATANUM2:
    Or      AH,AL                                                               ;AH |= AL
    Inc     EBX                                                                 ;EBX++
    And     EBX,SCR700MASK                                                      ;EBX &= Program Mask
    Cmp     EBX,EDI                                                             ;EBX < EDI?
    JB      short .CRITICALERROR                                                ;   Yes

    Mov     [RSI+RBX],AH                                                        ;Program[EBX] = AH
    Mov     EDI,EBX                                                             ;EDI = EBX
    Jmp     .DATARETURNLINE

    .DATAERROR:
    Test    byte [RCX],-1                                                       ;Is char NULL?
    JZ      short .EXIT                                                         ;   Yes
    Call    GetScript700NextLine                                                ;Next Line
    XOr     AH,AH                                                               ;AH = 0x00
    Jmp     .DATARETURN2

    ;---------- Error ----------

    .CRITICALERROR:
    XOr     EAX,EAX                                                             ;EAX = 0x00
    Test    byte [scr700inc+02h],-1                                             ;Include mode?
    JNZ     short .NORESET                                                      ;   Yes
        Mov     [RSI],AL                                                        ;Program[0] = AL

    .NORESET:
    Test    RCX,RCX                                                             ;RCX = NULL?
    SetZ    AL                                                                  ;AL = Zero?
    Dec     EAX                                                                 ;EAX--
    Jmp     short .FINALIZE

    ;---------- Finalize ----------

    .EXIT:
    Mov     EAX,EBX                                                             ;EAX = EBX
    Inc     EAX                                                                 ;EAX++
    Test    byte [scr700inc+02h],-1                                             ;Include mode?
    JNZ     short .FINALIZE                                                     ;   Yes

    Mov     ECX,[scr700dat]                                                     ;ECX = Data Offset
    Test    ECX,ECX                                                             ;ECX = 0x00?
    JNZ     short .FINALIZE                                                     ;   No

    Mov     [RSI+RBX],CL                                                        ;Program[EBX] = CL
    Mov     [scr700dat],EAX                                                     ;Data Offset = EAX

    .FINALIZE:
    Mov     [scr700inc+08h],EAX

ENDP


;===================================================================================================
;Set Script700 Binary Data Function

PROC SetScript700Data, addr, pData, size

    Mov     RAX,[pData]                                                         ;RAX = Data Pointer
    Test    RAX,RAX                                                             ;RAX = NULL?
    JZ      short .FINALIZE                                                     ;   Yes

    Mov     EAX,[scr700dat]                                                     ;EAX = Data Offset
    Add     EAX,[addr]                                                          ;EAX += addr, is overflow?
    JO      short .CRITICALERROR                                                ;   Yes
    Add     EAX,[size]                                                          ;EAX += size, is overflow?
    JO      short .CRITICALERROR                                                ;   Yes
    Cmp     EAX,SCR700SIZE                                                      ;EAX > Buffer Size?
    JG      short .CRITICALERROR                                                ;   Yes

    Push    EDI,ESI,ECX

    Mov     RDI,[pSCRRAM]                                                       ;EDI = Script RAM Pointer
    Mov     EAX,[scr700dat]
    Add     RDI,RAX                                                             ;EDI += Data Offset
    Mov     EAX,[addr]
    Add     RDI,RAX                                                             ;EDI += addr
    Mov     RSI,[pData]                                                         ;ESI = Data Pointer

    Mov     ECX,[size]                                                          ;ECX = size
    ShR     ECX,2                                                               ;ECX >> 2
    Rep     MovSD                                                               ;memcpy(EDI, ESI, ECX*4)

    Mov     ECX,[size]                                                          ;ECX = size
    And     ECX,3                                                               ;ECX &= 3
    Rep     MovSB                                                               ;memcpy(EDI, ESI, ECX)

    Mov     RAX,RDI                                                             ;EAX = EDI (RAM Pointer + DataOffset + addr + size)
    Sub     RAX,[pSCRRAM]                                                       ;EAX -= Script RAM Pointer

    Pop     ECX,ESI,EDI
    Jmp     short .FINALIZE

    .CRITICALERROR:
    XOr     EAX,EAX                                                             ;EAX = 0x00
    Dec     EAX                                                                 ;EAX--

    .FINALIZE:
    Mov     [scr700inc+08h],EAX

ENDP


;===================================================================================================
;Get SNESAPU Context Buffer Size Function

PROC GetSNESAPUContextSize
USES ECX

    XOr     EAX,EAX

    Mov     ECX,apuVarEP - apuRAMBuf                                            ;ECX = Variable size of APU.asm
    And     ECX,0FFFFFFFCh
    Add     ECX,4

    Add     EAX,ECX                                                             ;EAX += ECX

    Lea     RCX,[rel dspVarEP]                                                  ;ECX = Variable size of DSP.asm
    Lea     RDX,[rel mix]
    Sub     RCX,RDX
    And     ECX,0FFFFFFFCh
    Add     ECX,4

    Add     EAX,ECX                                                             ;EAX += ECX

    Lea     RCX,[rel spcVarEP]                                                  ;ECX = Variable size of SPC700.asm
    Lea     RDX,[rel extraRAM]
    Sub     RCX,RDX
    And     ECX,0FFFFFFFCh
    Add     ECX,4

    Add     EAX,ECX                                                             ;EAX += ECX

ENDP


;===================================================================================================
;Get SNESAPU Context Data Function

PROC GetSNESAPUContext, pCtxOut
USES ECX,ESI,EDI

    Mov     RDI,[pCtxOut]

    Mov     ECX,apuVarEP - apuRAMBuf                                            ;ECX = Variable size of APU.asm
    ShR     ECX,2
    Inc     ECX

    Lea     RSI,[rel apuRAMBuf]                                                 ;memcpy(&EDI, &apuRAMBuf, ECX*4)
    Rep     MovSD

    Lea     RAX,[rel dspVarEP]                                                  ;ECX = Variable size of DSP.asm
    Lea     RCX,[rel mix]
    Sub     RAX,RCX
    Mov     ECX,EAX
    ShR     ECX,2
    Inc     ECX

    Lea     RSI,[rel mix]                                                       ;memcpy(&EDI, &mix, ECX*4)
    Rep     MovSD

    Lea     RAX,[rel spcVarEP]                                                  ;ECX = Variable size of SPC700.asm
    Lea     RCX,[rel extraRAM]
    Sub     RAX,RCX
    Mov     ECX,EAX
    ShR     ECX,2
    Inc     ECX

    Lea     RSI,[rel extraRAM]                                                  ;memcpy(&EDI, &extraRAM, ECX*4)
    Rep     MovSD

    XOr     EAX,EAX

ENDP


;===================================================================================================
;Set SNESAPU Context Data Function

PROC SetSNESAPUContext, pCtxIn
USES ECX,ESI,EDI

    Mov     RSI,[pCtxIn]

    Mov     ECX,apuVarEP - apuRAMBuf                                            ;ECX = Variable size of APU.asm
    ShR     ECX,2
    Inc     ECX

    Lea     RDI,[rel apuRAMBuf]                                                 ;memcpy(&apuRAMBuf, &ESI, ECX*4)
    Rep     MovSD

    Lea     RAX,[rel dspVarEP]                                                  ;ECX = Variable size of DSP.asm
    Lea     RCX,[rel mix]
    Sub     RAX,RCX
    Mov     ECX,EAX
    ShR     ECX,2
    Inc     ECX

    Lea     RDI,[rel mix]                                                       ;memcpy(&mix, &ESI, ECX*4)
    Rep     MovSD

    Lea     RAX,[rel spcVarEP]                                                  ;ECX = Variable size of SPC700.asm
    Lea     RCX,[rel extraRAM]
    Sub     RAX,RCX
    Mov     ECX,EAX
    ShR     ECX,2
    Inc     ECX

    Lea     RDI,[rel extraRAM]                                                  ;memcpy(&extraRAM, &ESI, ECX*4)
    Rep     MovSD

    XOr     EAX,EAX

ENDP
