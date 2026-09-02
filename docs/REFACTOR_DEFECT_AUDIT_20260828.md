# Legado 重构项目深度体检报告（只读审计）

> **[2026-09-03 整合注记]** 本报告（含复查附录）已整合至 `REFACTOR_CONSOLIDATED_AUDIT_20260903.md` 并由其替代；各项最新状态以整合报告 §三 为准。文中 §编号（§一.1/§二.5 等）被代码注释与 CI 工作流引用，继续有效。

> 审计日期：2026-08-28
> 审计性质：只读，未改动任何代码与文件
> 审计基线：当前工作树 HEAD `b855d9955`（含 7 个文件未提交改动，见 §一.3）

## 审计方式与范围

- 通读 `docs/REFACTORING_ACTIVE_PLAN.md` 与 5 份关键审计文档（RESIDUAL_RISKS / STUB_FALLBACK_CLASSIFICATION / SEARCH_PARITY_REMEDIATION_PLAN / SEARCH_PARITY_AUDIT / SOURCE_DIFF_AUDIT）；
- 对 `rust/`（8 个 crate）做关键词扫描（桩标记、unwrap/expect 密度、lock().unwrap()、static 全局、spawn_blocking、#[ignore]）与抽样代码核读；
- 对 `flutter_legado/lib/`（68 个页面文件）做同类扫描 + 路由表/平台通道/大文件清点；
- 以原版 `app/src/main/java/io/legado/app/ui/` 功能域清单逐项对照 Flutter 页面覆盖；
- 清点 CI workflow、测试结构与工作区卫生。

---

## 总体结论（TL;DR）

重构的整体完成度是扎实的：原版 20 个 UI 功能域（书架/搜索/详情/阅读/漫画/音频/视频/RSS 全家桶/规则订阅/换源/缓存/WebDAV/字典/替换规则/自动任务等）在 Flutter 侧几乎全部有对应页面，`legado-book` 书籍格式面完整（txt/epub/mobi/umd/pdf/导出），显式 TODO/桩在业务代码中极少，搜索一致性修复（P3-6）已实质推进过半。

**真正的问题集中在四处：**

1. 未提交的进行中改动有丢失风险；
2. 两个 ARM32 / 后台播放级的发布硬伤；
3. 三处注释自认的"简化实现"是真实功能缺口；
4. 测试与 CI 的门禁存在结构性盲区。

另有 169 个未跟踪临时文件污染工作区。

---

## 一、P0 级问题（发布即翻车 / 资产风险）

### 1. armeabi-v7a 的 `.so` 仍然没有 QuickJS 引擎（新证据确认）

`flutter_legado/android/app/src/main/jniLibs/armeabi-v7a/liblegado_ffi.so.meta` 明确写着 `"quickjs":false`（arm64/x86_64 的 meta 无此字段），构建时间 2026-08-28——即**当天刚重建的产物依然不带 JS 引擎**。所有 ARM32 真机上 `@js:` 规则、书源 JS 都会静默返回空结果。

`SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` §7.2 已定位为 rquickjs 平台限制并做了 `.meta` 机读化降级——但"标注降级"不是"解决"。若发版渠道包含 v7a 设备，这是功能性断裂。

**建议**：明确决策——要么解决 rquickjs 的 v7a 构建链，要么在发布矩阵里显式剔除 v7a 并在文档登记。

### 2. 后台听书缺少前台服务（新发现）

Android manifest 中唯一的 `<service>` 是 `AutoTaskJobService`；`MediaSessionBridge.kt` 全文没有 `startForeground`/前台服务逻辑（仅 PowerManager/AudioManager 调用）。`FOREGROUND_SERVICE` 权限已声明（AndroidManifest.xml:16-17）但没有任何服务组件消费它。

**后果**：应用退后台或锁屏后，音频/听书播放大概率被系统冻结——A2 验收矩阵（听书流媒体+后台续播）按当前实现验收必失败。原版有独立的 `ReadAloudService`/媒体前台服务，这一层在 Flutter 轨没有等价物。

