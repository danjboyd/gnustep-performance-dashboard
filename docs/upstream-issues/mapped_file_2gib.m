/* +[NSData dataWithContentsOfMappedFile:] on files either side of 2 GiB.

   clang `gnustep-config --objc-flags` mapped_file_2gib.m \
     -o mapped_file_2gib `gnustep-config --base-libs`  */

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void
try_size(long long size)
{
  char path[] = "/tmp/mapped_file_2gibXXXXXX";
  int fd = mkstemp(path);
  NSData *data;

  if (fd < 0 || ftruncate(fd, (off_t)size) != 0)
    {
      perror("creating the test file");
      exit(1);
    }
  close(fd);
  data = [NSData dataWithContentsOfMappedFile:
    [NSString stringWithUTF8String: path]];
  printf("%lld bytes: %s, length %llu\n", size,
         data ? object_getClassName(data) : "nil",
         (unsigned long long)[data length]);
  unlink(path);
}

int
main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];

  try_size(2147483646LL);   /* 2 GiB - 2 */
  try_size(2147483648LL);   /* 2 GiB */
  [pool release];
  return 0;
}
