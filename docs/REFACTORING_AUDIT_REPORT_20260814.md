# Legado 重构项目全量审计报告（2026-08-14）

> **审计性质**：只读审计。未修改任何项目代码；未提交任何变更。
> **审计基准**：工作树 HEAD `6cb63f95c`（feature/rust-core，pubspec 2.0.48+50）。
> **方法**：① 后台实测 `cargo test` / `flutter analyze` / `flutter test`；② 4 路子代理并行深度审计（Rust 轨 / Flutter 轨 / FFI 契约 / 计划台账与仓库卫生）；③ git worktree 复跑失败用例定位回归提交；④ 关键发现逐一人工复核证据。

---

## 一、总体结论

重构主体（Phase 0–4 功能迁移）完成度高：Rust 8 crate 模块覆盖与计划「模块→目标归属」基本一致；FFI 四层调用链 244↔244 双向闭合、content hash 一致；Flutter 1209 个测试全绿；FFI 生产边界无 panic 逃逸（bridge.rs 全 catch_unwind 包裹）。

**但审计发现 3 项 P0 级缺陷与 12 项 P1 级问题**，均与「已完成、零失败、0 issues、工程已收口」的文档口径不符：

| 级别 | 数量 | 代表问题 |
|---|---|---|
| P0 | 3 | Rust 词典查询 CSS 回归（已提交代码带确定性失败测试）；flutter analyze 14 个 error；签名库 legado.jks 入库 |
| P1 | 12 | 3 处 TODO 功能缺口；quickjs 默认关闭静默降级；CI 测试覆盖缺口；分支纪律失效；红线偏离残留（阅读统计/明文密码用户表）；仓库卫生失守 |
| P2 | 21 | FFI 层 panic 残留；沙箱死配置与文档矛盾；契约计数全面滞后；UI 层职责越界；死代码/死模块；页面覆盖缺口；RSS origin 过滤 |
| P3 | 12 | 硬编码路径、临时文件、文档数据偏差、资产缺失、诚实占位等 |

> A* 环境验收项（WebDAV 实网/真机媒体键/样例书等）经核实确属**真实环境依赖**（依赖用户素材），非文档造假，不计入缺陷。

---

## 二、实测验证结果（第一手证据）

### 2.1 `cargo test`（rust/，legado-ffi 默认 feature）

**282 passed；3 failed；10 ignored —— 与文档「零失败」不符**

| 失败用例 | 复测结论 |
|---|---|
| `api::dict_api::tests::test_lookup_show_rule_css` | **真实回归**：`--features quickjs` 下仍失败（definitions.len()=0，期望 1）。词典查询（阅读器选中查词）的 showRule CSS 提取链路已损坏 |
| `api::web_book::tests::qmao_js_rule_extracts_m3u8_from_saved_html` | quickjs feature 下通过 → **feature 配置问题**（默认构建无 JS 引擎） |
| `api::web_book::tests::test_parse_content_page_with_js_lib_resolves_lib_function` | 同上，quickjs 下通过 |

**回归定位（git worktree 复跑，只读验证）**：
- `20bee32d1`（08-07，测试引入时）：PASS
- `ec4919c9e`（08-13，ownText/编译缓存）：PASS
- `6bb18abb9`（08-13，发现列表点号索引）：**FAIL**
- → **回归由 `6bb18abb9` 引入**：html.rs 元素选择逻辑「JSoup 级选择器命中含自身」改动（`selector.matches(elem)` 提前入列）破坏了 `#def` 等 ID 选择器的文本提取。该提交为修思路客 `.page-link@a@href` 而加，但引入通用 CSS 路径回归。**词典功能已损坏，且可能波及其他 ID 选择器书源**。

### 2.2 `flutter analyze`

**276 issues = 14 error + 3 warning + 259 info —— 与文档「0 issues」不符**

