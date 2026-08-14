# verify-ffi-android.ps1 - Verify Android jniLibs match FRB content hash
#
# Usage:
#   .\verify-ffi-android.ps1
#   .\verify-ffi-android.ps1 -AutoBuild
#   .\verify-ffi-android.ps1 -Mode debug -Targets "x86_64,aarch64"
#
# Exit: 0=ok  1=mismatch  2=no toolchain (use Mock mode)

param(
    [ValidateSet("release", "debug")]
    [string]$Mode = "debug",

    [string]$Targets = "aarch64,x86_64",

    [switch]$AutoBuild,

    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$msg, [string]$Color = "") {
    if ($Quiet) { return }
    if ($Color) { Write-Host $msg -ForegroundColor $Color }
    else { Write-Host $msg }
}

function Write-Warn([string]$msg) {
    if (-not $Quiet) { Write-Host $msg -ForegroundColor Yellow }
}

function Write-Err([string]$msg) {
    Write-Host $msg -ForegroundColor Red
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RustDir = Split-Path -Parent $ScriptDir
$RootDir = Split-Path -Parent $RustDir
$FlutterDir = Join-Path $RootDir "flutter_legado"
$JniLibsDir = Join-Path $FlutterDir "android\app\src\main\jniLibs"
$DartFrb = Join-Path $FlutterDir "lib\src\bridge\frb_generated.dart"
$RustFrb = Join-Path $RustDir "legado-ffi\src\frb_generated.rs"
$BuildScript = Join-Path $ScriptDir "build-android.ps1"

$AbiMap = @{
    "aarch64" = "arm64-v8a"
    "armv7"   = "armeabi-v7a"
    "x86_64"  = "x86_64"
}

$SelectedKeys = $Targets -split "," | ForEach-Object { $_.Trim() }

function Get-FrbContentHashFromFile {
    param([string]$Path, [string]$Pattern)
    if (-not (Test-Path $Path)) {
        throw "FRB file not found: $Path"
    }
    $text = Get-Content $Path -Raw -Encoding UTF8
    if ($text -match $Pattern) {
        return [int]$Matches[1]
    }
    throw "Cannot parse content hash from $Path"
}

function Get-ExpectedContentHash {
    $dartHash = Get-FrbContentHashFromFile -Path $DartFrb -Pattern 'rustContentHash\s*=>\s*(-?\d+)'
    $rustHash = Get-FrbContentHashFromFile -Path $RustFrb -Pattern 'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH:\s*i32\s*=\s*(-?\d+)'
    if ($dartHash -ne $rustHash) {
        throw "Dart/Rust frb_generated hash mismatch (Dart=$dartHash Rust=$rustHash). Run flutter_legado\scripts\generate-bridge.ps1"
    }
    return $dartHash
}

function Test-SoEmbedsHash {
    param([string]$SoPath, [int]$Hash)
    if (-not (Test-Path $SoPath)) { return $false }
    $needle = [System.BitConverter]::GetBytes([int32]$Hash)
    $bytes = [System.IO.File]::ReadAllBytes($SoPath)
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

function Get-SoMetaHash {
    param([string]$SoPath)
    $metaPath = "$SoPath.meta"
    if (-not (Test-Path $metaPath)) { return $null }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [int]$meta.contentHash
    } catch {
        return $null
    }
}

function Write-SoMeta {
    param([string]$SoPath, [int]$Hash, [string]$BuildMode)
    $meta = [ordered]@{
        contentHash = $Hash
        mode        = $BuildMode
        builtAt     = (Get-Date).ToString("o")
    }
    ($meta | ConvertTo-Json -Compress) | Set-Content "$SoPath.meta" -Encoding UTF8 -NoNewline
}

function Get-BuildCommand {
    return ".\rust\scripts\build-android.ps1 -Mode $Mode -Targets `"$Targets`""
}

try {
    $expectedHash = Get-ExpectedContentHash
} catch {
    Write-Err "[FFI] $($_.Exception.Message)"
    exit 1
}

Write-Info "=== Legado Android FFI verify ==="
Write-Info "Expected content hash: $expectedHash"
Write-Info "Build mode: $Mode"
Write-Info "Targets: $($SelectedKeys -join ', ')"
Write-Info ""

$issues = New-Object System.Collections.Generic.List[string]

foreach ($key in $SelectedKeys) {
    if (-not $AbiMap.ContainsKey($key)) {
        Write-Err "Unknown target: $key"
        exit 1
    }
    $abi = $AbiMap[$key]
    $soPath = Join-Path $JniLibsDir "$abi\liblegado_ffi.so"

    if (-not (Test-Path $soPath)) {
        $issues.Add("missing $abi\liblegado_ffi.so")
        continue
    }

    $metaHash = Get-SoMetaHash -SoPath $soPath
    if ($null -ne $metaHash) {
        if ($metaHash -ne $expectedHash) {
            $issues.Add("$abi .so.meta hash=$metaHash, expected $expectedHash")
        } else {
            Write-Info "[OK] $abi (meta)"
        }
        continue
    }

    if (Test-SoEmbedsHash -SoPath $soPath -Hash $expectedHash) {
        Write-Info "[OK] $abi (binary hash)"
        Write-SoMeta -SoPath $soPath -Hash $expectedHash -BuildMode $Mode
    } else {
        $issues.Add("$abi liblegado_ffi.so out of sync (expected hash $expectedHash)")
    }
}

if ($issues.Count -eq 0) {
    Write-Info ""
    Write-Info "=== FFI verify PASSED ===" "Green"
    exit 0
}

Write-Err ""
Write-Err "=== FFI verify FAILED (content hash / .so out of sync) ==="
foreach ($item in $issues) {
    Write-Err "  - $item"
}

$buildCmd = Get-BuildCommand
Write-Err ""
Write-Err "Run from repo root:"
Write-Err "  $buildCmd"
Write-Err ""
Write-Err "Or unified entry:"
Write-Err "  .\flutter_legado\scripts\build-apk.ps1 -Targets `"$Targets`""
Write-Err ""
Write-Err "Pure Dart UI dev (no Rust):"
Write-Err "  flutter run --dart-define=USE_MOCK=true"

if ($AutoBuild) {
    if (-not (Test-Path $BuildScript)) {
        Write-Err "Build script not found: $BuildScript"
        exit 2
    }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Warn "cargo not found; skip auto-build (use Mock mode)"
        exit 2
    }
    Write-Warn ""
    Write-Warn ">> Auto-running build-android.ps1 ..."
    & $BuildScript -Mode $Mode -Targets $Targets
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Auto-build failed (exit=$LASTEXITCODE)"
        exit 1
    }
    & $MyInvocation.MyCommand.Path -Mode $Mode -Targets $Targets -Quiet:$Quiet
    exit $LASTEXITCODE
}

exit 1
