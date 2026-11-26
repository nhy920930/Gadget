# Static syntax check for the VBScript blocks inside the HTA.
#
# Why not cscript: extracting the block to %TEMP%\*.vbs and running it with
# cscript.exe is exactly the "script interpreter reads a script from the temp
# folder" pattern that EDR products (QiAnXin TianQing and friends) flag as a
# fileless attack. This checker runs no script engine at all and writes
# nothing, so it cannot be intercepted. It trades a real compiler for
# structural checks: block pairing (Sub/Function/If/For/Do/While/With/
# Select/Class/Property/Enum), unterminated string literals, JS-style
# operators, and misspelled block terminators.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-vbs.ps1
#        powershell ... -File tools\check-vbs.ps1 -Hta app\<name>.hta
param(
    [string]$Hta = ''
)
$ErrorActionPreference = 'Stop'

if ($Hta -eq '') {
    $appDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
    $cand = @(Get-ChildItem -LiteralPath $appDir -Filter '*.hta' | Where-Object { $_.Name -notlike '_*' })
    if ($cand.Count -eq 0) { Write-Host 'FAIL: no .hta file under app\'; exit 2 }
    $Hta = $cand[0].FullName
}
if (-not (Test-Path -LiteralPath $Hta)) { Write-Host ('FAIL: not found: ' + $Hta); exit 2 }

$text = [IO.File]::ReadAllText($Hta, [Text.Encoding]::UTF8)
$openTag = '<script language="VBScript">'
$closeTag = '</script>'

# Collect blocks exactly the way the engine sees them: up to the first
# "</script>" after the opening tag (a literal "</script>" inside a string
# would terminate the block for the engine too, so this mirrors reality).
$blocks = New-Object System.Collections.Generic.List[object]
$pos = 0
while ($true) {
    $a = $text.IndexOf($openTag, $pos, [StringComparison]::OrdinalIgnoreCase)
    if ($a -lt 0) { break }
    $bodyStart = $a + $openTag.Length
    $b = $text.IndexOf($closeTag, $bodyStart, [StringComparison]::OrdinalIgnoreCase)
    if ($b -lt 0) {
        Write-Host ('FAIL: <script language="VBScript"> at char ' + $a + ' is never closed')
        exit 2
    }
    $startLine = 1
    for ($k = 0; $k -lt $bodyStart; $k++) { if ($text[$k] -eq "`n") { $startLine++ } }
    $blocks.Add([pscustomobject]@{ Body = $text.Substring($bodyStart, $b - $bodyStart); StartLine = $startLine })
    $pos = $b + $closeTag.Length
}
if ($blocks.Count -eq 0) { Write-Host 'FAIL: no <script language="VBScript"> block found'; exit 2 }

$failCount = 0
$totalLines = 0

foreach ($blk in $blocks) {
    $stack = New-Object System.Collections.Generic.List[string]
    $stackLn = New-Object System.Collections.Generic.List[int]
    $parenOpen = 0
    $parenClose = 0
    $lines = $blk.Body.Split("`n")

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $raw = $lines[$i]
        if ($raw.EndsWith("`r")) { $raw = $raw.Substring(0, $raw.Length - 1) }
        $ln = $blk.StartLine + $i
        $totalLines++

        # Strip string literals and comments so keywords inside them are not
        # mistaken for code. VBScript strings cannot span lines, so a line
        # that ends inside a literal is a real error. " doubled quotes are
        # escapes, not literal boundaries.
        $sb = New-Object System.Text.StringBuilder
        $inStr = $false
        for ($k = 0; $k -lt $raw.Length; $k++) {
            $c = $raw[$k]
            if ($inStr) {
                if ($c -eq '"') {
                    if (($k + 1) -lt $raw.Length -and $raw[$k + 1] -eq '"') { [void]$sb.Append('xx'); $k++; continue }
                    $inStr = $false
                }
                [void]$sb.Append('x')
                continue
            }
            if ($c -eq '"') { $inStr = $true; [void]$sb.Append('x'); continue }
            if ($c -eq "'") { break }
            if ($c -eq '(') { $parenOpen++ }
            elseif ($c -eq ')') { $parenClose++ }
            [void]$sb.Append($c)
        }
        if ($inStr) {
            Write-Host ('[fail] line ' + $ln + ': string literal is not closed on this line')
            $failCount++
        }

        $t = $sb.ToString().Trim()
        if ($t -eq '') { continue }
        if ($t -match '(\s|^)_\s*$') { continue }

        if ($t -match '&&|\|\||==|!=|\+\+|//') {
            Write-Host ('[fail] line ' + $ln + ': JS-style operator in VBScript: ' + $t)
            $failCount++
        }

        $pushed = $null
        if ($t -match '^(Public\s+|Private\s+|Friend\s+|Static\s+)?Sub\s+\w+') { $pushed = 'Sub' }
        elseif ($t -match '^(Public\s+|Private\s+|Friend\s+|Static\s+)?Function\s+\w+') { $pushed = 'Function' }
        elseif ($t -match '^(Public\s+|Private\s+)?Property\s+(Get|Let|Set)\b') { $pushed = 'Property' }
        elseif ($t -match '^(Public\s+|Private\s+)?Class\s+\w+') { $pushed = 'Class' }
        elseif ($t -match '^(Public\s+|Private\s+)?Enum\s+\w+') { $pushed = 'Enum' }
        elseif ($t -match '^If\b.*\bThen\s*$') { $pushed = 'If' }
        elseif ($t -match '^Select\s+Case\b') { $pushed = 'Select' }
        elseif ($t -match '^For\b') { $pushed = 'For' }
        elseif ($t -match '^Do\b') { $pushed = 'Do' }
        elseif ($t -match '^While\b') { $pushed = 'While' }
        elseif ($t -match '^With\b') { $pushed = 'With' }

        $popped = $null
        if ($t -match '^End\s+(Sub|Function|Property|Class|Enum|If|Select|With)\s*$') { $popped = $Matches[1] }
        elseif ($t -match '^Next\b') { $popped = 'For' }
        elseif ($t -match '^Loop\b') { $popped = 'Do' }
        elseif ($t -match '^Wend\b') { $popped = 'While' }
        elseif ($t -match '^(EndIf|EndSub|EndFunction|EndSelect|EndWith|EndProperty|EndClass|EndEnum)\b') {
            Write-Host ('[fail] line ' + $ln + ': "' + $Matches[1] + '" needs a space, e.g. "End If"')
            $failCount++
            continue
        }

        if ($null -ne $popped) {
            if ($stack.Count -eq 0) {
                Write-Host ('[fail] line ' + $ln + ': "' + $t + '" has no matching opener')
                $failCount++
            }
            elseif ($stack[$stack.Count - 1] -ne $popped) {
                Write-Host ('[fail] line ' + $ln + ': "' + $t + '" closes ' + $popped + ' but the innermost open block is ' + $stack[$stack.Count - 1] + ' (line ' + $stackLn[$stackLn.Count - 1] + ')')
                $failCount++
            }
            else {
                $stack.RemoveAt($stack.Count - 1)
                $stackLn.RemoveAt($stackLn.Count - 1)
            }
        }
        elseif ($null -ne $pushed) {
            $stack.Add($pushed)
            $stackLn.Add($ln)
        }
    }

    for ($j = 0; $j -lt $stack.Count; $j++) {
        Write-Host ('[fail] line ' + $stackLn[$j] + ': block ' + $stack[$j] + ' is never closed')
        $failCount++
    }
}

Write-Host ('file   = ' + $Hta)
Write-Host ('blocks = ' + $blocks.Count)
Write-Host ('lines  = ' + $totalLines)
if (($parenOpen - $parenClose) -ne 0) {
    Write-Host ('[warn] unbalanced parentheses in total: ( = ' + $parenOpen + ', ) = ' + $parenClose)
}
if ($failCount -eq 0) {
    Write-Host 'RESULT = PASS'
    exit 0
}
Write-Host ('RESULT = FAIL (' + $failCount + ' problem(s))')
exit 1
