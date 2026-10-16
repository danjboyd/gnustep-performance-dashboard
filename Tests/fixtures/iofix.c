/* iofix - File Activity and Network fixture: writes 100 KiB in ten
   writes, syncs, reads it back with read() and with stdio, then sends
   5000 bytes over a loopback TCP connection and reads them back.  */
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

__attribute__((noinline)) static void
write_file(const char *path)
{
  char block[10240];
  memset(block, 'a', sizeof(block));
  int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
  for (int i = 0; i < 10; i++)
    write(fd, block, sizeof(block));
  fsync(fd);
  close(fd);
}

__attribute__((noinline)) static void
read_file(const char *path)
{
  char buf[4096];
  int fd = open(path, O_RDONLY);
  while (read(fd, buf, sizeof(buf)) > 0)
    ;
  close(fd);
  FILE *f = fopen(path, "r");
  while (fread(buf, 1, sizeof(buf), f) > 0)
    ;
  fclose(f);
  /* failures must pass through untouched */
  if (fopen("/nonexistent/iofix", "r") != NULL || open("/nonexistent/iofix", O_RDONLY) >= 0)
    abort();
}

__attribute__((noinline)) static void
talk(void)
{
  int srv = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a;
  socklen_t al = sizeof(a);
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind(srv, (struct sockaddr *)&a, sizeof(a));
  listen(srv, 1);
  getsockname(srv, (struct sockaddr *)&a, &al);
  int c = socket(AF_INET, SOCK_STREAM, 0);
  connect(c, (struct sockaddr *)&a, sizeof(a));
  int s = accept(srv, NULL, NULL);
  char buf[5000];
  memset(buf, 'n', sizeof(buf));
  send(c, buf, sizeof(buf), 0);
  size_t got = 0;
  while (got < sizeof(buf))
    {
      ssize_t n = recv(s, buf, sizeof(buf) - got, 0);
      if (n <= 0)
        break;
      got += (size_t)n;
    }
  close(c);
  close(s);
  close(srv);
}

int
main(int argc, char **argv)
{
  const char *path = argc > 1 ? argv[1] : "/tmp/iofix.dat";
  write_file(path);
  read_file(path);
  talk();
  unlink(path);
  return 0;
}
