# Environment check for the toolbox: run once on first launch and report what is missing.
# Same line protocol as the other helpers: 'META \t key \t value' rows plus a trailing EOF row,
# so the HTA can poll one small file instead of parsing console output.
# Source stays pure ASCII on purpose (Windows PowerShell 5.1 reads a BOM-less script as ANSI and
# would eat any Chinese comment); the HTA turns these keys into Chinese hints.
param(
    [string]$OutFile = ''
)

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row($k, $v) { $script:rows.Add([string]$k + "`t" + [string]$v) }

# --- PowerShell itself -------------------------------------------------------
Add-Row 'psver' ($PSVersionTable.PSVersion.ToString())
Add-Row 'psbits' $(if ([Environment]::Is64BitProcess) { '64' } else { '32' })
Add-Row 'mshta' $(if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\mshta.exe')) { '1' } else { '0' })

# --- files the toolbox needs next to itself ----------------------------------
# $PSScriptRoot is <app>\ocr, so $root is the folder holding the .hta. Only runtime files are
# listed here: the development helpers now live in the repository's tools\ folder and are not
# expected next to the toolbox. The calculators keep working even when the list is not ok.
$root = Split-Path -Parent $PSScriptRoot
$need = @(
    'ocr\ghost_monitor.ps1',
    'ocr\ghost_texts.txt',
    'ocr\ocr_answer.ps1',
    'ocr\ocr_region.ps1',
    'ocr_tiku.txt'
)
$miss = New-Object System.Collections.Generic.List[string]
foreach ($n in $need) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $n))) { $miss.Add($n) }
}
if ($miss.Count -eq 0) { Add-Row 'files' 'ok' } else { Add-Row 'files' ($miss -join '|') }

# --- question bank -----------------------------------------------------------
# Same rule as OcrRefreshTiku: skip blanks and '#' comments, count rows holding a separator.
$n = 0
try {
    $p = Join-Path $root 'ocr_tiku.txt'
    if (Test-Path -LiteralPath $p) {
        $tab = [string][char]9
        foreach ($ln in [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)) {
            $t = $ln.Trim()
            if ($t.Length -gt 0 -and -not $t.StartsWith('#')) {
                if ($t.IndexOf('|') -ge 0 -or $t.IndexOf($tab) -ge 0) { $n++ }
            }
        }
    }
} catch { }
Add-Row 'tiku' $n

# --- built-in OCR engine + Chinese language pack ----------------------------
# Mirrors Get-OcrEngine in ghost_monitor.ps1: prefer zh-Hans-CN, else whatever the profile offers.
$ok = '0'
$lang = ''
try {
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $e = $null
    try { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'zh-Hans-CN')) } catch { }
    if ($null -ne $e) {
        $ok = '1'
        $lang = 'zh-Hans'
    } else {
        try { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() } catch { }
        if ($null -ne $e) {
            $ok = '1'
            try { $lang = (@($e.AvailableRecognizerLanguages) | ForEach-Object { $_.LanguageTag }) -join ',' } catch { $lang = 'profile' }
        }
    }
} catch { }
Add-Row 'ocr' $ok
Add-Row 'ocrlang' $lang

# --- output ------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
foreach ($r in $rows) { [void]$sb.AppendLine('META' + "`t" + $r) }
[void]$sb.AppendLine('EOF' + "`t" + [DateTime]::Now.Ticks)
$text = $sb.ToString()
if ($OutFile.Length -gt 0) {
    try {
        [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
} else {
    Write-Output $text
}
