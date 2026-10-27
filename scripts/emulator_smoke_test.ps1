# ⚠ 编码：本文件必须保持 UTF-8 with BOM（Windows PowerShell 5.1 按 GBK 解码无 BOM .ps1，中文注释会解析失败）`r`n# ============================================================
# 模拟器冒烟测试脚本（Legado Flutter 轨）
# 流程：构建 debug APK → 安装到指定模拟器 → 启动应用 →
#       进程存活检查 → 崩溃日志检查 →（可选）UI 元素冒烟
#       （-CheckUI 时先自动关闭「上次运行发生崩溃」弹窗再断言，防历史
#        崩溃存根遮蔽主界面语义）
# 用法示例：
#   .\scripts\emulator_smoke_test.ps1                      # 默认 emulator-5556
#   .\scripts\emulator_smoke_test.ps1 -Device emulator-5558   # 用户验收机
#   .\scripts\emulator_smoke_test.ps1 -SkipBuild              # 复用已有 APK
#   .\scripts\emulator_smoke_test.ps1 -CheckUI                 # 追加 UI 元素检查（自动关崩溃弹窗）
#   .\scripts\emulator_smoke_test.ps1 -CheckPlayback           # 追加听书前台服务检查
#   .\scripts\emulator_smoke_test.ps1 -DisplayId 0             # 多屏：显式指定逻辑 display（默认自动探测）
# 退出码：0=通过；1=失败（可用于 CI/子代理验收门禁）。失败来源：
#   设备离线 / APK 构建失败 / 安装失败 / 已装版本与 pubspec 不一致 /
#   进程未存活 / 崩溃日志命中 / 历史崩溃弹窗无法关闭 / UI 元素未检出 /
#   听书前台服务检查失败
# 编写者：Reasonix ｜ 2026-08-10
# ============================================================
param(
  [string]$Device = "emulator-5556",
  [switch]$SkipBuild,
  [switch]$CheckUI,
  [switch]$CheckPlayback,
  # 多屏逻辑 display id（批23b）：-1=自动探测应用窗口所在 display，>=0 显式
  # 指定。模拟器（如 MuMu）可能把应用窗口挂在独立逻辑 display 上，input 默认
  # 发往 display 0 会点不中；该 id 在 force-stop 后可能变化，自动模式在每次
  # 点击前重新探测（探测失败回落 0）。
  [int]$DisplayId = -1,
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

# ---- UI dump / 历史崩溃弹窗处理（批23，批23b 加固）----
# 背景：应用若上次崩溃，冷启动会弹出「上次运行发生崩溃」模态框
# （CrashLogDialog / showDialog barrierDismissible=false）。弹窗会覆盖主界面，
# 使 -CheckUI 的底栏语义文本被遮蔽（uiautomator dump 读不到或点不中），
# 造成「UI 未渲染」的假失败。处理：UI 断言前先 dump，命中弹窗文案即点
# 「确定」（其 onPressed 会清除 crash_log 存根，避免下次启动重复弹）；
# 找不到「确定」节点时退回系统返回键（能关窗但不清存根）。
# 批23b：① 识别收紧为「标题」或（「崩溃时间」且存在「确定」）；② 关闭只
# 尝试一次，失败立即 Fail 并注明不再重试；③ 点击带 -d 逻辑 display（多屏）；
# ④ 中文字面量统一由 UTF-8 字节构造并做启动自检。
$UiRemotePath = "/sdcard/ui_smoke.xml"
$UiLocalPath = Join-Path $env:TEMP ("ui_smoke_" + ($Device -replace '[^\w\.-]', '_') + ".xml")

function Decode-Utf8([int[]]$Bytes) {
  return [System.Text.Encoding]::UTF8.GetString([byte[]]$Bytes)
}

# 中文常量：UTF-8 字节构造，避免 .ps1 编码被改写（GBK / 无 BOM）后静默失配
$CrashTitleText = Decode-Utf8 @(
  0xE4,0xB8,0x8A,0xE6,0xAC,0xA1,0xE8,0xBF,0x90,0xE8,0xA1,0x8C,
  0xE5,0x8F,0x91,0xE7,0x94,0x9F,0xE5,0xB4,0xA9,0xE6,0xBA,0x83
)
$CrashTimeText = Decode-Utf8 @(0xE5,0xB4,0xA9,0xE6,0xBA,0x83,0xE6,0x97,0xB6,0xE9,0x97,0xB4)
$ConfirmText = Decode-Utf8 @(0xE7,0xA1,0xAE,0xE5,0xAE,0x9A)
# 启动自检：长度不符说明源码编码/字节常量已损坏，直接失败而非静默跳过弹窗
if ($CrashTitleText.Length -ne 8 -or $CrashTimeText.Length -ne 4 -or $ConfirmText.Length -ne 2) {
  Write-Host "[FAIL] 中文常量自检失败（脚本必须保持 UTF-8 with BOM）" -ForegroundColor Red
  exit 1
}
$script:crashDismissFailed = $false

function Get-UiDump {
  # 部分 ROM 的 uiautomator 写完转储即自杀（输出噪声/退出码非 0），
  # 以本地文件是否含 <hierarchy 为准，失败重试一次。
  for ($i = 0; $i -lt 2; $i++) {
    # 先清设备/本地旧转储，防 pull 失败时读到上一轮的 stale XML（假阳性）
    & $adb -s $Device shell rm -f $UiRemotePath 2>&1 | Out-Null
    if (Test-Path $UiLocalPath) { Remove-Item $UiLocalPath -Force -ErrorAction SilentlyContinue }
    & $adb -s $Device shell uiautomator dump $UiRemotePath 2>&1 | Out-Null
    & $adb -s $Device pull $UiRemotePath $UiLocalPath 2>&1 | Out-Null
    if (Test-Path $UiLocalPath) {
      $text = [System.IO.File]::ReadAllText($UiLocalPath, [System.Text.Encoding]::UTF8)
      if ($text -match '<hierarchy') { return $text }
    }
    Start-Sleep -Milliseconds 500
  }
  return ""
}

function Test-CrashDialogXml([string]$xml) {
  # 收紧识别（批23b）：标题命中；或「崩溃时间」与「确定」按钮同时存在。
  # 仅出现「崩溃时间」而无「确定」的页面（如日志查看/详情页）不再误判。
  if ($xml -match [regex]::Escape($CrashTitleText)) { return $true }
  return (($xml -match [regex]::Escape($CrashTimeText)) -and
    ($xml -match [regex]::Escape($ConfirmText)))
}

# 多屏（批23b）：应用窗口所在逻辑 display。显式 -DisplayId 优先；自动模式
# 解析 `dumpsys window windows` 的 Display 段，探测失败回落 0（保持原行为）。
function Resolve-DisplayId {
  if ($DisplayId -ge 0) { return $DisplayId }
  $dump = & $adb -s $Device shell dumpsys window windows 2>$null
  $current = 0
  foreach ($line in $dump) {
    if ($line -match 'mDisplayId=(\d+)') { $current = [int]$Matches[1] }
    elseif ($line -match [regex]::Escape($Package)) { return $current }
  }
  return 0
}

function Close-CrashDialogOnce {
  # 返回值：$true=当前存在崩溃弹窗（已尝试关闭或此前已失败）；$false=无弹窗
  if ($script:crashDismissFailed) { return $true }  # 失败后不再重试/重复计数
  $xml = Get-UiDump
  if (-not (Test-CrashDialogXml $xml)) { return $false }
  Write-Host "==> 检测到历史崩溃弹窗，尝试关闭 ..."
  $tap = $null
  foreach ($m in [regex]::Matches($xml, '<node\b[^>]*>')) {
    $tag = $m.Value
    $hasText = $tag.Contains('text="' + $ConfirmText + '"')
    $hasDesc = $tag.Contains('content-desc="' + $ConfirmText + '"')
    if (-not $hasText -and -not $hasDesc) { continue }
    if ($tag -match 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
      $x = [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
      $y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
      $tap = @($x, $y)
      break
    }
  }
  if ($tap) {
    $targetDisplay = Resolve-DisplayId
    Write-Host "==> 点击 display $targetDisplay ($($tap[0]),$($tap[1]))"
    & $adb -s $Device shell input -d $targetDisplay tap $tap[0] $tap[1] 2>&1 | Out-Null
  } else {
    & $adb -s $Device shell input keyevent KEYCODE_BACK 2>&1 | Out-Null
  }
  Start-Sleep -Seconds 2
  if (Test-CrashDialogXml (Get-UiDump)) {
    # 单次关闭失败即 Fail：不重试、不重复计数（避免轮询循环刷多条 Fail）
    $script:crashDismissFailed = $true
    Fail "历史崩溃弹窗关闭失败（仅尝试一次，不再重试；UI 断言可能被遮蔽）"
  } else {
    Pass "历史崩溃弹窗已关闭（不再遮蔽 UI 断言）"
  }
  return $true
}

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
  # [FIX 2026-09-19] pidof 无进程时输出为空，直接 .Trim() 会抛 InvalidOperation（非致命但污染日志）：
  # 先 -join '' 归一为字符串再 Trim，保持后续 -match 判空与自恢复语义不变
  $appPid = ((& $adb -s $Device shell pidof $Package 2>$null) -join '').Trim()
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
  # UTF-8 字节构造底栏标签，避免 .ps1 源文件编码导致匹配失败
  $uiTabLabels = @(
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE4,0xB9,0xA6,0xE6,0x9E,0xB6)),
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE5,0x8F,0x91,0xE7,0x8E,0xB0)),
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE8,0xAE,0xA2,0xE9,0x98,0x85)),
    [System.Text.Encoding]::UTF8.GetString([byte[]](0xE6,0x88,0x91,0xE7,0x9A,0x84))
  )
  # 批23：断言前先关历史崩溃弹窗（弹窗在闪屏退出后才出，最多观察 3 轮）
  $dismissed = $false
  for ($cdTry = 0; $cdTry -lt 3; $cdTry++) {
    if (Close-CrashDialogOnce) { $dismissed = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $dismissed) { Write-Host "==> 未检测到历史崩溃弹窗" }

  $found = @()
  for ($uiTry = 0; $uiTry -lt 15; $uiTry++) {
    # 弹窗也可能在轮询期间才出现：每轮先兜底关闭，关闭后重查语义树
    if (Close-CrashDialogOnce) {
      # 单次关闭失败已 Fail：立即结束 UI 断言，不再空转/重复计数
      if ($script:crashDismissFailed) { break }
      Start-Sleep -Seconds 1
      continue
    }
    $xmlText = Get-UiDump
    $found = $uiTabLabels | Where-Object { $xmlText -match [regex]::Escape($_) }
    if ($found.Count -ge 2) { break }
    Start-Sleep -Seconds 2
  }
  if ($found.Count -ge 2) { Pass "UI 主界面渲染正常（检测到：$($found -join '/')）" }
  else { Fail "UI 主界面元素未检出（检测到：$($found -join '/')）" }
}

