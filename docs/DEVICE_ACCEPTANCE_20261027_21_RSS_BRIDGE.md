# 批21 RSS WebView preloadJs 宿主桥 + 脚本清洗设备验收（2026-10-27）

> 范围：RSS 阅读 WebView `preloadJs` 宿主桥（批21a~21g）、`injectJs`/`ajaxAwait`/`singleUrl`
> URL 模式/`shouldOverrideUrlLoading`/`showWebLog`、页面脚本清洗（mXSS / meta refresh / 内联事件）
> 与回归。设备：MuMu「Test测试」实例（Android 15 / x86_64）。
>
> 设备端点：`192.168.100.62:5555`（实测在线，adbd 以 root 运行）
> 源码基线：`master` HEAD `ac27350d16`（批21g 收尾）
> 验收时间：2026-10-27 19:03 ~ 19:30（+08:00）
> 证据目录：`tmp_debug/device_acceptance_20261027_rss_bridge/`
> 宿主 mock：`127.0.0.1:18082` 绑定 `0.0.0.0`，设备经 LAN `192.168.100.52:18082` 访问
> （`adb reverse` 未使用；实测 LAN 直连稳定，`/echo` 可达）。

## 一、结论总览

| # | 场景 | 结论 | 关键证据 |
|---|---|---|---|
| 1 | 宿主桥基础（HTML 模式） | **PASS**（`tag=no-tag` 口径见 §三.1） | `screens/03_s1_bridge_detail.png` |
| 2 | `ajaxAwait` mock 回环 | **FAIL（字面断言）**：`r.body` 为 undefined；桥回环本身正常 | `screens/05_s2_ajax_detail.png`、`screens/05b_s2_ajax_detail_header.png`、`mock/requests.jsonl` |
| 3 | `injectJs` 无桥 | **PASS** | `screens/03_s1_bridge_detail.png` |
| 4 | 脚本清洗（mXSS / refresh / onerror） | **PASS** | `screens/06_s4_clean_detail.png`、`mock/requests.jsonl` |
| 5 | URL 模式（`singleUrl`） | **PASS**（字面 `java.ajaxAwait` 为 undefined，见 §三.5） | `screens/08c_s5_urlmode.png`、`screens/15_s5_urlmode_javaajax.png` |
| 6 | `shouldOverrideUrlLoading` | **PASS** | `screens/10_s6_override_article.png`、`screens/11_s6_after_block_click.png`、`logs/logcat_evidence.txt` |
| 7 | `showWebLog` / `java.log` | **FAIL**：`console.log` 可见；`java.log('BRIDGE_LOG')` 不可见（动作通道缺陷） | `screens/19_s7_console_vs_javalog.png`、`logs/logcat_evidence.txt`、`screens/18_s7_direct_action.png` |
| 8 | 安全（通道删除 / 明文 / mXSS SAFE） | **FAIL（部分）**：通道已删，但 window 仍留 `legado` 命名全局；内联桥脚本含登录头/源变量明文 | `screens/07_s8_sec_detail.png`、`screens/06_s4_clean_detail.png` |
| 9 | 回归（普通 RSS / 书架 / 阅读器 / FATAL） | **PASS** | `screens/20_s9_normal_article.png`、`21_s9_normal_link_nav.png`、`24_s9_bookshelf_withbook.png`、`25_s9_reader.png`、`logs/final_env.txt` |
| 10 | 真实 preloadJs 源对比（可选） | **未覆盖** | 设备无原版可用 preloadJs 源；见 §五 |

- **FATAL = 0**（`FATAL_EXCEPTION` 计数 0，`E/flutter` 计数 0，`logs/final_env.txt`）。
- 新增两个必须修复项：**P1 动作通道被同名函数遮蔽**（场景 7，影响 `java.log/toast/open/...`）与
  **安全断言不成立**（场景 8，快照明文内联 + 全局命名残留）。

## 二、构建与安装

### 2.1 Rust（`rust/scripts/build-android.ps1 -Mode release`）

