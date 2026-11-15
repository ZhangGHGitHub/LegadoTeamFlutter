# REPORT — P2-2 双 Cookie 罐 + 仅最终响应写回：现状核实与修复方案

> 任务来源：`docs/audit_20261113/REPORT_引擎链.md` §2.4 P2-2。
> 调研性质：**只读**。本轮未修改任何代码、未执行 `cargo test`/构建。
> 代码基准：工作区 `HEAD = daae6a2447`（`rust/legado-net/src/client.rs` 无未提交改动）。
> 依赖基准：`reqwest 0.12.28`（`rust/Cargo.lock:3196-3198`）、`tower-http 0.6.11`（`Cargo.lock:4205-4207`）、`http 1.4.2`（`Cargo.lock:1484-1486`）。
> 行号说明：审查报告中的 `client.rs:1077 / :1130 / :1544-1556` 与当前文件有约 40-60 行漂移；本报告全部按当前工作区逐行核实后的行号引用（对应实际位置 `:1134 / :1187 / :1619-1623`），下文不再重复标注漂移。

---

## 〇、结论摘要

1. **问题全部成立，且比“双罐”更严重：实际是 3 份进程内内存态**——reqwest 内置 Jar（罐 A）、`legado-net` 的 App `CookieStore`（罐 B）、`legado-js` 的 `GLOBAL_COOKIES`（罐 C）。正常网络运行期三者互不同步；DB `cookies` 表是主要桥，且只在启动时自动回填（`legado-js` 回填路径见 `rust/legado-js/src/host_api/cookie_store.rs:95`；备份恢复/清除是显式管理入口，见 §2.5）。
2. **重定向是 reqwest 自动跟随**，策略在 `client.rs:248-252`（`Policy::limited(20)` / `Policy::none()`），`followRedirects=false` 由 `no_redirect_variant()` 派生客户端实现（`client.rs:1029-1045`，调用点 `rust/legado-fetcher/src/analyze_request.rs:216-230`）。**“自定义 `redirect::Policy` 捕获 Set-Cookie”不可行**：Policy 回调只拿到 status/Location/previous，拿不到响应头（`reqwest-0.12.28/src/redirect.rs:120-147,296-338`）。
3. **`save_cookies_from_response` 确实只对最终响应调用**：唯一 3 个调用点是 `client.rs:990`（`send_stream`）、`:1134`（`collect_response`）、`:1187`（`collect_raw_response`），全部在 reqwest 内部消化完重定向之后。逐跳 `Set-Cookie` 只进罐 A。
4. **reqwest 的 CookieService 本身是逐跳工作的**：服务栈为 `FollowRedirect<CookieService<Retry<Hyper>>>`（`reqwest-0.12.28/src/async_impl/client.rs:1023-1026`），因此罐 A 对**每一跳**都执行注入与写入（`cookie.rs:237-247` 注入；`:280-291` 写入）。这解释了“为什么登录有时又能成”：罐 A 在偷偷替我们维持会话，只是 App/DB/JS 完全看不见。
5. **显式 `Cookie` 头会完全屏蔽罐 A**：`apply_headers_and_cookies` 在 App 罐或规则 Cookie 非空时设置显式头（`client.rs:1611-1623`），reqwest 仅在请求**没有** `Cookie` 头时才从 jar 注入（`cookie.rs:239-245`）。同站重定向时 tower-http 逐跳克隆上一跳请求头（`tower-http-0.6.11/src/follow_redirect/mod.rs:211-229`），显式头会一直保留；跨站才删除（`reqwest-0.12.28/src/redirect.rs:239-249`）。
6. **附加确认（审查未列，但同属 P2-2 面）**：① 最终响应上的**多个 `Set-Cookie` 会被折叠成一个**——`collect_response` 用 `HashMap<String,String>` 收头（`client.rs:1125-1128`），`LegadoResponse.headers` 文档明确“每个头取最后一个值”（`rust/legado-net/src/response.rs:13,47`），而 `http::HeaderMap::iter()` 对同名多值逐条产出（`http-1.4.2/src/header/map.rs:2323-2353`），`insert` 后者覆盖前者；② **即使是最终响应，HTTP Set-Cookie 在同一进程内也进不了 `java.getCookie`**（HTTP 写回不写罐 C；罐 C 只接受 JS `setCookie`、WebView 回流和启动回填，见 §2.5），所以“302 才不可见”的表述偏窄。
7. **上游（Kotlin）是单罐 + 逐跳**：`HttpHelper.kt:83-98` 用 `addNetworkInterceptor`（OkHttp 对每一跳网络请求都调用），`CookieManager.saveResponse` 逐跳写库/内存（`CookieManager.kt:29-50`），`loadRequest` 逐跳把 store 合并进请求头（`:55-75`）；OkHttp 内置 `.cookieJar(...)` 在 `HttpHelper.kt:62` 是**注释掉**的。也就是说，罐 A 是我方实现引入的“第二套状态”，上游没有。
8. **方案结论**：C（最小改动）不闭环，只能缓解跨请求遮蔽；A（手动逐跳）能闭环但要把重定向语义搬进我方代码，且 `enabledCookieJar` 默认 `Some(true)`（`rust/legado-core/src/models/book_source.rs:71-85` 的 `default_true_opt`，上游 `BookSource.kt:57` 默认 true）意味着受影响的不是少数源；**推荐 B2：关闭 reqwest 内置 jar，改用 `cookie_provider` 注入 App 罐适配器 + 请求级 Cookie 上下文（逐跳由 reqwest CookieService 自动完成）**，辅以“多 Set-Cookie 全量捕获”和“HTTP→JS 罐写穿”两项必做配套；A 作为 B2 受阻时的备选（仅门控请求手动跟随）。

---

## 一、存储拓扑：不是“双罐”，是“三内存态 + 一 DB”

```
                         ┌─────────────────────────────────────────────┐
 请求头构造              │ apply_headers_and_cookies (client.rs:1562)  │
 (书源 header / JS       │  - rule_cookie = 请求头里的 Cookie          │
  setCookie / loginHeader)│  - db_cookie = App CookieStore.get_cookie   │
                         │  - merged = merge(db, rule)（规则优先）     │
                         └──────────────────┬──────────────────────────┘
                                            │ 有 merged → 显式 Cookie 头
                                            ▼
                         ┌─────────────────────────────────────────────┐
 reqwest 发送栈          │ FollowRedirect (Policy::limited(20))        │
 (逐跳)                  │   → CookieService                           │
                         │       - 仅当请求无 Cookie 头 → 从罐 A 注入  │
                         │       - 每跳响应 Set-Cookie → 写罐 A        │
                         └──────────────────┬──────────────────────────┘
                                            │ 最终响应（罐 A 的中间跳已丢失）
                                            ▼
                         ┌─────────────────────────────────────────────┐
 写回（仅最终响应）      │ collect_response / collect_raw_response /   │
                         │ send_stream → save_cookies_from_response    │
                         │   → 罐 B (legado-net CookieStore)           │
                         │   → CookiePersistence.save → DB cookies 表  │
                         └──────────────────┬──────────────────────────┘
                                            │ 仅启动时
                                            ▼
                         ┌─────────────────────────────────────────────┐
 JS 读侧                 │ 罐 C (legado-js GLOBAL_COOKIES)             │
                         │   ← backfill_from_sink()（启动一次）        │
                         │ java.getCookie / merge_js_cookies 只读罐 C  │
                         └─────────────────────────────────────────────┘

 运行期：罐 A ↔ 罐 B ↔ 罐 C 均无同步；DB 只在启动回填（罐 B 构建预载 / 罐 C backfill）。
```

- **罐 A**：reqwest `cookie_store(true)` 内部 `Jar`（`client.rs:232`）。每个 `reqwest::Client` 一份；`with_proxy`/`no_redirect_variant` 重建客户端时会各自再建一份（`client.rs:1000-1008,1029-1045`），所以严格说还有 A′、A″。
- **罐 B**：`LegadoClient.cookie_store`（`client.rs:155` 字段、`:382` 访问器），进程级共享实例（FFI 主客户端 + JS 四池共用，`rust/legado-ffi/src/http_state.rs:365-366,422-426`、`rust/legado-js/src/host_api/network.rs:273-280`）。
- **罐 C**：`legado-js` 的 `GLOBAL_COOKIES`（`rust/legado-js/src/host_api/cookie_store.rs:23-25`），也就是 `java.getCookie` 读的那一份。
- **DB**：`cookies` 表；两个写方共用一行并按 key 并集合并（`http_state.rs:94-110`）。

---

## 二、逐条现状核实

### 2.1 重定向：自动跟随，20 跳，开关在派生客户端

