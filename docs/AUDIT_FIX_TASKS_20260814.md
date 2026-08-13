# Legado 重构审计修复任务清单（2026-08-14）

> **配套文档**：[REFACTORING_AUDIT_REPORT_20260814.md](REFACTORING_AUDIT_REPORT_20260814.md)（审计结论与证据）
> **本文档定位**：将审计报告的 3 P0 / 12 P1 / 21 P2 / 12 P3 缺陷拆解为可执行修复任务，供后续批次排期执行。
> **性质**：任务计划文档（非代码改动）。执行时须遵守 AGENTS.md 全部规范。

---

## 〇、使用说明与执行规范

### 0.1 任务编号与字段

- 任务编号：`F<批次>-<序号>`（如 F1-1 = 第一批第 1 项）。
- 轨道标注：`[Rust]` / `[UI]` / `[双轨]`（Rust+UI 跨轨）/ `[工程]`（git/CI/配置）/ `[文档]`。
- 工作量：S ≤0.5 天 ｜ M 1–2 天 ｜ L 3–5 天 ｜ XL >1 周（估算，供排期参考）。
- 状态：⬜ 待办 ｜ 🔄 进行中 ｜ ✅ 完成（执行时维护）。

### 0.2 执行前必读（规范路由）

1. **契约先行**：任何涉及 Rust/Dart FFI 边界的任务，先更新 `docs/API_CONTRACT.md` 再实施；跨轨阻塞项 Rust 轨先行交付契约。
2. **红线**：禁止新增原版不存在的创意功能；偏离项清理须按用户决策执行，不得擅自保留或删除。
3. **超范围禁止**：仅处理本清单任务范围内的文件；删除/修改文件前确认范围。
4. **分批提交**：跨轨改动分批提交，`[Rust]` / `[UI]` 前缀标注；每批完成同步 CHANGELOG（版本 patch 递增）与相关文档。
5. **验证门禁**（每批完成后）：
   - Rust：`cargo test --workspace` + `cargo test -p legado-ffi --features quickjs` + `cargo clippy --workspace -- -D warnings` + `cargo fmt --check`
   - Flutter：`flutter analyze`（0 error）+ `flutter test` 全量通过
   - 冒烟：`.\scripts\emulator_smoke_test.ps1 -Device emulator-5556`（子代理）；用户验收前 `-Device emulator-5558 -CheckUI`
6. **文档同步**：每批完成后更新本文档状态列、REMAINING 台账与 README「当前状态」。

---

## 一、需用户决策项（先行，阻塞对应任务）

| ID | 决策项 | 来源缺陷 | 选项 | 阻塞任务 |
|---|---|---|---|---|
| D1 | **阅读统计子系统去留** | P1-7 | A. 彻底清理（Rust 核心+reading_sessions 表+服务端 /stats 路由+FFI 全删）｜ B. 正式豁免保留（更新 AGENTS.md 红线豁免清单） | F2-7、F3-15 |
| D2 | **users 表去留** | P1-8 | A. 删除（原版无此表）｜ B. 豁免 + 密码改哈希存储 | F2-8 |
| D3 | **eval/Function 沙箱策略** | D4 | A. 维持生产启用（对齐原版 Rhino，更新 README/沙箱文档）｜ B. 严格沙箱禁用（评估书源兼容性影响） | F3-4 |
| D4 | **video_play_utils 解析逻辑** | D17 | A. 下沉 Rust（video 解析 FFI 化）｜ B. 登记豁免（UI 轨保留，契约注明） | F3-13 |
| D5 | **l10n 推进范围** | P3-7 | A. 全面国际化 ｜ B. 维持中文主语言现状（仅登记） | F4-7 |
| D6 | **legado.jks 是否真实密钥** | P0-3 | A. 真实 release 密钥 → 立即轮换 ｜ B. 测试占位 → 移除出库即可 | F1-3 |

---

## 二、第一批（P0，立即执行）

