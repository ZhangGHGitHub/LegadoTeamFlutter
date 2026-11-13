# 2026-11-13 全面审查 · 路 1：引擎链报告

> 审查基线：HEAD `e26916c098`（2.0.497+498；`BRIEF.md` 写明的 `7c15e82252` 已前移，按实际 HEAD 审查）
> 对照基线：`app/`（本仓保留的原版 Kotlin）、`D:\OH-WorkSpace\LegadoTeam\legado-upstream`（上游）、`D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（参考版）
> 性质：**只读审查**。未修改业务代码、未运行构建/测试；仅使用 `git log/show`、`rg`、`Read`、cargo registry 只读源码。遵守 `BRIEF.md`「审查期间禁止运行构建/测试」。
> 证据等级声明：**本报告全部结论来自静态代码证据**（含上游/参考版逐行对照、crates.io 依赖源码核对）。标注「已核实」的项是代码路径闭合核验，不等于运行时实机证明；本轮未做真实用例复现，凡涉及运行时行为的建议均给出可执行回归用例。
> 路径约定：下文「我方」路径相对 `D:\OH-WorkSpace\LegadoTeam\legado\`；「上游」= `legado-upstream`；「参考版」= `legado-with-MD3`。行号为审查时 HEAD 行号。

---

## 一、摘要

### 1.1 审查范围与实际落点

| 计划范围 | 实际审查对象 | 说明 |
|---|---|---|
| `rust/legado-js/` | `engine.rs`、`engine_cache.rs`、`executor.rs`、`source_engine.rs`、`replace_rule_js.rs`、`sandbox.rs`、`login_check.rs`、`host_api/{quickjs_impl,fs_policy,archive_utils,font_api,cookie_store,variable_store,cache_store,network,global_headers,current_source,ui_action_queue}.rs` | 宿主 API 面、规则执行语义、引擎生命周期 |
| `rust/legado-parser/` | `analyze_url.rs`、`analyze_rule.rs`、`html.rs`、`xpath.rs`、`jsonpath.rs`、`rule_analyzer.rs` | 规则三态（空/异常/网络失败）、选择器边界 |
| `rust/legado-net/` + `rust/legado-fetcher/` | `client.rs`、`cookie_store.rs`、`ssl_config.rs`、`retry.rs`、`source_checker.rs`；fetcher `web_book.rs`（目录链/epoch/取页/缓存）、`analyze_request.rs`、`source_setup.rs`、`js_adapter.rs` | 注：`web_book`/epoch 实际位于 `legado-fetcher`，不在 `legado-net` |
| `rust/legado-book/` | `txt.rs`、`epub.rs`、`mobi.rs`、`archive.rs`、`encoding.rs`、`pdf.rs`、`umd.rs`、`cbz.rs` | 解析、编码检测、切分、大文件 |

### 1.2 总体结论

**需修改（needs changes）**。引擎链主干（URL/规则解析、JS 引擎池、图片动作 LRU、RAR/ZIP/7z 解压安全、目录刷新 epoch）整体工程质量较高，且上一批（批21）的 RAR 越界与 `fs_policy` 白名单修复**经核实已完整落地**；但本轮发现 **1 条 P0 级跨书源请求头泄漏**、**5 条 P1**（生产环境文件 API 整体缺失、`cache`/`source.put` 持久化语义被内存实现取代、书源校验不跑规则、契约字段 `step_timeout_ms` 未接线+取消粒度不足），以及一组 P2/P3。

### 1.3 缺陷计数

| 级别 | 数量 | 编号 |
|---|---|---|
| P0 | 1 | P0-1 |
| P1 | 5 | P1-1 ~ P1-5 |
| P2 | 9 | P2-1 ~ P2-9 |
| P3 | 8 | P3-1 ~ P3-8 |
| 需用户裁决 | 4 | 见 §三 |

**最严重 3 条**

1. **P0-1 `java.headerMap.put` 的线程局部收集器无作用域、失败路径不清空**：书源 A 在 URL 规则 JS 中写入请求头后脚本报错，该头会残留在线程局部队列中，被**下一次任意书源**的 `parse_with_js` 成功收尾时并入请求——跨源认证头/凭据外发。代码注释还声称「非 URL 窗口写入会被下次窗口收尾丢弃」，与实现相反。
2. **P1-1 生产沙箱不注册整套文件 API**：`allow_file_access=false`（生产唯一配置）下 `java.downloadFile/cacheFile/importScript/getFile/readTxtFile/getTxtInFolder/fileExists/deleteFile/readFile/writeFile` **全部未注册**，随包帮助文档（`jsHelp.md`）却明确列出这些能力。音频/漫画/聚合类书源一旦引用即 `TypeError`。
3. **P1-2 书源 setup 脚本无条件覆盖 `globalThis.cache`**：`cache.put/get` 退化为 `java.put/get`（进程内存裸键），`saveTime` 被忽略、`putFile/getFile/delete` 直接消失；Rust 侧带 TTL/磁盘的 `cache_store` 在规则 JS 中实际不可达。依赖 TTL 刷新 nonce 的源会永久使用过期值，重启又会丢失永久缓存。

---

## 二、缺陷清单（按 P0 → P3）

### 2.1 总表

| 编号 | 等级 | 文件:行号 | 问题（一句话） | 后果 | 建议修法（一句话） |
|---|---|---|---|---|---|
| P0-1 | P0 | `rust/legado-parser/src/analyze_url.rs:44-49,62-70,1329-1386`；`rust/legado-js/src/host_api/quickjs_impl.rs:2766-2781` | URL 窗口写入的 pending 请求头无作用域归属，失败路径不清空，下一次任意窗口成功时被并入请求 | 跨书源认证头/凭据外发；错误头导致他源请求失败 | 入口先清空 + 窗口开关门控写入 + RAII 全退出清理；补双源回环用例 |
| P1-1 | P1 | `rust/legado-js/src/host_api/quickjs_impl.rs:179-182,2089-2257`；`rust/legado-js/src/sandbox.rs:219-228`；生产配置 `engine_cache.rs:60-62`、`executor.rs:96-102` | 生产 `allow_file_access=false` 下整套文件 API 未注册 | 文档化的 `downloadFile/cacheFile/importScript/...` 在 App 内 undefined，相关书源直接失败 | 用 `FsPolicy` 白名单重开（对齐上游 externalCache 限域），或同步删除文档并显式报“不支持” |
| P1-2 | P1 | `rust/legado-fetcher/src/source_setup.rs:114-125`；对照 RSS 同名逻辑 `:522-527` | 书源 setup 无条件覆盖 `cache` 对象，规则内 `cache.put/get` 退化为内存裸键 | saveTime/TTL 失效（过期值永久使用）、restart 丢缓存、`putFile/getFile/delete` 不存在、备份不覆盖 | 与 RSS 一致加 `typeof globalThis.cache === 'undefined'` 守卫，保留宿主 `cache_store`；补 TTL/putFile 用例 |
| P1-3 | P1 | `rust/legado-fetcher/src/source_setup.rs:144-161`；`rust/legado-js/src/host_api/variable_store.rs:15-18,38-45`；`rust/legado-ffi/src/api/backup_api.rs:2457-2468` | `source.put` / `sourceVariable` / `v_*` 只写进程内存，无持久化 sink；`java.put/get` 裸键无书/源作用域 | 重启丢登录/会话变量；备份恢复链预期 `caches` 行但无人写；跨源同名键串值 | 增加 `VariableSink` 写穿 `caches`（deadline=0）+ 启动回填；裸 `java.put` 按 flow/source 作用域隔离 |
| P1-4 | P1 | `rust/legado-net/src/source_checker.rs:385-509`；`rust/legado-ffi/src/api/source_check_api.rs:70-92`；上游 `CheckSourceService.kt:273-410` | 「书源校验」不执行搜索/详情/目录/正文规则，只用正则取首个 href | 校验结果不可信：坏源可通过、好源（POST/JS/严格规则）被判失败 | 复用已有 fetcher 版校验实现（`legado-server/src/legacy/source_check_api.rs:1023-1250`），或在 UI/契约明确改名为“连通性测试” |
| P1-5 | P1 | `rust/legado-net/src/source_checker.rs:142,159`；`rust/legado-ffi/src/api/source_check_api.rs:160-200` | 冻结契约字段 `step_timeout_ms` 全仓无消费；`cancelCheckSources` 仅在源间检查 | 配置的超时不生效；停止校验最长要等当前源数次 60s 请求；批量校验不可及时中止 | 每步 `tokio::time::timeout(step_timeout_ms)` + `select!` 轮询取消标志；补契约测试 |
| P2-1 | P2 | `rust/legado-fetcher/src/web_book.rs:2954-2958,2998-3007,3095-3121`；`rust/legado-ffi/src/api/reader.rs:725-731` | 只有 `refresh_toc` bump 代数，但所有目录分页链都读代数；同书 refresh 会取消普通 `webbook_chapters` | Web/其他调用方在 App 刷新同书时收到 `superseded` Internal 错误（而非正常返回） | 仅 refresh 发起的链把“被抢占”当取消；非 refresh 链不参与该取消或返回部分成功 |
| P2-2 | P2 | `rust/legado-net/src/client.rs:229-232,1077-1085,1495-1556`；`rust/legado-js/src/host_api/cookie_store.rs:440-451` | 双 Cookie 罐：reqwest 内置 jar 收 3xx Set-Cookie，App 罐/Vue 只收最终响应；显式 Cookie 头会让 reqwest 跳过 jar | 302 登录 Set-Cookie 不进 App 罐/DB/JS 可见域；同名旧值可压制新值；重启后会话丢失 | 单一 Cookie 管：逐跳捕获 3xx Set-Cookie 入 App 罐；`java.getCookie` 兜底读共享罐；关闭/清理 reqwest 内置 jar 的二义性 |
| P2-3 | P2 | `rust/legado-js/src/host_api/font_api.rs:47,50,204-212`；上游 `CacheManager.kt:12` | `HANDLE_CACHE` 是无上限 HashMap，且保存完整字体输入串（`data` 回显） | 逐章轮换字体的反爬源会无限累积内存（每项可含数百 KB 字体串）→ 长阅读 OOM | 句柄缓存改与 `FONT_LRU` 同容量 LRU（4/8），句柄只存 fontId/hash，不回显原始 data |
| P2-4 | P2 | `rust/legado-book/src/txt.rs:242-259,315-320`；上游 `TextFile.kt:118-127` | 每次取章节正文都 `read_to_end` 全文件并整体 decode | 大 TXT（数十~数百 MB）每翻页 O(file) I/O+解码，内存峰值 ~1.5×文件；低端机卡顿/OOM | 按 `(path,charset)` 缓存解码结果或分块窗口读取（seek+局部 decode），至少给“最近一本”加有界缓存 |
| P2-5 | P2 | `rust/legado-js/src/source_engine.rs:137-176`；对照 `executor.rs:207-219` | JS 书源 `new_quickjs` 直接把 `js_lib` 原样交给 `engine_cache` eval，不做 URL 映射形态解析 | mainJs + URL 映射 jsLib 的 JS 书源直接报 `jsLib 求值失败`（普通规则源却正常） | 复用 `jslib_loader::parse_js_lib_url_map`/`resolve_js_lib_url_map_with_status`，与 `QuickJsExecutor` 同源 |
| P2-6 | P2 | `rust/legado-js/src/engine_cache.rs:173-194` | 持有进程级缓存 mutex 期间执行 `init_engine`（可 eval 数百 KB jsLib，jsLib 顶层 java.ajax 可阻塞到网络超时） | 一个源首次建引擎时，全进程所有源的引擎查找被阻塞（Mutex），搜索/阅读整体卡住 | 改双检：读锁快路径 → 锁外构建 → 写锁复查装入（同 `http_state::shared_client` 模式） |
| P2-7 | P2 | `rust/legado-js/src/host_api/current_source.rs:49-60` | `with_current_source_tag` 无 Drop 护栏，闭包 panic 后线程局部 tag 不恢复 | tokio blocking 线程复用时，后续请求被归属到错误书源（cookie 门控/全局头/验证码钩子错源） | 用 RAII guard 保存/恢复（同 `ui_action_queue::ScopeGuard`） |
| P2-8 | P2 | `rust/legado-js/src/login_check.rs:74-108`；上游 `WebBook.kt:74-99` | `loginCheckJs` 只用裸 `QuickJsExecutor::new(source_tag)` 执行，未加载 jsLib/setup，只绑定 `result` | loginCheckJs 引用 jsLib 函数或 `source/cookie/cache/java.*` 时抛错→登录检测失败/整次搜索报错 | 按规则执行器构造（jsLib + source_setup + js_bindings），补 jsLib 函数用例 |
| P2-9 | P2 | `rust/legado-js/src/engine_pool.rs:63-84,98-116`；`rust/legado-js/src/source_engine.rs:313` | `EnginePool` 无生产调用点（死代码）；池满“删第一个”非 LRU；`lock().unwrap()` 中毒即 panic | 维护陷阱（误以为是 LRU）；一旦启用会随机丢引擎状态；锁中毒导致连续 panic | 删除 `EnginePool` 或实现真正 LRU；`unwrap` 改 `unwrap_or_else(into_inner)` |
| P3-1 | P3 | `rust/legado-js/src/host_api/archive_utils.rs:45-73,86-127,488-525,377-406` | zip 条目先读入内存再落盘；`read_file_magic`/RAR 预扫描读整包；无解压总量/单条目上限 | 恶意/异常压缩包可造成内存峰值（zip bomb），大包重复整读 | 流式 copy + 单条目/总量上限；magic 只读头 512B；RAR 预扫描改流式 |
| P3-2 | P3 | `rust/legado-book/src/txt.rs:263-307` | 编码检测只读前 4KB，且“能无错解码 GB18030”即判 GB18030 | 长 ASCII 头部 + 后段 GBK 的文件被判 UTF-8 → 后半段替换符/乱码 | 扩大采样（如 64KB）+ 统计置信度；或复用 chardetng（fetcher 已用作第四级） |
| P3-3 | P3 | `rust/legado-net/src/url_template.rs:1-10,92-` | 第二套“基础版”URL 模板解析器（不执行 JS/不支持 `{{}}` JS），仅 re-export，无仓内消费方 | 双实现漂移风险；误用会得到与主链不同的 URL | 删除或标注 `#[deprecated]` 并移除 re-export |
| P3-4 | P3 | `rust/legado-js/src/host_api/quickjs_impl.rs:3700-3713` vs `rust/legado-js/src/host_api/cache_store.rs:257-300` | 注释称 `saveTime<=0` “仅内存”，实际写永久磁盘条目+内存 | 文档误导排障 | 修正注释（与 cache_store 模块文档统一） |
| P3-5 | P3 | `rust/legado-net/src/ssl_config.rs:57-68` | 自定义 CA PEM 解析失败仅 `log::warn` 后忽略 | 用户配置私有 CA 后仍握手失败，且无用户可见原因 | 解析失败向上返回错误（或初始化期 fail-fast） |
| P3-6 | P3 | `rust/legado-js/src/host_api/ui_action_queue.rs:123-182` | `begin_collect/end_collect/discard_collect` 兼容 API 无 RAII，漏配对会在线程池残留会话；生产仅 `with_collect` | 未来误用会复现“action 串会话” | 删除兼容 API（仅测试使用），或内部改委托 `with_collect` |
| P3-7 | P3 | `rust/legado-server/src/handlers/source_check.rs:63-70,100-118` | 批量校验每个源 `LegadoClient::new` 新建连接池（最多 20 个） | 批量校验 TLS 握手/连接池开销大 | 复用共享客户端（FFI 侧已用 `shared_client`） |
| P3-8 | P3 | `rust/legado-js/src/host_api/archive_utils.rs:280-363,376-406` | RAR 安全依赖自写的 RAR5 预扫描解析器与 `rar` crate 双解析一致；解压后无“产物 containment”兜底 | 依赖方升级/格式边缘差异时，预扫描可能漏判；无第二道防线 | 解压后遍历输出目录 canonicalize 校验全部落在 out_dir；预扫描加与 crate 的格式一致性用例 |

