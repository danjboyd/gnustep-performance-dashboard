/* SPDX-License-Identifier: GPL-3.0-or-later */
/* gstrace-helper - privileged perf_event sampling for Performance Dashboard.

   Runs as root through pkexec (installed at /usr/local/libexec/gstrace-helper
   with the org.gnustep.performancedashboard polkit policy), or unprivileged when
   kernel.perf_event_paranoid allows it.

     gstrace-helper record --pid PID --output DIR [--duration SECS] [--frequency HZ]
     gstrace-helper install --source DIR      (root: install helper + policy)
     gstrace-helper uninstall                 (root)
     gstrace-helper version

   Safety rules when running as root on behalf of another user:
   - only processes owned by the invoking user can be sampled;
   - DIR must be a real directory owned by the invoking user; files are
     created with O_NOFOLLOW|O_EXCL relative to that directory and handed to
     the invoking user;
   - nothing from the environment except PKEXEC_UID is trusted.  */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>

#include "GSPerformance/gsp_format.h"

#define HELPER_VERSION "0.1.1"
#define INSTALL_PATH "/usr/local/libexec/gstrace-helper"
#define POLICY_DIR "/usr/share/polkit-1/actions"
#define POLICY_NAME "org.gnustep.performancedashboard.policy"
/* The policy's name before the project was renamed; removed on install
   and uninstall.  */
#define OLD_POLICY_NAME "org.gnustep.instruments.policy"
#define MAX_THREADS 4096
#define RING_PAGES 64  /* data pages per event, power of two */

static uid_t invoking_uid;
static gid_t invoking_gid;
static int dir_fd = -1;
static int out_fd = -1;
static volatile sig_atomic_t interrupted;

static void
die(const char *fmt, ...)
{
  va_list ap;
  fprintf(stderr, "gstrace-helper: ");
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fprintf(stderr, "\n");
  exit(1);
}

