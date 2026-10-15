/* gsp_internal.h - private declarations of the in-process recording agent.

   The agent (libgsperf.so) is loaded into the target with LD_PRELOAD by the
   recorder, or linked directly by programs that emit signposts.  It records
   only when GSP_OUTPUT names a trace bundle in the environment at startup.

   Concurrency model
   - Every traced thread owns two single-producer rings: one written only
     from signal handlers (samples), one only from normal code (allocations,
     signposts, definitions).  A handler that interrupts normal code writes
     to the other ring, so a ring never has two producers.
   - One internal writer thread drains all rings into the event file and
     owns the file descriptor.  It also performs leak scans and finalization.
   - Signal handlers never take locks or allocate.  */

#ifndef GSP_INTERNAL_H
#define GSP_INTERNAL_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <ucontext.h>
#include <sys/types.h>

#include "GSPerformance/gsp_format.h"

#define GSP_EXPORT __attribute__((visibility("default")))
#define GSP_HIDDEN __attribute__((visibility("hidden")))
#define GSP_TLS __thread __attribute__((tls_model("initial-exec")))

#define GSP_MAX_THREADS 4096
#define GSP_MAX_FRAMES 128
#define GSP_RING_NORMAL (1u << 20)
#define GSP_RING_SIGNAL (256u << 10)

/* ---- configuration (read once from the environment) ---- */

typedef struct gsp_config
{
  char output[1024];          /* trace bundle directory */
  bool cpu_sampling;
  bool wall_sampling_main;    /* main-thread wall clock samples (Hangs) */
  bool allocations;
  bool refcounts;
  bool leaks;
  bool signposts;
  bool zombies;
  bool unwind_fp;             /* force frame-pointer unwinding */
  unsigned sample_interval_us;
  unsigned wall_interval_us;
  unsigned leak_interval_s;   /* 0 = only at the end of recording */
  unsigned max_frames;
  unsigned alloc_frames;
  int control_signal;
} gsp_config;

GSP_HIDDEN extern gsp_config gsp_cfg;

/* Signals used by the agent. */
#define GSP_SIG_CPU SIGPROF
#define GSP_SIG_WALL (SIGRTMIN + 3)
#define GSP_SIG_SUSPEND (SIGRTMIN + 4)
#define GSP_SIG_CONTROL_DEFAULT (SIGRTMIN + 5)

/* Control requests carried in sigqueue()'s value. */
enum { GSP_CTL_STOP = 1, GSP_CTL_LEAK_SNAPSHOT = 2, GSP_CTL_MARK = 3 };

/* ---- global state ---- */

GSP_HIDDEN extern atomic_int gsp_recording;  /* events are being collected */
GSP_HIDDEN extern atomic_int gsp_alloc_on;   /* allocation hooks record */
GSP_HIDDEN extern uintptr_t gsp_agent_text_lo, gsp_agent_text_hi;
GSP_HIDDEN extern uintptr_t gsp_writer_stack_lo, gsp_writer_stack_hi;

/* ---- rings ---- */

typedef struct gsp_ring
{
  uint8_t *buf;
  uint32_t cap;          /* power of two */
  _Atomic uint64_t head; /* producer position */
  _Atomic uint64_t tail; /* consumer position */
} gsp_ring;

/* ---- threads ---- */

enum
{
  GSP_SLOT_FREE = 0,
  GSP_SLOT_ACTIVE = 1,
  GSP_SLOT_EXITED = 2,   /* drain once more, then retire */
  GSP_SLOT_RETIRED = 3
};

typedef struct gsp_thread
{
  atomic_int state;
  pid_t tid;
  unsigned flags;              /* GSP_THREAD_* */
  gsp_ring ring_signal;
  gsp_ring ring_normal;
  uintptr_t stack_lo, stack_hi;
  timer_t cpu_timer;
  timer_t wall_timer;
  bool has_cpu_timer, has_wall_timer;
  volatile sig_atomic_t in_unwind;  /* normal-context libunwind in progress */
  uint64_t dropped_signal;          /* written by the owner only */
  /* stop-the-world state */
  atomic_int suspended;
  uintptr_t saved_sp;
  uintptr_t saved_fs;
  uint64_t saved_regs[NGREG];
} gsp_thread;

GSP_HIDDEN extern gsp_thread *gsp_threads[GSP_MAX_THREADS];
GSP_HIDDEN extern atomic_int gsp_thread_count;
GSP_HIDDEN extern GSP_TLS gsp_thread *gsp_self_thread;
GSP_HIDDEN extern GSP_TLS int gsp_in_agent;   /* reentrancy guard */
GSP_HIDDEN extern GSP_TLS int gsp_is_internal;

