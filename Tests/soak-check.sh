#!/usr/bin/env bash
# Measured sustained recording; does not replace interactive viewer acceptance.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
seconds=${1:-60}
[[ "$seconds" =~ ^[0-9]+$ ]] && [ "$seconds" -ge 60 ] && [ "$seconds" -le 600 ] \
  || { echo "Choose 60-600 seconds." >&2; exit 2; }
out="$root/Tests/out/soak"
mkdir -p "$out"
gcc -O2 -g -fno-omit-frame-pointer "$root/Tests/fixtures/soak.c" -o "$out/soak" -lpthread
gst="$root/Tools/gstrace/obj/gstrace"
rm -rf "$out/soak.gstrace"
/usr/bin/time -f 'elapsed_seconds=%e\ncommand_peak_rss_kib=%M' -o "$out/record-resources.txt" \
  timeout "$((seconds + 45))" "$gst" record --instrument allocations --instrument leaks --instrument time-profiler \
  --leak-interval 10 -o "$out/soak.gstrace" --launch "$out/soak" "$seconds" >"$out/record.log" 2>&1
"$gst" info "$out/soak.gstrace" >"$out/info.txt" 2>&1
grep -q 'finished cleanly: yes' "$out/info.txt"
grep -Eq 'allocation events: [1-9][0-9]{5}' "$out/info.txt"
grep -Eq 'leak checks: ([2-9]|[1-9][0-9]+)' "$out/info.txt"
if grep -q 'Warning:' "$out/info.txt"; then cat "$out/info.txt"; exit 1; fi
/usr/bin/time -f 'report_elapsed_seconds=%e\nreport_peak_rss_kib=%M' -o "$out/report-resources.txt" \
  timeout 30 "$gst" report "$out/soak.gstrace" allocations >"$out/allocations.txt" 2>&1
"$gst" report "$out/soak.gstrace" leaks >"$out/leaks.txt" 2>&1
du -sb "$out/soak.gstrace" >"$out/trace-bytes.txt"
cat "$out/record-resources.txt" "$out/report-resources.txt" "$out/trace-bytes.txt"
echo "All sustained recording checks passed ($seconds seconds, eight workers)."
echo "RSS above is the command's maximum including children, not separate target/recorder measurements."
