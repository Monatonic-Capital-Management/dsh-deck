# Configuration is read only on explicit function calls, never on import.
function Get-ConfigProp($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [Collections.IDictionary]) { return $Obj[$Name] }
  if ($Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
  return $null
}
function Get-InstProp($Inst, [string]$Name, $Default = $null) {
  $value = Get-ConfigProp $Inst $Name
  if ($null -eq $value -or ($value -is [string] -and $value -ceq '')) { return $Default }
  return $value
}
function Test-InstFlag($Inst, [string]$Name, [bool]$Default = $false) {
  $value = Get-ConfigProp $Inst $Name
  if ($null -eq $value) { return $Default }
  if ($value -isnot [bool]) { Throw-LauncherError 'invalid-config' "$Name 必须是 JSON 布尔值。" }
  return $value
}
function ConvertTo-ConfigMap($Obj) {
  $map = [ordered]@{}
  if ($Obj -is [Collections.IDictionary]) { foreach ($key in $Obj.Keys) { $map[$key] = $Obj[$key] } }
  elseif ($Obj) { foreach ($prop in $Obj.PSObject.Properties) { $map[$prop.Name] = $prop.Value } }
  return $map
}
function Get-HomeDir {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  if ($env:HOME) { return $env:HOME }
  return $LauncherDir
}
function Resolve-FullPath([string]$Path) {
  if ($Path -eq '~') { return [IO.Path]::GetFullPath((Get-HomeDir)) }
  if ($Path -match '^~[/\\]') { $Path = Join-Path (Get-HomeDir) $Path.Substring(2) }
  if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
  return [IO.Path]::GetFullPath($Path)
}
function Resolve-ConfigPath([string]$Explicit) {
  if ($Explicit) { return Resolve-FullPath $Explicit }
  if ($env:DSH_LAUNCHER_CONFIG) { return Resolve-FullPath $env:DSH_LAUNCHER_CONFIG }
  foreach ($path in @((Join-Path $LauncherDir 'hosts.json'), (Join-Path $LauncherDir '.dshproj.json'), (Join-Path (Get-HomeDir) '.dsh-launcher\hosts.json'))) {
    if (Test-Path -LiteralPath $path) { return Resolve-FullPath $path }
  }
  return Resolve-FullPath (Join-Path (Get-HomeDir) '.dsh-launcher\hosts.json')
}
function Get-SshConfigPath([string]$Override) {
  if ($Override) { return Resolve-FullPath $Override }
  if ($env:DSH_SSH_CONFIG) { return Resolve-FullPath $env:DSH_SSH_CONFIG }
  return Resolve-FullPath (Join-Path (Get-HomeDir) '.ssh\config')
}
function Get-DefaultHosts {
  return [pscustomobject]@{ version = 1; profiles = @(); instances = @(
    [pscustomobject]@{ name = 'local'; kind = 'local'; enabled = $true; port = 3080; workdir = (Get-HomeDir); description = '本机 dsh web' }
  ) }
}
function Assert-InstanceName([string]$Value) {
  if (-not $Value -or $Value.Length -gt 120 -or $Value -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.@-]*$' -or $Value.Contains('..') -or $Value.EndsWith('.') -or $Value -match '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)') {
    Throw-LauncherError 'invalid-name' 'name 只能使用字母、数字、下划线、连字符、点和 @，不得包含路径、命令字符或 Windows 保留名。'
  }
  if ($Value -in @('app','app-owner','tray','latest-version','balance')) { Throw-LauncherError 'invalid-name' '此 name 为启动器保留标识。' }
}
function Assert-DshVersion([string]$Value) {
  if ($Value -and $Value -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
    Throw-LauncherError 'invalid-config' 'dshVersion 必须是完整版本号（例如 0.1.5-rc.1），或留空。'
  }
}
function Assert-ConfigFields($Map) {
  foreach ($key in @('port','localPort','remotePort','sshPort')) {
    if ($Map.Contains($key)) {
      $value = $Map[$key]
      if ($value -isnot [int] -and $value -isnot [long]) { Throw-LauncherError 'invalid-config' "$key 必须是 1 到 65535 的整数。" }
      if ($value -lt 1 -or $value -gt 65535) { Throw-LauncherError 'invalid-config' "$key 必须是 1 到 65535 的整数。" }
    }
  }
  foreach ($key in @('enabled','autoInstall','stopRemoteService')) {
    if ($Map.Contains($key) -and $Map[$key] -isnot [bool]) { Throw-LauncherError 'invalid-config' "$key 必须是 JSON 布尔值。" }
  }
  foreach ($key in @('name','kind','profile','displayName','description','workdir','dshVersion','sshHost','sshUser','identityFile','jumpHost','runAsUser')) {
    if ($Map.Contains($key) -and $null -ne $Map[$key] -and $Map[$key] -isnot [string]) { Throw-LauncherError 'invalid-config' "$key 必须是字符串。" }
    if ($Map.Contains($key) -and [string]$Map[$key] -match '[\x00-\x1f\x7f]') { Throw-LauncherError 'invalid-config' "$key 不得包含控制字符。" }
  }
  if ($Map.Contains('kind') -and $Map['kind'] -notin @('local','remote')) { Throw-LauncherError 'invalid-config' 'kind 必须是 local 或 remote。' }
  if ($Map.Contains('dshVersion')) { Assert-DshVersion ([string]$Map['dshVersion']) }
  foreach ($key in @('sshHost','jumpHost')) {
    if ($Map.Contains($key) -and $Map[$key] -and $Map[$key] -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.@:\[\],-]*$') { Throw-LauncherError 'invalid-config' "$key 含有不安全的 SSH 地址字符。" }
  }
  foreach ($key in @('sshUser','runAsUser')) {
    if ($Map.Contains($key) -and $Map[$key] -and $Map[$key] -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { Throw-LauncherError 'invalid-config' "$key 含有不安全的用户名字符。" }
  }
  if ($Map.Contains('identityFile') -and [string]$Map['identityFile'] -match '["\r\n\x00]') { Throw-LauncherError 'invalid-config' 'identityFile 不得包含引号或控制字符。' }
}
function Get-NormalizedConfig($Cfg) {
  $root = ConvertTo-ConfigMap $Cfg
  if (-not $root.Contains('version') -or ($root['version'] -isnot [int] -and $root['version'] -isnot [long]) -or $root['version'] -ne 1) { Throw-LauncherError 'invalid-config' '配置 version 必须是整数 1。' }
  if (-not $root.Contains('instances') -or $root['instances'] -isnot [array]) { Throw-LauncherError 'invalid-config' '配置必须包含 instances 数组。' }
  if ($root.Contains('profiles') -and $root['profiles'] -isnot [array]) { Throw-LauncherError 'invalid-config' 'profiles 必须是数组。' }
  $profiles = @{}
  foreach ($profile in @($root['profiles'])) {
    if (-not $profile) { continue }
    $map = ConvertTo-ConfigMap $profile
    Assert-InstanceName ([string]$map['name']); Assert-ConfigFields $map
    if ($profiles.ContainsKey([string]$map['name'])) { Throw-LauncherError 'invalid-config' 'profile name 重复。' }
    $profiles[[string]$map['name']] = $map
  }
  $users = Get-ConfigProp $Cfg 'userProfiles'
  if ($users -and $users -isnot [Collections.IDictionary] -and $users -isnot [pscustomobject]) { Throw-LauncherError 'invalid-config' 'userProfiles 必须是按用户名索引的对象。' }
  $userMap = ConvertTo-ConfigMap $users
  foreach ($user in $userMap.Keys) {
    $overrides = ConvertTo-ConfigMap $userMap[$user]
    foreach ($profileName in $overrides.Keys) {
      if (-not $profiles.ContainsKey($profileName)) { Throw-LauncherError 'invalid-config' 'userProfiles 引用了不存在的 profile。' }
      $fields = ConvertTo-ConfigMap $overrides[$profileName]
      if ($fields.Contains('name') -or $fields.Contains('profile')) { Throw-LauncherError 'invalid-config' 'userProfiles 不得覆盖 name 或 profile。' }
      Assert-ConfigFields $fields
    }
  }
  $me = if ($env:USERNAME) { $env:USERNAME } else { $env:USER }
  $mine = ConvertTo-ConfigMap (Get-ConfigProp $users $me)
  $names = @{}; $localPorts = @{}; $remoteUnits = @{}; $expanded = @()
  foreach ($instance in @($root['instances'])) {
    if ($instance -isnot [pscustomobject] -and $instance -isnot [Collections.IDictionary]) { Throw-LauncherError 'invalid-config' 'instances 的每一项必须是对象。' }
    $own = ConvertTo-ConfigMap $instance
    Assert-ConfigFields $own
    $merged = [ordered]@{}
    $profileName = [string]$own['profile']
    if ($profileName) {
      if (-not $profiles.ContainsKey($profileName)) { Throw-LauncherError 'invalid-config' '实例引用了不存在的 profile。' }
      foreach ($key in $profiles[$profileName].Keys) { if ($key -ne 'name') { $merged[$key] = $profiles[$profileName][$key] } }
      $overrides = ConvertTo-ConfigMap $mine[$profileName]
      foreach ($key in $overrides.Keys) { $merged[$key] = $overrides[$key] }
      $merged['kind'] = 'remote'
    }
    foreach ($key in $own.Keys) { $merged[$key] = $own[$key] }
    if (-not $merged.Contains('name') -and $profileName) { $merged['name'] = $profileName }
    Assert-InstanceName ([string]$merged['name'])
    if (-not $merged.Contains('kind')) { $merged['kind'] = if ($merged['sshHost']) { 'remote' } else { 'local' } }
    foreach ($key in @('enabled','autoInstall','stopRemoteService')) { if (-not $merged.Contains($key)) { $merged[$key] = $true } }
    if (-not $merged.Contains('displayName') -or -not $merged['displayName']) { $merged['displayName'] = $merged['name'] }
    if (-not $merged.Contains('description')) { $merged['description'] = '' }
    if ($merged['kind'] -eq 'remote') {
      if (-not $merged['sshHost']) { Throw-LauncherError 'invalid-config' '远端实例必须提供 sshHost 或有效 profile。' }
      if (-not $merged.Contains('remotePort')) { $merged['remotePort'] = 3080 }
      if (-not $merged.Contains('localPort')) { $merged['localPort'] = 3099 }
      $bind = [int]$merged['localPort']
      # A user service has one fixed unit name. Two cards for the same known
      # connection would otherwise start/stop each other's sessions.
      $unitKey = '{0}|{1}|{2}|{3}' -f $merged['sshHost'], $merged['sshUser'], $merged['runAsUser'], $(if ($merged['sshPort']) { $merged['sshPort'] } else { 22 })
      if ($remoteUnits.ContainsKey($unitKey)) { Throw-LauncherError 'invalid-config' '同一 SSH 用户连接只能登记一个 dsh-web 服务；请使用独立用户账户，不要重复登记同一服务。' }
      $remoteUnits[$unitKey] = $true
    } else {
      if (-not $merged.Contains('port')) { $merged['port'] = 3080 }
      $bind = [int]$merged['port']
    }
    Assert-ConfigFields $merged
    if ($names.ContainsKey([string]$merged['name'])) { Throw-LauncherError 'invalid-config' '实例 name 重复（不区分大小写）。' }
    $names[[string]$merged['name']] = $true
    if ($merged['enabled']) {
      if ($localPorts.ContainsKey($bind)) { Throw-LauncherError 'invalid-config' '启用实例的本地监听端口重复。' }
      $localPorts[$bind] = $true
    }
    $expanded += [pscustomobject]$merged
  }
  return [pscustomobject]@{ version = 1; instances = @($expanded); profiles = $profiles }
}
function Get-HostsConfig([string]$ConfigPath) {
  $path = Resolve-ConfigPath $ConfigPath
  if (-not (Test-Path -LiteralPath $path)) { return Get-DefaultHosts }
  try { $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Throw-LauncherError 'invalid-config' '配置不是有效的 JSON，未修改文件。' }
  $null = Get-NormalizedConfig $cfg
  return $cfg
}
function Save-HostsConfig($Cfg, [string]$ConfigPath) {
  $null = Get-NormalizedConfig $Cfg
  $path = Resolve-ConfigPath $ConfigPath
  $guard = Enter-LauncherLock ('config:' + $path)
  try { Write-AtomicJson $path $Cfg } finally { Exit-LauncherLock $guard }
}
function Get-Profiles([string]$ConfigPath) { return (Get-NormalizedConfig (Get-HostsConfig $ConfigPath)).profiles }
function Get-Instances([string[]]$Names, [string]$ConfigPath, [switch]$IncludeDisabled) {
  $all = @((Get-NormalizedConfig (Get-HostsConfig $ConfigPath)).instances)
  if (-not $Names -or @($Names).Count -eq 0) {
    return @($all | Where-Object { $IncludeDisabled -or $_.enabled })
  }
  $seen = @{}
  foreach ($name in (Expand-TargetNames $Names)) {
    $hit = @($all | Where-Object { $_.name -eq $name })
    if ($hit.Count -eq 0) { Throw-LauncherError 'unknown-instance' "unknown instance '$name'（使用 list 查看登记）。" }
    if (-not $seen.ContainsKey($name)) { $seen[$name] = $true; $hit[0] }
  }
}
function Expand-TargetNames([string[]]$Names) {
  $seen = @{}
  foreach ($value in @($Names)) {
    foreach ($piece in ([string]$value -split ',')) {
      $name = $piece.Trim()
      if ($name -and -not $seen.ContainsKey($name)) { Assert-InstanceName $name; $seen[$name] = $true; $name }
    }
  }
}
