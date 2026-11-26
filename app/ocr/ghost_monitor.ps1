param(
    [string]$ProcName = '',
    [int]$X1 = -9999, [int]$X2 = 9999,
    [int]$Y1 = -9999, [int]$Y2 = 9999,
    [int]$FakeX = -1, [int]$FakeY = -1,
    [string]$Half = '',
    [int]$RelX = -1, [int]$RelY = -1, [int]$RelW = 0, [int]$RelH = 0,
    [int]$Interval = 800,
    [double]$Scale = 2.0,
    [string]$OutFile = "$env:TEMP\gadget_ghost_monitor.txt",
    [string]$StopFile = '',
    [string]$PidFile = '',
    [string]$TextFile = '',
    [string]$ConfigFile = '',
    [int]$SimX = -1, [int]$SimY = -1,
    [string]$OcrFile = '',
    [switch]$Once,
    [switch]$NoOverlay,
    [switch]$Strict,
    [switch]$SelfTest,
    # Escape hatch: some games report a child window as foreground, which would otherwise
    # keep the monitor in not_foreground forever.
    [switch]$IgnoreFocus,
    [string]$ShotFile = '',
    # One-shot mode: read the quest tracker strip and report the ghost-hunt target
    # (scene id + fake coordinate) instead of watching the coordinate readout.
    [switch]$ReadQuest,
    # Debug aid for a misread: keep the cropped strip and every pass's raw OCR lines next to the
    # META block, so a wrong pair can be traced to one pass instead of guessed at.
    [switch]$QuestDump,
    # Debug: append the raw OCR lines of the coordinate box to the result file and save the crop,
    # so a misread can be diagnosed instead of guessed at.
    [switch]$HudDump,
    [int]$QuestTimeout = 9000,
    # Multi-open: pin one client by the character id printed in its window title
    # ('... - name[12345]'). With a pin the reader never drifts to another client or tab.
    [string]$PinId = '',
    # One-shot: list the game client windows so the toolbox can offer a picker.
    [switch]$ListWindows,
    # Capture source. 'auto' reads the window's own surface first (PrintWindow), which keeps
    # working while another window covers the client, and only falls back to the screen when the
    # client offers no surface. 'screen' keeps the old copy-from-screen path.
    [ValidateSet('auto', 'screen')] [string]$Capture = 'auto'
)

# Realtime ghost-coordinate monitor.
# OCR the coordinate area of the game window, compare it with the search rectangle that
# the toolbox computed, and paint a passthrough banner on top of the game window when the
# player is still outside that rectangle.
# NOTE: this file is pure ASCII on purpose - PowerShell 5.1 parses a BOM-less script as ANSI,
# so every Chinese string is either read from ghost_texts.txt or built from char codes.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$cs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class GhostWin
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
    [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, int rop);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    // Client area in screen pixels: the coordinate readout is anchored to the client's top-left,
    // not to the outer window frame (title bar + border would shift the crop).
    public static bool GetClientRectScreen(IntPtr h, out RECT r)
    {
        RECT c; POINT p;
        r = new RECT();
        if (!GetClientRect(h, out c)) return false;
        p.X = 0; p.Y = 0;
        if (!ClientToScreen(h, ref p)) return false;
        r.Left = p.X; r.Top = p.Y;
        r.Right = p.X + c.Right; r.Bottom = p.Y + c.Bottom;
        return true;
    }

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public static string Title(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, 1024);
        return sb.ToString();
    }

    // Browser windows often carry the game name in their titles (searching guides), so they must never be picked
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

    public static IntPtr FindGame(string procName, string brand, string exclude)
    {
        IntPtr best = IntPtr.Zero, bestMin = IntPtr.Zero;
        long bestArea = 0;
        IntPtr online = IntPtr.Zero, onlineMin = IntPtr.Zero;
        long onlineArea = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            string title = Title(h);
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

    // Window list for the multi-open picker, in screen order (top-left first) so the list reads
    // like the tiled layout on the desktop. Rows are 'hwnd \t WxH \t state \t title'.
    public static string[] ListGames(string procName, string brand, string exclude)
    {
        var rows = new System.Collections.Generic.List<string[]>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            string title = Title(h);
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
            int w = r.Right - r.Left;
            int hh = r.Bottom - r.Top;
            bool min = IsIconic(h);
            if (!min && (w < 320 || hh < 240)) return true;
            rows.Add(new string[] { r.Top.ToString(), r.Left.ToString(),
                h.ToInt64().ToString(), w + "x" + hh, min ? "min" : "ok", title });
            return true;
        }, IntPtr.Zero);
        rows.Sort(delegate(string[] a, string[] b)
        {
            int c = int.Parse(a[0]).CompareTo(int.Parse(b[0]));
            if (c != 0) return c;
            return int.Parse(a[1]).CompareTo(int.Parse(b[1]));
        });
        var outv = new System.Collections.Generic.List<string>();
        foreach (var row in rows) outv.Add(row[2] + "\t" + row[3] + "\t" + row[4] + "\t" + row[5]);
        return outv.ToArray();
    }

    public static bool SameProcess(IntPtr a, IntPtr b)
    {
        if (a == IntPtr.Zero || b == IntPtr.Zero) return false;
        if (a == b) return true;
        uint pa, pb;
        GetWindowThreadProcessId(a, out pa);
        GetWindowThreadProcessId(b, out pb);
        return pa == pb;
    }

    // A DPI-unaware client (the game is one: awareness 0 at 125% scaling) is stretched to the
    // screen by Windows, but PrintWindow hands back the client's OWN unstretched picture. Measured
    // on the real client: a 1615x1279 window rendered into 1290x1022, i.e. 96/120. Everything right
    // and below that line is empty, which is why the quest strip at the right edge came back black
    // and why the coordinate box read a smaller, shifted picture. Returns 1.0 for DPI-aware clients
    // and for 100% scaling.
    public static double RenderScale(IntPtr h)
    {
        try
        {
            IntPtr ctx = GetWindowDpiAwarenessContext(h);
            if (ctx == IntPtr.Zero) return 1.0;
            if (GetAwarenessFromDpiAwarenessContext(ctx) != 0) return 1.0;
            uint sys = GetDpiForSystem();
            if (sys > 96 && sys <= 480)
            {
                double s = 96.0 / sys;
                if (s > 0.3) return s;
            }
        }
        catch { }
        return 1.0;
    }

    // Grab a client-relative box out of the window's OWN surface instead of the screen. A covered
    // client still returns its real picture here, while CopyFromScreen would return whatever window
    // is painted on top of it. PW_RENDERFULLCONTENT asks the compositor for the redirected surface,
    // which is what makes this work on hardware-rendered clients.
    // 'raw' skips the DPI mapping, for a client that turned out not to be virtualized.
    public static System.Drawing.Bitmap GrabWindow(IntPtr h, int x, int y, int w, int hh)
    {
        return GrabWindow(h, x, y, w, hh, false);
    }

    public static System.Drawing.Bitmap GrabWindow(IntPtr h, int x, int y, int w, int hh, bool raw)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) return null;
        int W = r.Right - r.Left, H = r.Bottom - r.Top;
        if (W < 16 || H < 16) return null;
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (w > W - x) w = W - x;
        if (hh > H - y) hh = H - y;
        if (w < 8 || hh < 8) return null;
        double s = raw ? 1.0 : RenderScale(h);
        int sx = (int)Math.Round(x * s), sy = (int)Math.Round(y * s);
        int sw = (int)Math.Round(w * s), sh = (int)Math.Round(hh * s);
        if (sx + sw > W) sw = W - sx;
        if (sy + sh > H) sh = H - sy;
        if (sw < 8 || sh < 8) return null;
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr mem = CreateCompatibleDC(screen);
        IntPtr bmp = CreateCompatibleBitmap(screen, W, H);
        if (mem == IntPtr.Zero || bmp == IntPtr.Zero)
        {
            if (mem != IntPtr.Zero) DeleteDC(mem);
            if (bmp != IntPtr.Zero) DeleteObject(bmp);
            ReleaseDC(IntPtr.Zero, screen);
            return null;
        }
        IntPtr old = SelectObject(mem, bmp);
        bool ok = PrintWindow(h, mem, 2);
        System.Drawing.Bitmap shot = null;
        if (ok)
        {
            bool same = Math.Abs(s - 1.0) < 0.001;
            int cx = same ? x : sx, cy = same ? y : sy;
            int cw = same ? w : sw, ch = same ? hh : sh;
            // Not a using block: on the unscaled path this bitmap IS the result, and returning a
            // disposed bitmap only shows up later as a GDI+ 'parameter is not valid' error.
            System.Drawing.Bitmap part = new System.Drawing.Bitmap(cw, ch, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (System.Drawing.Graphics gp = System.Drawing.Graphics.FromImage(part))
            {
                IntPtr dst = gp.GetHdc();
                BitBlt(dst, 0, 0, cw, ch, mem, cx, cy, 0x00CC0020);
                gp.ReleaseHdc(dst);
            }
            if (same)
            {
                shot = part;
            }
            else
            {
                // Scale the unstretched crop back up to the pixels the user actually sees, so
                // the caller's box and the OCR glyph size stay in physical pixels.
                shot = new System.Drawing.Bitmap(w, hh, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(shot))
                {
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                    g.DrawImage(part, new System.Drawing.Rectangle(0, 0, w, hh),
                        new System.Drawing.Rectangle(0, 0, cw, ch), System.Drawing.GraphicsUnit.Pixel);
                }
                part.Dispose();
            }
        }
        SelectObject(mem, old);
        DeleteObject(bmp);
        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, screen);
        return shot;
    }

    // One flat colour means the client handed back nothing (minimized, or not drawn yet): treat it
    // as a miss so the caller can fall back instead of OCR'ing a black rectangle.
    public static bool IsBlank(System.Drawing.Bitmap b)
    {
        if (b == null) return true;
        int min = 255, max = 0;
        int sx = Math.Max(1, b.Width / 12), sy = Math.Max(1, b.Height / 12);
        for (int y = 0; y < b.Height; y += sy)
            for (int x = 0; x < b.Width; x += sx)
            {
                System.Drawing.Color c = b.GetPixel(x, y);
                int v = (c.R + c.G + c.B) / 3;
                if (v < min) min = v;
                if (v > max) max = v;
            }
        return (max - min) < 3;
    }
}
'@

if (-not ('GhostWin' -as [type])) { Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing }

[void][GhostWin]::SetProcessDPIAware()

# One window grab with the DPI mapping and a raw retry. A virtualized client needs the mapping,
# an aware one needs the opposite, and a flat result means the client gave nothing back at all -
# report that as a miss so the caller falls back to the screen instead of OCR'ing a black box.
function Get-WindowCrop {
    param([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$W, [int]$H)
    $shot = $null
    try { $shot = [GhostWin]::GrabWindow($Hwnd, $X, $Y, $W, $H) } catch { $shot = $null }
    if ($null -ne $shot -and -not [GhostWin]::IsBlank($shot)) { return $shot }
    if ($null -ne $shot) { $shot.Dispose() }
    try { $shot = [GhostWin]::GrabWindow($Hwnd, $X, $Y, $W, $H, $true) } catch { $shot = $null }
    if ($null -ne $shot -and [GhostWin]::IsBlank($shot)) { $shot.Dispose(); return $null }
    return $shot
}

# ---------------------------------------------------------------- texts
# Chinese labels live in ghost_texts.txt (UTF-8): editing text never touches this script
function Get-TextTable {
    param([string]$Path)
    $map = @{}
    foreach ($k in @('out_of_range', 'in_range', 'no_coord', 'no_window', 'minimized', 'not_foreground',
            'pin_lost', 'pin_hidden',
            'dir_left', 'dir_right', 'dir_up', 'dir_down', 'dir_lu', 'dir_ru', 'dir_ld', 'dir_rd',
            'ahead', 'cells', 'current', 'range', 'look_at',
            'quad_lu', 'quad_ru', 'quad_ld', 'quad_rd')) {
        $map[$k] = $k
    }
    if ($Path.Length -gt 0 -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            foreach ($line in ($raw -split "`r?`n")) {
                $i = $line.IndexOf('=')
                if ($i -gt 0) {
                    $k = $line.Substring(0, $i).Trim()
                    $v = $line.Substring($i + 1).Trim()
                    if ($k.Length -gt 0 -and $v.Length -gt 0) { $map[$k] = $v }
                }
            }
        } catch { }
    }
    return $map
}

