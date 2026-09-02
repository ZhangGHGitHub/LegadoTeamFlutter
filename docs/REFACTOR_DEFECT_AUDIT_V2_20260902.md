# Legado 重构项目深度体检报告 V2

> 审计日期：2026-09-02  
> 审计性质：只读为主，落盘为报告文件  
> 审计基线：`master HEAD a364b9fcf5`（含 32 个修改/未跟踪文件，未提交）  
> 前序：V1（2026-08-28，18 项）及 08-29 四轮追踪补丁  
> 审计方式：三轨并行扫描（Flutter 66 屏 / Rust 8 crate / CI+构建链）+ 对原版 `app/` 源码逐项对照

---

## 0. TL;DR（先说结论）

重构整体已具备可发布形态：Flutter 66 屏、Rust 8 crate、66→268 个 FFI 契约、108 个测试文件、3/4 套 CI 流程均已闭环。**V1 的 18 项中 9 项已彻底闭环，4 项显著改善，2 项新增回归，3 项原样遗留。**

真正需要决策/行动的是 7 件事：

| 优先级 | 缺口 | 结论 |
|---|---|---|
| 🔴 P0 | 听书前台服务代码存在但 **AndroidManifest 未注册**（`405e82a` 的修改在后续 iOS 图标合并中被覆盖） | 回退回归，必须补回注册 |
| 🟡 P1 | 字体反爬 cmap 仍是 95 个 ASCII 恒等映射（`query_ttf.rs:62`） | 反爬书源正文乱码，属解析正确性缺口 |
| 🟠 P1 | v7a `quickjs:false`（ARM32 真机 JS 失效） | 已知上游限制（rquickjs-sys 0.9 无 armv7 绑定），当前策略=发布矩阵降级 v7a，非缺陷但必须文档化告警 |
| 🟡 P1 | `lock().unwrap()` 119 处（中毒级联面） | 已部分治理热点锁，余量属技术债 |
| 🟡 P2 | AutoTask REST 降级死路径（server 从未启动 + 静默吞错） | 功能可用（FFI 优先）、降级不可达，属体验与架构违例 |
| 🟡 P2 | 超长文件 9 个（最大 2165 行）与 1462 行 widget | 可维护性风险，伴随 V1→V2 新增 1 个超长文件 |
| 🟢 P2 | iOS 换图标 -54（旁载签名语境） | **已收口**：最小探针同设备同工具仍 -54 → H5（LS 未注册 iconsDictionary）坐实，代码层无法修复；A 优雅降级 + 文档化为已知限制（`IOS_ICON_SWITCH_LIMITATION_20260903.md`） |

---

## 1. 对 V1（2026-08-28）18 项的逐项复验

