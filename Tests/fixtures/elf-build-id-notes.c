/* Pure malformed-note cases: no loading, allocation or file access. */
#include "../../Runtime/gsp_build_id.h"
#include <assert.h>
#include <stdio.h>

static void
header(uint8_t *p, uint32_t name, uint32_t desc, uint32_t type)
{
  uint32_t fields[] = {name, desc, type};
  memcpy(p, fields, sizeof(fields));
}

int
main(void)
{
  uint8_t notes[96] = {0}, out[64] = {0};
  header(notes, 4, 4, 3); memcpy(notes + 12, "GNU", 4);
  memcpy(notes + 16, "abcd", 4);
  for (size_t size = 0; size < 20; size++)
    assert(gsp_note_build_id(notes, size, 4, out, sizeof(out)) == 0);
  assert(gsp_note_build_id(notes, 20, 4, out, sizeof(out)) == 4);
  assert(memcmp(out, "abcd", 4) == 0);
  assert(gsp_note_build_id(notes, 20, 4, out, 3) == 0);
  header(notes, UINT32_MAX, 4, 3);
  assert(gsp_note_build_id(notes, sizeof(notes), 4, out, sizeof(out)) == 0);
  header(notes, 4, UINT32_MAX, 3);
  assert(gsp_note_build_id(notes, sizeof(notes), 4, out, sizeof(out)) == 0);
  header(notes, 4, 4, 1); header(notes + 20, 4, 4, 3);
  memcpy(notes + 32, "GNU", 4); memcpy(notes + 36, "next", 4);
  assert(gsp_note_build_id(notes, 40, 4, out, sizeof(out)) == 4);
  assert(memcmp(out, "next", 4) == 0);
  /* An 8-aligned first note with namesz=5 forces padding after name+header. */
  memset(notes, 0, sizeof(notes)); header(notes, 5, 4, 1);
  header(notes + 32, 4, 4, 3); memcpy(notes + 44, "GNU", 4);
  memcpy(notes + 48, "eight", 4);
  assert(gsp_note_build_id(notes, 52, 8, out, sizeof(out)) == 4);
  assert(memcmp(out, "eight", 4) == 0);
  assert(gsp_note_build_id(notes, 52, 3, out, sizeof(out)) == 0);
  /* The scan must reject an unmapped/outside PT_NOTE before reading bytes. */
  assert(gsp_note_range_within(0x1100, 52, 0x1000, 0x1000));
  assert(!gsp_note_range_within(0x1ff0, 52, 0x1000, 0x1000));
  assert(!gsp_note_range_within(0x0fff, 52, 0x1000, 0x1000));
  assert(!gsp_note_range_within(UINT64_MAX - 3, 8, UINT64_MAX - 7, 8));
  puts("PASS bounded ELF notes: truncation, huge sizes, multiple notes, 8-byte alignment, readable range");
  return 0;
}
