/* gsp_heap_win.c - the Allocations instrument on Windows.

   There is no LD_PRELOAD on Windows, so the agent patches the import
   address tables of the loaded modules instead: calls to the UCRT heap
   functions (malloc, calloc, realloc, free, _aligned_*, _recalloc,
   _strdup, _wcsdup) and to libobjc2's allocation entry points
   (class_createInstance, objc_alloc, ...) and reference counting
   (objc_retain, objc_release, objc_autorelease) go through a hook that calls the
   original and records the event.  Modules loaded later with LoadLibrary
   are patched when the call returns (LoadLibrary itself is hooked), and
   once a second as a backstop.

   Only imports from the UCRT (ucrtbase.dll, api-ms-win-crt-*) are patched:
   a module using msvcrt.dll has its own heap, and its blocks must not be
   handed to the UCRT functions.  The agent's own module is never patched.

   Blocks allocated before the agent was injected (by the static DLLs'
   initialisers) are unknown; their frees are recorded and ignored by the
   analysis.

   A thread-local flag keeps the hooks from recording the agent's own work
   and is set permanently on the agent's threads.  */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

#include "GSPerformance/gsp_format.h"
#include "gsp_agent_win.h"

#define MAX_ALLOC_FRAMES 62  /* RtlCaptureStackBackTrace limit */

static DWORD guard_tls = TLS_OUT_OF_INDEXES;
static volatile LONG heap_on;
static unsigned alloc_frames = 48;
static HMODULE self_module;
static CRITICAL_SECTION patch_lock;

/* ------------------------------------------------------------------ */
/* re-entrancy guard                                                   */

static inline bool
enter(void)
{
  if (!heap_on || guard_tls == TLS_OUT_OF_INDEXES || !gspw_recording())
    return false;
  DWORD e = GetLastError();
  bool busy = TlsGetValue(guard_tls) != NULL;
  if (!busy)
    TlsSetValue(guard_tls, (LPVOID)1);
  SetLastError(e);
  return !busy;
}

static inline void
leave(void)
{
  DWORD e = GetLastError();
  TlsSetValue(guard_tls, NULL);
  SetLastError(e);
}

void
gspw_heap_exclude_thread(void)
{
  if (guard_tls != TLS_OUT_OF_INDEXES)
    TlsSetValue(guard_tls, (LPVOID)1);
}

/* ------------------------------------------------------------------ */
/* stacks                                                              */

typedef struct stack_entry
{
  uint32_t hash;
  uint32_t id;
  uint32_t count;
  uint64_t *frames;
} stack_entry;

static stack_entry *stacks;
static size_t stack_cap, stack_used;
static uint32_t next_stack = 1;
static CRITICAL_SECTION stack_lock;

static uint32_t
hash_frames(const uint64_t *frames, unsigned n)
{
  uint64_t h = 1469598103934665603ull;
  for (unsigned i = 0; i < n; i++)
    h = (h ^ frames[i]) * 1099511628211ull;
  return (uint32_t)(h ^ (h >> 32)) | 1;
}

static bool
grow_stacks(void)
{
  size_t ncap = stack_cap ? stack_cap * 2 : 65536;
  stack_entry *n = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, ncap * sizeof(*n));
  if (n == NULL)
    return false;
  for (size_t i = 0; i < stack_cap; i++)
    if (stacks[i].hash)
      {
        size_t j = stacks[i].hash & (ncap - 1);
        while (n[j].hash)
          j = (j + 1) & (ncap - 1);
        n[j] = stacks[i];
      }
  if (stacks)
    HeapFree(GetProcessHeap(), 0, stacks);
  stacks = n;
  stack_cap = ncap;
  return true;
}

/* The stack id for a list of frames; a new stack is written to the stream
   (under the lock, so it precedes any record that refers to it).  */
