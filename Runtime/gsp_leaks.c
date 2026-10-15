/* gsp_leaks.c - conservative leak detection (the Leaks instrument).

   Runs on the writer thread:
   1. take the live-block lock so no thread can allocate or free;
   2. stop every registered thread with GSP_SIG_SUSPEND; each saves its
      registers, stack pointer and TLS base, then waits;
   3. mark: scan roots (writable data of loaded images and other writable
      mappings, thread stacks from their saved stack pointer, saved
      registers, TLS areas) for words that point into live blocks, then
      scan reachable blocks transitively;
   4. every unmarked block is a leak; emit LEAK records;
   5. resume the threads and release the lock.

   Nothing here allocates with malloc: a stopped thread may hold the malloc
   lock.  Memory comes from mmap.  Ranges are only read after checking them
   against /proc/self/maps.  */

#include "gsp_internal.h"

#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <semaphore.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <asm/prctl.h>
#include <sys/syscall.h>

static sem_t suspend_ack;
static uint64_t explain_size;
static atomic_int world_stopped;
static uint32_t snapshot_ordinal;

/* ------------------------------------------------------------------ */
/* suspension                                                          */

static void
suspend_handler(int sig, siginfo_t *info, void *ucv)
{
  int saved = errno;
  gsp_thread *t = gsp_self_thread;
  ucontext_t *uc = ucv;
  unsigned long fs = 0;

  (void)sig;
  (void)info;
  if (t == NULL || !atomic_load(&world_stopped))
    {
      errno = saved;
      return;
    }
  memcpy(t->saved_regs, uc->uc_mcontext.gregs, sizeof(t->saved_regs));
  t->saved_sp = (uintptr_t)uc->uc_mcontext.gregs[REG_RSP];
  syscall(SYS_arch_prctl, ARCH_GET_FS, &fs);
  t->saved_fs = fs;
  atomic_store(&t->suspended, 1);
  sem_post(&suspend_ack);
  while (atomic_load(&world_stopped))
    {
      struct timespec ts = { 0, 100000 };
      nanosleep(&ts, NULL);
    }
  atomic_store(&t->suspended, 0);
  errno = saved;
}

void
gsp_leaks_init(void)
{
  struct sigaction sa;

  if (!gsp_cfg.leaks)
    return;
  if (getenv("GSP_LEAK_EXPLAIN"))
    explain_size = strtoull(getenv("GSP_LEAK_EXPLAIN"), NULL, 10);
  sem_init(&suspend_ack, 0, 0);
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = suspend_handler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigfillset(&sa.sa_mask);
  sigaction(GSP_SIG_SUSPEND, &sa, NULL);
}

static int
stop_world(void)
{
  int n = atomic_load(&gsp_thread_count);
  int stopped = 0;
  pid_t pid = getpid();

  atomic_store(&world_stopped, 1);
  for (int i = 0; i < n; i++)
    {
      gsp_thread *t = gsp_threads[i];
      if (t == NULL || atomic_load(&t->state) != GSP_SLOT_ACTIVE)
        continue;
      atomic_store(&t->suspended, 0);
      if (syscall(SYS_tgkill, pid, t->tid, GSP_SIG_SUSPEND) == 0)
        stopped++;
    }
  /* Wait for acknowledgements; threads stuck in uninterruptible sleep are
     given up on after a second (their stacks are then scanned whole).  */
  int acked = 0;
  while (acked < stopped)
    {
      struct timespec deadline;
      clock_gettime(CLOCK_REALTIME, &deadline);
      deadline.tv_sec += 1;
      if (sem_timedwait(&suspend_ack, &deadline) != 0)
        {
          if (errno == EINTR)
            continue;
          break;
        }
      acked++;
    }
  return acked;
}

static void
start_world(void)
{
  atomic_store(&world_stopped, 0);
  /* Drain stale acknowledgements from threads that answered late.  */
  while (sem_trywait(&suspend_ack) == 0)
    ;
}

/* ------------------------------------------------------------------ */
/* /proc/self/maps                                                     */

typedef struct region
{
  uintptr_t lo, hi;
  bool readable, writable;
  bool special;   /* [vvar], [vsyscall], device memory... */
  bool stack;     /* [stack] */
  bool has_block; /* contains a live malloc block: a heap, skip as root */
} region;

typedef struct regions
{
  region *items;
  size_t count, cap;
  size_t bytes;
} regions;

