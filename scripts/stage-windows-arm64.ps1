param(
    [switch]$VerifyBuild
)

$ErrorActionPreference = 'Stop'
$target = 'aarch64-pc-windows-msvc'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'src-tauri'
$bin = Join-Path $app 'binaries'
$libmpv = Join-Path $app 'libmpv'

if (-not [OperatingSystem]::IsWindows() -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::Arm64 -or [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
    throw 'This staging script requires a native Windows ARM64 host and ARM64 PowerShell process.'
}

function Assert-Arm64Pe([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing binary: $path" }
    $stream = [System.IO.File]::OpenRead($path)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 6) { throw "Invalid PE offset: $path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Not a PE file: $path" }
        $machine = $reader.ReadUInt16()
        if ($machine -ne 0xaa64) { throw ('Expected ARM64 PE machine 0xAA64, got 0x{0:X4}: {1}' -f $machine, $path) }
        Write-Host "ARM64 PE: $path"
    } finally {
        $stream.Dispose()
    }
}

function Assert-NativeLibmpv {
    $dll = Join-Path $libmpv 'libmpv-2.dll'
    Assert-Arm64Pe $dll
    $handle = [System.Runtime.InteropServices.NativeLibrary]::Load($dll)
    try { Write-Host 'ARM64 libmpv loaded in the native process.' }
    finally { [System.Runtime.InteropServices.NativeLibrary]::Free($handle) }
}

function Assert-Stage {
    foreach ($name in @('mpv', 'ffmpeg', 'ffprobe', 'yt-dlp')) {
        # The current Windows bundle config and managed payload read these legacy x64-named
        # files. This workflow stages ARM64 PE files there and checks their machine headers.
        Assert-Arm64Pe (Join-Path $bin "$name-x86_64-pc-windows-msvc.exe")
        if ($name -ne 'mpv') {
            # Tauri externalBin resolves its input by the requested Rust target.
            Assert-Arm64Pe (Join-Path $bin "$name-$target.exe")
        }
    }
    Assert-NativeLibmpv
}

if ($VerifyBuild) {
    Assert-Stage
    foreach ($path in @(
        (Join-Path $app "target/$target/release/harbor.exe"),
        (Join-Path $app 'target/release/harbor.exe'),
        (Join-Path $root 'installer/src-tauri/target/release/harbor-uninstall.exe'),
        (Join-Path $root 'installer/src-tauri/target/release/harbor-setup.exe')
    )) { Assert-Arm64Pe $path }
    exit 0
}

function Get-VerifiedAsset([string]$url, [string]$sha256, [string]$path) {
    Write-Host "Fetching $url"
    Invoke-WebRequest -Uri $url -OutFile $path
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $sha256) { throw "SHA-256 mismatch for $url (expected $sha256, got $actual)" }
}

function Find-One([string]$directory, [string]$name) {
    $item = Get-ChildItem -LiteralPath $directory -Recurse -File -Filter $name | Select-Object -First 1
    if (-not $item) { throw "Cannot find $name in $directory" }
    return $item.FullName
}

$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $sevenZip) { $sevenZip = 'C:\Program Files\7-Zip\7z.exe' }
if (-not (Test-Path -LiteralPath $sevenZip)) { throw '7-Zip is required on the ARM64 runner.' }

$temp = Join-Path $env:RUNNER_TEMP 'harbor-windows-arm64-assets'
New-Item -ItemType Directory -Force -Path $temp, $bin, $libmpv | Out-Null

