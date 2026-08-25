# ============================================================
# 模拟器冒烟测试脚本（Legado Flutter 轨）
# 流程：构建 debug APK → 安装到指定模拟器 → 启动应用 →
#       进程存活检查 → 崩溃日志检查 →（可选）UI 元素冒烟
# 用法示例：
#   .\scripts\emulator_smoke_test.ps1                      # 默认 emulator-5556
#   .\scripts\emulator_smoke_test.ps1 -Device emulator-5558   # 用户验收机
#   .\scripts\emulator_smoke_test.ps1 -SkipBuild              # 复用已有 APK
#   .\scripts\emulator_smoke_test.ps1 -CheckUI                 # 追加 UI 元素检查
# 退出码：0=通过 1=失败（可用于 CI/子代理验收门禁）
# 编写者：Reasonix ｜ 2026-08-10
# ============================================================
param(
  [string]$Device = "emulator-5556",
  [switch]$SkipBuild,
  [switch]$CheckUI,
  # 默认相对仓库根目录 flutter_legado/；可用 -FlutterDir 或环境变量 LEGADO_FLUTTER_DIR 覆盖
  [string]$FlutterDir = "",
  # 注意：与 android/app/build.gradle.kts 的 applicationId 保持同步
  #（2026-08-10 确认当前为 io.legado.flutter_legado，勿用旧包名 com.legado.legado_flutter）
  [string]$Package = "io.legado.flutter_legado",
  # MainActivity 类位于 io.legado.flutter 包（非 applicationId 同包），
  # 必须全限定类名（2026-08-10 修正：`.MainActivity` 报 Activity does not exist）
  [string]$Activity = "io.legado.flutter.MainActivity"
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# 注：native 命令（adb）的 stderr 警告在 Stop 策略下会被当作异常中止脚本，
# 改用 Continue + 各步骤显式 PASS/FAIL 检查（adb 的 "Activity not started"
# 警告属正常场景）
$ErrorActionPreference = "Continue"
$pass = 0; $fail = 0

# ---- 解析 Flutter 工程目录（F4-1：去硬编码，相对 scripts/ 定位仓库）----
if (-not $FlutterDir) {
  $FlutterDir = $env:LEGADO_FLUTTER_DIR
}
if (-not $FlutterDir) {
  $FlutterDir = Join-Path (Split-Path $PSScriptRoot -Parent) "flutter_legado"
}
$FlutterDir = (Resolve-Path $FlutterDir -ErrorAction Stop).Path

function Pass([string]$msg) { $script:pass++; Write-Host "[PASS] $msg" -ForegroundColor Green }
function Fail([string]$msg) { $script:fail++; Write-Host "[FAIL] $msg" -ForegroundColor Red }

# ---- 定位 adb（D:\Android 优先，其次环境变量，最后 PATH）----
function Find-Adb {
  $candidates = @(
    "D:\Android\platform-tools\adb.exe",
    "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
    "$env:ANDROID_HOME\platform-tools\adb.exe",
    "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command adb -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "未找到 adb，请安装 Android platform-tools 或设置 ANDROID_HOME"
}
$adb = Find-Adb
Write-Host "==> adb: $adb"
Write-Host "==> 目标设备: $Device（$Package）"

# ---- 1. 设备在线检查 ----
$devices = & $adb devices 2>$null | Select-String "$Device\s+device"
if (-not $devices) {
  Fail "设备 $Device 不在线（adb devices 中未见 device 状态）"
  Write-Host "提示：可用 flutter emulators 启动模拟器后重试"
  exit 1
}
Pass "设备 $Device 在线"

# ---- 2. 构建 APK ----
$apk = Join-Path $FlutterDir "build\app\outputs\flutter-apk\app-debug.apk"
$verifyScript = Join-Path (Split-Path $PSScriptRoot -Parent) "rust\scripts\verify-ffi-android.ps1"
if ($SkipBuild) {
  if (-not (Test-Path $apk)) { Fail "跳过构建但 APK 不存在：$apk"; exit 1 }
  Pass "跳过构建，复用已有 APK"
} else {
  # 构建前校验/自动同步 jniLibs（根治 content hash 失配）
  if (Test-Path $verifyScript) {
    Write-Host "==> 校验 Android FFI content hash ..."
    # .so 必须用 release 编译：debug 构建的 Rust 侧性能约为 release 的 1/10
    # （实测 favcomic 解析 C≈12s vs ≈1s），会污染性能结论；Dart APK 本身仍为 debug。
    & $verifyScript -Mode release -Targets "aarch64,x86_64" -AutoBuild
    if ($LASTEXITCODE -ne 0) {
      Fail "FFI 校验失败，无法继续构建（exit=$LASTEXITCODE）"
      exit 1
    }
    Pass "FFI content hash 校验通过"
  }
  Write-Host "==> flutter build apk --debug ..."
  Push-Location $FlutterDir
  try {
    flutter build apk --debug 2>&1 | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $apk)) {
      Fail "APK 构建失败（exit=$LASTEXITCODE）"
      exit 1
    }
  } finally { Pop-Location }
  Pass "APK 构建成功（$([math]::Round((Get-Item $apk).Length/1MB,1)) MB）"
}

