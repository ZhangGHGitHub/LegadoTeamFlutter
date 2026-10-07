# Web 页对齐 B1+B2 批代码审查报告

- 审查对象：提交 `4fd08369e844c33d833013339606a39f6b9268e6`（feat(rust): Web 服务移植原版前端资产与只读端点，79 文件 +11385/-221）
- 审查基线：`app/src/main/java/io/legado/app/**`（Kotlin 原版，只读）、`docs/WEB_UI_PARITY_SURVEY_20261007.md`
- 审查日期：2026-10-07
- 审查方式：只读静态逐字段对照 + git blob 字节级对比 + 真实运行（`cargo test`/`clippy`/`fmt`，未修改任何被审文件）
- 证据等级说明：【实证】= 命令/测试/grep 可复现；【对照】= 与 Kotlin 源逐字比对得出；【推断】= 由代码结构推导、未直接运行验证

## Summary: needs changes（无阻塞级缺陷；1 项 P1 安全加固 + 3 项 P1 一致性偏离应在 B3 前修正）

门禁实测：`cargo test -p legado-server --test legacy_web_test` 21/21 通过；`--lib web_assets` 5/5、`legacy` 11/11 通过；`cargo clippy -p legado-server --all-targets -- -D warnings` 通过；`cargo fmt -p legado-server --check` 通过。

---

## Errors (blocking)

无阻塞级（P0）缺陷。重点排查项逐一给出核验结论：

### E-1 build.rs 正确性与卫生 —— 通过【实证】

- **完整性**：`rust/legado-server/web-dist/` 67 文件与 `app/src/main/assets/web/`（删除前提交 `4257d75439^`）文件清单 `diff` 完全一致；67 个文件逐一 `git rev-parse` blob 哈希对比**零差异**；`git ls-tree -r -l` 总字节两侧均 **2,057,579 B**（与提交信息自称一致）。build.rs `walk()`（`rust/legado-server/build.rs:56-72`）递归收集 + `assets.sort()` 去重天然成立（路径集合唯一）。
- **路径分隔符**：`build.rs:67` `to_string_lossy().replace('\\', "/")` 显式把 Windows 反斜杠归一为 `/` 作为表键；`include_bytes!` 的 `concat!(env!("CARGO_MANIFEST_DIR"), "/web-dist/{}")` 用 `/` 拼接，Windows API 亦接受。无跨平台问题。
- **rerun-if-changed**：`build.rs:26-27` 声明 `web-dist` 目录与 `build.rs` 自身，`build.rs:36` 再对每文件显式声明（双保险）。正确。
- **生成物位置**：`build.rs:51-52` 写入 `$OUT_DIR/web_assets_table.rs`，由 `web_assets.rs:39` `include!` 引入，未污染 `src/`。
- **非 UTF-8 资产**：图片/woff/ttf/ico 以 `include_bytes!` 嵌入（二进制安全）；`to_string_lossy` 仅作用于路径且资产行均无非 UTF-8 字符（清单核对通过）。MIME 表对 `.vue`（Vue 单文件产物无此扩展存在于表）与未知扩展回 `application/octet-stream`。

### E-2 静态服务行为 vs 原版 —— 通过（两处登记偏离属实且不影响 Vue 运行）【对照】

