# Legado 双轨重构缺陷审计报告

模型署名：Qwen3.8-27B-GGUF（Qwen3.8-27B-Ridge-3.7bpw.gguf，本地推理）
编写者：DSH Agent ｜ 日期：2026-08-17
审计方式：仅源码静态比对（不读文档、不修改代码）；原版基准 com.legado.app.release 3.26081008

## 一、审计概述

| 项 | 说明 |
|---|---|
| 原版范围 | app/ + modules/（约 1000+ Kotlin 文件） |
| 新轨范围 | rust/ 8 crate + flutter_legado/lib（307 dart） |
| 比对方法 | 实体/模型逐字段对照、函数表面比对、关键行为逻辑抽样验证；子代理并行补充验证（MCP 覆盖度、设置覆盖度） |
| 工作量 | 主代理 85 次 run_code / ~149 次工具执行 / ~500 万 token 当量，活跃 ~28 min；子代理 2 个后台并行 |

## 二、分域覆盖矩阵

| # | 领域 | 原版位置 | 新轨对应 | 结论 |
|---|------|---------|---------|------|
| 1 | 数据层 | data/entities/ 34 实体 + Room DAO | legado-db 27 表 + 27 Repository | ⚠️ 模型对齐，备份/导入重大缺失（H1/H2） |
| 2 | 网络层 | help/http/ 18 文件（OkHttp） | legado-net LegadoClient（reqwest） | ⚠️ 大部分对齐，UA 默认值偏差 + 设置未接线（M1） |
| 3 | 规则引擎 | model/analyzeRule/ 12 文件 | legado-parser 11 文件 + legado-js QuickJS | ✅ 方言/配置面/分页逻辑均对齐 |
| 4 | 搜索与书源管理 | WebBook.kt、source help | FFI search.rs(128KB)、source_* | ✅ 并发/去重/精确搜索对齐 |
| 5 | 阅读核心 | model/webBook/（WebBook/BookContent） | FFI web_book.rs(161KB) + content_help.rs | ✅ 分页防环/长章拆分对齐 |
| 6 | 本地书籍与媒体 | model/localBook/（epub/mobi/pdf/txt/umd） | legado-book 同名模块 + export/archive | ✅ 格式全覆盖，mobi HuffCDIC 逐行移植 |
| 7 | 设置与其他 | PreferKey 226 常量 + AppConfig 族 | caches 表 KV + Flutter providers | ⚠️ 覆盖 60.2%，90 键未覆盖（M3） |
| 8 | Web/MCP/Socket | web/（HttpServer+MCP+3 WS） | legado-server（axum，mcp.rs 2034 行） | ⚠️ MCP 仅覆盖 7/13，JS 书源流程断裂（M2） |

## 三、缺陷清单

### 🔴 H1. 备份/恢复功能覆盖严重不足
- 原版 help/storage/Backup.kt L56-80：**25 个备份数据集** + zip 打包 + WebDAV 上传同步 + AES 加密敏感项 + 每日自动备份（autoBack() L103）。
- 新轨 rust/legado-ffi/src/api/backup_api.rs：BackupData 仅 **6 张表**（books/bookmarks/replaceRules/bookSources/rssSources/readRecords）；Flutter backup_service.dart 更弱（仅 books+sources）。
- 后果：高亮、分组、RSS 收藏、搜索历史、规则订阅、TTS 配置、字典、自动任务、WebDAV 服务器、全部应用设置在新轨备份中丢失；与原版 zip 备份不互通；无自动备份。

### 🔴 H2. RoomImporter 仅导入 2 张表
- rust/legado-db/src/import.rs（469 行）：仅 import_book_sources / import_books。
- 原版 help/storage/Restore.kt 恢复全部数据集（含全表 deleteAll 语义）。新轨无法完整恢复原版备份 JSON。