### 3. 会话级搜索取消修复（S5/P0-3 核心成果）尚未提交

工作树 7 个文件 224+/124- 未提交改动：`rust/legado-ffi/src/api/search.rs`（会话身份复检 `is_current_session`/`clear_current_session_if_same`、累积前与持久化前防残留）、`source_switch.rs`、`web_book.rs`、`mod.rs`、`examples/scan_search_sources.rs`、`CHANGELOG.md`、`pubspec.yaml`。

这是最近 15+ 提交的搜索修复批次的收尾部分，**未提交即未入基线**：任何误操作（checkout/clean/磁盘问题）都会把"防旧会话残留写入"的修复回退到已提交状态（`07bd63089` 之前）。

**建议**：尽快完成验证并提交（属版本控制纪律，非代码改动）。

---

## 二、P1 级问题（功能正确性缺口）

### 4. 书源字体反爬解码是空壳

`rust/legado-core/src/query_ttf.rs:62` 自注"简化实现：构建基本的 ASCII 映射"——cmap 解析只做 0x20–0x7E 恒等映射，注释自己承认"真实书源反爬场景中，字体会将标准字符映射到私有区域"。即：遇到字体反爬的书源，**正文会输出乱码**，且没有任何报错。原版对这一场景有真实 cmap 解析，属解析正确性缺口，不是已声明的平台边界。

### 5. 自动任务的 Custom JS 动作不执行

`rust/legado-core/src/auto_task.rs:202` `do_custom_js` 自注"简化实现：验证脚本非空即视为成功"——返回 `(true, "Custom JS executed (N chars)")`。任务显示"执行成功"但什么都没做，是**静默假成功**。若原版 AutoTask 支持 customJs 动作，这是对齐缺口。

### 6. WebDAV PROPFIND 解析过于脆弱

`rust/legado-net/src/remote_book.rs:219` 用 `xml.split("<D:response>")` 做字符串切分。真实 WebDAV 服务器的命名空间前缀五花八门（`d:`、无前缀、自定义前缀），`<D:collection` 的 contains 判断同理——换一个不按 `D:` 前缀返回的服务器，远程书籍列表会静默变空。与 A1（WebDAV 实网验收）直接相关，**验收前建议换真实服务器（如坚果云）先自测**。

### 7. AutoTask 的 REST 降级路径是死路径且静默降级

`flutter_legado/lib/src/providers/auto_task/auto_task_notifier.dart:41` 指向 `http://127.0.0.1:8080/api/auto-tasks`，但全 `lib/` **没有任何地方调用 `serverStart`**（`rust_api.dart:1962` 定义后零调用方）——内嵌 Server 从未启动，REST 降级永远不可达；且 `loadTasks` 的 catch 里连接错误被吞掉（`_isConnectionError(e) ? null : ...`，L98-104），失败时用户看到的是空列表而非报错。

同时这条 UI→HTTP→server 通道是"数据必须经 Rust Bridge"架构约束的违例先例（虽为降级路径）。

**建议**：删除 REST 降级或补齐 server 启动前提，并让失败可见。

### 8. Server 与 FFI 两套数据库连接并存（潜伏）

`rust/legado-server/src/state.rs:12` 自带 `Mutex<Connection>`，FFI 侧 `db_state.rs:20` 有独立 `Pool`。当前 server 未启动所以未爆发，但一旦 REST 通道被启用（或 Web 服务功能开放），两条写入路径共享同一 SQLite 文件，锁竞争与可见性风险需要先设计清楚。

---

## 三、P2 级问题（健壮性与工程门禁）

### 9. JS 引擎内存限制测试在 Windows 直接跳过

`rust/legado-js/src/engine.rs:961` `#[ignore = "QuickJS memory limit test causes ACCESS_VIOLATION on Windows"]`——Windows 恰是本项目开发主平台，64MB 内存上限这条沙箱安全线**没有回归防护**（恶意书源 JS 的内存炸弹无法被测试捕获）。

### 10. CI 的 lint 与校验盲区（`.github/workflows/rust-ci.yml`）

