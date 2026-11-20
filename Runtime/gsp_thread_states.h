/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Writer-only thread state batching. No sampling signals or user stacks. */
#ifndef GSP_THREAD_STATES_H
#define GSP_THREAD_STATES_H
#include <string.h>
#include <errno.h>
#include <sys/types.h>

typedef struct gsp_state_polls
{
  uint64_t first, last, emitted;
  uint32_t count;
  unsigned char state;
} gsp_state_polls;

/* comm (field 2) may contain spaces and closing parentheses. */
static inline unsigned char
gsp_proc_state(const char *stat)
{
  const char *end = strrchr(stat, ')');
  if (end && end[1] == ' ' && end[2] && end[3] == ' '
      && strchr("RSDTtXZPIWK", end[2]))
    return (unsigned char)end[2];
  return GSP_STATE_UNKNOWN;
}
/* Capture read errno before close, which can change errno even on success.
   A proc fd opened while the task lived can yield ESRCH after its exit. */
static inline unsigned char
gsp_read_proc_state(int fd, ssize_t (*read_fn)(int, void *, size_t),
                    int (*close_fn)(int), int *error_out)
{
  *error_out = 0;
  if (fd < 0) { *error_out = errno; return GSP_STATE_UNKNOWN; }
  char stat[4096];
  ssize_t bytes = read_fn(fd, stat, sizeof(stat) - 1);
  int error = bytes < 0 ? errno : 0;
  close_fn(fd);
  if (bytes <= 0)
    {
      *error_out = bytes < 0 ? error : EIO;
      return error == ESRCH ? GSP_STATE_EXITED : GSP_STATE_UNKNOWN;
    }
  stat[bytes] = 0;
  unsigned char state = gsp_proc_state(stat);
  if (state == GSP_STATE_UNKNOWN) *error_out = EPROTO;
  return state;
}
#endif
