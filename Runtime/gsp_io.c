/* gsp_io.c - File Activity and Network instruments.

   Interposes the POSIX file and socket entry points (and their
   _FORTIFY_SOURCE variants, which GNUstep's distribution builds call) plus
   stdio's fopen/fread/fwrite/fclose, and records each operation with its
   duration, result and call stack.  Descriptors are classified once (file,
   socket, other) and cached, so reads and writes on sockets count as
   network traffic and pipes or terminals are left out.

   Recording happens in normal context only through the thread's normal
   ring.  A signal handler that calls write() while the agent itself is
   emitting is skipped (gsp_in_agent), so the ring never has two
   producers.  */

#include "gsp_internal.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <netinet/in.h>

static atomic_int files_on, net_on;

enum { FD_UNKNOWN = 0, FD_FILE = 1, FD_SOCKET = 2, FD_OTHER = 3 };
#define FD_TABLE 65536
static _Atomic uint8_t fd_kind[FD_TABLE];

void
gsp_io_init(void)
{
  atomic_store(&files_on, gsp_cfg.file_io);
  atomic_store(&net_on, gsp_cfg.network);
}

void
gsp_io_stop(void)
{
  atomic_store(&files_on, 0);
  atomic_store(&net_on, 0);
}

static inline bool
active(void)
{
  return (atomic_load_explicit(&files_on, memory_order_relaxed)
          || atomic_load_explicit(&net_on, memory_order_relaxed))
    && !gsp_in_agent && !gsp_is_internal
    && atomic_load_explicit(&gsp_recording, memory_order_relaxed);
}

static int
kind_of(int fd)
{
  struct stat st;
  int k;

  if (fd < 0)
    return FD_OTHER;
  if (fd < FD_TABLE && (k = atomic_load_explicit(&fd_kind[fd], memory_order_relaxed)) != 0)
    return k;
  k = FD_OTHER;
  if (fstat(fd, &st) == 0)
    {
      if (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode) || S_ISBLK(st.st_mode))
        k = FD_FILE;
      else if (S_ISSOCK(st.st_mode))
        k = FD_SOCKET;
    }
  if (fd < FD_TABLE)
    atomic_store_explicit(&fd_kind[fd], (uint8_t)k, memory_order_relaxed);
  return k;
}

static inline void
set_kind(int fd, int k)
{
  if (fd >= 0 && fd < FD_TABLE)
    atomic_store_explicit(&fd_kind[fd], (uint8_t)k, memory_order_relaxed);
}

static void
emit(int op, int fd, int64_t result, uint64_t start, uint64_t end,
     const char *name, int flags)
{
  gsp_thread *t;
  int saved = errno;

  gsp_in_agent++;
  t = gsp_thread_current();
  if (t != NULL)
    {
      gsp_io_payload p;
      p.result = result;
      p.duration = end > start ? end - start : 0;
      p.fd = fd;
      p.name = name ? gsp_intern_string(name) : 0;
      p.stack = gsp_current_stack_id(t);
      p.flags = (uint32_t)flags;
      gsp_emit_normal(t, GSP_REC_IO, (uint32_t)op, 0, start, &p, sizeof(p), NULL, 0);
    }
  gsp_in_agent--;
  errno = saved;
}

/* Record a read/write-style operation on fd, classified by its kind.  */
static void
data_op(int fd, bool is_write, ssize_t r, uint64_t start, uint64_t end)
{
  int k = kind_of(fd);
  int64_t res = r < 0 ? -(int64_t)errno : (int64_t)r;
  if (k == FD_FILE && atomic_load(&files_on))
    emit(is_write ? GSP_IO_WRITE : GSP_IO_READ, fd, res, start, end, NULL, 0);
  else if (k == FD_SOCKET && atomic_load(&net_on))
    emit(is_write ? GSP_IO_SEND : GSP_IO_RECV, fd, res, start, end, NULL, 0);
}

