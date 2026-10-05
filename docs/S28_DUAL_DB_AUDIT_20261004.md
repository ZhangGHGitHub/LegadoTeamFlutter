# S28 §二.8「双 DB 连接」矛盾专项审计（2026-10-04）

- 审计对象：V2 审计报告称「§二.8 双 DB 已治/已消」，但代码 `rust/legado-server/src/server.rs:44` 仍自开 DB 连接。
- 审计方式：只读（未修改任何源码；本文档为唯一落盘产物）。HEAD `0ec0859fb7`。
- 所有结论均给出 `文件:行号` 证据；无法核实处明确标注「未找到/未实测」。

---

## 一、结论摘要（先读这里）

1. **V2 的「已治」是误判**：它把「AppState 只有一个 `Mutex<Database>`」当作「单 DB」证据，但那个 `Database` 本身就是第二连接池（`server.rs:44` 自开）；其「当前 server 未启动」的前提在审计时点（09-02）已不成立——设置页 Web 服务开关自 08-06 起即接线到真实 `bridge.serverStart`。
2. **真正的尖锐问题不是 WAL 双池写冲突**（两侧均有 WAL + busy_timeout=5000 兜底），而是 **Web 服务路径的 db_path 硬编码相对路径 `"legado.db"`**（`server_api.rs:114`）：Android 上要么打开失败（用户仍被告知启动成功、错误只 eprintln），要么在进程 cwd 生成第二个空库（Web 书架读空数据、用户写入进分裂库）。Task #76 只把 **MCP 独立端口路径**修成复用 `current_db_path()`，Web 路径漏改。
3. **cookie sink 的前期结论已过时**：`db_open` 自 2026-09-23 上游同步起即注册 legado-js 进程级全局 `CookieSink`（`ffi.rs:185`），server 同进程，JS `setCookie` **能**落库。真正残余的 cookie 缺口是 server 抓取链**每请求新建 HTTP 客户端**（`web_book.rs:201`），响应 Set-Cookie 不共享、不落库，App 登录态进不了 server 抓取链。

风险分级：**P1 应修**（非 P0）。详见 §五。

---

## 二、任务 1：还原「矛盾」的真相

### 2.1 三代审计表述原文

**V1**（`docs/过期文档/REFACTOR_DEFECT_AUDIT_20260828.md:196`）：

> | 8 | Server/FFI 双 DB 连接（潜伏） | ❌ 未修复 | `server/state.rs` 仍自带 `Mutex<Database>` |

**V2**（`docs/REFACTOR_DEFECT_AUDIT_V2_20260902.md:40`，表格行 8；`:97` 将其列入「已治」清单）：

> | 8 | Server/FFI 双 DB 连接潜伏 | ❌ | ✅ 已消 | `legado-server/src/state.rs:11 pub db: Mutex<Database>` 单 DB，无独立 `Mutex<Connection>`；`legado-ffi` 侧 `Pool` 与 server 共享同一文件但当前 server 未启动，未爆发。V1 "潜伏"标签可降级为"设计约束：server 启用前需明确连接归属"。 |

V2 的论证逻辑拆开看是三点：
- ① `state.rs:11` 是 `Mutex<Database>` 而非 `Mutex<Connection>` ⇒ 算「单 DB」；
- ② ffi 侧 Pool 与 server「共享同一文件」；
- ③ 「当前 server 未启动，未爆发」。

**09-03 综合审计**（`docs/REFACTOR_CONSOLIDATED_AUDIT_20260903.md:27`）实际已把 §二.8 **重新打开**：

> **剩余确凿缺口（09-03 修订）**：Web 服务功能域未接线（N3）与配套双 DB 潜伏（§二.8）、REST 死降级路径（§二.7）为仅存决策簇缺口

`:180` 给出合并设计但未实施：

> ① 若本版交付 Web 服务：设置开关 → `startServer(webPort)`，双 DB 访问统一（server 复用 FFI db_state 连接或下沉共享 DB 层）

### 2.2 `server.rs:44` 自开的是什么

`rust/legado-server/src/server.rs:42-49`（`start_server`）：

```rust
pub async fn start_server(config: ServerConfig) -> Result<(), Box<dyn std::error::Error>> {
    // 初始化数据库（含 schema 迁移）
    let db = legado_db::init_database(&config.db_path)?;
    let state = Arc::new(AppState { db: Mutex::new(db), ... });
```

