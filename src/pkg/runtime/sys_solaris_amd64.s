// Copyright 2013 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// System calls and other sys.stuff for AMD64, SunOS
// /usr/include/sys/syscall.h for syscall numbers.
//

#include "zasm_GOOS_GOARCH.h"
#include "../../cmd/ld/textflag.h"

// This is needed by asm_amd64.s
TEXT runtime·settls(SB),NOSPLIT,$8
	RET

// void libc·miniterrno(void *(*___errno)(void));
//
// Set the TLS errno pointer in M.
//
// Called using runtime·asmcgocall from os_solaris.c:/minit.
TEXT runtime·miniterrno(SB),NOSPLIT,$0
	// asmcgocall will put first argument into DI.
	CALL	DI	// SysV ABI so returns in AX
	get_tls(CX)
	MOVQ	m(CX), BX
	MOVQ	AX,	m_perrno(BX)
	RET

// int64 runtime·nanotime1(void);
//
// clock_gettime(3c) wrapper because Timespec is too large for
// runtime·nanotime stack.
//
// Called using runtime·sysvicall6 from os_solaris.c:/nanotime.
TEXT runtime·nanotime1(SB),NOSPLIT,$0
	// need space for the timespec argument.
	SUBQ	$64, SP	// 16 bytes will do, but who knows in the future?
	MOVQ	$3, DI	// CLOCK_REALTIME from <sys/time_impl.h>
	MOVQ	SP, SI
	MOVQ	libc·clock_gettime(SB), AX
	CALL	AX
	MOVQ	(SP), AX	// tv_sec from struct timespec
	IMULQ	$1000000000, AX	// multiply into nanoseconds
	ADDQ	8(SP), AX	// tv_nsec, offset should be stable.
	ADDQ	$64, SP
	RET

// pipe(3c) wrapper that returns fds in AX, DX.
TEXT runtime·pipe1(SB),NOSPLIT,$0
	SUBQ	$16, SP // 8 bytes will do, but stack has to be 16-byte alligned
	MOVQ	SP, DI
	MOVQ	libc·pipe(SB), AX
	CALL	AX
	MOVL	0(SP), AX
	MOVL	4(SP), DX
	ADDQ	$16, SP
	RET

// Call a library function with SysV calling conventions.
// The called function can take a maximum of 6 INTEGER class arguments,
// see 
//   Michael Matz, Jan Hubicka, Andreas Jaeger, and Mark Mitchell
//   System V Application Binary Interface 
//   AMD64 Architecture Processor Supplement
// section 3.2.3.
//
// Called by runtime·asmcgocall or runtime·cgocall.
TEXT runtime·asmsysvicall6(SB),NOSPLIT,$0
	// asmcgocall will put first argument into DI.
	PUSHQ	DI			// save for later
	MOVQ	libcall_fn(DI), AX
	MOVQ	libcall_args(DI), R11
	MOVQ	libcall_n(DI), R10

	get_tls(CX)
	MOVQ	m(CX), BX
	MOVQ	m_perrno(BX), DX
	CMPQ	DX, $0
	JEQ	skiperrno1
	MOVL	$0, 0(DX)

skiperrno1:
	CMPQ	R11, $0
	JEQ	skipargs
	// Load 6 args into correspondent registers.
	MOVQ	0(R11), DI
	MOVQ	8(R11), SI
	MOVQ	16(R11), DX
	MOVQ	24(R11), CX
	MOVQ	32(R11), R8
	MOVQ	40(R11), R9
skipargs:

	// Call SysV function
	CALL	AX

	// Return result
	POPQ	DI
	MOVQ	AX, libcall_r1(DI)
	MOVQ	DX, libcall_r2(DI)

	get_tls(CX)
	MOVQ	m(CX), BX
	MOVQ	m_perrno(BX), AX
	CMPQ	AX, $0
	JEQ	skiperrno2
	MOVL	0(AX), AX
	MOVQ	AX, libcall_err(DI)

skiperrno2:	
	RET

// uint32 tstart_sysvicall(M *newm);
TEXT runtime·tstart_sysvicall(SB),NOSPLIT,$0
	// DI contains first arg newm
	MOVQ	m_g0(DI), DX		// g

	// Make TLS entries point at g and m.
	get_tls(BX)
	MOVQ	DX, g(BX)
	MOVQ	DI, m(BX)

	// Layout new m scheduler stack on os stack.
	MOVQ	SP, AX
	MOVQ	AX, g_stackbase(DX)
	SUBQ	$(0x100000), AX		// stack size
	MOVQ	AX, g_stackguard(DX)
	MOVQ	AX, g_stackguard0(DX)

	// Someday the convention will be D is always cleared.
	CLD

	CALL	runtime·stackcheck(SB)	// clobbers AX,CX
	CALL	runtime·mstart(SB)

	XORL	AX, AX			// return 0 == success
	RET

