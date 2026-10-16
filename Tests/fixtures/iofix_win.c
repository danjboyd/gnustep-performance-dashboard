/* iofix_win - the File Activity and Network fixture for Windows: writes
   100 KiB in ten WriteFile calls, flushes, reads it back with ReadFile and
   with stdio, tries two opens that fail, then sends 5000 bytes over a
   loopback TCP connection and reads them back.  */
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((noinline)) static void
write_file(const char *path)
{
  char block[10240];
  DWORD n;
  memset(block, 'a', sizeof(block));
  HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  for (int i = 0; i < 10; i++)
    WriteFile(h, block, sizeof(block), &n, NULL);
  FlushFileBuffers(h);
  CloseHandle(h);
}

__attribute__((noinline)) static void
read_file(const char *path)
{
  char buf[4096];
  DWORD n;
  HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  while (ReadFile(h, buf, sizeof(buf), &n, NULL) && n > 0)
    ;
  CloseHandle(h);
  FILE *f = fopen(path, "rb");
  while (fread(buf, 1, sizeof(buf), f) > 0)
    ;
  fclose(f);
  /* failures must pass through untouched */
  if (fopen("C:/nonexistent/iofix", "r") != NULL
      || CreateFileA("C:/nonexistent/iofix", GENERIC_READ, 0, NULL, OPEN_EXISTING, 0, NULL)
         != INVALID_HANDLE_VALUE)
    abort();
}

__attribute__((noinline)) static void
talk(void)
{
  SOCKET srv = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a;
  int al = sizeof(a);
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind(srv, (struct sockaddr *)&a, sizeof(a));
  listen(srv, 1);
  getsockname(srv, (struct sockaddr *)&a, &al);
  SOCKET c = socket(AF_INET, SOCK_STREAM, 0);
  connect(c, (struct sockaddr *)&a, sizeof(a));
  SOCKET s = accept(srv, NULL, NULL);
  char buf[5000];
  memset(buf, 'n', sizeof(buf));
  send(c, buf, sizeof(buf), 0);
  int got = 0;
  while (got < (int)sizeof(buf))
    {
      int n = recv(s, buf, sizeof(buf) - got, 0);
      if (n <= 0)
        break;
      got += n;
    }
  closesocket(c);
  closesocket(s);
  closesocket(srv);
}

int
main(int argc, char **argv)
{
  const char *path = argc > 1 ? argv[1] : "iofix.dat";
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  write_file(path);
  read_file(path);
  talk();
  DeleteFileA(path);
  WSACleanup();
  printf("io done\n");
  return 0;
}
