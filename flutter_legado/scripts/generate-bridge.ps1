# generate-bridge.ps1 — 运行 flutter_rust_bridge 代码生成 (Windows)
# 用法: .\generate-bridge.ps1

$ErrorActionPreference = "Stop"

# 切到 flutter_legado 目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FlutterDir = Split-Path -Parent $ScriptDir
Set-Location $FlutterDir

Write-Host "=== flutter_rust_bridge Code Generation ===" -ForegroundColor Cyan
Write-Host "Working dir: $(Get-Location)"
Write-Host ""

# 检查 flutter_rust_bridge_codegen 是否已安装
if (-not (Get-Command flutter_rust_bridge_codegen -ErrorAction SilentlyContinue)) {
    Write-Error "flutter_rust_bridge_codegen not found.`nInstall it with:`n  cargo install flutter_rust_bridge_codegen"
    exit 1
}

Write-Host ">> Running codegen..." -ForegroundColor Yellow
flutter_rust_bridge_codegen generate

if ($LASTEXITCODE -ne 0) {
    Write-Error "Code generation failed"
    exit 1
}

# 关键：codegen 会重新生成两侧 content hash，必须紧跟一次 DLL 重编译，
# 否则运行时报 "Content hash on Dart side ... different from Rust side"。
Write-Host ""
Write-Host ">> Rebuilding Rust FFI DLL (keep hash in sync)..." -ForegroundColor Yellow
$RustDir = Join-Path (Split-Path -Parent $FlutterDir) "rust"
# DLL 可能被运行中的应用锁定，先尝试关闭
Stop-Process -Name "flutter_legado" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Push-Location $RustDir
cargo build -p legado-ffi
$rustExit = $LASTEXITCODE
Pop-Location
if ($rustExit -ne 0) {
    Write-Error "Rust FFI build failed"
    exit 1
}

Write-Host ""
Write-Host "Bridge code generated & DLL rebuilt successfully!" -ForegroundColor Green
Write-Host "Generated files are in lib\src\bridge\"
