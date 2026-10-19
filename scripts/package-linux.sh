#!/usr/bin/env bash
# Packages the Linux AppImage from the pinned inputs and runs the release
# checks on it. Adapted from LinDirStat's scripts/package-linux.sh. Nothing
# is signed, tagged or published here (docs/release.md).
#
#   scripts/package-linux.sh [--release] [--version VERSION]
#
# --version packages VERSION instead of package.version (release
# candidates: --version 0.1.0-rc1). --release refuses inputs that are not at
# their pins (GNUSTEP_PACKAGER, ADWAITA_THEME or LIBS_BACK_BUNDLE naming
# another tree); without it they are used with a warning.
#
# Steps: packager manifest-check, build, stage, validate, package (AppImage)
# and validate with the smoke launch on a private Xvfb; then a recording
# made by the AppImage (scripts/check-appimage-record.sh).
#
# Writes to dist/packages: the AppImage, the packager's sidecars, and
# PerformanceDashboard-VERSION-x86_64.provenance.json: the source commit,
# every pin, the build IDs of the Adwaita theme, libs-back and the GNUstep
# libraries inside the AppImage, and each check's result.
set -euo pipefail

release=0
version_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) release=1; shift ;;
    --version) version_override="${2:?--version needs a value}"; shift 2 ;;
    *) sed -n '2,21p' "$0" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
pin="$repo_root/scripts/pinned-checkout.sh"
manifest=packaging/package.manifest.json

die() { echo "package-linux: $*" >&2; exit 1; }
warn() { echo "package-linux: warning: $*" >&2; }

[ "$release" = 0 ] || [ -z "$(git status --porcelain)" ] || die "a release builds only from a clean tree"
if [ "$release" = 1 ]; then
  [ -n "${PD_VERIFIED_TOOLCHAIN_CACHE:-}" ] || die "release builds use ci-release-linux.sh in a clean Debian 13 build home"
  python3 scripts/fetch-toolchain.py "$PD_VERIFIED_TOOLCHAIN_CACHE"
fi

# Inputs. A tree named in the environment may be used for a dry run, but a
# release is built only from trees at their pins.
pin_check() { # name dir
  "$pin" --verify "$1" "$2" && return 0
  [ "$release" = 1 ] && die "a release builds only from the pinned $1 (packaging/release-inputs.json)"
  warn "$1 is not at its pin; this is not a release build"
}
if [ -n "${GNUSTEP_PACKAGER:-}" ]; then
  packager_root="$GNUSTEP_PACKAGER"
  pin_check gnustep-packager "$packager_root"
else
  packager_root="$("$pin" gnustep-packager "$repo_root/out/gnustep-packager")"
fi
packager="$packager_root/scripts/gnustep-packager.ps1"
[ -f "$packager" ] || die "no gnustep-packager at $packager_root (set GNUSTEP_PACKAGER)"
"$repo_root/scripts/fetch-appimagetool.sh" "$packager_root" >/dev/null
if [ -n "${ADWAITA_THEME:-}" ]; then
  pin_check adwaita "$(dirname "$ADWAITA_THEME")"
fi
if [ -n "${LIBS_BACK_BUNDLE:-}" ]; then
  [ "$release" = 1 ] && die "a release builds libs-back from its lock file; unset LIBS_BACK_BUNDLE"
  warn "LIBS_BACK_BUNDLE is set; this is not a release build"
fi

commit="$(git rev-parse HEAD)" || die "cannot read the source commit"
source_dirty=false
[ -z "$(git status --porcelain)" ] || source_dirty=true
source_diff_sha256="$(git diff --binary HEAD | sha256sum | cut -d' ' -f1)"
version="${version_override:-$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["package"]["version"])' "$manifest")}"
version_args=()
[ -n "$version_override" ] && version_args=(-PackageVersion "$version_override")
# A prerelease (0.1.0-rc1) checks the prerelease update feed, from a copy of
# the manifest beside it (its relative paths still resolve).
case "$version" in
  *-*)
    python3 scripts/prerelease-manifest.py "$manifest" packaging/package.manifest.prerelease.json
    manifest=packaging/package.manifest.prerelease.json ;;
esac
packager_commit="$(git -C "$packager_root" rev-parse HEAD)"
echo "package-linux: Performance Dashboard $version from ${commit:0:7}, gnustep-packager ${packager_commit:0:7}"

