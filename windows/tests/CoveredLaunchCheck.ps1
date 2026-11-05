# A Kite that opens where no one can see it never draws its page (shell/Occlusion.h, P2): the
# first page, made after Kite's occlusion already said "covered", ends up hidden and its
# requestAnimationFrame stops, and stays that way while Kite stays covered.
#
#   pwsh windows/tests/CoveredLaunchCheck.ps1 -Kite windows\build\Release\Kite.exe [-Cover] [-Seconds 8]
#
# Kite runs as a quiet --perf-log run on a fresh %TEMP% test profile, so it opens at the bottom of
# the z-order and never activates; its occlusion is on from the start (no --perf-control). -Cover
# first shows an opaque, never-activating window over every monitor (CI, whose desktop is empty);
# without it the desktop's own windows must cover Kite (a PC in use). The page writes its
# visibility and rAF count into its title, which Kite saves in the session on closing. Exit 0 when
# Kite's verdict was hidden and the page ended hidden with rAF stopped; 1 otherwise, with why.
param(
  [Parameter(Mandatory)] [string] $Kite,
  [switch] $Cover,
  [int] $Seconds = 8
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
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
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
  // An opaque, captioned-less, unowned app window over every monitor that never activates: what
  // Kite's occlusion counts as covering it (a tool window or an owned popup wouldn't).
  public static IntPtr MakeCover() {
    var c = new WNDCLASS { proc = proc, instance = GetModuleHandleW(IntPtr.Zero), background = GetStockObject(4), name = "KiteCoveredLaunchCheck" };
    RegisterClassW(ref c);
    IntPtr h = CreateWindowExW(0x08000000, "KiteCoveredLaunchCheck", "Kite covered-launch check", 0x80000000,
        GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79), IntPtr.Zero, IntPtr.Zero, c.instance, IntPtr.Zero);
    ShowWindow(h, 4);  // SW_SHOWNOACTIVATE
    return h;
  }
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
$cover = $null
$previousSupportPath = $env:KITE_SUPPORT_PATH
$process = $null
try {
  New-Item -ItemType File -Path (Join-Path $profileDir 'kite-test-profile') | Out-Null
  $page = Join-Path $profileDir 'page.html'
  # "vis:" then words: V or H (visibilityState changed) or F<ms>:<frames>, each with Date.now().
  [IO.File]::WriteAllText($page, @'
<!doctype html><meta charset="utf-8"><title>vis:</title>
<canvas id="c" width="200" height="100"></canvas>
<script>
let log = '', frames = 0;
const g = document.getElementById('c').getContext('2d');
function vis() { log += (document.visibilityState === 'visible' ? 'V' : 'H') + Date.now() + ' '; document.title = 'vis:' + log; }
function draw(t) { frames++; g.fillStyle = `hsl(${(t / 10) % 360} 80% 50%)`; g.fillRect(0, 0, 200, 100); requestAnimationFrame(draw); }
requestAnimationFrame(draw);
document.addEventListener('visibilitychange', vis); vis();
setInterval(() => { log += 'F' + Date.now() + ':' + frames + ' '; document.title = 'vis:' + log; }, 1000);
</script>
'@)
  $kitecore = Join-Path (Split-Path -Parent (Resolve-Path $Kite)) 'kitecore.exe'
  & $kitecore --profile $profileDir open ([uri]$page).AbsoluteUri | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "kitecore open exited with $LASTEXITCODE" }

  if ($Cover) {
    $cover = [KiteCheck]::MakeCover()
    if ($cover -eq [IntPtr]::Zero) { throw "couldn't make the cover window" }
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
  [KiteCheck]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
  if (-not $process.WaitForExit(30000)) { throw "Kite didn't close within 30 s" }

  $verdicts = @(Get-Content $occlusionLog | Where-Object { $_ -match '"verdict":"(\w+)"' } | ForEach-Object { $Matches[1] })
  $session = Get-Content (Join-Path $profileDir 'session.json') -Raw
  if ($session -notmatch '"title":"vis:([^"]*)"') { throw 'the page logged nothing into its title' }
  $log = $Matches[1]
  Write-Host "Kite's verdicts: $($verdicts -join ', ')"
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
  Write-Host "covered launch: the page ended hidden, rAF stopped at $($recent[-1].n) frames"
} finally {
  if ($process -and -not $process.HasExited) { $process.Kill() }
  if ($cover) { [KiteCheck]::DestroyWindow($cover) | Out-Null }
  $env:KITE_SUPPORT_PATH = $previousSupportPath
  Remove-Item -Recurse -Force -LiteralPath $profileDir -ErrorAction SilentlyContinue
}
