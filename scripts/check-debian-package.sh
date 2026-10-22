#!/usr/bin/env bash
# Run INSIDE a disposable Debian 13 container, with the repo at /src (read-only),
# one AppImage at /candidate.AppImage and a writable evidence folder at /evidence.
# No developer GNUstep installation or host HOME is mounted.
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends gcc libc6-dev binutils libunwind8 \
  xvfb xauth x11-utils fonts-dejavu-core python3 procps ca-certificates bubblewrap \
  libxft2 libxt6t64 libcairo2 libglib2.0-0t64 libdbus-1-3
export APPIMAGE_EXTRACT_AND_RUN=1
bash /src/scripts/check-appimage-record.sh /candidate.AppImage
cd /tmp
/candidate.AppImage --appimage-extract >/dev/null
runtime=/tmp/squashfs-root/usr/runtime
mkdir -p /tmp/pd-home
rm -rf /evidence/optimized.gstrace /evidence/lines.gstrace /evidence/no-unwind.gstrace /evidence/legacy-O0.gstrace /evidence/legacy-O2.gstrace
gst() {
  env -i HOME=/tmp/pd-home PATH=/usr/bin:/bin /tmp/squashfs-root/usr/runtime/bin/gstrace "$@"
}
gcc -O2 -g -fomit-frame-pointer /src/Tests/fixtures/optimized.c -o /tmp/optimized -lpthread
gst record --template 'Time Profiler' -o /evidence/optimized.gstrace --launch /tmp/optimized
gst info /evidence/optimized.gstrace | tee /evidence/optimized.info
gst report /evidence/optimized.gstrace calltree --lines | tee /evidence/optimized.tree
grep -q 'finished cleanly: yes' /evidence/optimized.info
grep -q hot_inner /evidence/optimized.tree
grep -q hot_outer /evidence/optimized.tree
gcc -O0 -g /src/Tests/fixtures/cburn.c -o /tmp/cburn -lpthread
gst record --template Leaks -o /evidence/lines.gstrace --launch /tmp/cburn
gst report /evidence/lines.gstrace leaks --lines | tee /evidence/lines.txt
grep -q 'cburn.c:' /evidence/lines.txt
gst symbolicate /evidence/optimized.gstrace --embed
mv /tmp/optimized /tmp/optimized.hidden
gst report /evidence/optimized.gstrace top > /evidence/embedded.txt
grep -q hot_inner /evidence/embedded.txt
mv /tmp/optimized.hidden /tmp/optimized

# Remove the optional host unwinder: a warning must replace a false promise
# of complete optimized stacks. Restore it before the legacy runtime probe.
apt-get remove -y libunwind8
gst record --template 'Time Profiler' -o /evidence/no-unwind.gstrace --launch /tmp/optimized
gst info /evidence/no-unwind.gstrace | tee /evidence/no-unwind.info
grep -qi 'frame.pointer' /evidence/no-unwind.info
apt-get install -y --no-install-recommends libunwind8 gobjc libgnustep-base-dev gnustep-make
set +u
. /usr/share/GNUstep/Makefiles/GNUstep.sh
set -u
for opt in 0 2; do
  gcc -O"$opt" -g $(gnustep-config --objc-flags) /src/Tests/fixtures/legacy.m \
    -o /tmp/legacy $(gnustep-config --base-libs)
  ldd /tmp/legacy | tee /evidence/legacy-O"$opt".ldd
  grep -q '/libobjc.so.4' /evidence/legacy-O"$opt".ldd
  gst record --template 'Time Profiler' -o /evidence/legacy-O"$opt".gstrace --launch /tmp/legacy
  gst info /evidence/legacy-O"$opt".gstrace > /evidence/legacy-O"$opt".info
  gst report /evidence/legacy-O"$opt".gstrace calltree > /evidence/legacy-O"$opt".tree
  grep -q 'finished cleanly: yes' /evidence/legacy-O"$opt".info
  grep -q busyWork /evidence/legacy-O"$opt".tree
done
dpkg-query -W > /evidence/packages.txt
sha256sum /candidate.AppImage > /evidence/appimage.sha256
echo 'Debian package checks passed (GUI/CLI leaks, optimized stacks/lines, embedded symbols, missing unwinder, GCC legacy CPU).'
