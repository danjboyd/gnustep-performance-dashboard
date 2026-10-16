#!/bin/sh
# Tests/windows-checks.sh - recording on Windows (MSYS2 clang64): build the
# portable fixture, record it with the Time Profiler and check the result.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GSTRACE=$ROOT/Tools/gstrace/obj/gstrace.exe
OUT=$ROOT/Tests/out
mkdir -p "$OUT"
FAILED=0
PASSED=0
check() { if eval "$2"; then PASSED=$((PASSED + 1)); echo "ok   - $1"; else FAILED=$((FAILED + 1)); echo "FAIL - $1"; fi; }

clang -O0 -g -I"$ROOT/Runtime/include" "$ROOT/Tests/fixtures/spin.c" -o "$OUT/spin.exe" \
  -L"$ROOT/Runtime/obj" -lgsperf -lpthread || exit 1
cp "$ROOT/Runtime/obj/gsperf.dll" "$OUT/"

rm -rf "$OUT/spin.gstrace"
timeout 180 "$GSTRACE" record --template "Time Profiler" -o "$OUT/spin.gstrace" --launch "$OUT/spin.exe" \
  >"$OUT/spin-record.log" 2>&1
cat "$OUT/spin-record.log"
"$GSTRACE" info "$OUT/spin.gstrace" >"$OUT/spin-info.txt" 2>&1
cat "$OUT/spin-info.txt"
check "recorded and finished cleanly" "grep -q 'finished cleanly: yes' '$OUT/spin-info.txt'"
"$GSTRACE" report "$OUT/spin.gstrace" top --limit 5 >"$OUT/spin-top.txt" 2>&1
cat "$OUT/spin-top.txt"
check "CPU time lands in spin_inner" "sed -n 4p '$OUT/spin-top.txt' | grep -q spin_inner"
"$GSTRACE" report "$OUT/spin.gstrace" threads >"$OUT/spin-threads.txt" 2>&1
cat "$OUT/spin-threads.txt"
check "two threads with CPU" "[ \$(grep -c 'CPU' '$OUT/spin-threads.txt') -ge 2 ]"
"$GSTRACE" report "$OUT/spin.gstrace" signposts >"$OUT/spin-sp.txt" 2>&1
cat "$OUT/spin-sp.txt"
check "4 Round signposts" "grep -E -q '^Round +PointsOfInterest +4 ' '$OUT/spin-sp.txt'"

# Attaching to a running program
"$OUT/spin.exe" 12 >"$OUT/spin-attached.log" 2>&1 &
SPIN=$!
WINPID=$(cat /proc/$SPIN/winpid 2>/dev/null || echo $SPIN)
timeout 2 tail -f /dev/null 2>/dev/null
rm -rf "$OUT/attach.gstrace"
timeout 180 "$GSTRACE" record --template "Time Profiler" --attach "$WINPID" --time-limit 2s \
  -o "$OUT/attach.gstrace" >"$OUT/attach-record.log" 2>&1
cat "$OUT/attach-record.log"
"$GSTRACE" info "$OUT/attach.gstrace" >"$OUT/attach-info.txt" 2>&1
cat "$OUT/attach-info.txt"
"$GSTRACE" report "$OUT/attach.gstrace" top --limit 3 >"$OUT/attach-top.txt" 2>&1
cat "$OUT/attach-top.txt"
check "attach: recorded and finished cleanly" "grep -q 'finished cleanly: yes' '$OUT/attach-info.txt'"
check "attach: CPU time lands in spin_inner" "sed -n 4p '$OUT/attach-top.txt' | grep -q spin_inner"
"$GSTRACE" report "$OUT/attach.gstrace" signposts >"$OUT/attach-sp.txt" 2>&1
check "attach: signposts after attaching are recorded" "grep -E -q '^Round +PointsOfInterest +[1-4] ' '$OUT/attach-sp.txt'"
check "attach: the program keeps running and finishes" "kill -0 $SPIN 2>/dev/null && wait $SPIN && grep -q '^spin ' '$OUT/spin-attached.log'"

