# 重构版发现页问题排查报告（2026-08-14）

> **排查性质**：只读源码对比排查。未修改任何代码、未提交任何变更。
> **排查对象**：重构版发现页（`flutter_legado` explore 系列 + `rust/legado-ffi/src/api/explore_api.rs` + 登录链路）vs 原版 Android。
> **用户报告**：① 同样的书源内容与原版不一致；② 功能不一致；③ 无法登录。
> **方法**：主代理逐文件源码对比 + 三路子代理（原版基准 ✅ / 登录链路 ✅ / 重构内容审计 🔄）。

---

## 一、结论速览

| # | 根因 | 症状关联 | 严重度 | 状态 |
|---|---|---|---|---|
| R1 | **登录状态持久化/消费链路断裂**（V2 login 命令丢弃 + Rust 不同步 + 请求头不合并 + 双 Cookie 存储分离 + 手动登录无读取方） | **无法登录（决定性）** | **P0** | 已确认 |
| R2 | **发现页书源行菜单缺失登录入口**（原版 hasLoginUrl 条件菜单项） | 无法登录、功能不一致 | P1 | 已确认 |
| R3 | **explore 书籍抓取链路未接线 loginCheckJs**（搜索/详情/章节已接，explore 未接） | **内容不一致（主因一）** | P1 | 已确认 |
| R4 | explore 错误处理无登录引导 | 无法登录 | P2 | 已确认 |
| R5 | **发现列表缺在架标记 + 批量加入书架菜单 + kind 标签** | 功能不一致 | P2 | 已确认 |
| R6 | **explore 解析内核 6 项 P1 差异**（50 截断/字段清洗/简介净化/bookUrl 兜底/重定向 baseUrl/-+ 前缀）+ 4 项 P2 | **内容不一致（主因二）** | P1 | 已确认 |

---

## 二、根因明细

### R1（P0，决定性）登录状态持久化/消费链路断裂 —— 「永远无法登录」的根源

**症状**：V2 对话框能弹出、能执行 loginActionV2、显示"登录成功"，但登录后请求仍不带凭据 → loginCheckJs 持续报未登录。

**链路断裂点（4 处）**：

| # | 断裂点 | 原版正确行为 | 重构版现状 | 证据 |
|---|---|---|---|---|
| 1 | **V2 login 命令丢弃** | `SourceLoginV2Delegate.kt:268-274`：收到 login 命令 → `source.putLoginInfo(loginJson)` 落库 | Flutter `_LoginV2Dialog._doAction`：收到 login 命令**直接 `Navigator.pop(context, true)`，login JSON 被丢弃** | `book_info_screen.dart:1887-1890` |
| 2 | **Rust 登录动作不同步登录缓存** | 原版 eval 后 variable_store 持久化 | `eval_login_action_v2`（`source_login_v2_api.rs:91-118`）只返回命令 JSON，**无** explore 路径那样的 `sync_login_cache_from_js` 把 userInfo/loginHeader 写回 `source_login_cache` | `explore_api.rs:314-324`（对比） |
| 3 | **请求路径不合并登录头/Cookie** | 原版 `getHeaderMap(hasLoginHeader=true)`（`BaseSource.kt:205-209`）自动附加 loginHeader | `parse_source_headers`（`web_book.rs:105-110`）**只读静态 `source.header`**，不合并 `source_login_cache::get_login_header` | `web_book.rs:105-110` |
| 4 | **双 Cookie 存储分离** | 原版单一 CookieStore | JS `java.setCookie` 写 legado-js 独立 `GLOBAL_COOKIES`（`cookie_store.rs:9-43`），与 legado-net `LegadoClient.CookieStore`（`client.rs:86,234-235`）**两套存储**，仅 `clear_cookie` 双向接触 | `net_api.rs:75-104` |

**附加**：手动登录入口（`source_login_prompt.dart:54-62`、`source_screen.dart:955-961`、`reader_top_bar.dart:761-768`）全部打开 `SourceLoginScreen` 手动页，保存到 `source_login_<url>` config 键（`source_login_notifier.dart:22,110`），**全仓无任何 Rust 读取方** → 手动登录同样无效。

**一句话**：loginActionV2 执行链路完整（参数/脚本/命令解析均对齐原版），但「登录结果 → userInfo/loginHeader → 请求头/Cookie」这条链在重构版是断的。

