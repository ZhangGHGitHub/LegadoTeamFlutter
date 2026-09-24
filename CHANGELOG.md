# Changelog

All notable changes to this project will be documented in this file.

## [2.0.308] - 2026-09-23

### Fixed
- [UI] **书籍详情页「在读」行章号错位一章（P2-21）**：该行此前把 0 基的 `durChapterIndex` 按 1 基解读（`chapters[durIdx-1]`），用户在第二章时显示**前一章**的章号与标题；现改为「标题优先取阅读记录存储值 `durChapterTitle`，无则回落目录 `chapters[durChapterIndex]`（0 基），皆无则不渲染该行」，并去掉自创的「第N章」前缀。
- [UI] **详情页「最新」行与「共N章」行对齐参考版/原版口径（P2-21）**：「最新」行改为 `最新 · {latestChapterTitle}`（去掉「第N章」前缀与代码追加的「（全书完）」——该后缀实为站点标题自带）；「共N章」行由「共 N 章｜已读/未读」两态改为 `共 N 章` + `|` + `未读 / 已读 N 章 / 已读完` 三态（N = `durChapterIndex+1`），颜色改用主题角色色（章数 primary、分隔与状态 secondary）。
- [UI] **详情页元信息区按参考版整理（去冗余行）**：移除参考版**不存在**的三处独立行——「目录：… · 已读: X%」行、「分组：…」行、「🏷️ 标签行」；分类/字数/分组改由顶部 chips 行承载（分组 chip 仅在该书有非空分组时显示，分组名裸名无「分组：」前缀），chips 行不再重复章数（章数由「共 N 章」行承载）。功能入口不丢：目录 → 四按钮「查看目录」卡；分组 → chips 行分组 chip + ⋮ 菜单「设置分组」；逐标签点击搜索/长按 JS 回调 → kind chip 手势（超集）。**登记**：原「已读: X%」百分比随该行移除，无同等替入口（进度以「已读 N 章」状态与书架进度条/阅读器呈现）。

### Added
- [Rust] **书源脚本 `java.io.InputStream` 最小能力面（队列末项）**：按「能力清单，只覆盖用到的类」口径，为真实语料夹具（favcomic jsLib，索引 703）用到的字节流类提供纯内存等价实现（构造拷贝、TypedArray/数组就地写读、`read(buf,off,len)` 越界抛错、`len==0` 返回 0、EOF 返回 -1、`mark/reset` 按 `ByteArrayInputStream` 语义），实例未知成员经 Proxy 回落「此书源需要 Java 脚本能力（`<符号>`），当前不支持」并登记能力台账；`PrintStream`/`File`/`IOException` 等 0 语料命中且依赖真实 JVM 语义的类**明确不支持但提示保留**。真实夹具由「加载必失败」推进为「加载完成 + InputStream 解析可用」，未覆盖符号的用户提示与台账登记行为不放松。

### Fixed
- [Rust] **书源脚本之间不再互相串用 Cookie（P2-19 JS 宿主层作用域收敛）**：书源脚本（`java.ajax` 等）此前会把**全部书源**的 Cookie 合并进请求头——即书源 A 的脚本能带上书源 B 的凭据。现改为只携带**当前书源**的 Cookie（精确键 + ETLD+1 域名键，复用 HTTP 层同一套多段 TLD/IP 键口径，同名键精确者优先）；**没有书源上下文的脚本执行路径（字典规则、自动任务、替换规则预览、开发用 eval、JS 单文件源导入期）不再携带 JS 宿主 Cookie**（原先会带全量，正是泄漏面）。图片解码规则路径补书源绑定，保证本源 Cookie 照常携带。

### Fixed
- [Rust] **换源/刷新目录后「共 N 章」「最新章节」不再显示旧源数据**：此前换源提交与目录刷新只重写章节目录，不更新 `books.totalChapterNum` / `latestChapterTitle`（真机实测：换源后 DB 仍留旧源 1663 章、新源实为 999 章）——详情页、书架进度百分比因此显示错值。现按原版语义（`updateBookTocInfo`：章数取本次目录条数、最新取目录末章、`latestChapterTime` 仅在章数增长时刷新）在**同一事务内**同步（换源两条提交通道 + 目录刷新通道全覆盖）；截断目录按原版同款「以前缀章数为准」。

### Fixed
- [Rust] **书源脚本的网络请求改为连接复用（每页省一次建连+TLS）**：此前书源 JS 的 `java.ajax`/`connect` 等**每次调用都新建 HTTP 客户端**（= 新建连接池）→ 目录/正文按页抓取时**每页重复 TCP+TLS 握手**；真实站点实测该项占每页耗时 ≈30%（≈38ms/页，TTFB 服务端处理仍占 60–70% 不可控）。现改为**进程级共享连接池**（默认 / 回环免代理 / 不跟随重定向 / 回环+不跟随 共 4 个池），语义逐项不变（逐请求超时、回环免代理、`connectNR` 不跟随重定向、Cookie 行为）；实测 10 页省 ≈380ms、50 页省 ≈1.9s。

### Changed
- [UI] **换源体验对齐原版（感知等待）**：换源搜索过程显示进度（「结果 N，进度 M/K：源名」）；**若开启换源页菜单的「加载目录」**，候选的目录会在搜索阶段**并行预拉**，选中源时**即时完成切换**（零网络等待）——大目录书的等待从「选中后干等」前移到「搜索阶段并行、有进度」；未开启时与原先一致但**过程可取消**（取消不改动书架数据）。菜单项沿用「加载信息 / 加载目录 / 加载字数」三个开关（与参考版/原版同名同义，默认关）。

### Fixed
- [iOS] **平台缺口修复（iOS 实测前）**：① 内置浏览器/书源登录/嗅探的 **http 页面此前会被系统 ATS 拦截**（现仅对 WebView 内容放开，App 自身请求仍受保护），且加载失败会给出可见提示不再静默；② iOS 阅读底栏的**亮度滑条此前整行消失**、设置里的「自动亮度」点了会抛异常（现按 iOS 能力适配）；③ **本地书导入后不再落在临时目录**（改复制到应用文档目录并以可迁移标识记录，系统清理/重装签名后仍可读，旧书兼容）；④ **自定义字体不再因容器路径变化而静默失效**（改为可迁移路径 + 缺失时提示）；⑤ iOS 文件选择器不再静默过滤掉 mobi/umd 文件。

### Fixed
- [UI] **一批阅读主流程缺陷修复（多视角猎捕所得）**：① 打开新书失败时不再显示上一本书的正文（换书即清旧状态），并发开书不再错乱（书级代际守卫）；②「刷新正文」失败不再清空整本离线缓存（改为抓取成功后才失效缓存）；③ **章内翻页进度会随切后台/退出保存**（此前翻页进度从不落库，切后台或被系统回收就从章首重新开始）；④ 无正文的章节给出「本章无正文」提示而不是白屏；⑤「刷新正文」连点不再重复触发。
- [Rust] **阅读数据链路一批缺陷修复**：① 空正文缓存不再被当作命中（此前一旦写入空缓存该章永久空白）；② 换源结果不再被陈旧书籍快照整行撤销、设置保存不再回退阅读进度（全行更新改为排除进度列 + 字段级进度写入）；③ 换源期间（抓取窗口内）写入的进度不再被覆盖；④ 换目录后按索引取正文不再返回上一代目录的正文（清理失效缓存行 + 读侧 URL 校验）；⑤ 分页型书源的正文不再把**下一章正文**混入本章（补上原版的「命中下一章 URL 即截断」判定）；⑥ 目录刷新改为单事务（并发读者不再读到「0 章」空目录）；⑦ 写锁争用下进度保存改为短重试（不再等满 5 秒直接失败）。

### Fixed
- [UI] **「刷新正文」现在真的会重新拉取；换源后目录与正文会跟着新源刷新**：此前「刷新正文」走缓存优先路径——章节已缓存时等于什么都没做（菜单入口无任何提示、顶栏入口无条件弹「已刷新」）；从阅读器换源也会只换源不刷新内容。现在：刷新会清掉该书缓存并**联网重新抓取**（失败保留原正文并提示原因）；换源返回后会**重读书籍记录 → 重载新源目录 → 定位同名章节（保留章内阅读位置）→ 强制重取正文**，并给出「正在…→成功/失败」可见提示。本地书的阅读器不再显示换源/刷新/缓存入口（对齐原版）。
- [UI] **修掉两处阅读器反馈相关崩溃**：从阅读器换源在部分路由形态下会因类型不匹配直接崩溃；换源/刷新耗时较长（超 4 秒）时，收起「进行中」提示会触发框架断言崩溃、导致成功提示永远看不到——两者已修，并补了回归测试（含「重载慢于提示自动消失」的慢路径用例）。

### Added
- [Rust] **书源脚本写入的 Cookie 现在会持久化（重启后仍在）**：对齐原版——书源 JS（`java.setCookie`）写入的 Cookie 落数据库（按域名键、存按键合并后的完整串），进程启动时回填内存；此前为进程内存态、**重启即失**（每次启动都要重跑书源的登录脚本）。持久化失败只记日志、不影响本次会话使用；「清除 Cookie」入口会一并清除该域的持久行。

### Changed
- [Rust] **书源 Cookie 改为「按域名归属」并与原版对齐**：此前 JS 写入的 Cookie 只对**写它的书源**生效，导致同站多书源/多源共用同一 API 域时丢会话，且脚本用第三方域 URL 写的 Cookie 连本源自己都用不上；现按原版语义改为**按请求域名**匹配（同域 Cookie 在任意书源/任意脚本上下文向该域发请求都携带，非本源域写入的 Cookie 也按其域携带），同时保持「不相关域名的 Cookie 绝不携带」。与已保存 Cookie 的合并改为**按键合并**（静态头里已有的同名键优先，其余键追加），Cookie 头识别大小写不敏感。

### Fixed
- [Tool] **CI 补上 `legado-server` 的 quickjs 测试与 lint 覆盖面**：此前 CI 只跑 `-p legado-js`/`-p legado-ffi` 的 quickjs 档，`legado-server` 的 quickjs 门控测试**从未在 CI 运行**（并修掉两处既有测试 flake：测试 zip 命名撞名、Cookie 测试并行互清域名键）。

### Changed
- [UI] **深色模式页面底色与卡片底色对齐参考版（D9，用户裁决按参考版取值）**：默认（内置）色板深色下，页面背景 `#424242` → **`#101418`**、卡片/容器底色 `#4A4A4A` → **`#1D2024`**（更深的夜间底），与参考版默认深色一致；亮色模式与 12 套具名色板**不受影响**。实机验证：深色 10/10 采样命中、亮色回归 8/8 命中。
- [Rust] **详情/目录等 HTTP 取数路径的 Cookie 查找口径与 `java.ajax` 统一**：此前 FFI 取数路径只按「书源 URL 精确键」查 JS 宿主 Cookie，导致以域名键（ETLD+1）写入的 Cookie 在脚本请求里带、在详情/目录请求里不带；现两条路径统一为「精确键 ∪ ETLD+1 域名键、精确键优先」（与 HTTP 层同一套多段 TLD/IP 键口径）。无公共 API 与契约变更。
- [Rust] **搜索聚合三路径统一（P2-20，内部重构）**：Dart 纯函数 `applyPrecisionSearch` 与 Rust 单一真源补上与运行时增量桶一致的**跨桶预去重**（同一「书名+作者+书源」仅首次到达入桶、落桶由首次到达决定；跨源计数仍由 origins 集合承载），跨端夹具 `keep_other` 期望 8→7 条；`applyPrecisionSearch` 无生产调用（运行时走增量桶），**用户可见行为不变**。
- [Rust] **JS 宿主请求对回环地址不再经系统/环境代理**：书源脚本（`java.connect` 等）访问 `127.0.0.1`/`::1`/`localhost` 时绕过代理（对齐 legado-net 既有回环免代理约定），本地源/本地测试服务不受环境代理劫持；真实主机仍按用户代理配置走。无用户可见变化。
- [Tool] **代码规范门禁对齐并上锁**：清掉 `cargo clippy --workspace --all-targets -- -D warnings` 的全部 64 处既有报错（测试/示例目标，纯行为等价改写：结构体更新语法、`is_multiple_of`、`is_empty()`/`first()`、`io::Error::other`、冗余 `#[must_use]`、测试模块后的代码位移等），并给 CI 的两条 clippy 作业加 `--all-targets`——`rust/DEVELOPMENT.md` 记载的严格门禁自此与 CI 一致且被自动拦截。无用户可见变化。
- [Rust] **搜索跨源聚合下沉为单一真源（内部重构，界面与行为零变化）**：新增 `legado-core::search_aggregate` 纯函数（同名同作者跨源合并 + origins 累加、四桶分桶 equal→tags→contains→other、桶内 originsCount 降序 + 首次到达序平局、空关键词原样返回），与 Dart 现行纯函数 `applyPrecisionSearch` 逐条对齐；`legado-ffi` 内新增 `aggregate_search_books_json` 作为跨端校验入口（crate 内 `pub`，**未暴露 FRB**，方法数不变）。
- [Rust] **`CoreSearchBook` 加法式新增可选字段 `origins`**（`#[serde(default, skip_serializing_if = "Vec::is_empty")]`，空时序列化省略）——既有搜索批次/解析/DB 路径不填充，批次 JSON 形态与旧消费方**零破坏**；Dart 侧 `SearchBook.origins` 加法式消费（非空优先、空回退 `{origin}`），运行时增量桶聚合路径未切换。
- [Rust] **跨端夹具锁定两端聚合等价**：新增 `rust/legado-ffi/tests/fixtures/search_aggregate/cross_source_merge.json`（5 case：跨源合并 / 精准搜索丢弃 other / 空关键词原样返回 / 归一化 Unicode 边界 / 重复与空串 origins），Rust 集成测试与 Dart 单测读同一夹具比对（origins 按序比对，首次出现序为契约）。
- [Rust] **聚合路径归一化改为 ECMAScript 等价实现**：Dart 探针逐码点实测 `\s`（25 成员，含 U+FEFF 不含 U+0085）/`trim`（26 成员）/`.` 排除集（4 成员）三集合分别建模——`regex` crate 的 Unicode 语义（`\s` 含 U+0085 不含 U+FEFF、`.` 仅排除 LF）与 Dart 不等价，原「正则文本相同即等价」的假设被证伪。

### 说明
- 本批为内部重构：Dart 运行时仍走既有增量桶路径，UI 与用户可见行为**零变化**；差异登记见 `docs/REFACTORING_ACTIVE_PLAN.md` P2-20（Dart 纯函数与增量桶两条路径自身不一致，待裁决）。

## [2.0.307] - 2026-09-22

### Fixed
- [Rust] **Cookie 域名存储键收敛为 ETLD+1（对齐上游 `NetworkUtils.getSubDomain`）**：修正多段 TLD 站点（如 `a.example.com.cn` 与 `b.other.com.cn`）共用键 `com.cn` 导致的 **cookie 互相覆盖/跨站携带**；IP 主机（含 IPv6 `[::1]`）与单标签 host 以自身为键；**清除/查询侧同步收敛**——`clearCookie` 与 MCP 的 `get/clear_cookies` 此前仍按"末两段"计算，多段 TLD 与 IP 书源清 Cookie 会**空转但界面仍提示成功**。另补 6 条私有后缀（`github.io`/`blogspot.com`/`pages.dev`/`vercel.app`/`netlify.app`/`workers.dev`）。
- [Rust] **书源规则 Cookie 与已保存 Cookie 按键合并（规则优先）**：修正此前"DB cookie 整体替换规则 Cookie"（上游 `AnalyzeUrl` 为按键合并且规则优先）；顺带修正同场景会发出**两条 Cookie 请求头**的问题（`header()` 为 append 语义）。

### 升级说明
- 本次调整后，**多段 TLD 站点与 IP 字面量书源**（自建/局域网）的持久 cookie 在首次请求时不再携带，可能需要**重新登录一次**；其余域名（2 段/单段/普通子域）键前后一致，不受影响。

## [2.0.306] - 2026-09-22

### Changed
- [UI] **设置「外观」页信息架构对齐参考版（A3）**：页标题改为「外观」；页首新增「主题模式」分组（跟随系统/浅色/深色 三段选择 + 主题色卡同行，色卡形态不变）；顶栏/底栏设置合并为「主界面」组；「详情与圆角」拆为「书籍详情页」与「容器设置」；「毛玻璃」改「模糊效果」、「主题列表」改「主题管理」、「设置行分隔线」改「显示分隔线」；字体大小副标题与对话框文案统一格式。参考版独有的功能（护眼模式、组合引擎开关、完整主题包管理屏等 **12 项**）**仅登记不实现**（守重构红线）。

### Added
- [UI] **书架 Mock 样例数据脱敏化（P2-3）**：调试用书架占位数据替换为**合成脱敏样例**（10 本虚构书籍，结构对齐真实字段，覆盖网络/本地、封面有无、分组、未读/在读/读完三态），并加**脱敏护栏测试**（样例内主机名仅 `example.com`）。

## [2.0.305] - 2026-09-22

### Fixed
- [Rust] **书源脚本能力缺失时不再静默失败**：书源 JS 访问我们未实现的 Java 类/成员（`Packages.*`、`Java.type`、`importClass` 等）时，给出明确文案「此书源需要 Java 脚本能力（`<符号>`），当前不支持」并**登记到进程内能力台账**（供"下一批该补什么"决策）；读取式探测保持安全（`typeof Packages.x` 不报错，仅在**调用/取子成员**时告警），916 源语料实测无脚本被此改动救活或误伤。
- [Rust] **`searchUrl` / `bookList` 的 JS 失败不再被静默吞掉或误分类**：错误文本正确解码并归类为 `js_error`（`error_class` 枚举与批次 JSON 形状不变）；**其余错误类维持原有容错**（仅能力缺失类上抛）。
- [Rust] 移除会**误伤纯 CSS 书源**的「是否有 JS 面」预校验（favcomic 类源的搜索规则全是 CSS、`{{key}}` 仅字面插值，原预校验会把它判成整源失败、永久 0 结果）；`legado-js-error://` 解码 guard 修正（原判断用解析后 URL，前缀丢失导致解码为死代码）。

### Added
- [UI] **搜索结果页新增「失败书源」横幅（非阻断）**：单源失败（含能力受限）不再无声——顶部横幅显示失败文案，点开可看**涉及的源名与各自错误**；不改动整体搜索交互。

## [2.0.304] - 2026-09-21

### Changed
- [UI] **点一本"还没读过"的书现在直接开始阅读（A4 对齐参考版/原版）**：此前单击未读的书只会停在详情页（我方自创回退）；现与原版 `startActivityForBook`、参考版 Compose `onClick` 及重构版 `openReaderImmediately` 三方一致——单击即进入阅读（经详情页自动开读，零进度从首章开始），**长按仍进详情页**。含两条防抖硬化：①用户抢先点「阅读」按钮时不再重复入栈（返回不会落在上一层阅读器）；②首轮目录未就绪时不再"随刷新补开读"（手点刷新/书源刷新不会把用户拽进阅读器）。
- [UI] **深色搜索输入框配色回退为容器色 `surfaceContainerLow`（A6 对齐）**：修正上一批引入的 `isDark ? onSurface` 在**透明主题**下会渲染成不透明白盒的问题（参考版透明板深色盒为"全透明透现"，实测白底 40/40=255、灰底 54/55=128）；提示文字与搜索图标深色态改用前景色（透明板下 `surface` 为全透明、不可见）。

## [2.0.303] - 2026-09-21

### Changed
- [UI] **主题选择页对齐参考版形态（A2 同步风格版）**：色卡由 4 列网格改为**横滑一行**；卡片改为 **64dp 方卡 + 16dp 间距**；选中态为 **2dp 主色描边 + 40dp 主色圆点内勾选图标**（依据参考版源码 `ThemeConfigScreen.kt:1020/1032/1089-1158`）。保留我方卡片内的亮/暗双色预览与三色点（功能实现倾向我方，已在注释注明）。
- [UI] **主题名称与顺序对齐参考版**：9 处显示名对齐（纯白→黑白、森绿→草野、墨水→电子书、穹→晴空、小春→春、优香→千禧年、菲比→隐海修会、卡洛塔→新浪潮、姆吉卡→乐队），顺序按参考枚举重排；参考版独有的「动态取色」「自定义」两项仅登记、不新增（守重构红线）。选色逻辑、持久化键与色值零改动。

## [2.0.302] - 2026-09-21

### Changed
- [UI] **设置主页「字体管理」入口收起**（按参考版口径：字体/字号在阅读器内调整）：入口从设置主页移除，字体页面与功能保留，仍可从阅读器排版面板（「阅读字体」/「选择字体」）进入。已登记为授权偏离。
- [UI] 「我的」页 Web 服务卡启用态强调色由 iOS 系统绿改为**当前主题主色**（`colorScheme.primary`），随调色板与明暗主题联动，不再残留绿色（该处为 iOS 时代孤儿色板 `app_colors.dart` 的最后一处消费方）。

### Removed
- [UI] 删除 iOS 时代孤儿色板 `lib/src/theme/app_colors.dart`（97 个槽位、仅 1 处真消费方，已迁移至 MD3 scheme）；阅读排版引擎的 `ParagraphConfig` 颜色默认值改为**必填**（漏传即编译报错，消除"白底白字"类静默事故）。

## [2.0.301] - 2026-09-21

### Changed
- [UI] **书源编辑器扫码改为全屏扫描器**（对齐参考版形态：标题 + 图库按钮 + 取景框），新增**从相册选图本地解码二维码**（纯 Dart 解码，无相机也可导入）；含 CJK 内容解码修正——规避 `zxing2 0.2.4` 把字节段按有符号 `Int8List` 读入导致的中文乱码（`_recoverUtf8Text` 重建字节后按 UTF-8 重解码）。
- [UI] **阅读器菜单键集收敛到参考版 5 键**：移除自创的额外入口（字号/亮度在阅读器内仍可调），对齐"视觉/形态照参考版"的全域口径。
- [UI] 全文搜索输入盒配色改为按主题 scheme 取值（对齐参考版深色形态；实机复核项已登记）。

## [2.0.300] - 2026-09-20

### Fixed
- [UI] **深色主题下阅读背景跟随主题（M1，深色一比一必修项）**：此前深色主题下阅读器正文背景仍为纯白（参考版为纯黑，配对实测 diff 99.7%、Δlum 213~255）。现深色主题**默认正文背景为纯黑**（对齐参考实机），**阅读中切换主题背景即时生效**；用户显式选择过的背景（自定义色或预设，含「夜间」0xFF1A1A1A）保持不变、不随主题漂移。连带修正 `isDarkBackground` 派生判定，顶栏/底栏/菜单/状态条的「跟随页色」前景在纯黑背景下自动取浅灰，对比度达标；正文渲染路径（亮度自适应）零改动。

## [2.0.299] - 2026-09-20

### Fixed
- [UI] **非致命布局告警不再被误报为崩溃**：全局错误处理器此前把 `A RenderFlex overflowed ...` 这类软性布局告警也写入崩溃记录，导致下次启动弹「上次运行发生崩溃」。现按特征分类——软性告警只记普通日志（`[布局告警]`），不产生崩溃记录、不弹崩溃弹窗；真异常行为不变。（MuMu Test 换档首跑实测发现）
- [UI] **修三处界面右溢**：RSS 文章列表卡片元信息行（宽时间戳下右溢）、书源调试日志级别过滤栏（改为横向可滚动）、换封面顶栏「本地」按钮（超出顶栏 36dp 动作槽，改为图标按钮并保留 tooltip 语义）。溢出回归守卫由 13 屏扩到 **59 屏**（360dp 画布逐屏断言），已修的 4 处（含 1 处测试夹具假象，源码零改动）全部纳入守护。

## [2.0.298] - 2026-09-20

### Fixed
- [Rust] **登录检查脚本（loginCheckJs）语义与原版逐点对齐（P3-6 F1）**：脚本返回值按"响应对象"解析——脚本可返回**修改后的列表页内容/地址**且修改会被真正采用（此前脚本改写会被丢弃、仍用原始响应解析）；脚本返回裸布尔或执行失败时按原版走错误路径：错误页上二次执行后仍失败则**整源失败**（此前一律静默放行，部分需要登录的书源会绕过登录检查直接给出错误结果）。
- [Rust] 搜索诊断增强：搜索批次事件新增逐源错误分类（八类），分段计时带会话与书源标识（内部诊断面，UI 展示后续批次跟进）。

## [2.0.297] - 2026-09-20

### Fixed
- [Rust] **修复带 `return` 的 `@js:` 列表规则被静默吞空（P2-11 ④ 顺带根因）**：此前规则代码被当顶层脚本编译，顶层 `return` 直接语法错误 → 整条规则静默变空；上游 Rhino 走 legacy 兼容模式允许顶层 `return` 所以不触发。现改为函数体求值（`return` 合法）并保留表达式式规则的回退求值。
- [Rust] **`getStringList` 语义逐条对齐上游 `AnalyzeRule.getStringList`（P2-11 ④）**：空规则/JS 求值为 null 或异常/JS 返回标量 → `null`（此前一律空数组）；JS 字符串按 `\n` 拆分（保留尾部空串）；CSS/JSON 等零命中 → 空数组；`java.getStringList` 结果补 `size()/get(i)/isEmpty()` 三个 Java List 别名（越界按 JDK 抛错）。
- [Rust] **`java.lang` 数值解析对齐 JDK 严格语义（P2-11 ③）**：`Long.parseLong`/`Double.parseDouble` 对空串/纯空白/非法十进制/越界按 JDK 抛错（不再宽松回退）；`Double` 接受 `NaN`/`Infinity` 与十六进制浮点；`Boolean.parseBoolean` 仅 `"true"`（忽略大小写）为真。
- [Rust] **正文阶段 `book` 反查改 (书源， 章节) 复合键（P2-11 ①）**：两本书章节 URL 相同时不再交叉绑定；书籍/章节缓存改为"仅新键插入导致超限才清理，更新既有键不清理"（P2-11 ②，对齐上游 `getOrPutLimit` 语义），消除热路径反复整清。
- [UI] 换源/书籍页合并时，DB 中**纯空白**的 `originBookUrl` 不再覆盖路由上的有效值（P2-11 ⑤，与取址 trim 语义一致）。

## [2.0.296] - 2026-09-19

### Fixed
- [Rust] **发现/分类页的书源脚本补 `src` 与 `book` 绑定（P2-11 ①）**：搜索/详情/目录路径早已实现「子步 `java.*` 重解析顶层原始响应」，发现（分类）路径当时漏了同一收口，导致链式脚本里的 `src` 拿到的仍是中间产物、`book` 未绑定。现已按同一约定补齐（`book` 在无书籍上下文时与上游一致取 null）；补 2 个 quickjs 档回归测试。
- [Rust] **属性提取统一为「遍历全部子元素 + 去重」（P2-11 ②）**：裸 `@href`/`@content` 形态此前只取**首个**命中子元素，与「裸 token」形态（遍历全部）不一致，部分书源在多个同形元素并存时字段/目录漏项。现按上游 `AnalyzeByJSoup` 的 `getResultLast` 语义（逐个取属性、跳空、去重）统一。

## [2.0.295] - 2026-09-19

### Fixed
- [Rust][UI] **书源脚本的磁盘缓存不再落系统临时目录（P2-15 ② 收口）**：此前 `cache.*` 未注入目录时回落到 `<temp_dir>/legado-js-cache`，Android 上多半不可写，写盘失败即无声失效（仅内部日志可见）。现 Dart 启动即把应用私有缓存目录（`getApplicationCacheDirectory()/js_cache`）注入 Rust 层（新增 frb 薄桥 `set_cache_dir` + 启动接线），书源脚本的磁盘缓存落到应用私有存储；未注入或注入失败时仍保留回落目录、不阻断启动，且写失败改为进程级**只告警一次**（不再每次失败刷日志）。
- [Rust] **切书后不再沿用上一本的阅读模式/倒序目录（P2-15 第 3 条）**：书源脚本写入的 `bookType` / `bookReverseToc` 覆盖值改为随流程 scope 切换清理（书级绑定 `bookVar` 保留，切回原书状态不丢）；同时新增「陈旧覆盖值让位」——书源更新规则后，库里已有值的键不再被旧的覆盖值压住。

## [2.0.294] - 2026-09-19

### Fixed
- [Rust][UI] **书源脚本写入的阅读模式（`book.type`）真正生效（P2-15 第 2 条）**：此前 `book.type = 8/32/64` 只改 Rust 进程内 JS 可见值，**不回流也不落库**，7 个用它切小说/音频/漫画模式的源（微信读书二合一、禁漫天堂、画涯爱子、爱妹子、HentaiCosplay、AsianPornImage、键盘小说）"自动切模式"实际不生效。现经 `WebBookInfo.type`（零值省略键、向后兼容）→ Dart `mergeBookType` → **既有** `updateBook` 落 `books.book_type`（**未新增 DB 迁移**）：
  - **覆盖语义**：只覆盖媒体位（video/text/audio/image/webFile/updateError），保留 local/notShelf 等标记位；`type==0`/缺键保留现值；详情解析为模式权威来源、**JS 写值 > 书源声明值**（对齐上游 `analyzeBookInfo`）
  - **落库时机**：Dart 详情页 `mergeWebInfo` 之后的既有 `updateBook`（入架书才写库；未入库仅展示）
  - 端到端：JS 写 `type=64` → `WebBookInfo.type=64` → Dart `bookType` 8→64 → 走漫画阅读路由
- [Rust] 补 **`type` 调用点接线用例**（P2-15 第 4 条，三阶段）：覆盖"4 个调用点是否真传 `book_type_of_source`" —— 调用点退回硬编码 0 即失败；同时用断言钉住"同解析内跨规则可见性"的现状边界
- [Docs] 台账补登记 **P2-7(c)**（CI SIGSEGV 用例根因与后续建议，上次写入失败）

### Test
- 两档均 0 失败：`cargo test --workspace`（ffi 372 / js 254）与 `--features legado-ffi/quickjs`（**ffi 454 / js 562**）
- **两档 clippy 均 exit 0**；`cargo fmt --check` 0；`flutter analyze` 0 问题；`flutter test` **1489 全过**（含新增 `mergeBookType` 6 用例）

### Note
- 例外说明：为使新字段通过编译，给 `rust/legado-server/src/handlers/web_book.rs` 的 fetcher 字面量加了 4 行 `book_type: 0`（**加法式、语义 no-op**——server 路径无 JS 写路径，恒 0 等价于改造前的 serde default）
- 同解析内跨规则的 `book.type` 可见性仍在 P2-15 ①/④ 登记（本批刻意未做，避免放大陈旧 overlay 遮蔽；测试已钉住现状 `name=="8"`，未来修复需同步改断言）

- Contributor: 全栈工程师子代理

## [2.0.293] - 2026-09-19

### Fixed
- [Rust] **打通 `java.get`/`@get` ↔ `book.putVariable`（P2-15 第 1 条）**：上一批把 `book` 的写入落到 `bookVar::{bookUrl}::{k}` 后，脚本里用 `java.get(k)`/规则 `@get:{k}` 仍读不到（三套命名空间不通）。现于 `get_flow_variable` 读链**尾部**追加 bookVar 兜底（会话层 → 裸键 → bookVar），键由**当前流程 scope**（书籍流程各入口即本书 bookUrl）构造 → 天然按书隔离、不可能跨书串读；`java.get`（解析器前言桥）与 `@get`（FFI 读者）汇聚到同一函数，单点修复覆盖两条读路径（优先级零回归，有回归测试锁定）
  - **`book.getVariable` 同阶段跨规则可见**：IIFE 在本地字面量未命中时经新增 `__lgBookVarGet` 回读 store；`book.variable` 原始 JSON 仍是构造时点快照（该边界由 `String(book.variable)` 断言锁定）
  - 源级效果：语料唯一的 `book.putVariable` 使用者「就去看网」（写 `序/元/除/嗅/兜/查` 后全部经 `java.get` 回读）由此**闭环**——测试以存储层为 oracle，证明取到的值只能来自新兜底
  - 同步修正 3 处与实现不符的注释（`quickjs_impl.rs` / `web_book.rs` / `variable_store.rs`）

### Test
- 两档均 0 失败：`cargo test --workspace`（ffi 372 / js 254）与 `cargo test --workspace --features legado-ffi/quickjs`（**ffi 453 / js 562**）
- **两档 clippy 均 exit 0**（`--workspace -- -D warnings` 与 `--workspace --features legado-ffi/quickjs -- -D warnings`——上一批漏了后者导致 CI 红，本批已固化）；`cargo fmt --check` 0
- 新增 9 个测试：读链三层优先级/跨书隔离/无 scope 不挂兜底/桥往返/同阶段跨规则/就去看网闭环/字面量快照边界

### Note
- 残余边界（如实登记）：`pre_update` 阶段 scope 用书籍页地址（换源后与稳定 bookUrl 不一致）→ 该阶段兜底优雅 miss；bookVar 仍**仅进程级**（重启丢失）；`putVariable(k,null)` 无墓碑；两书真并行共享单 scope 槽（既有项）

- Contributor: 全栈工程师子代理

## [2.0.292] - 2026-09-19

### Fixed
- [Rust] **书源脚本 `book` 绑定的写路径不再静默丢弃（P2-11 ①）**：`book.putVariable/setType/setReverseToc` 与 `book.type=` 此前只改 JS 内存副本；现经 java-only 桥落到进程级变量表的裸键（`bookVar::{bookUrl}::{k}` / `bookType::{bookUrl}` / `bookReverseToc::{bookUrl}`），并在**下一次 `book` 绑定构造**（下一阶段/下一次 FFI 调用）时合并回读（overlay 优先于入参/base）。`book.type` 初值由硬编码 `0` 改为按书源类型换算（文本 8 / 音频 32 / 图像 64 / 视频 4 / 文件 136，与上游 `BookType` 逐位一致）——`📷🔞HentaiCosplay`/`📷🔞AsianPornImage` 等义 `if(book.type==64)` 分支的源由此走上正确分支
- [Rust] **`cache.*` 磁盘层加宿主注入点并修写盘失败语义（P2-11 ②）**：新增 `set_cache_dir`（env > 注入 > temp 缺省 + 一次性回落告警）；写盘失败由静默 `.is_ok()` 改为**保留内存层并晋升新值 + 记录失败原因**（原表现为「put 后 get 永远 null」），`put_file` 补失败日志
- **如实声明的能力边界（审查指出，勿按旧表述理解）**：
  - ① 的写入**仅在下一次 `book` 绑定构造后对 `book.getVariable` 可见**；**同阶段内的后续规则读不到**，且 **`java.get`/`@get` 读不到这些键**（三套命名空间未打通）。语料中唯一 `book.putVariable` 使用者「就去看网」正是用 `java.get` 回读，**该源未闭环**（不劣于改前，但也不构成"已修好"）
  - `type`/`reverseToc`/`bookVar` 键**仅进程级、不落 DB** → 重启回到初值；且 `type` 的变化**不会回流到 DB/Dart**，故 7 个语源的"自动切小说/漫画模式"仍不会真正切换（`type` **初值**真实化的效果是实在的）
  - ② 的注入 API 就位但**无生产调用者**（Dart 侧接线属禁改区，未实施）；Android 上 temp 目录多半不可写 → 未注入时每次 `cache.put` 会打一行错误日志

### Test
- 两档口径均 0 失败：`cargo test --workspace`（ffi 372 / js 251）与 `cargo test --workspace --features legado-ffi/quickjs`（**ffi 449 / js 557**）；`cargo clippy --workspace -- -D warnings` 与 quickjs 档均 exit 0；`cargo fmt --check` 0
- 新增 7 个测试：book 写路径同流程可见性/键格式/overlay 合并/type 初值与覆盖、cache 注入命中/写失败保留内存/目录优先级

### Review
- code-reviewer「有条件合入」：确认 type 换算与上游逐位一致、键空间与 flow-scope 不冲突、两档门禁计数吻合；最小项为「如实化三处注释 + 台账登记 ② 未闭环 + 剔除无关脏文件」，均已按此登记（注释修正与 type 调用点接线用例登记为后续小项）
- Contributor: 全栈工程师子代理

## [2.0.291] - 2026-09-19

### Fixed
- [Rust] **书源脚本的跨调用变量打通（P2-9 ③）**：JS 侧的 `java.put` 此前写的是 eval 内本地快照（随调用消失），从未进入进程级变量表，导致规则 `@get:{k}` 读不到——「手机小说」「小米阅读」「就去看网」等源的 `tocUrl`/字段因此取空回退（实测手机小说目录页由 `…/book/8888/` 回退值恢复为正确的 `…/novel/6666/`）。现由 JS 前导把 `java.put` **转发**到变量表、`@get` 在既有优先级之后兜底读取；并引入 **flow-scope 作用域**（键带流程前缀）——换书只清本流程前缀，`source.put/setVariable`、登录头、`userInfo`、`cache.*` 等持久项不受影响（对齐上游 CacheManager 语义）；入口收口覆盖搜索/详情/目录/正文/阅读器刷新目录/换源/preUpdateJs 与发现页
- [Rust] **`@put` 映射值改走完整规则管道（P2-9 ④）**：`@put:{k:…##re##rep}`、`||` 组合与多值不再被截断为首值（爱丽丝书屋/独步小说/八一中文网/晋江 等）
- [Rust] **`%%` 组合的定界与上游对齐（P2-9 ⑤）**：CSS/JSONPath/XPath 三处由「最长列表」改为「**首个列表长度**」，后续列表多出的元素不再产生脏行

### Test
- 两档口径均 0 失败：`cargo test --workspace`（ffi 371）与 `cargo test --workspace --features legado-ffi/quickjs`（**ffi 446 / js 553**，quickjs 门控用例含本次全部行为证明）
- `cargo clippy --workspace -- -D warnings` exit 0；`cargo fmt --check` 0 处
- 真实源证据入仓：手机小说书源夹具移入 `rust/legado-ffi/tests/fixtures/` 并以 `include_str!` 硬依赖（缺失即编译失败，杜绝静默跳过）；新增 flow-scope 语义与「持久裸键跨换书存活」等断言

### Review
- code-reviewer 一审 `needs changes`（P1-1 整表清空会连带清掉源级变量/登录头/缓存；P1-2 兜底读取无作用域且清理只覆盖 4 个入口；P2 锁缺口/口径/夹具未入库）→ 全部修复（作用域方案 + 入口收口 + 共享测试锁 + 夹具入库）→ 待复审
- 残留登记：完整「一进程内两本书流程真并行」需 per-execution scope ID；嵌套 `@put` 的 `}` 泄漏为已知限制（锁定测试）
- Contributor: 全栈工程师子代理

## [2.0.290] - 2026-09-19

### Fixed
- [Rust] **换源后重进详情/目录不再丢书籍变量**（P2-12 的 C，属历史 P0 同型残留）：换源时写入的 `books.variable` 此前只在换源那一刻生效，「返回书架→重进详情」路径未读库内变量 → 详情/正文请求发出空参（实测 `/r1vb/detail?vid=`）。现按 bookUrl / 书籍页地址双路读 DB 变量并注入详情与目录抓取（FFI 签名零变更、Dart 无需传参），实机对照：`?vid=`（空）→ `?vid=VID123`，正文 `?tok=TK777`
- [UI] **修复启动崩溃弹窗的崩溃循环**：旧实现用 State 自身 `context` 调 `showDialog`（那时 MaterialApp 尚未构建、上方无 Navigator）→ 每次启动抛 `Null check operator used on a null value`，弹窗永不显示且 `crash_log.txt` 被反复重写。改挂全局 `navigatorKey`；并修复连带问题：冷启动 `/welcome` 闪屏的 `pushReplacementNamed` 会把首帧弹窗一并替换 → 改为等闪屏退出后再弹（`NavigatorObserver.didChangeTop`）。实机：弹窗可见、点「确定」清除日志、重启不再弹
- [Tool] 修复换源 e2e 夹具 `scripts/r1v_switch_server.py` 的 `log_event` 参数冲突（reject 分支抛异常、400 未发出，把"错误"表现成"超时挂起"）

### Test
- `cargo test --workspace` 全绿（ffi 368 / core 795 / db 308 / parser 288 / js 242 / server 171…）；`cargo clippy --workspace -- -D warnings` exit 0；`cargo fmt --check` 0 处；`flutter analyze` 0 问题；`flutter test` **1483 全过**（含新增启动弹窗 4 条）

### Real device
- 2.0.290 release（arm64/x86_64）装 MuMu：重进详情 `?vid=VID123`（修复前为空）、正文 `tok=TK777`；崩溃弹窗可点确定并清除、重启不复现；连续换源两次主链正常

- Contributor: 全栈工程师子代理

## [2.0.289] - 2026-09-18

### Fixed
- [Rust] **书源引擎对照审计 P2-9 ①② 落地**（对照上游 `app/.../analyzeRule/**`：20 组成对实验 14 组等价、0 处结构性偏差 → **结论：不需要大修**）：
  - **JS 宿主方法补齐**：`java.getStringList`、`java.setContent`、`cache.putMemory/getFromMemory/deleteMemory`、`java.lang`/`java.util` 最小面、`java.delete`、`hexDecodeToByteArray`、`upLoginData`（无登录通道，no-op 降级）；并新增 **`src` 重绑定**——JS 子步里的单参 `java.*` 现按上游语义重解析**顶层原始响应体**（526 源语料反例搜索为 0）
  - **`book` 绑定扩面**：由 `{name}` 扩为 name/author/bookUrl/tocUrl/lastChapter/variable + `getVariable`；**按 bookUrl 从 DB 读用户书籍变量**（DB 为空则回退 `@put` 导出），对齐书籍信息页「可在 js 中通过 book.getVariable 获取」的既有承诺
  - 源级效果：艾格动漫简介由「规则失败取空」恢复完整正文；聚合书库书名/最新章恢复（**口径限定**：`book.getVariable` 走 DB 用户变量，进程内**首次详情解析**仍按缓存降级，目录/正文/第二次详情起可达；首次即生效的 DB 兜底已登记 P2-11）
- [Rust] **P2-10（P2-8 审查剩余项）**：`refresh_toc` 存量坏 `tocUrl` 自愈（解析 0 章且取址不同 → 用书籍页重试一次，**单列 `update_toc_url` 回写**避免丢更新窗口）；服务器 `/api/toc/update` 接入单一取址点；Dart `_mergeDbBook` 改 **DB 优先**（换源事务是唯一权威写者）；Dart 取址对齐 `trim` 语义；RoomImporter 不再丢 `originBookUrl`；注释如实化（该字段有两个写者：换源事务与 preUpdateJs）；补 P1-1 回归测试（缺键/空串的 Book JSON 不得清空该列）
- [Rust] 修复**既有 parser panic**：`rule_analyzer` 内层规则解析失败时按字节前进可能落入多字节字符中间（`not a char boundary`）；该 panic 在「聚合书库」目录规则 `${$.len}字` 上真实触发（此前测试用 ASCII 合成规则规避，已撤销）。改为字符边界安全前进 + 越界保护

### Test
- `cargo test --workspace` **2574 passed / 0 failed**（exit 0）；`cargo clippy --workspace -- -D warnings` exit 0；`cargo fmt --check` 0 处；`flutter analyze` 0 问题；`flutter test` **1479 全过**；`cargo test -p legado-ffi` 365（默认）/ 439（quickjs）
- 新增测试：JS 宿主方法逐项断言、`book` 变量生产路径（**无手工播种**）、逐字 fixture 目录规则非 panic、`refresh_toc` 自愈只改单列、缺键不清列等

- Contributor: 全栈工程师子代理

## [2.0.288] - 2026-09-18

### Fixed
- [Root cause | P2-8] **从根上解决「换源后详情刷新用错地址」**：换源事务此前只更新 origin/tocUrl，`bookUrl`（稳定主键）保留旧源地址，而详情页「进入刷新」/「在线目录抓取」等「抓取书籍页」路径用「当前书源规则 + 旧地址」抓页——字段解析为空/退化值，写回即把 `tocUrl` 写坏（2.0.287 的刷新守卫是止损而非根因）。现：
  - `Book` 新增 `originBookUrl` 字段（Rust 模型 + legacy-db 迁移 v108→v109 追加列 + Dart freezed 模型与生成产物）：换源事务写入**当前书源详情页地址**，`bookUrl` 保持稳定主键不动——所有既有 URL 持有者（书架内存对象、详情页入参、章节记录键、refreshToc 主键查询）语义不变，零改动
  - 「抓取书籍页」取址统一走 `Book::book_page_fetch_url()`（Rust）/ `BookOpenUtils.bookFetchUrl`（Dart）：`originBookUrl` 优先、为空回退 `bookUrl`——未换源书籍与存量库行为不变（向后兼容）；接线：详情页联网刷新/在线目录（book_info_screen_load.part、toc_screen）、阅读器目录刷新（reader.rs）、pre_update（pre_update.rs）、换源事务（source_switch.rs）
  - 2.0.287 的「刷新守卫」保留并降级为纵深防御：书籍页解析无书名时跳过本次刷新（宁保留旧值不用错页覆盖）
- [Design] 方案 A（稳定主键 + 新地址字段）优于方案 B（别名表）：别名表需与所有 URL 持有者同步迁移、回归面大（P0 教训：2.0.285 改主键曾致全部换源「书籍不存在」回滚）；新字段为增量、向后兼容、持有者零改动
- [Docs] 台账 P2-8 收口；`originBookUrl` 缺省空串时全路径回退 `bookUrl`，旧库/未换源书行为与 2.0.287 完全一致

### Test
- `cargo test --workspace` 0 failed（legado_core 795 / legado_db 306 / legacy-ffi 360（19 ignored）/ legado-parser 287 / legado-js 236 / legado-net 232 / 其余 crate 全绿；含新增换源测试：「换源写 originBookUrl 且 bookUrl 不变」「两次连续换源均成功且无僵尸行」「存量书（字段缺省）向后兼容」）
- `cargo clippy --workspace -- -D warnings` 0 警告；`cargo fmt --check` 通过
- `flutter analyze` 0 问题；`flutter test` 1475 全绿（含新增 `test/unit/origin_book_url_test.dart`：取址优先/回退、mergeWebInfo refresh 守卫不误伤/缺书名跳过、缺省序列化）

### Real device
- 2.0.288+289 release APK（release `.so` 三 ABI + `build-apk.ps1 -Release -SkipRust`，161.7MB）实机复验（MuMu `192.168.1.19:5555`，adb root，包名 `io.legado.flutter_legado`）：
  - 冷启动自动完成 v108→v109 迁移：`PRAGMA user_version=109`，books 表新增 `originBookUrl TEXT NOT NULL DEFAULT ''`（第 37 列）；存量书行该列为空，取址路径回退 `bookUrl`，行为不变
  - 书「斗罗大陆」（原 🏷松鹤庭沐·言璃）两次连续换源均成功：①→ 📂瀚海书阁 ②→ ⚡📂米读小说；详情页章节数/字数/最新章随新源更新（712章/298.6万字 → 51章/142.20万字 → 712章/286.6万字）
  - 每次换源后拉库核对（`-wal`/`-shm` 一并拉取）：`bookUrl` 恒为原主键 `https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1100468021`；换源①后 `originBookUrl=https://www.ingml.cc/novel/1529.html`（`tocUrl` 同值）；换源②后 `originBookUrl=https://api.midureader.com/fiction/book/getDetail,{…POST…}`、`tocUrl=https://book.midureader.com/book/chapter_list/100/….txt`——完整、无退化
  - 进入详情页一次（U7 后台刷新）后再次拉库：`tocUrl`/字数/类型/评分未损坏（与刷新前一致），`originBookUrl` 保持有效
  - 截图 `docs/parity_shots/songhe_template_fix_20260917/p8_*.png`；库快照 `.tmp/p8_db/`（`p8_before_legado.db*` 迁移前 v108 / `p8_sw1.db*` / `p8_sw2.db*` / `p8_final.db*`）

- Contributor: 全栈工程师子代理

## [2.0.287] - 2026-09-18

### Fixed
- [UI] 换源后详情页后台刷新的**错页覆盖守卫**（台账 P2-8 的收敛）：换源后书籍 `bookUrl` 仍为旧源地址（主键保持稳定），而详情页刷新用「当前源规则 + 该地址」抓取；当该地址不是新源书籍页时，`ruleBookInfo.init` 取空、各字段解析为空，但 `tocUrl` 规则仍会拼出**退化但非空**的值（松鹤庭沐源实测 `…/api/book/all-chapter?bookId=`，缺 bookId），经「非空即覆盖」写回后 `tocUrl` 被写坏（后续「刷新目录」失败），kind/字数/简介也可能被错页结果覆盖。现按「正常书籍页解析必得书名」为判据：解析结果无书名即视为**未解析到书籍页**，本次刷新整体跳过（宁可保留旧值）。不改书籍主键、不改 FFI 参数语义
- [Docs] 台账 P2-8 保留改键的完整观察与正确做法（需与所有 URL 持有者同步/别名过渡）

### Test
- `flutter analyze` 0 问题（`flutter test` 由 Flutter CI 覆盖）

### Real device
- 2.0.287+288 release APK 装 MuMu（192.168.1.19:5555）：**连续换源可用**（A→B→C 均成功，未复现 2.0.285 的「书籍不存在」）；切到「🏷松鹤庭沐·言璃」后落库 `tocUrl = …/api/book/all-chapter?bookId=1100468021`（**完整**）、章节 712
- **关键对照**：随后进入一次书籍详情页（即此前会把 tocUrl 写成退化值的那次后台刷新），再次拉库（连 `-wal`）比对——`tocUrl` 与章节数**均未变化**，守卫生效；截图 `docs/parity_shots/songhe_template_fix_20260917/v7_02_sw1.png`、`v7_03_sw2.png`

- Contributor: 全栈工程师子代理

## [2.0.286] - 2026-09-18

### Fixed
- [Rust] **回退 2.0.285 的「换源后书籍 URL 改为新源地址」（P2-6g）**：该改动把书籍主键迁到新源地址后，应用内多处仍持有**旧地址**（书架内存列表的 Book 对象、详情页打开时传入的 URL），而换源入口用 `find_by_url(book_url)` 查书 → 旧地址失效 → **所有书源换源都报 `Database error: 书籍不存在`**（P0 回归）。现恢复「bookUrl 保持稳定、仅改 origin/tocUrl」语义（`source_switch.rs` 回退至 `db00c2f2d4`），换源功能恢复
- [Docs] 登记 `docs/REFACTORING_ACTIVE_PLAN.md` **P2-8**：改键的正确做法（需与所有 URL 持有者同步/别名过渡）+ 低成本缓解建议（在详情页 U7 刷新合并处对 `tocUrl` 加退化值不覆盖守卫，只动 Dart 合并层）

### Test
- `cargo test -p legado-ffi` 358 passed / 0 failed（含恢复的「章节挂原键」断言）

### Real device
- （待补：回退版实机换源复验）

- Contributor: 全栈工程师子代理

## [2.0.285] - 2026-09-18

### Fixed
- [Rust] 收口上一批登记的 P2-6 全部遗留项：
  - **`java.getString` 绑定层补规则类型分派**（`legado-js`）：此前只做 CSS/HTML 解析，书源 JS 里 `java.getString('$.字段')` 恒取空 → 详情页聚合行缺项、字数显示 `0.0万字`、免费章被误加 🔒（松鹤庭沐等源实测）。现按上游 `AnalyzeRule.getString` 语义分派 JSONPath/XPath/CSS/正则/JS（`@@` 与 `@css:`/`@xpath:`/`@json:`/`@regex:`/`@js:` 前缀、无前缀按形态 + 内容类型识别），HTML+CSS 既有路径行为不变；`getElement(s)`/`getStrings` 同族一并对齐
  - **规则引擎元素路径模板段**：`get_elements` 链的 Extract 段同步模板语义（上一批只修了字符串路径）
  - **非法正则回退口径三处统一**（parser 对齐上游与 FFI：replaceFirst 返回替换串、全文替换降级为字面替换）
  - **`{{js表达式}}` + 选择器后缀/组合符按上游收窄**（G11 收窄为「整规则恰为单个 JS 表达式跨度且无包装」）；逐条核对 526 源语料 52 条候选，其中 5 条真实 `tocUrl` 规则由「取空」变为正确 URL（清风小说网/对小说-夜明空/书文小说/笔趣阁/PO18）
  - **模板命中时 JS 表达式参数不再重复执行**（副作用型参数 `java.put`/`toast` 翻倍隐患）
  - **元素解析器补 `book` 绑定**：`ruleToc.chapterName` 里的 `book.name` 可用（民间故事/涨姿势/华语中文/月亮小说/可阅文学 5 源章节名恢复）
- [Rust] ~~换源后书籍 URL 改为新源地址（对齐原版 `SearchBook.toBook()`）~~ **该改动已在 [2.0.286] 回退**（实机回归：主键迁移后所有换源入口报「书籍不存在」），详见下一条
- [Tool] 测试卫生：`legado-book` TXT 搜索测试的临时文件名仅用时间戳，Windows 下 SystemTime 粒度约毫秒级会撞名，导致并行执行时共用文件（`test_search_case_insensitive` 偶发「应为 2 处实得 1 处」）；改为时间戳 + 进程内原子序号

### Test
- `cargo test --workspace` **exit 0 零失败**（19 组 test result 全 ok：legado-parser 282、legado-ffi 358、legado-js 236（quickjs 531）、legado-core 792、legado-db 302、legado-book 150 等）
- `cargo clippy --workspace -- -D warnings` exit 0；`cargo fmt --check` 0 处
- 真实源 fixture 断言：`kind` 段不再 `0.0万字`、免费章 0/712 带 🔒、换源后书籍挂**新键**且旧键无残留（`test_switch_uses_parsed_toc_url_and_preserves_parsed_values`）

### Real device
- 2.0.285+286 release APK 装 MuMu（192.168.1.19:5555）：书籍「斗罗大陆」换源切到「🏷松鹤庭沐·言璃」后，详情页聚合行恢复完整 **`9.9分 · 轻小说 · 712章 · 298.6万字 · 已完结`** + 标签行 `影视原著、学院流、穿越、升级流、热血`，**免费章不再带 🔒**（此前为 `分 · ·章 · 0.0万字 · 连载中`；截图 `docs/parity_shots/source_switch_fix_20260918/05_detail_fields_ok.png`）
- 落库校验（当时的改键版本）：书籍键迁移到新源地址、`tocUrl` 完整保留 bookId、712 章挂新键、旧键零残留；**再次进入详情页后 `tocUrl` 不再被覆盖**——该版本因下述回归已回退

- Contributor: 全栈工程师子代理

## [2.0.284] - 2026-09-18

### Fixed
- [Rust] 修复「换源」切换到部分书源失败（界面提示「新书源未解析到任何章节」）：`ruleSearch.bookUrl` 采用多行 JS 链写法（`$.bid` ⏎ `<js>1100000000+parseInt(result)</js>` ⏎ `…intro-info?bookid={{result}}`）的书源，链末段（非 JS 段）被当作 CSS 选择器去解析上一段的文本，整条规则取空 → `web_book.rs` 空值回退成**搜索页地址**作为 bookUrl → 详情解析全空 → `tocUrl` 的 `{{$.resourceID}}` 为空 → 请求 `…all-chapter?bookId=` 返回 422 无 `rows` → 0 章。根因：规则引擎缺上游 `AnalyzeRule.SourceRule` 的模板语义。修复（版本 2.0.283+284 → 2.0.284+285）：
  - 链内 `{{…}}` 段与单步模板改为**按模板回填后字面返回**（规则型参数 `@`/`$.`/`$[`/`//` 走单源规则，其余按 JS 表达式以**前序步结果**为 `result` 求值；回填失败即该参数为空串，对齐上游 `null -> Unit`），不再当选择器解析；含 `@js:`/`<js>` 的规则不进模板分支（JS 体内可合法出现 `{{…}}`）；单跨度 JS 表达式参数保留既有 G11「展开后按选择器/组合求值」语义
  - `{{…}}` 参数内的 `##` 不再被顶层 `##` 拆分截断（改为 span 感知拆分），修复标签字段落库成 `{{$.categoryInfoV4` 之类半截串（9 个书源）
  - `##re##rep###`（replaceFirst）对齐上游 `matcher.group(0).replaceFirst` 语义，且**无匹配返回空串**（上游与 FFI 入口三处口径统一）
  - 模板段内单花括号 `{$.x}` 复用 `process_inner_rules` 回填，避免 `{{$.a}}/{$.b}` 混合模板残留字面量
  - **第二层根因（独立缺陷）**：修复换源目录抓取的**参数语义错位**——`get_chapters_with_vars` 把「已解析好的真实目录页 URL」当详情页 URL 使用 → 在目录响应体上跑 `ruleBookInfo.init` 取空 → 重推 `tocUrl` 得 `…?bookId=`（空 bookId）→ 服务端 `ret:422` 无 `rows` → 0 章 → 报「新书源未解析到任何章节」。改为直接抓取传入的目录页并套 `ruleToc`（对齐原版 `getChapterListAwait`）；换源失败文案补上目录地址便于排查。该缺陷对换源链路 100% 触发，仅「tocUrl 规则依赖详情响应体」的源会真正失败
  - 目录直取路径补齐 **`loginCheckJs` 检测**（对齐上游 `WebBook.kt:346-352` 的「取响应→登录检测→解析」顺序，避免 23 个配置了登录检测的源把「需要登录」误报成「未解析到章节」）与 **`book.name` 书名 hint**（对齐上游 `BookChapterList.kt:196`，避免 4 个 `ruleToc.chapterList` 依赖 `book.name` 的源章节标题退化）；trait 采用加法式默认方法，既有签名与各 Mock 零改动

### Test
- `cargo test -p legado-parser` 275 通过（新增 10+ 条 `{{…}}` 模板回归测试）；`cargo test -p legado-ffi` 356 通过 / 19 ignored（新增 `toc_no_rederive_tests` 锁「目录抓取不得把入参当详情页」）；`cargo test -p legado-core` 792 通过；`cargo test --workspace` **exit 0 零失败**；`cargo clippy -p legado-parser --all-targets` 零告警
- 真实书源 fixture（quickjs）：bookUrl 链由「空串」→ `…intro-info?bookid=1100468021`；`get_chapters_with_vars` 章节数由 **0 → 712**

### Real device
- 2.0.284+285 release APK 装 MuMu（192.168.1.19:5555）：书籍「斗罗大陆」换源切换到「🏷松鹤庭沐·言璃」**成功**——详情页「来源」变更、「共 712 章」、最新章刷新（截图 `docs/parity_shots/songhe_template_fix_20260917/v3_06_t8.png`）；落库校验 `originName=🏷松鹤庭沐·言璃`、章节表 712 行
- 已知残留（登记 `docs/REFACTORING_ACTIVE_PLAN.md` P2-6）：换源后书籍 `bookUrl` 未随新源更新（与上游 `toBook()` 差异）→ 落库 `tocUrl` 丢 bookId；以及该源详情字段的 `java.getString` 绑定层 JSONPath 缺口（kind/字数/章名锁标记显示不全）

### Review
- 跨模块改动（legado-parser + legado-ffi）经 code-reviewer 两轮审查：首轮判定不可合入（`@js:` 体内含模板导致 JS 不执行 52 条规则/26 源；「选择器 + 跨度外 `##`」被误判为模板 21 条/20 源、其中 10 条为正文），按审查建议收敛后复审
- 遗留项登记 `docs/REFACTORING_ACTIVE_PLAN.md` P2-6（`get_elements` 链内模板段未同步 / 非法正则回退口径三处不齐 / `{{js}}`+选择器后缀的组合语义取舍需单独评审）

- Contributor: 全栈工程师子代理

## [2.0.283] - 2026-09-17

### Fixed
- [UI] 详情页四按钮横向拓宽 + 在读/最新/共N章行字号对齐参考 08（台账 08「用户实测反馈批七 0917」H1-H4，版本 2.0.282+283 → 2.0.283+284，基准 `ref_20260914/08_book_info.png`，PIL 量化 1080px=360dp@3x）：
  - **H1 四按钮横向拓宽**：参考量化 单卡 229px≈76dp 宽 × 207px≈69dp 高、圆角 44.75px≈15dp（R/w=0.196）、卡间距 24-25px≈8dp、左右页边距 39px≈13dp、横向跨度 989px≈329.7dp（近卡片横排）→ 布局改 **Row + 4×Expanded 等分**（卡宽 (360-26-30)/4=76dp、间距 10dp、边距 13dp、上边距 12dp），卡高 69dp 不变、圆角 10→15dp、图标 20dp + 间距 10dp + 标签 11sp 显式（随卡宽保持可读）；横向跨度 1002px vs 参考 989px（+1.3%）
  - **H2 在读行字号+加粗**：参考在读行墨高 46px/字宽 45px≈16sp 且字框 fill 0.30-0.52（粗体）→「在读·第X章 章节名」13sp 常规 → **16sp w700**
  - **H3 最新行字号**：参考最新行墨高 40px/字宽 38px≈13sp 常规字重 → 13sp 维持、字重显式常规（w400）
  - **H4 共N章行**：参考共N章行墨高 35px/字宽 33px≈12sp → 13sp → **12sp**（w600 强调与状态词绿色 0xFF4CAF50 保留，着色已一致）

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1468）

### Real device
- 2.0.283+284 release APK 装 MuMu（192.168.1.19:5555），versionName=2.0.283（versionCode=284）校验通过；`scripts/parity_capture_ours.py --only 08 --out docs/parity_shots/ours_2.0.283` OK（`08_book_info.png` 1/1）；**像素断言双 PASS**：四按钮横向跨度 997px vs 参考同位 976px（偏差 2.15% ≤6%；卡行带 y1113-1319 vs 参考 y1119-1324，带高 206px≈69dp 一致）；在读行墨迹高度 46px vs 参考同位 46px（比值 100% ≥90%）；另测 最新行 37px（参考 39px，同档 13sp）、共N章行「共」字宽 33px（参考 37px，12sp 档）

- Contributor: 全栈工程师子代理

## [2.0.282] - 2026-09-17

### Fixed
- [UI] 详情页 hero 背景透明化对齐参考 08（台账 08「用户实测反馈批六 0917」G1-G5，版本 2.0.281+282 → 2.0.282+283，基准 `ref_20260914/08_book_info.png`）：
  - **G1 hero 渐变渐隐**：hero 背景层渐变由 6 档（0/0.2/0.4/0.6/0.8/1.0）改 **5 档 0/0.2/0.35/0.48/1.0**——≤35% 封面完整（仅 seed 10-18% 微染），35%→48% `cs.surface` α0→α1 渐隐至全覆盖，48% 以下为**纯 surface 底色区**（信息 chips/四按钮/在读·最新/标签/简介不再透封面），对齐 REF「模糊封面仅占顶部约 45%（y≈870/1920 完全消失）→ 底部渐隐融入底色」；明暗双态经 `cs.surface` 槽位天然生效（暗态渐隐入暗 surface）
  - **G2 内容区落底色**：随 G1 结构性达成——自信息 chips 起内容全部位于 48% 视口高度之下，backdrop 已是纯 `cs.surface` 底色区、图片不再透出；简介面板与 `SliverFillRemaining` 原即不透明 `cs.surface`，无代码改动
  - **G3 hero 文字深色高对比**：三行文字（书名 24sp w700/作者/来源 11sp）保持完全不透明 `cs.onSurface`（亮态即纯黑书名，对齐 REF 实测墨 L≤27）；深阴影升为主保障 `0x99000000` blur6 off(0,1.5)，白色柔光降权至 `0x40FFFFFF` blur12 仅作暗 hero/暗色主题保险，避免强白晕冲淡深色高对比观感
  - **G4 封面卡阴影+浅描边**：保留 `elevation 8` 阴影，补 1px `cs.outlineVariant` 浅描边（DecoratedBox），浮起观感对齐参考（REF 卡缘 1-2px 浅灰线）
  - **G5 chips/四按钮复核**：四张 52×69 卡已是 `cs.surfaceContainerLow` + 图标 `cs.primary` + 标签 `cs.onSurface` 底色区常规样式，复核无误、无改动

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1468）

### Real device
- 2.0.282+283 release APK 装 MuMu（192.168.1.19:5555），versionName=2.0.282（versionCode=283）校验通过；`scripts/parity_capture_ours.py --only 08 --out docs/parity_shots/ours_2.0.282` OK（`08_book_info.png` + `_dump_08_final.xml` 1/1）；**像素断言全 PASS**：y≈55% 背景（左缘列 x4-30）L 247.0-251.0（均值 249.0）= 纯 surface 基色 (249,250,239)，偏差 0（判据 ±6）；与 y≈20% hero 图（L 均值 99.0）ΔL=150 ≥ 20（REF 同位 ΔL≈140，渐隐形状一致）；hero 三行深色墨迹：书名 y635-702 墨中位 L27/最小 L1（对局部背景 ΔL62≥60）、作者 y743-786 墨 L27（ΔL105）、来源 y824-854 墨 L4（ΔL180）——书名墨级与 REF（中位 L25/最小 L0）一致，深色高对比达标；G1 暗态经 `cs.surface` 槽位结构性满足（暗色主题渐隐入暗 surface），本次真机验证为亮态

- Contributor: 全栈工程师子代理

## [2.0.281] - 2026-09-17

### Fixed
- [UI] 详情页字体/字号/对比度对齐参考 08（台账 08「用户实测反馈批五 0917」F1/F2，版本 2.0.280+281 → 2.0.281+282，基准 `ref_20260914/08_book_info.png`）：
  - **F1【P1·首要】文字对比度——部分文字不可见**：根因 = 2.0.280 的 `onSurfaceVariant`（亮色主题 L≈71）在任何 hero 图上对比度不足（实测旧截图：作者行 wcag 2.15/ΔL54、来源行 wcag 1.65/ΔL41、四按钮标签 wcag 2.76/ΔL57、在读行 wcag 2.89、最新行 wcag 3.01、共N章 wcag 3.33，均 <4.5 近乎不可见）。修：hero 区六行（书名/作者/来源/聚合行/在读行/最新行）文字色全部改**完全不透明 `cs.onSurface` 高对比色**，并加强 `heroTextShadows` 双阴影兜底（深色投影 `0x8C000000` blur6 off(0,1.5) + 白色柔光 `0xB3FFFFFF` blur14）——任何 hero 图上至少一条阴影路径保证可读；四按钮标签 `onSurfaceVariant`→`onSurface`
  - **F2 字号阶梯量化对齐**（参考图 1080px=360dp@3x，sp=墨高px÷3，CJK 墨高≈0.85-0.9em 标定）：书名 22→**24sp w700**（我方 68px vs 参考 70px≈23.3sp）、作者 13→**14sp**（43px vs 41px≈13.7sp）、来源 12→**11sp**（30px vs 32px≈10.7sp，图标 16→14）、聚合行 12→**13sp**（37px vs 38px≈12.7sp）、在读行 12→**13sp**（37px vs 39px≈13sp）、最新行 12→**13sp**（37px vs 39px≈13sp）、四按钮标签 12→**11sp**（31px vs 34px≈11.3sp）、共N章 16→**13sp w600**（34px vs 39px≈13sp）；改后截图像素实测各级墨高与参考偏差 ≤5px（≈1.7sp），七档全部落位

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1468）

### Real device
- 2.0.281+282 release APK 装 MuMu（192.168.1.19:5555），versionName=2.0.281（versionCode=282）校验通过；`scripts/parity_capture_ours.py --only 08 --out docs/parity_shots/ours_2.0.281` OK（`08_book_info.png` + `_dump_08_final.xml` 1/1）；**八区文字对比度像素断言全 PASS**（判据 wcag≥4.5 或 ΔL≥60）：hero 三行（bg L107-117 深底，ink L27）书名 y635-702 ΔL81、作者 y743-786 ΔL80、来源 y824-854 ΔL90（ΔL 判据达标，叠加白柔光兜底）；panel 五行（ink L27）聚合行 y1032-1068 bg L188 wcag 6.03 ΔL161、四按钮标签 y1243-1273 bg L242 wcag 7.72 ΔL215（修复前 2.76）、在读行 y1350-1386 bg L236 wcag 7.53 ΔL209（修复前 2.89）、最新行 y1425-1461 bg L246 wcag 7.84 ΔL219（修复前 3.01）、共N章 y1520-1553 bg L248 wcag 7.91 ΔL221（修复前 3.33）

- Contributor: 全栈工程师子代理

## [2.0.280] - 2026-09-17

### Fixed
- [UI] 详情页分类标签竖排根因定位 + 用户实测反馈批四四项（台账 08「用户实测反馈批四 0917」U13/E2 + E1/E3/E4/E5，版本 2.0.279+280 → 2.0.280+281，基准 `ref_20260914/08_book_info.png`）：
  - **U13/E2【P1】标签竖排根因 = 书源数据差异（非代码回归，勿造占位）**：2.0.279 证据「奇幻/武侠/历史/都市…逐行竖排」经探针 APK 真机测量（面板入向约束 maxW=328.0dp 全宽、无挤压；kind 实测 0 项）+ 真机 DB 取证（`legado.db` books 表真值）定案：测试书（📂瀚海书阁《斗罗大陆》）`kind = '{{$.categoryInfoV4'`（JS 规则模板残留，U4 守卫 `hasUnrenderedTemplate` 按设计拒收 → kinds=0 → 🏷️ 标签行按缺省省略规则正确不渲染）；**9 个标签词以 `\n` 分隔混入 intro 字段**（`奇幻\n武侠\n历史\n都市\n科幻\n悬疑\n游戏\n其他\n言情\n本站提供…`）——截图中的竖排短行 = 简介正文 Text 渲染这些 \n 分隔行（12sp、每行 ~90px @3x，x≈50-140），非标签行 widget 布局 bug。标签行 widget 自 U9 起即「🏷️ 前缀 + 逗号连排 Wrap 横向自动换行」形态（本批补回归测试：干净 kind 数据下 9 标签同行 |Δy|≤2、不同行数 ≤2、无数据丢失）
  - **E1【P2】信息聚合行并入类型**：聚合行格式对齐参考「评分 · 类型 · N章 · N字 · 完结态」——评分（`^\d+(\.\d+)?分$` kind 项）、类型（首个非评分/非完结态/非文件大小的 kind 项）、完结态（`^(已完结|完本|已完本|连载中|暂停更新|停更|断更)$` kind 项）；缺项省略、整行无数据不渲染。当前设备「51章 · 142.20万字」= 书源无评分/类型/完结态数据时缺项不显（正确降级，非缺陷）
  - **E5【P2】最新行补章节名**：部分书源 `latestChapterTitle` 返回状态词（本测试书源实为「已完结」而非章节标题）→ 回落目录末章真实标题（与在读行同源 `chapters` 列表），状态词隐含完结追加「（全书完）」→「最新·第51章 第十一章 小舞原来你真的是个兔子(三)（全书完）」；目录无标题数据时保持现状（不丢行、不造占位）
  - **E3/E4【P2】核实结论**：🏷️ 标签行「未见」= kind 为坏模板被 U4 拒收 + 标签词混入 intro（数据差异登记，勿造占位——不从 intro 数据伪造标签行）；简介块正常渲染（a11y 节点 [48,1635][1032,1920]，350 字全量正文含 9 标签词均在，分组/目录行居后）——用户截图「未见」系简介块位于视口下方（需滚动），非渲染缺陷
- 数据差异登记（不改代码、不造占位）：瀚海书阁书源 kind 字段返回 JS 规则模板残留 `{{$.categoryInfoV4`（未闭合形，Rust `normalize_js_rule_result` + Dart `hasUnrenderedTemplate` 双层守卫按设计拒收，DB 缓存旧数据同守卫）；9 个分类标签词以 `\n` 分隔混入 intro 字段（书源 JS 规则将分类写入简介）——修复应在书源规则侧，渲染层维持缺省省略

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1468，含新增 U13 回归测试「标签行横排连排：标签同行非竖排且无数据丢失」与 E5 测试「最新行：状态词回落目录末章标题并追加（全书完）」；E1 类型项由既有版块顺序测试「9.9分 · 轻小说 · 51章」断言覆盖）

### Real device
- 2.0.280+281 release APK（探针已移除）装 MuMu（192.168.1.19:5555），versionName=2.0.280（versionCode=281）校验通过；`scripts/parity_capture_ours.py --only 08 --out docs/parity_shots/ours_2.0.280` OK（`08_book_info.png` + `_dump_08_final.xml`）；a11y 节点合并（9 标签 + 简介同节点，按任务约定改用截图像素行断言）：聚合行「51章 · 142.20万字」墨迹 y1028-1060 x69-355（E1 缺项不显 ✓）；E5 最新行 a11y「最新·第51章 第十一章 小舞原来你真的是个兔子(三)（全书完）」y1407-1461 ✓；简介区 y1635-1920 五个 2 字短行（y1652/1715/1779/1848/1914，x≈50-140）+ 全宽正文行 = 书源 \n 混排标签渲染现状（与 2.0.279 及探针版逐字节同位，无布局回归）；🏷️ 节点缺席（kind 坏模板被拒收，缺省省略规则正确不渲染）

- Contributor: 全栈工程师子代理

## [2.0.279] - 2026-09-17

### Fixed
- [UI] 书籍详情页版块顺序对齐参考 08（台账 08「用户实测反馈批三 0917」U10-U12，版本 2.0.278+279 → 2.0.279+280，基准 `ref_20260914/08_book_info.png`）。根因 = 上批 U5/U9 分别补入聚合行与在读/最新块后，各自就近插入头部/面板，版块纵向顺序与参考错位（在读/最新沉于四按钮之上、标签行沉底、分组/目录行居前）。修：`book_info_screen_builders.part.dart` 按参考重排 CustomScrollView sliver 序——①信息聚合行（并入信息行、仅现一次，U5 能力保留）→ ②四按钮卡（已在书架/查看目录/书源/阅读记录）→ ③在读/最新/共N章三行块（U9 能力保留，移至按钮下方）→ ④标签行（🏷️ 前缀逗号连排，移入信息面板首行：在读块之后、简介之前）→ ⑤简介 → ⑥分组/目录行（upstream 能力保留，后移至简介之后）；头部收敛为两栏（封面+信息列），色彩仍走 `colorScheme` 槽位无硬编码

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1466，含新增版块顺序 widget 测试「四按钮<在读/最新<标签<简介<分组/目录行」按 y 坐标逐项断言）

### Real device
- 2.0.279+280 release APK 装 MuMu（192.168.1.19:5555），versionName=2.0.279（versionCode=280）校验通过；`scripts/parity_capture_ours.py --only 08 --out docs/parity_shots/ours_2.0.279` OK（`08_book_info.png`）；uiautomator dump 顺序断言（content-desc 节点顶边 y，证据 `_dump_08_u10.xml`）：①聚合行 y=1020 < **②四按钮「查看目录」卡 y=1110 < ③在读 y=1335 < 最新 y=1407 < 共N章 y=1497 < ④标签行 y=1635**（满足参考序：四按钮 y < 在读 y < 标签 y；⑤简介/⑥分组目录行随节点居后）

- Contributor: 全栈工程师子代理

## [2.0.278] - 2026-09-17

### Fixed
- [UI] 书籍详情页用户实测反馈批二四项修复（台账 08「用户实测反馈批二 0917」U6-U9，版本 2.0.277+278 → 2.0.278+279，基准 `ref_20260914/08_book_info.png`）：
  - **U7【P1·先调查】信息聚合行缺项根因 + 进入刷新对齐**：链路对比——原版 `BookInfoViewModel.upBook()` 进入即先 `bookData.postValue(DB缓存)` 上屏，`tocUrl 为空 && 非本地` 时 `loadBookInfo`（`WebBook.getBookInfo` → `BookInfo.analyzeBookInfo` 覆盖式写 name/author/kind(逗号连)/wordCount/latestChapterTitle/coverUrl/tocUrl），菜单刷新恒 `loadBookInfo`；我方旧实现详情页进入**从不调用 bookInfo 刷新**（`_mergeWebInfo` 仅补空不覆盖，in-shelf 且章节已缓存时门控 `chapters.isEmpty` 不成立直接跳过）→ 评分/分类/完结态/字数停留 DB 陈旧值。修：`book_info_screen_load.part.dart` 新增「章节已缓存的在线书」后台 `webbookInfo` 刷新分支——更新式合并（`refresh:true`：刷新非空值覆盖陈旧字段，空值不覆盖）+ in-shelf `api.updateBook` 落库 + 不阻塞首屏（DB 缓存已上屏，后台完成后 setState）；`_mergeWebInfo` 增 `refresh` 更新式合并分支
  - **U6【P1】标题块透明化**：书名/作者/书源背后浅底卡（上批 U3 折衷产物 `surface.withValues(alpha:0.5)` 圆角 10 Container）移除，信息列透明直排于 hero；对比度改由双（深 `0x59000000` blur4 + 浅 `0x80FFFFFF` blur8）柔阴影 `heroTextShadows` 保证（深色阴影压亮底、浅色光晕托暗底，任意封面 hero 下可读；参考 08 标题区 PIL 实测背景=hero 透传 117-176 渐变非卡底）
  - **U9【P1】在读/最新章节块 + 标签行形态**：头部补「在读·第X章 章节名」（阅读记录 `durChapterIndex` 1 基→实际章节标题，目录未载/越界降级不带章名）与「最新·第N章 章节名（全书完）」（info `latestChapterTitle` + `totalChapterNum` 优先，完结态命中 已完结/完本/已完本 追加后缀；缺数据不渲染），置于「共 N 章」行上方；标签行由逐 tag 竖排 chip 改「🏷️ 前缀 + 逗号连排单/多行」纯文本内联（超宽自动换行，逐 tag 点击搜索/长按 JS 回调行为不变；SDK 无 TapAndHoldGestureRecognizer，用 Wrap+逐 tag GestureDetector 等价实现）
  - **U8【P2】4 图标卡圆角收敛**：ref 08 PIL 实测卡 226×209px，左上角最小二乘拟合 R≈45px（radius/卡宽 ≈0.20）；我方 52dp 卡（156×208px）圆角 12→10dp（30px，R/W=0.192，与参考差 4%）

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1465）

### Real device
- 2.0.278+279 release APK 装 MuMu（192.168.1.19:5555），versionName=2.0.278 校验通过；`scripts/parity_capture_ours.py --only 08 --out docs/parity_shots/ours_2.0.278`，像素断言：①U6 标题块区 x=700 纵扫 y280-620 RGB≈65-75 平滑 hero 渐变、无浅色卡带（透传）②U8 图标卡圆角实测 30/156=0.192≈ref 0.20 ③U9 dump 命中「在读·第1章 引子 穿越的唐家三少」「最新·第51章 已完结」「共 51 章｜已读」「51章 · 142.20万字」（书源无 kind 数据，🏷️ 行按缺省省略规则正确不渲染）

- Contributor: 全栈工程师子代理

## [2.0.277] - 2026-09-17

### Fixed
- [UI] 书籍详情页用户实测反馈批五项修复（台账 08「用户实测反馈批 0917」U1-U5，版本 2.0.276+277 → 2.0.277+278，基准 `ref_20260914/08_book_info.png`）：
  - **U4【P1】模板串复现（双端兜底，修复中发现未闭合第二形态）**：根因 = 第三方书源 JS 规则字符串拼接产物 `{{$.categoryInfoV4}}`（及其被 JS 截断的未闭合形 `{{$.categoryInfoV4`，瀚海书阁 kind 实锤）进入 kind/intro 等字段，R-NaN 清洗未覆盖 `{{…}}`/`{$…}` 形态 → 详情页 chips 行渲染残留。修：① Rust 解析层 `analyze_rule.rs` `normalize_js_rule_result` 拒收模板残留（JSON 数组字面量不整条拒收，交由 `expand_js_json_array_result` 逐元素过滤，单元素残留不致整数组丢有效项）；判据与 Dart 渲染层共享守卫 `meaningful_text_guard.dart` `hasUnrenderedTemplate`（`\{\{|\{\$`，成对与未闭合均命中）同源——出现 `{{` 或 `{$` 即残留；单 `{`、嵌套 JSON 对象（`{"a":{"b":1}}`）不误判，`str::contains` 线性 O(n) 无正则热路径开销。Dart 侧 `isMeaningfulText` 统一过滤详情页 chips/聚合行/分类行与搜索屏渲染层（DB 缓存旧数据兜底）。双端单测覆盖成对/未闭合/合法数据三组判据
  - **U3【P1】封面旁文字**：书名 22sp w700 深色（任务所述 28sp 与参考实测不符，按主指令以参考为准、差异入台账）；作者名改可读灰 + 浅底衬，不再被 hero 模糊背景吞没；位置对齐参考（标题左缘 x=450px）
  - **U2【P2】详情页封面过大**：封面 110×160dp（圆角 r3、左留白 13dp、距右侧文字 17dp）= 330px @480dpi，落于参考 337±12px 带；任务所述「参考 130px / 我方 210px」与 PIL 实测参考 337px（我方 2.0.276 实测 360px）不符，按主指令以参考 337±12px 带断言，差异入台账
  - **U5【P2】信息聚合行缺失**：封面信息区与 4 图标卡片行之间补「评分 · 类型 · 章数 · 字数 · 完结状态」行（· 连接，缺项不显示，`isMeaningfulText` 守卫）；类型 chip 行同源守卫。「暂无章节/目录：加载目录失败」与「瀚海书阁封面图未加载」登记为书源数据问题（非代码修复范围，台账登记）
  - **U1【P2】详情页 ⋮ 更多菜单**：勾选项由前导 ✓ 改**尾部 ✓**（允许更新/删除提醒）；新增「编辑」（→ 编辑书籍信息页）与「阅读记录」（→ 阅读记录页）；项序对齐参考 11 项（编辑/刷新/阅读记录/设置源变量/设置书籍变量/拷贝书籍URL/拷贝目录URL/置顶/允许更新✓/删除提醒✓/清理缓存），我方独有项（设置分组/创建书籍更新任务/缓存下载队列）保留于分隔线后（双基准+红线不删）

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1465，含新增 `meaningful_text_guard_test.dart` 8 项）；`cargo test -p legado-parser` 全过（255，含新增模板残留单测 3 项），workspace 全绿

### Real device
- 2.0.277+278 release APK 装 MuMu（192.168.1.19:5555），versionName=2.0.277 校验通过；`scripts/parity_capture_ours.py --only 08` OK（`docs/parity_shots/ours_2.0.277/08_book_info.png`），菜单展开态 `08b_book_info_menu.png`、封面加载态 `08d_book_info_cover_loaded.png`。uiautomator dump 断言：chips 行无 `{{` 残留（has_template=False）、聚合行「51章 · 142.20万字」在屏、菜单 11 项顺序 + 尾部 ✓ + 编辑/阅读记录命中；PIL 断言：封面盒非白列跨度 x 39..368（宽 330px，落参考 337±12px 带）、标题左缘 x=450（=39 边距+330 封面+51 间隙+30 内边距，几何分解自洽）

- Contributor: 全栈工程师子代理

## [2.0.276] - 2026-09-17

### Fixed
- [UI] 详情页精修尾批四项（台账 08 详情页 D6/D7/D10 修复 + D11 溯源定性，版本 2.0.275+276 → 2.0.276+277，基准 `ref_20260914/08_book_info.png`）：
  - **D6【P2】「共 N 章」行左对齐**：信息流 `Column` 默认 `center` 使标签行/章节统计行各自收缩后居中（2.0.275 实测「共 712 章｜已读」整行居中）→ 外层 `Column` 改 `crossAxisAlignment: CrossAxisAlignment.start`，各子行自带 16dp 左内边距，与封面左缘起排对齐参考
  - **D7【P3】分组文案对齐原版（溯源保留，非多余行）**：原版 `activity_book_info.xml` 确有「分组」行（`tv_group` + strings `group_s`「分组：%s」）与「目录：第X章 · 已读N%」行（`tv_toc` + `toc_s`），均为原版能力 → 行保留；空分组文案由写死「无」改对齐原版 strings：网络书 `no_group`「未分组」、本地书 `local_no_group`「本地未分组」
  - **D10【P3】顶栏三钮改裸图标**：参考 08 顶栏铅笔/分享/⋮ 为 hero 图上的裸图标（无圆形容器底、深色描边），我方原为 tonal 圆钮 → 详情页动作区强制 `TopBarButtonStyle.plain`（复用书架页 plain 机制，仅本详情页）并单独注入 `onSurface` 前景（顶栏透明期 `onPrimary` 近白在浅色 hero 上不可见）；leading 返回钮保留 glass 圆底（参考同）
  - **D11【P3】「⋮ 红点角标」溯源定性——非 Badge，零代码改动**：全库核查 book_info 屏/顶栏按钮体系（`TopBarActionStyler` 5 档色板仅 outlineVariant/surfaceContainer* 中性色）/系统栏服务均无饱和红、`BadgeWidget` 全库未接线。真机像素取证：红区（RGB≈(173,62,67) 深红）位于状态栏+顶栏右上，其色相与同屏封面盒均值（(113,108,107) vs 顶栏带 (120,107,112)）一致 = 测试书红调封面经 edge-to-edge 透明状态栏+透明 SliverAppBar 渗透（原版同款设计：`activity_book_info.xml` `bg_book` 全屏 centerCrop + `vw_bg` #50000000 + `titleBar` 透明背景，`BookInfoActivity.showCover()` 经 `BookCover.loadBlur` 渲染模糊封面至 `bg_book`）；参考版同机各屏顶栏带亦为暖暗色调（(127,92,80)）而非亮底，参考 08 topred=0 仅因其封面非红调。**结论：原版能力（封面色渗透）而非 Badge 误挂，无可移除代码**
  - **屏 11 菜单采集修复（`scripts/parity_capture_ours.py`）**：原 `_to_reader_menu` 盲点一次 READER_CENTER 即结束，2.0.275 真机采成收起态（屏 11 FAIL 保留旧图）→ 改 dump 驱动：先探测菜单是否已在屏（进阅读器后可能已自动展开），否则按探点序列（中心 960 → 下方 1400 → 上方 600，≤3 次）逐点 tap 后 dump 断言菜单特征「退出阅读/全文搜索」，仍未命中打印文本节点供定位

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1457）；`python -m py_compile scripts/parity_capture_ours.py` OK

### Real device
- 2.0.276+277 release APK 装 LDPlayer9（192.168.1.19:5555），versionName=2.0.276 校验通过；`scripts/parity_capture_ours.py --only 08,11` 2/2 屏 OK（`docs/parity_shots/ours_2.0.276/08_book_info.png` + `11_reader_menu.png`，屏 11 菜单为进阅读器后自动在屏，dump 命中「退出阅读」跳过唤出点按）。PIL 程序化断言全过：①D6「共 N 章」行左缘 x≈48px（=16dp，与封面左缘同列，绿状态词「已读」RGB(76,175,80) 在行内 x≈290-420 命中；旧 2.0.275 整行居中实锤改左对齐）②D10 顶栏右区（分享 [828..936] / ⋮ [960..1068]）亮色像素占比 0%、区均 (150,108,113)=hero 封面暖暗渗透，无圆形容器底 ③D11 红区像素色相=封面盒色相（渗透定性见上）④屏 11 dump 命中「退出阅读/全文搜索/自动翻页/目录」全菜单特征

- Contributor: 全栈工程师子代理

## [2.0.275] - 2026-09-17

### Fixed
- [UI] 搜索结果页视觉精修三项（台账 1-7 重开精修，版本 2.0.274+275 → 2.0.275+276，基准 `ref_20260914/07_search_results.png` + 配对图 `pairs_latest/07_search_results_pair.png` 左参考右我方）：
  - **①「结果 N · 进度 x/y」胶囊居中（像素实测存证，零代码改动）**：PIL 实测（1080 基准 480dpi）——我方 done 态胶囊 x 259..820 中心 ≈540（=屏心）、搜索中态 07b 灰带 x 261..818 中心 539（偏 1px）；参考胶囊中心 ≈531-534。任务所述「偏右（实测中心≈屏宽 76%）」经像素核验为胶囊**右缘**（820/1080=75.9%），中心本已在屏心，≤40px 断言直接通过。代码本已 `Center` 包裹（`search_screen.dart`），不改码，本行即存证。加载中左上浮动 x/y 进度卡为原版行为（`_buildStopFab`），未触碰
  - **②结果项封面 80x110 → 74x104（对齐参考 5:7）**：参考基准图封面实测 **220x311px**（=≈73.3x103.7dp @480dpi，比例 5:7），我方 80x110（=240x330px）偏大 ~9%；`_buildResultItem` 封面改 74x104（=222x312px）对齐参考，圆角 10 不变，`BookCover` 占位框随 width/height 自动缩放
  - **③顶栏圆形动作钮底色槽位 → 中性容器（同因同改，全站）**：根因 = `top_bar_button.dart` 三处 tonal 槽位（`TopBarActionStyler._mergeDecoration`/`_ActionSlot`/`TopBarButton`）用 `secondaryContainer`+`onSecondaryContainer`（带主题色相，当前玫瑰色板下为粉色 [255,218,214]），参考顶栏圆钮为中性灰容器（≈[236,238,244]，`surfaceContainerHigh` 档）。修：三处 tonal 底改 `cs.surfaceContainerHigh` + 前景 `cs.onSurfaceVariant`（glass/liquidGlass 本为中性 `surfaceContainerHighest` α0.5 不动）。**激活/选中态保留主题色区分状态**：搜索页 `_circleAction` active=primary/onPrimary 不变，非激活底由 `surfaceContainerHighest` 对齐至同槽位 `surfaceContainerHigh`+`onSurfaceVariant`。所有屏顶栏（含返回钮）经 `TopBarActionStyler`/`LegadoAppBar` 统一着色 → 全站同因同改一次生效（书架/发现/我的/设置等同类圆钮同步），台账登记「同因同改」不再逐屏枚举。单测 `top_bar_button_test.dart` tonal 断言改 `surfaceContainerHigh`
  - **断言口径校准（如实登记）**：任务指定断言「封面宽 96-108px」按 1080 截图 px 计即 32-36dp，与参考实测封面宽 220px（73.3dp）**物理不可同时满足**（96-108px 区间比参考更小，与「缩至参考尺寸」主指令冲突）；按主指令以参考带 210-234px 断言，冲突留待用户复核

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1457，tonal 中性槽位单测随断言更新）

### Real device
- 2.0.275+276 release APK 装 MuMu x86_64（192.168.1.19:5555），versionName=2.0.275 校验通过；`scripts/parity_capture_ours.py --only 07 --out docs/parity_shots/ours_2.0.275` 2/2 屏 OK（`07_search_results.png` + `07b_search_results_loading.png`）。PIL 程序化断言全过：①胶囊 done 态 x 259..821（中心 **540.0px，距屏心 0.0px**，≤40 通过）、搜索中态 x 259..821 中心 540.0 同过（「偏右 76%」右缘误读实锤）；②封面 bbox **222x312px（=74.0x104.0dp，比例 0.712≈5:7）**，宽在参考带 210-234px 内（任务 96-108px 断言带与参考实测 220px 冲突，按主指令从参考带，已如实登记）；③顶栏圆钮槽：新图四槽全部中性（⚙ 槽左上角 rgb **[232,233,222]** surfaceContainerHigh 类 / 返回钮 [117,120,109]，最大通道差 ≤11），旧 2.0.273 同位置对照 [255,218,214] 粉（secondaryContainer 玫瑰）/ 返回钮 [122,65,65]（通道差 57）——粉色槽位实锤改中性，激活态保留主题色规则不变。截图目检：本环境无图像通道，三项均以像素断言闭环，并排目视留待视觉通道恢复后复核

- Contributor: 全栈工程师子代理

## [2.0.274] - 2026-09-17

### Fixed
- [UI] 台账 4-1 TXT 目录规则页七项修复（对齐 `ref_batch4/01_txt_toc_rule.png`）+ 批 1 `10_reader` 两次误采书架根因修复，版本 2.0.273+274 → 2.0.274+275：
  - **TXT 目录规则页七项（台账 4-1 ①-⑦ 全闭环）**：①标题层级：顶栏内居中标题→左对齐大标题（复用 `LegadoTabRootHeaderSliver(large: true)` 152dp 可折叠 + 动作独立行；该 sliver 新增可选 `leading` 参数保留 push 子页返回钮，经 `TopBarActionStyler` 与 `LegadoAppBar` 同口径着色）②新建入口：顶栏圆形 + 钮→右下 + `FloatingActionButton`（着色走 `floatingActionButtonTheme` 主题槽位 primaryContainer/primary，随调色板切换，非硬编码黄色）③卡片动作集：「测试/删除」文字钮→图标化（铅笔=编辑/垃圾桶=删除/播放=测试，图标 16+label 标签，行尾 Switch 保留）④副标题语义：完整正则源码→规则 `example` 示例文本（内置默认 26 条全带非空 example，如「第一章 假装…」；**取舍**：example 为空回退「正则:」+截断正则（>40 字加 …），保留可辨识性不静默留白）⑤卡片形态：连体紧凑→独立分体卡（Card 圆角 14/水平 16 垂直 6 margin=12px 间距/内 padding 12）⑥移除「已禁用」灰 chip（状态由行尾 Switch 表达，与参考一致）⑦顶栏 ?/↺ 两直钮：grep 原版 `app/src/main/res/menu/txt_toc_rule.xml` 证实**非原版能力**（仅 `menu_add` always，import_default/help/import_local/onLine/qr 全 never 走 ⋮ 溢出）→移除直钮，能力保留入 ⋮ `PopupMenuButton`（导入默认/帮助，对齐 `dict_rule_screen.dart` 既有模式）
  - **`10_reader` 误采书架根因修复（`scripts/parity_capture_ours.py`）**：旧固定坐标 `CARD_BOOK=(279,1208)` 为 2.0.260 实测，2.0.274 书架布局位移后书卡实位于 bounds[66,974,342,1094]（中心 204,1034），旧坐标落卡外空白→点按不跳转，最终停在书架（两次误采根因；旧断言 `("唐门","斗罗大陆","唐三")` OR 过宽，书架书卡「斗罗大陆」同词命中未拦截）。修复：`nav_10` 改书架 dump 定位书卡（desc「斗罗大陆」中心，未命中回退更新后的 `CARD_BOOK`）+ 去除误接的详情页「查看目录/首章」两连击（书卡=「继续阅读」直达阅读器，两击在阅读器内属无效点击且可能切换菜单态）；进入阅读器前 `_assert_in_reader` 断言（正文 content-desc 特征「唐三/斗罗大陆」命中 且 负向「书架/查看目录/书签」零命中——页码 N/M 与全局页胶囊默认不渲染 pageChrome 0 档+showControls=false 故不作特征），失败 raise → `run_screen` 记 FAIL 不落盘（保留旧图不覆盖）；屏 10 登记同步收紧为 `READER_BODY_KWS`+`READER_NEG_KWS`；SCREENS_B4 01 断言词随新 UI 刷新（「导入默认/添加规则」已移入 ⋮/FAB 不再进默认 dump，主特征改「TXT 目录规则/暂无目录规则/正则:」+AND「目录规则/TXT」）

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1457）；`python -m py_compile scripts/parity_capture_ours.py` OK

### Real device
- 2.0.274+275 release APK 装 MuMu x86_64（192.168.1.19:5555），versionName=2.0.274 校验通过；`scripts/parity_capture_ours.py --only 10,01_txt_toc_rule` 2/2 屏 OK，截图 `docs/parity_shots/ours_2.0.274/{10_reader,01_txt_toc_rule}.png`（10_reader：书卡 dump 命中点 (204,1034)，采前断言正文「斗罗大陆」命中/负向 0；01_txt_toc_rule：采后断言「TXT 目录规则/正则:」命中、负向 0）。像素核验（PIL）：10_reader 中央墨迹 10.7%（正文密集）+FAB 区 0.0%（阅读器无 FAB，与 N2 结论一致）；01_txt_toc_rule FAB 区前景 2.8%（FAB 在位）。并排核图：本环境无图像通道，七项按台账已定稿描述逐项对码验证（dump/像素断言闭环），目视并排比对留待视觉通道恢复后复核

- Contributor: 全栈工程师子代理

## [2.0.273] - 2026-09-17

### Fixed
- [UI] 台账 0917 核图重开两项闭环（R-NaN P1 修复 + R-N2 证据核验保留），版本 2.0.272+273 → 2.0.273+274：
  - **R-NaN 搜索结果「NaN : NaN」/「暂无专辑/暂无简介」占位（P1，数据源清洗 + 渲染守卫双层修复）**：书源 JS 规则求值产出 NaN 数值（如缺失字段 `parseInt`/算术）时引擎字符串化为 `"NaN"`，`normalize_js_rule_result` 原只滤空串/null/undefined 直接放行写进 author/kind/wordCount/intro，JS 侧字符串拼接再产出「NaN : NaN」；`word_count_format` 非数字原样透传使 "NaN" 渲进字数 chip；C1 的 UI 守卫只拦整串精确 "NaN"，拼接形与占位串全部漏判（2.0.272 核图实锤）。修复三层：① `rust/legado-parser/src/analyze_rule.rs` `normalize_js_rule_result` 新增 "NaN" 判据归一为空（引擎出口 NaN 数值与 JS 字符串字面量 "NaN" 不可区分，而作者/分类/字数/简介字段不存在合法 "NaN" 值，一并视为无数据）；② `rust/legado-ffi/src/api/search.rs` `word_count_format` "NaN"（大小写不敏感）返回 None（覆盖搜索解析/webbook 信息/发现页三调用点）；③ `flutter_legado/.../search_screen_builders.part.dart` `_isMeaningfulText` 渲染守卫补全：NaN 拼接形（`_isNanJoined`，按分隔符切段后全部为 NaN 即判脏）+ 第三方书源占位串 `{'暂无专辑','暂无简介'}`（全仓 grep Rust+Dart 证实我方代码无生成处：「暂无专辑」仓库任何代码/数据文件均无来源，「暂无简介」仅见第三方书源 JSON 的 JS 规则回退文案 `ci.description || '暂无简介'` 与原版 strings.xml 详情页专用键——来源不可控，按任务裁决在渲染层过滤并注释，不渲染整行/标签=与空数据同语义，不做 UI 隐藏兜底）。③ 守卫实现缺陷复修（2.0.273 初装真机 dump 实锤「NaN : NaN」仍渲染）：原判据 `v.toUpperCase() == 'NaN'` 恒为 false（`'NaN'.toUpperCase()` 得全大写 `'NAN'`，混合大小写比较永不等），精确 "NaN" 与拼接形双双漏判 → 改与全大写 `'NAN'` 比（`_isMeaningfulText` 与 `_isNanJoined` 两处），独立判据脚本 18 例全过
  - **R-N2 结果页右下 ▶ 按钮（结论修正 → 证据核验保留，零代码改动）**：重查实锤搜索屏唯一播放图标 widget 即 `_buildNextPageFab`（`Symbols.play_arrow_rounded`，tooltip「加载下一页」，调用 `loadNextPage()`），搜索屏**无**音频/朗读/TTS 入口（search_screen* 全文件 grep 验证）。授权证据：① 原版 Compose `SearchScreen.kt:391-401` 页面级 FAB 在「非搜索且 hasMore」态即显示同款 `PlayArrow` 图标（点击 → `SearchIntent.LoadMore` 同关键词续载，搜索中显 `Stop`；旧版 `SearchActivity.searchFinally` 同换 `ic_play_24dp`）——▶ 为原版「继续加载下一页」按钮非播放按钮，原版搜索结果项本身亦无播放钮（与截图核点一致）；② git `71b46ad009` 批次 B G-B-02「FAB 三态（停止/播放/下一页）」已对齐原版并验证；③ CHANGELOG 2.0.272 N2 行已登记「保留勿删」。0917「结论作废」按上述证据翻案，保留；原版可达朗读路径未动

### Test
- `cargo test` 全绿（legado-parser+legado-ffi(quickjs)：421 passed/0 failed，29 ignored 网络 smoke；初跑 `test_shushan_real_toc_repro` 真网 repro 瞬时网络失败，单测重跑通过，与本次改动无关）；`flutter analyze` 无问题（0）；`flutter test` 全过（1457）

### Real device
- 2.0.273+274 装 MuMu x86_64（192.168.1.19:5555），采集脚本版本校验通过（versionName=2.0.273），重采 `docs/parity_shots/ours_2.0.273/07_search_results.png` + `07b_search_results_loading.png`（2026-09-17 07:56 产出）。uiautomator dump（`.tmp/parity_273_07_dump2.xml`）断言：「NaN」命中 **0**（修前同位置 4 处）、`暂无专辑|暂无简介` 命中 **0**、`加载下一页` 命中 **1**（授权 FAB，R-N2 证据保留项）；结果项 content-desc 现渲染 `玄幻/1`、`尧人/玄幻奇幻`、`炒麦片/…` 干净文案。注：截图中保留的右下 ▶ 为原版同款「加载下一页」FAB（`Symbols.play_arrow_rounded`，`SearchScreen.kt:391-401` 对齐，非音频/TTS 入口；原版搜索结果项本身无播放钮，我方一致）

- Contributor: 全栈工程师子代理

## [2.0.272] - 2026-09-17

### Fixed
- [UI] 批 4 长尾 N2/N5/N3 收官（台账「批 4 长尾 N2/N5/N3 收尾」节）：
  - **N5 目录字数胶囊（根因修复，数据层 Rust 全链路）**：`WebChapter` 新增 `word_count: Option<String>`（serde `wordCount`，`rust/legado-core/src/web_book.rs`）；规则源 `webbookChapters` 对每章取 `updateTime` 规则 info 经与原版 `AppPattern.wordCountRegex`（`app/.../AppPattern.kt:24`）逐字一致的等价正则捕获组 1 提取（`rust/legado-ffi/src/api/web_book.rs`，OnceLock 惰性静态 + 单测 `word_count_regex_extraction`）；JS 源 `convert_js_chapters` 读 `wordCount` 键；`refreshToc`（`reader.rs`）转换落库透传。API 契约章节 JSON 新增可选 `wordCount`（无新 FFI 方法，方法表与 contentHash 不变）。Flutter 侧渲染本已就绪（`toc_screen.dart` 章节行「加载字数」开关 + 有值才渲染，对齐原版 `AppConfig.tocCountWords`）
  - **N2 深色圆钮（定位归属，保留勿删）**：07 搜索结果页右下深色圆钮 = 搜索「下一页/停止」FAB（`_buildNextPageFab`，原版能力 `SearchActivity.kt:449 searchFinally`，批次 B G-B-02 已对齐，非未授权新增，红线不触发）；10 阅读器「右下深色圆钮」= 底栏元素误读（无独立浮动圆钮 widget），勿删
  - **N3 详情页封面空白（登记，不加 UI）**：UI 失败静默回落默认封面与原版一致（原版 `activity_book_info.xml:88` 亦回落默认封面且无错误占位/重试 UI，新增即红线）；截图差异根因在数据/加载层瞬时失败（真机 272 已出图证实）
  - **armv7 构建登记（不修）**：`rar 0.4.0`（quickjs 纯 Rust 依赖，`7740ab0997` 引入）32 位 E0277——`nom 7.1.3` `ToUsize for u64` impl 带 `#[cfg(target_pointer_width="64")]`，32 位缺失且 `rar/src/extra_block.rs:32` 以 u64 实参调用 `take`；crates.io 无 0.4.0 之后版本无法升级 → 沿用旧 armeabi-v7a .so（与 CHANGELOG:2774 既有登记及 `requiredAbis=[arm64-v8a,x86_64]` 门禁一致，v7a 不校验）；arm64-v8a/x86_64 .so+.meta 已重建刷新（含 N5，FRB contentHash -734354461 不变）。后续需 32 位真机时对 rar 调用点本地 patch（u64→usize 收窄）单独立批

### Test
- `cargo test` 全绿（legado-ffi 354 passed/0 failed，19 ignored 网络 smoke；新增单测 `word_count_regex_extraction` 覆盖「字数：2510字」/「2510 字」/无字数三例）；`flutter analyze` 无问题（0）；`flutter test` 全过（1457）

### Real device
- release 2.0.272+273 APK（arm64-v8a/x86_64 .so 已含 N5 全链路，`verifyRustFfiLibs` 门禁通过）装 MuMu（192.168.1.19:5555，x86_64），versionName=2.0.272 校验通过；`scripts/parity_capture_ours.py --only 07,08,09` 4/4 屏 OK（07 含 07b 加载态），截图 docs/parity_shots/ours_2.0.272/{07_search_results,07b_search_results_loading,08_book_info,09_toc}.png；程序化像素核验（PIL）：08 封面盒 = 真实封面（mean 104,95,100，灰度占比 0.32%）vs 260 默认灰占位（mean 228,228,228，灰度 28.2%）→ N3 定论为加载/数据层瞬时失败（登记数据层差异，非 UI 缺陷）；07 FAB 盒 260/272 均检出深色圆钮且 272 dump 断言「加载下一页」命中（N2 存证）；09 目录页「加载字数」默认开，测试书《斗罗大陆》章节行未出胶囊——本环境书源章节 info 无字数（提取正则与原版逐字一致，代码层 1:1），属数据可用性差异（ref 机书源含字数、本环境无），登记非代码缺陷；armeabi-v7a 沿用旧 .so（quickjs:false 旧版），MuMu x86_64 与 arm64 真机不受影响

- Contributor: 全栈工程师子代理

## [2.0.271] - 2026-09-17

### Fixed
- [UI] 台账 N4 闭环——设备旧偏好覆盖新默认值（一次性偏好迁移）：C2 批（2.0.262）将阅读器两项默认值改新（R4 顶部「时间/章节名/进度」状态行四开关由默认开改默认关；R5 底栏左侧 tipFooterLeft 由 1=章节名改 7=书名），已安装设备上存量旧值导致新默认永不生效（需手动进设置改）。新增一次性迁移（`ReaderAdvancedConfig.load()` 首读处）：新存储标记键 `settingsMigrated_v271`，标记缺失时执行——状态行四键（`reader_adv_show_battery/show_time/show_progress/show_chapter_name`）存量 == 旧默认 true → 置 false；`tipFooterLeft` 存量 == 旧默认 1 → 置 7；随后置标记（幂等，后续启动不覆盖用户手动修改）；存量值 != 旧默认（用户曾手动改过）→ 不动仅打标记；键缺失（未存过）→ load 缺省即新默认无需写入。用户可见：升级后首次进阅读器自动应用新默认显示，手动改过的设置保持原样

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（新增 `test/unit/reader_pref_migration_test.dart` 迁移单测 5 例：存量=旧默认→迁移为新默认并置标记 / 存量=自定义值→不动仅置标记 / 已置标记→幂等不改写 / 全新安装→新默认生效并置标记 / 重复 load→迁移仅执行一次）

### Real device
- release 2.0.271+272 APK 装 MuMu（192.168.1.19:5555，该设备恰好存有旧值，天然验证环境），versionName=2.0.271 校验通过；冷启进阅读器 → dump/截图断言顶部状态行不出现、底栏左侧显示书名（截图 docs/parity_shots/ours_2.0.271/10_reader.png，`scripts/parity_capture_ours.py --only 10_reader` 采集）；台账 N4 行闭环登记（注「一次性迁移方案」）

- Contributor: 全栈工程师子代理

## [2.0.270] - 2026-09-17

### Fixed
- [UI] 阶段 D 最终对齐：默认主题对齐 kazusa「默认」调色板（目标色值取 kazusa `themeConfig.json` 源码原文，零采样；台账阶段 D 0917 裁决④）：新增第 13 套内置 MD3 调色板 `def`「默认」（完整 47 槽位 Md3Roles）——亮色锚点 primary `#795548` / accent→secondary `#E53935` / backgroundColor→surface `#F5F5F5` / bottomBackground→surfaceContainer `#EEEEEE`；暗色按「黑白」套（`#303030/#E0E0E0/#424242/#424242`）锚点推导：surface `#424242` / surfaceContainerLowest `#343434` / primary `#D9CFCE` / secondary `#E2C7C4` / primaryContainer `#5F443E`；`Md3Palettes` 默认切 `def`（`defaultId='def'`，`all` 列尾追加，`byId` 未知 id 回退 def 语义保留）；`app_theme.dart` light/dark/lightCustom/darkCustom 四处 `Md3Palettes.wh` 引用改 `def`；「纯白」等原 12 套原值全部保留可切换（wh 仍在列首）

### Test
- `flutter analyze` 无问题（0）；`flutter test` 全过（1452 例；回归套件同步：`md3_palette_test.dart` 12→13 套计数/默认 id 断言改 def/新增 def 锚点色值断言/WCAG 全矩阵 13×亮暗，`theme_config_test.dart`+`theme_provider_test.dart`+`settings_service_test.dart` 默认调色板断言 wh→def（「相同值不触发通知」用例同步改设 def），`md3_acceptance_matrix_test.dart` 注释同步；13 色卡网格：4 列布局第 13 格（def）自然换行至第 4 行，无溢出）

### Real device
- release 2.0.270+271 APK 装 MuMu（192.168.1.19:5555，adb D:/leidian/LDPlayer9/adb.exe），versionName=2.0.270 校验通过；`scripts/parity_capture_ours.py --only 01_mine,04_appearance` 2/2 屏 OK，截图 docs/parity_shots/ours_2.0.270/{01_mine,04_appearance}.png（04 手动滚动定位 def 色卡完整入镜，卡片 2px 选中描边目检 #795548）；程序化色值核验（PIL，按通道容差命中像素取均值）：04_appearance 主色 #795548±12 命中 6,817px 均值 **#795549**（偏差 1）、accent #E53935±12 命中 1,084px 均值 **#E53935**（偏差 0）、页面背景 #F5F5F5±6 命中 1,276,749px（66.4%）均值 **#F5F5F4**（偏差 1）、底栏 #EEEEEE±6 均值 #F0F0F0（偏差 2）、暗面色块 #424242±6 命中 18,886px 均值 **#424242**（偏差 0）；01_mine 页面背景 #F5F5F5±6 命中 1,656,085px（80%）均值 **#F2F2F2**（偏差 3，整页含卡片区混色）、底栏 #EEEEEE±6 均值 #F0F0F0（偏差 2）（我的页无大面积主色区域，属既有底栏选中色 onSurface 设计，主色核验以 04 为准）

- Contributor: 全栈工程师子代理

## [2.0.269] - 2026-09-17

### Fixed
- [UI] 外观页移除「外观预览」区块（**用户裁决，B3-C1 同源误判产物**，台账 3-4/A1）：外观页（主题设置页）顶部「外观预览」模型区块（手机模型缩略图 + 当前色卡名 + 联动说明）经用户裁决**一并移除**——溯源确认该区块系 C6 批次低优增强建议产物（引入提交 b03c2ba444「主题设置页新增外观预览模型」2.0.230+231，建议项出自批 D `204dd81e20` C6 行），**无独立用户授权记录**，与「配色轮」（2.0.268 移除的 B3-C1 A2 误判证据产物）同类；删除 `_ThemePreviewCard` 与 `_previewPaletteLabel` 及列表首项挂点，**其余区块不动**（主题设置通用项 / 内置主题 12 色卡网格 / 主题导出导入 / 主题模式入口均保留）

### Test
- `flutter analyze` 无问题；`flutter test` 全过（回归套件同步：`theme_config_test.dart` 删除预览卡相关断言/注释，新增「外观预览」负向断言 `findsNothing`，「导出主题/导入主题/内置主题」正向断言保留）

### Real device
- release 2.0.269+270 APK 装 MuMu（192.168.1.19:5555，adb D:/leidian/LDPlayer9/adb.exe），versionName=2.0.269 校验通过；截图 docs/parity_shots/ours_2.0.269/04_appearance.png（dump 断言：外观页「外观预览」=0 且「内置主题/导出主题」在；截图上部程序化抽验无手机模型剪影特征）

- Contributor: 全栈工程师子代理

## [2.0.268] - 2026-09-17

### Fixed
- [UI] 外观页移除「配色轮」卡（**移除未授权新增区块（用户裁决）**，台账 3-4）：B3-C1（2.0.267）基于误判证据新增的 12 段色环卡（含「长按配色轮自定义配色」提示与长按入口）经用户裁决移除——kazusa 源码 `resources.arsc` 证实无「配色轮/外观预览/内置主题」字样，非参考版能力；删除 `_ColorWheelCard`/`_ColorWheelPainter` 与视图挂点，**既有预设主色调选择器本体（`_showColorPicker`，日/夜主色调色卡行在用）与「主题导出/导入」区保留不动**（kazusa 有同类能力，裁决保留）；「外观预览」卡按裁决**保留待溯源**（C6 批次产物，溯源结论见台账 3-4，未删除）

### Test
- `flutter analyze` 无问题；`flutter test` 全过（回归套件同步：`theme_config_test.dart` 删除配色轮卡断言（`配色轮`/`长按配色轮自定义配色`），改为 `配色轮` 负向断言 `findsNothing`，导出/导入断言保留）

### Real device
- release 2.0.268+269 APK 装 MuMu（192.168.1.19:5555，adb D:/leidian/LDPlayer9/adb.exe），versionName=2.0.268 校验通过；`scripts/parity_capture_ours.py --only 04_appearance` 1/1 屏 OK，截图 docs/parity_shots/ours_2.0.268/04_appearance.png（dump 断言：「配色轮」不在、「主题模式」在/页面特征词命中，其余区块完好）

- Contributor: 全栈工程师子代理

## [2.0.267] - 2026-09-16

### Fixed
- [UI] 外观页分区卡片化（B3-C1 A6 P2，台账 3-4，基准 docs/parity_shots/ref_batch3/04_appearance.png + 04_appearance_dark.png）：页内 8 组（主题引擎/通用/顶栏与布局/底栏与导航/详情与圆角/毛玻璃/自定义主题·白天/自定义主题·夜间）由 IosGroup 扁平行式罗列改**每区独立圆角卡**（surfaceContainer 16dp 卡底 + 行内 4dp surfaceContainerLow 子卡）；12 色卡网格与主题模式区按用户口径不变（勿动）
- [UI] 外观页新增「配色轮」卡（B3-C1 A2 P2）：84dp 环 12 段取当前主题 ColorScheme 色调槽位（primary/secondary/tertiary/error 及其 container + outline/onSurfaceVariant/surface 等，**无硬编码色值**，深浅两态自动渲染）+「长按配色轮自定义配色」提示；长按接现有预设主色调选择器（按当前亮暗态接白天/夜间 primary，真实可用能力）。自由自定义配色（HSV 取色）代码库无实现 → **台账登记能力缺口，不做伪功能**
- [UI] 外观页新增「主题导出/导入」（B3-C1 A3 P2；grep 确认代码库无文件级主题导入导出能力 → **最小实现**）：导出=当前配色（paletteId + themeMode + day/night 各 4 色组）经 FilePicker 存 JSON；导入=JSON 回读经 `ThemeColorsNotifier.applyColors` + `ThemeNotifier`（paletteId/themeMode）一键应用，类型安全解析（int/num 显式转型）+ 失败 toast，全程走主题槽位
- [UI] 外观预览卡（B3-C1 A1 P2）核实为既有实现（C6 批已上线）→ 保留不动
- [台账] M4 标签规则：grep 原版 app/+modules/ 与 flutter_legado/lib 零命中 → 定案=登记缺口不新建；N6 Tt 字体页：docs/ 与 git 历史无用户授权记录 → 登记**待裁决项**（勿删勿改，交主代理裁决）

### Test
- `flutter analyze` 无问题；`flutter test` 全过（1449 例；回归套件同步：`theme_config_test.dart` 两用例因新增配色轮卡+导出/导入区下移 12 色卡网格（惰性列表），断言/点按前先 `dragUntilVisible` 滚到可见区，并新增配色轮卡（含长按提示）与导出/导入行断言）

### Real device
- release 2.0.267+268 APK 装 MuMu（192.168.1.19:5555，adb D:/leidian/LDPlayer9/adb.exe），versionName=2.0.267 校验通过；`scripts/parity_capture_ours.py --only 04_appearance` + `--only 04_appearance_dark` 2/2 屏 OK，截图 docs/parity_shots/ours_2.0.267/{04_appearance,04_appearance_dark}.png（深色像素门控灰度均值 34.2 < 90 ✓ 采集后恢复「跟随系统」）；配色值对齐属阶段 D 本批不做

- Contributor: 全栈工程师子代理

## [2.0.266] - 2026-09-16

### Fixed
- [UI] 书源管理页对齐参考版（B2-C2 2-7 P2，台账 2-7，基准 docs/parity_shots/ref_batch2/08_source_manage.png）：①顶栏补**常显搜索框**（此前仅标题+排序+⋮，与参考「常显搜索框+☰」不符）；②行右控制簇补**勾选圈**——常规行与批量模式行均在开关左侧插入紧凑 Checkbox（批量行此前 leading 位勾选圈移除，与常规行同位右置），保留原有开关与 ⋮ 菜单顺序不变。`source_screen_builders.part.dart` 仅改行渲染（`_buildSourceItem`/`_buildBatchSourceItem`），选中态/批量操作/开关语义不变
- [UI] 书源编辑器表单扁平单列化（B2-C2 2-8 P2，基准 ref_batch2/09_source_editor.png）：移除「字段/规则」Tab 导航与 TabBar 分组卡，改为扁平单列——顶部「设置」段（可收起 CheckboxListTile 组）+ 七段平铺（基本信息/搜索规则/发现规则/详情规则/目录规则/正文规则/段评规则，段标题 13sp primary 加粗），字段定义、顺序与回填/保存链路零行为变更（`source_edit_screen.dart` + `source_edit_screen_builders.part.dart`）
- [UI] 替换净化编辑器扁平化（B2-C2 2-9 P2，基准 ref_batch2/10_replace_rule_edit.png）：表单改扁平单列，字段顺序对齐参考——名称/分组/匹配规则/替换为/作用范围/正则/特定范围/排除范围/超时/预览；「标题/书源/正文」作用范围由三个 Checkbox 改 **FilterChip 平铺 chips**（未选范围提示行保留）；「使用正则表达式」保留 Checkbox + 帮助按钮。`replace_rule_edit_screen.dart` 仅改表单布局与范围控件，规则数据链路不变
- [UI] Web 服务卡片化（B2-C2 2-10 P3，基准 ref_batch2/12_web_service.png，台账「参考大卡带图标/绿acc，我方扁平」）：我的页「Web 服务」由 SwitchListTile 行改为**独立大卡**——48dp 圆角图标槽（language 图标）+ 标题/状态副题 + 右端 Switch（busy 时 spinner）；开启态卡片描边与图标槽转绿（iOS 系统绿 AppColors.iosGreen，亮/暗双值），MCP 服务行独立成组保持原位。`settings_screen.dart` 新增 `_buildWebServiceCard`，`_toggleWebService` 启停/状态/持久化语义不变
- [台账] 2-2 发现溢出菜单由主代理修正采集断言后重采，本批不动代码

### Test
- `flutter analyze` 无问题；`flutter test` 全过（1449 例；回归套件同步：`replace_rule_edit_test.dart`/`replace_rule_scope_overflow_regress_test.dart` 范围控件断言 Checkbox→FilterChip（含 360dp+字体放大溢出回归），`source_edit_test.dart` 断言由 Tab 切换改为扁平段标题直查 + 800x8000 加高面全字段直断）

### Real device
- release 2.0.266+267 APK 装 MuMu（192.168.1.19:5555，adb D:/leidian/LDPlayer9/adb.exe），versionName=2.0.266 校验通过；`scripts/parity_capture_ours.py --only 07_source_switch,08_source_manage,09_source_editor,10_replace_rule_edit,12_web_service` 5/5 屏 OK，截图 docs/parity_shots/ours_2.0.266/{07_source_switch,08_source_manage,09_source_editor,10_replace_rule_edit,12_web_service}.png（对照 ref_batch2/07、08、09、10、12，07 为回归屏）

- Contributor: 全栈工程师子代理

## [2.0.265] - 2026-09-15

### Fixed
- [UI] 发现页源卡改参考版单列列表行形态（B2-C1 2-1 P1，台账 2-1，基准 docs/parity_shots/ref_batch2/01_discover.png）：移除卡片底（页背景直落），行 = 前置 24dp 圆角图标位 + 源名 + 右侧 chevron（展开旋转 0.25 圈不变）；行高 56，行内水平 padding 16→10dp（列表页另 16dp 页边距，合计 26dp 对标原版 16+10）。`explore_screen.dart` 仅改 `_SourceItemState.build` 行渲染，展开/长按六项菜单/分组筛选/搜索机制不变。参考版行内前置 24dp 圆角图标（ref 01/03 全分辨率像素核验为源 favicon 图）——我方 BookSource 模型无图标字段（favicon 数据不可取），前置位以中性占位图标渲染（book_rounded、onSurface 6% 圆角底），登记台账数据差异
- [UI] 书单页细差（B2-C1 2-5，基准 ref_batch2/06_booklist.png / 08_booklist_books.png）：①筛选漏斗按开启态着色——默认态改深色中性漏斗（`filter_alt` + onSurface，对齐参考顶栏像素核验：深色 onSurface、无 off 斜杠；原为浅灰 `filter_alt_off_rounded`），开启态保持实心 + 主题色（`filter_alt_rounded` + primary，不变）；②卡片评分/热度行——SearchBook 模型无 score/heat 字段（notifier/API 检索确认数据不可取，任务条件「若数据可取」不成立），无代码改动，登记台账数据差异
- [台账] 展开区 chips 型源复核（B2-C1 2-3，基准 ref_b2_map/03_discover_expand.png + ref_20260913/12_discover_expanded_3col_chips.png）：同型源形态一致（分区标题 + 3 列 chips 网格，C8 已闭环）；参考版 chip 选中态 accent 为源主题色（像素核验绿色 ≈(122,221,138)），我方中性灰底（onSurface 10%/14%）——差异属源数据类型（主题色 BookSource 不可取），登记台账数据差异，不改代码

### Test
- `flutter analyze` 无问题；`flutter test` 全过（1449 例；回归套件 `explore_screen_c8_test.dart` A4 卡片底用例同步为新行形态断言：源名祖先链无卡片 Container + 行首 24x24 图标槽（onSurface 6% 圆角 6 底、16dp book_rounded 占位、后随 12dp 间距）+ 行尾 chevron）

### Real device
- release 2.0.265+266 APK 装 MuMu（192.168.1.19:5555，adb D:/leidian/LDPlayer9/adb.exe），versionName=2.0.265 校验通过；`scripts/parity_capture_ours.py --only 01_discover,03_discover_expand,06_booklist` 3/3 屏 OK，截图 docs/parity_shots/ours_2.0.265/{01_discover,03_discover_expand,06_booklist}.png（对照 ref_batch2/01、03、06 与 ref_20260913/12）
- 像素点检：①01 首源行前置图标槽底色 (235,235,235)（=onSurface 6% 落于 248 页背景）+ 16dp book 占位墨迹 (68,71,72) + 行尾 chevron 墨迹存在，行外页背景 248 直落（无卡片底）✓ ②06 顶栏漏斗默认态深色中性墨迹存在（filter_alt，无 off 斜杠）✓

- Contributor: 全栈工程师子代理

## [2.0.264] - 2026-09-15

### Fixed
- [UI] 书架封面网格列数 2→3 修正（台账 SCREEN_1TO1_PARITY_LEDGER 1-3「0915 修正」注记，用户实测 + 主代理度量确认：参考 03b 实为 3 列固定卡宽——卡宽≈屏宽 27%/列间距 20/左右边距 22，仅 2 本书时第三格留空；我方 2 列卡宽≈44% 致封面过大、不像目标风格）。`bookshelf_screen.dart` 只动网格参数：正式网格与加载骨架 `crossAxisCount 2→3`、`mainAxisSpacing/crossAxisSpacing 12→20`、左右 padding 12→22（上下 8 不变）；封面比例 5:7（≈1:1.4）/圆角 12/书名居中字号/选择模式勾选态/长按菜单均不变；书少时右格自然留空（与参考一致，不撑满/不居中放大）。回归套件 `bookshelf_grid_responsive_test.dart` 断言同步 2→3（并锁间距 20）
- [UI]（补修，复审 d005c46802 未通过，版本保持 2.0.264+265 不递增）①封面压方修正：网格 cell 固定 `childAspectRatio` 5/7 把「封面 5:7 + 书名行 40dp」整格定高，`BookGridItem` 的 Expanded 封面被标题行挤占后实测压成 ≈1:0.97 方形（270 宽×262 高；要求 5:7 即 270 宽应≈378 高）。改由上层 `LayoutBuilder` 取视口实际宽动态计算（SDK 3.44 无 `SliverPadding.builder`，box 层取宽）：`cellW=(W−44−40)/3`、`cellH=cellW×7/5+40`、`aspect=cellW/cellH`（360dp→0.5450），封面恢复精确 5:7（360dp：92×128.8dp），加载骨架网格同式同构 ②分组 tab 行加左缘 20dp：此前 `TabBar` padding 0 贴死屏左缘（「全部」左起 x≈2px、下划线 x=0 起），参考 03b 量测首 tab 墨迹 x≈59px@3x≈20dp；改 `TabBar(padding: EdgeInsets.only(left: 20))`，可滚动 TabBar 下 padding 仅作用于首尾两 tab 边缘（首 tab 左 20dp、末 tab 右 0），中间 tab 顺排不变 ③网格左右 padding 锁 22dp：自检③单卡墨迹跨度 26%~30%（1080px 屏 279~324px）——22dp→294px（27.2%）落区间，30dp→≈25.4% 出区间，故保持 22dp；卡左起 68px 小于参考换算≈90px，登记为已知微差（边距协同以自检③红线为准）。回归套件 `bookshelf_grid_responsive_test.dart`（cell aspect 三档按同式 `closeTo(…,1e-6)`）与 `bookshelf_tab_alignment_test.dart`（首 tab 左缘 `inInclusiveRange(19,24)`）断言同步补修

### Test
- `flutter analyze` 无问题；`flutter test` 全过
- （补修复跑）`flutter analyze`（flutter_legado 域）0 问题；`flutter test` 全过（1449 例，含上述两回归套件补修断言）

### Real device
- release 2.0.264+265 APK 装 MuMu（192.168.1.19:5555）复验：截图 docs/parity_shots/ours_2.0.264/03_bookshelf.png（程序化断言：单卡封面行墨迹横向跨度占比落于 26%~30% 区间，对齐参考卡宽≈27%）
- （补修）release 2.0.264+265 APK 重装 MuMu 并**重采** docs/parity_shots/ours_2.0.264/03_bookshelf.png（覆盖同路径）；三项程序化自检全部达标：①封面高宽比 1.441（≥1.35 ✓，名义 5:7=1.4，含阴影/圆角抗锯齿外扩）②tab 文字左缘 40px@720p（=20dp，≥15px ✓；1080p 等效 ≈60px，与参考 ≈59px 一致）③单卡墨迹跨度 26.1%（26%~30% ✓）；采集环境注记：Test 实例（192.168.1.19:5555）本轮 ADB 桥接失效（实例 ADB 未启用且 manager 无法重连），改在实例 0（127.0.0.1:16384，720×1280@320dpi=360dp，与 1080×1920@480dpi 同 360dp 布局基准）重装 2.0.264 重采；该实例书架仅 R1 换源验证书 1 本（网格右两格留空符合规格），采前经 ⋮ 菜单「布局设置」由列表切回网格态

- Contributor: 全栈工程师子代理

## [2.0.263] - 2026-09-15

### Fixed
- [UI] 书架与全局图标 1:1 对齐（C3，台账 SCREEN_1TO1_PARITY_LEDGER 1-3/1-4，基准 docs/parity_shots/ref_20260914/03_bookshelf*.png / 04）：
  - B1 分组 tab 左对齐：根因为 `SliverAppBar.large` 的 bottom 槽以松约束下发，M3 可滚动 TabBar 收缩为内容宽度并被父级居中（单组「全部」整行居中偏右、多组首 tab 同样不贴左）。改以 `SizedBox(width: double.infinity)` 撑满 bottom 槽 + `isScrollable` + `TabAlignment.start` 把首 tab 钉左（`SizedBox.expand` 会致 tab 行爆高，禁用）
  - B2 书架溢出菜单改参考「每项图标 + 分体圆角卡」形态（量测自参考 04：全屏最浅 surface 覆盖层 + 右侧 162dp 竖板 + 144×48dp 圆角 8 卡、卡间 8dp 露竖板色、24dp 图标距卡左 15dp）；自绘菜单页整页从右轻微滑入，触发钮改裸 ⋮（无圆底）。首屏 11 项顺序与功能项集不动，我方特有项（离线缓存/分组模式三选/书源管理）按双基准原则保留；原 PopupMenuButton 下拉形态与 `_buildGroupModeItem` 移除，分组三选改卡内单选钮图标
  - B3 菜单文案对齐参考：「添加远程书籍」→「远程书籍」、「书架布局」→「布局设置」
  - B5 底栏订阅页签图标 `feed_rounded`（报纸/文档版式）→ `rss_feed_rounded`（经典 RSS：左下圆点 + 双弧，对齐参考底栏第 4 项）；顶栏钮裸图标——`LegadoTabRootHeaderSliver` 新增 `actionsStyle` 覆写参（null=跟随全局 topBarButtonStyle 档位），书架顶栏与批量模式钮锁 `TopBarButtonStyle.plain`（对齐参考 03/03b/05 无圆底；搜索等圆底屏不受影响）
- 新增回归套件 `test/widget/bookshelf_tab_alignment_test.dart`（B1 两态锁死：空态回落唯一 tab 左缘 ≈0；多组首 tab 左起 + 后续 tab 顺排。注意分组 tab 列表=通知器「默认全部组置顶 + 用户组」，断言以实际渲染首 tab 为准）

### Real device
- release 2.0.263+264 APK 已装 MuMu（192.168.1.19:5555）并复验（2026-09-15）；截图 docs/parity_shots/ours_2.0.263/03_bookshelf.png（程序化断言：tab 行最左墨迹列 x≈1=左对齐、顶栏动作区墨迹占比 0.6%=裸图标）与 04_bookshelf_overflow_menu.png（程序化断言：全屏覆盖层下书网格区方差 0.0=均匀 surface、右面板卡片墨迹存在）+ 03b_rss_icon_crop.png（底栏订阅 RSS 图标形态存证）

- Contributor: 全栈工程师子代理

## [2.0.262] - 2026-09-15

### Fixed
- [UI] 阅读器正文 1:1 对齐（台账 SCREEN_1TO1_PARITY_LEDGER 1-10，基准 docs/parity_shots/ref_20260914/10_reader.png / 10b）：①【P1】默认字号 18→20（对齐参考约 20-22sp/行、每行约 14 字，自 ref 10 量化后改默认档，`ReaderState`/`SettingsService`/freezed 默认值同步）；②默认行距 1.6/1.67→1.7（对齐参考约 1.7）；③正文顶部「时间+章节名+进度」状态行——四开关（电量/时间/进度/章节名）默认关闭（参考无顶状态行，改为用户按需开启，功能保留）；④底栏左侧改显示「书名」而非「章节名（截断）」（`tipFooterLeft` 1(章节名)→7(书名)，对齐参考「斗罗大陆」）
- [UI] 阅读器菜单 1:1 对齐（台账 1-11，基准 docs/parity_shots/ref_20260914/11_reader_menu.png）：①【P1】菜单形态收敛为紧凑浮层（非整页大面板、无暗色遮罩，正文约 87% 可见；顶行=章节信息+⋮、中部小图标、底部功能行）；②移除来源 URL 全文行（来源名并入小字徽标行，仅保留来源名小字）；③中部圆钮去圆底、对齐参考小图标形态（搜索/目录/朗读/设置/换源五快捷钮，仅保留小图标+圆形点击热区，全部功能项不丢失）；④进度形态对齐参考底行「X/Y + 目录%」（文字=当前页/总页数 或 当前章/总章数 + 进度百分比，保留滑条寻址能力，移除 S6 圆形前后箭头按钮——前后章仍可经屏缘点按与目录触达）；⑤亮度条位置核实：参考该态未见→菜单内亮度行默认关闭（`showBrightnessView` 构造器/load 缺省 true→false，改为用户经设置开关按需开启，开关保留）；⑥底部功能行五项（章节梗概/AI改写/全文搜索/自动翻页/目录）已是同名同序，未改动
- [UI] 目录页 1:1 对齐（台账 1-9，基准 docs/parity_shots/ref_20260914/09_toc.png）：①T1 tabs 数——参考 2 项（目录/书签），我方多「标注」第 3 项，**登记保留**（标注为功能超集，移除将隐藏书籍标注列表功能，按功能基线保留并登记）；②T2 章节行右侧改字数胶囊（「N 字」surfaceContainerHighest 圆角底，受「加载字数」开关控制），移除原云朵缓存状态图标（当前章对勾/已缓存实心云/未缓存空心云），缓存能力保留于目录 FAB「一键缓存」，连带清理仅服务该图标的缓存态轮询定时器与 `_cachedChapterUrls` 集合（缓存查询 API 不变）；③T3 标题区对齐：章名大标题与「N / M」页码同行（参考为「章节名+页码」整体大标题，与右侧 🔍/⋮ 动作分离；原为两行 Column 堆叠改单行）；④T4 移除目录底栏「页码+↑↓」信息条（参考无底栏；跳转顶部/底部与定位当前章能力保留于目录 FAB 展开菜单）；⑤T5 当前章高亮改参考淡蓝整行底（量化 ref≈(238,243,253)，用 primary 10% 透明铺底替代原「选中加粗+主题色」，文字恢复常规色）
- [UI] 搜索结果项未渲染模板串（C1 验收登记 N1，归入本批）：ngmlc 等书源 kind/intro 模板变量（形如「{{$categoryInfoV4}}」）未被清洗时，结果项会原样显示未渲染模板串。UI 层防御性清洗——结果项副标题/标签渲染前检测未渲染模板串（`{{...}}` 残留）并隐藏对应字段，避免错显。**根因登记于书源规则域**（模板变量应经书源规则 JS 求值后落值，属数据层/书源规则域，非本批 UI 范围，后续由书源规则域跟进）

### Test
- `flutter analyze` 无问题；`flutter test` 全过（1447 例；受影响用例同步：默认字号/行距断言 18/1.67→20/1.7、ReaderStatusStrip 默认改为「全关不渲染 + 开启开关才渲染」、移除已废弃的目录云图标用例 `toc_cache_icon_test.dart`）

### Real device
- MuMu Test 实例（192.168.1.19:5555）安装 release 2.0.262+263：截图 docs/parity_shots/ours_2.0.262/{10_reader,11_reader_menu,09_toc}.png（与 ref_20260914 对应屏比对）

- Contributor: 全栈工程师子代理

## [2.0.261] - 2026-09-15

### Fixed
- [UI] 搜索结果页 1:1 对齐（台账 SCREEN_1TO1_PARITY_LEDGER 1-7，基准 docs/parity_shots/ref_20260914/07_search_results.png）：①移除结果胶囊下「搜索: N」重复文本行（「结果 N · 进度 x/y」胶囊已含两信息；加载中悬浮 x/y 卡为原版行为保留）；②【P1】空数据防「NaN : NaN」：作者/最新章节/字数（含 kind 标签）为空串或 "NaN"（书源规则未返回数值时 JS 侧可能字符串化出 "NaN"，Rust 侧 word_count 为 Option<String>）一律视为无数据，不渲染副标题行与标签；③「暂无专辑」「暂无简介」占位——确认代码中不存在（简介为空时 `_buildIntro` 直接返回 SizedBox，无占位文本），与参考版一致，无改动；④结果项右侧书源名徽标改为来源数数字角标（灰底圆角盒、顶对齐、单源显示 1，对齐参考 143/13/8 量化形态）；⑤红线：封面音频播放钮/右下播放浮钮——代码中不存在，docs/ 与 git 历史检索均无授权证据，按红线规则不新增
- [UI] 书内内容搜索页 1:1 对齐（台账 1-13，基准 docs/parity_shots/ref_20260914/13_search_content.png）：①标题「搜索正文」→「搜索内容」；②新增「仅本书」深色胶囊（72×39dp、深色实底白字、置于历史行右侧，复用既有范围三档逻辑：与 ⋮ 菜单「仅本书（已缓存）」共享同一进程内静态选择，点击切换 仅本书⇄本书+网络 范围并立即重搜，默认选中样式对齐参考）；③搜索框 hint 改为「搜索...」
- [UI] 书籍详情页 1:1 对齐（台账 1-8，基准 docs/parity_shots/ref_20260914/08_book_info.png）：①【P1】操作区改 4 图标卡一行（已在书架/查看目录/书源/阅读记录；卡 52×69dp、间距 32dp、图标上标签下；书架卡为状态切换：在架显示「已在书架」点按移出、不在架显示「加书架」点按加入）；「设置分组」行内小按钮移除，并入次级入口=顶栏 ⋮ 溢出菜单「设置分组」（_showChangeGroup 行为不变，功能不丢失）；②封面放大至参考比例（自 ref 08 量化：约占屏宽 1/3=120dp、高 260dp）；③右下「继续阅读」改绿色「阅读」胶囊 FAB（约 101×55dp，绿底 (175,242,196)/深绿字 (11,81,48)，右 18dp/底 17dp；标签固定「阅读」，阅读跳转与续读位置取 durChapterIndex 行为不变）；④章节信息行改单行「共 N 章｜未读/已读」（总章数取 book.totalChapterNum 缺失时回落目录长度，状态词绿色强调，无章节显示「暂无章节」）；⑤红线：流派标签云——代码中不存在，docs/ 与 git 历史检索均无授权证据，按红线规则不新增

### Test
- `flutter analyze` 无问题；`flutter test` 全过

### Real device
- MuMu Test 实例（192.168.1.19:5555）安装 release 2.0.261+262：截图 docs/parity_shots/ours_2.0.261/07_search_results.png、13_search_content.png、08_book_info.png（与 ref_20260914 对应屏比对）

- Contributor: 全栈工程师子代理

## [2.0.260] - 2026-09-14

### Fixed
- [UI] 书架页布局骨架对齐参考版（台账 SCREEN_1TO1_PARITY_LEDGER 1-3，基准 docs/parity_shots/ref_20260914/03b_bookshelf_with_books.png / 03_bookshelf.png）：①布局骨架=可折叠大标题「书架」（28sp：`LegadoTabRootHeaderSliver` 新增加性参数 `largeTitleFontSize: 28`，显式传入 `SliverAppBar.titleTextStyle`——SDK 解析序 `titleTextStyle ?? appBarTheme.titleTextStyle ?? config.headlineMedium`，全局 AppBarTheme 的 titleLarge 18sp 短路子树字阶覆写，标题实际渲染 18sp 偏小；参考 03b 截图量测字身 66px@480dpi≈28sp，与首页 2.0.259 大标题先例一致；另 `expandedHeight: 164`（SDK large 变体对显式 expandedHeight 原样使用、不再加 bottom 高，语义为「状态栏之外头部总高（含 TabBar 56）」=顶行 64+标题区 44+TabBar 56，加状态栏 24 共 188dp，对齐参考下划线底 551px@3x；显式值小于 minExtent 144dp 时会被 delegate 钳制致标题带归零——初版误传 108 经实机复验发现后修正）收敛 M3 large 默认节距差。两参数均默认不启用，仅书架传入，共享组件其他调用方行为不变）→ 常驻分组 tab 行（tab 数据来自既有分组；无分组数据时回落单一「全部」tab；选中态=primary 字色+下划线；切换 tab 经 `selectGroup` 真正过滤列表并持久化位置）→ 2 列大封面网格（卡片=封面（圆角 12）+居中书名，子项 5/7 比例，间距 12；原按宽度 3/4/6 分档列数不再采用）；②页内全宽搜索行移除，搜索入口收敛为顶栏 🔍 图标（沿用既有路由 AppRoutes.search，⋮ 溢出菜单项集不变）；③空态对齐参考版：大标题+「全部」tab+居中颜文字彩蛋（`EmptyState(kaomoji)`，既有用户授权功能，2026-08-29 口径）；④选择模式/批量操作、网格/列表切换、分组逻辑、卡片长按菜单全部保持可用，`_buildBatchListItem` 的 `ValueKey` 修复（2.0.258 P0）不回退；批量态网格卡圆角统一 12
- [UI] **红线清理**（2026-08-29 用户修订授权口径：无授权记录的功能须清理）：移除书架页「统计行（N 本书 · N 在读）」与「最近阅读行」。证据检索结论=①原版安卓 `AppConfig.showBookshelfStats` 默认 **false**（统计行在原版默认隐藏），本移植版将其改为默认常显属未对齐偏差；②docs/ 与 git 提交历史中未发现用户对常显这两行的授权记录（0907 盘点「结构基本一致」为审计员判断，非用户授权，已被 0914 重采样基准取代）。连带死代码清理：`BookshelfState.showStats`/`showRecentReading` 字段（含 freezed 重生成）、`BookshelfNotifier.toggleShowStats`/`toggleShowRecentReading`、`SettingsService` 的 `get/setShowBookshelfStats`/`get/setShowBookshelfRecentReading` 与 2 个 SharedPreferences key、`Responsive.gridColumnsForWidth`/`bookGridChildAspectRatio`（书架网格已固定 2 列）。另：99+ 未读徽标与阅读进度条不再渲染于书架卡片（参考版 03b 无此二者，以参考版为准）；未读/阅读状态能力保留——封面长按 → 书籍信息页「在读」行仍可达（登记项）
### Test
- `flutter analyze` 无问题；`flutter test` 全过（含选择模式回归 `bookshelf_batch_mode_test`；受影响用例改写：搜索入口守护改顶栏图标断言、网格响应式用例改固定 2 列断言、统计/最近阅读相关用例随死代码移除）

### Real device
- MuMu Test 实例（192.168.1.19:16416）安装 release 2.0.260+261：截图 docs/parity_shots/ours_2.0.260/03_bookshelf.png（有书态，书架现有 1 本斗罗大陆）与 05_bookshelf_select_mode.png（选择模式复验）

- Contributor: 全栈工程师子代理

## [2.0.259] - 2026-09-14

### Fixed
- [UI] 首页 1:1 对齐（台账 SCREEN_1TO1_PARITY_LEDGER 1-2，基准 docs/parity_shots/ref_20260914/01_home_page.png）：①「首页」大标题移至动作钮行下方独立一行（fontSize 28）；②统计双卡图标统一主题 primary 色（复核已对齐，无改动）；③目标卡编辑入口由行内铅笔改为白底圆形悬浮钮（pencil 图标 40×40 圆形 Material），目标卡图标统一靶形 radar_rounded；④卡片圆角 20→24 对齐参考版；⑤⋮「首页组件」入口属模块管理域，用户裁决暂不实施，仅保留台账登记
- [UI] 搜索页 1:1 对齐（台账 1-6，基准 docs/parity_shots/ref_20260914/06_search.png）：①顶栏 4 钮 → 3 钮（⚙ 设置 / ◯ 搜索范围 / ≡ 结果过滤），移除 ⋮ 溢出菜单并将菜单项按语义并入三钮（精准搜索/标识读过的书籍/书源管理/日志 → ⚙ 设置弹层；当前书源/全部书源/分组:X → ◯ 范围弹层新增快捷节，点按即切范围并重搜；原 ⋮ 静态项「搜索结果过滤/分组或书源」与 ≡/◯ 直按钮重复，不再单列）；②输入条改紧凑胶囊（高 56dp、hint 16sp、灰蓝底走主题槽 surfaceContainerHigh、无阴影、两端全圆）；③「搜索历史」标题行补时钟形（history）前缀图标；④历史 chip 与空态不改（待参考有数据态补采后再比，保留台账登记）

### Test
- 实机验证：MuMu Test 实例（192.168.1.19:16416）安装 release 2.0.259+260，截图 docs/parity_shots/ours_2.0.259/01_home_page.png、06_search.png（与 ref_20260914 逐屏比对通过）；`flutter analyze` 无问题；`flutter test` 全过（1459 例）

- Contributor: 全栈工程师子代理

## [2.0.258] - 2026-09-14

### Fixed
- [UI] 书架「选择模式」进入后整屏灰白空白（台账 SCREEN_1TO1_PARITY_LEDGER 1-5 P0，用户可见功能不可用，MuMu 实机复拍两次复现：菜单→选择模式后无顶栏/无全选·删除·取消操作项/无书列表，仅剩底部导航，uiautomator dump 无任何选择态关键词）。根因=批量摘要卡 `_buildBatchSummaryCard` 被构建为 `Positioned` 子树却挂在 `SliverToBoxAdapter`（非 Stack 父级）下，进入选择模式（isBatchMode=true）后布局期抛异常（debug 报 "A Positioned widget must be wrapped with its parent"，release 帧渲染中断）→ body 整屏空白。修复=①摘要卡改常规 Center 布局（对齐参考版 05 截图「已选N本 · 共M本」胶囊：×退出钮+计数，位置移至头部之后）；②选择模式顶栏由「搜索+溢出菜单」切换为批量动作集（全选/反选/删除/取消，tooltip 暴露为 content-desc 保证 dump 可检索）；③列表/分组列表/网格行均呈现勾选态（选中高亮+对勾，点按切换）；④删除动作经确认对话框后逐本 `deleteBook`（对齐 BookshelfManageNotifier 方案），成功后同步列表并重拉数据源、清空选中并退出选择模式。空书架+选择模式仍呈现胶囊（对齐参考版 05 空态截图）。剩余能力（批量下载/移动分组 目前为 SnackBar 占位、批量缓存/批量换源等）登记不实现

### Fixed（补充修正）
- [UI] 2.0.258 复审缺陷补修：选择模式下书架**书卡列表/网格分支仍不渲染**（书卡区灰色空区、无封面/书名/勾选态）。根因=`SliverReorderableList` 惰性 `itemBuilder` 要求每个 item 必带 `Key`（`reorderable_list.dart` 断言 `child.key != null`），而批量态 `_buildBatchListItem` 返回**无 key 的 `Material`** → 进入选择模式该 item 构建期抛异常、整行不渲染（正常态 `BookListItem` 自带 `ValueKey` 故不受影响）。修复=`_buildBatchListItem` 外层 `Material` 补 `key: ValueKey(book.bookUrl)`；新增真实 widget 测试 `bookshelf_batch_mode_test`（pump 真实 `BookshelfScreen` 复现并锁定勾选态）

### Test
- 实机验证：MuMu Test 实例（192.168.1.19:16416）安装 release 2.0.258+259，书架→溢出菜单→选择模式，屏幕呈现顶栏批量动作集（全选/反选/删除/取消）+「已选N本 · 共M本」胶囊+书列表勾选态，uiautomator dump 含 全选/反选/删除/取消/已选 关键词；`flutter analyze` 无问题；`flutter test` 全过。截图 docs/parity_shots/ours_2.0.258/05_bookshelf_select_mode.png
- 复审补修后复验：选择模式书卡行完整渲染（dump 中「斗罗大陆」命中 最近阅读行 + 书卡行 2 处，书卡行 bounds y>1100），点按书卡切换勾选、胶囊数字随之变化；`flutter analyze` 无问题；`flutter test` 全过（含新增 2 例选择模式书卡渲染/勾选测试）

- Contributor: 全栈工程师子代理

## [2.0.257] - 2026-09-14

### Fixed
- [UI] 书架溢出菜单「导出书单/导入书单/日志」三项首屏不可见（台账 SCREEN_1TO1_PARITY_LEDGER 1-4② 登记 P1「功能缺失待核实」，核实结论=**功能与入口均已存在**，v2.0.2 起三项菜单项与处理逻辑齐备：导出书单=书架 JSON 数组（name/author/intro）导出分享、导入书单=URL/JSON 数组/txt/json 文件导入并经 preciseSearch 逐本入库、日志=跳 AppLogScreen（对标原版 menu_log → AppLogDialog）；缺失表象根因=菜单 14 项 + 4 条分割线超出 360×640dp 屏溢出菜单可视高度，三项被挤到滚动区外，1:1 首屏截图比对误判为缺失。修复=菜单重排对齐参考版顺序：首屏 11 项=添加远程书籍/添加本地/更新目录/书架布局/分组管理/添加网址/选择模式/书架管理/导出书单/导入书单/日志（对齐参考版 03_bookshelf_overflow_menu.png 顺序，并含参考版特有「选择模式」项），我方特有项（离线缓存/不分组/按来源分组/按分组显示/书源管理，双基准任一侧存在即保留）移至分隔线后第二屏。菜单图标/分体卡形态（1-4①）另行登记，本任务不做

### Test
- 实机验证：MuMu Test 实例（192.168.1.19:16416）安装 release 2.0.257+258 冷启动，uiautomator dump 验证书架溢出菜单首屏文本含「导出书单」「导入书单」「日志」；`flutter analyze` 无问题；`flutter test` 全过。版本 2.0.257+258

- Contributor: 全栈工程师子代理

## [2.0.256] - 2026-09-14

### Fixed
- [Rust] 多源搜索起步阶段 UI 卡顿（用户实测报告，MuMu 1 核实例取证）：搜索触发后应用进程吃满全核（top 实测 84→100%，整机 0% idle），32 路并发派发 + blocking 池 64 线程与 Flutter UI 线程公平竞争，单核下 UI 线程仅分到 ~3% CPU → 整页掉帧。修复 = runtime 全部线程（worker + spawn_blocking 池，经 tokio `on_thread_start` 统一挂钩）在 Android/Linux 上降权至 nice 19，对齐 Android 原版平台行为（后台协程运行在低优 cgroup）；UI 线程立即抢占，runtime 线程在 UI 空闲时仍吃满核，搜索吞吐不受损。搜索并发数（32，2026-08-25 实证对齐原版有效并发）保持不变

### Test
- 实机 A/B 取证：修复前搜索期应用进程 CPU 84→100% 持续风暴；修复后同场景 40~72%，526 源全量搜索 33s 收敛（此前 57s），worker 线程 `ps -T` 实测 NI=19。`cargo check` 通过；`flutter analyze` 无问题。版本 2.0.256+257

- Contributor: Qoder UI（子代理暂停期主代理兜底，经用户授权）

## [2.0.255] - 2026-09-14

### Changed
- [UI] 搜索页整体布局对齐参考版（差异清单登记项，主代理兜底实现）：**输入条从顶栏移入 body**——顶栏仅保留 ← + 圆形动作钮（⚙ 书源管理 / 🌐 定位 / ☰ 筛选〔实心=已开启〕/ ⋮ 全量菜单），body 顶部新增大标题「搜索」（headlineMedium 加粗）+ 全宽输入条；结果/历史/空态逻辑不变。此项同步解决了 A1 三钮加入后顶栏 7 元素在 360dp 屏的拥挤与 SearchBar minWidth 360 溢出问题（输入条入 body 后顶栏无宽度压力）

### Test
- 主代理实现并复核：`flutter analyze` 无问题；`flutter test` **1451 全过**；`search_screen_scroll_test` 的 readPixels 改为读取结果 ListView 自身控制器（原按类型取首个 Scrollable 在新布局下误读其他滚动视图），2 例滚顶回归通过
- 说明：输入条全宽后不再有 minWidth 溢出问题（此前 2.0.254 的 minWidth 0 修复为过渡方案）。版本 2.0.255+256

- Contributor: Qoder UI（子代理暂停期主代理兜底，经用户授权）


## [2.0.254] - 2026-09-14

### Fixed
- [UI] 搜索页顶栏溢出导致无法输入（用户实测报告，Test 实例 360dp 屏）：A1 三钮加入后顶栏共 7 元素（返回+胶囊+→+⚙+定位+筛选+⋮），而 M3 SearchBar 默认 **minWidth 360**——胶囊在 AppBar 中槽内无法收缩、内部行溢出 4px（红条），输入区被压没。修复：SearchBar `constraints.minWidth = 0` 允许随中槽收缩；移除冗余「→ 提交」钮（提交能力由键盘搜索 IME 动作覆盖，能力零丢失），为胶囊腾出宽度

### Test
- 主代理修复并复核：`flutter analyze` 无问题；`flutter test` **1451 全过**（新增 `search_appbar_overflow_test` 2 例：360dp 下顶栏无溢出 + 输入/IME 提交不抛异常）。版本 2.0.254+255

- Contributor: Qoder UI（子代理暂停期主代理兜底，经用户授权）


## [2.0.253] - 2026-09-13

### Fixed
- [UI] 发现页书源列表不随导入刷新（用户报告：导入 526 源合集后发现页没有发现源）：根因 = 发现页源列表仅在页面初始化时加载一次，书源管理的导入/删除/启停**不触发任何失效通知**——导入后不重启应用，发现页永远显示旧列表（空）。DB 证据：导入实际完全成功（book_sources 526 行、395 行带 exploreUrl 且 enabledExplore=1）。修复 = ExploreNotifier `ref.listen(sourceNotifierProvider)`：书源状态任意变更（copyWith 新对象）即自动重载发现书源列表（_loadBookSources 只读 bookApiProvider，无循环触发）

### Test
- 主代理修复并复核：`flutter analyze` 无问题；`flutter test` **1449 全过**
- 设备证据（MuMu Test 实例，192.168.1.19:16416）：DB 中 526 源/395 带发现均在库；修复后启动发现页正常列出 半夏小说/奈飞工厂/SiS文學網简体 等源卡；「导入后不重启即自动出现」的监听器行为由 Riverpod ref.listen 语义保证（代码审查：_loadBookSources 无循环触发路径）
- 版本 2.0.253+254

- Contributor: Qoder UI（子代理暂停期主代理兜底，经用户授权）


## [2.0.252] - 2026-09-13

### Added
- [UI] 发现分类书单页顶栏动作对齐参考版（差异清单低优登记项，主代理兜底实现）：新增**筛选漏斗**（本地关键字过滤已加载书籍，匹配书名/作者，忽略英文大小写；开启态图标实心着色对齐参考版语义）与 **☰ 列表切换**（书卡密度 舒适/紧凑——紧凑模式封面缩小、简介单行）；既有 加入书架/页码 动作保留，能力零丢失

### Test
- 主代理实现并复核：`flutter analyze` 无问题；`flutter test` **1449 全过**（新增 `explore_show_actions_test` 3 例：关键字筛选/清空恢复/密度切换）
- 语义说明（如实）：参考版两图标（筛选漏斗/☰ 列表切换）为 Compose 新版形态、无源码可查，按图标惯用语义落地为「关键字筛选」与「密度切换」；若后续获取参考版确切语义再校准。版本 2.0.252+253

- Contributor: Qoder UI（子代理暂停期主代理兜底，经用户授权）


## [2.0.251] - 2026-09-13

### Changed
- [UI] 阅读界面弹层「更多」改为**全高独立弹层**（差异清单遗留实施项，UI_ONE_TO_ONE_CLONE_PLAN 登记：参考版「更多」页签为全高独立弹层——把手+居中标题、无底部页签栏，我方为页签内嵌排版组）：点「更多」页签以全高（92%）独立弹层覆盖打开，内容整体迁移（行距/字重/ReaderConfigPanel 更多配置/共用布局），关闭后回到页签弹层；页签栏保留四项、其余三页签行为不变

### Test
- 主代理自实现（子代理暂停期间按用户授权兜底）并复核：`flutter analyze` 无问题；`flutter test` **1446 全过**（新增全高弹层回归断言：页签+弹层标题同名两处、行距/字重/共用布局在弹层内、几何检查）；既有 sheet 测试原样兼容
- 真机复核：Test 实例（192.168.1.19:16416）已装 2.0.250 并冒烟 7/7；「更多」全高弹层的真机目视复核待用户实测（Test 实例需先加一本书打开阅读器——本地 TXT 导入经 SAF 的打开方式链路未走通，如实登记）。版本 2.0.251+252

- Contributor: Qoder UI（子代理暂停期主代理兜底，经用户授权）


## [2.0.250] - 2026-09-13

### Added
- [Rust] 替换规则编辑器 `@js:` 预览补齐（用户裁决立项，跨轨，子代理 full-stack-engineer 交付 + 主代理复验）：契约 §2.8 新增 `previewReplaceRule(ruleJson, sampleContent)`（方法数 7→**8**，附录 277→**278**，BookApi 口径 274→**275**）——把样例文本送进 Rust **真实替换管线**（正则优先/fancy-regex 回退、`@js:` 走 QuickJS、逐规则超时），对齐原版 ReplacePreview 的 Rhino 语义；**规则级错误返回 `⚠️ ` 前缀说明文本不上抛**（预览 UX 直接可显示）
- [UI] 编辑器预览改为单一语义源：`_runPreview` 改调 FFI 真实管线（保留 250ms 防抖与首帧预览），**删除 Dart 轻量近似**（`_expandGroups` 与字面/正则/`@js:` 不可用降级提示全部移除）——预览结果与真实替换完全一致

### Test
- Rust：`preview_replace_rule` 五类 19 个单测（正则/字面/@js:/超时/非法 JSON），quickjs feature 开关双侧验证
- 设备 E2E（MuMu Test 实例，QA 代理，截图 `.tmp/e2e/`）：①`@js:` 真实执行——规则 `hello`→`@js:'<b>'+result+'</b>'`、输入 `hello`、输出 `<b>hello</b>`；②正则组展开——`([A-Z]+)([0-9]+)`→`$2-$1`、输入 `ABC123`、输出 `123-ABC`；③非法正则 `[` → 输出 `⚠️ Invalid regex pattern: [`；④`@js:` 规则成功保存进列表并启用；logcat 无应用侧错误（SIGSEGV 均为 uiautomator 工具自身）
- 主代理独立复跑：`flutter analyze` 无问题、`flutter test` **1446 全过**、`cargo test -p legado-ffi replace_rule` 19/19、`api_contract_test` 7/7；`.so` 重建（19:08/19:09 双 ABI，verifyRustFfiLibs 哈希 -734354461 通过）。**遗留**：armeabi-v7a 的 `.so` 未重建（不在 requiredAbis，真机 v7a 需时再跑）。版本 2.0.250+251

- Contributor: full-stack-engineer + Bridge + QA（主代理 Qoder UI 审核）


## [2.0.249] - 2026-09-13

### Added
- [UI] 字典规则管理新增「扫码导入」（尾巴清扫批①）：复用既有 QrcodeScreen 扫码链路（书源导入同款），扫码内容走 `dictRuleImport(kind:'text')` 同语义；原版 `menu_import_qr` 对齐，待办注释销记
- [UI] 滚动模式标题块接入标题字体（尾巴清扫批②）：C3 标题字体此前仅翻页/排版模式生效，现滚动模式标题块同样经 `effectiveTitleFontFamily` 单源取值（滚动不分页仅渲染侧，无测量同参问题）

### Fixed
- [Rust] `legado-js` variable_store 测试并行交错（尾巴清扫批③，照 2.0.248 config_api 的 StoreGuard 模式）：`test_clear_variables` 全量清空与并行 set/get 的中危交错窗口消除，产品代码零改动

### Test
- 主代理独立复跑：`flutter analyze` 无问题、`flutter test` **1446 全过**（新增 dict 扫码 2 例 + 滚动标题 2 例）、`cargo test -p legado-js` **236/236**、fmt 通过
- 说明：任务①部分实现系上一会话中断代理已完成、本批复验确认；`reader_page_view.dart:616` build 期 `Timer.run` 导致测试 pending-timer 残留为**既有**行为，测试内以追加 pump 规避，产品侧根治登记另批。版本 2.0.249+250

- Contributor: full-stack-engineer + UI + Bridge（主代理 Qoder UI 复核）


## [2.0.248] - 2026-09-13

### Fixed
- [Rust] 修复 `legado-js` config_api 三测的全局状态并行污染偶发失败（存量 CI flake，与本会话 scopeSource 批无关、复现于全量并行跑）：根因 = `test_injected_*` 三个写入类测试结束后**不恢复**进程级 `OnceLock<RwLock<Option<String>>>` 注入态（read_book_config/theme_config/theme_mode），并行交错时读取类测试（期望「未注入」默认语义）取到别人的注入值。修复（**纯测试改动 +69/-0，产品代码零改动**）：`StoreGuard` 快照-恢复守卫（Drop 实现，panic 路径同样恢复）+ `STORE_TEST_LOCK` 仅对 5 个触碰全局态的测试互斥（其余 231 个照常并行），从构造上消除交错；未用 `--test-threads=1` 掩盖、未删除/弱化断言

### Test
- 子代理自测与主代理独立复跑一致：`cargo test -p legado-js` **连跑 5 次 + 8/16 线程压力各一次全绿**（236/236）；其它 host_api 同类隐患已排查登记（`variable_store.rs` 全量 clear 与并行 set/get 存在中危交错窗口，建议后续修；device_id/global_headers/cookie_store/concurrency 为低危残留态）

- Contributor: full-stack-engineer + Bridge（主代理 Qoder UI 复核）


## [2.0.247] - 2026-09-13

### Added
- [Rust] 替换规则「书源作用范围」scopeSource 全链路（A3 最后一个字段受阻项解除，跨轨，子代理 full-stack-engineer 交付 + 主代理复验；对齐原版 `ReplaceRule.kt:47 scopeSource`）：① DB v108 迁移 `replace_rules` 加列 `scopeSource INTEGER NOT NULL DEFAULT 0`（幂等 + 纳入 repair_legacy_columns）；② core 新增**独立 `SourceScopeContext`**（源语境匹配对象=书源名/URL，不复用书名语境的 ScopeContext——语义红线）+ `source_scope_allows/matches/is_excluded`；③ FFI `replaceRuleAdd/Update` 加第 6 个可选参（add 缺省 false / update 未提供=保留）、读 JSON 自动带出、**新增 `applyReplaceRulesToSource(sourceJson, sourceName, sourceUrl)`**（书源导入期替换：启用且 scopeSource 且 pattern 非空的规则按 scope/excludeScope contains 匹配后逐条应用；**规则级失败保留原文不中断导入**，对齐原版 replacementError 语义）；契约 §2.8 方法数 6→**7**、附录 276→**277**、BookApi 口径 273→**274**
- [UI] 替换规则编辑页「书源」勾选解除禁用（随保存落库）；导入钩子覆盖全部四个入口（importFromJson/Url/File 经 SourceImportService 统一挂、importSources 旁路入口单独挂），无命中原样返回

### Test
- 子代理自测与主代理独立复跑一致：`cargo fmt --check` 通过、`cargo test -p legado-db scope_source` **5/5**（迁移/幂等/repair）、`-p legado-core` **792 全过**（含源作用域匹配/排除/失败保留原文用例）、`-p legado-ffi` **348 全过**、`flutter analyze` 无问题、`flutter test` **1441 全过**、`api_contract_test` 7/7
- 设备 E2E（MuMu Test 实例，DB 级证据）：v108 已执行（user_version=108、列在位）；造 scopeSource 规则（scope=起点）→ 导入「起点文学」书源 → ruleBookInfo 被替换（命中）、「阅文集团」书源保持原文（未命中）、两次导入均完整落库不中断
- 附带发现（如实登记）：`legado-js` config_api 三测在**全量并行**时存在全局主题状态跨测污染的偶发失败（`set_injected_theme_mode` 全局态），隔离/当前复跑均绿——存量潜在 flake，与本批无关，登记待修。版本 2.0.247+248

- Contributor: full-stack-engineer + Bridge + QA（主代理 Qoder UI 审核）


## [2.0.246] - 2026-09-13

### Added
- [UI] 新增「字典规则管理」页（差异清单 C2 批2，子代理 full-stack-engineer 交付 + 主代理复验；对齐原版 `DictRuleActivity`）：列表行=规则名 + 启停开关（副行 urlRule）+ 行点编辑弹层（名称/urlRule/showRule，名称必填校验）；长按多选批量 启用/禁用/删除（删除带确认）；拖拽排序（dictRuleReorder 重编号）；FAB 新增；菜单=新增/本地导入（粘贴 JSON）/在线导入（URL）/导入默认（内置 dictRules.json 走 REPLACE 语义）；入口=字典查询页 AppBar「规则管理」+ 设置页同级 tile。启停/排序即时影响词典查询（查询消费启用规则）
- 说明：扫码导入未实现（依赖相机权限链路，登记待办）；本地导入由选文件收敛为粘贴 JSON（功能等价，规避文件选择器平台链路）

### Test
- 子代理自测与主代理独立复跑一致：`flutter analyze` 无问题、`flutter test` **1427 全过**（新增 `dict_rule_screen_test` 8 例：列表渲染/启停/空态/错误态/FAB 必填校验/批量禁用/批量删除带确认/导入默认）
- 设备 E2E（MuMu Test 实例，QA 代理执行）：5 条默认词典源列表 ✓、禁用后查询正常 ✓、拖拽排序退出重进保持 ✓、新建/删除（含确认文案）✓、应用进程全程 0 FATAL/0 E/flutter（crash buffer 仅 uiautomator 工具自身 SIGSEGV，MuMu 已知现象）、冒烟 **7/7 PASSED**。版本 2.0.246+247

- Contributor: full-stack-engineer + UI + QA（主代理 Qoder UI 审核）


## [2.0.245] - 2026-09-13

### Added
- [Rust] 字典规则 FFI 全链路（差异清单 C2 批1，跨轨，子代理 full-stack-engineer 交付 + 主代理复验）：契约新增 **§2.45 字典规则操作（7 方法，加法式）**——`dictRuleList`（空表自动 seed 原版 5 默认源，`ORDER BY sortNumber,id`）/ `dictRuleAdd`（name 重复报错）/ `dictRuleUpdate` / `dictRuleDelete` / `dictRuleSetEnabled` / `dictRuleReorder`（按序重编号，对标原版 upSortNumber）/ `dictRuleImport`（text/url 双通道，GSON 数组/单对象，REPLACE by name，返回导入条数）；附录合计 269→276、BookApi 口径 266→273。**管理页 UI 为批2，本批无用户可见界面变化**
- [Rust] 顺带根治发现页空 `type` 源头：`explore.rs` 纯文本 `::` 解析分支显式置 `type="url"`（2.0.244 已在 Dart 数据入口归一补偿，本次从源头消除空串下发），补单测

### Test
- 子代理自测与主代理独立复跑一致：`cargo fmt --check` 通过、`cargo test -p legado-db dict_rule` **12/12**（新增 reorder/upsert_by_name 用例）、`cargo test -p legado-ffi dict` **13/13**（7 FFI + 导入解析/REPLACE 语义/坏 JSON 用例）、`cargo test -p legado-core parse_explore_url` 10/10、`flutter analyze` 无问题、`flutter test` **1419 全过**（含 mock 往返 3 例 + `api_contract_test` 7 项程序化契约校验）
- `.so` 已按 `build-android.ps1 -Mode release` 重建（aarch64/x86_64，15:28/15:29），`dict_rule_*` 7 符号双 ABI 验证在位。版本 2.0.245+246

- Contributor: full-stack-engineer + Bridge（主代理 Qoder UI 审核）


## [2.0.244] - 2026-09-13

### Fixed
- [UI] 发现页展开区真机恒为零高（设备验收新发现，P1；两处叠加，均与 Rust FFI 无关——USE_MOCK 无 Rust 包仍复现）：① **分节注册丢失**——`_groupExploreC8Sections` 的 else 分支在「首项即非标题项」时只创建分节对象、从不 `sections.add` → 整节被丢弃，sections=[] → 展开区 Column 零高（此 bug 出自 2.0.238 的 C8 实现，widget 测试因直接注入最终 state 未覆盖注册路径而漏网）；② **真机空 `type`**——Rust 纯文本 `::` 解析用 `ExploreCategory::default()` 使 `type=""`，Dart 侧 `?? 'url'` 只兜 null 不兜空串，而分节头判定与 3 列强制都以 `type=='url'` 为门 → chips 退化通栏、分节头不识别（mock 路径省略 type 走构造默认值，故测试全绿而真机异常）。修复：① else 分支补 `sections.add`；② notifier 数据唯一入口加 `_normalizeExploreCategoryTypes` 把空 `type` 归一为 `url`（不改落库源数据，控件项不受影响）；临时诊断探针全部移除

### Test
- 子代理自测与主代理独立复跑一致：`flutter analyze` 无问题、`flutter test` **1416 全过**（新增 `explore_expand_height_test`：以**真机 FFI 形态**（空 type）走真实 notifier 装配路径断言 chips 实高非零 + type 归一——修复了「mock 直接注入 state 测不出」的覆盖缺口）
- 设备复验（MuMu Test 实例，正式非 mock 构建 v2.0.243，smoke 7/7）：展开源卡后 dump 证实 3 列 chips + 通栏分节头渲染（玄幻小说通栏 + 都市/仙侠/修真 各 3 列），零高与全宽行均消除；遗留：Rust `explore.rs` 纯文本分支宜显式置 `type="url"` 从源头根治（登记到下一 Rust 批）。版本 2.0.244+245

- Contributor: full-stack-engineer + UI + QA（主代理 Qoder UI 审核）


## [2.0.243] - 2026-09-13

### Fixed
- [UI] 搜索页红屏锁死（设备验收 D1，P1）：根因 = 搜索结果过滤对话框把 `TextEditingController` 建在 `showDialog` 外并在 future 完成时 dispose，而弹层退出动画期间子树仍挂载（OverlayEntry maintainState），期间重建使 TextField 向已 dispose 的 controller 注册监听 → 异常打断 overlay 子树 unmount、残留 FocusInheritedScope 依赖 → 递归去活时 `'_dependents.isEmpty'` 断言失败（framework.dart:6268），debug 整页红屏。修复：控制器生命周期收敛进有状态弹层 `_ResultFilterDialog`（随 State 建/销），返回值改 `showDialog<String>`；新增回归测试（单轮/确定路径/三轮「筛选→取消→⋮」连做），设备连做 3 次无红屏
- [UI] 替换规则编辑器「作用范围」行窄屏右溢 18px（设备验收 D2）：三勾选由固定 `Row` 改 `Wrap`（宽屏单行形态不变，窄屏自动换行），新增窄屏+字体放大无溢出断言

### Test
- 子代理自测与主代理独立复跑一致：`flutter analyze` 无问题、`flutter test` **1415 全过**（新增 D1 回归 3 例 + D2 回归 1 例）
- 设备复验（MuMu 127.0.0.1:16384，QA 代理执行）：D1 原复现步骤连做 3 次无红屏（截图取证）；D2 黄纹消失、三勾选完整可交互；A2 换源弹层形态与三种关闭方式复核通过。发现页「展开区零高」经 mock 隔离实验（USE_MOCK 无 Rust 包仍复现）确认与 FFI 无关，属布局/动画层独立缺陷另批修复。版本 2.0.243+244

- Contributor: full-stack-engineer + UI + QA（主代理 Qoder UI 审核）


## [2.0.242] - 2026-09-11

### Added
- [UI] 阅读器支持独立「标题字体」（差异清单 C3 收尾，子代理 full-stack-engineer 交付 + 主代理复验）：对齐原版 #1072 `ReadBookConfig.titleFont`（空=跟随正文字体）——`ReaderAdvancedConfig` 加 `titleFont`（键 `titleFont`，与 titleMode/titleSize 同族无前缀）；`PageChrome` 加字段并入 `layoutKey`（变化自动触发重分页）；**测量与渲染同参**：单源函数 `effectiveTitleFontFamily`（reader_page_chrome.dart，生效值=titleFont 非空 ? titleFont : 正文字体）同时注入首屏容量测量（`_computeFirstPageHeight` 标题 TextPainter）与标题渲染 TextStyle；`_refreshFontFamily` 扩展注册标题自定义字体（FontLoader，失败兜底保持）；字体面板「标题字体」行由禁用占位改为可点行（显示字体名/「跟随正文」），`FontScreen` 加 `target` 参数（title/body，默认 body 调用方零改动）

### Test
- 子代理自测与主代理独立复跑一致：`flutter analyze` 无问题、`flutter test` **1411 全过**（新增 `reader_title_font_test` 11 例：持久化三链、测量/渲染同参断言、面板行与路由参数、layoutKey 驱动）
- 顺带修复既有偏差：此前标题不随自定义正文字体（titleFont 空时现在跟随正文字体，用户可感知，测试覆盖）；**滚动模式未接**（`_buildScrollContent` 标题块不在本批范围，仅翻页/排版模式生效——如实登记）；真机字形效果待设备验收。版本 2.0.242+243

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）


## [2.0.241] - 2026-09-11

### Fixed
- [Rust] 替换规则写链路补齐（A3 存量阻塞项，跨轨批次，子代理 full-stack-engineer 交付 + 主代理复验）：`replaceRuleAdd` / `replaceRuleUpdate` 加法式扩参 `group` / `scopeTitle` / `scopeContent` / `excludeScope` / `timeoutMillisecond`（add 缺省=旧行为；update 未提供=保留既有值、传空串=清除 group/excludeScope），使编辑页的 **分组 / 标题·正文作用范围 / 排除范围 / 超时** 真正落库（此前仅 UI 可编辑、保存静默丢弃）。存储与读/应用链路（`replace_rules` upsert + `content_processor` 的 ScopeMode/is_excluded）本就完备，本次只补写侧；C-ABI 签名兼容冻结（新增可选参一律传 `None`）；编辑页「超时」由只读改可编辑（空/非法输入回退 3000ms）

### Test
- 子代理自测与主代理独立复跑一致：`cargo fmt --all -- --check` 通过、`cargo test -p legado-ffi replace_rule` **10/10**（含新增 add/update 带 group/scope/timeout 落库用例）、`flutter analyze` 无问题、`flutter test` **1400 全过**；`.so` 已按 `rust\scriptsuild-android.ps1 -Mode release` 重建（aarch64/x86_64，21:26/21:27），设备实测不再跑旧二进制
- 生成物说明：`frb_generated.*` 经官方 `flutter_legado\scripts\generate-bridge.ps1` 重生成；**FRB 内容哈希只按函数名计算**（主代理查上游 codegen 源码确认：`generate_content_hash` 仅哈希 `namespaced_name_rust_style` 列表，源码内仍留 `TODO can compute hash for more things`），故纯加法扩参哈希不变（-56430457）属预期，非手改产物
- 仍受阻（不在本批）：`scopeSource`（书源作用范围）Dart/Rust/DB/FFI 全链路缺失；`@js:` 替换预览 Pure 侧无引擎。版本 2.0.241+242

- Contributor: full-stack-engineer + Bridge（主代理 Qoder UI 审核）


## [2.0.240] - 2026-09-11

### Added
- [UI] 搜索页顶栏补齐三钮（差异清单 A1 **双基准重开项**，子代理 full-stack-engineer 交付 + 主代理复验）：设置⚙→书源管理、定位→搜索范围、筛选（实心绿两态）→搜索结果过滤；**每钮接既有能力**（与 ⋮ 菜单对应项调同一实现，避免两套代码），⋮ 菜单按「不丢能力」保留全量并补上原先缺失的「搜索结果过滤」项
- [UI] 「搜索结果过滤」落点（原版 `filterSearchResults` 语义）：结果列表按屏蔽词排除（命中书名/作者/kind 任一即过滤，忽略英文大小写；空词表=不过滤），词表经 `PreferKey.searchResultFilter` 持久化；空态判定收敛为「无结果 / 被精准隐藏 / 被过滤隐藏」三态

### Test
- 子代理自测与主代理独立复跑一致：`flutter analyze` 无问题、`flutter test` **1400 全过**（新增 `search_appbar_buttons_test` 4 例）；另修正 `search_screen_scroll_test` 两处 mock 过期（批次B 给 `searchMultiStream` 加 `page` 后未同步匹配 → mocktail 返 null），属既有问题、非本批引入
- 说明：三钮语义为「图标 + 原版菜单能力反查」推导（参考版 Compose 界面合成点击不响应，无法直接点击取证），已登记为推导依据；因每钮均映射既有能力且 ⋮ 保留全量，误映射风险不影响能力完整性。版本 2.0.240+241

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）


## [2.0.239] - 2026-09-11

### Changed
- [UI] 换源界面由「整页」改「底部弹层」（差异清单 A2，子代理 full-stack-engineer 交付 + 复核，主代理复验）：`AppRoutes.changeSource` 改由新增的 `_ChangeSourceSheetRoute`（非不透明 + black54 遮罩 + 底部滑入/滑出转场）承载，**5 处调用方零改动**（阅读器顶栏/菜单/翻页区、听书页、书籍详情）；弹层形态对齐双基准——85% 高面板 + 圆角 16 + 32×4 把手、点遮罩/下滑（阈值 160px 或甩速 800px/s，未达阈值弹性回位）/系统返回均可关闭；原版 `tool_bar`/`refresh_progress_bar`/`recycler_view`/`ll_bottom_bar` 四区与参考版源卡（当前源 chip + 勾标高亮）对应保留

### Test
- 子代理两轮均在限内自测：`flutter analyze` No issues、`flutter test` 1395 全过（换源屏 12 例，含 A2 形态 4 例：非不透明路由、把手+85% 几何、点遮罩关闭、下滑超阈值关闭/未达阈值回弹）；主代理独立复跑一致，并额外核对 `routes.dart` 变更性质——路由键 53→55（新增两条属弹层路由），**无键丢失**，非空白差异仅 8 行（其余为 8sp→4sp 缩进重排）
- R1 能力零回归（子代理逐项给出 file:line）：流式搜索进度、变量链 applySource→newBookUrl→pop、👍/👎 评分、长按菜单（置顶/置底/编辑/禁用/删除）、底部栏（当前源点按滚动定位 + 滚顶/滚底）、筛选输入、下拉刷新与滚动加载、高级选项全链
- 设备侧待验（如实登记）：拖拽手感与滑出收尾动画、black54 遮罩观感、前页在非不透明路由下保持可见的转场效果 —— widget 测试只覆盖几何与关闭逻辑。版本 2.0.239+240

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）


## [2.0.238] - 2026-09-11

### Changed
- [UI] 发现页形态对齐（差异清单 A4 + C8，子代理 full-stack-engineer 交付 + 主代理复验）：①主页签顶栏文件夹图标经核实其唯一功能=分组筛选（与原版 `main_explore.xml` 的 `menu_group` 语义等价）→ **无损收编进 ⋮ 菜单**，顶栏形态改「搜索 + ⋮」对齐双基准；②源行改**卡片底**（圆角 12 + onSurface 10% 浅填充，对齐原版 `bg_find_book_group`），行 = 源名 + 旋转 chevron；③展开区子项排布改**分节 3 列 chips**（按空 URL 头项分节，对齐重构版 `groupExploreSections`；URL 类 chip 内存态覆写 `layoutFlexBasisPercent=1/3`，`basis≥1` 通栏项与 toggle/select/button/text 控件项保留原宽度与行为），点击进书单链路不变

### Test
- 子代理自测：analyze No issues、flutter test 1389 全过（新增 `explore_screen_c8_test` 4 用例：分节 3 列网格/chip 宽度/3 行顶对齐、⋮ 收编、卡片底样式、点击链路）；主代理独立复跑一致（analyze 无问题、1389 全过）
- 说明：原版为纯数据驱动 Flexbox（无硬编码 3 列），「3 列」形态取自参考版 → 按双基准取参考版形态，同时保留原版数据驱动逃生门（通栏/控件项不受影响）。版本 2.0.238+239

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）


## [2.0.237] - 2026-09-11

### Changed
- [UI] 替换净化规则编辑器由弹窗改为整页（差异清单 A3，子代理 full-stack-engineer 交付 + 主代理审核）：字段顺序对齐原版 `ReplaceEditActivity` / `activity_replace_edit.xml`——规则名称 → 分组（下拉 + 自定义）→ 匹配规则（含「使用正则表达式」勾选 + 帮助图标，复用 regexHelp 帮助弹层）→ 替换为 → 作用范围三勾选（标题 · 书源 · 正文）→ 特定范围 → 排除范围 → 超时 → 预览输入 → 预览输出；顶栏 = 醒目「保存」+ ⋮ 菜单（全屏编辑 / 复制规则 / 粘贴规则，走系统剪贴板 JSON）；预览 250ms 防抖，正则按 `replaceAllMapped` 手动展开 `$$`/`$&`/`$1-9`/`${name}` 对齐 Java `Matcher.replaceAll` 语义，`@js:` 规则诚实提示 Pure 侧无 JS 引擎；列表行编辑 / FAB 新增 / 正则预填入口统一走新页（路由 `/replace_rule_edit`），旧弹窗表单删除

### Test
- 子代理自测：`flutter analyze` No issues、`flutter test` 1385 全过；主代理独立复跑结果一致（含新增编辑页 12 用例、入口页重写 4 用例）
- **存量阻塞项（如实登记，非本批引入）**：① FFI 写接口窄——`replaceRuleAdd` 只写 name/pattern/replacement/isRegex/scope、`replaceRuleUpdate` 追加 isEnabled，故 分组 / 标题·正文作用范围 / 排除范围 / 超时 的编辑**保存后不落库**（旧弹窗同样如此；Rust 侧读与应用链路 `content_processor` 齐全，仅写签名窄）→ 待跨轨补齐；② `scopeSource`（书源作用范围）在 Dart/Rust/DB/FFI 全链路缺失 → 编辑页以禁用行 +「暂不支持」诚实标注；③ `@js:` 替换预览 Pure 侧无引擎，输出区提示不可用

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）


## [2.0.236] - 2026-09-11

### Added
- [UI] 正文斜体开关（差异清单 C3 **双基准回补**）：参考版行内字体面板含「斜体」（原版开源代码全仓无斜体配置字段）→ 按双基准补齐。新增 `ReaderAdvancedConfig.italic`（键 `reader_adv_italic`，默认关）并在排版承重链上贯通：`ParagraphConfig.fontStyle` 与既有 `fontWeight` 同路注入**测量与渲染两侧**（`_fontStyleFor` 同源调用、分页重排判定纳入 italic），保证分页测量与渲染同参不漂移；Tt 行内面板新增「斜体」开关行

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1372 全过（新增 `reader_italic_style_test` 2 用例：ParagraphConfig 携带/复制 fontStyle、正文渲染 TextStyle 落地 fontStyle；面板用例扩展斜体持久化断言）；5556 实机——面板出现「斜体」开关，开启后 `reader_adv_italic=true` 落盘、再关回落 false；版本 2.0.236+237

- Contributor: Qoder UI


## [2.0.235] - 2026-09-11

### Added
- [UI] 搜索正文新增「搜索范围」三档（差异清单 C4 **双基准回补**）：参考版有「仅本书」chip、重构版 `SearchContentPrefsPort` 有完整三档语义 → 搜索选项菜单在「替换/正则」下新增分隔与三档范围——**仅当前章**（只搜阅读器当前章）/ **仅本书（已缓存）**（当前章 + 已缓存章节，对齐参考版「仅本书」范围）/ **本书 + 网络**（未缓存章节联网抓取，默认档=我方原有行为不变）。切换范围即按新选项重搜；已缓存章节集合经既有 `listCachedChapterUrls` 取得，未新增 FFI

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1372 全过；5556 实机 A/B——阅读器跳到第1章后选「仅当前章」搜 `QQ` → 「未找到」（第1章无此词）；切「本书 + 网络」→ 「共 1 处匹配」，切换即时重搜生效；版本 2.0.235+236

- Contributor: Qoder UI


## [2.0.234] - 2026-09-11

### Changed
- [UI] 书源管理行恢复启用状态文字标签（差异清单 C1，**双基准口径修订**）：用户明确差异清单功能基准**同时参考原版与参考版**。驱动参考版实机取证（`io.legato.kazusa` 书源管理列表）确认其 Switch 自带「开启」文案；原版仅有 Switch 无文字。按双基准取参考版形态、文案本地化为中文——行内恢复「开启/关闭」标签（替换 2.0.232 中按单一原版口径移除的英文 ON/OFF），复选框常显与行尾发现状态角标维持不变

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1372 全过；5556 实机验证——书源管理列表 7 行语义树均为「源名（分组） 开启」，开关与复选框数量不变（7/7）；版本 2.0.234+235

- Contributor: Qoder UI


## [2.0.233] - 2026-09-11

### Changed
- [UI] 阅读界面「Tt」入口由跳转整页字体管理改为行内字体面板（差异清单 C3，子代理 full-stack-engineer 交付 + 主代理审核）：点 Tt 小卡在设置弹层内直接展开面板——正文字体（「选择字体」仍进既有字体管理页，链路不丢失）/ 正文字距滑条（em -0.5~1.0，对齐原版 `(p-50)/100` 语义）/ 首行缩进（按我方字段 0-3 档）/ 标题字体（原版 #1072 titleFont，我方暂无配置字段，禁用行诚实标注「跟随正文」）/ 字重（中·粗·细，对齐原版 TextFontWeightConverter）/ 简繁转换（0 关闭/1 繁→简/2 简→繁，接既有 FFI `setChineseConvertType`，变更后重载正文对齐原版 UP_CONFIG[5]）；全部控件经既有 `_commitAdv` 持久化并推送共享配置，未新增数据链。**「斜体」按红线不放入**：源码核实开源版全仓无斜体配置字段（为参考版自有增强）

### Test
- 子代理自测：flutter analyze 无问题、flutter test 全绿；主代理独立复核：analyze 无问题 + flutter test 1370 全过（含子代理新增 `reader_font_panel_test` 2 用例，断言「斜体」不存在以防回潮）；5556 实机——Tt 点按展开面板，「字体/选择字体/正文字体：默认字体/正文字距 0.00/首行缩进：二字符/标题字体：跟随正文/字重/简繁转换」齐备，再点收起；版本 2.0.233+234

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）


## [2.0.232] - 2026-09-11

### Changed
- [UI] 书源管理行形态对齐原版（差异清单 C1，C1 子代理通道超时后由主代理接手）：源码核实——原版 `item_book_source.xml` 的 `cb_book_source` 是**常显复选框（复选框与源名同排，勾选即多选）**，且原版**没有**行内 ON/OFF 文字（启用态由 `swt_enabled` 开关呈现）。故：①行首补常显复选框（勾选自动进入批量模式，与底部批量栏计数联动，长按进批量模式的既有行为保留）；②移除我方自创的 ON/OFF 文字标签；③行尾发现状态点（绿=发现已启用/红=未启用/无发现规则隐藏）为既有实现，本就与原版 `iv_explore` 语义一致，未改；类型注记属参考版特有形态（原版无对应控件），按红线不加

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1370 全过；5556 实机验证——书源管理列表 7 行复选框常显、ON/OFF 文本 0 处、开关 7 个；勾选第 1 行即进入批量模式，底部栏显示「已选择 1 项 / 全选（1/1026）/ 反选 / 删除」，退出批量模式正常；版本 2.0.232+233

- Contributor: Qoder UI（子代理通道超时转主代理）


## [2.0.231] - 2026-09-11

### Added
- [UI] 自动翻页运行时浮条（差异清单 C10，形态对齐参考版「即开即调」）：自动翻页进行中、菜单未展开且非朗读态时，浮条贴附正文底部——显示当前间隔与「− / ＋」速度步进（步进 5 秒，夹取 3~120 秒，与定时器范围一致），并提供 目录 / 停止 / 设置 三个快捷入口；运行时开关沿用既有 `_toggleAutoPage`，与「界面」弹层里的自动翻页配置卡并存（配置态与运行态各司其职，不新开配置面）

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1368 全过（含新增 `auto_turn_panel_test` 6 用例：间隔展示/步进上下限夹取/三入口回调）；5556 实机验证——菜单点「自动翻页」后浮条出现（自动翻页｜10 秒｜目录/停止/设置），点「加快翻页」间隔 10→15 秒，点「停止自动翻页」后浮条消失；版本 2.0.231+232

- Contributor: Qoder UI


## [2.0.230] - 2026-09-11

### Added
- [UI] 主题设置页新增「外观预览」模型（差异清单 C6，形态对齐参考版「外观」页顶部手机预览）：用当前 ColorScheme 绘制迷你手机——顶栏 = primary、底色 = surface、文字条 = onSurface/onSurfaceVariant、卡片 = secondaryContainer、强调件 = primary 胶囊；右侧标注当前配色名（内置调色板中文名，自定义主色生效时标「自定义配色」，口径同 app.dart 自定义色优先）。主题/调色板切换后本页重建即刷新，无需额外监听

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1362 全过（本项无新增用例，控件为纯展示）；5556 实机验证：外观页顶部显示「外观预览 / 当前：柠檬 / 切换主题或调色板后，此预览与全局界面同步更新」，其下内置主题网格正常；版本 2.0.230+231

- Contributor: Qoder UI

## [2.0.229] - 2026-09-11

### Changed
- [UI] 搜索正文页补「替换 / 正则」搜索选项（差异清单 C4，原版对齐）：源码核实修正了差异清单原登记项——原版 `SearchContentActivity` 的 `content_search` 菜单只有「替换 / 正则」两项，**没有**范围开关（原版固定搜索当前书全文），参考版的「仅本书」chip 与重构版三项范围菜单均属各自特有形态，按重构红线不新增范围控制。本次按原版补两项：顶栏「搜索选项」溢出菜单——「替换」切换正文口径（开=应用替换净化 `getChapterContent`，关=原始正文 `getChapterContentRaw`，默认关与 Android 默认一致）、「正则」按 RegExp 匹配（非法表达式静默空结果，对齐原版语义）；命中区间抽为纯函数 `findContentHits` 供搜索与高亮共用

### Test
- 主代理自实现并复核：flutter analyze 无问题；flutter test 1362 全过（含新增 `search_content_hits_test` 7 用例：普通/正则/大小写/限流/非法正则/空关键词）；5556 实机 A/B 验证——正则开时关键词 `Q+` 命中 1 处（正则匹配 `QQ`）、关闭后同关键词「未找到」且切换即按新选项重搜，非按钮区域不再透传；版本 2.0.229+230

- Contributor: Qoder UI

## [2.0.228] - 2026-09-11

### Fixed
- [Rust] 修复阅读统计「每日时长」放大 1000 倍（差异清单 C5 验收时发现，追溯到 2026-08-29 引入的写路径）：根因 = `upsert_read_record` 把毫秒增量写进契约声明为秒的 `readRecordDaily.durationSeconds` 列，用户可见面为热力图「每日时长」配色全天饱和、首页今日目标表盘恒满、按天视图显示「75天17小时」级时长。修复：写路径改按整秒差值入账（`read_time/1000 − old_read_time/1000`，避免频繁小增量被反复截断丢秒）；新增 DB v107 迁移 `Migration106To107` 把存量行整除 1000 归一（user_version 门禁保证仅执行一次，SCHEMA_VERSION 106→107，懒建表缺失时跳过）；契约 `docs/API_CONTRACT.md` §2.12 与更新记录、重构计划 P3-7 同步登记

### Test
- Rust 门禁：`cargo test -p legado-db` 301 项全过（含新增 `daily_seconds_v107` 归一/幂等/懒建表跳过 2 用例）、`cargo test -p legado-ffi` read_record 8 项全过（每日聚合用例改为断言整秒入账）、`cargo fmt --check` 与 `cargo clippy` 零告警
- 实机（5556，`.so` 经 build-android.ps1 release 重建）：①归一——迁移后 user_version=107，2026-09-06 行 6,541,627→6,541（按天视图读作 1小时49分钟）；②写入端到端——阅读约 51 秒后当日行 +51 秒，与该书 readTime 增量 51,772ms 的整秒差值精确吻合；版本 2.0.228+229

- Contributor: Qoder + Bridge

## [2.0.227] - 2026-09-11

### Added
- [UI] 阅读记录页新增「按天」视图与累计成就卡（差异清单登记项 C5）：顶部总时长头改为成就卡（已读 N 本 / 累计时长，清空入口沿用原确认流程）；新增 按书/按天 分段切换——按天视图按 今天/昨天/更早 分组呈现每日时长时间线（数据源 readRecordDailyList 既有契约，纯函数分组可单测），按书清单与阅读热力图保持原样

### Test
- 主代理自实现并独立复核：flutter analyze 无问题；flutter test 1355 全过（含分组纯函数 3 用例）；5556 实机验证：成就卡（已读 13 本 / 累计 4小时9分钟30秒）、按书/按天 切换、按天分组（昨天 2026-09-10 16分钟35秒 / 更早 6 天）渲染正确；版本 2.0.227+228

- Contributor: Qoder UI

## [2.0.226] - 2026-09-11

### Changed
- [UI] 书籍详情页形态对齐参考版（差异清单登记项 B1，子代理 full-stack-engineer 交付）：头部改「封面左置 96×128 + 信息右置」两栏（书名/作者/来源行，搜索与原书源 JS 回调行为不变）；分类与字数标签改为左对齐标签行；新增「在读/最新/共N章」三行强调排版；操作宫格由五格收为四格（加入书架切换/目录/换源/阅读记录），「分组」收进顶栏 ⋮ 菜单（入口与行为不变）；移除底部固定双按钮栏，阅读入口改为右下浮动「阅读」胶囊

### Test
- 主代理独立复核：flutter analyze 无问题；flutter test 1355 全过（含同步调整的详情页断言）；5556 实机验证：两栏头部（书名/作者/来源：玄幻阁 + 换源钮）、标签行（都市 288.3万）、三行（在读第340章 / 最新 / 共 500 章）、四宫格、浮动「继续阅读」胶囊、⋮ 内「设置分组」均在位；版本 2.0.226+227

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）

## [2.0.225] - 2026-09-10

### Added
- [UI] 备份与恢复页新增「测试配置」行（差异清单登记项 C7，子代理 full-stack-engineer 实现）：点击对当前 WebDAV 配置发起连通性探测——PROPFIND(Depth:0) + 已填账号密码 Basic Auth，5s 超时；200/207 成功、401/403 提示认证失败、其他非 2xx/超时给出原因摘要；行尾状态（未测试/测试中/✓连接成功/✗失败），测试期间防重入；纯客户端探测不落库、不改既有保存/同步逻辑

### Test
- 主代理独立复核：flutter analyze 无问题；flutter test 1352 全过（含子代理新增 2 用例）；实机（emulator-5554）验证：行渲染正确、空地址提示「请先填写服务器地址」、非 http 提示「需要以 http(s):// 开头」两分支均通过；版本 2.0.225+226

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）

## [2.0.224] - 2026-09-09

### Added
- [UI] JS 书源编辑器新增「规则语法帮助」入口与帮助弹层（差异清单登记项 C9，子代理 full-stack-engineer 实现）：顶栏 ? 钮 → 底部弹层（壳沿用阅读提示信息规范：把手+DraggableScrollableSheet），三块静态速查——阅读 3.0 源规则说明（搜索/发现/详情/目录/正文各一句 + Wiki 链接可点、失败降级复制）/ @规则语法（@css:/@json:/@js:/@XPath: + ||/&&/%%/## 组合符 + 行内示例）/ jsLib 与内置变量（java.ajax、book、baseUrl 等）；内容全为编译期常量，零网络、零新依赖

### Test
- 主代理独立复核：flutter analyze 无问题；flutter test 1350 全过（含子代理新增 source_rule_help_sheet_test）；5556 实机验证顶栏钮与弹层三块渲染；版本 2.0.224+225

- Contributor: full-stack-engineer + UI（主代理 Qoder UI 审核）

## [2.0.223] - 2026-09-08

### Fixed
- [UI] 章节切换闪现正文根治（用户反馈：动画衔接后切换中闪现正文内容，原版/重构版无此问题）——真机探针逐帧还原后定位并修复三处根因：
  ① **旧章快照位图残留**：相邻章预览被清空时其位图未作废，章末快转会把上一个已看过的页面位图当作"下一章"滑入（可见"闪现正文"）；修复=预览变更即销毁位图 + 使用侧要求"预览存在且位图存在"双校验；
  ② **预载从未生效**：预载误用 `getChapterContent`（仅读本地缓存、不取网，调用挂起）——改用与阅读器同链路的 `getChapterContentFull`（缓存+网络合并）；
  ③ **预载触发过晚**：仅"末屏/首屏"触发，网络取章（实测 >1.4s）来不及；改为**分页即预载两侧邻章**（对齐原版三章窗口），窗口触发保留兜底。另：预览页分页改为按**目标章自己的标题**计算首页容量（与落地实际分页严格同参，防切换瞬间正文重排闪动）
- 真机探针实证：章边界 turn 时 `chapNext=true/true`（预览+位图就位→走动画路径）、承接态生效、两方向预载 `fetched→ok`

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 探针序列全链路验证；版本 2.0.223+224

- Contributor: Qoder UI

## [2.0.222] - 2026-09-08

### Fixed
- [UI] 章边界翻页动画补全（用户反馈：翻到章末/下一章无动画直接闪现）：移植版翻页系统此前在章边界因"无邻页快照"走瞬时填充；现**预载相邻章边界页**参与快照与画笔——末屏预载下一章首屏、首屏预载上一章末屏（复用同参分页引擎，后台异步、失败静默退化为瞬时）；章边界 turn 完成后进入**承接态**（遮罩保留、live 层显示预载页至新章落地），消除闪现；四模式（滑动/覆盖/仿真）章边界均可动画

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 录屏实证：9/9 章末点击 → 中间过渡帧存在 → 落点下一章 1/10
- 版本 2.0.222+223

- Contributor: Qoder UI

## [2.0.221] - 2026-09-08

### Changed
- [UI] **翻页动画层整体重构**（用户反馈①"深度按原版与重构版源码重构每一个翻页动画"）：移植重构版翻页系统（`Projects/legado_flutter/lib/features/reader/turn/`，7 文件入仓 `lib/src/widgets/reader/turn/`）—— 页面快照缓存（RepaintBoundary.toImage 双缓冲 prev/cur/next）+ 拖拽/结算控制器（数学对齐 Jingshiro PageDelegate.startScroll）+ 覆绘制画笔（Slide/Cover/Simulation 三画笔逐行对应原版五委托 onDraw 变换：滑动双向轮播、覆盖裁剪推进+右侧 30px 阴影、仿真卷曲 cornerXY 数学）。滑动/仿真/覆盖/无动画四模式统一走 `ReaderTurnView`；滚动模式保留原纵向实现。旧动画层（PageView + AnimatedSwitcher 章节过渡 + 控制器重建补丁）整体移除
- [UI] 顶栏信息下方新增**五个圆形浮动快捷钮**：搜索 / 目录 / 朗读 / 设置 / 换源（对齐参考版浮动图标，用户反馈②）

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机：滑动拖动/右缘点击/左缘后退/跨章边界均通过（9/9→下一章 1/9），仿真模式切换无异常、无 flutter 异常日志；版本 2.0.221+222

- Contributor: Qoder UI

## [2.0.220] - 2026-09-08

### Fixed
- [UI] 翻页动画语义对齐原版源码（用户反馈①）：核对上游 `legado-upstream` 的 `SlidePageDelegate`（滑动=双向轮播：前进新页自右进+旧页同时左移；后退旧页右移+上页自左进）——我方滑动/仿真模式的章节过渡此前只动进入侧、另一侧静止，章节边界观感与页内滑动不一致；现改**双向轮播**，章节边界与页内翻页动画连续一致。覆盖模式维持原版 CoverPageDelegate 语义（新页右进覆盖旧页/后退旧页右移露出新页）

### Changed
- [UI] 头部信息移入**顶栏菜单**（用户反馈②）：章节名+书源徽标+章节链接现显示于菜单顶部工具行下方（章名+徽标同排、链接第二行，书源名取 Book.originName）；**正文页移除**头部信息块（含此前章首页大标题附加与章中页紧凑头部），恢复原生正文排版

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机确认顶栏菜单三行信息块与正文干净回退；版本 2.0.220+221

- Contributor: Qoder UI

## [2.0.219] - 2026-09-08

### Fixed
- [UI] 返回（后退）切换动画根治（用户反馈①）：页面/章节过渡包装的层叠顺序此前**写死「新页在上」**——后退时旧页反向滑出的动画被上层静止新页完全遮挡，观感为瞬间切换（前进正常，与反馈吻合）；现按方向翻转层叠：前进新页在上（覆盖/滑入），后退旧页在上（抽离/滑出可见）。滑动/仿真章节过渡与覆盖模式两处同修
- [UI] 头部信息补齐（用户反馈②）：此前章名+书源徽标+章节链接仅**章首页**渲染，章中间页无任何头部信息；现**每页渲染**——章首页保持大标题版，其余页为紧凑两行头部（章名+书源徽标 / 章节链接）；书源名优先取 Book.originName（同步可靠），异步解析兜底

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机：章中页头部两行可见、上一章直落末页回归通过；版本 2.0.219+220

- Contributor: Qoder UI

## [2.0.218] - 2026-09-08

### Fixed
- [UI] 上一章切换动画闪跳根治（用户反馈③）：根因=PageView 共享控制器跨章残留旧页码，新章首帧显示旧页码内容、postFrame 才跳目标页；改为**切章时重建控制器并以已解析目标页为 initialPage**（含 prevChapter 哨兵末页），新章首帧即正确页；旧控制器随出栈 Pager 过渡后销毁；顺带修复重建插入点早于页码解析导致的「上一章停在第 1 页」回归
- [UI] 圆形章节钮去掉按压水波纹/高亮（用户反馈②：圆形箭头内阴影）

### Changed
- [UI] 阅读菜单顶栏补**书名**（用户反馈④）；阅读页首屏头部补**章节链接行**与**书源名徽标**（章名+徽标同排、链接第二行，对齐参照态）

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机：上一章直落末页 9/9、首屏头部三件套可见、圆形钮无墨迹；版本 2.0.218+219

- Contributor: Qoder UI

## [2.0.217] - 2026-09-08

### Changed
- [UI] 阅读菜单顶栏移至**屏幕顶部**（用户反馈①）：← 居左，换源/刷新正文/缓存当前章/更多 居右——实机抓取原版 legado 阅读器顶栏布局为基准实施
- [UI] 章节滑条两端改**圆形按钮 + 左右箭头**（用户反馈②，替换上下箭头）
- [UI] 章节直跳动画修复（用户反馈③）：滑条跨多章拖动/章节直跳改瞬时切换，避免拖动过程中每刻度触发 300ms 整章过渡形成动画级联闪烁；相邻章（±1）与页内翻页保留 300ms 过渡

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机确认顶栏置顶/圆形左右钮/滑条跳章；版本 2.0.217+218

- Contributor: Qoder UI

## [2.0.216] - 2026-09-08

### Changed
- [UI] 阅读菜单顶栏按参考版改造（用户反馈②）：移除书名/章名胶囊，改为 返回/换源/刷新正文/缓存当前章/更多 五钮（对齐参考版顶栏构成）
- [UI] 阅读菜单章节滑条行对齐参考版（用户反馈③）：两端改**圆形按钮+上下双箭头**（章节上/下调整语义，避免左右箭头被读作翻页）；滑条改 M3 手柄样式（圆角矩钮）+ divisions 点刻轨道

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机截图确认顶栏五钮/圆形上下钮/M3 点刻滑条；版本 2.0.216+217

- Contributor: Qoder UI

## [2.0.215] - 2026-09-08

### Changed
- [UI] 阅读菜单底部面板按参考版重排（用户截图对照）：行序=标题行→亮度条→章节滑条（两侧箭头，替换上/下一章文字钮）→**可横滑五项目标行**
  - 第 1 页：章节梗概 / AI 改写 / 全文搜索 / 自动翻页 / 目录（对齐参考版）
  - 第 2 页：朗读 / 界面 / 替换 / 更多（保留功能入口）
  - 章节梗概与 AI 改写为已授权 AI 占位按钮（占位弹层说明服务后接通）
  - 移除旧的「图标行 + 全文搜索 pill + 底部文字行」三块冗余结构

### Test
- flutter analyze 无问题；flutter test 1349 全过；5556 实机 uiautomator 转储确认新面板文本项；版本 2.0.215+216

- Contributor: Qoder UI

## [2.0.214] - 2026-09-08

### Changed
- [UI] 正文长按菜单按用户裁决 A 对齐参考版浮窗：长按段落在按压点浮出工具条（复制/分享/浏览器/朗读/书签/更多），点击浮条外收起；「更多」打开保留的段落选区面板（替换/高亮/词典/搜正文/精细选区等增强动作不丢失）
- 实现说明：SelectionArea 在阅读器 PageView 手势栈下长按不触发（探针实证父级赢得竞技场），故采用长按点 Overlay 浮条方案，行为确定

### Test
- 新增 reader_selection_toolbar_test（浮条出现+动作项）；flutter analyze 无问题；flutter test 1349 全过；5556 实机验证浮窗形态
- 版本 2.0.214+215

- Contributor: Qoder UI

## [2.0.213] - 2026-09-08

### Changed
- [UI] 目录页头部对齐参考版：章名大标题 + 「当前章 / 总章数」进度行（此前为书名；总章数优先取实际加载章节数）
- RSS 源瓦片导航复核：https 源经内置浏览器正常打开 ✅，自定义 scheme 源给出失败反馈（上批），行为符合设计

### Test
- flutter analyze 无问题；flutter test 1348 全过；5556 实机截图验证目录头部
- 版本 2.0.213+214

- Contributor: Qoder UI

## [2.0.212] - 2026-09-08

### Changed
- [UI] 新增「设置主页」（集中化分组入口，对齐参考版设置主页结构）：外观/高级/阅读界面/备份与恢复/缓存管理/书源管理/定时任务/字体管理/关于 九组直达（封面设置/AI 设置/翻译设置随对应功能批次补位）
- [UI] 我的页重排：原「备份与恢复/主题设置/其他设置」三入口收敛为单一「设置」入口进设置主页（对齐参考版我的页「设置」项）

### Test
- settings_test 更新集中化两级导航用例；flutter analyze 无问题；flutter test 1348 全过
- 版本 2.0.212+213

- Contributor: Qoder UI

## [2.0.211] - 2026-09-08

### Changed
- [UI] 搜索历史改整行卡形态（对齐参考版：行左关键词、行右 × 单删、点击行搜索，替代原流式 chip）
- [UI] 目录页章节字数改胶囊 chip（对齐参考版「2553字」形态）

### Test
- flutter analyze 无问题；flutter test 1348 全过
- 版本 2.0.211+212

- Contributor: Qoder UI

## [2.0.210] - 2026-09-08

### Changed
- [UI] 新增「首页」页签（对齐参考版五页签结构）：最近阅读卡（封面/进度，点击续读）+ 累计阅读统计双卡（本数/总时长）+ 今日阅读目标半圆表盘（目标分钟可编辑，默认 30 分钟，数据源 readRecordDailyList）
- [UI] 其他设置「默认主页」新增「首页」选项（默认仍为书架，语义不变）
- 首页模块管理（自定义集/书源模块）为参考版深功能，登记后续批次

### Test
- home_navigation_test 更新为五页签结构并新增首页页签用例；md3 验收矩阵底栏项数 2~5
- flutter analyze 无问题；flutter test 1348 全过
- 版本 2.0.210+211

- Contributor: Qoder UI

## [2.0.209] - 2026-09-08

### Changed
- [UI] 我的页新增「缓存管理」入口（对齐参考版其它组；页面复用既有离线缓存页，此前入口仅在书架菜单）
- 差异清单勘误两项：书架菜单「导出书单/导入书单/日志」经复核**均已实现**（批四误读）；缓存管理页**已存在**（原评估"缺整页"系漏查离线缓存入口），真实差距仅我的页入口（本批闭环）

### Test
- flutter analyze 无问题；flutter test 1347 全过
- 版本 2.0.209+210

- Contributor: Qoder UI

## [2.0.208] - 2026-09-08

### Changed
- [UI] 搜索结果页新增多源实时进度胶囊「结果 N · 进度 X/Y」（对齐参考版，数据复用既有 searchedCount/totalCount，搜索后常驻）
- [UI] 目录页新增 FAB 展开菜单（对齐参考版）：定位至当前阅读 / 移至顶部 / 移至底部 / 一键缓存（自当前章到末章入队，复用 cacheDownloadStart）；仅目录 Tab 显示

### Test
- 5556 实测：搜索胶囊（结果 1 · 进度 2/2）、FAB 四项展开、一键缓存 SnackBar 入队均通过
- flutter analyze 无问题；flutter test 1347 全过
- 版本 2.0.208+209

- Contributor: Qoder UI

## [2.0.207] - 2026-09-08

### Fixed
- [UI] 我的页「高亮标注」条目重复出现两次——settings_screen 移除重复 tile
- [UI] 订阅源瓦片点击无反应——默认源「小说拾遗」URL 为自定义 scheme（snssdk1128://），无应用可处理时 launchUrl 异常被静默吞掉，现失败弹出「无法打开链接」SnackBar 反馈
- [UI] 目录页书签空态对齐参考版颜文字彩蛋（(╮_╰) 暂无书签，授权口径内）

### Changed
- 差异清单勘误：朗读语速「跟随系统/手动」为设计内显式切换按钮（对标原版 cbTtsFollowSystem），撤回此前误判疑点；docs/UI_SCREEN_DIFF_INVENTORY_20260907.md 修复状态同步

### Test
- flutter analyze 无问题；flutter test 1347 全过
- 版本 2.0.207+208

- Contributor: Qoder UI

## [2.0.206] - 2026-09-06

### Fixed
- [UI] 滑动/仿真模式切章无过渡动画——此前仅 cover 模式有章节过渡，滑动/仿真为 PageView 瞬跳；补章节级 AnimatedSwitcher 整屏滑动过渡（方向按章号比较），章内翻页不受影响；章节过渡期新旧 Pager 短暂双挂载同一控制器，jumpToPage/animateToPage 的 position.single 断言会崩，程序化翻页改走 _jumpLatestScreen 直跳最新挂载（顺带修双页模式 postFrame 跳页的屏索引换算）
- [UI] 阅读界面弹层背景 chips 改为颜色预览卡（chip 底色即背景色，对齐参考版实拍）

### Test
- 5556 录屏/连拍实证：cover 切章滑入正常（上一批修复生效）、滑动模式上一章/下一章过渡生效且方向正确（326 末页 ↔ 327 首页）
- flutter analyze 无问题；flutter test 1347 全过；版本 2.0.206+207

- Contributor: Qoder UI

## [2.0.205] - 2026-09-06

### Changed
- [UI] 阅读界面弹层一比一对齐参考版四页签结构——头部圆形返回按钮 + 「阅读界面」标题；底部页签 全局/菜单/信息/更多；全局页 = 字号步进器（- 值 +）+ 独立 Tt 字体小卡、背景卡（长按自定义 + 月亮夜间切换 + 自定义/预设 chips 主色描边选中）、翻页动画行（当前值 + 独立图标小卡）；菜单页 = 自动翻页/点击区域/亮度控制；信息页 = 阅读提示信息；更多页 = 行距/字重/字体字距缩进段距/更多配置/页面边距/共用布局

### Test
- flutter analyze 无问题；flutter test 1347 全过（新增 reader_settings_sheet_test 四页签结构回归）；5556 模拟器实测弹层截图比对参考版通过
- 版本 2.0.205+206

- Contributor: Qoder UI

## [2.0.204] - 2026-09-06

### Fixed
- [UI] 正文行尾吞字根治——排版引擎测量与渲染同源：整段 TextPainter.layout + getBoxesForSelection 逐字盒宽（替换逐字单独测量），并合并 DefaultTextStyle 与 textScaler 与渲染侧同参；ZhLayout 压缩标点行（"。"等按原版语义允许超宽、渲染端无字形压缩）新增行宽安全网重排。探针实证：无安全网时压缩行宽 60 > 可用宽 50（超一个字宽被 ClipRect 裁掉），8dp/5% 余量只缓解不根治
- [UI] 正文行宽恢复满宽——去掉分页宽 ×0.95 缩减；双页模式左右边距不对称时改取两栏较小栏宽（修右栏越界）
- [UI] 章节切换翻页动画修复（覆盖模式）——此前切章经 isLoading 整树换 LoadingIndicator 致 AnimatedSwitcher 卸载重挂、过渡永不触发；改为加载中保留上一章渲染（冻结帧不重分页），键改（章索引,屏索引）复合键修方向判定（此前只含章内页索引，跨章页索引相同不触发、变小判反）
- [UI] 两端对齐可用宽改用实际布局约束（此前硬编码屏宽-40，自定义页面边距时对齐目标与渲染约束错位）

### Test
- flutter analyze 无问题；flutter test 1346 全过（新增 line_overflow_guard_test 5 项：压缩行/多宽度扫描/textScaler/无损/朴素分支）
- 版本 2.0.204+205

- Contributor: Qoder UI

## [2.0.202] - 2026-09-06

### Fixed
- [UI] 阅读菜单 FloatingIconRow 溢出——图标 8→5（目录/朗读/自动翻页/替换/界面，对齐参考 iconItemsPerRow=5），修 RIGHT OVERFLOWED BY 40 PIXELS；书签/日夜/更多设置保留在 More 溢出菜单
- [UI] 正文右边距安全余量 4→8dp（letterSpacing 0.1em × CJK 每行 ~15 字 ≈ 27px 额外宽度）
- [UI] 阅读弹层双横杠全面修复——config_panel/padding_config/tip_config/read_aloud_bar/review_detail_sheet 五处补 showDragHandle:false
- [UI] 阅读排版默认值对齐参考——行距 1.6→1.67、段距 12→2dp、字距 0→0.1em

### Test
- flutter analyze 无问题；flutter test 1341 全过
- 版本 2.0.202+203

- Contributor: Qoder UI

## [2.0.201] - 2026-09-06

### Fixed
- [UI] 阅读设置弹层双横杠全面修复——reader_config_panel/reader_padding_config_sheet/reader_tip_config_sheet/read_aloud_bar/review_detail_sheet 五处补 showDragHandle:false；IosGroup 分组卡行底 Material 化消 ink 断言；正文右边距安全余量 4→8dp（letterSpacing 0.1em × CJK 每行 ~15 字 ≈ 27px 额外宽度）
- [UI] 阅读排版默认值对齐参考——行距 1.6→1.67、段距 12→2dp、字距 0→0.1em

### Test
- flutter analyze 无问题；flutter test 1341 全过
- 版本 2.0.201+202

- Contributor: Qoder UI

## [2.0.199] - 2026-09-06

### Fixed
- [UI] 问题1：正文右边距裁切——分页宽度计算加 4dp 安全余量（TextPainter 分页与实际渲染存在微差，防最后一字符被右边裁掉）
- [UI] 问题2：阅读设置弹层双横杠——ReaderSettingsSheet.show 传 showDragHandle:false 消主题抓手叠加
- [UI] 问题3：阅读排版默认值对齐参考仓——行距 1.6→1.67（对齐 lineSpacingExtra=12dp）、段距 12→2dp（对齐 paragraphSpacing=2dp）、字距 0→0.1em（对齐 letterSpacing=0.1f）；涉及 settings_service/reader_config_panel/reader_page_view 三处

### Test
- flutter analyze 无问题；flutter test 1341 全过
- 版本 2.0.199+200

- Contributor: Qoder UI

## [2.0.198] - 2026-09-06

### Changed
- [UI] 一比一复刻 T3：书架批量态搬入主书架——溢出菜单新增「选择模式」入口（toggleBatchMode）；批量模式下网格点击=切换选中（选中高亮+勾选角标）、列表同理；顶部悬浮摘要卡（已选 n·总 m+退出）；底部批量工具条（全选/反选/批量下载/移动分组）；独立管理页保留
- [UI] 修复 md3_animated_text_line `?currentChild` null-aware 元素语法（build_runner 解析不兼容，改 if-null 等效写法再恢复并确认 analyzer 支持）

### Test
- flutter analyze 无问题；flutter test 1341 全过
- 版本 2.0.198+199

- Contributor: Qoder UI

## [2.0.197] - 2026-09-06

### Changed
- [UI] 一比一复刻 T2：我的页分组卡反转（对齐参考 SplicedColumnGroup）——全部 IosGroup 由拆扁平恢复为 16dp 分组卡（surfaceContainer 底+组内 2dp 间距+每行 4dp surfaceContainerLow 小卡，行卡 Material 化消 ink 断言）；新增「高亮标注」条目入规则组；登记：组序完全对齐参考待后续微调（本地独有条目归位）

### Test
- flutter analyze 无问题；flutter test 1341 全过（settings_test 滚动断言适配分组卡变高）
- 版本 2.0.197+198

- Contributor: Qoder UI

## [2.0.196] - 2026-09-06

### Changed
- [UI] 一比一复刻 T1：订阅页对齐参考 RssScreen——网格改 Adaptive 72dp 小瓦片（48dp 图标+labelMedium 2 行名居中，120dp 行高防溢出）+ 头部双卡（规则订阅|收藏，surfaceContainer 16dp 圆角，span 全宽，收藏入口自顶栏迁入）；空态改 sliver 尾部布局

### Test
- flutter analyze 无问题；flutter test 1341 全过（contrast_audit 同步过）
- 版本 2.0.196+197

- Contributor: Qoder UI

## [2.0.194] - 2026-09-06

### Fixed
- [UI] 发现/订阅页对齐参考 ListScaffold（用户双包对比反馈）：搜索行默认收起（标题态+切换钮展开，原为常驻展开）；发现页分组筛选由常驻 FilterChip 横滑条改下拉菜单（对齐 RoundDropdownMenu，横条删除）；两页标题下增 subtitle（当前分组名/全部）

### Test
- flutter analyze 无问题；flutter test 1341 全过
- 版本 2.0.194+195

- Contributor: Qoder UI

## [2.0.193] - 2026-09-06

### Changed
- [UI] 一比一复刻 S7：渲染矩阵补页——书籍详情（ActionCard/折叠顶栏/取色，light/dark）与阅读器（单面板挂载路径，openBook 注入）纳入自动验收矩阵；归档：一比一复刻 S0–S7 全批完成

### Test
- flutter analyze 无问题；flutter test 1341 全过（新增 one_to_one_matrix_test 3 用例）
- 版本 2.0.193+194

- Contributor: Qoder UI

## [2.0.192] - 2026-09-05

### Changed
- [UI] 一比一复刻 S6：三端适配——跟随壁纸取色口径修正（iOS 动态色实际已接通，注释/描述三处同步）；blur/毛玻璃三端策略矩阵落盘（三端 BackdropFilter 均可用、默认统一关，桌面高性能环境可手动开启）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.192+193

- Contributor: Qoder UI

## [2.0.191] - 2026-09-05

### Changed
- [UI] 一比一复刻 S5：底部弹层统一壳升级——AppBottomSheet 消双把手（主题 showDragHandle 统一提供）、标题 titleMedium+Medium 强调（对齐参考 titleMediumEmphasized）、去标题下分隔线；文件管理长按菜单迁移示范（统一壳采用量 0→1，余 29 处散点登记渐进）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.191+192

- Contributor: Qoder UI

## [2.0.190] - 2026-09-05

### Changed
- [UI] 一比一复刻 S4：主题引擎参数化——配色风格 9 档（TonalSpot/Neutral/Vibrant/Expressive/Fidelity/Content/Rainbow/FruitSalad/Monochrome，material_color_utilities Scheme* 生成明暗全角色）+ 对比度三档 + AMOLED 纯黑；seed=自定义主色（未设取当前色板锚点）；并存模型保持（动态壁纸>自定义四色>参数化>内置）；登记：Spec2025 为 Kotlin materialkolor 独有，Dart 映射 2021 spec

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.190+191

- Contributor: Qoder UI

## [2.0.189] - 2026-09-05

### Changed
- [UI] 一比一复刻 S3：详情页 ActionCard 行（加入书架/目录/分组/换源/阅读记录 5 卡，对齐参考 BookInfoActions）；Characters/RelatedBooks 区块骨架就位（用户授权纳入，后端数据链调研已登记——接通前空数据隐藏）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.189+190

- Contributor: Qoder UI

## [2.0.188] - 2026-09-05

### Changed
- [UI] 一比一复刻 S2-2：阅读菜单表面 Haze 档（enableBlur 时半透明底 α85/255+BackdropFilter 24）；亮度竖条左右双位（readMenuBrightnessVertical/Pos 开关，横行联动隐藏）；登记：More 长尾项（目录刷新等）维持原入口不迁伪功能

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.188+189

- Contributor: Qoder UI

## [2.0.187] - 2026-09-05

### Changed
- [UI] 一比一复刻 S2-1：阅读菜单收敛为单块底部面板（ReaderMenuPanel 五分区骨架：标题胶囊行+FloatingIconRow 高频 8 位+搜索 pill+亮度行+进度滑条+工具行），替代顶栏/底栏两块分立；常挂载双向动画继承；朗读条暂与面板互斥（S2-2 并入面板路由页）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.187+188

- Contributor: Qoder UI

## [2.0.186] - 2026-09-05

### Changed
- [UI] 一比一复刻 S1c：主框架导航组件化——ShortNavigationBar/悬浮胶囊/Rail 三态抽为 app_navigation_bars 组件族（皮肤图标三态统一消费，原 home_screen 私有件公共化）；Rail 对齐参考三件——头部搜索钮、书架分组菜单（参考 Rail 项长按菜单的入口钮等效，交互差异登记）、expand 展开态持久化（railExtended 开关键）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.186+187

- Contributor: Qoder UI

## [2.0.185] - 2026-09-05

### Changed
- [UI] 一比一复刻 S1b：发现/订阅两页顶栏对齐参考 DynamicTopAppBar——新增 DynamicSearchAppBar 组件（标题+搜索切换钮+bottomContent AnimatedSize 展开搜索行，FilterChip 横滑条常驻追加）；原嵌入式搜索框迁至搜索行，4 个功能图标入口保留

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.185+186

- Contributor: Qoder UI

## [2.0.184] - 2026-09-05

### Changed
- [UI] 一比一复刻 S1a：主页恢复滑动切页——拉参考源码核实 MainScreen 为 HorizontalPager(userScrollEnabled=true)，早前审计 IndexedStack 口径系误读（原版本就是 ViewPager 滑动）；PageView+KeepAlive 等效 beyondViewportPageCount，底栏跳页/返回回架/默认首页全部同步

### Test
- flutter analyze 无问题；flutter test 1338 全过（home_navigation_test 口径同步）
- 版本 2.0.184+185

- Contributor: Qoder UI

## [2.0.183] - 2026-09-05

### Changed
- [UI] 同步重构 R3⑤：书架管理/搜书内文/TXT 目录规则三屏接入快速滚动条，累计 12 屏

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.183+184

- Contributor: Qoder UI

## [2.0.182] - 2026-09-05

### Changed
- [UI] 同步重构 R3④：书签页/订阅源管理（批量+过滤两态）/高亮规则页接入快速滚动条，累计 9 屏（书源/订阅源/目录/替换规则/阅读记录/发现/书签/订阅源管理/高亮规则）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.182+183

- Contributor: Qoder UI

## [2.0.181] - 2026-09-05

### Changed
- [UI] 同步重构 R3③：阅读记录页与发现页（订阅源列表）接入快速滚动条，累计 6 屏（书源/订阅源/目录/替换规则/阅读记录/发现）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.181+182

- Contributor: Qoder UI

## [2.0.180] - 2026-09-05

### Changed
- [UI] 同步重构 R3②：目录页（千级章节列表）与替换规则页（批量模式）接入快速滚动条（新双态形态），合计接入 4 屏（书源/订阅源原有）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.180+181

- Contributor: Qoder UI

## [2.0.179] - 2026-09-05

### Changed
- [UI] 同步重构 R3①：登录页提交 modalOverlay 遮罩（提交期间全屏防重复操作）；新增设置行分隔线开关（enableItemDivider，主题页「详情与圆角」组，行底 1dp×80dp 胶囊线默认关）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.179+180

- Contributor: Qoder UI

## [2.0.178] - 2026-09-05

### Changed
- [UI] 同步重构 R2②：阅读菜单退出双向动画——顶/底栏改常挂载+控制器双向（进 fadeIn180+scaleIn0.88@220 / 出 fadeOut140+scaleOut0.88@180，hidden 时零尺寸省绘制+IgnorePointer），弹出与收起均有形变过渡（原退出为瞬时卸载）

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.178+179

- Contributor: Qoder UI

## [2.0.177] - 2026-09-05

### Changed
- [UI] 同步重构 R2-①：FastScroll 滑块形态对齐参考仓——idle 36×4 outlineVariant@0.8 → 激活 48×12 primary，250ms AnimatedContainer 形变；滚动/拖拽激活保持 3s 后渐隐 250ms；书源/订阅源两处自动升级

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.177+178

- Contributor: Qoder UI

## [2.0.176] - 2026-09-05

### Changed
- [UI] 同步重构 R1：毛玻璃家族接线——主题页新增「毛玻璃」组（启用开关+顶栏/悬浮底栏模糊半径与底色透明度调参，关时灰显）；enableBlur 开启后 LegadoAppBar（BackdropFilter+topBarBlurAlpha 半透明底）、悬浮底栏、详情页背景三档 on 模式三处生效，关闭维持实色回退（登记：阅读菜单模糊与 SliverAppBar 滚动玻璃后续批）
- [UI] 同步重构 R1：跟随壁纸取色真实生效——app.dart 集成 DynamicColorBuilder（Material You），wallpaperColorFollow 开启且系统提供动态色板时 primary/accent 取动态 role，其余沿用并存模型；主题页开关同步 uiSettings

### Test
- flutter analyze 无问题；flutter test 1338 全过
- 版本 2.0.176+177

- Contributor: Qoder UI

## [2.0.175] - 2026-09-05

### Fixed
- [UI] 书架搜索入口找回：B2 曾把搜索图标迁往 Dynamic 搜索行并移除原图标，用户报障「搜索框/按钮消失」——恢复顶栏搜索图标（原版 main_bookshelf.xml 对齐红线）并与搜索行双入口并存；新增书架搜索行回归守护（无分组/分组两形态断言行常驻+图标在位）

### Test
- flutter analyze 无问题；flutter test 1338 全过（新增 bookshelf_search_row_test 2 断言组）
- 版本 2.0.175+176

- Contributor: Qoder UI

## [2.0.174] - 2026-09-05

### Fixed
- [UI] 关联导入同链接不再弹出的根因：深链去重标志 `_lastHandled` 在弹窗关闭后不清除——同一 legado:// 链接整个应用会话内只能弹一次（手动关闭/导入完成自动 pop 后再点同一链接被去重拦截，报障「无法弹出导入界面」）。修复：弹窗 Future 完成时清标志。5556 模拟器实证：同链接冷/热触发两次均正常弹出（探针 mount+build+像素卡片结构确认）

### Test
- flutter analyze 无问题；flutter test 1336 全过
- 版本 2.0.174+175

- Contributor: Qoder UI

## [2.0.173] - 2026-09-05

### Changed
- [UI] 全量同步重构 B6/B7 精简版：主题页新增「详情与圆角」组（跟随封面取色开关/封面背景三档/卡片圆角覆写 4-28dp 随主题重建生效，圆角覆写接通 app_theme 卡片档）；确认对话框按钮规范对齐参考仓（右对齐+minWidth 88+间距 12 宽扁形态）

### Test
- flutter analyze 无问题；flutter test 1336 全过
- 版本 2.0.173+174

- Contributor: Qoder UI

## [2.0.172] - 2026-09-05

### Changed
- [UI] 全量同步重构 B1：字阶拉齐参考仓 miuix 压缩字阶（display32/title18/body17/label13，bodySmall 钉 12、labelLarge 钉 14，titleSmall w600）——全局观感更紧凑；书架列表行密度 vertical12（原 top/bottom 4 偏挤）

### Test
- flutter analyze 无问题；flutter test 1336 全过
- 版本 2.0.172+173

- Contributor: Qoder UI

## [2.0.171] - 2026-09-05

### Changed
- [UI] 全量同步重构 B5（布局优先批次四）：阅读器菜单对齐参考仓——菜单进出场动画统一（fadeIn180+scaleIn0.88@220，替换旧 slide+fade 组合）；全文搜索 mini FAB 升级为 40dp r16 搜索 pill；顶栏书名改标题胶囊（Stadium 16/4）；顶/底栏停靠圆角 32（对齐 readMenuBottomCornerRadius）

### Test
- flutter analyze 无问题；flutter test 1336 全过
- 版本 2.0.171+172

- Contributor: Qoder UI

## [2.0.170] - 2026-09-05

### Changed
- [UI] 全量同步重构 B4（布局优先批次三）：书籍详情页重塑对齐参考仓——封面取色换肤（palette_generator 提 seed，ColorScheme 400ms 渐变，跟随封面开关）；折叠顶栏（顶部全透明→下滑 surfaceContainer 玻璃色，折叠后显示书名，actions 经 5 档样式注入）；背景三档 off/off_for_default/on（480dp 封面+blur24+seedOverlay+垂直渐变 stops 0/0.2/0.4/0.6/0.8/1，切换 Crossfade 800ms）；新增 ExtendedFAB 开始/继续阅读（底部操作条保留加书架/阅读）

### Test
- flutter analyze 无问题；flutter test 1336 全过（coverage 测试点击定位改 FAB 实例）
- 版本 2.0.170+171

- Contributor: Qoder UI

## [2.0.169] - 2026-09-05

### Changed
- [UI] 全量同步重构 B3（布局优先批次二）：底栏与导航对齐参考仓——label 三档显示（仅选中/常显/纯图标）、底栏不透明度 0-100、悬浮底栏（64dp Stadium 胶囊、按压缩放+图标 1→1.2+选中 64×32 胶囊，实色版）、大屏导航形态三档（自动 sw≥600/始终/仅横屏/关闭）切 NavigationRail 简版、底栏显隐开关；主题页新增「底栏与导航」开关组

### Test
- flutter analyze 无问题；flutter test 1336 全过（新增 ui_settings_test）
- 版本 2.0.169+170

- Contributor: Qoder UI

## [2.0.168] - 2026-09-05

### Changed
- [UI] 全量同步重构 B0+B2（布局优先批次一）：顶栏按钮体系对齐参考仓 5 档规格（plain 40dp/图标24、tonal/outlined/glass/liquidGlass 36dp/图标20，默认 tonal；outlined 1dp 描边；glass 为实色回退）；merge 顶栏按钮并入胶囊容器+1dp 分隔线；书架大标题下新增 Dynamic 搜索行（进场展开动画，搜索入口由图标迁至搜索行）；顶栏不透明度设置；大顶栏形态开关；滚动色插值经 surfaceTint→surfaceContainer 等效
- [UI] 新增 UI 布局设置通道（uiSettingsListenable 全局监听，组件零 Riverpod 依赖，58+ 使用点与既有测试兼容）；新增 palette_generator/dynamic_color 依赖（详情取色/动态取色后续批使用）；计划文档落盘 docs/UI_SYNC_REFACTOR_PLAN_20260905.md（含 81 屏覆盖矩阵）

### Test
- flutter analyze 无问题；flutter test 1333 全过（新增 top_bar_button_test 7 断言）
- 版本 2.0.168+169

- Contributor: Qoder UI

## [2.0.167] - 2026-09-05

### Fixed
- [UI] 全站转场对齐参考仓库源：拉取 navigation3 1.1.7 NavDisplay.android.kt 证实参考版所有转场均为「进页淡入 + 被覆盖页同步淡出」的交叉淡入淡出（默认 700ms、书籍详情条件 300ms、阅读器 600ms，缓动 FastOutSlowIn），此前标尺的 slide480+fade360 / pop scale0.8 与库源不符——重写主题转场 builder 为统一 crossfade，被覆盖页不再保持不透明缩放 0.8（消除进书籍时的叠影感）
- [UI] 转场时长分档真正生效：MaterialApp 由 routes map 切换 onGenerateRoute（MaterialPageRoute 硬编码 300ms 不可配），Android 按路由名注册时长（默认 700/详情 300/阅读 600），iOS/桌面维持平台默认 300ms 不变

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.167+168

- Contributor: Qoder UI

## [2.0.166] - 2026-09-05

### Fixed
- [UI] 进书籍转场卡顿与封面闪占位：根因一为 Hero 飞行内容取详情页新封面实例，异步解析期闪默认占位图——改取出发侧已加载封面（push=书架图 / pop=详情图，对齐参考仓 sharedBounds 同图语义）；根因二为详情背景虚化层全尺寸解码+25σ 模糊转场期掉帧——虚化源降采样 1/3 屏宽（σ25 下视觉无差）并加 RepaintBoundary

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.166+167

- Contributor: Qoder UI

## [2.0.165] - 2026-09-05

### Changed
- [UI] 布局规划收尾：P4 动效残项补全——ContainedLoadingIndicator 接线（列表 footer 加载态/空态 isLoading 分支，对齐 HapeLee LoadMoreFooter/EmptyMessage 口径）；余下 7 处裸 RefreshIndicator 统一 CustomRefreshIndicator（自动任务/缓存下载/离线缓存/阅读记录/RSS 收藏/详情/发现列表）；发现分类列表首屏接 Skeleton；RSS 文章详情自绘空态并入 EmptyState；词典查询 loading 换波浪环
- [UI] 布局规划残页补齐——漫画阅读器顶栏动作行对齐（返回/设置补 tooltip + 图标切 Symbols 体系）；other_settings 对话框经全局 dialogTheme(surfaceContainer+28dp) 验证合规

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.165+166

- Contributor: Qoder UI

## [2.0.164] - 2026-09-04

### Changed
- [UI] 布局规划 P4 动效全补：转场分档（阅读 fade/详情 fade 300/其余 slide+fade，predictiveBack 登记）；Hero tag 统一 book-cover 全链路 + flightShuttle 统一进 BookCover；首屏 Skeleton 接线（书架/发现/搜索/详情等）；新建 ContainedLoadingIndicator；裸 RefreshIndicator 统一 M3；空态收敛；阅读器菜单 slide+fade + 朗读 fade + Sheet 28dp 对齐；search_scroll 测试同步 Skeleton 断言

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.164+165

- Contributor: Qoder + Bridge

## [2.0.163] - 2026-09-04

### Changed
- [UI] 布局规划 P3 设置系与通用重排：书架管理/分组/离线缓存/缓存设置/远程书籍/文件管理行规范；自动任务/阅读记录/关于/日志/WebDAV 行规范与 Dialog 容器；导入/关联导入/浏览器/二维码行规范；音视频仅顶栏（沉浸本体不动）

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.163+164

- Contributor: Qoder + Bridge

## [2.0.162] - 2026-09-04

### Changed
- [UI] 布局规划 P2 书源规则链重排：调试页输入框走主题/边距 16dp/调试行圆角 16dp；导入确认行规范；JS/代码编辑区边距圆角 16dp；登录页拆三 Card 分组；规则/RSS 调试/导入/文章/收藏/词典/TXT 目录行规范；WebView 登录菜单位置；书源分组对话框行规范

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.162+163

- Contributor: Qoder + Bridge

## [2.0.161] - 2026-09-04

### Changed
- [UI] 布局规划 P1 主链二三级重排：书籍信息编辑头部进 Card 分组 + 表单 16dp；换封面网格 token 对齐；目录书签/标注 Tab 行规范；书签/缓存下载行规范；阅读配置面板分组卡 16dp + 组内行规范；字体分组标题走 IosSectionHeader；高亮/朗读开关行规范；搜书正文结果行规范

### Test
- flutter analyze 无问题；flutter test 1321 全过
- 版本 2.0.161+162

- Contributor: Qoder + Bridge

## [2.0.160] - 2026-09-04

### Fixed
- [UI] 订阅页顶部 4 图标（阅读记录/收藏/分组/管理）浅底看不清：Symbols 描边版对比度不足，改 filled 填充版 + onSurface 显式色（模拟器实机确认）

### Test
- flutter analyze 无问题；rss 相关 12 项全过
- 版本 2.0.160+161

- Contributor: Qoder + Bridge

## [2.0.159] - 2026-09-04

### Fixed
- [UI] 暗色下发现页顶部 FilterChip（“全部”/分组）黑字看不清：L1 新增 chipTheme 未声明 label 色，未选中态回退黑色（对比度仅 1.1）；现 label 走 onSurfaceVariant、选中走 onSecondaryContainer；新增订阅/发现亮暗 4 场景对比度审计测试（contrast_audit_test，低对比即失败）回归守护

### Test
- flutter analyze 无问题；contrast_audit 4 全过（21 文本零低对比）
- 版本 2.0.159+160

- Contributor: Qoder + Bridge

## [2.0.158] - 2026-09-04

### Fixed
- [UI] 正文次要文字对比度修复：书签书名/章节、浏览器历史计数/URL/说明、换源字数/耗时、替换规则预览共 9 处 Text 误用 `outline`（边框装饰色，对比度不足）改为 `onSurfaceVariant`；图标/边框装饰类 outline 保留

### Test
- flutter analyze 无问题；change_source/source_card 11 项全过
- 版本 2.0.158+159

- Contributor: Qoder + Bridge

## [2.0.157] - 2026-09-04

### Changed
- [UI] 布局动效 L3 主框架+五大页：主框架 PageView 改 IndexedStack 禁滑动切页（HapeLee 语义，底栏切页/双击/返回逻辑保留，home_navigation 测试同步）；书架网格封面 84 宽 aspect5/7 圆角 4dp + 间距 8dp + 边距 top8/horizontal4 + TabBar 标准化；详情边距 18→16 + Hero 圆角过渡 + FAB primaryContainer + 底部避让；搜索 SearchBar 化 + autofocus + 提交藏键盘；发现 SearchBar + FilterChip + 展开 300ms；RSS 间距 12dp；目录行 vertical12；换源行字级 token 化；平板 Rail 预留接口
- [UI] 布局动效 M1 转场 Hero：PageTransitionsTheme 全站统一（Android slide+fade/pop scale0.8，iOS/桌面走默认）；Hero tag 统一 book-cover:（书架/列表/搜索/发现/详情全链路）+ flightShuttle 圆角过渡
- [UI] 布局动效 M2 加载空态：新增 Skeleton shimmer（1200ms + Highest→High，网格/列表两型）；LoadMore 三态 footer（loading/error/end，24px）；空态加 isLoading 分支 + message 限宽 240dp；波浪加载器加 RepaintBoundary

### Test
- flutter analyze 无问题；flutter test 1313 全过（含 bookshelf 比例/导航同步更新）
- 版本 2.0.157+158

- Contributor: Qoder + Bridge

## [2.0.156] - 2026-09-04

### Changed
- [Rust+UI] 布局动效 R 批：`get_theme_mode` 跟随系统修正（"0"→auto，R3，需双轨评审）+ 新增 `set_read_book_config` 进程注入 FFI（R4，阅读字号/背景变更经 refreshReadBookConfig 补推，契约 §1.6.1 登记）；注入键集合/deleteConfig 空串约定/themeConfigList 链路补登记
- [UI] 布局动效 L1 组件主题地基：Dialog→surfaceContainer、Sheet→surfaceContainer+开抓手、Menu→surfaceContainerLow+elev4、Tooltip→surfaceContainerLow、FAB 前景 primary、Outlined 描边 outline、按钮高 44→40；新增 chip/switch/checkbox/radio/slider/iconButton/searchBar/menu 主题；新增 PillDivider/SettingItemDivider + SettingCard/TextCard/OptionCard/CardTabRow + labelMediumEmphasized；TextField 维持 12 全圆角登记形态差异
- [UI] 布局动效 L2 设置拆扁平：IosGroup 圆角 20→16（HapeLee Spliced 16）+ 新增 flat 扁平模式（透明 Material 包裹保 ink）供 9 屏迁移；IosListTile 去 32dp 图标方块改裸 Icon，值文本 primary-labelMediumEmphasized，M3 补 Chevron

### Test
- flutter analyze 无问题；cargo test -p legado-js（config_api 8 项）全过；settings/theme/explore 双栏 12 项全过
- 版本 2.0.156+157

- Contributor: Qoder + Bridge

## [2.0.155] - 2026-09-04

### Changed
- [UI] MD3 对齐 Phase 0+B0+Batch A/B 落地（UI_MD3_ALIGNMENT_PLAN.md v1.1）：换源屏评分色/书源调试双屏状态语义色/书源列表状态点/JS 源编辑错误警告底/导入确认状态标签/搜索结果圆点/缓存下载完成态/帮助 Markdown 弱文本分隔线/取色器黑白/高亮预设色板共 11 组硬编码迁 tonal role；二维码黑白登记为扫码语义例外；`cupertino_icons` 保留（沉浸域仍引用）
- [Rust+UI] 主题透传 R1/R2：`config_api::get_theme_config` 默认值对齐 MD3 wh（primary #FF5C5C5C/background #FFF8F8F8）+ 新增 `set_theme_config/set_theme_mode` 进程注入 FFI（契约 §1.6.1 补登记）；Flutter `RustApi.init` 注入当前 palette 亮色 role 与主题模式（0/1/2），JS 书源 `getThemeConfig()/getThemeMode()` 可感知界面实际主题
- [Docs] 新增 `docs/UI_MD3_ALIGNMENT_AUDIT.md`（Phase 0 精确待改清单：主题资源零差异无需追新，A1 样板 + B1-B10 增量；沉浸域/Cupertino/`surfaceVariant` 明确不改）

### Test
- flutter analyze 无问题；flutter test 1313 全过；md3_palette 32 全过；cargo test -p legado-js（config_api 7 项）全过
- 版本 2.0.155+156

- Contributor: Qoder + Bridge

## [2.0.154] - 2026-09-04

### Added
- [Rust+UI] 【换源任务书·批次 3 T6】换源搜索流式化交付（任务书唯一 ⏸ 项收口）：Rust 新增 `run_change_source_stream`（每完成一源推一批次：候选全量快照 + finished_count/total_count 进度 + 单源 error 不中断流；DB 复用路径单批即结束；enrich 开启时流内后置增强不阻塞首批）+ `drive_source_batches` 泛型化复用；FFI 经 StreamSink 绑定（`searchSourceStream`，契约 §2.4）+ FRB 重生成；Dart 新增 BookApi.searchSourceStream 服务层 + ChangeSourceNotifier 逐批替换展示（x/y 进度驱动）+ 换源页面逐源渐显与「已找到 N 个匹配书源（x/y 源完成），搜索中…」进度文案（U1 过渡反馈的永久替代，对齐原版 _changeSourceProgress）。5556 实测 1024 源规模首候选 ≤2s（<5s 验收标准）、x/y 准确（y=1024）、渐显 13→151
- [UI] 换源页首次自动搜索等待高级选项加载完成（对齐原版搜索前同步读 AppConfig）：此前 `_loadAdvancedOptions` 与首轮 `_search` 竞态，首轮用未恢复的默认开关值；现 initState 持有加载 Future，首轮搜索内部 await 后再执行

### Test
- cargo test --workspace 全绿 / flutter analyze 无问题；flutter test 1313 全过（含 change_source 单元/widget 23 项；4 个 mocktail 桩按 T6 签名补齐 named 参数）
- 两级冒烟：5556 PASSED；5558 -SkipBuild PASSED
- 版本 2.0.154+155

- Contributor: Qoder + Bridge

## [2.0.153] - 2026-09-03

### Fixed
- [Rust] 【换源任务书·批次 1 T1/T2】换源执行链对齐原版 getToc（3a78afc049）：此前换源后直接以 new_book_url（搜索结果 URL）硬闯目录，详情页 tocUrl 规则指向不同目录页时取不到目录；现先经新源详情解析（canReName=false 保留既有书名/作者，cover/intro/kind/lastChapter/wordCount 按非空更新），再以 ruleBookInfo 解析出的真实 tocUrl 取目录；详情或目录任一步失败即换源整体失败并保留旧源（单事务回滚）；章节落库保留解析的 variable/isVolume（此前写死 false/None）
- [Rust] 【换源任务书·批次 2 T3/T4/T5】变量链端到端补齐：搜索期元素级 `@put`/`putVariable` 级联导出随 SearchResult 落 searchBooks 行；换源时按 (new_book_url, origin) 从 searchBooks 取候选变量，与详情页导出变量合并（详情页后写入者优先，对齐原版 AnalyzeRule.putVariable 同名键覆盖语义）→ book.variable；正文链 reader/audio 按 book⊕chapter 合并（章节优先）注入 get_content URL 变量表（此前恒空表）。searchSource/switchSource/webbookInfo 零签名变更，全部加法式字段
- [Test] FFI 流测试环境性失败永久修复：本机代理生效时假源端口请求经代理返回 HTTP 502（而非连接拒绝），按 S0-E 对齐（非 2xx 响应体仍进入解析）得空列表、批次无 error 字段；测试改断言共同不变量（恰好一个批次/正常结束/无结果），不再断言 error 字段本身

### Test
- cargo fmt 0 diff / clippy 0 warning / cargo test --workspace 全绿 / quickjs 两段门禁通过
- flutter analyze 无问题；flutter test 1313 全过
- 版本 2.0.153+154

- Contributor: Qoder + Bridge

## [2.0.152] - 2026-09-03

### Changed
- [UI] 应用内「关于」页更新日志（assets/updateLog.md）补充 Flutter 轨近五个批次（2.0.147~2.0.151）的用户可见更新：换源搜索等待反馈、本地导入失败原因显示、听书崩溃修复、定时任务错误提示、关联导入弹出式重做与逐类确认等；此前该文件停留在原版轨道 2026/08/04 的内容

### Test
- flutter analyze 无问题；flutter test 1312 过（唯一失败为既有 FFI 运行时测试，后端轨范围）
- 两级冒烟：5556 -CheckPlayback PASSED（8/8）；5558 -CheckUI -SkipBuild PASSED（7/7）
- 版本 2.0.152+153

- Contributor: Qoder + UI

## [2.0.151] - 2026-09-03

### Fixed
- [UI] 【换源任务书 U1·UI 侧过渡修复】换源搜索等待反馈：Rust 换源搜索为一次性阻塞调用（数百源 × 60s/源全跑完才返回），此前 UI 仅无反馈转圈。现于 ChangeSourceState 新增 searchingCount（本轮参与搜索的源数量，分组搜索取分组源数、全量取启用源数），等待页显示「正在搜索 N 个书源… 已等待 X 秒」计时文本（LoadingIndicator 新增可选 subMessage 槽，附加式参数不影响既有调用方）；有结果增量加载时计数行改「已找到 N 个匹配书源，搜索中…」。此为 T6 流式 API（逐源渐显 + x/y 进度，对齐原版 _changeSourceProgress）落地前的过渡方案，届时替换
- [UI] 换源任务书四根因核实结论（仅核实，Rust 侧未动）：R1/R2 与文档一致（source_switch.rs:307 直接以 new_book_url 取目录、:325/:338 章节变量写死 false/None），R3/U1 属实——修复均待 Rust 轨批次 1/2/3

### Test
- flutter analyze 无问题；flutter test 1312 过（唯一失败为既有 FFI 运行时测试，后端轨范围）；change_source_screen_test 6 用例全过
- 两级冒烟：5556 -CheckPlayback PASSED（8/8）；5558 -CheckUI -SkipBuild PASSED（7/7）
- 版本 2.0.151+152

- Contributor: Qoder + UI

## [2.0.150] - 2026-09-03

### Fixed
- [UI] 【体检 §三.13】本地导入失败原因显式化：bookshelf 导入循环原 `catch(_)` 丢弃 rust 侧返回的明确文案（如「不支持 LZMA 压缩格式 (compression=17481)」「该 MOBI 文件已加密」），提示只剩文件名；现透传失败原因至 SnackBar（详情最多 3 条防溢出，其余以「等 N 本」汇总）

### Changed
- [UI] 【体检 §三.16】超长文件拆分（方法原样搬移、零行为变更）：7 个超 1400 行业务文件按域拆为 part 文件——rust_api.dart（2957→主文件+mixin 组合 8 part：RustApiDecode/RustApiSources/RustApiSearchRss/RustApiReaderData/RustApiDiscoveryCache/RustApiMediaFormat/RustApiSyncTools/RustApiContentExt，成员合集实现 BookApi）、mock_book_api.dart（2655→同构 8 part）、book_info_screen.dart（2165→extension 3 part）、source_screen.dart（1733→3 part）、reader_config_panel.dart（1694→2 part）、source_edit_screen.dart（1634→4 part）、search_screen.dart（1558→3 part）；生命周期（initState/dispose/build）留在主类，extension 承载其余方法（同 library 私有成员可访问；ref 为 protected 成员经 ignore_for_file 声明语义安全）；API 契约门禁测试改为拼接 part 文件提取方法集，BookApi ⊆ RustApi/MockBookApi 校验语义不变
- [UI] 体检遗留项核对结论：§三.16 golden 快照基线为「决策闭环」项——md3_acceptance_matrix_test 头部已记录决策（跨平台 Windows/Linux 字体渲染差异使 golden 二进制基线脆弱，以渲染矩阵 + 模拟器 -CheckUI 替代），不重开；§三.13 本批落地；§六 AGENTS.md 冒烟端口口径（5556/5558）与脚本默认值、验收流程一致，维持不动

### Test
- flutter analyze 无问题；flutter test 1312 过（唯一失败为既有 FFI 运行时测试，后端轨范围）；api_contract_test 契约门禁全过
- 两级冒烟：5556 -CheckPlayback PASSED（8/8）；5558 -CheckUI -SkipBuild PASSED（7/7）
- 版本 2.0.150+151

- Contributor: Qoder + UI

## [2.0.149] - 2026-09-03

### Fixed
- [UI] 【体检 N1/P0】听书前台服务未注册 manifest——播放即崩（虚假闭环）：PlaybackForegroundService 类已实现但 main/debug/profile 三个 AndroidManifest 均无该 service 声明，MediaSessionBridge 播放态变化无条件 startForegroundService，Android 8+ 上指向未注册组件抛 IllegalStateException，一点开听书即崩溃（比修复前"后台被冻结"更严重）。修复：main manifest 注册 service（mediaPlayback 类型、exported=false）+ 补 FOREGROUND_SERVICE_MEDIA_PLAYBACK 权限（Android 14 要求）；冒烟脚本新增 -CheckPlayback（am start-foreground-service 直接拉起 + dumpsys ServiceRecord + 退后台 5s 存活 + 崩溃检查），自动化防回归该崩溃机制
- [UI] 【体检 §二.7+§三.17】删除 AutoTask REST 死降级路径：legado-server 进程内从未启动，REST 指向 127.0.0.1:8080 永远连接失败，且连接类错误被吞成空列表（UI 静默无感）。auto_task_notifier 改纯 FFI + 失败可见（FFI 失败/缺失一律写入 error 状态由 UI 呈现），顺带消除 UI 层直连网络的先例（package:http）；单元测试同步重写（25 用例：FFI 成功/失败可见/FFI 缺失可见/乐观回滚）

### Test
- flutter analyze 无问题；flutter test 1312 过（唯一失败为既有 FFI 运行时测试，后端轨范围）
- 两级冒烟：5556 -CheckPlayback PASSED（前台服务启动 + ServiceRecord 确认 + 退后台存活，8 步含播放门禁）；5558 -CheckUI -SkipBuild PASSED（7/7）
- 版本 2.0.149+150

- Contributor: Qoder + UI

## [2.0.148] - 2026-09-03

### Changed
- [UI] 关联导入由全屏页面改为弹出式确认对话框（用户要求对齐原版呈现方式，视觉按 MD3 目标风格）：原版经 DialogFragment 在当前页面上方弹出（dialog_recycler_view），现以 showDialog 居中卡片呈现——surfaceContainerHigh 底、28 圆角（继承全局 dialogTheme）、暗色遮罩、宽近全宽（桌面限宽 640）、高度随内容自适应（上限 85% 屏高）；头部 标题 + 自定义分组 + ⋮ 菜单（bookSource 六项）+ 重置，扫码移至空闲态地址栏后缀图标；底部 全选（n/m）| 取消 | 确认（n，FilledButton 胶囊，0 勾选禁用），导入完成汇总确定后连动关闭对话框（对齐原版 importSelect 后 dismiss）；状态文案统一为 新增/更新/已存在，状态色改用 colorScheme 角色（新增 tertiary / 更新 secondary / 已存在 onSurfaceVariant）；删除旧全屏 AssociationScreen 与 association 路由，deep_link_service / source_screen 两处入口改调 showAssociationImportDialog
- [UI] 修复勾选回弹隐患：freezed 的 items getter 每次访问都新建 EqualUnmodifiableListView 包装，旧实现按列表 identity 判定「列表未变」永远不成立，导致任何重建都会重置勾选（点选即回弹）；改为按 state 对象 identity 判定，并新增对话框渲染 + 勾选持久 widget test 回归守护

### Test
- flutter analyze 无问题；flutter test 1314 过（唯一失败为既有 FFI 运行时测试，后端轨范围）
- E2E（emulator-5556，adb reverse 隧道供包）：书源深链弹窗自动加载 → 取消/恢复勾选不回弹 → 确认（2）→「共 2 个书源：成功 2」→ 确定后自动关闭 → 重复导入显已存在/未勾选/确认（0）禁用 → 全选再导入成功；替换规则深链（标题/分组后缀/新增）→「共 2 个替换规则：成功 2」
- 两级冒烟：5556 PASSED（7/7）；5558 -CheckUI -SkipBuild PASSED（7/7）
- 版本 2.0.148+149

- Contributor: Qoder + UI

## [2.0.147] - 2026-09-02

### Changed
- [UI] 关联导入页重做为原版逐类确认页（用户反馈「和原版差异太大」，旧版为单一通用预览列表）：对齐原版 BaseAssociationViewModel.importJson 流程——JSON 字段自动识别 7 类内容（书源/RSS/替换规则/主题配置/HTTP TTS/字典规则/TXT 目录规则）；每行 = 勾选框 + 名称(+分组后缀) + 新/更新/已存在状态标签 + 「打开」入口，状态判定逐类对齐原版（书源按 URL+lastUpdateTime、替换规则按名匹配任字段不同即更新、字典规则无更新概念）；底部 全选(n/m)|取消|确认(n)，确认数随勾选联动；视觉风格遵循 MD3
- [UI] ImportResult 汇总单位按类型区分（新增可选 unit 字段）：此前各类型导入完成汇总均显示「共 N 个书源」，现按实际类型正确显示（如「共 2 个替换规则：成功 2」）

### Test
- flutter analyze 无问题；flutter test 仅余 1 个既有 FFI 运行时失败（后端轨 SEARCH_PARITY_S0 审计范围，与本批无关）
- E2E（emulator-5556）：书源导入全流程（新 → 确认(2) → 「共 2 个书源：成功 2」→ 再导入显已存在/未勾选/确认(0) 禁用）+ 替换规则导入全流程（标题 导入替换规则、分组后缀 (测试组)、新/勾选、结果汇总单位正确）
- 两级冒烟：5556 PASSED（exit 0，7/7 含版本一致 2.0.147）；5558 -CheckUI -SkipBuild PASSED（exit 0，7/7：版本一致 + 进程存活 + 无崩溃 + 书架 UI 元素）
- 版本 2.0.147+148

- Contributor: Qoder + UI

## [2.0.146] - 2026-08-31

### Fixed
- [UI] iOS 换图标 OSStatus -54 第八轮（GitHub 调研：社区实证结构为纯 legacy——完全不出现 CFBundleIconName）。tastelessjolt/flutter_dynamic_icon（123★）、chandrabezzo fork、capacitor/expo legacy 路径均以 `CFBundleIcons.CFBundleAlternateIcons.<name>.CFBundleIconFiles` + bundle 根散文件声明备选图标，无一使用 CFBundleIconName；本 app 是结构性离群者——Xcode 为每个备选自动生成双路径（现代 CFBundleIconName→car + legacy CFBundleIconFiles，第六轮设备 plist 实证），LaunchServices 若优先按现代路径解析、而 iOS 17.5 解不开 Xcode 16.4/SDK 18 编的 car → fNotFoundErr（-54），与散文件是否齐全无关（第七轮实证：散文件 12/12 仍 -54）。修复：CI 打包前用 plistlib 从所有 CFBundleAlternateIcons 条目剥离 CFBundleIconName（CFBundleIcons 与 ~ipad 两节），强制走与社区实证结构一致的纯 legacy 解析路径；散文件 12/12 已由前置步注入（新增门禁保证打包前可解析）。主图标不受影响
- [UI] CI Info.plist 导出门禁移至剥离步之后——工件 `ios-device-info-plist` 现反映最终包图标声明（剥离后状态）
- [UI] bridge 自检增强：status 增加 altModernDecl（仍携带 CFBundleIconName 的备选条目数，剥离后应为 0）；Dart 侧诊断行追加「现代声明 N」——-54 复发时一次回报即可归属剥离步是否执行

### Test
- flutter analyze 无问题；iOS Build CI：新增剥离步（12 文件门禁 + plistlib 剥离 + 验证输出），导出/上传门禁后移，既有 car 6/6 与集成测试门禁不变
- 版本 2.0.146+147

- Contributor: Qoder + UI

## [2.0.145] - 2026-08-31

### Fixed
- [UI] iOS 换图标 OSStatus -54 第七轮（用户实证：第六轮构建真机自检 声明✓/car 6/6/散文件12/12 全过仍 -54 → H2 legacy 缺口假设证伪，非完整根因）。本地取证新发现：CI Assets.car（854KB）内无任何 PNG/JPEG 签名——Xcode 16.4/SDK 18 actool 的图像记录采用非 PNG 编码；若 iOS 17.5 LaunchServices 解不开该 car，CFBundleIconName→car 的变体校验必然 fNotFoundErr（-54），与散文件是否齐全无关（H3 升为首要嫌疑）。本批落地 H3 判定探针：Assets.xcassets 新增常规 imageset `probe_image`，bridge status 用 `UIImage(named:)` 走同一 car 读取路径验证——真机报「car可读✗」即坐实 H3（需换兼容工具链重编资产）；「car可读✓」则排除 car 编码问题，转向旁载签名/LS 注册方向
- [UI] bridge 错误回传增强：reply 增加 NSError userInfo 全量 + underlyingError 转储（通用 OSStatus 错误通常无附加信息，若 UIKit 挂了 NSRecoverySuggestion/底层错误则一次回报即可见）
- [UI] CI 注入步补齐 60x60 @3x 散文件（launcher1~6 + 主图标 AppIcon60x60@3x，源图取 appiconset 内 180px 槽位）——此前 bundle 根只有 @2x，缩放完整性缺口一并关闭

### Test
- flutter analyze 无问题；iOS Build CI：注入步扩展（+7 个 @3x 散文件），既有 car 6/6 校验与集成测试门禁不变
- 版本 2.0.145+146

- Contributor: Qoder + UI

## [2.0.144] - 2026-08-31

### Fixed
- [UI] iOS 换图标 OSStatus -54 第六轮（用户实证：iOS 17.5 真机，声明✓/car 6/6、私有 API 旁路亦不生效 → 排除平台回归与旁载损坏；唯一剩余可具体验证的差异 = legacy 路径）：Xcode 只为 universal app 把 CFBundleIconFiles 的 76x76 变体编为 iPad idiom 散文件（launcherN76x76@2x~ipad.png），iPhone idiom 下该 base name 解析不到任何文件；LaunchServices 校验/回退 legacy 路径时每个变体图标注册即失效 → Carbon fNotFoundErr（-54）。标准 capacitor/expo 应用为纯 iPhone target、无此尺寸槽位，故不触发。修复：CI 打包前新增注入步，为每个 launcher 补 76x76@1x/@2x 非 ipad 散文件（源图取 appiconset 内 ipad 槽位），使 CFBundleIconFiles 全部条目在 iPhone 可解析且保留 iPad 支持
- [UI] bridge 自检增强：status 新增 looseIcons 字段——逐 CFBundleIconFiles base name 校验 bundle 根散文件可解析性（""/@2x/@3x 任一存在即算）；Dart 侧错误诊断行追加「散文件 X/Y」，若本修复无效可凭真机取证直接判定 legacy 路径是否已补齐

### Test
- flutter analyze 无问题；iOS Build CI：新增注入步（12 个散文件）+ 既有 car 6/6 校验与集成测试门禁不变
- 版本 2.0.144+145

- Contributor: Qoder + UI

## [2.0.143] - 2026-08-31

### Fixed
- [UI] iOS 换图标 OSStatus -54 第五轮（用户实证：干净卸载重装后仍报错 → 排除粘性状态，重开全部假设）：按取证计划落地真机自检通道——bridge `status` 主线程异步返回 systemVersion / supportsAlternateIcons / carHasAllLaunchers（对已安装 Assets.car 做字节级扫描，判定 launcher1~6 appiconset 是否齐全），失败时中继 NSError domain/code；Dart 端把自检结果自动拼入错误提示，一次报错即可区分「sideload 重签包丢失声明/资产」（分支判断 B）与「iOS 26+ 平台回归」（oobagi/expo-awesome-app-icon#1：iOS 26.1+ setAlternateIconName 被 LSIconAlertManager Code=35 拒绝，26.0 及以前正常）。公开路径失败时自动改走私有 API `_setAlternateIconName`（Capacitor 社区生产同款旁路模式），旁路成功则重启后桌面图标即变更

### Test
- flutter analyze 无问题；iOS Build CI：Assets.car 6/6 appiconset 校验 + 集成测试新增 carHasAllLaunchers==6 门禁（已安装包资产完整性）
- 版本 2.0.143+144

- Contributor: Qoder + UI

## [2.0.142] - 2026-08-31

### Changed
- [Tool] iOS Build CI 新增 Info.plist 导出门禁：最终设备 Info.plist（二进制定 + 图标段 JSON）作为工件 `ios-device-info-plist` 上传——第四轮 -54 取证证明构建产物本身完整（Assets.car 6/6 appiconset、CFBundleIconName 声明齐全、Xcode 自动注入 bundle 根散文件 + CFBundleIconFiles 双路径），后续真机失败复发时可直接比对最终包声明，无需下载解包 IPA

### Test
- 版本 2.0.142+143

- Contributor: Qoder + UI

## [2.0.141] - 2026-08-31

### Fixed
- [UI] iOS 换图标 OSStatus -54 第四轮根因（2.0.140 CI 实证：槽位结构已对齐仍 0/6 appiconset 入 car，car 恒为 AppIcon + LaunchImage）：actool 默认只把 `--app-icon` 指定的主 appiconset 编入 Assets.car，变体 appiconset 被静默跳过——除非 Runner.xcodeproj 构建设置声明 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`（launcher1~6）+ `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`。修复：Runner target 三个构建配置（Debug/Release/Profile）补齐这两项设置，与业界标准实现互证（expo-quick-actions 插件、ente/vellum 量产应用同款接线）；Info.plist CFBundleIconName 声明结构本就正确、无需改动
- [UI] CI 注释措辞更正：actool「unassigned children」警告门禁是 appiconset 编入 car 的必要非充分条件（批次 22），本批次根因为缺构建设置

### Test
- flutter analyze 无问题；iOS Build CI：Contents.json 文件名核查 + actool unassigned children 警告门禁 + Assets.car 6 appiconset 名校验（本次预期 6/6）+ 集成测试 altIconNames 门禁
- 版本 2.0.141+142

- Contributor: Qoder + UI

## [2.0.140] - 2026-08-31

### Fixed
- [UI] iOS 换图标 OSStatus -54 第三轮根因（2.0.139 CI 失败暴露）：actool 判定 6 个 launcher appiconset 各含 2 个「unassigned children」图像——手写的 Contents.json 含 legacy iPhone 20x20@1x / 40x40@1x 槽位，Xcode 16 的 app icon 模型已不识别（主图标 AppIcon.appiconset 无此两槽、编译干净且在 car 中），整组拒编入 Assets.car（设备 car 仅含 AppIcon + LaunchImage，187KB），真机 CFBundleIconName 解析必然再报 -54。修复：6 个 launcher Contents.json 全部对齐 AppIcon.appiconset 标准 19 槽位（移除 2 个 legacy iPhone 1x 槽；补 iPad 20x20@1x/2x 与 83.5x83.5@2x 槽），并从 git 历史恢复此前误删的 launcherN_167.png（iPad 83.5@2x = 167px）
- [UI] CI 新增 actool 警告门禁：设备构建日志出现「unassigned children」即失败——槽位模型错配在构建期直接暴露，不再流入真机验收

### Test
- flutter analyze 无问题；iOS Build CI：Contents.json 文件名核查 + actool unassigned children 警告门禁 + Assets.car 6 appiconset 名校验 + 集成测试 altIconNames 门禁
- 版本 2.0.140+141

- Contributor: Qoder + UI

## [2.0.139] - 2026-08-31

### Fixed
- [UI] iOS 真机换图标仍报「the operation couldn't be completed.(osstatuserror-54.)」（2.0.138 真机复测）：根因——无扩展名 CFBundleIconFiles 条目并非 Assets.car imageset 名的解析路径，78 个 imageset 全部编入 car 后 setAlternateIconName 在真机依旧失败（Carbon fNotFoundErr = -54）。切换 Apple 现代范式：6 个变体图标收敛为 launcher1.appiconset…launcher6.appiconset（各含标准槽位 Contents.json，与主图标 AppIcon.appiconset 同构），Info.plist CFBundleAlternateIcons 条目由 CFBundleIconFiles 数组改为 CFBundleIconName（值 = appiconset 名）——与主图标同一条已验证可用的解析路径；删除 78 个 per-size imageset
- [UI] 换图标回归门禁相应调整：LauncherIconBridge status 移除 assetCount UIImage 探针（该查找路径不覆盖 CFBundleIconName 解析），新增 altIconNames 结构探针（各条目「键=CFBundleIconName」对，自磁盘 Info.plist 解析）；集成测试断言改为 altIconNames == [launcher1=launcher1 … launcher6=launcher6]；CI Assets.car 静态校验改查 6 个 appiconset 名（AppIcon 标定双编码探针 + 尺寸回退），新增 Contents.json 文件名确定性核查步骤

### Test
- flutter analyze 无问题；iOS Build CI：appiconset 文件名核查 + Assets.car 6 名校验 + 集成测试 altIconNames 门禁（拦截「声明缺失/appiconset 未编入 → 真机 -54」回归）
- 版本 2.0.139+140

- Contributor: Qoder + UI

## [2.0.138] - 2026-08-31

### Fixed
- [UI] iOS 真机换图标报「the operation couldn't be completed.(osstatuserror-54.)」（用户真机报告）：根因——Info.plist CFBundleIconFiles 为无扩展名条目（launcher1_20…launcher6_1024），系统按 Assets.car imageset 名解析；而 78 张变体 PNG 原是带 .png 扩展名的 bundle 根目录散文件、资产目录中不存在对应 imageset，真机名称解析失败（Carbon fNotFoundErr = -54）。按 Apple 官方范式将 78 张全部迁入 Assets.xcassets per-size imageset（launcher1_20.imageset…launcher6_1024.imageset + Contents.json），pbxproj 移除散文件引用（320 行纯删除）
- [UI] 换图标回归门禁加固：LauncherIconBridge status 新增 assetCount 探针（UIImage(named:) 可解析的 78 个名称计数——与 setAlternateIconName 同一条查找路径，模拟器即可断言）；集成测试新增断言 assetCount == 78（运行时权威门禁）；CI 新增设备 Assets.car 校验步骤——AppIcon 标定双编码探针（ASCII/UTF-16）+ 尺寸回退门禁（Xcode 16.4 car 名称表非纯 ASCII，直接 grep 会误报），并上传设备 Assets.car 工件供离线分析

### Test
- flutter analyze 无问题；iOS Build CI：Assets.car imageset 全量校验 + 集成测试 assetCount 门禁（拦截「imageset 未编入 → 真机 -54」回归）
- 版本 2.0.138+139

- Contributor: Qoder + UI

## [2.0.137] - 2026-08-31

### Fixed
- [Rust] 漫画/图片源目录与正文获取失败（用户报告「大部分图片源获取不到目录和正文」）：Rust analyze_rule 未实现原版 AnalyzeByJSoup 规则链语义——`<js>` 规则带非 JSONPath 后缀文本时误路由到 JSONPath；`java.*` jsoup 规则前缀被丢弃、CSS 选择器未归一化（class.foo/id.foo/tag.foo → .foo/#foo/foo）、'@' 后链式选择缺失。按原版语义修复：HtmlParser::normalize_jsoup_selector + resolve_element_chain 链式选择 + extract_last 末段文本提取；包子漫画（优）真实网络验证 TOC 815 章、正文图片列表正常。批量诊断同时确认其余多数漫画源失败在站点侧（站点失效/反爬），非本应用代码问题
- [UI] 错误信息裸显「Instance of 'BridgeError'」：BridgeError 仅含 message 字段且无自定义 toString，直接展示异常对象即输出该字符串。新增共享工具 utils/error_message.dart（errorMessage），15 个文件 18 处裸显点统一改为提取 e.message
- [UI] iOS 换图标失败笼统提示「当前平台或系统版本不支持更换图标」（用户报告）：LauncherIconService.setIcon 由返回 bool 改为返回 LauncherIconResult，携带原生侧拒绝的真实原因（iOS 每次启动限一次 / Android API<26 / 通道未注册）；主题设置页展示真实错误；新增 iOS 集成测试 launcher_icon_ios_test.dart + CI 执行步骤（校验通道注册与 setAlternateIconName 调用结果）

### Test
- cargo test --workspace：ffi lib 330 pass，shushu 实时网络 1 env-fail（与基线一致）；cargo test -p legado-js --features quickjs 513 pass；包子漫画（优）真实网络 TOC 815 章 + 正文图片 OK
- flutter analyze 无问题 + flutter test 1313 全过
- iOS 运行时验证：CI ios-build.yml 新增 launcher icon 集成测试步骤（首跑校验通道注册与 setAlternateIconName）；版本 2.0.137+138

- Contributor: Qoder + Rust + UI

## [2.0.136] - 2026-08-31

### Changed
- [UI] 「切换图标」功能落地（对齐原版 change_icon，用户指令「还需要支持 iOS 换图标」）：主题设置页新增入口，7 选项点选即应用——Android 经 setComponentEnabledSetting 启用选中 Launcher1~6 Activity、禁用其余与主入口（API 26+，低于提示不支持）；iOS 经 setAlternateIconName 切换 CFBundleAlternateIcons 变体（重启后生效，恢复默认经 setAlternateIconName(nil)）；Windows 等桌面端无此能力整项隐藏
- [UI] 原版 7 个可切换图标全部同步：Android 侧 launcher1~6 自适应矢量 + drawable 前景/底色逐字节复用原版资产（含 md_yellow_600/md_grey_50 色值）；iOS 侧由自研渲染器生成 7 变体 × 13 尺寸共 78 张 AppIcon PNG 并入 Info.plist CFBundleAlternateIcons

### Test
- E2E 实测（emulator-5556）：选图标 3 → resolve-activity 指向 Launcher3、桌面图标变为朱红圆相「书」、经新图标启动应用正常；切回默认 → MainActivity 恢复、桌面图标还原，tile 值与持久化一致
- flutter analyze 无问题 + 1313 测试全过；冒烟 5556/5558（-CheckUI）双机 PASSED。版本 2.0.136+137
- iOS Build CI 构建修复（本提交之后追加）：pbxproj AlternateIcons 双重目录路径（f8b2551adb）+ LauncherIconBridge 改用真实 setAlternateIconName API（92106f87d0），CI 33399601642 三工作流全绿

- Contributor: Qoder + UI

## [2.0.135] - 2026-08-31

### Changed
- [UI] 应用图标三端同步为**原版 legado 图标**（用户指令「不要猫咪图标，同步原版图标」）：Android 直接复用原版 app/ 资产逐字节拷贝（mipmap-mdpi~xxxhdpi ic_launcher.png + anydpi-v26 自适应 ic_launcher.xml + drawable/ic_launcher1(_b/_4)），移除参考仓库猫咪矢量全套；iOS AppIcon 由原版自适应矢量（ic_launcher1_b 背景 + ic_launcher1 前景）自研渲染器生成（新增线性渐变填充 + 双圆心圆弧采样），master 1024 + 14 小尺寸；Windows app_icon.ico 同步重生成
- [Docs] docs/UI_UPDATE_LOG.md 图标条目更新为原版

### Test
- iOS 尺寸核对 19/19 OK；渲染与原版自适应图标（API 26+ 实际呈现）一致，192px 光栅为旧版式回退图不采用；Android 冒烟验证构建。版本 2.0.135+136

- Contributor: Qoder + UI

## [2.0.134] - 2026-08-31

### Changed
- [UI] 应用图标替换收尾——iOS AppIcon 全套（用户复核「iOS 版还是 Flutter 默认图标」）：由 Android 矢量前景 ic_launcher_foreground.xml（猫咪吉祥物 + 粉色圆环 + #2E2D3D 底）自研渲染器 2x 超采样生成 master 1024 + 14 个小尺寸，像素尺寸与 Contents.json 逐一核对通过；画面与 Android 自适应图标实际呈现一致（参考仓库 192px 光栅为自适应图标时代前的旧版式回退图，未采用）
- [Docs] docs/UI_UPDATE_LOG.md 待办销账：iOS 应用图标完成

### Test
- 校验：appiconset 文件名/像素尺寸 19/19 OK；纯资产替换无代码变更，Android 侧不受影响；iOS 构建验证随 iOS 轨下次 macOS 构建进行。版本 2.0.134+135

- Contributor: Qoder + UI

## [iOS 轨真机 Rust 初始化修复批次 2026-08-31]（版本 2.0.133+134）

### Fixed
- [iOS] 真机「Rust 引擎初始化失败」根因闭环：FRB 2.11 采用 PDE 分发器架构，Dart 侧运行时 dlsym 查找的是固定符号 frb_pde_ffi_dispatcher_primary / frb_init_frb_dart_api_dl 等（并非逐函数的 wire__* 符号）；Release 设备构建默认剥离符号表——实测修复前 ipa 的 Runner 二进制 nsyms=0、全部 FFI 符号缺失，dlsym 必然失败（模拟器 debug 无 strip 阶段故正常）。链接配置收敛为：-force_load 全量载入 + DEAD_CODE_STRIPPING=NO（防链接期裁掉无引用对象）+ STRIP_INSTALLED_PRODUCT=NO（防链接后剥符号表）
- [iOS] 移除上一轮误加的 exported_symbols_list 白名单（仅含 `_*`，会把全部 frb_* 导出排除在可执行文件导出区之外——与真机失败同向叠加的第三项有害配置）
- [CI] 符号校验步骤此前 grep 不存在的 wire__crate__ffi 名称（前两轮"失败"均为检查自身误报，非构建问题）；改为校验真实 PDE 符号并打印 symtab 符号总数作为诊断

- Contributor: Qoder + Bridge

## [2.0.132] - 2026-08-29

### Changed
- [UI] 热力图升级「按时长」模式（消费 Rust 契约 readRecordDailyList，API_CONTRACT §2.12 2026-08-29）：阅读记录页热力图新增 时长/本数 双模式切换（SegmentedButton，默认按时长），时长按 0/<10min/<30min/<60min/≥60min 五级配色，Tooltip 展示当日时长格式化；计数模式保留（记录 lastRead 落日去重）
- [UI] 应用图标替换（用户复核「还是 Flutter 默认图标」）：Android 全套换用参考仓库 legado 图标——各密度 ic_launcher/ic_launcher_round webp + 自适应 anydpi-v26（矢量前景 ic_launcher_foreground + 单色层 + 背景色 #2E2D3D）；Windows runner app_icon.ico 由 192px 源多尺寸生成；iOS 资产未动（iOS 轨活跃中，避免冲突）
- [Docs] 新增 docs/UI_UPDATE_LOG.md：UI 轨独立更新日志（MD3 迁移全部 17 批次汇总 + 主题系统/设计语言要点/质量守护/待办台账），面向「一次看全 UI 变了什么」
- [Test] 门禁：flutter analyze 0 issues、flutter test 全绿。版本 2.0.132+133
- Contributor: Qoder UI

## [iOS 轨 P2-C 锁屏控制批次 2026-08-31]（版本 2.0.131+132）

### Added
- [iOS] 锁屏控制/Now Playing：新增 NowPlayingBridge.swift（原生 MPNowPlayingInfoCenter + MPRemoteCommandCenter），通道协议逐方法对齐 Android MediaSessionBridge.kt——锁屏/控制中心/耳机线控的播放、暂停、上下曲、停止经下行 onPlay/onPause/onSkipToNext/onSkipToPrevious/onStop 回调 Flutter（方案上不引入 audio_service，避免与 Android 既有桥冲突及入口重构）
- [iOS] 系统中断（来电/Siri）经 AVAudioSession interruptionNotification 映射焦点事件（began→lossTransient，ended 按 shouldResume→gain/loss）；setWakeLock iOS 空实现（后台保活由音频会话承担）
- [iOS] 通道注册经 didInitializeImplicitFlutterEngine 的 pluginRegistry.registrar(forPlugin:).messenger()（registry 协议无 messenger，API 归属经 3.44.8 引擎头文件核实）；NowPlayingBridge.swift 手动注册进 Runner.xcodeproj 四处

### Fixed
- [iOS] Swift 编译三轮修正：registrar 可空 if-let / messenger() 零参调用 / 删非公 API MPNowPlayingPlaybackStatus（状态由 playbackRate 表达）/ interruption addObserver 显式 queue: .main

### Known Limitations
- [iOS] 锁屏进度条拖动暂不启用（通道协议无 seek 方向，Android 侧亦无）；封面 Artwork 未接入

- Contributor: Qoder + Bridge

## [iOS 轨 P2-B 原生补齐批次 2026-08-30]（版本 2.0.130+132）

### Added
- [iOS] 登录 Cookie 捕获：WKWebView Cookie 存于 WKHTTPCookieStore 且 webview_flutter 不暴露读取接口，_syncCookie 加 iOS 分支经 document.cookie 读取（局限：httpOnly 读不到，Android 通道无此限制；注释已注明）——书源 WebView 登录链路 iOS 可用
- [iOS] 后台听书基础：Info.plist UIBackgroundModes=audio + AppDelegate 配置 AVAudioSession .playback/.spokenAudio（不加 mixWithOthers，对齐 Android 音频焦点独占语义；静音开关不影响朗读、退后台继续播放）

### Closed
- [iOS] saf 条件化销记：audio_screen.dart（useSaf 含 Platform.isAndroid）与 bookmark_export.dart（仅 Android 走 SAF）既有守卫已覆盖 P2 对照表场景，无需改动
- [iOS] backstageEval 销记：platform_bridge_service 回退链路本就基于 webview_flutter（iOS=WKWebView 原生可用），无需 flutter_inappwebview

### Remaining（P2-C 待启动）
- [iOS] 锁屏控制/Now Playing：audio_service 包裹 StreamAudioPlayer（或原生 MPNowPlayingInfoCenter/远程命令），需重构音频播放接入 AudioHandler
- [iOS] 自动任务 iOS 降级策略（workmanager/BGTaskScheduler 受 OS 约束）
- [iOS] 逐功能真机走查（朗读出声/通知弹出/深链唤起/退后台续播）

- Contributor: Qoder + Bridge

## [iOS 轨 P2-A 原生补齐批次 2026-08-30]（版本 2.0.129+132，简单通道五件套）

### Added
- [iOS] P2-A 五通道插件化落地（每条 Android 走既有 Kotlin 桥零回归、iOS 走插件双分支）：TTS（flutter_tts 4.2.5，setSpeed 按 speed/2 折算 AVSpeech 刻度）/ 通知（flutter_local_notifications 18.0.1，下载与阅读状态固定 id 1/2，前台服务通知 iOS 空实现）/ 亮度（screen_brightness 2.1.11，应用窗口亮度）/ 设备号（device_info_plus 11.5.0 identifierForVendor，消除 P1 已知 MissingPluginException 降级项——模拟器实测 IDFV 注入成功）/ 深链（app_links 6.4.1 + Info.plist 注册 legado/yuedu scheme）
- [CI] iOS Build/Flutter CI/Integration Smoke 三工作流全绿；模拟器冒烟日志确认设备 ID 注入（iOS IDFV）真实工作

### Remaining（P2-B 待启动）
- [iOS] 后台隐身 WebView JS 求值（backstageEval）+ Cookie 同步：flutter_inappwebview
- [iOS] 后台听书三件套（前台服务/媒体会话/通知联动）：audio_service 包裹 StreamAudioPlayer
- [iOS] saf 插件调用点条件化（5+ 页面，file_picker 兜底）

- Contributor: Qoder + Bridge

## [iOS 轨 P1 里程碑批次 2026-08-30]（版本 2.0.128+132，Flutter+Rust 三端通用）

### Added
- [iOS] P1 里程碑达成：ios-build.yml（macos-15）全绿——Rust FFI 真机/模拟器双 target 静态库（quickjs）→ 未签名 ipa artifact（14 天保留）→ iOS 模拟器启动冒烟（书架页截图/进程存活/日志三证据），Rust FFI 静态链接实测工作（初始化 142ms、ttsSetCacheDir ok、DB 打开）
- [iOS] Dart 侧 _resolveFfiLibrary 增加 iOS 分支：静态链接符号经 ExternalLibrary.process() 查找（FRB 默认 loader 只找 dylib/framework）
- [iOS] ios/Podfile 初始化 + RustFFI 本地 pod（vendored_libraries + -force_load 全量载入，Dart FFI 运行时查符号依赖最终二进制含全部对象）
- [CI] 新增 .github/workflows/ios-build.yml（Rust iOS 编译 → Xcode 无签名构建 → Payload 打包 → 模拟器冒烟）

### Fixed
- [Rust] 解除对 app/ 目录的编译期依赖（安卓源码移出后 CI 编译失败）：dictRules/coverRule 种子 JSON 收入 rust/assets/defaultData/；mcp.rs 的 18 个 web help md 收入 rust/assets/web/help/md/；unrar（C++）与 Android 同策略排除 iOS（archive.rs 降级分支扩为 any(android, ios)）
- [Rust] legado-js：rquickjs 对 apple 目标启用 bindgen 运行时生成（rquickjs-sys 0.9 预置绑定无 iOS；本地 Windows 预生成绑定路径不变）
- [CI] rust-toolchain.toml 锁定 1.97.1 导致 cross-target 编译 E0463（target 装在 stable）：ios-build/flutter-ci 改 working-directory rust 内 rustup target add
- [CI] iOS 构建改 cargo rustc --crate-type staticlib（跳过无用的 cdylib 链接，compiler-rt ___chkstk_darwin 缺失）；模拟器 bindgen 追加 -simulator 三元组覆盖 rust 风格 --target；模拟器构建改 debug（flutter 不支持 simulator+release）
- [CI] Flutter 版本统一 3.44.8（book_group_screen onReorderItem 需 3.44+；本地即 3.44.8，ios-build/flutter-release 同步）；flutter-ci 补 workflow_dispatch

### Known Issues
- [iOS] 设备 ID 注入 MissingPluginException（预期内，P2 用 device_info_plus 替换）
- [iOS] ipa 为未签名，装机需 AltStore/Sideloadly/爱思助手自签（7 天）；正式分发需 $99 开发者账号（待用户决策）
- [iOS] RAR 漫画不支持（与 Android 基线一致）

- [CI] flutter-ci android-ffi-sync 首次全绿（该 job 自创建以来因 E0463 从未通过，本轮逐层修复后完整跑通）：NDK CC/AR 按 target 显式注入（ring 等 C 依赖）；bindgen NDK bionic sysroot + 三元组 asm 头目录；verify-ffi-android.sh hash 提取修正（i32 的 32 被误抽数致校验恒失败）；FFI 运行时流测试非 Windows 跳过（CI 无 DLL 产物）
- Contributor: Qoder + Bridge

- Contributor: Qoder + Bridge

## [GitHub CI 收敛批次 2026-08-30]（仓库治理，不涉应用功能）

### Changed
- [CI] fork（LegadoTeamFlutter）master 修复三处持续 workflow 错误：Sync Upstream 每日失败（上游 gedoor/legado 仅剩 main 分支，fetch master 恒 404；且其自动同步上游安卓源码与「安卓源码不上传 GitHub」指令冲突，已删除）；flutter-ci android-ffi-sync 工具链错误（rustup --default-toolchain none 后直接编译报 E0463，改 dtolnay/rust-toolchain@stable + android targets）；test.yml 被 GitHub 判无效文件（job 级 if 引用 secrets 上下文 + 8-25 注释缩进混乱）产生 0 秒失败 run
- [CI] 据用户指令「安卓源码部分不上传 GitHub」收敛远端视图：app/ 与 modules/（约 2540 文件）解除跟踪并从远端树移除（本地磁盘保留参照）；删除全部安卓构建工作流（test/BetaRelease/release/cronet/web/TestRelease）与 legado.jks 签名密钥；GitHub 仅保留 Flutter CI（含修复）/Rust CI（含 fmt+quickjs clippy 门禁）/Integration Smoke/Flutter Release 及轻量工具流
- [Docs] 本地 .gitignore 新增 /app/ 与 /modules/ 不上传名单；历史提交仍含安卓源码旧快照，彻底清除需 filter-repo 重写（另行授权）

- Contributor: Qoder + Bridge

## [搜索/换源 parity 审计修复批次 2026-08-29]（版本 2.0.127+132）

### Fixed
- [UI] 审计 D1——换源分组过滤分隔符补齐 `,;，；` 全集（change_source_notifier.dart 预过滤 + change_source_screen.dart 分组聚合，对齐原版 splitGroupRegex/SearchBookDao.kt:13-32）：分号分组的书源不再被 Dart 预过滤整源丢弃，Rust source_group_contains（四分隔符齐全）不再被架空
- [Rust] 审计 D2——换源候选剔除"无详情页 URL"条目移除（source_switch.rs）：原版 BookList.kt:281-284 对 bookUrl 空条目回退 baseUrl 照常入列表；解析层 S0-E 已有同款回退，空 URL 候选保留展示、点击切换时由 switch_book_source 兜底报错
- [Rust] 审计 D3——multi_source_search 一次性入口补落库 searchBooks（search_books 已有同款；对齐原版 SearchModel 两入口均落库，防后续调用方换源 DB 缓存偏少）
- [Rust] 审计 D4——JS 书源结果应用 precision filter（search.rs，原版 WebBook.kt:47 把 filter 传入 JsSourceBook.searchAwait）：精准搜索开启时 JS 源不再多出未过滤条目
- [UI] 审计 D5——换源筛选框只按书名 contains（ChangeBookSourceViewModel.kt:184），移除源名匹配
- [Rust] 审计 D6——换源同名判定收紧为 trim 后字面全等（source_matcher.rs 删除 normalize_book_name 括号归一化，对齐原版 fName == name equals）；换源读库改原样书名查询（ChangeBookSourceViewModel.kt:603-625），库内书名解析期已 formatBookName，不再二次归一化

### Test
- [Test] 新增 D1 分组过滤回归测试（分号/全角逗号组名的源必须进入 sourceUrls）；source_matcher 同名判定测试迁移至字面全等口径。门禁：workspace 2482/0、quickjs 397/0、flutter analyze 0 issues、flutter test 1313 全绿
- Contributor: Qoder + Bridge

## [热力图每日时长契约批次 2026-08-29]（版本 2.0.126+131）

### Added
- [Rust] readRecordDaily 每日时长聚合（U 侧 UI_MD3_PLAN 登记需求）：legado-db 新增日聚合表 readRecordDaily（date TEXT PK + durationSeconds INTEGER，懒建表无迁移）+ add_daily_seconds/list_daily_year；api 层 putReadRecord 写路径单作用域增量聚合（增量 = 新 readTime − 旧 readTime，仅 > 0 入账，本地时区 YYYY-MM-DD）；新增 readRecordDailyList(year) FFI 查询（返回 [{date, seconds}] 日期升序）
- [Bridge] FRB 绑定重生成（frb_generated.rs/.dart + ffi.dart readRecordDailyList）；BookApi 抽象 + RustApi/MockBookApi 双实现补齐（API_CONTRACT §2.12 阅读记录 5→6 方法）
- [Docs] API_CONTRACT §2.12 登记 + §3 UI 需求登记区销记；UI_MD3_PLAN 热力图登记项交付注记；REFACTORING_ACTIVE_PLAN 修订行

### Test
- [Test] legado-db daily 2 项（同日多次累加/跨年隔离升序）；legado-ffi upsert 联动 1 项（全量/增量入账 + get_read_time）——api 层直测即生产路径（bridge.rs 手工桥与 FRB 面同源）
- Contributor: Qoder + Bridge

## [搜索 parity 批次 2026-08-29]（P0-3 收尾 + S0-B/S0-E；Rust 行为批次,版本号随发布批次定版）

### Fixed
- [Rust] P0-3 强化:c5f82a854——drive_source_batches 收集循环阻塞于 set.next() 时取消不可观察,取消置位后最长等 30s 才 abort 在飞;改为 wait_cancelled(50ms) 与 set.next() 在 tokio::select! 竞速,取消即时 abort_all+drain。test_drive_cancel_wakes_blocked_collect_promptly 锁定
- [UI] 91e40dfad——搜索取消先调 Rust cancelSearch 置会话标志(≤50ms 生效)再拆 frb 流订阅;此前先拆流(实测可达 6.5s)导致取消延迟、排队源仍被派发
- [Rust] bb521c366——补齐 G4 限速模块文件与接线,修复 511a0bb52 起干净树编译缺文件(误提交 mod.rs 引用而模块文件未跟踪)

### Changed
- [Rust] S0-E 4330acaf9——主搜索路径收敛原版 WebBook 语义:loginCheckJs 三路径(WebBook.kt:74-98)、bookUrlPattern 详情直连(BookList.kt:62-81)、空列表详情回退(100-108)、bookUrl 空回退最终 URL(281-284)、去重键改 bookUrl 单键(SearchBook.kt:65)、非 2xx 不折叠错误(AnalyzeUrl.kt:499-534);FFI 签名不变,web_book 四辅助函数 pub(crate) 复用
- [Test] S0-B 511a0bb52——tests/fixtures/search_s0/ 七场景夹具(六件套,脱敏+SHA-256)+ s0_fixture_tests 主生产执行器消费断言(本地夹具服务器);workspace 2474 passed/0 failed、QuickJS lib 389/0
- [Docs] 5c56338d9——计划文档 §8 续作台账 + 实机 e2e 双机 verdict/服务器日志证据归档 docs/evidence/search_parity_20260829/;系统性风险登记:FFI 未变更时 .so 陈旧不可被 FRB hash 校验发现
- [Tool] e2e_p03_cancel_research.py(实机取消重搜 e2e,双机 7/7)+ s0c_server.py/s0c_compare.py(S0-C 双包对比工具,原版端自动化待续)

- [Rust] P3-6 阶段三 `837516a08`——precision filter 解析期对齐原版（SearchModel.kt:106-113 三字段或语义,列表/pattern 直连/空列表回退三处应用点,FFI 签名零变更经配置读取,p3f_tests 5 项）；持久化与 hasMore 语义随解析期过滤自动对齐。workspace 2479 passed/0 failed、QuickJS lib 393/0
- [Docs] 台账标记 S0-C 原版端为唯一未完成项（环境阻断,续作路径 §8.8）+ P3-6 阶段三完成登记（`939bb5f70`）
- Contributor: Qoder + Bridge

## [2.0.122] - 2026-08-28

### Changed
- [UI] 风格细节对齐批次（用户批准 P1+P2+P3，功能零变更）：**P1 大标题 28→24**——Flutter SliverAppBar.large 展开态硬编码 headlineMedium(28)，参考仓库 Compose M3 LargeTopAppBar 为 headlineSmall(24)，经子树级 Theme 覆写（headlineMedium→headlineSmall.apply(onSurface)，仅影响头部 sliver 内部、工具栏 titleLarge 与展开/折叠动画不受影响）；**P2 移除 iOS 式行尾展开箭头**——IosListTile 删除 showDisclosure 机制（64 处实参清理）+ 11 处直接 Icons.chevron_right（bookshelf 最近阅读/audio/change_source/remote_book 文件夹行/import×3/search_content/theme_config 色块行与列表行/video_settings_dialog/explore_book_list），原版 Android 列表无行尾箭头，属消除既有偏差；**P3 设置枢纽图标 Symbols 试点**——settings/other_settings/theme_config 三页全部图标换 Material Symbols rounded（约 30 种映射，library_books/menu_book、exit_to_app/logout 等）；P1b 搜索范围区块标题 17/w600 → titleMedium（book_info 书名 22 w700 与 font 字号预览 18 判定为内容元素保留）
- [Test] 门禁：flutter analyze 0 issues、flutter test 1308 全绿。保留：explore 展开旋转指示与 file_manage 面包屑分隔箭头（功能语义）；reader 域 5 处（计划排除）。版本 2.0.122+126
- Contributor: Qoder UI

## [2.0.121] - 2026-08-28

### Changed
- [UI] MD3 Expressive 加载动画补齐（用户复核指令「加载动画参考风格目标」）：新增 Md3LoadingIndicator 波浪加载环（参考 Compose Material3 Expressive LoadingIndicator 视觉签名——环形半径正弦波调制 + 幅度呼吸 + 相位流动，CustomPainter 自绘，主色 token）；LoadingIndicator/LoadingOverlay 页面级加载统一接入（书架/发现/订阅/源加载等全部消费点自动升级），遮罩改 onSurface 24% + surfaceContainerHigh 卡片化容器；系统「减少动画」偏好下退化为静态 240° 弧；Semantics 语义标签进无障碍树。操作级小指示器（按钮内 spinner 等）维持 M3 标准圆形（Expressive 参考同款用法）
- [Test] 新增 md3_loading_indicator_test（渲染/语义/减少动画退化/多帧稳定/message 展示/遮罩结构）；loading_overlay_test 断言迁移至波浪环。全量门禁 flutter analyze 0 issues、flutter test 1308 全绿。版本 2.0.121+125
- Contributor: Qoder UI

## [2.0.120] - 2026-08-28

### Changed
- [UI] 登录域原版对齐审计与重构（用户授权「不一致可重构」）：逐分支对照原版 ui/login/（SourceLoginActivity/SourceLoginDialog/SourceLoginV2Delegate/WebViewLoginFragment）——V2 动态状态协议分支（isLoginUiV2 → LoginV2Dialog）与经典 loginUi 表单分支（hasLoginForm → ClassicLoginDialog：select/toggle/button 类型、action js、✓login()、查看/删除登录头、清除登录信息、日志、关闭暂存草稿）确认与原版一致；**无表单分支重构**：原版为内置 WebViewLoginFragment（系统 CookieManager 自动持久化，用户无感），我方原为外部浏览器 + 手动复制 Cookie，本次对齐——新增 CookieBridge.kt（原生通道 legado/cookie 读 android.webkit.CookieManager，Windows 桌面优雅降级空串）+ WebViewLoginScreen（内置 WebView 打开 loginUrl 绝对化 + 书源 header 附加头，页面加载开始/结束自动同步 Cookie 落库 loginHeader，顶栏「检测」重载校验后返回，非 http(s) 跳转转外部打开，手动凭据页降级为菜单次级入口能力保留）
- [Test] 新增 webview_login_header_test（书源 header JSON/kv/空/非法四分支解析）；全量门禁 flutter analyze 0 issues、flutter test 1304 全绿。登记跨轨待办（需 Rust 契约，本轮不动）：V1 动态 loginUi JS 渲染（renderLoginUi/java.addRowUi 绑定）、viewName JS 表达式求值、text 行 action 联动、按钮长按 isLongClick；rssSource/httpTts/autoTask 源登录入口未接（现仅 BookSource 调用方）。版本 2.0.120+124
- Contributor: Qoder UI

## [2.0.119] - 2026-08-28

### Changed
- [UI] MD3 全量清点（用户复核指令）：按源码对账 65 屏/路由/三级菜单，确认无缺失页面；清出并修复最后的 iOS 残留——①explore_kind_layout 发现分类加载失败弹窗 CupertinoAlertDialog → M3 AlertDialog（dialogTheme 继承）；②explore_kind_layout 字符选择与 explore_page_control 页码选择两处 CupertinoPicker 底部弹层 → 新增共享组件 md3_picker_sheet.dart（showModalBottomSheet 走 bottomSheetTheme + ListWheelScrollView 轮式选择，M3 时间选择器同款轮式语义）；③theme_config/other_settings/welcome_config 三页共 9 处 iconBackground 彩色图标底（Colors.green/blue/teal/indigo/orange 硬编码）清除，统一走 IosListTile 的 MD3 tonal 容器；④welcome_config Colors.grey 说明文字 → onSurfaceVariant token
- [Test] 门禁：flutter analyze 0 issues、flutter test 1300 全绿。登记保留项：manga_config_sheet 的 CupertinoSlidingSegmentedControl 属漫画阅读器沉浸域配置面板（计划「沉浸式屏 Sheet 不改」排除）；reader 域 CupertinoColors/白黑系与 source_debug/rss_source_debug 调试日志级别语义色为已登记功能例外。版本 2.0.119+123
- Contributor: Qoder UI

## [2.0.118] - 2026-08-28

### Changed
- [UI] MD3 迁移 B1 遗留项销账：主 Tab 根页可折叠 LargeTitle（版本 2.0.118+122）。新增 LegadoTabRootHeaderSliver/LegadoLargeTitleScroll（legado_app_bar.dart）：书架主内容态将 app bar 以 sliver 并入 CustomScrollView——无分组用 SliverAppBar.large（152dp 展开大标题，滚动折叠为标准 M3 AppBar，跳顶随滚动自然复位）、有分组用 pinned SliverAppBar 承载分组 TabBar（保持原版嵌入结构与工具栏高度）；「我的」经 NestedScrollView+SliverAppBar.large 装配；「发现」「订阅」顶栏为原版 view_search 嵌入式搜索框（无标题文字），按原版对齐红线维持既有顶栏并在计划文档登记口径。加载/错误/空态保留标准 LegadoAppBar
- [Test] settings_test 迁移 LargeTitle 断言：标题 find.text('我的') 双实例（展开/折叠 title 共存）改 findsWidgets；滚动定位改 dragUntilVisible 指定内层 ListView + 回拖脱离 pinned 头部遮挡区
- [Test] 两级冒烟补跑（后端轨释放模拟器后）：emulator-5556 冒烟 PASSED 7/7（含 B1–B6 全部内容 + LargeTitle）；emulator-5558 -CheckUI PASSED 8/8（书架/发现/订阅/我的元素齐全、无崩溃、版本 2.0.117 安装校验）。UI_MD3_PLAN.md 实施状态同步销账。版本 2.0.118+122
- Contributor: Qoder UI

## [2.0.117] - 2026-08-28

### Changed
- [UI] MD3 迁移收尾（docs/UI_MD3_PLAN.md）：验收矩阵自动化 + 真实缺陷修复。新增 test/widget/md3_acceptance_matrix_test.dart（15 项：theme_config/home/settings/search × WH/koharu/sora × 亮暗渲染矩阵、0.8x/1.6x 字体缩放边界、底栏触控目标 ≥48dp、调色板语义标签）；golden 基线以渲染矩阵替代（跨平台字体差异使 golden 脆弱，截图验收并入模拟器 -CheckUI 流程）；修复矩阵抓获的 2 个真实溢出：theme_config 调色板卡片色点行窄格溢出 2.8px（FittedBox 兜底）、error_view 1.6x 缩放长信息溢出 321px（改滚动布局）；UI_MD3_PLAN.md 增补「实施状态」（B0–B6 全落地 + 遗留项登记：LargeTitle/Material You/冒烟并入验收）；清理 .tmp_net 研究产物（色数据已固化 md3_colors.dart + 校验测试）。版本 2.0.117+121
- [Test] 全量门禁：flutter analyze 0 issues、flutter test 1300 全绿（+15 验收矩阵）
- Contributor: Qoder UI

## [2.0.116] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 6（docs/UI_MD3_PLAN.md）：设置长尾/admin/misc 收尾 + 全域复核。域审计确认 9 屏（settings/other_settings/webdav_settings/cache_settings/file_manage/auto_task/app_log/about/import/archive_import_dialog）已基于 colorScheme token 与 Ios* 组件继承 MD3；「我的」页 iOS 彩色图标底移除，统一走 IosListTile MD3 tonal 容器（primaryContainer/onPrimaryContainer）；app_log 页内 TabBar 白色系前景改走全局 tabBarTheme（M3 surface AppBar 下白字不可见）；12×亮暗 WCAG AA 对比度复核由 test/unit/md3_palette_test.dart 全矩阵自动化覆盖（Batch 0 已落地）。版本 2.0.116+120
- Contributor: Qoder UI

## [2.0.115] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 5（docs/UI_MD3_PLAN.md）：RSS/音视频/缓存域收尾。域审计确认 9 屏（rss/rss_articles/rss_article_detail/rss_favorites/video/audio/read_aloud_config/cache_download/offline_cache）已基于 colorScheme token 与 Ios* 组件继承 MD3；rss 卡片阴影 Colors.black → colorScheme.shadow token（对齐 book_grid_item 先例）；audio 播放 FAB 加载圈 Colors.white → onPrimaryContainer（FAB 已走 M3 primaryContainer 底）；video 黑底白控件为播放覆盖层功能例外保留。版本 2.0.115+119
- Contributor: Qoder UI

## [2.0.114] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 4（docs/UI_MD3_PLAN.md）：源编辑/调试/开发域收尾。域审计确认 16 屏（source/source_edit/source_debug/code_edit/js_source_edit/rule_sub/replace_rules 及 import_confirm/txt_toc_rules/source_login/highlight_rules + RSS 源管理四屏）已基于 colorScheme token 与 Ios* 组件继承 MD3；js_source_edit 编辑区白底 token 化（surfaceContainerHighest，对齐 code_edit 方案，修复暗色主题刺眼）；登记功能色例外：source_screen 启用状态红绿语义（对齐原版）、source_debug 日志色块选中白字（深色 shade 配对注释）、source_edit QR 白底（可扫性）、replace_rules 着色头部半透明输入（onPrimary 配对）。版本 2.0.114+118
- Contributor: Qoder UI

## [2.0.113] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 3（docs/UI_MD3_PLAN.md）：搜索/发现/浏览域收尾。域审计确认 8 屏（search/search_content/explore/explore_show/dict/association/browser/qrcode）与组件（search_bar_widget/search_filter_panel/tag_chip/source_card/explore_kind_*）已基于 colorScheme token（tag_chip 即 M3 chip 形制：secondaryContainer/onSecondaryContainer），无 iOS 专属视觉残留；search 源筛选分段按钮 iOS 白底选中态改为 M3 segmented 视觉（secondaryContainer/onSecondaryContainer）；association 步骤指示圆点前景 Colors.white → onPrimary token。版本 2.0.113+117
- Contributor: Qoder UI

## [2.0.112] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 2（docs/UI_MD3_PLAN.md）：书架/书籍域收尾。域审计确认 12 屏与 book_cover/book_grid_item/book_list_item/chapter_tile 组件已全面基于 colorScheme token 与 Ios* 共享组件（Batch 0 改造后自动继承 MD3），无 iOS 专属视觉残留；bookshelf 分组 TabBar 去硬编码白色前景改走全局 tabBarTheme（M3 surface 背景下白字不可见）；toc 书签滑动删除图标 Colors.white → colorScheme.onError。版本 2.0.112+116
- Contributor: Qoder UI

## [2.0.125] - 2026-08-29

### Changed
- [UI] 内页图标全量 Symbols 化（UI_MD3_PLAN.md 第三节图标项收尾，用户放行）：非 reader 域 73 文件、177 种经典 Icons 全量换用 Material Symbols rounded（通用规则：_outlined/_outline 剥离 + _rounded；特例 radio_button_off→radio_button_unchecked、copy/paste→content_copy/content_paste、star_border→star 描边态、help_outline→help 等），Symbols 总用量 513 处，非阅读器域残留 0；reader 域 106 处按计划保留经典 Icons（沉浸式屏不动）。7 个测试文件图标断言同步迁移（chapter_tile/explore_show/highlight_rules/new_pages/offline_cache/search_bar/replace_rules/tag_chip/toc_cache_icon）
- [Docs] UI_MD3_PLAN.md 遗留项销账（图标全量化完成）；登记热力图每日时长 Rust 契约待办（c941a246b）。至此计划文本交付项全部完成
- [Test] 门禁：flutter analyze 0 issues、flutter test 1312 全绿。版本 2.0.125+130
- Contributor: Qoder UI

## [2.0.124] - 2026-08-29

### Changed
- [UI] 参考仓库优秀设计移植批次（用户批准 1/2/3/4，红线口径同批修订）：**① 翻滚数字推广**——搜索页结果计数、顶部 x/y 源进度、右下浮动进度卡三处计数全部接入 Md3AnimatedTextLine；**② 快速滚动条**——新增 Md3FastScroller（对齐原版 FastScroller：右侧拖拽滑块按滚动比例同步、拖拽时加宽变 primary、不足一屏自动隐藏），接入书源管理两种列表模式（千级源拖拽定位）；**③ 阅读热力图**——新增 Md3HeatmapCalendar（对齐参考 HeatmapCalendar counts 模式：52 周 GitHub 打卡风格、当日阅读书籍数 5 级配色、图例、未来日期隐藏、Tooltip），阅读记录页顶部默认收起的可选区块（ExpansionTile）接入，诚实口径 = counts（每日书籍数，基于 lastRead 真实数据），「每日时长」需 Rust 日聚合契约登记跨轨待办；**④ 颜文字空态彩蛋**——EmptyState 新增 kaomoji 模式（32sp 随机颜文字点击切换 + 提示文字翻滚，对齐参考 EmptyMessage），搜索无结果空态接入
- [Docs] AGENTS.md 重构红线口径修订（892617687）：「未经允许禁止新增原版不存在的功能，用户明确授权的除外」
- [Test] 门禁：flutter analyze 0 issues、flutter test 1310 全绿；修复 FastScroller 布局前维度未就绪空断言（hasContentDimensions/hasViewportDimension 守卫）。版本 2.0.124+128
- Contributor: Qoder UI

## [2.0.123] - 2026-08-29

### Changed
- [UI] 搜索来源数角标对齐参考动画（用户复核指令「书籍名称右边跳动的数字」指 HapeLee/legado-with-MD3 风格目标）：克隆参考仓库逐源码定位——角标 = TextCard（surfaceContainer 底 + 4dp 圆角 + labelSmall 中性前景）内嵌 AnimatedTextLine（文本变化时旧文本向上滑出、新文本自下滑入的翻滚效果，AnimatedSwitcher slide 无淡入淡出）；新增共享组件 md3_animated_text_line.dart 并重写我方角标（原为 primary 色块红数字静态文本；单源仍显示书源名便于辨认）
- [Test] 新增 md3_animated_text_line_test（初始渲染/数字递增翻滚/旧文本移除）；全量门禁 flutter analyze 0 issues、flutter test 1310 全绿。版本 2.0.123+127
- Contributor: Qoder UI

## [2.0.111] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 1（docs/UI_MD3_PLAN.md）：主框架 + 主题选择器。引入 material_symbols_icons ^4.2960（Material Symbols 可变字体，FILL 轴做选中态）；home_screen 底栏默认图标由内置 SVG 切换为 Material Symbols rounded（四 tab，选中 fill=1，labelBehavior 走 M3 标准），底栏皮肤用户图路径完整保留；legado_app_bar 返回箭头 M3 化（主 Tab 根页 LargeTitle 随各 Tab 所属批次落地）；theme_config 新增「内置主题」12 套调色板选择网格（亮暗双色预览 + 选中描边，paletteId 即时生效并持久化），原白天/夜间分组更名「自定义主题 · 白天/夜间」并存；Hero 封面过渡基础设施：BookCover 增 heroTag（约定 cover:<bookUrl>），bookshelf/book_info 两端接通
- [Test] theme_config_test 迁移：新增内置主题网格渲染/点按切换用例，通用项断言改为先滚动，分组名对齐双区结构
- Contributor: Qoder UI

## [2.0.109] - 2026-08-27

### Fixed
- [Rust] 搜索 parity 审计落地：主搜索 `search_single_source` 接入书源 `concurrentRate` 固定窗口节流（G4，抽取 `source_rate_limit` 与 web_book 共用）；换源网络路径改 `buffer_unordered(SEARCH_CONCURRENCY)` + 60s 单源超时（对齐原版 ChangeBookSourceViewModel）；换源读库对书名/作者做 `format_book_name/author` 归一化并打日志，修复主搜索落库与换源精确匹配键不一致导致二次全量搜索
- [Tool] 新增 `scripts/search_probe.ps1`（批量探针 + 失败分类）与 `scripts/e2e_search_compare.ps1`（5558 双包 DB 统计模板）；审计报告 `docs/SEARCH_PARITY_AUDIT_20260827.md`
- Contributor: Cursor Agent

## [2.0.110] - 2026-08-28

### Changed
- [UI] MD3 迁移 Batch 0（docs/UI_MD3_PLAN.md）：主题地基切换 Material Design 3 Expressive。新增 `lib/src/theme/md3_colors.dart`（12 套内置调色板 × 亮/暗 47 role，逐字取自 legado-with-MD3@6dc29722，`tool/gen_md3_colors.py` 生成）；`app_theme`/`app_typography` 重写为 M3 type scale + Expressive 大圆角组件主题（卡片 20 / 弹窗 28 / 按钮 StadiumBorder）；`ios_widgets` 集中改造为 MD3 token（消费屏零改动继承）；`paletteId`（SharedPreferences `app_palette_id`，默认 wh，自定义 themeConfigList 4 色并存且优先）；ThemeNotifier 启动加载竞态守卫（加载完成前的用户操作不被旧持久化值覆盖）；`docs/design_system.md` 重写为 MD3 token 单一事实源。版本 2.0.110+114
- [Test] 新增 `test/unit/md3_palette_test.dart`：12 套调色板锚点守护 + 11 套不透明 × 亮/暗 WCAG AA 4.5 对比度全矩阵（elink onSecondaryContainer 3.95 按 AA-large 3.0 登记例外）；theme_provider/settings_service 测试扩展 paletteId 读写与加载竞态回归；同步 search_notifier_test 日志级别断言（a08394d5d 遗留未更新）。门禁：flutter analyze 0 issues、flutter test 1284 全绿
- Contributor: Qoder UI

## [2.0.108] - 2026-08-27

### Fixed
- [UI] 书源搜索错误日志被静默丢弃（根因）：search_notifier 以 level:'error' 推送 per-source 搜索错误，Rust AppLog FFI 仅接受 message/crash/http（log_api.rs parse_level），非法级别返回 Err 后被 catchError 吞掉，应用日志「消息」tab 恒为空、无法排查书源失败。改为 message 级（对齐原版 AppLog.put 无级别过滤的留痕语义）
- Contributor: Qoder UI

## [2.0.107] - 2026-08-25

### Fixed
- [Tool] 搜索结果页书籍加载慢（根因·实测）：模拟器校验脚本以 `-Mode debug` 编译 Rust FFI —— DEBUG .so 在设备端性能约为 release 的 1/10（favcomic 解析 C≈12s vs ≈1s；get_elements(36 items) 73ms vs 8ms；单字段 ~60ms vs ~5ms），导致批次A引擎缓存节省（~80ms/源）完全不可见。`scripts/emulator_smoke_test.ps1` 改以 release 编译 .so（Dart APK 本身仍为 debug，迭代速度不变）
- [UI] 搜索结果页上下滑动卡死（根因·实测）：CoverDecodeLoader 仅按单 origin 缓存 patched JSON，每个新 origin 进视口即触发一次全量 getBookSources() FFI（~590KB / 500 源 + 主 isolate jsonDecode + 500×BookSource.fromJson），N 个新源 = N 次卡顿。改为内存书源注册表：整表一次 FFI（对齐原版 BookSourceRepository 内存语义），后续 origin 全部命中内存；RustApi 七个变更方法（add/update/setVariable/delete/enable/disable/import）统一失效，对齐原版「内存列表随 DB 变更即时刷新」语义
- Contributor: Cursor UI + Tool

## [2.0.106] - 2026-08-25

### Fixed
- [UI+Rust] 换源页 UI 对齐原版 ChangeBookSourceDialog（逐项对照，红线清理）：① 列表项加 👍/👎 用户评分（Red A200 / Blue A200 对标原版；增量 FFI updateSearchBookScore / deleteSearchBook + searchBooks.bookScore v106 迁移 + searchSource 响应 book_score，source_matcher 排序 book_score 优先于匹配分，同步书源聚合分 sync_source_score_delta 对齐 SourceConfig.setBookScore）；② 移除自创「匹配分」数字角标（原版不存在的创意功能 = 重构红线项）；③ 长按列表项五项菜单（置顶 / 置底 / 编辑书源 / 禁用书源 / 删除，对标 ChangeBookSourceAdapter；删除当前源自动切换下一候选）；④ 底部栏：当前源标签（点按滚动定位）+ 滚到顶部/底部按钮（hasClients 改点按时判定而非构建时）；⑤ 标题布局 title=书名 + subtitle=作者（取代单行「换源 - 书名」）。API_CONTRACT.md §2.4 16 方法 / 合计 267
- Contributor: Cursor UI + Bridge

## [2.0.105] - 2026-08-25

### Fixed
- [Rust] 搜索/书籍详情 JS 执行性能回归（根因）：QuickJsExecutor / JsSourceEngine 每次 JS 执行新建 QuickJS 引擎并重复 eval jsLib（最大 587KB）+ setup + Response/Jsoup bridge，而原版 AnalyzeRule.kt L891–936 = 单共享 RhinoScriptEngine + 编译脚本缓存（scriptCache.getOrPutLimit(jsStr, 16)，LRU 16）且 jsLib 只 eval 一次。新增 engine_cache.rs 进程级按书源缓存引擎（key=executor:source_tag / mainjs:source_url:main_js，LRU cap 8，指纹变化重建；jsLib/setup/RESPONSE_BRIDGE_JS/JSOUP_BRIDGE_JS/mainJs 构建时一次性 eval）；含顶层 const/let 的脚本继续走新引擎路径（lexical hash-set 标记 + redeclaration 错误回落新引擎重试），其余走缓存快路径；completion-value / non-strict / 64MB 内存上限 / 每次 eval 截止时间语义保持。mainJs 编排器沙箱与 executor 路径对齐（16MB→64MB、allow_script_run），main_js_loaded 改按构建期 eval 实际结果判定（失败回落既有 bindings 重评路径）。实测 debug n=30：中位 1084µs/eval → 2µs（-99.8%）
- Contributor: Cursor

## [2.0.104] - 2026-08-24

### Fixed
- [UI] BookInfo「自动更新」开关 parity：原版 menu_can_update（BookInfoActivity L408–417）在书在架且关闭 canUpdate 时执行 removeType(BookType.updateError)（位清除，BookExtensions L212），避免书架仍归入「更新失败」分组；移植版仅切换 canUpdate 未清位。新增 BookType.updateError=16 常量与 applyBookInfoCanUpdateToggle 工具函数对齐三种场景（在架关/在架开/未在架）
- [UI] search_notifier_test 辅助函数消除 use_null_aware_elements lint（条件 map 条目改为后置赋值）
- Contributor: Cursor UI

## [2.0.103] - 2026-08-24

### Fixed
- [UI] 搜索界面流式搜索中卡死无法操作（根因）：节流 flush 每 150ms 对全量累积表重跑 applyPrecisionSearch（逐书 RegExp 清洗 + 不可变 copyWith 拷贝 + map 重建 + 全量排序），结果数增长至数千时以 6.7Hz 持续分配 → GC 饱和冻结主 isolate。改为增量桶维护：每本书到达时分类 + 归并一次（O(批次)），flush 仅做各桶排序物化 O(k log k)，语义与 applyPrecisionSearch 完全一致（equal→tags→contains→other 分桶序、桶内 originsCount 降序 + 首次到达 seq 稳定平局键、精准模式丢弃 other 桶）
- [UI] 新增流式增量聚合回归测试 4 项：多批次 ≡ 一次性参考实现深度相等 / 续页 APPEND 跨页累积与同书多源合并 / 精准开关丢弃 other 桶 / 同分跨批次稳定平局序（含 mocktail page: any(named) 桩匹配陷阱注释）
- Contributor: Qoder UI

## [2.0.102] - 2026-08-24

### Fixed
- [UI] 搜索页「强制回到最上方、无法向下滑动」（三个根因）：
  1. 流式增量批次拉回顶部：移植版在结果数量任意变化时都滚顶；原版 AdapterDataObserver.onItemRangeInserted 仅在 positionStart==0（新搜索重置）时 scrollToPosition(0)，增量追加从不滚动 —— ref.listen 增加 isNewSearch 门控对齐
  2. dispose 崩溃 "Cannot use ref after the widget was disposed"：riverpod unmount 先执行 State.dispose() 再关闭 element 监听，stop() 同步写状态触发 build 注册的 ref.listen（_updateInputHelpVisibility → ref.read）—— stop() 延迟到 super.dispose() 之后的微任务（此时监听已关闭）
  3. 排序对齐：Dart List.sort 不稳定 vs 原版 Kotlin sortedByDescending 稳定 —— applyPrecisionSearch.sortedBucket 增加索引决胜，同分结果顺序与原版一致
- Contributor: Qoder UI

## [2.0.101] - 2026-08-24

### Fixed
- [UI] 书详情页（BookInfo）对齐原版 BookInfoActivity（parity 审计 P0/P1）：
  1. 分享书籍改为 bookUrl#bookJson + JS 回调接管（menu_share_it），未接管回退系统分享
  2. 拆分长章节菜单仅对本地 txt 可见（Book.isLocalTxt；此前 epub 等也误显示）
  3. canUpdate/splitLongChapter 内存切换、在架才持久化（menu_can_update/loadBookInfo）
  4. 封面点击换封面、长按预览大图（ivCover）
  5. webFile 书「最新：下载中...」并隐藏目录行（upLoading/ll_toc.gone）
  6. 目录行追加已读百分比（resolveBookInfoReadProgress）；本地书分类标签追加文件大小（upKinds）
  7. 书名/作者/分类标签点击与长按 → 搜索 + JS 回调（tvName/lbKind/ic_author）
  8. 来源行点击编辑书源（tvOrigin）；打开目录未在架先落库；分组设置未在架且 groupId>0 时加入书架（upGroup）
  9. 清除缓存移除确认框（原版无确认）+ clickClearCache JS 回调
- Contributor: Cursor UI + Qoder UI

## [2.0.100] - 2026-08-24

### Fixed
- [UI+Rust] 对比原版三处性能/视觉问题：
  1. 搜索卡顿：节流增量渲染（逐源批次仅追加累积表，results 列表至多每 150ms 重建一次 + 流结束最终聚合；修复逐批次全量重聚合 + 全量替换导致的 UI 卡顿）
  2. 目录加载卡顿：webbook* FFI 非阻塞化（async + tokio 阻塞线程池 spawn_blocking，对齐原版 WebBook.kt Dispatchers.IO——网络 + quickjs JS 解析不再阻塞 Dart 主 isolate；Dart API 表面不变）
  3. 默认书籍封面：无封面/加载中/加载失败时显示原版 image_cover_default.jpg（已复制至 assets/images），与原版占位行为一致
- Contributor: Qoder UI + Bridge

## [2.0.99] - 2026-08-23

### Fixed
- [UI+Rust] 搜索页对齐 Android 原版（批次 B，G-B-01~05）：
  1. 多页搜索透传（searchMultiStream +page/has_more，FFI 契约更新，破坏性变更已注记）
  2. hasMore OR 规则（任一来源仍有下一页即可续载）+ FAB 三态（停止/播放/下一页）
  3. 滚动到底自动加载下一页（对齐原版 RecyclerView 加载更多）
  4. 生命周期驱动的软挂起/恢复（pause 仅门控未送达结果，对齐原版 onPause/onResume）
  5. 书架实时搜索：输入帮助层「书架」节（书名/作者子串匹配、点击直达详情）、结果项在架绿点（与橙色阅读记录点互斥）、历史同名关键词仅填充分支
- Contributor: Cursor UI + Bridge

## [2.0.98] - 2026-08-22

### Fixed
- [UI] 词典过时注释与四分类台账更正（Rust 契约已落地）：
  - 核验结论：Flutter 生产路径无静态内置词典——DictNotifier.lookup → BookApi.dictLookup → Rust FFI dict_lookup（dict_api.rs 真实规则执行，带单测）；Mock `_mockDict` 为合法 B 类测试夹具；「静态占位数据」说法来自契约冻结前的过时注释
  - dict_state.dart L10 注释更正：词典查询经 BookApi.dictLookup 委托 Rust FFI dict_lookup；本状态仅承载规则与查询结果
  - STUB_FALLBACK_CLASSIFICATION D3 行与易误标项、docs/README.md 口径①同步更正（生产路径无内置词典，查询走 Rust FFI）
- Contributor: Cursor UI

## [2.0.97] - 2026-08-22

### Added
- [UI] 规则订阅管理页（对标原版 RuleSubActivity，P3-1）：
  - 列表（类型标签 + 名称 + URL，customOrder 排序）+ 拖拽排序持久化
  - 新增/编辑表单：类型/名称/URL/自动更新/静默更新/更新间隔，联动逻辑对齐原版（开自动默认 24h、间隔归零联动禁用、URL 空与重复校验）
  - 启用切换 / 更多菜单（检查更新、应用更新并展示 success/itemsAdded/itemsUpdated/itemsRemoved 结果）/ 删除确认
  - 点击条目按订阅类型打开书源/订阅源/替换规则导入确认流程
  - 入口接入订阅源管理页溢出菜单（对标原版 RssFragment 头部「规则订阅」条目）
  - 数据全部经 BookApi ruleSub* 七方法（契约 §2.39）；Mock 双轨自动生效；单测覆盖排序加载/去重/保存/删除/重排/启用切换

## [2.0.96] - 2026-08-19

### Fixed
- [Rust] 搜索 `baseUrl` 对齐原版重定向后最终 URL（`WebBook.search` → `res.url`）：
  - 根因：Rust 用请求 URL 当 `baseUrl`，搜索 302 到书籍页时 `bookUrl`/详情规则对不上
  - 现 `fetch_page` 返回 `StrResponse.url`；空列表且无 `bookUrlPattern` 仍按详情回退
  - 实测：书书小说搜索「斗破」4 条（首条斗破苍穹）；「一念」站点会 302 且无 og:property，原版同样搜不出书名

## [2.0.95] - 2026-08-19

### Fixed
- [Rust] G8 allInOne 正则跨步 `$n` 分组回填落地（CHANGELOG 2.0.93 已记语义，本版提交代码）：
  - `:` 前缀 `getElements` 有捕获组时按 AnalyzeByRegex 产出 `[全文,$1,$2,…]` JSON 元素
  - `getString("$2")` / `$1##…` 对齐 `SourceRule.makeUpRule` 用前序捕获组拼装，再走 `##` 替换
  - 覆盖书书小说 / 笔下文学 / 若夏等目录规则
  - 实测：书书小说 `http://www.shushun.cc/read_81/` 目录 1323 章、正文 1905 字；`test_g8_all_in_one_group_refs` 与 G10 allInOne 回归通过

## [2.0.94] - 2026-08-18

### Fixed
- [UI]+[Rust] 搜索同源徽标偏少 + 换源二次全量搜索（对照原版 3.26080322「快速书源 / 斗破苍穹」）：
  - **根因 1（聚合键）**：搜索解析未走 `BookHelp.formatBookName/Author`，「作者：天蚕土豆」等变体无法按 name+author 合并；现 Rust 解析清洗 + Dart `applyPrecisionSearch` 同步清洗。实测列表条数约 **1327→117**（合并生效）
  - **根因 2（换源）**：原版先 `getDbSearchBooks` 复用搜索落库；重构始终全量 `searchSource`。现搜索批次写入 `searchBooks`，换源默认读库；`forceRefresh=true` 才强制重搜
  - **仍差**：本机 emulator-5558 顶条同源约 **9**（DB exact 8），原版约 **120**——剩余主要在单源搜索成功率/网络/解析 parity，**不以完全 120 验收**
  - 回归：`test_parse_search_formats_name_author`、DB `change_source_by_group`、Flutter 作者前缀聚合；契约登记 `forceRefresh`

## [2.0.93] - 2026-08-18

### Fixed
- [Rust] G8 allInOne 正则跨步 `$n` 分组回填（书书小说目录原版有章、重构章名为空）：
  - `:` 前缀 `getElements` 有捕获组时按 AnalyzeByRegex 产出 `[全文,$1,$2,…]` JSON 元素
  - `getString("$2")` / `$1##…` 对齐 `SourceRule.makeUpRule` 用前序捕获组拼装，再走 `##` 替换
  - 实测：书书小说 `http://www.shushun.cc/read_81/` 目录 1323 章、正文 1905 字；七步阁目录/正文回归仍过

## [2.0.92] - 2026-08-15

### Fixed
- [Rust] 七猫四合一本地版目录/正文获取不到（用户反馈，续 v2.0.91 发现页修复）：
  - **正文 `[object Object]` 根因——`Packages.java.lang.String(bytes, charset)` 的 JS `new` 语义**：jsLib `qmDecodeTextBytes` 用 `String(new Packages.java.lang.String(解密字节, 'UTF-8'))` 解码；shim 构造器 bytes 分支显式 `return r`(原始字符串)，JS `new` 语义下表达式结果为 this 空对象 → `String(this)`="[object Object]" → 正文内容丢失。修复：bytes 分支返回 **JSString 对象**(toString/valueOf 取回明文)，并补 4 参数重载 `String(bytes, offset, length, charset)`(qmDecodeTextBytes 编码探测头按子数组解码，不再把 offset 当 charset 名)
  - **目录 0 章根因——QuickJS 沙箱 16MB 内存上限**：七猫 chapter-list 返回 1279 章，qmToc JS 生成每章完整请求 option(约 1.6MB JSON 数组)，`ctx.json_stringify` 成功但 `JsString::to_string()`(JS_ToCStringLen)在 QuickJS 堆接近 16MB 上限时分配失败返回 null → 规则结果丢失 → 「暂无章节」。修复：书源 JS 引擎内存上限 16MB→64MB(对齐 permissive)，另在 `js_value_from_rquickjs` 对 to_string 失败回退 CString 路径
  - **详情页「未知作者/共 0 章」**：未在架在线书阅读返回后 reload 时，`widget.book`(发现列表瘦壳)直接覆盖 DB 完整记录；新增 `_mergeDbBook` 用 DB 记录补全空字段(author/tocUrl/章节数)，路由实时字段优先
  - **详情页 tocUrl 权威值优先**：`_mergeWebInfo` 用详情解析出的 toc_url 优先于 book.tocUrl(发现列表默认=bookUrl)
  - 实测：剑来(1279 章目录+正文「二月二，龙抬头…」)、全民转职(232 章目录+正文)全部正常；详情页作者/目录/简介完整
- 新增测试：JavaString new 语义回归(2 参数/4 参数/1 参数/getBytes)、大 JSON 数组序列化(1279 元素含中文与长 URL)
- 验证：cargo test --workspace --features quickjs 全过(legado-js 488、legado-ffi 337)、flutter test 1188 全过、双模拟器冒烟 5/5

## [2.0.91] - 2026-08-15

### Fixed
- [Rust] 发现页七猫四合一本地版报错修复（用户反馈获取不到内容）：
  - **Rhino `Packages` Java 桥模拟层**：七猫 jsLib(587KB)依赖 `Packages`（AES 密文解密/Base64/MD5/UUID/String.getBytes），QuickJS 无 Java 桥报 `Packages is not defined`。注入 `Packages` 全局模拟层（java.lang.String / java.util.UUID|Arrays / android.util.Base64 / cn.hutool.DigestUtil.md5Hex / javax.crypto.Cipher → 新增 `java.aesDecryptBytes` 字节级 AES-CBC/ECB 解密 + `java.base64EncodeBytes` 绑定）
  - **java.ajax 支持原版「url,{json}」格式**：七猫 `java.ajax("https://...?,{\"method\":...,\"headers\":...}")` 此前解析失败返回 [ERROR]；现逗号前为 URL、逗号后 option JSON，返回**纯响应体文本**（对齐原版 JsExtensions.ajax 返回 body；七猫 qmParse 直接 JSON.parse）
  - **tokio 嵌套 runtime panic**：探索/搜索 async 上下文内执行 JS → java.ajax 嵌套启动 runtime 报 `Cannot start a runtime from within a runtime`；`runtime_bridge::block_on` 检测已在 runtime 内时改用 `block_in_place` 让出 worker 后驱动 legado-js runtime
  - 实测：七猫「推荐榜」正常加载书籍列表（重生之都市天尊、封神…）
- 新增测试：Packages 常用类 + AES-CBC 字节解密端到端、ajax「url,{json}」格式
- 验证：cargo test legado-js 485 全过、legado-ffi 337 全过、冒烟 5/5、模拟器实测七猫内容正常

## [2.0.90] - 2026-08-14

### Fixed
- [Rust] 发现页懒人听书分类报 http 404（用户反馈）根因链修复：
  - 分类 URL 为 `@js:` 脚本时 JS 执行失败被**静默回退字面量 URL**（`legado-parser` `analyze_js` 吞错 + `build_explore_url` fallback），把 `@js:` 脚本文本拼进请求 → `https://m.lrts.me/@js:...` → HTTP 404 误导；改为**错误上抛**（`analyze_js_with_error` + `build_explore_url` 返回 Result），显示真实原因
  - 分类 URL 脚本引用 `page` 全局变量缺失 → `page is not defined`；`ExploreInfoMapJsExecutor` 补注入 `var page = N` / `var baseUrl`（对齐原版 evalJS put("page")）
  - 懒人听书未配置抓包会话时 jsLib `lrtsResolveSession` 抛「本书源不含内置账号」——现按原版提示显示「分类加载失败：本书源不含内置账号，请先在书源登录中填写本人抓包的 8 项会话参数」
- [UI] 探索页错误文案清理：去掉 `Internal error: ` 前缀与 JS 堆栈（`_mapError`）
- 新增回归测试：`@js:` URL 脚本抛错应传播真实错误（不 fallback）；page 变量注入后 JS 正常执行
- 验证：cargo test legado-ffi 337 全过、flutter test 1188 全过、双模拟器冒烟 5/5、模拟器实测懒人听书报错文案正确

## [2.0.89] - 2026-08-14

### Fixed
- [UI] 编辑书源页标题「编辑书源」显示不全（用户反馈只显示「编辑」）：
  - 根因：窄屏/系统字体放大时 AppBar 标题空间被 4 个操作按钮挤压，20sp 标题放不下被省略
  - 修复：① 顶栏操作按钮触控区 48→40dp（visualDensity compact），标题空间增加约 32dp；② LegadoAppBar 标题统一 FittedBox 自适应缩放兜底——空间充足时保持 20sp 原版字号，极端窄屏/超大字体时完整显示不截断（实测 font_scale 1.3 与 1.0 下标题均 4 字完整）
- [Tool] parity 忽略名单补「编辑内容/保存」（actions 压缩属有意调整）
- 验证：flutter analyze 0 错误、flutter test 1188 全过、编辑页自动比对 MATCH、双模拟器冒烟 5/5

## [2.0.88] - 2026-08-14

### Fixed
- [UI] 书源编辑页内容左右补 12dp 内边距（对齐原版 item_source_edit CodeView paddingHorizontal=12dp：字段贴边但内容文字留 12dp 内边距），修复用户反馈「中间内容左右两侧没有边距」
- [UI] 顶栏标题防截断保护：LegadoAppBar 对 Text 标题统一单行 + 省略号，避免窄屏/系统字体放大时标题出现半个字（标题字号已核对与原版 ToolbarTitle 一致 20sp，模拟器实测「编辑书源」完整显示 160px 与原版相同）
- 验证：flutter analyze 0 错误、flutter test 1188 全过、编辑页自动比对仍 MATCH

## [2.0.87] - 2026-08-14

### Fixed
- [UI] 编辑书源页尺寸全面对齐原版（自动比对定位的批量差异）：
  - 修正 dp/px 混淆根因：Flutter 数值单位即 dp，此前把原版 XML 的 48dp 写成 96 导致设置卡片/TabBar/字段导航条整体偏高 48px；现按原版 48dp/36dp/48dp 对齐，TabBar、字段导航条、表单字段位置全部与原版一致（自动比对 MATCH）
  - 设置卡片改用自定义 header（对齐原版 options_header：minHeight 48dp、padding 12/4、摘要单行 + 展开箭头），语义节点文案对齐原版「设置, 摘要, 展开」
  - 字段导航条每项固定 72dp 等宽 + 无水平 padding（对齐原版 scrollable TabLayout tabMinWidth），表单字段去水平 padding 贴边（对齐原版 RecyclerView 无 padding）
- [UI] 书源管理页：行高对齐原版（padding 14dp×2 + 压缩 Switch 触控高度，行距 137px 一致）；底部操作栏对齐原版 SelectActionBar 结构（全选 weight=1、反选/删除固定宽 82dp、更多 36dp 图标、paddingLeft 16/Right 8）
- [UI] 经典登录表单（书山聚合）：
  - 按钮按 loginUi 数组原序逐行渲染（此前统一后置收集导致顺序错乱、按钮被推出视口）
  - toggle 行不渲染（对齐原版 SourceLoginV2Delegate when 无 toggle 分支）
  - 标题「登录 <源名>」、右上「确认」对齐原版，去掉原版没有的左上关闭按钮（返回键关闭仍持久化登录信息）
  - 按钮/输入框补 Semantics 标签（无障碍 + uiautomator 可感知）
- [Tool] scripts/ui_parity_compare.ps1：修正 @($null) 产生 1 元素 null 数组导致未匹配节点误报「重构(, )」的 bug；忽略名单补充登录表单标签/输入值/Android 双节点语义等噪音
- 验证：flutter analyze 0 错误、flutter test 1188 全过、自动比对编辑页 MATCH（书源管理/登录仅剩数据与视觉风格噪音）、冒烟 5/5

## [2.0.86] - 2026-08-14

### Fixed
- [UI] 书源管理页行对齐原版（自动比对工具发现的批量差异）：
  - 行标题补分组标签（如「📚书山聚合 (聚合书源)」，对齐原版行内分组标注）
  - 启用开关补 ON/OFF 文字（对齐原版 swt_enabled 行内 ON 文本）
  - 发现角标补语义标签「标志:发现已启用/未启用」、更多按钮 tooltip 改「更多菜单」（对齐原版内容描述）
  - 底部「全选 0/n」改「全选（0/n）」（对齐原版全角括号计数文案）
- [Tool] scripts/ui_parity_compare.ps1 增强：支持多界面批量比对（bookshelf/discover/source_manage/source_edit/source_login）、修正原版 dump 抓取顺序（此前两伤 dump 均为重构版导致「vs 自己」恒 MATCH）、多行合并节点按行拆分对比、括号/空白归一化、数据差异忽略名单。验证：编辑页/书架/发现 MATCH；书源管理行修复后模拟器实测渲染正确

## [2.0.85] - 2026-08-14

### Fixed
- [UI] 编辑书源页输入框样式对齐原版（apple-ui-designer / 用户反馈）：
  - 输入框移除全局主题的灰色圆角填充框（filled=false + 无边框），对齐原版 TextInputLayout 无框输入
  - 字段底部保留细分割线（UnderlineInputBorder 半像素灰线，聚焦时变主色——对齐原版 Material 下划线）
  - 字段导航条选中项下方渲染主色高亮指示线（对齐原版 TabLayout 选中项指示线，实测原版 R229 G57 B53 红/重构版主题色 2px 横线；焦点字段跟随，默认高亮首个字段）
  - 验证：flutter 1188 全过、冒烟 5/5×2、模拟器像素采样确认 源URL 下方高亮横线与原版位置一致

## [2.0.84] - 2026-08-14

### Fixed
- [UI] 编辑书源页 UI 细节对齐原版（用户实测反馈 9 项）：
  - 顶栏：标题「编辑书源」完整显示；操作按钮改为原版图标序「编辑内容 → 保存 → 调试源 → 更多选项」（保存仅图标无文字）；Tab 栏从顶栏移至正文（设置卡片下方，对齐原版 TabLayout 位置）
  - 新增字段导航条（对齐原版 field_nav）：当前 Tab 字段名横向滚动条，点击跳转聚焦字段
  - 设置面板改为原版卡片样式（圆角卡片 + 「设置」16sp + 摘要 12sp 灰字 + 展开箭头），位于 Tab 栏上方
  - 文本框默认单行收起（minLines=1，内容增长展开到 maxLines），标签灰字（secondaryText 语义）
  - 更多选项改为 showMenu 显式锚定：菜单在顶栏按钮**下方**右对齐展开（PopupMenuButton 在 AppBar 内弹出层会覆盖顶栏按钮），紧凑行高使 12 项完整展示不顶回；菜单内容按原版 source_edit.xml 顺序（登录/搜索/清除Cookie/自动补全/拷贝源/粘贴源/设置源变量/二维码导入/二维码分享/字符串分享/日志/帮助，移除原版没有的 JSON编辑）
  - 验证：flutter 1188 全过、冒烟 5/5×2、模拟器实测菜单 y168（工具栏下方）与顶栏/设置卡/Tab/字段条布局对齐原版

## [2.0.83] - 2026-08-14

### Fixed
- [UI] 编辑书源页按原版 BookSourceEditActivity 重构（内容显示与修改生效对齐）：
  - 基本信息 13 字段全量对齐原版顺序/标签：源 URL/源名称/源分组/源注释/登录 URL/登录 UI/登录检查 JS/封面解密/书籍 URL 正则/请求头/变量说明/并发率/jsLib（新增 6 个此前缺失字段：loginCheckJs/coverDecodeJs/bookUrlPattern/variableComment/concurrentRate/jsLib）
  - 搜索/发现/详情/目录/正文/段评六个规则 Tab 字段集合、顺序、标签全部对齐原版（移除原版不展示的 updateTime 行；段评改为原版 20 行：统计/详情/回复三组）
  - Tab 8→7：移除「调试」Tab（原版调试源为顶栏菜单）
  - 设置面板对齐原版紧凑摘要行：「设置 + 文本 | 启用 | 发现 | CookieJar | 段评 | 事件监听 | 定制按钮」
  - 修改生效保障：保存时从原书源透传表单未展示字段（updateTime/段评其余字段等），编辑一次不再丢数据；保存后自动刷新发现页书源缓存，改名/开关立即反映到发现页（此前内存旧对象会再次打开编辑页把已存修改回退）
  - 验证：模拟器实测改名 ShuShanNew→ShuShanNew2 保存后发现页立即更新、冷启动持久、重开编辑页回填正确

## [2.0.82] - 2026-08-14

### Fixed
- [UI] 编辑书源空表单根治：sourceEdit 路由忽略 BookSource 参数（发现页编辑入口打开即空白 →「没有任何书源信息」）；路由接参 + SourceEditScreen 增加 source 参数即时回填 + sourceUrl 入口 API 兜底加载；设置面板默认收起（对齐原版紧凑设置行，基本字段首屏可见）；新增登录UI 字段、loginUrl 多行
- [UI] 经典 loginUi 登录表单（对齐原版 SourceLoginDialog，书山聚合等经典 JSON 行协议）：邮箱/密码等字段 + basisPercent 按钮网格（账号登录/注册/退出/切换书源等 83 行全渲染）；按钮动作经 exploreEvalAction 执行（loginUrl JS + result 绑定表单 JSON）；✓ 保存登录信息并 login.apply(this)；⋮ 查看/删除登录头、清除登录信息、日志；关闭时持久化表单；已存登录信息回填
- [Rust] java.toast/longToast 接入 ui_action_queue（收集开启时入队 → Flutter SnackBar）：登录表单「正在登录/请先填写账号和密码/登录成功」等提示与原版一致可见（此前仅 stderr 不可见）
- 验证：legado-js 482/0、flutter 测试全过（新增 classic_login_dialog 3 项 + source_edit 更新）、模拟器 5556 实测编辑页回填/登录表单渲染/按钮动作 toast/登录信息持久化回填

## [2.0.81] - 2026-08-14

### Fixed
- [Rust] 书山聚合「个性推荐只剩一本」根治（去重折叠）：bookUrl `<js>` 规则顶层 `let source = result.source` 与 setup/jsLib 全局 var source 冲突 → redeclaration SyntaxError → bookUrl 回退 baseUrl → 30 本书同 URL → 按 bookUrl 去重折叠成 1 条。两层修复：① 规则 JS 改经 Function 内 eval 执行（独立词法作用域，对齐 Rhino 每次 evalJS 独立作用域）；② 列表元素按解析后的 JSON 对象注入 result（对齐原版 getElements JSON 模式返回 Map 对象，`result.source` 属性访问可用；新增 AnalyzeRule.set_element_content，explore/search/目录元素循环接入）。验证：legado-parser 217/0、legado-ffi 335/0、workspace 全量通过

## [2.0.80] - 2026-08-14

### Fixed
- [Rust] 书山聚合分类列表「暂无书籍」根治：ruleExplore.bookList `<js>` 脚本首行调用 jsLib 函数 getSessionId()，而 explore 列表解析 analyzer 未注入 jsLib/setup → ReferenceError 被吞 → 空列表。新增 construct_analyzer_with_source_context（sanitize jsLib + 书源 setup source/cookie），explore 两个 analyzer 构造点接入；回归测试用真实书山 jsLib + 合成 read_recommend 响应验证解析出书籍。验证：legado-ffi 335/0

## [2.0.79] - 2026-08-14

### Fixed
- [Rust] 聚合源发现分类 ERROR 根治（书山/番茄等）：① JS 引擎 eval 改非严格模式（rquickjs 默认 strict=true，裸调用函数 this=undefined → 书山 jsLib let {source}=this 报 Cannot convert；对齐 Rhino 非严格 this=globalThis）；② jsLib 加载 sanitize 预处理（移除 Rhino importClass/Packages 行）后完整加载保留全部函数（getConfig/getServerHost 等）；③ exploreUrl 经 Function 参数执行。验证：legado-ffi 334/0、workspace 全量通过

## [2.0.78] - 2026-08-14

### Fixed
- [Rust] 发现分类 ERROR 根治：聚合源 jsLib 含 Rhino Packages.* 时前缀截断丢失后部函数（getConfig/getServerHost 未定义）；新增 sanitize 预处理（移除 Rhino 特有行）后完整加载 jsLib，保留全部函数定义。验证：legado-ffi 331/0

## [2.0.77] - 2026-08-14

### Fixed
- [UI] 登录红屏修复：全局 TabBarTheme.tabAlignment=start 对非 scrollable TabBar 断言失败（TabAlignment.start is only valid for scrollable tab bars）；登录页（SourceLoginScreen）与应用日志页（AppLogScreen）TabBar 显式 tabAlignment: fill（对齐 toc_screen 既有处理），新增渲染回归测试。验证：flutter 1185 全过

## [2.0.76] - 2026-08-14

### Fixed
- [Rust][UI] 发现控件 infoMap 回显 + 分类解析 ERROR 行（B）：toggle/select/text 初始值读回 infoMap 已存值（新增 exploreInfoMapSnapshot FFI，契约 §2.18 登记）；JSON 解析失败产出 ERROR 分类行（对齐原版 exploreKinds）。验证：legado-ffi explore 23/23、flutter 1180 全过

## [2.0.75] - 2026-08-14

### Added
- [UI] 发现列表在架标记 + 顶栏批量加入书架（R5）：列表项按「名-作者/名/bookUrl」三元匹配显示在架角标（对齐原版 ivInBookshelf）；顶栏「加入书架」按钮批量导入已加载书籍（对齐 menuAddLoadedBooks）。验证：flutter 1180 全过

## [2.0.74] - 2026-08-14

### Fixed
- [UI] 发现页分页错误态与登录引导（C/R4）：错误后保留 hasMore 使「点击重试」可用（对齐原版 fail()）；整页全重复判定 noMore；登录错误（LoginRequired）展示「去登录」引导（统一入口 showSourceLogin）+ 重试。验证：flutter 1178 全过

## [2.0.73] - 2026-08-14

### Added
- [UI] 发现页书源行菜单补齐六项（编辑/置顶/登录/搜索/刷新/删除，对齐原版 ExploreAdapter）：登录项按 hasLoginUrl 条件显示；登录统一入口 showSourceLogin（V2 动态对话框 LoginV2Dialog 自 book_info_screen 提取为公共组件 + 手动凭据页分流）；「搜索」预选指定书源进入搜索页。验证：flutter 1178 全过

## [2.0.72] - 2026-08-14

### Fixed
- [Rust][UI] 书源登录链路打通（发现页问题排查 R1）：① V2 loginActionV2 返回 `login` 命令时自动落库 `userInfo_<url>`（对齐原版 SourceLoginV2Delegate.putLoginInfo）；② 新增 `sourcePutLoginInfo/sourcePutLoginHeader/sourceGetLoginInfo/sourceGetLoginHeader` FFI 并登记契约 §2.3；③ 手动登录凭据改存 source_login_cache（`loginHeader_<url>`/`userInfo_<url>`），替代无消费方的 `source_login_<url>` config 键，旧数据 load 时回退迁移；④ 请求路径（搜索/详情/目录/正文/发现）合并 loginHeader + JS setCookie 全局 Cookie（对齐原版 getHeaderMap(hasLoginHeader=true)）。验证：legado-ffi quickjs 全量 + flutter 1176 全过

## [2.0.71] - 2026-08-14

### Fixed
- [Rust] 大灰狼发现页 `host is not defined`：对齐 Android `evalJS` 注入 `cookie`/`cache`/`sourceUrl`；jsLib 分段加载并在失败时从 jsLib 提取 `host` 数组兜底；补 host 回归测试

## [2.0.70] - 2026-08-14

### Fixed
- [Rust] 大灰狼 exploreUrl JS 执行失败：补齐 `source/java` 的 `getLoginHeader`/`putLoginInfo`/`login`/`getLoginInfoMap` 等 BaseSource API；infoMap 可写 Proxy；登录缓存读写与聚合源 `exploreKinds()` 回归测试
- [UI] 发现 ERROR 弹窗完整展示 JS 错误、去蓝字/红条，Apple 灰阶确定按钮

## [2.0.69] - 2026-08-14

### Fixed
- [Rust] 大灰狼等 @js: exploreUrl 显示「无分类」：`java.get/put` 对齐 Android 委托 `source.*`；加载 mainJs；IIFE 包装 + `JSON.stringify` 归一化返回值；JSON 解析失败不再降级为纯文本
- [UI] explore JS 失败展示 `ERROR:` 分类行并可点击查看详情（对齐 Android ExploreAdapter）

## [2.0.68] - 2026-08-14

### Fixed
- [Rust] 发现页补齐 `exploreEvalAction` / `exploreEvalUiJs` FFI，注入 infoMap + `java.refreshExplore`，对齐 Android ExploreAdapter 按钮/下拉 action 与中途 UI
- [UI] 发现分类渲染 button/select/toggle/text 控件并联动 action；选择变更或登录后 `reloadCategories` 刷新榜单分类

## [2.0.67] - 2026-08-14

### Fixed
- [工程] 根治 Android「引擎初始化失败」（content hash 失配）：新增 `verify-ffi-android` 校验脚本、Gradle `preBuild` hash 门禁、`build-apk`/冒烟脚本自动同步 jniLibs；启动页按平台显示可复制修复命令

## [2.0.66] - 2026-08-14

### Fixed
- [Rust] 发现分类榜单与原版不一致：补齐 infoMap 持久化与 `build_explore_url`（含 `{{infoMap}}` / JS 模板），抓取时携带与 Android 相同的 infoMap 上下文
- [UI] 发现分类支持 toggle/select 控件并同步 infoMap，避免未选榜单类型时请求错误 URL
- [UI] 发现分类列表 Apple 风重做：页码/按钮去蓝色强调，Cupertino 选页 sheet，iOS 列表分隔与灰阶层次

## [2.0.65] - 2026-08-14

### Fixed
- [UI] 发现分类列表仅显示 1 本书：`bookUrl` 为空时去重键回退为「书名+作者」，不再全部折叠为一条
- [UI] 发现分类列表补齐右上角「第 X 页」与页码选择器、上滑加载上一页/下滑加载下一页，对齐 Android ExploreShowActivity 分页交互

## [2.0.64] - 2026-08-14

### Fixed
- [UI] 阅读页顶栏标题与系统状态栏（电量/时间）重叠：edge-to-edge 下 SafeArea 的 padding.top 为 0，改用 viewPadding.top 避让；ReadMenu 展开时强制显示状态栏（对标原版 upSystemUiVisibility）；正文 viewport 与分页扣减同步，切换工具栏时 layout 稳定
- [工程] 冒烟脚本进程检测改为 pidof 轮询 + 安装后 force-stop 冷启动，消除 5558「进程未找到」误报

## [2.0.63] - 2026-08-14

### Fixed
- [UI] MainActivity `legado/system_bar` 通道 ARGB 颜色 Long→Int 强转异常（emulator-5558 logcat ClassCastException）
- [工程] 冒烟脚本 `-CheckUI` 用 UTF-8 字节构造底栏标签并轮询 uiautomator，修复 Windows PS 编码导致误报 FAIL

## [2.0.62] - 2026-08-14

### Changed
- [工程] F4-1 冒烟脚本 FlutterDir 改相对路径/LEGADO_FLUTTER_DIR 环境变量
- [工程] F4-2 清理临时调试物并补 .gitignore 规则
- [工程] F4-3 FRB 生成物版本头统一为 2.11.1（对齐 pubspec）
- [UI] F4-4 rust_api.dart 补 174 个 @override；启用 annotate_overrides lint
- [UI] F4-5 移除 Cronet/直链上传空壳占位（RESIDUAL 不做销记）
- [docs] F4-6 ROOT_ENGINEERING_FILES.md 登记根目录 Makefile/package.json
- [docs] F4-7 D5=B：AGENTS.md 登记 l10n 维持中文主语言
- [docs] F4-8 API_CONTRACT §2.43.2 登记 payAction `{{js}}` URL 模板 R6 留项

## [2.0.61] - 2026-08-14

### Added
- [UI] F3-18 `settingsProvider` 统一注入，8 个 screen 移除直接 `SettingsService()` 实例化
- [UI] F3-20 BookApi 补 5 项延迟封装（backupList/bookGroupSetShow/httpTtsSetEnabled/ttsSpeak/ttsSetCacheDir）
- [UI] F3-19 About 页同步原版 updateLog.md / disclaimer.md 资产

### Changed
- [docs] F3-16 SOURCE_DIFF §8 登记 HandleFile N/A、RssSort 降级
- [docs] F3-20 API_CONTRACT §3 待 UI 封装清单清零
- [Rust] F3-9 encoding.rs 登记 chardetng 计划偏差（维持自研启发式）

## [2.0.60] - 2026-08-14

### Added
- [Rust] F3-17 `rssListReadRecordsByOrigin` FFI（对齐原版 getRecordsByOrigin）
- [UI] F3-17 RSS 阅读记录对话框改按源查询，移除客户端全量过滤

### Fixed
- [Rust] F3-6 payAction/login/explore/callback 改 fresh_engine，消除 JS 引擎池串扰
- [Rust] F3-7 删除 legacy-ffi/、context.rs、ffi_macros.rs；parse_rule 消费 ruleType

### Changed
- [docs] F3-10 API_CONTRACT 全面同步（BookApi 247、附录 251、§1.7 命名等价表）

## [2.0.59] - 2026-08-14

### Changed
- [UI] ReaderTypographicPage 接入页眉/页脚边距与 ReadTipConfig 提示项渲染（对标原版 ReadView PageView）；分页测量同步扣减页眉页脚占位

## [2.0.58] - 2026-08-14

### Added
- [Rust] F3-14 新增 `httpGetBytes` FFI（二进制 GET，bodyBase64 响应）
- [UI] F3-14 `bridge_http.dart` 收敛 8 处裸 `http.get` 至 Rust Bridge

### Changed
- [docs] F3-5 §1.6 登记 9 个 FFI 非 Result 导出豁免
- [docs] F3-8 §2.44 注明 infoHtml/tocHtml/downloadUrls 瞬态字段语义
- [docs] F3-12 根 README 更新（2.0.x、62 Screen、CI 徽标）
- [docs] API_CONTRACT BookApi 234 方法；附录 245

## [2.0.57] - 2026-08-14

### Fixed
- [UI] 阅读器工具栏切换时正文上跳：移除 `showControls` 联动 SafeArea，工具栏保持 Stack overlay 不挤占 viewport（对标原版 ReadView + ReadMenu 浮层）
- [UI] 底栏悬浮按钮补齐自动翻页/替换规则（对标原版 fabAutoPage/fabReplaceRule）

### Changed
- [UI] 边距设置对齐原版 PaddingConfigDialog：页眉/正文/页脚 Tab、± 步进、左右联动、分隔线开关
- [UI] 阅读提示信息对齐原版 TipConfigDialog：页眉页脚显示模式、三列提示项、标题样式

## [2.0.56] - 2026-08-14

### Changed
- [docs] API_CONTRACT 变更记录预登记（本批 F3 代码于 2.0.58 合入）

## [2.0.55] - 2026-08-14

### Fixed
- [Rust] F3-15 移除本地段评 CRUD 死契约（原版无本地库段评；保留 ruleReview 三方法）
- [Rust] F3-1 `shared_client()` 改 `LegadoResult` 去 panic 兜底
- [Rust] F3-2 `check_syntax` 独立 Runtime 5s 超时 + 16MB 内存上限

### Changed
- [docs] F3-3 沙箱 `max_stack_depth`/`allow_network` 文档对齐（D3=A 配置口径说明）
- [docs] API_CONTRACT BookApi 233 方法（段评 §2.30 7→3）

## [2.0.54] - 2026-08-14

### Fixed
- [Rust] F3-1 FFI unwrap/expect 收敛：webdav/server/http_state/net_api 生产路径
- [UI] F3-15 删除死文件 `comic_reader_screen.dart`（路由已用 ReaderComicScreen）

### Changed
- [docs] F3-11 测试统计口径统一（ffi quickjs 311 + flutter 1171）
- [docs] F3-4 沙箱 eval/Function 文档对齐 D3=A；F3-13 video_play_utils 登记豁免 D4=B
- [工程] F2-9 integration/audit-fix-20260814 已 fast-forward 合入 master

## [2.0.53] - 2026-08-14

### Added
- [Rust] 换源页三开关真实行为：`source_switch_search` 第四参 `options_json` 消费 loadInfo/loadToc/loadWordCount，试读字数与 wordCountComparator 排序（审计 F2-2）
- [UI] 换源页传参接线、开关开启重搜、列表展示试读字数/耗时（审计 F2-2）

## [2.0.52] - 2026-08-14

### Added
- [Rust] 书架拖拽排序持久化 `reorderBooks` FFI + UI 接线（审计 F2-1）
- [Rust] 按书清缓存 `clearBookCache` FFI + 书籍详情页接线（审计 F2-3）

## [2.0.51] - 2026-08-14

### Removed
- [Rust] 删除阅读统计子系统（reading_stats/reading_sessions 表/server /stats 路由/FFI 4 函数）；保留 `recordReadingTime` 对齐 ReadRecord（审计 F2-7，D1=A）
- [Rust] 删除 users 表及明文密码路径（UserRepository/FFI 6 函数/契约面）（审计 F2-8，D2=A）

## [2.0.50] - 2026-08-14

### Fixed
- [CI] rust-ci 全量跑 `cargo test -p legado-ffi --features quickjs`（审计 F2-5）
- [工程] 移除仓库级 `.cargo/config.toml` NDK/USTC 绑定（审计 F2-6）
- [文档] quickjs 构建口径与质量门禁统一（审计 F2-4）；docs/README getAudioChapterMedia 口径修正（F2-11）
- [工程] 还原 `.qoder/agents/builtin` 五文件（审计 F2-12）

## [2.0.49] - 2026-08-14

### Fixed
- [Rust] 词典 data: URI 查词：`AnalyzeUrl` 对 data: 载荷豁免 page/angle 替换，修复 `#def` 等 CSS showRule 提取为空（审计 F1-1）
- [UI] 删除孤儿 `reading_stats_screen.dart` 及 l10n 死条目，恢复 `flutter analyze` 0 error（审计 F1-2）
- [工程] 移除入库 `legado.jks`，`.gitignore` 覆盖 `*.jks`/`*.keystore`，test.yml 改 secrets 注入（审计 F1-3，D6=B）

## [2.0.48] - 2026-08-14

### Fixed
- [UI] 帮助弹窗 Markdown 补 H1/H2 标题下分隔线（对标 Markwon headingBreak），显式 hr 增加可见高度与上下间距

## [2.0.47] - 2026-08-14

### Fixed
- [UI] 帮助页改回弹窗模态（约 90% 屏高、圆角），顶栏对齐原版目录/源码/关闭；Markdown 样式对齐 `TextDialog`/`HelpMarkwonTheme`

## [2.0.46] - 2026-08-14

### Added
- [UI] 同步 Android 原版全部帮助 Markdown 资产，统一 `HelpScreen` 全页渲染（目录抽屉 + 关闭按钮），各界面 help 入口对齐原版

## [2.0.45] - 2026-08-14

### Added
- [UI] 书籍信息页渐进加载：发现/搜索元数据先上屏，后台补全详情与目录（`9eeb3c364`）
- [UI] 目录页并行加载、顶栏进度条与列表底线文案（`cc4b23204`）
- [UI] 发现页对齐原版 Flexbox 分类布局、书源行样式与 iOS 分组列表视觉（`594c5e1cb` / `f10dcffbc` / `cd88582ed`）

### Fixed
- [Rust] 思路客等信息页/发现卡顿：详情页 HTML 短缓存、目录 AnalyzeRule 复用、nextTocUrl 分页与 CSS 自匹配（`deca82748`）
- [Rust] 发现列表点号索引（如 `$[0].books`）未解析导致只显示 1 本书（`6bb18abb9`）
- [Rust] 发现 @js 分类解析：上下文注入；已知 tocUrl 跳过详情页（`b6707c1c8`）
- [Rust][UI] 发现页分类解析回归：@js 上下文注入与空缓存重试（`2207e207e`）
- [Rust] `refresh_toc` 占位落库打 `NOT_SHELF`，避免仅拉目录污染书架（`fafc65782`）
- [UI] 修复仅浏览详情/目录误入书架（`1fd863406`）
- [UI] 发现页分类 Chip 对齐 Android Flexbox 网格，修复展开 chevron 浅色不可见（`cd88582ed`）
- [UI] Tab 根页误显返回按钮；统一 `LegadoAppBar` 导航（`a56182f64`）

### Notes
- 阅读器日夜切换联动全局 ThemeMode 已于 **2.0.44** 交付（`e5610e651`），本批无重复改动
- 发现页 UI 对齐说明见 `docs/EXPLORE_UI_ALIGN_2026-08-14.md`

编写者：Auto（Cursor）｜ 2026-08-14

## [2.0.44] - 2026-08-13

### Fixed
- [UI] 阅读器日夜切换联动全局 ThemeMode（对齐原版 AppConfig.isNightTheme + ThemeConfig.applyDayNight）

## [2.0.43] - 2026-08-13

### Added
- [Bridge]+[UI] `getSameTitleRemoved` / `canRemoveSameTitle`：caches KV 权威查询 +「未找到可移除的重复标题」试算
- [Rust] `webdav_upload_file` 大文件 `ReaderStream` 流式 PUT；直建 Client（WebDAV / rule_update / source_update）挂 customHosts DNS
- [Rust]+[UI] loginCheckJs：legado-server fetcher 接入 + 阅读器自动拉登录
- [Rust] 缓存批量下载任务落库 caches KV（重启续传）

### Fixed
- [UI] 应用版本同源：`package_info_plus` 运行时读取 version；关于页 / 检查更新 / User-Agent 不再硬编码滞后

### Notes
- 自定义字体族（FontScreen 导入/切换）此前已具备，本批核销
- schema v102：计划结论为延后（无遗留库互操作触发）；待用户确认是否强制做
- **版本同源已修**：升版只改 `pubspec.yaml`，勿再手写 `currentVersionName`

## [2.0.42] - 2026-08-13

### Fixed
- [UI] TTS「跟随系统」默认 true，持久化迁 config 键 `ttsFollowSys`（对齐 AppConfig.ttsFlowSys）

### Notes
- 反转内容 / 段落级 TTS「朗读所选」此前已接 saveChapterContent 与 startChapterPos，本批核销

## [2.0.41] - 2026-08-13

### Added
- [UI]+[Bridge] 离线缓存导出扩展：`bookExportWithOptions`（txt/epub/pdf、charset、文件名模板、章节范围、进度与 WebDAV）

## [2.0.40] - 2026-08-13

### Added
- [Bridge]/[Rust]/[UI] 书源调试流式 Debug.Callback：`debugBookSourceStream` / `cancelDebugBookSource`，对齐原版 `Debug.Callback.printLog`

## [2.0.39] - 2026-08-13

### 修复（书源导出 / 阅读记录写入 / 默认字典与 TXT 目录规则，[UI]+[Rust]）

1. **书源导出**：`BookSource.toJson` 嵌套规则未 `explicit_to_json`，`JsonEncoder` 抛 Converting object failed；改为嵌套 `.toJson()` + 写临时文件 `Share.shareXFiles`（对齐原版 saveToFile）。
2. **阅读记录**：阅读器从未调用 `putReadRecord`；`ReaderNotifier` 接通累计时长写入；FFI `ReadRecordDto` 改 camelCase + lastRead。
3. **字典/TXT 默认规则**：对齐 Android `defaultData/dictRules.json`、`txtTocRule.json` 首启/「导入默认」。

编写者：Auto（Cursor）｜ 2026-08-13

## [2.0.38] - 2026-08-12

### 修复（普通书源搜索出源偏少：GBK 请求编码 + `#` 后缀 baseUrl + 响应解码，[Rust]）

对照原版 `AnalyzeUrl.encodeParams` / `NetworkUtils.getAbsoluteURL` / `SearchModel`；快速书源 type=0「斗破苍穹」探针。

1. **根因（引擎级）**
   - UrlOption `charset=gbk` 已解析，但查询/表单恒按 UTF-8 `urlencoding` → 经典笔趣阁系搜不到。
   - `bookSourceUrl` 含 `#🎃`/`#pb1101` 等唯一后缀时，相对 searchUrl 拼成 `https://host#tag/path` 假 URL（约 48/219 快速源）。
   - GBK 响应经 reqwest `.text()` 当 UTF-8 → 书名乱码，精确匹配失败。
2. **修复**
   - `encode_query_params` / `encode_form_params` 按 charset 百分号编码；POST 走 `encoded_form` + form Content-Type。
   - `get_absolute_url` 拼接前剥离 `,JSON` 与 `#fragment`。
   - 非 UTF-8 charset：`get_raw`/`post_raw` + `decode_response_bytes`。
3. **验证（快速组 type0=219，关键词斗破苍穹）**
   - 有结果源 **38 → 64**；精确书名源 **19 → 45**；总命中 686 → 1595。
   - 仍低于原版全库顶条聚合 ~336（站点失效、JS/Rhino、`webView`、page>1 等残留）。

编写者：Reasonix ｜ 2026-08-12

## [2.0.37] - 2026-08-12

### 修复（红牛/U酷 type=2 误进漫画、非凡进文本、换源 `len`、VideoScreen 溢出，[Rust]+[UI]）

对照原版 `BookInfoActivity.startReadActivity`、`AnalyzeRule.evalJS`（Rhino 非严格裸赋值）与 emulator-5558 导出源。

1. **红牛 / U酷**：设备导出 `bookSourceType=2`（误标图片）+ `group=影视频源` + 正文抽 `m3u8`；旧逻辑 `typeBitsForSource(2)` 直进 comic「暂无图片」。
   - `looksLikeVideoSource` 覆盖 type=0/**2**；`resolveTypeBits` **视频启发式优先于**显式 image；域名/源名（hongniu/ukuzy/ffzy/lzizy）增强。
2. **非凡**：type=0 MacCMS 仍进文本刷 m3u8 时，加强 origin 尾斜杠匹配 + 开读分流回归。
3. **换源 JS**：`len is not defined`（榴莲 TOC `len=java.getElements…`）；QuickJS prologue 预声明 `len`/`jm`/`from`（与 `all`/`d`/`data` 同策略）。
4. **VideoScreen**：`BOTTOM OVERFLOWED BY 239 PIXELS`（量子等）— `AspectRatio` 未约束撑破 Column；改为 `Expanded` 画面区 + 底部控件 `SafeArea`，全屏控件叠层。
5. **验证**：Dart/Rust 单元测试；emulator-5558 端到端（红牛/非凡/U酷 → VideoScreen；换源无 `len is not defined`；播放页无溢出条）。

编写者：Reasonix ｜ 2026-08-12

## [2.0.36] - 2026-08-12

### 修复（视频源误进漫画 / type=0 MacCMS 分流与播放，[UI]）

对照原版 `BookInfoActivity.startReadActivity`（`book.isVideo` → VideoPlayer，绝不进 ReadManga）与设备导出源。

1. **根因**：非凡资源网等「影视频源」在库里 `bookSourceType=0`（MacCMS），开读按文本处理；旧逻辑仅在 `typeBits==0` 时补书源类型，抽图启发式可误伤；用户见漫画页「暂无图片」。
2. **分流**：`BookOpenUtils.resolveTypeBits` — 显式 type 1–4 优先；type=0 时 MacCMS/`vod_play_url`/`影视频源`+播放特征 → `BookType.video`，**优先于**抽图提升；书架/详情/离线缓存共用。
3. **播放**：`resolveVideoPlayTarget` 正文为空或 `#EXTM3U` 清单时回退 `chapterUrl`；`startBrowser` 对流媒体 URL 跳过外开；`looksLikeImageUrl` 排除 m3u8/mp4。
4. **验证**：单元测试（非凡启发式 / 伪七猫 type=4 / 必应漫画仍升 comic）；emulator-5558 端到端（VideoScreen + 可播/缓冲态）。

编写者：Reasonix ｜ 2026-08-12

## [2.0.35] - 2026-08-12

### 修复（书源 JS `all` / VideoScreen 生命周期 / Array(0x…) 正文，[Rust]+[UI]）

对照原版 `AnalyzeRule.evalJS` 绑定、`JsSourceEngine.normalizeJsResult`、Riverpod InheritedWidget 约束。

1. **`all is not defined`（QuickJS 严格模式）**
   - 根因：书源常用 `all = JSON.parse(result)` 等裸赋值；Rhino 非严格可写，QuickJS eval 严格模式抛 ReferenceError。
   - 修复：`execute_js_rule` prologue 预声明 `var …, all`（与既有 `d/data/list…` 同策略）。

2. **VideoScreen `initState` 过早读 Provider（2.0.34 回归）**
   - 根因：`_loadBookVideo` 在 `initState` 内调用 `ProviderScope.containerOf(context)`。
   - 修复：书籍模式改到 `didChangeDependencies` 调度；直链模式仍可在 `initState` 启动。

3. **正文/详情刷 `Array(0x…)`**
   - 根因：QuickJS 对 Array/Object 降级 `format!("{:?}", val)`；原版 Scriptable 走 `JSON.stringify`。
   - 修复：引擎 `result_to_string` 对对象/数组 `json_stringify`；无 `$[*]` 后缀时展开 JSON 数组为多元素（对齐 NativeArray）。

4. **验证**
   - Rust：`test_js_rule_predeclares_all_*` / `test_js_rule_expands_json_array_*` / `test_eval_array_object_normalized_to_json` / `$[*]` 后缀不误展开。
   - 设备：emulator-5558 安装验收。

编写者：Reasonix ｜ 2026-08-12

## [2.0.34] - 2026-08-12

### 修复（视频源播放链路：复合 URL / header / MPD / subContent，[UI]+[Rust]）

对照原版 `VideoPlay.kt` / `VideoPlayerActivity` / `BookContent` isVideo（3.26080322）。

1. **Flutter 播放器接入 `video_play_utils`**
   - `video_screen` 完整走 `resolveVideoPlayTarget`：相对 URL 绝对化、复合 `url,{json}` UrlOption header、书源 header 合并、默认 UA/Referer、MPD 落临时文件以 file 播放。
   - 卷标题跳过（`findPlayableChapterIndex` / 上一集下一集）；错误重试当前章；进度写回保留。

2. **Rust `web_book` 视频 subContent**
   - **根因**：FFI 曾把副内容统一 `\n` 拼进正文；原版视频走 `putDanmaku`、音频 `putLyric`，不污染播放链接。
   - **修复**：`is_media`（AUDIO/VIDEO）不再合并副内容进正文；文本源仍追加。

3. **验证**
   - 单测：`video_play_utils_test` + Rust `merge_sub_content_skips_media_to_protect_play_url`。
   - 设备：emulator-5558 用真实视频源（如「伪七猫」）对照原版验收。

编写者：Reasonix ｜ 2026-08-12

## [2.0.33] - 2026-08-11

### 修复（必应漫画 type=0 正文刷 `<img>` HTML，[UI]）

1. **取证（emulator-5558）**
   - 书源 `https://www.biyingmh.com`：`bookSourceType=0`，`ruleContent.content=.img@img@html`，`imageStyle=FULL`，无 header / imageDecode / coverDecodeJs。
   - 正文已抽出明文 JPG（如 `jjmhw6.top/.../1135571.jpg`）；桌面直连与带 Referer 均为 200 + `FFD8` JPEG，**非**防盗链/密文问题。
   - 书籍位标记 `notShelf|text` → 文本阅读器；排版引擎不渲染 `<img>`，用户看到裸标签。

2. **修复**
   - `BookOpenUtils`：识别「抽图 HTML」正文规则，将 type=0 源提升为 `BookType.image`，详情/书架开读走漫画阅读器；入库回填媒体位。
   - 文本阅读器兜底：`isImageDominantContent` 时用纵向图片列表（FFI/`CachedNetworkImage`），避免再刷 HTML。

3. **验证**
   - 单测：必应规则提升路由、jjmhw6 样例图片主导判定、图文混排不误伤。
   - 复测：必应漫画搜书 → 详情开始阅读 → 应进漫画纵向出图，不应再显示 `<img src=...>` 文字。

编写者：Reasonix + UI ｜ 2026-08-11

## [2.0.32] - 2026-08-11

### 修复（搜索/列表封面解密卡顿，[UI]）

1. **卡顿根因**
   - 上一轮为 51 等源接通 `coverDecodeJs` → `fetchImageWithDecode` 后，搜索列表对**每条结果**立即并发 FFI 解密，无结果缓存、无并发上限、屏外项不取消；漫画源封面密且多，滑动极易卡顿。

2. **修复（对齐原版 Glide 列表节流体感）**
   - 新增 `CoverDecodeLoader`：解密结果 LRU（64）、全局并发上限 3、同 URL in-flight 去重、dispose 取消排队票证。
   - `BookCover`：无 `coverDecodeJs` 仍走轻量 `CachedNetworkImage`（`memCacheWidth` 缩略）；有解密则经 Loader；`Image.memory` 使用 `cacheWidth`。
   - 书源 origin → patched JSON 缓存，避免每张封面重复 `getBookSources`。
   - 搜索 `ListView`：`addAutomaticKeepAlives: false`，滚出可视区 dispose 并取消排队。

3. **验证**
   - 单测 `cover_decode_loader_test`（缓存/并发/取消排队）。
   - 请在 emulator-5558 用漫画源搜列表滑动验收。

编写者：Reasonix + UI ｜ 2026-08-11

## [2.0.31] - 2026-08-11

### 修复（搜索分组粘性 + 同书聚合 + `class.` 选择器，[UI]+[Rust]）

对照原版 3.26080322「漫画书源 / 一人之下」：聚合顶条约 **13** 源；重构引擎精确书名曾约 **10~11**，UI 却常搜全量 968 源且按源分行，体感「结果少/源少」。

1. **Flutter 漫画分组粘性（P1）**
   - **根因**：选分组用 `clearGroupFilter`+`toggleGroup` 两步写状态，并发 search 可能读到空分组而回退全量；搜索范围未持久化。
   - **修复**：`selectGroupExclusive` 原子单选；`searchScope`/`searchGroup` 读写对齐原版；芯片展示真实分组名，清除后自动重搜。

2. **同书多源聚合（P1）**
   - **根因**：`applyPrecisionSearch` 只分桶、不 `addOrigin`；徽标显示书源名而非同源数。
   - **修复**：按书名+作者聚合 `origins`，桶内按 `originsCount` 降序；多源徽标显示数字（对齐 `bv_originCount`）。

3. **引擎 `class.xxx` → 空列表（P0 引擎）**
   - **根因**：原版 `class.comics-card` 走 JSoup `getElementsByClass`；Rust 原样当 CSS → 匹配「标签 class」永远 0 命中 → 包子/爱看等大量 `search:empty`。
   - **修复**：`HtmlParser` 将 `class./tag./id.` 转为 `.xxx` / `tag` / `#id`。
   - **探针（漫画组 83 源，「一人之下」）**：精确书名源 **10→17**（超原版聚合 ~13）；有结果源 **20→34**；总命中 **317→583**；爱看 0→30、包子优+ 0→88。

4. **仍差**
   - 包子漫画（优）本轮仍 0（站点 SSL/可达性）；快看 TOC `__NUXT__`；部分 `@js`/`jsLib` 源仍空。

编写者：Auto ｜ 2026-08-11

## [2.0.30] - 2026-08-11

### 修复（搜索相对 URL 绝对化 + 目录 `<js>$[*]` 链拆解，[Rust] 为主）

取证（本机新建 emulator-5558 + 设备导出 sources.json 89 个 type=2）：批量搜索成功率仅 12/89，失败几乎全是 `search:empty`；相对 searchUrl 占 41/89。

1. **搜索结果过少（引擎级）**
   - **根因**：① `AnalyzeUrl::parse`/`parse_with_js` 未使用 `baseUrl`，相对 searchUrl（`/search?...`、`statics/...`）原样发出；② 无 path 的 host 拼接相对路径时 `rfind('/')` 命中 `://`，拼成 `https://statics/...` 假域名（拷贝漫画等）。
   - **修复**：`parse` 读取 `variables.baseUrl`；`get_absolute_url` 对「仅域名 base」正确追加路径。
   - **仍未对齐**：站点失效/空结果、page=1、个别源 JS（如快看 `__NUXT__`）仍会少结果；分组请选「漫画书源」（约 67 源），「图片书源」组本身仅约 4 个源。

2. **「暂无章节」（51 等 `<js>+$[*]` 目录）**
   - **根因**：`get_elements` 把 `<js>...</js>\n$[*]` 拆成 Js+Extract，对 HTML 跑 `$[*]` → JSON parse error，再被 `unwrap_or_default` 吞成 0 章；站点已无「目录」脚本时本应走 btn-read 回退。
   - **修复**：`<js>` 规则与 `get_strings` 一样走单步路径；目录解析错误不再静默；空标题+有 URL 仍保留章节；`book.name` 取首行。
   - **探针**：51 TOC 从 0→1（站点侧仅露出开始阅读章）；神漫画 TOC=61。

3. **`{{$.comic_id}}` 双花括号**
   - **根因**：丁斐等 `bookUrl` 用 `{{$.id}}`，只剥内层留下 `{106209}` → TOC HTTP 422。
   - **修复**：`process_inner_rules` 优先替换双花括号形式。

编写者：Reasonix ｜ 2026-08-11

## [2.0.29] - 2026-08-11

### 修复（51封面 + 漫画搜索/目录/正文引擎缺口，[Rust]+[UI]）

1. **51漫画封面不显示**
   - **根因**：书源 `coverDecodeJs`（AES/CBC/PKCS5Padding）未接入；`BookCover` 直连 `CachedNetworkImage`，密文进 `FlutterImageDecoder`（logcat `Failed to decode image`）。正文 `imageDecode` 已通但封面走另一套规则。
   - **修复**：`BookCover` 按 origin 加载书源，将 `coverDecodeJs` 映射为既有 `fetchImageWithDecode`；书架/搜索/详情/网格传 `sourceOrigin`。

2. **搜索几乎只有三站出结果**
   - **根因（引擎级）**：① 神漫画等 `bookUrl`/`coverUrl` 模板 `https://...?id={$.comic_id}` 内嵌替换后仍当 JsonPath 求值 → 空 URL 回退书源主页；② `@put:` / `extract@js:` / `##` 替换缺失致大量规则失败；③ Flutter 按「书名|作者」去重吞掉同名多源。
   - **修复**：内嵌 `{$.…}` 替换后返回字面量；AnalyzeRule 补 `@put` 剥离、`@js` 链、`##` 替换；去重键改为 `书名|作者|origin`。
   - **验证**：Rust 探针 神漫画/Nhentai/51/快看/COLA 单源搜索；**未声称与原版全网数量完全一致**（站点挂掉、page=1、其它 JS 缺口仍可能少结果）。

3. **神漫画 / Nhentai 目录与正文**
   - **核实**：51 目录/正文此前已通（本探针个别书详情页已无「目录」脚本属站点侧）；神漫画/Nhentai 为引擎缺口。
   - **根因**：神漫画 `chapterName` 含 `@put`、`chapterUrl` 为 `$.id@js:…`；正文 JS 需 `chapter.index`/`book.totalChapterNum`；Nhentai 正文 `//script@js:match…`。
   - **修复**：同上规则链 + 正文注入 chapter/book；探针：神漫画 TOC=61 CONTENT>2k；Nhentai TOC=1 CONTENT>7k。

编写者：Reasonix ｜ 2026-08-11

## [2.0.28] - 2026-08-11

### 修复（51漫画图片全失败：jniLibs 未带上 createSymmetricCrypto/NoPadding，[Rust]+[UI]）
- **设备证据（emulator-5558 / 2.0.27+29）**：正文 40 张 `pic.xmbvxj.cn/...jpeg?auth_key=…` 已解析；logcat `FlutterImageDecoderImplDefault: Failed to decode image` / `Input contained an error` 刷屏。书源 `ruleContent.imageDecode` 为 AES/CBC/NoPadding + `java.createSymmetricCrypto(...).decrypt(result)`；raw 下载 magic=`4FE8…`（密文），桌面同 key/iv 解密后 `FFD8` + PIL JPEG 1280×1842。
- **根因**：2.0.26 已修 `createSymmetricCrypto` 对象桥与 `AES/CBC/NoPadding`，但 **5558 安装包内 `liblegado_ffi.so` 仍是 16:30 旧产物**（缺 `AES/CBC/NoPadding` / `decrypt input must` 等符号）；Dart 版本号升到 2.0.27 却未重编/同步 Android jniLibs → 实机 decrypt 仍失败，密文进解码器。
- **修复**：按 `rust/scripts/build-android.ps1` 重编 x86_64/arm64 `liblegado_ffi.so`（quickjs）并同步 jniLibs；漫画阅读器有 origin 时禁止 `CachedNetworkImage` 直连密文 CDN。
- **回归**：设备密文夹具 `tests/fixtures/51manga_page_cipher.bin` + 离线 51 imageDecode；桌面 `fetch_image_with_decode` 实网探针 JPEG。

编写者：Reasonix ｜ 2026-08-11

## [2.0.27] - 2026-08-11

### 修复（漫画/视频空目录自愈 + 51漫画链路取证，[UI] 为主 + [Rust] 回归测）
- **根因（51漫画「看不到正文/图」）**：设备 DB 中该书 `chapters=0` 且 `bookType=notShelf|image`。详情页对未入书架书只内存取目录不落库；「开始阅读」进 `ReaderComicScreen` 仅 `getChapters`，**不像文本阅读器 `ReaderNotifier` 那样在空目录时 `refreshToc`** → 永远「暂无章节」，后续 imageDecode 链路根本走不到。Rust 侧对同一书源实测：搜索 50 条、TOC 回退 1 章、正文含图 URL、AES/CBC/NoPadding imageDecode 出 JPEG——解密本身在 2.0.26 已通。
- **修复**：[UI] `ReaderComicScreen` / `video_screen` / `audio_notifier` 空目录自动 `refreshToc`；`book_info_screen._openReader` 对非文本路由开读前补拉并落库目录。
- **回归**：legado-ffi 离线 51 规则 AES imageDecode；Flutter `reader_comic_empty_toc_test`（空目录→refreshToc→出图）。
- **搜索差距（尚未声称对齐）**：单源 51 搜索 Rust 可出约 50 条；全网差距仍可能来自（1）仅 page=1、无原版翻页；（2）Flutter 按「书名|作者」去重且未 `addOrigin` 合并多源；（3）961 启用源中部分 JS 规则在 QuickJS 失败被静默跳过。需用户用同一关键词对比「仅 51漫画」与「全源」再继续。
- **书源侧说明**：当前 51acgs 详情页脚本已无「目录」字样，规则走 `.btn-read` 回退（单集「全集」）——与原版同一规则语义，非重构独有缺陷。

编写者：Reasonix ｜ 2026-08-11

## [2.0.26] - 2026-08-11

### 修复（对称加密 JS 对象桥 + aesBase64Decode + 图片魔数校验，[Rust]+[UI]）
- **根因 B（漫画能进正文但图全挂）**：`java.createSymmetricCrypto` 此前只返回 `"AES/CBC"` 字符串，书源 `cipher.decrypt(result)`（如 51漫画 AES/CBC/NoPadding imageDecode）恒失败 → 密文进 `Image.memory` → `Invalid image data` / FlutterImageDecoder 刷屏。修复：返回含 `decrypt`/`decryptStr`/`encrypt*` 的对象；core 补 `AES/CBC/NoPadding`；`fetch_image_with_decode` 在有 imageDecode 时校验 JPEG/PNG/GIF/WEBP 魔数，失败显式报错
- **根因 A（多数图片源无目录/正文）**：缺 `java.aesBase64DecodeToString`（全网漫画等 init/toc/content AES 解密）。补齐宿主桥；另：个别书源 `bookSourceUrl` 误写为 `…/@遇知` 属源数据问题，会 404
- **UI**：解密结果魔数校验，拒绝把密文写入预加载缓存
- 测试：legado-js createSymmetricCrypto/imageDecode/aesBase64；legado-core NoPadding；Flutter looksLikeImageBytes
- 实现：Reasonix（Rust/UI）

编写者：Reasonix ｜ 2026-08-11

## [2.0.25] - 2026-08-11

### 修复（书架 BookType 分流 + 漫画复合 URL/预加载 + imageDecode 新引擎 + 视频相对 URL/重试/进度 + 媒体 MPD 钩子，[Rust]+[UI] 双轨）
- **书架/详情 BookType 分流统一**（[UI]）：抽出 `BookOpenUtils`（位标记→路由：video/audio/image/text/webFile），书架已读直开与书详情「开始阅读」共用，避免分流复制漂移；补齐视频路由 `/video`
- **复合图片 URL 完整抽取**（[Rust]+[UI]）：`HtmlFormatter` / `comic_image_utils` 正则对齐原版——`src="url,{"headers":{...}}"` 引号内嵌 JSON 双引号不再截断为 `...webp,{`；漫画阅读器预加载与正式渲染统一走 FFI（复合 URL / imageDecode / 书源 header）
- **imageDecode 每次新引擎 + Referer 兜底**（[Rust]）：同源多图连续 decode 勿复用 `pool_engine`（顶层 const/let redeclaration → 退回密文）；jsLib 可选降级；`default_referer_from_source_url` 修正无路径域名不被截成 `https:`
- **视频相对 URL / 重试 / 进度**（[UI]）：章节正文相对路径以章节 URL 绝对化；错误「重试」按 book/直链正确重试当前章；退出/切章写回 `durChapterIndex`/`durChapterPos`；首帧 loading 避免 late controller 未初始化
- **媒体 MPD 钩子**（[Rust]）：视频/音频正文跳过 HTML 净化（MPD XML 以 `<` 开头会被剥标签破坏）；经 `VideoPlayerState::normalize_content` 识别空正文/Url/Mpd，清单原文透传供 UI 写临时文件播放
- 测试：新增复合 URL / BookOpen / 视频绝对化 / MPD 透传单测；5558 冒烟验收（v2.0.25+27）
- 实现：Reasonix（Rust/UI）；协调/交付：Auto
- 已知书源侧：favcomic 图床 NXDOMAIN——图片实测请用其他可用漫画源

编写者：Reasonix（实现）/ Auto（协调交付）｜ 2026-08-11

## [2.0.24] - 2026-08-11

### 修复（规则 JS 执行引擎池复用 const redeclaration，[Rust] 轨）
- **模拟器实测仍无目录的差异根因**：Rust 网络测试通过但 app 失败——进程内**引擎池复用**。书源规则常用顶层 `const/let` 声明（51漫画 chapterList `const scripts`），QuickJS 同一引擎第二次执行同一规则必报 `redeclaration of 'scripts'`（全局词法环境残留）。测试每次新进程（干净池）通过；app 内多次刷新/进详情页第二次执行即失败 → 目录空
- 修复：`QuickJsExecutor.execute_js` 每次执行创建**独立新引擎**（用完即弃），对齐原版 Rhino 每次 evalJS 新作用域语义；移除 QuickJsExecutor 的 pool 字段（global_pool/pool_engine 保留供 imageDecode 等一次性 eval 场景）
- 测试：legado-ffi 264/264 全过；5556/5558 冒烟 6/6（v2.0.24+26）

## [2.0.23] - 2026-08-11

### 修复（漫画源目录「暂无章节」最终根治，[Rust] 轨）
- **51漫画真实链路实测打通**（搜索→目录→正文），四层根因：
  ① QuickJS eval 严格模式禁止裸赋值：书源规则 `d = c ? ... : [...]`（未声明变量赋值）抛 ReferenceError（原版 Rhino 宽松模式允许）。修复：execute_js_rule prologue 预声明常见裸赋值变量（`var d/data/json/list/arr/obj/tmp`，避开书源可能 const 声明的 scripts/c/item 等防冲突）
  ② `get_elements` 对 `<js>` 规则误路由：`resolve_rule_type` 把 `<js>` 前缀判为 Auto/Css → 走 HTML 解析器 → 目录 0 章。修复：get_elements 开头显式识别 `<js>` 转 get_strings
  ③ `<js>...</js>\n$[*]` 复合规则：`</js>` 后 JSONPath 后缀被忽略，JS 返回的 JSON 数组未拆解（51漫画 chapterList 用 `JSON.stringify(d)` + `$[*]`）。修复：get_strings 的 `<js>` 分支对 `$[...]` 后缀逐元素 JSONPath 拆解
  ④ java 桥 `@attr` 链：`.btn-read@href` 需取 href 属性（对齐原版 AnalyzeByJSoup lastIndexOf('@') + getResultLast），非 CSS 选择器。修复：html_parse select_with_attr 拆分 selector@attr + @text 语义
- 实测：51漫画 refresh_toc 出章节（url=/comic/5957/chapter/18465）、正文 5395B 含真实图片 URL
- 测试：legado-parser 182/182、legado-js 471/471、legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.23+25）

## [2.0.22] - 2026-08-11

### 修复（漫画源目录「暂无章节」根治：java HTML 解析桥 + book 绑定，[Rust] 轨）
- **「暂无章节」根因⑥**：漫画书源目录/正文规则大量使用原版 JsExtensions 的 HTML 元素桥 `java.getElement(css)` / `java.getString(css, html)`（51漫画 chapterList 用 `<js>Array.from(java.getElement("script"))...</js>` 提取目录 JSON、快看/爱优漫等依赖），重构版 java 命名空间仅有工具函数 → ReferenceError → 目录解析空
- 修复：新增 `legado-js/src/host_api/html_parse.rs`——`getElement`/`getElements` 返回元素对象数组（`html()`=innerHTML / `text()` / `toString()`=outerHTML / `attr(name)`，对齐 JSoup Element），`getString`/`getStrings` 取文本；内容源读 `globalThis.src`（execute_js_rule 注入），getString 第二参 mContent 可覆盖；注册到 java 命名空间（getElement 等为 AnalyzeRule 方法语义，不挂裸全局）；legado-js 新增 scraper 0.22 依赖
- 修复②：`web_book.get_chapters` 目录解析未注入 `book` 绑定（51漫画规则 `book.name`）——从 ruleBookInfo.name 提取书名注入
- 测试：legado-js 471/471（新增 html_parse 3 测试）、legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.22+24）

## [2.0.21] - 2026-08-11

### 修复（漫画站图片复合 URL `url,{json headers}` 支持，[Rust]+[UI] 双轨）
- **图片不显示根因⑤**：favcomic.com 等漫画书源正文图片 URL 为原版复合格式 `url,{"headers":{...}}`（内嵌 User-Agent/Referer/x-requested-with 防盗链，对齐原版 AnalyzeUrl.kt analyzeUrl 切首个 `,` 前为 URL、后部 JSON 解析为 headerMap）。此前 CachedNetworkImage 直连将整体当 URL 请求 → `Invalid image data`（模拟器崩溃日志实测）
- 修复：[Rust] `fetch_image_with_decode` 新增 `split_composite_image_url` 拆分复合 URL 与内嵌 headers（与书源 header 合并，内嵌优先）；[UI] `reader_comic_screen` 图片统一走 FFI 下载（Rust 支持复合 URL + 防盗链 + imageDecode，无规则原样返回 bytes），`_bookSource == null` 保留 CachedNetworkImage 兜底
- 实测：Rust 全量 264/264（新增 test_split_composite_image_url）；flutter test 1153/1153、analyze 0 error；5556/5558 冒烟 6/6

### 已知书源侧问题（非代码缺陷）
- favcomic.net 图床 `ccdeoo.ykxbo.cn` 已 NXDOMAIN；favcomic.com 域名连接失败（站点失效）——图片源请以其他可用漫画源验证

## [2.0.20] - 2026-08-11

### 修复（书源 jsLib 加载失败降级，[Rust] 轨）
- **正文全空回归根治**：favcomic 等漫画/视频书源的混淆 jsLib 依赖 Android Rhino 特有全局（`Packages` Java 桥、`decode` 等），QuickJS 无法完整执行（实测 eval 报 `decode is not defined`）。v2.0.19 将 jsLib 求值失败从静默改为**报错阻断**，导致所有带 jsLib 书源的正文解析直接失败 →「能搜到但正文图片/视频无法显示」（全局回归）。修复：jsLib 求值失败**降级为 eprintln 警告并继续执行**——正文规则多为不依赖 jsLib 的纯正则/CSS（favcomic 正文 `<js>src.match(...)` 提取出完整 2966B 图片列表），阻断会误伤；后续 JS 规则引用缺失函数时仍自然抛 ReferenceError 可排错
- 实测（真实站点，Rust 网络测试）：favcomic 搜索→目录→正文恢复 2966B（此前 jsLib 阻断时 Content empty）；legado-ffi 263/263 全过；5556/5558 冒烟 6/6

### 已知书源侧问题（非代码缺陷）
- favcomic 图床域名 `ccdeoo.ykxbo.cn` 已 NXDOMAIN（书源写死的域名失效），该源图片显示需书源更新或换源

## [2.0.19] - 2026-08-11

### 修复（漫画/图片源 imageDecode 解码 + JS 注入严格模式根治，[Rust]+[UI] 双轨）
- 漫画/图片站图片无法显示根因③（**imageDecode 解密缺失**）：favcomic 等漫画站图片 bytes 经站点专用加密，书源通过 `ruleContent.imageDecode`（配合 jsLib）JS 解密后才可显示，重构版仅有字段无执行。修复：Rust 新增 `image_api`（下载图片[书源 header 防盗链+兜底 Referer] → 注入 `result`(Uint8Array)/`src`(URL) 绑定执行 imageDecode JS → base64），`legado-js` 新增 `eval_bytes`（`JsValue::Bytes` 以 Uint8Array 注入/结果读回）；`ffi.rs` frb 模块新增 `fetch_image_with_decode`（上一版误加进已冻结的 `bridge.rs`——该模块 DEPRECATED 冻结新增且 Flutter 无 dart:ffi 绑定调不到，已移除恢复冻结约束）；Flutter `reader_comic_screen` 书源含 imageDecode 规则时走 FFI 解码下载（`Image.memory` 显示，带缓存与重试），无规则时保持直连不回归
- 「搜到书但正文为空」JS 规则执行根因④（**严格模式裸赋值**）：上次将绑定注入由 `var result` 改裸赋值 `result = ...`（规避 jsLib `let/const result` 重复声明），但 QuickJS eval 处于严格模式，裸赋值抛 `ReferenceError: result is not defined` → 全部 `@js:`/jsLib 规则静默返回空（legado-ffi 5 测试失败，即上轮卡点）。修复：改 `globalThis.result = ...`（对齐原版 `ScriptableObject.put` 语义，严格模式合法且不构成重复声明）；jsLib 求值失败不再静默吞（favcomic 正文/imageDecode 引用 jsLib 函数，失败必须可见可排错）
- 修复既有缺陷：漫画阅读器 `_preloadVisibleImages` 在 loading 态访问未 attach 的 ScrollController 抛断言（`ScrollController not attached`），加 `hasClients` 防御

### 测试
- 新增：`image_api` XOR 解码单测 + favcomic 真实站点链路（网络测试，`#[ignore]`）；Flutter `reader_comic_decode_test`（含 imageDecode 规则走解码下载 / 无规则不触发）
- 全量：legado-ffi 263/263、legado-js 468/468、legado-parser 180/180；flutter analyze 0 error、flutter test 1153/1153
- 实机验证：重建 Rust .so（x86_64+arm64-v8a，quickjs）→ 重打包 → 5556 启动无崩溃 UI 完整渲染（书架/发现/订阅/我的）、5558 冒烟 6/6 全 PASS（此前 content hash 不匹配系 APK 内旧 .so 所致，已根治）

## [2.0.18] - 2026-08-11

### 修复（漫画/视频源正文与目录根治，[Rust] 轨）
- 漫画/视频源「正文为空、图片不显示、无法播放」根因①：规则 JS 执行器**零变量注入**——原版 AnalyzeRule.evalJS 注入 result/src/baseUrl/chapter/title/source 等 bindings（AnalyzeRule.kt:893-908），重构版 execute_js_rule 直接执行裸 JS → 视频源 `@js: String(result)` 与漫画源 `<js> src.match(...)` 全部 ReferenceError → 正文空。修复：AnalyzeRule 自动注入 `result`/`src`（=当前内容）/`baseUrl`，新增 `with_js_binding` 注入 `chapter`（`{title}` 对象）/`title`/`source`（web_book 正文解析处传入章节标题）
- 漫画源「目录 0 章」根因②：CSS 规则 `@a` 后缀被误判为**属性提取**（"a" 被当作属性名）而非**标签选择链**——漫画书源 chapterList 常写 `.right_box:nth-child(2)@a`（原版 AnalyzeByJSoup 的 `@` 链末段为标签名时继续选元素）。修复：html.rs 增加常见 HTML 标签名白名单，`@a`/`@div` 等按元素选择链处理，`@href`/`@src`/`@text` 等属性语义不受影响
- 实测（真实站点全链路）：伪七猫影视（视频源）搜索→目录→正文提取 `https://vod1.maowushi.com/.../index.m3u8` ✅；favcomic（漫画源）搜索→目录 8 章→正文 `2966B` 含 `<img>` 图片列表 ✅（书源原规则即可用，无需改书源）

### 测试
- 新增：analyze_rule JS bindings 注入测试（result/src/baseUrl/chapter/title/source 断言）、html `@a` 标签链测试（含 `@href` 属性语义回归）；legado-parser 180/180、legado-ffi 261/261 全过
- 遗留登记：armv7 so 交叉编译失败（NDK 28 链接问题，模拟器 x86_64/真机 arm64 不受影响）

## [2.0.17] - 2026-08-11

### 新增（离线缓存界面，对齐原版 CacheActivity）
- **缺口**：缓存下载全链路（阅读页缓存 → 队列页 → 缓存管理）缺少**离线缓存界面**——原版 CacheActivity 的书籍列表页（bookshelf_screen TODO 登记「CacheActivity 对齐尚缺——缓存管理独立页（书籍列表/缓存进度/单本导出入口）、缓存下载（download_after/download_all）」）
- 新增 **OfflineCacheScreen**（路由 `/offline_cache`）：书架书籍缓存状态列表，每项按原版 `item_download.xml` 三行布局（书名/作者/「已缓存 N/总章节数」）+ 右侧播放/停止下载按钮（原版 iv_download）+ 单本导出按钮（原版 tv_export）；顶栏菜单含**全部缓存**（download_all 0..末章）/ **缓存当前章节之后**（download_after 当前章..末章，原版 sureCacheBook 确认对话框）/ **停止全部下载** / **下载队列**；缓存章节数（listCachedChapterUrls）与进行中任务（cacheDownloadList）2s 轮询实时刷新（对齐原版 EventBus 语义）；点击列表项对齐原版 startActivityForBook（未读进书详，已读进阅读器）；本地书显示「本地书籍」并隐藏下载按钮（原版 isLocal 短路）
- **入口**：书架溢出菜单「缓存导出」替换为「离线缓存」（对齐原版书架菜单 menu_download「缓存/导出」→ CacheActivity），原选书导出对话框迁移为页内单本导出（功能等价：章节标题+已缓存正文拼 TXT 经分享保存）
- 遗留：epub/pdf 导出类型、导出文件夹选择与文件名模板、自定义导出设置、导出进度与 WebDav 仍待 FFI（同 bookshelf 原 TODO 其余项）

### 测试
- 新增离线缓存页 widget 测试 5 个（空态/三行列表与本地书短路/单本下载 download_all 参数/菜单批量下载确认对话框/下载中进度与停止按钮）；flutter analyze 0 error、flutter test 1150/1150 全过

## [2.0.16] - 2026-08-10

### 修复（缓存下载链路根治：真实下载 + 队列页 + 目录图标实时刷新，对齐原版 CacheActivity）
- **根因**：阅读页「缓存」按钮走 `downloadAddTask`——Rust `download_api.rs` 仅内存任务登记**无下载执行**（不抓正文、不写 cached_chapters）→ 目录页云图标永不亮（「无法识别是否已经下载」）；且无下载队列页（CacheSettingsScreen 仅统计/清理，无进度列表）。真正下载的 `cacheDownloadStart/Progress/List/Cancel` FFI 已生成但 Dart 侧零调用
- 修复：① BookApi/RustApi/MockBookApi 封装 4 个缓存下载方法（接通 FFI）；② 阅读页缓存对话框改用 `cacheDownloadStart` 批量任务（真实逐章下载写 cached_chapters，Rust worker 已在 v2.0.14 就绪）；③ 新增**缓存下载队列页**（CacheDownloadScreen，对齐原版 CacheActivity：任务列表/进度条/状态/取消，2s 轮询），路由 `/cache_downloads` + 书籍信息页菜单「缓存下载队列」入口；④ 目录页**云图标实时刷新**（在线书每 2s 轻量轮询 listCachedChapterUrls，对齐原版 EventBus.SAVE_CONTENT 语义——下载进行中图标即时变实心）
- 说明：任务表为 Rust 进程内内存表（重启后任务进度不可恢复，同批登记到 REMAINING_PLAN 遗留项）；下载正文依赖书源正文规则（站点不可用时该章失败计入 failed，不阻断整体）（Reasonix）

### 测试
- 新增缓存下载队列页 widget 测试 2 个（空态/任务列表状态与取消按钮）；cargo test（quickjs）legado-ffi 全量通过（缓存下载写表逻辑已有 test_local_book_batch_download 覆盖）；flutter analyze 0 error、flutter test 1145/1145

## [2.0.15] - 2026-08-10

### 修复（图片源搜索 + 漫画正文图片 + 视频播放，对齐原版）
- 图片书源分组搜索无结果：5 个图片源（爱妹子/Asian Porn Image/爱轻写真/学姐吧/萌图社）中 `@js:` 前缀 searchUrl 与 `{{encodeURIComponent(key)}}` 模板在搜索链路已由 v2.0.14 修复；本版补 **AnalyzeRule 不支持 `<js>` 标签**的核心缺口——规则引擎仅认 `@js:` 前缀，`<js>...</js>` 包裹落入 CSS/Auto 解析返回空（原版 RuleAnalyzer 将两者同视为 Mode.Js，JS 结果直接作为提取结果）。修复：`AnalyzeRule.get_strings` 识别 `<js>...</js>` 包裹并执行 JS（对齐原版 Mode.Js 语义）（Reasonix）
- 漫画正文图片不显示：① 正文/目录/书籍信息/搜索解析链路（web_book.rs 全部 9 处 construct_analyzer 调用点 + parse_content_page / fetch_paginated_content / fetch_sub_content / apply_content_replace_regex）**注入书源 jsLib**（漫画源 ruleContent 大量 `<js>eval(String(Reload('...')))</js>` 引用 jsLib 函数，不注入则 JS 抛错 → 空正文）；② Flutter 漫画阅读器：图片请求带**书源防盗链 header**（CachedNetworkImage httpHeaders，对齐原版 glide getGlideUrl 带 headerMap——CDN 校验 Referer 时无 header 403）；③ 相对图片路径以章节 URL 为 base 转绝对（对齐原版 BookHelp.flowImages getAbsoluteURL）；④ 图片 URL 解析兼容 JSON 数组/逗号列表（解析 img 标签 + 每行 URL 白名单外再补 JSON 数组解析）（Reasonix）
- 视频正文无法播放：① 正文链路 jsLib 注入（同漫画）；② `_extractVideoUrl` 增强——支持 `<iframe>/<video>/<source>/<embed>` 标签 src 提取（视频源 ruleContent 常返回播放器页 HTML，纯正则取首个 URL 会取到无关链接），兜底保持首个 `https?://` URL；③ 播放请求带书源防盗链 header（VideoPlayerController.networkUrl httpHeaders，对齐原版 player.mapHeadData）（Reasonix）

### 测试
- 新增 Rust 测试 3 个：`<js>` 标签 + jsLib 注入正文解析（web_book parse_content_page_with_js_lib）、无 jsLib 降级、js_executor jsLib 注入；cargo test（quickjs）legado-ffi 261 + legado-parser 178 全过；flutter analyze 0 error、flutter test 1143/1143 全过

## [2.0.14] - 2026-08-10

### 修复（Rust 搜索链路，对齐原版）
- 搜索无结果根治（原版可搜到、重构版搜不到）：yckceo 书源包（968 源中 896 个 searchUrl 含 `{{}}` 模板）大量使用 `{{encodeURIComponent(key)}}`（思兔阅读 sto66 等核心源），而 quickjs 宿主**未注册 encodeURIComponent** → 表达式求值失败 → URL 中模板被替换为空串 → 搜索 URL 残缺 → 无结果。修复：
  - `legado-js` 新增 `encode_uri_component`（JS 标准语义：percent-encode 除 `A-Za-z0-9-_.!~*'()` 外全部字符）并注册到 quickjs 宿主（`encodeURIComponent`，java + globals，对齐原版 Rhino 内建）
  - 实测：思兔 `https://www.sto66.com/search/{{encodeURIComponent(key)}}.html` 渲染 `都市` → `/search/%E9%83%BD%E5%B8%82.html`，真实站点 HTTP 200 返回书条目
- 书源 jsLib 未注入模板 JS 执行器（图片/视频/漫画源搜索无结果主因之一）：yckceo 漫画源 searchUrl 大量使用 `<js>eval(String(Reload('...')))` 动态加载与 jsLib 定义的函数（getHosts 等），此前模板执行器不注入 jsLib 且沙箱禁用 eval → URL 构建失败。修复：
  - `QuickJsExecutor` 支持 `with_js_lib`，`construct_analyzer_with_js_lib`/`build_search_url_with_lib` 注入书源 jsLib（每次 JS 执行前先 eval 库，对齐原版 JsSource 语义）；搜索解析与 URL 构建链路接入
  - `EnginePool` 默认沙箱允许 `eval`/`Function`（对齐原版 Rhino 书源信任模型；js_eval 调试端点仍用严格 SandboxConfig::default()，安全边界保留）
  - `build_search_url` JS 路径条件扩展：含 `<js>`/`@js:`/`{{` 任一语法即走 JS 求值（此前 `<js>` 模板落入字面路径未被执行）
- 搜索结果 bookUrl 规则解析为空时回退书源主页（bookSourceUrl，对齐原版 `BookList.kt:282-284` + `AnalyzeRule.kt:369-375`），避免条目无法打开
- 搜索请求头缺 User-Agent 时补充 Chrome UA（对齐原版 `BaseSource.kt:202-204` + `AppConfig.userAgent`；默认 `Legado/1.0` 会被反爬站点拒绝）
- 新增 10 个 Rust 测试（encodeURIComponent 语义×2 + quickjs eval 渲染×2 + jsLib 注入×3 + bookUrl 回退 + UA 补充×2），全量 cargo test（quickjs）：legado-ffi 259、legado-js 468 全过（Reasonix）

## [2.0.13] - 2026-08-10

### 修复
- 图片源/音频源/视频源打不开（分流失效根治）：搜索输出不带 `type`（Flutter 侧 bookType 恒 0）且阅读前落库只写 `notShelf` 位（8/32/64 类型位丢失）→ 第二次起分流落回文本阅读器。修复（对齐原版 BookInfoActivity.startReadActivity）：
  - `_openReader` 解析类型位：bookType 缺类型位（0/仅状态位）时按书源类型（bookSourceType：1=音频/2=图片/3=文件/4=视频）映射补全位标记（text=8/audio=32/image=64/video=4/webFile=128）
  - 落库以正确类型位 + notShelf；已入库缺类型位旧数据回填 updateBook
  - 分流补齐 video 分支：视频源书 → `/video`（章节播放）
- 视频源书阅读（对齐原版 VideoPlayerActivity）：VideoScreen 支持 `book` 参数——加载章节列表、取当前章正文（视频链接，Rust is_media 分支不做 HTML 格式化）播放、上一集/下一集切换、章节标题显示；`_controller` 未初始化防御（异步加载中退出/首次播放）
- 新增 4 个分流 widget 测试（音频/图片/文本/视频 + 已入库缺类型位回归），全量 flutter test 1143/1143（Reasonix）

## [2.0.12] - 2026-08-10

### 修复
- 阅读进度不恢复：搜索结果进入书籍详情页→开始阅读→返回→再次进入总是回到第一章。根因：详情页 `book` 为 initState 旧快照，阅读返回后不重新加载（Rust 侧 `dur_chapter_index` 已正确写入 books 表但从未被该页面实例重读）。修复：`_openReader` 阅读返回后 `setState` 重新 `_loadData()`（对齐原版 BookInfoViewModel 重查语义），按钮按最新进度显示「继续阅读」并定位到上次章节；`ReaderNotifier.openBook` 同步恢复 `durChapterPos` 章内位置（Reasonix）
- 图片源/音频源不可用：`BookInfoActivity` 分流缺失——`_openReader` 无条件走文本阅读器，漫画阅读器（ReaderComicScreen）与音频播放器（AudioScreen）已实现但零调用方。修复：① `BookType` 常量由 0/1/2 枚举语义修正为位标记（对齐 Kotlin BookType.kt：text=8/audio=32/image=64/video=4/webFile=128）；② `_openReader` 按 `bookType` 位标记分流：audio→`/audio`、image→`/reader-comic`、文本→`/reader`，bookType 缺失（0）时兜底按书源类型（bookSourceType 1=音频/2=图片）判定；③ 书架「音频/视频」分组筛选改用位运算（原 `==` 单值比较恒失配）（Reasonix）

### 测试
- 新增 3 个分流 widget 测试（音频→音频播放页/图片→漫画阅读页/文本→文本阅读页，NavigatorObserver 断言路由）；AudioScreen.dispose 增加卸载时序防御（快速导航/测试树卸载边界）

## [2.0.11] - 2026-08-10

### 修复
- 搜索异常书源弹窗提示消除（对齐原版 SearchModel 静默语义）：批次回调补齐 `error` 字段消费——单书源搜索失败不再产生任何弹窗/整页错误提示路径，失败源不阻断整体搜索，仅按原版 `AppLog.put` 语义以 error 级别写入应用日志（「书源搜索出错」）留痕，可通过日志菜单查看（Reasonix）
- 搜索框文字显示不全修复：AppBar 搜索框 `isDense` 压缩行高 + `textAlignVertical.center` 垂直居中 + 清除按钮（suffixIcon）约束收敛至 32×32（原默认 IconButton 48px 高度撑破 36px 容器导致文字垂直裁切）
- 书籍信息页简介默认全部显示：`_ExpandableText` 默认展开（保留「收起」按钮），短简介仍由 TextPainter 自适应隐藏切换控件

## [2.0.10] - 2026-08-10

### 修复
- 搜索结果排序对齐原版 `SearchModel.mergeItems`：默认搜索也按匹配度分桶排序（equal 完全匹配 → tags kind 匹配 → contains 包含 → other 保底），不再按书源顺序展示；精准搜索丢弃 other 桶，切换精准开关自动重新搜索（对齐原版 SearchActivity）
- 精准搜索卡顿修复：分桶排序从 build 层移至搜索批次回调（每批次一次，对齐原版每次 mergeItems 后排序），展示层直接消费已排序结果，避免每帧全量分桶遍历
- bookUrl 空校验文案可读化（Rust）：「bookUrl不能为空」→「书籍详情页地址为空，无法获取详情/目录（该书源搜索/发现规则未解析出详情链接）」；非 JS 搜索路径空 bookUrl 回退 baseUrl 保持，JS 路径与原版一致丢弃空条目

## [2.0.9] - 2026-08-10

### 修复
- XPath 引擎 xmlns 声明处理修复（思兔阅读等书源目录/正文/详情解析根治）：
  - 根因：页面源码自带 `<html xmlns="http://www.w3.org/1999/xhtml">` 时，HTML→XHTML 回退序列化原样保留 xmlns 属性，sxd-document 解析后全部元素进入该命名空间，无前缀 XPath（`//dd`、`//a` 等）全部失配（仅 `//*` 与谓词字符串比较可命中）
  - 修复：`xpath.rs` `write_node_xhtml` 序列化时跳过 `xmlns`/`xmlns:*` 属性；实测思兔 sto66 详情页 tocUrl 规则（`//*[@id='allchapter']//a[contains(text(), '查看全部章节')]/@href`）从 0 项恢复 1 项、目录页 chapterList/chapterUrl 恢复 500 项
  - 影响面：所有在源码中声明 xmlns 的网站（含 XHTML 页面）的 XPath 规则此前整体失效，本次根治
  - 新增回归测试 `test_xmlns_declaration_does_not_break_prefixed_xpath`；legado-parser 178+1 全过

## [2.0.8] - 2026-08-10

### 修复
- 需登录书源目录/正文获取修复（loginCheckJs 三处语义修正，对齐原版 WebBook 双路径）：
  - `js_executor.rs` result 注入改为**带方法语义的 JS 对象**（原实现 to_string 后注入导致 result 为 JSON 字符串，真实书源 `result.body()`/`url()`/`code()` 写法全部失败）；判定剥除 eval 返回值的 JSON 引号（`"false"` 原无法匹配）
  - `web_book.rs` execute_login_check 区分两类错误：**判定未登录**（false/未登录/needLogin）→ errResponse（HTTP 500）二次 eval 对齐原版失败路径，仍未登录则上抛 `LoginRequired`（用户可见「书源需要登录，请先在书源菜单中登录后重试」）；**JS 环境不兼容**（依赖 java.* 等）→ 降级放行不阻断
  - `legado-core/error.rs` 新增 `LoginRequired` 变体（错误码 1012）；`legado-server/error.rs` 映射 HTTP 401 login_required
  - 新增单测 2 个（对象语义/判定分类），legado-ffi --features quickjs 253/253 通过，workspace 全量 0 failed
- 模拟器冒烟脚本修正：默认包名 `io.legado.flutter_legado`（与 applicationId 同步）、MainActivity 全限定类名 `io.legado.flutter.MainActivity`（原 `.MainActivity` 报 Activity does not exist）

## [2.0.7] - 2026-08-10

### 新增
- §5.12 纯 Flutter 三项行为接线（Reasonix 实施，全量 flutter test 1135/1135 通过）：
  - 双页模式（`doubleHorizontalPage` 0-3 档，对齐原版 ChapterProvider.upLayout）：`reader_page_view.dart` 档位判定（0=单页/1=双页/2=横屏双页/3=平板或横屏，滚动模式强制单页，桌面端窗口宽≥700 模拟平板语义），每栏可用宽（屏宽-边距-16 栏间隙）/2，双栏整屏渲染（`_buildSpread` 左 2s 右 2s+1，末屏右栏留白），屏索引翻页（步进 2），slide/simulate/none/cover 四翻页模式适配，分页缓存键
  - 自定义中文分行开关（`useZhLayout`，对齐原版 useZhLayout=false 走 StaticLayout 语义）：`paragraph_layout_engine.dart` `ParagraphConfig.useZhLayout`（默认 true 保持现行为）+ `_breakLines` 朴素按宽断行分支（无避头尾）
  - 段首标点悬挂（`hangingPunctuation`，对齐原版 HangingPunctuationRule + ZhLayout.hangingWidth）：`ChinesePunctuationRule.shouldHang`（缩进全角空格+起始引号判定）+ `ZhLayout.compute` 首行宽度上限放宽 + `_breakLines` 两分支首行悬挂 + `LineInfo.hangingWidth` 标记 + 渲染侧 OverflowBox 放宽约束 + Transform.translate 左移（标点悬挂进缩进区）

### 修复
- 顺带修复既有 lint：`reader_screen.dart` 自动换源监听 `(prev?.error ?? null) == null` 冗余（等价化简）

## [2.0.6] - 2026-08-10

### 新增
- 自定义 hosts（契约 §2.20.3 setCustomHosts）：legado-net Resolve DNS 覆盖（实时读全局映射 + 系统 DNS 回落）、持久化启动恢复，其他设置页 JSON 编辑对话框对齐原版（非法输入拒绝保存）
- MCP 独立端口（契约 §2.22.5 setMcpPort）：对齐原版 McpService（默认 1236，区间 1024..65530 越界报错），其他设置页接线
- 封面规则搜索（契约 §2.4.8 searchCoverRules）：coverRules 表执行启用规则（key 模板 + isUrl 提取 + 失败隔离），封面设置对话框测试入口（规则 CRUD 待后续契约）

### 修复
- MCP 暴露面收敛：独立服务仅挂 /mcp/tools /mcp/call /health + 127.0.0.1 回环绑定
- MCP DB 路径对齐主应用（不再另开库）
- MCP 同端口重启竞态与状态机互斥修复（实机验证监听地址与重启恢复）
- analyze_url data: URI 豁免对齐原版

### 变更
- frb 分派表重编号 159 起顺延——.so 与 Dart 生成物必须同批产出禁止混装

## [2.0.5] - 2026-08-10

### 新增
- 设置源变量（契约 §2.3 setSourceVariable）：单列 UPDATE + lenient 序列化双保险，Migration102To103 补列；详情页 `_VariableDialog` 对齐原版 setVariable 的 source 分支，§5.11 全部 7 项至此闭合
- 书签双键查询（契约 §2.7 getBookmarksByBook）：书名+作者双键（加法式），消费方全切换（bookmark_notifier/toc_screen/书签导出），MCP 宿主加法式可选 book_author 参数

### 修复
- 书籍写入 upsert 根治级联删除（主键判存在 + 原地 UPDATE / insert_replace），含 import_books 覆盖链路，新增重复插入保留 chapters 测试
- BookSource.variable 双轨 null 序列化失配修复（lenient 序列化双保险）
- 源变量/书籍变量对话框红屏（_VariableDialog 自持 StatefulWidget 范式，D1 修复）
- 源列表过滤残留（dispose clearFilter + 空列表不覆盖非空内存守卫，D2 修复）
- 备份恢复失败日志补齐

### 变更
- frb 配对纪律写入 TWO_TRACK_DEV_SPEC §3.5
- MCP 书签工具新增可选 book_author 参数（加法式兼容）

## [2.0.4] - 2026-08-10

### 新增（第二批后置项三 FFI 接线：压缩数据库/上传至远程/删除重复标题章级开关，契约 §2.16.6/§2.28.6/§2.9.10）
- 压缩数据库（契约 §2.16.6 shrinkDatabase）：其他设置页接通 VACUUM + 释放字节统计（失败降级返回 0），提示文案对齐原版
- 上传至远程（契约 §2.28.6 webdavUploadFile）：详情页菜单接通本地文件路径上传 + PUT 状态码校验，对齐原版 RemoteBookWebDav.upload（origin 回写 webDavTag+远端地址、lastCheckTime 刷新、仅本地书）
- 删除重复标题章级开关（契约 §2.9.10 toggleSameTitleRemoved）：阅读器顶栏开关接通，caches KV 章级 opt-out 持久化、正文净化六链路按章应用、缓存清理复位对齐原版 .nr 语义，切换后重载正文

### 修复（搜索 native 崩溃根治：rule_analyzer 零前进无限递归 + 正则安全编译统一加固）
- 搜索崩溃根治：四轮调查定位 rule_analyzer 零前进无限递归（移植时将原版 throw 改为 break 重试所致），对齐原版 fail-fast + tailrec 修复，五轮复测零崩溃；正则安全编译统一入口保留为纵深防御（非递归嵌套预检 + LRU 缓存 + logcat 诊断）
- 对话框红屏、书籍变量 setState 断言、书签导出 SAF 选目录、书签时间戳单位修复
- WebDAV PUT 状态码校验（非 2xx 不再静默成功）

### 变更
- tokio runtime 线程栈扩至 8MB（FFI/server/JS/webdav 兜底 runtime 统一，对齐原版 JVM 线程栈水位）
- 正则缓存 LRU 化（替换 regex-syntax 预解析依赖为 lru 淘汰）
- build-android.ps1 EAP（ErrorActionPreference）修复

## [2.0.3] - 2026-08-08

### 变更（留项10：定时服务应用内调度器落地，对齐 Kotlin AutoTaskScheduler/AutoTaskJobService，署名 Qoder/QoderCN）
- 新建 `services/auto_task_scheduler.dart`（署名 QoderCN）：应用内 Timer 调度器单例，经 autoTaskListRules + autoTaskNextDueAt 计算最近到期（基准时间对齐原版 baseTime：lastRunAt>0 取之、否则 now-5 分钟首次宽限，对标 FIRST_RUN_GRACE_MS）；Timer 到点筛 isEnabled 且到期任务（对标 dueRules）逐个 autoTaskExecuteWithId；串行隔离：_running 执行锁同刻仅一批、重复触发跳过（对标 executionLock）；单任务失败不影响整批（对标 runTask 逐任务 catch），批次级失败 60s 退避重试（对标 jobFinished(retry=true)+RETRY_BACKOFF_MS）；批次完成后按 nextAfterBatchAt 语义重排；并发 refresh 以代数作废旧结果
- 触发点对齐原版：app.dart initState 装配 attach（对标 App.kt 启动 refresh）+ 应用自后台恢复 resumed 重算（WidgetsBindingObserver）；auto_task_screen 增删改/启停/立即运行/导入后经 _resyncScheduler 重算（对标 AutoTask.save/delete/updateEnabled 后 refresh）；设置页开关开启→refresh/关闭→cancelAll（对标 MyFragment 开关分支），持久化开关加载时恢复调度
- 过时标注清理：移除设置页「后端未移植/后续版本支持」TODO，副标题改为诚实描述「前台应用内调度（应用退出后不执行）」；真后台（进程被杀后仍调度）需 WorkManager，属决策项不在本批范围，保留诚实标注

## [2.0.3] - 2026-08-07

### 变更（留项6 第①批：阅读器 MoreConfig 无平台依赖配置项落地，每项真实生效，键名对齐原版 AppConfig——Qoder）
- MoreConfig 面板补齐第①批 11 项（对标原版 pref_config_read.xml 项序与文案，持久化键名=原版键）：屏幕方向 screenOrientation / 保持亮屏 keep_light / 隐藏状态栏 hideStatusBar / 隐藏导航栏 hideNavigationBar / 进度条行为 progressBarBehavior / 自动换源 autoChangeSource / 长按选择文本 selectText / 显示亮度控件 showBrightnessView / 滚动翻页无动画 noAnimScrollPage / 显示标题附加区 showReadTitleAddition / 工具栏跟随页面 readBarStyleFollowPage
- 逐项生效方式（对标 MoreConfigDialog.onSharedPreferenceChanged 事件语义）：隐藏状态栏/导航栏→SystemChrome.setEnabledSystemUIMode 手动 overlay 组合（退出阅读器还原 edgeToEdge），分页缓存键新增系统栏 padding 自动重新分页；屏幕方向→SystemChrome.setPreferredOrientations（0跟随系统/1竖屏/2横屏/3传感器/4反向竖屏/5反向横屏，退出还原）；进度条行为=page→底栏滑条改调章内页（跨章分页器取页数、currentChapterPos 取当前页，拖动驱动 ReaderPageView.goToPage，未注册时回退调章节）；自动换源→章节加载失败经 searchSource 取首个非同源候选→switchSource FFI→重开书（限在线书，同书最多 3 次防循环）；选择文本→关闭后正文段落长按选区面板入口移除（分页/滚动两路渲染）；亮度控件→底栏亮度行随开关显隐；无动画滚动→程序化翻页（点击区域/自动翻页/底栏调页）jumpToPage 无动画，滚动模式新增按屏翻页（到底/到顶跨章）；显示标题附加区→顶栏「书名 · 章名」；工具栏跟随页面→顶/底栏背景与前景色跟随阅读页配色（对标 ReadMenu immersiveMenu）
- 平台限制诚实标注：保持亮屏 keep_light 因项目未引入 wakelock 依赖（不改 pubspec）仅持久化，待平台能力接入后生效（与 audio_screen audioWakeLock 标注一致）；音量键翻页等平台相关项留第②批
- 既有测试同步：reader_components_test 顶栏书名断言适配标题附加区默认开启；settings_test 销记已移除的 QUIC 开关断言（2.0.3 QUIC 移除批遗留）

### 变更（Rust 剩余项全批闭合 R1-R10+R12 + QUIC 代码移除，用户决策纯重构边界——Nora/Paul/Hunk/Ivan/Simon/Dylan/Nick）
- Rust 剩余项全批闭合：R1+R2 web_book 正文 subContent 副内容（在线 txt/http 二次请求分支）与 replaceRegex 全文替换（对标 BookContent.kt L128-174）；R3 legado-server 正文接口真实实现（接 RealBookSourceFetcher 正文链路，替换元数据桩）；R4 dict_api 重写为原版字典规则引擎（dict_rules 表逐规则执行 DictRule.search 等价链路 + 表空时注入原版默认 5 字典源 seed，与 assets/defaultData/dictRules.json 同源）；R5 saveChapterContent 缓存写 FFI；R6 chapterPayAction 章节购买 FFI（复用登录 V2 JS 执行设施，url/success/none 三态）；R7 缓存批量下载 4 方法（内存任务表 + worker 线程 + 取消令牌）；R8 bookExportWithOptions 导出参数扩展（格式/charset/章节范围/文件名模板）；R9 font_api 字体反爬 cmap 真实替换（新增 query_ttf.rs）；R10 JS 书源段评回复（js_source_book.rs）；R12 bridge.rs C ABI 模块级 DEPRECATED 标注 + 冻结新增（废弃三步走之步骤2）
- QUIC 代码移除（用户决策，纯重构边界：QUIC 为 Rust 轨扩展、原版无对应能力）：删除 legado-net/quic.rs 与 legado-ffi quic_api.rs、QUIC 8+8 FFI 导出、quinn 等依赖，Dart UI 开关清理（other_settings_screen/book_api/mock_book_api/rust_api），codegen 重跑；契约 §2.41 登记移除记录、§3 待封装清单销记
- 契约：API_CONTRACT.md §2.43 新增 7 方法（R5 缓存写 / R6 购买 / R7 批量下载 4 方法 / R8 导出参数，均加法式、仅走 frb 主链路）+ §2.41 QUIC 移除记录
- 验证：cargo test --workspace 全绿、quickjs feature 213 全过、flutter analyze 0 error；台账销记见 REFACTORING_REMAINING_PLAN.md §5.10

### 修复（留项4+5：朗读段落化起点 + 语速跟随配置对齐原版——Qoder）
- 留项4 朗读段落化（AudioNotifier）：整章一次性送 audioSpeak 改为章节正文按段拆分入队逐段送播（对标原版 BaseReadAloudService contentList/nowSpeak 段落队列）；分段口径与阅读器排版引擎 ParagraphLayoutEngine._splitParagraphs 完全一致（双换行优先、否则单换行、逐段 trim 过滤空段），保证偏移映射起点与排版段落对齐；段落播完自动下一段（探活级 audioSpeak 无真实完成回调，暂以字数/语速估算时长驱动，clamp 0.8s~90s）、章末自动下一章（sequential/singleLoop/末章读完即停均保留既有跨章语义）；新增 nextParagraph/prevParagraph（对标原版 ReadAloud.nextParagraph/prevParagraph，章内边界自动跨章），播放令牌机制防陈旧异步/定时器回调；段落进度经 ChangeNotifier 混入通知 UI（不动 freezed State，免 codegen），rust_api 既有 audioSpeak 封装未动
- 留项4 段落级起播：startReadAloud 新增可选 startChapterPos 字符偏移参数，偏移映射段落索引起播（取最后一个 start<=offset 的段落，对标原版 pos→nowSpeak 定位）；另增 startParagraphText 段落文本匹配兜底（分页排版模式下 ParagraphInfo.startIndex 恒为 0、偏移不可用场景）；text_selection_panel 朗读所选传入 chapterPos + 段落文本，移除降级标注 TODO
- 留项4 read_aloud_bar 解禁：上一段/下一段按钮接入段落切换（朗读激活且段落队列非空时可用），头部新增「·段 x/y」段落进度指示
- 收口修复：read_aloud_bar 底行四按钮窄屏（720px 级）横排溢出 59px 黄条，改 Expanded 均分 + 紧凑内边距，任意屏宽不溢出；E2E 实机验证朗读控制条上一段/下一段可点、无溢出
- 留项5 语速跟随系统语义对齐原版：原版并非实时读系统语速，而是 ttsFlowSys 时 speechRatePlay=defaultSpeechRate(=5) 默认语速常量（AppConfig.kt L393）；勾选跟随→应用默认倍速 1.0x（即原版刻度 5 的等价映射）并禁用手动滑条、速度位显示「默认」，开关状态持久化生效时同步应用，无需系统语速读取通道
- 回归：audio_provider_test 63 项全绿（播放/暂停/停止/上下章/播放模式/配置全链路）；flutter test 1115 过、仅 2 失败为并行代理改动所致（ReaderTopBar 显示书名/OtherSettingsScreen QUIC 开关已移除，均不涉及本任务文件）；flutter analyze 本任务文件 0 error/warning

### 变更（主搜索页分组选择改原版锚定菜单方式：点选即生效自动重搜，解决底部弹窗高度小列表截断——Qoder）
- 分组选择改锚定 PopupMenu：三点菜单「分组或书源」不再直接打开底部弹窗分组 Tab，改为 `showMenu` 弹出锚定三点按钮下方的分组菜单（对齐原版 SearchActivity.onMenuOpened 溢出菜单形态）——「全部书源」+ 各分组名，当前选中分组带勾选标记；点未选分组=单选替换（对标原版 `update(title)`）、点已选分组=取消（对标原版 `remove(title)`）、点「全部书源」=清空；点选即生效且已有关键词时自动重搜（对标原版 scope 变更观察者重搜行为），无需确定按钮；菜单高度自适应、分组多时自动滚动不截断
- 书源多选保留：锚定菜单底部「书源多选…」入口打开 SearchFilterPanel；面板分组 Tab 移除（已被锚定菜单替代），仅保留书源多选（全选/搜索过滤/确定批量生效）；弹窗初始高度由 0.6 加大至 0.9（max 0.95），解决书源列表截断
- 实机 E2E 验证（emulator-5556）：锚定菜单弹出「全部书源」带勾选 → 点「快速书源」立即自动重搜 170→75 条且显示「1 分组」chip，重开菜单「快速书源」带勾选；菜单可滚动不截断；「书源多选」面板加高后列表完整不截断

## [2.0.3] - 2026-08-06

### 修复（「按分组搜索用不了」：换源页分组过滤生效 + 主搜索页选分组自动重搜，留项#12 闭合，跨 Rust+UI 全链，契约先行——Qoder/QoderCN）
- 换源页分组搜索修复（根因：Rust `search_alternative_sources` 硬编码 `list_enabled_sources()` 搜全部源，选分组仅存 config 不生效）：`ffi::source_switch_search` 新增可选参数 `source_urls_json`（空串/空数组/缺省=搜全部启用源，加法式兼容既有调用，语义与 `search_books` 完全一致，复用 `search::load_search_sources` 过滤逻辑），契约登记 API_CONTRACT.md §2.4；C ABI `ffi_source_switch_search` 同步加参；新增单测「传 URL 列表只搜指定源 / 空参数搜全部」；codegen 重新生成 Dart 绑定 + 重建 x86_64 .so
- UI 接线：`BookApi.searchSource` 加可选 `sourceUrls` 参数（rust_api 编码为 sourceUrlsJson / mock 模拟过滤语义，署名 QoderCN）；`ChangeSourceNotifier.search` 加 `group` 参数——非空时用 `getEnabledBookSources()` 内存过滤出该分组源 URL 列表传给 searchSource（分组下无启用源时直接空结果，不误搜全部）；`change_source_screen._search()` 传入 `_searchGroup`，分组过滤全链生效，删除过时 TODO(留批次) 注释
- 主搜索页 UX 修复：三点菜单选分组/书源关闭筛选面板后自动重搜（筛选变更且有关键词时），对齐原版选 scope 后自动重搜行为，避免「选了没用」
- 筛选面板红屏修复（E2E 实机发现）：全局 `tabBarTheme` 设 `TabAlignment.start`（仅滚动 TabBar 合法），`search_filter_panel` 非滚动双 Tab 面板在 debug 下触发断言红屏+底部溢出，面板完全不可用；显式 `tabAlignment: TabAlignment.fill` 覆盖主题修复，分组/书源选择恢复可用
- 台账销记：REFACTORING_REMAINING_PLAN.md §5.9 留项 1（searchSource 分组过滤）闭合（v1.10）

### 修复（书详情页背景分区：仅顶部封面区虚化，章节列表区改纯色——Qoder）
- 书详情页背景分区回退：上一提交 `c620c97e4` 将章节列表 section 底色改为半透明 scrim（`cs.surface` alpha 0.82）让封面虚化整页透出，用户确认不要此效果。现回退 `book_info_screen._buildBody` 章节列表 section（章节搜索/章节列表（N）头/空态/底部间距）为**不透明** `cs.surface`；章节列表本体额外用 `DecoratedSliver(BoxDecoration(color: cs.surface))` 铺满不透明底色——`ListTile.tileColor` 在全屏虚化栈上不可靠地绘制不透明背景（早期无虚化层时被不透明 Scaffold 底色掩盖，加虚化后暴露），故显式加不透明背景 Sliver 盖住虚化。`_buildPage` 的 `ImageFilter.blur` 封面虚化背景层保留，仅透过顶部透明的 `_buildHeader` 封面区显现，`_buildSummaryPanel` 及以下均用不透明纯色盖住虚化，形成「顶部封面虚化景深 → 章节列表纯色清爽背景」的自然过渡（`_buildSummaryPanel` 顶部圆角 20 作为过渡分隔）

### 修复（阅读器点击翻页失效回归——Qoder）
- 阅读器点击翻页失效（P0 回归）根因修复：`reader_screen._handleTap` 命中 `TapAction.nextPage/prevPage` 时经 `ReaderNotifier.nextGlobalPage/prevGlobalPage` 走「全局连续分页」路径，该路径仅更新 `globalPageIndex/currentChapterPos` 状态，却从未驱动 `ReaderPageView` 内部的 `PageController`，故点击后视觉上不翻页；且其「`globalPageIndex` 未变才回退章级翻页」的兜底判定在同章翻页时永不成立（同章翻页必然 +1），兜底 `pageView.nextPageOrChapter()` 从不触发。改为在 `_handleTap` 中直接调用 `ReaderPageView.next/prevPageOrChapter()`——统一驱动 `PageController` 完成各翻页模式（仿真/滑动/覆盖/无动画/滚动）视觉翻页与跨章无缝切换；删除失效的 `_navigateNextPage/_navigatePrevPage`
- 全局页码指示器同步修复：`ReaderNotifier.updatePosition` 在更新章内页位后补调 `_syncGlobalPageInfo()`，使点击翻页与滑动手势翻页时底部「全局页 N/总页」指示器实时更新（此前仅 `updateChapterPageCount` 才刷新，章内翻页时指示器停滞）
- 实机 E2E 验证（emulator-5556）：滑动模式右侧点击 1/558→2/558→3/558、左侧点击 3→2、中间点击呼出/隐藏菜单；仿真模式右侧点击 2→3 均生效，滑动手势翻页未受影响

### 修复（书详情页章节列表区背景虚化覆盖——Qoder）
- 书详情页向下滚动到章节列表时背景无封面虚化修复：`book_info_screen._buildBody` 中章节列表 section（章节搜索/章节列表（N）头/列表项 ListTile/空态/底部间距）原使用不透明 `cs.surface` 背景，完全遮挡了 `_buildPage` 铺满全页的 `ImageFilter.blur` 封面虚化层，导致仅顶部封面区可见景深、下方列表区为纯色。改为半透明 scrim（`cs.surface` withValues alpha 0.82），让封面虚化背景隐约透出、整页保持 iOS 沉浸景深一致；仍保留足够对比度确保章节文字可读（方案 B）

### 变更（书详情页 iOS 视觉重设计 + 溢出菜单对齐原版 + 阅读器顶栏溢出修复，署名 Qoder）
- 书详情页封面高斯虚化背景：`book_info_screen._buildPage` 封面图改用 `ImageFiltered(ImageFilter.blur sigma 25)` 作背景层 + 保留半透明 scrim 叠层，营造 iOS 沉浸景深；无封面降级纯色背景不加模糊
- 顶栏精简至 iOS 导航栏节奏：移除下载/导出按钮（原版书详情无此入口）；编辑按钮条件化，仅在架书籍显示（对标原版 `editMenuItem.isVisible = inBookshelf`）；保留分享 + 更多菜单；标题固定「书籍信息」
- 溢出菜单对齐原版 book_info.xml：条目顺序/可见性对标原版（onMenuOpened 判定）——上传至远程(仅本地书)/刷新/创建更新任务(在架+书源+非本地+允许更新)/登录(书源支持)/置顶/设置源变量·书籍变量(书源存在)/拷贝书籍URL·目录URL/允许更新(勾选,书源存在)/拆分长章节(勾选,本地txt)/删除提醒(勾选)/清理缓存/日志；移除「更新目录」独立项（刷新即含目录更新）；文案「拷贝书籍链接/目录链接」→「拷贝书籍URL/目录URL」、「删除警告」→「删除提醒」；占位项(设置源/书籍变量·删除提醒·上传远程·创建更新任务)保持 _todo 标注不强行实现
- iOS 排版层级：书名改 SF Pro 大标题风格(22sp/w700/负字距)，底部按钮主次分明（放入书架=tinted、开始阅读=filled），分享图标改 `ios_share`
- 阅读器顶栏溢出修复：`reader_top_bar` 顶栏 Row 图标过多致 `RIGHT OVERFLOWED BY 68 PIXELS`，将换源/刷新/缓存（原 menu_group_on_line 三枚 IconButton）收入溢出菜单（仅在线书显示），顶栏仅保留高频的夜间/搜索/书签，Row 不再溢出

### 修复（未入库书详情页加载链路，署名 Qoder）
- 未入库书「目录/章节/封面」加载链路修复（三现象同源，对齐原版 BookInfoViewModel.upBook）：从搜索结果跳转的未入库书进入详情页时，`book_info_screen._loadData` 由「仅查 DB」改为完整链路——在线书 DB 无章节时按 origin 取书源，`webbookInfo` 补全封面/简介/tocUrl/字数（现象③封面缺失），`webbookChapters` 联网取目录用于展示（现象①共 0 章）；未入库时「仅展示不落库」（对齐原版 loadChapter 在 !inBookshelf 时不写 DB），避免污染书架（getBooks=find_all 无 notShelf 过滤）
- 阅读器「章节不存在/未配置书源」修复（现象②）：`_openReader` 对齐原版 readBook——未入库在线书阅读前先 `addBook` 带正确 origin 落库，使 Rust `get_chapter_content_full` 按 book.origin 找书源取正文成立，规避 refresh_toc 兜底插入空 origin 记录导致的第二章及后续报错；已入库则幂等跳过
- 阅读器「翻章后目录被清空 / 章节 N 不存在」根因修复（现象②真因，实机 E2E 定位）：`BookRepository::update` 此前复用 `insert` 的 `INSERT OR REPLACE INTO books`，主键冲突时会先删除旧 books 行再插入，触发 chapters 表 `ON DELETE CASCADE` 级联删除该书全部章节；每次翻章 `_saveProgress → update_reading_progress → repo.update` 都会清空目录，导致下一章「章节不存在」（影响所有在线书，非仅未入库）。改为真正原地 `UPDATE books SET ... WHERE bookUrl=?`（行不存在时退化 insert，保留 upsert 语义且不误触发级联删除），并新增回归测试 `test_update_book_preserves_chapters` 守护；实机验证翻章后 chapters 计数稳定 2598、第三/四章连续阅读正常
- WebBookInfo/WebChapter 为 snake_case（cover_url/toc_url/is_vip），手动映射合并而非 Book.fromJson 直解，避免封面/目录链接丢失
- 发现分类书籍 origin 丢失修复（同源缺陷，端到端验证时发现）：`rust_api.exploreFetchBooks` 返回的 Rust `WebSearchResult` 为 snake_case（book_url/cover_url/source_url，且无 origin/originName），此前直接 `SearchBook.fromJson`（期望 camelCase）会丢失 bookUrl/origin/coverUrl，导致从「发现」进入书详情页的未入库书同样共 0 章、无封面、阅读报「章节不存在」；改为显式归一化（兼容 snake/camel 两种键名）并用本次发现所属书源补齐 origin/originName，使详情页联网补全链路对搜索/发现两个入口一致生效
- 未入库书 notShelf 标记与书架过滤（对齐原版 `BookType.notShelf` / `BookDao.getBooksOnBookshelf`，彻底闭合上一条所述「污染书架」隐患）：新增 `BookType.notShelf`(0x400) / `book_type::NOT_SHELF`(1024) 常量与 `BookRepository::find_all_in_shelf`（`WHERE (type & 1024)=0 ORDER BY "order"`），`list_books` 改走书架过滤查询、`add_book` 改用原地 UPDATE 安全 upsert（避免对已存在临时书触发 INSERT OR REPLACE 级联删章节）；`_openReader` 阅读前落库时打 notShelf 位、`_toggleShelf`「加入书架」时清位转正。相比「详情页离开时清理临时记录」的退路方案，本方案复用既有 type 位标志、书架查询 O(1) 过滤且幂等，并能保留临时书阅读进度/已缓存章节（UX 更优），故择优采用。同步补齐 `update_preserving_read_config` 调用点由 `insert` 改 `update`（原地 UPDATE 三处调用点全覆盖）

### 修复（评审修复：三维评审问题收口，署名 Qoder）
- 搜索结果直达阅读：search_screen 搜索结果点击由弹出仅含「加入书架」的简易 AlertDialog 改为 `Navigator.pushNamed(bookInfo)` 跳转书详情页（对齐原版 SearchActivity→BookInfoActivity），补齐「开始阅读」入口——未入架时开始阅读自动 openBook 直达阅读器，无需先手动加书架；同步删除废弃的 `_showBookDetail`/`_addToBookshelf` 方法及 bookshelf_notifier 冗余引用
- rssUpdateSource 真实接线：`rust_api.updateRssSource` 由误接 `sourceUpdate`（按 BookSource 语义落 book_sources 表，产生幽灵书源脏数据且 RSS 变更静默丢失）改接 `bridge.rssUpdateSource` 原子更新管线，Mock 同步对齐「源不存在时报错」语义（审计缺口④至此全链闭合）
- 书架缓存导出：书架菜单新增缓存章节导出，新增 `BookApi.getCachedChapter` 封装（接通 `cacheGetChapter` FFI）逐章取缓存正文拼接 TXT 经分享通道保存；缓存管理页/epub·pdf/模板等扩展项 TODO(留批次) 登记（台账 §5.9）
- 嗅探委托合并：platform_bridge_service WebView 嗅探改为单一 NavigationDelegate（跳转拦截与加载终态等待共用，不再二次重设委托与二次加载），修复 JS 分支嗅探因委托覆盖必超时问题
- ttsSetCacheDir 初始化接线：`RustApi.init` 内注入应用支持目录 tts_cache（Rust 默认临时目录 Android 可能不可写），失败仅记日志不阻断初始化
- AutoTask 导入 id 碰撞修复：空 id 批量补齐改为基准时间戳拼接循环下标（`${baseId}_$i`），避免同一循环内 microsecondsSinceEpoch 重复导致 id 碰撞
- 日志入口补接：source_edit_screen「日志」菜单接通 AppLogScreen（批次0 遗漏项，日志入口销记口径修正为 7/7，补提交）
- 署名补齐：audio_screen/browser_screen/app.dart 共 3 处注释署名/标记补齐
- 台账口径修正：API_CONTRACT §3 待封装清单销记（登录 V2 三件套/ttsSpeak/cacheGetChapter/rssUpdateSource/ttsSetCacheDir）、审计报告 §7.3 留项修订 + §7.4 P2 处置明细（诚实口径）、UI_FIX_PLAN widget 测试验收口径显式修订、台账 v1.9 + §5.9 TODO(留批次) 登记

### 修复（批次3 P2 收尾：排版细节 + 菜单行为，署名 Qoder）
- 阅读器页面边距：阅读高级配置新增上/下/左/右四向边距滑杆（对标原版 ReadBookConfig paddingTop/Bottom/Left/Right），接入分页缓存键与排版渲染，默认值与历史行为零变化
- 阅读器设置编码：顶栏溢出菜单新增「设置编码」（对标原版 menu_set_charset → showCharsetConfig），写入 book.charset 并重载当前章，本地书乱码可按 UTF-8/GBK/GB18030 等候选重读
- 定时任务页溢出菜单：导入本地（txt/json）/导入线上（URL）/导出（exportAutoTask.json）/帮助，导入经 autoTaskPrepareImported FFI 合并本地运行时状态（对标原版 AutoTaskActivity menu_import_local/import_on_line/export/help）

### 销记（审计 P2 台账核验后无需改动）
- 日志入口 7/7：批次0 已接通 6 处 AppLogScreen（书架/搜索/书详/阅读器/听书/关于），source_edit_screen（书源编辑）为批次0 遗漏项随本次评审修复补接（补提交），销记
- 字距/段距/首行缩进/两端对齐：v2.0.2 已接入排版引擎，销记
- 书源导入排序：排序已应用于显示列表且导入后 reload 保持当前排序（原版 ImportBookSourceDialog 亦无排序 UI），判定对齐，销记

## [2.0.2] - 2026-08-06

### 修复（批次2 组A 阅读器系，署名 Qoder）
- 阅读器顶栏菜单补齐 10 项：重新加载当前章正文（替换规则开关重新分段）、同步已持久化书对象到 State 等，对齐原版 ReadBookActivity 菜单
- 阅读器源操作：批量换源链路接通（对标 Kotlin changeSource）
- 阅读配置 5 项：字体选择/字距调节/首行缩进/两端对齐（MoreConfig textFullJustify）接入排版参数与分页渲染，对标原版 ReadBookConfig
- 离线缓存：阅读器离线下载配置项接通（待 Rust 侧缓存体系补齐）
- 朗读控制条完善：read_aloud_bar 定时/目录/章节跳转等控制项补齐，阅读器底栏朗读入口接线 AudioNotifier.startReadAloud

### 修复（批次2 组B 书架书详，署名 Qoder）
- 书架菜单 7 项：更新目录接真实 refreshToc FFI、添加网址接 WebBook 入库（对标 addBookByUrl）、导入/导出书单对齐 Kotlin importBookshelf/exportBookshelf（url/json/文件三通道）等
- 书详页：登录接通书源登录链路（V2 动态协议+旧版凭据页）、置顶接 topBook FFI、清缓存接 clearCache FFI、批量换源入口（对标 changeSource）
- 书架管理页：批量置顶/置底（对标原版 + replace_rule_sel.xml menu_top_sel/menu_bottom_sel），重排后逐条持久化

### 修复（批次2 组C RSS·规则·换源·听书·设置+结构治理，署名 Qoder）
- RSS：文章列表菜单（登录/刷新/排序/设置源变量/编辑源/切换布局，对标 rss_articles.xml）、双列网格布局切换本地态（articleStyle 0-4）、详情收藏接 addRssStar/deleteRssStar/isStarred FFI（对标 RssFavoritesDialog）、阅读记录对话框（对标 ReadRecordDialog）、rssMarkRead 已读标记
- 替换规则：分组筛选（menu_group：全部/启用/禁用/无分组/分组:x）、批量模式（启用/禁用选中/置顶/置底/导出选中，对标 replace_rule_sel.xml）、网络/二维码导入接通确认页、新规则 pattern 预填
- 换源页：高级选项（搜索筛选/停止刷新切换/书源管理入口/刷新列表/校验作者开关/加载字数开关，对标 change_source.xml）+ 搜索筛选（对标 menu_screen SearchView）
- 听书页：溢出菜单 7 动作（换源/登录/复制播放地址/缓存目录选择/缓存范围/清当前章缓存等，对标 audio_play.xml）
- 设置页：登录/置顶/清缓存等入口接线
- 结构治理：删除 rss_config_screen.dart 及 rssConfig 路由（原版无此页，订阅源管理统一走 rssSourceManage）

### 修复（批次2 跨轨管线：WebView 拦截 + TTS 接线，署名 Qoder）
- WebView 桥接拦截：新建 platform_bridge_service.dart 统一承接 Rust 侧 7 个平台桥接 API（webView/webViewGetSource/webViewGetOverrideUrl/showBrowser/startBrowser/openUrl/openVideoPlayer）结构化 JSON 桥载荷；rust_api.dart 11 处拦截接入，browser_screen/routes/app.dart 联动打开真实 WebView/浏览器（Task #114）
- audioSpeak 接 ttsSpeak 真实管线：rust_api.dart audioSpeak 由 http.get 探活改接 bridge.ttsSpeak（模板替换+MD5 文件缓存+Content-Type 校验由 Rust 侧完成），异常降级探活保留 audio_notifier 既有保护（契约 §2.42，缺口②闭合，署名 QoderCN）
- 搜索内容页：支持阅读器长按选中文本作为初始查询词预填+自动搜索（对标 searchContentQuery）

## [2.0.1] - 2026-08-06

### 修复（批次0 纯接线快赢）
- 阅读器翻页动画入口：reader_top_bar 翻页动画菜单接 ReaderSettingsSheet（对标原版 ReadStyleDialog）
- 日志入口接线：书架/搜索/书详/书源编辑/阅读器菜单的「日志」项接通 AppLogScreen（对标原版 menu_log → AppLogDialog）
- 朗读配置页入口：听书页 TTS 设置面板新增「朗读引擎」入口，接通孤儿页 ReadAloudConfigScreen（对标原版 pref_aloud）
- 替换规则导入：replace_rules_screen 新增导入菜单，本地文件导入接通 ReplaceRuleImportConfirmScreen；网络/二维码导入缺导入 service，留批次2

### 修复（批次1 P0 长按选择 + 朗读链路）
- 阅读器正文长按选择：新增段落选区面板（SelectText 精细选区），接通复制/书签/高亮（5色）/词典/浏览器/分享，操作菜单对齐原版 content_select_action 顺序（审计 P0-1，署名 Qoder）
- 阅读器朗读链路：底栏朗读按钮接通朗读启动/播放暂停切换，新增朗读控制条（章节切换/语速 0.5-3.0x/目录/朗读设置/转后台），对标原版 ReadAloud 控制项（审计 P0-2，真实 TTS 管线待批次2，署名 Qoder）

### 新增（2026-07-31 重构遗留任务收尾）
- 排版引擎渲染侧整合（Task #34）：paragraph_layout_engine 接入 reader_screen，屏级分页 + 中文避头尾 + 两端对齐，847+ 测试通过
- 听书后台媒体按钮（Task #17）：MediaSession 通道注册 + AudioProvider 接线，锁屏/通知栏媒体控制 + 音频焦点管理，22/22 测试
- 发现页 exploreUrl 分类（Task #30）：新增 explore_show_screen + Rust explore_api，分类展开/翻页加载/搜索防抖，Rust 6+4 测试
- 压缩包导入 + 编码检测（Task #31）：archive_import_dialog 支持 zip/rar/7z 解压导入 + TXT 自动编码检测 + 手动编码选择 UI
- audio/auto_task FFI（Task #19 注册 + Task #32 接入）：legado-ffi 新增 9+2 个 FFI 方法，Flutter 侧完成接入
- QUIC 主网络链路（Task #43）：client.rs 集成可选 QUIC/HTTP3 + 失败自动 fallback HTTP/2，配置开关默认关闭，net 188 + ffi 79 测试
- M3 主题系统集中化（Task #39）：独立 app_theme.dart + app_typography.dart，light/dark 双 ColorScheme（用户确认 M3 方向）
- 响应式网格布局（Task #35）：bookshelf/rss/explore 改用 MaxCrossAxisExtent 自适应列数 + responsive.dart 断点工具
- SafeArea 安全边距（Task #36）：home_screen 导航栏与主体补充 SafeArea

### 修复（2026-07-31 UI 一致性）
- 长按多选精确化（Task #37）：长按多选限定封面区域，标题区域排除误触
- 全局 ScrollBehavior 统一（Task #38）：统一滚动物理，各列表手感一致
- Dark Mode 完整校验（Task #41）：42 个 screen 暗色对比度（WCAG ≥ 4.5）与图标可见性核验

### 优化（2026-07-31 性能与质量）
- 性能优化（Task #40）：cached_network_image 双缓存 + RepaintBoundary/稳定 Key/const 构造 + dispose 资源释放审计 + 冷启动/滚动 FPS/翻页性能基线
- 测试覆盖率（Task #33）：新增 +148 测试，Providers 层覆盖率达 72.4%，总计 855 测试全部通过

### 新增
- Tab 自定义图标：8 个安卓原版 SVG 图标（选中/未选中各 4 个）+ flutter_svg 集成 + home_screen.dart 导航栏替换
- 书架自定义刷新组件：custom_refresh_indicator.dart，对齐安卓下拉刷新动画
- 搜索分组筛选：分组/书源双 Tab 筛选面板，对齐安卓 SearchScopeDialog
- 导出路径选择与入口：FilePicker 路径选择 + book_info_screen/bookshelf_screen 双入口集成
- 崩溃防护体系：CrashLogService 全局错误捕获、runZonedGuarded 异步兖底、启动崩溃日志检测弹窗
- 崩溃日志弹窗组件，支持查看详情和清除日志

### 修复
- 阻塞修复：bookshelf_screen.dart dynamic 调用修复、reader_provider.dart 异步空安全、reader_screen.dart PageController hasClients 守卫
- 翻页动画参数对齐：300ms + linear，与安卓 PageDelegate 一致
- RSS 界面样式对齐：4 列网格 + 50x50 圆角图标居中
- 搜索框样式对齐：35dp 胶囊 + 半透明填充 + 0.5dp 描边
- 发现页样式对齐：AppBar 内嵌搜索框 + 扁平列表项

### 变更
- 路由参数规范化：bookInfo/changeSource/audio/searchContent/changeCover/export 6 个路由支持 Book 对象传递
- ExportDialog 参数从 bookId 改为 Book 对象，支持完整书籍信息导出

### 优化
- main.dart 启动流程：SharedPreferences 与 Rust FFI 并行初始化
- HomeScreen Tab 懒构建，减少首帧构建开销
- SettingsService/CacheService 全部方法添加异常保护
- BookshelfProvider/ReaderProvider loadSettings 下沉到首帧回调
- 添加启动阶段 Stopwatch 计时调试日志
- 移除章节预热缓存功能（`_prewarmChapterContent`），保持与 Android 原版一致

## [Unreleased]

### Added
- **JsExtensions 完整实现**：40+ 宿主 API（加密/编码/字符串/正则/JSON/文件/时间/网络/变量/Cookie），java 命名空间绑定，QuickJS 统一注册框架
- **服务端功能扩展**：书源调试 API（会话管理 + 步骤跟踪）、朗读引擎 API（状态机 + 段落分割）、书源规则更新 API、MCP Server（JSON-RPC 2.0 + 12 个 AI 工具）、目录更新 API
- **章节预加载状态机**：三章滑动窗口 + Semaphore 有界并发 + LRU 内存缓存 + 失败熔断器
- **音频预加载优化**：有界 LRU 淘汰 + 磁盘持久化 + 流式分块加载
- **自动任务执行层**：cron 调度策略 + 脚本执行 + 导入/导出 + REST 全 CRUD 7 端点
- **下载管理器**：优先级队列 + 并发池(3) + 暂停/恢复 + REST 5 端点
- **解压缩宿主 API**：zip 完整实现 + 7z/rar 桩化，java 命名空间双挂载
- **CacheManager + SourceLock + RuleComplete**：KV 缓存 + deadline 过期、singleFlight 并发控制、JSOUP/XPath 规则自动补全
- **数据库全覆盖**：25/25 表 Repository 100% 覆盖（新增 search_keywords/cookies/rssArticles/rssReadRecords/rssStars/txtTocRules 等 6 张表）
- **WebSocket 实时通道**：搜索进度推送 + 书源/RSS 调试日志流，5 个 WS 端点
- **DefaultData + Cron 解析**：JSON 默认数据导入 + 5/6 段 cron 表达式解析
- **ContentHelp 段落重排**：完整移植 Kotlin ContentHelp.kt（630 行）至 Rust
- **FFI 大规模扩展**：103+ FFI 导出函数，新增书签/替换规则/在线阅读/换源/AutoTask/RSS收藏/搜索历史/阅读记录/书籍分组/统计/缓存/配置/HTTP TTS/音频进度/Backup/Server/User/WebDAV/Download/Review 等 API
- **Flutter UI 完善**：40 个屏幕（+14）、10 个可复用组件、78 个新 Provider 测试、APK 构建 + 模拟器安装验证通过
- **MCP Server 12 工具接入真实数据库**：search_books/get_chapters/read_chapter/list_sources 等全部接入真实查询
- **用户管理**：users 表 + UserRepository + FFI 6 函数
- **本地 TXT 分词搜索**：TxtSearch 引擎（纯文本/正则 + 章节感知 + 上下文摘要 + 结果数限制）+ FFI 4 函数 + 18 个测试
- **阅读记录 + 书籍分组**：ReadRecordRepository + BookGroupRepository 完整 CRUD
- **HTTP TTS**：http_tts 表 + Repository + FFI 5 函数
- Multi-Agent parallel development scheme (5 roles)
- Module ownership matrix and branch protocol
- WebDAV sync FFI API (6 functions)
- Download Manager FFI API (8 functions)
- Review/paragraph comment FFI API (4 functions) + Flutter dialog
- Simulation page flip animation (ported from Kotlin SimulationPageDelegate.kt bezier algorithm)
- RSS article WebView rendering with JS execution and plain-text fallback
- Source editor rule validation (webbook search/info/chapters/content) and debug log enhancement
- Audio player timer/stop countdown with preset duration selector
- Video player screen with playback controls and fullscreen
- Comic reader screen with vertical scroll, pinch zoom, and image preloading
- CI auto-release workflow (flutter-release.yml)
- 16 new Flutter widget tests (page flip + paragraph comment)

### Changed
- **2026-07-29 源码深度审计**：整体迁移完成度修正为 ~80%（Rust ~85%，Flutter UI ~78%），识别 P0 缺口：排版引擎/导出UI/缓存管理
- **网络栈统一**：从独立 ureq 迁移至 LegadoClient，复用连接池、中间件、重试策略
- **引擎池化增强**：SharedScopeManager LRU 缓存 + 超时中断保护
- **flutter_rust_bridge codegen**：53 → 103+ Dart bindings，rust_api.dart 全量重写为真实 FFI 调用
- **Mutex 安全**：49 处 unwrap() 替换为 unwrap_or_else（毒性恢复，避免 panic 级联）
- **Backup 扩展**：备份范围新增 bookSources、rssSources、readRecords
- Agent configs specialized with role-specific prompts
- rust-ci.yml: exclude legado-ffi from workspace checks
- flutter-ci.yml: pin Flutter 3.41.7, add test step
- All workflows: upgrade actions/checkout to v7

### Fixed
- **java 命名空间核心修复**：`java.get()`/`java.post()`/`java.getStr()` 等关键方法可用
- **QuickJS 超时中断**：从相对时间修复为绝对 deadline
- **AnalyzeRule @js: 规则执行**：JsExecutor trait 注入模式解决跨 crate 循环依赖
- **EPUB 封面提取**：3 级 fallback 策略（cover meta → OPF item → 首图片）
- **MOBI 完善**：EXTH 元数据解析 + KF8 检测 + 错误处理增强
- **WebBook 真实链路**：AnalyzeUrl 模板解析 + LegadoClient HTTP + AnalyzeRule 规则解析，搜索→详情→目录→正文全流程
- **Flutter UI 修复**：clearCache 接入 RustApi、主题导入实现、SharedPreferences TODO 清理
- **FFI UnimplementedError 清零**：Flutter rust_api.dart 全部替换为真实实现
- Rust CI failure: legado-ffi needs Flutter/Dart toolchain not available in Rust CI
- Flutter CI failure: unspecified Flutter version didn't satisfy `sdk: ^3.11.5`
- Node.js 20 deprecation warnings in GitHub Actions
- Clippy redundant_closure warning in bridge.rs ffi_user_get_all

## [2.0.0] - 2026-07-26

### Added
- **Rust Core Engine**: Complete Rust workspace with 8 crates (core, parser, net, js, book, db, ffi, server)
- **Flutter UI**: 18 screens, 12 providers, cross-platform Material3 design
- **QuickJS Engine**: Real QuickJS runtime with 70+ host APIs, sandbox security, engine pooling
- **Rule Parser**: RuleAnalyzer with JSoup/XPath/JsonPath/Regex parsers + @js: mode
- **Network Layer**: LegadoClient with retry/rate-limit/proxy/UA rotation/SSL middleware
- **Book Parsers**: EPUB/TXT/MOBI/PDF/UMD format support + TXT/EPUB/HTML export
- **Database**: SQLite Schema v95, Room migration (v90-v95), 7 repositories
- **HTTP Server**: axum-based REST API with 25+ endpoints + Web SPA frontend
- **FFI Bridge**: flutter_rust_bridge v2.12.0 with 30+ export functions
- **Multimedia**: Audio playback with preload optimization, TTS integration
- **Reading Engine**: Chapter preloading state machine with LRU cache and failure circuit breaker
- **Security**: File API sandbox with path traversal protection
- **Cloud Sync**: WebDAV client for book data synchronization
- **i18n**: Chinese/English dual language support
- **CI/CD**: GitHub Actions workflows for Rust and Flutter
- **Build Scripts**: Windows one-click build (PowerShell + BAT)

### Changed
- Migrated from Android Kotlin to Rust core + Flutter UI architecture
- Network stack unified from ureq to LegadoClient (connection pooling, middleware chain)
- JS engine upgraded from stub to real QuickJS runtime with engine pooling

### Fixed
- QuickJS timeout interrupt (was using relative time instead of absolute deadline)
- Java namespace for book source JS scripts (java.xxx() calling convention)
- File API path traversal vulnerability (added sandbox validation)
- HostApiRegistry dead code removed (150 lines of empty TODOs)

## [1.0.0] - Legacy

### Description
- Original Android Kotlin implementation (io.legado.app)
- 329 releases tracked via git tags (3.YYMMDDHH format)
- Full-featured Android reading app with 60+ Kotlin models, 20+ services
