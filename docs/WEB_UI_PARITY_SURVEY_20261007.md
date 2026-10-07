# Web 服务页面与原版一致 —— 差距盘点调研报告

- 日期：2026-10-07
- 调研方式：Windows 本机静态分析（只读），未操作设备、未修改任何文件
- 用户裁决：**Web 服务的书架页面必须与原版一致**（指原版 Web 服务提供的浏览器页面）
- 原版基线：`app/src/main/assets/web/`（前端）+ `app/src/main/java/io/legado/app/web/` 与 `app/src/main/java/io/legado/app/api/controller/`（后端）
- 我方现状：`rust/legado-server/`（axum）
- 抽样策略说明：Vue 产物为压缩混淆 JS（单文件最大 489.7KB），未逐行阅读；对全部 11 个 JS chunk 用 `grep -oE` 做关键词全量提取（`.get(` / `.post(` / `baseURL` / `new WebSocket` / 端点名字面量），并对关键命中回读上下文。原版路由另以 `HttpServer.kt` 的 `when(uri)` 分发为准做交叉验证。

---

## 一、结论摘要

1. 原版浏览器前端是**完整 Vue 3 应用（rolldown 打包，无 sourcemap）+ 静态导航页 + 传书页 + 帮助文档**，共 67 个文件约 2.2MB，位于 `app/src/main/assets/web/`；入口为根 `index.html`（Forty 导航页）→ `vue/index.html`（hash 路由 `#/` 书架、`#/bookSource` 书源、`#/rssSource` 订阅源、`#/chapter` 阅读器）。
2. 原版 HTTP API 共 **30 个端点**（GET 15 + POST 14 + 特殊 1，含 `/cover` `/image` 图片代理与 `/legacyReviewPage` 动态页），另有 **3 个 WebSocket 路由**（`/searchBook`、`/bookSourceDebug`、`/rssSourceDebug`，跑在 **port+1** 的独立 NanoWSD 端口上）。响应统一为 `ReturnData{isSuccess, errorMsg, data}` 信封。
3. 我方 `rust/legado-server` 仅 `/api/*` 自研 REST + MCP + 9.5KB 单页，**30 个原版端点里 0 个以原版路径/信封提供**（语义相近者 10 个，但响应结构不兼容，Vue 前端按 `isSuccess/errorMsg/data` 解析会直接报"后端返回内容格式错误"）。
4. 资产差距：我方 `web-dist/` 仅 1 个自制 9.5KB 页面；原版 2.2MB。**推荐方案①：整体拷入 `rust/legado-server/web-dist/` 用 `include_dir` 编译期嵌入**（原版本身也是 Android assets 整目录只读分发，语义一致；iOS 无 CWD 保证，磁盘 fallback 不可依赖；2.2MB 对二进制体积影响可接受）。
5. FFI 契约（docs/API_CONTRACT.md）**无需变更**：本专项纯 HTTP 层，server 直接查 `db_state` 全局池，不新增 FFI 函数。
6. 无法静态确证项 4 处（见 §六），主要是大列表响应的精确 JSON 形态（如 Book 实体全字段序列化形态）与 Review 系列参数细节，需对原版 APK 实机抓包验证。

---

## 二、原版 Web 前端盘点（任务 1）

### 2.1 目录树与体积分布

总计 **2.2MB / 67 文件**（`du -sb` 实测）：

| 目录 | 体积 | 内容 |
|---|---|---|
| `web/` 根 | 2.3KB + 4.3KB | `index.html`（Forty 导航页，HTML5 UP 模板）、`favicon.ico` |
| `web/vue/` | **1,533,193 B (1.46MB) / 24 文件** | Vue 3 SPA（书架/阅读器/书源/订阅源四路由） |
| `web/assets/` | 190KB | 导航页 css/main.css（74KB）+ js/dist.js（103KB）+ md5.js |
| `web/help/` | 228KB | 帮助文档站：require.js + marked + highlight + 16 篇 md |
| `web/images/` | 50.7KB | bg.jpg |
| `web/uploadBook/` | 57.4KB | WiFi 传书页（html5 上传 + 图片资源） |

Vue 产物明细（`web/vue/`）：