$script:txt = Get-TextTable $TextFile
$script:kwCoord = -join ([char]0x5750, [char]0x6807)   # "coordinate" hint used to prefer the right OCR line

# ---------------------------------------------------------------- config (proc + relative region + pin)
$script:cfgProc = ''
$script:cfgPin = ''
if ($ConfigFile.Length -gt 0 -and (Test-Path -LiteralPath $ConfigFile)) {
    try {
        $raw = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
        foreach ($line in ($raw -split "`r?`n")) {
            $p = $line -split '=', 2
            if ($p.Count -eq 2) {
                $k = $p[0].Trim()
                $v = $p[1].Trim()
                if ($k -eq 'proc') { $script:cfgProc = $v }
                if ($k -eq 'pin') { $script:cfgPin = $v }
                if ($k -eq 'region') {
                    $seg = $v -split ','
                    if ($seg.Count -eq 4) {
                        $RelX = [int]$seg[0]; $RelY = [int]$seg[1]; $RelW = [int]$seg[2]; $RelH = [int]$seg[3]
                    }
                }
            }
        }
    } catch { }
}
if ($ProcName.Length -eq 0 -and $script:cfgProc.Length -gt 0) { $ProcName = $script:cfgProc }
if ($PinId.Length -eq 0 -and $script:cfgPin.Length -gt 0) { $PinId = $script:cfgPin }
$script:pinId = $PinId.Trim()

# ---------------------------------------------------------------- window selection
$brand = -join ([char]0x68A6, [char]0x5E7B, [char]0x897F, [char]0x6E38)   # game brand in window title
$exclude = -join ([char]0x804A, [char]0x5929, [char]0x7A97, [char]0x53E3)  # toolbox title itself

# Multi-open: a pin decides the window; without one the biggest game window is used as before.
# The pin is the id inside the title ('... - name[12345]'), not a window handle: a handle changes
# when the client restarts and stays identical when the tab switches, so only the id can tell two
# characters of one client apart.
function Get-GameWindow {
    param([string]$Proc, [string]$Brand, [string]$Exclude)
    if ($script:pinId.Length -gt 0) { return [GhostWin]::FindGame($Proc, $script:pinId, $Exclude) }
    return [GhostWin]::FindGame($Proc, $Brand, $Exclude)
}

if ($ListWindows) {
    $sb = New-Object System.Text.StringBuilder
    $rows = @([GhostWin]::ListGames($ProcName, $(if ($ProcName.Length -gt 0) { '' } else { $brand }), $exclude))
    [void]$sb.AppendLine('META' + "`t" + 'count' + "`t" + $rows.Count)
    foreach ($row in $rows) {
        $p = $row -split "`t"
        # key = the id in brackets: identical for every window of one character, absent when the
        # client prints no id - such a window can be watched but not pinned.
        $id = ''
        $mi = [regex]::Match($p[3], '\[(\d{3,})\]')
        if ($mi.Success) { $id = $mi.Groups[1].Value }
        $label = $p[3]
        $ml = [regex]::Match($p[3], '-\s*([^-\[]+?)\s*\[(\d{3,})\]')
        if ($ml.Success) { $label = $ml.Groups[1].Value + '[' + $ml.Groups[2].Value + ']' }
        [void]$sb.AppendLine('WIN' + "`t" + $id + "`t" + $label + "`t" + $p[1] + "`t" + $p[2])
    }
    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($OutFile, $sb.ToString() + 'EOF' + "`t" + [DateTime]::Now.Ticks, $enc)
    } catch { }
    exit 0
}

# ---------------------------------------------------------------- read box
# The coordinate readout always sits at the top-left corner of the game client, so the
# default is fully automatic: the box is derived from the client size on every frame.
# A region saved by the optional "tweak region" button overrides it.
$script:autoBox = ($RelW -le 0 -or $RelH -le 0 -or $RelX -lt 0 -or $RelY -lt 0)

function Get-AutoBox {
    param([int]$ox, [int]$oy, [int]$ow, [int]$oh)
    # 30% x 20% of the client with pixel floors: wide enough for a 4-digit pair and for
    # any UI scale, small enough to keep the OCR cheap and free of HUD noise.
    $bw = [int][Math]::Round($ow * 0.30)
    if ($bw -lt 260) { $bw = 260 }
    $bh = [int][Math]::Round($oh * 0.20)
    if ($bh -lt 130) { $bh = 130 }
    if ($bw -gt $ow) { $bw = $ow }
    if ($bh -gt $oh) { $bh = $oh }
    if ($bw -lt 24) { $bw = 24 }
    if ($bh -lt 24) { $bh = 24 }
    return @($ox, $oy, $bw, $bh)
}

# ---------------------------------------------------------------- range helpers
# Game minimap grows X to the right and Y upward, so a point below the rectangle must move up (Y+)
function Get-MoveHint {
    param([int]$cx, [int]$cy)
    $needLeft = $cx -gt $X2
    $needRight = $cx -lt $X1
    $needUp = $cy -lt $Y1
    $needDown = $cy -gt $Y2
    $dx = 0
    if ($needLeft) { $dx = $cx - $X2 } elseif ($needRight) { $dx = $X1 - $cx }
    $dy = 0
    if ($needUp) { $dy = $Y1 - $cy } elseif ($needDown) { $dy = $cy - $Y2 }
    $key = ''
    if ($needLeft -and $needUp) { $key = 'dir_lu' }
    elseif ($needRight -and $needUp) { $key = 'dir_ru' }
    elseif ($needLeft -and $needDown) { $key = 'dir_ld' }
    elseif ($needRight -and $needDown) { $key = 'dir_rd' }
    elseif ($needLeft) { $key = 'dir_left' }
    elseif ($needRight) { $key = 'dir_right' }
    elseif ($needUp) { $key = 'dir_up' }
    elseif ($needDown) { $key = 'dir_down' }
    $dist = [Math]::Max($dx, $dy)
    return @{ key = $key; dist = [int]$dist; dx = [int]$dx; dy = [int]$dy }
}

# Direction key -> arrow rotation in degrees (0 = up, clockwise on screen). The hint tells the
# player which way to walk, so the arrow points at the walk direction, not at the ghost.
function Get-DirAngle {
    param([string]$Key)
    switch ($Key) {
        'dir_up' { return 0 }
        'dir_ru' { return 45 }
        'dir_right' { return 90 }
        'dir_rd' { return 135 }
        'dir_down' { return 180 }
        'dir_ld' { return 225 }
        'dir_left' { return 270 }
        'dir_lu' { return 315 }
    }
    return -1
}

function Test-InRange {
    param([int]$cx, [int]$cy)
    return ($cx -ge $X1 -and $cx -le $X2 -and $cy -ge $Y1 -and $cy -le $Y2)
}

# The game HUD prints "X:196 Y:64". Spaces can sit anywhere (OCR keeps them),
# so the pair is matched on a whitespace-stripped copy.
function Get-XyPair {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $s = [regex]::Replace($Text, '\s+', '')
    if ($s.Length -eq 0) { return $null }
    $m = [regex]::Match($s, '[Xx\uFF38\u00D7][:\uFF1A]?(\d{1,4})\D{0,4}[Yy\uFF59][:\uFF1A]?(\d{1,4})')
    if ($m.Success) { return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value) }
    return $null
}

# True when the line clearly carries the HUD's "X:.. Y:.." shape. Used to stop the loose
# fallback: if the labels are there but the digits did not come out, guessing is worse than
# reporting "no coordinate" for one frame. Callers pass the whole block: the engine splits the
# HUD row, so 'X:11' and 'Y:90' regularly end up on two different lines and a per-line check
# would let the loose fallback run right past a visible HUD.
function Test-XyMarker {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    $s = [regex]::Replace($Text, '\s+', '')
    return ($s -match '[Xx\uFF38\u00D7][:\uFF1A]' -and $s -match '[Yy\uFF59][:\uFF1A]')
}

# One axis picked out of the whole block, for the split HUD row. The game prints 'X:11', so a
# match that kept its colon beats one that did not - a stray glyph read as 'x0' must not win
# over the real '/X:11'. Inside the same class, more digits beat fewer: OCR drops digits far more
# often than it invents them, which is the same reason Merge-QuestHits folds truncated pairs.
function Get-XyAxis {
    param($Lines, [string]$Axis)
    $best = $null
    $bestScore = -1
    if ($Axis -eq 'X') { $pat = '[Xx\uFF38\u00D7]([:\uFF1A])?(\d{1,4})' }
    else { $pat = '[Yy\uFF59]([:\uFF1A])?(\d{1,4})' }
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $s = [regex]::Replace([string]$line, '\s+', '')
        if ($s.Length -eq 0) { continue }
        foreach ($m in [regex]::Matches($s, $pat)) {
            $score = $m.Groups[2].Value.Length
            if ($m.Groups[1].Success) { $score = $score + 10 }
            if ($score -gt $bestScore) { $bestScore = $score; $best = [int]$m.Groups[2].Value }
        }
    }
    return $best
}

# Parse "12,34" style coordinates. Separators may be OCR'd as , . : / \ | or full-width variants.
# -Loose marks the last-resort pass (no keyword, no X/Y marker): a coordinate line holds exactly
# two numbers, so anything with three or more is a clock or a timer, never a pair.
function Parse-CoordText {
    param([string]$Text, [switch]$StrictMode, [switch]$Loose)
    if ($null -eq $Text) { return $null }
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return $null }
    if ($StrictMode -and $t.IndexOf($script:kwCoord) -lt 0) { return $null }
    # Two colons in one line is a clock ('18:08:43'): the separator set below would happily pair
    # '8' with '0' and hand the user a wrong walking hint.
    if ([regex]::IsMatch($t, '[\uFF1A:].*[\uFF1A:]')) { return $null }
    # The clock is also read as '1 8 : 0 & 43' at some zooms, which the colon count above misses.
    # Three or more numbers on one loose line is never a coordinate.
    if ($Loose -and ([regex]::Matches($t, '\d+').Count -ge 3)) { return $null }
    $m = [regex]::Matches($t, '(\d{1,3})\s*[,\uFF0C\u3001\u3002\uFF1A.:;/\|\\-]\s*(\d{1,3})')
    if ($m.Count -gt 0) {
        return @([int]$m[0].Groups[1].Value, [int]$m[0].Groups[2].Value)
    }
    # Comma eaten by OCR: accept only a line holding exactly two 1-3 digit numbers
    $n = [regex]::Matches($t, '\d+')
    if ($n.Count -eq 2) {
        $a = $n[0].Value
        $b = $n[1].Value
        if ($a.Length -le 3 -and $b.Length -le 3) { return @([int]$a, [int]$b) }
    }
    return $null
}

