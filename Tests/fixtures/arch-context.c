/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Native ABI smoke: compiled and executed by each Linux architecture job. */
#include "../../Runtime/gsp_arch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static __thread uintptr_t tls_marker;

int
main(void)
{
  ucontext_t uc = { 0 };
  uint64_t roots[GSP_SAVED_REG_COUNT];
#if defined(__aarch64__)
  for (unsigned i = 0; i < GSP_SAVED_REG_COUNT; i++)
    uc.uc_mcontext.regs[i] = 0x1000 + i;
  uc.uc_mcontext.pc = 0xabcdef;
  uc.uc_mcontext.sp = 0x123456;
#elif defined(__x86_64__)
  for (unsigned i = 0; i < GSP_SAVED_REG_COUNT; i++)
    uc.uc_mcontext.gregs[i] = 0x1000 + i;
  uc.uc_mcontext.gregs[REG_RIP] = 0xabcdef;
  uc.uc_mcontext.gregs[REG_RSP] = 0x123456;
#endif
  assert(GSP_CONTEXT_PC(&uc) == 0xabcdef);
  assert(GSP_CONTEXT_SP(&uc) == 0x123456);
#if defined(__aarch64__)
  assert(GSP_CONTEXT_FP(&uc) == 0x1000 + 29);
#else
  assert(GSP_CONTEXT_FP(&uc) == 0x1000 + REG_RBP);
#endif
  memcpy(roots, GSP_CONTEXT_REGS(&uc), sizeof(roots));
  for (unsigned i = 0; i < GSP_SAVED_REG_COUNT; i++)
    {
      uint64_t expected = 0x1000 + i;
#if defined(__x86_64__)
      if (i == REG_RIP) expected = 0xabcdef;
      if (i == REG_RSP) expected = 0x123456;
#endif
      assert(roots[i] == expected);
    }
  /* Initial-exec TLS must be near a nonzero architecture thread pointer. */
  uintptr_t tp = gsp_thread_pointer();
  uintptr_t marker = (uintptr_t)&tls_marker;
  assert(tp != 0 && (tp > marker ? tp - marker : marker - tp) < (1u << 20));
  puts("PASS native register roots and thread pointer");
  return 0;
}