- 14 个 error **全部**集中在 `flutter_legado/lib/src/screens/reading_stats_screen.dart`：import 的 `../providers/reading_stats/reading_stats_notifier.dart` 已删除（providers/reading_stats/ 目录不存在）。该文件为**孤儿死代码**（全 lib 无任何引用），是「阅读统计」偏离项清理的半成品残留。
- CI（flutter-ci.yml）`flutter analyze --no-fatal-infos`：error 仍致命 → **当前推送到 CI 必红**。
- 3 个 warning：book_info_screen.dart 2 处多余 cast、rss_source_edit_screen.dart 1 处未用 import。

### 2.3 `flutter test`

**1209 个测试全部通过 ✓**（reading_stats_screen.dart 未参与编译，未影响测试）。

---

## 三、P0 缺陷（必须立即处理）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P0-1 | **词典查询 CSS 提取回归**（`6bb18abb9` 引入） | `legado-parser/src/html.rs` 元素选择「含自身」改动；`legado-ffi/src/api/dict_api.rs:461` 测试确定性失败 | 阅读器查词功能损坏；ID 选择器类书源规则可能受影响；已提交代码带失败测试 |
| P0-2 | **flutter analyze 14 error**：`reading_stats_screen.dart` 引用已删除 provider | `lib/src/screens/reading_stats_screen.dart:5` → `providers/reading_stats/` 不存在；全 lib 零引用（孤儿） | CI flutter-ci 必红；「0 issues」口径失真；半删半留的死代码 |
| P0-3 | **签名库 legado.jks 入库** | `.github/workflows/legado.jks` 已跟踪（2232B，2026-07-25）；.gitignore 未覆盖 jks | 若含真实 release 密钥即泄露，须立即核验并轮换；应移入 secrets 并从仓库移除 |

---

## 四、P1 缺陷（重要）

### 4.1 功能缺口（TODO 未完成，用户可见）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1-1 | **书架拖拽排序不持久化** | `bookshelf_notifier.dart:158`「持久化排序由后续调用 BookApi 完成（TODO: Phase 1.5）」；`book_api.dart` 无书籍排序持久化接口 | 用户拖拽排序后**重启丢失** |
| P1-2 | **换源页 3 个假开关** | `change_source_screen.dart:125`；`loadWordCount`/`loadInfo`/`loadToc` 写入 config 后 **rust/ 全库零读取**（仅 checkAuthor/searchGroup 被消费） | 开关无实际效果，误导用户 |
| P1-3 | **按书清缓存降级为全局** | `book_info_screen.dart:1590` TODO(Rust轨)；原版 BookCacheManager.clear 按书，当前 FFI 仅 cacheClear 全局 | 功能降级（有确认对话框缓解） |

### 4.2 构建/CI/配置

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1-4 | **quickjs 默认关闭，静默降级** | `legado-js/Cargo.toml` `default = []`；`engine.rs` StubJsEngine；`rust/README.md` 教 `cargo build` 不带 feature | 按文档构建得到「能编译但 JS 书源全不可用」产物；文档质量门禁 `cargo test` 直接失败（3 个失败测试的 2 个由此而来） |
| P1-5 | **CI 不跑 legado-ffi 全量测试** | `rust-ci.yml` 仅 `cargo test -p legado-ffi --features quickjs js_executor`（子集）；clippy 也 `--exclude legado-ffi` | dict/web_book 回归（P0-1）CI 完全无感知 |
| P1-6 | **仓库级 .cargo/config.toml 硬编码 Windows NDK 路径 + USTC 镜像绑定** | `rust/.cargo/config.toml`：`D:\Android\ndk\28.2.13676358\...` + `replace-with = "ustc"` | 非 Windows 开发者/CI（ubuntu）交叉编译 Android 必然失败；镜像故障全链构建失败 |

### 4.3 红线偏离（AGENTS.md 明令清理项）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1-7 | **阅读统计子系统 Rust 侧完整残留** | `legado-core/src/reading_stats.rs`、`reading_sessions` 表（schema.rs:454）、`reading_stats_api.rs`、ffi.rs 4 个 stats_* 导出、legado-server `/stats/today|daily|books|heatmap` 4 路由 | 原版仅 ReadRecordActivity（简单列表，无热力图/会话/阅读速度）；Flutter 侧屏幕已删但 **Rust 核心+DB+服务端端点全套保留**——清理半途而废；AGENTS.md 点名须清理 |
| P1-8 | **users 表明文密码** | `schema.rs:73` CREATE_USERS；`user_repository.rs` `password_hash` 列**存明文**；原版无 user 表（为 servers 表，语义不同，RESIDUAL 文档亦承认 mismatch） | 违反红线 + 明文密码安全隐患（当前 UI 未接线） |