# Coordinates are the only small number pair on screen; prefer a line mentioning the keyword
function Find-Coord {
    param($Lines)
    if ($null -eq $Lines) { return $null }
    $arr = @($Lines)
    foreach ($line in $arr) {
        $r = Get-XyPair $line
        if ($null -ne $r) { return $r }
    }
    # The engine splits the HUD row: 'X:11' and 'Y:90' land on different lines, sometimes with a
    # stray glyph between them and in either order, so both markers are matched per axis over the
    # whole block. Reusing the two-line join alone missed the real client (the pair sat at i and
    # i+2), and the fallback then read the game clock as '8,0'.
    $vx = Get-XyAxis $arr 'X'
    $vy = Get-XyAxis $arr 'Y'
    if ($null -ne $vx -and $null -ne $vy) { return @([int]$vx, [int]$vy) }
    # A marker anywhere in the block means the HUD is on screen: if its digits did not come out,
    # reporting "no coordinate" for this frame beats grabbing some other number pair.
    if ((Test-XyMarker ($arr -join ' ')) -or $null -ne $vx -or $null -ne $vy) { return $null }
    foreach ($line in $arr) {
        if ($line.IndexOf($script:kwCoord) -ge 0) {
            $r = Parse-CoordText $line
            if ($null -ne $r) { return $r }
        }
    }
    if ($Strict) { return $null }
    foreach ($line in $arr) {
        $r = Parse-CoordText $line -Loose
        if ($null -ne $r) { return $r }
    }
    return $null
}

# ---------------------------------------------------------------- hue channel
# Pull the quest line out as brightness so the OCR sees bright glyphs on black and ignores the
# scenery. The tracker prints the scene + coordinate in red, but the game's colour-weak mode
# repaints that same line yellow, so two metrics are combined:
#   red    - R clearly dominates both G and B (red text); green goes dark
#   yellow - both R and G sit above B (yellow / amber text); red goes dark
# Both metrics are mutually exclusive by construction, so the chroma pass is just their maximum.
# They are merged into ONE pass on purpose: a separate yellow pass would add a fourth vote and
# one pass that truncates '100' to '1' was enough to flip the majority vote to the wrong number.
#
# Near-white text stays as a dimmed copy: the anchor line (the one carrying 'zhong kui ghost
# hunt') is printed white, and the parser only accepts a scene + pair that sits right below an
# anchor inside the SAME pass. Dropping white made red quests unreadable - the colour pass then
# held the coordinate with no anchor to hang it on.
#
# The metrics are scaled by 1.5 (3/2), not by the earlier 3 and 2. A stronger factor saturates
# the antialiased edge of every stroke to 255, which fattens the glyphs until neighbouring ones
# touch: on the sample strips the two '0' merged and the pair came back as '1,142'. At 1.5 the
# edge ramp survives and all six samples read '100,142'.
# Lives before the self test so the channel math can be asserted without OCR.
function Convert-HueGray {
    param($bmp, [string]$Mode = 'chroma')
    $w = $bmp.Width
    $h = $bmp.Height
    $out = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.DrawImage($bmp, 0, 0, $w, $h)
    $g.Dispose()
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $d = $out.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($d.Stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $px, 0, $px.Length)
    for ($i = 0; $i -lt $px.Length; $i += 4) {
        $rr = [int]$px[$i + 2]; $gg = [int]$px[$i + 1]; $bb = [int]$px[$i]
        # Truncate rather than round: a [int] cast rounds to even, which would make the selftest
        # values (and the edge ramp) depend on the last bit of the division.
        $vr = [int][Math]::Truncate((($rr - [Math]::Max($gg, $bb)) * 3) / 2)
        $vy = [int][Math]::Truncate((([Math]::Min($rr, $gg) - $bb) * 3) / 2)
        # Yellow only counts while red is at least as strong as green, and only for bright pixels.
        # Measured on real screenshots with the colour-weak option on, the yellowish task words run
        # 176..232 on the red/green channel; the khaki grass showing through the translucent tracker
        # panel runs 128..160 and used to paint 43% of the strip bright.
        if ($rr -lt $gg) { $vy = 0 }
        if ([Math]::Min($rr, $gg) -lt 170) { $vy = 0 }
        if ($Mode -eq 'red') { $vv = $vr }
        elseif ($Mode -eq 'yellow') { $vv = $vy }
        elseif ($vy -gt $vr) { $vv = $vy }
        else { $vv = $vr }
        if ([Math]::Min([Math]::Min($rr, $gg), $bb) -ge 210) { $vv = 190 }
        if ($vv -lt 0) { $vv = 0 }
        if ($vv -gt 255) { $vv = 255 }
        $px[$i] = [byte]$vv; $px[$i + 1] = [byte]$vv; $px[$i + 2] = [byte]$vv
    }
    [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $d.Scan0, $px.Length)
    $out.UnlockBits($d)
    return $out
}

# ---------------------------------------------------------------- quest vote
# Majority vote across the passes: a scene name read by two passes beats a one-off misread, and
# inside that scene the most repeated pair wins. Ties keep the earlier pass.
# Lives before the self test so the vote can be asserted without OCR.
function Merge-QuestHits {
    param($Hits)
    # Copy through foreach: @() on a List<object> holding arrays throws "parameter type mismatch".
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($h in $Hits) { $list.Add($h) }
    if ($list.Count -eq 0) { return $null }
    $sceneKeys = New-Object System.Collections.Generic.List[string]
    $sceneCnt = New-Object System.Collections.Generic.List[int]
    foreach ($h in $list) {
        $k = [string]$h[0]
        $i = $sceneKeys.IndexOf($k)
        if ($i -lt 0) { $sceneKeys.Add($k); $sceneCnt.Add(1) } else { $sceneCnt[$i] = $sceneCnt[$i] + 1 }
    }
    $bi = 0
    for ($i = 1; $i -lt $sceneKeys.Count; $i++) {
        if ($sceneCnt[$i] -gt $sceneCnt[$bi]) { $bi = $i }
    }
    $scene = $sceneKeys[$bi]
    $pairKeys = New-Object System.Collections.Generic.List[string]
    $pairCnt = New-Object System.Collections.Generic.List[int]
    foreach ($h in $list) {
        if ([string]$h[0] -ne $scene) { continue }
        $k = [string]$h[1] + ',' + [string]$h[2]
        $i = $pairKeys.IndexOf($k)
        if ($i -lt 0) { $pairKeys.Add($k); $pairCnt.Add(1) } else { $pairCnt[$i] = $pairCnt[$i] + 1 }
    }
    if ($pairKeys.Count -eq 0) { return $null }
    # OCR drops digits far more often than it invents them, so '1,142' next to '100,142' is a
    # truncated read of that pair rather than a rival. Left alone it collects votes of its own and
    # can even outvote the correct pair 2:1, which would hand the user a wrong search box.
    for ($i = 0; $i -lt $pairKeys.Count; $i++) {
        if ($pairCnt[$i] -eq 0) { continue }
        $si = $pairKeys[$i] -split ','
        $li = $si[0].Length + $si[1].Length
        for ($j = 0; $j -lt $pairKeys.Count; $j++) {
            if ($i -eq $j) { continue }
            $sj = $pairKeys[$j] -split ','
            if (($sj[0].Length + $sj[1].Length) -le $li) { continue }
            if ($sj[0].StartsWith($si[0], [StringComparison]::Ordinal) -and $sj[1].StartsWith($si[1], [StringComparison]::Ordinal)) {
                $pairCnt[$i] = 0
                break
            }
        }
    }
    $bp = 0
    for ($i = 1; $i -lt $pairKeys.Count; $i++) {
        if ($pairCnt[$i] -gt $pairCnt[$bp]) { $bp = $i }
    }
    $seg = $pairKeys[$bp] -split ','
    return @($scene, [int]$seg[0], [int]$seg[1])
}

# ---------------------------------------------------------------- quest kind
# The tracker can hold two kinds of ghost-hunt task at once: the ordinary one (zhong kui) and the
# ghost-king one. They print the same 'scene + fake pair' shape, so the kind is taken from the
# anchor line itself and the two are voted on separately - merging them would mix the coordinates
# of two different tasks. 'Ghost king' wins over 'catch ghost' because the king wording usually
# contains the ordinary one ('zhua gui wang').
function Get-QuestKind {
    param([string]$Line)
    if ($null -eq $Line -or $Line.Length -eq 0) { return '' }
    $s = [regex]::Replace($Line, '\s+', '')
    $k1 = -join ([char]0x9B3C, [char]0x738B)              # ghost king
    $k2 = -join ([char]0x5730, [char]0x85CF, [char]0x738B) # di zang wang, the king quest giver
    if ($s.IndexOf($k1, [StringComparison]::Ordinal) -ge 0) { return 'k' }
    if ($s.IndexOf($k2, [StringComparison]::Ordinal) -ge 0) { return 'k' }
    $a1 = -join ([char]0x6349, [char]0x9B3C)   # capture-ghost anchor
    $a2 = -join ([char]0x6293, [char]0x9B3C)   # catch-ghost anchor
    $a3 = -join ([char]0x949F, [char]0x9998)   # zhong kui anchor
    foreach ($a in @($a1, $a2, $a3)) {
        if ($s.IndexOf($a, [StringComparison]::Ordinal) -ge 0) { return 'g' }
    }
    return ''
}

