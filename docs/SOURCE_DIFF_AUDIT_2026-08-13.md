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
| 解析核心 AnalyzeRule | 40+ 方法逐函数 | ⚠️ 约 90%（本轮 isUrl/unescape/setRedirectUrl/@webjs） |
| AnalyzeByJSoup | 8 方法 | ✅ 约 95%+（含 `@html`；ownText 对齐 Jsoup） |
| AnalyzeUrl | 60+ 方法/getter | ⚠️ 约 90% |
| JsExtensions（java 桥） | 120+ 方法 | ⚠️ 约 95%（含 ConfigMap） |
| 响应层 legado-net | LegadoResponse/RawResponse/cookie/rate_limit/webdav/cover | ⚠️ 约 85% |
| web_book 域 | search/info/chapters/content/分页/subContent/payAction/callBackJs | ⚠️ 约 85% |
| 数据实体层 | Kotlin 42 实体 vs Rust 44 模型 | ✅ Book 等核心实体字段完整对齐 |
| Service 层 | 10+ 原版 Service | ⚠️ 见 §3.6 |
| API 域（搜索/备份/WebDAV/高亮/阅读记录/词典/规则订阅/登录/RSS/Explore/缓存下载/导出） | 逐 API 存在性 | ✅ 全部有对应 |

---

## 2. 实质缺失清单（按影响排序，累计多轮结论）

### P0 级（影响书源兼容性）

1. ~~**`@put:` 变量系统**（put/get/setLocal）~~ → **✅ 已落地（2026-08-13）**
   - 证据：commit `14517217b`

2. ~~**`preciseSearch` 精确搜索**~~ → **✅ 已落地（2026-08-13）**
   - Rust：`search::precise_search` + FFI `preciseSearch`
   - Dart/FRB：codegen + `BookApi.preciseSearch`；书单导入/批量换源已接线
   - 证据：commit `099b5ebc7` + 本轮 FRB/UI 接线

3. ~~**`checkRedirect` 重定向检测**~~ → **✅ 可观测性已落地（2026-08-13）**
   - `web_book::check_redirect_log`：请求 URL ≠ 最终 URL 时 eprintln（对齐 Debug.log）

4. ~~**`runPreUpdateJs` 更新前 JS 钩子**~~ → **✅ 已落地（2026-08-13）**
   - `refresh_toc` 调用 `pre_update::run_pre_update_js`（写回 book + 持久化）
   - **`java.reGetBook` / `java.refreshTocUrl`** 宿主钩子已注入（仅 preUpdateJs 期间可用）
   - 证据：commit `099b5ebc7` + 本轮钩子补齐

### P1 级（功能缺口）

5. ~~**`getWebJsResult`（规则级 Mode.WebJs）**~~ → **✅ DOM 通道 + 无头回退（2026-08-13）**
   - Flutter 订阅 `webviewRequestStream` 时走真实 BackstageWebView DOM（`window.result`/`document`）
   - 无订阅者回退无头 QuickJS（`result`/`src`/`html`/`baseUrl`）
   - Android：原生 `backstageEval` 注入 `java`/`source`/`cache` JavascriptInterface；`cacheFirst`→`LOAD_CACHE_ELSE_NETWORK`

6. ~~**`setRedirectUrl`**~~ → **✅ 已落地（2026-08-13）**
   - `AnalyzeRule::set_redirect_url` + `redirect_url`；`isUrl` 绝对化使用该 base

7. ~~**`getStringList(..., isUrl=true)` + `getString(rule, unescape)`**~~ → **✅ 已落地（2026-08-13）**
   - `get_strings_ex` / `get_string_ex(is_url, unescape)`；默认 `get_string` 保持 unescape=true

8. ~~**AnalyzeByJSoup `@html`**~~ → **✅ 已对齐**

9. ~~**`imageStyle` 正文图片样式**~~ → **✅ 已接线**（`6b1eb163c`）

10. ~~**`sourceRegex` 正文应用**~~ → **✅ 已接线**（`e05746a4c`，无头近似）

