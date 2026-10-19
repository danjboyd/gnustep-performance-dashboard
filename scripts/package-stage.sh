#!/usr/bin/env bash
# Stage the Performance Dashboard payload for gnustep-packager.
# Adapted from LinDirStat's scripts/package-stage.sh.
#
# Layout under <stage-root>:
#   app/PerformanceDashboard.app  the built app bundle (with the recording
#                                 agent, gstrace-helper and its polkit policy
#                                 in Resources)
#   runtime/lib                   bundled shared libraries (libGSPerformance,
#                                 GNUstep, libobjc2, libdispatch and their
#                                 non-host dependencies)
#   runtime/System/Library        GNUstep resources, the back bundle, and the
#                                 Adwaita theme (Themes/Adwaita.theme)
#   runtime/bin                   GNUstep tools (defaults, gpbs, gdnc,
#                                 make_services) and gstrace
#   runtime/etc/GNUstep           a relocatable GNUstep.conf
#   metadata/                     icon and license notices
#
# Inputs (override with environment variables):
#   GNUSTEP_CLI_ROOT   gnustep-cli-new install (~/.local/share/gnustep-cli)
#   ADWAITA_THEME      a built Adwaita.theme (default: built by
#                      scripts/build-adwaita.sh from its pin in
#                      packaging/release-inputs.json)
#   LIBS_BACK_BUNDLE   a built libgnustep-back-032.bundle (default: built by
#                      scripts/build-libs-back.sh from the pinned revision
#                      and patches in packaging/linux/libs-back)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <stage-root>\n' "$0" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage_root="$1"
app_source="$repo_root/Dashboard/PerformanceDashboard.app"
gnustep_root="${GNUSTEP_CLI_ROOT:-$HOME/.local/share/gnustep-cli}"
gnustep_library="$gnustep_root/Local/Library"
gnustep_tools="$gnustep_root/Local/Tools"
# libobjc2 and libdispatch live in the install's lib, which GNUstep.sh does
# not add; the theme and back builds run GNUstep tools that need them.
export LD_LIBRARY_PATH="$gnustep_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

require() {
  if [[ ! -e "$1" ]]; then
    printf 'package-stage: missing %s (%s)\n' "$1" "$2" >&2
    exit 1
  fi
}

if [[ ! -x "$app_source/PerformanceDashboard" ]]; then
  "$repo_root/scripts/package-build.sh"
fi
for built in "$app_source/Resources/libgsperf-agent.so" "$app_source/Resources/gstrace-helper" \
             "$repo_root/GSPerformance/obj/libGSPerformance.so.0" "$repo_root/Tools/gstrace/obj/gstrace"; do
  require "$built" "scripts/package-build.sh"
done

require "$gnustep_library/Libraries/libgnustep-base.so" "gnustep-cli-new GNUstep install; set GNUSTEP_CLI_ROOT"
adwaita_theme="${ADWAITA_THEME:-$("$repo_root/scripts/build-adwaita.sh")}"
require "$adwaita_theme/Adwaita" "pinned Adwaita build (scripts/build-adwaita.sh); or set ADWAITA_THEME"
libs_back_bundle="${LIBS_BACK_BUNDLE:-$("$repo_root/scripts/build-libs-back.sh")}"
require "$libs_back_bundle/libgnustep-back-032" "pinned libs-back build (scripts/build-libs-back.sh); or set LIBS_BACK_BUNDLE"

rm -rf "$stage_root"
runtime="$stage_root/runtime"
system_library="$runtime/System/Library"
mkdir -p "$stage_root/app" "$runtime/bin" "$runtime/lib" "$runtime/etc/GNUstep" \
  "$system_library/Libraries" "$system_library/Themes" \
  "$stage_root/metadata/icons" "$stage_root/metadata/licenses"

cp -R "$app_source" "$stage_root/app/PerformanceDashboard.app"
# gnustep-make's launcher entry points at the build machine's openapp; the
# AppImage writes its own desktop entry.
rm -f "$stage_root/app/PerformanceDashboard.app/Resources/PerformanceDashboard.desktop" \
  "$stage_root/app/PerformanceDashboard.app/stamp.make"

# GNUstep resources: base/gui library resources, the back bundle, images,
# key bindings, colour pickers, fonts and printing support. Headers,
# documentation and make files are build-time only.
for item in Bundles ColorPickers Fonts Images KeyBindings PostScript Services Sounds; do
  if [[ -d "$gnustep_library/$item" ]]; then
    cp -R "$gnustep_library/$item" "$system_library/$item"
  fi
done
for item in gnustep-base gnustep-gui; do
  cp -R "$gnustep_library/Libraries/$item" "$system_library/Libraries/$item"
