/* gsp_agent_win.c - the recording agent on Windows (gsperf-agent.dll).

   The recorder starts the target suspended and loads this DLL into it
   with a remote LoadLibraryW thread.  When GSP_OUTPUT is set, DllMain
   opens events-<pid>.bin and starts one sampler thread.  To attach to a
   running program the recorder loads the DLL the same way and then calls
   gsp_agent_attach in another remote thread.  The sampler thread:

   - every interval (1 ms), for each thread whose CPU cycle count moved,
     suspends it, unwinds its stack with RtlVirtualUnwind and resumes it
     (Windows has no asynchronous signals, so sampling is done from
     outside the thread, as Windows profilers do);
   - every wall interval (10 ms) samples the main thread regardless of
     state, for the Hangs analysis;
   - records loaded modules and, when the Objective-C class list grows,
     the method table (GNUstep's DLLs carry no symbols for methods);
   - signals Local\gsperf-ready-<pid> once it runs (the recorder keeps
     the target suspended until then);
   - stops when the recorder signals the named event
     Local\gsperf-stop-<pid>, then writes END and events-<pid>.done.

   While another thread is suspended the sampler must not take any lock
   that thread could hold (heap, loader): the walk reads only the stack and
   the modules' own unwind tables, and records are written after resuming.

   Allocations (heap and Objective-C allocation hooks) are in
   gsp_heap_win.c, the Leaks scan in gsp_leaks_win.c.

   Signposts and os_log go through the same entry points as on Linux
   (gsp_agent_signpost, called by gsperf.dll); there are no signal
   handlers here, so a critical section protects the output.  */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <mmsystem.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "GSPerformance/gsp_format.h"
#include "gsp_agent_win.h"

#define GSP_EXPORT __declspec(dllexport)
#define MAX_FRAMES 128
#define MAX_THREADS 1024

typedef struct sampled_thread
{
  DWORD tid;
  HANDLE handle;
  ULONG64 cycles;
  bool named;
  bool alive;
} sampled_thread;

static HANDLE out_file = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION out_lock;
static uint8_t out_buf[256 * 1024];
static size_t out_used;
static char out_dir[1024];
static DWORD self_pid;
static DWORD main_tid;
static DWORD sampler_tid;
static DWORD meta_thread_id;
static HANDLE meta_thread;
static HANDLE stop_event;
static volatile LONG recording;
static volatile LONG finished;
static LARGE_INTEGER qpc_freq;
static unsigned sample_interval_us = 1000;
static unsigned wall_interval_us = 10000;
static unsigned leak_interval_s;
static bool cpu_sampling = true, wall_sampling = true, signposts_on = true;
static double cycles_per_interval;
static sampled_thread threads[MAX_THREADS];
static int thread_count;

/* ------------------------------------------------------------------ */
/* time and output                                                     */

static uint64_t
now_ns(void)
{
  LARGE_INTEGER c;
  QueryPerformanceCounter(&c);
  return (uint64_t)((double)c.QuadPart * 1e9 / (double)qpc_freq.QuadPart);
}

static void
write_all(const void *p, size_t len)
{
  const uint8_t *c = p;
  while (len > 0 && out_file != INVALID_HANDLE_VALUE)
    {
      DWORD n = 0;
      if (!WriteFile(out_file, c, (DWORD)(len > 1u << 30 ? 1u << 30 : len), &n, NULL) || n == 0)
        return;
      c += n;
      len -= n;
    }
}

static void
flush_locked(void)
{
  if (out_used)
    {
      write_all(out_buf, out_used);
      out_used = 0;
    }
}

static void
emit(uint16_t type, uint32_t aux, uint16_t flags, uint64_t time, uint32_t tid,
     const void *a, size_t alen, const void *b, size_t blen)
{
  static const uint8_t zeros[8];
  size_t raw = sizeof(gsp_record) + alen + blen;
  size_t total = GSP_RECORD_ALIGN(raw);
  gsp_record h = { type, flags, (uint32_t)total, time, tid, aux };

  EnterCriticalSection(&out_lock);
  if (out_file == INVALID_HANDLE_VALUE)
    {
      LeaveCriticalSection(&out_lock);
      return;
    }
  if (total > sizeof(out_buf) - out_used)
    flush_locked();
  if (total > sizeof(out_buf))
    {
      write_all(&h, sizeof(h));
      write_all(a, alen);
      write_all(b, blen);
      write_all(zeros, total - raw);
    }
  else
    {
      memcpy(out_buf + out_used, &h, sizeof(h));
      if (alen)
        memcpy(out_buf + out_used + sizeof(h), a, alen);
      if (blen)
        memcpy(out_buf + out_used + sizeof(h) + alen, b, blen);
      memset(out_buf + out_used + raw, 0, total - raw);
      out_used += total;
    }
  LeaveCriticalSection(&out_lock);
}