### F1-1 `[Rust]` 修复 html.rs 元素选择回归（词典查词损坏）
- **来源**：P0-1（回归由 `6bb18abb9` 引入）
- **涉及文件**：`rust/legado-parser/src/html.rs`、`rust/legado-ffi/src/api/dict_api.rs`（测试）
- **实施要点**：
  1. 复核 `6bb18abb9` 中「选择器命中含自身」改动（`selector.matches(elem)` 提前入列）对 `extract_from_doc`/`extract_chained` 的影响；
  2. 修复 `#def` 等 ID 选择器文本提取（保留思路客 `.page-link@a@href` 修复语义，二者需兼容）；
  3. 补回归测试：dict `test_lookup_show_rule_css` + 通用 CSS ID/类选择器提取用例 + 思路客 `.page-link@a@href` 用例。
- **验收**：`cargo test -p legado-ffi --features quickjs --lib` 全绿；`cargo test --workspace` 零失败；dict 与思路客相关用例同过。
- **工作量**：M ｜ **前置**：无 ｜ **状态**：✅（根因：`AnalyzeUrl` 对 data: URI 误用 page/angle 替换破坏 HTML 载荷；已豁免并补回归测试）

### F1-2 `[UI]` 删除孤儿死文件 reading_stats_screen.dart
- **来源**：P0-2
- **涉及文件**：`flutter_legado/lib/src/screens/reading_stats_screen.dart`（删除）、`flutter_legado/lib/src/l10n/app_strings.dart:161`（`readingStats` 死条目）、`flutter_legado/lib/src/routes.dart:77/199`（`/reading_stats` 别名保留或同步移除）
- **实施要点**：删除文件后确认全 lib 无引用；`/reading_stats` 别名路由若保留须确认仍重定向 ReadRecordScreen。
- **验收**：`flutter analyze` **0 error**（该文件为 14 个 error 唯一来源）；`flutter test` 全绿。
- **工作量**：S ｜ **前置**：无 ｜ **状态**：✅

### F1-3 `[工程]` legado.jks 签名库核验与移除
- **来源**：P0-3（需先决策 D6）
- **涉及文件**：`.github/workflows/legado.jks`（移除出库）、`.gitignore`（追加 `*.jks`/`*.keystore`）、release.yml/BetaRelease.yml（确认仅走 secrets）
- **实施要点**：keytool 核验密钥内容与密码保护；无论是否真实密钥均从 git 历史移除（`git rm --cached` + 历史清理或标注）；CI 签名改 secrets 注入（现有 RELEASE_KEY_STORE 机制）。
- **验收**：仓库无 jks/keystore 文件；`.gitignore` 覆盖；release 流程经 secrets 正常签名。
- **工作量**：S ｜ **前置**：D6 决策 ｜ **状态**：✅（D6=B 测试占位；`git rm --cached` + `.gitignore`；test.yml 改 secrets 注入）

---

## 三、第二批（P1，本周）

### F2-1 `[双轨]` 书架拖拽排序持久化
- **来源**：P1-1
- **涉及文件**：`rust/legado-ffi/src/`（新增排序持久化 FFI）、`docs/API_CONTRACT.md`（契约先行）、`flutter_legado/lib/src/services/book_api.dart` / `rust_api.dart` / `mock_book_api.dart`、`bookshelf_notifier.dart:155-172`、`bookshelf_screen.dart:338-342`
- **实施要点**：契约登记书籍排序接口（对齐原版 sort 语义）→ Rust 实现（books 表 order 字段持久化）→ FRB codegen（`make gen`）→ UI 接线 reorderBook。
- **验收**：拖拽排序后重启应用排序保持；契约/双实现同步；`flutter test` 新增排序持久化用例。
- **工作量**：L ｜ **前置**：无 ｜ **状态**：✅（`reorderBooks` FFI + BookshelfNotifier 持久化接线）

