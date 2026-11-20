/* SPDX-License-Identifier: GPL-3.0-or-later */
/* gsp-dump - print the records of a Performance Dashboard event stream.
   A debugging aid for the trace format; `gstrace` is the real reader.  */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "GSPerformance/gsp_format.h"

static const char *names[] = {
  "PAD", "STRING", "THREAD", "THREAD_END", "IMAGE", "SAMPLE", "STACK",
  "ALLOC", "FREE", "OBJC_TAG", "REFCOUNT", "SIGNPOST", "LEAK_BEGIN", "LEAK",
  "LEAK_END", "METHOD", "ZOMBIE", "DROPPED", "END", "LOG", "MARK",
  "IO", "DIAGNOSTIC", "THREAD_STATE"
};

static const char *
record_name(unsigned type)
{
  return type < sizeof(names) / sizeof(names[0]) ? names[type] : "?";
}

int
main(int argc, char **argv)
{
  FILE *f;
  gsp_file_header h = {0};
  unsigned long counts[GSP_REC_TYPE_COUNT] = { 0 };
  int verbose = argc > 2 && strcmp(argv[2], "-v") == 0;

  if (argc < 2 || (f = fopen(argv[1], "rb")) == NULL)
    {
      fprintf(stderr, "usage: gsp-dump events-<pid>.bin [-v]\n");
      return 2;
    }
  if (fread(&h, GSP_FILE_HEADER_V1_SIZE, 1, f) != 1
      || memcmp(h.magic, GSP_MAGIC, 8) != 0 || h.version != GSP_FORMAT_VERSION
      || h.header_size < GSP_FILE_HEADER_V1_SIZE
      || fseek(f, 0, SEEK_END) != 0 || ftell(f) < (long)h.header_size
      || fseek(f, (long)h.header_size, SEEK_SET) != 0)
    {
      fprintf(stderr, "not an event stream\n");
      return 1;
    }
  printf("pid %u ppid %u exe %.256s version %u interval %uus wall %uus\n",
         h.pid, h.ppid, h.exe, h.version, h.sample_interval_us,
         h.wall_interval_us);
  for (;;)
    {
      gsp_record r;
      unsigned char *payload;
      if (fread(&r, sizeof(r), 1, f) != 1)
        break;
      if (r.size < sizeof(r) || r.size > (64u << 20))
        {
          fprintf(stderr, "corrupt record size %u\n", r.size);
          return 1;
        }
      payload = malloc(r.size - sizeof(r) + 1);
      if (payload == NULL) return 1;
      size_t length = r.size - sizeof(r);
      if (fread(payload, 1, length, f) != length)
        { free(payload); break; }
      payload[length] = 0;
      if (r.type < GSP_REC_TYPE_COUNT)
        counts[r.type]++;
      if (verbose)
        {
          printf("%-10s t=%.6f tid=%u aux=%u", record_name(r.type), (r.time - h.start_ns) / 1e9, r.tid,
                 r.aux);
          if (r.type == GSP_REC_STRING || r.type == GSP_REC_THREAD)
            printf(" \"%s\"", (char *)payload);
          else if (r.type == GSP_REC_IMAGE && length >= sizeof(gsp_image_payload))
            printf(" %s", (char *)payload + sizeof(gsp_image_payload));
          else if ((r.type == GSP_REC_SAMPLE || r.type == GSP_REC_STACK)
                   && length >= sizeof(gsp_frames_payload))
            printf(" frames=%u", ((gsp_frames_payload *)payload)->count);
          else if (r.type == GSP_REC_ALLOC && length >= sizeof(gsp_alloc_payload))
            printf(" %#lx size=%lu", (unsigned long)((gsp_alloc_payload *)payload)->address,
                   (unsigned long)((gsp_alloc_payload *)payload)->size);
          else if (r.type == GSP_REC_METHOD && length >= sizeof(gsp_method_payload))
            printf(" %s", (char *)payload + sizeof(gsp_method_payload));
          else if ((r.type == GSP_REC_LEAK_END || r.type == GSP_REC_LEAK_BEGIN)
                   && length >= sizeof(gsp_leak_summary_payload))
            printf(" count=%lu bytes=%lu", (unsigned long)((gsp_leak_summary_payload *)payload)->count,
                   (unsigned long)((gsp_leak_summary_payload *)payload)->bytes);
          printf("\n");
        }
      free(payload);
    }
  for (int i = 0; i < GSP_REC_TYPE_COUNT; i++)
    if (counts[i])
      printf("%-10s %lu\n", record_name((unsigned)i), counts[i]);
  return 0;
}