- 打包形态：**rolldown（Vite 系）产物**——`rolldown-runtime-DK3Fl9T5.js`、文件名带内容 hash（`index-toG2697L.js`）、产物内含 `vite:preloadError` 事件与 `__vite__mapDeps` 预加载映射（`vue/assets/index-toG2697L.js`）。
- **无 sourcemap**：`find web -name "*.map"` 零命中。
- 入口 `vue/index.html:7-11`：引 `assets/index-toG2697L.js`（module + crossorigin）+ 2 个 modulepreload + 2 个 css。
- 路由（`index-toG2697L.js` 内 `path:` 字面量）：`/`（BookShelf）、`/chapter`（BookChapter）、`/bookSource`、`/rssSource`；书源/订阅源共用同一套 SourceList/SourceEditor 组件，按 `location.href` 是否含 `bookSource` 切换。
- 两套构建并存：`index-toG2697L.js` + `BookShelf-CY0LgYpv.js` + `BookChapter-DRyeLtSm.js`（入口实际引用）与 `index-Cuw80yqS.js` + `BookShelf-CBjCMxV2.js` + `BookChapter-CGy3A3Zd.js`（旧构建，无任何 HTML/JS 引用，疑为历史残留）。两者 API 层一致；本报告以**入口实际引用的 toG2697L 套**为准。
- vendor 含 axios（`baseURL: localStorage.getItem('remoteUrl') || location.origin`，超时 120s）+ Element Plus 风格组件 + vue-router + pinia。

### 2.2 原版后端路由分发（HttpServer.kt）

`app/src/main/java/io/legado/app/web/HttpServer.kt:44-156` 的 `when(session.method)` + `when(uri)`：

- **单端口 HTTP（NanoHTTPD）+ 独立 WS 端口**：`app/src/main/java/io/legado/app/service/WebService.kt:215-218` —— `HttpServer(port)` 与 `WebSocketServer(port + 1)`。前端 `Gt()` 函数（`index-toG2697L.js`）按「HTTP 端口 +1、http→ws / https→wss（443→444、81→82 的特例映射）」推导 WS 地址。
- **静态兜底**：`HttpServer.kt:161-167` —— returnData 为空时 `uri.endsWith("/")` 补 `index.html` 后交给 `AssetsWeb`。
- **CORS**：OPTIONS 预检放行 `GET, POST` + `x-legado-token`（:45-56）；API 响应回写 `Access-Control-Allow-Origin: <origin>`（:203-204、addWebHeaders）。
- **CSP**：`/vue/*.html` 注入 `VUE_CONTENT_SECURITY_POLICY`（:233-238、:274-277）；`/legacyReviewPage` 另有独立 CSP + sandbox（:239-245、:280-310）。
- **缓存头**：仅令牌相关路由 `Cache-Control: no-store`、`/vue/*.html` 为 `no-cache`（:265-278），其余静态资源无缓存头。
- **大响应**：List 超过 3000 条时走 chunked 流式 JSON（:183-194）——书架/书源大库场景的实际行为。

### 2.3 完整端点清单（Kotlin 路由为骨架、JS 字符串为佐证）

响应统一信封（`app/src/main/java/io/legado/app/api/ReturnData.kt:6-29`）：

```json
{ "isSuccess": true|false, "errorMsg": ""|"...错误文案...", "data": <任意> }
```

**GET（HttpServer.kt:133-153）：**

