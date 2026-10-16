#!/usr/bin/env bash
# Release check: the AppImage records a program. Runs the AppImage on a
# private Xvfb with a private GNUstep home, without the build machine's
# GNUstep environment, has it record a small C program with the Leaks
# template (the recording agent is copied out of the AppImage mount and
# preloaded into the program), sends SIGTERM, and checks that the app exits
# with status 0 and that the trace finished cleanly with the program's ten
# leaked blocks.
#
#   scripts/check-appimage-record.sh APPIMAGE
set -euo pipefail

[ $# -eq 1 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
appimage="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "check-appimage-record: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/pd-record-check.XXXXXX")"
xvfb_pid=""; app_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
  [ -n "${trace:-}" ] && rm -rf "$trace"
  rm -rf "$work"
}
trap cleanup EXIT

cc -O0 -g "$repo_root/Tests/fixtures/cburn.c" -o "$work/cburn" -lpthread || die "cannot build the fixture"

exec 3< <(Xvfb -displayfd 4 -screen 0 1280x800x24 -nolisten tcp 4>&1 2>/dev/null)
xvfb_pid=$!
read -r -t 10 display_number <&3 || die "Xvfb did not start"

# GNUstep's temporary directory for this user, where unsaved recordings go.
traces="/tmp/GNUstepSecure$(id -u)/Performance Dashboard"
mkdir -p "$work/home"
touch "$work/start"
env -i HOME="$work/home" PATH=/usr/bin:/bin DISPLAY=":$display_number" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent \
  ${APPIMAGE_EXTRACT_AND_RUN:+APPIMAGE_EXTRACT_AND_RUN=$APPIMAGE_EXTRACT_AND_RUN} \
  "$appimage" -PDRecordTarget "$work/cburn" -PDRecordTemplate Leaks >"$work/app.log" 2>&1 &
app_pid=$!

# The program runs for about half a second; give the app time to start and
# to read the finished trace.
trace=""
for _ in $(seq 1 30); do
  sleep 1
  trace="$(find "$traces" -maxdepth 1 -name 'cburn*.gstrace' -type d -newer "$work/start" 2>/dev/null | head -1)"
  if [ -n "$trace" ] && grep -q ExitStatus "$trace/Info.plist" 2>/dev/null; then
    break
  fi
done
[ -n "$trace" ] || { tail -20 "$work/app.log" >&2; die "no trace was written"; }
sleep 2
# Signal the app. In extract-and-run mode (no FUSE, as in CI containers)
# the AppImage runtime runs it as a child and dies on SIGTERM itself,
# leaving the app behind; with FUSE the AppImage's process is the app.
target="$(pgrep -P "$app_pid" -f 'PerformanceDashboard\.app/PerformanceDashboard' | head -1 || true)"
kill -TERM "${target:-$app_pid}"
status=0
for _ in $(seq 1 10); do kill -0 "$app_pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$app_pid" 2>/dev/null; then die "the app did not exit on SIGTERM"; fi
wait "$app_pid" || status=$?
app_pid=""
[ "$status" = 0 ] || die "the app exited with status $status on SIGTERM"

(cd "$work" && "$appimage" --appimage-extract usr/runtime >/dev/null 2>&1) || die "cannot extract the AppImage"
runtime="$work/squashfs-root/usr/runtime"
info="$(LD_LIBRARY_PATH="$runtime/lib" GNUSTEP_CONFIG_FILE="$runtime/etc/GNUstep/GNUstep.conf" \
  HOME="$work/home" "$runtime/bin/gstrace" info "$trace" 2>/dev/null)"
leaks="$(LD_LIBRARY_PATH="$runtime/lib" GNUSTEP_CONFIG_FILE="$runtime/etc/GNUstep/GNUstep.conf" \
  HOME="$work/home" "$runtime/bin/gstrace" report "$trace" leaks 2>/dev/null)"
grep -q 'finished cleanly: yes' <<<"$info" || { echo "$info" >&2; die "the trace did not finish cleanly"; }
grep -q '^10 leaked block(s), 480 Bytes' <<<"$leaks" || { echo "$leaks" >&2; die "the trace does not have the fixture's 10 leaks"; }
echo "check-appimage-record: passed (recorded, 10 leaks found, exit status 0 on SIGTERM)"