### 🟠 M1. 默认 UA 偏差 + userAgent 设置未接线
- 原版 AppConfig.kt L719-724：默认 Chrome 浏览器 UA，用户可改（PreferKey.userAgent），全局注入。
- 新轨 legado-net/src/client.rs L66：客户端级默认 **"Legado/1.0"**；仅 ffi/api/search.rs L1105、image_api.rs L216 注入 Chrome UA；webbook/explore/content 等端点在书源未指定 UA 时发送 Legado/1.0。
- 子代理 B 核验：Flutter other_settings_screen.dart:128/645 可读写 config:userAgent，但 **Rust 网络层零消费**；且 UA 轮换中间件（client.rs:169/181，硬编码列表）可能覆盖书源 UA，与原版"书源 UA 优先"相悖。
- 影响：部分反爬站点在新轨失效（原版正常）；设置项形同虚设并产生误导。

### 🟠 M2. Web/MCP 服务缺口（JS 书源管理流程断裂）
子代理 A 逐工具核验（原版 web/mcp/McpToolServer.kt L217-795 ↔ rust/legado-server/src/handlers/mcp.rs list_tools L47-289）：

**原版 13 个 MCP 工具 → 新轨覆盖 7 个（≈54%）**
- 存在 7：debug_source（简化）、list_sources（search→enabled_only 语义变）、get_source、clear_cookies、eval_js（无 java.log + quickjs feature 门控）、check_source（改名 check_sources，不写回校验结果）、get_cookies（仅持久层）
- **缺失 6**：save_source、delete_sources（REST 仅单删补偿）、set_cookie、get_http_logs、get_http_log、set_http_log_recording

