#!/usr/bin/env bash
set -euo pipefail
# Source GNUstep.sh first. Uses only generated data and isolated preferences.
[ "$#" = 2 ] || { echo "usage: $0 /path/to/ScreenshotTool /path/to/LinDirStat" >&2; exit 2; }
screenshot_app=$(realpath "$1")
lindirstat_app=$(realpath "$2")
[ -x "$screenshot_app" ] && [ -x "$lindirstat_app" ]
root="$(cd "$(dirname "$0")/.." && pwd)"
out=$root/Tests/out/real-apps
mkdir -p "$out/defaults" "$out/tree"
python3 - "$out/tree" <<'PY'
import os,sys
for d in range(12):
    folder=os.path.join(sys.argv[1],str(d)); os.makedirs(folder,exist_ok=True)
    for i in range(100):
        with open(os.path.join(folder,str(i)+'.txt'),'w') as f: f.write('sample data\n'*100)
PY
conf=$(gnustep-config --variable=GNUSTEP_CONFIG_FILE)
{ grep -v '^GNUSTEP_USER_CONFIG_FILE=\|^GNUSTEP_USER_DEFAULTS_DIR=' "$conf"; echo GNUSTEP_USER_CONFIG_FILE=; echo "GNUSTEP_USER_DEFAULTS_DIR=$out/defaults"; } > "$out/GNUstep.conf"
chmod 600 "$out/GNUstep.conf"
exec 3< <(Xvfb -displayfd 4 -screen 0 1280x900x24 -nolisten tcp 4>&1 2>/dev/null)
xpid=$!
record_pid=""
cleanup() {
  [ -z "$record_pid" ] || kill "$record_pid" 2>/dev/null || true
  kill "$xpid" 2>/dev/null || true
}
trap cleanup EXIT
read -r -t 10 display <&3
export DISPLAY=:$display
export GNUSTEP_CONFIG_FILE="$out/GNUstep.conf"
defaults write NSGlobalDomain GSTheme Adwaita >/dev/null 2>&1
gst="$root/Tools/gstrace/obj/gstrace"
for name in ScreenshotTool LinDirStat; do
  if [ "$name" = ScreenshotTool ]; then
    app="$screenshot_app"
    input="$root/docs/screenshots/allocations.png"
  else
    app="$lindirstat_app"
    input="$out/tree"
  fi
  sha256sum "$app" > "$out/$name-binary.sha256"
  for template in 'Time Profiler' Leaks; do
    label=${template// /-}
    trace="$out/$name-$label.gstrace"
    rm -rf "$trace"
    "$gst" record --template "$template" --time-limit 8s --env "GNUSTEP_CONFIG_FILE=$out/GNUstep.conf" -o "$trace" --launch "$app" "$input" >"$out/$name-$label-record.log" 2>&1 &
    record_pid=$!
    sleep 5
    import -window root "$out/$name-$label.png"
    wait "$record_pid"
    record_pid=""
    "$gst" info "$trace" >"$out/$name-$label-info.txt" 2>&1
    grep -q 'finished cleanly: yes' "$out/$name-$label-info.txt"
    if [ "$template" = Leaks ]; then
      "$gst" report "$trace" leaks >"$out/$name-leaks.txt" 2>&1
    else
      "$gst" report "$trace" calltree --depth 30 >"$out/$name-calltree.txt" 2>&1
    fi
    "$gst" symbolicate "$trace" --embed >"$out/$name-$label-symbols.txt" 2>&1
    echo "Recorded $name: $template; embedded symbols."
  done
done
echo "All four real-app recording checks passed; inspect screenshots and stacks before acceptance."
