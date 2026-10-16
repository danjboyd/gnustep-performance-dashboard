/* gsp_runtime.c - agent lifecycle, rings, thread registry and writer.  */

#include "gsp_internal.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>

gsp_config gsp_cfg;
atomic_int gsp_recording;
atomic_int gsp_alloc_on;
uintptr_t gsp_agent_text_lo, gsp_agent_text_hi;
uintptr_t gsp_writer_stack_lo, gsp_writer_stack_hi;

gsp_thread *gsp_threads[GSP_MAX_THREADS];
atomic_int gsp_thread_count;
GSP_TLS gsp_thread *gsp_self_thread;
GSP_TLS int gsp_in_agent;
GSP_TLS int gsp_is_internal;
static GSP_TLS int thread_exiting;

int (*gsp_real_pthread_create)(pthread_t *, const pthread_attr_t *,
                               void *(*)(void *), void *);

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_key_t thread_key;
static int out_fd = -1;
static int wake_pipe[2] = { -1, -1 };
static pthread_t writer_thread;
static atomic_int writer_running;
static atomic_int stop_requested;
static atomic_int leak_requested;
static atomic_int mark_requested;
static atomic_int finished;
/* Set when the stop comes from a signal handler: the interrupted thread
   may hold any lock (the live table, the loader, libobjc), so the writer
   skips every finalisation step that takes one.  */
static atomic_int stop_from_signal;
static atomic_int gave_up_waiting;
static pid_t traced_pid;
static uint64_t start_ns;
static char events_path[1100];

pid_t
gsp_gettid(void)
{
  return (pid_t)syscall(SYS_gettid);
}

/* ------------------------------------------------------------------ */
/* raw memory                                                          */

#define GSP_MAX_MAPPINGS 16384
static struct { uintptr_t lo, hi; } mappings[GSP_MAX_MAPPINGS];
static atomic_int mapping_count;
static atomic_flag mapping_lock = ATOMIC_FLAG_INIT;

void *
gsp_map(size_t size)
{
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED)
    return NULL;
  while (atomic_flag_test_and_set_explicit(&mapping_lock, memory_order_acquire))
    ;
  int n = atomic_load(&mapping_count);
  if (n < GSP_MAX_MAPPINGS)
    {
      mappings[n].lo = (uintptr_t)p;
      mappings[n].hi = (uintptr_t)p + size;
      atomic_store(&mapping_count, n + 1);
    }
  atomic_flag_clear_explicit(&mapping_lock, memory_order_release);
  return p;
}

/* Raw mapping, not registered: for the writer while other threads are
   stopped (one of them may hold mapping_lock).  */
void *
gsp_map_raw(size_t size)
{
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return p == MAP_FAILED ? NULL : p;
}

void
gsp_unmap(void *p, size_t size)
{
  while (atomic_flag_test_and_set_explicit(&mapping_lock, memory_order_acquire))
    ;
  int n = atomic_load(&mapping_count);
  for (int i = 0; i < n; i++)
    if (mappings[i].lo == (uintptr_t)p)
      {
        mappings[i] = mappings[n - 1];
        atomic_store(&mapping_count, n - 1);
        break;
      }
  atomic_flag_clear_explicit(&mapping_lock, memory_order_release);
  munmap(p, size);
}

int
gsp_agent_mappings(uintptr_t (*out)[2], int max)
{
  int n = atomic_load(&mapping_count), k = 0;
  for (int i = 0; i < n && k < max; i++, k++)
    {
      out[k][0] = mappings[i].lo;
      out[k][1] = mappings[i].hi;
    }
  return k;
}

bool
gsp_is_agent_memory(uintptr_t lo, uintptr_t hi)
{
  int n = atomic_load(&mapping_count);
  for (int i = 0; i < n; i++)
    if (lo < mappings[i].hi && hi > mappings[i].lo)
      return true;
  return false;
}

#define ARENA_CHUNK (1u << 20)
static pthread_mutex_t arena_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *arena_cur;
static size_t arena_left;

void *
gsp_arena_alloc(size_t size)
{
  void *p;

  size = (size + 15) & ~(size_t)15;
  pthread_mutex_lock(&arena_lock);
  if (size > arena_left)
    {
      size_t chunk = size > ARENA_CHUNK ? size : ARENA_CHUNK;
      arena_cur = gsp_map(chunk);
      arena_left = arena_cur ? chunk : 0;
    }
  if (arena_cur == NULL || size > arena_left)
    {
      pthread_mutex_unlock(&arena_lock);
      return NULL;
    }
  p = arena_cur;
  arena_cur += size;
  arena_left -= size;
  pthread_mutex_unlock(&arena_lock);
  return p;
}

/* ------------------------------------------------------------------ */
/* configuration                                                       */

