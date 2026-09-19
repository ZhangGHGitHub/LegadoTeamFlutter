# verify-ffi-android.ps1 - Verify Android jniLibs match FRB content hash
#   + Rust 源码树指纹（P2-13：FRB hash 只覆盖 FFI 导出面；仅改 Rust 内部逻辑时
#     hash 不变，会误判 in sync 打包旧 .so。现追加 rust/** 源码树指纹比对，
#     指纹由 build-android.ps1 构建时写入 .so.meta 的 rustFingerprint 字段）
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

# P2-13: 读取 .so.meta 中的 Rust 源码树指纹（build-android.ps1 构建时写入）
function Get-SoMetaFingerprint {
    param([string]$SoPath)
    $metaPath = "$SoPath.meta"
    if (-not (Test-Path $metaPath)) { return $null }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($meta.rustFingerprint) { return [string]$meta.rustFingerprint }
        return $null
    } catch {
        return $null
    }
}

function Short-Hash {
    param([string]$Hash)
    if ($Hash.Length -ge 16) { return $Hash.Substring(0, 16) + "..." }
    return $Hash
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

# P2-13: 计算当前 Rust 源码树指纹（rust-fingerprint.ps1），用于判定 .so 是否陈旧
$FingerprintScript = Join-Path $ScriptDir "rust-fingerprint.ps1"
$CurrentRustFingerprint = $null
if (Test-Path $FingerprintScript) {
    $fpPrevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $fpRaw = & $FingerprintScript -RustDir $RustDir
    $ErrorActionPreference = $fpPrevEAP
    if ($fpRaw) { $CurrentRustFingerprint = ($fpRaw -join "`n").Trim() }
}
if ($CurrentRustFingerprint) {
    Write-Info "Rust source fingerprint: $(Short-Hash $CurrentRustFingerprint)"
} else {
    Write-Warn "Rust 源码树指纹不可用（rust-fingerprint.ps1 缺失或计算失败），本轮保守要求重编 .so"
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
            # P2-13: FRB content hash 只覆盖 FFI 导出面；再比对 Rust 源码树指纹，
            # 防止「只改 Rust 内部逻辑（FFI 面不变）→ 误判 in sync → 打包旧 .so」
            $metaFp = Get-SoMetaFingerprint -SoPath $soPath
            if (-not $metaFp) {
                $issues.Add("$abi .so.meta 缺 rustFingerprint（旧版构建产物），需重编 .so 以记录源码树指纹")
            } elseif (-not $CurrentRustFingerprint) {
                $issues.Add("$abi 当前 Rust 源码树指纹不可用，保守需重编 .so")
            } elseif ($metaFp -cne $CurrentRustFingerprint) {
                $issues.Add("$abi Rust 源码已变更（.so 指纹 $(Short-Hash $metaFp) ≠ 当前 $(Short-Hash $CurrentRustFingerprint)），.so 陈旧，需重编")
            } else {
                Write-Info "[OK] $abi (meta: FRB hash + Rust 源码指纹一致)"
            }
        }
        continue
    }

    if (Test-SoEmbedsHash -SoPath $soPath -Hash $expectedHash) {
        # P2-13: 无 .meta 的旧 .so 通过二进制 hash 但无指纹记录 → 源码树状态未知。
        # 保守重编（不回填指纹，否则等于给旧 .so 盖「当前指纹」，会再次骗过校验）
        $issues.Add("$abi .so 无源码树指纹记录（.so 可能来自更早源码树），需重编并记录指纹")
    } else {
        $issues.Add("$abi liblegado_ffi.so out of sync (expected hash $expectedHash)")
    }
}

if ($issues.Count -eq 0) {
    Write-Info ""
    Write-Info "=== FFI verify PASSED (FFI 面与 Rust 源码指纹一致，复用现有 .so) ===" "Green"
    exit 0
}

Write-Err ""
Write-Err "=== FFI verify FAILED (FRB hash / Rust 源码指纹 / .so 不同步) ==="
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
    Write-Warn ">> Rust 源码已变更 / .so 陈旧或缺失，正在重编 .so ..."
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
