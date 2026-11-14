# 依赖漏洞调研报告（cargo audit 23 项）

> 基线：HEAD `7e80d3562f`（2026-11-15），`rust-toolchain.toml` = 1.97.1，cargo-audit 0.22.2
> 范围：`rust/` 9 个 workspace crate
> 方法：`cargo audit --json`、`cargo tree -i`、`cargo update --dry-run`、临时副本全量升级模拟（不触碰仓库）、registry 源码/CHANGELOG 核对、代码路径可达性静态审查
> 约束：未修改任何业务代码、`Cargo.toml`、`Cargo.lock`
> 编写：调研子代理 ｜ 2026-11-15

## 一、摘要

### 1.1 计数

| 分类 | 数量 | 条目 |
|---|---|---|
| A 可直接升级（仅 lock 或 manifest 版本行，无需改代码） | 19 | libsqlite3-sys×1、quinn 家族×8、rustls×4、rustls-webpki×1、webpki-roots×1、zstd 家族×4 |
| B 需改代码适配 | 4 | zip×4（RUSTSEC-2026-0367/0368/0369/0429） |
| C 无可修路径需豁免 | 0 | — |
| 合计 | 23 | **23/23 = 100% 有已发布修复版本** |

22 项 allowed warnings 另计：8 项 unmaintained（全部暂缓）、13 项 unsound（11 项由本次 A 类顺带修复，2 项 lru 可选升级）、1 项 yanked（chacha20，A 类一条命令修复）。

### 1.2 全量升级模拟结果（临时副本，仓库零改动）

| 阶段 | 非豁免漏洞 | warnings | `cargo audit` 结果 |
|---|---|---|---|
| 现状 | 23 | 8 unmaintained + 13 unsound + 1 yanked | `error: 23 vulnerabilities found! warning: 22 allowed warnings found` |
| 仅 A 类 lock 更新 | 5（libsqlite3-sys 1 + zip 4） | 8 unmaintained + 2 lru unsound | exit 1 |
| A + rusqlite/r2d2_sqlite | 4（zip） | 8 unmaintained + 2 lru unsound | exit 1 |
| A + rusqlite + zip 9.5.1 | **0** | 8 unmaintained + 2 lru unsound | **exit 0**（保留现有 audit.toml 两项豁免） |
| 再叠加 lopdf 0.47 / scraper 0.29 / lru 0.18.5（可选） | 0 | **6 unmaintained，0 unsound** | exit 0 |

### 1.3 最关键的 3 条发现

1. **quinn 8 项当前完全不可达，但必须修 lock**：`reqwest 0.12.28` 仅在启用 `http3` feature 时编译 quinn；我方 `legado-net` / `legado-server` 均未启用 `http3`，`cargo tree --target all` 中 quinn 出现 0 次。它只是 Cargo.lock 里的可选依赖残留。真正高可达的是 **rustls-webpki + webpki-roots 的 emSign 信任链（2 项）**：默认 HTTPS 校验路径可达，且 emSign 中间证书私钥已公开，应作为本批最高优先级。
2. **zip 4 项不能靠 2.6.1**：RustSec 的 patched 范围是 `>=9.0.0`，2.6.1 仍全部受影响。2.6.1 已将 `ZipFile<'a>` 改为 `ZipFile<'a, R: Read>`，这正是 `legado-js/src/host_api/archive_utils.rs:189` 的 `ZipFile<'_>` 编译失败原因；9.5.1 又进一步把 `ZipFile::name()` 从 `&str` 改为 `ZipResult<Cow<'_, str>>`，**11 处调用点必须改，且 `.to_string()` 在 `Result` 上会静默编译成 `Ok("...")`，是本次升级最大的隐蔽坑**。
3. **23 项全部可修，无需新增永久豁免**。A→DB→zip 三批落地后非豁免漏洞归零；剩余 8 项 unmaintained 全部来自 `genpdf 0.2.0 → printpdf 0.3.4 → lopdf 0.26 / image 0.23 / rusttype 0.8 / time 0.2.27` 这条停更链，只能靠把 PDF 导出重写为 `printpdf 0.12` 才能彻底清除，建议列 P2。

### 1.4 批次建议

