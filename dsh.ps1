<#
.SYNOPSIS
  dsh-deck - one entry point for every DeepSeek Harness (dsh) instance you run.

.DESCRIPTION
  Manages dsh web instances on this Windows machine AND on remote Linux hosts,
  each reached through an SSH port-forward that the launcher owns.

  The problem it removes:
    * locally you had to open a terminal and run `dsh web` every time;
    * remotely you had to start the server and then hand-build an SSH tunnel.

  Now one command (or one desktop shortcut) starts the server, brings up the
  tunnel, extracts the authenticated URL and opens your browser.

  Design notes, each one learned the hard way:
    * Remote scripts travel as base64 and are decoded with `base64 -d` on the
      far side. Piping raw text into `ssh ... bash -s` mangles bytes in this
      environment, and nested quoting through PowerShell -> ssh -> bash is a
      trap. Base64 is one ASCII line that nothing can reinterpret.
    * SSH ControlMaster/ControlPersist is NOT usable from Windows OpenSSH here
      ("getsockname failed: Not a socket"), so every host probe is a single
      combined call rather than many small ones.
    * Newer dsh (>= 0.1.5) prints a one-time token URL and answers `/` with 401
      until that token is redeemed. Older dsh (<= 0.1.1) prints no token and
      answers 200. Both shapes are handled, and the token is always redeemed
      through the LOCAL tunnel port, because the signed cookie is bound to the
      authority the request arrives with.
    * A spawned node.exe would otherwise flash a conhost window, so the local
      server is started with CREATE_NO_WINDOW.

.PARAMETER Command
  menu     interactive control panel (default)
  status   show every instance and its health
  start    start an instance (server + tunnel, then optionally open browser)
  stop     stop an instance (kills local server and/or tunnel + remote service)
  restart  stop then start
  open     open the browser at an already-running instance
  logs     tail or print an instance's log
  add      register a new host by reading your ~/.ssh/config
  list     list configured instances
  install  deploy the remote systemd service to a host
  doctor   diagnose the environment and every configured host

.PARAMETER Target
  One or more instance names (or "local"). Defaults to every enabled instance.

.EXAMPLE
  .\dsh.ps1                       # interactive control panel
.EXAMPLE
  .\dsh.ps1 status
.EXAMPLE
  .\dsh.ps1 start Research_Prod
.EXAMPLE
  .\dsh.ps1 start -NoOpen         # bring everything up, do not touch the browser
.EXAMPLE
  .\dsh.ps1 install DuckServer    # deploy the remote service to a new host
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('menu','app','tray','tray-start','tray-stop','tray-loop','status','start','stop','restart','open','logs','add','list','install','doctor')]
  [string]$Command = 'menu',

  [Parameter(Position = 1)]
  [string[]]$Target,

  [switch]$NoOpen,
  [switch]$AppWindow,
  [int]$LocalPort,
  [int]$Lines = 40,
  [switch]$Follow,
  [string]$SshHost,
  [string]$Name,
  [int]$Port,

  [switch]$Json,        # emit machine-readable JSON (used by the desktop app)
  [switch]$NoProbe,     # status only: skip the HTTP liveness probe, much faster
  [switch]$Probe,       # status only: force the probe (default is probe on)

  # Config file to use instead of the discovered one. Also settable through
  # $DSH_LAUNCHER_CONFIG, which is how you keep several configurations around.
  [string]$Config,

  # `app -Stop` stops the desktop app's backend and closes its window. Declared
  # here because PowerShell rejects an undeclared named parameter outright
  # (NamedParameterNotFound) rather than treating it as a positional argument.
  [switch]$Stop,

  [string]$SshConfigPath,  # override the ssh config used for host discovery

  [int]$TrayInterval = 20  # seconds between tray state polls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This script is UTF-8 (with BOM). Windows PowerShell 5.1 otherwise encodes its
# own console output using the legacy ANSI code page, which turns every Chinese
# string into mojibake the moment stdout is redirected to a file or a pipe. The
# desktop app reads this output, and the SSH probe scripts are assembled from
# Chinese-bearing strings, so this has to be UTF-8.
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

# --------------------------------------------------------------------------
# Paths and constants
# --------------------------------------------------------------------------

$LauncherDir = $PSScriptRoot
if (-not $LauncherDir) { $LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# Inlined rather than calling Get-HomeDir: the function is defined further down
# with the rest of the config helpers, and a script-scope function is not
# callable before its definition has been executed.
$HomeDir      = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $LauncherDir }
$StateDir     = Join-Path $LauncherDir 'state'
$LogDir       = Join-Path $LauncherDir 'logs'
$RemoteScript = Join-Path $LauncherDir 'remote\dsh-web-service.sh'
$RemotePath   = '.local/bin/dsh-web-service.sh'
$RemoteUnit   = '.config/systemd/user/dsh-web.service'
$DshHome      = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HomeDir '.dsh' }

