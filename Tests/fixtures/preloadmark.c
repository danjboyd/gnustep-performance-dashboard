/* preloadmark - a library for LD_PRELOAD that creates the file named by
   PRELOAD_MARK when it is loaded: shows that a preload the user asked for
   (gstrace record --env LD_PRELOAD=...) was loaded with the agent.  */
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void
preloadmark(void)
{
  const char *path = getenv("PRELOAD_MARK");
  int fd;

  if (path == NULL)
    return;
  fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd >= 0)
    close(fd);
}
