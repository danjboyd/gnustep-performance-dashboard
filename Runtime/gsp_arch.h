/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Linux register and thread-pointer access. No allocation or locking. */
#ifndef GSP_ARCH_H
#define GSP_ARCH_H

#include <stdint.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

#if defined(__aarch64__)
/* Conservative glibc pthread descriptor bound below TP. May retain up to
   roughly 1.7 KiB of stale exited-thread stack as roots; not an ABI size. */
# define GSP_AARCH64_PTHREAD_DESC_MAX 4096
# define GSP_SAVED_REG_COUNT 31
# define GSP_CONTEXT_REGS(uc) ((uc)->uc_mcontext.regs)
# define GSP_CONTEXT_PC(uc) ((uc)->uc_mcontext.pc)
# define GSP_CONTEXT_FP(uc) ((uc)->uc_mcontext.regs[29])
# define GSP_CONTEXT_SP(uc) ((uc)->uc_mcontext.sp)
#elif defined(__x86_64__)
# define GSP_SAVED_REG_COUNT NGREG
# define GSP_CONTEXT_REGS(uc) ((uc)->uc_mcontext.gregs)
# define GSP_CONTEXT_PC(uc) ((uc)->uc_mcontext.gregs[REG_RIP])
# define GSP_CONTEXT_FP(uc) ((uc)->uc_mcontext.gregs[REG_RBP])
# define GSP_CONTEXT_SP(uc) ((uc)->uc_mcontext.gregs[REG_RSP])
#else
# error "The Linux recording agent requires x86_64 or aarch64."
#endif

static inline uintptr_t
gsp_thread_pointer(void)
{
#if defined(__aarch64__)
  return (uintptr_t)__builtin_thread_pointer();
#else
  unsigned long base = 0;
  syscall(SYS_arch_prctl, 0x1003 /* ARCH_GET_FS */, &base);
  return (uintptr_t)base;
#endif
}

/* XPACLRI is HINT #7: safe as a NOP on pre-PAC CPUs, with no allocation,
   syscalls, locks or guessed virtual-address mask in a signal handler. */
static inline uintptr_t
gsp_strip_return_address(uintptr_t address)
{
#if defined(__aarch64__)
  register uintptr_t lr __asm__("x30") = address;
  __asm__ __volatile__("hint #7" : "+r" (lr));
  return lr;
#else
  return address;
#endif
}

#endif