### F2-2 `[双轨]` 换源页三个假开关处理
- **来源**：P1-2
- **涉及文件**：`flutter_legado/lib/src/screens/change_source_screen.dart:125-131/375-387`、`rust/legado-ffi/src/api/source_switch.rs`（如需接线）
- **实施要点**：二选一——① Rust 侧实现 `changeSourceLoadWordCount/LoadInfo/LoadToc` 消费逻辑（对齐原版 search 时加载选项）并接线 `_search()`；② 若原版语义不适用，移除开关并登记说明。不可保留假开关。
- **验收**：三开关有实际效果或已移除；UI 无误导性控件；契约同步。
- **工作量**：M ｜ **前置**：无 ｜ **状态**：✅（`source_switch_search` 第四参 options_json + loadInfo/loadToc/loadWordCount enrichment + wordCountComparator 排序；Flutter 传参/重搜/UI 展示）

### F2-3 `[双轨]` 按书清缓存 FFI 补齐
- **来源**：P1-3
- **涉及文件**：`docs/API_CONTRACT.md`、`rust/legado-ffi/src/api/cache_api.rs`（新增 `clear_book_cache`）、`book_api.dart`/`rust_api.dart`/`mock_book_api.dart`、`book_info_screen.dart:1588-1609`
- **实施要点**：契约登记 → Rust 实现按 bookUrl 清缓存（对齐 BookCacheManager.clear）→ FRB codegen → UI 移除全局降级对话框。
- **验收**：详情页「清除缓存」仅清该书；契约/三实现同步；`flutter test` 新增用例。
- **工作量**：M ｜ **前置**：无 ｜ **状态**：✅（`clearBookCache` FFI + 书籍详情页按书清缓存）

### F2-4 `[文档]` quickjs 构建口径修正
- **来源**：P1-4（2 个失败测试由此而来）
- **涉及文件**：`rust/README.md`（构建命令补 `--features quickjs`）、`docs/REFACTORING_REMAINING_PLAN.md` 质量门禁（`cargo test` → `cargo test -p legado-ffi --features quickjs`）、`rust/legado-js/Cargo.toml`（评估默认 feature 或保留并在文档显著警示）
- **实施要点**：文档明确「不带 quickjs 的构建 = JS 书源全不可用（Stub 降级）」；质量门禁命令统一。
- **验收**：按文档命令可复现全量测试通过；README 无误导性构建指引。
- **工作量**：S ｜ **前置**：无 ｜ **状态**：✅

### F2-5 `[CI]` rust-ci 补 legado-ffi 全量测试覆盖
- **来源**：P1-5（P0-1 回归 CI 无感知的根因）
- **涉及文件**：`.github/workflows/rust-ci.yml`
- **实施要点**：新增 job `cargo test -p legado-ffi --features quickjs`（全量，非 js_executor 子集）；clippy 覆盖 legado-ffi（或单独 job 处理现有 warning）。
- **验收**：CI 全量跑 legado-ffi 测试；本次 P0-1 类回归可被 CI 拦截。
- **工作量**：S ｜ **前置**：F1-1（否则 CI 必红）｜ **状态**：✅

### F2-6 `[工程]` .cargo/config.toml 跨平台修复
- **来源**：P1-6
- **涉及文件**：`rust/.cargo/config.toml`
- **实施要点**：移除仓库级 Windows NDK 路径与 `replace-with = "ustc"` 镜像绑定；本机 NDK 配置移到用户级 `%USERPROFILE%\.cargo\config.toml` 或 CI 环境变量注入。
- **验收**：ubuntu CI 可交叉编译 Android target；Windows 本机构建不受影响。
- **工作量**：S ｜ **前置**：无 ｜ **状态**：✅

