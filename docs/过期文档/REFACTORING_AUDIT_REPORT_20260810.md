# Legado 重构进度全面审计报告（2026-08-10）

**报告日期**: 2026-08-10
**审计范围**: 重构后代码（rust/ + flutter_legado/，HEAD `3d9ddb94f`，v2.0.4+6）+ 上游最新（`upstream/master` = `36d58eea9`，#672，2026-08-10，v3.26.081008，cronet 151.0.7922.71）
**审计方法**: 4 个并行只读子代理源码实证（grep/读文件/契约核对/git 历史核实）+ `cargo test --workspace` 全绿 + 台账交叉核对；**未修改任何代码**
**审计人**: Reasonix
**修订**: v2（2026-08-10 二次修订）——依据用户台账更新（REMAINING_PLAN v1.17/v1.18、CHANGELOG 2.0.5/2.0.6）同步核对：设置源变量已销记（v1.17 Task #71）、customHosts/MCP 端口/封面规则已销记（v1.18 Task #78）、§5.14 新增 #9-#17 登记；§6 滞后修正项相应更新

---

## 1. 上游拉取与版本控制

- `git fetch upstream` 成功：拉到 3.26 系列 **35 个 tag**（`3.26071315` → `3.26081008`）
- 上游最新 = **#672**（36d58eea9，2026-08-10），较上次审计基线 #396（2026-07-25）推进 **250 提交 / 580 文件 / +41,508 −3,364 行**（app/ 占 525 文件 +37,847）
- 已建基准分支 **`integration/upstream-latest`**（跟踪 upstream/master）+ 独立 worktree（`D:\OH-WorkSpace\LegadoTeam\legado-upstream`），留中文 commit **`c0ba9afaf`「更新到最新源码（上游 #672，2026-08-10，v3.26.081008，cronet 151.0.7922.71）」**
- 主分支 `feature/rust-core` 与工作区 259 项未提交更改零影响

## 2. Rust 轨缺口闭合矩阵（实证结论）

| 项 | 结论 | 证据要点 |
|----|------|----------|
| R1+R2 subContent + replaceRegex | ✅ 真实闭合（txt/http 分支口径） | web_book.rs:613-692（分页后追加副内容、replaceRegex 全文替换）+ 单测 1873-2030；Kotlin 歌词/弹幕分流未实现但已被源码注释与文档口径承认 |
| R3 legado-server 正文接口 | ✅ 真实闭合 | handlers/web_book.rs:95-175、512-703；routes.rs:75 |
| R4 dict_api 字典规则引擎 | ✅ 真实闭合 | dict_api.rs:89-126（dict_rules 逐规则 + seed_default_rules 5 源测试断言） |
| R5 saveChapterContent 缓存写 FFI | ✅ 真实闭合 | cache_api.rs:90 + ffi.rs:1199-1214（契约 §2.43.1 一致）+ roundtrip 单测 |
| R6 chapterPayAction 三态 FFI | ✅ 真实闭合 | pay_action_api.rs:39-113（本地书短路 none/缺失报错/url·success·none 三态/success 清章缓存） |
| R7 缓存批量下载 4 方法 | ✅ 真实闭合 | cache_download_api.rs:68/204/224/240（worker+AtomicBool 取消令牌） |
| R8 bookExportWithOptions 四格式 | ✅ 真实闭合 | book_export.rs:71（txt/epub/html/pdf + 7 种编码）+ GBK 单测 |
| R9 font_api cmap 真实替换 | ✅ 真实闭合 | legado-js/src/host_api/query_ttf.rs（format 0/4/6 多子表）+ 端到端真字体单测 |
| R10 JS 书源段评回复 | ✅ 真实闭合 | js_source_book.rs:307 + review_api.rs:274-332（JS 分支+失败回退） |
| R12 bridge.rs C ABI DEPRECATED | ✅ 真实闭合 | bridge.rs:3-10 模块级标注 |
| QUIC 六件套移除 | ✅ 已移除确认 | legado-net 无 quic.rs/quic_api.rs、无 quinn 依赖、契约 §2.41 登记 |
| 08-06 四项 P1（nextContentUrl 99 页/audioSpeak TTS 管线/WebView 桥接拦截/rssUpdateSource 原子更新） | ✅ 全部真实闭合 | web_book.rs:715、tts_speak_api.rs:55、platform_bridge_service.dart:60-68、rss.rs:103-119 |
| 上次十项缺口 | **13/17 真实闭合**；2 项部分；4 项未闭合 | 见下方 §2.1 |
| 测试 | `cargo test --workspace` 全绿（0 failed） | 各 crate 单测+集成全过；17 个 style warning（highlight.rs non_snake_case×15、rule_analyzer unused_assignments×1、js_source_config unused import×1） |

### 2.1 十项缺口剩余明细

