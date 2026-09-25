# 阶段 3 结论：离线干跑（引擎真实执行，全语料 916 源）

> 执行入口：`rust/legado-ffi/tests/capability_sweep.rs::test_offline_dry_run_sweep`（`#[ignore]`，需 `-- --ignored`）。
> 运行命令：`cargo test -p legado-ffi --features quickjs --test capability_sweep -- --ignored`
> 产物：`dry_run_report.md`（人类可读）、`dry_run_details.json`（916 行 per_source，已验证 JSON 合法）、`dry_run_stdout.log`。

## 1. 运行条件

- 引擎：与生产同源的 `QuickJsEngine`（`allow_script_run=true`、64MB 内存、5s/eval 超时）。
- 离线保证：setup 之后注入 `NETWORK_PATCH_JS`，把所有宿主网络/浏览器/睡眠函数替换为记录器（调用计入 `globalThis.__netCalls`），`threadSleep` 置空。全程零真实联网。
- 隔离：每源独立线程（4 路并发池 + join 捕获），panic → d 类；线程创建失败亦 → d 类。
- 执行范围（按任务规格）：每源 **jsLib + searchUrl 的 `<js>`/`@js:` 块**（每源最多 8 块）。exploreUrl / loginUrl / 各 rule 字段**不执行**。
- 模板变量按 Legado 语义预置：`var key="测试"; var page=1; var result=<上块返回值>`，`{{key}}/{{page}}` 块内由 prologue 变量承接。
- 本轮实测总耗时 **1.63s**（4 并发；单源 3–36ms，QuickJS 快于预期，已抽验合理性）。

## 2. 分类统计（最终数字，来自 dry_run_details.json）

| 类别 | 定义 | 源数 | 占比 |
|---|---|---|---|
| ok-离线可跑 | jsLib+searchUrl 全执行成功且无网络调用 | **856** | 93.5% |
| c-需网络/登录（离线不可判） | net_calls>0，或报错文案明确要求登录 | **48** | 5.2% |
| b-JS错误 | 引擎内 JS 语法/引用/语义错误（非能力缺失、非网络） | **12** | 1.3% |
| a-缺失 Java 能力 | 台账（unknown_java_symbols）命中或友好报错文案命中 | **0** | 0% |
| d-引擎内部错误 | 线程 panic / 引擎崩溃 | **0** | 0% |

`missing_ranking: []`（a 类为空，见 §3 解释）。**d=0：916 源无一 panic/崩溃——最高优先项「引擎内部错误」清零。**

## 3. 为什么 a=0（与静态对账缺失榜不矛盾）

1. **执行范围差异**：静态对账扫描的是全部 7 类字段（rule 字段 JS 共 1.6 万+ 片段）；干跑只执行 jsLib+searchUrl。静态缺失榜的头部符号（`java.searchBook` 5 源→exploreUrl；`cache.getFromMemory/putMemory` 4 源→jsLib #36 的惰性分支；`cookie.getKey` 4 源→explore/loginUrl；`java.open` 3 源）大多落在未执行字段或未触达的分支里。
2. **裸 `java.*` 未知成员不走台账**：生产引擎中仅 `Packages.*` 未知叶子（trapNode→reportUnknownSymbol）与 `Java.type`/`importClass` 会写台账；裸 `java.xxx` 未注册成员只是 `undefined`，运行时表现为 "not a function" → 被归入 b 类。所以 a 类排行天然窄，**完整缺口面以静态榜（report_02 / static_report.md）为准**。

## 4. b 类 12 源逐一定因（全部是引擎侧兼容性问题，无 JVM 类）

| 根因簇 | 源（# 名） | 错误签名 | 说明 |
|---|---|---|---|
| **jsLib 远程库加载器未实现**（4 源） | #463 月色书屋、#658 情言小说、#674 闪爵小说、#915 漫画1 | `expecting ';' (at eval_script:1:1)` | jsLib 为 `{"crypto":"https://cdn.bootcss.com/crypto-js/3.1.9-1/crypto-js.min.js"}` 远程引用格式，引擎直接把 JSON 当脚本 parse。#463/#658/#674 记 b；**#915 因 net=1 被 c 规则双计**（实际同簇） |
| **QuickJS vs Rhino 严格度：重复形参名**（3 源） | #26 书旗、#324 长佩、#583 哔哩哔哩 | `invalid redefinition of parameter name` | Rhino 容忍重复形参，QuickJS 按 ES 语义拒绝。修向：QuickJS 侧放宽或预处理 |
| **JavaImporter（Rhino 专有全局）**（2 源） | #135 阅文集团、#634 得间免费小说 | `JavaImporter is not defined` | Java 导入器语义，属 JVM 互操作 |
| **混淆 jsLib 与 QuickJS 不兼容**（2 源） | #626 📂69书吧-H、#888 69書吧 | `not a function (at bind (native) at _0xeab7ca ...)` | 39KB obfuscator.io 风格产物：XOR 字符串数组解码器 + 1014 处 `\u00XX` 转义 + 自防御包装（尾部 `Object.defineProperty.bind(Object), Object.getOwnPropertyDescriptor.bind(Object)`）；`buildRequest` 仅由解码后的混淆名在运行时定义，源码中 0 处 `java.*`/`Packages.*` 引用 → 非 Java 能力缺口，疑似混淆包装内 QuickJS↔V8 语义差异，需落地反混淆复现 |
| **我方 prologue 变量与源内声明冲突**（2 源） | #702 乐乎文章（优）：`redeclaration of 'baseUrl'`；#850 爱巴士：`invalid redefinition of global identifier` | 见左 | 干跑 prologue 预置 `var key/baseUrl/...`，与源内 `let baseUrl` / `let key` 冲突。#850 另用裸 `org.jsoup.Jsoup.parse(java.ajax(...))`——裸 `org` 全局生产已提供（quickjs_impl.rs:912-915），冲突修掉后即可解析。属**清扫入口自身**可修（prologue 改 `if(!(x in globalThis))` 守卫式声明） |

## 5. c 类 48 源说明

- 47 源 `net_calls≥1`：执行到真实网络阶段，记录器返回空响应 → 下游解析必然报错（"not a function"/"cannot read property 'join' of null"/"Error converting from js 'null' into type 'string'" 等）。**这些 c 类内的 JS 报错文案是打桩副作用，不是 b 类缺陷**，离线不可判，需在线回归才能定论。
- 登录型 1 源：#36 微信读书二合一本地源（net=0，报错文案「缺少 APP 登录参数。请先点击游客登录或微信扫码登录…」→ 按文案归 c）。
- 其它特例：#170/#619 七猫四合一本地版「七猫接口返回空响应」（本地壳 + 远端 API，空响应即离线不可判）；#405 独阅读网「Error converting from js 'String' into type 'SymmetricCrypto': Empty B...」（需登录密钥）。
- 完整 48 源清单见 `dry_run_report.md`（前 20 示例）与 `dry_run_details.json`。

## 6. 与静态对账的交叉结论

- 干跑 93.5% 直接通过 + 5.2% 纯网络依赖 → 引擎对「普通 URL/JS 源」的可用性已被实证。
- 静态缺失榜（`java.searchBook` 5 / `cache.getFromMemory` 4 / `cache.putMemory` 4 / `cookie.getKey` 4 / `java.open` 3 / 其余 1–2 源各若干）= 真正待分诊的缺口面，见 report_02_static.md 与 static_report.md。
- 已知限制（后续可选项）：干跑范围若扩到 exploreUrl/loginUrl/rule 字段（需补对应离线桩与求值上下文），a 类排行才会非空；本轮按规格未扩。