### F2-7 `[Rust]` 阅读统计子系统处理
- **来源**：P1-7（需先决策 D1）
- **涉及文件**：方案 A（清理）：`rust/legado-core/src/reading_stats.rs`、`rust/legado-db/src/repository/reading_stats_repository.rs`、`legado-db/src/schema.rs:454-466`（表+索引）、`rust/legado-ffi/src/api/reading_stats_api.rs`、`ffi.rs:1288-1309`、`rust/legado-server/src/handlers/stats.rs` + `routes.rs:88-92`、`book_api.dart:800-815` 死契约面；方案 B（豁免）：仅更新 AGENTS.md 豁免清单 + 补契约登记。
- **实施要点**：按 D1 决策执行；若清理，同步删 Flutter 侧 `book_api.dart` 阅读统计方法与 mock 实现。
- **验收**：按所选方案，仓库无半成品残留；`cargo test --workspace` 全绿。
- **工作量**：L（A）/ S（B）｜ **前置**：D1 ｜ **状态**：✅（D1=A：删 reading_stats 子系统+reading_sessions 表+server /stats+FFI；保留 recordReadingTime/readRecord；reader 内 LiveReadingStats 仅内存）

### F2-8 `[Rust]` users 表处理
- **来源**：P1-8（需先决策 D2）
- **涉及文件**：方案 A（删除）：`schema.rs:73` CREATE_USERS、`user_repository.rs`、`user_api.rs`、`book_api.dart:877-896` 死契约面；方案 B（豁免）：密码改哈希（argon2/bcrypt）+ 契约登记。
- **实施要点**：按 D2 决策执行；若删除，注意 RESIDUAL「users vs servers」说明同步更新。
- **验收**：仓库无明文密码存储路径；相关测试全绿。
- **工作量**：M ｜ **前置**：D2 ｜ **状态**：✅（D2=A：删 users 表+UserRepository+FFI 6 函数+契约/mock）

### F2-9 `[工程]` 分支合入与悬空变更提交
- **来源**：P1-9、P1-10（部分）
- **涉及文件**：git 操作（无代码改动）
- **实施要点**：① 确认并提交 75 个删除（含 repowiki 废弃、根目录历史垃圾）；② 提交真实测试 `offline_cache_screen_test.dart`；③ feature/rust-core → master 合入（或创建 `integration/*` 承接，按 AGENTS.md 分支策略）；④ 核对 master 与上游 #672 同步状态。
- **验收**：master 承接全部近期成果；`git status` 无悬空删除；工作树收敛到可预期状态。
- **工作量**：M ｜ **前置**：F1-1/F1-2（先让 master 处于绿态）｜ **状态**：✅（fast-forward 合入 master @ `85b013d22`；`integration/audit-fix-20260814` 与 master 同 HEAD）

### F2-10 `[工程]` .gitignore 补全与仓库垃圾清理
- **来源**：P1-10
- **涉及文件**：`.gitignore`、根目录 `tmp_*`、`tmp_debug/`、`tmp_device_probe/`、`expired_2026-08/`、`_debug_51manga/`、`flutter_legado/legado.db*`（已跟踪，应 untrack）、`docs/screenshots/v1_3/legado.db`、`scripts/_tmp_*`
- **实施要点**：.gitignore 追加 `tmp_debug/`、`expired_2026-08/`、`tmp_*`、`*.db`/`*.db-shm`/`*.db-wal`（保留测试夹具白名单例外）；对已跟踪的 runtime DB 执行 untrack；临时调试物清理或归档。
- **验收**：`git status` 未跟踪条目大幅收敛（仅剩有意文件）；CI 不受影响。
- **工作量**：M ｜ **前置**：无 ｜ **状态**：✅（.gitignore 补全 tmp/db 规则；runtime DB 与 tmp_diff 等已 untrack/移除跟踪）

### F2-11 `[文档]` README 死代码口径修正
- **来源**：P1-11
- **涉及文件**：`docs/README.md:37`
- **实施要点**：将 `getAudioChapterMedia` 从「死代码 fallback」清单移除，改为「在用真实 FFI（音频书取址链路）」；仅保留 scanLocalBooks/parseTxt 死代码标注。
- **验收**：README 口径与代码事实一致，不会再误导清理决策。
- **工作量**：S ｜ **前置**：无 ｜ **状态**：✅