/* ------------------------------------------------------------------ */
/* strings                                                             */

typedef struct str_node
{
  struct str_node *next;
  uint32_t id;
  uint32_t len;
  char text[];
} str_node;

static str_node *str_buckets[4096];
static uint32_t next_string = 1;
static CRITICAL_SECTION str_lock;

static uint32_t
intern(const char *s)
{
  uint32_t h = 2166136261u, len = (uint32_t)strlen(s);
  for (uint32_t i = 0; i < len; i++)
    h = (h ^ (uint8_t)s[i]) * 16777619u;
  EnterCriticalSection(&str_lock);
  for (str_node *n = str_buckets[h & 4095]; n; n = n->next)
    if (n->len == len && memcmp(n->text, s, len) == 0)
      {
        uint32_t id = n->id;
        LeaveCriticalSection(&str_lock);
        return id;
      }
  str_node *n = HeapAlloc(GetProcessHeap(), 0, sizeof(*n) + len + 1);
  if (n == NULL)
    {
      LeaveCriticalSection(&str_lock);
      return 0;
    }
  n->id = next_string++;
  n->len = len;
  memcpy(n->text, s, len + 1);
  n->next = str_buckets[h & 4095];
  str_buckets[h & 4095] = n;
  LeaveCriticalSection(&str_lock);
  emit(GSP_REC_STRING, n->id, 0, now_ns(), GetCurrentThreadId(), s, len + 1, NULL, 0);
  return n->id;
}

/* ------------------------------------------------------------------ */
/* modules                                                             */

static uintptr_t emitted_modules[2048];
static int emitted_module_count;

static void
emit_new_modules(void)
{
  HMODULE mods[2048];
  DWORD needed = 0;

  if (!K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed))
    return;
  int n = (int)(needed / sizeof(HMODULE));
  if (n > 2048)
    n = 2048;
  for (int i = 0; i < n; i++)
    {
      bool known = false;
      for (int k = 0; k < emitted_module_count; k++)
        if (emitted_modules[k] == (uintptr_t)mods[i])
          known = true;
      if (known || emitted_module_count >= 2048)
        continue;
      MODULEINFO mi;
      WCHAR wpath[MAX_PATH];
      char path[MAX_PATH * 3];
      if (!K32GetModuleInformation(GetCurrentProcess(), mods[i], &mi, sizeof(mi)))
        continue;
      DWORD len = GetModuleFileNameW(mods[i], wpath, MAX_PATH);
      if (len == 0)
        continue;
      WideCharToMultiByte(CP_UTF8, 0, wpath, (int)len + 1, path, sizeof(path), NULL, NULL);
      for (char *c = path; *c; c++)
        if (*c == '\\')
          *c = '/';
      gsp_image_payload p = { (uint64_t)(uintptr_t)mi.lpBaseOfDll,
                              (uint64_t)(uintptr_t)mi.lpBaseOfDll,
                              (uint64_t)(uintptr_t)mi.lpBaseOfDll + mi.SizeOfImage };
      emit(GSP_REC_IMAGE, 0, 0, now_ns(), GetCurrentThreadId(), &p, sizeof(p),
           path, strlen(path) + 1);
      emitted_modules[emitted_module_count++] = (uintptr_t)mods[i];
    }
}

/* ------------------------------------------------------------------ */
/* Objective-C method table                                            */

typedef void *Class;
typedef void *Method;
typedef void *SEL;
static int (*p_getClassList)(Class *, int);
static Method *(*p_copyMethodList)(Class, unsigned *);
static SEL (*p_methodName)(Method);
static void *(*p_methodImp)(Method);
static const char *(*p_className)(Class);
static const char *(*p_selName)(SEL);
static Class (*p_objectGetClass)(void *);
static void (*p_free)(void *);
static int last_class_count = -1;
static uint64_t *dumped_imps;
static size_t dumped_count, dumped_cap;

static bool
resolve_objc(void)
{
  if (p_getClassList)
    return true;
  HMODULE mods[2048];
  DWORD needed = 0;
  if (!K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed))
    return false;
  for (DWORD i = 0; i < needed / sizeof(HMODULE) && i < 2048; i++)
    {
      FARPROC f = GetProcAddress(mods[i], "objc_getClassList");
      if (f == NULL)
        continue;
      p_copyMethodList = (void *)GetProcAddress(mods[i], "class_copyMethodList");
      p_methodName = (void *)GetProcAddress(mods[i], "method_getName");
      p_methodImp = (void *)GetProcAddress(mods[i], "method_getImplementation");
      p_className = (void *)GetProcAddress(mods[i], "class_getName");
      p_selName = (void *)GetProcAddress(mods[i], "sel_getName");
      p_objectGetClass = (void *)GetProcAddress(mods[i], "object_getClass");
      if (p_copyMethodList && p_methodName && p_methodImp && p_className
          && p_selName && p_objectGetClass)
        {
          p_getClassList = (void *)f;
          break;
        }
    }
  if (p_getClassList)
    {
      HMODULE crt = GetModuleHandleA("ucrtbase.dll");
      if (crt == NULL)
        crt = GetModuleHandleA("msvcrt.dll");
      if (crt)
        p_free = (void *)GetProcAddress(crt, "free");
    }
  return p_getClassList != NULL;
}

