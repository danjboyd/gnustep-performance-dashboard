#!/usr/bin/env bash
# Builds Performance Dashboard (runtime, framework, gstrace, helper, app)
# with GNUstep Make against the gnustep-cli-new install, for the packager's
# build step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

gnustep_root="${GNUSTEP_CLI_ROOT:-$HOME/.local/share/gnustep-cli}"
if [[ ! -f "$gnustep_root/System/Library/Makefiles/GNUstep.sh" ]]; then
  printf 'package-build: no gnustep-cli-new install at %s; set GNUSTEP_CLI_ROOT\n' "$gnustep_root" >&2
  exit 1
fi
set +u
# shellcheck disable=SC1091
. "$gnustep_root/System/Library/Makefiles/GNUstep.sh"
set -u
# libobjc2 and libdispatch live in the install's lib, which GNUstep.sh does
# not add; the build runs GNUstep tools (pl2link) that need them.
export LD_LIBRARY_PATH="$gnustep_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Objects made against a different GNUstep installation are not reusable:
# make does not know that the toolchain/environment changed.
make -C "$repo_root" clean
make -C "$repo_root"