| # | 路径 | Controller 方法 | 用途 | 前端调用证据 |
|---|---|---|---|---|
| 1 | `/getBookshelf` | `BookController.bookshelf`（BookController.kt:65-83） | 书架全部书籍，按 `AppConfig.bookshelfSort` 排序；空书架返回 errorMsg「还没有添加小说」 | `W.get(\`getBookshelf\`)`（toG2697L）；前端按 `durChapterTime` 二次排序 |
| 2 | `/getChapterList?url=` | `BookController.getChapterList`（:182-193） | 章节列表；**DB 无章节时自动转 refreshToc 抓取**（:189-191） | `W.get(\`getChapterList?url=\`+encodeURIComponent(e))` |
| 3 | `/getBookContent?url=&index=` | `BookController.getBookContent`（:198-246） | 正文：本地缓存优先（BookHelp.getContent）→ 缺失经书源抓取（WebBook.getContentAwait）→ **ContentProcessor 替换净化**，`includeTitle=false` | `W.get(\`getBookContent?url=..&index=..\`)` |
| 4 | `/refreshToc?url=` | `BookController.refreshToc`（:145-177） | 重抓目录（本地书走 LocalBook；网络书走 WebBook.getChapterListAwait），**删旧插新 + book.update()** | （active bundle 无独立调用点，目录刷新走 getChapterList 的隐式链；待实测） |
| 5 | `/cover?path=` | `BookController.getCover`（:88-113） | **返回 PNG Bitmap**（HttpServer.kt:169-180 特判 image/png），84x112 裁切，失败回退默认封面 | `new URL(\`cover?path=\`+.., G)`（getProxyCoverUrl） |
| 6 | `/image?path=&url=&width=` | `BookController.getImg`（:118-140） | 正文图片代理（经书源规则下载），width 默认 640 | `new URL(\`image?path=..&url=..&width=..\`, G)`（getProxyImageUrl） |
| 7 | `/getReadConfig` | `BookController.getWebReadConfig`（:346-351） | Web 阅读配置（CacheManager `webReadConfig` 键），无配置时 errorMsg「没有配置」 | `V.get(\`getReadConfig\`, {baseURL:.., timeout:3000})` |
| 8 | `/getBookSources` | `BookSourceController.sources`（BookSourceController.kt:28-35） | 全部书源；空返回「设备源列表为空」 | `W.get(\`getBookSources\`)` |
| 9 | `/getBookSource?url=` | `BookSourceController.getSource`（:196-205） | 单个书源 | 前端 active bundle 无直接调用（编辑页由列表态驱动） |
| 10 | `/getJsSourceApiTokenRequired` | `BookSourceController.isJsSourceApiTokenRequired`（:189-190） | 令牌开关探测（前端决定是否弹令牌输入框），前端显式 `cache:'no-store'` | `fetch(new URL(\`getJsSourceApiTokenRequired\`,..))` |
| 11 | `/getHttpLogs?limit=` | `HttpLogController.getLogs`（HttpLogController.kt:13-31） | HTTP 调试日志列表 `{recording, logs[]}`（受令牌保护） | active bundle 无调用点（工具性端点） |
| 12 | `/getHttpLog?id=` | `HttpLogController.getLog`（:33-39） | 单条日志详情（受令牌保护） | 同上 |
| 13 | `/getRssSources` | `RssSourceController.sources`（RssSourceController.kt:15-25） | 全部订阅源 | `W.get(\`getRssSources\`)` |
| 14 | `/getRssSource?url=` | `RssSourceController.getSource`（:57-66） | 单个订阅源 | 同 #9 |
| 15 | `/getReplaceRules` | `ReplaceRuleController.allRules`（ReplaceRuleController.kt:14-22） | 全部替换规则（含样例合并，**data 为 JSON 字符串而非数组**） | active bundle 无调用点 |
| 16 | `/getReviewSummary?url=&index=` | `ReviewController.getSummary`（ReviewController.kt:181） | 段评摘要 | `V.get(\`getReviewSummary\`, {params:..})` |
| 17 | `/getReviewDetail?...` | `ReviewController.getDetail`（:222） | 段评详情（游标分页） | `V.get(\`getReviewDetail\`, {params: {url,index,paraIndex,paraData,page,cursor}})` |
| 18 | `/getReviewReplies?...` | `ReviewController.getReplies`（:331） | 段评回复 | `V.get(\`getReviewReplies\`, {params:..})` |
| 19 | `/legacyReviewPage` | `ReviewController.getLegacyReviewPage`（:458） | 旧评论会话动态 HTML 页（非 ReturnData，直接回 HTML，no-store） | `getLegacyReviewPageUrl`（toG2697L） |

**POST（HttpServer.kt:80-108）：**

| # | 路径 | Controller 方法 | 用途 | 前端调用证据 |
|---|---|---|---|---|
| 20 | `/saveBookSource` | `BookSourceController.saveSource`（:37-52） | 保存单个书源（名称/URL 非空校验） | `W.post(\`saveBookSource\`, ..)` |
| 21 | `/saveBookSources` | `BookSourceController.saveSources`（:54-70） | 批量保存书源（过滤空名/空URL，**data 返回成功入库的源数组**） | `W.post(\`saveBookSources\`, ..)` |
| 22 | `/saveJsSource` | `BookSourceController.saveJsSource`（:72-96） | JS 源脚本入库（text/plain、≤1MiB、须令牌，另有 openedSourceUrl 参数） | `W.post(\`saveJsSource\`, ..)` |
| 23 | `/deleteBookSources` | `BookSourceController.deleteSources`（:207-216） | 批量删书源（data「已执行」） | `W.post(\`deleteBookSources\`, ..)` |
| 24 | `/saveBook` | `BookController.saveBook`（:251-259） | 保存整本书（含 WebDav 进度上传），data 为 "" | `W.post(\`saveBook\`, ..)` |
| 25 | `/deleteBook` | `BookController.deleteBook`（:264-271） | 删书（book.delete() 级联），data 为 "" | `W.post(\`deleteBook\`, ..)` |
| 26 | `/saveBookProgress` | `BookController.saveBookProgress`（:276-301） | **保存阅读进度（按 name+author 定位书）**，data 为 ""；前端 `navigator.sendBeacon` 也会打此端点 | `W.post(\`saveBookProgress\`, ..)` + `sendBeacon(new URL(\`saveBookProgress\`,G))` |
| 27 | `/addLocalBook` | `BookController.addLocalBook`（:306-330） | WiFi 传书：multipart 表单 `fileName` + `fileData`（uploadBook/js/html5_fun.js:137-139），文件名安全校验（:39-49） | `url: "../addLocalBook"`（uploadBook/js/common.js:8） |
| 28 | `/saveReadConfig` | `BookController.saveWebReadConfig`（:335-341） | 保存 Web 阅读配置（原样字符串入 CacheManager） | `W.post(\`saveReadConfig\`, e)` |
| 29 | `/saveRssSource` / `/saveRssSources` / `/deleteRssSources` | `RssSourceController.saveSource/saveSources/deleteSources`（:24-72） | 订阅源增删（语义同书源三件套） | `W.post(\`saveRssSource(s)\`/\`deleteRssSources\`, ..)` |
| 30 | `/saveReplaceRule` / `/deleteReplaceRule` / `/testReplaceRule` | `ReplaceRuleController.saveRule/delete/testRule`（:23-100） | 替换规则增删测 | 端点名仅出现在前端令牌守卫 Set 字面量（toG2697L）；**active bundle 未发现实际调用点**（替换规则编辑 UI 未在本构建路由内） |
| — | `/openLegacyReview` / `/runLegacyReview` | `ReviewController.openLegacyReview/runLegacyReview`（:400/:438） | 旧评论会话开/跑（须令牌） | `W.post(\`openLegacyReview\`/\`runLegacyReview\`)` |

