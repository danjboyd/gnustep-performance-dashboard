**Repository:** gnustep/libs-gui

**Status:** draft, re-checked 2026-10-16 (below), not yet reviewed by Dan.
Reproducer: `button_state_signature.m` (next to this file).

**Re-checked 2026-10-16:** master is still fdc5cfe83 (`git fetch`); the
reproducer, built with clang 19.1.7, prints the two messages below against
the installed 0.32.0 and against master's headers and library
(`Source/obj/libgnustep-gui.so`, confirmed with `ldd`);
`Tests/Scripts/gcc-syntax-check.sh --files button_state_signature.m`
exits 0; the four searches below were run again with `gh search issues
--include-prs` and found only #362 again. The line numbers were checked on
fdc5cfe83.

**Checked before drafting (2026-10-16):** libs-gui issues and pull
requests, open and closed, searched for "NSControlStateValue",
"NSCellStateValue", "incorrect signature" and "state NSUInteger". The one
hit (#362, accessibility) is about something else. The typedef dates from
8785a1307 (2020) and is unchanged on master.

**Our workaround meanwhile:** Performance Dashboard reads check boxes
with `[(NSCell *)[button cell] state]` (`PDIsOn` in `Dashboard/PDTheme.h`).

---

**Title:** -state is declared both NSInteger (NSCell) and NSControlStateValue, which is NSUInteger (NSSwitch): libobjc2 logs a type mismatch for every -[NSButton state]

### Summary

`Headers/AppKit/NSCell.h` declares `-(NSInteger) state`, and
`Headers/AppKit/NSSwitch.h` declares `-(NSControlStateValue) state`. But
`NSControlStateValue` is `NSUInteger` (`NSCell.h`, line 135 on master
fdc5cfe83; `NSCellStateValue` is too, line 124). A `-state` message sent to
a receiver typed `id` can be compiled with either signature. clang picks the
unsigned one, so with libobjc2's typed selectors every such call prints:

```
Calling [NSButtonCell -state] with incorrect signature.  Method has q16@0:8 (q16@0:8), selector has Q16@0:8
```

libs-gui makes one of these calls itself: `-[NSButton state]`
(`Source/NSButton.m`, lines 227–230) returns `[_cell state]`, and `_cell` is an
`id` (`NSControl.h`, line 71). So every application that reads a check box
or radio button's state through `NSButton` logs this once per call. The
value is still right on x86_64, where both types are 64 bits wide, but the
log fills up: Performance Dashboard printed it five times each time it
rebuilt a view with five check boxes.

### Steps to reproduce

The attached `button_state_signature.m` makes an `NSSwitchButton`, sets it
on, and reads its state through the button and through `-cell` (which also
returns `id`):

```
Calling [NSButtonCell -state] with incorrect signature.  Method has q16@0:8 (q16@0:8), selector has Q16@0:8
[button state] = 1
Calling [NSButtonCell -state] with incorrect signature.  Method has q16@0:8 (q16@0:8), selector has Q16@0:8
[[button cell] state] = 1
```

### Expected

No message: one signature for `-state`. Declaring
`NSControlStateValue` (and `NSCellStateValue`) as `NSInteger` would match
`-[NSCell state]` and `NSOnState`/`NSOffState`/`NSMixedState`, which include
-1.

### Versions

Reproduced with the program above on Debian 13 x86_64 under Xvfb, built
with clang 19.1.7, against libs-gui 0.32.0 (as installed, with libobjc2)
and against master fdc5cfe83 built from source. Same output on both.

Investigated, reproduced and written up with AI assistance (Claude).