退出码 **0**；三 ABI 产出并复制到 `flutter_legado/android/app/src/main/jniLibs/`。

| ABI | 大小 | quickjs（.meta） | 备注 |
|---|---|---|---|
| arm64-v8a | 50,525,392 B | true | — |
| armeabi-v7a | 33,679,880 B | **false（回退）** | `rar` crate 编译错误 `E0277`，沿用既有回退；本设备 x86_64 不受影响 |
| x86_64 | 50,619,416 B | true | 验收使用 |

- FRB contentHash `1314275783`；Rust 源码指纹 `4792af0112ec5237...`（完整值见 `.meta`）。
- 证据：`logs/build_rust.log`、`logs/build_info.txt`。

### 2.2 Flutter（`flutter build apk --release`）

| 项 | 值 |
|---|---|
| 退出码 | 0（`√ Built ... app-release.apk (187.0MB)`） |
| 大小 | 196,072,004 B |
| sha256 | `99352579cfe2cae239887ea6b1421bb49a07df30b61fe60e5c362c395fe4ab5c` |
| 安装 | `adb install -r` 成功 |
| 版本 | **versionName 2.0.396 / versionCode 397**（pubspec 未 bump，与任务预期一致） |

- 证据：`logs/build_apk.log`、`logs/apk_sha256.txt`、`logs/final_env.txt`。

### 2.3 夹具与 DB 处置

- 首次启动生成 DB 后立即备份：`db/legado.db.orig`（274,432 B，WAL checkpoint 后拉取）。
- 夹具：8 个 `rssSources`（`sourceGroup='QA批21'`）+ 3 条 `caches`（登录头/源变量/`v_k`），
  生成脚本 `db/gen_fixtures.py`、SQL `db/seed_sources.sql`；落库回读见 `db/qa_sources_runtime_dump.txt`。
- mock：`mock/mock_server.py`（`/rss_bridge.xml`、`/echo`、`/urlmode.html`、`/article/*`、`/pixel.png`、
  `/refresh_target.html`），逐请求头记录 `mock/requests.jsonl`，统计 `mock/requests_summary.txt`。
- **收尾已恢复原 DB**（`db/legado.db.orig` → 设备），删除 `-wal/-shm`，`chown u0_a62`；
  恢复后 `rssSources=0`、`QA批21=0`、`books=0`，订阅页显示「当前没有订阅源！」（`screens/26_restored_rss_tab.png`）。

## 三、逐场景明细

### 1. 宿主桥基础（HTML 模式）——PASS

源 `QA21-桥基础`（preloadJs 为任务给定脚本 + injectJs 回显），打开 `QA-BRIDGE-基础`。

页面渲染结果（`screens/03_s1_bridge_detail.png`）：

```
INJECTED=1 JAVA=undefined SRC=undefined CACHE=undefined
TITLE=BRIDGE|no-tag|src=http://192.168.100.52:18082/rss_bridge.xml?s=bridge|put=v1|cache=cv1|b64=5Lit5paH|md5=900150983cd24fb0d6963f7d28e17f72
URL=http://192.168.100.52:18082/article/1.html
```

- `src/put/cache/b64/md5` 全部符合预期，`b64` 为 `5Lit5paH`、`md5` 为
  `900150983cd24fb0d6963f7d28e17f72`；无 `ReferenceError`，握手日志 `握手 ACK 已确认`。
- **口径说明（`tag=no-tag`）**：`java.getTag` 在桥中不存在（任务脚本自身带 `no-tag` 兜底）；
  Android 原版 `JsExtensions.getTag()` 无 `@JavascriptInterface`，经 `addJavascriptInterface`
  同样不暴露，`source.getTag()` 才可用。因此 `no-tag` 为原版等价行为，不判失败。

### 2. `ajaxAwait` mock 回环——FAIL（字面断言）

源 `QA21-AJAX`，preloadJs 按任务写法：

```js
ajaxAwait('http://192.168.100.52:18082/echo','',9000).then(r=>{ ... 'AW '+r.body ... })
```

