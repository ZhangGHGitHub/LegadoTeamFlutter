# ============================================================
# UI 对齐自动比对脚本（原版 Android app vs 重构版 Flutter app）
# ============================================================
# 用途：自动抓取两台应用当前界面的语义树（uiautomator dump），
#       归一化后输出结构化差异报告（缺失节点 / 顺序差异 / 坐标偏移），
#       把「人工逐个反馈 UI 差异」改为「一次跑出全部差异清单」。
#
# 用法：
#   .\scripts\ui_parity_compare.ps1 -Device emulator-5556
#   .\scripts\ui_parity_compare.ps1 -Device emulator-5556 -NavigateTo source_edit
#     （-NavigateTo 自动导航到指定界面：source_edit=发现页长按书山聚合→编辑）
#   .\scripts\ui_parity_compare.ps1 -DumpOnly -NavigateTo source_edit
#     （仅抓取两份 dump 到 tmp_debug/parity/，不对比，供人工复查）
#
# 输出：tmp_debug/parity/<screen>_diff.txt + 控制台摘要
# 退出码：0=无实质差异；1=存在差异（供 CI/自动化门禁）
# 编写者：DeepSeek Harness ｜ 2026-08-14
# ============================================================
param(
  [string]$Device = "emulator-5556",
  [string]$OriginalPkg = "com.legado.app.release",
  [string]$RefactorPkg = "io.legado.flutter_legado",
  [string]$NavigateTo = "",
  [switch]$DumpOnly,
  # 坐标差异阈值（像素）：小于该值视为一致
  [int]$PosThreshold = 24
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$adb = "D:\Android\platform-tools\adb.exe"
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) "tmp_debug\parity"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Invoke-Adb([string]$cmd) {
  # 简单命令按空格拆分逐参数传给 adb（本脚本命令均无引号参数）
  & $adb -s $Device ($cmd -split ' ') 2>$null
}

function Get-DumpXml([string]$tag, [int]$retry = 2) {
  for ($i = 0; $i -le $retry; $i++) {
    Invoke-Adb "shell uiautomator dump /sdcard/parity_$tag.xml" | Out-Null
    Start-Sleep -Milliseconds 800
    $xml = Invoke-Adb "shell cat /sdcard/parity_$tag.xml"
    if ($xml -and $xml.Length -gt 500 -and $xml -notmatch 'could not get') {
      return ($xml -join "`n")
    }
    Start-Sleep -Seconds 1
  }
  return ""
}

