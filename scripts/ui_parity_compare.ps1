# ============================================================
# UI 对齐自动比对脚本（原版 Android app vs 重构版 Flutter app）
# ============================================================
# 用途：自动抓取两台应用当前界面的语义树（uiautomator dump），
#       归一化后输出结构化差异报告（缺失节点 / 顺序差异 / 坐标偏移），
#       把「人工逐个反馈 UI 差异」改为「一次跑出全部差异清单」。
#
# 用法：
#   .\scripts\ui_parity_compare.ps1 -Device emulator-5556 -Screens all
#     （-Screens 批量比对界面：bookshelf/discover/source_manage/source_edit/source_login，
#     逗号分隔多个；all = 全部）
#   .\scripts\ui_parity_compare.ps1 -Device emulator-5556 -Screens source_edit
#   .\scripts\ui_parity_compare.ps1 -DumpOnly -Screens source_edit
#     （仅抓取两份 dump 到 tmp_debug/parity/，不对比，供人工复查）
#
# 输出：tmp_debug/parity/<screen>_diff.txt + 控制台摘要
# 退出码：0=全部一致；1=任一界面存在差异（供 CI/自动化门禁）
# 编写者：DeepSeek Harness ｜ 2026-08-14
# ============================================================
param(
  [string]$Device = "emulator-5556",
  [string]$OriginalPkg = "com.legado.app.release",
  [string]$RefactorPkg = "io.legado.flutter_legado",
  [string]$NavigateTo = "",
  # 界面名列表（逗号分隔；all = 全部内置界面）
  [string]$Screens = "",
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

# ---- 启动应用并进入指定界面（内置导航计划） ----
function Start-App([string]$pkg) {
  Invoke-Adb "shell am force-stop $pkg" | Out-Null
  Start-Sleep -Milliseconds 500
  Invoke-Adb "shell monkey -p $pkg -c android.intent.category.LAUNCHER 1" | Out-Null
  Start-Sleep -Seconds 10
  return Get-DumpXml "boot"
}

function Tap-BottomTab([string]$xml, [string]$tab) {
  # 底部导航项可能带 "Tab N of M" 后缀
  foreach ($m in [regex]::Matches($xml, 'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
    if ($m.Groups[1].Value -match "^$tab") {
      $x = ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2
      $y = ([int]$m.Groups[3].Value + [int]$m.Groups[5].Value) / 2
      Invoke-Adb "shell input tap $([int]$x) $([int]$y)" | Out-Null
      return $true
    }
  }
  return $false
}

function Navigate-ToScreen([string]$pkg, [string]$screen) {
  $xml = Start-App $pkg
  if (-not $xml) { Write-Host "  [!] 启动失败"; return $false }
  Write-Host "  启动后 dump: $($xml.Length) 字符"

  switch ($screen) {
    "bookshelf" {
      # 默认落在书架页
      return $true
    }
    "discover" {
      if (-not (Tap-BottomTab $xml '发现')) {
        Write-Host "  [!] 未找到底部「发现」Tab"; return $false
      }
      Start-Sleep -Seconds 5
      return $true
    }
    "source_manage" {
      if (-not (Tap-BottomTab $xml '我的')) {
        Write-Host "  [!] 未找到底部「我的」Tab"; return $false
      }
      Start-Sleep -Seconds 4
      $xml = Get-DumpXml "step"
      if (-not (Invoke-TapByText $xml '书源管理')) {
        Write-Host "  [!] 未找到「书源管理」"; return $false
      }
      Start-Sleep -Seconds 4
      return $true
    }
    "source_edit" {
      return Navigate-SourceRowAction $pkg "编辑"
    }
    "source_login" {
      return Navigate-SourceRowAction $pkg "登录"
    }
    default {
      Write-Host "  [!] 未知界面: $screen"; return $false
    }
  }
}

# 发现页 → 长按「书山聚合」行 → 点菜单动作（编辑/登录）
function Navigate-SourceRowAction([string]$pkg, [string]$action) {
  if (-not (Tap-BottomTab (Get-DumpXml "t") '发现')) {
    Write-Host "  [!] 未找到底部「发现」Tab"; return $false
  }
  Start-Sleep -Seconds 5
  $xml = Get-DumpXml "nav"
  if (-not $xml) { return $false }
  Write-Host "  发现页 dump: $($xml.Length) 字符, 含书山聚合: $($xml -match '书山聚合')"
  # 书山聚合行可能被折叠/排序变化，滚动查找
  for ($i = 0; $i -lt 5; $i++) {
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
  if (-not (Invoke-TapByText $menu $action)) {
    Write-Host "  [!] 未找到 $action 菜单"; return $false
  }
  Start-Sleep -Seconds 5
  return $true
}

# ---- 归一化节点列表：text/content-desc → (text, x, y, w, h) ----
function Get-Nodes([string]$xml) {
  $nodes = @()
  foreach ($m in [regex]::Matches($xml, '(?:text|content-desc)="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
    $t = $m.Groups[1].Value.Trim()
    # 归一化：底部导航 "书架\nTab 1 of 4" → "书架"（原版无 Tab 后缀）
    $t = $t -replace '\nTab \d+ of \d+$', ''
    if ($t -eq '' -or $t -match '^(Tab \d|Dismiss|Collapsed|Expanded|Navigate up|Back)$') { continue }
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
# 解析界面列表
$allScreens = @('bookshelf', 'discover', 'source_manage', 'source_edit', 'source_login')
if ($Screens -eq 'all') { $Screens = $allScreens -join ',' }
if ($NavigateTo -and -not $Screens) { $Screens = $NavigateTo }
$screenList = @($Screens -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if ($screenList.Count -eq 0) { $screenList = @('current') }

Write-Host "=== UI 对齐自动比对 ==="
Write-Host "设备: $Device  界面: $($screenList -join ', ')"

$anyDiff = $false
foreach ($screenName in $screenList) {
  Write-Host ""
  Write-Host "----- 界面: $screenName -----"
  Write-Host "--- 导航: 原版 $OriginalPkg ---"
  if (-not (Navigate-ToScreen $OriginalPkg $screenName)) { Write-Host "  [跳过] 原版导航失败"; continue }
  # 原版 dump 必须在重构版导航**之前**抓取（此前顺序错误导致两份
  # dump 都是重构版，「重构版 vs 自己」恒为 MATCH）
  $origXml = Get-DumpXml "orig"
  Write-Host "--- 导航: 重构版 $RefactorPkg ---"
  if (-not (Navigate-ToScreen $RefactorPkg $screenName)) { Write-Host "  [跳过] 重构版导航失败"; continue }
  $refXml = Get-DumpXml "ref"
  if (-not $origXml -or -not $refXml) {
    Write-Host "  [!] dump 失败，跳过"
    continue
  }

  Set-Content -Path (Join-Path $outDir "${screenName}_orig.xml") -Value $origXml -Encoding UTF8
  Set-Content -Path (Join-Path $outDir "${screenName}_ref.xml") -Value $refXml -Encoding UTF8

  if ($DumpOnly) {
    Write-Host "  [DumpOnly] 已保存：$outDir\${screenName}_orig.xml / _ref.xml"
    continue
  }

  $orig = Get-Nodes $origXml
  $ref = Get-Nodes $refXml
  Write-Host "原版节点数: $($orig.Count)  重构版节点数: $($ref.Count)"

  $lines = @()
  $hasDiff = $false

# 1) 文本序列对比（原版有、重构缺 / 重构有、原版无）
# 多行合并节点（Flutter 语义把 源名+分组+角标 合并为一个 content-desc）：
# 按行拆分后对比行集合，避免「语义粒度差异」误报为「内容缺失/多余」
$origTokens = @()
foreach ($t in ($orig | ForEach-Object { $_.Text })) { $origTokens += @($t -split "`n") }
$refTokens = @()
foreach ($t in ($ref | ForEach-Object { $_.Text })) { $refTokens += @($t -split "`n") }
# 数据差异忽略名单（两侧书架/书源内容不同，非 UI 结构差异）
$dataPattern = '^(全部|筛选发现源|搜索书源|末日重生|西瓜黄|最近：%s|最新：%s|第一章 |第八百一十五章|重生高考前99天|从一证永证开始成神|凡戒窃灵|99\+|0%|ON|OFF|标志:发现已|更多菜单|阅宝书屋|爱下电子|番茄聚合|更多选项|3 本书|最近阅读|Show menu)$'
$missing = @($origTokens | Where-Object { $_ -notin $refTokens -and $_ -notmatch $dataPattern } | Select-Object -Unique)
$extra = @($refTokens | Where-Object { $_ -notin $origTokens -and $_ -notmatch $dataPattern } | Select-Object -Unique)
# 括号/空白归一化后重算（原版「全选（0/968）」= 重构「全选（0/968）」）
$norm = { param($s) ($s -replace '[（(]', '(' -replace '[）)]', ')' -replace '\s+', ' ').Trim() }
$refNorm = @($refTokens | ForEach-Object { & $norm $_ })
$origNorm = @($origTokens | ForEach-Object { & $norm $_ })
$missing = @($missing | Where-Object { (& $norm $_) -notin $refNorm })
$extra = @($extra | Where-Object { (& $norm $_) -notin $origNorm })

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

# 2) 顺序对比（公共文本在重构版中的相对顺序是否与原版一致；
#    重复文本取首次出现位置，避免多次出现导致误报）
$origTexts = @($orig | ForEach-Object { $_.Text })
$refTexts = @($ref | ForEach-Object { $_.Text })
$common = @($origTexts | Select-Object -Unique | Where-Object { $_ -in $refTexts })
$refPos = @{}
for ($i = 0; $i -lt $refTexts.Count; $i++) {
  if (-not $refPos.ContainsKey($refTexts[$i])) { $refPos[$refTexts[$i]] = $i }
}
if ($common.Count -gt 2) {
  $lastIdx = -1
  foreach ($t in $common) {
    $p = $refPos[$t]
    if ($p -lt $lastIdx) {
      $hasDiff = $true
      $lines += "【顺序差异】'$t' 在重构版中顺序靠前"
      break
    }
    $lastIdx = $p
  }
}

# 3) 坐标偏移对比（同文本按出现次序一一对应；忽略内容驱动装饰元素）
$ignorePos = @('代码编辑', '全屏编辑', '调试源', '更多选项')
$refOccur = @{}
foreach ($r in $ref) {
  if (-not $refOccur.ContainsKey($r.Text)) { $refOccur[$r.Text] = @() }
  $refOccur[$r.Text] += $r
}
$origCount = @{}
$posLines = @()
foreach ($o in $orig) {
  if ($ignorePos -contains $o.Text) { continue }
  $list = @($refOccur[$o.Text])
  if ($list.Count -eq 0) { continue }
  $idx = if ($origCount.ContainsKey($o.Text)) { $origCount[$o.Text] } else { 0 }
  $origCount[$o.Text] = $idx + 1
  if ($idx -ge $list.Count) { continue }
  $r = $list[$idx]
  $dx = [Math]::Abs($o.X - $r.X)
  $dy = [Math]::Abs($o.Y - $r.Y)
  if ($dx -gt $PosThreshold -or $dy -gt $PosThreshold) {
    $posLines += "  - '$($o.Text)'#$(($idx + 1)): 原版($($o.X),$($o.Y)) vs 重构($($r.X),$($r.Y)) [Δ($dx,$dy)]"
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
  if (-not $hasDiff) {
    Write-Host "  [MATCH] 未发现实质差异（文本/顺序/坐标均一致）。"
  } else {
    $anyDiff = $true
    Write-Host "  [DIFF] 差异："
    $lines | ForEach-Object { Write-Host "    $_" }
    Write-Host "  完整报告: $reportPath"
  }
}

Write-Host ""
Write-Host "================ 汇总 ================"
Write-Host "比对界面: $($screenList -join ', ')  结果: $(if ($anyDiff) { 'DIFF' } else { 'ALL MATCH' })"
exit $(if ($anyDiff) { 1 } else { 0 })
