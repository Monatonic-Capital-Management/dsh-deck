# Remote service snapshots, provisioning and owned SSH tunnels.
function ConvertFrom-RemoteFacts([string]$Text) {
  $facts = @{}
  foreach ($line in ($Text -split '\r?\n')) { if ($line -match '^([A-Z_]+)=(.*)$') { $facts[$Matches[1]] = $Matches[2].Trim() } }
  return $facts
}
function Get-RemoteSnapshotScript($Inst) {
  $body = @'
set +e
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
MP=0; ST=unknown; CG=''; LP=0; OWNED=no; LISTENING=no; HTTP=0
UNIT_FACTS="$(systemctl --user show dsh-web.service -p MainPID -p ActiveState -p ControlGroup 2>/dev/null)"
while IFS='=' read -r key value; do
  case "$key" in MainPID) MP="$value";; ActiveState) ST="$value";; ControlGroup) CG="$value";; esac
done <<< "$UNIT_FACTS"
SOCKETS="$(ss -ltnpH 'sport = :__PORT__' 2>/dev/null)"
if [ -n "$SOCKETS" ]; then LISTENING=yes; fi
LOOPBACK="$(printf '%s\n' "$SOCKETS" | grep -E '127\.0\.0\.1:__PORT__[[:space:]]|\[::1\]:__PORT__[[:space:]]')"
LP="$(printf '%s\n' "$LOOPBACK" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
LP="${LP:-0}"
if [ "$LP" -gt 0 ] 2>/dev/null && [ "$MP" -gt 0 ] 2>/dev/null; then
  if [ "$LP" = "$MP" ]; then OWNED=yes
  elif [ -n "$CG" ] && [ "$CG" != / ] && [ -r "/proc/$LP/cgroup" ]; then
    while IFS=: read -r hierarchy controllers member; do
      case "$member" in "$CG"|"$CG"/*) OWNED=yes;; esac
    done < "/proc/$LP/cgroup"
  fi
fi
if [ "$OWNED" = yes ]; then
  if command -v curl >/dev/null 2>&1; then
    HTTP="$(curl --noproxy '*' -s --max-time 3 -o /dev/null -w '%{http_code}' 'http://127.0.0.1:__PORT__/' 2>/dev/null)"
  elif command -v node >/dev/null 2>&1; then
    HTTP="$(node -e 'const h=require("http");const r=h.get("http://127.0.0.1:__PORT__/",s=>{console.log(s.statusCode);s.resume()});r.setTimeout(3000,()=>r.destroy());r.on("error",()=>process.exit(1))' 2>/dev/null)"
  fi
fi
echo "SNAP_MAIN=${MP:-0}"
echo "SNAP_STATE=${ST:-unknown}"
echo "SNAP_LISTEN=$LP"
echo "SNAP_LISTENING=$LISTENING"
echo "SNAP_OWNED=$OWNED"
echo "SNAP_HTTP=${HTTP:-0}"
'@
  return $body.Replace('__PORT__', [string]([int](Get-InstProp $Inst 'remotePort' 3080)))
}
function Get-RemoteProbeScript($Inst, [switch]$IncludeUrl) {
  $facts = @'
echo SSH_READY=yes
echo "OS=$(uname -s 2>/dev/null)"
echo "ARCH=$(uname -m 2>/dev/null)"
echo "NODE=$(command -v node 2>/dev/null)"
echo "NODE_V=$(node -v 2>/dev/null)"
echo "NPM=$(command -v npm 2>/dev/null)"
echo "NPM_PREFIX=$(npm config get prefix 2>/dev/null)"
DSH="$(command -v dsh 2>/dev/null)"
echo "DSH=$DSH"
echo "DSH_V=$([ -n "$DSH" ] && "$DSH" --version 2>/dev/null | head -1)"
if [ -f "$HOME/.config/systemd/user/dsh-web.service" ] && [ -f "$HOME/.local/bin/dsh-web-service.sh" ]; then echo SERVICE_PRESENT=yes; else echo SERVICE_PRESENT=no; fi
echo "LINGER=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
if [ -f "$HOME/.dsh/remote-web.version" ]; then echo "RUNNING_VERSION=$(head -1 "$HOME/.dsh/remote-web.version")"; fi
true
'@
  $body = (Get-RemoteSnapshotScript $Inst) + "`n" + $facts
  if ($IncludeUrl) { $body += "`n" + 'if [ -f "$HOME/.dsh/remote-web.url" ]; then printf "URL="; head -1 "$HOME/.dsh/remote-web.url"; fi; true' }
  return $body
}
function Get-RemoteFacts($SshHostName) {
  $inst = if ($SshHostName -is [string]) { [pscustomobject]@{ sshHost = $SshHostName; remotePort = 3080 } } else { $SshHostName }
  $facts = ConvertFrom-RemoteFacts (Invoke-B64 (Get-RemoteProbeScript $inst) $inst)
  if ($facts['SSH_READY'] -ne 'yes') { Throw-LauncherError 'unreachable' '远端探测未返回完整结果。' }
  return $facts
}
function Test-RemoteSnapshotHealthy($Facts) {
  return ($Facts['SNAP_STATE'] -eq 'active' -and $Facts['SNAP_LISTENING'] -eq 'yes' -and $Facts['SNAP_OWNED'] -eq 'yes' -and $Facts['SNAP_HTTP'] -in @('200','401','302','303'))
}
function Get-RemoteProbeOutputs([object[]]$Insts, [switch]$IncludeUrl) {
  $results = @{}; $jobs = @()
  foreach ($inst in $Insts) {
    try {
      $body = Get-RemoteProbeScript $inst -IncludeUrl:$IncludeUrl
      $jobs += [pscustomobject]@{ Name = $inst.name; Invocation = (Start-SshInvocation $inst (Get-B64Command $body $inst 30) 30) }
    } catch { $results[$inst.name] = "SSH_FAILURE=unknown`nSSH_HINT=无法启动 SSH 探测，请检查 OpenSSH 和配置。" }
  }
  foreach ($job in $jobs) {
    try {
      $result = Complete-SshInvocation $job.Invocation
      if ($result.Code -eq 0) { $results[$job.Name] = $result.Out }
      else {
        $failure = Get-SshFailureClass $result.Err
        $results[$job.Name] = "SSH_FAILURE=$($failure.Code)`nSSH_HINT=$($failure.Hint)"
      }
    } catch { $results[$job.Name] = "SSH_FAILURE=timeout`nSSH_HINT=SSH 探测未完成，请检查网络或 VPN。" }
  }
  return $results
}
function ConvertTo-TunnelUrl([string]$RemoteUrl, [int]$RemotePort, [int]$LocalPort) {
  $uri = $null
  if ([Uri]::TryCreate($RemoteUrl, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'http' -and $uri.Host -eq '127.0.0.1' -and $uri.Port -eq $RemotePort -and -not $uri.UserInfo) {
    $builder = New-Object UriBuilder($uri); $builder.Port = $LocalPort
    return $builder.Uri.AbsoluteUri
  }
  return "http://127.0.0.1:$LocalPort/"
}
function Get-RemoteStatus($Inst, [string]$ProbeOutput, [switch]$IncludeUrl) {
  if (-not $PSBoundParameters.ContainsKey('ProbeOutput')) { $ProbeOutput = Invoke-B64 (Get-RemoteProbeScript $Inst -IncludeUrl:$IncludeUrl) $Inst }
  $facts = ConvertFrom-RemoteFacts $ProbeOutput
  if ($facts['SSH_READY'] -ne 'yes') {
    $code = if ($facts['SSH_FAILURE']) { $facts['SSH_FAILURE'] } else { 'unknown' }
    $hint = if ($facts['SSH_HINT']) { Protect-Text $facts['SSH_HINT'] } else { '检查 SSH 配置、认证和网络。' }
    return [pscustomobject]@{ Name = $Inst.name; Kind = 'remote'; Port = $Inst.localPort; State = 'unreachable'; Detail = $hint; FailCode = $code; Hint = $hint; Http = 0; Url = ''; SshHost = $Inst.sshHost; DshInstalled = $false; SshReady = $false }
  }
  $state = Get-State $Inst.name; $port = [int]$Inst.localPort
  $tunnel = Get-RecordedPid $Inst.name 'tunnel' $Inst
  if ($tunnel -gt 0) { $port = [int](Get-InstProp $state 'localPort' $port) }
  $tunnelUp = $tunnel -gt 0 -and (Get-ListeningPid $port) -eq $tunnel
  $healthy = Test-RemoteSnapshotHealthy $facts
  $status = 'down'; $detail = '远端服务未运行'
  if ($healthy -and $tunnelUp) { $status = 'up'; $detail = '远端服务健康，受管隧道已连接' }
  elseif ($healthy) { $status = 'remote-only'; $detail = '远端服务健康，隧道未连接' }
  elseif ($tunnelUp) { $status = 'tunnel-only'; $detail = '隧道已连接，远端服务未就绪' }
  elseif ($facts['SNAP_LISTENING'] -eq 'yes' -and $facts['SNAP_OWNED'] -ne 'yes') { $status = 'port-busy'; $detail = '远端端口由未知进程占用；不会终止该进程' }
  elseif ($facts['SNAP_STATE'] -eq 'active') { $status = 'unhealthy'; $detail = '远端服务处于 active，但健康探测未通过' }
  $version = [string]$facts['DSH_V']; $update = Get-UpdateStatus $Inst $version
  $url = ''; $remoteUrl = ''
  if ($status -eq 'up') {
    if ($IncludeUrl) { $remoteUrl = [string]$facts['URL'] }
    $url = ConvertTo-TunnelUrl $remoteUrl ([int]$Inst.remotePort) $port
  }
  return [pscustomobject]@{
    Name = $Inst.name; Kind = 'remote'; Port = $port; State = $status; Detail = $detail; Http = [int]$facts['SNAP_HTTP']; Url = $url
    SshHost = $Inst.sshHost; TunnelPid = $tunnel; RemoteUrl = $remoteUrl; RemotePort = $Inst.remotePort
    DshInstalled = [bool]$version; DshVersion = $version; InstalledVersion = $version
    RunningVersion = $(if ($facts['SNAP_STATE'] -eq 'active') { [string]$facts['RUNNING_VERSION'] } else { '' })
    LatestVersion = $update.latest; TargetVersion = $update.target; PinnedVersion = $update.pinned; UpdateAvailable = $update.updateAvailable
    VersionDrift = [bool]($version -and (Get-LocalDshVersion) -and $version -ne (Get-LocalDshVersion)); SshReady = $true
    Linger = [string]$facts['LINGER']; NodeV = [string]$facts['NODE_V']; ServicePresent = ($facts['SERVICE_PRESENT'] -eq 'yes')
  }
}
function Test-RemoteDshInstalled($SshHostName) { return [bool](Get-RemoteFacts $SshHostName)['DSH'] }
function Test-RemoteDshRunnable($SshHostName) { return [string](Get-RemoteFacts $SshHostName)['DSH_V'] }
function Install-RemoteNode($Connection, $Facts, [switch]$Quiet) {
  $nodeVersion = 'v22.23.2'
  $arch = switch -Regex ([string]$Facts['ARCH']) { '^(x86_64|amd64)$' { 'x64'; break }; '^(aarch64|arm64)$' { 'arm64'; break }; default { '' } }
  if ($Facts['OS'] -ne 'Linux' -or -not $arch) { Throw-LauncherError 'unsupported-host' '自动准备运行时仅支持 Linux x64/arm64。' }
  $tarball = "node-$nodeVersion-linux-$arch"
  $installNode = @'
set -euo pipefail
umask 077
mkdir -p "$HOME/.local"
STAGING="$(mktemp -d "$HOME/.dsh-node-download.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
cd "$STAGING"
TARBALL="__TARBALL__"
URL="https://nodejs.org/dist/__NODEVER__/$TARBALL.tar.xz"
SUMS="https://nodejs.org/dist/__NODEVER__/SHASUMS256.txt"
echo 'downloading Node package'
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o SHASUMS256.txt "$SUMS"
  curl -fsSL -o "$TARBALL.tar.xz" "$URL"
else
  wget -qO SHASUMS256.txt "$SUMS"
  wget -qO "$TARBALL.tar.xz" "$URL"
fi
EXPECTED="$(awk -v f="$TARBALL.tar.xz" '$2 == f { print $1; exit }' SHASUMS256.txt)"
if ! printf '%s' "$EXPECTED" | grep -Eq '^[a-fA-F0-9]{64}$'; then
  echo "CHECKSUM_FAIL $TARBALL.tar.xz is not listed in SHASUMS256.txt"; exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then ACTUAL="$(sha256sum "$TARBALL.tar.xz" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then ACTUAL="$(shasum -a 256 "$TARBALL.tar.xz" | awk '{print $1}')"
else echo 'CHECKSUM_FAIL no SHA-256 tool available'; exit 1; fi
if [ "$EXPECTED" != "$ACTUAL" ]; then echo 'CHECKSUM_FAIL checksum mismatch'; exit 1; fi
echo 'checksum verified'
tar -xf "$TARBALL.tar.xz"
test -f "$TARBALL/bin/node" && test -f "$TARBALL/bin/npm"
chmod +x "$TARBALL/bin/node" "$TARBALL/bin/npm"
"$TARBALL/bin/node" -v
if [ -e "$HOME/.local/node" ] || [ -L "$HOME/.local/node" ]; then
  BACKUP="$(mktemp -d "$HOME/.local/node.previous.XXXXXX")"
  mv "$HOME/.local/node" "$BACKUP/runtime"
  echo 'previous managed Node retained in node.previous directory'
fi
mv "$TARBALL" "$HOME/.local/node"
for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
  [ -f "$f" ] || continue
  grep -q '.local/node/bin' "$f" 2>/dev/null && continue
  printf '\n# added by dsh-deck\nexport PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"\n' >> "$f"
done
echo NODE_INSTALLED
'@
  $body = $installNode.Replace('__TARBALL__', $tarball).Replace('__NODEVER__', $nodeVersion)
  $out = Invoke-B64 $body $Connection 240
  if ($out -notmatch '(?m)^NODE_INSTALLED\s*$') { Write-Err 'remote Node installation did not complete'; return $false }
  return $true
}
function Install-RemoteDsh($SshHostName, [switch]$Quiet, [string]$Version, [switch]$Upgrade) {
  $facts = Get-RemoteFacts $SshHostName
  if ($facts['OS'] -ne 'Linux') { Throw-LauncherError 'unsupported-host' '远端自动安装仅支持 Linux。' }
  if (-not $facts['NODE_V'] -or (Compare-Version $facts['NODE_V'] $script:NodeMinVersion) -lt 0 -or -not $facts['NPM']) {
    if (-not (Install-RemoteNode $SshHostName $facts -Quiet:$Quiet)) { return $false }
    $facts = Get-RemoteFacts $SshHostName
  }
  if ($facts['DSH_V'] -and -not $Upgrade) { if (-not $Quiet) { Write-Info 'remote dsh is already usable; install will not change its version' }; return $true }
  if (-not $Version) { $Version = (Resolve-TargetDshVersion $SshHostName -ReadOnly).target }
  if (-not $Version) { Throw-LauncherError 'unknown-version' '无法确定目标版本，请设置 dshVersion 或恢复 registry 连接。' }
  Assert-DshVersion $Version
  $prefix = [string]$facts['NPM_PREFIX']
  $prefixExpression = if (-not $prefix -or $prefix -in @('none','/usr','/usr/local')) { '"$HOME/.local"' } else { ConvertTo-ShLiteral $prefix }
  $installDsh = @'
set -euo pipefail
umask 077
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
PREFIX=__PREFIX__
NPM="$(command -v npm)"
OUTPUT="$(mktemp)"
trap 'rm -f -- "$OUTPUT"' EXIT
if ! "$NPM" install -g --prefix "$PREFIX" --no-fund --no-audit '@deepseek-ai/dsh@__TARGET__' >"$OUTPUT" 2>&1; then
  echo 'npm install failed; no rollback is guaranteed' >&2; exit 1
fi
export PATH="$PREFIX/bin:$PATH"
DSH_NOW="$("$PREFIX/bin/dsh" --version 2>/dev/null | head -1)"
[ "$DSH_NOW" = '__TARGET__' ] || { echo 'installed dsh did not pass version verification' >&2; exit 1; }
echo "DSH_NOW=$DSH_NOW"
'@
  $body = $installDsh.Replace('__PREFIX__', $prefixExpression).Replace('__TARGET__', $Version)
  $result = Invoke-B64 $body $SshHostName 240
  if ($result -notmatch ('(?m)^DSH_NOW=' + [regex]::Escape($Version) + '\s*$')) { return $false }
  $verified = Get-RemoteFacts $SshHostName
  if ($verified['DSH_V'] -ne $Version) { Throw-LauncherError 'runtime-prefix-mismatch' '已安装包，但服务 PATH 选择了另一份 dsh；未声称升级成功，请核对 npm prefix。' }
  return $true
}
function Install-RemoteService($Inst, [switch]$Quiet) {
  if (-not (Test-Path -LiteralPath $RemoteScript)) { Throw-LauncherError 'missing-resource' '缺少 remote/dsh-web-service.sh。' }
  $wrapper = Get-B64Payload (Get-Content -LiteralPath $RemoteScript -Raw -Encoding UTF8)
  $workdir = [string](Get-InstProp $Inst 'workdir' '')
  $environment = ''
  if ($workdir) { $escaped = $workdir.Replace('\','\\').Replace('"','\"').Replace('%','%%'); $environment = 'Environment="DSH_WORKDIR=' + $escaped + '"' }
  $unit = @"
[Unit]
Description=DeepSeek Harness web UI
After=network-online.target
[Service]
Type=simple
UMask=0077
Environment=DSH_PORT=$([int]$Inst.remotePort)
$environment
ExecStart=%h/.local/bin/dsh-web-service.sh
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=20
[Install]
WantedBy=default.target
"@
  $unitPayload = Get-B64Payload $unit
  $deploy = @'
set -euo pipefail
umask 077
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.dsh"
WRAPPER="$(mktemp "$HOME/.local/bin/.dsh-web.XXXXXX")"
UNIT="$(mktemp "$HOME/.config/systemd/user/.dsh-web.XXXXXX")"
trap 'rm -f -- "$WRAPPER" "$UNIT"' EXIT
printf %s __WRAPPER__ | base64 -d > "$WRAPPER"
printf %s __UNIT__ | base64 -d > "$UNIT"
chmod 700 "$WRAPPER"
mv -f "$WRAPPER" "$HOME/.local/bin/dsh-web-service.sh"
mv -f "$UNIT" "$HOME/.config/systemd/user/dsh-web.service"
systemctl --user daemon-reload
systemctl --user enable dsh-web.service >/dev/null 2>&1
if loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then echo LINGER_SET; else echo LINGER_UNAVAILABLE; fi
echo DEPLOYED
'@
  $out = Invoke-B64 ($deploy.Replace('__WRAPPER__', $wrapper).Replace('__UNIT__', $unitPayload)) $Inst 45
  if ($out -notmatch '(?m)^DEPLOYED\s*$') { return $false }
  if ($out -match 'LINGER_UNAVAILABLE') { Write-Warn2 '未能启用 linger；退出 SSH 后用户服务可能停止。' }
  if (-not $Quiet) { Write-Ok 'service files deployed; not started or restarted' }
  return $true
}
function Start-Tunnel($Inst, [switch]$Quiet) {
  $state = Get-State $Inst.name; $port = [int]$Inst.localPort
  $existing = Get-RecordedPid $Inst.name 'tunnel' $Inst
  if ($existing -gt 0) {
    $port = [int](Get-InstProp $state 'localPort' $port)
    if ((Get-ListeningPid $port) -eq $existing) { return $port }
    Throw-LauncherError 'tunnel-unhealthy' '已有受管 SSH 隧道未监听；请先 stop 再重试。'
  }
  $rawPid = [int](Get-InstProp $state 'tunnelPid' 0)
  if ($rawPid -gt 0 -and (Test-ProcessAlive $rawPid)) { Throw-LauncherError 'ownership-unknown' '旧隧道记录指向无法核对归属的进程，未覆盖记录。' }
  if (Test-PortListening $port) { $port = Find-FreePort ($port + 1) }
  if ($port -le 0) { Throw-LauncherError 'port-busy' '找不到可用的本地隧道端口。' }
  $arguments = Join-NativeArguments @(Get-SshArguments $Inst -Purpose tunnel -LocalPort $port -RemotePort ([int]$Inst.remotePort))
  if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $process = Start-Process -FilePath 'ssh.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LogDir "$($Inst.name).tunnel.log") -RedirectStandardError (Join-Path $LogDir "$($Inst.name).tunnel.err")
  $stamp = Get-ProcessStamp (Get-ProcessRecord $process.Id)
  Set-StateField $Inst.name @{ tunnelPid = $process.Id; tunnelStartedAt = $stamp; localPort = $port; context = $script:ConfigContext }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
    if ((Get-ListeningPid $port) -eq $process.Id -and (Get-RecordedPid $Inst.name 'tunnel' $Inst) -eq $process.Id) { return $port }
    Start-Sleep -Milliseconds 250
  }
  if (-not (Stop-OwnedProcess $process.Id $stamp)) { Throw-LauncherError 'tunnel-timeout' '隧道未就绪且未能停止；保留进程记录。远端服务可能仍在运行。' }
  Set-StateField $Inst.name @{ tunnelPid = 0; tunnelStartedAt = '' }
  Write-Err 'tunnel failed to become ready; its child was stopped; remote service may remain running'
  return 0
}
function Stop-Tunnel($Inst, [switch]$Quiet, [switch]$RemoveState) {
  $state = Get-State $Inst.name; $managed = Get-RecordedPid $Inst.name 'tunnel' $Inst
  if ($managed -gt 0) {
    if (-not (Stop-OwnedProcess $managed ([string](Get-InstProp $state 'tunnelStartedAt' '')))) { Throw-LauncherError 'stop-failed' 'SSH 隧道未停止；保留记录。' }
  } elseif ([int](Get-InstProp $state 'tunnelPid' 0) -gt 0 -and (Test-ProcessAlive ([int]$state.tunnelPid))) {
    Throw-LauncherError 'ownership-unknown' '无法核对记录中 SSH 进程的归属；未终止或遗忘该进程。'
  }
  if ($RemoveState) { Remove-State $Inst.name }
  elseif ($state) { Set-StateField $Inst.name @{ tunnelPid = 0; tunnelStartedAt = ''; url = ''; remoteUrl = '' } }
  return $true
}
function Start-RemoteInstance($Inst, [switch]$Quiet) {
  $facts = Get-RemoteFacts $Inst
  if (-not (Test-RemoteSnapshotHealthy $facts)) {
    if ($facts['SNAP_LISTENING'] -eq 'yes' -and $facts['SNAP_OWNED'] -ne 'yes') { Throw-LauncherError 'remote-port-busy' '远端端口不属于该 systemd service；未终止任何未知进程。' }
    $needsSoftware = -not $facts['DSH_V'] -or -not $facts['NODE_V'] -or (Compare-Version $facts['NODE_V'] $script:NodeMinVersion) -lt 0
    $needsService = $facts['SERVICE_PRESENT'] -ne 'yes'
    if (($needsSoftware -or $needsService) -and -not (Test-InstFlag $Inst 'autoInstall' $true)) {
      Throw-LauncherError 'auto-install-disabled' 'autoInstall=false：start 不会安装软件或部署服务定义。请先预览并执行显式 install。'
    }
    if ($needsSoftware -and -not (Install-RemoteDsh $Inst -Quiet:$Quiet)) { return $false }
    if ($needsService -and -not (Install-RemoteService $Inst -Quiet:$Quiet)) { return $false }
    $facts = Get-RemoteFacts $Inst
  }
  $pin = Get-DesiredDshVersion $Inst
  if ($pin -and $facts['DSH_V'] -ne $pin) { Throw-LauncherError 'pin-mismatch' '远端已安装版本与 dshVersion 不符；start 不会替换可用软件，请执行显式 upgrade。' }
  $started = $false
  if (-not (Test-RemoteSnapshotHealthy $facts)) {
    if ($facts['SNAP_STATE'] -ne 'active') {
      $null = Invoke-B64 'set -e; systemctl --user start dsh-web.service; echo START_REQUESTED' $Inst 40
      $started = $true
    }
    $deadline = (Get-Date).AddSeconds(60)
    do {
      $facts = ConvertFrom-RemoteFacts (Invoke-B64 (Get-RemoteSnapshotScript $Inst) $Inst)
      if (Test-RemoteSnapshotHealthy $facts) { break }
      Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    if (-not (Test-RemoteSnapshotHealthy $facts)) {
      if ($started) {
        try { $null = Invoke-B64 'set -e; systemctl --user stop dsh-web.service; echo STOPPED_AFTER_TIMEOUT' $Inst 30 }
        catch { Throw-LauncherError 'remote-start-timeout' '远端启动超时，停止新启动服务也失败；请检查远端服务，未声称操作已撤销。' }
      }
      Throw-LauncherError 'remote-start-timeout' '远端服务未通过归属及 HTTP 检查；未重启原有进程，新启动的服务已请求停止。'
    }
  }
  $port = Start-Tunnel $Inst -Quiet:$Quiet
  if ($port -le 0) { return $false }
  if (-not $Quiet) { Write-Ok "$($Inst.name): remote service healthy; tunnel connected on port $port" }
  return $true
}
function Stop-RemoteInstance($Inst, [switch]$Quiet) {
  $null = Stop-Tunnel $Inst -Quiet:$Quiet
  if (-not (Test-InstFlag $Inst 'stopRemoteService' $true)) {
    if (-not $Quiet) { Write-Info '仅断开隧道；stopRemoteService=false，远端服务未请求停止。' }
    return $true
  }
  $facts = Get-RemoteFacts $Inst
  if ($facts['SERVICE_PRESENT'] -eq 'yes' -or $facts['SNAP_STATE'] -eq 'active') {
    $null = Invoke-B64 'set -e; systemctl --user stop dsh-web.service; echo STOP_REQUESTED' $Inst 40
    $after = ConvertFrom-RemoteFacts (Invoke-B64 (Get-RemoteSnapshotScript $Inst) $Inst)
    if ($after['SNAP_STATE'] -eq 'active' -or $after['SNAP_OWNED'] -eq 'yes') { Throw-LauncherError 'stop-failed' '远端受管服务仍然存活；未报告停止成功。' }
  }
  Remove-State $Inst.name
  return $true
}
function Upgrade-RemoteDsh($Inst, [string]$Version, [switch]$DryRun) {
  if (-not $Version) { $Version = (Resolve-TargetDshVersion $Inst -ReadOnly).target }
  if (-not $Version) { Throw-LauncherError 'unknown-version' '无法确定远端目标版本。' }
  $facts = Get-RemoteFacts $Inst
  if ($facts['DSH_V'] -eq $Version) { return $true }
  if ($DryRun) { return $true }
  if ($facts['SNAP_LISTENING'] -eq 'yes' -and $facts['SNAP_OWNED'] -ne 'yes') { Throw-LauncherError 'remote-port-busy' '未知进程占用远端端口，拒绝升级或重启。' }
  $running = $facts['SNAP_STATE'] -eq 'active'
  if (-not (Install-RemoteDsh $Inst -Version $Version -Upgrade)) { return $false }
  if (-not (Install-RemoteService $Inst)) { return $false }
  if ($running) {
    $null = Invoke-B64 'set -e; systemctl --user restart dsh-web.service; echo RESTART_REQUESTED' $Inst 45
    $deadline = (Get-Date).AddSeconds(60)
    do {
      $after = ConvertFrom-RemoteFacts (Invoke-B64 (Get-RemoteSnapshotScript $Inst) $Inst)
      if (Test-RemoteSnapshotHealthy $after) { return $true }
      Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    Throw-LauncherError 'restart-failed' '远端软件已变更，但服务未通过健康检查；不保证回滚，请检查应用日志。'
  }
  return $true
}