---

### 2.2 P0 详述

#### P0-1 URL 窗口 pending 请求头无归属：失败残留 + 跨源注入

**证据链（我方）**

1. 收集器是**无 owner 的线程局部 Vec**，没有任何 invocation id / scope：
   - `rust/legado-parser/src/analyze_url.rs:44-49`：`PENDING_REQUEST_HEADERS: RefCell<Vec<(String,String)>>`。
   - `:62-65`：`push_pending_request_header` 无条件 push；`:68-70`：`take_pending_request_headers` 只在调用方显式调用时清空。
2. 入口只重置 `CURRENT_URL`，**不清理上一轮 pending**：
   - `rust/legado-parser/src/analyze_url.rs:1323-1336`（`parse_with_js` 起始 `set_current_url(Some(""))`，无 `take`）。
3. 失败路径提前 `return Err`，**没有清理 pending**：
   - `:1336-1343`：URL 模板 JS 执行失败 → `set_current_url(None); return Err(...)`。
   - `:1348-1353`：`Self::parse` 失败 → 同样直接返回。
   - 只有成功路径 `:1381-1386` 才 `take_pending_request_headers()` 并并入 `parsed.headers`。
4. 写入入口在**任意 JS 上下文**都可用，且 setup 脚本无条件挂载：
   - `rust/legado-js/src/host_api/quickjs_impl.rs:2766-2781`：`java.headerMapPut` 全局注册，函数体无窗口判断。
   - `rust/legado-fetcher/src/source_setup.rs:243-252`：`java.headerMap = { put: (k,v)=>java.headerMapPut(...) }` 在每次 setup 时注入；因此 jsLib、`init`、`@js` 规则、失败中的 URL 模板都能写。
