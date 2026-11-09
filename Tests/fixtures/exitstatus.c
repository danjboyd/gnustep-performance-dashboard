/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile uint64_t value = 1;

static void
work(void)
{
  for (unsigned i = 0; i < 10000; i++)
    value = value * 6364136223846793005ULL + 1;
}

int
main(int argc, char **argv)
{
  struct timespec start, now;

  if (argc != 2)
    return 2;
  /* A broken recorder must not leave this test's busy target behind. */
  alarm(12);
  if (strcmp(argv[1], "ignore-term") == 0)
    signal(SIGTERM, SIG_IGN);
  if (strcmp(argv[1], "loop") == 0 || strcmp(argv[1], "ignore-term") == 0)
    for (;;)
      work();

  /* Ensure the agent has samples before either a normal or a signal exit. */
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &start);
  do
    {
      work();
      clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &now);
    }
  while ((now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9 < 0.06);
  if (strcmp(argv[1], "exit3") == 0)
    return 3;
  if (strcmp(argv[1], "segv") == 0)
    raise(SIGSEGV);
  if (strcmp(argv[1], "term") == 0)
    raise(SIGTERM);
  return strcmp(argv[1], "exit0") == 0 ? 0 : 2;
}
