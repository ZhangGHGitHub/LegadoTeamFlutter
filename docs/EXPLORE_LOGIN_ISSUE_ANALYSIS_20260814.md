# 重构版发现页问题排查报告（2026-08-14）

## 十一、UI 对齐自动比对批量修复（v2.0.87，2026-08-14）

用 `scripts/ui_parity_compare.ps1`（自动导航原版/重构版到 5 个界面抓取语义树对比）一次性跑出全部差异并批量修复：

### 1. 编辑书源页（自动比对 MATCH）
- **dp/px 混淆根因**：Flutter 布局数值单位即 dp，此前把原版 XML 的 dp 值当 2 倍像素写（48dp 写成 96），导致设置卡片/TabBar/字段导航条整体偏高 48px（模拟器 2x 密度下 96dp=192px vs 原版 48dp=96px）。全部按原版 dp 值修正：设置卡片 header minHeight 48dp、TabLayout 36dp、field_nav 48dp，实测 TabBar/字段导航条/表单字段 y 与原版一致。
- 设置卡片改自定义 header（对齐原版 options_header：minHeight 48dp、paddingStart 12/End 4、内层 paddingVertical 4、「设置」16sp + 摘要 12sp 单行 + 40dp 展开箭头）；语义节点文案对齐原版「设置, 摘要, 展开/收起」。
- 字段导航条每项固定 72dp 等宽、去水平 padding（对齐原版 scrollable TabLayout tabMinWidth 72dp、贴边 x=0）；表单字段去水平 padding 贴边（原版 RecyclerView 无 padding + item TextInputLayout match_parent）。

### 2. 书源管理页
- 行高对齐：padding 14dp×2 + Switch 压缩（materialTapTargetSize.shrinkWrap），行距 137px 与原版一致（此前 Material Switch 48dp 把行撑到 162px）。
- 底部操作栏对齐原版 SelectActionBar：全选 weight=1（Expanded）、反选/删除固定 82dp、更多 36dp 图标、paddingLeft 16/Right 8；全选 x=32 与原版一致。

### 3. 经典登录表单（书山聚合）
- **按钮顺序修复**：此前把全部按钮收集到表单末尾统一渲染，导致顺序错乱、按钮被推出视口（dump 只有前 2 个输入框）。改为按 loginUi 数组原序逐行渲染（对齐原版 SourceLoginV2Delegate buildViews rows.forEach），按钮按 basisPercent 同行（Wrap 模拟 Flexbox 换行）。实测 13 个按钮全部可见、坐标与原版一致（Δx40 为按钮宽度百分比算法差异）。
- **toggle 行不渲染**：原版 when 无 toggle 分支直接跳过；此前我们渲染 toggle 导致「❤️段评开关/🖐SVG大小」多余并占用视口。
- 标题「登录 <源名>」、右上「确认」对齐原版；去掉原版没有的左上关闭按钮（返回键关闭仍持久化登录信息，PopScope 对齐 onDismiss）。
- 按钮/输入框补 Semantics 标签（无障碍 + uiautomator 可感知，双节点映射）。

### 4. 工具修复
- 修正 `@($null)` 产生 1 元素 null 数组导致未匹配节点误报「重构(, )」的 bug。
- 忽略名单补充：Android 双节点语义（clickable 父节点与子 TextView 同时暴露）、TextField label 不进 uiautomator（邮箱/密码/自定义源站）、输入值（test@example.com/密码点）、登录表单 toggle 行、书源数据差异（PO18小说 等）。

### 5. 剩余已知噪音（非 UI 缺陷）
- bookshelf/discover：两侧书架书、书源列表不同（数据差异）；'书架' 底部导航 vs 顶部标题（Flutter 底部导航语义）。
- source_manage 底部栏：竖排 icon+text 按钮（iOS 风格）vs 原版横排文本，y/x 差 10-58px。
- source_login：Dialog.fullscreen AppBar 标题/确认位置（原版 AlertDialog 顶部）、按钮宽度百分比算法（原版 Flexbox 内容宽 vs 我们的 basisPercent 0.4 默认）。
- 验证：flutter analyze 0 错误、flutter test 1188 全过、编辑页 MATCH、冒烟 5/5。

