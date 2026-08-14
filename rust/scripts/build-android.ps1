# build-android.ps1 — 交叉编译 Rust FFI 为 Android 各架构的 .so 文件 (Windows)
# 用法: .\build-android.ps1 [-Mode release|debug] [-Targets "x86_64,aarch64,armv7"]

param(
    [ValidateSet("release", "debug")]
    [string]$Mode = "release",

    [string]$Targets = "aarch64,armv7,x86_64"
)

$ErrorActionPreference = "Stop"

$AllTargets = @{
    "aarch64" = @{
        triple = "aarch64-linux-android"
        abi    = "arm64-v8a"
        cc     = "aarch64-linux-android21-clang.cmd"
    }
    "armv7" = @{
        triple = "armv7-linux-androideabi"
        abi    = "armeabi-v7a"
        cc     = "armv7a-linux-androideabi21-clang.cmd"
    }
    "x86_64" = @{
        triple = "x86_64-linux-android"
        abi    = "x86_64"
        cc     = "x86_64-linux-android21-clang.cmd"
    }
}

$SelectedKeys = $Targets -split "," | ForEach-Object { $_.Trim() }
foreach ($key in $SelectedKeys) {
    if (-not $AllTargets.ContainsKey($key)) {
        Write-Error "Unknown target: $key. Available: $($AllTargets.Keys -join ', ')"
        exit 1
    }
}

function Find-Ndk {
    if ($env:ANDROID_NDK_HOME -and (Test-Path $env:ANDROID_NDK_HOME)) {
        return $env:ANDROID_NDK_HOME
    }
    $candidates = @(
        "D:\Android\ndk",
        "$env:LOCALAPPDATA\Android\Sdk\ndk",
        "$env:ANDROID_HOME\ndk",
        "C:\Android\ndk"
    )
    foreach ($base in $candidates) {
        if (Test-Path $base) {
            $latest = Get-ChildItem $base -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($latest) { return $latest.FullName }
        }
    }
    return $null
}

function Repair-RquickjsAndroidBindings {
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE ".cargo" }
    $regRoot = Join-Path $cargoHome "registry\src"
    if (-not (Test-Path $regRoot)) { return }

    $roots = @()
    $roots += Get-ChildItem $regRoot -Directory -Filter "index.*" -ErrorAction SilentlyContinue
    $roots += Get-ChildItem $regRoot -Directory -Filter "mirrors.*" -ErrorAction SilentlyContinue
    $rquickjsDirs = @()
    foreach ($root in $roots) {
        $rquickjsDirs += Get-ChildItem $root.FullName -Directory -Filter "rquickjs-sys-*" -ErrorAction SilentlyContinue
    }
    if ($rquickjsDirs.Count -eq 0) { return }

    $needed = @("aarch64-linux-android.rs", "armv7-linux-androideabi.rs", "x86_64-linux-android.rs")
    foreach ($pkg in $rquickjsDirs) {
        $bindDir = Join-Path $pkg.FullName "src\bindings"
        if (-not (Test-Path $bindDir)) { continue }
        foreach ($file in $needed) {
            $dst = Join-Path $bindDir $file
            if (Test-Path $dst) { continue }
            foreach ($donor in $rquickjsDirs) {
                $src = Join-Path $donor.FullName "src\bindings\$file"
                if (Test-Path $src) {
                    Copy-Item $src $dst -Force
                    Write-Host "   Patched missing binding: $($pkg.Name)\bindings\$file" -ForegroundColor DarkYellow
                    break
                }
            }
        }
    }
}

function Test-SoEmbedsHash {
    param([string]$SoPath, [int]$Hash)
    if (-not (Test-Path $SoPath)) { return $false }
    $needle = [System.BitConverter]::GetBytes([int32]$Hash)
    $bytes = [System.IO.File]::ReadAllBytes($SoPath)
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

function Find-SyncedSoInTarget {
    param([string]$RustDir, [string]$Triple, [string]$PreferredMode, [int]$Hash)
    foreach ($m in @($PreferredMode, "release", "debug")) {
        $candidate = Join-Path $RustDir "target\$Triple\$m\liblegado_ffi.so"
        if ((Test-Path $candidate) -and (Test-SoEmbedsHash -SoPath $candidate -Hash $Hash)) {
            return $candidate
        }
    }
    return $null
}

$NdkPath = Find-Ndk
if (-not $NdkPath) {
    Write-Error @"
Android NDK not found! Please either:
  1. Set ANDROID_NDK_HOME environment variable
  2. Install NDK via Android Studio SDK Manager
  3. Place NDK in D:\Android\ndk\<version>
"@
    exit 1
}

$ToolchainBin = Join-Path $NdkPath "toolchains\llvm\prebuilt\windows-x86_64\bin"
if (-not (Test-Path $ToolchainBin)) {
    Write-Error "NDK toolchain not found at: $ToolchainBin"
    exit 1
}

$env:ANDROID_NDK_HOME = $NdkPath
$env:PATH = "$ToolchainBin;$env:PATH"
$env:CFLAGS = ''
$env:CXXFLAGS = ''
Remove-Item Env:\CC, Env:\AR -ErrorAction SilentlyContinue

Write-Host "=== Legado Rust Android Build ===" -ForegroundColor Cyan
Write-Host "Mode:      $Mode"
Write-Host "NDK:       $NdkPath"
Write-Host "Toolchain: $ToolchainBin"
Write-Host "Targets:   $($SelectedKeys -join ', ')"
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RustDir   = Split-Path -Parent $ScriptDir
Set-Location $RustDir

Repair-RquickjsAndroidBindings

$FrbRs = Join-Path $RustDir "legado-ffi\src\frb_generated.rs"
$ContentHash = $null
if (Test-Path $FrbRs) {
    $frbText = Get-Content $FrbRs -Raw -Encoding UTF8
    if ($frbText -match 'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH:\s*i32\s*=\s*(-?\d+)') {
        $ContentHash = [int]$Matches[1]
        Write-Host "FRB content hash: $ContentHash" -ForegroundColor DarkGray
    }
}

$triples = $SelectedKeys | ForEach-Object { $AllTargets[$_].triple }
Write-Host ">> Ensuring Rust targets installed..." -ForegroundColor Yellow
rustup target add $triples
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to install Rust targets"
    exit 1
}

