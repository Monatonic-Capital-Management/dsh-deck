# Ownership is proven with the dsh entry point, arguments and creation time.
function Test-DshProcessRecord($ProcessRecord, [string]$Bin, [int]$Port = 0) {
  if (-not $ProcessRecord -or -not $Bin -or -not $ProcessRecord.CommandLine) { return $false }
  if ([IO.Path]::GetFileName([string]$ProcessRecord.ExecutablePath) -ine 'node.exe') { return $false }
  $args = @(Split-NativeArguments ([string]$ProcessRecord.CommandLine))
  if ($args.Count -lt 3 -or $args[1] -ine $Bin -or $args[2] -cne 'web') { return $false }
  if ($Port -gt 0) {
    $matchesPort = $false
    for ($index = 3; $index -lt $args.Count; $index++) {
      if ($args[$index] -eq '--port' -and $index + 1 -lt $args.Count -and $args[$index + 1] -eq [string]$Port) { $matchesPort = $true }
      if ($args[$index] -eq "--port=$Port") { $matchesPort = $true }
    }
    if (-not $matchesPort) { return $false }
  }
  return $true
}
function Get-RecordedPid([string]$InstanceName, [string]$Kind, $Inst) {
  $state = Get-State $InstanceName
  if (-not $state) { return 0 }
  if ((Get-InstProp $state 'context' '') -ne $script:ConfigContext) { return 0 }
  $field = if ($Kind -eq 'tunnel') { 'tunnelPid' } else { 'serverPid' }
  $pidValue = [int](Get-InstProp $state $field 0)
  $process = Get-ProcessRecord $pidValue
  if (-not $process) { return 0 }
  $stampField = if ($Kind -eq 'tunnel') { 'tunnelStartedAt' } else { 'serverStartedAt' }
  $stamp = [string](Get-InstProp $state $stampField '')
  if (-not $stamp -or (Get-ProcessStamp $process) -ne $stamp) { return 0 }
  if ($Kind -eq 'server') {
    $bin = Get-InstProp $state 'entryPoint' ''
    if (-not $bin -or $bin -ine (Find-DshLocal) -or -not (Test-DshProcessRecord $process $bin ([int](Get-InstProp $state 'port' 0)))) { return 0 }
  } else {
    if (-not $Inst) { $Inst = @(Get-Instances @($InstanceName) $Config)[0] }
    if ([IO.Path]::GetFileName([string]$process.ExecutablePath) -ine 'ssh.exe') { return 0 }
    $actual = @(Split-NativeArguments $process.CommandLine)
    $expected = @(Get-SshArguments $Inst -Purpose tunnel -LocalPort ([int](Get-InstProp $state 'localPort' 0)) -RemotePort ([int]$Inst.remotePort))
    if ($actual.Count -ne $expected.Count + 1) { return 0 }
    for ($index = 0; $index -lt $expected.Count; $index++) { if ($actual[$index + 1] -cne $expected[$index]) { return 0 } }
  }
  return $pidValue
}
function Get-InstWorkdir($Inst) {
  $directory = [string](Get-InstProp $Inst 'workdir' (Get-HomeDir))
  return Resolve-FullPath $directory
}
function Test-DshServing([int]$Port) { return (Test-Http "http://127.0.0.1:$Port/") -in @(200,401,302,303) }
function Get-LocalUrlFromLog([string]$InstanceName, [int]$PortValue) {
  Assert-InstanceName $InstanceName
  $file = Join-Path $LogDir "$InstanceName.server.log"
  if (-not (Test-Path -LiteralPath $file)) { return '' }
  $text = Get-Content -LiteralPath $file -Tail 200 -ErrorAction SilentlyContinue | Out-String
  $found = [regex]::Matches($text, ('dsh web:\s+(http://127\.0\.0\.1:' + $PortValue + '(?:/[^\s()]*)?)'))
  if ($found.Count -gt 0) { return $found[$found.Count - 1].Groups[1].Value }
  return ''
}
function Get-LocalUrl([string]$InstanceName, [int]$PortValue) {
  $logged = Get-LocalUrlFromLog $InstanceName $PortValue
  if ($logged) { return $logged }
  return "http://127.0.0.1:$PortValue/"
}
function Get-LocalStatus($Inst, [switch]$NoProbeHttp) {
  $name = $Inst.name; $port = [int]$Inst.port
  $state = Get-State $name; $managed = Get-RecordedPid $name 'server' $Inst
  if ($managed -gt 0) { $port = [int](Get-InstProp $state 'port' $port) }
  $holder = Get-ListeningPid $port; $status = 'down'; $detail = "未启动 · 端口 $port"; $http = 0
  $bin = Find-DshLocal
  if ($holder -gt 0) {
    if ($holder -eq $managed) { $status = 'up'; $detail = "本机受管服务运行中 · 端口 $port" }
    elseif (Test-DshProcessRecord (Get-ProcessRecord $holder) $bin $port) { $status = 'up-external'; $detail = '已识别的外部 dsh；未接管，不会自动终止' }
    else { $status = 'port-busy'; $detail = "端口 $port 被未知进程占用；不会接管或终止" }
  } elseif ($managed -gt 0) { $status = 'starting'; $detail = '受管进程存活，但还未监听' }
  if (-not $NoProbeHttp -and $status -in @('up','up-external')) {
    $http = Test-Http "http://127.0.0.1:$port/"
    if ($http -notin @(200,401,302,303)) { $status = 'unhealthy'; $detail = '已识别 dsh 进程，但 HTTP 探测未通过' }
  }
  $version = Get-LocalDshVersion; $update = Get-UpdateStatus $Inst $version
  $hint = ''
  if (-not $version) {
    if ($bin) { $hint = "dsh 已安装但无法运行；需要 Node >= 22.19.0，当前 $(Get-NodeVersionOf (Get-NodeExe))。请运行 dsh.ps1 -Command install -Target $name。" }
    else { $hint = "dsh 未安装。运行 dsh.ps1 -Command install -Target $name（手动方式：npm i -g @deepseek-ai/dsh）。" }
  }
  $url = ''
  if ($status -eq 'up') { $url = Get-LocalUrl $name $port }
  elseif ($status -eq 'up-external') { $url = "http://127.0.0.1:$port/" }
  return [pscustomobject]@{
    Name = $name; Kind = 'local'; Port = $port; State = $status; Detail = $detail; Http = $http; Url = $url; Workdir = (Get-InstWorkdir $Inst)
    DshInstalled = [bool]$version; Hint = $hint; DshVersion = $version; InstalledVersion = $version
    RunningVersion = $(if ($managed -gt 0) { [string](Get-InstProp $state 'runningVersion' '') } else { '' })
    LatestVersion = $update.latest; TargetVersion = $update.target; PinnedVersion = $update.pinned; UpdateAvailable = $update.updateAvailable
  }
}
function Start-LocalInstance($Inst, [switch]$Quiet, [int]$PortOverride = 0) {
  $name = $Inst.name; $port = [int]$Inst.port
  if ($PortOverride -gt 0) { $port = $PortOverride }
  $existing = Get-RecordedPid $name 'server' $Inst
  if ($existing -gt 0) {
    $state = Get-State $name; $actual = [int](Get-InstProp $state 'port' $port)
    if ((Get-ListeningPid $actual) -eq $existing -and (Test-DshServing $actual)) { return $actual }
    Throw-LauncherError 'local-running' '已有受管进程未就绪；请先停止该实例，再重试。'
  }
  $bin = Find-DshLocal
  if (-not $bin) { Write-Err "$name cannot start: dsh not found. Run dsh.ps1 -Command install -Target $name (npm i -g @deepseek-ai/dsh)"; return 0 }
  $node = Get-NodeExe; $nodeVersion = Get-NodeVersionOf $node
  if (-not $nodeVersion -or (Compare-Version $nodeVersion $script:NodeMinVersion) -lt 0) { Write-Err "$name cannot start: no usable Node; run dsh.ps1 -Command install -Target $name"; return 0 }
  $version = Get-LocalDshVersion
  if (-not $version) { Write-Err "$name cannot start: dsh does not run; use explicit install/upgrade to repair it"; return 0 }
  Assert-LocalPins
  $pin = Get-DesiredDshVersion $Inst
  if ($pin -and $pin -ne $version) { Throw-LauncherError 'pin-mismatch' '已安装版本与 dshVersion 不符，请先预览并执行显式 upgrade。' }
  if (Test-PortListening $port) {
    $holder = Get-ListeningPid $port
    if (Test-DshProcessRecord (Get-ProcessRecord $holder) $bin $port) {
      Throw-LauncherError 'external-dsh' '端口由外部 dsh 占用；不能证明配置上下文，未接管。请先自行停止或选择其他端口。'
    }
    if ($PortOverride -gt 0) { Throw-LauncherError 'port-busy' '指定端口被其他进程占用；未终止该进程。' }
    $free = Find-FreePort ($port + 1)
    if ($free -le 0) { Throw-LauncherError 'port-busy' '找不到可用的本地端口。' }
    Write-Warn2 "端口 $port 被其他进程占用，使用 $free；原进程保持不变。"
    $port = $free
  }
  $workdir = Get-InstWorkdir $Inst
  if (-not (Test-Path -LiteralPath $workdir -PathType Container)) { Throw-LauncherError 'invalid-workdir' 'workdir 不存在；请编辑实例的工作目录后重试。' }
  if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $log = Join-Path $LogDir "$name.server.log"
  if (Test-Path -LiteralPath $log) { Move-Item -LiteralPath $log -Destination "$log.1" -Force }
  $arguments = Join-NativeArguments @($bin, 'web', '--port', [string]$port, '--no-open')
  $process = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $workdir -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
  $record = Get-ProcessRecord $process.Id; $stamp = Get-ProcessStamp $record
  Set-State $name ([pscustomobject]@{ serverPid = $process.Id; serverStartedAt = $stamp; entryPoint = $bin; port = $port; context = $script:ConfigContext; runningVersion = $version; updatedAt = (Get-Date).ToString('o') })
  $deadline = (Get-Date).AddSeconds(90); $ready = $false
  while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
    if ((Get-ListeningPid $port) -eq $process.Id -and (Test-DshServing $port) -and (Test-DshProcessRecord (Get-ProcessRecord $process.Id) $bin $port)) { $ready = $true; break }
    Start-Sleep -Milliseconds 300
  }
  if (-not $ready) {
    if (-not (Stop-OwnedProcess $process.Id $stamp)) { Throw-LauncherError 'start-timeout' '启动未就绪，受管进程未能停止；保留记录，请执行 stop 后重新检查。' }
    Remove-State $name
    Write-Err "$name failed to become ready; its spawned process was stopped; inspect sanitized logs"
    return 0
  }
  $url = Get-LocalUrl $name $port
  Set-StateField $name @{ url = $url }
  if (-not $Quiet) { Write-Ok "$name up on port $port" }
  return $port
}
function Stop-LocalInstance($Inst, [switch]$Quiet) {
  $name = $Inst.name; $recorded = Get-State $name
  $managed = Get-RecordedPid $name 'server' $Inst
  if ($managed -gt 0) {
    if (-not (Stop-OwnedProcess $managed ([string](Get-InstProp $recorded 'serverStartedAt' '')))) { Throw-LauncherError 'stop-failed' '受管 dsh 进程未停止；保留运行记录，请重新检查。' }
    Remove-State $name
    if (-not $Quiet) { Write-Ok "$name stopped" }
    return $true
  }
  $recordedPid = [int](Get-InstProp $recorded 'serverPid' 0)
  $port = [int](Get-InstProp $recorded 'port' $Inst.port)
  if (($recordedPid -gt 0 -and (Test-ProcessAlive $recordedPid)) -or (Test-PortListening $port)) {
    Throw-LauncherError 'ownership-unknown' '不能证明现有进程属于此实例，未终止进程或删除记录；请手动核对。'
  }
  if ($recorded) { Remove-State $name }
  if (-not $Quiet) { Write-Info "$name is not running" }
  return $true
}
