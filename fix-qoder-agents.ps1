# fix-qoder-agents.ps1
# 监控 .qoder/agents/builtin/ 目录，自动修复 Qoder 与 QoderCN 同时使用导致的两类冲突：
#   1. 重复 frontmatter（两个程序各写一段）
#   2. 自定义模型 ID 不互通（custom:model_xxx 只在注册它的应用内有效）
#
# 用法: 在项目根目录打开终端，运行 powershell -ExecutionPolicy Bypass -File .\fix-qoder-agents.ps1
# 按 Ctrl+C 停止。

$watchDir = Join-Path $PSScriptRoot ".qoder\agents\builtin"

if (-not (Test-Path $watchDir)) {
    Write-Host "[ERROR] 目录不存在: $watchDir" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] 正在监控: $watchDir" -ForegroundColor Cyan
Write-Host "[INFO] 按 Ctrl+C 停止" -ForegroundColor Gray

function Repair-File {
    param([string]$FilePath)

    $content = Get-Content $FilePath -Raw -Encoding UTF8
    if ($null -eq $content) { return }

    $needFix = $false

    # --- 检测问题 1: 多段 frontmatter ---
    $dashMatches = [regex]::Matches($content, '(?m)^---\s*$')
    if ($dashMatches.Count -gt 2) {
        $needFix = $true
    }

    # --- 检测问题 2: 自定义模型 ID ---
    if ($content -match 'custom:model_') {
        $needFix = $true
    }

    # --- 检测问题 3: additionalPrompt 占位符 ---
    if ($content -match 'additionalPrompt:\s*"\|"') {
        $needFix = $true
    }

    if (-not $needFix) { return }

    # 提取第一段 frontmatter
    $pattern = '(?s)^---\s*\n(.*?)\n---'
    $m = [regex]::Match($content, $pattern)
    if (-not $m.Success) { return }

    $frontmatter = $m.Groups[1].Value

    # 修复: 清除自定义模型 ID，改为空（使用各应用自己的默认模型）
    $frontmatter = $frontmatter -replace 'model:\s*"\[.*?\]\(custom:model_[^"]*\)"', 'model: ""'
    $frontmatter = $frontmatter -replace 'model:\s*"custom:model_[^"]*"', 'model: ""'

    # 修复: additionalPrompt 占位符
    $frontmatter = $frontmatter -replace 'additionalPrompt:\s*"\|"', 'additionalPrompt: ""'

    $fixed = "---`n$frontmatter`n---`n"
    Set-Content -Path $FilePath -Value $fixed -Encoding UTF8 -NoNewline

    $name = Split-Path $FilePath -Leaf
    Write-Host "[FIXED] $name ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Green
}

# 先修复一次当前已有的问题
Get-ChildItem $watchDir -Filter "*.md" | ForEach-Object {
    Repair-File $_.FullName
}

# 设置文件系统监控
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $watchDir
$watcher.Filter = "*.md"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
$watcher.EnableRaisingEvents = $true

$onChanged = Register-ObjectEvent $watcher "Changed" -Action {
    Start-Sleep -Milliseconds 300  # 等待写入完成
    $path = $Event.SourceEventArgs.FullPath
    Repair-File $path
}

Write-Host "[INFO] 监控已启动，等待文件变化..." -ForegroundColor Cyan

try {
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    Unregister-Event $onChanged.Name
    $watcher.Dispose()
    Write-Host "`n[INFO] 监控已停止" -ForegroundColor Gray
}
