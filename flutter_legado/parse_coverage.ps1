# 解析 lcov.info 覆盖率报告
$content = Get-Content "coverage/lcov.info" -Raw
$files = $content -split "end_of_record"
$results = @()
$totalAll = 0
$hitAll = 0

foreach ($f in $files) {
    if ($f -match "SF:(.+?)\r?\n") {
        $sf = $Matches[1]
        $lines = [regex]::Matches($f, "DA:(\d+),(\d+)")
        $total = $lines.Count
        $hit = ($lines | Where-Object { [int]$_.Groups[2].Value -gt 0 }).Count
        if ($total -gt 0) {
            $pct = [math]::Round($hit / $total * 100, 1)
            $shortName = $sf -replace ".*lib/src/", ""
            $results += [PSCustomObject]@{File=$shortName; Total=$total; Hit=$hit; Pct=$pct}
            $totalAll += $total
            $hitAll += $hit
        }
    }
}

Write-Host "=== 总体覆盖率 ==="
$overallPct = [math]::Round($hitAll / $totalAll * 100, 1)
Write-Host "总行数: $totalAll, 命中: $hitAll, 覆盖率: $overallPct%"
Write-Host ""
Write-Host "=== 分层覆盖率 ==="

$providers = $results | Where-Object { $_.File -like "providers/*" }
$services = $results | Where-Object { $_.File -like "services/*" }
$screens = $results | Where-Object { $_.File -like "screens/*" }
$widgets = $results | Where-Object { $_.File -like "widgets/*" }
$models = $results | Where-Object { $_.File -like "models/*" }

foreach ($group in @(@{Name="Providers";Items=$providers}, @{Name="Services";Items=$services}, @{Name="Screens";Items=$screens}, @{Name="Widgets";Items=$widgets}, @{Name="Models";Items=$models})) {
    $t = ($group.Items | Measure-Object -Property Total -Sum).Sum
    $h = ($group.Items | Measure-Object -Property Hit -Sum).Sum
    if ($t -gt 0) {
        $p = [math]::Round($h / $t * 100, 1)
        Write-Host "$($group.Name): $h/$t = $p%"
    }
}

Write-Host ""
Write-Host "=== 各文件详情（按覆盖率排序）==="
$results | Sort-Object Pct | Format-Table -AutoSize
