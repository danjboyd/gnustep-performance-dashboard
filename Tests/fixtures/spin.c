/* spin - portable C fixture (Linux and Windows): two threads burn CPU in
   known functions while the main thread emits signposts around each
   round.  Links with libgsperf / gsperf.dll.  An argument scales the
   work (the attach test runs it long enough to attach to).  */
#include <os/signpost.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static int scale = 1;

static void *
worker(void *arg)
{
  spin_rounds(300 * scale);
  return arg;
}

int
main(int argc, char **argv)
{
  if (argc > 1 && atoi(argv[1]) > 0)
    scale = atoi(argv[1]);
  os_log_t log = os_log_create("org.gnustep.tests", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
  int heartbeat = argc > 2 && strcmp(argv[2], "--heartbeat") == 0;
  pthread_t t;
  pthread_create(&t, NULL, worker, NULL);
  for (int r = 0; r < 4; r++)
    {
      os_signpost_id_t id = os_signpost_id_generate(log);
      os_signpost_interval_begin(log, id, "Round", "round %d", r);
      if (heartbeat)
        {
          /* Attach may land between the endpoints of a long Round interval.
             Emit frequent events so a short recording actually observes a
             signpost call after the agent is loaded, independent of CPU speed. */
          for (int batch = 0; batch < 10 * scale; batch++)
            {
              spin_rounds(10);
              os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE,
                                    "AttachHeartbeat", "batch %d", batch);
            }
        }
      else
        spin_rounds(100 * scale);
      os_signpost_interval_end(log, id, "Round");
    }
  pthread_join(t, NULL);
  printf("spin %f\n", sink);
  return 0;
}
