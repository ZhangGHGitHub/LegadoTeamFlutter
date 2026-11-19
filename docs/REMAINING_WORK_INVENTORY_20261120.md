# 剩余未关闭项全量盘点（2026-11-20）

> 基线：`HEAD c3d95bda8e`，版本 `2.0.512+513`，`SCHEMA_VERSION = 119`
> 性质：**只读调研**。除本文件外未修改任何代码/配置。
> 方法：`docs/REFACTORING_ACTIVE_PLAN.md`（1289 行）用 Python 以 UTF-8 读取；每条结论均以源码 grep / 命令输出交叉验证，不照抄文档。

---

## 一、结论摘要

| 指标 | 数值 |
|---|---|
| 提取出的剩余项总数 | **47 项**（合并强相关子项后） |
| 其中「已对齐 / 无需做」 | **11 项** |
| 实际仍需动作 | **36 项** |
| 类型分布 | 功能缺口 4 ｜ 已知缺陷 12 ｜ 文档偏差 3 ｜ 实机项 5 ｜ 技术债 12 ｜ 已对齐 11 |
| 核实中发现「文档与代码不一致」 | **13 处**（其中 5 处文档声称未做但代码已实现，3 处数字失真，5 处声称状态已过时） |

**三条最重要的核实结论**

1. **C1「逐表备份忽略」已经做完了**（`65fbe842e0`，2026-11-18，`docs/API_CONTRACT.md:15/849/875` 已回写，Rust + Dart + 测试全齐）。但 ACTIVE_PLAN 最后一条（`L1289`）仍写「C1 逐表备份忽略」在「下一步」，**文档滞后 2 天**。
2. **「L10N 剩约 54 处」严重失真**：实测 `flutter_legado/lib` 内（排除 `app_strings.dart` 字符串表与 `debugPrint`/`assert` 日志）仍有 **4391~4587 处**中文 UI 字面量，分布在 **288 个文件**；去重后仍有 **3197 条不同字面量**。真实量级是文档数字的 **80 倍**。
3. **WebDAV widget 测试的 `getConfig` stub 缺失仍在**：9 个 pump `WebDavSettingsScreen` 的测试文件中只有 `settings_test.dart` 有 stub，其余 8 个缺失，运行时打 `读取备份内容忽略配置失败` 日志（`gate9_flutter_test.log` 实测可见）。

---

## 二、清单表（按建议优先级排序）

优先级口径：P0＝影响发版正确性/用户可见数据；P1＝安全或明显体验缺陷；P2＝质量债；P3＝卫生项/低优。

