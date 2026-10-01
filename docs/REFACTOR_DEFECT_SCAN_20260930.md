# 重构缺陷扫描报告（2026-09-30）

> 编写目的：全仓（flutter_legado/ + rust/，Kotlin 原版仅作参照）独立审查产出的缺陷登记与用户裁决记录。本文只保存方法、证据与裁决，**当前任务状态以 [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md) 为唯一来源**（本批登记为 P5 项，见 §五）。

## 一、审查方法

- 双轨并行独立审查（code-reviewer ×2，125/131 次工具调用），主代理对关键发现逐条抽查复核（分叉文件 grep 对照、死代码全仓裸名搜索、临时目录存在性、fail-open 位置精读）。
- 范围：`flutter_legado/lib` + `test`（Dart），`rust/` 工作区 8 crate、435 个 .rs 文件；对照 `docs/API_CONTRACT.md` 双向核对 FFI 契约（ffi.rs 276 个 pub fn vs Dart 侧 265 个调用点，零缺失）。
- 结论：**无 P0 阻塞项**；Rust 轨 2 项 P1 结构性分叉、5 项 P2 工程卫生；Flutter 轨 2 项 P2。顺带确认 HEAD 时点 B2a AppBottomSheet 迁移提交无回归。

## 二、P1：结构性分叉（用户已裁决立项，登记为 P5）

### P5-1 书源抓取核心下沉共享 crate（server/ffi 双实现合一）

- **缺陷**：`rust/legado-server/src/handlers/web_book.rs`（约 650 行 trait impl）是 `rust/legado-ffi/src/api/web_book.rs`（约 640 行 + 全文件 9214 行支撑）的能力阉割分叉版。
- **分叉证据（主代理复核）**：
  - server 版对 `acquire_source_rate_limit|webViewGetSource|verification` 零命中；ffi 版 `acquire_source_rate_limit` 有 6 处调用（每个搜索/详情/目录入口都有）+ webView 通道（web_book.rs:3018-3085）+ verification 通道 + 详情/目录变量链（`get_chapters_with_hints_and_vars`）。
  - 后果：走 REST `/api/webbook/*` 的调用方，对启用 `concurrent_rate` 或需 webView/验证码的书源，拿到与 App 主链路**不同语义**的结果。
- **原版架构佐证（2026-09-30 主代理核实）**：原版 Web 服务 handler（`app/src/main/java/io/legado/app/api/controller/BookController.kt:165,167,235`）直接调共享 `WebBook` 单例（getBookInfoAwait/getChapterListAwait/getContentAwait），server 是薄壳、核心逻辑只有一份。我方把核心长在 ffi 侧、server 复制一份，与原版架构背离。
- **根因**：`RealBookSourceFetcher` 长在 legado-ffi，legado-core 只定义了 trait 骨架，共享实现无处可放；legado-server 不依赖 legado-ffi（方向正确）。
- **方向**：将 fetcher（含 rate limit/webView/verification/变量链）下沉至 legado-core 或独立共享 crate，server/ffi 改为引用同一实现。**高风险大范围重构，按 DoD 需独立审查；未动 API_CONTRACT 冻结契约（仅内部模块移动）**。

### P5-2 loginCheckJs 逻辑双副本合一（随 P5-1 一并处理）

- **缺陷**：`rust/legado-server/src/login_check.rs:128-200`（`run_login_check_response` + `parse_login_check_completion`）是 `rust/legado-ffi/src/js_executor.rs:222-320` 的最小副本（server 源码注释自承，行 20/26/128）。当前 wrapped_code 模板与分支恰好一致，但 QuickJsEngine 构造不同（server 侧无池化），两份副本需手工同步——loginCheckJs 三叉点语义是历史最易回归区（STAGE4-P36、#702/#850 多轮修复）。
- **方向**：`execute_login_check_response` 移到 legado-core 或 legado-js，两侧引用同一实现。

### P5-1/P5-2 实施要求

- 拆分为两个可独立验证的子批（fetcher 下沉 / login_check 下沉），fetcher 批需先做 API_CONTRACT 影响评估（预期零 FFI 导出变化，但须写明）。
- 门禁：`cargo test --workspace --features quickjs`（parser/js/ffi/server 各 crate 全量）+ `cargo check --workspace --all-features` 零警告 + server 侧既有测试不丢语义（分叉期间 server 版已缺的 rate limit 门控是否回补，随下沉自然获得）。
- 验证口径：CI 结果为准（Rust 侧改动，无需设备验证）。

## 三、P2：工程卫生（本批修复，2026-09-30 派发）

| # | 位置 | 问题 | 处置 |
|---|---|---|---|
| P2-A | `rust/legado-server/src/handlers/web_book.rs:101` | 构造器死兜底：失败后用相同 config 重试再 panic，重试必然同样失败 | 删除死兜底，直接 `.expect("LegadoClient init")` |
| P2-B | `rust/legado-net/src/rate_limit.rs:57,62` | `try_acquire`/`acquire_timeout` + `OwnedSemaphorePermit` 全工作区零引用（仅自测） | 删除或 `#[cfg(test)]` 门控 |
| P2-C | `rust/legado-ffi/tmp_diag/`、`rust/_p03_norm_probe/` | 遗留临时诊断产物（probe json/dart/输出），不被任何构建引用 | 删除 |
| P2-D | `flutter_legado/lib/src/providers/bottom_bar_skin_notifier.dart:70` | `importZipFile` 及其包装的 `BottomBarSkinService.importZip` 全仓零引用（UI 走 extractZipToSession 会话化路径） | 删除 |
| P2-E | `read_record_screen.dart:283` / `offline_cache_screen.dart:263` / `welcome_screen.dart:140` / `home_tab_screen.dart:411` | 「开书路由分发」在 4 屏完整拷贝且已分叉（home_tab 缺 `_openBookInfo` 分支、welcome 用全局 navigatorKey） | 收敛为 `BookOpenUtils` 静态编排方法 |

