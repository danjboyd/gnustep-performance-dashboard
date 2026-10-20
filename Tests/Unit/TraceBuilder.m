#import "TraceBuilder.h"

@implementation TraceBuilder
{
  NSMutableData *_data;
  int _pid;
  uint64_t _start;
}

- (instancetype) initWithPID: (int)pid
{
  if ((self = [super init]) != nil)
    {
      gsp_file_header h;
      _pid = pid;
      _start = 1000000000ull;
      memset(&h, 0, sizeof(h));
      memcpy(h.magic, GSP_MAGIC, 8);
      h.version = GSP_FORMAT_VERSION;
      h.header_size = sizeof(h);
      h.pid = (uint32_t)pid;
      h.start_ns = _start;
      h.pointer_size = 8;
      h.flags = GSP_STREAM_FROM_AGENT;
      h.sample_interval_us = 1000;
      h.wall_interval_us = 10000;
      strcpy(h.exe, "/usr/bin/synthetic");
      _data = [NSMutableData dataWithBytes: &h length: sizeof(h)];
    }
  return self;
}

- (uint64_t) start { return _start; }

- (void) diagnosticAt: (uint64_t)t message: (const char *)message
{
  [self record: GSP_REC_DIAGNOSTIC aux: GSP_DIAGNOSTIC_LEAK_SCAN_UNAVAILABLE
          time: t tid: 0 a: message alen: strlen(message) + 1 b: NULL blen: 0];
}

- (void) ioAt: (uint64_t)time duration: (uint64_t)duration tid: (uint32_t)tid
{
  gsp_io_payload payload = { 128, duration, 3, 0, 0, 0 };
  [self record: GSP_REC_IO aux: GSP_IO_READ time: time tid: tid
             a: &payload alen: sizeof(payload) b: NULL blen: 0];
}

- (void) dropped: (uint64_t)count
{
  [self record: GSP_REC_DROPPED aux: GSP_REC_SAMPLE time: _start tid: 0
             a: &count alen: sizeof(count) b: NULL blen: 0];
}

- (void) record: (uint16_t)type aux: (uint32_t)aux time: (uint64_t)t tid: (uint32_t)tid
              a: (const void *)a alen: (size_t)alen b: (const void *)b blen: (size_t)blen
{
  static const uint8_t zeros[8];
  size_t raw = sizeof(gsp_record) + alen + blen;
  size_t total = GSP_RECORD_ALIGN(raw);
  gsp_record h = { type, 0, (uint32_t)total, t, tid, aux };
  [_data appendBytes: &h length: sizeof(h)];
  if (alen)
    [_data appendBytes: a length: alen];
  if (blen)
    [_data appendBytes: b length: blen];
  [_data appendBytes: zeros length: total - raw];
}

- (void) string: (uint32_t)identifier value: (const char *)value
{
  [self record: GSP_REC_STRING aux: identifier time: _start tid: (uint32_t)_pid
             a: value alen: strlen(value) + 1 b: NULL blen: 0];
}

- (void) name: (uint64_t)address as: (NSString *)name
{
  gsp_method_payload p = { address };
  const char *c = [name UTF8String];
  [self record: GSP_REC_METHOD aux: 0 time: _start tid: 0
             a: &p alen: sizeof(p) b: c blen: strlen(c) + 1];
}

- (void) thread: (uint32_t)tid name: (const char *)name main: (BOOL)isMain at: (uint64_t)t
{
  [self record: GSP_REC_THREAD aux: isMain ? GSP_THREAD_MAIN : 0 time: t tid: tid
             a: name alen: strlen(name) + 1 b: NULL blen: 0];
}

- (void) stack: (uint32_t)identifier frames: (const uint64_t *)frames count: (unsigned)n
{
  gsp_frames_payload fp = { n, 0, 0 };
  [self record: GSP_REC_STACK aux: identifier time: _start tid: (uint32_t)_pid
             a: &fp alen: sizeof(fp) b: frames blen: n * 8];
}

- (void) sampleAt: (uint64_t)t tid: (uint32_t)tid kind: (uint32_t)kind weight: (uint16_t)w
           frames: (const uint64_t *)frames count: (unsigned)n
{
  gsp_frames_payload fp = { n, 0, w };
  [self record: GSP_REC_SAMPLE aux: kind time: t tid: tid
             a: &fp alen: sizeof(fp) b: frames blen: n * 8];
}

