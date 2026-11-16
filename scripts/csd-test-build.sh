#!/usr/bin/env bash
# Future local/CI CSD harness: uninstalled XCTest, no SDK/host installs.
# Usage: bash scripts/csd-test-build.sh ABS_SDK ABS_XCTEST ABS_UNUSED_EVIDENCE
set -euo pipefail
[[ $# == 3 ]] || { echo 'usage: csd-test-build.sh ABS_SDK ABS_XCTEST ABS_UNUSED_EVIDENCE' >&2; exit 2; }
pd_sdk="$1"; pd_xctest="$2"; pd_evidence="$3"
pd_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for pd_path in "$pd_sdk" "$pd_xctest" "$pd_evidence"; do
  [[ "$pd_path" == /* && "$pd_path" != *[[:space:]]* ]] || { echo 'CSD harness requires absolute paths without whitespace' >&2; exit 1; }
done
[[ ! -e "$pd_evidence" ]] || { echo 'CSD harness refuses stale evidence output' >&2; exit 1; }
[[ -f "$pd_xctest/xctest.make" && -x "$pd_xctest/obj/xctest" ]] || { echo 'build the reviewed runner serially first, without install' >&2; exit 1; }
mkdir -p "$pd_evidence/logs"
unset GNUSTEP_CONFIG_FILE GNUSTEP_MAKEFILES GNUSTEP_PATHLIST LD_LIBRARY_PATH CPPFLAGS CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS LDFLAGS PKG_CONFIG_PATH
set +u
. "$pd_sdk/System/Library/Makefiles/GNUstep.sh"
set -u
export GNUSTEP_CLI_ROOT="$pd_sdk"
export PATH="$pd_xctest/obj:$pd_sdk/System/Tools:$pd_sdk/Local/Tools:$pd_sdk/bin:$PATH"
cp -a "$GNUSTEP_MAKEFILES" "$pd_evidence/makefiles"
mkdir -p "$pd_evidence/makefiles/Auxiliary"
cp "$pd_xctest/xctest.make" "$pd_evidence/makefiles/Auxiliary/xctest.make"
export GNUSTEP_MAKEFILES="$pd_evidence/makefiles"
export XCTEST_INCLUDE_DIR="$pd_xctest" XCTEST_LIBRARY_DIR="$pd_xctest/XCTest/obj"
export LD_LIBRARY_PATH="$XCTEST_LIBRARY_DIR:$pd_sdk/Local/Library/Libraries:$pd_sdk/lib:$pd_sdk/lib64"
# Config files can reset an environment variable. Command-line make variables
# are authoritative, and MAKEFLAGS carries the same values to nested makes.
export MAKEFLAGS="-j2 messages=yes GNUSTEP_MAKEFILES=$GNUSTEP_MAKEFILES XCTEST_INCLUDE_DIR=$XCTEST_INCLUDE_DIR XCTEST_LIBRARY_DIR=$XCTEST_LIBRARY_DIR"
printf 'GNUSTEP_MAKEFILES=%s\nXCTEST_INCLUDE_DIR=%s\nXCTEST_LIBRARY_DIR=%s\nMAKEFLAGS=%s\n' \
 "$GNUSTEP_MAKEFILES" "$XCTEST_INCLUDE_DIR" "$XCTEST_LIBRARY_DIR" "$MAKEFLAGS" >"$pd_evidence/make-overrides.txt"
make -C "$pd_repo/Tests/Unit" check -j2 GNUSTEP_MAKEFILES="$GNUSTEP_MAKEFILES" \
 XCTEST_INCLUDE_DIR="$XCTEST_INCLUDE_DIR" XCTEST_LIBRARY_DIR="$XCTEST_LIBRARY_DIR" >"$pd_evidence/logs/unit.log" 2>&1
SKIP_GUI=1 bash "$pd_repo/Tests/run.sh" >"$pd_evidence/logs/headless.log" 2>&1
