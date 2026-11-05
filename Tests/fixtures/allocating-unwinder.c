/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Controlled libunwind ABI fixture. The allocation mode rejects recursive
   unwinding with Exit86, independently of the GUI crash. The bad-FP mode
   exercises the invalid frame-pointer candidate identified in the GUI core. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
#include <ucontext.h>
#include <sys/syscall.h>
#include <signal.h>

static _Thread_local int in_signal_cursor;
static _Thread_local int invalid_fp_signal;
static int allocate_in_signal;
void *_ULx86_64_local_addr_space;

__attribute__((constructor)) static void
fixture_init(void)
{
  allocate_in_signal = getenv("CONTROLLED_INVALID_FP") == NULL;
}

/* Armed after agent initialization. Present the bad frame-pointer candidate
   from the GUI core while the agent is collecting an allocation stack. */
void
controlled_invalid_fp_sample(int sig)
{
  invalid_fp_signal = sig;
}

int
_ULx86_64_set_caching_policy(void *space, int policy)
{
  (void)space;
  (void)policy;
  return 0;
}

int
unw_backtrace(void **frames, int count)
{
  if (invalid_fp_signal)
    {
      int sig = invalid_fp_signal;
      invalid_fp_signal = 0;
      long pid = getpid();
      long tid = syscall(SYS_gettid);
      long result;
      /* tgkill delivers on this thread before returning. Preserve RBP without
         touching the compiler's stack or red zone. The signal ucontext sees
         UINTPTR_MAX-15, exactly the overflowing candidate in the native core. */
      __asm__ volatile ("mov %%rbp, %%r8\n\t"
                        "mov $-16, %%rbp\n\t"
                        "syscall\n\t"
                        "mov %%r8, %%rbp"
                        : "=a" (result)
                        : "0" ((long)SYS_tgkill), "D" (pid), "S" (tid),
                          "d" ((long)sig)
                        : "r8", "rcx", "r11", "memory");
      if (result != 0)
        _exit(87);
      static const char message[] = "CONTROLLED_INVALID_FP_SAMPLE_RETURNED\n";
      syscall(SYS_write, STDERR_FILENO, message, sizeof(message) - 1);
    }
  if (in_signal_cursor)
    {
      static const char message[] = "CONTROLLED_REENTRANT_UNWINDER\n";
      syscall(SYS_write, STDERR_FILENO, message, sizeof(message) - 1);
      _exit(86);
    }
  if (count > 0)
    frames[0] = __builtin_return_address(0);
  return count > 0 ? 1 : 0;
}

int
_ULx86_64_init_local2(void *cursor, ucontext_t *context, int flags)
{
  void *(*volatile allocate)(size_t) = malloc;
  void (*volatile release)(void *) = free;
  if (allocate_in_signal)
    {
      in_signal_cursor = 1;
      void *block = allocate(7897);
      release(block);
      in_signal_cursor = 0;
    }
  ((uintptr_t *)cursor)[0] = context->uc_mcontext.gregs[REG_RIP];
  (void)flags;
  return 0;
}

int
_ULx86_64_get_reg(void *cursor, int reg, uint64_t *value)
{
  if (reg != 16)
    return -1;
  *value = ((uintptr_t *)cursor)[0];
  return 0;
}

int
_ULx86_64_step(void *cursor)
{
  (void)cursor;
  return 0;
}
