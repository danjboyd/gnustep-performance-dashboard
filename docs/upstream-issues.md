# Upstream issues found while building Performance Dashboard

Leads found while building and using Performance Dashboard. None has been
reported. Anything sent upstream follows `upstream-policy.md`: a draft
and reproducer under `upstream-issues/`, re-checked on current master,
reviewed and signed off by Dan (`upstream-signoff.md`), then sent only when
he asks. The notes below are from earlier sessions and are not yet
verified to that standard. Each has a workaround here.

## libobjc2: `objc_getClassList` double-frees its enumerator

**Status:** filed as
[gnustep/libobjc2#433](https://github.com/gnustep/libobjc2/issues/433)
on 2026-10-16 (draft:
`upstream-issues/1-libobjc2-getclasslist-double-free.md`). A bug report
only; libobjc2 accepts no AI-generated code, so the report describes the
bug in prose and the maintainer writes the fix (`upstream-policy.md`).

`objc_getClassList(buffer, n)` with `n` larger than the number of registered
classes walks off the end of the class table; `class_table_internal_next`
frees the enumerator and `objc_getClassList` frees it again
(`class_table.c`), aborting with "free(): double free detected in tcache 2".
Only callers that over-allocate the buffer hit it (Apple's documentation
encourages that pattern).

Workaround: `Runtime/gsp_objc.c` asks for exactly the count returned by
`objc_getClassList(NULL, 0)`.

## libs-gui: `-[NSOutlineView frameOfOutlineCellAtRow:]` ignores the outline column

**Status:** drafted, not reviewed:
`upstream-issues/2-libs-gui-outline-cell-frame-column-0.md`. Reproduced on
0.32.0 and master: the triangle is drawn in column 0, while clicks are
detected in the outline column (not "in the wrong column" as noted below).

It always uses column 0 (`frameOfCellAtColumn: 0`), so when the outline
column is not the first column the disclosure triangles are drawn — and
clicks are detected — in the wrong column.

Workaround: the call tree puts Symbol Name first.

## libs-gui: `+[NSBitmapImageRep _bitmapIsJPEG:]` leaks 72 bytes per non-JPEG image

**Status:** drafted, not reviewed:
`upstream-issues/3-libs-gui-jpeg-probe-leak.md`. Reproduced on 0.32.0 and
master with TIFF data. PNG data doesn't leak: it is detected before the
JPEG probe runs. The cause below was confirmed by disassembly.

Found with the Leaks template on Gorm (185 leaks) and reproduced with a
ten-line program that calls `+imageRepsWithData:` on a TIFF ten times: all
ten 72-byte blocks allocated by `gs_jpeg_memory_src_create`
(`sizeof(gs_jpeg_source_mgr)`) stay live. On non-JPEG data
`jpeg_read_header` longjmps back to the `setjmp` branch, which should free
`cinfo.src`. `cinfo` is a non-volatile local modified after `setjmp`, so
its value there is indeterminate; at -O2 the compiler can use the value it
had at `setjmp` time (NULL from the memset) and `free(NULL)`. Likely fix:
declare `cinfo` (and `jerrMgr`) `volatile`, or keep the source manager
pointer in a volatile local and free that. Same pattern in
`-_initBitmapFromJPEG:errorMessage:`.

## (Retracted) libs-back font strings

About 1,900 `GSCInlineString`s from `FCFontEnumerator` were reported as
leaked in every GUI app. They were reachable: `GSInlineArray` stores its
objects at a 4-byte-aligned offset, which the scanner skipped. Fixed in the
scanner (heap blocks are scanned at a 4-byte stride); nothing to report.
