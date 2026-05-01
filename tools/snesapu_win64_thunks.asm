CPU X64
BITS 64
DEFAULT REL

SECTION .text ALIGN=16

%macro SAVE_NONVOL 0
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
%endmacro

%macro RESTORE_NONVOL 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
%endmacro

extern InitAPU
extern SetAPUOpt
extern SetAPUSmpClk
extern SetAPULength
extern SetDSPPitch
extern SetDSPStereo
extern SetDSPEFBCT
extern SetDSPAmp
extern SetDSPDbg
extern LoadSPCFile
extern EmuAPU
extern GetSPCRegs
extern trace_dsp_write_impl

global call_InitAPU
global call_SetAPUOpt
global call_SetAPUSmpClk
global call_SetAPULength
global call_SetDSPPitch
global call_SetDSPStereo
global call_SetDSPEFBCT
global call_SetDSPAmp
global call_SetDSPDbg
global call_LoadSPCFile
global call_EmuAPU
global call_GetSPCRegs
global trace_dsp_write_bridge

call_InitAPU:
    SAVE_NONVOL
    push rcx
    call InitAPU
    add rsp, 8
    RESTORE_NONVOL
    ret

call_SetAPUOpt:
    mov r10, [rsp + 40]
    mov r11, [rsp + 48]
    SAVE_NONVOL
    sub rsp, 8
    push r11
    push r10
    push r9
    push r8
    push rdx
    push rcx
    call SetAPUOpt
    add rsp, 56
    RESTORE_NONVOL
    ret

call_SetAPUSmpClk:
    SAVE_NONVOL
    push rcx
    call SetAPUSmpClk
    add rsp, 8
    RESTORE_NONVOL
    ret

call_SetAPULength:
    SAVE_NONVOL
    sub rsp, 8
    push rdx
    push rcx
    call SetAPULength
    add rsp, 24
    RESTORE_NONVOL
    ret

call_SetDSPPitch:
    SAVE_NONVOL
    push rcx
    call SetDSPPitch
    add rsp, 8
    RESTORE_NONVOL
    ret

call_SetDSPStereo:
    SAVE_NONVOL
    push rcx
    call SetDSPStereo
    add rsp, 8
    RESTORE_NONVOL
    ret

call_SetDSPEFBCT:
    SAVE_NONVOL
    movsxd rcx, ecx
    push rcx
    call SetDSPEFBCT
    add rsp, 8
    RESTORE_NONVOL
    ret

call_SetDSPAmp:
    SAVE_NONVOL
    push rcx
    call SetDSPAmp
    add rsp, 8
    RESTORE_NONVOL
    ret

call_SetDSPDbg:
    SAVE_NONVOL
    push rcx
    call SetDSPDbg
    add rsp, 8
    RESTORE_NONVOL
    ret

call_LoadSPCFile:
    SAVE_NONVOL
    push rcx
    call LoadSPCFile
    add rsp, 8
    RESTORE_NONVOL
    ret

call_EmuAPU:
    SAVE_NONVOL
    push r8
    push rdx
    push rcx
    call EmuAPU
    add rsp, 24
    RESTORE_NONVOL
    ret

call_GetSPCRegs:
    mov r10, [rsp + 40]
    mov r11, [rsp + 48]
    SAVE_NONVOL
    sub rsp, 8
    push r11
    push r10
    push r9
    push r8
    push rdx
    push rcx
    call GetSPCRegs
    add rsp, 56
    RESTORE_NONVOL
    ret

trace_dsp_write_bridge:
    mov rcx, [rsp + 8]
    movzx edx, byte [rsp + 16]
    mov rbx, rsp
    sub rsp, 40
    and rsp, -16
    call trace_dsp_write_impl
    mov rsp, rbx
    ret
