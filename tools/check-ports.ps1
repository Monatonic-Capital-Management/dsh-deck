# Verify local-start port handling.
#
# Reproduces the reported bug on a spare port: a dsh already serving there used to
# make the launcher spawn a doomed second process and still report success.
# Deliberately never touches port 3080, which serves the user's own GUI.
$ErrorActionPreference = 'Continue'
Set-Location '$PSScriptRoot\..'

$TestPort = 3123
$AltPort  = 3124

function Test-Http([string]$Url) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 4 -ErrorAction Stop
    return [int]$r.StatusCode
  } catch {
    $c = 0; try { $c = [int]$_.Exception.Response.StatusCode.value__ } catch { }
    return $c
  }
}
function Listening([int]$Port) { [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }
function Kill-Port([int]$Port) {
  $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $null = & taskkill.exe /PID $c.OwningProcess /T /F 2>&1 }
}

Write-Host '=== setup: clear the test ports ==='
foreach ($p in @($TestPort, $AltPort)) { Kill-Port $p }
Start-Sleep -Seconds 2
Write-Host ("  {0} listening: {1}" -f $TestPort, (Listening $TestPort))

$dsh = 'C:\Users\<you>\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
$node = 'C:\Program Files\nodejs\node.exe'

# ---------------------------------------------------------------- case 1
Write-Host ''
Write-Host '=== case 1: a dsh is ALREADY serving the target port (the reported bug) ==='
Write-Host '  starting an "external" dsh, as if the user ran npx dsh web themselves'
$extLog = Join-Path $env:TEMP 'ext_dsh.log'
Remove-Item $extLog -Force -ErrorAction SilentlyContinue
$ext = Start-Process -FilePath $node -ArgumentList @($dsh, 'web', '--port', "$TestPort", '--no-open') `
  -WorkingDirectory '$env:USERPROFILE' -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $extLog -RedirectStandardError "$env:TEMP\ext_dsh.err"
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
  if (Listening $TestPort) { break }
  Start-Sleep -Milliseconds 400
}
Write-Host ("  external dsh pid {0} listening: {1}  http={2}" -f $ext.Id, (Listening $TestPort), (Test-Http "http://127.0.0.1:$TestPort/"))

Write-Host '  now asking the launcher to start a local instance on that same port'
$cfg = Join-Path $env:TEMP 'porttest.json'
@"
{
  "version": 1,
  "instances": [
    { "name": "porttest", "kind": "local", "enabled": true, "port": $TestPort }
  ]
}
"@ | Set-Content -Path $cfg -Encoding UTF8

$out = & powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh.ps1 -Command start -Target porttest -NoOpen -Config $cfg 2>&1 | Out-String
Write-Host '  --- launcher output ---'
$out.Trim() -split "`r?`n" | ForEach-Object { Write-Host "    $_" }

Write-Host ''
Write-Host '  --- verdict ---'
$adopted = $out -match 'adopting'
$moved = $out -match 'starting on'
$falseSuccess = ($out -match 'failed to start') -or ($out -match '\[ok\]')
Write-Host ("    adopted the existing dsh : {0}" -f $adopted)
Write-Host ("    moved to a free port     : {0}" -f $moved)
Write-Host ("    external dsh still alive : {0}" -f (-not $ext.HasExited))
Write-Host ("    port still serving       : http={0}" -f (Test-Http "http://127.0.0.1:$TestPort/"))

# ---------------------------------------------------------------- case 2
Write-Host ''
Write-Host '=== case 2: port held by a NON-dsh listener ==='
Kill-Port $AltPort
Start-Sleep -Seconds 1
Write-Host '  (using a plain TCP listener that does not speak HTTP)'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $AltPort)
$listener.Start()
Write-Host ("  listener bound on {0}: {1}" -f $AltPort, $listener.Server.IsBound)
Write-Host ("  http probe there returns: {0}  (0 = not an http server)" -f (Test-Http "http://127.0.0.1:$AltPort/"))

$cfg2 = Join-Path $env:TEMP 'porttest2.json'
@"
{
  "version": 1,
  "instances": [
    { "name": "porttest2", "kind": "local", "enabled": true, "port": $AltPort }
  ]
}
"@ | Set-Content -Path $cfg2 -Encoding UTF8

$out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh.ps1 -Command start -Target porttest2 -NoOpen -Config $cfg2 2>&1 | Out-String
Write-Host '  --- launcher output ---'
$out2.Trim() -split "`r?`n" | ForEach-Object { Write-Host "    $_" }
Write-Host ''
Write-Host ("  moved off the busy port instead of failing: {0}" -f ($out2 -match 'starting on'))

# ---------------------------------------------------------------- cleanup
Write-Host ''
Write-Host '=== cleanup ==='
try { $listener.Stop() } catch { }
if (-not $ext.HasExited) { $null = & taskkill.exe /PID $ext.Id /T /F 2>&1 }
& powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh.ps1 -Command stop -Target porttest  -Config $cfg  2>&1 | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh.ps1 -Command stop -Target porttest2 -Config $cfg2 2>&1 | Out-Null
Start-Sleep -Seconds 2
foreach ($p in @($TestPort, $AltPort, ($TestPort + 1), ($AltPort + 1))) { Kill-Port $p }
Remove-Item $cfg, $cfg2, '.\state\porttest.json', '.\state\porttest2.json' -Force -ErrorAction SilentlyContinue
Write-Host ("  3080 untouched: {0}" -f (Listening 3080))
Write-Host ("  leftovers on test ports: {0}" -f (@($TestPort, $AltPort, ($TestPort + 1), ($AltPort + 1) | Where-Object { Listening $_ }).Count))
exit 0