| 编号 | 项目 | 来源 | 代码核实状态 | 类型 | 预估工作量 | 依赖/阻塞 | 建议优先级 |
|---|---|---|---|---|---|---|---|
| R01 | **`.so` 全 ABI 陈旧，需重建后才能发版** | 环境实测 | `pwsh rust-fingerprint.ps1 -Check` → `DECISION=REBUILD`；`.so` 指纹 `0288169c…` ≠ 当前 `b1c0003b…`（arm64/x86_64 均陈旧；`c3d95bda8e` 改了 `audio_cache_api.rs`） | 技术债 | 0.5 天（含三 ABI release 构建 + 冒烟） | 无 | **P0** |
| R02 | L10N 阶段 3 剩余量（文档称 54 处，**实测 4391 处 UI 字面量 / 288 文件 / 3197 条去重**） | L1289、L1285 | 实测：`screens` 2371、`widgets` 1136、`services` 486、`providers` 209、`models` 77。Top：`reader_config_panel_builders.part` 141、`bookshelf_config_sheet` 102、`highlight_rules_screen` 100、`rss_source_edit_screen` 96 | 功能缺口 | 15~25 天（分批） | 需分批派单，单批 ≤300 处 | **P1** |
| R03 | 私密内容随备份/导出/Web 输出（用户 2026-11-11 已裁决「维持参考口径」） | L1247 裁决③ | 裁决在案，仅需**补隐私设置页明示文案**——实测 `privacy_settings_screen.dart:423/439` 已有两段明示文案 | 已对齐 | 0 | — | 关闭 |
| R04 | JS `setCookie` 不进 App 罐（「单罐」只做了 HTTP→JS 单向） | 批38 遗留② | 已确认：`http_state.rs:283-286` 的 `JsCookieDbSink::upsert` 只写 DB，不同步 `shared_cookie_store`；反向 `legado-js/src/host_api/network.rs:287` 有 `JsCookieWriteObserver`（HTTP→JS 已通） | 已知缺陷 | 1~2 天 | 需锁序论证（D→C→P→G） | **P1** |
| R05 | `/api/sources` GET 免令牌返回含 `variable` 且无 `no-store` | 批24/批27 遗留 | 已确认：`routes.rs:67-68` 注释明示「GET /sources 保持免令牌」；`web_assets.rs:128-135` 的 no-store 白名单不含 `/api/sources` | 已知缺陷 | 0.5 天（加路由级令牌 + no-store） | 与上游 `PROTECTED_HTTP_LOG_READ_ROUTES` 口径对齐 | **P1** |
| R06 | `repo_url` 只做字面量校验，DNS 解析到内网未拦截 | 批24/批27/批34 遗留 | 已确认：`handlers/source_update.rs:168-197` 仅查 scheme/host 字面量 + `is_disallowed_ip`；无 DNS 解析后校验 | 已知缺陷 | 0.5~1 天 | 需引入解析后复核（防 DNS rebinding） | **P1** |
| R07 | `PUT /api/sources/{id}` 改 URL 且不冲突时旧行保留（产生重复源） | 批24/批27 遗留 | 已确认：`handlers/source.rs:53/149/185-186` 仅做「目标已存在 → 409」，无「改键后删旧行」 | 已知缺陷 | 0.5 天 | 需确认是否对齐上游（上游整行 replace） | P2 |
| R08 | 书源 JS `openVideoPlayer` 浮窗直启绕过私密闸门 | 批45 遗留⑥ | **已修**：`30d404de04`（批42 P2-7），`platform_bridge_service.dart:1046-1099` 的 `_allowOpenVideoPlayer` 覆盖浮窗与路由两分支；`fea0555073` 载荷带 `bookUrl` | 已对齐 | 0 | — | 关闭 |
| R09 | `is_invalid_group` 用 `contains("失效")` 误删用户自建分组 | 批45 遗留⑧ | **已修**：`e6f53a1e76`（B14），`legado-fetcher/src/source_check.rs:84-105` 已改**精确白名单** `invalid_group_names_domain()` | 已对齐 | 0 | — | 关闭 |
| R10 | `lastUpdateTime` 编辑打戳缺失（牵动 respondTime 与订阅门控） | 批39 遗留③ | **已修**：`5e33216758`（B12），`api/source.rs:97-136` 的 `apply_last_update_time` 按 `check_content()` 归一比较后打戳 | 已对齐 | 0 | — | 关闭 |
| R11 | FFI 校验路径不更新 `respondTime` | 批39 遗留⑦ | **已修**：`e6f53a1e76`（B13），`api/source_check_api.rs:583-613` 的 `write_back_respond_time` | 已对齐 | 0 | — | 关闭 |
| R12 | `mainJs` 未在 `eval_explore_kinds_js` 预载（JS 单文件源 `exploreUrl:"@js:"` 判 js失效） | 批39 遗留⑥ | **已修**：`ca48ff4c96`（B16），`source_check.rs:853-860` 已传入 `setup_script` | 已对齐 | 0 | — | 关闭 |
| R13 | 滚动模式 `ReaderParagraphs` 规则与手动高亮未接线 | 批29 新登记 | **已修**：`reader_page_view.dart:2399-2427` 两处均已传 `highlightMatches`（含 `matchesStartSorted` 优化） | 已对齐 | 0 | — | 关闭 |
| R14 | 首页「最近阅读」无隐私脱敏 | 批31 遗留⑤ | **已修**：`b00585e592`（批32），`docs/evidence/batch32/` 有 4/4 设备证据 | 已对齐 | 0 | — | 关闭 |
| R15 | 清理缓存副标题与实际范围不符 | 批37 遗留③ | **已修**：`bfcf16d21e`，`app_strings.dart:512` 现为「清除章节缓存与书源缓存」 | 已对齐 | 0 | — | 关闭 |
| R16 | `unzipFile` 与 `extract_archive_with_policy` 双实现（口径漂移风险） | 批37 遗留⑥ | **已修**：`a0c770a1ac`，`unzipFile` 已复用公共闸门 | 已对齐 | 0 | — | 关闭 |
| R17 | HLS SAMPLE-AES 硬失败 + 忽略 `KEYFORMAT` | 批2 遗留④ | 已确认仍在：`hls_playlist.rs:740-745` 对 `SAMPLE-AES*` 直接 `Err`；`parse_key`（`:712-746`）**不解析 `KEYFORMAT`** 属性（未知属性静默丢弃），双 KEY（`KEYFORMAT=identity` + `com.apple.streamingkeydelivery`）的 Apple 风格 playlist 因先遇 SAMPLE-AES 整体拒绝 | 已知缺陷（边界） | 1~2 天（仅需忽略非 identity 的 KEY，保留 AES-128 分支） | 需先定「多 KEY 择一」策略 | P2 |
| R18 | HLS 内容嗅探只看首块 | 批2 遗留④ | 已确认：`audio_cache_api.rs:1065-1066` 仅对 `first_chunk` 调 `looks_like_m3u8`；首块 <7 字节时无扩展名 m3u8 会被当二进制音频 | 已知缺陷（边界） | 0.5 天（首块不足则再读一块拼接判定） | 无 | P2 |
| R19 | HLS 分片请求不继承书源 `timeout` | 批2 遗留④ | 已确认：`fetch_bytes_capped`（`audio_cache_api.rs:1289-1295`）恒 `timeout: None`（用客户端默认 60s）；主请求在 `:1029` 有 `analyze_url.timeout()` | 已知缺陷 | 0.5 天（把 timeout 传入 `HlsFetchCtx`） | 无 | P2 |
| R20 | HLS 非网络错误被包成 `Network`（错误码 1001→1002） | 批2 遗留④ | 已确认：`:1703/1756` 把 `LegadoError::Parser` 等一律 `return Err(LegadoError::Network(format!(...)))`，仅 `retryable` 判定区分 | 已知缺陷 | 0.5 天（保留原 err 类型，仅文案包装） | 无 | P2 |
| R21 | HLS 16 分片章锁覆盖整个合并期 | 批2 遗留④ | 已确认：`chapter_lock` 在 `:936-937` 取锁，HLS 分支 `:1078-1091` 在同锁内完成全部分片下载 + 合并 | 技术债 | 1 天（锁粒度拆到「写临时文件」段） | 需保证并发不互相删除 tmp | P2 |
| R22 | 7 个零引用组件仍留在 `docs/pending_deletion/lib/src/widgets/` | 批45 遗留④ | 已确认：7 文件已 `git mv` 入库（`git ls-files` 可见），全 `lib/` 逐类名 grep **命中 0**（已复核），`test/` 零引用 | 技术债（清理） | 10 分钟（`git rm -r docs/pending_deletion`） | 观察期已满（2026-11-17 移入） | P2 |
| R23 | `docs/pending_deletion/` 另两个目录（8 个 SVG + Web 自制首页） | `pending_deletion/README.md` | 已确认仍在库；`assets_icons_unused/` 8 个 SVG，`web_dist_custom_index/` 9,536B index.html | 技术债（清理） | 10 分钟 | 同上 | P3 |
| R24 | `tmp_debug/` 42 个 `device_acceptance_*` + 272 个其它文件，**1.1 GB** | 批45 遗留⑤（文档称「69 个 60GB + .tmp 4.5GB」） | 实测：`tmp_debug` 1.1G（42 个 acceptance 目录）、`tmp_*` 合计 1.2G（16 项）、`.tmp` 645M；全部被 `.gitignore:49 /tmp_*` 忽略。**文档 60GB/4.5GB 严重失真**（真实约 3 GB；`rust/target` 329G 才是大头，且为构建产物） | 技术债（清理） | 30 分钟（需用户确认后删） | 需用户授权（含历史验收证据） | P2 |
| R25 | 8 个 WebDAV widget 测试缺 `getConfig` stub | 批45 交接 | 已确认：9 个 pump `WebDavSettingsScreen` 的文件中，仅 `settings_test.dart` 有 stub；`webdav_settings_screen_test`/`webdav_restore_confirm`/`webdav_restore_password`/`webdav_local_restore_seen`/`webdav_backup_restore_actions`/`webdav_backup_family_settings`/`screens_overflow_regress` 均缺；`webdav_settings_test.dart` 有 5 处（已补）。运行时实测打 `读取备份内容忽略配置失败：type 'Null' is not a subtype of type 'Future<String?>'` | 已知缺陷（测试噪音） | 0.5 天 | 无 | P2 |
| R26 | `get_cache_size` 只统计章节缓存，未纳入 `cache_store` | 批37 遗留⑤ | 已确认：`cache_api.rs:14-20` 仅 `CacheBookRepository::get_stats()` | 功能缺口（小） | 0.5 天 | 需定义 cache_store 目录统计口径 | P3 |
| R27 | `cacheFile` 下载文件在 `js_files` 沙箱，不随「清理缓存」删除 | 批37 遗留④ | 已确认（上游 `externalCache` 同样不删，属对齐行为） | 已对齐 | 0 | — | 关闭 |
| R28 | `split_url_option` 与 parser 双实现，剩余 3 条有意差异 | 批37 遗留② | 已确认已在注释登记（逗号前空白 / 非字符串 type / 含 `.` 的 type）；其中含 `.` 的回退是安全收敛 | 技术债（已登记） | 0 | — | P3（维持） |
| R29 | RSS WebView 垫片 `cache.get` 只读页面本地镜像，与 QuickJS 读一致性有缺口 | 批36 遗留④ | 已确认仍在（`rss_web_bridge` 侧镜像写入异步） | 已知缺陷（边界） | 2~3 天 | 需跨 WebView/QuickJS 同步设计 | P3 |
| R30 | `downloadFile` 的选项 headers/method 仍不支持 | 批36 遗留⑤ | 已确认（完整语义需走 `AnalyzeUrl` 链路） | 功能缺口（小） | 1 天 | 依赖 AnalyzeUrl 复用 | P3 |
| R31 | 旧「前 16 位」cache 键与旧命名文件成为孤儿 | 批36 遗留⑦ | 已确认（缓存失效非数据丢失） | 技术债 | 0.5 天（迁移或忽略） | 无 | P3 |
| R32 | TXT 解码缓存 >64 MiB 退化（无提速但正确） | 批35 遗留① | 已确认：`txt_cache.rs` 单条超限不缓存；彻底方案需原始字节索引 + DB 迁移 | 技术债 | 3~5 天 | 独立批次（需 DB 迁移） | P3 |
| R33 | `detect_encoding` 对 FIFO/字符设备会阻塞到 EOF | 批35 遗留③ | 已确认：`txt.rs:277-278` 用 `read_up_to` 填满 64KB | 已知缺陷（边缘） | 0.5 天（非普通文件跳过） | 无 | P3 |
| R34 | `cargo audit` 剩余 6 warnings（`genpdf`/`printpdf` unmaintained） | 批34 遗留⑤ | 已确认：`rust/.cargo/audit.toml` 仅 ignore 2 条 RUSTSEC；`genpdf→printpdf 0.12` 重写可清 6 项 | 技术债 | 2~3 天（PDF 导出重写） | 需功能回归 | P3 |
| R35 | 测试抖动三例（`engine_cache::invalidate_forces_rebuild` 等） | 批34 遗留③ | 已确认仍为既有隔离缺陷 | 技术债 | 1 天 | 无 | P3 |
| R36 | A1-4 TTS 实际发声（MuMu 无 TTS 引擎，仅降级链 PASS） | 批45 遗留、L1243 | 已确认：设备无 `tts_default_*`；`audio_screen.dart` 代码链完整（引擎选择/音调落库/内联列表均已实现） | 实机项 | 0.5 天（需带 TTS 的 AVD 或真机） | **阻塞：无 TTS 硬件** | P2（阻塞） |
| R37 | A1-5 生物识别原生链路（无指纹硬件） | 同上 | 已确认：`PrivacyBiometricBridge.kt` + `privacy_biometric_service.dart` 齐备；批9d 仅「降级验收 5/5 PASS」 | 实机项 | 0.5 天 | **阻塞：无指纹/iOS 硬件** | P2（阻塞） |
| R38 | A* 实网验收 9 项（验证码实网、登录倒计时、外链确认等） | P2-4 矩阵 | 矩阵在 `RESIDUAL_RISKS_2026-08-13.md` §A*，逐项待素材 | 实机项 | 依项而定 | 需真实账号/素材 | P3 |
| R39 | P2-23 iOS 自动任务降级 + 真机走查 | P2-23 | 工程侧已可编译验证；真机待 Apple 设备 | 实机项 | 待设备 | 无 Apple 设备 | P3 |
| R40 | P2-26 iOS CI 签名（脚手架已交付 `4d5366d818`） | P2-26 | 态 A（无 secrets）默认，CI 绿；态 B 未实证 | 实机项/技术债 | 0.5 天（配置 4 secrets） | 需 Apple Developer Program | P3 |
| R41 | 低优候选 1：`md3_acceptance_matrix_test.dart` 仅 4 屏，详情/阅读两屏无单测级渲染防护 | 低优候选1 | 已确认：矩阵仅 `theme_config/home/settings/search` | 技术债（测试） | 1 天 | 无 | P3 |
| R42 | 低优候选 2：Characters/RelatedBooks 后端数据链 + AI 摘要 | 低优候选2 | 已确认：`API_CONTRACT.md` **无** `getBookCharacters`/`getRelatedBooks`（grep 0 命中）；`book_info_screen_builders.part.dart:1571-1613` 为 `const []` 空骨架 | 功能缺口 | 5~8 天 | 需契约先行 + 用户授权排期 | P3 |
| R43 | 深色主题台账 44 屏「待补采」参考截图 | `DARK_THEME_PARITY_LEDGER_20260920.md` | 已确认：台账 `待补采` 出现 44 次；但后续批 3b/8b/13 已大量实机验证（该台账未回销） | 文档偏差 + 实机项 | 依屏幕数 | 需参考版设备 | P3 |
| R44 | 「待优化台账」6 项 UX（替换规则保存不返回数据、测试空 pattern 提示被覆盖、RSS 末条判底复用首条 sort、崩溃弹窗溢出 12px、Web 服务卡片仅 Switch 可点、冒烟脚本存根遮蔽） | L849 | 逐项核实：①仍保留（`source_write_api.rs:1103-1106` 注释明示 1:1 保留原版怪癖）；④已修（`crash_log_dialog.dart:88-99` 有宽度约束注释）；其余未逐项复核 | 已知缺陷（UX） | 2~3 天 | **偏离原版需用户确认** | P3 |
| R45 | `README.md` 版本 `2.0.510+511` vs `pubspec.yaml` `2.0.512+513` | 文档卫生 | 已确认不一致 | 文档偏差 | 5 分钟 | 无 | P2 |
| R46 | `docs/DEVELOPMENT.md` 称「31 个 Repository」，实测 `rust/legado-db/src/repository/*.rs` = **32** | 文档卫生 | 已确认不一致 | 文档偏差 | 5 分钟 | 无 | P3 |
| R47 | 8 个未跟踪证据目录（`docs/evidence/batch39c`/`batch45d`/`batch46b` + batch33 5 个文件） | 仓库卫生 | `git status --porcelain` 8 项 `??` | 技术债（卫生） | 10 分钟（提交或删除） | 需确认是否入库 | P2 |

