# Upstream sign-off

Dan's record that he has reviewed an item and that exact version may be
sent upstream (`docs/upstream-policy.md`, stage 2).

A line is added by Dan, or by Claude recording an approval Dan gave in the
chat: explicit, naming the item, given after Claude presented that item's
review document and hash, quoted in Notes. Claude adds nothing else here,
and reads this table before sending anything: nothing is sent whose hash
isn't in it.

- A patch: the commit's hash (`git rev-parse` in the series worktree).
- An issue: `git hash-object` of the draft and of its reproducer.

Any change to an item after its line was added voids the line.

| Date | Item | Hash(es) reviewed | Notes | Sent |
|---|---|---|---|---|
| 2026-10-16 | libobjc2 issue 1: objc_getClassList() double-frees its enumerator when the buffer is larger than the class count | e2e420d99e08ad43c988dde7f928f84a90278894 (`docs/upstream-issues/1-libobjc2-getclasslist-double-free.md`) | Approved in chat: "I approve libobjc2 issue 1 at e2e420d", after the draft and its hash were presented. Covers the report only; the reproducer `getclasslist_overallocate.c` (38ca91d) is not part of this approval and is not sent | |
