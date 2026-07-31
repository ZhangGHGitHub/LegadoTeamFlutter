$lcov = Get-Content "coverage/lcov.info" -Raw
$blocks = $lcov -split "end_of_record"
$results = @()

foreach ($block in $blocks) {
    if ($block -match "SF:(.+?)\r?\n") {
        $file = $Matches[1]
        $lines = [regex]::Matches($block, "DA:(\d+),(\d+)")
        if ($lines.Count -gt 0) {
            $total = $lines.Count
            $hit = ($lines | Where-Object { [int]$_.Groups[2].Value -gt 0 }).Count
            $pct = [math]::Round($hit / $total * 100, 1)
            $results += @{File=$file; Total=$total; Hit=$hit; Pct=$pct}
        }
    }
}

# Show providers
Write-Host "=== Providers Coverage ==="
$providers = $results | Where-Object { $_.File -like "*provider*" } | Sort-Object Pct -Descending
foreach ($p in $providers) {
    Write-Host "$($p.Pct)% : $($p.File.Split('/')[-1]) - $($p.Hit)/$($p.Total)"
}

Write-Host "`n=== Services Coverage (excluding rust_api which is FFI layer) ==="
$services = $results | Where-Object { $_.File -like "*service*" -and $_.File -notlike "*rust_api*" } | Sort-Object Pct -Descending
foreach ($s in $services) {
    Write-Host "$($s.Pct)% : $($s.File.Split('/')[-1]) - $($s.Hit)/$($s.Total)"
}
