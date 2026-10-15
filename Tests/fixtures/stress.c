/* stress - many threads allocating while the agent samples and runs leak
   checks.  Each thread leaks exactly one 4000-byte block.  */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define THREADS 8
static void *keep[THREADS][64];

static void *
worker(void *arg)
{
  long id = (long)arg;
  unsigned seed = (unsigned)id * 7919u + 1;
  for (int i = 0; i < 150000; i++)
    {
      size_t sz = (rand_r(&seed) % 512) + 1;
      if (i % 5000 == 0)
        sz = 200000;   /* large: mmap'd by glibc */
      char *p = malloc(sz);
      memset(p, i, sz < 64 ? sz : 64);
      if (i % 3 == 0)
        p = realloc(p, sz * 2);
      int slot = rand_r(&seed) % 64;
      free(keep[id][slot]);
      keep[id][slot] = p;
    }
  char *leak = malloc(4000);
  memset(leak, 1, 4000);
  leak = NULL;
  return NULL;
}

int
main(void)
{
  pthread_t t[THREADS];
  for (long i = 0; i < THREADS; i++)
    pthread_create(&t[i], NULL, worker, (void *)i);
  for (int i = 0; i < THREADS; i++)
    pthread_join(t[i], NULL);
  puts("stress done");
  return 0;
}