/* open-addressing set of implementation addresses already written */
static bool
mark_imp(uint64_t imp)
{
  if ((dumped_count + 1) * 2 > dumped_cap)
    {
      size_t ncap = dumped_cap ? dumped_cap * 2 : 16384;
      uint64_t *n = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, ncap * sizeof(uint64_t));
      if (n == NULL)
        return true;
      for (size_t i = 0; i < dumped_cap; i++)
        if (dumped_imps[i])
          {
            size_t j = (size_t)((dumped_imps[i] * 0x9E3779B97F4A7C15ull) >> 20) & (ncap - 1);
            while (n[j])
              j = (j + 1) & (ncap - 1);
            n[j] = dumped_imps[i];
          }
      if (dumped_imps)
        HeapFree(GetProcessHeap(), 0, dumped_imps);
      dumped_imps = n;
      dumped_cap = ncap;
    }
  size_t j = (size_t)((imp * 0x9E3779B97F4A7C15ull) >> 20) & (dumped_cap - 1);
  while (dumped_imps[j])
    {
      if (dumped_imps[j] == imp)
        return false;
      j = (j + 1) & (dumped_cap - 1);
    }
  dumped_imps[j] = imp;
  dumped_count++;
  return true;
}

static void
dump_class(Class cls, char prefix)
{
  unsigned count = 0;
  Method *list = p_copyMethodList(cls, &count);
  const char *cname = p_className(cls);
  char name[1024];

  if (list == NULL)
    return;
  for (unsigned i = 0; i < count; i++)
    {
      void *imp = p_methodImp(list[i]);
      SEL sel = p_methodName(list[i]);
      if (imp == NULL || sel == NULL || !mark_imp((uint64_t)(uintptr_t)imp))
        continue;
      int n = snprintf(name, sizeof(name), "%c[%s %s]", prefix, cname ? cname : "?",
                       p_selName(sel));
      if (n <= 0)
        continue;
      if ((size_t)n >= sizeof(name))
        n = sizeof(name) - 1;
      gsp_method_payload p = { (uint64_t)(uintptr_t)imp };
      emit(GSP_REC_METHOD, 0, 0, now_ns(), 0, &p, sizeof(p), name, (size_t)n + 1);
    }
  if (p_free)
    p_free(list);
}

static void
dump_methods(bool force)
{
  if (!resolve_objc())
    return;
  int count = p_getClassList(NULL, 0);
  if (count <= 0 || (!force && count == last_class_count))
    return;
  last_class_count = count;
  Class *classes = HeapAlloc(GetProcessHeap(), 0, sizeof(Class) * (size_t)count);
  if (classes == NULL)
    return;
  /* exactly `count`: libobjc2 2.x double-frees its enumerator otherwise */
  count = p_getClassList(classes, count);
  for (int i = 0; i < count; i++)
    {
      dump_class(classes[i], '-');
      Class meta = p_objectGetClass(classes[i]);
      if (meta)
        dump_class(meta, '+');
    }
  HeapFree(GetProcessHeap(), 0, classes);
}

/* ------------------------------------------------------------------ */
/* threads and sampling                                                */

static HRESULT (WINAPI *p_GetThreadDescription)(HANDLE, PWSTR *);

