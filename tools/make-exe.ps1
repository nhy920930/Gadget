# Build the single-file exe: the release tree packed inside a small C# launcher.
#
# The exe is only a shell. The toolbox is still an HTA driven by mshta.exe + Windows PowerShell,
# so what this buys is "one file to download": on first run the launcher unpacks the payload into
# a MengHuanToolbox\ folder next to itself and starts the toolbox from there.
#
# Payload = the exact folder make-release.ps1 just produced, so the exe and the zip handed out
# with it always carry the same files. All three share one short name per version:
#
#   dist\<name>_v<version>\      <- run in place
#   dist\<name>_v<version>.zip   <- zip of that folder
#   dist\<name>_v<version>.exe   <- that folder, embedded
#
# Rebuilding the same version replaces those three files; other versions stay untouched. The exe
# still stamps "<version>+<build time>" into its .version marker, so a rebuilt package of the same
# version also refreshes a MengHuanToolbox\ folder that was already unpacked.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-exe.ps1
#   powershell ... -Version 1.2.0     # pass-through, only if the notes are not written yet
#   powershell ... -NoPreview         # do not re-capture docs\preview.png (no window opens)
#
# The README preview (docs\preview.png) is refreshed by make-release.ps1 on the way, so packing
# after a UI change already updates the picture that ships in the package.
#
# ASCII only, like the other tool scripts. All Chinese text the launcher shows lives in
# launcher-texts.txt and is embedded as-is.
param(
    [string]$OutDir = 'dist',
    [string]$Version = '',
    [switch]$NoPreview,
    [switch]$NoCloud
)

$ErrorActionPreference = 'Stop'

# This script sits in tools\, so the project root is its parent folder.
$root = Split-Path -Parent $PSScriptRoot

# ---- stage 0: let make-release.ps1 build the folder, reuse it as the payload ----------
$releaseArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'make-release.ps1'),
    '-OutDir', $OutDir
)
if ($Version -ne '') { $releaseArgs += @('-Version', $Version) }
if ($NoPreview) { $releaseArgs += '-NoPreview' }
if ($NoCloud) { $releaseArgs += '-NoCloud' }
$releaseOut = & powershell.exe @releaseArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error 'make-release.ps1 failed, nothing to embed.'
    exit 1
}
foreach ($line in $releaseOut) { Write-Output $line }

$stage = ''
$ver = ''
$stamp = ''
foreach ($line in @($releaseOut)) {
    if ($line -match '^Folder : (.*)$') { $stage = $Matches[1].Trim() }
    if ($line -match '^Version: (.*)$') { $ver = $Matches[1].Trim() }
    if ($line -match '^Stamp  : (.*)$') { $stamp = $Matches[1].Trim() }
}
if ($stage -eq '' -or -not (Test-Path -LiteralPath $stage)) {
    Write-Error 'Could not read the release folder from make-release.ps1 output.'
    exit 1
}
if ($ver -eq '' -or $ver -notmatch '^[0-9A-Za-z._-]+$') {
    Write-Error ('Bad version "' + $ver + '" in make-release.ps1 output.')
    exit 1
}

# AssemblyVersion needs four numeric parts. "1.2.2" -> "1.2.2.0"; anything else falls back to
# 1.0.0.0 instead of failing the build.
$asmVer = '1.0.0.0'
if ($ver -match '^(\d+)\.(\d+)\.(\d+)') { $asmVer = $Matches[1] + '.' + $Matches[2] + '.' + $Matches[3] + '.0' }

# Unpack marker written by the launcher. It carries the build stamp so that a rebuilt package of
# the same version still refreshes an already-unpacked MengHuanToolbox\ folder - the file names
# themselves stay version-only.
$buildTag = $ver
if ($stamp -ne '') { $buildTag = $ver + '+' + $stamp }

