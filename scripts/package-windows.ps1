# Build unsigned MSI/ZIP review artifacts. No tags, publication or feed deployment.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$ToolchainRoot = "dist/verified-toolchain",
  [switch]$Release,
  [switch]$SkipBuild
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
if ($Version -notmatch '^\d+\.\d+\.\d+-[A-Za-z0-9.-]+$') { throw 'Use an unpublished prerelease version for Windows qualification.' }
if ($Release -and (& git status --porcelain)) { throw 'Release artifacts require a clean source tree.' }
if ($Release -and $SkipBuild) { throw 'Release artifacts cannot skip the build.' }
if (Test-Path -LiteralPath 'dist/ci/windows') { throw 'Archive the existing dist/ci/windows before starting another producer run.' }
if (@(Get-ChildItem dist/packages -File -ErrorAction SilentlyContinue).Count) {
  throw 'Archive existing dist/packages before starting another producer run.'
}
$inputs = Get-Content -Raw packaging/release-inputs.json | ConvertFrom-Json
$toolchainSourcePin = (Get-Content -Raw packaging/windows-core-sources.json | ConvertFrom-Json).toolchainSourceRevision
$themePin = (Get-Content -Raw packaging/package.manifest.json | ConvertFrom-Json).platformOverrides.windows.themeInputs[0].ref

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
function Get-PinnedSource([string]$Directory, [string]$Url, [string]$Revision) {
  if (-not (Test-Path -LiteralPath $Directory)) {
    # Preserve recipe/patch bytes. Hosted Windows Git defaults can rewrite
    # upstream CRLF patches and make an otherwise pinned checkout dirty.
    Invoke-Checked git @('clone', '--no-checkout', '--config', 'core.autocrlf=false', '--filter=blob:none', '--', $Url, $Directory)
    # This pin contains a mixed-ending patch despite '*.patch text eol=lf'.
    # Disable text transforms in clone-local metadata before checkout. Git's
    # clean-tree check then compares exact bytes, including that patch.
    Set-Content -LiteralPath (Join-Path $Directory '.git/info/attributes') -Value '* -text' -Encoding ascii
    Invoke-Checked git @('-C', $Directory, 'checkout', '--detach', $Revision)
  }
  $actual = & git -C $Directory rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $actual -ne $Revision -or (& git -C $Directory status --porcelain)) {
    throw "Source must be clean at $Revision : $Directory"
  }
}
Get-PinnedSource out/gnustep-packager $inputs.'gnustep-packager'.url $inputs.'gnustep-packager'.revision
Get-PinnedSource out/gnustep-cli-new 'https://github.com/danjboyd/gnustep-cli-new.git' $toolchainSourcePin
Get-PinnedSource out/WinUITheme 'https://github.com/danjboyd/plugins-themes-winuitheme.git' $themePin
Invoke-Checked python @('scripts/fetch-toolchain.py', '--platform', 'windows', 'dist/toolchain-windows')
$toolchain = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ToolchainRoot))
if (-not (Test-Path -LiteralPath $toolchain)) {
  New-Item -ItemType Directory -Path $toolchain | Out-Null
  Invoke-Checked (Join-Path $env:SystemRoot 'System32/tar.exe') @('-xf', 'dist/toolchain-windows/gnustep-toolchain-windows-amd64-msys2-clang64-0.1.1.zip', '-C', $toolchain)
} elseif ($Release) {
  throw 'Release builds require a new toolchain extraction. Choose an unused ToolchainRoot.'
}
$env:GP_GNUSTEP_CLI_ROOT = $toolchain
$env:GNUSTEP_CLI_ROOT = $toolchain
$env:GNUSTEP_MAKEFILES = Join-Path $toolchain 'clang64/share/GNUstep/Makefiles'
$env:GNUSTEP_CONFIG_FILE = Join-Path $toolchain 'clang64/etc/GNUstep/GNUstep.conf'
$env:MSYSTEM = 'CLANG64'
$env:PD_BUILD_CLEAN = if ($Release) { '1' } else { '0' }
$env:PATH = (Join-Path $toolchain 'clang64/bin') + ';' + (Join-Path $toolchain 'usr/bin') + ';' + $env:PATH
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
if (-not $SkipBuild) { Invoke-Checked $pwsh @('-NoProfile', '-File', 'scripts/package-build-windows.ps1') }
Invoke-Checked $pwsh @('-NoProfile', '-File', 'scripts/package-stage-windows.ps1', '-AllowMissingLicenseTexts')
Invoke-Checked python @('scripts/prepare-windows-sources.py', '--stage', 'dist/stage', '--toolchain-source', 'out/gnustep-cli-new', '--output', 'out/windows-sources')
Invoke-Checked $pwsh @('-NoProfile', '-File', 'scripts/package-stage-windows.ps1')
Invoke-Checked python @('scripts/prerelease-manifest.py', 'packaging/package.manifest.json', 'packaging/package.manifest.prerelease.json')
$packager = 'out/gnustep-packager/scripts/gnustep-packager.ps1'
foreach ($step in @('host-preflight', 'provision')) {
  Invoke-Checked $pwsh @('-NoProfile', '-File', $packager, '-Manifest', 'packaging/package.manifest.prerelease.json',
    '-Backend', 'msi', '-Platform', 'windows', '-PackageVersion', $Version, '-Command', $step)
}
# Provisioning can add runtime dependencies. Verify the resulting payload too.
Invoke-Checked python @('scripts/windows-runtime-inventory.py', '--stage', 'dist/stage', '--toolchain', $toolchain)
Invoke-Checked $pwsh @('-NoProfile', '-File', 'out/gnustep-packager/scripts/run-packaging-pipeline.ps1',
  '-Manifest', 'packaging/package.manifest.prerelease.json', '-Backend', 'msi', '-Platform', 'windows',
  '-PackageVersion', $Version, '-SkipBuild', '-SkipStage', '-SkipHostPreflight', '-SkipProvision', '-RunSmoke')
Invoke-Checked python @('scripts/record-windows-provenance.py', '--version', $Version)
$output = Join-Path $repoRoot 'dist/ci/windows'
if (Test-Path -LiteralPath $output) { throw "Collection output already exists: $output" }
New-Item -ItemType Directory -Path $output | Out-Null
foreach ($pattern in @('*.msi', '*-portable.zip', '*.update-feed.json', '*.provenance.json')) {
  $files = @(Get-ChildItem dist/packages -Filter $pattern -File)
  if ($files.Count -ne 1) { throw "Expected exactly one $pattern; found $($files.Count)" }
  Copy-Item -LiteralPath $files[0].FullName -Destination $output
}
Invoke-Checked python @('scripts/collect-windows-sources.py', '--version', $Version)
$commit = & git rev-parse HEAD
if ($Release) {
  Invoke-Checked python @('scripts/assemble-release.py', '--input', $output, '--output', 'dist/ci/windows-validated',
    '--version', $Version, '--commit', $commit, '--require-backend', 'msi')
}
Get-ChildItem -LiteralPath $output -File | Get-FileHash -Algorithm SHA256 | Format-Table Hash,Path
