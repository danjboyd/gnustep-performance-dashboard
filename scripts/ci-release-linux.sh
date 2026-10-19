#!/usr/bin/env bash
# The release workflow's Linux job (.github/workflows/release.yml), on a
# clean Debian 13 container: the gnustep-cli-new toolchain from its pinned
# bootstrap, PowerShell for gnustep-packager from its pin in
# packaging/release-inputs.json, then scripts/package-linux.sh --release.
# Collects the unsigned release files in dist/ci/linux. Adapted from
# LinDirStat's scripts/ci-release-linux.sh. Nothing is signed or published.
#
#   scripts/ci-release-linux.sh [VERSION]   # default: package.version
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
pin="$repo_root/scripts/pinned-checkout.sh"
work="${CI_WORK:-${RUNNER_TEMP:-/tmp}/pd-ci}"
gnustep_root="$HOME/.local/share/gnustep-cli"
mkdir -p "$work"

die() { echo "ci-release-linux: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

version_args=()
[ -n "${1:-}" ] && version_args=(--version "$1")

step "GNUstep toolchain (gnustep-cli-new v0.1.0)"
[ ! -e "$gnustep_root" ] || die "use a clean build home; an existing toolchain is not release provenance"
python3 scripts/fetch-toolchain.py "$work/toolchain"
sh "$work/toolchain/gnustep-bootstrap.sh" --yes --json setup --user \
  --manifest "$work/toolchain/release-manifest.json"
export PD_VERIFIED_TOOLCHAIN_CACHE="$work/toolchain"

step "PowerShell $("$pin" --field powershell version)"
if ! command -v pwsh >/dev/null 2>&1; then
  archive="$work/powershell.tar.gz"
  curl -fsSL -o "$archive" "$("$pin" --field powershell url)"
  echo "$("$pin" --field powershell sha256)  $archive" | sha256sum -c -
  mkdir -p "$work/powershell"
  tar -xzf "$archive" -C "$work/powershell"
  chmod +x "$work/powershell/pwsh"
  export PATH="$work/powershell:$PATH"
fi
pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

step "Package and check"
# No FUSE in a container: AppImages extract themselves and run from there.
export APPIMAGE_EXTRACT_AND_RUN=1
scripts/package-linux.sh --release "${version_args[@]}"

step "Collect"
out="dist/ci/linux"
rm -rf "$out"
mkdir -p "$out"
for pattern in '*.AppImage' '*.AppImage.zsync' '*.update-feed.json' '*.provenance.json'; do
  # shellcheck disable=SC2086
  set -- dist/packages/$pattern
  [ -f "$1" ] || die "packaging did not produce $pattern"
  cp "$@" "$out/"
done
ls -l "$out"