$dist = Split-Path -Parent $stage
$relName = Split-Path -Leaf $stage
$exePath = Join-Path $dist ($relName + '.exe')
$exeReplaced = $false
if (Test-Path -LiteralPath $exePath) {
    try {
        Remove-Item -LiteralPath $exePath -Force -ErrorAction Stop
        $exeReplaced = $true
    } catch {
        Write-Error ('Cannot replace ' + $exePath + ' - close it first if it is running, then build again.')
        exit 1
    }
}

# ---- stage 1: pack the payload -------------------------------------------------------
# Own container instead of a zip, because the launcher then needs nothing but System.dll:
#   [int32 manifestLength][manifest: "name|size" lines, UTF-8][raw bytes of each file]
# then the whole thing gzipped.
$items = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName)
if ($items.Count -eq 0) {
    Write-Error ('Nothing to embed in ' + $stage)
    exit 1
}

$manifest = New-Object System.Text.StringBuilder
foreach ($f in $items) {
    $rel = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
    [void]$manifest.Append($rel + '|' + $f.Length + "`n")
}
$manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifest.ToString())

$raw = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($raw)
$bw.Write([int]$manifestBytes.Length)
$bw.Write([byte[]]$manifestBytes)
foreach ($f in $items) { $bw.Write([byte[]][System.IO.File]::ReadAllBytes($f.FullName)) }
$bw.Flush()

