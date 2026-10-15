/* cburn - CPU, allocation and leak fixture for the runtime tests.  */
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

void *keep;
static volatile double sink;

__attribute__((noinline)) double
hot_inner(int n)
{
  double x = 0;
  for (int i = 0; i < n; i++)
    x += (double)i * 0.5;
  return x;
}

__attribute__((noinline)) void
hot_outer(int reps)
{
  for (int i = 0; i < reps; i++)
    sink += hot_inner(200000);
}

__attribute__((noinline)) void
leak_some(void)
{
  for (int i = 0; i < 10; i++)
    {
      char *p = malloc(48);
      memset(p, 'x', 48);
      p = NULL;   /* leaked */
    }
  keep = malloc(100); /* reachable from a global */
}

static void *
worker(void *arg)
{
  hot_outer(400);
  return arg;
}

int
main(void)
{
  pthread_t t;
  pthread_create(&t, NULL, worker, NULL);
  leak_some();
  hot_outer(800);
  pthread_join(t, NULL);
  printf("done %f\n", sink);
  return 0;
}