### 4.4 工程/分支纪律

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1-9 | **分支纪律失效：master 冻结** | master 停在 `5209063f4`（**2026-08-01**）；feature/rust-core（当前 HEAD）**0 behind / 388 ahead**；feature/ui 08-01 后无提交；integration/* 未承接 | 双轨/集成规范（AGENTS.md）实际未执行；13 天 388 提交未合入主分支 |
| P1-10 | **1400+ 未跟踪文件 + 75 个删除悬空** | `git status` 1572 条：?? 1410（tmp_debug 1243）、D 75、M 87；.gitignore 未覆盖 tmp_debug/expired/tmp_* | 仓库卫生失守；**真实测试 `offline_cache_screen_test.dart` 未提交**；真实测试文件可能遗漏 |
| P1-11 | **README 死代码口径错误** | `docs/README.md:37` 将 `getAudioChapterMedia` 与 scanLocalBooks/parseTxt 并列为死代码；实测 **getAudioChapterMedia 是音频书播放在用真实 FFI**（audio_notifier.dart:288、audio_screen.dart:816/937） | 按 README 清理将误删在用功能 |
| P1-12 | **.qoder/agents/builtin/*.md 5 个被修改** | code-reviewer/full-stack-engineer/qa/researcher/ui-operator 均为工作树 M 状态 | 违反「builtin 勿手动编辑」明令 |

---

## 五、P2 缺陷（次要）

### 5.1 Rust 轨
- **D1  FFI 层 panic 残留（违反「FFI 禁 panic」）**：`webdav_api.rs` 9 处 `thread::Builder...build().unwrap()`、`server_api.rs` 5 处 `expect`（含 mutex 中毒）、`http_state.rs`/`net_api.rs` 锁 `unwrap`。frb 会转 Dart 异常，但违反契约 §3.3。
- **D2  `check_syntax` 无超时无内存上限**（`legado-js/src/engine.rs:452`）：书源语法检查对病态 JS 可无限挂起 FRB 线程（Function() 编译期无 5s 超时兜底）。
- **D3  沙箱死配置**：`sandbox.rs` `max_stack_depth`（README 声称「栈深度 512」未实施）、`allow_network`（网络注册无条件）、`ALLOWED_GLOBALS` 白名单（`#[allow(dead_code)]` 从未应用）。
- **D4  eval 生产路径启用与文档矛盾**：`engine_pool.rs:43`/`js_executor.rs` `with_allow_script_run(true)`，而 README/sandbox.rs 文档写「eval/Function 禁用」→ 文档未同步（方向可辩护：对齐原版 Rhino）。
- **D5  ffi.rs 9 个导出不返回 Result**（version/backup_list/server_stop/server_status/archive_is_archive/auto_task_*/audio_with_play_mode），违反「全部 Result」条款。
- **D6  引擎池跨调用链状态串扰**：`js_executor.rs` 引擎池按 source_tag 复用，payAction/login/explore 共享引擎，JS 顶层全局声明跨 eval 持久。
- **D7  死模块/桩**：`legacy-ffi/` 孤儿目录（不在 workspace，仅 DEPRECATED.md）、`context.rs`/`scope.rs`/`ffi_macros.rs` 死代码、`ffi.rs:1060` `let _ = &rule_type` 桩。
- **D8  Rust 多存瞬态字段**：infoHtml/tocHtml/downloadUrls 落库（SOURCE_DIFF §4.3 已承认，非功能缺陷）。
- **D9  编码检测未按计划用 chardetng**：`legado-book/src/encoding.rs` 自研启发式 + encoding_rs（功能等价，计划文字偏差）。