| 事实 | 证据 |
|---|---|
| 默认跟随重定向 | `LegadoClientConfig.follow_redirects: bool`（`client.rs:99`），`Default` 为 `true`（`client.rs:130`） |
| 跟随上限 20 跳 | `client.rs:242-252`：`Policy::limited(20)`；`Policy::none()` 用于关闭 |
| 20 跳语义 | reqwest `PolicyKind::Limit`：`attempt.previous.len() > max` 才报 `TooManyRedirects`（`reqwest-0.12.28/src/redirect.rs:131-145`），`previous` 含初始 URL → 最多跟随 20 跳；仓库已有 20/21 跳回归（`client.rs:2723-2791`） |
| 书源 `followRedirects=false` | `analyze_request.rs:216-230` 选择 `client.no_redirect_variant()`；派生客户端复用同一 `CookieStore`/持久化后端（`client.rs:1029-1045`） |
| reqwest 内部逐跳 | 服务栈 `CookieService::new(...)` 后 `FollowRedirect::with_policy(...)`（`reqwest-0.12.28/src/async_impl/client.rs:1023-1026`）——CookieService 在 FollowRedirect **内层**，每跳都过 |
| 逐跳注入条件 | `if req.headers().get(COOKIE).is_none() { add_cookie_header(...) }`（`reqwest-0.12.28/src/cookie.rs:237-247`） |
| 逐跳写入 | `ResponseFuture::poll` 对每个 response 调 `extract_response_cookie_headers` + `cookie_store.set_cookies`（`reqwest-0.12.28/src/cookie.rs:280-291`） |
| 同站重定向保留显式头 | `FollowRedirect::call` 克隆原始 `req.headers()` 为每跳模板（`tower-http-0.6.11/src/follow_redirect/mod.rs:211-229`）；`on_request` 只在**跨 host/port** 时删 `AUTHORIZATION/COOKIE/...`（`reqwest-0.12.28/src/redirect.rs:239-249`） |

**结论**：重定向跟随本身没有问题；“逐跳捕获”在 reqwest 内部已经发生，只是被写进了罐 A，且最终响应不携带中间跳头。

### 2.2 `save_cookies_from_response` 的调用点只有最终响应

`save_cookies_from_response` 定义在 `client.rs:1230-1300`。全仓（除测试）调用点仅 3 处：

| 调用点 | 所在路径 | 响应形态 |
|---|---|---|
| `client.rs:989-990` | `send_stream` | 最终响应（流式；此时 body 未读，先写头） |
| `client.rs:1133-1134` | `collect_response` | 最终响应（`get`/`post`/`head`/`post_multipart`/`get_bytes` 等经 `execute_with_retry_and_limit` 汇入） |
| `client.rs:1186-1187` | `collect_raw_response` | 最终响应（`get_raw`/`post_raw`） |

- `collect_response` / `collect_raw_response` 拿到的 `response` 是 reqwest 完成重定向后的最终响应：`response.url()` 已是最终 URL（`client.rs:1121,1174`），中间 302/301 的响应对象不可达。
- 没有任何 middleware / redirect 回调 / 响应拦截器参与 cookie 写回；`save_cookies_from_response` 是唯一 HTTP 写回入口。
- `get_bytes_capped` 复用 `send_stream`（`client.rs:505`），因此也走最终响应。
- `post_multipart` 走 `execute_with_retry_and_limit` → `collect_response`（`client.rs:793-795`），同样最终响应。

**额外缺陷（多值折叠）**：`collect_response` 把响应头收进 `HashMap<String,String>`（`client.rs:1125-1128`），`collect_raw_response` 同理（`:1178-1181`）。`LegadoResponse.headers` 的文档写明“每个头取最后一个值”（`response.rs:13`；`LegadoRawResponse` 同 `:47`）。`http::HeaderMap::iter()` 对同名多值逐条产出（`http-1.4.2/src/header/map.rs:2323-2353`），`HashMap::insert` 逐条覆盖，因此**同一个响应上的多条 `Set-Cookie` 只有最后一条能进入 `save_cookies_from_response`**。这条与重定向无关，普通 200 登录响应也会中招。

### 2.3 显式 `Cookie` 头如何完全屏蔽罐 A

`apply_headers_and_cookies`（`client.rs:1562-1624`）的执行顺序：

1. 从调用方 headers 里取 `Cookie`（大小写不敏感）为 `rule_cookie`（`:1569-1577`）；
2. 应用其余自定义头，**跳过 `Cookie` 与内部 `CookieJar` 标记**（`:1582-1602`）；
3. 读罐 B：`cookie_store.read().get_cookie_string(url)`（`:1611-1615`）；
4. `merge_cookie_headers(db_cookie, rule_cookie)`（`:1618`，规则优先，P1-2 语义）；
5. 非空则 `req.header("Cookie", merged)`（`:1619-1623`）。

reqwest 侧：`CookieService::call` 只在 `req.headers().get(COOKIE).is_none()` 时注入（`reqwest-0.12.28/src/cookie.rs:239-245`）。因此：

- **罐 B 对该域有任意一条 cookie** → 显式头非空 → 罐 A 的注入被完全跳过（不是“同名覆盖”，是整条不注入）。
- **书源/JS/登录头里带任意 `Cookie`** → 同样屏蔽罐 A。
- 同站 302 的下一跳克隆同一份显式头（tower-http，见 2.1 表），所以罐 A 在上一跳刚收到的 `SESSION=NEW` 不会出现在下一跳；跨站才会删头并让罐 A 注入（但此时注入的是新 host 的罐 A 状态）。
- 这直接产生“登录死循环”：302 下了新会话 → 下一跳仍带旧会话 → 服务器再次 302。

**具体复现序列（与审查结论一致，已按代码推演）**：

```
罐 B: sid=OLD; theme=dark                      （任意一条即可）
请求 1: Cookie: sid=OLD; theme=dark            （显式头）
响应 1: 302 Set-Cookie: sid=NEW; Location: /home
        → 罐 A 只有 sid=NEW；罐 B/DB/JS 均无 NEW（save 只在最终响应）
请求 2: Cookie: sid=OLD; theme=dark            （显式头被 tower-http 克隆；CookieService 不注入）
响应 2: 302 Set-Cookie: sid=NEW2 ...           （服务器认为未登录）
```

### 2.4 罐 B（App `CookieStore`）的读写路径

| 路径 | 位置 |
|---|---|
| 写：HTTP 最终响应 | `save_cookies_from_response`（`client.rs:1230`）→ `CookieStore::set_cookie`（`rust/legado-net/src/cookie_store.rs:239-250`，同域同名替换）→ `domain_cookie_string`（`:306-315`）→ `persistence.save`（`client.rs:1295-1299`） |
| 写：DB 实现 | `DbCookiePersistence::save`（`http_state.rs:229-243`）→ `persist_cookie_row_merged`（`:94-110`，读旧行、按键并集、同名新值胜、upsert） |
| 读：请求注入 | `CookieStore::get_cookie_string(url)`（`cookie_store.rs:296-304`）→ `cookie_domain_key` ETLD+1（`:603-608`）→ `apply_headers_and_cookies`（`client.rs:1611-1615`） |
| 读：启动预载 | 新建 store：`store.load_persisted(load_all())`（`client.rs:339-348`）；共享 store：按域合并预载（`:315-337`，内存值同名胜） |
| 写侧门控 | 请求头存在 `CookieJar` 键才写（`client.rs:67-76,1109-1112`；标记在 `:1588-1592` 发送前剥离） |
| 标记注入点 | 书源：`web_book.rs:889-908`（`Some(true)` 才补，只补不覆盖）；搜索：`search.rs:1290`；RSS：`rss/request.rs:145`；JS 桥：`network.rs:314-338`（按当前书源开关查询，`:304-311`） |
| 门控默认值 | `BookSource.enabled_cookie_jar` 缺键 → `Some(true)`（`book_source.rs:71-85` + `:230-232` `default_true_opt`）；显式 null → `None` → 运行时按关（`web_book.rs:905-907` 的 `enabled != Some(true)`）。**因此默认书源会走门控写回** |

补充：`CookieStore::get_cookie_string` 只按域名键取，**不按 Path/Secure 过滤**；`set_cookie` 同域同名直接替换（忽略 Path）。这是既有语义，不是本缺陷引入，但会影响“逐跳捕获后新增 cookie”的行为（见 §6 风险）。

### 2.5 罐 C（`legado-js`）的读写路径与 `java.getCookie`