static void
format_peer(const struct sockaddr *sa, socklen_t len, char *out, size_t cap)
{
  out[0] = 0;
  if (sa == NULL || len < sizeof(sa_family_t))
    return;
  if (sa->sa_family == AF_INET && len >= sizeof(struct sockaddr_in))
    {
      const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
      char a[INET_ADDRSTRLEN];
      inet_ntop(AF_INET, &in->sin_addr, a, sizeof(a));
      snprintf(out, cap, "%s:%u", a, ntohs(in->sin_port));
    }
  else if (sa->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6))
    {
      const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sa;
      char a[INET6_ADDRSTRLEN];
      inet_ntop(AF_INET6, &in6->sin6_addr, a, sizeof(a));
      snprintf(out, cap, "[%s]:%u", a, ntohs(in6->sin6_port));
    }
  else if (sa->sa_family == AF_UNIX)
    {
      const struct sockaddr_un *un = (const struct sockaddr_un *)sa;
      size_t n = len - offsetof(struct sockaddr_un, sun_path);
      if (n > 0 && un->sun_path[0] == 0)
        snprintf(out, cap, "unix:@%.*s", (int)(n > 1 ? n - 1 : 0), un->sun_path + 1);
      else
        snprintf(out, cap, "unix:%.*s", (int)strnlen(un->sun_path, n), un->sun_path);
    }
  else
    snprintf(out, cap, "family %d", sa->sa_family);
}

