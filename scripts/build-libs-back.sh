#!/usr/bin/env bash
# Builds the libs-back the Linux AppImage ships, from
# packaging/linux/libs-back/libs-back.lock.json: the pinned upstream revision
# with the patches next to it, against the gnustep-cli-new install.
#
#   scripts/build-libs-back.sh        # prints the built bundle's path
#
# Inputs (environment): GNUSTEP_CLI_ROOT (~/.local/share/gnustep-cli) and
# LIBS_BACK_BUILD_DIR, where the checkout lives (out/libs-back). Each run
# resets the checkout to the pinned revision, checks every patch against its
# sha256 and applies them in order.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_dir="$repo_root/packaging/linux/libs-back"
lock="$lock_dir/libs-back.lock.json"
gnustep_root="${GNUSTEP_CLI_ROOT:-$HOME/.local/share/gnustep-cli}"
build_dir="${LIBS_BACK_BUILD_DIR:-$repo_root/out/libs-back}"

die() { printf 'build-libs-back: %s\n' "$*" >&2; exit 1; }
field() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print("\n".join(v) if isinstance(v, list) else v)' "$lock" "$1"; }

[[ -f "$gnustep_root/System/Library/Makefiles/GNUstep.sh" ]] || die "no gnustep-cli-new install at $gnustep_root (set GNUSTEP_CLI_ROOT)"
url="$(field url)"
revision="$(field revision)"
mapfile -t configure_args < <(field configure)
mapfile -t make_args < <(field make)

if [[ ! -d "$build_dir/.git" ]]; then
  mkdir -p "$(dirname "$build_dir")"
  git clone --quiet --no-checkout "$url" "$build_dir" >&2
fi
git -C "$build_dir" cat-file -e "$revision^{commit}" 2>/dev/null || git -C "$build_dir" fetch --quiet origin >&2
git -C "$build_dir" checkout --quiet --force --detach "$revision"
git -C "$build_dir" clean --quiet -fdx

while IFS=$'\t' read -r path sha256; do
  patch="$lock_dir/$path"
  [[ -f "$patch" ]] || die "missing patch $path"
  actual="$(sha256sum "$patch" | cut -d' ' -f1)"
  [[ "$actual" == "$sha256" ]] || die "$path has sha256 $actual, the lock file says $sha256"
  git -C "$build_dir" apply "$patch" || die "$path does not apply to $revision"
done < <(python3 -c 'import json, sys
for p in json.load(open(sys.argv[1]))["patches"]:
    print(p["path"] + "\t" + p["sha256"])' "$lock")

(
  cd "$build_dir"
  set +u
  # shellcheck disable=SC1091
  . "$gnustep_root/System/Library/Makefiles/GNUstep.sh"
  set -u
  export PKG_CONFIG_PATH="$gnustep_root/lib/pkgconfig:$gnustep_root/Local/Library/Libraries/pkgconfig"
  ./configure "${configure_args[@]}" > "$build_dir/configure.out" 2>&1 || { tail -20 "$build_dir/configure.out" >&2; exit 1; }
  # GNUstep Base's headers name themselves in assertions (__FILE__), which
  # put the install's path, under the build user's home, into the bundle;
  # mapped to a fixed name, builds on different machines are identical.
  prefix_map="-fmacro-prefix-map=$gnustep_root=/gnustep-cli"
  make -j"$(nproc)" "${make_args[@]}" AUXILIARY_OBJCFLAGS="$prefix_map" AUXILIARY_CFLAGS="$prefix_map" \
    > "$build_dir/make.out" 2>&1 || { tail -20 "$build_dir/make.out" >&2; exit 1; }
) || die "the build failed (logs in $build_dir)"

bundle="$build_dir/Source/libgnustep-back-032.bundle"
[[ -x "$bundle/libgnustep-back-032" ]] || die "no bundle at $bundle"
printf '%s\n' "$bundle"