### F2-12 `[工程]` .qoder/agents/builtin 还原
- **来源**：P1-12
- **涉及文件**：`.qoder/agents/builtin/{code-reviewer,full-stack-engineer,qa,researcher,ui-operator}.md`
- **实施要点**：`git checkout -- <5 文件>` 还原为产品版本；若确需项目定制，创建到 `.qoder/agents/`（非 builtin）。
- **验收**：5 文件工作树恢复干净；`git status` 无 builtin 改动。
- **工作量**：S ｜ **前置**：无 ｜ **状态**：✅

---

## 四、第三批（P2，排期）

### F3-1 `[Rust]` FFI 层 unwrap/expect 收敛
- **来源**：D1
- **涉及文件**：`webdav_api.rs`（9 处 `thread::Builder...build().unwrap()`）、`server_api.rs`（5 处 expect 含 mutex 中毒）、`http_state.rs`/`net_api.rs`（锁 unwrap）
- **实施要点**：改为 `map_err` 返回 BridgeError/LegadoError；mutex 中毒用 `poisoned.into_inner()` 恢复或返回错误。
- **验收**：FFI 生产代码零 unwrap/expect（测试模块除外）；`cargo test --workspace` 全绿。
- **工作量**：M ｜ **前置**：无 ｜ **状态**：✅（webdav/server/http_state/net_api 生产路径已收敛；shared_client 初始化失败仍 panic 兜底，待后续改 Result）

### F3-2 `[Rust]` check_syntax 超时与内存上限
- **来源**：D2
- **涉及文件**：`legado-js/src/engine.rs:452-459`、`js_source_config.rs:388`（调用点）
- **实施要点**：`check_syntax` 独立 Runtime 设置 interrupt 超时（对齐 5s 基线）+ 内存上限；病态输入返回错误而非挂起。
- **验收**：超长/深嵌套 JS 语法检查有限时返回；新增超时测试。
- **工作量**：M ｜ **前置**：无

### F3-3 `[Rust]` 沙箱死配置处置
- **来源**：D3
- **涉及文件**：`sandbox.rs`（`max_stack_depth`、`allow_network`、`ALLOWED_GLOBALS` 白名单）
- **实施要点**：三选一逐项处理——实现（栈深度经 rquickjs 能力落地/网络按配置门控/白名单实际应用）或删除配置字段与文档声明（避免死配置误导）。
- **验收**：README 声称的安全项与代码一致；无 `#[allow(dead_code)]` 白名单。
- **工作量**：M ｜ **前置**：D3（策略相关）

### F3-4 `[文档]` 沙箱文档与实现对齐
- **来源**：D4（需先决策 D3）
- **涉及文件**：`rust/legado-js/README.md`、`sandbox.rs` 模块文档、`docs/README.md`（如涉及）
- **实施要点**：按 D3 决策统一「eval/Function 实际策略」表述（生产启用 or 禁用），消除文档与代码矛盾。
- **验收**：文档描述与 `engine_pool.rs:43`/`js_executor.rs` 实际行为一致。
- **工作量**：S ｜ **前置**：D3 ｜ **状态**：✅（D3=A：sandbox.rs + rust/README 书源路径 eval/Function 启用口径；js_eval 严格入口分离）

### F3-5 `[Rust]` FFI 非 Result 导出改造
- **来源**：D5
- **涉及文件**：`ffi.rs`（version/backup_list/server_stop/server_status/archive_is_archive/auto_task_normalize_script/auto_task_can_refresh_toc/auto_task_next_due_at/audio_with_play_mode 共 9 个）
- **实施要点**：改为返回 Result（契约 §3.3 对齐）或在契约登记豁免（只读查询吞错语义）；同步 Dart 侧调用点。
- **验收**：契约与实现一致；`cargo test -p legado-ffi --features quickjs` 全绿。
- **工作量**：M ｜ **前置**：无

### F3-6 `[Rust]` 引擎池状态串扰治理
- **来源**：D6
- **涉及文件**：`js_executor.rs:244-247/330-334`、`engine_pool.rs`
- **实施要点**：payAction/login/explore 等非主路径调用改为每次新建引擎（对齐 v1.36 主路径策略）或按调用链隔离 tag；评估 `main_js_loaded` 按实例缓存跳过重载问题。
- **验收**：同一书源不同调用链无 JS 全局残留串扰；相关回归测试。
- **工作量**：M ｜ **前置**：无

