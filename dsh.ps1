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
  app      start the desktop panel (backend + chromeless window) - the usual entry
  menu     interactive control panel in the terminal (default)
  status   show every instance and its health
  start    start an instance (server + tunnel, then optionally open browser)
  stop     stop an instance (kills local server and/or tunnel + remote service)
  restart  stop then start
  open     open the browser at an already-running instance
  logs     print an instance's log, or stream it with -Follow
  add      register an instance in the config (does not read your ~/.ssh/config)
  list     list configured instances
  install  deploy the remote systemd service to a host
  upgrade  check for and install a newer dsh (-DryRun to preview)
  check    report which instances have an update available
  balance  show the DeepSeek account balance
  url      print an instance's current authenticated URL
  doctor   diagnose the environment and every configured host
  tray  tray-start  tray-stop
           notification-area icon; alerts when an instance changes state
  tray-loop  internal: the detached process that owns the tray's message loop
             (there is no `help` verb - an invalid Command lists every valid one)

.PARAMETER Target
  One or more instance names (or "local"). Defaults to every enabled instance.
  Accepts a comma-separated list as well as separate arguments.

.EXAMPLE
  .\dsh.ps1 app                   # open the desktop panel
.EXAMPLE
  .\dsh.ps1                       # interactive control panel in the terminal
.EXAMPLE
  .\dsh.ps1 status
.EXAMPLE
  .\dsh.ps1 status -Target DuckServer -NoProbe   # one host, no HTTP probe
.EXAMPLE
  .\dsh.ps1 start Research_Prod
.EXAMPLE
  .\dsh.ps1 start -NoOpen         # bring everything up, do not touch the browser
.EXAMPLE
  .\dsh.ps1 install DuckServer    # deploy the remote service to a new host
.EXAMPLE
  .\dsh.ps1 logs -Target local -Follow           # stream a log until Ctrl-C
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('menu','app','tray','tray-start','tray-stop','tray-loop','status','start','stop','restart','open','logs','add','list','install','check','upgrade','balance','url','doctor')]
  [string]$Command = 'menu',

  [Parameter(Position = 1)]
  [string[]]$Target,

  [switch]$NoOpen,
  [switch]$AppWindow,
  [int]$LocalPort,
  [int]$Lines = 40,
  [switch]$Follow,      # logs: stream instead of printing once (Ctrl-C to stop)
  [string]$SshHost,
  [string]$Name,
  [int]$Port,

  [switch]$Json,        # emit machine-readable JSON (used by the desktop app)
  [switch]$NoProbe,     # status: skip the HTTP liveness probe (see -Probe below)
  # Accepted for compatibility and deliberately inert: probing is what status
  # does by default, so there is nothing to force. It is listed here rather than
  # removed because callers pass it, and PowerShell rejects an undeclared named
  # parameter outright. tools/check-ui.js allows this one name to go unread.
  [switch]$Probe,

  # Config file to use instead of the discovered one. Also settable through
  # $DSH_LAUNCHER_CONFIG, which is how you keep several configurations around.
  [string]$Config,

  # `app -Stop` stops the desktop app's backend and closes its window. Declared
  # here because PowerShell rejects an undeclared named parameter outright
  # (NamedParameterNotFound) rather than treating it as a positional argument.
  [switch]$Stop,

  [string]$SshConfigPath,  # override the ssh config used for host discovery

  [int]$TrayInterval = 20, # seconds between tray state polls

  [switch]$DryRun,         # upgrade: report what would change, change nothing

  [switch]$Refresh         # balance: ignore the cache and re-query
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# True while an -Json command is running. The console helpers below consult it
# before writing anything human-readable, because Write-Host output reaches the
# same host stream the caller captures: a stray "[warn] unknown instance" ahead
# of the payload breaks every consumer that parses the result. Set as early as
# possible, and never re-initialised further down - a later `= $false` would
# silently disable the guard.
$script:JsonMode = [bool]$Json

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

# Under -Json the payload owns stdout and nothing else may appear there: the
# caller parses that stream, and a stray "[warn] port 3100 is held by ..." in
# front of the JSON is a parse failure, not a warning. Note that Write-Host
# does reach that stream - it writes to the host output, which is exactly what
# a captured stdout is - so "it is only a host message" is not a defence.
#
# The fix is to move the line, not to drop it. stderr is captured separately by
# callers (the app backend keeps stdout and stderr in distinct buffers), so the
# diagnostic stays available in the log while the machine-readable stream stays
# clean. Dropping it outright would have hidden real problems such as "port was
# taken, started on another one instead".
function Write-Diag([string]$Text, [string]$Color = 'Gray') {
  if (-not $script:JsonMode) { Write-C $Text $Color; return }
  # WriteLine, not Write-Error: these are notes, not terminating conditions, and
  # a PowerShell error record would be wrapped in a RemoteException by the
  # caller's shell and drown the message in noise.
  try { [Console]::Error.WriteLine($Text) } catch { }
}

function Write-Warn2([string]$Text){ Write-Diag "  [warn] $Text" 'Yellow' }
# Errors follow the same rule as warnings: under -Json the payload owns stdout,
# and "[fail] no remote instances selected" printed ahead of the JSON is what
# made a failed install look parseable but wrong. stderr keeps it visible.
function Write-Err([string]$Text)  { Write-Diag "  [fail] $Text" 'Red' }
function Write-Info([string]$Text) { Write-Diag "  [info] $Text" 'Gray' }

function Write-Log([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  try { Add-Content -Path (Join-Path $LogDir 'launcher.log') -Value $line -Encoding UTF8 } catch { }
}

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------

function Get-B64Payload([string]$Script) {
  <# The bytes of a remote script, as the base64 payload every ssh call sends.

     Line endings are forced to LF before encoding. .gitattributes asks for CRLF
     in .ps1 files (right for PowerShell), so every here-string in this file
     carries CRLF -- and bash rejects CRLF with errors like
     "set: +e\r: invalid option" and "syntax error: unexpected end of file".
     The deploy path already normalised its own payload; the probe path did not,
     which made every remote instance report "服务器上还没有安装 dsh" no matter
     what was actually installed. Normalising here fixes every caller at once. #>
  $normalized = ($Script -replace "`r`n", "`n") -replace "`r", "`n"
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
}

function Invoke-B64([string]$Script, [string]$SshHostName, [int]$TimeoutSec = 30) {
  <# Run a bash script on a remote host. The script is base64-encoded so that
     nothing between here and the remote bash can reinterpret its bytes: nested
     quoting through PowerShell -> ssh -> bash mangles anything else.
     The payload is ASCII by construction, so the encoding of our own pipe into
     ssh cannot corrupt it regardless of the console code page.

     Line-ending normalisation lives in Get-B64Payload, which the batched probe
     path shares. #>
  $b64 = Get-B64Payload $Script
  # ssh reports failures ("Connection refused", "Permission denied") on stderr,
  # and under $ErrorActionPreference='Stop' a native command's stderr line is a
  # TERMINATING error: one unreachable host aborted the entire command, so the
  # panel showed a crash instead of marking that host unreachable. Continue for
  # the duration of the call and keep stderr as ordinary text.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # accept-new matches what Test-SshReachable used to do: this is the only ssh
  # call on the status path now, so a host whose key is not in known_hosts yet
  # must still be reachable on the first probe rather than reported as down.
  try { $out = & ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $SshHostName "echo $b64 | base64 -d | bash" 2>&1 }
  finally { $ErrorActionPreference = $prevEap }
  return ($out | Out-String)
}

function Test-SshReachable([string]$SshHostName, [int]$TimeoutSec = 8) {
  # Same stderr-is-not-fatal rule as Invoke-B64: an unreachable host must answer
  # $false, not throw.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = & ssh -n -o BatchMode=yes -o ConnectTimeout=$TimeoutSec -o StrictHostKeyChecking=accept-new $SshHostName "echo REACHABLE" 2>&1 }
  finally { $ErrorActionPreference = $prevEap }
  return (($out | Out-String) -match 'REACHABLE')
}

function Get-NetstatListeners {
  <# TCP listeners with their owning pid, from one netstat call (~200 ms).
     Only used where the pid itself is needed; the plain "is anything on this
     port" question is answered by Test-PortListening without a child process.

     The state word is deliberately not matched: it is localised on some Windows
     builds. A listening row is recognised by its FOREIGN address being port 0
     (0.0.0.0:0 or [::]:0), which no established connection can have. #>
  $rows = @()
  # Native stderr is a terminating error under $ErrorActionPreference='Stop'
  # (same rule as Invoke-B64), and this call treats all output as data.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = & netstat.exe -ano -p tcp 2>&1 } finally { $ErrorActionPreference = $prevEap }
  foreach ($line in $out) {
    if ($line -notmatch '^\s*TCP\s+(\S+):(\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$') { continue }
    # Copy the captures out before the next -match: -match and -notmatch both
    # overwrite $Matches, so reading $Matches[1] after testing the foreign address
    # silently yields nulls.
    $addr = $Matches[1]; $portValue = [int]$Matches[2]; $foreign = $Matches[3]; $ownerPid = [int]$Matches[5]
    if ($foreign -notmatch ':0$') { continue }
    $rows += [pscustomobject]@{ Address = $addr; Port = $portValue; Pid = $ownerPid }
  }
  return $rows
}

function Get-ListeningPid([int]$PortValue) {
  <# Returns the pid listening on the loopback address of $PortValue.
     Deliberately ignores listeners bound to other local addresses: this machine
     has Termius on 127.0.0.124:3080 as well as dsh on 127.0.0.1:3080, and
     "first listener wins" picks the wrong one. #>
  $mine = @(Get-NetstatListeners | Where-Object { $_.Port -eq $PortValue })
  if ($mine.Count -eq 0) { return 0 }
  $loop = $mine | Where-Object { $_.Address -eq '127.0.0.1' } | Select-Object -First 1
  if ($loop) { return [int]$loop.Pid }
  $any = $mine | Where-Object { $_.Address -eq '[::1]' } | Select-Object -First 1
  if ($any) { return [int]$any.Pid }
  return 0
}

function Test-PortListening([int]$PortValue) {
  <# Is a loopback listener on this port? Asked through the IP helper API: ~1 ms
     and no child process.

     Get-NetTCPConnection answered the same question in ~2.4 s per call on a
     normal Windows box (it is a CIM query). The start path polls this every
     300 ms while dsh boots, and Find-FreePort calls it once per candidate port,
     so the panel kept showing "starting" for seconds after dsh was already
     serving, and searching for a free port could take minutes. Same address rule
     as Get-ListeningPid: 127.0.0.1 or ::1 counts, a wildcard or any other local
     address does not. #>
  try {
    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    foreach ($ep in $listeners) {
      if ([int]$ep.Port -ne $PortValue) { continue }
      $addr = $ep.Address.ToString()
      if ($addr -eq '127.0.0.1' -or $addr -eq '::1') { return $true }
    }
    return $false
  } catch {
    # Fall back to the pid lookup if the IP helper API is ever unavailable.
    return ((Get-ListeningPid $PortValue) -gt 0)
  }
}

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
     the server can be spawned without a console window.

     The npm prefix is worked out from the filesystem before asking npm itself:
     `npm root -g` starts a node process (~0.7 s) and this function runs on every
     status refresh, through Get-LocalDshVersion. A prefix= line in .npmrc wins
     over the default, exactly as npm resolves it; `npm root -g` remains the
     fallback for anything neither of those covers (env vars, fnm, pnpm, ...). #>
  $prefixes = @()
  $npmrc = Join-Path $HomeDir '.npmrc'
  if (Test-Path $npmrc) {
    foreach ($line in @(Get-Content $npmrc -ErrorAction SilentlyContinue)) {
      if ($line -match '^\s*prefix\s*=\s*(.+?)\s*$') { $prefixes += $Matches[1].Trim('"') }
    }
  }
  $prefixes += (Join-Path $env:APPDATA 'npm')
  foreach ($prefix in $prefixes) {
    $candidate = Join-Path $prefix 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $candidate) { return $candidate }
  }

  $npmRoot = (npm root -g 2>$null | Select-Object -First 1)
  if ($npmRoot) {
    $candidate = Join-Path $npmRoot '@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $candidate) { return $candidate }
  }
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
     out of the log keeps this function correct for either.

     Only a URL for the port being asked about counts. The log can still hold a
     URL from an earlier run on a different port (an instance started with
     -LocalPort, then re-adopted), and handing that to the browser opens a dead
     page. The rotated log is searched as well: the run that is still serving
     this port may be the one whose output was rotated away.

     Falls back to the plain port URL when the log has no line for it yet; the
     start path polls the log-only variant so it can record the real link the
     moment dsh prints it. #>
  $logged = Get-LocalUrlFromLog $InstanceName $PortValue
  if ($logged) { return $logged }
  return "http://127.0.0.1:$PortValue"
}