# ---- 3. 安装 ----
Write-Host "==> adb install -r ..."
& $adb -s $Device install -r $apk 2>&1 | Select-Object -Last 1 | ForEach-Object {
  if ($_ -match "Success") { Pass "APK 安装成功" }
  else { Fail "APK 安装失败：$_" }
}
if ($fail -gt 0) { exit 1 }

# ---- 3.1 校验已装版本与 pubspec 一致（防 -SkipBuild 静默复用陈旧 APK）----
$pubVer = ((Select-String -Path "$FlutterDir\pubspec.yaml" -Pattern '^version:\s*(\S+)' | Select-Object -First 1).Matches[0].Groups[1].Value -split '\+')[0]
$instOut = & $adb -s $Device shell dumpsys package $Package 2>$null
$instVer = ($instOut | Select-String 'versionName=([0-9.]+)' | Select-Object -First 1).Matches[0].Groups[1].Value
if ($instVer -ne $pubVer) { Fail "版本不一致：已装=$instVer，pubspec=$pubVer（APK 可能陈旧——去掉 -SkipBuild 重新构建）" }
else { Pass "已装版本与 pubspec 一致（$instVer）" }
if ($fail -gt 0) { exit 1 }

# ---- 4. 启动应用 ----
# 安装会 force-stop 旧进程；清 logcat + 冷启动，避免误判旧会话 UI/日志
& $adb -s $Device logcat -c 2>$null | Out-Null
& $adb -s $Device shell am force-stop $Package 2>$null | Out-Null
# 注：应用已在顶层运行时 am start 会输出 Warning（正常场景），stderr 丢弃避免中断
& $adb -s $Device shell am start -n "$Package/$Activity" 2>$null | Out-Null

# ---- 5. 进程存活检查（轮询 pidof，冷启动/重装后 12s 固定等待易误判）----
$procLine = $null
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 1
  $appPid = (& $adb -s $Device shell pidof $Package 2>$null).Trim()
  if ($appPid -match '^\d+') {
    $procLine = (& $adb -s $Device shell "ps -A | grep $Package" 2>$null)
    if ($procLine -match $Package) { break }
  }
}
if ($procLine -match $Package) { Pass "应用进程存活（$($procLine.Trim())）" }
else { Fail "应用进程未找到（启动失败或被杀死）" }

# ---- 6. 崩溃日志检查 ----
$crash = & $adb -s $Device logcat -d -t 300 2>&1 |
  Select-String "FATAL EXCEPTION|E/flutter|AndroidRuntime.*FATAL" | Select-Object -Last 5
if ($crash) { Fail "检测到崩溃日志：$($crash -join ' | ')" }
else { Pass "无崩溃日志（FATAL/E/flutter）" }

# ---- 7.（可选）UI 元素冒烟 ----
if ($CheckUI) {
  $remote = "/sdcard/ui_smoke.xml"
  $local = Join-Path $env:TEMP "ui_smoke_$Device.xml"
  # UTF-8 字节构造底栏标签，避免 .ps1 源文件编码导致匹配失败
  $uiTabLabels = @(
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE4,0xB9,0xA6,0xE6,0x9E,0xB6)),
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE5,0x8F,0x91,0xE7,0x8E,0xB0)),
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE8,0xAE,0xA2,0xE9,0x98,0x85)),
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE6,0x88,0x91,0xE7,0x9A,0x84))
  )
  $found = @()
  for ($uiTry = 0; $uiTry -lt 15; $uiTry++) {
    & $adb -s $Device shell uiautomator dump $remote 2>&1 | Out-Null
    & $adb -s $Device pull $remote $local 2>&1 | Out-Null
    $xmlText = [System.IO.File]::ReadAllText($local, [System.Text.Encoding]::UTF8)
    $found = $uiTabLabels | Where-Object { $xmlText -match [regex]::Escape($_) }
    if ($found.Count -ge 2) { break }
    Start-Sleep -Seconds 2
  }
  if ($found.Count -ge 2) { Pass "UI 主界面渲染正常（检测到：$($found -join '/')）" }
  else { Fail "UI 主界面元素未检出（检测到：$($found -join '/')）" }
}

# ---- 汇总 ----
Write-Host ""
Write-Host "================ 冒烟测试汇总 ================"
Write-Host "  通过: $pass   失败: $fail   设备: $Device"
if ($fail -gt 0) { Write-Host "结果: FAILED" -ForegroundColor Red; exit 1 }
Write-Host "结果: PASSED" -ForegroundColor Green
exit 0
