/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Controlled libunwind ABI fixture, not evidence of the GUI's crash cause.
   Allocate while initializing a signal cursor. A tracing hook must not re-enter
   the unwinder to record the unwinder's own allocation. Exit86 identifies that
   contract violation without manufacturing a real SIGSEGV. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
#include <ucontext.h>
#include <sys/syscall.h>

static _Thread_local int in_signal_cursor;
void *_ULx86_64_local_addr_space;

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
  in_signal_cursor = 1;
  void *block = allocate(7897);
  release(block);
  in_signal_cursor = 0;
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