---

## 三、文档与代码不一致项（13 处，逐条给证据）

| # | 文档表述 | 实际状态 | 证据 |
|---|---|---|---|
| **I-01** | `L1289`（最后一条，2026-11-20）「下一步：L10N 阶段 3（剩约 54 处）、**C1 逐表备份忽略**」 | **C1 已完成**（2026-11-18 `65fbe842e0`） | `rust/legado-ffi/src/api/backup_api.rs:529-700`（`BACKUP_IGNORE_IDENTIFIERS` 28 别名 → 16 段）、`:832-839`、`:1160-1164`；Dart `backup_content_service.dart` + `backup_content_dialog.dart` + `webdav_settings_screen.dart:148-213`；`API_CONTRACT.md:15/849/875`；`CHANGELOG.md:25`；测试 `backup_content_service_test.dart` 11 例 + `webdav_settings_test.dart` 2 例全过（`docs/evidence/batch47b/spot2b_backup_content_service.log`） |
| **I-02** | 「L10N 剩约 54 处」（`L1285`/`L1287`/`L1289` 三处） | 实测 **4391 处** UI 中文字面量 / **288 文件** / **3197 条去重** | Python 扫描 `flutter_legado/lib`（排除 `app_strings.dart` 与 `debugPrint`/`assert`）：`occurrences 4587`、`distinct 3197`；仅排除日志后 4391。Top 文件 `reader_config_panel_builders.part.dart` 141 处（如 `'翻页模式'`、`'自动翻页'`、`'点击区域设置'`） |
| **I-03** | 「tmp_* 69 个 60GB + .tmp/ 4.5GB」（`L1285` 批45 遗留⑤） | 实测 `tmp_debug` **1.1 GB / 42 个 acceptance 目录**、`tmp_*` 合计 **1.2 GB / 16 项**、`.tmp` **645 MB** | `du -sh tmp_debug` = 1.1G；`ls -d tmp_debug/device_acceptance_*` = 42；`du -ch tmp_*` = 1.2G；`du -sh .tmp` = 645M。真实大头是 `rust/target` 329G（构建产物，已 gitignore） |
| **I-04** | 「7 个零引用组件…待移动」（`L1285` 批45 遗留④） | **已移动完成**，仅剩 `git rm` | `git ls-files docs/pending_deletion` 列出 7 个 `.dart`；全 `lib/` 逐类名 grep 7/7 命中 0；`test/` 零引用 |
| **I-05** | 「书源 JS `openVideoPlayer` 浮窗直启仍绕过闸门（P2）」（`L1285` 批45 遗留⑥） | **已修** | `30d404de04`（批42 P2-7）；`platform_bridge_service.dart:1046-1099` 两分支均过 `_allowOpenVideoPlayer`；`fea0555073` 载荷带 `bookUrl`；`85d1f8b3ec` 补 e2e 用例 |
| **I-06** | 「`is_invalid_group` 的 `contains("失效")` … 会误删用户自建分组」（`L1285` 批45 遗留⑧） | **已改为精确白名单** | `e6f53a1e76`（B14）；`legado-fetcher/src/source_check.rs:84-105` 的 `invalid_group_names_domain()` 为 10 项精确匹配，注释明示「与上游 `"失效" in it` 是有意偏离」 |
| **I-07** | 「L10N 阶段 2/3 待续——全 `lib/` UI 层仍剩约 **6137 处**（Top：`theme_config_screen` 263、`read_aloud_settings_screen` 189、`reader_config_panel_builders.part` 139）」（批39 遗留①） | **Top 两个文件已清零**（阶段 2 `589b353053`） | 实测 `theme_config_screen.dart` ui_cjk=**0**（12 处均为 `debugPrint`）、`read_aloud_settings_screen.dart` ui_cjk=**0**（2 处 debugPrint/assert）、`webdav_settings_screen.dart` ui_cjk=**0**、`rss_source_manage_screen.dart` 0、`source_edit_screen*.dart` 全部 0 |
| **I-08** | 批39 遗留③「`lastUpdateTime` 编辑打戳缺失」 | **已修** | `5e33216758`（B12）；`api/source.rs:82-136` 注释与 `apply_last_update_time` 实现齐备 |
| **I-09** | 批39 遗留⑦「FFI 路径不更新 `respondTime`」 | **已修** | `e6f53a1e76`（B13）；`api/source_check_api.rs:471-473/583-613` |
| **I-10** | 批29「滚动模式规则与手动高亮均未接线」（`reader_page_view.dart:1285` 注释自述） | **已接线** | `reader_page_view.dart:2399-2404`（分页路径）与 `:2424-2426`（滚动回退路径）均传 `highlightMatches` |
| **I-11** | 批37 遗留③「设置页清理缓存副标题与实际范围不符（P3）」 | **已修** | `bfcf16d21e`；`app_strings.dart:512` = 「清除章节缓存与书源缓存 / Clear chapter and source caches」 |
| **I-12** | 批38 遗留⑥「本地跑 `flutter test` 前须先 `cargo build -p legado-ffi --features quickjs`」+ 「CI Flutter 3.50.0、本地 3.44.8」 | 现状：本地 **3.44.8**（实测 `flutter --version`），CI 未在本轮核实；`flutter analyze` 实测 **0 issue**（`No issues found!`） | `flutter --version` → 3.44.8；`flutter analyze --no-fatal-infos` → `No issues found! (ran in 34.3s)` |
| **I-13** | `README.md:71`「当前版本：**2.0.510+511**」 | 实际 `pubspec.yaml:4` = **2.0.512+513**；`updateLog.md` 已到 2.0.512 | `grep "^version" flutter_legado/pubspec.yaml`；`CHANGELOG.md:5 ## [2.0.512]` |