function Find-NodeCenter([string]$xml, [string]$text) {
  # 在语义树中查找包含指定文本的节点，返回其中心坐标（或 $null）
  foreach ($m in [regex]::Matches($xml, '(?:text|content-desc)="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
    if ($m.Groups[1].Value -match $text) {
      $x = ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2
      $y = ([int]$m.Groups[3].Value + [int]$m.Groups[5].Value) / 2
      return @($x, $y)
    }
  }
  return $null
}

function Invoke-TapByText([string]$xml, [string]$text, [int]$durationMs = 0) {
  $c = Find-NodeCenter $xml $text
  if ($null -eq $c) { return $false }
  if ($durationMs -gt 0) {
    Invoke-Adb "shell input swipe $([int]$c[0]) $([int]$c[1]) $([int]$c[0]) $([int]$c[1]) $durationMs" | Out-Null
  } else {
    Invoke-Adb "shell input tap $([int]$c[0]) $([int]$c[1])" | Out-Null
  }
  return $true
}

function Navigate-ToSourceEdit([string]$pkg) {
  # 发现页 → 长按「书山聚合」行 → 点「编辑」
  Invoke-Adb "shell am force-stop $pkg" | Out-Null
  Start-Sleep -Milliseconds 500
  Invoke-Adb "shell monkey -p $pkg -c android.intent.category.LAUNCHER 1" | Out-Null
  Start-Sleep -Seconds 10
  $xml = Get-DumpXml "nav"
  if (-not $xml) { Write-Host "  [!] dump 失败"; return $false }
  Write-Host "  启动后 dump: $($xml.Length) 字符"
  # 进入发现 Tab（底部导航：书架/发现/订阅/我的）
  if (-not (Invoke-TapByText $xml '发现')) {
    Write-Host "  [!] 未找到底部「发现」Tab"
    return $false
  }
  Start-Sleep -Seconds 5
  $xml = Get-DumpXml "nav"
  if (-not $xml) { return $false }
  Write-Host "  发现页 dump: $($xml.Length) 字符, 含书山聚合: $($xml -match '书山聚合')"
  # 书山聚合行可能被折叠/排序变化，滚动查找
  for ($i = 0; $i -lt 4; $i++) {
    if (Find-NodeCenter $xml '书山聚合') { break }
    Invoke-Adb "shell input swipe 360 900 360 300 300" | Out-Null
    Start-Sleep -Seconds 2
    $xml = Get-DumpXml "nav"
  }
  if (-not (Invoke-TapByText $xml '书山聚合' 1500)) {
    Write-Host "  [!] 未找到 书山聚合"; return $false
  }
  Start-Sleep -Seconds 3
  $menu = Get-DumpXml "menu"
  if (-not (Invoke-TapByText $menu '编辑')) {
    Write-Host "  [!] 未找到 编辑 菜单"; return $false
  }
  Start-Sleep -Seconds 4
  return $true
}

# ---- 归一化节点列表：text/content-desc → (text, x, y, w, h) ----
function Get-Nodes([string]$xml) {
  $nodes = @()
  foreach ($m in [regex]::Matches($xml, '(?:text|content-desc)="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
    $t = $m.Groups[1].Value.Trim()
    if ($t -eq '' -or $t -match '^(Tab \d|Dismiss|Collapsed|Expanded|Navigate up)$') { continue }
    # 去重：同文本相邻重复（TabLayout 内外层）只留一个
    $node = [PSCustomObject]@{
      Text = $t
      X = [int]$m.Groups[2].Value; Y = [int]$m.Groups[3].Value
      W = [int]$m.Groups[4].Value - [int]$m.Groups[2].Value
      H = [int]$m.Groups[5].Value - [int]$m.Groups[3].Value
    }
    $nodes += $node
  }
  # 保持顺序 + 去除紧邻重复
  $out = @()
  $prev = $null
  foreach ($n in $nodes) {
    if ($prev -and $n.Text -eq $prev.Text -and [Math]::Abs($n.Y - $prev.Y) -lt 6) { continue }
    $out += $n
    $prev = $n
  }
  return $out
}

# ============================================================
$screenName = if ($NavigateTo) { $NavigateTo } else { "current" }
Write-Host "=== UI 对齐自动比对 ==="
Write-Host "设备: $Device  界面: $screenName"

if ($NavigateTo) {
  Write-Host "--- 导航: 原版 $OriginalPkg ---"
  Navigate-ToSourceEdit $OriginalPkg | Out-Null
  Start-Sleep -Seconds 1
  Write-Host "--- 导航: 重构版 $RefactorPkg ---"
  Navigate-ToSourceEdit $RefactorPkg | Out-Null
}

$origXml = Get-DumpXml "orig"
$refXml = Get-DumpXml "ref"
if (-not $origXml) { Write-Host "[!] 原版 dump 失败"; exit 1 }
if (-not $refXml) { Write-Host "[!] 重构版 dump 失败"; exit 1 }

Set-Content -Path (Join-Path $outDir "${screenName}_orig.xml") -Value $origXml -Encoding UTF8
Set-Content -Path (Join-Path $outDir "${screenName}_ref.xml") -Value $refXml -Encoding UTF8

if ($DumpOnly) {
  Write-Host "[DumpOnly] 已保存两份 dump：$outDir\${screenName}_orig.xml / _ref.xml"
  exit 0
}

$orig = Get-Nodes $origXml
$ref = Get-Nodes $refXml
Write-Host "原版节点数: $($orig.Count)  重构版节点数: $($ref.Count)"

$lines = @()
$hasDiff = $false

# 1) 文本序列对比（原版有、重构缺 / 重构有、原版无 / 顺序错位）
$origTexts = @($orig | ForEach-Object { $_.Text })
$refTexts = @($ref | ForEach-Object { $_.Text })
$missing = @($origTexts | Where-Object { $_ -notin $refTexts })
$extra = @($refTexts | Where-Object { $_ -notin $origTexts })

if ($missing.Count -gt 0) {
  $hasDiff = $true
  $lines += "【缺失（原版有、重构版无）】"
  foreach ($t in $missing) { $lines += "  - $t" }
  Write-Host "缺失: $($missing -join ' | ')"
}
if ($extra.Count -gt 0) {
  $hasDiff = $true
  $lines += "【多余（重构版有、原版无）】"
  foreach ($t in $extra) { $lines += "  - $t" }
  Write-Host "多余: $($extra -join ' | ')"
}

# 2) 顺序对比（相对顺序不同）
if (-not $hasDiff -and $origTexts.Count -gt 2) {
  $refOnly = @($refTexts | Where-Object { $_ -in $origTexts })
  $refIndex = @{}
  for ($i = 0; $i -lt $refOnly.Count; $i++) { $refIndex[$refOnly[$i]] = $i }
  $lastIdx = -1
  foreach ($t in $origTexts) {
    if ($refIndex.ContainsKey($t)) {
      if ($refIndex[$t] -lt $lastIdx) {
        $hasDiff = $true
        $lines += "【顺序差异】'$t' 在重构版中顺序靠前"
        break
      }
      $lastIdx = $refIndex[$t]
    }
  }
}

# 3) 坐标偏移对比（同文本节点位置差异 > 阈值）
# 忽略内容驱动的装饰元素（工具提示图标等，其纵向位置随字段内容行数变化）
$ignorePos = @('代码编辑', '全屏编辑', '调试源', '更多选项')
$posLines = @()
foreach ($o in $orig) {
  if ($ignorePos -contains $o.Text) { continue }
  $r = $ref | Where-Object { $_.Text -eq $o.Text } | Select-Object -First 1
  if ($null -eq $r) { continue }
  $dx = [Math]::Abs($o.X - $r.X)
  $dy = [Math]::Abs($o.Y - $r.Y)
  if ($dx -gt $PosThreshold -or $dy -gt $PosThreshold) {
    $posLines += "  - '$($o.Text)': 原版($($o.X),$($o.Y)) vs 重构($($r.X),$($r.Y)) [Δ($dx,$dy)]"
  }
}
if ($posLines.Count -gt 0) {
  $hasDiff = $true
  $lines += "【坐标偏移 > ${PosThreshold}px】"
  $lines += $posLines
  Write-Host "坐标偏移: $($posLines.Count) 处"
}

$reportPath = Join-Path $outDir "${screenName}_diff.txt"
$lines | Set-Content -Path $reportPath -Encoding UTF8

Write-Host ""
Write-Host "================ 差异报告 ================"
if (-not $hasDiff) {
  Write-Host "未发现实质差异（文本/顺序/坐标均一致）。"
} else {
  $lines | ForEach-Object { Write-Host $_ }
  Write-Host "完整报告: $reportPath"
}
Write-Host "结果: $(if ($hasDiff) { 'DIFF' } else { 'MATCH' })"
exit $(if ($hasDiff) { 1 } else { 0 })
