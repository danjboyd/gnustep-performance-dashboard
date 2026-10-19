#!/usr/bin/env bash
# Adapted from PerformanceDashboard's AppImage update acceptance test.
# OLD.AppImage NEW.AppImage NEW.update-feed.json: isolated UI acceptance of
# replacement/relaunch and rejection of a bad digest or missing download.
# Logs are retained under Tests/out/update; no public feed is modified.
set -euo pipefail

if [ $# -ne 3 ]; then
  sed -n '2,20p' "$0" >&2
  exit 2
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
old_appimage="$(realpath "$1")"
new_appimage="$(realpath "$2")"
new_feed="$(realpath "$3")"
for tool in Xvfb xdotool xwininfo openssl; do
  command -v "$tool" >/dev/null || { echo "test-appimage-update: needs $tool" >&2; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/pd-update-test.XXXXXX")"
xvfb_pid=""
# The AppImage, the app and its GNUstep daemons, all run from $work.
app_pids() { pgrep -f "^$work/" || true; }
# Stops the app and unmounts its AppImage (the runtime unmounts when it
# exits; one that was killed may not), so nothing under $work is a mount.
stop_app() {
  local pids mount_point
  pids="$(app_pids)"
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    wait_for '[ -z "$(app_pids)" ]' 20 || kill -9 $(app_pids) 2>/dev/null || true
  fi
  for mount_point in $(findmnt -rn -o TARGET | grep "^$work/" || true); do
    fusermount3 -u "$mount_point" 2>/dev/null || fusermount -u "$mount_point" 2>/dev/null || true
  done
  ! findmnt -rn -o TARGET | grep -q "^$work/"
}

# Removes a folder under $work, never while an AppImage is mounted there.
remove_under_work() {
  if stop_app; then
    rm -rf "$@"
  else
    echo "test-appimage-update: an AppImage is still mounted under $work; not removing it" >&2
    return 1
  fi
}

cleanup() {
  mkdir -p "$repo_root/Tests/out/update"
  cp "$work"/app-*.log "$repo_root/Tests/out/update/" 2>/dev/null || true
  stop_app || true
  echo "Update acceptance working files: $work"
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

exec 3< <(Xvfb -displayfd 4 -screen 0 1280x800x24 -nolisten tcp 4>&1 2>/dev/null)
xvfb_pid=$!
read -r -t 10 display_number <&3 || { echo "test-appimage-update: Xvfb did not start" >&2; exit 1; }
export DISPLAY=":$display_number"

sha() { sha256sum "$1" | cut -d' ' -f1; }

# Waits up to $2 seconds for the condition command $1.
wait_for() {
  local deadline=$((SECONDS + $2))
  until eval "$1"; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.5
  done
}

# The update dialogs are NSAlerts, all titled "Alert". There is no window
# manager, so windows are listed with xwininfo; the newest is listed first.
alert_count() { xwininfo -root -tree | grep -c '"Alert"' || true; }
newest_alert() { xwininfo -root -tree | grep '"Alert"' | head -1; }
main_window_count() { xwininfo -root -tree | grep -c 'true\|Choose a Profiling Template\|"Window"' || true; }

# Presses the default button of the newest alert: Return, then a click on
# the button if that did not close it ($1, $2: the button's centre from the
# alert's top-left corner under the Adwaita theme; negative x counts from
# the right edge).
answer_alert() {
  local line id geometry width x y before
  line="$(newest_alert)"
  id="$(awk '{print $1}' <<<"$line")"
  geometry="$(grep -o '[0-9]*x[0-9]*+[0-9]*+[0-9]*' <<<"$line" | head -1)"
  IFS='x+' read -r width _ x y <<<"$geometry"
  before="$(alert_count)"
  xdotool windowfocus --sync "$id" 2>/dev/null || true
  xdotool key Return
  if wait_for '[ "$(alert_count)" -lt "$before" ]' 3; then
    return
  fi
  local dx="$1"
  [ "$dx" -lt 0 ] && dx=$((width + dx))
  xdotool mousemove $((x + dx)) $((y + $2)) mousedown 1
  sleep 0.15
  xdotool mouseup 1
}

# The updater's state file $1: its status, or why it failed.
helper_status() { helper_field "$1" status; }
helper_field() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
state = json.load(open(sys.argv[1]))
if sys.argv[2] == "error":
    print((state.get("error") or {}).get("message", "") or state.get("message", ""))
else:
    print(state.get(sys.argv[2], ""))
PY
}

# One scenario: installs OLD, points at a private feed, and accepts the update.
run_scenario() {
  local name="$1"
  remove_under_work "$work/install" "$work/release" "$work/home" "$work/xdg" "$work/tmp" "$work/scan" || return
  mkdir -p "$work/install" "$work/release" "$work/home" "$work/xdg/data" "$work/xdg/config" "$work/xdg/cache" "$work/scan"
  # The updater keeps its state in GNUstep's temporary folder: TMP (not
  # TMPDIR), used only when no one else can write to it. TMPDIR is where
  # the AppImage runtime mounts the AppImage.
  mkdir -m 700 "$work/tmp"
  cp "$old_appimage" "$work/install/PerformanceDashboard.AppImage"
  chmod +x "$work/install/PerformanceDashboard.AppImage"
  cp "$new_appimage" "$work/release/"
  printf 'x\n' > "$work/scan/file.txt"

  python3 - "$new_feed" "$work/release" "$work/release/stable.json" <<'PY'
import json, os, pathlib, sys
feed = json.load(open(sys.argv[1], encoding="utf-8-sig"))
for release in feed["releases"]:
    for asset in release["assets"]:
        asset["url"] = pathlib.Path(sys.argv[2], asset["name"]).as_uri()
json.dump(feed, open(sys.argv[3], "w"), indent=2)
PY
  python3 - "$work/release/stable.json" "$name" <<'PYEDIT'
import json,sys
p=sys.argv[1]; feed=json.load(open(p)); asset=feed['releases'][0]['assets'][0]
if sys.argv[2] == 'bad-hash': asset['sha256']='0'*64
if sys.argv[2] == 'missing': asset['url'] += '.missing'
json.dump(feed,open(p,'w'))
PYEDIT

  local old_sha new_sha state_dir state
  old_sha="$(sha "$work/install/PerformanceDashboard.AppImage")"
  new_sha="$(sha "$new_appimage")"
  state_dir="$work/tmp/gnustep-packager-updater/io.github.danjboyd.PerformanceDashboard"

  GNUSTEP_HOME="$work/home" XDG_DATA_HOME="$work/xdg/data" XDG_CONFIG_HOME="$work/xdg/config" \
  XDG_CACHE_HOME="$work/xdg/cache" TMP="$work/tmp" TMPDIR="$work/tmp" DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent \
  GP_UPDATER_FEED_URL="file://$work/release/stable.json" APPIMAGE_EXTRACT_AND_RUN=1 \
    "$work/install/PerformanceDashboard.AppImage" -PDRecordTarget /bin/true -PDRecordTemplate "Time Profiler" >"$work/app-$name.log" 2>&1 &
  disown

  # The automatic check runs startupDelaySeconds (15) after launch.
  if ! wait_for '[ "$(alert_count)" -ge 1 ]' 60; then
    fail "$name: no update offered"
    return
  fi
  answer_alert 187 152   # Install Update

  state="$state_dir/update-state.json"
  if [ "$name" = valid ]; then
    if ! wait_for '[ "$(helper_status "$state")" = readyToApply ] && [ "$(alert_count)" -ge 1 ]' 120; then
      fail "$name: the update was not prepared (helper: $(helper_status "$state"))"
      return
    fi
    cp "$state" "$work/prepared-$name.json"
    answer_alert -104 146  # Restart and Install
    if ! wait_for '[ "$(sha "$work/install/PerformanceDashboard.AppImage" 2>/dev/null)" = "$new_sha" ]' 120; then
      fail "$name: the installed AppImage was not replaced"
      return
    fi
    if ! wait_for '{ [ ! -e "$state" ] || [ "$(helper_status "$state")" = completed ]; } && [ -n "$(app_pids)" ] && [ "$(main_window_count)" -ge 1 ]' 60; then
      cp "$state" "$work/state-$name.json" 2>/dev/null || true
      fail "$name: the updated AppImage did not start again"
      return
    fi
    echo "test-appimage-update: $name: replaced by the new AppImage, which started again"
  else
    if ! wait_for '[ "$(helper_status "$state")" = failed ]' 120; then
      fail "$name: the helper did not refuse the payload (helper: $(helper_status "$state"))"
      return
    fi
    if [ "$(sha "$work/install/PerformanceDashboard.AppImage")" != "$old_sha" ]; then
      fail "$name: the installed AppImage changed"
      return
    fi
    echo "test-appimage-update: $name: payload refused ($(helper_field "$state" error)), installed AppImage unchanged"
  fi
  cp "$state" "$work/state-$name.json" 2>/dev/null || true
  import -window root "$work/screen-$name.png" 2>/dev/null || true
  stop_app || true
}

real_settings="$HOME/GNUstep/Defaults/PerformanceDashboard.plist"
settings_before="$(stat -c %Y "$real_settings" 2>/dev/null || echo none)"

run_scenario valid
run_scenario bad-hash
run_scenario missing
# A valid retry after failures must still update and restart.
run_scenario valid

if [ "$(stat -c %Y "$real_settings" 2>/dev/null || echo none)" != "$settings_before" ]; then
  fail "$real_settings changed"
fi

if [ "$failures" -ne 0 ]; then
  echo "test-appimage-update: $failures failure(s); logs were in $work" >&2
  exit 1
fi
echo "test-appimage-update: PASSED"