static bool
env_flag(const char *name, bool fallback)
{
  const char *v = getenv(name);
  if (v == NULL || *v == '\0')
    return fallback;
  return !(strcmp(v, "0") == 0 || strcasecmp(v, "no") == 0
           || strcasecmp(v, "false") == 0);
}

static unsigned
env_uint(const char *name, unsigned fallback)
{
  const char *v = getenv(name);
  if (v == NULL || *v == '\0')
    return fallback;
  return (unsigned)strtoul(v, NULL, 10);
}

static void
read_config(void)
{
  const char *out = getenv("GSP_OUTPUT");

  memset(&gsp_cfg, 0, sizeof(gsp_cfg));
  snprintf(gsp_cfg.output, sizeof(gsp_cfg.output), "%s", out ? out : "");
  gsp_cfg.cpu_sampling = env_flag("GSP_CPU_SAMPLING", true);
  gsp_cfg.wall_sampling_main = env_flag("GSP_WALL_SAMPLING", true);
  gsp_cfg.allocations = env_flag("GSP_ALLOCATIONS", false);
  gsp_cfg.leaks = env_flag("GSP_LEAKS", false);
  gsp_cfg.refcounts = env_flag("GSP_REFCOUNTS", false);
  gsp_cfg.signposts = env_flag("GSP_SIGNPOSTS", true);
  gsp_cfg.zombies = env_flag("GSP_ZOMBIES", false);
  gsp_cfg.unwind_fp = getenv("GSP_UNWIND") != NULL
    && strcmp(getenv("GSP_UNWIND"), "fp") == 0;
  gsp_cfg.sample_interval_us = env_uint("GSP_SAMPLE_INTERVAL_US", 1000);
  gsp_cfg.wall_interval_us = env_uint("GSP_WALL_INTERVAL_US", 10000);
  gsp_cfg.leak_interval_s = env_uint("GSP_LEAK_INTERVAL", 0);
  gsp_cfg.max_frames = env_uint("GSP_MAX_FRAMES", GSP_MAX_FRAMES);
  gsp_cfg.alloc_frames = env_uint("GSP_ALLOC_FRAMES", 48);
  gsp_cfg.control_signal = (int)env_uint("GSP_CONTROL_SIGNAL", 0);
  if (gsp_cfg.control_signal == 0)
    gsp_cfg.control_signal = GSP_SIG_CONTROL_DEFAULT;
  if (gsp_cfg.max_frames == 0 || gsp_cfg.max_frames > GSP_MAX_FRAMES)
    gsp_cfg.max_frames = GSP_MAX_FRAMES;
  if (gsp_cfg.alloc_frames == 0 || gsp_cfg.alloc_frames > GSP_MAX_FRAMES)
    gsp_cfg.alloc_frames = GSP_MAX_FRAMES;
  if (gsp_cfg.sample_interval_us < 100)
    gsp_cfg.sample_interval_us = 100;
  if (gsp_cfg.wall_interval_us < 1000)
    gsp_cfg.wall_interval_us = 1000;
  if (gsp_cfg.leaks)
    gsp_cfg.allocations = true;
  if (gsp_cfg.refcounts)
    gsp_cfg.allocations = true;
}

/* Remove this agent from LD_PRELOAD so child processes run untraced,
   unless GSP_FOLLOW_CHILDREN asks otherwise.  */
static void
scrub_environment(void)
{
  if (env_flag("GSP_FOLLOW_CHILDREN", false))
    return;

  const char *pre = getenv("LD_PRELOAD");
  Dl_info info;
  if (pre != NULL && dladdr((void *)scrub_environment, &info)
      && info.dli_fname != NULL)
    {
      const char *base = strrchr(info.dli_fname, '/');
      char kept[4096];
      size_t used = 0;
      const char *p = pre;

      base = base ? base + 1 : info.dli_fname;
      kept[0] = '\0';
      while (*p)
        {
          size_t len = strcspn(p, ": ");
          const char *slash = memrchr(p, '/', len);
          const char *name = slash ? slash + 1 : p;
          size_t nlen = len - (size_t)(name - p);

          if (len > 0 && !(nlen == strlen(base) && memcmp(name, base, nlen) == 0)
              && used + len + 2 < sizeof(kept))
            {
              if (used)
                kept[used++] = ':';
              memcpy(kept + used, p, len);
              used += len;
              kept[used] = '\0';
            }
          p += len;
          while (*p == ':' || *p == ' ')
            p++;
        }
      if (used)
        setenv("LD_PRELOAD", kept, 1);
      else
        unsetenv("LD_PRELOAD");
    }
  unsetenv("GSP_OUTPUT");
  unsetenv("GSP_RECORDER_PID");
}

/* ------------------------------------------------------------------ */
/* rings                                                               */

static bool
ring_init(gsp_ring *r, uint32_t cap)
{
  if (r->buf == NULL)
    {
      r->buf = gsp_map(cap);
      if (r->buf == NULL)
        return false;
      r->cap = cap;
    }
  atomic_store(&r->head, 0);
  atomic_store(&r->tail, 0);
  return true;
}

