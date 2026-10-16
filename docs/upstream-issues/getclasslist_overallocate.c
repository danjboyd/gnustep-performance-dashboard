/* objc_getClassList with a buffer larger than the number of classes.
   Not for sending with the libobjc2 report unless Dan decides otherwise
   (docs/upstream-policy.md).

   cc getclasslist_overallocate.c -o getclasslist_overallocate -lobjc  */

#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

int
main(void)
{
  int n = objc_getClassList(NULL, 0);
  Class *buffer = malloc(sizeof(Class) * (n + 10));
  int got;

  printf("objc_getClassList(NULL, 0) = %d\n", n);
  got = objc_getClassList(buffer, n);
  printf("objc_getClassList(buffer, %d) = %d\n", n, got);
  fflush(stdout);
  got = objc_getClassList(buffer, n + 10);
  printf("objc_getClassList(buffer, %d) = %d\n", n + 10, got);
  free(buffer);
  return 0;
}
