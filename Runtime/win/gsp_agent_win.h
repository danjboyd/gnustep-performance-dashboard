/* gsp_agent_win.h - shared by the parts of gsperf-agent.dll.  */

#ifndef GSP_AGENT_WIN_H
#define GSP_AGENT_WIN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* gsp_agent_win.c */
void gspw_emit(uint16_t type, uint32_t aux, uint16_t flags, uint64_t time,
               uint32_t tid, const void *a, size_t alen, const void *b, size_t blen);
uint32_t gspw_intern(const char *s);
uint64_t gspw_now(void);
bool gspw_recording(void);
void gspw_flush(void);
bool gspw_is_agent_thread(unsigned long tid);

/* gsp_leaks_win.c */
void gspw_leaks_start(bool on);
bool gspw_leaks_enabled(void);
void gspw_leaks_snapshot(const void *stack_top);
void gspw_live_insert(void *p, size_t size, uint32_t stack);
bool gspw_live_take(void *p, size_t *size, uint32_t *stack, uint32_t *class_name);
void gspw_live_put(void *p, size_t size, uint32_t stack, uint32_t class_name);
void gspw_live_tag(void *obj, uint32_t class_name);

/* gsp_heap_win.c: import table hooks.  A hook applies to imports of
   `name` from a DLL of the given kind; `real` receives the original.  */
enum { GSPW_LIB_CRT, GSPW_LIB_OBJC, GSPW_LIB_KERNEL, GSPW_LIB_NET };

typedef struct gspw_hook
{
  const char *name;
  int lib;
  void *hook;
  void **real;
} gspw_hook;

bool gspw_guard_enter(void);
void gspw_guard_leave(void);
uint32_t gspw_caller_stack(void);
void gspw_heap_start(bool allocations, bool refcounts, bool zombies, unsigned frames);
void gspw_heap_patch_modules(void);
void gspw_heap_exclude_thread(void);
uint32_t gspw_intern_stack(const uint64_t *frames, unsigned n);
void gspw_agent_image(uint64_t *lo, uint64_t *hi);
bool gspw_exit_snapshot_taken(void);

/* gsp_io_win.c */
extern gspw_hook gspw_io_hooks[];
extern const size_t gspw_io_hook_count;
void gspw_io_start(bool files, bool network);
bool gspw_io_enabled(void);

#endif
