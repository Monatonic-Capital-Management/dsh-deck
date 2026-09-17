# One SSH argument builder for discovery context, probes, commands and tunnels.
function ConvertTo-ShLiteral([string]$Value) {
  $q = [string][char]39
  return $q + $Value.Replace($q, ($q + '"' + $q + '"' + $q)) + $q
}
function Get-SshArguments($Connection, [string]$Purpose = 'command', [int]$LocalPort = 0, [int]$RemotePort = 0, [int]$TimeoutSec = 10) {
  if ($Connection -is [string]) { $Connection = [pscustomobject]@{ sshHost = $Connection } }
  $map = ConvertTo-ConfigMap $Connection; Assert-ConfigFields $map
  $hostName = [string](Get-InstProp $Connection 'sshHost' '')
  if (-not $hostName) { Throw-LauncherError 'invalid-config' 'SSH 连接缺少 sshHost。' }
  $configPath = Get-SshConfigPath $SshConfigPath
  $file = if ((Test-Path -LiteralPath $configPath) -or $script:SshConfigWasExplicit) { $configPath } else { 'NUL' }
  $arguments = @('-F', $file, '-n', '-T', '-o', 'BatchMode=yes', '-o', "ConnectTimeout=$TimeoutSec", '-o', 'StrictHostKeyChecking=yes', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2')
  foreach ($pair in @(@('sshPort','-p'),@('sshUser','-l'),@('identityFile','-i'),@('jumpHost','-J'))) {
    $value = Get-InstProp $Connection $pair[0] ''
    if ($value) {
      if ($pair[0] -eq 'identityFile') { $value = Resolve-FullPath ([string]$value) }
      $arguments += @($pair[1], [string]$value)
    }
  }
  if ($Purpose -eq 'tunnel') {
    if ($LocalPort -lt 1 -or $RemotePort -lt 1) { Throw-LauncherError 'invalid-port' '隧道端口无效。' }
    $arguments += @('-N', '-L', "127.0.0.1:${LocalPort}:127.0.0.1:${RemotePort}", '-o', 'ExitOnForwardFailure=yes')
  }
  $arguments += $hostName
  return $arguments
}
function Get-B64Payload([string]$Script) {
  $normalized = ($Script -replace "`r`n", "`n") -replace "`r", "`n"
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
}
function Get-B64Command([string]$Script, $Connection, [int]$TimeoutSec = 30, [switch]$Stream) {
  $payload = Get-B64Payload $Script
  $runner = if ($Stream) { 'bash' } else { "timeout --signal=TERM --kill-after=5 ${TimeoutSec}s bash" }
  $command = "printf %s $payload | base64 -d | $runner"
  $runAs = Get-InstProp $Connection 'runAsUser' ''
  if ($runAs) { $command = 'sudo -n -H -u ' + (ConvertTo-ShLiteral $runAs) + ' bash -c ' + (ConvertTo-ShLiteral $command) }
  return $command
}
function Start-SshInvocation($Connection, [string]$RemoteCommand, [int]$TimeoutSec = 30) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'ssh.exe'
  $psi.Arguments = Join-NativeArguments (@(Get-SshArguments $Connection) + @($RemoteCommand))
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false); $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
  $process = New-Object Diagnostics.Process; $process.StartInfo = $psi
  $null = $process.Start()
  return [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync(); Deadline = (Get-Date).AddSeconds($TimeoutSec + 15) }
}
function Complete-SshInvocation($Invocation) {
  $p = $Invocation.Process
  try {
    $remaining = [Math]::Max(0, [int]($Invocation.Deadline - (Get-Date)).TotalMilliseconds)
    if (-not $p.WaitForExit($remaining)) {
      try { $p.Kill(); $p.WaitForExit(5000) | Out-Null } catch { }
      Throw-LauncherError 'ssh-timeout' 'SSH 操作超时；远端命令有独立超时保护，请重新探测确认结果。'
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $Invocation.Out.Result; Err = $Invocation.Err.Result }
  } finally { $p.Dispose() }
}
function Invoke-B64([string]$Script, $SshHostName, [int]$TimeoutSec = 30) {
  $result = Complete-SshInvocation (Start-SshInvocation $SshHostName (Get-B64Command $Script $SshHostName $TimeoutSec) $TimeoutSec)
  if ($result.Code -ne 0) {
    $failure = Get-SshFailureClass $result.Err
    Throw-LauncherError $failure.Code ("SSH/远端命令失败（退出码 {0}）：{1}" -f $result.Code, $failure.Hint)
  }
  return [string]$result.Out
}
function Invoke-SshStream([string]$Script, $Connection) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'ssh.exe'; $psi.Arguments = Join-NativeArguments (@(Get-SshArguments $Connection) + @((Get-B64Command $Script $Connection -Stream)))
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false); $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
  $process = New-Object Diagnostics.Process; $process.StartInfo = $psi
  try {
    $null = $process.Start(); $errors = $process.StandardError.ReadToEndAsync()
    while (-not $process.StandardOutput.EndOfStream) { Write-C ($process.StandardOutput.ReadLine()) }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { Throw-LauncherError 'ssh-failed' '远端日志流已失败或断开。' }
  } finally {
    try { if (-not $process.HasExited) { $process.Kill() } } catch { }
    $process.Dispose()
  }
}
function Test-SshReachable($SshHostName, [int]$TimeoutSec = 8) {
  try { return (Invoke-B64 'echo REACHABLE' $SshHostName $TimeoutSec).Trim() -eq 'REACHABLE' } catch { return $false }
}
function Get-SshFailureClass([string]$SshOutput) {
  $text = $SshOutput.ToLowerInvariant()
  if ($text -match 'could not resolve hostname') { return [pscustomobject]@{ Code = 'dns'; Hint = '主机名无法解析，请检查 SSH 配置或 DNS。' } }
  if ($text -match 'connection refused') { return [pscustomobject]@{ Code = 'refused'; Hint = 'SSH 端口拒绝连接，请检查 sshd 和端口配置。' } }
  if ($text -match 'permission denied|no supported authentication') { return [pscustomobject]@{ Code = 'auth'; Hint = 'SSH 认证失败，请检查密钥或 ssh-agent。' } }
  if ($text -match 'host key verification failed|host key is known|host identification has changed') { return [pscustomobject]@{ Code = 'hostkey'; Hint = '请先手动核对 SSH 主机指纹；启动器不会自动信任未知主机。' } }
  if ($text -match 'timed out|timeout|unreachable|no route|connection closed') { return [pscustomobject]@{ Code = 'timeout'; Hint = 'SSH 网络不可达，请检查网络、VPN 或防火墙。' } }
  return [pscustomobject]@{ Code = 'unknown'; Hint = '远端命令未成功；检查 SSH 配置和该主机的服务状态。' }
}
function Get-RemoteDiagnosis($SshHostName, [int]$Port = 0) {
  if (Test-SshReachable $SshHostName) { return [pscustomobject]@{ Code = 'ok'; Hint = '' } }
  return Get-SshFailureClass ''
}
function Get-SshHostNames([string]$Path, [hashtable]$Visited) {
  $full = Resolve-FullPath $Path
  if ($Visited.ContainsKey($full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
  if ($Visited.Count -ge 64) { Throw-LauncherError 'invalid-ssh-config' 'SSH Include 层数或文件数过多。' }
  $Visited[$full] = $true
  foreach ($line in (Get-Content -LiteralPath $full -Encoding UTF8)) {
    $content = [regex]::Match($line, '^(?:[^#"'']+|"[^"]*"|''[^'']*'')*').Value
    $tokens = @([regex]::Matches($content, '"([^"\r\n]*)"|''([^''\r\n]*)''|([^\s#]+)') | ForEach-Object {
      if ($_.Groups[1].Success) { $_.Groups[1].Value } elseif ($_.Groups[2].Success) { $_.Groups[2].Value } else { $_.Groups[3].Value }
    })
    if ($tokens.Count -lt 2) { continue }
    if ($tokens[0] -ieq 'Host') {
      foreach ($value in $tokens[1..($tokens.Count - 1)]) {
        if ($value -notmatch '[*?!]' -and $value -match '^[A-Za-z0-9_][A-Za-z0-9_.@-]*$') { $value }
      }
    } elseif ($tokens[0] -ieq 'Include') {
      foreach ($value in $tokens[1..($tokens.Count - 1)]) {
        if ($value -match '^~[/\\]') { $value = Join-Path (Get-HomeDir) $value.Substring(2) }
        elseif (-not [IO.Path]::IsPathRooted($value)) { $value = Join-Path (Split-Path -Parent $full) $value }
        foreach ($file in @(Get-ChildItem -Path $value -File -ErrorAction SilentlyContinue | Sort-Object FullName)) { Get-SshHostNames $file.FullName $Visited }
      }
    }
  }
}
function Get-SshHosts {
  $path = Get-SshConfigPath $SshConfigPath
  $registered = @(Get-Instances $null $Config -IncludeDisabled | Where-Object { $_.kind -eq 'remote' } | ForEach-Object { $_.sshHost })
  $names = @(Get-SshHostNames $path @{} | Sort-Object -Unique)
  $hosts = @($names | ForEach-Object { [pscustomobject]@{ name = $_; configured = ($registered -contains $_) } })
  return [pscustomobject]@{ hosts = $hosts; configPath = $path; exists = [bool](Test-Path -LiteralPath $path -PathType Leaf) }
}
