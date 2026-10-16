#!/bin/sh
# Tests/viewer-checks.sh - reading, reporting and exporting a trace that was
# recorded on Linux (Tests/data/sample.gstrace, with embedded symbols).
# Runs on every platform, including Windows where recording is not
# available yet.  Usage: sh Tests/viewer-checks.sh [path/to/gstrace]

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GSTRACE=${1:-$ROOT/Tools/gstrace/obj/gstrace}
T=$ROOT/Tests/data/sample.gstrace
OUT=${TMPDIR:-/tmp}/gsp-viewer-$$
mkdir -p "$OUT"
FAILED=0
PASSED=0
check() { if eval "$2"; then PASSED=$((PASSED + 1)); echo "ok   - $1"; else FAILED=$((FAILED + 1)); echo "FAIL - $1"; fi; }

"$GSTRACE" info "$T" >"$OUT/info.txt" 2>/dev/null
check "info reads the sample" "grep -q 'finished cleanly: yes' '$OUT/info.txt'"
"$GSTRACE" report "$T" top --limit 3 >"$OUT/top.txt" 2>/dev/null
check "embedded symbols name the hot method" "grep -q 'Worker crunch:' '$OUT/top.txt'"
"$GSTRACE" report "$T" leaks >"$OUT/leaks.txt" 2>/dev/null
check "leaks: the 5 Leaky objects" "grep -E -q '^Leaky +5 ' '$OUT/leaks.txt'"
"$GSTRACE" report "$T" signposts >"$OUT/sp.txt" 2>/dev/null
check "signposts: 5 Round intervals" "grep -E -q '^Round +PointsOfInterest +5 ' '$OUT/sp.txt'"
"$GSTRACE" report "$T" allocations --limit 400 >"$OUT/alloc.txt" 2>/dev/null
check "allocations: GSCInlineString category" "grep -q '^GSCInlineString' '$OUT/alloc.txt'"
for f in json chrome speedscope collapsed; do
  "$GSTRACE" export "$T" --format $f -o "$OUT/x.$f" 2>/dev/null
  check "export $f" "[ -s '$OUT/x.$f' ]"
done
check "diff of the sample with itself" "'$GSTRACE' diff '$T' '$T' >/dev/null 2>&1"

rm -rf "$OUT"
echo
if [ $FAILED -eq 0 ]; then
  echo "All $PASSED viewer checks passed."
  exit 0
fi
echo "$FAILED of $((PASSED + FAILED)) viewer checks failed."
exit 1
