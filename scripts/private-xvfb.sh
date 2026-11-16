#!/usr/bin/env bash
# Source this file. The caller owns/reaps xvfb_pid through its existing trap.
pd_start_private_xvfb() {
  local pd_display="${PD_PRIVATE_X_DISPLAY:-:151}"
  local pd_log="$1"
  if [[ ! "$pd_display" =~ ^:([1-9][0-9]*)$ ]] || [[ "$pd_display" == :120 ]]; then
    printf 'private-xvfb: require an explicit numeric display other than :0/:120\n' >&2
    return 1
  fi
  if [[ -e "/tmp/.X${pd_display#:}-lock" || -e "/tmp/.X11-unix/X${pd_display#:}" ]]; then
    printf 'private-xvfb: refusing occupied display %s\n' "$pd_display" >&2
    return 1
  fi
  Xvfb "$pd_display" -screen 0 1280x800x24 -nolisten tcp >"$pd_log" 2>&1 &
  xvfb_pid=$!
  display_number="${pd_display#:}"
  printf 'private-xvfb: display=%s owned_pid=%s log=%s\n' "$pd_display" "$xvfb_pid" "$pd_log" >&2
  python3 - "$pd_display" "$xvfb_pid" <<'PY'
import ctypes, os, sys, time
from pathlib import Path
lib = ctypes.CDLL('libX11.so.6')
lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
lib.XOpenDisplay.restype = ctypes.c_void_p
lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
for _ in range(100):
    os.kill(int(sys.argv[2]), 0)
    state = Path('/proc', sys.argv[2], 'stat').read_text().split(') ', 1)[1].split()[0]
    if state == 'Z':
        raise SystemExit('private-xvfb: owned child exited')
    display = lib.XOpenDisplay(sys.argv[1].encode())
    if display:
        lib.XCloseDisplay(display)
        break
    time.sleep(.1)
else:
    raise SystemExit('private-xvfb: owned display readiness timeout')
PY
}
