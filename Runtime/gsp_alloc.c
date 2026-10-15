/* gsp_alloc.c - malloc-family interposition for the Allocations and Leaks
   instruments.

   The wrappers call glibc's __libc_* entry points directly, so they work
   before the agent is initialized and never recurse through dlsym.  The live
   block table is only kept when leak detection is on; the Allocations
   analysis replays the ALLOC/FREE records instead.  */

#include "gsp_internal.h"

#include <errno.h>
#include <string.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void __libc_free(void *);
extern void *__libc_memalign(size_t, size_t);
extern void *__libc_valloc(size_t);
extern void *__libc_pvalloc(size_t);

/* ------------------------------------------------------------------ */
/* live block table: linear probing, backward-shift deletion           */

static pthread_mutex_t live_mutex = PTHREAD_MUTEX_INITIALIZER;
static gsp_block *live_slots;
static uint64_t live_cap;   /* power of two */
static uint64_t live_used;

static inline uint64_t
hash_addr(uint64_t a)
{
  a ^= a >> 33;
  a *= 0xff51afd7ed558ccdull;
  a ^= a >> 33;
  return a;
}

static bool
live_grow(void)
{
  uint64_t ncap = live_cap ? live_cap * 2 : (1ull << 18);
  gsp_block *nslots = gsp_map(ncap * sizeof(gsp_block));

  if (nslots == NULL)
    return false;
  for (uint64_t i = 0; i < live_cap; i++)
    if (live_slots[i].address)
      {
        uint64_t j = hash_addr(live_slots[i].address) & (ncap - 1);
        while (nslots[j].address)
          j = (j + 1) & (ncap - 1);
        nslots[j] = live_slots[i];
      }
  if (live_slots)
    gsp_unmap(live_slots, live_cap * sizeof(gsp_block));
  live_slots = nslots;
  live_cap = ncap;
  return true;
}

static void
live_insert(uint64_t addr, uint64_t size, uint32_t stack)
{
  uint64_t i;

  if ((live_used + 1) * 10 > live_cap * 7 && !live_grow())
    return;
  i = hash_addr(addr) & (live_cap - 1);
  while (live_slots[i].address && live_slots[i].address != addr)
    i = (i + 1) & (live_cap - 1);
  if (live_slots[i].address == 0)
    live_used++;
  live_slots[i].address = addr;
  live_slots[i].size = size;
  live_slots[i].stack = stack;
  live_slots[i].class_name = 0;
}

static gsp_block *
live_find(uint64_t addr)
{
  uint64_t i;

  if (live_cap == 0)
    return NULL;
  i = hash_addr(addr) & (live_cap - 1);
  while (live_slots[i].address)
    {
      if (live_slots[i].address == addr)
        return &live_slots[i];
      i = (i + 1) & (live_cap - 1);
    }
  return NULL;
}

static void
live_remove(uint64_t addr)
{
  gsp_block *b = live_find(addr);
  uint64_t i, j, mask = live_cap - 1;

  if (b == NULL)
    return;
  i = (uint64_t)(b - live_slots);
  live_used--;
  j = i;
  for (;;)
    {
      j = (j + 1) & mask;
      if (live_slots[j].address == 0)
        break;
      uint64_t home = hash_addr(live_slots[j].address) & mask;
      /* Move j into the hole at i if its home is not in (i, j].  */
      bool between = (i <= j) ? (home > i && home <= j)
                              : (home > i || home <= j);
      if (!between)
        {
          live_slots[i] = live_slots[j];
          i = j;
        }
    }
  memset(&live_slots[i], 0, sizeof(gsp_block));
}

void
gsp_live_lock(void)
{
  pthread_mutex_lock(&live_mutex);
}

void
gsp_live_unlock(void)
{
  pthread_mutex_unlock(&live_mutex);
}

void
gsp_live_foreach(void (*fn)(const gsp_block *, void *), void *ctx)
{
  for (uint64_t i = 0; i < live_cap; i++)
    if (live_slots[i].address)
      fn(&live_slots[i], ctx);
}

uint64_t
gsp_live_count(void)
{
  return live_used;
}

void
gsp_alloc_tag(void *address, uint32_t class_name)
{
  if (!gsp_cfg.leaks || address == NULL)
    return;
  pthread_mutex_lock(&live_mutex);
  gsp_block *b = live_find((uint64_t)(uintptr_t)address);
  if (b)
    b->class_name = class_name;
  pthread_mutex_unlock(&live_mutex);
}

void
gsp_alloc_init(void)
{
  if (gsp_cfg.leaks)
    {
      pthread_mutex_lock(&live_mutex);
      live_grow();
      pthread_mutex_unlock(&live_mutex);
    }
}

