/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef GSP_LAUNCH_PROTOCOL_H
#define GSP_LAUNCH_PROTOCOL_H
#include <stdint.h>
#define GSP_LAUNCH_MAGIC 0x47534c31u
#define GSP_LAUNCH_LIMIT (8u * 1024u * 1024u)
#define GSP_LAUNCH_FAILURE 125
/* Local, same-host protocol. Each string includes its trailing NUL:
   cwd (empty means inherited), argv, then KEY=value environment entries.
   SCM_RIGHTS carries the open stdio descriptors in bit order, then status. */
struct gsp_launch_header
{
  uint32_t magic, version, bytes, argc, envc, stdio_mask, reserved[2];
  uint64_t ignored_signals;
};
/* First response: prepared=1,error=0. Subsequent EOF means exec closed the
   CLOEXEC channel; an error response means target exec never succeeded. */
struct gsp_launch_reply { uint32_t prepared; int32_t error; };
#endif
