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

## Mailbox coordination authorized on 2026-10-19

Dan explicitly authorized dispatch of the two prompts already presented in
full in chat: "you should be able to access the gnustep-cli-new and
gnustep-packager agents via the mailbox.agents messaging system. Confirm you
can and, if so, dispatch those prompts"

The exact chat prompts are preserved below; hashes were recorded at dispatch.
This records the direct instruction to send the shown text, not prior review
of these newly recorded hashes. These are information requests only, with no
authorization to publish or change another repository.

- gnustep-packager: `docs/release-handoffs/packager-mailbox.txt`,
  `40ab4c5c871cb4855469946bb6d1d28fa75437a5`.
- gnustep-cli-new: `docs/release-handoffs/toolchain-mailbox.txt`,
  `ae84126c404fdb57d21d6bcefaf65f1949ddfa7c`.

Sent through the mailbox as `performance-dashboard` on 2026-10-19:
conversation `performance-dashboard-v0.1.0-linux`, message 1 to
`gnustep-packager`, message 2 to `gnustep-cli-new`. Both sends succeeded;
recipient acknowledgement was pending at dispatch.

| Date | Item | Hash(es) reviewed | Notes | Sent |
|---|---|---|---|---|
| 2026-10-16 | libobjc2 issue 1: objc_getClassList() double-frees its enumerator when the buffer is larger than the class count | e2e420d99e08ad43c988dde7f928f84a90278894 (`docs/upstream-issues/1-libobjc2-getclasslist-double-free.md`) | Approved in chat: "I approve libobjc2 issue 1 at e2e420d", after the draft and its hash were presented. Covers the report only; the reproducer `getclasslist_overallocate.c` (38ca91d) is not part of this approval and is not sent | |
| 2026-10-16 | libs-gui issue 2: NSOutlineView -frameOfOutlineCellAtRow: always uses column 0 | 41447de952d8cb03ac70a2dff70bdcab18dfd16d (`docs/upstream-issues/2-libs-gui-outline-cell-frame-column-0.md`), 1830fe69e77370ea9867394bee373bd951488341 (`outline_column_frame.m`) | Approved in chat: "I approve libs-gui issue 2 at 41447de/1830fe6 and libs-gui issue 3 at a26b495/633afeb", after the drafts and these hashes were presented. The screenshot `outline_column_frame.png` is not covered | |
| 2026-10-16 | libs-gui issue 3: +[NSBitmapImageRep _bitmapIsJPEG:] leaks its source manager when the data isn't a JPEG | a26b495d68c0b731c9143db90c27962428791c57 (`docs/upstream-issues/3-libs-gui-jpeg-probe-leak.md`), 633afeb4949db72520033d06d49b66e5f72b30d9 (`jpeg_probe_leak.m`) | Approved in chat: "I approve libs-gui issue 2 at 41447de/1830fe6 and libs-gui issue 3 at a26b495/633afeb", after the drafts and these hashes were presented | |
