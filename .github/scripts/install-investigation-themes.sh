#!/usr/bin/env bash
# Test-only themes in the isolated CI GNUstep prefix; no upstream edits.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
adwaita_url=$(python3 -c 'import json; print(json.load(open("packaging/release-inputs.json"))["adwaita"]["url"])')
adwaita_revision=$(python3 -c 'import json; print(json.load(open("packaging/release-inputs.json"))["adwaita"]["revision"])')
install_theme() {
  local name=$1 url=$2 revision=$3 directory="$root/out/gui-theme-$1"
  git clone --quiet --filter=blob:none --no-checkout "$url" "$directory"
  git -C "$directory" checkout --quiet --detach "$revision"
  test "$(git -C "$directory" rev-parse HEAD)" = "$revision"
  make -C "$directory" -j2
  make -C "$directory" install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
  printf 'Installed investigation theme %s at %s\n' "$name" "$revision"
}
install_theme Adwaita "$adwaita_url" "$adwaita_revision"
# Upstream Sombre, pinned for the second-theme investigation regression gate.
install_theme Sombre https://github.com/gnustep/plugins-themes-sombre.git 3d69677546cd6069e2c927f82f4aadef0e026602
