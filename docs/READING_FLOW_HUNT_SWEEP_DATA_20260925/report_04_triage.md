# 阶段 4：分诊建议（仅建议，不实施）

输入：静态缺失榜（static_report.md，命名空间修正后）+ 干跑 b 类 12 源定因（report_03）+ 能力面清单（capability_names.txt，164 项）。
约定：工作量 S=半天内 / M=2–5 天 / L=1 周+；风险按对引擎全局语义的影响评估。

## 1. Top-10 分诊（按救活源数降序，同数按可行性）

| # | 项（符号/根因） | 救活源数 | 可行性 | 工作量 | 风险 | 分诊 |
|---|---|---|---|---|---|---|
| 1 | `java.searchBook(key, source)`（exploreUrl #7/#15/#25/#40 UI 按钮动作 + jsLib #583） | 5 | 中：宿主回调重入搜索管线；原 Legado 同源 API（UI 脚本触发指定源搜索） | M | 中（重入引擎调用：超时/栈/并发需隔离） | 做（排在有 UI 宿主回调基建之后） |
| 2 | `cookie.getKey`（#94/#147 exploreUrl、#135/#583 loginUrl） | 4 | 高：小宿主函数（cookie 容器取 key） | S | 低 | 做（与 #3 同批） |
| 3 | `cache.getFromMemory` / `cache.putMemory` / `cache.deleteMemory`（#36 为主，4+4+2） | 4 | 高：进程内内存缓存宿主函数（HashMap 即可，与现有 cache 文件后端分离） | S | 低 | 做 |
| 4 | jsLib 远程库加载器（#463/#658/#674/#915，jsLib 为 `{"crypto":"https://cdn.bootcss.com/crypto-js/…"}`） | 4 | 高：解析 JSON 远程引用形式 → 拉取脚本文本（带缓存）→ eval；生产环境有网 | S–M | 低（独立路径，不影响现有 jsLib 执行） | 做（离线干跑不可复验，上线后回归） |
| 5 | QuickJS 重复形参名宽容度（#26 书旗/#324 长佩/#583 哔哩哔哩，`invalid redefinition of parameter name`） | 3 | 中：两条路——引擎级放宽（QuickJS 选项或预处理重命名重复形参） | M | 中（全局引擎语义变更 / 正则预处理有误伤面，需全量回归） | 做（先出 POC 验证放宽路径） |
| 6 | `java.open(type, url?, title?)`（#20/#302/#583 ruleContent UI 脚本：`java.open("login")` / `java.open("explore", u, 标题)`） | 3 | 中：宿主 UI 桥接（打开登录/探索页）；Web 端需定义等价行为（路由跳转） | M | 低–中 | 做（依赖 UI 桥接基建） |
| 7 | 清扫 prologue 变量冲突（#702 `redeclaration of 'baseUrl'`、#850 `invalid redefinition of global identifier`） | 2 | 高：prologue 改守卫式属性赋值（`if (typeof x==='undefined') globalThis.x=…`），不动源脚本 | S | 低 | 做（清扫入口/引擎 setup 各一处，需与生产 setup 同步） |
| 8 | 混淆 jsLib QuickJS 兼容（#626/#888，obfuscator.io 风格：XOR 字符串数组 + `\u00XX` 转义 + 自防御包装，`not a function (at bind (native))`） | 2 | 中：需反混淆定位不兼容点（QuickJS↔V8 语义差），再修引擎或预转译 | M | 中（引擎级修复波及面需全量回归） | 做（P2；两源同一家族，先反混淆复现） |
| 9 | `Packages.okhttp3`（3 源） | 3 | 低：为引擎引入第二套 HTTP 客户端栈不值得 | — | — | **不做（引擎侧）→ 源侧迁移**：等价能力已由 `java.*` 网络函数覆盖，给源作者迁移指引 |
| 10 | `JavaImporter`（#135 阅文/#634 得间，Rhino 专有 JVM 互操作全局） | 2 | 低：无 JVM，类加载/导入器语义不可移植 | — | — | **确认不做** |

### 附：小工具批（各 1 源，纯 Rust 计算类，建议一批放出，合计约 12–15 源可救活）

`java.HMacBase64` / `java.tripleDESEncodeBase64Str`（#135 阅文）· `java.base64Decoder`（#顾淮）· `java.hexEncodeToString`（#长佩）· `cookie.mapToCookie` / `cookie.replaceCookie` / `cookie.split`（#爱丽丝书屋）· `cache.dev_id` · `java.headerMap.put`（#刚够）· `java.openWeb`（#42 黄豆短剧）· `java.showPhoto` · `java.sleep` · `java.url` · `Packages.android.text.TextUtils.isEmpty`（1）
可行性：高（Rust `crypto`/`base64`/`hex` 直接映射，语义无歧义）；工作量：S（整批 1–2 天）；风险：低（纯新增宿主函数，不改既有行为）。
例外：`Packages.android.graphics.BitmapFactory`（1–2 源）单列——需图像解码管线，**一期不做**，按需再评。

## 2. 「确认不做」清单（JVM/系统依赖，统一口径）

| 项 | 源 | 理由 |
|---|---|---|
| `JavaImporter` / `Java.type` 风格 JVM 互操作 | #135、#634 | 引擎无 JVM；类加载、导入器、反射语义不可移植。`Java.type` 保持现状（受控：记台账 + 友好报错） |
| `Packages.okhttp3`（OkHttpClient/Request 等） | 3 源 | 不引入第二套 HTTP 栈；`java.*` 网络函数已覆盖等价能力 → 源侧迁移 |
| `com.kmxs.reader` / `com.*` 本地 App 包 | 2 源 | 仅在特定本地阅读器 App 内有效（App 内置 JS 桥），Web/桌面引擎场景外 |
| `Packages.android.graphics.BitmapFactory` 等 Android 图像 API | 1–2 源 | 无 Web 端等价需求，成本收益差 |
| 本地 App / 系统环境依赖源（c 类 48 源中的本地壳源，如 #36 微信读书二合一本地源） | 若干 | 离线不可判，需在线回归 + 登录态，超出本引擎能力对账范围 |

## 3. 汇总预估

- 全部「做」项落地后，可救活 ≈ 5+4+4+4+3+3+2+2 + 小工具批 12–15 ≈ **39–42 源**（占语料 4.3–4.6%）。
- 干跑已实证 856 源（93.5%）离线即可跑通 + 48 源纯网络依赖（在线即可用）→ 引擎现成可用性 98.8%；本分诊针对剩余长尾。
