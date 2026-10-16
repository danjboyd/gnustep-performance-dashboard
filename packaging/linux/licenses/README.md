# Runtime license texts

The license files of the GNUstep runtime Performance Dashboard's Linux AppImage bundles, copied
from upstream so `scripts/package-stage.sh` can write the AppImage's notices
without local checkouts of those projects (the gnustep-cli-new install does
not carry them).

| File | Upstream |
| --- | --- |
| `libs-base-COPYING.LIB` | gnustep/libs-base `COPYING.LIB` (last changed in `4b33151`) |
| `libs-gui-COPYING.LIB` | gnustep/libs-gui `COPYING.LIB` (`7afdd32`) |
| `libs-back-COPYING.LIB` | gnustep/libs-back `COPYING.LIB` (`250ebdf`; the same at the pinned `bf3b3ce`) |
| `libobjc2-COPYING` | gnustep/libobjc2 `COPYING` (`07758fe`) |
| `libdispatch-LICENSE` | swiftlang/swift-corelibs-libdispatch `LICENSE` (`9ccd785`) |
| `GPL-3.0.txt` | the GNU GPL version 3, for the GNUstep tools (`defaults`, `gpbs`, `gdnc`, `make_services`) |
