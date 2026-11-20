/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Complete writer protocol fixture: legacy, current, future and bad headers. */
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <GSPerformance/gsp_format.h>
#include <GSPerformance/gsp_capture.h>

__attribute__((constructor)) static void
write_stream(void)
{
  const char *directory = getenv("GSP_OUTPUT");
  if (!directory) return;
  unsigned size = (unsigned)atoi(getenv("PD_FIXTURE_HEADER_SIZE"));
  gsp_file_header header = {0};
  memcpy(header.magic, GSP_MAGIC, 8);
  header.version = GSP_FORMAT_VERSION;
  header.header_size = size;
  header.pid = (uint32_t)getpid();
  header.start_ns = 1000000000;
  header.pointer_size = sizeof(void *);
  strcpy(header.exe, "/synthetic-header-writer");
  char path[4096];
  snprintf(path, sizeof(path), "%s/events-%u.bin", directory, header.pid);
  FILE *file = fopen(path, "wb");
  assert(file);
  unsigned char bytes[328] = {0};
  memcpy(bytes, &header, sizeof(header));
  /* Bad size 304 retains a full prefix, but declares an invalid header. */
  unsigned written = size < GSP_FILE_HEADER_V1_SIZE ? GSP_FILE_HEADER_V1_SIZE : size;
  assert(written <= sizeof(bytes));
  assert(fwrite(bytes, 1, written, file) == written);
  gsp_record end = { GSP_REC_END, 0, sizeof(end), header.start_ns + 1, header.pid, 0 };
  assert(fwrite(&end, sizeof(end), 1, file) == 1);
  assert(fflush(file) == 0 && fsync(fileno(file)) == 0 && fclose(file) == 0);
  snprintf(path, sizeof(path), "%s/events-%u.done", directory, header.pid);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  assert(fd >= 0 && close(fd) == 0);
  gsp_writer_status status = { GSP_WRITER_STATUS_MAGIC, GSP_WRITER_STATUS_VERSION,
    header.pid, GSP_OUTPUT_COMPLETE, 0, 0, header.start_ns, written + sizeof(end) };
  const char *channel = getenv("GSP_STATUS_FD");
  assert(channel && send(atoi(channel), &status, sizeof(status), MSG_NOSIGNAL) == sizeof(status));
}
