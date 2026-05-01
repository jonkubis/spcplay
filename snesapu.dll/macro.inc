;===================================================================================================
;Program:    TASM Like Macros for NASM
;Platform:   Intel 80386
;Programmer: Anti Resonance (Alpha-II Productions)
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
;                                                   Copyright (C) 2003 Alpha-II Productions
;                                                   Copyright (C) 2012 degrade-factory
;
;List of users and dates who/when modified this file:
;   - degrade-factory in 2012-11-24
;===================================================================================================

;The following defines affect the way some macros work:
;   INTERNAL effects the way PUBLIC works (see macro header for comments)
;   STDCALL mangles labels and cleans up the stack on returns
;   CDECL mangles labels

%ifidn __OUTPUT_FORMAT__,macho64
    %define HOST64 1
%elifidn __OUTPUT_FORMAT__,elf64
    %define HOST64 1
%elifidn __OUTPUT_FORMAT__,win64
    %define HOST64 1
%endif

%ifdef HOST64
    %define ARG_BYTES 8
    %define ARG_BASE 16
%else
    %define ARG_BYTES 4
    %define ARG_BASE 8
%endif

%define ST      ST0


;===================================================================================================
;Overloaded Instructions

;===================================================================================================
;Push
;
;Params:
;   List of values to be pushed onto the stack.  Values are pushed left to right.

%macro Push 1-*
    %rep %0
        %ifdef HOST64
            %ifidni %1,EAX
                push    rax
            %elifidni %1,EBX
                push    rbx
            %elifidni %1,ECX
                push    rcx
            %elifidni %1,EDX
                push    rdx
            %elifidni %1,ESI
                push    rsi
            %elifidni %1,EDI
                push    rdi
            %elifidni %1,EBP
                push    rbp
            %elifidni %1,ESP
                push    rsp
            %else
                push    %1
            %endif
        %else
            push    %1
        %endif
        %rotate 1
    %endrep
%endmacro


;===================================================================================================
;Pop
;
;Params:
;   List of values to be popped off the stack.  Values are popped left to right.

%macro Pop 1-*
    %rep %0
        %ifdef HOST64
            %ifidni %1,EAX
                pop     rax
            %elifidni %1,EBX
                pop     rbx
            %elifidni %1,ECX
                pop     rcx
            %elifidni %1,EDX
                pop     rdx
            %elifidni %1,ESI
                pop     rsi
            %elifidni %1,EDI
                pop     rdi
            %elifidni %1,EBP
                pop     rbp
            %elifidni %1,ESP
                pop     rsp
            %else
                pop     %1
            %endif
        %else
            pop     %1
        %endif
        %rotate 1
    %endrep
%endmacro


;===================================================================================================
;Call Procedure
;
;If STDCALL is defined, the procedure is assumed to clean up the stack.
;
;Params:
;   Function name followed by stack parameters.  All arguments are assumed to be dwords.

%macro Call 1-*
    %if %0>1
        %rep %0-1
            %rotate -1
            Push    %1
        %endrep
        %rotate -1
    %endif

    %ifdef HOST64
        %ifidni %1,EAX
            call    rax
        %elifidni %1,EBX
            call    rbx
        %elifidni %1,ECX
            call    rcx
        %elifidni %1,EDX
            call    rdx
        %elifidni %1,ESI
            call    rsi
        %elifidni %1,EDI
            call    rdi
        %elifidni %1,EBP
            call    rbp
        %else
            call    %1
        %endif
    %else
        call    %1
    %endif

    %if %0>1
        %ifndef STDCALL
            %ifdef HOST64
                Add     RSP,(%0*ARG_BYTES)-ARG_BYTES
            %else
                Add     ESP,(%0*ARG_BYTES)-ARG_BYTES
            %endif
        %endif
    %endif
%endmacro


;===================================================================================================
;Return from Procedure
;
;Ensures the stack frame will be cleaned up and any used registers restored
;
;Params (optional):
;   Value to return in EAX

%macro RetN 0-1
    %if %0
        Mov     EAX,%1
    %endif

    %ifdef %$paramsize
        Jmp     %$Done
    %elifdef %$uses
        Jmp     %$Done
    %else
        Ret
    %endif
%endmacro


;===================================================================================================
;Conditional Return from Procedure
;
;Ensures the stack frame will be cleaned up and any used registers restored
;
;Params (optional):
;   Value to return in EAX

%macro RetZ 0-1
    %if %0
        Mov     EAX,%1
    %endif

    JZ      short %$Done
%endmacro


%macro RetZF 0-1
    %if %0
        Mov     EAX,%1
    %endif

    JZ      %$Done
%endmacro


