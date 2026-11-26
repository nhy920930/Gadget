# Build the release handed to other players: a ready-to-run folder plus a zip of the same tree.
#
# Whitelist approach: only the files the toolbox actually needs are packed, so local state
# (locked character id, picked read region, per-account history, IDE settings) can never leak
# into a release by accident.
#
# One release per version, named after the version only so the file names stay short (the version
# already identifies the build; a timestamp made every name ~20 characters longer):
#   dist\<name>_v<version>\
#   dist\<name>_v<version>.zip
# Rebuilding the same version replaces that release in place - a retry after a fix must not leave
# two packages of the same version behind. Other versions in dist\ stay untouched.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-release.ps1
#   powershell ... -Version 1.1.0     # only if the notes for 1.1.0 are not written yet
#   powershell ... -NoPreview         # keep the existing docs\preview.png (no window opens)
#
# Before copying anything it re-captures docs\preview.png (tools\shot-preview.ps1), so the
# picture in README.md always shows the UI that is about to ship - adding a feature and packing
# again is the whole update process for it. A capture that fails just warns: losing the preview
# must never fail a release.
#
# The version is the newest "## <version>" heading in CHANGELOG.md, and that same file ships in
# the package as the update notes - one place to edit, nothing to keep in sync.
#
# ASCII only, like the other tool scripts.
param(
    [string]$OutDir = 'dist',
    [string]$TopName = '',
    [string]$Version = '',
    [switch]$NoPreview,
    [switch]$NoCloud
)

# This script sits in tools\, so the project root is its parent folder - never the current
# working directory, or the result would depend on where it is launched from.
$root = Split-Path -Parent $PSScriptRoot

# Name the folder inside the zip after the toolbox itself, so the release is self-describing
# without hard-coding a Chinese literal here. The toolbox lives in app\ under the project root;
# pick the biggest .hta there (a stray test .hta would be far smaller).
if ($TopName -eq '') {
    $hta = Get-ChildItem -Path (Join-Path $root 'app\*.hta') -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($null -eq $hta) {
        Write-Error 'No .hta found under app\, nothing to package.'
        exit 1
    }
    $TopName = $hta.BaseName
}
if ($TopName -notmatch '^[^\\/:*?"<>|]+$') {
    Write-Error ('Base name "' + $TopName + '" contains characters that are not safe in a folder name.')
    exit 1
}

# Version: the newest section heading in CHANGELOG.md IS the current version, so the number in
# the package name can never disagree with the notes shipped inside it.
$notesFile = Join-Path $root 'CHANGELOG.md'
if ($Version -eq '') {
    if (Test-Path -LiteralPath $notesFile) {
        foreach ($line in (Get-Content -LiteralPath $notesFile -Encoding UTF8)) {
            if ($line -match '^##\s+v?([0-9][0-9A-Za-z._-]*)') { $Version = $Matches[1]; break }
        }
    }
    if ($Version -eq '') {
        Write-Error 'CHANGELOG.md is missing or has no "## <version>" section - cannot name the release.'
        exit 1
    }
} elseif (Test-Path -LiteralPath $notesFile) {
    if ($null -eq (Select-String -LiteralPath $notesFile -Pattern ('^##\s+v?' + [regex]::Escape($Version) + '(\s|$)') -ErrorAction SilentlyContinue)) {
        Write-Warning ('CHANGELOG.md has no section for ' + $Version + ' yet')
    }
}
if ($Version -notmatch '^[0-9A-Za-z._-]+$') {
    Write-Error ('Version "' + $Version + '" is not a plain number like 1.0.0.')
    exit 1
}

# ---- refresh the README preview before anything is copied -------------------
# The picture in README.md is a screenshot of the window as it opens on this machine, taken right
# now: adding a feature and packing again keeps the docs in step without a separate step to
# forget. It only replaces the file when the pixels differ, so rebuilding an unchanged UI leaves
# docs\preview.png (and the git working tree) alone.
$preview = 'kept (capture skipped)'
if ($NoPreview) {
    $preview = 'skipped (-NoPreview)'
} else {
    $shot = Join-Path $PSScriptRoot 'shot-preview.ps1'
    if (-not (Test-Path -LiteralPath $shot)) {
        $preview = 'kept (tools\shot-preview.ps1 not found)'
    } else {
        $shotOut = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $shot -Out (Join-Path $root 'docs\preview.png')
        $shotText = (@($shotOut) -join "`n")
        foreach ($l in @($shotOut)) { if ($l -ne '') { Write-Output $l } }
        if ($LASTEXITCODE -ne 0) {
            $preview = 'kept (capture failed, see PREVIEW lines above)'
        } elseif ($shotText -match 'PREVIEW file  = unchanged') {
            $preview = 'up to date (already matches this window)'
        } else {
            $preview = 'refreshed from the current window'
        }
    }
}