- **批 1**：A 类锁更新（TLS 家族 → quinn → zstd → chacha20 → tokio）——lock-only，可合一笔。
- **批 2**：rusqlite / r2d2_sqlite / libsqlite3-sys——DB 引擎敏感，独立一笔。
- **批 3**：zip 9.5.1 + 代码适配——归档解析/API 敏感，独立一笔。
- **批 4（可选 P2）**：lru 0.18、lopdf 0.47、scraper 0.29、genpdf→printpdf 0.12——逐项独立。

## 二、逐项表

| ID | crate@version | 直接依赖 / 引入链 | 修复版本 | 影响面 | 我方可达性 | 处置 |
|---|---|---|---|---|---|---|
| RUSTSEC-2026-0459 | libsqlite3-sys 0.28.0 | 传递：rusqlite 0.31（legado-db、legado-ffi）+ r2d2_sqlite 0.24 | 0.39.1（经 rusqlite 0.41.1） | manifest 2 crate + lock；SQLite 3.45.0→3.54.1；MSRV 1.89 | 低：仅打开应用私有 DB（`legado-ffi/src/ffi.rs:193` 的 `init_database`），无用户可控 DB+WAL 对；本地利用需同账号写权限 | **A** |
| RUSTSEC-2026-0338 | quinn-proto 0.11.16 | 传递可选：reqwest 0.12.28（http3 未启用） | >=0.11.18（统一升 0.11.19） | lock-only | 零：未编译；且需 unordered read | **A** |
| RUSTSEC-2026-0339 | quinn-proto 0.11.16 | 同上 | >=0.11.17（升 0.11.19） | lock-only | 零：未编译 | **A** |
| RUSTSEC-2026-0340 | quinn-proto 0.11.16 | 同上 | >=0.11.18（升 0.11.19） | lock-only | 零：未编译；ACK_FREQUENCY 为 opt-in | **A** |
| RUSTSEC-2026-0341 | quinn-proto 0.11.16 | 同上 | >=0.11.17（升 0.11.19） | lock-only | 零：未编译 | **A** |
| RUSTSEC-2026-0342 | quinn-proto 0.11.16 | 同上 | >=0.11.17（升 0.11.19） | lock-only | 零：未编译；未使用 DATAGRAM | **A** |
| RUSTSEC-2026-0523 | quinn-proto 0.11.16 | 同上 | >=0.11.19 | lock-only | 零：未编译 | **A** |
| RUSTSEC-2026-0524 | quinn-proto 0.11.16 | 同上 | >=0.11.19 | lock-only | 零：未编译 | **A** |
| RUSTSEC-2026-0538 | quinn-udp 0.5.15 | 传递可选：reqwest→quinn | >=0.5.16 或 >=0.6.3（用 0.5.16） | lock-only | 零：未编译；且 Linux/Android/Windows 接收路径不受影响 | **A** |
| RUSTSEC-2026-0346 | rustls 0.23.45 | 传递：reqwest→hyper-rustls 0.27.9 / tokio-rustls 0.26.4；dev-dep legado-net | 0.23.46 | lock-only | 零：无自定义 `ClientSessionStore`，不打印会话值 Debug | **A** |
| RUSTSEC-2026-0347 | rustls 0.23.45 | 同上 | 0.23.46 | lock-only | 零：未启用 ECH（reqwest 无 ECH 配置） | **A** |
| RUSTSEC-2026-0348 | rustls 0.23.45 | 同上 | 0.23.46 | lock-only | 零：rustls `brotli` feature 未启用（feature 树已核实） | **A** |
| RUSTSEC-2026-0349 | rustls 0.23.45 | 同上 | 0.23.46 | lock-only | 零：ring provider 仅 X25519/SECP256R1/SECP384R1，无 MLKEM 组可降级 | **A** |
| RUSTSEC-2026-0382 | rustls-webpki 0.103.15 | 传递：rustls | >=0.103.16（用 0.103.17） | lock-only | **高**：默认 HTTPS 校验路径可达；emSign 中间证书私钥公开，可伪造链 | **A（最高优先）** |
| RUSTSEC-2026-0381 | webpki-roots 1.0.9 | 传递：reqwest / hyper-rustls | >=1.0.10（用 1.0.12） | lock-only | **高**：同上；1.0.9 仍含 `emSign ECC Root CA - G3` | **A（最高优先）** |
| RUSTSEC-2026-0367 | zip 2.4.2 | 直接：`legado-book/Cargo.toml:10`、`legado-net/Cargo.toml:25`、`legado-ffi/Cargo.toml:37`、`legado-js/Cargo.toml:46`（optional quickjs） | **9.5.1**（2.6.1 仍受影响） | manifest 4 crate + 11 处 `name()` + 1 处泛型；MSRV 1.88；新增依赖 | 零：仅 `ZipArchive::extract()` 路径；全仓无 `.extract(` 调用，全部手写 `by_index/by_name`，只写普通文件，不建 symlink、不套用外部权限位 | **B** |
| RUSTSEC-2026-0368 | zip 2.4.2 | 同上 | 9.5.1 | 同上 | 零：同上；`archive_utils.rs:251` 用 `enclosed_name()`，`archive.rs:202`/`backup_api.rs:1201` 用白名单校验 | **B** |
| RUSTSEC-2026-0369 | zip 2.4.2 | 同上 | 9.5.1 | 同上 | 零：同上 | **B** |
| RUSTSEC-2026-0429 | zip 2.4.2 | 同上 | 9.5.1 | 同上 | 零：同上；我方先检查声明大小再流式读取（`archive_utils.rs:192-205`、`archive.rs:206-216`），不做 `Vec::with_capacity(声明值)` | **B** |
| RUSTSEC-2026-0391 | zstd 0.13.3 | 传递：zip 2.4.2 默认 `zstd` feature | >=0.13.4（用 0.13.5） | lock-only | 零：zip 使用 `zstd::Decoder::with_buffer` / `Encoder::new` 新建 context，不走 `with_context` | **A** |
| RUSTSEC-2026-0398 | zstd-safe 7.2.4 | 传递：zstd | ^7.4.0（用 7.4.1） | lock-only | 零：未使用 `Seekable` | **A** |
| RUSTSEC-2026-0403 | zstd-safe 7.2.4 | 传递：zstd | ^7.4.0（用 7.4.1） | lock-only | 零：zip 使用 `read::Decoder`，非 `write::Decoder`（公告明确 read/bulk 不受影响） | **A** |
| RUSTSEC-2026-0410 | zstd-sys 2.0.16+zstd.1.5.7 | 传递：zstd-safe | >=2.1.2（用 2.1.3） | lock-only | 零：仅 wasm32，非我方目标平台 | **A** |

