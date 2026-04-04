[CmdletBinding()]
param(
  [switch]$PreflightOnly,
  [switch]$SkipVerify,
  [string]$EnvFile = "install.env"
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string]$Message)
  Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Escape-BashSingleQuoted {
  param([string]$Value)
  return ($Value -replace "'", "'""'""'")
}

$repoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installSh = Join-Path $repoDir "install.sh"
$envPath = Join-Path $repoDir $EnvFile

if (-not (Test-Path $installSh)) {
  Write-Error "install.sh not found in $repoDir"
  exit 1
}

$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
  Write-Error "WSL is required on Windows. Install it once with 'wsl --install', reboot, then run this script again."
  exit 1
}

Write-Step "Preparing WSL launch"
$wslRepoDir = (& wsl.exe wslpath -a "$repoDir").Trim()
$wslEnvPath = (& wsl.exe wslpath -a "$envPath").Trim()

if (-not $wslRepoDir) {
  Write-Error "Could not convert the repository path to a WSL path."
  exit 1
}

$bashLines = @(
  "set -euo pipefail",
  "cd '$(Escape-BashSingleQuoted $wslRepoDir)'",
  "chmod +x ./install.sh"
)

if ($EnvFile) {
  $bashLines += "export ENV_FILE='$(Escape-BashSingleQuoted $wslEnvPath)'"
}

if ($PreflightOnly) {
  $bashLines += "export PREFLIGHT_ONLY=1"
}

if ($SkipVerify) {
  $bashLines += "export SKIP_VERIFY=1"
}

$bashLines += "./install.sh"
$bashCommand = ($bashLines -join "; ")

Write-Step "Running installer inside WSL"
& wsl.exe bash -lc $bashCommand
exit $LASTEXITCODE
