param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out = "$env:TEMP\quest_strip.png",
    [int]$Zoom = 2
)
# Save the exact region the ghost-quest reader looks at, so a failed OCR run can be told
# apart from a wrong crop: the box is x 82%-100%, y 9%-60% of the CLIENT area (same formula
# as Get-QuestBox in ghost_monitor.ps1, clamps included).
# The input must be a FULL client screenshot; feeding it an already-cropped strip would
# crop the strip once more.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $In).Path)
$w = $src.Width
$h = $src.Height
if ($w -lt 320 -or $h -lt 240) {
    $src.Dispose()
    Write-Output ('IMAGE_TOO_SMALL ' + $w + 'x' + $h + ' (reader needs >= 320x240)')
    exit 1
}
$bx = [int][Math]::Round($w * 0.82)
$bw = [int][Math]::Round($w * 0.18)
$by = [int][Math]::Round($h * 0.09)
$bh = [int][Math]::Round($h * 0.51)
if ($bw -lt 140) { $bw = 140 }
if ($bh -lt 200) { $bh = 200 }
if ($bx + $bw -gt $w) { $bw = $w - $bx }
if ($by + $bh -gt $h) { $bh = $h - $by }
if ($Zoom -lt 1) { $Zoom = 1 }
$ow = $bw * $Zoom
$oh = $bh * $Zoom
$bmp = New-Object System.Drawing.Bitmap $ow, $oh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $ow, $oh),
    (New-Object System.Drawing.Rectangle $bx, $by, $bw, $bh), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$src.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ('STRIP ' + $Out + ' ' + $bw + 'x' + $bh + ' @' + $bx + ',' + $by + ' zoom=' + $Zoom)
