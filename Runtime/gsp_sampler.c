/* gsp_sampler.c - Time Profiler and Hangs sampling, thread and image hooks.

   CPU samples come from a per-thread CLOCK_THREAD_CPUTIME_ID timer, so a
   thread is only sampled while it runs on a CPU (as Instruments' Time
   Profiler does).  The main thread also gets a wall-clock timer whose
   samples show where it is even while blocked; the Hangs analysis uses them
   to find periods when the main run loop was not waiting for events.  */

#include "gsp_internal.h"

#include <dlfcn.h>
#include <errno.h>
#include <link.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_int sampling_on;

static void
sample_handler(int sig, siginfo_t *info, void *uc)
{
  int saved = errno;
  gsp_thread *t = gsp_self_thread;
  uint64_t buf[2 + GSP_MAX_FRAMES];
  gsp_frames_payload *fp = (gsp_frames_payload *)buf;
  unsigned n;

  if (t == NULL || !atomic_load_explicit(&sampling_on, memory_order_relaxed)
      || atomic_load_explicit(&t->suspended, memory_order_relaxed))
    {
      errno = saved;
      return;
    }
  n = gsp_unwind_signal(t, uc, buf + 1, gsp_cfg.max_frames);
  fp->count = n;
  fp->kernel_count = 0;
  /* CPU-time timers are checked on the scheduler tick, so several
     intervals can elapse per signal; carry them as the sample's weight.  */
  {
    int over = info ? info->si_overrun : 0;
    fp->weight = (uint16_t)(over < 0 ? 1 : (over + 1 > 65535 ? 65535 : over + 1));
  }
  gsp_emit_signal(t, GSP_REC_SAMPLE,
                  sig == GSP_SIG_CPU ? GSP_SAMPLE_CPU : GSP_SAMPLE_WALL,
                  n >= gsp_cfg.max_frames ? GSP_FRAMES_TRUNCATED : 0,
                  gsp_now(), buf, sizeof(*fp) + n * 8, NULL, 0);
  errno = saved;
}

static bool
make_thread_timer(gsp_thread *t, clockid_t clock, int sig, unsigned us,
                  timer_t *out)
{
  struct sigevent sev;
  struct itimerspec its;

  memset(&sev, 0, sizeof(sev));
  sev.sigev_notify = SIGEV_THREAD_ID;
  sev.sigev_signo = sig;
  sev._sigev_un._tid = t->tid;
  if (timer_create(clock, &sev, out) != 0)
    return false;
  its.it_interval.tv_sec = us / 1000000;
  its.it_interval.tv_nsec = (long)(us % 1000000) * 1000;
  its.it_value = its.it_interval;
  if (timer_settime(*out, 0, &its, NULL) != 0)
    {
      timer_delete(*out);
      return false;
    }
  return true;
}

void
gsp_thread_start_timers(gsp_thread *t)
{
  if (!atomic_load(&sampling_on))
    return;
  /* libunwind's per-thread cache lives in dynamic TLS that is allocated on
     first use; make that happen here, not inside the first SIGPROF.  */
  {
    uint64_t frames[4];
    gsp_unwind_here(t, frames, 4);
  }
  if (gsp_cfg.cpu_sampling && !t->has_cpu_timer)
    t->has_cpu_timer = make_thread_timer(t, CLOCK_THREAD_CPUTIME_ID,
                                         GSP_SIG_CPU,
                                         gsp_cfg.sample_interval_us,
                                         &t->cpu_timer);
  if (gsp_cfg.wall_sampling_main && (t->flags & GSP_THREAD_MAIN)
      && !t->has_wall_timer)
    t->has_wall_timer = make_thread_timer(t, CLOCK_MONOTONIC, GSP_SIG_WALL,
                                          gsp_cfg.wall_interval_us,
                                          &t->wall_timer);
}

void
gsp_sampler_init(void)
{
  struct sigaction sa;

  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = sample_handler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  /* Do not let the two sampling signals nest.  */
  sigaddset(&sa.sa_mask, GSP_SIG_CPU);
  sigaddset(&sa.sa_mask, GSP_SIG_WALL);
  if (gsp_cfg.cpu_sampling)
    sigaction(GSP_SIG_CPU, &sa, NULL);
  if (gsp_cfg.wall_sampling_main)
    sigaction(GSP_SIG_WALL, &sa, NULL);
  atomic_store(&sampling_on, gsp_cfg.cpu_sampling || gsp_cfg.wall_sampling_main);
}

void
gsp_sampler_stop(void)
{
  /* Handlers ignore signals from now on.  Timers belong to their threads
     (which may be deleting them right now), so they are not touched from
     here; they go away with the thread or the process.  */
  atomic_store(&sampling_on, 0);
}

/* ------------------------------------------------------------------ */
/* threads                                                             */

typedef struct trampoline
{
  void *(*fn)(void *);
  void *arg;
} trampoline;