function Get-LocalUrlFromLog([string]$InstanceName, [int]$PortValue) {
  <# The ready line dsh printed for exactly this port, or '' when there is none.

     See Get-LocalUrl for why only a line matching this port counts, and why the
     rotated log is searched too. #>
  foreach ($file in @("$InstanceName.server.log", "$InstanceName.server.log.1")) {
    $log = Join-Path $LogDir $file
    if (-not (Test-Path $log)) { continue }
    $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    $m = [regex]::Matches($text, 'dsh web:\s+(http://[^\s()]+)')
    for ($i = $m.Count - 1; $i -ge 0; $i--) {
      $url = $m[$i].Groups[1].Value
      if ($url -match ":$PortValue/") { return $url }
    }
  }
  return ''
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

function Resolve-ConfigPath([string]$Explicit) {
  <# The config path is passed IN rather than read from a script variable.

     Reading it here via $PSBoundParameters worked in theory and not in practice:
     a function's $PSBoundParameters reflects that function's own parameters, and
     depending on how the script is invoked the script-level ones are not visible,
     so `-Config` was silently ignored and hosts.json always won. An explicit
     argument cannot be ambiguous. #>
  if ($Explicit) { return $Explicit }
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

function Get-SshConfigPath([string]$Override) {
  <# honours -SshConfigPath, then $DSH_SSH_CONFIG, then the user's ~/.ssh/config.

     The override is an explicit argument rather than a read of the script-scope
     $SshConfigPath, because a function's $PSBoundParameters reflects *its own*
     parameters: the earlier version tested $PSBoundParameters.ContainsKey(
     'SshConfigPath') inside a function that declares nothing, so the condition
     could never be true and `doctor -SshConfigPath <path>` silently read the
     default file instead. This is the same bug that was already fixed once for
     -Config (see Resolve-ConfigPath), and it is why an override must be
     threaded through rather than discovered. #>
  if ($Override) { return [string]$Override }
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

function Get-HostsConfig([string]$ConfigPath) {
  <# $ConfigPath is threaded through every caller from the script's -Config
     parameter. Passing it explicitly rather than reading a script variable is
     what makes -Config actually work. #>
  $path = Resolve-ConfigPath $ConfigPath
  if (-not (Test-Path $path)) {
    $cfg = Get-DefaultHosts
    Save-HostsConfig $cfg -ConfigPath $path
    return $cfg
  }
  $raw = Get-Content $path -Raw -Encoding UTF8
  if (-not $raw -or -not $raw.Trim()) { return Get-DefaultHosts }
  $obj = $raw | ConvertFrom-Json
  if (-not $obj.instances) { throw "config has no 'instances' array: $path" }
  return $obj
}

function Save-HostsConfig($Cfg, [string]$ConfigPath) {
  $path = Resolve-ConfigPath $ConfigPath
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

function Get-InstProp($Inst, [string]$Name, $Default = $null) {
  <# Instance field with a default. Optional config fields must never be read
     directly: `$Inst.workdir` on an instance that omits it is a hard error under
     Set-StrictMode, which crashed a start the moment a config got terse. #>
  $v = Get-ConfigProp $Inst $Name
  if ($null -eq $v -or $v -eq '') { return $Default }
  return $v
}

function Test-InstFlag($Inst, [string]$Name, [bool]$Default = $false) {
  <# Boolean instance field with a default; same reasoning as Get-InstProp. #>
  $v = Get-ConfigProp $Inst $Name
  if ($null -eq $v) { return $Default }
  return [bool]$v
}

function Get-Profiles([string]$ConfigPath) {
  <# Normalised profile lookup: profile -> merged connection defaults.
     Per-user overrides win over the shared profile so the same repo config
     serves everyone without editing committed files. #>
  $cfg = Get-HostsConfig $Config $ConfigPath
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

function Get-Instances([string[]]$Names, [string]$ConfigPath) {
  <# Callers wrap the result in @(), which turns zero-or-one results into a real
     array so .Count is always safe under Set-StrictMode -Version Latest.
     Do NOT return ,@(...) here: that nests the array one level deeper and makes
     `foreach` iterate over the collection itself instead of its instances. #>
  $cfg = Get-HostsConfig $Config $ConfigPath
  $all = @($cfg.instances)

  # Expand "profile" references into concrete connection fields.
  $profiles = Get-Profiles $ConfigPath
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
    return @($all | Where-Object { (Get-ConfigProp $_ 'enabled') -ne $false })
  }
  $sel = @()
  foreach ($n in $Names) {
    # Accept "a,b" as well as "a","b". The parameter is [string[]], which makes
    # a comma list look supported, but PowerShell only splits on commas in
    # *unquoted* argument position - a quoted 'local,DuckServer' arrives as one
    # element and used to match nothing and quietly return an empty table.
    foreach ($piece in ([string]$n -split ',')) {
      $name = $piece.Trim()
      if (-not $name) { continue }
      $hit = @($all | Where-Object { $_.name -eq $name })
      if ($hit.Count -eq 0) {
        # Reaches stdout normally and stderr under -Json, so the caller can tell
        # an unknown name from "configured but not running" either way.
        Write-Warn2 "unknown instance '$name' (see: dsh.ps1 list)"
        continue
      }
      $sel += $hit
    }
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

function Get-InstWorkdir($Inst) {
  <# The directory a local instance actually starts in.

     Resolution used to live inline in the start path, so only a launch knew the
     answer; status and the panel could not say where an instance would open.
     That matters because a stale workdir silently starts a session in the wrong
     project - the exact failure the roadmap calls out. Falls back to $HOME when
     the configured directory is missing, matching what start does, so the value
     reported is always the value that would be used. #>
  $wd = Get-InstProp $Inst 'workdir' $env:USERPROFILE
  if (-not $wd -or -not (Test-Path $wd)) { return $env:USERPROFILE }
  return $wd
}

function Get-LocalStatus($Inst, [switch]$NoProbeHttp) {
  $configuredPort = [int](Get-InstProp $Inst 'port' 3080)
  $port = $configuredPort
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

  # Same update flag the remote rows carry, from the cached registry lookup.
  $localVersion = Get-LocalDshVersion
  $latestVersion = Get-LatestDshVersion
  $updateAvailable = $false
  if ($localVersion -and $latestVersion) {
    $updateAvailable = (Compare-Version $latestVersion $localVersion) -gt 0
  }

  return [pscustomobject]@{
    Name = $Inst.name; Kind = 'local'; Port = $port
    State = $state; Detail = $detail; Http = $httpCode
    Url = $url
    # Where this instance starts sessions. Only meaningful locally: a remote
    # workdir lives on the other machine and cannot be opened from here.
    Workdir = (Get-InstWorkdir $Inst)
    DshVersion = $localVersion
    LatestVersion = $latestVersion
    UpdateAvailable = $updateAvailable
  }
}

function Test-DshServing([int]$Port) {
  <# Is a dsh web server actually answering on this port?

     A port being in LISTEN state is not enough to conclude "dsh is here". The
     code has to answer HTTP, and dsh fences `/` in a version-dependent way, so a
     definite answer is accepted and anything else (connection refused, a TLS
     handshake, a stray service) is not. `401` means a modern dsh demanding its
     token; `200` means an older one that does not; `303`/`302` means a token
     query was already redeemed. #>
  $code = Test-Http "http://127.0.0.1:$Port/"
  return ($code -eq 200 -or $code -eq 401 -or $code -eq 303 -or $code -eq 302)
}

function Start-LocalInstance($Inst, [switch]$Quiet, [int]$PortOverride = 0) {
  $name = $Inst.name
  $configuredPort = [int](Get-InstProp $Inst 'port' 3080)
  $port = $configuredPort
  $explicitPort = ($PortOverride -gt 0)
  if ($explicitPort) { $port = $PortOverride }
  $log  = Join-Path $LogDir "$name.server.log"

  # ---------------------------------------------------------------- preflight
  # Decide the port BEFORE spawning anything. This is the whole point: an earlier
  # version only checked here and then still spawned on a taken port, so the new
  # process died with EADDRINUSE while the wait loop saw the OTHER process
  # listening and cheerfully reported success. The user was left with a failure
  # message and no working instance.
  if (Test-PortListening $port) {
    $holding = Get-ListeningPid $port
    $holdingName = Get-ProcessNameSafe $holding

    if ($holdingName -eq 'node' -and (Test-DshServing $port) -and -not $explicitPort) {
      # A dsh this launcher did not start. Adopt it rather than fighting it: the
      # user's own `npx @deepseek-ai/dsh web` is a legitimate dsh to use.
      if (-not $Quiet) { Write-Info "$name is already served on port $port (pid $holding) - adopting it" }
      Set-State $name ([pscustomobject]@{
        serverPid = $holding; port = $port
        url = (Get-LocalUrl $name $port); adopted = $true
        updatedAt = (Get-Date).ToString('o')
      })
      return $port
    }

    if ($explicitPort) {
      # An explicit port is a request, so refuse rather than silently moving.
      Write-Err "$name cannot start: port $port is held by $holdingName (pid $holding)"
      Write-Info 'stop that process, or choose another port with -LocalPort'
      return 0
    }

    # Move to a free port instead of failing. Say so plainly, because the URL the
    # user sees will not match the configured port.
    $free = Find-FreePort ($port + 1)
    if ($free -eq $port) {
      Write-Err "$name cannot start: port $port is held by $holdingName (pid $holding)"
      return 0
    }
    Write-Warn2 "port $port is held by $holdingName (pid $holding); starting on $free instead"
    $port = $free
  }

  $bin = Find-DshLocal
  if (-not $bin) { Write-Err "$name cannot start: dsh not found. Install with: npm i -g @deepseek-ai/dsh"; return 0 }
  $node = Get-NodeExe
  if (-not $node) { Write-Err "$name cannot start: node.exe not found on PATH"; return 0 }

  if (Test-Path $log) { Move-Item -Force $log "$log.1" -ErrorAction SilentlyContinue }

  # Resolution lives in Get-InstWorkdir so status reports the same directory a
  # launch would use, instead of duplicating the rule here.
  $workdir = Get-InstWorkdir $Inst

  # The panel backend keeps the environment it was started with, so a
  # DEEPSEEK_API_KEY added to the user environment afterwards never reaches the
  # dsh servers it spawns: dsh snapshots its launch environment, finds no key
  # there, and the first agent run dies with MISSING_CREDENTIAL even though the
  # variable is set "in the environment". Re-read the persisted user (then
  # machine) value and fill only that gap -- a value this process already
  # carries stays authoritative, and the key itself is never written to config,
  # state, or logs.
  if (-not $env:DEEPSEEK_API_KEY) {
    $persistedKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
    if (-not $persistedKey) { $persistedKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'Machine') }
    if ($persistedKey) {
      $env:DEEPSEEK_API_KEY = $persistedKey
      Write-Log "local ${name}: filled DEEPSEEK_API_KEY from the persisted user environment"
    }
  }

  # Record the chosen port before starting, so status and stop agree with it even
  # if this function is interrupted.
  Set-State $name ([pscustomobject]@{
    serverPid = 0; port = $port; updatedAt = (Get-Date).ToString('o')
  })

  # CREATE_NO_WINDOW (0x08000000) keeps node from flashing a conhost window.
  $args = "`"$bin`" web --port $port --no-open"
  $proc = Start-Process -FilePath $node -ArgumentList $args -WorkingDirectory $workdir `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
            -WindowStyle Hidden -PassThru
  Write-Log "started local $name pid $($proc.Id) on port $port"

  # ------------------------------------------------------------------- confirm
  # Success requires BOTH our process to be alive and the port to answer as dsh.
  # Waiting on the port alone is what produced the false success above.
  $deadline = (Get-Date).AddSeconds(90)
  $up = $false
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    if ((Test-PortListening $port) -and (Test-DshServing $port)) {
      # Two starts can race for the same instance, and the port answers as soon
      # as EITHER child binds it. Success means our own child owns the listener:
      # a child that lost the race is about to exit with EADDRINUSE, and
      # recording its pid leaves the instance reporting "up-external" with a
      # pid that is already dead, so stop then refuses to touch it. netstat
      # runs only once the port answers, not on every poll.
      $holder = Get-ListeningPid $port
      if ($holder -eq $proc.Id -or $holder -eq 0) { $up = $true; break }
    }
    Start-Sleep -Milliseconds 300
  }

  if (-not $up) {
    # A start that lost the race still leaves a healthy instance behind: adopt
    # the process that owns the port rather than reporting a failure for an
    # instance that is serving.
    if ($proc.HasExited -and (Test-PortListening $port) -and (Test-DshServing $port)) {
      $holder = Get-ListeningPid $port
      if ($holder -gt 0 -and (Get-ProcessNameSafe $holder) -eq 'node') {
        if (-not $Quiet) { Write-Warn2 "$name was started by another run; adopting pid $holder on port $port" }
        Set-State $name ([pscustomobject]@{
          serverPid = $holder; port = $port; url = (Get-LocalUrl $name $port); updatedAt = (Get-Date).ToString('o')
        })
        Write-Log "adopted local $name pid $holder on port $port (another start won the race)"
        return $port
      }
    }
    if ($proc.HasExited) {
      Write-Err "$name failed to start: the process exited with code $($proc.ExitCode)"
    } else {
      Write-Err "$name failed to start within 90s"
    }
    $errText = ''
    if (Test-Path "$log.err") { $errText = (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue) }
    if ($errText -and $errText.Trim()) {
      Write-C (($errText.Trim() -split "`r?`n" | Select-Object -First 8) -join "`n") 'DarkGray'
      if ($errText -match 'EADDRINUSE|address already in use') {
        Write-Info "port $port was taken by another process; retry and the launcher will pick a free one"
      }
    } elseif (Test-Path $log) {
      Get-Content $log -Tail 10 | ForEach-Object { Write-C "    $_" 'DarkGray' }
    }
    if (-not $proc.HasExited) { try { $null = & taskkill.exe /PID $proc.Id /T /F 2>&1 } catch { } }
    Remove-State $name
    return 0
  }

  # dsh prints its ready line as it starts answering, so poll for that line
  # instead of sleeping a flat two seconds -- the link (and its one-time token)
  # is normally in the log the moment the port answers. A build that never prints
  # one still falls back to the plain URL after the bounded wait.
  $url = ''
  $urlDeadline = (Get-Date).AddSeconds(3)
  while (-not $url -and (Get-Date) -lt $urlDeadline) {
    $url = Get-LocalUrlFromLog $name $port
    if (-not $url) { Start-Sleep -Milliseconds 100 }
  }
  if (-not $url) { $url = "http://127.0.0.1:$port" }
  Set-State $name ([pscustomobject]@{
    serverPid = $proc.Id; port = $port; url = $url; updatedAt = (Get-Date).ToString('o')
  })
  if (-not $Quiet) {
    if ($port -ne $configuredPort) { Write-Ok "$name up on port $port (pid $($proc.Id)); configured port was busy" }
    else { Write-Ok "$name up on port $port (pid $($proc.Id))" }
  }
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
    $configuredPort = [int](Get-InstProp $Inst 'port' 3080)
  $port = $configuredPort
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

# --------------------------------------------------------------------------
# Versions and upgrades
# --------------------------------------------------------------------------

function Get-LatestDshVersion([switch]$Refresh) {
  <# The version `npm install -g @deepseek-ai/dsh` would install. Cached to disk
     for a few hours because the panel asks for it on every status refresh and the
     npm registry should not be hit every 20 seconds. #>
  $cacheFile = Join-Path $StateDir 'latest-version.json'
  if (-not $Refresh -and (Test-Path $cacheFile)) {
    try {
      $c = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $age = (Get-Date) - [datetime]$c.checkedAt
      if ($age.TotalHours -lt 6 -and $c.version) { return $c.version }
    } catch { }
  }
  $v = ''
  try {
    $r = Invoke-WebRequest -Uri 'https://registry.npmjs.org/@deepseek-ai/dsh' -UseBasicParsing -TimeoutSec 20
    $j = $r.Content | ConvertFrom-Json
    $v = [string]$j.'dist-tags'.latest
  } catch { }
  if ($v) {
    try {
      [pscustomobject]@{ version = $v; checkedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8
    } catch { }
  } elseif (Test-Path $cacheFile) {
    # Offline: fall back to whatever was last known rather than reporting nothing.
    try { $v = [string]((Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json).version) } catch { }
  }
  return $v
}

function Get-DesiredDshVersion($Inst) {
  <# The version an instance should run.

     Resolution order, most specific first:
       1. the instance's own "dshVersion"
       2. the instance's project "autoUpdate.version"
       3. when autoUpdate is enabled, whatever npm's `latest` currently is
     A pin that resolves to a plain pin means "do not chase releases"; leaving it
     unset with autoUpdate off means "do not check at all". #>
  $instPin = ''
  if ($Inst -and $Inst.PSObject.Properties['dshVersion'] -and $Inst.dshVersion) { $instPin = [string]$Inst.dshVersion }
  return $instPin
}

function Get-UpdateStatus($Inst, [string]$LocalOrRemoteVersion) {
  <# Compares a running version against the newest published one and classifies
     the gap. Deliberately does NOT act: upgrading restarts dsh and would drop any
     session in flight, so it stays a decision the person makes, not a side effect
     of launching the tool. #>
  $latest = Get-LatestDshVersion
  $pin = Get-DesiredDshVersion $Inst
  $target = if ($pin) { $pin } else { $latest }
  $current = [string]$LocalOrRemoteVersion
  $result = [ordered]@{
    current = $current
    latest = $latest
    pinned = $pin
    target = $target
    updateAvailable = $false
    reason = ''
  }
  if (-not $current) { $result.reason = 'unknown-current'; return [pscustomobject]$result }
  if (-not $target) { $result.reason = 'unknown-latest'; return [pscustomobject]$result }
  if ($target -eq $current) { $result.reason = 'current'; return [pscustomobject]$result }
  $cmp = Compare-Version $target $current
  if ($cmp -gt 0) {
    $result.updateAvailable = $true
    $result.reason = if ($pin) { 'behind-pin' } else { 'behind-latest' }
  } else {
    $result.reason = if ($pin) { 'ahead-of-pin' } else { 'ahead-of-latest' }
  }
  return [pscustomobject]$result
}

function Upgrade-LocalDsh([string]$Version, [switch]$DryRun) {
  <# Upgrade dsh on this machine.

     Warns rather than upgrading silently when an instance is currently served by
     this dsh: replacing it would disturb a running session. #>
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) { Write-Err 'npm not found on PATH; cannot upgrade the local dsh'; return $false }
  $current = Get-LocalDshVersion
  $target = if ($Version) { $Version } else { Get-LatestDshVersion }
  if (-not $target) { Write-Err 'could not determine the target version'; return $false }
  if ($current -eq $target) {
    Write-Ok "local dsh is already $current"
    return $true
  }

  $spec = "@deepseek-ai/dsh@$target"
  if ($DryRun) {
    Write-Info "[dry-run] would run: npm install -g $spec"
    Write-Info "[dry-run] current $current -> $target"
    return $true
  }

  $bg = Get-LocalStatus ([pscustomobject]@{ name = 'local'; port = 3080 })
  Write-Info "upgrading local dsh $current -> $target"
  if ($bg.State -eq 'up' -or $bg.State -eq 'up-external') {
    Write-Warn2 'a local dsh server is running; it keeps the old code until restarted'
    Write-Warn2 'on Windows its native DLLs stay locked, so a repair pass may be needed'
  }
  if (-not (Invoke-NpmGlobal $spec)) {
    # A locked native dependency (sharp/koffi ship .node/.dll files that a running
    # dsh holds open) can produce a half-extracted tree: npm reports the new
    # version while a dependency is missing files. That is not a warning, it is a
    # broken install, and it is repaired by forcing a re-extract.
    Write-Warn2 'first attempt did not leave a working install; retrying with --force'
    if (-not (Invoke-NpmGlobal $spec -Force)) {
      Write-Err 'could not install a working dsh'
      return $false
    }
  }
  $script:LocalDshVersion = ''      # invalidate the cache
  $after = Get-LocalDshVersion
  Write-Ok "local dsh upgraded to $after"
  Write-Info 'restart the local instance to use it: dsh.ps1 -Command restart -Target local'
  return $true
}

function Invoke-NpmGlobal([string]$Spec, [switch]$Force) {
  <# Run `npm install -g` and decide success by whether dsh RUNS afterwards, not
     by npm's exit code.

     Two traps, both hit for real on this project:
       1. npm prints deprecation notices on stderr, and with
          $ErrorActionPreference='Stop' PowerShell 5.1 turns native stderr into a
          terminating error -- so a perfectly successful install aborted the
          upgrade. ErrorActionPreference is set to Continue for the duration (its
          value is inherited by native commands, so there is no per-call flag).
       2. An exit code of 0 does NOT mean a usable install. npm can register the
          new version while leaving a dependency directory incomplete, because a
          file was locked by a running process. Only executing the binary proves
          otherwise, so that is the check. #>
  $args = @('install', '-g', $Spec, '--no-fund', '--no-audit')
  if ($Force) { $args += '--force' }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & npm @args 2>&1 | Out-String
  } finally {
    $ErrorActionPreference = $prev
  }
  $script:LocalDshVersion = ''
  $ver = Get-LocalDshVersion
  if ($ver) { return $true }
  $tail = ($out.Trim() -split "`r?`n" | Select-Object -Last 6) -join "`n"
  if ($tail) { Write-C $tail 'DarkGray' }
  return $false
}

function Upgrade-RemoteDsh($Inst, [string]$Version, [switch]$DryRun) {
  <# Upgrade dsh on a remote host in place.

     Order matters and mirrors provisioning: make sure Node is new enough, install
     the target, then PROVE the binary runs before touching the service -- because
     a failed upgrade that is not caught leaves a service that cannot start. Only
     then restart and confirm it is listening again. #>
  $name = $Inst.name
  $sshHost = $Inst.sshHost
  if (-not (Test-SshReachable $sshHost)) {
    $d = Get-RemoteDiagnosis $sshHost
    Write-Err "$name`: cannot reach $sshHost [$($d.Code)]"
    if ($d.Hint) { Write-Info $d.Hint }
    return $false
  }

  $facts = Get-RemoteFacts $sshHost
  $current = "$(if ($facts.ContainsKey('DSH_V')) { $facts['DSH_V'] })".Trim()
  $target = if ($Version) { $Version } else { Get-LatestDshVersion }
  if (-not $target) { Write-Err "$name`: could not determine the target version"; return $false }

  if ($current -eq $target) {
    Write-Ok "$name`: already at $current"
    return $true
  }

  if ($DryRun) {
    Write-Info "[dry-run] $name`: $current -> $target"
    Write-Info "[dry-run] would check node >= 22.19.0, then npm install -g @deepseek-ai/dsh@$target,"
    Write-Info "[dry-run] verify it runs, restart dsh-web.service, and confirm it listens"
    return $true
  }

  # Node gate first: upgrading a package that cannot run is worse than not
  # upgrading it, because it replaces a working install with a broken one.
  $minNode = '22.19.0'
  $nodeV = "$(if ($facts.ContainsKey('NODE_V')) { $facts['NODE_V'] })".Trim()
  $needsNode = $true
  if ($nodeV -and (Compare-Version $nodeV $minNode) -ge 0) { $needsNode = $false }
  if ($needsNode) {
    $hasLocalNode = (Invoke-B64 'if [ -x "$HOME/.local/node/bin/node" ]; then "$HOME/.local/node/bin/node" -v; fi' $sshHost).Trim()
    if ($hasLocalNode -and (Compare-Version $hasLocalNode $minNode) -ge 0) {
      $needsNode = $false
    }
  }
  if ($needsNode) {
    Write-Warn2 "$name`: node $nodeV is older than $minNode; installing a suitable node first"
    if (-not (Install-RemoteDsh $sshHost -Quiet)) {
      Write-Err "$name`: could not prepare node; aborting before changing dsh"
      return $false
    }
  }

  $prefix = if ($facts['NPM_PREFIX'] -and $facts['NPM_PREFIX'] -ne 'none') { $facts['NPM_PREFIX'] } else { '$HOME/.local' }
  if ($prefix -eq '/usr' -or $prefix -eq '/usr/local') { $prefix = '$HOME/.local' }

  Write-Info "$name`: upgrading dsh $current -> $target"
  $upgrade = @'
set -e
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"
if [ -x "$HOME/.local/node/bin/npm" ]; then NPM="$HOME/.local/node/bin/npm"; else NPM="$(command -v npm)"; fi
"$NPM" config set prefix "__PREFIX__" >/dev/null 2>&1 || true
"$NPM" install -g --no-fund --no-audit @deepseek-ai/dsh@__TARGET__ 2>&1 | tail -n 8
echo "----"
for c in "$HOME/.local/bin/dsh" "$HOME/.npm-global/bin/dsh" "$HOME/.local/node/bin/dsh"; do
  if [ -x "$c" ]; then v="$("$c" --version 2>/dev/null | head -1)"; echo "DSH_NOW=$v"; exit 0; fi
done
echo "DSH_NOW="
'@
  $upgrade = $upgrade.Replace('__PREFIX__', $prefix).Replace('__TARGET__', $target)
  $res = Invoke-B64 $upgrade $sshHost

  $nowVer = ''
  if ($res -match 'DSH_NOW=(\S+)') { $nowVer = $Matches[1] }
  if ($nowVer -ne $target) {
    Write-Err "$name`: upgrade failed, dsh reports '$nowVer' instead of '$target'"
    Write-C (($res.Trim() -split "`r?`n" | Select-Object -Last 8) -join "`n") 'DarkGray'
    Write-Info 'the previous installation may still be intact; check before restarting'
    return $false
  }
  Write-Ok "$name`: dsh now $nowVer"

  # Restart so the running server actually uses the new version.
  $r = Invoke-B64 'systemctl --user restart dsh-web.service 2>&1; sleep 3; systemctl --user is-active dsh-web.service 2>&1' $sshHost
  if ($r -notmatch 'active') {
    Write-Err "$name`: service did not come back after the upgrade: $($r.Trim())"
    Write-Info "inspect with: ssh $sshHost journalctl --user -u dsh-web -n 50 --no-pager"
    return $false
  }

  # A restart replaces the token URL, so the tunnel's browser URL is stale until
  # the next start; the tunnel itself survives.
  $rp = [int](Get-InstProp $Inst 'remotePort' 3080)
  $deadline = (Get-Date).AddSeconds(60)
  $listening = $false
  while ((Get-Date) -lt $deadline) {
    if ((Invoke-B64 "ss -ltn 2>/dev/null | grep -q '127.0.0.1:$rp' && echo YES || echo NO" $sshHost) -match 'YES') {
      $listening = $true; break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $listening) { Write-Err "$name`: service restarted but is not listening on $rp"; return $false }
  Write-Ok "$name`: restarted and listening on 127.0.0.1:$rp"
  Write-Info "$name`: the auth URL was reissued; click 启动 to pick up the fresh one"
  return $true
}

function Invoke-Check {
  <# Read-only version report. Safe to run any time, and the fastest way to answer
     "is anything out of date?". #>
  $latest = Get-LatestDshVersion -Refresh
  $local = Get-LocalDshVersion
  $rows = @()
  $rows += [pscustomobject]@{
    Name = 'local'; Kind = 'local'; Current = $local; Latest = $latest
    UpdateAvailable = [bool]($latest -and $local -and (Compare-Version $latest $local) -gt 0)
  }
  foreach ($i in @(Get-Instances $null $Config)) {
    if ((Get-InstProp $i 'kind' 'local') -ne 'remote') { continue }
    if (-not (Test-SshReachable $i.sshHost)) {
      $rows += [pscustomobject]@{ Name = $i.name; Kind = 'remote'; Current = '(unreachable)'; Latest = $latest; UpdateAvailable = $false }
      continue
    }
    $f = Get-RemoteFacts $i.sshHost
    $cur = "$(if ($f.ContainsKey('DSH_V')) { $f['DSH_V'] })".Trim()
    $rows += [pscustomobject]@{
      Name = $i.name; Kind = 'remote'; Current = $cur; Latest = $latest
      UpdateAvailable = [bool]($latest -and $cur -and (Compare-Version $latest $cur) -gt 0)
    }
  }
  if ($Json) { Write-Json $rows; return }
  Write-Head "dsh versions (npm latest: $latest)"
  $fmt = "  {0,-16} {1,-14} {2,-14} {3}"
  Write-C ($fmt -f 'INSTANCE', 'CURRENT', 'LATEST', 'STATUS') 'Cyan'
  foreach ($r in $rows) {
    $status = if ($r.UpdateAvailable) { '可升级' } else { '已是最新' }
    $color = if ($r.UpdateAvailable) { 'Yellow' } else { 'Green' }
    Write-C ($fmt -f $r.Name, $r.Current, $r.Latest, $status) $color
  }
  Write-Host ''
  if (@($rows | Where-Object { $_.UpdateAvailable }).Count -gt 0) {
    Write-Info 'upgrade with: dsh.ps1 -Command upgrade            (all)'
    Write-Info '              dsh.ps1 -Command upgrade -Target prod  (one)'
    Write-Info 'add -DryRun to see what would change without changing it'
  }
}

function Invoke-Upgrade([string[]]$Names, [switch]$DryRun) {
  $insts = @(Get-Instances $Names $Config)
  $target = Get-LatestDshVersion -Refresh
  if (-not $target) { Write-Err 'could not determine the latest published version'; return }
  if (-not $DryRun) {
    Write-Warn2 "upgrading restarts dsh on each instance; any session in flight will be interrupted"
  }
  Write-Head "upgrade to $target"
  # local first: it is the one that is usually furthest behind, and its failure is
  # visible immediately.
  foreach ($i in @($insts | Where-Object { $_.kind -eq 'local' })) {
    Upgrade-LocalDsh -Version $target -DryRun:$DryRun | Out-Null
  }
  foreach ($i in @($insts | Where-Object { $_.kind -eq 'remote' })) {
    Upgrade-RemoteDsh $i -Version $target -DryRun:$DryRun | Out-Null
  }
}

# --------------------------------------------------------------------------
# Account balance
# --------------------------------------------------------------------------

function Get-DshApiKey {
  <# The DeepSeek platform API key, or '' when unavailable.

     Sources, in order:
       1. $env:DEEPSEEK_API_KEY            a key the user exported explicitly
       2. $DSH_HOME/.credentials.yaml      dsh's own credential store

     This reads a secret, so two rules apply: the value is never logged, echoed,
     or placed in an error message, and only the one well-known field is
     consulted rather than parsing arbitrary YAML.

     Note the file's shape. It has a top-level `secret:` field AND a `refs:` map.
     `secret` is dsh's own internal secret, and using it returns 401 from the
     platform API; the platform key lives under refs/DEEPSEEK_API_KEY and looks
     like `sk-...`. That distinction cost a debug cycle, hence the note. #>
  if ($env:DEEPSEEK_API_KEY) { return [string]$env:DEEPSEEK_API_KEY }
  $cred = Join-Path $DshHome '.credentials.yaml'
  if (-not (Test-Path $cred)) { return '' }
  try {
    $raw = Get-Content $cred -Raw -Encoding UTF8
    if ($raw -match 'DEEPSEEK_API_KEY:\s*["'']?([A-Za-z0-9_\-]{20,})') { return $Matches[1] }
  } catch { }
  return ''
}

function Get-AccountBalance([switch]$Refresh) {
  <# Remaining platform credit.

     Cached for a few minutes: without it the panel would hit a billing endpoint
     on every 20-second poll, which is both rude and likely to be rate limited.

     Every failure mode is returned as data rather than thrown -- no key, a
     rejected key, no network. The panel must still render when the balance
     cannot be fetched, because a billing endpoint being down is no reason for
     the control panel to look broken. #>
  $cacheFile = Join-Path $StateDir 'balance.json'
  if (-not $Refresh -and (Test-Path $cacheFile)) {
    try {
      $c = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $age = (Get-Date) - [datetime]$c.checkedAt
      if ($age.TotalMinutes -lt 5) { return $c }
    } catch { }
  }

  $result = [ordered]@{
    ok = $false; reason = ''; isAvailable = $false
    balances = @(); checkedAt = (Get-Date).ToString('o')
  }
  $key = Get-DshApiKey
  if (-not $key) {
    $result.reason = 'no-key'
  } else {
    try {
      $r = Invoke-WebRequest -Uri 'https://api.deepseek.com/user/balance' `
             -Headers @{ Authorization = "Bearer $key" } -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
      $j = $r.Content | ConvertFrom-Json
      $result.ok = $true
      $result.isAvailable = [bool]$j.is_available
      $list = @()
      foreach ($b in @($j.balance_infos)) {
        $list += [pscustomobject]@{
          currency = [string]$b.currency
          total    = [string]$b.total_balance
          granted  = [string]$b.granted_balance
          toppedUp = [string]$b.topped_up_balance
        }
      }
      $result.balances = $list
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { }
      if ($code -eq 401) { $result.reason = 'unauthorized' }
      elseif ($code -eq 403) { $result.reason = 'forbidden' }
      elseif ($code -gt 0) { $result.reason = "http-$code" }
      else { $result.reason = 'network' }
      # The response body is deliberately not included: it can echo request detail.
    }
  }

  try {
    [pscustomobject]$result | ConvertTo-Json -Depth 5 | Set-Content -Path $cacheFile -Encoding UTF8
  } catch { }
  return [pscustomobject]$result
}

function Invoke-Balance([switch]$Refresh) {
  $b = Get-AccountBalance -Refresh:$Refresh
  if ($Json) { Write-Json $b; return }

  Write-Head 'DeepSeek 账户余额'
  if (-not $b.ok) {
    switch ($b.reason) {
      'no-key'       { Write-Warn2 '没找到 API key'
                       Write-Info '设置环境变量 DEEPSEEK_API_KEY，或让 dsh 登录一次写入 ~/.dsh/.credentials.yaml' }
      'unauthorized' { Write-Err 'API key 被拒绝（401）'
                       Write-Info 'key 可能已失效；重新登录 dsh，或换成有效的 DEEPSEEK_API_KEY' }
      'forbidden'    { Write-Err 'API key 无权访问余额接口（403）' }
      'network'      { Write-Warn2 '网络不通，无法查询余额' }
      default        { Write-Err "查询失败：$($b.reason)" }
    }
    return
  }
  if (-not $b.isAvailable) { Write-Warn2 '账户当前不可用（is_available = false）—— 余额可能已耗尽' }
  foreach ($x in @($b.balances)) {
    $mark = if ($x.currency -eq 'CNY') { '¥' } elseif ($x.currency -eq 'USD') { '$' } else { '' }
    Write-C ("  {0,-4} {1}{2}" -f $x.currency, $mark, $x.total) 'Cyan'
    Write-C ("       赠金 {0}{1}   充值 {2}{3}" -f $mark, $x.granted, $mark, $x.toppedUp) 'DarkGray'
  }
  Write-Host ''
  Write-Info "查询于 $(([datetime]$b.checkedAt).ToString('HH:mm:ss'))，缓存 5 分钟；-Refresh 强制刷新"
}

function Invoke-Url([string[]]$Names) {
  <# The current browser URL for one or more instances, re-probed now.

     Exists because a cached URL goes stale: a remote service restart reissues its
     one-time token, so a link the panel holds can point at a 401 page. This
     answers "what should I open right now" without the caller reconstructing log
     paths or reading the launcher's own state files. #>
  $insts = @(Get-Instances $Names $Config)
  if ($insts.Count -eq 0) { Write-Err 'no instances selected'; return }
  $rows = @(Get-AllStatus -NoProbeHttp -Names @($insts | ForEach-Object { $_.name }))
  if ($Json) {
    if ($rows.Count -eq 1) { Write-Json $rows[0] } else { Write-Json $rows }
    return
  }
  foreach ($r in $rows) {
    if ($r.Url) { Write-C ("  {0,-16} {1}" -f $r.Name, $r.Url) 'DarkCyan' }
    else {
      Write-Warn2 ("{0,-16} 没有可用地址（{1}）" -f $r.Name, $r.State)
      if ($r.PSObject.Properties['Hint'] -and $r.Hint) { Write-Info "  $($r.Hint)" }
    }
  }
}

function Get-RemoteProbeScript($Inst) {
  $rport = [int](Get-InstProp $Inst 'remotePort' 3080)
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

function Get-RemoteProbeOutputs([object[]]$Insts) {
  <# Run one ssh probe per remote host with all of them in flight at once.

     The probes are independent, and each one costs about as long as its ssh
     handshake (~0.8 s here): probing four hosts in a row spent ~3.7 s of every
     status refresh waiting on handshakes that could overlap. Runspaces keep the
     probes inside this process -- an extra PowerShell per host would cost more
     than the wait it removes -- and a host that cannot be reached still answers
     with its ssh error text, which the caller already turns into an
     "unreachable" row. Output is keyed by instance name. #>
  $results = @{}
  $list = @($Insts)
  if ($list.Count -eq 0) { return $results }
  $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Min(8, $list.Count))
  $jobs = @()
  try {
    $pool.Open()
    foreach ($i in $list) {
      $payload = Get-B64Payload (Get-RemoteProbeScript $i)
      $shell = [PowerShell]::Create()
      $shell.RunspacePool = $pool
      # The script block must stand alone: it runs in a fresh runspace and
      # cannot see this file's functions. Same ssh contract as Invoke-B64.
      $null = $shell.AddScript({
        param($sshHost, $b64)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = & ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $sshHost "echo $b64 | base64 -d | bash" 2>&1 }
        finally { $ErrorActionPreference = $prev }
        ($out | Out-String)
      }).AddArgument($i.sshHost).AddArgument($payload)
      $jobs += [pscustomobject]@{ Name = [string]$i.name; Shell = $shell; Handle = $shell.BeginInvoke() }
    }
    foreach ($j in $jobs) {
      $text = ''
      try { $text = [string](@($j.Shell.EndInvoke($j.Handle)) -join '') } catch { $text = '' }
      $results[$j.Name] = $text
    }
  } finally {
    foreach ($j in $jobs) { try { $j.Shell.Dispose() } catch { } }
    try { $pool.Close() } catch { }
    try { $pool.Dispose() } catch { }
  }
  return $results
}

function Get-RemoteStatus($Inst, [string]$ProbeOutput) {
  $sshHost = $Inst.sshHost
  <# One ssh session, not two. The probe script's first line is SSH_USER, so a
     host that answered is proven reachable by the probe itself; the separate
     Test-SshReachable round trip only added ~1.4 s to every refresh.

     A caller that already ran the probes together passes the output in, so the
     status loop can keep one ssh handshake per host without running them one
     after another. #>
  if ($PSBoundParameters.ContainsKey('ProbeOutput')) { $out = $ProbeOutput }
  else { $out = Invoke-B64 (Get-RemoteProbeScript $Inst) $sshHost }
  $f = @{}
  foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^([A-Z_]+)=(.*)$') { $f[$Matches[1]] = $Matches[2] }
  }
  if (-not $f.ContainsKey('SSH_USER')) {
    # Explain the failure using the ssh error the probe already produced, rather
    # than a second probe or a generic "unreachable". "Needs a VPN" and "your key
    # was rejected" require completely different actions from the reader.
    $cls = Get-SshFailureClass $out
    return [pscustomobject]@{
      Name = $Inst.name; Kind = 'remote'; Port = [int](Get-InstProp $Inst 'localPort' 3099)
      State = 'unreachable'
      Detail = "连不上 $sshHost · $($cls.Hint)"
      FailCode = $cls.Code
      Hint = $cls.Hint
      Http = 0; Url = ''
      SshHost = $sshHost; DshInstalled = $false; SshReady = $false
    }
  }

  # Tunnel state, from our own records. The live port comes from state, because
  # a tunnel that had to fall back from a busy port recorded the port it used.
  $tunPid = Get-RecordedPid $Inst.name 'tunnel'
  $lp = [int](Get-InstProp $Inst 'localPort' 3099)
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
  $rp = [int](Get-InstProp $Inst 'remotePort' 3080)
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

  # Update availability comes from the cached registry lookup, so this adds no
  # network call to a status refresh. It is reported as a flag only: upgrading
  # restarts dsh and would drop a session in flight, so the decision stays with
  # the person rather than becoming a side effect of opening the panel.
  $latestVersion = Get-LatestDshVersion
  $updateAvailable = $false
  if ($dshVersion -and $dshVersion -ne 'none' -and $latestVersion) {
    $updateAvailable = (Compare-Version $latestVersion $dshVersion) -gt 0
  }

  $remoteUrl = "$(if ($f.ContainsKey('URL')) { $f['URL'] })".Trim()
  $url = ''
  if ($state -eq 'up') {
    if ($remoteUrl -match '^https?://') {
      $url = $remoteUrl -replace "127\.0\.0\.1:$([int](Get-InstProp $Inst 'remotePort' 3080))", "127.0.0.1:$lp"
    } else {
      $url = "http://127.0.0.1:$lp"
    }
  }

  return [pscustomobject]@{
    Name = $Inst.name; Kind = 'remote'; Port = $lp
    State = $state; Detail = $detail; Http = 0; Url = $url
    SshHost = $sshHost; TunnelPid = $tunPid
    RemoteUrl = $remoteUrl; RemotePort = [int](Get-InstProp $Inst 'remotePort' 3080)
    DshInstalled = ($dshPath -ne 'none' -and $dshPath -ne '')
    DshVersion = $dshVersion
    LatestVersion = $latestVersion
    UpdateAvailable = $updateAvailable
    VersionDrift = $drift
    SshReady = $true
    Linger = "$(if ($f.ContainsKey('LINGER')) { $f['LINGER'] })".Trim()
    NodeV  = "$(if ($f.ContainsKey('NODE_V')) { $f['NODE_V'] })".Trim()
  }
}

function Get-SshFailureClass([string]$SshOutput) {
  <# Classify an ssh failure from output we ALREADY have.

     Split out from Get-RemoteDiagnosis so status can explain an unreachable host
     without paying for another ssh attempt. The advice is identical either way --
     what matters to the reader is "needs a VPN" versus "your key was rejected"
     versus "wrong hostname", and all three are visible in the error text. #>
  $t = ([string]$SshOutput).ToLowerInvariant()
  if ($t -match 'could not resolve hostname') {
    return [pscustomobject]@{ Code = 'dns'; Hint = '主机名无法解析：检查 ssh config 里的 HostName，或 DNS' }
  }
  if ($t -match 'connection refused') {
    return [pscustomobject]@{ Code = 'refused'; Hint = '端口拒绝连接：sshd 没在监听，或端口写错了' }
  }
  if ($t -match 'permission denied|no supported authentication') {
    return [pscustomobject]@{ Code = 'auth'; Hint = '认证失败：密钥没配好，或 ssh-agent 里没有对应私钥' }
  }
  if ($t -match 'host key verification failed') {
    return [pscustomobject]@{ Code = 'hostkey'; Hint = '主机指纹变了：先手动 ssh 一次确认' }
  }
  if ($t -match 'timed out|timeout|unreachable|no route|connection closed') {
    return [pscustomobject]@{ Code = 'timeout'; Hint = '网络不通：大概率需要连 VPN，或安全组没放行' }
  }
  $last = (([string]$SshOutput) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
  return [pscustomobject]@{ Code = 'unknown'; Hint = ([string]$last).Trim() }
}

function Get-RemoteDiagnosis([string]$SshHostName, [int]$Port = 0) {
  <# Classify an unreachable host, actively probing.
     Used where no ssh output exists yet; status prefers Get-SshFailureClass so a
     refresh does not double its ssh handshakes. #>
  $args = @('-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
  if ($Port -gt 0) { $args += @('-p', "$Port") }
  $out = (& ssh @args $SshHostName "echo DIAG_OK" 2>&1 | Out-String).Trim()
  if ($out -match 'DIAG_OK') {
    return [pscustomobject]@{ Code = 'ok'; Hint = '' }
  }
  return Get-SshFailureClass $out
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
  $rport = [int](Get-InstProp $Inst 'remotePort' 3080)

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
  $lp = [int](Get-InstProp $Inst 'localPort' 3099)
  $rp = [int](Get-InstProp $Inst 'remotePort' 3080)

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
    if (-not $Quiet) { Write-Warn2 "local port $(Get-InstProp $Inst 'localPort' 3099) in use; tunnel using $lp instead" }
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
  $rp = [int](Get-InstProp $Inst 'remotePort' 3080)

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
    $autoOk = Test-InstFlag $Inst 'autoInstall' $true
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

function Get-AllStatus([switch]$NoProbeHttp, [string[]]$Names) {
  <# -Names limits the refresh to the instances a mutation just touched.

     The panel asks "what is the state of the thing I restarted", and answering
     that for every configured instance meant paying an ssh probe per remote host
     on every start/stop/restart: ~3.7 s of the ~13 s a local restart used to
     take. The full panel refresh still calls this with no -Names. #>
  $insts = @(Get-HostsConfig $Config).instances
  if ($Names -and @($Names).Count -gt 0) {
    # Profile-expanded entries carry the connection fields; disabled entries are
    # kept so a mutation against one still reports its own row.
    $wanted = @{}
    foreach ($n in @($Names)) { $wanted[[string]$n] = $true }
    $enabled = @(Get-Instances $Names $Config)
    $off = @($insts | Where-Object { $wanted.ContainsKey([string]$_.name) -and (Get-ConfigProp $_ 'enabled') -eq $false })
    $insts = @($enabled) + @($off)
  }
  $rows = @()
  # Remote probes are independent and each costs an ssh handshake, so run the set
  # together and hand every row its own output. A single remote keeps the plain
  # path: one probe has nothing to overlap with.
  $probeOutputs = @{}
  $remotes = @($insts | Where-Object { (Get-InstProp $_ 'kind' 'local') -eq 'remote' -and (Test-InstFlag $_ 'enabled' $true) })
  if ($remotes.Count -gt 1) { $probeOutputs = Get-RemoteProbeOutputs $remotes }
  foreach ($i in $insts) {
    if (-not (Test-InstFlag $i 'enabled' $true)) {
      $rows += [pscustomobject]@{
        Name = $i.name; Kind = $i.kind; Port = 0
        State = 'disabled'; Detail = 'disabled in hosts.json'; Http = 0; Url = ''
      }
      continue
    }
    # One unreadable instance must not blank the whole panel: an exception here
    # used to kill the entire status command, which the desktop app reported as
    # "无法读取实例状态" for every instance, including the healthy ones. Turn it
    # into a row for this instance alone and keep collecting the rest.
    try {
      if ((Get-InstProp $i 'kind' 'local') -eq 'remote') {
        $key = [string]$i.name
        if ($probeOutputs.ContainsKey($key)) { $rows += Get-RemoteStatus $i -ProbeOutput $probeOutputs[$key] }
        else { $rows += Get-RemoteStatus $i }
      }
      else { $rows += Get-LocalStatus $i -NoProbeHttp:$NoProbeHttp }
    } catch {
      $portValue = 0
      $configured = Get-InstProp $i 'port' 0
      if (-not $configured) { $configured = Get-InstProp $i 'localPort' 0 }
      if ($configured) { $portValue = [int]$configured }
      $rows += [pscustomobject]@{
        Name = $i.name
        Kind = (Get-InstProp $i 'kind' 'local')
        Port = $portValue
        State = 'unreachable'
        Detail = "状态查询失败：$($_.Exception.Message)"
        Http = 0; Url = ''
      }
    }
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
  $insts = @(Get-Instances $Names $Config)
  if ($insts.Count -eq 0) { Write-Warn2 'no instances selected'; return }
  $urls = @()
  foreach ($i in $insts) {
    if (-not (Test-InstFlag $i 'enabled' $true)) { Write-Info "$($i.name) is disabled; skipping"; continue }
    Write-Head "start $($i.name)"
    if ((Get-InstProp $i 'kind' 'local') -eq 'remote') {
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
  $insts = @(Get-Instances $Names $Config)
  foreach ($i in $insts) {
    Write-Head "stop $($i.name)"
    if ((Get-InstProp $i 'kind' 'local') -eq 'remote') { Stop-RemoteInstance $i } else { Stop-LocalInstance $i | Out-Null }
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

function Invoke-Logs([string[]]$Names, [int]$Tail, [switch]$Follow) {
  <# -Follow streams instead of printing once. The switch existed from the first
     release but nothing ever read it, so `logs -Follow` printed the last N lines
     and exited - a flag that lies in Get-Help's syntax line is worse than a
     missing one. Get-Content -Wait blocks until interrupted, which is the
     behaviour a tail needs; the remote path delegates to journalctl -f. #>
  $insts = @(if ($Names -and @($Names).Count -gt 0) { Get-Instances $Names $Config } else { Get-Instances $null $Config })
  if ($Follow -and @($insts).Count -gt 1) {
    # Interleaving several live streams into one console is unreadable, and each
    # remote one holds an ssh session open. Make the caller choose.
    Write-Err '-Follow works on one instance at a time; narrow it with -Target'
    return
  }
  foreach ($i in $insts) {
    if ((Get-InstProp $i 'kind' 'local') -eq 'remote') {
      Write-Head "logs $($i.name) (remote systemd journal)"
      if ($Follow) {
        Write-Info 'streaming; press Ctrl-C to stop'
        # No pipe to `tail` here: a pipe would buffer and defeat the streaming.
        Invoke-B64 "journalctl --user -u dsh-web -n $Tail -f --no-pager 2>&1" $i.sshHost |
          ForEach-Object { Write-C $_ 'DarkGray' }
      } else {
        $r = Invoke-B64 "journalctl --user -u dsh-web -n $Tail --no-pager 2>&1 | tail -n $Tail" $i.sshHost
        Write-C ($r.TrimEnd()) 'DarkGray'
      }
    } else {
      $log = Join-Path $LogDir "$($i.name).server.log"
      Write-Head "logs $($i.name) ($log)"
      if (Test-Path $log) {
        if ($Follow) {
          Write-Info 'streaming; press Ctrl-C to stop'
          Get-Content $log -Tail $Tail -Wait | ForEach-Object { Write-C "  $_" 'DarkGray' }
        } else {
          Get-Content $log -Tail $Tail | ForEach-Object { Write-C "  $_" 'DarkGray' }
        }
      } else { Write-Info 'no log yet' }
    }
  }
}

function Invoke-Add([switch]$Quiet) {
  <# Returns $true when an instance was actually written to the config.

     Each bail-out used to `return` bare, which under -Json still answered with
     the unchanged list and exit 0, so a caller could not tell "added" from
     "usage error" or "already exists". The backend surfaces this as r.ok, and
     the panel's add form reads it. #>
  if (-not $SshHost) {
    Write-Err 'usage: dsh.ps1 add -SshHost <ssh-alias-or-user@host> [-Name x] [-Port 3080]'
    return $false
  }
  $cfg = Get-HostsConfig $Config
  $n = if ($Name) { $Name } else { $SshHost }
  if (@($cfg.instances) | Where-Object { $_.name -eq $n }) {
    Write-Err "instance '$n' already exists"
    return $false
  }
  $free = Find-FreePort 3099
  $rp = if ($Port) { $Port } else { 3080 }
  $new = [pscustomobject]@{
    name = $n; kind = 'remote'; enabled = $true; sshHost = $SshHost
    remotePort = $rp; localPort = $free; description = "dsh web on $SshHost"
  }
  $cfg.instances = @($cfg.instances) + $new
  Save-HostsConfig $cfg -ConfigPath $Config
  if (-not $Quiet) {
    Write-Ok "added '$n' (tunnel 127.0.0.1:$free -> $SshHost`:127.0.0.1:$rp)"
    Write-Info "next: dsh.ps1 install $n"
  }
  return $true
}

function Invoke-List {
  $insts = @(Get-HostsConfig $Config).instances
  $fmt = "{0,-18} {1,-8} {2,-7} {3,-26} {4}"
  Write-Host ''
  Write-C ($fmt -f 'INSTANCE', 'KIND', 'ENABLED', 'SSH HOST', 'DESCRIPTION') 'Cyan'
  Write-C ('  ' + ('-' * 92)) 'DarkGray'
  foreach ($i in $insts) {
    $sh = if ((Get-InstProp $i 'kind' 'local') -eq 'remote') { $i.sshHost } else { '(this machine)' }
    Write-C ($fmt -f $i.name, (Get-InstProp $i 'kind' 'local'), (Test-InstFlag $i 'enabled' $true), $sh, $i.description) 'Gray'
  }
  Write-Host ''
  Write-Info "config file: $(Resolve-ConfigPath $Config)"
  Write-Host ''
}

function Invoke-Install([string[]]$Names, [switch]$Quiet) {
  <# Returns $true only when every requested instance was installed.

     The -Json caller used to answer {"ok":true} unconditionally, so a run that
     printed "[fail] no remote instances selected" and did nothing still told
     the panel the deploy had succeeded. The verdict has to come from here,
     because only this function knows whether any work happened. #>
  $insts = @(Get-Instances $Names $Config) | Where-Object { $_.kind -eq 'remote' }
  if (-not $insts -or @($insts).Count -eq 0) { Write-Err 'no remote instances selected'; return $false }
  $allOk = $true
  foreach ($i in $insts) {
    if (-not $Quiet) { Write-Head "install $($i.name) -> $($i.sshHost)" }
    # Install-RemoteService reports failure by returning a falsy value rather
    # than throwing, so it has to be inspected instead of discarded.
    $res = Install-RemoteService $i -Quiet:$Quiet
    if (-not $res) { $allOk = $false }
  }
  return $allOk
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

function Test-ProcessAlive([int]$ProcId) {
  <# Is this pid a live process right now?

     Asked through the process table rather than Get-Process because the answer
     is used as a VERDICT - "did the backend actually die?" - and a verdict may
     not depend on whether the name lookup happens to succeed. See
     Stop-App for the bug that made this necessary.

     Defaults to "still alive" when the query itself cannot answer. The safe
     direction is to leave the runtime file alone and say so, because forgetting
     a live backend leaves a process holding the panel's port: the next launch
     cannot adopt it (the state file is gone) and silently starts a second one. #>
  if ($ProcId -le 0) { return $false }
  try {
    return [bool](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop)
  } catch {
    return $true
  }
}

function Stop-App {
  <# Stop the app backend, and optionally the browser window that points at it.
     The window is identified by its command line containing our app URL, so we
     never kill an unrelated browser the user has open.

     The bug this function now guards against, reproduced 6 times in 8 runs:
     `taskkill /T` can kill the parent and still print
     "ERROR: The process with PID n (child process of PID m) could not be
     terminated." on stderr. Because $ErrorActionPreference is 'Stop' at the top
     of this file, that stderr line is a TERMINATING error (the same rule
     Invoke-B64 and Get-NetstatListeners already document), so the assignment
     below it never ran, the surrounding catch swallowed the exception, and a
     backend that had in fact been killed was reported as "app backend was not
     running". The runtime file was deleted anyway, so the next launch could not
     adopt anything and simply started a second backend on a new port.

     So the verdict comes from the PROCESS TABLE, not from taskkill's exit code
     and not from its stderr: a kill is a success exactly when the pid is gone
     afterwards, which is true both for a clean kill and for that half-failure,
     and false when the process really did survive ("Access is denied"). #>
  $runtimeFile = Join-Path $StateDir 'app.json'
  $stopped = $false
  $survivorPid = 0
  if (Test-Path $runtimeFile) {
    # Only the read is guarded here. An earlier version wrapped the kill in the
    # same try, so any failure while killing was reported as "could not read
    # <runtime file>" - a message that names the wrong thing and sends the
    # reader looking at a file that is perfectly fine.
    $rt = $null
    try {
      $rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
      Write-Diag "  [warn] could not read $runtimeFile : $($_.Exception.Message)" 'Yellow'
    }

    $targetPid = 0
    if ($rt -and $rt.pid) { $targetPid = [int]$rt.pid }
    $p = $null
    if ($targetPid -gt 0) { $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue }
    if ($p -and $p.ProcessName -eq 'node') {
      # Continue, not Stop, for the duration of the call: that keeps taskkill's
      # stderr ordinary text so its output can be shown when a kill does not
      # take, instead of becoming the terminating error this whole function
      # exists to survive.
      $prevEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      $killOut = ''
      try { $killOut = & taskkill.exe /PID $targetPid /T /F 2>&1 | Out-String }
      catch { $killOut = $_.Exception.Message }
      finally { $ErrorActionPreference = $prevEap }

      # Both sides of the tree are being torn down asynchronously, so wait for
      # the pid to leave the process table instead of reading the table once and
      # reporting whatever it said at that instant.
      $deadline = (Get-Date).AddSeconds(5)
      while ((Get-Date) -lt $deadline -and (Test-ProcessAlive $targetPid)) {
        Start-Sleep -Milliseconds 200
      }
      if (Test-ProcessAlive $targetPid) {
        $survivorPid = $targetPid
        Write-Err "app backend did not stop (pid $targetPid is still running)"
        foreach ($line in ($killOut.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3)) {
          Write-C "    $($line.Trim())" 'DarkGray'
        }
        Write-Info "stop it by hand with: taskkill /PID $targetPid /T /F"
      } else {
        Write-Ok "app backend stopped (pid $targetPid)"
        $stopped = $true
      }
    }

    # Deleting the runtime file is what makes the backend unreachable for the
    # next launch, so it only goes once the process is known to be gone. While
    # it survives, the file stays and keeps the survivor adoptable.
    if (-not (Test-ProcessAlive $survivorPid)) {
      Remove-Item $runtimeFile -Force -ErrorAction SilentlyContinue
    }
  }
  if (-not $stopped -and $survivorPid -eq 0) { Write-Info 'app backend was not running' }

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

  # A stop that did not stop anything must not answer like one that did: the
  # caller scripts `app -Stop` and needs a non-zero exit to notice. Returned
  # rather than exited here so the dispatcher stays the only place that exits.
  return ($survivorPid -eq 0)
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

function Invoke-Doctor([string]$SshConfigOverride) {
  Write-Head 'this machine'
  Write-Info "powershell : $($PSVersionTable.PSVersion)"
  $node = Get-NodeExe
  if ($node) { Write-Ok "node       : $node ($(& $node -v 2>&1))" } else { Write-Err 'node       : NOT FOUND' }
  $bin = Find-DshLocal
  if ($bin) { Write-Ok "dsh        : $bin" } else { Write-Err 'dsh        : NOT FOUND (npm i -g @deepseek-ai/dsh)' }
  Write-Info "DSH_HOME   : $DshHome"
  Write-Info "launcher   : $LauncherDir"
  $sshCfg = Get-SshConfigPath $SshConfigOverride
  if (Test-Path $sshCfg) { Write-Ok "ssh config : $sshCfg" } else { Write-Warn2 "ssh config : not found at $sshCfg" }

  Write-Head 'configured instances'
  $rows = Get-AllStatus
  Write-StatusTable $rows

  Write-Head 'ssh config hosts not yet configured here'
  $sshCfg = Get-SshConfigPath $SshConfigOverride
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
    # -InputObject, not the pipeline: the pipeline unrolls a one-element array, so
    # `list -Json` with a single instance emitted `{...}` instead of `[{...}]` and
    # every consumer that maps over the result (the panel's cfg.map) threw
    # "cfg.map is not a function". -InputObject passes the array through intact.
    ConvertTo-Json -InputObject $Obj -Depth 8 -Compress | Write-Output
  } catch {
    try { Write-Log "Write-Json failed (stdout closed?): $($_.Exception.Message)" } catch { }
  }
}

try {
  switch ($Command) {
    'menu'    { Invoke-Menu }
    'app'     { if ($PSBoundParameters.ContainsKey('Stop') -and [bool]$Stop) {
                  # The verdict has to reach the exit code: a stop that left the
                  # backend alive is a failure, and reporting it as success is
                  # how a surviving backend ends up shadowing the next launch.
                  if (-not (Stop-App)) { exit 1 }
                } else { Invoke-App } }
    # `tray` starts or toggles, `tray-start` is the explicit form for scripted
    # callers, and `tray-stop` exists because a trailing -Stop switch would be
    # collected into the positional target list instead of reaching this switch.
    'tray'       { Invoke-Tray -Stop:($PSBoundParameters.ContainsKey('Stop') -and [bool]$Stop) }
    'tray-start' { Invoke-Tray }
    'tray-stop'  { Invoke-Tray -Stop }
    # Internal: the detached process that owns the tray's message loop.
    'tray-loop'  { Start-TrayLoop -IntervalSeconds $TrayInterval }
    # -Target narrows the report to the named instances. Without it a `status`
    # probes every remote host, which costs one ssh round trip each; asking about
    # one host should not pay for the other five.
    #
    # -NoProbe reaches Get-AllStatus as -NoProbeHttp. It used to be declared and
    # documented but never forwarded, so `status -NoProbe` still probed and cost
    # the same as a full status - which two in-repo callers relied on being
    # cheap (the panel's fast path and tools/check-panel.ps1). -Probe is
    # deliberately absent: probing is already the default, so the flag has
    # nothing to switch on.
    'status'  { $rows = @(Get-AllStatus -NoProbeHttp:$NoProbe -Names $Target)
                if ($Json) { Write-Json $rows } else { Write-StatusTable $rows } }
    # A mutation answers for the instances it acted on, not for the whole farm:
    # the panel reads the row it asked about, and refreshing every remote host
    # here used to add one ssh probe each to every start/stop/restart.
    'start'   { if ($Json) { Invoke-Start $Target -Quiet; Write-Json @(Get-AllStatus -NoProbeHttp -Names $Target) }
                else { Invoke-Start $Target } }
    'stop'    { if ($Json) { Invoke-Stop $Target; Write-Json @(Get-AllStatus -NoProbeHttp -Names $Target) }
                else { Invoke-Stop $Target } }
    'restart' { if ($Json) { Invoke-Stop $Target; Start-Sleep -Milliseconds 500; Invoke-Start $Target -Quiet; Write-Json @(Get-AllStatus -NoProbeHttp -Names $Target) }
                else { Invoke-Stop $Target; Start-Sleep -Milliseconds 500; Invoke-Start $Target } }
    'open'    { Invoke-Open $Target }
    'logs'    { Invoke-Logs $Target $Lines -Follow:([bool]$Follow) }
    # The list is returned either way, but a failed add now exits non-zero so
    # the caller can tell it apart from a successful one. The response shape is
    # deliberately unchanged: the panel's add form reads the list.
    'add'     { if ($Json) {
                  $ok = [bool](Invoke-Add -Quiet)
                  Write-Json @((Get-HostsConfig $Config).instances)
                  if (-not $ok) { exit 1 }
                } else { [void](Invoke-Add) } }
    'list'    { $insts = @((Get-HostsConfig $Config).instances)
                if ($Json) { Write-Json $insts } else { Invoke-List } }
    # ok reflects what actually happened, not that the command was invoked: a
    # failed or empty deploy used to answer {"ok":true} with exit 0. The
    # non-Json path discards the verdict because it already printed the detail.
    'install' { if ($Json) {
                  $ok = [bool](Invoke-Install $Target -Quiet)
                  Write-Json @{ ok = $ok }
                  if (-not $ok) { exit 1 }
                } else { [void](Invoke-Install $Target) } }
    'check'   { Invoke-Check }
    'upgrade' { Invoke-Upgrade $Target -DryRun:([bool]$DryRun) }
    'balance' { Invoke-Balance -Refresh:([bool]$Refresh) }
    'url'     { Invoke-Url $Target }
    'doctor'  { Invoke-Doctor -SshConfigOverride $SshConfigPath }
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
