# Web 服务读正文「后端连接失败」失败面调研报告

- 日期：2026-10-07
- 调研方式：Windows 本机静态分析（只读）+ 本地三态复现测试（tests 增补，独立 commit）
- 报障现象：iOS 实机跑我方 App（Web 服务运行中，`/api/health`、`/api/books` 均 200），PC 浏览器开原版 Vue 界面读书，**读正文一步**弹红色横幅「后端连接失败，请检查阅读WEB服务或者设置其它可用链接」
- 涉及文件：
  - 前端产物 `rust/legado-server/web-dist/vue/assets/index-Cuw80yqS.js`（与 `index-toG2697L.js` 同构双份）
  - 服务端 `rust/legado-server/src/legacy/book_api.rs`、`rust/legado-server/src/handlers/web_book.rs`
  - App 端对照 `rust/legado-ffi/src/api/web_book.rs`、`rust/legado-ffi/src/api/reader.rs`
- 测试证据：`rust/legado-server/tests/legacy_web_test.rs` 三个 `test_survey_*` 用例，31/31 通过；commit `a5e64666a1`（test: 调研取证）

---

## 一、结论摘要

1. **红色横幅是 axios 响应拦截器的 reject 分支产物**（HTTP 非 2xx / 网络层失败 / 120s 超时），**不是** `isSuccess=false` 信封。`isSuccess=false` 走的是成功拦截器中的警告分支（「后端返回内容格式错误」不触发；errorMsg 在读书页有专门展示位）。→ 用户看到红横幅 ⇒ **请求没有以 HTTP 200 + JSON 信封抵达**。
2. 服务端 `/getBookContent` 全部失败点都是 **HTTP 200 + `isSuccess=false` + errorMsg** 信封（`legacy/mod.rs:87-96` 恒 200），本地三态复现测试证明三条正文路径（缓存/书源缺失/网络抓取/本地书）**在本机环境全部可用且错误信封形态正确**。⇒ 与「红横幅」现象同型的服务端候选只剩 **handler panic → 连接中断（无响应）** 或 **请求耗时超 120s** 两类。
3. 服务端抓取链（`server_deps`）与 App 主链路（`ffi_deps`）注入面对齐度高：登录头 / 书籍变量 / 源上下文 setup / 限速 / cookie 持久化全部就位，仅 `media_sub_content` sink 一项差异（只影响媒体副内容落库，不影响正文返回）。**「server 缺源上下文注入」候选不成立（已证伪）**。
4. P1-3 净化门控对普通文字书路径无影响：普通在线文字书回退默认开启净化（`book_api.rs:81-96`），有单元与集成双测试钉死。
5. iOS 特有取证要点：Web 服务在 iOS 后台的存活由近静音音频保活维持（`WebKeepAlive.swift`，2026-10-07 方案 C+A）；**保活状态与系统是否掐断音轨直接决定 server 进程是否还响应请求**。用户读 PC 页面时手机若已锁屏/切后台较久，保活失效 → server 挂起 → 出现的正是「HTTP 层无响应」→ 红横幅。这是与现象同型的最优先候选。
6. 未发现可静态确证、且能解释本现象的产品缺陷；发现两项**错误可见性改进**（见 §六），其中 server 端 errorMsg 已带真因（三态测试实证），改进点主要在抓取链错误摘要的粒度与 panic 兜底。

---

## 二、红色横幅的触发条件（原版前端侧，已实证）

### 2.1 文案位置与触发链

文案「后端连接失败，请检查阅读WEB服务或者设置其它可用链接」在两份入口 chunk 各出现一次（python 检索，`index-Cuw80yqS.js` 偏移 15620 起 / `index-toG2697L.js` 偏移 16910 起）：

```js
// axios 响应拦截器（index-Cuw80yqS.js）
xt=[`isSuccess`,`errorMsg`],
Ut = e => {                       // 成功拦截器
  // 校验 e.data 必含 isSuccess/errorMsg（isSuccess=true 还须含 data）
  // 缺失 → ElMessage.warning(`后端返回内容格式错误`) + 抛错
  // 通过 → 连接状态置 `已连接`
},
wt = e => {                       // 失败拦截器（reject 分支）
  e === `cancel` || e === `close`
    ? e
    : ( ElMessage.error({ message: `后端连接失败，请检查阅读WEB服务或者设置其它可用链接`, grouping: !0 }),
        连接状态置 `连接异常`（danger） )
};
V.interceptors.response.use(Ut, wt);
```

