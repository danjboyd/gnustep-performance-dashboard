**Repository:** gnustep/libs-back

**Status:** draft, not reviewed. Reproducer: `wm_name_title.m` (next to
this file).

**Checked before drafting (2026-10-17):** libs-back issues and pull
requests, open and closed, searched for "WM_NAME", "titlewindow",
"window title encoding", "UTF8_STRING", "lossyCString",
"Xutf8TextListToTextProperty" and "XStringListToTextProperty". Hits: #82
(missing decorations on some window managers; its xprop dumps show
WM_NAME, but it is about something else) and #86 (Wayland). The fallback
dates from 684c01e ("Use UTF8 window title for X where possible") and is
unchanged on master 36ac709.

**Not in the report:** the same output with the 0.32.0 build installed
here, which carries local patches; the report cites only master built
from source.

**Our workaround meanwhile:** none needed in Performance Dashboard. Its
test suite matches window titles loosely (any character for the dash).

---

**Title:** -[XGServer titlewindow::] sets WM_NAME as STRING holding UTF-8 bytes when the locale isn't UTF-8

### Summary

`-[XGServer titlewindow::]` (`Source/x11/XGServerWindow.m`, from line
2615 on master 36ac709) asks `Xutf8TextListToTextProperty()` for a
UTF8_STRING `WM_NAME`. When that doesn't succeed, it falls back to
`XStringListToTextProperty()` with `[window_title lossyCString]`, and the
property is typed STRING, which ICCCM defines as Latin-1. With no locale
in the environment, the bytes it stores are UTF-8, so a client that reads
`WM_NAME` and decodes it as the type says gets mojibake for a non-ASCII
title (xprop below; xdotool's title search too). `_NET_WM_NAME` is set
separately and is right.

### Steps to reproduce

The attached `wm_name_title.m` opens a window titled "Café — Test". Run it
under X with no locale variables, then read the properties:

```
env -i PATH="$PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" DISPLAY=:1 ./wm_name_title &
xprop -id <window> WM_NAME _NET_WM_NAME
```

```
WM_NAME(STRING) = "CafÃ© â\302\200\302\224 Test"
_NET_WM_NAME(UTF8_STRING) = "Café — Test"
```

With `LANG=C.UTF-8` added:

```
WM_NAME(UTF8_STRING) = "Café — Test"
_NET_WM_NAME(UTF8_STRING) = "Café — Test"
```

### Expected

A `WM_NAME` that X clients decode to the title: either UTF8_STRING
regardless of the locale (as `_NET_WM_NAME` already is), or, for the
STRING fallback, Latin-1 bytes (characters outside Latin-1 replaced).

### Versions

Reproduced with the program above on Debian 13 x86_64 under Xvfb, built
with clang 19.1.7, with libs-back master 36ac709 built from source (the
running program's memory map showed master's backend bundle) and
libs-gui 0.32.0.

Investigated, reproduced and written up with AI assistance (Claude).
