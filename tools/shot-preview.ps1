# Refresh docs\preview.png from the toolbox as it opens on this machine.
#
# Called by make-release.ps1 before the file list is built, so the README preview cannot lag
# behind the UI: adding a feature and packing again re-captures the picture, no manual step.
#
# What it captures is the default window: mshta is started, Window_OnLoad finishes sizing and
# centring, then the window rectangle is copied from the screen as-is - scrollbars included,
# nothing cropped or stitched, so the README shows what a user actually gets.
#
# The caller has to be DPI aware before measuring: at 125% scaling a DPI-unaware process gets the
# virtualised rect (0.8x) while the screen is physical, so the crop lands on the wrong pixels.
#
# The new picture replaces the old one only if the bytes differ, so a rebuild with an unchanged
# UI leaves docs\preview.png alone instead of dirtying the working tree.
#
# Exit codes: 0 = done (picture updated or already identical), 1 = nothing usable captured - the
# caller keeps the existing file and must not fail the release over it.
#
# ASCII only, like the other tool scripts.
param(
    [string]$Out = '',
    [int]$WaitMs = 7000,
    [int]$MinColors = 60
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
if ($Out -eq '') { $Out = Join-Path $root 'docs\preview.png' }

# Same pick as make-release.ps1: the biggest .hta under app\ is the toolbox.
$hta = Get-ChildItem -Path (Join-Path $root 'app\*.hta') -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending | Select-Object -First 1
if ($null -eq $hta) {
    Write-Output 'PREVIEW skipped, no .hta under app\'
    exit 1
}

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class ShotWin {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint wpid;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid != pid || !IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(260);
            GetWindowTextW(h, sb, 260);
            if (sb.Length == 0) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            if (r.R - r.L < 400) return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    // SetForegroundWindow is a no-op while the calling process is not the foreground one, and
    // CopyFromScreen then grabs whatever is really on top - a chat window, the IDE. Attaching to
    // the foreground thread lifts that restriction; the caller still checks IsFront afterwards.
    public static bool ForceForeground(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint myThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != myThread) { attached = AttachThreadInput(myThread, fgThread, true); }
        ShowWindow(h, 9);
        bool ok = SetForegroundWindow(h);
        if (attached) { AttachThreadInput(myThread, fgThread, false); }
        return ok;
    }
    public static bool IsFront(IntPtr h) { return GetForegroundWindow() == h; }
    // GetWindowRect includes the invisible resize border and drop shadow (7-9px per side at
    // 100-125%), and what shows through there is the desktop - taskbar clock, icons, stray
    // slivers on the edges. DWMWA_EXTENDED_FRAME_BOUNDS is the rectangle that is actually drawn.
    public static bool VisibleRect(IntPtr h, out RECT r) {
        r = new RECT();
        try {
            if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0) {
                if (r.R - r.L > 400) return true;
            }
        } catch (Exception) { }
        return GetWindowRect(h, out r);
    }
}
"@
[void][ShotWin]::SetProcessDPIAware()

$before = @(Get-Process -Name mshta -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $env:SystemRoot 'System32\mshta.exe'
$psi.Arguments = '"' + $hta.FullName + '"'
$psi.UseShellExecute = $false
$started = $null
try { $started = [Diagnostics.Process]::Start($psi) } catch { $started = $null }
if ($null -eq $started) {
    Write-Output 'PREVIEW skipped, mshta did not start'
    exit 1
}
Start-Sleep -Milliseconds $WaitMs

$hwnd = [IntPtr]::Zero
foreach ($q in (Get-Process -Name mshta -ErrorAction SilentlyContinue)) {
    if ($before -notcontains $q.Id) {
        $h = [ShotWin]::Find([uint32]$q.Id)
        if ($h -ne [IntPtr]::Zero) { $hwnd = $h }
    }
}
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output 'PREVIEW skipped, no toolbox window found'
    foreach ($m in (Get-Process -Name mshta -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })) {
        try { $m.Kill() } catch {}
    }
    exit 1
}

# Front and centre, then measure again: the window may have just finished moving. The result is
# verified before the screen is read - capturing the wrong window is worse than keeping the old
# picture, because the colourful one passes the colour count check.
[void][ShotWin]::ForceForeground($hwnd)
Start-Sleep -Milliseconds 900
if (-not [ShotWin]::IsFront($hwnd)) {
    Write-Output 'PREVIEW skipped, the toolbox window could not be brought to the front'
    foreach ($m in (Get-Process -Name mshta -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })) {
        try { $m.Kill() } catch {}
    }
    exit 1
}
$rect = New-Object ShotWin+RECT
[void][ShotWin]::VisibleRect($hwnd, [ref]$rect)

$w = $rect.R - $rect.L
$h2 = $rect.B - $rect.T
Write-Output ('PREVIEW rect  = ' + $rect.L + ',' + $rect.T + ' ' + $w + 'x' + $h2)

$tmp = Join-Path $env:TEMP ('gadget-preview-' + [guid]::NewGuid().ToString('N') + '.png')
$ok = $false
$colors = 0
if ($w -gt 400 -and $h2 -gt 400 -and $rect.L -gt -10000) {
    try {
        $bmp = New-Object Drawing.Bitmap $w, $h2
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($rect.L, $rect.T, 0, 0, (New-Object Drawing.Size $w, $h2))
        $g.Dispose()
        $bmp.Save($tmp, [Drawing.Imaging.ImageFormat]::Png)
        # A window behind another window, or a solid rectangle, still "captures" but is useless.
        # Sample the picture instead of trusting CopyFromScreen.
        $seen = @{}
        for ($y = 0; $y -lt $h2; $y += 7) {
            for ($x = 0; $x -lt $w; $x += 7) {
                $c = $bmp.GetPixel($x, $y).ToArgb()
                if (-not $seen.ContainsKey($c)) { $seen[$c] = 1 }
            }
        }
        $colors = $seen.Count
        $bmp.Dispose()
        if ($colors -ge $MinColors) { $ok = $true }
    } catch {
        Write-Output ('PREVIEW capture failed: ' + $_.Exception.Message)
    }
} else {
    Write-Output 'PREVIEW skipped, window rect is not on screen'
}
Write-Output ('PREVIEW colors= ' + $colors)

$keep = @(Get-Process -Name mshta -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
foreach ($m in $keep) { try { $m.CloseMainWindow() | Out-Null } catch {} }
Start-Sleep -Milliseconds 900
foreach ($m in $keep) { try { if (-not $m.HasExited) { $m.Kill() } } catch {} }

if (-not $ok) {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-Output 'PREVIEW failed, keeping the existing picture'
    exit 1
}

$had = Test-Path -LiteralPath $Out
$same = $false
$oldHash = $null
if ($had) {
    $oldHash = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash
    $newHash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    if ($oldHash -eq $newHash) { $same = $true }
}
$outDir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

if ($same) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Output ('PREVIEW file  = unchanged, ' + $Out + ' already matches this window')
} else {
    Copy-Item -LiteralPath $tmp -Destination $Out -Force
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $info = Get-Item -LiteralPath $Out
    $was = 'written'
    if ($had) { $was = 'updated' }
    Write-Output ('PREVIEW file  = ' + $was + ', ' + $Out + ' (' + [math]::Round($info.Length / 1KB, 1) + ' KB)')
}
exit 0