| 路径 | 位置 |
|---|---|
| `java.getCookie(url[,key])` 绑定 | `rust/legado-js/src/host_api/quickjs_impl.rs:2996-3010` → `cookie_store::get_cookie` / `get_cookie_by_key` |
| 读实现 | `cookie_store.rs:440-451`，只查 `GLOBAL_COOKIES`（按 URL 归一域名键 + 历史原始串键，`:418-438`） |
| 写实现 | JS `setCookie` → `set_cookie`（`:491-502`）/ `set_cookie_str`（`:507-533`）→ `with_store_update`（`:464-486`，域锁 D + 内存锁 G，锁外 sink upsert） |
| 持久化 | `CookieSink`（`:31-53`）由 FFI 注册 `JsCookieDbSink`（`http_state.rs:281-341`）→ 同一 `persist_cookie_row_merged` |
| 请求注入（JS 侧） | `cookies_for_url`（`:696-706`）+ `merge_js_cookies`（`:736-786`）；调用点：`web_book.rs:1158`（fetch_page）、`:1282`（fetch_simple_cached）、`:1330`（toc 分页）、`:3245`；`network.rs:711`（java.ajax/get/post/head/connect）；`explore_api.rs:536`；`audio_cache_api.rs:933` |
| 启动回填 | `backfill_from_sink`（`:95-...`）由 `register_js_cookie_sink`（`http_state.rs:343-351`）在 `db_open` 调用一次 |
| 运行期同步 | **无**。`persist_cookie_row_merged` 只写 DB（`http_state.rs:94-110`），不回写罐 C；罐 B 的 HTTP 写回也不会更新罐 C |

**结论**：`java.getCookie` 读的是罐 C，不是罐 B，也不是罐 A。正常网络运行期，罐 C 与罐 B 之间**没有自动同步**；唯一自动路径是“启动时从 DB 回填”，另有两个显式管理入口会同时碰两罐（备份恢复 `backup_api.rs:2092-2191` 的 `overwrite_shared_cookie_rows` + `overwrite_cookies`；清除入口 `net_api.rs:107-159`）。HTTP 写回路径（罐 B/DB）不会更新罐 C。因此：

- 302 的 `Set-Cookie` 不进罐 C（审查结论成立）；
- **最终 200 响应的 `Set-Cookie` 也只进罐 B/DB，同样进不了罐 C 的进程内视图**（要等下次重启 backfill）。这会让“登录成功后立刻在 JS 里 `getCookie` 取 token”的源失败，属于比审查描述更宽的同源问题。

### 2.6 上游 Kotlin 对照（决定修复目标形态）

| 事实 | 证据 |
|---|---|
| 上游无 OkHttp 内置 CookieJar | `HttpHelper.kt:62` `.cookieJar(cookieJar = cookieJar)` 被注释；`cookieJar` 对象（`:28-48`）只写一个内存 `_cookieJar` 键，当前主链未消费 |
| 上游逐跳捕获 | `HttpHelper.kt:83-98` `addNetworkInterceptor`；OkHttp 对每个 follow-up 网络请求都调用 network interceptor |
| 上游逐跳写 | `CookieManager.saveResponse`（`CookieManager.kt:29-50`）：持久 cookie → `CookieStore.replaceCookie`（DB），会话 cookie → 内存 `_session_cookie` |
| 上游逐跳读 | `CookieManager.loadRequest`（`:55-75`）：`mergeCookies(requestCookie, CookieStore.getCookie(domain))`，**store 在后 → 同名 store 值胜** |
| 上游单罐读 | `CookieStore.getCookie`（`CookieStore.kt:54-70`）= DB/内存 `_cookie` + 会话 `_session_cookie` 按键合并 |
| 上游首次请求的规则优先 | `AnalyzeUrl.setCookie`（`AnalyzeUrl.kt:608-629`）：`mergeCookies(storeCookie, headerMap["Cookie"])`，header（urlOption/规则）在后 → 规则胜；随后补 `CookieJar` 标记 |
| 上游门控默认 | `BookSource.kt:57` `enabledCookieJar: Boolean? = true`（DB 列默认 0，见 `:56`，但 Kotlin 构造默认 true） |

**修复目标**：单罐 + 每跳“先读后写”，与上游网络拦截器语义一致。唯一需要保留的我方差异是 P1-2 的“规则/书源 Cookie 优先”（上游 `loadRequest` 的第二段 merge 实际会让 store 反超，但 `AnalyzeUrl.setCookie` 的注释与用户预期是规则优先；本仓已有 P1-2 回归测试，见 `client.rs:2247-2360`，修复不应推翻它）。

---

## 三、后果复核（在审查三条之外补两条）

| # | 后果 | 判定 | 证据 |
|---|---|---|---|
| ① | 登录 302 的 `Set-Cookie` 只进罐 A，不进罐 B/DB/罐 C | **成立** | §2.2 调用点 + §2.5 运行期无同步 |
| ② | 罐 B 对该域已有任意 cookie 时，显式头完全屏蔽罐 A；同名旧值压制新值 | **成立** | §2.3；reqwest 注入条件 `cookie.rs:239-245`；同站跳克隆显式头 `follow_redirect_mod.rs:211-229` |
| ③ | 重启后 3xx cookie 丢失 | **成立** | 3xx 从未进罐 B/DB（仅罐 A 内存），进程退出即丢 |
| ④ | **最终响应的多条 `Set-Cookie` 折叠，只保留最后一条** | **成立（新增）** | `client.rs:1125-1128,1178-1181`；`response.rs:13,47`；`http-1.4.2/src/header/map.rs:2323-2353` |
| ⑤ | **最终响应的 cookie 也进不了 `java.getCookie`（同进程）** | **成立（新增/扩大）** | §2.5；罐 C 只有启动 backfill |

另外两个边际事实：

- 罐 A 的存在会让部分场景“看起来正常”（无显式头时罐 A 注入），所以问题表现为**间歇性**：书源换一个、或罐 B 多了一条无关 cookie，行为就翻转。
- 罐 A 不按 `CookieStore` 的域名键做持久化，重启必丢；但它也不会写入 DB，所以不会污染持久层。

---

## 四、方案对比

> 风险排序：C（最低，但不闭环）＜ B2（中，改 cookie 层、不动重定向引擎）＜ A（中高，重写重定向语义且默认门控覆盖大多数书源）。

### 4.1 方案 C（最小改动）：保留双罐，注入前合并罐 A 的读视图

**思路**：把 `cookie_store(true)` 换成 `cookie_provider(Arc<reqwest::cookie::Jar>)`，在 `LegadoClient` 里持有这个 `Arc<Jar>`；在 `apply_headers_and_cookies` 拼显式头之前，用 `jar.cookies(&Url)` 读出该 URL 的罐 A 值，和罐 B/规则 cookie 按键合并。

**改动点**：

| 文件:行号 | 改动 |
|---|---|
| `client.rs:228-232` | `let jar = Arc::new(reqwest::cookie::Jar::default()); builder.cookie_provider(jar.clone())`；`LegadoClient` 增加 `cookie_jar: Arc<Jar>` 字段（`client.rs:155-165`，`:351-363` 构造） |
| `client.rs:1611-1623` | 在 `db_cookie` 之后追加 `jar.cookies(&Url::parse(url)?)` 的解析与合并 |
| `client.rs:1000-1045` | `with_proxy`/`no_redirect_variant` 重建时复用同一 `Arc<Jar>`（否则派生客户端又开新罐） |
| `Cargo.toml` | 无需新增（`reqwest` 已开 `cookies`） |

**可行性关键点（已核实）**：

- `reqwest::cookie::Jar` 是公开类型，`add_cookie_str` 与 `CookieStore::cookies(url)` 可用（`reqwest-0.12.28/src/cookie.rs:28,157,174-186`）。
- 但 **`reqwest::Client` 没有读取内部 jar 的公开 API**；用 `cookie_store(true)` 时拿不到句柄，必须改成 `cookie_provider(Arc<Jar>)` 才能读。仓库当前没有任何 `cookie_provider` 使用（`rg` 仅命中 reqwest 源码）。
- `Jar` 没有“遍历全部 cookie”的 API（公开方法只有 `add_cookie_str` + trait 的 `cookies(url)`，见 `cookie.rs:45-157`），因此**无法把罐 A 的内容导出到罐 B/DB/罐 C**。

**结论**：C 只能修“跨请求的同名遮蔽”（下一次请求前把罐 A 合并进显式头），**不能修**：
- 302→302 同一条链内的下一跳（显式头在请求发出前就固定了，罐 A 的新值在链内产生）；
- DB 持久化 / 重启保持；
- `java.getCookie` 可见性。

**判定：不闭环，不建议作为 P2-2 的正式修复**。只有在“本批必须 0 风险、且只求缓解”时才考虑，并需在审查报告登记“3xx 仍不可见”。

### 4.2 方案 A（逐跳捕获，仅门控请求）：手动跟随 + 每跳写回/重拼

**思路**：只在 `save_cookies == true && config.follow_redirects == true` 时，绕过 reqwest 自动跟随：用关闭重定向的派生客户端逐跳发送；每收到 3xx，先把该跳 `Set-Cookie` 全量写入罐 B（+DB），再根据 `Location` 重拼下一跳请求（Cookie 头按“罐 B 最新值 + 尚未被本次链覆盖的显式键”重建），直到非 3xx 或 20 跳。