Add-Type -AssemblyName System.IO.Compression
$gzBuffer = New-Object System.IO.MemoryStream
$gz = New-Object System.IO.Compression.GZipStream($gzBuffer, [System.IO.Compression.CompressionMode]::Compress, $true)
$raw.Position = 0
$raw.CopyTo($gz)
$gz.Dispose()

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('gadget-exe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$payloadPath = Join-Path $temp 'payload.bin'
[System.IO.File]::WriteAllBytes($payloadPath, $gzBuffer.ToArray())

# ---- stage 2: compile the launcher ---------------------------------------------------
$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

// File properties (right-click -> Properties -> Details). Security software and SmartScreen treat a
// binary with no title/product/version info as far more suspicious than a plain signed-looking app,
// and users get a readable name in Task Manager. Values come from make-release.ps1's version.
[assembly: AssemblyTitle("MengHuan Toolbox")]
[assembly: AssemblyDescription("MengHuan toolbox launcher (unpacks the bundled HTA and starts it)")]
[assembly: AssemblyProduct("MengHuan Toolbox")]
[assembly: AssemblyCompany("MengHuan Toolbox")]
[assembly: AssemblyCopyright("")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("__ASMVERSION__")]
[assembly: AssemblyFileVersion("__ASMVERSION__")]

// Single-file shell around the toolbox: unpack the embedded release next to this exe, then hand
// the .hta to mshta.exe. Kept to C# 5 and System.dll + System.Windows.Forms only, so the compiler
// that ships with Windows (.NET Framework) is enough - no SDK, no NuGet, no install step.
internal static class Program
{
    private const string WorkDirName = "MengHuanToolbox";
    private const string MarkerName = ".version";
    private const string PayloadName = "payload.bin";
    private const string TextsName = "launcher-texts.txt";
    private const string BuildVersion = "__VERSION__";

    private static Dictionary<string, string> texts;

    [STAThread]
    private static int Main(string[] args)
    {
        bool extractOnly = false;
        // verify-release.ps1 uses this mode: unpack next to the exe and exit without starting mshta,
        // so a packaging run can prove the payload is complete without popping the toolbox window.
        bool unpackOnly = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Compare(args[i], "--extract", true) == 0) { extractOnly = true; }
            if (string.Compare(args[i], "--unpack-only", true) == 0) { unpackOnly = true; }
        }

        try { texts = LoadTexts(); }
        catch (Exception) { texts = new Dictionary<string, string>(); }

        string work;
        try
        {
            string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            work = Path.Combine(exeDir, WorkDirName);
            Prepare(work);
        }
        catch (Exception ex)
        {
            Error(T("err_unpack") + Environment.NewLine + Environment.NewLine + ex.Message);
            return 1;
        }

        string hta = FindHta(work);
        if (hta == null)
        {
            Error(T("err_no_hta"));
            return 2;
        }

        if (extractOnly)
        {
            try { Process.Start("explorer.exe", "\"" + work + "\""); }
            catch (Exception) { }
            Info(string.Format(T("info_extracted"), work));
            return 0;
        }

        if (unpackOnly) { return 0; }

        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "mshta.exe"));
            psi.Arguments = "\"" + hta + "\"";
            psi.WorkingDirectory = Path.GetDirectoryName(hta);
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Error(T("err_launch") + Environment.NewLine + Environment.NewLine + ex.Message);
            return 3;
        }
        return 0;
    }

    // Unpack once per version. A newer exe replaces the old files but keeps app\data, so an
    // update never costs the player his locked character, picked read region or pet history.
    private static void Prepare(string work)
    {
        Directory.CreateDirectory(work);
        string marker = Path.Combine(work, MarkerName);
        string have = File.Exists(marker) ? File.ReadAllText(marker, Encoding.UTF8).Trim() : "";
        string keep = Path.Combine(Path.Combine(work, "app"), "data");

        if (have == BuildVersion && FindHta(work) != null) { return; }

        CleanExcept(work, keep);
        Unpack(work);
        File.WriteAllText(marker, BuildVersion, new UTF8Encoding(false));
    }

    private static void CleanExcept(string dir, string keep)
    {
        if (!Directory.Exists(dir)) { return; }
        string keepFull = Path.GetFullPath(keep);

        string[] files = Directory.GetFiles(dir);
        for (int i = 0; i < files.Length; i++) { File.Delete(files[i]); }

        string[] dirs = Directory.GetDirectories(dir);
        for (int i = 0; i < dirs.Length; i++)
        {
            string full = Path.GetFullPath(dirs[i]);
            if (string.Equals(full, keepFull, StringComparison.OrdinalIgnoreCase)) { continue; }
            if (keepFull.StartsWith(full + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                CleanExcept(dirs[i], keep);
            }
            else
            {
                Directory.Delete(dirs[i], true);
            }
        }
    }

    private static void Unpack(string work)
    {
        using (Stream res = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadName))
        {
            if (res == null) { throw new InvalidOperationException(PayloadName + " is missing from this exe."); }
            using (GZipStream gz = new GZipStream(res, CompressionMode.Decompress))
            using (MemoryStream ms = new MemoryStream())
            {
                gz.CopyTo(ms);
                ms.Position = 0;
                BinaryReader br = new BinaryReader(ms);
                int length = br.ReadInt32();
                string manifest = Encoding.UTF8.GetString(br.ReadBytes(length));
                string[] lines = manifest.Split('\n');
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = lines[i].TrimEnd('\r');
                    if (line.Length == 0) { continue; }
                    int bar = line.LastIndexOf('|');
                    string name = line.Substring(0, bar);
                    int size = int.Parse(line.Substring(bar + 1));
                    string target = Path.Combine(work, name.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    File.WriteAllBytes(target, br.ReadBytes(size));
                }
            }
        }
    }

    // Same rule as the .bat launcher: the biggest .hta in app\, no Chinese literal in the code.
    private static string FindHta(string work)
    {
        string appDir = Path.Combine(work, "app");
        if (!Directory.Exists(appDir)) { return null; }
        string best = null;
        long bestSize = -1;
        string[] found = Directory.GetFiles(appDir, "*.hta");
        for (int i = 0; i < found.Length; i++)
        {
            long len = new FileInfo(found[i]).Length;
            if (len > bestSize) { bestSize = len; best = found[i]; }
        }
        return best;
    }

    private static Dictionary<string, string> LoadTexts()
    {
        Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(TextsName))
        {
            if (s == null) { return map; }
            using (StreamReader r = new StreamReader(s, Encoding.UTF8, true))
            {
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    if (line.Length == 0 || line[0] == '#') { continue; }
                    int eq = line.IndexOf('=');
                    if (eq <= 0) { continue; }
                    map[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
            }
        }
        return map;
    }

    // "a|b" in launcher-texts.txt becomes two paragraphs in the dialog.
    private static string T(string key)
    {
        string value;
        if (texts != null && texts.TryGetValue(key, out value) && value.Length > 0)
        {
            return value.Replace("|", Environment.NewLine + Environment.NewLine);
        }
        return key;
    }

    private static void Error(string text)
    {
        MessageBox.Show(text, T("title"), MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private static void Info(string text)
    {
        MessageBox.Show(text, T("title"), MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
}
'@

$csPath = Join-Path $temp 'launcher.cs'
$csText = $source.Replace('__VERSION__', $buildTag).Replace('__ASMVERSION__', $asmVer)
[System.IO.File]::WriteAllText($csPath, $csText, [System.Text.Encoding]::ASCII)

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    Write-Error 'csc.exe (.NET Framework 4) not found, cannot build the exe.'
    exit 1
}
$fwDir = Split-Path -Parent $csc

# Optional icon: a plain gradient disc in the toolbox colours, so the file does not show the
# generic .NET icon. Skipped silently if GDI+ is unavailable.
$icoPath = Join-Path $temp 'launcher.ico'
$haveIcon = $false
try {
    Add-Type -AssemblyName System.Drawing
    $size = 64
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = New-Object System.Drawing.Rectangle(3, 3, ($size - 6), ($size - 6))
    $c1 = [System.Drawing.Color]::FromArgb(255, 123, 67, 245)
    $c2 = [System.Drawing.Color]::FromArgb(255, 72, 149, 239)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45)
    $graphics.FillEllipse($brush, $rect)
    $graphics.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $icoStream = [System.IO.File]::Create($icoPath)
    $icon.Save($icoStream)
    $icoStream.Close()
    $icon.Dispose()
    $bmp.Dispose()
    $haveIcon = (Test-Path -LiteralPath $icoPath)
} catch {
    $haveIcon = $false
}

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    ('/out:' + $exePath),
    ('/reference:' + (Join-Path $fwDir 'System.Windows.Forms.dll')),
    ('/resource:' + $payloadPath + ',payload.bin'),
    ('/resource:' + (Join-Path $PSScriptRoot 'launcher-texts.txt') + ',launcher-texts.txt')
)
if ($haveIcon) { $cscArgs += ('/win32icon:' + $icoPath) }
$cscArgs += $csPath

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error 'csc.exe failed, see the messages above.'
    exit 1
}