- `cargo check/clippy/test --workspace` 全部在默认 feature 下运行，而 quickjs 门控代码有 182 处（STUB 台账 C1/C2 归并）——**clippy 从未 lint 过 quickjs 启用路径**；
- 无 `cargo fmt --check`、无 `cargo audit`；
- flutter-ci 只对 debug 模式的 aarch64+x86_64 做 FFI content hash 校验（`verify-ffi-android.sh debug`），**release 产物与 armeabi-v7a 不在校验范围内**——恰好是 §一.1 问题藏身的地方；
- `test.yml`（Android 单测）push 触发被注释，长期可能腐化。

### 11. 其余被 ignore 的测试（共 12 项）

`legado-ffi/src/api/reader.rs`（5 项）、`search.rs`（3 项）、`image_api.rs`（1 项）均为 `requires network access`，理由成立，但意味着**网络链路端到端语义主要靠 5556/5558 冒烟而非 CI**——冒烟只覆盖当前书源快照，书源失效后无告警。

### 12. Mutex 中毒级联面

生产路径 `lock().unwrap()` 共 81 处（legado-ffi/legado-net/legado-core）。Rust 惯例可接受，但一处 panic 中毒后所有后续加锁点连锁 panic；FFI 边界内的 panic 表现为功能整体不可用而非单点失败。建议至少在 `CURRENT_SEARCH_SESSION`、`TASKS` 这类全局热点锁上改用 `lock().unwrap_or_else(|e| e.into_inner())` 恢复语义。

### 13. MOBI 两个未实现项

`rust/legado-book/src/mobi.rs:21` 明示不支持 LZMA 压缩（compression=17481）与加密内容——遇到即解析失败，属可接受边界，但建议在导入失败提示中显式化（当前未验证提示文案）。

### 14. 引擎缓存容量与并发搜索不匹配（轻微）

`rust/legado-js/src/engine_cache.rs:14` `MAX_ENTRIES = 8`，而多源搜索并发 32（`SEARCH_CONCURRENCY`）。跨源并发时 LRU 抖动，缓存外的源每次 eval 仍要重挂 587KB jsLib——批次 A 的 -99.8% 实测收益在真实多源场景可能打折。可观察后决定是否按并发数调容。

---

## 四、P3 级问题（卫生与可维护性）

### 15. 工作区杂物 169 项

根目录散落约 60+ 个 `.tmp_*.py/.txt/.json` 调试脚本、`.shot_*.png` 截图、`.s0_booksource.json`、`rust/timing_book_out*.txt`、`rust/_p03_*` 系列实验驱动等，全部未跟踪也不在 `.gitignore` 内。每次 `git status` 都要人工过滤，极易误提交敏感的调试产物（书源快照、base64 转储）。

**建议**：一次性归档到 `docs/过期文档/` 或本地临时目录，并补 `.gitignore` 规则。

### 16. 超长文件（可维护性）

`book_info_screen.dart` 2162 行、`reader_config_panel.dart` 1694 行、`source_edit_screen.dart` 1633 行、`search_screen.dart` 1544 行、`other_settings_screen.dart` 1492 行、`reader_top_bar.dart` 1462 行（单个 widget 文件）、`rust_api.dart` 2929 行。无 golden 测试（`matchesGoldenFile` 零命中）——"UI 视觉可自由改"的策略下反而更需要视觉快照基线防止回归。

### 17. UI 层直连网络的先例

`auto_task_notifier.dart:7` `import 'package:http/http.dart'`（见 §二.7）。另 `reader_screen.dart:276/841` 有主 isolate `jsonDecode`（量级小暂无害，但与 P3-4 修过的"主 isolate 解码卡顿"同类模式，值得留意）。

### 18. 已声明的平台边界（非缺陷，登记在案）

- RSS 图文页 Windows/Linux 降级纯文本（`rss_article_detail_screen.dart:60`）；
- 悬浮窗播放降级全屏（`platform_bridge_service.dart:655`）；
- qrcode 桌面端相机占位（STUB 台账 D5）。