done
# The back bundle is the pinned, patched libs-back, not the install's.
rm -rf "$system_library/Bundles/libgnustep-back-032.bundle"
cp -R "$libs_back_bundle" "$system_library/Bundles/libgnustep-back-032.bundle"
rm -f "$system_library/Bundles/libgnustep-back-032.bundle/stamp.make"
cp -R "$adwaita_theme" "$system_library/Themes/Adwaita.theme"
rm -f "$system_library/Themes/Adwaita.theme/stamp.make"

# Tools: defaults seeds packaged defaults from AppRun; gpbs and gdnc are the
# pasteboard and distributed-notification servers gnustep-gui starts;
# NSWorkspace runs make_services to build the services cache when the user's
# GNUstep home has none. gstrace is the command-line recorder, for anyone
# who extracts the AppImage.
for tool in defaults gpbs gdnc make_services; do
  cp "$gnustep_tools/$tool" "$runtime/bin/$tool"
done
cp "$repo_root/Tools/gstrace/obj/gstrace" "$runtime/bin/gstrace"
# gstrace looks for the recording agent next to libGSPerformance.
cp "$app_source/Resources/libgsperf-agent.so" "$runtime/lib/libgsperf-agent.so"

# The libraries themselves: this project's framework, then the GNUstep
# install; remaining dependencies come from the host
# (scripts/stage-linux-runtime.py). The recording agent in the app's
# Resources links only libc, so nothing is added for it.
python3 "$repo_root/scripts/stage-linux-runtime.py" "$stage_root" \
  "$repo_root/GSPerformance/obj" "$gnustep_library/Libraries" "$gnustep_root/lib"

# GNUstep.conf with paths relative to itself (gnustep-base resolves './' and
# '../' against the config file's directory), so the AppImage mount point can
# move. AppRun points GNUSTEP_CONFIG_FILE here. The user domain stays in the
# user's home directory as usual.
conf="$runtime/etc/GNUstep/GNUstep.conf"
{
  printf 'GNUSTEP_USER_CONFIG_FILE=.GNUstep.conf\n'
  printf 'GNUSTEP_USER_DEFAULTS_DIR=GNUstep/Defaults\n'
  printf 'GNUSTEP_MAKEFILES=../../System/Library/Makefiles\n'
  for users in SYSTEM NETWORK LOCAL; do
    printf 'GNUSTEP_%s_USERS_DIR=/home\n' "$users"
  done
  for domain in SYSTEM NETWORK LOCAL; do
    printf 'GNUSTEP_%s_APPS=../../System/Applications\n' "$domain"
    printf 'GNUSTEP_%s_ADMIN_APPS=../../System/Applications/Admin\n' "$domain"
    printf 'GNUSTEP_%s_WEB_APPS=../../System/Library/WebApplications\n' "$domain"
    printf 'GNUSTEP_%s_TOOLS=../../bin\n' "$domain"
    printf 'GNUSTEP_%s_ADMIN_TOOLS=../../bin\n' "$domain"
    printf 'GNUSTEP_%s_LIBRARY=../../System/Library\n' "$domain"
    printf 'GNUSTEP_%s_HEADERS=../../System/Library/Headers\n' "$domain"
    printf 'GNUSTEP_%s_LIBRARIES=../../lib\n' "$domain"
    printf 'GNUSTEP_%s_DOC=../../System/Library/Documentation\n' "$domain"
    printf 'GNUSTEP_%s_DOC_MAN=../../System/Library/Documentation/man\n' "$domain"
    printf 'GNUSTEP_%s_DOC_INFO=../../System/Library/Documentation/info\n' "$domain"
  done
  for dir in APPS:Applications ADMIN_APPS:Applications/Admin WEB_APPS:Library/WebApplications \
             TOOLS:Tools ADMIN_TOOLS:Tools/Admin LIBRARY:Library HEADERS:Library/Headers \
             LIBRARIES:Library/Libraries DOC:Library/Documentation \
             DOC_MAN:Library/Documentation/man DOC_INFO:Library/Documentation/info; do
    printf 'GNUSTEP_USER_DIR_%s=GNUstep/%s\n' "${dir%%:*}" "${dir#*:}"
  done
} > "$conf"
# Adwaita as the packaged default theme, with ifUnset semantics: gnustep-base
# reads GlobalDefaults.plist next to GNUstep.conf below the user's own
# NSGlobalDomain and app defaults, so a theme the user picked still wins.
# GSX11HandlesWindowDecorations = NO lets the theme draw the header bar; the
# Control key acts as GNUstep's Command key, so shortcuts are Ctrl+... as in
# GNOME apps.
cat > "$runtime/etc/GNUstep/GlobalDefaults.plist" <<'EOF'
{
  GSTheme = Adwaita;
  GSX11HandlesWindowDecorations = NO;
  GSFirstCommandKey = Control_L;
  GSSecondCommandKey = Control_R;
  GSFirstControlKey = Alt_L;
  GSSecondControlKey = Alt_R;
  GSFirstAlternateKey = Super_L;
  GSSecondAlternateKey = Super_R;
}
EOF
# gnustep-base ignores config files that group or others can write.
chmod 0644 "$conf" "$runtime/etc/GNUstep/GlobalDefaults.plist"