**触发条件 = axios 请求 reject**，即以下三种形态之一：

| 形态 | 说明 |
|---|---|
| HTTP 状态非 2xx | axios 默认 `validateStatus` 只放行 2xx |
| 网络层失败 | 连接拒绝 / 连接复位 / DNS 失败（TCP 层无响应） |
| 超时 | axios 实例 `timeout: 120*1000`（120 秒，chunk 内 `se.create({baseURL:…, timeout:120*ze})`，`ze=1e3`） |

**关键区分**：服务端正常返回的 `ReturnData{isSuccess:false, errorMsg:…}` 信封是 HTTP 200，走成功拦截器，**不弹红横幅**；errorMsg 有两个展示位：

- 读书页正文加载失败：`BookChapter-DRyeLtSm.js` 偏移 45199 附近——`getBookContent` 的 `then` 分支里 `o.data.isSuccess` 为假 → `b({message:o.data.errorMsg, type:'error'})` + 章节占位内容直接显示 errorMsg 文本（用户能看到**底层真因**，如「未找到书源」）；
- 拦截器格式校验失败（信封缺字段）→ warning「后端返回内容格式错误」（非红横幅文案）。

### 2.2 原版 Vue 调用 `/getBookContent` 的参数形态

`index-Cuw80yqS.js` 偏移 7418 附近（API 封装层）：

```js
Xe = (e, t) => V.get(`getBookContent?url=` + encodeURIComponent(e) + `&index=` + t)
Ye = (e)      => V.get(`getChapterList?url=` + encodeURIComponent(e))
```

- `url` = 书籍 bookUrl（encodeURIComponent 编码），`index` = 章节序号（裸拼接数字）；**无额外参数**（无登录头/令牌——本批 Vue 产物未带 `x-legado-token` 头逻辑，仅在书源保存类 POST 走签名头）。
- baseURL：`localStorage.getItem('remoteUrl') || location.origin`；读书请求（`getBookContent` 不在签名端点集合 `Be` 内）走普通 GET。
- 读书页先 `getChapterList` 后 `getBookContent`（`BookChapter` 视图按章节序号逐章调用）；**目录失败同样会导致读不了**（目录 HTTP 层失败 → 同款红横幅；目录信封失败 → 页面 errorMsg）。

---

## 三、服务端 `/getBookContent` / `/getChapterList` 失败面逐点排查

### 3.1 路由与响应信封

- 路由注册：`rust/legado-server/src/legacy/mod.rs:117-129`（`/getChapterList` GET、`/getBookContent` GET 等 8 个原版端点）。
- 响应信封：`legacy/mod.rs:45-73` `ReturnData{isSuccess, errorMsg, data}`；`to_response`（:87-96）**HTTP 状态恒 200**，仅 `serde_json::to_vec` 失败回 `{}`（实际不可达）。⇒ **所有 handler 内失败都是 200 信封，不可能直接触发红横幅**。

### 3.2 `/getChapterList`（book_api.rs:156-193）失败返回点

| # | 条件 | errorMsg | 位置 |
|---|---|---|---|
| 1 | `url` 参数为空 | 「参数url不能为空，请指定书籍地址」 | :163-169 |
| 2 | DB 查目录失败 | DB 错误串 | :178 |
| 3 | 空目录回退 `refresh_toc`：书不存在 | 「未在数据库找到对应书籍，请先添加」 | :208 |
| 4 | 网络书 + 书源缺失 | 「未找到对应书源,请换源」 | :220 |
| 5 | 网络抓目录失败（引擎错误） | 引擎错误摘要 | :235-238 |
| 6 | 落库（删旧插新/事务）失败 | 事务错误串 | :268-270 |

### 3.3 `/getBookContent`（book_api.rs:368-475）失败返回点

