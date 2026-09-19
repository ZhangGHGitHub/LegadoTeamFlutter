#!/usr/bin/env pwsh
# Legado Flutter Android 一键构建脚本
#
# 完整流程：Rust 交叉编译 → 复制 .so → Flutter 构建 APK → 安装到设备
#
# 用法:
#   .\scripts\build-apk.ps1                    # 构建 debug APK 并安装
#   .\scripts\build-apk.ps1 -Release           # 构建 release APK
#   .\scripts\build-apk.ps1 -BuildOnly         # 仅构建不安装
#   .\scripts\build-apk.ps1 -Targets "x86_64"  # 仅编译 x86_64（模拟器）
#   .\scripts\build-apk.ps1 -SkipRust          # 跳过 Rust 编译（.so 已存在时）
#   .\scripts\build-apk.ps1 -Clean             # 清理后重新构建
# 
# FFI / .so 新鲜度检查（P2-13）：
#   - 脚本会比较「Rust 源码树指纹」（rust/** 内容哈希，构建时记录在 .so.meta）与当前源码树：
#     Rust 源码已变更 / .so 陈旧 → 自动重编 .so；FFI 面与源码均未变 → 复用 .so；
#   - 若你手工 -SkipRust，检测到源码树变更时本脚本会硬失败（防止打包旧 .so）；
#     确需跳过时，请自行确保 .so 与 Rust 源码一致（例如确认只改了 Dart）。

param(
    [switch]$Release,
    [switch]$BuildOnly,
    [switch]$SkipRust,
    [switch]$Clean,
    [string]$Targets = "aarch64,x86_64",
    [string]$AdbPath = "D:\Android\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"

# ========== 路径设置 ==========
$env:PATH = "C:\Users\admin\.cargo\bin;$env:PATH"
$FlutterDir = Split-Path -Parent $PSScriptRoot
$RootDir = Split-Path -Parent $FlutterDir
$RustDir = Join-Path $RootDir "rust"
$BuildScript = Join-Path $RustDir "scripts\build-android.ps1"
$VerifyScript = Join-Path $RustDir "scripts\verify-ffi-android.ps1"
$FingerprintScript = Join-Path $RustDir "scripts\rust-fingerprint.ps1"
$JniLibsDir = Join-Path $FlutterDir "android\app\src\main\jniLibs"

$Mode = if ($Release) { "release" } else { "debug" }

# P2-13: 前置检查 —— 比对 jniLibs 各 .so 的源码树指纹与当前 Rust 源码树（rust-fingerprint.ps1 -Check）。
# 逐 ABI 明细行由子脚本 Write-Host 直接上屏；DECISION 行被捕获解析。
# 返回 "REUSE" / "REBUILD" / $null（前置检查不可用，交由 verify 脚本判定）
function Get-SoFingerprintDecision {
    [CmdletBinding()]
    param([string]$FpTargets)
    if (-not (Test-Path $FingerprintScript)) { return $null }
    $fpOut = $null
    try {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $fpOut = & $FingerprintScript -Check -Targets $FpTargets
        $ErrorActionPreference = $prevEAP
    } catch {
        Write-Host "WARNING: Rust 源码树指纹前置检查失败（$($_.Exception.Message)），交由 verify 脚本判定" -ForegroundColor Yellow
        return $null
    }
    foreach ($line in @($fpOut)) {
        if ("$line" -match '^DECISION=(REUSE|REBUILD)') { return $Matches[1] }
    }
    return $null
}

Write-Host "=== Legado Android Build ===" -ForegroundColor Cyan
Write-Host "Mode:    $Mode"
Write-Host "Targets: $Targets"
Write-Host "Rust:    $RustDir"
Write-Host "Flutter: $FlutterDir"
Write-Host ""

# ========== Step 1: Clean (optional) ==========
if ($Clean) {
    Write-Host "--- [1/5] Cleaning ---" -ForegroundColor Yellow
    Set-Location $FlutterDir
    flutter clean
    Write-Host ""
} else {
    Write-Host "--- [1/5] Clean skipped ---" -ForegroundColor DarkGray
}

# ========== Step 2: Rust 交叉编译 / FFI 校验 ==========
if ($SkipRust) {
    Write-Host "--- [2/5] Rust build skipped ---" -ForegroundColor DarkGray
    # P2-13: 跳过 Rust 构建时仍检查源码树指纹；.so 陈旧则硬失败，
    # 防止打包「旧 Rust + 新 Dart」混合体的旧 .so
    $fpDecision = Get-SoFingerprintDecision -FpTargets $Targets
    if ($fpDecision -eq "REBUILD") {
        Write-Host "ERROR: Rust 源码已变更（或 .so 陈旧/缺失）但指定了 -SkipRust：将打包旧 .so（""旧 Rust + 新 Dart"" 混合体）！" -ForegroundColor Red
        Write-Host "请去掉 -SkipRust 重跑以重编 .so；确需跳过时，请自行确保 .so 与 Rust 源码一致。" -ForegroundColor Red
        exit 1
    }
    if (Test-Path $VerifyScript) {
        & $VerifyScript -Mode $Mode -Targets $Targets
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: jniLibs 与 FRB content hash 不同步！请去掉 -SkipRust 重编。" -ForegroundColor Red
            exit 1
        }
    } else {
        # 回退：仅检查 .so 是否存在
        $soExists = (Test-Path "$JniLibsDir\x86_64\liblegado_ffi.so") -or
                    (Test-Path "$JniLibsDir\arm64-v8a\liblegado_ffi.so")
        if (-not $soExists) {
            Write-Host "WARNING: jniLibs 中无 .so 文件，APK 将无法在 Android 上运行！" -ForegroundColor Red
            Write-Host "Remove -SkipRust to build Rust FFI." -ForegroundColor Red
        }
    }
} else {
    Write-Host "--- [2/5] Verifying / building Rust FFI ---" -ForegroundColor Yellow
    # P2-13: 前置检查打印明确结论（重编/复用）；实际重编/复用决策由 verify 脚本执行
    $fpDecision = Get-SoFingerprintDecision -FpTargets $Targets
    if ($fpDecision -eq "REBUILD") {
        Write-Host ">> Rust 源码已变更（或 .so 陈旧/缺失），正在重编 .so ..." -ForegroundColor Yellow
    } elseif ($fpDecision -eq "REUSE") {
        Write-Host ">> FFI 面与源码均未变，复用现有 .so" -ForegroundColor Green
    }
    if (Test-Path $VerifyScript) {
        & $VerifyScript -Mode $Mode -Targets $Targets -AutoBuild
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Rust FFI verify/build failed!" -ForegroundColor Red
            exit 1
        }
    } elseif (-not (Test-Path $BuildScript)) {
        Write-Host "ERROR: Build script not found: $BuildScript" -ForegroundColor Red
        exit 1
    } else {
        & $BuildScript -Mode $Mode -Targets $Targets
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Rust cross-compilation failed!" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host ""
}

