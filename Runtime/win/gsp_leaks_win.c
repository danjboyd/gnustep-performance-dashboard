/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* gsp_leaks_win.c - the Leaks instrument on Windows.

   The heap hooks (gsp_heap_win.c) keep a table of live blocks.  A leak
   check stops every other thread and does a conservative mark from the
   roots:

   - every committed, writable region of the address space (globals,
     thread stacks above their stack pointer, heap memory that is not a
     tracked block, which includes blocks allocated before the agent was
     injected), and
   - the integer registers of the stopped threads;

   then follows pointers through the reachable blocks.  Tracked blocks that
   were never reached are leaks.  An Objective-C object counts as
   referenced only through a pointer near its start; other blocks accept
   interior pointers.

   Left out of the roots: the agent's image (its output buffer holds
   recent block addresses), the agent's threads' stacks, the dead part of
   each stack below its stack pointer, and the scan's own memory.

   While threads are stopped one of them may hold the heap or the output
   lock, so the scan uses only VirtualAlloc'd memory and writes its
   records after letting them run again.  The live table's lock is taken
   before stopping anyone, so no thread is stopped half-way through an
   update.

   Checks run when the program calls exit() (before atexit handlers, as on
   Linux), when the recorder stops a running program, and every
   GSP_LEAK_INTERVAL seconds.  */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "GSPerformance/gsp_format.h"
#include "gsp_agent_win.h"

/* ------------------------------------------------------------------ */
/* live block table (open addressing, in VirtualAlloc'd memory)        */

typedef struct live_block
{
  uint64_t address;   /* 0 = empty, 1 = deleted */
  uint64_t size;
  uint32_t stack;
  uint32_t class_name;
} live_block;

#define EMPTY 0
#define DELETED 1

static bool leaks_on;
static CRITICAL_SECTION live_lock;
static live_block *live;
static size_t live_cap, live_used, live_count;
static uint32_t snapshot_ordinal;
static CRITICAL_SECTION scan_lock;