### R2（P1）发现页书源行菜单缺失登录入口

- **原版** `ExploreAdapter.kt:688-713` `showMenu`：edit / top / **login（`hasLoginUrl` 时可选）** / search / refresh / delete
  - `hasLoginUrl` = SQL 计算列（`BookSourcePart.kt:13-17`）：`loginUrl` 非空 **或**（`mainJs`+`loginUi` 非空且非 `[]`）
  - 动作：`startActivity<SourceLoginActivity>`（type=bookSource）
- **重构版** `explore_screen.dart:467-491`：菜单仅 edit / uninstall；`_SourceItem` 回调仅 onEdit/onUninstall/onCategoryTap
- **原版仅 2 个手动登录入口且都在书源列表页**（ExploreAdapter 菜单 + SourceLoginActivity 内部分流 hasLoginForm→表单/WebView）；**ExploreShowActivity（分类列表页）原版也无登录入口** → 重构版 explore_show 无登录不算差异，缺失的是 **explore_screen 书源行菜单 login 项**

### R3（P1）explore 链路未接线 loginCheckJs —— 「内容不一致」主因

- **loginCheckJs 语义**（原版 `WebBook.kt:149-172`，子代理 A 确认）：**响应改写钩子**而非布尔——成功路径 `evalJS(checkJs, response)` 可整体改写响应；失败路径构造 code=500 伪响应**二次 eval**，返回 500 则重抛原始异常 → UI 报错。
- **重构版** `execute_login_check`（`web_book.rs:195-248`）已接线：搜索(419)/章节(579,612)/详情(770,806)；**explore_api.rs 零调用**（grep 证实）。
- **影响**：书源未登录时 explore 请求返回登录页/验证页 HTML → 重构版当正常内容解析 → **列表内容与原版不一致**；原版会报错引导（错误可点重试）。

### R4（P2）explore 错误处理无登录引导

- 重构版 `explore_show_notifier.dart:69-75`：错误仅文本；原版 `ExploreShowActivity.kt:90-95` 错误进 LoadMoreView.error 可点击重试。原版不自动弹登录（登录全靠用户手动发起），重构版至少应提供错误可见 + 可重试 + 登录入口可达。

### R5（P2）发现列表功能缺失（第一手核实）

| 缺失项 | 原版 | 重构版 |
|---|---|---|
| 列表项**在架标记** | `ExploreShowAdapter.kt:45,71-72` `ivInBookshelf`（三元匹配 + payload 增量刷新） | `explore_book_list.dart` 无（grep 零命中） |
| **批量加入书架**菜单 | `ExploreShowActivity.kt:37-45` `menuAddLoadedBooks`（alert 确认 / 进行中禁用 / toast 结果） | `explore_show_screen.dart:56` 顶栏仅 ExplorePageControl，无批量入架 |
| 页码跳转 | `menuPage` NumberPickerDialog(1..999) | ExplorePageControl（有页码控件，跳页能力待确认） |

---

## 三、内容解析内核核对（原版基准，子代理 A/B ✅）

### 3.1 解析内核差异（子代理 B：**未对齐**，10 项）

**A. 字段映射（explore_api.rs `explore_books_async:438-640`）—— 6 P1 + 3 P2，直接导致「内容不一致」**

| # | 差异 | 原版 | 重构版 | 严重度 |
|---|---|---|---|---|
| A1 | **每页 50 条硬截断** | 无上限 | `elements.iter().take(50)`（:563-564）→ 超 50 本缺书 | P1 |
| A2 | **书名/作者未清洗** | `formatBookName/formatBookAuthor` 去「 作者xx」「xx 著」（BookList.kt:220,225） | 原样返回（:567-572） | P1 |
| A3 | **简介未净化** | `HtmlFormatter.formatIntro` 去标签（BookList.kt:260） | 原样返回（:587-594），Flutter 直显 | P1 |
| A4 | **bookUrl 空不回退** | `getString(isUrl=true)` 空→baseUrl（AnalyzeRule.kt:369-375） | 留空（:573-578）；Rust 搜索路径有兜底（search.rs:930-938） | P1 |
| A5 | **重定向 baseUrl 用错** | 用 `res.url` 最终 URL（WebBook.kt:173-181） | 用请求前 `final_url`（:508），legado-net 已回传最终 URL 未用 | P1 |
| A6 | **bookList 规则 `-`/`+` 前缀不支持** | `-` 反转、`+` 剥离（BookList.kt:90-96,145-147） | `get_elements` 无此逻辑（analyze_rule.rs:623+） | P1 |
| A7 | wordCount 恒 None | 有（wordCountFormat） | 恒 None（:629）；搜索路径有（search.rs:926-927） | P2 |
| A8 | bookType 未设置 | 按书源类型 | Dart 默认 0（rust_api.dart:1759-1773）→ 漫画/听书/视频类型丢失 | P2 |
| A9 | 详情页回退差异 | collections 空 → `getInfoItem` 用 ruleInfo 规则整页解析（BookList.kt:100-108） | 空 bookList 规则 → 整页当单元素用 bookList 规则（:513-517） | P2 |

