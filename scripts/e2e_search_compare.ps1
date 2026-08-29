# ============================================================
# 搜索 parity 双包复测辅助（5558 原版 + 重构）
# ============================================================
# 采集重构版 searchBooks 表统计；原版需 UI 人工记录顶条 origins。
#
# 用法:
#   .\scripts\e2e_search_compare.ps1 -Device emulator-5558 -Keyword "斗破苍穹"
#
# 输出: tmp_debug/e2e_5558/SEARCH_COMPARE_<timestamp>.md
# 编写者: Cursor Agent | 2026-08-27
# ============================================================
param(
  [string]$Device = "emulator-5558",
  [string]$Keyword = "斗破苍穹",
  [string]$KeywordFile = "",
  [string]$RefactorPkg = "io.legado.flutter_legado",
  [string]$OriginalPkg = "com.legado.app.release"
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

if ($KeywordFile -and (Test-Path $KeywordFile)) {
  $Keyword = (Get-Content -Path $KeywordFile -Raw -Encoding UTF8).Trim()
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repoRoot "tmp_debug\e2e_5558"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$adb = if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME "platform-tools\adb.exe" } else { "adb" }
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportFile = Join-Path $outDir ("SEARCH_COMPARE_{0}.md" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Get-DbStats([string]$pkg, [string]$bookName) {
  $remote = "/data/data/$pkg/databases/legado.db"
  $escaped = $bookName.Replace("'", "''")
  $sql = "SELECT COUNT(*), COUNT(DISTINCT origin) FROM searchBooks WHERE name='$escaped';"
  $raw = & $adb -s $Device shell "run-as $pkg sqlite3 $remote `"$sql`"" 2>$null
  if ($raw) {
    $parts = ($raw -join "").Trim() -split '\|'
    if ($parts.Count -ge 2) {
      return @{ rows = [int]$parts[0]; origins = [int]$parts[1] }
    }
  }
  return $null
}

$refStats = Get-DbStats $RefactorPkg $Keyword
$origStats = Get-DbStats $OriginalPkg $Keyword

$md = @"
# 搜索对比复测记录

- **时间**: $ts
- **设备**: $Device
- **关键词**: $Keyword

## 自动采集（searchBooks 表）

| 包 | 行数 | 去重 origin | 备注 |
|----|------|-------------|------|
| 重构 $RefactorPkg | $(if ($refStats) { $refStats.rows } else { 'N/A' }) | $(if ($refStats) { $refStats.origins } else { 'N/A' }) | run-as sqlite3 |
| 原版 $OriginalPkg | $(if ($origStats) { $origStats.rows } else { 'N/A' }) | $(if ($origStats) { $origStats.origins } else { 'N/A' }) | 若包名/库路径不同需手填 |

## 人工填写（快速书源 chip，搜索完成后）

| 指标 | 原版 | 重构 |
|------|------|------|
| total_count (x/y) | | |
| 顶条书名 | | |
| 顶条 origins 徽标 | | |
| 列表总行数 | | |
| 搜索墙钟(s) | | |

## 换源首屏（重构 forceRefresh=false）

| 指标 | 值 |
|------|-----|
| 首屏耗时(ms) | |
| 首屏条数 | |
| 是否全量 loading | |

## 操作步骤

1. 双包均选「快速书源」分组
2. 搜索「$Keyword」，等待进度完成或停搜
3. 记录顶条同源徽标与总行数
4. 点换源，记录首屏是否立即出列表
5. 重新运行本脚本更新 DB 统计

"@

Set-Content -Path $reportFile -Value $md -Encoding UTF8
Write-Host "复测记录模板: $reportFile"
if ($refStats) {
  Write-Host "重构 DB: rows=$($refStats.rows) origins=$($refStats.origins)"
}
