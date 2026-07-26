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

Write-Host ""
Write-Host "Bridge code generated successfully!" -ForegroundColor Green
Write-Host "Generated files are in lib\src\bridge\"