static void
ring_copy(gsp_ring *r, uint64_t pos, const void *src, size_t len)
{
  uint32_t off = (uint32_t)(pos & (r->cap - 1));
  size_t first = r->cap - off;

  if (first >= len)
    {
      if (src)
        memcpy(r->buf + off, src, len);
      else
        memset(r->buf + off, 0, len);
    }
  else
    {
      if (src)
        {
          memcpy(r->buf + off, src, first);
          memcpy(r->buf, (const uint8_t *)src + first, len - first);
        }
      else
        {
          memset(r->buf + off, 0, first);
          memset(r->buf, 0, len - first);
        }
    }
}

static bool
ring_put(gsp_ring *r, bool may_block, uint16_t type, uint32_t aux,
         uint16_t flags, uint64_t time, uint32_t tid,
         const void *a, size_t alen, const void *b, size_t blen)
{
  size_t raw = sizeof(gsp_record) + alen + blen;
  size_t total = GSP_RECORD_ALIGN(raw);
  uint64_t head, tail;
  gsp_record h;

  if (r->buf == NULL || total > r->cap / 2)
    return false;
  for (int spins = 0;; spins++)
    {
      head = atomic_load_explicit(&r->head, memory_order_relaxed);
      tail = atomic_load_explicit(&r->tail, memory_order_acquire);
      if (r->cap - (head - tail) >= total)
        break;
      if (!may_block || !atomic_load(&writer_running) || spins > 50000)
        return false;
      gsp_writer_wake();
      struct timespec ts = { 0, 20000 };
      nanosleep(&ts, NULL);
    }

  h.type = type;
  h.flags = flags;
  h.size = (uint32_t)total;
  h.time = time;
  h.tid = tid;
  h.aux = aux;
  ring_copy(r, head, &h, sizeof(h));
  if (alen)
    ring_copy(r, head + sizeof(h), a, alen);
  if (blen)
    ring_copy(r, head + sizeof(h) + alen, b, blen);
  if (total > raw)
    ring_copy(r, head + raw, NULL, total - raw);
  atomic_store_explicit(&r->head, head + total, memory_order_release);
  return true;
}

bool
gsp_emit_normal(gsp_thread *t, uint16_t type, uint32_t aux, uint16_t flags,
                uint64_t time, const void *a, size_t alen,
                const void *b, size_t blen)
{
  if (t == NULL)
    return false;
  return ring_put(&t->ring_normal, true, type, aux, flags, time,
                  (uint32_t)t->tid, a, alen, b, blen);
}

bool
gsp_emit_signal(gsp_thread *t, uint16_t type, uint32_t aux, uint16_t flags,
                uint64_t time, const void *a, size_t alen,
                const void *b, size_t blen)
{
  if (t == NULL)
    return false;
  if (!ring_put(&t->ring_signal, false, type, aux, flags, time,
                (uint32_t)t->tid, a, alen, b, blen))
    {
      t->dropped_signal++;
      return false;
    }
  return true;
}

/* ------------------------------------------------------------------ */
/* writer output                                                       */

static uint8_t wbuf[256 * 1024];
static size_t wbuf_used;
static uint64_t bytes_written;

static void
write_all(const void *p, size_t len)
{
  const uint8_t *c = p;
  while (len > 0 && out_fd >= 0)
    {
      ssize_t n = write(out_fd, c, len);
      if (n < 0)
        {
          if (errno == EINTR)
            continue;
          return;
        }
      c += n;
      len -= (size_t)n;
      bytes_written += (uint64_t)n;
    }
}

static void
wbuf_flush(void)
{
  if (wbuf_used)
    {
      write_all(wbuf, wbuf_used);
      wbuf_used = 0;
    }
}

void
gsp_writer_emit(uint16_t type, uint32_t aux, uint64_t time, uint32_t tid,
                const void *a, size_t alen, const void *b, size_t blen)
{
  size_t raw = sizeof(gsp_record) + alen + blen;
  size_t total = GSP_RECORD_ALIGN(raw);
  gsp_record h = { type, 0, (uint32_t)total, time, tid, aux };
  static const uint8_t zeros[8];

  if (total > sizeof(wbuf) - wbuf_used)
    wbuf_flush();
  if (total > sizeof(wbuf))
    {
      write_all(&h, sizeof(h));
      write_all(a, alen);
      write_all(b, blen);
      write_all(zeros, total - raw);
      return;
    }
  memcpy(wbuf + wbuf_used, &h, sizeof(h));
  if (alen)
    memcpy(wbuf + wbuf_used + sizeof(h), a, alen);
  if (blen)
    memcpy(wbuf + wbuf_used + sizeof(h) + alen, b, blen);
  memset(wbuf + wbuf_used + raw, 0, total - raw);
  wbuf_used += total;
}

