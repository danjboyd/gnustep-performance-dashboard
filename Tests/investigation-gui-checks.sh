#!/bin/sh
# Source GNUstep.sh first. Uses only a newly allocated private Xvfb display.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT="$ROOT/Tests/out/investigations"
mkdir -p "$OUT"
clang $(gnustep-config --objc-flags) -fobjc-arc -Wno-protocol -I. -IRuntime/include \
  Tests/GUI/InvestigationChecks.m Tests/Unit/TraceBuilder.m \
  Dashboard/PDInvestigationWindowController.m Dashboard/PDInspectorView.m \
  Dashboard/PDSourceWindowController.m Dashboard/PDTheme.m \
  Dashboard/PDDetailController.m Dashboard/PDTrackRenderer.m Dashboard/PDTimelineView.m \
  -LGSPerformance/obj -lGSPerformance $(gnustep-config --gui-libs) \
  -Wl,-rpath,"$ROOT/GSPerformance/obj" -o "$OUT/checks"
display_file=$(mktemp)
Xvfb -displayfd 3 -screen 0 1280x900x24 -nolisten tcp -ac 3>"$display_file" >"$OUT/xvfb.log" 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null || :; rm -f "$display_file"' EXIT HUP INT TERM
n=0
while [ ! -s "$display_file" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
[ -s "$display_file" ] || { echo 'Private Xvfb failed to start'; exit 1; }
export DISPLAY=:$(cat "$display_file")
export XAUTHORITY=
for theme in Adwaita Sombre; do
  found=0
  for domain in USER LOCAL SYSTEM; do
    library=$(gnustep-config --variable="GNUSTEP_${domain}_LIBRARY")
    [ ! -d "$library/Themes/$theme.theme" ] || found=1
  done
  [ "$found" = 1 ] || { echo "Missing theme: $theme"; exit 1; }
  mkdir -p "$OUT/$theme" "$OUT/defaults-$theme"
  config=$(gnustep-config --variable=GNUSTEP_CONFIG_FILE)
  { [ ! -f "$config" ] || sed '/^GNUSTEP_USER_CONFIG_FILE=/d; /^GNUSTEP_USER_DEFAULTS_DIR=/d' "$config"
    echo 'GNUSTEP_USER_CONFIG_FILE='
    echo "GNUSTEP_USER_DEFAULTS_DIR=$OUT/defaults-$theme"
  } >"$OUT/config-$theme"
  chmod 600 "$OUT/config-$theme"
  env GNUSTEP_CONFIG_FILE="$OUT/config-$theme" PD_GUI_OUTPUT="$OUT/$theme" \
    "$OUT/checks" -GSTheme "$theme" >"$OUT/$theme.log" 2>&1 || { cat "$OUT/$theme.log"; exit 1; }
  tail -1 "$OUT/$theme.log"
done
