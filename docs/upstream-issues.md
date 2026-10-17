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

**Status:** filed as
[gnustep/libs-gui#1009](https://github.com/gnustep/libs-gui/issues/1009)
on 2026-10-16 (draft:
`upstream-issues/2-libs-gui-outline-cell-frame-column-0.md`). Reproduced on
0.32.0 and master: the triangle is drawn in column 0, while clicks are
detected in the outline column (not "in the wrong column" as noted below).

It always uses column 0 (`frameOfCellAtColumn: 0`), so when the outline
column is not the first column the disclosure triangles are drawn — and
clicks are detected — in the wrong column.

Workaround: the call tree puts Symbol Name first.

## libs-gui: `+[NSBitmapImageRep _bitmapIsJPEG:]` leaks 72 bytes per non-JPEG image

**Status:** filed as
[gnustep/libs-gui#1010](https://github.com/gnustep/libs-gui/issues/1010)
on 2026-10-16 (draft: `upstream-issues/3-libs-gui-jpeg-probe-leak.md`). Reproduced on 0.32.0 and
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

## libs-gui: `-state` declared both `NSInteger` and `NSControlStateValue` (`NSUInteger`)

**Status:** drafted and re-checked on master fdc5cfe83 and 0.32.0
(2026-10-16), waiting for Dan's review:
`upstream-issues/4-libs-gui-state-signature-mismatch.md`. Workaround: `PDIsOn` asks the cell through an `NSCell *`.

## Lead: libs-base's pool list breaks when only libobjc2's pool is at the bottom

**Status:** lead, seen 2026-10-17 with the installed libs-base 1.31.1 and
libs-gui 0.32.0; not checked on master, where `NSAutoreleasePool.m` has
changed a lot since. Reproducer (not a draft):
`upstream-issues/modal_table_pool.m`, which passes the GCC check and
crashed 3 runs out of 3 under the default theme.

A program whose outermost pool is libobjc2's (`@autoreleasepool`, or
`objc_autoreleasePoolPush()`, so no `NSAutoreleasePool` object at the
bottom) runs a modal panel holding an `NSTableView` from a button's
action. Under the default theme and Sombre, once the modal session ends,
`-[NSNotificationCenter _postAndRelease:]` releases its pool and
`-dealloc` → `-emptyPool` → `-_emptyChild` → `-dealloc` recurses on the
same pool until the stack overflows (gdb against an unstripped build of
our libs-base checkout). With an `NSAutoreleasePool` at the bottom
instead, it doesn't crash. A guess, not checked: `-init` takes over its
parent's existing child (`_child = _parent->_child`), so a child left on
the list with a `_parent` that skips the new pool makes `-_emptyChild`'s
walk back up reach the new pool's parent and dealloc the new pool again.
Performance Dashboard's template chooser crashed this way with no user
defaults (Adwaita in the defaults hid it).

Workaround: `Dashboard/main.m` is built without ARC and keeps an
`NSAutoreleasePool` at the bottom.

## Lead: quitting under the Sombre theme recurses until the stack overflows

**Status:** lead, not reproduced outside Performance Dashboard; probably
the pool-list lead above (same recursion, and the app had only libobjc2's
pool at the bottom until 2026-10-17). With libs-gui
0.32.0 and Sombre, `-[NSApplication replyToApplicationShouldTerminate:]`
closes every window (`makeObjectsPerformSelector: @selector(close)`), and
`-[NSWindow close]` ↔ `-[NSAutoreleasePool emptyPool]` recursed through 19
`GSCacheW` image-cache windows until the stack overflowed (seen in gdb on
2026-10-16). A small program with a table, scroll bars and a pop-up button
under Sombre (9 windows, cache windows included) quits cleanly, so the
trigger may be in how this app's windows and controllers are torn down.
Workaround: the app exits from `-applicationWillTerminate:`.

## Lead: libs-back's SIGTERM handler calls `-[NSApp terminate:]`

**Status:** lead, no harm observed of its own. `Source/x11/XGServer.m`
installs `signal(SIGTERM, terminate)`, and `terminate()` sends
`-terminate:` from the signal handler, which is not async-signal-safe. The
crashes seen on SIGTERM were the Sombre teardown above, which happens on a
menu Quit too. Workaround: the app installs a handler that only writes to a
pipe.

## Lead: libs-back labels a UTF-8 window title as STRING when Xlib can't convert it

**Status:** lead, seen 2026-10-16, not drafted. `-[XGServer titlewindow::]`
(`Source/x11/XGServerWindow.m`, same on master 36ac709 and 0.32.0) asks
`Xutf8TextListToTextProperty` for a UTF8_STRING `WM_NAME`; when that fails
(here: the app run with no locale in the environment), it falls back to
`XStringListToTextProperty` with `-lossyCString`, which on these systems is
still UTF-8, typed STRING (Latin-1 by ICCCM). `xprop` then shows
`WM_NAME(STRING) = "objcwork \342\200\224 Custom"`, and anything reading
`WM_NAME` sees mojibake for non-ASCII titles. `_NET_WM_NAME` is right.
Workaround: none needed in the app; the test suite matches titles loosely.

## Lead: the Adwaita theme's segmented control may leak like libs-gui 0.32.0's

**Status:** lead for the Adwaita theme (danjboyd/plugins-themes-Adwaita),
not upstream GNUstep. Recording ScreenshotTool under the installed Adwaita
build, half of the segmented-control leaks (`NSMutableParagraphStyle`,
`GSDictionary`, ...) have `-[NSCell _nonAutoreleasedTypingAttributes]`
called straight from `-[GnomeTheme _overrideNSSegmentedCellMethod_drawSegment:inFrame:withView:]`,
with no libs-gui frame between, so the known-leak entry for libs-gui 0664f51
does not cover them. The theme's current source does not call that method,
so the installed build may be older; to check against a current build.

## (Retracted) libs-back font strings

About 1,900 `GSCInlineString`s from `FCFontEnumerator` were reported as
leaked in every GUI app. They were reachable: `GSInlineArray` stores its
objects at a 4-byte-aligned offset, which the scanner skipped. Fixed in the
scanner (heap blocks are scanned at a 4-byte stride); nothing to report.
