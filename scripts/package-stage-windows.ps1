# Stages Performance Dashboard for the MSI (gnustep-packager's stage step on
# Windows). Adapted from ScreenshotTool's scripts/stage_release.ps1.
#
#   app/PerformanceDashboard.app   the app (PerformanceDashboard.exe, the
#                                  recording agent gsperf-agent.dll in
#                                  Resources)
#   runtime/bin                    the DLLs the programs import (by import
#                                  closure from CLANG64), libGSPerformance,
#                                  gstrace.exe, defaults.exe, GNUstep.conf
#   runtime/System/Library         GNUstep resources and bundles
#   runtime/System/Tools           gdnc, gpbs, make_services
#   metadata/                      icons and license notices
#
#   scripts/package-stage-windows.ps1 -StageRoot dist/stage
param(
  [string]$StageRoot = "dist/stage"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$stage = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $StageRoot))
$appSource = Join-Path $repoRoot "Dashboard\PerformanceDashboard.app"
$runtime = Join-Path $stage "runtime"
$runtimeBin = Join-Path $runtime "bin"
$metadata = Join-Path $stage "metadata"
$licenses = Join-Path $metadata "licenses"
$licenseTexts = Join-Path $repoRoot "packaging\linux\licenses"

function Ensure-Directory([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return $Path
}

function Copy-Tree([string]$Source, [string]$Destination) {
  if (-not (Test-Path $Source)) { return $false }
  Ensure-Directory $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
  return $true
}

function Resolve-MsysRoot {
  foreach ($candidate in @($env:GP_GNUSTEP_CLI_ROOT, $env:GNUSTEP_CLI_ROOT, $env:MSYS2_LOCATION, "C:\msys64")) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  throw "MSYS2 root not found. Set MSYS2_LOCATION before staging the Windows payload."
}

$exe = Join-Path $appSource "PerformanceDashboard.exe"
if (-not (Test-Path $exe)) { throw "No built app at $exe; run scripts/package-build-windows.ps1 first." }
foreach ($built in @((Join-Path $appSource "Resources\gsperf-agent.dll"), (Join-Path $repoRoot "Tools\gstrace\obj\gstrace.exe"))) {
  if (-not (Test-Path $built)) { throw "Missing $built; run scripts/package-build-windows.ps1 first." }
}

$clang64 = Join-Path (Resolve-MsysRoot) "clang64"
if (-not (Test-Path $clang64)) { throw "MSYS2 CLANG64 root not found at $clang64." }

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
foreach ($dir in @($runtimeBin, (Join-Path $stage "app"), (Join-Path $metadata "icons"), $licenses)) {
  Ensure-Directory $dir | Out-Null
}

# The app, without gnustep-make's build stamp.
Copy-Tree $appSource (Join-Path $stage "app\PerformanceDashboard.app") | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "app\PerformanceDashboard.app\stamp.make")

# This project's own DLL and the command-line recorder.
Get-ChildItem -Path (Join-Path $repoRoot "GSPerformance\obj") -Filter "*.dll" -File |
  ForEach-Object { Copy-Item $_.FullName (Join-Path $runtimeBin $_.Name) -Force }
Copy-Item (Join-Path $repoRoot "Tools\gstrace\obj\gstrace.exe") (Join-Path $runtimeBin "gstrace.exe") -Force
# gstrace looks for the recording agent next to the GSPerformance DLL.
Copy-Item (Join-Path $appSource "Resources\gsperf-agent.dll") (Join-Path $runtimeBin "gsperf-agent.dll") -Force

# GNUstep: fonts configuration, the back bundle and the gui's shared resources.
Copy-Tree (Join-Path $clang64 "etc\fonts") (Join-Path $runtime "etc\fonts") | Out-Null
Copy-Tree (Join-Path $clang64 "lib\GNUstep\Bundles") (Join-Path $runtime "System\Library\Bundles") | Out-Null
Get-ChildItem -Path (Join-Path $runtime "System\Library\Bundles") -Directory -Filter "*.prefPane" -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force
foreach ($name in @("Images", "KeyBindings", "Fonts", "ColorPickers", "PostScript", "DTDs", "Services", "Sounds")) {
  Copy-Tree (Join-Path $clang64 "lib\GNUstep\$name") (Join-Path $runtime "System\Library\$name") | Out-Null
}
foreach ($name in @("gnustep-base", "gnustep-gui")) {
  Copy-Tree (Join-Path $clang64 "lib\GNUstep\Libraries\$name") (Join-Path $runtime "System\Library\Libraries\$name") | Out-Null
}