- (void) allocAt: (uint64_t)t address: (uint64_t)a size: (uint64_t)size stack: (uint32_t)stack
{
  gsp_alloc_payload p = { a, size, stack, 0, 0 };
  [self record: GSP_REC_ALLOC aux: 0 time: t tid: (uint32_t)_pid
             a: &p alen: sizeof(p) b: NULL blen: 0];
}

- (void) freeAt: (uint64_t)t address: (uint64_t)a
{
  gsp_free_payload p = { a, 0, 0 };
  [self record: GSP_REC_FREE aux: 0 time: t tid: (uint32_t)_pid
             a: &p alen: sizeof(p) b: NULL blen: 0];
}

- (void) tagAt: (uint64_t)t address: (uint64_t)a classString: (uint32_t)sid
{
  gsp_tag_payload p = { a, sid, 0 };
  [self record: GSP_REC_OBJC_TAG aux: 0 time: t tid: (uint32_t)_pid
             a: &p alen: sizeof(p) b: NULL blen: 0];
}

- (void) signpostAt: (uint64_t)t kind: (uint32_t)kind spid: (uint64_t)spid
               name: (uint32_t)nameID category: (uint32_t)catID message: (const char *)msg
{
  gsp_signpost_payload p = { spid, 0, catID, nameID, msg ? (uint32_t)strlen(msg) : 0 };
  [self record: GSP_REC_SIGNPOST aux: kind time: t tid: (uint32_t)_pid
             a: &p alen: sizeof(p) b: msg ? msg : "" blen: msg ? strlen(msg) + 1 : 1];
}

- (void) leakSnapshot: (uint32_t)ordinal at: (uint64_t)t leaks: (NSArray *)leaks
{
  gsp_leak_summary_payload begin = { 100, 4096, 0 };
  uint64_t bytes = 0;
  [self record: GSP_REC_LEAK_BEGIN aux: ordinal time: t tid: 0
             a: &begin alen: sizeof(begin) b: NULL blen: 0];
  for (NSArray *l in leaks)
    {
      gsp_leak_payload p;
      memset(&p, 0, sizeof(p));
      p.address = [[l objectAtIndex: 0] unsignedLongLongValue];
      p.size = [[l objectAtIndex: 1] unsignedLongLongValue];
      p.stack = [[l objectAtIndex: 2] unsignedIntValue];
      p.class_name = [[l objectAtIndex: 3] unsignedIntValue];
      p.snapshot = ordinal;
      bytes += p.size;
      [self record: GSP_REC_LEAK aux: ordinal time: t tid: 0
                 a: &p alen: sizeof(p) b: NULL blen: 0];
    }
  gsp_leak_summary_payload end = { [leaks count], bytes, 1234 };
  [self record: GSP_REC_LEAK_END aux: ordinal time: t tid: 0
             a: &end alen: sizeof(end) b: NULL blen: 0];
}

- (void) end: (uint64_t)t
{
  [self record: GSP_REC_END aux: 0 time: t tid: (uint32_t)_pid a: NULL alen: 0 b: NULL blen: 0];
}

- (void) appendGarbage: (NSUInteger)bytes
{
  gsp_record h = { GSP_REC_SAMPLE, 0, 4096, _start, (uint32_t)_pid, 1 };
  [_data appendBytes: &h length: MIN(bytes, sizeof(h))];
}

- (NSString *) writeBundleNamed: (NSString *)name instruments: (NSArray *)instruments
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"gsp-unit-%d-%@.gstrace",
     [[NSProcessInfo processInfo] processIdentifier], name]];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath: dir error: NULL];
  [fm createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
  [_data writeToFile: [dir stringByAppendingPathComponent:
    [NSString stringWithFormat: @"events-%d.bin", _pid]] atomically: NO];
  NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
    @"Synthetic", @"Template", instruments ?: [NSArray array], @"Instruments",
    [NSNumber numberWithInt: _pid], @"TargetPID", nil];
  [info writeToFile: [dir stringByAppendingPathComponent: @"Info.plist"] atomically: NO];
  return dir;
}

@end
