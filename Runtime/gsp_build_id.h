/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Pure bounded ELF note helpers, shared with reader and C regression cases. */
#ifndef GSP_BUILD_ID_H
#define GSP_BUILD_ID_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static inline int
gsp_note_range_within(uint64_t address, uint64_t size,
                      uint64_t readable, uint64_t readable_size)
{
  return address >= readable && address - readable <= readable_size
    && size <= readable_size - (address - readable);
}

static inline size_t
gsp_note_build_id(const void *data, size_t size, uint64_t alignment,
                  void *identifier, size_t capacity)
{
  const uint8_t *bytes = data;
  uint64_t offset = 0;
  if (alignment != 4 && alignment != 8)
    return 0;
  while (offset <= size && size - offset >= 12)
    {
      uint32_t fields[3];
      memcpy(fields, bytes + (size_t)offset, sizeof(fields));
      uint64_t name = offset + 12;
      if ((uint64_t)fields[0] > size - name)
        return 0;
      uint64_t desc = name + fields[0];
      uint64_t padding = (-desc) & (alignment - 1);
      if (padding > size - desc)
        return 0;
      desc += padding;
      if ((uint64_t)fields[1] > size - desc)
        return 0;
      if (fields[2] == 3 && fields[0] == 4 && fields[1] > 0
          && fields[1] <= capacity && memcmp(bytes + (size_t)name, "GNU", 4) == 0)
        {
          memcpy(identifier, bytes + (size_t)desc, fields[1]);
          return fields[1];
        }
      offset = desc + fields[1];
      padding = (-offset) & (alignment - 1);
      if (padding > size - offset)
        return 0;
      offset += padding;
    }
  return 0;
}
#endif