- **CSP 逐字对照**：`web_assets.rs:42-46` 与 `HttpServer.kt:233-238` `VUE_CONTENT_SECURITY_POLICY` 逐 token 一致（default-src/script-src/style-src/img-src/font-src/connect-src/frame-src/object-src/base-uri 全部相同）。`no-cache` 仅对 `/vue/` 前缀且 `.html` 结尾加（`web_assets.rs:98-104`），与 `HttpServer.kt:274-277` 一致。
- **nosniff / Origin 回显 / OPTIONS**：`with_web_headers`（`web_assets.rs:87-105`）对齐 `addWebHeaders`（HttpServer.kt:265-278）；OPTIONS 预检 200 + `GET, POST` + `content-type, x-legado-token`（`web_assets.rs:153-169`）对齐 `HttpServer.kt:45-56`。测试 `test_options_preflight` 断言三头齐全。
- **目录补 index**：`/`→`index.html`、`/vue/`→`vue/index.html`（`web_assets.rs:57-61`）对齐 `HttpServer.kt:161-163`。无目录列表、无 SPA 回退——与原版一致（原版 `assets.open` 未命中即抛异常，同样无回退）。
- **登记偏离 1（404 vs 500）**：属实。原版 `assets.open` 抛 `FileNotFoundException` 被 `HttpServer.serve` 最外层 catch（HttpServer.kt:264-278）兜成 500 text/plain；本实现 404（`web_assets.rs:139`）。偏离**已如实登记**（`web_assets.rs:19-21` 模块注释 + 提交信息），且 Vue 前端为 hash 路由、所有资源路径均在嵌入表内，未知路径 404 不影响其运行（集成测试验证入口页/静态 chunk/`/vue/` 全通）。
- **登记偏离 2（MIME 修正）**：属实。原版 `AssetsWeb.kt:33-44` MIME 表仅 5 条、png/woff/ttf 等误标 `text/html`；本表按标准类型修正（`build.rs:89-105`），登记为「产品语义等价，非缺陷复刻」。`.js` 保持原版 `text/javascript`。浏览器加载 Vue 产物对修正后的正确 MIME 无碍（`<script type=module>` 反而要求 JS MIME 正确，修正方向正确）。
- 小差异（不影响语义）：原版静态响应为 chunked（`NanoHTTPD.newChunkedResponse`），本实现整包 `Body::from(bytes)`；HTTP 层语义等价。

### E-3 JSON 投影逐字段抽样 —— 键名通过；null 语义与 useReplaceRule 门控两处偏离（见 W-1/W-2）【对照】

抽样 14 键与 Kotlin 源逐字对照（`rust/legado-server/src/legacy/book_json.rs` ↔ `Book.kt`/`BookChapter.kt`）：

| Rust 字段（行号） | Kotlin 声明 | 结论 |
|---|---|---|
| `bookUrl`(39) / `tocUrl`(41) / `origin`(43) / `originName`(44) | Book.kt:55-69 | 一致 |
| `customTag`(49) / `customCoverUrl`(53) / `customIntro`(56) | Book.kt:70-78 | 一致 |
| `type`(59) ← `book_type: i32` | Book.kt:84-86 `type: Int` | 一致（serde rename 到 `type`） |
| `group`(61) `i64` | Book.kt:89 `group: Long` | 一致 |
| `durChapterPos`(80) / `durChapterTime`(82) | Book.kt:110-115 | 一致 |
| `canUpdate`(86) `bool` | Book.kt:119 `canUpdate: Boolean` | 一致 |
| `originOrder`(89) | Book.kt:121 | 一致 |
| `syncTime`(94) | Book.kt:135-136 | 一致 |
| `persistedCoverUrl`(97) 恒 null | Book.kt:138-139 | 键在、值 null（登记差异1，见 W-1） |
| `infoHtml`(100)/`tocHtml`(103)/`downloadUrls`(104)/`folderName`(107) 恒 null | Book.kt:158-175 `@Ignore` + 私有 | 键集含它们与 GSON 反射序列化行为一致 |
| `titleMD5`(258) 恒 null | BookChapter.kt:100-101 `@Ignore var titleMD5` | 一致（GSON 序列化私有 @Ignore 字段） |
| ReadConfig `tocExpanded`(162) 恒 true | Book.kt:496 `tocExpanded: Boolean = true` | 默认值对齐（登记差异2） |
| ReadConfig `manualReplaceRuleIds`(197) 恒 [] | Book.kt:512 | 默认值对齐（登记差异2） |
| Rust 独有 `originBookUrl`/`coverOrigin` | 不存在于 Kotlin Book | **未外泄**（`LegacyBook` 不含此二字段，测试 `test_get_bookshelf_full_kotlin_field_shape` 显式断言其不存在）【实证】 |