5. 写入后确实会出网：
   - `rust/legado-fetcher/src/web_book.rs:1144-1150`：`headers.extend(analyze_url.headers().clone())`，随后交给 `send_raw`/`send_text`。
6. 代码注释与实现相反：
   - `quickjs_impl.rs:2770-2771` 注释：「非 URL 窗口写入会被下次窗口收尾丢弃（上游同款：无 AnalyzeUrl 上下文则无 headerMap 可写）」。实际上没有“丢弃”，而是被**下一次成功窗口收尾**合并进请求。

**触发场景（真实可达）**

- 书源 A 的 `searchUrl` 含 `@js:` 块：先 `java.headerMap.put('Authorization','Bearer <A的token>')`，随后因 JS 运行时错误/语法错误返回 `Err`（本轮搜索失败）。
- 同一 tokio blocking 线程（长生命周期、跨源复用）随后处理书源 B 的 `parse_with_js`，成功收尾时 `take_pending_request_headers()` 取到 A 的头，`headers.extend(...)` 后 B 的请求带上 `Authorization: Bearer <A的token>`。
- 即使不是凭据，错误的自定义头（如 `Referer`/`X-Sign`/`Cookie`）也会让 B 的请求被风控拒绝，表现为“B 源时好时坏”。

**后果**

- 安全面：跨书源、跨域发送认证头/签名头/Cookie（书源作者可控的任意键值）。
- 功能面：残留头污染下一次请求，产生难以复现的 403/签名错误。

**建议修法**

1. `parse_with_js` 入口先 `take_pending_request_headers()` 丢弃陈值，并设置“URL 窗口开启”标志；用 RAII guard 在**所有退出路径**（`?`/`Err`/panic）清空并复位（参考 `ui_action_queue::ScopeGuard`）。
2. `headerMapPut` 仅在窗口开启时接受写入；窗口外返回 false/忽略（对齐上游“无 AnalyzeUrl 上下文即无 headerMap”）。
3. 若要支持嵌套/并发，收集器改为 `Vec<Frame>` 栈并按 token 归属，而不是单一 Vec。
4. 回归用例（建议放 `rust/legado-parser` 单测 + `rust/legado-fetcher` 回环）：
   - A 写入头后 JS 抛错 → B 成功解析 → 断言 B 的实际请求头中无 A 的键；
   - 窗口外 `java.headerMap.put` → 下一次 `parse_with_js` 的 `headers()` 为空；
   - panic 路径后线程复用不残留。

---

### 2.3 P1 详述

#### P1-1 生产沙箱不注册文件 API，与随包帮助文档/上游能力直接矛盾

**证据（我方）**

- 注册门控：`rust/legado-js/src/host_api/quickjs_impl.rs:179-182`
  ```rust
  // 文件 API 仅在 allow_file_access = true 时注册（安全门控）
  if config.allow_file_access {
      register_file_apis(ctx, &java, &globals)?;
  }
  ```
- 整套文件 API 只在 `register_file_apis` 内定义：`:2089-2257`（`readFile`、`writeFile`、`fileExists`、`deleteFile`、`readTxtFile`、`downloadFile`、`getFile`、`cacheFile`、`importScript`、`getTxtInFolder`）；全仓无第二处注册（`rg '"downloadFile"'` 仅命中该函数与文档/测试）。
- **生产所有引擎配置都保持 `allow_file_access=false`**：
  - `rust/legado-js/src/engine_cache.rs:60-62`：`SandboxConfig::default().with_allow_script_run(true).with_memory_limit(64MB)`；
  - `rust/legado-js/src/executor.rs:96-102`：同上；
  - `rust/legado-js/src/engine_pool.rs:43`：同上；
  - `SandboxConfig::default()` 的 `allow_file_access=false`：`rust/legado-js/src/sandbox.rs:306-317`；`permissive()` 只在测试/调试使用（`rg` 无生产调用）。
- 安全模型文档自述「文件 IO 禁止」：`rust/legado-js/src/sandbox.rs:15,219-228`。
- 但随包帮助明确把这些 API 当书源能力：`rust/assets/web/help/md/jsHelp.md:352-370`（`java.downloadFile`、`unArchiveFile/unzipFile/unrarFile/un7zFile`、`getTxtInFolder`、`readTxtFile`、`deleteFile`；并注明“只能操作 .../cache/ 内文件”）；`flutter_legado/assets/web/help/md/jsHelp.md` 同文。
- 上游实现把文件 API 限域在 `externalCache`，并非禁用：`legado-upstream/app/src/main/java/io/legado/app/help/JsExtensions.kt:455-540`（`importScript/cacheFile/downloadFile`）、`:802-833`（`getFile` 越界抛 `SecurityException`、`readFile/readTxtFile`）。
- 能力清单测试以生产同款配置构造引擎（`rust/legado-ffi/tests/capability_sweep.rs:1197-1201`），却把 `downloadFile/cacheFile/importScript` 列入 `CAPABILITY_NAMES`（`:78,97,139`）——清单不代表运行时可解析，不能作为“已提供”的证据。

**后果（真实用户可见）**

- 任何使用 `java.importScript(url)` 加载远端 JS（帮助文档推荐写法 `eval(String(java.importScript(...)))`）、`java.cacheFile(url)` 取远端文本、`java.downloadFile(url)` 下载音频/图片/字体、`java.readTxtFile/getTxtInFolder` 的书源，在 App 内调用即 `TypeError: ... is not a function`（或 Rhino 兼容层下 `undefined` 调用），规则失败/字段为空。
- 音频/漫画/聚合源受影响概率最高；这与「文件 API 后置」的批21 登记（`docs/REFACTORING_ACTIVE_PLAN.md:889` 的 RSS `downloadFileAwait` 后置）不是同一范围——那条只针对 RSS WebView 桥，不包含书源规则 JS。

**建议修法（推荐 A）**

