# Build-ID matched local runtime symbols

Existing trace image records contain an absolute path, ELF load bias and
executable mapping range. Stack addresses and Objective-C method names are
recorded; display snapshots may be embedded by `symbolicate --embed`. The
stream and GSPImage do not contain a module build ID, original file digest,
debuglink CRC or a copy of runtime/debug files. A historic path alone cannot
prove that the image still names the bytes loaded when recording.

The reader parses ELF symbol tables, build IDs and debuglink names. It already
looks in standard debug locations, but previously selected richer debug tables
without verifying their build ID. This can silently attach symbols from the
wrong build. Require a nonempty image ID and equal candidate ID before using
separate debug or unstripped symbol tables, including debuglink candidates.
No basename, symbol count or directory naming alone establishes identity.

Add explicit local `GSP_DEBUG_ROOTS` directories or full ELF/debug file paths.
Roots use colon separators on Unix and semicolons on Windows. Directories
support `.build-id/xx/rest.debug` and `.build-id/xx/rest` layouts, plus the
`xx/rest.debug` form when the root itself is a build-ID directory. Every
candidate is parsed and compared; search roots never execute code or fetch
files. Preserve original ELF function boundaries and load-bias arithmetic.
Source-line lookup must use the selected matched debug file too. Cache entries
include the configured roots, so alternate root sets do not reuse each other.

For old traces, describe matching as local image-to-debug identity, not verified
recording-time identity. If the original image is missing or matching symbols
are unavailable, retain honest module+offset labels. No new agent/format or
network/debuginfod dependency is introduced in this change. Capture-time IDs
require a separately qualified agent/format extension; embedded display-name
snapshots keep their existing precedence and are not retroactive ID evidence.

Validation must cover a correct candidate resolving a private function, a
different-ID richer candidate refusing, missing IDs refusing, root layout and
existing fallback behavior. Re-analyze the retained Arlen trace without
embedding or overwriting it, report exact before/after unresolved denominators,
and distinguish absent matching local symbols from a resolution failure.

CLI already supports range/focus/prune/hide-system/symbol-summary. Improve
examples and interpretation without changing defaults, filter semantics or
claiming these options are new. GUI changes are deferred to avoid unrelated
visual qualification in this local symbol work.

## Recording-time identity proposal (design only)

A future optional IMAGE_BUILD_ID record should bind a bounded GNU build-ID
byte sequence to an exact IMAGE record in the same process stream, preferably
by record offset or an explicit monotonically increasing image instance ID.
Base address alone is ambiguous after unload/reload. Read the loaded object's
PT_NOTE from mapped, range-checked program headers during the existing image
scan outside signal handlers; never allocate, lock or open files in a sample
signal handler, and keep the agent libc-only. Define missing/unsupported IDs
explicitly; PE/PDB identity needs a separate platform contract.

Old sized-record readers can skip an optional unknown record, but compatibility
and version rules must be reviewed before assigning a record number. New
readers would retain both recorded ID and provenance origin, refuse a local
image/debug mismatch, and permit an explicitly supplied matching full image
when the original path is unavailable. Never derive a historic ID from today's
file silently. A new embedded-symbol schema would bind snapshots to recorded
image instances/IDs; legacy name-only snapshots remain labelled legacy.

Required future gates: loaded-vs-replaced-on-disk image identity, separate
debug files and mismatches, missing IDs, dlopen/unload/reuse ordering, truncated
records, old/new-reader compatibility, cross-platform trace reading and
libc-only agent dependencies. No trace-format/agent implementation is included.
