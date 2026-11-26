param(
    [string]$ProcName = '',
    [string]$TikuFile = '',
    [string]$OutFile = "$env:TEMP\gadget_ocr_result.txt",
    [string]$ShotFile = '',
    [int]$RelX = -1,
    [int]$RelY = -1,
    [int]$RelW = 0,
    [int]$RelH = 0,
    [double]$Scale = 2.0,
    [int]$TopN = 3,
    [int]$Watch = 0,
    [string]$StopFile = '',
    [string]$PidFile = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$cs = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class GadgetWin
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool at);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static string Title(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, 1024);
        return sb.ToString();
    }

    // Browser windows often carry the game name in their title (searching guides), so they must never be picked
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
        // Titles containing ONLINE (e.g. "MengHuan XiYou ONLINE - (...)") identify the game client window
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

    // Foreground helpers: the realtime loop only captures while the game owns the foreground,
    // so it can tell "same process" apart from "another window of the game client" (e.g. IME popup)
    public static bool SameProcess(IntPtr a, IntPtr b)
    {
        if (a == IntPtr.Zero || b == IntPtr.Zero) return false;
        if (a == b) return true;
        uint pa, pb;
        GetWindowThreadProcessId(a, out pa);
        GetWindowThreadProcessId(b, out pb);
        return pa == pb;
    }

    public static void ForceForeground(IntPtr h)
    {
        if (h == IntPtr.Zero) return;
        // Restored windows need a moment before the screen contents are stable enough to grab
        if (IsIconic(h)) { ShowWindow(h, 9); System.Threading.Thread.Sleep(180); }
        IntPtr fg = GetForegroundWindow();
        uint p1, p2;
        uint t1 = GetWindowThreadProcessId(fg, out p1);
        uint t2 = GetWindowThreadProcessId(h, out p2);
        if (t1 != t2) AttachThreadInput(t1, t2, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (t1 != t2) AttachThreadInput(t1, t2, false);
    }
}

public class GadgetMatch
{
    static bool Keep(char c)
    {
        return char.IsLetterOrDigit(c) || c == '%' || c == '+' || c == '-';
    }