---

## 五、文档口径问题

- **`REFACTORING_ACTIVE_PLAN.md` 自身滞后于实际进度**：§三 P3-6 条目仍写"开放，未实施"，但 `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` §7.2-7.6 已记录 S1/S2/S6/S4 落地 + P0-3 会话级取消提交（`07bd63089`）+ 双包真实搜索基线验证。总表与正文矛盾，违反该计划自定的"状态口径"规则。
- **S0 四个子项 DEFERRED**（loginCheckJs 双路径 / 302 重定向最终 URL / bookUrlPattern 详情判定 / 空列表详情回退）：代码自称已对齐（如 `error.rs:41` 对齐 `LoginSourceException`），但缺定向书源验证素材，长期挂账需要台账提醒。
- **AGENTS.md 冒烟端口口径漂移**：写的是 5556/5558，实际本轮模拟器为 5554/5556（计划文档已记录，AGENTS.md 未同步）。
- A* 素材矩阵 9 项待验收状态与登记一致，无虚报。

---

## 六、验证确认的良好面（避免误伤）

- 搜索三入口解析器已统一（均走 `search_single_source → parse_search_response`），S6 驱动器分叉已消除；originOrder 已透传 `customOrder`；未提交的会话复检改动质量良好（`Arc::ptr_eq` 身份校验 + 持久化前丢弃）。
- 显式 TODO 在 Flutter 业务代码中仅 2 处（均为已登记的书架 Mock 素材项）；Rust 业务 crate 无 `unimplemented!`/`todo!`（唯一命中在 FRB 生成代码，属已登记不可达项）。
- 搜索页流订阅/定时器清理完整（`search_notifier.dart:414/568/608`）；排版引擎已用 `Isolate.run`/`compute` 隔离（`zh_layout.dart`、`paragraph_layout_engine.dart`）。
- 页面覆盖对照原版无整域缺失；原版 `ui/widget` 仅是自定义控件库（TitleBar/BatteryView 等），无对应缺口。
- `legado-book` 支持 txt/epub/mobi(azw3)/umd/pdf/archive + 导出，格式面完整（除 §三.13 两项）。

---

## 七、建议处理顺序（供决策，不含实施）

| 序 | 时机 | 事项 | 对应条目 |
|---|---|---|---|
| 1 | 立即 | 提交在途的搜索修复批次 | §一.3 |
| 2 | 立即 | 统一 Active Plan 的 P3-6 状态口径 | §五 |
| 3 | 发版前必须 | v7a quickjs 决策 | §一.1 |
| 4 | 发版前必须 | 后台播放前台服务 | §一.2 |
| 5 | 下一批次 | 字体反爬 cmap 缺口 | §二.4 |
| 6 | 下一批次 | AutoTask Custom JS 假成功 | §二.5 |
| 7 | 验收前置 | WebDAV PROPFIND 加固 | §二.6 |
| 8 | 顺手清理 | `.gitignore` + 归档 169 项杂物 | §四.15 |
| 9 | 顺手清理 | CI 补 quickjs-feature clippy 与 release/v7a hash 校验 | §三.10 |

---

## 附录：复查结论（2026-08-29）

> 复查日期：2026-08-29 ｜ 复查基线：HEAD `6314f5b215`（分支 `integration/upstream-3.26.082823`）
> 复查方式：对正文 18 条问题逐项重查当前代码/CI/文档状态（只读）。

**结论：未全部完成。18 项中仅 3 项闭环（均为"提交/文档口径"类），P0 两条发布硬伤与 P1 全部功能性缺口原样未动。**

### A. 逐项核对表