> 说明：`I-01`~`I-11` 属「文档滞后于代码」（代码已修/已做，文档未回销）；`I-12`/`I-13` 属「入口文档与实际环境/版本不一致」。本仓历史上多次出现「正文滞后」先例（`L1255` 审查批E 已登记过同类义务）。

---

## 四、建议优先处理的 5 项

### 1️⃣ R01 — 重建三 ABI `.so`（发版阻断）
**理由**：`rust-fingerprint.ps1 -Check` 实测 `DECISION=REBUILD`，arm64 与 x86_64 的 `.so` 指纹均为 `0288169cb3f2a677…`，当前源码指纹 `b1c0003bb55e7f8d…`。差异来自 `c3d95bda8e` 对 `audio_cache_api.rs` 的改动。若此时打 release 包，**HLS 缓存相关的任何修复都不会进包**——这类「`.so` 陈旧导致假通过」在本仓有过先例（`L234` 记录）。工作量仅 0.5 天，风险最低、收益最直接。

### 2️⃣ R02 — L10N 阶段 3 重新排期（数字需先纠正）
**理由**：文档说 54 处，实际 4391 处（80 倍差）。这不是「收尾」而是「还有大半个阶段」。必须先让用户知道真实体量，再决定：分批（每批 ≤300 处，约 15 批）／缩小范围（仅保留高频路径）／或明确「英文为部分覆盖」并在 UI 明示。**不纠正数字就派单，会立刻造成第二批「发现还剩 4000 处」的返工**。

### 3️⃣ R04 — JS `setCookie` → App 罐单向补齐
**理由**：批38 已把三罐收敛为「HTTP→JS 单向」，「JS→HTTP」仍是断点。后果是**登录态两侧可能不一致**：书源脚本用 `java.setCookie` 写入的会话，主链路 HTTP 请求（详情/目录/正文）看不到，表现为「脚本登录成功但下一次请求 401」。属安全/可用性交叉面，且有明确实现路径（`JsCookieDbSink::upsert` 内补一次 `shared_cookie_store` 写穿，锁序 D→C→P→G 已在批38 论证）。

### 4️⃣ R05 + R06 + R07 — Web 写面三个已知缺陷打包
**理由**：三项同在 `legado-server` 源管理面，可一次派单、一次验收：
- `GET /api/sources` 免令牌返回含 `variable`（登录态）且无 `no-store` —— 同网段任意设备可读取全部书源凭据；
- `repo_url` 无 DNS 解析后校验 —— SSRF 面（字面量已拦，解析后未拦）；
- `PUT` 改 URL 留旧行 —— 数据面产生重复源。

前两项是批23/24 建立令牌体系后的**同类遗漏**（当时只覆盖写方法与 webbook 四端点），属体系一致性缺口；第三项是数据正确性。

