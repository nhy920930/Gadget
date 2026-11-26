param(
    [string]$OutFile = "$env:TEMP\gadget_ocr_region.txt",
    [string]$ProcName = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class RegionWin
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static IntPtr FindGame(string procName, string brand, string exclude)
    {
        IntPtr best = IntPtr.Zero, bestMin = IntPtr.Zero;
        long bestArea = 0;
        // Titles containing ONLINE identify the game client window; keep consistent with ocr_answer.ps1
        IntPtr online = IntPtr.Zero, onlineMin = IntPtr.Zero;
        long onlineArea = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(1024);
            GetWindowTextW(h, sb, 1024);
            string title = sb.ToString();
            if (title.Length == 0) return true;
            if (exclude.Length > 0 && title.IndexOf(exclude, StringComparison.Ordinal) >= 0) return true;
            if (brand.Length > 0 && title.IndexOf(brand, StringComparison.Ordinal) < 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            string pn = "";
            try { pn = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            if (procName.Length > 0)
            {
                if (!string.Equals(pn, procName, StringComparison.OrdinalIgnoreCase)) return true;
            }
            else if (IsBrowserProcess(pn)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            long w = r.Right - r.Left;
            long hh = r.Bottom - r.Top;
            // Minimized windows report a tiny rect, so the size gate only applies to normal windows
            bool min = IsIconic(h);
            if (!min && (w < 320 || hh < 240)) return true;
            long area = w * hh;
            if (title.IndexOf("ONLINE", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                if (min) { if (onlineMin == IntPtr.Zero) onlineMin = h; }
                else if (area > onlineArea) { onlineArea = area; online = h; }
            }
            if (min) { if (bestMin == IntPtr.Zero) bestMin = h; }
            else if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        if (online != IntPtr.Zero) return online;
        if (onlineMin != IntPtr.Zero) return onlineMin;
        if (best != IntPtr.Zero) return best;
        return bestMin;
    }

    // Browser windows carry the game name in their titles when searching guides; never treat them as the game
    static bool IsBrowserProcess(string pn)
    {
        if (pn == null || pn.Length == 0) return false;
        string[] bad = new string[] {
            "msedge", "chrome", "firefox", "iexplore", "opera", "brave", "vivaldi",
            "360se", "360chrome", "360se6", "qqbrowser", "sogouexplorer", "maxthon",
            "ucbrowser", "msedgewebview2", "applicationframehost"
        };
        string n = pn.ToLowerInvariant();
        for (int i = 0; i < bad.Length; i++) if (n == bad[i]) return true;
        return false;
    }
}
'@

[void][RegionWin]::SetProcessDPIAware()

$brand = -join ([char]0x68A6, [char]0x5E7B, [char]0x897F, [char]0x6E38)
$exclude = -join ([char]0x804A, [char]0x5929, [char]0x7A97, [char]0x53E3)
$brandKey = $brand
if ($ProcName.Length -gt 0) { $brandKey = '' }

$hwnd = [RegionWin]::FindGame($ProcName, $brandKey, $exclude)
$winLeft = -1; $winTop = -1; $winW = -1; $winH = -1
if ($hwnd -ne [IntPtr]::Zero) {
    $wr = New-Object RegionWin+RECT
    [void][RegionWin]::GetWindowRect($hwnd, [ref]$wr)
    $winLeft = $wr.Left; $winTop = $wr.Top
    $winW = $wr.Right - $wr.Left; $winH = $wr.Bottom - $wr.Top
}

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds = New-Object System.Drawing.Rectangle -ArgumentList @($vs.Left, $vs.Top, $vs.Width, $vs.Height)
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::Black
$form.Opacity = 0.35
$form.ShowInTaskbar = $false
$form.Cursor = [System.Windows.Forms.Cursors]::Cross
$form.KeyPreview = $true
$form.Text = 'GadgetOcrRegion'

$script:startPt = $null
$script:curPt = $null
$script:result = $null

$font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$brush = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::White)
$penSel = New-Object System.Drawing.Pen -ArgumentList @([System.Drawing.Color]::FromArgb(255, 123, 67, 245), 3)
$brushFill = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::FromArgb(60, 123, 67, 245))

$form.Add_Paint({
    param($sender, $e)
    $e.Graphics.DrawString('Drag to select the OCR area. Release = OK, Esc = cancel.', $script:font, $script:brush, 20, 20)
    if ($script:startPt -ne $null -and $script:curPt -ne $null) {
        $x = [Math]::Min($script:startPt.X, $script:curPt.X)
        $y = [Math]::Min($script:startPt.Y, $script:curPt.Y)
        $w = [Math]::Abs($script:curPt.X - $script:startPt.X)
        $h = [Math]::Abs($script:curPt.Y - $script:startPt.Y)
        if ($w -gt 2 -and $h -gt 2) {
            $e.Graphics.FillRectangle($script:brushFill, $x, $y, $w, $h)
            $e.Graphics.DrawRectangle($script:penSel, $x, $y, $w, $h)
            $e.Graphics.DrawString(($w.ToString() + ' x ' + $h.ToString()), $script:font, $script:brush, ($x + 6), ([Math]::Max(4, $y - 30)))
        }
    }
})

$form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:startPt = New-Object System.Drawing.Point -ArgumentList @($e.X, $e.Y)
        $script:curPt = $script:startPt
        $sender.Invalidate()
    }
})

$form.Add_MouseMove({
    param($sender, $e)
    if ($script:startPt -ne $null) {
        $script:curPt = New-Object System.Drawing.Point -ArgumentList @($e.X, $e.Y)
        $sender.Invalidate()
    }
})

$form.Add_MouseUp({
    param($sender, $e)
    if ($script:startPt -eq $null) { return }
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $x = [Math]::Min($script:startPt.X, $e.X)
    $y = [Math]::Min($script:startPt.Y, $e.Y)
    $w = [Math]::Abs($e.X - $script:startPt.X)
    $h = [Math]::Abs($e.Y - $script:startPt.Y)
    if ($w -ge 24 -and $h -ge 24) {
        $script:result = New-Object System.Drawing.Rectangle -ArgumentList @(($x + $vs.Left), ($y + $vs.Top), $w, $h)
    }
    $sender.Close()
})

$form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $script:result = $null
        $sender.Close()
    }
})

[void]$form.ShowDialog()

$lines = New-Object System.Collections.Generic.List[string]
if ($script:result -ne $null) {
    $lines.Add('ABS' + "`t" + $script:result.Left + "`t" + $script:result.Top + "`t" + $script:result.Width + "`t" + $script:result.Height)
    $lines.Add('WIN' + "`t" + $winLeft + "`t" + $winTop + "`t" + $winW + "`t" + $winH)
    if ($winW -gt 0 -and $winH -gt 0) {
        $relX = $script:result.Left - $winLeft
        $relY = $script:result.Top - $winTop
        $lines.Add('REL' + "`t" + $relX + "`t" + $relY + "`t" + $script:result.Width + "`t" + $script:result.Height)
    } else {
        $lines.Add('REL' + "`t-1`t-1`t-1`t-1")
    }
} else {
    $lines.Add('CANCEL' + "`t0`t0`t0`t0")
}

$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutFile, ($lines -join "`r`n"), $enc)
