/* gsp_signpost_api.c - libgsperf.so, the signpost/os_log API that
   applications link.  It does nothing unless the recording agent
   (libgsperf-agent.so) has been preloaded into the process.  */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "GSPerformance/gsp_signpost.h"
#include "GSPerformance/gsp_format.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct gsp_log_s
{
  const char *subsystem;
  const char *category;
};

struct gsp_log_s gsp_log_default_s = { "", "" };

typedef int (*enabled_fn)(void);
typedef void (*signpost_fn)(int, int, uint64_t, const char *, const char *,
                            const char *, const char *, size_t);

static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static enabled_fn agent_enabled;
static signpost_fn agent_signpost;
static _Atomic uint64_t next_id = 1;

static void
resolve(void)
{
  agent_enabled = (enabled_fn)dlsym(RTLD_DEFAULT, "gsp_agent_signposts_enabled");
  agent_signpost = (signpost_fn)dlsym(RTLD_DEFAULT, "gsp_agent_signpost");
  if (agent_enabled == NULL || agent_signpost == NULL)
    agent_enabled = NULL;
}

static inline int
active(void)
{
  pthread_once(&resolve_once, resolve);
  return agent_enabled != NULL && agent_enabled();
}

gsp_log_t
gsp_log_create(const char *subsystem, const char *category)
{
  struct gsp_log_s *log = calloc(1, sizeof(*log));
  if (log == NULL)
    return &gsp_log_default_s;
  log->subsystem = strdup(subsystem ? subsystem : "");
  log->category = strdup(category ? category : "");
  return log;
}

bool
gsp_is_recording(void)
{
  return active();
}

bool
gsp_signpost_enabled(gsp_log_t log)
{
  return log != NULL && active();
}

gsp_signpost_id_t
gsp_signpost_id_generate(gsp_log_t log)
{
  (void)log;
  return atomic_fetch_add(&next_id, 1);
}

gsp_signpost_id_t
gsp_signpost_id_make_with_pointer(gsp_log_t log, const void *ptr)
{
  (void)log;
  uint64_t v = (uint64_t)(uintptr_t)ptr;
  if (v == 0 || v == GSP_SIGNPOST_ID_INVALID)
    return GSP_SIGNPOST_ID_INVALID;
  return v;
}

/* Remove os_log privacy annotations ("%{public}s" -> "%s").  */
static void
strip_annotations(const char *in, char *out, size_t cap)
{
  size_t o = 0;

  while (*in && o + 1 < cap)
    {
      if (in[0] == '%' && in[1] == '{')
        {
          const char *close = strchr(in, '}');
          if (close != NULL)
            {
              out[o++] = '%';
              in = close + 1;
              continue;
            }
        }
      out[o++] = *in++;
    }
  out[o] = '\0';
}

static void
emit(gsp_log_t log, int type, int kind, gsp_signpost_id_t spid,
     const char *name, const char *format, va_list ap)
{
  char fmt[512];
  char msg[1024];
  int len = 0;

  if (format != NULL && format[0] != '\0')
    {
      strip_annotations(format, fmt, sizeof(fmt));
      len = vsnprintf(msg, sizeof(msg), fmt, ap);
      if (len < 0)
        len = 0;
      if ((size_t)len >= sizeof(msg))
        len = sizeof(msg) - 1;
    }
  agent_signpost(type, kind, spid, log->subsystem, log->category, name,
                 msg, (size_t)len);
}

void
gsp_signpost_emitv(gsp_log_t log, int kind, gsp_signpost_id_t spid,
                   const char *name, const char *format, va_list ap)
{
  if (log == NULL || spid == GSP_SIGNPOST_ID_NULL
      || spid == GSP_SIGNPOST_ID_INVALID || !active())
    return;
  emit(log, GSP_REC_SIGNPOST, kind, spid, name, format, ap);
}

void
gsp_signpost_emit(gsp_log_t log, int kind, gsp_signpost_id_t spid,
                  const char *name, const char *format, ...)
{
  va_list ap;

  va_start(ap, format);
  gsp_signpost_emitv(log, kind, spid, name, format, ap);
  va_end(ap);
}

void
gsp_log_emit(gsp_log_t log, int level, const char *format, ...)
{
  va_list ap;

  if (log == NULL || !active())
    return;
  va_start(ap, format);
  emit(log, GSP_REC_LOG, level, 0, "", format, ap);
  va_end(ap);
}