static void *
vm_alloc(size_t bytes)
{
  return VirtualAlloc(NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
}

static void
vm_free(void *p)
{
  if (p)
    VirtualFree(p, 0, MEM_RELEASE);
}

static inline size_t
slot_of(uint64_t a, size_t cap)
{
  return (size_t)((a >> 4) * 0x9E3779B97F4A7C15ull >> 17) & (cap - 1);
}

static bool
live_grow(void)
{
  size_t ncap = live_cap ? live_cap * 2 : 1u << 16;
  live_block *n = vm_alloc(ncap * sizeof(live_block));
  if (n == NULL)
    return false;
  for (size_t i = 0; i < live_cap; i++)
    if (live[i].address > DELETED)
      {
        size_t j = slot_of(live[i].address, ncap);
        while (n[j].address != EMPTY)
          j = (j + 1) & (ncap - 1);
        n[j] = live[i];
      }
  vm_free(live);
  live = n;
  live_cap = ncap;
  live_used = live_count;
  return true;
}

static live_block *
live_find(uint64_t a)
{
  if (live_cap == 0)
    return NULL;
  for (size_t j = slot_of(a, live_cap);; j = (j + 1) & (live_cap - 1))
    {
      if (live[j].address == EMPTY)
        return NULL;
      if (live[j].address == a)
        return &live[j];
    }
}

void
gspw_live_put(void *p, size_t size, uint32_t stack, uint32_t class_name)
{
  uint64_t a = (uint64_t)(uintptr_t)p;

  if (!leaks_on || a <= DELETED)
    return;
  EnterCriticalSection(&live_lock);
  if ((live_used + 1) * 4 > live_cap * 3 && !live_grow())
    {
      LeaveCriticalSection(&live_lock);
      return;
    }
  live_block *b = live_find(a);
  if (b == NULL)
    {
      size_t j = slot_of(a, live_cap);
      while (live[j].address > DELETED)
        j = (j + 1) & (live_cap - 1);
      if (live[j].address == EMPTY)
        live_used++;
      b = &live[j];
      live_count++;
    }
  b->address = a;
  b->size = size;
  b->stack = stack;
  b->class_name = class_name;
  LeaveCriticalSection(&live_lock);
}

void
gspw_live_insert(void *p, size_t size, uint32_t stack)
{
  gspw_live_put(p, size, stack, 0);
}

/* Removes a block; returns what was known about it.  */
bool
gspw_live_take(void *p, size_t *size, uint32_t *stack, uint32_t *class_name)
{
  bool found = false;

  if (!leaks_on || p == NULL)
    return false;
  EnterCriticalSection(&live_lock);
  live_block *b = live_find((uint64_t)(uintptr_t)p);
  if (b)
    {
      if (size)
        *size = (size_t)b->size;
      if (stack)
        *stack = b->stack;
      if (class_name)
        *class_name = b->class_name;
      b->address = DELETED;
      live_count--;
      found = true;
    }
  LeaveCriticalSection(&live_lock);
  return found;
}

/* libobjc2 puts a reference count word in front of each object.  */
void
gspw_live_tag(void *obj, uint32_t class_name)
{
  if (!leaks_on || obj == NULL)
    return;
  EnterCriticalSection(&live_lock);
  live_block *b = live_find((uint64_t)(uintptr_t)obj);
  if (b == NULL)
    b = live_find((uint64_t)(uintptr_t)obj - sizeof(intptr_t));
  if (b)
    b->class_name = class_name;
  LeaveCriticalSection(&live_lock);
}

bool
gspw_leaks_enabled(void)
{
  return leaks_on;
}

void
gspw_leaks_start(bool on)
{
  InitializeCriticalSection(&live_lock);
  InitializeCriticalSection(&scan_lock);
  leaks_on = on;
}

/* ------------------------------------------------------------------ */
/* the scan                                                            */

typedef struct sblock
{
  uint64_t address;
  uint64_t size;
  uint32_t stack;
  uint32_t class_name;
  uint32_t marked;
  uint32_t reserved;
} sblock;

typedef struct range
{
  uint64_t lo, hi;
} range;

#define MAX_SCAN_THREADS 1024
#define MAX_EXCLUDED (2 * MAX_SCAN_THREADS + 16)

typedef struct scan
{
  sblock *blocks;
  size_t count;
  uint64_t lo, hi;        /* address span of the blocks */
  uint32_t *work;
  size_t work_used;
  range *excluded;
  size_t excluded_count;
} scan;

static int
compare_blocks(const void *a, const void *b)
{
  const sblock *x = a, *y = b;
  return x->address < y->address ? -1 : x->address > y->address;
}

static int
compare_ranges(const void *a, const void *b)
{
  const range *x = a, *y = b;
  return x->lo < y->lo ? -1 : x->lo > y->lo;
}

/* index of the last block starting at or before a, or -1 */
static ptrdiff_t
block_at_or_before(const scan *s, uint64_t a)
{
  ptrdiff_t lo = 0, hi = (ptrdiff_t)s->count - 1, found = -1;
  while (lo <= hi)
    {
      ptrdiff_t mid = (lo + hi) / 2;
      if (s->blocks[mid].address <= a)
        {
          found = mid;
          lo = mid + 1;
        }
      else
        hi = mid - 1;
    }
  return found;
}

static inline void
consider(scan *s, uint64_t v)
{
  if (v < s->lo || v >= s->hi)
    return;
  ptrdiff_t i = block_at_or_before(s, v);
  if (i < 0)
    return;
  sblock *b = &s->blocks[i];
  uint64_t off = v - b->address;
  if (off >= b->size)
    return;
  /* objects: only pointers to the object (after the refcount word) */
  if (b->class_name != 0 && off > 2 * sizeof(intptr_t))
    return;
  if (!b->marked)
    {
      b->marked = 1;
      s->work[s->work_used++] = (uint32_t)i;
    }
}

static void
scan_block(scan *s, const sblock *b)
{
  /* 4-byte steps: some GNUstep containers store pointers 4-byte aligned */
  if (b->size < sizeof(uint64_t))
    return;
  const uint8_t *p = (const uint8_t *)(uintptr_t)b->address;
  const uint8_t *end = p + b->size - sizeof(uint64_t);
  for (; p <= end; p += 4)
    {
      uint64_t v;
      memcpy(&v, p, sizeof(v));
      consider(s, v);
    }
}

static void
drain(scan *s)
{
  while (s->work_used > 0)
    scan_block(s, &s->blocks[s->work[--s->work_used]]);
}

/* Scans [lo, hi) word by word, stepping over tracked blocks.  */
static void
scan_root_range(scan *s, uint64_t lo, uint64_t hi)
{
  lo = (lo + 7) & ~7ull;
  ptrdiff_t i = block_at_or_before(s, lo);
  size_t bi = i < 0 ? 0 : (size_t)i;
  uint64_t p = lo;

  while (p + 8 <= hi)
    {
      while (bi < s->count && s->blocks[bi].address + s->blocks[bi].size <= p)
        bi++;
      if (bi < s->count && s->blocks[bi].address <= p)
        {
          p = (s->blocks[bi].address + s->blocks[bi].size + 7) & ~7ull;
          continue;
        }
      uint64_t stop = hi;
      if (bi < s->count && s->blocks[bi].address < stop)
        stop = s->blocks[bi].address;
      for (; p + 8 <= stop; p += 8)
        consider(s, *(const uint64_t *)(uintptr_t)p);
      if (p < stop)
        p = stop;
    }
}

/* Scans a region minus the excluded ranges.  */
static void
scan_region(scan *s, uint64_t lo, uint64_t hi)
{
  for (size_t k = 0; k < s->excluded_count && lo < hi; k++)
    {
      const range *x = &s->excluded[k];
      if (x->hi <= lo)
        continue;
      if (x->lo >= hi)
        break;
      if (x->lo > lo)
        scan_root_range(s, lo, x->lo);
      lo = x->hi > lo ? x->hi : lo;
    }
  if (lo < hi)
    scan_root_range(s, lo, hi);
  drain(s);
}

static void
exclude(scan *s, uint64_t lo, uint64_t hi)
{
  if (lo < hi && s->excluded_count < MAX_EXCLUDED)
    {
      s->excluded[s->excluded_count].lo = lo;
      s->excluded[s->excluded_count].hi = hi;
      s->excluded_count++;
    }
}

/* the whole reservation a stack lives in */
static void
reservation_of(uint64_t addr, uint64_t *lo, uint64_t *hi)
{
  MEMORY_BASIC_INFORMATION mbi;
  *lo = *hi = 0;
  if (VirtualQuery((LPCVOID)(uintptr_t)addr, &mbi, sizeof(mbi)) == 0)
    return;
  uint8_t *base = mbi.AllocationBase;
  uint8_t *p = base;
  while (VirtualQuery(p, &mbi, sizeof(mbi)) != 0 && mbi.AllocationBase == base)
    p = (uint8_t *)mbi.BaseAddress + mbi.RegionSize;
  *lo = (uint64_t)(uintptr_t)base;
  *hi = (uint64_t)(uintptr_t)p;
}

static void
exclude_vm(scan *s, const void *p, size_t bytes)
{
  if (p)
    exclude(s, (uint64_t)(uintptr_t)p,
            (uint64_t)(uintptr_t)p + ((bytes + 0xFFFF) & ~(size_t)0xFFFF));
}

static bool
writable(DWORD protect)
{
  if (protect & (PAGE_GUARD | PAGE_NOACCESS))
    return false;
  return (protect & (PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE
                     | PAGE_EXECUTE_WRITECOPY)) != 0;
}

typedef struct stopped
{
  DWORD tid;
  HANDLE handle;
  bool suspended;
  bool agent;
} stopped;

/* Runs a leak check.  stack_top: on the calling thread, the address below
   which the stack belongs to the agent (the hook's frame), or NULL when
   the caller is one of the agent's threads.  */
void
gspw_leaks_snapshot(const void *stack_top)
{
  static stopped threads[MAX_SCAN_THREADS];
  int nthreads = 0;
  scan s;
  uint64_t t0 = gspw_now();
  uint64_t live_bytes = 0, leak_count = 0, leak_bytes = 0;
  DWORD self = GetCurrentThreadId(), pid = GetCurrentProcessId();

  if (!leaks_on || !gspw_recording())
    return;
  EnterCriticalSection(&scan_lock);
  memset(&s, 0, sizeof(s));
  uint32_t ordinal = ++snapshot_ordinal;

  /* threads, listed while nobody is stopped (the snapshot uses the heap) */
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snap != INVALID_HANDLE_VALUE)
    {
      THREADENTRY32 te;
      te.dwSize = sizeof(te);
      if (Thread32First(snap, &te))
        do
          {
            if (te.th32OwnerProcessID != pid || te.th32ThreadID == self
                || nthreads >= MAX_SCAN_THREADS)
              continue;
            HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT
                                  | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
            if (h == NULL)
              continue;
            threads[nthreads].tid = te.th32ThreadID;
            threads[nthreads].handle = h;
            threads[nthreads].suspended = false;
            threads[nthreads].agent = gspw_is_agent_thread(te.th32ThreadID);
            nthreads++;
          }
        while (Thread32Next(snap, &te));
      CloseHandle(snap);
    }

  s.excluded = vm_alloc(MAX_EXCLUDED * sizeof(range));
  EnterCriticalSection(&live_lock);
  size_t cap = live_count + 1;
  s.blocks = vm_alloc(cap * sizeof(sblock));
  s.work = vm_alloc(cap * sizeof(uint32_t));
  if (s.blocks == NULL || s.work == NULL || s.excluded == NULL)
    goto out_unlocked_live;

  /* stop the world */
  for (int i = 0; i < nthreads; i++)
    threads[i].suspended = SuspendThread(threads[i].handle) != (DWORD)-1;

  for (size_t i = 0; i < live_cap; i++)
    if (live[i].address > DELETED && s.count < cap)
      {
        sblock *b = &s.blocks[s.count++];
        b->address = live[i].address;
        b->size = live[i].size;
        b->stack = live[i].stack;
        b->class_name = live[i].class_name;
        b->marked = 0;
        live_bytes += live[i].size;
      }
  qsort(s.blocks, s.count, sizeof(sblock), compare_blocks);
  if (s.count)
    {
      s.lo = s.blocks[0].address;
      s.hi = s.blocks[s.count - 1].address + s.blocks[s.count - 1].size;
    }

  /* what is not a root */
  uint64_t lo, hi;
  gspw_agent_image(&lo, &hi);
  exclude(&s, lo, hi);
  exclude_vm(&s, live, live_cap * sizeof(live_block));
  exclude_vm(&s, s.blocks, cap * sizeof(sblock));
  exclude_vm(&s, s.work, cap * sizeof(uint32_t));
  exclude_vm(&s, s.excluded, MAX_EXCLUDED * sizeof(range));
  reservation_of((uint64_t)(uintptr_t)&s, &lo, &hi);
  if (stack_top == NULL)
    exclude(&s, lo, hi);
  else
    exclude(&s, lo, (uint64_t)(uintptr_t)stack_top);

  /* registers, and the dead part of each stack */
  for (int i = 0; i < nthreads; i++)
    {
      CONTEXT ctx;
      if (!threads[i].suspended)
        continue;
      memset(&ctx, 0, sizeof(ctx));
      ctx.ContextFlags = CONTEXT_INTEGER | CONTEXT_CONTROL;
      if (!GetThreadContext(threads[i].handle, &ctx))
        continue;
      reservation_of(ctx.Rsp, &lo, &hi);
      if (threads[i].agent)
        {
          exclude(&s, lo, hi);
          continue;
        }
      exclude(&s, lo, ctx.Rsp);
      uint64_t regs[] = { ctx.Rax, ctx.Rbx, ctx.Rcx, ctx.Rdx, ctx.Rsi, ctx.Rdi,
                          ctx.Rbp, ctx.R8, ctx.R9, ctx.R10, ctx.R11, ctx.R12,
                          ctx.R13, ctx.R14, ctx.R15 };
      for (size_t r = 0; r < sizeof(regs) / sizeof(regs[0]); r++)
        consider(&s, regs[r]);
    }
  drain(&s);
  qsort(s.excluded, s.excluded_count, sizeof(range), compare_ranges);

  /* every writable committed region */
  {
    uint8_t *p = (uint8_t *)(uintptr_t)0x10000;
    MEMORY_BASIC_INFORMATION mbi;
    while (VirtualQuery(p, &mbi, sizeof(mbi)) != 0)
      {
        uint8_t *next = (uint8_t *)mbi.BaseAddress + mbi.RegionSize;
        if (mbi.State == MEM_COMMIT && writable(mbi.Protect))
          scan_region(&s, (uint64_t)(uintptr_t)mbi.BaseAddress, (uint64_t)(uintptr_t)next);
        if (next <= p)
          break;
        p = next;
      }
  }

  for (int i = 0; i < nthreads; i++)
    if (threads[i].suspended)
      ResumeThread(threads[i].handle);
  LeaveCriticalSection(&live_lock);

  {
    gsp_leak_summary_payload sum = { s.count, live_bytes, 0 };
    gspw_emit(GSP_REC_LEAK_BEGIN, ordinal, 0, t0, self, &sum, sizeof(sum), NULL, 0);
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
        gspw_emit(GSP_REC_LEAK, ordinal, 0, t0, self, &lp, sizeof(lp), NULL, 0);
        leak_count++;
        leak_bytes += lp.size;
      }
  {
    gsp_leak_summary_payload sum = { leak_count, leak_bytes, (gspw_now() - t0) / 1000 };
    gspw_emit(GSP_REC_LEAK_END, ordinal, 0, gspw_now(), self, &sum, sizeof(sum), NULL, 0);
  }
  goto out;

out_unlocked_live:
  LeaveCriticalSection(&live_lock);
out:
  for (int i = 0; i < nthreads; i++)
    CloseHandle(threads[i].handle);
  vm_free(s.blocks);
  vm_free(s.work);
  vm_free(s.excluded);
  LeaveCriticalSection(&scan_lock);
}