### 5️⃣ R22 + R24 + R47 — 仓库卫生一次清账
**理由**：三项都是「已判定、零风险、只差执行」的清理：7 个零引用组件（观察期已满、grep 已复核 0）、`tmp_debug` 1.1 GB + `tmp_*` 1.2 GB（已被 gitignore，纯磁盘占用）、8 个未跟踪证据目录。合计 30~40 分钟。放在这里而不是更低优先级，是因为**它们持续干扰后续盘点**（本轮盘点就被「69 个 60GB」的错误数字误导了一次）。

---

## 五、核实方法与可复现命令

```bash
# 1. 计划文档读取（Git Bash 的 grep 对中文不可靠，必须 Python + UTF-8）
python -c "import io; print(len(io.open('docs/REFACTORING_ACTIVE_PLAN.md',encoding='utf-8').read().splitlines()))"
# → 1289

# 2. C1 逐表备份忽略
grep -rn "BACKUP_IGNORE_IDENTIFIERS\|load_ignored_backup_sections" rust/legado-ffi/src/api/backup_api.rs
git merge-base --is-ancestor 65fbe842e0 HEAD && echo YES   # → YES
git show --stat 65fbe842e0 | head -12                      # 8 文件 +1264/-130

# 3. L10N 实测（排除字符串表与日志）
#    Python 脚本：遍历 flutter_legado/lib/**/*.dart，跳过 src/l10n/app_strings.dart，
#    跳过含 debugPrint/assert(/log( 的行与 // 注释行，正则匹配含 CJK 的字符串字面量
#    → occurrences 4587 / distinct 3197 / 288 文件

# 4. HLS 四条边界
grep -n "SAMPLE-AES" rust/legado-ffi/src/api/hls_playlist.rs           # :740-745 硬 Err
grep -n "KEYFORMAT" rust/legado-ffi/src/api/hls_playlist.rs            # 0 命中（未解析）
grep -n "looks_like_m3u8\|first_chunk" rust/legado-ffi/src/api/audio_cache_api.rs  # :1065-1066
grep -n "timeout: None" rust/legado-ffi/src/api/audio_cache_api.rs     # :1294
grep -n "return Err(LegadoError::Network" rust/legado-ffi/src/api/audio_cache_api.rs  # :1703/:1756

# 5. 7 个零引用组件
git ls-files docs/pending_deletion
for c in SearchBarWidget SwipeAction SourceCard TagChip BadgeWidget ChapterTile CustomProgress; do
  echo "$c -> $(grep -rn "\b$c\b" flutter_legado/lib --include=*.dart | wc -l)"; done   # 全 0

# 6. 磁盘占用
du -sh tmp_debug .tmp; du -ch tmp_* | tail -1; du -sh rust/target

# 7. WebDAV getConfig stub 缺失
for f in $(grep -rln "WebDavSettingsScreen" flutter_legado/test/); do
  grep -q "getConfig" "$f" || echo "NO_STUB: $f"; done
# → 8 个文件 NO_STUB（仅 settings_test.dart 有）

# 8. 门禁现状（本轮实测）
cd flutter_legado && flutter analyze --no-fatal-infos     # → No issues found!
cd rust && CARGO_HTTP_PROXY="" cargo fmt --all -- --check  # → exit 0
pwsh rust/scripts/rust-fingerprint.ps1 -Check             # → DECISION=REBUILD
```

---

## 六、按类型的完整分布

| 类型 | 编号 | 数量 |
|---|---|---|
| **功能缺口** | R02、R26、R30、R42 | 4 |
| **已知缺陷** | R04、R05、R06、R07、R17、R18、R19、R20、R25、R29、R33、R44 | 12 |
| **文档偏差** | R45、R46、R43 | 3 |
| **实机项** | R36、R37、R38、R39、R40 | 5 |
| **技术债** | R01、R21、R22、R23、R24、R28、R31、R32、R34、R35、R41、R47 | 12 |
| **已对齐（无需做）** | R03、R08、R09、R10、R11、R12、R13、R14、R15、R16、R27 | 11 |

> 合计 4+12+3+5+12+11 = **47**。其中「已对齐 11 项」为**本轮核实后确认无需动作**（代码已实现，文档未回销），建议在 ACTIVE_PLAN 一次性回销，避免下轮盘点再次误入清单。
> 第三节另列 **13 处文档与代码不一致**（I-01~I-13），其中 11 处即上述「已对齐」项的成因，2 处（I-12 环境口径、I-13 README 版本）独立于 R 编号。

---

## 七、给下一批派单的直接建议

| 批次 | 内容 | 文件面（互不重叠） | 可否并行 |
|---|---|---|---|
| **批 A** | R01 `.so` 三 ABI 重建 + 冒烟 | 仅构建产物 | 独占（构建期不能跑 flutter test） |
| **批 B** | R05+R06+R07 Web 写面三缺陷 | `rust/legado-server/src/{routes.rs,handlers/source.rs,handlers/source_update.rs,web_assets.rs}` | 可与批 C 并行 |
| **批 C** | R22+R23+R47 仓库卫生清账 | `docs/pending_deletion/**`、`docs/evidence/**` | 可与批 B 并行 |
| **批 D** | R04 JS→App 罐单向补齐 | `rust/legado-ffi/src/http_state.rs` + `rust/legado-js/src/host_api/cookie_store.rs` | 需独立（锁序敏感） |
| **批 E** | R25 8 个测试 stub + R45/R46 文档版本 | `flutter_legado/test/widget/webdav_*.dart`、`README.md`、`docs/DEVELOPMENT.md` | 可与批 B/C 并行 |
| **批 F** | R17~R21 HLS 五条边界 | `rust/legado-ffi/src/api/{hls_playlist.rs,audio_cache_api.rs}` | 需独立（同文件） |
| **批 G** | R02 L10N 分批（每批 ≤300 处，先按目录切） | 按目录分批 | 每批内可拆两子代理 |

**建议先做的三件事（零代码）**：
1. 把 I-01~I-13 的 13 处不一致回销进 ACTIVE_PLAN（尤其「C1 已完成」与「L10N 真实量」）；
2. 修正 `L1285`/`L1287`/`L1289` 三处「54 处」为实测口径（并注明统计方法，便于下轮复核）；
3. 修正 `L1285` 的「69 个 60GB + 4.5GB」为实测「`tmp_debug` 1.1G / `tmp_*` 1.2G / `.tmp` 645M / `rust/target` 329G」。

---

*报告生成：2026-11-20 ｜ 基线 `c3d95bda8e` / 2.0.512+513 ｜ 只读调研，未改任何代码*

---

## 附录 A：`tmp_debug/device_acceptance_*` 42 个目录处置盘点（2026-11-20）

> 只读盘点，**未删除任何文件**。处置需用户裁决。

### A.1 统计口径