# ---------------------------------------------------------------- self test
if ($SelfTest) {
    $fails = New-Object System.Collections.Generic.List[string]
    $kw = $script:kwCoord
    $fwOpen = [char]0xFF08
    $fwClose = [char]0xFF09
    $fwComma = [char]0xFF0C
    $kwOpen = $kw + ': 12,34'
    $caseList = New-Object System.Collections.Generic.List[object]
    $caseList.Add(@('12,34', 12, 34))
    $caseList.Add(@('(123,45)', 123, 45))
    $caseList.Add(@('12 34', 12, 34))
    $caseList.Add(@('12.34', 12, 34))
    $caseList.Add(@('12:34', 12, 34))
    $caseList.Add(@($kwOpen, 12, 34))
    $caseList.Add(@(($fwOpen + '12' + $fwComma + '34' + $fwClose), 12, 34))
    $cases = $caseList.ToArray()
    foreach ($c in $cases) {
        $r = Parse-CoordText $c[0]
        if ($null -eq $r) { $fails.Add('parse-null: ' + $c[0]) }
        elseif ($r[0] -ne $c[1] -or $r[1] -ne $c[2]) { $fails.Add('parse-wrong: ' + $c[0] + ' got ' + $r[0] + ',' + $r[1]) }
    }
    $nulls = @('level 25 exp 1234', '5 min', 'no digits here')
    foreach ($s in $nulls) {
        $r = Parse-CoordText $s
        if ($null -ne $r) { $fails.Add('parse-false-positive: ' + $s + ' -> ' + $r[0] + ',' + $r[1]) }
    }
    if ($null -ne (Parse-CoordText 'level 25 exp 1234')) { }
    # HUD style "X:196 Y:64" - the form the game actually prints at the top-left
    $xyCases = New-Object System.Collections.Generic.List[string]
    $xyCases.Add('X:196 Y:64')
    $xyCases.Add('X' + [char]0xFF1A + '196 Y' + [char]0xFF1A + '64')
    $xyCases.Add('X : 196 Y : 64')
    $xyCases.Add(([string][char]0x00D7) + '196 Y64')
    $xyCases.Add('X: 1000 Y: 9')
    foreach ($s in $xyCases) {
        $r = Get-XyPair $s
        if ($null -eq $r) { $fails.Add('xy-null: ' + $s) }
        elseif ($r[0] -lt 1 -or $r[1] -lt 1) { $fails.Add('xy-wrong: ' + $s + ' -> ' + $r[0] + ',' + $r[1]) }
    }
    $rxy = Find-Coord @('noise', 'X: 196 Y: 64')
    if ($null -eq $rxy -or $rxy[0] -ne 196 -or $rxy[1] -ne 64) { $fails.Add('find-coord xy single line') }
    $rxy2 = Find-Coord @('noise', 'X: 196', 'Y: 64')
    if ($null -eq $rxy2 -or $rxy2[0] -ne 196 -or $rxy2[1] -ne 64) { $fails.Add('find-coord xy split lines') }
    if ($null -ne (Get-XyPair '19:00:37')) { $fails.Add('xy-false-positive clock') }
    # Labels present but digits unreadable: must not fall back to guessing some other pair
    if ($null -ne (Find-Coord @('X' + [char]0xFF1A + 'four6 Y' + [char]0xFF1A + '64', '99,11'))) { $fails.Add('xy-marker-loose-fallback') }
    if (-not (Test-XyMarker ('X' + [char]0xFF1A + 'xx Y' + [char]0xFF1A + 'yy'))) { $fails.Add('xy-marker-detect') }
    # Real client (screenshot, client 1615x1278): the HUD row comes back as '/ X: 11' and 'Y : 90'
    # on two lines with a stray glyph between them, and the loose fallback used to take the game
    # clock ('18:08:43' -> '8,0') instead. Three shapes have to hold:
    $times = ([string][char]0x00D7)
    $rsp = Find-Coord @('noise', ($times + '0 other'), '/X:11', 'junk0', 'Y:90')
    if ($null -eq $rsp -or $rsp[0] -ne 11 -or $rsp[1] -ne 90) { $fails.Add('find-coord hud split with stray glyph') }
    $rrev = Find-Coord @('Y: 90', 'X: 11')
    if ($null -eq $rrev -or $rrev[0] -ne 11 -or $rrev[1] -ne 90) { $fails.Add('find-coord hud split reversed') }
    $clockFw = '18' + [char]0xFF1A + '08' + [char]0xFF1A + '43'
    if ($null -ne (Parse-CoordText $clockFw)) { $fails.Add('coord-false-positive clock') }
    if ($null -ne (Find-Coord @('noise', $clockFw))) { $fails.Add('find-coord false-positive clock') }
    # the noisy clock as the OCR actually returns it at 2.0x, and a three-number loose line
    if ($null -ne (Find-Coord @('noise', '1 8 : 0 & 43'))) { $fails.Add('find-coord false-positive clock noisy') }
    $rl = Parse-CoordText '99,11' -Loose
    if ($null -eq $rl -or $rl[0] -ne 99 -or $rl[1] -ne 11) { $fails.Add('loose pair rejected') }
    # markers split over lines still count: digits lost on one axis must not unlock the loose pass
    if ($null -ne (Find-Coord @(('X' + [char]0xFF1A + '11'), ('Y' + [char]0xFF1A + 'xx'), '99,11'))) { $fails.Add('xy-marker-split-loose-fallback') }
    # strict mode must ignore lines without the keyword
    if ($null -ne (Parse-CoordText '25 34' -StrictMode)) { $fails.Add('strict-not-applied') }
    if ($null -eq (Parse-CoordText ($kw + ' 25,34') -StrictMode)) { $fails.Add('strict-keyword-miss') }
    # range / direction: rectangle X 50..150 Y 20..120
    $X1 = 50; $X2 = 150; $Y1 = 20; $Y2 = 120
    $rc = @(
        @(100, 70, $true, '', 0),
        @(100, 142, $false, 'dir_down', 22),
        @(30, 70, $false, 'dir_right', 20),
        @(30, 10, $false, 'dir_ru', 20),
        @(200, 200, $false, 'dir_ld', 80),
        @(50, 20, $true, '', 0),
        @(150, 120, $true, '', 0)
    )
    foreach ($c in $rc) {
        $inR = Test-InRange $c[0] $c[1]
        $h = Get-MoveHint $c[0] $c[1]
        if ($inR -ne $c[2]) { $fails.Add('range: ' + $c[0] + ',' + $c[1] + ' expect ' + $c[2]) }
        if (-not $inR) {
            if ($h.key -ne $c[3]) { $fails.Add('dir: ' + $c[0] + ',' + $c[1] + ' -> ' + $h.key + ' expect ' + $c[3]) }
            if ($h.dist -ne $c[4]) { $fails.Add('dist: ' + $c[0] + ',' + $c[1] + ' -> ' + $h.dist + ' expect ' + $c[4]) }
        }
    }
    # arrow rotation: clockwise from up, so 'walk right' points right on screen
    $arrowCases = New-Object System.Collections.Generic.List[object]
    $arrowCases.Add(@('dir_up', 0))
    $arrowCases.Add(@('dir_ru', 45))
    $arrowCases.Add(@('dir_right', 90))
    $arrowCases.Add(@('dir_rd', 135))
    $arrowCases.Add(@('dir_down', 180))
    $arrowCases.Add(@('dir_ld', 225))
    $arrowCases.Add(@('dir_left', 270))
    $arrowCases.Add(@('dir_lu', 315))
    $arrowCases.Add(@('', -1))
    $arrowCases.Add(@('dir_bogus', -1))
    foreach ($a in $arrowCases) {
        $got = Get-DirAngle $a[0]
        if ($got -ne $a[1]) { $fails.Add('arrow-angle ' + $a[0] + ' -> ' + $got + ' expect ' + $a[1]) }
    }
    # hue channel: red text lights up the red metric, colour-weak yellow / amber the yellow one,
    # the shipped 'chroma' pass takes whichever applies; near-white stays a dim anchor copy and
    # UI gray stays black in every metric (expected columns: red, yellow, chroma)
    $hueCases = New-Object System.Collections.Generic.List[object]
    $hueCases.Add(@('red-text', 220, 40, 40, 255, 0, 255))
    # a 50% blend of red text and the dark panel: the edge must stay unsaturated so two adjacent
    # strokes do not run together - this is what keeps '100' from coming back as '1'
    $hueCases.Add(@('red-edge', 141, 50, 52, 133, 0, 133))
    $hueCases.Add(@('yellow-text', 255, 230, 60, 37, 255, 255))
    $hueCases.Add(@('amber-text', 255, 180, 0, 112, 255, 255))
    $hueCases.Add(@('white-anchor', 240, 240, 240, 190, 190, 190))
    $hueCases.Add(@('green-heading', 60, 200, 60, 0, 0, 0))
    # field seen through the translucent tracker panel: green above red, so the yellow metric
    # must stay dark instead of painting the whole panel bright
    $hueCases.Add(@('grass-olive', 127, 160, 35, 0, 0, 0))
    # khaki grass where red equals green: only the brightness floor keeps it dark
    $hueCases.Add(@('grass-khaki', 160, 160, 48, 0, 0, 0))
    # the two shades the client actually uses for the yellowish task words
    $hueCases.Add(@('yellow-real', 176, 176, 16, 0, 240, 240))
    $hueCases.Add(@('yellow-real-hi', 192, 192, 16, 0, 255, 255))
    $hueCases.Add(@('panel-gray', 70, 70, 80, 0, 0, 0))
    $hueCases.Add(@('ui-bright-gray', 205, 205, 210, 0, 0, 0))
    $hb = New-Object System.Drawing.Bitmap 1, $hueCases.Count, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($i = 0; $i -lt $hueCases.Count; $i++) {
        $hc = $hueCases[$i]
        $hb.SetPixel(0, $i, [System.Drawing.Color]::FromArgb(255, [int]$hc[1], [int]$hc[2], [int]$hc[3]))
    }
    $hueModes = @('red', 'yellow', 'chroma')
    for ($m = 0; $m -lt $hueModes.Count; $m++) {
        $hm = Convert-HueGray $hb $hueModes[$m]
        for ($i = 0; $i -lt $hueCases.Count; $i++) {
            $hc = $hueCases[$i]
            $got = [int]$hm.GetPixel(0, $i).R
            $want = [int]$hc[4 + $m]
            if ($got -ne $want) { $fails.Add('hue-' + $hueModes[$m] + ' ' + $hc[0] + ' -> ' + $got + ' expect ' + $want) }
        }
        $hm.Dispose()
    }
    $hb.Dispose()
    # quest vote: a truncated pair must lose to the longer read even when it has more votes
    $voteCases = New-Object System.Collections.Generic.List[object]
    $voteCases.Add(@(@(@('jy', 1, 142), @('jy', 100, 142), @('jy', 1, 142)), 'jy', 100, 142))
    $voteCases.Add(@(@(@('jy', 100, 142), @('jy', 100, 142), @('jy', 88, 177)), 'jy', 100, 142))
    $voteCases.Add(@(@(@('jy', 100, 14), @('jy', 100, 142)), 'jy', 100, 142))
    $voteCases.Add(@(@(@('jy', 100, 142), @('cs', 88, 177)), 'jy', 100, 142))
    $voteCases.Add(@(@(@('jy', 12, 34), @('jy', 21, 34)), 'jy', 12, 34))
    # task kind: the king wording must not fall back to the ordinary anchor, and vice versa
    $king = -join ([char]0x9B3C, [char]0x738B)
    $kingCatch = -join ([char]0x6293, [char]0x9B3C, [char]0x738B)
    $ghostCatch = -join ([char]0x6349, [char]0x9B3C)
    $zhongkui = -join ([char]0x949F, [char]0x9998)
    $dizang = -join ([char]0x5730, [char]0x85CF, [char]0x738B)
    $kindCases = New-Object System.Collections.Generic.List[object]
    $kindCases.Add(@('zhong kui', ($zhongkui + ' ' + $ghostCatch + ' (1st): go to'), 'g'))
    $kindCases.Add(@('catch ghost', ($ghostCatch + ' go'), 'g'))
    $kindCases.Add(@('king plain', ($king + ' quest: go to'), 'k'))
    $kindCases.Add(@('king catch', ($kingCatch + ' go'), 'k'))
    $kindCases.Add(@('di zang wang', ($dizang + ' quest'), 'k'))
    $kindCases.Add(@('unrelated', 'artifact reminder', ''))
    foreach ($kc in $kindCases) {
        $got = Get-QuestKind $kc[1]
        if ($got -ne $kc[2]) { $fails.Add('kind ' + $kc[0] + ' -> [' + $got + '] expect [' + $kc[2] + ']') }
    }
    foreach ($vc in $voteCases) {
        $want = $vc[1] + ',' + $vc[2] + ',' + $vc[3]
        $r = Merge-QuestHits $vc[0]
        if ($null -eq $r) { $fails.Add('vote-null expect ' + $want) }
        elseif ($r[0] -ne $vc[1] -or $r[1] -ne $vc[2] -or $r[2] -ne $vc[3]) {
            $fails.Add('vote got ' + $r[0] + ',' + $r[1] + ',' + $r[2] + ' expect ' + $want)
        }
    }
    if ($null -ne (Merge-QuestHits @())) { $fails.Add('vote-empty') }
    $lines = @('some noise', $kw + ' 25,34')
    $fc = Find-Coord $lines
    if ($null -eq $fc -or $fc[0] -ne 25 -or $fc[1] -ne 34) { $fails.Add('find-coord keyword line') }
    $lines2 = @('noise line', '99,11')
    $fc2 = Find-Coord $lines2
    if ($null -eq $fc2 -or $fc2[0] -ne 99) { $fails.Add('find-coord loose line') }
    # multi-open pin: the id in the title decides the window, never the window size, and a pin no
    # visible window carries must resolve to nothing (the host then asks the user to pick again).
    # The brand and the ids must be markers no live window carries (not even a file path in some
    # other title), otherwise the player's desktop decides these cases instead of the probes.
    try {
        $wa = New-Object System.Windows.Forms.Form
        $wa.Text = 'PROBEZ-a [77700001]'
        $wa.Width = 420; $wa.Height = 320
        $wa.Show()
        $wb = New-Object System.Windows.Forms.Form
        $wb.Text = 'PROBEZ-b [77700002]'
        $wb.Width = 520; $wb.Height = 420
        $wb.Show()
        $ha = $wa.Handle.ToInt64(); $hb = $wb.Handle.ToInt64()
        if ([GhostWin]::FindGame('', 'PROBEZ', '').ToInt64() -ne $hb) { $fails.Add('pin-largest-window') }
        if ([GhostWin]::FindGame('', '77700001', '').ToInt64() -ne $ha) { $fails.Add('pin-by-id') }
        if ([GhostWin]::FindGame('', '77799999', '') -ne [IntPtr]::Zero) { $fails.Add('pin-missing-id') }
        $rows = @([GhostWin]::ListGames('', 'PROBEZ', ''))
        $hits = 0
        foreach ($row in $rows) { if ($row.IndexOf('PROBEZ') -ge 0) { $hits++ } }
        if ($hits -lt 2) { $fails.Add('pin-list ' + $hits + '/' + $rows.Count) }
        # Covered-window capture: the window's own surface comes back even when the screen shows
        # something else, and the crop is clamped to the window instead of silently reading past it.
        $capBmp = [GhostWin]::GrabWindow($ha, 0, 0, 40, 30)
        if ($null -eq $capBmp) { $fails.Add('cap-window-null') }
        else {
            if ($capBmp.Width -ne 40 -or $capBmp.Height -ne 30) { $fails.Add('cap-window-size ' + $capBmp.Width + 'x' + $capBmp.Height) }
            $capBmp.Dispose()
        }
        $capBig = [GhostWin]::GrabWindow($ha, 5, 5, 9000, 9000)
        if ($null -ne $capBig) {
            if ($capBig.Width -gt 900) { $fails.Add('cap-window-clamp ' + $capBig.Width) }
            $capBig.Dispose()
        }
        # Our own probe window is DPI aware, so the mapping must stay neutral - a wrong factor
        # here would silently shift every crop on a scaled display.
        if ([Math]::Abs([GhostWin]::RenderScale($ha) - 1.0) -gt 0.001) { $fails.Add('cap-dpi-scale ' + [GhostWin]::RenderScale($ha)) }
        $flat = New-Object System.Drawing.Bitmap 20, 20
        $fg2 = [System.Drawing.Graphics]::FromImage($flat)
        $fg2.Clear([System.Drawing.Color]::Black)
        $fg2.Dispose()
        if (-not [GhostWin]::IsBlank($flat)) { $fails.Add('cap-blank-flat') }
        $fg3 = [System.Drawing.Graphics]::FromImage($flat)
        $fg3.FillRectangle([System.Drawing.Brushes]::White, 0, 0, 10, 10)
        $fg3.Dispose()
        if ([GhostWin]::IsBlank($flat)) { $fails.Add('cap-blank-painted') }
        $flat.Dispose()
    } catch { $fails.Add('pin-ex ' + $_.Exception.Message) }
    finally {
        if ($null -ne $wa) { try { $wa.Close(); $wa.Dispose() } catch { } }
        if ($null -ne $wb) { try { $wb.Close(); $wb.Dispose() } catch { } }
    }
    # client-area helper: a real frame must report a client box inset by the title bar / border
    try {
        $tf = New-Object System.Windows.Forms.Form
        $tf.Text = 'GhostClientProbe'
        $tf.Width = 400; $tf.Height = 300
        $null = $tf.Handle
        $wr = New-Object GhostWin+RECT
        [void][GhostWin]::GetWindowRect($tf.Handle, [ref]$wr)
        $cr = New-Object GhostWin+RECT
        if (-not [GhostWin]::GetClientRectScreen($tf.Handle, [ref]$cr)) { $fails.Add('client-rect-call') }
        else {
            $ccw = $cr.Right - $cr.Left; $cch = $cr.Bottom - $cr.Top
            if ($ccw -lt 300 -or $cch -lt 200) { $fails.Add('client-rect-size ' + $ccw + 'x' + $cch) }
            if ($cr.Left -lt $wr.Left -or $cr.Top -lt $wr.Top) { $fails.Add('client-rect-origin') }
            Write-Output ('CLIENTRECT frame=' + ($wr.Right - $wr.Left) + 'x' + ($wr.Bottom - $wr.Top) + ' client@' + $cr.Left + ',' + $cr.Top + ' ' + $ccw + 'x' + $cch)
        }
        $tf.Dispose()
    } catch { $fails.Add('client-rect-ex ' + $_.Exception.Message) }
    $ab = Get-AutoBox 100 50 960 720
    if ($ab[0] -ne 100 -or $ab[1] -ne 50 -or $ab[2] -ne 288 -or $ab[3] -ne 144) { $fails.Add('autobox-960 ' + ($ab -join ',')) }
    $ab2 = Get-AutoBox 0 0 640 480
    if ($ab2[2] -ne 260 -or $ab2[3] -ne 130) { $fails.Add('autobox-floor ' + ($ab2 -join ',')) }
    if ($fails.Count -eq 0) { Write-Output 'SELFTEST_PASS' } else {
        Write-Output ('SELFTEST_FAIL ' + $fails.Count)
        $fails | ForEach-Object { Write-Output ('X ' + $_) }
    }
    exit $(if ($fails.Count -eq 0) { 0 } else { 1 })
}

