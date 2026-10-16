/* gsp_signpost.h - signposts and trace logging for GNUstep Instruments.

   Link with -lgsperf.  When the process is not being recorded every call is
   a cheap no-op, so signposts can stay in release builds.  <os/signpost.h>
   and <os/log.h> in this distribution map Apple's API onto these functions. */

#ifndef GSP_SIGNPOST_H
#define GSP_SIGNPOST_H

#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(GSP_BUILDING_API)
#  define GSP_API __declspec(dllexport)
#elif defined(_WIN32)
#  define GSP_API __declspec(dllimport)
#else
#  define GSP_API __attribute__((visibility("default")))
#endif

typedef struct gsp_log_s *gsp_log_t;
typedef uint64_t gsp_signpost_id_t;

#define GSP_SIGNPOST_ID_NULL ((gsp_signpost_id_t)0)
#define GSP_SIGNPOST_ID_INVALID ((gsp_signpost_id_t)~0ULL)
#define GSP_SIGNPOST_ID_EXCLUSIVE ((gsp_signpost_id_t)0xEEEEB0B5B2B2EEEEULL)

enum
{
  GSP_LOG_LEVEL_DEFAULT = 0,
  GSP_LOG_LEVEL_INFO = 1,
  GSP_LOG_LEVEL_DEBUG = 2,
  GSP_LOG_LEVEL_ERROR = 16,
  GSP_LOG_LEVEL_FAULT = 17
};

/* Category used by Instruments' "Points of Interest" track. */
#define GSP_CATEGORY_POINTS_OF_INTEREST "PointsOfInterest"

/* Logs are never freed; create them once and keep them. */
GSP_API gsp_log_t gsp_log_create(const char *subsystem, const char *category);
GSP_API extern struct gsp_log_s gsp_log_default_s;
#define GSP_LOG_DEFAULT (&gsp_log_default_s)

GSP_API bool gsp_signpost_enabled(gsp_log_t log);
GSP_API gsp_signpost_id_t gsp_signpost_id_generate(gsp_log_t log);
GSP_API gsp_signpost_id_t gsp_signpost_id_make_with_pointer(gsp_log_t log,
                                                    const void *ptr);

/* kind: 0 event, 1 interval begin, 2 interval end (see gsp_format.h). */
GSP_API void gsp_signpost_emit(gsp_log_t log, int kind, gsp_signpost_id_t spid,
                       const char *name, const char *format, ...)
  __attribute__((format(printf, 5, 6)));
GSP_API void gsp_signpost_emitv(gsp_log_t log, int kind, gsp_signpost_id_t spid,
                        const char *name, const char *format, va_list ap);

GSP_API void gsp_log_emit(gsp_log_t log, int level, const char *format, ...)
  __attribute__((format(printf, 3, 4)));

/* True while a recording is active in this process. */
GSP_API bool gsp_is_recording(void);

#ifdef __cplusplus
}
#endif

#endif