static uint64_t
now_ns(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void
on_signal(int sig)
{
  (void)sig;
  interrupted = 1;
}

/* ------------------------------------------------------------------ */
/* output                                                              */

static void
write_all(const void *p, size_t len)
{
  const uint8_t *c = p;
  while (len > 0)
    {
      ssize_t n = write(out_fd, c, len);
      if (n < 0)
        {
          if (errno == EINTR)
            continue;
          die("write failed: %s", strerror(errno));
        }
      c += n;
      len -= (size_t)n;
    }
}

static void
emit(uint16_t type, uint32_t aux, uint64_t time, uint32_t tid,
     const void *a, size_t alen, const void *b, size_t blen)
{
  static const uint8_t zeros[8];
  size_t raw = sizeof(gsp_record) + alen + blen;
  size_t total = GSP_RECORD_ALIGN(raw);
  gsp_record h = { type, 0, (uint32_t)total, time, tid, aux };
  write_all(&h, sizeof(h));
  if (alen)
    write_all(a, alen);
  if (blen)
    write_all(b, blen);
  write_all(zeros, total - raw);
}

static int
create_in_dir(const char *name)
{
  int fd = openat(dir_fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                  0600);
  if (fd < 0)
    die("cannot create %s: %s", name, strerror(errno));
  if (geteuid() == 0 && fchown(fd, invoking_uid, invoking_gid) != 0)
    die("cannot hand %s to the invoking user: %s", name, strerror(errno));
  return fd;
}

/* ------------------------------------------------------------------ */
/* process inspection                                                  */

/* A process may be sampled only if every one of its user and group ids
   (real, effective, saved, filesystem) is the invoking user's: this rules
   out setuid/setgid programs the user started.  */
static int
process_owned_by(int pid, uid_t uid, gid_t gid)
{
  char path[64], line[256];
  FILE *f;
  int uid_ok = 0, gid_ok = 0;

  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  f = fopen(path, "r");
  if (f == NULL)
    return -1;
  while (fgets(line, sizeof(line), f))
    {
      unsigned long a, b, c, d;
      if (strncmp(line, "Uid:", 4) == 0 && sscanf(line + 4, "%lu %lu %lu %lu", &a, &b, &c, &d) == 4)
        uid_ok = a == uid && b == uid && c == uid && d == uid;
      else if (strncmp(line, "Gid:", 4) == 0 && sscanf(line + 4, "%lu %lu %lu %lu", &a, &b, &c, &d) == 4)
        gid_ok = a == gid && b == gid && c == gid && d == gid;
    }
  fclose(f);
  return uid_ok && gid_ok;
}

/* Identity of the target's executable, to notice an exec.  */
static int
exe_identity(int pid, dev_t *dev, ino_t *ino)
{
  char path[64];
  struct stat st;
  snprintf(path, sizeof(path), "/proc/%d/exe", pid);
  if (stat(path, &st) != 0)
    return -1;
  *dev = st.st_dev;
  *ino = st.st_ino;
  return 0;
}

static void
emit_thread(int pid, int tid, uint64_t t)
{
  char path[96], name[64] = "";
  FILE *f;

  snprintf(path, sizeof(path), "/proc/%d/task/%d/comm", pid, tid);
  f = fopen(path, "r");
  if (f)
    {
      if (fgets(name, sizeof(name), f))
        name[strcspn(name, "\n")] = 0;
      fclose(f);
    }
  emit(GSP_REC_THREAD, tid == pid ? GSP_THREAD_MAIN : 0, t, (uint32_t)tid,
       name, strlen(name) + 1, NULL, 0);
}

typedef struct image
{
  char path[512];
  uint64_t base, start, end;
  uint64_t first_lo, first_hi;   /* one mapping of the file, for map_files */
  int have_base;
} image;

static void
emit_images(int pid, uint64_t t)
{
  char path[64], line[1024];
  FILE *f;
  image images[512];
  int count = 0;

  snprintf(path, sizeof(path), "/proc/%d/maps", pid);
  f = fopen(path, "r");
  if (f == NULL)
    return;
  while (fgets(line, sizeof(line), f) && count < 512)
    {
      unsigned long lo, hi, off;
      char perms[8], file[512] = "";
      if (sscanf(line, "%lx-%lx %7s %lx %*s %*s %511[^\n]", &lo, &hi, perms,
                 &off, file) < 4 || file[0] != '/')
        continue;
      int i;
      for (i = 0; i < count; i++)
        if (strcmp(images[i].path, file) == 0)
          break;
      if (i == count)
        {
          memset(&images[i], 0, sizeof(image));
          snprintf(images[i].path, sizeof(images[i].path), "%s", file);
          images[i].start = UINT64_MAX;
          images[i].first_lo = lo;
          images[i].first_hi = hi;
          count++;
        }
      if (off == 0 && !images[i].have_base)
        {
          images[i].base = lo;
          images[i].have_base = 1;
        }
      if (perms[2] == 'x')
        {
          if (lo < images[i].start)
            images[i].start = lo;
          if (hi > images[i].end)
            images[i].end = hi;
        }
    }
  fclose(f);
  for (int i = 0; i < count; i++)
    {
      if (images[i].end == 0)
        continue;
      /* ET_EXEC executables load at their link address: base 0 */
      gsp_image_payload p = { images[i].base, images[i].start, images[i].end };
      /* Read the ELF type through map_files (the file actually mapped, not
         whatever the path names from root's point of view), never
         blocking and only from regular files.  */
      char mf[96];
      snprintf(mf, sizeof(mf), "/proc/%d/map_files/%lx-%lx", pid,
               (unsigned long)images[i].first_lo, (unsigned long)images[i].first_hi);
      int fd = open(mf, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
      if (fd >= 0)
        {
          struct stat st;
          unsigned char eh[18];
          if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)
              && read(fd, eh, sizeof(eh)) == sizeof(eh) && eh[16] == 2 /* ET_EXEC */)
            p.base = 0;
          close(fd);
        }
      emit(GSP_REC_IMAGE, 0, t, (uint32_t)pid, &p, sizeof(p), images[i].path,
           strlen(images[i].path) + 1);
    }
}