# ---------------------------------------------------------------- OCR plumbing
$script:engine = $null
$script:asTaskGeneric = $null

function Await($op, $type) {
    if ($null -eq $script:asTaskGeneric) { throw 'OCR_NO_LANGUAGE_PACK' }
    $asTask = $script:asTaskGeneric.MakeGenericMethod($type)
    $netTask = $asTask.Invoke($null, @($op))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

function Get-OcrEngine {
    if ($null -ne $script:engine) { return $script:engine }
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    $e = $null
    try { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'zh-Hans-CN')) } catch { }
    if ($null -eq $e) { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if ($null -eq $e) { throw 'OCR_NO_LANGUAGE_PACK' }
    $script:engine = $e
    return $e
}

function Get-Thumb {
    param($bmp, [int]$n = 24)
    $small = New-Object System.Drawing.Bitmap $n, $n, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g3 = [System.Drawing.Graphics]::FromImage($small)
    $g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Low
    $g3.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g3.DrawImage($bmp, 0, 0, $n, $n)
    $g3.Dispose()
    $rect = New-Object System.Drawing.Rectangle 0, 0, $n, $n
    $d = $small.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($d.Stride * $n)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $px, 0, $px.Length)
    $st = $d.Stride
    $small.UnlockBits($d)
    $small.Dispose()
    $arr = New-Object byte[] ($n * $n)
    $k = 0
    for ($y = 0; $y -lt $n; $y++) {
        $o = $y * $st
        for ($x = 0; $x -lt $n; $x++) {
            $arr[$k] = [byte][int](($px[$o] + $px[$o + 1] + $px[$o + 2]) / 3)
            $k++
            $o += 4
        }
    }
    return , $arr
}

function Test-ThumbChanged {
    param($a, $b, [double]$minRatio)
    if ($null -eq $b -or $null -eq $a) { return $true }
    if ($b.Length -ne $a.Length) { return $true }
    $n = $a.Length
    $hit = 0
    for ($i = 0; $i -lt $n; $i++) {
        $d = [int]$a[$i] - [int]$b[$i]
        if ($d -gt 10 -or $d -lt -10) { $hit++ }
    }
    return (($hit / $n) -ge $minRatio)
}

function Read-OcrLines($bmp) {
    $bw = $bmp.Width; $bh = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bw, $bh
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($data.Stride * $bh)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $stride = $data.Stride
    $bmp.UnlockBits($data)
    if ($stride -ne ($bw * 4)) {
        $packed = New-Object byte[] ($bw * 4 * $bh)
        for ($y = 0; $y -lt $bh; $y++) { [Array]::Copy($raw, $y * $stride, $packed, $y * $bw * 4, $bw * 4) }
        $raw = $packed
    }
    $engine = Get-OcrEngine
    $buf = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($raw)
    $sbmp = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer($buf, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, $bw, $bh)
    $res = Await ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])
    $sbmp.Dispose()
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $res.Lines) {
        $t = $ln.Text
        if ($null -ne $t) { $t = $t.Trim() }
        if ($null -ne $t -and $t.Length -gt 0) { $out.Add($t) }
    }
    return , $out
}

# OCR at a given zoom. Callers retry at another zoom when a pass yields no coordinate:
# the small HUD glyphs fuse with the colon at some scales (a real frame came back as
# 'X <cjk> 2 ... Y : 250' at 2.0x and as 'X : 146 Y : 44' at 3.0x), and the scale that
# fuses depends on the digits and on the map behind the translucent strip, so no single
# default scale can be trusted.
function Get-LinesAtScale {
    param($SrcBmp, [double]$sc)
    if ($sc -le 1.0) { return , (Read-OcrLines $SrcBmp) }
    $bw2 = [int][Math]::Round($SrcBmp.Width * $sc)
    $bh2 = [int][Math]::Round($SrcBmp.Height * $sc)
    if ($bw2 -gt 8000 -or $bh2 -gt 8000) { return , (Read-OcrLines $SrcBmp) }
    $big = New-Object System.Drawing.Bitmap $bw2, $bh2
    $g2 = [System.Drawing.Graphics]::FromImage($big)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($SrcBmp, 0, 0, $bw2, $bh2)
    $g2.Dispose()
    $r = Read-OcrLines $big
    $big.Dispose()
    return , $r
}

# Read the box at the requested zoom and, if that pass finds no coordinate, walk a ladder of
# other zooms until one parses. Each extra pass costs ~150ms and only runs on a frame that would
# otherwise be reported as "no coordinate", which is the worse outcome for the user.
$script:scaleLadder = @(1.5, 2.0, 2.5, 3.0, 4.0)
function Read-CoordLines {
    param($SrcBmp, [double]$sc)
    $l1 = Get-LinesAtScale $SrcBmp $sc
    if ($null -ne (Find-Coord $l1)) { return , $l1 }
    foreach ($alt in $script:scaleLadder) {
        if ([Math]::Abs($alt - $sc) -lt 0.01) { continue }
        $l2 = Get-LinesAtScale $SrcBmp $alt
        if ($null -ne (Find-Coord $l2)) { return , $l2 }
    }
    return , $l1
}

# ---------------------------------------------------------------- overlay banner
$script:ovTitle = ''
$script:ovSub = ''
$script:ovDir = ''
$script:ovBg = [System.Drawing.Color]::FromArgb(70, 70, 80)
$script:ovVisible = $false
# Arrow box is a fixed square at the left edge of the banner; text starts after it
$script:arrowBox = 28
$script:arrowGap = 10
$script:fontMain = New-Object System.Drawing.Font ('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Bold)
$script:fontMid = New-Object System.Drawing.Font ('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
$script:fontSmall = New-Object System.Drawing.Font ('Microsoft YaHei', 8.5, [System.Drawing.FontStyle]::Bold)
$script:ovFontMain = $script:fontMain
$script:ovW = 520
$script:ovH = 58
$script:fontSub = New-Object System.Drawing.Font ('Microsoft YaHei', 9)
$script:brushMain = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$script:brushSub = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 235, 235))
# Scratch surface for measuring strings before choosing the banner width / font
$script:measBmp = New-Object System.Drawing.Bitmap 1, 1
$script:measG = [System.Drawing.Graphics]::FromImage($script:measBmp)
$script:measG.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$script:sfTight = [System.Drawing.StringFormat]::GenericTypographic

function Measure-TextWidth {
    param([string]$Text, $Font)
    if ($null -eq $Text -or $Text.Length -eq 0) { return 0 }
    $s = $script:measG.MeasureString($Text, $Font, (New-Object System.Drawing.SizeF 8000, 400), $script:sfTight)
    return [int][Math]::Ceiling($s.Width)
}