### 5.2 契约/文档
- **D10 契约计数全面滞后**：BookApi 实际 257 方法 vs 契约声称 237；附录合计实测 247 vs 声称 248（漏 importOldData）；§2.3/§2.4/§2.5/§2.9/§2.11/§2.43 标题数/表格行/附录三方不一致。
- **D11 契约未登记 3 个完整实现**：`fetchImageWithDecode`、`rssClearArticles`、`sourceCallBackBtn`（BookApi+RustApi+ffi.rs 均存在，契约零命中，违反 §1.2）。
- **D12 §2.43.3 taskId 类型漂移**：契约写 String，实现为 int/i64（运行时互转不报错，语义不一致）。
- **D12b 契约延迟封装项 5 个**（Rust FFI 均存在、契约 §3 已登记待封装，非缺口）：`backupList`/`bookGroupSetShow`/`httpTtsSetEnabled` 未进 BookApi；`ttsSpeak`/`ttsSetCacheDir` 已由 RustApi 内部接通但未入抽象。另契约登记 FFI 名与 BookApi 名存在 8 对等价差异（sourceIsLoginUiV2↔isLoginUiV2、jsSourceExtract↔extractJsSource、cacheListCachedChapterUrls↔listCachedChapterUrls 等），易误导「契约有接口无」类比对（P3 提示）。
- **D13 测试数字多版本并存**：Rust 1409/1752/2023/2283；Flutter 1087/1092/1153（实测 1209）；**README「约 3400」自身算术错误**（2283+547+1087=3917，漏加 quickjs 547）。
- **D14 原子任务 148 vs 168 未对账**；FFI 函数数 103+/166/189 全低估（实测 ffi.rs 242 个 pub fn）。
- **D15 版本口径四套并存**：2.0.39（USER_TEST）/ 2.0.45（RESIDUAL/SOURCE_DIFF 08-14 修订行）/ 2.0.47~48（pubspec/CHANGELOG）/ v4.0.0-alpha（根 README）；文档修订滞后实际版本。
- **D16 根 README 全面过期**：v4.0.0-alpha、「18 个页面」（实际 67 个 screens 文件）、CI 徽标指向废弃仓库 ZhangGHGitHub/LegadoTeamFlutter。

### 5.3 Flutter 轨
- **D17 UI 层职责越界**：`video_play_utils.dart`（281 行 AnalyzeUrl/VideoPlay 解析逻辑：extractVideoUrl/splitUrlOption/isMpdVideoContent/resolveVideoPlayTarget，原版在 Kotlin、计划要求 Rust）；**8 处直接 `http.get`** 绕过 Rust 网络层（auto_task_screen:631、rule_sub_screen:496、audio_screen:940、reader_comic_screen:1259、replace_rules_screen:497、rss_source_manage_screen:1092、association_notifier:7、source_import_service:105/250）；`book_open_utils.dart` 正则扫描书源规则做视频源/抽图源启发式判定（原版靠 BookType 位标记）；SharedPreferences 直写散落 10+ 处。
- **D18 comic_reader_screen.dart（618 行）被替代死文件**（测试自述「已删除，路由使用 ReaderComicScreen」但文件未删）；段评 CRUD 与阅读统计 FFI 死契约面（@Deprecated 但 Rust 实现全套保留）。
- **D19 页面覆盖缺口**：原版 56 个 Activity（ui/ 包下 53 个 *Activity.kt + 3 个非 ui 包）中 52 个有对应，缺失 2 个——`HandleFileActivity`（ui/file/，文件管理 + 打开方式分享接收，Flutter 无对应，跨平台受限可论证 N/A 但未登记）；`RssSortActivity`（ui/rss/article/，RSS 排序页，Flutter 功能降级为无排序）。SOURCE_DIFF 声称「49 vs 63 全部有对应」与实际 53/67 口径松散且未列映射表。
- **D20 8 个 screen 直接 `SettingsService()` 实例化**未走 Provider（`bookshelf_manage`、`book_info`、`other_settings`、`welcome`、`welcome_config`、`webdav_settings`、`toc`、`theme_config`），与 Riverpod 统一状态管理规约不完全一致。
- **D21 RSS 阅读记录按 origin 客户端过滤**：`rss_articles_screen.dart:570-573`「FFI 无按源查询接口，客户端按 origin 过滤（TODO: 待 getRecordsByOrigin 补齐）」；`book_api.dart` 仅 `rssListReadRecords([int? limit])` 无按源查询 → 结果正确但记录量大时全量拉取（性能缺口）。
- **正面确认（未越界）**：无 sqflite/sqlite3 直连；正文净化/替换在 Rust；漫画解密走 FFI `fetchImageWithDecode`；词典走 FFI `dictLookup`；封面解密走 FFI；36 个 provider 无孤儿（全部有消费方）、无页面直接 `new Notifier`、无 Dart 硬编码版本号（走 PackageInfo）。搜索/阅读/换源等 Flutter 热路径对应的 Rust FFI 生产代码（search.rs/web_book.rs/source_login_v2_api.rs）经逐行核实 **0 处 unwrap/expect/panic**。

