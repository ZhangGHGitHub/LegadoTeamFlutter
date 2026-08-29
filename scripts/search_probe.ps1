# ⚠ 编码：本文件必须保持 UTF-8 with BOM
# ============================================================
# 搜索探针：按书源统计搜索成功/空/失败分类（真实网络）
# ============================================================
param(
  [string]$Keyword = "",
  [string]$KeywordFile = "",
  [string]$Group = "",
  [string]$DbPath = "",
  [string]$Device = "",
  [int]$MaxSources = 0
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$rustDir = Join-Path $repoRoot "rust"
$outDir = Join-Path $repoRoot "tmp_debug\search_probe"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if ($KeywordFile -and (Test-Path $KeywordFile)) {
  $Keyword = (Get-Content -Path $KeywordFile -Raw -Encoding UTF8).Trim()
}
if (-not $Keyword) {
  Write-Error "请指定 -Keyword 或 -KeywordFile"
}

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $outDir "${ts}_report.json"
$urlsJsonPath = Join-Path $outDir "${ts}_urls.json"
$queryFile = Join-Path $outDir "${ts}_query.txt"
[System.IO.File]::WriteAllText($queryFile, $Keyword, [System.Text.UTF8Encoding]::new($false))

if (-not $DbPath -and $Device) {
  $adbCandidates = @(
    (Join-Path $env:ANDROID_HOME "platform-tools\adb.exe"),
    "D:\Android\platform-tools\adb.exe",
    "adb"
  )
  $adb = $adbCandidates | Where-Object { $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
  if (-not $adb) { $adb = "adb" }
  $pkg = "io.legado.flutter_legado"
  $remoteDb = "/data/data/$pkg/databases/legado.db"
  $localDb = Join-Path $outDir "${ts}_legado.db"
  & $adb -s $Device shell "run-as $pkg cat $remoteDb" | Set-Content -Path $localDb -Encoding Byte
  if ((Get-Item $localDb -ErrorAction SilentlyContinue).Length -gt 1000) {
    $DbPath = $localDb
    Write-Host "[probe] 已从 $Device 拉取 DB"
  }
}

if (-not $DbPath -or -not (Test-Path $DbPath)) {
  Write-Error "需要有效 -DbPath"
}

$sourceUrlsJson = '[]'
if ($Group -or $MaxSources -gt 0) {
  $pyFile = Join-Path $PSScriptRoot "search_probe_filter.py"
  $limitArg = if ($MaxSources -gt 0) { $MaxSources } else { 0 }
  $cnt = python $pyFile $DbPath $Group $urlsJsonPath $limitArg
  Write-Host "[probe] 书源数: $cnt"
}

Write-Host "[probe] 关键词: $Keyword"
Write-Host "[probe] 报告: $reportPath"

Push-Location $rustDir
try {
  $probeArgs = @(
    "run", "--release", "--example", "scan_search_sources", "--",
    $DbPath, "@$queryFile", $reportPath
  )
  if (($Group -or $MaxSources -gt 0) -and (Test-Path $urlsJsonPath)) {
    $probeArgs += $urlsJsonPath
  }
  cargo @probeArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}

if (Test-Path $reportPath) {
  $j = Get-Content $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Host "===== 探针完成 ====="
  $j.summary | Format-List
}