| # | 条件 | errorMsg | 位置 | 是否可触发红横幅 |
|---|---|---|---|---|
| 1 | `url` 为空 | 「参数url不能为空，请指定书籍地址」 | :377-380 | 否（200 信封） |
| 2 | `index` 非法 | 「参数index不能为空, 请指定目录序号」 | :379-380 | 否 |
| 3 | 书/章节行不存在 | 「未找到」 | :407-409 | 否 |
| 4 | DB 读缓存失败 | DB 错误串 | :412-417 | 否 |
| 5 | 本地书文件解析失败 | IO/解析错误串 | :423-437 | 否 |
| 6 | 书源缺失 | 「未找到书源」 | :440-446 | 否 |
| 7 | `build_engine` 失败 | `LegadoClient init: …` 等 | :447-448 | 否 |
| 8 | **网络抓取失败/超时** | 引擎错误摘要（`e.to_string()`） | :450-453 | **否（200 信封）；但若抓取耗时 > 120s（axios 超时）→ 浏览器侧 abort → 红横幅** |
| 9 | **handler panic**（抓取链/净化链越界等） | 无响应（axum task panic → 连接中断/超时） | 任意 | **是（HTTP 层无响应）** |
| 10 | **进程挂起/死亡**（iOS 后台保活失效等） | 无响应 | 进程级 | **是** |

对齐说明：原版 `BookController.kt:198-246` 同为信封错误（抓取异常回 `e.stackTraceStr` 完整堆栈）；我方回错误摘要（:364-367 登记差异 #2），errorMsg 语义一致但**真因粒度略低**（见 §六改进项）。

### 3.4 书源获取路径核实（任务 2.1）

- handler 书源读取：`get_book_content_inner` 经 `BookSourceRepository::find_by_url(&book.origin)` 查 **AppState DB**（book_api.rs:440-446）；AppState DB 即 ffi `db_state` 全局单池同一 SQLite（`handlers/web_book.rs:22-31` 注释、S28 单池红线）。⇒ **用户 iOS App 内添加的书源对 server 端可见**，书源缺失只在 origin 不匹配（如换源书 origin 指向旧源）或源被删时发生。
- `refresh_toc` 同款读取（book_api.rs:215-221）。

### 3.5 server 抓取链 vs App 主链路差异核实（任务 2.2）

两链共用同一 fetcher 本体 `legado-fetcher::web_book::RealBookSourceFetcher`（`handlers/web_book.rs:9-12` [P5-1 链 b]）。差异仅在宿主注入面：

| 注入项 | App 端 `ffi_deps`（legado-ffi/src/api/web_book.rs:55-89） | server 端 `server_deps`（legado-server/src/handlers/web_book.rs:294-352） | 差异影响 |
|---|---|---|---|
| HTTP client | `http_state::shared_client()`（进程共享） | 每请求 `LegadoClient::with_cookie_persistence` 新建（:295-301，进程级复用留待裁决，:290-293 登记） | 功能等价；连接池开销差异，非失败源 |
| cookie 持久化 | DB（ffi `DbCookiePersistence`） | DB（`ServerCookiePersistence`，同 `cookies` 表，合并 upsert） | 无 |
| 登录头 | `caches` 表 `loginHeader_<url>` | 同键（:309-317） | 无 |
| 书籍变量 | `books.variable` 两路反查 | 同语义两路反查（:318-327） | 无 |
| 源上下文 setup | `source_js_bindings::book_source_js_setup_script` | 共享 `legado_fetcher::source_setup` 同款脚本，宿主数据同键（:328-351） | 无 |
| 限速注册表 | `api::source_rate_limit::registry()` | 进程级独立 static（:142-146，P2 互认已登记） | 窗口分叉，非失败源 |
| 媒体副内容 sink | 有（[V-B1 §2.49]） | **无**（`FetcherDeps::new` 默认 None） | 仅音频/视频书副内容不落库；**文字书正文返回不受影响** |

**结论：server 链路不缺源上下文注入；正文抓取能力与 App 链路对齐（本地测试态2 实证可用）。**

另核实抓取链正文入口 `RealBookSourceFetcher::get_content`（legado-fetcher/src/web_book.rs:1870-2063）：限速 → AnalyzeUrl 解析章节 URL（变量表取章节 variable）→ 抓取 → loginCheckJs → webJs/sourceRegex 钩子 → 规则解析（注入 `setup_script_for` 源上下文 + book 元信息反查）→ 分页 → 副内容/replaceRegex → 空内容检查（`ContentEmpty`）。变量注入方面，App 链路 `fetch_chapter_content_inner`（legado-ffi/src/api/reader.rs:779-856）把 **book.variable ⊕ chapter.variable 合并**后装入 `WebChapter`（reader.rs:830-844）；server legacy 链构造 `WebChapter::new` 时 **variable=None**（book_api.rs:449）。→ 若书源正文规则依赖**书级变量**（`{{token}}` 类），server 链无法展开而 App 链可展开——这是一处真实的差异，但影响面仅限「正文规则/章节 URL 模板使用书级变量」的书源，且失败形态是 200 信封（ContentEmpty/解析失败）而非红横幅。登记为改进候选（见 §六）。

