#!/usr/bin/env bash
# Checks out one input from packaging/release-inputs.json at its pinned
# revision, or checks that an existing tree is at it.
#
#   scripts/pinned-checkout.sh NAME DIR          # clone or reset DIR to the pin
#   scripts/pinned-checkout.sh --verify NAME DIR # DIR must be a clean tree at the pin
#   scripts/pinned-checkout.sh --field NAME KEY  # print url, tag or revision
#
# NAME is adwaita or gnustep-packager (--field also reads
# appimagetool, a download: url, version, sha256). When the pin has a tag,
# the tag is fetched and must point at the revision, so a moved tag fails
# rather than building something else. The checkout prints DIR.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inputs="$repo_root/packaging/release-inputs.json"

die() { printf 'pinned-checkout: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" >&2; exit 2; }
field() {
  python3 -c 'import json, sys
pin = json.load(open(sys.argv[1])).get(sys.argv[2])
if pin is None:
    sys.exit("pinned-checkout: no input " + sys.argv[2] + " in " + sys.argv[1])
value = pin.get(sys.argv[3])
print("" if value is None else value)' "$inputs" "$1" "$2"
}

mode=checkout
case "${1:-}" in
  --verify) mode=verify; shift ;;
  --field) [[ $# -eq 3 ]] || usage; field "$2" "$3"; exit 0 ;;
esac
[[ $# -eq 2 ]] || usage
name="$1"
dir="$2"
url="$(field "$name" url)"
tag="$(field "$name" tag)"
revision="$(field "$name" revision)"

if [[ "$mode" == verify ]]; then
  [[ -d "$dir" ]] || die "$name: no tree at $dir"
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || die "$name: $dir is not a git checkout"
  [[ "$head" == "$revision" ]] || die "$name: $dir is at ${head:0:9}, the pin is ${tag:-$revision} (${revision:0:9})"
  [[ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ]] || die "$name: $dir has local changes"
  exit 0
fi

if [[ ! -d "$dir/.git" ]]; then
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" remote add origin "$url"
fi
if [[ -n "$tag" ]]; then
  git -C "$dir" fetch --quiet --force --depth 1 origin "refs/tags/$tag:refs/tags/$tag" >&2
  [[ "$(git -C "$dir" rev-parse "refs/tags/$tag^{commit}")" == "$revision" ]] ||
    die "$name: tag $tag is not at $revision; release-inputs.json and the tag disagree"
fi
git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null ||
  git -C "$dir" fetch --quiet --depth 1 origin "$revision" >&2
git -C "$dir" checkout --quiet --force --detach "$revision"
git -C "$dir" clean --quiet -fdx
printf '%s\n' "$dir"
