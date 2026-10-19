/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* gsp_signpost_agent.c - the agent side of signposts and os_log.

   Applications link libgsperf.so (gsp_signpost_api.c), which looks these
   entry points up with dlsym when the agent has been preloaded.  The names
   are a private ABI between the two libraries.  */

#include "gsp_internal.h"

#include <string.h>

void
gsp_signpost_init(void)
{
}

GSP_EXPORT int
gsp_agent_signposts_enabled(void)
{
  return atomic_load(&gsp_recording) && gsp_cfg.signposts;
}

GSP_EXPORT void
gsp_agent_signpost(int record_type, int kind, uint64_t spid,
                   const char *subsystem, const char *category,
                   const char *name, const char *message, size_t length)
{
  gsp_thread *t;
  gsp_signpost_payload p;
  uint64_t now = gsp_now();

  /* gsp_in_agent: a signal handler interrupted the agent while it was
     writing to this thread's ring; a second producer would corrupt it.  */
  if (!gsp_agent_signposts_enabled() || gsp_is_internal || gsp_in_agent)
    return;
  gsp_in_agent++;
  t = gsp_thread_current();
  if (t != NULL)
    {
      p.signpost_id = spid;
      p.subsystem = gsp_intern_string(subsystem ? subsystem : "");
      p.category = gsp_intern_string(category ? category : "");
      p.name = gsp_intern_string(name ? name : "");
      p.message_length = (uint32_t)length;
      char tail[1] = { 0 };
      if (length)
        {
          /* message plus NUL in one piece */
          char buf[1100];
          if (length > sizeof(buf) - 1)
            length = sizeof(buf) - 1;
          memcpy(buf, message, length);
          buf[length] = 0;
          p.message_length = (uint32_t)length;
          gsp_emit_normal(t, (uint16_t)record_type, (uint32_t)kind, 0, now,
                          &p, sizeof(p), buf, length + 1);
        }
      else
        gsp_emit_normal(t, (uint16_t)record_type, (uint32_t)kind, 0, now,
                        &p, sizeof(p), tail, 1);
    }
  gsp_in_agent--;
}