// Careful, this is called by __sighndlr, a libc function. We must preserve
// registers as per AMD 64 ABI.
TEXT runtime·sigtramp(SB),NOSPLIT,$0
	// Note that we are executing on altsigstack here, so we have
	// more stack available than NOSPLIT would have us believe.
	// To defeat the linker, we make our own stack frame with
	// more space:
	SUBQ    $184, SP

	// save registers
	MOVQ    BX, 32(SP)
	MOVQ    BP, 40(SP)
	MOVQ	R12, 48(SP)
	MOVQ	R13, 56(SP)
	MOVQ	R14, 64(SP)
	MOVQ	R15, 72(SP)

	get_tls(BX)
	// check that m exists
	MOVQ	m(BX), BP
	CMPQ	BP, $0
	JNE	allgood
	MOVQ	DI, 0(SP)
	MOVQ	$runtime·badsignal(SB), AX
	CALL	AX
	RET

allgood:
	// save g
	MOVQ	g(BX), R10
	MOVQ	R10, 80(SP)

	// Save m->libcall and m->scratch. We need to do this because we
	// might get interrupted by a signal in runtime·asmcgocall.

	// save m->libcall 
	LEAQ	m_libcall(BP), R11
	MOVQ	libcall_fn(R11), R10
	MOVQ	R10, 88(SP)
	MOVQ	libcall_args(R11), R10
	MOVQ	R10, 96(SP)
	MOVQ	libcall_n(R11), R10
	MOVQ	R10, 104(SP)
	MOVQ    libcall_r1(R11), R10
	MOVQ    R10, 168(SP)
	MOVQ    libcall_r2(R11), R10
	MOVQ    R10, 176(SP)

	// save m->scratch
	LEAQ	m_scratch(BP), R11
	MOVQ	0(R11), R10
	MOVQ	R10, 112(SP)
	MOVQ	8(R11), R10
	MOVQ	R10, 120(SP)
	MOVQ	16(R11), R10
	MOVQ	R10, 128(SP)
	MOVQ	24(R11), R10
	MOVQ	R10, 136(SP)
	MOVQ	32(R11), R10
	MOVQ	R10, 144(SP)
	MOVQ	40(R11), R10
	MOVQ	R10, 152(SP)

	// save errno, it might be EINTR; stuff we do here might reset it.
	MOVQ	m_perrno(BP), R10
	MOVL	0(R10), R10
	MOVQ	R10, 160(SP)

	MOVQ	g(BX), R10
	// g = m->gsignal
	MOVQ	m_gsignal(BP), BP
	MOVQ	BP, g(BX)

	// prepare call
	MOVQ	DI, 0(SP)
	MOVQ	SI, 8(SP)
	MOVQ	DX, 16(SP)
	MOVQ	R10, 24(SP)
	CALL	runtime·sighandler(SB)

	get_tls(BX)
	MOVQ	m(BX), BP
	// restore libcall
	LEAQ	m_libcall(BP), R11
	MOVQ	88(SP), R10
	MOVQ	R10, libcall_fn(R11)
	MOVQ	96(SP), R10
	MOVQ	R10, libcall_args(R11)
	MOVQ	104(SP), R10
	MOVQ	R10, libcall_n(R11)
	MOVQ    168(SP), R10
	MOVQ    R10, libcall_r1(R11)
	MOVQ    176(SP), R10
	MOVQ    R10, libcall_r2(R11)

	// restore scratch
	LEAQ	m_scratch(BP), R11
	MOVQ	112(SP), R10
	MOVQ	R10, 0(R11)
	MOVQ	120(SP), R10
	MOVQ	R10, 8(R11)
	MOVQ	128(SP), R10
	MOVQ	R10, 16(R11)
	MOVQ	136(SP), R10
	MOVQ	R10, 24(R11)
	MOVQ	144(SP), R10
	MOVQ	R10, 32(R11)
	MOVQ	152(SP), R10
	MOVQ	R10, 40(R11)

	// restore errno
	MOVQ	m_perrno(BP), R11
	MOVQ	160(SP), R10
	MOVL	R10, 0(R11)

	// restore g
	MOVQ	80(SP), R10
	MOVQ	R10, g(BX)

	// restore registers
	MOVQ	32(SP), BX
	MOVQ	40(SP), BP
	MOVQ	48(SP), R12
	MOVQ	56(SP), R13
	MOVQ	64(SP), R14
	MOVQ	72(SP), R15

	ADDQ    $184, SP
	RET