- 清点对象：`tmp_debug/` 下 42 个 `device_acceptance_*` 目录（全部被 `.gitignore:44-45` 忽略，`git ls-files tmp_debug` = 0）
- 实测总量：`tmp_debug` 合计 **1.02 GB / 8,657 文件**，其中 acceptance 42 目录 **0.80 GB / 7,068 文件**，其余 272 项 **0.23 GB**（最大为 `e2e_5558` 162.8 MB / 1,164 文件）
- 归档比对方法：对每个文件算 SHA-256，与 `docs/evidence/**`（2,453 文件 / 1,689 唯一哈希）+ `docs/materials_*`（73 个目录 / 6,250 文件 / 5,477 唯一哈希）合并索引比对；>16 MB 文件跳过哈希、只按文件名核对
- 「已归档」列以**截图**为口径（截图是验收结论的承重证据；`.log`/`.txt`/`.xml` 属原始过程日志，可由文档结论覆盖）
- 「唯一副本」= 该目录内**未被任一归档目录覆盖的非日志文件**数（含 `.db`/`.json`/`.sql`/`.sh`/`.py`/`.cbz`/`.png` 等）

### A.2 分类表

| # | 目录名 | 大小 | 文件数 | mtime 范围 | 主要类型 | 截图归档情况 | 唯一非日志副本 | 建议 |
|---|---|---|---|---|---|---|---|---|
| 1 | `device_acceptance_20261026` | 3.3 MB | 51 | 2026-10-26~2026-10-26 | .xml×21、.txt×14、.png×13、.log×2 | 0/13 | 14 | **需先归档** |
| 2 | `device_acceptance_20261027` | 32.6 MB | 407 | 2026-10-27~2026-10-27 | .xml×186、.png×129、.txt×59、.json×19 | 0/129 | 146 | **需先归档** |
| 3 | `device_acceptance_20261027_7z` | 21.4 MB | 228 | 2026-10-27~2026-10-28 | .txt×50、.png×37、.xml×36、(noext)×20 | 0/37 | 72 | **需先归档** |
| 4 | `device_acceptance_20261027_backup_pwd` | 15.4 MB | 176 | 2026-10-27~2026-10-27 | .xml×90、.png×36、.txt×24、.b64×6 | 0/36 | 58 | **需先归档** |
| 5 | `device_acceptance_20261027_export_tree` | 8.6 MB | 122 | 2026-10-28~2026-10-28 | .png×42、.xml×41、.txt×30、.json×6 | 0/42 | 49 | **需先归档** |
| 6 | `device_acceptance_20261027_remote_book` | 10.8 MB | 113 | 2026-10-27~2026-10-27 | .png×73、.txt×18、.log×9、.xml×6 | 0/73 | 80 | **需先归档** |
| 7 | `device_acceptance_20261027_rss_bridge` | 8.9 MB | 106 | 2026-10-27~2026-10-27 | .png×51、.txt×17、.xml×14、.sql×8 | 0/51 | 71 | **需先归档** |
| 8 | `device_acceptance_20261028_batch2729` | 14.0 MB | 108 | 2026-10-28~2026-10-28 | .png×70、.txt×16、.db×6、.log×6 | 0/70 | 82 | **需先归档** |
| 9 | `device_acceptance_20261028_batch31` | 13.7 MB | 85 | 2026-10-29~2026-10-29 | .png×52、.txt×19、.log×5、.json×4 | 0/52 | 60 | **需先归档** |
| 10 | `device_acceptance_20261028_batch34` | 14.0 MB | 125 | 2026-10-29~2026-10-29 | .png×54、.xml×46、.txt×17、.log×5 | 0/54 | 57 | **需先归档** |
| 11 | `device_acceptance_20261029_batch35` | 9.1 MB | 60 | 2026-10-29~2026-10-29 | .png×35、.txt×11、.log×6、.xml×3 | 0/35 | 40 | **需先归档** |
| 12 | `device_acceptance_20261029_batch36` | 12.6 MB | 120 | 2026-10-29~2026-10-29 | .png×81、.log×11、.xml×11、.txt×9 | 0/81 | 88 | **需先归档** |
| 13 | `device_acceptance_20261029_batch37` | 17.1 MB | 181 | 2026-10-29~2026-10-29 | .xml×79、.png×73、.txt×14、.log×3 | 0/73 | 85 | **需先归档** |
| 14 | `device_acceptance_20261029_batch38` | 19.6 MB | 277 | 2026-10-30~2026-10-30 | .xml×147、.png×108、.json×6、.txt×6 | 0/108 | 121 | **需先归档** |
| 15 | `device_acceptance_20261029_batch40` | 23.3 MB | 147 | 2026-10-30~2026-11-17 | .png×111、.txt×12、.log×8、.xml×6 | 0/111 | 121 | **需先归档** |
| 16 | `device_acceptance_20261030_batch39_43` | 38.5 MB | 908 | 2026-10-30~2026-10-30 | .xml×773、.png×49、.sh×38、.log×26 | 49/49 | 50 | **需先归档** |
| 17 | `device_acceptance_20261031_batch1a` | 10.6 MB | 163 | 2026-10-31~2026-10-31 | .xml×91、.png×55、.sh×10、.txt×5 | 55/55 | 10 | **需先归档** |
| 18 | `device_acceptance_20261031_batch1b1` | 5.0 MB | 57 | 2026-10-31~2026-10-31 | .png×23、.xml×14、.sh×12、.txt×6 | 23/23 | 12 | **需先归档** |
| 19 | `device_acceptance_20261031_batch1b3` | 5.9 MB | 119 | 2026-10-31~2026-10-31 | .xml×85、.png×24、.sh×3、.txt×3 | 24/24 | 5 | **可删** |
| 20 | `device_acceptance_20261031_batch9a` | 15.6 MB | 226 | 2026-10-31~2026-10-31 | .xml×115、.png×97、.sh×8、.log×3 | 97/97 | 11 | **需先归档** |
| 21 | `device_acceptance_20261031_batch9b1` | 9.9 MB | 68 | 2026-10-31~2026-10-31 | .xml×24、.png×18、.log×11、.sql×8 | 18/18 | 9 | **需先归档** |
| 22 | `device_acceptance_20261031_batch9b2` | 16.2 MB | 113 | 2026-10-31~2026-11-01 | .png×55、.xml×34、.log×11、.txt×6 | 45/55 | 17 | **需先归档** |
| 23 | `device_acceptance_20261031_batch9b4` | 4.2 MB | 128 | 2026-10-31~2026-10-31 | .xml×92、.png×16、.log×11、.json×4 | 15/16 | 7 | **需先归档** |
| 24 | `device_acceptance_20261101_batch1b2a` | 21.4 MB | 202 | 2026-11-01~2026-11-01 | .png×116、.xml×81、.txt×2、.log×2 | 55/116 | 62 | **需先归档** |
| 25 | `device_acceptance_20261101_batch1b2a_reverify` | 19.4 MB | 132 | 2026-11-01~2026-11-01 | .png×83、.xml×44、.txt×2、.log×2 | 35/83 | 49 | **需先归档** |
| 26 | `device_acceptance_20261101_batch2a1` | 111.9 MB | 98 | 2026-11-01~2026-11-01 | .png×82、.txt×6、.log×5、.json×2 | 78/82 | 8 | **需先归档** |
| 27 | `device_acceptance_20261101_batch2b1a` | 30.5 MB | 97 | 2026-11-01~2026-11-01 | .png×78、.txt×7、.log×5、.jpg×2 | 76/80 | 7 | **需先归档** |
| 28 | `device_acceptance_20261101_batch2b1b1` | 1.0 MB | 23 | 2026-11-01~2026-11-01 | .xml×6、.log×6、.py×6、.sh×2 | 0/1 | 10 | **需先归档** |
| 29 | `device_acceptance_20261101_batch9b6` | 29.5 MB | 83 | 2026-11-01~2026-11-01 | .txt×59、.png×16、.log×3、.py×2 | 16/16 | 3 | **可删** |
| 30 | `device_acceptance_20261101_batch9b6c` | 21.1 MB | 104 | 2026-11-01~2026-11-01 | .xml×53、.png×32、.txt×11、.log×6 | 32/32 | 2 | **可删** |
| 31 | `device_acceptance_20261101_reverify` | 14.5 MB | 61 | 2026-11-01~2026-11-01 | .png×50、.log×5、.json×3、.py×2 | 34/50 | 21 | **需先归档** |
| 32 | `device_acceptance_20261102_batch2b1b2a` | 5.1 MB | 21 | 2026-11-02~2026-11-02 | .png×5、.txt×5、.log×5、.xml×3 | 0/5 | 8 | **需先归档** |
| 33 | `device_acceptance_20261102_reverify_saf` | 83.1 MB | 94 | 2026-11-02~2026-11-02 | .xml×67、.txt×15、.png×5、.log×5 | 0/6 | 7 | **需先归档** |
| 34 | `device_acceptance_20261103_batch2b1b2b` | 58.2 MB | 379 | 2026-11-03~2026-11-03 | .png×194、.xml×154、.txt×16、.log×5 | 59/196 | 145 | **需先归档** |
| 35 | `device_acceptance_20261103_batch2b2a` | 5.7 MB | 220 | 2026-11-02~2026-11-03 | .xml×197、.txt×6、.log×6、.py×5 | 0/3 | 11 | **需先归档** |
| 36 | `device_acceptance_20261103_batch2b2b` | 20.7 MB | 294 | 2026-11-03~2026-11-03 | .xml×178、.png×104、.txt×6、.log×5 | 104/104 | 1 | **可删** |
| 37 | `device_acceptance_20261103_batch2b2c` | 4.1 MB | 86 | 2026-11-03~2026-11-03 | .xml×33、.png×26、.html×17、.txt×4 | 0/26 | 45 | **需先归档** |
| 38 | `device_acceptance_20261103_m1` | 10.7 MB | 194 | 2026-11-03~2026-11-03 | .xml×110、.png×62、.txt×12、.log×8 | 34/62 | 30 | **需先归档** |
| 39 | `device_acceptance_20261103_m2` | 10.5 MB | 153 | 2026-11-03~2026-11-03 | .xml×88、.png×47、.log×10、.txt×7 | 47/47 | 1 | **可删** |
| 40 | `device_acceptance_20261103_m3` | 12.9 MB | 239 | 2026-11-03~2026-11-03 | .xml×160、.png×63、.log×8、.txt×7 | 62/63 | 2 | **需先归档** |
| 41 | `device_acceptance_20261103_reverify` | 9.6 MB | 158 | 2026-11-03~2026-11-03 | .xml×147、.log×6、.txt×3、.py×2 | 无截图 | 2 | **可删** |
| 42 | `device_acceptance_20261104` | 16.9 MB | 342 | 2026-11-03~2026-11-03 | .png×147、.xml×127、.html×26、.txt×21 | 102/149 | 86 | **需先归档** |

