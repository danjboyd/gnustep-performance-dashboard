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
#include <stdio.h>

/* Local-only libunwind ABI (Linux libunwind 1.6+). The signal ucontext
   prefix is compatible on both architectures. Public cursors need 250
   words on AArch64 and 127 on x86_64; leave room for the current ABI. */
#if defined(__aarch64__)
#define GSP_UNW_CURSOR_WORDS 256
/* UNW_REG_IP is X30 (30), not UNW_AARCH64_PC (32): get_reg special-cases
   it to return the advancing cursor IP rather than a saved register slot. */
#define GSP_UNW_REG_IP 30
#define GSP_UNW_PREFIX "_ULaarch64_"
#elif defined(__x86_64__)
#define GSP_UNW_CURSOR_WORDS 160
#define GSP_UNW_REG_IP 16
#define GSP_UNW_PREFIX "_ULx86_64_"
#else
#error "The Linux recording agent requires x86_64 or aarch64."
#endif
#define GSP_UNW_INIT_SIGNAL_FRAME 1
#define GSP_UNW_CACHE_PER_THREAD 2

typedef struct { uint64_t opaque[GSP_UNW_CURSOR_WORDS]; } unw_cursor_buf;

static int (*unw_init_local2_fn)(unw_cursor_buf *, ucontext_t *, int);
static int (*unw_step_fn)(unw_cursor_buf *);
static int (*unw_get_reg_fn)(unw_cursor_buf *, int, uint64_t *);
static int (*unw_backtrace_fn)(void **, int);
static bool have_libunwind;

#if defined(__aarch64__) || defined(GSP_TEST_VALIDATE_IP)
#define GSP_VALIDATE_IP 1
#define GSP_EXEC_RANGES 4096
/* Fixed atomic slots avoid allocation, reader locks and reclamation hazards.
   A signal interrupting publication fails closed immediately; it never spins.
   All slots and generation use seq_cst to keep snapshot validation ordered. */
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "Signal-context executable range checks require lock-free atomics");
static _Atomic uintptr_t exec_ranges[GSP_EXEC_RANGES][2];
static atomic_uint exec_generation, exec_count;
static _Atomic uint64_t invalid_ip_fallbacks;

typedef struct exec_scan
{
  unsigned count;
  bool overflow;
} exec_scan;

static int
exec_image_cb(struct dl_phdr_info *pi, size_t size, void *data)
{
  exec_scan *scan = data;
  (void)size;
  for (unsigned i = 0; i < pi->dlpi_phnum; i++)
    {
      const ElfW(Phdr) *ph = &pi->dlpi_phdr[i];
      if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_X) || !ph->p_memsz)
        continue;
      uintptr_t lo = (uintptr_t)pi->dlpi_addr + ph->p_vaddr;
      if (scan->count == GSP_EXEC_RANGES || lo < (uintptr_t)pi->dlpi_addr
          || ph->p_memsz > UINTPTR_MAX - lo)
        {
          scan->overflow = true;
          return 1;
        }
      atomic_store(&exec_ranges[scan->count][0], lo);
      atomic_store(&exec_ranges[scan->count][1], lo + ph->p_memsz);
      scan->count++;
    }
  return 0;
}

void
gsp_unwind_refresh_images(void)
{
  exec_scan scan = { 0, false };
  /* Serialized by images_lock, or startup before the writer/timers exist. */
  atomic_fetch_add(&exec_generation, 1);
  dl_iterate_phdr(exec_image_cb, &scan);
  atomic_store(&exec_count, scan.overflow ? 0 : scan.count);
  atomic_fetch_add(&exec_generation, 1);
}

static bool
executable_ip(uintptr_t ip)
{
  unsigned generation = atomic_load(&exec_generation);
  if (generation & 1)
    return false;
  unsigned count = atomic_load(&exec_count);
  bool found = false;
  for (unsigned i = 0; i < count; i++)
    if (ip >= atomic_load(&exec_ranges[i][0])
        && ip < atomic_load(&exec_ranges[i][1]))
      {
        found = true;
        break;
      }
  return found && generation == atomic_load(&exec_generation);
}

void
gsp_unwind_emit_stats(void)
{
  uint64_t count = atomic_load(&invalid_ip_fallbacks);
  if (count)
    {
      char message[160];
      snprintf(message, sizeof(message),
               "Unwind executable-IP validation fallbacks: %llu (invalid IP or image snapshot unavailable).",
               (unsigned long long)count);
      gsp_writer_emit(GSP_REC_DIAGNOSTIC, GSP_DIAGNOSTIC_UNWIND_LIMITED,
                      gsp_now(), 0, message, strlen(message) + 1, NULL, 0);
    }
}
#else
void gsp_unwind_refresh_images(void) { }
void gsp_unwind_emit_stats(void) { }
#endif

/* Resolve in normal startup context, before sampling timers exist. A target
   executable can COPY-relocate _r_debug; that interposed copy is stale on
   older glibc. DT_DEBUG is filled by the loader with its authoritative object.
   The main executable is the first dl_iterate_phdr object, PIE or not. */
static struct r_debug *loader_debug = &_r_debug;