static void
refresh_threads(void)
{
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  THREADENTRY32 te;

  if (snap == INVALID_HANDLE_VALUE)
    return;
  for (int i = 0; i < thread_count; i++)
    threads[i].alive = false;
  te.dwSize = sizeof(te);
  if (Thread32First(snap, &te))
    do
      {
        if (te.th32OwnerProcessID != self_pid || te.th32ThreadID == sampler_tid
            || te.th32ThreadID == meta_thread_id)
          continue;
        int i;
        for (i = 0; i < thread_count; i++)
          if (threads[i].tid == te.th32ThreadID)
            break;
        if (i == thread_count)
          {
            if (thread_count >= MAX_THREADS)
              continue;
            HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT
                                  | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
            if (h == NULL)
              continue;
            threads[i].tid = te.th32ThreadID;
            threads[i].handle = h;
            threads[i].cycles = 0;
            QueryThreadCycleTime(h, &threads[i].cycles);
            threads[i].named = false;
            thread_count++;
          }
        threads[i].alive = true;
      }
    while (Thread32Next(snap, &te));
  CloseHandle(snap);

  for (int i = 0; i < thread_count;)
    {
      if (threads[i].alive)
        {
          if (!threads[i].named)
            {
              char name[128] = "";
              PWSTR w = NULL;
              if (p_GetThreadDescription
                  && SUCCEEDED(p_GetThreadDescription(threads[i].handle, &w)) && w)
                {
                  WideCharToMultiByte(CP_UTF8, 0, w, -1, name, sizeof(name), NULL, NULL);
                  LocalFree(w);
                }
              emit(GSP_REC_THREAD, threads[i].tid == main_tid ? GSP_THREAD_MAIN : 0, 0,
                   now_ns(), threads[i].tid, name, strlen(name) + 1, NULL, 0);
              threads[i].named = true;
            }
          i++;
          continue;
        }
      emit(GSP_REC_THREAD_END, 0, 0, now_ns(), threads[i].tid, NULL, 0, NULL, 0);
      CloseHandle(threads[i].handle);
      threads[i] = threads[--thread_count];
    }
}

/* Unwind data of the loaded modules, for lookups while a thread is
   suspended.  RtlLookupFunctionEntry cannot be used then: it takes the
   loader's function table lock, which the suspended thread may hold (while
   loading a DLL), and the sampler would wait for it forever.  Only the
   sampler thread reads and rebuilds this table.  */
typedef struct code_module
{
  uintptr_t base, end;
  const RUNTIME_FUNCTION *funcs;
  DWORD count;
} code_module;

#define MAX_CODE_MODULES 1024
static code_module code_modules[MAX_CODE_MODULES];
static int code_module_count;

static int
compare_code_modules(const void *a, const void *b)
{
  const code_module *x = a, *y = b;
  return x->base < y->base ? -1 : x->base > y->base;
}

static void
refresh_code_modules(void)
{
  static HMODULE mods[MAX_CODE_MODULES];
  DWORD needed = 0;
  int n = 0;

  if (!K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed))
    return;
  int count = (int)(needed / sizeof(HMODULE));
  if (count > MAX_CODE_MODULES)
    count = MAX_CODE_MODULES;
  for (int i = 0; i < count; i++)
    {
      uint8_t *base = (uint8_t *)mods[i];
      IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
      if (dos->e_magic != IMAGE_DOS_SIGNATURE)
        continue;
      IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
      if (nt->Signature != IMAGE_NT_SIGNATURE
          || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC)
        continue;
      code_module *m = &code_modules[n++];
      m->base = (uintptr_t)base;
      m->end = m->base + nt->OptionalHeader.SizeOfImage;
      m->funcs = NULL;
      m->count = 0;
      if (nt->OptionalHeader.NumberOfRvaAndSizes > IMAGE_DIRECTORY_ENTRY_EXCEPTION)
        {
          IMAGE_DATA_DIRECTORY d = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
          if (d.VirtualAddress && d.Size >= sizeof(RUNTIME_FUNCTION))
            {
              m->funcs = (const RUNTIME_FUNCTION *)(base + d.VirtualAddress);
              m->count = d.Size / sizeof(RUNTIME_FUNCTION);
            }
        }
    }
  qsort(code_modules, (size_t)n, sizeof(code_module), compare_code_modules);
  code_module_count = n;
}

/* RtlLookupFunctionEntry without locks: modules' .pdata only (code
   generated at run time is unwound as a leaf).  */
static PRUNTIME_FUNCTION
lookup_function(uintptr_t pc, uintptr_t *image)
{
  int lo = 0, hi = code_module_count - 1;
  const code_module *m = NULL;
  while (lo <= hi)
    {
      int mid = (lo + hi) / 2;
      if (pc < code_modules[mid].base)
        hi = mid - 1;
      else if (pc >= code_modules[mid].end)
        lo = mid + 1;
      else
        {
          m = &code_modules[mid];
          break;
        }
    }
  if (m == NULL || m->funcs == NULL)
    return NULL;
  DWORD rva = (DWORD)(pc - m->base);
  size_t a = 0, b = m->count;
  while (a < b)
    {
      size_t mid = (a + b) / 2;
      if (rva < m->funcs[mid].BeginAddress)
        b = mid;
      else if (rva >= m->funcs[mid].EndAddress)
        a = mid + 1;
      else
        {
          *image = m->base;
          return (PRUNTIME_FUNCTION)&m->funcs[mid];
        }
    }
  return NULL;
}