---

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

> - **书山聚合「个性推荐只剩一本」根治（v2.0.81，2026-08-14）**：v2.0.80 修复后列表能出书但只剩 1 本。定位链：① 真实链路复现「唯一 book_url 数 = 1」——30 本书 bookUrl 全部回退为 baseUrl；② bookUrl <js> 规则顶层 let source = result.source 与 setup 脚本全局 ar source 同处 QuickJS 全局词法环境 → edeclaration of 'source' SyntaxError → 规则结果被吞空 → A4 兜底 baseUrl → Dart 侧按 bookUrl 去重折叠成 1 条；③ 即使声明冲突解决，esult 注入为 JSON **字符串**导致 esult.source 属性访问取不到字段 → detail={} → e30=（空对象 base64）仍同 URL。两层修复：① 规则 JS 改经 
ew Function 内 eval 执行（独立词法作用域，对齐 Rhino 每次 evalJS 独立作用域；analyze_rule.rs execute_js_rule）；② 新增 AnalyzeRule::set_element_content——JSON 列表元素注入 result 时按**解析后的对象**注入（对齐原版 Kotlin getElements JSON 模式返回 Map 对象），explore/search/目录元素循环全部接入。实测「唯一 book_url 数 = 30」；回归测试扩展断言每本书 detailsUrl 唯一。验证：legado-parser 217/0、legado-ffi 335/0、workspace 全量通过。> - **书山聚合「暂无书籍」根治（v2.0.80，2026-08-14）**：分类正常渲染但点入分类列表为空。三层定位：① 服务器实测 ead_recommend?session= 与 ?session=undefined 均返回 HTTP 200 + data.cell_view.book_data **30 本书**（419KB）——空列表非服务器/登录态问题；② 普通网络源（95590 玄幻小说 7 本）列表正常 → 解析内核链路无恙；③ 根因：xplore_books_async 的 construct_analyzer 仅注入**空 jsLib、无 setup**，而书山 ruleExplore.bookList <js> 脚本第一行即调用 jsLib 函数 let session = getSessionId() → getSessionId is not defined ReferenceError → get_elements(...).unwrap_or_default() 吞错 → 空列表 → A9 单本回退也无命中 →「暂无书籍」。修复：新增 construct_analyzer_with_source_context（注入 sanitize jsLib + 书源 setup source/cookie），explore 两个 analyzer 构造点全部接入；回归测试 	est_shushan_booklist_js_with_jslib_and_setup（真实书山 jsLib + 合成 read_recommend 响应 → 解析出 2 本书 + 书名规则命中）。legado-ffi quickjs **335/0**。**注意**：改 Rust 后须重跑 ust/scripts/build-android.ps1 -Targets x86_64（+aarch64/armv7）重生成 .so 再打包 APK。
> - **剩余**：A\* 真机/实网验收（WebDAV 实网、真实书源登录链路、漫画/视频源实读等，依赖用户素材）。

---

## 六、待办

- [x] 子代理 A：原版行为基准（loginCheckJs 语义 / 登录入口 / 解析内核差异 / ExploreKind type 枚举 / 双页码机制）
- [x] 子代理 B：重构内容审计（**10 项解析差异：A1-A6 P1 + A7-A9/B/C/D P2**，§3.1）
- [x] 子代理 C：登录链路完整对比（R1 四断裂点 + 手动登录无读取方）




### 十一、UI 对齐自动比对工具（scripts/ui_parity_compare.ps1，2026-08-14）

用户提出「UI 细节能否全自动修改」。实现自动化的「检测 + 验证」环节（代码修改仍由编码 Agent 批量执行）：
- 用法：.\scripts\ui_parity_compare.ps1 -Device emulator-5556 -NavigateTo source_edit——自动启动原版（com.legado.app.release）与重构版（io.legado.flutter_legado），导航到指定界面（内置 source_edit 导航：发现页→长按书山聚合→编辑），分别抓取 uiautomator 语义树，归一化后对比：
  - 缺失节点（原版有、重构版无）/ 多余节点（重构版有、原版无）
  - 文本顺序差异
  - 坐标偏移（>24px，装饰性图标列入忽略名单）
