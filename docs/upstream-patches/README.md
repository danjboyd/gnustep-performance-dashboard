# Upstream patch sends

## Report #9: NSTextStorage attribute cache

**Filed:** [libs-gui PR #1023](https://github.com/gnustep/libs-gui/pull/1023)
on 2026-11-05 under Dan's exact in-chat approval #3305.

- Pushed commit: `15fb673df53a1349ff91369b82c798646eb8c038`.
- Fork head: `danjboyd:gstextstorage-attribute-cache`, created without force.
- Base: `gnustep/libs-gui:master`, verified at
  `1dd8b76c6bc40f65fdf654fa040847e8bf7d762a`.
- Exact title: Distribute NSTextStorage attribute-cache entries by contents without temporary enumerators
- Approved file and posted body SHA-256:
  `a1cabce40ccaeef609fdd4c517c06ea93f01d10cc03626c66ed07a1547f801c9`.

The GCC syntax check passed for `Source/GSTextStorage.m` and
`Tests/gui/NSTextStorage/attributeCache.m` immediately before sending, with
the planted literal/block canary rejected. The open PR's head, base, title
and body were verified through GitHub's API. The lead received the PR URL
and full pushed SHA in message #8649 and owns report #9's posted record.
