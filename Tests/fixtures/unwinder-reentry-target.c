/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <dlfcn.h>
#include <signal.h>

static uint64_t
now_ns(void)
{
  struct timespec t;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}

int
main(void)
{
  const char *mode = getenv("CONTROLLED_INVALID_FP");
  if (mode)
    {
      void *library = dlopen("libunwind.so.8", RTLD_NOW | RTLD_NOLOAD);
      void (*arm)(int) = library
        ? dlsym(library, "controlled_invalid_fp_sample") : NULL;
      if (!arm)
        return 88;
      arm(mode[0] == 'w' ? SIGRTMIN + 3 : SIGPROF);
    }
  uint64_t end = now_ns() + 250000000ull;
  volatile uint64_t burn = 1;
  while (now_ns() < end)
    {
      void *(*volatile allocate)(size_t) = malloc;
      void (*volatile release)(void *) = free;
      void *p = allocate(64);
      for (unsigned i = 0; i < 10000; i++)
        burn = burn * 1664525u + 1013904223u;
      release(p);
    }
  /* A post-sampling allocation proves that the signal recursion guard was
     restored, rather than leaving ordinary allocation recording disabled.  */
  void *(*volatile allocate)(size_t) = malloc;
  void (*volatile release)(void *) = free;
  void *marker = allocate(12345);
  release(marker);
  return 0;
}
