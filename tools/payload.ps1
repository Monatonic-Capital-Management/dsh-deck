# Shared build/verification logic. No process launch or file writes on import.
function Get-PayloadFiles([string]$Root) {
  $manifest = Get-Content (Join-Path $Root 'tools\payload.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($manifest.version -ne 1) { throw 'Unsupported payload manifest version' }
  $files = @($manifest.files)
  foreach ($property in $manifest.directories.PSObject.Properties) {
    $directory = Join-Path $Root $property.Name
    if (-not (Test-Path $directory -PathType Container)) { throw "Missing payload directory: $($property.Name)" }
    $found = @(Get-ChildItem $directory -Recurse -File | Where-Object { $property.Value -contains $_.Extension })
    if (-not $found.Count) { throw "Empty payload directory: $($property.Name)" }
    foreach ($file in $found) { $files += $file.FullName.Substring($Root.TrimEnd('\','/').Length + 1).Replace('\','/') }
  }
  $result = @($files | Sort-Object -Unique)
  foreach ($relative in $result) {
    if ($relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$))') { throw 'Payload paths must remain in the checkout' }
    if (-not (Test-Path (Join-Path $Root $relative) -PathType Leaf)) { throw "Missing payload: $relative" }
  }
  return $result
}

function Get-PackageResources([string]$Root) {
  $resources = [ordered]@{}
  foreach ($relative in @(Get-PayloadFiles $Root)) { $resources["payload/$relative"] = Join-Path $Root $relative }
  foreach ($relative in @('tools/exe/DshDeck.cs', 'tools/build-exe.ps1', 'tools/payload.ps1', 'tools/payload.json')) {
    $resources["build/$relative"] = Join-Path $Root $relative
  }
  return $resources
}

function Test-ResourceBytes([byte[]]$Embedded, [byte[]]$Source, [string]$Path) {
  if ([IO.Path]::GetExtension($Path) -eq '.ico') {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash($Embedded)) -ceq [Convert]::ToBase64String($sha.ComputeHash($Source)) }
    finally { $sha.Dispose() }
  }
  # Git's checkout line endings differ by OS; logical text and its BOM must match.
  return [Text.Encoding]::UTF8.GetString($Embedded).Replace("`r`n", "`n") -ceq [Text.Encoding]::UTF8.GetString($Source).Replace("`r`n", "`n")
}

function Test-Package([string]$Root, [string]$ExePath, [string]$Version = '1.0.0.0') {
  if (-not (Test-Path $ExePath -PathType Leaf)) { return [pscustomobject]@{ ok = $false; checked = 0; mismatches = @('Start.exe missing') } }
  $resources = Get-PackageResources $Root
  $bad = @()
  try {
    # Byte-array Load uses an independent context, so an older binary with the
    # same assembly identity does not shadow a rebuild in this process. Only
    # resource metadata is inspected here; the executable entry point is not run.
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($ExePath))
    $names = @($assembly.GetManifestResourceNames())
    if ($assembly.GetName().Version.ToString() -ne $Version) { $bad += 'assembly version' }
    foreach ($name in $resources.Keys) {
      if ($names -notcontains $name) { $bad += $name; continue }
      $stream = $assembly.GetManifestResourceStream($name)
      $buffer = New-Object IO.MemoryStream
      try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() }
      finally { $stream.Dispose(); $buffer.Dispose() }
      if (-not (Test-ResourceBytes $bytes ([IO.File]::ReadAllBytes($resources[$name])) $resources[$name])) { $bad += $name }
    }
    foreach ($name in $names) { if (-not $resources.Contains($name)) { $bad += "unexpected resource: $name" } }
  } catch { $bad += 'assembly/resource inspection failed' }
  return [pscustomobject]@{ ok = ($bad.Count -eq 0); checked = $resources.Count; mismatches = $bad }
}
