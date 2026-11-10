/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile uint64_t value;
static void
churn(void)
{
  for (unsigned i = 0; i < 512; i++)
    {
      unsigned char *p = malloc(64);
      if (!p) _exit(4);
      memset(p, (int)i, 64);
      __asm__ volatile("" : : "r"(p) : "memory");
      value += p[0];
      free(p);
    }
}

int
main(int argc, char **argv)
{
  if (argc != 2) return 2;
  const char *mode = argv[1];
  alarm(12); /* bounded even if recorder cleanup is broken */
  if (!strcmp(mode, "ignore")) signal(SIGTERM, SIG_IGN);
  if (!strcmp(mode, "efbig") || !strcmp(mode, "efbig-exit3"))
    {
      signal(SIGXFSZ, SIG_IGN);
      struct rlimit limit = { 64 * 1024, 64 * 1024 };
      if (setrlimit(RLIMIT_FSIZE, &limit)) return 5;
    }
  if (!strcmp(mode, "bad-status"))
    {
      const char *fd = getenv("GSP_STATUS_FD");
      if (!fd || send(atoi(fd), "bad", 3, MSG_NOSIGNAL) != 3) return 6;
    }
  if (!strcmp(mode, "lost-status"))
    {
      const char *fd = getenv("GSP_STATUS_FD");
      if (!fd || close(atoi(fd))) return 6;
    }
  if (!strcmp(mode, "metadata-denied"))
    {
      /* Fail only this owned bundle's later atomic metadata/marker writes.
         Wait until initial metadata exists so it can expose unfinished state. */
      const char *directory = getenv("GSP_OUTPUT");
      char info[4096];
      if (!directory) return 8;
      int length = snprintf(info, sizeof(info), "%s/Info.plist", directory);
      if (length < 0 || (size_t)length >= sizeof(info)) return 8;
      struct stat st;
      unsigned waited;
      for (waited = 0; waited < 500 && stat(info, &st) != 0; waited++)
        {
          struct timespec delay = { 0, 1000000 };
          nanosleep(&delay, NULL);
        }
      if (waited == 500 || chmod(directory, 0500)) return 8;
    }
  if (!strcmp(mode, "stdout"))
    {
      char block[4096]; memset(block, 'x', sizeof(block));
      for (unsigned i = 0; i < 64; i++)
        if (write(STDOUT_FILENO, block, sizeof(block)) != sizeof(block)) return 7;
    }
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;)
    {
      churn();
      clock_gettime(CLOCK_MONOTONIC, &now);
      double elapsed = now.tv_sec - start.tv_sec + (now.tv_nsec - start.tv_nsec) / 1e9;
      if ((!strcmp(mode, "natural") || !strcmp(mode, "lost-status")
           || !strcmp(mode, "metadata-denied")) && elapsed > 0.06) return 0;
      if (!strcmp(mode, "efbig-exit3") && elapsed > 0.5) return 3;
    }
}