void
gsp_writer_wake(void)
{
  if (wake_pipe[1] >= 0)
    {
      char c = 1;
      ssize_t ignored = write(wake_pipe[1], &c, 1);
      (void)ignored;
    }
}

static void
drain_ring(gsp_ring *r)
{
  uint64_t tail, head;
  uint32_t off;
  size_t len, first;

  if (r->buf == NULL)
    return;
  tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
  head = atomic_load_explicit(&r->head, memory_order_acquire);
  if (head == tail)
    return;
  len = (size_t)(head - tail);
  off = (uint32_t)(tail & (r->cap - 1));
  first = r->cap - off;
  if (first >= len)
    write_all(r->buf + off, len);
  else
    {
      write_all(r->buf + off, first);
      write_all(r->buf, len - first);
    }
  atomic_store_explicit(&r->tail, head, memory_order_release);
}

static void
drain_all(void)
{
  int n = atomic_load(&gsp_thread_count);

  wbuf_flush();
  for (int i = 0; i < n; i++)
    {
      gsp_thread *t = gsp_threads[i];
      int state;

      if (t == NULL)
        continue;
      state = atomic_load(&t->state);
      if (state != GSP_SLOT_ACTIVE && state != GSP_SLOT_EXITED)
        continue;
      drain_ring(&t->ring_signal);
      drain_ring(&t->ring_normal);
      if (state == GSP_SLOT_EXITED)
        {
          if (t->dropped_signal)
            {
              uint64_t d = t->dropped_signal;
              gsp_writer_emit(GSP_REC_DROPPED, GSP_REC_SAMPLE, gsp_now(),
                              (uint32_t)t->tid, &d, sizeof(d), NULL, 0);
              wbuf_flush();
            }
          atomic_store(&t->state, GSP_SLOT_RETIRED);
        }
    }
}

/* ------------------------------------------------------------------ */
/* threads                                                             */

static void
thread_key_destructor(void *value)
{
  gsp_thread *t = value;
  if (t != NULL)
    gsp_thread_finish(t);
}

void
gsp_thread_finish(gsp_thread *t)
{
  thread_exiting = 1;
  if (t->has_cpu_timer)
    {
      t->has_cpu_timer = false;
      timer_delete(t->cpu_timer);
    }
  if (t->has_wall_timer)
    {
      t->has_wall_timer = false;
      timer_delete(t->wall_timer);
    }
  if (!gsp_in_agent)
    gsp_emit_normal(t, GSP_REC_THREAD_END, 0, 0, gsp_now(), NULL, 0, NULL, 0);
  gsp_self_thread = NULL;
  atomic_store(&t->state, GSP_SLOT_EXITED);
  gsp_writer_wake();
}

gsp_thread *
gsp_thread_current(void)
{
  gsp_thread *t = gsp_self_thread;
  int idx = -1;
  pthread_attr_t attr;
  char name[32] = "";

  if (t != NULL)
    return t;
  if (gsp_is_internal || thread_exiting || !atomic_load(&gsp_recording)
      || atomic_load(&finished))
    return NULL;

  gsp_in_agent++;
  pthread_mutex_lock(&registry_lock);
  int count = atomic_load(&gsp_thread_count);
  for (int i = 0; i < count; i++)
    if (gsp_threads[i] && atomic_load(&gsp_threads[i]->state) == GSP_SLOT_RETIRED)
      {
        idx = i;
        break;
      }
  if (idx < 0 && count < GSP_MAX_THREADS)
    idx = count;
  if (idx < 0)
    {
      pthread_mutex_unlock(&registry_lock);
      gsp_in_agent--;
      return NULL;
    }
  t = gsp_threads[idx];
  if (t == NULL)
    {
      t = gsp_map(sizeof(*t));
      if (t == NULL)
        {
          pthread_mutex_unlock(&registry_lock);
          gsp_in_agent--;
          return NULL;
        }
    }
  if (!ring_init(&t->ring_normal, GSP_RING_NORMAL)
      || !ring_init(&t->ring_signal, GSP_RING_SIGNAL))
    {
      pthread_mutex_unlock(&registry_lock);
      gsp_in_agent--;
      return NULL;
    }
  t->tid = gsp_gettid();
  t->flags = (t->tid == traced_pid) ? GSP_THREAD_MAIN : 0;
  t->has_cpu_timer = t->has_wall_timer = false;
  t->in_unwind = 0;
  t->dropped_signal = 0;
  atomic_store(&t->suspended, 0);
  t->stack_lo = t->stack_hi = 0;
  if (pthread_getattr_np(pthread_self(), &attr) == 0)
    {
      void *addr;
      size_t size;
      if (pthread_attr_getstack(&attr, &addr, &size) == 0)
        {
          t->stack_lo = (uintptr_t)addr;
          t->stack_hi = (uintptr_t)addr + size;
        }
      pthread_attr_destroy(&attr);
    }
  {
    unsigned long fs = 0;
    syscall(SYS_arch_prctl, 0x1003 /* ARCH_GET_FS */, &fs);
    t->tls_base = fs;
  }
  gsp_threads[idx] = t;
  if (idx == count)
    atomic_store(&gsp_thread_count, count + 1);
  atomic_store(&t->state, GSP_SLOT_ACTIVE);
  pthread_mutex_unlock(&registry_lock);

  gsp_self_thread = t;
  pthread_setspecific(thread_key, t);
  prctl(PR_GET_NAME, name, 0, 0, 0);
  gsp_emit_normal(t, GSP_REC_THREAD, t->flags, 0, gsp_now(),
                  name, strlen(name) + 1, NULL, 0);
  gsp_thread_start_timers(t);
  gsp_in_agent--;
  return t;
}