    public static string Norm(string s)
    {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (Keep(c)) sb.Append(char.ToLowerInvariant(c));
        }
        return sb.ToString();
    }

    static HashSet<string> Grams(string s)
    {
        HashSet<string> set = new HashSet<string>();
        if (s.Length == 0) return set;
        if (s.Length <= 2) { set.Add(s); return set; }
        for (int i = 0; i + 1 < s.Length; i++) set.Add(s.Substring(i, 2));
        return set;
    }

    static double Dice(HashSet<string> a, HashSet<string> b)
    {
        if (a.Count == 0 || b.Count == 0) return 0.0;
        int inter = 0;
        foreach (string g in a) { if (b.Contains(g)) inter++; }
        return 2.0 * inter / (a.Count + b.Count);
    }

    static int AnswerLine(string[] normLines, string answer)
    {
        string na = Norm(answer);
        if (na.Length == 0) return -1;
        if (na.Length == 1)
        {
            char t = na[0];
            for (int i = 0; i < normLines.Length; i++)
            {
                string l = normLines[i];
                if (l.Length > 0 && l[0] == t) return i;
            }
            return -1;
        }
        for (int i = 0; i < normLines.Length; i++)
        {
            if (normLines[i].IndexOf(na, StringComparison.Ordinal) >= 0) return i;
        }
        return -1;
    }

    public static int CountTiku(string tikuText)
    {
        int c = 0;
        string[] raw = tikuText.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string r0 in raw)
        {
            string r = r0.Replace((char)0xFF5C, '|').Trim();
            if (r.Length == 0 || r[0] == '#') continue;
            int p = r.IndexOf('|');
            if (p < 0) p = r.IndexOf('\t');
            if (p <= 0) continue;
            if (Norm(r.Substring(0, p)).Length < 2) continue;
            c++;
        }
        return c;
    }

    public static string[] Run(string[] lines, string tikuText, int topN)
    {
        List<string> questions = new List<string>();
        List<string> answers = new List<string>();
        List<HashSet<string>> qgrams = new List<HashSet<string>>();

        string[] raw = tikuText.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string r0 in raw)
        {
            string r = r0.Replace((char)0xFF5C, '|').Trim();
            if (r.Length == 0 || r[0] == '#') continue;
            int p = r.IndexOf('|');
            if (p < 0) p = r.IndexOf('\t');
            if (p <= 0) continue;
            string q = r.Substring(0, p).Trim();
            string a = r.Substring(p + 1).Trim();
            string nq = Norm(q);
            if (nq.Length < 2) continue;
            questions.Add(q);
            answers.Add(a);
            qgrams.Add(Grams(nq));
        }

        int n = lines.Length;
        string[] normLines = new string[n];
        for (int i = 0; i < n; i++) normLines[i] = Norm(lines[i]);

        HashSet<string>[] single = new HashSet<string>[n];
        HashSet<string>[] pair = new HashSet<string>[n];
        for (int i = 0; i < n; i++)
        {
            single[i] = Grams(normLines[i]);
            if (i + 1 < n) pair[i] = Grams(normLines[i] + normLines[i + 1]);
            else pair[i] = single[i];
        }

        double[] scores = new double[questions.Count];
        int total = questions.Count;
        for (int k = 0; k < total; k++)
        {
            double best = 0;
            int qc = qgrams[k].Count;
            for (int i = 0; i < n; i++)
            {
                int sc = single[i].Count;
                if (sc > 0 && sc * 3 >= qc)
                {
                    double d1 = Dice(qgrams[k], single[i]);
                    if (d1 > best) best = d1;
                }
                double d2 = Dice(qgrams[k], pair[i]);
                if (d2 > best) best = d2;
                if (best >= 0.999) break;
            }
            scores[k] = best;
        }

        int[] order = new int[total];
        for (int i = 0; i < total; i++) order[i] = i;
        Array.Sort<int>(order, delegate(int x, int y) { return scores[y].CompareTo(scores[x]); });

        List<string> hits = new List<string>();
        for (int i = 0; i < order.Length && hits.Count < topN; i++)
        {
            int k = order[i];
            if (scores[k] < 0.40) break;
            int al = AnswerLine(normLines, answers[k]);
            hits.Add(scores[k].ToString("0.000") + "\t" + al + "\t" + questions[k] + "\t" + answers[k]);
        }
        return hits.ToArray();
    }
}
'@

# Cache compiled assembly: first run compiles to LocalAppData, later runs load it directly (saves ~1.6s)
$cacheDir = Join-Path $env:LOCALAPPDATA 'GadgetOcr'
if (-not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
$srcHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm MD5).Hash
$dllPath = Join-Path $cacheDir ('gadget_ocr_' + $srcHash + '.dll')
$loaded = $false
if (Test-Path -LiteralPath $dllPath) {
    try { Add-Type -Path $dllPath; $loaded = $true } catch { $loaded = $false }
}
if (-not $loaded) {
    try {
        Add-Type -TypeDefinition $cs -OutputAssembly $dllPath -OutputType Library -ErrorAction Stop
        Add-Type -Path $dllPath
    } catch {
        Add-Type -TypeDefinition $cs
    }
}

$brand = -join ([char]0x68A6, [char]0x5E7B, [char]0x897F, [char]0x6E38)
$exclude = -join ([char]0x804A, [char]0x5929, [char]0x7A97, [char]0x53E3)
$meta = New-Object System.Collections.Generic.List[string]
$linesOut = New-Object System.Collections.Generic.List[string]
$hitOut = New-Object System.Collections.Generic.List[string]
$status = "ok"

# ---- realtime state (a one-shot run executes the loop body exactly once) ----
$engine = $null
$asTaskGeneric = $null
$tikuText = ""
$tikuCount = 0
$tikuLoaded = $false
$lastSig = ""
$lastLines = @()
$lastHits = @()
$lastThumb = $null
$runNo = 0
$swAll = $null
$swOcr = $null
$thumbSize = 24

function Write-Result {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $meta) { [void]$sb.AppendLine("META`t" + $m) }
    foreach ($l in $linesOut) { [void]$sb.AppendLine("LINE`t" + $l) }
    foreach ($h in $hitOut) { [void]$sb.AppendLine("HIT`t" + $h) }
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($OutFile, $sb.ToString() + "EOF`t" + [DateTime]::Now.Ticks, $enc)
}

