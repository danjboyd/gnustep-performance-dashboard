#!/bin/bash
# Native welcome checks. The gui mode uses the suite's owned private Xvfb.
set -eo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if ! python3 "$repo/scripts/with-private-home.py" --check; then
  parent=$(mktemp -d "${TMPDIR:-/tmp}/pd-welcome-home.XXXXXX")
  exec python3 "$repo/scripts/with-private-home.py" "$parent/sandbox" -- bash "$0" "$@"
fi
mkdir -p "$repo/Tests/out"
work=$(mktemp -d "$repo/Tests/out/welcome-check.XXXXXX")
result=0
export TRELLIS_ROOT="${TRELLIS_ROOT:-$repo/out/gnustep-trellis}"
export LD_LIBRARY_PATH="$repo/GSPerformance/obj:$TRELLIS_ROOT/obj:${LD_LIBRARY_PATH:-}"
case "${1:-}" in
  argv)
    clang $(gnustep-config --objc-flags) -fobjc-arc -fblocks \
      -I"$repo" -I"$repo/Runtime/include" "$repo/Tests/welcome-argv-probe.m" \
      "$repo/Dashboard/PDWelcomeArguments.m" "$repo/Dashboard/PDWelcomeModel.m" \
      -L"$repo/GSPerformance/obj" -lGSPerformance $(gnustep-config --base-libs) -o "$work/argv-probe"
    "$work/argv-probe" -PDAppOnly preserved --launch /bin/true \
      -GSFilePath /tmp/unintended.gstrace -GSTheme target-theme
    ;;
  gui)
    python3 - <<'OWNED'
import os
from pathlib import Path
assert os.environ.get('DISPLAY') == ':151', 'welcome probe requires private display151'
pid = os.environ.get('PD_OWNED_XVFB_PID', '')
assert pid.isdigit(), 'suite-owned Xvfb PID required'
args = Path('/proc', pid, 'cmdline').read_bytes().split(b'\0')
assert Path(os.fsdecode(args[0])).name == 'Xvfb' and b':151' in args, 'not the suite Xvfb'
OWNED
    bash "$repo/Tests/build-welcome-probe.sh" "$work/WelcomeProbe.app"
    for theme in Adwaita Sombre; do
      theme_path=""
      if [ "$theme" = Adwaita ]; then theme_path="${ADWAITA_TEST_THEME:-}"; else theme_path="${SOMBRE_TEST_THEME:-}"; fi
      if [ -z "$theme_path" ]; then
        for domain in USER LOCAL SYSTEM; do
          library=$(gnustep-config --variable="GNUSTEP_${domain}_LIBRARY")
          if [ -d "$library/Themes/$theme.theme" ]; then theme_path="$library/Themes/$theme.theme"; break; fi
        done
      fi
      [ -d "$theme_path" ] || { echo "welcome probe: missing $theme theme" >&2; exit 2; }
      # Each probe changes defaults; copy the selected theme into the project
      # work area so it remains readable inside the next private home.
      cp -RL "$theme_path" "$work/$theme.theme"
      if ! python3 "$repo/scripts/with-private-home.py" "$work/$theme-home" -- \
        "$work/WelcomeProbe.app/WelcomeProbe" "$work/$theme.theme" "$work/$theme.png"; then
        echo "welcome probe failed ($theme); continuing with the next theme" >&2
        result=1
      fi
    done
    ;;
  *) echo 'usage: check-welcome.sh argv|gui' >&2; exit 2 ;;
esac
echo "Welcome evidence: $work"
exit "$result"