### F3-7 `[Rust]` 死模块/桩清理
- **来源**：D7
- **涉及文件**：`rust/legacy-ffi/`（孤儿目录，物理删除或归档）、`legado-js/src/context.rs`、`scope.rs`、`legado-core/src/ffi_macros.rs`、`ffi.rs:1060`（`let _ = &rule_type` 桩）
- **实施要点**：逐一确认零生产引用后删除；`parse_rule` 补 rule_type 使用或移除参数。
- **验收**：`cargo test --workspace` 全绿；无死代码告警（legado-ffi clippy 含入后零警告）。
- **工作量**：M ｜ **前置**：无

### F3-8 `[Rust]` 瞬态字段落库治理
- **来源**：D8
- **涉及文件**：`rust/legado-db/`（infoHtml/tocHtml/downloadUrls 字段）
- **实施要点**：评估改存 KV/缓存或保留；若保留，契约注明瞬态语义。
- **验收**：数据语义明确；无异常行为。
- **工作量**：S ｜ **前置**：无

### F3-9 `[Rust]` 编码检测计划对齐（chardetng）
- **来源**：D9
- **涉及文件**：`legado-book/src/encoding.rs`
- **实施要点**：评估自研启发式与 chardetng 覆盖差异；若等价，登记计划文字偏差即可，不必强改。
- **验收**：GBK/GB2312/UTF-8 检测用例通过。
- **工作量**：S ｜ **前置**：无

### F3-10 `[文档]` 契约文档全面同步
- **来源**：D10/D11/D12/D12b
- **涉及文件**：`docs/API_CONTRACT.md`
- **实施要点**：① 方法数 237→257 及附录合计 248→实测值；② §2.3/2.4/2.5/2.9/2.11/2.43 标题/表格/附录三方对齐；③ 补登记 `fetchImageWithDecode`/`rssClearArticles`/`sourceCallBackBtn`；④ `taskId` 改数字语义；⑤ 命名等价差异 8 对加注说明。
- **验收**：契约与 BookApi 257 方法一一对应；附录合计正确。
- **工作量**：M ｜ **前置**：无

### F3-11 `[文档]` 测试/版本口径统一
- **来源**：D13/D14/D15
- **涉及文件**：`docs/README.md`、`docs/REFACTORING_REMAINING_PLAN.md`、`docs/REFACTORING_AUDIT_REPORT_20260806.md` 等
- **实施要点**：统一测试数（以实测为准：Rust workspace 全量 + quickjs 547 + Flutter 1209）；修正「约 3400」算术；对账原子任务 148/168；统一版本口径（2.0.x 系列）。
- **验收**：各文档量化声明互洽且与实测一致。
- **工作量**：M ｜ **前置**：F2-4（测试口径基准确定）｜ **状态**：✅（docs/README.md 门禁口径：ffi quickjs 311 + flutter 1171）

### F3-12 `[文档]` 根 README 更新
- **来源**：D16
- **涉及文件**：`README.md`（根）
- **实施要点**：版本（v4.0.0-alpha → 2.0.x）、页面数（18 → 实际）、CI 徽标仓库链接（废弃仓库 → 当前仓库）。
- **验收**：根 README 与现状一致。
- **工作量**：S ｜ **前置**：无

### F3-13 `[双轨]` video_play_utils 逻辑下沉
- **来源**：D17（需先决策 D4）
- **涉及文件**：方案 A：`rust/legado-ffi/src/`（新增 video 解析 FFI，对齐 AnalyzeUrl/VideoPlay）、`docs/API_CONTRACT.md`、`video_play_utils.dart`（改调 FFI）、`video_screen.dart`、`test/unit/video_url_resolve_test.dart`（迁移 Rust 测试）；方案 B：登记豁免。
- **实施要点**：按 D4 决策执行；下沉时保留现有播放行为不回退。
- **验收**：播放行为与原实现等价；契约同步。
- **工作量**：L（A）/ S（B）｜ **前置**：D4 ｜ **状态**：✅（D4=B：API_CONTRACT 登记 Flutter `video_play_utils` 豁免）