**为什么不能只写自定义 `redirect::Policy`**：Policy 回调签名是 `redirect(Attempt { status, next, previous })`（`reqwest-0.12.28/src/redirect.rs:120-147,296-338`），**不提供响应头**，拿不到 `Set-Cookie`；必须手动跟随（或改 reqwest 源码，不可取）。

**改动点**：

| 文件:行号 | 改动 | 预估 |
|---|---|---|
| `client.rs:228-252` | 新增内部配置 `reqwest_cookie_store: bool`（默认 true）；`cookie_capture_variant()` 构建 `follow_redirects=false` + `reqwest_cookie_store=false` 的派生客户端，实例级 `OnceLock` 缓存（仿 `no_redirect_variant`，`client.rs:1029-1045`） | +25 |
| `client.rs:1230-1300` | 抽出 `save_cookie_values(url, values: impl Iterator<Item=&str>)`：解析多条 `Set-Cookie`、写罐 B、按域持久化；旧 `save_cookies_from_response(HashMap)` 改为收集后调用它 | +40/-10 |
| `client.rs` 新增 | `async fn send_following_redirects(&self, spec: RequestSpec, save_cookies: bool) -> Result<reqwest::Response, reqwest::Error>`：维护 `hop=0..20`、`deadline = Instant::now() + effective_timeout`、`extra_cookie: HashMap<String,String>`（初始 = 调用方 Cookie 头解析）、`captured_names: HashSet<String>` | +180-220 |
| `client.rs:427-470,538-600,605-670,673-728,729-797,798-837,838-903,904-993` | 8 个请求工厂在 `save_cookies && self.config.follow_redirects` 时改走 `send_following_redirects`；否则保持 `req.send().await` | +80（8×10） |
| `analyze_request.rs:216-230` | `followRedirects=false` 走 `no_redirect_variant()` 后 `config.follow_redirects=false`，自然不进手动分支；无需改 | 0 |
| 测试 | `client.rs` 测试模块新增回环用例（见 §7） | +250 |

**手动跟随必须复刻的语义（逐条对照 reqwest 现有实现，避免回归）**：

1. **状态码/方法**：301/302 + POST → GET 且丢弃 body；303 → GET（HEAD 保持 HEAD）；307/308 → 保持方法与 body（`tower-http-0.6.11/src/follow_redirect/mod.rs:258-307` 的方法切换逻辑）；301/302/303 还要删除 `Content-Type`/`Content-Length`/`Content-Encoding`/`Transfer-Encoding`（同文件 `drop_payload_headers`，`:262-269`）。body 我方都是 `String`/`Bytes`（`post_multipart` 是 `bytes::Bytes`），可 clone 重放。
2. **Location 解析**：`Url::parse(current).join(location)`；缺失/非法 Location → 不跟随，原样返回（reqwest 行为）。
3. **20 跳上限**：等价 `previous.len() > 20` → 报 `TooManyRedirects`（可复用 `reqwest::Error` 不可构造，映射为 `LegadoError::Network("too many redirects")`）。
4. **跨 host/port 敏感头**：删除 `Authorization`、`Cookie`、`Cookie2`、`Proxy-Authorization`、`WWW-Authenticate`（`reqwest-0.12.28/src/redirect.rs:239-249`）；同时清空 `extra_cookie`（规则/登录 Cookie 不得跨站）。
5. **总超时**：现有 `config.read_timeout` 是客户端级总超时（`client.rs:230`，审查 §3.3 已登记）；手动循环必须用 `deadline` + 每跳 `.timeout(remaining)`，否则 20 跳 × 60s。剩余 ≤0 → `LegadoError::Timeout`。
6. **限流/重试**：循环放在 `factory` 内（`execute_with_retry_and_limit` 的 `factory`，`client.rs:1054-1082`），限流 permit 仍在整条逻辑请求外（`client.rs:1067-1074`），重试仍按“一次逻辑请求”重放整条链；不要在每个跳内重试。
7. **HTTP 日志/最终 URL**：只对最终响应 `finish_success`（现状一致）；`resp.url` 是最终 URL。
8. **中间响应 body**：直接 drop，不读取（避免大 body）；连接可能不复用，可接受。
9. **`CookieJar` 标记**：每跳 headers 重建时由 `apply_headers_and_cookies` 继续剥离（`client.rs:1588-1592`）。

**每跳 Cookie 重建算法（关键）**：

```
let mut extra = parse_cookie_header(inbound_cookie);   // 规则/JS/登录头
for hop in 0..=20 {
    let store_cookie = cookie_store.read().get_cookie_string(&current_url);
    let cookie_header = merge_cookie_headers(store_cookie, serialize(extra)); // 规则优先
    send with cookie_header
    if !is_redirect(status) { return response }
    let set_cookies = response.headers().get_all(SET_COOKIE); // 全量，不折叠
    save_cookie_values(current_url, set_cookies);
    for name in parsed names { extra.remove(name); }       // 本次链捕获的名字让罐 B 新值接管
    (method, body) = rewrite_for_redirect(status, method, body)
    if cross_host { extra.clear(); strip_sensitive_headers(&mut headers); }
    current_url = join(current_url, location)
}
```

**LOC 预估**：生产代码约 300-350 行（含 8 个方法接线），测试约 250 行；总 550-600 行。

**风险**：
- **中高**。重定向语义（方法改写、body 重放、跨站、相对 Location、超时）从 reqwest 内部搬到 `legado-net`，任何一处不一致都是全链路回归；而 `enabledCookieJar` 默认 true，意味着**大多数书源请求会走这条新路径**，不是“少数源”。
- 多一个派生客户端（第二连接池），门控请求的 keep-alive 复用略降。
- 中间跳日志不可见（与现状一致，但排障时需知道）。
- 超时/重试组合需要专门测试，否则可能出现 20×60s。

**可测性**：高。全部可在 `legado-net` 的本地回环服务器内确定性验证（现有 `spawn_set_cookie_recorder` / 20 跳夹具可复用，`client.rs:2861-3180`）。

### 4.3 方案 B（收敛为单罐）：关闭 jar A，App 罐成为唯一 cookie 源

#### B1（任务描述中的形态）：关闭 `cookie_store`，所有请求手动跟随

- 与 A 相同的逐跳循环，但**所有请求**（不只门控）都走；注入无条件、写侧仍按 `CookieJar` 标记门控。
- 改动面比 A 更大（所有请求都受影响），且 `follow_redirects=false` 的 302 语义、JS `connectNR` 拦截、HTTP 日志都要重新对齐。
- **不推荐**：收益与 A 相同（单罐），但风险面从“门控请求”扩大到“全部请求”。

#### B2（本报告推荐的实现形态）：`cookie_provider` 适配器，不手动跟随

**关键洞察（已逐行核实）**：reqwest 的 `CookieService` 位于 `FollowRedirect` **内层**（`reqwest-0.12.28/src/async_impl/client.rs:1023-1026`），所以只要用 `ClientBuilder::cookie_provider(Arc<C>)` 把罐 B 适配成 `reqwest::cookie::CookieStore`，reqwest 就会：

- 对**每一跳**调用 `C::cookies(url)` 取 Cookie（仅当请求没有显式 `Cookie` 头，`cookie.rs:237-247`）；
- 对**每一跳**响应调用 `C::set_cookies(headers, url)`（`cookie.rs:280-291`）。

于是**不需要手动跟随**，重定向/方法/超时/重试/限流全部保持 reqwest 原语义，同时得到逐跳写入罐 B。这是“单罐”目标的最低风险实现。

**需要解决的两个语义问题**：

1. **写侧门控是 per-request，而 provider 是 client 级**。`set_cookies` 只拿到 `(headers, url)`，拿不到请求的 `CookieJar` 标记。解决：用 `tokio::task_local!` 保存“本次逻辑请求上下文”（`save: bool` + 规则 Cookie overlay），`set_cookies` 在上下文中 `save=false` 时直接返回；所有 `LegadoClient` 发送点用 `with_cookie_context(ctx, async { req.send().await })` 包裹。这样门控语义不变，且不需要第二套客户端/连接池。
2. **显式 `Cookie` 头会跳过 provider 注入**。解决：**不再由 `apply_headers_and_cookies` 拼显式 Cookie 头**；把调用方带来的 `Cookie`（书源 header / JS `merge_js_cookies` / loginHeader）解析成请求级 `overlay`，由 provider 的 `cookies(url)` 做“罐 B 值 + overlay”按键合并（overlay 优先，保持 P1-2 的规则优先语义）。同时记录“本次链中已被响应更新过的 cookie 名”，这些名字在后续跳让罐 B 新值覆盖 overlay 里的旧值：