Book 38 键 / BookChapter 18 键 / ReadConfig 19 键的键集断言测试（`book_json.rs:292-417` + 集成测试硬编码 `KOTLIN_BOOK_KEYS`/`KOTLIN_CHAPTER_KEYS`）与我在 Kotlin 源逐键清点的结果**完全一致**（Book 构造参数 33 + 类体 @Ignore 4 = 37 持久/非持久键 + `readConfig`；BookChapter 17 构造 + `titleMD5`）。

### E-4 ReturnData 信封 —— 通过【对照】

`legacy/mod.rs:47-53` `{isSuccess, errorMsg, data}` 与 `ReturnData.kt` 三字段一致；`success()` → `isSuccess=true, errorMsg=""`、`error()` → `isSuccess=false, data=null` 对齐 `setErrorMsg`/`setData`（ReturnData.kt:16-30）。errorMsg 默认值差异（原版初始为「未知错误,请联系开发者!」，仅在「未 setErrorMsg 也未 setData 就返回」的不可达分支出现；Rust 侧不存在该分支）不构成行为偏离。HTTP 恒 200 对齐原版：原版 NanoHTTPD 仅在未捕获异常时 500（HttpServer.kt:264-277），错误路径同样回 200+信封。

### E-5 七端点语义抽查 —— 主链通过；三处偏离见 W-1/W-2/W-3【对照】

- **getChapterList 空目录回退**（book_api.rs:132-136）：空 → `refresh_toc`；书籍缺失/书源缺失文案逐字对齐（「未在数据库找到对应书籍，请先添加」「未找到对应书源,请换源」）；抓取成功后删旧插新+更新派生字段（persist_chapters，事务内）对齐 `refreshToc` 的 `delByBook/insert/book.update()`。preUpdateJs/变量桥缺失已登记。空抓取结果不落库直接返回空（对齐原版 `getChapterListAwait` 空列表不抛错 → setData(空)）。
- **getBookContent 净化链**：缓存→本地→网络三路均经 `purify_content`（remove_duplicate_title=true + apply_replace_rules=true，includeTitle=false 对应「不重排/不缩进/不去空行」的登记决策）；规则排序 `ORDER BY sortOrder ASC` 对齐 `ReplaceRuleDao:50`。偏离：Rust 侧**未按 `book.getUseReplaceRule()` 门控**（W-2）、去重复标题实现弱于原版（W-3）。
- **saveBookProgress**：POST、按 name+author 定位、更新 4 进度列（`update_progress`，book_repository.rs:309-331），WebDav 上传缺失已登记。text/plain 容忍实现正确（按原始字节 `serde_json::from_slice`，不查 Content-Type）。**name+author 歧义与原版一致**：原版同样 `appDb.bookDao.getBook(name, author)`（BookController.kt:291；BookDao.kt:125-126），且两侧 books 表均有 `(name,author)` 唯一索引（Kotlin Book.kt `Index(unique=true)`；Rust schema.rs:646），**串进度风险与原版等价，非本批引入的回归**。
- **/cover /image 路径校验**：见 S-1（`/cover` 本地路径任意读——安全项，非功能缺陷）。
- **getReadConfig/saveReadConfig**：键 `webReadConfig` 与原版一致（BookController.kt:335-351）；`put(key, value, 0)` = 无 TTL 对齐 CacheManager.put 默认；空体删键对应原版 `postData == null` 分支。**偏离**：原版只认 `files["postData"]`（multipart 表单字段，HttpServer.kt:135-136），原样字符串存取；Vue 端 `axios.post('saveReadConfig', e)` 发送 JSON 对象体——原版 Kotlin 实际也把整个 body 存入 `postData` 字段再存缓存，Rust 侧按原始字节存取，两端兼容（Vue 端 `JSON.parse(t.data)` 取回对象，roundtrip 测试通过）【实证】。

