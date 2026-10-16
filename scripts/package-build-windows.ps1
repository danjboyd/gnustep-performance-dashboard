# Builds Performance Dashboard on Windows for the packager's build step, with
# GNU make in the MSYS2 CLANG64 environment that holds the GNUstep toolchain:
# gnustep-packager's gnustep-cli-new root (GP_GNUSTEP_CLI_ROOT) on its
# hosted runners, else MSYS2 itself. Adapted from ScreenshotTool's
# scripts/build_release.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-MsysRoot {
  foreach ($candidate in @($env:GP_GNUSTEP_CLI_ROOT, $env:GNUSTEP_CLI_ROOT, $env:MSYS2_LOCATION, "C:\msys64")) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  throw "MSYS2 root not found. Set MSYS2_LOCATION before running the Windows packaging build."
}

$msysRoot = Resolve-MsysRoot
$bashExe = Join-Path $msysRoot "usr\bin\bash.exe"
if (-not (Test-Path $bashExe)) { throw "MSYS2 bash not found at $bashExe." }
$clang64Root = Join-Path $msysRoot "clang64"
$gnustepSh = @(
  (Join-Path $clang64Root "share\GNUstep\Makefiles\GNUstep.sh"),
  (Join-Path $clang64Root "System\Library\Makefiles\GNUstep.sh")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($null -eq $gnustepSh) { throw "GNUstep.sh not found under $clang64Root." }

# gnustep-base 1.31.1 puts __block on an instance variable, which newer clang
# rejects (gnustep/libs-base#809); CI makes the same change (ci.yml).
$scheduler = Join-Path $clang64Root "include\Foundation\NSBackgroundActivityScheduler.h"
if ((Test-Path $scheduler) -and (Select-String -Path $scheduler -SimpleMatch "BLOCK_SCOPE GSScheduledBlock _block;" -Quiet)) {
  (Get-Content -Raw $scheduler).Replace("BLOCK_SCOPE GSScheduledBlock _block;", "GSScheduledBlock _block;") |
    Set-Content -NoNewline $scheduler
  Write-Host "Patched $scheduler (gnustep/libs-base#809)"
}

$env:MSYSTEM = "CLANG64"
# HAVE_MODE_T: MSYS2's libdispatch headers redefine mode_t without it.
$command = "set -eo pipefail; cd `"`$(cygpath -u '$repoRoot')`"; set +u; " +
  "source `"`$(cygpath -u '$gnustepSh')`"; set -u; export ADDITIONAL_CPPFLAGS=-DHAVE_MODE_T; make"
& $bashExe -lc $command
if ($LASTEXITCODE -ne 0) { throw "The build failed with exit code $LASTEXITCODE." }