GSP_HIDDEN gsp_thread *gsp_thread_current(void); /* registers lazily */
GSP_HIDDEN void gsp_thread_start_timers(gsp_thread *t);
GSP_HIDDEN void gsp_thread_finish(gsp_thread *t);

/* ---- clock ---- */

static inline uint64_t
gsp_now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

GSP_HIDDEN pid_t gsp_gettid(void);

/* ---- emitting records ----
   gsp_emit_normal may block briefly when the ring is full; gsp_emit_signal
   drops and counts instead.  Both take up to two payload pieces.  */

GSP_HIDDEN bool gsp_emit_normal(gsp_thread *t, uint16_t type, uint32_t aux,
                                uint16_t flags, uint64_t time,
                                const void *a, size_t alen,
                                const void *b, size_t blen);
GSP_HIDDEN bool gsp_emit_signal(gsp_thread *t, uint16_t type, uint32_t aux,
                                uint16_t flags, uint64_t time,
                                const void *a, size_t alen,
                                const void *b, size_t blen);

/* Writer-thread-only direct output (bypasses rings). */
GSP_HIDDEN void gsp_writer_emit(uint16_t type, uint32_t aux, uint64_t time,
                                uint32_t tid, const void *a, size_t alen,
                                const void *b, size_t blen);
GSP_HIDDEN void gsp_writer_wake(void);

/* ---- interning (normal context only) ---- */

GSP_HIDDEN uint32_t gsp_intern_string(const char *s);
GSP_HIDDEN uint32_t gsp_intern_stack(const uint64_t *frames, unsigned n);

/* ---- raw memory ---- */

GSP_HIDDEN void *gsp_map(size_t size);       /* zeroed, page aligned */
GSP_HIDDEN void gsp_unmap(void *p, size_t size);
GSP_HIDDEN void *gsp_arena_alloc(size_t size); /* never freed */
GSP_HIDDEN bool gsp_is_agent_memory(uintptr_t lo, uintptr_t hi);
/* Copies the agent's own mmap ranges (rings, tables); returns the count. */
GSP_HIDDEN int gsp_agent_mappings(uintptr_t (*out)[2], int max);

/* ---- unwinding ---- */

GSP_HIDDEN void gsp_unwind_init(void);
GSP_HIDDEN unsigned gsp_unwind_signal(gsp_thread *t, void *ucontext,
                                      uint64_t *frames, unsigned max);
GSP_HIDDEN unsigned gsp_unwind_here(gsp_thread *t, uint64_t *frames,
                                    unsigned max);
GSP_HIDDEN uint32_t gsp_current_stack_id(gsp_thread *t);

/* ---- subsystems ---- */

GSP_HIDDEN void gsp_sampler_init(void);
GSP_HIDDEN void gsp_sampler_stop(void);
GSP_HIDDEN void gsp_images_emit_new(gsp_thread *t);
GSP_HIDDEN void gsp_images_emit_new_writer(void);
GSP_HIDDEN bool gsp_images_changed(void);   /* writer only */
GSP_HIDDEN bool gsp_loader_busy(void);      /* async-signal-safe */
GSP_HIDDEN void gsp_alloc_init(void);
GSP_HIDDEN void gsp_alloc_tag(void *address, uint32_t class_name);
GSP_HIDDEN void gsp_alloc_stop_live(void);
GSP_HIDDEN void gsp_objc_poll(void);         /* writer: install hooks once */
GSP_HIDDEN void gsp_objc_dump_methods(void); /* writer: method table */
GSP_HIDDEN void gsp_leaks_init(void);
GSP_HIDDEN void gsp_leaks_snapshot(void);    /* writer thread */
GSP_HIDDEN void gsp_signpost_init(void);

/* live block table, used by allocations and leaks */
typedef struct gsp_block
{
  uint64_t address;
  uint64_t size;
  uint32_t stack;
  uint32_t class_name;
} gsp_block;

GSP_HIDDEN void gsp_live_lock(void);
GSP_HIDDEN void gsp_live_unlock(void);
/* Calls fn for every live block; caller holds the live lock. */
GSP_HIDDEN void gsp_live_foreach(void (*fn)(const gsp_block *, void *),
                                 void *ctx);
GSP_HIDDEN uint64_t gsp_live_count(void);

/* real functions resolved with dlsym(RTLD_NEXT) */
GSP_HIDDEN extern int (*gsp_real_pthread_create)(pthread_t *,
                                                 const pthread_attr_t *,
                                                 void *(*)(void *), void *);

#endif
