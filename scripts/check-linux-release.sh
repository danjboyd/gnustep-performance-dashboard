#!/usr/bin/env bash
# Reproducible local gates; source GNUstep.sh first. Does not publish.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
for tool in gcc clang Xvfb xdotool import gnustep-config; do
  command -v "$tool" >/dev/null || { echo "Missing release-check dependency: $tool" >&2; exit 1; }
done
[ -x /usr/bin/time ] || { echo "Install GNU time for the soak measurements." >&2; exit 1; }
if [ "${SKIP_GUI:-0}" = 1 ]; then
  echo "Release checks require GUI checks; unset SKIP_GUI." >&2; exit 1
fi
for theme in Adwaita Sombre; do
  found=0
  for domain in USER LOCAL SYSTEM; do
    library=$(gnustep-config --variable="GNUSTEP_${domain}_LIBRARY")
    [ ! -d "$library/Themes/$theme.theme" ] || found=1
  done
  [ "$found" = 1 ] || { echo "Install the $theme theme before release checks." >&2; exit 1; }
done
out="$root/Tests/out/release"
mkdir -p "$out"
git rev-parse HEAD >"$out/commit.txt"
git diff --binary HEAD >"$out/working-tree.patch"
git ls-files --others --exclude-standard >"$out/untracked-files.txt"
date -u +%FT%TZ >"$out/date.txt"
uname -a >"$out/host.txt"
python3 Tests/private-home-checks.py 2>&1 | tee "$out/private-home.log"
sh Tests/run.sh 2>&1 | tee "$out/regression.log"
# The development suite permits missing UI facilities; the release gate does not.
if grep -Ei 'skipped|shortcuts do not reach' "$out/regression.log"; then
  echo "Release gate failed: a regression check was skipped." >&2; exit 1
fi
sh Tests/open-trace-gui-checks.sh 2>&1 | tee "$out/open-trace.log"
sh Tests/investigation-gui-checks.sh 2>&1 | tee "$out/investigations.log"
bash Tests/compiler-checks.sh 2>&1 | tee "$out/compilers.log"
bash Tests/soak-check.sh 60 2>&1 | tee "$out/soak.log"
echo "Automated Linux release checks passed. Review theme screenshots in Tests/out."
echo "Package, clean-machine, real-app and update acceptance remain separate gates (docs/v0.1.0-plan.md)."
