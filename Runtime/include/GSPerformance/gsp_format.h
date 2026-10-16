/* gsp_format.h - on-disk layout of Performance Dashboard event streams.

   A trace is a directory bundle (Foo.gstrace/) holding an Info.plist written
   by the recorder and one event stream per traced process
   (events-<pid>.bin).  A stream is a gsp_file_header followed by records.
   Every record starts with a gsp_record header; `size` is the total record
   length including the header, always a multiple of 8.

   Records are not globally time ordered: each thread writes into its own
   buffers, which are flushed independently.  Readers must make two passes
   (definitions such as strings and stacks may appear after their uses) and
   sort by time where order matters.

   Stack frames: frames[0] is the interrupted PC (for samples) or the first
   caller outside the agent (for allocation stacks); every later frame is a
   return address.  Symbolicate return addresses as (address - 1).

   This header is shared by the C runtime, the privileged helper and the
   Objective-C reader.  It must stay plain C.  */

#ifndef GSP_FORMAT_H
#define GSP_FORMAT_H

#include <stdint.h>

#define GSP_MAGIC "GSPTRACE"
#define GSP_FORMAT_VERSION 1

typedef struct gsp_file_header
{
  char magic[8];              /* "GSPTRACE" */
  uint32_t version;           /* GSP_FORMAT_VERSION */
  uint32_t header_size;       /* sizeof(gsp_file_header) */
  uint32_t pid;
  uint32_t ppid;
  uint64_t start_ns;          /* CLOCK_MONOTONIC at stream start */
  uint64_t start_realtime_ns; /* CLOCK_REALTIME at the same moment */
  uint32_t pointer_size;
  uint32_t flags;             /* GSP_STREAM_* */
  uint32_t sample_interval_us;
  uint32_t wall_interval_us;
  char exe[256];              /* resolved executable path */
} gsp_file_header;

enum
{
  GSP_STREAM_FROM_AGENT = 1 << 0,   /* in-process agent */
  GSP_STREAM_FROM_PERF = 1 << 1,    /* privileged perf_event helper */
  GSP_STREAM_KERNEL_FRAMES = 1 << 2 /* samples may contain kernel frames */
};

typedef struct gsp_record
{
  uint16_t type;
  uint16_t flags;
  uint32_t size;
  uint64_t time;  /* CLOCK_MONOTONIC nanoseconds */
  uint32_t tid;
  uint32_t aux;   /* type specific, see below */
} gsp_record;

enum gsp_record_type
{
  GSP_REC_PAD = 0,
  GSP_REC_STRING = 1,       /* aux = string id; payload = NUL-terminated UTF-8 */
  GSP_REC_THREAD = 2,       /* aux = GSP_THREAD_*; payload = name (may be empty) */
  GSP_REC_THREAD_END = 3,
  GSP_REC_IMAGE = 4,        /* gsp_image_payload + path */
  GSP_REC_SAMPLE = 5,       /* aux = GSP_SAMPLE_*; gsp_frames_payload */
  GSP_REC_STACK = 6,        /* aux = stack id; gsp_frames_payload */
  GSP_REC_ALLOC = 7,        /* gsp_alloc_payload */
  GSP_REC_FREE = 8,         /* gsp_free_payload */
  GSP_REC_OBJC_TAG = 9,     /* gsp_tag_payload: block at addr is an instance */
  GSP_REC_REFCOUNT = 10,    /* aux = GSP_RC_*; gsp_refcount_payload */
  GSP_REC_SIGNPOST = 11,    /* aux = GSP_SIGNPOST_*; gsp_signpost_payload */
  GSP_REC_LEAK_BEGIN = 12,  /* gsp_leak_summary_payload (live blocks) */
  GSP_REC_LEAK = 13,        /* gsp_leak_payload */
  GSP_REC_LEAK_END = 14,    /* gsp_leak_summary_payload (leaked blocks) */
  GSP_REC_METHOD = 15,      /* gsp_method_payload + "-[Class selector]" */
  GSP_REC_ZOMBIE = 16,      /* gsp_zombie_payload */
  GSP_REC_DROPPED = 17,     /* aux = record type dropped; payload u64 count */
  GSP_REC_END = 18,         /* stream finished cleanly */
  GSP_REC_LOG = 19,         /* aux = level; gsp_signpost_payload (name unused) */
  GSP_REC_MARK = 20,        /* aux = GSP_MARK_*; payload = optional text */
  GSP_REC_IO = 21,          /* aux = GSP_IO_*; gsp_io_payload (time = start) */
  GSP_REC_TYPE_COUNT
};

enum { GSP_THREAD_MAIN = 1, GSP_THREAD_INTERNAL = 2 };