### E-6 安全 —— 1 项需加固（S-1）；静态服务无穿越【对照+实证】

- **静态服务穿越**：免疫。嵌入表键即固定清单，`normalized_asset_key`（web_assets.rs:53-67）把 `..` 段原样保留但**无法匹配任何表键**（表键无 `..`），`test_path_normalization` 断言 `/../etc/passwd` → `lookup` 为 None；磁盘兜底 `ServeDir` 自带穿越防护。
- **CSP 破坏性**：无。CSP 与原版逐字一致，Vue 产物（module script、self 资源、ws 连接）在其允许集内；集成测试实际加载入口页与 chunk 验证通过。
- **S-1 `/cover?path=` 任意文件读取**：见 Warnings 首条。

### E-7 并发 —— 通过【对照】

`AppState.db` 为 `tokio::sync::Mutex<Database>`（state.rs:13）；B2 全部 handler 与既有 `/api/*` 共用 `state.db.lock().await` 同一把锁、同一连接池（book_api.rs 各端点均经 `state.db` 取 `db.connection()`），未新建池（提交声称属实）。锁内操作均为同步 SQLite 调用（快进快出）；`refresh_toc`/`get_book_content` 的网络抓取在锁外 await，无跨 await 持锁（逐点核对：`db.lock().await` 作用域均以块 `{}` 收窄后释放再进入 `.await` 抓取）。风险面与既有端点等价，无新增死锁/长持锁路径。

---

## Warnings（P1 —— 应当修）

### W-1 GSON null 语义声称与事实相反；null 字段实际被省略（P1，契约一致性）

- 位置：`rust/legado-server/src/legacy/book_json.rs:1-30`（头注释）、`legacy/mod.rs:86`
- 症状：头注释称项目 GSON「默认**不省略 null**，字段恒在」，但实证 `GsonExtensions.kt:26-42`：`INITIAL_GSON`/`GSON` 的 `GsonBuilder()` **未调用 `serializeNulls()`**，GSON 默认行为是**跳过 null 字段**。期望 X（注释声称/测试断言的 38 键恒在）vs 实际 Y（原版真机上 `getBookshelf` 对 null 字段——如未设置的 `kind`/`customTag`/`readConfig` 等——输出中**没有该键**）。本批投影恒输出 null 键，键集是原版「全字段非空时」的超集。
- 影响面评估：Vue 端消费侧（`index-toG2697L.js` 的 `loadBookShelf`/`loadWebCatalog`）只做 `data` 数组取值与 `durChapterTime` 排序，对 null 键 vs 缺键均按 undefined 处理（`e.durChapterTime||0` 模式），**当前前端实测不受影响**。但这是「键集逐字对齐 Kotlin」声明与真实 GSON 行为的系统性偏差，且第三方脚本消费者（原版 API 的既有用法）可能依赖缺键语义。
- 修复建议（二选一）：a) 投影结构体加 `#[serde(skip_serializing_if = "Option::is_none")]`（Option 字段），把 null 键省略，与 GSON 默认一致，同时把头注释与测试改为「null 字段省略」口径；b) 若坚持恒输出 null（前端更稳），把头注释改为「有意偏离：GSON 默认省略 null，本实现恒输出以稳定前端」，并在登记差异清单补第 4 条。**不允许维持现状**（注释与事实矛盾会误导后续批次）。
- Proof：`grep -n serializeNulls app/src/main/java/io/legado/app/utils/GsonExtensions.kt`（无输出）；对照 `Book::default()` 序列化输出 vs GSON 行为。

### W-2 getBookContent 净化未按 `useReplaceRule` 门控（P1，行为偏离，非登记项）