static bool
read_maps(regions *rs)
{
  int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
  size_t cap = 1 << 20, used = 0;
  char *text;

  if (fd < 0)
    return false;
  text = gsp_map(cap);
  if (text == NULL)
    {
      close(fd);
      return false;
    }
  for (;;)
    {
      if (used + 4096 > cap)
        break;
      ssize_t n = read(fd, text + used, cap - used - 1);
      if (n <= 0)
        break;
      used += (size_t)n;
    }
  close(fd);
  text[used] = 0;

  rs->cap = 1;
  for (size_t i = 0; i < used; i++)
    if (text[i] == '\n')
      rs->cap++;
  rs->bytes = rs->cap * sizeof(region);
  rs->items = gsp_map(rs->bytes);
  rs->count = 0;
  if (rs->items == NULL)
    {
      gsp_unmap(text, cap);
      return false;
    }

  char *line = text;
  while (line < text + used && rs->count < rs->cap)
    {
      char *end = strchr(line, '\n');
      region r;
      char *p;

      if (end)
        *end = 0;
      memset(&r, 0, sizeof(r));
      r.lo = strtoull(line, &p, 16);
      if (*p == '-')
        r.hi = strtoull(p + 1, &p, 16);
      while (*p == ' ')
        p++;
      r.readable = p[0] == 'r';
      r.writable = p[1] == 'w';
      /* skip perms, offset, dev, inode to the path */
      for (int field = 0; field < 4 && *p; field++)
        {
          while (*p && *p != ' ')
            p++;
          while (*p == ' ')
            p++;
        }
      if (strncmp(p, "[vvar", 5) == 0 || strcmp(p, "[vsyscall]") == 0
          || strcmp(p, "[vdso]") == 0 || strncmp(p, "/dev/", 5) == 0
          || strncmp(p, "/memfd:", 7) == 0)
        r.special = true;
      if (strcmp(p, "[stack]") == 0)
        r.stack = true;
      if (r.hi > r.lo)
        rs->items[rs->count++] = r;
      if (end == NULL)
        break;
      line = end + 1;
    }
  gsp_unmap(text, cap);
  return true;
}

static region *
find_region(regions *rs, uintptr_t p)
{
  size_t lo = 0, hi = rs->count;
  while (lo < hi)
    {
      size_t mid = (lo + hi) / 2;
      if (p < rs->items[mid].lo)
        hi = mid;
      else if (p >= rs->items[mid].hi)
        lo = mid + 1;
      else
        return &rs->items[mid];
    }
  return NULL;
}

/* ------------------------------------------------------------------ */
/* marking                                                             */

typedef struct mblock
{
  uint64_t address;
  uint64_t size;
  uint32_t stack;
  uint32_t class_name;
  uint32_t marked;
  uint32_t pad;
} mblock;

typedef struct scan_state
{
  mblock *blocks;
  size_t count;
  size_t bytes;
  uint32_t *work;      /* indices of marked, unscanned blocks */
  size_t work_count, work_cap, work_bytes;
  regions maps;
} scan_state;

static void
collect_block(const gsp_block *b, void *ctx)
{
  scan_state *s = ctx;
  mblock *m = &s->blocks[s->count++];
  m->address = b->address;
  m->size = b->size;
  m->stack = b->stack;
  m->class_name = b->class_name;
  m->marked = 0;
}

/* Heap sort: qsort may allocate, and a stopped thread can hold the malloc
   lock.  */
static void
sift_down(mblock *a, size_t start, size_t end)
{
  size_t root = start;
  while (2 * root + 1 < end)
    {
      size_t child = 2 * root + 1;
      size_t swap = root;
      if (a[swap].address < a[child].address)
        swap = child;
      if (child + 1 < end && a[swap].address < a[child + 1].address)
        swap = child + 1;
      if (swap == root)
        return;
      mblock tmp = a[root];
      a[root] = a[swap];
      a[swap] = tmp;
      root = swap;
    }
}

static void
sort_blocks(mblock *a, size_t n)
{
  if (n < 2)
    return;
  for (size_t start = n / 2; start-- > 0;)
    sift_down(a, start, n);
  for (size_t end = n - 1; end > 0; end--)
    {
      mblock tmp = a[0];
      a[0] = a[end];
      a[end] = tmp;
      sift_down(a, 0, end);
    }
}

static inline mblock *
block_for(scan_state *s, uint64_t p)
{
  size_t lo = 0, hi = s->count;
  while (lo < hi)
    {
      size_t mid = (lo + hi) / 2;
      mblock *m = &s->blocks[mid];
      if (p < m->address)
        hi = mid;
      else if (p >= m->address + (m->size ? m->size : 1))
        lo = mid + 1;
      else
        return m;
    }
  return NULL;
}

/* glibc's bins and stale free-chunk headers point at the header of the
   chunk that follows a block, which overlaps the block's last 8 usable
   bytes (address + usable - 8).  Treating that as an interior pointer
   would keep the block alive, so ignore exactly that address.  */