```
cookies(url):
  base = store.domain_cookie_string(domain(url))
  if ctx.overlay.domain != domain(url): return base
  map = parse(base)
  updated = ctx.updated_names[domain(url)]   // set_cookies 每跳按域记录
  for (k,v) in ctx.overlay.map:
      if k not in updated: map[k] = v        // 未被本次链刷新 → 规则/JS 值优先
      // 被刷新过 → 保留 base 中的新值
  return serialize(map)
```

- 这精确复刻了“首次请求规则优先、链内新值接管”的期望，也避免 JS 罐里的旧同名值压制 302 新会话。
- `set_cookies` 记录 `updated_names`、写罐 B、持久化、通知 JS 罐（见下）。

**改动点**：

| 文件:行号 | 改动 | 预估 |
|---|---|---|
| `rust/legado-net/src/client.rs:228-252` | 删除 `.cookie_store(true)`；改为 `cookie_provider(Arc::new(AppCookieJar::new(store, persistence)))`。需把罐 B 初始化（`client.rs:311-349`）**移到 builder 构建之前** | +20/-5 |
| 新增 `rust/legado-net/src/cookie_jar.rs` | `AppCookieJar` 实现 `reqwest::cookie::CookieStore`；`CookieRequestContext`（`save`、`overlay_domain`、`overlay: HashMap`、`updated: Mutex<HashMap<domain, HashSet<name>>>`）；`tokio::task_local!` 与 `with_cookie_context`；`parse/serialize` 复用 `CookieStore` 现成方法 | +180-220 |
| `client.rs:1562-1624` | `apply_headers_and_cookies` 去掉 `cookie_store` 参数与 DB 注入（`:1611-1623`），只负责普通头/UA/剥离 `CookieJar`；新增 `build_cookie_context(url, headers, save_cookies)` 提取 overlay | +30/-25 |
| `client.rs:427-993` 的 8 个工厂 | 各方法：`let ctx = build_cookie_context(...)`；`with_cookie_context(ctx, async move { ... req.send().await }).await` | +60-80 |
| `client.rs:1230-1300` | `save_cookies_from_response` 改为调用共享 `persist_cookie_values(store, persistence, url, values)`；provider 与最终兜底共用；写完罐 B/DB 后调用全局 `CookieWriteObserver`（见下） | +30/-20 |
| `client.rs:989-990,1133-1134,1186-1187` | 可保留为“兜底写回”（与 provider 重复但幂等）；建议保留一个版本周期，确认 provider 全路径覆盖后再删 | 0 |
| 新增 `rust/legado-net/src/cookie_jar.rs` | `pub trait CookieWriteObserver { fn on_cookies_saved(&self, domain: &str, cookie_string: &str); }` + 全局 `OnceLock`（仿 `CookiePersistence` 注入） | +25 |
| `rust/legado-js/src/host_api/cookie_store.rs` | 新增 `sync_cookie_from_http(domain, cookie_string)`：只更新罐 C（G 锁，incoming 胜），**不调用 sink**（DB 已由 net 层写）；供 observer 使用 | +30 |
| `rust/legado-js/src/host_api/network.rs:278-280` | `set_client_cookie_store` 注册 observer（`Arc<JsCookieObserver>`）→ HTTP 写回同步到罐 C；FFI 无需新增注册（`http_state.rs:461-471` 已调用该函数） | +20 |
| 测试 | `legado-net` 单测/回环 + `legado-js` quickjs 集成 + FFI 搜索链路 | +250-300 |

**LOC 预估**：生产代码约 420-470 行（适配器 ~200、上下文/接线 ~120、多值捕获/observer/JS 写穿 ~100-150），测试约 250-300 行；总 670-770 行。

**为什么 B2 风险低于 A**：

- 重定向、方法改写、跨站、超时、重试、限流**全部仍是 reqwest 的代码**；B2 只替换“cookie 存储器”，且 reqwest 的 CookieService 本来就是逐跳执行（已核实服务栈顺序）。
- 现有 P1-2 规则优先、门控、共享罐、DB 合并、`no_redirect_variant` 共享 store 等不变量都可以保留；测试面主要是 cookie 语义。
- 门控通过 task-local 上下文恢复，不需要第二套客户端/连接池。
- 唯一的新不变量是“所有发送必须包 context”；用私有 helper + 单测钉死（见测试清单）。

**残余风险/注意**：

- `cookies(url)` 读罐 B 时不按 Path/Secure 过滤（既有语义），逐跳注入不会新引入问题，但会把 Path 限定的 cookie 发到全路径；若要与上游完全一致，后续再给 `CookieStore` 加 path/secure 过滤（不在本批）。
- `Set-Cookie` 的 `Max-Age=0`/过期删除语义：当前解析器只存 `name=value`（`client.rs:1272-1285`），会把删除写成空值。B2 复用同一解析器可保持现状；若要正确删除，需单独改造并补测试（登记为遗留项）。
- provider 写罐 B 是每跳一次；同一请求链可能多次 `persistence.save`（上游也是每跳写 DB，`CookieManager.kt:41-50`），DB 写放大可接受。**注意**：`set_cookies` 在 reqwest poll 线程内同步调用 `CookiePersistence::save`（DB 池 I/O），与现有 `save_cookies_from_response` 的同步写库模式一致，但在多跳链上会放大 poll 阻塞；若实测有卡顿，可在保持 D 锁语义的前提下改为专用阻塞线程/批处理（需重新评估“响应头到达即可见”的时序）。
- 非门控请求：provider 仍会注入罐 B（读侧无条件，语义不变），但 `set_cookies` 因 `save=false` 不写；这消除了罐 A 过去对非门控请求的“隐形会话维持”（见风险清单）。

### 4.4 方案对比表

| 维度 | C（最小） | A（逐跳手动，仅门控） | B2（单罐 provider，推荐） |
|---|---|---|---|
| 修复① 3xx 进罐 B/DB | ❌ | ✅ | ✅ |
| 修复② 显式头遮蔽/同名旧值 | 仅跨请求，链内 ❌ | ✅（链内按 captured_names 接管） | ✅（overlay + updated_names） |
| 修复③ 重启保持 | ❌ | ✅（每跳持久化） | ✅（每跳持久化） |
| `java.getCookie` 可见 | ❌ | 需配套 observer（必做） | 需配套 observer（必做） |
| 改动面 | 小（~60 行） | 中（~300-350 生产 +250 测试） | 大（~450 生产 +300 测试） |
| 重定向语义风险 | 无 | **高**（复刻 reqwest） | **无**（保留 reqwest） |
| 门控保持 | 保持（不写） | 天然（只在门控分支） | task-local 上下文保持 |
| 额外连接池 | 无 | 有（手动变体） | 无 |
| `followRedirects=false` | 不变 | 不变（派生客户端已关跟随） | 不变（单跳仍逐跳捕获） |
| 可测性 | 中 | 高 | 高 |
| 结论 | 不闭环，仅缓解 | 可闭环，风险偏高 | **推荐** |

---

## 五、推荐方案与可执行改动清单

### 5.1 推荐

**推荐 B2：单罐（`cookie_provider` 适配器）+ 请求级 Cookie 上下文 + 多 Set-Cookie 全量捕获 + HTTP→JS 罐写穿。**

理由：

1. **根因是“存储多套”，不是“重定向没跟随”**。reqwest 已经在逐跳执行 CookieService（服务栈证据见 §2.1），把存储器换成罐 B 即可让逐跳写入自然落到 App/DB；这比在 `legado-net` 重写重定向链风险低一个量级。
2. **上游就是单罐 + 逐跳**（§2.6），B2 是对齐上游的实现，而不是另造语义；罐 A 在上游根本不存在（`.cookieJar` 被注释）。
3. **默认门控覆盖大多数书源**（`enabled_cookie_jar` 缺键默认 `Some(true)`），A 会把大多数书源请求切到手动重定向路径；B2 不碰重定向，爆炸半径更可控。
4. **可以保留 P1-2 规则优先、门控、共享罐、DB 合并等既有不变量**；新引入的只有“请求上下文”一个机制，可用单测钉死。

如果实现批次必须在“最小 diff”内完成，**退路是 A（仅门控）**，但必须在计划里明确：受影响的源范围是默认开启门控的大多数书源，且需要完整的重定向语义测试矩阵；否则不建议。

### 5.2 B2 实施步骤（建议按顺序，每步可独立编译/测试）

**Step 1：把罐 B 初始化前移，替换 jar A（`client.rs:224-363`）**

- 在 `build_with_store` 开头（builder 之前）完成 `cookie_store` 的 `existing`/`load_all` 初始化（把 `:311-349` 整段上移）。
- `builder` 去掉 `.cookie_store(true)`（`:232`），改为：
  ```rust
  let jar = Arc::new(AppCookieJar::new(
      Arc::clone(&cookie_store),
      cookie_persistence.clone(),
  ));
  builder = builder.cookie_provider(jar);
  ```