## 三、A 类升级方案

### 3.1 升级顺序与命令（按依赖自底向上）

```bash
cd D:\OH-WorkSpace\LegadoTeam\legado\rust

# 第 1 步：TLS 信任链（底层，最高优先级）
cargo update -p rustls-webpki --precise 0.103.17
cargo update -p webpki-roots  --precise 1.0.12
cargo update -p rustls         --precise 0.23.46

# 第 2 步：QUIC（上层；当前未编译，仅清 lock 审计）
cargo update -p quinn-proto --precise 0.11.19
cargo update -p quinn-udp   --precise 0.5.16

# 第 3 步：zstd（zip 默认 feature 引入；patch 级）
cargo update -p zstd --precise 0.13.5
# 期望连带：zstd-safe 7.4.1、zstd-sys 2.1.3

# 第 4 步：yanked chacha20
cargo update -p chacha20 --precise 0.10.2

# 第 5 步：tokio unsound（可选，warning）
cargo update -p tokio --precise 1.53.3
```

第 1 步也可合并为一条：`cargo update -p rustls -p rustls-webpki -p webpki-roots`，实测可直接锁定到上述三个版本。

### 3.2 各步风险

| 步骤 | 风险 | 说明与验证 |
|---|---|---|
| rustls/webpki/roots | 低 | 0.23 patch + webpki patch，reqwest/hyper-rustls/tokio-rustls 要求 `rustls ^0.23`，无 API 变化；跑 `cargo test -p legado-net`（含自签证书回环用例）+ 真实 HTTPS 书源冒烟 |
| quinn | 零 | 未编译；quinn 0.11.11 的 `quinn-proto ^0.11.15`、`quinn-udp ^0.5` 均允许新版本 |
| zstd | 低 | 项目不直接使用 zstd；zip 2.4.2 要求 `zstd ^0.13`，0.13.5 兼容 |
| chacha20 | 低 | 0.10.2 修复 SSE2 后端误用 SSE4.1 intrinsic 的正确性问题；`rand 0.10.x` 要求 `chacha20 ^0.10.0`，兼容 |
| tokio | 低 | 1.53.3 patch；项目未使用 `AsyncFd`，该 unsound 本身不可达 |
| rusqlite/r2d2_sqlite | 中 | SQLite 3.45.0→3.54.1；119 版 schema 迁移、WAL、备份恢复需全量回归。`r2d2_sqlite 0.36/0.37` 默认 `is-valid` 会对每次取连接执行 `SELECT 1;`，当前 0.24 是空 batch；**必须加 `default-features = false` 保持现有性能语义** |
| lru（可选） | 低 | 仅用 `new/put/get/pop/len/clear/iter`，0.18.5 签名一致；清掉 2 项 unsound |