/* Walks a suspended thread's stack.  No locks, no allocation.  */
static unsigned
walk(HANDLE h, uint64_t *frames, unsigned max)
{
  CONTEXT ctx;
  unsigned n = 0;

  memset(&ctx, 0, sizeof(ctx));
  ctx.ContextFlags = CONTEXT_FULL;
  if (!GetThreadContext(h, &ctx))
    return 0;
  while (n < max && ctx.Rip != 0)
    {
      frames[n++] = ctx.Rip;
      uintptr_t image = 0;
      PRUNTIME_FUNCTION fe = lookup_function(ctx.Rip, &image);
      if (fe != NULL)
        {
          PVOID handler_data = NULL;
          DWORD64 establisher = 0;
          RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, ctx.Rip, fe, &ctx,
                           &handler_data, &establisher, NULL);
        }
      else
        {
          /* leaf function without unwind data: return address on top */
          if (ctx.Rsp == 0 || (ctx.Rsp & 7))
            break;
          MEMORY_BASIC_INFORMATION mbi;
          if (VirtualQuery((LPCVOID)ctx.Rsp, &mbi, sizeof(mbi)) == 0
              || mbi.State != MEM_COMMIT)
            break;
          ctx.Rip = *(DWORD64 *)ctx.Rsp;
          ctx.Rsp += 8;
        }
    }
  return n;
}

static void
sample_thread(sampled_thread *t, uint32_t kind, uint16_t weight)
{
  uint64_t buf[2 + MAX_FRAMES];
  gsp_frames_payload *fp = (gsp_frames_payload *)buf;
  uint64_t when;
  unsigned n;

  if (SuspendThread(t->handle) == (DWORD)-1)
    return;
  when = now_ns();
  n = walk(t->handle, buf + 1, MAX_FRAMES);
  ResumeThread(t->handle);
  if (n == 0)
    return;
  fp->count = n;
  fp->kernel_count = 0;
  fp->weight = weight;
  emit(GSP_REC_SAMPLE, kind, n >= MAX_FRAMES ? GSP_FRAMES_TRUNCATED : 0, when, t->tid,
       buf, sizeof(*fp) + n * 8, NULL, 0);
}

/* Cycles per sampling interval.  QueryThreadCycleTime counts at the
   processor's nominal rate, which the registry records; measuring it
   instead would delay the first sample.  */
static void
calibrate(void)
{
  HKEY key;
  DWORD mhz = 0, size = sizeof(mhz);

  if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                    0, KEY_READ, &key) == ERROR_SUCCESS)
    {
      if (RegQueryValueExA(key, "~MHz", NULL, NULL, (LPBYTE)&mhz, &size) != ERROR_SUCCESS)
        mhz = 0;
      RegCloseKey(key);
    }
  if (mhz != 0)
    cycles_per_interval = (double)mhz * sample_interval_us;
  else
    {
      ULONG64 c0 = 0, c1 = 0;
      uint64_t t0 = now_ns();
      QueryThreadCycleTime(GetCurrentThread(), &c0);
      while (now_ns() - t0 < 5000000)
        ;
      QueryThreadCycleTime(GetCurrentThread(), &c1);
      cycles_per_interval = (double)(c1 - c0) / (double)(now_ns() - t0)
        * sample_interval_us * 1000.0;
    }
  if (cycles_per_interval < 1)
    cycles_per_interval = 1;
}

/* Module list and Objective-C method table, once a second, on their own
   thread: a large method dump must not stall sampling.  */
static DWORD WINAPI
meta_main(LPVOID arg)
{
  (void)arg;
  gspw_heap_exclude_thread();
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
  do
    {
      gspw_heap_patch_modules();
      emit_new_modules();
      dump_methods(false);
    }
  while (WaitForSingleObject(stop_event, 1000) == WAIT_TIMEOUT);
  return 0;
}