---

## 六、P3 卫生问题（提示）

1. `scripts/emulator_smoke_test.ps1:17` 硬编码 `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado` 绝对路径。
2. `scripts/` 混入 `_tmp_*.txt/_tmp_ui_check.py` 临时文件；`flutter_legado/` 根级 12 张调试截图、`_debug_db/`、`docs/screenshots/v1_3/legado.db` 数据库混入文档目录。
3. 根目录散落文件违反文档存放规范：已跟踪 `Makefile`（与 AGENTS.md「无 make」矛盾）、`package.json`（指向废弃仓库）；未跟踪 `tmp_legado.db`/`tmp_legado2.db`/`tmp_patch_*.py`/`tmp_preserve_vc.py`/`reasonix.toml`（含机器绝对路径）。
4. AGENTS.md 数据偏差：app/ 实测 1265 个 .kt（声称约 1000）。
5. FRB 生成物版本混杂：`bridge/api/{book_import,reader,rss,search}.dart` 标 2.12.0，其余 2.11.1。
6. `rust_api.dart` 185 个方法缺 `@override`（无 lint 强制，非编译风险）。
7. l10n：`app_strings.dart` 仅 ~163 条，页面大量直接中文字面量（中文主语言应用可接受，仅提示国际化缺口）。
8. `checkRedirect` 可观测性用 `eprintln`（SOURCE_DIFF 已登记，非结构化日志）。
9. 引擎池 `pool_engine` 与 `POOL.get_or_init` 双池并存，代码注释自述「每次新建引擎」与池复用逻辑并存（R4 同源）。
10. About 页更新日志/免责声明资产缺失：`about_screen.dart:138-157` 恒走占位文案；`assets/updateLog.md`/`assets/disclaimer.md` 未打包（原版有）。
11. `other_settings_screen.dart` uploadRule/Cronet 诚实占位（无引擎支撑，已标注）；`pay_action_api.rs` `{{js}}` URL 模板形态不支持（R6 留项）。
12. 8 处直接 `http.get`（越界-2 明细见 D17）与 `video_play_utils` 视频解析逻辑（D17）均已有对应 Rust 能力，属「重复实现」而非「能力缺失」。

---

## 七、与重构计划的偏差对照（REFACTORING_PLAN.md）

