#!/usr/bin/env python3
"""Writes the packaging manifest for a prerelease (0.1.0-rc1): the
"prerelease" update channel and feeds instead of "stable".

  scripts/prerelease-manifest.py IN OUT

Every build packages the manifest's updates.channel and each backend's
feedUrl into the app's updater configuration, and the updater reads only
those, so a release candidate built from the stable values would check
stable.json and never see the next candidate; it also skips a feed whose
"channel" differs from its own. The AppImage's zsync update information
uses GitHub's "latest" release, which skips prereleases; "latest-all"
takes the newest release or prerelease. As ScreenshotTool does
(scripts/use_prerelease_update_channel.ps1 there).
"""
import json
import sys
from collections import OrderedDict


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    with open(argv[1], encoding="utf-8") as f:
        manifest = json.load(f, object_pairs_hook=OrderedDict)
    manifest["updates"]["channel"] = "prerelease"
    for backend in ("msi", "appimage"):
        updates = manifest["backends"][backend]["updates"]
        url = updates["feedUrl"]
        if not url.endswith("/stable.json"):
            sys.exit("backends.%s.updates.feedUrl doesn't end in /stable.json: %s" % (backend, url))
        updates["feedUrl"] = url[: -len("stable.json")] + "prerelease.json"
    manifest["backends"]["appimage"]["updates"]["releaseSelector"] = "latest-all"
    with open(argv[2], "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv)