cp "$repo_root/Dashboard/Resources/PerformanceDashboard.png" \
  "$stage_root/metadata/icons/PerformanceDashboard.png"

licenses="$stage_root/metadata/licenses"
# Every notice carries its license text; a missing file stops the stage.
notice() {
  local file="$1" name="$2" license="$3" url="$4" text="${5:-}"
  if [[ -z "$text" || ! -f "$text" ]]; then
    echo "package-stage: license text for $name not found: ${text:-(none given)}" >&2
    exit 1
  fi
  {
    printf '%s\nLicense: %s\nSource: %s\n\n' "$name" "$license" "$url"
    cat "$text"
  } > "$licenses/$file"
}
license_texts="$repo_root/packaging/linux/licenses"
notice PerformanceDashboard.txt "Performance Dashboard, performance analysis for GNUstep applications" \
  "GPL-3.0-or-later" "https://github.com/danjboyd/gnustep-performance-dashboard" "$repo_root/COPYING"
notice GSPerformance.txt "GSPerformance, recording agent, signpost/logging libraries and public headers" \
  "LGPL-2.1-or-later" "https://github.com/danjboyd/gnustep-performance-dashboard" "$repo_root/COPYING.LIB"
notice GNUstep-base.txt "GNUstep Base (libgnustep-base)" "LGPL-2.1-or-later" \
  "https://github.com/gnustep/libs-base" "$license_texts/libs-base-COPYING.LIB"
notice GNUstep-gui.txt "GNUstep GUI (libgnustep-gui)" "LGPL-2.1-or-later" \
  "https://github.com/gnustep/libs-gui" "$license_texts/libs-gui-COPYING.LIB"
notice GNUstep-back.txt "GNUstep Back (libgnustep-back)" "LGPL-2.1-or-later" \
  "https://github.com/gnustep/libs-back" "$license_texts/libs-back-COPYING.LIB"
notice libobjc2.txt "libobjc2 (GNUstep Objective-C runtime)" "MIT" \
  "https://github.com/gnustep/libobjc2" "$license_texts/libobjc2-COPYING"
notice libdispatch.txt "libdispatch (swift-corelibs-libdispatch)" "Apache-2.0" \
  "https://github.com/swiftlang/swift-corelibs-libdispatch" "$license_texts/libdispatch-LICENSE"
notice GNUstep-tools.txt "GNUstep tools: defaults, make_services (libs-base, libs-gui; GPL-3.0-or-later), gpbs (libs-back; GPL-3.0-or-later), gdnc (libs-base; GPL-2.0-or-later)" \
  "GPL-3.0-or-later AND GPL-2.0-or-later" "https://github.com/gnustep" "$license_texts/GPL-3.0.txt"
notice gnustep-packager-updater.txt "gnustep-packager updater (GPUpdaterCore, GPUpdaterUI, gp-update-helper)" "MIT" \
  "https://github.com/danjboyd/gnustep-packager" "$license_texts/gnustep-packager-LICENSE"
notice Monocypher.txt "Monocypher (in gp-update-helper)" "BSD-2-Clause OR CC0-1.0" \
  "https://monocypher.org" "$repo_root/third_party/gnustep-packager-updater/objc/gp-update-helper/Source/monocypher/LICENCE.md"
notice Adwaita-theme.txt "Adwaita GNUstep theme (plugins-themes-adwaita)" "LGPL-2.1-or-later" \
  "https://github.com/danjboyd/plugins-themes-Adwaita" "$adwaita_theme/../COPYING.LIB"

cat > "$stage_root/metadata/stage-summary.json" <<EOF
{
  "app": "PerformanceDashboard.app",
  "defaultTheme": "Adwaita"
}
EOF

printf 'package-stage: staged %s (%s)\n' "$stage_root" "$(du -sh "$stage_root" | cut -f1)"

# A relocatable CLI entry point also scrubs the packaged runtime from targets.
mv "$stage_root/runtime/bin/gstrace" "$stage_root/runtime/bin/gstrace-bin"
install -m 0755 "$repo_root/packaging/linux/gstrace" "$stage_root/runtime/bin/gstrace"
