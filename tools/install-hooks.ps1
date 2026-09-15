# install-hooks.ps1 - point git at the tracked .githooks directory.
#
# The hook itself lives in .githooks/pre-commit and is version-controlled, so a
# fresh clone gets the same guard as this working copy once it runs this script.
# core.hooksPath is used instead of copying into .git/hooks because .git is not
# tracked and a copied hook would silently rot.
#
# Usage: powershell -File tools\install-hooks.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  if (-not (Test-Path (Join-Path $root '.git'))) {
    throw "not a git checkout: $root"
  }
  $hook = Join-Path $root '.githooks/pre-commit'
  if (-not (Test-Path $hook)) { throw "missing $hook" }

  & git config core.hooksPath .githooks
  if ($LASTEXITCODE -ne 0) { throw "git config core.hooksPath failed" }

  # Git for Windows runs hooks through sh, which needs the executable bit - and
  # a Windows checkout has no way to set it. Git applies its own heuristic, but
  # being explicit costs nothing. --add is required while the hook is still
  # untracked; without it git refuses with "cannot add to the index".
  try { & git update-index --add --chmod=+x .githooks/pre-commit 2>&1 | Out-Null } catch { }

  Write-Host ''
  Write-Host '  hooks installed' -ForegroundColor Green
  Write-Host "  core.hooksPath = .githooks"
  Write-Host "  pre-commit     = enforce UTF-8 BOM + PS 5.1 parse on staged .ps1 files"
  Write-Host ''
} finally {
  Pop-Location
}
