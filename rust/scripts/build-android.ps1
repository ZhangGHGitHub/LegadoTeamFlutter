# build-android.ps1 — 编译 Rust 为 Android 各架构的 .so 文件 (Windows)
# 用法: .\build-android.ps1 [-Mode release|debug]

param(
    [ValidateSet("release", "debug")]
    [string]$Mode = "release"
)

$ErrorActionPreference = "Stop"

$Targets = @(
    "aarch64-linux-android",
    "armv7-linux-androideabi",
    "x86_64-linux-android"
)

# 检查 Android NDK
if (-not $env:ANDROID_NDK_HOME) {
    Write-Error "ANDROID_NDK_HOME environment variable not set.`nPlease set it to your Android NDK installation path.`nExample: `$env:ANDROID_NDK_HOME = 'C:\Users\<user>\AppData\Local\Android\Sdk\ndk\<version>'"
    exit 1
}

Write-Host "=== Legado Rust Android Build ===" -ForegroundColor Cyan
Write-Host "Mode:    $Mode"
Write-Host "NDK:     $env:ANDROID_NDK_HOME"
Write-Host "Targets: $($Targets -join ', ')"
Write-Host ""

# 切到 rust 目录（脚本所在目录的上级）
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RustDir   = Split-Path -Parent $ScriptDir
Set-Location $RustDir

# 安装 targets
Write-Host ">> Installing Rust targets..." -ForegroundColor Yellow
rustup target add @Targets

# 编译
foreach ($target in $Targets) {
    Write-Host ""
    Write-Host ">> Building for $target..." -ForegroundColor Yellow
    if ($Mode -eq "release") {
        cargo build --release --target $target -p legado-ffi
    } else {
        cargo build --target $target -p legado-ffi
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed for $target"
        exit 1
    }
}

# 复制到 Flutter jniLibs
$FlutterJni = Join-Path (Split-Path -Parent $RustDir) "flutter_legado\android\app\src\main\jniLibs"

$ArchMap = @{
    "aarch64-linux-android"      = "arm64-v8a"
    "armv7-linux-androideabi"    = "armeabi-v7a"
    "x86_64-linux-android"       = "x86_64"
}

foreach ($arch in $ArchMap.Values) {
    $dir = Join-Path $FlutterJni $arch
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Write-Host ""
Write-Host ">> Copying .so files to Flutter jniLibs..." -ForegroundColor Yellow

foreach ($target in $Targets) {
    $arch    = $ArchMap[$target]
    $srcFile = Join-Path "target\$target\$Mode" "liblegado_ffi.so"
    $dstDir  = Join-Path $FlutterJni $arch

    if (-not (Test-Path $srcFile)) {
        Write-Error "Expected .so not found: $srcFile"
        exit 1
    }
    Copy-Item $srcFile $dstDir -Force
    Write-Host "  $arch\liblegado_ffi.so" -ForegroundColor Green
}

Write-Host ""
Write-Host "Build complete! .so files copied to:" -ForegroundColor Cyan
Write-Host "  $FlutterJni"