**WebSocket（`web/WebSocketServer.kt:33-55`，端口 = HTTP port + 1）：**

| # | 路径 | 处理类 | 用途 | 前端调用证据 |
|---|---|---|---|---|
| W1 | `/searchBook` | `BookSearchWebSocket`（socket/BookSearchWebSocket.kt:22-138） | 多源搜索：客户端首条消息 `{"key": "<关键词>"}`（10s 内不发即 PolicyViolation 关闭），服务端逐源推送 SearchBook JSON 数组，搜完 normal close | `new WebSocket(new URL(\`searchBook\`,tt), [\`legado\`, Xe(token)])`；onopen 后 `s.send(JSON.stringify({key:e}))` |
| W2 | `/bookSourceDebug` | `BookSourceDebugWebSocket` | 书源调试实时日志 | `new URL(\`${bookSource}Debug\`,tt)` + 子协议令牌 |
| W3 | `/rssSourceDebug` | `RssSourceDebugWebSocket` | 订阅源调试实时日志 | 同上（rssSource） |

### 2.4 静态资源服务（AssetsWeb）

`app/src/main/java/io/legado/app/web/utils/AssetsWeb.kt:11-45`：

- 构造时固定根 `AssetsWeb("web")`（HttpServer.kt:27），请求路径拼 `rootPath + uri`，`/+/` 归一为文件分隔符后**直接从 Android assets 打开**（:24-25），无目录列表、无路径白名单（assets.open 自带越界失败）。
- MIME 表仅 5 条：`.html/.htm → text/html`、`.js → text/javascript`、`.css → text/css`、`.ico → image/x-icon`、`.jpg → image/jpg`，**其余一律 text/html**（:33-44）——即 png/woff/ttf/md 都以 text/html 回给浏览器（浏览器按内容嗅探容忍；`X-Content-Type-Options: nosniff` 由 addWebHeaders 统一加在 HttpServer 层，AssetsWeb 自身不加）。
- 全部静态走 **chunked 响应**（:26-30），无 Content-Length、无 Cache-Control/ETag。
- 特殊路径：`help/`（帮助文档站，Vue 内以 `/help/#appHelp` 等锚点直链，`index-toG2697L.js` 中 10 处）；`uploadBook/`（传书页）；根 `/` → `/index.html`（HttpServer.kt:162-163）。

### 2.5 鉴权/令牌（如实记录）

原版**不是无鉴权**，但默认形态对普通阅读功能是"无感"的：

- 令牌体系仅保护 **JS/书源写入与 HTTP 日志**两组路由（`PROTECTED_SOURCE_WRITE_ROUTES` 11 条 + `PROTECTED_HTTP_LOG_READ_ROUTES` 2 条，HttpServer.kt:246-262）；**书架、目录、正文、进度、传书、封面等阅读主链路端点完全无鉴权**。
- 校验逻辑（BookSourceController.kt:138-145）：`jsSourceApiTokenRequired`（AppConfig.kt:524-525，**默认 true**）为 false 时全放行；为 true 时比对请求头 `x-legado-token` 与配置令牌（常量时间比较，:181-187）。**未配置令牌 + required=true → 一律拒绝**（errorMsg「Web 书源访问令牌未配置或不正确」）。
- WebSocket 令牌走子协议：客户端子协议数组 `["legado", "legado.token.<base64url(token)>"]`（前端 `Xe()`；服务端 BookSourceController.kt:154-179 拼装比对）。
- 前端行为：请求拦截器发现路径在受保护集合时先读内存令牌，没有则弹密码框（`请输入阅读 Web 服务中配置的访问令牌`），并主动 `localStorage.removeItem('apiToken')`；响应拦截器见 errorMsg 含「访问令牌」即清缓存重问。
- 用户已裁决「保持原版一致」→ 我方按同集合/同默认值/同错误文案复刻即可，无需另行加严或放宽。