enum
{
  GSP_SAMPLE_CPU = 1,   /* thread CPU-time timer: thread was running */
  GSP_SAMPLE_WALL = 2,  /* wall-clock timer: thread state unknown */
  GSP_SAMPLE_PERF = 3   /* perf_event cpu-clock sample */
};

enum { GSP_FRAMES_TRUNCATED = 1, GSP_FRAMES_KERNEL_SPLIT = 2 };

enum { GSP_RC_RETAIN = 1, GSP_RC_RELEASE = 2, GSP_RC_AUTORELEASE = 3 };

enum
{
  GSP_SIGNPOST_EVENT = 0,
  GSP_SIGNPOST_BEGIN = 1,
  GSP_SIGNPOST_END = 2
};

enum { GSP_MARK_START = 1, GSP_MARK_STOP_REQUESTED = 2, GSP_MARK_USER = 3 };

/* File and network operations (File Activity and Network instruments). */
enum
{
  GSP_IO_OPEN = 1,      /* fd = result; name = path */
  GSP_IO_CLOSE = 2,
  GSP_IO_READ = 3,      /* read, pread, readv, fread */
  GSP_IO_WRITE = 4,     /* write, pwrite, writev, fwrite */
  GSP_IO_SYNC = 5,      /* fsync, fdatasync */
  GSP_IO_CONNECT = 6,   /* name = peer address */
  GSP_IO_ACCEPT = 7,    /* fd = new socket; name = peer address */
  GSP_IO_SEND = 8,      /* send, sendto, sendmsg */
  GSP_IO_RECV = 9       /* recv, recvfrom, recvmsg */
};

typedef struct gsp_io_payload
{
  int64_t result;      /* bytes, new fd, 0, or -errno */
  uint64_t duration;   /* ns */
  int32_t fd;
  uint32_t name;       /* string id: path or peer, 0 if none */
  uint32_t stack;
  uint32_t flags;      /* open flags; GSP_IO_SOCKET on socket closes */
} gsp_io_payload;

#define GSP_IO_SOCKET 0x80000000u

typedef struct gsp_image_payload
{
  uint64_t base;   /* load bias: runtime address = base + ELF vaddr */
  uint64_t start;  /* lowest mapped executable address */
  uint64_t end;    /* highest mapped executable address (exclusive) */
  /* followed by NUL-terminated path */
} gsp_image_payload;

typedef struct gsp_frames_payload
{
  uint32_t count;
  uint16_t kernel_count; /* leading frames that are kernel addresses */
  uint16_t weight;       /* samples represented (timer overruns + 1); 0 = 1 */
  /* followed by count uint64_t frames */
} gsp_frames_payload;

typedef struct gsp_alloc_payload
{
  uint64_t address;
  uint64_t size;
  uint32_t stack;     /* stack id, 0 = unknown */
  uint32_t category;  /* string id of class name, 0 = plain malloc */
  uint64_t old_address; /* realloc: previous block, otherwise 0 */
} gsp_alloc_payload;

typedef struct gsp_free_payload
{
  uint64_t address;
  uint32_t stack;
  uint32_t reserved;
} gsp_free_payload;

typedef struct gsp_tag_payload
{
  uint64_t address;
  uint32_t class_name; /* string id */
  uint32_t stack;
} gsp_tag_payload;

typedef struct gsp_refcount_payload
{
  uint64_t address;
  uint32_t stack;
  int32_t refcount;    /* retain count after the operation, -1 unknown */
} gsp_refcount_payload;

typedef struct gsp_signpost_payload
{
  uint64_t signpost_id;
  uint32_t subsystem;  /* string ids */
  uint32_t category;
  uint32_t name;
  uint32_t message_length;
  /* followed by message bytes and a NUL */
} gsp_signpost_payload;

typedef struct gsp_leak_summary_payload
{
  uint64_t count;
  uint64_t bytes;
  uint64_t duration_us;
} gsp_leak_summary_payload;

typedef struct gsp_leak_payload
{
  uint64_t address;
  uint64_t size;
  uint32_t stack;
  uint32_t class_name;
  uint32_t snapshot;  /* snapshot ordinal within the stream */
  uint32_t reserved;
} gsp_leak_payload;

typedef struct gsp_method_payload
{
  uint64_t imp;
  /* followed by NUL-terminated "-[Class selector]" */
} gsp_method_payload;

typedef struct gsp_zombie_payload
{
  uint64_t address;
  uint32_t class_name;
  uint32_t selector;
  uint32_t stack;
  uint32_t reserved;
} gsp_zombie_payload;

#define GSP_RECORD_ALIGN(n) (((n) + 7u) & ~7u)

#endif
