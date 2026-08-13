# Legado 源码级差异比对审计报告（Kotlin 原版 vs Rust+Flutter 重构版）

**审计日期**: 2026-08-13
**审计方式**: 仅源码逐函数比对（`app/src/main/java/io/legado/app/` vs `rust/` + `flutter_legado/lib/`），未依赖任何既有审计文档结论
**审计口径**: 只读比对，不修改任何代码；结论仅陈述源码事实

---

## 1. 比对覆盖范围

| 层 | 比对内容 | 状态 |
|---|---|---|
| UI Activity 层 | 49 个原版 Activity vs 63 个重构 Screen | ✅ 全部有对应 |
| UI Dialog 层 | 70+ 个原版 Dialog vs 重构 Widget/Dialog | ✅ 约 85% 覆盖 |
| 解析核心 AnalyzeRule | 40+ 方法逐函数 | ⚠️ 约 75% |
| AnalyzeByJSoup | 8 方法 | ✅ 约 90%+（含 `@html`；ownText 近似） |
| AnalyzeUrl | 60+ 方法/getter | ⚠️ 约 90% |
| JsExtensions（java 桥） | 120+ 方法 | ⚠️ 约 92% |
| 响应层 legado-net | LegadoResponse/RawResponse/cookie/rate_limit/webdav/cover | ⚠️ 约 85% |
| web_book 域 | search/info/chapters/content/分页/subContent/payAction/callBackJs | ⚠️ 约 80% |
| 数据实体层 | Kotlin 42 实体 vs Rust 44 模型 | ✅ Book 等核心实体字段完整对齐 |
| Service 层 | 10+ 原版 Service | ⚠️ 见 §3.6 |
| API 域（搜索/备份/WebDAV/高亮/阅读记录/词典/规则订阅/登录/RSS/Explore/缓存下载/导出） | 逐 API 存在性 | ✅ 全部有对应 |

---

## 2. 实质缺失清单（按影响排序，累计三轮结论）

### P0 级（影响书源兼容性）

1. **`@put:` 变量系统**（put/get/setLocal）
   - 原版：`$.chapter_name@put:{chapter_id:$.chapter_id}` 写入变量，后续规则 `@get:chapter_id` / `{{get.chapter_id}}` 读取
   - 重构：`strip_put_rules` 仅剥离 `@put:{...}` 后**丢弃**（analyze_rule.rs:165 注释"变量写入后续可扩展"），无存储/读取 API
   - 影响：神漫画类书源的跨规则变量传递（正文分页/目录链）完全失效

2. **`preciseSearch` 精确搜索**
   - 原版：`WebBook.preciseSearchAwait`（换源/精搜场景）
   - 重构：Rust 全无对应

3. **`checkRedirect` 重定向检测**（影响偏弱）
   - 原版：`WebBook.checkRedirect`（`WebBook.kt`）——实测主要为 **Debug.log 记录重定向**，并非强制重请求
   - 重构：无对等日志/钩子；**不宜按「兼容性阻断」排 P0**，保留为可观测性缺口

4. **`runPreUpdateJs` 更新前 JS 钩子**
   - 原版：`WebBook.runPreUpdateJs`（TocRule.preUpdateJs，目录更新前执行）
   - 重构：toc_rule.rs 仅有模型字段，**无执行逻辑**

### P1 级（功能缺口）

5. **`getWebJsResult`（WebView JS 执行模式）**
   - 原版：AnalyzeRule WebJs 模式经 WebView 执行 JS 取结果
   - 重构：仅 webView 开屏存在，规则级 WebJs 模式缺失

6. **`setRedirectUrl`**：AnalyzeRule 重定向 URL 回填缺失（绝对化多处手传 `redirect_url`，无规则 API）

7. **`getStringList(..., isUrl=true)` URL 回退模式** + **`getString(rule, unescape)` 重载**：AnalyzeRule 通用重载仍缺；封面/部分 web_book 路径有局部 isUrl/unescape 等价

8. ~~**AnalyzeByJSoup `@html` 提取模式**~~ → **✅ 已对齐（复核销记）**：`legado-parser/src/html.rs` 已实现 `@html`/`html`/`all` 提取（`elem.html()`）；正文单测广泛使用 `.content@html`

9. **`imageStyle` 正文图片样式**：模型+书源编辑+阅读器菜单可持久化；`book_open_utils` 用 ContentRule.imageStyle 做漫画路由；**阅读器排版执行点仍弱**（`full`/`text`/`single` 未驱动 page layout）

