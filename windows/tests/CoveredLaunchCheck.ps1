# A Kite that opens where no one can see it never draws its page (shell/Occlusion.h, P2): the
# first page, made after Kite's occlusion already said "covered", ends up hidden and its
# requestAnimationFrame stops, and stays that way while Kite stays covered.
#
#   pwsh windows/tests/CoveredLaunchCheck.ps1 -Kite windows\build\Release\Kite.exe [-Cover] [-Seconds 20]
#        [-Attack none|stopPropagation|spoofState|docOpen|docOpenStop|endlessOpen|iframeStorm|
#                 pushStorm|hangNav|lateOpen|repeatOpen|reloadStorm]
#
# Kite runs as a quiet --perf-log run on a fresh %TEMP% test profile, so it opens at the bottom of
# the z-order and never activates; its occlusion is on from the start (no --perf-control). -Cover
# first shows an opaque, never-activating window over every monitor (CI, whose desktop is empty);
# without it the desktop's own windows must cover Kite (a PC in use). The page writes its
# visibility and rAF count into its title, which Kite saves in the session on closing. Exit 0 when
# Kite's verdict was hidden and the page ended hidden with rAF stopped; 1 otherwise, with why.
# -Attack makes the page try to keep itself drawing: stopPropagation stops every visibilitychange
# in a capture listener on window, spoofState makes document.visibilityState always read
# "hidden". docOpen loads a stub that, once loaded, rewrites itself with document.open/write/close,
# which drops every listener on the document and the window (an old document.write page does the
# same); docOpenStop also adds stopPropagation's listener to the new document. endlessOpen keeps
# an image loading for ever (from a listener in this script on 127.0.0.1 that never finishes a
# response), so the page never ends loading, and rewrites itself with document.open at once.
# iframeStorm points an iframe somewhere new every 150 ms. pushStorm calls history.pushState
# every 150 ms. hangNav starts a navigation every second to that listener, which never answers
# it. lateOpen rewrites the page with document.open 8 s after its load, repeatOpen every 2 s.
# reloadStorm rewrites itself with document.open and then reloads itself 0.4 s later, over and
# over (its log and rAF count kept in sessionStorage). The page's own log reads
# Document.prototype's getter, so it sees through the spoof; it keeps its state on window, so a
# rewrite carries on with it and one rAF loop.
# The run is 20 s so its last 6 s come after Kite's last re-hide (6 s after the page's last load,
# which a cold Kite can take 4 s to start); each re-hide shows the page for a few ms, a frame or
# two. Never run -Cover on a PC in use: it
# blacks out every monitor for the run.
param(
  [Parameter(Mandatory)] [string] $Kite,
  [switch] $Cover,
  [int] $Seconds = 20,
  [ValidateSet('none', 'stopPropagation', 'spoofState', 'docOpen', 'docOpenStop', 'endlessOpen', 'iframeStorm', 'pushStorm', 'hangNav',
               'lateOpen', 'repeatOpen', 'reloadStorm')] [string] $Attack = 'none'
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
  // A response that never ends, on 127.0.0.1 (a free port, returned): a header, a few bytes of a
  // much longer body, and nothing more, the connection held until this process ends. In this
  // process, on a background thread, so nothing else needs starting or stopping.
  public static int ServeEndless() {
    var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
    listener.Start();
    var held = new System.Collections.Generic.List<System.Net.Sockets.TcpClient>();
    var thread = new System.Threading.Thread(() => {
      for (;;) {
        var client = listener.AcceptTcpClient();
        held.Add(client);
        var stream = client.GetStream();
        var buffer = new byte[4096];
        int read = 0;
        try { read = stream.Read(buffer, 0, buffer.Length); } catch { continue; }
        if (Encoding.ASCII.GetString(buffer, 0, read).StartsWith("GET /hang")) continue;  // never answered
        byte[] head = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 1000000\r\nCache-Control: no-store\r\n\r\n");
        try { stream.Write(head, 0, head.Length); stream.Write(new byte[16], 0, 16); stream.Flush(); } catch { }
      }
    });
    thread.IsBackground = true;
    thread.Start();
    return ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
  }
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
  $stop = "<script>window.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);</script>"
  $attacks = @{
    none = ''
    stopPropagation = $stop
    spoofState = "<script>Object.defineProperty(document, 'visibilityState', { get: () => 'hidden' }); Object.defineProperty(document, 'hidden', { get: () => true });</script>"
    docOpen = ''
    docOpenStop = $stop
  }
  # "vis:" then words: V or H (visibilityState changed) or F<ms>:<frames>, each with Date.now().
  # The state is read with Document.prototype's own getter, on each change and every second.
  $html = '<!doctype html><meta charset="utf-8"><title>vis:</title>' + $attacks[$Attack] + @'
<canvas id="c" width="200" height="100"></canvas>
<script>
(() => {
  // State on window, so a document.open rewrite carries on with it; with window.kcPersist (set by
  // reloadStorm), also through reloads, in sessionStorage.
  const saved = window.kcPersist && sessionStorage.getItem('kc');
  const st = window.kc || (window.kc = saved ? JSON.parse(saved) : { log: '', frames: 0, last: '' });
  const save = () => {
    // Under Chromium's 4,096-character title limit, whole words only.
    if (st.log.length > 3000) st.log = st.log.slice(st.log.indexOf(' ', st.log.length - 3000) + 1);
    if (window.kcPersist) sessionStorage.setItem('kc', JSON.stringify(st));
  };
  const realState = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState').get;
  const sample = () => { st.log += 'F' + Date.now() + ':' + st.frames + ' '; save(); document.title = 'vis:' + st.log; };
  function vis() {
    const s = realState.call(document) === 'visible' ? 'V' : 'H';
    if (s !== st.last) { st.last = s; st.log += s + Date.now() + ' '; save(); document.title = 'vis:' + st.log; }
  }
  // One rAF loop: a rewrite starts a new one and the old one stops.
  const loop = st.loop = (st.loop || 0) + 1;
  function draw(t) {
    if (st.loop !== loop) return;
    st.frames++;
    const c = document.getElementById('c');
    if (c) { const g = c.getContext('2d'); g.fillStyle = `hsl(${(t / 10) % 360} 80% 50%)`; g.fillRect(0, 0, 200, 100); }
    requestAnimationFrame(draw);
  }
  requestAnimationFrame(draw);
  document.title = 'vis:' + st.log;  // a rewrite's <title> would hide the log until the next sample
  document.addEventListener('visibilitychange', vis); vis();
  if (window.kcPersist) { sample(); addEventListener('pagehide', sample); }
  if (!window.kcTimer) window.kcTimer = setInterval(() => { vis(); sample(); }, 1000);
})();
</script>
'@
  $decode = { param($text) "new TextDecoder().decode(Uint8Array.from(atob('$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))'), c => c.charCodeAt(0)))" }
  if ($Attack -like 'docOpen*') {
    # The stub, rewritten with the page once it has loaded.
    $html = '<!doctype html><meta charset="utf-8"><title>vis:</title><script>addEventListener("load", () => setTimeout(() => {' +
            "document.open(); document.write($(& $decode $html)); document.close();" + '}, 0));</script>'
  } elseif ($Attack -eq 'endlessOpen') {
    # Never done loading: an image that never finishes, before and after the rewrite.
    $image = "<img src=`"http://127.0.0.1:$([KiteCheck]::ServeEndless())/never.png`" width=1 height=1>"
    $html = '<!doctype html><meta charset="utf-8"><title>vis:</title>' + $image +
            "<script>setTimeout(() => { document.open(); document.write($(& $decode ($html + $image))); }, 0);</script>"
  } elseif ($Attack -eq 'iframeStorm') {
    $html += "<iframe id=`"f`" width=10 height=10></iframe><script>let n = 0; setInterval(() => { document.getElementById('f').src = 'data:text/html,' + (++n); }, 150);</script>"
  } elseif ($Attack -eq 'pushStorm') {
    $html += "<script>let n = 0; setInterval(() => history.pushState(null, '', '#' + (++n)), 150);</script>"
  } elseif ($Attack -eq 'hangNav') {
    $html += "<script>setInterval(() => { location.href = 'http://127.0.0.1:$([KiteCheck]::ServeEndless())/hang?' + Date.now(); }, 1000);</script>"
  } elseif ($Attack -eq 'lateOpen') {
    $html += "<script>addEventListener('load', () => setTimeout(() => { document.open(); document.write($(& $decode $html)); document.close(); }, 8000));</script>"
  } elseif ($Attack -eq 'repeatOpen') {
    $html += "<script>if (!window.kcRepeat) window.kcRepeat = setInterval(() => { document.open(); document.write($(& $decode $html)); document.close(); }, 2000);</script>"
  } elseif ($Attack -eq 'reloadStorm') {
    $inner = $html + "<script>setTimeout(() => location.reload(), 400);</script>"
    $html = '<!doctype html><meta charset="utf-8"><title>vis:</title><script>window.kcPersist = true; addEventListener("load", () => setTimeout(() => {' +
            "document.open(); document.write($(& $decode $inner)); document.close();" + '}, 0));</script>'
  }
  [IO.File]::WriteAllText($page, $html)
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
  # rAF over the last 6 s before the close: none. (A hidden page's timers can run only every 2 s.)
  $samples = @($before | Where-Object { $_[0] -eq 'F' } | ForEach-Object { $p = $_.Substring(1) -split ':'; [pscustomobject]@{ t = [double]$p[0]; n = [int]$p[1] } })
  $recent = @($samples | Where-Object { $_.t -ge $closedAt - 6000 })
  if ($recent.Count -lt 2) { throw "too few rAF samples in the last 6 s ($($recent.Count))" }
  $ran = $recent[-1].n - $recent[0].n
  if ($ran -ne 0) { throw "requestAnimationFrame ran $ran frames in the last $([int](($recent[-1].t - $recent[0].t) / 1000)) s while Kite was covered" }
  Write-Host "covered launch ($Attack): the page ended hidden, rAF stopped at $($recent[-1].n) frames"
} finally {
  if ($process -and -not $process.HasExited) { $process.Kill() }
  if ($coverWindow) { [KiteCheck]::DestroyWindow($coverWindow) | Out-Null }
  $env:KITE_SUPPORT_PATH = $previousSupportPath
  Remove-Item -Recurse -Force -LiteralPath $profileDir -ErrorAction SilentlyContinue
}