static int
find_loader_debug(struct dl_phdr_info *info, size_t size, void *opaque)
{
  (void)size;
  struct r_debug **result = opaque;
  for (ElfW(Half) i = 0; i < info->dlpi_phnum; i++)
    if (info->dlpi_phdr[i].p_type == PT_DYNAMIC)
      {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        const ElfW(Dyn) *dyn = (const void *)(info->dlpi_addr + ph->p_vaddr);
        size_t count = ph->p_memsz / sizeof(*dyn);
        for (size_t j = 0; j < count && dyn[j].d_tag != DT_NULL; j++)
          if (dyn[j].d_tag == DT_DEBUG && dyn[j].d_un.d_ptr)
            {
              *result = (struct r_debug *)(uintptr_t)dyn[j].d_un.d_ptr;
              return 1;
            }
      }
  return 1; /* Never inspect a DSO's dynamic table instead of the main one. */
}

static void
init_loader_debug(void)
{
  struct r_debug *debug = &_r_debug;
  dl_iterate_phdr(find_loader_debug, &debug);
  loader_debug = debug;
}

void
gsp_unwind_init(void)
{
  void *h;

  init_loader_debug();
  gsp_unwind_refresh_images();
  if (gsp_cfg.unwind_fp)
    goto limited;
  h = dlopen("libunwind.so.8", RTLD_NOW | RTLD_LOCAL);
  if (h == NULL)
    h = dlopen("libunwind.so", RTLD_NOW | RTLD_LOCAL);
  if (h == NULL)
    goto limited;
  unw_init_local2_fn = dlsym(h, GSP_UNW_PREFIX "init_local2");
  unw_step_fn = dlsym(h, GSP_UNW_PREFIX "step");
  unw_get_reg_fn = dlsym(h, GSP_UNW_PREFIX "get_reg");
  unw_backtrace_fn = dlsym(h, "unw_backtrace");
  int (*set_policy)(void *, int) = dlsym(h, GSP_UNW_PREFIX "set_caching_policy");
  void **space = dlsym(h, GSP_UNW_PREFIX "local_addr_space");
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
  return ((volatile struct r_debug *)loader_debug)->r_state != RT_CONSISTENT;
}

static inline bool
in_stack(gsp_thread *t, uintptr_t p, uintptr_t sp)
{
  /* Functions built without frame pointers can leave arbitrary chain values.
     Check the upper bound before subtracting: p + frame_size can wrap.  */
  if (t->stack_hi)
    return p >= sp && p >= t->stack_lo && p <= t->stack_hi
      && t->stack_hi - p >= 2 * sizeof(uintptr_t);
  return p >= sp && p - sp < (64u << 20);
}

static unsigned
walk_frame_pointers(gsp_thread *t, uintptr_t pc, uintptr_t fp, uintptr_t sp,
                    uint64_t *frames, unsigned max)
{
  unsigned n = 0;

  if (max == 0)
    return 0;
  frames[n++] = gsp_strip_return_address(pc);
  while (n < max && (fp & 7) == 0 && in_stack(t, fp, sp))
    {
      /* AAPCS64 and x86_64 both store [previous FP, return address]. */
      uintptr_t next = ((uintptr_t *)fp)[0];
      uintptr_t ret = gsp_strip_return_address(((uintptr_t *)fp)[1]);
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
  uintptr_t pc = (uintptr_t)GSP_CONTEXT_PC(uc);
  uintptr_t fp = (uintptr_t)GSP_CONTEXT_FP(uc);
  uintptr_t sp = (uintptr_t)GSP_CONTEXT_SP(uc);

  if (have_libunwind && !t->in_unwind && !gsp_loader_busy())
    {
      unw_cursor_buf cursor;
      unsigned n = 0;
      bool invalid_ip = false;

      t->in_unwind = 1;
      if (unw_init_local2_fn(&cursor, uc, GSP_UNW_INIT_SIGNAL_FRAME) == 0)
        {
          do
            {
              uint64_t ip;
              if (unw_get_reg_fn(&cursor, GSP_UNW_REG_IP, &ip) != 0 || ip == 0)
                break;
              ip = gsp_strip_return_address(ip);
#ifdef GSP_VALIDATE_IP
              if (!executable_ip(ip))
                {
                  invalid_ip = true;
                  atomic_fetch_add_explicit(&invalid_ip_fallbacks, 1, memory_order_relaxed);
                  break;
                }
#endif
              frames[n++] = ip;
            }
          while (n < max && unw_step_fn(&cursor) > 0);
        }
      t->in_unwind = 0;
      if (!invalid_ip && n > 1)
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
#ifdef GSP_VALIDATE_IP
      for (i = 0; i < n; i++)
        if (!executable_ip(gsp_strip_return_address((uintptr_t)raw[i])))
          {
            atomic_fetch_add_explicit(&invalid_ip_fallbacks, 1, memory_order_relaxed);
            n = 0;
            break;
          }
#endif
    }
  if (n <= 0)
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
  for (i = 0; i < n; i++)
    raw[i] = (void *)gsp_strip_return_address((uintptr_t)raw[i]);
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