**合计**：42 目录 / 0.80 GB。其中「可删」6 个（97.2 MB），「需先归档」36 个（719.8 MB）。

### A.3 「可删」清单（截图已 100% 命中归档，剩余唯一副本 ≤5 个脚本文件）

| 目录 | 大小 | 截图命中 | 唯一非日志副本（文件名） |
|---|---|---|---|
| `device_acceptance_20261031_batch1b3` | 5.9 MB | 24/24 | `data/build-android-bom.ps1`、`data/setcfg.sh`、`data/reparse_via_settings.sh`、`data/qa1b3_expect.json`、`data/dbq3.sh` |
| `device_acceptance_20261101_batch9b6` | 29.5 MB | 16/16 | `data/uia.py`、`data/locks.py`、`data/s5_probe.sh` |
| `device_acceptance_20261101_batch9b6c` | 21.1 MB | 32/32 | `data/s2_lockscreen.sh`、`data/probe.sh` |
| `device_acceptance_20261103_batch2b2b` | 20.7 MB | 104/104 | `scripts/dev.py` |
| `device_acceptance_20261103_m2` | 10.5 MB | 47/47 | `scripts/ui.py` |
| `device_acceptance_20261103_reverify` | 9.6 MB | 0/0 | `scripts/ui.py`、`scripts/open_nav_sheet.py` |

### A.4 「需先归档」中的重点（唯一副本 ≥40 个非日志文件）

| 目录 | 大小 | 唯一非日志副本 | 说明 |
|---|---|---|---|
| `device_acceptance_20261027` | 32.6 MB | 146 | 截图仅 0/129 命中，UI 树与截图未入库 |
| `device_acceptance_20261027_7z` | 21.4 MB | 72 | 截图仅 0/37 命中，UI 树与截图未入库 |
| `device_acceptance_20261027_backup_pwd` | 15.4 MB | 58 | 截图仅 0/36 命中，UI 树与截图未入库 |
| `device_acceptance_20261027_export_tree` | 8.6 MB | 49 | 截图仅 0/42 命中，UI 树与截图未入库 |
| `device_acceptance_20261027_remote_book` | 10.8 MB | 80 | 截图仅 0/73 命中，UI 树与截图未入库 |
| `device_acceptance_20261027_rss_bridge` | 8.9 MB | 71 | 截图仅 0/51 命中，UI 树与截图未入库 |
| `device_acceptance_20261028_batch2729` | 14.0 MB | 82 | 截图仅 0/70 命中，UI 树与截图未入库 |
| `device_acceptance_20261028_batch31` | 13.7 MB | 60 | 截图仅 0/52 命中，UI 树与截图未入库 |
| `device_acceptance_20261028_batch34` | 14.0 MB | 57 | 截图仅 0/54 命中，UI 树与截图未入库 |
| `device_acceptance_20261029_batch35` | 9.1 MB | 40 | 截图仅 0/35 命中，UI 树与截图未入库 |
| `device_acceptance_20261029_batch36` | 12.6 MB | 88 | 截图仅 0/81 命中，UI 树与截图未入库 |
| `device_acceptance_20261029_batch37` | 17.1 MB | 85 | 截图仅 0/73 命中，UI 树与截图未入库 |
| `device_acceptance_20261029_batch38` | 19.6 MB | 121 | 截图仅 0/108 命中，UI 树与截图未入库 |
| `device_acceptance_20261029_batch40` | 23.3 MB | 121 | 截图仅 0/111 命中，UI 树与截图未入库 |
| `device_acceptance_20261030_batch39_43` | 38.5 MB | 50 | 截图仅 49/49 命中，UI 树与截图未入库 |
| `device_acceptance_20261101_batch1b2a` | 21.4 MB | 62 | 截图仅 55/116 命中，UI 树与截图未入库 |
| `device_acceptance_20261101_batch1b2a_reverify` | 19.4 MB | 49 | 截图仅 35/83 命中，UI 树与截图未入库 |
| `device_acceptance_20261103_batch2b1b2b` | 58.2 MB | 145 | 截图仅 59/196 命中，UI 树与截图未入库 |
| `device_acceptance_20261103_batch2b2c` | 4.1 MB | 45 | 截图仅 0/26 命中，UI 树与截图未入库 |
| `device_acceptance_20261104` | 16.9 MB | 86 | 截图仅 102/149 命中，UI 树与截图未入库 |