11. **`upload(fileName, file, contentType)` 多部件上传** → **N/A**
    - 与直链上传产品入口正式 N/A 联动（GAP §10.2 / RESIDUAL「不做」），勿单独重开

### P2 级（通用文件下载 / 形态）

12. **`DownloadService` 通用文件下载** → **形态 N/A（功能覆盖）**
    - 原版：Android DownloadManager + 前台通知（Update/WebView/RSS 附件）
    - 重构：JS `downloadFile` 沙箱下载 + 更新对话框 `url_launcher`；跨平台无 DownloadManager 前台服务形态
    - **不按 Android Service 硬做**；真机附件下载体验属 A\* 验收

13. ~~**`getReadBookConfigMap`/`getThemeConfigMap`（Map 版）**~~ → **✅ 已落地（2026-08-13）**
    - `java.getReadBookConfigMap` / `getThemeConfigMap` 返回 QuickJS Object（同源 String JSON 解析）

---

## 3. 差异明细（按层）

### 3.1 AnalyzeRule（约 90%→更高）

- ✅ get_string/get_strings/get_elements/… / `@put`/`@get`/setLocal / setRedirectUrl / isUrl·unescape / `@webjs` DOM 通道+无头回退
- ✅ 编译缓存层（`string_rule_cache`，对齐 `stringRuleCache`）；Android 页内 java/source/cache 注入

### 3.2 AnalyzeByJSoup（约 85%→更高）

- ✅ `@html`/`html`/`all`；✅ ownText 对齐 Jsoup（仅直接文本子节点）

### 3.3 AnalyzeUrl（约 90%）

- ❌ upload 多部件（N/A 边界）

### 3.4 JsExtensions / java 桥（约 95%→更高）

- ✅ getReadBookConfigMap/getThemeConfigMap；reGetBook/refreshTocUrl（preUpdate 门控）
- ✅ webView `cacheFirst` 参数、downloadFile 双参（含 hex 废弃重载）、getFile 对象、unArchiveFile 别名、openVideoPlayer isFloat、timeFormatUTC（`sh`=毫秒偏移）
- ✅ Android `cacheFirst`→原生 `WebSettings.LOAD_CACHE_ELSE_NETWORK`（非 Android 回退路径仍无 cacheMode）

### 3.5–3.8

（与前版一致：响应层/Service/API/实体；DownloadService 见 §2 P2-12）

---

## 4. 缺陷与卫生问题（非缺失）

1. ~~**版本常量滞后**~~ → **✅ 已修（`46ebfa085`）**
2. ~~**过时注释**~~ → **✅ 已修（本轮）**：`reader_bottom_bar.dart` 自动翻页注释已对齐 `reader_screen._syncAutoTimer`
3. **Rust 多存瞬态字段**：infoHtml/tocHtml/downloadUrls（非功能缺陷）

---

## 5. 建议修复顺序

1. ~~P0-1 `@put:`~~ ✅
2. ~~P0-4 `runPreUpdateJs` / P0-2 `preciseSearch`~~ ✅（含 Dart FRB + reGetBook/refreshTocUrl）
3. ~~P1 `sourceRegex`+`webJs` / `imageStyle`~~ ✅
4. ~~P1 getWebJsResult（无头）/ setRedirectUrl / isUrl·unescape~~ ✅
5. ~~P2 ConfigMap~~ ✅；DownloadService 形态 N/A；upload N/A
6. ~~残留：AnalyzeRule 编译缓存、ownText、DOM 页内 java/source~~ ✅；仅剩 A\* 实网验收

---

## 6. 复核销记（2026-08-13）

