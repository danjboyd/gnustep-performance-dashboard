/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Unprivileged, libc-only NSTask exec trampoline. No target environment is
   installed until execve. FD 0 is a private startup socket, not target stdin. */
#include "gsp_launch_protocol.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int channel = 0;

static void
fail(int code)
{
  struct gsp_launch_reply reply = {0, code ? code : EIO};
  (void) send(channel, &reply, sizeof(reply), MSG_NOSIGNAL);
  _exit(GSP_LAUNCH_FAILURE);
}

static char *
next_string(char **cursor, char *end)
{
  char *s = *cursor;
  char *nul = memchr(s, 0, end - s);
  if (!nul) fail(EPROTO);
  *cursor = nul + 1;
  return s;
}

static void
close_extra_descriptors(void)
{
  /* /proc enumerates descriptors above a subsequently lowered RLIMIT too.
     Only 0..4 survive; dirfd is closed with the enumeration. */
  DIR *dir = opendir("/proc/self/fd");
  if (!dir) fail(errno);
  struct dirent *entry;
  for (;;)
    {
      errno = 0;
      entry = readdir(dir);
      if (!entry) { if (errno) fail(errno); break; }
      char *end;
      long fd = strtol(entry->d_name, &end, 10);
      if (!*end && fd > 4 && fd != dirfd(dir)) close((int)fd);
    }
  closedir(dir);
}

int
main(int argc, char **argv)
{
  (void)argv;
  if (argc != 1) fail(EINVAL);
  int type = 0;
  socklen_t type_size = sizeof(type);
  if (getsockopt(0, SOL_SOCKET, SO_TYPE, &type, &type_size)
      || type != SOCK_SEQPACKET) fail(EPROTO);
  struct timeval timeout = {5, 0};
  if (setsockopt(0, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout))) fail(errno);
  struct gsp_launch_header header;
  union { struct cmsghdr align; char bytes[CMSG_SPACE(4 * sizeof(int))]; } control;
  struct iovec io = {&header, sizeof(header)};
  struct msghdr message = {0};
  message.msg_iov = &io;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
  message.msg_controllen = sizeof(control.bytes);
  ssize_t n;
  do n = recvmsg(0, &message, MSG_CMSG_CLOEXEC); while (n < 0 && errno == EINTR);
  if (n != sizeof(header) || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC))
      || header.magic != GSP_LAUNCH_MAGIC || header.version != 1
      || !header.bytes || header.bytes > GSP_LAUNCH_LIMIT || !header.argc
      || header.argc > header.bytes || header.envc > header.bytes
      || (header.stdio_mask & ~7u) || header.reserved[0] || header.reserved[1])
    fail(EPROTO);
  unsigned count = 1;
  for (unsigned i = 0; i < 3; i++) count += !!(header.stdio_mask & (1u << i));
  struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
  if (!cmsg || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS
      || cmsg->cmsg_len != CMSG_LEN(count * sizeof(int))
      || CMSG_NXTHDR(&message, cmsg)) fail(EPROTO);
  int received[4], saved[4];
  memcpy(received, CMSG_DATA(cmsg), count * sizeof(int));
  for (unsigned i = 0; i < count; i++)
    {
      saved[i] = fcntl(received[i], F_DUPFD_CLOEXEC, 10);
      if (saved[i] < 0) fail(errno);
    }
  for (unsigned i = 0; i < count; i++) close(received[i]);
  char *payload = malloc(header.bytes);
  if (!payload) fail(ENOMEM);
  size_t used = 0;
  while (used < header.bytes)
    {
      do n = recv(0, payload + used, header.bytes - used, MSG_TRUNC);
      while (n < 0 && errno == EINTR);
      if (n <= 0 || (size_t)n > header.bytes - used) fail(n < 0 ? errno : EPROTO);
      used += n;
    }
  char *cursor = payload, *end = payload + header.bytes;
  char *cwd = next_string(&cursor, end);
  char **args = calloc((size_t)header.argc + 1, sizeof(char *));
  char **env = calloc((size_t)header.envc + 1, sizeof(char *));
  if (!args || !env) fail(ENOMEM);
  for (unsigned i = 0; i < header.argc; i++) args[i] = next_string(&cursor, end);
  for (unsigned i = 0; i < header.envc; i++)
    {
      env[i] = next_string(&cursor, end);
      if (!strchr(env[i], '=') || env[i][0] == '=') fail(EPROTO);
    }
  if (cursor != end || !args[0][0]) fail(EPROTO);
  if (args[0][0] != '/') fail(EINVAL);
  /* Preserve a separate, CLOEXEC error channel before replacing stdin. */
  int copy = fcntl(0, F_DUPFD_CLOEXEC, 10);
  if (copy < 0 || dup3(copy, 3, O_CLOEXEC) < 0) fail(errno);
  channel = 3;
  unsigned index = 0;
  for (unsigned i = 0; i < 3; i++)
    {
      if (header.stdio_mask & (1u << i))
        { if (dup2(saved[index++], i) < 0) fail(errno); }
      else close(i);
    }
  if (dup2(saved[index], 4) < 0) fail(errno);
  close_extra_descriptors();
  if (*cwd && chdir(cwd)) fail(errno);
  /* exec resets caught handlers, but preserves ignored dispositions. Restore
     the recorder's ignored set after NSTask's default reset, plus the old
     recorder's empty signal mask. */
  struct sigaction ignored = {0};
  ignored.sa_handler = SIG_IGN;
  sigemptyset(&ignored.sa_mask);
  for (int number = 1; number < NSIG && number <= 64; number++)
    if ((header.ignored_signals & (UINT64_C(1) << (number - 1)))
        && sigaction(number, &ignored, NULL) && errno != EINVAL) fail(errno);
  sigset_t empty;
  sigemptyset(&empty);
  if (sigprocmask(SIG_SETMASK, &empty, NULL)) fail(errno);
  struct gsp_launch_reply ready = {1, 0};
  if (send(channel, &ready, sizeof(ready), MSG_NOSIGNAL) != sizeof(ready)) fail(errno);
  execve(args[0], args, env);
  fail(errno);
}