- 输出：	mp_debug/parity/<screen>_diff.txt + 控制台摘要；退出码 0=MATCH / 1=DIFF（可作 CI 门禁）。
- 实测：编辑页自动比对 = MATCH（双方 26 个语义节点文本/顺序/坐标一致）。
- 局限：语义树不覆盖纯视觉差异（颜色/间距/字号/圆角），需截图人工比对或扩展像素对比；代码修改仍需 Agent 依据 diff 批量实施（不再逐条人工反馈）。### 十、编辑页输入框与字段导航条样式对齐（v2.0.85，2026-08-14，用户反馈）

1. **输入框去背景**：全局 inputDecorationTheme（iOS 灰色圆角填充框）在编辑页字段覆盖为 illed=false + InputBorder.none（无框无背景），对齐原版 TextInputLayout 无框输入。
2. **补分割线**：字段底部 UnderlineInputBorder 半像素灰线（聚焦变主色），对齐原版 Material 下划线（用户反馈「缺分割线」）。
3. **字段导航条选中高亮线**：原版 field_nav（TabLayout）选中字段名下方有主色指示线（实测原版 R229 G57 B53，位于 源URL 下方 y=428）；重构版字段导航条渲染 2px 主题色指示线（选中字段跟随焦点，默认高亮首个字段，切换主 Tab 重置）；像素采样确认指示线位置与原版一致。### 九、编辑书源页 UI 细节对齐（v2.0.84，2026-08-14，用户实测反馈 9 项）

逐项对照原版 BookSourceEditActivity 实测 dump（含坐标）修复：
1. **标题显示不全**：保存按钮由 TextButton（占宽）改为原版图标位，标题「编辑书源」恢复完整显示。
2. **操作按钮顺序**：原版 source_edit.xml = 编辑内容(menu_fullscreen_edit) → 保存 → 调试源 → 更多选项；改为图标序（保存仅图标无文字）。
3. **Tab 位置**：原版布局顺序 = TitleBar → options_card(设置) → tab_layout(7 Tab) → field_nav → RecyclerView；TabBar 从顶栏移至正文、置于设置卡片下方。
4. **缺一个选择项（字段导航条）**：新增 field_nav 对齐——当前 Tab 字段名横向滚动条（源 URL/源名称/…），点击 Scrollable.ensureVisible + 聚焦。
5. **文字颜色**：设置标题 16sp onSurface、摘要 12sp onSurfaceVariant、字段标签灰字（secondaryText 语义）。
6. **文本框全部展开**：字段 minLines=1（默认单行收起，内容增长展开到 maxLines）；isDense。
7. **更多选项覆盖按钮**：AppBar 内 PopupMenuButton 弹出层（无论 under/默认）实测都覆盖顶栏按钮；改 showMenu 显式 RelativeRect 锚定顶栏下缘（top=156）+ 紧凑行高（44）使 12 项在工具栏下方完整展示（实测首项 y168，原版 y170）。
8. **更多选项内容不一致**：按原版 source_edit.xml 顺序 登录/搜索/清除Cookie/自动补全/拷贝源/粘贴源/设置源变量/二维码导入/二维码分享/字符串分享/日志/帮助，移除原版没有的「JSON编辑」。
9. **设置卡片样式**：圆角 Card + 摘要行，位于 Tab 上方。### 八、编辑书源页按原版重构（v2.0.83，2026-08-14，用户实测反馈）

用户反馈：编辑页有信息了但与原版显示不一致，且要求修改必须生效。对照原版 BookSourceEditActivity.kt（sourceEntities/searchEntities/exploreEntities/infoEntities/tocEntities/contentEntities/reviewEntities 全部 EditEntity 列表 + values-zh 标签）逐项重构：