static inline bool
is_malloc_metadata(const mblock *m, uint64_t v)
{
#ifdef __GLIBC__
  uint64_t chunk = (m->size + 8 + 15) & ~(uint64_t)15;
  if (chunk < 32)
    chunk = 32;
  return v == m->address + chunk - 16;
#else
  (void)m;
  (void)v;
  return false;
#endif
}

static void
push_work(scan_state *s, uint32_t index)
{
  if (s->work_count == s->work_cap)
    {
      size_t ncap = s->work_cap ? s->work_cap * 2 : 65536;
      size_t nbytes = ncap * sizeof(uint32_t);
      uint32_t *nw = gsp_map(nbytes);
      if (nw == NULL)
        return;
      if (s->work)
        {
          memcpy(nw, s->work, s->work_count * sizeof(uint32_t));
          gsp_unmap(s->work, s->work_bytes);
        }
      s->work = nw;
      s->work_cap = ncap;
      s->work_bytes = nbytes;
    }
  s->work[s->work_count++] = index;
}

/* GSP_LEAK_EXPLAIN=<size>: report (to stderr) where blocks of that size
   were first found reachable from.  A diagnostic for false negatives.  */
static const char *explain_root = "";

static void
explain(uintptr_t at, uint64_t v, mblock *m)
{
  char buf[256];
  int n = snprintf(buf, sizeof(buf),
                   "gsperf leaks: block %#lx (%lu bytes) reachable via %#lx=%#lx from %s\n",
                   (unsigned long)m->address, (unsigned long)m->size,
                   (unsigned long)at, (unsigned long)v, explain_root);
  if (n > 0)
    {
      ssize_t ignored = write(2, buf, (size_t)n);
      (void)ignored;
    }
}

static void
scan_words(scan_state *s, uintptr_t lo, uintptr_t hi)
{
  lo = (lo + 7) & ~(uintptr_t)7;
  for (uintptr_t p = lo; p + 8 <= hi; p += 8)
    {
      uint64_t v = *(volatile uint64_t *)p;
      if (v < 4096)
        continue;
      mblock *m = block_for(s, v);
      if (m && !m->marked && !is_malloc_metadata(m, v))
        {
          m->marked = 1;
          if (explain_size && m->size == explain_size)
            explain(p, v, m);
          push_work(s, (uint32_t)(m - s->blocks));
        }
    }
}

/* Scan [lo, hi) clipped to readable mappings.  */
static void
scan_checked(scan_state *s, uintptr_t lo, uintptr_t hi)
{
  while (lo < hi)
    {
      region *r = find_region(&s->maps, lo);
      if (r == NULL)
        {
          /* advance to the next mapping */
          uintptr_t next = hi;
          for (size_t i = 0; i < s->maps.count; i++)
            if (s->maps.items[i].lo > lo)
              {
                next = s->maps.items[i].lo;
                break;
              }
          lo = next;
          continue;
        }
      uintptr_t end = r->hi < hi ? r->hi : hi;
      if (r->readable && !r->special)
        scan_words(s, lo, end);
      lo = end;
    }
}

static void
drain_work(scan_state *s)
{
  static char desc[96];
  while (s->work_count > 0)
    {
      mblock *m = &s->blocks[s->work[--s->work_count]];
      if (explain_size)
        {
          snprintf(desc, sizeof(desc), "block %#lx (%lu bytes)",
                   (unsigned long)m->address, (unsigned long)m->size);
          explain_root = desc;
        }
      scan_words(s, (uintptr_t)m->address, (uintptr_t)(m->address + m->size));
    }
}

static bool
is_thread_stack(uintptr_t lo, uintptr_t hi)
{
  int n = atomic_load(&gsp_thread_count);
  for (int i = 0; i < n; i++)
    {
      gsp_thread *t = gsp_threads[i];
      if (t && atomic_load(&t->state) == GSP_SLOT_ACTIVE && t->stack_hi
          && lo < t->stack_hi && hi > t->stack_lo)
        return true;
    }
  return false;
}

