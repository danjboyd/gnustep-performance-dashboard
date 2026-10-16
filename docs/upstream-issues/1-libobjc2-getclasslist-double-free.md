**Repository:** gnustep/libobjc2

**Filed:** [gnustep/libobjc2#433](https://github.com/gnustep/libobjc2/issues/433), 2026-10-16, as approved at e2e420d (the text below the line).

**Status:** sent. Under `docs/upstream-policy.md` this report
contains no code of ours. The reproducer `getclasslist_overallocate.c` next
to this file is for our own checks and is not sent unless Dan decides
otherwise.

**Checked before drafting (2026-10-16):** libobjc2 issues and pull requests,
open and closed, searched for "objc_getClassList", "getClassList" and
"double free". There were two hits, #122 (nullability annotations) and #235
(an aarch64 build failure), and neither is this bug. master's log has no
later change to `objc_getClassList`.

---

**Title:** objc_getClassList() double-frees its enumerator when the buffer is larger than the class count

### Summary

Calling `objc_getClassList(buffer, bufferLen)` with a `bufferLen` greater
than the number of registered classes aborts the process with glibc's
"free(): double free detected in tcache 2". A buffer of exactly the class
count works.

libobjc2's header (`objc/runtime.h`) says the function "copies all of the
classes currently registered with the runtime into the buffer", and Apple's
`runtime.h` in objc4 says it fills the buffer "up to either bufferCount or
the total number of registered classes, whichever is less". So a larger
buffer is a normal way to call it. Callers that leave room in case classes
are registered between the two calls, or that reuse a larger buffer, hit
this crash.

### Steps to reproduce

In a plain C program linked with `-lobjc`, without GNUstep base:

1. Call `objc_getClassList(NULL, 0)` to get the class count, n. It was 6
   in this test.
2. Allocate a buffer of n + 10 `Class` entries.
3. Call `objc_getClassList(buffer, n)`. It returns n.
4. Call `objc_getClassList(buffer, n + 10)`. It doesn't return. The process
   prints `free(): double free detected in tcache 2` and aborts with
   SIGABRT (exit status 134).

### Expected

The call in step 4 copies the n classes and returns n.

### Cause

Starting at `class_table.c`, line 508 on master (fab3df2):

```c
	while (count < bufferLen &&
		(next = class_table_internal_next(class_table, &e)))
	{
		buffer[count++] = next;
	}
	free(e);
```

When `bufferLen` is larger than the class count, the loop calls
`class_table_internal_next()` once more after the last class. That call goes
down the end-of-table path of `PREFIX(_next)` in `hash_table.h`, line 481,
which calls `free(*state)` and returns without setting `*state` to NULL. So
`e` still points at the freed enumerator, and the `free(e)` above frees it a
second time.

When `bufferLen` equals the class count, the loop stops on `count <
bufferLen` before reaching the end of the table, so the enumerator is freed
only once. That is how `objc_copyClassList()` calls it, so
`objc_copyClassList()` is not affected.

The `free(e)` came from #310 (771f7c4, "Trivial memory leak fix", November
2024). That fixed the leak in the exact-size case, but made the
larger-buffer case a double free. The commit before it (47d02a8) returns
normally for both calls.

### Versions

Built from source with clang 19.1.7 (CMake, `-DCMAKE_BUILD_TYPE=Release`),
on Debian 13 x86_64 with glibc 2.41. The program was built with gcc 14 and
run against each library through `LD_LIBRARY_PATH`:

| libobjc2 | Result of the `n + 10` call |
|---|---|
| master, fab3df2 | `free(): double free detected in tcache 2`, SIGABRT (exit 134) |
| v2.3, e877e78 | same |
| 47d02a8, the commit before #310 | returns 6, exit 0 |

v2.3 is the only release tag that contains 771f7c4.

Investigated, reproduced and written up with AI assistance (Claude).