foreach ($d in @($StateDir, $LogDir)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# Script-scope caches, pre-declared so StrictMode permits reading them.
$script:LocalDshVersion = ''

# --------------------------------------------------------------------------
# Console helpers
# --------------------------------------------------------------------------

$script:UseColor = $true
try { if ([Console]::IsOutputRedirected) { $script:UseColor = $false } } catch { }

function Write-C([string]$Text, [string]$Color = 'Gray') {
  if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Write-Head([string]$Text) {
  Write-Host ''
  Write-C ("  " + $Text) 'Cyan'
  Write-C ("  " + ('-' * $Text.Length)) 'DarkGray'
}

function Write-Ok([string]$Text)   { Write-C "  [ok]   $Text" 'Green' }
function Write-Warn2([string]$Text){ Write-C "  [warn] $Text" 'Yellow' }
function Write-Err([string]$Text)  { Write-C "  [fail] $Text" 'Red' }
function Write-Info([string]$Text) { Write-C "  [info] $Text" 'Gray' }

function Write-Log([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  try { Add-Content -Path (Join-Path $LogDir 'launcher.log') -Value $line -Encoding UTF8 } catch { }
}

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------

function Invoke-B64([string]$Script, [string]$SshHostName, [int]$TimeoutSec = 30) {
  <# Run a bash script on a remote host. The script is base64-encoded so that
     nothing between here and the remote bash can reinterpret its bytes: nested
     quoting through PowerShell -> ssh -> bash mangles anything else.
     The payload is ASCII by construction, so the encoding of our own pipe into
     ssh cannot corrupt it regardless of the console code page. #>
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
  $out = & ssh -n -o BatchMode=yes -o ConnectTimeout=10 $SshHostName "echo $b64 | base64 -d | bash" 2>&1
  return ($out | Out-String)
}

function Test-SshReachable([string]$SshHostName, [int]$TimeoutSec = 8) {
  $out = & ssh -n -o BatchMode=yes -o ConnectTimeout=$TimeoutSec -o StrictHostKeyChecking=accept-new $SshHostName "echo REACHABLE" 2>&1
  return (($out | Out-String) -match 'REACHABLE')
}

function Get-ListeningPid([int]$PortValue) {
  <# Returns the pid listening on the loopback address of $PortValue.
     Deliberately ignores listeners bound to other local addresses: this machine
     has Termius on 127.0.0.124:3080 as well as dsh on 127.0.0.1:3080, and
     "first listener wins" picks the wrong one. #>
  try {
    $all = @(Get-NetTCPConnection -State Listen -LocalPort $PortValue -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return 0 }
    $loop = $all | Where-Object { $_.LocalAddress -eq '127.0.0.1' } | Select-Object -First 1
    if ($loop) { return [int]$loop.OwningProcess }
    $any = $all | Where-Object { $_.LocalAddress -eq '::1' } | Select-Object -First 1
    if ($any) { return [int]$any.OwningProcess }
    return 0
  } catch { }
  return 0
}

function Test-PortListening([int]$PortValue) { return ((Get-ListeningPid $PortValue) -gt 0) }

function Get-ProcessNameSafe([int]$ProcId) {
  if ($ProcId -le 0) { return '' }
  $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
  if ($p) { return $p.ProcessName }
  return ''
}

function Test-Http([string]$Url, [int]$TimeoutSec = 6) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 0 -TimeoutSec $TimeoutSec -ErrorAction Stop
    return [int]$r.StatusCode
  } catch {
    $resp = $null
    try { $resp = $_.Exception.Response } catch { }
    if ($resp -and $resp.StatusCode) { return [int]$resp.StatusCode }
    return 0
  }
}

function Find-FreePort([int]$Start) {
  for ($p = $Start; $p -lt ($Start + 50); $p++) {
    if (-not (Test-PortListening $p)) { return $p }
  }
  return $Start
}

function Find-DshLocal {
  <# Locate the dsh entry point on this machine. Prefers the node script path so
     the server can be spawned without a console window. #>
  $candidates = @()
  $npmRoot = (npm root -g 2>$null | Select-Object -First 1)
  if ($npmRoot) { $candidates += (Join-Path $npmRoot '@deepseek-ai\dsh\lib\bin.js') }
  $candidates += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js')
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Get-NodeExe {
  $n = Get-Command node -ErrorAction SilentlyContinue
  if ($n) { return $n.Source }
  $p = Join-Path $env:ProgramFiles 'nodejs\node.exe'
  if (Test-Path $p) { return $p }
  return $null
}

function Get-LocalUrl([string]$InstanceName, [int]$PortValue) {
  <# Returns the URL to open for a local instance.

     dsh prints exactly one readiness line, built as `dsh web: ${webUrl}` where
     webUrl is `http://127.0.0.1:${port}` using the BOUND port (so --port 0 is
     reflected correctly). Newer builds append the one-time `?token=...`; older
     builds print no query at all. The `[^\s()]+` class deliberately stops at
     the `(LAN: ...)` suffix that only appears on an all-interfaces bind.

     Note the local build (0.1.1-rc.2) never prints a token and does not fence
     `/` at all, while the remote build (0.1.5-rc.1) does both. Reading the URL
     out of the log keeps this function correct for either. #>
  $log = Join-Path $LogDir "$InstanceName.server.log"
  if (Test-Path $log) {
    $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
    if ($text) {
      $m = [regex]::Matches($text, 'dsh web:\s+(http://[^\s()]+)')
      if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }
    }
  }
  return "http://127.0.0.1:$PortValue"
}

# --------------------------------------------------------------------------
# Configuration
#
# Two file shapes are supported, so the tool works both as a personal setup and
# as a shared team repo:
#
#   profiles[]  a shared .dshproj.json describing servers, with per-user
#               sshUser/identityFile overrides under userProfiles.
#   instances[] a per-machine hosts.json listing concrete instances, with
#               "profile": "<name>" pulling in a profile's connection defaults.
#
# Resolution order for the config file (first hit wins):
#   1. -Config <path>
#   2. $DSH_LAUNCHER_CONFIG
#   3. <launcher>\hosts.json          (this machine's own config)
#   4. <launcher>\.dshproj.json       (shared repository config)
#   5. ~/.dsh-launcher/hosts.json     (per-user global config)
# If none exists, a local-only default is written to (5) so the tool still works
# with zero setup and no write access to the install directory.
# --------------------------------------------------------------------------

function Get-HomeDir {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  if ($env:HOME) { return $env:HOME }
  return $LauncherDir
}

function Get-Param([string]$Name) {
  <# Read an optional script parameter safely. Under Set-StrictMode -Version
     Latest, referencing an unbound parameter of the script scope throws
     "cannot be retrieved because it has not been set", so every optional read
     goes through $PSBoundParameters rather than touching the variable. #>
  if ($PSBoundParameters.ContainsKey($Name)) {
    $v = $PSBoundParameters[$Name]
    if ($v) { return [string]$v }
  }
  return ''
}

function Resolve-ConfigPath {
  $explicit = Get-Param 'Config'
  if ($explicit) { return $explicit }
  if ($env:DSH_LAUNCHER_CONFIG) { return $env:DSH_LAUNCHER_CONFIG }
  foreach ($c in @(
    (Join-Path $LauncherDir 'hosts.json'),
    (Join-Path $LauncherDir '.dshproj.json'),
    (Join-Path $HomeDir '.dsh-launcher\hosts.json')
  )) {
    if (Test-Path $c) { return $c }
  }
  return (Join-Path $HomeDir '.dsh-launcher\hosts.json')
}

function Get-SshConfigPath {
  <# honours -SshConfigPath, then $DSH_SSH_CONFIG, then the user's ~/.ssh/config #>
  $explicit = Get-Param 'SshConfigPath'
  if ($explicit) { return $explicit }
  if ($env:DSH_SSH_CONFIG) { return $env:DSH_SSH_CONFIG }
  return (Join-Path $HomeDir '.ssh\config')
}

function Get-DefaultHosts {
  <# Local-only. A fresh clone runs immediately; servers are added on purpose. #>
  return [ordered]@{
    version   = 1
    profiles  = @()
    instances = @(
      [ordered]@{
        name        = 'local'
        kind        = 'local'
        enabled     = $true
        port        = 3080
        workdir     = (Join-Path (Get-HomeDir) 'Documents')
        description = 'dsh web on this machine'
      }
    )
  }
}

function Get-HostsConfig {
  $path = Resolve-ConfigPath
  if (-not (Test-Path $path)) {
    $cfg = Get-DefaultHosts
    Save-HostsConfig $cfg
    return $cfg
  }
  $raw = Get-Content $path -Raw -Encoding UTF8
  if (-not $raw -or -not $raw.Trim()) { return Get-DefaultHosts }
  $obj = $raw | ConvertFrom-Json
  if (-not $obj.instances) { throw "config has no 'instances' array: $path" }
  return $obj
}

function Save-HostsConfig($Cfg) {
  $path = Resolve-ConfigPath
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $Cfg | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
}

function Get-ConfigProp($Obj, [string]$Name) {
  <# Property access that tolerates absence. Under StrictMode, $obj.missing
     throws, and config files written before a key existed legitimately lack
     it -- for example hosts.json created before profiles were introduced. #>
  if ($Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
  return $null
}

function Get-Profiles {
  <# Normalised profile lookup: profile -> merged connection defaults.
     Per-user overrides win over the shared profile so the same repo config
     serves everyone without editing committed files. #>
  $cfg = Get-HostsConfig
  $map = @{}
  $me = $env:USERNAME
  if (-not $me) { $me = $env:USER }
  $userProfiles = Get-ConfigProp $cfg 'userProfiles'
  foreach ($p in @(Get-ConfigProp $cfg 'profiles')) {
    if (-not $p -or -not $p.name) { continue }
    $conn = [ordered]@{
      sshHost    = $p.sshHost
      remotePort = if ($p.remotePort) { [int]$p.remotePort } else { 3080 }
    }
    foreach ($k in @('sshUser','identityFile','runAsUser','jumpHost','description')) {
      if ($p.PSObject.Properties[$k] -and $p.$k) { $conn[$k] = $p.$k }
    }
    $up = $null
    if ($userProfiles -and $me -and $userProfiles.PSObject.Properties[$me]) {
      $up = $userProfiles.PSObject.Properties[$me].Value
    }
    if ($up -and $up.PSObject.Properties[$p.name]) {
      $ov = $up.PSObject.Properties[$p.name].Value
      foreach ($prop in $ov.PSObject.Properties) { $conn[$prop.Name] = $prop.Value }
    }
    $map[$p.name] = $conn
  }
  return $map
}

function Get-Instances([string[]]$Names) {
  <# Callers wrap the result in @(), which turns zero-or-one results into a real
     array so .Count is always safe under Set-StrictMode -Version Latest.
     Do NOT return ,@(...) here: that nests the array one level deeper and makes
     `foreach` iterate over the collection itself instead of its instances. #>
  $cfg = Get-HostsConfig
  $all = @($cfg.instances)

  # Expand "profile" references into concrete connection fields.
  $profiles = Get-Profiles
  $all = @($all | ForEach-Object {
    $i = $_
    $obj = [ordered]@{}
    foreach ($prop in $i.PSObject.Properties) { $obj[$prop.Name] = $prop.Value }
    if ($obj['profile']) {
      $pname = [string]$obj['profile']
      if (-not $profiles.ContainsKey($pname)) { throw "instance '$($obj['name'])' references unknown profile '$pname'" }
      $conn = $profiles[$pname]
      foreach ($k in $conn.Keys) {
        # instance-level value wins; profile fills the gaps
        if (-not $obj.Contains($k) -or -not $obj[$k]) { $obj[$k] = $conn[$k] }
      }
      if (-not $obj['name']) { $obj['name'] = $pname }
      if (-not $obj['kind']) { $obj['kind'] = 'remote' }
    }
    [pscustomobject]$obj
  })

  if (-not $Names -or @($Names).Count -eq 0) {
    return @($all | Where-Object { $_.enabled -ne $false })
  }
  $sel = @()
  foreach ($n in $Names) {
    $hit = @($all | Where-Object { $_.name -eq $n })
    if ($hit.Count -eq 0) { Write-Warn2 "unknown instance '$n' (see: dsh.ps1 list)" ; continue }
    $sel += $hit
  }
  return @($sel)
}


# --------------------------------------------------------------------------
# Per-instance runtime state
# --------------------------------------------------------------------------

function Get-State([string]$InstanceName) {
  $f = Join-Path $StateDir "$InstanceName.json"
  if (-not (Test-Path $f)) { return $null }
  try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Set-State([string]$InstanceName, $Obj) {
  $f = Join-Path $StateDir "$InstanceName.json"
  $Obj | ConvertTo-Json -Depth 6 | Set-Content -Path $f -Encoding UTF8
}

function Remove-State([string]$InstanceName) {
  $f = Join-Path $StateDir "$InstanceName.json"
  if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

function Get-RecordedPid([string]$InstanceName, [string]$Kind) {
  <# Kind is 'server' or 'tunnel'. Returns a live pid or 0. Guards against pid
     reuse by checking the process name still matches what we started. #>
  $st = Get-State $InstanceName
  if (-not $st) { return 0 }
  $field = if ($Kind -eq 'tunnel') { 'tunnelPid' } else { 'serverPid' }
  $prop = $st.PSObject.Properties[$field]
  if (-not $prop) { return 0 }
  $rec = [int]$prop.Value
  if ($rec -le 0) { return 0 }
  $name = Get-ProcessNameSafe $rec
  if (-not $name) { return 0 }
  if ($Kind -eq 'tunnel' -and $name -notmatch 'ssh') { return 0 }
  if ($Kind -eq 'server' -and $name -notmatch 'node') { return 0 }
  return $rec
}

# --------------------------------------------------------------------------
# Local instance
# --------------------------------------------------------------------------

function Get-LocalStatus($Inst, [switch]$NoProbeHttp) {
  $port = [int]$Inst.port
  $ourPid  = Get-RecordedPid $Inst.name 'server'

  # Prefer the port we actually recorded. An adopted instance, or one started
  # with -LocalPort, does not necessarily listen on the configured port, and
  # reporting the config value there would contradict the URL beside it.
  $st = Get-State $Inst.name
  $statePort = 0
  if ($st -and $st.PSObject.Properties['port']) { $statePort = [int]$st.port }
  if ($statePort -gt 0 -and (Test-PortListening $statePort)) { $port = $statePort }

  $holding = Get-ListeningPid $port
  $holdingName = Get-ProcessNameSafe $holding

  $state = 'down'
  $detail = ''
  if ($holding -gt 0) {
    if ($ourPid -gt 0 -and $holding -eq $ourPid) { $state = 'up'; $detail = "本机服务运行中 · 端口 $port" }
    elseif ($holdingName -eq 'node') { $state = 'up-external'; $detail = "本机服务运行中 · 端口 $port" }
    else { $state = 'port-busy'; $detail = "端口 $port 被 $holdingName 占用" }
  } else {
    $detail = "未启动 · 端口 $port"
  }
  $httpCode = 0
  if (-not $NoProbeHttp -and ($state -eq 'up' -or $state -eq 'up-external')) {
    $httpCode = Test-Http "http://127.0.0.1:$port/"
  }

  # Only advertise a URL while something actually serves it; otherwise a stale
  # log would keep showing a port that is no longer listening.
  $url = ''
  if ($state -eq 'up' -or $state -eq 'up-external') { $url = Get-LocalUrl $Inst.name $port }

  return [pscustomobject]@{
    Name = $Inst.name; Kind = 'local'; Port = $port
    State = $state; Detail = $detail; Http = $httpCode
    Url = $url
  }
}

function Start-LocalInstance($Inst, [switch]$Quiet, [int]$PortOverride = 0) {
  $name = $Inst.name
  $port = [int]$Inst.port
  if ($PortOverride -gt 0) { $port = $PortOverride }
  $log  = Join-Path $LogDir "$name.server.log"

  # Reuse an instance already listening on this port only when no override asked
  # for a different one: -LocalPort 3097 means "run a second instance there", not
  # "adopt whatever is on 3080".
  if (Test-PortListening $port) {
    $holding = Get-ListeningPid $port
    $holdingName = Get-ProcessNameSafe $holding
    if ($holdingName -eq 'node') {
      if (-not $Quiet) { Write-Info "$name is already served on port $port (pid $holding) - reusing it" }
      # Adopt the running process so stop/status work consistently.
      Set-State $name ([pscustomobject]@{
        serverPid = $holding; port = $port
        url = (Get-LocalUrl $name $port); updatedAt = (Get-Date).ToString('o')
      })
      return $port
    }
    Write-Err "$name cannot start: port $port is held by $holdingName (pid $holding). Use -LocalPort to pick another."
    return 0
  }

  $bin = Find-DshLocal
  if (-not $bin) { Write-Err "$name cannot start: dsh not found. Install with: npm i -g @deepseek-ai/dsh"; return 0 }
  $node = Get-NodeExe
  if (-not $node) { Write-Err "$name cannot start: node.exe not found on PATH"; return 0 }

  if (Test-Path $log) { Move-Item -Force $log "$log.1" -ErrorAction SilentlyContinue }

  $workdir = if ($Inst.workdir) { $Inst.workdir } else { $env:USERPROFILE }
  if (-not (Test-Path $workdir)) { $workdir = $env:USERPROFILE }

  # CREATE_NO_WINDOW (0x08000000) keeps node from flashing a conhost window.
  $args = "`"$bin`" web --port $port --no-open"
  $proc = Start-Process -FilePath $node -ArgumentList $args -WorkingDirectory $workdir `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
            -WindowStyle Hidden -PassThru
  Write-Log "started local $name pid $($proc.Id) on port $port"

  # Wait for the listener, and for the URL line when this dsh version prints one.
  $deadline = (Get-Date).AddSeconds(90)
  $up = $false
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    if (Test-PortListening $port) { $up = $true; break }
    Start-Sleep -Milliseconds 300
  }
  if (-not $up) {
    Write-Err "$name failed to start within 90s. Last log lines:"
    if (Test-Path $log) { Get-Content $log -Tail 20 | ForEach-Object { Write-C "    $_" 'DarkGray' } }
    return 0
  }

  # Give dsh a moment to print its URL, then record state.
  Start-Sleep -Seconds 2
  $url = Get-LocalUrl $name $port
  Set-State $name ([pscustomobject]@{
    serverPid = $proc.Id; port = $port; url = $url; updatedAt = (Get-Date).ToString('o')
  })
  if (-not $Quiet) { Write-Ok "$name up on port $port (pid $($proc.Id))" }
  return $port
}

function Stop-LocalInstance($Inst, [switch]$Quiet) {
  $name = $Inst.name
  $stopped = $false

  $pid_ = Get-RecordedPid $name 'server'
  if ($pid_ -gt 0) {
    & taskkill.exe /PID $pid_ /T /F 2>&1 | Out-Null
    $stopped = $true
    if (-not $Quiet) { Write-Ok "$name stopped (pid $pid_)" }
    Write-Log "stopped local $name pid $pid_"
  } else {
    # Fall back to the configured port, or the port the instance was last seen
    # on (an adopted or -LocalPort-started instance may not match the config).
    $port = [int]$Inst.port
    $st = Get-State $name
    if ($st -and $st.PSObject.Properties['port']) {
      $recordedPort = [int]$st.port
      if ($recordedPort -gt 0) { $port = $recordedPort }
    }
    $holding = Get-ListeningPid $port
    if ($holding -gt 0 -and (Get-ProcessNameSafe $holding) -eq 'node') {
      if (-not $Quiet) { Write-Warn2 "$name has no recorded pid; leaving the node process on port $port (pid $holding) alone" }
      if (-not $Quiet) { Write-Info "stop it manually with: taskkill /PID $holding /T /F" }
    } else {
      if (-not $Quiet) { Write-Info "$name is not running" }
    }
  }
  Remove-State $name
  # Drop the recorded log too, otherwise its startup line keeps advertising a
  # port that is no longer served.
  $log = Join-Path $LogDir "$name.server.log"
  foreach ($f in @($log, "$log.1")) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
  return $stopped
}

# --------------------------------------------------------------------------
# Remote instance
# --------------------------------------------------------------------------

function Get-LocalDshVersion {
  <# Cached: the doctor and every remote status row want this, and it cannot
     change while the launcher is running. #>
  if ($script:LocalDshVersion) { return $script:LocalDshVersion }
  $v = ''
  try {
    $bin = Find-DshLocal
    if ($bin) {
      $out = & node $bin --version 2>&1 | Out-String
      if ($out -match '(\d+\.\d+[^\s]*)') { $v = $Matches[1] }
    }
  } catch { }
  $script:LocalDshVersion = $v
  return $v
}

function Get-RemoteProbeScript($Inst) {
  $rport = [int]$Inst.remotePort
  @"
set +e
# Same PATH shape as the service: a locally installed node wins, so the reported
# version is the one the running service actually uses.
if [ -x "`$HOME/.local/node/bin/node" ]; then export PATH="`$HOME/.local/node/bin:`$PATH"; fi
export PATH="`$HOME/.local/bin:`$HOME/.npm-global/bin:`$PATH"
echo "SSH_USER=`$(whoami)"
echo "SSH_HOME=`$HOME"
echo "NODE=`$(command -v node 2>/dev/null || echo none)"
echo "NODE_V=`$(node -v 2>/dev/null || echo none)"
_dsh="`$(command -v dsh 2>/dev/null || true)"
[ -z "`$_dsh" ] && [ -x "`$HOME/.local/bin/dsh" ] && _dsh="`$HOME/.local/bin/dsh"
echo "DSH=`${_dsh:-none}"
echo "DSH_V=`$("`${_dsh:-dsh}" --version 2>/dev/null | head -1 || echo none)"
echo "UNIT_ENABLED=`$(systemctl --user is-enabled dsh-web.service 2>/dev/null | head -1 || echo none)"
echo "UNIT_ACTIVE=`$(systemctl --user is-active dsh-web.service 2>/dev/null | head -1 || echo none)"
echo "LINGER=`$(loginctl show-user `$(whoami) -p Linger --value 2>/dev/null || echo unknown)"
if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$rport"; then echo "LISTENING=yes"; else echo "LISTENING=no"; fi
if [ -f `$HOME/$RemotePath ]; then echo "SCRIPT=yes"; else echo "SCRIPT=no"; fi
if [ -f `$HOME/.dsh/remote-web.url ]; then echo "URL=`$(cat `$HOME/.dsh/remote-web.url 2>/dev/null | head -1)"; else echo "URL="; fi
"@
}

function Get-RemoteStatus($Inst) {
  $sshHost = $Inst.sshHost
  if (-not (Test-SshReachable $sshHost)) {
    return [pscustomobject]@{
      Name = $Inst.name; Kind = 'remote'; Port = [int]$Inst.localPort
      State = 'unreachable'; Detail = "连不上 $sshHost（可能需要 VPN）"; Http = 0; Url = ''
      SshHost = $sshHost; DshInstalled = $false; SshReady = $false
    }
  }
  $out = Invoke-B64 (Get-RemoteProbeScript $Inst) $sshHost
  $f = @{}
  foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^([A-Z_]+)=(.*)$') { $f[$Matches[1]] = $Matches[2] }
  }

  # Tunnel state, from our own records. The live port comes from state, because
  # a tunnel that had to fall back from a busy port recorded the port it used.
  $tunPid = Get-RecordedPid $Inst.name 'tunnel'
  $lp = [int]$Inst.localPort
  $st = Get-State $Inst.name
  if ($st -and $st.PSObject.Properties['localPort']) {
    $recorded = [int]$st.localPort
    if ($recorded -gt 0) { $lp = $recorded }
  }
  $tunnelUp = ($tunPid -gt 0) -and (Test-PortListening $lp)

  $remoteActive = ("$(if ($f.ContainsKey('UNIT_ACTIVE')) { $f['UNIT_ACTIVE'] })".Trim() -eq 'active')
  $remoteListen = ("$(if ($f.ContainsKey('LISTENING')) { $f['LISTENING'] })".Trim() -eq 'yes')

  $state = 'down'
  if ($remoteActive -and $remoteListen -and $tunnelUp) { $state = 'up' }
  elseif ($remoteActive -and $remoteListen) { $state = 'remote-only' }
  elseif ($tunnelUp) { $state = 'tunnel-only' }

  $unitActive  = "$(if ($f.ContainsKey('UNIT_ACTIVE'))  { $f['UNIT_ACTIVE'] })".Trim()
  $unitEnabled = "$(if ($f.ContainsKey('UNIT_ENABLED')) { $f['UNIT_ENABLED'] })".Trim()
  $listening   = "$(if ($f.ContainsKey('LISTENING'))   { $f['LISTENING'] })".Trim()
  $dshPath = "$(if ($f.ContainsKey('DSH')) { $f['DSH'] })".Trim()
  $dshVersion = "$(if ($f.ContainsKey('DSH_V')) { $f['DSH_V'] })".Trim()
  $localVersion = Get-LocalDshVersion

  # Detail strings are shown verbatim in the desktop app, so they are written
  # for a person rather than as a dump of internal state.
  $rp = [int]$Inst.remotePort
  $detail = ''
  switch ($state) {
    'up'          { $detail = "服务端运行中 · 隧道已连接 · $lp ↔ $rp" }
    'remote-only' { $detail = "服务端运行中 · 隧道未连接（点启动即可接上）" }
    'tunnel-only' { $detail = "隧道已连接 · 服务端未运行" }
    default {
      if ($dshPath -eq 'none' -or $dshPath -eq '') { $detail = '服务器上还没有安装 dsh（点安装可自动装好）' }
      elseif ($unitActive -eq 'failed') { $detail = '服务启动失败，可查看日志' }
      else { $detail = "未启动 · 隧道口 $lp → 远程 $rp" }
    }
  }

  # Version drift is called out because a mismatch changes behaviour in ways
  # that are very hard to guess from the outside: 0.1.5+ prints a one-time
  # token URL and fences / with 401, while 0.1.1 and earlier do neither.
  $drift = $false
  if ($dshVersion -ne 'none' -and $dshVersion -and $localVersion -and $dshVersion -ne $localVersion) {
    $drift = $true
    $detail += " · 版本不一致(本地 $localVersion / 远程 $dshVersion)"
  }

  $remoteUrl = "$(if ($f.ContainsKey('URL')) { $f['URL'] })".Trim()
  $url = ''
  if ($state -eq 'up') {
    if ($remoteUrl -match '^https?://') {
      $url = $remoteUrl -replace "127\.0\.0\.1:$([int]$Inst.remotePort)", "127.0.0.1:$lp"
    } else {
      $url = "http://127.0.0.1:$lp"
    }
  }

  return [pscustomobject]@{
    Name = $Inst.name; Kind = 'remote'; Port = $lp
    State = $state; Detail = $detail; Http = 0; Url = $url
    SshHost = $sshHost; TunnelPid = $tunPid
    RemoteUrl = $remoteUrl; RemotePort = [int]$Inst.remotePort
    DshInstalled = ($dshPath -ne 'none' -and $dshPath -ne '')
    DshVersion = $dshVersion
    VersionDrift = $drift
    SshReady = $true
    Linger = "$(if ($f.ContainsKey('LINGER')) { $f['LINGER'] })".Trim()
    NodeV  = "$(if ($f.ContainsKey('NODE_V')) { $f['NODE_V'] })".Trim()
  }
}

function Get-RemoteDiagnosis([string]$SshHostName, [int]$Port = 0) {
  <# Classify an unreachable host instead of just saying "unreachable".
     The distinction that matters most is "needs a VPN" versus "credentials
     rejected" versus "host down", because they need completely different
     actions from the person reading it. #>
  $args = @('-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
  if ($Port -gt 0) { $args += @('-p', "$Port") }
  $out = (& ssh @args $SshHostName "echo DIAG_OK" 2>&1 | Out-String).Trim()
  if ($out -match 'DIAG_OK') {
    return [pscustomobject]@{ Code = 'ok'; Hint = '' }
  }
  $t = $out.ToLowerInvariant()
  if ($t -match 'could not resolve hostname') {
    return [pscustomobject]@{ Code = 'dns'; Hint = "主机名无法解析：检查 ssh config 里的 HostName，或 DNS" }
  }
  if ($t -match 'connection refused') {
    return [pscustomobject]@{ Code = 'refused'; Hint = "端口拒绝连接：sshd 没在监听，或端口写错了" }
  }
  if ($t -match 'permission denied|no supported authentication') {
    return [pscustomobject]@{ Code = 'auth'; Hint = "认证失败：密钥没配好，或 ssh-agent 里没有对应私钥" }
  }
  if ($t -match 'host key verification failed') {
    return [pscustomobject]@{ Code = 'hostkey'; Hint = "主机指纹变了：先手动 ssh 一次确认" }
  }
  if ($t -match 'timed out|timeout|unreachable|no route') {
    return [pscustomobject]@{ Code = 'timeout'; Hint = "网络不通：大概率需要连 VPN，或安全组没放行" }
  }
  return [pscustomobject]@{ Code = 'unknown'; Hint = $out.Split("`n")[-1].Trim() }
}

function Compare-Version([string]$A, [string]$B) {
  <# Component-wise numeric compare of "22.23.2" style versions.
     Returns 1 when A>B, -1 when A<B, 0 when equal. #>
  $pa = @(($A -replace '[^0-9.]', '') -split '\.' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
  $pb = @(($B -replace '[^0-9.]', '') -split '\.' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
  $n = [Math]::Max($pa.Count, $pb.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
    $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
    if ($x -gt $y) { return 1 }
    if ($x -lt $y) { return -1 }
  }
  return 0
}

function Test-RemoteDshInstalled([string]$SshHostName) {
  <# A non-interactive ssh command does not get a login shell, so npm's global
     bin directory is absent from PATH. WHICH directory that is depends on the
     host's npm prefix, so probe the common ones instead of assuming
     ~/.local/bin -- DuckServer, for instance, uses ~/.npm-global/bin. #>
  $script = @'
for c in "$HOME/.local/bin/dsh" "$HOME/.npm-global/bin/dsh" "$HOME/.local/node/bin/dsh" "/usr/local/bin/dsh" "/usr/bin/dsh"; do
  [ -x "$c" ] && { echo HAS_DSH; exit 0; }
done
command -v dsh >/dev/null 2>&1 && { echo HAS_DSH; exit 0; }
echo NO_DSH
'@
  $r = Invoke-B64 $script $SshHostName
  return ($r -match 'HAS_DSH')
}

function Test-RemoteDshRunnable([string]$SshHostName) {
  <# Returns the reported version when dsh actually EXECUTES, else ''.

     Two traps this must clear, both learned from a real host (DuckServer):
       1. Installing the package is not the same as having a working binary.
          dsh's shebang is `#!/usr/bin/env node`, so on a host whose system node
          predates the required 22.19.0 it resolves to that older node and exits
          0 with NO output whatsoever -- a silent failure that both a presence
          check and an exit-code check would happily miss.
       2. So PATH must put a node we installed ahead of the system one, exactly
          as the systemd unit does. #>
  $script = @'
if [ -x "$HOME/.local/node/bin/node" ]; then
  export PATH="$HOME/.local/node/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$PATH"
for c in "$HOME/.local/bin/dsh" "$HOME/.npm-global/bin/dsh" "$HOME/.local/node/bin/dsh" "/usr/local/bin/dsh" "/usr/bin/dsh"; do
  if [ -x "$c" ]; then
    v="$("$c" --version 2>/dev/null | head -1)"
    [ -n "$v" ] && { echo "DSH_RUNS=$v"; exit 0; }
  fi
done
if command -v dsh >/dev/null 2>&1; then
  v="$(dsh --version 2>/dev/null | head -1)"
  [ -n "$v" ] && { echo "DSH_RUNS=$v"; exit 0; }
fi
echo "DSH_RUNS="
'@
  $r = Invoke-B64 $script $SshHostName
  if ($r -match 'DSH_RUNS=(\S+)') { return $Matches[1] }
  return ''
}

function Get-RemoteFacts([string]$SshHostName) {
  <# One round trip that reports everything provisioning needs to decide.
     Single-quoted here-string on purpose: the body is bash, and a
     double-quoted one would let PowerShell expand $(...) and $VAR locally. #>
  $script = @'
set +e
# Report the node dsh would actually use. ~/.local/node is one this tool
# installed; putting it first matches what the systemd unit does, so the version
# reported here is the one the service will run under.
if [ -x "$HOME/.local/node/bin/node" ]; then
  export PATH="$HOME/.local/node/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$PATH"
echo "OS=$(uname -s 2>/dev/null || echo unknown)"
echo "ARCH=$(uname -m 2>/dev/null || echo unknown)"
echo "HAS_SYSTEMD=$(command -v systemctl >/dev/null 2>&1 && echo yes || echo no)"
echo "HAS_SUDO=$(command -v sudo >/dev/null 2>&1 && echo yes || echo no)"
echo "SUDO_NOPASS=$(sudo -n true 2>/dev/null && echo yes || echo no)"
echo "NODE=$(command -v node 2>/dev/null || echo none)"
echo "NODE_V=$(node -v 2>/dev/null || echo none)"
echo "NPM=$(command -v npm 2>/dev/null || echo none)"
NPM_PREFIX=$(npm config get prefix 2>/dev/null || echo none)
echo "NPM_PREFIX=${NPM_PREFIX}"
echo "HAS_DSH=$(command -v dsh >/dev/null 2>&1 || [ -x "$HOME/.local/bin/dsh" ] && echo yes || echo no)"
echo "DSH_V=$(dsh --version 2>/dev/null || $HOME/.local/bin/dsh --version 2>/dev/null || echo none)"
echo "SSH_USER=$(whoami)"
echo "HOME=$HOME"
echo "DISK_FREE=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
'@
  $out = Invoke-B64 $script $SshHostName
  $f = @{}
  foreach ($line in ($out -split "`r?`n")) { if ($line -match '^([A-Z_]+)=(.*)$') { $f[$Matches[1]] = $Matches[2].Trim() } }
  return $f
}

function Install-RemoteDsh([string]$SshHostName, [switch]$Quiet) {
  <# Install dsh on a host that does not have it yet.

     Deliberately unprivileged wherever possible:
       * node/npm come from the official static tarball into ~/.local, so no root
         and no distro package manager is involved;
       * dsh installs into the npm user prefix (~/.local), which needs no sudo;
       * only `loginctl enable-linger` may want privileges, and it is optional.
     Every step is idempotent and reports what it did. #>
  $f = Get-RemoteFacts $SshHostName

  if ($f['OS'] -ne 'Linux') {
    Write-Err "auto-install currently supports Linux hosts only (this host reports '$($f['OS'])')"
    return $false
  }
  if ([int]$f['DISK_FREE'] -gt 0 -and [int]$f['DISK_FREE'] -lt 512000) {
    Write-Warn2 "only $([int]([int]$f['DISK_FREE']/1024)) MB free in \$HOME; installation may fail"
  }

  $arch = switch -Regex ($f['ARCH']) {
    '^(x86_64|amd64)$' { 'x64';   break }
    '^(aarch64|arm64)$' { 'arm64'; break }
    default { '' }
  }
  if (-not $arch) {
    Write-Err "unsupported architecture '$($f['ARCH'])' for the Node tarball; install node manually then re-run"
    return $false
  }

  # dsh's dependency tree requires node >= 22.19.0 (a transitive dependency,
  # '@earendil-works/pi-ai', declares that engine). An older node installs the
  # package fine and then fails at run time with an opaque error, so the version
  # is checked up front rather than trusting "node exists".
  $minNode  = '22.19.0'
  $nodeVersion = 'v22.23.2'   # pinned LTS line
  $haveNode = $f['NODE'] -ne 'none' -and $f['NPM'] -ne 'none'
  $nodeOk = $false
  if ($haveNode -and $f['NODE_V'] -ne 'none') {
    $nodeOk = (Compare-Version $f['NODE_V'] $minNode) -ge 0
  }

  if ($haveNode -and -not $nodeOk) {
    if (-not $Quiet) {
      Write-Warn2 "node $($f['NODE_V']) is older than the required $minNode; installing $nodeVersion into ~/.local"
      Write-Info 'the system node is left untouched; the new one shadows it via PATH for dsh only'
    }
    $haveNode = $false
  }

  if (-not $haveNode) {
    if (-not $Quiet) { Write-Info "installing Node $nodeVersion into ~/.local (no root needed)" }
    $tarball = "node-$nodeVersion-linux-$arch"
    # Single-quoted here-string; placeholders are substituted afterwards so the
    # bash body is never touched by PowerShell's own interpolation.
    $installNode = @'
set -e
cd "$HOME"
mkdir -p .local .dsh-deck-dl
cd .dsh-deck-dl
TARBALL="__TARBALL__"
URL="https://nodejs.org/dist/__NODEVER__/$TARBALL.tar.xz"
echo "  downloading $URL"
if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$TARBALL.tar.xz" "$URL"; else wget -qO "$TARBALL.tar.xz" "$URL"; fi
tar -xf "$TARBALL.tar.xz"
rm -rf "$HOME/.local/node"
mv "$TARBALL" "$HOME/.local/node"
cd "$HOME" && rm -rf .dsh-deck-dl
# Put node/npm on PATH for future logins without touching system files.
for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
  [ -e "$f" ] || continue
  grep -q '.local/node/bin' "$f" 2>/dev/null && continue
  printf '\n# added by dsh-deck\nexport PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"\n' >> "$f"
done
"$HOME/.local/node/bin/node" -v
'@
    $installNode = $installNode.Replace('__TARBALL__', $tarball).Replace('__NODEVER__', $nodeVersion)
    $res = Invoke-B64 $installNode $SshHostName
    if ($res -notmatch 'v\d+\.') {
      Write-Err "Node installation failed:"
      Write-C ($res.Trim()) 'DarkGray'
      return $false
    }
    if (-not $Quiet) { Write-Ok "node installed: $(($res -split "`n" | Where-Object { $_ -match 'v\d+\.' } | Select-Object -Last 1).Trim())" }
  } elseif (-not $Quiet) {
    Write-Ok "node $($f['NODE_V']) satisfies >= $minNode"
  }

  # Install dsh into the npm USER prefix. Not forced to ~/.local: if this host
  # already has an npm prefix configured (DuckServer uses ~/.npm-global), keep
  # that so we do not scatter a second copy of dsh across the machine.
  $prefix = if ($f['NPM_PREFIX'] -and $f['NPM_PREFIX'] -ne 'none') { $f['NPM_PREFIX'] } else { '' }
  if ($prefix -and ($prefix -eq '/usr' -or $prefix -eq '/usr/local')) {
    # A system prefix needs root; fall back to the user prefix instead.
    if (-not $Quiet) { Write-Warn2 "npm prefix is $prefix (needs root); using ~/.local instead" }
    $prefix = ''
  }
  if (-not $prefix) { $prefix = '$HOME/.local' }

  if (-not $Quiet) { Write-Info "installing @deepseek-ai/dsh into npm prefix $prefix" }
  $installDsh = @'
set -e
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"
# Prefer the newly installed node when the system one is too old.
if [ -x "$HOME/.local/node/bin/node" ]; then
  export PATH="$HOME/.local/node/bin:$PATH"
  NPM="$HOME/.local/node/bin/npm"
else
  NPM="$(command -v npm)"
fi
"$NPM" config set prefix "__PREFIX__" >/dev/null 2>&1 || true
"$NPM" install -g --no-fund --no-audit @deepseek-ai/dsh 2>&1 | tail -n 12
echo "----"
for c in "$HOME/.local/bin/dsh" "$HOME/.npm-global/bin/dsh" "$HOME/.local/node/bin/dsh"; do
  [ -x "$c" ] && { echo "DSH_AT=$c"; break; }
done
'@
  $installDsh = $installDsh.Replace('__PREFIX__', $prefix)
  $res2 = Invoke-B64 $installDsh $SshHostName

  # Trust only a real execution, not "npm said added N packages".
  $ver = Test-RemoteDshRunnable $SshHostName
  if (-not $ver) {
    Write-Err 'dsh was installed but does not run:'
    Write-C ($res2.Trim()) 'DarkGray'
    Write-Info "usually a node version problem; check with: ssh $SshHostName 'node -v'"
    return $false
  }
  if (-not $Quiet) { Write-Ok "dsh installed and runnable: $ver" }
  return $true
}

function Install-RemoteService($Inst, [switch]$Quiet) {
  <# Deploy dsh-web-service.sh and dsh-web.service to the host, enable linger so
     the service survives logout, and start it. #>
  $sshHost = $Inst.sshHost
  $name = $Inst.name
  $rport = [int]$Inst.remotePort

  if (-not (Test-SshReachable $sshHost)) { Write-Err "$name`: ssh $sshHost not reachable"; return $false }
  if (-not (Test-Path $RemoteScript)) { Write-Err "missing $RemoteScript"; return $false }

  $scriptText = Get-Content $RemoteScript -Raw -Encoding UTF8
  # Force LF. A CRLF shebang on Linux dies with "bad interpreter: /bin/bash^M",
  # and on a Windows checkout core.autocrlf can hand us exactly that. The repo's
  # .gitattributes asks for LF, but a checkout cannot be trusted to have honoured
  # it, so normalise here as well.
  $scriptText = ($scriptText -replace "`r`n", "`n") -replace "`r", "`n"
  $b64Script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))

  $unitText = @"
[Unit]
Description=DeepSeek Harness web UI (dsh web)
Documentation=https://github.com/deepseek-ai/deepseek-harness
After=network-online.target

[Service]
Type=simple
Environment=DSH_PORT=$rport
ExecStart=%h/$RemotePath
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=20

[Install]
WantedBy=default.target
"@
  $unitText = $unitText -replace "`r`n", "`n"
  $b64Unit = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($unitText))

  $deploy = @"
set -e
mkdir -p `$HOME/.local/bin `$HOME/.config/systemd/user `$HOME/.dsh
echo '$b64Script' | base64 -d > `$HOME/$RemotePath
chmod +x `$HOME/$RemotePath
echo '$b64Unit' | base64 -d > `$HOME/$RemoteUnit
systemctl --user daemon-reload
systemctl --user enable dsh-web.service >/dev/null 2>&1
echo "DEPLOYED"
"@
  $out = Invoke-B64 $deploy $sshHost
  if ($out -notmatch 'DEPLOYED') {
    Write-Err "$name`: deploy failed: $($out.Trim())"
    return $false
  }
  if (-not $Quiet) { Write-Ok "$name`: service files deployed" }

  # Linger: without it the user manager (and the service) dies at logout.
  $linger = Invoke-B64 'loginctl enable-linger "$(whoami)" 2>&1 && echo LINGER_SET || echo LINGER_FAILED' $sshHost
  if ($linger -match 'LINGER_SET') {
    if (-not $Quiet) { Write-Ok "$name`: linger enabled (service survives logout)" }
  } else {
    if (-not $Quiet) { Write-Warn2 "$name`: could not enable linger; the service may stop when you log out" }
  }
  return $true
}

function Set-StateField([string]$InstanceName, [hashtable]$Fields) {
  $st = Get-State $InstanceName
  $obj = [ordered]@{}
  if ($st) { foreach ($p in $st.PSObject.Properties) { $obj[$p.Name] = $p.Value } }
  foreach ($k in $Fields.Keys) { $obj[$k] = $Fields[$k] }
  $obj['updatedAt'] = (Get-Date).ToString('o')
  Set-State $InstanceName ([pscustomobject]$obj)
}

function Start-Tunnel($Inst, [switch]$Quiet) {
  <# Returns the local port the tunnel listens on, or 0 on failure.
     The port is read back from state, not recomputed, so a tunnel that had to
     fall back from a busy port stays consistent across calls. #>
  $sshHost = $Inst.sshHost
  $lp = [int]$Inst.localPort
  $rp = [int]$Inst.remotePort

  $st = Get-State $Inst.name
  $recordedPort = 0
  if ($st -and $st.PSObject.Properties['localPort']) { $recordedPort = [int]$st.localPort }
  if ($recordedPort -gt 0) { $lp = $recordedPort }

  $existing = Get-RecordedPid $Inst.name 'tunnel'
  if ($existing -gt 0 -and $lp -gt 0 -and (Test-PortListening $lp)) {
    if (-not $Quiet) { Write-Info "tunnel already up (ssh pid $existing, 127.0.0.1:$lp)" }
    return $lp
  }

  if (Test-PortListening $lp) {
    $lp = Find-FreePort ($lp + 1)
    if (-not $Quiet) { Write-Warn2 "local port $($Inst.localPort) in use; tunnel using $lp instead" }
    Set-StateField $Inst.name @{ localPort = $lp }
  }

  $sshArgs = @(
    '-N',
    '-L', "${lp}:127.0.0.1:${rp}",
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'TCPKeepAlive=yes',
    $sshHost
  )
  $proc = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -WindowStyle Hidden -PassThru
  Write-Log "tunnel $($Inst.name): pid $($proc.Id) 127.0.0.1:$lp -> ${sshHost}:127.0.0.1:$rp"

  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { Write-Err "tunnel for $($Inst.name) exited immediately (code $($proc.ExitCode))"; return 0 }
    if (Test-PortListening $lp) { break }
    Start-Sleep -Milliseconds 250
  }
  if (-not (Test-PortListening $lp)) { Write-Err "tunnel for $($Inst.name) never listened on $lp"; return 0 }

  Set-StateField $Inst.name @{ tunnelPid = $proc.Id; localPort = $lp }
  if (-not $Quiet) { Write-Ok "$($Inst.name): tunnel up 127.0.0.1:$lp -> $sshHost`:127.0.0.1:$rp (ssh pid $($proc.Id))" }
  return $lp
}

function Stop-Tunnel($Inst, [switch]$Quiet, [switch]$RemoveState) {
  $pid_ = Get-RecordedPid $Inst.name 'tunnel'
  if ($pid_ -gt 0) {
    & taskkill.exe /PID $pid_ /T /F 2>&1 | Out-Null
    if (-not $Quiet) { Write-Ok "$($Inst.name): tunnel closed (ssh pid $pid_)" }
    Write-Log "closed tunnel $($Inst.name) pid $pid_"
  } elseif (-not $Quiet) {
    Write-Info "$($Inst.name): no tunnel recorded"
  }
  # On a full stop the recorded url/port are meaningless, so drop the whole
  # record; a bare tunnel-close keeps the rest.
  if ($RemoveState) { Remove-State $Inst.name; return }
  $st = Get-State $Inst.name
  if ($st) {
    $obj = [ordered]@{}
    foreach ($p in $st.PSObject.Properties) {
      if ($p.Name -ne 'tunnelPid' -and $p.Name -ne 'localPort') { $obj[$p.Name] = $p.Value }
    }
    if ($obj.Count -gt 0) { Set-State $Inst.name ([pscustomobject]$obj) } else { Remove-State $Inst.name }
  }
}

function Start-RemoteInstance($Inst, [switch]$Quiet) {
  $name = $Inst.name
  $sshHost = $Inst.sshHost
  $rp = [int]$Inst.remotePort

  if (-not (Test-SshReachable $sshHost)) {
    $d = Get-RemoteDiagnosis $sshHost
    Write-Err "$name`: cannot reach $sshHost [$($d.Code)]"
    if ($d.Hint) { Write-Info $d.Hint }
    return $false
  }

  # Provision dsh if the host does not have a WORKING one. Testing runnability
  # rather than mere presence matters: an npm install performed under a too-old
  # node leaves a dsh binary behind that prints nothing at all, and a
  # presence-only check would then skip the very upgrade that repairs it.
  $remoteVer = Test-RemoteDshRunnable $sshHost
  if (-not $remoteVer) {
    # Opt-out gate: an instance may declare "autoInstall": false to forbid the
    # tool from touching that host's software at all.
    $autoOk = -not ($Inst.PSObject.Properties['autoInstall'] -and $Inst.autoInstall -eq $false)
    if (-not $autoOk) {
      Write-Err "$name`: dsh on $sshHost is missing or not working, and autoInstall is false"
      Write-Info "install it manually: ssh $sshHost 'npm install -g @deepseek-ai/dsh'  (needs node >= 22.19.0)"
      return $false
    }
    if (-not $Quiet) {
      if (Test-RemoteDshInstalled $sshHost) {
        Write-Warn2 "$name`: dsh is present on $sshHost but does not run; repairing it"
      } else {
        Write-Info "$name`: dsh is not installed on $sshHost - installing it now"
      }
    }
    if (-not (Install-RemoteDsh $sshHost -Quiet:$Quiet)) {
      Write-Err "$name`: automatic installation failed"
      Write-Info "install it by hand with: ssh $sshHost 'npm i -g @deepseek-ai/dsh'"
      return $false
    }
  }

  # Deploy the service definition if it is missing or stale.
  $hasSvc = Invoke-B64 "test -f `$HOME/$RemoteUnit -a -f `$HOME/$RemotePath && echo YES || echo NO" $sshHost
  if ($hasSvc -notmatch 'YES') {
    if (-not (Install-RemoteService $Inst -Quiet:$Quiet)) { return $false }
  }

  # dsh has no port/lock file and no stop command, so ask systemd for a single
  # coherent snapshot instead of two separate queries: reading is-active and
  # MainPID separately can catch the unit mid-transition and disagree.
  # LISTEN_PID identifies the process that actually holds the port; if it is not
  # the unit's MainPID we have an orphan from an earlier run, which would make a
  # second dsh fail to bind and linger as a stopped process.
  $snapScript = @"
MP=`$(systemctl --user show dsh-web.service -p MainPID --value 2>/dev/null)
ST=`$(systemctl --user is-active dsh-web.service 2>/dev/null)
LP=`$(ss -ltnpH "sport = :$rp" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
echo "SNAP_MAIN=`${MP:-0}"
echo "SNAP_STATE=`${ST:-unknown}"
echo "SNAP_LISTEN=`${LP:-0}"
"@

  $snap = Invoke-B64 $snapScript $sshHost
  $sm = @{}
  foreach ($line in ($snap -split "`r?`n")) { if ($line -match '^SNAP_([A-Z]+)=(.*)$') { $sm[$Matches[1]] = $Matches[2].Trim() } }
  $mainPid   = if ($sm['MAIN'])   { [int]$sm['MAIN'] }   else { 0 }
  $unitState = if ($sm['STATE'])  { $sm['STATE'] }       else { 'unknown' }
  $listenPid = if ($sm['LISTEN']) { [int]$sm['LISTEN'] } else { 0 }

  if ($unitState -eq 'active' -and $listenPid -gt 0 -and $mainPid -gt 0 -and $listenPid -ne $mainPid) {
    Write-Warn2 "$name`: port $rp is held by pid $listenPid but the unit's MainPID is $mainPid"
    Write-Info "$name`: an orphaned dsh from an earlier run is squatting the port; restarting the unit"
    $restart = Invoke-B64 "kill -TERM $listenPid 2>/dev/null; sleep 2; kill -KILL $listenPid 2>/dev/null; systemctl --user restart dsh-web.service 2>&1; sleep 3; systemctl --user is-active dsh-web.service 2>&1" $sshHost
    if ($restart -notmatch 'active') { Write-Err "$name`: could not recover the orphaned port: $($restart.Trim())"; return $false }
    Write-Ok "$name`: orphan cleared and unit restarted"
    $unitState = 'active'
  } elseif ($unitState -ne 'active') {
    if (-not $Quiet) { Write-Info "$name`: starting remote service" }
    $restart = Invoke-B64 'systemctl --user start dsh-web.service 2>&1; sleep 2; systemctl --user is-active dsh-web.service 2>&1' $sshHost
    if ($restart -notmatch 'active') {
      Write-Err "$name`: remote service failed to start: $($restart.Trim())"
      Write-Info "diagnose with: ssh $sshHost journalctl --user -u dsh-web -n 50 --no-pager"
      return $false
    }
  } elseif (-not $Quiet) {
    Write-Info "$name`: remote service already active"
  }

  # Wait for the remote listener.
  $deadline = (Get-Date).AddSeconds(60)
  $listening = $false
  while ((Get-Date) -lt $deadline) {
    $r = Invoke-B64 "ss -ltn 2>/dev/null | grep -q '127.0.0.1:$rp' && echo YES || echo NO" $sshHost
    if ($r -match 'YES') { $listening = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $listening) { Write-Err "$name`: remote server not listening on 127.0.0.1:$rp after 60s"; return $false }
  if (-not $Quiet) { Write-Ok "$name`: remote server listening on 127.0.0.1:$rp" }

  # Tunnel.
  $lp = Start-Tunnel $Inst -Quiet:$Quiet
  if ($lp -le 0) { return $false }

  # Authenticated URL, rewritten onto the tunnel port. The cookie is signed for
  # the authority the request arrives with, so redeeming via 127.0.0.1:$lp is
  # correct and yields a cookie valid for exactly that authority.
  $remoteUrl = ''
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    $remoteUrl = (Invoke-B64 'cat $HOME/.dsh/remote-web.url 2>/dev/null || true' $sshHost).Trim()
    if ($remoteUrl -match '^https?://') { break }
    Start-Sleep -Seconds 1
  }

  if ($remoteUrl -match '^https?://') {
    $url = $remoteUrl -replace "127\.0\.0\.1:$rp", "127.0.0.1:$lp"
  } else {
    if (-not $Quiet) { Write-Warn2 "$name`: remote dsh published no token URL (older version); opening the plain URL" }
    $url = "http://127.0.0.1:$lp"
  }

  # Merge, never replace: Start-Tunnel already recorded tunnelPid here, and a
  # wholesale Set-State would drop it, orphaning the ssh tunnel on the next stop.
  Set-StateField $name @{
    localPort = $lp
    remoteUrl = $remoteUrl
    url = $url
  }

  if (-not $Quiet) { Write-Ok "$name`: ready at $url" }
  return $url
}

function Stop-RemoteInstance($Inst, [switch]$Quiet) {
  $name = $Inst.name
  Stop-Tunnel $Inst -Quiet:$Quiet -RemoveState

  if ($Inst.PSObject.Properties['stopRemoteService'] -and $Inst.stopRemoteService -eq $false) {
    if (-not $Quiet) { Write-Info "$name`: leaving the remote service running (stopRemoteService=false)" }
    return
  }
  if (-not (Test-SshReachable $Inst.sshHost)) {
    if (-not $Quiet) { Write-Warn2 "$name`: ssh $($Inst.sshHost) unreachable; remote service left as is" }
    return
  }
  $r = Invoke-B64 'systemctl --user stop dsh-web.service 2>&1; sleep 1; systemctl --user is-active dsh-web.service 2>&1 || true' $Inst.sshHost
  if ($r -match 'inactive|failed') {
    if (-not $Quiet) { Write-Ok "$name`: remote service stopped" }
  } elseif (-not $Quiet) {
    Write-Warn2 "$name`: remote service state unclear: $($r.Trim())"
  }
}

# --------------------------------------------------------------------------
# Browser
# --------------------------------------------------------------------------

function Open-Instance([string]$Url, [switch]$AsAppWindow) {
  if (-not $Url) { Write-Err 'nothing to open (no URL)'; return }
  if ($AsAppWindow) {
    $browser = @(
      "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
      "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($browser) {
      $profileDir = Join-Path $LauncherDir 'browser-profile'
      if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
      Start-Process -FilePath $browser -ArgumentList @(
        "--app=$Url", "--user-data-dir=$profileDir", '--no-first-run', '--no-default-browser-check'
      ) | Out-Null
      Write-Ok "opened app window: $Url"
      return
    }
    Write-Warn2 'no Chrome/Edge found; opening a normal browser tab instead'
  }
  Start-Process -FilePath "$env:WINDIR\System32\rundll32.exe" `
    -ArgumentList 'url.dll,FileProtocolHandler', $Url -WindowStyle Hidden | Out-Null
  Write-Ok "opened $Url"
}

# --------------------------------------------------------------------------
# Status rendering
# --------------------------------------------------------------------------

function Get-AllStatus([switch]$NoProbeHttp) {
  $insts = @(Get-HostsConfig).instances
  $rows = @()
  foreach ($i in $insts) {
    if ($i.enabled -eq $false) {
      $rows += [pscustomobject]@{
        Name = $i.name; Kind = $i.kind; Port = 0
        State = 'disabled'; Detail = 'disabled in hosts.json'; Http = 0; Url = ''
      }
      continue
    }
    if ($i.kind -eq 'remote') { $rows += Get-RemoteStatus $i }
    else { $rows += Get-LocalStatus $i -NoProbeHttp:$NoProbeHttp }
  }
  return $rows
}

function Write-StatusTable($Rows) {
  $fmt = "{0,-18} {1,-8} {2,-6} {3,-13} {4}"
  Write-Host ''
  Write-C ($fmt -f 'INSTANCE', 'KIND', 'PORT', 'STATE', 'DETAIL') 'Cyan'
  Write-C ('  ' + ('-' * 92)) 'DarkGray'
  foreach ($r in $Rows) {
    $color = switch ($r.State) {
      'up'           { 'Green' }
      'up-external'  { 'Green' }
      'remote-only'  { 'Yellow' }
      'tunnel-only'  { 'Yellow' }
      'disabled'     { 'DarkGray' }
      default        { 'Red' }
    }
    Write-C ($fmt -f $r.Name, $r.Kind, $r.Port, $r.State, $r.Detail) $color
  }
  Write-Host ''
  foreach ($r in $Rows) { if ($r.Url) { Write-C ("  {0,-18} {1}" -f $r.Name, $r.Url) 'DarkCyan' } }
  Write-Host ''
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

function Invoke-Start([string[]]$Names, [switch]$Quiet) {
  $insts = @(Get-Instances $Names)
  if ($insts.Count -eq 0) { Write-Warn2 'no instances selected'; return }
  $urls = @()
  foreach ($i in $insts) {
    if ($i.enabled -eq $false) { Write-Info "$($i.name) is disabled; skipping"; continue }
    Write-Head "start $($i.name)"
    if ($i.kind -eq 'remote') {
      $u = Start-RemoteInstance $i -Quiet:$Quiet
      if ($u) { $urls += $u }
    } else {
      # -LocalPort overrides the configured port, which is how you run a second
      # local instance on a spare port without editing hosts.json.
      # NB: read the script-level $LocalPort directly. $PSBoundParameters inside
      # this function describes THIS function's parameters (Names/Quiet), not the
      # script's, so ContainsKey('LocalPort') would always be false here.
      $portOverride = 0
      if ($LocalPort -gt 0) { $portOverride = $LocalPort }
      $actualPort = Start-LocalInstance $i -Quiet:$Quiet -PortOverride $portOverride
      if ($actualPort -gt 0) { $urls += (Get-LocalUrl $i.name $actualPort) }
    }
  }
  $urls = @($urls)
  if ($urls.Count -gt 0 -and -not $NoOpen) {
    Start-Sleep -Milliseconds 400
    foreach ($u in $urls) { Open-Instance $u -AsAppWindow:$AppWindow }
  } elseif ($urls.Count -gt 0) {
    Write-Head 'urls'
    foreach ($u in $urls) { Write-C "  $u" 'Cyan' }
  }
}

function Invoke-Stop([string[]]$Names) {
  $insts = @(Get-Instances $Names)
  foreach ($i in $insts) {
    Write-Head "stop $($i.name)"
    if ($i.kind -eq 'remote') { Stop-RemoteInstance $i } else { Stop-LocalInstance $i | Out-Null }
  }
}

function Invoke-Open([string[]]$Names) {
  $rows = Get-AllStatus
  $want = if ($Names -and $Names.Count -gt 0) { $Names } else { @($rows | Where-Object { $_.State -eq 'up' } | Select-Object -ExpandProperty Name) }
  if (-not $want -or @($want).Count -eq 0) { Write-Warn2 'nothing is up; run: dsh.ps1 start'; return }
  foreach ($n in $want) {
    $r = $rows | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if (-not $r) { Write-Warn2 "unknown instance '$n'"; continue }
    if (-not $r.Url) { Write-Warn2 "$n is not up (state=$($r.State))"; continue }
    Open-Instance $r.Url -AsAppWindow:$AppWindow
  }
}

function Invoke-Logs([string[]]$Names, [int]$Tail) {
  $insts = @(if ($Names -and @($Names).Count -gt 0) { Get-Instances $Names } else { Get-Instances $null })
  foreach ($i in $insts) {
    if ($i.kind -eq 'remote') {
      Write-Head "logs $($i.name) (remote systemd journal)"
      $r = Invoke-B64 "journalctl --user -u dsh-web -n $Tail --no-pager 2>&1 | tail -n $Tail" $i.sshHost
      Write-C ($r.TrimEnd()) 'DarkGray'
    } else {
      $log = Join-Path $LogDir "$($i.name).server.log"
      Write-Head "logs $($i.name) ($log)"
      if (Test-Path $log) { Get-Content $log -Tail $Tail | ForEach-Object { Write-C "  $_" 'DarkGray' } }
      else { Write-Info 'no log yet' }
    }
  }
}

function Invoke-Add([switch]$Quiet) {
  if (-not $SshHost) { Write-Err 'usage: dsh.ps1 add -SshHost <ssh-alias-or-user@host> [-Name x] [-Port 3080]'; return }
  $cfg = Get-HostsConfig
  $n = if ($Name) { $Name } else { $SshHost }
  if (@($cfg.instances) | Where-Object { $_.name -eq $n }) { Write-Err "instance '$n' already exists"; return }
  $free = Find-FreePort 3099
  $rp = if ($Port) { $Port } else { 3080 }
  $new = [pscustomobject]@{
    name = $n; kind = 'remote'; enabled = $true; sshHost = $SshHost
    remotePort = $rp; localPort = $free; description = "dsh web on $SshHost"
  }
  $cfg.instances = @($cfg.instances) + $new
  Save-HostsConfig $cfg
  if (-not $Quiet) {
    Write-Ok "added '$n' (tunnel 127.0.0.1:$free -> $SshHost`:127.0.0.1:$rp)"
    Write-Info "next: dsh.ps1 install $n"
  }
}

function Invoke-List {
  $insts = @(Get-HostsConfig).instances
  $fmt = "{0,-18} {1,-8} {2,-7} {3,-26} {4}"
  Write-Host ''
  Write-C ($fmt -f 'INSTANCE', 'KIND', 'ENABLED', 'SSH HOST', 'DESCRIPTION') 'Cyan'
  Write-C ('  ' + ('-' * 92)) 'DarkGray'
  foreach ($i in $insts) {
    $sh = if ($i.kind -eq 'remote') { $i.sshHost } else { '(this machine)' }
    Write-C ($fmt -f $i.name, $i.kind, $i.enabled, $sh, $i.description) 'Gray'
  }
  Write-Host ''
  Write-Info "config file: $(Resolve-ConfigPath)"
  Write-Host ''
}

function Invoke-Install([string[]]$Names, [switch]$Quiet) {
  $insts = @(Get-Instances $Names) | Where-Object { $_.kind -eq 'remote' }
  if (-not $insts -or @($insts).Count -eq 0) { Write-Err 'no remote instances selected'; return }
  foreach ($i in $insts) {
    if (-not $Quiet) { Write-Head "install $($i.name) -> $($i.sshHost)" }
    Install-RemoteService $i -Quiet:$Quiet | Out-Null
  }
}

function Invoke-App([switch]$Quiet) {
  <# Start the desktop app: the Node backend, then a chromeless browser window.

     Readiness comes from the runtime file the backend writes
     (state\app.json), not from the child's stdout. Capturing the child's stdout
     instead ties its lifetime to our pipe: when this process exits the pipe
     closes and the backend can die on its next write. The file also doubles as
     the way a second launch discovers the backend that is already running.
     #>
  $serverJs = Join-Path $LauncherDir 'app\server.js'
  if (-not (Test-Path $serverJs)) { Write-Err "missing $serverJs"; return }
  $node = Get-NodeExe
  if (-not $node) { Write-Err 'node.exe not found on PATH'; return }

  # Reuse a backend that is already serving, so a second click opens the window
  # instead of stacking another server.
  $runtimeFile = Join-Path $StateDir 'app.json'
  if (Test-Path $runtimeFile) {
    try {
      $rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $alive = $false
      if ($rt.pid) { $alive = [bool](Get-Process -Id ([int]$rt.pid) -ErrorAction SilentlyContinue) }
      if ($alive -and $rt.url) {
        if (-not $Quiet) { Write-Info "app backend already running on port $($rt.port)" }
        Open-AppWindow $rt.url
        return
      }
    } catch { }
    Remove-Item $runtimeFile -Force -ErrorAction SilentlyContinue
  }

  if (-not $Quiet) { Write-Info 'starting app backend…' }
  Remove-Item $runtimeFile -Force -ErrorAction SilentlyContinue

  # UseShellExecute = true is what actually detaches the backend: no inherited
  # handles, so it survives this console exiting. Redirecting the child's
  # stdout/stderr (the earlier approach) left it holding our pipe handles -- it
  # reported ready, then died the moment the launcher exited. The backend now
  # writes its own log to logs\app.log.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node
  $psi.Arguments = "`"$serverJs`""
  $psi.WorkingDirectory = $LauncherDir
  $psi.UseShellExecute = $true
  $psi.WindowStyle = 'Hidden'
  $psi.CreateNoWindow = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  # Readiness comes from the runtime file the backend writes; a detached process
  # gives us no waitable handle, so poll the file.
  $payload = $null
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $runtimeFile) {
      try {
        $rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rt.pid -and $rt.url) { $payload = $rt; break }
      } catch { }
    }
    Start-Sleep -Milliseconds 250
  }

  if (-not $payload) {
    Write-Err 'app backend did not become ready'
    $backendLog = Join-Path $LogDir 'app.log'
    if (Test-Path $backendLog) {
      Write-Info "last backend log lines ($backendLog):"
      Get-Content $backendLog -Tail 15 | ForEach-Object { Write-C "    $_" 'DarkGray' }
    }
    return
  }

  Write-Log "app backend pid $($payload.pid) port $($payload.port)"
  Open-AppWindow $payload.url

  if (-not $Quiet) {
    Write-Ok "app backend running on port $($payload.port)"
    Write-Info '窗口已打开。关掉窗口不影响后端，下次运行本命令会重新打开。'
    Write-Info '停止后端：dsh.ps1 app -Stop'
  }
}

function Open-AppWindow([string]$Url) {
  <# Prefer a chromeless app window with its own browser profile: it reads as a
     real application rather than a browser tab, and the profile keeps it
     independent of the user's normal browsing session. #>
  $browser = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1

  if ($browser) {
    $profileDir = Join-Path $LauncherDir 'browser-profile'
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    Start-Process -FilePath $browser -ArgumentList @(
      "--app=$Url",
      "--user-data-dir=$profileDir",
      '--no-first-run',
      '--no-default-browser-check',
      '--window-size=1120,780'
    ) | Out-Null
    Write-Log "app window: $browser"
  } else {
    Write-Warn2 'no Chrome/Edge found; opening the default browser instead'
    Start-Process -FilePath "$env:WINDIR\System32\rundll32.exe" `
      -ArgumentList 'url.dll,FileProtocolHandler', $Url -WindowStyle Hidden | Out-Null
  }
}

