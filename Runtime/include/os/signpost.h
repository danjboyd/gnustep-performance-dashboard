/* os/signpost.h - Apple's signpost API on top of Performance Dashboard.

   Source written for Apple platforms compiles unchanged; link with -lgsperf.
   Apple restricts the name to a string literal and the format to a literal
   with os_log placeholders; here the format goes through printf, so
   "%{public}s"-style privacy annotations are stripped at runtime.  */

#ifndef GSP_OS_SIGNPOST_H
#define GSP_OS_SIGNPOST_H

#include <os/log.h>

typedef gsp_signpost_id_t os_signpost_id_t;

#define OS_SIGNPOST_ID_NULL GSP_SIGNPOST_ID_NULL
#define OS_SIGNPOST_ID_INVALID GSP_SIGNPOST_ID_INVALID
#define OS_SIGNPOST_ID_EXCLUSIVE GSP_SIGNPOST_ID_EXCLUSIVE

#define OS_LOG_CATEGORY_POINTS_OF_INTEREST GSP_CATEGORY_POINTS_OF_INTEREST

#define os_signpost_enabled(log) gsp_signpost_enabled(log)
#define os_signpost_id_generate(log) gsp_signpost_id_generate(log)
#define os_signpost_id_make_with_pointer(log, ptr) \
  gsp_signpost_id_make_with_pointer((log), (ptr))

#define os_signpost_event_emit(log, spid, name, ...) \
  gsp_signpost_emit((log), 0, (spid), (name), "" __VA_ARGS__)
#define os_signpost_interval_begin(log, spid, name, ...) \
  gsp_signpost_emit((log), 1, (spid), (name), "" __VA_ARGS__)
#define os_signpost_interval_end(log, spid, name, ...) \
  gsp_signpost_emit((log), 2, (spid), (name), "" __VA_ARGS__)
#define os_signpost_animation_interval_begin os_signpost_interval_begin

#endif