uint32_t
gspw_intern_stack(const uint64_t *frames, unsigned n)
{
  uint32_t h = hash_frames(frames, n), id = 0;

  EnterCriticalSection(&stack_lock);
  if ((stack_used + 1) * 2 > stack_cap && !grow_stacks())
    {
      LeaveCriticalSection(&stack_lock);
      return 0;
    }
  size_t j = h & (stack_cap - 1);
  while (stacks[j].hash)
    {
      if (stacks[j].hash == h && stacks[j].count == n
          && memcmp(stacks[j].frames, frames, n * sizeof(uint64_t)) == 0)
        {
          id = stacks[j].id;
          LeaveCriticalSection(&stack_lock);
          return id;
        }
      j = (j + 1) & (stack_cap - 1);
    }
  uint64_t *copy = HeapAlloc(GetProcessHeap(), 0, (2 + n) * sizeof(uint64_t));
  if (copy != NULL)
    {
      gsp_frames_payload *fp = (gsp_frames_payload *)copy;
      fp->count = n;
      fp->kernel_count = 0;
      fp->weight = 0;
      memcpy(copy + 1, frames, n * sizeof(uint64_t));
      id = next_stack++;
      stacks[j].hash = h;
      stacks[j].id = id;
      stacks[j].count = n;
      stacks[j].frames = copy + 1;
      stack_used++;
      gspw_emit(GSP_REC_STACK, id, 0, gspw_now(), GetCurrentThreadId(),
                copy, sizeof(*fp) + n * sizeof(uint64_t), NULL, 0);
    }
  LeaveCriticalSection(&stack_lock);
  return id;
}

static uintptr_t self_start, self_end;

/* The stack of the code that called a hook.  The agent's frames are left
   out wherever they are: a hook in the middle of a stack (an allocation
   inside class_createInstance) is transparent.  */
static uint32_t
hook_caller_stack(void)
{
  void *pcs[MAX_ALLOC_FRAMES];
  uint64_t frames[MAX_ALLOC_FRAMES];
  USHORT n = RtlCaptureStackBackTrace(0, alloc_frames, pcs, NULL);
  USHORT k = 0;

  for (USHORT i = 0; i < n; i++)
    if ((uintptr_t)pcs[i] < self_start || (uintptr_t)pcs[i] >= self_end)
      frames[k++] = (uint64_t)(uintptr_t)pcs[i];
  return k ? gspw_intern_stack(frames, k) : 0;
}

/* ------------------------------------------------------------------ */
/* recording                                                           */

static void
record_alloc(void *p, size_t size, void *old)
{
  gsp_alloc_payload a;

  a.address = (uint64_t)(uintptr_t)p;
  a.size = size;
  a.stack = hook_caller_stack();
  a.category = 0;
  a.old_address = (uint64_t)(uintptr_t)old;
  gspw_live_insert(p, size, a.stack);
  gspw_emit(GSP_REC_ALLOC, 0, 0, gspw_now(), GetCurrentThreadId(),
            &a, sizeof(a), NULL, 0);
}

static void
record_free(void *p)
{
  gspw_live_take(p, NULL, NULL, NULL);
  gsp_free_payload f = { (uint64_t)(uintptr_t)p, 0, 0 };
  gspw_emit(GSP_REC_FREE, 0, 0, gspw_now(), GetCurrentThreadId(),
            &f, sizeof(f), NULL, 0);
}

/* ------------------------------------------------------------------ */
/* CRT hooks                                                           */

static void *(*real_malloc)(size_t);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static void (*real_free)(void *);
static void *(*real_aligned_malloc)(size_t, size_t);
static void *(*real_aligned_realloc)(void *, size_t, size_t);
static void (*real_aligned_free)(void *);
static void *(*real_recalloc)(void *, size_t, size_t);
static char *(*real_strdup)(const char *);
static char *(*real_strdup2)(const char *);
static wchar_t *(*real_wcsdup)(const wchar_t *);

static void *
hook_malloc(size_t size)
{
  void *p = real_malloc(size);
  if (p && enter())
    {
      record_alloc(p, size, NULL);
      leave();
    }
  return p;
}

static void *
hook_calloc(size_t n, size_t size)
{
  void *p = real_calloc(n, size);
  if (p && enter())
    {
      record_alloc(p, n * size, NULL);
      leave();
    }
  return p;
}

static void
hook_free(void *p)
{
  if (p && enter())
    {
      record_free(p);
      leave();
    }
  real_free(p);
}

/* realloc, _recalloc (a = count, b = size) and _aligned_realloc.  A size
   of 0 frees the block and returns NULL in the UCRT; on failure the old
   block stays valid, so it goes back into the live table.  */