- **A（对齐上游、保留安全）**：始终注册文件 API，但路径统一走 `FsPolicy`：
  - `downloadFile/cacheFile/importScript/getFile/readTxtFile/getTxtInFolder/fileExists/deleteFile` → `resolve_read_path`/`resolve_write_path`；受限模式的根 = 引擎沙箱根（建议由宿主注入 `set_sandbox_root(app cache dir)`，与 `cache_store::set_cache_dir` 同型）；
  - `readFile/writeFile` 可维持 gated 或同样按策略限域（上游 `getFile` 已限域，建议放开策略化版本）；
  - 越界返回明确 `[ERROR]`/抛异常，不静默空串。
- **B（若坚持禁用）**：删除 `jsHelp.md` 中这些能力的条目，`capability_ledger` 与能力清单改登记为“不支持”，并在规则执行时给出可读错误（而非 `is not a function`）；FS 策略文档同步修正「书源拿到的本地路径由 downloadFile 生成」的错误前提（`fs_policy.rs:17-20`）。
- 测试：两种 `allow_file_access` 模式下 `typeof java.downloadFile`/`cacheFile`/`importScript` 断言；受限模式下载到沙箱成功、越界拒绝；permissive 保持旧行为。

#### P1-2 书源 setup 无条件覆盖 `cache` 对象：TTL/持久化/putFile 全部丢失

**证据（我方）**

- 书源 setup 无条件赋值（无 `typeof` 守卫，`rust/legado-fetcher/src/source_setup.rs:114-125`，下面为节选/概括，非逐字全量）：
    ```js
    globalThis.cache = {
      get: function(k) { return get(String(k)) || null; },
      put: function(k, v) { put(String(k), String(v)); return v; },
      remove: function(k) { removeVariable(String(k)); return true; },
      // putMemory/getFromMemory/deleteMemory 委托 java.cache*；未定义
      // putFile/getFile/delete，且 put 无 saveTime 参数
    };
    ```
  这里的裸 `get`/`put` 是 `java.get`/`java.put`（`register_variable_apis`，`quickjs_impl.rs:2311-2334`），写入的是**进程内存** `variable_store`（`variable_store.rs:15-18,38-45`）。
- RSS setup 的同名逻辑是**有守卫**的：`source_setup.rs:518-527`（注释明确写「此前覆盖为变量表会让 run 内 cache 与页面 cache 分叉。仅在引擎未提供时回落变量表镜像」，`if (typeof globalThis.cache === 'undefined' || globalThis.cache === null) { ... }`）——说明“优先复用引擎内置 cache_store”是既定设计，且 RSS 侧已在批21c P2-7 修复，书源路径漏加守卫。
- 书源主链确实会走到这段 setup：`construct_analyzer_with_source_context` 把 `setup_script` 挂到执行器（`rust/legado-fetcher/src/js_adapter.rs:82-95`），搜索/详情/目录/正文主链均使用它（`web_book.rs:1720-1726` 搜索 URL、`1792-1797` 搜索结果、`2610-2615/2713-2718` 详情、`2847-2856` 目录、`4830-4835` 正文）。少数不带 setup 的构造点（如 `web_book.rs:3439,3721,4047,4112,4176`）反而使用宿主 `cache_store`，形成同一 App 内两条不同语义的 `cache`。
- 引擎内置 `cache` 对象（带 TTL/磁盘/putFile/getFile/delete）在 `quickjs_impl.rs:3700-3760` 注册，但随后被 setup 覆盖。
- `cache_store` 的真实语义：`cache_store.rs:1-30`（saveTime=0 永久；>0 deadline；`putFile/getFile/delete`），`:257-300`（写磁盘 + 内存）。
- 上游：`legado-upstream/app/src/main/java/io/legado/app/help/CacheManager.kt:60-76`（`CacheManager.put` 写 DB `caches` 表 + 内存）、`:169-207`（`WebCacheManager.put/get/putFile/getFile/delete` 全部委托 `CacheManager`）。

**后果**

- `cache.put(k, v, saveTime)` 的 `saveTime` 被忽略，值在进程内**永不过期**：依赖“缓存 nonce 60 秒后重取”的源会一直用旧 nonce，首次过期后确定性失败。
- 重启后所有 `cache.put` 值丢失（上游是 DB 持久）：登录态、WAF 挑战态、昂贵的解析结果全部重取。
- `cache.putFile/getFile/delete` 在规则 JS 中不存在（JS 对象未定义）→ 使用这些 API 的源 `TypeError`。
- 备份/恢复：上游 `caches` 表进备份；我方这些值既不在 DB 也不在 `cache_store` 磁盘层，备份天然缺失。

**建议修法**

1. 与 RSS 同款加守卫，让宿主注册的 `cache` 对象（`cache_store`）优先；仅在引擎未提供时回退到变量表。
2. 若必须保留 JS 对象实现（为了镜像语义），把 `put/get/remove` 委托到新增的 `java.cachePut/cacheGet/cacheRemove` 宿主桥，保留 `saveTime` 参数与磁盘/TTL 行为；并补 `putFile/getFile/delete`。
3. 回归：`cache.put(k,v,1)` → 1s 后 `cache.get(k)` 为 null；`putFile/getFile` 往返；重启模拟（重建 store）后永久键仍在；与 RSS 路径行为一致。

#### P1-3 `source.put` / `sourceVariable` / `v_*` 无持久化，且裸 `java.put/get` 无作用域

**证据（我方）**

- `source.put` 映射到裸 `put`（`rust/legado-fetcher/src/source_setup.rs:144-161`，下面为节选，原文分多行）：
    ```js
    function __sourceVarKey(k) { return 'v_' + sourceUrl + '_' + k; }
    obj.get = function(k) { return get(__sourceVarKey(k)) || ''; };
    obj.put = function(k, v) { put(__sourceVarKey(k), String(v)); return v; };
    obj.getVariable = function() { return get(__sourceVariableKey()) || ''; };
    obj.setVariable = function(v) { setVariable(__sourceVariableKey(), String(v)); return v; };
    ```
- 裸 `put/get/setVariable` 只写 `variable_store`（进程内存，无 sink、无 DB）：`rust/legado-js/src/host_api/variable_store.rs:15-18`（`GLOBAL_VARIABLES`）、`:38-45`（`set_variable` 仅 insert）、`:28-35`（`get_variable` 仅内存）。全仓无 `VariableSink`/写 DB 的注册点（`rg` 仅 CookieSink 存在）。
- 上游 `BaseSource.put/get/setVariable/putVariable` 全部走 `CacheManager`（DB）：
  - `legado-upstream/app/src/main/java/io/legado/app/data/entities/BaseSource.kt:331-367`（`setVariable/putVariable` → `CacheManager.put("sourceVariable_<key>")`；`put` → `CacheManager.put("v_<key>_<k>")`）。
- 备份/恢复链**已经预期这些键在 DB**：
  - `rust/legado-ffi/src/api/backup_api.rs:2457-2468`（`is_runtime_source_cache_key` 覆盖 `v_/userInfo_/loginHeader_/sourceVariable_/infoMap_`，用于从 `caches` 表挑选备份条目）。书源路径从不写这些行 → 备份中为空。
- 同一 API 在 RSS 桥是“内存 + DB 双写”，证明设计意图：
  - `rust/legado-ffi/src/api/rss_web_bridge.rs:1064-1100`（`source_var_put`/`source_variable_set` 先 `variable_store::set_variable`，再 `db_cache_put(&full, value)`）。
- 裸 `java.put/get` 的作用域问题：`quickjs_impl.rs:2311-2334` 直接读写进程级 `variable_store` 的**裸键**；上游 `AnalyzeRule.put/get` 是 chapter → book → ruleData → source 的级联（`AnalyzeRule.kt:856-885`），`AnalyzeUrl.put/get` 是本次 URL 实例（`AnalyzeUrl.kt:426-450`），都不是进程全局。规则 JS 经 `analyze_rule` 的 `__lgVars` + flow scope 兜底（`analyze_rule.rs:1831-1847`）掩盖了大部分场景，但 URL 模板 JS、loginCheckJs、jsLib 顶层等未走该前导的路径仍会落到裸键。

**后果**