/* ------------------------------------------------------------------ */
/* kernel symbols                                                      */

typedef struct ksym
{
  uint64_t addr;
  char *name;
} ksym;

static ksym *ksyms;
static size_t ksym_count;

static int
cmp_ksym(const void *a, const void *b)
{
  const ksym *x = a, *y = b;
  return (x->addr > y->addr) - (x->addr < y->addr);
}

static void
load_kallsyms(void)
{
  FILE *f = fopen("/proc/kallsyms", "r");
  char line[512];
  size_t cap = 0;

  if (f == NULL)
    return;
  while (fgets(line, sizeof(line), f))
    {
      unsigned long long a;
      char type, name[256];
      if (sscanf(line, "%llx %c %255s", &a, &type, name) != 3 || a == 0)
        continue;
      if (type != 't' && type != 'T' && type != 'w' && type != 'W')
        continue;
      if (ksym_count == cap)
        {
          cap = cap ? cap * 2 : 65536;
          ksyms = realloc(ksyms, cap * sizeof(ksym));
        }
      ksyms[ksym_count].addr = a;
      ksyms[ksym_count].name = strdup(name);
      ksym_count++;
    }
  fclose(f);
  qsort(ksyms, ksym_count, sizeof(ksym), cmp_ksym);
}

static const ksym *
ksym_for(uint64_t addr)
{
  size_t lo = 0, hi = ksym_count;
  if (ksym_count == 0 || addr < ksyms[0].addr)
    return NULL;
  while (hi - lo > 1)
    {
      size_t mid = (lo + hi) / 2;
      if (ksyms[mid].addr <= addr)
        lo = mid;
      else
        hi = mid;
    }
  return &ksyms[lo];
}

/* kernel function starts already written as METHOD records */
static uint64_t *kdone;
static size_t kdone_count, kdone_cap;

static void
note_kernel_frame(uint64_t addr)
{
  const ksym *k = ksym_for(addr);
  if (k == NULL)
    return;
  for (size_t i = 0; i < kdone_count; i++)
    if (kdone[i] == k->addr)
      return;
  if (kdone_count == kdone_cap)
    {
      kdone_cap = kdone_cap ? kdone_cap * 2 : 1024;
      kdone = realloc(kdone, kdone_cap * sizeof(uint64_t));
    }
  kdone[kdone_count++] = k->addr;
  char name[300];
  snprintf(name, sizeof(name), "%s [kernel]", k->name);
  gsp_method_payload p = { k->addr };
  emit(GSP_REC_METHOD, 0, now_ns(), 0, &p, sizeof(p), name, strlen(name) + 1);
}

/* ------------------------------------------------------------------ */
/* perf_event                                                          */

typedef struct tevent
{
  int tid;
  int fd;
  struct perf_event_mmap_page *meta;
  uint8_t *data;
  size_t data_size;
} tevent;

static tevent events[MAX_THREADS];
static int event_count;
static unsigned frequency = 1000;
static uint64_t lost;