| # | 正文条目 | 状态 | 当前证据 |
|---|---|---|---|
| 1 | v7a `.so` 无 QuickJS | ❌ 未修复 | `liblegado_ffi.so.meta` 仍 `"quickjs":false`（builtAt 08-28） |
| 2 | 后台听书无前台服务 | ❌ 未修复 | manifest 仍仅 `AutoTaskJobService` 一个 service；`MediaSessionBridge.kt` 仍 0 处 `startForeground` |
| 3 | 在途搜索修复未提交 | ✅ 已闭环 | 批次已入库：`c5f82a854`（P0-3 强化取消）、`4330acaf9`（S0-E 主路径收敛）、`837516a08`（阶段三） |
| 4 | 字体反爬 cmap 空壳 | ❌ 未修复 | `query_ttf.rs:62` 仍"简化实现：构建基本的 ASCII 映射" |
| 5 | AutoTask Custom JS 假成功 | ❌ 未修复 | `auto_task.rs:202` 仍"验证脚本非空即视为成功" |
| 6 | PROPFIND split 解析 | ❌ 未修复 | `remote_book.rs:219/223` 仍是 `split("<D:response>")` |
| 7 | AutoTask REST 死路径+静默降级 | ❌ 未修复 | `serverStart` 仍零调用方；`_baseUrl:8080` 与吞连接错误逻辑不变（仅注释更详细、HTTP 客户端可注入测试） |
| 8 | Server/FFI 双 DB 连接（潜伏） | ❌ 未修复 | `server/state.rs` 仍自带 `Mutex<Database>` |
| 9 | JS 内存测试 Windows 跳过 | ❌ 未修复 | `engine.rs:961` ignore 原文不变 |
| 10 | CI 盲区 | ❌ 未修复 | clippy 仍默认 feature（无 quickjs）、无 fmt/audit；verify 仍 `debug "aarch64,x86_64"`；`test.yml` push 仍注释 |
| 11 | 网络类 ignore 测试 | — | 信息项，未变 |
| 12 | `lock().unwrap()` | ❌ 未修复 | 81 → 82 处（微增） |
| 13 | MOBI LZMA/加密未实现 | — | P2 边界项，`mobi.rs:21` 未变 |
| 14 | 引擎缓存 8 vs 并发 32 | ❌ 未变 | `MAX_ENTRIES: usize = 8` |
| 15 | 杂物与 .gitignore | ❌ 恶化 | 未跟踪 169 → 180 个；`.gitignore` 仍无 `.tmp_*` 规则 |
| 16 | 超长文件 / golden 测试 | ❌ 未修复 | golden 仍 0；`book_info_screen.dart` 2162 → 2165 行（还在增长） |
| 17 | UI 层 http import / 主 isolate jsonDecode | ❌ 未变 | `auto_task_notifier.dart:7`、`reader_screen.dart` 仍 2 处 |
| 18 | 平台边界登记 | — | 登记性条目，无需修复 |

### B. 文档口径 3 项（2 修复 1 未动）

- ✅ Active Plan P3-6 口径矛盾：已解决——`REFACTORING_ACTIVE_PLAN.md` §三 P3-6 现挂 2026-08-29 进度更新（S0-B/S0-E/P0-3 收尾/阶段三完成、S0-C 未完成标记、剩余 S0-D），与专项计划一致。
- ✅ S0 DEFERRED 台账：清晰——专项计划 §8.6 明确"重构端 7 夹具通过、原版端环境阻断（reverse 僵死/防火墙），保持 DEFERRED 不标绿"。
- ❌ AGENTS.md 冒烟端口口径：仍写 5556/5558，未同步实际 5554/5556。

### C. 清单之外的重要进展（与本文同源）

**P3-6 主线大幅推进**：离线原版响应夹具（S0-B `511a0bb52`）、主路径收敛原版 WebBook 语义（S0-E `4330acaf9`，loginCheckJs/pattern 直连/空列表回退/bookUrl 回退/去重键/非 2xx 六项对齐）、会话级取消收尾（P0-3，双机 e2e 7/7）、precision filter 解析期对齐（阶段三 `837516a08`，workspace 2479/0）。唯一遗留 S0-C（原版端终态证据）受 5558 环境阻断；剩余 S0-D 性能剖析依赖 S0-C。

### D. 复查新发现（同族问题，已登记未落 CI）