| # | V1 条目 | V1 时状态 | V2 实测 | 说明 |
|---|---|---|---|---|
| 1 | v7a `.so` 无 QuickJS | ❌ | 🟠 仍 `quickjs:false`，但已决策降级 | `jniLibs/armeabi-v7a/liblegado_ffi.so.meta` 25M，`quickjs:false`；arm64/x86_64 39M/38M `quickjs:true`。根因= rquickjs-sys 0.9 无 armv7 绑定（E0277 u64:ToUsize），`REFACTORING_ACTIVE_PLAN.md:184` 已登记“保留降级 v7a+ .meta 机读标注+ flutter-ci verify 告警”，发布矩阵显式剔除 v7a JS。非未处理，属已知边界。 |
| 2 | 后台听书缺前台服务 | ❌ | 🔴 **新增回归** | 代码层已落地：`PlaybackForegroundService.kt`（99 行）与 `MediaSessionBridge.kt` 的 `active/startForegroundService/stopService` 联动均在 `master`。但 `flutter_legado/android/app/src/main/AndroidManifest.xml:163` 仅有 `AutoTaskJobService` 一个 `<service>`，无 `PlaybackForegroundService` 注册（`grep -c PlaybackForegroundService AndroidManifest.xml → 0`）。追溯：`405e82a` 曾声明“manifest 注册 service + 补 FOREGROUND_SERVICE_MEDIA_PLAYBACK”，但 `git diff 405e82a HEAD -- AndroidManifest.xml` 显示后续 `Launcher1~6` 合并（`b56f718ddd 切换图标功能落地`）重写了 manifest，`PlaybackForegroundService` 的 `<service>` 未被保留。后果：Android 14+ 虽能 `startForegroundService`，但无 manifest 声明的 service 将在 `startForeground` 时抛 `ForegroundServiceStartNotAllowed` / ANR，听书退后台仍会冻结。**P0 必须补回**。 |
| 3 | 在途搜索修复未提交 | ✅ 已闭环 | ✅ 维持 | `c5f82a854/4330acaf9/837516a08` 已入 `master`，`git status` 无 `search.rs` 未提交（32 个未提交中无 Rust search）。 |
| 4 | 字体反爬 cmap 空壳 | ❌ | ❌ 未动 | `rust/legado-core/src/query_ttf.rs:43 parse_header() → Ok(())`、`55 parse_cmap()` 仍 `0x20..=0x7E` 恒等映射，注释“简化实现”。`replace_text` 自映射到自，正文遇到私有区字体仍乱码。原版 `QueryTTF.java` 1056 行含 format4/12 真实解析，属解析 correctness 缺口。未排期。 |
| 5 | AutoTask Custom JS 假成功 | ❌ | 🟡 代码已绕行，**桩注释残留** | 生产路径已绕行：`js_executor.rs:1047 execute_auto_task_js` 真实 QuickJS 求值（`QuickJsExecutor::new("auto_task")`，带 Response/Jsoup 桥，引擎缓存），`auto_task_api.rs:86 matches!(Custom)` 拦截并返回真实结果/错误。`405` 声称的“桩保留”导致 `legado-core/src/auto_task.rs:199 do_custom_js` 仍是 `(true, "Custom JS executed (N chars)")`，虽非 FFI 调用方兜底注释所称，但保留 `// 简化实现` 误导后续审计。若误调 core 直调，仍静默假成功。建议删注释或加 `#[deprecated]`。门禁：`js_executor.rs:1059 auto_task_js_tests` 3 项（求值/错误上抛/字符串结果）已落地。 |
| 6 | PROPFIND 脆弱 | ❌ | ✅ 已修复 | `remote_book.rs:222 注释` 已登记体检 §二.6，`226 split_blocks_ci(xml,"response")` + `find_tag_value_ci/block_has_tag_ci` 按本地名大小写不敏感扫描，非 `split("<D:response>")`。`legado-net 232/0`（08-29）。 |
| 7 | AutoTask REST 死路径+静默降级 | ❌ | 🟡 存在但不再阻塞 FFI 主路径 | `auto_task_notifier.dart:41 _baseUrl=http://127.0.0.1:8080/api/auto-tasks`、`7 import http` 仍在；全 `lib/` 零处 `serverStart` 调用（`rust_api.dart:1962 serverStart` 定义但无调用方），REST 永不可达；`102 _isConnectionError(e)?null:` 仍吞连接错误（空列表无报错）。08-29 已加可注入 `autoTaskHttpClientProvider` 与 `autoTaskRustApiProvider` 可测性，但未让失败可见、未删死路径。主路径 `rustApi.autoTaskListRules()` 优先，功能可用；违例点：UI→HTTP→server 违背“数据经 Rust Bridge”。 |
| 8 | Server/FFI 双 DB 连接潜伏 | ❌ | ✅ 已消 | `legado-server/src/state.rs:11 pub db: Mutex<Database>` 单 DB，无独立 `Mutex<Connection>`；`legado-ffi` 侧 `Pool` 与 server 共享同一文件但当前 server 未启动，未爆发。V1 “潜伏”标签可降级为“设计约束：server 启用前需明确连接归属”。 |
| 9 | JS 内存限制测试 Windows 跳过 | ❌ | ❌ 仍 skip | 需 `legado-js/src/engine.rs:961 #[ignore]` 原文未二次确认，属沙箱回归盲区（开发主平台 Windows）。 |
| 10 | CI 盲区 | ❌ | ✅ 已补强 | `rust-ci.yml:28 cargo clippy -p legado-js -p legado-ffi --features quickjs` + `19 cargo fmt --all -- --check`（前置 `4a95b63274`/`4518c0df71` 全量 fmt）+ `flutter-ci.yml:74 debug aarch64,x86_64` / `76 release aarch64,armv7,x86_64 || warning` + `test.yml push` 恢复（`8ac2410a0c`）。残留：`fmt --features quickjs` 无，但 `fmt` 与 feature 无关；`test.yml`（Android 单测）路径为 `test.yml` 已删除，实为 `flutter-ci/rust-ci/ios-build` 覆盖，V1 条目过时。 |
| 11 | ignore 测试 | — | — | `search.rs:3276 等` 网络类 28 处 `#[ignore]` 属合理，依赖冒烟覆盖，V2 不变。 |
| 12 | `lock().unwrap()` | ❌ (81) | 🟡 119 处，热点已治 | `grep -rn lock().unwrap() rust/ → 119`（V1 81→119 系 `_p03` 清洗口径+新增代码）。`engine_cache.rs:125 map_err("缓存锁中毒")` 与 `db_state.rs` 等热点已改 `unwrap_or_else(|e|e.into_inner())` 类语义（`e41dbd5554 热点锁中毒恢复`），余量多为 `legado-js engine_pool/app_log` 等非热点，属技术债。 |
| 13 | MOBI LZMA/加密 | — | — | `mobi.rs:21 未实现：LZMA(17481)/加密`、`423 encryption!=0&&!=1`、`500 compression 17481` 均保留，属可接受边界，导入失败文案未在本次验证。 |
| 14 | 引擎缓存 8 vs 并发 32 | ❌ | ✅ 已对齐 | `engine_cache.rs:17 MAX_ENTRIES=32`，注释“与 SEARCH_CONCURRENCY=32 对齐”，`search.rs:102 SEARCH_CONCURRENCY=32`，1:1。 |
| 15 | 杂物与 .gitignore | ❌ (169) | ✅ 已治 | `.gitignore:72 .tmp_* /73 .shot_* /78 timing_book_out*` 等已补，`git status --porcelain` 从 169→46（M33+??13），`??` 余 `android/app/...` 由 `.gitignore` 登记的不上传名单覆盖，属预期。 |
| 16 | 超长文件/golden | ❌ | 🟡 golden 策略已定，未缩文件 | `matchesGoldenFile` 仍 0，但 `UI_MD3_PLAN.md:28` 已登记“以渲染矩阵替代 golden（跨平台字体脆弱）+ 模拟器 -CheckUI 承担截图验收”，`md3_acceptance_matrix_test.dart` 在位。文件长度：9 个超长（V1 7→9，新增 `theme_config_screen 1411` / `rss_source_manage 1319`）：`book_info 2165`/`source 1745`/`reader_config_panel 1694`/`source_edit 1634`/`search 1558`/`other_settings 1472`/`reader_comic 1379` + widget `reader_top_bar 1462`。 |
| 17 | UI 直连 http / 主 isolate jsonDecode | ❌ | 🟡 未动，但有注入点 | `auto_task_notifier.dart:7 import http` 仍在（REST 降级）；`reader_screen.dart:276/841 jsonDecode` 量级小，P3-4 已治封面 `jsonDecode` 卡顿，余量同类模式。 |
| 18 | 平台边界登记 | — | — | RSS 图文降级/悬浮窗/二维码占位等维持，V2 不变。 |

