BITS 32

SECTION .text ALIGN=16

%macro SAVE_NONVOL 0
    push ebx
    push esi
    push edi
    push ebp
%endmacro

%macro RESTORE_NONVOL 0
    pop ebp
    pop edi
    pop esi
    pop ebx
%endmacro

extern _InitAPU@4
extern _SetAPUOpt@24
extern _SetAPUSmpClk@4
extern _SetAPULength@8
extern _SetDSPPitch@4
extern _SetDSPStereo@4
extern _SetDSPEFBCT@4
extern _SetDSPAmp@4
extern _SetDSPDbg@4
extern _LoadSPCFile@4
extern _EmuAPU@12
extern _GetSPCRegs@24

global _call_InitAPU@4
global _call_SetAPUOpt@24
global _call_SetAPUSmpClk@4
global _call_SetAPULength@8
global _call_SetDSPPitch@4
global _call_SetDSPStereo@4
global _call_SetDSPEFBCT@4
global _call_SetDSPAmp@4
global _call_SetDSPDbg@4
global _call_LoadSPCFile@4
global _call_EmuAPU@12
global _call_GetSPCRegs@24

_call_InitAPU@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _InitAPU@4
    RESTORE_NONVOL
    ret 4

_call_SetAPUOpt@24:
    SAVE_NONVOL
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    call _SetAPUOpt@24
    RESTORE_NONVOL
    ret 24

_call_SetAPUSmpClk@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _SetAPUSmpClk@4
    RESTORE_NONVOL
    ret 4

_call_SetAPULength@8:
    SAVE_NONVOL
    push dword [esp + 24]
    push dword [esp + 24]
    call _SetAPULength@8
    RESTORE_NONVOL
    ret 8

_call_SetDSPPitch@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _SetDSPPitch@4
    RESTORE_NONVOL
    ret 4

_call_SetDSPStereo@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _SetDSPStereo@4
    RESTORE_NONVOL
    ret 4

_call_SetDSPEFBCT@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _SetDSPEFBCT@4
    RESTORE_NONVOL
    ret 4

_call_SetDSPAmp@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _SetDSPAmp@4
    RESTORE_NONVOL
    ret 4

_call_SetDSPDbg@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _SetDSPDbg@4
    RESTORE_NONVOL
    ret 4

_call_LoadSPCFile@4:
    SAVE_NONVOL
    push dword [esp + 20]
    call _LoadSPCFile@4
    RESTORE_NONVOL
    ret 4

_call_EmuAPU@12:
    SAVE_NONVOL
    push dword [esp + 28]
    push dword [esp + 28]
    push dword [esp + 28]
    call _EmuAPU@12
    RESTORE_NONVOL
    ret 12

_call_GetSPCRegs@24:
    SAVE_NONVOL
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    push dword [esp + 40]
    call _GetSPCRegs@24
    RESTORE_NONVOL
    ret 24