- 重启/换机后书源登录 token、`source.put` 会话变量、`sourceVariable` 全部丢失：需要重新登录；对依赖手动登录/验证码的源，功能直接不可用。
- 备份恢复链对 `v_*`/`sourceVariable_*` 的覆盖是**空的**（契约/实现错觉）。
- 裸键同名跨源/跨书串值：A 源 `java.put('token', ...)` 后 B 源未设置时 `java.get('token')` 可能读到 A 的值（进程级 HashMap），与上游“按书/源作用域”不一致。

**建议修法（需先定口径，见 §三）**

1. 增加 `VariableSink`（仿 `CookieSink`）：`set_variable` 写内存后按 `key` 写穿 `caches`（deadline=0）；`db_open` 注册并启动回填；`source.put/sourceVariable` 自然获得持久化。
2. `java.put/get` 默认改走 flow/source 作用域（复用 `put_flow_variable/get_flow_variable`），仅 `source.put` 等显式持久键（`v_/sourceVariable_/loginHeader_/userInfo_`）保留持久层；避免 URL 模板/登录检测路径的跨源串值。
3. 若产品明确“JS 会话变量不落库”，则必须：删除备份链对 `v_*` 的预期、修正 `source.put` 文档与“持久键”措辞、并在契约中登记；不建议保留当前“看起来持久、实际不持久”的状态。

#### P1-4 书源校验不执行书源规则，结果不可信

**证据（我方）**

- 搜索：只用 `searchUrl` 做字符串替换后直接 GET，取首个 `href` 当书籍地址：
  - `rust/legado-net/src/source_checker.rs:385-410`（`build_search_url` 仅替换 `{{key}}/{key}/{searchKey}`；`client.get(&url, ...)`）；
  - `:477-484`（`build_search_url`）；
  - `:486-500`（`extract_first_book_url`：仅 `bookUrlPattern` 正则或 `extract_first_href`）。
- 目录：直接 GET「书籍地址」，再取首个 `href` 当章节地址——不使用 `ruleToc`/`tocUrl`：
  - `:414-432`（`do_toc_check`）、`:502-509`（`extract_first_chapter_url`，注释自述“简化实现”）。
- 正文：只判断 `is_success()` + body 非空，不跑 `ruleContent`：
  - `:435-452`。
- 全程无 `AnalyzeUrl`（@js/POST/header/编码）、无 `AnalyzeRule`（searchList/bookUrl/toc/content）：`rg "AnalyzeRule|AnalyzeUrl" rust/legado-net/src/source_checker.rs` 仅命中测试注入；`source.rule_search` 只被用于 `check_key_word`（`:459-475`）。
- 上游：`legado-upstream/app/src/main/java/io/legado/app/service/CheckSourceService.kt:273-410`——`withTimeout(CheckSource.timeout)` 内调用 `WebBook.searchBookAwait`、`WebBook.getBookInfoAwait`、`WebBook.getChapterListAwait`、`WebBook.getContentAwait`，逐项判 `TocEmptyException/ContentEmptyException`。
- 消费面：FFI `source_check`/`source_check_stream`（`rust/legado-ffi/src/api/source_check_api.rs:70-92`）与 server `/api/sources/check`（`rust/legado-server/src/handlers/source_check.rs:76-118`）都包装这个简化实现；`book_source_check_states` 状态机（批30）把它当权威结果。

**后果**

- **假阳**：任何返回非空 HTML 且带 `<a href>` 的站点，即使 searchList/toc/content 规则完全写错，也会被判定 search/toc/content 全通过。
- **假阴**：POST 搜索、`@js` 搜索 URL、严格 header/编码、目录需 `ruleToc` 解析的源被判失败；JS 源（searchUrl 为空 + mainJs）直接 “no searchUrl” 失败。
- 用户在「书源校验」页看到的状态与实际可用性不符，批量校验结果用于清源/分组时会误删好源或保留坏源。

**建议修法**

- 复用仓内已存在的**完整校验实现**：`rust/legado-server/src/legacy/source_check_api.rs:1023-1250` 已用 `webbook_search/webbook_info/webbook_chapters/webbook_content`（legacy API 路径），把它下沉到 `legado-fetcher`/`legado-net` 的共享模块，FFI 与新 server 路由改调同一实现；保留现有 captcha/redirect 检测。
- 若性能/并发压力是顾虑：至少让 `check_search` 走 `webbook_search`（带规则），目录/正文沿用同一 fetcher；逐源串行 + 每步超时。
- 若产品决定维持“连通性冒烟”，则契约 §书源校验、UI 文案与状态字段改名（如 `reachable_ok`），不再声称“对齐 Kotlin CheckSource”；避免以 `search_ok/toc_ok/content_ok` 误导用户（需用户裁决，见 §三）。

#### P1-5 `step_timeout_ms` 契约字段未接线；取消只发生在源之间

**证据（我方）**

- `CheckerConfig.step_timeout_ms` 定义/默认：`rust/legado-net/src/source_checker.rs:142,159`。
- 全仓消费点：`rg -n "step_timeout_ms"` 仅 `source_checker.rs`（定义/默认/测试）、`source_check_api.rs`（DTO 解析/测试）、`ffi.rs` 文档注释——**`check_full/check_search/quick_check` 均未使用**（`:178-330` 无 timeout 包装）。
- FFI DTO 明确暴露该字段并落库：`rust/legado-ffi/src/api/source_check_api.rs:37-64`；契约 §书源校验把 `step_timeout_ms` 列为冻结配置（`docs/API_CONTRACT.md:567`）。
- 取消：`rust/legado-ffi/src/api/source_check_api.rs:160-200` 只在每个源开始前检查 `CHECK_CANCELLED`；`check_full` 内部的 3 个 await 无取消轮询，也无 `tokio::time::timeout`。

**后果**

- 用户把单步超时设为 5s，实际单步仍按 HTTP 客户端 `read_timeout=60s`（`legado-net/src/client.rs:119-120`）甚至重试叠加，最长可达数分钟；契约字段是“空开关”。
- 「停止校验」在某个源卡住时最长要等该源全部请求结束；UI 表现为按钮无响应/继续推送结果。

**建议修法**

- `check_full` 每步 `tokio::time::timeout(Duration::from_millis(config.step_timeout_ms), ...)`，超时映射为 `*_error="timeout"`；整个 `check_full` 再加整体上限（对齐上游 `withTimeout`）。
- 每个 await 用 `tokio::select! { _ = cancel_notified() => return cancelled, r = fut => r }`，`cancel_check_sources` 用 `Notify`/`AtomicBool`+短轮询均可；补“卡住请求 + 取消 → 1s 内返回”的集成用例。
- 在契约测试里断言 `step_timeout_ms` 真的影响耗时上界（当前测试只断言 DTO 解析，`source_check_api.rs:281-293`）。

---

### 2.4 P2 详述（摘要式）

