param([string]$Out = "$env:TEMP\quest_shot.png")
# Capture the GAME CLIENT AREA only (no title bar / border / desktop), saved as PNG.
# The ghost reader treats every input image as a full client screenshot, so a partial
# crop (for example only the quest tracker corner) would be cropped a second time and misread.
# Bring the game to the foreground first: CopyFromScreen reads real screen pixels, so any
# window covering the quest tracker ends up in the picture.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class CapQuest {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static IntPtr Game() {
    // Brand + exclusion are built from code points: a BOM-less .ps1 is parsed as ANSI,
    // so a literal Chinese brand would arrive here as mojibake and never match.
    string brand = new string(new char[] { (char)0x68A6, (char)0x5E7B, (char)0x897F, (char)0x6E38 });
    string skip  = new string(new char[] { (char)0x804A, (char)0x5929, (char)0x7A97, (char)0x53E3 });
    IntPtr best = IntPtr.Zero;
    long bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      StringBuilder sb = new StringBuilder(512);
      GetWindowTextW(h, sb, 512);
      string t = sb.ToString();
      if (t.Length == 0) return true;
      if (t.IndexOf(brand, StringComparison.Ordinal) < 0) return true;
      if (t.IndexOf(skip, StringComparison.Ordinal) >= 0) return true;
      RECT r;
      if (!GetClientRect(h, out r)) return true;
      long w = r.Right - r.Left;
      long hh = r.Bottom - r.Top;
      if (w < 320 || hh < 240) return true;
      long area = w * hh;
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
'@
[void][CapQuest]::SetProcessDPIAware()
$h = [CapQuest]::Game()
if ($h -eq [IntPtr]::Zero) { Write-Output 'NO_GAME_WINDOW'; exit 1 }
$r = New-Object CapQuest+RECT
[void][CapQuest]::GetClientRect($h, [ref]$r)
$p = New-Object CapQuest+POINT
$p.X = 0; $p.Y = 0
[void][CapQuest]::ClientToScreen($h, [ref]$p)
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
if ($w -lt 320 -or $ht -lt 240) { Write-Output ('CLIENT_TOO_SMALL ' + $w + 'x' + $ht); exit 1 }
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($p.X, $p.Y, 0, 0, (New-Object System.Drawing.Size $w, $ht))
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ('SHOT ' + $Out + ' ' + $w + 'x' + $ht)