### 2.6 WebSocket 的实际用途

前端仅用 WS 做**三件事**：多源搜索（/searchBook，BookSearchWebSocket.kt:93-96 经 SearchModel 全源并发搜索）、书源调试、订阅源调试。书架/阅读主链路纯 HTTP。搜索结果以 SearchBook 实体 JSON 数组逐条推送，结束 normal-close（code 1000，reason "Search finish"）；code 1008 被前端识别为令牌失败。

---

## 三、与我方现状对照（任务 2）

### 3.1 我方现有路由全景（`rust/legado-server/src/routes.rs:41-245`）

- `GET /`：编译期嵌入自制 9.5KB 单页（`include_str!("../web-dist/index.html")`，routes.rs:27）。
- `/api/*` 共 50+ 条自研 REST：health、books CRUD、books/{id}/chapters、chapters/{index}/content、books/export、sources CRUD、sources/check(-batch)、sources/repos/updates/update、search(+cancel)、webbook/* 4 条、tts/* 3 条、audio/* 4 条、rss/articles 2 条、cache/* 3 条、download/* 5 条、reviews 2 条、debug/* 5 条、read-aloud/* 7 条、rule-update/* 3 条、bookshelf/update-toc 4 条、auto-tasks/* 6 条、ws 3 条（search、debug/book-source、debug/rss-source）。
- `/mcp/tools`（GET）、`/mcp/call`（POST）。
- 兜底：`ServeDir::new("web-dist")`（routes.rs:58）——仅本机开发时磁盘可用，设备上目录不存在即 404。

### 3.2 逐条语义对照（原版 → 我方）

| 原版端点 | 我方最接近物 | 等价判定 |
|---|---|---|
| `/getBookshelf` | `GET /api/books`（handlers/bookshelf.rs:30-35） | **结构不兼容**：我方返回 `{books, total}`，无 ReturnData 信封；空书架返回空数组而非 errorMsg；无 bookshelfSort 语义 |
| `/getChapterList?url=` | `GET /api/books/{id}/chapters`（handlers/reader.rs:18-29） | **结构不兼容**：`{chapters, total}` 无信封；参数走路径而非 `?url=`；**无"无章节自动抓取"回退** |
| `/getBookContent?url=&index=` | `GET /api/books/{id}/chapters/{index}/content`（reader.rs:39-77） | **结构不兼容**；有真实抓取链（web_book::build_engine），但**缺 ContentProcessor 替换净化**与 includeTitle 语义；本地书直接报错无本地文件解析 |
| `/refreshToc?url=` | `POST /api/bookshelf/update-toc/single`（handlers/toc_update.rs） | 语义相近但**方法/参数/结构全不同**（POST vs GET） |
| `/saveBook` | `POST /api/books`（bookshelf.rs:51-71） | 请求体为我方自定 CreateBookRequest，非原版 Book JSON |
| `/deleteBook` | `DELETE /api/books/{id}`（bookshelf.rs:100-108） | 路径参数 vs 原版 POST body；返回 `{deleted:true}` 非信封 |
| `/saveBookProgress` | 无直接物（reader 状态在 Flutter 侧管理） | **缺口** |
| `/addLocalBook` | 无 | **缺口**（本地书导入链路在 Flutter/FFI 层） |
| `/getReadConfig` / `/saveReadConfig` | 无 | **缺口** |
| `/cover` / `/image` | 无 | **缺口**（无图片代理/封面裁切端点） |
| `/getBookSources` / `/getBookSource` | `GET /api/sources`（handlers/source.rs:71-77） | **结构不兼容**：`{sources, total}` 无信封 |
| `/saveBookSource(s)` / `/deleteBookSources` / `/saveJsSource` | `POST/PUT/DELETE /api/sources*`（source.rs:79-172） | 部分可复用数据层（BookSourceRepository），但**无批量 JSON 数组入口、无 JS 源专用通道、无令牌** |
| `/getRssSources` 等三件套 | `POST /api/rss/articles`（非源管理） | **缺口**（rss_source_repository.rs 数据层已存在） |
| `/getReplaceRules` 等三件套 | 无（replace_rule_repository.rs 数据层已存在） | **缺口** |
| `/getReviewSummary/Detail/Replies` | `GET /api/reviews/{book_url}/{chapter}`（handlers/review.rs:27） | 语义不同（我方为段评拉取，非原版三端点结构） |
| `/legacyReviewPage` + open/run | 无 | **缺口**（原版本地化功能，见分级） |
| `/getHttpLogs` / `/getHttpLog` | 无 | **缺口**（legado-core/app_log.rs 可评估复用） |
| `/getJsSourceApiTokenRequired` | 无 | **缺口**（前端首屏即探测，缺失时前端按"required=true"处理——见 §3.4 注） |
| WS `/searchBook` | `GET /api/ws/search`（ws/search_ws.rs:79） | **不兼容**：我方为进度播报桩（welcome+模拟进度），无「首条消息传 key、逐源推 SearchBook、搜完关闭」协议；且路径/端口/子协议均不同 |
| WS `/bookSourceDebug`、`/rssSourceDebug` | `GET /api/ws/debug/book-source`、`/api/ws/debug/rss-source`（ws/book_source_debug.rs:70 等） | 路径/子协议/消息协议不兼容（无 `["legado", token]` 子协议握手） |

### 3.3 端点缺口清单（分级）

判定基准：Vue 前端按 `isSuccess/errorMsg/data` 信封解析，任何非信封响应都会触发「后端返回内容格式错误」toast（`index-toG2697L.js` 的 `Ct` 校验器）。因此**所有"结构不兼容"等同"缺失"**，需要以原版路径+信封新增实现（我方 `/api/*` 保留不动，两套路由并存，互不影响）。

**A 级（必须先做——书架/阅读主链路，用户裁决目标）：**

| 端点 | 类型 | 可复用 Rust 数据层/链路 | 工作量 |
|---|---|---|---|
| `/getBookshelf` | 简单 CRUD | `BookRepository::find_all` + 排序分支（bookshelfSort 需新增配置读取或先固定 durChapterTime 降序——待实测） | 小 |
| `/getChapterList?url=` | 简单 CRUD + 回退链 | `BookChapterRepository::find_by_book_url`；空时接 `legado-core toc_updater` | 中 |
| `/getBookContent?url=&index=` | 需业务链 | 既有 reader.rs 抓取链 + `content_processor.rs`（替换净化对齐） | 中 |
| `/saveBookProgress`（含 sendBeacon） | 简单写 | `BookRepository` 按 name+author 更新 dur 字段 | 小 |
| `/cover?path=` | 简单（需图片处理） | cover_rule_repository + legado-net；需 PNG 缩放（84x112）与默认封面回退 | 中 |
| `/image?path=&url=&width=` | 需业务链 | legado-fetcher/web_book 图片规则链 | 中 |
| `/getReadConfig` / `/saveReadConfig` | 简单 KV | legado-db 缓存表或等价 KV | 小 |
| `/deleteBook`、`/saveBook` | 简单写 | `BookRepository`（saveBook 的 WebDav 上传可后置） | 小 |
| 静态资产（2.2MB 嵌入 + MIME 修正 + `/`→`/index.html` + `/vue/*.html` CSP） | 资产 | 见 §四 | 小 |

**B 级（可后置——书源/订阅源编辑与搜索）：**

| 端点 | 类型 | 可复用 | 工作量 |
|---|---|---|---|
| `/getBookSources`、`/getBookSource` | 简单 CRUD | `BookSourceRepository::find_all/find_by_url` | 小 |
| `/saveBookSource(s)`、`/deleteBookSources` | 简单写 | BookSourceRepository | 小 |
| `/saveJsSource` + `/getJsSourceApiTokenRequired` + 令牌中间件 | 需业务链 | legado-js；令牌校验逻辑需对齐（§2.5） | 中 |
| `/getRssSources` 三件套 | 简单 CRUD | `rss_source_repository.rs` | 小 |
| WS `/searchBook`（port+1） | 需业务链 | `search_aggregate.rs`/`search_engine.rs` + axum WS；需独立监听端口或同端口升级（待实测原版行为差异） | 大 |
| WS `/bookSourceDebug`、`/rssSourceDebug` | 需业务链 | ws/debug_ws.rs 既有底座 + 子协议握手 | 大 |

**C 级（不适用/最后考虑——原版本地化或低价值）：**

| 端点 | 说明 |
|---|---|
| `/getReplaceRules` 三件套 | 数据层已有（replace_rule_repository.rs）；但 active Vue bundle 无调用点，可最后做 |
| `/getHttpLogs` / `/getHttpLog` | HTTP 调试日志，工具性；legado-core/app_log.rs 部分可复用 |
| `/legacyReviewPage` + `/openLegacyReview` + `/runLegacyReview` | 原版派生的「旧评论」本地化功能，非上游 gedoor 原版能力；建议列为"不适用（需用户裁决）" |
| `/refreshToc`（独立 GET） | 可由 getChapterList 空目录回退覆盖，可后置 |

数量小结：A 级 9 项、B 级 6 项、C 级 4 项；其中"简单 CRUD"约 9 个、"需业务链/网络抓取"约 6 个、"资产/基建"1 项。

### 3.4 静态资产差距

- 我方：`rust/legado-server/web-dist/index.html`（9,536B 自制页，include_str 嵌入）。
- 原版：`app/src/main/assets/web/` 2.2MB / 67 文件（vue 1.46MB + help 228KB + assets 190KB + uploadBook 57KB + images 51KB + 根 6.6KB）。
- 前端运行时行为对静态服务的硬要求（来自产物字符串取证）：
  1. 入口 `/` 与 `/index.html`；
  2. `/vue/` 目录下 JS/CSS/woff/ttf/ico 子路径（带 hash 文件名，可长缓存但原版对 html 加 no-cache）；
  3. `/help/*`（markdown 站，Vue 页内有 10 处 `/help/#xxx` 直链）；
  4. `/uploadBook/*`（传书页）；
  5. MIME 必须正确到 `.woff`/`.ttf`（原版 AssetsWeb 的 MIME 表其实是错的，但 nosniff 下浏览器仍以 font 形式加载——我方应直接用 mime_guess 正确表，属"结果一致"而非"缺陷复刻"，建议如实向用户说明）；
  6. `/vue/index.html` 需要 CSP 头（VUE_CONTENT_SECURITY_POLICY）以维持产物内联样式放行（style-src 'unsafe-inline'）。

---

## 四、资产移植方案（任务 2.4 落点选择）

**方案①（推荐）：整体拷入 `rust/legado-server/web-dist/` + `include_dir`（或 rust-embed）编译期嵌入**

理由：
1. **设备语义正确**：现 routes.rs 的 ServeDir fallback 依赖 CWD，Android/iOS 上不可靠——这正是 routes.rs:15-26 注释里已自我记载的教训（本次只是把单文件 include_str 推广为整目录嵌入）。
2. **与原版分发方式同构**：原版就是把同一目录打进 Android assets 由 AssetsWeb 只读吐出，不存在运行期写需求。
3. **iOS 硬约束**：设备上无 CWD 保证（docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md 已证 server 链路在 iOS 必然编入且行为同构），磁盘落地方案需额外"首次启动解包"逻辑，复杂度更高且引入版本升级清理问题；嵌入则零成本。
4. **体积可接受**：2.2MB 原始字节约 1.5MB gzip 后体积（压缩产物 js/css 为主）；include_dir 不压缩进二进制则约 +2.2MB——对当前 APK（Flutter 资产已数十 MB 级）不敏感；如在意，可启用 `include_dir` 的压缩特性或 rust-embed 的 gzip feature（实施时二选一，先验证 axum 响应侧 Content-Encoding 透传）。
5. 实施要点：新增 `get_file(path) -> Option<EmbeddedFile>` 兜底 handler 替换 ServeDir fallback；`/` 与 `/index.html` 映射根 index；对 `/vue/*.html` 加 no-cache+CSP；MIME 用 mime_guess（修正原版 .woff/.ttf/.png 误标为 text/html 的缺陷，属结果一致）；**删除/停用现有 9.5KB 自制页**需用户确认（它是"已授权的自研页"还是将被替代物——本报告不擅自处置）。

**方案②（不推荐）：Flutter assets 分发 + 运行时落地**
需在 Dart 侧随包携带 2.2MB、首次 server_start 前解包到应用目录、server 侧再按落地路径挂 ServeDir；引入三端路径差异与升级清理，且 server crate 依赖 Flutter 包存在（与"Web 服务可独立于 UI 运行"的现有形态冲突）。仅当用户明确要求"Web 资产可热更新不重编 Rust"时才值得。

**方案③（否决）：仅磁盘 ServeDir**——设备不可用，现况已证明。

---

## 五、分批实施建议（任务 3）

- **B1 资产移植 + 静态服务对齐**：拷贝 `app/src/main/assets/web/**` → `rust/legado-server/web-dist/web/**`，include_dir 嵌入 + MIME/CSP/缓存头对齐（§2.4 六条硬要求）。
  验收：设备开启 Web 服务，PC 浏览器打开 `http://<设备IP>:1122/` 能看到原版导航页，`书架`按钮进入 Vue 应用不白屏（此时数据接口报"连接异常"属预期）。
- **B2 核心只读端点（书架/目录/正文/封面/配置）**：A 级中 getBookshelf、getChapterList（含空目录自动抓取）、getBookContent（含 ContentProcessor 对齐）、getReadConfig、cover。
  验收：PC 浏览器打开能看到与原版一致的书架（封面、排序、阅读进度角标），点开书能看目录与正文、能翻章，图片书正文图片经 /image 正常显示。
- **B3 写端点（进度/删书/传书/换配置）**：saveBookProgress（含 beacon）、saveBook、deleteBook、saveReadConfig、addLocalBook。
  验收：PC 上阅读后回手机 App 进度已同步；WiFi 传书页拖入 txt/epub 后书架出现新书；删除书籍双向一致。
- **B4 书源/订阅源管理 + 令牌体系**：getBookSources 三件套、saveJsSource、getJsSourceApiTokenRequired、令牌中间件（§2.5 语义）、getRssSources 三件套。
  验收：PC 端书源页能导入/编辑/调试保存书源并回写设备；配置令牌后未带令牌的写请求被原样文案拒绝。
- **B5 WebSocket（port+1 独立监听）**：/searchBook 多源搜索、bookSourceDebug/rssSourceDebug。
  验收：PC 端书架搜索框发起多源搜索逐源出结果；书源调试窗口实时滚动日志。
- **B6（可选/待用户裁决）**：replaceRule 三件套、httpLogs、legacyReview（或裁定为不适用）。

风险与待实测项见 §六。**FFI 契约不受影响**：本专项全部为 legado-server crate 内 HTTP 层与静态资产，`server_start(port)` 签名不变（如选 B5 双端口方案，也只在 server 内部自行再 bind port+1，不需要新 FFI 面）；server 直接经 `db_state` 全局池查库，不新开连接池（对齐 server.rs:47-55 单池注释）。

---

## 六、无法静态确证项（待实测清单）

| # | 事项 | 现有证据 | 取证方法 |
|---|---|---|---|
| 1 | Book 实体经 GSON 序列化的**完整字段集**（getBookshelf data 元素形态，尤其 latestChapterTime/durChapterTitle/order 等字段是否恒在） | 我方 `Book` 已按 camelCase rename（legado-core/src/models/book.rs:114-130），但字段全集与 null 策略未逐一对过 | MuMu Test 实例装原版 `com.legado.app.release`，开 Web 服务后 `curl http://<ip>:port/getBookshelf` 抓响应做字段对照 |
| 2 | `/refreshToc` 是否被 Vue active bundle 调用 | toG2697L 中未见调用点（仅 Kotlin 侧存在），可能仅旧构建或 App 内使用 | 原版实机 Web 页删除重进书籍时抓网络面板 |
| 3 | WS 搜索的**具体消息节奏**（单条数组 vs 逐源逐条、进度消息有无） | BookSearchWebSocket.kt:126-128 显示 `onSearchSuccess` 一次性 send 整列表字符串 | 原版实机浏览器 DevTools WS 帧记录 |
| 4 | `getChapterList` 空目录自动抓取的**同步等待行为**（原版直接 runBlocking 抓完再返回，我方对齐时确认前端 loading 超时容忍度） | BookController.kt:189-191 直接调 refreshToc 同步返回 | 同 #1，构造一本无章节书籍实测 |
| 5 | `sendBeacon` 打 `/saveBookProgress` 时 **Content-Type 为 text/plain 而非 json** 的服务端解析差异 | Beacon API 固定 text/plain；NanoHTTPD parseBody 实际接受 | 原版实机退出阅读页时抓 POST 头 |
| 6 | 旧构建双套 chunk（toG2697L vs Cuw80yqS）是否为**有意的特性开关**（如 A/B） | 两套并存且互不引用；API 层一致，令牌 Set 略有差异（Cuw 套 Set 覆盖 ReplaceRule/LegacyReview，toG 套也有该 Set 但无调用点） | 对比上游 gedoor/legado 对应版本的 assets 目录（GitHub release apk）确认哪套是官方当前产物 |

## 七、给下游实施代理的入口建议

1. 实施一律从 `rust/legado-server/src/routes.rs` 起步：新增 `legacy_routes()` 与 `web_static()` 两个模块，不与 `/api/*` 混排；响应信封做一个 `ReturnData` 结构体 + `serde` 统一序列化（含大列表 chunked 语义可先不做——axum 默认即流式 body）。
2. 数据层入口：`legado_db::repository::book_repository::BookRepository`、`book_chapter_repository`、`book_source_repository`、`rss_source_repository`、`replace_rule_repository`；抓取链入口 `legado-core/src/web_book.rs` + `legado-fetcher/src/web_book.rs`；替换净化 `legado-core/src/content_processor.rs`。
3. 每批完成跑 `cargo test`（routes.rs 已有集成测试形态可仿写，routes.rs:247-386）+ MuMu 实机验收（B1 起 Web 页即为用户可见物，直接浏览器验收）。
4. 本报告为差距盘点，不含任何实施改动；`web-dist/index.html` 自制页的处置（删除或保留为 `/about` 类入口）待用户裁决。

---

编写者：调研员 + 调研，2026-10-07
