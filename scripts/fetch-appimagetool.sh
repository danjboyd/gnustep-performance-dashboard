#!/usr/bin/env bash
# Installs the appimagetool pinned in packaging/release-inputs.json into a
# gnustep-packager checkout, where its AppImage backend looks for it
# (tools/appimage/appimagetool-x86_64.AppImage), so the backend neither
# downloads its moving default nor reuses an older copy. The backend also
# takes the AppImage runtime from this file.
#
#   scripts/fetch-appimagetool.sh PACKAGER_ROOT
#
# The download is cached in APPIMAGETOOL_CACHE (out/appimagetool) and checked
# against the pinned sha256 every time.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 ]] || { sed -n '2,11p' "$0" >&2; exit 2; }
packager_root="$1"
cache="${APPIMAGETOOL_CACHE:-$repo_root/out/appimagetool}"
pin="$repo_root/scripts/pinned-checkout.sh"

die() { printf 'fetch-appimagetool: %s\n' "$*" >&2; exit 1; }
sha256() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

url="$("$pin" --field appimagetool url)"
expected="$("$pin" --field appimagetool sha256)"
file="$cache/$("$pin" --field appimagetool version)/appimagetool-x86_64.AppImage"

if [[ ! -f "$file" ]] || [[ "$(sha256 "$file")" != "$expected" ]]; then
  mkdir -p "$(dirname "$file")"
  curl -fsSL -o "$file.part" "$url" || die "could not download $url"
  mv "$file.part" "$file"
fi
actual="$(sha256 "$file")"
[[ "$actual" == "$expected" ]] || die "$url has sha256 $actual, release-inputs.json says $expected"

[[ -d "$packager_root/backends/appimage" ]] || die "no gnustep-packager at $packager_root"
mkdir -p "$packager_root/tools/appimage"
install -m 755 "$file" "$packager_root/tools/appimage/appimagetool-x86_64.AppImage"
printf '%s\n' "$packager_root/tools/appimage/appimagetool-x86_64.AppImage"