专项计划 §8.3 实测发现 jniLibs 的 `.so` 曾停留在 P0-3 之前的构建——verify 链基于 FRB content hash（只反映 FFI 签名），Rust 行为变更不改签名 → 校验恒通过、构建恒跳过、**APK 打包陈旧 .so**。即正文 §三.10"verify 范围盲区"的实锤变体。已登记整改令（Rust 行为变更后强制重跑 `build-android.ps1` + 产物版本字符串抽查），但尚未变成 CI 强制步骤。

### E. 复查后的处理顺序（维持正文 §七，微调）

1. ~~P0 两条~~ **跟进完成（2026-08-29）**：
   - §一.1 v7a quickjs：实测构建确认 `rquickjs-sys 0.9.0` 无 armv7 绑定且 bindgen 回退产物 32 位不兼容（E0277 u64:ToUsize）——**决策：发布矩阵显式剔除 v7a JS**（v7a .so 维持降级模式 + .meta 机读标注 + flutter-ci verify 告警，不阻断）；rquickjs 升级/补绑定为独立上游议题另行跟进。
   - §一.2 前台服务：已实现（`405e82a413`）——PlaybackForegroundService（mediaPlayback 类型）+ MediaSessionBridge 播放态驱动启停 + manifest 注册与权限；冒烟构建/安装/存活/无崩溃通过。**闭环**。
2. P1 三条功能缺口（§二.4 字体反爬、§二.5 Custom JS、§二.6 PROPFIND）——**§二.5/§二.6 已修复**（`bde0dddfa2` execute_auto_task_js 真实执行；`de4a69d3ea` PROPFIND 前缀无关解析，legado-net 232/0）；§二.4 cmap 按 §七 建议为下一批次。
3. **S0-C 原版端终测（同日三续）**：用户将 5558 切换为**桥接模式**（模拟器获得 LAN IP 192.168.100.61,与主机 192.168.100.52 同网段）。浏览器探针可通(marker 到达服务器 ✓),但原版 app 的 import fetch 仍未到达(可能 LDPlayer 虚拟网络对 app OkHttp 层有额外隔离)。**S0-C 原版端确认为 LDPlayer 虚拟网络环境限制,建议续作路径:①真机测试;②管理员网段路由排查;③Android Studio 官方模拟器替代 LDPlayer**。
4. **S0-C 原版端桥接模式终测（同日四续）**：桥接模式下浏览器探针可达 ✓,原版端导入探针可达 ✓(sources_json 落日志),但原版端**搜索从未调度夹具源请求**——根因:未圈范围搜索需遍历约千真实源(多数超时),夹具 7 源排列表尾部,遍历耗时远超 UI 自动化采集窗口。**结论:S0-C 原版端在 LDPlayer + 原版 release + 盲操作约束下无法自动化闭环。** 续作必需:①构建 debug 原版(需补 mavenLocal 构件)以 run-as 直导 DB;②或禁用全部真实源仅保留夹具源后重搜;③或使用 Android Studio 官方模拟器(支持 10.0.2.2 主机别名)。
4. **第二轮跟进（同日续）：§三.10 CI 盲区已补（rust-ci fmt/quickjs clippy、test.yml push 恢复、flutter-ci verify 扩展 release/v7a，`8ac2410a0c` + 全量 fmt 前置 `4518c0df71`）；§三.14 缓存容量 8→32（`e41dbd5554`）；§三.12 热点锁 CURRENT_SEARCH_SESSION 中毒恢复（同上）；§四.15 .gitignore 杂物规则（未跟踪 180→23）；§四.16 超长文件与 golden、§三.9 内存测试 Windows skip、§二.7 REST 死路径、§二.8 双 DB——登记待后续批次（涉及产品决策或大型重构）。
3. 把 §8.3 整改令落成 CI 强制步骤 + `.gitignore` 补规则（配合在途 screens 批次，及时提交）。

---

编写者：GLM-5.3-Flash ｜ 2026-08-28
复查者：GLM-5.3-Flash ｜ 2026-08-29（HEAD `6314f5b215`）