%macro RetNZ 0-1
    %if %0
        Mov     EAX,%1
    %endif

    JNZ     short %$Done
%endmacro


%macro RetNZF 0-1
    %if %0
        Mov     EAX,%1
    %endif

    JNZ     %$Done
%endmacro


;===================================================================================================
;Procedure Macros

;===================================================================================================
;Publicly Declare a Label
;
;If INTERNAL is defined, the label is declared as GLOBAL, otherwise EXTERN.
;If STDCALL is defined, the label has an underscore prepended and an 'at' with the size of the
; argument stack appended.
;If CDECL is defined, the label has an underscore prepended.
;
;Params:
;   The variable or procedure name.  Procedures must be followed by a list of arguments.  If a
;   procedure has no arguments, specify 'NULL'.

%macro PUBLIC 1-*
    %ifdef  STDCALL
        %if %0==1
            %xdefine    PUBNAME _%1
        %elif %0==2
            %ifidni %2,NULL
                %xdefine    PUBNAME _%1@0
            %else
                %xdefine    PUBNAME _%1@4
            %endif
        %elif %0==3
            %xdefine    PUBNAME _%1@8
        %elif %0==4
            %xdefine    PUBNAME _%1@12
        %elif %0==5
            %xdefine    PUBNAME _%1@16
        %elif %0==6
            %xdefine    PUBNAME _%1@20
        %elif %0==7
            %xdefine    PUBNAME _%1@24
        %elif %0==8
            %xdefine    PUBNAME _%1@28
        %elif %0==9
            %xdefine    PUBNAME _%1@32
        %elif
            %error  "PUBLIC :: Procedures can't have more than 8 arguments"
        %endif
        %ifdef  INTERNAL
            GLOBAL  PUBNAME
        %else
            EXTERN  PUBNAME
        %endif
        %xdefine    %1  PUBNAME
    %elifdef    CDECL
        %ifdef  INTERNAL
            GLOBAL  _%1
        %else
            EXTERN  _%1
        %endif
        %xdefine    %1  _%1
    %elifidn __OUTPUT_FORMAT__,macho64
        %ifdef  INTERNAL
            GLOBAL  _%1
        %else
            EXTERN  _%1
        %endif
        %xdefine    %1  _%1
    %else
        %ifdef  INTERNAL
            GLOBAL  %1
        %else
            EXTERN  %1
        %endif
    %endif
%endmacro


;===================================================================================================
;Define Procedure
;
;Used to begin a procedure definition (body).  Defines a label, creates the initial stack frame, and
;generates offsets for any arguments.  Arguments are assumed to be 32-bit and passed right to left.
;
;Params:
;   Procedure name followed by a list of arguments passed on the stack

%macro PROC 1-*
    ALIGN   16                                                                  ;Align entry point on a cache line boundary
    %1:                                                                         ;Define procedure label

    %push PROC                                                                  ;Save context

    %if %0>9
        %error  "PROC :: Procedures can't have more than 8 arguments"
    %endif

    %if %0>1                                                                    ;Does this procedure have any arguments?
        %ifdef HOST64
            Push    EBP                                                         ;Create a frame pointer
            Mov     RBP,RSP
        %else
            Push    EBP                                                         ;Create a frame pointer
            Mov     EBP,ESP
        %endif

        %assign %$paramsize (%0*ARG_BYTES)-ARG_BYTES                            ;Save the size of the frame

        %if %0>=2                                                               ;Create pointers to each argument
            %ifidn HOST64,HOST64
            %endif
            %ifdef HOST64
                %define %2  RBP+ARG_BASE
            %else
                %define %2  EBP+ARG_BASE
            %endif

        %if %0>=3
            %ifdef HOST64
                %define %3  RBP+24
            %else
                %define %3  EBP+12
            %endif

        %if %0>=4
            %ifdef HOST64
                %define %4  RBP+32
            %else
                %define %4  EBP+16
            %endif

        %if %0>=5
            %ifdef HOST64
                %define %5  RBP+40
            %else
                %define %5  EBP+20
            %endif

        %if %0>=6
            %ifdef HOST64
                %define %6  RBP+48
            %else
                %define %6  EBP+24
            %endif

        %if %0>=7
            %ifdef HOST64
                %define %7  RBP+56
            %else
                %define %7  EBP+28
            %endif

        %if %0>=8
            %ifdef HOST64
                %define %8  RBP+64
            %else
                %define %8  EBP+32
            %endif

        %if %0>=9
            %ifdef HOST64
                %define %9  RBP+72
            %else
                %define %9  EBP+36
            %endif

        %endif
        %endif
        %endif
        %endif
        %endif
        %endif
        %endif
        %endif
    %endif
%endmacro