### 3.6 P1-3 净化门控对普通文字书无影响（任务 2.3）

- 门控实现：`use_replace_rule`（book_api.rs:81-96）——`readConfig.useReplaceRule` 非空取该值；否则图片书/epub 本地书默认关；**其余（普通在线文字书）回退 `REPLACE_ENABLE_DEFAULT=true`**。
- 测试钉死：单元 `test_use_replace_rule_gating`（book_api.rs:1000-1057）+ 集成 `test_get_book_content_replace_rule_gated_by_use_replace_rule`（legacy_web_test.rs:643-772，普通文字书净化生效分支）。⇒ 普通文字书路径不受 P1-3 影响，已确证。

### 3.7 iOS 前后台对出站请求的影响（任务 2.4，取证要点）

- Web 服务绑 `0.0.0.0:1122`（legado-ffi/src/api/server_api.rs:135-169），进程内同时承载 **监听 socket**（PC→手机）与 **reqwest 出站请求**（手机→书源）。
- iOS 后台存活机制：`UIBackgroundModes: audio` + 近静音 PCM 循环（flutter_legado/ios/Runner/WebKeepAlive.swift:98-123；Dart 接线 lib/src/services/web_keep_alive_service.dart:106-124——服务启动即 start、停止即 stop、听书播放时让位）。**保活是全进程的：进程不被挂起 ⇒ 监听与出站请求都活着；保活失效（音轨被系统掐断/会话被打断/启动失败回退仅前台）⇒ 进程挂起 ⇒ 监听与出站同时停摆**。
- 因此「PC 能看到书架与目录（说明某时刻服务可达），读正文时却红横幅」的 iOS 特有解释是：**两次请求之间进程被挂起了**。书架/目录页打开在前（服务尚活），读正文点击在后（挂起后）——用户读 PC 页面时手机多半已锁屏/切后台，正是保活机制待实机验证的薄弱点（WebKeepAlive.swift:13-18 注明「待实机验证」「若实机仍被系统掐断」）。
- 反之，若手机全程前台，出站请求不受任何 iOS 挂起影响（前台无网络限制），失败面收敛回书源侧（源站对 server 出站 UA/头/登录态的差异化拒绝）或 120s 超时。
- **区分手段见 §七取证步骤**（横幅出现时立刻在手机上确认 App 是否前台 + Web 服务开关是否仍显示运行）。

### 3.8 本地三态复现测试（任务 2.5）

`rust/legado-server/tests/legacy_web_test.rs` 新增三用例（commit `a5e64666a1`），全部通过（套件 31/31）：

| 用例 | 场景 | 结果 | 与用户现象对照 |
|---|---|---|---|
| `test_survey_content_online_book_source_missing_error_shape` | 在线书 + server DB 无对应书源 | 200 + `isSuccess=false` + errorMsg「未找到书源」 | 非 HTTP 层失败，**不会**触发红横幅；若用户遇到此态，读书页章节位会显示该 errorMsg |
| `test_survey_content_online_book_with_mock_source_succeeds` | 在线书 + 回环 mock 源站（class 规则源） | 200 + 正文成功返回 | server 端抓取链端到端可用 |
| `test_survey_content_local_book_succeeds` | 本地 txt 书（目录解析 + 正文解析） | 200 + 正文成功 | 本地路径可用 |

**判定**：三态均正常 → 服务端三条正文路径的逻辑面在标准环境下无缺陷；用户现象与三态**均不同型**（用户是 HTTP 层失败），失败面收敛到：① iOS 进程挂起（最优先）；② handler panic；③ 抓取耗时 > 120s；④ 书源对 server 出站请求的差异化拒绝（该态 errorMsg 应为抓取失败摘要，可经读书页看到——若用户看到的是红横幅而非 errorMsg，则此候选也排除）。

---

## 四、可静态确证的缺陷排查结论（任务 3.1）

