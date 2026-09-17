# Node, dsh discovery and software changes. No work is done on import.
function Compare-Version([string]$A, [string]$B) {
  $aParts = ($A -replace '^v', '' -split '\+', 2)[0] -split '-', 2
  $bParts = ($B -replace '^v', '' -split '\+', 2)[0] -split '-', 2
  $aCore = @($aParts[0] -split '\.'); $bCore = @($bParts[0] -split '\.')
  for ($i = 0; $i -lt 3; $i++) {
    $x = if ($i -lt $aCore.Count -and $aCore[$i] -match '^\d+$') { [long]$aCore[$i] } else { 0 }
    $y = if ($i -lt $bCore.Count -and $bCore[$i] -match '^\d+$') { [long]$bCore[$i] } else { 0 }
    if ($x -gt $y) { return 1 }; if ($x -lt $y) { return -1 }
  }
  if ($aParts.Count -eq 1 -and $bParts.Count -eq 1) { return 0 }
  if ($aParts.Count -eq 1) { return 1 }; if ($bParts.Count -eq 1) { return -1 }
  $aPre = @($aParts[1] -split '\.'); $bPre = @($bParts[1] -split '\.')
  for ($i = 0; $i -lt [Math]::Max($aPre.Count, $bPre.Count); $i++) {
    if ($i -ge $aPre.Count) { return -1 }; if ($i -ge $bPre.Count) { return 1 }
    $x = $aPre[$i]; $y = $bPre[$i]
    if ($x -ceq $y) { continue }
    if ($x -match '^\d+$' -and $y -match '^\d+$') { if ([long]$x -gt [long]$y) { return 1 }; return -1 }
    if ($x -match '^\d+$') { return -1 }; if ($y -match '^\d+$') { return 1 }
    return [Math]::Sign([string]::CompareOrdinal($x, $y))
  }
  return 0
}
function Get-ManagedNodeRoot {
  $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path (Get-HomeDir) 'AppData\Local' }
  return Join-Path $base 'dsh-deck\node'
}
function Get-ManagedNode {
  $root = Get-ManagedNodeRoot
  if (-not (Test-Path -LiteralPath $root)) { return $null }
  $selected = $null; $version = ''
  foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    if ($dir.Name -notmatch '^v\d+\.\d+\.\d+$') { continue }
    $exe = Join-Path $dir.FullName 'node.exe'
    if ((Test-Path -LiteralPath $exe) -and (-not $selected -or (Compare-Version $dir.Name $version) -gt 0)) { $selected = $exe; $version = $dir.Name }
  }
  return $selected
}
function Get-NodeExe {
  $managed = Get-ManagedNode
  if ($managed) { return $managed }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  if ($env:ProgramFiles) {
    $candidate = Join-Path $env:ProgramFiles 'nodejs\node.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $null
}
function Get-NodeVersionOf([string]$NodeExe) {
  if (-not $NodeExe -or -not (Test-Path -LiteralPath $NodeExe)) { return '' }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = (& $NodeExe -v 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prev }
  if ($code -eq 0 -and $out -match '^v?\d+\.\d+\.\d+$') { return $out }
  return ''
}
function Test-NodeUsable([string]$NodeExe, [switch]$ReadOnly) {
  if (-not $NodeExe -or -not (Test-Path -LiteralPath $NodeExe)) { return $false }
  if ($ReadOnly) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $NodeExe; $psi.Arguments = '-'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $psi
    try {
      $null = $process.Start()
      $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
      $process.StandardInput.WriteLine('const c=require("crypto");if(c.createHash("sha256").update("dsh-probe").digest("hex")==="70129bc805718e0a482fd67713218dfde822b3c9df861c95e16ed3d4a68b697b")console.log("NODE_OK");else process.exit(4)')
      $process.StandardInput.Close()
      if (-not $process.WaitForExit(8000)) { $process.Kill(); return $false }
      return ($process.ExitCode -eq 0 -and $out.Result.Trim() -eq 'NODE_OK')
    } catch { return $false } finally { $process.Dispose() }
  }
  $probeFile = Join-Path ([IO.Path]::GetTempPath()) ('dsh-node-probe-' + [guid]::NewGuid().ToString('N') + '.js')
  $probe = @'
const crypto = require("crypto");
const expected = "70129bc805718e0a482fd67713218dfde822b3c9df861c95e16ed3d4a68b697b";
if (crypto.createHash("sha256").update("dsh-probe").digest("hex") !== expected) process.exit(4);
process.stdout.write("NODE_OK " + process.version);
'@
  try {
    [IO.File]::WriteAllText($probeFile, $probe, (New-Object Text.UTF8Encoding($false)))
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $NodeExe $probeFile 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return ($code -eq 0 -and $out -match '^NODE_OK v\d+\.\d+\.\d+')
  } catch { return $false }
  finally { if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force } }
}
function Copy-NodeDistributionFile([string]$Root, [string]$Name, [string]$Destination) {
  if (Test-Path -LiteralPath $Root -PathType Container) { Copy-Item -LiteralPath (Join-Path $Root $Name) -Destination $Destination; return }
  if ($Root -notmatch '^https?://') { throw 'distribution file not found' }
  $previous = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try { Invoke-WebRequest -Uri ($Root.TrimEnd('/') + '/' + $Name) -OutFile $Destination -UseBasicParsing -TimeoutSec 180 }
  finally { $ProgressPreference = $previous }
}
function Ensure-ManagedNode {
  param([switch]$Quiet, [switch]$Force)
  $existing = Get-ManagedNode
  if ($existing -and -not $Force) {
    $v = Get-NodeVersionOf $existing
    if ($v -and (Compare-Version $v $script:NodeMinVersion) -ge 0 -and (Test-NodeUsable $existing)) { return $existing }
  }
  $version = $script:ManagedNodeVersion
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  $stem = "node-$version-win-$arch"; $zipName = "$stem.zip"
  $root = Join-Path (Get-ManagedNodeRoot) $version
  $dest = Join-Path $root 'node.exe'
  if (Test-Path -LiteralPath $dest) {
    $active = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object { $_.ExecutablePath -eq $dest })
    if ($active.Count) { Write-Err 'managed Node is in use; stop dsh and the panel before replacing it'; return $null }
  }
  $baseUrl = if ($env:DSH_NODE_MIRROR) { $env:DSH_NODE_MIRROR } else { "https://nodejs.org/dist/$version" }
  Write-Info "downloading Node $version ($arch) into the per-user managed runtime"
  $staging = Join-Path ([IO.Path]::GetTempPath()) ('dsh-node-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    $zip = Join-Path $staging $zipName; $sums = Join-Path $staging 'SHASUMS256.txt'
    try { Copy-NodeDistributionFile $baseUrl 'SHASUMS256.txt' $sums }
    catch { Write-Err 'could not fetch the checksum list; refusing a binary that cannot be verified'; return $null }
    $expected = ''
    foreach ($line in (Get-Content -LiteralPath $sums)) {
      if ($line -match "^\s*([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($zipName))\s*$") { $expected = $Matches[1].ToLowerInvariant(); break }
    }
    if (-not $expected) { Write-Err "$zipName is not listed in the checksum file"; return $null }
    try { Copy-NodeDistributionFile $baseUrl $zipName $zip }
    catch { Write-Err 'Node download failed; no runtime was installed'; return $null }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
      Write-Err 'checksum mismatch: the download is not what nodejs.org published'; return $null
    }
    Write-Info 'checksum verified'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unpack = Join-Path $staging 'unpack'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpack)
    $inner = Join-Path $unpack $stem
    $candidate = Join-Path $inner 'node.exe'
    $got = Get-NodeVersionOf $candidate
    if (-not $got -or (Compare-Version $got $script:NodeMinVersion) -lt 0 -or -not (Test-NodeUsable $candidate) -or -not (Test-Path -LiteralPath (Join-Path $inner 'npm.cmd'))) {
      Write-Err 'the downloaded Node/npm did not pass the runtime checks'; return $null
    }
    $parent = Split-Path -Parent $root
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $root) {
      $backup = Join-Path $parent ('.previous-' + [guid]::NewGuid().ToString('N'))
      Move-Item -LiteralPath $root -Destination $backup
      Write-Warn2 'the previous managed runtime was retained in a .previous directory'
    }
    Move-Item -LiteralPath $inner -Destination $root
    if (-not $Quiet) { Write-Ok "Node $got installed (npm included)" }
    return $dest
  } finally { Remove-Item -LiteralPath $staging -Recurse -Force }
}
function Get-NpmExe([string]$NodeExe) {
  if ($NodeExe) {
    foreach ($name in @('npm.cmd','npm.exe')) {
      $candidate = Join-Path (Split-Path -Parent $NodeExe) $name
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  }
  $cmd = Get-Command npm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return ''
}
function Find-DshLocal {
  $prefixes = @()
  $managed = Get-ManagedNode
  if ($managed) { $prefixes += Split-Path -Parent $managed }
  if ($env:NPM_CONFIG_PREFIX) { $prefixes += $env:NPM_CONFIG_PREFIX }
  $npmrc = Join-Path (Get-HomeDir) '.npmrc'
  if (Test-Path -LiteralPath $npmrc) {
    foreach ($line in (Get-Content -LiteralPath $npmrc -ErrorAction SilentlyContinue)) {
      if ($line -match '^\s*prefix\s*=\s*(.+?)\s*$') { $prefixes += $Matches[1].Trim('"') }
    }
  }
  if ($env:APPDATA) { $prefixes += Join-Path $env:APPDATA 'npm' }
  foreach ($prefix in $prefixes) {
    $candidate = Join-Path $prefix 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $npm = Get-NpmExe (Get-NodeExe)
  if ($npm) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $npmRoot = & $npm root -g 2>$null | Select-Object -First 1 } finally { $ErrorActionPreference = $prev }
    if ($npmRoot) {
      $candidate = Join-Path ([string]$npmRoot) '@deepseek-ai\dsh\lib\bin.js'
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  }
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}
function Get-LocalDshVersion {
  if ($script:LocalDshVersion) { return $script:LocalDshVersion }
  $version = ''; $bin = Find-DshLocal; $node = Get-NodeExe
  if ($bin -and $node) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $previousPath = $env:PATH
    try {
      $env:PATH = (Split-Path -Parent $node) + ';' + $previousPath
      if ($bin -match '\.js$') { $out = & $node $bin --version 2>&1 | Out-String }
      else { $out = & $bin --version 2>&1 | Out-String }
      if ($LASTEXITCODE -eq 0 -and $out.Trim() -match '^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$') { $version = $Matches[1] }
    } catch { } finally { $ErrorActionPreference = $prev; $env:PATH = $previousPath }
  }
  $script:LocalDshVersion = $version
  return $version
}
function Get-LatestDshVersion([switch]$Refresh, [switch]$ReadOnly) {
  $memo = Get-Variable -Name DshLatestResolution -Scope Script -ErrorAction SilentlyContinue
  if (-not $Refresh -and $memo -and $memo.Value) { return [string]$memo.Value.version }
  $cacheFile = Join-Path $StateDir 'latest-version.json'; $cached = ''; $fresh = $false
  if (Test-Path -LiteralPath $cacheFile) {
    try {
      $data = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $cached = [string]$data.version; Assert-DshVersion $cached
      $fresh = ((Get-Date) - [datetime]$data.checkedAt).TotalHours -lt 6
    } catch { $cached = '' }
  }
  if ($cached -and $fresh -and -not $Refresh) { $script:DshLatestResolution = [pscustomobject]@{ version = $cached }; return $cached }
  $version = ''
  try {
    $response = Invoke-WebRequest -Uri 'https://registry.npmjs.org/@deepseek-ai/dsh' -UseBasicParsing -TimeoutSec 20
    $version = [string](($response.Content | ConvertFrom-Json).'dist-tags'.latest)
    Assert-DshVersion $version
  } catch { $version = '' }
  if ($version -and -not $ReadOnly) { Write-AtomicJson $cacheFile ([pscustomobject]@{ version = $version; checkedAt = (Get-Date).ToString('o') }) }
  $resolvedVersion = if ($version) { $version } else { $cached }
  $script:DshLatestResolution = [pscustomobject]@{ version = $resolvedVersion }
  return $resolvedVersion
}
function Get-DesiredDshVersion($Inst) { return [string](Get-InstProp $Inst 'dshVersion' '') }
function Resolve-TargetDshVersion($Inst, [switch]$ReadOnly, [switch]$Refresh) {
  $pin = Get-DesiredDshVersion $Inst
  if ($pin) { Assert-DshVersion $pin; return [pscustomobject]@{ target = $pin; pinned = $pin; latest = ''; source = 'pin' } }
  $latest = Get-LatestDshVersion -ReadOnly:$ReadOnly -Refresh:$Refresh
  return [pscustomobject]@{ target = $latest; pinned = ''; latest = $latest; source = 'latest' }
}
function Get-UpdateStatus($Inst, [string]$LocalOrRemoteVersion) {
  $resolved = Resolve-TargetDshVersion $Inst -ReadOnly
  $current = [string]$LocalOrRemoteVersion
  $reason = 'current'; $available = $false
  if (-not $current) { $reason = 'unknown-current' }
  elseif (-not $resolved.target) { $reason = 'unknown-latest' }
  elseif ((Compare-Version $resolved.target $current) -ne 0) {
    $available = [bool]($resolved.pinned -or (Compare-Version $resolved.target $current) -gt 0)
    $reason = if ($resolved.pinned) { 'pin-mismatch' } else { 'version-difference' }
  }
  return [pscustomobject]@{ current = $current; latest = $resolved.latest; pinned = $resolved.pinned; target = $resolved.target; updateAvailable = $available; reason = $reason }
}
function Assert-LocalPins([string]$TargetVersion) {
  $locals = @(Get-Instances $null $Config -IncludeDisabled | Where-Object { $_.kind -eq 'local' })
  $pins = @($locals | ForEach-Object { Get-DesiredDshVersion $_ } | Where-Object { $_ } | Select-Object -Unique)
  if ($pins.Count -gt 1 -or ($TargetVersion -and $pins.Count -eq 1 -and $pins[0] -ne $TargetVersion)) {
    Throw-LauncherError 'local-pin-conflict' '本地实例共享 dsh runtime，但版本固定互相冲突。请先统一所有本地实例的 dshVersion。'
  }
}
function Assert-LocalRuntimeStopped {
  $bin = Find-DshLocal
  if (-not $bin) { return }
  try { $processes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop) }
  catch { Throw-LauncherError 'ownership-unknown' '无法核对本地进程归属，拒绝修改共享 runtime。' }
  foreach ($process in $processes) {
    if (Test-DshProcessRecord $process $bin) { Throw-LauncherError 'local-running' '本地 dsh 正在运行，不能安全升级共享 runtime；请先停止所有本地 dsh 实例再执行 upgrade。' }
  }
}
function Get-InstallNode([switch]$Quiet) {
  $node = Get-NodeExe; $version = Get-NodeVersionOf $node
  if (-not $node -or -not $version -or (Compare-Version $version $script:NodeMinVersion) -lt 0 -or -not (Test-NodeUsable $node)) {
    Write-Info 'no usable Node found; dsh needs Node >= 22.19.0'
    $node = Ensure-ManagedNode -Quiet:$Quiet
    if (-not $node) { Write-Err 'could not provide a Node runtime; install Node.js 22.19+ from https://nodejs.org/en/download and retry'; return $null }
  }
  return $node
}
function Invoke-NpmGlobal([string]$Spec, [switch]$Force, [string]$NpmExe) {
  $arguments = @('install','-g',$Spec,'--no-fund','--no-audit')
  if ($Force) { $arguments += '--force' }
  if (-not $NpmExe) { $NpmExe = Get-NpmExe (Get-NodeExe) }
  if (-not $NpmExe) { Write-Err 'npm not found'; return $false }
  $previousPath = $env:PATH; $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $env:PATH = (Split-Path -Parent $NpmExe) + ';' + $previousPath
    $out = & $NpmExe @arguments 2>&1 | Out-String; $code = $LASTEXITCODE
  } finally { $env:PATH = $previousPath; $ErrorActionPreference = $prev }
  $script:LocalDshVersion = ''; $after = Get-LocalDshVersion
  $wanted = if ($Spec -match '^@deepseek-ai/dsh@(.+)$') { $Matches[1] } else { '' }
  if ($code -eq 0 -and $after -and (-not $wanted -or $wanted -eq $after)) { return $true }
  foreach ($line in @($out.Trim() -split '\r?\n' | Select-Object -Last 6)) { if ($line) { Write-Diag $line } }
  Write-Err 'npm did not leave the requested working dsh; installation may be incomplete (no rollback is guaranteed)'
  return $false
}
function Install-LocalDsh($Inst, [switch]$Quiet, [string]$Version) {
  Assert-LocalPins
  $before = Get-LocalDshVersion
  if ($before) {
    if (-not $Quiet) { Write-Ok "local dsh is already installed ($before); install does not change its version" }
    return $true
  }
  if (-not $Version) { $Version = (Resolve-TargetDshVersion $Inst -ReadOnly).target }
  if (-not $Version) { Write-Err 'could not determine the target version; set dshVersion or retry when the registry is reachable'; return $false }
  Assert-LocalPins $Version
  Assert-LocalRuntimeStopped
  $node = Get-InstallNode -Quiet:$Quiet
  if (-not $node) { return $false }
  $script:LocalDshVersion = ''
  if (Get-LocalDshVersion) { return $true }
  if (Find-DshLocal) { Write-Err 'dsh is installed but does not run even with a usable Node; use explicit upgrade to repair it'; return $false }
  $npm = Get-NpmExe $node
  if (-not $npm) { Write-Err 'npm not found'; return $false }
  $spec = "@deepseek-ai/dsh@$Version"
  if (-not (Invoke-NpmGlobal $spec -NpmExe $npm)) {
    Write-Warn2 'the install did not leave a working dsh; retrying with --force'
    if (-not (Invoke-NpmGlobal $spec -NpmExe $npm -Force)) { return $false }
  }
  if (-not $Quiet) { Write-Ok "local dsh installed ($Version); not started" }
  return $true
}
function Upgrade-LocalDsh([string]$Version, [switch]$DryRun, $Inst) {
  if (-not $Version) { $Version = (Resolve-TargetDshVersion $Inst -ReadOnly).target }
  if (-not $Version) { Write-Err 'could not determine the target version'; return $false }
  Assert-DshVersion $Version; Assert-LocalPins $Version
  if ((Get-LocalDshVersion) -eq $Version) { return $true }
  if ($DryRun) { return $true }
  Assert-LocalRuntimeStopped
  $node = Get-InstallNode
  if (-not $node) { return $false }
  $npm = Get-NpmExe $node
  if (-not (Invoke-NpmGlobal "@deepseek-ai/dsh@$Version" -NpmExe $npm)) { return $false }
  Write-Ok "local dsh installed version is now $Version; no service was started"
  return $true
}
function Invoke-NodePath([switch]$Ensure, [switch]$Force) {
  $chosen = Get-NodeExe; $failed = $false
  if ($Ensure) {
    $version = Get-NodeVersionOf $chosen
    if ($Force -or -not $version -or (Compare-Version $version $script:NodeMinVersion) -lt 0 -or -not (Test-NodeUsable $chosen)) {
      $chosen = Ensure-ManagedNode -Force:$Force
      $failed = -not $chosen
    }
  }
  $version = Get-NodeVersionOf $chosen
  $result = [pscustomobject]@{ ok = [bool]($version -and (Compare-Version $version $script:NodeMinVersion) -ge 0 -and (Test-NodeUsable $chosen)); node = [string]$chosen; version = $version; managed = [bool]($chosen -and $chosen -eq (Get-ManagedNode)); root = (Get-ManagedNodeRoot); minimum = $script:NodeMinVersion; ensureFailed = $failed; requiredFor = 'panel and dsh' }
  if ($Json) { Write-Json $result } else { Write-Info "Node $version; minimum $($script:NodeMinVersion)" }
  if ($failed) { $script:ExitCode = 1 }
}