/* ------------------------------------------------------------------ */
/* interning                                                           */

typedef struct intern_node
{
  struct intern_node *next;
  uint64_t hash;
  uint32_t id;
  uint32_t length;   /* bytes */
  uint8_t data[];
} intern_node;

typedef struct intern_table
{
  pthread_mutex_t lock;
  intern_node **buckets;
  uint32_t mask;
  uint32_t next_id;
} intern_table;

static intern_table strings = { PTHREAD_MUTEX_INITIALIZER, NULL, 0, 1 };
static intern_table stacks = { PTHREAD_MUTEX_INITIALIZER, NULL, 0, 1 };

static uint64_t
hash_bytes(const void *p, size_t n)
{
  const uint8_t *c = p;
  uint64_t h = 0x9E3779B97F4A7C15ull ^ n;
  size_t i = 0;
  for (; i + 8 <= n; i += 8)
    {
      uint64_t w;
      memcpy(&w, c + i, 8);
      h = (h ^ w) * 0xff51afd7ed558ccdull;
      h ^= h >> 32;
    }
  for (; i < n; i++)
    h = (h ^ c[i]) * 1099511628211ull;
  return h ? h : 1;
}

static void
emit_definition(uint16_t type, uint32_t id, const void *a, size_t alen,
                const void *b, size_t blen)
{
  if (gsp_is_internal)
    gsp_writer_emit(type, id, gsp_now(), (uint32_t)gsp_gettid(),
                    a, alen, b, blen);
  else
    {
      gsp_thread *t = gsp_thread_current();
      if (t)
        gsp_emit_normal(t, type, id, 0, gsp_now(), a, alen, b, blen);
    }
}

static uint32_t
intern(intern_table *table, uint32_t buckets, const void *data,
       uint32_t length, uint16_t type)
{
  uint64_t h = hash_bytes(data, length);
  intern_node *node;
  uint32_t id;

  pthread_mutex_lock(&table->lock);
  if (table->buckets == NULL)
    {
      table->buckets = gsp_map(sizeof(intern_node *) * buckets);
      if (table->buckets == NULL)
        {
          pthread_mutex_unlock(&table->lock);
          return 0;
        }
      table->mask = buckets - 1;
    }
  for (node = table->buckets[h & table->mask]; node; node = node->next)
    if (node->hash == h && node->length == length
        && memcmp(node->data, data, length) == 0)
      {
        id = node->id;
        pthread_mutex_unlock(&table->lock);
        return id;
      }
  node = gsp_arena_alloc(sizeof(*node) + length);
  if (node == NULL)
    {
      pthread_mutex_unlock(&table->lock);
      return 0;
    }
  node->hash = h;
  node->length = length;
  node->id = id = table->next_id++;
  memcpy(node->data, data, length);
  node->next = table->buckets[h & table->mask];
  table->buckets[h & table->mask] = node;
  pthread_mutex_unlock(&table->lock);

  /* Emitted outside the lock; readers resolve ids in a second pass.  */
  if (type == GSP_REC_STRING)
    {
      static const char nul = 0;
      emit_definition(type, id, data, length, &nul, 1);
    }
  else
    {
      gsp_frames_payload fp = { length / 8, 0, 0 };
      emit_definition(type, id, &fp, sizeof(fp), data, length);
    }
  return id;
}

uint32_t
gsp_intern_string(const char *s)
{
  if (s == NULL)
    return 0;
  return intern(&strings, 1u << 14, s, (uint32_t)strlen(s), GSP_REC_STRING);
}

uint32_t
gsp_intern_stack(const uint64_t *frames, unsigned n)
{
  if (n == 0)
    return 0;
  return intern(&stacks, 1u << 20, frames, n * 8, GSP_REC_STACK);
}

/* ------------------------------------------------------------------ */
/* writer thread and control                                           */

