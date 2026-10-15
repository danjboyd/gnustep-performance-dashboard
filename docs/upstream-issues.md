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

## libs-back (to verify): strings from `FCFontEnumerator` reported as leaked

Recording any GNUstep GUI app with the Leaks template reports about 1,900
`GSCInlineString` objects (≈ 93 KiB) created by
`-[FCFontEnumerator enumerateFontsAndFamilies]` via
`+[NSString stringWithUTF8String:]`. They may be a real leak in the font
enumeration, or referenced through a structure the conservative scanner
cannot follow; this needs a closer look before reporting.