- **部分闭合（2 项）**：infoHtml 缓存复用依赖入参（web_book.rs:443 注释自认）；nextChapterUrl 越界以 URL 去重+页数上限兜底（web_book.rs:851-852 源码注释登记）
- **未闭合（4 项）**：
  - ① **RuleData 变量表**：rust/ 全仓无实现（Kotlin BookList.kt:37/72 依赖 ruleData.getVariable()）
  - ② **filter/shouldBreak**：搜索/发现列表过滤与中断回调（search.rs/explore_api.rs 无对应，仅 Rust 迭代器 .filter）
  - ③ **preUpdateJs**：目录更新前 JS（仅 toc_rule.rs:6-7 模型字段，无执行点）
  - ④ **正文 title 标题规则**：contentRule.title/imgRegex 提取（Kotlin BookContent.kt:176-185，Rust get_content 无 titleRule 处理）

## 3. UI 轨进度验证结论

| 项 | 结论 | 证据要点 |
|----|------|----------|
| §5.1-5.4 UI 92 项（P0×2/P1×44/P2×46/快赢×4） | ✅ 抽查全部属实 | 批次提交哈希 0cde41a5c/873abea29/b7368193a/9ac94b173/522e1c1be/6633c25e3/0c452f4b5/13a11220e 在 git logs 真实存在；抽查 12 项均有真实代码 |
| v2.0.3 波次 4-6 关键接线 | ✅ 全部属实 | 编辑保存（reader_top_bar.dart:326）/反转内容（:350-376）/payAction 三分支（:633-696）/TocScreen 三 Tab（toc_screen.dart:492-503）/书签导出/上传远程（book_info_screen.dart:644-721）/更新任务/定时调度器（auto_task_scheduler.dart:34-253）/朗读段落化（audio_notifier.dart:55-600）/分页阈值（reader_page_view.dart:546-567） |
| v2.0.4 三 FFI 接线 | ✅ 属实 | shrinkDatabase（other_settings_screen.dart:786-818）/webdavUploadFile（book_info_screen.dart:703-721）/toggleSameTitleRemoved（reader_top_bar.dart:738-747） |
| 剩余项声明（MoreConfig 7 项/§5.13 八项/§5.14 七项） | ✅ 与代码一致 | 各键仅定义/持久化/UI，无行为消费；§5.14 遗留均属实 |
| TODO 口径 | 「零 TODO」不成立 | lib 生产代码约 13 处 TODO（均诚实标注延迟项；TODO(留批次) 正式留项 1 处与 §5.9 一致）；FIXME/XXX/HACK 0 处 |
| flutter test | 实测 **1092 全过** | PROGRESS 声称 1087（2026-08-05）已过时 |

## 4. 上游对比结论（e1c102803 #396 → 36d58eea9 #672）

- 差距：**250 提交 / 580 文件 / +41,508 −3,364 行**；时间 2026-07-25 → 08-10；版本 3.26 系列 35 个 tag（最新 3.26081008）
- 分类：bug 修复 ~50% / 新功能 ~22% / 依赖构建 ~18% / 性能 ~6% / 文档 ~4%
- 关键新功能：PDF 导出（#472/#483）、高亮体系（#405/#408/#448-459/#487/#506）、标点悬挂（#425）+标点挤压（#471）、SOCKS5 认证（#469）、MCP 5 工具（#452-456）、定时任务分享口令（#458）/批量（#460/#464/#497）、漫画离线缓存（#550）、壁纸动态配色（#485）、cURL 转换（#434）、登录 V2（#402/#488）、段评（#519/#529/#545）、WebDAV 系列（#587/#604/#622）、应用日志导出（#543/#524）
- 重构后覆盖约 **70%**（同步窗口 2 已对齐至 #543；#544→#672 约 109 条主要为 Web 前端、修复与依赖升级）
- **未覆盖项**：应用自更新系列（用户决策不迁移）、视频悬浮窗（Android 特性）、**MCP 的 Flutter UI 接线**（Rust 20 工具已有，设置页仅占位开关）、**批量单章换源缓存 #659**（新语义未见对齐）、壁纸配色落地、段评窗口拖高、音频全局片头片尾默认值
- 已覆盖确认：PDF 导出（export.rs 对齐 #483）、高亮体系（highlight.rs+11 FFI）、定时任务分享口令、SOCKS5 认证（proxy.rs RFC1929）、标点挤压/悬挂（zh_layout）、登录 V2、段评回复、WebDAV 系列、应用日志导出、cURL 转换（server 端点）

## 5. Kotlin 缺陷存量（本地 vs 上游对比）

- 08-02 审计 P0×2/P1×30/P2×55 中精选 10 项（含 P0×2：模拟阅读 LocalDate.parse 崩溃、migration_26_27 pageIndex 列不存在）在本地 app/ 与上游 upstream/master **全部原样存在、上游无一修复**（P0-2 上游同样未修正，仅新增 96_97/98_99 迁移）
- 上游新增代码（07-25 后 10 个新/大改文件：PunctuationCompress/Socks5Proxy/PdfFile/ExportBookService/HighlightRuleMatcher/HighlightDraw/CurlAnalyzeUrlConverter/AudioSkipPolicy/ReadRecordIndex/McpToolServer）抽查**无明显 P0/P1 缺陷**（唯一低危：PunctuationCompress 负宽未 clamp）
- 结论：若后续同步上游，Kotlin 缺陷仍需本地自行修复（REMAINING_PLAN §3.1 P0 清单保持有效）