**未发现能解释本现象的产品缺陷。** 排查过并证伪的候选：

1. 「server 缺源上下文注入」——证伪（§3.5 注入面对齐表）；
2. 「书源在 server 端不可见（DB 分池）」——证伪（S28 单池，§3.4）；
3. 「P1-3 门控误伤普通文字书」——证伪（§3.6，测试钉死）；
4. 「legacy 信封形态错误导致前端判失败」——证伪（信封含 isSuccess/errorMsg/data 三键，`test_return_data_success_shape`/`error_shape` 钉死；前端校验的恰是这三键）。

登记的**真实但非本现象根因**的差异（已在代码注释登记，此处汇总）：

| 差异 | 位置 | 影响 |
|---|---|---|
| server 正文链 `WebChapter.variable=None`（不合并 book.variable） | book_api.rs:449 vs reader.rs:830-844 | 书级变量型书源在 Web 端正文失败（200 信封，非红横幅） |
| 抓取失败回错误摘要而非 `stackTraceStr` | book_api.rs:364-367（登记差异 #2） | errorMsg 真因粒度低（见 §六改进） |
| fetcher `get_content` 中 `AnalyzeUrl::parse` 失败 / `fetch_url` 失败等已带类型前缀（`Internal: 章节 URL 解析失败: …`） | legado-fetcher/src/web_book.rs:1886-1897 | 前缀可读，粒度尚可 |

---

## 五、 errorMsg 数据字段与前端展示核对（任务 3.2）

- **前端确实展示 errorMsg**（原版固有）：
  - 读书页正文失败：`b({message:o.data.errorMsg,type:'error'})` + 章节内容位直接显示 errorMsg（BookChapter chunk 偏移 45199 附近，§2.1）；
  - 目录失败同链路（`getChapterList` 的 then 分支，同款 errorMsg 展示）。
- **server 端 errorMsg 已带底层真因**：三态测试实证「未找到书源」；抓取链错误经 `e.to_string()` 带 `LegadoError` 类型前缀（`Network error: …` / `Timeout: …` / `Content empty: 章节 … 正文为空` 等，legado-core/src/error.rs:7-47），不是笼统失败。
- 改进空间（非必需，交主代理裁决）：
  1. **server 正文链补 book.variable 合并**（对齐 reader.rs 两级级联；最小改法：`get_book_content_inner` 在构造 `WebChapter` 前读 `book.variable` 与 `chapter.variable` 合并，可复用 `legado_fetcher::web_book::merge_variables_json`）；
  2. 原版对齐项：抓取异常回 `stackTraceStr` 完整堆栈（现回摘要）——恢复需引擎错误透出堆栈串，改动面大，建议先经 §七取证确认真因类别再定。

---

## 六、需实机取证清单（任务 3.3，按定位效率排序）

1. **【一轮定位，最关键】PC 浏览器 F12 → Network，复现红横幅，找到标红的 `/getBookContent`（或 `/getChapterList`）请求，记录：**
   - `(failed)` 还是超时还是具体状态码；`errorMsg` 字段内容（若 HTTP 200）；
   - 请求耗时（是否贴近 120s）。
   - 判读：`(failed)/超时` → 进程挂起或 panic（转第 2 步）；HTTP 200 + errorMsg → 书源侧真因直接可读。
2. **红横幅出现的同时，看手机**：App 是否在前台？若锁屏/后台，立即亮屏回前台再点一次读正文——若恢复，坐实「iOS 后台挂起/保活失效」（与 WebKeepAlive「待实机验证」口径闭环）；若前台依旧失败，转第 1 步的 errorMsg 分类。
3. （可选）PC `curl -m 5 http://<iPhoneIP>:1122/getBookshelf` 在失败窗口执行：无响应 = 进程级问题；有响应但正文失败 = 书源/链路问题。

---

## 七、报告边界

- 本机静态分析 + 回环测试，未操作 iOS 设备；iOS 后台挂起/保活实效判定留待 §六取证。
- 前端 chunk 为压缩产物，行号为 python 字符串偏移（非源码行号）；双份 chunk（`index-Cuw80yqS.js` / `index-toG2697L.js`、`BookChapter-DRyeLtSm.js` / `BookChapter-CGy3A3Zd.js`）为同构双构建，触发逻辑一致。

— 调研员 ｜ 2026-10-07
