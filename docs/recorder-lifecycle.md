# Linux recorder child-status ownership

The GUI opts into `GSPRecordingOptions.useTaskLauncher`. A registered `NSTask`
owns collection of the target process, including when Foundation's run loop
collects child exits while another task is active. The recording monitor reads
that task's public termination reason and status; it never calls `waitpid` for
that PID. Attaching still does not own or reap the attached target.

The default remains the direct `posix_spawn` launcher. The CLI uses that default,
preserving its terminal/session behavior, inherited signal dispositions and
original kernel wait status, including the core-dump flag. Its launch method
is unchanged apart from the private selector name.

## Descriptor handoff and exec

GNUstep Base's NSTask closes extra descriptors during launch. `gsp-launch` is
an unprivileged libc-only exec helper next to the original agent library, found
by that exact path, never PATH. Both app Resources and the packaged CLI runtime
carry a copy. The AppImage agent's stable-copy path does not change helper
resolution. The helper receives no target environment or preload at startup.

A private socketpair temporarily occupies its stdin. A versioned header carries
string counts/size, intended stdio presence and the parent's ignored signal set.
SCM_RIGHTS transfers the intended open stdio descriptors and the existing agent
writer-status datagram endpoint as one checked handoff. NUL-terminated cwd,
argv and environment bytes follow in bounded packets. Invalid framing, absent
rights, invalid cwd and exec errors are launch failures, not target exit 125.
The helper's reserved pre-exec failure code is accompanied by a separate error
response; a real target exiting 125 is an ordinary target result.

The helper duplicates only intended stdio and status descriptor 4, closes every
other descriptor except its close-on-exec error channel, restores ignored signal
dispositions and clears the signal mask. It applies cwd and passes argv/env,
including the recording preload, only to final `execve`. This replaces the helper
in the same PID, so agent parent/PID filtering and writer receipts are unchanged.
Startup I/O has finite five-second socket timeouts. EOF after the prepared reply
uses the standard close-on-exec error-channel convention; abrupt external death
in the tiny prepared-to-exec interval cannot independently prove exec occurred.

## GUI process status and limits

NSTask creates an independent session/process group. GUI stop/escalation still
signals the exact owned PID. Terminal process-group behavior belongs to the
unchanged CLI launcher; the GUI task path is not a replacement for it.

NSTask exposes normal exit versus signal and its code, but not the kernel core
flag. GUI `exitStatus` therefore contains a wait-compatible representation
(`exit << 8` or the signal number), never a fabricated core flag. Final metadata
records `ExitStatusSource=NSTask`, `ExitStatusCoreDumpKnown=NO` and
`TargetSession=independent`; these survive saving and appear in the status
tooltip. Direct CLI recordings record `waitpid` and `CoreDumpKnown=YES`.
An unavailable process result remains a failure; capture completion still
requires matching agent receipts, a valid END record and finalization markers.

Headless unit tests cover a pipe-held target that Foundation collects before
the adapter reads it, an unrelated active NSTask, actual recorder/agent capture
completion, startup failure versus target 125, default CLI selection and core
flag storage. Transport checks cover argv/cwd/env, chunking, stdio, writer FD,
extra descriptor closure, malformed/partial handoffs and ignored signals.
These tests do not qualify a newly assembled package or an AppKit recording.
Packaged GUI, both themes, cancellation/escalation, process cleanup and caller
configuration still require their reserved qualification window. Windows uses
its separate lifecycle implementation and is unchanged.