| 项 | 结论 | 证据 |
|---|---|---|
| P0-1 `@put`/`@get`/`setLocal` | ✅ | `14517217b` |
| P0-2 `preciseSearch` | ✅ Rust+FFI+Dart FRB | `099b5ebc7` + 本轮 |
| P0-4 `runPreUpdateJs` + reGetBook/refreshTocUrl | ✅ | `099b5ebc7` + 本轮 |
| P0-3 checkRedirect 可观测性 | ✅ | 本轮 `check_redirect_log` |
| P1-5 `@webjs` / 正文 webJs DOM | ✅（含页内 java/source） | webview_channel + 原生 backstageEval |
| P1-6 `setRedirectUrl` | ✅ | 本轮 |
| P1-7 isUrl·unescape | ✅ | 本轮 |
| P1-9/10 imageStyle/sourceRegex·webJs | ✅ | `6b1eb163c`/`e05746a4c` |
| P1-11 upload | N/A | 直链边界 |
| P2-12 DownloadService | 形态 N/A | downloadFile + url_launcher |
| P2-13 ConfigMap | ✅ | 本轮 |
| §3.4 JS 次要重载 | ✅（Android cacheMode 真落地） | 本轮 |
| ownText / AnalyzeRule 编译缓存 | ✅ | 本轮 html.rs + string_rule_cache |
| §4.2 过时注释 | ✅ | 本轮 |
| Cronet / 直链上传产品入口 | N/A | GAP / RESIDUAL |
| Android x86_64 so + 5556 冒烟 | ✅ 本轮 | `build-android.ps1 -Targets x86_64`；`emulator_smoke_test.ps1 -Device emulator-5556` |

**本轮终态仍开放（勿销）**：A\* 素材/实网验收（不得由模拟器冒烟销账）。

---

## 7. 复核销记（2026-08-14，v2.0.45）

| 项 | 结论 | 证据 |
|---|---|---|
| 发现列表点号索引（`$[n].field`） | ✅ | `6bb18abb9` |
| 思路客 {{page}} / nextTocUrl 分页 / 详情 HTML 短缓存 | ✅ | `deca82748` |
| 目录 AnalyzeRule 复用（同页多规则） | ✅ | `deca82748` |
| 发现 @js 分类上下文注入 | ✅ | `b6707c1c8` / `2207e207e` |
| 已知 tocUrl 跳过详情页 | ✅ | `b6707c1c8` |
| `refresh_toc` 占位落库 `NOT_SHELF` | ✅ | `fafc65782` |
| 仅浏览详情/目录误入书架 | ✅ | `1fd863406` + `fafc65782` |

编写者：Auto（Cursor）｜ 2026-08-14

---

编写者：Reasonix ｜ 2026-08-13（源码级只读审计）  
修订：Auto（Cursor）｜ 2026-08-13（实现销记 P0/P1/P2 开放项；DownloadService/upload 标 N/A）  
修订：Auto（Cursor）｜ 2026-08-13（补编译修复 `30c48ded2` + 5556 冒烟证据）  
修订：Auto（Cursor）｜ 2026-08-13（DOM WebView 通道 + JS 次要重载 + checkRedirect）  
修订：Auto（Cursor）｜ 2026-08-13（页内 java/source + cacheMode + ownText + 编译缓存；§5.15 仅剩 A\*）

---

## 8. 页面覆盖缺口登记（F3-16，2026-08-14）

> 审计 D19：原版 53 个 `ui/*Activity` 中 2 项在 Flutter 侧无 1:1 Screen；本节如实登记处置结论，供 GAP/REMAINING 交叉引用。

| 原版 Activity | 路径 | Flutter 处置 | 说明 |
|---|---|---|---|
| `HandleFileActivity` | `ui/file/` | **N/A** | Android SAF/Intent 统一文件中转（打开方式、分享接收、EXPORT 模式）。Flutter 跨平台各入口已用 `file_picker` / 平台通道等价，不单独移植 Activity（与 GAP_AUDIT P2-14、REMAINING Doc5 一致） |
| `RssSortActivity` | `ui/rss/article/` | **降级** | 原版 RSS 文章排序页。Flutter `RssArticlesScreen` 保留列表与阅读，**无**独立排序 UI；排序语义暂不提供（非 P0 书源兼容项，后续若需对齐再单独立项） |

编写者：Cursor 子代理 ｜ 2026-08-14（F3-16 SOURCE_DIFF 缺口登记）