# Only our own throw-away folder under %TEMP%, never anything inside dist\.
if ((Split-Path -Leaf $temp) -like 'gadget-exe-*') {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$exeInfo = Get-Item -LiteralPath $exePath
Write-Output ('Exe    : ' + $exePath)
Write-Output ('Size   : ' + [math]::Round($exeInfo.Length / 1KB, 1) + ' KB (payload: ' + $items.Count + ' files)')
Write-Output ('Icon   : ' + $(if ($haveIcon) { 'embedded' } else { 'default (GDI+ unavailable)' }))
Write-Output ('Replace: ' + $(if ($exeReplaced) { 'yes, the previous exe of this version was replaced' } else { 'no, this exe did not exist yet' }))
Write-Output ('Marker : ' + $buildTag)
Write-Output ('On first run it unpacks next to itself into ' + 'MengHuanToolbox\' + ', then starts mshta.')
Write-Output ('Other versions in dist are untouched.')

# ---- stage 3: publish the exe into the cloud sync folder ----------------------
# make-release.ps1 already put CHANGELOG.md and the zip there; the exe only exists now, so it
# goes up in a second pass. Same rule: only the real dist\ is published.
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
                -File $sync -DistDir $OutDir -Version $ver
            foreach ($l in @($syncOut)) { if ($l -ne '') { Write-Output $l } }
        } catch {
            Write-Output ('Cloud  : skipped (' + $_.Exception.Message + ')')
        }
    }
}
