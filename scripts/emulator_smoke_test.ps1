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
  [string]$FlutterDir = "D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado",
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
if ($SkipBuild) {
  if (-not (Test-Path $apk)) { Fail "跳过构建但 APK 不存在：$apk"; exit 1 }
  Pass "跳过构建，复用已有 APK"
} else {
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

# ---- 4. 启动应用 ----
# 注：应用已在顶层运行时 am start 会输出 Warning（正常场景），stderr 丢弃避免中断
& $adb -s $Device shell am start -n "$Package/$Activity" 2>$null | Out-Null
Start-Sleep -Seconds 12

# ---- 5. 进程存活检查 ----
$proc = & $adb -s $Device shell "ps -A | grep $Package"
if ($proc -match $Package) { Pass "应用进程存活（$($proc.Trim())）" }
else { Fail "应用进程未找到（启动失败或被杀死）" }

# ---- 6. 崩溃日志检查 ----
$crash = & $adb -s $Device logcat -d -t 300 2>&1 |
  Select-String "FATAL EXCEPTION|E/flutter|AndroidRuntime.*FATAL" | Select-Object -Last 5
if ($crash) { Fail "检测到崩溃日志：$($crash -join ' | ')" }
else { Pass "无崩溃日志（FATAL/E/flutter）" }

# ---- 7.（可选）UI 元素冒烟 ----
if ($CheckUI) {
  $remote = "/sdcard/ui_smoke.xml"
  & $adb -s $Device shell uiautomator dump $remote 2>&1 | Out-Null
  # 注：用 pull 二进制传输 + 显式 UTF-8 读取，避免 PowerShell 5.1 管道
  # 对 adb 输出的 ANSI 解码导致中文 content-desc 乱码
  $local = Join-Path $env:TEMP "ui_smoke_$Device.xml"
  & $adb -s $Device pull $remote $local 2>&1 | Out-Null
  $xmlText = Get-Content $local -Raw -Encoding UTF8
  $found = @("书架", "发现", "订阅", "我的") | Where-Object { $xmlText -match [regex]::Escape($_) }
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