- `legado_db::init_database` → `Database::open`（`rust/legado-db/src/connection.rs:62-77`）：临时连接跑迁移（含 `repair_legacy_columns`/`cleanup_zombie_books` 写操作，`connection.rs:162-183`）后建 **r2d2 连接池，max_size=16**（`connection.rs:22`）——**是完整的第二连接池，不是裸 rusqlite Connection**。
- 调用链：Flutter 设置页 `_toggleWebService`（`flutter_legado/lib/src/screens/settings_screen.dart:85-89`，`await api.startServer()`）→ `RustApi::startServer`（`flutter_legado/lib/src/services/rust_api_media_format.part.dart:71-73`）→ `bridge.serverStart` → `ffi_server_start`（`rust/legado-ffi/src/bridge.rs:1359`）→ `server_api::server_start`（`rust/legado-ffi/src/api/server_api.rs:100-133`）→ `start_server`（`server.rs:42`）。
- **db_path 来源**：`server_api.rs:111-115` 硬编码 `db_path: "legado.db"`（相对路径）。而 ffi 主侧路径由 Dart 决定（`flutter_legado/lib/src/services/rust_api.dart:390-396`）：Android/iOS = `<ApplicationDocumentsDirectory>/legado.db`（绝对路径）；桌面 = `<cwd>/legado.db`。
- 是否同一文件：
  - **桌面**：cwd 未变时相对路径解析到同一文件（双池同文件）。
  - **Android**：相对路径按进程 cwd 解析，与 Documents 目录**无理由一致**。代码自己承认这一点——`db_state.rs:24-26` 注释：「供独立 MCP 服务等二次连接池场景复用同一 DB 文件（WAL 并发安全），**避免硬编码相对路径在 Android cwd 不可写/桌面双库数据漂移**」。Task #76 据此给 **MCP 路径**修了（`server_api.rs:232-234` 取 `current_db_path()`、`:253` 在该路径建二次池），**Web 路径（`server_api.rs:114`）漏改**。Android 上 cwd 的实际取值未实测（本次不操作设备），但「打开失败」与「cwd 可写时生成第二个空库」两者必居其一，均属缺陷态。

### 2.3 判定：治了留尾巴，还是报告与代码不符？

**结论：报告与代码不符（误判），且误判从 V2 撰写当天就存在。**

证据链：
1. V2 的核心证据①（`state.rs:11` 是 `Mutex<Database>`「单 DB」）不成立：`AppState.db` 里装的是 server **自己** `init_database` 开出来的第二池实例（`server.rs:44-46`），「无独立 `Mutex<Connection>`」与「是否与 ffi 共用连接」无关。V1 的描述（「server/state.rs 仍自带 `Mutex<Database>`」）反而是准确的。
2. V2 的前提③「当前 server 未启动」在审计时点不成立：`git log -S startServer -- settings_screen.dart` 显示 08-06 `522e1c1bed`（v2.0.2 批次2）已引入 `_toggleWebService`→`api.startServer()`；在 V2 时代 commit `249138904c` 上，`settings_screen.dart:85` 的调用与 `rust_api.dart:1990-1992` 的真实实现（`await bridge.serverStart(port: port)`）均在位，且 `bookApiProvider` 生产环境返回 `RustApi()`（`providers.dart:15-18`，`USE_MOCK` 默认 false）。V2 行 7 所称「全 lib/ 零处 serverStart 调用（rust_api.dart:1962 serverStart 定义但无调用方）」核实为**检索口径错误**：UI 层经 `api.startServer()` 间接调用，直接 grep 桥接层 camelCase 名漏掉了间接链。
3. 记忆线索中的「P5 批次注入」确实存在（`handlers/web_book.rs:167-240` `with_state_db` 三级锁 + `server_deps` 三闭包，见 §3.4），但它把 **handler 数据面统一到 AppState DB**，并没有把 **AppState DB 统一到 ffi 池**——不构成 §二.8 的「治」，且 server.rs:44 的自开路径根本不经过它。
4. 09-03 综合审计的措辞（「N3 未接线 + 配套双 DB 潜伏」为决策簇缺口）是正确的；N3 后续被交付（Web 服务开关卡片化 `87eaecd8d8` 2026-09-16），但配套的「双 DB 访问统一」设计（`:180`）**未实施**——这就是今天 `server.rs:44` 仍在的根因。

---

## 三、任务 2：当前双 DB 的真实风险面

### 3.1 写-写冲突与 WAL 边界

