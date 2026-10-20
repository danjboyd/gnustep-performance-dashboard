#!/usr/bin/env bash
# Invoked by package-build-windows.ps1 in the selected CLANG64 toolchain.
set -eo pipefail
cd "$(dirname "$0")/.."
set +u
source "$(cygpath -u "$PD_BUILD_GNUSTEP_SH")"
set -u
# MSYS2 libdispatch headers otherwise redefine mode_t.
export ADDITIONAL_CPPFLAGS=-DHAVE_MODE_T
if [ "${PD_BUILD_CLEAN:-0}" = 1 ]; then
  make clean
fi
make
