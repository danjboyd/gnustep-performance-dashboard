/* gsp-dump - print the records of a GNUstep Instruments event stream.
   A debugging aid for the trace format; `gstrace` is the real reader.  */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "GSPerformance/gsp_format.h"

static const char *names[] = {
  "PAD", "STRING", "THREAD", "THREAD_END", "IMAGE", "SAMPLE", "STACK",
  "ALLOC", "FREE", "OBJC_TAG", "REFCOUNT", "SIGNPOST", "LEAK_BEGIN", "LEAK",
  "LEAK_END", "METHOD", "ZOMBIE", "DROPPED", "END", "LOG", "MARK"
};

int
main(int argc, char **argv)
{
  FILE *f;
  gsp_file_header h;
  unsigned long counts[GSP_REC_TYPE_COUNT] = { 0 };
  int verbose = argc > 2 && strcmp(argv[2], "-v") == 0;

  if (argc < 2 || (f = fopen(argv[1], "rb")) == NULL)
    {
      fprintf(stderr, "usage: gsp-dump events-<pid>.bin [-v]\n");
      return 2;
    }
  if (fread(&h, sizeof(h), 1, f) != 1 || memcmp(h.magic, GSP_MAGIC, 8) != 0)
    {
      fprintf(stderr, "not an event stream\n");
      return 1;
    }
  printf("pid %u ppid %u exe %s version %u interval %uus wall %uus\n",
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
      if (fread(payload, r.size - sizeof(r), 1, f) != 1 && r.size > sizeof(r))
        break;
      if (r.type < GSP_REC_TYPE_COUNT)
        counts[r.type]++;
      if (verbose)
        {
          printf("%-10s t=%.6f tid=%u aux=%u", r.type < GSP_REC_TYPE_COUNT
                 ? names[r.type] : "?", (r.time - h.start_ns) / 1e9, r.tid,
                 r.aux);
          if (r.type == GSP_REC_STRING || r.type == GSP_REC_THREAD)
            printf(" \"%s\"", (char *)payload);
          else if (r.type == GSP_REC_IMAGE)
            printf(" %s", (char *)payload + sizeof(gsp_image_payload));
          else if (r.type == GSP_REC_SAMPLE || r.type == GSP_REC_STACK)
            printf(" frames=%u", ((gsp_frames_payload *)payload)->count);
          else if (r.type == GSP_REC_ALLOC)
            printf(" %#lx size=%lu", (unsigned long)((gsp_alloc_payload *)payload)->address,
                   (unsigned long)((gsp_alloc_payload *)payload)->size);
          else if (r.type == GSP_REC_METHOD)
            printf(" %s", (char *)payload + sizeof(gsp_method_payload));
          else if (r.type == GSP_REC_LEAK_END || r.type == GSP_REC_LEAK_BEGIN)
            printf(" count=%lu bytes=%lu", (unsigned long)((gsp_leak_summary_payload *)payload)->count,
                   (unsigned long)((gsp_leak_summary_payload *)payload)->bytes);
          printf("\n");
        }
      free(payload);
    }
  for (int i = 0; i < GSP_REC_TYPE_COUNT; i++)
    if (counts[i])
      printf("%-10s %lu\n", names[i], counts[i]);
  return 0;
}