#define REAL(name, ret, args)                                         \
  if (__builtin_expect(real_##name == NULL, 0))                       \
    real_##name = (ret (*) args)dlsym(RTLD_NEXT, #name)

/* Real entry points, resolved once at the start of the agent's
   constructor (hooks fall back to resolving lazily when called by other
   libraries' constructors earlier).  */
static int (*real___open64_2) (const char *, int);
static int (*real___open_2) (const char *, int);
static int (*real___openat_2) (int, const char *, int);
static ssize_t (*real___pread64_chk) (int, void *, size_t, off_t, size_t);
static ssize_t (*real___pread_chk) (int, void *, size_t, off_t, size_t);
static ssize_t (*real___read_chk) (int, void *, size_t, size_t);
static ssize_t (*real___recv_chk) (int, void *, size_t, size_t, int);
static ssize_t (*real___recvfrom_chk) (int, void *, size_t, size_t, int, struct sockaddr *, socklen_t *);
static int (*real_accept) (int, struct sockaddr *, socklen_t *);
static int (*real_accept4) (int, struct sockaddr *, socklen_t *, int);
static int (*real_close) (int);
static int (*real_connect) (int, const struct sockaddr *, socklen_t);
static int (*real_creat) (const char *, mode_t);
static int (*real_dup) (int);
static int (*real_dup2) (int, int);
static int (*real_dup3) (int, int, int);
static int (*real_fclose) (FILE *);
static int (*real_fdatasync) (int);
static FILE * (*real_fopen) (const char *, const char *);
static FILE * (*real_fopen64) (const char *, const char *);
static size_t (*real_fread) (void *, size_t, size_t, FILE *);
static int (*real_fsync) (int);
static size_t (*real_fwrite) (const void *, size_t, size_t, FILE *);
static int (*real_open) (const char *, int, ...);
static int (*real_open64) (const char *, int, ...);
static int (*real_openat) (int, const char *, int, ...);
static int (*real_openat64) (int, const char *, int, ...);
static ssize_t (*real_pread) (int, void *, size_t, off_t);
static ssize_t (*real_pread64) (int, void *, size_t, off_t);
static ssize_t (*real_pwrite) (int, const void *, size_t, off_t);
static ssize_t (*real_pwrite64) (int, const void *, size_t, off_t);
static ssize_t (*real_read) (int, void *, size_t);
static ssize_t (*real_readv) (int, const struct iovec *, int);
static ssize_t (*real_recv) (int, void *, size_t, int);
static ssize_t (*real_recvfrom) (int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t (*real_recvmsg) (int, struct msghdr *, int);
static ssize_t (*real_send) (int, const void *, size_t, int);
static ssize_t (*real_sendmsg) (int, const struct msghdr *, int);
static ssize_t (*real_sendto) (int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static int (*real_socket) (int, int, int);
static ssize_t (*real_write) (int, const void *, size_t);
static ssize_t (*real_writev) (int, const struct iovec *, int);

void
gsp_io_resolve(void)
{
  if (real___open64_2 == NULL)
    real___open64_2 = (int (*) (const char *, int))dlsym(RTLD_NEXT, "__open64_2");
  if (real___open_2 == NULL)
    real___open_2 = (int (*) (const char *, int))dlsym(RTLD_NEXT, "__open_2");
  if (real___openat_2 == NULL)
    real___openat_2 = (int (*) (int, const char *, int))dlsym(RTLD_NEXT, "__openat_2");
  if (real___pread64_chk == NULL)
    real___pread64_chk = (ssize_t (*) (int, void *, size_t, off_t, size_t))dlsym(RTLD_NEXT, "__pread64_chk");
  if (real___pread_chk == NULL)
    real___pread_chk = (ssize_t (*) (int, void *, size_t, off_t, size_t))dlsym(RTLD_NEXT, "__pread_chk");
  if (real___read_chk == NULL)
    real___read_chk = (ssize_t (*) (int, void *, size_t, size_t))dlsym(RTLD_NEXT, "__read_chk");
  if (real___recv_chk == NULL)
    real___recv_chk = (ssize_t (*) (int, void *, size_t, size_t, int))dlsym(RTLD_NEXT, "__recv_chk");
  if (real___recvfrom_chk == NULL)
    real___recvfrom_chk = (ssize_t (*) (int, void *, size_t, size_t, int, struct sockaddr *, socklen_t *))dlsym(RTLD_NEXT, "__recvfrom_chk");
  if (real_accept == NULL)
    real_accept = (int (*) (int, struct sockaddr *, socklen_t *))dlsym(RTLD_NEXT, "accept");
  if (real_accept4 == NULL)
    real_accept4 = (int (*) (int, struct sockaddr *, socklen_t *, int))dlsym(RTLD_NEXT, "accept4");
  if (real_close == NULL)
    real_close = (int (*) (int))dlsym(RTLD_NEXT, "close");
  if (real_connect == NULL)
    real_connect = (int (*) (int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "connect");
  if (real_creat == NULL)
    real_creat = (int (*) (const char *, mode_t))dlsym(RTLD_NEXT, "creat");
  if (real_dup == NULL)
    real_dup = (int (*) (int))dlsym(RTLD_NEXT, "dup");
  if (real_dup2 == NULL)
    real_dup2 = (int (*) (int, int))dlsym(RTLD_NEXT, "dup2");
  if (real_dup3 == NULL)
    real_dup3 = (int (*) (int, int, int))dlsym(RTLD_NEXT, "dup3");
  if (real_fclose == NULL)
    real_fclose = (int (*) (FILE *))dlsym(RTLD_NEXT, "fclose");
  if (real_fdatasync == NULL)
    real_fdatasync = (int (*) (int))dlsym(RTLD_NEXT, "fdatasync");
  if (real_fopen == NULL)
    real_fopen = (FILE * (*) (const char *, const char *))dlsym(RTLD_NEXT, "fopen");
  if (real_fopen64 == NULL)
    real_fopen64 = (FILE * (*) (const char *, const char *))dlsym(RTLD_NEXT, "fopen64");
  if (real_fread == NULL)
    real_fread = (size_t (*) (void *, size_t, size_t, FILE *))dlsym(RTLD_NEXT, "fread");
  if (real_fsync == NULL)
    real_fsync = (int (*) (int))dlsym(RTLD_NEXT, "fsync");
  if (real_fwrite == NULL)
    real_fwrite = (size_t (*) (const void *, size_t, size_t, FILE *))dlsym(RTLD_NEXT, "fwrite");
  if (real_open == NULL)
    real_open = (int (*) (const char *, int, ...))dlsym(RTLD_NEXT, "open");
  if (real_open64 == NULL)
    real_open64 = (int (*) (const char *, int, ...))dlsym(RTLD_NEXT, "open64");
  if (real_openat == NULL)
    real_openat = (int (*) (int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
  if (real_openat64 == NULL)
    real_openat64 = (int (*) (int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
  if (real_pread == NULL)
    real_pread = (ssize_t (*) (int, void *, size_t, off_t))dlsym(RTLD_NEXT, "pread");
  if (real_pread64 == NULL)
    real_pread64 = (ssize_t (*) (int, void *, size_t, off_t))dlsym(RTLD_NEXT, "pread64");
  if (real_pwrite == NULL)
    real_pwrite = (ssize_t (*) (int, const void *, size_t, off_t))dlsym(RTLD_NEXT, "pwrite");
  if (real_pwrite64 == NULL)
    real_pwrite64 = (ssize_t (*) (int, const void *, size_t, off_t))dlsym(RTLD_NEXT, "pwrite64");
  if (real_read == NULL)
    real_read = (ssize_t (*) (int, void *, size_t))dlsym(RTLD_NEXT, "read");
  if (real_readv == NULL)
    real_readv = (ssize_t (*) (int, const struct iovec *, int))dlsym(RTLD_NEXT, "readv");
  if (real_recv == NULL)
    real_recv = (ssize_t (*) (int, void *, size_t, int))dlsym(RTLD_NEXT, "recv");
  if (real_recvfrom == NULL)
    real_recvfrom = (ssize_t (*) (int, void *, size_t, int, struct sockaddr *, socklen_t *))dlsym(RTLD_NEXT, "recvfrom");
  if (real_recvmsg == NULL)
    real_recvmsg = (ssize_t (*) (int, struct msghdr *, int))dlsym(RTLD_NEXT, "recvmsg");
  if (real_send == NULL)
    real_send = (ssize_t (*) (int, const void *, size_t, int))dlsym(RTLD_NEXT, "send");
  if (real_sendmsg == NULL)
    real_sendmsg = (ssize_t (*) (int, const struct msghdr *, int))dlsym(RTLD_NEXT, "sendmsg");
  if (real_sendto == NULL)
    real_sendto = (ssize_t (*) (int, const void *, size_t, int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "sendto");
  if (real_socket == NULL)
    real_socket = (int (*) (int, int, int))dlsym(RTLD_NEXT, "socket");
  if (real_write == NULL)
    real_write = (ssize_t (*) (int, const void *, size_t))dlsym(RTLD_NEXT, "write");
  if (real_writev == NULL)
    real_writev = (ssize_t (*) (int, const struct iovec *, int))dlsym(RTLD_NEXT, "writev");
}


/* ------------------------------------------------------------------ */
/* opening and closing                                                 */

static int
after_open(int fd, const char *path, int flags, uint64_t start)
{
  if (fd >= 0)
    set_kind(fd, FD_UNKNOWN);
  if (atomic_load(&files_on))
    {
      int saved = errno;
      int k = fd >= 0 ? kind_of(fd) : FD_FILE;
      if (k == FD_FILE)
        emit(GSP_IO_OPEN, fd, fd >= 0 ? fd : -(int64_t)saved, start, gsp_now(), path, flags);
      errno = saved;
    }
  return fd;
}

static inline bool
open_needs_mode(int flags)
{
  return (flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE;
}

#define OPEN_HOOK(name)                                                \
  GSP_EXPORT int                                                       \
  name(const char *path, int flags, ...)                               \
  {                                                                    \
    REAL(name, int, (const char *, int, ...));                         \
    mode_t mode = 0;                                                   \
    if (open_needs_mode(flags))                                        \
      {                                                                \
        va_list ap;                                                    \
        va_start(ap, flags);                                           \
        mode = (mode_t)va_arg(ap, int);                                \
        va_end(ap);                                                    \
      }                                                                \
    if (!active())                                                     \
      {                                                                \
        int fd = real_##name(path, flags, mode);                       \
        if (fd >= 0)                                                   \
          set_kind(fd, FD_UNKNOWN);                                    \
        return fd;                                                     \
      }                                                                \
    uint64_t start = gsp_now();                                        \
    return after_open(real_##name(path, flags, mode), path, flags, start); \
  }

OPEN_HOOK(open)
OPEN_HOOK(open64)

#define OPENAT_HOOK(name)                                              \
  GSP_EXPORT int                                                       \
  name(int dirfd, const char *path, int flags, ...)                    \
  {                                                                    \
    REAL(name, int, (int, const char *, int, ...));                    \
    mode_t mode = 0;                                                   \
    if (open_needs_mode(flags))                                        \
      {                                                                \
        va_list ap;                                                    \
        va_start(ap, flags);                                           \
        mode = (mode_t)va_arg(ap, int);                                \
        va_end(ap);                                                    \
      }                                                                \
    if (!active())                                                     \
      {                                                                \
        int fd = real_##name(dirfd, path, flags, mode);                \
        if (fd >= 0)                                                   \
          set_kind(fd, FD_UNKNOWN);                                    \
        return fd;                                                     \
      }                                                                \
    uint64_t start = gsp_now();                                        \
    return after_open(real_##name(dirfd, path, flags, mode), path, flags, start); \
  }

OPENAT_HOOK(openat)
OPENAT_HOOK(openat64)

/* _FORTIFY_SOURCE: open(path, flags) without a mode becomes __open_2 */
GSP_EXPORT int
__open_2(const char *path, int flags)
{
  REAL(__open_2, int, (const char *, int));
  if (!active())
    {
      int fd = real___open_2(path, flags);
      if (fd >= 0)
        set_kind(fd, FD_UNKNOWN);
      return fd;
    }
  uint64_t start = gsp_now();
  return after_open(real___open_2(path, flags), path, flags, start);
}

GSP_EXPORT int
__open64_2(const char *path, int flags)
{
  REAL(__open64_2, int, (const char *, int));
  if (!active())
    {
      int fd = real___open64_2(path, flags);
      if (fd >= 0)
        set_kind(fd, FD_UNKNOWN);
      return fd;
    }
  uint64_t start = gsp_now();
  return after_open(real___open64_2(path, flags), path, flags, start);
}

GSP_EXPORT int
__openat_2(int dirfd, const char *path, int flags)
{
  REAL(__openat_2, int, (int, const char *, int));
  if (!active())
    {
      int fd = real___openat_2(dirfd, path, flags);
      if (fd >= 0)
        set_kind(fd, FD_UNKNOWN);
      return fd;
    }
  uint64_t start = gsp_now();
  return after_open(real___openat_2(dirfd, path, flags), path, flags, start);
}

GSP_EXPORT int
creat(const char *path, mode_t mode)
{
  REAL(creat, int, (const char *, mode_t));
  if (!active())
    {
      int fd = real_creat(path, mode);
      if (fd >= 0)
        set_kind(fd, FD_UNKNOWN);
      return fd;
    }
  uint64_t start = gsp_now();
  return after_open(real_creat(path, mode), path, O_CREAT | O_WRONLY | O_TRUNC, start);
}

GSP_EXPORT int
close(int fd)
{
  REAL(close, int, (int));
  if (!active())
    {
      set_kind(fd, FD_UNKNOWN);
      return real_close(fd);
    }
  int k = kind_of(fd);
  uint64_t start = gsp_now();
  int r = real_close(fd);
  int saved = errno;
  set_kind(fd, FD_UNKNOWN);
  if ((k == FD_FILE && atomic_load(&files_on)) || (k == FD_SOCKET && atomic_load(&net_on)))
    emit(GSP_IO_CLOSE, fd, r < 0 ? -(int64_t)saved : 0, start, gsp_now(), NULL,
         k == FD_SOCKET ? (int)GSP_IO_SOCKET : 0);
  errno = saved;
  return r;
}

/* ------------------------------------------------------------------ */
/* data                                                                */

#define DATA_HOOK(name, is_write, params, call)                        \
  GSP_EXPORT ssize_t                                                   \
  name params                                                          \
  {                                                                    \
    REAL(name, ssize_t, params);                                       \
    if (!active())                                                     \
      return real_##name call;                                         \
    uint64_t start = gsp_now();                                        \
    ssize_t r = real_##name call;                                      \
    int saved = errno;                                                 \
    data_op(fd, is_write, r, start, gsp_now());                        \
    errno = saved;                                                     \
    return r;                                                          \
  }

DATA_HOOK(read, false, (int fd, void *buf, size_t n), (fd, buf, n))
DATA_HOOK(write, true, (int fd, const void *buf, size_t n), (fd, buf, n))
DATA_HOOK(pread, false, (int fd, void *buf, size_t n, off_t off), (fd, buf, n, off))
DATA_HOOK(pwrite, true, (int fd, const void *buf, size_t n, off_t off), (fd, buf, n, off))
DATA_HOOK(pread64, false, (int fd, void *buf, size_t n, off_t off), (fd, buf, n, off))
DATA_HOOK(pwrite64, true, (int fd, const void *buf, size_t n, off_t off), (fd, buf, n, off))
DATA_HOOK(readv, false, (int fd, const struct iovec *iov, int c), (fd, iov, c))
DATA_HOOK(writev, true, (int fd, const struct iovec *iov, int c), (fd, iov, c))
DATA_HOOK(__read_chk, false, (int fd, void *buf, size_t n, size_t bl), (fd, buf, n, bl))
DATA_HOOK(__pread_chk, false, (int fd, void *buf, size_t n, off_t o, size_t bl), (fd, buf, n, o, bl))
DATA_HOOK(__pread64_chk, false, (int fd, void *buf, size_t n, off_t o, size_t bl), (fd, buf, n, o, bl))
DATA_HOOK(send, true, (int fd, const void *buf, size_t n, int fl), (fd, buf, n, fl))
DATA_HOOK(recv, false, (int fd, void *buf, size_t n, int fl), (fd, buf, n, fl))
DATA_HOOK(__recv_chk, false, (int fd, void *buf, size_t n, size_t bl, int fl), (fd, buf, n, bl, fl))
DATA_HOOK(sendto, true, (int fd, const void *buf, size_t n, int fl, const struct sockaddr *a, socklen_t l), (fd, buf, n, fl, a, l))
DATA_HOOK(recvfrom, false, (int fd, void *buf, size_t n, int fl, struct sockaddr *a, socklen_t *l), (fd, buf, n, fl, a, l))
DATA_HOOK(__recvfrom_chk, false, (int fd, void *buf, size_t n, size_t bl, int fl, struct sockaddr *a, socklen_t *l), (fd, buf, n, bl, fl, a, l))
DATA_HOOK(sendmsg, true, (int fd, const struct msghdr *m, int fl), (fd, m, fl))
DATA_HOOK(recvmsg, false, (int fd, struct msghdr *m, int fl), (fd, m, fl))

#define SYNC_HOOK(name)                                                \
  GSP_EXPORT int                                                       \
  name(int fd)                                                         \
  {                                                                    \
    REAL(name, int, (int));                                            \
    if (!active() || !atomic_load(&files_on))                          \
      return real_##name(fd);                                          \
    uint64_t start = gsp_now();                                        \
    int r = real_##name(fd);                                           \
    int saved = errno;                                                 \
    if (kind_of(fd) == FD_FILE)                                        \
      emit(GSP_IO_SYNC, fd, r < 0 ? -(int64_t)saved : 0, start, gsp_now(), NULL, 0); \
    errno = saved;                                                     \
    return r;                                                          \
  }

SYNC_HOOK(fsync)
SYNC_HOOK(fdatasync)

/* ------------------------------------------------------------------ */
/* sockets                                                             */

GSP_EXPORT int
socket(int domain, int type, int protocol)
{
  REAL(socket, int, (int, int, int));
  int fd = real_socket(domain, type, protocol);
  if (fd >= 0)
    set_kind(fd, FD_SOCKET);
  return fd;
}

GSP_EXPORT int
connect(int fd, const struct sockaddr *addr, socklen_t len)
{
  REAL(connect, int, (int, const struct sockaddr *, socklen_t));
  if (!active() || !atomic_load(&net_on))
    return real_connect(fd, addr, len);
  uint64_t start = gsp_now();
  int r = real_connect(fd, addr, len);
  int saved = errno;
  char peer[160];
  set_kind(fd, FD_SOCKET);
  format_peer(addr, len, peer, sizeof(peer));
  emit(GSP_IO_CONNECT, fd, r < 0 ? -(int64_t)saved : 0, start, gsp_now(), peer, 0);
  errno = saved;
  return r;
}

static int
after_accept(int fd, struct sockaddr *addr, socklen_t *len, uint64_t start)
{
  int saved = errno;
  if (fd >= 0)
    set_kind(fd, FD_SOCKET);
  if (atomic_load(&net_on))
    {
      char peer[160] = "";
      struct sockaddr_storage ss;
      socklen_t sl = sizeof(ss);
      if (fd >= 0 && addr && len)
        format_peer(addr, *len, peer, sizeof(peer));
      else if (fd >= 0 && getpeername(fd, (struct sockaddr *)&ss, &sl) == 0)
        format_peer((struct sockaddr *)&ss, sl, peer, sizeof(peer));
      emit(GSP_IO_ACCEPT, fd, fd >= 0 ? fd : -(int64_t)saved, start, gsp_now(),
           peer[0] ? peer : NULL, 0);
    }
  errno = saved;
  return fd;
}

GSP_EXPORT int
accept(int fd, struct sockaddr *addr, socklen_t *len)
{
  REAL(accept, int, (int, struct sockaddr *, socklen_t *));
  if (!active())
    {
      int r = real_accept(fd, addr, len);
      if (r >= 0)
        set_kind(r, FD_SOCKET);
      return r;
    }
  uint64_t start = gsp_now();
  return after_accept(real_accept(fd, addr, len), addr, len, start);
}

GSP_EXPORT int
accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags)
{
  REAL(accept4, int, (int, struct sockaddr *, socklen_t *, int));
  if (!active())
    {
      int r = real_accept4(fd, addr, len, flags);
      if (r >= 0)
        set_kind(r, FD_SOCKET);
      return r;
    }
  uint64_t start = gsp_now();
  return after_accept(real_accept4(fd, addr, len, flags), addr, len, start);
}

/* ------------------------------------------------------------------ */
/* stdio (glibc's stdio does its own I/O without going through the
   symbols above)                                                      */

#define FOPEN_HOOK(name)                                               \
  GSP_EXPORT FILE *                                                    \
  name(const char *path, const char *mode)                             \
  {                                                                    \
    REAL(name, FILE *, (const char *, const char *));                  \
    if (!active() || !atomic_load(&files_on))                          \
      {                                                                \
        FILE *f = real_##name(path, mode);                             \
        if (f)                                                         \
          set_kind(fileno(f), FD_UNKNOWN);                             \
        return f;                                                      \
      }                                                                \
    uint64_t start = gsp_now();                                        \
    FILE *f = real_##name(path, mode);                                 \
    int saved = errno;                                                 \
    int fd = f ? fileno(f) : -1;                                       \
    if (fd >= 0)                                                       \
      set_kind(fd, FD_UNKNOWN);                                        \
    if (fd < 0 || kind_of(fd) == FD_FILE)                              \
      emit(GSP_IO_OPEN, fd, fd >= 0 ? fd : -(int64_t)saved, start,     \
           gsp_now(), path, mode && mode[0] == 'r' && mode[1] != '+' ? O_RDONLY : O_WRONLY); \
    errno = saved;                                                     \
    return f;                                                          \
  }

FOPEN_HOOK(fopen)
FOPEN_HOOK(fopen64)

GSP_EXPORT int
fclose(FILE *f)
{
  REAL(fclose, int, (FILE *));
  int fd = fileno(f);
  if (!active() || fd < 0)
    {
      set_kind(fd, FD_UNKNOWN);
      return real_fclose(f);
    }
  int k = kind_of(fd);
  uint64_t start = gsp_now();
  int r = real_fclose(f);
  int saved = errno;
  set_kind(fd, FD_UNKNOWN);
  if (k == FD_FILE && atomic_load(&files_on))
    emit(GSP_IO_CLOSE, fd, r < 0 ? -(int64_t)saved : 0, start, gsp_now(), NULL, 0);
  errno = saved;
  return r;
}

GSP_EXPORT size_t
fread(void *buf, size_t size, size_t n, FILE *f)
{
  REAL(fread, size_t, (void *, size_t, size_t, FILE *));
  if (!active() || !atomic_load(&files_on))
    return real_fread(buf, size, n, f);
  uint64_t start = gsp_now();
  size_t r = real_fread(buf, size, n, f);
  int saved = errno;
  int fd = fileno(f);
  if (fd >= 0 && kind_of(fd) == FD_FILE)
    emit(GSP_IO_READ, fd, (int64_t)(r * size), start, gsp_now(), NULL, 0);
  errno = saved;
  return r;
}

GSP_EXPORT size_t
fwrite(const void *buf, size_t size, size_t n, FILE *f)
{
  REAL(fwrite, size_t, (const void *, size_t, size_t, FILE *));
  if (!active() || !atomic_load(&files_on))
    return real_fwrite(buf, size, n, f);
  uint64_t start = gsp_now();
  size_t r = real_fwrite(buf, size, n, f);
  int saved = errno;
  int fd = fileno(f);
  if (fd >= 0 && kind_of(fd) == FD_FILE)
    emit(GSP_IO_WRITE, fd, (int64_t)(r * size), start, gsp_now(), NULL, 0);
  errno = saved;
  return r;
}

/* ------------------------------------------------------------------ */
/* descriptor reuse: forget the cached kind of the target descriptor   */

GSP_EXPORT int
dup(int fd)
{
  REAL(dup, int, (int));
  int r = real_dup(fd);
  if (r >= 0)
    set_kind(r, FD_UNKNOWN);
  return r;
}

GSP_EXPORT int
dup2(int fd, int fd2)
{
  REAL(dup2, int, (int, int));
  int r = real_dup2(fd, fd2);
  if (r >= 0)
    set_kind(r, FD_UNKNOWN);
  return r;
}

GSP_EXPORT int
dup3(int fd, int fd2, int flags)
{
  REAL(dup3, int, (int, int, int));
  int r = real_dup3(fd, fd2, flags);
  if (r >= 0)
    set_kind(r, FD_UNKNOWN);
  return r;
}
