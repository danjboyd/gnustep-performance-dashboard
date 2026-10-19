#!/usr/bin/env bash
# Exercise the packaged privileged helper ONLY in a disposable container.
# /candidate.AppImage is read-only; /evidence is the retained output folder.
set -euo pipefail
[ -f /.dockerenv ] && [ "$(id -u)" = 0 ] || { echo 'Requires a disposable root Docker container'; exit 2; }
apt-get update
apt-get install -y --no-install-recommends gcc libc6-dev procps passwd util-linux dbus polkitd pkexec
cd /tmp
/candidate.AppImage --appimage-extract >/dev/null
source=/tmp/squashfs-root/usr/app/PerformanceDashboard.app/Resources
helper="$source/gstrace-helper"
policy=/usr/share/polkit-1/actions/org.gnustep.performancedashboard.policy
installed=/usr/local/libexec/gstrace-helper
mkdir -p /evidence
useradd -m -u 1000 profiler
mkdir -p /run/dbus
dbus-daemon --system --fork
/usr/lib/polkit-1/polkitd --no-debug > /evidence/polkit.log 2>&1 &
trap '"$helper" uninstall; kill "${target:-}" 2>/dev/null || true' EXIT
bash -c 'pkexec "$@"; result=$?; exit "$result"' -- "$helper" install --source "$source"
[ "$(stat -c '%u:%g:%a' "$installed")" = 0:0:755 ]
[ "$(stat -c '%u:%g:%a' "$policy")" = 0:0:644 ]
cmp "$helper" "$installed"
if "$installed" uninstall > /evidence/self-uninstall.log 2>&1; then exit 1; fi
grep -q 'run uninstall from a copy' /evidence/self-uninstall.log
if setpriv --reuid=1000 --regid=1000 --init-groups "$helper" install --source "$source" > /evidence/nonroot-install.log 2>&1; then exit 1; fi
gcc -O2 -g /src/Tests/fixtures/optimized.c -o /tmp/optimized -lpthread
mkdir /tmp/helper-trace /tmp/foreign-trace
chown 1000:1000 /tmp/helper-trace
sleep 30 & foreign=$!
if PKEXEC_UID=1000 "$installed" record --pid "$foreign" --output /tmp/helper-trace --duration 1 > /evidence/foreign-user.log 2>&1; then exit 1; fi
kill "$foreign"
grep -q 'belongs to another user' /evidence/foreign-user.log
setpriv --reuid=1000 --regid=1000 --init-groups /tmp/optimized & target=$!
if PKEXEC_UID=1000 "$installed" record --pid "$target" --output /tmp/foreign-trace --duration 1 > /evidence/foreign-output.log 2>&1; then exit 1; fi
grep -q 'not owned by the invoking user' /evidence/foreign-output.log
PKEXEC_UID=1000 "$installed" record --pid "$target" --output /tmp/helper-trace --duration 1
wait "$target"
target=''
test -n "$(find /tmp/helper-trace -name '*.done' -print)"
test "$(stat -c '%u:%a' /tmp/helper-trace/events-*.bin)" = 1000:600
cp -a /tmp/helper-trace /evidence/
bash -c 'pkexec "$@"; result=$?; exit "$result"' -- "$helper" uninstall
[ ! -e "$installed" ] && [ ! -e "$policy" ]
echo 'Helper install, ownership, same-user attach/stop, denial and uninstall checks passed.'