### A.5 两个「无对应验收文档」的目录

| 目录 | 大小 | 唯一非日志副本 | 风险 |
|---|---|---|---|
| `device_acceptance_20261026` | 3.3 MB | 14 | 全仓 `docs/*.md` 无任何引用，来源与结论不可追溯，**删除前必须先补文档或整目录归档** |
| `device_acceptance_20261103_batch2b2c` | 4.1 MB | 45 | 全仓 `docs/*.md` 无任何引用，来源与结论不可追溯，**删除前必须先补文档或整目录归档** |

### A.6 体积大头（删除收益集中处）

| 文件 | 大小 | 目录 |
|---|---|---|
| `logcat/final_session_2a1.log` | 99.4 MB | `device_acceptance_20261101_batch2a1` |
| `fixtures/saf_huge_48mb.png` | 45.8 MB | `device_acceptance_20261102_reverify_saf` |
| `fixtures/saf_33mb_padded.png` | 33.0 MB | `device_acceptance_20261102_reverify_saf` |
| `logcat/full_session_9b2.log` | 7.2 MB | `device_acceptance_20261031_batch9b2` |
| `logcat/session_2b1a.log` | 5.7 MB | `device_acceptance_20261101_batch2b1a` |
| `logcat/full_session_9b1*.sql`（`data/qa9b1_bulk20k.sql`） | 5.3 MB | `device_acceptance_20261031_batch9b1` |

> 单这两张 `saf_*` 大图 + 一个 99 MB logcat 即占 178 MB（占总量的 22%），且均为可再生成的压测夹具/原始日志。


---

## 附录 B：WebDAV `getConfig` stub 缺失精确清单（任务 4，只列不修）

### B.1 噪声来源确认

`flutter_legado/lib/src/screens/webdav_settings_screen.dart:207-213` 的 `_loadAll()`：

```dart
try {
  backupContentIgnored = await BackupContentService(
    api: ref.read(bookApiProvider),
  ).load();   // → _api.getConfig('backupIgnoreTables')
} catch (e) {
  debugPrint('[WebDavSettings] 读取备份内容忽略配置失败：$e');
}
```

`BackupContentService.load()`（`lib/src/services/backup_content_service.dart:72-75`）第一句即 `await _api.getConfig(configKey)`。

当 `bookApiProvider` 被覆写为 **`FakeServersRustApi`（`extends MockRustApi extends Mock implements RustApi`）** 且未 stub `getConfig` 时，mocktail 的 `noSuchMethod` 返回 `null`，在 `Future<String?>` 返回位触发：

```
type 'Null' is not a subtype of type 'Future<String?>'
```

该异常被上面的 `catch` 吞掉并 `debugPrint` → 测试输出噪声，但**不导致用例失败**。

### B.2 9 个 pump `WebDavSettingsScreen` 的文件逐个判定

| # | 文件 | pump 位置 | API 类型 | 现有 stub | 是否产噪 | 需补行号 |
|---|---|---|---|---|---|---|
| 1 | `test/widget/webdav_restore_confirm_test.dart` | `:142` | `FakeServersRustApi` | 无 | **是** | 在 `:88` 之后 |
| 2 | `test/widget/webdav_local_restore_seen_test.dart` | `:112` | `FakeServersRustApi` | 无 | **是** | 在 `:71` 之后 |
| 3 | `test/widget/webdav_settings_screen_test.dart` | `:56` | `FakeServersRustApi` | 无 | **是** | 在 `:47` 之后 |
| 4 | `test/widget/webdav_backup_family_settings_test.dart` | `:42`、`:151` | `FakeServersRustApi` | 无 | **是** | 在 `:38` 之后（覆盖 `pumpScreen`）+ `:144` 之后（第 2 个内联 pump） |
| 5 | `test/widget/webdav_restore_password_test.dart` | `:136` | `FakeServersRustApi` | 无 | **是** | 在 `:95` 之后 |
| 6 | `test/widget/webdav_backup_restore_actions_test.dart` | `:185` | `FakeServersRustApi` | 无 | **是** | 在 `:120` 之后（变量名为 `api`，非 `mockApi`） |
| 7 | `test/widget/settings_test.dart` | `:1017`（路由表） | `FakeServersRustApi` | `setUp` 无全局 stub；该用例体内也无 | **是** | 用例体内 `:1013` 之前，或 `setUp` `:48` 之后加全局 stub |
| 8 | `test/widget/screens_overflow_regress_test.dart` | `:192`（屏清单） | **`MockBookApi`（真实实现）** | 不需要 | **否** | — |
| 9 | `test/widget/webdav_settings_test.dart` | `:45`、`:255` | `FakeServersRustApi` | `setUp:34` 已有 `when(() => mockApi.getConfig(any()))` | 否 | —（已合规，可作模板） |

### B.3 与调研报告的差异（需回销）

调研报告称「9 个 pump 中 8 个缺 stub」，实测为 **7 个**：

- 报告把 `screens_overflow_regress_test.dart` 计入了缺 stub 名单，但该文件用的是 **`MockBookApi`**（`lib/src/services/mock_book_api.dart`，非 mocktail Mock），其 `getConfig` 由 `mock_book_api_reader_data.part.dart:316` 真实实现 `Future<String?> getConfig(String key) async => _configs[key]`，**不会抛类型错误**，无需补 stub。
- 9 个文件中真正合规的只有 `webdav_settings_test.dart`（`setUp:34` 已有 stub）。

### B.4 建议补法（下批次执行，本批不改）

在每处 `mockApi = FakeServersRustApi();` 之后追加一行：

```dart
// C1：页面加载会读 caches `config:backupIgnoreTables`；未 stub 时 mocktail
// 返回 null 会在 `Future<String?>` 返回位抛类型错误，触发
// 「读取备份内容忽略配置失败」debugPrint 噪声（被兜底捕获，不影响断言）。
when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
```

注意：`webdav_backup_restore_actions_test.dart` 的变量名是 **`api`**，需写成 `when(() => api.getConfig(any()))`。

`settings_test.dart` 建议加在 `setUp`（`:48` 之后）而非单用例：mocktail 以「最后注册的匹配 stub」为准，各用例中更具体的 `when(() => mockApi.getConfig('backupIgnoreTables'))` 仍会覆盖它，不会破坏既有断言。