10. **`sourceRegex` 正文应用**：仅 webViewGetSource 桥有参数；`web_book.rs` getContent 链路未把 `contentRule.sourceRegex`/`webJs` 传入请求（原版 `WebBook.getContent` → `AnalyzeUrl.getStrResponseAwait(jsStr=webJs, sourceRegex=…)`）

11. **`upload(fileName, file, contentType)` 多部件上传**：AnalyzeUrl 无（直链上传规则依赖；产品侧直链入口已正式 N/A，见 GAP §10.2 / RESIDUAL「不做」）

### P2 级（通用文件下载 / 形态）

12. **`DownloadService` 通用文件下载**（DownloadManager 封装：书源 zip/APK 下载）：重构版无对应 Service，APK 更新仅解析 URL 后交由系统

13. **`getReadBookConfigMap`/`getThemeConfigMap`（Map 版）**：书源 JS 读 Map 型配置缺失（仅 String 版，见 `legado-js` config_api / quickjs_impl）

---

## 3. 差异明细（按层）

### 3.1 AnalyzeRule（约 75%）

- ✅ get_string/get_strings/get_elements/get_attr/regex_match_groups/regex_chain/set_content/set_base_url/with_js_binding/splitSourceRule 等价（strip_put_rules + JsChainStep）/`##` 替换（SplitReplaceSpec）/execute_js（globalThis 注入）
- ❌ put/get/setLocal 变量系统、setRedirectUrl、getWebJsResult、isUrl 模式、unescape 重载、reGetBook/refreshTocUrl、编译缓存层

### 3.2 AnalyzeByJSoup（约 85%→更高）

- ✅ getElements/getString/getStringList/getResultLast（text/属性）/@ 链/多级链；**✅ `@html`/`html`/`all` 提取**（`html.rs`）
- ⚠️ textNodes/ownText：已分支实现，但 ownText 仍近似 text（非精确子节点 only）

### 3.3 AnalyzeUrl（约 90%）

- ✅ new/parse/apply_pipes（管道编码）/extract_config/get_absolute_url/analyze_js/parse_with_js/parse_with_context/parse_data_uri/全部字段 getter（method/headers/body/charset/retry/timeout/proxy/followRedirects/webView/webJs/webViewDelayTime/js/bodyJs/dnsIp/serverId）
- ❌ upload 多部件、put/get 内嵌变量；setCookie/saveCookie 主动调用时机未确认（存储层有）

### 3.4 JsExtensions / java 桥（约 92%）

- ✅ ajax 全家桶/webView 全家桶/编解码 18/压缩 6/字体 3/加密 10/并发 3/配置 5/文件 API/验证码/toURL/toast/log/openUrl/showBrowser/getSource/getTag
- ❌ 参数重载：getReadBookConfigMap/getThemeConfigMap（Map 版）、webView cacheFirst、downloadFile 双参、getFile（File 对象）、unArchiveFile（统一入口）、openVideoPlayer isFloat、timeFormatUTC 时区

### 3.5 响应层（约 85%）

- ✅ LegadoResponse（status/headers/body/url/is_success/header 大小写不敏感/content_type）+ LegadoRawResponse（二进制）+ cookie_store（domain/key/get_cookie_string）+ rate_limit（按域）+ webdav + cover 缓存
- ⚠️ 错误响应构造语义不同（Result vs 原版构造 Response 对象）；saveCookie 自动持久化时机未确认

### 3.6 Service 层

| 原版 Service | 重构对应 | 状态 |
|---|---|---|
| CacheBookService | cache_download_api（任务 CRUD/进度/重试/预加载策略） | ✅ |
| CheckSourceService | source_check_api（流式进度/取消） | ✅ |
| ExportBookService | book_export + legado-book export.rs（**PDF 图片导出已实现**：export_pdf_images/decode_pdf_image/image_fit_scale/extract_image_sources） | ✅ |
| DownloadService（通用文件下载） | 无对应 | ❌ |
| AudioPlayService | MediaSessionBridge（MainActivity.kt）+ audio_screen | ⚠️ 状态机完整性未逐函数比（音频焦点/电话监听/蓝牙线控完整性待真机验证） |
| BaseReadAloudService | Dart read_aloud + platform_channel TTS | ⚠️ 电话监听（PhoneStateListener）未确认 |
| AudioCacheService | audio 缓存（SAF 目录） | ⚠️ 后台队列/前台通知形态未比 |
| AutoTaskScheduler | AutoTaskJobBridge.kt（JobScheduler 双轨） | ⚠️ 重试策略（shouldRetry）未确认 |

### 3.7 API 域（全部有对应）

