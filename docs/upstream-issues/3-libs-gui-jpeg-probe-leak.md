**Repository:** gnustep/libs-gui

**Filed:** [gnustep/libs-gui#1010](https://github.com/gnustep/libs-gui/issues/1010), 2026-10-16, as approved (the text below the line, with the reproducer pasted in a collapsed section).

**Status:** sent. Reproducer: `jpeg_probe_leak.m` (next to
this file).

**Checked before drafting (2026-10-16):** libs-gui issues and pull
requests, open and closed, searched for "_bitmapIsJPEG", "jpeg leak",
"gs_jpeg_memory_src" and "NSBitmapImageRep leak": no hits. master's log for
`Source/NSBitmapImageRep+JPEG.m` (b52c3c9c0, 24efad839, ...) has no change
to `+_bitmapIsJPEG:`.

**Corrects our earlier notes:** PNG data does not leak. It is checked
before the JPEG probe, so it never reaches it. Our guess about the cause
is now confirmed by disassembly (see Cause).

**Our workaround meanwhile:** none in Performance Dashboard. The leak is
in the programs being profiled. Proposed: label these as a known libs-gui
leak in the Leaks instrument.

---

**Title:** +[NSBitmapImageRep _bitmapIsJPEG:] leaks its source manager when the data isn't a JPEG (TIFF, at -O2)

### Summary

Each time `+imageRepsWithData:` is given TIFF data, 72 bytes are leaked:
the `gs_jpeg_source_mgr` that `+_bitmapIsJPEG:` allocates before it
finds out that the data isn't a JPEG. Applications that load many TIFF
images build up leaks, and leak checkers report them against the
application.

### Steps to reproduce

The attached `jpeg_probe_leak.m` makes a 4×4 bitmap, takes its
`-TIFFRepresentation` and PNG representation, and calls
`+[NSBitmapImageRep imageRepsWithData:]` 1000 times on each, measuring heap
growth with glibc's `mallinfo2()`. Given a JPEG file as its argument, it
does the same for that file as a control:

```
1000 calls each; heap growth (mallinfo2 uordblks):
  TIFF   80000 bytes (80.0 per call)
  PNG        0 bytes (0.0 per call)
  JPEG       0 bytes (0.0 per call)
```

(80 bytes per call is one 72-byte block plus malloc's overhead.) A leak
checker run on the same program finds 1010 leaked blocks of 72 bytes, all
allocated in `+[NSBitmapImageRep _bitmapIsJPEG:]` called from
`+imageRepsWithData:` (the 1000 calls plus 10 warm-up calls).

### Expected

No heap growth for TIFF data.

### Cause

`+imageRepsWithData:` tries the formats in order: PNG
(Source/NSBitmapImageRep.m, line 182 on master fdc5cfe83), then JPEG
(line 209), then the others, with TIFF last (line 242). So TIFF data goes
through `+_bitmapIsJPEG:` (Source/NSBitmapImageRep+JPEG.m, line 389):

```objc
  memset((void*)&cinfo, 0, sizeof(struct jpeg_decompress_struct));
  ...
  if (setjmp(jerrMgr.setjmpBuffer))
    {
      gs_jpeg_memory_src_destroy(&cinfo);
      jpeg_destroy_decompress(&cinfo);
      return NO;
    }
  jpeg_create_decompress(&cinfo);
  gs_jpeg_memory_src_create(&cinfo, imageData);
  jpeg_read_header(&cinfo, TRUE);
```

`gs_jpeg_memory_src_create()` mallocs `cinfo.src` after the `setjmp`. On
non-JPEG data, `jpeg_read_header()` calls `gs_jpeg_error_exit()`, which
longjmps back. `cinfo` is a non-volatile local that was changed between
`setjmp` and `longjmp`, so C leaves its value after the `longjmp`
indeterminate. Its address isn't passed anywhere before the `setjmp`, so
the compiler can assume `cinfo.src` is still NULL from the `memset` on the
`setjmp` path, and `free(NULL)` does nothing.

That is what clang 19.1.7 does at -O2 with master fdc5cfe83. The compiled
`+_bitmapIsJPEG:` has one call to `free`, on the success path after
`jpeg_read_header`. The `setjmp` path jumps past it straight to
`jpeg_destroy_decompress`, so the source manager is never freed.

`-_initBitmapFromJPEG:errorMessage:` in the same file uses the same
`setjmp` pattern. We haven't checked whether it leaks.

### Versions

Reproduced with the program above on Debian 13 x86_64 (glibc 2.41,
libjpeg62-turbo), against libs-gui 0.32.0 (as installed) and against master
fdc5cfe83 built from source with clang 19.1.7 at -O2. Same output on both.

Investigated, reproduced and written up with AI assistance (Claude).
