/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* gsp_unwind.c - stack walking.

   DWARF unwinding uses libunwind, loaded with dlopen so the agent has no
   build-time dependency on its headers.  Frame-pointer walking is the
   fallback, and is what signal handlers use while the interrupted thread is
   itself inside libunwind (whose caches are not reentrant).  */

#include "gsp_internal.h"

#include <dlfcn.h>
#include <link.h>
#include <string.h>

/* libunwind (x86_64, local-only) ABI subset.  unw_cursor_t is 127 words;
   unw_context_t is ucontext_t on x86_64.  */
#define GSP_UNW_CURSOR_WORDS 160
#define GSP_UNW_REG_IP 16
#define GSP_UNW_INIT_SIGNAL_FRAME 1
#define GSP_UNW_CACHE_PER_THREAD 2

typedef struct { uint64_t opaque[GSP_UNW_CURSOR_WORDS]; } unw_cursor_buf;

static int (*unw_init_local2_fn)(unw_cursor_buf *, ucontext_t *, int);
static int (*unw_step_fn)(unw_cursor_buf *);
static int (*unw_get_reg_fn)(unw_cursor_buf *, int, uint64_t *);
static int (*unw_backtrace_fn)(void **, int);
static bool have_libunwind;

void
gsp_unwind_init(void)
{
  void *h;

  if (gsp_cfg.unwind_fp)
    goto limited;
  h = dlopen("libunwind.so.8", RTLD_NOW | RTLD_LOCAL);
  if (h == NULL)
    h = dlopen("libunwind.so", RTLD_NOW | RTLD_LOCAL);
  if (h == NULL)
    goto limited;
  unw_init_local2_fn = dlsym(h, "_ULx86_64_init_local2");
  unw_step_fn = dlsym(h, "_ULx86_64_step");
  unw_get_reg_fn = dlsym(h, "_ULx86_64_get_reg");
  unw_backtrace_fn = dlsym(h, "unw_backtrace");
  int (*set_policy)(void *, int) = dlsym(h, "_ULx86_64_set_caching_policy");
  void **space = dlsym(h, "_ULx86_64_local_addr_space");
  if (set_policy && space)
    set_policy(*space, GSP_UNW_CACHE_PER_THREAD);
  have_libunwind = unw_init_local2_fn && unw_step_fn && unw_get_reg_fn;
  if (have_libunwind)
    return;
limited:
  {
    /* Called before the writer thread starts, after the stream header. */
    const char *message = gsp_cfg.unwind_fp
      ? "Frame-pointer unwinding selected; stacks require frame pointers."
      : "Full stack unwinding unavailable: install libunwind; using frame pointers.";
    gsp_writer_emit(GSP_REC_DIAGNOSTIC, GSP_DIAGNOSTIC_UNWIND_LIMITED,
                    gsp_now(), 0, message, strlen(message) + 1, NULL, 0);
  }
}

/* libunwind calls dl_iterate_phdr, which takes the loader lock; while the
   loader is changing the link map a signal-context DWARF unwind could
   deadlock, so fall back to frame pointers then.  */
bool
gsp_loader_busy(void)
{
  return _r_debug.r_state != RT_CONSISTENT;
}

static inline bool
in_stack(gsp_thread *t, uintptr_t p, uintptr_t sp)
{
  if (t->stack_hi)
    return p >= sp && p + 16 <= t->stack_hi && p >= t->stack_lo;
  return p >= sp && p - sp < (64u << 20);
}

static unsigned
walk_frame_pointers(gsp_thread *t, uintptr_t pc, uintptr_t fp, uintptr_t sp,
                    uint64_t *frames, unsigned max)
{
  unsigned n = 0;

  if (max == 0)
    return 0;
  frames[n++] = pc;
  while (n < max && (fp & 7) == 0 && in_stack(t, fp, sp))
    {
      uintptr_t next = ((uintptr_t *)fp)[0];
      uintptr_t ret = ((uintptr_t *)fp)[1];
      if (ret < 4096)
        break;
      frames[n++] = ret;
      if (next <= fp)
        break;
      sp = fp;
      fp = next;
    }
  return n;
}

unsigned
gsp_unwind_signal(gsp_thread *t, void *ucontext, uint64_t *frames,
                  unsigned max)
{
  ucontext_t *uc = ucontext;
  uintptr_t pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
  uintptr_t fp = (uintptr_t)uc->uc_mcontext.gregs[REG_RBP];
  uintptr_t sp = (uintptr_t)uc->uc_mcontext.gregs[REG_RSP];

  if (have_libunwind && !t->in_unwind && !gsp_loader_busy())
    {
      unw_cursor_buf cursor;
      unsigned n = 0;

      t->in_unwind = 1;
      if (unw_init_local2_fn(&cursor, uc, GSP_UNW_INIT_SIGNAL_FRAME) == 0)
        {
          do
            {
              uint64_t ip;
              if (unw_get_reg_fn(&cursor, GSP_UNW_REG_IP, &ip) != 0 || ip == 0)
                break;
              frames[n++] = ip;
            }
          while (n < max && unw_step_fn(&cursor) > 0);
        }
      t->in_unwind = 0;
      if (n > 1)
        return n;
    }
  return walk_frame_pointers(t, pc, fp, sp, frames, max);
}

/* Unwind the calling thread, dropping the agent's own frames.  */
unsigned
gsp_unwind_here(gsp_thread *t, uint64_t *frames, unsigned max)
{
  void *raw[GSP_MAX_FRAMES + 8];
  int n = 0;
  unsigned out = 0;
  int i;

  if (max > GSP_MAX_FRAMES)
    max = GSP_MAX_FRAMES;
  if (have_libunwind && unw_backtrace_fn && t != NULL)
    {
      t->in_unwind = 1;
      n = unw_backtrace_fn(raw, (int)max + 8);
      t->in_unwind = 0;
    }
  else
    {
      uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
      uintptr_t sp = fp;
      uint64_t tmp[GSP_MAX_FRAMES + 8];
      gsp_thread dummy;

      if (t == NULL)
        {
          memset(&dummy, 0, sizeof(dummy));
          t = &dummy;
        }
      n = (int)walk_frame_pointers(t, (uintptr_t)__builtin_return_address(0),
                                   fp, sp, tmp, max + 8);
      for (i = 0; i < n; i++)
        raw[i] = (void *)(uintptr_t)tmp[i];
    }
  /* The walk starts inside libunwind, then the agent (unwinder, hook,
     interposed malloc).  Skip exactly that leading run: agent frames
     further down (e.g. the objc_alloc_init interposer) are real callers.  */
  int first = 0;
#define IN_AGENT(pc) ((uintptr_t)(pc) >= gsp_agent_text_lo && (uintptr_t)(pc) < gsp_agent_text_hi)
  while (first < n && first < 8 && !IN_AGENT(raw[first]))
    first++;
  if (first < n && IN_AGENT(raw[first]))
    {
      while (first < n && IN_AGENT(raw[first]))
        first++;
    }
  else
    first = 0;
#undef IN_AGENT
  for (i = first; i < n && out < max; i++)
    frames[out++] = (uintptr_t)raw[i];
  return out;
}

uint32_t
gsp_current_stack_id(gsp_thread *t)
{
  uint64_t frames[GSP_MAX_FRAMES];
  unsigned n = gsp_unwind_here(t, frames, gsp_cfg.alloc_frames);
  return gsp_intern_stack(frames, n);
}