# 24x24 grayscale thumbnail: cheap frame signature for realtime mode (raw pixels are too noisy)
function Get-Thumb {
    param($bmp)
    $n = $thumbSize
    $small = New-Object System.Drawing.Bitmap $n, $n, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g3 = [System.Drawing.Graphics]::FromImage($small)
    $g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Low
    $g3.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g3.DrawImage($bmp, 0, 0, $n, $n)
    $g3.Dispose()
    # One LockBits + Marshal.Copy instead of 576 GetPixel calls: every extra tick pays this cost
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

# Compare against the frame we last OCR'd (not the previous frame), so slow drift still triggers
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

function Await($op, $type) {
    if ($null -eq $script:asTaskGeneric) { throw "OCR_NO_LANGUAGE_PACK" }
    $asTask = $script:asTaskGeneric.MakeGenericMethod($type)
    $netTask = $asTask.Invoke($null, @($op))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

# Resolve the WinRT plumbing and the OCR engine once, then reuse it on every realtime tick
function Get-OcrEngine {
    if ($null -ne $script:engine) { return $script:engine }
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    $e = $null
    try { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'zh-Hans-CN')) } catch { }
    if ($null -eq $e) { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if ($null -eq $e) { throw "OCR_NO_LANGUAGE_PACK" }
    $script:engine = $e
    return $e
}

$brandKey = $brand
if ($ProcName.Length -gt 0) { $brandKey = '' }
[void][GadgetWin]::SetProcessDPIAware()

# The bank only changes when the user edits it, so parse it once per process
if ($TikuFile.Length -gt 0 -and (Test-Path -LiteralPath $TikuFile)) {
    $tikuText = [System.IO.File]::ReadAllText($TikuFile, [System.Text.Encoding]::UTF8)
    $tikuCount = [GadgetMatch]::CountTiku($tikuText)
}
$tikuLoaded = $true

# A cropped answer box is static text, so a small change there is meaningful;
# the auto middle band still shows animated scenery behind the dialog, so it keeps the looser gate
$picked = ($RelW -gt 0 -and $RelH -gt 0 -and $RelX -ge 0 -and $RelY -ge 0)
$diffMin = 0.02
if ($picked) { $diffMin = 0.012 }

# No user-picked area: read only the middle band where the question dialog lives instead of the
# whole window. Measured on an 800x565 client the dialog spans 132..672 x 337..505, i.e. 16%~84%
# wide and 60%~89% high; the band below is centered and slightly more generous so other
# resolutions / UI scales still fit, while the top HUD, task panel and bottom bar stay out.
$autoL = 0.10; $autoW = 0.80; $autoT = 0.46; $autoH = 0.48

if ($Watch -gt 0 -and $PidFile.Length -gt 0) {
    try { [System.IO.File]::WriteAllText($PidFile, [string]$PID, (New-Object System.Text.UTF8Encoding $false)) } catch { }
}

do {
    $runNo++
    [void]$meta.Clear()
    [void]$linesOut.Clear()
    [void]$hitOut.Clear()
    $status = "ok"
    $changed = 0
    $skipped = 0
    $title = ""
    $wx = 0; $wy = 0; $ww = 0; $wh = 0
    $cx = 0; $cy = 0; $cw = 0; $ch = 0
    $imgW = 0; $imgH = 0
    $area = ""
    $prevFg = [IntPtr]::Zero
    $hitQ = ""
    $hitA = ""
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()
    $swOcr = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $hwnd = [GadgetWin]::FindGame($ProcName, $brandKey, $exclude)
        if ($hwnd -eq [IntPtr]::Zero) {
            # realtime mode keeps polling so it recovers by itself once the game is back
            if ($Watch -gt 0) { throw "__NO_WINDOW__" }
            throw "GAME_WINDOW_NOT_FOUND"
        }
        $title = [GadgetWin]::Title($hwnd)

        if ($Watch -gt 0) {
            # realtime never steals focus: only capture while the game client owns the foreground
            if ([GadgetWin]::IsIconic($hwnd)) { throw "__MINIMIZED__" }
            if (-not [GadgetWin]::SameProcess([GadgetWin]::GetForegroundWindow(), $hwnd)) { throw "__NOT_FOREGROUND__" }
        } else {
            $prevFg = [GadgetWin]::GetForegroundWindow()
            # Bring the window forward (also restores minimized windows) before reading its rect,
            # otherwise a minimized window reports a tiny placeholder size
            [GadgetWin]::ForceForeground($hwnd)
            Start-Sleep -Milliseconds 360
        }

    $r = New-Object GadgetWin+RECT
    [void][GadgetWin]::GetWindowRect($hwnd, [ref]$r)
    $wx = $r.Left; $wy = $r.Top
    $ww = $r.Right - $r.Left; $wh = $r.Bottom - $r.Top

    if ($picked) {
        $cx = $wx + $RelX; $cy = $wy + $RelY; $cw = $RelW; $ch = $RelH
        $area = "region"
    } else {
        # middle band, relative to the window rect so it follows the window around
        $cx = $wx + [int][Math]::Round($ww * $autoL)
        $cy = $wy + [int][Math]::Round($wh * $autoT)
        $cw = [int][Math]::Round($ww * $autoW)
        $ch = [int][Math]::Round($wh * $autoH)
        $area = "middle"
    }

    $vx = [GadgetWin]::GetSystemMetrics(76); $vy = [GadgetWin]::GetSystemMetrics(77)
    $vw = [GadgetWin]::GetSystemMetrics(78); $vh = [GadgetWin]::GetSystemMetrics(79)
    if ($cx -lt $vx) { $cw = $cw - ($vx - $cx); $cx = $vx }
    if ($cy -lt $vy) { $ch = $ch - ($vy - $cy); $cy = $vy }
    if ($cx + $cw -gt $vx + $vw) { $cw = $vx + $vw - $cx }
    if ($cy + $ch -gt $vy + $vh) { $ch = $vy + $vh - $cy }
    if ($cw -lt 24 -or $ch -lt 24) { throw "REGION_INVALID" }

    $bmp = New-Object System.Drawing.Bitmap $cw, $ch
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($cx, $cy, 0, 0, (New-Object System.Drawing.Size $cw, $ch))
    $g.Dispose()

    if ($prevFg -ne [IntPtr]::Zero -and $prevFg -ne $hwnd) { [GadgetWin]::ForceForeground($prevFg) }

    # Realtime pre-check: when the crop matches the frame we last OCR'd, replay that result instead
    # of paying for another OCR pass (the client repaints constantly, but the text does not change)
    $thumb = Get-Thumb $bmp
    $needOcr = $true
    if ($Watch -gt 0) { $needOcr = Test-ThumbChanged $thumb $lastThumb $diffMin }

    if (-not $needOcr) {
        $skipped = 1
        $imgW = $bmp.Width; $imgH = $bmp.Height
        $bmp.Dispose()
        foreach ($l in $lastLines) { $linesOut.Add($l) }
        foreach ($h in $lastHits) { $hitOut.Add($h) }
    } else {

    if ($Scale -gt 1.0) {
        $bw = [int]($cw * $Scale); $bh = [int]($ch * $Scale)
        if ($bw -le 8000 -and $bh -le 8000) {
            $big = New-Object System.Drawing.Bitmap $bw, $bh
            $g2 = [System.Drawing.Graphics]::FromImage($big)
            $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g2.DrawImage($bmp, 0, 0, $bw, $bh)
            $g2.Dispose()
            $bmp.Dispose()
            $bmp = $big
        }
    }
    $imgW = $bmp.Width; $imgH = $bmp.Height
    # Debug aid only: saving the frame is slow (a 3230x2558 BMP takes seconds), so it happens
    # only when a caller explicitly passes -ShotFile
    if ($Watch -le 0 -and $ShotFile.Length -gt 0) {
        try { $bmp.Save($ShotFile, [System.Drawing.Imaging.ImageFormat]::Bmp) } catch { }
    }

    # Hand the pixels to WinRT without encoding them: packing the same frame as PNG cost ~3.4s
    # and even as uncompressed BMP ~3.9s, while a raw BGRA copy is a few tens of milliseconds
    $bw = $bmp.Width; $bh = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bw, $bh
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($data.Stride * $bh)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    $stride = $data.Stride
    $bmp.UnlockBits($data)
    $bmp.Dispose()
    if ($stride -ne ($bw * 4)) {
        # GDI+ normally hands back tightly packed rows; repack just in case it pads them
        $packed = New-Object byte[] ($bw * 4 * $bh)
        for ($y = 0; $y -lt $bh; $y++) { [Array]::Copy($raw, $y * $stride, $packed, $y * $bw * 4, $bw * 4) }
        $raw = $packed
    }

    $engine = Get-OcrEngine
    $buf = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($raw)
    $sbmp = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer($buf, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, $bw, $bh)

    $swOcr.Restart()
    $res = Await ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])
    $swOcr.Stop()
    $sbmp.Dispose()

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $res.Lines) {
        $t = $ln.Text
        if ($null -ne $t) { $t = $t.Trim() }
        if ($t -ne $null -and $t.Length -gt 0) { $texts.Add($t) }
    }
    $idx = 0
    foreach ($t in $texts) {
        $linesOut.Add(($idx.ToString() + "`t" + $t))
        $idx++
    }

    if ($tikuCount -gt 0 -and $texts.Count -gt 0) {
        $arr = $texts.ToArray()
        $hits = [GadgetMatch]::Run($arr, $tikuText, $TopN)
        $rank = 1
        foreach ($h in $hits) {
            $hitOut.Add(($rank.ToString() + "`t" + $h))
            if ($rank -eq 1) {
                $hPart = $h.Split("`t")
                if ($hPart.Length -ge 4) { $hitQ = $hPart[2]; $hitA = $hPart[3] }
            }
            $rank++
        }
        $lastHits = $hitOut.ToArray()
    }

    # Signature of what the answer panel would show; only a real change repaints the realtime UI
    $sig = "N|"
    if ($hitA.Length -gt 0) {
        $sig = "H|" + $hitQ + "|" + $hitA
    } else {
        foreach ($t in $texts) {
            $compact = $t.Replace(" ", "")
            if ($compact.Length -gt ($sig.Length - 2)) { $sig = "N|" + $compact }
        }
    }
    if ($sig -ne $lastSig) { $changed = 1; $lastSig = $sig }
    $lastLines = $linesOut.ToArray()
    $lastThumb = $thumb

    }   # end of the OCR branch

    } catch {
        $msg = $_.Exception.Message
        if ($msg -eq "__NO_WINDOW__") {
            $status = "no_window"
        } elseif ($msg -eq "__MINIMIZED__") {
            $status = "minimized"
        } elseif ($msg -eq "__NOT_FOREGROUND__") {
            $status = "not_foreground"
        } else {
            $status = "error"
            $meta.Add("error`t" + $msg)
        }
        # Keep the last panel content so the realtime UI does not blank out while waiting
        if ($Watch -gt 0) {
            $changed = 0
            foreach ($l in $lastLines) { $linesOut.Add($l) }
            foreach ($h in $lastHits) { $hitOut.Add($h) }
        }
    }

    $swAll.Stop()
    $meta.Insert(0, "status`t" + $status)
    $meta.Insert(1, "title`t" + $title)
    $meta.Add("window`t" + $wx + "," + $wy + "," + $ww + "," + $wh)
    $meta.Add("crop`t" + $cx + "," + $cy + "," + $cw + "," + $ch)
    $meta.Add("area`t" + $area)
    $meta.Add("image`t" + $imgW + "x" + $imgH)
    $meta.Add("shot`t" + $ShotFile)
    $meta.Add("tiku`t" + $tikuCount)
    $meta.Add("lines`t" + $linesOut.Count)
    $meta.Add("ms`t" + $swAll.ElapsedMilliseconds)
    $meta.Add("ms_ocr`t" + $swOcr.ElapsedMilliseconds)
    $meta.Add("run`t" + $runNo)
    $meta.Add("changed`t" + $changed)
    $meta.Add("skipped`t" + $skipped)

    Write-Result

    if ($Watch -le 0) { break }
    if ($StopFile.Length -gt 0 -and (Test-Path -LiteralPath $StopFile)) { break }
    Start-Sleep -Milliseconds $Watch
} while ($true)
