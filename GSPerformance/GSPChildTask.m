/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import "GSPChildTask.h"
#if defined(__linux__)
#include "../Runtime/gsp_launch_protocol.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static BOOL
append_string(NSMutableData *data, NSString *string)
{
  NSData *bytes = [string dataUsingEncoding: NSUTF8StringEncoding];
  if (!bytes || memchr([bytes bytes], 0, [bytes length])) return NO;
  [data appendData: bytes];
  char nul = 0;
  [data appendBytes: &nul length: 1];
  return [data length] <= GSP_LAUNCH_LIMIT;
}

@implementation GSPChildTask
{
  NSTask *_task;
}
- (int) pid { return [_task processIdentifier]; }

- (BOOL) launchHelper: (NSString *)helper executable: (NSString *)executable
           arguments: (NSArray *)arguments environment: (NSDictionary *)environment
    workingDirectory: (NSString *)directory descriptors: (const int *)descriptors
               error: (NSError **)error
{
  int code = EINVAL, pair[2] = {-1, -1};
  BOOL hasLaunched = NO;
  NSError *taskLaunchError = nil;
  NSMutableData *payload = [NSMutableData data];
  NSArray *keys = [[environment allKeys] sortedArrayUsingSelector: @selector(compare:)];
  if (![executable isAbsolutePath] || !append_string(payload, directory ?: @"")
      || !append_string(payload, executable))
    goto failed;
  for (NSString *argument in arguments)
    if (!append_string(payload, argument)) goto failed;
  for (NSString *key in keys)
    {
      if (![key length] || [key rangeOfString: @"="].location != NSNotFound) goto failed;
      if (!append_string(payload, [NSString stringWithFormat: @"%@=%@", key,
                                   [environment objectForKey: key]])) goto failed;
    }
  if ([arguments count] >= UINT32_MAX || [keys count] > UINT32_MAX) goto failed;
  struct gsp_launch_header header = {GSP_LAUNCH_MAGIC, 1, (uint32_t)[payload length],
    (uint32_t)[arguments count] + 1, (uint32_t)[keys count], 0, {0, 0}, 0};
  for (int number = 1; number < NSIG && number <= 64; number++)
    {
      struct sigaction action;
      if (!sigaction(number, NULL, &action) && action.sa_handler == SIG_IGN)
        header.ignored_signals |= UINT64_C(1) << (number - 1);
    }
  int rights[4];
  unsigned count = 0;
  for (unsigned i = 0; i < 3; i++)
    if (descriptors[i] >= 0)
      { rights[count++] = descriptors[i]; header.stdio_mask |= 1u << i; }
  rights[count++] = descriptors[3];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair))
    { code = errno; goto failed; }
  struct timeval timeout = {5, 0};
  if (setsockopt(pair[0], SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))
      || setsockopt(pair[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)))
    { code = errno; goto failed; }
  @try
    {
      _task = [NSTask new];
      NSString *absoluteHelper = [helper isAbsolutePath] ? helper
        : [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent: helper];
      [_task setLaunchPath: absoluteHelper];
      [_task setArguments: @[]];
      /* In particular, the trampoline must not preload the recording agent. */
      [_task setEnvironment: @{}];
      [_task setStandardInput: [[NSFileHandle alloc] initWithFileDescriptor: pair[1]
                                                           closeOnDealloc: NO]];
      [_task setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
      [_task setStandardError: [NSFileHandle fileHandleWithNullDevice]];
      if (![_task launchAndReturnError: &taskLaunchError])
        { code = EIO; goto failed; }
      hasLaunched = YES;
    }
  @catch (NSException *exception)
    { code = EIO; goto failed; }
  close(pair[1]); pair[1] = -1;
  union { struct cmsghdr align; char bytes[CMSG_SPACE(4 * sizeof(int))]; } control;
  memset(&control, 0, sizeof(control));
  struct iovec io = {&header, sizeof(header)};
  struct msghdr message = {0};
  message.msg_iov = &io; message.msg_iovlen = 1;
  message.msg_control = control.bytes; message.msg_controllen = CMSG_SPACE(count * sizeof(int));
  struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
  cmsg->cmsg_level = SOL_SOCKET; cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(count * sizeof(int));
  memcpy(CMSG_DATA(cmsg), rights, count * sizeof(int));
  ssize_t n;
  do n = sendmsg(pair[0], &message, MSG_NOSIGNAL); while (n < 0 && errno == EINTR);
  if (n != sizeof(header)) { code = n < 0 ? errno : EIO; goto failed; }
  for (NSUInteger offset = 0; offset < [payload length]; )
    {
      NSUInteger size = MIN((NSUInteger)16384, [payload length] - offset);
      do n = send(pair[0], (const char *)[payload bytes] + offset, size, MSG_NOSIGNAL);
      while (n < 0 && errno == EINTR);
      if (n != size) { code = n < 0 ? errno : EIO; goto failed; }
      offset += size;
    }
  struct gsp_launch_reply reply;
  do n = recv(pair[0], &reply, sizeof(reply), MSG_TRUNC); while (n < 0 && errno == EINTR);
  if (n != sizeof(reply) || reply.prepared != 1 || reply.error)
    { code = n == sizeof(reply) && reply.error > 0 ? reply.error : EPROTO; goto failed; }
  do n = recv(pair[0], &reply, sizeof(reply), MSG_TRUNC); while (n < 0 && errno == EINTR);
  if (n != 0)
    { code = n == sizeof(reply) && reply.error > 0 ? reply.error : (n < 0 ? errno : EPROTO);
      goto failed; }
  close(pair[0]);
  return YES;

failed:
  if (pair[0] >= 0) close(pair[0]);
  if (pair[1] >= 0) close(pair[1]);
  if (hasLaunched)
    {
      /* Only the registered task owns wait/reaping, including startup errors.
         Kill only the not-yet-successful launch, never a PID from a message. */
      if ([_task isRunning]) kill([_task processIdentifier], SIGKILL);
      [_task waitUntilExit];
    }
  _task = nil;
  if (error) *error = taskLaunchError ?: [NSError errorWithDomain: NSPOSIXErrorDomain code: code
    userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
      @"Recorder target launch failed: %s", strerror(code)]}];
  return NO;
}

- (BOOL) pollStatus: (int *)status
{
  if (!_task || [_task isRunning]) return NO;
  int value = [_task terminationStatus];
  NSTaskTerminationReason reason = [_task terminationReason];
  if (reason == NSTaskTerminationReasonExit && value >= 0 && value <= 255)
    *status = value << 8;
  else if (reason == NSTaskTerminationReasonUncaughtSignal && value > 0 && value < 128)
    *status = value;
  else *status = -1;
  return YES;
}
@end
#endif
