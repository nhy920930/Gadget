# In-place update for the toolbox: compare the newest published version with the local one, and
# download + replace files only when the published one is actually newer.
#
# Called by the "check for updates" button in the .hta, two modes:
#   check - read the published version, compare with <root>\CHANGELOG.md, report only.
#   apply - repeat that comparison first; if the published version is not newer, stop right there
#           (no download). Otherwise fetch the release zip, unpack it and copy the toolbox
#           files over this folder. app\data is never touched, so the locked character, the
#           picked read region, the self-check signature and the pet history survive, and the
#           bank of questions is backed up to app\data\ocr_tiku.prev.txt before it is replaced
#           by the one from the package (the question bank can be edited in the toolbox, so a
#           hand-edited copy would otherwise be lost without trace).
#
# Where the version comes from (default: the release folder shared on Baidu Pan):
#   The share folder is readable without logging in - submit the access code, take the cookie it
#   sets, then ask for the listing - so the newest "_v<version>.zip" (or ".exe") name in the
#   folder IS the published version. That matters because Baidu will not give a download link to
#   an anonymous client (sharedownload answers errno=118 "illegal operation"): players download
#   the file from the share page in a browser, while the toolbox itself still takes the zip from
#   public GitHub. When the shared copy is ahead of that zip, apply stops with
#   msg=package_stale instead of silently installing an older package over a newer one; the
#   caller then offers the share link for a manual download. When the share cannot be read at all
#   (offline, API change, empty folder) the check falls back to the GitHub CHANGELOG so updates
#   keep working.
#
# app\data\update_source.txt can move or pin the sources, one key=value per line:
#   share=<share path or https://pan.baidu.com/s/xxxx>  default 1jMjWXBqNIAm1qwaGaBkJ4w
#   pwd=<access code of that share>                     default 8iif
#   folder=<folder inside the share>                    default MengHuanToolbox
#   version=<url or path of CHANGELOG.md>               compare against this instead of the share
#   package=<url or path of the release zip>            override the download source
# A version= line switches the whole check to plain url mode (used by the offline test).
#
# Progress goes to -OutFile as plain key=value lines, rewritten in full after every step, so
# the caller can show "downloading..." and then pick up the final status without a protocol:
#   status=checking|downloading|extracting|applying|available|latest|local_newer|applied|error
#   local=1.2.2  remote=1.2.3  cloud=1.2.3  source=cloud|github|url  files=13  msg=...  detail=...
# Every value sits on its own line and is only ever written by a whole-file replace, so the
# reader never sees a half-written file.
#
# ASCII only, like the other scripts under app\ocr - keep it that way.
param(
    [ValidateSet('check', 'apply')][string]$Mode = 'check',
    [string]$Root = '',
    [string]$OutFile = '',
    [string]$VersionUrl = '',
    [string]$PackageUrl = '',
    [string]$Share = '',
    [string]$SharePwd = '',
    [string]$ShareFolder = '',
    [switch]$NoCloud
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Windows PowerShell 5.1 still offers TLS 1.0 first, and GitHub refuses that handshake.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
} catch { }

$defaultVersionUrl = 'https://raw.githubusercontent.com/nhy920930/Gadget/master/CHANGELOG.md'
$defaultPackageUrl = 'https://codeload.github.com/nhy920930/Gadget/zip/refs/heads/master'
$defaultShare = '1jMjWXBqNIAm1qwaGaBkJ4w'
$defaultSharePwd = '8iif'
$defaultShareFolder = 'MengHuanToolbox'
# Baidu Pan answers the listing to a client that only knows the access code; everything goes
# through pan.baidu.com with the same app_id the web page uses.
$panBase = 'https://pan.baidu.com'
$panCommon = '&channel=chunlei&web=1&app_id=250528&clienttype=0'
$panUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# ---------------------------------------------------------------- result file

$S = @{
    status = 'checking'
    local  = ''
    remote = ''
    cloud  = ''
    source = ''
    files  = 0
    msg    = ''
    detail = ''
}

