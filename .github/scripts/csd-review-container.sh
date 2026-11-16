#!/usr/bin/env bash
# Runs only in the ephemeral Debian13 review image, never on a developer host.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'explicit hosted CI environment required' >&2; exit 1; }
pd_repo="$(git rev-parse --show-toplevel)"
pd_work="$pd_repo/out/csd-ci"
pd_builder="$pd_work/builder"
pd_sdk="$pd_work/sdk"
pd_lock="$pd_repo/packaging/linux/v017-custom-toolchain.lock.proposed.json"
pd_state="$pd_work/container-inputs.json"
pd_policy="$pd_repo/.github/scripts/csd-review-state.py"
pd_final="$pd_repo/.github/scripts/csd-review-final.py"
[[ "${CSD_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-review(\.[0-9]+)?$ ]]
[[ "$(git -C "$pd_builder" rev-parse HEAD)" == 4d5504bbedf076f824c952f4ab198d09547c8c3c ]]
mkdir -p "$pd_work/logs"
case "${1:-}" in
  sdk)
    if [[ "${SDK_CACHE_HIT:-false}" != true ]]; then
      [[ ! -e "$pd_sdk" ]] || { echo 'non-cache SDK prefix already exists; refusing replacement' >&2; exit 1; }
      MAKEFLAGS="messages=yes" python3 "$pd_builder/scripts/internal/build_infra.py" --json build-custom-toolchain \
        --lock "$pd_lock" --prefix "$pd_sdk" --jobs 2 >"$pd_work/logs/sdk-build.log" 2>&1
      python3 "$pd_policy" build-sources --root "$pd_repo" --prefix "$pd_sdk" --output "$pd_sdk/pd-csd-build-sources.json"
      cp "$pd_work/.sdk-build/sources/libs-back/config.h" "$pd_sdk/pd-backend-config.h"
      cp "$pd_work/.sdk-build/logs/libs-back.log" "$pd_sdk/pd-backend-build.log"
    fi
    # Repeat on fresh AND restored SDKs before any receipt/cache save.
    python3 "$pd_policy" closure --root "$pd_repo" \
      --backend "$pd_sdk/Local/Library/Bundles/libgnustep-back-032.bundle/libgnustep-back-032" \
      --log "$pd_sdk/pd-backend-build.log" --output "$pd_work/logs/backend-closure.json"
    if [[ "${SDK_CACHE_HIT:-false}" != true ]]; then
      python3 "$pd_policy" sdk-verify --root "$pd_repo" --prefix "$pd_sdk" --state "$pd_state" --write-receipt
    fi
    python3 "$pd_policy" sdk-verify --root "$pd_repo" --prefix "$pd_sdk" --state "$pd_state"
    ;;
  review)
    python3 "$pd_policy" sdk-verify --root "$pd_repo" --prefix "$pd_sdk" --state "$pd_state"
    pd_theme="$pd_work/theme"
    bash "$pd_repo/scripts/pinned-checkout.sh" adwaita "$pd_theme" >"$pd_work/logs/theme-checkout.log" 2>&1
    # A new phase shell; builder strips host compile/search overrides too.
    unset GNUSTEP_CONFIG_FILE GNUSTEP_MAKEFILES GNUSTEP_PATHLIST LD_LIBRARY_PATH \
      CPPFLAGS CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS LDFLAGS PKG_CONFIG_PATH
    set +u
    . "$pd_sdk/System/Library/Makefiles/GNUstep.sh"
    set -u
    export GNUSTEP_CLI_ROOT="$pd_sdk"
    export PATH="$pd_sdk/System/Tools:$pd_sdk/Local/Tools:$pd_sdk/bin:$PATH"
    pd_tests="$pd_work/tools-xctest"
    git init -q "$pd_tests"
    git -C "$pd_tests" remote add origin https://github.com/danjboyd/tools-xctest.git
    git -C "$pd_tests" fetch -q --depth 1 origin 8ff9317d54e6bee57dc266cd9ba288c426790b40
    git -C "$pd_tests" checkout -q --detach 8ff9317d54e6bee57dc266cd9ba288c426790b40
    [[ "$(git -C "$pd_tests" rev-parse HEAD)" == 8ff9317d54e6bee57dc266cd9ba288c426790b40 ]]
    # Build runner serially; use a separate makefiles copy instead of mutating the SDK/cache.
    make -C "$pd_tests" -j1 >"$pd_work/logs/xctest-build.log" 2>&1
    cp -a "$GNUSTEP_MAKEFILES" "$pd_work/test-makefiles"
    export GNUSTEP_MAKEFILES="$pd_work/test-makefiles"
    export XCTEST_INCLUDE_DIR="$pd_tests" XCTEST_LIBRARY_DIR="$pd_tests/XCTest/obj"
    export MAKEFLAGS="-j2 messages=yes GNUSTEP_MAKEFILES=$GNUSTEP_MAKEFILES XCTEST_INCLUDE_DIR=$XCTEST_INCLUDE_DIR XCTEST_LIBRARY_DIR=$XCTEST_LIBRARY_DIR"
    mkdir -p "$GNUSTEP_MAKEFILES/Auxiliary"
    cp "$pd_tests/xctest.make" "$GNUSTEP_MAKEFILES/Auxiliary/"
    export PATH="$pd_tests/obj:$PATH"
    export CPATH="$pd_tests"
    export LIBRARY_PATH="$pd_tests/XCTest/obj"
    export LD_LIBRARY_PATH="$pd_tests/XCTest/obj:$pd_sdk/lib:$pd_sdk/Local/Library/Libraries"
    pd_map="-fmacro-prefix-map=$pd_sdk=/gnustep-cli"
    make -C "$pd_theme" -j2 AUXILIARY_OBJCFLAGS="$pd_map" AUXILIARY_CFLAGS="$pd_map" >"$pd_work/logs/theme-build.log" 2>&1
    python3 "$pd_policy" theme-receipt --root "$pd_repo" --prefix "$pd_sdk" --theme "$pd_theme" \
      --log "$pd_work/logs/theme-build.log" --output "$pd_work/theme-receipt.json"
    # The source builder keeps per-component logs outside the immutable prefix.
    # Cache hits must also retain the original linker log for this hard gate.
    python3 "$pd_policy" closure --root "$pd_repo" \
      --backend "$pd_sdk/Local/Library/Bundles/libgnustep-back-032.bundle/libgnustep-back-032" \
      --log "$pd_sdk/pd-backend-build.log" --output "$pd_work/logs/backend-closure.json"
    pd_archive="$pd_work/powershell.tar.gz"
    curl -fsSL -o "$pd_archive" "$(bash scripts/pinned-checkout.sh --field powershell url)"
    echo "$(bash scripts/pinned-checkout.sh --field powershell sha256)  $pd_archive" | sha256sum -c -
    mkdir -p "$pd_work/powershell"
    tar -xzf "$pd_archive" -C "$pd_work/powershell"
    chmod +x "$pd_work/powershell/pwsh"
    export PATH="$pd_work/powershell:$PATH"
    bash scripts/pinned-checkout.sh gnustep-packager "$pd_work/packager" >"$pd_work/logs/packager-checkout.log" 2>&1
    export GNUSTEP_PACKAGER="$pd_work/packager"
    export PD_CSD_BACKEND_LINK_LOG="$pd_sdk/pd-backend-build.log"
    export PD_CSD_TOOLCHAIN_LOCK="$pd_lock"
    export LIBS_BACK_BUNDLE="$pd_sdk/Local/Library/Bundles/libgnustep-back-032.bundle"
    export ADWAITA_THEME="$pd_theme/Adwaita.theme"
    export PD_CSD_BACKEND_SHA256="$(sha256sum "$LIBS_BACK_BUNDLE/libgnustep-back-032" | cut -d' ' -f1)"
    export PD_CSD_ADWAITA_SHA256="$(sha256sum "$ADWAITA_THEME/Adwaita" | cut -d' ' -f1)"
    export PD_CSD_ADWAITA_BUILD_RECEIPT="$pd_work/theme-receipt.json"
    export APPIMAGE_EXTRACT_AND_RUN=1
    bash scripts/package-linux.sh --version "$CSD_VERSION" >"$pd_work/logs/package.log" 2>&1
    make -j2 >"$pd_work/logs/application-build.log" 2>&1
    make -C Tests/Unit check -j2 GNUSTEP_MAKEFILES="$GNUSTEP_MAKEFILES" XCTEST_INCLUDE_DIR="$XCTEST_INCLUDE_DIR" XCTEST_LIBRARY_DIR="$XCTEST_LIBRARY_DIR" >"$pd_work/logs/unit.log" 2>&1
    SKIP_GUI=1 bash Tests/run.sh >"$pd_work/logs/headless.log" 2>&1
    python3 "$pd_final" extract --root "$pd_repo" --version "$CSD_VERSION" --packages dist/packages \
      --extracted "$pd_work/final-appimage" --output "$pd_work/logs/payload-closure.json"
    python3 "$pd_final" prepare --root "$pd_repo" --version "$CSD_VERSION" \
      --packages dist/packages --directory dist/ci/csd-review
    python3 scripts/collect-csd-sources.py --version "$CSD_VERSION" --output dist/ci/csd-review \
      --receipt-output "$pd_work/logs/sources-verification.json" >"$pd_work/logs/source-collection.log" 2>&1
    cp "$pd_state" "$pd_work/theme-receipt.json" "$pd_work/logs/backend-closure.json" \
      "$pd_work/logs/payload-closure.json" "$pd_work/logs/sources-verification.json" \
      "$pd_sdk/pd-csd-cache-receipt.json" dist/ci/csd-review/
    python3 "$pd_final" assemble --root "$pd_repo" --version "$CSD_VERSION" --directory dist/ci/csd-review
    python3 "$pd_final" verify --root "$pd_repo" --version "$CSD_VERSION" --directory dist/ci/csd-review \
      >"$pd_work/logs/review-receipt.sha256"
    ;;
  *) echo 'usage: csd-review-container.sh sdk|review' >&2; exit 2 ;;
esac
