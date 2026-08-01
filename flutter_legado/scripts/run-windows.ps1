# run-windows.ps1 — Windows 开发运行（先同步 DLL 再启动）
#
# 用途：避免反复出现 content hash 不同步导致的 "Rust 引擎初始化失败"。
# 启动前必定重编译 Rust FFI DLL，使其与当前 Dart 生成代码保持一致。
#
# 用法:
#   .\scripts\run-windows.ps1            # 重编译 DLL 后运行
#   .\scripts\run-windows.ps1 -Release   # Release 模式

param(
    [switch]$Release
)

$ErrorActionPreference = "Stop"

# 定位目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FlutterDir = Split-Path -Parent $ScriptDir
$RustDir = Join-Path (Split-Path -Parent $FlutterDir) "rust"

Write-Host "=== Legado Windows Dev Run ===" -ForegroundColor Cyan

# Step 1: 关闭可能锁定 DLL 的运行实例
Stop-Process -Name "flutter_legado" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Step 2: 重编译 Rust FFI DLL（与当前代码保持 hash 同步）
Write-Host "`n>> Rebuilding Rust FFI DLL..." -ForegroundColor Yellow
Push-Location $RustDir
if ($Release) {
    cargo build --release -p legado-ffi --features quickjs
} else {
    cargo build -p legado-ffi --features quickjs
}
$rustExit = $LASTEXITCODE
Pop-Location
if ($rustExit -ne 0) {
    Write-Error "Rust FFI build failed"
    exit 1
}

# Step 3: 启动 Flutter 应用
Write-Host "`n>> Launching Flutter app..." -ForegroundColor Yellow
Set-Location $FlutterDir
if ($Release) {
    flutter run -d windows --release
} else {
    flutter run -d windows
}