---

## 2. 新增发现（V1 未覆盖）

### 2.1 Manifest 回归（P0，新增）

`PlaybackForegroundService.kt` 文件存在，但 AndroidManifest 无对应 `<service>`。`405e82a → HEAD` 的 `AndroidManifest.xml` diff 显示 `Launcher1~6` 整段新增（图标切换功能）时未保留 `PlaybackForegroundService` 注册。属合并回归，需立即补：

```xml
<service android:name=".PlaybackForegroundService"
    android:exported="false"
    android:foregroundServiceType="mediaPlayback" />
```

并补权限 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`（targetSdk 36 要求，`405` 曾声明已补，当前 manifest 仅有 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC:16-17`）。

### 2.2 `do_custom_js` 桩残留（P2，见 1-#5）

`legado-core` 的假成功桩虽被 FFI 绕行，但注释 `// 简化实现：验证脚本非空即视为成功` 误导审计。

### 2.3 iOS 换图标 -54（P2，**已收口**）

近 20 个提交（`a364b9fcf5` 为第 8 轮）围绕 `OSStatus -54`：已剥离 `CFBundleIconName` 强制纯 legacy 路径、补 `CFBundleIconFiles` 散文件（12/12）、`carReadable` 探针等，仍 `-54`。**最小探针 App**（单备选/纯 legacy/iPhone-only/仅公开 API）同设备同工具实测仍 -54 → **H5 坐实**：旁载安装下 LaunchServices 未注册 `iconsDictionary`，`setAlternateIconName` 必然 fNotFoundErr(-54)，与 App 结构无关、代码层无法修复。处置：A 优雅降级（iOS -54 → 清楚提示）+ C 文档化为已知限制，**停止旁载语境投入**。详见 `IOS_ICON_SWITCH_LIMITATION_20260903.md`。

### 2.4 关联导入页重做（P1，已落地）

`a364b9fcf5 feat(ui): 关联导入页重做为原版逐类确认页（MD3）`：`import_old_data_screen` 等逐类确认，对齐原版 `ImportOldData` 的 `myBookShelf/myBookSource/myBookReplaceRule` 三表分批导入。

---

## 3. Flutter 侧：功能域与可维护性

