/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Normal writer context only. Function arguments provide a deterministic
   test seam without environment switches or interposing raw agent syscalls. */
#ifndef GSP_WRITER_IO_H
#define GSP_WRITER_IO_H
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include "include/GSPerformance/gsp_capture.h"

typedef struct gsp_output_state
{
  int error;
  int operation;
  uint64_t bytes;
} gsp_output_state;

static inline void
gsp_output_fail(gsp_output_state *state, int operation, int error)
{
  if (!state->error)
    {
      state->error = error ? error : EIO;
      state->operation = operation;
    }
}

static inline bool
gsp_output_write(gsp_output_state *state, int fd, const void *data, size_t size,
                 ssize_t (*write_fn)(int, const void *, size_t))
{
  const unsigned char *p = data;
  if (state->error)
    return false;
  while (size)
    {
      ssize_t n = write_fn(fd, p, size);
      if (n < 0 && errno == EINTR)
        continue;
      if (n <= 0 || (size_t)n > size)
        {
          gsp_output_fail(state, GSP_OUTPUT_WRITE, n < 0 ? errno : EIO);
          return false;
        }
      if (state->bytes > UINT64_MAX - (uint64_t)n)
        {
          gsp_output_fail(state, GSP_OUTPUT_WRITE, EOVERFLOW);
          return false;
        }
      state->bytes += (uint64_t)n;
      p += n;
      size -= (size_t)n;
    }
  return true;
}

static inline void
gsp_output_finish(gsp_output_state *state, int fd,
                  int (*sync_fn)(int), int (*close_fn)(int))
{
  if (!state->error)
    {
      int rc;
      do rc = sync_fn(fd); while (rc < 0 && errno == EINTR);
      if (rc < 0)
        gsp_output_fail(state, GSP_OUTPUT_SYNC, errno);
    }
  /* Linux close must not be retried after EINTR: the descriptor is released. */
  if (close_fn(fd) < 0)
    gsp_output_fail(state, GSP_OUTPUT_CLOSE, errno);
}
#endif
