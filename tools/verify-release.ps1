# Post-build verification of a release package: hash comparison + exe smoke test.
#
#   powershell -ExecutionPolicy Bypass -File tools\verify-release.ps1
#   ... -SkipSmoke          # hash checks only (no exe unpack run at all)
#   ... -Smoke              # also start the exe for real (this DOES open the toolbox window)
#   ... -KeepSmoke          # keep .check\verify-release\ for debugging
#
# What it checks:
#   1) Version   : newest "## x.y.z" in CHANGELOG.md matches the dist package name
#   2) Package   : zip entries and folder files are the same set with identical SHA256
#   3) Sources   : every packaged file (HTA, mobile page, launcher bat, app\ocr\*.ps1, README /
#                  CHANGELOG, docs\*.png) still equals its same-named repo file
#   4) Forbidden : no app\data\ and no dev-only scripts inside the package
#   5) Cloud     : if dist\MHToolbox already carries this version's files they must be byte-identical
#                  (the double-click bat refreshes that folder with sync-cloud -NoOpen before
#                  verifying, so a stale or missing copy is only a NOTE, never a FAIL)
#   6) Exe       : copy the exe to .check\, run it with --unpack-only (no window, mshta is not
#                  started), expect every packaged file in the unpacked tree byte-identical, the
#                  .version marker and no BOM in the HTA, then clean up. -Smoke starts the exe for
#                  real as well, which is the only thing that opens a window on purpose.
#
# ASCII only, like the other tool scripts. Exit code 0 = PASS, 1 = FAIL.
param(
    [string]$DistDir = 'dist',
    [switch]$SkipSmoke,
    [switch]$Smoke,
    [switch]$KeepSmoke,
    [int]$SmokeWait = 10
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([IO.Path]::IsPathRooted($DistDir)) { $dist = $DistDir } else { $dist = Join-Path $root $DistDir }

$fails = New-Object System.Collections.ArrayList
function Ok($msg) { Write-Output ('  OK   ' + $msg) }
function Bad($msg) { [void]$fails.Add($msg); Write-Output ('  FAIL ' + $msg) }
function Note($msg) { Write-Output ('  NOTE ' + $msg) }

function Get-HashOfFile($path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
function Get-HashOfStream($stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $sha.Dispose() }
}
function Compare-Source($source, $packed, $label) {
    if (-not (Test-Path -LiteralPath $source)) { Bad ($label + ': source file missing'); return }
    if (-not (Test-Path -LiteralPath $packed)) { Bad ($label + ': not found in package'); return }
    if ((Get-HashOfFile $source) -eq (Get-HashOfFile $packed)) { Ok ($label + ' matches source') }
    else { Bad ($label + ' differs from source (repack after the last edit)') }
}

Write-Output '=== verify-release ==='

# ---- 1) version comes from CHANGELOG.md, the single source of truth ----------------
$ver = ''
$changelog = Join-Path $root 'CHANGELOG.md'
if (Test-Path -LiteralPath $changelog) {
    $m = [regex]::Match([IO.File]::ReadAllText($changelog, [Text.Encoding]::UTF8), '(?m)^##\s+(\d+\.\d+\.\d+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}
if ($ver -eq '') {
    Bad 'CHANGELOG.md has no "## x.y.z" version line'
    Write-Output ''
    Write-Output 'RESULT = FAIL'
    exit 1
}
Ok ('version ' + $ver + ' from CHANGELOG.md')

# ---- 2) locate the package that belongs to that version ---------------------------
$zip = @(Get-ChildItem -Path (Join-Path $dist ('*_v' + $ver + '.zip')) -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)[0]
if ($zip -eq $null) {
    $zip = @(Get-ChildItem -Path (Join-Path $dist '*_v*.zip') -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)[0]
}
if ($zip -eq $null) {
    Bad ('no *_v*.zip in ' + $dist + ' - build the package first')
    Write-Output ''
    Write-Output 'RESULT = FAIL'
    exit 1
}
$stem = [IO.Path]::GetFileNameWithoutExtension($zip.Name)
$folder = Join-Path $dist $stem
$exe = Join-Path $dist ($stem + '.exe')
$exeLeaf = $stem + '.exe'
if ($stem -notlike ('*_v' + $ver)) { Bad ('newest zip is ' + $zip.Name + ' but CHANGELOG.md says v' + $ver) }
else { Ok ('package ' + $stem) }
if (Test-Path -LiteralPath $folder) { Ok 'release folder exists' } else { Bad ('missing folder ' + $folder) }
if (Test-Path -LiteralPath $exe) { Ok 'exe exists' } else { Bad ('missing exe ' + $exe) }

# ---- 3) zip and folder must carry the same files with the same bytes -------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stageFiles = @{}
if (Test-Path -LiteralPath $folder) {
    foreach ($f in (Get-ChildItem -LiteralPath $folder -Recurse -File)) {
        $rel = $f.FullName.Substring($folder.Length + 1)
        $stageFiles[$rel] = $f.FullName
    }
    Ok ('folder has ' + $stageFiles.Count + ' file(s)')
}
$seen = @{}
$zipCount = 0
$archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
try {
    foreach ($entry in $archive.Entries) {
        if ([string]::IsNullOrEmpty($entry.Name)) { continue }
        $zipCount++
        $rel = $entry.FullName.Replace('/', '\')
        # make-release.ps1 zips the version folder itself, so entries start with "<stem>\".
        $prefix = $stem + '\'
        if ($rel.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($prefix.Length) }
        $seen[$rel] = $true
        if (-not $stageFiles.ContainsKey($rel)) {
            Bad ('zip entry not in folder: ' + $rel)
            continue
        }
        $s = $entry.Open()
        try { $zh = Get-HashOfStream $s } finally { $s.Dispose() }
        if ($zh -ne (Get-HashOfFile $stageFiles[$rel])) { Bad ('zip/folder hash mismatch: ' + $rel) }
    }
} finally {
    $archive.Dispose()
}
if ($zipCount -eq $stageFiles.Count -and $stageFiles.Count -gt 0) { Ok ('zip and folder agree on ' + $zipCount + ' file(s)') }
else { Bad ('zip has ' + $zipCount + ' file(s), folder has ' + $stageFiles.Count) }
foreach ($rel in $stageFiles.Keys) {
    if (-not $seen.ContainsKey($rel)) { Bad ('folder file not in zip: ' + $rel) }
}

# ---- 4) forbidden content -------------------------------------------------------
$bad = @()
foreach ($rel in $stageFiles.Keys) {
    $leaf = [IO.Path]::GetFileName($rel)
    if ($rel -match '\\data\\' -or $rel -match '^data\\') { $bad += $rel }
    if ($leaf -eq 'cap_quest.ps1' -or $leaf -eq 'crop_strip.ps1') { $bad += $rel }
}
if ($bad.Count -eq 0) { Ok 'no app\data\ and no dev-only scripts inside' }
else { foreach ($b in $bad) { Bad ('forbidden file in package: ' + $b) } }

# ---- 5) packaged files must still equal the repo sources -------------------------
# Every packaged file has a same-named counterpart in the repo (white-list layout), so a generic
# loop covers the HTA, the mobile page, README / CHANGELOG, the launcher bat, app\ocr\*.ps1 and
# docs\*.png at once - no per-file list to keep in sync.
foreach ($rel in ($stageFiles.Keys | Sort-Object)) {
    $src = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $src)) { Note ('no repo source to compare: ' + $rel); continue }
    Compare-Source $src $stageFiles[$rel] $rel
}

# ---- 6) the cloud folder, when it already holds this version ---------------------
# The double-click bat refreshes dist\MHToolbox through sync-cloud.ps1 -NoOpen right after the
# build, so a full run normally shows three "cloud copy matches" lines. sync-cloud.ps1 copies
# byte-for-byte, so anything else only means "that folder was not refreshed for this build" (a
# direct make-exe run, or a Pan client holding a file) - never a failure.
$cloud = Join-Path $dist 'MHToolbox'
if (Test-Path -LiteralPath $cloud) {
    foreach ($n in @('CHANGELOG.md', $zip.Name, $exeLeaf)) {
        $c = Join-Path $cloud $n
        if (-not (Test-Path -LiteralPath $c)) { Note ('cloud folder has no ' + $n + ' (run tools\sync-cloud.ps1 to publish)'); continue }
        if ($n -eq 'CHANGELOG.md') { $local = Join-Path $folder $n } else { $local = Join-Path $dist $n }
        if ((Get-HashOfFile $c) -eq (Get-HashOfFile $local)) { Ok ('cloud copy matches: ' + $n) }
        else { Note ('cloud copy is from an older build: ' + $n + ' (run tools\sync-cloud.ps1 after building)') }
    }
} else {
    Note ('no ' + $cloud + ' (cloud sync not run)')
}

# ---- 7) exe unpack check --------------------------------------------------------
# The launcher is started with --unpack-only: it writes the release tree next to the exe and exits
# without starting mshta, so a packaging run never pops the toolbox window. -Smoke additionally
# starts the exe for real (that does open the window) to prove mshta comes up, and -SkipSmoke
# turns even the unpack run off.
if ($SkipSmoke -or -not (Test-Path -LiteralPath $exe)) {
    if ($SkipSmoke) { Note 'exe check skipped (-SkipSmoke)' }
    else { Note 'exe check skipped (no exe)' }
} else {
    $sandbox = Join-Path $root '.check\verify-release'
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $copy = Join-Path $sandbox (Split-Path -Leaf $exe)
    Copy-Item -LiteralPath $exe -Destination $copy

    $work = Join-Path $sandbox 'MengHuanToolbox'
    $before = @(Get-Process -Name mshta -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $proc = Start-Process -FilePath $copy -ArgumentList '--unpack-only' -PassThru
    # The whole run is unpack-and-exit, so waiting for the process to end is both the fastest and the
    # strongest signal (the marker and tree are written before it returns). The cap still covers a
    # cold antivirus scan of a fresh exe.
    $deadline = (Get-Date).AddSeconds($SmokeWait)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not $proc.HasExited) { [void]$proc.WaitForExit(3000) }
    if (-not $proc.HasExited) { Bad 'exe: launcher still running after the unpack' }
    elseif ($proc.ExitCode -ne 0) { Bad ('exe: launcher exited with code ' + $proc.ExitCode) }
    else { Ok 'exe: unpack-only run exited cleanly (no window opened)' }

    if (-not (Test-Path -LiteralPath $work)) {
        Bad 'exe: did not unpack MengHuanToolbox\'
    } else {
        $files = @(Get-ChildItem -LiteralPath $work -Recurse -File -Force)
        # Compare the package file by file instead of counting files: a count breaks as soon as
        # anything writes next to the package (a -Smoke run leaves app\data\env_ok.txt behind from
        # the toolbox's own self check). Unknown files are tolerated only under app\data\, which is
        # never packaged; anything else means the payload carries a file the folder does not.
        if ($stageFiles.Count -gt 0) {
            $missing = 0
            $differs = 0
            foreach ($rel in $stageFiles.Keys) {
                $u = Join-Path $work $rel
                if (-not (Test-Path -LiteralPath $u)) { Bad ('exe: unpacked file missing: ' + $rel); $missing++; continue }
                if ((Get-HashOfFile $u) -ne (Get-HashOfFile $stageFiles[$rel])) { Bad ('exe: unpacked file differs: ' + $rel); $differs++ }
            }
            if ($missing -eq 0 -and $differs -eq 0) { Ok ('exe: unpacked all ' + $stageFiles.Count + ' packaged file(s) byte-identical') }
        }
        $runtime = @()
        $stray = @()
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($work.Length + 1)
            if ($rel -eq '.version') { continue }
            if ($stageFiles.ContainsKey($rel)) { continue }
            if ($rel -match '^app\\data\\') { $runtime += $rel } else { $stray += $rel }
        }
        if ($runtime.Count -gt 0) { Note ('exe: ' + $runtime.Count + ' runtime state file(s) under app\data\: ' + ($runtime -join ', ')) }
        foreach ($s in $stray) { Bad ('exe: unexpected file in unpacked tree: ' + $s) }
        $marker = Join-Path $work '.version'
        if (Test-Path -LiteralPath $marker) {
            $tag = [IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8).Trim()
            if ($tag -like ($ver + '+*')) { Ok ('exe: marker ' + $tag) } else { Bad ('exe: marker "' + $tag + '" does not start with ' + $ver + '+') }
        } else { Bad 'exe: .version marker missing' }
        if (Test-Path -LiteralPath (Join-Path $work 'app\ocr\remind_notify.ps1')) { Ok 'exe: remind_notify.ps1 present' }
        else { Bad 'exe: app\ocr\remind_notify.ps1 missing' }
        $whta = @(Get-ChildItem -LiteralPath (Join-Path $work 'app') -Filter '*.hta' -File -ErrorAction SilentlyContinue)[0]
        if ($whta -eq $null) {
            Bad 'exe: no .hta in unpacked app\'
        } else {
            $bytes = [IO.File]::ReadAllBytes($whta.FullName)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Bad 'exe: unpacked .hta has a UTF-8 BOM' }
            else { Ok 'exe: unpacked .hta has no BOM' }
        }
    }
    # An exe built before --unpack-only existed ignores the flag and starts the toolbox. Close what
    # it opened anyway, so even verifying an old package leaves no window behind.
    $leaked = @(Get-Process -Name mshta -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
    if ($leaked.Count -gt 0) {
        Note ('exe: this build ignores --unpack-only (older launcher), closed ' + $leaked.Count + ' window(s) it opened')
        foreach ($p in $leaked) { try { [void]$p.CloseMainWindow() } catch { } }
        Start-Sleep -Milliseconds 900
        foreach ($p in $leaked) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
        Start-Sleep -Milliseconds 600
    }

    if ($Smoke) {
        # Real launch: this opens the toolbox window on purpose, then closes it again.
        # The HTA declares singleinstance="yes": a toolbox window that is already open (from the
        # repo or another unpacked copy) makes the freshly started mshta exit right away. Spot that
        # case by comparing the .hta leaf name in existing mshta command lines, so it becomes a
        # NOTE instead of a false "did not start" failure.
        $htaLeaf = ''
        foreach ($rel in $stageFiles.Keys) { if ($rel -match '^app\\[^\\]+\.hta$') { $htaLeaf = [IO.Path]::GetFileName($rel) } }
        $blocker = ''
        if ($htaLeaf -ne '') {
            try {
                foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" -ErrorAction SilentlyContinue)) {
                    $cl = [string]$p.CommandLine
                    if ($cl -match '"([^"]+\.hta)"' -and (Split-Path -Leaf $Matches[1]) -eq $htaLeaf) { $blocker = $cl; break }
                }
            } catch { }
        }
        if ($blocker -ne '') { Note ('smoke: already open, so singleinstance=yes swallows the new window: ' + $blocker) }

        $before = @(Get-Process -Name mshta -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $started = Start-Process -FilePath $copy -PassThru
        $live = @()
        # mshta normally shows up in under a second; poll for it and for the launcher's own exit
        # instead of sleeping a fixed budget, so the check does not sit there for 10 s.
        for ($i = 0; $i -lt 25; $i++) {
            Start-Sleep -Milliseconds 300
            $live = @(Get-Process -Name mshta -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
            if ($live.Count -gt 0 -and $started.HasExited) { break }
        }
        if ($live.Count -ge 1) { Ok ('smoke: ' + $live.Count + ' new mshta process') }
        elseif ($blocker -ne '') { Note 'smoke: no new mshta because another toolbox window was open (close it and run again for a full check)' }
        else { Bad 'smoke: no mshta process - the toolbox did not start' }
        if ($started.HasExited) { Ok 'smoke: launcher exited' } else { Bad 'smoke: launcher still running' }

        foreach ($p in $live) { try { [void]$p.CloseMainWindow() } catch { } }
        Start-Sleep -Milliseconds 900
        foreach ($p in $live) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
        Start-Sleep -Milliseconds 600
    } else {
        Note 'exe: startup not tried (add -Smoke to open the toolbox once)'
    }
    if ($KeepSmoke) {
        Note ('smoke sandbox kept: ' + $sandbox)
    } elseif (Test-Path -LiteralPath $sandbox) {
        # mshta may hold the folder for a moment after being killed; retry instead of giving up.
        for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $sandbox); $i++) {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $sandbox) { Start-Sleep -Milliseconds 500 }
        }
        if (Test-Path -LiteralPath $sandbox) { Note ('could not remove ' + $sandbox + ' - close its window and delete it by hand') }
    }
}

Write-Output ''
if ($fails.Count -eq 0) {
    Write-Output ('RESULT = PASS  (' + $stem + ')')
    exit 0
}
Write-Output ('RESULT = FAIL  (' + $fails.Count + ' problem(s))')
foreach ($f in $fails) { Write-Output ('  - ' + $f) }
exit 1