function Stop-App {
  <# Stop the app backend, and optionally the browser window that points at it.
     The window is identified by its command line containing our app URL, so we
     never kill an unrelated browser the user has open. #>
  $runtimeFile = Join-Path $StateDir 'app.json'
  $stopped = $false
  if (Test-Path $runtimeFile) {
    try {
      $rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($rt.pid) {
        $p = Get-Process -Id ([int]$rt.pid) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'node') {
          & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
          Write-Ok "app backend stopped (pid $($p.Id))"
          $stopped = $true
        }
      }
    } catch { }
    Remove-Item $runtimeFile -Force -ErrorAction SilentlyContinue
  }
  if (-not $stopped) { Write-Info 'app backend was not running' }

  # Close only our own app window. The profile directory identifies our
  # browser instance, so a user's normal Chrome is never touched. Child
  # processes may already be gone by the time we get to them, and taskkill
  # reports that as a non-zero exit the way a native command failure would, so
  # route its output away from the error stream instead of letting
  # $ErrorActionPreference='Stop' abort the cleanup.
  $profileDir = Join-Path $LauncherDir 'browser-profile'
  $killed = 0
  $targets = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$profileDir*" })
  foreach ($t in $targets) {
    try {
      $null = & taskkill.exe /PID $t.ProcessId /T /F 2>&1
      $killed++
    } catch { }
  }
  if ($killed -gt 0) { Write-Ok "closed $killed app window process(es)" }
}

