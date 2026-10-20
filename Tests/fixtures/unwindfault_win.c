/* A running function whose temporary frame register disagrees with .pdata.
   Sampling must truncate its stack, never fault inside RtlVirtualUnwind. */
#include <windows.h>
#include <stdio.h>

void transient_frame(void);
__asm__(
  ".text\n"
  ".globl transient_frame\n"
  ".seh_proc transient_frame\n"
  "transient_frame:\n"
  "pushq %rbp\n"
  ".seh_pushreg %rbp\n"
  "subq $32, %rsp\n"
  ".seh_stackalloc 32\n"
  "leaq 32(%rsp), %rbp\n"
  ".seh_setframe %rbp, 32\n"
  ".seh_endprologue\n"
  "xorl %ebp, %ebp\n"
  "movl $1200, %ecx\n"
  "callq Sleep\n"
  "nop\n"
  "nop\n"
  "addq $32, %rsp\n"
  "popq %rbp\n"
  "retq\n"
  ".seh_endproc\n");

int
main(void)
{
  transient_frame();
  puts("transient frame survived sampling");
  return 0;
}
