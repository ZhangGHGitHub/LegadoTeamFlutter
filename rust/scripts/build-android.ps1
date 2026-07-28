# build-android.ps1 — 交叉编译 Rust FFI 为 Android 各架构的 .so 文件 (Windows)
# 用法: .\build-android.ps1 [-Mode release|debug] [-Targets "x86_64,aarch64,armv7"]
#
# 示例:
#   .\build-android.ps1                          # 编译所有架构 (release)
#   .\build-android.ps1 -Mode debug              # 编译所有架构 (debug)
#   .\build-android.ps1 -Targets "x86_64"        # 仅编译 x86_64 (模拟器)
#   .\build-android.ps1 -Targets "aarch64"       # 仅编译 arm64 (真机)

param(
    [ValidateSet("release", "debug")]
    [string]$Mode = "release",

    [string]$Targets = "aarch64,armv7,x86_64"
)

$ErrorActionPreference = "Stop"

# ========== 架构映射 ==========
$AllTargets = [ordered]@{
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

# 解析用户选择的 targets
$SelectedKeys = $Targets -split "," | ForEach-Object { $_.Trim() }
foreach ($key in $SelectedKeys) {
    if (-not $AllTargets.Contains($key)) {
        Write-Error "Unknown target: $key. Available: $($AllTargets.Keys -join ', ')"
        exit 1
    }
}

# ========== 检测 Android NDK ==========
function Find-Ndk {
    # 1. 环境变量优先
    if ($env:ANDROID_NDK_HOME -and (Test-Path $env:ANDROID_NDK_HOME)) {
        return $env:ANDROID_NDK_HOME
    }
    # 2. 常见安装路径
    $candidates = @(
        "D:\Android\ndk",
        "$env:LOCALAPPDATA\Android\Sdk\ndk",
        "$env:ANDROID_HOME\ndk",
        "C:\Android\ndk"
    )
    foreach ($base in $candidates) {
        if (Test-Path $base) {
            # 取最新版本
            $latest = Get-ChildItem $base -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($latest) { return $latest.FullName }
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

# ========== 环境设置 ==========
$env:ANDROID_NDK_HOME = $NdkPath
# 将 NDK 工具链加入 PATH（供 cc-rs 发现 clang）
$env:PATH = "$ToolchainBin;$env:PATH"

# TLS 说明：reqwest 使用 rustls-tls (default-features=false)，无需 OpenSSL

Write-Host "=== Legado Rust Android Build ===" -ForegroundColor Cyan
Write-Host "Mode:      $Mode"
Write-Host "NDK:       $NdkPath"
Write-Host "Toolchain: $ToolchainBin"
Write-Host "Targets:   $($SelectedKeys -join ', ')"
Write-Host ""

# ========== 切到 rust workspace 目录 ==========
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RustDir   = Split-Path -Parent $ScriptDir
Set-Location $RustDir

# ========== 安装 Rust targets ==========
$triples = $SelectedKeys | ForEach-Object { $AllTargets[$_].triple }
Write-Host ">> Ensuring Rust targets installed..." -ForegroundColor Yellow
rustup target add @triples
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to install Rust targets"
    exit 1
}

# ========== 编译 ==========
foreach ($key in $SelectedKeys) {
    $info   = $AllTargets[$key]
    $triple = $info.triple

    # 设置 CC/AR 环境变量（cc-rs crate 需要）
    $ccName = $info.cc
    $env:CC = Join-Path $ToolchainBin $ccName
    $env:AR = Join-Path $ToolchainBin "llvm-ar.exe"

    # 也设置 target-specific 变量（更精确）
    $envVar = $triple -replace "-", "_"
    [System.Environment]::SetEnvironmentVariable("CC_$envVar", $env:CC, "Process")
    [System.Environment]::SetEnvironmentVariable("AR_$envVar", $env:AR, "Process")

    Write-Host ""
    Write-Host ">> Building $triple ($($info.abi))..." -ForegroundColor Yellow

    if ($Mode -eq "release") {
        cargo build --release --target $triple -p legado-ffi 2>&1
    } else {
        cargo build --target $triple -p legado-ffi 2>&1
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed for $triple"
        exit 1
    }
    Write-Host "   OK" -ForegroundColor Green
}

# ========== 复制到 Flutter jniLibs ==========
$FlutterJni = Join-Path (Split-Path -Parent $RustDir) "flutter_legado\android\app\src\main\jniLibs"

Write-Host ""
Write-Host ">> Copying .so files to Flutter jniLibs..." -ForegroundColor Yellow

foreach ($key in $SelectedKeys) {
    $info   = $AllTargets[$key]
    $triple = $info.triple
    $abi    = $info.abi

    $srcFile = Join-Path $RustDir "target\$triple\$Mode\liblegado_ffi.so"
    $dstDir  = Join-Path $FlutterJni $abi

    if (-not (Test-Path $srcFile)) {
        Write-Error "Expected .so not found: $srcFile"
        exit 1
    }

    if (-not (Test-Path $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    Copy-Item $srcFile $dstDir -Force
    $size = [math]::Round((Get-Item (Join-Path $dstDir "liblegado_ffi.so")).Length / 1MB, 1)
    Write-Host "   $abi\liblegado_ffi.so (${size} MB)" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Build complete! ===" -ForegroundColor Cyan
Write-Host "Output: $FlutterJni"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  cd ..\flutter_legado"
Write-Host "  flutter build apk --debug"
Write-Host "  adb install -r build\app\outputs\flutter-apk\app-debug.apk"
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
