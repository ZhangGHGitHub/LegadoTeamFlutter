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
| AnalyzeByJSoup | 8 方法 | ✅ 约 90%+（含 `@html`；ownText 近似） |
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

3. **`checkRedirect` 重定向检测**（影响偏弱）
   - 主要为 Debug.log 可观测性缺口，非兼容性阻断

4. ~~**`runPreUpdateJs` 更新前 JS 钩子**~~ → **✅ 已落地（2026-08-13）**
   - `refresh_toc` 调用 `pre_update::run_pre_update_js`（写回 book + 持久化）
   - **`java.reGetBook` / `java.refreshTocUrl`** 宿主钩子已注入（仅 preUpdateJs 期间可用）
   - 证据：commit `099b5ebc7` + 本轮钩子补齐

### P1 级（功能缺口）

5. ~~**`getWebJsResult`（规则级 Mode.WebJs）**~~ → **✅ 无头近似已落地（2026-08-13）**
   - `@webjs:` / `@webJs:` 前缀路由；注入 `result`/`src`/`html`/`baseUrl` 经 QuickJS 执行
   - **完整 BackstageWebView DOM 仍缺**（平台桥依赖；与正文 webJs 同源边界）

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

### 3.1 AnalyzeRule（约 90%）

- ✅ get_string/get_strings/get_elements/… / `@put`/`@get`/setLocal / setRedirectUrl / isUrl·unescape / `@webjs` 无头近似
- ⚠️ 完整 WebView DOM WebJs、编译缓存层仍缺

### 3.2 AnalyzeByJSoup（约 85%→更高）

- ✅ `@html`/`html`/`all`；⚠️ ownText 仍近似

### 3.3 AnalyzeUrl（约 90%）

- ❌ upload 多部件（N/A 边界）

### 3.4 JsExtensions / java 桥（约 95%）

- ✅ getReadBookConfigMap/getThemeConfigMap；reGetBook/refreshTocUrl（preUpdate 门控）
- ⚠️ webView cacheFirst、downloadFile 双参、getFile、unArchiveFile、openVideoPlayer isFloat、timeFormatUTC 等次要重载

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
6. 残留：完整 DOM WebView（平台桥）、次要 JS 重载、A\* 实网验收

---

## 6. 复核销记（2026-08-13）

| 项 | 结论 | 证据 |
|---|---|---|
| P0-1 `@put`/`@get`/`setLocal` | ✅ | `14517217b` |
| P0-2 `preciseSearch` | ✅ Rust+FFI+Dart FRB | `099b5ebc7` + 本轮 |
| P0-4 `runPreUpdateJs` + reGetBook/refreshTocUrl | ✅ | `099b5ebc7` + 本轮 |
| P1-5 `@webjs` 无头近似 | ✅（完整 DOM 仍开放） | 本轮 |
| P1-6 `setRedirectUrl` | ✅ | 本轮 |
| P1-7 isUrl·unescape | ✅ | 本轮 |
| P1-9/10 imageStyle/sourceRegex·webJs | ✅ | `6b1eb163c`/`e05746a4c` |
| P1-11 upload | N/A | 直链边界 |
| P2-12 DownloadService | 形态 N/A | downloadFile + url_launcher |
| P2-13 ConfigMap | ✅ | 本轮 |
| §4.2 过时注释 | ✅ | 本轮 |
| Cronet / 直链上传产品入口 | N/A | GAP / RESIDUAL |

编写者：Reasonix ｜ 2026-08-13（源码级只读审计）  
修订：Auto（Cursor）｜ 2026-08-13（实现销记 P0/P1/P2 开放项；DownloadService/upload 标 N/A）