| 计划条款 | 实际 | 判定 |
|---|---|---|
| Phase 0-4 主体迁移（书架/搜索/阅读器/管理功能） | 完成，功能可用 | ✅ |
| 「UI 层绝不包含业务逻辑」 | video_play_utils 全套解析、8 处裸 http、SharedPreferences 直写 | ❌ 部分未落实 |
| 「所有函数返回 Result<T, AppError>，禁止 panic」 | 9 个非 Result 导出；FFI 层 14+ 处 unwrap/expect | ❌ 部分未落实 |
| 「JS 引擎沙箱：禁用危险 API，超时 5 秒」 | 生产路径允许 eval（对齐原版 Rhino，文档化偏离）；check_syntax 无超时；引擎池跨调用复用 | ⚠️ 有意偏离但文档矛盾 |
| 「chardetng 处理 GBK」 | 自研启发式 + encoding_rs | ⚠️ 功能等价，文字偏差 |
| 「Mock 数据使用真实 JSON」 | mock_book_api 仍 TODO 待替换（仅 USE_MOCK 开发模式生效） | ⚠️ 未完成 |
| 「禁止新增原版不存在的创意功能」 | reading_stats 子系统（Rust 全套残留）、users 表明文密码表 | ❌ 违反（部分已清理） |
| 「集成使用 integration/* 分支」 | master 冻结 13 天，388 提交滞留 feature/rust-core | ❌ 未执行 |
| Phase 5 清理优化（移除残留、统一风格） | 孤儿文件、死模块、临时文件、文档口径均未收口 | ❌ 未完成 |

---

## 八、建议修复顺序

> 📎 可执行任务清单（含每项涉及文件、实施要点、验收标准、工作量、依赖关系）：[AUDIT_FIX_TASKS_20260814.md](AUDIT_FIX_TASKS_20260814.md)

**第一批（P0，立即）**
1. 修复 `6bb18abb9` 引入的 html.rs 元素选择回归（恢复 ID 选择器提取；补 dict + 通用 CSS 回归测试）。
2. 删除孤儿 `reading_stats_screen.dart`（恢复 flutter analyze 0 error）；或将阅读统计按用户决策正式豁免并重建 provider。
3. 核验 `legado.jks` 是否真实密钥 → 轮换 + 移入 secrets + 从仓库移除 + .gitignore 加 `*.jks`。

**第二批（P1，本周）**
4. 补书架排序持久化（BookApi 新方法 + 契约登记）；接线或移除 loadWordCount/loadInfo/loadToc 假开关；补按书清缓存 FFI。
5. rust-ci 增加 legado-ffi 全量测试 job（`--features quickjs`）；质量门禁文档改为 `cargo test -p legado-ffi --features quickjs`。
6. `.cargo/config.toml` 移除 Windows NDK 路径与 USTC 镜像绑定（改机器级配置或 CI 环境变量）。
7. 清理 reading_stats Rust 子系统 + users 明文密码表（或用户正式豁免后改哈希存储）。
8. 分支合入：feature/rust-core → master（或重建 integration 分支承接）；提交 75 个删除与 offline_cache_screen_test.dart；.gitignore 覆盖 tmp_debug/expired/tmp_*。
9. 修正 README getAudioChapterMedia 死代码口径。

**第三批（P2/P3，排期）**
10. 契约文档同步（257 方法、3 未登记实现、taskId 类型、附录合计）；统一测试数字口径并更新 README 系文档。
11. FFI 层 unwrap/expect 收敛（webdav/server/http_state）；check_syntax 加超时。
12. 沙箱文档与实现对齐（eval 策略、栈深度）；清理死模块（legacy-ffi/context.rs/scope.rs/ffi_macros.rs）、死文件（comic_reader_screen.dart）。
13. UI 层越界逻辑下沉 Rust（video_play_utils/http.get）；l10n 视需要推进。
14. 硬编码路径参数化；根目录/scripts/flutter_legado 临时文件清理。

---

## 九、审计旁证与口径说明

- 测试计数均为本次实测：`cargo test`（legado-ffi 默认）282+3+10、`--features quickjs` 下 dict 仍失败；`flutter test` 1209 全过；`flutter analyze` 276 issues。
- 回归定位用 git worktree 复跑（20bee32d1 PASS → ec4919c9e PASS → 6bb18abb9 FAIL），worktree 已清理，未污染工作树。
- A* 项（WebDAV 实网 / 听书流媒体 / 真机媒体键 / 漫画视频样例 / 段评 ruleReview / 皮肤 zip）为环境素材依赖，未计入缺陷；**不得以模拟器冒烟销账**（RESIDUAL 原文口径）。

编写者：DeepSeek Harness 审计代理 ｜ 2026-08-14
