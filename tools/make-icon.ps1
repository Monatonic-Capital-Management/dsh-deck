# make-icon.ps1 - rebuild app\icon\dsh-deck.ico from app\icon\dsh-deck.svg.
#
#   * renders the SVG at every size Windows asks for, using headless Chrome or
#     Edge (the panel already requires one of them, so this adds no new
#     dependency)
#   * packs the results into a single multi-size .ico: the classic sizes as BMP
#     entries, which is what older shell code and System.Drawing expect, and the
#     large ones as PNG entries, which Vista+ accepts and which keep the file
#     small
#
# Usage: powershell -NoProfile -File tools\make-icon.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$svgPath  = Join-Path $root 'app\icon\dsh-deck.svg'
$icoPath  = Join-Path $root 'app\icon\dsh-deck.ico'
if (-not (Test-Path $svgPath)) { throw "missing $svgPath" }

$browser = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'neither Chrome nor Edge found; cannot render the SVG' }

# A wrapper page does the scaling. Chrome screenshots the viewport, and a
# standalone .svg file is not scaled to it -- the art would be cropped instead.
# Large windows are also unreliable in headless mode, so anything above 64 px is
# rendered in a 64 px window and blown up with a device scale factor. Without
# --force-device-scale-factor a 200% display makes every screenshot half size.
$work    = Join-Path $env:TEMP ('dsh-icon-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$wrapper = Join-Path $work 'render.html'
@"
<!doctype html>
<meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
img{display:block;width:100vw;height:100vh}</style>
<img src="file:///$($svgPath -replace '\\','/')" alt="">
"@ | Set-Content -LiteralPath $wrapper -Encoding UTF8

Add-Type -AssemblyName System.Drawing

$pngSizes = @(96, 128, 256)          # packed as PNG entries
$bmpSizes = @(16, 24, 32, 48, 64)    # packed as BMP entries
$rendered = @{}

foreach ($size in $pngSizes + $bmpSizes) {
  if ($size -le 64) { $window = $size; $scale = 1 } else { $window = 64; $scale = $size / 64 }
  $out = Join-Path $work "icon-$size.png"
  $profile = Join-Path $work "profile-$size"
  $chromeArgs = @(
    '--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars',
    "--force-device-scale-factor=$scale", "--user-data-dir=$profile",
    '--default-background-color=00000000', "--screenshot=$out",
    "--window-size=$window,$window", "file:///$($wrapper -replace '\\','/')"
  )
  $proc = Start-Process -FilePath $browser -ArgumentList $chromeArgs -PassThru -Wait -WindowStyle Hidden
  if (-not (Test-Path $out)) { throw "browser produced no screenshot for ${size}px (exit $($proc.ExitCode))" }
  $img = [System.Drawing.Bitmap]::FromFile($out)
  if ($img.Width -ne $size -or $img.Height -ne $size) {
    $w = $img.Width; $h = $img.Height; $img.Dispose()
    throw "expected ${size}x${size} but the browser produced ${w}x${h}"
  }
  $rendered[$size] = $img
  Write-Host ("  rendered {0,3} x {0,-3} ({1:N0} bytes)" -f $size, (Get-Item $out).Length)
}

function ConvertTo-BmpEntry([System.Drawing.Bitmap]$Bitmap) {
  <# One BITMAPINFOHEADER + bottom-up 32bpp pixels + an empty (opaque) AND mask,
     which is what an .ico entry looked like before PNG entries existed. #>
  $w = $Bitmap.Width; $h = $Bitmap.Height
  $maskStride = [int]([math]::Floor((($w + 31) / 32)) * 4)
  $maskBytes  = $maskStride * $h
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([UInt32]40); $bw.Write([Int32]$w); $bw.Write([Int32]($h * 2))
  $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
  $bw.Write([UInt32]($w * $h * 4)); $bw.Write([Int32]0); $bw.Write([Int32]0)
  $bw.Write([UInt32]0); $bw.Write([UInt32]0)
  for ($y = $h - 1; $y -ge 0; $y--) {
    for ($x = 0; $x -lt $w; $x++) {
      $c = $Bitmap.GetPixel($x, $y)
      $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
    }
  }
  $bw.Write((New-Object byte[] $maskBytes))
  $bw.Flush()
  $bytes = $ms.ToArray()
  $bw.Dispose(); $ms.Dispose()
  # The comma matters: returning a byte[] unwrapped would enumerate it into an
  # object[] and the caller would then write one element per call instead of the
  # whole block.
  return ,$bytes
}

$entries = @()
foreach ($size in $bmpSizes) { $entries += [pscustomobject]@{ Size = $size; Bytes = (ConvertTo-BmpEntry $rendered[$size]) } }
foreach ($size in $pngSizes) {
  $ms = New-Object System.IO.MemoryStream
  $rendered[$size].Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $entries += [pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() }
  $ms.Dispose()
}
foreach ($img in $rendered.Values) { $img.Dispose() }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
  $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([UInt16]1); $bw.Write([UInt16]32)
  $bw.Write([UInt32]$e.Bytes.Length); $bw.Write([UInt32]$offset)
  $offset += $e.Bytes.Length
}
foreach ($e in $entries) { $bw.Write([byte[]]$e.Bytes) }
$bw.Flush()
[IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("wrote {0} ({1:N0} bytes, {2} sizes)" -f $icoPath, (Get-Item $icoPath).Length, $entries.Count)