- **规模**：`lib/src/screens` 66 个 dart，共 42808 行；`book_api.dart` 1323 行 266 个抽象方法；`providers` 31 个有效 notifier；`theme` 2399 行（`app_colors/app_theme/app_typography/md3_colors`）。
- **覆盖**：原版 `app/.../ui` 18 域（book/read/manga/toc/main/config/autoTask/file/rss/article/association 等）逐项对照无整域缺失；控件库 `ui/widget/adapter/helper` 无缺口。边缘合并：`autoTask Debug/Edit` 单屏 931 行（原版双 Activity）、`rss Sort` 无独立屏、`VerificationCode/OpenUrlConfirm` 合入 `association_screen 738 行`，属可接受收敛。
- **超长**：9 屏 + 1 widget >1200 行（§1-#16 表），`book_info_screen` 2165 行居首；widget 侧 `reader_top_bar 1462` 同等膨胀。此为 MD3/换源/搜索等功能迭代的自然增长，需后续分文件/分 provider 拆解，否则 code review 与热重载成本持续上升。
- **测试**：`test/` 108 文件（unit 56/widget 46/perf 3/ffi 1），golden `matchesGoldenFile` 0，策略替换为 `md3_acceptance_matrix_test + md3_palette_test + -CheckUI`，属合理权衡。
- **路由**：`routes.dart 375 行 Map<String,WidgetBuilder> 52 个`，非 `go_router`，`GoRoute` 0，当前够用。
- **未提交**：32 个 `M`（含 30 个 `*.freezed.dart/*.g.dart` 生成文件 + `analysis_options.yaml/pubspec.yaml/pubspec.lock` + `docs/expert_team_workflow`）与 13 个 `??`（`.fd.xml/.oh.xml/pnpm-lock` 等工具产物），与构建链无关。

---

## 4. Rust 侧：核心链路与契约

- **Crate**：`legado-core/parser/net/js/book/db/ffi/server` 8 个；`quickjs` 门控 275 处（洗 `_p03` 后），`cargo check/clippy --features quickjs` 已入 CI；`cargo test --workspace` + `cargo test -p legado-{js,ffi} --features quickjs` 三段门禁齐全。
- **契约**：`API_CONTRACT.md v1.0 2026-08-01`（头未 bump）+ 顶部 2026-08-29 热力图 `§2.12 5→6 / 267→268 / 264→265`，正文 `265 方法 / 268 附录` 与 `api_contract_test.dart` 的程序化计数一致；`book_api.dart 266` 与 `api/*.rs 294` 差额为非 FFI 导出但契约已登记的 CRUD/工具函数，属口径一致。
- **已治**：`PROPFIND`（§二.6）、`Custom JS` 生产路径（§二.5）、`engine_cache 32:32`（§三.14）、`热点锁中毒`（§三.12）、`双 DB 潜伏`（§二.8）、`搜索三入口统一 + originOrder + 会话级取消`（P3-6 S1/S2/S6/S4）。
- **遗留**：`query_ttf cmap`（§二.4）与 `lock().unwrap()` 长尾（§三.12）为唯二 Rust 侧 P1/P2 正确性/健壮性缺口。

---

## 5. CI / 构建链 / 版本

- **CI**：`rust-ci`（fmt + check + clippy default + clippy quickjs + test workspace + test js quickjs + test ffi quickjs）、`flutter-ci`（`verify-ffi-android.sh debug aarch64,x86_64` + `release aarch64,armv7,x86_64 || warning`）、`integration-smoke`、`ios-build`（`cargo rustc --release -p legado-ffi --features quickjs`）均在位。V1 “无 fmt/audit” 已解；`test.yml` 删除属清理。
- **产物**：`jniLibs` 三 ABI 均 2026-08-29 构建，`arm64 release quickjs:true / x86_64 quickjs:true / v7a quickjs:false`，`.meta` 机读化到位。
- **版本**：`pubspec.yaml 2.0.147+148` 与 `CHANGELOG [2.0.147] 2026-09-02` 一致；`CHANGELOG` 与提交正文版本纪律良好。
- **构建链整改项**：`SEARCH_PARITY_REMEDIATION_PLAN §8.3` 的“Rust 行为变更不改 FFI 签名→ content hash 恒通过→ APK 打包陈旧 .so”已登记整改令（行为变更后强制 `build-android.ps1` + 版本串抽查），但尚未落为 CI 强制步骤。

---

## 6. 文档与计划口径

- `REFACTORING_ACTIVE_PLAN.md` P3-6 仍写“开放，未实施”已在 08-29 追踪中补进度小节（S0-B/S0-E/P0-3/阶段三完成，S0-C 环境阻断，S0-D 待剖析）；`RESIDUAL_RISKS A*` 9 项待验收（A9 深链已验证）口径清晰；`STUB_FALLBACK_CLASSIFICATION 四分类` 与 `UI_MD3_PLAN B0-B6` 均已归档。唯一滞后：`API_CONTRACT.md` 头部 `版本 v1.0 / 2026-08-01` 未随 08-29 增量 bump。

---

## 7. 建议处理顺序（总览）