**B. ExploreKind 渲染**：结构/类型集合/action/viewName/style/`java.refreshExplore` 均对齐；差异①（P2）toggle/select/text **不读 infoMap 已存值回显**（explore_kind_layout.dart:419-426,528-535,717-734；原版读 `infoMap[title]`）→ UI 显示值与 Rust 请求实际值脱节；差异②（P2）JSON 解析失败原版出 ERROR 行（BookSourceExtensions.kt:97-100），Rust 返回空数组（explore.rs:149-150）。

**C. 分页**：nextPage/跳页/prepend/页码控件主语义对齐；差异①（P2）错误后 `hasMore:false`（explore_show_notifier.dart:73）→「点击重试」被 `!hasMore` 短路成**死按钮**（原版 fail() 不清 hasMore 可滚动重试）；差异②（P2）`hasMore = newBooks.isNotEmpty`（:65）整页全重复仍继续翻页（原版 adapter 数不变即 noMore）。

**D. 书架状态（缺失）**：列表项**无在架标记**（explore_book_list.dart:258-327；原版 ivInBookshelf 三元匹配+实时刷新）、**无批量加入书架菜单**（explore_show_screen.dart:56 顶栏仅页码控件；原版 Activity:37-45,109-127）、列表项**缺 kind 分类标签展示**（原版 llKind）。

### 3.2 结论

**内容不一致 = 双主因**：① R3（explore 未接线 loginCheckJs，未登录态误解析）；② **A1-A6 解析内核差异**（explore_books_async 是简化版，且与 Rust 自身搜索路径行为不一致）。若只修一处，`explore_api.rs:563-578`（50 截断 + 字段清洗/净化 + bookUrl 兜底）收益最大。

---

## 四、登录链路完整度矩阵

**入口对比（子代理 C 补充）**：

| 入口 | 原版 | 重构版 |
|---|---|---|
| explore 发现页 | 菜单「登录」（ExploreAdapter.kt:693-707） | ❌ 无 |
| 搜索页 | loginCheckJs 500 → 异常提示 | ❌ 仅 ErrorView 文本（search_screen.dart:239-241） |
| 详情页 | 菜单「登录」+ loginCheckJs 引导 | ✅ book_info_screen.dart:478-479,682-684（唯一可进 V2 对话框）；refreshToc 1012 → source_login_prompt（指向手动页） |
| 阅读页 | 菜单「登录」（ReadBookActivity.kt:1584-1590） | ✅ reader_top_bar.dart:749-768 + 1012 引导（指向手动页） |
| 书源管理 | BookSourceAdapter.kt:193 | ✅ source_screen.dart:910-961（指向手动页） |
| 音频/RSS | 有 | ✅ audio_screen.dart:243,728-729 / rss_articles_screen.dart:383-391 |

> **RowUi 类型澄清**：原版 RowUi.type 是**字符串枚举**（text/password/button/label/toggle/select，`RowUi.kt:19-26`），**无数字类型**（"0=普通/1=webview/2=二维码"的假设不成立）；WebView 登录由 `hasLoginForm()` 分支决定，二维码仅用于导入书源。

