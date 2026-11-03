# Downloads the pinned CEF (Chromium Embedded Framework) build for Windows x64 into
# ThirdParty\cef and builds its static C++ wrapper (libcef_dll_wrapper.lib).
# The Windows twin of scripts/fetch-cef.sh: same CEF version, so both shells run
# the same Chromium. The minimal distribution is a large download (a few hundred MB
# unpacked); run it only when you mean to.
#
#   pwsh scripts/fetch-cef.ps1
#
# Needs cmake, Ninja and the MSVC build tools (a "Developer PowerShell" or vcvars64).
$ErrorActionPreference = 'Stop'

$CefVersion = '156.0.7+g47dbc1d+chromium-156.0.8078.17'
$CefPlatform = 'windows64'
# Pin the SHA-1 after the first verified download (the CDN's .sha1 is checked either way).
$CefSha1 = ''

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$ThirdParty = Join-Path $Root 'ThirdParty'
$Dest = Join-Path $ThirdParty 'cef'
$Name = "cef_binary_${CefVersion}_${CefPlatform}_minimal"
$Archive = Join-Path $ThirdParty "$Name.tar.bz2"
$Stamp = Join-Path $Dest '.version'

if ((Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq $CefVersion)) {
    Write-Host "CEF $CefVersion already present"
} else {
    New-Item -ItemType Directory -Force -Path $ThirdParty | Out-Null
    $url = 'https://cef-builds.spotifycdn.com/' + [uri]::EscapeDataString("$Name.tar.bz2")
    if (-not (Test-Path $Archive)) {
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile "$Archive.part"
        Move-Item "$Archive.part" $Archive
    }
    $expected = $CefSha1
    if (-not $expected) { $expected = (Invoke-WebRequest -Uri "$url.sha1").Content.Trim() }
    $actual = (Get-FileHash -Algorithm SHA1 $Archive).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) { throw "SHA-1 mismatch for ${Name}: got $actual, expected $expected" }
    Write-Host "SHA-1 $actual"

    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    $unpacked = Join-Path $ThirdParty $Name
    if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
    # Windows 10+ ships bsdtar as tar.exe, which reads .tar.bz2.
    tar -xjf $Archive -C $ThirdParty
    if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
    Move-Item $unpacked $Dest
    Set-Content -Path $Stamp -Value $CefVersion -NoNewline
    Remove-Item $Archive
}

# libcef_dll_wrapper: CEF's C++ API on top of its C ABI. Static CRT (/MT) to match CEF's default.
$wrapper = Join-Path $Dest 'build\libcef_dll_wrapper\libcef_dll_wrapper.lib'
if (-not (Test-Path $wrapper)) {
    cmake -S $Dest -B (Join-Path $Dest 'build') -G Ninja `
        -DCMAKE_BUILD_TYPE=Release `
        -DPROJECT_ARCH=x86_64 `
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }
    cmake --build (Join-Path $Dest 'build') --target libcef_dll_wrapper
    if ($LASTEXITCODE -ne 0) { throw 'cmake build failed' }
}
Write-Host "CEF ready at $Dest"
