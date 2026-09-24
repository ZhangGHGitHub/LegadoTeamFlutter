# 紧凑屏幕分析：小网格字符图 + 绿色/亮区包围盒（用于无图像输入时定位书封/控件）
# 用法: pwsh sw_map.ps1 <png路径> [cols] [rows]
param(
  [Parameter(Mandatory)][string]$Png,
  [int]$Cols = 20,
  [int]$Rows = 35
)
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap($Png)
$w = $bmp.Width; $h = $bmp.Height
$cw = [Math]::Max(1,[int]($w / $Cols)); $ch = [Math]::Max(1,[int]($h / $Rows))
Write-Output ("dims {0}x{1} cell {2}x{3}" -f $w,$h,$cw,$ch)
$gMinX=999999;$gMinY=999999;$gMaxX=-1;$gMaxY=-1;$gCnt=0
$bMinX=999999;$bMinY=999999;$bMaxX=-1;$bMaxY=-1;$bCnt=0
for ($r = 0; $r -lt $Rows; $r++) {
  $y0 = $r * $ch
  $line = ''
  for ($c = 0; $c -lt $Cols; $c++) {
    $x0 = $c * $cw
    $p = $bmp.GetPixel($x0, $y0)
    $R=$p.R; $G=$p.G; $B=$p.B
    $isGreen = ($G -gt $R + 25) -and ($G -gt $B + 25)
    $isBright = ($R -gt 210) -and ($G -gt 210) -and ($B -gt 210)
    if ($isGreen) {
      if ($x0 -lt $gMinX){$gMinX=$x0}; if ($y0 -lt $gMinY){$gMinY=$y0}
      if ($x0 -gt $gMaxX){$gMaxX=$x0}; if ($y0 -gt $gMaxY){$gMaxY=$y0}; $gCnt++
    }
    if ($isBright) {
      if ($x0 -lt $bMinX){$bMinX=$x0}; if ($y0 -lt $bMinY){$bMinY=$y0}
      if ($x0 -gt $bMaxX){$bMaxX=$x0}; if ($y0 -gt $bMaxY){$bMaxY=$y0}; $bCnt++
    }
    if ($R -lt 60 -and $G -lt 60 -and $B -lt 60) { $x2='#' }
    elseif ($isBright) { $x2='.' }
    elseif ($isGreen) { $x2='g' }
    elseif ($B -gt $R + 25 -and $B -gt $G + 25) { $x2='b' }
    elseif ($R -gt $G + 40 -and $R -gt $B + 40) { $x2='r' }
    else { $x2='-' }
    $line += [string]$x2
  }
  Write-Output (('{0,5}' -f $y0) + ' ' + $line)
}
Write-Output ("GREEN cells={0} bbox=[{1},{2}]-[{3},{4}]" -f $gCnt,$gMinX,$gMinY,$gMaxX,$gMaxY)
Write-Output ("BRIGHT cells={0} bbox=[{1},{2}]-[{3},{4}]" -f $bCnt,$bMinX,$bMinY,$bMaxX,$bMaxY)
$bmp.Dispose()
