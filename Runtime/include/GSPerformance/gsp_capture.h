/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Linux recorder policy and private agent status protocol, not trace records. */
#ifndef GSP_CAPTURE_H
#define GSP_CAPTURE_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

static inline bool
gsp_parse_byte_size(const char *text, uint64_t *result)
{
  uint64_t value = 0, scale = 1;
  const unsigned char *p = (const unsigned char *)text;
  if (!p || *p < '0' || *p > '9')
    return false;
  while (*p >= '0' && *p <= '9')
    {
      unsigned digit = *p++ - '0';
      if (value > (UINT64_MAX - digit) / 10)
        return false;
      value = value * 10 + digit;
    }
  if (*p)
    {
      switch (*p++)
        {
        case 'K': scale = UINT64_C(1024); break;
        case 'M': scale = UINT64_C(1024) * 1024; break;
        case 'G': scale = UINT64_C(1024) * 1024 * 1024; break;
        default: return false;
        }
      if (*p)
        return false;
    }
  if (value > UINT64_MAX / scale)
    return false;
  *result = value * scale;
  return true;
}

static inline bool
gsp_block_bytes(uint64_t blocks, uint64_t size, uint64_t *bytes)
{
  if (!size || blocks > UINT64_MAX / size)
    return false;
  *bytes = blocks * size;
  return true;
}

static inline uint64_t
gsp_default_free_floor(uint64_t capacity)
{
  uint64_t five_percent = capacity / 20;
  uint64_t gib = UINT64_C(1024) * 1024 * 1024;
  return five_percent > gib ? five_percent : gib;
}

enum gsp_output_operation
{
  GSP_OUTPUT_COMPLETE = 0,
  GSP_OUTPUT_OPEN = 1,
  GSP_OUTPUT_WRITE = 2,
  GSP_OUTPUT_SYNC = 3,
  GSP_OUTPUT_CLOSE = 4,
  GSP_OUTPUT_RENAME = 5,
  GSP_OUTPUT_MARKER = 6,
  GSP_OUTPUT_THREAD = 7
};
#define GSP_WRITER_STATUS_MAGIC UINT32_C(0x47535053)
#define GSP_WRITER_STATUS_VERSION 1
typedef struct gsp_writer_status
{
  uint32_t magic;
  uint32_t version;
  uint32_t pid;
  uint32_t operation;
  int32_t error;
  uint32_t reserved;
  uint64_t epoch;
  uint64_t bytes;
} gsp_writer_status;
#endif