两侧 open 参数完全一致（同一 `legado_db` 库）：
- 每个池连接 `journal_mode=WAL`（`connection.rs:36`）、`foreign_keys=ON`（:37）、`synchronous=NORMAL`（:38）、**`busy_timeout=5000`**（:39，`PragmaCustomizer::on_acquire`）；初始化临时连接同款（`connection.rs:206-213`）。
- ffi 主侧同走 `init_database`（`ffi.rs:180`）⇒ 参数一致。

WAL 下并发语义：读-读/读-写并发无阻塞；**写-写单写者串行**，第二写者最多等 5 秒，超时返回 `SQLITE_BUSY`（表现为 REST 500 / `LegadoError::Database`）。两侧事务均为短事务（单语句或 `in_transaction` 批量，`connection.rs:248-265`），实际碰撞概率低。同进程多池与跨进程多连接在 SQLite 文件锁层面行为一致，**无数据腐化风险，只有 BUSY 报错面**。

次要噪音：server 每次启动会在主库上重跑 `auto_migrate`（版本相同时为幂等校验 + `cleanup_zombie_books` 空操作 DELETE，`connection.rs:162-183`），与 ffi 池并发时有一次性写锁竞争，busy_timeout 可覆盖。

### 3.2 server 自开连接的实际使用路径清单（核心交付）

路由注册：`rust/legado-server/src/routes.rs:25-207`（web 全量）；MCP：`server.rs:67-87` + `routes.rs:17-18`（web 端口也挂 `/mcp/tools|/mcp/call`）与独立端口 `serve_mcp`。所有 handler 经 `state.db.lock().await` 访问**同一个第二池实例**（`AppState.db`，`state.rs:11-13`）。

生产段写路径（写标记已剔除 `#[cfg(test)]` 段；各文件 test 起始行：bookshelf 110 / source 182 / review 未检出 / toc_update 417 / cache 89 / audio 406 / mcp 1438）：