| 环节 | 原版 | 重构版 | 结论 |
|---|---|---|---|
| LoginUiV2 判定 / rows 渲染 / action 执行 | ✅ | ✅（login_ui_v2.rs + _LoginV2Dialog） | 健康 |
| **login 命令落库（putLoginInfo）** | ✅ SourceLoginV2Delegate:268-274 | ❌ 丢弃 | **断裂** |
| **登录缓存同步（variable_store→source_login_cache）** | ✅ | ❌ login 路径无 sync（explore 路径有） | **断裂** |
| **请求头合并 loginHeader** | ✅ getHeaderMap(true) | ❌ 只读静态 header | **断裂** |
| **Cookie 统一存储** | ✅ 单一 CookieStore | ❌ 双存储分离 | **断裂** |
| 手动登录持久化读取 | ✅ | ❌ config 键无读取方 | **断裂** |
| 发现页登录入口（书源行菜单） | ✅ hasLoginUrl | ❌ 缺失 | **缺失** |
| explore loginCheckJs | ✅ 五链路 | ❌ explore 未接 | **缺失** |

---

## 五、修复建议（描述性，未实施）

> **UI 设计约束**：涉及 Flutter UI 修改必须遵循 **apple-ui-designer** 技能规范（iOS 原生观感、SF Pro 排版、中性配色、系统级组件、底部弹层优先、轻量克制）。

**第一批（P0-R1 登录链路打通，按依赖顺序）**：
1. Flutter `_LoginV2Dialog`：收到 login 命令时**不丢弃**，将 login JSON 交 Rust 持久化（对齐 `putLoginInfo`）；
2. Rust `eval_login_action_v2`：执行后补 `sync_login_cache_from_js`（对齐 explore_api.rs:314 模式），把 userInfo/loginHeader 写回 `source_login_cache`；
3. Rust 请求路径 `parse_source_headers`/client：合并 `source_login_cache::get_login_header`（对齐原版 getHeaderMap(hasLoginHeader=true)）；
4. Cookie 存储统一：legado-js `GLOBAL_COOKIES` 与 legado-net `CookieStore` 打通（setCookie 双向同步或统一存储）；
5. 手动登录 `source_login_<url>` config 键：补 Rust 读取方或改存 source_login_cache。

**第二批（P1-R3/R6，发现页内容）**：
6. `explore_books_async` 补 `execute_login_check`（对齐 web_book.rs:419 模式），未登录上抛 `LoginRequired`；
7. **R6 解析内核对齐**（explore_api.rs:438-640，与 Rust 搜索路径 search.rs 行为对齐）：① 移除 50 条截断；② 书名/作者清洗（formatBookName/formatBookAuthor）；③ 简介净化（formatIntro）；④ bookUrl 空回退 baseUrl；⑤ 重定向用最终 URL（client 回传）；⑥ `-`/`+` 前缀反转/剥离；⑦ wordCount 填充；⑧ bookType 设置；⑨ 详情页回退用 ruleInfo 规则；⑩ ExploreKind 回显 infoMap 值 + 解析失败 ERROR 行。

**第三批（P1-R2 + P2-R4/R5，发现页 UI）**：
8. explore_screen `_showItemMenu` 补齐菜单：edit/top/login（hasLoginUrl 条件）/search/refresh/delete；login 动作复用公共登录入口（apple-ui-designer 规范：系统菜单 + 底部弹层）；
9. explore_show_notifier：错误后保留 hasMore（修复重试死按钮）+ `LoginRequired` 提供「去登录」（apple-ui-designer：系统 Alert/内嵌提示）；
10. 列表项补在架标记 + kind 标签 + 批量加入书架菜单（apple-ui-designer：轻量角标、系统菜单）。

**第四批（登录引导统一，子代理 C 建议）**：
11. **统一登录引导**：`promptSourceLoginIfNeeded`/书源管理/阅读页登录统一 `isLoginUiV2` 分流——V2 走动态对话框，非 V2 才走手动页；手动页凭据改存 `userInfo_<url>`/`loginHeader_<url>`（source_login_cache 键）而非 `source_login_<url>` config；
12. **WebView 登录对齐**：补会话内 WebView 登录 + Cookie 回填（对齐 WebViewLoginFragment.kt），或外部浏览器登录后自动导入 Cookie；搜索页 1012 错误补登录引导。

---

## 五·修复进度（2026-08-14，DeepSeek Harness）

> **UI 设计约束**：涉及 Flutter UI 的修改（菜单、登录入口、错误引导等）遵循 **apple-ui-designer** 技能规范。