work="$(mktemp -d "${TMPDIR:-/tmp}/pd-package.XXXXXX")"
xvfb_pid=""
cleanup() {
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# Package and validate. The smoke launch runs on a private display with a
# private GNUstep home.
rm -rf dist/packages
for command in manifest-check build stage validate; do
  pwsh "$packager" -Manifest "$manifest" -Command "$command" "${version_args[@]}"
done
pwsh "$packager" -Manifest "$manifest" -Command package -Backend appimage "${version_args[@]}"

exec 3< <(Xvfb -displayfd 4 -screen 0 1280x800x24 -nolisten tcp 4>&1 2>/dev/null)
xvfb_pid=$!
read -r -t 10 display_number <&3 || die "Xvfb did not start"
mkdir -p "$work/home" "$work/xdg"
DISPLAY=":$display_number" GNUSTEP_HOME="$work/home" XDG_DATA_HOME="$work/xdg" XDG_CONFIG_HOME="$work/xdg" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent \
  pwsh "$packager" -Manifest "$manifest" -Command validate -Backend appimage -RunSmoke "${version_args[@]}"
kill "$xvfb_pid" 2>/dev/null || true
xvfb_pid=""

appimage="dist/packages/PerformanceDashboard-$version-x86_64.AppImage"
[ -f "$appimage" ] || die "packaging did not produce $appimage"

# The release check: the AppImage records a program.
scripts/check-appimage-record.sh "$appimage" || die "the AppImage does not record a program"

# Provenance: what went in, and the build IDs of what came out.
(cd "$work" && "$repo_root/$appimage" --appimage-extract >/dev/null 2>&1) || die "could not extract $appimage"
build_id() { # file
  readelf -n "$1" 2>/dev/null | sed -n 's/^ *Build ID: *//p' | head -1
}
root="$work/squashfs-root/usr"
theme_id="$(build_id "$root/runtime/System/Library/Themes/Adwaita.theme/Adwaita")"
back_id="$(build_id "$root/runtime/System/Library/Bundles/libgnustep-back-032.bundle/libgnustep-back-032")"
app_id="$(build_id "$root/app/PerformanceDashboard.app/PerformanceDashboard")"
agent_id="$(build_id "$root/app/PerformanceDashboard.app/Resources/libgsperf-agent.so")"
[ -n "$theme_id" ] || die "no build ID for the AppImage's Adwaita theme"
[ -n "$back_id" ] || die "no build ID for the AppImage's libs-back"
toolchain_ids="$(for lib in libgnustep-base.so.1.31 libgnustep-gui.so.0.32 libobjc.so.4.6 libdispatch.so; do
  printf '%s=%s\n' "$lib" "$(build_id "$root/runtime/lib/$lib")"
done)"
python3 - "dist/packages/PerformanceDashboard-$version-x86_64.provenance.json" <<PY
import json, sys, pathlib, subprocess, os
inputs = json.load(open("packaging/release-inputs.json"))
lock = json.load(open("packaging/linux/libs-back/libs-back.lock.json"))
toolchain_root = pathlib.Path(os.environ.get("GNUSTEP_CLI_ROOT", str(pathlib.Path.home() / ".local/share/gnustep-cli")))
metadata = {name: json.loads((toolchain_root / name).read_text())
            for name in ("source-lock.json", "component-inventory.json", "toolchain-manifest.json")
            if (toolchain_root / name).exists()}
def pin(name):
    return {k: v for k, v in inputs[name].items() if k != "comment"}
json.dump({
    "package": "PerformanceDashboard",
    "version": "$version",
    "commit": "$commit",
    "sourceDirty": "$source_dirty" == "true",
    "trackedDiffSha256": "$source_diff_sha256",
    "builtBy": "${GITHUB_ACTIONS:+github-actions}" or "local",
    "inputs": {
        "adwaita": pin("adwaita"),
        "gnustep-packager": dict(pin("gnustep-packager"), used="$packager_commit"),
        "appimagetool": pin("appimagetool"),
        "gnustep-toolchain": pin("gnustep-toolchain"),
        "libs-back": {"revision": lock["revision"], "patches": [{"path": p["path"], "sha256": p["sha256"]} for p in lock["patches"]]},
    },
    "buildIds": {"app": "$app_id", "agent": "$agent_id", "adwaita": "$theme_id", "libs-back": "$back_id"},
    # The toolchain the AppImage bundles (the gnustep-cli-new install it was
    # built against), to compare builds made on different machines.
    "toolchainBuildIds": dict(line.split("=", 1) for line in """$toolchain_ids""".split()),
    "toolchainPayloadsVerified": bool(os.environ.get("PD_VERIFIED_TOOLCHAIN_CACHE")),
    "toolchainMetadata": metadata,
    "compiler": subprocess.check_output(["clang", "--version"], text=True).strip(),
    "distributionPackages": subprocess.check_output(["dpkg-query", "-W", "-f=\u0024{Package}=\u0024{Version}\\n"], text=True).splitlines(),
    "checks": {"validate+smoke": "passed", "record": "passed"},
}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
PY
echo "package-linux: $appimage packaged and checked; provenance in dist/packages"