# File Activity and Network
clang -O0 -g "$ROOT/Tests/fixtures/iofix_win.c" -o "$OUT/iofix.exe" -lws2_32 || exit 1
rm -rf "$OUT/io.gstrace"
timeout 180 "$GSTRACE" record --template "File Activity" --instrument file-activity --instrument network \
  -o "$OUT/io.gstrace" --launch "$OUT/iofix.exe" "$OUT/iofix.dat" >"$OUT/io-record.log" 2>&1
cat "$OUT/io-record.log"
"$GSTRACE" report "$OUT/io.gstrace" files >"$OUT/io-files.txt" 2>&1
"$GSTRACE" report "$OUT/io.gstrace" network >"$OUT/io-net.txt" 2>&1
"$GSTRACE" report "$OUT/io.gstrace" files --by-stack --depth 6 >"$OUT/io-tree.txt" 2>&1
cat "$OUT/io-files.txt" "$OUT/io-net.txt"
check "files: 3 opens, 200 KiB read, 10 writes of 100 KiB" "grep -E -q 'iofix.dat +3 +[0-9]+ +200.00 KiB +10 +100.00 KiB' '$OUT/io-files.txt'"
check "files: failed opens recorded as errors" "grep -E -q 'nonexistent/iofix +2 +0 +0 Bytes +0 +0 Bytes +2 ' '$OUT/io-files.txt'"
check "files: call tree attributes I/O to write_file and read_file" "grep -q write_file '$OUT/io-tree.txt' && grep -q read_file '$OUT/io-tree.txt'"
check "network: 5000 bytes sent and received over loopback" "grep -E -q '^127.0.0.1:[0-9]+ +1 +0 +0 Bytes +1 +4.88 KiB' '$OUT/io-net.txt' && grep -E -q '^127.0.0.1:[0-9]+ +1 +1 +4.88 KiB' '$OUT/io-net.txt'"

