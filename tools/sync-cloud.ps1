# Publish the release that was just built into a small staging folder, then bring the Baidu Pan
# client up so the files can go to the shared folder. Baidu Pan has no command line uploader and
# its web API hands out no upload token to a script, so the client is the only way up; this
# script does everything that can be automated (staging, cleaning, launching, opening the
# folder) and leaves the drop itself to the client window.
#
# Layout of the staging folder (only the newest release is kept - the same "one version in dist"
# rule as the release folder):
#   CHANGELOG.md                    version record (kept for reading, not used by the checker)
#   <name>_v<version>.zip           the package
#   <name>_v<version>.exe           single-file build, when it exists
#
# app\ocr\update_toolbox.ps1 reads that folder through the anonymous share listing and takes the
# version from the file name: Baidu Pan answers the listing after the access code is submitted
# but refuses anonymous downloads (sharedownload answers errno=118), so the name is the only
# public fact about a release.
#
# Where the files end up is "My Drive / MengHuanToolbox" in the share; the share path and its
# code live in app\ocr\update_toolbox.ps1, so changing the share means editing that default, the
# GUI drop target and the README together.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-cloud.ps1
#   powershell ... -DistDir dist-test -CloudDir D:\Somewhere -NoOpen
#
# ASCII only, like the other tool scripts.
param(
    [string]$DistDir = 'dist',
    [string]$CloudDir = '',
    [string]$Version = '',
    [string]$TopName = '',
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Compare-Version {
    param([string]$A, [string]$B)
    if ($A -eq $B) { return 0 }
    $pa = $A.Split('.')
    $pb = $B.Split('.')
    $n = [Math]::Max($pa.Length, $pb.Length)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $pa.Length) { [void][int]::TryParse($pa[$i], [ref]$x) }
        if ($i -lt $pb.Length) { [void][int]::TryParse($pb[$i], [ref]$y) }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# Same name as the release: the biggest .hta under app\ (a stray test file would be smaller).
if ($TopName -eq '') {
    $hta = Get-ChildItem -Path (Join-Path $root 'app\*.hta') -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($null -eq $hta) {
        Write-Output 'Cloud  : skipped, no .hta under app\ to name the release after'
        exit 0
    }
    $TopName = $hta.BaseName
}

if ($Version -eq '') {
    $notesFile = Join-Path $root 'CHANGELOG.md'
    if (Test-Path -LiteralPath $notesFile) {
        foreach ($line in (Get-Content -LiteralPath $notesFile -Encoding UTF8)) {
            if ($line -match '^##\s+v?([0-9][0-9A-Za-z._-]*)') { $Version = $Matches[1]; break }
        }
    }
}
if ($Version -eq '') {
    Write-Output 'Cloud  : skipped, no version in CHANGELOG.md'
    exit 0
}

if ($CloudDir -eq '') { $CloudDir = Join-Path $root 'dist\_cloud' }
$dist = Join-Path $root $DistDir
$notes = Join-Path $root 'CHANGELOG.md'
$zipPath = Join-Path $dist ($TopName + '_v' + $Version + '.zip')
$exePath = Join-Path $dist ($TopName + '_v' + $Version + '.exe')

if (-not (Test-Path -LiteralPath $CloudDir)) {
    New-Item -ItemType Directory -Path $CloudDir -Force | Out-Null
}

# Old releases go first so the client deletes them in the cloud too: the folder must never offer
# two versions, or somebody grabbing the wrong file becomes a support question.
$removed = 0
foreach ($f in @(Get-ChildItem -LiteralPath $CloudDir -File -ErrorAction SilentlyContinue)) {
    if ($f.Name -notmatch '_v([0-9][0-9A-Za-z._-]*)\.(zip|exe)$') { continue }
    if ((Compare-Version $Matches[1] $Version) -eq 0) { continue }
    Remove-Item -LiteralPath $f.FullName -Force
    $removed++
}

$synced = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $notes) {
    Copy-Item -LiteralPath $notes -Destination (Join-Path $CloudDir 'CHANGELOG.md') -Force
    $synced.Add('CHANGELOG.md')
}
if (Test-Path -LiteralPath $zipPath) {
    Copy-Item -LiteralPath $zipPath -Destination (Join-Path $CloudDir (Split-Path -Leaf $zipPath)) -Force
    $synced.Add((Split-Path -Leaf $zipPath))
}
if (Test-Path -LiteralPath $exePath) {
    Copy-Item -LiteralPath $exePath -Destination (Join-Path $CloudDir (Split-Path -Leaf $exePath)) -Force
    $synced.Add((Split-Path -Leaf $exePath))
}

if ($synced.Count -eq 0) {
    Write-Output ('Cloud  : nothing to publish for v' + $Version + ' yet (build the release first)')
    exit 0
}
Write-Output ('Cloud  : ' + $CloudDir)
Write-Output ('Cloud  : published v' + $Version + ' -> ' + ($synced -join ', '))
if ($removed -gt 0) { Write-Output ('Cloud  : removed ' + $removed + ' older release file(s)') }

if ($NoOpen) {
    Write-Output 'Cloud  : folder ready (-NoOpen, the client was not touched)'
    exit 0
}

# ---- bring the client up and show the folder
# The client path is taken from the running process first (that is the copy the user is logged
# in with), then from the usual install locations, then from the uninstall record.
function Find-PanExe {
    $running = @(Get-Process -Name 'BaiduNetdisk' -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    if ($running.Count -gt 0) { return $running[0].Path }
    $cands = @(
        (Join-Path $env:ProgramFiles 'Baidu\BaiduNetdisk\BaiduNetdisk.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Baidu\BaiduNetdisk\BaiduNetdisk.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Baidu\BaiduNetdisk\BaiduNetdisk.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $loc = ''
            try {
                $loc = [string](Get-ItemProperty -Path $key.PSPath -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
            } catch { }
            if ($loc -match 'BaiduNetdisk') {
                $exe = Join-Path $loc 'BaiduNetdisk.exe'
                if (Test-Path -LiteralPath $exe) { return $exe }
            }
        }
    }
    return ''
}

$panExe = Find-PanExe
$running = @(Get-Process -Name 'BaiduNetdisk' -ErrorAction SilentlyContinue).Count -gt 0
if (-not $running) {
    if ($panExe -eq '') {
        Write-Output 'Cloud  : the Baidu Pan client was not found - install it, or copy the files by hand'
    } else {
        try {
            Start-Process -FilePath $panExe | Out-Null
            Write-Output ('Cloud  : started the Baidu Pan client (' + $panExe + ')')
        } catch {
            Write-Output ('Cloud  : could not start the client (' + $_.Exception.Message + ')')
        }
    }
} else {
    Write-Output 'Cloud  : the Baidu Pan client is already running'
}

try {
    Start-Process -FilePath 'explorer.exe' -ArgumentList $CloudDir | Out-Null
    Write-Output 'Cloud  : opened the staging folder'
} catch { }

Write-Output 'Cloud  : in the client, open  My Drive / MengHuanToolbox  and drop the files above into it'
Write-Output 'Cloud  : (Baidu Pan offers no command line uploader; that last drop is the only manual step)'
exit 0
