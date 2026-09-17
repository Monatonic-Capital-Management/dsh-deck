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
  add      register an instance; -DisplayName sets its human-readable label
  edit     update one instance using -Patch JSON (whitelisted fields only)
  remove   unregister a stopped instance; never uninstall or delete user data
  plan     read-only preview with -Action start|install|upgrade
  ssh-hosts
           discover SSH aliases using the same configuration as connections
  list     list normalized, profile-expanded instances
  install  deploy the remote systemd service to a host, or install dsh on this
           machine (local instances; never automatic - see the .NOTES below)
  upgrade  align with dshVersion or the shared latest target (-DryRun to preview)
  check    report which instances have an update available
  balance  show the DeepSeek account balance
  url      print an instance's current authenticated URL
  doctor   diagnose the environment and every configured host
  node-path
           which node runs the panel and dsh, and whether this tool installed it
           (-Ensure downloads a suitable Node when none usable is found)
  tray  tray-start  tray-stop
           notification-area icon; alerts when an instance changes state
  tray-loop  internal: the detached process that owns the tray's message loop
             (there is no `help` verb - an invalid Command lists every valid one)

.PARAMETER Target
  One or more instance names (or "local"). Defaults to every enabled instance.
  Accepts a comma-separated list as well as separate arguments.

.EXAMPLE
  .\dsh.ps1 -Command app                         # panel only; no automatic install
.EXAMPLE
  .\dsh.ps1 -Command status -Target local -NoProbe # skip local HTTP, not remote SSH
.EXAMPLE
  .\dsh.ps1 -Command plan -Action start -Target prod -Json
.EXAMPLE
  .\dsh.ps1 -Command install -Target prod        # prepare software/service, do not start
.EXAMPLE
  .\dsh.ps1 -Command start -Target local -NoOpen
.EXAMPLE
  .\dsh.ps1 -Command logs -Target local -Follow  # sanitized stream until Ctrl-C
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('menu','app','tray','tray-start','tray-stop','tray-loop','status','start','stop','restart','open','logs','add','edit','remove','list','install','plan','ssh-hosts','check','upgrade','balance','url','doctor','node-path')]
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
  [string]$DisplayName,
  [string]$Action,
  [string]$Patch,
  [int]$Port,

  [switch]$Json,        # emit machine-readable JSON (used by the desktop app)
  [switch]$NoProbe,     # status: skip local HTTP only; remote SSH still probes health
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

  [string]$SshConfigPath,  # shared SSH config for discovery, commands and tunnels

  [int]$TrayInterval = 20, # seconds between tray state polls

  # node-path: download a suitable Node when none usable is found. Without it the
  # verb only reports, so asking "which node am I using?" never installs anything.
  [switch]$Ensure,

  # node-path -Ensure: download even when a runtime is already present, which is the
  # only way to replace one that reports a version and then fails at real work.
  [switch]$Force,

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

# Initialize paths without reading configuration or creating runtime files.
$HomeDir      = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $LauncherDir }
$StateDir     = Join-Path $LauncherDir 'state'
$LogDir       = Join-Path $LauncherDir 'logs'
$RemoteScript = Join-Path $LauncherDir 'remote\dsh-web-service.sh'
$RemotePath   = '.local/bin/dsh-web-service.sh'
$RemoteUnit   = '.config/systemd/user/dsh-web.service'
$DshHome      = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HomeDir '.dsh' }

# Direct module imports only declare functions. Commands create state lazily.
$script:LocalDshVersion = ''
$script:ManagedNodeVersion = 'v22.23.2'
$script:NodeMinVersion = '22.19.0'
$script:ExitCode = 0
$script:LastFailure = ''
$script:SshConfigWasExplicit = [bool]($SshConfigPath -or $env:DSH_SSH_CONFIG)

$script:UseColor = $true
try { if ([Console]::IsOutputRedirected) { $script:UseColor = $false } } catch { }

foreach ($module in @('Core','Config','Runtime','Ssh','Local','Remote','Commands','Desktop')) {
  . (Join-Path $LauncherDir "launcher\$module.ps1")
}
$Config = Resolve-ConfigPath $Config
$SshConfigPath = Get-SshConfigPath $SshConfigPath
$script:ConfigContext = Get-ContextKey ($Config + '|' + $SshConfigPath)

# Dispatch owns serialization and process exit status.
try {
  if ($Command -in @('start','stop','restart','install','upgrade','add','edit','remove')) {
    $result = Invoke-Mutation $Command $Target -Quiet:$Json -DryRun:($DryRun -and $Command -eq 'upgrade')
    if ($Json) { Write-Json $result } else { Write-StatusTable $result.rows }
    if (-not $result.ok) { $script:ExitCode = 1 }
  } else {
    switch ($Command) {
      'menu' { Invoke-Menu }
      'app' {
        $guard = Enter-LauncherLock ('launcher:' + $LauncherDir)
        try { $ok = if ($Stop) { Stop-App } else { Invoke-App -Quiet:$Json } }
        finally { Exit-LauncherLock $guard }
        if ($Json) { Write-Json @{ ok = [bool]$ok; action = $(if ($Stop) { 'app-stop' } else { 'app' }); message = $(if ($ok) { '面板操作已完成。' } else { $script:LastFailure }) } }
        if (-not $ok) { $script:ExitCode = 1 }
      }
      'tray' { Invoke-Tray -Stop:$Stop }
      'tray-start' { Invoke-Tray }
      'tray-stop' { Invoke-Tray -Stop }
      'tray-loop' { Start-TrayLoop -IntervalSeconds $TrayInterval }
      'list' { if ($Json) { Write-Json @(Get-Instances $Target $Config -IncludeDisabled) } else { Invoke-List } }
      'status' { $rows = @(Get-AllStatus -NoProbeHttp:$NoProbe -Names $Target); if ($Json) { Write-Json $rows } else { Write-StatusTable $rows } }
      'plan' { $result = Invoke-Plan $Target $Action; if ($Json) { Write-Json $result } else { foreach ($item in $result.plans) { Write-C "$($item.name): $($item.summary)"; foreach ($step in $item.steps) { Write-C "  $step" } } }; if (-not $result.ok) { $script:ExitCode = 1 } }
      'ssh-hosts' { $result = Get-SshHosts; if ($Json) { Write-Json $result } else { foreach ($item in $result.hosts) { Write-C "$($item.name) configured=$($item.configured)" } } }
      'open' { Invoke-Open $Target }
      'logs' { Invoke-Logs $Target $Lines -Follow:$Follow }
      'check' { Invoke-Check }
      'balance' { Invoke-Balance -Refresh:$Refresh }
      'url' { Invoke-Url $Target }
      'doctor' { Invoke-Doctor -SshConfigOverride $SshConfigPath }
      'node-path' {
        $guard = $null
        try { if ($Ensure) { $guard = Enter-LauncherLock ('local-runtime:' + (Get-HomeDir)) }; Invoke-NodePath -Ensure:$Ensure -Force:$Force }
        finally { Exit-LauncherLock $guard }
      }
    }
  }
} catch {
  $script:ExitCode = 1
  $message = Protect-Text $_.Exception.Message
  Write-Err $message
  if ($Json) {
    if ($Command -eq 'plan') { Write-Json @{ ok = $false; plans = @(); errorCode = (Get-ErrorCode $_); message = $message; error = $message } }
    else { Write-Json @{ ok = $false; action = $Command; errorCode = (Get-ErrorCode $_); message = $message; error = $message } }
  }
}
exit $script:ExitCode