static int
open_thread(int tid)
{
  struct perf_event_attr attr;
  long page = sysconf(_SC_PAGESIZE);

  for (int i = 0; i < event_count; i++)
    if (events[i].tid == tid)
      return 0;
  if (event_count >= MAX_THREADS)
    return -1;
  memset(&attr, 0, sizeof(attr));
  attr.size = sizeof(attr);
  attr.type = PERF_TYPE_SOFTWARE;
  attr.config = PERF_COUNT_SW_CPU_CLOCK;
  attr.freq = 1;
  attr.sample_freq = frequency;
  attr.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_TIME
    | PERF_SAMPLE_CALLCHAIN | PERF_SAMPLE_PERIOD;
  attr.use_clockid = 1;
  attr.clockid = CLOCK_MONOTONIC;
  attr.disabled = 1;
  attr.exclude_hv = 1;
  attr.sample_max_stack = 127;
  if (geteuid() != 0)
    attr.exclude_kernel = 1;

  int fd = (int)syscall(SYS_perf_event_open, &attr, tid, -1, -1, PERF_FLAG_FD_CLOEXEC);
  if (fd < 0 && !attr.exclude_kernel && (errno == EACCES || errno == EPERM))
    {
      attr.exclude_kernel = 1;
      fd = (int)syscall(SYS_perf_event_open, &attr, tid, -1, -1, PERF_FLAG_FD_CLOEXEC);
    }
  if (fd < 0)
    return -errno;
  size_t len = (size_t)page * (RING_PAGES + 1);
  void *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED)
    {
      int e = errno;
      close(fd);
      return -e;
    }
  tevent *ev = &events[event_count++];
  ev->tid = tid;
  ev->fd = fd;
  ev->meta = m;
  ev->data = (uint8_t *)m + page;
  ev->data_size = (size_t)page * RING_PAGES;
  ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);
  return 0;
}

static int
scan_threads(int pid, uint64_t t)
{
  char path[64];
  DIR *d;
  struct dirent *e;
  int opened = 0, failed = 0;

  snprintf(path, sizeof(path), "/proc/%d/task", pid);
  d = opendir(path);
  if (d == NULL)
    return -1;
  while ((e = readdir(d)) != NULL)
    {
      if (!isdigit((unsigned char)e->d_name[0]))
        continue;
      int tid = atoi(e->d_name);
      int known = 0;
      for (int i = 0; i < event_count; i++)
        if (events[i].tid == tid)
          known = 1;
      if (known)
        continue;
      int r = open_thread(tid);
      if (r == 0)
        {
          emit_thread(pid, tid, t);
          opened++;
        }
      else
        {
          failed = r;
        }
    }
  closedir(d);
  if (opened == 0 && event_count == 0 && failed)
    return failed;
  return opened;
}

static void
drain(tevent *ev)
{
  uint64_t head = __atomic_load_n(&ev->meta->data_head, __ATOMIC_ACQUIRE);
  uint64_t tail = ev->meta->data_tail;
  uint8_t buf[8192];

  while (tail < head)
    {
      struct perf_event_header hdr;
      size_t off = tail % ev->data_size;
      for (size_t i = 0; i < sizeof(hdr); i++)
        ((uint8_t *)&hdr)[i] = ev->data[(off + i) % ev->data_size];
      if (hdr.size == 0)
        break;
      if (hdr.size > sizeof(buf))
        {
          tail += hdr.size;   /* not a sample we can use; skip it */
          continue;
        }
      for (size_t i = 0; i < hdr.size; i++)
        buf[i] = ev->data[(off + i) % ev->data_size];
      tail += hdr.size;

      if (hdr.type == PERF_RECORD_LOST)
        {
          uint64_t n;
          memcpy(&n, buf + sizeof(hdr) + 8, 8);
          lost += n;
          continue;
        }
      if (hdr.type != PERF_RECORD_SAMPLE)
        continue;
      /* ip, pid/tid, time, period, callchain(nr, ips[]) */
      const uint8_t *p = buf + sizeof(hdr);
      uint64_t ip, time, period, nr;
      uint32_t spid, stid;
      memcpy(&ip, p, 8); p += 8;
      memcpy(&spid, p, 4); memcpy(&stid, p + 4, 4); p += 8;
      memcpy(&time, p, 8); p += 8;
      memcpy(&period, p, 8); p += 8;
      memcpy(&nr, p, 8); p += 8;
      if (nr > 255)
        nr = 255;

      uint64_t frames[2 + 256];
      gsp_frames_payload *fp = (gsp_frames_payload *)frames;
      uint64_t *out = frames + 1;
      unsigned count = 0, kernel = 0;
      int in_kernel = 0;
      for (uint64_t i = 0; i < nr; i++)
        {
          uint64_t a;
          memcpy(&a, p + i * 8, 8);
          if (a >= (uint64_t)PERF_CONTEXT_MAX)
            {
              in_kernel = (a == (uint64_t)PERF_CONTEXT_KERNEL);
              continue;
            }
          if (count >= 256)
            break;
          out[count++] = a;
          if (in_kernel)
            {
              kernel++;
              note_kernel_frame(a);
            }
        }
      if (count == 0)
        out[count++] = ip;
      fp->count = count;
      fp->kernel_count = (uint16_t)kernel;
      fp->weight = 1;
      emit(GSP_REC_SAMPLE, GSP_SAMPLE_PERF, time, stid, frames,
           sizeof(*fp) + count * 8, NULL, 0);
    }
  __atomic_store_n(&ev->meta->data_tail, tail, __ATOMIC_RELEASE);
}