## 6. 文档滞后修正与台账销记核对（v2 更新）

> 首版审计后用户台账已更新至 REMAINING_PLAN v1.18（Task #71/#78）与 CHANGELOG 2.0.5/2.0.6，本节省略号（原滞后项状态）与新增进展合并如下。

1. **schema v102 声明过时（已确认）**：REMAINING_PLAN §5.10 与 PROGRESS 称「触发型延后」，实际 `migrations.rs:657-708` Migration101To102 已完整实现（含测试与回退 down），SCHEMA_VERSION 已到 **103**；用户 v1.17 已使用 Migration102To103 补 variable 列（契约 §2.3），实践与审计判断一致；§5.14 #16 另登记 coverRules 表 DDL 游离迁移体系须入 schema 对齐专项
2. **设置源变量（原"已实现未销记"，现已销记 ✅）**：首版审计发现 §5.11-3 未销记但代码已实现（Rust `source.rs:103`、DB v103 variable 列、Flutter `book_info_screen.dart:566-630`，Task #63-65 实机验证截图 `_verify_batch4/`）；用户 v1.17（Task #71）已正式销记——契约 §2.3 setSourceVariable + Migration102To103 补列 + `_VariableDialog` 对齐原版 source 分支，**§5.11 全部 7 项至此闭合**
3. **PROGRESS.md 测试数字过时（仍成立）**：flutter test 声称 1087（2026-08-05），实测 1092 全过；用户尚未更新 PROGRESS（头部仍为 2026-08-07）
4. backupList/bookGroupSetShow/httpTtsSetEnabled：FFI 均已实现（契约 §2.41 登记），真正未完成的是 Dart 侧 RustApi 封装（契约 §3 待封装清单）
5. **用户 v1.17/v1.18 新增销记核对（与审计一致）**：getBookmarks 补 bookAuthor → 契约 §2.7 getBookmarksByBook 双键查询（消费方全切换、MCP 可选参数）；BookRepository upsert 根治级联删除（原 §5.14 #3，审计曾登记 OR REPLACE 隐患，现销记）；customHosts → 契约 §2.20.3 setCustomHosts（DNS 覆盖+持久化+JSON 编辑对话框）；MCP 端口 → 契约 §2.22.5 setMcpPort（默认 1236、回环绑定、状态机互斥、同端口重启竞态修复）；封面规则 → 契约 §2.4.8 searchCoverRules（key 模板+isUrl 提取+失败隔离，CRUD 待后续）
6. **用户新增 §5.14 遗留 #9-#17（审计补充确认）**：书签作者改写边界验收知悉项（#9）、二级索引冲突 insert_replace 跨书级联残余与预检加固方向（#10）、getBookmarks 单键查询兼容保留建议（#11）、JS 链书源 bookUrl 为空待查（#12）、coverRule 规则 CRUD 待契约（#13）、MCP 局域网可达+token 鉴权待后续（#14）、customHosts 对直建 reqwest::Client 链路不生效覆盖缺口（#15）、coverRules 表 DDL 游离迁移体系（#16）、原版 McpService 前置 jsSourceApiToken 校验未实现（#17）

## 7. 后续工作项登记（下一批）

| 优先级 | 工作项 | 说明 |
|--------|--------|------|
| P1 | Rust 未闭合 4 项：RuleData 变量表 / filter/shouldBreak / preUpdateJs / 正文 title 规则 | 对齐 Kotlin BookList.kt/BookChapterList/BookContent.kt 语义；改动 FFI 前先冻结契约 |
| P1 | PROGRESS.md 测试数字更新（1087 → 实测 1092） | 设置源变量/schema v102 已由用户 v1.17 销记，剩余仅 PROGRESS 头部数字 |
| P2 | MCP Flutter UI 接线（Rust 20 工具已有实现） | 端口已接线（§2.22.5）；工具调用 UI 与 token 鉴权（§5.14 #14/#17）待后续 |
| P2 | 批量单章换源缓存 #659 对齐 | 评估后立项 |
| P2 | 视频悬浮窗、壁纸配色落地、段评窗口拖高、音频全局片头片尾 | 按原版对齐批次排期 |
| P2 | 用户新增 §5.14 #9-#17 遗留跟进 | coverRule CRUD、MCP 局域网+token、customHosts 直建链路缺口、coverRules DDL 游离、jsSourceApiToken 前置校验等（见 §6-6） |
| 延后 | Kotlin P0×2/P1 缺陷修复 | 依赖上游同步决策（REMAINING_PLAN §3.5）；上游未修，需本地修 |
| 观察 | normalizeJsResult 引擎差异、PunctuationCompress 负宽 | 维持观察 |

---

**编写者**: Reasonix
**日期**: 2026-08-10