### F3-14 `[双轨]` 裸 http 收敛到 Rust 网络层
- **来源**：D17（8 处：auto_task_screen:631、rule_sub_screen:496、audio_screen:940、reader_comic_screen:1259、replace_rules_screen:497、rss_source_manage_screen:1092、association_notifier:7、source_import_service:105/250）
- **涉及文件**：上述 8 处 + `rust/legado-net`（新增通用 fetch FFI 或复用既有能力）+ 契约
- **实施要点**：逐处改为经 Rust Bridge 请求（统一 UA/Cookie/超时/限流语义）；无对应 FFI 的先补契约。
- **验收**：UI 层零裸 http；请求行为与改造前等价。
- **工作量**：L ｜ **前置**：无

### F3-15 `[双轨]` 死文件/死契约面清理
- **来源**：D18
- **涉及文件**：`comic_reader_screen.dart`（删除）、段评 CRUD 死面（`book_api.dart:974-999` + `ffi.dart:1370-1398` + `rust_api.dart:2156-2183` + `mock_book_api.dart:1902-1918` + `review_api.rs:18-83`）、阅读统计死面（随 D1 一并处理）
- **实施要点**：确认零 UI 调用后删除或按 D1 决策保留。
- **验收**：无死契约面残留；`flutter analyze` 0 error。
- **工作量**：M ｜ **前置**：D1（阅读统计部分）｜ **状态**：⏳（已删 `comic_reader_screen.dart` + 孤儿 `comic_reader_test.dart`；本地段评 CRUD 死契约面待 FRB 移除）

### F3-16 `[双轨]` 页面覆盖缺口处置
- **来源**：D19
- **涉及文件**：`HandleFileActivity`（Android 专属，评估深链/插件方案或登记 N/A）、`RssSortActivity`（Flutter 补排序页或登记降级说明）
- **实施要点**：每项二选一——实现或登记「N/A/降级」说明至 SOURCE_DIFF。
- **验收**：SOURCE_DIFF 覆盖表如实记录两项状态。
- **工作量**：M ｜ **前置**：无

### F3-17 `[双轨]` RSS 阅读记录按源查询 FFI
- **来源**：D21
- **涉及文件**：`docs/API_CONTRACT.md`、`rust/legado-ffi/src/api/rss_api.rs`（新增 `get_records_by_origin`）、`book_api.dart`/`rust_api.dart`/`mock_book_api.dart`、`rss_articles_screen.dart:570-573`
- **实施要点**：契约登记 → Rust 实现 → codegen → UI 改按源查询。
- **验收**：按源查询生效；大记录量性能问题消除。
- **工作量**：M ｜ **前置**：无

### F3-18 `[UI]` SettingsService 注入收敛
- **来源**：D20
- **涉及文件**：8 个 screen（bookshelf_manage/book_info/other_settings/welcome/welcome_config/webdav_settings/toc/theme_config）
- **实施要点**：改走 `settingsProvider`/Riverpod 注入，移除直接 `SettingsService()` 实例化。
- **验收**：无直接实例化残留；`flutter test` 全绿。
- **工作量**：M ｜ **前置**：无

### F3-19 `[UI]` About 页资产补齐
- **来源**：P3-10（提升至本批）
- **涉及文件**：`about_screen.dart:138-157`、`assets/updateLog.md`/`assets/disclaimer.md`（从原版 assets 同步）、`pubspec.yaml`（assets 声明）
- **实施要点**：同步原版 updateLog/disclaimer 资产并声明。
- **验收**：About 页展示真实更新日志与免责声明，无占位文案。
- **工作量**：S ｜ **前置**：无

