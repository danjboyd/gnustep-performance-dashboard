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

/* gsp_heap_win.c */
void gspw_heap_start(bool allocations, unsigned frames);
void gspw_heap_patch_modules(void);
void gspw_heap_exclude_thread(void);
uint32_t gspw_intern_stack(const uint64_t *frames, unsigned n);

#endif