void
gsp_leaks_snapshot(void)
{
  scan_state s;
  uint64_t t0 = gsp_now();
  uint64_t live_bytes = 0, leak_bytes = 0, leak_count = 0;
  uint32_t ordinal = ++snapshot_ordinal;

  memset(&s, 0, sizeof(s));
  gsp_live_lock();
  stop_world();

  if (explain_size)
    {
      int mfd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
      char mb[4096];
      ssize_t mn;
      while (mfd >= 0 && (mn = read(mfd, mb, sizeof(mb))) > 0)
        {
          ssize_t ignored = write(2, mb, (size_t)mn);
          (void)ignored;
        }
      if (mfd >= 0)
        close(mfd);
    }
  s.bytes = (gsp_live_count() + 1) * sizeof(mblock);
  s.blocks = gsp_map(s.bytes);
  if (s.blocks == NULL || !read_maps(&s.maps))
    goto done;
  gsp_live_foreach(collect_block, &s);
  sort_blocks(s.blocks, s.count);
  for (size_t i = 0; i < s.count; i++)
    live_bytes += s.blocks[i].size;

  /* Mark regions holding malloc blocks: they are heaps, not roots.  */
  for (size_t i = 0, b = 0; i < s.maps.count && b < s.count; i++)
    {
      region *r = &s.maps.items[i];
      while (b < s.count && s.blocks[b].address < r->lo)
        b++;
      if (b < s.count && s.blocks[b].address < r->hi)
        r->has_block = true;
    }

  /* Roots 1: writable mappings that are not heaps, thread stacks or the
     agent's own memory.  */
  for (size_t i = 0; i < s.maps.count; i++)
    {
      region *r = &s.maps.items[i];
      if (!r->readable || !r->writable || r->special || r->has_block
          || r->stack || gsp_is_agent_memory(r->lo, r->hi)
          || (r->lo < gsp_writer_stack_hi && r->hi > gsp_writer_stack_lo)
          || is_thread_stack(r->lo, r->hi))
        continue;
      if (explain_size)
        {
          static char rd[96];
          snprintf(rd, sizeof(rd), "mapping %#lx-%#lx", (unsigned long)r->lo,
                   (unsigned long)r->hi);
          explain_root = rd;
        }
      scan_words(&s, r->lo, r->hi);
      drain_work(&s);
    }

  /* Roots 2: threads.  */
  int n = atomic_load(&gsp_thread_count);
  for (int i = 0; i < n; i++)
    {
      gsp_thread *t = gsp_threads[i];
      if (t == NULL || atomic_load(&t->state) != GSP_SLOT_ACTIVE)
        continue;
      if (explain_size)
        {
          static char td[96];
          snprintf(td, sizeof(td), "thread %d (sp %#lx, fs %#lx)", (int)t->tid,
                   (unsigned long)t->saved_sp, (unsigned long)t->saved_fs);
          explain_root = td;
        }
      if (atomic_load(&t->suspended))
        {
          scan_words(&s, (uintptr_t)t->saved_regs,
                     (uintptr_t)(t->saved_regs + NGREG));
          if (t->stack_hi && t->saved_sp >= t->stack_lo
              && t->saved_sp < t->stack_hi)
            scan_checked(&s, t->saved_sp, t->stack_hi);
          else if (t->saved_sp)
            {
              region *r = find_region(&s.maps, t->saved_sp);
              if (r)
                scan_checked(&s, t->saved_sp, r->hi);
            }
          if (t->saved_fs)
            scan_checked(&s, t->saved_fs - 16384, t->saved_fs + 4096);
        }
      else if (t->stack_hi)
        scan_checked(&s, t->stack_lo, t->stack_hi);
      drain_work(&s);
    }
  /* The main thread's [stack] mapping when it was not registered.  */
  for (size_t i = 0; i < s.maps.count; i++)
    if (s.maps.items[i].stack && !is_thread_stack(s.maps.items[i].lo,
                                                  s.maps.items[i].hi))
      {
        scan_words(&s, s.maps.items[i].lo, s.maps.items[i].hi);
        drain_work(&s);
      }

  start_world();
  gsp_live_unlock();

  {
    gsp_leak_summary_payload sum = { s.count, live_bytes, 0 };
    gsp_writer_emit(GSP_REC_LEAK_BEGIN, ordinal, t0, 0, &sum, sizeof(sum),
                    NULL, 0);
  }
  for (size_t i = 0; i < s.count; i++)
    if (!s.blocks[i].marked)
      {
        gsp_leak_payload lp;
        memset(&lp, 0, sizeof(lp));
        lp.address = s.blocks[i].address;
        lp.size = s.blocks[i].size;
        lp.stack = s.blocks[i].stack;
        lp.class_name = s.blocks[i].class_name;
        lp.snapshot = ordinal;
        gsp_writer_emit(GSP_REC_LEAK, ordinal, t0, 0, &lp, sizeof(lp),
                        NULL, 0);
        leak_count++;
        leak_bytes += lp.size;
      }
  {
    gsp_leak_summary_payload sum = { leak_count, leak_bytes,
                                     (gsp_now() - t0) / 1000 };
    gsp_writer_emit(GSP_REC_LEAK_END, ordinal, gsp_now(), 0, &sum,
                    sizeof(sum), NULL, 0);
  }
  goto cleanup;

done:
  start_world();
  gsp_live_unlock();
cleanup:
  if (s.blocks)
    gsp_unmap(s.blocks, s.bytes);
  if (s.work)
    gsp_unmap(s.work, s.work_bytes);
  if (s.maps.items)
    gsp_unmap(s.maps.items, s.maps.bytes);
}