# defaults seeds the packaged defaults; gdnc, gpbs and make_services are
# started by gnustep-base and gnustep-gui on demand (without gdnc the app
# exits before showing a window).
Copy-Item (Join-Path $clang64 "bin\defaults.exe") (Join-Path $runtimeBin "defaults.exe") -Force
$tools = Ensure-Directory (Join-Path $runtime "System\Tools")
foreach ($tool in @("gdnc.exe", "gpbs.exe", "make_services.exe")) {
  $source = Join-Path $clang64 "bin\$tool"
  if (-not (Test-Path $source)) { throw "GNUstep tool $tool not found at $source" }
  Copy-Item $source (Join-Path $tools $tool) -Force
}

# The DLLs the staged programs import, and theirs, from CLANG64 into
# runtime/bin (the launcher puts it on PATH). Seeds: every .exe and .dll in
# the stage, the bundles GNUstep loads with LoadLibrary and the recording
# agent included. A DLL not in CLANG64 is taken as Windows' own;
# gnustep-packager's closure check fails the build on any other.
$objdump = @((Join-Path $clang64 "bin\llvm-objdump.exe"), (Join-Path $clang64 "bin\objdump.exe")) |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if ($null -eq $objdump) { throw "objdump not found under $clang64\bin." }
$available = @{}
foreach ($dir in @((Join-Path $clang64 "bin"), (Join-Path $clang64 "lib"))) {
  foreach ($file in Get-ChildItem -Path $dir -Filter "*.dll" -File -ErrorAction SilentlyContinue) {
    if (-not $available.ContainsKey($file.Name)) { $available[$file.Name] = $file.FullName }
  }
}
$queue = [System.Collections.Generic.Queue[string]]::new()
foreach ($file in Get-ChildItem -Path $stage -Recurse -File -Include *.dll, *.exe) { $queue.Enqueue($file.FullName) }
$seen = @{}
$copied = 0
while ($queue.Count -gt 0) {
  $target = $queue.Dequeue()
  if ($seen.ContainsKey($target)) { continue }
  $seen[$target] = $true
  foreach ($line in & $objdump -p $target 2>$null) {
    if ($line -notmatch 'DLL Name:\s+(\S+)') { continue }
    $name = $Matches[1]
    if (-not $available.ContainsKey($name)) { continue }
    $destination = Join-Path $runtimeBin $name
    if (-not (Test-Path $destination)) {
      Copy-Item $available[$name] $destination -Force
      $copied++
    }
    $queue.Enqueue($destination)
  }
}
$global:LASTEXITCODE = 0
Write-Host "Staged $copied runtime DLLs by import closure"

# The toolchain's own DLLs must not ride along (they once made an MSI 245 MB).
$forbidden = @(Get-ChildItem -Path $runtime -Recurse -File |
  Where-Object { $_.Name -match '^(libLLVM|libclang|libLTO|libRemarks|libpython|tcl\d|tk\d)' })
if ($forbidden.Count -gt 0) {
  throw ("Toolchain DLLs staged into the runtime: {0}" -f (($forbidden | ForEach-Object Name) -join ", "))
}

# GNUstep.conf next to gnustep-base's DLL, with paths relative to it. The
# packager stages the bundled themes under runtime/lib/GNUstep/Themes: that is
# the Local domain's library.
$sys = "../System"
$conf = @("GNUSTEP_USER_CONFIG_FILE=")
foreach ($domain in @("SYSTEM", "NETWORK", "LOCAL")) {
  $conf += "GNUSTEP_${domain}_ROOT=$sys"
  $conf += "GNUSTEP_${domain}_APPS=$sys/Applications"
  $conf += "GNUSTEP_${domain}_ADMIN_APPS=$sys/Applications/Admin"
  $conf += "GNUSTEP_${domain}_WEB_APPS=$sys/Library/WebApplications"
  $conf += "GNUSTEP_${domain}_TOOLS=$sys/Tools"
  $conf += "GNUSTEP_${domain}_ADMIN_TOOLS=$sys/Tools/Admin"
  $conf += "GNUSTEP_${domain}_LIBRARY=" + $(if ($domain -eq "LOCAL") { "../lib/GNUstep" } else { "$sys/Library" })
  $conf += "GNUSTEP_${domain}_LIBRARIES=$sys/Library/Libraries"
  $conf += "GNUSTEP_${domain}_HEADERS=$sys/Library/Headers"
  $conf += "GNUSTEP_${domain}_DOC=$sys/Library/Documentation"
  $conf += "GNUSTEP_${domain}_DOC_MAN=$sys/Library/Documentation/man"
  $conf += "GNUSTEP_${domain}_DOC_INFO=$sys/Library/Documentation/info"
}
Set-Content -Path (Join-Path $runtimeBin "GNUstep.conf") -Value $conf -Encoding ascii

