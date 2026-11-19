/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Native ABI smoke: compiled and executed by each Linux architecture job. */
#define GSP_TEST_VALIDATE_IP 1
#include "../../Runtime/gsp_unwind.c"
#if defined(__aarch64__)
#include <asm/hwcap.h>
#include <sys/auxv.h>
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* Link the actual walker in this fixture, without the preload constructor. */
static char last_diagnostic[160];
gsp_config gsp_cfg;
uintptr_t gsp_agent_text_lo, gsp_agent_text_hi;
void
gsp_writer_emit(uint16_t type, uint32_t aux, uint64_t time, uint32_t tid,
                const void *a, size_t alen, const void *b, size_t blen)
{
  (void)type; (void)aux; (void)time; (void)tid;
  (void)alen; (void)b; (void)blen;
  if (type == GSP_REC_DIAGNOSTIC)
    snprintf(last_diagnostic, sizeof(last_diagnostic), "%s", (const char *)a);
}
uint32_t
gsp_intern_stack(const uint64_t *frames, unsigned n)
{
  (void)frames; (void)n;
  return 0;
}

static void
check_frame_record(uintptr_t return_address)
{
  uintptr_t record[2] = { 0, return_address };
  uint64_t frames[3] = { 0 };
  gsp_thread thread = { 0 };
  thread.stack_lo = (uintptr_t)record;
  thread.stack_hi = (uintptr_t)(record + 2);
  assert(walk_frame_pointers(&thread, return_address, (uintptr_t)record,
                            (uintptr_t)record, frames, 3) == 2);
  assert(frames[0] == 0x12345000 && frames[1] == 0x12345000);
}

static int
fake_init(unw_cursor_buf *cursor, ucontext_t *uc, int flags)
{
  (void)cursor; (void)uc; (void)flags;
  return 0;
}
static int
fake_ip(unw_cursor_buf *cursor, int reg, uint64_t *ip)
{
  (void)cursor; (void)reg;
  *ip = UINT64_C(0x12345000); /* Not a mapped executable image. */
  return 0;
}
static int
unexpected_step(unw_cursor_buf *cursor)
{
  (void)cursor;
  assert(!"invalid IP must stop before another libunwind step");
  return 0;
}
static void
check_invalid_ip_fallback(void)
{
  gsp_unwind_refresh_images();
  assert(executable_ip((uintptr_t)&check_frame_record));
  uintptr_t record[2] = { 0, 0x12345000 };
  assert(!executable_ip((uintptr_t)record));
  assert(!executable_ip(0x12345000));
  /* An interrupted publisher must fail closed, without waiting for itself. */
  atomic_fetch_add(&exec_generation, 1);
  assert(!executable_ip((uintptr_t)&check_frame_record));
  atomic_fetch_add(&exec_generation, 1);
  ucontext_t uc = { 0 };
  GSP_CONTEXT_PC(&uc) = 0x12345000;
  GSP_CONTEXT_FP(&uc) = (uintptr_t)record;
  GSP_CONTEXT_SP(&uc) = (uintptr_t)record;
  gsp_thread thread = { 0 };
  thread.stack_lo = (uintptr_t)record;
  thread.stack_hi = (uintptr_t)(record + 2);
  uint64_t frames[3] = { 0 };
  have_libunwind = true;
  unw_init_local2_fn = fake_init;
  unw_get_reg_fn = fake_ip;
  unw_step_fn = unexpected_step;
  assert(gsp_unwind_signal(&thread, &uc, frames, 3) == 2);
  assert(frames[0] == 0x12345000 && frames[1] == 0x12345000);
  assert(atomic_load(&invalid_ip_fallbacks) == 1 && !thread.in_unwind);
  gsp_unwind_emit_stats();
  assert(strstr(last_diagnostic, "fallbacks: 1 "));
  have_libunwind = false;
  puts("PASS executable image ranges, interrupted publication, invalid-IP fallback and trace counter");
}

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
  check_frame_record(0x12345000);
  check_invalid_ip_fallback();
#if defined(__aarch64__)
  if (getauxval(AT_HWCAP) & HWCAP_PACA)
    {
      /* Linux user VA widths are <=52 bits: bit54 is an instruction PAC
         bit. Do not set the separate TBI tag or address sign bit. */
      check_frame_record(UINT64_C(0x0040000012345000));
      puts("PASS fake frame and initial LR with high instruction PAC bit");
    }
  else
    puts("SKIP synthetic PAC bits: XPACLRI is a NOP on this non-PAC CPU");
#else
  puts("SKIP ARM PAC instruction: native x86_64 test");
#endif
  puts("PASS native register roots, thread pointer and real frame walker");
  return 0;
}
