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
app_pid=
trap '[ -z "$app_pid" ] || kill "$app_pid" 2>/dev/null || :; kill "$xpid" 2>/dev/null || :; rm -f "$display_file"' EXIT HUP INT TERM
n=0
while [ ! -s "$display_file" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
[ -s "$display_file" ] || { echo 'Private Xvfb failed to start'; exit 1; }
export DISPLAY=:$(cat "$display_file")
export XAUTHORITY=
window_id() {
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    id=$(xdotool search --onlyvisible --name "$1" 2>/dev/null | head -1)
    if [ -n "$id" ]; then echo "$id"; return 0; fi
    sleep .2; attempt=$((attempt + 1))
  done
  return 1
}
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
  env GNUSTEP_CONFIG_FILE="$OUT/config-$theme" \
    "$ROOT/Dashboard/PerformanceDashboard.app/PerformanceDashboard" \
    -GSFirstCommandKey Control_L -GSSecondCommandKey Control_R \
    -GSFirstControlKey Alt_L -GSSecondControlKey Alt_R \
    -GSFirstAlternateKey Super_L -GSSecondAlternateKey Super_R \
    -GSFilePath "$ROOT/Tests/data/sample.gstrace" -GSTheme "$theme" >"$OUT/menu-$theme.log" 2>&1 &
  app_pid=$!
  main=$(window_id 'objcwork.*Custom')
  xdotool windowfocus --sync "$main" key ctrl+g
  window_id '^Allocation Generations$' >/dev/null
  sleep .5
  import -window root "$OUT/$theme/generations-menu.png"
  # With no window manager, focusing X alone does not change AppKit's key
  # window after opening an auxiliary panel. Activate the trace by clicking.
  xdotool windowraise "$main" mousemove --window "$main" 500 70 click 1
  xdotool windowfocus --sync "$main" key ctrl+d
  window_id '^Compare Recordings$' >/dev/null
  sleep .5
  import -window root "$OUT/$theme/comparison-menu.png"
  kill -TERM "$app_pid"
  wait "$app_pid"
  app_pid=
  echo "All 2 Analysis menu checks passed ($theme)."
done