static void *
realloc_common(void *old, size_t a, size_t b, size_t align, int kind)
{
  size_t size = kind == 1 ? a * b : a;
  bool rec = enter();
  size_t osize = 0;
  uint32_t ostack = 0, oclass = 0;
  bool had = false;

  if (rec && old && size == 0)
    record_free(old);
  else if (rec && old)
    had = gspw_live_take(old, &osize, &ostack, &oclass);
  void *p = kind == 0 ? real_realloc(old, a)
    : kind == 1 ? real_recalloc(old, a, b)
    : real_aligned_realloc(old, a, align);
  if (had && p == NULL)
    gspw_live_put(old, osize, ostack, oclass);
  if (rec && p)
    record_alloc(p, size, old);
  if (rec)
    leave();
  return p;
}

static void *
hook_realloc(void *old, size_t size)
{
  return realloc_common(old, size, size, 0, 0);
}

static void *
hook_recalloc(void *old, size_t n, size_t size)
{
  return realloc_common(old, n, size, 0, 1);
}

static void *
hook_aligned_malloc(size_t size, size_t align)
{
  void *p = real_aligned_malloc(size, align);
  if (p && enter())
    {
      record_alloc(p, size, NULL);
      leave();
    }
  return p;
}

static void *
hook_aligned_realloc(void *old, size_t size, size_t align)
{
  return realloc_common(old, size, size, align, 2);
}

static void
hook_aligned_free(void *p)
{
  if (p && enter())
    {
      record_free(p);
      leave();
    }
  real_aligned_free(p);
}

static char *
hook_strdup(const char *s)
{
  char *p = real_strdup(s);
  if (p && enter())
    {
      record_alloc(p, strlen(p) + 1, NULL);
      leave();
    }
  return p;
}

static char *
hook_strdup2(const char *s)
{
  char *p = real_strdup2(s);
  if (p && enter())
    {
      record_alloc(p, strlen(p) + 1, NULL);
      leave();
    }
  return p;
}

static wchar_t *
hook_wcsdup(const wchar_t *s)
{
  wchar_t *p = real_wcsdup(s);
  if (p && enter())
    {
      record_alloc(p, (wcslen(p) + 1) * sizeof(wchar_t), NULL);
      leave();
    }
  return p;
}

/* ------------------------------------------------------------------ */
/* Objective-C allocation tagging                                      */

typedef void *id;
typedef void *Class;
static Class (*p_object_getClass)(id);
static const char *(*p_class_getName)(Class);
static id (*real_class_createInstance)(Class, size_t);
static id (*real_objc_alloc)(Class);
static id (*real_objc_allocWithZone)(Class);
static id (*real_objc_alloc_init)(Class);

static void
tag_object(id obj)
{
  if (obj == NULL || p_object_getClass == NULL || p_class_getName == NULL
      || !enter())
    return;
  Class cls = p_object_getClass(obj);
  if (cls != NULL)
    {
      gsp_tag_payload t;
      t.address = (uint64_t)(uintptr_t)obj;
      t.class_name = gspw_intern(p_class_getName(cls));
      t.stack = 0;
      gspw_emit(GSP_REC_OBJC_TAG, 0, 0, gspw_now(), GetCurrentThreadId(),
                &t, sizeof(t), NULL, 0);
      gspw_live_tag(obj, t.class_name);
    }
  leave();
}

static id
hook_class_createInstance(Class cls, size_t extra)
{
  id obj = real_class_createInstance(cls, extra);
  tag_object(obj);
  return obj;
}

static id
hook_objc_alloc(Class cls)
{
  id obj = real_objc_alloc(cls);
  tag_object(obj);
  return obj;
}

static id
hook_objc_allocWithZone(Class cls)
{
  id obj = real_objc_allocWithZone(cls);
  tag_object(obj);
  return obj;
}

static id
hook_objc_alloc_init(Class cls)
{
  id obj = real_objc_alloc_init(cls);
  tag_object(obj);
  return obj;
}

/* ------------------------------------------------------------------ */
/* reference counting history and zombies (the Zombies template)       */

typedef void *SEL;
typedef void (*IMP)(void);
static bool refcounts_on, zombies_on;
static id (*real_objc_retain)(id);
static void (*real_objc_release)(id);
static id (*real_objc_autorelease)(id);