- **P2-1 目录链 epoch 误取消**：`refresh_toc` 入口 bump（`rust/legado-ffi/src/api/reader.rs:725-731`），而 `get_chapters_with_hints` 的串行/并发分页链都读取同一 `book_url` 代数并在页边界比较（`rust/legado-fetcher/src/web_book.rs:2954-2958,2998-3007,3095-3121`）。普通 `webbook_chapters`（阅读端/Web `/api/webbook/chapters`）不 bump，但会被同书 refresh 抢占并返回 `Internal("toc refresh superseded…")`。上游语义是“协程取消只作用于自己的调用链”，不会跨调用取消。建议：链入口标记 `is_refresh_chain`，仅 refresh 链接受 supersede；或非 refresh 链在检测到抢占时返回 `Ok(已解析部分)` 并记录告警。
- **P2-2 双 Cookie 罐 + 仅最终响应写回**：`rust/legado-net/src/client.rs:232` 打开 reqwest 内置 `cookie_store(true)`；`save_cookies_from_response` 只在 `collect_response/collect_raw_response` 对**最终响应**调用（`:1077,1130`）；`apply_headers_and_cookies` 用 App 罐拼出显式 `Cookie` 头（`:1544-1556`）。reqwest 0.12.28 只在请求**没有** `Cookie` 头时才从内置 jar 注入（`reqwest-0.12.28/src/cookie.rs:242`）。因此：登录 302 响应上的 `Set-Cookie` 只进 reqwest 内存 jar，不进 App 罐/DB/JS `getCookie`；当 App 罐对该域已有任意 cookie 时，显式头会完全屏蔽 jar 中的新会话值（同名旧值也可能压制新值）；重启后 3xx cookie 丢失。建议：逐跳捕获重定向响应（自定义 `redirect::Policy` 或在 `no_redirect` 下手动跟随），把每跳 `Set-Cookie` 写入 App 罐；`java.getCookie` 兜底读共享 CookieStore；长期收敛为单一罐。
- **P2-3 字体句柄缓存无上限**：`HANDLE_CACHE` 是 `HashMap<String,String>`（`font_api.rs:47`），每次 `query_ttf_with_policy` 成功解析即 `cache.insert(cache_key, handle)`（`:204-212`），handle JSON 里 `"data": data` 回显完整输入（`:195-201`）。上游只有 `LruCache<String, QueryTTF>(4)`（`CacheManager.kt:12`）。逐章换字体（常见反爬）会让进程内累积 N 份字体串。建议：句柄缓存同容量 LRU（4），或只存 `fontId` 元数据，不回显原始 data。
- **P2-4 TXT 每次正文全文件读**：`get_chapter_content_with_charset` 每章 `read_file_bytes`（`txt.rs:247,315-320`）→ `decode_with_charset` 全量解码 → 切片（`:250-259`）。上游 `TextFile.getContent` 用 512KB 窗口 `bis.skip(bufferStart)` 只读附近块（`TextFile.kt:118-127`）。阅读翻页时每章重复 O(file) I/O/解码；大文件内存峰值 ≈ 原文件 + UTF-8 解码副本。建议：按 `(path, charset)` 做有界解码缓存或 mmap/seek 窗口读取；至少缓存最近一本书的解码文本。
- **P2-5 JS 书源 URL 映射 jsLib 未解析**：`JsSourceEngine::new_quickjs` 直接 `engine_cache::get_or_create(..., config.js_lib.as_deref(), ...)`（`source_engine.rs:146-153`），`init_engine` 原样 `eval(js_lib)`（`engine_cache.rs:69-87`）；URL 映射 JSON 不是合法 JS → `js_lib_ok=false` → `new_quickjs` 返回 `Err("jsLib 求值失败")`（`source_engine.rs:171-176`）。普通规则源的 `QuickJsExecutor` 已显式检测并走 `run_fresh`（`executor.rs:207-219`）。建议：`new_quickjs` 复用 `jslib_loader::parse_js_lib_url_map` + `resolve_js_lib_url_map_with_status`。
- **P2-6 engine_cache 持全局锁初始化**：`get_or_create_with_timeout` 在 `store().lock()` 后调用 `init_engine`（`engine_cache.rs:173-194`），而 `init_engine` 会 eval jsLib/setup/mainJs（`:69-139`）；jsLib 顶层 `java.ajax` 可阻塞到 60s。期间所有源的 `get_or_create`（含已缓存 key 的快路径）都在 Mutex 上排队。建议：读锁查表 → 未命中释放 → 锁外构建 → 写锁复查并装入（`http_state::shared_client` 已是此模式）。
- **P2-7 `with_current_source_tag` 非 panic 安全**：`current_source.rs:49-60` 保存 prev → `f()` → 恢复；`f()` panic 时恢复代码不执行，blocking 线程复用时 tag 残留。后果：后续请求的 `global_headers`（`network.rs:690-712`）、验证码钩子、cookie 写侧门控都可能错源。建议：RAII `Drop` guard（可直接照抄 `ui_action_queue::ScopeGuard`）。
- **P2-8 loginCheckJs 上下文缺 jsLib/source**：`execute_login_check_response` 只 `QuickJsExecutor::new(source_tag)`，只注入 `result`（`login_check.rs:83-106`），不加载 jsLib/setup、不绑定 `source/cookie/cache`；上游 `analyzeUrl.evalJS(checkJs, it)`（`WebBook.kt:74-99`）的 `evalJS` 会绑定 source/cookie/cache 并挂载 `SharedJsScope`（jsLib）。loginCheckJs 中使用 `jsLib` 函数或 `source.getVariable()` 的源会被判 `CastFailed/JsFailed`，且错误会沿登录检测上抛。建议：与规则执行器同构构造（jsLib + setup + bindings）。
- **P2-9 EnginePool 死代码/非 LRU/锁中毒 panic**：`EnginePool::get_or_create` 池满时 `pool.keys().next()` 删除任意项（`engine_pool.rs:73-78`，注释自述“后续可改为真正 LRU”）；`lock().unwrap()`（`:67`）与 `source_engine.rs:313` 在中毒后 panic。`EnginePool` 无生产调用点（`new_with_pool` 仅定义，`rg` 无调用）。建议：删除 `EnginePool` 与 `new_with_pool`（或迁移到 `engine_cache` 的 LRU 语义）；`unwrap` 改中毒恢复。

---

### 2.5 P3

- **P3-1 解压内存/大小无上限**：`unzip_file` 每条目 `read_to_end` 到 `Vec`（`archive_utils.rs:67-72`）；`get_zip_byte_array_content`/`zip_entry_bytes` 同样整条目入内存（`:100-127`）；`read_file_magic` 用 `fs::read` 读**整包**仅判前 4 字节（`:504-525`）；`unrar_file` 为预扫描整包读入（`:383-385`）。书源可控压缩包可造成数 GB 内存峰值。建议：流式 `io::copy` 到文件、单条目/总量上限、magic 只读 512B、预扫描流式。
- **P3-2 TXT 编码检测样本过小**：`detect_encoding` 只读 4KB（`txt.rs:263-307`），且用“GB18030 解码无 errors 即判定”的启发式；长 ASCII 头 + 后段 GBK 的常见排版会被判 UTF-8，后段出现 U+FFFD。上游用 ICU `CharsetDetector`（8KB 采样，`EncodingDetect.kt:55-70`）。建议：扩样 + 置信度/统计检测（fetcher 已引入 chardetng，可复用）。
- **P3-3 `legado-net/src/url_template.rs` 是第二套 URL 模板解析器**：仅 `{key}/<page>`/JSON 选项，不执行 JS，且全仓仅 re-export（`legado-net/src/lib.rs:74`），无调用方。建议删除或 `#[deprecated]` 并移除 re-export，避免误用。
- **P3-4 `cache.put` 注释与实现不一致**：`quickjs_impl.rs:3700-3713` 称 `saveTime<=0` “仅内存（putMemory）”，实际 `cache_store::put` 写永久磁盘条目 + 内存（`cache_store.rs:257-300`）。建议统一注释/模块文档。
- **P3-5 自定义 CA 失败静默**：`ssl_config.rs:57-68` 解析 PEM 失败只 `log::warn`，连接仍按默认根证书发起 → 用户配置私有 CA 后握手失败且无可见原因。建议返回错误或在 FFI 初始化期 fail-fast。
- **P3-6 `ui_action_queue` 兼容 API 无 RAII**：`begin_collect/end_collect/discard_collect`（`ui_action_queue.rs:123-182`）若调用方漏配对，线程局部栈残留；生产已全部 `with_collect`（`rg`：`explore_api.rs:393`、`image_action_api.rs:197`、`review_api.rs:1087`、`source_callback_api.rs:154`、`rss_web_bridge.rs:1413`），仅测试使用旧 API。建议删除或标注 `#[cfg(test)]`。
- **P3-7 server 批量校验每源新建客户端**：`legado-server/src/handlers/source_check.rs:63-70` 在并发循环内 `create_checker` → `LegadoClient::new(default)`，最多 20 个独立连接池；FFI 侧用 `shared_client`。建议复用共享客户端（注意 `no_proxy`/cookie 共享语义）。
- **P3-8 RAR 安全仅单层（预扫描）**：`scan_rar5_entry_names`（`archive_utils.rs:280-363`）是自写的 RAR5 头解析器，与 `rar` crate 并行维护；解压后没有遍历产物做 containment 复核。建议解压完成后遍历 `out_dir`，对每个条目 `canonicalize` 并断言在 `canonical(out_dir)` 内（成本 O(条目数)），作为 crate 升级/边缘格式的第二道防线。