### 3.3 rusqlite / r2d2_sqlite 具体版本

- 最小修复对（推荐）：`rusqlite 0.41.1` + `r2d2_sqlite 0.36.0` → `libsqlite3-sys 0.39.1`（SQLite 3.54.1）。
- 最新对（可选）：`rusqlite 0.42.0` + `r2d2_sqlite 0.37.0` → `libsqlite3-sys 0.40.0`（SQLite 3.54.1）。
- 两对 API 均已静态核对：`pragma_update(None, ...)` 在 0.41 起已是 `Option<&str>`，`execute/query_row/query_map/execute_batch/unchecked_transaction/Transaction::new_unchecked/TransactionBehavior` 签名不变；我方使用的 `Error::{QueryReturnedNoRows, InvalidQuery, FromSqlConversionFailure}` 均仍存在。预计**零源码改动**。

清单改动：

```toml
# legado-db/Cargo.toml:10,12
rusqlite = { version = "0.41.1", features = ["bundled"] }
r2d2_sqlite = { version = "0.36.0", default-features = false }

# legado-ffi/Cargo.toml:28,30
rusqlite = { version = "0.41.1", features = ["bundled"] }
r2d2_sqlite = { version = "0.36.0", default-features = false }
```

```bash
cargo update -p rusqlite --precise 0.41.1
cargo update -p r2d2_sqlite --precise 0.36.0
cargo update -p libsqlite3-sys --precise 0.39.1
cargo tree -i libsqlite3-sys   # 应只剩 0.39.1
```

## 四、B 类代码适配清单（zip 2.4.2 → 9.5.1）

### 4.1 API 差异证据

| 版本 | `ZipFile` 定义 | `ZipFile::name()` 返回 |
|---|---|---|
| 2.4.2 | `pub struct ZipFile<'a>`（`zip-2.4.2/src/read.rs:251`） | `&str`（`read.rs:1543`） |
| 2.6.1 | `pub struct ZipFile<'a, R: Read>`（`zip-2.6.1/src/read.rs:252`） | `&str`（`read.rs:1523`） |
| 9.5.1 | `pub struct ZipFile<'a, R: Read + ?Sized>`（`zip-9.5.1/src/read/zipfile.rs:31`） | `ZipResult<Cow<'_, str>>`（`zipfile.rs:97`） |

其余我方用到的 API 在 9.5.1 中保持兼容：`ZipArchive::new/len/by_index/by_name`、`ZipFile::enclosed_name/is_dir/size/is_symlink`、`ZipWriter::new/start_file/add_directory/finish`、`SimpleFileOptions`、`CompressionMethod::{Stored,Deflated,Zstd}`。

**结论：2.6.1 不是修复版本，且同样需要改泛型；没有理由停在 2.6.1，直接上 9.5.1。**

### 4.2 清单改动（4 个 crate）

| 文件:行 | 改为 |
|---|---|
| `legado-book/Cargo.toml:10` | `zip = "9"`（或 `{ version = "9", default-features = false, features = ["deflate","zstd","time"] }`，见 4.4） |
| `legado-net/Cargo.toml:25` | `zip = "9"` |
| `legado-ffi/Cargo.toml:37` | `zip = "9"` |
| `legado-js/Cargo.toml:46` | `zip = { version = "9", optional = true }` |

### 4.3 源码改动清单