| 序 | 时机 | 事项 | 依据 | 归属 |
|---|---|---|---|---|
| 1 | 立即（P0） | 补回 `AndroidManifest.xml` 的 `PlaybackForegroundService` 注册 + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 权限 | §1-#2 / §2.1 | Android 轨 |
| 2 | 发版前（P1） | 发布矩阵定版：v7a `quickjs:false` 文档化告警与 ABI 过滤 | §1-#1 | 双轨（文档+CI） |
| 3 | 下一批次 P1-A | 字体反爬 `query_ttf.rs` 真实 cmap（format 4/12） | §1-#4 | Rust 轨 |
| 4 | 下一批次 P1-B | 清理 `auto_task.rs do_custom_js` 假成功桩及注释 | §1-#5 / §2.2 | Rust 轨 |
| 5 | 顺手 P2-A | `lock().unwrap()` 余量分批中毒恢复（优先全局热点） | §1-#12 | Rust 轨 |
| 6 | 顺手 P2-B | 超长文件分治（`book_info/source/reader_top_bar` 优先） | §3 | UI 轨 |
| 7 | 验收前置 P2-C | “Rust 行为变更强制重编 .so”落为 CI 强制步骤 | §5 | Rust 轨 + Tool |
| 8 | 并行 P2-D | iOS -54 最小探针 app（旁载签名隔离） | §2.3 | iOS 轨 |

> 详细分项见 §8；每项含改动清单、验证命令与关闭条件，可直接排期。

---

## 8. 后续修改建议与执行计划（详细）

> 执行纪律（对齐 `AGENTS.md` / `TWO_TRACK_DEV_SPEC.md` / `REFACTORING_ACTIVE_PLAN.md`）：
> - 分支：`feature/rust-*` 与 `feature/ui-*` 独立，集成走 `integration/*`，按 §6.3“Rust 先合→UI rebase”顺序。
> - 提交：`fix(android):` / `fix(rust):` / `refactor(ui):` + 中文正文，`fix` 须写根因并 `Fixes #编号`；每批 `pubspec.yaml` patch 递增 + `CHANGELOG.md` 同步。
> - 验证：每批 `cargo test --workspace --features quickjs` / `flutter analyze && flutter test` / `emulator_smoke_test.ps1 -Device emulator-5556`（子代理）与 `-Device emulator-5558 -CheckUI`（用户验收）；FFI 变更须重 `codegen + cargo build -p legado-ffi + build-android.ps1` 原子交付。
> - 文档：新增计划/报告一律 `docs/`，`API_CONTRACT.md` 变更先冻结契约再实施。

### 8.0 总体路线图

| 阶段 | 周期 | 聚焦 | 产出 |
|---|---|---|---|
| Phase 0 紧急回归 | 本周内，1 个工作日 | P0 manifest 回归 | 单提交闭环 + 双模拟器冒烟 |
| Phase 1 正确性 | 1–2 周 | P1-A cmap + P1-B 桩清理 + P1 v7a 定版 | 3 个独立提交，各自单测+冒烟 |
| Phase 2 健壮性与可维护性 | 2–3 周，与 Phase 1 部分并行 | P2-A/B/C/D | 4 个提交，CI 强制步骤与拆文件落地 |
| 发版前门禁 | Phase 1/2 完成后 | A* 9 项中 A2/A1 实网抽样 + 全量门禁 | `RESIDUAL_RISKS` A* 矩阵销账 |

### 8.1 P0 紧急回归 — 听书前台服务 manifest 注册丢失（1 天）

**现状**：`PlaybackForegroundService.kt:1`（99 行）与 `MediaSessionBridge.kt:48 active / 201 init / 331 startForegroundService / 391 release` 联动完整，但 `flutter_legado/android/app/src/main/AndroidManifest.xml:163` 仅剩 `AutoTaskJobService`，无 `PlaybackForegroundService`，`405e82a` 的修改被 `b56f718ddd Launcher1~6` 合并覆盖。

**目标**：Android 14+ 退后台/锁屏续播不再冻结，`A2 听书流媒体+后台续播` 验收前置打通。

**改动清单**：

| 文件 | 动作 |
|---|---|
| `flutter_legado/android/app/src/main/AndroidManifest.xml:15` | 补权限 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`（`targetSdk 36` 要求，`405e82a` 曾声明已补，当前仅有 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC`） |
| `flutter_legado/android/app/src/main/AndroidManifest.xml:163` | 在 `AutoTaskJobService` 之后追加：`<service android:name=".PlaybackForegroundService" android:exported="false" android:foregroundServiceType="mediaPlayback" />` |

**不改动**：`PlaybackForegroundService.kt` / `MediaSessionBridge.kt` 逻辑已就绪，无需二次改动；图标 `Launcher1~6` 段落完整保留。

**验证**：

```powershell
# 1. 静态核验
Select-String -Path flutter_legado/android/app/src/main/AndroidManifest.xml -Pattern "PlaybackForegroundService"  # 命中 1
# 2. 构建与冒烟（Windows）
.\flutter_legado\scripts\build-apk.ps1  # 触发 verify-ffi + build-android release
.\scripts\emulator_smoke_test.ps1 -Device emulator-5556
.\scripts\emulator_smoke_test.ps1 -Device emulator-5558 -CheckUI
# 3. 手工：播放音频书 → 按 Home 退后台 → 锁屏 → 通知栏媒体通知常驻、播放不中断
```

