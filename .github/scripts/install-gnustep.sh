#!/usr/bin/env bash
# Builds the clang/libobjc2 GNUstep stack Performance Dashboard is tested
# against, plus tools-xctest for the unit tests, into $PREFIX (GNUstep
# filesystem layout). The workflow caches $PREFIX, keyed on this file.

set -euo pipefail

PREFIX=${PREFIX:?set PREFIX to the install directory}
SRC=${SRC:-${RUNNER_TEMP:-/tmp}/gnustep-src}
JOBS=$(nproc)

LIBOBJC2_TAG=v2.3
MAKE_TAG=make-2_9_3
BASE_TAG=base-1_31_1
GUI_TAG=gui-0_32_0
BACK_TAG=back-0_32_0
XCTEST_TAG=v0.5.1

export CC=clang CXX=clang++
mkdir -p "$SRC"

clone() {
  git clone -q --depth 1 --branch "$3" "https://github.com/$1/$2.git" "$SRC/$2"
}

echo "::group::libobjc2 $LIBOBJC2_TAG"
clone gnustep libobjc2 "$LIBOBJC2_TAG"
git -C "$SRC/libobjc2" submodule update -q --init --depth 1
cmake -S "$SRC/libobjc2" -B "$SRC/libobjc2/build" -G Ninja \
  -DTESTS=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DGNUSTEP_INSTALL_TYPE=NONE -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=System/Library/Libraries
cmake --build "$SRC/libobjc2/build"
cmake --install "$SRC/libobjc2/build"
echo "::endgroup::"

LIBS="$PREFIX/System/Library/Libraries"
export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$LIBS -fuse-ld=lld"
export LD_LIBRARY_PATH="$LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "::group::gnustep-make $MAKE_TAG"
clone gnustep tools-make "$MAKE_TAG"
(cd "$SRC/tools-make" &&
  ./configure --prefix="$PREFIX" --with-layout=gnustep \
    --with-library-combo=ng-gnu-gnu --with-runtime-abi=gnustep-2.2 &&
  make install)
echo "::endgroup::"

set +u
# shellcheck disable=SC1091
. "$PREFIX/System/Library/Makefiles/GNUstep.sh"
set -u

for lib in "libs-base $BASE_TAG" "libs-gui $GUI_TAG" "libs-back $BACK_TAG"; do
  set -- $lib
  echo "::group::$1 $2"
  clone gnustep "$1" "$2"
  (cd "$SRC/$1" && ./configure && make -j"$JOBS" && make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM)
  echo "::endgroup::"
done

echo "::group::tools-xctest $XCTEST_TAG"
clone danjboyd tools-xctest "$XCTEST_TAG"
(cd "$SRC/tools-xctest" && make && make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM)
echo "::endgroup::"