实际（`screens/05_s2_ajax_detail.png`、`screens/05b_s2_ajax_detail_header.png`）：

```
AW-BODY undefined
AW-RAW hello
```

- **桥链路正常**：宿主 mock 收到 `GET /echo`（200，5 B `hello`），先源 UA 为 WebView UA，
  为 `QA21-AJAX` 补 `header` 后重测收到
  `user-agent: LegadoQA/21Bridge`、`x-qa-source: rss-bridge`（`mock/requests_summary.txt`）。
- **失败根因（验收脚本假设不成立）**：`ajaxAwait` 的返回值是**响应体字符串**（`"hello"`），
  不是 `{body}` 对象。Rust `__lgWebHost.ajaxAwait` 为 `String(java.ajax(...))`
  （`rust/legado-ffi/src/api/rss_web_bridge.rs:1195`），回环测试也钉死 `value == "ajax-body-ok"`
  （`rust/legado-ffi/tests/rss_web_bridge_loopback.rs:267-283`）；Android 原版
  `JsExtensions.ajax()` 同样返回 `String?` 响应体（`app/src/main/java/io/legado/app/help/JsExtensions.kt:134-147`）。
  因此 `r.body` 在原版语义下也为 `undefined`。
- **建议**：验收脚本改为 `'AW ' + r`（`AW-RAW hello` 已证明）；若产品要求 `{body}` 对象，
  需单独立项并同步契约/原版差异，不能在验收侧默默改口径。

### 3. `injectJs` 无桥——PASS

同一页面 `INJECTED=1 JAVA=undefined SRC=undefined CACHE=undefined`
（`screens/03_s1_bridge_detail.png`）。`injectJs` 经 `onPageFinished` 的 `runJavaScript`
在页面全局执行，桥 IIFE 闭包内的 `java/source/cache` 不可见，符合「仅 preloadJs 作用域有桥」的门控。

### 4. 脚本清洗（mXSS / meta refresh / onerror）——PASS

源 `QA21-清洗`（preloadJs `document.title='SAFE'` 先执行），文章 HTML 含任务四条向量 + 正常样式/图片。
实际（`screens/06_s4_clean_detail.png`）：

```
TITLE=SAFE
URL=http://192.168.100.52:18082/article/2.html
IMGS=2 SCRIPTS=1
```

- 标题未被 `HACKED`/`MXSS`/`ONERR` 覆盖；`meta refresh` 未生效（URL 仍为文章 baseUrl，
  无 `example.com` 导航）；正文 `CLEAN-BODY` 可见、绿色样式保留。
- `SCRIPTS=1` 为宿主注入的桥脚本；文章内 `<script>` 已删除。
- `IMGS=2`：`<img src=x>` 保留元素但 `onerror` 被剥离（mock 收到 `/article/x` 404 请求），
  正常 `<img src=/pixel.png>` 保留（`/pixel.png` 200，`mock/requests.jsonl`）。

### 5. URL 模式（`singleUrl`）——PASS（含字面口径偏差）

源 `QA21-URL模式`（`singleUrl=1`，`sourceUrl` 指向 `/urlmode.html`）。点击源直接进入站内 WebView。
实际（`screens/08c_s5_urlmode.png`）：

```
URLMODE-PAGE（顶栏）
URL MODE BODY
SRC=http://192.168.100.52:18082/urlmode.html
AW-BODY undefined
AW-RAW hello
```

- `onPageStarted` 注入可用：页面出现 `SRC=source.getKey()` 与 `AW-RAW hello`；
  mock 收到 `/urlmode.html` 与 `/echo?from=urlmode`（200），握手日志 `ACK 已确认`。
- **字面 `java.ajaxAwait` 不成立**：`screens/15_s5_urlmode_javaajax.png` 显示
  `JAVA_AJAXAWAIT=undefined`。原版 `WebJsExtensions.kt` 的 `JS_INJECTION` 也只定义**裸函数**
  `ajaxAwait`（`app/.../WebJsExtensions.kt:254`），`java` 接口没有 `ajaxAwait`；故裸 `ajaxAwait`
  为正确 API，字面写法属验收脚本偏差。