| 文件:行 | 现状 | zip 9 改法 |
|---|---|---|
| `legado-js/src/host_api/archive_utils.rs:188-190` | `fn read_zip_entry_capped(entry: &mut zip::read::ZipFile<'_>, ...)` | `fn read_zip_entry_capped<R: std::io::Read>(entry: &mut zip::read::ZipFile<'_, R>, ...)`；调用点自动推断 `R` |
| `legado-book/src/archive.rs:202` | `validate_archive_entry_name(entry.name(), "ZIP")?` | 先 `entry.name().map_err(...)?` 取局部 `name`，再校验 |
| `legado-book/src/archive.rs:209` | `format!` 参数里 `entry.name()` | 复用上面的局部 `name`；**不能直接留 `entry.name()`**，否则 `Result` 的 Display 会把整个 `Ok("...")` 打进错误文案 |
| `legado-book/src/archive.rs:260` | `let entry_name = entry.name().to_string();` | `.name().map_err(...)?.into_owned()`（后面有 `entry.read`，必须 owned） |
| `legado-book/src/archive.rs:598` | `let name = entry.name().to_string();` | `.map_err(...)?.into_owned()` |
| `legado-book/src/cbz.rs:54` | `let name = entry.name();` | `.map_err(...)?`（之后只读 name，可保留 Cow） |
| `legado-book/src/umd.rs:111` | `let name = file.name().to_string();` | `.map_err(...)?.into_owned()`（后面 `file.read_to_string`） |
| `legado-ffi/src/api/backup_api.rs:1201` | `entry.name().trim_start_matches("./").to_string()` | `.map_err(...)?.trim_start_matches("./").to_string()`；后面 `&mut entry` 读取，必须 owned |
| `legado-book/src/export.rs:1218` | 测试 `.map(|i| archive.by_index(i).unwrap().name().to_string())` | `.name().unwrap().to_string()` |
| `legado-book/src/export.rs:1241` | `assert_eq!(first.name(), "mimetype")` | `assert_eq!(first.name().unwrap(), "mimetype")` |
| `legado-net/src/direct_link_upload.rs:498,763` | `assert_eq!(entry.name(), "...")` | `entry.name().unwrap()` |

**隐蔽坑（必须写进实现批任务书）**：`name()` 变成 `Result` 后，`.to_string()`、`format!("{}", ...)`、`.trim_start_matches(...)` 这类写法里，前两者**能编译但语义错误**（输出 `Ok("...")`），第三者才会编译报错。必须逐个显式 `?`/`map_err`，不能靠编译器兜底。

### 4.4 依赖与行为影响

- MSRV：zip 9.5.1 要求 Rust 1.88；当前 toolchain 1.97.1、CI stable 均满足。
- 新增锁文件包：`cmov、cpubits、ctutils、hybrid-array、libbz2-rs-sys、nix、ppmd-rust、typed-path、zlib-rs`；移除 `arbitrary、bzip2-sys、crc、crc-catalog、derive_arbitrary、lzma-rs、lzma-sys、xz2`。
- 新增重复 crypto 版本：`aes 0.9+0.8`、`cipher 0.5+0.4`、`digest 0.11+0.10`、`sha1 0.11+0.10`、`sha2 0.11+0.10`、`hmac 0.13+0.12`、`pbkdf2 0.13+0.12`。功能无冲突，但产物体积与编译时间会略增。
- 默认 features 与 2.4.2 基本对齐（`aes-crypto,bzip2,deflate64,deflate,lzma,ppmd,time,zstd,xz`）。若确认不读加密 ZIP/稀有压缩方法，可改 `default-features = false, features = ["deflate","zstd","time"]`，但这是能力裁剪，需产品确认；且 optional 依赖仍会进入 Cargo.lock 被 audit 扫描，不能减少审计面。
- `name()` 遇到无法解码的条目名现在会返回错误：建议列表路径按「跳过 + 告警」处理，解压路径按 fail-closed 处理，避免一个坏条目导致整包导入失败。
- 回归面：`legado-book`（EPUB/CBZ/UMD/归档导入）、`legado-js` quickjs（`java.unzipFile`/`getZipStringContent`）、`legado-ffi`（备份创建/恢复含密码、书籍导入、阅读器 zip）、`legado-net`（直链上传内存 zip）。

## 五、C 类豁免清单

本次推荐方案下 **23 项漏洞 C 类为 0**。以下仅作为「zip 9 无法在发布前落地」的临时兜底，以及 unmaintained warnings 的登记模板。