| 路由 | 方法 | 处理器证据 | 读/写 |
|---|---|---|---|
| /api/books | POST | bookshelf.rs:68 `repo.insert(&book)` | **写** |
| /api/books/{id} | PUT | bookshelf.rs:94 `repo.update` | **写** |
| /api/books/{id} | DELETE | bookshelf.rs:106 `repo.delete` | **写** |
| /api/reviews | POST | review.rs:60 `repo.insert` | **写** |
| /api/sources | POST | source.rs:97 `repo.insert` | **写** |
| /api/sources/{id} | PUT | source.rs:153 `repo.update` | **写** |
| /api/sources/{id} | DELETE | source.rs:178 `repo.delete` | **写** |
| /api/bookshelf/update-toc(/single) | POST | toc_update.rs:264 `book_repo.update` | **写** |
| /api/cache/chapters | POST | cache.rs:63 `repo.insert(&chapter)` | **写** |
| /api/audio/*（chapter-media/play 等） | POST | audio.rs:378 `CacheBookRepository::insert` | **写** |
| /mcp/call（web+独立端口） | POST | mcp.rs:579 insert book / :696 update source / :847 insert bookmark | **写** |
| /api/rule-update/apply | POST | rule_update.rs 生产段无直接 DB 写（测试段 :314） | 读+网络 |

只读路径（生产段仅 `find/get/list` 或无 DB）：GET /api/health、/api/books（bookshelf.rs:31）、/api/books/{id}、/api/books/{id}/chapters、/api/books/{id}/chapters/{i}/content（reader.rs:23-93 查完即放，**正文不回写 DB**）、/api/search（search.rs:42-44 读 books 表）、/api/sources GET、/api/sources/repos|updates|check|check-batch（source_update.rs:178-240 读；check 走网络）、/api/webbook/search|info|chapters|content（读 loginHeader_/books.variable/infoMap_ 后走网络抓取，web_book.rs:200-244，生产段无 DB 写）、/api/tts/*、/api/audio/chapters、/api/rss/*、/api/cache/stats、DELETE /api/cache/book/{url}（cache.rs:85 delete——**写**）、/api/download/*（download.rs 无 DB 标记，内存态管理器）、/api/debug/*（debug.rs 读）、/api/read-aloud/*（无 DB）、/api/auto-tasks list|export（读；create/update/delete/run 为**写**，auto_task_handler.rs 生产段经 repo，写标记 :225 为测试路由断言，run/update 走 repo.update/put）、/api/ws/*（search_ws/debug_ws 读 + 网络）、静态文件 fallback（routes.rs:20 `ServeDir("web-dist")`）。

**小结：server 第二池的写面覆盖 books、book_sources、reviews、bookmarks、auto_task_rules、chapters/cache、cachedBook 共 7 类表、约 12 个端点族；其余为读。**

### 3.3 数据一致性（缓存/内存态失效面）

- ffi 侧对 server 所写各表**无长驻内存缓存**：全部经 `db_state::with_database` 现取池连接现读（`db_state.rs:99-108`）⇒ server 写入后 ffi 下一次查询即见新值；Dart 屏级列表刷新后可见。无失效通知机制，也暂无必要。
- 反向（server 读 ffi 写的缓存键）：server 只**读** `caches` 表键 `loginHeader_<url>`/`userInfo_<url>`/`infoMap_<tag>`（web_book.rs:211-217、:233-244），写方是 ffi `source_login_cache`（内存优先 + DB 双写，`api/source_login_cache.rs:9-48`，内存写穿 DB、读内存优先 miss 回落 DB）。server 不写这些键 ⇒ 不产生「server 写了 ffi 内存缓存读旧值」的回路。
- JS `cache.put` 走 legado-js **内存 LRU + 磁盘文件**，不碰 DB `caches` 表（`legado-js/src/host_api/cache_store.rs:1-16`）⇒ server 侧 JS 无法绕道写 loginHeader_ 键。
- 已登记的分叉（非 DB 但同族）：限速注册表 ffi/server 各持一份 static（web_book.rs:122-133「[P2 互认]」注释明确「窗口仍会分叉（弱于真单例）——收敛留待后续裁决」）。
- **文件身份才是最狠的一致性问题**：若 Android 上 server 打开的是 cwd 下的第二个空库，Web 书架页将读到**空书架**，用户经 REST 的增删改全部写进分裂库——不是「读到旧值」，是「读到另一个库」。桌面同文件时无此问题。

### 3.4 连接生命周期与多实例

- 建：`start_server` 每次调用新建（server.rs:44-49）；`serve_mcp` 由 `mcp_start_internal` 在 spawn 前同步建（server_api.rs:253-255）。
- 活：随 `Arc<AppState>` 存活至 axum serve 结束/任务 abort（server_stop → `handle.abort()`，server_api.rs:138-153；MCP 同款 :287-302，且 abort 后 `block_on(handle)` 等待退出）。`Database` drop 时池与连接随之关闭（r2d2 语义）。`SERVER_RUNTIME` 静态常驻不关（server_api.rs:19）。
- 多实例：Web 侧 `SERVER_RUNNING` 先查后置（server_api.rs:101-130）存在 check-then-act 竞态——并发双调可能 spawn 两个任务，第二个 bind 失败仅 eprintln；单用户 UI 开关场景概率极低。Web + MCP 独立端口可并存 ⇒ 峰值 3 个池（ffi 16 + web 16 + mcp 16 上限，实际 server 侧因 `Mutex<Database>` 串行只用 1 条持驻连接）。
- **静默失败缺陷**：`server_start` 在 spawn **前**返回 `Ok("Server started on port {port}")` 并置 RUNNING=true（server_api.rs:129-132）；`start_server` 内 DB 打开失败的错误在任务里只 `eprintln!`（:117-119）。Android 上 DB 打不开时：用户看到「已启动」，实际进程已死；UI 随后 `getServerStatus()` 因竞态可能显示 true 也可能 false（settings_screen.dart:86-88）。

### 3.5 cookie sink：前期结论修正 + 残余缺口

**修正**：前期调研所称「server 无 cookie sink：依赖方向 legado-ffi → legado-server 使其无法注册，server 的 JS 写 cookie 仍内存态」**已过时**。现状：
- `db_open` 在进程启动即注册基于 `CookieRepository` 的持久化下沉并回填（`ffi.rs:182-185`，2026-09-23 上游同步注释）；
- 下沉注册进 **legado-js crate 级全局 first-wins 槽位**（`legado-js/src/host_api/cookie_store.rs:57-66` `static COOKIE_SINK: OnceLock`），由 `http_state.rs:292-301 register_js_cookie_sink` 写入；
- `JsCookieDbSink` 的 upsert/remove/remove_all/load_all 全部经 `crate::db_state::with_database`（**ffi 全局池**）读写同一张 `cookies` 表（`http_state.rs:230-301`）。

由于 legado-server 与 legado-ffi **同进程**（server 是 ffi 的依赖 crate，`legado-ffi/Cargo.toml:18`），server 侧 JS（webbook 书源 JS、MCP eval_js）走的 `legado_js::host_api::cookie_store` 是同一进程级实例 ⇒ **JS setCookie 能落库、能回读**。此路径不需要修。

**残余缺口（真实存在）**：server 抓取链的 HTTP 客户端与 cookie 面：
1. `server_deps` **每次调用**新建 `LegadoClient::new(LegadoClientConfig::default())`（web_book.rs:200-202），而 build_engine/server_deps 被 webbook 四端点、reader content（reader.rs:93）、audio（audio.rs:349）、toc_update（toc_update.rs:293）**逐请求调用** ⇒ 每请求一个全新客户端 + 全新内存 cookie jar，响应 Set-Cookie 随请求结束即弃，**不落库**（`DbCookiePersistence` 只挂在 ffi `shared_client` 上，http_state.rs:303-329 一带）；也**不预载** DB/共享内存 cookie（抓取前仅 merge legado-js 全局 store：fetcher web_book.rs:999/1119/1164）。
2. 用户可见影响（具体踩法）：用户在 App 内登录了某书源（cookie 在 ffi 共享 jar/DB）→ 打开 Web 服务用浏览器搜该书源/读正文 → server 侧抓取请求**不带会话 cookie** → 源返回登录页/403/空数据，除非该源恰好走 `loginHeader_` 缓存键（server_deps 闭包会读）。server 侧连续抓取（如toc 批量更新）中途源种下的 cookie 下一请求即丢，需 cookie 续命的源表现为间歇性失败。
3. 附带性能面：每请求重建 reqwest 客户端（连接池无法复用）。

---

## 四、任务 3：与原版 Android 对照（语义基线）

- 原版 Web 服务是**同进程** Android Service：`app/src/main/java/io/legado/app/service/WebService.kt:42`（`class WebService : BaseService()`），`:204 upWebServer()` 起 HttpServer（`:90` `httpServer: HttpServer?`，`:194-195` stop 生命周期）。
- 控制器**直查 Room 单例 `appDb`**：`app/api/controller/BookSourceController.kt:30`（`appDb.bookSourceDao.all`）、`:45`/`:65`（insert）、`:202`（getBookSource）；`BookController.kt:67`（`appDb.bookDao.all`）、`:129`。即原版 = 单进程、单 DB 实例（Room 单写连接），Web 服务与 App 界面共享同一数据面，无跨池、无文件身份、无缓存分叉问题；cookie 同理共用应用内 CookieStore。
- 我方差异的实质：把 server 做成**同进程第二个连接池**（不是第二个进程），却引入了原版不存在的四件事——①db 文件身份漂移（相对路径，Android 上可分裂成两库）；②跨池写-写 BUSY 面（已被 WAL+busy_timeout 压低）；③server 启动时对主库重复跑迁移；④限速注册表/HTTP cookie 面双份。
- 结论：**「双连接」本身就是与原版语义基线的偏离**；对齐基线的方向不是「接受双连接再打补丁」，而是回到单池。

---

## 五、任务 4：分级结论与修复建议

### 5.1 总体风险等级：P1（应修），非 P0

| 项 | 等级 | 依据 |
|---|---|---|
| Web 服务路径 db_path 硬编码相对路径 + 启动失败静默（`server_api.rs:114`、`:117-119`、`:129-132`） | **P1** | Android 上功能级损坏（打不开→假成功；打得开→分裂空库、Web 书架空数据、用户写进错库）；桌面正常同文件。不腐化主库故非 P0 |
| 同文件双池写-写 BUSY 面（桌面 Web + MCP 路径） | P2 | WAL+busy_timeout=5000 两侧兜底（connection.rs:36-39），短事务碰撞概率低；无腐化，偶发 500/BUSY 报错 |
| server 抓取链 per-request 客户端 cookie 隔离（web_book.rs:201） | P2 | §3.5 的登录态/会话 cookie 用户可见退化 |
| server_deps/with_state_db 注入面 | 无风险 | P5 批次实现正确且带锁序纪律（web_book.rs:150-181），与本议题无关 |

### 5.2 修复建议（按优先级）

**修法 A（P1，最小，约 10-20 行，FFI 契约不变）**
`server_start`（server_api.rs:110-122）改为：
1. `db_path` 不再硬编码 `"legado.db"`，改取 `crate::db_state::current_db_path()`；未初始化返回 `LegadoError::Internal`（逐字对齐 `mcp_start_internal` 的守卫，server_api.rs:227-234）；
2. 把 `legado_db::init_database(&db_path)` 提到 **spawn 之前同步执行**，失败即返回 Err——消灭「假成功」；
3. `start_server` 增加带 db 参数的变体（如 `start_server_with_db(config, db)`），原 `start_server` 保留给独立二进制/测试。

**修法 B（P2，推荐随后做，约 40-60 行，FFI 契约不变）**
彻底统一连接来源：`server_api` 从 `db_state::DB_POOL` 构造 `Database::from_pool(&pool)`（现成 API，connection.rs:123-131）注入 `AppState.db`（`serve_mcp` 本就收 `db` 参数，server_api.rs:266，把 `:253` 的 `init_database` 二次建池换掉即可）；`mcp_start_internal` 同改。效果：单一池、无二次迁移、无跨池 BUSY、server 与主应用数据面强一致——即 09-03 综合审计 `:180` 设计的「server 复用 FFI db_state 连接」。依赖方向可行：legado-server 已依赖 legado-db（其 Cargo.toml `[dependencies]`），注入发生在 legado-ffi 侧，无需反向依赖。`Mutex<Database>` 形状不变，handler 零改动。

**cookie 残余面（P2，约 40-60 行，不触契约）**
1. server crate 内建进程级共享 `LegadoClient`（OnceLock，照抄 `RATE_LIMITER` 模式，web_book.rs:133-137），`server_deps` 改取共享实例 ⇒ 连接池复用 + 请求间 cookie 存活；
2. 把 Set-Cookie 持久化做成 legado-net 层可注入后端（对齐 legado-js `set_cookie_sink` 的 first-wins 方向），ffi `db_open` 时注册 `DbCookiePersistence` 同款实现 ⇒ server 抓取的响应 cookie 也落库。前期调研的「~40 行 JsCookieDbSink sink + 启动注册」**已完成**（见 §3.5），无需重做。

### 5.3 契约影响

三条修法均不改任何 FFI 导出签名（`ffi_server_start(port)` / `set_mcp_port` 原样），`api_contract_test.dart` 程序化计数不受影响；改动全部在 rust 内部函数签名与注入方向。

---

## 六、未找到 / 未实测事项

- Android 应用进程 cwd 的实际取值未实测（本次不操作设备）；「打开失败或生成第二个空库」为代码注释（db_state.rs:25）+ 路径语义推演，建议后续真机开启 Web 服务开关用 `adb shell run-as` 验证一次。
- V2 时代设置页开关是否实际可达（是否存在 FeatureFlag 遮蔽）：在 `249138904c` 上未见遮蔽逻辑，判定可达；如需 100% 确证可回溯 `522e1c1bed` 的完整 diff。
- server 侧 `mcp.rs` 1438 行之前的写点除 :579/:696/:847 外未逐一展开（grep 全量扫描仅此三处生产写）。

---

## 附：关键证据文件索引

| 主题 | 位置 |
|---|---|
| server 自开第二池 | rust/legado-server/src/server.rs:42-49 |
| 硬编码相对路径 | rust/legado-ffi/src/api/server_api.rs:111-115 |
| MCP 路径已修（对照组） | rust/legado-ffi/src/api/server_api.rs:227-234, 253-255 |
| 启动失败静默 | rust/legado-ffi/src/api/server_api.rs:110-132 |
| WAL/busy_timeout | rust/legado-db/src/connection.rs:34-41, 205-215 |
| DB 路径记录动机注释 | rust/legado-ffi/src/db_state.rs:22-26 |
| ffi 全局池 | rust/legado-ffi/src/db_state.rs:19-20, 99-108 |
| Dart db 路径 | flutter_legado/lib/src/services/rust_api.dart:390-396 |
| Web 服务 UI 开关 | flutter_legado/lib/src/screens/settings_screen.dart:85-89 |
| V2 报告原文 | docs/REFACTOR_DEFECT_AUDIT_V2_20260902.md:40, 97 |
| 09-03 重开缺口与设计 | docs/REFACTOR_CONSOLIDATED_AUDIT_20260903.md:27, 180 |
| P5 注入面 | rust/legado-server/src/handlers/web_book.rs:150-244 |
| cookie sink 注册 | rust/legado-ffi/src/ffi.rs:182-185; rust/legado-ffi/src/http_state.rs:230-301; rust/legado-js/src/host_api/cookie_store.rs:57-66 |
| server 每请求新建客户端 | rust/legado-server/src/handlers/web_book.rs:200-202, 265-268 |
| 原版同进程基线 | app/src/main/java/io/legado/app/service/WebService.kt:42, 204; app/src/main/java/io/legado/app/api/controller/BookSourceController.kt:30,45,65,202 |