- **注入时机**：URL 模式 preloadJs 在 `onPageStarted`（文档起始）执行，此时 `document.body`
  可能为 `null`；依赖 DOM 的脚本需等 `DOMContentLoaded`（本次夹具已按此写法，正常）。
  这是已登记差异（HTML 模式内联 `<head>`，URL 模式退化为文档开始执行）。

### 6. `shouldOverrideUrlLoading`——PASS

源 `QA21-拦截`：`shouldOverrideUrlLoading = java.get('k')=='v1'`，
`caches.v_<sourceUrl>_k = v1` 预置。打开 `QA-OVERRIDE-拦截`（`screens/10_s6_override_article.png`），
点击 `BLOCK_ME_LINK`：

- logcat：`[RSS WebView] shouldOverrideUrlLoading 拦截: http://192.168.100.52:18082/article/blocked.html`
  （`logs/logcat_evidence.txt`）。
- mock **未收到** `/article/blocked.html`（`mock/requests_summary.txt` 计数 0）；
  页面保持原状（`screens/11_s6_after_block_click.png`）。
- 同页 `injectJs` 显示 `TITLE=OVERRIDE JAVA_K=v1`，证明 override 快照桩读到预置变量。

### 7. `showWebLog` / `java.log`——**FAIL（动作通道缺陷）**

源 `QA21-日志`（`showWebLog=1`），preloadJs：`console.log('BRIDGE_CONSOLE'); java.log('BRIDGE_LOG');`。

- `console.log` 路径正常：logcat 出现
  `[RSS WebView][QA21-日志] log: BRIDGE_CONSOLE`（`screens/19_s7_console_vs_javalog.png`）。
- `java.log('BRIDGE_LOG')` **在 logcat/AppLog 均不可见**（全量 logcat 检索无 `BRIDGE_LOG`、
  无 `[AppLog]`）。
- 隔离探针：在 preloadJs 内直接调用内部原语
  `__lgChannel.request('__action', '{"action":"log","message":"DIRECT_CHANNEL"}', ...)` 与
  外层 `__lgEmitAction({action:'log',message:'DIRECT_EMIT'})`，两者均产生
  `[AppLog] [RSS WebView][QA21-日志] DIRECT_CHANNEL` / `DIRECT_EMIT`
  （`screens/18_s7_direct_action.png`、`logs/logcat_evidence.txt`）。**通道和 Dart 动作处理均正常，
  `java.log` 包装层丢消息。**

**根因（代码级，高置信）**：Dart 同步面 `kRssBridgeSyncShimBody` 内声明了同名局部函数

- `flutter_legado/lib/src/services/rss_web_bridge.dart:669`：
  `function __lgEmitAction(name, payload) { ... __lgAction(data); }`
- 同文件 `:764-772` 的包装器 `__lgAction` 调用 `__lgEmitAction(payload || {})`（单参）。
- 由于函数声明提升，`__lgAction` 解析到**局部两参版本**，单参调用使 `payload` 为 `undefined`，
  局部函数再次调用 `__lgAction` → 无限互递归，最终 `RangeError` 被 `__lgAction` 的
  `try/catch` 吞掉，动作从未发送。
- 影响范围：`java.log` / `java.toast` / `java.longToast` / `java.open` / `java.searchBook` /
  `java.addBook` / `java.showPhoto` / `java.openUrl`（均经该包装器）。
- 修复方向：局部函数改名（如 `__lgDispatchAction`），或 `__lgAction` 改为调用
  Rust 桥头的原名（例如经 `__lgEmitRaw`）；修复后补一条 `java.log` 真机/单测断言。

### 8. 安全——**FAIL（部分）**