function Save-State {
    if ($OutFile -eq '') { return }
    $text = 'status=' + $S.status + "`r`n" +
            'local=' + $S.local + "`r`n" +
            'remote=' + $S.remote + "`r`n" +
            'cloud=' + $S.cloud + "`r`n" +
            'source=' + $S.source + "`r`n" +
            'files=' + $S.files + "`r`n" +
            'msg=' + ('' + $S.msg -replace "`r?`n", ' ') + "`r`n" +
            'detail=' + ('' + $S.detail -replace "`r?`n", ' | ') + "`r`n"
    $tmp = $OutFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

# ---------------------------------------------------------------- versions

function Get-VersionFromText {
    param([string]$Text)
    if ($Text -eq '') { return '' }
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*##\s+v?([0-9]+(\.[0-9]+)*)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

function Compare-VersionText {
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

# ---------------------------------------------------------------- baidu pan share

function Get-PanText {
    param([string]$Url, $Sess, [string]$SharePath)
    $hdr = @{
        Accept = 'application/json, text/plain, */*'
        'Accept-Language' = 'zh-CN,zh;q=0.9'
        Referer = $panBase + '/s/' + $SharePath
    }
    if ($null -eq $Sess) {
        $resp = Invoke-WebRequest -Uri $Url -Headers $hdr -UserAgent $panUa -UseBasicParsing -TimeoutSec 25
    } else {
        $resp = Invoke-WebRequest -Uri $Url -Headers $hdr -UserAgent $panUa -WebSession $Sess `
            -UseBasicParsing -TimeoutSec 25
    }
    # Raw bytes decoded as UTF-8: the listing carries Chinese file names and promises no charset.
    return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
}

function Get-PanList {
    param([string]$Uk, [string]$ShareId, [string]$Dir, $Sess, [string]$SharePath)
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $Url = $panBase + '/share/list?uk=' + $Uk + '&shareid=' + $ShareId + '&order=other&desc=1' +
        '&showempty=0&page=1&num=100&dir=' + [Uri]::EscapeDataString($Dir) + '&t=' + $t + $panCommon
    return ((Get-PanText $Url $Sess $SharePath) | ConvertFrom-Json)
}

# The share is readable but not downloadable for an anonymous client, so the only public fact
# about a release is its name. The folder holds "<name>_v<version>.zip" plus the matching exe;
# the highest version in either name is the published one.
function Get-CloudVersion {
    param([string]$SharePath, [string]$Pwd, [string]$Folder)
    if ($Pwd -eq '') {
        throw 'The share needs an access code but none is configured (key pwd=).'
    }
    $Sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    # 1. the share page itself, so the calls below run with the cookies it sets
    $null = Invoke-WebRequest -Uri ($panBase + '/s/' + $SharePath + '?pwd=' + $Pwd) -UseBasicParsing `
        -UserAgent $panUa -WebSession $Sess -TimeoutSec 25

    # 2. submit the access code; the short form drops the leading 1 of the /s/ path
    $short = $SharePath
    if ($short.Length -gt 1 -and $short.StartsWith('1')) { $short = $short.Substring(1) }
    $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $verifyUrl = $panBase + '/share/verify?surl=' + $short + '&t=' + $t + $panCommon
    $vr = Invoke-WebRequest -Uri $verifyUrl -Method POST -Body ('pwd=' + $Pwd) `
        -ContentType 'application/x-www-form-urlencoded' -Headers @{ Referer = $panBase + '/s/' + $SharePath } `
        -UserAgent $panUa -WebSession $Sess -UseBasicParsing -TimeoutSec 25
    $vj = ([Text.Encoding]::UTF8.GetString($vr.RawContentStream.ToArray())) | ConvertFrom-Json
    if ($vj.errno -ne 0) {
        throw ('The share rejected the access code (errno=' + $vj.errno + ').')
    }

    # 3. who owns the share and which id it has, both printed into the rendered page
    $html = Get-PanText ($panBase + '/s/' + $SharePath) $Sess $SharePath
    $mShare = [regex]::Match($html, '"shareid"\s*:\s*"?([0-9]+)')
    $mUk = [regex]::Match($html, '"share_uk"\s*:\s*"?([0-9]+)')
    if (-not $mShare.Success -or -not $mUk.Success) {
        throw 'The share page did not carry a share id (page layout changed?).'
    }
    $shareId = $mShare.Groups[1].Value
    $uk = $mUk.Groups[1].Value

    # 4. the release folder, or the share root when the share points at the folder itself
    $dirs = @('/' + $Folder.Trim('/'))
    if ($dirs[0] -eq '/') { $dirs = @('/') } else { $dirs += '/' }
    $best = ''
    foreach ($dir in $dirs) {
        $json = Get-PanList $uk $shareId $dir $Sess $SharePath
        if ($null -eq $json -or $json.errno -ne 0) { continue }
        foreach ($it in @($json.list)) {
            if ($null -eq $it) { continue }
            if ($it.isdir -ne 0) { continue }
            $m = [regex]::Match($it.server_filename, '_v([0-9]+(\.[0-9]+)*)\.(zip|exe)$')
            if (-not $m.Success) { continue }
            $v = $m.Groups[1].Value
            if ($best -eq '' -or (Compare-VersionText $v $best) -gt 0) { $best = $v }
        }
        if ($best -ne '') { break }
    }
    return $best
}

# ---------------------------------------------------------------- fetch

function Test-RemoteUrl {
    param([string]$Url)
    return ($Url -match '^[a-zA-Z][a-zA-Z0-9+.-]*://')
}

function Get-RemoteText {
    param([string]$Url)
    if (Test-RemoteUrl $Url) {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 25 `
            -UserAgent 'Mozilla/5.0 (compatible; MengHuanToolbox)'
        # Decode the raw bytes as UTF-8: a response without a charset header would otherwise be
        # read as Latin-1 and turn the Chinese notes into noise (irrelevant for the version
        # line, but the whole file is parsed).
        return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    }
    return [IO.File]::ReadAllText($Url, [Text.Encoding]::UTF8)
}

function Save-RemoteFile {
    param([string]$Url, [string]$Path)
    if (Test-RemoteUrl $Url) {
        Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 600 `
            -UserAgent 'Mozilla/5.0 (compatible; MengHuanToolbox)' -OutFile $Path
    } else {
        Copy-Item -LiteralPath $Url -Destination $Path -Force
    }
}

# ---------------------------------------------------------------- paths

if ($Root -eq '') {
    # <root>\app\ocr\update_toolbox.ps1 -> <root>
    $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$Root = $Root.TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $Root)) {
    throw ('Toolbox folder not found: ' + $Root)
}
$Root = (Resolve-Path -LiteralPath $Root).Path
$dataDir = Join-Path $Root 'app\data'
if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

# update_source.txt first, then an explicit switch on top of it, then the built-in defaults, so
# a mirror can be configured once and still be overridden when testing.
$fromFileVersion = ''
$fromFilePackage = ''
$fromFileShare = ''
$fromFilePwd = ''
$fromFileFolder = ''
$sourceFile = Join-Path $dataDir 'update_source.txt'
if (Test-Path -LiteralPath $sourceFile) {
    foreach ($line in ([IO.File]::ReadAllText($sourceFile, [Text.Encoding]::UTF8) -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -le 0) { continue }
        $key = $t.Substring(0, $eq).Trim().ToLower()
        $val = $t.Substring($eq + 1).Trim()
        if ($key -eq 'version') { $fromFileVersion = $val }
        if ($key -eq 'package') { $fromFilePackage = $val }
        if ($key -eq 'share') { $fromFileShare = $val }
        if ($key -eq 'pwd') { $fromFilePwd = $val }
        if ($key -eq 'folder') { $fromFileFolder = $val }
    }
}
if ($VersionUrl -eq '') { $VersionUrl = $fromFileVersion }
if ($PackageUrl -eq '') { $PackageUrl = $fromFilePackage }
if ($Share -eq '') { $Share = $fromFileShare }
if ($SharePwd -eq '') { $SharePwd = $fromFilePwd }
if ($ShareFolder -eq '') { $ShareFolder = $fromFileFolder }
if ($Share -eq '') { $Share = $defaultShare }
# The link may carry the code along as ?pwd=, which is used when nothing else sets it.
if ($Share -match '[?&]pwd=([A-Za-z0-9]+)' -and $SharePwd -eq '') { $SharePwd = $Matches[1] }
if ($SharePwd -eq '') { $SharePwd = $defaultSharePwd }
if ($ShareFolder -eq '') { $ShareFolder = $defaultShareFolder }
# Either the bare share path or the whole link is accepted for share=.
if ($Share -match '/s/([A-Za-z0-9_-]+)') { $Share = $Matches[1] }
if ($Share -match '^https?://') { throw ('Not a share path: ' + $Share) }

# A version= line (file or switch) means plain url mode: the share is then never touched.
$urlMode = ($VersionUrl -ne '')
$useCloud = (-not $NoCloud) -and (-not $urlMode)
if ($VersionUrl -eq '') { $VersionUrl = $defaultVersionUrl }
if ($PackageUrl -eq '') { $PackageUrl = $defaultPackageUrl }

$S.local = ''
$localChangeLog = Join-Path $Root 'CHANGELOG.md'
if (Test-Path -LiteralPath $localChangeLog) {
    $S.local = Get-VersionFromText ([IO.File]::ReadAllText($localChangeLog, [Text.Encoding]::UTF8))
}
Save-State

# ---------------------------------------------------------------- main

$tmpRoot = Join-Path $dataDir 'update_tmp'
$pkgRoot = $null
$zipPath = $null
# Kept across the whole run: a failure while reaching the package source should still say why
# the share was not used, otherwise the only visible error is the fallback one.
$cloudErr = ''

try {
    if ($S.local -eq '') {
        $S.status = 'error'
        $S.msg = 'local_version_missing'
        $S.detail = 'No version record (CHANGELOG.md) in ' + $Root
        Save-State
        exit 3
    }

    # ---- where is the published version?
    # The share folder is the intended answer; the public GitHub record is only a fallback, so a
    # share that cannot be read (offline, API change, still empty) never blocks updating.
    if ($useCloud) {
        try {
            $S.cloud = Get-CloudVersion $Share $SharePwd $ShareFolder
            if ($S.cloud -eq '') { $cloudErr = 'no *_v<version>.zip or .exe in the share folder' }
        } catch {
            $cloudErr = $_.Exception.Message
        }
    }
    if ($S.cloud -ne '') {
        $S.source = 'cloud'
        $S.remote = $S.cloud
    } else {
        $S.source = $(if ($urlMode) { 'url' } else { 'github' })
        if ($cloudErr -ne '') { $S.detail = 'cloud share unreadable: ' + $cloudErr }
        $remoteText = Get-RemoteText $VersionUrl
        $S.remote = Get-VersionFromText $remoteText
        if ($S.remote -eq '') {
            $S.status = 'error'
            $S.msg = 'remote_version_missing'
            $S.detail = 'No "## x.y.z" line in ' + $VersionUrl + '. ' + $S.detail
            Save-State
            exit 3
        }
    }
    Save-State

    $cmp = Compare-VersionText $S.remote $S.local
    if ($cmp -le 0) {
        # Same version or older: never download, that is the whole point of the check.
        $S.status = 'latest'
        if ($cmp -lt 0) { $S.status = 'local_newer' }
        $S.msg = 'up_to_date'
        Save-State
        exit 0
    }

    if ($Mode -eq 'check') {
        $S.status = 'available'
        $S.msg = 'update_available'
        Save-State
        exit 0
    }

    # ---- apply

    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

    $S.status = 'downloading'
    $S.msg = 'downloading'
    Save-State
    $zipPath = Join-Path $tmpRoot 'package.zip'
    Save-RemoteFile $PackageUrl $zipPath
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw ('Download produced no file: ' + $PackageUrl)
    }
    $zipInfo = Get-Item -LiteralPath $zipPath
    if ($zipInfo.Length -lt 50000) {
        throw ('Downloaded file is too small to be a release (' + $zipInfo.Length + ' bytes): ' + $PackageUrl)
    }

    $S.status = 'extracting'
    $S.msg = 'extracting'
    Save-State
    $stage = Join-Path $tmpRoot 'stage'
    # ZipFile refuses entries that point outside the target folder (zip slip) on .NET 4.6.1+.
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stage)

    # A GitHub zip wraps everything in one folder (Gadget-master\); a hand-made zip may not.
    $topDirs = @(Get-ChildItem -LiteralPath $stage -Directory)
    $topFiles = @(Get-ChildItem -LiteralPath $stage -File)
    if ($topFiles.Count -eq 0 -and $topDirs.Count -eq 1 -and
        (Test-Path -LiteralPath (Join-Path $topDirs[0].FullName 'app'))) {
        $pkgRoot = $topDirs[0].FullName
    } elseif (Test-Path -LiteralPath (Join-Path $stage 'app')) {
        $pkgRoot = $stage
    } else {
        throw 'The package does not look like a toolbox release (no app folder inside).'
    }
    $pkgHta = @(Get-ChildItem -LiteralPath (Join-Path $pkgRoot 'app') -Filter *.hta -File)
    if ($pkgHta.Count -eq 0) {
        throw 'The package has no .hta under app\.'
    }

    # The version came from one source (the share) and the package from another (GitHub), so the
    # package must not be allowed to install something older than the user was just told about:
    # that would look like a downgrade and leave the cloud copy ahead of the installed one.
    $pkgNotes = Join-Path $pkgRoot 'CHANGELOG.md'
    $pkgVer = ''
    if (Test-Path -LiteralPath $pkgNotes) {
        $pkgVer = Get-VersionFromText ([IO.File]::ReadAllText($pkgNotes, [Text.Encoding]::UTF8))
    }
    if ($pkgVer -ne '' -and (Compare-VersionText $pkgVer $S.remote) -lt 0) {
        $S.status = 'error'
        $S.msg = 'package_stale'
        $S.detail = 'The package source still offers ' + $pkgVer + ' while the published version is ' + $S.remote + '.'
        Save-State
        exit 4
    }
    # A package ahead of the announcement is fine and worth installing: report what it really is.
    if ($pkgVer -ne '' -and (Compare-VersionText $pkgVer $S.remote) -gt 0) { $S.remote = $pkgVer }

    # The question bank is editable and importable from the toolbox, so a hand-edited copy is
    # easy to lose: keep one before the package version takes its place.
    $tiku = Join-Path $Root 'app\ocr_tiku.txt'
    if (Test-Path -LiteralPath $tiku) {
        try {
            Copy-Item -LiteralPath $tiku -Destination (Join-Path $dataDir 'ocr_tiku.prev.txt') -Force
        } catch { }
    }

    $S.status = 'applying'
    $S.msg = 'applying'
    Save-State

    $copied = 0
    $failed = New-Object Collections.ArrayList
    function Copy-One {
        param([string]$Rel)
        $src = Join-Path $pkgRoot $Rel
        $dst = Join-Path $Root $Rel
        $dir = Split-Path -Parent $dst
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination $dst -Force
            try { Unblock-File -LiteralPath $dst -ErrorAction SilentlyContinue } catch { }
            $script:copied = $script:copied + 1
        } catch {
            [void]$failed.Add($Rel + ': ' + $_.Exception.Message)
        }
    }

    foreach ($f in (Get-ChildItem -LiteralPath $pkgRoot -Recurse -File)) {
        $rel = $f.FullName.Substring($pkgRoot.Length).TrimStart('\', '/')
        $low = $rel.ToLower()
        # Never touch the player's own state, wherever it sits.
        if ($low.StartsWith('app\data\')) { continue }
        $take = $false
        if ($rel -match '^app\\[^\\]+\.(hta|html)$') { $take = $true }
        elseif ($rel -match '^app\\ocr\\[^\\]+\.ps1$') { $take = $true }
        elseif ($low -eq 'app\ocr\ghost_texts.txt') { $take = $true }
        elseif ($low -eq 'app\ocr_tiku.txt') { $take = $true }
        elseif ($rel -match '^[^\\]+\.md$') { $take = $true }
        elseif ($rel -match '^[^\\]+\.bat$') {
            # The packing button is a development tool and stays out of the payload; it marks
            # itself with "gadget-devtool" on its first lines.
            $head = ''
            try { $head = (@(Get-Content -LiteralPath $f.FullName -TotalCount 2 -Encoding Default) -join "`n") } catch { }
            if ($head -notmatch 'gadget-devtool') { $take = $true }
        }
        elseif ($low.StartsWith('docs\') -or $low.StartsWith('tools\')) { $take = $true }
        if ($take) { Copy-One $rel }
        Save-State
    }

    $S.files = $copied
    if ($failed.Count -gt 0) {
        $S.status = 'applied'
        $S.msg = 'applied_with_warnings'
        $S.detail = 'Could not replace: ' + ($failed -join ' | ')
    } else {
        $S.status = 'applied'
        $S.msg = 'applied'
        $S.detail = ''
    }
    Save-State
    exit 0
} catch {
    $S.status = 'error'
    $S.msg = 'failed'
    $S.detail = $_.Exception.Message
    if ($cloudErr -ne '') { $S.detail = $S.detail + ' | cloud: ' + $cloudErr }
    Save-State
    exit 1
} finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
