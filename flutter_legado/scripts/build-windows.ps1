#!/usr/bin/env pwsh
# Legado Flutter Windows 一键构建+运行脚本
# 
# 用法:
#   .\scripts\build-windows.ps1          # 构建并运行
#   .\scripts\build-windows.ps1 -BuildOnly  # 仅构建不运行
#   .\scripts\build-windows.ps1 -Release    # Release 模式

param(
    [switch]$BuildOnly,
    [switch]$Release,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# 设置路径
$env:PATH = "C:\Users\admin\.cargo\bin;$env:PATH"
$RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RustDir = Join-Path $RootDir "rust"
$FlutterDir = Split-Path -Parent $PSScriptRoot

Write-Host "=== Legado Windows Build ===" -ForegroundColor Cyan
Write-Host "Root: $RootDir"
Write-Host "Rust: $RustDir"
Write-Host "Flutter: $FlutterDir"

# Step 1: Clean (optional)
if ($Clean) {
    Write-Host "`n--- Cleaning ---" -ForegroundColor Yellow
    Set-Location $RustDir
    cargo clean
    Set-Location $FlutterDir
    flutter clean
}

# Step 2: Build Rust FFI library
Write-Host "`n--- Building Rust FFI Library ---" -ForegroundColor Yellow
Set-Location $RustDir
if ($Release) {
    cargo build --release -p legado-ffi
    $DllName = "legado_ffi.dll"
    $DllPath = Join-Path $RustDir "target\release\$DllName"
} else {
    cargo build -p legado-ffi
    $DllName = "legado_ffi.dll"
    $DllPath = Join-Path $RustDir "target\debug\$DllName"
}

if (-not (Test-Path $DllPath)) {
    Write-Host "ERROR: Rust FFI library not found at $DllPath" -ForegroundColor Red
    exit 1
}
Write-Host "Rust FFI library built: $DllPath" -ForegroundColor Green

# Step 3: Build Flutter Windows
Write-Host "`n--- Building Flutter Windows ---" -ForegroundColor Yellow
Set-Location $FlutterDir
if ($Release) {
    flutter build windows --release
} else {
    flutter build windows --debug
}

# Step 4: Copy Rust DLL to Flutter build output
Write-Host "`n--- Copying Rust DLL ---" -ForegroundColor Yellow
$Mode = if ($Release) { "Release" } else { "Debug" }
$DestDir = Join-Path $FlutterDir "build\windows\x64\runner\$Mode"
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}
Copy-Item $DllPath $DestDir -Force
Write-Host "Copied $DllName to $DestDir" -ForegroundColor Green

# Step 5: Run (optional)
if (-not $BuildOnly) {
    Write-Host "`n--- Running Flutter App ---" -ForegroundColor Yellow
    Set-Location $FlutterDir
    flutter run -d windows
}

Write-Host "`n=== Build Complete ===" -ForegroundColor Cyan