源 `QA21-安全`：`header` 含 `X-QA-Header: QA_SECRET_21`，登录头
`loginHeader_<sourceUrl> = {"Cookie":"LOGIN_SECRET_21=1"}`，源变量 `SECRET_VAR_21`。
`injectJs` 探针结果（`screens/07_s8_sec_detail.png`）：

```
NAMES=[__legado_rssBoot_v5sop2vilrit,__legado_rssCb_7tr9gvwlxu98]
CHAN=[]
LEAKS=[QA_SECRET_21,LOGIN_SECRET_21,SECRET_VAR_21] SCRIPTCOUNT=1
TITLE=SEC
```

- ✅ **通道已删除**：`CHAN=[]`（`__legado_rssNative_*` 已不可见）。
- ❌ **window 仍有 `legado` 命名全局**：`__legado_rssBoot_*`（幂等标记）与
  `__legado_rssCb_*`（回填回调）均为 `configurable:false`，按设计常驻；契约 §2.5 批21d
  「真机结论」已记载 `getOwnPropertyNames` 可见回调名。任务断言「结果应为空」不成立。
- ❌ **`document.scripts` 含明文**：HTML 模式把桥头（含 `__lgSnapshot`）作为 `<script>`
  内联进 `<head>`（`rss_web_config.dart:45-53`、`rssClHtml:354-401`），快照包含
  `header/loginHeader/sourceVariable/vars`（`rust/legado-ffi/src/api/rss_web_bridge.rs:481-492`），
  因此页面脚本可读到 `QA_SECRET_21`、`LOGIN_SECRET_21`、`SECRET_VAR_21`。
- **风险边界**：桥模式（preloadJs 非空）下文章页面脚本已被整体剥离，普通文章脚本无法读取；
  URL 模式页面属「可信页面」假设（与原版等价）。因此该明文泄漏当前不可由不可信文章脚本直接触发，
  但断言与「快照不下发页面」的目标不符，需产品或安全侧裁决：
  ① 评估把敏感快照移出内联脚本（改为页面不可读的宿主侧查询）；
  ② 至少避免在 `source.header` 外重复下发登录头/变量，或将快照字段按需裁剪。
- mXSS 聚合页标题 `SAFE`：见场景 4，`TITLE=SAFE`（PASS）。

### 9. 回归——PASS

| 子项 | 结果 | 证据 |
|---|---|---|
| 普通 RSS 文章（无 preloadJs） | 渲染正常：标题/正文/蓝色样式/链接；点击 `NORMAL-LINK` 站内导航到 `/article/3.html`，页面显示 `ARTICLE 3 BODY` | `screens/20_s9_normal_article.png`、`21_s9_normal_link_nav.png`、`mock/requests.jsonl` |
| 书架 | 空态正常显示，无崩溃 | `screens/22_s9_bookshelf.png` |
| 阅读器 | 临时换入含 1 本书的 dev DB 并补 3 章缓存正文后，书架显示《E2E测试书1》，打开阅读器显示「第二章」缓存正文，底栏 `1/1 66.7%` | `screens/24_s9_bookshelf_withbook.png`、`25_s9_reader.png` |
| FATAL | `FATAL EXCEPTION` = 0，`E/flutter` = 0 | `logs/final_env.txt`、`logs/logcat_evidence.txt` |

> 说明：全新安装 DB 无书籍数据，阅读器回归采用「dev DB + 缓存章节」临时夹具；验证后已恢复原 DB
> （`db/legado.db.orig`），不影响验收结论。本批改动不涉及书籍阅读链。

### 10. 真实 preloadJs 源对比（可选）——未覆盖

设备仅装有原版 `com.legado.app.release`（未登录、无可用 preloadJs 源数据），无法取得真实源做
双包对比；本项按任务「可选」标注未覆盖。若需闭环，建议在用户验收档（有真实订阅源）补一条
含 `preloadJs` 的源对照 `java.log`/`ajaxAwait`/`source` 行为。

## 四、证据文件清单（`tmp_debug/device_acceptance_20261027_rss_bridge/`）