static void
finish_recording(void)
{
  bool from_signal = atomic_load(&stop_from_signal);
  gsp_sampler_stop();
  drain_all();
  if (!from_signal)
    {
      gsp_images_emit_new_writer();
      gsp_objc_dump_methods();
      if (gsp_cfg.leaks)
        gsp_leaks_snapshot();
    }
  /* samples dropped by threads that are still alive */
  {
    int n = atomic_load(&gsp_thread_count);
    for (int i = 0; i < n; i++)
      {
        gsp_thread *t = gsp_threads[i];
        if (t && atomic_load(&t->state) == GSP_SLOT_ACTIVE && t->dropped_signal)
          {
            uint64_t d = t->dropped_signal;
            gsp_writer_emit(GSP_REC_DROPPED, GSP_REC_SAMPLE, gsp_now(),
                            (uint32_t)t->tid, &d, sizeof(d), NULL, 0);
          }
      }
  }
  atomic_store(&gsp_alloc_on, 0);
  gsp_alloc_stop_live();
  atomic_store(&finished, 1);
  /* Let in-flight producers publish what they have.  */
  struct timespec ts = { 0, 2000000 };
  nanosleep(&ts, NULL);
  drain_all();
  gsp_writer_emit(GSP_REC_END, 0, gsp_now(), (uint32_t)traced_pid,
                  NULL, 0, NULL, 0);
  wbuf_flush();
  atomic_store(&gsp_recording, 0);
  fsync(out_fd);
  close(out_fd);
  out_fd = -1;

  char done[1200];
  snprintf(done, sizeof(done), "%s/events-%d.done", gsp_cfg.output,
           (int)traced_pid);
  int fd = open(done, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0644);
  if (fd >= 0)
    close(fd);
}

static void *
writer_main(void *arg)
{
  sigset_t set;
  uint64_t next_leak = 0;
  uint64_t next_images = 0;

  (void)arg;
  gsp_is_internal = 1;
  gsp_in_agent = 1;
  sigemptyset(&set);
  sigaddset(&set, GSP_SIG_CPU);
  sigaddset(&set, GSP_SIG_WALL);
  sigaddset(&set, GSP_SIG_SUSPEND);
  sigaddset(&set, gsp_cfg.control_signal);
  sigaddset(&set, SIGINT);
  sigaddset(&set, SIGTERM);
  sigaddset(&set, SIGHUP);
  pthread_sigmask(SIG_BLOCK, &set, NULL);
  prctl(PR_SET_NAME, "gsp-writer", 0, 0, 0);
  {
    pthread_attr_t attr;
    void *addr;
    size_t size;
    if (pthread_getattr_np(pthread_self(), &attr) == 0)
      {
        if (pthread_attr_getstack(&attr, &addr, &size) == 0)
          {
            gsp_writer_stack_lo = (uintptr_t)addr;
            gsp_writer_stack_hi = (uintptr_t)addr + size;
          }
        pthread_attr_destroy(&attr);
      }
  }

  if (gsp_cfg.leak_interval_s)
    next_leak = gsp_now() + (uint64_t)gsp_cfg.leak_interval_s * 1000000000ull;

  while (!atomic_load(&stop_requested))
    {
      struct pollfd pfd = { wake_pipe[0], POLLIN, 0 };
      char junk[64];
      uint64_t now;

      poll(&pfd, 1, 20);
      while (read(wake_pipe[0], junk, sizeof(junk)) > 0)
        ;
      drain_all();
      gsp_objc_poll();
      now = gsp_now();
      if (now >= next_images || gsp_images_changed())
        {
          gsp_images_emit_new_writer();
          next_images = now + 1000000000ull;
        }
      if (atomic_exchange(&mark_requested, 0))
        gsp_writer_emit(GSP_REC_MARK, GSP_MARK_USER, now,
                        (uint32_t)traced_pid, NULL, 0, NULL, 0);
      if (gsp_cfg.leaks
          && (atomic_exchange(&leak_requested, 0)
              || (next_leak && now >= next_leak)))
        {
          gsp_leaks_snapshot();
          if (gsp_cfg.leak_interval_s)
            next_leak = gsp_now()
              + (uint64_t)gsp_cfg.leak_interval_s * 1000000000ull;
        }
    }
  finish_recording();
  atomic_store(&writer_running, 0);
  return NULL;
}

static void
control_handler(int sig, siginfo_t *info, void *uc)
{
  int saved = errno;
  int request = GSP_CTL_STOP;

  (void)sig;
  (void)uc;
  if (info != NULL && info->si_code == SI_QUEUE)
    request = info->si_value.sival_int;
  if (request == GSP_CTL_LEAK_SNAPSHOT)
    atomic_store(&leak_requested, 1);
  else if (request == GSP_CTL_MARK)
    atomic_store(&mark_requested, 1);
  else
    atomic_store(&stop_requested, 1);
  gsp_writer_wake();
  errno = saved;
}

/* SIGINT/SIGTERM/SIGHUP while the app still has the default action:
   finish the recording, then die the way the app would have.  */
static int fatal_signals[] = { SIGINT, SIGTERM, SIGHUP };