$assets = @(
    @{ Name = 'mpv'; Url = 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260610/mpv-aarch64-20260610-git-304426c.7z'; Sha = '0781fdffeef27a40a7f266631d1ca9e5c1d0f82868a1678c58d23e0b1bd1eb98' },
    @{ Name = 'mpv-dev'; Url = 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260610/mpv-dev-aarch64-20260610-git-304426c.7z'; Sha = 'd9dd60db1c7b24db2e19d041f70abf0a4995f3e9eadf80a34e54f72300df6ed4' },
    @{ Name = 'ffmpeg'; Url = 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260610/ffmpeg-aarch64-git-2576e0943.7z'; Sha = '80ad97a134f486d46e4e140de7e65d6ac6c5c744c89ae8df23496132f1d771e1'
    }
)

foreach ($asset in $assets) {
    $archive = Join-Path $temp "$($asset.Name).7z"
    $out = Join-Path $temp $asset.Name
    Get-VerifiedAsset $asset.Url $asset.Sha $archive
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    & $sevenZip x -y $archive "-o$out" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed for $archive" }
}

$ytDlp = Join-Path $temp 'yt-dlp_arm64.exe'
Get-VerifiedAsset 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_arm64.exe' '05b438997bafc3affdfda9d041353c9d73e04dc842207254b655b0887c4445b0' $ytDlp

Copy-Item -LiteralPath (Find-One (Join-Path $temp 'mpv') 'mpv.exe') -Destination (Join-Path $bin 'mpv-x86_64-pc-windows-msvc.exe') -Force
Copy-Item -LiteralPath (Find-One (Join-Path $temp 'ffmpeg') 'ffmpeg.exe') -Destination (Join-Path $bin 'ffmpeg-x86_64-pc-windows-msvc.exe') -Force
Copy-Item -LiteralPath (Find-One (Join-Path $temp 'ffmpeg') 'ffprobe.exe') -Destination (Join-Path $bin 'ffprobe-x86_64-pc-windows-msvc.exe') -Force
Copy-Item -LiteralPath $ytDlp -Destination (Join-Path $bin 'yt-dlp-x86_64-pc-windows-msvc.exe') -Force
foreach ($name in @('ffmpeg', 'ffprobe', 'yt-dlp')) {
    Copy-Item -LiteralPath (Join-Path $bin "$name-x86_64-pc-windows-msvc.exe") -Destination (Join-Path $bin "$name-$target.exe") -Force
}
Copy-Item -LiteralPath (Find-One (Join-Path $temp 'mpv-dev') 'libmpv-2.dll') -Destination (Join-Path $libmpv 'libmpv-2.dll') -Force

Assert-Stage

$vcTools = Get-ChildItem -Path "$env:ProgramFiles\Microsoft Visual Studio" -Filter lib.exe -Recurse -File |
    Where-Object { $_.FullName -match '\\HostArm64\\arm64\\lib\.exe$' } | Select-Object -First 1
if (-not $vcTools) { throw 'Native ARM64 MSVC tools are missing from the runner.' }
$libTool = $vcTools.FullName
$dumpbin = Join-Path $vcTools.DirectoryName 'dumpbin.exe'
if (-not (Test-Path -LiteralPath $dumpbin)) { throw "ARM64 dumpbin.exe is missing beside $libTool" }

# The pinned ARM64 dev archive has a DLL and MinGW import library, but no .def.
# Generate the MSVC import library from that exact DLL's exports.
$exports = & $dumpbin /exports (Join-Path $libmpv 'libmpv-2.dll')
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect ARM64 libmpv exports.' }
$names = @($exports | ForEach-Object {
    if ($_ -match '^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { $Matches[1] }
} | Sort-Object -Unique)
if (@($names | Where-Object { $_ -like 'mpv_*' }).Count -lt 30) { throw 'ARM64 libmpv has too few mpv exports to generate an import library.' }
$definition = Join-Path $libmpv 'libmpv.def'
@('LIBRARY libmpv-2', 'EXPORTS') + @($names | ForEach-Object { "    $_" }) |
    Set-Content -LiteralPath $definition -Encoding ascii
Write-Host "Generated $definition from $($names.Count) ARM64 DLL exports."
& $libTool "/def:$definition" "/out:$(Join-Path $libmpv 'mpv.lib')" /machine:ARM64
if ($LASTEXITCODE -ne 0) { throw 'Failed to generate the ARM64 libmpv import library.' }

foreach ($name in @('mpv', 'ffmpeg', 'ffprobe', 'yt-dlp')) {
    $exe = Join-Path $bin "$name-x86_64-pc-windows-msvc.exe"
    $versionFlag = if ($name -in @('ffmpeg', 'ffprobe')) { '-version' } else { '--version' }
    & $exe $versionFlag | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$name $versionFlag failed on ARM64." }
}