| 文件/目录 | 说明 |
|---|---|
| `screens/00_launch.png` ~ `26_restored_rss_tab.png` | 全流程截图（启动、文章列表、桥基础、AJAX、清洗、URL 模式、拦截、日志、安全、回归、恢复） |
| `screens/ui_rss_sources.xml` | RSS 源列表 UI 树（点击坐标取证） |
| `logs/logcat_all.txt` | 全程 logcat（1.39 MB） |
| `logs/logcat_evidence.txt` | 关键片段（握手/拦截/console/AppLog/FATAL） |
| `mock/mock_server.py`、`mock/requests.jsonl`、`mock/requests_summary.txt` | mock 服务、逐请求头、统计（含 `/article/blocked.html` 计数 0） |
| `db/legado.db.orig` | 验收前 DB 备份（已恢复回设备） |
| `db/gen_fixtures.py`、`db/seed_sources.sql`、`db/seed_book.sql`、`db/update_*.sql` | 夹具与增量探针 SQL |
| `db/qa_sources_runtime_dump.txt` | 夹具落库回读（8 源 + 3 cache 键） |
| `logs/build_rust.log`、`logs/build_apk.log`、`logs/build_info.txt`、`logs/apk_sha256.txt` | 构建元数据 |
| `logs/final_env.txt` | 恢复后环境快照（版本/ABI/DB 计数/FATAL/reverse） |

## 五、遗留问题与建议（按优先级）

1. **P1（必须修）动作通道被同名函数遮蔽**：`rss_web_bridge.dart:669` 与 `:764-772`；
   `java.log/toast/open/...` 全部静默丢失。场景 7 因此 FAIL；建议立即修复并补 `java.log`
   单测 + 真机回归。修复前不得宣称「preloadJs 动作面可用」。
2. **P1（需裁决）安全断言**：`document.scripts` 含登录头/源变量明文（桥快照内联），
   `window` 残留 `__legado_rssBoot_*`/`__legado_rssCb_*`。前者需评估敏感快照下发面，
   后者可改为非 `legado` 命名的随机名或握手后清理（受 `configurable:false` 约束需改设计）。
3. **P2（验收口径）`ajaxAwait` 返回字符串**：与原版一致，但任务脚本按 `{body}` 断言；
   请修正验收脚本（`'AW '+r`）或另立产品需求，避免把原版等价行为记成缺陷。
4. **P2（原版等价）`java.getTag` / `java.ajaxAwait` 不存在**：原版同样不经
   `@JavascriptInterface` 暴露；建议在验收脚本文档中统一写 `source.getTag()` 与裸 `ajaxAwait`。
5. **P2（已登记差异）URL 模式注入时机**：`onPageStarted` 注入时 `document.body` 可能为 null，
   依赖 DOM 的 preloadJs 需等 `DOMContentLoaded`；本次已用该写法通过，建议在验收模板中注明。
6. **iOS 未验证**：本机无 Mac/Apple 设备；`webkit.messageHandlers` 通道、快照可见性、
   `java.log` 动作通道均需 iOS 真机复验。Android 结论不得外推到 iOS。
7. **armv7 quickjs 回退**：构建脚本沿用既有回退（`rar` crate `E0277`），本设备 x86_64 不受影响；
   如后续要支持 armv7 真机，需单独修复依赖编译。
8. **可选**：真实 preloadJs 源双包对比未覆盖（见 §三.10）。

## 六、收尾状态

- DB：已恢复 `db/legado.db.orig`（`rssSources=0`、`books=0`），删除 `-wal/-shm` 并修正属主。
- 测试源：随 DB 恢复全部消失（订阅页空态截图 `screens/26_restored_rss_tab.png`）。
- mock 服务：已停止（PID 120820 终止，18082 不再监听）。
- `adb reverse`：全程未建立，最终 `--list` 为空。
- logcat 采集进程：已终止。
- 设备应用：保留安装（versionName 2.0.396 / versionCode 397），便于后续复验。

---

编写者：QA（ZCode 子代理）｜ 2026-10-27