static void
close_exited_threads(int pid)
{
  for (int i = 0; i < event_count;)
    {
      char path[96];
      struct stat st;
      snprintf(path, sizeof(path), "/proc/%d/task/%d", pid, events[i].tid);
      if (stat(path, &st) == 0)
        {
          i++;
          continue;
        }
      drain(&events[i]);
      munmap(events[i].meta, (size_t)sysconf(_SC_PAGESIZE) * (RING_PAGES + 1));
      close(events[i].fd);
      events[i] = events[--event_count];
    }
}

static int
cmd_record(int argc, char **argv)
{
  int pid = 0;
  const char *output = NULL;
  double duration = 0;
  struct stat st;

  for (int i = 0; i < argc; i++)
    {
      if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc)
        pid = atoi(argv[++i]);
      else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc)
        output = argv[++i];
      else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc)
        duration = atof(argv[++i]);
      else if (strcmp(argv[i], "--frequency") == 0 && i + 1 < argc)
        frequency = (unsigned)atoi(argv[++i]);
      else
        die("unknown argument %s", argv[i]);
    }
  if (pid <= 0 || output == NULL)
    die("record needs --pid and --output");
  if (frequency < 10 || frequency > 10000)
    frequency = 1000;

  int owned = process_owned_by(pid, invoking_uid, invoking_gid);
  if (owned < 0)
    die("no process %d", pid);
  if (invoking_uid != 0 && !owned)
    die("process %d belongs to another user or runs with other privileges (setuid/setgid)", pid);
  dev_t exe_dev;
  ino_t exe_ino;
  if (exe_identity(pid, &exe_dev, &exe_ino) != 0)
    die("cannot inspect process %d", pid);
  if (duration <= 0 || duration > 3600)
    duration = 3600;   /* bounded: root writes can use reserved disk space */

  dir_fd = open(output, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (dir_fd < 0 || fstat(dir_fd, &st) != 0)
    die("cannot open %s: %s", output, strerror(errno));
  if (st.st_uid != invoking_uid)
    die("%s is not owned by the invoking user", output);

  char name[64];
  snprintf(name, sizeof(name), "events-%d.bin", pid);
  out_fd = create_in_dir(name);

  gsp_file_header h;
  struct timespec rt;
  memset(&h, 0, sizeof(h));
  memcpy(h.magic, GSP_MAGIC, 8);
  h.version = GSP_FORMAT_VERSION;
  h.header_size = sizeof(h);
  h.pid = (uint32_t)pid;
  h.start_ns = now_ns();
  clock_gettime(CLOCK_REALTIME, &rt);
  h.start_realtime_ns = (uint64_t)rt.tv_sec * 1000000000ull + (uint64_t)rt.tv_nsec;
  h.pointer_size = 8;
  h.flags = GSP_STREAM_FROM_PERF | (geteuid() == 0 ? GSP_STREAM_KERNEL_FRAMES : 0);
  h.sample_interval_us = 1000000 / frequency;
  char exe[64];
  snprintf(exe, sizeof(exe), "/proc/%d/exe", pid);
  ssize_t n = readlink(exe, h.exe, sizeof(h.exe) - 1);
  if (n > 0)
    h.exe[n] = 0;
  write_all(&h, sizeof(h));

  if (geteuid() == 0)
    load_kallsyms();
  uint64_t t0 = now_ns();
  emit(GSP_REC_MARK, GSP_MARK_START, t0, (uint32_t)pid, NULL, 0, NULL, 0);
  emit_images(pid, t0);
  int r = scan_threads(pid, t0);
  if (r < 0)
    {
      close(out_fd);
      unlinkat(dir_fd, name, 0);
    }
  if (r < 0)
    die("perf_event_open failed: %s (kernel.perf_event_paranoid is %s)",
        strerror(-r), "too strict for this user; run through pkexec");

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  uint64_t deadline = duration > 0 ? t0 + (uint64_t)(duration * 1e9) : 0;
  uint64_t next_scan = t0 + 100000000ull;
  uint64_t next_images = t0 + 1000000000ull;

  while (!interrupted)
    {
      struct pollfd pfds[MAX_THREADS];
      for (int i = 0; i < event_count; i++)
        {
          pfds[i].fd = events[i].fd;
          pfds[i].events = POLLIN;
        }
      poll(pfds, (nfds_t)event_count, 50);
      for (int i = 0; i < event_count; i++)
        drain(&events[i]);
      uint64_t t = now_ns();
      if (deadline && t >= deadline)
        break;
      if (kill(pid, 0) != 0 && errno == ESRCH)
        break;
      if (faccessat(dir_fd, "stop", F_OK, AT_SYMLINK_NOFOLLOW) == 0)
        break;
      if (t >= next_scan)
        {
          /* The target must still be the same program run by the same
             user: stop at an exec or a change of credentials.  */
          dev_t d;
          ino_t ino;
          if (exe_identity(pid, &d, &ino) != 0 || d != exe_dev || ino != exe_ino
              || (invoking_uid != 0 && process_owned_by(pid, invoking_uid, invoking_gid) != 1))
            break;
          close_exited_threads(pid);
          scan_threads(pid, t);
          next_scan = t + 100000000ull;
        }
      if (t >= next_images)
        {
          next_images = t + 2000000000ull;
        }
    }
  for (int i = 0; i < event_count; i++)
    {
      ioctl(events[i].fd, PERF_EVENT_IOC_DISABLE, 0);
      drain(&events[i]);
    }
  /* images loaded during the recording */
  emit_images(pid, now_ns());
  if (lost)
    emit(GSP_REC_DROPPED, GSP_REC_SAMPLE, now_ns(), (uint32_t)pid, &lost, 8, NULL, 0);
  emit(GSP_REC_END, 0, now_ns(), (uint32_t)pid, NULL, 0, NULL, 0);
  fsync(out_fd);
  close(out_fd);
  snprintf(name, sizeof(name), "events-%d.done", pid);
  close(create_in_dir(name));
  return 0;
}

