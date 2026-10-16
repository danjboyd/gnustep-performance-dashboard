/* spin - portable C fixture (Linux and Windows): two threads burn CPU in
   known functions while the main thread emits signposts around each
   round.  Links with libgsperf / gsperf.dll.  */
#include <os/signpost.h>
#include <pthread.h>
#include <stdio.h>

static volatile double sink;

__attribute__((noinline)) double
spin_inner(int n)
{
  double x = 0;
  for (int i = 0; i < n; i++)
    x += (double)i * 0.5;
  return x;
}

__attribute__((noinline)) void
spin_rounds(int rounds)
{
  for (int i = 0; i < rounds; i++)
    sink += spin_inner(400000);
}

static void *
worker(void *arg)
{
  spin_rounds(300);
  return arg;
}

int
main(void)
{
  os_log_t log = os_log_create("org.gnustep.tests", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
  pthread_t t;
  pthread_create(&t, NULL, worker, NULL);
  for (int r = 0; r < 4; r++)
    {
      os_signpost_id_t id = os_signpost_id_generate(log);
      os_signpost_interval_begin(log, id, "Round", "round %d", r);
      spin_rounds(100);
      os_signpost_interval_end(log, id, "Round");
    }
  pthread_join(t, NULL);
  printf("spin %f\n", sink);
  return 0;
}