**JS 书源保存流程在新轨无等价路径**：
- 原版 POST /saveJsSource（HttpServer.kt:58-60/81）：x-legado-token + text/plain + ≤1MiB 校验（BookSourceController.kt:94-117），Rhino 执行提取元数据；9 个受保护写路由（HttpServer.kt:220-230）。
- 新轨：MCP 无 save_source；REST POST /api/sources（source.rs:37-56）仅 6 固定字段、不支持 main_js；底层能力 JsSourceUpsert/js_source_extract（legado-ffi js_source_config_api.rs:15-38）**仅 FFI 暴露，legado-server 零调用**；/api/* 写路由无 token 中间件。

### 🟠 M3. 设置项覆盖度 60.2%，90 键未覆盖
子代理 B 逐键核验（PreferKey.kt 226 常量 ↔ rust/*.rs + flutter_legado/lib/*.dart 全量精确匹配 + 变体补查）：

| 功能域 | 覆盖/总数 |
|---|---|
| 主题/外观/壁纸 | 28/36 |
| 欢迎页 | 8/8 |
| 书架显示/管理 | 3/14 |
| 阅读交互/排版（含九宫格点击区） | 21/38 |
| 漫画阅读 | 6/14 |
| 朗读/TTS/按键 | 11/24 |
| 书源/搜索/换源/导入管理 | 14/23 |
| 网络/服务/安全 | 13/14 |
| WebDAV/同步 | 3/8 |
| 备份/恢复/存储 | 6/8 |
| 导出/导入本地 | 2/10 |
| 杂项/调试/更新 | 13/21 |
| 封面加载类 | 8/8 |

- **已覆盖 136（60.2%）/ 未覆盖 90（39.8%）**；其中约 12 键仅"注册/名单级"（无实际读写调用，属死键）。
- 高影响 1：userAgent（已列 M1）。
- 中影响 ~55 键，五大缺口组：**阅读排版**（textBottomJustify/adaptSpecialStyle/nightBrightness/expandTextMenu/textSelectMenuConfig/contentSelectSpeakMod 等）、**九宫格点击区**（clickActionTL..BR 9 键全缺）、**TTS/朗读**（ttsEngine/ttsSpeechRate/sleepTimer* 等 10 键）、**漫画**（mangaPreDownloadNum/autoPageSpeed/hideMangaTitle 等 8 键）、**导出/备份**（exportType/exportCharset[假覆盖]/bookImportFileName 等 9 键）+ 书架显示 12 键 + 书源导入管理 9 键。
- 低影响 ~10 键：mcpService/fontFolder/enableReview/optimizeRender/editFontScale 等。
- **键存储形态变化（迁移兼容风险）**：WebDAV 改 SyncState 对象字段、mcpService 并入 mcpPort、日志键改 crash_record_* —— 与 Android 备份数据不兼容，成为 H1/H2 之外的额外迁移障碍。

### 🟡 L1. WebDAV 服务器配置存储方式改变
原版 Server.kt + Room servers 表（备份 AES 加密）；新轨无 servers 表，webdav_api.rs 每次调用由 Flutter 传 config_json（stateless）。功能近似但脱离统一数据层与备份。

### 🟡 L2. unrar 不可用于 Android 目标
rust/legado-book/Cargo.toml：unrar 仅限 cfg(not(target_os="android"))。若新轨上 Android，RAR 书籍缺失（当前 Windows 主目标不受影响）。

## 四、偏离项（新轨独有，红线核查）

1. legado-net retry/rate_limit/UA 轮换/proxy 池中间件——原版无对应物（网络层增强；UA 轮换引入 M1 副作用）。
2. books DDL 额外持久化原版 @Ignore 的 infoHtml/tocHtml/downloadUrls + coverOrigin 列（数据层改进）。
3. **MCP 新增 10 个工具**（mcp.rs:50-195）：search_books、get_chapters、read_chapter、get_bookshelf、add_to_bookshelf、update_source、get_reading_progress、get_bookmarks、add_bookmark、get_replace_rules——原版 MCP 无对应物，**按 AGENTS.md 红线需确认是否属新架构服务形态的合理组成部分**。
4. legado-server 整体为原架构不存在的服务形态（axum + /api 全量 REST）；AGENTS.md 模块地图已列为正式成员，判为架构差异而非红线违规。
5. rust/legacy-ffi 空目录残留、根目录 tmp_* 调试产物（仓库卫生）。

## 五、确认对齐项

- **数据模型**：Book/ReadConfig 全字段 serde rename 精确匹配；27 表覆盖 34 实体。
- **网络**：超时 15s/60s、重定向、Keep-Alive/Cache-Control、跳过证书校验（client.rs:68）、Cookie DB 持久化、SOCKS5/HTTP 代理+认证、customHosts 真接线（ffi.rs:106 → custom_hosts.rs）。
- **规则引擎**：@css/@json/@xpath/##regex## 四方言；AnalyzeUrl 配置面与原版 setter 族一一对应；nextContentUrl 分页防环（web_book.rs L1813-1851）；splitLongChapter；curl_converter 对齐 CurlAnalyzeUrlConverter.kt。
- **JS 引擎**：QuickJS host_api 130+ 函数，覆盖原版 JsExtensions 全部关键 API。
- **搜索**：FuturesUnordered + 并发上限 + bookUrl 去重（search.rs L335）；preciseSearch 全链路；preUpdateJs。
- **本地书籍**：epub/mobi(HuffCDIC)/pdf/txt/umd/archive/export 全覆盖。
- **换源行为**：changeSource* 4 键真接线；主题/欢迎页近乎全量对齐（子代理 B）。

## 六、修复建议（按优先级）

- **P0**：① userAgent 接入 legado-net（或删除设置项避免误导，M1）；② 备份/恢复补全数据集并实现 zip/WebDAV/AES（H1/H2）；③ MCP save_source + JS 书源保存流程接通 server（M2）。
- **P1**：阅读排版键（textBottomJustify/adaptSpecialStyle/nightBrightness/expandTextMenu）+ TTS 全局键接线；check_sources 写回校验结果；debug_source 自动管线。
- **P2**：漫画/导出/书架显示组逐项对齐或显式裁剪；清理 12 个死键；MCP 新增 10 工具做红线确认；unrar Android 目标决策。

## 七、审计过程备注

- 主代理串行完成 8 域比对（~28 min 活跃）；子代理机制修复后 2 个并行验证成功（MCP、设置覆盖度）。
- 全部结论附 file:line 证据；UI 视觉差异不计为缺陷。