- 位置：`rust/legado-server/src/legacy/book_api.rs:455-463`（`apply_replace_rules: true` 无条件）
- 症状：原版 `ContentProcessor.getContent`（ContentProcessor.kt:79-81）`replaceEnabled = useReplace && book.getUseReplaceRule()`；`getUseReplaceRule`（Book.kt:237-247）在 `readConfig.useReplaceRule == null` 时按书籍类型回退：**图片类/epub 本地书默认关闭净化**，否则取 `AppConfig.replaceEnableDefault`。期望 X：epub/图片书默认不应用替换规则；实际 Y：Rust 侧无条件应用全部启用规则。用户可见差异：epub/图片书的正文中含 `正文` 前缀替换等全局规则时被错误应用。此偏离**未在登记差异清单中**（提交只登记了 30s 等待与 stackTraceStr 两项）。
- 修复建议：`purify_content` 增加 `replace_enabled` 判定：读 `book.read_config.use_replace_rule`，None 时按 `book_type`（IMAGE_BIT/epub 本地）回退 false、其余回退 true；并补入登记差异或直接对齐。
- Proof：`sed -n 237,247p app/src/main/java/io/legado/app/data/entities/Book.kt` vs `book_api.rs:455-463`。

### W-3 去重复标题实现远弱于原版（P1，净化效果差异，建议补登记或对齐）

- 位置：`rust/legado-core/src/content_processor.rs:236-249`（`remove_duplicate_title` 仅 `strip_prefix(chapter_name)`）
- 症状：原版 `sameTitleLineMatcher`（ContentProcessor.kt:21-26 + 92-114）匹配「行首空白/标点/书名前缀 + 标题（空白弹性匹配）+ 行尾」的正则，且带 `removeSameTitleCache` 与「替换后标题二次匹配」分支。Rust 侧仅处理「正文以章节标题**原样开头**」一种形态；对「第X章 标题」vs「标题」空白差异、书名前缀、标点包裹均不命中。净化强度低于原版（重复标题残留在 Web 阅读页首行）。`book_name` 参数传入了 ScopeContext 但去重链路未用书名。
- 修复建议：最低限度在 `book_api.rs` 模块注释/提交登记差异中补一条「去重复标题为简化实现（仅原样前缀剥离）」；后续批次对齐 `sameTitleLineMatcher` 正则语义。
- Proof：对照 `ContentProcessor.kt:21-26,92-114` vs `content_processor.rs:236-249`。

### S-1 `/cover?path=` 允许读取本机任意路径文件（P1，安全加固；原版同面但有 App 沙箱兜底）

- 位置：`rust/legado-server/src/legacy/book_api.rs:688-714`（`fetch_image_bytes` 非 http(s) 前缀一律 `tokio::fs::read(path)`，无目录白名单）
- 症状：`GET /cover?path=/etc/passwd`（或 Windows `C:\...\任意文件`）会把本机文件以 200+字节回给客户端。审查项要求「必须限定在应用可读的封面缓存目录」。**注意与原版的对照**：原版 `ImageLoader.loadBitmap(appCtx, coverPath)` 走 Glide，可加载本地文件 URI——面等价；但原版运行在 Android 沙箱内（应用私有目录+MediaStore 可读范围），Rust 侧（桌面/独立二进制）以进程权限读文件，暴露面显著更大。实测 FFI Web 服务绑定 `0.0.0.0`（`rust/legado-ffi/src/api/server_api.rs:169,333`），即**局域网内任意主机可拖库**。`/image` 端点因强制 `bookUrl` 存在于库且相对路径经 `base.join` 归一，直链场景与 `/cover` 同风险（`resolve_image_url` 对绝对 http(s) 直用，本地路径在 `/image` 下被 `find_by_url` 前置挡住 bookUrl，但 path 直接给本地绝对路径时 `fetch_image_bytes` 同样读本地文件——`/image?path=C:\x&url=book1` 成立）。
- 修复建议（按优先级）：a) 非 http(s) 的 `path` 限定为书库内已登记书籍的 `cover_url`/本地书目录（先查库再读文件，或路径前缀白名单：应用数据目录 + 书籍文件所在目录）；b) 至少把本地文件分支限定扩展名白名单（复用 `guess_image_mime` 魔数校验失败即 404）；c) 若首版接受风险，必须在提交登记差异中显式写明「本地 path 直读为已知风险，桌面绑定 127.0.0.1 缓解」——但 FFI 绑 0.0.0.0 时该缓解不成立。
- Proof：`curl "http://<host>:<port>/cover?path=/etc/passwd"`（实现读文件并按魔数/扩展名回包；非图片扩展名回 `application/octet-stream` 字节）。