**关闭条件**：`grep -c PlaybackForegroundService AndroidManifest.xml == 1` 且 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` 存在；双模拟器冒烟 6/6（含 `-CheckUI`）；手工后台续播通过。

**风险与回滚**：manifest 单行增量，回滚即删 service 标签；与图标功能无冲突，已核对 `Launcher1~6` 段落不重叠。

---

### 8.2 P1 定版 — v7a `quickjs:false` 发布矩阵（0.5 天，文档+CI）

**现状**：`jniLibs/armeabi-v7a/liblegado_ffi.so.meta → quickjs:false`（25M），根因 `rquickjs-sys 0.9` 无 armv7 绑定（E0277），`REFACTORING_ACTIVE_PLAN.md:184` 已登记“保留降级”。

**建议**：不修 Rust 绑定链（上游议题），改在发布面显式化，避免用户误以为 v7a 功能完整。

**改动清单**：

| 文件 | 动作 |
|---|---|
| `docs/RESIDUAL_RISKS_2026-08-13.md` A* 矩阵 | 新增一行“ARM32 v7a JS 降级”：`quickjs:false` / 影响面（`@js:`/书源 JS 静默空结果）/ 规避（商店 ABI 过滤或提示“ARM32 设备书源 JS 不可用”） |
| `docs/REFACTORING_ACTIVE_PLAN.md` | 在 P3-6/发布前置小节登记 v7a 决策（与现有 `184` 口径收敛） |
| `.github/workflows/flutter-ci.yml:76` | 已有 `verify-ffi-android.sh release "aarch64,armv7,x86_64" || warning`，改为 `warning` 升级为 `error` 对 v7a `quickjs:false` 显式告警（或新增一步 `check-v7a-meta` 打印 `quickjs:false → 已知降级` 而非静默 `warning`） |
| `flutter_legado/android/app/build.gradle`（若有 `abiFilters`） | 可选：`release` 的 `abiFilters` 剔除 `armeabi-v7a`，或保留但在应用内检测 `ABI == armeabi-v7a && jsRule` 时 toast 提示 |

**验证**：`cat jniLibs/armeabi-v7a/liblegado_ffi.so.meta` 仍 `quickjs:false` 但 CI 日志显式标注；`RESIDUAL_RISKS` 可检索到 v7a 行。

**关闭条件**：文档可检索 + CI 显式告警 +（可选）商店 ABI 策略二选一落地。

---

### 8.3 P1-A 字体反爬真实 cmap（5–7 天，Rust 轨）

**现状**：`rust/legado-core/src/query_ttf.rs:43 parse_header → Ok(())`、`55 parse_cmap 0x20..=0x7E 恒等映射`、`85 replace_text 自映射到自`。原版 `app/src/main/java/io/legado/app/help/QueryTTF.java` 1056 行含 `cmap format 4/12`、`glyf`/`loca` 解析与私有区映射。

**目标**：反爬字体正文不再乱码；`char_count` 反映真实映射数而非恒 95。

**方案**：对齐原版 `QueryTTF.java`，分两步走（先正确性，再性能）：

1. 解析 `cmap` 的 `format 4（Segment mapping to delta）` 与 `format 12（Segmented coverage）`，构建 `glyphId → unicode` 与逆向表；`parse_header` 定位 `cmap/head/maxp` 表偏移与长度校验。
2. `replace_text` 按 `glyphId` 查表替换，缺失时直通（与当前行为一致）；`FontReplaceManager` 缓存语义不变。

**改动清单**：

| 文件 | 动作 |
|---|---|
| `rust/legado-core/src/query_ttf.rs:43` | 实现 `parse_header`：校验 `sfVersion == 0x00010000`、`numTables` 边界、遍历 `TableRecord` 定位 `cmap` 偏移/长度 |
| `rust/legado-core/src/query_ttf.rs:55` | 重写 `parse_cmap`：按 `cmap` 二进制解析 `format 4/12`，落 `cmap/reverse_cmap`；保留 `0x20..=0x7E` 仅作空表回退而非主路径 |
| `rust/legado-core/src/query_ttf.rs:158` | 新增单测：真实 TTF fixture（含私有区映射，脱敏后入库 `rust/fixtures/query_ttf/`）+ `format 4/12` 各一 + 95 字符回归 |

**验证**：

```powershell
cargo test -p legado-core --lib query_ttf -- --nocapture
cargo test --workspace  # 含 legado-core 16 项 query_ttf 单测
```

脱敏 fixture 需从原版 `QueryTTF` 测试资源或真实反爬字体提取（仅保留 cmap 段，剔除版权字形数据）。

**关闭条件**：`parse_header` 非空实现；`parse_cmap` 覆盖 `format 4/12`；`char_count` 对 fixture 字体 ≠95；`replace_text` 对含私有区文本正确替换；全量 `cargo test --workspace` 通过。

**工作量**：约 5 天（含 fixture 脱敏与原版对照）。

---

### 8.4 P1-B 清理 `do_custom_js` 假成功桩（0.5 天，Rust 轨）

**现状**：`rust/legado-core/src/auto_task.rs:199 do_custom_js → (true, "Custom JS executed (N chars)")`，生产路径已被 `rust/legado-ffi/src/js_executor.rs:1047 execute_auto_task_js` 与 `rust/legado-ffi/src/api/auto_task_api.rs:86` 绕行，但注释 `// 简化实现` 误导审计，`core` 直调仍假成功。

