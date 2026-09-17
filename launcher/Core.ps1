# Shared helpers. Dot-sourcing this file performs no I/O.
function Protect-Text([string]$Text) {
  $safe = $Text -replace '(?i)(https?://[^\s?#"''<>]+)[?#][^\s"''<>]*', '$1?[redacted]'
  $safe = $safe -replace '(?i)(Bearer\s+)\S+', '$1[redacted]'
  $safe = $safe -replace '(?i)((?:token|api[_-]?key|password|secret|cookie|authorization)"?\s*[:=]\s*)(?:"[^"\r\n]*"|[^\s,;]+)', '$1[redacted]'
  return ($safe -replace '\bsk-[A-Za-z0-9_-]+', '[redacted]')
}

function Write-C([string]$Text, [string]$Color = 'Gray') {
  $safe = Protect-Text $Text
  if ($script:JsonMode) { [Console]::Error.WriteLine($safe); return }
  if ($script:UseColor) { Write-Host $safe -ForegroundColor $Color } else { Write-Host $safe }
}
function Write-Head([string]$Text) { Write-C "  $Text" 'Cyan' }
function Write-Diag([string]$Text, [string]$Color = 'Gray') { Write-C $Text $Color }
function Write-Ok([string]$Text) { Write-Diag "  [ok]   $Text" 'Green' }
function Write-Warn2([string]$Text) { Write-Diag "  [warn] $Text" 'Yellow' }
function Write-Info([string]$Text) { Write-Diag "  [info] $Text" }
function Write-Err([string]$Text) {
  $script:LastFailure = Protect-Text $Text
  Write-Diag "  [fail] $Text" 'Red'
}
function Write-Log([string]$Message) {
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content -LiteralPath (Join-Path $LogDir 'launcher.log') -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Protect-Text $Message))
  } catch { }
}
function Write-Json($Obj) { ConvertTo-Json -InputObject $Obj -Depth 20 -Compress | Write-Output }
function Throw-LauncherError([string]$Code, [string]$Message) {
  $err = New-Object InvalidOperationException (Protect-Text $Message)
  $err.Data['errorCode'] = $Code
  throw $err
}
function Get-ErrorCode($ErrorRecord) {
  if ($ErrorRecord.Exception.Data.Contains('errorCode')) { return [string]$ErrorRecord.Exception.Data['errorCode'] }
  return 'operation-failed'
}
function Get-ContextKey([string]$Value) {
  $hash = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())))).Replace('-', '') }
  finally { $hash.Dispose() }
}
function Enter-LauncherLock([string]$Key) {
  $mutex = New-Object Threading.Mutex($false, ('Local\DshDeck-' + (Get-ContextKey $Key)))
  $owned = $false
  try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Throw-LauncherError 'busy' '另一个启动器操作正在进行，请稍后重试。' }
    return $mutex
  } catch { $mutex.Dispose(); throw }
}
function Exit-LauncherLock($Mutex) {
  if ($Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
}
function Write-AtomicJson([string]$Path, $Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = Join-Path $dir ('.dsh-' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 20), (New-Object Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($tmp, $Path) }
  } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function ConvertTo-NativeArgument([string]$Value) {
  if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
  return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Join-NativeArguments([string[]]$Arguments) {
  return (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
}
function Split-NativeArguments([string]$CommandLine) {
  if (-not ('DshDeck.NativeArgs' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DshDeck {
  public static class NativeArgs {
    [DllImport("shell32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr ptr);
    public static string[] Split(string command) {
      int count; IntPtr ptr = CommandLineToArgvW(command, out count);
      if (ptr == IntPtr.Zero) return new string[0];
      try {
        var result = new string[count];
        for (int i=0; i<count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(ptr, i*IntPtr.Size));
        return result;
      } finally { LocalFree(ptr); }
    }
  }
}
'@
  }
  return [DshDeck.NativeArgs]::Split($CommandLine)
}
function Get-ProcessRecord([int]$ProcId) {
  if ($ProcId -le 0) { return $null }
  try { return Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop } catch { return $null }
}
function Get-ProcessStamp($ProcessRecord) {
  if (-not $ProcessRecord) { return '' }
  try { return ([datetime]$ProcessRecord.CreationDate).ToUniversalTime().ToString('o') } catch { return '' }
}
function Test-ProcessAlive([int]$ProcId) {
  if ($ProcId -le 0) { return $false }
  try { return [bool](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop) } catch { return $true }
}
function Get-ProcessNameSafe([int]$ProcId) {
  if ($ProcId -le 0) { return '' }
  $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
  if ($p) { return $p.ProcessName }
  return ''
}
function Stop-OwnedProcess([int]$ProcId, [string]$Stamp) {
  if (-not (Test-ProcessAlive $ProcId)) { return $true }
  $p = Get-ProcessRecord $ProcId
  if (-not $p -or -not $Stamp -or (Get-ProcessStamp $p) -ne $Stamp) { return $false }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $null = & taskkill.exe /PID $ProcId /T /F 2>&1 } finally { $ErrorActionPreference = $prev }
  $until = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $until -and (Test-ProcessAlive $ProcId)) { Start-Sleep -Milliseconds 150 }
  return (-not (Test-ProcessAlive $ProcId))
}
function Get-NetstatListeners {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $text = & netstat.exe -ano -p tcp 2>&1 } finally { $ErrorActionPreference = $prev }
  foreach ($line in $text) {
    if ($line -notmatch '^\s*TCP\s+(\S+):(\d+)\s+(\S+)\s+\S+\s+(\d+)\s*$') { continue }
    $address = $Matches[1]; $portValue = [int]$Matches[2]; $foreign = $Matches[3]; $owner = [int]$Matches[4]
    if ($foreign -match ':0$') { [pscustomobject]@{ Address = $address; Port = $portValue; Pid = $owner } }
  }
}
function Get-ListeningPid([int]$PortValue) {
  $row = Get-NetstatListeners | Where-Object { $_.Port -eq $PortValue -and $_.Address -in @('127.0.0.1','[::1]') } | Select-Object -First 1
  if ($row) { return [int]$row.Pid }
  return 0
}
function Test-PortListening([int]$PortValue) {
  try {
    foreach ($ep in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
      if ($ep.Port -eq $PortValue -and $ep.Address.ToString() -in @('127.0.0.1','::1','0.0.0.0','::')) { return $true }
    }
    return $false
  } catch { return ((Get-ListeningPid $PortValue) -gt 0) }
}
function Find-FreePort([int]$Start) {
  for ($candidate = $Start; $candidate -le [Math]::Min(65535, $Start + 49); $candidate++) {
    if (-not (Test-PortListening $candidate)) { return $candidate }
  }
  return 0
}
function Test-Http([string]$Url, [int]$TimeoutSec = 6) {
  try { return [int](Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 0 -TimeoutSec $TimeoutSec -ErrorAction Stop).StatusCode }
  catch { try { return [int]$_.Exception.Response.StatusCode } catch { return 0 } }
}
function Get-State([string]$InstanceName) {
  Assert-InstanceName $InstanceName
  $file = Join-Path $StateDir "$InstanceName.json"
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Set-State([string]$InstanceName, $Obj) {
  Assert-InstanceName $InstanceName
  Write-AtomicJson (Join-Path $StateDir "$InstanceName.json") $Obj
}
function Set-StateField([string]$InstanceName, [hashtable]$Fields) {
  $obj = ConvertTo-ConfigMap (Get-State $InstanceName)
  foreach ($key in $Fields.Keys) { $obj[$key] = $Fields[$key] }
  $obj['updatedAt'] = (Get-Date).ToString('o')
  Set-State $InstanceName $obj
}
function Remove-State([string]$InstanceName) {
  Assert-InstanceName $InstanceName
  $file = Join-Path $StateDir "$InstanceName.json"
  if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
