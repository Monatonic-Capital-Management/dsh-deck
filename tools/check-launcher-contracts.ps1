# Offline module/CLI contracts. All mutable inputs and processes are test-owned.
[CmdletBinding()]
param([switch]$KeepTemp, [string]$LauncherPath, [switch]$HelpersOnly)

function Set-LauncherTestEnvironment($StartInfo, [string]$Root, [string]$Clone) {
  if ($StartInfo.RedirectStandardOutput) { $StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false) }
  if ($StartInfo.RedirectStandardError) { $StartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false) }
  $StartInfo.EnvironmentVariables.Clear()
  foreach ($key in @('SystemRoot','WINDIR','COMSPEC','PATHEXT','OS','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS')) {
    $value = [Environment]::GetEnvironmentVariable($key, 'Process')
    if ($value) { $StartInfo.EnvironmentVariables[$key] = $value }
  }
  foreach ($directory in @('home','appdata','localappdata','temp','programfiles','mirror')) {
    $path = Join-Path $Root $directory
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  }
  $StartInfo.EnvironmentVariables['PATH'] = "$env:WINDIR\System32;$env:WINDIR;$env:WINDIR\System32\WindowsPowerShell\v1.0"
  $StartInfo.EnvironmentVariables['USERPROFILE'] = Join-Path $Root 'home'
  $StartInfo.EnvironmentVariables['USERNAME'] = 'dsh-test'
  $StartInfo.EnvironmentVariables['USER'] = 'dsh-test'
  $StartInfo.EnvironmentVariables['APPDATA'] = Join-Path $Root 'appdata'
  $StartInfo.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Root 'localappdata'
  $StartInfo.EnvironmentVariables['TEMP'] = Join-Path $Root 'temp'
  $StartInfo.EnvironmentVariables['TMP'] = Join-Path $Root 'temp'
  $StartInfo.EnvironmentVariables['ProgramFiles'] = Join-Path $Root 'programfiles'
  $StartInfo.EnvironmentVariables['ProgramFiles(x86)'] = Join-Path $Root 'programfiles'
  $StartInfo.EnvironmentVariables['DSH_HOME'] = Join-Path $Root 'home\.dsh'
  $StartInfo.EnvironmentVariables['DSH_LAUNCHER_CONFIG'] = Join-Path $Root 'hosts.json'
  $StartInfo.EnvironmentVariables['DSH_SSH_CONFIG'] = Join-Path $Root 'ssh-config'
  $StartInfo.EnvironmentVariables['DSH_NODE_MIRROR'] = Join-Path $Root 'mirror'
  $StartInfo.EnvironmentVariables['NPM_CONFIG_USERCONFIG'] = Join-Path $Root 'npmrc'
  $StartInfo.EnvironmentVariables['NPM_CONFIG_GLOBALCONFIG'] = Join-Path $Root 'npmrc'
  foreach ($file in @('ssh-config','npmrc')) {
    $path = Join-Path $Root $file
    if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, '') }
  }
  $configFile = Join-Path $Root 'hosts.json'
  if (-not (Test-Path -LiteralPath $configFile)) { [IO.File]::WriteAllText($configFile, '{"version":1,"instances":[]}', (New-Object Text.UTF8Encoding($true))) }
}
function Copy-LauncherTestModules([string]$SourceLauncher, [string]$Clone) {
  $moduleDir = Join-Path (Split-Path -Parent $SourceLauncher) 'launcher'
  if (-not (Test-Path -LiteralPath $moduleDir)) { throw 'source launcher modules are missing' }
  Copy-Item -LiteralPath $moduleDir -Destination $Clone -Recurse -Force
}
function Get-LauncherTestSource([string]$SourceLauncher) {
  $parts = @((Get-Content -LiteralPath $SourceLauncher -Raw -Encoding UTF8))
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $SourceLauncher) 'launcher') -Filter '*.ps1' | Sort-Object Name)) { $parts += Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 }
  return $parts -join "`n"
}
function Join-LauncherTestArguments([string[]]$Values) {
  return (@($Values | ForEach-Object { '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"' }) -join ' ')
}
function Read-LauncherTestJson([string]$Text) {
  try { return ConvertFrom-Json -InputObject $Text.Trim() } catch { return $null }
}
if ($HelpersOnly) { return }
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$source = if ($LauncherPath) { (Resolve-Path -LiteralPath $LauncherPath).Path } else { Join-Path $repo 'dsh.ps1' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('dsh-contract-' + [guid]::NewGuid().ToString('N'))
$clone = Join-Path $scratch 'clone'
$script:passed = 0; $script:failed = 0
function Check([string]$Label, [bool]$Passed) {
  if ($Passed) { $script:passed++; Write-Host "PASS $Label" } else { $script:failed++; Write-Host "FAIL $Label" }
}
function Check-Throws([string]$Label, [scriptblock]$Body, [string]$Code) {
  try { $null = & $Body; Check $Label $false }
  catch { Check $Label ((Get-ErrorCode $_) -eq $Code) }
}
function Invoke-ContractCli([string[]]$Arguments) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $psi.Arguments = Join-LauncherTestArguments (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $clone 'dsh.ps1')) + $Arguments)
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $clone
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  Set-LauncherTestEnvironment $psi $scratch $clone
  $process = [Diagnostics.Process]::Start($psi)
  $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(45000)) { $process.Kill(); throw 'isolated CLI timed out' }
    $parsed = Read-LauncherTestJson $out.Result
    if (-not $parsed -and $Arguments -contains '-Json') {
      $ids = @([regex]::Matches($err.Result, 'FullyQualifiedErrorId\s*:\s*([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
      Write-Host ('CLI parse metadata: exit=' + $process.ExitCode + ' stdoutBytes=' + $out.Result.Length + ' errorIds=' + ($ids -join ','))
    }
    return [pscustomobject]@{ Code = $process.ExitCode; Json = $parsed; Out = $out.Result; Err = $err.Result }
  } finally { $process.Dispose() }
}
try {
  New-Item -ItemType Directory -Path $clone -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination (Join-Path $clone 'dsh.ps1')
  Copy-LauncherTestModules $source $clone
  Copy-Item -LiteralPath (Join-Path $repo 'remote') -Destination $clone -Recurse
  New-Item -ItemType Directory -Path (Join-Path $clone 'app') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $clone 'app\server.js'), '// inert test server')
  $envSetup = New-Object Diagnostics.ProcessStartInfo
  Set-LauncherTestEnvironment $envSetup $scratch $clone
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $clone 'launcher') -Filter '*.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Check ($file.Name + ' parses and has function-only top level') ($errors.Count -eq 0 -and @($ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0)
    . $file.FullName
  }
  $LauncherDir = $clone; $StateDir = Join-Path $clone 'state'; $LogDir = Join-Path $clone 'logs'; $RemoteScript = Join-Path $clone 'remote\dsh-web-service.sh'
  $Config = Join-Path $scratch 'hosts.json'; $SshConfigPath = Join-Path $scratch 'ssh-config'
  $NoOpen = $true; $Json = $true; $LocalPort = 0; $Patch = ''; $DisplayName = ''; $Name = ''; $SshHost = ''; $Port = 0; $AppWindow = $false
  $script:JsonMode = $true; $script:UseColor = $false; $script:ExitCode = 0; $script:LastFailure = ''; $script:LocalDshVersion = ''; $script:NodeMinVersion = '22.19.0'; $script:ManagedNodeVersion = 'v22.23.2'; $script:SshConfigWasExplicit = $true
  $script:ConfigContext = Get-ContextKey ($Config + '|' + $SshConfigPath)
  function Get-HomeDir { return Join-Path $scratch 'home' }
  Check 'import did not create state/logs' (-not (Test-Path -LiteralPath $StateDir) -and -not (Test-Path -LiteralPath $LogDir))
  $cfg = [pscustomobject]@{ version = 1; profiles = @([pscustomobject]@{ name = 'shared'; sshHost = 'alias'; sshUser = 'team'; remotePort = 41002; autoInstall = $true }); userProfiles = @{}; instances = @([pscustomobject]@{ name = 'local'; kind = 'local'; port = 41001; dshVersion = '1.2.3' }, [pscustomobject]@{ name = 'user@host'; profile = 'shared'; localPort = 41003; sshUser = 'instance'; enabled = $true; autoInstall = $false; displayName = '研发环境 中文 😀'; dshVersion = '1.2.3' }) }
  $username = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }
  $cfg.userProfiles[$username] = @{ shared = @{ sshUser = 'personal'; identityFile = (Join-Path $scratch 'key with spaces'); jumpHost = 'jump'; sshPort = 2202 } }
  Save-HostsConfig $cfg $Config
  $instances = @(Get-Instances $null $Config -IncludeDisabled)
  $remote = $instances[1]
  $int64Version = Get-NormalizedConfig ([pscustomobject]@{ version = [long]1; instances = @() })
  Check 'configuration version accepts JSON Int64 without accepting strings' ($int64Version.version -eq 1)
  Check-Throws 'string configuration version is refused' { Get-NormalizedConfig ([pscustomobject]@{ version = '1'; instances = @() }) } 'invalid-config'
  Check 'profiles normalize before default selection' ($remote.kind -eq 'remote' -and $remote.remotePort -eq 41002 -and $remote.sshUser -eq 'instance' -and -not $remote.autoInstall -and $remote.sshPort -eq 2202)
  Check 'displayName preserves normal Unicode' ($remote.displayName -eq '研发环境 中文 😀')
  $testCredential = [guid]::NewGuid().ToString('N')
  $protected = Protect-Text ('http://127.0.0.1:41001/#t=' + $testCredential + ' {"token":"' + $testCredential + '"} Bearer ' + $testCredential)
  Check 'diagnostic redaction covers fragments and JSON credentials' (-not $protected.Contains($testCredential))
  & {
    $script:latestRequests = 0; $script:DshLatestResolution = $null
    function Invoke-WebRequest { $script:latestRequests++; return [pscustomobject]@{ Content = '{"dist-tags":{"latest":"1.2.4"}}' } }
    $first = Get-LatestDshVersion -ReadOnly
    $second = Get-LatestDshVersion -ReadOnly
    Check 'read-only latest resolution is shared without cache-file writes' ($first -eq '1.2.4' -and $second -eq $first -and $script:latestRequests -eq 1 -and -not (Test-Path -LiteralPath $StateDir))
    $script:DshLatestResolution = $null
  }
  foreach ($bad in @('../escape','a/b','a\b','a"b','a;b','a`b','a..b','con','x.')) { Check-Throws 'unsafe instance name rejected' { Assert-InstanceName $bad } 'invalid-name' }
  $sameRemote = [pscustomobject]@{ version = 1; instances = @(
    [pscustomobject]@{ name = 'first'; kind = 'remote'; sshHost = 'fixture'; localPort = 42001 },
    [pscustomobject]@{ name = 'second'; kind = 'remote'; sshHost = 'fixture'; localPort = 42002 }
  ) }
  Check-Throws 'one remote user service cannot be registered twice' { Get-NormalizedConfig $sameRemote } 'invalid-config'
  $badBool = ConvertTo-ConfigMap $remote; $badBool['enabled'] = 'false'
  Check-Throws 'string booleans rejected' { Assert-ConfigFields $badBool } 'invalid-config'
  Check 'SemVer prerelease is below release' ((Compare-Version '1.2.3-rc.10' '1.2.3') -lt 0)
  Check 'SemVer numeric prerelease components compared numerically' ((Compare-Version '1.2.3-rc.10' '1.2.3-rc.2') -gt 0)
  $sshArgs = @(Get-SshArguments $remote -Purpose tunnel -LocalPort 41003 -RemotePort 41002)
  $roundtrip = @(Split-NativeArguments ('ssh.exe ' + (Join-NativeArguments $sshArgs)))
  Check 'SSH config/user/identity/jump/port override reaches arguments' ($sshArgs -contains $SshConfigPath -and $sshArgs -contains 'instance' -and $sshArgs -contains $remote.identityFile -and $sshArgs -contains 'jump' -and $sshArgs -contains '2202')
  Check 'SSH argument quoting survives spaced paths' ($roundtrip.Count -eq $sshArgs.Count + 1 -and $roundtrip[1 + [Array]::IndexOf($sshArgs, $remote.identityFile)] -eq $remote.identityFile)
  [IO.File]::WriteAllText($SshConfigPath, "Host alias extra # ignored-comment`nHost wildcard* !negated`n")
  $hosts = Get-SshHosts
  Check 'SSH discovery ignores wildcard, negated and comment tokens' ($hosts.hosts.Count -eq 2 -and @($hosts.hosts | Where-Object { $_.name -eq 'alias' -and $_.configured }).Count -eq 1)
  & {
    function Get-LocalDshVersion { return '1.2.2' }
    function Get-NodeExe { return 'synthetic-node' }
    function Get-NodeVersionOf { return 'v22.23.2' }
    function Test-NodeUsable { param($NodeExe, [switch]$ReadOnly); return $true }
    function Get-State { return $null }
    function Get-RecordedPid { return 0 }
    function Get-ListeningPid { return 0 }
    function Assert-LocalRuntimeStopped { }
    function Get-LatestDshVersion { throw 'pin resolution must not query latest' }
    function Ensure-ManagedNode { throw 'plan changed software' }
    function Install-RemoteDsh { throw 'plan installed dsh' }
    $before = (Get-FileHash -LiteralPath $Config).Hash
    $plan = Get-InstancePlan $instances[0] 'upgrade'
    Check 'upgrade plan honors pin without software/service writes' ($plan.ok -and $plan.targetVersion -eq '1.2.3' -and $plan.changesSoftware -and -not $plan.restartsService -and (Get-FileHash -LiteralPath $Config).Hash -eq $before -and -not (Test-Path -LiteralPath $StateDir))
    $plan = Get-InstancePlan $instances[0] 'install'
    Check 'install plan does not replace usable dsh' ($plan.ok -and -not $plan.changesDsh -and -not $plan.startsService)
    function Get-RemoteFacts { return @{ DSH_V = '1.2.3'; NODE_V = 'v22.23.2'; NPM = 'npm'; SERVICE_PRESENT = 'yes'; SNAP_MAIN = '100'; SNAP_LISTEN = '101'; SNAP_STATE = 'active'; SNAP_LISTENING = 'yes'; SNAP_OWNED = 'yes'; SNAP_HTTP = '200' } }
    function Start-Tunnel { return 41003 }
    function Invoke-B64 { throw 'healthy start must not mutate remote service' }
    Check 'healthy remote child PID may differ from MainPID; repeat start is no-op' ((Start-RemoteInstance $remote -Quiet) -and (Start-RemoteInstance $remote -Quiet))
    function Get-RemoteFacts { return @{ DSH_V = '1.2.3'; NODE_V = 'v22.23.2'; NPM = 'npm'; SERVICE_PRESENT = 'no'; SNAP_STATE = 'inactive'; SNAP_LISTENING = 'no'; SNAP_OWNED = 'no'; SNAP_HTTP = '0' } }
    Check-Throws 'autoInstall false blocks missing service definition' { Start-RemoteInstance $remote -Quiet } 'auto-install-disabled'
    function Get-RemoteFacts { return @{ DSH_V = '1.2.3'; NODE_V = 'v22.23.2'; NPM = 'npm'; SERVICE_PRESENT = 'yes'; SNAP_STATE = 'active'; SNAP_LISTENING = 'yes'; SNAP_OWNED = 'no'; SNAP_HTTP = '200' } }
    Check-Throws 'unknown remote listener is not killed' { Start-RemoteInstance $remote -Quiet } 'remote-port-busy'
    $blockedPlan = Get-InstancePlan $remote 'start'
    Check 'blocked plan keeps specific errorCode and summary' (-not $blockedPlan.ok -and $blockedPlan.errorCode -eq 'remote-port-busy' -and [bool]$blockedPlan.summary)
    Check 'blocked plan uses strict booleans and arrays' ($blockedPlan.changesSoftware -is [bool] -and $blockedPlan.restartsService -is [bool] -and $blockedPlan.requiresConfirmation -is [bool] -and $blockedPlan.steps -is [array] -and $blockedPlan.warnings -is [array])
    function Get-RemoteFacts { Throw-LauncherError 'unreachable-fixture' 'synthetic offline probe detail' }
    $failedPlan = (Invoke-Plan @($remote.name) 'start').plans[0]
    Check 'probe error plan preserves its concrete failure' (-not $failedPlan.ok -and $failedPlan.errorCode -eq 'unreachable-fixture' -and $failedPlan.summary -eq 'synthetic offline probe detail')
    Check 'probe error plan uses strict booleans and arrays' ($failedPlan.changesSoftware -is [bool] -and $failedPlan.restartsService -is [bool] -and $failedPlan.requiresConfirmation -is [bool] -and $failedPlan.steps -is [array] -and $failedPlan.warnings -is [array])
  }
  & {
    function Start-SshInvocation { return [pscustomobject]@{} }
    function Complete-SshInvocation { return [pscustomobject]@{ Code = 255; Out = ''; Err = 'Permission denied (publickey)' } }
    $secondRemote = [pscustomobject](ConvertTo-ConfigMap $remote); $secondRemote.name = 'second-remote'
    $outputs = Get-RemoteProbeOutputs @($remote, $secondRemote)
    $failedRow = Get-RemoteStatus $remote -ProbeOutput $outputs[$remote.name]
    Check 'parallel SSH failures preserve safe classified hints' ($outputs.Count -eq 2 -and $failedRow.FailCode -eq 'auth' -and $failedRow.Hint -match '认证')
    function Complete-SshInvocation { return [pscustomobject]@{ Code = 255; Out = ''; Err = 'Could not resolve hostname fixture.invalid' } }
    Check-Throws 'single SSH failure preserves classification' { Invoke-B64 'true' $remote } 'dns'
  }
  & {
    $bin = Join-Path $scratch 'package\@deepseek-ai\dsh\lib\bin.js'
    $fake = [pscustomobject]@{ ExecutablePath = 'C:\fixture\node.exe'; CommandLine = ('node.exe "' + $bin + '" web --port 41001 --no-open') }
    Check 'dsh entry point plus web/port proves process identity' (Test-DshProcessRecord $fake $bin 41001)
    $fake.CommandLine = 'node.exe unrelated.js web --port 41001'
    Check 'node name and HTTP cannot prove ownership' (-not (Test-DshProcessRecord $fake $bin 41001))
  }
  & {
    $disabledLocal = [pscustomobject](ConvertTo-ConfigMap $instances[0]); $disabledLocal.enabled = $false
    $disabledRemote = [pscustomobject](ConvertTo-ConfigMap $remote); $disabledRemote.enabled = $false
    function Get-Instances { return @($disabledLocal, $disabledRemote) }
    function Get-RecordedPid { param($InstanceName, $Kind, $Inst); if ($Kind -eq 'server') { return 71001 }; return 71002 }
    function Get-State { return [pscustomobject]@{ port = 41001; localPort = 41003; url = '' } }
    function Get-RemoteProbeOutputs { throw 'disabled rows must never launch batch SSH probes' }
    function Get-RemoteFacts { throw 'disabled rows must never launch SSH probes' }
    function Invoke-B64 { throw 'disabled rows must never send remote commands' }
    function Test-Http { throw 'disabled rows must never launch HTTP probes' }
    function Stop-OwnedProcess { throw 'status must never terminate owned processes' }
    $rows = @(Get-AllStatus)
    Check 'disabled local instance keeps its owned process and stop state' ($rows[0].State -eq 'up' -and -not $rows[0].Enabled -and $rows[0].Port -eq 41001 -and $rows[0].Detail -match '仍存活')
    Check 'disabled remote instance keeps owned tunnel without SSH or HTTP' ($rows[1].State -eq 'tunnel-only' -and -not $rows[1].Enabled -and $rows[1].Port -eq 41003 -and $rows[1].Detail -match '未探测远端')
    $editedRows = @(Get-ConfigurationRows)
    Check 'edit result also preserves disabled instance stop states' ($editedRows[0].State -eq 'up' -and $editedRows[1].State -eq 'tunnel-only' -and -not $editedRows[0].Enabled -and -not $editedRows[1].Enabled)
    function Get-RecordedPid { return 0 }
    $rows = @(Get-AllStatus)
    Check 'disabled is used only when no local owned process is confirmed' ($rows.Count -eq 2 -and @($rows | Where-Object { $_.State -eq 'disabled' -and -not $_.Enabled }).Count -eq 2)
  }
  & {
    $record = [pscustomobject]@{ serverPid = 70001; serverStartedAt = 'old-stamp'; context = $script:ConfigContext; port = 41001 }
    function Get-State { return $record }
    function Get-ProcessRecord { return [pscustomobject]@{ ProcessId = 70001 } }
    function Get-ProcessStamp { return 'reused-pid-new-stamp' }
    function Test-ProcessAlive { return $true }
    function Stop-OwnedProcess { throw 'must never kill a reused PID' }
    function Remove-State { throw 'must preserve mismatched ownership evidence' }
    Check 'PID reuse cannot pass recorded-process ownership' ((Get-RecordedPid 'local' 'server' $instances[0]) -eq 0)
    Check-Throws 'PID reuse preserves record and refuses stop' { Stop-LocalInstance $instances[0] -Quiet } 'ownership-unknown'
    $owner = [pscustomobject]@{ pid = 70001; context = $script:ConfigContext; configPath = $Config; sshConfigPath = $SshConfigPath }
    $runtime = [pscustomobject]@{ pid = 70001; configPath = (Join-Path $scratch 'different.json'); sshConfigPath = $SshConfigPath }
    function Get-ProcessRecord { throw 'mismatched context must fail before process lookup' }
    Check 'backend-published config mismatch blocks reuse' (-not (Test-AppProcess $runtime $owner))
  }
  & {
    function Get-AllStatus { param([switch]$NoProbeHttp, [string[]]$Names); return @() }
    function Start-LocalInstance { return 0 }
    $result = Invoke-Mutation 'start' @('local','missing') -Quiet
    Check 'mutation failure and unknown target produce per-target envelope' (-not $result.ok -and $result.action -eq 'start' -and $result.results.Count -eq 2 -and $result.results[0].errorCode -eq 'unknown-instance')
    function Stop-Tunnel { return $true }
    $remote.stopRemoteService = $false
    Check 'remote-only stop succeeds without SSH probe' (Stop-RemoteInstance $remote -Quiet)
  }
  & {
    $Patch = '{"displayName":"测试显示名","enabled":false,"dshVersion":"1.2.3"}'
    $result = Invoke-Mutation 'edit' @('local') -Quiet
    Check 'edit applies whitelisted fields atomically' ($result.ok -and @(Get-Instances @('local') $Config)[0].displayName -eq '测试显示名' -and -not @(Get-Instances @('local') $Config)[0].enabled)
    $Patch = '{"sshHost":"not-allowed"}'
    $result = Invoke-Mutation 'edit' @('local') -Quiet
    Check 'edit rejects non-whitelisted field' (-not $result.ok -and $result.results[0].errorCode -eq 'invalid-patch')
    function Get-State { return [pscustomobject]@{ serverPid = 999999 } }
    function Test-ProcessAlive { return $true }
    $result = Invoke-Mutation 'remove' @('local') -Quiet
    Check 'remove refuses a live recorded process' (-not $result.ok -and $result.results[0].errorCode -eq 'instance-running')
    function Get-State { return $null }
    function Get-ListeningPid { return 0 }
    $dataFile = Join-Path $scratch 'retained-user-data.txt'; [IO.File]::WriteAllText($dataFile, 'synthetic retained data')
    $result = Invoke-Mutation 'remove' @('local') -Quiet
    Check 'remove only unregisters and preserves data' ($result.ok -and (Test-Path -LiteralPath $dataFile) -and @(Get-Instances $null $Config -IncludeDisabled).Count -eq 1)
  }
  $cfg.instances = @([pscustomobject]@{ name = 'local'; kind = 'local'; port = 41001; dshVersion = '1.2.3' }, [pscustomobject]@{ name = 'local2'; kind = 'local'; port = 41004; dshVersion = '1.2.4' })
  Save-HostsConfig $cfg $Config
  Check-Throws 'shared local runtime pin conflict rejected' { Assert-LocalPins '1.2.3' } 'local-pin-conflict'
  $cfg.instances = @($cfg.instances[0]); Save-HostsConfig $cfg $Config
  $r = Invoke-ContractCli @('-Command','list','-Json')
  Check 'CLI list is one JSON array' ($r.Code -eq 0 -and $r.Out.Trim().StartsWith('[') -and @($r.Json).Count -eq 1)
  $r = Invoke-ContractCli @('-Command','start','-Target','local','-NoOpen','-Json')
  Check 'CLI missing runtime start fails nonzero with envelope' ($r.Code -ne 0 -and $r.Json -and -not $r.Json.ok -and $r.Json.results.Count -eq 1)
  $r = Invoke-ContractCli @('-Command','plan','-Action','start','-Target','local','-Json')
  $blockedPlan = if ($r.Json) { $r.Json.plans[0] } else { $null }
  Check 'blocked CLI plan stays parseable with concrete summary/errorCode' ($r.Code -ne 0 -and $blockedPlan -and -not $blockedPlan.ok -and $blockedPlan.errorCode -eq 'runtime-unavailable' -and [bool]$blockedPlan.summary -and $blockedPlan.changesSoftware -is [bool] -and $blockedPlan.restartsService -is [bool] -and $blockedPlan.requiresConfirmation -is [bool] -and $blockedPlan.steps -is [array] -and $blockedPlan.warnings -is [array])
  $r = Invoke-ContractCli @('-Command','start','-Target','missing','-NoOpen')
  Check 'non-JSON CLI failure exits nonzero' ($r.Code -ne 0)
  $r = Invoke-ContractCli @('-Command','app','-NoOpen','-Json')
  Check 'app without Node fails and names explicit install' ($r.Code -ne 0 -and $r.Json -and -not $r.Json.ok -and ($r.Err -match 'install -Target local'))
  $r = Invoke-ContractCli @('-Command','plan','-Action','install','-Target','local','-Json')
  $onePlan = if ($r.Json -and $r.Json.plans.Count -gt 0) { $r.Json.plans[0] } else { $null }
  Check 'CLI install plan reports Node preparation but starts nothing' ($r.Code -eq 0 -and $onePlan -and (Get-InstProp $onePlan 'installsNode' $false) -and -not (Get-InstProp $onePlan 'startsService' $true) -and -not (Test-Path -LiteralPath (Join-Path $scratch 'localappdata\dsh-deck\node')))
  Check 'atomic saves leave no temporary config files' (@(Get-ChildItem -LiteralPath $scratch -Filter '.dsh-*.tmp').Count -eq 0)
} catch {
  $script:failed++
  Write-Host ('FAIL test harness at line ' + $_.InvocationInfo.ScriptLineNumber + ' (' + $_.FullyQualifiedErrorId + ')')
  Write-Host $_.ScriptStackTrace
} finally {
  if ($KeepTemp) { Write-Host ('test-fixture-retained=' + $scratch) }
  elseif (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Write-Host ("contracts: passed={0} failed={1}" -f $script:passed, $script:failed)
if ($script:failed) { exit 1 }
exit 0