> **✅ 已修复并提交（master）**：
> - **R1（P0，v2.0.72，783d4ec3d/fe5bf5202/f93b58622）**：① `eval_login_action_v2` login 命令自动落库 `userInfo_<url>`；② 新增 `sourcePutLoginInfo/sourcePutLoginHeader/sourceGetLoginInfo/sourceGetLoginHeader` FFI（契约 §2.3 登记）；③ 手动登录改存 source_login_cache（旧 config 键回退迁移）；④ 请求路径（搜索/详情/目录/正文/发现）合并 loginHeader + JS setCookie Cookie。
> - **R3 + R6（P1，v2.0.72，9efb65559/0dd9938d4/4c6a07412）**：explore 补 loginCheckJs 双路径（未登录上抛 LoginRequired）；A1 移除 50 截断、A2 书名作者清洗、A3 简介净化、A4 bookUrl 兜底、A5 重定向最终 URL、A6 `-`/`+` 前缀反转、A7 字数格式化、A8 bookType 类型位。
> - **R2（P1，v2.0.73，cc16d633f/31f14b4e3）**：发现页书源行菜单六项（编辑/置顶/登录/搜索/刷新/删除，登录项按 hasLoginUrl 条件）；统一登录入口 `showSourceLogin`（LoginV2Dialog 公共化）；「搜索」预选指定书源。
> - **C/R4（v2.0.74，294f7c064/282cc0c62）**：错误后保留 hasMore 可重试、整页重复 noMore、LoginRequired 展示「去登录」引导。
> - **R5（v2.0.75，4cac7aa7b/79388d28c）**：列表项在架标记（三元匹配）+ 顶栏批量加入书架 + kind 分类标签。
> - **B②+B①（v2.0.76，3ef3dff6d/8504d1052/55e673010/27ff679d3）**：探索分类 JSON 解析失败产出 ERROR 行；toggle/select/text 回显 infoMap 已存值（新增 exploreInfoMapSnapshot FFI，契约 §2.18 登记）。
> - **A9（d754c931e）**：explore 列表空时按详情页单本回退解析（ruleBookInfo）。
> - **聚合源分类 ERROR 根治（v2.0.79，fce86ecc2）**：书山/番茄等聚合源 exploreUrl 依赖 jsLib（getConfig/getServerHost/setConfigs 等），三层根因：① rquickjs `ctx.eval` 默认 **strict**（rquickjs-core ctx.rs:46 `JS_EVAL_FLAG_STRICT`），jsLib 函数裸调用 `this=undefined` → 书山 `let { source } = this` 报 `Cannot convert undefined or null to object`；引擎 `eval`/`eval_with_bindings`/`eval_bytes` 改 `EvalOptions { strict:false, global:true }`（对齐 Rhino 非严格 this=globalThis）；② jsLib 含 Rhino `Packages.*` 时前缀截断丢失后部函数（getConfig 在截断点之后），新增 `sanitize_js_lib_for_quickjs` 移除 Rhino 特有行后完整加载；③ exploreUrl 经 `new Function` 参数执行（避免 IIFE eval 严格继承）。**注意**：改 Rust 后须重跑 `rust/scripts/build-android.ps1` 重生成 .so（gradle 只校验 content hash 不重编），否则 APK 打包旧逻辑。
> - 验证：legado-ffi quickjs **334/0**、workspace 全量通过、**模拟器 5556/5558 书山聚合分类实测正常**（个性推荐/榜单全出，无 ERROR）、冒烟 7/7。
> - **剩余**：A\* 真机/实网验收（WebDAV 实网、真实书源登录链路、漫画/视频源实读等，依赖用户素材）。

---

## 六、待办

- [x] 子代理 A：原版行为基准（loginCheckJs 语义 / 登录入口 / 解析内核差异 / ExploreKind type 枚举 / 双页码机制）
- [x] 子代理 B：重构内容审计（**10 项解析差异：A1-A6 P1 + A7-A9/B/C/D P2**，§3.1）
- [x] 子代理 C：登录链路完整对比（R1 四断裂点 + 手动登录无读取方）

**三路子代理全部收敛，排查完成。**

编写者：DeepSeek Harness ｜ 2026-08-14