# ---- 7.5（可选）听书前台服务检查（体检 N1：虚假闭环教训）----
# 说明：真机听书全链路（TTS 合成、退后台 60s 续播）仍需人工验收；本步骤自动化
# 防回归 N1 的崩溃机制——startForegroundService 指向未注册组件播放即崩：
#   ① am start-foreground-service 直接拉起（未注册会抛 IllegalStateException）；
#   ② dumpsys activity services 确认 ServiceRecord；③ ≥10s 后进程存活且无
#   FATAL；④ HOME 退后台 5s 再查；⑤ am stopservice 清理
# 注：本 ROM 的 dumpsys package 不枚举 manifest 声明，注册与否以"能否成功启动"
# 为准（功能等价判定）
if ($CheckPlayback) {
  $svc = "$Package/io.legado.flutter.PlaybackForegroundService"
  & $adb -s $Device shell am start-foreground-service -n $svc --es state playing 2>&1 | Out-Null
  Start-Sleep -Seconds 10
  $svcCrash = & $adb -s $Device logcat -d -t 200 2>&1 |
    Select-String "IllegalStateException|FATAL EXCEPTION|E/flutter" | Select-Object -Last 3
  $svcPid = (& $adb -s $Device shell pidof $Package 2>$null).Trim()
  $svcRec = & $adb -s $Device shell "dumpsys activity services $Package" 2>$null |
    Select-String "PlaybackForegroundService" | Select-Object -First 1
  if ($svcCrash -or -not ($svcPid -match '^\d+') -or -not $svcRec) {
    Fail "听书前台服务启动失败/未注册（IllegalStateException=N1 回归）：$($svcCrash -join ' | ')"
  } else {
    & $adb -s $Device shell input keyevent KEYCODE_HOME 2>$null | Out-Null
    Start-Sleep -Seconds 5
    $bgPid = (& $adb -s $Device shell pidof $Package 2>$null).Trim()
    if ($bgPid -match '^\d+') { Pass "前台服务已注册可启动 + 退后台 5s 存活（播放链路冒烟）" }
    else { Fail "前台服务运行中退后台进程被杀" }
  }
  & $adb -s $Device shell am stopservice -n $svc 2>&1 | Out-Null
}

# ---- 汇总 ----
Write-Host ""
Write-Host "================ 冒烟测试汇总 ================"
Write-Host "  通过: $pass   失败: $fail   设备: $Device"
if ($fail -gt 0) { Write-Host "结果: FAILED" -ForegroundColor Red; exit 1 }
Write-Host "结果: PASSED" -ForegroundColor Green
exit 0
