/* Deterministically simulate a policy denying the leak scanner's memory reads. */
#define _GNU_SOURCE
#include <errno.h>
#include <sys/uio.h>

ssize_t
process_vm_readv(pid_t pid, const struct iovec *local, unsigned long local_count,
                 const struct iovec *remote, unsigned long remote_count,
                 unsigned long flags)
{
  (void)pid; (void)local; (void)local_count;
  (void)remote; (void)remote_count; (void)flags;
  errno = EPERM;
  return -1;
}
