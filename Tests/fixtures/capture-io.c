/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Deterministic tests of the exact writer helpers; no agent/env injection. */
#include "../../Runtime/gsp_writer_io.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int mode, calls, closes, syncs;
static size_t received;
static unsigned char sink[32];

static ssize_t
fake_write(int fd, const void *data, size_t size)
{
  (void)fd;
  calls++;
  if (mode == 1 && calls == 1) { errno = EINTR; return -1; }
  if (mode == 2) return 0;
  if (mode == 3) { errno = ENOSPC; return -1; }
  if (mode == 4) { errno = EFBIG; return -1; }
  if (mode == 8 && calls > 1) { errno = ENOSPC; return -1; }
  size_t n = size > 3 ? 3 : size;
  assert(received + n <= sizeof(sink));
  memcpy(sink + received, data, n);
  received += n;
  return (ssize_t)n;
}
static int
fake_sync(int fd)
{
  (void)fd; syncs++;
  if (mode == 5) { errno = ENOSPC; return -1; }
  if (mode == 7 && syncs == 1) { errno = EINTR; return -1; }
  return 0;
}
static int
fake_close(int fd)
{
  (void)fd; closes++;
  if (mode == 6) { errno = EIO; return -1; }
  if (mode == 9) { errno = EINTR; return -1; }
  return 0;
}

int
main(void)
{
  uint64_t size;
  assert(gsp_parse_byte_size("0", &size) && size == 0);
  assert(gsp_parse_byte_size("128K", &size) && size == 131072);
  assert(gsp_parse_byte_size("2M", &size) && size == 2097152);
  assert(gsp_parse_byte_size("1G", &size) && size == UINT64_C(1073741824));
  assert(gsp_parse_byte_size("18446744073709551615", &size) && size == UINT64_MAX);
  const char *bad[] = { "", "-1", "+1", "1.5M", " 1", "1k", "1KB", "1Kx",
                       "18446744073709551616", "18446744073709551615K", NULL };
  for (unsigned i = 0; bad[i]; i++) assert(!gsp_parse_byte_size(bad[i], &size));
  assert(!gsp_block_bytes(UINT64_MAX, 2, &size));
  assert(!gsp_block_bytes(1, 0, &size));
  assert(gsp_block_bytes(10, 4096, &size) && size == 40960);
  assert(gsp_default_free_floor(100) == UINT64_C(1073741824));
  assert(gsp_default_free_floor(UINT64_C(40)*1073741824) == UINT64_C(2)*1073741824);
  for (mode = 0; mode <= 9; mode++)
    {
      gsp_output_state state = {0};
      calls = closes = syncs = 0; received = 0;
      bool ok = gsp_output_write(&state, 9, "abcdefgh", 8, fake_write);
      if ((mode >= 2 && mode <= 4) || mode == 8)
        {
          int expected = mode == 2 ? EIO : (mode == 3 || mode == 8) ? ENOSPC : EFBIG;
          assert(!ok && state.error == expected && state.operation == GSP_OUTPUT_WRITE);
          assert(state.bytes == (mode == 8 ? 3 : 0) && calls == (mode == 8 ? 2 : 1));
          if (mode == 8) assert(received == 3 && !memcmp(sink, "abc", 3));
          int before = calls;
          assert(!gsp_output_write(&state, 9, "x", 1, fake_write) && calls == before);
          gsp_output_fail(&state, GSP_OUTPUT_SYNC, EBADF);
          assert(state.error == expected && state.operation == GSP_OUTPUT_WRITE);
        }
      else
        assert(ok && state.bytes == 8 && received == 8 && !memcmp(sink, "abcdefgh", 8));
      gsp_output_finish(&state, 9, fake_sync, fake_close);
      assert(closes == 1);
      if (mode == 5) assert(state.error == ENOSPC && state.operation == GSP_OUTPUT_SYNC);
      if (mode == 6) assert(state.error == EIO && state.operation == GSP_OUTPUT_CLOSE);
      if (mode == 7) assert(syncs == 2 && !state.error);
      if (mode == 9) assert(state.error == EINTR && state.operation == GSP_OUTPUT_CLOSE);
      if ((mode >= 2 && mode <= 4) || mode == 8) assert(syncs == 0);
    }
  puts("PASS: byte policy, short/EINTR/zero/ENOSPC/EFBIG writes, sync and close faults");
  return 0;
}
