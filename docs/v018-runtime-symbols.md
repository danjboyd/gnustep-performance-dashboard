# Build-ID matched local runtime symbols

Legacy trace image records contain an absolute path, ELF load bias and
executable mapping range. Stack addresses and Objective-C method names are
recorded; display snapshots may be embedded by `symbolicate --embed`. Those
legacy records do not contain a module build ID, original file digest,
debuglink CRC or a copy of runtime/debug files. A historic path alone cannot
prove that the image still names the bytes loaded when recording.

The reader parses ELF symbol tables, build IDs and debuglink names. It already
looks in standard debug locations, but previously selected richer debug tables
without verifying their build ID. This can silently attach symbols from the
wrong build. Require equal image/candidate IDs before using separate symbol tables when
the image has an ID. An ID-less image may instead use a .gnu_debuglink candidate
only after its GNU CRC32 matches.
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
are unavailable, retain honest module+offset labels. The initial local image/debug matching fix adds no network/debuginfod
dependency. The subsequent local capture extension is documented below. Its
agent/format changes have local validation, but package and cross-platform
qualification remain unrun. Legacy display-name snapshots are not retroactive
ID evidence and cannot override a recorded ID.

Validation must cover a correct candidate resolving a private function, a
different-ID richer candidates refusing, missing IDs without CRC refusing,
CRC-matched ID-less debuglink, root layout and
existing fallback behavior. Re-analyze the retained Arlen trace without
embedding or overwriting it, report exact before/after unresolved denominators,
and distinguish absent matching local symbols from a resolution failure.

CLI already supports range/focus/prune/hide-system/symbol-summary. Improve
examples and interpretation without changing defaults, filter semantics or
claiming these options are new. GUI changes are deferred to avoid unrelated
visual qualification in this local symbol work.

## Earlier lifetime-aware proposal (remaining design work)

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

Remaining qualification gates include: loaded-vs-replaced-on-disk image identity, separate
debug files and mismatches, missing IDs, dlopen/unload/reuse ordering, truncated
records, old/new-reader compatibility, cross-platform trace reading and
libc-only agent dependencies. Some gates now have local coverage below; a
full lifetime-aware format and package qualification are still deferred.

## Local implementation after goal674 scope approval

The lead superseded the earlier design-only boundary for this new goal. The
implementation uses a flagged suffix inside each existing IMAGE record instead
of a separately paired record: header/path remain unchanged, old readers ignore
trailing bytes, and new readers parse the bounded ID extension. See the exact
layout in trace-format.md. This avoids ambiguous pairing between IMAGE and a
separate identity record. Address reuse with conflicting observed identities
is marked ambiguous; the reader does not infer sample lifetimes.

Recorded IDs take precedence over the current path. A replaced/missing image
can resolve only via an explicitly supplied matching symbol/full-image file.
Malformed IDs and ambiguous mappings refuse attribution. Version2 embedded
snapshots bind names to the image record identities; flat legacy snapshots
cannot override a recorded ID. Existing traces and legacy snapshots remain
readable. The broader lifetime-aware mapping design above remains future work.

The reader caches addr2line file-ID verification by path, device/inode, size,
mtime and ctime (including nanoseconds where available), invalidating on file
replacement or change. Configured debug roots are parsed once per setting.
A fixed 65,536-comparison budget bounds image-overlap work; exhaustion marks
all stream images ambiguous. Loaded-note parsing honors 4/8-byte alignment
and ELF PF_R ranges; PF_R is not a guarantee against later mprotect changes.
Agent image deduplication retains a bounded path fingerprint and length rather
than a 1 KiB path per entry. Full recorded paths are still emitted in IMAGE.