static void
finish(void)
{
  if (meta_thread)
    WaitForSingleObject(meta_thread, 10000);
  /* stopped by the recorder while the program runs: a last leak check */
  if (!finished && gspw_leaks_enabled() && !gspw_exit_snapshot_taken())
    gspw_leaks_snapshot(NULL);
  if (InterlockedExchange(&finished, 1))
    return;
  InterlockedExchange(&recording, 0);
  emit_new_modules();
  dump_methods(true);
  emit(GSP_REC_END, 0, 0, now_ns(), self_pid, NULL, 0, NULL, 0);
  EnterCriticalSection(&out_lock);
  flush_locked();
  FlushFileBuffers(out_file);
  CloseHandle(out_file);
  out_file = INVALID_HANDLE_VALUE;
  LeaveCriticalSection(&out_lock);

  char done[1100];
  snprintf(done, sizeof(done), "%s/events-%lu.done", out_dir, (unsigned long)self_pid);
  HANDLE d = CreateFileA(done, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (d != INVALID_HANDLE_VALUE)
    CloseHandle(d);
}

static DWORD WINAPI
sampler_main(LPVOID arg)
{
  uint64_t next_wall = 0, next_scan = 0, next_flush = 0, next_leak = UINT64_MAX;

  (void)arg;
  gspw_heap_exclude_thread();
  timeBeginPeriod(1);
  calibrate();
  refresh_threads();
  refresh_code_modules();
  if (leak_interval_s && gspw_leaks_enabled())
    next_leak = now_ns() + (uint64_t)leak_interval_s * 1000000000ull;
  /* The recorder resumes the target when this is set.  */
  WCHAR rname[64];
  swprintf(rname, 64, L"Local\\gsperf-ready-%lu", (unsigned long)self_pid);
  HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, rname);
  if (ready)
    {
      SetEvent(ready);
      CloseHandle(ready);
    }
  for (;;)
    {
      DWORD w = WaitForSingleObject(stop_event, sample_interval_us >= 2000
                                    ? sample_interval_us / 1000 : 1);
      if (w == WAIT_OBJECT_0)
        break;
      uint64_t now = now_ns();
      if (now >= next_scan)
        {
          refresh_threads();
          refresh_code_modules();
          next_scan = now + 100000000ull;
        }
      bool wall = wall_sampling && now >= next_wall;
      if (wall)
        next_wall = now + (uint64_t)wall_interval_us * 1000;
      for (int i = 0; i < thread_count; i++)
        {
          sampled_thread *t = &threads[i];
          ULONG64 c = 0;
          if (cpu_sampling && QueryThreadCycleTime(t->handle, &c) && c > t->cycles)
            {
              double intervals = (double)(c - t->cycles) / cycles_per_interval;
              uint16_t weight = intervals < 1 ? 1
                : (intervals > 65535 ? 65535 : (uint16_t)(intervals + 0.5));
              t->cycles = c;
              sample_thread(t, GSP_SAMPLE_CPU, weight);
            }
          if (wall && t->tid == main_tid)
            sample_thread(t, GSP_SAMPLE_WALL, 1);
        }
      if (now >= next_leak)
        {
          gspw_leaks_snapshot(NULL);
          next_leak = now_ns() + (uint64_t)leak_interval_s * 1000000000ull;
        }
      if (now >= next_flush)
        {
          EnterCriticalSection(&out_lock);
          flush_locked();
          LeaveCriticalSection(&out_lock);
          next_flush = now + 50000000ull;
        }
    }
  timeEndPeriod(1);
  finish();
  return 0;
}

/* ------------------------------------------------------------------ */
/* for the other parts of the agent                                    */

void
gspw_emit(uint16_t type, uint32_t aux, uint16_t flags, uint64_t time, uint32_t tid,
          const void *a, size_t alen, const void *b, size_t blen)
{
  emit(type, aux, flags, time, tid, a, alen, b, blen);
}

uint32_t
gspw_intern(const char *s)
{
  return intern(s);
}

uint64_t
gspw_now(void)
{
  return now_ns();
}

bool
gspw_recording(void)
{
  return recording && !finished;
}

void
gspw_flush(void)
{
  EnterCriticalSection(&out_lock);
  flush_locked();
  LeaveCriticalSection(&out_lock);
}

bool
gspw_is_agent_thread(unsigned long tid)
{
  return tid == sampler_tid || tid == meta_thread_id;
}

/* ------------------------------------------------------------------ */
/* signposts (called by gsperf.dll)                                    */

GSP_EXPORT int
gsp_agent_signposts_enabled(void)
{
  return recording && signposts_on && !finished;
}

GSP_EXPORT void
gsp_agent_signpost(int record_type, int kind, uint64_t spid, const char *subsystem,
                   const char *category, const char *name, const char *message,
                   size_t length)
{
  gsp_signpost_payload p;
  char buf[1100];

  if (!gsp_agent_signposts_enabled())
    return;
  p.signpost_id = spid;
  p.subsystem = intern(subsystem ? subsystem : "");
  p.category = intern(category ? category : "");
  p.name = intern(name ? name : "");
  if (length > sizeof(buf) - 1)
    length = sizeof(buf) - 1;
  if (length)
    memcpy(buf, message, length);
  buf[length] = 0;
  p.message_length = (uint32_t)length;
  emit((uint16_t)record_type, (uint32_t)kind, 0, now_ns(), GetCurrentThreadId(),
       &p, sizeof(p), buf, length + 1);
}

/* ------------------------------------------------------------------ */
/* start-up                                                            */

/* Settings come from the environment when the recorder launched the
   program, and from the text the recorder put in the shared memory
   Local\gsperf-config-<pid> ("NAME=value" lines) when it attached.  */
