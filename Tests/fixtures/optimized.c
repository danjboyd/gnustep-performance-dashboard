/* A stable CPU workload that optimizers cannot hoist out of hot_outer. */
#include <stdio.h>
static volatile double input = 0.5;
static volatile double sink;

__attribute__((noinline)) double
hot_inner(int n)
{
  double sum = 0;
  for (int i = 0; i < n; i++)
    sum += i * input;
  return sum;
}

__attribute__((noinline)) void
hot_outer(void)
{
  for (int i = 0; i < 800; i++)
    sink = hot_inner(1000000);
}

int
main(void)
{
  hot_outer();
  printf("%f\n", sink);
  return 0;
}