# ========== Step 3: 验证 .so 文件 ==========
Write-Host "--- [3/5] Verifying .so files ---" -ForegroundColor Yellow
$soFiles = Get-ChildItem "$JniLibsDir\*\liblegado_ffi.so" -ErrorAction SilentlyContinue
if ($soFiles) {
    foreach ($so in $soFiles) {
        $abi = $so.Directory.Name
        $sizeMB = [math]::Round($so.Length / 1MB, 1)
        Write-Host "  $abi\liblegado_ffi.so (${sizeMB} MB)" -ForegroundColor Green
    }
} else {
    Write-Host "WARNING: No .so files found in jniLibs!" -ForegroundColor Red
    Write-Host "  Expected at: $JniLibsDir\<abi>\liblegado_ffi.so" -ForegroundColor Red
}
Write-Host ""

# ========== Step 4: Flutter 构建 APK ==========
Write-Host "--- [4/5] Building Flutter APK ($Mode) ---" -ForegroundColor Yellow
Set-Location $FlutterDir
if ($Release) {
    flutter build apk --release
} else {
    flutter build apk --debug
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Flutter build failed!" -ForegroundColor Red
    exit 1
}

$ApkPath = if ($Release) {
    Join-Path $FlutterDir "build\app\outputs\flutter-apk\app-release.apk"
} else {
    Join-Path $FlutterDir "build\app\outputs\flutter-apk\app-debug.apk"
}
$ApkSize = [math]::Round((Get-Item $ApkPath).Length / 1MB, 1)
Write-Host "APK: $ApkPath (${ApkSize} MB)" -ForegroundColor Green
Write-Host ""

# ========== Step 5: 安装到设备 ==========
if ($BuildOnly) {
    Write-Host "--- [5/5] Install skipped (-BuildOnly) ---" -ForegroundColor DarkGray
} else {
    Write-Host "--- [5/5] Installing to device ---" -ForegroundColor Yellow
    if (-not (Test-Path $AdbPath)) {
        Write-Host "WARNING: adb not found at $AdbPath, skipping install" -ForegroundColor Yellow
        Write-Host "  Manual install: adb install -r $ApkPath" -ForegroundColor Yellow
    } else {
        # 检查设备连接
        $devices = & $AdbPath devices 2>&1 | Select-String "device$"
        if (-not $devices) {
            Write-Host "WARNING: No device connected, skipping install" -ForegroundColor Yellow
            Write-Host "  Connect a device/emulator, then: adb install -r $ApkPath" -ForegroundColor Yellow
        } else {
            & $AdbPath install -r $ApkPath
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Installed successfully!" -ForegroundColor Green
                # 启动应用
                & $AdbPath shell am start -n "io.legado.flutter_legado/io.legado.flutter.MainActivity" 2>&1 | Out-Null
                Write-Host "App launched." -ForegroundColor Green
            } else {
                Write-Host "WARNING: Install failed" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Cyan