function Start-TrayLoop([int]$IntervalSeconds = 20) {
  <# A tray icon that polls instance state and raises a balloon whenever an
     instance changes state. This is the one genuinely event-like part of the
     tool: a tunnel dying while you are not looking is only useful to know about
     if something tells you.

     Threading, because getting this wrong freezes the icon silently:
       * WinForms needs an STA thread with a running message loop. PowerShell
         5.1's console host is STA by default, so the icon and menu are created
         here and Application.Run owns this thread.
       * Polling must NOT run on that thread, or the loop stops pumping messages
         and the icon stops responding to clicks. A WinForms Timer marshals each
         tick back onto the UI thread between message pumps.
     Balloon tips are used rather than WinRT toasts: no extra module, works on
     every supported Windows version. #>
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $icon = New-Object System.Windows.Forms.NotifyIcon
  # Borrow the shell's own icon so there is no binary asset to ship.
  try {
    $icon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon(
      (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
  } catch { }
  $icon.Text = 'dsh-deck'
  $icon.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miOpen  = $menu.Items.Add('打开面板')
  $miStart = $menu.Items.Add('全部启动')
  $miStop  = $menu.Items.Add('全部停止')
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $miExit  = $menu.Items.Add('退出托盘（后端继续运行）')

  $miOpen.add_Click({  try { Invoke-App -Quiet } catch { } })
  $miStart.add_Click({ try { Invoke-Start $null -Quiet } catch { } })
  $miStop.add_Click({  try { Invoke-Stop $null } catch { } })
  $miExit.add_Click({
    $icon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
  })
  $icon.ContextMenuStrip = $menu

  $form = New-Object System.Windows.Forms.Form
  $form.ShowInTaskbar = $false
  $form.WindowState = 'Minimized'
  $form.Visible = $false

  $previous = @{}

  $tick = {
    try {
      $rows = @(Get-AllStatus -NoProbeHttp)
      foreach ($r in $rows) {
        if ($previous.ContainsKey($r.Name)) {
          $was = $previous[$r.Name]
          if ($was -ne $r.State) {
            $good = ($r.State -eq 'up' -or $r.State -eq 'up-external')
            $icon.ShowBalloonTip(
              6000,
              "dsh-deck: $($r.Name)",
              $(if ($good) { "现在可用（$($r.State)）" } else { "状态变为 $($r.State) — $($r.Detail)" }),
              $(if ($good) { 'Info' } else { 'Warning' })
            )
            Write-Log "tray: $($r.Name) $was -> $($r.State)"
          }
        }
        $previous[$r.Name] = $r.State
      }
      # Windows truncates the tooltip near 63 characters.
      $up = @($rows | Where-Object { $_.State -eq 'up' -or $_.State -eq 'up-external' }).Count
      $icon.Text = "dsh-deck  $up/$(@($rows).Count) 运行中"
    } catch {
      Write-Log "tray tick failed: $($_.Exception.Message)"
    }
  }

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(5, $IntervalSeconds) * 1000
  $timer.add_Tick($tick)

  # Claim the pid file from inside the long-lived process, so it is accurate for
  # our whole lifetime and self-cleaning on exit. A parent-written record outlives
  # a crashed child and would then report a tray that does not exist.
  #
  # The tick body is wrapped in try/catch deliberately: an unhandled exception
  # inside a WinForms event handler is swallowed by the message loop without a
  # trace, so a bug in status polling would silently freeze the icon rather than
  # surface anywhere.
  $pidFile = Join-Path $StateDir 'tray.json'
  $form.add_Shown({
    try {
      [pscustomobject]@{
        pid = $PID; interval = $IntervalSeconds; startedAt = (Get-Date).ToString('o')
      } | ConvertTo-Json | Set-Content -Path $pidFile -Encoding UTF8
    } catch {
      Write-Log "tray: could not write pid file: $($_.Exception.Message)"
    }
    & $tick
    $timer.Start()
  })

  $icon.ShowBalloonTip(4000, 'dsh-deck', '托盘已启动，正在监控实例状态', 'Info')

  try {
    [System.Windows.Forms.Application]::Run($form)
  } finally {
    $timer.Stop()
    $icon.Visible = $false
    $icon.Dispose()
    # Only remove the pid file if it is still ours, so a newer tray is not erased.
    try {
      if (Test-Path $pidFile) {
        $recorded = [int]((Get-Content $pidFile -Raw -Encoding UTF8 | ConvertFrom-Json).pid)
        if ($recorded -eq $PID) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
      }
    } catch { }
  }
}

function Get-RunningTrayPid {
  <# The pid of the live tray, or 0.

     The pid file is the authority, and it is owned by the long-lived tray process
     itself: it writes its own pid once its message loop is up and removes the file
     on exit, including exit by taskkill, because PowerShell still runs a finally
     block on termination. That self-cleaning property is the point. An earlier
     design had the PARENT write the pid, so a crash or an external kill left an
     entry claiming a tray existed when none did.

     Deliberately does NOT also scan the process table. Matching trays by command
     line proved unreliable -- the pattern also matched scripts and handlers whose
     command line merely contained the text, so the tool repeatedly counted itself
     as a tray, and a "stop" would kill one and instantly find another. A pid file
     cannot be fooled that way. #>
  $stateFile = Join-Path $StateDir 'tray.json'
  if (-not (Test-Path $stateFile)) { return 0 }
  try {
    $pid_ = [int]((Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).pid)
    if ($pid_ -gt 0 -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) { return $pid_ }
  } catch { }
  Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
  return 0
}

function Get-LiveTrays {
  <# Tray processes, identified by command line.

     The match has to be anchored to the real invocation. A loose
     `-like '*-Command tray-loop*'` also matches any process whose command line
     merely CONTAINS that text -- a script that runs `dsh.ps1 -Command tray-loop`,
     or even this function's own caller when the string appears in its source. The
     tool was therefore counting itself as a tray, which is why a stop would kill
     one and immediately "find" another. Anchoring on the
     `-File ... dsh.ps1 -Command tray-loop` shape excludes those false positives.

     Returns a plain array; callers wrap it in @(). Do NOT return ,@(...): that
     nests the array one level deeper, so .Count reports 1 even when nothing
     matched and $live[0] yields the inner array instead of a pid. #>
  $out = @()
  $all = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object {
             $_.CommandLine -and
             $_.ProcessId -ne $PID -and
             $_.CommandLine -match 'dsh\.ps1"?\s+-Command\s+tray-loop(\s|$)'
           })
  foreach ($p in $all) { $out += [int]$p.ProcessId }
  return $out
}

function Invoke-Tray([switch]$Stop) {
  <# Manage the tray as a tracked background process.

     The tray needs a WinForms message loop on its own STA thread, so it cannot
     share a process with either a console command or the app backend. It is
     therefore started detached with its pid recorded -- the same pattern the
     backend uses. Without the record, every invocation would leave another icon
     in the notification area.

     The lock file is the authority on whether a tray is running, not the pid
     cache and not a process count: the lock is atomic, so concurrent calls cannot
     both decide to start one. The json file only records the pid for display and
     for `tray-stop` to target. #>
  $stateFile = Join-Path $StateDir 'tray.json'
  $lockFile  = Join-Path $StateDir 'tray.lock'
  $wantStop  = [bool]$Stop

  if ($wantStop) {
    $target = Get-RunningTrayPid
    if ($target -gt 0) {
      # taskkill writes "process not found" to the error stream when a child has
      # already exited; with $ErrorActionPreference='Stop' an unhandled native
      # error would abort the stop although the tray is in fact already gone.
      try { $null = & taskkill.exe /PID $target /T /F 2>&1 } catch { }
      # Give the tray's finally block a moment to remove its own pid file.
      $deadline = (Get-Date).AddSeconds(5)
      while ((Get-Date) -lt $deadline -and (Test-Path $stateFile)) { Start-Sleep -Milliseconds 200 }
    }
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    if ($target -eq 0) {
      if (-not $Json) { Write-Info 'tray was not running' }
    } elseif (-not $Json) {
      Write-Ok "tray stopped (pid $target)"
    }
    if ($Json) { Write-Json @{ ok = $true; running = $false; stopped = $(if ($target -gt 0) { 1 } else { 0 }) } }
    return
  }

  $running = Get-RunningTrayPid
  if ($running -gt 0) {
    if ($Json) { Write-Json @{ ok = $true; running = $true; pid = $running } }
    else { Write-Info "tray already running (pid $running)" }
    return
  }

  $scriptPath = $PSCommandPath
  if (-not $scriptPath) { $scriptPath = Join-Path $LauncherDir 'dsh.ps1' }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Command tray-loop -TrayInterval $TrayInterval"
  $psi.WorkingDirectory = $LauncherDir
  # UseShellExecute detaches it: no inherited handles, so closing this console
  # does not take the tray with it.
  $psi.UseShellExecute = $true
  $psi.WindowStyle = 'Hidden'
  $psi.CreateNoWindow = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  # The tray writes its own pid file once its message loop is up, so wait for that
  # rather than inventing a pid record here: a parent-written record outlives a
  # crashed child and would then claim a tray exists when none does.
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    if (Test-Path $stateFile) {
      try {
        if ([int]((Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).pid) -eq $proc.Id) { break }
      } catch { }
    }
    Start-Sleep -Milliseconds 250
  }

  if ($proc.HasExited) {
    if ($Json) { Write-Json @{ ok = $false; running = $false; error = "tray exited immediately (code $($proc.ExitCode))" } }
    else { Write-Err "tray exited immediately (code $($proc.ExitCode))" }
    return
  }

  if ($Json) {
    Write-Json @{ ok = $true; running = $true; pid = $proc.Id }
    return
  }

  Write-Ok "tray started (pid $($proc.Id), polling every $TrayInterval s)"
  Write-Info 'right-click the tray icon for 打开面板 / 全部启动 / 全部停止'
  Write-Info 'notifications appear when an instance changes state'
  Write-Info 'stop it with: dsh.ps1 -Command tray-stop'
}

