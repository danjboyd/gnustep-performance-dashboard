#!/usr/bin/env bash
# Linux target/compiler contract: GCC and Clang agents and optimized C targets.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Tests/out/compilers"
gst="$root/Tools/gstrace/obj/gstrace"
mkdir -p "$out"
checks=0
for compiler in gcc clang; do
  command -v "$compiler" >/dev/null
  dir="$out/$compiler"
  mkdir -p "$dir"
  "$compiler" --version | head -1
  make -C "$root/Runtime" all CC="$compiler" OBJDIR="$dir/runtime" >"$dir/build.log" 2>&1
  if readelf -d "$dir/runtime/libgsperf-agent.so" | grep NEEDED | grep -E 'libobjc|gnustep|libstdc\+\+|libc\+\+'; then
    echo "FAIL: agent links an application runtime" >&2; exit 1
  fi
  for optimization in 0 2; do
    target="$dir/cburn-O$optimization"
    "$compiler" -O"$optimization" -g -fomit-frame-pointer \
      "$root/Tests/fixtures/optimized.c" -o "$target" -lpthread
    trace="$target.gstrace"
    rm -rf "$trace"
    GSP_AGENT_PATH="$dir/runtime/libgsperf-agent.so" timeout 60 "$gst" record \
      --template 'Time Profiler' -o "$trace" --launch "$target" >"$target.record.log" 2>&1
    "$gst" info "$trace" >"$target.info" 2>&1
    "$gst" report "$trace" calltree >"$target.tree" 2>&1
    grep -q 'finished cleanly: yes' "$target.info"
    grep -q hot_inner "$target.tree"
    grep -q hot_outer "$target.tree"
    "$gst" symbolicate "$trace" --embed >"$target.symbols.log" 2>&1
    # Embedded names must work when the original executable is unavailable.
    mv "$target" "$target.hidden"
    "$gst" report "$trace" top >"$target.embedded" 2>&1
    mv "$target.hidden" "$target"
    grep -q hot_inner "$target.embedded"
    echo "ok - $compiler agent and -O$optimization target without frame pointers; portable symbols"
    checks=$((checks + 1))
  done
done
echo "All $checks compiler checks passed."
