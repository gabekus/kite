# A Kite that opens where no one can see it never draws its page (shell/Occlusion.h, P2): the
# first page, made after Kite's occlusion already said "covered", ends up hidden and its
# requestAnimationFrame stops, and stays that way while Kite stays covered.
#
#   pwsh windows/tests/CoveredLaunchCheck.ps1 -Kite windows\build\Release\Kite.exe [-Cover] [-Seconds 8]
#        [-Attack none|stopPropagation|spoofState]
#
# Kite runs as a quiet --perf-log run on a fresh %TEMP% test profile, so it opens at the bottom of
# the z-order and never activates; its occlusion is on from the start (no --perf-control). -Cover
# first shows an opaque, never-activating window over every monitor (CI, whose desktop is empty);
# without it the desktop's own windows must cover Kite (a PC in use). The page writes its
# visibility and rAF count into its title, which Kite saves in the session on closing. Exit 0 when
# Kite's verdict was hidden and the page ended hidden with rAF stopped; 1 otherwise, with why.
# -Attack makes the page try to keep itself drawing: stopPropagation stops every visibilitychange
# in a capture listener on window, spoofState makes document.visibilityState always read
# "hidden". The page's own log reads Document.prototype's getter, so it sees through the spoof.
# Never run -Cover on a PC in use: it blacks out every monitor for the run.
param(
  [Parameter(Mandatory)] [string] $Kite,
  [switch] $Cover,
  [int] $Seconds = 8,
  [ValidateSet('none', 'stopPropagation', 'spoofState')] [string] $Attack = 'none'
)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class KiteCheck {
  delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct WNDCLASS { public uint style; public WndProc proc; public int cls, wnd; public IntPtr instance, icon, cursor, background;
                    public string menu, name; }
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint time; public int x, y; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS c);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style,
      int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
  [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] static extern bool PeekMessageW(out MSG m, IntPtr h, uint min, uint max, uint remove);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
  [DllImport("gdi32.dll")] static extern IntPtr GetStockObject(int i);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  static WndProc proc = (h, m, w, l) => m == 0x21 ? (IntPtr)3 : DefWindowProcW(h, m, w, l);  // WM_MOUSEACTIVATE: MA_NOACTIVATE
  // An opaque, captionless, unowned app window over every monitor that never activates: what
  // Kite's occlusion counts as covering it (a tool window or an owned popup wouldn't). Topmost,
  // so it stays over Kite even if Kite came forward (CI's desktop has no one to keep it back).
  public static IntPtr MakeCover() {
    // In physical pixels, as Kite (per-monitor aware) measures: a shell that isn't DPI aware
    // gets the screen scaled down, and a cover that size left part of Kite showing on CI.
    SetProcessDpiAwarenessContext((IntPtr)(-4));
    var c = new WNDCLASS { proc = proc, instance = GetModuleHandleW(IntPtr.Zero), background = GetStockObject(4), name = "KiteCoveredLaunchCheck" };
    RegisterClassW(ref c);
    IntPtr h = CreateWindowExW(0x08000008, "KiteCoveredLaunchCheck", "Kite covered-launch check", 0x80000000,
        GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79), IntPtr.Zero, IntPtr.Zero, c.instance, IntPtr.Zero);
    // Shown by SetWindowPos, not ShowWindow, whose first call takes the launcher's show state
    // instead (hidden, for a runner's shell). HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW.
    SetWindowPos(h, (IntPtr)(-1), GetSystemMetrics(76) - 64, GetSystemMetrics(77) - 64, GetSystemMetrics(78) + 128, GetSystemMetrics(79) + 128,
                 0x0010 | 0x0040);
    return h;
  }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  public static string Describe(IntPtr h) { RECT r; GetWindowRect(h, out r); return r.l + "," + r.t + "," + r.r + "," + r.b; }
  public static void Pump() { MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) DispatchMessageW(ref m); }
  public static IntPtr FindKite(int pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      int p; GetWindowThreadProcessId(h, out p);
      var c = new StringBuilder(64); GetClassName(h, c, 64);
      if (p == pid && c.ToString() == "KiteBrowserWindow") { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@

function Pump([int] $ms) {
  $end = [DateTime]::UtcNow.AddMilliseconds($ms)
  while ([DateTime]::UtcNow -lt $end) { [KiteCheck]::Pump(); Start-Sleep -Milliseconds 20 }
}

$profileDir = Join-Path ([IO.Path]::GetTempPath()) "kite-covered-launch-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $profileDir | Out-Null
$coverWindow = $null
$previousSupportPath = $env:KITE_SUPPORT_PATH
$process = $null
try {
  New-Item -ItemType File -Path (Join-Path $profileDir 'kite-test-profile') | Out-Null
  $page = Join-Path $profileDir 'page.html'
  $attacks = @{
    none = ''
    stopPropagation = "<script>window.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);</script>"
    spoofState = "<script>Object.defineProperty(document, 'visibilityState', { get: () => 'hidden' }); Object.defineProperty(document, 'hidden', { get: () => true });</script>"
  }
  # "vis:" then words: V or H (visibilityState changed) or F<ms>:<frames>, each with Date.now().
  # The state is read with Document.prototype's own getter, on each change and every second.
  [IO.File]::WriteAllText($page, '<!doctype html><meta charset="utf-8"><title>vis:</title>' + $attacks[$Attack] + @'
<canvas id="c" width="200" height="100"></canvas>
<script>
let log = '', frames = 0, last = '';
const realState = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState').get;
const g = document.getElementById('c').getContext('2d');
function vis() {
  const s = realState.call(document) === 'visible' ? 'V' : 'H';
  if (s !== last) { last = s; log += s + Date.now() + ' '; document.title = 'vis:' + log; }
}
function draw(t) { frames++; g.fillStyle = `hsl(${(t / 10) % 360} 80% 50%)`; g.fillRect(0, 0, 200, 100); requestAnimationFrame(draw); }
requestAnimationFrame(draw);
document.addEventListener('visibilitychange', vis); vis();
setInterval(() => { vis(); log += 'F' + Date.now() + ':' + frames + ' '; document.title = 'vis:' + log; }, 1000);
</script>
'@)
  $kitecore = Join-Path (Split-Path -Parent (Resolve-Path $Kite)) 'kitecore.exe'
  & $kitecore --profile $profileDir open ([uri]$page).AbsoluteUri | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "kitecore open exited with $LASTEXITCODE" }

  if ($Cover) {
    $coverWindow = [KiteCheck]::MakeCover()
    if ($coverWindow -eq [IntPtr]::Zero -or -not [KiteCheck]::IsWindowVisible($coverWindow)) { throw "couldn't show the cover window" }
    Write-Host "cover: $([KiteCheck]::Describe($coverWindow))"
    Pump 300
  }
  $env:KITE_SUPPORT_PATH = $profileDir
  $occlusionLog = Join-Path $profileDir 'occlusion.jsonl'
  $process = Start-Process -FilePath (Resolve-Path $Kite) -PassThru `
    -ArgumentList @('--perf-log', (Join-Path $profileDir 'perf.jsonl'), '--occlusion-log', $occlusionLog)
  $null = $process.Handle
  Pump ($Seconds * 1000)
  $closedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $window = [KiteCheck]::FindKite($process.Id)
  if ($window -eq [IntPtr]::Zero) { throw 'Kite never showed its window' }
  Write-Host "Kite's window: $([KiteCheck]::Describe($window))"
  [KiteCheck]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
  # Pumping the cover's messages meanwhile, so it never shows as not responding.
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Pump 100 }
  if (-not $process.HasExited) { throw "Kite didn't close within 30 s" }

  $verdicts = @(Get-Content $occlusionLog | Where-Object { $_ -match '"verdict":"(\w+)"' } | ForEach-Object { $Matches[1] })
  $session = Get-Content (Join-Path $profileDir 'session.json') -Raw
  if ($session -notmatch '"title":"vis:([^"]*)"') { throw 'the page logged nothing into its title' }
  $log = $Matches[1]
  Write-Host "Kite's verdicts: $($verdicts -join ', ')"
  Get-Content $occlusionLog -TotalCount 3 | ForEach-Object { Write-Host "  occlusion log: $_" }
  Write-Host "page: $log"
  if ($verdicts.Count -eq 0 -or $verdicts[0] -eq 'visible') {
    throw "Kite wasn't covered from the start (verdicts: $($verdicts -join ', ')): nothing to check; run with -Cover"
  }
  if ($verdicts -contains 'visible') { throw "Kite's verdict went to visible mid-run: $($verdicts -join ', ')" }
  $words = @($log -split ' ' | Where-Object { $_ })
  $before = @($words | Where-Object { [double]($_.Substring(1) -split ':')[0] -lt $closedAt })
  $lastVisibility = @($before | Where-Object { $_[0] -eq 'V' -or $_[0] -eq 'H' }) | Select-Object -Last 1
  if (-not $lastVisibility -or $lastVisibility[0] -ne 'H') {
    throw "the page was still visible when Kite closed (last change: $lastVisibility)"
  }
  # rAF over the last 3 s before the close: none.
  $samples = @($before | Where-Object { $_[0] -eq 'F' } | ForEach-Object { $p = $_.Substring(1) -split ':'; [pscustomobject]@{ t = [double]$p[0]; n = [int]$p[1] } })
  $recent = @($samples | Where-Object { $_.t -ge $closedAt - 3500 })
  if ($recent.Count -lt 2) { throw "too few rAF samples in the last 3 s ($($recent.Count))" }
  $ran = $recent[-1].n - $recent[0].n
  if ($ran -ne 0) { throw "requestAnimationFrame ran $ran frames in the last $([int](($recent[-1].t - $recent[0].t) / 1000)) s while Kite was covered" }
  Write-Host "covered launch ($Attack): the page ended hidden, rAF stopped at $($recent[-1].n) frames"
} finally {
  if ($process -and -not $process.HasExited) { $process.Kill() }
  if ($coverWindow) { [KiteCheck]::DestroyWindow($coverWindow) | Out-Null }
  $env:KITE_SUPPORT_PATH = $previousSupportPath
  Remove-Item -Recurse -Force -LiteralPath $profileDir -ErrorAction SilentlyContinue
}