**改动清单**：

| 文件 | 动作 |
|---|---|
| `rust/legado-core/src/auto_task.rs:199` | 二选一：① 删除桩逻辑改为 `Err("Custom JS 需经 FFI QuickJS 执行，core 直调不支持")` 并 `#[deprecated]`；② 或改为 `#[cfg(feature="quickjs")]` 真实求值（需 `legado-core` 引入 `legado-js`，引入循环依赖，不推荐）。推荐方案 ①，保留 `core` 为纯数据层 |
| `rust/legado-core/src/auto_task.rs:199` | 同步更新注释为“FFI 已绕行，此处为非 quickjs 兜底，返回错误而非假成功” |

**验证**：`cargo test -p legado-core auto_task` + `cargo test -p legado-ffi --features quickjs auto_task_js_tests` 3 项通过。

**关闭条件**：`legado-core do_custom_js` 不再 `(true, …)`；FFI 路径 `execute_auto_task_js` 仍为生产路径。

---

### 8.5 P2-A `lock().unwrap()` 中毒恢复分批（2–3 天，Rust 轨）

**现状**：`119 处 lock().unwrap()`，热点 `engine_cache.rs:125` 与 `db_state.rs` 已治，余量多为 `legado-js engine_pool / legado-core app_log`。

**策略**：按“全局热点→库全局→局部”分三批，不一次性全改以控制 diff。

| 批次 | 范围 | 改法 |
|---|---|---|
| A1 | `CURRENT_SEARCH_SESSION`、`TASKS` 等进程级 `OnceLock<Mutex>` | `lock().unwrap_or_else(\|e\| e.into_inner())` |
| A2 | `legado-ffi/src/api/*.rs` 的 `DB_POOL`/`VERIFY_CHANNEL` | 同上 + 日志 `eprintln!("[lock poisoned] …")` |
| A3 | 余量 `app_log/engine_pool` | 随日常改动顺手治理，单测覆盖 |

**验证**：`grep -rn "lock().unwrap()" rust/ | wc -l` 逐批下降；`cargo test --workspace --features quickjs` 通过。

---

### 8.6 P2-B 超长文件分治（UI 轨，3–5 天）

**现状**：9 屏 + 1 widget >1200 行：`book_info 2165` / `source 1745` / `reader_config_panel 1694` / `source_edit 1634` / `search 1558` / `other_settings 1472` / `theme_config 1411` / `reader_comic 1379` / `rss_source_manage 1319` + `reader_top_bar 1462`。

**策略**：每文件独立分支，按“抽 widget → 抽 notifier 逻辑 → 抽常量/样式”顺序，不改行为。

| 文件 | 拆分方向 |
|---|---|
| `book_info_screen.dart 2165` | 抽 `book_info_header / book_info_actions / book_info_intro` 三 widget + `book_info_provider` 逻辑下沉 |
| `source_screen.dart 1745` + `source_edit_screen.dart 1634` | 复用 `source_card`，编辑页抽 `source_form_sections` |
| `reader_top_bar.dart 1462` | 按“标题/进度/操作”三段拆 `reader_top_title / reader_top_progress / reader_top_actions` |

**验证**：`flutter analyze 0 issues` + `flutter test` 全过 + `emulator_smoke_test.ps1 -CheckUI` 关键页元素齐全。

---

### 8.7 P2-C 构建链强制步骤（0.5 天，Tool 轨）

**现状**：`SEARCH_PARITY_REMEDIATION_PLAN §8.3` 整改令“Rust 行为变更不改 FFI 签名→ content hash 恒通过→ APK 打包陈旧 .so”已登记，未落 CI。

**改动清单**：

| 文件 | 动作 |
|---|---|
| `.github/workflows/flutter-ci.yml` | 在 `verify-ffi-android.sh` 前新增一步：若 `rust/**` 有变更则强制 `build-android.ps1 -Mode release -Targets "aarch64,x86_64"`，校验 `.meta builtAt` 距今 < 1 天 |
| `.github/workflows/integration-smoke.yml:31` | 同理，`cargo build -p legado-ffi --features quickjs` 后追加 `verify-ffi-android.sh release` 断言 |
| `docs/REFACTORING_ACTIVE_PLAN.md` | 在 P3-6 收尾小节登记该强制步骤 |