# Objective-C: method names come from the runtime's method table
if command -v gnustep-config >/dev/null 2>&1; then
  OBJCFLAGS=$(gnustep-config --objc-flags | sed 's/-MMD//; s/-MP//')
  clang $OBJCFLAGS -DHAVE_MODE_T -O0 -g -Wno-unused-but-set-variable -I"$ROOT/Runtime/include" \
    "$ROOT/Tests/fixtures/objcwork.m" -o "$OUT/objcwork.exe" $(gnustep-config --base-libs) \
    -L"$ROOT/Runtime/obj" -lgsperf >"$OUT/objcwork-build.log" 2>&1 || cat "$OUT/objcwork-build.log"
  rm -rf "$OUT/objc.gstrace"
  timeout 180 "$GSTRACE" record --template "Time Profiler" -o "$OUT/objc.gstrace" --launch "$OUT/objcwork.exe" \
    >"$OUT/objc-record.log" 2>&1
  "$GSTRACE" info "$OUT/objc.gstrace" 2>&1 | tail -4
  "$GSTRACE" report "$OUT/objc.gstrace" top --limit 5 >"$OUT/objc-top.txt" 2>&1
  cat "$OUT/objc-top.txt"
  check "Objective-C: -[Worker crunch:] is the top function" "sed -n 4p '$OUT/objc-top.txt' | grep -q 'Worker crunch:'"
  "$GSTRACE" report "$OUT/objc.gstrace" signposts >"$OUT/objc-sp.txt" 2>&1
  check "Objective-C: 5 Round signposts" "grep -E -q '^Round +PointsOfInterest +5 ' '$OUT/objc-sp.txt'"

  # Allocations: CRT heap and Objective-C allocation hooks
  rm -rf "$OUT/objalloc.gstrace"
  timeout 180 "$GSTRACE" record --template Allocations -o "$OUT/objalloc.gstrace" --launch "$OUT/objcwork.exe" \
    >"$OUT/objalloc-record.log" 2>&1
  cat "$OUT/objalloc-record.log"
  "$GSTRACE" info "$OUT/objalloc.gstrace" 2>&1 | tail -6
  "$GSTRACE" report "$OUT/objalloc.gstrace" allocations --limit 12 >"$OUT/objalloc.txt" 2>&1
  cat "$OUT/objalloc.txt"
  "$GSTRACE" export "$OUT/objalloc.gstrace" --format csv --table allocations \
    -o "$OUT/objalloc.csv" >/dev/null 2>&1
  cut -d, -f5 "$OUT/objalloc.csv" | sort | uniq -c | sort -rn | head -8
  check "Allocations: 10000 GSCInlineString allocations classified" "[ \$(grep -c ',GSCInlineString,' '$OUT/objalloc.csv') -ge 10000 ]"
  check "Allocations: 5 Leaky objects" "[ \$(grep -c ',Leaky,' '$OUT/objalloc.csv') -eq 5 ]"
  "$GSTRACE" report "$OUT/objalloc.gstrace" allocations --by-stack --min-percent 0 \
    >"$OUT/objalloc-stacks.txt" 2>&1
  check "Allocations: stacks reach make_leaks, without agent frames" \
    "grep -q make_leaks '$OUT/objalloc-stacks.txt' && ! grep -q hook_ '$OUT/objalloc-stacks.txt'"

  # Leaks: the conservative scan at exit()
  rm -rf "$OUT/objleaks.gstrace"
  timeout 180 "$GSTRACE" record --template Leaks -o "$OUT/objleaks.gstrace" --launch "$OUT/objcwork.exe" \
    >"$OUT/objleaks-record.log" 2>&1
  cat "$OUT/objleaks-record.log"
  "$GSTRACE" info "$OUT/objleaks.gstrace" 2>&1 | tail -6
  "$GSTRACE" report "$OUT/objleaks.gstrace" leaks >"$OUT/objleaks.txt" 2>&1
  head -40 "$OUT/objleaks.txt"
  check "Leaks: all 5 Leaky objects (incl. a retain cycle) found" "grep -E -q '^Leaky +5 ' '$OUT/objleaks.txt'"
  check "Leaks: leak stack names make_leaks" "grep -q make_leaks '$OUT/objleaks.txt'"
  check "Leaks: few other reports (< 50 blocks)" "[ \$(sed -n 2p '$OUT/objleaks.txt' | cut -d' ' -f1) -lt 50 ]"
  "$GSTRACE" report "$OUT/objleaks.gstrace" leaks --lines >"$OUT/objleaks-lines.txt" 2>&1
  check "source lines: leak stack shows objcwork.m:<line>" "grep -E -q 'make_leaks .*objcwork\.m:[0-9]+' '$OUT/objleaks-lines.txt'"

  # Zombies: a message to a deallocated object
  rm -rf "$OUT/zombie.gstrace"
  timeout 180 "$GSTRACE" record --template Zombies -o "$OUT/zombie.gstrace" --launch "$OUT/objcwork.exe" zombie \
    >"$OUT/zombie-record.log" 2>&1
  cat "$OUT/zombie-record.log"
  "$GSTRACE" info "$OUT/zombie.gstrace" 2>&1 | tail -4
  "$GSTRACE" report "$OUT/zombie.gstrace" zombies >"$OUT/zombie.txt" 2>&1
  cat "$OUT/zombie.txt"
  check "Zombies: -description to deallocated NSObject" "grep -q -- '-description sent to deallocated NSObject' '$OUT/zombie.txt'"
  check "Zombies: history Malloc, Release, Zombie" "grep -q Malloc '$OUT/zombie.txt' && grep -q Release '$OUT/zombie.txt' && grep -q 'Zombie' '$OUT/zombie.txt'"
fi

echo
if [ $FAILED -eq 0 ]; then
  echo "All $PASSED Windows recording checks passed."
  exit 0
fi
echo "$FAILED of $((PASSED + FAILED)) Windows recording checks failed."
exit 1