---

## Suggestions（P2 —— 可改进）

### SUG-1 `is_local_book` 的 WebDav 前缀常量与原版不一致（P2，潜在风险，标注不确定）

- 位置：`rust/legado-core/src/models/book.rs:30` `WEB_DAV_TAG = "dav:"`；原版 `BookType.kt:76` `webDavTag = "webDav::"`。
- 症状：`book_api.rs:47-53` `is_local_book` 用 `origin.starts_with(WEB_DAV_TAG)` 复刻 `BookExtensions.kt:50-56`，但常量值不同。期望 X：`origin` 以 `webDav::` 开头判本地；实际 Y：以 `dav:` 开头即判本地。影响：导入原版 WebDav 备份（origin=`webDav::...`）的书不会被识别为本地书，`getChapterList`/`getBookContent` 走网络书源分支报「未找到书源」；反向地，任何以 `dav:` 开头的 http(s) URL 不受影响（http 开头）。该常量为架构首提交（`12115036ab`）遗留，非本批引入；本批是首个消费它的 Web 端点，故在此登记。【推断】（未实测 WebDav 导入链）
- 修复建议：改常量为 `"webDav::"`（全仓 grep `"dav:"` 仅 book.rs:30 一处定义，改动面 1 行），或补迁移层把存量 `dav:` 前缀归一。

### SUG-2 `getBookshelf` 排序固定默认分支（P2，已登记，确认登记属实）

- 原版 `BookController.kt:65-83` 默认分支（`AppConfig.bookshelfSort` 默认 0，AppConfig.kt:792-793）即 `durChapterTime` 降序；Rust 固定该分支（book_api.rs:88）且**已在注释与提交信息登记**排序 1/2/3 不生效。Vue 端拿到数据后还自行按 `durChapterTime` 重排（`index-toG2697L.js` `sort((e,t)=>...)`），用户可见行为一致。空书架文案「还没有添加小说」逐字一致。无需修。

### SUG-3 `find_all` 无排序依赖 + 内存重排的稳定性（P2，可选）

- `book_api.rs:88` 依赖 `BookRepository::find_all`（book_repository.rs:508-530，`ORDER BY "order" ASC`）后在内存按 `durChapterTime` 逆序重排。`sort_by_key(Reverse)` 在 rusqlite 顺序稳定的前提下结果确定；但 Rust `sort_by_key` 为稳定排序，`dur_chapter_time` 相同时按 `order` 升序稳定——原版 Kotlin `sortedByDescending` 同为稳定排序且输入同为 `SELECT * FROM books`（BookDao.all 无 ORDER BY，实际顺序不定）。行为等价或更优，无需修；仅提示 `find_all` 注释「对齐 appDb.bookDao.all」与实际 SQL（多了 ORDER BY order ASC）存在细微偏差，无用户可见影响。

### SUG-4 tower 迁移与 Cargo.lock（P2，核实通过）

- `Cargo.toml` 将 `tower` 从 dev-dependencies 移入 dependencies（features=["util"]），仅因 `web_assets.rs:35` 在非测试代码 `ServiceExt::oneshot` 调 ServeDir；tower 本就是 axum 传递依赖，无新增外部 crate，声称属实。提交未触碰 `Cargo.lock`（`git show --stat` 无该文件），核实无误【实证】。

### SUG-5 自制页 git mv 登记（P2，核实通过）

