#!/bin/bash
# Build the native welcome controller probe in an isolated GNUstep environment.
# Source GNUstep.sh first, set TRELLIS_ROOT, then use with-private-home.py:
#   python3 scripts/with-private-home.py UNUSED_HOME -- \
#     bash Tests/build-welcome-probe.sh UNUSED_OUTPUT/WelcomeProbe.app
# Run the resulting executable through Trellis's scripts/run-headless.sh:
#   WelcomeProbe.app/WelcomeProbe /path/to/Adwaita.theme screenshot.png
# The probe intentionally requires private display :151. Repeat with Sombre.
set -eo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
python3 "$repo/scripts/with-private-home.py" --check || {
  echo 'build-welcome-probe: run through scripts/with-private-home.py' >&2
  exit 2
}
: "${TRELLIS_ROOT:?Set TRELLIS_ROOT to the reviewed Trellis checkout}"
test "$#" = 1 || { echo 'usage: build-welcome-probe.sh UNUSED_OUTPUT/WelcomeProbe.app' >&2; exit 2; }
app=$1
test ! -e "$app" || { echo 'build-welcome-probe: output already exists' >&2; exit 2; }
mkdir -p "$app/Resources"
cp "$repo/Dashboard/Resources/WelcomeWindow.trellis" "$app/Resources/"
cat > "$app/Resources/Info-gnustep.plist" <<'INFO'
{ NSExecutable = WelcomeProbe; NSPrincipalClass = NSApplication; }
INFO
clang $(gnustep-config --objc-flags) -fobjc-arc -fblocks -Wno-deprecated-declarations \
  -I"$repo" -I"$repo/Runtime/include" \
  -I"$TRELLIS_ROOT/Source/Engine" -I"$TRELLIS_ROOT/Source/View" \
  "$repo/Tests/welcome-window-probe.m" "$repo/Dashboard/PDWelcomeModel.m" \
  "$repo/Dashboard/PDWelcomeWindowController.m" "$repo/Dashboard/PDRecordPanel.m" \
  "$repo/Dashboard/PDTheme.m" -L"$repo/GSPerformance/obj" -lGSPerformance \
  -L"$TRELLIS_ROOT/obj" -lTrellis -lTrellisEngine \
  $(gnustep-config --gui-libs) -o "$app/WelcomeProbe"
