#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test perf attachment in an isolated guest kernel with software emulation.
# No host devices, network or shared filesystem are exposed to the guest.
# Usage: bash scripts/check-helper-vm.sh APPIMAGE KERNEL
set -euo pipefail
appimage=$(realpath "${1:?AppImage required}")
kernel=$(realpath "${2:?Linux kernel required}")
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/pd-helper-vm.XXXXXX)
root=$work/root
mkdir -p "$root"/{bin,lib64,etc,proc,sys,dev,tmp,source,usr/local/libexec,usr/share/polkit-1/actions}
(cd "$work" && "$appimage" --appimage-extract >/dev/null)
resources=$work/squashfs-root/usr/app/PerformanceDashboard.app/Resources
chmod 700 "$root/source"
install -m 755 "$resources/gstrace-helper" "$root/source/gstrace-helper"
install -m 644 "$resources/org.gnustep.performancedashboard.policy" "$root/source/"
cp /usr/bin/busybox "$root/bin/busybox"
for name in sh mount mkdir cp chmod chown grep stat touch kill sleep poweroff cat env test seq; do
  ln -s busybox "$root/bin/$name"
done
for binary in /usr/bin/busybox "$resources/gstrace-helper"; do
  while read -r library; do
    mkdir -p "$root$(dirname "$library")"
    cp -L "$library" "$root$library"
  done < <(ldd "$binary" | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}')
done
cat > "$work/target.c" <<'C'
#include <unistd.h>
#include <time.h>
int main(void) {
  if (setgid(1000) || setuid(1000)) return 2;
  volatile unsigned long n=0;
  time_t end=time(0)+30;
  while(time(0)<end) n++;
  return 0;
}
C
gcc -O2 -g -static "$work/target.c" -o "$root/bin/target"
printf 'root:x:0:0:root:/root:/bin/sh\nprofiler:x:1000:1000:profiler:/tmp:/bin/sh\n' > "$root/etc/passwd"
cat > "$root/init" <<'INIT'
#!/bin/sh
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
run_checks() {
  set -e
  /source/gstrace-helper install --source /source
  test "$(stat -c '%u:%g:%a' /usr/local/libexec/gstrace-helper)" = 0:0:755
  mkdir /tmp/trace
  chown 1000:1000 /tmp/trace
  /bin/target & target=$!
  sleep 1
  PKEXEC_UID=1000 /usr/local/libexec/gstrace-helper record --pid "$target" --output /tmp/trace --duration 2
  test -f /tmp/trace/events-$target.done
  test "$(stat -c '%u:%a' /tmp/trace/events-$target.bin)" = 1000:600
  test "$(stat -c '%s' /tmp/trace/events-$target.bin)" -gt 1024
  # Test an explicit stop request independently of the duration bound.
  mkdir /tmp/stopped
  chown 1000:1000 /tmp/stopped
  PKEXEC_UID=1000 /usr/local/libexec/gstrace-helper record --pid "$target" --output /tmp/stopped --duration 20 & recorder=$!
  sleep 2
  touch /tmp/stopped/stop
  wait "$recorder"
  test -f /tmp/stopped/events-$target.done
  kill "$target"
  /source/gstrace-helper uninstall
  test ! -e /usr/local/libexec/gstrace-helper
  test ! -e /usr/share/polkit-1/actions/org.gnustep.performancedashboard.policy
  echo 'PD_HELPER_VM_PASSED: install, same-user perf attach, timed stop, requested stop, ownership, uninstall'
}
(run_checks)
result=$?
[ "$result" -eq 0 ] || echo PD_HELPER_VM_FAILED
poweroff -f
INIT
chmod 755 "$root/init"
(cd "$root" && find . -print0 | cpio --null -o --format=newc --owner=0:0 2>/dev/null | gzip -1 > "$work/initrd.gz")
mkdir -p "$repo/Tests/out/helper-vm"
timeout 180 qemu-system-x86_64 -machine accel=tcg -m 512 -smp 2 -kernel "$kernel" \
  -initrd "$work/initrd.gz" -append 'console=ttyS0 rdinit=/init panic=-1' \
  -nographic -no-reboot -nic none > "$repo/Tests/out/helper-vm/serial.log" 2>&1
grep 'PD_HELPER_VM_PASSED' "$repo/Tests/out/helper-vm/serial.log"
! grep -q 'PD_HELPER_VM_FAILED' "$repo/Tests/out/helper-vm/serial.log"
sha256sum "$appimage" "$kernel" > "$repo/Tests/out/helper-vm/inputs.sha256"
echo "Guest test files retained at $work"