function Invoke-Doctor {
  Write-Head 'this machine'
  Write-Info "powershell : $($PSVersionTable.PSVersion)"
  $node = Get-NodeExe
  if ($node) { Write-Ok "node       : $node ($(& $node -v 2>&1))" } else { Write-Err 'node       : NOT FOUND' }
  $bin = Find-DshLocal
  if ($bin) { Write-Ok "dsh        : $bin" } else { Write-Err 'dsh        : NOT FOUND (npm i -g @deepseek-ai/dsh)' }
  Write-Info "DSH_HOME   : $DshHome"
  Write-Info "launcher   : $LauncherDir"
  $sshCfg = Get-SshConfigPath
  if (Test-Path $sshCfg) { Write-Ok "ssh config : $sshCfg" } else { Write-Warn2 "ssh config : not found at $sshCfg" }

  Write-Head 'configured instances'
  $rows = Get-AllStatus
  Write-StatusTable $rows

  Write-Head 'ssh config hosts not yet configured here'
  $sshCfg = Get-SshConfigPath
  if (Test-Path $sshCfg) {
    $known = @($rows | Select-Object -ExpandProperty Name)
    $cfgHosts = @()
    Get-Content $sshCfg | ForEach-Object {
      if ($_ -match '^\s*Host\s+(.+)$') {
        $cfgHosts += ($Matches[1] -split '\s+' | Where-Object { $_ -and $_ -notmatch '[*?]' })
      }
    }
    $missing = $cfgHosts | Select-Object -Unique | Where-Object { $known -notcontains $_ }
    if ($missing) {
      foreach ($m in $missing) { Write-C "  $m" 'DarkGray' }
      Write-Host ''
      Write-Info "add one with: dsh.ps1 add -SshHost <host>   (then: dsh.ps1 install <host>)"
    } else { Write-Info 'every ssh host is already configured' }
  }
  Write-Host ''
}

