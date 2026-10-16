# Upstream issues found while building GNUstep Instruments

None of these have been reported yet — they need Dan's go-ahead (public
issues on other projects). Each has a workaround here.

## libobjc2: `objc_getClassList` double-frees its enumerator

`objc_getClassList(buffer, n)` with `n` larger than the number of registered
classes walks off the end of the class table; `class_table_internal_next`
frees the enumerator and `objc_getClassList` frees it again
(`class_table.c`), aborting with "free(): double free detected in tcache 2".
Only callers that over-allocate the buffer hit it (Apple's documentation
encourages that pattern).

Workaround: `Runtime/gsp_objc.c` asks for exactly the count returned by
`objc_getClassList(NULL, 0)`.

## libs-gui: `-[NSOutlineView frameOfOutlineCellAtRow:]` ignores the outline column

It always uses column 0 (`frameOfCellAtColumn: 0`), so when the outline
column is not the first column the disclosure triangles are drawn — and
clicks are detected — in the wrong column.

Workaround: the call tree puts Symbol Name first.

## (Retracted) libs-back font strings

About 1,900 `GSCInlineString`s from `FCFontEnumerator` were reported as
leaked in every GUI app. They were reachable: `GSInlineArray` stores its
objects at a 4-byte-aligned offset, which the scanner skipped. Fixed in the
scanner (heap blocks are scanned at a 4-byte stride); nothing to report.