static char *attach_config;

static DWORD
config_get(const char *name, char *out, DWORD cap)
{
  if (attach_config == NULL)
    return GetEnvironmentVariableA(name, out, cap);
  size_t nl = strlen(name);
  for (const char *line = attach_config; *line;)
    {
      const char *end = strchr(line, '\n');
      size_t len = end ? (size_t)(end - line) : strlen(line);
      if (len > nl && line[nl] == '=' && strncmp(line, name, nl) == 0)
        {
          size_t vlen = len - nl - 1;
          if (vlen + 1 > cap)
            return (DWORD)(vlen + 1);
          memcpy(out, line + nl + 1, vlen);
          out[vlen] = 0;
          return (DWORD)vlen;
        }
      line = end ? end + 1 : line + len;
    }
  return 0;
}

static bool
env_flag(const char *name, bool fallback)
{
  char v[16];
  DWORD n = config_get(name, v, sizeof(v));
  if (n == 0 || n >= sizeof(v))
    return fallback;
  return !(strcmp(v, "0") == 0 || _stricmp(v, "no") == 0 || _stricmp(v, "false") == 0);
}

static unsigned
env_uint(const char *name, unsigned fallback)
{
  char v[32];
  DWORD n = config_get(name, v, sizeof(v));
  return (n == 0 || n >= sizeof(v)) ? fallback : (unsigned)strtoul(v, NULL, 10);
}

/* The main thread is the oldest thread of the process (at injection time
   it is still suspended, and the loader thread running DllMain is newer). */
static DWORD
find_main_thread(void)
{
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  THREADENTRY32 te;
  DWORD best = 0;
  ULONGLONG best_time = ~0ull;

  if (snap == INVALID_HANDLE_VALUE)
    return 0;
  te.dwSize = sizeof(te);
  if (Thread32First(snap, &te))
    do
      {
        if (te.th32OwnerProcessID != self_pid)
          continue;
        HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, te.th32ThreadID);
        FILETIME c, e, k, u;
        if (h && GetThreadTimes(h, &c, &e, &k, &u))
          {
            ULONGLONG t = ((ULONGLONG)c.dwHighDateTime << 32) | c.dwLowDateTime;
            if (t < best_time)
              {
                best_time = t;
                best = te.th32ThreadID;
              }
          }
        if (h)
          CloseHandle(h);
      }
    while (Thread32Next(snap, &te));
  CloseHandle(snap);
  return best;
}