function Invoke-Menu {
  while ($true) {
    Clear-Host
    Write-C '  ========================================================' 'Cyan'
    Write-C '    DeepSeek Harness  -  control panel' 'White'
    Write-C '  ========================================================' 'Cyan'
    Write-Info "launcher: $LauncherDir"

    $rows = Get-AllStatus
    Write-StatusTable $rows

    Write-C '  [1] start everything        [2] start one instance' 'White'
    Write-C '  [3] stop everything         [4] stop one instance' 'White'
    Write-C '  [5] open in browser         [6] restart everything' 'White'
    Write-C '  [7] show logs               [8] status / refresh' 'White'
    Write-C '  [9] doctor (diagnose)       [0] exit' 'White'
    Write-Host ''
    $choice = Read-Host '  choice'

    switch ($choice) {
      '1' { Invoke-Start $null }
      '2' {
        $n = Read-Host '  instance name'
        if ($n) { Invoke-Start @($n) }
      }
      '3' { Invoke-Stop $null }
      '4' {
        $n = Read-Host '  instance name'
        if ($n) { Invoke-Stop @($n) }
      }
      '5' {
        Write-C '  press ENTER to open every running instance, or type a name' 'Gray'
        $n = Read-Host '  instance'
        if ($n) { Invoke-Open @($n) } else { Invoke-Open $null }
      }
      '6' { Invoke-Stop $null; Invoke-Start $null }
      '7' {
        $n = Read-Host '  instance name (ENTER = all)'
        if ($n) { Invoke-Logs @($n) $Lines } else { Invoke-Logs $null $Lines }
      }
      '8' { }
      '9' { Invoke-Doctor }
      '0' { return }
      default { Write-Warn2 "unknown choice '$choice'" }
    }

    if ($choice -ne '8') {
      Write-Host ''
      Read-Host '  press ENTER to return to the panel' | Out-Null
    }
  }
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

function Write-Json($Obj) {
  <# Serialize with matching depth and no BOM, and never let a dead stdout abort
     the caller. Detached processes are started with UseShellExecute so they do
     not inherit console handles; if the originating console has already exited,
     writing the result throws, and $ErrorActionPreference='Stop' would turn that
     into a crash after the work had in fact succeeded. #>
  try {
    $Obj | ConvertTo-Json -Depth 8 -Compress | Write-Output
  } catch {
    try { Write-Log "Write-Json failed (stdout closed?): $($_.Exception.Message)" } catch { }
  }
}

try {
  switch ($Command) {
    'menu'    { Invoke-Menu }
    'app'     { if ($PSBoundParameters.ContainsKey('Stop') -and [bool]$Stop) { Stop-App } else { Invoke-App } }
    # `tray` starts or toggles, `tray-start` is the explicit form for scripted
    # callers, and `tray-stop` exists because a trailing -Stop switch would be
    # collected into the positional target list instead of reaching this switch.
    'tray'       { Invoke-Tray -Stop:($PSBoundParameters.ContainsKey('Stop') -and [bool]$Stop) }
    'tray-start' { Invoke-Tray }
    'tray-stop'  { Invoke-Tray -Stop }
    # Internal: the detached process that owns the tray's message loop.
    'tray-loop'  { Start-TrayLoop -IntervalSeconds $TrayInterval }
    'status'  { $rows = @(Get-AllStatus)
                if ($Json) { Write-Json $rows } else { Write-StatusTable $rows } }
    'start'   { if ($Json) { Invoke-Start $Target -Quiet; Write-Json @(Get-AllStatus -NoProbeHttp) }
                else { Invoke-Start $Target } }
    'stop'    { if ($Json) { Invoke-Stop $Target; Write-Json @(Get-AllStatus -NoProbeHttp) }
                else { Invoke-Stop $Target } }
    'restart' { if ($Json) { Invoke-Stop $Target; Start-Sleep -Milliseconds 500; Invoke-Start $Target -Quiet; Write-Json @(Get-AllStatus -NoProbeHttp) }
                else { Invoke-Stop $Target; Start-Sleep -Milliseconds 500; Invoke-Start $Target } }
    'open'    { Invoke-Open $Target }
    'logs'    { Invoke-Logs $Target $Lines }
    'add'     { if ($Json) { Invoke-Add -Quiet; Write-Json @((Get-HostsConfig).instances) }
                else { Invoke-Add } }
    'list'    { $insts = @((Get-HostsConfig).instances)
                if ($Json) { Write-Json $insts } else { Invoke-List } }
    'install' { if ($Json) { Invoke-Install $Target -Quiet; Write-Json @{ ok = $true } }
                else { Invoke-Install $Target } }
    'doctor'  { Invoke-Doctor }
  }
} catch {
  if ($Json) {
    Write-Json @{ error = $_.Exception.Message; stack = $_.ScriptStackTrace }
    exit 1
  }
  Write-Host ''
  Write-Err "unhandled error: $($_.Exception.Message)"
  Write-C ($_.ScriptStackTrace) 'DarkGray'
  Write-Log "ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
  exit 1
}

exit 0