Copy-Item (Join-Path $repoRoot "Dashboard\Resources\PerformanceDashboard.ico") (Join-Path $metadata "icons\PerformanceDashboard.ico") -Force
Copy-Item (Join-Path $repoRoot "Dashboard\Resources\PerformanceDashboard.png") (Join-Path $metadata "icons\PerformanceDashboard.png") -Force

# Every notice carries its license text; a missing file stops the stage.
function Write-Notice([string]$File, [string]$Name, [string]$License, [string]$Url, [string]$Text) {
  if (-not (Test-Path $Text)) { throw "License text for $Name not found: $Text" }
  $body = "$Name`nLicense: $License`nSource: $Url`n`n" + (Get-Content -Raw $Text)
  Set-Content -Path (Join-Path $licenses $File) -Value $body -Encoding utf8
}
Write-Notice "PerformanceDashboard.txt" "Performance Dashboard, performance analysis for GNUstep applications" `
  "LGPL-2.1-or-later" "https://github.com/danjboyd/gnustep-performance-dashboard" (Join-Path $repoRoot "COPYING.LIB")
Write-Notice "GNUstep-base.txt" "GNUstep Base (libgnustep-base)" "LGPL-2.1-or-later" `
  "https://github.com/gnustep/libs-base" (Join-Path $licenseTexts "libs-base-COPYING.LIB")
Write-Notice "GNUstep-gui.txt" "GNUstep GUI (libgnustep-gui)" "LGPL-2.1-or-later" `
  "https://github.com/gnustep/libs-gui" (Join-Path $licenseTexts "libs-gui-COPYING.LIB")
Write-Notice "GNUstep-back.txt" "GNUstep Back (libgnustep-back)" "LGPL-2.1-or-later" `
  "https://github.com/gnustep/libs-back" (Join-Path $licenseTexts "libs-back-COPYING.LIB")
Write-Notice "GNUstep-tools.txt" "GNUstep tools: defaults, make_services (libs-base, libs-gui; GPL-3.0-or-later), gpbs (libs-back; GPL-3.0-or-later), gdnc (libs-base; GPL-2.0-or-later)" `
  "GPL-3.0-or-later AND GPL-2.0-or-later" "https://github.com/gnustep" (Join-Path $licenseTexts "GPL-3.0.txt")
Write-Notice "libobjc2.txt" "libobjc2 (GNUstep Objective-C runtime)" "MIT" `
  "https://github.com/gnustep/libobjc2" (Join-Path $licenseTexts "libobjc2-COPYING")
Write-Notice "libdispatch.txt" "libdispatch (swift-corelibs-libdispatch)" "Apache-2.0" `
  "https://github.com/swiftlang/swift-corelibs-libdispatch" (Join-Path $licenseTexts "libdispatch-LICENSE")
Write-Notice "gnustep-packager-updater.txt" "gnustep-packager updater (GPUpdaterCore, GPUpdaterUI, gp-update-helper)" "MIT" `
  "https://github.com/danjboyd/gnustep-packager" (Join-Path $licenseTexts "gnustep-packager-LICENSE")
Write-Notice "Monocypher.txt" "Monocypher (in gp-update-helper)" "BSD-2-Clause OR CC0-1.0" `
  "https://monocypher.org" (Join-Path $repoRoot "third_party\gnustep-packager-updater\objc\gp-update-helper\Source\monocypher\LICENCE.md")
Write-Notice "WinUITheme.txt" "WinUITheme, the default Windows theme (plugins-themes-winuitheme)" "LGPL-2.1-or-later" `
  "https://github.com/danjboyd/plugins-themes-winuitheme" (Join-Path $licenseTexts "libs-gui-COPYING.LIB")
$clangDlls = @(Get-ChildItem -Path $runtimeBin -Filter "*.dll" -File | Where-Object { $_.Name -notmatch '^(libgnustep-|libobjc|dispatch|libdispatch|GSPerformance|libGSPerformance)' } | ForEach-Object Name | Sort-Object)
Set-Content -Path (Join-Path $licenses "msys2-libraries.txt") -Encoding utf8 -Value (
  @("Libraries from MSYS2 CLANG64 (https://packages.msys2.org) bundled in runtime/bin, each under its own",
    "license as packaged by MSYS2 (see the package pages for the license texts):", "") + $clangDlls)

$size = (Get-ChildItem -Path $stage -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("Staged {0} ({1:N1} MB)" -f $stage, ($size / 1MB))