# Banner painting is shared by the live window and the proof screenshot
# Direction arrow: one path drawn pointing up, then rotated by the hint angle. A vector shape
# stays crisp at any DPI and does not depend on the font covering the four diagonal arrows.
function Draw-OverlayArrow {
    param($g, [int]$x, [int]$y, [int]$size, [int]$angle, $brush)
    $s = [double]$size
    $half = $s / 2.0
    $headY = -$s * 0.08        # base of the triangular head, just above the centre
    $headW = $s * 0.34
    $shaftW = $s * 0.10
    $tipY = -$half
    $botY = $half
    $negHeadW = -$headW
    $negShaftW = -$shaftW
    $pts = New-Object 'System.Drawing.PointF[]' 7
    $pts[0] = New-Object System.Drawing.PointF ([float]0), ([float]$tipY)
    $pts[1] = New-Object System.Drawing.PointF ([float]$headW), ([float]$headY)
    $pts[2] = New-Object System.Drawing.PointF ([float]$shaftW), ([float]$headY)
    $pts[3] = New-Object System.Drawing.PointF ([float]$shaftW), ([float]$botY)
    $pts[4] = New-Object System.Drawing.PointF ([float]$negShaftW), ([float]$botY)
    $pts[5] = New-Object System.Drawing.PointF ([float]$negShaftW), ([float]$headY)
    $pts[6] = New-Object System.Drawing.PointF ([float]$negHeadW), ([float]$headY)
    $state = $g.Save()
    $g.TranslateTransform([float]($x + $half), [float]($y + $half))
    if ($angle -ne 0) { $g.RotateTransform([float]$angle) }
    $g.FillPolygon($brush, $pts)
    $g.Restore($state)
}

function Draw-Banner {
    param($g, [int]$w, [int]$h, $bg, [string]$title, [string]$sub, [string]$dir = '')
    if ($null -ne $bg) { $g.Clear($bg) }
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $tx = 12
    $angle = Get-DirAngle $dir
    if ($angle -ge 0) {
        Draw-OverlayArrow $g 12 ([int](($h - $script:arrowBox) / 2)) $script:arrowBox $angle $script:brushMain
        $tx = 12 + $script:arrowBox + $script:arrowGap
    }
    $g.DrawString($title, $script:ovFontMain, $script:brushMain, $tx, 7)
    if ($sub.Length -gt 0) {
        $g.DrawString($sub, $script:fontSub, $script:brushSub, $tx, 33)
    }
}

$script:form = $null
if (-not $NoOverlay) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'Manual'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Opacity = 0.9
    $f.BackColor = $script:ovBg
    $f.Text = 'GadgetGhostMonitor'
    # DoubleBuffered is protected on Control - reach it through reflection to avoid flicker on repaint
    try {
        $f.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($f, $true, $null)
    } catch { }
    $f.Add_Paint({
            param($sender, $e)
            Draw-Banner $e.Graphics $sender.ClientRectangle.Width $sender.ClientRectangle.Height $null $script:ovTitle $script:ovSub $script:ovDir
        })
    # Create the handle first so the no-activate / click-through styles are in place before the
    # first paint: the banner must never steal focus from the game client
    $null = $f.Handle
    $ex = [GhostWin]::GetWindowLong($f.Handle, [GhostWin]::GWL_EXSTYLE)
    $ex = $ex -bor [GhostWin]::WS_EX_NOACTIVATE -bor [GhostWin]::WS_EX_TRANSPARENT -bor [GhostWin]::WS_EX_TOOLWINDOW
    [void][GhostWin]::SetWindowLong($f.Handle, [GhostWin]::GWL_EXSTYLE, $ex)
    $script:form = $f
}

function Show-Overlay {
    param([int]$wx, [int]$wy, [int]$ww, [string]$title, [string]$sub, $color, [string]$dir = '')
    if ($null -eq $script:form) { return }
    $script:ovTitle = $title
    $script:ovSub = $sub
    $script:ovDir = $dir
    if ($script:form.BackColor.ToArgb() -ne $color.ToArgb()) { $script:form.BackColor = $color }

    # Fit the banner to its text. The width is driven by the text, not the window: a narrow client
    # must still show a readable hint, so the banner is allowed to stick out a little.
    # An arrow takes a slice off the left edge, so the text gets that much less room.
    $maxW = 760
    $arrowW = 0
    if ((Get-DirAngle $dir) -ge 0) { $arrowW = $script:arrowBox + $script:arrowGap }
    $maxText = $maxW - 28 - $arrowW
    $font = $script:fontMain
    $need = Measure-TextWidth $title $font
    if ($need -gt $maxText) { $font = $script:fontMid; $need = Measure-TextWidth $title $font }
    if ($need -gt $maxText) { $font = $script:fontSmall; $need = Measure-TextWidth $title $font }
    $script:ovFontMain = $font
    $needSub = Measure-TextWidth $sub $script:fontSub
    $ow = [Math]::Min([Math]::Max([Math]::Max($need, $needSub) + 28 + $arrowW, 240 + $arrowW), $maxW)

    if ($ww -le 0) { $wx = 40; $wy = 40 }   # simulated run without a game window
    $ox = $wx + [int](($ww - $ow) / 2)
    $oy = $wy + 10
    [void][GhostWin]::SetWindowPos($script:form.Handle, [GhostWin]::HWND_TOPMOST, $ox, $oy, $ow, 58,
        ([GhostWin]::SWP_NOACTIVATE -bor [GhostWin]::SWP_SHOWWINDOW))
    $script:ovVisible = $true
    $script:ovW = $ow
    $script:ovH = 58
    $script:form.Invalidate()
}

# Screenshot the banner itself - used to prove the overlay renders when no game client is around.
# Rendered off the live controls: copying a layered window from the screen depends on DWM timing.
function Save-OverlayShot {
    param([string]$Path)
    if ($null -eq $script:form) { return }
    try {
        $w = $script:ovW; $h = $script:ovH
        if ($w -lt 8 -or $h -lt 8) { return }
        $b = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($b)
        Draw-Banner $g $w $h $script:form.BackColor $script:ovTitle $script:ovSub $script:ovDir
        $g.Dispose()
        $b.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
    } catch { }
}

function Hide-Overlay {
    if ($null -eq $script:form) { return }
    [void][GhostWin]::SetWindowPos($script:form.Handle, [GhostWin]::HWND_TOPMOST, 0, 0, 0, 0,
        ([GhostWin]::SWP_NOACTIVATE -bor [GhostWin]::SWP_NOMOVE -bor [GhostWin]::SWP_NOSIZE -bor 0x0080))
    $script:ovVisible = $false
}

# ---------------------------------------------------------------- result file
$script:resMeta = New-Object System.Collections.Generic.List[string]

