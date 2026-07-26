@echo off
REM Legado Flutter Windows 一键构建+运行（CMD 兼容）
set PATH=C:\Users\admin\.cargo\bin;%PATH%

echo === Building Rust FFI ===
cd /d "%~dp0..\..\rust"
cargo build -p legado-ffi
if errorlevel 1 exit /b 1

echo === Building Flutter ===
cd /d "%~dp0.."
call flutter build windows --debug
if errorlevel 1 exit /b 1

echo === Copying DLL ===
copy /Y "..\rust\target\debug\legado_ffi.dll" "build\windows\x64\runner\Debug\" >nul

echo === Running ===
call flutter run -d windows