static void
record_refcount(id obj, int kind)
{
  /* small objects (tagged pointers) are not allocations */
  if (obj == NULL || !refcounts_on || ((uintptr_t)obj & 7) != 0 || !enter())
    return;
  gsp_refcount_payload p;
  p.address = (uint64_t)(uintptr_t)obj;
  p.stack = hook_caller_stack();
  p.refcount = -1;
  gspw_emit(GSP_REC_REFCOUNT, (uint32_t)kind, 0, gspw_now(), GetCurrentThreadId(),
            &p, sizeof(p), NULL, 0);
  leave();
}

/* objc_release may send -release, which is also hooked (below): the
   object being handled by the C entry point is noted per thread so the
   message is not counted twice.  */
static DWORD rc_tls = TLS_OUT_OF_INDEXES;

static inline void
rc_note(id obj)
{
  DWORD e = GetLastError();
  TlsSetValue(rc_tls, obj);
  SetLastError(e);
}

static inline bool
rc_noted(id obj)
{
  DWORD e = GetLastError();
  bool same = TlsGetValue(rc_tls) == obj;
  if (same)
    TlsSetValue(rc_tls, NULL);
  SetLastError(e);
  return same;
}

static id
hook_objc_retain(id obj)
{
  record_refcount(obj, GSP_RC_RETAIN);
  rc_note(obj);
  id r = real_objc_retain(obj);
  rc_note(NULL);
  return r;
}

static void
hook_objc_release(id obj)
{
  record_refcount(obj, GSP_RC_RELEASE);
  rc_note(obj);
  real_objc_release(obj);
  rc_note(NULL);
}

static id
hook_objc_autorelease(id obj)
{
  record_refcount(obj, GSP_RC_AUTORELEASE);
  rc_note(obj);
  id r = real_objc_autorelease(obj);
  rc_note(NULL);
  return r;
}

/* -[NSObject retain/release/autorelease]: clang on Windows sends these as
   messages rather than calling the runtime's entry points.  */
static id (*real_msg_retain)(id, SEL);
static void (*real_msg_release)(id, SEL);
static id (*real_msg_autorelease)(id, SEL);

static id
msg_retain(id self, SEL cmd)
{
  if (!rc_noted(self))
    record_refcount(self, GSP_RC_RETAIN);
  return real_msg_retain(self, cmd);
}

static void
msg_release(id self, SEL cmd)
{
  if (!rc_noted(self))
    record_refcount(self, GSP_RC_RELEASE);
  real_msg_release(self, cmd);
}

static id
msg_autorelease(id self, SEL cmd)
{
  if (!rc_noted(self))
    record_refcount(self, GSP_RC_AUTORELEASE);
  return real_msg_autorelease(self, cmd);
}

/* GNUstep's GSLogZombie is called inside gnustep-base, out of reach of
   import tables, from -[NSZombie forwardInvocation:]; that method is
   replaced through the runtime instead.  */
static void (*real_zombie_forward)(id, SEL, id);
static SEL sel_selector;
static IMP (*p_objc_msg_lookup)(id, SEL);
static const char *(*p_sel_getName)(SEL);

static void
zombie_forward(id self, SEL cmd, id invocation)
{
  if (enter())
    {
      SEL sel = NULL;
      if (invocation && p_objc_msg_lookup && sel_selector)
        {
          SEL (*get)(id, SEL) = (SEL (*)(id, SEL))p_objc_msg_lookup(invocation, sel_selector);
          if (get)
            sel = get(invocation, sel_selector);
        }
      gsp_zombie_payload z;
      memset(&z, 0, sizeof(z));
      z.address = (uint64_t)(uintptr_t)self;
      z.selector = sel && p_sel_getName ? gspw_intern(p_sel_getName(sel)) : 0;
      z.stack = hook_caller_stack();
      gspw_emit(GSP_REC_ZOMBIE, 0, 0, gspw_now(), GetCurrentThreadId(),
                &z, sizeof(z), NULL, 0);
      /* zombie messages often end in abort(): make sure it is written */
      gspw_flush();
      leave();
    }
  if (real_zombie_forward)
    real_zombie_forward(self, cmd, invocation);
}