### 5.1 zip 临时豁免模板（仅当批 3 推迟时使用）

```toml
# [advisories] ignore 追加：
# RUSTSEC-2026-0367 / 0368 / 0369 / 0429 — zip 2.4.2 的 extract() 系列缺陷
#   豁免对象：zip 2.4.2。公告 patched 范围为 >=9.0.0，2.x 无修复版本。
#   风险接受理由（临时）：四条公告全部只影响 ZipArchive::extract() /
#   ZipStreamReader::extract() 的自动解压路径；我方全仓无 .extract( 调用，
#   所有 ZIP 解压均为手写 by_index/by_name 循环
#   （archive_utils.rs:246、archive.rs:240、backup_api.rs:1193），只创建普通文件，
#   不创建符号链接、不套用 external_attributes 的 SUID/SGID/权限位；
#   条目名经 enclosed_name()/validate_archive_entry_name()/is_safe_zip_entry_name()
#   校验，声明大小与实际字节双重限额。
#   P1 跟进：zip 9.5.1 升级批落地后立即移除本条。
ignore = ["RUSTSEC-2026-0367", "RUSTSEC-2026-0368", "RUSTSEC-2026-0369", "RUSTSEC-2026-0429"]
```

不建议把 zip 当作永久 C：这是 4 条 official security advisory，且升级路径明确。

### 5.2 unmaintained warnings（当前不阻断 CI，建议只登记说明）

`cargo audit` 默认只在 vulnerability 上 exit 1；22 项 warnings 需要 `-D warnings` 才阻断。因此当前**不必**把 unmaintained ID 加进 `ignore`，避免掩盖后续新公告。

| ID | crate@version | 引入链 | 登记理由要点 |
|---|---|---|---|
| RUSTSEC-2025-0056 | adler 1.0.2 | `genpdf 0.2.0`/`printpdf 0.3.4` → `image 0.23.14` → `tiff 0.6.1` → `miniz_oxide 0.4.4` | 仅 PDF 导出图片管线；输入为应用自身生成的图片，不解析外部 TIFF。P2：以 `printpdf 0.12` 重写导出后移除。 |
| RUSTSEC-2021-0153 | encoding 0.2.33 | `genpdf/printpdf` → `lopdf 0.26.0` | 仅 PDF 导出写面；不解析外部不可信 PDF；`genpdf 0.2.0` 已是 crates.io 最新、上游停更。P2 同上。 |
| RUSTSEC-2020-0144 | lzw 0.10.0 | 同上 | 同上（PDF LZW 编码路径）。 |
| RUSTSEC-2021-0140 | rusttype 0.8.3 | `genpdf 0.2.0` + `printpdf 0.3.4` | 仅导出字体排版；输入为系统字体/我方字体文件。P2 同上。 |
| RUSTSEC-2020-0020 | stb_truetype 0.3.1 | `rusttype 0.8.3` | 同上。 |
| RUSTSEC-2020-0056 | stdweb 0.4.20 | `time 0.2.27`（wasm32 可选依赖） | 非 wasm 目标不编译。零运行时暴露。P2 随 genpdf 链移除。 |
| RUSTSEC-2025-0057 | fxhash 0.2.1 | `scraper 0.22` → `selectors 0.26` | unmaintained 不等于存在漏洞，无 CVE。可选 B：`scraper 0.29`；选择器引擎行为变化风险高于收益，暂缓。 |
| RUSTSEC-2026-0192 | ttf-parser 0.25.1 | 直接 `lopdf 0.42.0`（`legado-book/Cargo.toml:14`） | 公告仅 unmaintained、无已知漏洞。可选 B：`lopdf 0.47.0` 改用 `skrifa`。 |

### 5.3 现有豁免保持不变

`rust/.cargo/audit.toml:7-17` 两项继续有效，升级后仍存在：
- `RUSTSEC-2026-0187` lopdf 0.26（genpdf/printpdf 链）；
- `RUSTSEC-2023-0071` rsa 0.9.10（legado-js quickjs 加密桥）。

## 六、建议批次切分