static void stop_and_wait(void);

static void stop_and_wait_for(int seconds);

static void
fatal_handler(int sig)
{
  struct sigaction dfl;

  gsp_in_agent++;
  atomic_store(&stop_from_signal, 1);
  stop_and_wait_for(5);
  memset(&dfl, 0, sizeof(dfl));
  dfl.sa_handler = SIG_DFL;
  sigemptyset(&dfl.sa_mask);
  sigaction(sig, &dfl, NULL);
  raise(sig);
}

static void
install_fatal_handlers(void)
{
  for (size_t i = 0; i < sizeof(fatal_signals) / sizeof(fatal_signals[0]); i++)
    {
      struct sigaction old, sa;
      if (sigaction(fatal_signals[i], NULL, &old) != 0 || old.sa_handler != SIG_DFL)
        continue;
      memset(&sa, 0, sizeof(sa));
      sa.sa_handler = fatal_handler;
      sigemptyset(&sa.sa_mask);
      sa.sa_flags = SA_RESETHAND;
      sigaction(fatal_signals[i], &sa, NULL);
    }
}

static void
stop_and_wait_for(int seconds)
{
  if (!atomic_load(&writer_running) || atomic_load(&gave_up_waiting))
    return;
  atomic_store(&stop_requested, 1);
  gsp_writer_wake();
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += seconds;
  if (pthread_timedjoin_np(writer_thread, NULL, &deadline) != 0)
    atomic_store(&gave_up_waiting, 1);   /* never wait twice */
}

static void
stop_and_wait(void)
{
  stop_and_wait_for(60);
}

/* exit() runs atexit handlers (GNUstep releases many globals there)
   before ours, which would make everything those globals referenced look
   leaked.  Finish the recording first.  Returning from main reaches
   exit() inside libc without going through this symbol; then the atexit
   handler below finishes instead.  */
GSP_EXPORT void
exit(int status)
{
  typedef void (*exit_fn)(int) __attribute__((noreturn));
  static exit_fn real_exit;
  if (real_exit == NULL)
    real_exit = (exit_fn)dlsym(RTLD_NEXT, "exit");
  if (atomic_load(&writer_running) && !gsp_is_internal)
    {
      gsp_in_agent++;
      stop_and_wait();
      gsp_in_agent--;
    }
  real_exit(status);
}

static void
at_exit_handler(void)
{
  gsp_in_agent++;
  stop_and_wait();
  gsp_in_agent--;
}

static void
fork_child(void)
{
  /* The child is not traced: its copy of the rings has no writer.  Stop
     live-block tracking too, so no hook ever takes a lock that another
     parent thread may have held at fork time.  */
  gsp_alloc_stop_live();
  atomic_store(&gsp_recording, 0);
  atomic_store(&gsp_alloc_on, 0);
  atomic_store(&writer_running, 0);
  atomic_store(&finished, 1);
  gsp_self_thread = NULL;
  if (out_fd >= 0)
    close(out_fd);
  out_fd = -1;
}

uintptr_t gsp_agent_data_ranges[4][2];
int gsp_agent_data_count;

static void find_agent_text(void);

static int
find_agent_data_cb(struct dl_phdr_info *pi, size_t size, void *data)
{
  uintptr_t probe = (uintptr_t)find_agent_text;
  bool ours = false;
  (void)size;
  (void)data;
  for (int i = 0; i < pi->dlpi_phnum; i++)
    {
      const ElfW(Phdr) *ph = &pi->dlpi_phdr[i];
      uintptr_t lo = pi->dlpi_addr + ph->p_vaddr;
      if (ph->p_type == PT_LOAD && lo <= probe && probe < lo + ph->p_memsz)
        ours = true;
    }
  if (!ours)
    return 0;
  for (int i = 0; i < pi->dlpi_phnum && gsp_agent_data_count < 4; i++)
    {
      const ElfW(Phdr) *ph = &pi->dlpi_phdr[i];
      if (ph->p_type == PT_LOAD && (ph->p_flags & PF_W))
        {
          uintptr_t lo = (pi->dlpi_addr + ph->p_vaddr) & ~(uintptr_t)4095;
          uintptr_t hi = (pi->dlpi_addr + ph->p_vaddr + ph->p_memsz + 4095)
            & ~(uintptr_t)4095;
          gsp_agent_data_ranges[gsp_agent_data_count][0] = lo;
          gsp_agent_data_ranges[gsp_agent_data_count][1] = hi;
          gsp_agent_data_count++;
        }
    }
  return 1;
}