/* ------------------------------------------------------------------ */
/* install                                                             */

/* The installed copy runs under the polkit policy's auth_admin_keep for
   sampling; it must not also be able to replace itself or the policy.  */
static int
running_installed_copy(void)
{
  char self[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
  if (n <= 0)
    return 1;
  self[n] = 0;
  return strcmp(self, INSTALL_PATH) == 0;
}

static void
copy_file(int src_dir, const char *name, const char *dest, mode_t mode)
{
  int in = openat(src_dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  struct stat st;
  char tmp[PATH_MAX];

  if (in < 0 || fstat(in, &st) != 0 || !S_ISREG(st.st_mode))
    die("source %s is missing or not a regular file", name);
  if ((st.st_uid != 0 && st.st_uid != invoking_uid) || (st.st_mode & 022))
    die("source %s must be owned by you or root and not writable by others", name);
  snprintf(tmp, sizeof(tmp), "%s.new", dest);
  unlink(tmp);
  int out = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
  if (out < 0)
    die("cannot create %s: %s", tmp, strerror(errno));
  char buf[65536];
  ssize_t n;
  while ((n = read(in, buf, sizeof(buf))) > 0)
    if (write(out, buf, (size_t)n) != n)
      die("write to %s failed", tmp);
  if (fchown(out, 0, 0) != 0 || fchmod(out, mode) != 0)
    die("cannot set owner/mode on %s", tmp);
  close(out);
  close(in);
  if (rename(tmp, dest) != 0)
    die("cannot install %s: %s", dest, strerror(errno));
}

static int
cmd_install(int argc, char **argv)
{
  const char *source = NULL;
  for (int i = 0; i < argc; i++)
    if (strcmp(argv[i], "--source") == 0 && i + 1 < argc)
      source = argv[++i];
  if (geteuid() != 0)
    die("install must run as root (use `gstrace install-helper`)");
  if (running_installed_copy())
    die("the installed helper cannot reinstall itself; run `gstrace install-helper`");
  if (source == NULL)
    die("install needs --source DIR");
  int src = open(source, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat dst;
  if (src < 0 || fstat(src, &dst) != 0)
    die("cannot open %s", source);
  /* Only a staging directory nobody else can change.  */
  if ((dst.st_uid != 0 && dst.st_uid != invoking_uid) || (dst.st_mode & 022))
    die("%s must be owned by you or root and not writable by others", source);
  mkdir("/usr/local/libexec", 0755);
  mkdir(POLICY_DIR, 0755);
  copy_file(src, "gstrace-helper", INSTALL_PATH, 0755);
  copy_file(src, POLICY_NAME, POLICY_DIR "/" POLICY_NAME, 0644);
  unlink(POLICY_DIR "/" OLD_POLICY_NAME);
  printf("Installed %s and %s/%s\n", INSTALL_PATH, POLICY_DIR, POLICY_NAME);
  return 0;
}

static int
cmd_uninstall(void)
{
  if (geteuid() != 0)
    die("uninstall must run as root");
  if (running_installed_copy())
    die("run uninstall from a copy of the helper (e.g. the one next to gstrace) through pkexec");
  unlink(INSTALL_PATH);
  unlink(POLICY_DIR "/" POLICY_NAME);
  unlink(POLICY_DIR "/" OLD_POLICY_NAME);
  printf("Removed %s and the polkit policy\n", INSTALL_PATH);
  return 0;
}

int
main(int argc, char **argv)
{
  const char *pk = getenv("PKEXEC_UID");

  invoking_uid = getuid();
  invoking_gid = getgid();
  if (geteuid() == 0 && pk != NULL)
    {
      char *end;
      unsigned long u = strtoul(pk, &end, 10);
      if (*end == '\0')
        {
          invoking_uid = (uid_t)u;
          invoking_gid = (gid_t)u;
          /* use the user's primary group when we can find it */
          FILE *f = fopen("/etc/passwd", "r");
          char line[512];
          while (f && fgets(line, sizeof(line), f))
            {
              unsigned long uid, gid;
              char *c = strchr(line, ':');
              if (c && (c = strchr(c + 1, ':'))
                  && sscanf(c + 1, "%lu:%lu", &uid, &gid) == 2 && uid == u)
                {
                  invoking_gid = (gid_t)gid;
                  break;
                }
            }
          if (f)
            fclose(f);
        }
    }

  if (argc < 2)
    {
      fprintf(stderr, "usage: gstrace-helper record|install|uninstall|version ...\n");
      return 2;
    }
  if (strcmp(argv[1], "record") == 0)
    return cmd_record(argc - 2, argv + 2);
  if (strcmp(argv[1], "install") == 0)
    return cmd_install(argc - 2, argv + 2);
  if (strcmp(argv[1], "uninstall") == 0)
    return cmd_uninstall();
  if (strcmp(argv[1], "version") == 0)
    {
      printf("gstrace-helper %s\n", HELPER_VERSION);
      return 0;
    }
  die("unknown command %s", argv[1]);
  return 2;
}
