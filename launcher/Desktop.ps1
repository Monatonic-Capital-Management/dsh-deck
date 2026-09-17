# Desktop entry points. Importing this file never launches a process or reads state.
function Read-AppRuntime {
  $file = Join-Path $StateDir 'app.json'
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Read-AppOwner {
  $file = Join-Path $StateDir 'app-owner.json'
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Test-AppProcess($Runtime, $Owner, [switch]$AnyContext) {
  $id = [int](Get-InstProp $Runtime 'pid' 0)
  if ($id -le 0 -or -not $Owner -or [int](Get-InstProp $Owner 'pid' 0) -ne $id) { return $false }
  if (-not $AnyContext -and (Get-InstProp $Owner 'context' '') -ne $script:ConfigContext) { return $false }
  foreach ($field in @('configPath','sshConfigPath')) {
    $published = Get-InstProp $Runtime $field $null
    if ($null -ne $published -and [string]$published -ine [string](Get-InstProp $Owner $field '')) { return $false }
  }
  $record = Get-ProcessRecord $id
  if (-not $record -or [IO.Path]::GetFileName([string]$record.ExecutablePath) -ine 'node.exe') { return $false }
  if (-not (Get-InstProp $Owner 'startedAt' '') -or (Get-ProcessStamp $record) -ne $Owner.startedAt) { return $false }
  $args = @(Split-NativeArguments $record.CommandLine)
  return ($args.Count -eq 2 -and $args[1] -ieq (Join-Path $LauncherDir 'app\server.js'))
}
function Test-AppReady($Runtime, $Owner) {
  if (-not (Test-AppProcess $Runtime $Owner)) { return $false }
  $port = [int](Get-InstProp $Runtime 'port' 0); $url = [string](Get-InstProp $Runtime 'url' '')
  $uri = $null
  if ($port -lt 1 -or $port -gt 65535 -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { return $false }
  if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.Port -ne $port -or $uri.UserInfo) { return $false }
  if ((Get-ListeningPid $port) -ne [int]$Runtime.pid) { return $false }
  return (Test-Http "http://127.0.0.1:$port/" 3) -in @(200,401,403,302,303)
}
function Invoke-App([switch]$Quiet) {
  $serverJs = Join-Path $LauncherDir 'app\server.js'
  if (-not (Test-Path -LiteralPath $serverJs)) { Write-Err 'missing app/server.js'; return $false }
  $node = Get-NodeExe; $version = Get-NodeVersionOf $node
  if (-not $version -or (Compare-Version $version '18.0.0') -lt 0 -or -not (Test-NodeUsable $node)) {
    Write-Err 'app cannot start: no usable Node. Run dsh.ps1 -Command install -Target local, then retry app (no automatic install).'
    return $false
  }
  $runtime = Read-AppRuntime; $owner = Read-AppOwner
  if (Test-AppReady $runtime $owner) {
    if (-not $NoOpen) { Open-AppWindow $runtime.url }
    if (-not $Quiet) { Write-Info "app backend already running on port $($runtime.port)" }
    return $true
  }
  foreach ($record in @($runtime, $owner)) {
    $id = [int](Get-InstProp $record 'pid' 0)
    if ($id -gt 0 -and (Test-ProcessAlive $id)) { Throw-LauncherError 'app-context-mismatch' '面板记录指向存活但未就绪或配置上下文不符的进程；未复用、终止或遗忘它。请核对后先停止原面板。' }
  }
  $cfgPath = Resolve-ConfigPath $Config
  $cfg = Get-HostsConfig $cfgPath
  if (-not (Test-Path -LiteralPath $cfgPath)) { Save-HostsConfig $cfg $cfgPath }
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
  $runtimeFile = Join-Path $StateDir 'app.json'; $ownerFile = Join-Path $StateDir 'app-owner.json'
  foreach ($file in @($runtimeFile, $ownerFile)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $node; $psi.Arguments = Join-NativeArguments @($serverJs); $psi.WorkingDirectory = $LauncherDir
  $psi.UseShellExecute = $true; $psi.WindowStyle = 'Hidden'; $psi.CreateNoWindow = $true
  # ShellExecute detaches the backend. Its environment is inherited at creation.
  $previousConfig = $env:DSH_LAUNCHER_CONFIG; $previousSsh = $env:DSH_SSH_CONFIG
  try {
    $env:DSH_LAUNCHER_CONFIG = $cfgPath
    $env:DSH_SSH_CONFIG = Get-SshConfigPath $SshConfigPath
    $process = New-Object Diagnostics.Process; $process.StartInfo = $psi
    $null = $process.Start()
  } finally { $env:DSH_LAUNCHER_CONFIG = $previousConfig; $env:DSH_SSH_CONFIG = $previousSsh }
  $stamp = Get-ProcessStamp (Get-ProcessRecord $process.Id)
  $owner = [pscustomobject]@{ pid = $process.Id; startedAt = $stamp; context = $script:ConfigContext; configPath = $cfgPath; sshConfigPath = (Get-SshConfigPath $SshConfigPath) }
  Write-AtomicJson $ownerFile $owner
  $ready = $false; $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
    $runtime = Read-AppRuntime
    if (Test-AppReady $runtime $owner) { $ready = $true; break }
    Start-Sleep -Milliseconds 250
  }
  if (-not $ready) {
    Write-Info ("app readiness metadata: exited={0}; runtimePresent={1}; ownerMatches={2}" -f $process.HasExited, [bool]$runtime, (Test-AppProcess $runtime $owner))
    if ($process.HasExited) { Write-Info ("app child exit code: {0}" -f $process.ExitCode) }
    if (-not (Stop-OwnedProcess $process.Id $stamp)) { Write-Err 'app backend did not become ready and did not stop; ownership record retained'; return $false }
    foreach ($file in @($runtimeFile, $ownerFile)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
    Write-Err 'app backend did not become ready; its process was stopped. Check sanitized app diagnostics, or run dsh.ps1 -Command install -Target local.'
    return $false
  }
  if (-not $NoOpen) { Open-AppWindow $runtime.url }
  if (-not $Quiet) { Write-Ok "app backend running on port $($runtime.port)" }
  return $true
}
function Stop-App {
  $runtime = Read-AppRuntime; $owner = Read-AppOwner
  if (-not $runtime -and $owner) { $runtime = $owner }
  $id = [int](Get-InstProp $runtime 'pid' 0)
  $wasRunning = $id -gt 0 -and (Test-ProcessAlive $id)
  if ($wasRunning) {
    if (-not (Test-AppProcess $runtime $owner)) { Throw-LauncherError 'ownership-unknown' '无法核对面板进程归属或配置上下文；未终止进程、未删除记录。' }
    if (-not (Stop-OwnedProcess $id ([string]$owner.startedAt))) {
      Write-Err "app backend did not stop (pid $id is still running)"
      Write-Info "after checking ownership, stop it manually: taskkill /PID $id /T /F"
      return $false
    }
    Write-Ok "app backend stopped (pid $id)"
  } else { Write-Info 'app backend was not running' }
  foreach ($file in @((Join-Path $StateDir 'app.json'), (Join-Path $StateDir 'app-owner.json'))) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
  if (-not $NoOpen) {
    $profile = Join-Path $LauncherDir 'browser-profile'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue)) {
      if (-not $process.CommandLine) { continue }
      $args = @(Split-NativeArguments $process.CommandLine)
      if ($args -contains "--user-data-dir=$profile") { $null = Stop-OwnedProcess ([int]$process.ProcessId) (Get-ProcessStamp $process) }
    }
  }
  return $true
}
function Open-AppWindow([string]$Url) { Open-Instance $Url -AsAppWindow }
function Open-Instance([string]$Url, [switch]$AsAppWindow) {
  if ($NoOpen) { return }
  $uri = $null
  if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo) { Throw-LauncherError 'invalid-url' '只允许打开本机 loopback HTTP 地址。' }
  if ($AsAppWindow) {
    $browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($browser) {
      $profile = Join-Path $LauncherDir 'browser-profile'
      if (-not (Test-Path -LiteralPath $profile)) { New-Item -ItemType Directory -Path $profile -Force | Out-Null }
      Start-Process -FilePath $browser -ArgumentList (Join-NativeArguments @("--app=$Url", "--user-data-dir=$profile", '--no-first-run', '--no-default-browser-check', '--window-size=1120,780')) | Out-Null
      Write-Info 'opened app window (authenticated address omitted)'
      return
    }
  }
  Start-Process -FilePath "$env:WINDIR\System32\rundll32.exe" -ArgumentList (Join-NativeArguments @('url.dll,FileProtocolHandler', $Url)) -WindowStyle Hidden | Out-Null
  Write-Info 'opened browser (authenticated address omitted)'
}
function Get-RunningTrayPid {
  $file = Join-Path $StateDir 'tray.json'
  if (-not (Test-Path -LiteralPath $file)) { return 0 }
  try {
    $record = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-InstProp $record 'context' '') -ne $script:ConfigContext) { return 0 }
    $process = Get-ProcessRecord ([int]$record.pid)
    if (-not $process -or (Get-ProcessStamp $process) -ne (Get-InstProp $record 'startedAt' '')) { return 0 }
    $args = @(Split-NativeArguments $process.CommandLine)
    if ($args -contains (Join-Path $LauncherDir 'dsh.ps1') -and $args -contains 'tray-loop') { return [int]$record.pid }
  } catch { }
  return 0
}
function Get-LiveTrays { $id = Get-RunningTrayPid; if ($id -gt 0) { $id } }
function Invoke-Tray([switch]$Stop) {
  $id = Get-RunningTrayPid
  if ($Stop) {
    if ($id -gt 0 -and -not (Stop-OwnedProcess $id (Get-ProcessStamp (Get-ProcessRecord $id)))) { Throw-LauncherError 'stop-failed' 'tray did not stop' }
    $file = Join-Path $StateDir 'tray.json'
    if ($id -gt 0 -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force }
    if ($Json) { Write-Json @{ ok = $true; running = $false; stopped = [int]($id -gt 0) } }
    return
  }
  if ($id -le 0) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = Join-NativeArguments @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $LauncherDir 'dsh.ps1'),'-Command','tray-loop','-TrayInterval',[string]$TrayInterval,'-Config',(Resolve-ConfigPath $Config),'-SshConfigPath',(Get-SshConfigPath $SshConfigPath))
    $psi.UseShellExecute = $true; $psi.WindowStyle = 'Hidden'; $psi.WorkingDirectory = $LauncherDir
    $process = [Diagnostics.Process]::Start($psi)
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited -and (Get-RunningTrayPid) -le 0) { Start-Sleep -Milliseconds 250 }
    $id = Get-RunningTrayPid
    if ($id -le 0) { $null = Stop-OwnedProcess $process.Id (Get-ProcessStamp (Get-ProcessRecord $process.Id)); Throw-LauncherError 'tray-not-ready' 'tray did not become ready' }
  }
  if ($Json) { Write-Json @{ ok = $true; running = $true; pid = $id } } else { Write-Ok "tray running (pid $id)" }
}
function Start-TrayLoop([int]$IntervalSeconds = 20) {
  $guard = Enter-LauncherLock ('tray:' + $LauncherDir)
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $icon = New-Object Windows.Forms.NotifyIcon
  $icon.Icon = [Drawing.SystemIcons]::Application; $icon.Text = 'dsh-deck'; $icon.Visible = $true
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $open = $menu.Items.Add('打开面板'); $start = $menu.Items.Add('全部启动'); $stopAll = $menu.Items.Add('全部停止'); $quit = $menu.Items.Add('退出托盘')
  $open.add_Click({ try { $null = Invoke-App -Quiet } catch { Write-Log $_.Exception.Message } })
  $start.add_Click({ try { $null = Invoke-Start $null -Quiet } catch { Write-Log $_.Exception.Message } })
  $stopAll.add_Click({ try { $null = Invoke-Stop $null } catch { Write-Log $_.Exception.Message } })
  $quit.add_Click({ [Windows.Forms.Application]::Exit() })
  $icon.ContextMenuStrip = $menu
  $form = New-Object Windows.Forms.Form; $form.ShowInTaskbar = $false; $form.WindowState = 'Minimized'
  $previous = @{}
  $tick = {
    try {
      $rows = @(Get-AllStatus -NoProbeHttp)
      foreach ($row in $rows) {
        if ($previous.ContainsKey($row.Name) -and $previous[$row.Name] -ne $row.State) { $icon.ShowBalloonTip(4000, 'dsh-deck', "$($row.Name): $($row.State)", [Windows.Forms.ToolTipIcon]::Info) }
        $previous[$row.Name] = $row.State
      }
      $icon.Text = "dsh-deck $(@($rows | Where-Object { $_.State -eq 'up' }).Count)/$($rows.Count)"
    } catch { Write-Log $_.Exception.Message }
  }
  $timer = New-Object Windows.Forms.Timer; $timer.Interval = [Math]::Max(5, $IntervalSeconds) * 1000; $timer.add_Tick($tick)
  $file = Join-Path $StateDir 'tray.json'
  try {
    Write-AtomicJson $file ([pscustomobject]@{ pid = $PID; startedAt = (Get-ProcessStamp (Get-ProcessRecord $PID)); context = $script:ConfigContext; interval = $IntervalSeconds })
    $form.add_Shown({ & $tick; $timer.Start() })
    [Windows.Forms.Application]::Run($form)
  } finally {
    $timer.Stop(); $timer.Dispose(); $icon.Visible = $false; $icon.Dispose(); $form.Dispose()
    if ((Get-RunningTrayPid) -eq $PID -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force }
    Exit-LauncherLock $guard
  }
}
function Get-DshApiKey {
  if ($env:DEEPSEEK_API_KEY) { return [string]$env:DEEPSEEK_API_KEY }
  $file = Join-Path $DshHome '.credentials.yaml'
  if (-not (Test-Path -LiteralPath $file)) { return '' }
  $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
  $pattern = 'DEEPSEEK_API_KEY' + ':\s*["'']?([A-Za-z0-9_-]{20,})'
  if ($text -match $pattern) { return $Matches[1] }
  return ''
}
function Get-AccountBalance([switch]$Refresh) {
  $file = Join-Path $StateDir 'balance.json'
  if (-not $Refresh -and (Test-Path -LiteralPath $file)) {
    try { $cached = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json; if (((Get-Date) - [datetime]$cached.checkedAt).TotalMinutes -lt 5) { return $cached } } catch { }
  }
  $result = [ordered]@{ ok = $false; reason = ''; isAvailable = $false; balances = @(); checkedAt = (Get-Date).ToString('o') }
  $key = Get-DshApiKey
  if (-not $key) { $result.reason = 'no-key' }
  else {
    try {
      $response = Invoke-WebRequest -Uri 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = "Bearer $key" } -UseBasicParsing -TimeoutSec 20
      $data = $response.Content | ConvertFrom-Json
      $result.ok = $true; $result.isAvailable = [bool]$data.is_available
      $result.balances = @($data.balance_infos | ForEach-Object { [pscustomobject]@{ currency = $_.currency; total = $_.total_balance; granted = $_.granted_balance; toppedUp = $_.topped_up_balance } })
    } catch { $result.reason = 'account-request-failed' }
  }
  Write-AtomicJson $file $result
  return [pscustomobject]$result
}
function Invoke-Balance([switch]$Refresh) {
  $balance = Get-AccountBalance -Refresh:$Refresh
  if ($Json) { Write-Json $balance } else { if ($balance.ok) { foreach ($row in $balance.balances) { Write-C "$($row.currency): $($row.total)" } } else { Write-Warn2 $balance.reason } }
}
function Invoke-Menu {
  if ($Json) { Throw-LauncherError 'invalid-argument' '交互式 menu 不支持 -Json。' }
  while ($true) {
    Write-StatusTable @(Get-AllStatus)
    Write-C '[1] start all  [2] stop all  [3] open  [4] doctor  [0] exit'
    switch (Read-Host 'choice') {
      '1' { $result = Invoke-Start $null; Write-StatusTable $result.rows }
      '2' { $result = Invoke-Stop $null; Write-StatusTable $result.rows }
      '3' { Invoke-Open $null }
      '4' { Invoke-Doctor }
      '0' { return }
    }
  }
}