$BuiltSo = @{}

foreach ($key in $SelectedKeys) {
    $info   = $AllTargets[$key]
    $triple = $info.triple
    $ccName = $info.cc
    $envVar = $triple -replace "-", "_"
    [System.Environment]::SetEnvironmentVariable("CC_$envVar", (Join-Path $ToolchainBin $ccName), "Process")
    [System.Environment]::SetEnvironmentVariable("AR_$envVar", (Join-Path $ToolchainBin "llvm-ar.exe"), "Process")
    $linkerVar = "CARGO_TARGET_$($envVar.ToUpper())_LINKER"
    [System.Environment]::SetEnvironmentVariable($linkerVar, (Join-Path $ToolchainBin $ccName), "Process")
    [System.Environment]::SetEnvironmentVariable("CARGO_TARGET_$($envVar.ToUpper())_AR", (Join-Path $ToolchainBin "llvm-ar.exe"), "Process")

    Write-Host ""
    Write-Host ">> Building $triple ($($info.abi))..." -ForegroundColor Yellow

    $srcFile = Join-Path $RustDir "target\$triple\$Mode\liblegado_ffi.so"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($Mode -eq "release") {
        cargo build --release --target $triple -p legado-ffi --features quickjs 2>&1
    } else {
        cargo build --target $triple -p legado-ffi --features quickjs 2>&1
    }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($buildExit -ne 0 -and $null -ne $ContentHash) {
        $synced = Find-SyncedSoInTarget -RustDir $RustDir -Triple $triple -PreferredMode $Mode -Hash $ContentHash
        if ($synced) {
            Write-Host "   Reusing synced .so from target: $synced" -ForegroundColor Yellow
            $srcFile = $synced
            $buildExit = 0
        }
    }
    if ($buildExit -ne 0) {
        Write-Host "   quickjs build failed; retrying without quickjs ..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        if ($Mode -eq "release") {
            cargo build --release --target $triple -p legado-ffi 2>&1
        } else {
            cargo build --target $triple -p legado-ffi 2>&1
        }
        $buildExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $srcFile = Join-Path $RustDir "target\$triple\$Mode\liblegado_ffi.so"
    }

    if ($buildExit -ne 0 -or -not (Test-Path $srcFile)) {
        Write-Error "Build failed for $triple (no .so at $srcFile)"
        exit 1
    }

    $BuiltSo[$key] = $srcFile
    Write-Host "   OK" -ForegroundColor Green
}

$FlutterJni = Join-Path (Split-Path -Parent $RustDir) "flutter_legado\android\app\src\main\jniLibs"

Write-Host ""
Write-Host ">> Copying .so files to Flutter jniLibs..." -ForegroundColor Yellow

foreach ($key in $SelectedKeys) {
    $info = $AllTargets[$key]
    $abi = $info.abi
    $srcFile = $BuiltSo[$key]
    $dstDir = Join-Path $FlutterJni $abi

    if (-not (Test-Path $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    $dstFile = Join-Path $dstDir "liblegado_ffi.so"
    Copy-Item $srcFile $dstFile -Force
    $size = [math]::Round((Get-Item $dstFile).Length / 1MB, 1)
    Write-Host "   $abi\liblegado_ffi.so (${size} MB)" -ForegroundColor Green

    if ($null -ne $ContentHash) {
        $meta = [ordered]@{
            contentHash = $ContentHash
            mode        = $Mode
            builtAt     = (Get-Date).ToString("o")
        }
        ($meta | ConvertTo-Json -Compress) | Set-Content "$dstFile.meta" -Encoding UTF8 -NoNewline
    }
}

Write-Host ""
Write-Host "=== Build complete! ===" -ForegroundColor Cyan
Write-Host "Output: $FlutterJni"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  cd ..\flutter_legado"
Write-Host "  flutter build apk --debug"
Write-Host "  # or: .\scripts\build-apk.ps1"