---

## 三、需用户裁决项

### 3.1 目录刷新取消口径：普通目录请求是否应被“同书 refresh”取消？

- **我方现状**：`refresh_toc` 对 `book_url` bump 代数（`rust/legado-ffi/src/api/reader.rs:725-731`）；所有目录分页链（含普通 `webbook_chapters`）在页边界比对代数（`rust/legado-fetcher/src/web_book.rs:2998-3007,3095-3121`），不等即 `Internal("toc refresh superseded by a newer refresh generation")`。
- **上游现状**：`refresh_toc`（`WebBook.getChapterListAwait`）与另一个读取调用是两个独立协程；`ensureActive()` 只检查**自身**协程是否被取消，不会被另一个调用取消（`legado-upstream` `BookChapterList.kt` 的 nextUrl 链 + `ensureActive` 语义）。
- **需裁决**：是维持“同书任意新刷新可取消所有在途目录链”（实现简单，但普通读取会遇到 superseded 错误），还是把取消限定在“refresh 链之间”（普通链不参与，或把抢占转为部分成功）。
- **建议**：后者更贴合上游与用户预期；若保留前者，需要把 `Internal` 错误映射为“已取消/请重试”的 UI 语义而非红色失败。

### 3.2 `cache` / `source.put` 的持久化口径

- **我方现状**：书源 setup 把 `cache` 覆盖为 `variable_store` 内存实现（`source_setup.rs:114-125`），`source.put` 亦只写内存（`:144-161`）；RSS 桥则“内存+DB 双写”（`rss_web_bridge.rs:1064-1100`）。
- **上游现状**：`CacheManager.put`/`BaseSource.put` 全部写 DB `caches` 表（`CacheManager.kt:60-76`、`BaseSource.kt:331-367`）。
- **需裁决**：是补齐 DB 写穿（推荐，恢复上游语义并让备份链生效），还是明确“App 的 JS 缓存只驻内存”（则必须同步修改帮助文档/契约、删除备份链对 `v_*` 的预期，并移除 `saveTime` 语义；但这会让依赖 TTL 的源行为异常）。
- **补充事实**：当前状态不是“有意的内存实现”，因为 `cache_store` 已实现 TTL/磁盘/`putFile`，却被 setup 覆盖；这更像漏加守卫的回归。

### 3.3 HTTP 总超时口径（60s total vs 上游无 callTimeout）

- **我方**：`LegadoClientConfig::default` 的 `read_timeout=60s` 作为 reqwest 客户端 `.timeout()`（`legado-net/src/client.rs:229-230`），是**总请求超时**；仅分片上传按载荷覆写（`API_CONTRACT.md:1595` 已登记），普通 GET/正文/图片未覆写。
- **上游**：OkHttp 只设 `connectTimeout(15s)`/`readTimeout(60s)`（每次读操作），无 `callTimeout`；慢但持续有数据的响应不会被 60s 总超时掐断。
- **需裁决**：是否将普通请求改为“只在无数据进展时超时”（reqwest 无直接 read-timeout 语义，可通过 `timeout` 取消 + 自定义流读取看门狗近似），或维持现状并在契约登记“大响应/慢链 60s 上限”。

### 3.4 书源校验的产品语义

- **选项 A**：改为规则级校验（对齐上游 `CheckSourceService`，推荐；见 P1-4）。
- **选项 B**：保留简化冒烟，但把按钮/字段/状态改名为“连通性检查”，并在契约中删除“对齐 Kotlin CheckSource”的表述。
- 需用户确认是“校验结果可信度优先”还是“批量速度优先”，后者也需明确「假阳/假阴可接受」并调整清源逻辑。

---

## 四、已核实无问题项（含核实方式）

> 下列项均逐行读代码/依赖源码闭合核验；「测试」为仓库内已存在用例，本轮**未执行**。

1. **RAR `getRarStringContent` 路径校验（批21 P0 回修）已修好**：`normalized_rar_entry_name` 仅允许 `Component::Normal`（拒绝绝对路径/盘符/UNC/verbatim/`..`，`archive_utils.rs:192-217`）；读取侧再 `canonicalize` 双重确认（`:223-237`）；`unrar_file`/`rar_entry_bytes` 在写盘前预扫描整包（`:285-363,377-406,443-480`）；安全错误显式 `[ERROR]`（`quickjs_impl.rs:4761-4771`）。测试：`test_rar_entry_bytes_rejects_absolute_entry`、`test_rar_entry_bytes_rejects_parent_dir_entry`、`test_unrar_file_rejects_traversal_entry`、`test_rar_entry_bytes_rar5_basic`。
2. **7z 解压路径穿越**：锁定版本为 `sevenz-rust2 0.24.1`（`rust/Cargo.lock`），其 `util/decompress.rs:140,153-171` 已实现 `safe_join`（拒绝 `..`/RootDir/Prefix，Windows 风格 `\` 归一），`un7z_file` 直接调用 `decompress_file` → 受保护。
3. **ZIP 解压路径穿越**：`unzip_file` 使用 `entry.enclosed_name()`（`archive_utils.rs:51-54`）；`zip 2.4.2` 的 `enclosed_name`（`zip-2.4.2/src/types.rs:606-618`）拒绝 `\0`、`Prefix/RootDir`、越界 `..`。写入目标均相对 `out_dir`。
4. **`fs_policy` 白名单（批21 P2-5 回修）**：受限模式词法拒绝 `..`（`fs_policy.rs:111-123`）、拒绝非盘符 Prefix（UNC/verbatim/设备）；`canonicalize_allow_missing` 处理不存在尾段并对最近存在祖先 canonicalize（`:179-194`）；`allowed_roots` 只含引擎沙箱根与字体缓存（`:159-170`）；`Path::starts_with` 防兄弟目录前缀（测试 `test_restricted_rejects_sibling_with_sandbox_prefix`）；symlink/junction 逃逸测试（`:350-374`）。permissive 分支原样返回（`test_unrestricted_keeps_arbitrary_path`）。
5. **`replace_rule_js` 引擎复用与预算**：`thread_engine()` 为线程局部（`replace_rule_js.rs:741-773`），而规则执行器在 `apply_rule_with_timeout` 中为每条规则新建 OS 线程（`content_processor.rs:669-706`），故 thread-local 实际“一条规则一个引擎”，不会跨书源；逐匹配预算由 `eval_with_budget` 下传（`content_processor.rs:820-827`），引擎 `set_execution_timeout` 收紧（`replace_rule_js.rs:795-803`）；IIFE + `eval` 隔离匹配作用域；`eval('1+1')` 探测防沙箱替换 `eval`（`:756-765`）。
6. **图片动作引擎 LRU（批21-A）**：容量 4、命中刷新顺序、淘汰队首、jsLib 签名变化重建、degraded 不入缓存、`try_lock` 忙时降级一次性引擎、Poisoned 失效缓存（`replace_rule_js.rs:151-298,426-498`）；测试 `lru_evicts_least_recently_used`、`degraded_url_map_js_lib_is_not_cached_and_retries`、`poisoned_cached_engine_is_invalidated_and_falls_back`。
7. **`engine_cache` LRU 正确性**：命中时 `order.retain` + `push_back`；插入超 `MAX_ENTRIES` 从队首淘汰；key 比较含 `js_lib/setup/main_js/timeout`（`engine_cache.rs:176-212`）；测试 `lru_never_exceeds_max`、`changing_initialization_scripts_rebuilds_entry`、`timeout_participates_in_cache_key`。
8. **`ui_action_queue` 会话隔离**：`with_collect` 用 RAII `ScopeGuard`（`ui_action_queue.rs:85-121`），panic 展开也弹栈；生产 5 处调用全部用 `with_collect`（grep 已列）；测试 `nested_scopes_do_not_leak`、`scoped_collect_isolated_from_outside`。
9. **目录刷新 epoch 的键控与有界性**：`TOC_FETCH_EPOCHS` 按 `book_url` 键控、全局 fence 独立、容量 4096 且仅在满时清过期代（`web_book.rs:3555-3617`）；同书抢占测试 `test_toc_fetch_epoch_same_book_bump_cancels_inflight_chain`、他书不误杀测试 `test_toc_fetch_epoch_keyed_by_book_other_book_bump_does_not_cancel`。**注**：键控本身正确，问题只在“谁有权 bump/谁应被取消”，见 P2-1。
10. **Cookie 域键单一真源与跨层共享**：JS 写侧/读侧与 HTTP jar 共用 `legado_net::cookie_store::cookie_domain_key`（`legado-js/src/host_api/cookie_store.rs:1-30,420-451`）；FFI 注册共享 store（`http_state.rs:357-366,451-466`）与持久化后端；清除路径锁序 D→C→P（`http_state.rs:54-140`、`net_api.rs:95-160`）。**注**：跨层“可见性”仍有 P2-2 缺口。
11. **`queryTTF` 的 `file://` 预检与多字节 classify 修复**：先剥 `file://` 再 `resolve_read_path`，且在句柄缓存命中之前（`font_api.rs:153-171`）；`classify` 用 `as_bytes().get(1)` 避免多字节切片 panic（`:116-128`）；拒绝时返回 `valid=false`+`error`（`:220-230`）。测试含 `test_query_ttf_file_scheme_escape`（`quickjs_impl.rs` 测试段）与 permissive 对照。
12. **解析器异常边界（静态核验）**：JSONPath 空路径返回空、JSON 解析失败返回 `Err`（`jsonpath.rs:48-56,117`），无用户输入 `unwrap`；XPath 严格 XML 失败回退 html5ever→XHTML（`xpath.rs:168-182,294-305`），编译/求值错误返回 `Err`；HTML 选择器 `Selector::parse` 失败返回空/属性回退，`unwrap` 仅在 `is_err()` 分支之后（`html.rs:951-987`、`select_step` `:845-852`）。
13. **TXT 正文偏移安全**：`start/end` 先 `min(len)` 再 `floor_char_boundary`，负数 `as usize` 也被 clamp（`txt.rs:250-259`）；自定义目录规则编译失败回退内置规则（`:180-200`）；`parse_by_length` 单次前向扫描且切点落在字符边界（`:445-503`）。
14. **本地压缩包导入安全/限额**：ZIP 限额 512MiB/10000 条目/单条目 256MiB/总量 512MiB，声明值与实际读取双重计数，任一条目名非法整包拒绝（`legado-book/src/archive.rs:55-71`、测试段 `:1772-1870`）；`.part` 暂存 + 成功才落位 + 失败回滚（`:92-160`）；7z 同限额同落位（`:1560-1600`）。
15. **MOBI/EPUB 读取边界**：PDB 记录索引越界返回 `Err`，`record()` 对 start/end 双 clamp（`mobi.rs:113-130`）；EXTH/INDX/TAGX 头部均有长度检查（`:241,332,934,947,1127-1130`）；EPUB `read_zip_entry`/XML 解析返回 `Result`。
16. **v7a 无 QuickJS 降级**：`package.json`/CI 已按 P2-24 裁决（`flutter-release.yml:67-85`、`flutter-ci.yml:82-85`），属已登记决策，本轮不重复报告。

