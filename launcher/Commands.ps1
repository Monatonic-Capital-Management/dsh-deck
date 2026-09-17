# CLI results and read-only plans share the same configuration/runtime helpers.
function New-ActionResult([string]$Name, [bool]$Ok, [string]$ErrorCode = '', [string]$Message = '') {
  return [pscustomobject]@{ name = $Name; ok = $Ok; errorCode = $ErrorCode; message = (Protect-Text $Message) }
}
function Add-StatusMetadata($Row, $Inst, [switch]$IncludeUrls) {
  foreach ($entry in @{
    DisplayName = [string](Get-InstProp $Inst 'displayName' $Inst.name); Description = [string](Get-InstProp $Inst 'description' '')
    Enabled = (Test-InstFlag $Inst 'enabled' $true); DshVersionPinned = [string](Get-DesiredDshVersion $Inst)
    AttemptedAt = (Get-Date).ToString('o'); ProbedAt = ''; StatusError = ''
  }.GetEnumerator()) { $Row | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force }
  if ($Row.State -eq 'unreachable') { $Row.StatusError = Protect-Text $Row.Detail }
  elseif ($Row.State -notin @('disabled','not-probed')) { $Row.ProbedAt = $Row.AttemptedAt }
  if (-not $IncludeUrls) {
    foreach ($key in @('Url','RemoteUrl')) {
      if ($Row.PSObject.Properties[$key] -and $Row.$key) { $Row.$key = ([string]$Row.$key -split '[?#]', 2)[0] }
    }
  }
  foreach ($key in @('Detail','Hint','StatusError')) { if ($Row.PSObject.Properties[$key]) { $Row.$key = Protect-Text ([string]$Row.$key) } }
  return $Row
}
function Get-DisabledStatus($Inst, [switch]$IncludeUrls) {
  $kind = if ($Inst.kind -eq 'remote') { 'tunnel' } else { 'server' }
  $owned = Get-RecordedPid $Inst.name $kind $Inst
  $row = [pscustomobject]@{ Name = $Inst.name; Kind = $Inst.kind; Port = 0; State = 'disabled'; Detail = '登记已停用；未确认有存活的本地受管进程，未探测远端服务'; Http = 0; Url = '' }
  if ($owned -gt 0) {
    $state = Get-State $Inst.name
    if ($Inst.kind -eq 'remote') {
      $row.Port = [int](Get-InstProp $state 'localPort' $Inst.localPort)
      $row.State = 'tunnel-only'
      $row.Detail = '登记已停用，但受管 SSH 隧道仍存活，可执行停止；未探测远端服务'
      if ($IncludeUrls) { $row.Url = [string](Get-InstProp $state 'url' '') }
    } else {
      $row.Port = [int](Get-InstProp $state 'port' $Inst.port)
      $row.State = 'up'
      $row.Detail = '登记已停用，但受管本地进程仍存活，可执行停止；未执行 HTTP 健康探测'
      if ($IncludeUrls) { $row.Url = Get-LocalUrl $Inst.name $row.Port }
    }
  }
  return $row
}
function Get-ConfigurationRows([string[]]$Names) {
  foreach ($inst in @(Get-Instances $Names $Config -IncludeDisabled)) {
    if (-not $inst.enabled) { $row = Get-DisabledStatus $inst }
    else { $row = [pscustomobject]@{ Name = $inst.name; Kind = $inst.kind; Port = [int](Get-InstProp $inst 'localPort' (Get-InstProp $inst 'port' 0)); State = 'not-probed'; Detail = '配置已读取；未执行运行状态探测'; Http = 0; Url = '' } }
    Add-StatusMetadata $row $inst
  }
}
function Get-AllStatus([switch]$NoProbeHttp, [string[]]$Names, [switch]$IncludeUrls) {
  $instances = @(Get-Instances $Names $Config -IncludeDisabled)
  $remotes = @($instances | Where-Object { $_.enabled -and $_.kind -eq 'remote' })
  $outputs = @{}
  if ($remotes.Count -gt 1) { $outputs = Get-RemoteProbeOutputs $remotes -IncludeUrl:$IncludeUrls }
  foreach ($inst in $instances) {
    try {
      if (-not $inst.enabled) {
        $row = Get-DisabledStatus $inst -IncludeUrls:$IncludeUrls
      } elseif ($inst.kind -eq 'remote') {
        if ($outputs.ContainsKey($inst.name)) { $row = Get-RemoteStatus $inst -ProbeOutput $outputs[$inst.name] -IncludeUrl:$IncludeUrls }
        else { $row = Get-RemoteStatus $inst -IncludeUrl:$IncludeUrls }
      } else { $row = Get-LocalStatus $inst -NoProbeHttp:$NoProbeHttp }
    } catch {
      $row = [pscustomobject]@{ Name = $inst.name; Kind = $inst.kind; Port = [int](Get-InstProp $inst 'localPort' (Get-InstProp $inst 'port' 0)); State = 'unreachable'; Detail = (Protect-Text $_.Exception.Message); Hint = (Protect-Text $_.Exception.Message); FailCode = (Get-ErrorCode $_); Http = 0; Url = '' }
    }
    Add-StatusMetadata $row $inst -IncludeUrls:$IncludeUrls
  }
}
function Write-StatusTable($Rows) {
  Write-Head 'INSTANCE / KIND / PORT / STATE / DETAIL'
  foreach ($row in $Rows) { Write-C ('{0,-18} {1,-8} {2,-6} {3,-14} {4}' -f $row.Name, $row.Kind, $row.Port, $row.State, $row.Detail) }
}
function Get-InstancePlan($Inst, [ValidateSet('start','install','upgrade')][string]$Action) {
  $resolved = Resolve-TargetDshVersion $Inst -ReadOnly
  $current = ''; $nodeVersion = ''; $nodeNeeded = $false; $running = $false; $healthy = $false; $servicePresent = $true
  $warnings = @(); $steps = @(); $blocked = ''; $errorCode = ''; $facts = @{}
  if ($Inst.kind -eq 'local') {
    $current = Get-LocalDshVersion
    $node = Get-NodeExe; $nodeVersion = Get-NodeVersionOf $node
    $nodeNeeded = -not $nodeVersion -or (Compare-Version $nodeVersion $script:NodeMinVersion) -lt 0 -or -not (Test-NodeUsable $node -ReadOnly)
    $managed = Get-RecordedPid $Inst.name 'server' $Inst
    $running = $managed -gt 0
    $port = [int]$Inst.port
    if ($running) { $port = [int](Get-InstProp (Get-State $Inst.name) 'port' $port) }
    $healthy = $running -and (Get-ListeningPid $port) -eq $managed -and (Test-DshServing $port)
    try { Assert-LocalPins $(if ($Action -eq 'upgrade' -or -not $current) { $resolved.target } else { '' }) }
    catch { $blocked = $_.Exception.Message; $errorCode = Get-ErrorCode $_ }
  } else {
    $facts = Get-RemoteFacts $Inst
    $current = [string]$facts['DSH_V']; $nodeVersion = [string]$facts['NODE_V']
    $nodeNeeded = -not $nodeVersion -or (Compare-Version $nodeVersion $script:NodeMinVersion) -lt 0 -or -not $facts['NPM']
    $running = $facts['SNAP_STATE'] -eq 'active'; $healthy = Test-RemoteSnapshotHealthy $facts
    $servicePresent = $facts['SERVICE_PRESENT'] -eq 'yes'
    if ($facts['SNAP_LISTENING'] -eq 'yes' -and $facts['SNAP_OWNED'] -ne 'yes' -and $Action -ne 'install') { $blocked = '远端端口属于未知进程，未计划终止或接管。'; $errorCode = 'remote-port-busy' }
  }
  $packageChange = -not $current
  if ($Action -eq 'upgrade') { $packageChange = $current -ne $resolved.target; if (-not $packageChange) { $nodeNeeded = $false } }
  $serviceChange = $Inst.kind -eq 'remote' -and (($Action -eq 'install') -or ($Action -eq 'upgrade' -and $packageChange) -or ($Action -eq 'start' -and -not $servicePresent -and -not $healthy))
  $restart = $Inst.kind -eq 'remote' -and $Action -eq 'upgrade' -and $packageChange -and $running
  $startsService = $Action -eq 'start' -and -not $running
  if ($Action -eq 'start') {
    if ($resolved.pinned -and $current -and $resolved.pinned -ne $current) { $blocked = '已安装版本与 dshVersion 不符；start 不替换可用软件，请执行 upgrade。'; $errorCode = 'pin-mismatch' }
    if ($Inst.kind -eq 'local') {
      if ($packageChange -or $nodeNeeded) { $blocked = "本机 start 不自动安装。请执行 dsh.ps1 -Command install -Target $($Inst.name)。"; $errorCode = 'runtime-unavailable' }
      $packageChange = $false; $nodeNeeded = $false
    } elseif ($healthy) { $packageChange = $false; $nodeNeeded = $false; $serviceChange = $false }
    elseif (($packageChange -or $nodeNeeded -or $serviceChange) -and -not $Inst.autoInstall) { $blocked = 'autoInstall=false，需先显式执行 install；start 不会准备软件或服务定义。'; $errorCode = 'auto-install-disabled' }
  }
  if (($packageChange -or $Action -eq 'upgrade') -and -not $resolved.target) { $blocked = '无法确定目标版本。请设置 dshVersion 或恢复 registry 连接。'; $errorCode = 'unknown-version' }
  if ($Action -eq 'upgrade' -and $packageChange -and $Inst.kind -eq 'local') {
    try { Assert-LocalRuntimeStopped } catch { $blocked = $_.Exception.Message; $errorCode = Get-ErrorCode $_ }
  }
  if (-not $Inst.enabled -and $Action -eq 'start') { $blocked = '实例已停用，请先启用。'; $errorCode = 'disabled' }
  if ($Action -eq 'install' -and $current) { $warnings += 'install 不替换已经可用的 dsh；版本不符时请另行预览 upgrade。' }
  if ($Action -eq 'upgrade' -and $packageChange) { $warnings += '升级失败不保证回滚；已安装版本不等于正在运行版本。' }
  if ($Inst.kind -eq 'local' -and ($packageChange -or $nodeNeeded)) { $warnings += '此机器的本地实例共享 runtime，本次准备会影响共用软件。' }
  if ($blocked) {
    $steps = @(); $warnings += $blocked
    $packageChange = $false; $nodeNeeded = $false; $serviceChange = $false; $restart = $false; $startsService = $false
  } else {
    if ($nodeNeeded) { $steps += "下载并校验 Node $($script:ManagedNodeVersion)，安装到用户目录（不更改系统 Node）。" }
    if ($packageChange) { $steps += "npm install -g @deepseek-ai/dsh@$($resolved.target)，验证退出码与实际版本。" }
    if ($serviceChange) { $steps += '部署 systemd 用户服务定义，尝试启用 linger；此步骤不启动服务。' }
    if ($restart) { $steps += '重启正在运行的远端服务，并验证进程归属和 HTTP 健康。' }
    if ($Action -eq 'start' -and -not $healthy) { $steps += '启动或等待受管服务，验证进程归属和健康状态。' }
    if ($Action -eq 'start' -and $Inst.kind -eq 'remote') { $steps += '建立或复用受管 SSH 隧道，不终止外部进程。' }
    if ($steps.Count -eq 0) { $steps += '已满足条件，无需修改软件或重启服务。' }
  }
  $changesSoftware = $packageChange -or $nodeNeeded
  return [pscustomobject]@{
    ok = -not [bool]$blocked; name = $Inst.name; displayName = $Inst.displayName; kind = $Inst.kind; action = $Action
    targetVersion = $resolved.target; currentVersion = $current; nodeVersion = $nodeVersion; pinnedVersion = $resolved.pinned; versionSource = $resolved.source
    changesSoftware = [bool]$changesSoftware; installsNode = [bool]$nodeNeeded; changesDsh = [bool]$packageChange; changesServiceDefinition = [bool]$serviceChange
    restartsService = [bool]$restart; startsService = [bool]$startsService; requiresConfirmation = [bool]($changesSoftware -or $serviceChange -or $restart)
    summary = $(if ($blocked) { Protect-Text $blocked } elseif ($Action -eq 'install') { '仅准备运行时和服务定义，不启动、不替换可用 dsh。' } elseif ($restart) { '按目标版本更新软件，并重启运行中的远端服务。' } elseif ($healthy -and $Action -eq 'start') { '服务已健康；只复用服务并检查隧道。' } else { "$Action：按以下步骤执行，不保证升级回滚。" })
    steps = @($steps); warnings = @($warnings | ForEach-Object { Protect-Text $_ }); errorCode = $errorCode; blocked = [bool]$blocked
  }
}
function Invoke-Plan([string[]]$Names, [string]$Action) {
  if ($Action -notin @('start','install','upgrade')) { Throw-LauncherError 'invalid-action' 'plan 需要 -Action start、install 或 upgrade。' }
  $plans = @()
  foreach ($inst in @(Get-Instances $Names $Config)) {
    try { $plans += Get-InstancePlan $inst $Action }
    catch {
      $plans += [pscustomobject]@{ ok = $false; name = $inst.name; displayName = $inst.displayName; kind = $inst.kind; action = $Action; targetVersion = (Get-DesiredDshVersion $inst); currentVersion = ''; nodeVersion = ''; pinnedVersion = (Get-DesiredDshVersion $inst); versionSource = ''; changesSoftware = $false; installsNode = $false; changesDsh = $false; changesServiceDefinition = $false; restartsService = $false; startsService = $false; requiresConfirmation = $false; summary = (Protect-Text $_.Exception.Message); steps = @(); warnings = @('未取得完整探测结果，不能执行此计划。'); errorCode = (Get-ErrorCode $_); blocked = $true }
    }
  }
  return [pscustomobject]@{ ok = ($plans.Count -gt 0 -and @($plans | Where-Object { -not $_.ok }).Count -eq 0); plans = @($plans) }
}
function Invoke-Add([switch]$Quiet) {
  if (-not $SshHost) { Throw-LauncherError 'invalid-argument' 'add 需要 -SshHost <alias-or-user@host>。' }
  $newName = if ($Name) { $Name } else { $SshHost }
  Assert-InstanceName $newName
  Assert-ConfigFields ([ordered]@{ sshHost = $SshHost })
  $cfg = Get-HostsConfig $Config; $all = @((Get-NormalizedConfig $cfg).instances)
  if (@($all | Where-Object { $_.name -eq $newName }).Count -gt 0) { Throw-LauncherError 'duplicate-instance' '该实例 name 已登记。' }
  $used = @($all | ForEach-Object { [int](Get-InstProp $_ 'localPort' (Get-InstProp $_ 'port' 0)) })
  $local = 3099
  while ($local -le 65535 -and ($used -contains $local -or (Test-PortListening $local))) { $local++ }
  if ($local -gt 65535) { Throw-LauncherError 'port-busy' '找不到可用的本地隧道端口。' }
  $new = [pscustomobject]@{ name = $newName; displayName = $(if ($DisplayName) { $DisplayName } else { $newName }); kind = 'remote'; enabled = $true; sshHost = $SshHost; remotePort = $(if ($Port) { $Port } else { 3080 }); localPort = $local; description = '' }
  $cfg.instances = @($cfg.instances) + $new
  Save-HostsConfig $cfg $Config
  return $newName
}
function Invoke-Edit($Inst, [string]$PatchJson) {
  try { $patchObject = ConvertFrom-Json -InputObject $PatchJson }
  catch { Throw-LauncherError 'invalid-patch' 'Patch 不是有效 JSON 对象。' }
  if ($patchObject -isnot [pscustomobject]) { Throw-LauncherError 'invalid-patch' 'Patch 必须是 JSON 对象。' }
  $patchMap = ConvertTo-ConfigMap $patchObject
  if ($patchMap.Count -eq 0) { Throw-LauncherError 'invalid-patch' 'Patch 不能为空。' }
  $allowed = @('displayName','description','workdir','enabled','dshVersion','autoInstall','stopRemoteService')
  foreach ($key in $patchMap.Keys) { if ($key -cnotin $allowed) { Throw-LauncherError 'invalid-patch' 'Patch 包含非白名单字段；name、kind、SSH 与端口不能通过 edit 修改。' } }
  Assert-ConfigFields $patchMap
  $cfg = Get-HostsConfig $Config; $updated = @()
  foreach ($entry in @($cfg.instances)) {
    $raw = ConvertTo-ConfigMap $entry
    $entryName = [string](Get-InstProp $entry 'name' (Get-InstProp $entry 'profile' ''))
    if ($entryName -eq $Inst.name) { foreach ($key in $patchMap.Keys) { $raw[$key] = $patchMap[$key] } }
    $updated += [pscustomobject]$raw
  }
  $cfg.instances = $updated
  Save-HostsConfig $cfg $Config
  return $true
}
function Invoke-Remove($Inst) {
  $state = Get-State $Inst.name
  foreach ($field in @('serverPid','tunnelPid')) {
    $processId = [int](Get-InstProp $state $field 0)
    if ($processId -gt 0 -and (Test-ProcessAlive $processId)) { Throw-LauncherError 'instance-running' '记录中的进程仍存活；请先停止并确认归属后再移除登记。' }
  }
  if ($Inst.kind -eq 'remote') {
    $facts = Get-RemoteFacts $Inst
    if ($facts['SNAP_STATE'] -eq 'active' -or $facts['SNAP_OWNED'] -eq 'yes') { Throw-LauncherError 'instance-running' '远端受管服务仍运行；请先停止远端服务，再移除登记。' }
  } else {
    $holder = Get-ListeningPid ([int]$Inst.port)
    if ($holder -gt 0 -and (Test-DshProcessRecord (Get-ProcessRecord $holder) (Find-DshLocal) ([int]$Inst.port))) { Throw-LauncherError 'instance-running' '该端口上的 dsh 仍运行；请先手动停止外部实例。' }
  }
  $cfg = Get-HostsConfig $Config
  $cfg.instances = @($cfg.instances | Where-Object { (Get-InstProp $_ 'name' (Get-InstProp $_ 'profile' '')) -ne $Inst.name })
  Save-HostsConfig $cfg $Config
  return $true
}
function Invoke-Mutation([string]$Action, [string[]]$Names, [switch]$Quiet, [switch]$DryRun) {
  $results = @(); $rows = @(); $plans = @(); $rootGuard = $null; $configGuard = $null; $runtimeGuard = $null
  try {
    $rootGuard = Enter-LauncherLock ('launcher:' + $LauncherDir)
    $configGuard = Enter-LauncherLock ('config:' + (Resolve-ConfigPath $Config))
    if ($Action -eq 'add') {
      $added = Invoke-Add -Quiet:$Quiet
      $results += New-ActionResult $added $true '' '已登记；未连接 SSH、未安装或启动软件。'
      $rows = @(Get-ConfigurationRows @($added))
    } else {
      $all = @(Get-Instances $null $Config -IncludeDisabled)
      $requested = @(Expand-TargetNames $Names)
      if ($Action -in @('edit','remove') -and $requested.Count -ne 1) { Throw-LauncherError 'invalid-target' 'edit/remove 必须指定唯一 -Target。' }
      if ($requested.Count -eq 0) { $requested = @($all | Where-Object { $_.enabled } | ForEach-Object { $_.name }) }
      if ($requested.Count -eq 0) { Throw-LauncherError 'no-targets' '没有选中的实例。' }
      $selected = @()
      foreach ($requestedName in $requested) {
        $hit = @($all | Where-Object { $_.name -eq $requestedName })
        if ($hit.Count -eq 0) { $results += New-ActionResult $requestedName $false 'unknown-instance' 'unknown instance；使用 list 查看登记。' }
        else { $selected += $hit[0] }
      }
      if (@($selected | Where-Object { $_.kind -eq 'local' }).Count -gt 0 -and $Action -in @('start','stop','restart','install','upgrade')) { $runtimeGuard = Enter-LauncherLock ('local-runtime:' + (Get-HomeDir)) }
      foreach ($inst in $selected) {
        $script:LastFailure = ''
        try {
          $ok = $false; $message = '操作已完成。'
          if ($DryRun) {
            $preview = Get-InstancePlan $inst $Action; $plans += $preview; $ok = $preview.ok
            if (-not $ok) { Throw-LauncherError $preview.errorCode $preview.summary }
            $message = '仅预览，未执行变更。'
          } else {
            switch ($Action) {
              'start' {
                if (-not $inst.enabled) { Throw-LauncherError 'disabled' '实例已停用，请先启用。' }
                if ($inst.kind -eq 'remote') { $ok = [bool](Start-RemoteInstance $inst -Quiet:$Quiet) }
                else { $ok = (Start-LocalInstance $inst -Quiet:$Quiet -PortOverride $LocalPort) -gt 0 }
                $message = '实例已通过启动/复用验证。'
              }
              'stop' {
                if ($inst.kind -eq 'remote') { $ok = [bool](Stop-RemoteInstance $inst -Quiet:$Quiet) }
                else { $ok = [bool](Stop-LocalInstance $inst -Quiet:$Quiet) }
                $message = if ($inst.kind -eq 'remote' -and -not $inst.stopRemoteService) { '隧道已断开；stopRemoteService=false，远端服务未请求停止（remote-only 是预期结果）。' } else { '受管进程已停止，或已确认未运行。' }
              }
              'restart' {
                if (-not $inst.enabled) { Throw-LauncherError 'disabled' '实例已停用，请先启用。' }
                if ($inst.kind -eq 'remote') { $ok = [bool](Stop-RemoteInstance $inst -Quiet:$Quiet); if ($ok) { $ok = [bool](Start-RemoteInstance $inst -Quiet:$Quiet) } }
                else { $ok = [bool](Stop-LocalInstance $inst -Quiet:$Quiet); if ($ok) { $ok = (Start-LocalInstance $inst -Quiet:$Quiet -PortOverride $LocalPort) -gt 0 } }
                $message = if ($inst.kind -eq 'remote' -and -not $inst.stopRemoteService) { '按 stopRemoteService=false 仅重建隧道，未请求重启远端服务。' } else { '已停止并重新启动，通过健康验证。' }
              }
              'install' {
                if ($inst.kind -eq 'remote') { $ok = [bool](Install-RemoteDsh $inst -Quiet:$Quiet); if ($ok) { $ok = [bool](Install-RemoteService $inst -Quiet:$Quiet) } }
                else { $ok = [bool](Install-LocalDsh $inst -Quiet:$Quiet) }
                $message = '已准备可用软件/服务定义；未启动服务，未替换已可用 dsh。'
              }
              'upgrade' {
                $version = (Resolve-TargetDshVersion $inst -ReadOnly).target
                if ($inst.kind -eq 'remote') { $ok = [bool](Upgrade-RemoteDsh $inst -Version $version) }
                else { $ok = [bool](Upgrade-LocalDsh -Inst $inst -Version $version) }
                $message = '已按目标版本验证安装；运行版本以 RunningVersion 为准，不保证失败回滚。'
              }
              'edit' { $ok = [bool](Invoke-Edit $inst $Patch); $message = '配置已原子保存；没有启动、停止或升级服务。' }
              'remove' { $ok = [bool](Invoke-Remove $inst); $message = '仅取消登记；未卸载软件、删除状态或用户数据。' }
            }
          }
          if (-not $ok) { Throw-LauncherError "$Action-failed" $(if ($script:LastFailure) { $script:LastFailure } else { '未达到请求的目标状态。' }) }
          $results += New-ActionResult $inst.name $true '' $message
          if (-not $Quiet) { Write-Ok "$($inst.name): $message" }
        } catch { $results += New-ActionResult $inst.name $false (Get-ErrorCode $_) $_.Exception.Message; Write-Err $_.Exception.Message }
      }
      $remaining = @($selected | ForEach-Object { $_.name })
      if ($Action -eq 'remove') { $rows = @() }
      elseif ($remaining.Count -gt 0) {
        if ($Action -in @('edit') -or $DryRun) { $rows = @(Get-ConfigurationRows $remaining) }
        else { $rows = @(Get-AllStatus -Names $remaining -NoProbeHttp) }
      }
      if ($Action -in @('start','restart') -and -not $NoOpen -and -not $DryRun) {
        $successNames = @($results | Where-Object { $_.ok } | ForEach-Object { $_.name })
        if ($successNames.Count -gt 0) { foreach ($row in @(Get-AllStatus -Names $successNames -NoProbeHttp -IncludeUrls)) { if ($row.Url) { Open-Instance $row.Url -AsAppWindow:$AppWindow } } }
      }
    }
  } catch {
    $label = if ($Action -eq 'add') { $(if ($Name) { $Name } else { $SshHost }) } elseif (@($Names).Count -eq 1) { [string]$Names[0] } else { '' }
    $results += New-ActionResult $label $false (Get-ErrorCode $_) $_.Exception.Message
    Write-Err $_.Exception.Message
  } finally { Exit-LauncherLock $runtimeGuard; Exit-LauncherLock $configGuard; Exit-LauncherLock $rootGuard }
  $envelope = [ordered]@{ ok = ($results.Count -gt 0 -and @($results | Where-Object { -not $_.ok }).Count -eq 0); action = $Action; results = @($results); rows = @($rows) }
  if ($DryRun) { $envelope['plans'] = @($plans) }
  return [pscustomobject]$envelope
}
function Invoke-Start([string[]]$Names, [switch]$Quiet) { return Invoke-Mutation 'start' $Names -Quiet:$Quiet }
function Invoke-Stop([string[]]$Names) { return Invoke-Mutation 'stop' $Names }
function Invoke-Install([string[]]$Names, [switch]$Quiet) { return Invoke-Mutation 'install' $Names -Quiet:$Quiet }
function Invoke-Upgrade([string[]]$Names, [switch]$DryRun) { return Invoke-Mutation 'upgrade' $Names -DryRun:$DryRun }
function Invoke-List { foreach ($inst in @(Get-Instances $Target $Config -IncludeDisabled)) { Write-C ("{0,-18} {1,-8} {2}" -f $inst.name, $inst.kind, $inst.displayName) } }
function Invoke-Check {
  $rows = @()
  foreach ($inst in @(Get-Instances $Target $Config)) {
    try {
      $current = if ($inst.kind -eq 'remote') { [string](Get-RemoteFacts $inst)['DSH_V'] } else { Get-LocalDshVersion }
      $update = Get-UpdateStatus $inst $current
      $rows += [pscustomobject]@{ Name = $inst.name; Kind = $inst.kind; Current = $current; Latest = $update.latest; Target = $update.target; Pinned = $update.pinned; UpdateAvailable = $update.updateAvailable; Reason = $update.reason }
    } catch {
      $script:ExitCode = 1
      $rows += [pscustomobject]@{ Name = $inst.name; Kind = $inst.kind; Current = '(unreachable)'; Latest = ''; Target = (Get-DesiredDshVersion $inst); Pinned = (Get-DesiredDshVersion $inst); UpdateAvailable = $false; Reason = (Get-ErrorCode $_) }
    }
  }
  if ($Json) { Write-Json $rows } else { foreach ($row in $rows) { Write-C "$($row.Name): $($row.Current) -> $($row.Target)" } }
}
function Invoke-Url([string[]]$Names) {
  $rows = @(Get-AllStatus -Names $Names -NoProbeHttp -IncludeUrls)
  if ($Json) { if ($rows.Count -eq 1) { Write-Json $rows[0] } else { Write-Json $rows } }
  else { foreach ($row in $rows) { if ($row.Url) { Write-C "$($row.Name): $($row.Url)" } else { Write-Warn2 "$($row.Name): no URL available" } } }
  if ($rows.Count -eq 0 -or @($rows | Where-Object { -not $_.Url }).Count -gt 0) { $script:ExitCode = 1 }
}
function Invoke-Open([string[]]$Names) {
  $rows = @(Get-AllStatus -Names $Names -NoProbeHttp -IncludeUrls); $opened = 0
  foreach ($row in $rows) { if ($row.Url) { if (-not $NoOpen) { Open-Instance $row.Url -AsAppWindow:$AppWindow }; $opened++ } }
  if ($opened -eq 0) { Throw-LauncherError 'not-running' '没有可打开的实例，请先 start。' }
  if ($Json) { Write-Json @{ ok = $true; opened = $opened; noOpen = [bool]$NoOpen } }
}
function Invoke-Logs([string[]]$Names, [int]$Tail, [switch]$Follow) {
  $instances = @(Get-Instances $Names $Config)
  if ($Tail -lt 1 -or $Tail -gt 10000) { Throw-LauncherError 'invalid-argument' 'Lines 必须是 1 到 10000。' }
  if ($Follow -and ($Json -or $instances.Count -ne 1)) { Throw-LauncherError 'invalid-argument' 'Follow 仅用于单实例的非 JSON 日志流。' }
  $logs = @()
  foreach ($inst in $instances) {
    $text = ''
    if ($inst.kind -eq 'remote') {
      $body = 'tail -n ' + $Tail + $(if ($Follow) { ' -F' } else { '' }) + ' "$HOME/.dsh/remote-web.log"'
      if ($Follow) { Invoke-SshStream $body $inst; return }
      $text = Invoke-B64 $body $inst
    } else {
      $file = Join-Path $LogDir "$($inst.name).server.log"
      if (Test-Path -LiteralPath $file) {
        if ($Follow) { Get-Content -LiteralPath $file -Tail $Tail -Wait | ForEach-Object { Write-C $_ }; return }
        $text = Get-Content -LiteralPath $file -Tail $Tail | Out-String
      }
    }
    $safe = Protect-Text $text
    if ($Json) { $logs += [pscustomobject]@{ name = $inst.name; text = $safe } } else { Write-C $safe }
  }
  if ($Json) { Write-Json @{ ok = $true; logs = @($logs) } }
}
function Invoke-Doctor([string]$SshConfigOverride) {
  $node = Get-NodeExe; $bin = Find-DshLocal
  $rows = @(Get-AllStatus -Names $Target -NoProbeHttp:$NoProbe)
  if ($Json) { Write-Json @{ nodeVersion = (Get-NodeVersionOf $node); dshInstalled = [bool]$bin; instances = $rows; ssh = (Get-SshHosts) }; return }
  if ($node) { Write-Info "node : $(Get-NodeVersionOf $node)" } else { Write-Err 'node : NOT FOUND; run dsh.ps1 -Command install -Target local' }
  if ($bin) { Write-Info 'dsh : found' } else { Write-Err 'dsh : NOT FOUND; run dsh.ps1 -Command install -Target local' }
  Write-StatusTable $rows
}
