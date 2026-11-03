# Downloads the pinned CEF (Chromium Embedded Framework) build for Windows x64 into
# windows\ThirdParty\cef and builds its static C++ wrapper (libcef_dll_wrapper.lib).
# The Windows twin of scripts/fetch-cef.sh: same CEF version, so both shells run
# the same Chromium. The minimal distribution is a large download (a few hundred MB
# unpacked); run it only when you mean to.
#
#   pwsh windows/scripts/fetch-cef.ps1
#   pwsh windows/scripts/fetch-cef.ps1 -AllowUnpinned   # first run only, see $CefSha1
#
# Needs cmake, Ninja and the MSVC build tools (a "Developer PowerShell" or vcvars64).
param([switch] $AllowUnpinned)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Windows PowerShell 5.1's progress bar slows downloads to a crawl

$CefVersion = '156.0.7+g47dbc1d+chromium-156.0.8078.17'
$CefPlatform = 'windows64'
# The archive's SHA-1, like scripts/fetch-cef.sh pins the macOS one. Until it's set the
# script refuses to run; -AllowUnpinned checks against the CDN's own .sha1 instead (which
# guards only against corruption) and prints the value to pin here.
$CefSha1 = ''

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')  # windows/
$ThirdParty = Join-Path $Root 'ThirdParty'
$Dest = Join-Path $ThirdParty 'cef'
$Name = "cef_binary_${CefVersion}_${CefPlatform}_minimal"
$Archive = Join-Path $ThirdParty "$Name.tar.bz2"
$Stamp = Join-Path $Dest '.version'

if ((Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq $CefVersion)) {
    Write-Host "CEF $CefVersion already present"
} else {
    if (-not $CefSha1 -and -not $AllowUnpinned) {
        throw 'No pinned SHA-1 for the CEF archive: set $CefSha1, or run once with -AllowUnpinned to get it'
    }
    New-Item -ItemType Directory -Force -Path $ThirdParty | Out-Null
    $url = 'https://cef-builds.spotifycdn.com/' + [uri]::EscapeDataString("$Name.tar.bz2")
    if (-not (Test-Path $Archive)) {
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile "$Archive.part"
        Move-Item "$Archive.part" $Archive
    }
    $expected = $CefSha1
    if (-not $expected) {
        # .Content is a byte[] when the CDN doesn't send a text content type.
        $body = (Invoke-WebRequest -Uri "$url.sha1").Content
        if ($body -is [byte[]]) { $body = [System.Text.Encoding]::ASCII.GetString($body) }
        $expected = ($body.Trim() -split '\s+')[0]
    }
    $actual = (Get-FileHash -Algorithm SHA1 $Archive).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        Remove-Item $Archive  # or every later run would skip the download and fail again
        throw "SHA-1 mismatch for ${Name}: got $actual, expected $expected"
    }
    Write-Host "SHA-1 $actual"
    if (-not $CefSha1) { Write-Host "Pin it: set `$CefSha1 = '$actual' in windows/scripts/fetch-cef.ps1" }

    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    $unpacked = Join-Path $ThirdParty $Name
    if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
    # Windows 10+ ships bsdtar as System32\tar.exe, which reads .tar.bz2. Named in full: Git's
    # GNU tar, if it comes first on PATH, reads "C:\..." as a remote host.
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xjf $Archive -C $ThirdParty
    if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
    Move-Item $unpacked $Dest
    Set-Content -Path $Stamp -Value $CefVersion -NoNewline
    Remove-Item $Archive
}

# libcef_dll_wrapper: CEF's C++ API on top of its C ABI. Built for Release (/MT) and Debug
# (/MTd), so either configuration of Kite links against a wrapper with the same CRT
# (otherwise LNK2038). They land in build-release and build-debug; Kite picks by $<CONFIG>.
foreach ($config in 'Release', 'Debug') {
    $buildDir = Join-Path $Dest ("build-" + $config.ToLower())
    $wrapper = Join-Path $buildDir 'libcef_dll_wrapper\libcef_dll_wrapper.lib'
    if (Test-Path $wrapper) { continue }
    cmake -S $Dest -B $buildDir -G Ninja `
        -DCMAKE_BUILD_TYPE=$config `
        -DPROJECT_ARCH=x86_64 `
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    if ($LASTEXITCODE -ne 0) { throw "cmake configure ($config) failed" }
    cmake --build $buildDir --target libcef_dll_wrapper
    if ($LASTEXITCODE -ne 0) { throw "cmake build ($config) failed" }
}
Write-Host "CEF ready at $Dest"