extern void *__libc_malloc(size_t);
extern void __libc_free(void *);

static void *
thread_trampoline(void *p)
{
  trampoline tr = *(trampoline *)p;
  __libc_free(p);
  gsp_thread_current();
  return tr.fn(tr.arg);
}

GSP_EXPORT int
pthread_create(pthread_t *thread, const pthread_attr_t *attr,
               void *(*fn)(void *), void *arg)
{
  trampoline *tr;

  if (gsp_real_pthread_create == NULL)
    gsp_real_pthread_create = dlsym(RTLD_NEXT, "pthread_create");
  if (!atomic_load(&gsp_recording) || gsp_is_internal)
    return gsp_real_pthread_create(thread, attr, fn, arg);
  tr = __libc_malloc(sizeof(*tr));
  if (tr == NULL)
    return gsp_real_pthread_create(thread, attr, fn, arg);
  tr->fn = fn;
  tr->arg = arg;
  int r = gsp_real_pthread_create(thread, attr, thread_trampoline, tr);
  if (r != 0)
    __libc_free(tr);
  return r;
}

/* ------------------------------------------------------------------ */
/* images                                                              */

#define MAX_IMAGES 4096
static uintptr_t emitted_bases[MAX_IMAGES];
static int emitted_count;
static pthread_mutex_t images_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct image_info
{
  uint64_t base, start, end;
  char path[1024];
} image_info;

typedef struct image_scan
{
  image_info *found;
  int count, max;
} image_scan;

static int
image_cb(struct dl_phdr_info *pi, size_t size, void *data)
{
  image_scan *scan = data;
  uint64_t lo = UINT64_MAX, hi = 0;

  (void)size;
  for (int i = 0; i < pi->dlpi_phnum; i++)
    {
      const ElfW(Phdr) *ph = &pi->dlpi_phdr[i];
      if (ph->p_type == PT_LOAD && (ph->p_flags & PF_X))
        {
          uint64_t a = pi->dlpi_addr + ph->p_vaddr;
          if (a < lo)
            lo = a;
          if (a + ph->p_memsz > hi)
            hi = a + ph->p_memsz;
        }
    }
  if (hi == 0)
    return 0;
  for (int i = 0; i < emitted_count; i++)
    if (emitted_bases[i] == lo)
      return 0;
  if (scan->count >= scan->max || emitted_count >= MAX_IMAGES)
    return 0;
  image_info *im = &scan->found[scan->count++];
  im->base = pi->dlpi_addr;
  im->start = lo;
  im->end = hi;
  if (pi->dlpi_name && pi->dlpi_name[0])
    {
      strncpy(im->path, pi->dlpi_name, sizeof(im->path) - 1);
      im->path[sizeof(im->path) - 1] = 0;
    }
  else
    {
      ssize_t n = readlink("/proc/self/exe", im->path, sizeof(im->path) - 1);
      im->path[n > 0 ? n : 0] = 0;
    }
  emitted_bases[emitted_count++] = lo;
  return 0;
}

static void
emit_new_images(gsp_thread *t, bool writer)
{
  static image_info found[256];
  image_scan scan = { found, 0, 256 };

  pthread_mutex_lock(&images_lock);
  dl_iterate_phdr(image_cb, &scan);
  for (int i = 0; i < scan.count; i++)
    {
      gsp_image_payload p = { found[i].base, found[i].start, found[i].end };
      size_t len = strlen(found[i].path) + 1;
      if (writer)
        gsp_writer_emit(GSP_REC_IMAGE, 0, gsp_now(), (uint32_t)gsp_gettid(),
                        &p, sizeof(p), found[i].path, len);
      else
        gsp_emit_normal(t, GSP_REC_IMAGE, 0, 0, gsp_now(),
                        &p, sizeof(p), found[i].path, len);
    }
  pthread_mutex_unlock(&images_lock);
  if (scan.count == scan.max)
    emit_new_images(t, writer);
}

void
gsp_images_emit_new(gsp_thread *t)
{
  if (t == NULL)
    return;
  gsp_in_agent++;
  emit_new_images(t, false);
  gsp_in_agent--;
}

void
gsp_images_emit_new_writer(void)
{
  emit_new_images(NULL, true);
}

/* Cheap change detection for the writer's poll: the loader counts every
   object it adds.  Not interposing dlopen keeps callers' RUNPATH and
   $ORIGIN lookups intact.  */
static int
adds_cb(struct dl_phdr_info *pi, size_t size, void *data)
{
  (void)size;
  *(unsigned long long *)data = pi->dlpi_adds;
  return 1;
}

bool
gsp_images_changed(void)
{
  static unsigned long long last;
  unsigned long long adds = 0;
  dl_iterate_phdr(adds_cb, &adds);
  if (adds == last)
    return false;
  last = adds;
  return true;
}