static IMP
replace_method(HMODULE objc, const char *cls, const char *sel, IMP imp)
{
  Class (*getClass)(const char *) = (void *)GetProcAddress(objc, "objc_getClass");
  SEL (*selReg)(const char *) = (void *)GetProcAddress(objc, "sel_registerName");
  void *(*instMethod)(Class, SEL) = (void *)GetProcAddress(objc, "class_getInstanceMethod");
  IMP (*setImp)(void *, IMP) = (void *)GetProcAddress(objc, "method_setImplementation");
  if (!getClass || !selReg || !instMethod || !setImp)
    return NULL;
  Class c = getClass(cls);
  void *m = c ? instMethod(c, selReg(sel)) : NULL;
  return m ? setImp(m, imp) : NULL;
}

static void
install_refcount_hooks(HMODULE objc)
{
  if (rc_tls == TLS_OUT_OF_INDEXES)
    rc_tls = TlsAlloc();
  if (rc_tls == TLS_OUT_OF_INDEXES)
    return;
  /* installed at injection, while the program's threads are suspended */
  IMP r;
  if ((r = replace_method(objc, "NSObject", "retain", (IMP)msg_retain)) != NULL)
    real_msg_retain = (id (*)(id, SEL))r;
  if ((r = replace_method(objc, "NSObject", "release", (IMP)msg_release)) != NULL)
    real_msg_release = (void (*)(id, SEL))r;
  if ((r = replace_method(objc, "NSObject", "autorelease", (IMP)msg_autorelease)) != NULL)
    real_msg_autorelease = (id (*)(id, SEL))r;
}

static void
install_zombie_hook(HMODULE objc)
{
  Class (*getClass)(const char *) = (void *)GetProcAddress(objc, "objc_getClass");
  SEL (*selReg)(const char *) = (void *)GetProcAddress(objc, "sel_registerName");
  void *(*instMethod)(Class, SEL) = (void *)GetProcAddress(objc, "class_getInstanceMethod");
  IMP (*setImp)(void *, IMP) = (void *)GetProcAddress(objc, "method_setImplementation");
  p_objc_msg_lookup = (void *)GetProcAddress(objc, "objc_msg_lookup");
  p_sel_getName = (void *)GetProcAddress(objc, "sel_getName");
  if (!getClass || !selReg || !instMethod || !setImp)
    return;
  Class zombie = getClass("NSZombie");
  if (zombie == NULL)
    return;
  void *m = instMethod(zombie, selReg("forwardInvocation:"));
  if (m == NULL)
    return;
  sel_selector = selReg("selector");
  real_zombie_forward = (void (*)(id, SEL, id))setImp(m, (IMP)zombie_forward);
}

/* ------------------------------------------------------------------ */
/* exit: the final leak check, before atexit handlers release globals  */

static void (*real_exit)(int);
static volatile LONG exit_snapshot;

static void
hook_exit(int status)
{
  volatile char top = 0;
  if (gspw_leaks_enabled() && InterlockedExchange(&exit_snapshot, 1) == 0)
    {
      gspw_heap_exclude_thread();
      gspw_leaks_snapshot((const void *)&top);
      leave();
    }
  real_exit(status);
}

bool
gspw_exit_snapshot_taken(void)
{
  return exit_snapshot != 0;
}

/* ------------------------------------------------------------------ */
/* LoadLibrary: patch what it brought in                               */

static HMODULE (WINAPI *real_LoadLibraryA)(LPCSTR);
static HMODULE (WINAPI *real_LoadLibraryW)(LPCWSTR);
static HMODULE (WINAPI *real_LoadLibraryExA)(LPCSTR, HANDLE, DWORD);
static HMODULE (WINAPI *real_LoadLibraryExW)(LPCWSTR, HANDLE, DWORD);

static HMODULE WINAPI
hook_LoadLibraryA(LPCSTR name)
{
  HMODULE m = real_LoadLibraryA(name);
  if (m)
    gspw_heap_patch_modules();
  return m;
}

static HMODULE WINAPI
hook_LoadLibraryW(LPCWSTR name)
{
  HMODULE m = real_LoadLibraryW(name);
  if (m)
    gspw_heap_patch_modules();
  return m;
}

static HMODULE WINAPI
hook_LoadLibraryExA(LPCSTR name, HANDLE file, DWORD flags)
{
  HMODULE m = real_LoadLibraryExA(name, file, flags);
  if (m)
    gspw_heap_patch_modules();
  return m;
}