### F3-20 `[双轨]` 契约延迟封装项收口
- **来源**：D12b
- **涉及文件**：`book_api.dart`（backupList/bookGroupSetShow/httpTtsSetEnabled 入抽象）、`rust_api.dart`（ttsSpeak/ttsSetCacheDir 入抽象）
- **实施要点**：5 个延迟项补入 BookApi 抽象与 UI 封装（或按契约 §3 明确永不封装并销记）。
- **验收**：契约延迟清单清零或显式销记。
- **工作量**：M ｜ **前置**：无

---

## 五、第四批（P3，提示项）

| 编号 | 轨道 | 任务 | 来源 | 要点 | 工作量 |
|---|---|---|---|---|---|
| F4-1 | 工程 | 硬编码路径参数化 | P3-1 | `emulator_smoke_test.ps1:17` FlutterDir 改相对/环境变量 | S |
| F4-2 | 工程 | 临时文件清理 | P3-2 | flutter_legado 根级截图、`_debug_db/`、scripts `_tmp_*` 归档或删除 | S |
| F4-3 | 工程 | FRB 生成物版本统一 | P3-5 | `bridge/api/*.dart` 4 文件 2.12.0 头与整体 2.11.1 混杂；下次 codegen 统一 | S |
| F4-4 | UI | @override 补全 | P3-6 | rust_api.dart 185 个方法补 @override 或启用 `annotate_overrides` lint | M |
| F4-5 | UI | uploadRule/Cronet 占位收口 | P3-11 | 评估引擎接入或按 RESIDUAL「不做」销记 | S |
| F4-6 | 工程 | 文档存放规范收口 | P3-3 | 根目录 tmp_*/Makefile/package.json 处置（归档或补说明）；reasonix.toml 移出 | S |
| F4-7 | UI | l10n 推进 | P3-7 | 按 D5 决策：全面国际化或维持现状登记 | L（视范围） |
| F4-8 | Rust | payAction `{{js}}` 模板 | P3-11 | 补 URL 模板形态支持或契约登记 R6 留项 | M |

---

## 六、质量门禁汇总（每批执行后）

```powershell
# Rust（rust/ 下）
cargo test --workspace                       # 全量通过（零失败）
cargo test -p legado-ffi --features quickjs  # JS 引擎全量（F2-5 后纳入 CI）
cargo clippy --workspace -- -D warnings     # 零警告（F3-7 后含 legado-ffi）
cargo fmt --check

# Flutter（flutter_legado/ 下）
flutter analyze                             # 0 error（F1-2 后）
flutter test                                # 全量通过

# 冒烟（F1-1/F2-1/F2-3 等涉及运行链路后必做）
.\scripts\emulator_smoke_test.ps1 -Device emulator-5556          # 子代理自测
.\scripts\emulator_smoke_test.ps1 -Device emulator-5558 -CheckUI # 用户验收
```

---

## 七、任务依赖关系图

```
D1 决策 ──→ F2-7 阅读统计 ──→ F3-15 死契约面
D2 决策 ──→ F2-8 users 表
D3 决策 ──→ F3-4 沙箱文档
D4 决策 ──→ F3-13 video 下沉
D6 决策 ──→ F1-3 legado.jks
F1-1 html 回归 ──→ F2-5 CI 覆盖（先绿再纳入）
F1-1/F1-2 ──→ F2-9 分支合入（master 绿态承接）
F2-4 测试口径 ──→ F3-11 口径统一
```

---

## 八、执行批次建议顺序

1. **P0 批**：F1-1 → F1-2 → F1-3（决策 D6）
2. **P1 批**：F2-1/F2-2/F2-3（功能缺口）→ F2-4/F2-5/F2-6（构建 CI）→ F2-7/F2-8（红线，需 D1/D2 决策）→ F2-9/F2-10/F2-12（工程卫生）→ F2-11（文档）
3. **P2 批**：F3-1/F3-2（Rust 健壮性）→ F3-10/F3-11（契约文档）→ F3-13/F3-14（越界下沉）→ 其余按依赖
4. **P3 批**：F4-1 ~ F4-8

---

编写者：DeepSeek Harness ｜ 2026-08-14
