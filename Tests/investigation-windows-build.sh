#!/usr/bin/env bash
# Invoked by investigation-windows-checks.ps1 with the selected toolchain.
set -eo pipefail
cd "$(dirname "$0")/.."
source "$PD_TOOLCHAIN/clang64/share/GNUstep/Makefiles/GNUstep.sh"
mkdir -p "$PD_GUI_OUTPUT"
clang $(gnustep-config --objc-flags) -DHAVE_MODE_T -fobjc-arc -Wno-protocol -I. -IRuntime/include \
  Tests/GUI/InvestigationChecks.m Tests/Unit/TraceBuilder.m \
  Dashboard/PDInvestigationWindowController.m Dashboard/PDInspectorView.m \
  Dashboard/PDSourceWindowController.m Dashboard/PDTheme.m \
  Dashboard/PDDetailController.m Dashboard/PDTrackRenderer.m Dashboard/PDTimelineView.m \
  -LGSPerformance/obj -lGSPerformance $(gnustep-config --gui-libs) \
  -o "$PD_GUI_OUTPUT/checks.exe"