| 批次 | 内容 | 为什么独立 | 验证 | 回滚 |
|---|---|---|---|---|
| **批 1（可合一）** | rustls-webpki/webpki-roots/rustls、quinn-proto/quinn-udp、zstd、chacha20、tokio | 全部 lock-only，零源码改动；TLS 与 QUIC 同属网络栈 | `cargo audit`（应剩 5 项非豁免）；`cargo test --workspace`；真实 HTTPS 书源/RSS 冒烟 | 还原 `Cargo.lock` |
| **批 2** | rusqlite 0.41.1 + r2d2_sqlite 0.36.0（`default-features=false`）+ libsqlite3-sys 0.39.1 | DB 引擎从 SQLite 3.45 跳到 3.54，迁移/备份敏感 | `cargo test -p legado-db`；ffi 全量；DB 打开/119 版迁移/备份创建恢复冒烟 | 还原两个 manifest + lock |
| **批 3** | zip 9.5.1 + 4 处 manifest + 11 处 `name()` + 1 处泛型 | 归档解析行为与 API 双变 | `cargo test -p legado-book -p legado-js -p legado-ffi -p legado-net`；手工导入四类归档 + 备份恢复 | 还原 manifest + 代码 + lock |
| **批 4（可选 P2）** | lru 0.18.5、lopdf 0.47、scraper 0.29、genpdf→printpdf 0.12 | 各自行为敏感；genpdf 替换是功能重写 | 逐项回归 | 逐项独立提交 |

**如果必须在 zip 9 之前发布**：批 3 改为「只加 5.1 的 4 条临时 ignore + 在 audit.toml 注释中写明移除条件」，并把 zip 9 作为紧随其后的独立批。不要把它降级为永久 C。

## 附录 A：22 项 allowed warnings 全景

| 类别 | 数量 | 条目与处置 |
|---|---|---|
| unmaintained | 8 | adler、encoding、lzw、rusttype、stb_truetype、stdweb（genpdf/printpdf/lopdf 0.26 死链，暂缓）；fxhash（scraper/selectors，暂缓）；ttf-parser（lopdf 0.42，暂缓） |
| unsound | 13 | zstd-safe×10（随 zstd 0.13.5 全清）；lru×2（我方不用 `IterMut`，key 为 `String` 不会 panic Drop，实际不可达；可选升 0.18.5 清除）；tokio×1（`AsyncFd`，我方未使用；`cargo update -p tokio --precise 1.53.3` 清除） |
| yanked | 1 | chacha20 0.10.1 → 0.10.2。0.10.2（2026-08-27）修复 SSE2 后端误用 SSE4.1 intrinsic；经 `rand 0.10.2 → chacha20` 影响 `uuid`/`lopdf` 的随机源，建议必升 |

## 附录 B：复现命令

```bash
cd D:\OH-WorkSpace\LegadoTeam\legado\rust

cargo audit --no-fetch        # 现状：23 vulnerabilities / 22 allowed warnings

cargo tree -i libsqlite3-sys -e normal,build,dev
cargo tree -i quinn-proto --target all -e normal,build,dev   # nothing to print（未编译）
cargo tree -i rustls -e normal,build,dev
cargo tree -i zip -e normal,build,dev
cargo tree -i zstd -e normal,build,dev
cargo tree -i chacha20 -e normal,build,dev
cargo tree -i adler -e normal,build,dev
cargo tree -i encoding -e normal,build,dev
cargo tree -i fxhash -e normal,build,dev
cargo tree -i stdweb --target all -e normal,build,dev
cargo tree -i ttf-parser -e normal,build,dev

# 可行性 dry-run（不改 lock）
cargo update -p rustls -p rustls-webpki -p webpki-roots -n
cargo update -p quinn-proto -p quinn-udp -n
cargo update -p zstd -n
cargo update -p chacha20 -n
cargo update -p zip --precise 9.5.1 -n   # 失败：requirement zip = "^2"（需先改 manifest）
```

升级模拟方法：把 9 个 `Cargo.toml` + `Cargo.lock` 复制到临时目录（不含源码），在临时目录执行 `cargo update`，再 `cargo audit --file Cargo.lock --no-fetch`。结果：
- A 类后：5 项非豁免（libsqlite3-sys + zip×4）；
- 再升 rusqlite：4 项非豁免（zip×4）；
- 再升 zip 9.5.1：0 项非豁免，保留 audit.toml 两项豁免时 exit 0；
- 再叠加 lopdf 0.47 / scraper 0.29 / lru 0.18.5：unmaintained 从 8 降到 6、unsound 从 2 降到 0。