;===================================================================================================
;Define Local Variables
;
;Defines a list of local variables to be temporarily allocated on the stack
;
;Params:
;   Variable names (each var is allocated 32-bits)

%macro LOCALS 1-4
    %assign %$localsize %0*ARG_BYTES                                            ;Save the size of the local variables

    %ifndef %$paramsize                                                         ;If a stack frame hasn't been created, create one
        %assign %$paramsize 0                                                   ;No arguments
        Push    EBP
        %ifdef HOST64
            Mov     RBP,RSP
        %else
            Mov     EBP,ESP
        %endif
    %endif

    %if %0>4
        %error  "LOCALS :: Procedures can't have more than 4 local variables"
    %endif

    %if %0>=1                                                                   ;Create pointers to each of the locals
        %ifdef HOST64
            %define %1  RBP-8
        %else
            %define %1  EBP-4
        %endif

    %if %0>=2
        %ifdef HOST64
            %define %2  RBP-16
        %else
            %define %2  EBP-8
        %endif

    %if %0>=3
        %ifdef HOST64
            %define %3  RBP-24
        %else
            %define %3  EBP-12
        %endif

    %if %0>=4
        %ifdef HOST64
            %define %4  RBP-32
        %else
            %define %4  EBP-16
        %endif

    %endif
    %endif
    %endif
    %endif

    %ifdef HOST64
        Sub     RSP,%$localsize                                                 ;Allocate space on the stack
    %else
        Sub     ESP,%$localsize                                                 ;Allocate space on the stack
    %endif
%endmacro


;===================================================================================================
;Registers Used by Procedure
;
;Pushes registers onto the stack, then restores them at the end of the procedure.  EAX is assumed
;to contain the return value.  EBP and ESP must be saved manually, if no stack frame is used.
;
;Params:
;   Registers used by the procedure (EBX, ECX, EDX, ESI, and EDI, or ALL to save all five)

%macro USES 1-5
    %ifidni %1,ALL
        Push    ECX,EDX,EBX,ESI,EDI
        %assign %$uses 5
        %assign %$ECX 0
        %assign %$EDX 1
        %assign %$EBX 2
        %assign %$ESI 3
        %assign %$EDI 4
    %else
        %assign %$uses  0
        %rep    %0
            %ifidni %1,ECX                                                      ;Does parameter == "ECX"?
                %assign %$ECX %$uses                                            ;Define "$ECX" as the current push position
                Push    ECX                                                     ;Push ECX
            %elifidni %1,EDX
                %assign %$EDX %$uses
                Push    EDX
            %elifidni %1,EBX
                %assign %$EBX %$uses
                Push    EBX
            %elifidni %1,ESI
                %assign %$ESI %$uses
                Push    ESI
            %elifidni %1,EDI
                %assign %$EDI %$uses
                Push    EDI
            %else
                %error  "USES only accepts EBX, ECX, EDX, ESI, EDI, or ALL"
            %endif

            %rotate 1
            %assign %$uses %$uses+1
        %endrep
    %endif

%endmacro


;===================================================================================================
;End Procedure Definition
;
;Ends a procedure definition.  Restores any used registers, cleans up the stack frame, and pops the
;context stack.  Also pops any arguments off the stack if STDCALL is defined.

%macro ENDP 0
    %$Done:

    %assign %$i 4
    %rep 5
        %ifdef %$ECX                                                            ;Is "$ECX" defined?
            %if %$ECX==%$i                                                      ;Does it equal the current pop position?
                Pop     ECX
            %endif
        %endif

        %ifdef %$EDX
            %if %$EDX==%$i
                Pop     EDX
            %endif
        %endif

        %ifdef %$EBX
            %if %$EBX==%$i
                Pop     EBX
            %endif
        %endif

        %ifdef %$ESI
            %if %$ESI==%$i
                Pop     ESI
            %endif
        %endif

        %ifdef %$EDI
            %if %$EDI==%$i
                Pop     EDI
            %endif
        %endif

        %assign %$i %$i-1
    %endrep

    %ifdef %$paramsize
        Leave

        %if %$paramsize>0
            %ifdef STDCALL
                Ret     %$paramsize
            %else
                Ret
            %endif
        %else
            Ret
        %endif
    %else
        Ret
    %endif

    %pop
%endmacro


;===================================================================================================
;Creating Floating Point Powers of 2

%macro Scale32 2                                                                ;Single
    %1  DD  (127+(%2)) << 23
%endmacro

%macro Scale64 2                                                                ;Double
    %1  DD  0,(1023+(%2)) << 20
%endmacro

%macro Scale80 2                                                                ;Extended
    %1  DD  0,80000000h
        DW      16383+(%2)
%endmacro
