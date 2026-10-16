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
bool gspw_is_agent_thread(unsigned long tid);

/* gsp_leaks_win.c */
void gspw_leaks_start(bool on);
bool gspw_leaks_enabled(void);
void gspw_leaks_snapshot(const void *stack_top);
void gspw_live_insert(void *p, size_t size, uint32_t stack);
bool gspw_live_take(void *p, size_t *size, uint32_t *stack, uint32_t *class_name);
void gspw_live_put(void *p, size_t size, uint32_t stack, uint32_t class_name);
void gspw_live_tag(void *obj, uint32_t class_name);

/* gsp_heap_win.c */
void gspw_heap_start(bool allocations, unsigned frames);
void gspw_heap_patch_modules(void);
void gspw_heap_exclude_thread(void);
uint32_t gspw_intern_stack(const uint64_t *frames, unsigned n);
void gspw_agent_image(uint64_t *lo, uint64_t *hi);
bool gspw_exit_snapshot_taken(void);

#endif
