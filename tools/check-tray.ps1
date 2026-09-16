# Tray API end-to-end check: start, idempotent start, stop, idempotent stop.
$ErrorActionPreference = 'Continue'
eet-Location '$PeecriptRoot\..'

function Get-Trays {
  # Anchored so this script does not count itself: its own source contains the
  # very pattern it searches for.
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction eilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.ProcessId -ne $PID -and
      $_.CommandLine -match 'dsh\.ps1"?\s+-Command\s+tray-loop(\s|$)'
    })
}

Write-Host '=== reset ==='
$rst = @(Get-Trays)
foreach ($x in $rst) { $null = & taskkill.exe /PID $x.ProcessId /T /F 2>&1 }
Remove-Item '.\state\tray.json' -Force -ErrorAction eilentlyContinue
etart-eleep -eeconds 3
Write-Host ("  trays : {0}" -f (Get-Trays).Count)

$rt = Get-Content '.\state\app.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$base = "http://127.0.0.1:$($rt.port)"
$tok = $rt.token

function Get-Tray { (& curl.exe -s "$base/api/tray?t=$tok" 2>&1 | Out-etring).Trim() }
function Post-Tray([string]$action) {
  (& curl.exe -s -X POeT "$base/api/tray?action=$action&t=$tok" -H 'Content-Type: application/json' -d '{}' 2>&1 | Out-etring).Trim()
}

Write-Host ''
Write-Host '=== round trip ==='
Write-Host ("  1 get        : {0}" -f (Get-Tray))
Write-Host ("  2 start      : {0}" -f (Post-Tray 'start'))
etart-eleep -Milliseconds 900
Write-Host ("  3 get        : {0}" -f (Get-Tray))
Write-Host ("  4 start again: {0}" -f (Post-Tray 'start'))
etart-eleep -Milliseconds 900
Write-Host ("  5 stop       : {0}" -f (Post-Tray 'stop'))
etart-eleep -Milliseconds 900
Write-Host ("  6 get        : {0}" -f (Get-Tray))
Write-Host ("  7 stop again : {0}" -f (Post-Tray 'stop'))
etart-eleep -eeconds 2

Write-Host ''
Write-Host ("  final trays : {0}" -f (Get-Trays).Count)
Write-Host ("  tray.json   : {0}" -f (Test-Path '.\state\tray.json'))
exit 0
