/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* gsp_objc.c - Objective-C awareness without linking libobjc.

   - Instance allocation: class_createInstance and the objc_alloc family are
     interposed so allocations can be labelled with their class
     (OBJC_TAG records), as Apple Instruments' Allocations does.
   - Reference counting history: objc_retain/objc_release/objc_autorelease
     are interposed when GSP_REFCOUNTS is set.
   - Zombies: GNUstep's GSLogZombie is interposed to record the message
     sent to a deallocated object (NSZombieEnabled=YES must be set too).
   - Symbolication: GNUstep libraries are usually stripped, so at the end of
     a recording the writer dumps every method implementation address with
     its "-[Class selector]" name (METHOD records).

   Every runtime function is looked up with dlsym, so processes that do not
   use Objective-C are unaffected and the agent has no libobjc dependency.  */

#include "gsp_internal.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *id;
typedef void *Class;
typedef void *SEL;
typedef void *Method;
typedef void *IMP;

static const char *(*p_class_getName)(Class);
static Class (*p_object_getClass)(id);
static const char *(*p_sel_getName)(SEL);
static int (*p_objc_getClassList)(Class *, int);
static Method *(*p_class_copyMethodList)(Class, unsigned *);
static SEL (*p_method_getName)(Method);
static IMP (*p_method_getImplementation)(Method);
static bool resolved;

static bool
resolve_runtime(void)
{
  if (resolved)
    return true;
  p_class_getName = dlsym(RTLD_DEFAULT, "class_getName");
  p_object_getClass = dlsym(RTLD_DEFAULT, "object_getClass");
  p_sel_getName = dlsym(RTLD_DEFAULT, "sel_getName");
  p_objc_getClassList = dlsym(RTLD_DEFAULT, "objc_getClassList");
  p_class_copyMethodList = dlsym(RTLD_DEFAULT, "class_copyMethodList");
  p_method_getName = dlsym(RTLD_DEFAULT, "method_getName");
  p_method_getImplementation = dlsym(RTLD_DEFAULT, "method_getImplementation");
  resolved = p_class_getName && p_object_getClass && p_sel_getName
    && p_objc_getClassList && p_class_copyMethodList && p_method_getName
    && p_method_getImplementation;
  return resolved;
}

/* IMPs already written, so periodic dumps only emit new methods.  */
static uint64_t *dumped;
static uint64_t dumped_cap, dumped_used;
static int last_class_count = -1;
static uint64_t next_poll;

static bool
mark_dumped(uint64_t imp)
{
  if ((dumped_used + 1) * 2 > dumped_cap)
    {
      uint64_t ncap = dumped_cap ? dumped_cap * 2 : 65536;
      uint64_t *n = gsp_map(ncap * 8);
      if (n == NULL)
        return true;
      for (uint64_t i = 0; i < dumped_cap; i++)
        if (dumped[i])
          {
            uint64_t j = (dumped[i] * 0x9E3779B97F4A7C15ull >> 20) & (ncap - 1);
            while (n[j])
              j = (j + 1) & (ncap - 1);
            n[j] = dumped[i];
          }
      if (dumped)
        gsp_unmap(dumped, dumped_cap * 8);
      dumped = n;
      dumped_cap = ncap;
    }
  uint64_t j = (imp * 0x9E3779B97F4A7C15ull >> 20) & (dumped_cap - 1);
  while (dumped[j])
    {
      if (dumped[j] == imp)
        return false;
      j = (j + 1) & (dumped_cap - 1);
    }
  dumped[j] = imp;
  dumped_used++;
  return true;
}

/* Writer thread, every tick: dump new methods about once a second when
   the class list grew (new bundles, lazily registered classes).  */
void
gsp_objc_poll(void)
{
  uint64_t now = gsp_now();
  if (now < next_poll)
    return;
  next_poll = now + 1000000000ull;
  if (dlsym(RTLD_DEFAULT, "objc_getClassList") == NULL || !resolve_runtime())
    return;
  int count = p_objc_getClassList(NULL, 0);
  if (count != last_class_count)
    {
      last_class_count = count;
      gsp_objc_dump_methods();
    }
}

/* ------------------------------------------------------------------ */
/* allocation tagging                                                  */

static void
tag_object(id obj)
{
  gsp_thread *t;
  Class cls;

  if (obj == NULL || !atomic_load_explicit(&gsp_alloc_on, memory_order_relaxed)
      || gsp_in_agent)
    return;
  gsp_in_agent++;
  if (resolve_runtime() && (t = gsp_thread_current()) != NULL)
    {
      cls = p_object_getClass(obj);
      if (cls != NULL)
        {
          gsp_tag_payload p;
          p.address = (uint64_t)(uintptr_t)obj;
          p.class_name = gsp_intern_string(p_class_getName(cls));
          p.stack = 0;
          gsp_emit_normal(t, GSP_REC_OBJC_TAG, 0, 0, gsp_now(),
                          &p, sizeof(p), NULL, 0);
          gsp_alloc_tag(obj, p.class_name);
        }
    }
  gsp_in_agent--;
}

#define NEXT(type, name, args)                                   \
  static type (*real) args;                                      \
  if (real == NULL)                                              \
    real = (type (*) args)dlsym(RTLD_NEXT, name)

GSP_EXPORT id
class_createInstance(Class cls, size_t extra)
{
  NEXT(id, "class_createInstance", (Class, size_t));
  id obj = real ? real(cls, extra) : NULL;
  tag_object(obj);
  return obj;
}