- `docs/pending_deletion/README.md` 与 `web_dist_custom_index/README.md` 均写全来源（`rust/legado-server/web-dist/index.html` 9,536B 自制页）、理由（与原版 67 文件资产的同名 `index.html` 冲突）、用户裁决（2026-10-06）与后续处置，符合项目约定。原自制页 179 行完整保留于 pending_deletion 目录【实证】。

### SUG-6 提交卫生（P2，核实通过）

- 79 文件全部属于 B1/B2 范围（67 资产 + 5 个 pending_deletion 迁移 + 7 个 Rust 源/测试/构建），无无关混入【对照 stat 清单】。
- autocrlf 声称核实：`core.autocrlf=true`，但全 67 个 blob 的**仓库内字节**与原版删除前提交逐 blob 哈希一致（含 CRLF 文本文件 `vue/index.html` 的 `\r\n` 在两侧 blob 中同样存在——原版仓库内本就存 CRLF），工作区 checkout 后 CRLF 保持（`grep -c '\r'` 非零但与原版磁盘行为相同）。`include_bytes!` 编译期读工作区文件——若未来某次重新 checkout/归一化把工作区文件转成 LF，会导致嵌入字节与原版差异（构建产物哈希变化）。**建议**（可选）：为 `rust/legado-server/web-dist/**` 加 `.gitattributes` 标 `binary` 或 `-text`，锁死字节。当前提交内容本身无缺陷。

### SUG-7 ReturnData 序列化键序（P2，已正确登记，无需修）

- serde_json 默认 BTreeMap 键序（字典序）输出 `{data,errorMsg,isSuccess}`，与 Gson 声明序 `{isSuccess,errorMsg,data}` 不同；`legacy/mod.rs:139-141` 注释已登记「键序无语义」。JS 消费端只按键取值，无影响。

### SUG-8 大列表整包序列化（P2，已登记，接受）

- 原版对 >3000 元素列表走 chunked 流式（HttpServer.kt:183-194），本实现整包；`legacy/mod.rs:25-27` 已登记。超长书目（万章）时整包内存峰值更高，可后续接 axum Body 流。接受现状。

---

## 多视角交叉与验证声明

- 视角覆盖：正确性（构建/路由/序列化）、契约（Kotlin 基线逐字段）、安全（路径/网络暴露）、并发（锁作用域）。**missing lens**：无移动端真机行为验证（本仓 Rust 侧无法跑 Android Glide 路径），/cover 裁切差异仅能以登记为准。
- 行为验证证据等级：静态逐字对照 =【对照】；`cargo test -p legado-server --test legacy_web_test` 21 通过（含键集硬编码断言、beacon text/plain、roundtrip、路径归一负例）=【实证】；未做浏览器端端到端（Vue 前端渲染）人工验证 = limitation。non-claims：本报告不声称「Vue 前端在真实浏览器下与原版 App 完全一致」，仅声称端点/资产/头部形状按对照与测试一致；W-1 的「前端不受 null 键影响」结论基于对打包 JS 的读取分析，未做浏览器实测。

## 处置决定

- `promote_to_artifact`：本报告落盘 `docs/WEB_LEGACY_ENDPOINTS_CODE_REVIEW_20261007.md`。
- 建议转入检查项（`convert_to_check`）：W-1（GSON null 口径二选一定案）、S-1（本地 path 白名单）、SUG-6（web-dist .gitattributes 锁字节）。
- `leave_native`：SUG-2/3/4/5/7/8（登记属实，不引入改动）。

## 总体结论

**需修改（needs changes）**——无阻塞缺陷，B1 资产与静态服务、B2 端点主链、信封与键集投影质量高（逐字段对照零键名错误，测试先红后绿属实）；合并前应处理 W-1（注释与事实矛盾，必改其一）、S-1（0.0.0.0 暴露面下的本地任意读，建议 B3 前加白名单）、W-2（未登记的行为偏离）；W-3/SUG-1 可随 B3 一并处理或登记。
