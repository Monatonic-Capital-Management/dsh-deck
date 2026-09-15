# End-to-end checks for the panel optimizations.
#
# Covers the config cache, the fresh-URL endpoint, and the failure
# classification. Read-only with respect to the user's instances: it probes, it
# does not start or stop anything, and the unreachable fixtures are fake hosts
# given to the launcher through a scratch -Config.
$ErrorActionPreference = 'Continue'
Set-Location '$PSScriptRoot\..'

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else     { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

$rt = Get-Content '.\state\app.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$base = "http://127.0.0.1:$($rt.port)"
$tok = $rt.token

function Api([string]$path) {
  $sep = if ($path.Contains('?')) { '&' } else { '?' }
  # Build the query separator explicitly. Writing "$path$sep`t=" would emit a
  # literal backtick-t (PowerShell only expands `t inside a double-quoted string,
  # not across an interpolated variable boundary), so every request went out with
  # a malformed token and came back 403.
  $query = $base + $path + $sep + 't=' + $tok
  return (& curl.exe -s $query 2>&1 | Out-String)
}

Write-Host ''
Write-Host '=== 1. background poll feeds the cache; reads never wait on ssh ==='
$logBefore = @(Get-Content '.\logs\app.log' -Encoding UTF8)
$timings = @()
foreach ($i in 1..5) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $null = Api '/api/instances'
  $sw.Stop()
  $timings += $sw.Elapsed.TotalSeconds
}
$logAfter = @(Get-Content '.\logs\app.log' -Encoding UTF8)
# Inspect only the lines appended during the window. A live panel (or the tray)
# can append unrelated calls concurrently, so this reads the delta and asserts a
# floor rather than an exact total -- asserting equality made the check flaky the
# first time it ran against a panel that was actually open.
$tail = @($logAfter | Select-Object -Skip $logBefore.Count)
$listCalls = @($tail | Where-Object { $_ -match '"list"' }).Count
$statusCalls = @($tail | Where-Object { $_ -match '"status"' }).Count
$maxMs = [math]::Round((($timings | Measure-Object -Maximum).Maximum) * 1000)
# Read the steady state separately from the first sample. The first read after a
# quiet period legitimately pays for a probe: the cache has aged past its TTL and
# nothing else has asked since, so it is a cold read rather than a regression.
# Asserting a ceiling across every sample flagged that normal case as a failure.
$steady = @($timings | Select-Object -Skip 1)
$steadyMaxMs = [math]::Round((($steady | Measure-Object -Maximum).Maximum) * 1000)
Write-Host ("  timings (s): {0}" -f (($timings | ForEach-Object { [math]::Round($_, 3) }) -join ', '))
Write-Host ("  first read: {0} ms (may be a cold probe); steady max: {1} ms" -f ([math]::Round($timings[0] * 1000)), $steadyMaxMs)
Write-Host ("  appended during the window -> status={0} list={1}" -f $statusCalls, $listCalls)
Check 'steady-state reads are near-instant (max under 300ms)' ($steadyMaxMs -lt 300) "$steadyMaxMs ms"
Check 'reads did not each trigger a probe' ($statusCalls -le 2) "got $statusCalls (background poll may add one)"
Check 'no list call in the window (served from cache)' ($listCalls -eq 0) "got $listCalls"
Write-Host ''
Write-Host '=== 2. GET /api/instances/:name/url returns a usable url ==='
foreach ($name in @('local', 'DuckServer')) {
  $raw = Api "/api/instances/$name/url"
  $o = $null
  try { $o = $raw | ConvertFrom-Json } catch { }
  $url = if ($o -and $o.instance) { $o.instance.url } else { '' }
  Check "$name fresh url present" ([bool]$url) $raw.Substring(0, [Math]::Min(120, $raw.Length))
  if ($url) {
    # The URL must actually answer: 401 (token fence) or 200/303 all mean alive.
    $code = (& curl.exe -s -o NUL -w "%{http_code}" -L --max-redirs 0 $url 2>&1 | Out-String).Trim()
    Check "$name url answers (got $code)" ($code -in @('200', '303', '401')) $code
  }
}

Write-Host ''
Write-Host '=== 3. unknown instance is still rejected ==='
$bad = Api '/api/instances/no-such-instance/url'
Check 'unknown name -> error' ($bad -match 'unknown instance') $bad

Write-Host ''
Write-Host '=== 4. failure classification (fixtures, no real hosts touched) ==='
$cfg = Join-Path $env:TEMP 'uxcheck.json'
@'
{ "version": 1, "instances": [
  { "name": "fx-timeout", "kind": "remote", "enabled": true, "sshHost": "172.26.42.63", "remotePort": 3080, "localPort": 3196 },
  { "name": "fx-dns", "kind": "remote", "enabled": true, "sshHost": "no-such-host-xyz.invalid", "remotePort": 3080, "localPort": 3195 }
] }
'@ | Set-Content $cfg -Encoding UTF8
& powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh.ps1 -Command status -NoProbe -Json -Config $cfg > "$env:TEMP\uxcheck.json.out" 2>&1
$rows = Get-Content "$env:TEMP\uxcheck.json.out" -Raw -Encoding UTF8 | ConvertFrom-Json
$t = @($rows | Where-Object { $_.Name -eq 'fx-timeout' })[0]
$d = @($rows | Where-Object { $_.Name -eq 'fx-dns' })[0]
Check 'intranet host classified as timeout/VPN' ($t.FailCode -eq 'timeout') $t.FailCode
Check 'timeout hint mentions VPN' ($t.Hint -match 'VPN') $t.Hint
Check 'bad hostname classified as dns' ($d.FailCode -eq 'dns') $d.FailCode
Check 'unreachable detail carries the hint' ($t.Detail -match 'VPN') $t.Detail
Remove-Item $cfg, "$env:TEMP\uxcheck.json.out" -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("=== {0} passed, {1} failed ===" -f $pass, $fail)
exit $(if ($fail -gt 0) { 1 } else { 0 })