- `AppCookieJar` 的 observer 通过全局 `OnceLock` 读取，不在构造参数里传，避免改 4 个生产构造点（`http_state.rs:422-426`、`network.rs:357-373`、`server/web_book.rs:295-301`）。

**Step 2：新增 `rust/legado-net/src/cookie_jar.rs`**

- `CookieRequestContext`：
  ```rust
  pub struct CookieRequestContext {
      pub save: bool,
      pub overlay_domain: Option<String>,      // ETLD+1
      pub overlay: HashMap<String, String>,    // 书源/JS/loginHeader 的 Cookie
      pub updated: Mutex<HashMap<String, HashSet<String>>>, // 域 → 本链被响应刷新过的 cookie 名
  }
  tokio::task_local! { static COOKIE_CTX: Arc<CookieRequestContext>; }
  pub async fn with_cookie_context<F>(ctx: Arc<CookieRequestContext>, f: F) -> F::Output
  ```
- `AppCookieJar::set_cookies`：
  - `let Some(ctx) = COOKIE_CTX.try_with(Clone::clone).ok() else { return }`；`if !ctx.save { return }`；
  - 收集 `cookie_headers` 为 `Vec<String>`（**迭代器全量**，不折叠）；
  - 解析 `name=value`（复用 `client.rs` 现有解析逻辑，抽成 `parse_set_cookie_pair`）；
  - 取 `domain_write_lock(domain)`（D）；写 `store.set_cookie`；在 J 锁内取 `domain_cookie_string`；释放 J；
  - `persistence.save(domain, &view)`（仍在 D 内，J 外——与 `save_cookies_from_response` 的锁纪律一致）；
  - 记录 `ctx.updated` 的 name 集合；
  - **释放 D**（显式 `drop(guard)`）后调用全局 observer（JS 写穿），避免 JS 侧再取 D 造成自死锁（`std::sync::Mutex` 不可重入，见 `legado-js/cookie_store.rs:628-635` 的同类警告）。
- `AppCookieJar::cookies`：
  - 取 domain key；`base = store.read().domain_cookie_string(&domain)`（**先释放 J 读锁**，再取 `ctx.updated`，避免 J↔updated 交叉持锁）；
  - 若 ctx 的 overlay 同域，按键合并（`updated` 中的 key 用 base 的新值，其余 overlay 覆盖）；
  - 空串返回 `None`；否则 `HeaderValue::from_str`。

**Step 3：`apply_headers_and_cookies` 改造（`client.rs:1562-1624`）**

- 去掉 `cookie_store` 参数和 `:1611-1623` 的 DB 读取/合并；保留普通头/UA/`CookieJar` 标记剥离。
- 新增：
  ```rust
  fn build_cookie_context(
      url: &str,
      headers: Option<&HashMap<String, String>>,
      save_cookies: bool,
  ) -> Arc<CookieRequestContext>
  ```
  - 从 headers 提取 `Cookie`（大小写不敏感）→ `parse_cookie_header`；
  - `overlay_domain = cookie_domain_key(url)`；
  - `save = save_cookies`。
- 8 个工厂（`get` `get_raw` `post_raw` `post` `post_multipart` `head` `send` `send_stream`，行号见 §4.2 表）：
  ```rust
  let ctx = build_cookie_context(&url, headers.as_ref(), save_cookies);
  ...
  with_cookie_context(ctx, async move {
      let mut req = ...;
      req = apply_default_headers_static(req);
      req = apply_headers_and_cookies(req, &url, (*headers).clone(), fallback_ua.clone());
      req.send().await
  }).await
  ```
  - 注意：ctx 要在 factory 内**每次尝试新建**（重试时 `updated` 清空），或在 factory 外 clone 后 `updated` 清空；推荐在 factory 内建。

**Step 4：多 Set-Cookie 全量捕获（配套，必须）**

- `collect_response`（`client.rs:1114-1160`）与 `collect_raw_response`（`:1167-1213`）：
  - 在构建 `HashMap` 之前，先 `let set_cookie_values: Vec<String> = response.headers().get_all(SET_COOKIE).iter().filter_map(|v| v.to_str().ok()).map(str::to_owned).collect();`
  - 仍构建 `headers` HashMap（供响应消费方），但写回改为 `save_cookie_values(&final_url, set_cookie_values)`（不再从 HashMap 取）。
- `send_stream`（`client.rs:981-991`）：在 `LegadoStreamResponse::new` 之前从 `raw_response.headers()` 取全量 `Set-Cookie`，或给 `LegadoStreamResponse` 增加 `set_cookie_headers: Vec<String>` 字段；建议前者（在 `new` 前捕获并传给保存函数）。
- provider 已经在 `set_cookies` 拿到全量迭代器，因此这条主要修“最终响应 + 非重定向/无 provider 兜底”路径；两条路径共用 `save_cookie_values`。

**Step 5：JS 罐写穿（配套，必须）**

- `legado-net`：新增 `CookieWriteObserver` trait + `set_cookie_write_observer(Arc<dyn ...>) -> bool`（first-wins），在 `save_cookie_values` 写完罐 B/DB、**释放 D 后**调用。
- `legado-js/host_api/cookie_store.rs`：
  ```rust
  /// HTTP 层写回镜像到 JS 罐（不写 DB——net 层已写；不加 D——net 层调用时可能仍持有/刚释放，避免自死锁）
  pub fn sync_cookie_from_http(domain: &str, cookie_string: &str) {
      let mut store = lock_store();
      let entry = store.entry(domain.to_string()).or_default();
      for (k, v) in parse_cookie_pairs(cookie_string) { entry.insert(k, v); }
  }
  ```
  - 只取 G 锁；同域覆盖（incoming 胜），保留 JS 独有键。
- `legado-js/host_api/network.rs:278-280`：`set_client_cookie_store` 成功后注册 observer（`JsCookieObserver` 调 `sync_cookie_from_http`）。FFI 在 `db_open` 已调用该函数（`http_state.rs:461-471`），因此 FFI 主客户端与 JS 四池都会获得写穿。注意 first-wins：`legado-js` 单测若先注册了别的 observer，生产注册可能被忽略——建议 observer 注册与 `CLIENT_COOKIE_STORE` 绑定，且测试使用独立进程/不注册 store。
- 如果不想动 `legado-js` 的注册顺序，也可在 FFI `register_js_client_cookie_persistence` 里直接调用 `legado_net::cookie_store::set_cookie_write_observer(...)`；两种都可，推荐前者（legado-js 自包含）。
- 备选（**不推荐单独使用**）：只让 `java.getCookie` 兜底读 `CLIENT_COOKIE_STORE`（net 罐）。它能让 `getCookie` 看到 HTTP 新值，但 `merge_js_cookies` 仍会先把罐 C 的旧同名值塞进请求头，形成 overlay 旧值；没有写穿就无法保证“旧值不压制新值”。因此写穿是主方案，读穿只能作为兜底。

**Step 6：清理/收敛**

- provider 生效后，`collect_response` 的兜底写回会与 provider 重复。建议保留一个版本（幂等、可防御 context 丢失），在 provider 全路径测试通过后删除，减少 DB 写放大。
- `save_cookies_from_response(HashMap)` 保留给测试/兼容；生产调用点逐步改为 `save_cookie_values`。

**Step 7：验证**

```powershell
cd D:\OH-WorkSpace\LegadoTeam\legado\rust
cargo test -p legado-net
cargo test -p legado-js --features quickjs
cargo test -p legado-ffi
cargo test -p legado-fetcher
```
（Windows 无 make；以上为 CMD/PowerShell 可直接执行。CI 见 `.github/workflows/rust-ci.yml`。）

> 环境说明：本任务只涉及 Rust crate，未改 `flutter_legado/**`，因此不涉及 `dart analyze`；项目根无 `analysis_options.yaml`（仅有 `flutter_legado/analysis_options.yaml`）。

---

## 六、回归风险清单