# -HudDump: keep the cropped box and every raw OCR line, so a wrong pair can be traced to the
# engine instead of guessed at. Called before the bitmap is disposed.
function Write-HudDump {
    param($Bmp, $Lines)
    $script:resMeta.Clear()
    if ($null -ne $Bmp) {
        try { $Bmp.Save((Join-Path $env:TEMP 'gadget_hud_box.png'), [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
    }
    $li = 0
    foreach ($ln in @($Lines)) {
        $li++
        $script:resMeta.Add('DUMP' + "`t" + 'line' + "`t" + $li + "`t" + [string]$ln)
    }
}

function Write-Result {
    param([string]$State, [string]$Coord, [string]$InRange, [string]$Dir, [string]$Dist, [long]$Ms, [string]$Title, [string]$Sub, [string]$Mode, [string]$Cap)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('META' + "`t" + 'status' + "`t" + $State)
    [void]$sb.AppendLine('META' + "`t" + 'coord' + "`t" + $Coord)
    [void]$sb.AppendLine('META' + "`t" + 'inrange' + "`t" + $InRange)
    [void]$sb.AppendLine('META' + "`t" + 'dir' + "`t" + $Dir)
    [void]$sb.AppendLine('META' + "`t" + 'dist' + "`t" + $Dist)
    [void]$sb.AppendLine('META' + "`t" + 'ms' + "`t" + $Ms)
    [void]$sb.AppendLine('META' + "`t" + 'mode' + "`t" + $Mode)
    [void]$sb.AppendLine('META' + "`t" + 'pin' + "`t" + $script:pinId)
    [void]$sb.AppendLine('META' + "`t" + 'cap' + "`t" + $Cap)
    [void]$sb.AppendLine('META' + "`t" + 'range' + "`t" + $X1 + ',' + $X2 + ',' + $Y1 + ',' + $Y2)
    [void]$sb.AppendLine('LINE' + "`t" + '0' + "`t" + $Title)
    if ($Sub.Length -gt 0) { [void]$sb.AppendLine('LINE' + "`t" + '1' + "`t" + $Sub) }
    foreach ($dm in $script:resMeta) { [void]$sb.AppendLine($dm) }
    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($OutFile, $sb.ToString() + 'EOF' + "`t" + [DateTime]::Now.Ticks, $enc)
    } catch { }
}

if ($PidFile.Length -gt 0) {
    try { [System.IO.File]::WriteAllText($PidFile, [string]$PID, (New-Object System.Text.UTF8Encoding $false)) } catch { }
}

# ---------------------------------------------------------------- quest reader
# The ghost-hunt task is printed in the quest tracker at the right edge of the client:
#   (green) the ghost-hunt heading
#   (white) 'zhong kui ghost hunt (1st): go to'
#   (colour) scene name + fake coordinate, e.g. 'jianyecheng100,142', (white) 'nearby'
# The scene name and the fake coordinate share the colour line: red normally, yellow once the
# client's colour-weak mode is switched on. A plain gray read can lose that line against the
# scenery; the strip is therefore read twice in gray plus once through the chroma channel (see
# Convert-HueGray) and every pass is parsed and voted on separately.
#
# Two tasks can sit in the tracker at the same time - the ordinary ghost hunt and the ghost-king
# hunt. Both print 'scene + fake pair' under their own anchor, so the anchor decides the kind (see
# Get-QuestKind), each kind is voted on separately, and when both kinds come back the reader
# reports 'choose' with both pairs instead of picking one silently.

function Get-QuestBox {
    param([int]$ox, [int]$oy, [int]$ow, [int]$oh)
    $bx = $ox + [int][Math]::Round($ow * 0.82)
    $bw = [int][Math]::Round($ow * 0.18)
    $by = $oy + [int][Math]::Round($oh * 0.09)
    $bh = [int][Math]::Round($oh * 0.51)
    if ($bw -lt 140) { $bw = 140 }
    if ($bh -lt 200) { $bh = 200 }
    if ($bx + $bw -gt $ox + $ow) { $bw = $ox + $ow - $bx }
    if ($by + $bh -gt $oy + $oh) { $bh = $oy + $oh - $by }
    if ($bw -lt 24) { $bw = 24 }
    if ($bh -lt 24) { $bh = 24 }
    return @($bx, $by, $bw, $bh)
}

$script:mapIds = @('jy', 'al', 'cs', 'zz', 'bx', 'xl', 'ne', 'pt', 'wz', 'jnyw', 'dtjw', 'hgs', 'd3', 'h1', 'qls', 'bj', 'tg', 'byd', 'wzs', 'nw')
$script:mapNames = @{}
foreach ($mid in $script:mapIds) {
    $mv = [string]$script:txt['map_' + $mid]
    # A missing key falls back to the key itself ('map_jy'): keep CJK names only, otherwise the
    # 2-char prefix fallback would happily match latin garbage in the OCR output.
    if ($mv.Length -ge 2 -and [int]$mv[0] -ge 0x4E00 -and [int]$mv[0] -le 0x9FFF) { $script:mapNames[$mid] = $mv }
}

# Longest exact name wins; a 2-char prefix is the fallback for one misread glyph.
function Find-Scene {
    param([string]$Text)
    if ($null -eq $Text -or $Text.Length -eq 0) { return $null }
    $bestId = ''
    $bestPos = -1
    $bestLen = 0
    foreach ($mid in $script:mapNames.Keys) {
        $nm = $script:mapNames[$mid]
        $i = $Text.IndexOf($nm, [StringComparison]::Ordinal)
        if ($i -ge 0 -and $nm.Length -gt $bestLen) { $bestId = $mid; $bestPos = $i; $bestLen = $nm.Length }
    }
    if ($bestPos -ge 0) { return @($bestId, $bestPos) }
    foreach ($mid in $script:mapNames.Keys) {
        $nm = $script:mapNames[$mid]
        $i = $Text.IndexOf($nm.Substring(0, 2), [StringComparison]::Ordinal)
        if ($i -ge 0) { return @($mid, $i) }
    }
    return $null
}

# Anchors are mandatory: a coordinate printed by an unrelated quest must never be taken.
# Every OCR pass is parsed on its own. Gluing the passes into one string would let a scene
# name read by one pass land behind an anchor read by another (wrong map, wrong pair).
# Returns every candidate found, tagged with its kind ('g' ordinary, 'k' ghost king), so the
# caller can vote per kind and still tell the user which task a pair belongs to.
function Get-QuestFromLines {
    param($Lines)
    $arr = @($Lines)
    $n = $arr.Count
    $out = New-Object System.Collections.Generic.List[object]
    if ($n -eq 0) { return , $out }
    $anchors = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $n; $i++) {
        $k = Get-QuestKind ([string]$arr[$i])
        if ($k.Length -gt 0) { $anchors.Add(@($i, $k)) }
    }
    if ($anchors.Count -eq 0) { return , $out }
    # The task text is either one line (scene + pair together) or two lines (scene, then pair),
    # so a scene name found at or below the anchor is looked for in its own line and the next two.
    foreach ($an in $anchors) {
        $ai = [int]$an[0]
        $kind = [string]$an[1]
        $lim = $ai + 2
        if ($lim -ge $n) { $lim = $n - 1 }
        $loose = $null
        $hit = $null
        for ($j = $ai; $j -le $lim -and $null -eq $hit; $j++) {
            # The engine spaces out CJK glyphs ('scene name 100 , 142'), so names and pairs are
            # matched on a whitespace-free copy of the line.
            $txt = [regex]::Replace([string]$arr[$j], '\s+', '')
            $sc = Find-Scene $txt
            if ($null -eq $sc) { continue }
            $from = [int]$sc[1]
            if ($from -gt $txt.Length) { $from = $txt.Length }
            $tail = $txt.Substring($from)
            if ($tail.Length -gt 18) { $tail = $tail.Substring(0, 18) }
            $m = [regex]::Match($tail, '(\d{1,4})\D{1,4}(\d{1,4})')
            if ($m.Success) {
                $vx = [int]$m.Groups[1].Value
                $vy = [int]$m.Groups[2].Value
                if ($vx -le 999 -and $vy -le 999) { $hit = @($kind, $sc[0], $vx, $vy) }
            }
            if ($null -ne $hit -or $null -ne $loose) { continue }
            # Scene name alone on its line: accept a pair from the two lines below it.
            for ($k = $j + 1; $k -le $lim; $k++) {
                $m2 = [regex]::Match([regex]::Replace([string]$arr[$k], '\s+', ''), '(\d{1,4})\D{1,4}(\d{1,4})')
                if (-not $m2.Success) { continue }
                $lx = [int]$m2.Groups[1].Value
                $ly = [int]$m2.Groups[2].Value
                if ($lx -le 999 -and $ly -le 999) { $loose = @($kind, $sc[0], $lx, $ly) }
                break
            }
        }
        if ($null -ne $hit) { $out.Add($hit) }
        elseif ($null -ne $loose) { $out.Add($loose) }
    }
    return , $out
}

function Read-QuestStrip {
    param($bmp)
    # One string array per pass. Three passes, not four: each extra pass is another vote, and a
    # pass that drops a digit would then be able to outvote the two that read it correctly.
    $passes = New-Object System.Collections.Generic.List[object]
    $passes.Add((Get-LinesAtScale $bmp 2.0))
    $passes.Add((Get-LinesAtScale $bmp 3.0))
    # The chroma mask is a hard-edged image, so the two round glyphs of '00' can merge at the lower
    # zooms and the pair comes back as '1,142'. 4.0x separates them and read digits right on all
    # six sample strips - the gray passes stay at 2.0/3.0 as before.
    $chromaBmp = Convert-HueGray $bmp 'chroma'
    $passes.Add((Get-LinesAtScale $chromaBmp 4.0))
    $chromaBmp.Dispose()
    return , $passes
}

if ($ReadQuest) {
    $qBrand = $brand
    $qExclude = $exclude
    if ($ProcName.Length -gt 0) { $qBrand = '' }
    $qScene = ''
    $qX = -1
    $qY = -1
    $qTask = ''
    $qOpt1 = ''
    $qOpt2 = ''
    $qState = 'no_window'
    $qErr = ''
    $qTry = 0
    $qDump = New-Object System.Collections.Generic.List[string]
    $deadline = [DateTime]::Now.AddMilliseconds($QuestTimeout)
    while ($true) {
        $qTry++
        $qState = 'no_window'
        try {
            # -OcrFile replays a saved client screenshot, so the whole reader can be verified
            # without owning the game window (and without waiting for a real ghost quest).
            $qimg = $null
            $qox = 0; $qoy = 0; $qow = 0; $qoh = 0
            if ($OcrFile.Length -gt 0) {
                $qsrc = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $OcrFile).Path)
                $qow = $qsrc.Width; $qoh = $qsrc.Height
                $qimg = New-Object System.Drawing.Bitmap $qow, $qoh
                $qg = [System.Drawing.Graphics]::FromImage($qimg)
                $qg.DrawImage($qsrc, 0, 0, $qow, $qoh)
                $qg.Dispose()
                $qsrc.Dispose()
            } else {
                $hwnd = Get-GameWindow $ProcName $qBrand $qExclude
                if ($hwnd -eq [IntPtr]::Zero) {
                    $qState = 'no_window'
                } elseif ([GhostWin]::IsIconic($hwnd)) {
                    $qState = 'minimized'
                } else {
                    # Same client-anchored box in both capture modes: the window grab is offset by the
                    # frame, so the quest strip keeps its position whether the client is covered or not.
                    $qwr = New-Object GhostWin+RECT
                    [void][GhostWin]::GetWindowRect($hwnd, [ref]$qwr)
                    $cr = New-Object GhostWin+RECT
                    if ([GhostWin]::GetClientRectScreen($hwnd, [ref]$cr)) {
                        $qox = $cr.Left; $qoy = $cr.Top; $qow = $cr.Right - $cr.Left; $qoh = $cr.Bottom - $cr.Top
                    } else {
                        $qox = $qwr.Left; $qoy = $qwr.Top
                        $qow = $qwr.Right - $qwr.Left; $qoh = $qwr.Bottom - $qwr.Top
                    }
                    if ($qow -lt 320 -or $qoh -lt 240) {
                        $qState = 'no_window'
                    } else {
                        if ($Capture -ne 'screen') {
                            try {
                                $qshot = Get-WindowCrop $hwnd ($qox - $qwr.Left) ($qoy - $qwr.Top) $qow $qoh
                                if ($null -ne $qshot) { $qimg = $qshot }
                            } catch { }
                        }
                        if ($null -eq $qimg) {
                            $qimg = New-Object System.Drawing.Bitmap $qow, $qoh
                            $qg = [System.Drawing.Graphics]::FromImage($qimg)
                            $qg.CopyFromScreen($qox, $qoy, 0, 0, (New-Object System.Drawing.Size $qow, $qoh))
                            $qg.Dispose()
                        }
                    }
                }
            }
            if ($null -ne $qimg -and $qow -ge 320 -and $qoh -ge 240) {
                $box = Get-QuestBox $qox $qoy $qow $qoh
                $strip = New-Object System.Drawing.Bitmap $box[2], $box[3]
                $gs = [System.Drawing.Graphics]::FromImage($strip)
                $gs.DrawImage($qimg, (New-Object System.Drawing.Rectangle 0, 0, $box[2], $box[3]),
                    (New-Object System.Drawing.Rectangle ($box[0] - $qox), ($box[1] - $qoy), $box[2], $box[3]),
                    [System.Drawing.GraphicsUnit]::Pixel)
                $gs.Dispose()
                $qpasses = Read-QuestStrip $strip
                if ($QuestDump -and $qTry -eq 1) {
                    try { $strip.Save((Join-Path $env:TEMP 'gadget_quest_strip.png'), [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
                    $pi = 0
                    foreach ($qp in $qpasses) {
                        $pi++
                        $qDump.Add('DUMP' + "`t" + 'pass' + "`t" + $pi + "`t" + 'lines' + "`t" + @($qp).Count)
                        foreach ($ln in $qp) { $qDump.Add('DUMP' + "`t" + 'line' + "`t" + $pi + "`t" + [string]$ln) }
                    }
                }
                $strip.Dispose()
                # Vote per task kind: the ordinary task and the ghost-king task print the same
                # shape, so every candidate is filed under its kind and each kind is voted on
                # on its own - one kind's coordinate must never be averaged with the other's.
                $hitsG = New-Object System.Collections.Generic.List[object]
                $hitsK = New-Object System.Collections.Generic.List[object]
                foreach ($qp in $qpasses) {
                    $cs = Get-QuestFromLines $qp
                    foreach ($c in $cs) {
                        $h = @([string]$c[1], [int]$c[2], [int]$c[3])
                        if ([string]$c[0] -eq 'k') { $hitsK.Add($h) } else { $hitsG.Add($h) }
                    }
                }
                $opts = New-Object System.Collections.Generic.List[object]
                $winG = Merge-QuestHits $hitsG
                if ($null -ne $winG) { $opts.Add(@('ghost', $winG)) }
                $winK = Merge-QuestHits $hitsK
                if ($null -ne $winK) { $opts.Add(@('king', $winK)) }
                if ($opts.Count -gt 0) {
                    $qTask = [string]$opts[0][0]
                    $qScene = [string]$opts[0][1][0]
                    $qX = [int]$opts[0][1][1]
                    $qY = [int]$opts[0][1][2]
                    if ($opts.Count -ge 2) {
                        # Both tasks are up: hand both pairs to the host so it can ask which one
                        # the user wants, instead of silently betting on one of them.
                        $qState = 'choose'
                        $qOpt1 = [string]$opts[0][0] + '|' + [string]$opts[0][1][0] + '|' + [int]$opts[0][1][1] + '|' + [int]$opts[0][1][2]
                        $qOpt2 = [string]$opts[1][0] + '|' + [string]$opts[1][1][0] + '|' + [int]$opts[1][1][1] + '|' + [int]$opts[1][1][2]
                    } else {
                        $qState = 'ok'
                    }
                } else {
                    $qState = 'no_quest'
                }
            }
            if ($null -ne $qimg) { $qimg.Dispose() }
            if ($qState -eq 'ok' -or $qState -eq 'choose') { break }
        } catch {
            $qState = 'error'
            $qErr = $_.Exception.Message
            if ($null -ne $_.InvocationInfo) { $qErr = $qErr + ' @L' + $_.InvocationInfo.ScriptLineNumber }
        }
        if ([DateTime]::Now -ge $deadline) { break }
        Start-Sleep -Milliseconds 600
    }
    $qOk = '0'
    if ($qScene.Length -gt 0) { $qOk = '1' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('META' + "`t" + 'status' + "`t" + $qState)
    [void]$sb.AppendLine('META' + "`t" + 'quest' + "`t" + $qOk)
    [void]$sb.AppendLine('META' + "`t" + 'task' + "`t" + $qTask)
    [void]$sb.AppendLine('META' + "`t" + 'scene' + "`t" + $qScene)
    [void]$sb.AppendLine('META' + "`t" + 'fakex' + "`t" + $qX)
    [void]$sb.AppendLine('META' + "`t" + 'fakey' + "`t" + $qY)
    if ($qOpt1.Length -gt 0) {
        [void]$sb.AppendLine('META' + "`t" + 'opt1' + "`t" + $qOpt1)
        [void]$sb.AppendLine('META' + "`t" + 'opt2' + "`t" + $qOpt2)
    }
    [void]$sb.AppendLine('META' + "`t" + 'tries' + "`t" + $qTry)
    if ($qErr.Length -gt 0) { [void]$sb.AppendLine('META' + "`t" + 'error' + "`t" + $qErr) }
    foreach ($dl in $qDump) { [void]$sb.AppendLine($dl) }
    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($OutFile, $sb.ToString() + 'EOF' + "`t" + [DateTime]::Now.Ticks, $enc)
    } catch { }
    exit 0
}

# ---------------------------------------------------------------- main loop
$brandKey = $brand
if ($ProcName.Length -gt 0) { $brandKey = '' }

$lastThumb = $null
$runNo = 0
$diffMin = 0.012
if ($RelW -le 0) { $diffMin = 0.02 }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
do {
    $runNo++
    $state = 'error'
    $coordText = ''
    $inRange = '0'
    $dirKey = ''
    $dist = 0
    $title = $script:txt['no_window']
    $sub = ''
    $bg = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $wx = 0; $wy = 0; $ww = 0; $wh = 0
    $capText = ''
    $modeText = $(if ($script:autoBox) { 'auto' } else { 'custom' })
    $sw.Restart()
    $lines = $null
    $simulated = ($SimX -ge 0 -and $SimY -ge 0)

    try {
        if ($OcrFile.Length -gt 0) {
            # OCR an existing picture instead of the live screen: lets the whole pipeline be tested
            # without owning the game window (and without stealing focus from it)
            $hwnd = Get-GameWindow $ProcName $brandKey $exclude
            if ($hwnd -ne [IntPtr]::Zero) {
                $r = New-Object GhostWin+RECT
                [void][GhostWin]::GetWindowRect($hwnd, [ref]$r)
                $wx = $r.Left; $wy = $r.Top; $ww = $r.Right - $r.Left; $wh = $r.Bottom - $r.Top
            }
            $src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $OcrFile).Path)
            # Same box as the live path so an offline run proves the real crop geometry
            $bx = 0; $by = 0; $bw = $src.Width; $bh = $src.Height
            if ($script:autoBox) {
                $box = Get-AutoBox 0 0 $src.Width $src.Height
                $bx = $box[0]; $by = $box[1]; $bw = $box[2]; $bh = $box[3]
            }
            if ($bx + $bw -gt $src.Width) { $bw = $src.Width - $bx }
            if ($by + $bh -gt $src.Height) { $bh = $src.Height - $by }
            if ($bw -lt 8 -or $bh -lt 8) { $bx = 0; $by = 0; $bw = $src.Width; $bh = $src.Height }
            $modeText = $(if ($script:autoBox) { 'auto' } else { 'custom' }) + ' ' + $bw + 'x' + $bh
            $bmp = New-Object System.Drawing.Bitmap $bw, $bh
            $gb = [System.Drawing.Graphics]::FromImage($bmp)
            $gb.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $bw, $bh),
                (New-Object System.Drawing.Rectangle $bx, $by, $bw, $bh), [System.Drawing.GraphicsUnit]::Pixel)
            $gb.Dispose()
            $src.Dispose()
            $lines = Read-CoordLines $bmp $Scale
            if ($HudDump -and $runNo -eq 1) { Write-HudDump $bmp $lines }
            $bmp.Dispose()
        } elseif ($simulated) {
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add($script:kwCoord + ' ' + $SimX + ',' + $SimY)
            $hwnd = Get-GameWindow $ProcName $brandKey $exclude
            if ($hwnd -ne [IntPtr]::Zero) {
                $r = New-Object GhostWin+RECT
                [void][GhostWin]::GetWindowRect($hwnd, [ref]$r)
                $wx = $r.Left; $wy = $r.Top; $ww = $r.Right - $r.Left; $wh = $r.Bottom - $r.Top
            }
        } else {
            $hwnd = Get-GameWindow $ProcName $brandKey $exclude
            if ($hwnd -eq [IntPtr]::Zero) {
                # A pin that no longer matches a window means the character was closed or another
                # tab is active: say so instead of silently watching someone else's client.
                if ($script:pinId.Length -gt 0) { throw '__PIN_LOST__' }
                throw '__NO_WINDOW__'
            }
            if ([GhostWin]::IsIconic($hwnd)) { throw '__MINIMIZED__' }

            $r = New-Object GhostWin+RECT
            [void][GhostWin]::GetWindowRect($hwnd, [ref]$r)
            $wx = $r.Left; $wy = $r.Top; $ww = $r.Right - $r.Left; $wh = $r.Bottom - $r.Top

            $cx = $wx; $cy = $wy; $cw = $ww; $ch = $wh
            if ($script:autoBox) {
                # Anchor to the client area: the outer frame (title bar + border) would shift the crop
                $cr = New-Object GhostWin+RECT
                $box = $null
                try {
                    if ([GhostWin]::GetClientRectScreen($hwnd, [ref]$cr)) {
                        $crw = $cr.Right - $cr.Left; $crh = $cr.Bottom - $cr.Top
                        if ($crw -ge 24 -and $crh -ge 24) { $box = Get-AutoBox $cr.Left $cr.Top $crw $crh }
                    }
                } catch { }
                if ($null -eq $box) { $box = Get-AutoBox $wx $wy $ww $wh }
                $cx = $box[0]; $cy = $box[1]; $cw = $box[2]; $ch = $box[3]
            } else {
                $cx = $wx + $RelX; $cy = $wy + $RelY; $cw = $RelW; $ch = $RelH
            }

            # The client's own surface first: a covered client still yields its real pixels, while
            # the screen below shows whatever window is painted on top of it.
            $bmp = $null
            if ($Capture -ne 'screen') {
                try {
                    $shot = Get-WindowCrop $hwnd ($cx - $wx) ($cy - $wy) $cw $ch
                    if ($null -ne $shot) { $bmp = $shot; $capText = 'window' }
                } catch { }
            }
            if ($null -eq $bmp) {
                # Screen fallback: realtime never steals focus, so it only runs while the client owns
                # the foreground - and a pinned client must be the foreground window itself.
                if (-not $IgnoreFocus) {
                    $fg = [GhostWin]::GetForegroundWindow()
                    if ($script:pinId.Length -gt 0) {
                        # Pinned clients of one process share a process id, so the process test would
                        # pass with another client in front - and CopyFromScreen would then read that
                        # window's pixels. The pinned window must be the foreground one itself.
                        if ($fg -ne $hwnd) { throw '__PIN_HIDDEN__' }
                    } elseif (-not [GhostWin]::SameProcess($fg, $hwnd)) {
                        throw '__NOT_FOREGROUND__'
                    }
                }
                $vx = [GhostWin]::GetSystemMetrics(76); $vy = [GhostWin]::GetSystemMetrics(77)
                $vw = [GhostWin]::GetSystemMetrics(78); $vh = [GhostWin]::GetSystemMetrics(79)
                if ($cx -lt $vx) { $cw = $cw - ($vx - $cx); $cx = $vx }
                if ($cy -lt $vy) { $ch = $ch - ($vy - $cy); $cy = $vy }
                if ($cx + $cw -gt $vx + $vw) { $cw = $vx + $vw - $cx }
                if ($cy + $ch -gt $vy + $vh) { $ch = $vy + $vh - $cy }
                if ($cw -lt 24 -or $ch -lt 24) { throw 'REGION_INVALID' }
                $bmp = New-Object System.Drawing.Bitmap $cw, $ch
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($cx, $cy, 0, 0, (New-Object System.Drawing.Size $cw, $ch))
                $g.Dispose()
                $capText = 'screen'
            }
            $modeText = $(if ($script:autoBox) { 'auto' } else { 'custom' }) + ' ' + $cw + 'x' + $ch

            $thumb = Get-Thumb $bmp
            $needOcr = $true
            # A small box is OCR'd every tick: one changed digit moves too few pixels for the
            # 24x24 thumbnail to cross the change threshold, and a stale coordinate is worse
            # than ~100ms of extra work.
            if ($SimX -lt 0 -and ($cw * $ch) -gt 120000) { $needOcr = Test-ThumbChanged $thumb $lastThumb $diffMin }
            if ($needOcr) {
                if ($ShotFile.Length -gt 0 -and $runNo -eq 1) { try { $bmp.Save($ShotFile, [System.Drawing.Imaging.ImageFormat]::Png) } catch { } }
                $lines = Read-CoordLines $bmp $Scale
                if ($HudDump -and $runNo -eq 1) { Write-HudDump $bmp $lines }
                $bmp.Dispose()
                $lastLines = $lines
                $lastThumb = $thumb
            } else {
                $bmp.Dispose()
                $lines = $lastLines
            }
        }

        $coord = Find-Coord $lines
        if ($null -eq $coord) {
            $state = 'no_coord'
            $title = $script:txt['no_coord']
            $sub = $script:txt['range'] + ' X ' + $X1 + '~' + $X2 + ' | Y ' + $Y1 + '~' + $Y2
            $bg = [System.Drawing.Color]::FromArgb(60, 60, 72)
        } else {
            $px2 = $coord[0]; $py2 = $coord[1]
            $coordText = '' + $px2 + ',' + $py2
            $in = Test-InRange $px2 $py2
            if ($in) {
                $state = 'ok'
                $inRange = '1'
                $title = $script:txt['in_range'] + ' ' + $script:txt['current'] + ' (' + $coordText + ')'
                if ($Half.Length -gt 0) { $title = $title + ' | ' + $script:txt['look_at'] + $script:txt['quad_' + $Half] }
                $bg = [System.Drawing.Color]::FromArgb(28, 122, 66)
            } else {
                $h = Get-MoveHint $px2 $py2
                $state = 'ok'
                $dirKey = $h.key
                $dist = $h.dist
                $title = $script:txt['out_of_range'] + ' ' + $script:txt['current'] + ' (' + $coordText + ') ' +
                    $script:txt[$h.key] + ' ' + $script:txt['ahead'] + $h.dist + $script:txt['cells']
                $bg = [System.Drawing.Color]::FromArgb(178, 42, 42)
            }
            $sub = $script:txt['range'] + ' X ' + $X1 + '~' + $X2 + ' | Y ' + $Y1 + '~' + $Y2
            if ($FakeX -ge 0 -and $FakeY -ge 0) { $sub = $sub + ' | ' + $FakeX + ',' + $FakeY }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -eq '__NO_WINDOW__') {
            $state = 'no_window'
            $title = $script:txt['no_window']
            Hide-Overlay
        } elseif ($msg -eq '__MINIMIZED__') {
            $state = 'minimized'
            $title = $script:txt['minimized']
            Hide-Overlay
        } elseif ($msg -eq '__NOT_FOREGROUND__') {
            $state = 'not_foreground'
            $title = $script:txt['not_foreground']
            Hide-Overlay
        } elseif ($msg -eq '__PIN_LOST__') {
            $state = 'pin_lost'
            $title = $script:txt['pin_lost']
            Hide-Overlay
        } elseif ($msg -eq '__PIN_HIDDEN__') {
            $state = 'pin_hidden'
            $title = $script:txt['pin_hidden']
            Hide-Overlay
        } else {
            $state = 'error'
            $title = 'OCR error: ' + $msg
        }
    }

    $sw.Stop()
    if ($state -eq 'ok' -or $state -eq 'no_coord') {
        Show-Overlay $wx $wy $ww $title $sub $bg $dirKey
    }
    Write-Result $state $coordText $inRange $dirKey $dist $sw.ElapsedMilliseconds $title $sub $modeText $capText

    if ($ShotFile.Length -gt 0 -and ($simulated -or $OcrFile.Length -gt 0)) {
        if ($null -ne $script:form) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } }
        Start-Sleep -Milliseconds 150
        Save-OverlayShot $ShotFile
    }

    if ($null -ne $script:form) {
        try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    }

    if ($Once) { break }
    if ($StopFile.Length -gt 0 -and (Test-Path -LiteralPath $StopFile)) { break }
    Start-Sleep -Milliseconds $Interval
} while ($true)

if ($null -ne $script:form) {
    try { $script:form.Close() } catch { }
    try { $script:form.Dispose() } catch { }
}
