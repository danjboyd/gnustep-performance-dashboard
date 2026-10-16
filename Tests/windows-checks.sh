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

echo
if [ $FAILED -eq 0 ]; then
  echo "All $PASSED Windows recording checks passed."
  exit 0
fi
echo "$FAILED of $((PASSED + FAILED)) Windows recording checks failed."
exit 1
