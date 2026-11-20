/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Writer-only thread state batching. No sampling signals or user stacks. */
#ifndef GSP_THREAD_STATES_H
#define GSP_THREAD_STATES_H
#include <string.h>

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
#endif