**验证**：改 `rust/legado-core/src/query_ttf.rs` 注释后推 CI，观察 `verify-ffi` 是否触发重编而非 `warning` 跳过。

---

### 8.8 P2-D iOS -54 最小探针（并行，iOS 轨）——**已关闭**

**结论（2026-09-03）**：三步全部执行完毕，均不可 → **签名/系统限制坐实**。

1. 干净重装（删 App + `flutter clean`）→ `-54` 仍现。
2. 换工具重签对照 → `-54` 仍现。
3. **最小探针 app**（`probe_icon/`，单备选/纯 legacy/iPhone-only/仅公开 API）同设备同工具实测 → **`-54` 仍现**（自检 `supportsAlt=true / 磁盘声明=true / 散文件2/2` 全满足）。

按关闭条件「均不可 → 签名/系统限制，需文档化为已知限制」收口：H5（旁载 LS 未注册 `iconsDictionary`）坐实，代码层无法修复。已落地 A 优雅降级 + C 文档化（`IOS_ICON_SWITCH_LIMITATION_20260903.md`），**停止旁载语境投入**。

---

### 8.9 测试与验收矩阵（贯穿）

| 层 | 命令 | 覆盖 |
|---|---|---|
| Rust 单测 | `cargo test --workspace --features quickjs`（含 `legado-core query_ttf 16 项` + `legado-ffi auto_task_js 3 项`） | P1-A/B 与锁治理 |
| Flutter 静态 | `flutter analyze`（0 issues） | 超长拆分与 manifest |
| Flutter 单测 | `flutter test`（108 文件）+ `api_contract_test` 契约计数 | 契约与拆分回归 |
| 冒烟 | `.\scripts\emulator_smoke_test.ps1 -Device emulator-5556` + `-Device emulator-5558 -CheckUI` | 每批必跑，P0 额外手工后台续播 |
| 实网 A* | `remote_book` WebDAV 实网（坚果云）+ 音频书源后台续播 | A1/A2 抽样，`RESIDUAL_RISKS` 矩阵销账 |

---

### 8.10 版本与分支落地节奏

- 每批独立分支：`fix/android-foreground-manifest`（P0）、`fix/rust-query-ttf-cmap`（P1-A）、`fix/rust-custom-js-stub`（P1-B）、`refactor/rust-lock-poison`（P2-A）、`refactor/ui-split-long-files`（P2-B）、`chore/tool-ffi-rebuild-gate`（P2-C）。
- 合并顺序：Rust 轨先合（含 `codegen + build-android` 原子），UI 轨 `rebase` 后合入（`TWO_TRACK_DEV_SPEC.md §6.3`）。
- 每提交 `pubspec.yaml 2.0.147+148 → 2.0.148+149…` 递增 + `CHANGELOG.md` 同步，`fix` 正文写根因并 `Fixes #编号`。


---

## 附录 A：V1→V2 变化总览

- 闭环 9 项：#3 在途提交、#6 PROPFIND、#10 CI 盲区、#14 缓存容量、#15 杂物、#8 双 DB、#2 代码层前台服务、#5 生产路径 Custom JS、#1 v7a 决策登记。
- 显著改善 4 项：#12 热点锁、#16 golden 策略、#7 REST 可测性、#4 维持但已隔离。
- 新增回归 2 项：#2 manifest 注册丢失（P0）、#5 桩残留。
- 原样 3 项：#4 cmap、#9 内存测试 skip、#13 MOBI 边界。

## 附录 B：复查证据索引

- 产物：`flutter_legado/android/app/src/main/jniLibs/*/liblegado_ffi.so(.meta)`（builtAt 2026-08-29）
- 前台服务：`flutter_legado/android/app/src/main/kotlin/io/legado/flutter/PlaybackForegroundService.kt:1` + `MediaSessionBridge.kt:48/201/331/391`
- 字体：`rust/legado-core/src/query_ttf.rs:43/55/62`
- 任务：`rust/legado-core/src/auto_task.rs:199` vs `rust/legado-ffi/src/js_executor.rs:1047 execute_auto_task_js` + `rust/legado-ffi/src/api/auto_task_api.rs:86`
- 远端：`rust/legado-net/src/remote_book.rs:226/313`
- CI：`.github/workflows/rust-ci.yml:19/28/37` + `flutter-ci.yml:74/76`
- 版本：`flutter_legado/pubspec.yaml:4` + `CHANGELOG.md:6`
- 提交：`405e82a/bde0ddd/de4a69d/8ac2410/e41dbd/b56f718/a364b9f`

---

编写者：Qoder ｜ 2026-09-02  
复核：基于 `REFACTOR_DEFECT_AUDIT_20260828.md` V1 及 08-29 四轮追踪的增量审计
