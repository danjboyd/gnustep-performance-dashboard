#!/bin/sh
# Tests/run.sh - regression suite: unit tests (tools-xctest) plus end-to-end
# recordings of the fixtures with gstrace.
#
#   sh Tests/run.sh            build what is needed and run everything
#   SKIP_GUI=1 sh Tests/run.sh skip the AppKit fixture and the app checks
#                              (they need Xvfb; the app checks also xdotool)
#
# Judge the suite by the exit status and the final line.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/Tests/out
GSTRACE=$ROOT/Tools/gstrace/obj/gstrace
FAILED=0
PASSED=0

mkdir -p "$OUT"
cd "$ROOT" || exit 1

pass() { PASSED=$((PASSED + 1)); echo "ok   - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
quiet() { grep -v -E 'Configuration contains unknown keys|GNUSTEP_EXTRA=' ; }

echo "== build"
make -s >"$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; echo "build failed"; exit 1; }

OBJCFLAGS=$(gnustep-config --objc-flags | sed 's/-MMD//; s/-MP//')
cc -O0 -g "$ROOT/Tests/fixtures/cburn.c" -o "$OUT/cburn" -lpthread || exit 1
cc -O1 -g -fno-omit-frame-pointer "$ROOT/Tests/fixtures/stress.c" -o "$OUT/stress" -lpthread || exit 1
cc -O0 -g -Wno-unused-result "$ROOT/Tests/fixtures/iofix.c" -o "$OUT/iofix" || exit 1
clang $OBJCFLAGS -O0 -Wno-unused-but-set-variable -I"$ROOT/Runtime/include" \
  "$ROOT/Tests/fixtures/objcwork.m" -o "$OUT/objcwork" $(gnustep-config --base-libs) \
  -L"$ROOT/Runtime/obj" -lgsperf -Wl,-rpath,"$ROOT/Runtime/obj" || exit 1
clang $OBJCFLAGS -O0 -I"$ROOT/Runtime/include" "$ROOT/Tests/fixtures/hangapp.m" \
  -o "$OUT/hangapp" $(gnustep-config --gui-libs) \
  -L"$ROOT/Runtime/obj" -lgsperf -Wl,-rpath,"$ROOT/Runtime/obj" || exit 1

echo "== unit tests (xctest)"
if (cd Tests/Unit && make -s check) >"$OUT/unit.log" 2>&1; then
  pass "unit tests: $(grep -o '[0-9]* tests PASSED' "$OUT/unit.log" | head -1)"
else
  quiet <"$OUT/unit.log" | tail -30
  fail "unit tests"
fi

record() {   # record <name> <args...>
  name=$1; shift
  rm -rf "$OUT/$name.gstrace"
  "$GSTRACE" record --output "$OUT/$name.gstrace" "$@" >"$OUT/$name.log" 2>&1
}

echo "== C fixture: time profiler, allocations, leaks"
record cburn --instrument time-profiler --instrument allocations --instrument leaks \
  --launch "$OUT/cburn"
check "cburn recorded" "[ -f '$OUT/cburn.gstrace/Info.plist' ]"
"$GSTRACE" export "$OUT/cburn.gstrace" --format json -o "$OUT/cburn.json" 2>/dev/null
check "cburn summary is valid JSON" "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$OUT/cburn.json'"
# The work is fixed but its CPU time is not: on hybrid CPUs it takes about
# three times longer on an efficiency core than on a performance core.
check "cburn: 0.3-3 s of CPU, top function hot_inner" "python3 - '$OUT/cburn.json' <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))
top=d['topFunctions'][0]
sys.exit(0 if top['symbol']=='hot_inner' and 0.3 < d['cpuSeconds'] < 3.0 else 1)
EOF"
check "cburn: two threads" "python3 -c 'import json,sys; sys.exit(0 if len(json.load(open(sys.argv[1]))[\"threads\"])==2 else 1)' '$OUT/cburn.json'"
"$GSTRACE" report "$OUT/cburn.gstrace" leaks >"$OUT/cburn-leaks.txt" 2>/dev/null
check "cburn: exactly the 10 leaked 48-byte blocks" "grep -q '^10 leaked block(s), 480 Bytes' '$OUT/cburn-leaks.txt'"
check "cburn: leak attributed to leak_some" "grep -q 'leak_some' '$OUT/cburn-leaks.txt'"
"$GSTRACE" report "$OUT/cburn.gstrace" calltree --invert --depth 1 >"$OUT/cburn-tree.txt" 2>/dev/null
check "cburn: inverted call tree leads with hot_inner" "sed -n 4p '$OUT/cburn-tree.txt' | grep -q hot_inner"

echo "== Stress: 8 threads allocating during sampling and leak checks"
record stress --instrument time-profiler --instrument allocations --instrument leaks \
  --leak-interval 1 --launch "$OUT/stress"
check "stress: finished cleanly" "'$GSTRACE' info '$OUT/stress.gstrace' 2>/dev/null | grep -q 'finished cleanly: yes'"
"$GSTRACE" report "$OUT/stress.gstrace" leaks >"$OUT/stress-leaks.txt" 2>/dev/null
check "stress: no false leak reports (only the threads' 4000-byte blocks, if any)" "[ \$(grep -v '^      ' '$OUT/stress-leaks.txt' | grep -E '^(Malloc|[A-Z])' | grep -v -E '^Malloc 3.91 KiB' | grep -c -v -E '^[0-9]') -eq 0 ]"

echo "== Objective-C fixture: classes, leaks, signposts, os_log"
record objcwork --instrument time-profiler --instrument allocations --instrument leaks \
  --instrument points-of-interest --instrument os-log --launch "$OUT/objcwork"
"$GSTRACE" report "$OUT/objcwork.gstrace" leaks >"$OUT/objcwork-leaks.txt" 2>/dev/null
check "objcwork: all 5 Leaky objects (incl. a retain cycle) found" "grep -E -q '^Leaky +5 ' '$OUT/objcwork-leaks.txt'"
check "objcwork: leak stack names make_leaks" "grep -q make_leaks '$OUT/objcwork-leaks.txt'"
"$GSTRACE" report "$OUT/objcwork.gstrace" signposts >"$OUT/objcwork-sp.txt" 2>/dev/null
check "objcwork: 5 Round intervals" "grep -E -q '^Round +PointsOfInterest +5 ' '$OUT/objcwork-sp.txt'"
check "objcwork: Checkpoint event" "grep -q '^Checkpoint' '$OUT/objcwork-sp.txt'"
"$GSTRACE" report "$OUT/objcwork.gstrace" logs >"$OUT/objcwork-logs.txt" 2>/dev/null
check "objcwork: os_log message with arguments" "grep -q 'objcwork starting with 1 args' '$OUT/objcwork-logs.txt'"
"$GSTRACE" export "$OUT/objcwork.gstrace" --format csv --table allocations -o "$OUT/objcwork-allocs.csv" 2>/dev/null
check "objcwork: 10000 GSCInlineString allocations classified" "[ \$(grep -c ',GSCInlineString,' '$OUT/objcwork-allocs.csv') -ge 10000 ]"
"$GSTRACE" report "$OUT/objcwork.gstrace" top --limit 3 >"$OUT/objcwork-top.txt" 2>/dev/null
check "objcwork: -[Worker crunch:] is the top function" "sed -n 4p '$OUT/objcwork-top.txt' | grep -q 'Worker crunch:'"

echo "== File Activity and Network"
record io --template "File Activity" --instrument file-activity --instrument network \
  --launch "$OUT/iofix" "$OUT/iofix.dat"
"$GSTRACE" report "$OUT/io.gstrace" files >"$OUT/io-files.txt" 2>/dev/null
"$GSTRACE" report "$OUT/io.gstrace" network >"$OUT/io-net.txt" 2>/dev/null
"$GSTRACE" report "$OUT/io.gstrace" files --by-stack --depth 6 >"$OUT/io-tree.txt" 2>/dev/null
check "files: 3 opens, 200 KiB read, 10 writes of 100 KiB" "grep -E -q 'iofix.dat +3 +[0-9]+ +200.00 KiB +10 +100.00 KiB' '$OUT/io-files.txt'"
check "files: failed opens recorded as errors" "grep -E -q '/nonexistent/iofix +2 +0 +0 Bytes +0 +0 Bytes +2 ' '$OUT/io-files.txt'"
check "files: call tree attributes I/O to write_file and read_file" "grep -q write_file '$OUT/io-tree.txt' && grep -q read_file '$OUT/io-tree.txt'"
check "network: 5000 bytes sent and received over loopback" "grep -E -q '^127.0.0.1:[0-9]+ +1 +0 +0 Bytes +1 +4.88 KiB' '$OUT/io-net.txt' && grep -E -q '^127.0.0.1:[0-9]+ +1 +1 +4.88 KiB' '$OUT/io-net.txt'"

echo "== Relative target path with another working directory"
record relpath --template "Time Profiler" --cwd / --launch Tests/out/cburn
check "relative target: launched and recorded" "'$GSTRACE' info '$OUT/relpath.gstrace' 2>/dev/null | grep -q 'finished cleanly: yes'"
check "relative target: Info.plist stores the absolute path" "grep -q 'TargetPath = \"$OUT/cburn\"' '$OUT/relpath.gstrace/Info.plist'"

echo "== Zombies"
record zombie --template Zombies --launch "$OUT/objcwork" zombie
"$GSTRACE" report "$OUT/zombie.gstrace" zombies >"$OUT/zombie.txt" 2>/dev/null
check "zombie: -description to deallocated NSObject" "grep -q -- '-description sent to deallocated NSObject' '$OUT/zombie.txt'"
check "zombie: history Malloc, Release, Zombie" "grep -q Malloc '$OUT/zombie.txt' && grep -q Release '$OUT/zombie.txt' && grep -q 'Zombie' '$OUT/zombie.txt'"

echo "== Exports and symbol embedding"
for f in chrome speedscope; do
  "$GSTRACE" export "$OUT/cburn.gstrace" --format $f -o "$OUT/cburn-$f.json" 2>/dev/null
  check "export $f is valid JSON" "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$OUT/cburn-$f.json'"
done
"$GSTRACE" export "$OUT/cburn.gstrace" --format collapsed -o "$OUT/cburn.folded" 2>/dev/null
check "export collapsed has hot_inner stacks" "grep -q 'hot_outer;hot_inner ' '$OUT/cburn.folded'"
"$GSTRACE" symbolicate "$OUT/cburn.gstrace" --embed >/dev/null 2>&1
check "symbolicate --embed writes symbols plist" "ls '$OUT/cburn.gstrace'/symbols-*.plist >/dev/null 2>&1"
check "embedded symbols still resolve" "'$GSTRACE' report '$OUT/cburn.gstrace' top --limit 1 2>/dev/null | grep -q hot_inner"

echo "== Trace comparison"
check "diff of a trace with itself shows no change" "'$GSTRACE' diff '$OUT/objcwork.gstrace' '$OUT/objcwork.gstrace' 2>/dev/null | grep -E -q '^ .* \+ +0.00 µs +0.0%  \(total\)'"
check "diff --fail-above fails when CPU time grows" "! '$GSTRACE' diff '$OUT/objcwork.gstrace' '$OUT/cburn.gstrace' --fail-above 50 >/dev/null 2>&1"
check "diff --fail-above passes when it shrinks" "'$GSTRACE' diff '$OUT/cburn.gstrace' '$OUT/objcwork.gstrace' --fail-above 50 >/dev/null 2>&1"

echo "== Viewer checks on the checked-in sample trace"
if sh "$ROOT/Tests/viewer-checks.sh" "$GSTRACE" >"$OUT/viewer.log" 2>&1; then
  pass "viewer checks: $(tail -1 "$OUT/viewer.log")"
else
  cat "$OUT/viewer.log"
  fail "viewer checks"
fi

echo "== CLI behaviour"
check "unknown template is rejected" "! '$GSTRACE' record --template Nope --launch /bin/true >/dev/null 2>&1"
check "list templates" "'$GSTRACE' list templates 2>/dev/null | grep -q '^Time Profiler'"
check "setuid targets are refused" "! '$GSTRACE' record --output '$OUT/su.gstrace' --launch /usr/bin/passwd >/dev/null 2>&1"
check "child processes are not traced by default" "[ \$(ls '$OUT/objcwork.gstrace' | grep -c '^events-.*\\.bin') -eq 1 ]"

if [ "${SKIP_GUI:-0}" != 1 ] && command -v Xvfb >/dev/null 2>&1; then
  echo "== AppKit fixture: hangs (Xvfb)"
  DISP=:$((70 + $$ % 20))
  Xvfb $DISP -screen 0 1024x768x24 -nolisten tcp -ac >/dev/null 2>&1 &
  XPID=$!
  timeout 3 sh -c "until [ -e /tmp/.X11-unix/X${DISP#:} ]; do :; done" 2>/dev/null
  DISPLAY=$DISP XAUTHORITY= record hang --template "Time Profiler" --launch "$OUT/hangapp"
  "$GSTRACE" report "$OUT/hang.gstrace" hangs >"$OUT/hang.txt" 2>/dev/null
  check "hangapp: 3 hangs" "grep -q '^3 hang(s)' '$OUT/hang.txt'"
  check "hangapp: microhang 300 ms" "grep -E -q '^Microhang at .*, (29[0-9]|30[0-9]|31[0-9])\\.[0-9]+ ms' '$OUT/hang.txt'"
  check "hangapp: hang 700 ms" "grep -E -q '^Hang at .*, (69[0-9]|70[0-9]|71[0-9])\\.[0-9]+ ms' '$OUT/hang.txt'"
  check "hangapp: severe hang 2.2 s" "grep -E -q '^Severe Hang at .*, 2\\.2[0-9] s' '$OUT/hang.txt'"
  check "hangapp: hang stack shows the busy loop" "grep -q 'HangController tick:' '$OUT/hang.txt'"
  DISPLAY=$DISP XAUTHORITY= record hangleaks --template Leaks --launch "$OUT/hangapp"
  "$GSTRACE" report "$OUT/hangleaks.gstrace" leaks >"$OUT/hangleaks.txt" 2>/dev/null
  check "GUI app leak check stays small (< 100 blocks, no GSCInlineString)" "[ \$(sed -n 2p '$OUT/hangleaks.txt' | cut -d' ' -f1) -lt 100 ] && ! grep -q '^GSCInlineString' '$OUT/hangleaks.txt'"

  if command -v xdotool >/dev/null 2>&1; then
    echo "== Performance Dashboard app (Xvfb, xdotool)"
    APP=$ROOT/Dashboard/PerformanceDashboard.app/PerformanceDashboard
    SAMPLE=$ROOT/Tests/data/sample.gstrace
    TRACES="/tmp/GNUstepSecure$(id -u)/Performance Dashboard"
    # window_id <title> [seconds]: the visible window with that title
    window_id() {
      n=0
      while [ $n -lt "${2:-20}" ]; do
        w=$(DISPLAY=$DISP xdotool search --onlyvisible --name "^$1\$" 2>/dev/null | head -1)
        [ -n "$w" ] && { echo "$w"; return 0; }
        sleep 1; n=$((n + 1))
      done
      return 1
    }
    # wait_app <pid> [seconds]: sets STATUS to the app's exit status, or
    # "running" (and kills it).  Not in $(...): a subshell can't wait.
    wait_app() {
      n=0
      while [ $n -lt "${2:-10}" ] && kill -0 "$1" 2>/dev/null; do sleep 1; n=$((n + 1)); done
      if kill -0 "$1" 2>/dev/null; then kill -9 "$1"; wait "$1" 2>/dev/null; STATUS=running
      else wait "$1"; STATUS=$?; fi
    }
    key() { DISPLAY=$DISP xdotool key --window "$1" "$2"; }

    # Open a trace, Record from it, quit.
    mkdir -p "$TRACES"; touch "$OUT/gui.mark"
    DISPLAY=$DISP XAUTHORITY= "$APP" -GSFilePath "$SAMPLE" >"$OUT/gui.log" 2>&1 &
    APID=$!
    W=$(window_id "objcwork — Custom")
    check "app: opens a trace" "[ -n '$W' ]"
    [ -n "$W" ] && key "$W" ctrl+r
    P=$(window_id "Choose a Profiling Template" 10)
    check "app: Record on an opened trace shows the template chooser" "[ -n '$P' ]"
    # Xvfb has no window manager, so the panel is not the key window and
    # GNUstep takes the first click on it to activate it: click an empty
    # spot, then Record (its centre is 29 points above the content's
    # bottom edge, 656 from the left).
    if [ -n "$P" ]; then
      eval $(DISPLAY=$DISP xdotool getwindowgeometry --shell "$P")
      DISPLAY=$DISP xdotool mousemove --window "$P" 360 $((HEIGHT - 60)) click 1
      sleep 1
      DISPLAY=$DISP xdotool mousemove --window "$P" 656 $((HEIGHT - 29)) click 1
    fi
    check "app: the chooser records into a new window" "window_id 'objcwork — Time Profiler' 10 >/dev/null"
    sleep 3
    NEW=$(find "$TRACES" -maxdepth 1 -name 'objcwork*.gstrace' -newer "$OUT/gui.mark" | head -1)
    check "app: the new recording finished cleanly" "[ -n '$NEW' ] && '$GSTRACE' info '$NEW' 2>/dev/null | grep -q 'finished cleanly: yes'"
    check "app: the opened trace stays open" "window_id 'objcwork — Custom' 1 >/dev/null"
    [ -n "$W" ] && key "$W" ctrl+q
    wait_app $APID
    check "app: Quit exits with status 0 ($STATUS)" "[ $STATUS = 0 ]"
    check "app: no selector type mismatches logged" "! grep -q 'incorrect signature' '$OUT/gui.log'"

    # Quitting under each installed theme, by menu and by SIGTERM.
    for theme in Adwaita Sombre; do
      found=no
      for lib in $(gnustep-config --variable=GNUSTEP_USER_LIBRARY) \
                 $(gnustep-config --variable=GNUSTEP_LOCAL_LIBRARY) \
                 $(gnustep-config --variable=GNUSTEP_SYSTEM_LIBRARY); do
        [ -d "$lib/Themes/$theme.theme" ] && found=yes
      done
      if [ $found = no ]; then
        echo "     ($theme theme not installed; skipped)"
        continue
      fi
      DISPLAY=$DISP XAUTHORITY= "$APP" -GSFilePath "$SAMPLE" -GSTheme $theme >"$OUT/gui-$theme.log" 2>&1 &
      APID=$!
      W=$(window_id "objcwork — Custom")
      [ -n "$W" ] && key "$W" ctrl+q
      wait_app $APID
      check "app ($theme): Quit exits with status 0 ($STATUS)" "[ $STATUS = 0 ]"
      DISPLAY=$DISP XAUTHORITY= "$APP" -GSFilePath "$SAMPLE" -GSTheme $theme >>"$OUT/gui-$theme.log" 2>&1 &
      APID=$!
      window_id "objcwork — Custom" >/dev/null
      sleep 2   # the handler is installed once launching has finished
      kill -TERM $APID
      wait_app $APID
      check "app ($theme): SIGTERM exits with status 0 ($STATUS)" "[ $STATUS = 0 ]"
    done
  else
    echo "== Performance Dashboard app skipped (needs xdotool)"
  fi
  kill $XPID 2>/dev/null
else
  echo "== AppKit fixture skipped"
fi

echo
if [ $FAILED -eq 0 ]; then
  echo "All $PASSED checks passed."
  exit 0
fi
echo "$FAILED of $((PASSED + FAILED)) checks failed."
exit 1
