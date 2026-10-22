#!/bin/sh
# Actual delegate success/error/cancel/exception boundaries, private display.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT="$ROOT/Tests/out/open-trace"
mkdir -p "$OUT" "$OUT/tmp"
chmod 700 "$OUT/tmp"
export TMP="$OUT/tmp" DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
clang $(gnustep-config --objc-flags) -fobjc-arc -Wno-protocol \
  -Wno-deprecated-declarations -DPD_ENABLE_SIGNPOSTS=1 -I. -IRuntime/include \
  -Ithird_party/gnustep-packager-updater/objc/GPUpdaterCore/Headers \
  -Ithird_party/gnustep-packager-updater/objc/GPUpdaterUI/Headers \
  Tests/GUI/OpenTraceChecks.m Dashboard/PD*.m \
  -LGSPerformance/obj -lGSPerformance \
  -Lthird_party/gnustep-packager-updater/objc/GPUpdaterUI -lGPUpdaterUI \
  -Lthird_party/gnustep-packager-updater/objc/GPUpdaterCore -lGPUpdaterCore \
  $(gnustep-config --gui-libs) -Wl,-rpath,"$ROOT/GSPerformance/obj" -o "$OUT/checks"
display_file=$(mktemp)
Xvfb -displayfd 3 -screen 0 1280x900x24 -nolisten tcp -ac 3>"$display_file" >"$OUT/xvfb.log" 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null || :; rm -f "$display_file"' EXIT HUP INT TERM
n=0
while [ ! -s "$display_file" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
[ -s "$display_file" ] || { echo 'Private Xvfb failed to start'; exit 1; }
export DISPLAY=:$(cat "$display_file") XAUTHORITY=
for theme in Adwaita Sombre; do
  mkdir -p "$OUT/defaults-$theme"
  config=$(gnustep-config --variable=GNUSTEP_CONFIG_FILE)
  { [ ! -f "$config" ] || sed '/^GNUSTEP_USER_CONFIG_FILE=/d; /^GNUSTEP_USER_DEFAULTS_DIR=/d' "$config"
    echo 'GNUSTEP_USER_CONFIG_FILE='
    echo "GNUSTEP_USER_DEFAULTS_DIR=$OUT/defaults-$theme"
  } >"$OUT/config-$theme"
  chmod 600 "$OUT/config-$theme"
  env GNUSTEP_CONFIG_FILE="$OUT/config-$theme" PD_OPEN_TRACE_SAMPLE="$ROOT/Tests/data/sample.gstrace" \
    "$OUT/checks" -GSTheme "$theme" >"$OUT/$theme.log" 2>&1 || { cat "$OUT/$theme.log"; exit 1; }
  tail -1 "$OUT/$theme.log"
done