| # | 既有行为 | 现状 | B2 后可能变化 | 风险级别 | 必测 |
|---|---|---|---|---|---|
| 1 | 书源自定义 `Cookie` 头覆盖 DB cookie（P1-2，规则优先） | `merge_cookie_headers(db, rule)` 规则胜（`client.rs:1617-1623`） | overlay 规则优先，保留；但**本次链捕获的同名 cookie 从第二跳起接管** | 中 | `test_cookie_merge_rule_priority_e2e_p1_2` + 新增 302 同名用例 |
| 2 | 登录态保持（同进程） | 罐 A 隐式维持；罐 B 只收最终响应 | 罐 B 每跳更新，同进程可见；罐 A 消失 | 低（正向） | 302 登录回环 |
| 3 | 登录态保持（重启） | 3xx 丢失；最终 cookie 进 DB | 3xx 也进 DB，重启保持 | 低（正向） | 清内存 + 重建 + backfill |
| 4 | `cookie` 持久化 | 最终响应整域视图 upsert；同域合并 | 每跳 upsert；`persist_cookie_row_merged` 键并集合同名新值胜，不丢其它键 | 低 | MockPersistence 多次 save 断言 |
| 5 | `java.getCookie` 可见性 | 只读罐 C；运行期看不到 HTTP 写回 | 写穿后可见（HTTP 写 → 罐 C）；JS `setCookie` 仍走原路径 | 低（正向） | quickjs 集成：302 后 getCookie |
| 6 | 书源 `enabledCookieJar=false` | 响应 cookie 不写罐 B/DB（罐 A 仍偷偷写） | provider `save=false` 不写；**罐 A 的隐形状态消失** → 依赖罐 A 的源可能行为变化 | 中 | 门控关闭 + 两请求回环，断言第二请求不带第一响应的 cookie |
| 7 | RSS 登录头合并 | `loginHeader` 的 Cookie 随请求头出网（同源门控） | overlay 保留；跨站重定向清空 overlay（与 reqwest 删 Cookie 头一致） | 低 | `rss/request.rs` 现有用例 + 跨站 302 |
| 8 | 多条 `Set-Cookie` | 只保留最后一条（所有路径） | provider/新 `save_cookie_values` 全量；响应头 map 仍只暴露最后一条（供 UI/日志） | 低（正向） | 单响应两条 Set-Cookie |
| 9 | Cookie `Path`/`Secure`/`Domain` | 全部忽略（存 path `/`） | 不变（仍忽略）；逐跳后可能捕获更多带 Path 的 cookie，被发到全路径 | 中（既有缺陷放大） | 带 `Path=/api` 的 Set-Cookie + 首页请求 |
| 10 | 会话 cookie 持久化 | 无 `Expires` 也写 DB | 不变（仍写）；上游是“会话 cookie 只驻内存”，我方原本就偏离 | 低（既有偏离） | 重启后会话 cookie 仍在（记录现状） |
| 11 | 跨端口 cookie | 域名键忽略 port，同 host 不同 port 共罐 | 不变；逐跳会合并不同端口的 Set-Cookie | 低（既有） | 回环两端口（如需隔离用不同 host） |
| 12 | `followRedirects=false` | 302 原样返回；最终 3xx 的 Set-Cookie 写回（门控） | provider 单跳捕获，语义不变 | 低 | 现有 `test_no_follow_redirects_returns_302_unchanged` + 门控 |
| 13 | `CookieJar` 标记不出网 | 首发送前剥离，重定向不复活（现有测试 `client.rs:3075-3179`） | 不变（`apply_headers_and_cookies` 仍是剥离点） | 低 | 现有 20 跳测试 |
| 14 | 超时/重试/限流 | reqwest 总超时包整条链；retry 在外层 | 不变（B2 不动发送栈） | 低 | 现有 `test_follow_redirects_*`（20/21 跳） |
| 15 | 代理/hosts/派生客户端 | `with_proxy`/`no_redirect_variant` 复用同 store | provider 也复用同 store；**每个派生客户端各建一个 provider（同一 store）**，无新罐 | 低 | 现有 `test_no_redirect_variant_caches_and_shares_cookie_store` |
| 16 | `send_stream` 流式消费 | 头到达即写回 | provider 在头到达时写；流式语义不变 | 低 | 音频/下载现有测试 |
| 17 | `legado-server` 每请求客户端 | `with_cookie_persistence` 新建、构建时 load_all | provider 同样每请求新建；行为不变（无进程级共享） | 低 | server cookie 测试 |
| 18 | 并发同域写 | D→J→C→P 锁序 | provider 复用 `domain_write_lock`，锁序不变；**observer 必须在 D 释放后调用** | 中 | 现有 RMW/清除并发测试（`net_api.rs:434-510`） |

---

## 七、测试清单（必须补）

### 7.1 `legado-net` 单元/回环（核心）

建议新增 `rust/legado-net/tests/cookie_redirect.rs`（或放在 `client.rs` 的 `#[cfg(test)]`，复用现有 `spawn_set_cookie_recorder` 模式，`client.rs:2861-2891`）。

1. **302 Set-Cookie 进入罐 B + DB + 下一跳**
   - 回环 `/login` → `302` + `Set-Cookie: sid=NEW; Path=/` + `Location: /home`；`/home` → `200` 并记录请求头。
   - 客户端预置罐 B `sid=OLD`（`client.cookie_store().write().set_cookies_from_string("127.0.0.1", "sid=OLD")`）。
   - 断言：`/home` 的 `Cookie` 含 `sid=NEW` 且不含 `sid=OLD`；罐 B `get_key("127.0.0.1","sid") == NEW`；`MockPersistence` 行含 `sid=NEW`。
   - 这是 P2-2 的最小回归。
2. **同站两跳都带 Set-Cookie**
   - `/a` 302 `a=1` → `/b` 302 `b=2` → `/c` 200；断言 `/c` 同时带 `a=1; b=2`，罐 B/DB 都有。
3. **规则 Cookie 与 capture 同名**
   - 请求头 `Cookie: sid=OLD; rule=1`；302 下 `sid=NEW`；断言下一跳 `rule=1; sid=NEW`（不出现 `sid=OLD`）。
4. **302 POST → GET，body 丢弃**
   - POST `/login`（body）→ 302 `/home`；断言第二跳 method=GET 且无 body。
5. **307 POST 保持**
   - 307 `/submit` → `/result`；断言 method=POST、body 原样。
6. **跨 host 不泄漏**
   - A（`127.0.0.1`）302 → B（`localhost`）；A 请求带 `Authorization` + `Cookie: rule=1`；断言 B 的请求头无 `Authorization`、无 `rule=1`；B 自己的罐 B cookie 仍注入。
7. **20 跳成功 / 21 跳失败**
   - 复用现有 `test_follow_redirects_follows_20_hops` / `stops_at_21st_hop`（`client.rs:2723-2791`），改为带 `CookieJar` 标记 + 每跳 Set-Cookie，断言 20 跳都写回。
8. **`followRedirects=false`**
   - 带标记，302 原样返回；罐 B/DB 有该 302 的 Set-Cookie；不请求第二跳（现有 `test_no_follow_redirects_returns_302_unchanged` 扩展）。
9. **门控关闭**
   - 无 `CookieJar` 标记；302→200，断言罐 B/DB 无 Set-Cookie（现有 `test_without_cookie_jar_marker_skips_writeback...` 扩展到重定向夹具）。
10. **多条 Set-Cookie（单响应）**
    - 200 响应带 `Set-Cookie: a=1` + `Set-Cookie: b=2`；断言罐 B 同时有 a/b（覆盖 §2.2 折叠缺陷）。
11. **超时预算（可选）**
    - 两跳各 sleep 40s，客户端 `read_timeout=60s`；断言语义是总 60s 超时（与现状一致），而不是 2×60s。
12. **并发同域 RMW**
    - 两个 gated 请求同时 302 下不同 cookie；断言 DB 行并集、无回退（复用 `http_state.rs` 现有 RMW 测试模式）。

### 7.2 `legado-js` / `legado-ffi` 集成

13. **`java.getCookie` 同进程可见**
    - quickjs 引擎执行 `java.ajax`/`java.connect` 访问回环 302（带 `CookieJar` 标记，当前书源 `enabledCookieJar=true`）；响应后在同一进程执行 `java.getCookie(url, "sid")`，断言等于 302 的新值。
14. **JS `setCookie` 与 HTTP 写回不互相覆盖**
    - JS 先 `setCookie(url, "js=1")`；HTTP 302 下 `sid=2`；断言 `getCookie` 同时含 `js=1` 和 `sid=2`，下一请求两者都带。
15. **重启语义**
    - 302 后清空罐 B/罐 C 内存（测试支撑入口），用同一 DB 重建客户端 + `backfill_from_sink`；断言 `sid` 恢复。
16. **搜索主链路**
    - `search_single_source` 的回环用例（已有 `test_search_single_source_cookie_jar_gate_end_to_end`，`search.rs:2547-2700`）扩展为 302 登录 + 第二请求断言。
17. **RSS 登录头**
    - `rss/request.rs` 的 `source_headers_with_login` + 302：断言登录 Cookie 在同站链内保留、302 同名值接管、跨站不发送。

### 7.3 现有测试必须保持绿

- `client.rs:2247-2360` P1-2 规则优先（单测 + e2e）。
- `client.rs:2915-3010` 门控开/关写回 + 读侧无条件注入。
- `client.rs:3017-3070` `get_raw` 门控。
- `client.rs:3075-3179` `CookieJar` 标记跨 20 跳不复活。
- `client.rs:2818-2840` `no_redirect_variant` 共享 store。
- `http_state.rs:635-720` DB 持久化 roundtrip；`:873-1050` 合并写/清除。
- `legado-js` `cookie_store.rs:793-1530` 读写/合并/清除。
- `legado-js/tests/str_response_tianlai_loopback.rs` 302 无 Location / 有 Location 的 StrResponse 语义。

