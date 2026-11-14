# API 契约文档（BookApi 接口基准）

**日期**: 2026-08-01
**版本**: v1.0
**维护人**: Legado 开发团队

**更新记录**：

| 日期 | 内容 |
|------|------|
| 2026-11-15 | **批33 文件 API 生产化与沙箱隔离（宿主 API 语义重大变更，零 FFI 方法/签名变化）**：①**上游同名文件 API 在生产环境恢复可用**——此前 `allow_file_access=false`（生产默认）时 `register_file_apis` 完全不注册，`readFile`/`getFile`/`readTxtFile`/`getTxtInFolder`/`deleteFile`/`downloadFile`/`cacheFile`/`importScript` 全部 `undefined`，与随包 `jsHelp.md` 及上游「限域在 externalCache 而非禁用」语义矛盾；现 8 项**始终注册**，路径统一经 `FsPolicy` 限域。②**非原版能力维持 gated**：`writeFile`/`fileExists`/`downloadFile(url,fileName)` 二参重载上游 `JsExtensions.kt` 中不存在（红线），仅 `allow_file_access=true`（调试/可信脚本）注册；生产调用 `downloadFile(url,fileName)` 返回 `[ERROR] ... 非原版 API ...` 且不联网（**函数本身仍存在**，`typeof` 探测不能作为可用性判据，帮助文档已注明）。③**沙箱按书源隔离**：根目录由进程级共享改为 `js_files/<SHA256(source_tag)[:16]>/`（无 tag 落 `_shared`），修复 A 源可 `getTxtInFolder(".")` 遍历/污染 B 源下载文件的跨源问题；分页正文 JS 此前硬编码空 tag 落 `_shared`（生产路径隔离缺口），现绑定本源 tag。④**路径安全**：读路径返回 canonical 目标（含 Windows `\?\` 剥离），写路径拒绝已存在的符号链接/junction 末段；`../`/绝对路径/UNC/verbatim/设备前缀/驱动器相对路径均拒绝，canonicalize 失败 fail-closed（审查逐项实证，无沙箱逃逸）。残留 TOCTOU 窗口（canonical 化与 IO 之间）已登记：生产 JS 面无创建链接能力，不可由书源利用。⑤**下载按原始字节落盘**：此前 `downloadFile`/`cacheFile`/`importScript(http)` 经 `response.text()` 解码再 `into_bytes()`，**非 UTF-8 字节全变 U+FFFD**（`downloadFile`+`unzipFile` 典型用法直接失效）；现新增 `LegadoClient::get_bytes_capped`（复用 `send_stream` 逐块累计、`Content-Length` 快速拒绝、超限中止），按字节写盘。⑥**资源上限**：单文件读取/下载 **32MB**、`getTxtInFolder` 累计 **64MB**，超限显式报错（此前无上限，书源可令进程 OOM）。⑦**`cacheFile` 映射值改源内相对名**（键仍为上游可见的裸 `md5(url)`，保留书源 `cache.get(md5(url))` 可读语义），消除多源共享同一 URL 时的缓存互相顶掉与绝对路径泄露。⑧**两份 `jsHelp.md` 同步**（`rust/assets` 与 `flutter_legado/assets`，后者是用户实际看到的帮助）：限域根、跨源不可见、上限、原始字节落盘口径一致。⑨**顺带修复既有 P1**：`WebChapter.is_vip` 缺 `#[serde(default)]` 致书源调试正文路径（`--<chapterUrl>`）反序列化失败整链不可用；调试章节 JSON 改由 `WebChapter::new` 类型化构造序列化（未来新增字段不再击穿）。**消费方影响**：依赖文件 API 的书源（下载音频/图片/字体、`importScript` 远端 JS、读文本）从「生产报错」恢复可用；沙箱目录结构变化使旧绝对路径持久化值失效（书源若持久化 `downloadFile` 返回值，缓存目录迁移后需重下）。 |
| 2026-11-14 | **RSS 登录检测错误归类（宿主语义收紧，零方法/签名变化）**：RSS 源登录检测原把执行错误**压平成 `String`**，jsLib 求值失败时用户看到「RSS 源需要登录（… jsLib 求值失败: …）」——误导文案，与书籍源 loginCheckJs（批29 已区分 `JsLibUnavailable` → `LegadoError::JsEngine`）不一致。现 `rss/login.rs` 的 `apply_success_check`/`apply_error_check` 改返回 `LoginCheckEvalError`，`gate_login` 将 jsLib 前置加载/求值失败映射为 `LegadoError::JsEngine`（保留根因），**仅 checkJs 判定未登录**才返回 `LoginRequired`；「jsLib 求值失败」前缀识别抽为 `legado-js::login_check::classify_login_check_exec_error` 单一实现，书籍源与 RSS 链路共用（避免两处硬编码字符串漂移）。登录成功/失败/需要登录的判定语义不变，仅错误归类改变。 |
| 2026-11-13 | **批30 资源上限与错误可见性（宿主 API 行为收紧，零方法/签名变化）**：①**字体句柄缓存改 LRU(4)**——`HANDLE_CACHE` 原为无上限 `HashMap`，逐章换字体（常见反爬）会让进程内累积 N 份字体串（每份含完整 `data` 回显），对齐上游 `CacheManager.queryTTFMap = LruCache(4)`；`data` 字段保留（唯一消费方 `resolve_font` 在解析 LRU 未命中时需用它重载，JS 侧句柄为字符串无法持对象）。②**压缩包解压资源上限**——新增单条目 **32MB** / 总量 **512MB**（与 `theme_package_service.dart` 主题包口径逐字一致），超限返回明确错误、**不返回截断数据**；`unzip_file` 改流式落盘 + 声明值与实际字节双重校验；RAR5 预扫描改流式（只读块头 + 按 DataSize seek 跳过数据区，不再整包入内存）；`read_file_magic` 只读前 512B；**7z 整包解压补齐同口径限额**（`ArchiveReader::for_each_entries` 逐条目 + 声明总量前置拒绝 + 实际字节复核，此前 7z 路径完全无上限即可被压缩炸弹打穿）；失败路径统一 RAII `ExtractionGuard` 清理（只删本次创建的文件与最上层目录，不误删用户已有目录）。③**`GET /api/sources/check*` 批量校验维持逐源客户端**（不改行为，仅加注释）——共享进程级客户端会让同域书源的会话 Cookie 串用（我方读侧 Cookie 注入无条件，写侧才受 `enabled_cookie_jar` 门控），校验结果会随批量顺序/并发度变化；逐源客户端把 Cookie 生命周期限制在单次校验内，20 个连接池成本低于跨源凭据串用风险。④**UI 侧错误可见性**：183 处用户可见文案由裸 `$e` 改为 `errorMessage(e)`（此前会显示 `Instance of 'BridgeError'`），日志保留原始异常；新增静态守卫测试（扫描 screens/widgets/providers/services，regex 覆盖 `$e`/`${e}`/`$err`/`$error`/`$ex`/`$exception`，日志按调用括号范围豁免）；书架开书加按 `bookUrl` 重入保护（防双击压入两个阅读器）；远程书库与自动任务批量导入改成功/失败分列（含早退路径清空上次结果，避免配置错误显示成「成功导入 N 本」）；`errorMessage` 不再把引擎/WebView 的执行超时误映射为「网络连接超时」。 |
| 2026-11-13 | **批29 引擎语义修复（宿主 API 语义收紧，零方法/签名变化）**：①**引擎缓存不再持全局锁初始化**——`get_or_create_with_timeout` 原在进程级 Mutex 内 `init_engine`（eval jsLib/setup/mainJs，jsLib 顶层 `java.ajax` 可阻塞至网络超时），期间**所有源的引擎查找（含已缓存 key 的快路径）排队**，一个源首次建引擎即拖住全局搜索/阅读；改为「短锁查表 → 锁外构建 → 写锁复查装入」，并发同 key 构建先装入者胜出。②**书源上下文 tag 改 RAII**——`with_current_source_tag` 原仅在闭包正常返回后恢复，panic 时跳过恢复，tokio blocking 线程复用后 tag 残留，导致后续请求的 `global_headers`、验证码钩子、cookie 写侧门控**错源**。③**删除 `EnginePool`**（无生产调用点，池满淘汰非 LRU、`lock().unwrap()` 中毒即 panic）；`source_engine` 的池化执行分支保留，中毒改为恢复。④**JS 书源 URL 映射形态 jsLib 现可解析**——`JsSourceEngine::new_quickjs` 原直接把 URL 映射 JSON 当 JS eval，必然 `jsLib 求值失败`；现先 `parse_js_lib_url_map` 探测并复用 `resolve_js_lib_url_map_with_status`，降级语义与普通规则源 `executor.rs` 同构（单条失败跳过并记台账，全失败不 eval 原始 JSON）。⑤**`loginCheckJs` 补齐执行上下文**——原只注入 `result`，未加载 jsLib/setup、不绑定 `source`/`cookie`/`cache`（上游 `analyzeUrl.evalJS` 两者都挂载），故 checkJs 引用 jsLib 函数或 `source.getVariable()` 会 `ReferenceError` → `JsFailed` → 整源失败；现与规则执行器同构构造，**登录判定三叉点与 `code 500` 二次判定语义不变**。⑥**自定义 CA PEM 解析失败改为显式错误**——现 `SslConfig::apply` 返回 `LegadoResult<ClientBuilder>`，以 `Certificate::from_pem_bundle` 显式校验 PEM armor/base64 与证书段非空，解析失败即返回 `LegadoError::Network`（客户端构建期 fail-fast；`LegadoClient` 惰性构建，坏 CA 不阻止 App 启动）。**旧行为澄清（审查 P3-2 更正）**：本仓仅启用 `rustls-tls`，reqwest 的 `Certificate::from_pem` 在该后端只缓存原始字节，故旧代码的 `log::warn` 分支实际不可达——非法 PEM 本就会在 `ClientBuilder::build` 的根证书解析处失败。真正由「静默」变为「显式」的是「PEM 结构合法但无 CERTIFICATE 段」（如误配私钥 PEM）这一子集；DER 级非法仍在 build 期失败（错误文案较泛）。另注：`SslConfig` 目前无生产接线（`http_state::shared_client` 用默认配置），将来接线时应在设置保存/FFI 入口预校验并给用户可见提示，避免坏 CA 使进程级共享客户端整体构建失败。 |
| 2026-11-13 | **批28 安全修复：URL 规则窗口请求头改为 RAII 作用域（宿主 API 语义收紧，零方法/签名变化）**：`java.headerMap.put(k,v)`（宿主桥 `push_pending_request_header`）此前写入**无 owner 的线程局部 `Vec`**，`parse_with_js` 入口不清理陈值、且只有**成功路径**才 `take`（JS 失败与 `parse` 失败两条 `Err` 路径直接返回，未清空）。后果：书源 A 在 `searchUrl` 的 `@js:` 中写入 `Authorization` 后脚本报错 → 同线程随后处理书源 B 的成功解析 → **A 的认证头被发给 B 的域名**（凭据泄漏到第三方站点），非凭据头亦造成他源 403/签名失败。现改为 **`UrlWindowGuard`（RAII）**：① 根窗口入口先 `take` 丢弃陈值并告警；② 成功路径显式 `take` 后 `finish`；③ `Drop` 统一覆盖 `Err` 与 panic 退出（清本层 pending + 恢复外层快照 + 恢复进入前 `CURRENT_URL` + 深度−1）；④ 仅 URL 窗口开启（depth>0）时接受写入，jsLib 顶层 / `source` evalJS / init 等**窗口外写入直接丢弃并告警**（对齐上游「无 AnalyzeUrl 上下文即无 headerMap」）；⑤ 嵌套窗口用深度栈隔离（生产无嵌套调用路径，作为防御设计）。告警只打印键名不打印值，避免凭据落日志。**消费方影响**：书源需在 URL 规则 JS 内写请求头才生效（本即上游语义），窗口外写入从「静默污染下一请求」变为「丢弃 + 告警」；无 FFI/Dart 面变化。 |
| 2026-11-13 | **批27 安全与数据回修（无鉴权出站面收口 + 划线备份往返）**：①`PROTECTED_SOURCE_WRITE_ROUTES` **27→33**，新增 6 条方法级表项 `POST /api/rss/articles`、`GET /api/rss/{source_url}/articles`、`POST /api/tts/speak`、`POST /api/audio/speak`、`POST /api/bookshelf/update-toc`、`POST /api/bookshelf/update-toc/single`——此前这 6 条无鉴权且服务绑 `0.0.0.0`，同 LAN 攻击者无需令牌即可把设备当出站代理，其中 `tts/speak`/`audio/speak` 由 body 的 `engine_url` 控制目标并**把响应体原样回传**（完整响应外带），`rss/*` 走默认 `accept_invalid_certs=true` + 跟随 20 跳。②`route_pattern_matches` 由「仅支持末段 `{id}`」改为**按 `/` 分段、占位符段匹配任意单段非空、其余段精确相等、段数一致**——旧实现对中段参数（`/api/rss/{source_url}/articles`）永不命中即**静默失效**；新增结构测试「每条表项必须命中至少一个 routes.rs 已注册路由样例」，杜绝未来中段参数漏保护。③`Some("GET")` 同时覆盖 `HEAD`（axum `get()` 自动服务 HEAD，防 HEAD 绕过；OPTIONS 预检不受影响）。④`/api/bookshelf/update-toc*` 并发上限由「仅 `.max(1)` 无上限」收敛为 `clamp(1, 9)`（`TOC_UPDATE_MAX_CONCURRENT=9`，依据上游 `AppConst.MAX_THREAD=9`、`MainViewModel` 批量目录池口径），修掉「未鉴权 + 无上限并发 = 出站放大器」。⑤`book_marks` **纳入备份/恢复链**：自有 JSON 备份格式 `BACKUP_VERSION` **5→6** 新增 `bookMarks` 段（12 列 camelCase，空表写空数组，旧备份缺键默认空数组不清库），zip 恢复白名单 22→23 增 `bookMarking.json` 并映射 `book_marks`（`INSERT OR REPLACE` upsert、缺 id 补 UUID、空 `anchorJson` 跳过并 warn）。**推翻批7b-1「与参考版一致不纳入备份」的旧登记**——参考版实际含该能力（`legado-with-MD3` `Backup.kt:71,158` 写出 `bookMarking.json`、`Restore.kt:163-165` 读回 `bookMarkingDao.insert`，能力自 `488a375`/2026-09-28 起，早于批7b 立项），旧前提有误，故按真缺陷修复而非仅加提示。⑥备份数据类计数 19→**20**（§2.40 口径）；`RestoreStats` **不计** `book_marks` 条数（维持既有 FFI 返回结构）。消费方影响：仓内 Flutter（走 FFI）与 `web-dist` 对上述 6 条路由零调用，加守卫不打断自有功能；外部脚本需补 `x-legado-token`。FFI 方法计数不变（无新增导出）。 |
| 2026-11-13 | **P2-1/P2-2/P2-3 回修**：①`POST /openLegacyReview`、`POST /runLegacyReview` 纳入 `PROTECTED_SOURCE_WRITE_ROUTES`（23→25，裸路径对齐上游 `HttpServer.kt:251-265`）——此前仅 handler 内校验，而 axum 提取 body 早于 handler，未授权请求仍会缓冲请求体；现未授权在读 body 前拒绝（失败信封 + `Connection: close`），handler 内校验保留为纵深防御；`GET /legacyReviewPage`（nonce 即凭据）保持免令牌。②契约门禁新增第 7 项：解析 `rust/legado-ffi/src/ffi.rs` 的 `pub fn`/`pub async fn` 面与 `bridge/ffi/ffi.dart` 顶层 wrapper 做双向差集（允许名单集中定义，当前均为空），实测 **Rust 328 unique / Dart 328 / 差集为空**，为 FFI 面扩张提供可重复 CI 门禁（此前无此边，新增导出未 codegen 也能编译通过）。③`.github/workflows/rust-ci.yml` 的 quickjs clippy 档补 `-p legado-fetcher`，与同文件 quickjs test 档对齐。 |
| 2026-11-13 | **P1 回修（批24）**：①`POST /api/rule-update/check` 与 `POST /api/rule-update/apply` 纳入 `PROTECTED_SOURCE_WRITE_ROUTES`（21→23，方法级；`GET /api/rule-update/subs` 仍公开只读）——P1-3 让 apply 真正落库后，未鉴权即可覆写三张规则表；`legado-net::rule_update_client` 与 `source_update::check_updates` **移除 `danger_accept_invalid_certs(true)` 恢复默认证书校验**（防 MITM 内容落库）。②`PUT /api/sources/{id}` 改为**部分更新**：仅写入请求体出现的键，未出现保持原值；`book_source_url` 缺省沿用 path；`book_source_group`/`search_url`/`concurrent_rate` 支持「缺省不动 / null 清空 / 有值写入」三态。③订阅应用改为**按 `lastUpdateTime` 逐条门控**（对齐上游 `RuleUpdate.kt:41-47`）：仅当 `remote.lastUpdateTime > local.lastUpdateTime` 才覆盖，否则保留本地 `variable`/`header`/`jsLib`/名称/comment；双方均无时间戳时已有条目不覆盖。④订阅版本口径改为 `<max(lastUpdateTime)>-content-<16hex>`（无时间戳纯指纹），修复混合订阅内容变更未 bump 时间戳时 `hasUpdate=false` 永不应用；现有订阅升级后首次 check 会因格式变化报一次「有更新」，应用后稳定。⑤内网拒绝集合补 `100.64.0.0/10`（含 `100.100.100.200` 元数据）/`192.0.0.0/24`/`198.18.0.0/15`/`240.0.0.0/4`。 |
| 2026-11-13 | **P1-1/P1-2/P1-3 安全与数据修复**：①`/api/sources` 写面（POST/PUT/DELETE）与 `/api/sources/update` 纳入 `PROTECTED_SOURCE_WRITE_ROUTES`（17→21，方法级匹配；GET 读取面免令牌）；`POST /api/sources` 对已存在 URL 返回 **409** 不再 `INSERT OR REPLACE` 整行覆盖（防清空规则/jsLib/variable），`PUT` 未命中返回 **404**、body URL 命中他行返回 **409**；`repo_url` 仅 http/https 且拒绝内网/保留地址、重定向逐跳校验、恢复默认证书校验。②`GET /getBookSourcesForManagement`、`GET /getBookSourceCheckStates` 由「无令牌」改为**受保护读面**（须 `x-legado-token`，失败信封 + `Connection: close`，成功与失败均带 `Cache-Control: no-store`）。③规则订阅「应用更新」由「仅写版本号」改为**真正 upsert 落库**（`book_sources`/`rssSources`/`replace_rules`，单一实现 `legado-db::apply_rule_subscription`，FFI 与 Web 共用），**仅新增与更新、不删除本地条目**（对齐上游 `RuleUpdate.kt`；`itemsRemoved` 恒 0），版本号与最后更新时间在事务最后一步写入、失败整笔回滚、空数组拒绝；检查更新版本标识改为 `legado-net::extract_subscription_version`（对象取 `version`、数组取最新 `lastUpdateTime`、无时间戳用内容指纹）+ `has_subscription_update` 统一判定。消费方影响：仓库内 Flutter/`web-dist` 无 `/api/sources` 调用，外部脚本需补令牌、重复创建改用 PUT。 |
| 2026-11-13 | **P0-1 安全修复：`/api/webbook/*` 四条纳入令牌守卫（行为收紧）**：`POST /api/webbook/{search,info,chapters,content}` 自本批起纳入 `PROTECTED_SOURCE_WRITE_ROUTES`（13→17）。请求须携带 `x-legado-token`（大小写不敏感）且与 `config:jsSourceApiToken` 字节级相等；未配置令牌（默认 `jsSourceApiTokenRequired=true`）或头缺失/不等时返回原版失败信封（HTTP 200，`isSuccess=false`、`errorMsg="Web 书源访问令牌未配置或不正确"`、`data=null`）+ `Connection: close`，且**不读取请求体、不执行书源 JS**。显式 `config:jsSourceApiTokenRequired=false` 时维持既有免令牌放行语义（与源写端点、Web 端口 `/mcp/call` 一致），首次命中记 `warn` 日志。消费方影响：仓库内 Flutter 走 FFI `webbook*` 不受影响，`web-dist` 无调用方；外部自建脚本需补 `x-legado-token`。路由、请求/响应 schema 均不变。 |
| 2026-11-11 | **TTS P3 与 `/mcp/call` 鉴权口径回销（纯文档澄清，无新增方法、零 FFI 签名变化）**：§2.22 更正「Web 端口 `/mcp/*` 兼容不变」的旧表述——批17 起 Web 端口 `/mcp/call`（POST）已纳入 `PROTECTED_SOURCE_WRITE_ROUTES`，请求须携带 `x-legado-token`（大小写不敏感）且与 `config:jsSourceApiToken` 字节级相等，未配置令牌（默认 `jsSourceApiTokenRequired=true`）时一律拒绝；Web 端口 `/mcp/tools`（GET）免令牌；独立 MCP 端口鉴权与行为不变。方法计数与附录合计均不变。 |
| 2026-11-12 | **批20：图片 click/js action 执行通道 + Web/App 净化语义统一（契约先行，加法式 +1 方法）**：§2.21 新增 `evalImageAction(String bookUrl, int chapterIndex, String action, String imgSrc)`（Rust `legado-ffi/src/api/image_action_api.rs` + `ffi::eval_image_action`）：按参考版 `ReadBookController.kt:677-695` 语义执行书源 `<img>` 上的 `click`/`js` 动作——绑定 `source`（书源 JSON）、`book`（name/author/bookUrl）、`chapter`（title/index/url/bookUrl）、`result`（imgSrc）、`baseUrl`、`java`（`log/t2s/s2t/get/put`）；复用 `legado-js` 的 QuickJS 执行器与 `legado-js::replace_rule_js` 的绑定构造风格（**不新增第二份执行器**）；`@js:` 抛错/超时返回原文/空串并记日志、不 panic；无 quickjs 构建返回明确错误。同时**统一 Web 与 App 正文净化的配置面与作用域面**（用户 2026-11-12 裁决「统一到 App 侧」）：Web `purify_content` 改为读取与 App 相同的持久化配置（`sameTitleRemoved`/`chineseConverterType`/`reSegment`/`replaceEnableDefault`），`scope` 匹配统一为 App 的「按 `[,;，；]` 拆分 + 书名精确匹配」语义（`excludeScope` 在两端均不参与正文路径，登记差异消除）。方法模块保持 **50**，附录合计 339→**340**，BookApi 337→**338**，§1.7 表 B 173→**174**（等价对总数 189→**190**）。 |
| 2026-11-10 | **批12：替换规则排序与作用域写链路（契约先行，加法式 +1 方法 + 1 方法扩参）**：§2.8 新增 `reorderReplaceRules(List<int> ids)`（Dart 侧签名；FFI `replace_rule_reorder(String idsJson)`，Rust `legado-db::ReplaceRuleRepository::reorder` + `legado-ffi/src/api/replace_rule_api.rs` + `ffi::replace_rule_reorder`），语义对齐既有 `dictRuleReorder`：入参 JSON 数组为**全量**规则 id 顺序，单事务内重编号 `sortOrder=0..n-1`，返回重排条数；**重复 id / 缺失 id / 未知 id 一律 Err 且零写入**（防筛选态子集重排打乱隐藏规则）。同时 `updateReplaceRule` 的 FFI 扩参 `scope: Option<String>`（未提供=保留既有值），修复「特定范围编辑不落库」（原 FFI 无 scope 参数、Rust 强制沿用 `existing.scope`）；`addReplaceRule` 的 `sortOrder` 改为 `max+1`（原硬编码 0，重排后新规则会顶到最前；不改方法计数）。DB `SCHEMA_VERSION` 保持 119（`replace_rules.sortOrder` 自基线存在，无需迁移）。方法模块保持 **50**，附录合计 338→**339**，BookApi 336→**337**，§1.7 表 B 172→**173**（等价对总数 188→**189**）。 |
| 2026-11-10 | **批9d：生物识别快捷解锁（契约先行，加法式 +4 方法）**：§2.53 新增 `privacyBiometricStateGet` / `privacyBiometricSet` / `privacyBiometricVerify` / `privacyBiometricClear`（Rust `legado-ffi/src/api/privacy_api.rs` + `ffi::privacy_biometric_*`）。**安全设计（偏离参考版并登记）**：平台 Keystore/Keychain 只封装 **32B 随机解锁令牌**（由 Dart `Random.secure()` 生成标准 Base64；Android IV 由 Keystore Cipher 生成，iOS `SecRandomCopyBytes` 仅生成契约占位 IV），**不封装明文密码**（参考版 `PrivatePasswordCipher.kt` 封密码）；令牌摘要（SHA-256，Base64）存 caches `config:private_biometric_token_hash`，信封/IV 存 `config:private_biometric_envelope` / `config:private_biometric_iv`；`stateGet` 只返回 `configured/envelope/iv`，**绝不返回摘要或令牌**；`set` 要求已有密码、token Base64 恰 32B、iv 恰 12B、envelope 1..4096B，单事务覆盖三键；`verify` 常量时间比较摘要；`clear` 删除三键。`privacySetPassword` 成功改密与 `privacyClearPassword` 在同一事务内清空三键（改密即失效生物快捷；参考版「同密码保留信封」不适用令牌模型，登记差异）。方法模块保持 **50**，附录合计 334→**338**，BookApi 332→**336**，§1.7 表 B 168→**172**（等价对总数 184→**188**）。 |
| 2026-11-09 | **批9a：隐私与私密标记数据层（契约先行，加法式 +8 方法）**：新增 §2.53 8 方法 `privacyHasPassword` / `privacySetPassword` / `privacyVerifyPassword` / `privacyClearPassword` / `setBooksPrivate` / `getPrivateBookUrls` / `setBookGroupPrivate` / `getPrivateGroupIds`（Rust `legado-ffi/src/api/privacy_api.rs` + `ffi::privacy_*`，密码凭据落 caches `config:private_password_salt` / `config:private_password_verifier`，DB `SCHEMA_VERSION` 118→119 为 `books` / `book_groups` 增 `isPrivate` 列）。**语义按参考版** `PrivatePasswordCipher.kt`（PBKDF2WithHmacSHA256 210000 次 / 32B verifier / 16B salt，**不存明文**）与 `BookDao.kt:1191-1213`、`BookGroup.kt:27`；`privacySetPassword` 已有凭据时必须校验旧密码，`privacyVerifyPassword` 常量时间比较；`setBooksPrivate` 入参为 JSON 数组并事务批量 `UPDATE`，返回实际更新行数；列表类返回裸 JSON 数组（书 URL 稳定排序 / 分组 ID 升序）。本批仅数据层/FFI/Dart API/Mock，**不做 UI、路由与平台生物识别**。方法模块 49→**50**，附录合计 326→**334**，BookApi 324→**332**，§1.7 表 B 160→**168**（等价对总数 176→**184**）。 |
| 2026-11-09 | **批7b-1：书签标记（book_marks）数据层（契约先行，加法式 +5 方法）**：§2.52 新增 5 方法 `getBookMarkingsByBook` / `getBookMarkingsForChapter` / `saveBookMarking` / `deleteBookMarking` / `setBookMarkingEnabled`（Rust `legado-ffi/src/api/book_marking_api.rs` + `ffi::book_marking_*`，数据落新增 `book_marks` 表，DB `SCHEMA_VERSION` 117→118）。**语义按参考版** `BookMarking.kt:21-46` / `BookMarkingDao.kt:13-87`：`id` 为 String 主键（空则 Rust 生成 UUID v4）、`bookName`+`bookAuthor` 跨源关联、`chapterIndex` 可空、`anchorJson` 必填、`styleJson` 可空；按 `bookUrl` 查章时 SQL 同时允许 `chapterIndex IS NULL`；`enabled` 默认 true，`save` 恒写 `updatedAt` 为当前毫秒。**与参考版一致不纳入备份**（§2.52 注登记）。本批仅数据层/FFI，划词卡、编辑 Sheet、目录笔记页与正文渲染属 7b-2。方法模块 48→**49**，附录合计 321→**326**，BookApi 319→**324**，§1.7 表 B 155→**160**（等价对总数 171→**176**）。**审查 P3 注记**：`book_marks` **无外键**（参考版 `BookMarking` 实体未声明 ForeignKey，本实现同）；FFI 仅校验 `anchorJson` 非空，`anchorJson`/`styleJson` 的内容解析属 7b-2 渲染层。 |
| 2026-11-06 | **批6a-1 设备修复：BookGroup.group_id 位掩码语义（零签名/方法计数变化；契约先于代码）**：① `addBookGroup` 新建 ID 改为**最小未占用 2 的幂**（`1,2,4,…`，上限 `1<<30`；Rust `BookGroupRepository::get_unused_id`，对齐原版 `BookGroupDao.getUnusedId`），不再使用 SystemTime 毫秒；`books.group` 以位掩码表达一本书属于多个分组，ID 必须是 2^n。② **兼容层**：存量时间戳/任意非 2^n ID **不迁移**；Dart 过滤按混合语义——`groupId` 为 2 的幂时 `(book.group & groupId) != 0`，非 2 的幂时 `book.group == groupId`（exact），`BookGroup.IdAll=-1` 等特殊组保持既有分支。③ 旧客户端/旧备份仍可读写 groupId；新建组在旧客户端按 exact 匹配只命中自身（位掩码多组语义仅在升级后生效）。 |
| 2026-11-03 | **批9b-3 回修：窗口必需集与复合 URL（零方法计数变化；契约先于代码）**：① **窗口必需集**——当前章（`index == durIndex`）必须有非空 `cached_chapters` 正文，缺失/空白或当前章为卷章 → 整次跳过；后窗（`index < durIndex`）章节缺失正文 → **整次跳过**（保守，避免删除未缓存章节图片；登记「阅读早期可能跳过清理」，随阅读推进后窗补齐后自然生效）；前窗（`index > durIndex`）章节缺失正文 → **仅跳过该章**，不再整跳（默认 `preDownloadNum=10`、漫画只预载 ±1 时前窗大量缺缓存，原实现会导致每次整跳）；卷章 `is_volume` 一律跳过（不要求正文、不贡献图片）。② **复合 URL**——`<img src>` 解析对齐原版 `AppPattern.imgPattern` / Dart `comicImgSrcRegex` 四分支，完整保留 `url,{json headers}` 尾（单/双引号均支持），line fallback 剥 `,{json}` 判后缀；保留文件名与阅读器缓存键一致。③ **首图**——每章 `chapter.imgUrl`（阅读器作为首个图片页）纳入保留集合。④ **SQL 窗口查询**——新增 `CacheBookRepository::get_by_book_index_range`，只取窗口行，不再整书装载正文。⑤ **差异/竞态登记**——Rust `AnalyzeUrl`（协议相对按 base scheme、保留端口）与 Dart `_resolveImageUrl`（协议相对恒 https、`Uri.host` 丢端口）仍存在极端 URL 解析差异，本批不改阅读器缓存键，后续统一；清理与相邻章预载的竞态已由「只执行最后一次排队任务」+ 后窗/前窗保护覆盖，本批不加延迟去抖（登记）。方法计数：§2.46 **3**、附录合计 **321**、BookApi **319**、§1.7 表 B **155**（等价对总数 **171**）全部不变。 |
| 2026-11-03 | **批9b-3：漫画图片保留数真正生效（契约先行，加法式 +1 方法）**：§2.46 新增 `retainComicImages({bookUrl, durIndex, retain, preDownload}) → Future<int>`（Rust `ffi::retain_comic_images` → `legado-ffi/src/api/image_cache_api.rs::retain_comic_images`），对齐原版 `BookHelp.clearComicCache`（`app/src/main/java/io/legado/app/help/book/BookHelp.kt:204-235`）：保留窗口 `[durIndex-retain, durIndex+preDownload]`，取窗口内 `cached_chapters` 正文解析 `<img src>`、按章节 URL 绝对化后以 `md5_16(url).suffix` 组成保留集合，删除本书 `images/` 下不在集合内的直接子文件。**安全性加法式收紧（与原版差异登记）**：① `retain<=0` / 非图片书 → 不清理；② 窗口内任一章节缺缓存正文或正文空白 → **整次跳过**（原版逐章 `getContent` 为 null 时仅跳过该章，可能误删未缓存章节图片）；③ 窗口解析出的保留集合为空 → 整次跳过；④ 仅删普通直接子文件（不递归、不跟随符号链接）。**Dart 接线**：漫画阅读器打开/翻章成功后读取 `imageRetainNum`（默认 **0**=不清理，0 不调 FFI）与 `preDownloadNum` 调用；同书同索引去重、失败静默。**偏好**：`imageRetainNum` UI 默认 100→**0**（仅改默认，存量保留），范围 0..999，副题标注 0=不清理；随既有 `appPrefs` 备份/恢复往返（参考版 `BackupConfig` 未将其归入 readPrefKeys，任何忽略组合下均往返）。方法计数：§2.46 2→**3**，附录合计 320→**321**，BookApi 318→**319**（304 同名行 + 14 命名等价 + 1 别名），§1.7 表 B 154→**155**（等价对总数 170→**171**）。 |
| 2026-10-31 | **批9b-4：UserAgent 设置全局生效（零新增 FFI 方法/签名变化；§2.10 `setConfig`/`getConfig` 行为补充，契约先于代码提交）**：设置页「用户代理」（偏好键 `userAgent`，留空=默认）此前仅 RSS 文章 WebView 消费；本批让所有**未显式设置 UA** 的网络请求回落到用户全局 UA。**语义基准（原版/参考版一致）**：`legado-upstream/app/src/main/java/io/legado/app/help/http/HttpHelper.kt:70-77` 请求拦截器——`request.header(UA_NAME) == null` 时补 `AppConfig.userAgent`、值为 `"null"` 时移除；`AppConfig.kt:48,135,918-925` 偏好变更即时更新、空白回落桌面 Chrome 默认；`AnalyzeUrl.kt:801` / `BaseSource.kt:215` 书源 header 未配 UA 时回落全局。参考版同点：`HttpHelper.kt:98-104`、`AppConfig.kt:75`、`FeatureSettingsRepositories.kt:159-163`。**优先级**：书源/规则/接口显式 `User-Agent`（键名大小写不敏感）> 用户全局 UA > 内置默认（`legado-net/src/client.rs:49` `DEFAULT_USER_AGENT`）；全局值为空/纯空白视为未设置并回落内置默认。**Rust 架构（无新 FFI 方法）**：`legado-net/src/user_agent.rs` 新增进程级 `RwLock<Option<String>>` 覆盖（`set_default_user_agent` / `default_user_agent`）；`LegadoClientConfig::default().user_agent` 保持内置常量作为「未显式定制」哨兵，`LegadoClient` 统一请求出口 `apply_headers_and_cookies` 在调用方头无 UA 时由 `request_default_user_agent` **请求期**解析（显式定制 `config.user_agent` > 进程级全局 > 内置默认；默认配置即全局）——对齐原版 OkHttp 拦截器；已构建共享客户端/JS 桥池无需重建即即时生效，显式 UA 原样保留。**FFI 接线**：`config_api::set_config("userAgent", v)` 落库成功后同步更新进程级覆盖（空串清除）；`db_open` 调用 `restore_user_agent()` 从 caches `config:userAgent` 回填；`search.rs::ensure_default_user_agent`、`image_api` 图片 UA 兜底、`rss_web_bridge::effective_ua` 统一改读全局。**覆盖范围**：搜索/详情/目录/正文（统一 `LegadoClient` 出口）、图片（显式兜底 + 统一出口）、RSS 列表/正文抓取（统一出口）与 RSS WebView（既有 DA 回落点改读全局）；WebDAV 按原版 `lib/webdav/WebDav.kt:104`（`okHttpClient.newBuilder()` 派生，含全局 UA 拦截器）在 `WebDavClient`/`RemoteBookManager` 构建期注入全局 UA。**不覆盖（登记）**：① `legado-server` 内裸 `reqwest::Client` 旁路（TTS/音频/源更新下载）；② `legado-net/src/rule_update_client.rs` **普通订阅请求当前完全不带 UA**（未改走 `LegadoClient`），`#requestWithoutUA` 分支发送**字面量 `null` 头**而非移除——本批不改其行为，登记后续批对齐（原版普通路径走全局 OkHttp UA、后缀分支由拦截器移除）；③ Flutter `CachedNetworkImage` 图片请求与 Dart 自建 HTTP（应用更新/WebView）不属 Rust 网络链；④ `User-Agent: "null"` 残留差异——本批仅保证不下发字面量 `null`，reqwest 客户端默认头仍会补内置 UA，上游为彻底移除，登记后续。**Dart 接线**：`main.dart` 启动第 5d 步把 SharedPreferences `userAgent` 镜像到 Rust（值相同不写；空值写空串清除旧值；USE_MOCK 跳过；失败静默）；设置页保存/清空经既有 `BookApi.setConfig` 即时同步；备份恢复 `_reloadPrefsAfterRestore` 在 appPrefs 回填后再次同步（避免同会话 prefs/Rust 分叉，失败不阻断恢复）。**测试**：Rust 覆盖「无 header→全局」「有 header→保留」「空全局→内置」「已构建客户端 setConfig 后即时生效」「Default 哨兵与显式客户端配置优先」「控制字符 UA 拒绝并回落」「图片 UA 键名大小写不敏感」「并发读写值域安全」「config_set/restore 链路」；Dart 覆盖启动同步（写入/相同跳过/清空/异常静默）、设置页保存/清空与恢复后同步。计数：§2.x 附录合计 **320**、BookApi **318**、§1.7 表 B **154**（等价对总数 **170**）全部不变。 |
| 2026-10-31 | **批9b-2 P0 复验回修（零新增 FFI 方法/签名变化；续跑重复计数修复）**：**P0 根因**——快照 `nextIndex=0, finishedChapters=[1]` 恢复后，worker 完成章 0 时 `record_finished_locked` 在同一临界区内把前缀推进到 2 并移除 ahead 的 1；随后 worker 认领到陈旧的章 1，旧跳过条件只查 `ahead.contains(1)`（已移除）→ 重下并 `completed++`，最终 `counted>total` 被判 `failed`。**修复**：① worker 跳过条件改为 `index < finished_prefix || ahead.contains(index)`，且**在 `finished_ahead` 同一把锁内同时读取前缀**（`is_finished`），消除「ahead 已移除、前缀尚未写回」的竞态窗口；② `claim_next` 入口 `next_dispatch.fetch_max(finished_prefix)`，游标不落后于连续前缀；③ worker 循环整体 `catch_unwind`（主 worker panic 后置取消、唤醒窗口、join 全部 spawned worker 后才释放全局准入），循环 panic / join Err 置 `failed`（不误报 cancelled/completed），单章 panic 仍计该章失败。**§2.43.3 补充**：窗口 32 是快照有界性与预取的折中，慢/挂起章会延迟后续派发；`finishedChapters` 超窗恢复时裁剪并扣减计数后重下（幂等）。**测试**：单 worker 确定性 P0 红→绿、2 worker 竞态、裁剪后跑完计数闭合、worker 循环 panic/join 收尾；threadCount 测试复位改为 Drop guard。计数：§2.x 附录合计 **320**、BookApi **318**、§1.7 表 B **154**（等价对总数 **170**）全部不变。 |
| 2026-10-31 | **批9b-2 审查回修（零新增 FFI 方法/签名变化；默认值/有效上限/全局准入/有界快照/恢复同步）**：按用户裁决调整 9b-2 语义——① **默认值 16**（对齐参考版，多平台更稳；原版 32 仅作历史证据），仅改缺省，已存值保留，>256 的存量值夹逼显示为 256；② **搜索有效上限 32**（本架构 `max_blocking_threads=64`、单源约 2 个 spawn_blocking），不采用 64；UI 保留 1..256 并在行 subtitle 标注「搜索有效上限 32；离线缓存有效上限 8」；③ **下载全局准入**：进程级同时只准入 1 本书（Condvar 队列，排队任务零 HTTP），单书上限 8 worker，取消/重启恢复同样遵守；④ `finishedChapters` 改为**滑动窗口 32 章**（窗口外不派发，持久化集合长度 ≤32，恢复时窗口外记录丢弃并扣减计数后重下，幂等）；⑤ worker `download_one` 经 `catch_unwind`，panic 计失败并记录，终态要求 `completed+failed==total`；⑥ 备份恢复 `_reloadPrefsAfterRestore` 同 UserAgent 一样回写 threadCount；⑦ `parse_thread_count` 对超出 i64 的纯数字正数按上限夹逼、负数按 1，非数字回落缺省。取消语义统一为「不再派发（竞态窗口内最多再派发 N 章），在途完成后停止」；§2.43.7 在途集合为 0..N。计数：§2.x 附录合计 **320**、BookApi **318**、§1.7 表 B **154**（等价对总数 **170**）全部不变。 |
| 2026-10-31 | **批9b-2：「线程数」设置真正生效（零新增 FFI 方法/签名变化；§2.4 / §2.10 / §2.43.3 / §2.43.7 行为补充，契约先于代码提交）**：设置页「更新和搜索线程数（太多会卡顿）」（偏好键 `threadCount`）此前零消费；本批让多源搜索与批量离线下载在**运行期**读取该值。**语义基准**：原版 `AppConfig.threadCount` 默认 **32**（`legado-upstream/.../help/config/AppConfig.kt:416-419`），消费于 `SearchModel.kt:38,106`（`mapParallelSafe(threadCount)` 有效并发=threadCount；固定线程池 `min(threadCount, AppConst.MAX_THREAD=9)`）、`CacheBookService.kt:43-45`（下载线程池 `min(threadCount, 9)`）、`CacheBook.kt:154`（`onEachParallel`）、`ChangeBookSourceViewModel.kt:336,588`、`CheckSourceService.kt:210`、`JsExtensions.kt:205,224`；参考版 `DownloadCacheSettings.threadCount` 默认 16（`FeatureSettingsRepositories.kt:157`）、UI 范围 **1..256**（`downloadCacheConfig/DownloadCacheConfigScreen.kt:104-109`）、搜索 `coerceAtLeast(1)`（`ChangeSourceSearchUseCase.kt:74,130`）、下载 `cacheBookThreadCount.coerceIn(1, CacheBook.maxDownloadConcurrency=8)`（`CacheBook.kt:50,79`、`CacheBookService.kt:63-64,111`）。**配置真源与读取时机（无新 FFI，走既有 `setConfig`）**：Dart SharedPreferences 为 UI 真源，经 `setConfig("threadCount", v)` 镜像到 Rust caches `config:threadCount`；Rust 在**每次搜索/下载任务入口**读该键（不缓存，用户保存后下一次入口即生效）。**解析与夹逼（统一口径）**：缺失/空串/纯空白/非整数 → 回落缺省；数值越界 → 夹逼（负数/0 → 1；超出 i64 的纯数字正数按上限夹逼）。**搜索并发**：缺省 **16**（对齐参考版）、硬上限 **32**（本架构 `max_blocking_threads=64`、单源约 2 个 `spawn_blocking`（URL 构建 + 解析）的有效上限；参考版 UI 允许更高值，本架构不采用 64）（`search.rs::search_concurrency()`），应用于 `searchBooks`/`searchMulti`/`searchMultiStream`/换源批量与流式（`drive_source_batches` 与 `buffer_unordered`）；单源内解析顺序、跨源结果聚合、会话取消/暂停/超时（30s，换源 60s）语义不变。**下载并发**：有效并发 = threadCount 夹逼 **1..=8**（缺省 16 → 8，对齐参考版 `maxDownloadConcurrency=8` 与原版 `MAX_THREAD=9` 线程池语义）；**全局准入**：进程级同时只准入 **1 本书**的批量下载（Condvar 队列，排队任务在获得准入前不发起任何 HTTP；取消/重启恢复路径同样遵守），单书内 N worker 共享派发游标（每章恰好派发一次），进度/失败集合/`completed`/`failed` 计数原子更新、快照写入串行化；取消 = 不再派发新章（竞态窗口内最多再派发 N 章）、在途章（≤N）完成后停止（单线程时代「当前章完成后停止」的推广）；续跑游标改为**连续完成前缀**（`nextIndex` 语义）并持久化有界「已完成但前缀未推进」集合（新字段 `finishedChapters`，`#[serde(default)]` 兼容旧快照；派发/持久化滑动窗口 **32 章**，窗口外不派发，重启后集合长度 ≤32，窗口外章重下幂等），重启后不跳过、不重复计数；worker panic 经 `catch_unwind` 计为失败并记录，终态仅在「全部尝试且 completed+failed==total」时判 `completed`，否则置 `failed`。**未接入（登记）**：目录批量更新调度器 `toc_updater` 仍无 FFI 调用方、`download_manager`（`DownloadManager::new(3)`）与 `checkThreadCount`（§4.1 批42 独立配置）不随本键变化；正文多 URL/JS 批量请求（原版 `AppConfig.threadCount`）当前无对应我方消费点。**Dart 接线**：UI 默认值保持 **16**（对齐参考版；已存值保留，>256 的存量值仅夹逼显示为 256）、范围 1..999→**1..256**（行 subtitle 标注「搜索有效上限 32；离线缓存有效上限 8」）；保存时写 prefs 并经 `setConfig` 同步 Rust；启动第 5e 步按 prefs→Rust 单向对齐（值相同不写、USE_MOCK 跳过、失败静默）；备份恢复 `_reloadPrefsAfterRestore` 同 UserAgent 一样回写 threadCount（同会话内避免 prefs/Rust 分叉）。**测试**：Rust 覆盖配置解析（缺省/非法/夹逼/超 i64）、搜索入口并发取配置值（回环服务器最大在途数）、下载单书 N worker 最大在途/保序/失败/取消/无重复/续跑、全局单书准入（3 书串行、重启多任务、取消排队）、慢首章有界快照、worker panic；Dart 覆盖默认 16、范围与存量夹逼显示、保存同步、启动同步、恢复后同步。计数：§2.x 附录合计 **320**、BookApi **318**、§1.7 表 B **154**（等价对总数 **170**）全部不变。 |
| 2026-10-31 | **批9b-1：自动清除过期搜索结果接线（契约先行；§2.15 加法式新增 1 方法 `clearExpiredSearchBooks`）**:对齐原版 `App.onCreate`（`legado-upstream/app/src/main/java/io/legado/app/App.kt:114-117`）——启动时若「自动清除过期搜索」开关（偏好键 `autoClearExpired`，默认 true；UI/持久化已有，此前零消费）为开，删除 `searchBooks` 表中 `time < now - 1 天` 的记录。**语义基准**：SQL `DELETE FROM searchBooks WHERE time < :time`（对齐 `SearchBookDao.kt:95` `clearExpired`），**严格小于**边界（`time == before` 保留），单语句返回删除行数，无事务包裹需求（单 DELETE 原子）。**Rust 链**：`legado-db::SearchBookRepository::delete_expired(before: i64) -> LegadoResult<usize>` → `legado-ffi/src/api/search.rs::clear_expired_search_books(before_ms: i64) -> LegadoResult<i64>`（数据库未初始化报错，同 `delete_search_book` 风格）→ `ffi.rs::search_books_clear_expired(before_ms) -> Result<i64, BridgeError>`（FRB 导出，返回删除行数）。**Dart 启动接线**：`main.dart` 启动序列第 5c 步（语言/图片偏好初始化后、闪屏路由前）——读 `autoClearExpired`（`SettingsService.getBoolPref`，默认 true），为 true 时 unawaited 调 `clearExpiredSearchBooks(DateTime.now().millisecondsSinceEpoch - 86400000)`；USE_MOCK 模式跳过（Mock 无 DB）；失败静默（debugPrint，不阻断启动）；开关关闭不调用。计数：附录合计 319→**320**、BookApi 317→**318**（303 同名行 + 14 命名等价 + 1 别名）、§1.7 表 B 153→**154**（等价对总数 169→**170**）；§2.15 5→**6**。 |
| 2026-10-31 | **批1b-3：无目录规则时按长度分章（零 FFI 签名/方法计数变化；`getChapters` 行为补充，本条目契约先于代码提交）**：本地 TXT 在「未配置显式目录规则（`books.tocUrl` 空）**或**显式规则未命中/不可编译而回退」且**内置默认正则零命中**时，由「整文件单章『全文』」改为按设置项 `maxLengthWithNoToc`（caches 表 `config:` 前缀，与参考版 `PreferKey.maxLengthWithNoToc` 同名）分章。**语义逐条对齐参考版 `TextFile.kt` `analyze()`（L358-464）**：① 配置读值默认 **3000**，非法/越界回落默认，夹逼范围 **3000..100000**（参考版 `ReadConfigViewModel.kt:134` `coerceIn(3000, 100000)`）；② **字符→字节换算**：`maxLengthWithNoTocBytes(charset, chars)`——UTF-8 每字 3 字节、GB* 每字 2 字节、UTF-16 每字 2 字节、其余 1 字节（参考版 L464-476；我方在**解码后文本**上按字符切分，换算仅用于对齐切分粒度，无字节截断乱码面）；③ 切分点优先取「超出上限处之后的最近换行符」（参考版按字节在缓冲区找 `0x0a`；我方等价实现为按字符找 `\n`），无换行则在本段缓冲边界硬切；④ 章节标题 `第{block}章({pos})`（参考版 L385 模板），`start/end` 按解码后文本字节偏移（与正文读取链同一坐标系）；⑤ 尾段**不足最小档位（≤100 字节，原始字节比较，不做编码换算）时并入上一章**，否则自成一章（参考版 L457-462 `bufferStart > 100 || toc.isEmpty()` 口径）；⑥ 空文件报错（既有 `EmptyFileException` 语义不变）；`used_custom_rule` 语义不变（长度分章恒 false）；自定义规则命中、非 TXT/在线书路径、目录缓存命中路径均不受影响；改配置后**已入库目录不自动失效**（与参考版「重进目录重新解析」一致，用户经 TXT 目录规则弹层或重导入触发重解析；目录页溢出菜单新增「重新解析目录」入口，见下）。**已登记差异（P3-1）**：参考版按 512KB 缓冲分块读取，>512KB 连续无换行文件会跨缓冲切出多章；我方整文件单缓冲处理，此类文件（极罕见）单章吞下全文。**登记（P3-2/P3-3，2026-10-31 审查回修）**：P3-2——纯中文 UTF-8 文件前 4KB 采样在字符中间截断时既有 `detect_encoding` 误判 gb18030（批37b 前既有口径），本批「默认档位分章」公开链路测试改用显式 charset 锚定切分边界（不覆盖误判路径下的分章数量），误判与长度分章互不影响正文读取；P3-3——caches `config:` 键不在既有备份 `BackupData` 段内，`maxLengthWithNoToc` 经 `configSet` 写入的 Rust 真源值**不随备份往返**（Dart SharedPreferences 镜像随 `appPrefs` 往返；恢复后 Rust 侧缺省 3000，直至用户重改设置或后续批把 caches config 纳入备份），备份恢复路径未做端到端验证。FFI 侧 `reader_get_chapters` 在本地 TXT 懒解析分支读 `config:maxLengthWithNoToc` 后传给解析器，签名与返回形状不变。Dart 阅读设置页新增「无目录时每章字数」行（滑块 3000..100000，默认 3000，松手提交），偏好键 `maxLengthWithNoToc`，并经既有 `configSet` 写 caches（Rust 为真源）+ SharedPreferences 镜像；纳入 `RestoreIgnorePrefs.readPrefKeys` 白名单。 |
| 2026-10-30 | **批42：书源检验补齐发现页校验 + 并行检验 + 域名 TCP 探测（零 FFI 签名/方法计数变化；服务端 4 条检验端点请求/响应形状不变，仅执行语义补齐，见 §4.1 批42 注）**：① **发现页校验接入**——`config:checkDiscovery`（默认 true）且 `exploreUrl` 非空时取首个可用分类 URL（纯文本/JSON 分类数组/`@js:`/`<js>` 求值），经新增 `legado-fetcher::web_book::webbook_explore_first_book`（规则源 `RealBookSourceFetcher::explore_first_book`：AnalyzeUrl + `ruleExplore.bookList`（空则回退 `ruleSearch.bookList`）+ loginCheckJs + 「列表为空按详情页解析」回退）抓取首书并跑详情/目录/正文；失败口径区分「发现规则为空 / 发现规则求值失败 / 发现页请求失败 / 发现失效 / 发现目录失效 / 发现正文失效」，搜索书同步改为「搜索目录失效 / 搜索正文失效」（对齐原版 `checkBook(isSearchBook)`）；未启用 quickjs 构建跳过 JS 发现规则求值（登记）。② **并行检验**——`run_check_session` 由逐源串行改为有界并发（`JoinSet` + 共享队列），并发数 = CPU 核数夹逼 4~8、caches `config:checkThreadCount` 可覆盖（硬上限 32）；单会话/sessionToken/stop 取消（在途工作线程随会话任务中止）/CAS 写回语义不变，DB 写经 AppState 互斥锁串行。③ **checkDomain**——`config:checkDomain=true` 时 TCP 探测源地址（连接 1.6s，对齐原版 `isDomainReachable`），不可达 → 「域名失效」+「源地址不可访问」，非 http(s) → UNCHECKABLE。④ **测试**：service 集成 20 例（新增发现项 4 + 并行耗时 + 并行停止 + 域名探测），fetcher 既有面不变（批42b 复核实数）。 |
| 2026-10-30 | **批43b：TXT 目录规则审查回修（2 P1 + 3 P2 + P3；零新增 FFI，BookApi +1 纯别名）**：① **P1-1 恢复默认被陈旧整书写回复活**——`updateBook`/`addBook` 的受保护列合并扩展：本地 TXT 的 `tocUrl` 一律取库内值（**含空串**），只由 `setBookTocRule` 与备份/导入写入（旧规则「库内空则入参补齐」会让 `setBookTocRule(null)` 清空后又被旧快照复活）。② **P1-2 派生字段被旧 Book 打回 0/NULL**——`totalChapterNum/latestChapterTitle/latestChapterTime` 整书写回一律取库内值；`getChapters` 目录缓存命中时以 `chapters` 表回填派生字段；Dart `reloadAfterTocRuleChange` 成功后 `getBook` 刷新 currentBook、目录页 `_loadChapters` 同步 `totalChapterNum`。③ **P2-1 假成功反馈**——`ChapterListResponse` 新增 `used_custom_rule`（serde default false，仅本地 TXT 懒解析有效），BookApi 新增只读别名 `getChaptersWithMeta`（§1.7 登记，复用 `reader_get_chapters`）；UI 仅在「选具体规则且 false」提示「规则未命中，已回退默认规则」，恢复默认提示「已恢复默认目录规则」。④ **P2-2 并发解析窗口**——懒解析落库前 `BEGIN IMMEDIATE` 复查 `charset/tocUrl` 未变才写入，变了丢弃并按新设置重解析（≤2 次）。⑤ **P3**——分隔符注释码点修正 U+1FAC5/U+1F233/U+1F3FB；`split_toc_rule` 外部 `tocUrl` 原样消费（不再 trim）；空/纯空白标题按原版跳过、零宽字符保留；Dart 本地 TXT 判定四套口径收敛为 `utils/txt_toc_rule.dart::isLocalTxtBook`；弹层高度按窗口自适应 + `scrollable`；目录页阅读器重载错误并入 onApplied。计数：§2.x 行合计 319 不变、BookApi 316→**317**（§1.7 改名等价 15→**16**、等价对总数 168→**169**）。 |
| 2026-10-30 | **批42b：书源检验审查回修（5 P2 + P3；零 FFI 签名/方法计数变化，服务端 4 条端点请求/响应形状不变）**：① **P2-1 停止后在途结果写回**——`check_one_source` 抽出 `write_back_check_result`，写回入口前复查 `is_cancelled(token)`，已停止/已更换会话直接丢弃本次结果（AbortHandle 只打断 await 点，超时返回与写回之间仍有窗口）。② **P2-2 早退丢失失效分组**——`check_source` 的硬失败早退统一走 `fail_check(message, 已累计分组)`，`failed_with_groups` 统一补「校验失败:」前缀；搜索已判「搜索失效」后，发现求值/请求硬失败不再丢失首段分组。③ **P2-3 停止取消用例**——集成用例先等 mock「请求已到达」计数再 stop（旧用例只等 NEEDS_CHECK，该状态在请求发出前已写入，近恒真）。④ **P2-4 发现链 fetcher 单测**——补 `{{page}}` 求值、`@js:`/`<js>` 失败上抛、`ruleExplore.bookList` 空回退 `ruleSearch.bookList`、`bookUrlPattern` 非空不回落详情、`concurrentRate` 限流、JSON 分类数组 URL 入链共 6 例。⑤ **P2-5 FLOW_SCOPE 登记修正**——并行下 A 的 `@put` 可能写进 B 的 scope（跨源串读，不只为空值降级）；并行度 >1 且 ≥2 源使用流程变量时输出一次 tracing warn + stderr（`[收敛项 B42-C2]`）。⑥ **P3**——契约计数 19→20；测试头更新；`check_discovery` 过期注释；quickjs 跳过日志改 warn+stderr；TCP 探测改 500ms/地址子超时（整体 1.6s）；exploreKinds 双实现登记 `[收敛项 B42-C1]`；非 quickjs 边界写清；可达/discovery 用例加请求计数；并行用例改「并行 vs 串行」对比；`parse_explore_url` JSON 判定补 `endsWith(']')`。⑦ **测试**：service 集成 23 例（默认 22 + quickjs 1）、source_check 单测 27 例（含既有用例）；fetcher 新增 6 例（默认 5 + quickjs 1）。 |
| 2026-10-29 | **批41b：原版 zip 媒体恢复审查回修（P1×1 + P2×2 + P3；零 FFI 签名/方法计数变化：§2.11 = 4、附录合计 318、BookApi 315、§1.7 表 B 152）**：① **P1-1 解压字节错误路径入账**——`read_zip_entry_limited` 先累计 `read_to_end` 已读出的字节、再处理读错误与总限额（此前错误路径直接 `?` 返回、`total_decoded` 不增长），「合法 deflate + 坏 CRC」批量条目不再能绕过 512 MiB 总限额（媒体条目原本把该错误吞成 warn）；红→绿用例 `test_read_zip_entry_limited_counts_bytes_on_error_path`。② **P2-1 JSON 备份不再外带本机媒体绝对路径**——`backup_create` 把本机媒体根 `covers/`、`readRecordCovers/` 下的封面绝对路径归一为 null（书面 `customCoverUrl` / 分组 `cover` / 阅读记录 `coverUrl`）；JSON 恢复新增封面守卫：`.../covers/<file>` 按本地媒体根 remap、其他绝对路径「目标存在才保留」，否则 null，网络 URL/相对路径原样；补 zip→JSON→异机恢复用例。③ **P2-2 媒体落盘原子化**——同目录临时文件 `create_new` + `rename` 覆盖（Windows 先删后 rename，非原子窗口登记），替代 `fs::write` 直接截断。④ **P3**——条目数上限前移 EOCD 预检（解析后 `archive.len()` 仍权威）；媒体相对路径拒绝控制字符与 Windows 保留设备名（con/nul/aux/prn/com1..9/lpt1..9）及结尾空格/点；`coverFont.ttf` 落盘前 TTF/OTF 魔数首检；测试注入槽中毒锁 `into_inner`；`canonicalize` 只用于包含判断、落库路径剥离 Windows 逐字前缀；补条目数/总限额/合并覆盖/设备名/inspect 不收集媒体用例；登记「DB 事务失败不回滚媒体」与 remap 判据差异。详见 §2.11 批41b 回修补记。 |
| 2026-10-29 | **批41：原版 zip 媒体恢复（covers/bg/readRecordCovers/coverFont.ttf；零 FFI 签名/方法计数变化：§2.11 = 4、附录合计 318、BookApi 315、§1.7 表 B 152）**：原版 zip 备份内的 `covers/`（可含子目录）、`bg/`、`readRecordCovers/` 与封面字体 `coverFont.ttf` 从「只 warn 跳过」改为按白名单前缀落盘（对齐原版 `Backup.kt:399-429` / `Restore.kt:613-627` / `Restore.kt:487-495`）。媒体根 = DB 父目录（移动端应用 Documents；env `LEGADO_BACKUP_MEDIA_DIR` 可覆盖），映射 `<媒体根>/covers|bg|readRecordCovers/<相对路径>` 与 `<媒体根>/font/coverFont.ttf`；合并写不删除本地既有媒体，失败逐条 warn 不阻断恢复。路径安全：白名单前缀 + 既有条目名校验 + 相对段校验（拒绝 `..`/绝对/空段/`:`），逐段拒绝符号链接，写入前 `canonicalize` 父目录并校验仍在媒体根内。限额：单媒体文件 32 MiB、跨条目共用 512 MiB 总限额、zip 条目总数 ≤ 50 000。媒体落盘后按目标文件存在性 remap `customCoverUrl`/分组 `cover`/阅读记录 `coverUrl`（covers 与 readRecordCovers 两形态），目标缺失置 null。我方 JSON 备份不含媒体（不 base64 膨胀），`backup_create` 不写媒体。详见 §2.11 批41 补记。 |
| 2026-10-29 | **批40b：WebDAV 备份族审查回修（P1×1 + P2×4 + P3；方法计数不变：§2.28 11、附录合计 318、BookApi 315、§1.7 表 B 152）**：① **P1-1 本地书相对标识上传**——`WebDavBookUploadService.uploadBook` 上传前经 `LocalBookStore.resolveSync(book.bookUrl)` 还原为当前容器绝对路径（iOS 批量导入落库 `books/<name>`，Rust `webdav_upload_file` 直接读相对路径必然失败；绝对路径/`://` 原样）；`LocalBookStore.resolveSync` 显式把前导 `/` 视为绝对路径（Windows 下 `File.isAbsolute` 不识别 POSIX 路径）。② **P2**——回环全链用例夹具 `max_requests` 3→4（原值截断第二次 DELETE，`failed` 静默吞掉）；恢复链（WebDAV 短按/本地长按）经 `LocalBackupService.runExclusiveRestore` 与备份共用互斥，恢复进行中自动备份返回 busy；导入后逐本自动上传由服务层进程内单飞队列串行（原版单协程串行）；`WebDavClient` 增加 connect 15s / 控制请求 60s / 文件传输 600s 超时（自动链路不再无限占锁）。③ **P3**——备份名清理改为严格 `backup_yyyyMMdd_HHmmss[_SSS].json`（大小写敏感）；删除键取 PROPFIND `href`（百分号解码、剥离 `remote_dir` 前缀），不再信任 `displayname`；保留数 UI/服务双侧 clamp `0..1000`；恢复后重读备份族新增设置行；自动备份锁内复检 `autoBackup` 与到期状态、`lastBackup` 在未来视为到期；远端备份名追加毫秒段（同秒去重）；设置页对话框 controller 改为对话框自持并 dispose；差异/缺口见 §2.28 批40 注②③⑤⑥⑦⑧⑨。 |
| 2026-10-30 | **批43：TXT 目录规则真正作用于当前书（加法式 +1 方法）**：① §2.2 新增 `setBookTocRule(String bookUrl, String? ruleJson) → Future<Book>`（Rust `ffi::book_set_toc_rule` → `legado-ffi/src/api/bookshelf.rs::set_book_toc_rule`）——对齐原版 `TocActivity.onTocRegexDialogResult` / `ReadBookActivity.onTocRegexDialogResult`：选中规则后**单列 UPDATE** `books.tocUrl`（原版格式 `rule + TextFile.spaceChars(🫅🈳🏻) + replacement`，Android 备份/跨端库直接兼容），同事务清空 `chapters` 表该书行并重置目录派生字段（下一次 `getChapters` 重解析）；`ruleJson` 为 `TxtTocRule` JSON（`{rule,replacement}`）或直接正则串，`null`/空白 = 恢复默认规则；正则经 `legado_core::regex_safe::compile_fancy_regex_safe`（支持原版 lookbehind）试编译，非法/超长/嵌套过深**抛错**（不假成功）；非本地 TXT 抛错（UI 隐藏入口）。② **解析侧**：`legado-book` 新增 `LocalBook::get_chapters_with_rule` / `TxtParser::get_chapters_with_rule` 与 `TocParseOutcome{chapters,used_custom_rule}`；显式规则按原版 `Pattern.MULTILINE` 整段匹配（行首偏移 + 命中片段为标题），**未命中/不可编译回退内置默认规则**并由 `reader.rs::get_chapters` 记 warn；`books.tocUrl` 仅在本地 TXT 分支消费，非 TXT/在线书不受影响。③ UI：阅读器顶栏 `toc_rule` 恢复默认启用并改用原版文案「TXT 目录规则」，点击弹选择层（启用规则 + 默认规则 + 管理规则入口，勾选态按 tocUrl 逐字匹配）；目录页溢出菜单同源；选中后单列写 + 重载目录/正文（阅读页 `reloadAfterTocRuleChange`；目录页 `_loadChapters` 并同步阅读器状态）。④ **备份**：规则标识随 `bookshelf.json` 的 `tocUrl` 自然往返（新增用例 `test_toc_url_backup_restore_roundtrip` 锁定）。方法计数：§2.2 14→**15**，附录合计 318→**319**，BookApi 315→**316**，§1.7 表 B 152→**153**（等价对总数 167→**168**）。 |
| 2026-10-29 | **批40：WebDAV 备份族——上传备份、保留数清理、自动备份周期、导入后自动上传（契约先行，加法式 +1 方法）**：① §2.28 新增 `webdavPruneBackups(String configJson, String currentFileName, int keepCount) → Future<String>`（Rust `ffi::webdav_prune_backups` → `legado-net/src/webdav.rs::WebDavClient::prune_backup_files`）——对齐原版 `AppWebDav.pruneOldBackups`：上传成功后列出远端根目录，**只处理 `backup*.json`**（我方单文件 JSON 备份格式；`backup*.zip` 为原版/参考版格式，不参与清理，差异见 §2.28 批40 注），`keepCount = 0` 不清理（默认，直接返回空结果、零网络请求）；先排除 `currentFileName` 再按文件名降序保留 `keepCount - 1` 份历史备份（防 PROPFIND 未列出刚上传文件时把旧备份当成最新 N 份保留）；单个删除失败只记 warn 日志并计入 `failed`（非 2xx 才计失败，走新增的 `delete_checked`），不使整次调用失败；返回 `BackupPruneResult` JSON（`deleted` / `failed[{name,error}]`）。② **备份上传复用既有能力**：`webdavUploadFile` 上传本地 JSON 备份到远端根目录，命名 `backup_yyyyMMdd_HHmmss.json`（本地备份名保持既有 `legado_backup_<millis>.json`，仅远端名对齐批规范）；上传失败不影响本地备份成功，由 UI 明确提示。③ **Flutter 偏好（不进 FFI/DB，键名逐字对齐原版 `PreferKey`）**：`webDavBackupKeepCount`（String，默认 0=不清理）、`webDavBookAutoUpload`（bool，默认 false）、`autoBackup`（bool，默认 true）、`autoBackupWebDav`（bool，默认 true）、`autoBackupIntervalDays`（int，默认 1，读取时 clamp ≥1）、`lastBackup`（int 毫秒，成功创建本地备份后写入；设备级状态，加入 `RestoreIgnorePrefs.alwaysIgnoreKeys`，不随备份往返）。④ **自动备份调度**：启动与回前台时按「距 lastBackup ≥ 间隔天数」判定并后台创建本地备份（可选上传），与手动备份共用互斥锁；失败仅日志、不更新 lastBackup（对齐原版 `Backup.autoBack` 双检 + `BackupRestoreLock`）。⑤ **导入后自动上传**：本地书导入成功后按默认 WebDAV 配置上传到 `books/<originName>` 并回写 `book.origin`（复用远程书库手动上传同规则），默认关闭、未配置跳过、失败仅日志不阻断导入。方法计数：§2.28 10→**11**，附录合计 317→**318**，BookApi 314→**315**，§1.7 表 B 151→**152**（等价对总数 166→**167**）。 |
| 2026-10-29 | **批37b：阅读器顶栏审查回修（P1-1 charset 真接线 + 单列写，方法 +1）**：① §2.2 新增 `setBookCharset(String bookUrl, String charset) → Future<Book>`（Rust `ffi::book_set_charset` → `legado-ffi/src/api/bookshelf.rs::set_book_charset`）——**单列 UPDATE** 只改 `books.charset`（不整书回写，`readConfig` 未建模键与进度列原样保留）；编码名经 `legado-book::txt::normalize_charset`（`encoding_rs` 标签体系）校验/归一化（如 `GB2312`→`GBK`），空白/不支持编码**抛错**（UI 不得假成功）；本地 TXT 同事务清空章节表并重置目录派生字段，下一次 `getChapters` 按新编码重解析（目录 `start/end` 是解码后文本字节偏移，跨编码不可复用）。② **charset 真消费**：`legado-book` 新增 `LocalBook::get_chapters_with_charset` / `get_chapter_content_with_charset`（TXT 生效，其它格式忽略）；FFI 阅读链路 `get_chapters` / `get_chapter_content` / `get_chapter_content_raw` / `get_chapter_content_full`、本地书导出、离线缓存下载均读取 `books.charset` 作为解码覆盖（检测/默认之上），无效编码 fail-closed。③ UI：阅读器「设置编码」改走 `setBookCharset` + 目录/正文重载，目录或正文读取失败时提示失败（对齐参考版 `ReadBook.setCharset`）。方法计数：§2.2 13→**14**，附录合计 316→**317**，BookApi 313→**314**，§1.7 表 B 150→**151**（等价对总数 165→**166**）。 |
| 2026-10-29 | **批35b：批35 审查回修（P2/P3；方法计数不变：§2.2 13、附录合计 316、BookApi 313、§1.7 表 B 150）**：① **P2-1 删除源文件信任边界**——`deleteBooks` 的文件删除新增「Documents/Cache 信任根」：相对标识拒绝 `..` 组件（`books/../outside.txt` 不再能逃出 Documents）、`canonicalize` 后必须仍在应用 Documents（DB 文件父目录）或 Cache/tmp（`std::env::temp_dir()`，WebDAV 导入临时落盘）根内、删除前 `symlink_metadata` 拒绝符号链接、目录/设备文件按「非普通文件」拒绝；根外/越界一律返回中文提示且不删文件、不阻断记录删除。② **P2-2 整书全行写不再重置书级开关**——`updateBook`/`addBook` 与 Web `PUT /api/books/:id` 对缺键（JSON 无 `disableReadRecord` 或 `null`）保留库内值，显式携带才覆盖；Web 请求体新增可选 `disable_read_record`（兼容 `disableReadRecord` 别名）。③ **P3**：`deleteBooks` 返回值由 `Future<List<String>>` 改为 **`Future<DeleteBooksResult>`**（`{deleted, missing, warnings}`；Rust `BookshelfDeleteResult`，删除前查库计数，UI 用实际删除数）；`putReadRecord` 返回值由 `Future<void>` 改为 **`Future<bool>`**（Rust 因书级开关跳过时返回哨兵 `-1` → `false`，阅读器回滚会话基数，关闭期间时长不再补记）；`deleteBooks` 改为「短连接查库 → 无连接文件 IO → 单事务删记录」；`BookType.isLocalStorageBook`（Dart）与 Rust `is_local_storage_book` 同构（Rust 为真源）；标签行高度按 `textScaler` 计算；`recordReadingTime` 不传 `bookUrl`、书级开关不生效的既有事实登记（无生产调用方）。 |
| 2026-10-29 | **批35：书架标签内容 + 批量删除原文件 + 书籍级阅读记录开关（契约先行，加法式 +2 方法 / 1 方法可选参数）**：① §2.2 新增 `deleteBooks(List<String> bookUrls, {bool deleteOriginal = false}) → Future<List<String>>`（Rust `ffi::bookshelf_delete_books` → `legado-ffi/src/api/bookshelf.rs::delete_books`）——逐本删除书架记录（`BookRepository::delete_by_url`，级联清章节）；`deleteOriginal=true` 时**仅对本地/WebDAV 书**删除 `bookUrl` 指向的磁盘文件（`db_state::resolve_local_book_path` 还原 iOS 相对标识；路径安全 fail-safe：拒绝 URL scheme、空值、非普通文件与扩展名不在电子书/本地媒体白名单的路径），删除失败**不阻断书籍记录删除**，以中文提示逐条返回（成功返回空数组）。对齐参考版 `DeleteBooksUseCase` + `LocalBook.deleteBook(deleteOriginal)`。② §2.2 新增 `setReadRecordDisabled(String bookUrl, bool disabled) → Future<Book>`（Rust `ffi::book_set_read_record_disabled` → `BookRepository::set_read_record_disabled`）——**单列 UPDATE** 只改 `books.disableReadRecord`，不整书回写（避免陈旧快照覆盖进度/其他列）；返回更新后的整书 JSON；书籍不存在报错。对齐参考版 `BookInfoViewModel.toggleReadRecordDisabled` + `BookDao.setReadRecordDisabled`。③ §2.12 `putReadRecord` 新增可选命名参数 `{String? bookUrl}`（Rust `ffi::read_record_upsert(book_name, read_time, book_url: Option<String>)`）——`bookUrl` 非空时写前查 `books.disableReadRecord`，为真则**跳过本次写入**（返回传入 readTime，不写 readRecord/readRecordDaily），为空保持旧行为；阅读器写路径传 `book.bookUrl`，覆盖「详情页切换后阅读器持有旧 Book 副本」的并发窗口。④ **DB `SCHEMA_VERSION` 116→117**：`ALTER TABLE books ADD COLUMN disableReadRecord INTEGER NOT NULL DEFAULT 0`（对齐原版 `Book.kt:120-122`），幂等迁移 + 开库自愈；`Book` 模型加法式字段 `disableReadRecord`（bool，键名 `disableReadRecord`，缺键默认 false）；`bookshelf.json`/自有备份 `books` 段/原版 zip 恢复自动透传。⑤ **Flutter 偏好**：书架标签四键 `bookshelfShowTag` / `bookshelfShowCustomTags` / `bookshelfShowSourceTags` / `bookshelfShowWordCount`（默认均 true，对齐参考版 `BookshelfSettings.kt:17-20`；不进 FFI/DB，随 JSON 备份 `appPrefs` 往返，受「忽略书架布局」约束）。方法计数：§2.2 11→**13**，附录合计 314→**316**，BookApi 311→**313**，§1.7 表 B 148→**150**（等价对总数 163→**165**）。 |
| 2026-10-29 | **批34b：批34 审查回修（P2/P3；零新增/变更 FFI 方法或字段，§2 方法计数、附录合计 314、BookApi 311、§1.7 表 B 148 全部不变）**：① **P2-1 接线可测化**——阅读页高亮键计算/缓存命中/换章清空/在途去重/旧结果丢弃从 `ReaderPageViewState` 抽到 `flutter_legado/lib/src/services/highlight_match_sync.dart`（`HighlightMatchSync` + `HighlightMatchRequest` + 注入式 loader），补 9 项单测（换章清旧命中、滚动模式不调用 FFI、修订号变化丢弃旧结果等）；② **P2-2 乱序防御**——`buildHighlightedLineSpans` 对 `matches` 做 O(n) 有序校验，乱序时按 `(start, order)` 稳定排序兜底，补「乱序输入不丢 span」用例；③ **P2-3 超时语义补记**——任一截止（单规则 `timeoutMillisecond` 夹取 1..=5s / 整体 5s）到期即**中止剩余规则**并返回已收集结果（对齐原版），warn 文案区分「单规则（规则 id）」与「整体」；④ **P2-4 失败不每帧重试**——匹配异常时清 key 并按 1.5s 退避，单 key 最多尝试 2 次（首次 + 一次重试），补注入异常单测；⑤ **P2-5 渲染边界补记**——本批仅渲染规则命中，highlights 表记录渲染仍为后续专项；⑥ **P3 收口**：style 数值字段 `is num` 守卫 + `parseHighlightMatches` 逐条 try/catch（单条坏样式不丢整章）、长按高亮 `chapterPos/chapterPosEnd` 扣除首行缩进列并修正过期注释、缓存键增文本长度、Mock scope 空串守卫对齐 Rust（空 bookName/origin 不命中非空 scope）、Rust 补 maxMatches 保高优先级/同 order 先命中/零宽正则/fancy 回退 4 项用例、相邻章预览页高亮登记为后续专项、underline/strike 共用 `decorationColor` 差异登记（见 §2.36 批34b 补记）。 |
| 2026-10-29 | **批34：高亮规则正文匹配 + MVP 渲染（契约先行，加法式 +1 方法）**：§2.36 新增 `highlightRuleMatch({required String text, String bookName = '', String origin = '', bool applyToTitle = false, int? maxMatches}) → Future<String>`（Rust `ffi::highlight_rule_match` → `legado-ffi/src/api/highlight_api.rs::highlight_rule_match`，复用 `HighlightRuleRepository::find_enabled_by_book` 的启用 + scope 过滤语义）。返回 `HighlightRuleMatch[]` JSON，元素 `{ruleId, start, end, order, styleJson}`：`start/end` 为 **UTF-16 code unit 半开区间**（与 Dart `String` 下标一致），`order` 为规则 `sortOrder`，`styleJson` 为规则 `style` 原文（未知键原样保留，Dart 侧解析）。**匹配语义**：仅启用规则；`applyToTitle=false` 取 `applyToBody` 规则、`true` 取 `applyToTitle` 规则；空 pattern 跳过；字面量按 `isRegex=false` 不重叠查找，正则先做 Java 方言适配（`\uXXXX`→`\x{XXXX}`、`\R` 展开等，见 §2.36 注）后走 `legado-core::regex_safe` 安全编译（1KB 上限 + 嵌套深度 ≤32），不支持语法回退 `fancy-regex`（backtrack 上限 100 万），仍失败则 warn 跳过该规则；**重叠按 `order` 大者覆盖**（同 order 先命中者胜），其余截断/跳过，输出按 `(order 升序, start 升序)` 稳定排序；单次正文上限 **1 MiB**（超限报错）、整体截止 **5s**（逐规则检查，超时返回已收集结果并 warn）、`maxMatches` 缺省 **10000**（≤0 返回空）。**渲染范围（MVP）**：Flutter 阅读页正文 `Text.rich` 应用前景色 / 背景色（矩形）/ 下划线 / 删除线；`fillShape` 的圆角/马克笔/半高/PILL 暂按矩形绘制，`bold`/`italic` **不启用**（会改变字体度量，分页不重算），`box`/`emphasis`/`shadow`/`fontPath`/`fontSize`/`letterSpacing`/`horizontalPadding` 不渲染——全部在 §2.36 注与批34 交付说明登记。偏移映射修正 `paragraph_layout_engine.dart`：段落/行补章节全局偏移（`ParagraphInfo.startIndex/endIndex` 改为章节全局半开区间，`LineInfo` 新增 `chapterStartIndex`/`highlightSkip`），缩进列不参与高亮。**计数**：§2.36 11→**12**、附录合计 313→**314**、BookApi 310→**311**（296→**297** 同名行 + 14 命名等价）、§1.7 表 B 147→**148**（等价对总数 162→**163**）。 |
| 2026-10-29 | **批33：裁决项 1/2/4 + 高亮编辑器字段保真（纯 Flutter 行为/偏好，零新增/变更 FFI 方法或字段；§2 方法计数、附录合计 313、BookApi 310、§1.7 表 B 147 全部不变）**：① **字号范围 5–50**（参考版口径，步进 1，默认 20）：`ReaderNotifier.updateFontSize` clamp 12–32 → 5–50，`_loadSettings` 读取后同样归一（历史 >50 收敛到 50 并回写）；阅读界面设置页字号卡由纯步进器改为「滑块 + 数值 + 加减」。偏好键 `reader_font_size` 不变。② **边距上下联动**：`ReaderAdvancedConfig` 新增 `paddingTopBottomLinked`（bool，默认 false，键名逐字对齐原版 `ReadBookConfig.paddingTopBottomLinked`；仅正文 Tab 显示，任一方向调整镜像另一侧；开启时下边距对齐上边距）并入 `RestoreIgnorePrefs.readPrefKeys`（随 Flutter JSON 备份 `appPrefs` 往返、受「忽略阅读配置」约束）；四行边距从「仅 ±1 步进」升级为「滑块 + 数值 + 加减」，范围保持上/下 0–400、左/右 0–100。**后续项登记**：原版「长按 Tab 切换大控件」（`readPaddingLargeControls`）本批不做。③ **正文搜索范围**：三档范围 + 替换/正则开关由进程内静态改为 SharedPreferences 持久化（新键 `search_content_scope` / `search_content_use_replace` / `search_content_use_regex`），默认范围由 `current_and_network` 改为 **`current_and_cached`**（仅本书已缓存，对齐原版/参考版「只搜已缓存」）；「仅本书」胶囊与搜索范围**解绑**（改为仅提示，不再改 scope）。**后续项登记**：参考版按书搜索历史需 `SearchKeyword`/`getSearchHistory` 提供 bookName 维度与按书过滤入参（当前 FFI 无该能力，本批不新建表）。④ **高亮规则 style 保真**：编辑保存由「重建 `{\"textColor\":…}`」改为「原 style JSON 补丁」（只覆盖 textColor，保留 fill/fillShape/underline/bold/italic/strike/未知键）；Dart 模型补 `styleMap` / `styleFill` / `styleBold` / `styleItalic` / `styleUnderline` 解析用于预览展示。**渲染仍未接线**：正文按 style 绘制（fill/underline/bold/stroke 等）不在本批，后续专项。 |
| 2026-10-29 | **批32b：readConfig 单键写 / zip·rar 限额审查回修（零新增方法，计数不变）**：① **P2-1 三格式落位统一**——zip/rar/7z 的 `.part` → 最终输出改由 `archive.rs::land_pending_files` 统一处理：任一落位失败清理**全部剩余** `.part`（旧实现消费式迭代只删当前 temp，其余残留），并回滚已落位项；Windows 覆盖既有输出改为「先 rename 到 `.legado_bak_<i>.<名>.bak` → 新的 rename 成功 → 删除备份」，失败恢复备份（旧实现先删旧文件再 rename，失败即丢既有输出）；既有目标为目录/符号链接等非常规文件一律拒绝，不移动用户数据。② **P2-2 目录页收口**——`splitLongChapter`/`useReplaceRule` 从 `updateBook` 改走 `updateReadConfigField` 单键写（与批32 的 `reverseToc`/`reverseTocDisplay` 一致），目录页 readConfig 勾选全部保留 Dart 未建模键。③ **P2-3 类型校验**——`BookRepository::update_read_config_field` 写回前按 `ReadConfig` 反序列化校验，类型不符（如 `reverseToc` 写字符串）拒绝写入并报「值类型不符」，DB 原键集不变（防 `row_to_book` 静默 `None` → 后续整书写 NULL 导致配置永久丢失）。④ **测试/文档**——新增落位失败清理/Windows 备份恢复（zip/7z）、伪造声明大小命中实际读取计数、CRC 精确断言（`zip 2.4.2` 为 `io::Error(InvalidData, "Invalid checksum")`）、`update_book` 清键对照用例；RAR 解析级安全/限额无夹具登记 limitation；模块文档修正同名 basename 口径（7z 去重、zip/rar 覆盖）。§2.2 = 11、附录合计 313、BookApi 310、§1.7 表 B 147 均不变。详见 §2.2/§2.34 批32b 补记。 |
| 2026-10-29 | **批32：readConfig 单键写 FFI（契约先行，加法式 +1 方法）**：§2.2 新增 `updateReadConfigField(String bookUrl, String key, String valueJson) → Future<void>`（Rust `ffi::book_update_read_config_field` → `legado-db::BookRepository::update_read_config_field` 复用；`valueJson` 为**值本身**的 JSON 编码串，支持 bool/string/number/对象/数组，解析失败抛错）。**根因**：`updateBook` 是整书快照写，Dart `ReadConfig` 未建模的键（如 `useGlobalAudioSkip`、`tocExpanded`、`manualReplaceRuleIds`）在 Dart→Rust 往返中被类型化结构体丢弃，切一次目录反转就会清空这些键；新方法在 DB 侧**只合并目标键**，未建模键与其他键原样保留。**语义**：书籍不存在报错（不清空、不静默成功）；`key` 为空白报错；`readConfig` 为空/非法 JSON 时新建对象再写入目标键；不触碰其他列与进度列。**接线**：目录页 `reverseToc`/`reverseTocDisplay` 与阅读器菜单 `reverseTocDisplay` 改走单键写，`updateBook` 保留其余用途。§2.2 10→**11**，附录合计 312→**313**，BookApi 309→**310**，§1.7 表 B 146→**147**（等价对总数 161→**162**）。 |
| 2026-10-29 | **批32：zip/rar 导入限额与路径安全对齐 7z（零新增方法，计数不变）**：`legado-book/src/archive.rs` 的 zip 导入/列表与 rar 导入/列表补齐与 7z 同口径限额（输入 ≤512 MiB / 单条目 ≤256 MiB / 总量 ≤512 MiB / 条目数 ≤10000，声明值与实际读取字节双计数）与共用路径安全 fail-closed 校验（`validate_archive_entry_name`，任一不安全条目整包拒绝）；zip/rar 改「先写 `.part`、整包成功后 rename」，失败清理临时文件且不触碰既有输出；zip CRC 损坏如实报错。Android/iOS 的 rar 仍为明确不支持桩。详见 §2.34 批32 补记。 |
| 2026-10-29 | **批32：图片下载链登录头同站门控 + proxy 伪头剔除（零新增方法，计数不变）**：`fetchImageWithDecode`（§2.20）按 `web_book::is_login_header_site` 同站判定附加 `loginHeader_<bookSourceUrl>`（跨域 CDN 不携带认证信息，无法判定域名时回退附加），与搜索/发现/正文链同口径；发送前 `strip_proxy_header` 剔除源 header 中的 `proxy` 代理配置键，避免凭据作为 HTTP 头外发（对齐批29b 审查 P2-6 的既有修复面）。回环用例覆盖同站带头/跨域不带/头中无 proxy。 |
| 2026-10-28 | **批31：书源管理「显示书籍数量」+ 目录「显示反转」（契约先行；零新增 FFI 方法 / 2 处模型字段加法式，§2 方法计数全部不变）**：① **`getBookSources`（§2.3）返回项加法式字段 `bookshelfCount`（int，缺键默认 0）**——Rust `ffi::source_list` 包装输出，按书源 `bookSourceUrl` 对齐 `origin` 聚合书架书籍数（`SELECT origin, COUNT(*) FROM books WHERE (type & 1024) = 0 AND (type & 256) = 0 AND (type & 4096) = 0 GROUP BY origin`，即排除 `notShelf` 临时书、Kotlin local 位 256 与 Rust local 位 4096，对齐原版 `BookDao.flowBookshelfSourceOrigins` 的 `type & notShelf = 0 AND type & local = 0` 过滤口径；与 §2.3 批31 注逐字一致）；`source_list_enabled` / `source_export`（导出/备份）**不携带**该字段，Dart `BookSource.toJson` 亦不输出（`includeToJson: false`），源保存/导出往返零污染。② **`Book.readConfig` 加法式字段 `reverseTocDisplay`（bool，缺键默认 false）**——逐字对齐原版 `Book.ReadConfig.reverseTocDisplay`（`Book.kt:502`）；仅展示层反序，章节数据顺序与 `index` 身份不变；与既有 `reverseToc` 组合语义 = 先数据反转、再显示反转（双开回到原始顺序）。**DB `SCHEMA_VERSION` 115→116**：`readConfig` 为 JSON TEXT 列（对齐原版 Room `books.readConfig`），本次无 DDL，迁移 115→116 为版本登记（幂等空操作），旧库缺键按 serde 默认 false 读取；`bookshelf.json`/自有备份 `books` 段/原版 zip 恢复**自动透传**该键。③ **Flutter 偏好**：`showSourceBookshelfCount`（默认 false，SharedPreferences 键，对齐原版 `PreferKey.showSourceBookshelfCount`；不进 FFI/DB，随 Flutter JSON 备份 `appPrefs` 自动往返）。 |
| 2026-10-28 | **批30：书源检验状态 + 原版 web-dist 同步（零新增 FFI 方法，§2 方法计数全部不变；服务端新增 4 条原版 HTTP 端点，见 §4）**：① **DB `SCHEMA_VERSION` 114→115**：新增 `book_source_check_states` 表（逐列对齐原版 `BookSourceCheckState.kt` 与 `DatabaseMigrations.kt:108-121` 的 `migration_105_106`：`bookSourceUrl` 主键 + 外键 `book_sources(bookSourceUrl)` ON DELETE CASCADE、`revision`/`sourceRevision`/`status`/`checkedAt`/`detail` 全 NOT NULL），迁移 114→115 建表 + `INSERT OR IGNORE` 为存量源播种 `NEEDS_CHECK`（随机 revision），幂等，并纳入开库自愈 `repair_legacy_columns`；**不重建 `book_sources_part` 视图**（Rust 无消费方，网页管理端点直接返回完整源 + 状态）。② **状态机**：书源新增/规则变更（`checkContent()` 变化）→ 重建状态；仅改启用/排序/权重等不触发；`startBookSourceCheck` 排队重置 `revision` 并保留 `sourceRevision`，结果写回以 `(url, revision, status='NEEDS_CHECK')` CAS；`stop` 中止后台任务，未完成源保持 `NEEDS_CHECK`。`checkContent()` 归一忽略 `customOrder/enabled/enabledExplore/lastUpdateTime/respondTime/weight`，另把 `enabledCookieJar` 的 `None` 与默认 `true` 同指纹（对齐网页端 `sourceCheckState.js` 规范化）。③ **保存钩子**：FFI `addSource`/`updateSource`/`importSources`、服务端 `/saveBookSource(s)`/`/saveJsSource`、备份与旧版导入、`RoomImporter::import_book_sources` 均维护状态（新增/规则变更重建，规则不变保留）。④ **web-dist**：整体替换为上游 `531f9fbf07` 的 60 文件构建产物（新 hash 资产 + `vue/js_source_template.js`，旧 hash 资产清除；字节取上游 git blob，保持 `.gitattributes -text` 字节锁定）。⑤ **验证**：Rust 全量 `cargo test --workspace` 通过；真实 TCP 服务 + headless Chrome 冒烟：`/vue/` 渲染、拉取源、检验选中、状态显示「检验失败」，书籍/订阅页无 console/page error。 |
| 2026-10-28 | **批29：RSS 阅读记录按源清空 + 书源登录头同站门控（契约先行，零新增方法 / 1 方法可选参数；批29b 审查回修已并入）**：§2.35 `rssClearReadRecords` 新增可选命名参数 `{String? origin}`（Rust `ffi::rss_clear_read_records(origin: Option<String>)`，核心实现 `legado-ffi/src/api/rss_read_record_api.rs::clear_by_origin` → `legado-db::RssReadRecordRepository::clear_by_origin`）——对齐原版 `ReadRecordDialog` 的「清空」按当前源 `RssReadRecordDao.deleteAllRecord(origin)`。**清空语义（批29b 审查 P1-1 修正）**：仅 `None` 清空全部；`Some(origin)` 一律按 trim 后 origin 精确过滤，空串/纯空白删除 0 行、**绝不**退化为清空全部（原版 WHERE origin='' 同样不命中正常记录）；DB `clear_by_origin` 同口径 trim，全量清空唯一入口 `clear_all`。方法计数不变（§2.35 = 7，附录合计不变）。同批登记：RSS 阅读记录**全局开关** `enableRssReadRecord`（默认 true，Flutter SharedPreferences 键，对齐原版 `AppConfig.enableRssReadRecord`；**不进 FFI/DB**，写入门控在 Dart 两处入口：列表打开与桥动作打开）；按源开关 `RssSource.enableReadRecord` 维持字段保真、不参与运行期（批28 已登记，原版行为一致）。**书源登录头同站门控（对齐上游 #1099 `AnalyzeUrl.isLoginHeaderSite`；批29b 审查 P2-4/P2-5 登记）**：① **行为**——登录头（`loginHeader_<bookSourceUrl>`）只附加到与书源**同 eTLD+1** 的请求，粒度复用 Cookie 域键单一真源 `legado_net::cookie_store::cookie_domain_key`（多段公共后缀 `com.cn`、私有后缀 `github.io`、IP 字面量按自身、单段主机按自身，与 Cookie 域处理同源一致）；覆盖搜索/详情/目录/正文/`nextContentUrl`/`nextTocUrl`（串行+并发）/发现页/音频缓存；相对目标按各链 baseUrl 绝对化后判定；无法判定域名（非 http(s)、畸形串、缺 base、`bookSourceUrl` 非 URL）回退旧行为（附加）。合并顺序：静态源 header → 登录头（仅门控命中）→ AnalyzeUrl 头 → 请求属域 JS cookie。② **已登记偏差/风险**——㈠ 协议相对地址 `//host/path`：我方按 baseUrl 补协议后判定（`//cdn.other.com/x` → 跨站，不附登录头），比上游「按原样取子域失败 → 回退附加」更严格（收敛方向，安全）；㈡ `bookSourceUrl` 含 `@js:` 等非 URL 形态时 `Url::parse` 失败 → 回退**无条件附加**登录头，**潜在外发风险**（上游同构回退的等价物；规则书源 key 为 URL，此形态仅见畸形/脚本源，后续批评估改为失败即不附加）；㈢ 图片/封面链（`image_api`、封面规则）**不附加登录头（同站也不带）**，为批前既有行为（本批未改；该链合并源 header 后亦未剔除 `proxy` 伪头，登记后续项）；㈣ 门控在**发起请求前**按请求 URL 判定，HTTP 重定向（3xx 跟随）**不重新门控**——同站 URL 302 到跨站时登录头仍随重定向请求发出（与上游客户端级跟随同构，已知边界）。③ **同批登记（批29b 审查 P3-6）**——搜索单源 `search_single_source` 合并 `source.header` 但**不附登录头**（原版搜索链按同站附加，差异登记，后续批接线）；RSS 链自身沿用**同源（scheme+host+port 全等）**门控（比书源 eTLD+1 更严格，见 §2.5 批15b 注）；Flutter `rssHistoryNotifierProvider` 为全局单例，全局与按源阅读记录对话框共享同一份 `records/isLoading/error`，交替打开存在作用域串扰（**后续批**改 family/局部作用域）。④ **proxy 伪头剔除（批29b 审查 P2-6，既有泄漏顺手修复）**——发现页、音频缓存下载、并发 `nextTocUrl` 分页三路径发送前补 `strip_proxy_header`；`fetch_simple_cached`/`fetch_toc_page_optional`（正文分页/subContent/串行目录分页）同口径补齐。 |
| 2026-10-28 | **批28：原版规则字段往返保真（schema v114 / ContentRule 批量正文 / HighlightRule.group / RssSource.enableReadRecord；零新增 FFI 方法，§2 方法计数全部不变）**：① **模型契约加法**（详见 §2.3/§2.5/§2.36 注）：`BookSource.ruleContent` 增 `contentBatch`（String，可空）/`maxBatchSize`（Int，可空，`null`=不支持批量）；`HighlightRule` 增 `group`（可空，键名 `group`）；`RssSource` 增 `enableReadRecord`（bool，缺键默认 `true`）。全部按原版键名/类型（`ContentRule.kt`、`HighlightRule.kt`、`RssSource.kt`）冻结。② **DB `SCHEMA_VERSION` 113→114**：`ALTER TABLE highlightRules ADD COLUMN "group" TEXT DEFAULT ''`（对齐原版 `HighlightRule.kt:37-38` 与 `DatabaseMigrations.kt:63-66` 的 `migration_108_109`）、`ALTER TABLE rssSources ADD COLUMN enableReadRecord INTEGER NOT NULL DEFAULT 1`（对齐原版 `RssSource.kt:28-30`；该列自原版 Room schema **112** 起存在，上游无独立 ALTER）；建表语句同步，迁移 113→114 全为 `add_column_if_not_exists`，**幂等**（`user_version` 门禁 + 列存在性检测），并纳入开库自愈 `repair_legacy_columns`。③ **往返路径**：源保存/导入/导出（`add_source`/`update_source`/`import_sources`/`export_sources`）、RSS 源 CRUD、高亮规则 CRUD、`BackupData`（`bookSources`/`rssSources`/`highlightRules`）与原版 zip（`bookSource.json`/`rssSources.json`/`highlightRule.json`）**自动透传**新字段（模型全字段序列化 + 全列 SQL 读写，无字段级重建）。④ **Dart**：源编辑器保存改为「原 JSON 补丁」（编辑后的模型 JSON 深合到原始 JSON 之上，未在表单出现的规则字段保留）；高亮规则编辑保留 `group`；RSS 源编辑保留 `enableReadRecord`（**无 UI 开关**，按源开关上游运行期已回退为全局开关）。**遗留（本批不实现）**：正文批量下载（`BookContent.analyzeContentBatch` / `BookSource.supportContentBatch/contentBatchSize`）与按源 RSS 阅读记录开关行为。方法计数不变（§2.3 = 33、§2.5 = 19、§2.36 = 11，附录合计不变） |
| 2026-10-28 | **批27：原版 P0 数据兼容（schema v113 / readRecord 13 字段 / book_memos / 备份 v5；零新增 FFI 方法，§2 方法计数全部不变）**：① DB `SCHEMA_VERSION` 112→113，`readRecord` 主键改 `(deviceId,bookName,author)`、补 `lastChapterTitle`/`lastChapterIndex`（DEFAULT -1）/`lastChapterPos`（DEFAULT 0）/`coverUrl`/`resolvedAuthor`/`displayBookName`（NOT NULL DEFAULT ''）/`displayAuthor`（NOT NULL DEFAULT ''）/`metadataEditedAt`（NOT NULL DEFAULT 0）8 列 + `index_readRecord_snapshot(displayBookName,displayAuthor,lastRead DESC,deviceId,bookName,author)`/`index_readRecord_bookName_author`；新增 `book_memos(bookUrl PK, content NOT NULL, updatedAt NOT NULL)`（无级联外键）。迁移 112→113 重建表**原样搬运**（不拆旧 `\u001Eauthors:` 合并串），先探测 `displayBookName` 列保证上游「发列未升版本」场景幂等。② `readRecord` 读写按新主键；恢复合并对齐上游 `mergeRestoredReadRecord`（同键较新者胜 + 章节快照/封面/显示元数据按 `metadataEditedAt` 选择），**同名不同作者分行**；旧合并作者串仅保留解码用途（搜索阅读记录标识/展示），写入侧不再产生。③ `BackupData` 增 `bookMemos`（`{bookUrl,content,updatedAt}` 数组，**空表也写空数组**），`BACKUP_VERSION` 4→5；`readRecords` 元素扩为 13 字段；原版 zip 映射增 `bookMemo.json`，恢复按 `restoredBookUrls` + 书籍存在 + `updatedAt` 更新者胜过滤；`readRecordCovers/`、`coverFont.ttf` 仍不落盘（warn 跳过；**该媒体不落盘口径已被批41 取代**，见批41/批41b 补记）。④ Dart `ReadRecord` 模型补 13 字段，阅读记录页按 `displayBookName`/`displayAuthor`（空回退物理书名/作者）分组展示，同名不同作者不再按书名合并时长。方法计数不变（§2.11 = 4、§2.12 = 6，附录合计不变） |
| 2026-10-27 | **批24d：7z 交错条目导入漏文件修复（零新增方法；P1）**：设备验收 D1——py7zr 等打包器把目录条目与文件条目交错写入（7z 规范允许，`kEmptyStream` 位图），`sevenz-rust2 0.24.1` 的 `for_each_entries`/`read_file` solid 分支按「块首文件索引 + 子流数」连续遍历，区间撞到无流目录条目后提前结束，后续文件被静默跳过（列表走 `archive.files` 仍完整）。修复：① 以 `archive.files` 为权威清单，输出名仍按原始文件序规划（列表口径）；② 导入前按块重排内存文件表并重写 `stream_map`（`normalize_7z_block_file_ranges`），使块区间恰好覆盖全部子流，主迭代一次读全；③ 主迭代记录已写出集合，未覆盖条目回退 `read_file` 逐条读取（长度不符/缺失即整包报 `7z 条目读取不完整`，不静默成功）；④ 结果按原始文件序返回，list/import 命名与顺序一致。单测新增交错夹具（py7zr 生成、base64 内联）与回退/不完整用例；真实 DLL 用例增交错包回归。方法计数不变（§2.34 = 10，附录合计 312，BookApi 309，§1.7 表 B 146）。详见 §2.34 批24d 补记 |
| 2026-10-27 | **批24c：7z 审查回修（零新增方法；大小写不敏感去重 + 归因修正 + 命名一致性）**：① **P2-1 去重平台矩阵**——原 `output_name_key` 仅 Windows 折叠大小写，iOS APFS/macOS 默认大小写不敏感下 `A.txt`/`a.txt` 仍相互覆盖且列表返回两个路径；改为 `FOLD_OUTPUT_NAME_CASE = cfg!(any(windows, target_os="macos", target_os="ios"))`，去重策略抽为 `dedupe_output_name(base, used, next_seq, fold_case)` 参数，单测覆盖折叠/精确两支。② **P3-1 归因修正**——上游 `init_archive` 已先拒绝 `next_header_size > reader_len`，64 MiB 签名头预检属纵深防御而非 OOM 修复；编码头解码输出（`take(unpack_size).read_to_end`）与编码头内 LZMA 字典分配未缓解，7Z-1 明确「仅头部明文缓冲区受限；解码内存未缓解」。③ **P3-4 list/import 命名一致**——import 按 `archive.files` 文件序预计算输出名（`plan_book_output_names`），解压回调按 basename 队列取用，修复零字节/无流条目最后访问导致的 `_2`/`_3` 归属漂移。④ **P3-5 去重 O(n)**——`HashMap<基名, 下一序号>` 替代重复线性扫描，命名规则不变。⑤ **P3-7 阻塞例外**——`spawn_blocking` 任务 panic/JoinError 时 `archiveImport7z` 可能抛 BridgeError 而非信封。方法计数不变（§2.34 = 10，附录合计 312，BookApi 309，§1.7 表 B 146）。详见 §2.34 批24c 补记 |
| 2026-10-27 | **批24b：7z 审查回修（零新增方法；错误语义修正 + 残余风险登记 + 去重命名 + 阻塞模型）**：① **P2-4 错误语义修正**——§2.34 原表述「以下情形均抛 BridgeError（success=false 信封仅供 zip/rar）」与实现相反：`archiveImport7z` **恒返回信封** `{success, error, extracted_files}`（不抛 BridgeError），`archiveList7zFiles` 失败**抛 BridgeError**（消息含 `Book parsing error:` 前缀）。② **P2-1 头部 OOM 登记 + 缓解**——`sevenz-rust2` 编码头解码 `MAX_MEM_LIMIT_KB=usize::MAX/1024`（等同无上限），恶意头可声明 4 GiB 字典致 OOM（仅 DoS）；新增打开前 32 字节签名头预检，`NextHeaderSize`（offset 20..28）> 64 MiB 拒绝；编码头内部字典声明仍不受控，登记于 `docs/RESIDUAL_RISKS_2026-08-13.md`。③ **P2-2 阻塞模型**——`archiveImport7z`/`archiveList7zFiles` 改 async + `spawn_blocking`（对齐 `directLinkUpload`），Dart 签名不变，FRB 生成 `wrap_async`。④ **P3-2 同名 basename**——同包重名按 `name.ext`/`name_2.ext` 去重，列表与解压同命名，不再后者覆盖前者。⑤ **P3-4 Windows ADS**——Windows 上条目名含 `:` 整包拒绝。⑥ **P3-8 块级 CRC**——PackInfo pack stream CRC 上游不校验，已登记。方法计数不变（§2.34 = 10，附录合计 312，BookApi 309，§1.7 表 B 146）。详见 §2.34 批24b 补记 |
| 2026-10-27 | **批24：外部文件 7z 解压导入（契约先行，加法式 +2 方法；用户已授权）**：§2.34 新增 `archiveImport7z({required String sevenZipPath, required String outputDir}) → Future<Map<String, dynamic>>`（Rust `ffi::archive_import_7z`，核心实现 `legado-book/src/archive.rs::import_7z_file`）与 `archiveList7zFiles({required String sevenZipPath}) → Future<List<String>>`（Rust `ffi::archive_list_7z_files` → `list_7z_book_files`）。**实现选型**：`sevenz-rust2 0.24`（Apache-2.0、纯 Rust、Android/iOS/v7a 可交叉编译；`default-features=false`，同批把 `legado-js` 的 0.12.1 升至 0.24，修复 CVE-2026-61725 7z 条目名路径穿越，0.21.1 已修）。**语义**：解压后仅取书籍后缀（`.txt/.epub/.mobi/.pdf/.umd/.azw3/.azw`）逐个返回，文件名取条目 basename（与 zip/rar 路径一致）；列表不解压、仅读头。**限额（fail-closed）**：输入 512 MiB / 单条目解压 256 MiB / 全部条目解压总量 512 MiB / 条目数 10000 / LZMA·LZMA2 字典 128 MiB；超限整包失败。**路径安全**：条目名 `\`→`/` 后逐组件拒绝 `..`、绝对路径、盘符、空字节，任一不安全整包拒绝；写盘只用 basename 并经既有 `safe_output_path` 二次校验。**错误语义**：签名/版本/CRC/截断/密码/内存/IO/限额/路径错误 → `BridgeError` 中文文案（`ArchiveImportResult.success=false` + `error` 仅用于保持与 zip/rar 一致的信封）。**不支持项（与原版 libarchive 无密码回调口径一致）**：加密 7z、分卷、PPMd/BZip2/Deflate/LZ4/Zstd/Brotli。**契约先行日期 2026-10-27**（本条目与 §2.34 文档改动先于 Rust/Dart 代码落盘）。§2.34 8→**10**，附录合计 310→**312**，BookApi 307→**309**，§1.7 表 B 144→**146**（等价对总数 159→**161**）。详见 §2.34 批24 补记 |
| 2026-10-27 | **批21h 设备验收缺陷回修（P1-1/P1-2 + P2-1 口径 + P2-3 登记；零新增方法）**：① **P1-1 动作通道红→绿**——Dart 同步面局部两参 `function __lgEmitAction(name,payload)` 与 Rust 桥头单参 `__lgEmitAction(payload)` 同名提升，`__lgAction` 自递归、`RangeError` 被吞，`java.log/toast/longToast/open/searchBook/addBook/showPhoto/openUrl` 全部静默丢失；改为局部 `__lgActionEmit`，`__lgAction` 单次调用桥头。② **P1-2 页面全局命名**——注入 `window` 的名字去 `legado` 前缀（`__rs_`/`__rn_`/`__rc_`/`__rk_`/`__rb_`），幂等标记首个 tick 后转移到回填回调并删除窗口属性，桥释放时删除回调（Rust 回填回调改 `configurable:true`）；console 钩子/override 桩改 `__rssConsole*`/`__rssJava`。③ **P2-1 安全口径**——内联快照仅对源作者脚本可达（桥模式页面脚本已剥离）、URL 模式页面可信等价、不声称「窗口无任何宿主痕迹」。④ **P2-3 快照拆分登记未改**（时序/语义风险）。§2.5 批21h 段详述；方法计数不变（§2.5 19，附录合计 310，BookApi 307，§1.7 表 B 144） |
| 2026-10-27 | **批21a：RSS 阅读 WebView `preloadJs` 宿主桥（契约先行，加法式 +1 方法）**：§2.5 新增 `rssWebViewHostCall(String sourceUrl, String method, String argsJson) → Future<String>`（Rust `ffi::rss_web_view_host_call`，核心实现 `legado-ffi/src/api/rss_web_bridge.rs`）——**单入口 RPC**：`argsJson` 为位置参数 JSON 数组，返回信封 `{"ok":bool,"value":<any>,"error":String?,"actions":[...]?}`。内部方法 `__prepare`（`{channelName,callbackName,ua}` → `{script,snapshot}`，源 `preloadJs` 为空/空白时 `script` 为空串＝不注入桥）、`__cookieSet`（WebView Cookie 回流落库）、`__store`（source 变量/登录缓存/cache 读写与 toast 动作）；对外方法白名单与 `WebJsExtensions.request` funName 对齐（`run`/`ajaxAwait`/`connectAwait`/`getAwait`/`headAwait`/`postAwait`/`webViewAwait`/`webViewGetSourceAwait`/`decryptStrAwait`/`encryptBase64Await`/`encryptHexAwait`/`createSignHexAwait`/`readTxtFileAwait`/`importScriptAwait`/`getStringAwait`；`downloadFileAwait` 本批返回明确不支持）。Rust 在 `executor:<sourceUrl>` QuickJS 引擎中执行宿主调用，源静态 header + UA 注入全局请求头、`enabledCookieJar` 查询回退 `RssSourceRepository`、源 `concurrentRate` 限流、`ui_action_queue` 收集动作。Dart 侧 channel/握手/动作转发属批21b。§2.5 18→**19**，附录合计 309→**310**，BookApi 口径 306→**307**，§1.7 表 B 143→**144**（等价对总数 158→**159**）。**契约先行口径**：本批同时把 `rssWebViewHostCall` 直通封装进 `BookApi`/`RustApi`/`MockBookApi`（纯 FFI 委托，无 channel 业务逻辑），故 BookApi 计数同批转齐。详见 §2.5 批21a 补记 |
| 2026-10-27 | **批20：RSS 历史记录 type/sort/image/pubDate/durPos 扩展（契约先行，零新增方法 / 1 方法可选参数）**：① §2.35 `rssMarkRead` 新增可选命名参数 `{int type = 0, String? sort, String? image, String? pubDate, int? durPos}`（Rust `ffi::rss_mark_read(..., article_type: Option<i32>, sort/image/pub_date: Option<String>, dur_pos: Option<i32>)`，核心实现 `legado-db::RssReadRecordRepository::mark_read_with`）——对齐原版 `RssArticle.toRecord()`（`RssArticle.kt:66-76`）全列写入；缺省 `type=0`、`sort=''`、`image/pubDate=NULL`、`durPos=0`，旧调用不传行为不变。② §2.35 `RssReadRecordRow` 新增字段 `type`（int，DB `NOT NULL DEFAULT 0`，旧行读出 0）、`sort`（string，DB `NOT NULL DEFAULT ''`，旧行读出空串）、`image`（string?）、`pubDate`（string?，Room 列 `pubDate` 为 TEXT，原版实体为 `String?`）、`durPos`（int，DB `NOT NULL DEFAULT 0`，旧行读出 0）；两个列表入口（`rssListReadRecords` / `rssListReadRecordsByOrigin`）SELECT 与 JSON 输出一致。③ **历史入口分流以记录为准**：`rss_screen.dart` 历史记录打开时用 `record.type/sort/image/pubDate` 构造文章 DTO，`resolveRssArticleType(articleType: record.type, sourceType: source.rssType)`——记录 `type` 非 0 与 `ReadRss.kt:25-45` 严格对齐（0 网页 / 1 图片 / 2 视频），`type=0` 回退源 `type` 为我方已登记的兼容超集（原版无此回退）。同主键重复标记按 `INSERT OR IGNORE` 忽略（批20b 审查对齐原版 `RssReadRecordDao` 的 `OnConflictStrategy.IGNORE`：不刷新 `readTime`、不改写扩展列）。方法计数不变（§2.35 = 7，附录合计 309，BookApi 306，§1.7 表不变）。 |
| 2026-10-27 | **批18b：远程书库书籍 origin 对齐原版/参考版（零 FFI 方法/签名变化，数据语义登记）**：① **新写入格式冻结**——远程书库导入/上传统一写 `webDav::<完整远程 URL>[,{"serverID":<int>}]`（对齐 `BookType.kt:76` + `RemoteBookViewModel.kt:141-143` + `CustomUrl.kt:42-47`）：默认 WebDAV 服务器 `serverID = null`（`AppWebDav.defaultBookWebDav` 构造未传）→ **不追加属性**；自定义服务器追加 `,{"serverID":<servers.id>}`。② **存量兼容**——批18b 前本仓库写入的 `dav:` 前缀（默认服 `dav:<完整URL>`、自定义服 `dav:<相对路径>`）**永久保留只读兼容，不做数据迁移**（避免大范围写库）。③ **读写口径分离**——Dart `BookType.isWebDavOrigin` / `webDavPathOf` / `buildWebDavOrigin` / `isLocalOrigin`，Rust `book_type::is_web_dav_origin`（`WEB_DAV_TAG` + `LEGACY_WEB_DAV_TAG`）；`is_local_book`、on-shelf 判定、`isOnlineBook`、阅读器/详情页/删除/备份过滤等 20+ 消费点全部收敛到统一判定，不再散落字符串比较。④ 属性后缀解析对齐 `AnalyzeUrl.paramPattern = "\\s*,\\s*(?=\\{)"`（逗号前后允许空白）。 |
| 2026-10-26 | **批17c：加密备份恢复审查回修（零 FFI 签名/方法计数变化）**：① **P2-1 恢复 Cookie 立即生效**——Cookie 恢复移到主事务提交后，在 `COOKIE_PERSIST_RW_LOCK` 内完成「读-合并-写库 → 读回最终行 → 覆盖式写回 FFI 共享内存 store + `legado-js` 内存 store」，随后 `reset_shared_client`（+ quickjs `reset_shared_client_pools`）重建客户端（此前只写库、内存仍旧值且合并预载「内存值胜」，要重启才生效）。② **P3-2 Cookie 合并对齐原版** `CookieStore.mergeCookieValues`：空旧值原样返回、**插入序**（不再按键排序）、空白值丢弃、字面量 `"null"` 保留；空键丢弃为本地加固。③ **P3-3 `backupInspect` 空/纯空白条目判损坏**（不弹永远失败的密码框）；恢复侧空文件仍报 `BACKUP_ENCRYPTED_CONTENT_CORRUPT`。④ **P3-4 cookie 条目级容错口径**登记（见 §2.11 批17c 补记）。⑤ **P3-5 Dart 侧容器判定改扩展名 + 文件魔数**（`.json` 命名的加密 zip 也探测密码并弹框；zip 容器不做 JSON 偏好/账号回读）。⑥ **P3-6 进度框三态**（忙/已执行/异常，忙不再被当成功）。⑦ **P2-3 偏好敏感面收口**（Flutter `appPrefs`）：`sync_webdav_password` 整键排除；`remote_servers` 备份时剥除 `password`、恢复时不用备份值覆盖本机密码。⑧ §2.11 契约文本修正（批9「我方无密码输入面」注记已被批17a 取代）。方法计数不变（§2.11 = 4，附录 309，BookApi 306）。 |
| 2026-10-26 | **批17a：加密原版备份恢复（契约先行，加法式 +1 方法 / 1 方法可选参数）**：① §2.11 `restore` 增加可选命名参数 `{String? password}`（Rust `ffi::backup_restore(path, password: Option<String>)`）——仅对原版 zip 备份生效，`null`/空串=空密码，旧调用不传行为不变；我方 JSON 备份忽略该参数。② §2.11 新增 `backupInspect(String backupPath) → Future<String>`（只读 JSON `{"format","passwordRequired","passwordProtectedFiles"}`；zip 只解压 `servers.json`/`cookies.json`/`runtimeSourceCache.json` 三个候选条目，复用路径安全校验与限额；Dart 封装在后续批）。③ 恢复算法与内容：密钥 = `MD5(password)` 小写 hex 前 16 个 ASCII 字符（不 hex 解码），AES-128-ECB/PKCS5Padding + Base64；错误码前缀 `BACKUP_PASSWORD_REQUIRED:`/`BACKUP_PASSWORD_INVALID:`/`BACKUP_ENCRYPTED_CONTENT_CORRUPT:`（`LegadoError::Internal` 文本，Dart 按前缀识别）；`cookies.json` 按域名同名键合并 upsert，`runtimeSourceCache.json` 五前缀过滤 + 精确 deadline（过期跳过）+ 写后清内存运行时变量。④ 兼容：C bridge 保留 `ffi_backup_restore`（无密码）+ 新增 `ffi_backup_restore_with_password`/`ffi_backup_inspect`；**本批不做备份创建侧加密**（另立项）。§2.11 3→**4**，附录合计 308→**309**，BookApi 口径 305 不变（`backupInspect` 契约先行，Dart 封装批落地后 +1），§1.7 表 B 142→**143**（总数 157→**158**）。详见 §2.11 批17a 补记。 |
| 2026-10-27 | **批16a：直链上传能力重写 + FFI（契约先行，加法式 +1 方法）**：§2.51 新增 `directLinkUpload(String ruleJson, String fileName, String contentType, {String? content, String? filePath}) → Future<String>`（Rust `ffi::direct_link_upload`，async + spawn_blocking 非阻塞；核心实现 `legado-ffi/src/api/direct_link_upload_api.rs` + `legado-net::direct_link_upload`）。**裁决纪律**：语义对照原版上传链（`help/DirectLinkUpload.kt:26-71` + `AnalyzeUrl.kt:714-729` + `OkHttpUtils.kt:157-191`），**字段集按参考版**——参考版 `legado-with-MD3` 已删除口令与 `expiryDate`，规则对象冻结为 4 字段 `uploadUrl` / `downloadUrlRule` / `summary` / `compress`（兼容 snake_case alias）。**语义要点**：`uploadUrl` 逗号选项 `method`/`headers`/`body`/`type`，上传链恒 POST multipart（对齐原版 `AnalyzeUrl.upload`）；`body` 值 `"fileRequest"` 的键替换为文件部件，其余为普通 form 字段；`compress=true` 且 `contentType != application/zip` 时内存打 zip（条目名=原文件名）并改文件名/类型；下载链接规则以响应体 + 响应 URL 经 `AnalyzeRule` 求值（JSONPath/正则/`@js:` 级联），空结果报「上传失败,{body}」；无 quickjs 构建且规则含 `@js:` → 明确错误「当前构建不支持 JS 下载规则」。§2.51 方法数 **1**，方法模块 47→**48**，附录合计 307→**308**，BookApi 口径 304→**305**，§1.7 表 B 141→**142**（总数 156→**157**）。 |
| 2026-10-26 | **批15f 审查回修（无新增方法、零 FFI 签名变化）**：① §2.5 `rssListCachedArticles` 语义修正——**`sortName = Some("")` 严格过滤空名默认分类**（此前被 `filter(!is_empty)` 当成缺省，默认分类会读出全部分类混排），`null` 才返回该源全部分类（仅内部/兼容）；`read` 改为 `rssReadRecords` 派生（`LEFT JOIN` + `ifNull(t2.read,0)`，对齐 `RssArticleDao.kt:16-20`）；补「键名差异」说明：缓存/列表载荷分类字段分别为 `type` / `articleType`（同义，Dart 兼容）。② §2.5 `rssSortUrls` 覆盖值边界口径补全：整值先 trim、重复键逐项展开（不复刻 GSON 后者覆盖）、JSON 值非字符串/尾随垃圾/非法 JSON 回退单条 `("", trim 后原值)`、空白值回退源配置。③ Dart 侧同步：`RssNotifier._loadCachedArticles` 返回 `hasCache`，目标分类缓存为空时清空旧分类列表（`selectSource`/`selectSort`/`clearSearch`）；详情页 `startHtml` 起始页独立渲染条件（不再落空态）、`shouldOverrideUrlLoading` 结果归一（Android JSON 字面量去引号，修复恒判 true）、源 header 无 UA 时回落全局 `PrefKeys.userAgent`、`legado:`/`yuedu:` 链接走站内关联导入。④ Mock 同步空串分类过滤语义。 |
| 2026-10-26 | **批15f：RSS 增强（契约先行，加法式 +1 方法 / 1 方法可选参数）**：① §2.5 `rssSortUrls` 增加可选命名参数 `{String? sortUrl}`（Rust `ffi::rss_sort_urls(source_url, sort_url: Option<String>)`）——非空时按原版 `RssSortActivity.kt:356-366`（参考版 `RssSortViewModel.parseSortUrl`）解析该覆盖值：`sortUrl.isJsonObject()` 为真时按 `{name:url}` 对象展开（保持书写顺序；解析失败按单条 `("", sortUrl)` 回退），否则单条 `("", sortUrl)`；空值保持源配置 `sortUrls()` 原语义（默认参数行为不变）。② §2.5 新增 `rssListCachedArticles(String sourceUrl, {String? sortName}) → Future<String>`（Rust `ffi::rss_list_cached_articles`，核心实现 `legado-ffi/src/api/rss.rs::rss_list_cached_articles` → `legado-db::RssArticleRepository::find_by_origin_sort` 只读查询）——**只读 DB、零网络**，按 `origin`（+可选 `sort`）以 `order DESC` 返回文章 JSON 数组（字段 `origin/sort/title/order/link/pubDate/description/content/image/variable/group/read/type`），对齐原版 `RssArticleDao.flowByOriginSort(origin, sortName)` 的首屏本地缓存语义（`RssArticlesFragment.kt:179-218`）；`legacy:` 伪主键原样返回（UI 按既有 `hasRssArticleLink` 视为无链接）。**接线**：Dart `BookApi`/`RustApi`/`MockBookApi` 同批实现，`RssNotifier.selectSource`/`selectSort` 在网络刷新前先展示缓存（缓存查询失败静默，网络刷新不阻断）。§2.5 17→**18**，附录合计 306→**307**，BookApi 口径 303→**304**，§1.7 表 B 140→**141**（总数 155→**156**）。 |
| 2026-10-26 | **批15c 审查回修（无新增方法、零 FFI 签名变化；3 P1 + 11 P2 闭环/登记）**：① **P1-1 RSS 源级 `concurrentRate` 接线**——`legado-fetcher::rate_limit::RateLimiterRegistry` 新增 `acquire_by_source(source_url, Option<rate>)` 泛化入口（复用书源 limiter map 与固定窗口语义，`acquire(BookSource)` 改为薄封装）；RSS 列表/正文（含 `nextContentUrl` 每一页）每次请求前经 `RssRateLimit` 取许可（对齐上游 `AnalyzeUrl.kt:129,449`）；FFI `add/import/update_rss_source` 写库成功后 `refresh` 该源限流配置，引擎按当前源快照惰性创建/复用 limiter；测试：rate=`1/200` 时两次列表请求到达间隔 ≥ 200ms + registry 泛化入口单测。② **P1-3 RSS 字符集四级探测**——RSS 列表/正文由 `send_text` 改为 `send_raw` + `decode_web_response`（显式 Charset → `Content-Type` → HTML meta → chardetng 统计探测），与书源抓取链/搜索链同口径；测试：GBK `Content-Type` feed、无 charset 声明 GBK feed（统计探测）、GBK meta 正文三例。③ **P1-2 规则正文 WebView baseUrl**——详情页 `loadHtmlString(styledHtml, baseUrl: article.url.substringBefore("@js"))`，对齐上游 `ReadRssActivity.kt:406-411`；`loadWithBaseUrl` 源字段接线属批15f（下方交叉引用）。④ **P2 修正**：`rssFetchContent` 文章行改 `RssArticleRepository::find_by_link(origin, link, sort?)` 主键索引查询（缺省 `order DESC` 首行，替代 `find_by_source(i32::MAX)` 全表扫描）；正文/列表规则注入 `rssArticle` JS 绑定（DB 行 JSON / 列表基线对象，对齐 `AnalyzeRule.kt:906`）；`RssArticle` DTO 新增 `sort`，Dart `RssFeedArticle.sort` 透传详情；详情页空判定改 trim（`isNullOrBlank` 口径）、抓取成功后收藏使用抓取正文、自带 content 降级也提供重试（SnackBar action）、返回列表回填正文；e2e 补 `order`/`read` 写回保留断言，多链并发阈值放宽至 700ms 页延迟/900ms 上限。⑤ **登记/措辞**：详情触发条件为「`description` 为空即拉取（自带 content 非空也拉）」；收藏元数据「以 `rssArticles` 为准，Dart `addRssStar` 只传 origin/title/link、其余默认」；历史入口暂不抓规则正文（15d/15f）；多链并发固定 32（上游 `AppConfig.threadCount` 可配置）列入已登记差异；登录头同源门控归入「已登记差异」；列表页无 DB-only 查询 FFI，详情正文回填内存态、DB 查询登记 15d。 |
| 2026-10-26 | **批15c：RSS 正文规则 + 正文分页（契约先行，加法式 +1 方法）**：§2.5 新增 `rssFetchContent(String sourceUrl, String link, {String? sort}) → Future<String>`（Rust `ffi::rss_fetch_content`，核心实现 `legado-ffi/src/api/rss.rs::rss_fetch_content` + 引擎 `legado-fetcher/src/rss/content.rs`）。**语义对齐**：逐行对照 `Rss.kt:99-242`（`getContentAwait` / `getContentResponse` / `analyzeContentPage`）与 `ReadRssViewModel.kt:46-59,153-168`——① 首屏 `AnalyzeUrl(link, baseUrl=sourceUrl)`（page/key 空），源静态 header 透传、`loginHeader_`/`userInfo_` 仅同源附加（复用批15b 门控），`loginCheckJs` 成功/失败两路检测与列表共用 `login` 单实现；② 正文 `AnalyzeRule::new(body)` + `set_base_url(absolute(sourceUrl, 当页请求 URL))` + `set_redirect_url(响应最终 URL)` + `get_string(ruleContent)`，空规则 → 空串；③ 分页仅 `source.type==0 && 文章 type==0 && nextContentUrl 非空`，`get_strings_ex(nextContentUrl, is_url=true)`：单链顺序跟随 + 已访问集合去环，多链有界并发（上限 32 = `AppConfig.threadCount` 默认）按列表顺序拼接，最终 `"\n"` join；④ 错误语义：首屏/任一后续页失败 → `Err`（原版 `mapAsync` 保序 `await`，任一页异常即整次失败，无部分返回），空正文 → `Ok("")`；⑤ 写回 `rssArticles.description` 与 `rssStars.description`（仅已收藏行），文章行不存在时跳过。**已登记差异**：写回失败仅告警仍返回正文（原版写库异常显示加载失败）；正文页 `@put` 变量不回写 `rssArticles.variable`；多链并发不接会话取消信号；单链分页不设总页数上限。**DB**：`RssStarRepository` 新增 `find_by_key(origin, link)`（对齐 `RssStarDao.get`），文章行读取复用 `RssArticleRepository::find_by_source`（本批不改 rssArticles 仓库）。**Dart**：`BookApi`/`RustApi`/`MockBookApi` 同批实现，`rss_article_detail_screen.dart` 在 `description` 为空、`sourceUrl` 非空且源 `ruleContent` 非空时拉取（自带 `content` 非空也拉，见当日审查回修行；加载态/失败提示）。§2.5 16→**17**，附录合计 305→**306**，BookApi 口径 302→**303**，§1.7 表 B 139→**140**（总数 154→**155**）。 |
| 2026-10-26 | **批15b 审查回修（无新增方法，语义/登记修正）**：① **RSS 登录头同源门控**——`loginHeader_<url>` / `userInfo_<url>` 仅在请求 URL 与 `sourceUrl` 同源（scheme + host + port 全等）时附加；跨域 `nextUrl`（第三方跳转/聚合外链）绝不外发登录凭据（收敛方向对齐原版 `Rss.kt:56 hasLoginHeader=false`，差异仍登记为超集）；② §1.7 计数补齐：导语「另有 139 对 / 合计 154 对」、表 B 标题「→ 139 对」（表 B 实际 139 行 + 表 A 15 行 = 154），并由 `api_contract_test.dart` 增加机械校验防再漂移；③ 解析语义对齐：字段求值顺序 title → pubDate → description → image → link，`title.isBlank()` 丢弃移到全部求值之后；`description` 规则非空但无匹配 → 空串（规则为空 → null）；`link` 反转义（`get_string_ex(..., unescape=true)`）；④ `rssLoadMoreArticles` 空/空白 `nextUrl` 直接返回 `{"articles":[],"nextUrl":"","hasMore":false}`（不发请求）；⑤ 翻页 `order` 水位 = `min(order)-1`，部分重叠页只追加新条目（与原版 VM 会话 order 的差异见 §2.5 注）。 |
| 2026-10-26 | **批15b：RSS 规则列表解析 + sortUrl 分类 + 登录头合并 + 分页（契约先行，加法式 +4 方法）**：§2.5 新增 4 个 RSS 列表方法——① `rssSortUrls(sourceUrl) → Future<String>`（JSON `[{"name","url"}]`，对齐 `RssSource.sortUrls()`：`sortUrl` 按 `&&`/换行分段、`name::url` 拆分；`@js:`/`<js>` 配置经 JS 求值，结果按源缓存，键 `rssSortUrl_` + MD5(sourceUrl+sortUrl)，对齐原版 ACache `rssSortUrl`；求值失败/无配置回退 `[{"name":"","url":sourceUrl}]`）；② `rssClearSortCache(sourceUrl) → Future<void>`（对齐 `removeSortCache()`）；③ `rssRefreshArticles(sourceUrl, sortName, sortUrl, {key}) → Future<String>`（JSON `{articles,nextUrl,hasMore}`，对齐 `RssArticlesViewModel.loadArticles`：`AnalyzeUrl(sortUrl, page=1, key)` → `loginCheckJs` 检测（成功响应 eval、失败按 code 500 二次判定）→ `RssParserByRule` 规则列表/默认解析 → `order` 自当前毫秒递减 REPLACE 写库，`ruleNextPage` 非空时 `clearOld(origin,sort,order)`；hasMore = 文章非空 && nextUrl 非空）；④ `rssLoadMoreArticles(sourceUrl, sortName, nextUrl, page, {key}) → Future<String>`（对齐 `loadMore`：本页首条与末条均在库即判到底、不写库；否则 order 续接该 (origin,sort) 最小 order 递减、`INSERT OR IGNORE` 追加；JSON 同 ③）。**兼容**：`getRssArticles(sourceUrl)` 保留，内部等价 `rssRefreshArticles(sourceUrl, "", sourceUrl, null)`。**Rust 实现**：`legado-fetcher/src/rss/{parser_rule,sort_urls,login}.rs`（逐行对齐 `RssParserByRule.kt:22-140` / `RssSourceExtensions.kt:49-113` / `Rss.kt:25-85`）+ `legado-db::RssArticleRepository` 新增 `clear_old`/`append_ignore`/`find_one`/`min_order`；`source_setup.rs` 新增 RSS 最小 JS 绑定（`source`/`java`/jsLib/setup）。**已登记取舍**：E4 维持 15a（默认解析对齐原版保留空 link，仓库 `legacy:` 伪造主键保留）；E5 旧数据 `sort=""` 视为默认分类、不迁移（`getRssArticles` 等价路径仍写 `sort=""`）；登录头合并为已登记超集（原版 `Rss.kt:56` 传 `hasLoginHeader=false`，本实现按批15b 要求**仅在请求 URL 与 sourceUrl 同源时**合并 `loginHeader_<url>`/`userInfo_`，跨域 nextUrl 不外发凭据；见 §2.5 批15b 注）。§2.5 12→**16**，附录合计 301→**305**，BookApi 口径 298→**302**，§1.7 表 B 135→**139**（总数 150→**154**，4 条同名映射）。 |
| 2026-10-26 | **批11：HTTP 采集全量接线 + `/refreshToc` 独立入口（契约先行，加法式 +1 方法）**：§2.10 新增 `setHttpLogRecording(bool enabled) → Future<bool>`（Rust `ffi::set_http_log_recording`，实现 `legado-ffi/src/api/http_log_api.rs`）——对齐原版 `HttpLogController.setRecording`：先落库 caches `config:recordHttpLog`（`config_api` 同前缀，跨进程可读、服务启动同键回填），成功后切换 `legado_net::http_log` 运行期开关；落库失败抛错且运行期状态不变。**采集架构**（依赖方向硬约束：legado-net 不依赖 legado-server）：`legado-net` 新增 `http_log` 模块（`HttpLogEntry` + `HttpLogRecorder` trait + `install_recorder` 单槽 + `set_recording_enabled` 开关 + `HttpLogCapture` 上下文）；`LegadoClient` 全部统一出口（`get`/`get_raw`/`post`/`post_raw`/`head`/`send`/`send_stream`）在**最终结果处**提交一条（重试与重定向链不重复，流式响应体留空并登记）；`legado-server::legacy::http_log::StoreHttpLogRecorder` 注册为进程级实现（复用既有 `record_success`/`record_failure` 脱敏/截断/ring 50 单实现，并同步 `legado_core::app_log` 级别 http 摘要行，对齐 `HttpLogStore.add` 的 `AppLog.put`），服务启动与 FFI `db_open` 各自注册（first-wins 幂等）；段评链（`review_api.rs`）删除手工 `record_*`，避免双记录。**脱敏补齐**（审查批4 P2-4）：路径段规则新增「敏感名路径段的下一段 → `[redacted]`」（`/token/abc`、`/api/accessToken/x`、`/api/sign/x`），与凭据形段（JWT）并列；`redact_url`/`redact_path` 共用同一实现。**Dart 接线**：`BookApi`/`RustApi`/`MockBookApi` 新增同名方法；其他设置页「记录 HTTP 请求」开关改为经本方法同步 Rust（保留 prefs 写入兼容旧版本；首次读到 Rust 空值时用 prefs 值迁移一次；Rust 为真源）。**Web 端点**：新增 GET `/refreshToc?url=`（`BookController.refreshToc` 语义，复用 `refresh_toc` 单实现，无令牌；空目录刷新与「敏感名下一段」同批对齐），`/getChapterList` 空目录回退语义不变；**空目录分支行为补正**：网络抓取成功但目录为空时按原版执行「删旧 + 派生字段清零 + 返回空数组」（此前保留旧目录，独立入口会暴露差异）。§2.10 4→**5**，附录合计 300→**301**，BookApi 297→**298**，§1.7 表 B 134→**135**（总数 149→**150**）。**登记（未覆盖）**：`legado-net` 内 `webdav.rs`/`remote_book.rs` 与 server handler 裸 reqwest（TTS/音频/源更新下载）不经 `LegadoClient`，不在采集面；请求头记录为调用方显式头（默认头与 DB Cookie 合并串不入日志）；失败 error 取错误 `Display`（原版取异常类名）；流式响应体不记录。 |
| 2026-10-26 | **批9：原版 zip 备份恢复器（用户裁决⑥，零 FFI 签名/方法计数变化；审查回修后定稿）**：`backup_restore` 按文件魔数分流，`PK\x03\x04`/`PK\x05\x06` 走原版多文件 zip（映射 17 类数据 JSON + `servers.json` + `autoTask.json`，落库复用同一恢复体与事务）；`servers.json` 明文优先、否则按原版 `BackupAES`（MD5 hex 前 16 ASCII 字符 → AES-128-ECB/PKCS5，密钥派生经 openssl 向量锚定）空密码解密；`cookies.json`/`runtimeSourceCache.json` 密文 → 明确错误且零落库（无密码输入面，登记），明文 → warn 跳过；`readRecord.deviceId` 归一空串走本机合并（防两行/时长叠加）；`highlightRule`/`keyboardAssists` 备份存在即先清空再写入（缺文件不清库）；**解压限额加固**：按实际解压字节限量（伪造声明无效）+ 跨条目 512 MiB + 输入包 512 MiB 前置拦截；`covers/`、`bg/` 与配置快照类文件不恢复（登记；**其中 `covers/`、`bg/`、`readRecordCovers/`、`coverFont.ttf` 的「不恢复」口径已被批41 取代**，见批41/批41b 补记）；Flutter 选择器放开 `['json','zip']` 且 zip 忽略项过滤有明示提示。详见 §2.11 补记 |
| 2026-10-26 | **批8 审查回修（语义登记/实现回修，零 FFI 签名变化）**：① **旧格式备份恢复边界**（P1-1）：v1/v2 备份无 `servers` 键，恢复只写 Flutter 偏好（`sync_webdav_*`）；因 `loadSyncServer` 在 DB 有行或迁移标记已置时不回读偏好，恢复流程新增「偏好 → DB `id = -1` 行」显式回填（`WebDavServerService.applyLegacyPrefsOverwrite`，三项偏好全空时不写库；仅当备份 `appPrefs` 确实携带账号键时回填，备份未带账号则保持 DB 不变，避免设备残留偏好覆盖当前配置），对齐原版 `Restore.kt:455-470`「恢复 prefs 后账号立即生效」；v3 备份含 `servers` 键，以备份 DB 行为准、不回读偏好（详见 §2.28 servers 段说明）。② **恢复路径主键保真**（P2-2）：`ServerRepository::restore_upsert_preserving_id` 原样保留备份中的 `id`（含 `0`），普通 `webdavServerSave` 的 `id=0 → 当前毫秒` 新建语义不变；否则同一备份重复恢复会不断产生新行。③ **安全口径差异登记**（P2-3）：我方单文件 JSON 备份为**明文**（既有口径，非本批引入），本批 v3 把 WebDAV 密码扩散到 `servers[].config` 明文，敏感面扩大已登记（原版 zip 备份对 `webDavPassword` / `servers.json` 做 AES 加密；加密另行立项）。④ §2.28 `webdavServerDelete` 标注为「预留（待远程书库批消费）」并补 Dart 单测。 |
| 2026-10-26 | **批8：servers 表契约冻结（用户裁决②「补表+一次性迁移 Flutter prefs+纳入备份」；加法式 +3 方法，契约先行）**：§2.28 新增 `webdavServersList() → Future<String>`（裸 JSON 数组，元素为原版 `Server` 实体 `id`/`name`/`type`/`config`/`sortNumber`，按 `sortNumber` 升序，对齐 `ServerDao.all`）、`webdavServerSave(String serverJson) → Future<int>`（全字段 INSERT OR REPLACE，返回落库 id；id 为 0 按当前毫秒分配、负数 id 原样保留，对齐原版 `Server.id = System.currentTimeMillis()` 默认值）、`webdavServerDelete(int id) → Future<bool>`（按 id 删除，未命中返回 false，对齐 Room DELETE 静默语义）。Rust 实现 `legado-ffi/src/api/webdav_api.rs` → `legado-db::ServerRepository` 单实现；DB `SCHEMA_VERSION` 111→112 建 `servers` 表（DDL 逐列对齐原版 Room v104：`id` INTEGER NOT NULL 主键 / `name` TEXT NOT NULL / `type` TEXT NOT NULL / `config` TEXT / `sortNumber` INTEGER NOT NULL，`Migration111To112` 幂等建表）。备份 `BACKUP_VERSION` 2→3，`BackupData.servers` 纳入该表（形态对齐原版 `servers.json` 实体数组）；恢复按 id REPLACE，旧 v1/v2 备份无该键不触碰库内 servers（对齐原版 `Restore.kt:379-390` 缺文件跳过语义）。Flutter 侧 WebDAV 同步设置（原 `sync_webdav_*` 偏好的 url/username/password）一次性迁移为 `id=-1` 的 `WEBDAV` 行并置 `webdav_servers_migrated` 标记（幂等）；`webdav_api.rs` 既有 `config_json` 入参签名全部不变。§2.28 方法数 7→**10**，附录合计 297→**300**，BookApi 口径 294→**297**；§1.7 表 B 补登记 10 对（既有 WebDAV 7 方法 + 新增 3 方法），同名 FFI 映射 124→**134**、等价对总数 139→**149** || 2026-10-26 | **审查批7c：§1.6.1 预留状态措辞对齐实际消费面（纯文档，零 FFI 签名/§2.x 计数变化）**：`sourceLoginV1` 仅 `ffi.dart` 封装、无业务调用亦无测试消费，状态由「预留（仅测试消费）」更正为「预留（无消费）」；`verificationPending` / `webviewPending` 保持「预留（仅测试消费）」（`test/ffi/ffi_stream_sink_runtime_test.dart` 消费）。§1.6.1 标题与裁决说明同步改为按实际消费面区分，消除「统一仅测试消费」与「无测试消费」的表述矛盾 |
| 2026-10-26 | **审查批7a：死接线转正登记 + `/cache_settings` 死路由删除 + `direct_link_upload` 保留加注（纯登记/清理，零 FFI 签名、零 codegen；§2.x 方法计数与 §1.7 表全部不变）**：① 按用户裁决（2026-10-26）在 §1.6.1 附加登记 3 个死接线——`sourceLoginV1`（Rust `ffi::source_login_v1` → `source_login_v1_api::eval_login_v1`；V1 登录被 V2 协议 / 经典登录 / WebView 三通路覆盖）、`verificationPending` / `webviewPending`（Rust `ffi::verification_pending` / `ffi::webview_pending`；推送式 `verificationRequestStream` / `webviewRequestStream` 已覆盖 UI 需求），状态均为「预留（仅测试消费）」。Rust 实现完好、Dart 仅 `ffi.dart` 封装：两个 pending 另有 `test/ffi/ffi_stream_sink_runtime_test.dart` 消费，`sourceLoginV1` 无业务调用亦无测试消费（纯预留）；未来接 UI 或移除须走契约变更。⑤ 删除 `/cache_settings` 死路由（原 `routes.dart:90,197`）与 `cache_settings_screen.dart` 及溢出回归测试引用（全库零入口，页面含原版不存在的「自动过期策略」；按重构红线清理，未新增任何功能）。⑦ `rust/legado-net/src/direct_link_upload.rs` 仅加文件头保留注释（原版 DirectLinkUpload 能力对应物，原版消费方全部在 UI 域，待「外部文件处理页」UI 批接线；`extract_download_url` 系我方辅助），逻辑零改动。④ Room v104 拷库直开不支持的登记口径回写 ACTIVE_PLAN（本批不改代码）。验证：`flutter test test/unit/api_contract_test.dart` 7/7、`flutter analyze` 0 issue、`flutter test test/unit` 全绿、`cargo check -p legado-net` 通过、`rg "cacheSettings\|CacheSettingsScreen\|cache_settings" flutter_legado/lib flutter_legado/test` 零命中 |
| 2026-10-26 | **审查批6：RSS 源启用/禁用误接书源 FFI 修复——契约冻结（加法式，+1 方法；契约先行，本条目提交先于实现代码）**：§2.5 新增 `rssSourceSetEnabled(String sourceUrl, bool enabled) → Future<bool>`（Rust `ffi::rss_source_set_enabled`，核心实现 `legado-ffi/src/api/rss.rs::set_rss_source_enabled` 走 `legado-db::RssSourceRepository::set_enabled` 单实现）。**缺陷**：`enableRssSource` / `disableRssSource` 此前分别调 `source_enable` / `source_disable`（`rust/legado-ffi/src/api/source.rs:64-71` 走 `BookSourceRepository`）——RSS-only 源报「书源不存在」，同 URL 恰有书源时误改书源。**语义对齐原版**（`app/src/main/java/io/legado/app/data/dao/RssSourceDao.kt:152-153`：`@Query("update rssSources set enabled = :enable where sourceUrl = :sourceUrl")`，Room UPDATE 静默执行、源不存在既不报错也不写书源表）：新方法按 `sourceUrl` 单条 UPDATE `rssSources.enabled`，返回是否实际命中行；**源不存在返回 `false`（不抛错）**，书源表零触碰。`enableRssSource` / `disableRssSource` 的 BookApi 签名与「启用/禁用 RSS 源」冻结语义不变，改为委托 `rssSourceSetEnabled(url, true/false)`。§2.5 方法数 11→**12**，附录合计 296→**297**，BookApi 口径 293→**294**；§1.7 表 B 补登记 `rssSourceSetEnabled` 1 对（既有 `enableRssSource` / `disableRssSource` 两对的 FFI 列由误接的 `source_enable` / `source_disable` 更正为 `rss_source_set_enabled`），等价对总数 138→**139**（改名等价 15 + 同名 FFI 映射 124） |
| 2026-10-26 | **审查批5 文档修整：§1.7 命名等价对补登记（纯文档，零 FFI 签名/方法计数变化）**：原表 A 仅登记 15 对改名等价；本批以 `rust/legado-ffi/src/ffi.rs` 的 284 个 `pub fn` 导出面 × `flutter_legado/lib/src/services/rust_api*.dart` 的 `bridge.<fn>` 调用面程序化提取，补表 B **123 对**「BookApi 同名方法 ↔ Rust 模块前缀导出名」（示例 `getBooks ↔ bookshelf_list`、`getBookSources ↔ source_list`；含 3 条跨导出复合实现 `initialize`/`updateBookmark`/`parseEpub` 与 2 条无前缀命名 `initialize`/`getVersion`）。§1.7 等价对总数 15→**138**（改名等价 15 + 同名 FFI 映射 123）；§2.x 方法行、附录合计 296、BookApi 口径 293 全部不变。同步勘误附录口径：`rssUpdateSource` 已由 BookApi `updateRssSource` 封装（`rust_api_search_rss.part.dart:246-247`），纯 FFI 仅剩 `chapterPayAction` 1 个。证据：`docs/REFACTORING_FULL_AUDIT_REPORT_20261026.md` §四-4 / P2-7；`flutter_legado/test/unit/api_contract_test.dart` §1.7 解析校验全绿 |
| 2026-10-05 | **P2-29c 后续：失败章查询契约冻结（加法式，零破坏，+1 方法，契约先行本批不改代码）**：§2.43 新增 `cacheDownloadFailedChapters(bookUrl) → Future<String>`（§2.43.8）：单次只读查询返回该书批量下载**已失败**章节 index 的 JSON 整型数组（升序、0-based；无失败为空数组）；数据链=任务表 `TaskInner` 与持久化快照新增失败章索引集合（对齐参考版 `CacheDownloadStateStore.kt:35-57` 的 `markFailed`（加入）/`markSuccess`（移除）语义，任务启动清空、恢复回读一并恢复、`persist_snapshot` 含集合）；目录页 ERROR 态（红色重试图标可重试，P2-29c 已落 UI、数据源恒空待接）由此接通。§2.43 方法数 10→**11**，附录合计 293→**294**，BookApi 口径 290→**291**（契约先行，实现批封装后程序化计数转齐） |
| 2026-10-03 | **B2 音频预下载写入面契约冻结（加法式，+2 写面方法；契约先于代码，本批不改任何代码）**：§2.48 新增（补齐 §2.47 只读/清理面所缺写入面，对齐原版 `AudioCacheService` 服务编排 + `AudioCacheManager.cacheChapter` 写入本体）：`audioCacheDownload({bookUrl, chapterIndex, chapterUrl, chapterTitle, playUrl}) → Future<String>`（Rust `ffi::audio_cache_download`，async + spawn_blocking 非阻塞）——单章下载安装，**幂等**（已提交缓存直接返回 `already_cached` 不重下，对齐原版服务循环 `AudioCacheService.kt:216` 跳过语义）；playUrl 由 Dart 经既有 `audioGetChapterMedia`（§2.26 播放取址链）的 `mediaUrl` 解析传入——**修订说明（2026-10-04，主代理据实现批反馈修正）**：初稿写 `getChapterContentFull`，但该链会应用替换规则与简繁转换（`reader.rs:1034,1111`）**可能污染 URL**；原版 `cacheChapterLocked:139-144` 实为播放链 `WebBook.getContentAwait` 输出，与我方 `getAudioChapterMedia` 同源，实现取后者更贴原版；Rust 自 DB 载入 Book/BookSource/BookChapter 后以 `legado-parser::AnalyzeUrl` 等价语义发起下载（headers/cookie/JS/重试全在 Rust；**字节不穿 FFI**——音频可达数十 MB，禁止 base64，系 §2.46 base64 惯例的反例登记，先例 `tts_speak`/`webdavDownloadFile`）；流程逐条对齐 `AudioCacheManager.kt:132-199`：五段式命名（`AudioCachePolicy.kt:67-98`）→ 陈旧未提交清理（1 小时阈值 `:302-314`）→ 流式写 `tmp_*.part`（块级取消检查）→ size 校验 → rename 安装（失败退复制）→ 写 `.complete` 并回读校验 → 同 key 旧版本清理；失败 **Err 上抛不降级**（有意区别于 §2.47 读面降级风格：写入是显式用户动作，错误须驱动 Dart 循环 failCount）。`audioCacheCancel() → Future<bool>`——取消在途下载（进程级取消代数单槽，对齐原版服务单 worker + stop 语义；中止流式拷贝并删部分文件）。**不设**批量队列/进度查询方法（Dart 循环逐章自持进度，原版服务编排不上 FFI）；**不设**容量上限/自动清理（原版无此功能，重构红线禁新增）；**不设**导入/导出（用户已裁决）；原版前台服务保活语义不复制（进程死即停、已装文件保留，登记为已知边界）。决策策略（键计算/文件名/扩展名探测/.complete 安装/已缓存跳过）全部落 Rust，UI 层零业务逻辑。§2.48 方法数 **2**，方法模块 44→**45**，附录合计 291→**293**，BookApi 口径 288→**290**（契约先行，代码未实现，`api_contract_test.dart` BookApi 总数项按预期红、实现批封装后转绿） |
| 2026-10-03 | **cbz 本地漫画批 B：FFI 契约冻结 + bookType 位域 + is_local_book 白名单（E9 参考版扩展，用户已授权；加法式，+1 纯 FFI 方法）**：**契约先于代码**——本条目及同批文档改动先于 Rust 代码落盘（工作树顺序：契约先行，代码随后；若同批提交则契约条目提交在前，见提交记录）。**新增 FFI 方法**（§2.34 压缩包导入 7→**8**，附录合计 286→**287**，BookApi 口径 283 不变——纯 FFI，待 UI 轨后续封装）：`cbzReadPage(path, entry) → Future<String>`（Rust `ffi::cbz_read_page`，实现 `legado-ffi/src/api/cbz_api.rs`；仅走 frb 主链路）——CBZ 本地漫画按条目读取图片字节，返回 JSON `{base64, len}`（与 §2.20 `fetchImageWithDecode` / §2.46 图片缓存的 `{base64,len}` 惯例对齐，§1.3 复杂类型 JSON 约定）；`entry` 兼容带/不带 `cbz://` 前缀（剥前缀后按 ZIP 条目名精确匹配，中文/空格条目名原样，不 URL 编解码）；`path` 为本地书 `bookUrl` 形态（绝对路径原样；相对可迁移标识经 `resolve_local_book_path` 同语义解析，与 §2.9 本地书链路一致）；错误语义：文件不存在 / ZIP 解析失败 / 条目不存在 / 包内无图片条目 → 抛 BridgeError。**bookType 语义补记**：`importLocalBook` 导入 `.cbz` 时 `bookType = LOCAL(0x1000) \| IMAGE_BIT(64)`（位域，对齐 Kotlin `BookType` 位语义）；其余本地格式（txt/epub/mobi/azw/azw3/pdf/umd）保持 `LOCAL` 无媒体位；`origin=loc_book` / `book_url` 相对标识语义不变。**命名域警告（必读）**：新增常量 `legado_core::models::book::book_type::IMAGE_BIT = 64` 属 `Book.bookType` **位域**；既有 `book_type::IMAGE = 2` 属 **BookSourceType 数值域**（书源类型「图片源」），两域禁止混用。**is_local_book 白名单**：新增 `.cbz`（`reader::is_local_book` 后缀判定，与 `.epub/.txt/.text/.mobi/.azw/.azw3/.pdf` 同列）；`.zip` **不加入**（保持压缩容器行为，`archiveImportZip` 路径不变）。**链路衔接**：`.cbz` 加入白名单后，`getChapters` 懒加载经 `LocalBook` → `CbzFile`（批 A `1e7dd3abb3`）解析并入库，`getChapterContent` 返回 `cbz://<条目名>` 行列表，Dart 侧逐行调 `cbzReadPage` 取图渲染 |
| 2026-10-02 | **P5 尾项 server 注入面接入关闭（setup 生成器平移 + `server_deps` 三闭包全量接入；零 FFI 签名变更、零 REST schema 变化、不新增端点；方法表与方法计数全部不变）**：提交 `aa49874137`。**调研翻盘（前批边界登记已被补齐）**：P5 关闭时登记「`login_header`/`book_variable`/`source_context` server 侧注入 None（server 无 DB/登录端点/setup 构造器，行为无损起点，接真实现即生效）」（见本表 2026-10-01 条目⑤及 REFACTORING_ACTIVE_PLAN P5 关闭记录尾项）——本批全部接入真实现，server 注入面不再有 None 占位。**setup 脚本生成器平移**：`legado-fetcher` 新增共享 `source_setup.rs`（宿主数据参数化），ffi `source_js_bindings.rs` 改薄壳 re-export——与 HEAD 逐字一致、diff 为空（code-reviewer 证实）；non-quickjs 档行为保持（返回空串）。**server 三闭包全量接入（`server_deps(state: &Arc<AppState>)`）**：① `login_header`——caches 表 `loginHeader_<source_url>`（与 ffi `source_login_cache::get_login_header` 同键）；② `book_variable`——`find_by_url` → `find_by_origin_book_url` 反查 `books.variable`（与 ffi `db_book_variable` 同语义）；③ `source_context`——`infoMap_<url>`/`loginHeader_<url>`/`userInfo_<url>` 三键 + 共享生成器（与 ffi `explore_info_map`/登录缓存同键）。**`with_state_db` 三级锁**：try_lock 快路径 → 多线程 runtime `block_in_place`（源码级证实慢路径无死锁风险）→ current_thread 测试档 None 降级（=批前行为等价）；code-reviewer 建议的两条禁令已注释（持 guard 任务不得进 fetcher 链、`Runtime::block_on` 根 future 不得直调 webbook 链）。**行为变化范围（接线）**：`build_engine(state)` 签名改动，reader/audio/toc_update 全端点接线；REST `/api/webbook/{search,info,chapters,content}`、`/api/books/:id/chapters/:index/content`、audio、toc_update 对需登录/带变量/需 setup 的书源从「能力关闭（None）」变为「可用」（登录头合并、`books.variable` 变量链、setup 脚本注入 JS 上下文）；不新增端点、不改 schema。**边界登记（未改）**：server 无 login/webView 写入面，登录头/变量生效依赖 server DB 已有行（App/桌面端写同库或外部写库）；`PUT /api/books/{id}` 以 `..Book::default()` 重建行会清空 variable（存量边界）。**测试与门禁**：server 5 新（deps 装配/login_header 种库/book_variable 反查/source_context 内容/REST 端到端 login_header 种→1 条未种→0 条）+ fetcher source_setup 2；回归 server 179、fetcher 84、ffi 403、ffi quickjs 467、server quickjs 180 全绿；clippy 三 crate `--all-targets -D warnings` 通过。**独立审查（code-reviewer）**：pass（无阻塞；P2-1 锁禁令已注释、P3 `leave_native`）。零 FFI 签名/REST schema/方法表变化，§2 方法表与方法计数全部不变 |
| 2026-10-02 | **HTTP P2-19 阻塞项关闭——`enabledCookieJar` 写侧门控（用户裁决方案 A「标记头机制」；零 FFI 签名变更、零 REST schema 变化、零 codegen，方法表与方法计数全部不变）**：提交 `62b04d9998`。**调研翻盘（推翻 2026-09-22 登记前提）**：原登记「打通需 FFI 签名/契约变更 + parser 变更，触碰契约先行红线」不成立——P5 fetcher 下沉后主链路调用点全部持 `BookSource`（共享 `legado-fetcher`），实现零 FFI 导出变更、零 codegen、零方法表变更。**上游真实语义（实读）**：请求**读侧**（携带 DB cookie）在主链路**无条件**（`AnalyzeUrl.kt:126/735-757`）；门控只在**写侧**（`Set-Cookie` 落 DB）——`enabledCookieJar==true` 才由 `AnalyzeUrl.kt` 放置 `CookieJar:1` 标记头，`HttpHelper.kt:84-100` 拦截器按标记头门控 `CookieManager.saveResponse` 写回，`null→false` 判定在 `AnalyzeUrl.kt:126`，Jsoup `get`/`post`/`head` 仅开关开启时补标记（`JsExtensions.kt:532-534/559-561/586-588`）。我方真实缺口仅为**写侧无条件落库**，读侧现状已对齐、逐行未动。**批1（Rust 写侧门控）**：serde 三态 `default_true_opt`（缺键→`Some(true)`、显式 `false`→`Some(false)`、显式 `null`/DB NULL→`None`→按关）；`legado-net` 写侧门控（`COOKIE_JAR_HEADER` 常量 + 6 个发送方法透传 `save_cookies` + `collect_*` 按标记门控 + 唯一建请求点剥离标记头；读侧 `apply_headers_and_cookies` 逐行未动）；`legado-fetcher` `parse_source_headers` 一处覆盖全部主链路调用点（`apply_cookie_jar_marker` 只补不覆盖）+ `search_single_source` 接线。**批2（JS 桥与直发点）**：first-wins 注入钩子 `SourceCookieJarLookup`（tag→`Option<bool>`），ffi `db_open` 与 cookie persistence 同点注册（基于 `BookSourceRepository::find_by_url`）；10 个 JS 网络发送入口按当前书源开关补标记（`http_get`/`http_post`/`http_head`/`ajax`/`ajax_request_body`/`ajax_all`/`connect_full`/`connect_no_redirect`/`head_full`/`post_full`）；读侧 `merge_js_cookies`/`cookies_for_url` 逐行未动；`review`×3/`explore`/`image`/`rss`/`source_checker` 直发点接线；无 source 语境的通用下载路径（`ffi_http_get/post`、`http_get_bytes`、TTS、font、`file_utils`、`jslib_loader`、dict、net rss/cover）保持无标记=不写回（对齐上游），已登记。**审查收尾（code-reviewer 初判 needs changes、无 P0 → 3 项全部闭环转 pass）**：P1 RoomImporter 解析统一（`as_bool().or_else(as_i64.map(n!=0)).unwrap_or(true)`，缺键→1、布尔 `true`→1，消除 server `source_update` 与 FFI `import_sources` 口径分叉及布尔 true 丢失）；P2-1 `RssSource` 同款 `default_true_opt`（core 的 `default_true_opt` 提升 `pub(crate)` 复用）——新导入/保存的 RSS 缺键现在按开（行为变化），库中既有 NULL 行仍按关（不迁移）；P2-2 残差仅登记（`tts_speak_api.rs:64` 与 dict/cover 恒不写，列入下一批接线清单）。**行为变化（均已登记）**：JS 桥每请求一次 `find_by_url` DB 查询（单行索引、不持锁进网络路径，保证运行中开关切换即时生效）；导出再导入 NULL→`Some(true)` 语义翻转（`default_true` 副作用）；同名 `CookieJar` 键自带 header 会被判开（上游同风险，只补不覆盖）；`httpGet`/`httpPost`/`httpHead` 纳入门控为上游超集（方向安全）。**测试（红→绿已做）**：core 4（`BookSource` 缺键/false/null、`RssSource` 同款）+ net 5（标记写回/无标记跳过/raw 两态/大小写/剥离）+ fetcher 2（parse 注入、e2e 缺键导入落库）+ search e2e 2 态 + JS 桥 3（gate 三态 + 2 原失败用例恢复）+ db 5 例三态（缺键/true/false/0/1→1/1/0/0/1 SELECT 断言）。**门禁（实现者+审查+主代理三方）**：db 322 / core 830 / net 257 / fetcher 81 / ffi 401+21 ignored / ffi quickjs 465+42 ignored / legado-js quickjs 657+2 ignored（连续 5 次）全绿；workspace 与 quickjs 档 clippy `--all-targets -D warnings` 通过。**P3 `leave_native`（登记不修）**：关源+规则同名 `CookieJar` 头 fail-open 半边、重定向后续跳无剥离断言、JS 桥其余 9 入口表驱动用例可补、`find_by_url` 每请求开销。**P2-19 至此全部关闭（backlog 五项 + 阻塞项 `enabledCookieJar`）**。零 FFI 签名/REST schema/方法表变化，§2 方法表与方法计数全部不变 |
| 2026-10-02 | **HTTP P2-19 尾项 charset 第四级统计探测（chardetng，零 FFI 签名变更、零 REST schema 变化；方法表与方法计数全部不变）**：提交 `f83b891ed6`。**依赖批准记录**：用户已批准引入 `chardetng` 1.0（纯 Rust、Apache-2.0 OR MIT、依赖仅 `encoding_rs`/`memchr`/`cfg-if`），`legado-fetcher` 的 `Cargo.toml` 带批准注释（2026-10-01 批准）；`encoding_rs` 0.8 由 dev-dependency 升为正式依赖。**四级解码语义表**：`decode_web_response`（`rust/legado-fetcher/src/web_book.rs`，改 pub，抓取链+搜索链唯一入口）按序为 ① 显式 charset（最高优先，不被探测覆盖；对抗用例双证：fetcher 单测 + 搜索级）→ ② `Content-Type` 头 → ③ HTML meta → ④ `chardetng` 统计探测；均未命中走 lossy UTF-8 兜底。对齐上游 `OkHttpUtils.kt:80-96` → `EncodingDetect.kt:18-44`（ICU4J `CharsetDetector`，无阈值）。**第四级细节**：BOM 优先（`Encoding::for_bom`，UTF-8/UTF-16 均支持，上游仅剥 UTF-8 BOM、属合理超集）；`guess(None, Utf8Detection::Allow)`（Allow 必须，Deny 会把无标识中文 UTF-8 误判 windows-1252，审查代理 scratch 实测）；`Iso2022JpDetection::Deny`（Web 内容指引）；探测猜非 UTF-8 走无损解码，失败或猜 UTF-8 回 lossy UTF-8。**搜索链收敛**：`search_single_source` 两分支（needs_charset_decode raw 分支 + 文本分支）统一为 `send_raw` + `decode_web_response`——补齐 meta 级与探测级（改前文本分支 reqwest `.text()` 只认 header）；retry/followRedirects 语义不变（共用 `send_with_options`）。**行为变化（已登记）**：3xx 日志拆两条（4xx/5xx「非 2xx/3xx」+ 未跟随 3xx 单独留痕，合取等价改前 raw 分支完整语义）；重定向后 `final_url` 作为相对链接解析基（改善，302→GBK 目标页用例钉住）。**parser 侧**：`decode_response_bytes` 保持声明解码原语 + lossy 兜底，不加探测（评估注释：避免共享原语语义扩散，探测只在 fetcher 一处）。**已知边界（注释登记）**：猜中 GBK/GB18030 族时无损解码对混合非法字节几乎总成功，个别乱码正文会有损解码进入规则解析（对齐上游无阈值）；JSON 纯 ASCII 不受影响。**测试 8 例**：fetcher 3（四级探测单测含对抗/UTF-8 回归、BOM 处理含 UTF-16LE、fetch_page 无标识 GBK 端到端）+ ffi 5（meta-only GBK、无标识 GBK+负向锚、显式 charset 对抗、UTF-8 回归、302→final_url）；红→绿已做。**门禁（实现者+审查+主代理三方）**：fetcher 79 / ffi 400+21 ignored / parser 314，0 failed；三 crate clippy `--all-targets -D warnings` 通过。**独立审查（code-reviewer）**：初判 needs changes（无阻塞，核心实现经 scratch 实测确认），4 项收尾全部闭环（P1-1 3xx 日志双条、P2-1 final_url 用例、P2-2 误判边界注释、P2-3 负向锚）→ 转 **pass**；P3 `leave_native`（显式 charset=utf-8 + BOM 极端角落保留 U+FEFF）。零 FFI 签名/REST schema 变化，§2 方法表与方法计数全部不变 |
| 2026-10-02 | **HTTP P2-19 批3 `urlOption` `followRedirects`/`retry` 消费接线（零 FFI 签名变更、零 REST schema 变化；方法表与方法计数全部不变）**：提交 `70b7c65e83`。新增汇聚模块 `rust/legado-fetcher/src/analyze_request.rs`（552 行，`send_raw` / `send_text` / `send_with_options`）统一消费 `AnalyzeUrl` 的 urlOption。**followRedirects 语义**：`Some(false)` → 改用 `LegadoClient::no_redirect_variant()`（`rust/legado-net/src/client.rs`，`Arc<OnceLock<LegadoClient>>` 实例级缓存的第二客户端池；clone 共享同池，FFI `shared_client` 场景即进程级）不跟随重定向发送；`true`/缺省 → 沿用现有共享客户端 `Policy::limited(20)`（批1 语义不变）。第二池复用同一 CookieStore（`Arc::ptr_eq` 验证）与持久化后端；首建 `load_all` 为一次性成本（已注释）。**retry 语义（重试边界）**：`retry > 0` 时响应**非 2xx 且非 3xx** 立即原样重发、无退避，总尝试次数 = `retry + 1`；2xx/3xx 为终态（含 `followRedirects=false` 下原样返回的 3xx，不触发重试），传输错误 `Err` 上抛不重试；**不复用 `legado_net::retry::RetryExecutor`**（其指数退避/面向 I/O 错误语义与 urlOption 的响应码级即时重发不等价）。**接线范围**：`fetch_page` 两分支（`web_book.rs`）、`search_single_source` 两分支（`search.rs`）、dict `fetch_body`（`dict_api.rs`，封面规则复用）。**行为变化（上游证实）**：hex（`type != null`）+ POST 书源从「实际 GET」恢复为「按 method POST」派发（上游 `AnalyzeUrl.kt:443` + `getResponseAwait:577-597` 按 method 派发），并补端到端用例 `test_fetch_page_hex_post_dispatches_post` 锁定。**未接线 deferred（各自原因）**：`review_api` 三处（发送 URL 为规则相对路径经 `get_absolute_url` 改写后的 `final_url`，可≠`analyze_url.url()`，需 helper 增 URL override 参数）；`explore_books_async`（现状强制 GET，接线会顺带改 method 语义）；`web_book.rs` 裸 URL 直发点（不持 `AnalyzeUrl`，天然不在汇聚点范围）。**curl 键不补**：`curl_converter` 不加 `retry` 键——上游 `CurlAnalyzeUrlConverter.analyzeOptionKeys` 无 `retry`，逐字一致。**测试**：`analyze_request` 10 例（followRedirects 302 原样/缺省 true 回归、retry 耗尽/成功即停/缺省 0/3xx 不重试、组合 false+retry 重试链不跟随/true+retry 跟随、POST 方法保持、`send_text` 共用循环）+ net 1 例（变体缓存 + CookieStore 共享 + 原客户端 20 跳对照）+ ffi 1 例（searchUrl retry=2 全链路 3 次请求）+ fetcher hex+POST 1 例；红→绿已做（桩 unimplemented 10 红→绿）。**门禁**（实现者 + 审查代理 + 主代理三方复跑）：fetcher 76 / net 252 / parser 314 / ffi 395+21 ignored / server 175，0 failed；四 crate clippy `--all-targets -- -D warnings` 通过；fmt 仅既有漂移（`web_book.rs` `include_str!` 换行，HEAD 记 `:5883` 位移）。**独立审查（code-reviewer）**：初判 needs changes（无 P0/P1），两项 P2 已闭环——P2-1 hex+POST 经上游源码证实维持现实现 + 用例锁定 + 行为登记；P2-2 汇聚点声明修正为准确覆盖范围 + deferred 登记；P3 `leave_native`（persistence `load_all` 权衡已注释）；闭环后满足 `convert_to_check` 转 **pass**。本批零 FFI 签名/REST schema 变化，§2 方法表与方法计数全部不变 |
| 2026-10-02 | **P2-19 `concurrentRate` REST 三态接线（REST schema 加法式；FFI 签名零变化、Dart `BookApi` 面零变化，方法表与方法计数全部不变）**：承接同日「保存刷新接线」批，按用户裁决方案 A 关闭 REST 面残余。**REST schema 加法**：`CreateSourceRequest`（`POST /api/sources`）新增可选 `concurrent_rate`（snake_case；缺键/null → `None`；空串/纯空白 → 按 `None`，对齐原版「空=不限流」）；新增独立 `UpdateSourceRequest`（`PUT /api/sources/:id`），`concurrent_rate` 为三态 `Option<Option<String>>` + 自定义 serde `deserialize_present_option_string`（键存在时再包一层 `Some`，缺键归外层 `None`）。**`concurrent_rate` 三态语义表（`UpdateSourceRequest`）**：① 缺键 = 保留数据库原值且**不刷新**限速注册表；② 显式 `null` 或空串/纯空白 = **清除**（DB 置 `None` + registry `remove`）；③ 合法值 = 入库并**刷新**。create 侧：带合法值 → 入库并刷新；缺键/null/空串/纯空白 → `None`，并清除该 URL 既有 limiter（`INSERT OR REPLACE` 既有行语义）。**update handler**：改为 `find_by_url` 完整实体字段级 mutate（不再 `BookSource::default()` 全列构造），DTO 未暴露字段（`jsLib`/`header`/`variable`/`comment`/`ruleSearch`/`ruleContent` 等）保留；path 不存在维持 `INSERT OR REPLACE`（不加 404）；path/body URL 冲突保持「按 path 查找、写 body URL」现状。**registry 新增原语**（`rust/legado-fetcher/src/rate_limit.rs`）：`remove(source_url)`（map 锁内移除，在途 `Arc` 自然跑完，未注册 no-op）+ `refresh(url, rate)` 统一保存入口（空 / `"0"` / 纯空白 → `remove`，对齐上游 Kotlin `ConcurrentRateLimiter`「空即不限流」；其余 → `update`：合法原位刷新保留窗口、非法不改、未注册不预建）；ffi/server 两处 `refresh_source_rate_limit` 薄壳均改走 `refresh`。**行为变化**：FFI `import_sources` / server `execute_update` 批量路径保存空值从「不改动」变为「移除 limiter」，修复 DB 与 registry 分叉（审查确认合理无回归）。**测试**：fetcher 4 新例（remove 重建/在途 Arc/未注册 no-op/refresh 分发）+ server 7 例（create 带值/缺省清除、update 缺键保留全字段且不刷新、显式 null 清除、空串清除、合法值原位刷新可区分清除重建、path 不存在 upsert）+ ffi 1 例（清除路径）。**门禁**（实现者跑 + code-reviewer 独立复跑）：fetcher 65 / net 251 / db 321 / ffi 394+21 ignored / server 175，0 failed；五 crate clippy `--all-targets -- -D warnings` 通过；fmt 仅两处 HEAD 既有漂移（`legado-fetcher/src/web_book.rs:5883`、`legado-server/src/handlers/web_book.rs:698`，未触碰）。**独立审查（code-reviewer）pass 无阻塞；登记项**：P1-1 path/body URL 冲突时清除/改率只刷新 body URL，path URL 旧 limiter 残留（裁决保留旧行为衍生，leave_native 后续批）；P2-2 create 对已存在 URL 全列 upsert 清空未暴露字段（既有 create 语义，与 FFI `add_source` 一致，不处理）；P3 响应无可观测性区分 / 合法值不 trim 入库（与 create 口径一致，上游同形）。**已知残余延续**：未注册 key 保存合法值后首个旧快照 `acquire` 仍按旧率惰性建（上游以 `update` 预建 record 关闭，我方按「未注册不预创建」约束保留待裁决）。本批为 REST schema 加法，FFI 签名、Dart 面与 codegen 零变化，§2 方法表与方法计数全部不变 |
| 2026-10-02 | **P2-19 `concurrentRate` 保存刷新接线（既有行为修复，零 FFI 签名变更、零 REST schema 变化，方法表与方法计数全部不变）**：修复「书源编辑保存后 `concurrentRate` 不生效」（P2-19 未修 backlog 项）。`RateLimiterRegistry`（`rust/legado-fetcher/src/rate_limit.rs`，自 ffi 下沉的共享实现）：`acquire` 只读配置、仅 key 缺失时按当前快照惰性创建 limiter；新增唯一配置写入者 `update(source_url, concurrent_rate)`（对齐上游 `ConcurrentRateLimiter.updateConcurrentRate`）——已有 limiter 原位更新 `accessLimit/interval` 并保留当前窗口 `time/frequency`（不重置已用次数），空 / `"0"` / 非法 rate 不改动既有记录，未注册 key 不预创建 limiter（「保存后首个 acquire 仍来自旧快照」作为残余登记）。**入口覆盖**：FFI `add_source` / `update_source` / `import_sources`（`legado-ffi/src/api/source.rs`）写库成功后刷新本次书源；server `source_update::execute_update` 经 `RoomImporter::import_book_sources` 成功后刷新本次实际导入 sources。**批量事务语义**：FFI `import_sources` 改走 `BookSourceRepository::insert_batch`（`legado-db::connection::in_transaction` 单事务），server `RoomImporter` 同用该共享事务边界——整批提交成功后才刷新，任一条失败整批回滚、不刷新（消除「前 k-1 条已入库但整体报错」的 DB 与 limiter 分叉态；嵌套事务场景复用外层事务）。**双宿主边界**：ffi 与 server 可同进程并存但各持独立 static registry，各自保存入口刷新各自实例；REST/FFI 同源并发窗口仍分叉，单例收敛另立项。**REST 面**：create/update DTO 不携带 `concurrentRate`，本批未扩展 REST schema、未改其原有字段语义，仅批量 source_update 接线；REST 编辑支持 `concurrentRate` 与其 update 全行 replace 可能把旧 rate 置空，登记为待用户裁决。本批为 Rust 内部行为修复，Dart `BookApi` 表面与 codegen 零变化 |
| 2026-10-01 | **漫画设置作用域书级字段（加法式，零 FFI 签名变更，方法数不变）**：按用户裁决对齐参考版「本书覆盖 + 全局回退」——`Book.readConfig` JSON 加法式新增可选 `mangaScrollMode`（书级翻页模式）与 `webtoonSidePaddingDp`（书级条漫侧边留白），均为 null/缺失 = 未覆盖、跟随全局 `MangaConfigKeys.scrollMode` / `MangaConfigKeys.sidePadding`。**单位口径（必读）**：`webtoonSidePaddingDp` 键名沿用以保持参考版作用域对齐，但**单位不是 dp**，值为 Flutter 现行百分比口径 0..45（每侧留白 = 视口宽 × p/100），不引入 dp/百分比换算。Rust `ReadConfig`（`legado-core/src/models/book.rs`）加法式类型化接收（`skip_serializing_if = "Option::is_none"`），修复此前 `updateBook` 全行回写链因类型化结构体不含该键而静默丢弃的问题；旧 JSON/旧数据库缺键 → `None`，空 readConfig JSON 形态与既有行为不变；进度/其他 readConfig 字段保留（进度列结构性排除不回滚）。Dart 端复用既有 `BookApi.updateBook`/`Book.copyWith(readConfig:)`（无新 FFI 方法、无签名变更、无 codegen 变化）；Flutter 阅读器有效值 = 书级 `readConfig` ?? 全局键 ?? 默认，「跟随全局」= 删键回退。回归测试：`legado-core` 三例（round-trip/旧 JSON 缺失/单项独立）、`legado-db` 两例（update 回写保留书级字段与进度、旧库 JSON 回写不新增键）。§2.2 方法数 10 不变、附录合计不变 |
| 2026-10-01 | **P5-1/P5-2 双实现下沉共享 crate 行为补记（内部重构，零 FFI 导出变化）**：server（REST `/api/webbook/*`）的 `RealBookSourceFetcher` 与 `login_check.rs` 本是 ffi 同类型的能力阉割分叉副本（P5-1/P5-2 缺陷登记，原版佐证 BookController.kt 直调共享 WebBook 单例）。三个提交完成合一：`bef38c3f25`（loginCheckJs 内核+QuickJsExecutor 下沉 legado-js）+ `f5ecbc0961`（新建 legado-fetcher 共享 crate，ffi fetcher 本体迁移）+ `2bdad331dc`（server 切共享实现+REST 改接自由入口）。**FFI 导出零变化**（ffi.rs:1280-1336 四个 `webbook_*` 签名与 FRB 绑定不动，codegen 未重跑）；REST 路由与响应 JSON 结构不变。**行为补记（server 侧能力增强，均属缺陷修复本身）**：① loginCheckJs 沙箱档统一为 ffi 原版（`allow_script_run=true`+64MB+RESPONSE/JSOUP 桥）——server 原裸档（eval 禁用/16MB）下依赖 eval 的 loginCheckJs 由误判 LoginRequired 变为可正确执行；② REST 端点获得源级 `concurrentRate` 限速门控（旧版零限速）、charset 三级解码（GBK 站点不再乱码）、data:URI/hex/final_url/cookie 按域合并/分页与变量字段；③ REST 改接 fetcher 自由入口后 mainJs **JS 书源分派经 REST 可用**（旧版 JS 源经 REST 恒失败）、begin_book_flow 流程生命周期接入、章节 index 语义与 App 对齐（不再叠加 0..n 重排）；④ 空 searchUrl 校验 500→400 Parser（引擎前置校验，对齐 App 自由入口）；⑤ `login_header`/`book_variable`/`source_context` server 侧注入 None（server 无 DB/登录端点/setup 构造器，行为无损起点，接真实现即生效）；⑥ flow scope 进程级单槽竞态为原版同构已知接受项。独立审查（code-reviewer）结论 pass（3 项 P2 登记：fetcher 测试夹具跨 crate 引用、双宿主限速表注释互认、REST 序列化往返开销）。§2.17 方法表与计数全部不变 |
| 2026-09-29 | **P4-1 C4 正文链空正文规则语义事实补记（纯补记+测试固化，零行为变更）**：§2.17 新增 ℹ️ 补记——正文规则 `ruleContent.content` 为空时，**非 JS 书源**的 `webbookContent` / 阅读正文链**不请求章节页**、直接返回**章节 URL 字符串**（Rust 短路位于 `WebBookEngine::get_content` 包装层 `legado-core/src/web_book.rs`，对齐原版 Kotlin `WebBook.kt:429-433`「正文规则为空,使用章节链接」——两侧语义一致，**无差异**）；JS 书源（`mainJs` 非空）豁免该短路，进入 fetcher 正文链（空规则 → 章节页 body 直用，是 `parse_content_page_with_bindings`「body 直用」分支的唯一可达路径，非 JS 源经引擎路径不可达）。P4-1 调查稿 §6 C4 原表述「空正文时 Rust 返回 body HTML、原版返回章节 URL 字符串」**与实测行为不符**（包装层先于 body 直用分支短路），本补记以实测行为为准并勘误。固化测试 `rust/legado-ffi/tests/comic_content_fixture.rs::test_empty_content_rule_returns_chapter_url_like_original`（离线回环：章节页路由注册但断言零命中 + 正文 == 章节 URL）。无签名/行为变更 |
| 2026-09-29 | **P2-29 目录章节行状态机对齐参考版五态：新增只读查询 listDownloadingChapters（加法式，零破坏，+1 方法）**：用户验收反馈「下载中缺少过渡动画」——P2-28b/c 目录轮询只翻转缓存态，批量离线缓存下载中章节行无 DOWNLOADING 态动画，且我方当前章 check_circle 与参考版 SUCCESS 态撞形。§2.43 加法式新增 `cacheDownloadRunningChapters(bookUrl) → Future<String>`（§2.43.7）：单次只读查询（纯任务表读 + 恢复回读，**零写入**）返回该书当前在途下载章节 index 集合，JSON 整型数组 `[2,3,...]`（0-based 升序；无活跃任务返回空数组）；Rust `cache_download_api::cache_download_running_chapters`（进程内任务表纯读 + `ensure_restored` 落库恢复回读：每 `running` 任务在途章 = `next_index`（worker 顺序下载，`[start,end]` 闭区间内方收录））；FFI `ffi::cache_download_running_chapters`（frb 主链）+ FRB codegen；Dart `BookApi/RustApi/MockBookApi.listDownloadingChapters`（RustApi 解析 JSON 数组为 `List<int>`）；目录页 1s 轮询（P2-28b/c）同周期拉取下载中集合驱动五态行（isDur location_on / DOWNLOADING 16px 转圈 / ERROR 红色重试 / NONE ⬇ / 已缓存无图标）。ERROR 态数据链：任务表仅 failed 计数、无逐章失败记录（记录需任务表写路径改动，超出本批授权）→ 目录页 ERROR 分支先落、数据源恒空（恒不显示，不伪造），待数据链补齐后接。§2.43 方法数 9→**10**，§1.7 等价对 13→**14**，附录合计 283→**284**，BookApi 口径 280→**281** |
| 2026-09-28 | **P2-28c 目录页实时字数刷新数据链：新增只读查询 listCachedChapters（加法式，零破坏，+1 方法）**：2.0.319 真机点验发现 P2-28b 轮询只 diff URL 集合（翻转 ⬇ 图标），字数胶囊渲染数据（章节 wordCount）不在轮询刷新路径内——批量缓存下载中胶囊要重开目录才出现。§2.43 加法式新增 `cacheListCachedChapters(bookUrl) → Future<String>`（§2.43.6）：单次只读查询返回该书已缓存章节的 (chapter_url, wordCount) 集合，JSON 对象数组 `[{"url":"...","wordCount":"..."}]`（按 chapter_index 升序、空 url 过滤；wordCount 取 `chapters` 表当前值（P2-28b 回填链同源），未回填为空串；有目录书过滤已退出当前目录的陈旧缓存行，与 §2.43.5 同步）；Rust `cache_api::list_cached_chapters`（纯 SELECT，复用 `CacheBookRepository::get_by_book` + `BookChapterRepository::find_by_book_url` 零额外查询）；FFI `ffi::cache_list_cached_chapters`（frb 主链）；Dart `BookApi/RustApi/MockBookApi.listCachedChapters`（RustApi 将 JSON 解析为 `Map<String, String>` url→wordCount，空 wordCount 不收录）；目录页 1s 轮询（P2-28b）升级为新方法：一次调用同时 diff URL 集合（翻转 ⬇）与刷新字数映射（新缓存章字数胶囊同帧出现，对齐参考版 ChapterListFragment 订阅 SAVE_CONTENT 同帧刷行语义）；查询失败保留旧态，dispose/停轮询语义不变。§2.43 方法数 8→**9**，§1.7 等价对 12→**13**，附录合计 282→**283**，BookApi 口径 279→**280** |
| 2026-09-28 | **STAGE3-C2B 刷新正文对齐上游原版强制联网重取（用户已裁决，加法式新增 1 方法）**：§2.16 加法式新增 `clearChapterCache(bookUrl, chapterIndex) → Future<int>`——删除指定书籍单章的正文缓存行（对齐上游原版 `BookHelp.delContent` 章级语义：仅删该章缓存行、**不触碰** `sameTitleRemoved` 等章级开关键、行不存在为 no-op 成功、空 bookUrl 返回参数错误、**不触发整书清理**）；FFI `ffi::cache_clear_chapter`（Rust `cache_api::clear_chapter_cache` → `CacheBookRepository::delete_by_book_and_index`）。Dart 阅读器 `refreshChapterContent` 编排改为「先失效当前章 → 再抓取」（对齐上游 `ReadBookViewModel.refreshContentDur` = `BookHelp.delContent` → `ReadBook.loadContent`），移除 C2 期自创的「抓取成功后才失效 + 成功后整书 `clearBookCache`」——已缓存章节点刷新必发网络请求，失败仅丢当前章缓存（同书他章缓存保留，UI 保留旧正文并显示失败原因）。§2.16 方法数 8→**9**，附录合计 281→**282**，BookApi 口径 278→**279** |
| 2026-09-24 | **换源感知等待（搜索期预拉缓存 + 可取消 apply，加法式，零破坏）**：对齐上游 Android `ChangeBookSourceViewModel` 三步——① 搜索期 enrich 对候选做内存预拉缓存写入（有界并发 8、单候选 60s 超时、失败/超时隔离直通；缓存 key `source_url\u0000book_url` 对齐上游 `primaryStr()`、目录上限 30000 章）；② §2.4 加法式新增 `switchSourcePrefetch(bookUrl, newSourceUrl, newBookUrl) → Future<String>`——命中预拉缓存直接提交缓存详情+目录（**零网络、选中即落地**），部分命中仅补抓目录，未命中现场抓取（执行链同 `switchSource`，既有方法冻结不变）；③ §2.4 加法式新增 `cancelSwitchSourceApply() → Future<void>`（对齐上游 `cancelChangeSource` L715-721）——apply 代数 +1 并 bump 目录刷新代数，在途 apply 提交前三点代数比对即中止（DB 零变更），在途目录分页链下一页边界中止；④ Flutter 换源页：apply 在途展示可取消加载态（spinner + 取消钮），进度串对齐上游 zh「结果 N，进度 M/K：源名」（values-zh/strings.xml:1457 + ChangeBookSourceDialog.kt L286-298）。§2.4 方法数 17→**19**，附录合计 278→**280**，BookApi 口径 275→**277** |
| 2026-09-22 | **队列⑩a P2-20 搜索跨源聚合三路径语义收敛（加法式，零破坏，方法数不变）**：P2-20 裁决落地——三条路径（Dart 纯函数 `applyPrecisionSearch` / `SearchNotifier` 增量桶 / Rust `aggregate_search_books` 单一真源）**在同一输入列表内**统一到同一语义：入桶前跨桶预去重（seen 键为**原始** `name|author|origin` 三段，与运行时 `_seenKeys` 逐字一致），同一 `(name, author, origin)` 仅**首次到达**入桶（落桶由首次到达决定，四桶优先级 equal→tags→contains→other 不变），后续同键到达丢弃（origin 由首条代表，跨源计数由桶内 `origins` 集合承载）。实现：纯函数（`search_state.dart`）与 Rust 入口（`legado-core::search_aggregate`）各补 `seen` 门控；`search_notifier.dart` 运行时路径仅补注释、行为不动（语义基准）。两端各新增 2 条单测（同键 kind 分桶 → 仅首条 1 条，含 assert_ne 回归保护；不同 origin 各保留、origins 累加）+ 跨端夹具 `cross_source_merge.json` `keep_other` expected 8→7 条（若回退为无 seen 的四桶独立实现，该 case 由 7 变 8 条、夹具变红——回归保护）。**范围限定（必读）**：该统一仅在**单次调用的输入列表**内成立——运行时 `_seenKeys` 为**会话级跨页**（跨页 APPEND 不清空，直至新关键词/清空），纯函数 / Rust 入口为**单次调用**语义、不携带会话状态；未来若把运行时聚合切到 Rust 入口，须传**会话累积列表**（会话内全部 books）而非单批 `SearchSourceBatch.books[]`，否则跨页同键书会重复计数（跨页重复回归）。§2.4 方法数 17 不变、附录合计不变 |
| 2026-09-22 | **队列⑩a P1-1 项2 搜索跨源聚合单一真源（加法式，零破坏，方法数不变）**：① **Rust 单一聚合入口**——`legado-core` 新增 `search_aggregate` 模块（`aggregate_search_books(books, key, keep_other)` 纯函数：归一化清洗 / 聚合键 `name\u0000author`（清洗后值）/ 四独立桶 equal→tags→contains→(keep_other) other / 桶内 originsCount 降序 + 首次到达索引平局 / 归并时 origins 并集累加（首次出现序，origin 去重不重复计数）+ `hasReadRecord` 跨源 OR + 首条到达元数据保留 / 空 key 原样返回），与 Dart 现行**纯函数** `applyPrecisionSearch`（`search_state.dart` L144-207）**逐条对齐（对齐范围严格限定为纯函数，不覆盖 `SearchNotifier` 增量桶路径——该路径入桶前多一层 `_seenKeys` 预去重（`search_notifier.dart` L307-310，`_seenKeys` 声明 L64），同名同作者同 origin 且 kind 分落不同桶时（如「都市情缘+乙」同源两条）纯函数/本入口产出 2 条、增量路径仅 1 条；差异登记 `REFACTORING_ACTIVE_PLAN.md` P2-20 待裁决，故本模块不得与增量路径称「完全一致」）**；FFI 层 `legado-ffi/src/api/search.rs::aggregate_search_books_json(books_json, key, keep_other) → Result<String>` 作为跨端校验入口（**FFI crate 内 pub 函数，本轮不做 FRB 暴露**——避免 codegen + `BookApi`/`MockBookApi` 同步面，Dart 运行时聚合切换留待后续批次，届时直接包装本函数）。② **`CoreSearchBook`（`SearchSourceBatch.books[]` 元素）加法式新增可选字段 `origins`（string 数组，serde default + 空时省略序列化）**——由聚合入口产出（同名同作者跨源合并后累加的 origins，首次出现序）；既有流式批次 / 解析 / DB 读路径不填充（空 → 序列化省略 → 批次 JSON 形态零变化），旧消费方零破坏。③ **Dart 侧加法式消费**——`SearchBook.origins`（`@Default([])`）+ `SearchResult.fromSearchBook` 非空时优先作为有效 origins（对齐 Rust `effective_origins` 规则：origins 非空→用它；否则 origin 非空→`{origin}`；全空→空集合，计数下限 1）；**Dart 运行时聚合路径（`SearchNotifier` 增量桶 + 150ms 节流）本轮不切换**——切换为每次 flush 跨 FFI 全量聚合将引入 O(n) 性能回归与会话态映射复杂度，非最小改动，故本轮交付 Rust 参考实现 + 加法式字段 + 跨端夹具锁定两端等价。④ **跨端夹具校验**——`rust/legado-ffi/tests/fixtures/search_aggregate/cross_source_merge.json`（books + expected，含跨源同名合并 / 作者「作者：」前缀与书名「 作者」后缀归一化 / 同源重复去重 / 四桶分落（同一键因 kind 差异落不同桶）/ 预填 origins 字段 / hasReadRecord OR / keep_other 两态），Rust 集成测试 `tests/search_aggregate_fixture.rs` 与 Dart 单测 `test/unit/search_aggregate_fixture_test.dart` 各跑同一夹具与 expected 比对（origins 按序比对（首次出现序为契约）、其余字段顺序敏感，不依赖真网络），已验证 Rust 聚合结果 ≡ Dart 现行纯函数 `applyPrecisionSearch` 期望。**双轨确认记录（一句）**：本变更 Rust/Flutter 双轨均归我方——Rust 侧仅 `search_aggregate` 新模块 + `CoreSearchBook.origins` 加法式字段 + FFI 内 pub JSON 入口（无 FRB 签名变更），Flutter 侧仅 `SearchBook.origins` 加法式消费（增量桶聚合路径不变、UI 零改动），既有搜索批次 JSON 形态与行为零变化。§2.4 方法数 17 不变、附录合计不变 |
| 2026-09-22 | **队列④ P1-B 单源搜索失败 UI 落地（纯 Flutter，无新 FFI，方法数不变）**：§2.4 `searchMultiStream` 批次事件 `error` / `source_name` 字段原在 Flutter 侧仅 `AppLog` 留痕（单源失败 UI 不可见）。本次落地最小可见呈现：`SearchNotifier` 批次监听将单源失败累积进 `SearchState.failedSources`（按源名去重、最新错误优先；新关键词搜索 / 清空结果 / 页面重开三处会话重置，同关键词续页会话内累积），搜索结果页顶部（列表头位置）以非阻断横幅呈现——文案取批次 `error`（含书源能力受限提示），点击展开可见逐源明细（`source_name` + `error`）。整体搜索交互不变（失败源不阻断搜索，对齐原版 `SearchModel` 静默语义，仅把「仅 AppLog 留痕」升级为「留痕 + 可见呈现」）；FFI 契约零变更，§2.4 方法数 17 不变、附录合计不变 |
| 2026-09-19 | **搜索批次逐源错误八分类（任务书 B P2 项1，加法式，零破坏）**：§2.4 `searchMultiStream` 批次事件 `SearchSourceBatch` JSON 新增可选字段 `error_class`（字符串枚举，八类：`ok` / `empty` / `http_error` / `timeout` / `login_required` / `js_error` / `parser_error` / `cancelled`）；分类在 Rust 侧批次组装单点完成（`search.rs` `run_multi_stream` 批次闭包对 `LegadoError` 变体做映射，不可归类的落到最近类别并在报告说明）；现有 `error?` 字段及其语义保持不变（冻结约束），不读该字段的旧调用方零破坏；§2.4 方法数 17 不变、附录合计不变。**双轨确认记录（一句）**：本变更 Rust/Flutter 双轨均归我方——Rust 仅批次 JSON 加法式扩展；Flutter 侧 `ffi.dart` 批次事件解析加法式同步，UI 展示已落地（队列④ P1-B，2026-09-22：单源失败累积 `SearchState.failedSources` 并在搜索结果页顶部以非阻断横幅呈现，既有批次消费路径不变） |
| 2026-09-13 | **替换规则预览 `@js:` 补齐（跨轨批次）**：§2.8 加法式新增方法 `previewReplaceRule(ruleJson, sampleContent) → Future<String>`（替换规则编辑器预览：对单条规则在示例文本上执行真实替换管线——正则（regex 优先 / fancy-regex 回退）/ 字面量 / `@js:` QuickJS 执行 + 逐规则超时；成功=返回替换后文本；规则级错误（非法正则 / `@js:` JS 异常 / 执行超时）=返回 `⚠️ ` 前缀错误文本（可直接展示于预览区，不上抛异常）；非法输入（JSON 解析失败）MAY Err）；§2.8 方法数 7→**8**，附录合计 277→**278**，BookApi 口径 274→**275** |
| 2026-09-13 | **替换规则书源作用域（scopeSource）全链路加法式（跨轨批次，对齐原版 `ReplaceRule.scopeSource`）**：① 契约——FFI `replaceRuleAdd` / `replaceRuleUpdate`（§2.8）各新增末尾可选参 `scopeSource: Option<bool>`（add 缺省=false 对齐原版；update 未提供=保留既有值）；`replaceRuleList` / `replaceRuleEnabled` 返回 JSON 项自动新增 `scopeSource`（缺省 false，旧调用方零破坏）；§2.8 **新增方法** `applyReplaceRulesToSource(sourceJson, sourceName, sourceUrl) → Future<String>`（书源导入时替换：仅取 isEnabled && scopeSource && pattern 非空规则，scope/excludeScope 按「源名称或 URL」contains 忽略大小写匹配——与标题/正文上下文的「书名/书籍来源」匹配是两套独立上下文，不复用 ScopeContext；正则带超时、`@js:` 复用正文管线、非正则按字面量替换；未命中=原样返回，规则级错误不上抛 FFI、保留原文不阻断导入）；§2.8 方法数 6→**7**，附录合计 276→**277**，BookApi 口径 273→**274**；② DB——`replace_rules` 表新增 `scopeSource INTEGER NOT NULL DEFAULT 0` 列，DB v108 迁移预告（SCHEMA_VERSION 107→**108**，幂等：user_version 门禁 + table_info 缺列检测，down 不可回滚），并纳入 `repair_legacy_columns` 防「版本已到 108 但缺列」历史坑 |
| 2026-09-11 | **替换规则写接口加法式扩参（A3 存量阻塞项，跨轨批次）**：FFI `replaceRuleAdd` / `replaceRuleUpdate`（§2.8 替换规则操作）新增 5 个可选参 `group: Option<String>` / `scopeTitle: Option<bool>` / `scopeContent: Option<bool>` / `excludeScope: Option<String>` / `timeoutMillisecond: Option<i64>`。缺省语义：add 未提供=旧行为（group=null / scopeTitle=false / scopeContent=true / excludeScope=null / timeout=3000ms）；update 未提供=保留既有值，提供空串=清除该字段。存储与读链路（replace_rules 表 upsert + `content_processor` 按 scope/scopeTitle/scopeContent/excludeScope 应用）早已存在，本次补齐写侧使 分组/作用范围/排除范围/超时 真正落库；BookApi 签名不变（仍传 ReplaceRule 对象，UI 层零改动），§2.8 方法数 6 不变、附录合计不变。**A3 阻塞项状态：①「FFI 写接口窄」已解除（写链路已补齐）；② scopeSource、③ @js: 预览仍受阻** |
| 2026-09-11 | **readRecordDaily 单位归一（修复，非签名变更）**：2026-08-29 上线的写路径把毫秒增量写进契约声明为秒的 `durationSeconds` 列，当日聚合值放大 1000 倍（热力图时长配色全天饱和、首页今日目标表盘恒满、按天视图显示「75天」级时长）。写路径改按整秒差值入账（`read_time/1000 − old_read_time/1000`，不因频繁小增量截断丢秒）；新增 DB v107 迁移把存量行整除 1000 归一（`Migration106To107`，user_version 门禁保证仅执行一次，SCHEMA_VERSION 106→**107**）。FFI 签名与 §2.12 方法数不变 |
| 2026-09-03 | **换源搜索流式化 FFI 冻结**（换源修复任务书批次 3 / T6，加法式）：`searchSourceStream`（§2.4 换源搜索流：Rust 侧 `ffi::source_switch_search_stream(book_name, author, source_urls_json, options_json, sink: StreamSink<String>)`，逐源完成即推一批次——进度 `finished_count`/`total_count` + 当前已过滤评分排序候选全量快照 `matches[]`；DB 复用路径单批推送；enrich 流内后置不阻塞首批到达）。旧 `searchSource` 保留兼容。§2.4 方法数 16→**17**，附录合计 268→**269**，BookApi 口径 265→**266** |
| 2026-09-03 | **换源执行链与变量链对齐**（换源修复任务书 T2/T3/T4/T5，加法式）：`searchSource` 返回 `matches[]` 项新增可选 `variable`（搜索期级联变量，对齐 SearchBook.toBook 复制语义）；`webbookInfo` 返回 JSON 新增可选 `variable`（bookInfo 规则求值 `@put`/`putVariable` 级联导出，无专用规则字段）；搜索结果项与 `searchBooks` 持久化启用 `variable` 透传（元素级导出）；`switchSource` 签名不变、行为对齐原版 getToc（详情解析→真实 tocUrl 取目录→失败即失败保留旧源；book.variable=候选与详情页变量合并、详情页优先；章节落库保留 variable/isVolume）。§2.4/§2.17 方法数不变 |
| 2026-08-29 | **热力图每日时长聚合契约**（U 侧 UI_MD3_PLAN 登记）：加法式——`readRecordDailyList(int year)`（§2.12 阅读记录组，返回 `[{date, seconds}]` 日期升序）；`putReadRecord` 写路径增量累加当日 readRecordDaily（新 readRecordDaily 表：date TEXT PK + durationSeconds，增量 > 0 入账，本地时区）。§2.12 方法数 5→**6**，附录合计 267→**268**，BookApi 口径 264→**265** |
| 2026-08-25 | **P3-5 换源页 parity**：加法式——`updateSearchBookScore` / `deleteSearchBook`（§2.4 搜索组，对标原版 SourceConfig 书维度评分与换源长按删除）；`searchSource` 返回 `matches[]` 项新增 `book_score`（-1/0/1）。§2.4 方法数 14→**16**，附录合计 265→**267**，BookApi 口径 262→**264** |
| 2026-08-24 | **搜索 parity 批次B FFI 冻结**：breaking——`searchMultiStream` Rust 签名 `ffi::search_multi_stream` 新增 `page: i32` 入参（页码透传，双轨评审记录：两轨均归我方 + 用户已批准批次B范围）；加法式——`pauseSearch()` / `resumeSearch()`（软暂停门控，SEARCH_PAUSED，仅拦未派发书源）+ 批次事件 `has_more` 字段（累积非空判定）。§2.4 方法数 12→14，附录合计 263→**265**，BookApi 口径 260→**262** |
| 2026-08-22 | **P1-3 契约自动校验**：新增 `test/unit/api_contract_test.dart` 程序化交叉校验（BookApi⊆RustApi/MockBookApi、§2.x 各节声明数、附录镜像、计数口径）；§1.7 补登录四方法命名等价对（`getLoginHeader` / `getLoginInfo` / `putLoginHeader` / `putLoginInfo`）；修正 6 处章节标题计数（2.3/2.5/2.9/2.18/2.41/2.43）+ 6 行附录计数；附录合计 251→**263**，BookApi 口径 252→**260** |
| 2026-09-15 | **N5 目录字数胶囊（无新 FFI 方法，JSON 加法式字段）**：`WebChapter`/`BookChapter` 章节 JSON 新增可选字段 `wordCount`（规则源由 `ruleToc.updateTime` 规则 info 经 `AppPattern.wordCountRegex` 等价正则 `(?:^|字数[：:、]?\s*|\s+)([0-9万千百.]{1,6}字)` 提取；JS 书源读章节 `wordCount` 键；`refreshToc` 落库透传）。Dart 侧 `BookChapter.wordCount` 已有（`@JsonKey(name: 'wordCount')`），目录页字数胶囊按「有值才渲染」，方法表不变 |
| 2026-08-01 | 契约初版冻结（v1.0） |
| 2026-08-10 | 第二批后置项 FFI 冻结：三个加法式新增——`shrinkDatabase`（§2.16 缓存管理）/ `webdavUploadFile`（§2.28 WebDAV 云同步）/ `toggleSameTitleRemoved`（§2.9 阅读器操作），契约合计方法数 174→177（Task #50） |
| 2026-08-10 | 第三批后置项 FFI 冻结：两个加法式新增——`setSourceVariable`（§2.3 书源操作）/ `getBookmarksByBook`（§2.7 书签操作，书签作者维度查询）+ `book_sources` 表补 `variable` 列 schema 迁移预告（SCHEMA_VERSION 102→103，幂等迁移），契约合计方法数 225→227（Task #63） |
| 2026-08-10 | 第四批后置项 FFI 冻结（Task #72）：三个加法式新增——`setCustomHosts`（§2.20 网络组，对齐原版 hosts 映射 JSON 对象）/ `setMcpPort`（§2.22 服务器组，**决策：对齐原版独立端口方案**，不复用 `setServerPort`，默认 1236，≤0=停止独立 MCP 服务）/ `searchCoverRules`（§2.4 搜索组，coverRules 表规则搜封面），附录合计 236→239，BookApi 口径 227→230 |
| 2026-08-12 | 远程书库（P1-5）加法式新增——`webdavDownloadFile`（§2.28 WebDAV 云同步，镜像 `webdavUploadFile`，二进制落盘）；远程服务器列表沿用 Flutter `SettingsService` 持久化（对齐原版 `servers` 表语义，不新增 Server CRUD FFI）。附录合计 239→240，BookApi 口径 230→231 |
| 2026-08-12 | P1-2 加法式新增——`clearCookie`（§2.3 书源操作，对齐原版 `CookieStore.removeCookie`）：按 URL 二级域名清除持久层 + 共享 HTTP 内存 CookieStore + JS 宿主 Cookie；附录合计 240→241，BookApi 口径 231→232 |
| 2026-08-13 | P2-4 部分：恢复忽略项 UI + `localBook` 在调用 `restore` 前由 Flutter 过滤备份 JSON（无新 FFI）；「导入旧版」仍隐藏待确认 |
| 2026-08-13 | P2-4 续：恢复忽略项其余键——备份 JSON 注入 `appPrefs`，恢复时按 BackupConfig.keyIsNotIgnore 过滤（readConfig/themeMode/themeConfig/coverConfig/bookshelfLayout/showRss/threadCount）；无新 FFI |
| 2026-08-13 | P2-1：底栏皮肤最小可用——纯 Flutter（`archive` zip 导入 + PrefKeys.bottomBarSkin）；**无新 FFI** |
| 2026-08-12 | P1-14 加法式新增——`looksLikeCurl` / `curlToAnalyzeUrl` / `analyzeUrlToCurl`（§2.3 书源操作）：对齐原版 `CurlAnalyzeUrlConverter`；Rust 复用 `legado-parser::curl_converter`。附录合计 241→244，BookApi 口径 232→235 |
| 2026-08-14 | **发现页控件 action**：加法式 `exploreEvalAction` / `exploreEvalUiJs`（§2.18）；`java.refreshExplore` 经 ui_action_queue 回传 `refreshExplore` 标志 |
| 2026-08-14 | **F3-17**：加法式 `rssListReadRecordsByOrigin`（§2.35）；**F3-10** 契约全面同步至 BookApi **247** 方法、附录 **251** |
| 2026-08-14 | **F3-14**：加法式新增 `httpGetBytes`（§2.20）；UI 层 8 处裸 `http.get` 收敛至 Bridge；附录 244→245，BookApi 233→234 |
| 2026-08-14 | **F3-5**：§1.6 登记 9 个 FFI 非 Result 导出豁免（只读/哨兵语义，不改签名） |
| 2026-08-13 | P2-8：检查更新对接 GitHub Release API（`AppUpdateService` + `UpdateDialog`）；纯 Flutter HTTP，**无新 FFI** |
| 2026-08-13 | P2-7：AutoTaskDebug 流式调试——UI 逐行回调 + `TaskResult.details` 对齐 LogFormatter；复用 `autoTaskExecuteWithId`，**无新 StreamSink FFI** |
| 2026-08-13 | `getSameTitleRemoved` / `canRemoveSameTitle` 权威查询与试算 FFI（§2.9）；UI 勾选态改读 caches KV；复刻「未找到可移除的重复标题」提示 |
| 2026-08-13 | **DB schema 结构对齐专项落地**（台账称「schema v102」，代码版本号 **103→104**，因 102/103 已分别用于 cached_chapters 复合索引与 book_sources.variable）：rssArticles/rssStars/readRecord 主键重建；rssReadRecords/httpTTS（原 http_tts）/search_keywords 结构对齐 Room v95；rssSources 去掉 enableCookieJar 冗余列；coverRules 纳入建表清单。无新 FFI；Repository 列名随表结构适配。残留：rule_subs/dict_rules/keyboard_assists 表名仍为 snake_case（见台账 §4.2.1） |
| 2026-08-13 | **D1**：SCHEMA 104→105，`ruleSubs`/`dictRules`/`keyboardAssists` 对齐 Room 表名列名（Migration104To105） |
| 2026-08-13 | **F4**：封面规则 CRUD 加法式新增——`getCoverRule` / `saveCoverRule` / `deleteCoverRule`（§2.4，对齐原版 `BookCover` + `CoverRuleConfigDialog`） |
| 2026-08-13 | **F5**：`setMcpPort` 对齐原版 LAN（`0.0.0.0`）+ `jsSourceApiToken` 启动前置 + `X-Legado-Token` 鉴权（§2.22） |
| 2026-08-13 | **SOURCE_DIFF P0-1**：`@put:`/`@get:`/`setLocal` 变量系统落地——`AnalyzeRule` 会话变量 + 章节 `WebChapter.variable` / `BookChapter.variable` 透传；**无新 FFI 方法**（既有 webbook/reader JSON 加法式字段） |
| 2026-08-14 | **F3-13（D4=B）**：`video_play_utils.dart` 视频 URL/MPD 解析保留 Flutter 层（对齐原版 VideoPlay 复合 URL 语义）；**登记豁免**，不新增 video FFI |
| 2026-08-14 | **F3-4（D3=A）**：沙箱文档口径——书源主路径 `EnginePool` 启用 eval/Function（Rhino 对齐）；`js_eval` 仍用严格 `SandboxConfig::default()` |
| 2026-08-13 | **SOURCE_DIFF P1 DOM WebView**：加法式新增 `webviewRequestStream` / `webviewSubmit` / `webviewCancel` / `webviewPending`（§2.3）：对齐 `BackstageWebView` 挂起-唤醒；Flutter 订阅后 `@webjs`/正文 webJs/`java.webView*` 走真实 DOM。附录合计随 codegen +4 |
| 2026-08-13 | **SOURCE_DIFF 纯工程收口（无新 FFI）**：Android 原生 `backstageEval` 落地页内 `java`/`source`/`cache` JavascriptInterface + `cacheFirst`→`LOAD_CACHE_ELSE_NETWORK`；Rust `ownText`/`string_rule_cache`。契约语义边界更新，方法表不变 |
| 2026-08-18 | **书源搜索 parity（无新 FFI）**：QuickJS 宿主补齐 `org.jsoup.Jsoup` 模拟（`java.jsoupAttr/jsoupText/jsoupHtml`）+ 引擎创建时注入 `java.get/post/head` Response 桥（`connectNR`/`followRedirects(false)`，对齐 JsExtensions）；`@js`/`<js>` searchUrl 求值失败禁止字面回退；`AnalyzeUrl`/`ajax` 纠正书源 `#tag` 后缀把 path/query 拼进 fragment 的假 URL。方法表不变 |
| 2026-08-18 | **G8 `$n` 跨步分组（无新 FFI）**：allInOne 正则 `getElements`（`:` 前缀）在有捕获组时把 `[全文,$1,$2,…]` 编成 JSON 数组元素；`getString("$2")` / `$1##…` 对齐原版 `SourceRule.makeUpRule` 用前序捕获组回填。覆盖书书小说/笔下文学/若夏等目录规则。方法表不变 |
| 2026-08-19 | **搜索 baseUrl=重定向最终 URL（无新 FFI）**：`webbookSearch` 对齐 `WebBook.search` 的 `baseUrl = res.url`；搜索 302 到详情页时按空列表回退解析 `ruleBookInfo`。方法表不变 |
| 2026-08-24 | **webbook* FFI 非阻塞化（无签名变更）**：Rust 侧 `ffi::webbook_search/info/chapters/content` 改为 `async fn` + tokio 阻塞线程池执行（`spawn_blocking`），对齐原版 `WebBook.kt` Dispatchers.IO 语义——网络 + quickjs JS 解析不再阻塞 Dart 主 isolate（此前 wire 函数同步执行，加载目录卡 UI 数秒）；Dart 侧 API 表面不变（仍 `Future<String>`），codegen 双侧重生成 |
| 2026-09-26 | **项 B/B1 WebView cookie 回流 + sourceKey（加法式）**：新增 `webviewSubmitResultWithCookies`（§2.3，WebView 执行结果 + 域 cookie 回流，Rust 侧按 ETLD+1 归一域键 merged upsert 落 `cookies` 表并同步 JS 桥共享客户端内存 CookieStore，先持久化后唤醒）；`WebViewRequest` 事件加法式字段 `source_key`（JS 执行线程当前书源 key，缺省空串）/ `cookie`（B4 起按请求域预填，缺省空串）——`serde(default)` 空串缺省，旧端忽略未知字段不破坏反序列化。Android 原生 `backstageEval` 加法式返回 cookie 回流信封（无 cookie 时纯结果串，旧版语义不变）；注入接口口径由 `isRule` 扩为「`isRule` 或 `sourceKey` 非空」。旧 `webviewSubmit` 冻结不动。§2.3 方法数 32→**33**，附录合计 280→**281**，BookApi 口径 277→**278** |

---

## 1. 契约总则

### 1.1 定位

本文档是 **UI 轨**与 **Rust 轨**的唯一接口契约基准。所有跨轨数据流通均以 `BookApi` 抽象接口（`flutter_legado/lib/src/services/book_api.dart`）为准，本文档为其权威文字说明。

### 1.2 变更规则

| 变更类型 | 规则 |
|----------|------|
| **新增 API** | Rust 轨可自由添加，但须同步：① 更新本文档 ② 补 `MockBookApi` 假实现 ③ `BookApi` 接口新增抽象方法 |
| **修改/删除已有签名** | 破坏性变更，必须双轨评审确认后执行，PR 标注"破坏性变更"及影响范围 |

详细流程参见 [TWO_TRACK_DEV_SPEC.md § 4 契约变更流程](TWO_TRACK_DEV_SPEC.md)。

### 1.3 数据传递约定

- 复杂类型统一以 **JSON String** 跨 FFI 边界传递（项目既有决策）。
- Dart 侧负责 `jsonEncode` / `jsonDecode`，Rust 侧返回序列化后的 JSON 字符串。
- 模型对象（Book、BookSource 等）通过各自 `toJson()` / `fromJson()` 完成序列化。

### 1.4 已知双兼容点（重要警告）

以下方法的 Rust 侧返回为 **Map 包装结构**（非裸 List），Dart 侧已做兼容处理（提取内部字段）：

| 方法 | Rust 返回结构 | 提取字段 | 历史事故 |
|------|---------------|----------|----------|
| `getChapters` | `ChapterListResponse { total, chapters[] }` | `chapters` | Task #29 崩溃修复 |
| `refreshToc` | `ChapterListResponse { total, chapters[] }` | `chapters` | Task #42 崩溃修复 |
| `searchSource` | `SourceSwitchResponse { book_name, author, matches[] }` | `matches` | Task #42 崩溃修复 |

> **铁律**：未来新增返回列表的 FFI 方法，Rust 侧必须返回裸 JSON Array `[...]`，禁止无预警使用 Map 包装。若确需包装，必须在本文档登记并在 Dart 侧同步兼容。

### 1.5 实现类

| 类 | 文件 | 用途 |
|----|------|------|
| `RustApi` | `rust_api.dart` | 真实 FFI 实现（需 Rust DLL） |
| `MockBookApi` | `mock_book_api.dart` | 纯 Dart Mock（`--dart-define=USE_MOCK=true`） |

### 1.6 FFI 非 Result 导出豁免（F3-5，2026-08-14）

以下 9 个 `ffi.rs` 导出**刻意**不包 `Result<_, BridgeError>`，BookApi/Dart 侧保持既有签名；语义为只读查询或哨兵返回值，失败不抛 bridge 异常：

| FFI 函数 | 返回类型 | 豁免理由 |
|----------|----------|----------|
| `version` | `String` | 编译期常量版本号，永真 |
| `backup_list` | `String` | 目录列表 JSON；IO 失败返回 `[]` 空数组字符串 |
| `server_stop` | `String` | 状态消息字符串（对齐 stopServer 吞错语义） |
| `server_status` | `String` | 状态 JSON；未启动时返回 `{running:false}` |
| `archive_is_archive` | `bool` | 纯路径扩展名判定，无 IO |
| `auto_task_normalize_script` | `String` | 纯字符串变换，输入必返字符串 |
| `auto_task_can_refresh_toc` | `bool` | 纯布尔逻辑组合 |
| `auto_task_next_due_at` | `i64` | cron 无法解析时返回 **-1** 哨兵（非异常） |
| `audio_with_play_mode` | `String` | readConfig JSON 变换；非法 JSON 回落 `{}` |

> 其余新增 FFI 仍遵循 `Result<_, BridgeError>` 铁律；本表仅销记历史非 Result 面，**不扩范围**。

### 1.6.1 进程注入型 FFI（void，不经 BookApi，MD3 对齐 2026-09-04）

以下 6 个 `ffi.rs` 导出为 Flutter→Rust 单向进程级注入（返回 void，经 `bridge.*` 直调，不进 `BookApi` 抽象层与方法计数）：

| FFI 函数 | 入参 | 说明 |
|----------|------|------|
| `set_device_id` | device_id（Android ID / iOS IDFV） | 历史既有（本书山正文 X-Device-Id 校验），本次补登记 |
| `set_theme_config` | theme_json（`get_theme_config` 同形 JSON） | Batch 0 R1：启动/切换调色板时注入当前 palette 亮色 role，JS `getThemeConfig()` 优先返回注入值，未注入回退 wh 默认 |
| `set_theme_mode` | mode（"0"=跟随系统/"1"=亮/"2"=暗，对齐 Kotlin themeMode） | Batch 0 R2 + R 批 R3：`setThemeMode` 时注入，JS `getThemeMode()` 映射为 auto/light/dark（"0"→auto；未注入回退 light） |
| `set_read_book_config` | read_json（`get_read_book_config` 同形 JSON） | R 批 R4：阅读配置变更时注入当前阅读配置，JS `getReadBookConfig()` 优先返回注入值，未注入回退硬编码默认 |
| `set_image_cache_dir` | dir（应用缓存目录下 `image_cache` 子目录，P4-2a） | 与 `set_cache_dir` 同型的进程注入（`set_cache_dir` 服务 JS 缓存）：`saveImageCache`/`getImageCache`（§2.46）图片磁盘缓存落应用私有缓存目录；未注入时回落 `<temp_dir>/legado-image-cache`（一次性告警）。Dart 侧 `RustApi.initialize` 经 `path_provider` 注入 |
| `set_audio_cache_dir` | dir（应用缓存目录下 `audio_cache` 子目录，B1） | 与 `set_image_cache_dir` 同型：`audioCacheQuery`/`audioCacheList`/`audioCacheClearChapter`/`audioCacheClearBook`（§2.47）音频章节文件缓存读取与 `audioCacheDownload`/`audioCacheCancel`（§2.48，B2）写入**共用此根目录**（写读同根同键）；未注入时回落 `<temp_dir>/legado-audio-cache`（一次性告警）。Dart 侧 `RustApi.initialize` 经 `path_provider` 注入 |

> 注入键集合约定（R 批 R5 登记）：`set_theme_config` JSON 必需键 `themeName/isNightTheme/primaryColor/accentColor/backgroundColor/bottomBackground/statusBarColor/navigationBarColor`；可选透传键 `paletteId/背景图路径/blur/圆角覆写` 等（Rust 不解释，原样透传 JS）；注入为进程内存级（RwLock），重启需 Flutter 在 `RustApi.init` 重注，注入前 JS 调用拿到 wh 默认。
>
> `themeConfigList` 纯 Flutter 持久化（SharedPreferences），Rust 仅见合成后的单主题 JSON，不做调色板解析。
>
> `deleteConfig` 契约登记但 `ffi.rs` 暂无 `config_delete` 导出，布局开关恢复默认约定为 `setConfig(key,"")` 空串语义。

**§1.6.1 附加登记：预留 FFI（无消费 / 仅测试消费，2026-10-26 审查批7a 转正登记）**

> 用户裁决（2026-10-26）：以下 3 个导出**保留、不接线、不删除**，状态按实际消费面分别登记——`sourceLoginV1` 为「预留（无消费）」，`verificationPending` / `webviewPending` 为「预留（仅测试消费）」；本表为纯登记，不增删导出，不改 §2.x 方法计数与 §1.7 等价表。若未来接 UI 或移除，须走契约变更流程（§1.2），并同批更新本节状态与相关计数。

| FFI 函数 | Rust 实现（完好） | Dart 消费面 | 状态与保留理由 |
|----------|-------------------|-------------|----------------|
| `sourceLoginV1`（`ffi::source_login_v1`） | `legado-ffi/src/api/source_login_v1_api.rs::eval_login_v1` | 仅 `flutter_legado/lib/src/bridge/ffi/ffi.dart:358` 封装；无业务调用、无测试消费 | 预留（无消费）——V1 登录已被 V2 动态协议（`loginUiV2`/`loginActionV2`）、经典登录、WebView 登录三通路覆盖；V1 对书山类 loginUrl JS 源仍有兼容价值，保留成本为零 |
| `verificationPending`（`ffi::verification_pending`） | `legado-ffi/src/api/verification_api.rs::pending_requests_json` | 仅 `ffi.dart:274` 封装 + `test/ffi/ffi_stream_sink_runtime_test.dart` | 预留（仅测试消费）——拉取式快照已被推送式 `verificationRequestStream`（订阅时回放进行中请求）覆盖，UI 无使用需求 |
| `webviewPending`（`ffi::webview_pending`） | `legado-ffi/src/api/webview_api.rs::pending_requests_json` | 仅 `ffi.dart:317` 封装 + `test/ffi/ffi_stream_sink_runtime_test.dart` | 预留（仅测试消费）——推送式 `webviewRequestStream`（订阅时回放进行中请求）已覆盖 UI 需求 |

### 1.7 BookApi / FFI 命名等价表（F3-10，2026-08-14）

以下 **16 对** Dart `BookApi` 方法名与契约 §2.x 登记名不一致（改名等价对）；另有 **174 对**方法名与 Rust FFI 导出名不一致、但 §2.x 按 BookApi 同名登记（机械映射见表 B）。两类合计 **190 对**，语义等价，计数时勿重复：

| BookApi（Dart） | 契约 §2.x / FFI 登记名 |
|-----------------|------------------------|
| `extractJsSource` | `jsSourceExtract`（§2.37） |
| `checkJsSourceSyntax` | `jsSourceSyntaxCheck`（§2.37） |
| `stampJsSourceLastUpdateTime` | `jsSourceStampLastUpdateTime`（§2.37） |
| `isLoginUiV2` | `sourceIsLoginUiV2`（§2.3） |
| `loginUiV2` | `sourceLoginUiV2`（§2.3） |
| `loginActionV2` | `sourceLoginActionV2`（§2.3） |
| `listCachedChapterUrls` | `cacheListCachedChapterUrls`（§2.43.5） |
| `listCachedChapters` | `cacheListCachedChapters`（§2.43.6） |
| `listDownloadingChapters` | `cacheDownloadRunningChapters`（§2.43.7） |
| `listFailedChapters` | `cacheDownloadFailedChapters`（§2.43.8，2026-10-05 实现批补登记） |
| `getCachedChapter` | `cacheGetChapter`（§2.16 / §2.41） |
| `getChaptersWithMeta` | `getChapters`（§2.9，复用 `reader_get_chapters`，批43b P2-1：目录 + `used_custom_rule`） |
| `getLoginHeader` | `sourceGetLoginHeader`（§2.3） |
| `getLoginInfo` | `sourceGetLoginInfo`（§2.3） |
| `putLoginHeader` | `sourcePutLoginHeader`（§2.3） |
| `putLoginInfo` | `sourcePutLoginInfo`（§2.3） |

**表 B：Rust FFI 导出 ↔ BookApi 方法机械映射（2026-10-26 审查批5 补登记 123 对，审查批6 增 1 对 → 124 对；批8 增 10 对（WebDAV 云同步全量 + servers CRUD）→ 134 对；批11 增 1 对（HTTP 日志采集开关 `setHttpLogRecording` ↔ `set_http_log_recording`）→ 135 对；批15b 增 4 对（RSS 列表四方法 `rssSortUrls`/`rssClearSortCache`/`rssRefreshArticles`/`rssLoadMoreArticles`）→ 139 对；批15c 增 1 对（RSS 正文 `rssFetchContent` ↔ `rss_fetch_content`）→ 140 对；批15f 增 1 对（RSS 只读缓存 `rssListCachedArticles` ↔ `rss_list_cached_articles`）→ 141 对；批16a 增 1 对（直链上传 `directLinkUpload` ↔ `direct_link_upload`）→ 142 对；批17a 增 1 对（备份探测 `backupInspect` ↔ `backup_inspect`，契约先行）→ 143 对；批21a 增 1 对（RSS WebView 宿主桥 `rssWebViewHostCall` ↔ `rss_web_view_host_call`）→ 144 对；批24 增 2 对（7z 导入 `archiveImport7z` ↔ `archive_import_7z`、7z 列表 `archiveList7zFiles` ↔ `archive_list_7z_files`）→ 146 对；批32 增 1 对（readConfig 单键写 `updateReadConfigField` ↔ `book_update_read_config_field`）→ 147 对；批34 增 1 对（高亮规则正文匹配 `highlightRuleMatch` ↔ `highlight_rule_match`）→ 148 对；批35 增 2 对（批量删除 `deleteBooks` ↔ `bookshelf_delete_books`、阅读记录开关 `setReadRecordDisabled` ↔ `book_set_read_record_disabled`）→ 150 对；批37b 增 1 对（设置编码 `setBookCharset` ↔ `book_set_charset`）→ 151 对；批40 增 1 对（备份保留清理 `webdavPruneBackups` ↔ `webdav_prune_backups`）→ 152 对；批43 增 1 对（TXT 目录规则 `setBookTocRule` ↔ `book_set_toc_rule`）→ 153 对；批9b-1 增 1 对（过期搜索清理 `clearExpiredSearchBooks` ↔ `search_books_clear_expired`）→ 154 对；批9b-3 增 1 对（漫画图片保留清理 `retainComicImages` ↔ `retain_comic_images`）→ 155 对；批7b-1 增 5 对（书签标记 `getBookMarkingsByBook` ↔ `book_marking_list_by_book`、`getBookMarkingsForChapter` ↔ `book_marking_list_for_chapter`、`saveBookMarking` ↔ `book_marking_save`、`deleteBookMarking` ↔ `book_marking_delete`、`setBookMarkingEnabled` ↔ `book_marking_set_enabled`）→ 160 对；批9a 增 8 对（隐私与私密标记 `privacyHasPassword` ↔ `privacy_has_password`、`privacySetPassword` ↔ `privacy_set_password`、`privacyVerifyPassword` ↔ `privacy_verify_password`、`privacyClearPassword` ↔ `privacy_clear_password`、`setBooksPrivate` ↔ `set_books_private`、`getPrivateBookUrls` ↔ `get_private_book_urls`、`setBookGroupPrivate` ↔ `set_book_group_private`、`getPrivateGroupIds` ↔ `get_private_group_ids`）→ 168 对；批9d 增 4 对（生物识别 `privacyBiometricStateGet` ↔ `privacy_biometric_state_get`、`privacyBiometricSet` ↔ `privacy_biometric_set`、`privacyBiometricVerify` ↔ `privacy_biometric_verify`、`privacyBiometricClear` ↔ `privacy_biometric_clear`）→ 172 对；批12 增 1 对（替换规则排序 `reorderReplaceRules` ↔ `replace_rule_reorder`）→ 173 对；批20 增 1 对（图片动作执行 `evalImageAction` ↔ `eval_image_action`）→ 174 对）**

> 生成口径：以 `rust/legado-ffi/src/ffi.rs` 的 `pub fn` 导出面与本仓 `rust_api*.dart` 实现中的 `bridge.<fn>` 调用点为源，取「BookApi 方法名 ≠ Rust FFI 导出名」且未在表 A 登记的对。一个 FFI 导出可被多个 BookApi 方法复用（如 `bookshelf_update`），复合实现列出全部调用；`initialize`/`getVersion` 无模块前缀但同属命名差异，一并登记。本表为纯登记（不新增方法、不改 §2.x 计数口径）。

| BookApi（Dart） | 契约 §2.x 登记名 | Rust FFI 导出（ffi.rs pub fn） |
|---|---|---|
| `getAudioChapterMedia` | `getAudioChapterMedia`（§2.26） | `audio_get_chapter_media` |
| `getAudioProgress` | `getAudioProgress`（§2.26） | `audio_get_progress` |
| `saveAudioProgress` | `saveAudioProgress`（§2.26） | `audio_save_progress` |
| `autoTaskBuildBookUpdateTask` | `autoTaskBuildBookUpdateTask`（§2.32） | `auto_task_build_book_update` |
| `autoTaskCanRefreshBookToc` | `autoTaskCanRefreshBookToc`（§2.32） | `auto_task_can_refresh_toc` |
| `autoTaskFindBookUpdateTask` | `autoTaskFindBookUpdateTask`（§2.32） | `auto_task_find_book_update` |
| `backup` | `backup`（§2.11） | `backup_create` |
| `restore` | `restore`（§2.11） | `backup_restore` |
| `backupInspect` | `backupInspect`（§2.11） | `backup_inspect` |
| `addBookGroup` | `addBookGroup`（§2.14） | `book_group_add` |
| `deleteBookGroup` | `deleteBookGroup`（§2.14） | `book_group_delete` |
| `getBookGroups` | `getBookGroups`（§2.14） | `book_group_list` |
| `updateBookGroup` | `updateBookGroup`（§2.14） | `book_group_update` |
| `addBookmark` | `addBookmark`（§2.7） | `bookmark_add` |
| `deleteBookmark` | `deleteBookmark`（§2.7） | `bookmark_delete` |
| `getAllBookmarks` | `getAllBookmarks`（§2.7） | `bookmark_list` |
| `getBookmarks` | `getBookmarks`（§2.7） | `bookmark_get_all` |
| `searchBookmarks` | `searchBookmarks`（§2.7） | `bookmark_search` |
| `updateBookmark` | `updateBookmark`（§2.7） | `bookmark_delete` + `bookmark_add` |
| `getBookMarkingsByBook` | `getBookMarkingsByBook`（§2.52） | `book_marking_list_by_book` |
| `getBookMarkingsForChapter` | `getBookMarkingsForChapter`（§2.52） | `book_marking_list_for_chapter` |
| `saveBookMarking` | `saveBookMarking`（§2.52） | `book_marking_save` |
| `deleteBookMarking` | `deleteBookMarking`（§2.52） | `book_marking_delete` |
| `setBookMarkingEnabled` | `setBookMarkingEnabled`（§2.52） | `book_marking_set_enabled` |
| `privacyHasPassword` | `privacyHasPassword`（§2.53） | `privacy_has_password` |
| `privacySetPassword` | `privacySetPassword`（§2.53） | `privacy_set_password` |
| `privacyVerifyPassword` | `privacyVerifyPassword`（§2.53） | `privacy_verify_password` |
| `privacyClearPassword` | `privacyClearPassword`（§2.53） | `privacy_clear_password` |
| `setBooksPrivate` | `setBooksPrivate`（§2.53） | `set_books_private` |
| `getPrivateBookUrls` | `getPrivateBookUrls`（§2.53） | `get_private_book_urls` |
| `setBookGroupPrivate` | `setBookGroupPrivate`（§2.53） | `set_book_group_private` |
| `getPrivateGroupIds` | `getPrivateGroupIds`（§2.53） | `get_private_group_ids` |
| `privacyBiometricStateGet` | `privacyBiometricStateGet`（§2.53） | `privacy_biometric_state_get` |
| `privacyBiometricSet` | `privacyBiometricSet`（§2.53） | `privacy_biometric_set` |
| `privacyBiometricVerify` | `privacyBiometricVerify`（§2.53） | `privacy_biometric_verify` |
| `privacyBiometricClear` | `privacyBiometricClear`（§2.53） | `privacy_biometric_clear` |
| `addBook` | `addBook`（§2.2） | `bookshelf_add` |
| `deleteBook` | `deleteBook`（§2.2） | `bookshelf_delete` |
| `deleteBooks` | `deleteBooks`（§2.2） | `bookshelf_delete_books` |
| `setReadRecordDisabled` | `setReadRecordDisabled`（§2.2） | `book_set_read_record_disabled` |
| `setBookCharset` | `setBookCharset`（§2.2） | `book_set_charset` |
| `setBookTocRule` | `setBookTocRule`（§2.2） | `book_set_toc_rule` |
| `getBook` | `getBook`（§2.2） | `bookshelf_get` |
| `getBooks` | `getBooks`（§2.2） | `bookshelf_list` |
| `importBooks` | `importBooks`（§2.2） | `bookshelf_import` |
| `reorderBooks` | `reorderBooks`（§2.2） | `bookshelf_reorder_orders` |
| `setBookGroup` | `setBookGroup`（§2.2） | `bookshelf_update` |
| `topBook` | `topBook`（§2.2） | `bookshelf_update` |
| `unTopBook` | `unTopBook`（§2.2） | `bookshelf_update` |
| `updateBook` | `updateBook`（§2.2） | `bookshelf_update` |
| `updateReadConfigField` | `updateReadConfigField`（§2.2） | `book_update_read_config_field` |
| `highlightRuleMatch` | `highlightRuleMatch`（§2.36） | `highlight_rule_match` |
| `clearBookCache` | `clearBookCache`（§2.16） | `cache_clear_book` |
| `clearCache` | `clearCache`（§2.16） | `cache_clear` |
| `clearCacheBefore` | `clearCacheBefore`（§2.16） | `cache_clear_before` |
| `clearChapterCache` | `clearChapterCache`（§2.16） | `cache_clear_chapter` |
| `getCacheBookCount` | `getCacheBookCount`（§2.16） | `cache_get_book_count` |
| `getCacheChapterCount` | `getCacheChapterCount`（§2.16） | `cache_get_chapter_count` |
| `getCacheSize` | `getCacheSize`（§2.16） | `cache_get_size` |
| `shrinkDatabase` | `shrinkDatabase`（§2.16） | `cache_shrink_database` |
| `deleteConfig` | `deleteConfig`（§2.10） | `config_set` |
| `getAllConfigs` | `getAllConfigs`（§2.10） | `config_get_all` |
| `getConfig` | `getConfig`（§2.10） | `config_get` |
| `setConfig` | `setConfig`（§2.10） | `config_set` |
| `setHttpLogRecording` | `setHttpLogRecording`（§2.10） | `set_http_log_recording` |
| `setServerPort` | `setServerPort`（§2.22） | `config_set` |
| `sortBookSources` | `sortBookSources`（§2.3） | `config_set` |
| `cancelDebugBookSource` | `cancelDebugBookSource`（§2.17） | `debug_book_source_cancel` |
| `addHttpTts` | `addHttpTts`（§2.25） | `http_tts_add` |
| `deleteHttpTts` | `deleteHttpTts`（§2.25） | `http_tts_delete` |
| `getHttpTts` | `getHttpTts`（§2.25） | `http_tts_list` |
| `importHttpTts` | `importHttpTts`（§2.25） | `http_tts_add` |
| `updateHttpTts` | `updateHttpTts`（§2.25） | `http_tts_update` |
| `detectFormat` | `detectFormat`（§2.6） | `import_detect_format` |
| `parseEpub` | `parseEpub`（§2.23） | `import_local_book` + `reader_get_chapters` |
| `parseMetadata` | `parseMetadata`（§2.6） | `import_parse_metadata` |
| `initialize` | `initialize`（§2.1） | `init` + `db_open` |
| `evalJs` | `evalJs`（§2.21） | `js_eval` |
| `getJsEngineVersion` | `getJsEngineVersion`（§2.21） | `js_eval` |
| `evalImageAction` | `evalImageAction`（§2.21） | `eval_image_action` |
| `clearReadRecords` | `clearReadRecords`（§2.12） | `read_record_clear` |
| `deleteReadRecord` | `deleteReadRecord`（§2.12） | `read_record_delete` |
| `getReadRecords` | `getReadRecords`（§2.12） | `read_record_list` |
| `putReadRecord` | `putReadRecord`（§2.12） | `read_record_upsert` |
| `recordReadingTime` | `recordReadingTime`（§2.12） | `read_record_upsert` |
| `canRemoveSameTitle` | `canRemoveSameTitle`（§2.9） | `reader_can_remove_same_title` |
| `fetchChapterContent` | `fetchChapterContent`（§2.9） | `reader_fetch_content` |
| `getChapterContent` | `getChapterContent`（§2.9） | `reader_get_content` |
| `getChapterContentFull` | `getChapterContentFull`（§2.9） | `reader_get_content_full` |
| `getChapterContentRaw` | `getChapterContentRaw`（§2.9） | `reader_get_content_raw` |
| `getChapters` | `getChapters`（§2.9） | `reader_get_chapters` |
| `getChineseConvertType` | `getChineseConvertType`（§2.9） | `reader_get_chinese_convert` |
| `getSameTitleRemoved` | `getSameTitleRemoved`（§2.9） | `reader_get_same_title_removed` |
| `refreshToc` | `refreshToc`（§2.9） | `reader_refresh_toc` |
| `setChineseConvertType` | `setChineseConvertType`（§2.9） | `reader_set_chinese_convert` |
| `toggleSameTitleRemoved` | `toggleSameTitleRemoved`（§2.9） | `reader_toggle_same_title_removed` |
| `updateReadingProgress` | `updateReadingProgress`（§2.9） | `reader_update_progress` |
| `addReplaceRule` | `addReplaceRule`（§2.8） | `replace_rule_add` |
| `deleteReplaceRule` | `deleteReplaceRule`（§2.8） | `replace_rule_delete` |
| `getEnabledReplaceRules` | `getEnabledReplaceRules`（§2.8） | `replace_rule_enabled` |
| `getReplaceRules` | `getReplaceRules`（§2.8） | `replace_rule_list` |
| `previewReplaceRule` | `previewReplaceRule`（§2.8） | `replace_rule_preview` |
| `setReplaceRuleEnabled` | `setReplaceRuleEnabled`（§2.8） | `replace_rule_set_enabled` |
| `updateReplaceRule` | `updateReplaceRule`（§2.8） | `replace_rule_update` |
| `addRssSource` | `addRssSource`（§2.5） | `rss_add_source` |
| `addRssStar` | `addRssStar`（§2.13） | `rss_star_add` |
| `deleteRssSource` | `deleteRssSource`（§2.5） | `rss_delete_source` |
| `deleteRssStar` | `deleteRssStar`（§2.13） | `rss_star_delete` |
| `getRssArticles` | `getRssArticles`（§2.5） | `rss_fetch_articles` |
| `getRssSources` | `getRssSources`（§2.5） | `rss_list_sources` |
| `getRssStars` | `getRssStars`（§2.13） | `rss_star_list` |
| `isStarred` | `isStarred`（§2.13） | `rss_star_is_starred` |
| `rssSourceSetEnabled` | `rssSourceSetEnabled`（§2.5） | `rss_source_set_enabled` |
| `rssClearSortCache` | `rssClearSortCache`（§2.5） | `rss_clear_sort_cache` |
| `rssFetchContent` | `rssFetchContent`（§2.5） | `rss_fetch_content` |
| `rssListCachedArticles` | `rssListCachedArticles`（§2.5） | `rss_list_cached_articles` |
| `rssLoadMoreArticles` | `rssLoadMoreArticles`（§2.5） | `rss_load_more_articles` |
| `rssRefreshArticles` | `rssRefreshArticles`（§2.5） | `rss_refresh_articles` |
| `rssSortUrls` | `rssSortUrls`（§2.5） | `rss_sort_urls` |
| `updateRssSource` | `updateRssSource`（§2.5） | `rss_update_source` |
| `addSearchKeyword` | `addSearchKeyword`（§2.15） | `search_history_add` |
| `cancelSearch` | `cancelSearch`（§2.4） | `search_cancel` |
| `clearSearchHistory` | `clearSearchHistory`（§2.15） | `search_history_clear` |
| `deleteSearchKeyword` | `deleteSearchKeyword`（§2.15） | `search_history_delete` |
| `getSearchHistory` | `getSearchHistory`（§2.15） | `search_history_list` |
| `clearExpiredSearchBooks` | `clearExpiredSearchBooks`（§2.15） | `search_books_clear_expired` |
| `pauseSearch` | `pauseSearch`（§2.4） | `search_pause` |
| `resumeSearch` | `resumeSearch`（§2.4） | `search_resume` |
| `getServerStatus` | `getServerStatus`（§2.22） | `server_status` |
| `startServer` | `startServer`（§2.22） | `server_start` |
| `stopServer` | `stopServer`（§2.22） | `server_stop` |
| `addBookSource` | `addBookSource`（§2.3） | `source_add` |
| `cancelCheckSources` | `cancelCheckSources`（§2.3） | `source_check_cancel` |
| `cancelSwitchSourceApply` | `cancelSwitchSourceApply`（§2.4） | `source_switch_apply_cancel` |
| `checkSource` | `checkSource`（§2.3） | `source_check` |
| `checkSourcesStream` | `checkSourcesStream`（§2.3） | `source_check_stream` |
| `deleteBookSource` | `deleteBookSource`（§2.3） | `source_delete` |
| `disableBookSource` | `disableBookSource`（§2.3） | `source_disable` |
| `disableRssSource` | `disableRssSource`（§2.5） | `rss_source_set_enabled` |
| `enableBookSource` | `enableBookSource`（§2.3） | `source_enable` |
| `enableRssSource` | `enableRssSource`（§2.5） | `rss_source_set_enabled` |
| `exportBookSources` | `exportBookSources`（§2.3） | `source_export` |
| `getBookSources` | `getBookSources`（§2.3） | `source_list` |
| `getEnabledBookSources` | `getEnabledBookSources`（§2.3） | `source_list_enabled` |
| `importBookSources` | `importBookSources`（§2.3） | `source_import` |
| `searchSource` | `searchSource`（§2.4） | `source_switch_search` |
| `searchSourceStream` | `searchSourceStream`（§2.4） | `source_switch_search_stream` |
| `switchSource` | `switchSource`（§2.4） | `source_switch_apply` |
| `switchSourcePrefetch` | `switchSourcePrefetch`（§2.4） | `source_switch_apply_prefetch` |
| `updateBookSource` | `updateBookSource`（§2.3） | `source_update` |
| `audioSpeak` | `audioSpeak`（§2.26） | `tts_speak` |
| `cancelVerificationRequest` | `cancelVerificationRequest`（§2.3） | `verification_cancel` |
| `submitVerificationResult` | `submitVerificationResult`（§2.3） | `verification_submit` |
| `getVersion` | `getVersion`（§2.1） | `version` |
| `cancelWebviewRequest` | `cancelWebviewRequest`（§2.3） | `webview_cancel` |
| `submitWebviewResult` | `submitWebviewResult`（§2.3） | `webview_submit` |
| `submitWebviewResultWithCookies` | `submitWebviewResultWithCookies`（§2.3） | `webview_submit_result_with_cookies` |
| `webdavListDir` | `webdavListDir`（§2.28） | `webdav_list_dir` |
| `webdavUpload` | `webdavUpload`（§2.28） | `webdav_upload` |
| `webdavUploadFile` | `webdavUploadFile`（§2.28） | `webdav_upload_file` |
| `webdavDownload` | `webdavDownload`（§2.28） | `webdav_download` |
| `webdavDownloadFile` | `webdavDownloadFile`（§2.28） | `webdav_download_file` |
| `webdavDelete` | `webdavDelete`（§2.28） | `webdav_delete` |
| `webdavPruneBackups` | `webdavPruneBackups`（§2.28） | `webdav_prune_backups` |
| `webdavFullSync` | `webdavFullSync`（§2.28） | `webdav_full_sync` |
| `webdavServersList` | `webdavServersList`（§2.28） | `webdav_servers_list` |
| `webdavServerSave` | `webdavServerSave`（§2.28） | `webdav_server_save` |
| `webdavServerDelete` | `webdavServerDelete`（§2.28） | `webdav_server_delete` |
| `directLinkUpload` | `directLinkUpload`（§2.51） | `direct_link_upload` |
| `rssWebViewHostCall` | `rssWebViewHostCall`（§2.5） | `rss_web_view_host_call` |
| `archiveImport7z` | `archiveImport7z`（§2.34） | `archive_import_7z` |
| `archiveList7zFiles` | `archiveList7zFiles`（§2.34） | `archive_list_7z_files` |
| `retainComicImages` | `retainComicImages`（§2.46） | `retain_comic_images` |
| `reorderReplaceRules` | `reorderReplaceRules`（§2.8） | `replace_rule_reorder` |

> 📌 **2026-10-26 审查批6 已闭环（原 ⚠ 缺口登记销记）**：`enableRssSource` / `disableRssSource` 曾分别调 `source_enable` / `source_disable`（`rust/legado-ffi/src/api/source.rs:64-71` 走 `BookSourceRepository`）——RSS-only 源报「书源不存在」，同 URL 恰有书源时误改书源。现两者委托新增的 `rssSourceSetEnabled`（FFI `rss_source_set_enabled` → `legado-db::RssSourceRepository::set_enabled` 单实现），本表两对的 FFI 列已更正；RSS 源开关写路径不再触碰 `book_sources` 表。

---

## 2. 方法清单

> 共 **50 个方法模块**（§2.1–§2.53，编号跳过 2.24/2.27）+ §2.44 数据层实现备注；计数由 `test/unit/api_contract_test.dart` 自动校验。
> BookApi 接口当前共 **338 个方法**（2026-08-15 起以 Dart 测试程序化计数为唯一基准，取代人工统计；2026-10-04 B1 将音频缓存 4 方法封装进 BookApi：284→288；2026-10-03 B2 冻结音频预下载写入面 2 方法，契约先行、待实现批封装进 BookApi：288→290；2026-10-05 P2-29c 后续批冻结失败章查询 1 方法，契约先行、待实现批封装进 BookApi：290→291；2026-10-05 V-B1 冻结视频弹幕查询 1 方法，契约先行、待实现批封装进 BookApi：291→292；2026-10-05 V-B2 冻结弹幕解析 1 方法，契约先行、待实现批封装进 BookApi：292→293；2026-10-26 审查批6 新增 RSS 源开关 1 方法 `rssSourceSetEnabled`（修复误接书源 FFI，同批封装进 BookApi）：293→294；2026-10-26 批8 servers 表新增 WebDAV 服务器 CRUD 3 方法 `webdavServersList`/`webdavServerSave`/`webdavServerDelete`（契约先行冻结，同批封装进 BookApi）：294→297；2026-10-26 批11 新增 HTTP 日志采集开关 1 方法 `setHttpLogRecording`（legado-net 采集点接线，同批封装进 BookApi）：297→298；2026-10-26 批15b 新增 RSS 分类/分页 4 方法 `rssSortUrls`/`rssClearSortCache`/`rssRefreshArticles`/`rssLoadMoreArticles`（契约先行冻结，同批封装进 BookApi）：298→302；2026-10-26 批15c 新增 RSS 正文 1 方法 `rssFetchContent`（契约先行冻结，同批封装进 BookApi）：302→303；2026-10-26 批15f 新增 RSS 只读缓存 1 方法 `rssListCachedArticles`（契约先行冻结，同批封装进 BookApi）：303→304；2026-10-27 批16a 新增直链上传 1 方法 `directLinkUpload`（契约先行冻结，同批封装进 BookApi）：304→305；2026-10-26 批17b 将批17a 契约先行的备份探测 `backupInspect` 封装进 BookApi：305→306；2026-10-27 批21a 新增 RSS WebView `preloadJs` 宿主桥 1 方法 `rssWebViewHostCall`（同批封装进 BookApi）：306→307；2026-10-27 批24 新增 7z 导入/列表 2 方法 `archiveImport7z`/`archiveList7zFiles`（同批封装进 BookApi）：307→309；2026-10-29 批32 新增 readConfig 单键写 1 方法 `updateReadConfigField`（契约先行，同批封装进 BookApi）：309→310；2026-10-29 批34 新增高亮规则正文匹配 1 方法 `highlightRuleMatch`（契约先行 + 同批封装进 BookApi）：310→311；2026-10-29 批35 新增批量删除 `deleteBooks` / 书籍级阅读记录开关 `setReadRecordDisabled` 2 方法（契约先行 + 同批封装进 BookApi）：311→313；2026-10-29 批37b 新增设置编码 1 方法 `setBookCharset`（契约先行 + 同批封装进 BookApi）：313→314；2026-10-29 批40 新增备份保留清理 1 方法 `webdavPruneBackups`（契约先行 + 同批封装进 BookApi）：314→315；2026-10-30 批43 新增 TXT 目录规则 1 方法 `setBookTocRule`（契约先行 + 同批封装进 BookApi）：315→316；2026-10-30 批43b 新增 `getChaptersWithMeta`（BookApi-only 别名，复用 §2.9 `getChapters` 的 `reader_get_chapters`，透出 `used_custom_rule`；§1.7 登记，不新增 FFI/§2.x 行）：316→317；2026-10-31 批9b-1 新增过期搜索清理 1 方法 `clearExpiredSearchBooks`（契约先行 + 同批封装进 BookApi）：317→318；2026-11-03 批9b-3 新增漫画图片保留清理 1 方法 `retainComicImages`（契约先行 + 同批封装进 BookApi）：318→319；2026-11-09 批7b-1 新增书签标记 5 方法 `getBookMarkingsByBook`/`getBookMarkingsForChapter`/`saveBookMarking`/`deleteBookMarking`/`setBookMarkingEnabled`（契约先行 + 同批封装进 BookApi）：319→324；2026-11-09 批9a 新增隐私与私密标记 8 方法 `privacyHasPassword`/`privacySetPassword`/`privacyVerifyPassword`/`privacyClearPassword`/`setBooksPrivate`/`getPrivateBookUrls`/`setBookGroupPrivate`/`getPrivateGroupIds`（契约先行 + 同批封装进 BookApi）：324→332；2026-11-10 批9d 新增生物识别快捷解锁 4 方法 `privacyBiometricStateGet`/`privacyBiometricSet`/`privacyBiometricVerify`/`privacyBiometricClear`（契约先行 + 同批封装进 BookApi）：332→336；2026-11-10 批12 新增替换规则全量排序 1 方法 `reorderReplaceRules`（契约先行 + 同批封装进 BookApi）：336→337；2026-11-12 批20 新增正文图片动作执行 1 方法 `evalImageAction`（契约先行 + 同批封装进 BookApi）：337→338）。
> 附录 §2.x 行合计 **340** = §2.x 实际方法行总数；其中 1 个为尚未封装进 BookApi 的纯 FFI（`chapterPayAction`；`rssUpdateSource` 已由 BookApi `updateRssSource` 封装接通，见附录口径）。

### 2.1 初始化/版本（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `initialize()` | 无 | `Future<void>` | 初始化 Rust 运行时和数据库连接 |
| `getVersion()` | 无 | `Future<String>` | 获取引擎版本号 |

### 2.2 书架操作（15 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBooks()` | 无 | `Future<List<Book>>` | 获取书架上所有书籍 |
| `addBook(Book book)` | book: Book 对象 | `Future<Book>` | 添加书籍到书架 |
| `updateBook(Book book)` | book: Book 对象 | `Future<void>` | 更新书籍信息。Book JSON 的 `readConfig` 承载加法式书级字段：可选 `mangaScrollMode`（书级翻页模式）与 `webtoonSidePaddingDp`（书级条漫侧边留白）——缺失/null = 未覆盖、跟随全局；后者键名沿用参考版（legado-with-MD3）但**单位不是 dp**，值为 Flutter 现行百分比口径 0..45（每侧留白 = 视口宽 × p/100，不做 dp/百分比换算）。Rust `ReadConfig` 类型化接收后全行回写不丢该两字段（旧 JSON 缺键 → None，空值序列化省略）；进度列按既有「不回滚」语义仍由 `update_progress` 单列写入 |
| `deleteBook(String bookUrl)` | bookUrl | `Future<void>` | 从书架删除书籍 |
| `deleteBooks(List<String> bookUrls, {bool deleteOriginal = false})` | bookUrls: 待删 URL；deleteOriginal: 是否同时删除本地原文件 | `Future<DeleteBooksResult>` | **批35** 批量删除书架书籍（对齐参考版 `DeleteBooksUseCase`）：删除前查库计数，短连接查库 → 无连接文件 IO → 单事务 `delete_by_url`（章节级联删除）；`deleteOriginal=true` 时仅对本地/WebDAV 存储书删除 `bookUrl` 指向的磁盘文件（`resolve_local_book_path` 解析 iOS 相对标识；信任边界见下注），文件删除失败**不阻断记录删除**，逐条返回中文失败提示。**批35b** 返回值改为 `DeleteBooksResult{deleted, missing, warnings}`（UI 用实际删除数；Rust `BookshelfDeleteResult`） |
| `setReadRecordDisabled(String bookUrl, bool disabled)` | bookUrl: 书籍 URL；disabled: 是否独立关闭本书阅读记录 | `Future<Book>` | **批35** 书籍级阅读记录开关（对齐参考版 `BookInfoViewModel.toggleReadRecordDisabled`）：单列 UPDATE `books.disableReadRecord`，**不整书回写**（陈旧快照不得覆盖进度/其他列）；返回更新后的整书 JSON；书籍不存在报错（不静默成功） |
| `setBookCharset(String bookUrl, String charset)` | bookUrl: 书籍 URL；charset: 编码名（`encoding_rs` 标签体系，如 `UTF-8`/`GBK`/`GB2312`/`UTF-16LE`） | `Future<Book>` | **批37b** 设置本地书编码（对齐参考版 `ReadBook.setCharset`）：**单列 UPDATE** `books.charset`，不整书回写（`readConfig` 未建模键/进度列原样保留）；编码名归一化（`GB2312`→`GBK`），空白/不支持编码抛错；本地 TXT 同事务清空章节表并重置目录派生字段，下一次 `getChapters` 按新编码重解析（目录偏移是解码后文本字节偏移，跨编码不可复用）；非 TXT 本地书只写编码列 |
| `setBookTocRule(String bookUrl, String? ruleJson)` | bookUrl: 书籍 URL；ruleJson: `TxtTocRule` JSON（`{"rule":"...","replacement":"..."}`）或直接正则串；`null`/空白 = 恢复默认规则 | `Future<Book>` | **批43** 本地 TXT 目录规则作用于当前书（对齐原版 `TocActivity.onTocRegexDialogResult` / 参考版 `MenuTocRegex`）：**单列 UPDATE** `books.tocUrl`（原版格式 `rule + spaceChars(🫅🈳🏻) + replacement`，Android 备份/跨端库直接兼容），同事务清空 `chapters` 表该书行并重置目录派生字段，下一次 `getChapters` 按新规则重解析；正则经 `compile_fancy_regex_safe`（支持原版 lookbehind）试编译，非法/超长/嵌套过深抛错；非本地 TXT 抛错（UI 隐藏入口）。**批43b**：返回 Book 的 `totalChapterNum/latestChapterTitle` 已失效（0/NULL），调用方重载目录后须 `getBook` 刷新；整书写回侧已保护本地 TXT `tocUrl` 与目录派生字段，不会被陈旧快照打回 |
| `getBook(String bookUrl)` | bookUrl | `Future<Book?>` | 按 bookUrl 获取书籍详情 |
| `topBook(String bookUrl)` | bookUrl | `Future<void>` | 置顶书籍 |
| `unTopBook(String bookUrl)` | bookUrl | `Future<void>` | 取消置顶 |
| `setBookGroup(String bookUrl, int groupId)` | bookUrl, groupId | `Future<void>` | 设置书籍分组 |
| `importBooks(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 批量导入书籍，返回成功导入的数量 |
| `reorderBooks(List<Map<String, dynamic>> orders)` | orders: `[{bookUrl, order}, ...]` | `Future<void>` | 批量持久化拖拽排序（对齐原版 BookAdapter.swap 后 updateBook） |
| `updateReadConfigField(String bookUrl, String key, String valueJson)` | bookUrl；key: readConfig 键名；valueJson: 值本身的 JSON 编码串 | `Future<void>` | **批32** 单键更新 `Book.readConfig` 指定键（Rust `ffi::book_update_read_config_field` → `BookRepository::update_read_config_field`）：`valueJson` 支持 bool/string/number/对象/数组（JSON 解析失败抛错）；DB 侧只合并目标键，**不重写整书快照**，Dart `ReadConfig` 未建模键（`useGlobalAudioSkip`/`tocExpanded`/`manualReplaceRuleIds` 等）与其他键原样保留；`readConfig` 为空/非法 JSON 时新建对象后写入；`key` 为空白抛错；书籍不存在抛错（不静默成功）；不触碰其他列与进度列。**批32b**：合并结果写回前按 `ReadConfig` 反序列化校验，类型不符（如 `reverseToc` 写字符串 `"true"`、`playMode` 写字符串）**拒绝写入**并报「值类型不符」，DB 原键集不变；未建模键仍可写入任意 JSON 类型 |

> ℹ️ **§2.2 批32b：`updateBook` 整书写回边界与 readConfig 类型校验（2026-10-29）**
>
> **单键写覆盖面**：目录页 4 个 readConfig 勾选项（`reverseToc` / `reverseTocDisplay` / `splitLongChapter` / `useReplaceRule`）与阅读器菜单 `reverseTocDisplay` 均走 `updateReadConfigField`（批32b P2-2 补齐后两处）。
>
> **`updateBook` 其余用途仍为整书快照写（P3-7 登记，既有行为）**：详情页/阅读器设置保存、换源事务、备份恢复、本地书导入等路径继续经 `updateBook` 全行回写；Dart `ReadConfig` 未建模的键在这些路径往返中仍会丢失（`useGlobalAudioSkip` 被 Rust 默认值覆盖、`tocExpanded`/`manualReplaceRuleIds` 直接丢弃）。本批不改变这些路径；新增 readConfig 写路径应优先复用单键写，或在 Rust 侧做 DB 合并。
>
> **类型校验根因**：`row_to_book` 对 `readConfig` 用 `serde_json::from_str(...).ok()` 静默退化——一份类型不符的 readConfig 会让整份解析失败 → `read_config = None` → 后续任意整书 `updateBook` 把 NULL 落库，配置永久丢失。故单键写在写入前做反序列化校验（fail-closed）。

> ℹ️ **§2.2 批35：批量删除原文件 / 书籍级阅读记录开关（2026-10-29）**
>
> **`deleteBooks` 原文件删除路径安全（fail-safe，批35b 信任边界收敛）**：仅当书为本地/WebDAV 存储（`origin == loc_book` 或 `webDav::`/存量 `dav:`，或 `bookType` 带 local 位；Dart `BookType.isLocalStorageBook` 与此同构）才尝试删除；`bookUrl` 必须为无 `://` 的磁盘路径，并满足：
> - **相对可迁移标识**：拒绝任何 `..` 组件（`books/../outside.txt` 借路径归一逃出 Documents，canonical 后的根检查拦不住）；
> - **信任根**：`canonicalize` 后必须仍在应用 Documents（DB 文件父目录，`db_state::documents_root`）或 Cache/tmp（`std::env::temp_dir()`，Dart `Directory.systemTemp` 同源，WebDAV 远程书临时落盘处）根内；根外绝对路径（含用户导入被构造的书名指向任意目录）一律拒绝；
> - **符号链接**：删除前 `symlink_metadata` 判定为链接即拒绝（canonical 会跟随链接删目标）；
> - **普通文件**：目录/FIFO/设备文件拒绝；扩展名必须在电子书/本地媒体白名单（txt/epub/mobi/azw/azw3/pdf/umd/cbz/zip/mp3/m4a/aac/flac/wav/ogg/mp4/mkv/webm/avi/mov/3gp）。
>
> 任一校验失败或 `remove_file` 失败均记录中文提示并继续删除记录（对齐参考版「runCatching 删除失败不阻断」+ 本批「失败提示」要求）。**不做**封面缓存/章节缓存/下载任务清理（参考版 `BookHelp.clearCache` 对应能力另批）。
>
> **`setReadRecordDisabled` 单列写**：参考版 `BookRepository.setReadRecordDisabled` 用事务内单条 `UPDATE books SET disableReadRecord=:disabled WHERE bookUrl=:url` 后回读整书，避免阅读器并发保存进度被陈旧快照覆盖。本轨同构（`BookRepository::set_read_record_disabled` 单条 UPDATE + `find_by_url` 回读）；`Book` 模型新增 `disableReadRecord`（bool，缺键默认 `false`），DB `SCHEMA_VERSION` 116→117（`INTEGER NOT NULL DEFAULT 0`）；`bookshelf.json`/自有备份/原版 zip 恢复经模型全字段序列化自动透传。
>
> **批35b：`updateBook`/`addBook` 的 `disableReadRecord` 缺键合并**：整书全行 UPDATE 会写入该列，而 `Book` 的 serde 默认值是 `false`——载荷缺键时旧实现把库内 `true` 打回假。现规则：载荷**缺键或 `null`** → 保留库内既有值（新建行仍为 `false`）；**显式携带 `true`/`false`** → 以入参为准（用户主动切换/备份恢复完整快照）。Web `PUT /api/books/:id` 同语义（`disable_read_record` 可选，兼容 `disableReadRecord` 别名）。后续新增「用户可见开关」若进入整书快照，应加入同一合并名单（`merge_missing_user_switches`）。
>
> **批35b：`DeleteBooksResult` 与 UI 提示**：Rust 删除前 `find_by_url` 计数——`deleted` = 删除前在库的记录数（实际删除），`missing` = 请求但已不在库的 URL 数，`warnings` = 文件删除失败中文提示。UI「已删除 N 本」必须用 `deleted`（不再用选中数）；`missing > 0` 时追加「（M 本已不在书架）」。记录删除在单事务内执行，失败整体回滚（不出现删一半）。

> ℹ️ **§2.2 批37b：`setBookCharset` 与本地 TXT 解码（2026-10-29）**
>
> **根因**：阅读器「设置编码」旧实现只写 `Book.charset` 并提示成功，但 Rust 本地正文读取链路从未消费该值（`TxtParser` 始终自动检测），且写入走 `updateBook` 整书快照回写，会清空 Dart `ReadConfig` 未建模键。用户在乱码 TXT 上设置 GBK 后正文仍乱码，属于**假成功**。
>
> **解码覆盖**：`legado-book` 新增 `LocalBook::get_chapters_with_charset` / `get_chapter_content_with_charset`（TXT 分支把 `charset` 传入 `TxtParser`，优先级 = 显式 charset > BOM/UTF-8 检测 > 常见中文编码探测 > UTF-8 默认；显式标签经 `Encoding::for_label` 解析，失败报「不支持的编码」，不静默回退）。非 TXT 格式忽略 charset（EPUB/PDF 等自带编码声明）。BOM 仅在匹配所选编码时跳过（显式 GBK 时开头的 `EF BB BF` 是正文而非 BOM）。
>
> **消费面**：`reader.rs::get_chapters`（懒解析目录）、`get_chapter_content`/`get_chapter_content_raw`（内部同一实现）、`get_chapter_content_full`（阅读器主链路）、本地书导出（`book_export.rs`）、离线缓存下载（`cache_download_api.rs`）均读取 `books.charset`；`local_book_charset` 在书籍行缺失时返回 `None`（保持自动检测，不把临时书读正文变硬失败）。
>
> **目录偏移一致性**：TXT 章节 `start/end` 是**解码后文本**的字节偏移，换编码后旧目录不可复用——`set_book_charset` 对本地 TXT 在同一事务内清空 `chapters` 并 `totalChapterNum/latestChapterTitle` 归零，由下一次 `getChapters` 按新编码重解析（对齐参考版 `ReadBook.setCharset` → `clearTextChapter` + `loadChapterList`）。Dart 侧 `ReaderNotifier.reloadAfterCharsetChange` 重新拉目录并重载当前章；目录/正文任一失败都提示失败，不提示成功。
>
> **Mock 偏差**：`MockBookApi.setBookCharset` 只更新内存 Book 字段，不做编码名校验/归一化、不清目录（Rust 侧负责）。

> ℹ️ **§2.2 批43：`setBookTocRule` 与 TXT 目录规则真正作用于当前书（2026-10-30）**
>
> **原版依据**：`TextFile.getChapterList()` 读取 `book.tocUrl`，按 `TextFile.spaceChars = "🫅🈳🏻"` 拆成 `[rule, replacement]` 后以 `Pattern.MULTILINE` 匹配整段文本；`TxtTocRuleDialog` 选中规则时写入 `tocRule.rule + spaceChars + tocRule.replacement`，`TocActivity.onTocRegexDialogResult` / `ReadBookActivity.onTocRegexDialogResult` 随后持久化并重载目录。本批沿用同一存储格式，不新增 DB 列/Schema 迁移（`books.tocUrl` 自 v1 起存在，备份 `bookshelf.json` 已自然携带）。
>
> **解析语义**：`legado-book::txt::get_chapters_with_rule` 用 `fancy-regex`（原版默认规则大量使用 lookbehind，Rust `regex` 不支持）按 `(?m)` 整段匹配，命中位置映射回所属行（章节起点 = 行首、标题 = 命中片段 trim）；规则不可编译/未命中任何标题 → **回退内置默认规则**，`TocParseOutcome.used_custom_rule=false` 由 `reader.rs::get_chapters` 记 `warn`；`replacement`（原版 JS 片段）仅随 `tocUrl` 透传，Rust 解析不执行（标题保留命中原文，日志登记）。仅本地 TXT 消费 `tocUrl`；在线书/其它本地格式忽略。
>
> **UI**：阅读器顶栏 `toc_rule` 恢复参考版默认启用并显示「TXT 目录规则」（仅本地 TXT 可见），目录页溢出菜单同源；弹层列出规则库启用项 +「默认规则」+「管理规则」，当前书规则按 `tocUrl` 逐字匹配勾选；应用后阅读页 `reloadAfterTocRuleChange`、目录页 `_loadChapters` 并同步阅读器状态。规则库之外的自定义 `tocUrl` 显示「当前书使用规则库之外的规则」且不预选（需重新选择）。
>
> **批43b 回修（2026-10-30，无新增 FFI；BookApi +1 纯别名）**：
> - **`setBookTocRule` 返回 Book 的派生字段已失效**：返回时 `totalChapterNum/latestChapterTitle` 已被重置为 0/NULL（同事务清空章节）。调用方**必须**在重载目录后以 `getBook` 刷新快照（阅读器 `reloadAfterTocRuleChange` 已内置），**不得**把该 Book（或更旧的快照）直接整书写回作为派生字段真源。
> - **整书快照受保护列合并扩展**：`updateBook`/`addBook` 对已存在行按库内值合并——① 本地 TXT 的 `tocUrl` **一律取库内值（含空串）**，只由 `setBookTocRule` 与备份/导入写入（修复「恢复默认」被陈旧快照复活）；② `totalChapterNum/latestChapterTitle/latestChapterTime` 一律取库内值（目录真源 = `chapters` 表 / `refresh_toc`，修复 `setBookTocRule → get_chapters 回填 N → 旧 Book 整书写回打回 0`）。
> - **缓存命中自愈**：`getChapters` 目录缓存命中时以 `chapters` 表为准回填上述派生字段（修复历史坏值 0/NULL 不再永久停留）。
> - **并发解析窗口**：本地书懒解析在落库前用 `BEGIN IMMEDIATE` 事务复查 `books.charset` / `books.tocUrl` 与解析前快照一致；不一致则丢弃本次结果并按新设置重解析（最多 2 次，仍冲突报「目录解析期间书籍编码或目录规则被并发修改」），避免 `setBookTocRule`/`setBookCharset` 后旧解析结果覆盖新空目录。
>
> **Mock 偏差**：`MockBookApi.setBookTocRule` 只更新内存 `tocUrl` 并清空章节缓存，不做正则试编译与非 TXT 拒绝（Rust 侧负责）。

### 2.3 书源操作（33 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookSources()` | 无 | `Future<List<BookSource>>` | 获取所有书源 |
| `getEnabledBookSources()` | 无 | `Future<List<BookSource>>` | 获取所有启用的书源 |
| `addBookSource(BookSource source)` | source: BookSource 对象 | `Future<BookSource>` | 添加书源 |
| `updateBookSource(BookSource source)` | source: BookSource 对象 | `Future<void>` | 更新书源 |
| `deleteBookSource(String sourceUrl)` | sourceUrl | `Future<void>` | 删除书源 |
| `enableBookSource(String sourceUrl)` | sourceUrl | `Future<void>` | 启用书源 |
| `disableBookSource(String sourceUrl)` | sourceUrl | `Future<void>` | 禁用书源 |
| `importBookSources(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 批量导入书源，返回成功数量 |
| `exportBookSources()` | 无 | `Future<String>` | 导出所有书源为 JSON 数组 |
| `sortBookSources(int sortKey, bool ascending)` | sortKey, ascending | `Future<void>` | 书源排序 |
| `sourceIsLoginUiV2(String sourceJson)` | sourceJson: BookSource JSON | `Future<bool>` | 判定登录 UI 是否为 V2 动态状态协议（#402/#488，加法式新增） |
| `sourceLoginUiV2(String sourceJson, String stateJson)` | sourceJson, stateJson（首次传 `"{}"`） | `Future<String>` | 执行 loginUi v2 脚本，返回动态 UI 描述 JSON `{"rows":[RowUi...]}`（#402，加法式新增） |
| `sourceLoginActionV2(String sourceJson, String userInputJson)` | sourceJson, userInputJson | `Future<String>` | 执行 loginAction v2 动作，返回命令 JSON（state/error/login/close）（#402，加法式新增） |
| `sourcePutLoginInfo(String sourceUrl, String infoJson)` | sourceUrl, infoJson: 用户信息 JSON | `Future<void>` | 保存书源登录用户信息（对齐原版 `BaseSource.putLoginInfo` → `userInfo_<key>`；V2 login 命令自动落库 + 手动登录共用）。加法式新增（2026-08-14 发现页修复 R1） |
| `sourcePutLoginHeader(String sourceUrl, String headerJson)` | sourceUrl, headerJson: header map JSON（如 `{"Cookie":"..."}`） | `Future<void>` | 保存书源登录头（对齐原版 `BaseSource.putLoginHeader` → `loginHeader_<key>`；请求路径自动合并）。加法式新增（2026-08-14 发现页修复 R1） |
| `sourceGetLoginInfo(String sourceUrl)` | sourceUrl | `Future<String>` | 读取书源登录用户信息（`userInfo_<key>`），无则空串。加法式新增（2026-08-14 发现页修复 R1） |
| `sourceGetLoginHeader(String sourceUrl)` | sourceUrl | `Future<String>` | 读取书源登录头（`loginHeader_<key>`），无则空串。加法式新增（2026-08-14 发现页修复 R1） |
| `checkSource(String sourceJson, {String? configJson})` | sourceJson: BookSource JSON；configJson(可选): 校验配置 JSON | `Future<Map<String, dynamic>>` | 校验单个书源（搜索→详情→目录→正文四步 + 验证码/重定向检测），返回 CheckResult JSON（Task #87，加法式新增） |
| `checkSourcesStream(List<String> sourceUrls, {String? configJson})` | sourceUrls: 待校验书源 URL 列表（空列表=全部书源）；configJson(可选) | `Stream<Map<String, dynamic>>` | 批量校验书源（串行逐个回推进度，对齐 Kotlin CheckSourceService），每条为 CheckProgress JSON（Task #87，加法式新增） |
| `cancelCheckSources()` | 无 | `Future<void>` | 取消正在进行的批量书源校验（Task #87，加法式新增） |
| `verificationRequestStream()` | 无 | `Stream<Map<String, dynamic>>` | 验证码请求事件流（长期存活，订阅时先回放进行中请求），事件字段：`key` / `source_url` / `source_name` / `image_url` / `title` / `use_browser`（恒 false，已降级）/ `created_at_ms`（Task #90，加法式新增） |
| `submitVerificationResult(String key, String code)` | key: resultKey；code: 用户输入的验证码 | `Future<bool>` | 提交验证码结果唤醒 JS 等待方（对齐 Kotlin `setResult`：空值也唤醒，空值判定在等待侧），返回是否命中进行中请求（Task #90，加法式新增） |
| `cancelVerificationRequest(String key)` | key: resultKey | `Future<bool>` | 取消验证码请求（对齐 Kotlin `checkResult`：以空结果唤醒等待方），返回是否命中（Task #90，加法式新增） |
| `webviewRequestStream()` | 无 | `Stream<Map<String, dynamic>>` | BackstageWebView DOM 执行请求流（长期存活，订阅时回放进行中请求）。事件字段：`key` / `action` / `html` / `url` / `js` / `source_regex` / `override_url_regex` / `cache_first` / `delay_time` / `is_rule` / `result` / `created_at_ms` / `source_key` / `cookie`（SOURCE_DIFF P1 加法式新增；`source_key` / `cookie` 为项 B 加法式字段（B1 sourceKey 补全 / B4 请求域预填），`serde(default)` 空串缺省，旧端忽略未知字段） |
| `submitWebviewResult(String key, String result)` | key: resultKey；result: WebView 执行结果（可空） | `Future<bool>` | 提交 DOM 执行结果唤醒 Rust 等待方，返回是否命中（SOURCE_DIFF P1，加法式新增；项 B/B1 起 cookie 回流场景改调 `submitWebviewResultWithCookies`，本方法冻结不动） |
| `submitWebviewResultWithCookies(String key, String result, String cookiesJson)` | key: resultKey；result: WebView 执行结果；cookiesJson: cookie 回流 JSON 对象（`{"<url 或域键>": "k1=v1; k2=v2"}`，空串 / `{}` = 无回流） | `Future<bool>` | 提交 DOM 执行结果并回流域 cookie（项 B/B1，加法式新增）：Rust 侧对每个域键按 ETLD+1 归一（`cookie_store::normalized_cookie_key`）merged upsert 落 `cookies` 表，并同步 JS 桥共享客户端内存 CookieStore（quickjs 构建重置共享池；复用 http_state 落库/锁序口径），**先持久化后唤醒**等待方；不相关域键不落行（P2-19 口径）。双轨均归我方、加法式，旧端忽略未知字段；Android 原生 `backstageEval` 加法式返回 `{"result","cookies"}` 信封（无 cookie 时纯结果串，旧版语义不变），非 Android 回退路径经 `document.cookie` 尽力读取（仅非 HttpOnly，仅 webView 主路径） |
| `cancelWebviewRequest(String key)` | key: resultKey | `Future<bool>` | 取消 WebView 请求（空结果唤醒），返回是否命中（SOURCE_DIFF P1，加法式新增） |
| `setSourceVariable(String sourceUrl, String variable)` | sourceUrl: 书源 URL；variable: 自定义变量内容（空串=清除） | `Future<void>` | 设置书源自定义变量（对齐原版 `source.setVariable`），单列 UPDATE 语义仅更新 `variable` 单列，规避 `updateBookSource` 全行更新风险；variable 为空串表示清除该变量。错误码：Internal（书源不存在）/ Db（写入失败）。**DB schema 变更预告**：`book_sources` 表补 `variable` 列（幂等迁移，SCHEMA_VERSION 102→103）（台账 §5.11-3，第三批后置项，Task #63，加法式新增） |
| `clearCookie(String url)` | url: 书源/订阅源 URL（或任意含域名的地址） | `Future<void>` | 清除该 URL 所属二级域名的 Cookie（对齐原版 `CookieStore.removeCookie` / 编辑页 `menu_clear_cookie`）。清除范围：① cookies 表持久层；② 共享 HTTP 客户端内存 CookieStore；③ JS 宿主 `java.clearCookies`（内存表 + 其**落库行**——2026-09-23 起 JS 写入的 cookie 亦落 `cookies` 表，按 ETLD+1 域键持久化并在进程启动时回填；该域的持久行随本入口一并清除）。差距说明：原版另清 WebView Cookie / 会话 CacheManager，本实现无独立 WebView Cookie 层（与 MCP `clear_cookies` 一致）。url 为空 → Internal。加法式新增（2026-08-12 P1-2） |
| `looksLikeCurl(String text)` | text: 待判定文本 | `Future<bool>` | 判断是否形似 cURL 命令（对齐 `CurlAnalyzeUrlConverter.looksLikeCurl`）。加法式新增（2026-08-12 P1-14） |
| `curlToAnalyzeUrl(String text)` | text: cURL 命令 | `Future<String>` | cURL → AnalyzeUrl 模板（`url` 或 `url,{options}`）。错误消息含 `[CURL_*]` 前缀。加法式新增（2026-08-12 P1-14） |
| `analyzeUrlToCurl(String text)` | text: AnalyzeUrl 模板 | `Future<String>` | AnalyzeUrl → cURL 命令。错误消息含 `[CURL_*]` 前缀。加法式新增（2026-08-12 P1-14） |
| `sourceCallBackBtn({required String event, required String bookUrl, int? chapterIndex, String? result, int bookType = 0})` | event, bookUrl, chapterIndex(可选), result(可选), bookType | `Future<Map<String, dynamic>>` | 书源 callBackBtn JS（对齐 SourceCallBack）；返回 `invoked` / `jsTrue` / `raw` / `actions`（F3-10 补登记） |

> ℹ️ **书源列表项 `bookshelfCount`（2026-10-28 批31，模型契约加法式，零方法/签名变化）**：`getBookSources` 返回的每个书源对象新增 `bookshelfCount`（int，缺键默认 `0`），由 Rust `ffi::source_list` 经 `legado-ffi/src/api/source.rs::list_sources_with_bookshelf_counts` 包装输出——按 `books.origin = book_sources.bookSourceUrl` 聚合书架书籍数，SQL 口径 `WHERE (type & 1024) = 0 AND (type & 256) = 0 AND (type & 4096) = 0 GROUP BY origin`（排除 `notShelf` 临时书、Kotlin local 位 256 与 Rust local 位 4096，对齐原版 `BookDao.flowBookshelfSourceOrigins` 的 `type & notShelf = 0 AND type & local = 0`）。**作用域限定**：仅 `getBookSources` 携带；`getEnabledBookSources`（`source_list_enabled`）与 `exportBookSources`/备份（`source_export`）保持原形状。**Dart 序列化**：`BookSource.bookshelfCount` 标注 `@JsonKey(name: 'bookshelfCount', includeToJson: false)`，`toJson()` 不输出该字段，源保存「原 JSON 补丁」与用户导出 JSON 均不受污染。**消费方**：书源管理页「显示书籍数量」开关（偏好 `showSourceBookshelfCount`，默认关）开启时列表行显示「书架：N 本」（对齐原版 `values/source_bookshelf_count.xml`）。**批31b 补记**：源保存「原 JSON 补丁」生成时剔除该派生键（`source_json_patch.dart`），即使原始 JSON 缓存来自 `getBookSources` 也不得将 `bookshelfCount` 带入 `sourceUpdate` 载荷；计数非实时（仅 `loadSources` 刷新）。**已知边界（批31b 登记）**：Flutter `BookApi.updateBook` 为整书写回，Dart `ReadConfig` 未建模的键（如 `tocExpanded` / `manualReplaceRuleIds`，服务端投影补默认值）在往返中会丢失（既有行为，非本批引入）；目录页配置回写沿用该路径，后续评估新增单键 FFI `bookUpdateReadConfigField`（**批32 已落地**：契约名 `updateReadConfigField` + Rust `book_update_read_config_field`，目录页/阅读器反转开关已改走单键写）。
>
> ℹ️ **`Book.readConfig.reverseTocDisplay`（2026-10-28 批31，模型契约加法式，零方法/签名变化）**：书内阅读配置新增 `reverseTocDisplay`（bool，缺键默认 `false`），逐字对齐原版 `Book.ReadConfig.reverseTocDisplay`（`Book.kt:502`）与 `BookDao.updateReverseTocDisplay`。语义：**数据顺序与章节 `index` 身份不变，仅目录展示反序**；与既有 `reverseToc`（数据反转）组合 = 先数据反转、再显示反转（两者同开回到原始顺序）。往返路径：`updateBook`（`readConfig` JSON 全量透传）、自有备份 `books` 段、原版 zip `bookshelf.json` 恢复均自动保留该键；DB 无 DDL（`readConfig` 为 JSON TEXT），`SCHEMA_VERSION` 115→116 仅登记数据契约，旧库缺键按默认 `false` 读取。
>
> ℹ️ **登录 UI V2 动态状态协议（#402/#488）**：Rust 侧 `ffi::source_is_login_ui_v2 / source_login_ui_v2 / source_login_action_v2`（核心实现 `legado-core/src/login_ui_v2.rs`，对齐 Kotlin `LoginUiV2.kt` + `BaseSource.evalLoginUiV2/evalLoginActionV2`）。`loginUi` 为 `{"version":2}` 标记时启用；登录脚本取自 `mainJs`（JS 单文件书源）或 `loginUrl`，须实现 `loginUi(state)` / `loginAction(action, state, form)`。`userInputJson` 契约：`{"action":"...","stateJson":"...","formJson":{...}}`（stateJson/formJson 支持字符串或对象）。JS 返回 null/undefined 时返回空字符串；需 quickjs 特性构建。RowUi V2 扩展字段：key/hint/value/options/countdown。冻结契约保持不变，本组方法为加法式新增。
>
> ℹ️ **书源校验（Task #87）**：Rust 侧 `ffi::source_check / source_check_stream / source_check_cancel`（核心实现 `legado-ffi/src/api/source_check_api.rs`，包装 `legado-net::source_checker::SourceChecker`，与 legado-server `/sources/check` 同源）。`checkSource` 返回 CheckResult JSON：`source_url` / `search_ok` / `toc_ok` / `content_ok` / `search_error` / `toc_error` / `content_error` / `total_time_ms` / `captcha`（detected/captcha_type/matched_keyword）/ `redirect`（redirected/original_url/final_url/is_login_redirect）。`checkSourcesStream` 每完成一个书源推送一条 CheckProgress JSON：`index` / `total` / `is_last` / `source_name` / `result`（CheckResult）；**串行**校验（对齐 Kotlin `CheckSourceService` flow 顺序执行，避免对书源站并发压力），不存在的书源推送失败结果而非跳过（序号连续）。**2026-11-13 批31 语义补全**：①`step_timeout_ms` **真正生效**（此前被解析但从未使用）——每个网络步骤经 `tokio::time::timeout(min(单步, 剩余预算))` 包装，超时记该步 `*_error="timeout"` 并按既有依赖语义继续后续步骤；整源总预算 = `step_timeout_ms × 启用步数`；`step_timeout_ms` 生效值夹取 `100ms..24h`（`0` 会令每次请求立即失败）。②**取消可中断**：每个 await 经 `select!`（取消优先）轮询令牌，`source_check_cancel` 可在 1s 内返回；取消为**协作式**（同步 CPU 段如正则提取/验证码扫描需回到 await 点才观察到，受单步/整源预算约束）。③`CheckResult` 新增 `cancelled`（bool，默认 false）：取消时本步 `*_error="cancelled"`、后续步骤 `"skipped: cancelled"`，`all_ok()` 与 `is_available()` 均排除取消态（取消不计为书源不可用）；批量流**不回推**在途已取消源的结果。④**取消令牌按会话隔离**（`CheckSessionRegistry`）：每次流在**任何 await 之前**登记独立令牌，`source_check_cancel`（无参）只取消最近进行中的会话，另有 `cancel_check_sources_by_id` 精确取消；会话结束（含异常/提前 break）自动注销——修复此前进程级单例导致「取消被吞」与「两次校验互相取消」。`configJson` 契约：`{"keyword":String,"step_timeout_ms":int,"check_search":bool,"check_toc":bool,"check_content":bool,"detect_captcha":bool,"detect_redirect":bool}`，全部字段可选，缺省回落 CheckerConfig 默认值（keyword="我的"、step_timeout_ms=180000、其余全开）。冻结契约保持不变，本组方法为加法式新增。
>
> ℹ️ **验证码交互通道（Task #90）**：Rust 侧 `ffi::verification_request_stream / verification_submit / verification_cancel / verification_pending`（核心实现 `legado-core/src/verification_channel.rs`，对齐 Kotlin `SourceVerificationHelp` + `JsExtensions.getVerificationCode/startBrowserAwait`）。JS 书源经宿主 API 钩子挂起等待（std condvar 阻塞 JS 工作线程，不占用 tokio runtime，默认超时 5 分钟对齐 Kotlin）；同书源并发请求经航班去重共享结果（空 source_url 匿名请求不去重）；`use_browser` 一律降级为图片验证码（桌面端无 WebView）。`verificationSubmit` 无论 code 是否为空都唤醒等待方（对齐 Kotlin `setResult`），空值由等待侧报「验证结果为空」；`verificationCancel` 等价 Kotlin `checkResult`（空结果唤醒）；超时返回「source verification timed out」。订阅事件流时先回放当前进行中的请求。冻结契约保持不变，本组方法为加法式新增。
>
> ℹ️ **BackstageWebView DOM 通道（SOURCE_DIFF P1）**：Rust 侧 `ffi::webview_request_stream / webview_submit / webview_cancel / webview_pending`（核心 `legado-core/src/webview_channel.rs`）。Flutter `WebViewBridgeListener` 订阅后，`@webjs` / 正文 `contentRule.webJs` / `java.webView*` 经真实 WebView 执行并回传；无订阅者时回退无头 QuickJS 或历史桥接载荷（`interceptResult`）。默认超时 60s，规则级 Mode.WebJs 10s。**Android**：`PlatformBridgeService`→原生 `legado/webview.backstageEval`：`cacheFirst`→`WebSettings.LOAD_CACHE_ELSE_NETWORK`；`isRule`+html 时注入 `java`/`source`/`cache` JavascriptInterface（变量读写与精简同步 API；ajax 等网络类仍建议无头宿主）。非 Android 回退 `webview_flutter`（无 cacheMode）。加法式新增。
>
> ℹ️ **项 B/B1 WebView cookie 回流 + sourceKey 补全（2026-09-26，加法式，零破坏）**：Rust 侧新增 `ffi::webview_submit_result_with_cookies`（Dart `submitWebviewResultWithCookies`）——WebView 执行结果 + 域 cookie 回流：cookiesJson 每个域键按 ETLD+1 归一（`cookie_store::normalized_cookie_key`，不相关域不落行，P2-19 口径）merged upsert 落 `cookies` 表 + 同步 JS 桥共享客户端内存 CookieStore（quickjs 构建重置共享池，复用 http_state 落库/锁序口径），先持久化后唤醒等待方；`WebViewRequest` 事件加法式字段 `source_key`（JS 执行线程当前书源 key，缺省空串）/ `cookie`（B4 起按请求域预填，缺省空串），`serde(default)` 空串缺省、旧端忽略未知字段不破坏反序列化。Android 原生 `backstageEval`：注入接口口径由 `isRule` 扩为「`isRule` 或 `sourceKey` 非空」（对齐上游 tag 语义）；结果确定时（onPageFinished 首次命中 + 最终 eval 前）`CookieManager.getCookie(finalUrl)` 读取并随结果回传，返回值加法式改为 `{"result","cookies"}` 信封（cookie 为空时仍返回纯结果串，旧版 loadUrl/evaluateJs 通道语义不变）；非 Android 回退路径 `document.cookie` 尽力读取（仅非 HttpOnly，仅 webView 主路径，嗅探动作空串）。旧 `webviewSubmit`（`submitWebviewResult`）冻结不动。
>
> ℹ️ **书源模型 `ruleContent` 批量正文两字段（2026-10-28 批28，模型契约加法式，零方法/签名变化）**：`BookSource.ruleContent`（嵌套 JSON 对象）新增 `contentBatch`（String，可空，「批量正文规则，支持 JS」，对齐原版 `ContentRule.contentBatch`）与 `maxBatchSize`（Int，可空，`null` 表示不支持批量，对齐原版 `ContentRule.maxBatchSize`）。两键随 `getBookSources` / `addBookSource` / `updateBookSource` / `importBookSources` / `exportBookSources` / 备份（`bookSources` 数组）与「原版 zip `bookSource.json` 导入导出」原样往返；**本批只做字段保真，不实现正文批量下载**（原版 `BookContent.analyzeContentBatch` 行为留待后续批次）。Dart 侧源编辑器保存改走「原 JSON 补丁」（编辑后的模型 JSON 深合到原始 JSON 之上），未在表单出现的规则字段一律保留。**解析宽松口径（批28b 补记）**：`maxBatchSize` 接受 JSON 数字与数字字符串（Gson 式 `"20"`→20）、缺键/显式 `null`→不支持批量，避免单条源字段类型不标准击穿整批 `importBookSources`。

### 2.4 搜索操作（19 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `searchBooks(String keyword, {List<String>? sourceUrls})` | keyword, sourceUrls(可选) | `Future<List<SearchResult>>` | 搜索书籍 |
| `preciseSearch(String name, String author, {List<String>? sourceUrls})` | name, author, sourceUrls(可选) | `Future<SearchBook>` | 精确搜索（对齐 `WebBook.preciseSearchAwait`）：启用源中搜书名，返回首个 name+author 完全匹配的 SearchBook JSON；未命中抛错（SOURCE_DIFF P0-2） |
| `searchMulti(String query, {List<String>? sourceUrls})` | query, sourceUrls(可选) | `Future<List<Map<String, dynamic>>>` | 多源并行搜索 |
| `searchMultiStream(String query, {List<String>? sourceUrls, int page = 1})` | query, sourceUrls(可选), page(默认 1) | `Stream<Map<String, dynamic>>` | 多源渐进式（流式）搜索：每完成一个书源即推送一个批次，无需等待最慢书源；批次事件含 `has_more` 字段（累积值）。**批次B breaking**：新增 `page` 入参透传（同关键词翻页 searchPage++，新关键词重置为 1，对齐原版 SearchModel.kt L73-75）；批次事件另加 `error_class?` 逐源错误八分类字段（2026-09-19 加法式，`error?` 语义冻结不变） |
| `cancelSearch()` | 无 | `Future<void>` | 取消搜索（硬取消，批次A） |
| `pauseSearch()` | 无 | `Future<void>` | 暂停流式搜索（软挂起：未派发书源挂起、已派发任务继续完成；状态/进度保留，可 resume。G-B-04，对齐原版 workingState 门控语义 SearchModel.kt L45/L98/L227-233） |
| `resumeSearch()` | 无 | `Future<void>` | 恢复已暂停的流式搜索（G-B-04） |
| `searchSource(String bookName, String author, {List<String>? sourceUrls, bool loadInfo = false, bool loadToc = false, bool loadWordCount = false, bool forceRefresh = false})` | bookName, author, sourceUrls(可选), loadInfo, loadToc, loadWordCount, forceRefresh | `Future<List<Map<String, dynamic>>>` | 搜索可替换的书源 ⚠️ 双兼容点（留项#12/Task #131：`sourceUrls` 为加法式新增可选参数，null/空=搜全部启用源；`forceRefresh` 默认 false 优先复用 searchBooks） |
| `searchSourceStream(String bookName, String author, {List<String>? sourceUrls, bool loadInfo = false, bool loadToc = false, bool loadWordCount = false, bool forceRefresh = false})` | bookName, author, sourceUrls(可选), loadInfo, loadToc, loadWordCount, forceRefresh | `Stream<Map<String, dynamic>>` | 换源搜索流式（Task #156 / T6）：逐源完成即推一批次事件，首批候选 <5s 到达（500+ 源规模验收线）；批次事件含 `source_index` / `source_url` / `source_name` / `error?` / `finished_count` / `total_count` / `is_last` / `matches[]`（`matches` = 当前已过滤评分排序候选**全量快照**，Rust 侧维持过滤/排序、UI 仅替换展示）；DB 复用路径（forceRefresh=false 且库有数据）推单批即结束；enrich 开启时搜索阶段结束后再推一批 enriched+重排快照（不阻塞首批到达）。旧 `searchSource` 保留兼容 |
| `searchCover(String bookName)` | bookName | `Future<List<Map<String, dynamic>>>` | 搜索书籍封面候选列表：复用多书源搜索提取封面 URL，每项字段 `url` / `width` / `height`（未知尺寸填 0），无候选返回空列表 |
| `switchSource(String bookUrl, String newSourceUrl, String newBookUrl)` | bookUrl, newSourceUrl, newBookUrl | `Future<String>` | 切换书源 |
| `switchSourcePrefetch(String bookUrl, String newSourceUrl, String newBookUrl)` | bookUrl, newSourceUrl, newBookUrl | `Future<String>` | 切换书源（预拉缓存版，2026-09-24 换源感知等待，加法式新增）：命中搜索期预拉缓存（`SwitchPrefetchCache`，key = `newSourceUrl\u0000newBookUrl`，对齐上游 `primaryStr()`）→ 缓存详情+目录**零网络**直接提交（选中即落地）；部分命中（有 info 无 chapters）→ 仅补抓目录；未命中 → 现场抓取详情+目录（执行链同 `switchSource`，且提交前可经 `cancelSwitchSourceApply` 取消，取消后 DB 零变更）；返回新 bookUrl JSON |
| `cancelSwitchSourceApply()` | 无 | `Future<void>` | 取消进行中的「换源（预拉缓存版）」apply（对齐上游 `cancelChangeSource`，ChangeBookSourceViewModel.kt L715-721）：换源 apply 代数 +1 并 bump 目录刷新代数——未提交 apply 在提交前代数比对即中止（DB 零变更），在途目录分页链在下一页边界中止 |
| `updateSearchBookScore(String bookUrl, int score)` | bookUrl, score（-1/0/1） | `Future<void>` | 更新换源列表项用户评分（对标原版 `SourceConfig.setBookScore`，持久化 `searchBooks.bookScore` 并同步书源聚合分） |
| `deleteSearchBook(String bookUrl)` | bookUrl | `Future<void>` | 删除换源列表项（对标换源页长按「删除」，按 bookUrl 移除 `searchBooks` 行） |
| `searchCoverRules(String name)` | name: 书名（作为规则搜索关键词，对齐原版 `BookCover.searchCover(book)` 传 `book.name` 语义） | `Future<String>` | 按书名执行 coverRules 表中全部启用规则搜封面（JS 搜索规则语义对齐原版 `BookCover.searchCover` 链路），返回候选封面 URL **裸 JSON Array**（遵守 §1.4 铁律）；无启用规则/无候选返回空数组（非异常）；单规则失败隔离（记日志跳过，不阻断其余规则）。错误码：Internal（coverRules 规则数据读取失败）（台账 §5.13-10，第四批后置项，Task #72，加法式新增） |
| `getCoverRule()` | 无 | `Future<String>` | 读取封面规则配置（对齐原版 `BookCover.getCoverRule`）：返回裸 JSON 对象 `{enable, searchUrl, coverRule}`；表空时回退 `DefaultData.coverRule`（assets 同源）。错误码：Internal |
| `saveCoverRule(String ruleJson)` | ruleJson: `{enable, searchUrl, coverRule}` | `Future<bool>` | 保存封面规则（对齐原版 `BookCover.saveCoverRule`）：写入 coverRules 表（单配置语义，REPLACE 主配置行）；searchUrl/coverRule 为空 → Internal。F4 |
| `deleteCoverRule()` | 无 | `Future<bool>` | 删除用户封面规则配置（对齐原版 `BookCover.delCoverRule`）：清空 coverRules；随后 `getCoverRule` 回退默认。F4 |

> ⚠️ `searchSource`：Rust 返回 `SourceSwitchResponse { book_name, author, matches[] }`，Dart 侧提取 `matches` 字段。
>
> ℹ️ **换源变量链与执行链对齐（2026-09-03，换源修复任务书 T2/T3/T4/T5，均为加法式）**：
> ① `searchSource` 返回的 `matches[]` 项新增可选字段 `variable`（string，JSON 对象文本；搜索期 `@put`/`putVariable` 级联变量，对齐原版 `SearchBook.toBook()` 复制 variable 语义）；`loadInfo` 开启时 enrich 阶段将详情页导出变量合并入候选 `variable`（详情页后写入者优先）。
> ② `webbookInfo` 返回 JSON 新增可选字段 `variable`（bookInfo 规则求值期间 `@put`/JS `putVariable` 级联导出，与目录解析同一机制；原版无专用 variable 规则字段）。
> ③ `search_books`/`searchSingleSource`/`searchMulti*` 的结果项与 `searchBooks` 表持久化新增/启用 `variable` 透传（元素级解析导出，additive）。
> ④ `switchSource` 签名不变，行为对齐原版 `ChangeBookSourceViewModel.getToc`：先经新源详情解析（canReName=false 保留既有书名/作者，cover/intro/kind/lastChapter/wordCount 按非空更新），以解析出的**真实 tocUrl**（ruleBookInfo.tocUrl，可与详情页不同）取目录；详情或目录任一步失败 → 换源整体失败并保留旧源（单事务回滚，禁止拿 new_book_url 硬闯目录）；`book.variable` = 候选搜索期变量（searchBooks 行）与详情页导出变量合并（详情页后写入者优先，对齐原版覆盖语义）；章节落库保留解析值（`variable`/`isVolume`）。
>
> ℹ️ `searchSource` 分组/书源范围过滤（留项#12，Task #131 闭合）：Rust 侧 `ffi::source_switch_search(book_name, author, source_urls_json)` 新增第三个参数 `source_urls_json`（JSON 字符串数组；空串/空数组/缺省=搜全部启用源，语义与 `search_books` 的 `source_urls_json` 完全一致，复用 `search::load_search_sources` 过滤逻辑）。C ABI `ffi_source_switch_search` 同步加参。Dart 侧 `searchSource` 新增可选命名参数 `sourceUrls`，由 `rust_api` 编码为 `sourceUrlsJson` 传入；换源页按 `AppConfig.searchGroup` 内存过滤出该分组源 URL 列表后传入。冻结契约返回结构不变，本变更为加法式新增。
>
> ℹ️ `searchSource` 分组 config 原生过滤（留项#12 增强，Task #145，**零签名变更**）：Rust 侧 `source_switch::resolve_switch_sources` 内部读取 config `searchGroup`（键名对齐原版 `AppConfig.searchGroup`，UI setConfig 已通），非空时对齐原版 `getEnabledPartByGroup` 的 `SOURCE_GROUP_MEMBERSHIP_FILTER` SQL 语义过滤：分组字段按 `,`/`;`/`，`/`；` 规范化拆分、逐组名 trim 后与目标分组精确相等匹配（非子串）；空分组=全部启用源。过滤后零结果由 UI 弹「xx分组搜索结果为空，是否切换到全部分组」对话框（对标 ChangeChapterSourceDialog L90-97，确认后清空 searchGroup 重搜）。
>
> ℹ️ `searchSource` 换源高级选项（审计 F2-2，**加法式新增**）：Rust 侧 `ffi::source_switch_search` 第四参 `options_json` 为 JSON 对象 `{loadInfo,loadToc,loadWordCount}`；Dart `searchSource` 三命名参数编码传入。空串/缺省时 Rust 回退读取 config `changeSourceLoadInfo`/`changeSourceLoadToc`/`changeSourceLoadWordCount`（键名对齐原版 AppConfig）。`loadInfo` 触发详情页补全；`loadToc`/`loadWordCount` 触发目录抓取；`loadWordCount` 另试读末章正文计字数并按原版 `wordCountComparator` 排序。返回 `matches[]` 项新增可选字段 `chapter_word_count_text` / `chapter_word_count` / `respond_time` / `origin_order` / `book_score`（snake_case，用户评分 -1/0/1，对标原版 SearchBook.bookScore）。

> ℹ️ `searchSource` 复用搜索缓存（**加法式**，`forceRefresh`）：对齐原版 `ChangeBookSourceViewModel` 先 `getDbSearchBooks` 再条件 `startSearch`。搜索流式/一次性结果写入 `searchBooks` 表；换源默认读库复用（`forceRefresh=false`），「刷新列表」等传 `forceRefresh=true` 才强制全量网络重搜。Dart `searchSource` / 换源页进入默认不二次搜索。
>
> ℹ️ **换源搜索流式化（Task #156 / T6，加法式）**：Rust 侧 `ffi::source_switch_search_stream(book_name, author, source_urls_json, options_json, sink: StreamSink<String>)`（frb 生成 Dart `Stream<String>`），驱动复用 `search::drive_source_batches`（并发 32、单源超时 60s、逐源隔离，与主搜索同构）。每完成一个书源推送一个 `ChangeSourceBatch` JSON：`source_index` / `source_url` / `source_name` / `error?` / `finished_count` / `total_count` / `is_last` / `matches[]`——**`matches` 为当前累积候选经同名过滤（+可选作者校验）与评分排序后的全量快照**（逐源增量过滤 ≡ 批量过滤，元素级判定），Rust 侧维持过滤/排序职责、UI 仅按批替换展示。单源错误以 `error` 字段随该批次推送（不中断流）；全部完成后：① `options.needs_enrichment()` 时**流内后置 enrich**——对累积候选补详情/目录后推最后一批 enriched+重排快照（首批到达不受阻塞，对齐任务书「enrich 改流内后置或仅对展示项懒加载」）；② `persist_switch_matches` 落库最终排序结果。DB 复用路径（forceRefresh=false 且 searchBooks 有数据）：读库评分排序后推**单批**（`finished_count=total_count=1`、`is_last=true`）即结束，不发起网络搜索；forceRefresh=true 先清库再全量重搜。旧 `searchSource`（一次性）保留兼容，两 API 共享同一执行链与落库语义。
>
> ℹ️ `searchMultiStream`：Rust 侧 `ffi::search_multi_stream(query, source_urls_json, page, sink: StreamSink<String>)`（frb 生成 Dart `Stream<String>`），每完成一个书源推送一个 `SearchSourceBatch` JSON：`source_index` / `source_url` / `source_name` / `books[]` / `error?` / `error_class?` / `finished_count` / `total_count` / `is_last` / `has_more`（累积值：任一已推送批次非空即 true，对齐原版 SearchModel `hasMore = hasMore || items.isNotEmpty()` 语义）。**批次B breaking 变更**（双轨评审记录：本重构 Rust/Flutter 两轨均归我方所有 + 用户已批准批次B范围）：签名新增 `page: i32` 入参——页码透传至 `build_search_url_with_setup` 第三参及 JS 书源 `orch.search`（原硬编码 page=1），Dart 侧同关键词翻页传 `searchPage++`、新关键词重置为 1。加法式新增：`pauseSearch()` / `resumeSearch()`——Rust 侧 `SEARCH_PAUSED` 门控位于单源派发前（信号量 permit 后、search_one 前；已派发任务继续完成、未派发书源挂起，状态/进度全部保留），新搜索开始时自动解除暂停。冻结契约 `searchMulti` / `cancelSearch` 保持不变。**逐源错误八分类（任务书 B P2 项1，2026-09-19，加法式，零破坏）**：批次 JSON 新增可选字段 `error_class`（字符串枚举，八类：`ok` / `empty` / `http_error` / `timeout` / `login_required` / `js_error` / `parser_error` / `cancelled`），Rust 侧分类在批次组装单点完成（`run_multi_stream` 批次闭包对 `LegadoError` 变体映射，不可归类的落到最近类别并在报告说明）；现有 `error?` 字段及其语义保持不变（冻结约束），不读该字段的旧调用方零破坏；`#[serde(default)]` 兼容历史批次反序列化（历史批次无此字段时回退空串，Rust 侧发出的批次恒为八类之一）。**双轨确认记录（一句）**：本变更 Rust/Flutter 双轨均归我方——Rust 仅批次 JSON 加法式扩展；Flutter 侧 `ffi.dart` 批次事件解析加法式同步，UI 展示已落地（队列④ P1-B，2026-09-22：单源失败累积 `SearchState.failedSources` 并在搜索结果页顶部以非阻断横幅呈现，既有批次消费路径不变）。
>
> ℹ️ **跨源聚合单一真源（队列⑩a P1-1 项2，2026-09-22，加法式，零破坏）**：`SearchSourceBatch.books[]` 元素（`CoreSearchBook`）新增可选字段 `origins`（string 数组，`#[serde(default, skip_serializing_if = "Vec::is_empty")]`——空时序列化省略，**既有批次 JSON 形态零变化**）。填充路径：Rust 跨源聚合入口 `legado_ffi::api::search::aggregate_search_books_json(books_json, key, keep_other)`（FFI crate 内 pub 函数，非 FRB 暴露；`legado-core::search_aggregate::aggregate_search_books` 纯函数为单一真源，语义与 Dart **纯函数** `applyPrecisionSearch`（`search_state.dart` L144-207）逐条对齐——同名同作者跨源合并、origins 并集累加（首次出现序，同源不重复计数）、`hasReadRecord` 跨源 OR、桶序 equal→tags→contains→(keep_other) other、桶内 originsCount 降序 + 首次到达索引平局、空 key 原样返回；**P2-20 裁决后（2026-09-22 收敛）三条路径（纯函数 / `SearchNotifier` 增量桶 / Rust 单一真源）已统一到同一语义——限定在**同一输入列表内**：入桶前跨桶预去重（seen 键为**原始** `(name, author, origin)` 三段，与 `_seenKeys` 逐字一致），同一三元组仅**首次到达**入桶、**落桶由首次到达决定**，后续同键到达丢弃（其 origin 已由首条代表，跨源计数由桶内 `origins` 集合承载）；纯函数与 Rust 入口已补 `seen` 门控，夹具 `keep_other` expected 8→7 条（若回退为无 seen 的四桶独立实现，该 case 由 7 变 8 条、夹具变红——回归保护）。**范围限定（必读）**：该统一仅对**单次调用的输入列表**成立——运行时 `_seenKeys` 为**会话级跨页**去重（跨页 APPEND 不清空，直至新关键词/清空），纯函数 / Rust 入口是**单次调用**语义、不携带会话状态；未来若把运行时聚合切到 Rust 入口，须传**会话累积列表**（会话内全部 books）而非单批 `SearchSourceBatch.books[]`，否则跨页同键书会重复计数（跨页重复回归）。既有 `searchMultiStream` / `searchMulti` 流式批次与解析路径**不填充**该字段（恒为空 → 省略序列化），旧消费方零破坏。Dart 侧 `SearchBook.origins`（`@Default([])`）加法式消费：`SearchResult.fromSearchBook` 非空时优先作为有效 origins（对齐 Rust `effective_origins`：origins 非空→用它；否则 origin 非空→`{origin}`；全空→空集合，计数下限 1）；Dart 运行时增量桶聚合路径不变（切换评估见更新记录 2026-09-22 行③）。跨端夹具：`rust/legado-ffi/tests/fixtures/search_aggregate/cross_source_merge.json`（Rust 集成测试 + Dart 单测双端比对，锁定两端聚合等价，不依赖真网络）。
>
> ℹ️ **封面规则搜索（台账 §5.13-10，Task #72）**：原版实现为单条封面规则配置——Kotlin `BookCover.searchCover(book)` 读取 `CoverRule(enable, searchUrl, coverRule)`（用户配置存 CacheManager，缺省回退 `DefaultData.coverRule`，UI 入口 `CoverRuleConfigDialog`），以 `AnalyzeUrl(searchUrl, book.name)` 发起搜索请求，再经 `AnalyzeRule.getString(coverRule, isUrl=true)` 提取封面 URL。本轨差异与对齐方案：规则载体为 `legado-db` 既有 `coverRules` 表（`id` / `name` / `rule` / `enable`，默认数据注入已就位），执行全部 `enable=1` 规则；规则执行复用既有书源搜索/JS 执行基础设施（`legado-net` HTTP 抓取 + `legado-parser`/quickjs 规则解析链路，与 `dictLookup` 字典规则执行同模式），`rule` 文本承载 searchUrl 与提取规则（具体内联格式由 Rust 轨实施时按表内既有数据确定）；单规则失败隔离不阻断其余；与既有 `searchCover`（多书源搜索提取封面）互补并存、互不影响。冻结契约保持不变，本方法为加法式新增。
>
> ℹ️ **换源预拉缓存与感知等待（2026-09-24，加法式，零破坏）**：对齐上游 Android `ChangeBookSourceViewModel`「换源感知等待」方案三步——① **搜索期并行预拉**：`searchSourceStream` / `searchSource` 的 enrich 阶段对候选做内存预拉缓存写入（`SwitchPrefetchCache`，`source_switch.rs`）——有界并发 `ENRICH_CONCURRENCY = 8`（上游 threadCount=32 覆盖「搜索+enrich」全链；本轨搜索缺省 16/有效上限 32，enrich 为重目录突发，收敛到 8 防连接池饱和），单候选超时复用 `search::SWITCH_SOURCE_TIMEOUT`（60s），单候选失败/超时回退原候选直通、不阻断整批（对齐上游 per-source `try/catch + ensureActive`）；缓存条目 `{info: Option<WebBookInfo>, chapters: Vec<WebChapter>}`，key = `new_source_url\u0000new_book_url`（对齐上游 `primaryStr()` = origin+bookUrl 拼接，`\u0000` 分隔防拼接边界歧义），总目录数上限 `PREFETCH_CACHE_MAX_CHAPTERS = 30000`（超限条目跳过、不计入配额）；② **选中命中零网络**：`switchSourcePrefetch`（§2.4 加法式新增）——完整命中（chapters 非空）→ 缓存详情+目录直接提交，**零网络、选中即落地**；部分命中（info 有、chapters 空）→ 仅补抓目录（2a 跳过）；未命中 → 现场抓取详情（2a）+目录（2b），执行链与 `switchSource` 同构（`switchSource` 本体签名与行为冻结不变）；③ **可取消加载态**：`cancelSwitchSourceApply`（§2.4 加法式新增，对齐上游 `cancelChangeSource` L715-721）——`SWITCH_APPLY_EPOCH` 代数 +1 并同步 bump 目录刷新代数（`bump_toc_fetch_epoch`）：在途 apply 在详情前/目录前/提交前三点代数比对即中止（`Err("换源已取消")`，DB 零变更），在途目录分页链在下一页边界中止；Flutter 换源页 apply 在途展示可取消加载态（spinner + 取消钮）。**双轨确认记录（一句）**：本变更 Rust/Flutter 双轨均归我方——Rust 仅 `source_switch.rs` 增 `SwitchPrefetchCache`/`SWITCH_APPLY_EPOCH`/`cancel_switch_apply` + FFI `source_switch_apply_prefetch`/`source_switch_apply_cancel` 两个新导出；Flutter 侧 `BookApi.switchSourcePrefetch`/`cancelSwitchSourceApply` + RustApi/MockBookApi 实现 + 换源页进度串对齐上游 zh「结果 %1$d, 当前进度 %2$d / %3$d: %4$s」（values-zh/strings.xml:1457 + ChangeBookSourceDialog.kt L286-298）与可取消加载态；`reloadAfterSourceChange` 链、进度保持、本地书隐藏入口、`switchSource` 既有行为均不变。§2.4 方法数 17→**19**，附录合计 278→**280**，BookApi 口径 275→**277** |

> ℹ️ **搜索并发来源（批9b-2，2026-10-31，零签名变化）**：主搜索（`searchBooks` / `searchMulti` / `searchMultiStream`）与换源搜索（`searchSource` / `searchSourceStream`）的跨源并发上限不再固定 32，改为**每次入口运行期**读取 caches `config:threadCount`（Dart `setConfig("threadCount", v)` 写入）：缺失/空串/非整数回落 **16**（参考版缺省），数值夹逼 **1..=32**（`search.rs::search_concurrency()`）。**上限说明**：参考版 UI 允许更高值，但本架构的 runtime `max_blocking_threads=64`、单源约 2 个 spawn_blocking（URL 构建 + 解析），32 并发即匹配池容量，故有效上限取 32；设置 >32 保存后搜索按 32 执行。单源内解析顺序、跨源结果聚合口径、会话取消/暂停（仅拦未派发源）、单源超时（搜索 30s / 换源 60s）与 `drive_source_batches` 的隔离/中止语义均不变。进行中的搜索不热更新（新值从下一次搜索入口生效）。换源 enrich 阶段的有界并发 `ENRICH_CONCURRENCY = 8` 独立不随该键变化（防止重目录突发打满连接池）。

### 2.5 RSS 源操作（19 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getRssSources()` | 无 | `Future<List<RssSource>>` | 获取所有 RSS 源 |
| `addRssSource(RssSource source)` | source: RssSource 对象 | `Future<RssSource>` | 添加 RSS 源 |
| `updateRssSource(RssSource source)` | source: RssSource 对象 | `Future<void>` | 更新 RSS 源（Rust 侧 `ffi::rss_update_source`：按 `sourceUrl` 主键单条 UPDATE 原子更新，替代「删旧+加新」workaround，规避级联串表风险；Task #108，加法式新增 FFI）。✅ UI 封装接通：`rust_api.updateRssSource` 已由误接 `sourceUpdate` 改接 `rssUpdateSource` 真实管线（本次评审修复提交），Mock 同步对齐「源不存在时报错」语义 |
| `rssUpdateSource(String sourceJson)` | sourceJson: RssSource JSON | `Future<String>` | 原子更新 RSS 源（按 `sourceUrl` 主键单条 UPDATE 全字段），源不存在时报错，返回更新后的 RssSource JSON（Task #108，加法式新增） |
| `deleteRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 删除 RSS 源 |
| `enableRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 启用 RSS 源（委托 `rssSourceSetEnabled(sourceUrl, true)`）。**2026-10-26 审查批6 修复**：此前误接书源 `source_enable`（`BookSourceRepository`），RSS-only 源报「书源不存在」、同 URL 有书源时会误改书源；现只更新 `rssSources` 表。签名与「启用 RSS 源」语义冻结不变 |
| `disableRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 禁用 RSS 源（委托 `rssSourceSetEnabled(sourceUrl, false)`）。**2026-10-26 审查批6 修复**：同 `enableRssSource`，不再误接书源 `source_disable`；现只更新 `rssSources` 表 |
| `rssSourceSetEnabled(String sourceUrl, bool enabled)` | sourceUrl / enabled | `Future<bool>` | 设置 RSS 源启用状态（Rust `ffi::rss_source_set_enabled` → `legado-db::RssSourceRepository::set_enabled` 单实现）：按 `sourceUrl` 单条 UPDATE `rssSources.enabled`，返回是否实际命中行；**源不存在返回 `false`（不抛错）**，对齐原版 `RssSourceDao.enable`（Room `@Query` UPDATE 静默语义），**书源表零触碰**（2026-10-26 审查批6 加法式新增） |
| `importRssSources(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 导入 RSS 源，返回成功数量。✅ **2026-08-12 纠偏**：Flutter `rust_api.importRssSources` 曾误接 `sourceImport`（写入书源表）；现改为逐条 `rssAddSource` 落 `rssSources`。Rust `add_rss_source` 已改走 `RssSourceRepository::insert` 全字段；`import_rss_sources` 已在 `api/rss.rs` 备好，待 FRB 生成后可改批量 FFI |
| `exportRssSources()` | 无 | `Future<String>` | 导出 RSS 源。✅ **2026-08-12 纠偏**：勿走 `sourceExport`；现导出 `getRssSources()` JSON |
| `getRssArticles(String sourceUrl)` | sourceUrl | `Future<List<RssFeedArticle>>` | 获取 RSS 文章列表（保留兼容；内部等价 `rssRefreshArticles(sourceUrl, "", sourceUrl, null)`，见 §2.5 批15b 注）。**2026-10-26 批15c 审查**：JSON 载荷新增 `sort` 字段（列表规则 `sortName`，默认解析为空串），Dart `RssFeedArticle.sort` 原样透传详情页 |
| `rssClearArticles(String sourceUrl)` | sourceUrl | `Future<void>` | 清空指定 RSS 源本地文章缓存（对齐原版 clearArticles，F3-10 补登记） |
| `rssSortUrls(String sourceUrl, {String? sortUrl})` | sourceUrl / sortUrl(可选) | `Future<String>` | 解析 RSS 源分类列表，返回 JSON 数组 `[{"name","url"}]`。对齐原版 `RssSource.sortUrls()`（`RssSourceExtensions.kt:87-107`）：`sortUrl` 按 `&&` / 换行（`\r?\n`）分段，每段 `name::url` 拆分（无 `::` 的段因 url 为空被丢弃）；配置以 `@js:` / `<js>` 开头时经 JS 求值（注入 RSS 源 jsLib + setup + `source`/`java` 绑定），求值结果按源缓存（`CacheRepository`，键 `rssSortUrl_` + MD5(sourceUrl + sortUrl)，对齐原版 ACache 名 `rssSortUrl`；仅脚本配置读/写缓存）；求值失败/无配置/结果为空 → 回退 `[{"name":"","url":sourceUrl}]`（2026-10-26 批15b 加法式新增）。**`sortUrl` 覆盖（批15f）**：非空时忽略源配置、按原版 `RssSortActivity.kt:356-366`（参考版 `RssSortViewModel.parseSortUrl`）解析该值——`{name:url}` JSON 对象展开（保持书写顺序；解析失败回退单条 `("", sortUrl)`），非 JSON 单条 `("", sortUrl)`；空对象按源 URL 兜底单条（原版为空列表，UI 无分类可渲染，属已登记差异）。**覆盖路径边界口径（审查 P2-7）**：① 整个覆盖值先 `trim` 再判形态，单条回退时 URL 取 **trim 后的原值**（源配置 `::` 路径则分别 trim 名称/URL 段）；② **JSON 对象含重复键**时逐项展开为多个分类条目（保序 visitor 不复刻 GSON `Map` 的「后者覆盖前者」，属已登记差异）；③ **JSON 值非字符串**（数字/布尔/对象/数组）或尾随垃圾 → 整串按形态不符回退单条 `("", trim 后原值)`（不是回退源 URL）；④ 以 `{` 开头但非合法 JSON 同样回退单条；⑤ 空白覆盖值回退源配置解析（`parse_sort_urls`），与「非 JSON 单条」不同 |
| `rssListCachedArticles(String sourceUrl, {String? sortName})` | sourceUrl / sortName(可选) | `Future<String>` | 只读 DB 查询本地缓存的 RSS 文章（**零网络**），返回 JSON 数组（字段同 `RssArticleItem`：`origin/sort/title/order/link/pubDate/description/content/image/variable/group/read/type`），按 `order DESC` 排序。对齐原版 `RssArticleDao.flowByOriginSort(origin, sortName)` 的首屏本地缓存语义（`RssArticlesFragment.kt:179-218`）：**`sortName = Some("")` 严格过滤空名分类（UI 默认分类，名称恒为空串），不是「全部分类」；`null`（缺省）才返回该源全部分类，仅供内部/兼容使用，Dart 侧恒传 `sortName`**（2026-10-26 审查 P1-2 修正）。`read` 由 `rssReadRecords` 派生（`LEFT JOIN rssReadRecords AS t2 ON t1.link = t2.record` + `ifNull(t2.read, 0)`，不再读 `rssArticles.read`，对齐 `RssArticleDao.kt:16-20`；审查 P2-1）。`legacy:` 伪主键原样返回（UI 按 `hasRssArticleLink` 视为无链接）。**键名差异（审查 P2-10）**：本载荷分类字段为 `type`，列表载荷（`rssRefreshArticles` / `rssLoadMoreArticles`）为 `articleType`，两者同义；Dart `RssFeedArticle.fromJson` 兼容两种键。Dart `RssNotifier.selectSource`/`selectSort`/`clearSearch` 在网络刷新前先展示本缓存（2026-10-26 批15f 加法式新增） |
| `rssClearSortCache(String sourceUrl)` | sourceUrl | `Future<void>` | 清除该源分类脚本求值缓存（对齐原版 `RssSource.removeSortCache()`；缓存键同 `rssSortUrls`，源不存在时静默） |
| `rssRefreshArticles(String sourceUrl, String sortName, String sortUrl, {String? key})` | sourceUrl / sortName / sortUrl / key(可选) | `Future<String>` | 刷新 RSS 列表（对齐 `RssArticlesViewModel.loadArticles` + `Rss.getArticlesAwait`）：`AnalyzeUrl(sortUrl, page=1, key)`（`baseUrl=sourceUrl`）→ `loginCheckJs` 登录检测 → `RssParserByRule` 规则列表解析（`ruleArticles` 空回退默认解析）→ 按 `order` 自当前毫秒递减 `INSERT OR REPLACE` 写库；`ruleNextPage` 非空时按 `(origin, sort, order)` 执行 `clearOld`。返回 JSON `{"articles":[{...}],"nextUrl":String?,"hasMore":bool}`；`hasMore = 文章列表非空 && nextUrl 非空`（2026-10-26 批15b 加法式新增）。**请求语义（批15c 审查）**：每次请求前按源 `concurrentRate` 取限流许可；响应经四级字符集解码（见下方批15c 注） |
| `rssLoadMoreArticles(String sourceUrl, String sortName, String nextUrl, int page, {String? key})` | sourceUrl / sortName / nextUrl / page / key(可选) | `Future<String>` | 加载 RSS 下一页（对齐 `RssArticlesViewModel.loadMore`）：请求 `nextUrl`（`page` 为当前页码 + 1，`AnalyzeUrl` 变量）→ 解析 → 用 `(origin, link, sort)` 同时查询本页首条与末条：**两者均已在库即判到底**（不写库，`hasMore=false`）；否则 `order` 续接该 `(origin, sort)` 最小 order 递减、`INSERT OR IGNORE` 追加（已存在行保持原 order）。**空/空白 `nextUrl` 直接返回 `{"articles":[],"nextUrl":"","hasMore":false}`（不发请求）**。返回 JSON 同 `rssRefreshArticles`；`hasMore = 实际追加 && nextUrl 非空`（2026-10-26 批15b 加法式新增） |
| `rssFetchContent(String sourceUrl, String link, {String? sort})` | sourceUrl / link / sort(可选) | `Future<String>` | 拉取 RSS 文章正文（对齐 `ReadRssViewModel.loadContent` + `Rss.getContentAwait`）：按源 `ruleContent` 抓取 `link`，`nextContentUrl` 多页拼接（单链顺序跟随 + URL 去环；多链有界并发、按列表顺序拼接），成功后写回 `rssArticles.description` 与 `rssStars.description`（仅已收藏行）。返回正文 HTML/文本；`ruleContent` 为空或正文为空 → 空串；首屏/任一后续页失败 → 抛错。`sort` 用于在 `(origin, link, sort)` 主键中定位写回行与文章 `type`：**给定 sort 时完整主键精确命中；缺省按 `ORDER BY order DESC LIMIT 1` 取该 `(origin, link)` 首行**（对齐原版 `getByLink` 单行语义；同 link 多分类时缺省会取最新一条，属已登记风险，调用方应尽量传 sort），2026-10-26 批15c 加法式新增，语义见下方批15c 注 |
| `rssWebViewHostCall(String sourceUrl, String method, String argsJson)` | sourceUrl / method / argsJson | `Future<String>` | RSS 阅读 WebView `preloadJs` 宿主桥单入口 RPC（2026-10-27 批21a 加法式新增）。`argsJson` 为**位置参数 JSON 数组**（`[...]`，≤1 MiB）；返回 JSON 信封 `{"ok":bool,"value":<any>,"error":String?,"actions":[...]?}`（`actions` 仅非空时出现）。**内部方法**：`__prepare`（`args[0] = {"channelName","callbackName","ua"}`，`value = {"script","snapshot"}`；源 `preloadJs` 为空/空白 → `script` 为空串＝不注入桥）、`__cookieSet`（`args[0] = {"url","cookie"}` → WebView Cookie 回流，合并 upsert 落库并同步内存 CookieStore）、`__store`（`args[0] = {"op","key","value"}`；`op` ∈ `sourceGet`/`sourcePut`/`sourceVariableGet`/`sourceVariableSet`/`loginHeaderGet`/`loginHeaderSet`/`loginHeaderRemove`/`loginInfoGet`/`loginInfoSet`/`loginInfoRemove`/`cacheGet`/`cachePut`/`cacheRemove`/`cachePutMemory`/`cacheGetFromMemory`/`cacheDeleteMemory`/`log`/`toast`/`longToast`）。**对外方法白名单**（对齐 `WebJsExtensions.request` funName）：`run` / `ajaxAwait` / `connectAwait` / `getAwait` / `headAwait` / `postAwait` / `webViewAwait` / `webViewGetSourceAwait` / `decryptStrAwait` / `encryptBase64Await` / `encryptHexAwait` / `createSignHexAwait` / `readTxtFileAwait` / `importScriptAwait` / `getStringAwait`；`downloadFileAwait` 本批明确返回不支持（文件 API 后置）。Rust 在 `executor:<sourceUrl>` QuickJS 引擎中执行宿主调用（源静态 header + UA 注入全局请求头、`enabledCookieJar` 查询回退 RSS 源、`concurrentRate` 限流、`ui_action_queue` 收集动作）。详见下方批21a 补记 |

> ℹ️ **RSS 源原子更新（Task #108 缺口④）**：Rust 侧 `ffi::rss_update_source(source_json)`（核心实现 `legado-ffi/src/api/rss.rs::update_rss_source`，DB 层 `legado-db::RssSourceRepository::update_fields`）。对 `rssSources` 表按 `sourceUrl` 主键执行**单条 UPDATE 语句**全字段原子更新（不走 DELETE+INSERT，不触发外键级联）；目标源不存在时返回错误（不静默插入）。Flutter 侧 RSS 源编辑保存应改走本接口，替代原「删旧+加新」workaround。冻结契约保持不变，本方法为加法式新增。
>
> ℹ️ **RSS 源启用/禁用写路径（2026-10-26 审查批6，加法式）**：`enableRssSource` / `disableRssSource` 统一委托 `rssSourceSetEnabled(sourceUrl, enabled)`；Rust 侧 `ffi::rss_source_set_enabled(source_url, enabled)`（`legado-ffi/src/api/rss.rs::set_rss_source_enabled`）→ `legado-db::RssSourceRepository::set_enabled`（`UPDATE rssSources SET enabled = ?2 WHERE sourceUrl = ?1`，单实现）。**原版语义对照**：`app/src/main/java/io/legado/app/data/dao/RssSourceDao.kt:152-153` 的 `enable(sourceUrl, enable)` 就是同形 Room `@Query` UPDATE——源不存在时静默 0 行、不报错、不碰书源表；故本方法以 `bool` 返回是否实际命中行（`false` = 源不存在），Dart 侧不抛异常。**旧实现缺陷**：误接 `source_enable` / `source_disable`（书源 FFI，`BookSourceRepository`），RSS-only 源报「书源不存在」，同 URL 恰有书源时误改书源——本批已消除，RSS 源开关写路径不再触碰 `book_sources` 表。

> ℹ️ **RSS 规则列表 / 分类 / 分页（2026-10-26 批15b，加法式）**：Rust 实现在 `legado-fetcher/src/rss/`——`parser_rule.rs` 逐行对齐 `RssParserByRule.kt:22-140`（`ruleArticles` 首字符 `-` 反转、`get_elements` 元素循环、`ruleNextPage` 大小写不敏感 `PAGE` → `nextUrl = sortUrl`、其余规则求值后按 `sortUrl` 绝对化；字段求值顺序 **title → pubDate → description → image → link**，全部求值后才按 `title.isBlank()` 丢弃条目；`description` 规则为空 → null、规则非空但无匹配 → **空串**；`image` 按 `sourceUrl` 绝对化；`link` 走 `getString(isUrl=true, unescape=true)` 空回退 `sortUrl`；`variable` = 列表级规则变量 JSON；`type` 复制源 `type`）；`sort_urls.rs` 对齐 `RssSourceExtensions.kt:49-113`（`&&`/换行分段、`name::url`、`@js:`/`<js>` 求值 + 缓存、失败回退）；`login.rs` 对齐 `Rss.kt:57-81`（成功响应 eval `loginCheckJs`；失败按 `getErrStrResponse`（code 500）二次 eval，二次仍 500 → 登录失败）。**登录头同源门控（审查 P1-2）**：请求目标 `AnalyzeUrl(sortUrl, page, key, baseUrl=sourceUrl)`；源静态 header 始终透传，`loginHeader_<url>` / `userInfo_<url>` **仅在请求 URL 与 `sourceUrl` 同源（scheme + host + port 全等）时**合并/注入 JS 上下文，跨域 `nextUrl`（第三方跳转/聚合外链）不携带任何登录凭据（收敛方向对齐原版 `Rss.kt:56 hasLoginHeader=false`，合并本身仍为已登记超集）；`proxy` 键仍提取为代理配置后剥离、绝不出网。**分页语义**：`rssLoadMoreArticles` 空/空白 `nextUrl` 直接返回 `{"articles":[],"nextUrl":"","hasMore":false}`（不发请求）；非空时本页首末条均在库即判到底，否则 `order` 以该 `(origin, sort)` 的 `min(order)-1` 续接、`INSERT OR IGNORE` 追加（已存在行保持原 order；部分重叠页只追加新条目）。**已登记差异**：原版 `order` 为 VM 会话字段，进程重启后翻页会从新的当前毫秒计数（新页可能排到旧页前）；本实现无会话状态，始终接在旧页之后。DB 侧 `legado-db::RssArticleRepository` 新增 `clear_old` / `append_ignore` / `find_one` / `min_order`；旧数据 `sort=""` 按默认分类读取、不做迁移（E5）。**E4 维持 15a**：默认解析对齐原版保留空 link，仓库 `legacy:` 伪造主键保留（规则列表解析已保证非空 link，回退 `sortUrl`）。**Dart 封装状态**：`BookApi` / `RustApi` / `MockBookApi` 已同批实现 4 方法（Mock 内存实现），**UI 调用点（RssNotifier 分类/分页/搜索与列表页）已接线（批15d，`c188d02c55` + `9aa860fa6c`）**。

> ℹ️ **RSS 正文规则 / 正文分页（2026-10-26 批15c，加法式；含同日审查回修）**：Rust 实现在 `legado-fetcher/src/rss/content.rs`，逐行对齐 `Rss.kt:99-242`（`getContentAwait` / `getContentResponse` / `analyzeContentPage`）：
> - **首屏**：`AnalyzeUrl(link, baseUrl = sourceUrl, page/key 空)` → 源静态 header 始终透传；`loginHeader_<url>` / `userInfo_<url>` 仅当目标与 `sourceUrl` 同源（scheme + host + port 全等）时附加/注入 JS 上下文（复用批15b 门控）；`loginCheckJs` 成功/失败两路检测与列表共用 `login` 模块单实现；
> - **请求限流**：每次正文请求（含 `nextContentUrl` 每一页）前按 `RssSource.concurrentRate` 取许可，复用书源 `RateLimiterRegistry` 的 limiter map 与固定窗口语义（对齐上游 `AnalyzeUrl` 内 `ConcurrentRateLimiter`，`AnalyzeUrl.kt:129,449`）；空 / `"0"` / 非法不限流。宿主在 RSS 源 `add/import/update` 写库成功后 `refresh` 该源配置，引擎按当前源快照惰性创建/复用（与书源路径一致）；RSS 与书源同 URL 时共享同一窗口；
> - **字符集**：请求改 `send_raw` 取原始字节 + `decode_web_response` 四级解码（显式 charset → `Content-Type` → HTML meta → chardetng 统计探测），对齐上游 `OkHttpUtils.ResponseBody.text`（显式/头/meta）+ `EncodingDetect`（统计探测），与书源抓取链/搜索链同一实现；
> - **正文解析**：`AnalyzeRule::new(body)` + `set_base_url(get_absolute_url(sourceUrl, 当页请求 URL))` + `set_redirect_url(响应最终 URL)` + `get_string(ruleContent)`；`ruleContent` 为空 → 空串（对齐原版 `getString(null/"") → ""`）。正文页 `@get:{k}` 以库里 `rssArticles.variable` 种子化（对齐原版 `AnalyzeRule(ruleData = rssArticle)` 的初值）；**`rssArticle` JS 绑定**注入文章行 JSON（`origin/sort/title/order/link/pubDate/description/content/image/variable/group/read/type/durPos`，对齐 `AnalyzeRule.kt:906` 的 `bindings["rssArticle"]`），文章行不存在时注入最小对象 `{origin,title:"",link,type:0}`；列表规则逐元素求值时注入 `{origin, sort, variable}` 基线对象（「已求值字段逐步可见」不复刻，见下方差异⑦）；
> - **正文分页**：仅 `source.type == 0 && 文章 type == 0 && nextContentUrl 非空` 时启用；下一页列表 = `get_strings_ex(nextContentUrl, is_url=true)`（按重定向最终 URL 绝对化 + 去重，对齐原版 `getStringList(isUrl = true)`）。**单链**（列表恰 1 个）：顺序 while 跟随，已访问集合 = `{首屏响应最终 URL} ∪ 已请求 URL`，next 为空或回环即停；**多链**（>1）：有界并发（固定上限 32；远低于该值时按列表长度），结果**按列表顺序**拼接，不再跟随各页的下一页（对齐原版 `mapAsync` 保序 `await`）。最终 `"\n"` join（空页也占一行，产生空行，与原版一致）；
> - **错误语义**：首屏失败、`loginCheckJs` 判定未登录、任一后续页失败 → `Err`（原版 `mapAsync` 为保序 `await`，任一页异常即整次 `getContentAwait` 抛出，**不做部分返回**；Rust `buffered` 同语义）；**空正文 → `Ok("")`**（原版把空串交给 UI，界面显示空白内容，不报错）。非 2xx 维持批15b 的严格报错（原版不校验状态码，已登记同一条差异）；
> - **写回**：正文成功后写回 `rssArticles.description`（`RssArticleRepository::find_by_link(origin, link, sort?)` 主键索引查询取全行后 `REPLACE`，`sort` 缺省按 `ORDER BY order DESC LIMIT 1` 取首行，对齐原版 `getByLink`）与 `rssStars.description`（仅 `(origin, link)` 已收藏行存在时，对齐 `ReadRssViewModel.kt:153-168`）；文章行不存在时跳过写回（历史记录入口只有 origin/link，对齐原版 `RssArticle(origin, title, title, link = openUrl)` 的内存态）。**文章元数据口径**：`type` / `variable` **以 `rssArticles` 为准**；Dart `addRssStar` 只传 `origin/title/link`、其余字段默认（本契约此前「正常收藏由文章派生」表述有误，已按实现更正）。写回保留既有 `order` / `read`（e2e 断言钉住；原版 `toRssArticle()` 不带 order，REPLACE 会把 order 置 0，属上游瑕疵，不复刻）。**已登记差异**：① 写回失败仅 `warn`，正文仍返回（原版写库异常会走 `onError`，整次加载显示失败）；② 正文页 `@put` 产生的变量不回写 `rssArticles.variable`（原版随 `RuleData` 对象变更落库）；③ 多链并发不接会话取消信号（原版 `currentCoroutineContext().ensureActive()`，FFI 无会话取消面）；④ 单链分页不设总页数上限（原版同样无上限，靠 URL 去环判停）；⑤ **多链并发度固定 32**（上游取可配置 `AppConfig.threadCount`，默认 32；FFI 无全局配置面，不随用户设置变化）；⑥ **登录头合并为超集**（原版 `getContentResponse` 传 `hasLoginHeader = false`，正文请求不合并登录头；本实现仅同源附加、跨域不发，仍是超集）；⑦ **`rssArticle` 字段可见范围**（正文页注入完整 DB 行；列表元素仅注入基线对象，原版逐字段可见不复刻）。
> - **Dart 侧（同日审查回修）**：详情页触发条件为「`description` 为空（`isNullOrBlank` 口径）即拉取，**自带 `content` 非空也拉**」（对齐 `resolveRssReadLoadTarget` 只认 description）；`RssFeedArticle.sort` 透传 `rssFetchContent(sort:)`；WebView `loadHtmlString(html, baseUrl: article.url)`（`substringBefore("@js")`，对齐 `ReadRssActivity.kt:406-411`；`loadWithBaseUrl` 源字段接线属批15f）；抓取成功后收藏使用抓取到的正文（Rust `addRssStar` 仅取 origin/title/link，其余默认，见上）；自带 content 的失败降级提供「重试」SnackBar action；返回列表回填抓取正文（列表页无 DB-only 查询 FFI，登记 15d 补；DB 真源由 Rust 写回）。**历史入口已透传 origin 并可抓规则正文**（批15d：`rss_screen.dart` 历史对话框与文章页「阅读记录」均透传；`legacy:` 伪主键视为无链接不触发）；文章 DTO 缺 sort/type 等字段（写回按 order DESC 首行，风险已登记），收敛属 15f。**批15d 追加登记**：① 初始 `sortUrl` 覆盖路径（原版 JS `sort` 动作）不可达，挂 15f；② 分类栏采用参考版单行可滚动 TabBar，原版多行 chip 与参考版分类展开下拉均不复刻；③ 列表页 DB-only 查询（先展示本地缓存）改挂 15f/后续。
> - **批15f 回销（2026-10-26）**：① **DB-only 查询已落地**——`rssListCachedArticles`（§2.5）+ `RssNotifier.selectSource`/`selectSort` 首屏先渲染本地缓存（详情页内存回填保留为即时反馈，DB 仍为真源）；② **初始 `sortUrl` 覆盖参数已就绪**——`rssSortUrls(sourceUrl, {sortUrl})` 解析覆盖值（JSON `{name:url}` 保持书写顺序 / 非 JSON 单条），`RssArticlesScreen(initialSortUrl:)` → `selectSource(sortUrl:)` 透传；JS `java.open("sort", …)` 动作接线不在本批（无调用方，注册后续）；③ **文章 DTO 补 `type`**——列表/缓存载荷 `type`（兼容 `articleType`）进入 `RssFeedArticle.type`，供图片/视频源阅读分流；④ **WebView 阅读链**（`startHtml`/`startJs`/`injectJs`/`preloadJs`/`style`/`enableJs`/`loadWithBaseUrl`/`showWebLog`/`contentWhitelist`/`contentBlacklist`/`shouldOverrideUrlLoading`）在详情页接线；**已登记差异**：`preloadJs` 对 URL 模式改为 `onPageStarted` 注入（原版经 `shouldInterceptRequest` 重写主文档 `<head>`，Flutter WebView 无该拦截面）、白/黑名单仅作用于主框架导航（原版覆盖全部子资源请求）、`showWebLog` 经 console 钩子回读日志（原版 `onConsoleMessage`）、`cacheFirst` 无跨平台 cacheMode 面（沿用批15a 登记）、`shouldOverrideUrlLoading` 的 Java 对象仅提供空实现桩（`open/searchBook/addBook/showPhoto` 不执行，登记 15g）；⑤ **`coverDecodeJs` 未接线**（原版在图片解码层执行 JS，需字节侧桥；登记 15g）；⑥ **`type` 图片分流**：源 `type == 1` 打开全屏图片查看（缩放/保存），`== 2` 打开视频播放页，0/未知走 WebView。⑦ **同日审查回修**：`startHtml` 起始页独立渲染条件（此前控制器已初始化仍落「暂无内容」空态）；`shouldOverrideUrlLoading` 结果经 Dart 归一（JS 返回原始值，Android JSON 字面量去引号；`null`/`undefined`/空串不拦截），修复字符串 `"false"` 恒判 true 的全拦截；源 header 无 `User-Agent` 时回落全局 `PrefKeys.userAgent`（再缺省用系统默认，对齐原版 WebView 全局 UA）；`legado:`/`yuedu:` 导航走站内关联导入（复用 `DeepLinkService.handleUrl`，不再交外部浏览器）。

> ℹ️ **RSS 阅读 WebView `preloadJs` 宿主桥（2026-10-27 批21a，加法式）**：Dart 侧（批21b）负责 WebView `JavaScriptChannel` 握手、动作转发与同步面摊平；Rust 侧只提供本单入口 RPC，**本批不写 Dart channel 业务代码**（`BookApi`/`RustApi`/`MockBookApi` 仅纯委托直通）。
> - **作用域（1:1 对齐原版）**：桥**只在 `preloadJs` 作用域**存在——`__prepare` 按源 `preloadJs` 是否非空返回脚本（空/空白 → `script` 为空串，Dart 不注入任何桥）；`injectJs` 与页面内普通脚本**无桥**（原版 `initJavascriptInterface` 仅在 `preloadJs` 非空时注册，`onPageFinished` 的 `injectJs` 不注册接口，`ReadRssActivity.kt:452-455,650-658,739-762`）。
> - **脚本拼接口径（冻结）**：`script` 为 Rust 生成的 IIFE **头部**（`java`/`source`/`cache` 垫片 + 通道回调注册），以 `// __LEGADO_PRELOAD_JS__` 注释行结尾；Dart 必须把该标记行替换为 `preloadJs` 原文，并以 `\n})();` 闭合，等价原版 `(() => {$JS_INJECTION\n$preloadJs\n})();`。`snapshot` 同时回传只读快照（`sourceUrl/sourceName/loginUrl/loginUi/header/loginHeader/loginInfo/sourceVariable/vars/userAgent`），供 Dart 同步面（`source.get` 等）零 RPC 摊平。
> - **通道协议（Dart 实现）**：垫片调用 `window[channelName].request(method, argsJson, id)`（`argsJson` 为 JSON 数组），Dart 完成后回调 `window[callbackName](id, ok, payload)`；`ok=false` 时 `payload` 为错误串（Promise reject）。`*Await` 函数在注入 IIFE 闭包内可用（`preloadJs` 词法可见，**不挂 `window`**；原版同样在 `(() => {…})()` 内声明），参数/结果均为字符串。`__prepare` / `__cookieSet` / `__store` 的对象参数均为 `argsJson` 数组的**第 0 个元素**（如 `[{"channelName":…}]`）。
> - **Rust 执行面**：每个对外方法在 QuickJS 引擎（批21c 起键 `rss-webview:<sourceUrl>`，绑定 `current_source`）中执行 `(function(){ var __a=<argsJson>; var __r=__lgWebHost[<method>].apply(null,__a); return JSON.stringify({value:__r}); })()`；宿主调用前后由 `ui_action_queue::with_collect` 收集 `java.webView*` 等结构化动作。请求上下文：源静态 `header` JSON + UA（`__prepare` 的 `ua`，缺失回落 `LegadoClientConfig::default().user_agent`）经 `java.putGlobalHeaders` 注入、`enabledCookieJar` 查询在书源 miss 时回退 `RssSourceRepository`、源 `concurrentRate` 经 `RateLimiterRegistry::acquire_by_source` 限流（**网络类方法每次调用一许可**；`run` 内嵌 `java.ajax` 不单独限流，已登记差异）。登录头**不自动注入**请求（跨域安全，对齐原版 `Rss.kt:56 hasLoginHeader=false`），脚本可经 `source.getLoginHeader()` 显式使用。
> - **平台差异（已登记）**：① **同步网络 API 不可用**——`java.ajax`/`connect`/`get`/`post`/`head`/`webView*` 等同步网络/加密/解析调用在垫片中抛「请改用 `ajaxAwait`/`connectAwait`/…（WebView 同步宿主调用不可用）」并写日志；原版经 `@JavascriptInterface` 同步可用。② `cache.get`/`getFromMemory` 同步读基于页面内镜像（跨页面会话首次 miss 返回 `null`，写操作异步落 `cache_store` 并回填镜像），原版同步命中进程缓存。③ `source.put`/`setVariable`/`putLoginHeader`/`putLoginInfo` 同步写先更新页面镜像、再经 `__store` 异步落库（键 `v_<sourceUrl>_*` / `sourceVariable_<sourceUrl>` / `loginHeader_<sourceUrl>` / `userInfo_<sourceUrl>`，与规则 JS 同键空间；登录头写入同时同步 `Cookie` 键到 Cookie 存储）。④ `downloadFileAwait` 本批返回明确不支持（文件 API 后置）。⑤ `@js:`/`<js>` 形式的源 `header` 规则不求值（仅解析静态 JSON header，与 RSS 列表链现状一致，登记后续）。⑥ `run` 在宿主引擎全局作用域执行，`*Await` 不注入宿主（无事件循环），与原版页面作用域不同。
> - **安全边界**：方法白名单（未知方法 `ok:false`）；参数上限 1 MiB、结果上限 4 MiB、单次执行 30s（QuickJS 中断预算）；源变量按 `v_<sourceUrl>_` / `sourceVariable_<sourceUrl>` 前缀隔离，跨源不串读；`__cookieSet` 只接受 `http(s)`/域键并走 ETLD+1 归一（`cookie_store::normalized_cookie_key`），同 `submitWebviewResultWithCookies` 的合并 upsert（先持久化后内存可见），不相关域零触碰。Rust 实现 `legado-ffi/src/api/rss_web_bridge.rs`，引擎复用 `legado_js::engine_cache` 并绑定 `current_source`。
> ℹ️ **批21c/21d/21e 审查加固（2026-10-27，不改方法/计数）**：
> - **脚本自身不写全局（本地加固差异，非隔离承诺）**：`java`/`source`/`cache` 与 `*Await` 只在 Rust 生成的 IIFE 闭包内声明，**不写 `window`**（原版同样只在 `(() => {…})()` 内声明）；Dart bootstrap 捕获平台注入的 `JavaScriptChannel` 对象后尝试 `delete`（Android；iOS 无该全局、`webkit.messageHandlers` 不可删）；页面桥对象 `window[__rs_*]`（批21h 起随机名且**不含 `legado` 前缀**）以 `enumerable:false, configurable:true` 定义并在 Rust 桥头读取后立即删除；回填回调 `window[__rc_*]` 以 `enumerable:false, configurable:true` 定义（批21h 放宽为可删除），桥释放时由 Dart `delete`；nonce 回调 `window[__rk_*]` 使用独立随机名且交付后删除；同文档幂等标记 `window[__rb_*]` 仅在首个 tick 内存在（守卫随后转移到回填回调的非枚举属性 `__lgBridgeInstalled` 并删除窗口属性）。console 钩子与 `shouldOverrideUrlLoading` 桩改用无 `legado` 前缀的固定名（`__rssConsoleHooked`/`__rssConsoleLogs`/`__rssJava`）。
> - **可发现性口径（批21d P0-B，替代「无法枚举发现」表述）**：`enumerable:false` 只保证 `for..in`/`Object.keys` 不可见；`Object.getOwnPropertyNames(window)` **仍可见属性名**，`configurable` 只影响可删除/可重定义、**不防读取**（批21h 起回填回调为 `configurable:true` 以支持释放时删除）。**URL 模式桥能力与原版等价（页面可信假设）**；脚本隔离仅对文章 HTML 模式成立。Android `delete window[addJavascriptInterfaceName]` 是否真正移除、通道在 `Object.getOwnPropertyNames(window)` 中的可见性、iOS `webkit.messageHandlers` 可见性均以「真机结论」段为准。
> - **nonce 不承担安全隔离（登记）**：nonce 仅防误用/重放；页面排队请求上限 20，溢出/10s 未握手按失败回填。
> - **握手代数 + ACK（批21d P1-1）**：每个 nonce 回填携带单调代数令牌；页面 nonce handler 接受**不旧于当前令牌**的 nonce（新 hello 可覆盖在途握手）并回发 `nonceAck`；Dart 仅在 ACK 的令牌与当前 nonce 匹配时置位握手。4s 看门狗在回填在途时只顺延、不重置；ACK 缺失时重发 hello 并可重试。
> - **HTML 模式脚本隔离（本地加固差异，批21e P0 起改用 HTML5 DOM 解析，批21f P0 修复 mXSS）**：启用桥（源 `preloadJs` 非空且 `enableJs`）时，文章 HTML/`startHtml` 先剥离页面脚本再注入应用可信脚本（`startJs`/桥组合脚本）。实现用 `package:html`（HTML5 容忍解析，与浏览器同一树构造）：`parse(html)` 构建 DOM → **整体删除 `<svg>`/`<math>`/`<plaintext>` 子树**（批21f：foreign content 序列化差异是 mXSS 根因；批21g：`<plaintext>` 无结束标签语义，序列化补 `</plaintext>` 后逐轮增长，破坏不动点）→ 删除所有 `script` 元素 → 删除 `srcdoc` 与 `on*` 内联事件（大小写不敏感）→ URL 属性（`href`/`src`/`action`/`formaction`/`xlink:href`/`poster`/`background`/`cite`/`longdesc`/`usemap`/`manifest`/`ping`/`data`）实体解码 + 控制字符剔除后拒绝 `javascript:`/`vbscript:`/`data:text/html`/`data:image/svg+xml`/`data:application/xhtml+xml`（`iframe`/`object`/`embed` 额外拒绝全部 `data:`）→ 删除 `meta http-equiv=refresh` 与 CSP meta（`content-security-policy`/`-report-only`）→ 删除注释节点 → `document.outerHtml` 序列化 → **不动点复检**（对结果重新解析清洗，最多 3 轮，直到连续两轮一致，保证 `strip(strip(x)) == strip(x)`；批21g 删除 `<plaintext>` 后对既有语料成立）。批21f 终审 5 条真实 Chrome 执行向量（`<svg><style>&lt;script&gt;document.title=41` 等，foreign content 内实体编码文本被序列化成字面 `<script>`）修复后均不再执行；`isSanitizedHtmlSafe(html)` 作为测试/运行时断言（parse 后无 `script`/`svg`/`math`/`plaintext`、无 `on*`、无 `srcdoc`、无危险 URL、无 refresh/CSP meta）。批21d 手写词法的三类绕过（`<!-->`/`<!--->`/`--!>` 注释提前终止；`<!x ">`/`<?x ">`/`<!DOCTYPE html ">` 伪注释引号失配；`<div x=a"><script>` 无引号属性含引号）已修复。`<style>/<title>/<textarea>/<noscript>` 按 rawtext/RCDATA 语义保留字面 `<script>`（浏览器不执行）；`<pre>` 内**未转义** `<script>` 是真实元素（浏览器同样执行），仍删除；实体编码 `&lt;script&gt;` 的代码块保留。原版经 `shouldInterceptRequest` 以外部子资源注入桥（桥不在 DOM），Flutter WebView 无该拦截面、只能内联，故以剥离消除页面脚本。非桥模式保持原样。
> - **已登记功能损失/差异（批21d P2-5，批21e 修订为 DOM 口径，批21f P0 补 ⑦，批21g P2-1 补 ⑧）**：① DOM 解析会重排/补全标签（片段补 `<html><head><body>`、自闭合标签与属性引号规范化）并删除注释节点；② 依赖页面脚本/内联事件（`onload`/`onerror` 懒加载等）的图片/视频嵌入失效（可能显示空图/占位）；③ `srcdoc` 内嵌文档被移除；④ 危险 URL 属性整体删除（属性值不保留）；⑤ `iframe`/`object`/`embed` 的 `data:` 文档整体移除；⑥ `<pre>` 内未转义 `<script>` 删除（浏览器同样执行，非额外损失）；⑦ **`<svg>`/`<math>` 子树整体删除**（含 SVG 图片、图标、公式与 foreignObject 内容；安全优先，批21f）；⑧ **`<plaintext>` 子树整体删除**（其内容本会被浏览器当作纯文本吞到文档末尾，删除同时消除序列化/再解析逐轮增长；批21g）。均为安全优先的本地差异，非原版行为。
> - **残余风险（批21f P1/P2-3/P3-6 登记，批21g P3-3 拆分补全）**：① **脚本隔离仅对首份 HTML 文档成立**——HTML 模式只清洗 `loadHtmlString` 的首文档；用户链接/表单/脚本跳转等**非用户手势跨文档导航**会加载新文档，新文档不经过 `rssStripPageScripts`，桥在 `onPageStarted` 重新注入（`preloadJs` 组合脚本）。URL 模式按原版等价「页面可信」假设理解。② **同源 iframe/object/embed 嵌入为残余风险**——清洗只删除 `srcdoc` 与 `data:` 文档，`src`/`data` 指向 `http(s)` 的（同源/跨源）文档仍会完整加载并执行其脚本；脚本隔离不覆盖子框架。③ **文章 `<title>` 提升**——HTML5 解析会把正文中的 `<title>` 提升到 `<head>`（标题欺骗）；阅读页 HTML 模式顶栏固定「文章详情」（不取文档标题），`singleUrlDirect`（URL 模式）顶栏取 WebView 标题（与原版一致），故欺骗仅影响文档内展示或 URL 模式。④ **meta refresh 之外的自动导航**——`<base>`/`<form>`/`window.location` 等页面内自动导航仍可在无用户手势下加载新文档（见 ①）；本批仅删除 `meta http-equiv=refresh`。⑤ **外链 CSS**——`<link rel=stylesheet>` 的 `http(s)` `href` 保留并加载；CSS 不能直接执行脚本，但可经 `url()`/`@import` 发起第三方请求（隐私/网络副作用），并可影响阅读页样式。⑥ **`<base>` URL 重写**——`http(s)` 的 `<base href>` 保留且 HTML5 解析会提升到 `<head>`，改变文档内相对 URL 的解析基址（资源/链接可能指向第三方）；非脚本执行，属资源/导航重定向风险。⑦ **`<frame>/<frameset>`**——清洗不删除 frame/frameset，子框架文档会完整加载并执行其脚本（与 ② 同类的子框架风险）。⑧ **`<form action>`**——危险 scheme 的 `action` 会被删除，但 `http(s)` `action` 保留，用户提交表单可导航到新文档（无用户手势的自动提交需脚本，已由脚本剥离阻断）。⑨ **`<meta charset>`**——未删除；`loadHtmlString` 以 UTF-8 字符串传入，页面若声明其他编码可能显示乱码（非脚本执行风险，后续可评估一并删除）。
> - **同文档 onPageStarted 去重（批21d P1-2）**：阅读页以「当前文档 URL + 文档代数」双条件去重，同文档重复回调不重复执行 preloadJs/重置握手；`onPageFinished` 结束本代窗口（同 URL 的真实重载仍会重新注入）。批21e：`onWebResourceError` 清空去重键，失败后的同 URL 重试必重新注入。
> - **降级与快照（批21d P2-1）**：`__prepare` 在非 quickjs 构建也返回 `snapshot`（`bridgeAvailable:false`、`script` 为空串），Dart Cookie 预写/同步面不依赖 JS 引擎；prepare 失败、`bridgeAvailable:false` 或桥头为空时一律注入**引导式降级桩**（带明确报错的 `java`/`source`/`cache` + 同步面纯函数），不再裸跑 `preloadJs`；只有完全未尝试 prepare 才保持裸 `preloadJs`。
> - **缓存/登录缓存一致性（批21d P2-3）**：`run` 内 `cache` 与页面 `cache` 垫片统一走引擎内置 `cache_store`（此前 setup 覆盖为变量表，两侧分叉）；`loginHeaderSet` 同步写 `variable_store`（与 `loginHeaderRemove` 对称），已存在引擎的 `run` 内 `source.getLoginHeader()` 立即可读新值；`loginHeaderRemove`/`loginInfoRemove` 同步 `variable_store::remove_variable`，setup null seed 亦显式 remove（避免已删除登录头复活）。
> - **资源边界（批21d P2-2，批21e P3-5 修订）**：每源宿主调用并发上限 4，等待许可 10s 超时按 `ok:false` 明确回填；并发信号量表优先淘汰空闲项、**不淘汰在用项**（避免同源新建第二个信号量导致并发上浮失控；表项可临时超过 256 条并留告警），`__store` 限频窗口/UA 记忆表均有 256 条上限（超限淘汰任意非当前源条目，只损失短期状态）。
> - **执行面细节**：`run` 改间接 `(0, eval)`，`var` 声明跨调用持久（原版 evalJS 全局语义，红→绿 `run('var x=1')` → `run('x')==1`）；URL 映射形态 `jsLib` 经 `jslib_loader` 解析后加载（与 `QuickJsExecutor` 的 `run_fresh` 同源）；引擎缓存键改 `rss-webview:<sourceUrl>`（与规则链 5s 默认超时/不同 setup 解耦）；每源宿主调用并发上限 4，`__store` 每秒 300 次、`__action` 每秒 200 次（Dart），`importScriptAwait` 纳入 `concurrentRate` 限流；`RESPONSE_BRIDGE_JS` 二次注入的幂等 guard 分支恢复 `globalThis.connect = java.connect`（批21d P2-4）。
> - **同步面补充**：`source.sourceUrl/sourceName/loginUrl/loginUi/header` 只读属性；`java.randomUUID/timeFormat` 提供可用实现，`java.htmlFormat/s2t/t2s` 为原样返回的简化实现（首次调用写日志，不抛 TypeError）。`connectAwait` 返回 JSON `{statusCode,body,headers,url}`、`headAwait` 返回响应头 JSON（原版 `StrResponse.toString()` 口径不同，登记为本地增强）；`getAwait`/`postAwait`/`headAwait`/`connectAwait` 均透传 `callTimeout`。
> - **批21e 审查修复（2026-10-27，不改方法/计数）**：
>   - **P0 HTML5 DOM 剥离**：`rssStripPageScripts` 由手写词法扫描改为 `package:html` DOM 解析（`parse` → 删除 `script`/`srcdoc`/`on*`/危险 URL 属性/注释 → `outerHtml`），与浏览器同容忍语义；修复批21d 三类绕过（见上方「HTML 模式脚本隔离」）。已知差异见上方「已登记功能损失/差异」。
>   - **P1-1 看门狗边界**：仅当本代文档**实际注入桥**（平台通道注册成功 + 桥头非空 + 本页执行组合脚本）时臂看门狗（`beginNavigation(bridgeInjected:true)`）；未注入源只重置握手状态、不重发 hello。看门狗重试上限 3 次（`kRssWebBridgeMaxWatchdogRetries`），超过后停止并留「停止重试」日志；nonce 回填在途的顺延受 `handshakeTimeout` 总时长上限约束（超限按失败进入重试）；ACK 成功后取消计时器并清零重试计数。
>   - **P2-1 `loginInfoSet` 对称同步变量表**：`__store loginInfoSet` 同步 `variable_store::set_variable("userInfo_<url>", value)`，已存在引擎的 `run` 内 `source.getLoginInfo()` 立即可读；`loginInfoRemove` 清变量表（回环用例 seed→建引擎→set→run 新值→remove→run 读不到）。
>   - **P2-2 随机源**：通道/桥对象/回填回调/nonce 回调/幂等标记名均用 `Random.secure()` 生成（测试注入确定性 Random；不支持平台回落 `Random()`）。
>   - **P2-3 嵌入文档 `data:`**：`iframe`/`object`/`embed` 的 `src`/`data` 拒绝全部 `data:`（内嵌文档可自带脚本），其余元素仅拒绝 `data:text/html`/`data:image/svg+xml`/`data:application/xhtml+xml`。
>   - **P3**：bootstrap 增加同文档幂等标记（`configurable:false`；重复注入直接返回，避免二次 defineProperty/重发 hello 造成死桥）；`onWebResourceError` 清空「URL + 文档代数」去重键（失败重试必重新注入）；看门狗用例改虚拟时钟；补陈旧 ACK/旧代数丢弃用例；并发信号量表裁剪不再淘汰在用项（允许条数临时上浮并告警）。
>   - **P2-4 真机证据（批21e）**：探针脚本 + 原始 JSON + 截图归档于 `docs/materials_remote_webview_bridge_20261027/`（结论见上方「真机结论」段）。
> - **批21f 审查修复（2026-10-27，不改方法/计数）**：
>   - **P0 mXSS 终审闭环**：`rssStripPageScripts` 整体删除 `<svg>`/`<math>`/`<plaintext>` 子树；删除 `meta http-equiv=refresh`/CSP meta；不动点复检（≤3 轮，`strip(strip(x))==strip(x)`）；新增纯函数 `isSanitizedHtmlSafe` 作测试/运行时断言。**真实红→绿仅 41..46 + meta refresh**（`<svg><style>` 实体 / `<svg><xmp>` / `<svg><noscript>`（43）/ `<svg><g><style>` / `<math><annotation-xml><svg><style>` / `<svg><iframe>`（46）/ refresh，修复前 Chrome 实测执行 document.title）；**47-50 修复前 Chrome 已为 SAFE，作为回归向量保留**（CDATA / mglyph / mtext-table-mglyph / `</p>` 提前退出 + `<a id="` 未闭合属性）。默认门禁为 5 条结构化向量 + golden（纯 Dart）；Chrome headless 仅在 `LEGADO_CHROME_HEADLESS=1` 且宿主有 Chrome 时执行，否则用例**显式 skipped**（不是 passed），由 CI 夜间/设备验收执行。实测 before 标题 `41..46`/`REFRESHED` → after 全部 `SAFE`，红→绿证据归档于 `docs/materials_remote_webview_bridge_20261027/mxss/`。1MB/1 万标签含两轮不动点复检典型 80-240ms（debug 断言二次自检 + 机器/并行负载相关，CI 并行争用可更高），测试阈值 800ms（只拦截数量级回归，**不承诺绝对耗时**；批21g P1-1 收敛旧「87ms/<200ms」口径）。
>   - **P1 残余风险**：见上方「残余风险」段（首文档隔离/同源 iframe 嵌入/title 提升/meta refresh 之外的自动导航/外链 CSS/`<base>`/frame/form/meta charset）。
>   - **P2-1 页面级看门狗接线测试**：无 `preloadJs` 不臂、通道注册失败不臂、主框架错误后同 URL 重试重新注入（子资源错误不清空去重键）；批21g 补正例（preloadJs 非空 + 通道注册成功 → 4s 后确实重发 hello）与主框架错误停看门狗用例。
>   - **P2-2 单调时钟**：看门狗在途时长改用注入式 `Duration Function()`（默认进程内 `Stopwatch`），负差值按 0；补时钟回拨用例。
>   - **P2-4 真机复跑**：探针脚本 + 原始 JSON + 运行日志 + 设备信息归档（`probe/probe_result_raw_21f.json`、`probe/probe_run_raw_21f.log`、`device/device_info.txt`）；断言固化 `typeofChannel=object`、`deleteResult=true`、`typeofAfterDelete=undefined`、`capturedStillWorks=true`，加载清洗后 mXSS 页面 `MXSS_TITLE=SAFE`（批21g P3-1：该字段原先只在运行日志中，现单独归档于 `probe/mxss_probe_21f.json`）。
>   - **P3**：`MAX_TRACKED_SOURCES` 注释与「信号量只淘汰空闲项/允许临时上浮」一致；信号量超限告警仅在状态变化时记录一次；bootstrap 幂等标记移到通道删除与桥对象安装之后（安装途中异常可重试）；`loginInfoSet/Remove` 的 DB→变量表非原子顺序已注释登记；测试审计属性集合与实现一致（`poster`/`background`/`cite`/`longdesc`/`usemap`/`manifest`/`ping` 等）；文章 `<title>` 提升登记。
> - **批21g 审查回修（2026-10-27，不改方法/计数）**：
>   - **P1-1 性能用例阈值**：全量 `flutter test` 并行争用下 1MB/1 万标签用例实测 214-238ms（debug assert 额外解析 + JIT/机器差异），旧 `<200ms` 阈值使全量变红；阈值放宽为 800ms（典型 80-240ms，机器/负载相关），只拦截数量级回归，不再保留「87ms」绝对承诺。
>   - **P2-1 `<plaintext>`**：`<plaintext>` 与 `<svg>`/`<math>` 同等整体删除——`package:html` 序列化会补 `</plaintext>`，而 HTML5 解析器不再识别其结束标签（内容吞到 EOF），逐轮解析/序列化不断增长，破坏 `strip(strip(x)) == strip(x)`；删除后对既有语料（含 plaintext 向量）成立。功能损失登记为「已登记功能损失/差异 ⑧」，安全自检同步拒绝 plaintext。
>   - **P2-2 浏览器级门禁**：Chrome headless 用例在未设置 `LEGADO_CHROME_HEADLESS=1` 或宿主无 Chrome 时以 `skip:` **显式 skipped**（此前直接 return 会显示 passed，属假绿）；默认门禁保持 5 条结构化向量 + golden，浏览器级用例供 CI 夜间/设备验收。
>   - **P2-3 看门狗正例**：补「`preloadJs` 非空 + 通道注册成功 → 4s 后确实重发 hello」页面级用例（虚拟时钟），与既有无 `preloadJs`/通道注册失败反例成组。
>   - **P2-4 清洗同步执行（登记）**：`rssStripPageScripts` 目前在 UI isolate 同步执行（首文档在 `loadHtmlString` 前完成），1MB 文章约 0.2-1s 级（debug/机器相关）；本轮**不改 `compute`**——isolate 往返与首帧时序会改变加载顺序，且组件测试依赖同步注入链，风险高于收益；后续可评估后台 isolate 化。
>   - **P3-1 探针证据**：`MXSS_TITLE=SAFE` 原先仅打印在运行日志，现单独归档 `docs/materials_remote_webview_bridge_20261027/probe/mxss_probe_21f.json`（内容与日志一致），本条措辞按该证据收敛。
>   - **P3-2 红→绿范围**：见上方 P0 段——真实红→绿限定 41..46 + refresh；47-50 修复前已 SAFE，标为回归向量。
>   - **P3-3 残余风险拆分**：外链 CSS、`<base>` URL 重写、`<frame>/<frameset>`、`<form action>`、`<meta charset>` 分别登记于「残余风险」⑤-⑨。
>   - **P3-4 安全插入点**：`rssClHtml`/`rssInjectStartJs` 不再用裸 `indexOf` 搜索 `</head>`/`</style>`/`</body>`，改由 `_rssFindTagPositions` 跳过注释与 rawtext/RCDATA（`script`/`style`/`xmp`/`iframe`/`noembed`/`noframes`/`noscript`/`plaintext`/`title`/`textarea`）内的字面标签；仍是字符串插入、**不重新序列化正文**（避免未清洗 HTML 的 DOM 往返 mXSS）。补 `<xmp></body></xmp>`、title/textarea/注释等单测。
>   - **P3-5 主框架错误停看门狗**：`onWebResourceError`（仅主框架）调用 `beginNavigation(bridgeInjected:false)` 取消计时器，避免对已失败文档每 4s 空转重发 hello；同 URL 重试的 `onPageStarted` 会重新臂。
>   - **P3-6 复核**：`MAX_TRACKED_SOURCES` 注释（信号量只淘汰空闲项/允许临时上浮）与超限告警限频（仅状态变化时一次）已在前批落地，本批复核与实现一致，无代码改动。
> - **批21h 设备验收回修（2026-10-27，不改方法/计数）**：
>   - **P1-1 动作通道被同名函数遮蔽（红→绿）**：Dart 同步面 `kRssBridgeSyncShimBody` 内局部声明了两参 `function __lgEmitAction(name, payload)`，与 Rust 桥头同作用域的单参 `function __lgEmitAction(payload)` 同名；函数声明提升使外层包装器 `__lgAction` 解析到局部两参版本，单参调用时 `payload` 为 `undefined` → 再次调用 `__lgAction` → 无限互递归 → `RangeError` 被 `try/catch` 吞掉，动作从不发送。影响 `java.log/toast/longToast/open/searchBook/addBook/showPhoto/openUrl`。修复：局部函数改名 `__lgActionEmit`，`__lgAction(payload)` 只调用桥头单参 `__lgEmitAction(payload)` 一次；新增 Node 实执行用例（每个动作恰好一条 `__action` 消息）与「Node 产出载荷 → `handleMessage` → `onAction`」组件级用例，并加「同步面不得声明 `function __lgEmitAction`」回归守卫。
>   - **P1-2 页面全局命名去 `legado`**：注入 `window` 的名字全部改为无 `legado` 前缀的随机名（`__rs_` 桥对象 / `__rn_` 平台通道 / `__rc_` 回填回调 / `__rk_` nonce 回调 / `__rb_` 幂等标记）；窗口幂等标记 `configurable:true`，首个 tick 后守卫转移到回填回调的非枚举属性 `__lgBridgeInstalled` 并 `delete` 窗口标记；桥 `dispose()` 在页面侧删除回填回调/标记/nonce 回调（Rust 桥头回填回调同步改为 `configurable:true`）。设备口径：`Object.getOwnPropertyNames(window).filter(n => /legado/i.test(n))` 为空。
>   - **P2-1 安全口径精确化（替代「窗口无任何宿主痕迹」类表述）**：① **内联快照仅对源作者脚本可达**——HTML 模式下桥组合脚本（含 `header/loginHeader/sourceVariable/vars/loginInfo` 快照）作为 `<script>` 内联在 `<head>`，其源码文本可被**源作者脚本**（`preloadJs`/`injectJs`）读取；桥模式下文章 HTML 的页面脚本已被 `rssStripPageScripts` 整体剥离，**不可信页面脚本不可达**。② **URL 模式为「页面可信假设、与原版等价」**——组合脚本经 `runJavaScript` 注入、不进入 DOM，但页面本身按可信处理，快照可达性与原版同级。③ **不声称「窗口无任何宿主痕迹」**——桥存活期间 `Object.getOwnPropertyNames(window)` 仍可见回填回调（不可枚举但可发现；`configurable:true`、`writable:false`），桥模式页面脚本已剥离、URL 模式页面可信；nonce 不承担安全边界。
>   - **P2-3 快照拆分（登记，未改代码）**：把 `loginHeader/vars` 从内联 `<script>` 移到 `runJavaScript` 注入的闭包变量，需要「敏感变量先注入、`preloadJs` 后执行」的时序；HTML 模式内联脚本在解析期同步执行，`loadHtmlString` 前无法可靠地用 `runJavaScript` 前置，异步门控 `preloadJs` 又会改变原版同步语义（且 `preloadJs` 依赖 `source.getVariable` 同步可用）。候选方案：宿主侧按需查询（牺牲同步语义）或资源拦截注入（Flutter WebView 无该面）。本批只登记。
> - **真机结论（2026-10-27 批21e/21f 复跑，Android 15 / 192.168.100.62:5555，`webview_flutter` 探针）**：平台注入的 `JavaScriptChannel` 在页面脚本中表现为 `window[channel]`，`typeof === "object"`、`postMessage` 为函数；`Object.getOwnPropertyNames(window)` **可见**，`Object.keys(window)` **也可见**（属性描述符 `enumerable:true, configurable:true, writable:true`）。`delete window[channel]` 返回 `true` 且删除后 `typeof === "undefined"`、`getOwnPropertyNames` 不再包含该名；删除前捕获的对象仍可 `postMessage`（`capturedStillWorks:true`）——**Android 上桥 bootstrap 的「捕获后立即 delete」确有效**（这是桥模式下限制页面枚举通道的主要手段）。因通道在删除前对 `Object.keys` 可见，页面脚本若在 bootstrap 执行前运行即可发现/调用通道；URL 模式必须按「原版等价、页面可信」假设理解。批21f 复跑将上述结论固化为探针断言，并加载 `rssStripPageScripts` 清洗后的终审 mXSS 聚合页面（5 条向量），`document.title` 保持 `SAFE`（任一向量执行会改写为 41..45）。iOS `webkit.messageHandlers` 可见性**待验收**（无 iOS 设备）。原始 JSON/日志/设备信息/截图/探针脚本归档：`docs/materials_remote_webview_bridge_20261027/`。
>
> ℹ️ **RSS 源模型 `enableReadRecord`（2026-10-28 批28，模型契约加法式，零方法/签名变化）**：`RssSource` 新增 `enableReadRecord`（bool，缺键默认 `true`，对齐原版 `RssSource.enableReadRecord: Boolean = true`，DB 列 `INTEGER NOT NULL DEFAULT 1`）。随 `getRssSources` / `addRssSource` / `updateRssSource` / `rssUpdateSource` / `importRssSources` / `exportRssSources` / 备份（`rssSources` 数组）与「原版 zip `rssSources.json` 导入导出」原样往返。**行为口径**：上游运行期已回退为全局开关（`AppConfig.enableReadRecord`，按源开关不生效），故本批**只做字段/DB 往返保真，不实现按源开关行为**，Dart 侧也无对应 UI 开关。**解析宽松口径（批28b 补记）**：为兼容旧备份/第三方 JSON 并避免单条坏源击穿整批 `importRssSources`，反序列化接受 `true/false`、`0/1`、`"true"/"false"/"1"/"0"`；显式 `null` 按语义默认值 `true`（与缺键一致）。**与 Gson 的已知差异**：Gson 对原始类型 `boolean` 的显式 null 会跳过赋值（保留初值 false），本实现选择 `true`，避免开关被 null 反转。

### 2.6 本地书籍操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `importLocalBook(String filePath)` | filePath | `Future<Book>` | 导入本地书籍。**`.cbz` 本地漫画（2026-10-03 批 B 补记）**：`bookType = LOCAL(0x1000) \| IMAGE_BIT(64)`（位域，对齐 Kotlin `BookType` 位语义；`IMAGE_BIT` 常量见 `legado-core` `book_type`，**勿与 BookSourceType 数值域的 `IMAGE=2` 混淆**）；其余本地格式（txt/epub/mobi/azw/azw3/pdf/umd）仍为 `LOCAL` 无媒体位；`origin=loc_book`、`book_url` 存传入标识（相对标识语义不变） |
| `scanLocalBooks(String dirPath)` | dirPath | `Future<List<Map<String, dynamic>>>` | 扫描本地书籍，返回 `{path, name, size, lastModified}` |
| `detectFormat(String filePath)` | filePath | `Future<String>` | 检测书籍文件格式 |
| `parseMetadata(String filePath)` | filePath | `Future<String>` | 解析书籍元数据（返回 JSON） |

> ℹ️ **本地书白名单与 CBZ 懒加载链路（2026-10-03 批 B）**：`reader::is_local_book` 后缀白名单 = `.epub / .txt / .text / .mobi / .azw / .azw3 / .pdf / .cbz`（本次新增 `.cbz`）；`.zip` **不在**白名单（保持压缩容器语义，走 §2.34 导入路径，行为不变）。`.cbz` 命中白名单后：`getChapters` 首次调用懒解析（`LocalBook` → `CbzFile`，整包 1 章、章节 `url` 置空）并入库（含 B-13b 派生字段同步）；`getChapterContent` 返回 `cbz://<条目名>` 行列表（自然排序、仅图片条目）；图片字节经 §2.34 `cbzReadPage` 按条目读取。

### 2.7 书签操作（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookmarks(String bookName)` | bookName | `Future<List<Bookmark>>` | 获取某本书的所有书签（仅按书名查询；同名书会混入，兼容保留，推荐用 `getBookmarksByBook`） |
| `getBookmarksByBook(String bookName, String bookAuthor)` | bookName, bookAuthor | `Future<List<Bookmark>>` | 按书名+作者获取某本书的所有书签（对齐原版 `bookmarkDao.getByBook(name, author)`，规避同名书混入）；返回书签列表（遵守 §1.4 裸数组铁律）。既有 `getBookmarks` 签名保持不变，本方法为加法式新增。方案说明：不采用给 `getBookmarks` 追加可选参数方案，避免触碰既有冻结签名；新增独立方法对既有调用方零破坏（台账 §5.14-2，第三批后置项，Task #63，加法式新增） |
| `getAllBookmarks()` | 无 | `Future<List<Bookmark>>` | 获取所有书签 |
| `addBookmark(Bookmark bookmark)` | bookmark: Bookmark 对象 | `Future<Bookmark>` | 添加书签 |
| `updateBookmark(Bookmark bookmark)` | bookmark: Bookmark 对象 | `Future<void>` | 更新书签 |
| `deleteBookmark(int id)` | id | `Future<void>` | 删除书签 |
| `searchBookmarks(String keyword)` | keyword | `Future<List<Bookmark>>` | 搜索书签 |

### 2.8 替换规则操作（9 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getReplaceRules()` | 无 | `Future<List<ReplaceRule>>` | 获取所有替换规则 |
| `getEnabledReplaceRules()` | 无 | `Future<List<ReplaceRule>>` | 获取启用的替换规则 |
| `addReplaceRule(ReplaceRule rule)` | rule: ReplaceRule 对象 | `Future<ReplaceRule>` | 添加替换规则。**2026-09-11 加法式扩参（A3 写链路补齐）**：FFI `replaceRuleAdd` 新增可选参 `group` / `scopeTitle` / `scopeContent` / `excludeScope` / `timeoutMillisecond`（缺省=旧行为：group=null、scopeTitle=false、scopeContent=true、excludeScope=null、timeoutMillisecond=3000）；**2026-09-13 再新增末尾可选参 `scopeSource: Option<bool>`（add 缺省=false 对齐原版独立列默认值）**；**2026-11-10 批12：`sortOrder` 改为 `max(sortOrder)+1` 追加末尾（原硬编码 0，重排后会顶到最前）**；BookApi 签名不变（仍传 ReplaceRule 对象，UI 层零改动） |
| `updateReplaceRule(ReplaceRule rule)` | rule: ReplaceRule 对象 | `Future<void>` | 更新替换规则。**2026-09-11 加法式扩参（A3 写链路补齐）**：FFI `replaceRuleUpdate` 新增可选参 `group` / `scopeTitle` / `scopeContent` / `excludeScope` / `timeoutMillisecond`（未提供=保留既有值；提供空串=清除该字段）；`isEnabled` 维持既有参。**2026-09-13 再新增末尾可选参 `scopeSource: Option<bool>`（未提供=保留既有值）**。**2026-11-10 批12 再新增末尾可选参 `scope: Option<String>`（未提供=保留既有值；提供空串=清除，修复「特定范围编辑不落库」）**。BookApi 签名不变 |
| `deleteReplaceRule(int id)` | id | `Future<void>` | 删除替换规则 |
| `setReplaceRuleEnabled(int id, bool enabled)` | id, enabled | `Future<void>` | 启用/禁用替换规则 |
| `applyReplaceRulesToSource(String sourceJson, String sourceName, String sourceUrl)` | sourceJson: 单个书源对象 JSON 字符串；sourceName / sourceUrl: 该源 `bookSourceName` / `bookSourceUrl`（scope 匹配依据） | `Future<String>` | **2026-09-13 加法式新增（书源导入时替换，对齐原版 `ReplaceRuleDao.findEnabledBySourceScope` + `BookSourceImport` 逐源判定）**：仅取 `isEnabled && scopeSource && pattern 非空` 的启用规则，`scope`/`excludeScope` 按「源名称或 URL」contains（忽略大小写）匹配——独立源上下文（**不复用标题/正文的 ScopeContext，语义红线：source 上下文的 scope 匹配对象是源名/源 URL，不是书名/书籍来源**）；正则带逐规则超时、`@js:` 复用正文管线、非正则按字面量替换；**未命中=原样返回原文，任何规则级错误（编译失败/超时/@js: 异常/DB 未就绪）不上抛 FFI、保留原文不阻断导入**。Dart 侧由 `SourceImportService.importFromJson` 统一入口对数组逐项调用（逐项而非整数组，因 scope 匹配按单源） |
| `reorderReplaceRules(List<int> ids)` | ids: 全量规则 id 顺序（Dart 序列化为 JSON 数组经 FFI `idsJson` 传输） | `Future<int>` | **2026-11-10 批12 加法式新增**：按给定 ID 顺序**全量**重编号 `replace_rules.sortOrder = 0..n-1`（单事务），返回重排条数；重复/缺失/未知 ID 一律参数错误且零写入（防筛选态子集重排打乱隐藏规则）；对齐 `dictRuleReorder` 语义（Rust `ffi::replace_rule_reorder`） |
| `previewReplaceRule(String ruleJson, String sampleContent)` | ruleJson: 单条 `ReplaceRule` 模型 JSON（camelCase 字段，Dart 侧 `ReplaceRule.toJson()` 产物）；sampleContent: 预览输入文本 | `Future<String>` | **2026-09-13 加法式新增（替换规则编辑器预览，`@js:` 补齐）**：对单条规则在示例文本上执行真实替换管线（正则编译 regex 优先 / fancy-regex 回退、`@js:` 走 QuickJS 执行器、逐规则超时保护）；成功=返回替换后文本；规则级错误（非法正则 / `@js:` JS 异常 / 执行超时）=返回 `⚠️ ` 前缀错误文本（可直接展示于预览区，不上抛异常）；非法输入（JSON 解析失败）MAY Err。编辑器预览改由本方法单一语义源承接（原 Dart 侧纯 Dart 近似分支删除，`@js:` 不再降级为「不可用」提示）。**2026-11-10 批15 回修登记**：预览无书籍/章节上下文，`chapter`/`book` 以空对象绑定（字段为空串/0，而非 `undefined`）；正文净化生产路径绑定真实 `chapter`（title/index/url/bookUrl）与 `book`（name/author/bookUrl），两处共用同一执行器与绑定构造点。差异口径：引用 `chapter`/`book` 的规则在预览中看到空值，实际阅读时看到真实值；以 `result` 为主的规则预览与生产输出一致 |

> **[批20-B | 2026-11-12] Web 与 App 正文净化语义已统一（统一到 App 侧，零方法数变化）**：两轨共用 `legado-js::replace_rule_js` 执行器与绑定构造；Web 服务与 App 打开同一 SQLite 文件，正文净化直接读取同一套配置（不依赖 SharedPreferences，无需同步落库）。
> - **配置面**：两端均读取章级 `caches:sameTitleRemoved:{bookUrl}:{index}`、`config:chineseConverterType`、`books.readConfig.reSegment` 与 `config:replaceEnableDefault`（缺省值依次为：去除重复标题 / 0 不转换 / false / true）；配置读取失败回退默认值并记录告警，不阻断正文。
> - **作用域面**：正文 `scope` 统一为 App 语义——按 `[,;，；]` 拆分后与书名精确匹配，不看 `origin`、不处理 `excludeScope`（实现下沉 `legado_core::content_processor::book_scope_matches`，两端共用）；标题路径仍保留原 DAO 子串匹配 + `excludeScope`。
>
> 因此**去重标题开关、简繁转换、重新分段、替换总开关及正文 `scope` 判定**在默认与非默认配置下两端一致。回归用例：`legado-ffi/tests/replace_rule_js_web_parity.rs`（默认配置逐字相等 + 简繁/替换总开关/scope/excludeScope/章级去重/reSegment parity）。
>
> **仍存在的既有差异（批20-B 未统一）**：Web `purify_content_blocking` 向 `ContentProcessor` 传 `ScopeContext::new(book.name, book.origin)`，而 App `process_content_with_rules_inner_ctx` 未注入 `ScopeContext`；`remove_duplicate_title` 用 `scope_context.book_name` 作为章节标题前的可选书名前缀，故正文首行恰为「书名 + 章节标题」时 Web 会额外去掉该行、App 不会。
>
> **并发保护与耗尽风险（批17 三审登记）**：`/getBookContent` 无鉴权。正文净化经 `spawn_blocking` 执行；**仅 FFI 内嵌 `server_start` 创建的 runtime** 设 `max_blocking_threads(8)`（独立 `start_server` 使用调用方 runtime，无此上限，需自行配置）。含 `@js:` 的净化另有进程级信号量上限 **4**：`try_acquire` 非阻塞，超限时**仍执行完整净化管线**（去重标题/普通规则照常生效），只禁用 `@js:` 执行器、其匹配保留原文（与 no-quickjs 语义一致）。Web 端口 `/mcp/call` 的 `eval_js` 可执行任意 JS（timeout 5..600s），会把共享 blocking 池（8 槽）占满、导致净化排队；该路由已纳入写源令牌守卫（生产入口 `attach_source_write_token_guard`），未配置/未携带令牌一律拒绝；独立 MCP 端口沿用自身 token 中间件。剩余风险：持有令牌的客户端仍可占满 8 槽，需通过限流另行收敛。

### 2.9 阅读器操作（12 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getChapters(String bookUrl)` | bookUrl | `Future<List<BookChapter>>` | 获取章节列表 ⚠️ 双兼容点 |
| `getChapterContent(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取章节正文内容 |
| `getChapterContentRaw(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取章节正文（不应用替换规则，用于内容搜索，与 Android replaceEnabled=false 对齐） |
| `getChapterContentFull(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 一次调用获取章节正文（合并 getChapterContent + fetchChapterContent，在线书籍自动网络抓取，始终返回纯正文） |
| `fetchChapterContent(String bookUrl, String chapterUrl, String sourceUrl)` | bookUrl, chapterUrl, sourceUrl | `Future<String>` | 从网络获取章节正文 |
| `updateReadingProgress({required String bookUrl, required int chapterIndex, required int chapterPos})` | bookUrl, chapterIndex, chapterPos | `Future<void>` | 更新阅读进度 |
| `refreshToc(String bookUrl, String sourceUrl)` | bookUrl, sourceUrl | `Future<List<BookChapter>>` | 从网络刷新书籍目录 ⚠️ 双兼容点 |
| `setChineseConvertType(int type)` | type | `Future<void>` | 设置阅读器繁简转换类型并持久化（0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t，对齐 Android `AppConfig.chineseConverterType`，非法值归一为 0） |
| `getChineseConvertType()` | 无 | `Future<int>` | 获取当前繁简转换类型（0/1/2） |
| `toggleSameTitleRemoved(String bookUrl, int chapterIndex, bool enable)` | bookUrl: 书籍 URL；chapterIndex: 章节序号（0 起）；enable: true=去除重复标题 / false=保留原始标题 | `Future<void>` | 章级「删除重复标题」开关，覆盖全局默认（全局默认仍为去除）；状态须持久化（建议 DB，重启后保持）；接线后正文读取按章应用该开关。错误码：Db（章节不存在）/ Internal（书籍不存在）。语义对齐原版章级 opt-out 方向（台账 §5.11-7 删除重复标题正文链路，Task #50，加法式新增） |
| `getSameTitleRemoved(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<bool>` | 权威查询章级开关（caches KV `sameTitleRemoved:{bookUrl}:{chapterIndex}`）；true=去除（默认），false=opt-out。UI 菜单勾选态须以此为准，避免仅 SP 镜像分叉（2026-08-13 加法式新增） |
| `canRemoveSameTitle(String chapterTitle, String rawContent)` | chapterTitle, rawContent | `Future<bool>` | 试算正文 trim 后是否以标题开头（对齐原版「未找到可移除的重复标题」提示条件；2026-08-13 加法式新增） |

> ⚠️ `getChapters` / `refreshToc`：Rust 返回 `ChapterListResponse { total, chapters[], used_custom_rule }`，Dart 侧提取 `chapters` 字段。
>
> [批1b-3 | 2026-10-31] **`getChapters` 本地 TXT 无目录规则行为补充（长度分章）**：当「无显式规则（`books.tocUrl` 空）或显式规则未命中/不可编译而回退」且**内置默认正则零命中**时，不再整文件单章「全文」，改为按设置项 `maxLengthWithNoToc`（caches `config:` 前缀，默认 **3000**，夹逼 **3000..100000**，非法/越界回落默认）分章。切分语义逐条对齐参考版 `TextFile.kt` `analyze()`（L358-464）：超出上限处之后的最近换行优先作终止点（无换行硬切）、标题 `第{block}章({pos})`、尾段 ≤100 字节（原始字节比较，不做编码换算）并入上一章、字节粒度按编码换算（UTF-8 3 / GB* 2 / UTF-16 2 / 其余 1 字节每字，`maxLengthWithNoTocBytes` L464-476）。长度分章时 `used_custom_rule` 恒为 false；自定义规则命中 / 非 TXT / 在线书 / 目录缓存命中路径不受影响。改配置不自动失效已入库目录（用户经目录页溢出菜单「重新解析目录」——对齐参考版 `TocViewModel.updateToc` 本地分支——或 TXT 规则弹层/重导入触发重解析）。**已登记差异（P3-1）**：参考版按 512KB 缓冲分块读取，>512KB 连续无换行文件会跨缓冲切出多章；我方整文件单缓冲处理，此类文件（极罕见）单章吞下全文。**登记（P3-2/P3-3）**：编码误判测试弱化与 caches config 备份往返缺口见更新记录批1b-3 条目。
>
> [批43b P2-1] `used_custom_rule` 仅在**本地 TXT 懒解析**时有效：true = `books.tocUrl` 的显式规则命中并用于分章；false = 未配置规则或规则不可用/未命中而回退内置默认（目录缓存命中、在线书、其它本地格式恒为 false，表示「未解析」）。BookApi 新增只读别名 `getChaptersWithMeta`（→ 同一 `reader_get_chapters`，§1.7 登记）返回 `(chapters, usedCustomRule)`；`getChapters` 行为不变。UI 仅在「选了具体规则且 false」时提示「规则未命中，已回退默认规则」，恢复默认时 false 属预期。
>
> 繁简转换（Task #100）：配置键 `chineseConverterType`（caches 表 `config:` 前缀，与 Kotlin PreferKey 同名）。正文在净化管线按配置做 t2s/s2t；章节标题在 getChapters/refreshToc 返回前做显示层转换（对齐 Kotlin `BookChapter.getDisplayTitle`，不回写 DB）；内容搜索 raw 路径保持原文。

### 2.10 配置操作（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getConfig(String key)` | key | `Future<String?>` | 获取配置值 |
| `setConfig(String key, String value)` | key, value | `Future<void>` | 设置配置值 |
| `deleteConfig(String key)` | key | `Future<void>` | 删除配置 |
| `getAllConfigs()` | 无 | `Future<Map<String, String>>` | 获取所有配置 |
| `setHttpLogRecording(bool enabled)` | enabled | `Future<bool>` | **新增（2026-10-26 批11，加法式）**：HTTP 请求日志采集开关，对齐原版 `HttpLogController.setRecording`——Rust 侧落库 caches `config:recordHttpLog` 并立即切换 `legado-net` 统一请求出口的采集开关；返回生效值（落库失败抛错且运行期状态不变）。App 侧请求与 Web 端 `/getHttpLogs` 共享同一进程级 ring（对齐原版 App/Web 共享 `HttpLogStore` 单例）；启动时 FFI `db_open` 按该键回填（缺省关闭）。Dart 「其他设置 → 记录 HTTP 请求」开关经本方法同步（保留 SharedPreferences 写入兼容旧版本，首次读到 Rust 空值时用 prefs 值迁移一次）。 |

> **批9b-4 补充（2026-10-31，零签名变化）**：`setConfig("userAgent", v)` / `deleteConfig("userAgent")`（后者等价写空串）除 caches 落库外，同步更新 `legado-net` 进程级默认 UA 覆盖——非空值即时成为所有未显式设置 `User-Agent` 请求的默认；空/纯空白清除覆盖并回落内置默认。`db_open` 读回 `config:userAgent` 回填覆盖。`getConfig("userAgent")` 返回 Rust 侧运行期真源值（空串=未设置/默认）。优先级与覆盖范围见 2026-10-31 批9b-4 更新记录；设置页 SharedPreferences 仍为 UI 镜像真源，启动与保存时同步到 Rust。

> **批9b-2 补充（2026-10-31，零签名变化）**：`config:threadCount` 为「更新和搜索线程数」的 Rust 运行期真源（Dart SharedPreferences 为 UI 镜像）。Rust 在**每次搜索/下载任务入口**读取该键并解析：缺失/空串/非整数 → 回落缺省 **16**；数值越界 → 夹逼（`<1` → 1，超出 i64 的纯数字正数 → 上限）。搜索并发缺省 16、有效上限 **32**；批量离线下载有效并发夹逼 **1..=8**（缺省 16 → 8）且**进程级同时只准入 1 本书**。保存后无需重启，下一次搜索/下载任务即按新值执行；进行中的任务/搜索不热更新（与原版配置在任务启动时取值一致）。详见 2026-10-31 批9b-2 更新记录与 §2.43.3/§2.43.7。

### 2.11 备份操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `backup(String dirPath)` | dirPath | `Future<String>` | 备份数据，返回备份文件路径。**P2-4（2026-08-13）**：Flutter 在 FFI 写出 JSON 后注入 `appPrefs`（当前 SharedPreferences 快照；备份侧按 backupIgnore + alwaysIgnore 过滤，恢复侧仍按 restoreIgnore）；无新 FFI 签名。**批17c P2-3**：`appPrefs` 另排除 `sync_webdav_password`（设备级秘密）。**批18a（2026-10-27）**：`remote_servers` 旧偏好**整键不导出**（服务器列表由 `servers` 段承载；仅备份侧排除，旧备份恢复仍读取，见 §2.28「远程书库服务器列表（批18a 已迁移）」） |
| `restore(String backupPath, {String? password})` | backupPath；password（**批17a 新增，可选**）：原版 zip 备份密码 | `Future<void>` | 恢复数据。**P2-4（2026-08-13）**：UI 先读 `SettingsService.restoreIgnore`；`localBook` 预过滤备份 JSON 本地书；其余 ignore 键在应用备份内 `appPrefs` 时经 `RestoreIgnorePrefs.keyIsNotIgnore` 跳过（对齐 BackupConfig）；再调用本方法恢复业务表。**批17a（2026-10-26）**：新增可选 `password`（Rust `ffi::backup_restore(path, password: Option<String>)`）——仅对原版 zip 备份生效；`null`/空串等价空密码，**旧调用不传时行为不变**；我方单文件 JSON 备份忽略该参数（见下方批17a 补记） |
| `backupInspect(String backupPath)` | backupPath | `Future<String>`（JSON） | **新增（2026-10-26 批17a，加法式，契约先行）**：只读探测备份是否需要备份密码（Rust `ffi::backup_inspect`，实现 `legado-ffi/src/api/backup_api.rs::backup_inspect`）。返回 `{"format":"zip"\|"json","passwordRequired":bool,"passwordProtectedFiles":[string]}`：`format` 按文件魔数判定；`passwordRequired` = `passwordProtectedFiles` 非空；`passwordProtectedFiles` 按 `servers.json`/`cookies.json`/`runtimeSourceCache.json` 固定顺序列出「用空密码解不开」的条目。**只读**：zip 仅解压上述三个候选条目（复用路径安全校验与解压限额，不全量解压），不写任何表；非 zip 且首字符 `{` → `{"format":"json","passwordRequired":false,"passwordProtectedFiles":[]}`；其余格式 → 明确错误「不支持的备份格式」。判定细则：条目缺失 → 忽略；**空/纯空白条目 → 视为损坏（不要求密码，批17c P3-3：空内容不可能被任何密码解开，判「需密码」会让 UI 弹永远失败的密码框）**；明文 JSON 数组 → 无需密码；以 `{`/`[` 开头但解析不成数组 → 视为损坏（不要求密码）；其余（密文）用空密码试解 + JSON 数组解析，失败则计入 `passwordProtectedFiles`。**Dart 封装批17b 已落地**：`BookApi.backupInspect` 返回强类型 `BackupInspectInfo`（`lib/src/models/backup_inspect_info.dart`），JSON 解析在数据层完成，UI 不解析 |
| `importOldData(String dirPath)` | dirPath：含旧版备份文件的目录 | `Future<String>`（统计 JSON） | **P2-4（2026-08-13）**：对齐原版 `ImportOldData.importUri`。读取目录下 `myBookShelf.json` / `myBookSource.json` / `myBookReplaceRule.json`（缺文件不致命，计入 `messages`）；书架字段映射（`noteUrl`→`bookUrl`、`bookInfoBean.*` 等）；书源经 `toNewRule`/`toNewUrl`/`toNewUrls`/`uaToHeader` 迁到 3.x 规则结构；替换规则兼容新格式或旧字段（`regex`/`replaceSummary`/`useTo`/`enable`/`serialNumber`）。已存在 `bookUrl` 的书跳过。返回 JSON：`{books, bookSources, replaceRules, messages: string[]}` |

> **备份密码恢复（2026-10-26 批17a，用户裁决：探测 + 密码框；不含加密创建）**：`restore(path, {password})` 的密码仅对**原版 zip 备份**生效，`null`/空串等价空密码；我方单文件 JSON 备份忽略该参数（其 `appPrefs` 过滤语义不变）。**算法（逐行对齐原版）**：密钥 = `MD5(password)` 小写十六进制串的**前 16 个 ASCII 字符**（`BackupAES.kt:6-8` + `MD5Utils.md5Encode`，**不做 hex 解码**；空密码固定密钥 `d41d8cd98f00b204`；密码不 trim），算法 AES-128-ECB/PKCS5Padding，Base64 standard。**加密文件集合**：`servers.json`（原版**恒加密**，空密码也用固定密钥，失败才回退明文）、`cookies.json` / `runtimeSourceCache.json`（仅设置备份密码时写出，内容恒为密文）、`config.xml` 的 `webDavPassword`（本实现仍跳过整份偏好快照，登记为未决）；其余数据文件与 `directLinkUploadRule.json` 为明文。**恢复前置校验（事务前，校验失败库内零残留）**：① 未提供密码且 `cookies.json`/`runtimeSourceCache.json` 为密文 → `BACKUP_PASSWORD_REQUIRED: ...`；② 提供密码时对三个候选逐个「解密 + 解析」，全部解密失败 → `BACKUP_PASSWORD_INVALID: ...`；部分成功 → 密码正确，失败条目按类别 warn 跳过（`servers.json` 解析失败只 warn，对齐原版 `runCatching`），`cookies.json`/`runtimeSourceCache.json` 解密成功但解析失败 → `BACKUP_ENCRYPTED_CONTENT_CORRUPT: ...`。**错误码形态**：后端以 `LegadoError::Internal` 返回文本（Display 形如 `Internal error: BACKUP_PASSWORD_REQUIRED: ...`），Dart 按消息中是否包含前缀 `BACKUP_PASSWORD_REQUIRED:` / `BACKUP_PASSWORD_INVALID:` / `BACKUP_ENCRYPTED_CONTENT_CORRUPT:` 识别（**不得**按字符串起始位置判断）。**内容恢复**：`cookies.json` = `[{url, cookie}]`，`url` 含 `|` 原样 upsert（原版 `cookieDao.insert` 语义），否则按 `get_sub_domain` 归一并与库内同名域 Cookie **同名键合并**（新值胜）后 upsert（对齐 `CookieStore.restoreCookie`）；`runtimeSourceCache.json` = `[{key, value, deadline}]`，仅接受 `v_`/`userInfo_`/`loginHeader_`/`sourceVariable_`/`infoMap_` 五前缀（对齐 `Restore.isRuntimeSourceCacheKey`），`deadline > 0 && deadline <= now` 跳过（过期不写），精确 deadline 落库（`CacheRepository::put_with_deadline`），写完后调用 `legado_js::host_api::variable_store::clear_source_variables()` 让内存运行时变量重载（对齐 `AppCacheManager.clearSourceVariables`）。**兼容策略**：旧入口 `backup_restore(path)` 包装为无密码调用；C bridge 保留 `ffi_backup_restore`（无密码），新增 `ffi_backup_restore_with_password` 与 `ffi_backup_inspect`；我方 **不自动复用本机 `localPassword`**（避免语义耦合，密码由 Dart 密码框输入）。**本批不做**：备份**创建**侧加密（`backup_create` 仍写明文 JSON，另行立项）。
>
> **备份密码 UI（2026-10-26 批17b；批17c 回修）**：Flutter 本地恢复（长按「恢复」）**按容器判定**调用 `backupInspect`——扩展名 `.zip` 或**文件魔数**为 `PK\x03\x04`/`PK\x05\x06`（`.json` 命名的加密 zip 同样处理，批17c P3-5；口径与 Rust `is_zip_backup` 一致）；`passwordRequired=false` 直接 `restore(path)`（password 传 null）；`true` 时弹「输入备份密码」对话框（列出受保护文件中文标签，默认隐藏可切换显示，不预填、不复用本机 `localPassword`）。**空/纯空白提交在对话框内拦截**（内联「请输入备份密码」，不调用 restore，批17c P2-2——后端把空串当「未提供密码」，仅 servers 加密的包会静默丢服务器配置）；密码原文不 trim（仅判空）。取消密码框=中止且零写入。恢复错误按消息「包含」前缀识别：`BACKUP_PASSWORD_INVALID` → 进度框关闭后重开密码框、内联「密码错误或备份已损坏，请重试」并保留上次输入；`BACKUP_PASSWORD_REQUIRED` → 防御性重开密码框；`BACKUP_ENCRYPTED_CONTENT_CORRUPT` → 提示备份文件损坏并结束；其余走统一错误文案。进度框为**三态**结果（已执行/忙/异常，批17c P3-6）：忙（另一操作进行中）时不得提示成功也不得继续后续步骤。密码只在调用栈与对话框 controller 中存在，不写日志/不落盘/不进 prefs；JSON 容器不探测、不弹框，zip 容器不做 JSON 偏好/账号回读。
>
> **批17c 回修补记（2026-10-26，零 FFI 签名变化）**：
> - **Cookie 恢复时机与内存同步（P2-1）**：Cookie 写入移到**主事务提交后**（`apply_restored_cookies`），在同一 `COOKIE_PERSIST_RW_LOCK` 保护域内完成「读现有行 → 按键合并（备份胜）→ upsert → 读回最终行 → 覆盖式写回 FFI 共享内存 CookieStore + `legado-js` 内存 CookieStore」，随后 `reset_shared_client()`（quickjs 档 `reset_shared_client_pools()`）重建客户端。理由：旧实现只写 DB，而客户端重建的合并预载是「内存值胜」，备份 Cookie 要重启才生效；同锁也关闭「读到旧行 → 覆盖落库」的丢更新窗口（原 P3-5）。**失败语义（批17d 补记）**：Cookie 阶段在**主事务提交后**执行，条目级/整段失败**不回滚主事务、不改变 `restore` 的返回值**（`stats` 照常返回），仅 `log::warn!`（整段失败文案「恢复 Cookie 写入失败（本次未生效）」）——与其他表的条目级容错口径一致；用户侧无提示（`stats.warnings` 破坏性扩展另立项）。锁序：C（合并写串行锁）→ P（连接池）/S（共享内存 store）/G（JS 内存 store）；**不在 C 内取按域写通道 D**（JS/jar 写侧是 D→C，避免 ABBA；批17d 起恢复侧在进 C **之前**取 D，收敛为 D→C→P→S/G）。回原先红态用例：`test_restore_zip_cookies_take_effect_in_process_memory`。
> - **Cookie 恢复的并发捕获窗口（批17d P2，锁序 D→C→P→S/G）**：jar 写回（`legado-net::client::save_cookies_from_response`）持 D 写内存并捕获整域串后**释放 S**、再持 D 取 C 落库；旧实现恢复侧只取 C，会在 jar「已捕获、未落库」的窗口读库（看不到新值）→ 合并结果覆盖内存后 jar 以旧视图「incoming 胜」落库，**回滚刚恢复的备份值**且内存/DB 分叉、jar 新键在内存丢失。修复：恢复侧按受影响域键（库内域键 ∪ 全部 JS 内存键）排序去重后**先取 D**（默认档另取 `lock_local_domain_writes`）再取 C，在该保护域内完成「读-合并-写-回读-覆盖内存」，释放 D/C 后再 `reset_shared_client`；与 jar（D→C、D→S）和 JS 写侧（D→C、D→G）同序无环。同域同键冲突按**后写胜**（D 串行后后完成者在最新行上合并）：jar 先行 → 备份值胜；恢复先行 → 真实后到的 Set-Cookie 胜。回归用例：`test_restore_cookies_concurrent_jar_write_no_rollback`。
> - **同域多 URL 的 JS 键覆盖（批17d P3-3）**：默认（无 quickjs）档 `legado-js` 键空间是「trim 原始 URL 串」，同域不同 URL = 不同键；恢复按域收集**全部** JS 键并逐键覆盖同一份最终合并串（旧实现按库内域键去重只记首个键，其余 URL 的内存条目保持旧值、重启前读侧仍命中旧串）。quickjs 档两 URL 归一为同一 ETLD+1 键，收敛为一次写。回归用例：`test_restore_cookies_covers_every_js_key_of_same_domain`。
> - **Cookie 合并语义对齐上游（P3-2）**：`merge_cookie_values` 逐条对齐 `CookieStore.kt:118-136`——`existing` 为空 → 原样返回 `incoming`；同名键**位置保留、值覆盖**（输出保持**插入序**，删除旧实现按键名排序的本地偏离）；键值各 trim 后**空白值丢弃**、字面量 `"null"` 保留；无 `=` 段跳过。**本地加固（已登记偏离）**：键为空的段丢弃（上游会产出 `=value` 畸形段）。
> - **条目级容错口径（P3-4，`cookies.json`）**：**文件级**结构非法（非 UTF-8、空/纯空白、非 JSON 数组）→ `BACKUP_ENCRYPTED_CONTENT_CORRUPT`（事务前中止、零落库，空文件口径保持）；**条目级**非法（元素非对象、`url` 非字符串或空白、`cookie` 非字符串）→ 只 warn 跳过该条，其余照常恢复（原版整份抛错，本实现收窄为「单条坏数据不阻断整次恢复」）。`url` 含 `|` 原样主键；其余按 `get_sub_domain` 归一后同域合并。
> - **偏好敏感面（P2-3，Flutter 侧）**：`appPrefs` 中 `sync_webdav_password` 加入 `alwaysIgnoreKeys`（整键不进备份、不被恢复覆盖）；`remote_servers`（legacy prefs）**批18a 起整键不导出**（`RestoreIgnorePrefs.backupExcludedKeys`，服务器列表由 `servers` 段承载）；恢复旧备份时仍读取该键，按 `id`（其次 `url`+`username`）从 **servers 表**取回本机密码，备份值携带的 `password` 一律忽略，本机无匹配条目时密码置空（详见 §2.28「远程书库服务器列表（批18a 已迁移）」）。**仍存差异**：Rust 侧 v3 `servers[].config` 内 WebDAV 密码与 `directLinkUploadRule` 仍随明文 JSON 备份落盘（批8 已登记，备份加密另立项）；原版 `config.xml` 的 `webDavPassword` 本实现跳过整份偏好快照。

> **备份 v3 纳入 servers（2026-10-26 批8，方法签名不变）**：`BackupData` 增 `servers` 字段（`BACKUP_VERSION` 2→3），值为 `servers` 表全量实体数组（键 `id`/`name`/`type`/`config`/`sortNumber`，对齐原版 `servers.json` 形态）。恢复器按 `id` REPLACE 写入（原样保留备份主键，含 `id = 0`，不做毫秒重分配）；**旧 v1/v2 备份无该键时按空列表处理、不触碰库内 servers**（对齐原版 `Restore.kt:379-390` 仅在 `servers.json` 存在时 `serverDao.insert` 的语义），此时 WebDAV 账号由 Flutter 恢复流程从备份偏好回填 DB（见 §2.28 servers 段）。`RestoreStats` 返回结构不变（不新增计数，失败明细走 warn 日志）。
>
> **备份 v4 纳入直链上传规则（2026-10-27 批16f，方法签名不变）**：`BackupData` 增 `directLinkUploadRule` 字段（`BACKUP_VERSION` 3→4）。**键名关系**：zip 内文件为短键 `directLinkUploadRule.json`（对齐原版 `DirectLinkUpload.ruleFileName`），我方落库键为 caches 表 `config:directLinkUploadRule`（`config:` 前缀 + Dart `DirectLinkUploadRuleService.configKey = 'directLinkUploadRule'`），两者指向同一份规则。**值形态**：单个 JSON 对象文本，4 字段 camelCase `uploadUrl` / `downloadUrlRule` / `summary` / `compress`；原版 `expiryDate` 不建模、不消费，若备份携带则原样透传保留（恢复时不剥除；内联对象形态因 `serde_json` 未启用 `preserve_order`，允许紧凑化与键重排，但**键不丢、`expiryDate` 不剥除**）。**写入侧**：配置不存在或值为空白 → 省略该键（保持旧备份形状兼容）。**恢复侧字段级容错**：字符串按原文接收；对象/数组内联形态转紧凑文本后判定（数组等非对象值只 warn 跳过）；null/数字/布尔视为无效值、不触碰配置；非法 JSON 只 warn 跳过。**空/空白跳过并保留旧配置是相对上游的本地加固**：上游 `Restore.kt:404-408` 只要文件存在就 `ACache.put`（空文件等价清空，`getRule()` 回落内置默认规则），我方跳过空值并保留库内既有配置，避免备份中的空占位抹掉用户规则。**字段缺失（v1~v3 旧备份）不触碰库内既有配置**（对齐上游仅在该文件存在时写入的语义）。`RestoreStats` 返回结构不变（不新增计数）。
>
> **备份 v5 纳入书备忘与 readRecord 全字段（2026-10-28 批27，方法签名不变）**：`BackupData` 增 `bookMemos` 字段（`BACKUP_VERSION` 4→5），元素形态 `{bookUrl, content, updatedAt}`（对齐原版 `BookMemo` 实体与 `bookMemo.json`），**空表也写空数组**（对齐原版 `Backup.kt` 的 `writeListToJson(memos, "bookMemo.json", writeEmpty = true)`）；写入侧只收集**书架内书籍**的备忘（对齐原版 `bookMemoDao.all()` 的 `inner join books`）。`readRecords` 元素扩为 13 字段：`deviceId`/`bookName`/`author`/`readTime`/`lastRead`/`lastChapterTitle`/`lastChapterIndex`/`lastChapterPos`/`coverUrl`/`resolvedAuthor`/`displayBookName`/`displayAuthor`/`metadataEditedAt`（可空字段原样写 null，不省略键）。**恢复侧**：`bookMemos` 缺键（v1~v4 旧备份）按空数组处理，**不清库内既有备忘**；存在时仅恢复满足「`bookUrl` ∈ `restoredBookUrls`（本次备份 `books` 段中成功解析的书籍 URL 集合）+ 库内存在该书 + `updatedAt` 大于库内值」的条目（对齐原版 `Restore.kt:304-306` 过滤 + `BookMemoDao.restore` 的 `hasBook`/更新者胜）；书内备忘主键 `bookUrl`。原版 zip 分支：`bookMemo.json` 从「无落库面」移入数据映射（`ZIP_DATA_FILES` 21→22），`readRecord.json` 解析全部 13 字段（缺字段按实体默认：`lastChapterIndex=-1`、`lastChapterPos=0`、显示字段空串、`metadataEditedAt=0`）；`readRecordCovers/` 目录、`coverFont.ttf` 封面字体与既有 `covers/`/`bg/` 一样**不落盘**（存在时只 warn 跳过）。**注：媒体不落盘口径已被批41 取代**（`covers/`、`bg/`、`readRecordCovers/`、`coverFont.ttf` 均落盘，见下方批41 补记）。`RestoreStats` 返回结构不变（不新增计数）。
>
> **安全口径差异（2026-10-26 批8 审查回修 P2-3 登记）**：原版备份为 zip 包，`webDavPassword` 与 `servers.json` 均经 AES 加密后落盘；我方单文件 JSON 备份**不加密**（既有口径，非本批引入），且本批 v3 把 WebDAV 账号密码以明文写入 `servers[].config`，敏感面扩大。v4 起直链上传规则（`uploadUrl` 的 options 可能含鉴权信息）同样随明文单文件 JSON 备份落盘；若用户自行把备份文件同步到 WebDAV/网盘，该文件会连同规则原文一并离开本机（WebDAV 同步功能本身只上传书架与书源，不读取备份 JSON），敏感面按同一口径登记，备份加密另行立项，不在本批扩范围。
>
> **原版 zip 备份恢复（2026-10-26 批9，用户裁决⑥；方法签名不变）**：`backup_restore` 按文件魔数分流——`PK\x03\x04`/`PK\x05\x06` 走原版多文件 zip 分支，其余按单文件 JSON（非 zip 且首字符非 `{` → 「不支持的备份格式」）。zip 分支映射原版数据文件：`bookshelf.json`/`bookGroup.json`/`bookmark.json`/`highlight.json`/`highlightRule.json`/`bookSource.json`/`rssSources.json`/`rssStar.json`/`sourceSub.json`/`replaceRule.json`/`txtTocRule.json`/`httpTTS.json`/`keyboardAssists.json`/`dictRule.json`/`autoTask.json`/`readRecord.json`/`searchHistory.json` + `servers.json`（明文数组优先，否则按原版 `BackupAES` 空密码 AES-128-ECB 解密；解密失败 warn 跳过，对齐原版 runCatching）+ `directLinkUploadRule.json`（**原版以明文 GSON 对象写出、未走 `BackupAES`**，直接映射到 caches 配置键 `config:directLinkUploadRule`；明文非对象只 warn 跳过，若具备 Base64 形态再按同一条空密码解密流水线回退（解密失败为独立文案），解不出或仍非对象则跳过、不清库内既有配置）。字段归一对齐原版（`order→sortOrder`、`sourceSub.type→sub_type`/`update→last_update`、`httpTTS` 补 `isEnabled=true` 等）；落库统一复用同一恢复体与事务（无第二套写库）。**恢复语义对齐项**：`readRecord` 的 `deviceId` 归一为空串走「本机较新者胜 + 作者合并」（单设备模型，防同书两行/时长叠加）；`highlightRule`/`keyboardAssists` 改为「备份含该文件且解析成功 → 先清空再写入」（备份缺文件/损坏时不清库，对齐原版 replaceAll/deleteAll 语义）。**加密备份边界**：`cookies.json`/`runtimeSourceCache.json` 为密文（原版设过备份密码）→ 返回明确错误且零落库（**注：此处的「无密码输入面」口径已被批17a 取代**——现由 `backupInspect` 探测 + `restore` 的 `password` 参数 + Dart 密码框处理，见上方批17a 补记与批17c 补记）；明文数组（第三方产物）→ 批17a 起正常恢复。**解压限额（审查 P1 加固）**：按实际解压字节限量（不信任 zip 声明大小，伪造 `uncompressed_size` 无效）——单条目 256 MiB、跨条目累计 512 MiB（超限中止并明确报错）、输入包 512 MiB（`fs::metadata` 前置拦截，JSON/zip 共用）；坏 JSON 条目 warn 跳过，条目解压/CRC 损坏整体报错（对齐原版解压失败）。**未恢复项（登记；其中 `covers/`、`bg/`、`readRecordCovers/`、`coverFont.ttf` 的「不恢复」口径已被批41 取代，见下）**：`persistedCoverUrl` 不恢复（我方无该列）；`readConfig.json`/`shareReadConfig.json`/`themeConfig.json`/`coverRule.json`/`config.xml`/`videoConfig.xml` 配置快照无等价面（warn 跳过）；`bookSource.json` 解析失败不回退旧格式导入（warn 跳过，旧目录导入另有 `import_old_data`）；旧高亮 legacy 样式/归属回填缺失（沿用模型解析）。Flutter 本地恢复选择器放开 `['json','zip']`；zip 备份不支持恢复忽略项过滤（UI 明示提示）。部分恢复对用户不可见（仅日志；`stats.warnings` 破坏性扩展另立项）。
>
> **原版 zip 媒体恢复（2026-10-29 批41，用户批次要求；方法签名/计数不变）**：`readRecordCovers/`、`covers/`、`bg/` 三个目录与封面字体 `coverFont.ttf` 从「只 warn 跳过」改为**按白名单前缀落盘**，对齐原版 `Backup.kt:399-429`（写出）与 `Restore.kt:613-627`、`Restore.kt:487-495`（恢复）。**落点映射**（我方无 `externalFiles` 注入点，媒体根取 DB 父目录——移动端即应用 Documents，桌面端为 `legado.db` 所在目录；可用 env `LEGADO_BACKUP_MEDIA_DIR` 非空覆盖）：`covers/<相对路径>` → `<媒体根>/covers/<相对路径>`（子目录保留）、`bg/<相对路径>` → `<媒体根>/bg/<相对路径>`、`readRecordCovers/<相对路径>` → `<媒体根>/readRecordCovers/<相对路径>`、`coverFont.ttf` → `<媒体根>/font/coverFont.ttf`。**合并语义**：备份内文件覆盖同名旧文件，**不删除**本地既有媒体（对齐 `restoreBackupMediaDirectory` 的暂存/回滚合并）；媒体在数据库事务前落盘，写失败逐条 warn、不回滚数据库、不阻断整体恢复（相对原版 covers/readRecordCovers 失败整次抛错，本实现按批次要求收窄）。**路径安全**：条目名先过既有 `is_safe_zip_entry_name`（拒绝空名/反斜杠/NUL/绝对路径/盘符/`.`/`..`），媒体相对路径再过 `is_safe_media_relative_path`（拒绝空段、`.`/`..`、`:`）；落盘逐段 `symlink_metadata` 拒绝符号链接与非目录中间段，目标为符号链接/目录拒绝，写入前 `canonicalize` 父目录并校验仍在规范化媒体根内。**限额**：单媒体文件实际解压 ≤ 32 MiB（超限 warn 跳过该条），跨条目共用既有 512 MiB 总限额（超限中止）；zip 条目总数 ≤ 50 000（结构异常直接报错）；媒体条目缺失/只有目录条目不报错。**封面 remap**：媒体落盘后按「目标文件存在（本次恢复或本地既有）」把 `bookshelf.json` 的 `customCoverUrl`、`bookGroup.json` 的 `cover`、`readRecord.json` 的 `coverUrl`（`.../covers/<file>` 与 `.../readRecordCovers/<file>`）改写为本地绝对路径；目标不存在置 null（书架回落书源封面）；与上游一致只识别直系子文件，covers 子目录形态不 remap。**JSON 备份边界**：我方单文件 JSON 备份无法内嵌二进制媒体，**不含媒体、不做 base64 膨胀**；`backup_create` 不收集/不写出媒体（无 zip 创建面），媒体只在原版 zip 恢复路径落盘。**未接线/差异登记**：我方 UI 暂无封面缓存、阅读背景图、阅读记录封面、封面字体的消费面（恢复目录为数据保留面）；`bg/` 无条件恢复（zip 恢复不支持「忽略阅读配置」）；封面字体只落盘、不写 `coverFont` 偏好（zip 恢复不恢复偏好快照，我方也无该设置项）。`RestoreStats` 返回结构不变（不新增计数）。
>
> **批41b：媒体恢复审查回修（2026-10-29，零 FFI 签名/计数变化）**：
> ① **P1（红→绿）解压错误路径入账**：`read_zip_entry_limited` 在 `read_to_end` 返回后**先**把已读出的字节 `saturating_add` 进 `total_decoded`、再判定总限额、最后才把读错误转成 `LegadoError`；超限时总限额错误优先于读错误上抛。修复前「合法 deflate 流 + 坏 CRC / 流中途截断」条目解压出的字节完全不入账（媒体分支还会把该错误吞成 warn 继续下一条），可批量绕过 512 MiB 跨条目总限额。红态证据：`test_read_zip_entry_limited_counts_bytes_on_error_path` 在修复前断言 `total>=64` 失败（实际 0，另报普通读错误），修复后通过并报「解压总量超过上限」。
> ② **P2-1 JSON 备份封面口径**：`backup_create` 对 `books[].customCoverUrl` / `bookGroups[].cover` / `readRecords[].coverUrl` 做本机媒体根识别（`covers/`、`readRecordCovers/` 下的绝对路径 → null；canonicalize 与词法归一（分隔符/逐字前缀/ASCII 大小写）双轨判定），不再把 zip 恢复 remap 写入的机器本地路径外带到异机；JSON 恢复侧 `guard_json_backup_covers` 对封面字段做「目标存在才保留，否则 null」（`.../covers/<file>` 与 `.../readRecordCovers/<file>` 按本地媒体根 remap，其他绝对路径目标不存在置 null，网络 URL/相对路径原样）。用例：`test_zip_restore_to_json_backup_drops_local_cover_paths`（zip→JSON→异机恢复后封面为 null）、`test_json_restore_guards_dangling_cover_paths`。
> ③ **P2-2 媒体落盘原子化**：`write_media_file_atomic` 在目标同目录 `create_new` 临时文件 → 写入 flush → `rename` 覆盖；命名带 pid/纳秒/尝试序号，`AlreadyExists` 重试（最多 8 次），失败清理临时文件。Windows 的 `rename` 不覆盖已存在目标 → 先 `remove_file` 再 rename（**两步之间目标短暂缺失，非原子，已登记**）；canonicalize 校验与写入之间的换链窗口仍是尽力而为的纵深防御，不构成并发安全保证。
> ④ **P3 清单**：条目数上限前移为 EOCD 预检 `zip_declared_entry_count`（zip64 `0xFFFF` 与畸形 EOCD 不做判断，解析后 `archive.len()` 仍为权威）；媒体相对路径拒绝控制字符（含 NUL）、Windows 保留设备名（con/nul/aux/prn/com1..9/lpt1..9，任意扩展名形态）与结尾空格/点；`coverFont.ttf` 落盘前 TTF/OTF/TTC 魔数首检（`\x00\x01\x00\x00` / `OTTO` / `true` / `typ1` / `ttcf`），不符只跳过该条；测试注入槽与守卫 Drop 的中毒锁改 `unwrap_or_else(into_inner)`；`canonicalize` 结果只用于包含关系判断，写入/落库路径统一剥离 Windows `\\?\` 逐字前缀。**新增用例**：条目数 EOCD 预检、媒体累计总限额中止（16×33 MiB 压成小包）、合并覆盖且不留临时文件、设备名/结尾点/字体魔数负例、`backup_inspect` 不收集不落盘媒体、NUL/控制字符/冒号守卫。
> ⑤ **登记（P3）**：**DB 事务失败回滚时不撤销已写出的媒体**（媒体与 DB 无事务关系，合并写幂等，重复恢复不累积垃圾）；**remap 判据差异**——本实现「目标文件存在才改写」，上游直接拼本地路径（目标不存在时保留悬空绝对路径），JSON 恢复对非 covers/readRecordCovers 形态的绝对路径也做「存在才保留」（本地加固，上游无对应逻辑）。

### 2.12 阅读记录（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getReadRecords()` | 无 | `Future<List<ReadRecord>>` | 获取所有阅读记录 |
| `putReadRecord(ReadRecord record, {String? bookUrl})` | record: ReadRecord 对象；bookUrl: 可选书籍 URL（批35） | `Future<bool>` | 更新阅读记录；**（热力图每日时长契约，2026-08-29；单位口径 2026-09-11 修复）**写路径同步累加当日 readRecordDaily（增量 = 新 readTime − 旧 readTime，**按整秒差值入账**——readTime 为毫秒、readRecordDaily 为秒，仅增量 > 0 时累加，本地时区 YYYY-MM-DD）。**批35**：`bookUrl` 非空时写前查 `books.disableReadRecord`，为真则整次跳过（不写 readRecord/readRecordDaily）；为空保持旧行为（Rust `ffi::read_record_upsert(..., book_url: Option<String>)`）。**批35b**：返回是否真正写入——Rust 跳过时返回哨兵 `-1`（`read_record_api::READ_RECORD_SKIPPED`），Dart 折算 `false` 供阅读器回滚会话基数 |
| `deleteReadRecord(String bookName)` | bookName | `Future<void>` | 删除阅读记录 |
| `clearReadRecords()` | 无 | `Future<void>` | 清空阅读记录 |
| `recordReadingTime(String bookName, int seconds)` | bookName, seconds | `Future<void>` | 记录阅读时长（对齐原版 ReadRecord，非统计子系统） |
| `readRecordDailyList(int year)` | year：年份 | `Future<List<Map<String, dynamic>>>`（`[{date, seconds}]`，日期升序） | **新增（热力图每日时长契约，2026-08-29，U 侧 UI_MD3_PLAN 登记；单位归一 2026-09-11）**：按年查询每日阅读秒数（readRecordDaily 表：`date TEXT PK` + `durationSeconds INTEGER`）；由 `putReadRecord` 写路径自动累加，UI 轨热力图「每日时长」配色模式数据源。存量毫秒值经 DB v107 迁移归一为秒（见更新记录） |

> **readRecord v113（2026-10-28 批27，零 FFI 签名变化）**：`ReadRecord` 返回/接收 JSON 为 13 字段（`deviceId`/`bookName`/`author`/`readTime`/`lastRead`/`lastChapterTitle`/`lastChapterIndex`/`lastChapterPos`/`coverUrl`/`resolvedAuthor`/`displayBookName`/`displayAuthor`/`metadataEditedAt`），主键为 `(deviceId, bookName, author)`；同名不同作者的记录**分行**存在，`getReadRecords` 按 `readTime` 降序返回全部行。Dart 侧按「`displayBookName`/`displayAuthor`（为空回退物理 `bookName`/`author`）」分组聚合（`readTime` 求和、`lastRead` 取最大），同名不同作者不再互相覆盖时长。`putReadRecord` 仍只写 `bookName/readTime`（FFI 既有签名）：定位该书的「主记录」（`author=''` 优先，其次 `lastRead` 最新）并只更新 `readTime`，**不清空**章节快照/封面/显示字段（写路径不再做作者合并）；**阅读器写路径本批未传作者**（签名未变），时长记入该书主记录，作者感知写入后续批补。`deleteReadRecord(bookName)` 删除该书**全部作者**的行（上游按显示书名+作者删除，差异已登记）。旧合并作者串（`\u001Eauthors:`）在迁移中**原样保留不拆**，仅用于搜索阅读记录标识与展示解码；书备忘（`book_memos`）本批只做数据层与备份，**无 FFI 方法**（阅读器备忘面板后续批）。
>
> **readRecord v113 审查回修（2026-10-28 批27b，零 FFI 签名变化）**：
> ① **会话基数口径（P1-1）**：阅读器进入会话时，Dart 侧基数**只取该书主记录**的 `readTime`，选取口径与 Rust `ReadRecordRepository::primary_record` 完全一致（`author=''` 优先 → `lastRead` 最大 → `readTime` 最大），**不得把同名书所有作者行的 `readTime` 求和**。原因：`putReadRecord` 不传作者，Rust 只把新时长写回上述主记录，并以该行旧值计算 `readRecordDaily` 增量；基数若含其他作者行，从第二个会话起每会话都会把其他作者的时长重复叠加进主记录（热力图/记录页膨胀）。**风险登记**：同书多作者共享一次阅读会话时，阅读时长只记入主记录，其他作者行时长不随本机阅读增长（作者感知写入需扩展 FFI 签名，另批处理）。
> ② **展示解码（P2-1）**：Dart 侧按原版 `ReadRecordAuthors.display` 同构解码 `\u001Eauthors:["A","B"]`（剥前缀 → JSON 字符串数组 → 过滤空白/去重 → 按码位排序 → 「、」连接；前缀后 JSON 非法回退原文；另支持 `\u001F` 聚合分隔符分段），分组键与展示作者均使用解码后的值。
> ③ **删除确认（P2-2）**：UI 明示「将删除该书全部作者的阅读记录」，与 FFI 按物理书名整书删除的语义一致。
> ④ **迁移事务（P2-3）**：112→113 表重建改用 rusqlite 事务对象（失败自动 ROLLBACK），失败后连接保持 autocommit；搬运语句由 `INSERT OR REPLACE` 改为 `INSERT`（旧主键 `(deviceId, bookName)` 唯一，撞行属数据异常应显性失败）；`index_readRecord_snapshot` 改为无条件 DROP+CREATE（`PRAGMA index_info` 不暴露 ASC/DESC，条件比对可能漏判同名索引的排序方向）。
> ⑤ **本批未做/差异登记**：跨设备显示元数据传播（上游 `ReadRecordDao.insert` 会把同 identity 的 `displayBookName`/`displayAuthor`/`metadataEditedAt` 传播到该 identity 的全部行，我方 v113 写入只更新当前行）；阅读记录列表不展示章节快照/封面（`lastChapterTitle`/`lastChapterIndex`/`lastChapterPos`/`coverUrl` 已在数据层与备份中往返，UI 展示后续批）；分组行 `physicalBookName` 取组内首行（FFI 按 `readTime` 降序返回，非上游「快照行 = `lastRead` 最大」口径），打开书籍可能落到同组另一作者行，后续批按上游 join 快照行修正。
>
> **批35：书籍级阅读记录开关（2026-10-29，对齐参考版 `Book.disableReadRecord`）**：① 写入门控在 Rust `upsert_read_record` 的**最前端**（早于主记录定位与 readRecordDaily 累加）：`book_url` 非空且该书 `disableReadRecord=true` → 直接返回哨兵 `-1`（批35b；批35 原为传入 `read_time`），库内零写入；书籍不存在按无记录处理（保持旧行为，不因临时书/未落库书阻断阅读）。② 阅读器 Dart 侧同时做本地短路（`book.disableReadRecord` 为真时连 FFI 都不发），Rust 侧查询是「详情页切换后阅读器仍持有旧 Book 副本」的第二道保险。③ 本轨**仅文本阅读器**写阅读记录（朗读/听书当前不写 readRecord，故无需额外门控）；RSS 阅读记录是 `rssReadRecords` 独立体系（按源 `enableReadRecord`），不受 `books.disableReadRecord` 影响。④ 备份：`readRecord` 段与 `books.disableReadRecord` 各自独立往返；恢复备份不会因开关为真而删除既有记录（对齐参考版只拦写入、不清历史）。
>
> **批35b P3-1：关闭期间时长不补记**：① 本地短路（全局 `enableReadRecord` 关闭 / 书级开关为真）时阅读器推进 `_readStartMs`，同会话重开后首轮增量从重开时刻起算；② Rust 侧跳过时 `putReadRecord` 返回 `false`，阅读器把本轮 `delta` 从 `_baseReadTimeMs` 回滚（起点已推进，不重复累计）。
>
> **批35b P3-6：`recordReadingTime` 的既有绕过（契约登记，无生产调用方）**：`recordReadingTime(bookName, seconds)` 只传书名、**不传 `bookUrl`**，Rust 侧无从判断书级开关，因此 `disableReadRecord=true` 对它不生效。当前 Flutter 生产代码无调用方（仅接口/实现保留的历史统计入口）；新增写路径若需书级门控，必须走 `putReadRecord(..., bookUrl:)`。若要彻底封堵，需为该入口增加 `bookUrl` 参数或按书名反查主记录对应书籍（另批处理）。

### 2.13 RSS 收藏操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getRssStars()` | 无 | `Future<List<RssStar>>` | 获取所有 RSS 收藏 |
| `addRssStar(RssStar star)` | star: RssStar 对象 | `Future<RssStar>` | 添加 RSS 收藏 |
| `deleteRssStar(String link)` | link | `Future<void>` | 删除 RSS 收藏 |
| `isStarred(String link)` | link | `Future<bool>` | 判断是否已收藏 |

### 2.14 书籍分组（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookGroups()` | 无 | `Future<List<BookGroup>>` | 获取所有书籍分组 |
| `addBookGroup(BookGroup group)` | group: BookGroup 对象 | `Future<BookGroup>` | 添加书籍分组（新 `groupId` = 最小未占用 2 的幂，上限 `1<<30`） |
| `updateBookGroup(BookGroup group)` | group: BookGroup 对象 | `Future<void>` | 更新书籍分组 |
| `deleteBookGroup(int groupId)` | groupId | `Future<void>` | 删除书籍分组 |

> **`BookGroup.groupId` 语义（2026-11-06 批6a-1 设备修复，零签名变化）**：
> - **新组 ID**：`addBookGroup` 由 Rust `BookGroupRepository::get_unused_id` 返回最小未占用 `2^n`（`1,2,4,…`，上限 `1<<30`），对齐原版 `BookGroupDao.getUnusedId`；不再使用时间戳。
> - **存量兼容**：历史时间戳/任意非 `2^n` ID 不迁移、不重排；Dart 过滤按混合语义——`groupId` 为 2 的幂 → `(book.group & groupId) != 0`；非 2 的幂 → `book.group == groupId`。`BookGroup.IdAll=-1` 及 `-2..-6` 特殊组沿用既有分支。
> - **位域边界**：`groupId <= 0` 不参与自定义组掩码匹配（特殊组除外）；`1<<30` 用尽后 `addBookGroup` 返回错误，不生成重叠位。
> - **删除分组（2026-11-06 复核）**：`deleteBookGroup` 必须在同一事务内先清书成员再删组——2^n 组只清 `0 < books.group <= 1<<31-1` 的对应位，避免误清旧时间戳高位；非 2^n/高位旧组按 exact 清 0；`groupId<=0` 特殊组不动书。
> - **外部数据边界**：小整数（如 1、2）若被外部工具直接写入 `books.group`，会被视为新 2^n 位掩码而非旧组；外部/旧客户端按 exact 写入的值不保证与新版位掩码语义一致，需要用户重新分配。
> - **并发边界（登记）**：`get_unused_id` 为 SELECT + INSERT 两步，非原子；当前 FFI 单进程/单 DB 连接使用。若未来多进程并发创建分组，可能发生唯一键冲突，届时改为 `BEGIN IMMEDIATE` + 冲突重试。
> - **旧客户端**：读新组 ID 时按 exact 匹配只命中自身，位掩码多组语义仅在升级后生效。

### 2.15 搜索历史（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getSearchHistory({int limit = 50})` | limit(默认50) | `Future<List<SearchKeyword>>` | 获取搜索历史 |
| `searchHistoryByPrefix(String prefix, {int limit = 20})` | prefix, limit(默认20) | `Future<List<String>>` | 按前缀搜索历史关键词（搜索联想） |
| `addSearchKeyword(String keyword, String bookName)` | keyword, bookName | `Future<void>` | 添加搜索关键词 |
| `deleteSearchKeyword(String keyword)` | keyword | `Future<void>` | 删除搜索关键词 |
| `clearSearchHistory()` | 无 | `Future<void>` | 清空搜索历史 |
| `clearExpiredSearchBooks(int beforeTimestampMs)` | beforeTimestampMs: 毫秒时间戳 | `Future<int>` | **批9b-1** 删除 `time < beforeTimestampMs` 的过期搜索结果行，返回删除行数（严格小于：`time == before` 保留；对齐原版 `SearchBookDao.clearExpired` SQL `delete from searchBooks where time < :time`；启动接线：`autoClearExpired` 开关（默认 true）开启时以 `now - 1 天` 调用，unawaited 静默失败，见更新记录批9b-1 行） |

> ℹ️ **按书搜索历史待后续（2026-10-29 批33；方法签名不变）**：参考版「仅本书」胶囊只控制搜索历史的按书过滤，我方此前误绑到正文搜索范围。批33 已解绑（胶囊仅提示、不改 scope；范围统一由 ⋮ 菜单三档控制并持久化）。**能力缺口**：本表 `SearchKeyword` 仅返回 `word` / `usage` / `lastUseTime`，`getSearchHistory` 无 bookName 维度/按书过滤入参，且 Rust `search_keywords` 表与 `SearchKeywordRepository::insert` 当前直接忽略 `bookName`（无该列）——按书历史过滤需先扩 schema/FFI，本轮不新建表、不改签名。

### 2.16 缓存管理（9 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getCacheSize()` | 无 | `Future<int>` | 获取缓存大小（字节） |
| `clearCache()` | 无 | `Future<void>` | 清除全部缓存 |
| `clearBookCache(String bookUrl)` | bookUrl | `Future<int>` | 清除指定书籍章节缓存，返回删除行数（对齐 BookHelp.clearCache(book)） |
| `clearChapterCache(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<int>` | 清除指定书籍**单章**的章节缓存，返回删除行数（行不存在为 no-op 成功；对齐上游原版 `BookHelp.delContent` 章级语义——仅删本章缓存行，**不触碰** `sameTitleRemoved` 等章级开关键，不触发整书清理；空 bookUrl 返回参数错误）（STAGE3-C2B：刷新正文对齐上游强制联网重取） |
| `getCacheBookCount()` | 无 | `Future<int>` | 获取缓存书籍数量 |
| `getCacheChapterCount()` | 无 | `Future<int>` | 获取缓存章节数量 |
| `clearCacheBefore(int beforeTimestampMs)` | beforeTimestampMs: 毫秒时间戳 | `Future<void>` | 清除指定时间之前的缓存 |
| `shrinkDatabase()` | 无 | `Future<int>` | 执行 SQLite VACUUM 压缩数据库文件，返回释放的字节数；Rust 侧应在后台线程执行避免阻塞。错误语义：VACUUM 失败（数据库锁/文件损坏）或数据库未初始化 → 返回 0 降级为无操作（不抛异常阻断业务）（台账 §5.13-9，第二批后置项，Task #50，加法式新增） |
| `getCachedChapter(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 读取已缓存章节正文（FFI `cacheGetChapter`，F3-10 补登记 §1.7 命名等价） |

### 2.17 WebBook 操作（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `webbookSearch(String sourceJson, String query, int page)` | sourceJson, query, page | `Future<String>` | 搜索书籍（书源规则驱动），返回 JSON |
| `webbookInfo(String sourceJson, String bookUrl)` | sourceJson, bookUrl | `Future<String>` | 获取书籍详情 JSON |
| `webbookChapters(String sourceJson, String bookUrl)` | sourceJson, bookUrl | `Future<String>` | 获取章节列表 JSON |
| `webbookContent(String sourceJson, String chapterJson)` | sourceJson, chapterJson | `Future<String>` | 获取章节正文（含 nextContentUrl 分页抓取，见下） |
| `debugBookSourceStream(String sourceUrl, String key)` | sourceUrl（已入库书源 URL）, key（调试关键字） | `Stream<Map<String, dynamic>>` | 流式书源调试（对齐 Kotlin `Debug.startDebug` + `Callback.printLog`）。每条 JSON：`state`（int）/ `msg`（String，含 `[mm:ss.SSS]` 时间戳）；`state=-1` 失败终止、`1000` 成功完成；关键字分流：绝对 URL→详情、`分类名::url`→发现、`++tocUrl`→目录、`--chapterUrl`→正文、否则搜索→详情→目录→正文。流在完成/取消/sink 关闭后结束 |
| `cancelDebugBookSource()` | 无 | `Future<void>` | 取消正在进行的书源调试（对齐 `Debug.cancelDebug`） |

> ℹ️ **nextContentUrl 分页抓取行为（Task #108 缺口①）**：`webbookContent` 签名不变，行为完善——消费 `contentRule.nextContentUrl` 规则（对标 Kotlin `BookContent.analyzeContent` 分页循环）：解析当前页正文后解析下一页 URL 规则，非空且未重复则继续抓取并按页拼接（`\n` 连接，同 Kotlin `contentList.joinToString("\n")`）；每页正文独立走 HtmlFormatter 净化（按该页 URL 绝对化 img）。防死循环保护：已访问 URL 去重（含首章 URL）+ 最大页数上限 99（原版无显式上限，Rust 轨加法式加固）；nextContentUrl 命中下一章 URL 的截断判定因无状态签名不可得 nextChapterUrl，由 URL 去重与页数上限兜底。音视频源不参与分页净化（同单页行为）。

> ℹ️ **空正文规则语义（P4-1 C4，2026-09-29，行为事实补记，零行为变更）**：正文规则 `ruleContent.content` 为空时，**非 JS 书源**两侧语义**一致**——`webbookContent` / 阅读正文链**不请求章节页**、直接返回**章节 URL 字符串**。Rust 侧短路位于 `WebBookEngine::get_content` 包装层（`legado-core/src/web_book.rs`，注释「正文规则为空时回退章节链接（听书/直链源关键路径）」），对齐原版 Kotlin `WebBook.kt:429-433`（`contentRule.content.isNullOrEmpty()` → `return bookChapter.url`，日志「正文规则为空,使用章节链接」）。JS 书源（`mainJs` 非空）豁免该短路：原版走 `JsSourceBook.getContentAwait` 独立分支（Kotlin `WebBook.kt:408-424`）；Rust 进入 fetcher 正文链（空规则 → 章节页 body 经 `format_keep_img` 直用）——这是 `parse_content_page_with_bindings`「body 直用」分支（空规则 → `analyzer.content()`）的**唯一可达路径**，非 JS 源经引擎路径不可达（包装层先短路，章节页不请求）。P4-1 调查稿 §6 C4 原表述「空正文时 Rust 返回 body HTML、原版返回章节 URL 字符串」**与实测行为不符**（实测 Rust 与原版同为「回退章节 URL」），本补记以实测行为为准并勘误。影响：漫画书源（bookSourceType=2）若 `content` 规则为空，上层（阅读器/Dart）收到的是章节 URL 字符串而非正文 HTML，漫画屏渲染前须按「URL 字符串」语义处理（图片 URL 行解析等兜底路径见 `comic_image_utils`）。固化测试：`rust/legado-ffi/tests/comic_content_fixture.rs::test_empty_content_rule_returns_chapter_url_like_original`（离线回环，章节页路由注册但断言零命中 + 正文 == 章节 URL）。本补记为纯契约记录 + 测试固化，无实现/签名变更。

> ℹ️ **流式 Debug.Callback（2026-08-13）**：Rust 侧 `ffi::debug_book_source_stream / debug_book_source_cancel`（实现 `legado-ffi/src/api/source_debug_api.rs`），复用既有 `webbook*` / `exploreFetchBooks` 链路推送逐步日志与字段摘要（`JsSourceDebugFormatter` 风格）。冻结 `webbook*` 契约不变，本组为加法式新增。

> ℹ️ **webbook* 非阻塞执行（2026-08-24）**：`webbookSearch/webbookInfo/webbookChapters/webbookContent` 四方法在 Rust 阻塞线程池（tokio `spawn_blocking`）执行，对齐原版 `WebBook.kt` Dispatchers.IO 语义；FFI 入口立即返回，网络 + quickjs JS 解析不阻塞 Dart 主 isolate。签名与返回值不变。

### 2.18 发现页操作（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `exploreParseUrl(String exploreUrl, {String sourceJson})` | exploreUrl；`@js:` 须传 sourceJson | `Future<List<ExploreCategory>>` | 解析 exploreUrl 为分类列表（含 type/action/chars/style） |
| `exploreFetchBooks(String sourceJson, String url, int page)` | sourceJson, url, page | `Future<List<SearchBook>>` | 抓取发现分类的书籍列表 |
| `exploreInfoMapPut(String sourceUrl, String key, String value)` | sourceUrl, key, value | `Future<void>` | toggle/select/text 写入 infoMap |
| `exploreInfoMapEnsureDefault(String sourceUrl, String key, String defaultValue)` | sourceUrl, key, defaultValue | `Future<void>` | infoMap 键不存在时写入默认值 |
| `exploreInfoMapSnapshot(String sourceUrl)` | sourceUrl | `Future<String>` | 读取 infoMap 快照（JSON 对象；UI 回显 toggle/select/text 已存值，对齐原版 InfoMap 持久化）。加法式新增（2026-08-14 发现页修复 B①） |
| `exploreEvalAction({required String sourceJson, required String actionJs})` | sourceJson, actionJs | `Future<Map>` | 执行发现控件 action JS；返回 `{raw, actions, refreshExplore}`（对标 evalButtonClick + java 中途 UI） |
| `exploreEvalUiJs({required String sourceJson, required String jsStr})` | sourceJson, jsStr | `Future<String>` | 执行 viewName 动态标题 JS（对标 evalUiJs） |

### 2.19 规则解析（1 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseRule(String content, String rule, String ruleType)` | content, rule, ruleType（css/xpath/json/regex 等，rule 无 `@` 前缀时拼为 `@type:rule`） | `Future<String>` | 使用规则解析内容，返回 `{results,count}` JSON |

### 2.20 网络操作（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `httpGet(String url)` | url | `Future<String>` | HTTP GET 请求，返回 JSON `{"status": int, "body": string, "url": string}`（文本 body） |
| `httpPost(String url, String body)` | url, body | `Future<String>` | HTTP POST 请求，返回格式同 httpGet |
| `httpGetBytes(String url, {String headersJson = ''})` | url；headersJson 可选 JSON 对象 | `Future<String>` | HTTP GET 二进制响应，返回 JSON `{"status": int, "bodyBase64": string, "url": string}`（F3-14，经 legado-net 共享客户端） |
| `fetchImageWithDecode(String url, String sourceJson)` | url, sourceJson（BookSource JSON） | `Future<String>` | 图片下载 + imageDecode JS 解密，返回 `{base64,len}` JSON（F3-10 补登记）。**批32**：登录头（`loginHeader_<bookSourceUrl>`）按目标 URL 与书源**同站**门控附加（`legado_fetcher::web_book::is_login_header_site`，eTLD+1 口径；跨域 CDN 不携带认证信息，无法判定域名时回退附加），与搜索/发现/正文链同口径；发送前 `strip_proxy_header` 剔除 `proxy` 伪头（源 header 中的代理配置键不得作为 HTTP 头外发） |
| `setCustomHosts(String hostsJson)` | hostsJson: 域名→IP 映射 JSON 对象字符串（对齐原版存储格式） | `Future<void>` | 设置自定义 hosts 映射，配置后网络层 DNS 解析优先使用该映射（命中域名直连映射 IP，未命中回落系统 DNS）。存储格式对齐原版 `AppConfig.customHosts`：JSON **对象** `{"域名":"IP", "域名":["IP1","IP2"]}`（值支持单 IP 字符串或 IP 数组，实读原版 `AppConfig.hostMap/addressCache` 确认）；空串/空对象=清除映射、恢复系统 DNS。配置需持久化（复用既有配置存储语义，caches 表 `config:` 前缀键 `customHosts`，与既有 `setConfig` 同语义）并即时生效（后续请求使用新映射）。Rust 实现要点：legado-net 经 reqwest `ClientBuilder::resolve` 域名覆盖或自定义 DNS resolver 挂钩（现状无 custom_hosts 钩子，实施时补）。错误码：Internal（hostsJson 非合法 JSON 对象）。差异注明：原版非法输入即清除；本契约改为拒绝保存（更防误操作，Task #76 Med2）。既有 `httpGet` / `httpPost` 签名保持不变，本方法为加法式新增（台账 §5.13-1，第四批后置项，Task #72） |

### 2.21 JS 引擎（3 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `evalJs(String script)` | script | `Future<String>` | 执行 JS 脚本 |
| `getJsEngineVersion()` | 无 | `Future<String>` | 获取 JS 引擎版本 |
| `evalImageAction(String bookUrl, int chapterIndex, String action, String imgSrc)` | bookUrl：书籍 URL；chapterIndex：章节序号（可 -1 表示无章节上下文）；action：书源 `<img>` 的 `click`/`js` 动作源码；imgSrc：图片地址（作为 `result` 与 `baseUrl` 依据） | `Future<String>` | **2026-11-12 批20 加法式新增**：执行正文图片上的书源动作（对齐参考版 `ReadBookController.kt:677-695`）。绑定：`source`（书源 JSON 对象）、`book`（name/author/bookUrl）、`chapter`（title/index/url/bookUrl，缺失时字段为空串/0）、`result`（=imgSrc）、`baseUrl`（=imgSrc 的目录部分）、`java`（`log/t2s/s2t/get/put`）。成功返回动作结果字符串；动作抛错/超时/`@js:` 非法返回空串并记 `log::debug!`（不上抛，避免打断阅读）；无 quickjs 构建返回明确错误（不静默）；`bookUrl` 无对应书籍行时 `book` 字段留空。Rust `ffi::eval_image_action` | **2026-11-12 批21-A 返回值扩展（签名不变、向后兼容）**：动作期间产生的中途 UI 副作用（`java.toast`/`java.longToast`/`java.showBrowser`/`java.startBrowser`/`java.openUrl` 等，经 `ui_action_queue` 收集）存在时，返回值由纯字符串扩展为 JSON 信封 `{"_lgActions":true,"result":"<动作结果>","actions":[<action 对象>...]}`；无副作用时保持纯字符串。action 对象沿用既有入队形态：`action` 为动作名；`toast`/`longToast` 含 `message`；`openBrowser`（对应 `java.showBrowser`）/`startBrowser`/`openUrl` 含 `url`，另有 `html`/`title`/`mimeType` 等既有字段。Dart 侧仅在 JSON 对象含 `_lgActions:true`、`result` 为字符串且 `actions` 为**非空**数组时按信封拆包，否则按纯字符串处理（旧调用方无需改动）。执行器按书源 `bookSourceUrl` 进程内 LRU 缓存（上限 4）复用已加载 `jsLib` 的引擎；书源新增/更新/删除/导入调用 `legado_js::replace_rule_js::invalidate_image_action_engine` 失效，`jsLib` 变更亦自动重建，无书源 URL 不缓存；`jsLib` 拉取降级（degraded）的引擎不入缓存。无 quickjs 构建行为不变（明确报错）。方法计数不变。

### 2.22 服务器管理（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `startServer({int port = 1122})` | port(默认1122) | `Future<void>` | 启动服务器 |
| `stopServer()` | 无 | `Future<void>` | 停止服务器 |
| `getServerStatus()` | 无 | `Future<String>` | 获取服务器状态 |
| `setServerPort(int port)` | port | `Future<void>` | 设置服务器端口 |
| `setMcpPort(int port)` | port: 独立 MCP 服务端口（合法区间 1024–65530，对齐原版 NumberPicker 取值；缺省语义默认 1236，对齐原版 `AppConfig.mcpPort` 默认值，未配置时 UI 对话框预填 1236 落实该缺省语义）；port ≤ 0 = 停止独立 MCP 服务 | `Future<void>` | 启动/停止独立 MCP 服务端口（**对齐原版独立端口方案**，见下方决策说明）。独立端口启动后提供与既有 Web 端口挂载的 `/mcp/tools`（GET）/ `/mcp/call`（POST）等价能力（同一套 MCP 工具与调用入口，零新增工具）；**并存与鉴权**：独立端口开启时 Web 端口 `/mcp/tools`（GET）/`/mcp/call`（POST）挂载保持存在，其中 **Web 端口 `/mcp/call` 已纳入 `PROTECTED_SOURCE_WRITE_ROUTES`，请求须携带 `x-legado-token`（大小写不敏感）且与 `config:jsSourceApiToken` 字节级相等，否则返回令牌失败信封并关闭连接；`/mcp/tools` 免令牌**；默认 `jsSourceApiTokenRequired=true` 且未配置令牌时 `/mcp/call` 一律拒绝（显式关闭 required 时按原版免令牌放行）。独立 MCP 端口行为不变（其 `/mcp/*` 仍走自身 `X-Legado-Token` 中间件）。Web 端口与独立端口共用同一 AppState/工具实现。端口配置需持久化（caches 表 `config:` 前缀键 `mcpPort`，与既有配置语义一致）。**F5（2026-08-13）**：监听 `0.0.0.0`（LAN 可达，对齐原版）；启动前置要求 `config:jsSourceApiToken` 非空（否则 Internal）；独立端口 `/mcp/*` 请求须带请求头 `X-Legado-Token`（大小写不敏感）与配置 token 字节级相等，否则 401。错误码：Internal（端口绑定失败 / 越界 / token 未设置）。既有 `startServer` / `stopServer` / `getServerStatus` / `setServerPort` 签名保持不变，本方法为加法式新增（台账 §5.13-6，第四批后置项，Task #72） |

> ℹ️ **mcpPort 决策说明（台账 §5.13-6，Task #72；F5 补齐）**：调研原版 `McpService.kt`——其为**独立前台服务**，ktor CIO embeddedServer 绑定 **0.0.0.0** 独立端口（`AppConfig.mcpPort` 默认 1236，合法区间 1024..65530），与 Web 服务完全分离；启动前置条件为 `jsSourceApiToken` 非空；请求经 `X-Legado-Token` 鉴权 + Host/Origin 白名单。本轨：`setMcpPort` 独立端口 + REST `/mcp/tools`/`/mcp/call`；**F5 已对齐** LAN 绑定、`jsSourceApiToken` 启动前置与 `X-Legado-Token` 校验。差异：原版另有 Host/Origin 白名单（本轨暂以 token 为访问控制主防线）；原版越界回落 1236，本契约改为报错（UI 内联区间校验前置拦截）。

### 2.23 书籍格式解析（3 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseTxt(String filePath)` | filePath | `Future<List<BookChapter>>` | 解析 TXT 文件 |
| `parseEpub(String filePath)` | filePath | `Future<List<BookChapter>>` | 解析 EPUB 文件 |
| `exportBook(String bookUrl, String format, String outDir)` | bookUrl, format, outDir | `Future<String>` | 导出书籍（将章节内容写入文件） |

### 2.25 HTTP TTS（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getHttpTts()` | 无 | `Future<List<HttpTts>>` | 获取所有 HTTP TTS 配置 |
| `getHttpTtsList()` | 无 | `Future<List<HttpTts>>` | 获取所有 HTTP TTS 配置（别名） |
| `addHttpTts(HttpTts tts)` | tts: HttpTts 对象 | `Future<HttpTts>` | 添加 HTTP TTS 配置 |
| `updateHttpTts(HttpTts tts)` | tts: HttpTts 对象 | `Future<void>` | 更新 HTTP TTS 配置 |
| `deleteHttpTts(int id)` | id | `Future<void>` | 删除 HTTP TTS 配置 |
| `importHttpTts(String json)` | json: JSON 字符串 | `Future<int>` | 导入 HTTP TTS 配置，返回成功数量 |
| `exportHttpTts()` | 无 | `Future<String>` | 导出 HTTP TTS 配置 |

### 2.26 音频播放（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `audioSpeak({required String text, required String engineUrl, double speed = 1.0, double pitch = 1.0, double volume = 1.0, String? voiceName})` | text, engineUrl, speed, pitch, volume, voiceName | `Future<void>` | TTS 朗读（文本书朗读路径；与音频书流媒体互斥） |
| `getAudioChapterMedia(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<Map<String, dynamic>>` | **音频书章节取址**（对齐原版 `AudioPlay` → `WebBook.getContent`）。Rust FFI：`audioGetChapterMedia` → JSON。返回字段（camelCase）：`chapterIndex` / `title` / **`mediaUrl`**（可播地址，即 getContent 正文 trim）/ `url`（章节页 URL，兼容旧字段）/ `resourceUrl` / `isVolume`（卷章无媒体，调用方应跳过）/ `fromCache` / `lyric` / `sourceUrl`。流程：查章 → 卷章短路 → DB 章节内容缓存命中则直接作 `mediaUrl` → 否则按 `book.origin` 书源 `getContent`（**正文规则为空时回退章节 URL**，对齐 Kotlin）→ 写入缓存。空 `mediaUrl` 且非卷章表示取址失败。错误码：章节/书籍不存在 → Database；书源网络/解析失败向上抛。与 TTS `audioSpeak` 分流：仅 `BookType.audio` 走本接口流媒体 |
| `getAudioProgress(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<Map<String, dynamic>?>` | 获取音频播放进度 |
| `saveAudioProgress(String bookUrl, int chapterIndex, int positionMs)` | bookUrl, chapterIndex, positionMs | `Future<void>` | 保存音频播放进度 |

### 2.28 WebDAV 云同步（11 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `webdavListDir(String configJson, String path)` | configJson, path | `Future<String>` | WebDAV 列出远程目录；返回 `Vec<WebDavFileInfo>` JSON：`name` / `path` / `size` / `last_modified` / `etag` / `is_dir` |
| `webdavUpload(String configJson, String path, String data)` | configJson, path, data | `Future<void>` | WebDAV 上传文件 |
| `webdavDownload(String configJson, String path)` | configJson, path | `Future<String>` | WebDAV 下载文件（**仅 UTF-8 文本**；二进制请用 `webdavDownloadFile`） |
| `webdavDelete(String configJson, String path)` | configJson, path | `Future<void>` | WebDAV 删除远程文件 |
| `webdavFullSync(String configJson, String localBooks, String localSources)` | configJson, localBooks, localSources | `Future<String>` | WebDAV 全量同步 |
| `webdavUploadFile(String configJson, String path, String localFilePath)` | configJson（与既有 `webdavUpload` 相同，WebDavConfig JSON）；path: 远程目标路径；localFilePath: 本地文件绝对路径 | `Future<void>` | WebDAV 从本地文件路径读取并上传（大文件场景，如书籍上传至远程），区别于既有 `webdavUpload` 的 String data 直传；既有 `webdavUpload` 签名保持不变。错误码：Io（文件不存在/读取失败）/ Net（上传失败）/ Internal（配置解析失败）（台账 §5.11-1 上传至远程，Task #50，加法式新增） |
| `webdavDownloadFile(String configJson, String path, String localFilePath)` | configJson（WebDavConfig JSON，字段 `url`/`username`/`password`/`remote_dir`）；path: 相对 `remote_dir` 的远程路径；localFilePath: 本地落盘绝对路径 | `Future<void>` | WebDAV 下载**二进制**到本地文件（对齐远程书库 `RemoteBookActivity` 导入；镜像 `webdavUploadFile`）。父目录不存在时创建；错误码：Io（写盘失败）/ Net（下载失败）/ Internal（配置解析失败）。既有 `webdavDownload` 签名保持不变（加法式新增，2026-08-12 P1-5） |
| `webdavServersList()` | 无 | `Future<String>` | 列出 `servers` 表全部服务器（`sortNumber` 升序、同序按 `id` 升序），返回**裸 JSON 数组**（对齐 §1.4 列表返回铁律）：元素为原版 `Server` 实体形态 `id` / `name` / `type` / `config` / `sortNumber`；`type` 当前仅 `"WEBDAV"`；`config` 为 `{"url","username","password"}` 的 **JSON 字符串**（原版 `Server.config: String?`）。对齐原版 `ServerDao.all`（`order by sortNumber`）。DB 未初始化/读取失败 → 抛 bridge 错误（不静默返回空数组）。**批8（2026-10-26，用户裁决②）**：`servers` 表（DB v112）落地面；Flutter WebDAV 同步设置改由本表承载，备份 v3 纳入 `servers` |
| `webdavServerSave(String serverJson)` | serverJson：`Server` JSON（`id` 缺省或为 0 时按当前毫秒分配并避让既有主键；**负数 id 原样保留**（`-1` = 默认 WebDAV 同步账号固定身份）；`name` 缺省空串；`type` 缺省 `WEBDAV`；`config` 可空；`sortNumber` 缺省 0） | `Future<int>`（实际落库的 server id） | 全字段 upsert（`INSERT OR REPLACE`，对齐原版 `ServerDao.insert(onConflict = REPLACE)`），返回落库 id。**批8**：Flutter 同步设置保存链路（含 prefs→DB 一次性迁移）唯一写入口；id 为 0 的新建语义对齐原版 `Server.id = System.currentTimeMillis()` 默认值。**批18a**：远程书库服务器新建/编辑亦经本方法（`ServerService.saveServer`；编辑保留既有 `sortNumber`，`id = 0` 交 Rust 分配，`id = -1` 拒绝） |
| `webdavServerDelete(int id)` | id | `Future<bool>` | 按 id 删除服务器（对齐原版 `ServerDao.delete(id)`），返回是否命中行；目标不存在返回 `false`（不抛错，对齐 Room DELETE 静默语义）。**批8**：预留；**批18a（2026-10-27）已消费**——远程书库服务器 Sheet 的删除入口经 `ServerService.deleteServer` 调用（`id = -1` 默认 WebDAV 拒绝删除），详见下方「远程书库服务器列表（批18a 已迁移）」 |
| `webdavPruneBackups(String configJson, String currentFileName, int keepCount)` | configJson：WebDavConfig JSON；currentFileName：本次刚上传的备份文件名（不含目录）；keepCount：保留份数（含当前文件，0=不清理） | `Future<String>` | **批40（契约先行；批40b 回修）** 清理远端根目录历史备份，对齐原版 `AppWebDav.pruneOldBackups`：只处理严格命名的 `backup_yyyyMMdd_HHmmss[_SSS].json`（大小写敏感，`BACKUP_`/松前缀/`.json.bak` 不参与），按文件名降序、先排除 `currentFileName` 再保留 `keepCount - 1` 份；`keepCount = 0` 直接返回空结果（零网络请求）；删除键取 PROPFIND `href` 解析出的相对 `remote_dir` 路径（百分号解码，不信任 `displayname`）；单文件删除失败只记日志并计入 `failed`。返回 `{"deleted":[..],"failed":[{"name":..,"error":..}]}`。Rust 实现 `legado-net/src/webdav.rs::prune_backup_files`（DELETE 走状态码校验的 `delete_checked`）。Dart 消费：`WebDavBackupService.uploadBackup`（上传成功后调用，清理失败仅日志） |

> **servers 表（DB v112，2026-10-26 批8 用户裁决②）**：对齐原版 Room `servers` 表（`data/entities/Server.kt`：`id` INTEGER 主键 + `name` / `type` / `config` / `sortNumber`，`ServerDao`：`order by sortNumber`）。**语义对照说明**：原版该表的消费方是「远程书库」服务器列表（`ServersDialog` / `ServerConfigViewModel` / `RemoteBookViewModel` + `Authorization(serverID)`），备份 WebDAV 同步账号在原版仍是偏好（`PreferKey.webDavUrl/webDavAccount/webDavPassword` + `AppConfig.webDavDir`）；本批按用户裁决②把我方同步账号也纳入 `servers`（`id = -1`），属显式裁决的口径收敛；**远程书库列表已于批18a 迁移到本表**（见下方「远程书库服务器列表（批18a 已迁移）」）。本批落地面：① Flutter WebDAV **同步设置**（原 `sync_webdav_*` 偏好中的 url/username/password）一次性迁移为 `id = -1` 的 `WEBDAV` 行（`config` 为 `{"url","username","password"}` JSON 字符串；子目录/设备名仍为 Flutter 偏好，对齐原版 `AppConfig.webDavDir` 亦为偏好而非 servers 列）；迁移幂等（`servers` 表无记录且旧偏好存在时写入一次，置迁移标记后不再重复）；② 备份 v3 纳入 `servers`（键 `servers`，形态为原版 `servers.json` 的实体数组），恢复按 `id` REPLACE（原样保留备份主键，含 `id = 0`；`webdavServerSave` 的 `id=0 → 当前毫秒` 仅用于新建）、**备份缺该键不清库内 servers**（对齐原版 `Restore.kt:379-390` 仅在文件存在时 insert 的语义）；**旧格式恢复边界（2026-10-26 审查回修 P1-1）**：v1/v2 备份无 `servers` 键且恢复器不触碰库内 servers，恢复流程（`webdav_settings_screen.dart`）在恢复成功后把备份带来的 `sync_webdav_url/username/password` 偏好显式覆盖到 DB `id = -1` 行（`WebDavServerService.applyLegacyPrefsOverwrite`；三项全空时不写库，DB 无行则创建，既有 `name`/`sortNumber` 保留；**仅当备份 `appPrefs` 携带账号键时回填**——备份未带账号则保持 DB 不变，防止设备残留偏好覆盖当前配置；**批17d P3-5**：偏好密码为空时（批17c 起新备份不再导出 `sync_webdav_password`）按默认服务器 id 读回 DB 现有密码写入，不清空已保存密码；备份携带旧密码仍按旧行为写入），对齐原版「prefs 即权威」语义；v3 备份含 `servers` 键则以备份 DB 行为准，不回读偏好；③ `webdav_api.rs` 的 `config_json` 入参签名全部保持不变，配置来源由 Flutter 从 DB 读取后传入。
> **远程书库服务器列表（批18a 已迁移，2026-10-27）**：`RemoteBookNotifier` 的服务器列表数据源已从 `SettingsService.remote_servers` 偏好切换到 `servers` 表，读写经新增 Dart 服务 `ServerService`（`lib/src/services/server_service.dart`）→ §2.28 三方法，**FFI 签名/方法数零变化**。**列表**：`webdavServersList` 后过滤 `id = -1`（默认 WebDAV 同步账号不在本页展示）；单行 `config` 非法只标记该行无效（`isValid=false`，仍可编辑/删除），不拖垮整页；整表形态异常（非数组/元素非对象/契约字段缺失）显式报错。**保存**：`type=WEBDAV`、`config` 为 `{"url","username","password"}` JSON 字符串；正数 `id` 原样保留且沿用既有 `sortNumber`，`id = 0`/缺省交给 Rust 分配；`id = -1` 拒绝编辑。**删除**：`id > 0` 经 `webdavServerDelete`；`id = -1` 永不删除。**选中项回退**：`remote_server_id` 指向的服务器不存在或 config 无效时回退默认 WebDAV（对齐原版 `RemoteBookViewModel.initData` 与参考版 `RemoteBookRepository.getWebDav`），不再报「服务器配置无效」；回退只改内存状态，不覆盖用户偏好。**一次性迁移**：应用启动（prefs+FFI 就绪后 await 一次）把旧 `remote_servers` JSON 数组写入 `servers` 表并置标记 `remote_servers_migrated`（默认 false）；非数组/解析失败不置标记（下次重试）；`id < 0` 跳过；正数 id 原样保留；重复 id 的后续条目改由 Rust 重新分配（告警）；密码 prefs 有值用 prefs、为空时按 DB 同 id 行保留；全部成功才置标记，同 id REPLACE 幂等；旧键 `remote_servers` / `remote_server_id` **保留不删**（回滚安全）。迁移失败只记崩溃日志、不阻断启动。**备份/恢复兼容**：新备份**不再导出** `remote_servers`（`RestoreIgnorePrefs.backupExcludedKeys` 单独排除，不塞 `alwaysIgnoreKeys`，旧备份仍可读）；恢复旧备份仍读取该键写入 prefs，并由恢复流程强制重跑 `migrateLegacyPrefs(force: true)` 写入 DB（仅当备份无 `servers` 段或仅含 `id = -1` 行；密码按 DB 既有 `id` → `url+username` 匹配保留本机）；原版 zip 备份的 `servers` 已由 Rust 恢复，无需额外处理。目录浏览复用 `webdavListDir`；导入 = `webdavDownloadFile` → `importLocalBook`。**未纳入本批（18b）**：Dart `webDavTag='dav:'` 与 `webDav::` 不一致、自定义服务器 origin 缺 serverID。
> **批40（2026-10-29）WebDAV 备份族语义与格式差异登记**：① **参考版缺失项（已登记）**——参考版 `legado-with-MD3` 的 Compose `BackupConfigScreen`/`BackupConfigViewModel` 未提供「WebDAV 备份保留数量」「导入后自动上传本地书」「自动备份间隔/目标」设置，其 `Backup.kt` 自动备份固定「距上次 ≥1 天」且无开关/目的地选项；本批按原版 `531f9fbf07` 的 `AppConfig.webDavBackupKeepCount`/`webDavBookAutoUpload`/`autoBackup`/`autoBackupWebDav`/`autoBackupIntervalDays` 语义实现（用户本批明确要求这些设置项），参考版差异在此登记。② **备份格式差异（已登记）**——原版/参考版 WebDAV 备份为 `backup<yyyy-MM-dd>[-<设备名>].zip`（zip 容器、可加密），我方为**单文件 JSON**（`backup_create` 全量 20 类数据（批27 起含 `book_marks`） + Flutter `appPrefs` 注入）；本批按我方 JSON 上传，远端命名 `backup_yyyyMMdd_HHmmss_SSS.json`（批40b 回修起追加毫秒段，同秒连续备份不互相覆盖；本地文件名保持 `legado_backup_<millis>.json` 不变，避免影响既有备份列表/恢复链路）。③ **保留数清理差异**——批40b 回修后只处理**严格命名**的 `backup_yyyyMMdd_HHmmss[_SSS].json`（大小写敏感）：`BACKUP_*`、`backup_notes.json`、`.json.bak`、`.zip`（原版/参考版客户端写入）**都不参与清理**，避免误删其它客户端或非备份文件；删除键取 PROPFIND `href`（百分号解码后相对 `remote_dir` 解析），不使用可能被服务器改写/缺失的 `displayname`；「保留 N 份」含本次上传文件，即保留 N-1 份历史。④ **手动「备份」语义收敛**——页面「备份」入口由「本地备份 + `webdavFullSync`（bookshelf.json/sources.json）」改为「本地备份 + 上传本次备份文件 + 可选保留数清理」（对齐原版 `webdav_backup` 只上传备份 zip 的语义）；`webdavFullSync` 仍由「恢复」短按入口使用。上传失败不回滚本地备份，SnackBar 分别提示「备份成功」「已上传 WebDAV」「上传失败原因」。⑤ **自动备份**——启动/回前台判定 `now - lastBackup >= autoBackupIntervalDays × 24h`（与原版 `shouldBackup` 同口径；`autoBackup` 默认开、`autoBackupIntervalDays` 默认 1 且读取时 clamp ≥1），与手动备份共用进程内互斥锁；**本地备份成功即写 `lastBackup`（上传失败不回退，下次周期再补传），本地备份失败不写**；锁内二次复检 `autoBackup` 开关与到期状态，`lastBackup` 落在未来（时钟回拨/恢复他机偏好）视为到期。未配置备份路径时回退 `getApplicationDocumentsDirectory()/backup`（原版回退 Android externalFiles 目录，平台差异已登记）。⑥ **导入后自动上传**——本地书导入成功后按默认 WebDAV 配置上传到 `books/<originName>`（与远程书库手动「上传至远程」同规则：`originName` 优先、否则取本地文件名），成功后回写 `book.origin = webDav::<完整 URL>` 与 `lastCheckTime`；开关 `webDavBookAutoUpload` 默认关；WebDAV 未配置直接跳过；任何失败仅日志，不阻断导入；逐本触发经服务层进程内单飞队列**串行**执行（对齐原版单协程串行）；本地书 `bookUrl` 若为相对标识（iOS 批量导入 `books/<name>`）上传前经 `LocalBookStore.resolveSync` 还原为当前容器绝对路径（批40b 回修 P1-1）。⑦ **调度范围差异（批40b 登记）**——原版自动备份由 `MainActivity`/`ReadBookActivity.onResume` 触发（含 Android 后台恢复），我方**仅应用内调度**：Flutter 应用启动首帧后与 `AppLifecycleState.resumed` 时判定，无 WorkManager/后台定时/后台任务；应用长期不启动则不会自动备份（与「仅应用内」口径一致，后续如需后台调度需单独立项）。⑧ **恢复互斥差异（批40b 登记）**——原版备份/恢复共用 `backupRestoreLocked`；我方批40 起恢复链（WebDAV 短按同步、本地长按恢复）同样进入 `LocalBackupService` 进程内互斥，恢复进行中自动/手动备份按 busy 返回，备份进行中恢复提示稍候。⑨ **已知缺口与后续方案（批40b 登记，未在本批实现）**——（a）未配置备份路径时回退目录 `Documents/backup` 在 Android/iOS 上属应用私有目录，**用户无法通过文件管理器直接取用**；后续方案：Android 走 `getExternalStorageDirectory`/SAF 可见目录、iOS 在 `UIFileSharingEnabled` 下暴露 Documents，或在设置页提供「本地备份列表/分享/导出」入口（推荐后者，跨平台一致）。（b）设置页「仅保留最新备份」（`onlyLatestBackup`）当前**只落偏好、备份链路未消费**：本地备份从不清理历史文件；后续方案：备份成功后按开关删除同目录旧的 `legado_backup_*.json`（保留最新），并配合上述本地备份列表展示。（c）WebDAV 客户端批40b 起设 connect 15s / 控制请求总超时 60s / 文件传输总超时 600s；自动链路不再无限占用互斥锁，但超时值暂不可由用户配置。
>

### 2.29 下载管理器（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `downloadAddTask({required String bookUrl, required String chapterUrl, required String chapterTitle, required int chapterIndex, int priority = 0})` | bookUrl, chapterUrl, chapterTitle, chapterIndex, priority | `Future<String>` | 添加下载任务，返回任务 ID（**字符串**，opaque 标识符，非数字序号） |
| `downloadGetStats()` | 无 | `Future<String>` | 获取下载统计信息 JSON |
| `downloadListByBook(String bookUrl)` | bookUrl | `Future<String>` | 获取指定书籍的下载任务 JSON |
| `downloadPauseAll()` | 无 | `Future<void>` | 暂停所有下载 |
| `downloadResumeAll()` | 无 | `Future<void>` | 恢复所有下载 |
| `downloadRemoveTask(String taskId)` | taskId（字符串 opaque ID） | `Future<void>` | 移除下载任务 |
| `downloadUpdateProgress(String taskId, double progress)` | taskId（字符串 opaque ID）, progress | `Future<void>` | 更新下载进度 |

### 2.30 段评（3 个方法，书源 ruleReview）

> **口径**：`reviewGetSummary` / `reviewGetDetail` / `reviewGetReplies` 为书源 `ruleReview` 路径（对齐原版 ReadBook / ReviewDetailDialog / ReviewController）。  
> **已移除**（F3-15）：本地库 CRUD（`reviewGetByChapter` / `reviewAdd` / `reviewDelete` / `reviewLike`）——原版 Android 无本地段评表/CRUD，属重构偏离创意，已从 FFI 与 BookApi 删除。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `reviewGetSummary(String sourceJson, String requestJson)` | sourceJson, requestJson | `Future<String>` | 段评摘要（对标 `ReadBookActivity.loadReviewSummary*` + `ReviewRuleParser.parseSummary` / JS `getReviewSummary`）。返回 `{"counts":{"1":5},"keys":{"1":"paraData"}}`（键为段落索引字符串；仅 count>0 的段）。requestJson：`chapterUrl`；可选 `book`/`chapter` JSON。规则缺失/未启用返回空 maps（非异常） |
| `reviewGetDetail(String sourceJson, String requestJson, int page)` | sourceJson, requestJson, page | `Future<String>` | 段评详情分页（对标 `ReviewDetailDialog.loadDetailPage` + `parseDetailPage` / JS `getReviewDetail`）。返回 `{"items":[DetailItem...],"nextPageUrl":String?,"hasReplyUrl":bool}`。requestJson：`paraIndex`/`paraData`/`chapterUrl`；可选 `detailUrl`（翻页直连）、`book`/`chapter`。条目字段同 `reviewGetReplies`，另含 likeCount/replyCount/replies |
| `reviewGetReplies(String sourceJson, String requestJson, int page)` | sourceJson, requestJson, page | `Future<String>` | 按需加载段评回复（上游 #519），返回 `{"items": [...], "nextPageUrl": String?}` 对象包装（含分页 URL，非裸数组）；requestJson 支持 reviewId/paraIndex/paraData/chapterUrl/replyUrl 字段；回复条目字段：id/avatar/name/badges/content/imageUrl/audioUrl/time |

### 2.31 书籍导出（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `bookExport({required String bookUrl, required String format, required bool includeToc})` | bookUrl, format, includeToc | `Future<Map<String, dynamic>>` | 导出书籍，返回 ExportResult JSON |
| `bookExportInfo({required String bookUrl, required String format})` | bookUrl, format | `Future<Map<String, dynamic>>` | 获取导出预览信息 |

### 2.32 自动任务（auto_task FFI）（14 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `autoTaskBuildBookUpdateTask({required String bookUrl, required String bookName, required String bookAuthor, required String name})` | bookUrl, bookName, bookAuthor, name | `Future<Map<String, dynamic>>` | 构建书籍更新定时任务 |
| `autoTaskUpdateCronBatch({required String rulesJson, required String idsJson, required String cron})` | rulesJson, idsJson, cron | `Future<List<Map<String, dynamic>>>` | 批量更新 cron 表达式 |
| `autoTaskPrepareImported({required String localTasksJson, required String importedJson})` | localTasksJson, importedJson | `Future<List<Map<String, dynamic>>>` | 准备导入任务 |
| `autoTaskExecute({required String protocolJson})` | protocolJson | `Future<Map<String, dynamic>>` | 执行任务协议 |
| `autoTaskExecuteWithId({required String protocolJson, required String taskId})` | protocolJson, taskId（自动任务规则 ID，字符串 UUID/主键，非下载 taskId） | `Future<Map<String, dynamic>>` | 带任务 ID 执行任务协议 |
| `autoTaskNormalizeScript({required String script})` | script | `Future<String>` | 规范化脚本 |
| `autoTaskCanRefreshBookToc({required bool canUpdate, required bool respectCanUpdate})` | canUpdate, respectCanUpdate | `Future<bool>` | 判断书籍是否允许刷新目录 |
| `autoTaskFindBookUpdateTask({required String tasksJson, required String bookUrl, required String bookName, required String bookAuthor})` | tasksJson, bookUrl, bookName, bookAuthor | `Future<Map<String, dynamic>?>` | 查找书籍更新任务 |
| `autoTaskNextDueAt({required String cron, required int fromMs})` | cron, fromMs | `Future<int>` | 解析 cron 表达式计算下次执行时间 |
| `autoTaskListRules()` | 无 | `Future<List<Map<String, dynamic>>>` | 列出所有自动任务规则（数据库 CRUD） |
| `autoTaskCreateRule({required String ruleJson})` | ruleJson | `Future<String>` | 创建自动任务规则（数据库 CRUD） |
| `autoTaskUpdateRule({required String ruleJson})` | ruleJson | `Future<void>` | 更新自动任务规则（数据库 CRUD） |
| `autoTaskDeleteRule({required String id})` | id | `Future<void>` | 删除自动任务规则（数据库 CRUD） |
| `autoTaskFindRuleById({required String id})` | id | `Future<Map<String, dynamic>?>` | 根据 ID 查询自动任务规则（数据库 CRUD） |

### 2.33 音频播放模式（audio FFI）（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `audioWithPlayMode({String? readConfig, required int playMode})` | readConfig(可选), playMode | `Future<String>` | 将播放模式写入 readConfig JSON |
| `audioResolvePlayBook({String? requestedBookUrl, String? cachedBookJson})` | requestedBookUrl(可选), cachedBookJson(可选) | `Future<Map<String, dynamic>?>` | 解析听书书籍 |

### 2.34 压缩包导入（10 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `archiveImportZip({required String zipPath, required String outputDir})` | zipPath, outputDir | `Future<Map<String, dynamic>>` | 导入 ZIP 压缩包中的书籍文件 |
| `archiveImportRar({required String rarPath, required String outputDir, String? password})` | rarPath, outputDir, password(可选) | `Future<Map<String, dynamic>>` | 导入 RAR 压缩包中的书籍文件 |
| `archiveListZipFiles({required String zipPath})` | zipPath | `Future<List<String>>` | 列出 ZIP 压缩包中的书籍文件名 |
| `archiveListRarFiles({required String rarPath, String? password})` | rarPath, password(可选) | `Future<List<String>>` | 列出 RAR 压缩包中的书籍文件名 |
| `archiveImport7z({required String sevenZipPath, required String outputDir})` | sevenZipPath, outputDir | `Future<Map<String, dynamic>>` | **2026-10-27 批24 新增**：导入 7z 压缩包中的书籍文件（解压后仅取书籍后缀；**恒返回** `{success, extracted_files, error}` 信封，失败不抛 BridgeError；async + spawn_blocking，批24b） |
| `archiveList7zFiles({required String sevenZipPath})` | sevenZipPath | `Future<List<String>>` | **2026-10-27 批24 新增**：列出 7z 压缩包中的书籍文件名（只读头部、不解压；**失败抛 BridgeError**，async + spawn_blocking，批24b） |
| `archiveDetectEncoding({required String filePath})` | filePath | `Future<Map<String, dynamic>>` | 检测 TXT 文件编码 |
| `archiveConvertEncoding({required String filePath, required String fromEncoding, required String toEncoding})` | filePath, fromEncoding, toEncoding | `Future<Map<String, dynamic>>` | 转换 TXT 文件编码 |
| `archiveIsArchive({required String filePath})` | filePath | `Future<bool>` | 判断文件是否为压缩包格式 |
| `cbzReadPage({required String path, required String entry})` | path: 本地 CBZ 书 `bookUrl`（绝对路径，或相对可迁移标识——经 `resolve_local_book_path` 同语义解析）；entry: ZIP 条目名（兼容带/不带 `cbz://` 前缀，中文/空格原样） | `Future<String>` | **2026-10-03 批 B 加法式新增（E9 参考版扩展，用户已授权；纯 FFI，尚未封装进 BookApi）**：读取 CBZ 漫画单页图片字节，返回 JSON `{base64, len}`（与 `fetchImageWithDecode`/图片缓存同惯例）。配合 §2.6 链路：`getChapterContent` 返回 `cbz://<条目名>` 行列表，Dart 侧逐行调用本方法取图。错误语义：文件不存在 / ZIP 解析失败 / 条目不存在 / 包内无图片条目 → 抛 BridgeError |

> ℹ️ **§2.34 批24 补记：7z 解压导入（2026-10-27，用户已授权）**
>
> **新增方法**：`archiveImport7z` / `archiveList7zFiles`（Rust `ffi::archive_import_7z` / `ffi::archive_list_7z_files`，核心实现 `legado-book/src/archive.rs::import_7z_file` / `list_7z_book_files`，FFI 包装 `legado-ffi/src/api/archive_import_api.rs`）。7z 能力下沉到 `legado-book`（非 quickjs），无 QuickJS 的 v7a 构建同样可用。
>
> **实现选型**：`sevenz-rust2 0.24`（Apache-2.0、纯 Rust、MSRV 1.93 满足工具链 1.97.1），`default-features=false`（默认 features 会引入 aes256/bzip2/ppmd 与重复 crypto 依赖）。同批将 `legado-js` 的 `sevenz-rust2` 0.12.1 → 0.24（features `compress`,`util`），`SevenZReader` → `ArchiveReader`；0.12.1 存在 CVE-2026-61725（7z 条目名路径穿越，0.21.1 修复），升级后 JS 宿主 `un7zFile` 同获修复。
>
> **语义**：解压后只取书籍后缀（`.txt/.epub/.mobi/.pdf/.umd/.azw3/.azw`）逐个 dispatch（对齐原版 `ArchiveUtils` 解压后按书籍后缀导入）；输出文件名取条目 basename（与 zip/rar 一致，中文/空格/大写扩展名原样）。列表只读 7z 头部、不解压、不写盘。
>
> **限额（fail-closed，超限整包失败）**：输入文件 512 MiB；单条目解压 256 MiB（按实际读取字节计数，不信任声明值）；全部条目解压总量 512 MiB（含非书籍条目的 drain 字节，solid 7z 必须读尽以触发 CRC）；条目数 10000；LZMA/LZMA2 字典 128 MiB（LZMA props[1..5] LE u32；LZMA2 `(2|(p&1))<<(p/2+11)`，p>40 视为超限）。解码线程固定单线程（`set_thread_count(1)`）。
>
> **路径安全（fail-closed）**：条目名 `\`→`/` 后逐组件拒绝 `..`、绝对路径（含 `//` 前缀）、Windows 盘符（`X:`）、空字节；**任一不安全条目 → 整包拒绝**（不静默跳过）；写盘只用 basename 并经既有 `safe_output_path` 二次校验；书籍条目先写 `.part`，成功 rename（Windows 先删旧目标），失败删除 `.part`。
>
> **错误语义**：`archiveImport7z` **恒返回信封** `{success, error, extracted_files}`，以下情形均以 `success:false` + 中文 `error` 返回、**不抛 BridgeError**（与 zip/rar 同型）：签名错误 / 不支持的 7z 版本 / CRC 校验失败 / 截断或结构损坏 / 需要密码（`PasswordRequired`）/ 含 AES 编码器（识别为加密包）/ 不支持的压缩算法 / 解码内存超限 / IO 错误 / 限额与路径安全错误，文案前缀 `7z导入失败:`。`archiveList7zFiles` 失败**抛 BridgeError**，`message` 形如 `Book parsing error: 7z列表失败: <原因>`（`Book parsing error:` 为 `LegadoError::BookParse` 的 Display 前缀）。
>
> **不支持项（明确登记；与原版 libarchive 无密码回调口径一致）**：加密 7z（不显示密码框、不尝试密码）、分卷 7z（`.001` 分卷）、PPMd / BZip2 / Deflate / LZ4 / Zstd / Brotli 压缩方法。支持 COPY / LZMA / LZMA2 及 BCJ 系列过滤器 / Delta。
>
> **契约先行日期 2026-10-27**：本节文档改动先于 Rust/Dart 代码落盘。

> ℹ️ **§2.34 批24b 审查回修（2026-10-27）**
>
> **错误语义（修正批24 表述）**：`archiveImport7z` **恒返回信封**（见上条）；`archiveList7zFiles` 失败抛 `BridgeError`。批24b 同时消除了列表错误的双层前缀（内层 `Book parsing error:` 不再出现在 `7z列表失败:` 之后），最终消息为 `Book parsing error: 7z列表失败: <原因>`。
>
> **头部解码内存（残余风险 + 纵深防御；批24c 归因修正）**：`sevenz-rust2 0.24.1` 解码使用 `MAX_MEM_LIMIT_KB = usize::MAX/1024`（等同无上限），恶意头可声明超大 LZMA 字典致 OOM（仅 DoS，无 RCE）。**上游 `init_archive` 已先拒绝 `next_header_size > reader_len`**（声明值不得超过实际文件长度），因此打开前自读 32 字节签名头并把 `NextHeaderSize`（offset 20..28，LE u64；offset 12..20 是 `NextHeaderOffset`）限制在 64 MiB 内属**纵深防御**——进一步收紧明文头部缓冲区，**不是修复某个已知 OOM**；签名错误/头部不足亦在此阶段给出中文错误。伪造头单测见 `archive.rs::test_import_7z_rejects_oversized_header_before_open` 等。**未缓解向量**：编码头（EncodedHeader）解码输出经 `take(unpack_size).read_to_end` 按实际解码字节增长，编码头内部 LZMA 字典在 `ArchiveReader::open` 期间按属性分配（`check_7z_archive` 的字典检查发生在其后）；即**仅头部明文缓冲区受限，解码内存未缓解**，残余风险登记于 `docs/RESIDUAL_RISKS_2026-08-13.md`（7Z-1）。
>
> **同名 basename（P3-2）**：同包内多个条目 basename 相同，按出现顺序命名为 `name.ext` / `name_2.ext` / `name_3.ext`…（大小写不敏感文件系统 Windows/macOS/iOS 折叠大小写去重，Linux/Android 精确比较；批24c 补入 iOS/macOS）；列表与解压使用同一命名，选中列表项即可导入对应文件，不再「后者覆盖前者」造成数据丢失。输出目录中**既有同名文件**仍按原 zip/rar 语义覆盖（`test_import_7z_overwrites_existing_output`）。
>
> **Windows ADS（P3-4）**：Windows 上条目名含 `:`（如 `ab:cd.txt`）整包拒绝——冒号会被解释为备用数据流（ADS），既不产生同名文件也可能被安全软件拦截；非 Windows 平台冒号是合法文件名字符，不受影响。用例 `test_import_7z_rejects_windows_ads_name`（`#[cfg(windows)]`，断言整包拒绝且输出目录不创建）。
>
> **阻塞模型（P2-2）**：`archiveImport7z` / `archiveList7zFiles` 为 `async` + `spawn_blocking`（对齐 `directLinkUpload` 范式），单线程解压/头部解析在阻塞线程池执行；Dart 签名不变（仍为 `Future<...>`），FRB 生成物为 `wrap_async`。真实 DLL 用例见 `flutter_legado/test/ffi/archive_7z_runtime_test.dart`（含大包导入期间事件循环响应性断言；**仅本机/Windows 开发机执行，CI 不覆盖**）。**例外**：阻塞任务 panic/JoinError（如线程池关闭、栈溢出等非业务异常）时 `archiveImport7z` 可能抛 `BridgeError` 而非 `success:false` 信封；正常业务失败仍恒返回信封。
>
> **块级 CRC（P3-8，上游限制登记）**：`sevenz-rust2 0.24.1` 校验 StartHeaderCRC / NextHeaderCRC，并在读取条目流时校验块 CRC（单子流块）或子流 CRC（`file.has_crc`）；**PackInfo 中的 pack stream CRC 解析后不校验**，多子流块且缺少子流 CRC 时无条目级完整性保护。损坏通常仍会在解码或声明长度处失败；本批不额外实现 CRC（需复刻上游解析），登记于残留风险（7Z-2）。
>
> **`legado-js` 依赖面（P3-6）**：`sevenz-rust2` 生产 features 由 `compress+util` 收窄为 `util`（生产只用 `decompress_file`），`compress` 移入 dev-dependencies 仅供测试构造夹具——生产二进制不带 7z 编码器，Cargo.lock 版本不变。
>
> **契约计数**：批24b 零新增方法，§2.34 = 10、附录合计 312、BookApi 309、§1.7 表 B 146 均不变。

> ℹ️ **§2.34 批24c 审查回修（2026-10-27）**
>
> **大小写不敏感去重（P2-1）**：输出名去重策略按平台判定——`FOLD_OUTPUT_NAME_CASE = cfg!(any(windows, target_os = "macos", target_os = "ios"))`。Windows（NTFS）、macOS（APFS 默认）与 iOS 的默认文件系统大小写不敏感，`A.txt` / `a.txt` 会指向同一目录项；折叠后第二个条目命名 `a_2.txt`，避免 rename 相互覆盖。Linux/Android 默认大小写敏感，保持原名。策略经 `dedupe_output_name(base, used, next_seq, fold_case)` 参数化，单测 `test_dedupe_output_name_fold_case_policy` 覆盖两支。
>
> **list/import 命名一致（P3-4）**：`for_each_entries` 的访问顺序与 `archive.files` 文件序不同（有数据条目先访问，无流零字节条目最后统一访问）。import 改为按文件序预计算输出名（`plan_book_output_names`），回调按 basename 队列取用；零字节/无流条目与同名真实条目并存时，输出名集合与列表一致（不再出现列表外的 `_3` 后缀）。重复项之间名称对应可互换（列表本就不区分同 basename 条目）；夹具 `test_import_7z_empty_and_nonempty_same_name`（空 `a.txt` + 非空 `a.txt` + 真实 `a_2.txt` → `a.txt` / `a_2.txt` / `a_2_2.txt`）。
>
> **去重复杂度（P3-5）**：`HashMap<基名, 下一序号>` 替代每次从 `_2` 起的线性扫描，整体 O(n)；命名规则不变（首个原样、后续 `_2`/`_3`…，被真实条目占用的序号跳过）。
>
> **契约计数**：批24c 零新增方法，§2.34 = 10、附录合计 312、BookApi 309、§1.7 表 B 146 均不变。

> ℹ️ **§2.34 批24d 导入缺陷回修（2026-10-27，P1：交错条目漏文件）**
>
> **根因**：`sevenz-rust2 0.24.1` 的 `BlockDecoder::for_each_entries` 与 `ArchiveReader::read_file` 的 solid 分支都以 `block_first_file_index[b] .. + num_unpack_sub_streams` 连续索引遍历 `archive.files`，隐含假定同一块内的有流条目连续。7z 规范允许目录/无流条目（`kEmptyStream` 位图）与文件条目交错（py7zr 等打包器默认如此），连续区间撞到无流目录条目后提前结束，后续文件被静默跳过；列表走 `archive.files`，故出现「列表完整、导入缺失」且无错误（设备验收 D1）。
>
> **修复（`legado-book/src/archive.rs`）**：① **权威清单**——仍按 `archive.files`（原始文件序）经 `plan_book_output_names` 预计算输出名，列表口径不变；② **块区间归一化**——导入前 `normalize_7z_block_file_ranges` 按块重排内存文件表（各块有流条目在前、无流条目在后）并重写 `stream_map.file_block_index`/`block_first_file_index`，使每个块的连续区间恰好覆盖其全部子流；不改名称/大小/CRC，`blocks` 与 `num_unpack_sub_streams` 不变，`ArchiveReader::from_archive` 重建名称索引后 `read_file` 的 solid 分支同获修复；③ **缺失回退**——主迭代按输出名记录已写出集合，未覆盖条目回退 `read_7z_entry_strict`（`read_file` 逐条读取 + 声明长度校验），缺失/空读/半截读一律整包报 `7z 条目读取不完整 [名称]（声明 N 字节，实际读取 M 字节）`，不静默成功；④ **顺序一致**——落盘与 `extracted_files` 按原始文件序返回，与 `archiveList7zFiles` 一致。交错布局与回退触发时经 `eprintln!` 输出一行诊断（Android 走 logcat），不改变 FFI 返回值。
>
> **限额/安全**：回退读取同样计入总解压量限额（声明大小已在 `check_7z_archive` 逐条校验）；临时 `.part` + 整包成功后 rename 的回滚语义不变。回退仅对「主迭代未覆盖」条目发生，normal 包不产生额外解压。
>
> **测试**：`test_import_7z_interleaved_nested_entries` / `test_import_7z_interleaved_dirs_and_books`（py7zr 生成夹具 base64 内联，断言 list 与 import 集合/顺序/内容一致）、`test_normalize_7z_block_file_ranges_interleaved`、`test_read_7z_entry_strict_fallback_and_incomplete_errors`（回退读取 + 缺失/长度不符报错）；真实 DLL 用例 `flutter_legado/test/ffi/archive_7z_runtime_test.dart` 增「交错布局包」回归。
>
> **契约计数**：批24d 零新增方法，§2.34 = 10、附录合计 312、BookApi 309、§1.7 表 B 146 均不变。

> ℹ️ **§2.34 批32 补记（2026-10-29）：zip/rar 导入限额与路径安全对齐 7z（零新增方法）**
>
> **背景**：7z 导入已有限额与路径安全（§2.34 批24 系列），但 zip 导入/列表与 rar 桩仍是旧实现——无输入/条目数/单条目/总量限额，zip 直接 `read_to_end` 到内存后写最终文件（无 `.part` 回滚），rar 无任何限额。
>
> **实现（`legado-book/src/archive.rs`）**：① **同口径限额（fail-closed，默认值即生产限额）**——输入包 ≤512 MiB（打开前按文件元数据预检）、条目数 ≤10000、单条目 ≤256 MiB、全部条目解压总量 ≤512 MiB；**声明值与实际读取字节双计数**（`zip` 条目声明大小仅用于快速失败，解压循环按实际读到的字节累计；rar 同理按 `data.len()` 计数，声明值 `unpacked_size` 另行校验）。② **路径安全 fail-closed**——条目名校验抽为共用实现 `validate_archive_entry_name(raw, label)`（zip/rar/7z 同一实现）：`\`→`/` 后逐组件拒绝 `..`、绝对路径、盘符、空字节（Windows 另拒 `:`/ADS）；**任一不安全条目（含目录/非书籍条目）→ 整包拒绝**。③ **`.part` 失败清理**——zip/rar 解压先写 `.legado_zip_<i>.<名>.part` / `.legado_rar_<i>.<名>.part`，整包成功后才 rename（Windows 先删旧目标）；任一失败（限额/CRC/IO/路径）删除全部 `.part` 且不触碰既有输出文件。④ **CRC**——zip 读取到条目 EOF 时由 `zip` crate 校验 CRC，损坏统一报 `解压文件失败 [...]（文件可能损坏或 CRC 校验失败）`；声明大小与实际读取不一致另报 `ZIP 条目读取不完整`。⑤ **rar 平台口径不变**——Android/iOS 仍为明确不支持桩（不再进入限额/路径代码），可解析平台（桌面）限额与路径校验生效。
>
> **测试（`archive.rs`）**：正常 zip（既有 basic/list/empty 用例保持）、条目数超限（list+import）、单文件超限、总量超限、输入包超限、路径穿越/绝对路径/混合非书籍不安全条目整包拒绝、CRC 损坏后 `.part` 清理与既有输出不变、共用条目名校验三格式标签、rar 输入限额预检（桌面）。**契约计数**：批32 零新增方法（§2.34 = 10、附录合计 313 中 zip/rar 相关行数不变）。

> ℹ️ **§2.34 批32b 审查回修（2026-10-29，零新增方法）**
>
> **落位回滚统一（P2-1，取代批32 的「Windows 先删旧目标」表述）**：zip/rar/7z 的 `.part` → 最终输出统一走 `land_pending_files`（`legado-book/src/archive.rs`）：① 任一落位失败清理 `pending` 中**全部剩余**临时文件（旧实现 `for (temp, out) in pending` 消费式迭代只删当前 temp 就 `return`，剩余 `.part` 残留）；② Windows 覆盖既有输出改为「既有目标先 rename 到 `.legado_bak_<i>.<name>.bak` → 临时文件 rename 成功 → 删除备份」，失败时恢复备份并回滚已落位项（旧实现先 `remove_file(out)` 再 rename，rename 失败即永久丢失既有输出）；非 Windows 仍由 POSIX rename 原子替换；③ 既有目标为目录/符号链接等非常规文件时整次落位失败（不移动/删除用户数据）。用例：`test_import_zip_landing_failure_cleans_all_parts_and_keeps_existing`、`test_import_7z_landing_failure_cleans_all_parts_and_keeps_existing`、Windows 回滚 `test_import_{zip,7z}_landing_failure_restores_backed_up_output`。
>
> **同名 basename 口径登记（P3-1）**：模块文档原写「同名 basename 按序号去重，不互相覆盖」与实现不符。实际：**7z** 同包同名 basename 按文件序去重（`novel.txt`/`novel_2.txt`，list 与 import 同命名）；**zip/rar** 保持旧语义——同包同名 basename 后者覆盖前者（list 按条目原样返回重复名，不做去重），本文档模块注释已同步修正。本批不改变 zip/rar 行为；如需去重另立批次评估（会影响既有 list/import 输出名与选中映射）。
>
> **测试补强（P3-2）**：① 伪造 ZIP central directory 的 uncompressed size（4096 → 16）绕过声明预检，验证「实际读取字节」计数分支（`test_import_zip_actual_read_limit_with_forged_declared_size`，命中 `ZIP 单条目超限` 而非声明分支 `ZIP 单条目过大`）；② CRC 断言精确化——`zip 2.4.2` 无 `ZipError::InvalidChecksum` 变体，CRC 失败为 `io::Error(InvalidData, "Invalid checksum")`（`crc32::Crc32Reader` 在条目 EOF 返回），导入错误文案与底层变体各有精确断言（`test_zip_crc_corruption_is_invalid_checksum_io_error`）。**覆盖面说明**：实际读取计数的对抗性夹具仅在 zip 可构造（central directory 明文大小可改）；rar 无编码器（见下 ARC-1）、7z 头受 CRC 保护无法低成本伪造声明尺寸——7z 的「声明 ≠ 实际」路径由 `read_7z_entry_strict` 长度校验单测覆盖（`test_read_7z_entry_strict_fallback_and_incomplete_errors`），流式读取的 `total_read` 计数与 zip/rar 同源代码审读确认、未构造对抗夹具，登记于此。
>
> **RAR 验证缺口登记（P3-3，limitation）**：仓库无 RAR 夹具（`unrar` 仅解压、无编码器），RAR 的解析级限额（声明大小/实际读取/条目数）、条目名路径安全、`.part` 回滚与 Windows 备份落位**仅由与 zip/7z 共用的代码保证，未被单测覆盖**；现有 RAR 用例仅输入大小预检（`test_rar_input_size_limit_precheck`）。另有实现口径：`unrar::Archive::read()` 一次性返回整条数据（内存峰值受声明大小限额约束），非流式。已登记 `docs/RESIDUAL_RISKS_2026-08-13.md`（ARC-1）。
>
> **iOS RAR 桩文案（P3-5）**：`import_rar_file`/`list_rar_book_files` 的桩错误文案由「Android 平台暂不支持 RAR 解压」改为「当前平台暂不支持 RAR 解压」（Android/iOS 共用同一 `cfg`，原文案在 iOS 上表述错误）。
>
> **Mock 语义偏差（P3-4）**：`MockBookApi.updateReadConfigField` 注释已列明三处偏差（无原始 JSON 层/未建模键不可见、未知键 no-op、bool 键收非 bool 值被强转；真实实现对已建模键类型校验并拒绝），并补 `splitLongChapter` 分支。
>
> **契约计数**：批32b 零新增方法，§2.34 = 10、附录合计 313、BookApi 310、§1.7 表 B 147 均不变。

### 2.35 RSS 已读记录（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `rssMarkRead(String origin, String title, {String? link, int type = 0, String? sort, String? image, String? pubDate, int? durPos})` | origin, title, link/type/sort/image/pubDate/durPos(可选) | `Future<void>` | 标记 RSS 文章为已读（2026-10-27 批20 扩展全列写入）。对齐原版 `RssArticle.toRecord()`（`RssArticle.kt:66-76`）：`type` 0 网页 / 1 图片 / 2 视频、`sort` 分类名、`image` 封面、`pubDate` 发布时间（TEXT）、`durPos` 阅读进度。缺省 `type=0`、`sort=''`、`image/pubDate=NULL`、`durPos=0`；旧调用不传行为不变。同主键重复标记按 `INSERT OR IGNORE` 忽略（批20b 审查对齐原版 `RssReadRecordDao` 的 `OnConflictStrategy.IGNORE`：不刷新 `readTime`、不改写扩展列） |
| `rssIsRead(String link)` | link | `Future<bool>` | 判断文章是否已读（按 link 匹配） |
| `rssIsReadByTitle(String origin, String title)` | origin, title | `Future<bool>` | 判断文章是否已读（按 origin+title 匹配） |
| `rssClearReadRecords({String? origin})` | origin(可选) | `Future<void>` | 清空已读记录。**仅 `null` 清空全部**；`origin` 非空（含空串）时按 trim 后 origin 精确过滤——空串/纯空白删除 0 行，**不得**退化为清空全部（对齐原版 `RssReadRecordDao.deleteAllRecord(origin)` 的 WHERE 语义；2026-10-28 批29，批29b 审查 P1-1 修正）。旧调用不传参数行为不变 |
| `rssReadRecordCount()` | 无 | `Future<int>` | 获取已读记录总数 |
| `rssListReadRecords({int? limit})` | limit(可选，默认100) | `Future<List<RssReadRecordRow>>` | 获取已读记录列表（按 readTime 降序）。返回行字段：`origin` / `title` / `link` / `read_time` / `type` / `sort` / `image` / `pubDate` / `durPos`（2026-10-27 批20 扩展，旧数据 `type=0`、`sort=''`、`durPos=0`、`image/pubDate=NULL`） |
| `rssListReadRecordsByOrigin(String origin, {int? limit})` | origin, limit(可选，默认100) | `Future<List<RssReadRecordRow>>` | 按 RSS 源 origin 获取已读记录（对齐原版 `getRecordsByOrigin`，F3-17）；返回行字段与 `rssListReadRecords` 一致（2026-10-27 批20） |

> ℹ️ **RSS 阅读记录开关 + 按源清空（2026-10-28 批29；批29b 审查回修）**：① **全局开关**——原版 `AppConfig.enableRssReadRecord`（`AppConfig.kt:631-635`，默认 `true`；`ReadRss.kt:51` 写入前判定）由 Flutter `SharedPreferences` 键 `enableRssReadRecord` 承载（对齐原版 `PreferKey.enableRssReadRecord`，**不进 FFI/DB**）；两处写入口（`rss_articles_screen.dart::_recordReadIfEnabled`（列表打开）与 `rss_article_detail_screen.dart::_openBridgeRss`（桥动作打开，经 `_handleBridgeOpen` 分发））在调用 `rssMarkRead` 前判定，且经 `RssReadRecordPrefNotifier.resolved()` 等待 SharedPreferences 异步加载完成（进程首启首击不漏判），关闭后不新增记录、已有记录保留、重新开启恢复写入；开关 UI 在全局（`rss_screen.dart`）与按源（`rss_articles_screen.dart`）两个阅读记录对话框均提供（原版 `menu_enable_record` 仅在 origin 为空的全局对话框可见，按源对话框为批29 需求显式提供）。② **按源开关**——`RssSource.enableReadRecord` 仅字段往返保真，不参与运行期（批28 已登记；原版同样只保留字段）。③ **按源清空**——`rssClearReadRecords({origin})` 等价原版 `ReadRecordDialog` 的「清空」：`origin == null` 清空全部；`origin` 非空按 trim 后精确过滤（**空串删除 0 行，不再退化为清空全部**——批29b 审查 P1-1，改前一处空 origin 即丢全部源记录）；DB `RssReadRecordRepository::clear_by_origin` 同口径 trim，全量清空唯一入口 `clear_all`；`ReadRecordDialog` 的开关菜单项在客户端实现（见上①）。④ **确认框文案（批29b 审查 P2-1）**——按源与全局清空确认框均**不再显示条数**：列表入口只加载最近 100 条（`rssListReadRecords{,ByOrigin}` 默认 limit），而清空删的是该源/全部记录，条数必然低报，文案改为「确定清空当前源的全部阅读记录？」/「确定清空全部阅读记录？」。⑤ **清空失败/刷新失败分段提示（批29b 审查 P3-1）**——`RssHistoryNotifier.clear` 返回清空动作本身的失败文案（`null` = 清空成功）；UI 对「清空失败」与「清空成功但刷新记录失败」分别提示，清空成功不再误报失败。 |

> ℹ️ **RSS 历史记录 type 扩展（2026-10-27 批20）**：① **写路径**——`rssMarkRead` 的 `type/sort/image/pubDate/durPos` 经 `legado-ffi/src/api/rss_read_record_api.rs::mark_read_full` → `legado-db::RssReadRecordRepository::mark_read_with` 写入 `rssReadRecords` 全列（`INSERT OR IGNORE`，主键 `record` 语义不变；批20b 审查 P2-1 对齐原版 `RssReadRecordDao.insertRecord` 的 `OnConflictStrategy.IGNORE`——首次标记决定 `readTime`，重复打开不刷新 `readTime`、不改写扩展列）；Dart `BookApi.rssMarkRead` 由位置可选参数改为**命名可选参数**（`link` 同批改为命名参数，与本节签名一致），调用方需同步。② **读路径**——`RssReadRecordRow` 新增 `type`（JSON `type`）/`sort`/`image`/`pubDate`/`durPos`（JSON 键 `pubDate` / `durPos`，对齐原版 Room 列名；`read_time` 保持既有 snake_case 不变）；`list_records` 与 `list_records_by_origin` 两入口 SELECT 列集合与行映射完全一致。③ **旧数据兼容**——DB 列早已存在（Room v95 结构，无迁移）：`type` / `sort` / `durPos` 为 `NOT NULL`（旧行读出 `0` / `''` / `0`），`image` / `pubDate` 可空（旧行读出 `null`）。④ **历史入口分流**——`rss_screen.dart::_openRecord` 用 `record.type/sort/image/pubDate` 构造 `RssFeedArticle`，`resolveRssArticleType` 在 `record.type` 非 0 时与 `ReadRss.kt:25-45` 严格对齐（0 网页 / 1 图片 / 2 视频），`type=0` 回退源 `type` 为已登记兼容超集（原版无此回退）；`rss_articles_screen.dart::_openDetail` 打开文章时同批透传 `article.type/sort/imageUrl/pubDate`。⑤ **`durPos` 状态**——当前仅 FFI/DB 预留：`rssMarkRead` 可写、记录可读，UI 无消费（视频进度写入后续批接线；文章详情入口不传该参数）。

### 2.36 正文高亮（highlight FFI）（12 个方法）

> 对齐上游 `BookHighlight` / `HighlightRule` 实体与 DAO（DB v96-v99）。
> JSON 字段名对齐 Room 列名（camelCase）：BookHighlight 含 `time` / `bookUrl` / `chapterUrl` / `bookName` / `bookAuthor` / `chapterIndex` / `chapterPos` / `chapterPosEnd` / `layoutTitleLength` / `chapterName` / `bookText` / `style` / `note`；HighlightRule 含 `id` / `uuid` / `name` / `pattern` / `isRegex` / `scope` / `isEnabled` / `style` / `sortOrder` / `timeoutMillisecond` / `group` / `applyToTitle` / `applyToBody`（2026-10-28 批28：`group` 为规则分组，对齐原版 `HighlightRule.group`，DB 列 `"group" TEXT DEFAULT ''`；随 `highlightRuleList` / `highlightRuleSave` / 备份 `highlightRules` 与原版 zip `highlightRule.json` 原样往返）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `highlightAdd({required String highlightJson})` | BookHighlight JSON（time=0 时自动分配） | `Future<int>` | 新增/更新高亮记录，返回 time 主键 |
| `highlightDelete({required int time})` | time | `Future<bool>` | 按主键删除高亮记录，返回是否实际删除 |
| `highlightDeleteByBook({required String bookUrl})` | bookUrl | `Future<int>` | 按书籍删除全部高亮，返回删除数量 |
| `highlightListByBook({required String bookUrl})` | bookUrl | `Future<String>` | 按书籍获取高亮列表（BookHighlight 数组 JSON） |
| `highlightListByChapter({required String bookUrl, required int chapterIndex})` | bookUrl, chapterIndex | `Future<String>` | 按书籍+章节获取高亮列表（BookHighlight 数组 JSON） |
| `highlightSearch({required String keyword})` | keyword | `Future<String>` | 全局关键词搜索高亮（bookText/note，BookHighlight 数组 JSON） |
| `highlightListAll()` | 无 | `Future<String>` | 获取所有高亮记录（BookHighlight 数组 JSON） |
| `highlightRuleList()` | 无 | `Future<String>` | 获取所有高亮规则（按 sortOrder 升序，HighlightRule 数组 JSON） |
| `highlightRuleSave({required String ruleJson})` | HighlightRule JSON（id=0 时自增新增） | `Future<int>` | 保存高亮规则，返回规则 ID |
| `highlightRuleDelete({required int id})` | id | `Future<bool>` | 按 ID 删除高亮规则，返回是否实际删除 |
| `highlightRuleFindEnabled({required String bookName, required String origin})` | bookName, origin | `Future<String>` | 按书籍查找启用的高亮规则（scope 匹配书名或 origin，HighlightRule 数组 JSON） |
| `highlightRuleMatch({required String text, String bookName = '', String origin = '', bool applyToTitle = false, int? maxMatches})` | text（待匹配文本）, bookName/origin（scope 过滤，空=仅全局规则）, applyToTitle（false=匹配正文侧规则，true=匹配标题侧规则）, maxMatches（null=默认 10000，≤0 返回空） | `Future<String>` | 按启用高亮规则匹配文本，返回 `HighlightRuleMatch[]` JSON（元素 `{ruleId, start, end, order, styleJson}`，区间为 UTF-16 code unit 半开区间，见下方语义注） |

> ℹ️ **`highlightRuleMatch` 匹配语义与 MVP 渲染边界（2026-10-29 批34，契约先行）**：
> - **规则来源与过滤**：`HighlightRuleRepository::find_enabled_by_book(bookName, origin)`（`isEnabled=1` + scope 为空/包含书名或 origin，按 `sortOrder` 升序）；再按 `applyToTitle` 选侧（false→`applyToBody`，true→`applyToTitle`）。空 pattern 跳过。`styleJson` 为规则 `style` 原文（可为空串；Dart 侧解析并保留未知键）。
> - **字面量**（`isRegex=false`）：非重叠子串查找（对齐原版 `indexOf` + `from=end` 循环）；空 pattern 跳过。
> - **正则**（`isRegex=true`）：先做 Java 方言适配（复用 `legado-core::content_processor::adapt_java_regex`：`\uXXXX`→`\x{XXXX}`、`\R` 展开、移除 `(?d)/(?c)/(?u)` 内联标志），再走 `legado-core::regex_safe` 统一安全入口（**1KB pattern 上限 + 非递归嵌套深度 ≤32 预检**），`regex` crate 编译失败时回退 `fancy-regex`（lookbehind/backreference/原子组；backtrack 上限 100 万）。两路均失败 → `log::warn!` 跳过该规则（对齐原版 `runCatching` 降级）。**Java 方言差异登记**：`\Q...\E` 引号块、字符类交集 `[a-z&&[^bc]]`、`\p{IsHan}` 等 Java 专有写法不保证等价；`\G`、`\A`/`\z` 边界语义按 Rust 方言执行。扫描不做大小写不敏感等隐式开关（Java `Pattern.compile` 默认同样大小写敏感）。
> - **重叠与优先级**：高 `order`（`sortOrder`）覆盖低 `order`；同 `order` 先命中者胜；被覆盖/部分重叠的候选按区间差集**截断**或整段**跳过**。最终区间互不重叠，按 `(order 升序, start 升序)` 稳定输出。同一 `ruleId` 可输出多段。
> - **限额与超时**：正文 `text` UTF-8 字节数 > **1 MiB** → 报错（不截断）；整体截止 **5s**，单规则截止取规则 `timeoutMillisecond`（夹取 **1..=5s**）并受整体截止约束（取二者较早者）；每规则/每批命中前检查，**任一截止到期（单规则超时或整体超时）即中止剩余规则**并保留已收集结果（对齐原版「单规则超时不再继续后续规则」语义，批34b P2-3 补记）；warn 文案区分「单规则匹配超时（规则 id + 上限 ms）」与「整体匹配超时（5s）」；候选命中总数受 `maxMatches` 限制（缺省 **10000**，对齐原版 `DEFAULT_MAX_MATCHES`；`≤0` 返回空数组）。
> - **偏移口径**：`start/end` 为 **UTF-16 code unit** 偏移（与 Dart `String`/Kotlin 一致；Rust 内部匹配为 UTF-8 字节偏移，出口统一换算；非 BMP 字符按 2 个 code unit 计）。
> - **渲染范围（MVP，不改字体度量）**：阅读页正文 `Text.rich` 应用 `textColor`（前景色）/ `fill`（背景色，**统一矩形**）/ `underline`（`TextDecoration.underline`，颜色与粗细生效，`distance` 不生效）/ `strike`（`lineThrough`）。**不渲染**：`fillShape` 的 ROUNDED/MARKER/HALF/BASELINE/PILL 形状（按矩形降级）、`bold`/`italic`（会改字体度量而分页未重算，本批明确不启用，避免命中行宽度漂移与溢出）、`box`/`emphasis`/`shadow`/`fontPath`/`fontSize`/`letterSpacing`/`horizontalPadding`/`pillPaddingScale`（背景图/九宫格/边框不实现）。标题侧高亮（`applyToTitle=true` 的实际渲染）与**相邻章预载预览页**不在本批（FFI 已支持标题侧匹配；预览页属相邻章偏移，套用当前章命中会染错位置，批34b P3-6 登记）。**2026-11-13 批29/批32 补全**：①**highlights 表（用户手动高亮）的正文渲染已接入**——批29 起按章 `highlightListByChapter` 加载并与规则命中、`book_marks` 三方合并，优先级 **笔记标记 > 用户手动高亮 > 规则命中**（依据参考版 `HighlightMatcher.resolve` 的 `HighlightStyle.merge` 由 manual 覆盖规则）；保存后经 `bookHighlightsRevisionProvider` 立即重拉当前章。②**滚动模式（`PageTurnMode.scroll`）高亮已接入**——批32 起滚动模式同样加载规则命中与手动高亮，`ReaderTextContent` 与回退 `ReaderParagraphs` 均按章节坐标求交后用 `TextSpan` 只染色选区；CRLF 正文的段尾 `
` 不计入染色区间；整章命中只排序一次（父级下传 `matchesStartSorted`），正常有序路径每行/段游标单向推进无 O(n²)。命中结果按 `(bookUrl, chapterIndex, 文本长度, 文本 hash, 规则修订号)` 在 Dart 侧缓存，滚动/翻页不重复跨 FFI；匹配失败（异常/超时）降级为无高亮，同章失败后按短退避最多重试一次（单 key 最多尝试 2 次，批34b P2-4），不每帧重试。
> - **批34c 设备验收回修（2026-10-29，方法签名与返回结构不变）**：① **Java ASCII 字符类**——`adapt_java_regex` 按 Java 默认（未开启 `UNICODE_CHARACTER_CLASS`）改写预定义类：`\w`→`[0-9A-Za-z_]`、`\W`→`[^0-9A-Za-z_]`、`\d`→`[0-9]`、`\D`→`[^0-9]`、`\s`→`[ \t\n\x0B\f\r]`、`\S`→`[^ \t\n\x0B\f\r]`；字符类内用去括号形式（`[\w-]`→`[0-9A-Za-z_-]`），取反类用 Rust 嵌套字符类（`[a\W]`→`[a[^0-9A-Za-z_]]`）；`\\w` 等转义对整体保留不误替换，类首字面量 `]` 不改变类状态；pattern 含 `(?u)` 时保留 Rust 原生 Unicode 语义（不做 ASCII 改写）。效果：`关键词\w*` 只吞 ASCII 词字符（不吞汉字），`\d` 不匹配全角数字。② **下划线/删除线颜色回退**——`underline.color`/`strike.color` 为 0/未设时按原版 `HighlightDraw.drawRun` 的 `fallbackColor = textColor ?: 正文色` 回退：先取规则 `textColor`，规则也无则交正文色绘制；显式线色仍优先（`decorationColor` 共用限制见批34b P3-7）。③ **日志可见性**——`legado-ffi` 新增 `log_bridge`（`ffi::init` 安装）：`log` 记录转 Android logcat（tag `legado-rust`），默认 `warn` 级、`LEGADO_LOG_LEVEL` 可调，高亮降级 warn（无效正则/超时）设备可见。
> - **样式能力差异登记（批34b P3-7）**：Flutter `TextStyle.decorationColor`/`decorationThickness` 对 `underline` 与 `lineThrough` **共用**——两者同时存在时装饰色取 `underline.color`（下划线无色则退到 `strike.color`），粗细统一取 `underline.width`；原版 `HighlightStyle` 可分别配置下划线与删除线颜色/粗细，属 Flutter `TextStyle` 表达能力限制，按「取其一」降级渲染。

> ℹ️ **style 字段保真与渲染边界（2026-10-29 批33；方法签名不变）**：`HighlightRule.style` 为原版 `HighlightStyle` 完整 JSON（`fill` / `fillShape` / `textColor` / `bold` / `italic` / `underline` / `strike` / `box` / `emphasis` / `shadow` / `fontPath` / `fontSize` / `letterSpacing` 等）。Flutter 编辑表单只编辑文字颜色，保存改为**原 JSON 补丁**（`mergeHighlightStyleTextColor`：仅覆盖 `textColor`，其余键与未知键原样保留），不再重建只剩颜色的 style；Dart 模型补 `styleMap` / `styleFill` / `styleBold` / `styleItalic` / `styleUnderline` 供预览展示。**渲染仍未接线**：正文绘制高亮 style（fill/underline/bold/strike/stroke 等）不在批33，后续专项；当前字段保真只保证「导入 → 编辑 → 导出/保存」不丢数据。**批34 起接线范围**：正文前景色/背景色（矩形）/下划线/删除线已渲染；粗体/斜体因改字体度量仍不启用，圆角/马克笔/半高/PILL/边框/阴影/字号/字距/字体不渲染（见上方批34 注）。

### 2.37 JS 单文件书源配置（JsSourceConfig 对齐）（3 个方法）

> 对齐 Kotlin `JsSourceConfig.kt`：extract 配置提取 / stampLastUpdateTime 时间写回（#208/#515）/ 语法检查（#479）。
> extract 需 QuickJS 构建（`--features quickjs`），非 quickjs 构建返回错误；语法检查非 quickjs 构建降级为括号平衡基础检查。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `jsSourceExtract({required String content})` | content（完整 JS 书源脚本） | `Future<String>` | 执行脚本提取顶层 config/source 配置（BookSource JSON，mainJs 回填完整脚本）；缺必备函数/配对校验失败报错 |
| `jsSourceSyntaxCheck({required String content})` | content（待检查 JS 脚本） | `Future<String>` | 语法检查（SyntaxCheckResult JSON：`valid` / `message` / `line`）；quickjs 下只编译不执行 |
| `jsSourceStampLastUpdateTime({required String content, required int stamp})` | content（JS 书源脚本）, stamp（新时间戳毫秒） | `Future<String>` | 写回顶层 config/source 对象的 lastUpdateTime（仅替换数字字面量或 Date.now()）；无可替换位置返回空字符串 |

### 2.38 应用日志（app_log FFI，Task #79）（5 个方法）

> 对齐 Kotlin `AppLog.kt` / `AppLogDialog.kt`（旧欠账 + 上游 #512/#524/#543）。
> Rust 侧进程级环形缓冲（每级上限 500 条，最新在前），三级独立：`message` / `crash` / `http`（大小写不敏感）。
> 日志条目 JSON 字段：`timestamp`（毫秒）/ `level` / `message`（对齐 Kotlin `Triple<Long, String, Throwable?>`）。
> 导出文本格式 `yyyy-MM-dd HH:mm:ss.SSS [LEVEL] message`，时间升序，超 64_000 字符按字符边界截断（对齐 #543 `MAX_SHARE_TEXT`）。
> 纯内存缓冲、无 DB 依赖，任意时机可调用；日志页面 UI 由 UI 轨后续接入（与 Flutter 现有 `CrashLogService` 文件型崩溃日志互补，不重复）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `appLogPush({required String level, required String message})` | level（message/crash/http）, message | `Future<void>` | 写入一条日志；非法级别抛 BridgeError，空消息忽略（对齐 Kotlin `put` 的 null 短路） |
| `appLogList({required String level})` | level | `Future<String>` | 获取指定级别日志列表（裸 JSON Array，最新在前，对齐 §1.4 铁律） |
| `appLogClear({required String level})` | level | `Future<void>` | 清空指定级别日志 |
| `appLogClearAll()` | 无 | `Future<void>` | 清空全部级别日志（对齐 #543 清空确认后的 AppLog.clear + HttpLogStore.clear） |
| `appLogExport()` | 无 | `Future<String>` | 导出全部日志为格式化文本（时间升序，64_000 字符截断，对齐 #543） |

### 2.39 规则订阅（rule_sub FFI，Task #89）（7 个方法）

> 对齐 Kotlin `RuleSub.kt` 实体与 `RuleSubActivity.kt`（列表 CRUD / 拖拽排序 / 自动更新 / 静默更新 / 更新间隔）。
> DB v100（Rust 轨自有扩展）：rule_subs 表补全 Kotlin RuleSub 字段 `customOrder` / `autoUpdate` / `updateInterval` /
> `silentUpdate` / `js` / `showRule` / `sourceUrl`（Migration99To100，幂等补列，不动 v95-v99 高亮体系迁移）。
> RuleSub JSON 字段：`id` / `url` / `name` / `sub_type`（bookSource/replaceRule/rssSource）/ `last_update` / `version` /
> `is_enabled` / `created_at` / `customOrder` / `autoUpdate` / `updateInterval` / `silentUpdate` / `js` / `showRule` / `sourceUrl`（新增 7 字段对齐 Kotlin 驼峰命名）。
> 检查/应用更新委托 `legado-net` rule_update_client（should_update / fetch_subscription / merge_subscription）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `ruleSubList()` | 无 | `Future<String>` | 获取订阅列表（RuleSub 数组 JSON，按 customOrder 排序） |
| `ruleSubSave({required String subJson})` | RuleSub JSON | `Future<bool>` | 新增/更新订阅（id>0 且存在则更新，否则新增） |
| `ruleSubDelete({required int id})` | id | `Future<bool>` | 删除订阅，返回是否实际删除 |
| `ruleSubSetEnabled({required int id, required bool enabled})` | id, enabled | `Future<bool>` | 切换启用状态，返回记录是否存在 |
| `ruleSubUpdateOrder({required String idsJson})` | idsJson（新顺序 ID 数组 JSON） | `Future<bool>` | 拖拽排序：按索引重写 customOrder（0 起） |
| `ruleSubCheckUpdate({required int id})` | id | `Future<String>` | 检查更新（检查结果 JSON：`id` / `url` / `name` / `dueForUpdate`（should_update 间隔判定）/ `hasUpdate`（远程版本对比）/ `remoteVersion` / `error`） |
| `ruleSubApplyUpdate({required int id})` | id | `Future<String>` | 应用更新（应用结果 JSON：`id` / `url` / `success` / `itemsAdded` / `itemsUpdated` / `itemsRemoved` / `totalItems` / `error`；合并后回写版本号与最后更新时间） |

### 2.40 本地 TXT 全文搜索（txt_search FFI，Task #98 缺口#4）（4 个方法）

> 对齐既有 C ABI 4 函数（`ffi_txt_search` / `ffi_txt_search_regex` / `ffi_txt_search_in_chapter` / `ffi_txt_search_count`），
> 本小节为其 frb 主链路暴露（包装 `legado-book::txt_search::TxtSearch` 引擎），供 Flutter 侧本地 TXT 书内搜索调用。
> 返回裸 JSON Array（遵守 §1.4 铁律），每项字段（snake_case）：`chapter_index` / `chapter_title` / `char_offset` /
> `matched_text` / `context` / `context_match_start` / `context_match_end`（TxtSearchResult 序列化）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `txtSearch(String path, String query, {bool caseSensitive = false, int maxResults = 500})` | path: TXT 文件路径，query: 关键词 | `Future<List<Map<String, dynamic>>>` | 纯文本全文搜索（章节感知 + 上下文摘要） |
| `txtSearchRegex(String path, String pattern, {bool caseSensitive = false, int maxResults = 500})` | path, pattern: 正则表达式 | `Future<List<Map<String, dynamic>>>` | 正则全文搜索，返回格式同上 |
| `txtSearchInChapter(String path, String query, int chapterIndex, {bool caseSensitive = false, int maxResults = 50})` | path, query, chapterIndex（0 起） | `Future<List<Map<String, dynamic>>>` | 指定章节内搜索，返回格式同上 |
| `txtSearchCount(String path, String query, {bool caseSensitive = false})` | path, query | `Future<int>` | 匹配总数计数（不返回完整结果，供 UI 显示） |

### 2.41 契约外已实现 FFI 补登记（2026-08-06 审计，5 个方法）

> 以下函数已在 `rust/legado-ffi/src/ffi.rs` 实现并生成 Dart 绑定（`ffi.dart`），但此前未登记本契约（违反 §1.2「新增 API 须同步更新文档」），本节为补登记（承接 REMAINING_PLAN §4.2.2 P1-3）。其中多数尚未封装进 `BookApi` 抽象层，UI 封装计划见 §3「待 UI 封装清单」。
>
> **注（2026-08-07，Task #139）**：原 QUIC 系列 8 个函数（quicCreateClient / quicGet / quicPost / quicPerformanceTest / quicIsInitialized / quicCleanup / netSetQuicEnabled / netIsQuicEnabled）属原版不存在的新增能力，按「项目目标是纯重构」的用户决策已整体移除，不再作为契约项。

**其他（5 个）**

| 函数 | 所属模块 | 说明 |
|------|----------|------|
| `backupList` | 备份操作（§2.11 扩展） | 列出备份文件——✅ 已封装 `BookApi.backupList`（F3-20） |
| `cacheGetChapter` | 缓存管理（§2.16 扩展） | 获取已缓存章节内容（离线缓存 UI 批次依赖）——✅ 已封装接通（本次评审修复提交，`RustApi.getCachedChapter` 封装，书架菜单缓存导出） |
| `bookGroupSetShow` | 书籍分组（§2.14 扩展） | 设置分组显示状态——✅ 已封装 `BookApi.bookGroupSetShow`（F3-20） |
| `httpTtsSetEnabled` | HTTP TTS（§2.25 扩展） | 启用/禁用 HTTP TTS 配置——✅ 已封装 `BookApi.httpTtsSetEnabled`（F3-20） |
| `dictLookup` | 词典（§3 需求 4） | 词典释义查询——✅ 已封装 `BookApi.dictLookup`（F3-10 补登记） |

### 2.42 TTS 真实合成管线（Task #113 批次 2 缺口②，2 个方法）

> 对齐 Kotlin 原版 `HttpReadAloudService.getSpeakStream` + `AnalyzeUrl(speakText/speakSpeed)` 模型：
> url 模板占位符替换 → HTTP 请求获取音频二进制 → Content-Type 校验（`application/json` / `text/*` 视为服务器报错）→
> 以「模板+文本+语速」MD5 命名缓存到本地（命中直接返回路径，避免重复请求）。
> Flutter 侧 `audioSpeak`（§2.26）当前为 `http.get` 探活 fallback，UI 轨后续改接 `ttsSpeak` 真实管线。
>
> **占位符约定**：`{{speakText}}` / `{{text}}`（朗读文本，URL 编码后替换）、`{{speakSpeed}}` / `{{speed}}`（语速）。
> **缓存目录**：默认为系统临时目录下 `legado_tts_cache`，可通过 `ttsSetCacheDir` 覆盖（建议 UI 轨初始化时传入应用缓存目录）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `ttsSpeak({required String text, required String engineUrl, double speed = 1.0})` | text: 朗读文本，engineUrl: 引擎 URL 模板，speed: 语速 | `Future<Map<String, dynamic>>` | TTS 真实合成。返回字段（camelCase）：`audioPath: String`（本地音频文件绝对路径）/ `fromCache: bool`（是否缓存命中）/ `contentType: String`（音频 MIME 类型）。服务器返回 json/text 时以响应体文本抛出 BridgeError |
| `ttsSetCacheDir(String path)` | path: 缓存目录绝对路径 | `Future<bool>` | 设置 TTS 音频缓存目录（全局生效） |

### 2.43 缓存写/购买/批量下载/导出扩展（Task #136 R5+R6+R7+R8，11 个方法）

> Task #136 合并批次，均为**加法式**新增（不改既有签名/行为）。仅走 frb 主链路（`ffi.rs`），
> 旧式 C ABI（`bridge.rs`）已按 Task #136 R12 冻结新增并标注 DEPRECATED，故本批不在 C ABI 面暴露。

#### 2.43.1 R5 缓存写（1 个方法）

> 缓存系 FFI 此前仅读侧（§2.16 + §2.41 `cacheGetChapter`），写侧补齐：
> 复用 `legado-db` `CacheBookRepository.insert`（INSERT OR REPLACE），供阅读器「编辑内容/反转」闭环回写章节缓存。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `saveChapterContent({required String bookUrl, required int chapterIndex, required String title, required String content, String chapterUrl = ''})` | bookUrl, chapterIndex（0 起）, title（空串=从 DB 章节表回填）, content（正文原文，不做净化）, chapterUrl（空串=从 DB 章节表回填） | `Future<bool>` | 写入/覆盖单章缓存（cached_chapters 表），cached_at=当前毫秒、size_bytes=content 字节数；写入后可经 `cacheGetChapter` 读回一致 |

#### 2.43.2 R6 章节购买（1 个方法）

> 对齐 Kotlin `ReadBookActivity.payAction`：取书源 `ruleContent.payAction`（js 或含 `{{js}}` 的 url，空则报错 "no pay action"）→
> 复用登录 V2 JS 执行基础设施（书源 URL 分桶引擎池 + `eval_with_bindings`）执行，注入绑定 `baseUrl`=章节 url、
> `title`=章节标题、`book`/`chapter`=实体 JSON 对象、`source`=书源对象（Kotlin 另注入 java/result/src，Rust `java` 命名空间已全局注册，result/src 原版即为 null）。
> **结果语义（对照 Kotlin onSuccess）**：返回绝对 URL → UI 打开支付页 WebView；返回 "true" → 购买成功（Kotlin 随后清当前章缓存并刷新目录，UI 轨自行对应）；其他 → 原样回传。
> **R6 留项（F4-8，2026-08-14）**：含 `{{js}}` 的 URL 模板形态依赖 Android WebView 注入执行，Rust 侧**仅实现纯 JS 脚本**路径；URL 模板形态登记为后续留项（见 `pay_action_api.rs` 模块注释），不影响当前纯 JS payAction 书源。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `chapterPayAction({required String bookUrl, required int chapterIndex})` | bookUrl（本地书短路返回 kind=none，对齐 Kotlin isLocal 短路）, chapterIndex | `Future<String>` | 结果 JSON（camelCase）：`{"kind": "url"/"success"/"none", "value": "<JS 返回原文>"}`；kind=success 时 Rust 侧已清当前章正文缓存；需 quickjs 构建，否则返回 JsEngine 错误 |

#### 2.43.3 R7 缓存批量下载（4 个方法）

> 对标 Kotlin `CacheActivity` + `CacheBook` 批量缓存下载。运行态为进程内内存表（独立 worker 线程 + `AtomicBool` 取消令牌，
> worker 不用 tokio spawn 因正文抓取链路含 `block_on` 不可嵌套；取消对齐 §2.3 `cancelCheckSources` 的书源校验流机制）；
> **进度快照落库**至 `caches` 表（键前缀 `cacheDownloadTask:` / 索引 `cacheDownloadTaskIndex`，重启后恢复进行中任务并续跑；
> 终态任务亦可经 `cacheDownloadProgress`/`List` 回读）。逐章复用正文抓取链路 `get_chapter_content_full`
> （缓存命中免网络 → 网络抓取 → 缓存写入；本地书走解析器 + R5 写缓存），失败章计入 failed 并继续。
>
> **批9b-2 并发语义（2026-10-31；含审查回修，零签名变化）**：**全局准入**——进程级同时只准入 **1 本书**的批量下载
> （Condvar 队列；排队任务在获得准入前不发起任何 HTTP，取消/重启恢复路径同样遵守）。每任务有效并发 = caches
> `config:threadCount` 在**任务启动时**读取并夹逼 **1..=8**（缺省 16 → 8；对齐参考版
> `CacheBook.maxDownloadConcurrency = 8` 与原版 `min(threadCount, AppConst.MAX_THREAD=9)` 线程池语义；`<1` → 1）。
> 任务内 N 个 worker 共享**原子派发游标**，每个章 index 恰好派发一次（无重复下载）；派发采用**滑动窗口 32 章**
> （`[连续完成前缀, 前缀+32)`），窗口外的章不派发、不进入内存/持久化集合，避免慢首章导致集合无限增长。
> **窗口 32 是快照有界性与预取的折中**：慢/挂起章会延迟后续派发（不做无界预取），以换取内存与持久化状态有界；
> 恢复时窗口外条目丢弃并扣减计数后重下（幂等）。
> `completed`/`failed` 计数与失败章集合仍是任务级原子/加锁状态，进度快照经任务级互斥串行落库。**取消语义**：取消置位后
> 不再派发新章（竞态窗口内最多再派发 N 章），已在途章（≤N）完成后停止并置 `cancelled`（单线程时代「当前章完成后停止」
> 的推广）；排队中任务取消后**不发起任何 HTTP**；若取消到达时全部章节已派发完毕，则保持 `completed`/`failed` 终态。
> **续跑语义**：持久化快照的 `nextIndex` 表示**连续完成前缀**（该值之前的章节均已尝试成功或失败），并新增有界
> `finishedChapters`（≥前缀且已完成、但前缀尚未推进的章 index，升序；长度上限 = 派发窗口 **32**，
> `#[serde(default)]` 兼容旧快照）——重启后续跑不跳过未完成章、不重复计数已完成章；超出窗口的旧快照记录在恢复时
> 丢弃并同步扣减计数（该章重下，幂等）。**panic 隔离**：worker 内 `download_one` 经 `catch_unwind` 包裹，panic 计为
> 该章失败并记录日志；终态仅在「全部章已尝试且 `completed+failed==total`」时判 `completed`，否则置 `failed`。
> 章节正文写入顺序由并发完成顺序决定（DB 按 `(book_url, chapter_url)` 唯一键各自落行），进度总数/成功失败计数与
> 逐章缓存结果不受影响。`threadCount` 变更从下一次 `cacheDownloadStart`（或重启后续跑任务）生效，进行中任务不热更新。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `cacheDownloadStart({required String bookUrl, required int startChapter, required int endChapter})` | bookUrl, startChapter/endChapter（章节 index，闭区间；越界自动收敛） | `Future<String>` | 创建并后台启动批量下载任务，返回任务 ID（字符串）；同一本书已有进行中任务时复用返回既有 ID；全局同时只准入 1 本书、任务内并发度见上方批9b-2 语义 |
| `cacheDownloadProgress(String taskId)` | taskId | `Future<String>` | 进度 JSON（camelCase）：`taskId`/`bookUrl`/`status`（running/completed/cancelled/failed/notFound）/`total`/`completed`/`failed` |
| `cacheDownloadCancel(String taskId)` | taskId | `Future<bool>` | 取消进行中任务：排队中任务不再发起任何 HTTP；已准入任务不再派发新章（竞态窗口内最多再派发 N 章），在途章完成后停止。返回任务是否存在 |
| `cacheDownloadList()` | 无 | `Future<String>` | 全部任务进度 JSON 数组（字段同上） |

#### 2.43.4 R8 书籍导出参数扩展（1 个方法）

> 加法式扩展：既有 `bookExport`（§2.31）签名与行为不变（缺省=现行为）。新方法以 `optionsJson` 透传参数，
> 对照 Kotlin `ExportBookService`（`AppConfig.exportCharset` 编码 / 章节范围 / `getExportFileName` 文件名规则）：
> - `encoding`：UTF-8（缺省）/ GB2312 / GBK / GB18030 / UTF-16 / UTF-16LE / ASCII（对齐 Kotlin `AppConst.charsets`），仅作用于 TXT；不可映射字符以 `?` 替代
> - `startChapter` / `endChapter`：章节 index 闭区间，缺省/`-1` = 不限
> - `fileNameTemplate`：`{name}` / `{author}` 占位符模板，缺省 = 现行为 `{书名}.{扩展名}`

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `bookExportWithOptions({required String bookUrl, required String format, required bool includeToc, String optionsJson = ''})` | bookUrl, format（txt/epub/html/pdf）, includeToc, optionsJson（`{"encoding":"GBK","startChapter":0,"endChapter":9,"fileNameTemplate":"{name} 作者：{author}"}`，空串=全缺省） | `Future<String>` | ExportResult JSON（同 §2.31 `bookExport` 返回结构） |

#### 2.43.5 目录页缓存态查询（Task #22，1 个方法）

> [UI-fix v2.0.6 | 2026-08-08] 加法式新增（不改既有签名/行为），仅走 frb 主链路（`ffi.rs`）。
> 目录页云图标缓存态数据源：复用 `legado-db` `CacheBookRepository.get_by_book`（按
> `book_url` 复合键查询，不串本），仅提取 `chapter_url`。对齐 Kotlin
> `item_chapter_list` 的 `iv_toc_cache`（已缓存实心云 / 未缓存空心云）。
>
> **[批39 空正文过滤（显示宽松口径）]** 对齐参考版 `TocViewModel`（显示用宽松判定
> `BookHelp.hasContent`：有正文即算已缓存；下载是否补图仍走严格口径）：
> - **只收正文非空的缓存行**：`cached_chapters.content.trim()` 为空的历史/异常写入行
>   不算已缓存（读侧 `get_chapter_cache` 同样按空正文视为 miss）；
> - **不检查章节内图片**：正文引用的图片未落盘（缺图）时该章**仍算已缓存**，
>   云图标照常点亮；下载链路（§2.43.3）不消费本集合，逐章严格抓取（缺图会重抓）；
> - 有目录的书同步过滤已退出当前目录的陈旧缓存行（[B-5]：按 `chapters` 表当前
>   `chapter_url` 集合校验），无目录记录的书保持既有行为。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `cacheListCachedChapterUrls({required String bookUrl})` | bookUrl | `Future<String>` | 已缓存 `chapter_url` 的 JSON 字符串数组（`["url1","url2",...]`，按 chapter_index 升序、空 url 与空正文行过滤）；Dart 侧 `RustApi.listCachedChapterUrls` 解析为 `List<String>` 供目录页渲染云图标 |

#### 2.43.6 目录页实时字数刷新查询（P2-28c，1 个方法）

> [P2-28c | 2026-09-28] 加法式新增（不改既有签名/行为），仅走 frb 主链路（`ffi.rs`）。
> 目录页实时刷新数据链：§2.43.5 的升级形态——单次只读查询（纯 SELECT）返回该书已缓存章节的
> (chapter_url, wordCount) 集合，使目录页 1 秒轮询（P2-28b）一次调用同时完成 URL 集合 diff
> （翻转「未缓存」⬇ 图标）与字数映射刷新（新缓存章的字数胶囊**同帧出现**，对齐参考版
> `ChapterListFragment` 订阅 `SAVE_CONTENT` 同帧刷行语义）。
> wordCount 取 `chapters` 表当前值（与 P2-28b 回填链同源，避免 `cached_chapters` 表内旧快照），
> 未回填为空串。过滤语义与 §2.43.5 一致：按 chapter_index 升序（repository 已排序）、空
> `chapter_url` 过滤；有目录的书同步过滤已退出当前目录的陈旧缓存行（[B-5] 同源）。
>
> **[批39 空正文过滤（显示宽松口径）]** 与 §2.43.5 同源：`content.trim()` 为空的缓存行
> 不收录（空正文不算已缓存）；正文非空但缺图仍收录（宽松显示）；下载链路不消费本集合，
> 保持逐章严格抓取。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `cacheListCachedChapters({required String bookUrl})` | bookUrl | `Future<String>` | 该书已缓存章节 url+wordCount 的 JSON 对象数组（`[{"url":"...","wordCount":"..."},...]`，按 chapter_index 升序、空 url 与空正文行过滤；wordCount 取 `chapters` 表当前值，未回填为空串）；Dart 侧 `RustApi.listCachedChapters` 解析为 `Map<String, String>`（url → wordCount，空 wordCount 不收录）供目录页实时字数胶囊渲染 |

#### 2.43.7 目录页下载中态查询（P2-29，1 个方法）

> [P2-29 | 2026-09-29] 加法式新增（不改既有签名/行为），仅走 frb 主链路（`ffi.rs`）。
> 目录页五态行 DOWNLOADING 态动画的数据链（对齐参考版 `TocViewModel` 的 `runningIndices`
> —— 源自 `CacheBook.downloadStateFlow` 全局状态流）：单次只读查询（进程内任务表纯读 +
> `ensure_restored` 落库恢复回读，**零写入**）返回该书当前在途下载章节的 index 集合，
> 目录页 1s 轮询（P2-28b/c）与 §2.43.6 同周期拉取，驱动下载中行渲染 16px 加载指示
> （对齐参考版 `AppContainedLoadingIndicator` 16dp 形态，用户可见行为对齐）。
> 在途章语义：§2.43.3 的 worker 并发逐章下载（批9b-2 起每任务 N 个 worker，N = `config:threadCount` 夹逼 1..=8），
> 故每 `running` 任务的在途章集合 = **当前正在抓取的全部章节 index（0..N 个）**：0 表示排队等待全局准入
> （同时只准入 1 本书）或窗口暂时填满但无请求在途；越出 `[start_chapter, end_chapter]` 闭区间不收录，
> 任务终态后不收录；单 worker（`threadCount=1`）时退化为至多一个在途章，语义与旧版一致。
> 无活跃任务的书籍返回空数组。
> **ERROR 态留项**：Rust 任务表仅有 failed 计数、无逐章失败记录（补齐需任务表
> 写路径改动，超出本批授权）→ 目录页 ERROR 分支先落（红色重试图标 + 单章重下点击），
> 数据源恒空（恒不显示，不伪造），待失败记录数据链补齐后接入。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `cacheDownloadRunningChapters({required String bookUrl})` | bookUrl | `Future<String>` | 该书批量下载（§2.43.3）当前在途章节 index 的 JSON 整型数组（升序、0-based；无活跃任务为空数组 `[]`）；Dart 侧 `RustApi.listDownloadingChapters` 解析为 `List<int>` 供目录页 DOWNLOADING 态动画 |
| `cacheDownloadFailedChapters({required String bookUrl})` | bookUrl | `Future<String>` | 该书批量下载**已失败**章节 index 的 JSON 整型数组（升序、0-based；无失败为空数组 `[]`）；Dart 侧 `RustApi.listFailedChapters` 解析为 `List<int>` 供目录页 ERROR 态（红色重试图标，可点击重试）。**数据链（P2-29c 后续，2026-10-05 用户裁决）**：`TaskInner` 与持久化快照（`cacheDownloadTask:` kv）新增**失败章索引集合**（对齐参考版 `CacheDownloadStateStore.markFailed/markSuccess` 语义：失败加入、成功/重试移除、任务启动清空）；`run_download` 失败分支从仅递增 `failed` 计数改为同时记入集合，成功分支从集合移除；恢复回读（`ensure_restored`）一并恢复失败集合；`persist_snapshot` 序列化含集合。查询为**纯任务表读 + 恢复回读**，零额外写入 |

---

### 2.45 字典规则操作（dict_rule FFI，7 个方法）

> [C2 批1 | 2026-09-13] 加法式新增（不改既有签名/行为）：字典规则 CRUD / 重排 / 导入经 frb 主链路（`ffi.rs` → `dict_api.rs`）暴露。
> 数据源 `dictRules` 表（`name` UNIQUE，按 `sortNumber` 排序）；`dictRuleList` 空表先注入原版默认 5 源（与 `dictLookup` 同 seed 语义）。
> 复杂类型以 JSON String 跨 FFI（§1.3）；`dictRuleReorder` / `dictRuleImport` 返回处理条数；解析/抓取失败返回**明确错误**（导入为显式动作，非静默跳过）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `dictRuleList()` | 无 | `Future<List<Map<String, dynamic>>>` | 列出全部字典规则（`ORDER BY sortNumber, id`）；空表先 seed 原版默认 5 源；每行 `{id, name, urlRule, showRule, enabled, sortNumber}` |
| `dictRuleAdd({required String name, required String urlRule, required String showRule})` | name / urlRule / showRule | `Future<int>` | 新增规则（enabled=1, sortNumber=0），返回新 ID；name 重复返回错误（UNIQUE 约束） |
| `dictRuleUpdate({required int id, required String name, required String urlRule, required String showRule})` | id / name / urlRule / showRule | `Future<bool>` | 按 id 更新规则（name/urlRule/showRule），返回是否实际更新 |
| `dictRuleDelete(int id)` | id | `Future<bool>` | 按 id 删除规则，返回是否实际删除 |
| `dictRuleSetEnabled({required int id, required bool enabled})` | id / enabled | `Future<bool>` | 按 id 启用/禁用规则，返回是否实际更新 |
| `dictRuleReorder(String idsJson)` | idsJson（JSON 数组 `[3,1,2]`） | `Future<int>` | 按给定 ID 顺序重编号 sortNumber=0..n（对标原版 upSortNumber），返回重排条数 |
| `dictRuleImport({required String jsonOrUrl, required String kind})` | jsonOrUrl / kind（text \| url） | `Future<int>` | 导入 GSON 数组/单对象规则（REPLACE by name：同名覆盖保留 id，异名插入）；kind=text 为 JSON 文本，kind=url 先经既有抓取链路取 body 再解析；返回导入条数 |

---

### 2.46 图片磁盘缓存（image_cache FFI，3 个方法）

> [P4-2a | 2026-09-29] 加法式新增（不改既有签名/行为）：漫画/图片书源图片的**磁盘缓存存取**，对齐原版 `BookHelp.saveImage`（L347+：`isImageExist` 命中即跳过 → 下载 → `writeImage` 写盘，写失败仅记日志**不抛异常**）与 `BookHelp.getImage`（L392+：返回缓存文件路径）+ `MangaVH.mangaImagePath`（L31-34：**本地优先**——缓存文件存在则取本地、否则走网络）语义。
> 目录结构对齐原版 `downloadDir/book_cache/{bookFolderName}/images/{md5_16(url)}.{suffix}`：缓存根目录经 `set_image_cache_dir` 进程注入（§1.6.1，Dart 启动时传应用私有缓存目录下 `image_cache` 子目录，与 `set_cache_dir` 同型；未注入回落 `<temp_dir>/legado-image-cache`）→ 书目录 = `sanitize(bookUrl)`（非法文件名字符替换 `_` 截断 64 字符 + `_{md5_8(bookUrl)}` 防截断碰撞，原版以 `book.getFolderName()` 为键、本书以 `bookUrl` 为键的加法式简化）→ `images/` → 文件名 = MD5(url) 小写 hex 中段 16 字符（原版 `MD5Utils.md5Encode16` = `hex[8..24]`）+ `.{suffix}`（原版 `UrlUtil.getSuffix(src, "jpg")`：URL 末段 `.` 后后缀，须匹配 `[A-Za-z0-9]{1,5}` 否则缺省 `jpg`）。
> 字节跨 FFI 走 base64 String（对齐 `fetchImageWithDecode` 的 `{base64, len}` JSON 惯例，§1.3 复杂类型 JSON 约定）：`saveImageCache` 入参 bytes 由 Dart 侧 base64 编码、`getImageCache` 返回 base64 由 Dart 侧解码。**写失败/读失败均降级**（save 返回 false、get 返回 null 并记一次性日志），不抛 FFI 异常——缓存是加速器不是数据源，失败必须不影响在线加载（对齐原版 saveImage catch 仅记 AppLog）。
> 书目录以 `bookUrl` 隔离（不同书互不串缓存）；图片文件按 URL 命名与 bookUrl 无关（同 URL 同书内幂等覆盖）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `saveImageCache({required String bookUrl, required String url, required List<int> bytes})` | bookUrl / url / bytes | `Future<bool>` | 图片字节落盘缓存（对齐原版 `writeImage`）：写入 `{缓存根}/{书目录}/images/{md5_16(url)}.{suffix}`；成功 `true`；base64 输入非法 / 目录创建失败 / 写盘失败返回 `false`（静默降级 + 一次性日志，**不抛异常**——不影响在线加载）。Rust FFI 面为 `save_image_cache(bookUrl, url, bytesBase64) -> Result<bool, BridgeError>`（base64 解码失败抛 Ffi 错，IO 降级返回 `Ok(false)`）；Dart 侧 `RustApi.saveImageCache` 捕获所有错误统一返回 `false` |
| `getImageCache({required String bookUrl, required String url})` | bookUrl / url | `Future<List<int>?>` | 读取磁盘缓存（对齐原版 `getImage`/`isImageExist` 的本地优先语义）：命中返回图片字节；未命中 / 读失败返回 `null`（降级走网络加载）。Rust FFI 面为 `get_image_cache(bookUrl, url) -> Result<Option<String>, BridgeError>`（base64 或 null；文件不存在与读失败均降级 `Ok(None)`） |
| `retainComicImages({required String bookUrl, required int durIndex, required int retain, required int preDownload})` | bookUrl / durIndex / retain / preDownload | `Future<int>` | 删除本书不在「已读保留窗口」内的图片缓存（对齐原版 `BookHelp.clearComicCache`）：`retain<=0` → 直接返回 0（不清理）；非图片书（`bookType` 无图片位）→ 返回 0。窗口 = `[durIndex-retain, durIndex+preDownload]`（`start<0` 截 0），经 `CacheBookRepository::get_by_book_index_range` 只取窗口内 `cached_chapters` 行（不整书装载正文），逐章以 `(bookUrl, chapter.url)` 匹配正文。**窗口必需集**：当前章必须有非空正文（缺失/空白或当前章为卷章 → 整次跳过）；后窗（`index < durIndex`）章节缺失正文 → 整次跳过（保守）；前窗（`index > durIndex`）章节缺失正文 → 仅跳过该章；卷章 `is_volume` 一律跳过。逐章解析正文图片 URL（`<img src>` 四分支正则，完整支持 `url,{json headers}` 复合尾，单/双引号；无 `<img>` 时回退图片 URL 行且剥 `,{json}` 判后缀），以 `AnalyzeUrl::get_absolute_url(chapter.url, src)` 绝对化（复合 URL 原样保留，与阅读器缓存键同源）；每章 `chapter.imgUrl` 作为阅读器首图一并纳入保留集合。保留文件名 = `md5_16(url).suffix`（`MD5Utils.md5Encode16` = 小写 hex `[8..24]`；`UrlUtil.getSuffix(src,"jpg")` 同 §2.46）。仅删除 `{缓存根}/{书目录}/images` 下**直接普通子文件**中不在保留集合者（不递归、不跟随符号链接；集合为空时整次跳过；单文件删除失败跳过并计一次告警）。返回实际删除文件数；DB/IO 失败降级 0（一次性日志），**不抛 FFI 异常**。Rust FFI 面为 `retain_comic_images(bookUrl, durIndex, retain, preDownload) -> Result<i32, BridgeError>`（实现 `legado-ffi/src/api/image_cache_api.rs`）；Dart 侧 `RustApi.retainComicImages` 捕获异常统一返回 0 |

> **批9b-3 回修注（2026-11-03）**
> - **窗口必需集与「阅读早期跳过」**：后窗缺正文时整跳是本实现的有意保守（原版对缺正文章仅逐章跳过，可能误删该章图片）；代价是阅读早期（后窗章节尚未缓存）保留清理不生效，随阅读推进后窗补齐后自然恢复。前窗缺正文仅跳过该章，避免默认 `preDownloadNum=10`、实际只预载 ±1 时每次整跳。
> - **复合 URL**：`<img src="https://cdn/a.webp,{\"headers\":{...}}">` 必须完整保留（原版 `AppPattern.imgPattern` 允许尾 `}"`；Dart `comicImgSrcRegex` 四分支），否则 md5 与阅读器写盘键不一致会误删当前章图片。
> - **URL 绝对化差异（登记，本批不改缓存键）**：Rust 沿用原版 `AnalyzeUrl::get_absolute_url`（协议相对按 base scheme、保留端口）；Dart 阅读器 `_resolveImageUrl` 对 `//` 恒用 `https:` 且 `Uri.host` 丢端口。极端 `http` 章节 + 协议相对图片或非默认端口时，可能误删一张随渲染重下的图片（无数据损坏），后续统一两端口径。
> - **清理与预载竞态（登记）**：Dart 触发器串行化并只执行最后一次排队任务，后窗/前窗分别保护已读与预载章节；未加额外延迟去抖，避免引入退出后定时器与测试不确定性。卷章跳过、图片目录符号链接跳过、非 UTF-8 文件名跳过均有单测覆盖。

---

### 2.47 音频章节文件缓存（audio_cache FFI，4 个方法）

> [B1 | 2026-10-04] 加法式新增（不改既有签名/行为）：**音频章节音频文件的磁盘缓存只读面与清理面**，对齐原版 `AudioCacheManager` / `AudioPlay` 语义。
> **缓存键规则（严格对齐原版 `app/.../model/AudioCacheKey.kt:20-23`）**：`AudioCacheKey(MD5Utils.md5Encode16(chapterUrl.ifBlank { chapterTitle }))` —— 取**章节 URL**（为空才退回章节标题）的 MD5 小写 hex 中段 16 字符；**不含** `url + "|" + title` 拼接、**不含** bookUrl。`md5Encode16` 口径 = hutool MD5、小写 hex、`hex[8..24)`、UTF-8 字节、**不 trim、大小写敏感**（`MD5Utils.kt:29-33`；Rust 侧逐字节对齐先例见 `image_cache_api.rs:148` / `encoding.rs:36`）。
> **书级目录**：`{缓存根}/book_{md5Encode16(bookUrl)}`（原版 `AudioCacheManager.kt:210,228`，**即时计算、原版无映射表亦无 DB 记录**）→ 故 bookUrl 必须逐字符一致才能归位，跨应用不可直读原版目录（沙箱不继承 SAF 授权）。
> **命中判定（简化自原版 `AudioCacheManager.kt:201-203,358-373`）**：命中 = `key16` 匹配 **且** `.complete` 标记文件存在 **且** 音频文件 `size > 0`；同名多条取 `lastModified` 最新者。文件名五段式中的 title / playUrlHash / rev 三段**不参与命中判定**，仅过正则（`AudioCachePolicy.kt:11-13`）。**`.complete` 必须随行校验**：缺标记者原版眼中即不存在，导入/读取一律跳过。
> **只读面 + 清理面（不设写入面）**：按用户裁决（2026-10-04）「按原版做法」——原版写入只发生于预下载服务 `AudioCacheService`（`AudioCacheService.kt:217` 为全仓唯一 `cacheChapter` 调用方），**播放链从不写**（`AudioPlay.kt:388-413` 播放第一步查缓存、命中完全跳网络）。故本节**不登记任何写入方法**；写入面已于 2026-10-03 B2 批冻结至 **§2.48**（`audioCacheDownload` / `audioCacheCancel`，与本节写读同根同键）。
> **不纳入应用内备份**：原版官方备份产物为单一 zip（`help/storage/Backup.kt:122-131,416`，备份项见 `:52-98`），**不含音频缓存**（`help/storage` 包与备份 UI 中 `AudioCache*`/`LegadoAudioCache` 零命中；prefs 快照仅携带 `audioCacheTreeUri` 目录 URI 字符串，`BackupConfig.kt:101-116`）。按用户裁决（2026-10-04）**我方备份同样不含音频缓存**，故本节**不登记导入/导出方法**。
> 旧键 `${bookUrl.hashCode}_$i.audio`（重构版自创，`audio_screen.dart:996` 唯一引用、**无读取方**）按用户裁决**默认不读、不迁移**（按下标命名，目录重排后必错位且 `hashCode` 碰撞无从校验）。
> 失败一律降级（查询/列举返回空、清理返回实际删除数），**不抛 FFI 异常**——缓存是加速器不是数据源（同 §2.46 口径）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `audioCacheQuery({required String bookUrl, required int chapterIndex, required String chapterUrl, required String chapterTitle})` | bookUrl / chapterIndex / chapterUrl / chapterTitle | `Future<bool>` | 查询某章是否已缓存（**只读、幂等**）：按原版键规则计算 `key16` → 在 `{缓存根}/book_{md5_16(bookUrl)}` 下判定 `key16` 匹配 + `.complete` 存在 + size>0。`chapterUrl` 为空时用 `chapterTitle`（原版 `ifBlank` 语义）。目录不存在/无权限/解析异常一律返回 `false`（不抛异常）。Rust FFI 面为 `audio_cache_query(bookUrl, chapterIndex, chapterUrl, chapterTitle) -> Result<bool, BridgeError>` |
| `audioCacheList({required String bookUrl})` | bookUrl | `Future<List<int>>` | 列出该书**已缓存章节的章节下标数组**（**只读、幂等**）：扫描书目录内文件名，按原版五段式正则解析出章节序号与 `key16`（过不了正则的文件跳过并计数），仅返回通过 `.complete` + size>0 校验的条目，按章节下标升序。无缓存返回空数组 |
| `audioCacheClearChapter({required String bookUrl, required int chapterIndex, required String chapterUrl, required String chapterTitle})` | 同 `audioCacheQuery` | `Future<int>` | 清理某章缓存，返回**实际删除的文件数**（**仅统计数据文件，不计 `.complete` 标记**——对齐原版 `AudioCacheManager.kt:338-356`；**幂等**：不存在或已删返回 `0`，不抛异常）。只删该 `key16` 下的音频文件与标记（标记照删、只是不计入返回值），不触碰同目录其他章节 |
| `audioCacheClearBook({required String bookUrl})` | bookUrl | `Future<int>` | 清理该书**全部**缓存，返回实际删除的文件数（**同样仅统计数据文件，不计 `.complete` 标记**，对齐原版同上口径；**幂等**）；书目录一并尝试移除。**不跨书**（目录按 `md5_16(bookUrl)` 隔离，不同书互不影响） |

---

### 2.48 音频章节预下载（audio_cache 写入面 FFI，2 个方法）

> [B2 | 2026-10-03] 加法式新增（不改既有签名/行为；**契约先于代码**，本批不改任何代码）：**音频章节预下载写入面**，补齐 §2.47 只读/清理面所缺的下载安装能力，对齐原版 `AudioCacheService`（服务编排）+ `AudioCacheManager.cacheChapter`（写入本体）。
> **方法取舍（仅 2 方法）**：原版服务编排（任务队列 ArrayDeque、前台通知、START_NOT_STICKY 生命周期）**不上 FFI**——属 UI/应用层职责，Dart 循环逐章调用即可自持进度（done/total/fail 与原版通知计数 `AudioCacheService.kt:275-301` 等价）；唯一必须下放 Rust 的是「在途下载取消」（Dart 无法取消已发出的 Future）。决策策略（键计算、五段式文件名生成、扩展名探测、`.complete` 安装语义、已缓存跳过）**全部落 Rust**，UI 层零业务逻辑。
> **下载由 Rust 做（字节不穿 FFI）**：音频文件可达数十 MB，禁止 base64 穿边界（系 §2.46 图片缓存 base64 惯例的**反例登记**）。playUrl 由 Dart 经 **`audioGetChapterMedia`（§2.26 播放取址链）的 `mediaUrl`** 解析后传入——**修订说明（2026-10-04，主代理据实现批反馈修正契约初稿）**：初稿写「由 `getChapterContentFull` 解析」，但该链会应用替换规则与简繁转换（`reader.rs:1034,1111`）**可能污染 URL**；原版 `cacheChapterLocked:139-144` 实为**播放链** `WebBook.getContentAwait` 的输出，与我方 `getAudioChapterMedia` 同源，故实现取后者，**更贴原版**。取址同源保证 `.complete` 标记内 playUrl 与播放器将用的地址一致（可为含 `,{options}` 的 AnalyzeUrl 模板原串）；Rust 按 bookUrl 自 DB 载入 Book/BookSource/BookChapter，以 `legado-parser::AnalyzeUrl`（`analyze_url.rs:196`）+ `legado-fetcher` 等价语义发起下载（headers/cookie/JS/重试/限速全在 Rust，对齐原版 `AudioCacheManager.kt:148-154` 用 AnalyzeUrl 下载）；既有先例：`tts_speak`（`ffi.rs:2080`，Rust 下载+落盘+返回路径）、`webdavDownloadFile`（§2.28，字节零穿越）。
> **目录与命名（写读同根同键，严格对齐原版）**：写入根 = §1.6.1 `set_audio_cache_dir` 注入根（与 §2.47 读面共用）；书目录 = `{根}/book_{md5_16(bookUrl)}`（即时计算，`AudioCacheManager.kt:205-212/223-230`）；文件名五段式 `%05d_{key16}_{safeTitle}_{playUrlHash16}_{rev8}.{ext}`（`AudioCachePolicy.buildFileName:67-98`，正则 `:11-13`）——`key16` = `md5_16(chapterUrl.ifBlank{chapterTitle})`（与 §2.47 同源）；`safeTitle` = 标题经非法文件名字符替换 `_`（对齐 `normalizeFileName`）→ 去 ISO 控制符 → trim → 去首尾 `_` → 空则 `"chapter"` → 截 40 字符 → 去尾部 `.`/空格 → 空则 `"chapter"`（`AudioCachePolicy.kt:79-87`）；`playUrlHash16` = `md5_16(playUrl)`（不参与命中判定，仅区分同章换地址的历史版本）；`rev8` = 随机 8 位小写 hex（UUID 去连字符前 8 位，防并发同名）；`ext` 由 Content-Type 映射（mpeg/m4a/aac/ogg/opus/wav/flac/webm/amr/3gpp）→ 最终 URL 后缀 → playUrl 后缀 → 缺省 `"audio"`（`detectExtension:35-65`），须 ∈ 12 扩展白名单（mp3/m4a/m4b/aac/ogg/oga/opus/wav/flac/webm/amr/3gp）∪ `{"audio"}`（`:15-18`）。
> **下载安装流程（逐条对齐 `AudioCacheManager.kt:132-199`）**：① 前置校验（见方法行）；② 清理本 key 下陈旧未提交文件（`tmp_*.part` 与无 `.complete` 的五段式文件，lastModified 早于 1 小时者，`cleanupUncommittedFiles:302-314`，阈值 `STALE_PARTIAL_AGE_MILLIS:43`）；③ 流式下载写 `tmp_{key16}_{rev8}_{uuid}.part`（块级取消检查，对齐 `copyCancellable:397-412`；实现须 reqwest 字节流直写盘，禁整文件入内存后落盘）；④ size 校验（Content-Length>0 时最终大小必须相等且 size>0，`isCompleteFile:112-114`）；⑤ 安装（优先 rename 至五段式终名，SAF rename 失败退整文件复制后复验 size，`installStagedFile:232-264`）；⑥ 写 `.complete` 标记（内容 `1\n{md5_16(playUrl)}\n{playUrl}` UTF-8 三行元数据，写后**回读校验** decode==playUrl，不一致删标记报错，`createCompleteMarker:266-281` + `AudioCacheMetadata:137-153`）；⑦ 清理同 key 其他文件与标记（保留新安装文件，`removeCacheFiles:188/338-356`）；⑧ 任一步失败删除已安装文件+标记+tmp（`:190-197`）。
> **决策条件（原版事实，均落 Rust）**：原版**无用户开关**——AppConfig 仅 `audioCacheTreeUri` 目录键（`AppConfig.kt:728-735`），无 `readConfig.setCache` 类配置、无单章大小上限、无总容量上限/自动清理、无网络类型限制（仅 WiFi 与否不校验）、无超时。唯一决策门 = ① 分卷章节拒缓存（`cacheChapterLocked:115`）；② playUrl 校验——空 / JSON 数组多段 / HLS（`.m3u8`/`.m3u`，截 `?`/`#` 后大小写不敏感，`requireCacheablePlayUrl:25-33` + `isHlsUrl:116-119`，下载响应 Content-Type 含 mpegurl 或最终 URL 为 HLS 同拒 `:45-47`）；③ 已缓存跳过（服务循环 `AudioCacheService.kt:216`）。范围规范化（`normalizeRange:20-23`）与目录有效性预检（`isCacheDirAvailable:47-49`）属 UI/编排层，由 Dart 侧组合既有方法完成。**本批不新增**原版不存在的容量上限/自动清理（重构红线：禁止新增原版不存在的功能）。
> **已知边界（登记，不实现）**：原版为 Android 前台服务（通知+保活+AudioPlayActivity 内容 Intent），我方 FFI 下载仅在进程存活期间进行——App 被杀即停（已装文件保留，重入幂等=已缓存跳过）；无逐章失败明细持久化（对齐原版：计数仅在通知内存态）。
> **失败语义（有意区别于 §2.47 读面降级风格）**：写入是显式用户动作，失败**上抛 BridgeError 不降级**（原版 `cacheChapter` 返回 `Result`，服务计 `failCount` 后通知展示——Dart 循环等价承接）；错误文案对齐原版：「分卷章节不支持缓存」「播放链接为空」「暂不支持缓存多段音频」「暂不支持缓存 HLS 音频」「网络请求失败(code)」「音频文件为空」「音频文件不完整」「音频缓存完成标记校验失败」。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `audioCacheDownload({required String bookUrl, required int chapterIndex, required String chapterUrl, required String chapterTitle, required String playUrl})` | bookUrl / chapterIndex / chapterUrl / chapterTitle（章节四元标识，同 `audioCacheQuery`）/ playUrl（内容链解析所得播放地址原串，可为含 `,{options}` 的 AnalyzeUrl 模板） | `Future<String>` | 单章下载安装（**幂等**）：Rust 全权执行上文流程 ①–⑧；已提交缓存（命中判定同 §2.47：key16 匹配 + `.complete` 存在 + size>0）直接返回不重下（对齐原版服务 `AudioCacheService.kt:216` 跳过语义）；返回 JSON `{"status":"installed" / "already_cached","path":<本地文件绝对路径>,"sizeBytes":N,"extension":"mp3"}`。Rust FFI 面为 `pub async fn audio_cache_download(book_url: String, chapter_index: i32, chapter_url: String, chapter_title: String, play_url: String) -> Result<String, BridgeError>`（async + spawn_blocking 非阻塞，对齐 §2.17 webbook* 先例；实现落 `legado-ffi/src/api/audio_cache_api.rs` 扩展，复用其 `cache_key16`/`book_dir`/`parse_cache_file_name`）。前置校验：bookUrl 空白 / book 不在 DB / chapterIndex 无对应章（章不在 DB）/ playUrl 空 → Err；`isVolume` → Err「分卷章节不支持缓存」；playUrl 为 JSON 数组形态 → Err「暂不支持缓存多段音频」；HLS → Err「暂不支持缓存 HLS 音频」；书源不在 DB → Err（**差异登记**：原版为任务级静默中止整段范围 `AudioCacheService.kt:192`，我方逐章报错、由 Dart 循环决定后续，粒度更精细）。取消中断返回 Err「音频缓存下载已取消」 |
| `audioCacheCancel()` | 无 | `Future<bool>` | 取消当前在途下载（**对齐原版服务 stop 语义的单槽化**：原版单 worker 逐章处理 `AudioCacheService.kt:145-185`，全局同时至多一个在途下载）：进程级取消代数 +1，在途下载在每个流式块边界检查代数（对齐 `copyCancellable` 的 ensureActive），不匹配即中止拷贝并删除部分文件（对齐原版 CancellationException 清理路径 `AudioCacheManager.kt:190-197`）；返回 `true` = 置位时快照到在途下载（尽力提示，不作同步保证），`false` = 当前无在途；Dart 循环侧取消 = 调用本方法 + 停止发起后续章节调用。Rust FFI 面为 `pub fn audio_cache_cancel() -> Result<bool, BridgeError>`（同步立即返回）。**不设**进度/状态查询方法（Dart 循环自持进度，原版通知计数由 Dart 等价维护）；**不设**批量队列方法（原版 ArrayDeque 队列属服务编排，不上 FFI） |

---

### 2.49 视频弹幕数据链（video_danmaku FFI，1 个方法）

> [V-B1 | 2026-10-05] 加法式新增（不改既有签名/行为；**契约先于代码**，本批不改任何代码）：**视频弹幕数据链**——把书源内容规则副内容（`contentRule.subContent`）从「抓到即丢」接通到「捕获→落库→查询」，对齐原版 `BookContent` 弹幕链（`app/.../help/bookContent/BookContent.kt:156` `putDanmaku` → 章节变量 `danmaku`，`<10000` 字符进 variable 列、`≥10000` 走 `RuleBigDataHelp` 文件，`RuleDataInterface.kt:16`）与读取侧（`app/.../model/VideoPlay.kt:279` 读出 → `BiliDanmukuParser` 解析 B 站 XML）。
> **现状缺口（调研 `docs/VIDEO_TRACK_SURVEY_20261005.md` 实测）**：`rust/legado-fetcher/src/web_book.rs:3777-3783` `merge_sub_content_into_body` 在 `is_media`（视频/音频书）时**直接丢弃 subContent**——但提取链（含「http 开头则二次请求」语义，`:3731-3771` + 4 单测）**已完整实现**，缺的只是媒体分支的捕获与落库。**休眠资产激活**：`rust/legado-core/src/video_state.rs`（774 行，含 `DanmakuSource` 的 `Inline/File/None` 三态状态机 + 测试）当前零引用，本批激活为弹幕源归一入口。
> **方法取舍（仅 1 方法）**：查询面 `getVideoDanmaku`；**写入面不上 FFI**——捕获落库发生在 Rust 抓取链内部（fetcher 提取 subContent → 写章节 variable），与既有 `getChapterContentFull` 落库缓存同型，属数据链内部行为而非用户显式动作（对比 §2.48 音频缓存写入是用户显式动作故上抛 FFI）。**弹幕 XML 解析不在本节**：`BiliDanmukuParser` 的解析与渲染属 B2 渲染批（解析器归属另裁）。
> **字段模板**：对齐 §2.26 `getAudioChapterMedia` 的 `lyric` 字段先例（`audio_api.rs:44` `Option<String>` + `skip_serializing_if`）。
> **失败降级**：无弹幕返回 `null`（书源无 subContent / 未抓到 / 解析为空均同面）；查询异常降级为 `null` 不抛（弹幕是增强层不是数据源，对齐 §2.46 口径）。**幂等**：重复查询读同一落库值。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getVideoDanmaku({required String bookUrl, required int chapterIndex})` | bookUrl / chapterIndex | `Future<String?>` | 查询某章弹幕数据（**只读、幂等**）：读章节 variable 列 `danmaku` 键（对齐原版 `putDanmaku` 落点）；`<10000` 字符直返原文（B 站 XML 或内联文本）；**≥10000 字符走文件存储**（对齐 `RuleBigDataHelp`，落点与文件名规则对齐原版实现，调研报告 §3.1）；无记录/书或章不在 DB/读失败 → `null`（降级不抛）。Rust FFI 面为 `pub fn get_video_danmaku(book_url: String, chapter_index: i32) -> Result<Option<String>, BridgeError>`。**数据链写入侧（本批一并实现，不上 FFI）**：fetcher 媒体分支从「丢弃 subContent」改为「捕获 → 按 `<10000`/`≥10000` 分流落库（variable 列 / 大数据文件）」；写失败降级仅记日志不阻断正文返回（对齐原版 putDanmaku 的非致命语义） |

---

### 2.50 视频弹幕解析（danmaku_parse FFI，1 个方法）

> [V-B2 | 2026-10-05] 加法式新增（不改既有签名/行为）：**B 站弹幕 XML 语义解析**，对齐原版 `help/gsyVideo/BiliDanmukuParser.kt`（SAX 解析，`:34-51`）。**归属依据（用户裁决 2026-10-05「同步原版逻辑」）**：解析属业务规则（p 属性语义、颜色/字号换算、类型过滤），落 Rust 服务侧，Dart 仅做渲染——原版解析亦在播放器服务链（非 UI 层）。
> **暴露面说明（B2 实现代理核查定案）**：`getVideoDanmaku`（§2.49）返回**原文**；解析结果必须经独立 FFI 到达 Dart（既有 284 导出无承接面；改 §2.49 返回结构=契约修订，不取）。**非 XML 容错对齐原版**：原版 SAX 解析失败 → null（**无容错、不包裹 `<i>`**，javap 实测 DanmakuFlameMaster 0.9.25 `load(InputStream)` 直连 `AndroidFileSource`）→ 我方解析失败/非 XML → `null`（静默无弹幕，对齐原版）。
> **解析语义（逐条对齐原版字节码与源码，B2 代理实测）**：
> - `<d p="时间秒,类型,字号,颜色,时间戳,池,hash,id">文本</d>`（`:80-89`）；`time = p0*1000` 毫秒（`:94-108`）；`color = (0xFF000000|p3)&0xFFFFFFFF`；仅解码 `&amp;&quot;&gt;&lt;` 四实体（`:257-272`）。
> - **类型映射**（DanmakuFlameMaster 0.9.25 `DanmakuFactory` 字节码）：1=右→左、4=底、5=顶、6=左→右、7=special（高级弹幕 JSON）；**2/3/8 返回 null 静默丢弃**（对齐原版）。
> - type7 高级弹幕：解析 JSON 属性（`:136-253`）但 **V-B2 渲染范围=1/4/5/6 四类**，type7 数据字段保留、渲染作**已登记边界**（用户裁决范围外不实现渲染）。
> - 描边色：`color<=BLACK?白:黑`（有符号比较 → 仅纯黑白描边，`:94-108`）；字号原值透传，`(density-0.6)` 平台换算由 Dart 渲染层做（**平台适配不属 XML 语义**，Rust 不做 density）。
> - **原版渲染配置（Dart 渲染层对齐，不属契约）**：滚动最多 5 行、SCROLL_RL/TOP 禁重叠、STROKEN 3f、不合并重复、scaleTextSize 1.0f（`VideoPlayer.kt:286-301`）；暂停/恢复（`:156-174`）、seek 同步（`:199-209`）、倍速联动 `danmakuSpeed-(speed-1)/6`（`:135-141`）；开关 UI 仅控制器条一个 TextView 文案「关弹幕/开弹幕」（`video_layout_controller.xml:72-81`），无弹幕时 GONE（`VideoPlayer.kt:266-272`）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseVideoDanmaku({required String raw})` | raw（弹幕原文：B 站 XML） | `Future<String?>` | 解析 B 站弹幕 XML 为 JSON 数组（**纯函数、无 IO、无 DB**）：每项 `{"timeMs":int,"type":int(1/4/5/6/7),"textSizeRaw":double,"color":int,"text":String}`，按 timeMs 升序（对齐原版加载序）；type 2/3/8 静默丢弃；type7 仅保留 JSON 属性字段（渲染边界见上）；解析失败/非 XML/空 → `null`（对齐原版 SAX 失败→null 静默无弹幕）。Rust FFI 面为 `pub fn parse_video_danmaku(raw: String) -> Result<Option<String>, BridgeError>`。Dart 侧 `RustApi.parseVideoDanmaku` 解析 JSON 为弹幕项列表供自绘渲染层（CustomPainter，不引第三方插件——原版 DanmakuFlameMaster 为 Android 专用库无 Flutter 等价，插件属新依赖须用户裁决） |

---

### 2.51 直链上传（direct_link_upload FFI，1 个方法）

> [批16a | 2026-10-27] 加法式新增（不改既有签名/行为）：**外部文件/导出直链上传**，逐条对齐原版 `help/DirectLinkUpload.kt:26-71`（`upLoad`）+ `model/analyzeRule/AnalyzeUrl.kt:714-729`（`upload` 选项消费）+ `help/http/OkHttpUtils.kt:157-191`（`postMultipart`）。**字段集按参考版口径**（用户裁决 2026-10-27）：参考版 `legado-with-MD3` 已删除口令与 `expiryDate`，规则对象冻结为 **4 字段** `uploadUrl` / `downloadUrlRule` / `summary` / `compress`（序列化 camelCase；读取兼容 snake_case alias；未知键如原版 `expiryDate` 忽略）。
>
> **上传语义（逐条对齐原版）**：
> - `uploadUrl` 支持逗号选项：`<url>,{"method":"POST","headers":{…},"body":{…},"type":"multipart/form-data"}`（切分等价原版 `\s*,\s*(?=\{)`）；选项 JSON 形态非法 → 明确参数错误（不静默按无选项处理）；
> - **上传链恒以 POST multipart 发送**（原版 `AnalyzeUrl.upload` 固定 `postMultipart`，`method` 选项仅解析保留、不改变派发）；
> - `body` 中值为字符串 `"fileRequest"` 的键 → 文件部件（`fileName` / `contentType`），其余键 → 普通文本 form 字段（值字符串化，对齐 `value.toString()`）；
> - 请求复用 `LegadoClient` 统一出口（默认头 / UA / DB Cookie 合并 / 代理 / 限流 / 重试 / HTTP 日志采集），新增 `post_multipart` 出口；**字节不穿 FFI**（文件内容由 Dart 传路径或文本，Rust 读盘/压缩/上传）；`content` 与 `filePath` 同受 100 MiB 上限约束；
> - **上传超时口径**：共享客户端在构建期设置 `.timeout(read_timeout)`（默认 60s）是**总请求超时**（连接 + 发送 + 等待响应）；上传出口按 multipart 实际载荷大小覆写单请求超时为 `connect_timeout + 传输预算 + read_timeout`（传输按 256 KiB/s 保守下限估算，100 MiB ≈ 400s），小载荷至少保持 `read_timeout`。原版 OkHttp 仅设 `writeTimeout` 60s/次写操作、无 `callTimeout`（总请求不设上限），本实现采用「按载荷估算的有限总超时」以避免慢链路大文件被 60s 掐断；
> - `compress=true` 且 `contentType != "application/zip"`：内存打 zip（单条目名 = 原文件名、`Deflated`），上传文件名改为 `<fileName>.zip`、类型改为 `application/zip`（对齐 `ZipUtils.zipByteArray` + `upLoad:43-58`）；
> - 上传成功后以**响应体 + 响应最终 URL** 构造 `AnalyzeRule` 求值 `downloadUrlRule`（JSONPath / 正则 / `@js:` 级联；`result` 绑定前序结果、`baseUrl` 绑定响应 URL，对齐 `AnalyzeRule().setContent(res.body, res.url)`）；结果为空 → 错误「上传失败,{响应体}」。
>
> **错误语义（精确文案）**：`uploadUrl` 空 → 「上传 URL 未配置」；`downloadUrlRule` 空 → 「下载链接规则未配置」；规则求值为空 → 「上传失败,{响应体}」；无 quickjs 构建且规则含 `@js:`/`<js>`（**大小写不敏感**）→ 「当前构建不支持 JS 下载规则」（**不静默降级为空**）；`content` 与 `filePath` 未二选一 → 参数错误；`filePath` 不存在/读取失败 → 读取错误；`content` > 100 MiB → 「上传内容超过上传上限（100 MiB）」；单文件 > 100 MiB → 「文件超过上传上限（100 MiB）」。
>
> **已登记差异**（与 Android 原版 `AnalyzeUrl.upload` + `OkHttpUtils.postMultipart` 的实现口径差异，均为已知且当前不逐条对齐）：
> 1. **上传 URL 的 query 保留**：原版 `upload` 走 `url(urlNoQuery)`（剥离 query，upload 链不把 query 并入 multipart 表单）；本实现按 `uploadUrl` 原文（去选项后）直接请求，query 不剥离、随 URL 发送；
> 2. **上传 URL 不做模板求值**：原版 `AnalyzeUrl` 构造期执行 `initUrl`（`@js:` / `<js>` / `{{}}` 变量替换、相对 URL 解析）；本实现只做逗号选项切分，URL 原样使用（规则配置方需传入最终 URL）；
> 3. **headers 仅接受对象形态**：原版 `headers` 经 Gson 支持对象或 JSON 字符串两种形态；本实现 `UploadOptions.headers` 只接受对象（`HashMap<String, Value>`），传字符串形态会被 serde 判为形态不符并报规则解析错误；
> 4. **对象值字符串化与部件顺序**：原版 `value.toString()` 对 Map 走 Gson `toString`（如 `{a=1}` 的 Java Map 字符串形态），本实现用 JSON 紧凑串（如 `{"a":1}`）；原版按 Gson `LinkedTreeMap` 声明序发送部件，本实现按字段名排序（multipart 字段顺序语义不敏感）；
> 5. **body 空/缺失错误文案**：原版 `body` 缺失时 `!!` 抛 NPE、`{}` 空表照常发送空 multipart；本实现缺失 → 「上传 URL 选项缺少 body（无法定位 fileRequest 文件字段）」、空表 → 「上传 URL 选项 body 为空（无法定位 fileRequest 文件字段）」。
>
> 其余已登记差异：错误文案按本契约中文（原版 Kotlin 为「上传url未配置」「下载地址规则未配置」）；`type` 选项作为 multipart 整体 Content-Type 使用（缺省/`multipart/form-data` 时由实现附加 boundary；含 CR/LF 等控制字符或非 ASCII 的 Content-Type 明确报错）；原版 `expiryDate` 不进入契约（参考版已删）；压缩条目名统一取 `fileName` 参数（原版 `filePath` 输入走 `ZipUtils.zipFile` 时用实际文件名作条目名——调用方传 `fileName` = 实际文件名即等价）；用户选项 headers 中的 `Content-Type`/`Content-Length` 会被请求体覆盖（对齐 OkHttp `body.contentType()` 优先语义）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `directLinkUpload(String ruleJson, String fileName, String contentType, {String? content, String? filePath})` | ruleJson（4 字段规则 JSON，camelCase，兼容 snake_case）；fileName（上传文件名，压缩时自动加 `.zip`）；contentType（`application/zip` 时不再压缩）；content / filePath **二选一**（文本内容或本地文件绝对路径） | `Future<String>` | 上传并返回直链 URL（Rust `ffi::direct_link_upload`，async + spawn_blocking 非阻塞）：规则解析 / 压缩 / multipart 构造 / 网络上传落 Rust（`legado-net::direct_link_upload`），下载链接规则求值落 FFI 层（`legado-parser::AnalyzeRule` + QuickJS 执行器）；Dart 侧 `RustApi.directLinkUpload` 直通，**不做降级 catch**（上传是显式用户动作，失败须上抛）。16b 直链规则配置 Sheet 与 16c 通用导出目标 Sheet 为消费方 |

---

### 2.52 书签标记（book_marking FFI，5 个方法）

> [批7b-1 | 2026-11-09] 加法式新增（不改既有签名/行为）：**用户划线/高亮笔记（标记）数据层**，逐条对齐参考版 `data/entities/BookMarking.kt:21-46`、`data/dao/BookMarkingDao.kt:13-87` 与 `domain/gateway/BookMarkingGateway.kt`。书签标记与既有书签（§2.7 `bookmarks`，仅页面导航）和 AI 正文处理（`book_memos` / 内容处理记录）**相互独立**：新表 `book_marks`，**不写入** `highlights` 表，也不复用 `bookmarks` 表。**无外键**：参考版 `BookMarking` 实体未声明 `ForeignKey`，本实现同样不建外键（与参考版一致）。
>
> **模型 `BookMarking`（JSON 键名 camelCase）**：`id`（String 主键）/ `bookUrl`（String，创建时的源地址，跳转校验用）/ `bookName` / `bookAuthor`（String，跨源关联键——换源后标记仍可见可管理）/ `chapterIndex`（int?，可空）/ `anchorJson`（String，章节内定位锚点，复用参考版 `TextProcessAnchor` 序列化，**必填非空**）/ `styleJson`（String?，线段/颜色等 `TextProcessStyle` JSON，可空）/ `note`（String，用户备注）/ `chapterName`（String，冗余章节标题，目录笔记页展示用）/ `enabled`（bool，默认 true）/ `createdAt`（int，Unix 毫秒）/ `updatedAt`（int，Unix 毫秒）。字段与参考版实体逐列对齐，无 `kind` 列——样式即类型，由 `styleJson` 表达。
>
> **排序与过滤语义**：
> - `listByBook`：按 `bookName`+`bookAuthor` 取**全部章节/全部源**的标记，排序 `chapterIndex` 升序、`createdAt` 升序（对齐参考版 `flowByBook`）；
> - `listForChapter`：按 `bookUrl` 取；`chapterIndex` 为 Some 时 SQL 条件为 `chapterIndex = ? OR chapterIndex IS NULL`（对齐参考版 `getForChapterSync`：全局标记也参与该章渲染），None 时取该书全部；排序 `createdAt` 升序；
> - 返回均为**裸 JSON 数组**（遵守 §1.4 铁律）；Dart 侧 `BookApi` 返回类型化 `List<BookMarking>`。
>
> **保存语义**：`saveBookMarking` 接收 `BookMarking` JSON；`id` 为空串 → Rust 生成 **UUID v4**；`createdAt <= 0` → 当前毫秒；`updatedAt` **恒写当前毫秒**（忽略入参）；落库走 `INSERT OR REPLACE`（同 id 覆盖，重复导入幂等）；返回**落库后的完整对象 JSON**。入参 `marking_json` 非法 JSON → 参数错误（不静默降级）；`anchorJson` 为空/纯空白 → 参数错误；`styleJson` 可空。**`anchorJson`/`styleJson` 的内容解析属 7b-2 渲染层**——FFI 只要求 `anchorJson` 非空，不校验其 JSON 语法或字段结构。
>
> **删除/启停语义**：`deleteBookMarking` 按主键删除，id 不存在为 no-op（不报错）；`setBookMarkingEnabled` 更新 `enabled` 与 `updatedAt=now`，id 不存在为 no-op（不报错）。
>
> **备份口径（2026-11-13 批27 更正）**：`book_marks` **纳入备份与恢复**。批7b-1 原记「与参考版一致不纳入备份」**前提有误**——参考版实际备份该表（`legado-with-MD3` `app/src/main/java/io/legado/app/help/storage/Backup.kt:71` 的 `backupFileNames` 含 `bookMarking.json`、`:158` 以 `bookMarkingDao.all` 写出；`Restore.kt:163-165` 读回并 `bookMarkingDao.insert`，能力自 `488a375`/2026-09-28 起存在）。现状：
> - **自有 JSON 备份**：格式 `BACKUP_VERSION` 5→**6**，新增 `bookMarks` 段（12 列 camelCase，与参考版 `BookMarking.kt:27-46` 逐列对齐）；空表写空数组，旧 v5 备份缺该键时默认空数组且**不清空库内既有标记**（恢复为纯 upsert，无 DELETE）。
> - **参考版 zip 备份**：`bookMarking.json` 加入恢复白名单（`ZIP_DATA_FILES` 22→23），映射到 `book_marks`；落库 `INSERT OR REPLACE`，重复恢复同 id 幂等；缺 `id` 条目补 UUID v4（与 `saveBookMarking` 同口径）；`anchorJson` 为空/纯空白的条目 **warn 后跳过**（参考版 `Restore.kt` 直接 insert 会让这类行落库，但其正文渲染与目录笔记列表均对空锚点 `mapNotNull` 丢弃，即任何界面都不可见，故该偏离不可见，且与 `saveBookMarking` 拒绝空锚点同口径）。
> - **未计入统计**：`RestoreStats` 不新增 `book_marks` 条数，维持 `backup_restore` 既有 FFI 返回结构（如需统计须先改契约）。
> - **已知语义（与参考版一致）**：同 id 的旧备份再恢复会覆盖本机较新的编辑（无 `updatedAt` 最新者胜，参考版同为 REPLACE）；跨设备恢复因两侧 UUID 不同不会互相覆盖，但同一逻辑笔记可能各存一条。
>
> `bookName`+`bookAuthor` 为跨源关联键，换源不改写既有行的 `bookUrl`。
>
> **范围边界**：本批（7b-1）只交付数据层/契约/FFI/Dart API；划词内联卡（7 效果格 + 16 色）、编辑 Sheet、目录「笔记」页与正文渲染（下划线/删除线/背景/字色）属 7b-2，锚点解析与文本匹配放 Dart 侧，不新增 Rust 渲染链。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookMarkingsByBook(String bookName, String bookAuthor)` | bookName / bookAuthor（跨源关联键） | `Future<List<BookMarking>>` | 按书名+作者取全部章节标记（含不同 bookUrl 的源），`chapterIndex` 升序、`createdAt` 升序（Rust `ffi::book_marking_list_by_book`） |
| `getBookMarkingsForChapter(String bookUrl, int? chapterIndex)` | bookUrl；chapterIndex（null=该书全部章节） | `Future<List<BookMarking>>` | 按源地址取标记；chapterIndex 非 null 时同时返回该章 `chapterIndex IS NULL` 的标记，`createdAt` 升序（Rust `ffi::book_marking_list_for_chapter`） |
| `saveBookMarking(BookMarking marking)` | BookMarking（id 可空串；anchorJson 必填） | `Future<BookMarking>` | 新增/覆盖标记：空 id 生成 UUID v4、createdAt<=0 补当前毫秒、updatedAt 恒为当前毫秒，返回落库对象（Rust `ffi::book_marking_save`） |
| `deleteBookMarking(String id)` | id | `Future<void>` | 按主键删除；不存在为 no-op（Rust `ffi::book_marking_delete`） |
| `setBookMarkingEnabled(String id, bool enabled)` | id, enabled | `Future<void>` | 更新 enabled 与 updatedAt=now；不存在为 no-op（Rust `ffi::book_marking_set_enabled`） |

---

### 2.53 隐私与私密标记（privacy FFI，12 个方法）

> [批9a | 2026-11-09] 加法式新增（不改既有签名/行为）：**隐私密码凭据与私密标记数据层**。语义按参考版 `help/security/PrivatePasswordCipher.kt`（PBKDF2WithHmacSHA256 / 210000 次 / 32B verifier / 16B salt / 定长比较）、`data/repository/PrivateAccessRepository.kt`、`data/dao/BookDao.kt:1191-1213`（`isPrivate` 批量写与私密 URL 查询）与 `data/entities/BookGroup.kt:27`（分组 `isPrivate`）。**本批不做 UI、路由与平台生物识别**；生物识别与解锁状态机属后续批次。
>
> **密码凭据存储（不存明文）**：`legado-core::privacy` 生成 16 字节随机 salt，PBKDF2-HMAC-SHA256 迭代 **210000** 次派生 32 字节 verifier，两者均以标准 Base64 存入 caches 表固定键 `config:private_password_salt` 与 `config:private_password_verifier`（与既有 `config:` 前缀配置同表同前缀）。**绝不写入明文密码**；`privacyVerifyPassword` 用常量时间 XOR 比较，凭据缺失、Base64 非法或长度不符一律返回 false。
>
> **密码设置语义**：新密码按 `trim()` 后非空且字符数 **1..128** 校验，不满足返回 false（不落库、不抛错）；已有凭据（salt 与 verifier 均非空）时旧密码必须匹配——`oldPassword` 为 null 或错误均返回 false 且**不改动库**；无旧凭据时忽略 `oldPassword`。校验通过后重新生成 salt/verifier 并覆盖两键，返回 true。密码本身按用户输入原值参与派生（仅新密码合法性校验按 `trim()` 判空与计数，派生/校验均不修剪，对齐参考版 `PBEKeySpec(password.toCharArray())`）。
>
> **私密标记语义**：`books.isPrivate` 与 `book_groups.isPrivate` 均为 `INTEGER NOT NULL DEFAULT 0`（DB `SCHEMA_VERSION` 118→119，加法式迁移 v119，幂等 `add_column` 并纳入开库自愈）。单本标记与「所属私密分组」是**并集**关系（参考版 `isPrivateBook`），判定合并属消费方（UI/后续批次），本批只提供事实数据。`setBooksPrivate` 在**单事务**内执行 `UPDATE books SET isPrivate = ? WHERE bookUrl IN (...)`，返回实际更新行数（输入重复 URL 按 SQL `IN` 去重；不存在的 URL 不计数）；空数组返回 0 且不开事务。`getPrivateBookUrls` 返回 `isPrivate = 1` 的全部 `bookUrl`，按 `bookUrl` 升序稳定排序。`setBookGroupPrivate` 单列 `UPDATE book_groups SET isPrivate = ? WHERE groupId = ?`，返回是否命中行；`getPrivateGroupIds` 返回 `isPrivate = 1` 的 `groupId` 升序数组。
>
> **备份口径（登记差异）**：`Book.isPrivate` / `BookGroup.isPrivate` **纳入**备份与导入导出（参考版 `Book.kt` 注释明确私密标记属于书架结构，剔除会让恢复后私密属性丢失）；密码 salt/verifier 属敏感凭据，**不纳入**备份（`BackupConfig` 排除口径）。
>
> **JSON 入参与错误口径**：`set_books_private` 的 `book_urls_json` 必须是 JSON 字符串数组（元素均为字符串）；非数组、元素非字符串或 JSON 非法 → 参数错误（不静默降级）。DB 未初始化沿用既有「数据库尚未初始化，请先调用 db_open」错误。列表类 FFI 返回**裸 JSON 数组**（遵守 §1.4 铁律），Dart 侧返回类型化 `List<String>` / `List<int>`。
>
> **安全边界与失败语义（2026-11-09 审查回修）**：
> - **fail-closed**：`privacyHasPassword` / `privacyVerifyPassword` 的 DB 读取失败一律向上抛错（BridgeError），**不得**把读失败当作「无密码」返回 false；调用方遇错必须按锁定处理。
> - **清缓存保留凭据**：`cache_clear` 只删除非 `config:` 键，`config:private_password_*` 与用户配置均保留（否则清缓存会退化为「无密码」并可绕过旧密重设）；凭据删除唯一入口是 `privacyClearPassword`，9b UI 必须先验证旧密码（或当前已解锁）再提供清除入口。
> - **通用配置接口隔离**：`getAllConfigs` 过滤 `private_password_*` / `private_biometric_*`（后者为生物识别预留）；`getConfig` / `setConfig`（Dart `deleteConfig` 实为空串 `setConfig`）对这些键明确报中文错误，不得读写。
> - **并发**：`privacySetPassword` 的「读旧凭据 → 校验旧密码 → 写两键」在进程内互斥窗口内串行，写入以事务原子覆盖；并发改密只有一次成功，不产生丢失更新。
> - **批量写分块**：`setBooksPrivate` 按 **900** 个 URL 分块执行（SQLite 变量上限防御），单事务累计行数；跨分块重复 URL 去重。
> - **groupId 位宽**：`setBookGroupPrivate` 全链 **i64**（与既有 `bookGroup*` CRUD 一致），兼容原版时间戳分组 ID（如 `1793904884364`），禁止 i32 截断。
> - **salt 长度**：`privacyVerifyPassword` 要求 salt 解码后恰为 16 字节、verifier 恰为 32 字节，否则 false。
>
> [批9d | 2026-11-10] **生物识别快捷解锁（随机令牌信封，非明文密码）**：平台层（Android `BiometricPrompt` + Keystore auth-per-use；iOS `LAContext` + Keychain `kSecAccessControlBiometryCurrentSet`）只负责**认证并解封 32B 随机令牌**；令牌本身由 Dart `Random.secure()` 生成（标准 Base64），**平台层与配置表都不存明文密码**。Android 的加密 IV 由 Keystore Cipher 生成；iOS 的 `SecRandomCopyBytes` 仅生成契约占位 IV（Keychain item 本身受生物 ACL 保护，占位 IV 不参与解密）。Rust 将令牌 SHA-256 摘要以标准 Base64 存 `config:private_biometric_token_hash`，密文与 IV（Base64）存 `config:private_biometric_envelope` / `config:private_biometric_iv`。
>
> - `privacyBiometricStateGet` 返回 `{"configured": bool, "envelope": String?, "iv": String?}` 裸 JSON（无摘要、无令牌）；`configured` 为三键齐备且摘要可解码为 32 字节。
> - `privacyBiometricSet(token, envelope, iv)`：**必须已有隐私密码**；token Base64 解码后恰 32B、iv 恰 12B、envelope 解码后 1..4096B，否则参数错误返回 false 不落库；单事务覆盖三键。
> - `privacyBiometricVerify(token)`：无摘要或 token 非法返回 false；对 SHA-256 摘要做常量时间比较。**校验通过只代表生物凭据有效**，授权范围由 Dart `PrivacyNotifier` 按 `unlockScope` 决定（启动闸门置会话/启动验证；EveryTime 仅目标；设置页只验不授权）。
> - `privacyBiometricClear()`：删除三键，键不存在为 no-op。
> - **改密/清密联动**：`privacySetPassword` 成功（含新密码与原密码相同）与 `privacyClearPassword` 在**同一事务内**清空三键——改密即失效生物快捷（比参考版「同密码保留信封」更严格，登记差异）；Dart 随后调用原生 `deleteKey` 销毁 Keystore/Keychain 密钥。
> - **失效与降级**：原生返回 `key_invalidated`（新增/变更指纹）时，Dart 调 `privacyBiometricClear` 并关闭开关，回退密码；无硬件/未录入/系统锁定（`no_hardware`/`not_enrolled`/`locked_out`/`permanently_locked_out`）只隐藏或禁用快捷入口，不清除已配置信封（登记差异：参考版不主动清）。
> - **安全边界**：摘要、令牌、信封均不得写入日志；三键均属敏感配置，`getAllConfigs` 过滤且 `getConfig/setConfig` 拒绝；`cache_clear` 保留 `config:` 前缀；三键不纳入备份。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `privacyHasPassword()` | 无 | `Future<bool>` | salt 与 verifier 均存在（非空）时为 true（Rust `ffi::privacy_has_password`） |
| `privacySetPassword(String password, {String? oldPassword})` | password：新密码（trim 后 1..128 字符）；oldPassword：已有凭据时的旧密码，无旧凭据可空 | `Future<bool>` | 旧密码不匹配/新密码非法返回 false 且不落库；读校写进程内串行（并发只有一次成功）；成功生成 16B salt + 210k 次 PBKDF2 verifier 覆盖两键后返回 true（Rust `ffi::privacy_set_password`） |
| `privacyVerifyPassword(String password)` | password | `Future<bool>` | 无凭据或空密码返回 false；PBKDF2 派生后常量时间比较（Rust `ffi::privacy_verify_password`） |
| `privacyClearPassword()` | 无 | `Future<void>` | 删除 salt 与 verifier 两键；键不存在为 no-op（Rust `ffi::privacy_clear_password`） |
| `setBooksPrivate(List<String> bookUrls, bool isPrivate)` | bookUrls：书籍 URL 列表；isPrivate：目标标记 | `Future<int>` | 单事务分批（每批 900 URL）更新 `books.isPrivate`，返回实际更新行数；空列表返回 0，重复 URL 去重（Rust `ffi::set_books_private`） |
| `getPrivateBookUrls()` | 无 | `Future<List<String>>` | 返回 `isPrivate = 1` 的 bookUrl，按 bookUrl 升序（Rust `ffi::get_private_book_urls`） |
| `setBookGroupPrivate(int groupId, bool isPrivate)` | groupId：i64 全链（兼容旧时间戳分组 ID）；isPrivate | `Future<bool>` | 更新 `book_groups.isPrivate`，返回是否命中行（Rust `ffi::set_book_group_private`） |
| `getPrivateGroupIds()` | 无 | `Future<List<int>>` | 返回 `isPrivate = 1` 的 groupId，升序（Rust `ffi::get_private_group_ids`） |
| `privacyBiometricStateGet()` | 无 | `Future<String>` | 裸 JSON `{"configured": bool, "envelope": String?, "iv": String?}`；不返回摘要/令牌（Rust `ffi::privacy_biometric_state_get`） |
| `privacyBiometricSet(String token, String envelope, String iv)` | token：32B Base64；envelope/iv：Base64 | `Future<bool>` | 需已有密码；长度校验通过后单事务写三键，否则 false 不落库（Rust `ffi::privacy_biometric_set`） |
| `privacyBiometricVerify(String token)` | token：32B Base64 | `Future<bool>` | 无摘要/非法 token 返回 false；摘要常量时间比较（Rust `ffi::privacy_biometric_verify`） |
| `privacyBiometricClear()` | 无 | `Future<void>` | 删除摘要/信封/IV 三键；不存在为 no-op（Rust `ffi::privacy_biometric_clear`） |

---

### 2.44 数据层实现备注（不涉契约签名）

> 本节登记数据层内部实现变更预告，均不改变任何契约签名，仅供 Rust 轨实施与双轨知会。
> 本节不含方法，不计入方法模块数与附录统计（方法模块为 50 个，§2.1–§2.53，编号跳过 2.24/2.27）。
>
> ℹ️ **BookRepository::insert 级联删除隐患（第三批后置项，Task #63）**：`BookRepository::insert` 当前走
> INSERT OR REPLACE，存在外键级联删除隐患；将在本批改为 upsert 链路（内部实现变更，不涉契约签名，不改任何 FFI 行为）。
>
> ℹ️ **瞬态 HTML/下载字段（F3-8，2026-08-14）**：`books` 表 `infoHtml` / `tocHtml` / `downloadUrls` 对齐原版 Room 列，存书源详情/目录页原始 HTML 与下载地址缓存，**非用户持久配置**；换源/清缓存时可被覆盖或清空，UI 不应当作权威书元数据。
>
> ℹ️ **servers 表（DB v112，2026-10-26 批8）**：`servers` DDL 逐列对齐原版 Room v104 `servers`（`id` INTEGER NOT NULL 主键 / `name` TEXT NOT NULL / `type` TEXT NOT NULL / `config` TEXT / `sortNumber` INTEGER NOT NULL），`Migration111To112` 仅建表（幂等，只创建不写种子）；`ServerRepository` 为 servers 表唯一读写实现（`find_all` 按 `sortNumber` 升序、`upsert` = INSERT OR REPLACE、`delete`），FFI `webdavServersList` / `webdavServerSave` / `webdavServerDelete` 与备份收集/恢复全部委托该仓储。Flutter `sync_webdav_*` 偏好的 url/username/password 经一次性迁移写入 `id = -1` 的 `WEBDAV` 行（`remote_dir`/设备名仍为偏好）；迁移标记 `webdav_servers_migrated` 保证幂等。

---

## 3. UI 轨需求登记区

> UI 轨需要新数据时，在此登记需求，Rust 轨按契约实现。流程见 [TWO_TRACK_DEV_SPEC.md § 4.3](TWO_TRACK_DEV_SPEC.md)。

| 方法名 | 入参 | 期望返回 | 登记日期 | 状态 |
|--------|------|----------|----------|------|
| `getSearchHistory`（字段修复） | 不变 | `List<SearchKeyword>` 序列化字段对齐 Dart 模型：`word` / `usage` / `lastUseTime` | 2026-08-01 | ✅ 已完成 |
| `searchHistoryByPrefix`（新增） | `String prefix, {int limit = 20}` | `Future<List<String>>`（前缀匹配的历史关键词，对标 Android `searchKeywordDao.flowSearch`） | 2026-08-01 | ✅ 已完成 |
| `importBooks`（新增） | `String jsonArray` | `Future<int>`（批量导入书籍，返回成功导入数量，用于 WebDAV 书架批量回写） | 2026-08-02 | ✅ 已完成 |
| `searchMultiStream`（新增） | `String query, {List<String>? sourceUrls}` | `Stream<Map<String, dynamic>>`（多源渐进式搜索，逐书源推送批次，用于 Phase 3.3 渐进搜索） | 2026-08-02 | ✅ 已完成 |
| `searchCover`（新增） | `String bookName` | `Future<List<Map<String, dynamic>>>`（网络封面候选列表，字段建议 `url` / `width` / `height`，用于 Phase 6 P1 `change_cover_screen` 封面搜索） | 2026-08-01 | ✅ 已完成 |
| `dictLookup`（新增） | `String word` | `Future<Map<String, dynamic>>`（词典释义，字段对齐 Dart `DictEntry`：`word` / `phonetic` / `definitions[]`，用于 `dict_screen` 真实词典查询；Task #137 起数据源由静态占位表改为 dict_rules 字典规则引擎，见需求 4 补记） | 2026-08-01 | ✅ 已完成 |
| `highlight*` / `highlightRule*`（新增） | 见 §2.36 方法清单 | 高亮记录 CRUD + 高亮规则 CRUD（对齐上游 DB v96-v99，用于阅读器正文高亮一期） | 2026-08-04 | ✅ 已完成 |
| `reviewGetReplies`（新增） | `String sourceJson, String requestJson, int page` | `Future<String>`（段评回复按需加载，对标 Android `ReviewDetailDialog.loadReplies` + `ReviewRuleParser.parseReplyPage`，上游 #519；返回 `{items, nextPageUrl}` 对象包装，Flutter 段评弹窗回复 UI 由 UI 轨后续接入） | 2026-08-04 | ✅ 已完成 |
| `reviewGetSummary`（新增，P2-9） | `String sourceJson, String requestJson` | `Future<String>`（段评摘要，对标 `loadReviewSummary`+`parseSummary`；返回 `{counts, keys}`） | 2026-08-13 | ✅ 已冻结 |
| `reviewGetDetail`（新增，P2-9） | `String sourceJson, String requestJson, int page` | `Future<String>`（段评详情分页，对标 `ReviewDetailDialog`+`parseDetailPage`；返回 `{items, nextPageUrl, hasReplyUrl}`） | 2026-08-13 | ✅ 已冻结 |
| `appLog*`（新增，Task #79） | 见 §2.38 方法清单 | 应用日志体系：Rust 侧三级环形缓冲（message/crash/http）+ 写入/查询/清空/导出 FFI（对齐 Kotlin AppLog 旧欠账 + 上游 #543 导出 64K 截断），日志页面 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `checkSource` / `checkSourcesStream` / `cancelCheckSources`（新增，Task #87） | 见 §2.3 方法清单 | 书源校验 FFI 暴露：单本四步校验（CheckResult JSON）+ 批量串行 Stream 进度回推（CheckProgress JSON）+ 取消（包装 legado-net SourceChecker，对齐 Kotlin CheckSource 与 server /sources/check），校验页面 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `ruleSub*`（新增，Task #89） | 见 §2.39 方法清单 | 规则订阅 FFI 暴露：列表/保存/删除/启用切换/拖拽排序 + 检查更新/应用更新（DB v100 补全 Kotlin RuleSub 7 字段，委托 legado-net rule_update_client），订阅管理 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `verificationRequestStream` / `submitVerificationResult` / `cancelVerificationRequest`（新增，Task #90） | 见 §2.3 方法清单 | 验证码交互通道：JS 钩子（getVerificationCode/startBrowserAwait，对齐 Kotlin JsExtensions）经请求管理器挂起等待 → FFI 事件流推送请求（含航班去重/回放/5 分钟超时）→ UI 提交/取消唤醒；useBrowser 降级为图片验证码（桌面无 WebView），验证码弹窗 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `txtSearch` / `txtSearchRegex` / `txtSearchInChapter` / `txtSearchCount`（新增，Task #98 缺口#4） | 见 §2.40 方法清单 | 本地 TXT 全文搜索接入 frb 主链路：既有 C ABI 4 函数的 frb 暴露（包装 legado-book TxtSearch 引擎，纯文本/正则/章节内搜索 + 匹配计数，返回裸 JSON Array），供搜索页内“搜本地书正文”场景调用，UI 由 UI 轨后续接入 | 2026-08-05 | ✅ 已完成 |
| `setChineseConvertType` / `getChineseConvertType`（新增，Task #100） | 见 §2.9 方法清单 | 繁简转换 FFI 透传：reader.rs 硬编码 `chinese_convert: None` 改为读取持久化配置（键 `chineseConverterType`，0/1/2 → None/t2s/s2t），新增 set/get 接口；章节标题在展示路径补齐 t2s/s2t（对齐 Kotlin getDisplayTitle）；阅读器样式面板控件由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `ttsSpeak` / `ttsSetCacheDir`（新增，Task #113 缺口②） | 见 §2.42 方法清单 | TTS 真实合成管线：url 模板替换（speakText/speakSpeed）→ HTTP 拉取音频二进制（legado-net 新增 get_raw）→ Content-Type 校验 → MD5 命名本地缓存（命中免请求）；请 UI 轨将 `audioSpeak`（§2.26）的 `http.get` 探活 fallback 改接 `ttsSpeak`，音频播放器播放返回的 `audioPath` | 2026-08-06 | ✅ 已完成 |
| `readRecordDailyList`（新增，热力图「每日时长」） | `int year` | `Future<List<Map<String, dynamic>>>`（`[{date, seconds}]` 日期升序；写路径 `putReadRecord` 自动累加当日增量，见 §2.12） | 2026-08-29 | ✅ 已完成（单位归一 2026-09-11：存量毫秒经 v107 迁移归一为秒） |

#### 待 UI 封装清单（2026-08-06 审计：7 个 bridge 绑定已实现未被 UI 层封装）

> 以下 bridge 绑定（ffi.dart）已实现但未被 BookApi/rust_api.dart 封装或未被 UI 调用，登记于此供 UI 轨排期封装；封装后逐项销记。

| # | 绑定 | 所属组 | 备注 |
|---|------|--------|------|
| 1 | `sourceIsLoginUiV2` | 登录 UI V2 整组（§2.3） | ✅ 已封装接通（522e1c1be，`RustApi.isLoginUiV2`，书详/阅读器登录链路接入） |
| 2 | `sourceLoginUiV2` | 登录 UI V2 整组（§2.3） | ✅ 已封装接通（522e1c1be，`RustApi.loginUiV2`） |
| 3 | `sourceLoginActionV2` | 登录 UI V2 整组（§2.3） | ✅ 已封装接通（522e1c1be，`RustApi.loginActionV2`） |
| 4 | `backupList` | 其他（§2.41） | ✅ 已封装 `BookApi.backupList`（F3-20） |
| 5 | `cacheGetChapter` | 其他（§2.41） | ✅ 已封装接通（本次评审修复提交，`RustApi.getCachedChapter`，书架缓存导出） |
| 6 | `bookGroupSetShow` | 其他（§2.41） | ✅ 已封装 `BookApi.bookGroupSetShow`（F3-20） |
| 7 | `httpTtsSetEnabled` | 其他（§2.41） | ✅ 已封装 `BookApi.httpTtsSetEnabled`（F3-20） |
| 8 | `ttsSpeak` | TTS 真实合成管线（§2.42） | ✅ 已封装 `BookApi.ttsSpeak`（F3-20；`audioSpeak` 内部亦调用） |
| 9 | `ttsSetCacheDir` | TTS 真实合成管线（§2.42） | ✅ 已封装 `BookApi.ttsSetCacheDir`（F3-20；`RustApi.init` 内 `_initTtsCacheDir` 注入应用支持目录 tts_cache） |

> **销记更新（F3-20，2026-08-14）**：§3 待 UI 封装清单 **9 项全部销记**——登录 UI V2 三件套 + `cacheGetChapter` + `ttsSpeak`/`ttsSetCacheDir`（先前批次）+ `backupList`/`bookGroupSetShow`/`httpTtsSetEnabled`（本批补入 BookApi 抽象与 RustApi/MockBookApi 双实现）。**剩余待封装：0 项。**
>
> **移除记录（2026-08-07，Task #139）**：原表中 QUIC 客户端六件套（quicCreateClient/quicGet/quicPost/quicPerformanceTest/quicIsInitialized/quicCleanup）连同 netSetQuicEnabled/netIsQuicEnabled 总开关共 8 项 FFI，属原版不存在的新增能力，按纯重构决策已从 Rust/FFI/Dart 全链路移除，从本清单销记。

> **需求 1：getSearchHistory 字段修复（Bug）**
> 当前 Rust `search_history_api::get_search_history` 返回 DTO 字段为 `keyword` / `book_name` / `time`，
> 而 Dart `SearchKeyword` 模型（对齐 Android 原版实体）解析 `word` / `usage` / `lastUseTime`。
> 字段名不匹配导致 `SearchKeyword.fromJson` 解析后 `word` 恒为空字符串，
> 影响全局搜索历史与书内搜索历史（`search_content_screen.dart`）的真实 FFI 显示。
> 请 Rust 轨将 `SearchHistoryItem` 序列化字段对齐 Dart 模型（`word` / `usage` / `lastUseTime`）。
>
> **需求 2：searchHistoryByPrefix 前缀联想**
> Rust 仓储层已有 `SearchKeywordRepository::find_by_prefix`（LIKE 前缀匹配），但未暴露至 FFI bridge。
> 请暴露为 `searchHistoryByPrefix(prefix, {limit})` FFI 方法，供搜索页联想使用。
> UI 轨当前以客户端前缀过滤临时实现（行为等价），待本方法交付后切换为 DB 查询。
>
> **需求 3：searchCover 网络封面搜索（Phase 6 P1）**
> `change_cover_screen` 网络封面搜索原为 UI 内联占位假数据（`Future.delayed` + picsum 随机图）。
> Android 原版通过配置的封面源（图片搜索）按书名检索候选封面。请 Rust 轨提供 `searchCover(bookName)`。
> **响应契约**（snake_case，UI 侧已建 `CoverCandidate` freezed 模型对齐）：返回 `List<Map<String, dynamic>>`，
> 每项字段 `url: String`（封面图片地址，必需）/ `width: int`（像素，未知填 0）/ `height: int`（像素，未知填 0）。
> **错误语义**：无候选返回空列表（非异常）；网络/源异常抛出经 bridge 统一映射为 `BridgeError`。
> **UI 侧现状（Mock 先行）**：`ChangeCoverNotifier.searchCovers` 已就位并以 Mock 数据驱动 `CoverCandidate` 数据流，
> `change_cover_screen` 已重构为 `ConsumerStatefulWidget`（UI 层不再制造假数据）。Rust 交付后仅需将 Notifier 内
> `_mockSearch` 替换为 `ref.read(bookApiProvider).searchCover(keyword)` 并 `CoverCandidate.fromJson` 解析返回。
> 本地选图路径（FilePicker）不依赖本契约。因 UI 轨禁改 `rust_api.dart`，未单边添加 BookApi 抽象方法。
>
> **需求 4：dictLookup 词典查询（Phase 6 P2 延伸）**
> `dict_screen` 本地内置词典为静态占位数据，仅覆盖少量示例词。请 Rust 轨提供 `dictLookup(word)`。
> **响应契约**（snake_case，UI 侧已建 `DictEntry` freezed 模型对齐）：返回 `Map<String, dynamic>`，
> 字段 `word: String`（归一化后的单词）/ `phonetic: String`（音标，可空字符串）/ `definitions: List<String>`（释义条目）。
> **错误语义**：未收录词返回 `definitions` 空列表（非异常）；查询异常抛出经 bridge 统一映射为 `BridgeError`。
> **UI 侧现状（Mock 先行）**：`DictNotifier.lookup` 已封装查询职责，当前以本地内置词典 `_localDict` 为占位数据；
> 在线词典规则跳转经 `getConfig/setConfig` 持久化，不依赖本契约。Rust 交付后将 `_localDict[key]` 替换为
> `await api.dictLookup(key)`（届时 `lookup` 转异步）即可，模型字段即契约。
>
> **Task #137 补记（2026-08-07，数据源对齐原版字典规则，签名不变）**：
> Rust 侧 `dictLookup` 数据源由 18 词静态占位表改为对齐 Android 原版字典规则（dict_rules）体系：
> ① 查询 `dict_rules` 表全部启用规则（按 sortNumber 排序），逐条执行原版 `DictRule.search(word)`
> 等价链路（AnalyzeUrl urlRule 模板/`{{key}}`/data: URI → HTTP → AnalyzeRule showRule，`@js:` 经
> quickjs 特性执行）；② 表为空时注入原版默认 5 个字典源（海词中文/海词英文/有道/哔哩/百度汉语，
> 数据与 `assets/defaultData/dictRules.json` 逐字节同源）；③ 每条成功规则结果为一个 `definitions`
> 条目（前缀 `【规则名】`，原版为每规则独立页签），HTML 释义做轻量纯文本化；`phonetic` 恒为空；
> ④ 无启用规则/DB 未初始化返回空列表（非异常），单规则失败记日志跳过；
> ⑤ 入参仅 trim 不再小写（中文词兼容，原版原样传词）；⑥ 原版部分规则依赖 Rhino 专属能力
> （JavaImporter/org.jsoup/cache.putMemory）在 QuickJS 下不可等价复现，规则数据不改写、失败即跳过。

---

## 4. 服务端 HTTP 端点（legado-server 原版兼容面，非 FFI 计数范围）

> 本节记录 `rust/legado-server` 提供的**原版 Web API**（路径与响应信封对齐 Android
> 原版 `HttpServer.kt` + `ReturnData{isSuccess,errorMsg,data}`，HTTP 200）。这些端点
> 属于 Web 服务兼容面，**不计入** §2 FFI 方法数 / 附录合计。实现与逐条差异登记见
> `legado-server/src/legacy/mod.rs` 各批模块文档。

### 4.1 批30 新增：书源检验状态 4 条

| 端点 | 方法 | 令牌 | 请求 | 响应 `data` |
|---|---|---|---|---|
| `/getBookSourcesForManagement` | GET | 无 | `urls`（可选，JSON 字符串数组；缺省全量） | `{"sources": [BookSource], "states": [BookSourceCheckState]}` |
| `/getBookSourceCheckStates` | GET | 无 | — | `{"states": [BookSourceCheckState], "sessionToken": string\|null}` |
| `/startBookSourceCheck` | POST | `x-legado-token` | `{"sources": [BookSource], "keyword": string}` | `{"sessionToken": string, "sourceRevisions": {url: revision}}` |
| `/stopBookSourceCheck` | POST | `x-legado-token` | `{"sessionToken": string}` | `""`（成功） |

`BookSourceCheckState` 字段（与原版 Gson 输出键名一致）：

```json
{
  "bookSourceUrl": "https://example.com",
  "revision": "UUID",
  "sourceRevision": "UUID",
  "status": "NEEDS_CHECK | PASSED | FAILED | UNCHECKABLE",
  "checkedAt": 0,
  "detail": ""
}
```

状态机与错误文案（逐条对齐 `BookSourceCheckController.kt`）：

- 提交源与库内版本不一致 → `书源尚未保存或设备版本已变更，请先保存或重新拉取`；
  比较口径为 `BookSource.checkContent()`（忽略 `customOrder/enabled/enabledExplore/
  lastUpdateTime/respondTime/weight`，`enabledCookieJar` 的缺省/null 与默认 `true`
  同指纹）；
- 已有检验会话 → `书源调试通道占用中，请稍后重试`；`sources` 为空 →
  `请选择需要检验的书源`；请求体缺失/坏 JSON → `检验参数无效`；
- 停止时会话不存在或令牌不匹配 → `检验会话已结束或已更换`；
- `status` 写回使用 `(bookSourceUrl, revision, status='NEEDS_CHECK')` CAS：保存触发的
  状态重建、停止或旧任务结果都不会覆盖新状态；未完成源在停止后保持 `NEEDS_CHECK`。
- `detail` 组合（对齐 `CheckSourceService.onEach`）：`失效分组 | 结果消息 | // Error: {本次异常}`
  按 `" | "` 连接、过滤空串并去重；第三段恒取**本次失败消息**（去「校验失败:」前缀）——
  上游 `doCheckSource` 起始 `removeErrorComment()` 剥离历史错误块、失败时
  `addErrorComment(本次异常)` 前置后取首行，故无注释源也有第三段、带历史错误的源不会
  显示旧文案；`PASSED` 为 `""`，`UNCHECKABLE` 无第三段；`config:wSourceComment=false`
  时不生成第三段。

数据层：DB v115 `book_source_check_states`（`bookSourceUrl` 主键 + 外键
`book_sources(bookSourceUrl)` ON DELETE CASCADE；删源级联删状态）。书源新增/规则变更
（`checkContent()` 变化）重建状态；仅改启用/排序/权重等保留状态。检验执行使用
`legado-fetcher` 的 `webbook_search/info/chapters/content` 链（目录首章按上游
`selectCheckSourceChapter` 过滤卷章头：`isVolume && url.startsWith(title)`，空 URL 卷章
合成为 `{title}{index}`，不得当正文抓取）。

**批42 语义补充（发现页校验 + 并行检验 + 域名探测；端点/请求/响应形状零变化）**：

- **发现页校验已接入**：`config:checkDiscovery`（默认 `true`）且源 `exploreUrl` 非空时，
  取首个可用分类 URL（纯文本 `分类::URL` / JSON 分类数组 / `@js:` / `<js>` 求值），
  经 `legado-fetcher::webbook_explore_first_book` 抓取首个书籍并跑详情/目录/正文。
  `exploreUrl` 为空或该项关闭 → 跳过（不影响 `PASSED`）。失败口径（detail 首段分组）：
  无可用分类 → `发现规则为空`；`@js:`/`<js>`/分类 JSON 求值异常 → `FAILED` +
  `校验失败:发现规则求值失败: …`；请求/解析异常 → `FAILED` + `校验失败:发现页请求失败: …`；
  请求成功但解析不出书 → `发现失效`；发现书目录/正文为空 → `发现目录失效` /
  `发现正文失效`（搜索书对应 `搜索目录失效` / `搜索正文失效`，对齐原版 `checkBook`）。
  未启用 quickjs 的构建跳过 JS 发现规则求值（能力缺口不判失败，日志登记）。
- **并行检验**：并发数 = CPU 核数夹逼 4~8（caches `config:checkThreadCount` 可覆盖，
  硬上限 32），对齐原版 `AppConfig.threadCount` 并行语义；`sessionToken` 契约、单会话、
  `stop` 取消（在途工作线程随会话任务一并中止）、未完成源保持 `NEEDS_CHECK`、
  `(url, revision, status='NEEDS_CHECK')` CAS 写回均不变；DB 写经 AppState 互斥锁串行。
- **源地址可访问性**：`config:checkDomain=true` 时对源地址做 TCP 探测（整体 1.6s 预算，
  单地址 500ms 子超时，对齐原版 `isDomainReachable`）；不可达 → `域名失效` 分组 +
  `FAILED`「源地址不可访问」；非 http(s) → `UNCHECKABLE`。缺省 `false` 与原版一致。

**批42b 回修（端点/请求/响应形状零变化，仅执行语义与登记修正）**：

- **停止后在途结果不写回（P2-1）**：`stop` 后即使单源检查刚好超时/返回，写回入口
  （`write_back_check_result`）会复查会话令牌，已停止/已更换则丢弃结果；未完成源保持
  `NEEDS_CHECK` 的契约不变。
- **硬失败保留已判分组（P2-2）**：搜索已判「搜索失效」后，发现规则求值/请求硬失败
  （`发现规则求值失败: …` / `发现页请求失败: …`）的 `detail` 首段仍保留已累计分组，
  不再只留最后一条消息。
- **非 quickjs 边界**：仅 `@js:` / `<js>` 形态的 `exploreUrl` 不可求值；纯文本与 JSON
  分类数组不受影响。跳过时输出 warn + stderr（不判 `FAILED`）。
- **并行串读告警**：`FLOW_SCOPE` 为进程级单槽，并行下 `@put` 可能写进另一源的 scope；
  并行度 >1 且 ≥2 个源使用流程变量时输出一次可观测 warn（`[收敛项 B42-C2]`）。
- **exploreKinds 双实现**：服务端检验链与 ffi `explore_api` 各一份 JS 求值实现，登记
  为 `[收敛项 B42-C1]`，改动须双端同步，后续批次收敛。

### 4.2 既有端点索引

早期批次已落地的原版端点（`/getBookshelf`、`/getBookContent`、`/getBookSource(s)`、
`/saveBookSource(s)`、`/saveJsSource`、`/getHttpLog(s)`、`/getReview*`、
`/legacyReviewPage`、`/refreshToc` 等）清单与令牌面见
`legado-server/src/legacy/mod.rs` 模块文档；§4.1 为批30 增量。

---

## 附录：模块方法数统计

| # | 模块 | 方法数 |
|---|------|--------|
| 1 | 初始化/版本 | 2 |
| 2 | 书架操作 | 15 |
| 3 | 书源操作 | 33 |
| 4 | 搜索操作 | 19 |
| 5 | RSS 源操作 | 19 |
| 6 | 本地书籍操作 | 4 |
| 7 | 书签操作 | 7 |
| 8 | 替换规则操作 | 9 |
| 9 | 阅读器操作 | 12 |
| 10 | 配置操作 | 5 |
| 11 | 备份操作 | 4 |
| 12 | 阅读记录 | 6 |
| 13 | RSS 收藏操作 | 4 |
| 14 | 书籍分组 | 4 |
| 15 | 搜索历史 | 6 |
| 16 | 缓存管理 | 9 |
| 17 | WebBook 操作 | 6 |
| 18 | 发现页操作 | 7 |
| 19 | 规则解析 | 1 |
| 20 | 网络操作 | 5 |
| 21 | JS 引擎 | 3 |
| 22 | 服务器管理 | 5 |
| 23 | 书籍格式解析 | 3 |
| 24 | HTTP TTS | 7 |
| 25 | 音频播放 | 4 |
| 26 | WebDAV 云同步 | 11 |
| 29 | 下载管理器 | 7 |
| 30 | 段评（ruleReview） | 3 |
| 31 | 书籍导出 | 2 |
| 32 | 自动任务 | 14 |
| 33 | 音频播放模式 | 2 |
| 34 | 压缩包导入 | 10 |
| 35 | RSS 已读记录 | 7 |
| 36 | 正文高亮 | 12 |
| 37 | JS 单文件书源配置 | 3 |
| 38 | 应用日志 | 5 |
| 39 | 规则订阅 | 7 |
| 40 | 本地 TXT 全文搜索 | 4 |
| 41 | 契约外已实现 FFI 补登记（§2.41，待 BookApi 封装） | 5 |
| 42 | TTS 真实合成管线 | 2 |
| 43 | 缓存写/购买/批量下载/导出扩展（§2.43，Task #136） | 11 |
| 44 | 字典规则操作 | 7 |
| 45 | 图片磁盘缓存 | 3 |
| 46 | 音频章节文件缓存 | 4 |
| 47 | 音频章节预下载 | 2 |
| 49 | 视频弹幕数据链 | 1 |
| 50 | 视频弹幕解析 | 1 |
| 51 | 直链上传 | 1 |
| 52 | 书签标记 | 5 |
| 53 | 隐私与私密标记 | 12 |
| | **合计（§2.x 附录行合计）** | **340** |

> 口径说明（2026-08-15 程序化计数校准，2026-09-13 C2 批1 增 §2.45 字典规则 7 方法、书源作用域批次增 §2.8 替换规则 1 方法 `applyReplaceRulesToSource`、替换规则预览批次再增 §2.8 1 方法 `previewReplaceRule`、2026-09-24 换源预拉缓存批次增 §2.4 2 方法、2026-09-26 项 B/B1 增 §2.3 1 方法 `submitWebviewResultWithCookies`、2026-09-28 STAGE3-C2B 增 §2.16 单章缓存失效 1 方法 `clearChapterCache`、2026-09-28 P2-28c 增 §2.43 目录实时刷新 1 方法 `listCachedChapters`、2026-09-29 P2-29 增 §2.43 目录下载中态查询 1 方法 `listDownloadingChapters`、2026-09-29 P4-2a 增 §2.46 图片磁盘缓存 2 方法 `saveImageCache`/`getImageCache`、2026-10-03 cbz 批 B 增 §2.34 本地漫画页读取 1 方法 `cbzReadPage`、2026-10-04 B1 增 §2.47 音频章节文件缓存 4 方法、2026-10-03 B2 增 §2.48 音频章节预下载写入 2 方法 `audioCacheDownload`/`audioCacheCancel`，取代人工统计）：
> - 附录行合计 **340** = §2.x 实际方法行总数；其中与 BookApi 同名行 **323**（255 + 字典规则 7 + 书源作用域 1 + 替换规则预览 1 + 换源预拉缓存 2 + WebView cookie 回流 1 + 单章缓存失效 1 + 目录实时刷新 1 + 图片缓存 3 + 本地漫画页读取 1 + 音频缓存 4 + 音频缓存写入 2 + 视频弹幕 2 + RSS 源开关 1 + WebDAV 服务器 CRUD 3 + HTTP 日志开关 1 + RSS 列表/分类/分页 4 + RSS 正文 1 + RSS 只读缓存 1 + 直链上传 1 + 备份探测 1 + RSS WebView 宿主桥 1 + 7z 导入 2 + readConfig 单键写 1 + 高亮规则正文匹配 1 + 批量删除 1 + 阅读记录开关 1 + 设置编码 1 + WebDAV 备份保留清理 1 + TXT 目录规则 1 + 过期搜索清理 1（批9b-1）+ 书签标记 5（批7b-1）+ 隐私与私密标记 12（批9a + 批9d 生物识别 4）+ 替换规则排序 1（批12）+ 图片动作执行 1（批20）；失败章查询经 §1.7 命名等价对登记）、§1.7 命名等价对侧的不同名 FFI 行 **14**（3 个 JS 单文件 + 4 个缓存系 + 3 个登录 V2 + 4 个登录方法）、`cacheGetChapter` 独立行 1（§2.41；BookApi `getCachedChapter` 另在 §2.16 同名登记，不重复计数）、
>   尚未封装进 BookApi 的纯 FFI **1**（`chapterPayAction`；`backup_inspect` 已由批17b Dart 封装计入 BookApi）；`rssUpdateSource` 独立行 1（已由 BookApi `updateRssSource` 封装接通，`rust_api_search_rss.part.dart:246-247`，2026-10-26 审查批5 勘误：原记「纯 FFI 2」过时）。
> - BookApi 代码计数 **338** = 323 同名行（255 + 字典规则 7 + 书源作用域 1 + 替换规则预览 1 + 换源预拉缓存 2 + WebView cookie 回流 1 + 单章缓存失效 1 + 目录实时刷新 1 + 图片缓存 3 + 本地漫画页读取 1 + 音频缓存 4 + 音频缓存写入 2 + 视频弹幕 2 + RSS 源开关 1 + WebDAV 服务器 CRUD 3 + HTTP 日志开关 1 + RSS 列表/分类/分页 4 + RSS 正文 1 + RSS 只读缓存 1 + 直链上传 1 + 备份探测 1 + RSS WebView 宿主桥 1 + 7z 导入 2 + readConfig 单键写 1 + 高亮规则正文匹配 1 + 批量删除 1 + 阅读记录开关 1 + 设置编码 1 + WebDAV 备份保留清理 1 + TXT 目录规则 1 + 过期搜索清理 1（批9b-1）+ 书签标记 5（批7b-1）+ 隐私与私密标记 12（批9a + 批9d 生物识别 4）+ 替换规则排序 1（批12）+ 图片动作执行 1（批20）；失败章查询经 §1.7 命名等价对登记）+ 14 命名等价（§1.7：3 个 JS 单文件 + 4 个缓存系 + 3 个登录 V2 + 4 个登录方法）+ 1 BookApi 别名（`getChaptersWithMeta` → `getChapters`，复用同一 FFI，不新增 §2.x 行）。测试自动强制两口径与闭合关系（§2.48 2 方法为契约先行，`book_api.dart` 实现批封装后程序化计数转齐）。
> - 2026-10-26 审查批5：§1.7 表 B 新增 **123 条**「Rust FFI 导出 ↔ BookApi 同名方法」机械映射（`ffi.rs` pub fn 面 × `rust_api*.dart` 调用面程序化提取，含 3 条跨导出复合实现 `initialize`/`updateBookmark`/`parseEpub` 与 2 条无前缀命名 `initialize`/`getVersion`）；§1.7 等价对总数 15→**138**（改名等价 15 + 同名 FFI 映射 123）。该表不改变 §2.x 行数与 BookApi 计数，仅补齐命名等价登记债。审查批6 再 +1 对（`rssSourceSetEnabled`，并更正 `enableRssSource` / `disableRssSource` 两对的 FFI 列）：同名 FFI 映射 **124**、总数 **139**。批8 再 +10 对（WebDAV 云同步既有 7 方法补登记 + servers CRUD 新增 3 方法）：同名 FFI 映射 **134**、总数 **149**。批11 再 +1 对（`setHttpLogRecording` ↔ `set_http_log_recording`）：同名 FFI 映射 **135**、总数 **150**。批15b 再 +4 对（`rssSortUrls`/`rssClearSortCache`/`rssRefreshArticles`/`rssLoadMoreArticles`）：同名 FFI 映射 **139**、总数 **154**。批15c 再 +1 对（`rssFetchContent` ↔ `rss_fetch_content`）：同名 FFI 映射 **140**、总数 **155**。批15f 再 +1 对（`rssListCachedArticles` ↔ `rss_list_cached_articles`）：同名 FFI 映射 **141**、总数 **156**。
> - 2026-10-26 批11（HTTP 采集接线 + `/refreshToc`）：FFI 加法式新增 `setHttpLogRecording`（§2.10），§2.10 4→**5**、附录合计 300→**301**、BookApi 297→**298**、§1.7 表 B 134→**135**（总数 149→**150**）；`legado-net` 新增采集 trait/开关/单槽（`http_log` 模块，不依赖 server），`legado-server` 注册 ring 存储实现并删除段评链手工记录（防双记录）；脱敏补齐「敏感名路径段的下一段」规则（审查批4 P2-4）；Web 端新增 GET `/refreshToc`（复用既有刷新链）。**采集范围登记**：`LegadoClient` 统一出口（含重试/followRedirects 变体/流式）为唯一采集点；`legado-net` 内 `webdav.rs`/`remote_book.rs` 与 `legado-server` handler 内裸 reqwest（TTS/音频/源更新下载）不在采集面内。
> - 2026-10-27 批16a（直链上传）：§2.51 新增 1 方法 `directLinkUpload`（`legado-net::direct_link_upload` + `legado-ffi/src/api/direct_link_upload_api.rs`）；附录合计 307→**308**、BookApi 304→**305**、§1.7 表 B 141→**142**（等价对总数 156→**157**）；方法模块 47→**48**。参考版字段集裁决：仅 4 字段（无口令/无 `expiryDate`）。
> - 2026-10-29 批32（readConfig 单键写）：§2.2 新增 1 方法 `updateReadConfigField`（`legado-db::BookRepository::update_read_config_field` 复用 + `legado-ffi/src/api/bookshelf.rs` + `ffi::book_update_read_config_field`）；附录合计 312→**313**、BookApi 309→**310**（296 同名行 + 14 命名等价）、§1.7 表 B 146→**147**（等价对总数 161→**162**）。
> - 2026-10-29 批35（书架标签内容 + 批量删除原文件 + 书籍级阅读记录开关）：§2.2 新增 2 方法 `deleteBooks` / `setReadRecordDisabled`（`legado-ffi/src/api/bookshelf.rs` + `ffi::bookshelf_delete_books` / `book_set_read_record_disabled`），§2.12 `putReadRecord` 增加可选参数 `bookUrl`（`ffi::read_record_upsert` 增 `Option<String>` 入参）；DB `SCHEMA_VERSION` 116→117（`books.disableReadRecord INTEGER NOT NULL DEFAULT 0`）。附录合计 314→**316**、BookApi 311→**313**（299 同名行 + 14 命名等价）、§1.7 表 B 148→**150**（等价对总数 163→**165**）。§2.12 方法数保持 6。
> - 2026-10-29 批37b（阅读器 charset 真接线 + 单列写）：§2.2 新增 1 方法 `setBookCharset`（`legado-ffi/src/api/bookshelf.rs::set_book_charset` + `ffi::book_set_charset`）；`legado-book` 新增 `get_chapters_with_charset` / `get_chapter_content_with_charset`，FFI 阅读/导出/离线缓存链路消费 `books.charset`。附录合计 316→**317**、BookApi 313→**314**（300 同名行 + 14 命名等价）、§1.7 表 B 150→**151**（等价对总数 165→**166**）。
> - 2026-10-29 批40（WebDAV 备份族）：§2.28 新增 1 方法 `webdavPruneBackups`（`legado-net/src/webdav.rs::prune_backup_files` + `legado-ffi/src/api/webdav_api.rs::webdav_prune_backups` + `ffi::webdav_prune_backups`）；备份上传复用 `webdavUploadFile`。附录合计 317→**318**、BookApi 314→**315**（301 同名行 + 14 命名等价）、§1.7 表 B 151→**152**（等价对总数 166→**167**）。
> - 2026-10-30 批43（TXT 目录规则作用于当前书）：§2.2 新增 1 方法 `setBookTocRule`（`legado-ffi/src/api/bookshelf.rs::set_book_toc_rule` + `ffi::book_set_toc_rule`）；`legado-book` 新增 `LocalBook::get_chapters_with_rule` / `TxtParser::get_chapters_with_rule`（显式规则 + 未命中回退默认），FFI `reader.rs::get_chapters` 消费本地 TXT 的 `books.tocUrl`。无 Schema 迁移（复用既有 `books.tocUrl`）。附录合计 318→**319**、BookApi 315→**316**（302 同名行 + 14 命名等价）、§1.7 表 B 152→**153**（等价对总数 167→**168**）。
> - 2026-11-03 批9b-3 回修（窗口必需集与复合 URL）：零方法计数变化（§2.46 3、附录合计 321、BookApi 319、§1.7 表 B 155）——当前章必需正文、后窗缺失整跳、前窗缺失仅跳章、卷章跳过、复合 URL 完整保留、`chapter.imgUrl` 纳入保留集合、SQL 窗口查询；差异/竞态见 §2.46 回修注。
> - 2026-11-03 批9b-3（漫画图片保留清理）：§2.46 新增 1 方法 `retainComicImages`（`legado-ffi/src/api/image_cache_api.rs::retain_comic_images` + `ffi::retain_comic_images`）；§2.46 2→**3**、附录合计 320→**321**、BookApi 318→**319**（304 同名行 + 14 命名等价 + 1 别名）、§1.7 表 B 154→**155**（等价对总数 170→**171**）。窗口/安全语义与 Dart 接线见 §2.46 批9b-3 注。
> - 2026-11-09 批7b-1（书签标记数据层）：新增 §2.52 5 方法（`legado-core::models::BookMarking` + `legado-db::BookMarkingRepository` + `legado-ffi/src/api/book_marking_api.rs` + `ffi::book_marking_*`），DB `SCHEMA_VERSION` 117→118 建 `book_marks` 表与 `(bookUrl, chapterIndex)` 索引；方法模块 48→**49**、附录合计 321→**326**、BookApi 319→**324**（309 同名行 + 14 命名等价 + 1 别名）、§1.7 表 B 155→**160**（等价对总数 171→**176**）。备份口径与无外键说明见 §2.52 注（参考版与本实现均无外键）；划词卡/编辑 Sheet/目录笔记页/正文渲染属 7b-2。
> - 2026-11-09 批9a（隐私与私密标记数据层）：新增 §2.53 8 方法（`legado-core::privacy` + `legado-db` 仓储 + `legado-ffi/src/api/privacy_api.rs` + `ffi::privacy_*` / `set_books_private` / `get_private_book_urls` / `set_book_group_private` / `get_private_group_ids`），DB `SCHEMA_VERSION` 118→119 为 `books` / `book_groups` 增 `isPrivate INTEGER NOT NULL DEFAULT 0`；方法模块 49→**50**、附录合计 326→**334**、BookApi 324→**332**（317 同名行 + 14 命名等价 + 1 别名）、§1.7 表 B 160→**168**（等价对总数 176→**184**）。密码凭据仅存 caches `config:private_password_salt` / `config:private_password_verifier`（Base64，PBKDF2-HMAC-SHA256 210000 次 / 32B），不存明文且不纳入备份；`isPrivate` 标记纳入备份往返。本批不做 UI/路由/生物识别。
> - 2026-10-29 批40b（WebDAV 备份族审查回修）：零方法计数变化（§2.28 11、附录合计 318、BookApi 315、§1.7 表 B 152）。`prune_backup_files` 收紧为严格命名 + href 删除键（§2.28 批40 注③）、`WebDavClient` 增加连接/请求超时（注⑨c）；Dart 侧本地书相对标识上传前解析（注⑥）、恢复与备份共用互斥（注⑧）、导入后自动上传串行、保留数 clamp、恢复后重读设置行、自动备份锁内复检；调度边界与本地备份缺口登记见注⑦⑨。
> - 2026-10-29 批34（高亮规则正文匹配 + MVP 渲染）：§2.36 新增 1 方法 `highlightRuleMatch`（`legado-ffi/src/api/highlight_api.rs::highlight_rule_match` + `ffi::highlight_rule_match`，复用 `HighlightRuleRepository::find_enabled_by_book`）；附录合计 313→**314**、BookApi 310→**311**（297 同名行 + 14 命名等价）、§1.7 表 B 147→**148**（等价对总数 162→**163**）。偏移映射与渲染边界见 §2.36 批34 注。
> - 2026-10-26 批17a（加密原版备份恢复）：§2.11 新增 1 方法 `backupInspect` + `restore` 可选 `password` 参数；附录合计 308→**309**、BookApi 保持 **305**（契约先行）、§1.7 表 B 142→**143**（等价对总数 157→**158**）。算法/错误码/内容恢复口径见 §2.11 批17a 补记。
> - 2026-10-26 批17b（备份密码 Dart 封装与 UI）：`backupInspect` 封装进 BookApi 并返回强类型 `BackupInspectInfo`（`lib/src/models/backup_inspect_info.dart`），`restore` 增加可选 `password`；BookApi 305→**306**（292 同名行 + 14 命名等价），附录合计 **309** 与 §2.x 行数不变。UI 口径见 §2.11 批17b 补记。
> - 2026-10-27 批21a（RSS WebView `preloadJs` 宿主桥）：§2.5 新增 1 方法 `rssWebViewHostCall`（`legado-ffi/src/api/rss_web_bridge.rs`）；附录合计 309→**310**、BookApi 306→**307**（293 同名行 + 14 命名等价）、§1.7 表 B 143→**144**（等价对总数 158→**159**）。Dart 侧仅纯委托直通，channel/握手/动作转发属批21b。
> - 2026-10-26 批8 审查回修：零 FFI 签名/方法计数变化（§2.x 300、BookApi 297、§1.7 149 对全部不变）；仅登记恢复边界语义（v1/v2 偏好回填 / v3 以 DB 为准）、恢复主键保真（含 `id = 0`）、备份明文安全口径差异与 `webdavServerDelete` 预留状态。
> - 2026-08-15 之前的人工校准（F3-10 等）已由程序化计数取代，历史演进见 git 历史。