static int
find_agent_text_cb(struct dl_phdr_info *pi, size_t size, void *data)
{
  uintptr_t *range = data;
  uintptr_t probe = (uintptr_t)find_agent_text;

  (void)size;
  for (int i = 0; i < pi->dlpi_phnum; i++)
    {
      const ElfW(Phdr) *ph = &pi->dlpi_phdr[i];
      uintptr_t lo = pi->dlpi_addr + ph->p_vaddr;
      if (ph->p_type == PT_LOAD && (ph->p_flags & PF_X)
          && lo <= probe && probe < lo + ph->p_memsz)
        {
          range[0] = lo;
          range[1] = lo + ph->p_memsz;
          return 1;
        }
    }
  return 0;
}

static void
find_agent_text(void)
{
  uintptr_t range[2] = { 0, 0 };
  dl_iterate_phdr(find_agent_text_cb, range);
  gsp_agent_text_lo = range[0];
  gsp_agent_text_hi = range[1];
  dl_iterate_phdr(find_agent_data_cb, NULL);
}

__attribute__((constructor(101))) static void
gsp_init(void)
{
  gsp_file_header hdr;
  struct timespec rt;
  struct sigaction sa;
  char exe[256] = "";

  gsp_in_agent++;
  read_config();
  gsp_signpost_init();
  if (gsp_cfg.output[0] == '\0')
    {
      gsp_alloc_stop_live();
      gsp_in_agent--;
      return;
    }
  /* GNUstep caches the environment before this constructor runs, so
     processes it launches (gdnc, gpbs, NSTask children) inherit the agent
     even though LD_PRELOAD is scrubbed below.  When the recorder says who
     it is, only its direct child records unless children are followed.  */
  {
    const char *rec = getenv("GSP_RECORDER_PID");
    if (rec != NULL && *rec && !env_flag("GSP_FOLLOW_CHILDREN", false)
        && (pid_t)strtol(rec, NULL, 10) != getppid())
      {
        gsp_alloc_stop_live();
        gsp_in_agent--;
        return;
      }
  }
  scrub_environment();
  traced_pid = getpid();
  gsp_real_pthread_create = dlsym(RTLD_NEXT, "pthread_create");
  find_agent_text();

  mkdir(gsp_cfg.output, 0755);
  snprintf(events_path, sizeof(events_path), "%s/events-%d.bin",
           gsp_cfg.output, (int)traced_pid);
  out_fd = open(events_path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0644);
  if (out_fd < 0 || pipe2(wake_pipe, O_CLOEXEC | O_NONBLOCK) != 0)
    {
      fprintf(stderr, "gsperf: cannot write %s: %s\n", events_path,
              strerror(errno));
      if (out_fd >= 0)
        close(out_fd);
      out_fd = -1;
      gsp_alloc_stop_live();
      gsp_in_agent--;
      return;
    }

  memset(&hdr, 0, sizeof(hdr));
  memcpy(hdr.magic, GSP_MAGIC, 8);
  hdr.version = GSP_FORMAT_VERSION;
  hdr.header_size = sizeof(hdr);
  hdr.pid = (uint32_t)traced_pid;
  hdr.ppid = (uint32_t)getppid();
  start_ns = gsp_now();
  clock_gettime(CLOCK_REALTIME, &rt);
  hdr.start_ns = start_ns;
  hdr.start_realtime_ns = (uint64_t)rt.tv_sec * 1000000000ull
    + (uint64_t)rt.tv_nsec;
  hdr.pointer_size = sizeof(void *);
  hdr.flags = GSP_STREAM_FROM_AGENT;
  hdr.sample_interval_us = gsp_cfg.cpu_sampling ? gsp_cfg.sample_interval_us : 0;
  hdr.wall_interval_us = gsp_cfg.wall_sampling_main ? gsp_cfg.wall_interval_us : 0;
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n > 0)
    exe[n] = '\0';
  memcpy(hdr.exe, exe, sizeof(hdr.exe));
  write_all(&hdr, sizeof(hdr));

  pthread_key_create(&thread_key, thread_key_destructor);
  gsp_unwind_init();
  gsp_alloc_init();
  gsp_leaks_init();

  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = control_handler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(gsp_cfg.control_signal, &sa, NULL);

  pthread_atfork(NULL, NULL, fork_child);
  atomic_store(&gsp_recording, 1);
  gsp_sampler_init();

  gsp_thread *main_thread = gsp_thread_current();
  gsp_emit_normal(main_thread, GSP_REC_MARK, GSP_MARK_START, 0, start_ns,
                  NULL, 0, NULL, 0);
  gsp_images_emit_new(main_thread);

  atomic_store(&writer_running, 1);
  if (gsp_real_pthread_create(&writer_thread, NULL, writer_main, NULL) != 0)
    {
      atomic_store(&writer_running, 0);
      atomic_store(&gsp_recording, 0);
      gsp_in_agent--;
      return;
    }
  atexit(at_exit_handler);
  install_fatal_handlers();
  atomic_store(&gsp_alloc_on, gsp_cfg.allocations ? 1 : 0);
  gsp_in_agent--;
}

__attribute__((destructor)) static void
gsp_fini(void)
{
  at_exit_handler();
}

