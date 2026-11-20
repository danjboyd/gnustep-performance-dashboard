/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Linux worker blocking-call contract under SA_RESTART, 100 Hz wall signals.
   This does not enable all-thread wall sampling in the production agent. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <sys/select.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static __thread volatile sig_atomic_t signals_seen;
static void
on_signal(int signal, siginfo_t *info, void *context)
{
  (void)signal; (void)info; (void)context;
  signals_seen++;
}

static long long
now_ns(clockid_t clock)
{
  struct timespec ts;
  assert(clock_gettime(clock, &ts) == 0);
  return (long long)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

typedef struct result
{
  const char *name;
  int kind, interrupted, signals;
  long long elapsed;
} result;

static void *
worker(void *arg)
{
  result *r = arg;
  struct sigevent event = { 0 };
  timer_t timer;
  event.sigev_notify = SIGEV_THREAD_ID;
  event.sigev_signo = SIGRTMIN + 3;
  event._sigev_un._tid = (pid_t)syscall(SYS_gettid);
  assert(timer_create(CLOCK_MONOTONIC, &event, &timer) == 0);
  int epoll = epoll_create1(EPOLL_CLOEXEC);
  assert(epoll >= 0);
  sem_t sem;
  assert(sem_init(&sem, 0, 0) == 0);
  pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
  assert(pthread_mutex_lock(&lock) == 0);
  long long start = now_ns(CLOCK_MONOTONIC), end = start + 120000000;
  long long real_end = now_ns(CLOCK_REALTIME) + 120000000;
  struct timespec deadline = { real_end / 1000000000, real_end % 1000000000 };
  struct itimerspec rate = { { 0, 10000000 }, { 0, 10000000 } };
  assert(timer_settime(timer, 0, &rate, NULL) == 0);
  while (now_ns(CLOCK_MONOTONIC) < end)
    {
      long long remaining = end - now_ns(CLOCK_MONOTONIC);
      if (remaining <= 0) break;
      int rc = 0, error = 0;
      switch (r->kind)
        {
        case 0:
          rc = poll(NULL, 0, (int)((remaining + 999999) / 1000000));
          break;
        case 1:
          {
            struct epoll_event events[1];
            rc = epoll_wait(epoll, events, 1, (int)((remaining + 999999) / 1000000));
            break;
          }
        case 2:
          {
            struct timeval timeout = { remaining / 1000000000, (remaining % 1000000000) / 1000 };
            rc = select(0, NULL, NULL, NULL, &timeout);
            break;
          }
        case 3:
          {
            struct timespec timeout = { remaining / 1000000000, remaining % 1000000000 };
            rc = nanosleep(&timeout, NULL);
            break;
          }
        case 4: rc = sem_timedwait(&sem, &deadline); break;
        case 5:
          error = pthread_cond_timedwait(&cond, &lock, &deadline);
          assert(error == 0 || error == ETIMEDOUT); /* POSIX: never EINTR */
          break;
        }
      if (r->kind != 5 && rc < 0) error = errno;
      if (error == EINTR) r->interrupted++;
      else assert(error == 0 || error == ETIMEDOUT);
    }
  r->elapsed = now_ns(CLOCK_MONOTONIC) - start;
  assert(timer_delete(timer) == 0);
  r->signals = signals_seen;
  assert(pthread_mutex_unlock(&lock) == 0);
  assert(pthread_cond_destroy(&cond) == 0);
  assert(pthread_mutex_destroy(&lock) == 0);
  assert(sem_destroy(&sem) == 0);
  close(epoll);
  return NULL;
}

int
main(void)
{
  struct sigaction action = { 0 };
  action.sa_sigaction = on_signal;
  action.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&action.sa_mask);
  assert(sigaction(SIGRTMIN + 3, &action, NULL) == 0);
  result results[] = { { .name = "poll" }, { .name = "epoll_wait" },
    { .name = "select" }, { .name = "nanosleep" }, { .name = "sem_timedwait" },
    { .name = "cond_timedwait" } };
  puts("[");
  for (int i = 0; i < 6; i++)
    {
      pthread_t thread;
      results[i].kind = i;
      assert(pthread_create(&thread, NULL, worker, &results[i]) == 0);
      assert(pthread_join(thread, NULL) == 0);
      result *r = &results[i];
      assert(r->signals >= 3);
      assert(i == 5 ? r->interrupted == 0 : r->interrupted > 0);
      printf("  {\"call\":\"%s\",\"signals\":%d,\"eintr\":%d,\"elapsed_ns\":%lld}%s\n",
             r->name, r->signals, r->interrupted, r->elapsed, i == 5 ? "" : ",");
    }
  puts("]");
  return 0;
}
