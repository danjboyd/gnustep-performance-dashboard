/* Sustained allocation and sampling workload; duration is in seconds. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static atomic_int stopped;
static void *live[8][16];

static void *
worker(void *arg)
{
  long id = (long)arg;
  unsigned seed = (unsigned)id + 1;
  struct timespec pause = { 0, 10000000 };
  while (!atomic_load(&stopped))
    {
      for (int i = 0; i < 16; i++)
        {
          size_t size = 32 + rand_r(&seed) % 4096;
          free(live[id][i]);
          live[id][i] = malloc(size);
          if (live[id][i])
            memset(live[id][i], (int)id, size);
        }
      nanosleep(&pause, NULL);
    }
  for (int i = 0; i < 16; i++)
    {
      free(live[id][i]);
      live[id][i] = NULL;
    }
  return NULL;
}

int
main(int argc, char **argv)
{
  unsigned seconds = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 60;
  if (seconds < 1 || seconds > 600)
    return 2;
  pthread_t threads[8];
  for (long i = 0; i < 8; i++)
    if (pthread_create(&threads[i], NULL, worker, (void *)i) != 0)
      return 1;
  struct timespec remaining = { seconds, 0 };
  while (nanosleep(&remaining, &remaining) != 0)
    ;
  atomic_store(&stopped, 1);
  for (int i = 0; i < 8; i++)
    pthread_join(threads[i], NULL);
  return 0;
}