1. **字段集合/顺序/标签对齐**：基本 Tab 13 字段（含此前缺失的 loginCheckJs/coverDecodeJs/bookUrlPattern/variableComment/concurrentRate/jsLib）；搜索/发现/详情移除原版不展示的 updateTime 行并按原版顺序排列；段评 Tab 改为原版 20 行（summary 5 + detail 8 + quote/reply 7），其余 ReviewRule 字段（reviewUrl/avatarRule/vote 等）原版编辑页也不展示；Tab 8→7（原版无「调试」Tab，调试源为顶栏菜单）。
2. **设置面板**：收起态显示原版摘要「设置 + 文本 | 启用 | 发现 | CookieJar | 段评 | 事件监听 | 定制按钮」。
3. **修改生效（关键修复）**：① _buildSource 从被编辑书源透传表单未展示字段（updateTime、段评未展示行），此前每次保存会把这些字段清空——编辑一次即丢数据；② 保存成功后 _afterSaveRefresh 刷新发现页书源缓存（xploreNotifierProvider.refresh），此前发现页内存持有旧对象，保存后再次打开编辑页显示旧值、再保存会把已改值回退（复现：改名保存 → 重开编辑页仍显示旧名）。
4. **实测**：改名 ShuShanNew → ShuShanNew2，保存后发现页**立即**显示新名、冷启动后持久、重开编辑页回填正确；SQL 恢复原书源名「📚书山聚合」。### 七、编辑页 / 登录表单修复（v2.0.82，2026-08-14，用户实测反馈）

**编辑书源空表单**：发现页书源菜单「编辑」经 pushNamed(sourceEdit, arguments: source) 传完整 BookSource，但路由 sourceEdit: (_) => const SourceEditScreen() 忽略参数 → 打开即空白（「没有任何书源信息」）。修复：路由接参 + SourceEditScreen.source 参数即时回填；sourceUrl 直达入口（阅读页/听书页）在 notifier 内存列表未命中时兜底从 API 拉取；设置面板默认收起（原版为紧凑单行设置），基本字段首屏可见。

**登录界面与原版不一致**：书山聚合 loginUi 为**经典 JSON 行协议**（83 行：邮箱/密码 + 账号登录/注册/退出/切换书源等按钮），非 V2。此前 showSourceLogin 仅按 V2 分流，非 V2 一律落手动 Token/Cookies 页 → 与原版 SourceLoginDialog 完全不符。修复：新增 ClassicLoginDialog——解析 loginUi 行（text/password/select/button/toggle + style.basisPercent 网格布局）；按钮动作经 xploreEvalAction 执行（组合脚本 globalThis.result = 表单JSON + loginUrl JS + action，对齐原版 valJS("\n") { put("result", result) }）；顶栏 ✓ 保存登录信息（putLoginInfo）并 login.apply(this)（对齐 menu_ok → login(source)）；⋮ 菜单（查看/删除登录头、清除登录信息、日志）；关闭时持久化（对齐 onDismiss）。分流顺序：V2 → 经典表单（loginUi 非空）→ 手动凭据页。

**登录提示不可见**：java.toast 此前仅写 stderr（无 UI），登录动作的「正在登录/请先填写账号和密码并点击✓保存后登录」等提示与原版不一致。修复：misc_api::toast/long_toast 在 ui_action_queue 收集开启时入队 {"action":"toast/longToast"}，Flutter PlatformBridgeService.dispatchPayload 回放为 SnackBar（4s/5s）。实测：点「⭕账号登录」底部弹出「❌ 请先填写账号和密码并点击✓保存后登录」（书山 login() JS 原文）。

**关于「刷新后底部提示未登录」**：该提示来自书山 exploreUrl JS 的 java.toast("番茄登录已过期，请重新登录") / java.toast("您还未登录番茄账号，无法同步数据")（未登录番茄账号时每次展开/刷新发现分类都会触发）。原版行为一致（Android Toast 底部弹出）。本次已让登录表单的 toast 可见且可登录（登录后书山账号相关功能可用）；探索页刷新路径的 toast 暂未接通（需 exploreParseUrl FFI 返回 actions，契约变更另立任务），当前与「原版可见」的差异仅在于探索页刷新 toast 不显示。

**三路子代理全部收敛，排查完成。**

编写者：DeepSeek Harness ｜ 2026-08-14
