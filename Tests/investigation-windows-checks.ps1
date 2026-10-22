# Native controller assertions and window captures. No input injection or desktop capture.
[CmdletBinding()]
param(
  [string]$ToolchainRoot = 'dist/verified-toolchain',
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [string]$Output = 'Tests/out/investigations-windows'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$toolchain = (Resolve-Path -LiteralPath $ToolchainRoot).Path
$runtime = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$configuration = Join-Path $runtime 'bin/GNUstep.conf'
if (-not (Test-Path -LiteralPath $configuration)) { throw "Missing runtime configuration: $configuration" }
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$outputPath = (Resolve-Path -LiteralPath $Output).Path
$env:PD_TOOLCHAIN = $toolchain.Replace('\', '/')
$env:PD_GUI_OUTPUT = $outputPath.Replace('\', '/')
$env:MSYSTEM = 'CLANG64'
$env:CHERE_INVOKING = '1'
$env:Path = "$toolchain/clang64/bin;$toolchain/usr/bin;" + $env:Path
& (Join-Path $toolchain 'usr/bin/bash.exe') 'Tests/investigation-windows-build.sh'
if ($LASTEXITCODE -ne 0) { throw "Controller build failed: $LASTEXITCODE" }
$env:GNUSTEP_CONFIG_FILE = $configuration
$env:GNUSTEP_PATHPREFIX_LIST = $runtime
$env:Path = (Resolve-Path 'GSPerformance/obj').Path + ";$runtime/bin;" + $env:Path
Add-Type -AssemblyName System.Drawing
if (-not ('PDWindowsCapture' -as [type])) { Add-Type -Path 'Tests/GUI/WindowsCapture.cs' }
$stdout = Join-Path $outputPath 'checks.stdout.log'
$stderr = Join-Path $outputPath 'checks.stderr.log'
$process = Start-Process -FilePath (Join-Path $outputPath 'checks.exe') -ArgumentList '-GSTheme','WinUITheme' `
  -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
# Retain the handle so ExitCode survives a fast process exit.
[void]$process.Handle
$deadline = [DateTime]::UtcNow.AddSeconds(60)
$captures = @{}
try {
  while (-not $process.HasExited) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Controller assertions timed out.' }
    foreach ($window in [PDWindowsCapture]::Windows($process.Id)) {
      $label = $window.Title -replace '[^a-zA-Z0-9-]', '_'
      if (-not $label) { continue }
      $r = $window.Bounds
      $bitmap = [Drawing.Bitmap]::new($r.Right-$r.Left, $r.Bottom-$r.Top)
      $graphics = [Drawing.Graphics]::FromImage($bitmap)
      $context = $graphics.GetHdc()
      try { $ok = [PDWindowsCapture]::PrintWindow($window.Handle, $context, 2) }
      finally { $graphics.ReleaseHdc($context) }
      try {
        if ($ok) {
          $bitmap.Save((Join-Path $outputPath ($label+'.png')))
          $captures[$label] = $true
        }
      } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    Start-Sleep -Milliseconds 80
  }
  $process.WaitForExit()
  $exitCode = $process.ExitCode
  $text = Get-Content -LiteralPath $stdout -Raw
  Get-Content -LiteralPath $stderr
  Write-Output $text
  if ($exitCode -ne 0) { throw "Controller assertions failed: $exitCode" }
  if ($text -notmatch '(?m)^All (?<count>[1-9][0-9]*) investigation GUI checks passed\.\s*$') { throw 'Missing final assertion summary.' }
  $assertionCount = [int]$Matches['count']
  if ($captures.Count -lt 4) { throw "Expected four captured controller windows; found $($captures.Count)." }
  [ordered]@{
    sourceCommit = (& git rev-parse HEAD)
    sourceDirty = [bool](& git status --porcelain)
    theme = 'WinUITheme'
    assertions = $assertionCount
    exitCode = $exitCode
    capturedWindows = @($captures.Keys | Sort-Object)
    interaction = 'AppKit events; no physical input or file-picker acceptance'
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputPath 'result.json') -Encoding UTF8
} finally {
  if (-not $process.HasExited) { Stop-Process -Id $process.Id }
}