---

## 五、建议批次切分

| 批次 | 内容 | 合并/独立理由 | 依赖与门禁 |
|---|---|---|---|
| **批A（立即，安全）** | P0-1（pending header 作用域 + RAII）+ 回归两例 | 改动集中（`analyze_url.rs` + 1 个函数 + 测试），风险低、收益最高 | 无依赖；`cargo test -p legado-parser -p legado-fetcher`，补回环双源用例 |
| **批B（引擎语义，1 批）** | P1-2（cache 守卫）+ P2-9（EnginePool 清理）+ P2-7（RAII tag）+ P3-4/P3-6 | 都是 `legado-js`/`source_setup` 的小改；P1-2 与 RSS 已有实现对齐 | 需先定 §3.2 口径；`legado-js` quickjs 档测试 + capability 断言 |
| **批C（持久化，独立立项）** | P1-3（VariableSink 写穿 + 回填 + 裸键作用域） | 跨 `legado-js`/`legado-ffi`/`legado-db` 三层，需新 trait 和 DB 写路径；影响备份/恢复，必须独立设计 | 依赖 §3.2 裁决；加“写→重启→读”“备份→清库→恢复”往返测试 |
| **批D（文件 API，独立立项）** | P1-1（FsPolicy 化重开 + 宿主注入 sandbox root + 文档/能力清单） | 安全边界变更，需单独安全审查与设备验收；与 P2-3/P3-1 同域 | 依赖用户确认“重开 vs 删文档”；补受限/宽松双模式用例与真机回归 |
| **批E（书源校验，1 批）** | P1-4 + P1-5 + P3-7（改成 fetcher 规则级 + 超时/取消） | 同一模块、同一契约面；改完需同步 `book_source_check_states` 状态与 UI 文案 | 依赖 §3.4 裁决；server legacy 实现可复用；补“卡住请求取消”“JS/POST 源”用例 |
| **批F（网络/Cookie，独立立项）** | P2-2（逐跳 Set-Cookie + 单罐收敛）+ P2-1（epoch 取消语义） | Cookie 涉及 `legado-net`/`legado-js`/`legado-ffi` 三处与登录链；epoch 涉及 fetcher/ffi 两条链；都与“读链路正确性”相关但可分开 | P2-2 需设计评审（重定向拦截方式）；P2-1 需 §3.1 裁决 |
| **批G（性能/内存，1 批）** | P2-3、P2-4、P2-6、P2-5、P2-8 | 均为局部可独立验证的性能/资源修复；P2-5/P2-8 属语义修正可同批 | 各自补基准或回归（字体缓存容量、TXT 大文件耗时/内存、并发搜索不被 init 阻塞） |
| **批H（卫生，可搭车）** | P3-2/P3-3/P3-5/P3-8 + P3-1 | 低风险；P3-1/P3-8 与解压安全相关，建议随批D 或批G 一起 | 无 |

**不建议合并的原因**

- P1-1（文件 API）与 P1-3（持久化）都触碰“安全/数据可信”，但前者是能力开关/路径策略，后者是存储层新增，混批会放大回滚面。
- P1-4（校验语义）会改变 `book_source_check_states` 的结果分布，必须与 UI/清源逻辑同批验收，不能搭车性能批。
- P2-2（Cookie）与 P2-1（取消）都涉及“请求边界”，但修复点分别在 `client.rs` 的响应捕获与 `web_book.rs` 的 epoch 判定，独立立项更易定位回退。

---

## 六、覆盖边界与未审查项（诚实声明）

- 未做运行时复现：遵守 `BRIEF.md` 的只读约束，本轮没有执行 `cargo test`、没有设备验收；P0/P1 的触发条件基于代码路径推演，建议主代理按各条的“回归用例”实跑后再登记关闭。
- 未逐行审查：`legado-js/src/js_source/js_source_review.rs`、`js_source_marshaller.rs`、`js_source_upsert.rs`、`host_api/{asymmetric_crypto,symmetric_crypto,message_digest,encoding,query_ttf,html_parse}.rs` 的算法正确性（仅做了 panic/边界 grep）；`legado-net/{rss,webdav,direct_link_upload,rule_update_client,remote_book}.rs`；`legado-book/{pdf,umd,cbz}.rs` 的格式语义；`legado-server` 的 Web 阅读链。
- 依赖源码核对仅覆盖 `sevenz-rust2 0.24.1`、`zip 2.4.2`、`reqwest 0.12.28` 的关键路径；其余 crate（`rar 0.4.0`、`quickjs-ng`）未审计内部实现，仅核对我方调用边界。
- `capability_ledger` 与 `Packages` shim 的覆盖完整性属另一条审查线（能力对账），本报告未展开。

---

审查：ZCode 代码审核员（只读） ｜ 2026-11-13