GSP_EXPORT id
objc_alloc(Class cls)
{
  NEXT(id, "objc_alloc", (Class));
  id obj = real ? real(cls) : NULL;
  tag_object(obj);
  return obj;
}

GSP_EXPORT id
objc_allocWithZone(Class cls)
{
  NEXT(id, "objc_allocWithZone", (Class));
  id obj = real ? real(cls) : NULL;
  tag_object(obj);
  return obj;
}

GSP_EXPORT id
objc_alloc_init(Class cls)
{
  NEXT(id, "objc_alloc_init", (Class));
  id obj = real ? real(cls) : NULL;
  tag_object(obj);
  return obj;
}

/* ------------------------------------------------------------------ */
/* reference counting history                                          */

static void
record_refcount(id obj, int kind)
{
  gsp_thread *t;

  if (obj == NULL || !gsp_cfg.refcounts || gsp_in_agent
      || !atomic_load_explicit(&gsp_alloc_on, memory_order_relaxed))
    return;
  /* Small objects (tagged pointers) are not allocations.  */
  if (((uintptr_t)obj & 7) != 0)
    return;
  gsp_in_agent++;
  t = gsp_thread_current();
  if (t != NULL)
    {
      gsp_refcount_payload p;
      p.address = (uint64_t)(uintptr_t)obj;
      p.stack = gsp_current_stack_id(t);
      p.refcount = -1;
      gsp_emit_normal(t, GSP_REC_REFCOUNT, (uint32_t)kind, 0, gsp_now(),
                      &p, sizeof(p), NULL, 0);
    }
  gsp_in_agent--;
}

GSP_EXPORT id
objc_retain(id obj)
{
  NEXT(id, "objc_retain", (id));
  record_refcount(obj, GSP_RC_RETAIN);
  return real(obj);
}

GSP_EXPORT void
objc_release(id obj)
{
  NEXT(void, "objc_release", (id));
  record_refcount(obj, GSP_RC_RELEASE);
  real(obj);
}

GSP_EXPORT id
objc_autorelease(id obj)
{
  NEXT(id, "objc_autorelease", (id));
  record_refcount(obj, GSP_RC_AUTORELEASE);
  return real(obj);
}

/* ------------------------------------------------------------------ */
/* zombies                                                             */

GSP_EXPORT void
GSLogZombie(id obj, SEL sel)
{
  NEXT(void, "GSLogZombie", (id, SEL));
  if (atomic_load(&gsp_recording) && !gsp_in_agent)
    {
      gsp_in_agent++;
      gsp_thread *t = gsp_thread_current();
      if (t != NULL && resolve_runtime())
        {
          gsp_zombie_payload p;
          memset(&p, 0, sizeof(p));
          p.address = (uint64_t)(uintptr_t)obj;
          p.selector = sel ? gsp_intern_string(p_sel_getName(sel)) : 0;
          p.stack = gsp_current_stack_id(t);
          gsp_emit_normal(t, GSP_REC_ZOMBIE, 0, 0, gsp_now(),
                          &p, sizeof(p), NULL, 0);
          /* Make sure it reaches the file: zombie messages often abort.  */
          gsp_writer_wake();
          struct timespec ts = { 0, 5000000 };
          nanosleep(&ts, NULL);
        }
      gsp_in_agent--;
    }
  if (real)
    real(obj, sel);
}

/* ------------------------------------------------------------------ */
/* method table dump (writer thread)                                   */

static void
dump_class(Class cls, char prefix)
{
  unsigned count = 0;
  Method *list = p_class_copyMethodList(cls, &count);
  const char *cname = p_class_getName(cls);
  char name[1024];

  if (list == NULL)
    return;
  for (unsigned i = 0; i < count; i++)
    {
      IMP imp = p_method_getImplementation(list[i]);
      SEL sel = p_method_getName(list[i]);
      if (imp == NULL || sel == NULL || !mark_dumped((uint64_t)(uintptr_t)imp))
        continue;
      int n = snprintf(name, sizeof(name), "%c[%s %s]", prefix,
                       cname ? cname : "?", p_sel_getName(sel));
      if (n < 0)
        continue;
      if ((size_t)n >= sizeof(name))
        n = sizeof(name) - 1;
      gsp_method_payload p = { (uint64_t)(uintptr_t)imp };
      gsp_writer_emit(GSP_REC_METHOD, 0, gsp_now(), 0, &p, sizeof(p),
                      name, (size_t)n + 1);
    }
  free(list);
}

void
gsp_objc_dump_methods(void)
{
  int count;
  Class *classes;
  size_t bytes;

  if (dlsym(RTLD_DEFAULT, "objc_getClassList") == NULL || !resolve_runtime())
    return;
  count = p_objc_getClassList(NULL, 0);
  if (count <= 0)
    return;
  /* Ask for exactly `count`: libobjc2 2.x frees its enumerator twice when
     the buffer is larger than the class table.  */
  bytes = sizeof(Class) * (size_t)count;
  classes = gsp_map(bytes);
  if (classes == NULL)
    return;
  count = p_objc_getClassList(classes, count);
  for (int i = 0; i < count; i++)
    {
      dump_class(classes[i], '-');
      Class meta = p_object_getClass(classes[i]);
      if (meta)
        dump_class(meta, '+');
    }
  gsp_unmap(classes, bytes);
}