static HMODULE WINAPI
hook_LoadLibraryExW(LPCWSTR name, HANDLE file, DWORD flags)
{
  HMODULE m = real_LoadLibraryExW(name, file, flags);
  if (m)
    gspw_heap_patch_modules();
  return m;
}

/* ------------------------------------------------------------------ */
/* import table patching                                               */

enum { LIB_CRT, LIB_OBJC, LIB_LOADER };

typedef struct hook_def
{
  const char *name;
  int lib;
  void *hook;
  void **real;
} hook_def;

#define HOOK(n, lib, fn, real) { n, lib, (void *)fn, (void **)&real }
static hook_def hooks[] = {
  HOOK("malloc", LIB_CRT, hook_malloc, real_malloc),
  HOOK("calloc", LIB_CRT, hook_calloc, real_calloc),
  HOOK("realloc", LIB_CRT, hook_realloc, real_realloc),
  HOOK("free", LIB_CRT, hook_free, real_free),
  HOOK("_recalloc", LIB_CRT, hook_recalloc, real_recalloc),
  HOOK("_aligned_malloc", LIB_CRT, hook_aligned_malloc, real_aligned_malloc),
  HOOK("_aligned_realloc", LIB_CRT, hook_aligned_realloc, real_aligned_realloc),
  HOOK("_aligned_free", LIB_CRT, hook_aligned_free, real_aligned_free),
  HOOK("_strdup", LIB_CRT, hook_strdup, real_strdup),
  HOOK("strdup", LIB_CRT, hook_strdup2, real_strdup2),
  HOOK("_wcsdup", LIB_CRT, hook_wcsdup, real_wcsdup),
  HOOK("exit", LIB_CRT, hook_exit, real_exit),
  HOOK("class_createInstance", LIB_OBJC, hook_class_createInstance, real_class_createInstance),
  HOOK("objc_alloc", LIB_OBJC, hook_objc_alloc, real_objc_alloc),
  HOOK("objc_allocWithZone", LIB_OBJC, hook_objc_allocWithZone, real_objc_allocWithZone),
  HOOK("objc_alloc_init", LIB_OBJC, hook_objc_alloc_init, real_objc_alloc_init),
  HOOK("objc_retain", LIB_OBJC, hook_objc_retain, real_objc_retain),
  HOOK("objc_release", LIB_OBJC, hook_objc_release, real_objc_release),
  HOOK("objc_autorelease", LIB_OBJC, hook_objc_autorelease, real_objc_autorelease),
  HOOK("LoadLibraryA", LIB_LOADER, hook_LoadLibraryA, real_LoadLibraryA),
  HOOK("LoadLibraryW", LIB_LOADER, hook_LoadLibraryW, real_LoadLibraryW),
  HOOK("LoadLibraryExA", LIB_LOADER, hook_LoadLibraryExA, real_LoadLibraryExA),
  HOOK("LoadLibraryExW", LIB_LOADER, hook_LoadLibraryExW, real_LoadLibraryExW),
};
#define HOOK_COUNT (sizeof(hooks) / sizeof(hooks[0]))

static int
lib_kind(const char *dll)
{
  if (_stricmp(dll, "ucrtbase.dll") == 0 || _strnicmp(dll, "api-ms-win-crt-", 15) == 0)
    return LIB_CRT;
  if (_stricmp(dll, "kernel32.dll") == 0 || _stricmp(dll, "kernelbase.dll") == 0
      || _strnicmp(dll, "api-ms-win-core-libraryloader-", 30) == 0)
    return LIB_LOADER;
  char lower[64];
  size_t i;
  for (i = 0; dll[i] && i < sizeof(lower) - 1; i++)
    lower[i] = (char)(dll[i] >= 'A' && dll[i] <= 'Z' ? dll[i] + 32 : dll[i]);
  lower[i] = 0;
  if (strstr(lower, "objc") != NULL)
    return LIB_OBJC;
  return -1;
}

static void
resolve_objc(const char *dll)
{
  if (p_object_getClass != NULL)
    return;
  HMODULE m = GetModuleHandleA(dll);
  if (m == NULL)
    return;
  p_class_getName = (void *)GetProcAddress(m, "class_getName");
  p_object_getClass = (void *)GetProcAddress(m, "object_getClass");
  if (zombies_on)
    install_zombie_hook(m);
  if (refcounts_on)
    install_refcount_hooks(m);
}