/* ------------------------------------------------------------------ */
/* recording                                                           */

static inline bool
should_record(void)
{
  return atomic_load_explicit(&gsp_alloc_on, memory_order_relaxed)
    && !gsp_in_agent;
}

static void
record_alloc(void *p, size_t size, void *old)
{
  gsp_thread *t;
  uint32_t stack = 0;

  gsp_in_agent++;
  t = gsp_thread_current();
  if (t)
    stack = gsp_current_stack_id(t);
  if (gsp_cfg.leaks)
    {
      pthread_mutex_lock(&live_mutex);
      live_insert((uint64_t)(uintptr_t)p, size, stack);
      pthread_mutex_unlock(&live_mutex);
    }
  if (t)
    {
      gsp_alloc_payload a = { (uint64_t)(uintptr_t)p, size, stack, 0,
                              (uint64_t)(uintptr_t)old };
      gsp_emit_normal(t, GSP_REC_ALLOC, 0, 0, gsp_now(), &a, sizeof(a),
                      NULL, 0);
    }
  gsp_in_agent--;
}

static void
forget_block(void *p)
{
  if (gsp_cfg.leaks)
    {
      pthread_mutex_lock(&live_mutex);
      live_remove((uint64_t)(uintptr_t)p);
      pthread_mutex_unlock(&live_mutex);
    }
}

static void
record_free(void *p)
{
  gsp_thread *t;

  gsp_in_agent++;
  forget_block(p);
  t = gsp_thread_current();
  if (t)
    {
      gsp_free_payload f = { (uint64_t)(uintptr_t)p, 0, 0 };
      gsp_emit_normal(t, GSP_REC_FREE, 0, 0, gsp_now(), &f, sizeof(f),
                      NULL, 0);
    }
  gsp_in_agent--;
}

/* ------------------------------------------------------------------ */
/* interposed entry points                                             */

GSP_EXPORT void *
malloc(size_t size)
{
  void *p = __libc_malloc(size);
  if (p && should_record())
    record_alloc(p, size, NULL);
  return p;
}

GSP_EXPORT void *
calloc(size_t n, size_t size)
{
  void *p = __libc_calloc(n, size);
  if (p && should_record())
    record_alloc(p, n * size, NULL);
  return p;
}

GSP_EXPORT void
free(void *p)
{
  if (p && should_record())
    record_free(p);
  __libc_free(p);
}

GSP_EXPORT void *
realloc(void *old, size_t size)
{
  void *p;

  if (old == NULL)
    return malloc(size);
  if (!should_record())
    return __libc_realloc(old, size);
  if (size == 0)
    {
      free(old);
      return NULL;
    }
  gsp_in_agent++;
  forget_block(old);
  gsp_in_agent--;
  p = __libc_realloc(old, size);
  if (p == NULL)
    {
      /* The old block is still valid.  */
      if (gsp_cfg.leaks)
        {
          gsp_in_agent++;
          pthread_mutex_lock(&live_mutex);
          live_insert((uint64_t)(uintptr_t)old, 0, 0);
          pthread_mutex_unlock(&live_mutex);
          gsp_in_agent--;
        }
      return NULL;
    }
  record_alloc(p, size, old);
  return p;
}

GSP_EXPORT void *
reallocarray(void *old, size_t n, size_t size)
{
  size_t total;
  if (__builtin_mul_overflow(n, size, &total))
    {
      errno = ENOMEM;
      return NULL;
    }
  return realloc(old, total);
}

GSP_EXPORT void *
memalign(size_t align, size_t size)
{
  void *p = __libc_memalign(align, size);
  if (p && should_record())
    record_alloc(p, size, NULL);
  return p;
}

GSP_EXPORT void *
aligned_alloc(size_t align, size_t size)
{
  return memalign(align, size);
}

GSP_EXPORT int
posix_memalign(void **out, size_t align, size_t size)
{
  void *p;

  if (align < sizeof(void *) || (align & (align - 1)) != 0)
    return EINVAL;
  p = __libc_memalign(align, size);
  if (p == NULL)
    return ENOMEM;
  if (should_record())
    record_alloc(p, size, NULL);
  *out = p;
  return 0;
}

GSP_EXPORT void *
valloc(size_t size)
{
  void *p = __libc_valloc(size);
  if (p && should_record())
    record_alloc(p, size, NULL);
  return p;
}

GSP_EXPORT void *
pvalloc(size_t size)
{
  void *p = __libc_pvalloc(size);
  if (p && should_record())
    record_alloc(p, size, NULL);
  return p;
}
