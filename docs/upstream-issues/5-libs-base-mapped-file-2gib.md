**Repository:** gnustep/libs-base

**Status:** draft, not reviewed. Reproducer: `mapped_file_2gib.m` (next to
this file).

**Checked before drafting (2026-10-17):** libs-base issues and pull
requests, open and closed, searched for "dataWithContentsOfMappedFile",
"NSDataMappedFile", "mapping failed", "2147483647", "large file NSData"
and "mmap 2GB". The one hit, #512 (closed 2025-06-21), was a different
bug in the same `mmap()` call (it was passed the wrong variable as the
length), fixed then. The 2147483647 limit dates from 1ab80b3f5 (2016) and
is unchanged on master a767a1623.

**Our workaround meanwhile:** Performance Dashboard maps its trace files
with `mmap()` itself (`GSPTrace`), since its event streams pass 2 GiB.

---

**Title:** +[NSData dataWithContentsOfMappedFile:] can't map a file of 2 GiB or more and reads it all into memory instead

### Summary

For a file of 2147483647 bytes or more, `-[NSDataMappedFile
initWithContentsOfFile:options:error:]` logs

```
mapping failed for <path> - Error Domain=NSPOSIXErrorDomain Code=22 "Invalid argument"
```

and the caller gets an `NSDataMalloc` that holds a copy of the whole file.
A program that maps a large file to avoid reading it then needs as much
memory as the file is big.

`getContentsOfFile()` (`Source/NSData.m`, line 405 on master a767a1623)
sets the length it reports to 0 when `ftello()` returns 2147483647 or
more. The mapped-file initializer passes that length to `mmap()` (line
4076), and `mmap()` with a length of 0 fails with EINVAL. The read path
that follows copes with the 0 (it reads until end of file), which is why
the result is a complete `NSDataMalloc` and not an error.

### Steps to reproduce

The attached `mapped_file_2gib.m` creates a sparse file of 2147483646
bytes and one of 2147483648 bytes in `/tmp`, maps each with
`+dataWithContentsOfMappedFile:`, prints the class and length it gets
back, and deletes them:

```
mapping failed for /tmp/mapped_file_2gibMvGsTL - Error Domain=NSPOSIXErrorDomain Code=22 "Invalid argument"
2147483646 bytes: NSDataMappedFile, length 2147483646
2147483648 bytes: NSDataMalloc, length 2147483648
```

Its peak resident size was 2.1 GB (`/usr/bin/time`), the size of the
second file.

### Expected

An `NSDataMappedFile` for the larger file too, with no copy: on a 64-bit
system `off_t` and `size_t` hold the length, and `mmap()` accepts it.

### Versions

Reproduced with the program above on Debian 13 x86_64, built with clang
19.1.7 against libobjc2, with libs-base 1.31.1 (as installed) and with
master a767a1623 built from source (checked with `ldd` that master's
library was the one loaded). Same output and the same peak size on both.

Investigated, reproduced and written up with AI assistance (Claude).