static void
patch_slot(ULONGLONG *slot, hook_def *h)
{
  void *cur = (void *)(uintptr_t)*slot;
  DWORD old;

  if (cur == h->hook)
    return;
  /* The real function comes from the first table that imports it; the
     same export resolves to the same address everywhere.  */
  InterlockedCompareExchangePointer(h->real, cur, NULL);
  /* Bound to something else (a shim)?  Leave it alone; LoadLibrary may
     come from kernel32 or kernelbase, which are equivalent.  */
  if (*h->real != cur && h->lib != LIB_LOADER)
    return;
  if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old))
    return;
  InterlockedExchangePointer((void **)slot, h->hook);
  VirtualProtect(slot, sizeof(*slot), old, &old);
}

static void
patch_module(HMODULE m)
{
  uint8_t *base = (uint8_t *)m;
  IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;

  if (dos->e_magic != IMAGE_DOS_SIGNATURE)
    return;
  IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE
      || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC
      || nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT)
    return;
  IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (dir.VirtualAddress == 0)
    return;
  for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
       d->Name != 0; d++)
    {
      const char *dll = (const char *)(base + d->Name);
      int lib = lib_kind(dll);
      /* Without the name table the bound IAT cannot be matched by name. */
      if (lib < 0 || d->FirstThunk == 0 || d->OriginalFirstThunk == 0)
        continue;
      if (lib == LIB_OBJC)
        resolve_objc(dll);
      IMAGE_THUNK_DATA64 *names = (IMAGE_THUNK_DATA64 *)(base + d->OriginalFirstThunk);
      IMAGE_THUNK_DATA64 *iat = (IMAGE_THUNK_DATA64 *)(base + d->FirstThunk);
      for (; names->u1.AddressOfData != 0; names++, iat++)
        {
          if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal))
            continue;
          IMAGE_IMPORT_BY_NAME *ibn = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
          const char *fn = (const char *)ibn->Name;
          for (size_t k = 0; k < HOOK_COUNT; k++)
            if (hooks[k].lib == lib && strcmp(fn, hooks[k].name) == 0)
              {
                patch_slot(&iat->u1.Function, &hooks[k]);
                break;
              }
        }
    }
}

static uintptr_t patched[2048];
static int patched_count;

void
gspw_heap_patch_modules(void)
{
  HMODULE mods[2048];
  DWORD needed = 0;

  if (!heap_on)
    return;
  EnterCriticalSection(&patch_lock);
  if (K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed))
    {
      int n = (int)(needed / sizeof(HMODULE));
      if (n > 2048)
        n = 2048;
      for (int i = 0; i < n; i++)
        {
          bool done = mods[i] == self_module;
          for (int k = 0; k < patched_count && !done; k++)
            done = patched[k] == (uintptr_t)mods[i];
          if (done || patched_count >= 2048)
            continue;
          patch_module(mods[i]);
          patched[patched_count++] = (uintptr_t)mods[i];
        }
    }
  LeaveCriticalSection(&patch_lock);
}

void
gspw_agent_image(uint64_t *lo, uint64_t *hi)
{
  *lo = self_start;
  *hi = self_end;
}

void
gspw_heap_start(bool allocations, bool refcounts, bool zombies, unsigned frames)
{
  refcounts_on = refcounts;
  zombies_on = zombies;
  guard_tls = TlsAlloc();
  InitializeCriticalSection(&stack_lock);
  InitializeCriticalSection(&patch_lock);
  GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                     | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     (LPCSTR)(void *)gspw_heap_start, &self_module);
  MODULEINFO mi;
  if (self_module && K32GetModuleInformation(GetCurrentProcess(), self_module, &mi, sizeof(mi)))
    {
      self_start = (uintptr_t)mi.lpBaseOfDll;
      self_end = self_start + mi.SizeOfImage;
    }
  alloc_frames = frames == 0 ? 1 : (frames > MAX_ALLOC_FRAMES ? MAX_ALLOC_FRAMES : frames);
  if (!allocations || guard_tls == TLS_OUT_OF_INDEXES)
    return;
  InterlockedExchange(&heap_on, 1);
  gspw_heap_patch_modules();
}