### 7.4 回环夹具写法（可直接复用）

```rust
// 目标：记录每一跳的 Cookie 请求头，按路径返回固定响应
let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
let addr = listener.local_addr().unwrap();
let seen: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new())); // (path, head)
tokio::spawn(async move {
    while let Ok((mut sock, _)) = listener.accept().await {
        // 读头到 \r\n\r\n（同 client.rs:2880-2900 的实现）
        // 取 path 与 cookie: 行
        let (status, location, set_cookie) = match path.as_str() {
            "/login" => ("302 Found", Some("/home"), "Set-Cookie: sid=NEW; Path=/\r\n"),
            "/home"  => ("200 OK", None, ""),
            _ => ("404 Not Found", None, ""),
        };
        // 写响应：Location/Set-Cookie/Content-Length/Connection: close
    }
});
```

断言小工具：把 `Cookie` 头按 `;` 拆成 `HashMap`，避免顺序敏感。

---

## 八、不修/遗留项（建议登记，不在 P2-2 单批内扩散）

1. **会话 cookie 与持久 cookie 的区分**：上游 `CookieManager.saveResponse` 把无 `Expires/Max-Age` 的会话 cookie 只放内存（`CookieManager.kt:41-50`），我方当前全部写 DB（`client.rs:1265-1288`）。这会让“会话 cookie 重启仍存活”，与上游不一致。改动会影响登录态生命周期，建议单独立项。
2. **`Path`/`Secure`/`Domain` 属性**：我方 `Cookie` 结构有字段但读取/写入均不使用（`cookie_store.rs:231-315`）。逐跳捕获后更多带 Path 的 cookie 会被全路径发送；建议后续给 `get_cookie_string` 加 path/secure 过滤。
3. **`Max-Age=0`/过期删除**：当前解析只取 `name=value`（`client.rs:1272-1285`），删除会写成空值；上游的 `replaceCookie` 对空串是 no-op，也不完美。建议单独补“删除语义”测试后再改。
4. **响应头 map 的多值折叠**：`LegadoResponse.headers`/`LegadoRawResponse.headers` 仍是 `HashMap`（`response.rs:10-18,44-52`），JS `raw().headers('Set-Cookie')` 只能看到最后一条。写回路径已在 B2 中修复；若 JS 源依赖 `raw().headers` 读取多条 Set-Cookie，需要另行扩展响应头表示（涉及 FFI/JS 桥契约）。
5. **跨端口 cookie 共罐**：`cookie_domain_key` 按 host 计算、忽略 port（`cookie_store.rs:603-608`），同 host 不同端口的 cookie 会合并。既有语义，上游同样按域名；登记为已知行为。
6. **`legado-server` 每请求新建客户端**：`server_deps` 每次 `LegadoClient::with_cookie_persistence`（`server/handlers/web_book.rs:294-301`），provider 化后仍每请求构建（含 `load_all`）。性能问题另见审查 P3-7，不在本批。
7. **`legado-net/src/url_template.rs` 等无关项**：不在本报告范围。

---

## 九、证据索引（按文件）

### 我方（当前工作区）

| 文件 | 关键行 |
|---|---|
| `rust/legado-net/src/client.rs` | 67-76（`CookieJar` 常量/判定）、99/130（follow_redirects 默认）、155-165（字段）、197-204（with_cookie_store）、224-252（build：jar A + 重定向策略）、312-349（store 预载）、382/387（访问器）、427-470（get）、538-600（get_raw）、605-670（post_raw）、673-728（post）、729-797（post_multipart）、798-837（head）、838-903（send）、904-993（send_stream，990 写回）、1029-1045（no_redirect_variant）、1054-1082（retry/limit）、1114-1160（collect_response，1125-1128 折叠、1134 写回）、1167-1213（collect_raw_response，1178-1181 折叠、1187 写回）、1230-1300（save_cookies_from_response）、1562-1624（apply_headers_and_cookies）、2247-2360（P1-2 测试）、2723-2791（20/21 跳测试）、2861-3180（门控/标记测试） |
| `rust/legado-net/src/cookie_store.rs` | 11-31（Cookie）、35-44（Persistence trait）、151（domain_write_lock）、210-315（set/get/serialize）、560-608（域名键） |
| `rust/legado-net/src/response.rs` | 10-18、44-52、85-92、137-139（headers HashMap、文档“最后一个值”） |
| `rust/legado-fetcher/src/analyze_request.rs` | 208-230（followRedirects/retry 选择客户端） |
| `rust/legado-fetcher/src/web_book.rs` | 889-908（标记）、942-1000（同站登录头）、1088-1099（header 解析）、1143-1158（fetch_page 合并 + JS cookie）、1282/1330（simple/toc 合并）、3245（正文分页） |
| `rust/legado-ffi/src/api/search.rs` | 1283-1295（搜索头 + 标记）、2547-2700（门控 e2e） |
| `rust/legado-fetcher/src/rss/request.rs` | 120-149（静态头 + 登录头 + 标记） |
| `rust/legado-ffi/src/api/rss_web_bridge.rs` | 900-906（WebView cookie 回流）、1100-1120（loginHeader → JS setCookie） |
| `rust/legado-ffi/src/api/webview_api.rs` | 80-110（WebView cookie JSON 落库） |
| `rust/legado-ffi/src/http_state.rs` | 94-110（合并 upsert）、229-243（DbCookiePersistence）、343-351（JS sink/backfill）、365-366（共享 store）、389-428（shared_client/build）、461-471（JS 持久化 + store 注册） |
| `rust/legado-js/src/host_api/network.rs` | 250-280（持久化/store 钩子）、304-338（门控）、357-383（池构建）、711（merge_js_cookies） |
| `rust/legado-js/src/host_api/cookie_store.rs` | 23-25（罐 C）、95（backfill）、440-451（get_cookie）、464-533（写）、628-635（D 锁不可重入警告）、696-706（cookies_for_url）、736-786（merge_js_cookies） |
| `rust/legado-js/src/host_api/quickjs_impl.rs` | 2996-3010（`java.getCookie` 绑定） |
| `rust/legado-core/src/models/book_source.rs` | 71-85（enabled_cookie_jar 默认）、230-232（default_true_opt） |

### 依赖源码

| 依赖 | 关键行 |
|---|---|
| `reqwest 0.12.28` `src/async_impl/client.rs` | 1023-1026（`CookieService` 在 `FollowRedirect` 内层） |
| `reqwest 0.12.28` `src/cookie.rs` | 237-247（仅无 Cookie 头才注入）、280-291（每响应 set_cookies）、28/157/174-186（Jar 公开面） |
| `reqwest 0.12.28` `src/redirect.rs` | 120-147（Policy 回调无 headers）、131-145（limit 语义）、239-249（跨站删敏感头）、296-338（TowerRedirectPolicy） |
| `tower-http 0.6.11` `src/follow_redirect/mod.rs` | 211-229（每跳克隆原始请求头）、262-330（301/302/303 方法改写） |
| `http 1.4.2` `src/header/map.rs` | 2323-2353（同名多值逐条迭代） |
| 上游 `.tmp/legado-master/.../HttpHelper.kt` | 28-48（cookieJar 对象）、62（`.cookieJar` 注释）、83-98（network interceptor 逐跳） |
| 上游 `.tmp/legado-master/.../CookieManager.kt` | 29-50（saveResponse 逐跳；持久/会话分流）、55-75（loadRequest 逐跳合并） |
| 上游 `.tmp/legado-master/.../CookieStore.kt` | 54-70（getCookie 合并 DB+session） |
| 上游 `.tmp/legado-master/.../AnalyzeUrl.kt` | 604-630（setCookie 规则优先 + 标记）、635-645（saveCookie） |
| 上游 `.tmp/legado-master/.../BookSource.kt` | 55-57（enabledCookieJar 默认 true） |

---

## 十、给实现批的入口建议（一句话版）

1. 先在 `legado-net` 落地 **`AppCookieJar` + `CookieRequestContext`**（B2 Step 1-3），用 §7.1 的 1/2/3/9/10 五个回环用例钉死；
2. 再做 **多 Set-Cookie 全量捕获**（Step 4）和 **HTTP→JS 罐写穿**（Step 5），用 §7.2 的 13/14 钉死；
3. 最后跑全量 `cargo test -p legado-net -p legado-js -p legado-ffi -p legado-fetcher`，并复查 §6 的 18 项风险；
4. 若 B2 在评审中被判定改动过大，退回 **A（仅门控手动跟随）**，但必须同时接受“大多数默认书源走新的重定向实现”的风险，并按 §4.2 的 9 条语义逐条补测试。