- P2-E 注意：4 屏行为差异（welcome 全局 navigatorKey、home_tab 简化版）**须保持调用点行为等价**，只收敛实现不改行为；隔壁对话在做 P4-3 M5（reader_comic/平台通道），文件不重叠。

### 独立审查 P2 尾项处置（745d715742）

| 编号 | 处置状态 | 记录 |
|---|---|---|
| P2-1 | **已关闭** | 完成 legado-fetcher 测试夹具迁移：`source_shoujixiaoshuo_sjshuku.json`、`jhsu_book4cc_source.json`、`fixtures_95590_ch9.html`、`qmao_play_full.html` 从 `legado-ffi/tests/fixtures` 迁至 `legado-fetcher/tests/fixtures`，fetcher 源码改用本地路径，ffi 中 4 个零引用原件删除。`qmao_min_source.json` 因 ffi 仍有自身测试引用而保留，fetcher 另留独立副本，README 规定双同步。 |
| P2-2 | **已关闭** | 在 `rust/legado-ffi/src/api/source_rate_limit.rs` 与 `rust/legado-server/src/handlers/web_book.rs` 增加双宿主 `concurrentRate` registry 互认注释，明确当前不同进程/使用形态无实际双实例；未来同进程并用时若窗口分叉，统一改为静态 registry 或宿主注入 `Arc`。 |
| P2-3 | **已知开销，不立项** | REST JSON 序列化往返属于当前架构已知开销，独立审查确认不改实现、不新增任务。 |

后续 P2 候选：`rust/legado-js/src/host_api/quickjs_impl.rs:5976` 仍读取 `../legado-ffi/tests/fixtures/songhe`，属于同类跨 crate fixture 引用；本次仅登记，不实施。

## 四、裁决记录（2026-09-30 用户三项决定）

1. **P1 立项**（P5-1/P5-2）——本报告 §二。
2. **P2 派子代理修复**——本批执行 §三全部 5 项。
3. **fail-open 补告警日志（参考原版）**：
   - `rust/legado-ffi/src/api/reader.rs:88`（`is_same_title_removed` DB 故障回退 true）——主代理核实注释自承 fail-open，无日志。
   - `rust/legado-ffi/src/api/audio_api.rs:97` 附近（`with_database(...).ok().flatten()` 静默）。
   - `rust/legado-ffi/src/api/config_api.rs:49` 附近（rows.filter_map(|r| r.ok()) 静默跳过坏行）。
   - `rust/legado-ffi/src/api/explore_api.rs:116`（`let _ = explore_info_map::ensure_default(...)` 丢弃 DB 写入结果）。
   - 实现口径：按 crate 现有 `log::warn!` 惯例（backup_api.rs:179 先例）补中文告警；对高频路径（如 config_api 逐行 filter_map）**限一次告警或计数降频**，避免日志刷屏；**不改行为**（fail-open 语义保留）。
   - 原版参照：原版对应路径均有 AppLog 日志留痕（如 AppConfig.kt 的日志惯例），补日志方向与原版一致。
   - WebDAV 测试连接直发 http（`webdav_settings_screen.dart:394`）：原版将 WebDAV 协议实现抽在独立库 `lib/webdav/WebDav.kt`、App 层 AppWebDav.kt 只做编排；我方设置页 PROPFIND 探测为自包含轻量探测，与原版「设置页测试连接」入口语义一致——**裁决：维持现状，不做迁移**（记录于本文档归档，不立项）。

## 五、Active 计划登记

- 本报告缺陷项已登记至 [REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md)：
  - P5-1/P5-2（fetcher/login_check 下沉，立项未实施，待排期）
  - P2 清理批（本批实施，2026-09-30）
- 既有 P4-3 尾项（音量键翻页、点击区域编辑器等）维持原登记不变，与 P5 无重叠。

## 六、已检查无异常（覆盖面声明，摘要）

- Mock 仅在 `USE_MOCK=true` 编译开关下注入；生产路径无可达 panic/todo/unimplemented（唯一一处是 FRB 生成器模板 frb_generated.rs:10213）。
- FFI 边界 184 个导出全部 catch_unwind 包装；Dart 调用的每个 FFI 符号在 Rust 侧均有导出（零缺失）。
- 无跨 await 持 std 锁；unsafe 块 12 处目检无跨线程共享隐患；`cargo check --workspace --all-features` 零警告。
- Flutter：19 处空 catch 均带合理回退；30+ 处 firstWhere/[0]/clamp 均有守卫；MethodChannel 仅 audio_screen:866 一处 SAF 降级直连（其余经 services 封装）。

---

编写者：ZCode 主代理（审查执行：code-reviewer 子代理 ×2）｜ 2026-09-30