static void
start(void)
{
  char exe[MAX_PATH * 3] = "";
  WCHAR wexe[MAX_PATH];
  gsp_file_header hdr;
  char path[1200];

  DWORD n = config_get("GSP_OUTPUT", out_dir, sizeof(out_dir));
  if (n == 0 || n >= sizeof(out_dir))
    return;
  /* Children do not inherit recording.  */
  if (attach_config == NULL)
    SetEnvironmentVariableA("GSP_OUTPUT", NULL);
  cpu_sampling = env_flag("GSP_CPU_SAMPLING", true);
  wall_sampling = env_flag("GSP_WALL_SAMPLING", true);
  signposts_on = env_flag("GSP_SIGNPOSTS", true);
  sample_interval_us = env_uint("GSP_SAMPLE_INTERVAL_US", 1000);
  if (sample_interval_us < 1000)
    sample_interval_us = 1000;
  wall_interval_us = env_uint("GSP_WALL_INTERVAL_US", 10000);

  QueryPerformanceFrequency(&qpc_freq);
  InitializeCriticalSection(&out_lock);
  InitializeCriticalSection(&str_lock);
  self_pid = GetCurrentProcessId();
  main_tid = find_main_thread();
  p_GetThreadDescription = (void *)GetProcAddress(GetModuleHandleA("kernel32.dll"),
                                                  "GetThreadDescription");

  snprintf(path, sizeof(path), "%s/events-%lu.bin", out_dir, (unsigned long)self_pid);
  out_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  if (out_file == INVALID_HANDLE_VALUE)
    return;

  memset(&hdr, 0, sizeof(hdr));
  memcpy(hdr.magic, GSP_MAGIC, 8);
  hdr.version = GSP_FORMAT_VERSION;
  hdr.header_size = sizeof(hdr);
  hdr.pid = self_pid;
  hdr.start_ns = now_ns();
  FILETIME ft;
  GetSystemTimeAsFileTime(&ft);
  hdr.start_realtime_ns = ((((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime)
                           - 116444736000000000ull) * 100;
  hdr.pointer_size = sizeof(void *);
  hdr.flags = GSP_STREAM_FROM_AGENT;
  hdr.sample_interval_us = cpu_sampling ? sample_interval_us : 0;
  hdr.wall_interval_us = wall_sampling ? wall_interval_us : 0;
  DWORD len = GetModuleFileNameW(NULL, wexe, MAX_PATH);
  WideCharToMultiByte(CP_UTF8, 0, wexe, (int)len + 1, exe, sizeof(exe), NULL, NULL);
  for (char *c = exe; *c; c++)
    if (*c == '\\')
      *c = '/';
  snprintf(hdr.exe, sizeof(hdr.exe), "%s", exe);
  write_all(&hdr, sizeof(hdr));

  WCHAR ename[64];
  swprintf(ename, 64, L"Local\\gsperf-stop-%lu", (unsigned long)self_pid);
  stop_event = CreateEventW(NULL, TRUE, FALSE, ename);
  InterlockedExchange(&recording, 1);
  emit(GSP_REC_MARK, GSP_MARK_START, 0, hdr.start_ns, self_pid, NULL, 0, NULL, 0);
  emit_new_modules();
  gspw_leaks_start(env_flag("GSP_LEAKS", false));
  gspw_io_start(env_flag("GSP_FILE_IO", false), env_flag("GSP_NETWORK", false));
  leak_interval_s = env_uint("GSP_LEAK_INTERVAL", 0);
  gspw_heap_start(env_flag("GSP_ALLOCATIONS", false) || env_flag("GSP_LEAKS", false),
                  env_flag("GSP_REFCOUNTS", false), env_flag("GSP_ZOMBIES", false),
                  env_uint("GSP_ALLOC_FRAMES", 48));
  HANDLE sampler_thread = CreateThread(NULL, 0, sampler_main, NULL, 0, &sampler_tid);
  if (sampler_thread)
    CloseHandle(sampler_thread);
  DWORD meta_tid = 0;
  meta_thread = CreateThread(NULL, 0, meta_main, NULL, 0, &meta_tid);
  meta_thread_id = meta_tid;
}

/* Attaching: the recorder loads the DLL into the running program, then
   runs this in a remote thread (outside the loader lock).  Returns 0 when
   recording started, 1 without a configuration, 2 when this process was
   already recorded (the agent's state is per process; the program must
   be restarted to record it again).  */
GSP_EXPORT DWORD WINAPI
gsp_agent_attach(LPVOID arg)
{
  static volatile LONG attached;
  char name[64];

  (void)arg;
  if (recording || finished || InterlockedExchange(&attached, 1))
    return 2;
  snprintf(name, sizeof(name), "Local\\gsperf-config-%lu", (unsigned long)GetCurrentProcessId());
  HANDLE m = OpenFileMappingA(FILE_MAP_READ, FALSE, name);
  if (m == NULL)
    return 1;
  const char *view = MapViewOfFile(m, FILE_MAP_READ, 0, 0, 0);
  if (view == NULL)
    {
      CloseHandle(m);
      return 1;
    }
  MEMORY_BASIC_INFORMATION mbi;
  size_t cap = VirtualQuery(view, &mbi, sizeof(mbi)) ? mbi.RegionSize : 4096;
  attach_config = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, cap + 1);
  if (attach_config)
    memcpy(attach_config, view, strnlen(view, cap));
  UnmapViewOfFile(view);
  CloseHandle(m);
  if (attach_config == NULL)
    return 1;
  start();
  return recording ? 0 : 1;
}

BOOL WINAPI
DllMain(HINSTANCE dll, DWORD reason, LPVOID reserved)
{
  (void)dll;
  if (reason == DLL_PROCESS_ATTACH)
    {
      DisableThreadLibraryCalls(dll);
      start();
    }
  else if (reason == DLL_PROCESS_DETACH && recording && !finished)
    {
      /* Process exit: other threads (the sampler too) are gone and may have
         died holding the output lock; finish without waiting on it.  */
      if (reserved != NULL)
        {
          if (TryEnterCriticalSection(&out_lock))
            {
              LeaveCriticalSection(&out_lock);
              emit(GSP_REC_END, 0, 0, now_ns(), self_pid, NULL, 0, NULL, 0);
              EnterCriticalSection(&out_lock);
              flush_locked();
              CloseHandle(out_file);
              out_file = INVALID_HANDLE_VALUE;
              LeaveCriticalSection(&out_lock);
              char done[1100];
              snprintf(done, sizeof(done), "%s/events-%lu.done", out_dir,
                       (unsigned long)self_pid);
              HANDLE d = CreateFileA(done, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                                     FILE_ATTRIBUTE_NORMAL, NULL);
              if (d != INVALID_HANDLE_VALUE)
                CloseHandle(d);
              InterlockedExchange(&finished, 1);
            }
        }
      else
        finish();
    }
  return TRUE;
}