# A .bat carrying the "gadget-devtool" marker in its first lines is a local helper (the build
# button in the project root), never shipped: the whitelist below grabs every *.bat, and the marker
# keeps this script free of a non-ASCII file name to skip.
# Only what a player needs: the launcher, the readme (plus the screenshots it embeds), and the
# app\ folder. The developer helpers in tools\ (including this script) stay out of the release.
$patterns = @(
    '*.md',
    '*.bat',
    'docs\*.png',
    'app\*.hta',
    'app\*.html',
    'app\ocr\*.ps1',
    'app\ocr\ghost_texts.txt',
    'app\ocr_tiku.txt'
)
$skip = @('make-release.ps1')

$files = New-Object System.Collections.Generic.List[object]
foreach ($p in $patterns) {
    foreach ($f in @(Get-ChildItem -Path (Join-Path $root $p) -File -ErrorAction SilentlyContinue)) {
        if ($skip -contains $f.Name) { continue }
        if ($f.Extension -eq '.bat') {
            $head = ''
            try { $head = (@(Get-Content -LiteralPath $f.FullName -TotalCount 2 -ErrorAction Stop) -join ' ') } catch { $head = '' }
            if ($head -match 'gadget-devtool') { continue }
        }
        $files.Add($f)
    }
}
if ($files.Count -eq 0) {
    Write-Error 'Nothing matched, check that you run this from the project folder.'
    exit 1
}

$dist = Join-Path $root $OutDir
if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

# ---- stage 0: name it after the version, replace an older build of it -----
# The version alone names the release, so folder / zip / exe all stay short. Rebuilding the same
# version wipes that release first instead of piling up "-2" copies: two packages of the same
# version cannot be told apart once they are handed out.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$relName = $TopName + '_v' + $Version
$stage = Join-Path $dist $relName
$zipPath = Join-Path $dist ($relName + '.zip')
$replaced = $false
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
    $replaced = $true
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
    $replaced = $true
}

# ---- stage 1: the standalone folder -------------------------------------------
# Built first so the layout can be inspected and run in place (double-click the launcher);
# the zip is then produced from exactly this tree, so the two can never drift apart.
New-Item -ItemType Directory -Path $stage | Out-Null
$copied = 0
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $target = Join-Path $stage $rel
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $target -Force
    $copied++
}

# ---- stage 2: zip of that folder ----------------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
        $rel = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $entry = $relName + '/' + $rel
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $f.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}

$zipInfo = Get-Item -LiteralPath $zipPath
Write-Output ('Version: ' + $Version)
Write-Output ('Folder : ' + $stage)
Write-Output ('Packed : ' + $copied + ' files (update notes = CHANGELOG.md)')
Write-Output ('Zip    : ' + $zipPath)
Write-Output ('Size   : ' + [math]::Round($zipInfo.Length / 1KB, 1) + ' KB')
Write-Output ('Preview: ' + $preview)
Write-Output ('Replace: ' + $(if ($replaced) { 'yes, an older build of this version was replaced' } else { 'no, this version was not in dist yet' }))
Write-Output ('Stamp  : ' + $stamp)
Write-Output 'Other versions in dist are untouched.'

# ---- stage 3: publish into the cloud sync folder -------------------------------
# sync-cloud stages this release for the Baidu Pan share folder, so packing already gets the
# upload ready (the last drag into the client stays manual).
# Only the real dist\ is published: a test build in another folder must never reach players.
# A problem here never fails the release - the files are already complete in dist\.
if ($OutDir -ne 'dist') {
    Write-Output 'Cloud  : skipped (not building into dist\)'
} elseif ($NoCloud) {
    Write-Output 'Cloud  : skipped (-NoCloud)'
} else {
    $sync = Join-Path $PSScriptRoot 'sync-cloud.ps1'
    if (-not (Test-Path -LiteralPath $sync)) {
        Write-Output 'Cloud  : skipped (tools\sync-cloud.ps1 not found)'
    } else {
        try {
            $syncOut = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $sync -DistDir $OutDir -Version $Version
            foreach ($l in @($syncOut)) { if ($l -ne '') { Write-Output $l } }
        } catch {
            Write-Output ('Cloud  : skipped (' + $_.Exception.Message + ')')
        }
    }
}
