#!/usr/bin/env pwsh
# rust-fingerprint.ps1 — Rust 源码树指纹（P2-13）
#
# 背景：FFI 校验此前只比对 FRB content hash（frb_generated 的 FFI 导出面）。
# 当 Rust 只改内部逻辑（如 web_book.rs）而 FFI 面不变时，FRB hash 不变，
# 校验误判「in sync」→ 跳过交叉编译 → APK 打包旧 liblegado_ffi.so。
# 本脚本计算「Rust 源码树指纹」：rust/ 下任意源码/依赖清单变更都会改变指纹，
# 由 build-android.ps1 写入 .so.meta（rustFingerprint 字段），
# verify-ffi-android.ps1 / build-apk.ps1 据此判定 .so 是否陈旧。
#
# 用法:
#   .\rust-fingerprint.ps1                    # 打印当前指纹（单行 64 位小写 hex，stdout）
#   .\rust-fingerprint.ps1 -Check             # 逐 ABI 比对 jniLibs .so.meta 中的 rustFingerprint
#   .\rust-fingerprint.ps1 -Check -Targets "x86_64" [-Quiet]
#
# Check 模式输出（供调用方解析）:
#   每 ABI 一行提示（-Quiet 时仅打印异常 ABI 的行）；
#   末行恒为:  DECISION=REUSE  或  DECISION=REBUILD  fingerprint=<当前指纹>
#   （-Quiet 也打印末行，便于 & 调用后解析；逐 ABI 明细走 Write-Host 直接上屏）
# 退出码: 0=完成（判定看 DECISION 行）  1=参数错误
#
# 指纹算法（必须与 rust-fingerprint.sh 在相同源码树上产生相同结果，跨 OS 校验依赖此约定）:
#   1. 文件集 = rust/ 下所有常规文件，排除任意深度的 target/ 目录（构建产物）；
#   2. 每文件一行:  <相对路径(无 ./ 前缀, / 分隔)>TAB<该文件内容 SHA256 小写 hex>
#   3. 各行按「整行字节序」排序（ASCII 下等价于路径序；PS 侧用 Ordinal 比较，bash 侧用 LC_ALL=C）
#   4. 拼接（每行以 LF 结尾）后取 SHA256，小写 hex 即指纹
# 说明: 包含 Cargo.toml / Cargo.lock / 全部 crate src / assets / 构建脚本——
#       凡可能影响 .so 产物的变更都触发重编（宁多重编，不打包旧 .so）。

param(
    [string]$RustDir = "",
    [string]$Targets = "aarch64,x86_64",
    [switch]$Check,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Get-RustFingerprint {
    param([string]$Root)
    $rootFull = (Resolve-Path $Root).Path.TrimEnd('\', '/')
    $files = Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($rootFull.Length + 1) -replace '\\', '/'
        # 排除任意深度的 target/ 目录（构建产物不进指纹）
        if ($rel -match '(^|/)target(/|$)') { continue }
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        $lines.Add("$rel`t$hash")
    }
    # 整行字节序（Ordinal）排序，保证确定性且与 bash LC_ALL=C sort 一致
    $lines.Sort([System.StringComparer]::Ordinal)
    # 每行以 LF 结尾（不用 AppendLine：其在 Windows 上产生 CRLF，与 bash 侧 LF 不一致）
    $payload = [System.Text.StringBuilder]::new()
    foreach ($line in $lines) { [void]$payload.Append($line).Append("`n") }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload.ToString()))
    return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLower()
}

if (-not $RustDir) {
    $RustDir = Split-Path -Parent $PSScriptRoot
}

$curFp = Get-RustFingerprint -Root $RustDir

if (-not $Check) {
    Write-Output $curFp
    exit 0
}

$RootDir = Split-Path -Parent $RustDir
$JniLibsDir = Join-Path (Join-Path $RootDir "flutter_legado") "android\app\src\main\jniLibs"
$AbiMap = @{}
$AbiMap["aarch64"] = "arm64-v8a"
$AbiMap["armv7"]   = "armeabi-v7a"
$AbiMap["x86_64"]  = "x86_64"

$rebuild = $false
foreach ($key in ($Targets -split "," | ForEach-Object { $_.Trim() })) {
    if ($key -eq "") { continue }
    if (-not $AbiMap.ContainsKey($key)) {
        Write-Host "[Fingerprint] Unknown target: $key" -ForegroundColor Red
        exit 1
    }
    $abi = $AbiMap[$key]
    $soPath = Join-Path $JniLibsDir "$abi\liblegado_ffi.so"
    if (-not (Test-Path $soPath)) {
        if (-not $Quiet) { Write-Host "[Fingerprint] $abi liblegado_ffi.so 不存在 → 需构建" -ForegroundColor Yellow }
        $rebuild = $true
        continue
    }
    $metaFp = $null
    $metaPath = "$soPath.meta"
    if (Test-Path $metaPath) {
        try {
            $metaJson = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($metaJson.rustFingerprint) { $metaFp = [string]$metaJson.rustFingerprint }
        } catch { $metaFp = $null }
    }
    if (-not $metaFp) {
        if (-not $Quiet) { Write-Host "[Fingerprint] $abi .so 无源码指纹记录（.meta 缺 rustFingerprint，旧版产物/手工产物）→ 需重编 .so 以记录指纹" -ForegroundColor Yellow }
        $rebuild = $true
        continue
    }
    if ($metaFp -cne $curFp) {
        if (-not $Quiet) {
            Write-Host "[Fingerprint] $abi Rust 源码已变更（.so 指纹 $($metaFp.Substring(0, 16))… ≠ 当前 $($curFp.Substring(0, 16))…）→ .so 陈旧，需重编" -ForegroundColor Yellow
        }
        $rebuild = $true
        continue
    }
    if (-not $Quiet) {
        Write-Host "[Fingerprint] $abi 一致（指纹 $($curFp.Substring(0, 16))…）" -ForegroundColor Green
    }
}

$decision = if ($rebuild) { "REBUILD" } else { "REUSE" }
Write-Output "DECISION=$decision fingerprint=$curFp"
exit 0