搜索（search_books/search_multi/cancel_search）、备份（backup_api + import_old_data）、WebDAV（list/upload/upload_file/download/download_file/delete/mkdir/full_sync/incremental_sync）、高亮（add/delete/list/search + rule CRUD）、阅读记录（get_read_records）、词典（dict_lookup）、规则订阅（check_sub_update_db/apply_sub_update_db）、登录（eval_login_ui_v2/eval_login_action_v2）、RSS（fetch_rss_articles/clear_rss_articles）、Explore（explore_parse_url/explore_fetch_books）、缓存下载（download_api 全家族）、导出（export_book/export_book_with_options/export_info）、定时任务（auto_task_api）、替换规则（replace_rule_api）、TTS（http_tts_api）、TXT 目录规则（txt_toc_rules）、封面规则（cover_api CRUD + searchCoverRules）。

### 3.8 数据实体层（✅ 完整对齐）

- Kotlin 42 实体 vs Rust 44 模型：Book/BookChapter/BookSource/Bookmark/Highlight/RuleSub/TxtTocRule/Server/Cache/Cookie/DictRule/HttpTTS/KeyboardAssist/ReadRecord/RssArticle/RssStar/SearchBook/SearchKeyword/ReplaceRule/BookGroup/AutoTaskRule/BookSourcePart/BookProgress/ReplaceBook/BookCacheInfo/ReadRecordShow/RssReadRecord/BookChapterReview + rule 子模型 10 个（BookInfoRule/SearchRule/ContentRule/TocRule/ReviewRule/ExploreRule/ExploreKind/FlexChildStyle/RowUi/BookListRule）
- 抽样 Book 实体 30 持久字段逐字段对齐；Rust 额外序列化 infoHtml/tocHtml/downloadUrls 三瞬态字段 + coverOrigin
- Kotlin 独有 ReadRecordBook（Rust 以 ReadRecordDto 等价实现）

---

## 4. 缺陷与卫生问题（非缺失）

1. ~~**版本常量滞后**~~ → **✅ 已修（`46ebfa085`）**：`PackageInfo.fromPlatform()` 替代硬编码；`app_update_service.dart` 已无 `2.0.38` 常量
2. **过时注释**（仍在）：`reader_bottom_bar.dart:133` 仍写「Flutter 侧暂无自动翻页」，实际 `reader_screen` 已有 `_syncAutoTimer`
3. **Rust 多存瞬态字段**：infoHtml/tocHtml/downloadUrls 原版 @Ignore 不落库，Rust 模型带 serde 序列化（可能造成冗余序列化输出，非功能缺陷）

---

## 5. 建议修复顺序

1. P0-1 `@put:` 变量系统（影响神漫画类书源，最大兼容性缺口）
2. P0-4 `runPreUpdateJs` / P0-2 `preciseSearch`（Rust 权威实现；UI 书架导入仅有近似）
3. P1 `sourceRegex`+`webJs` 正文请求接线 / `imageStyle` 阅读器排版执行
4. P1 getWebJsResult / setRedirectUrl / isUrl·unescape 通用化
5. P2 getReadBookConfigMap/getThemeConfigMap、DownloadService；（upload 与直链 N/A 联动，勿单独重开产品入口）
6. ~~P0-3 checkRedirect~~ 降为日志级；~~P1 `@html`~~ 已销；~~§4.1 版本硬编码~~ 已销

---

## 6. 复核销记（2026-08-13 晚 · 对照 RESIDUAL / GAP / 近期 commit）

| 项 | 结论 | 证据 |
|---|---|---|
| D1 SCHEMA 105 | ✅ 已闭合（非本审计 P0 清单项） | `18003a7b9`；`RESIDUAL_RISKS` D1 |
| F4–F6 / T6 | ✅ 已闭合（封面 CRUD / MCP / shareLayout / bookUrl CSS@js） | `f7bcf4425`/`5cb4d4ca3`/`729eb970f`/`c3dd3a0b3` |
| PackageInfo 版本同源 | ✅ 已闭合 | `46ebfa085`；`app_update_service.dart` |
| `@html` | ✅ 本审计误判，已实现 | `legado-parser/src/html.rs` |
| Cronet / 直链上传产品入口 | N/A | GAP §10.2；RESIDUAL「不做」 |
| GAP UI 缺口清单 | 大体已销；开放多为 A 类环境验收 | `GAP_AUDIT` §10 / `RESIDUAL` A* |
| 本审计仍开放 | §2 P0-1/2/4；P1-5/6/7/9/10；P2-12/13；P1-11 与 N/A 边界 | 见上文 |

编写者：Reasonix ｜ 2026-08-13（源码级只读审计）  
修订：Auto（Cursor）｜ 2026-08-13（交叉验证：销记 PackageInfo/@html；降级 checkRedirect；标注 imageStyle/sourceRegex 真实现状）
