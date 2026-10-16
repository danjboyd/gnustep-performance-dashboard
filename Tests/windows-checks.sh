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
"$GSTRACE" record --template "Time Profiler" -o "$OUT/spin.gstrace" --launch "$OUT/spin.exe" \
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

# Objective-C: method names come from the runtime's method table
if command -v gnustep-config >/dev/null 2>&1; then
  OBJCFLAGS=$(gnustep-config --objc-flags | sed 's/-MMD//; s/-MP//')
  clang $OBJCFLAGS -DHAVE_MODE_T -O0 -Wno-unused-but-set-variable -I"$ROOT/Runtime/include" \
    "$ROOT/Tests/fixtures/objcwork.m" -o "$OUT/objcwork.exe" $(gnustep-config --base-libs) \
    -L"$ROOT/Runtime/obj" -lgsperf >"$OUT/objcwork-build.log" 2>&1 || cat "$OUT/objcwork-build.log"
  rm -rf "$OUT/objc.gstrace"
  "$GSTRACE" record --template "Time Profiler" -o "$OUT/objc.gstrace" --launch "$OUT/objcwork.exe" \
    >"$OUT/objc-record.log" 2>&1
  "$GSTRACE" info "$OUT/objc.gstrace" 2>&1 | tail -4
  "$GSTRACE" report "$OUT/objc.gstrace" top --limit 5 >"$OUT/objc-top.txt" 2>&1
  cat "$OUT/objc-top.txt"
  check "Objective-C: -[Worker crunch:] is the top function" "sed -n 4p '$OUT/objc-top.txt' | grep -q 'Worker crunch:'"
  "$GSTRACE" report "$OUT/objc.gstrace" signposts >"$OUT/objc-sp.txt" 2>&1
  check "Objective-C: 5 Round signposts" "grep -E -q '^Round +PointsOfInterest +5 ' '$OUT/objc-sp.txt'"

  # Allocations: CRT heap and Objective-C allocation hooks
  rm -rf "$OUT/objalloc.gstrace"
  "$GSTRACE" record --template Allocations -o "$OUT/objalloc.gstrace" --launch "$OUT/objcwork.exe" \
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
fi

echo
if [ $FAILED -eq 0 ]; then
  echo "All $PASSED Windows recording checks passed."
  exit 0
fi
echo "$FAILED of $((PASSED + FAILED)) Windows recording checks failed."
exit 1
