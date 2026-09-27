# 组A调研交叉核验报告：4 篇旧计划文档未结项（2026-09-27）

> 性质：只读调研报告。所有断言附精确证据（路径:行号 或 commit hash）；推测/待验证项明确标注。
> 核验基准：工作区当前版本（非 `git show HEAD`）。所有 commit 均核验为 HEAD 祖先（`git merge-base --is-ancestor`）。
> 基准文档：`docs/REFACTORING_ACTIVE_PLAN.md`（唯一任务队列）、`docs/REFACTORING_WORKFLOW.md`、`docs/REFACTORING_ROADMAP_PROPOSAL_20260927.md`。
> Active 现最大编号：P2-22 / P3-7（`REFACTORING_ACTIVE_PLAN.md` grep 结果）；新编号自 P2-23 / P3-8 起。

## 一、docs/AUDIT_FIX_ASSIGNMENT.md（131 行，2026-08-05）

### 文档概述
审计修复第一/二/三批任务分配与完成报告。本身不含独立不可丢失证据（修复细节均在提交信息与源码；§2/§5 已列提交 `5603677fd`/`6a7a68b5a`/`160affb0d`/`a62de97af`）。L4 引用 `PROJECT_AUDIT_REPORT.md`（链接现指向 `过期文档/`，文件实际存在，见下表）。

### 未结项交叉核验表
| 原文档 | 条目（原文编号/标题） | 原文状态 | 当前证据（commit hash / 文件:行 / Active编号 / CI） | 结论 | 处置建议 |
|---|---|---|---|---|---|
| AUDIT_FIX_ASSIGNMENT.md | §1.1 书源校验 FFI 链路（L61） | ⛳ 继续延后 | commit `08e731957e`（2026-08-05，HEAD 祖先）「[UI] 接入 Rust 四项交付：书源校验页（关键词弹窗/流式进度模板/失败…」；`rust/legado-ffi/src/api/source_check_api.rs` 存在（505 行，checkSource FFI） | 已完成收口 | 随源文档归档 |
| AUDIT_FIX_ASSIGNMENT.md | §2.1 验证码输入页 / 规则订阅页（L63） | ⛳ 待排期 | `flutter_legado/lib/src/widgets/verification_code_listener.dart`（256 行）、`lib/src/models/rule_sub.dart`（137 行）、`lib/src/providers/rule_sub/rule_sub_notifier.dart`（161 行）、`lib/src/screens/rule_sub_screen.dart`（778 行）均存在；commit `961a2d353`（2026-08-22，HEAD 祖先）「feat(ui): 规则订阅管理页入口接入书源管理菜单」 | 已完成收口 | 随源文档归档 |
| AUDIT_FIX_ASSIGNMENT.md | §1.4 MOBI HUFF/CDIC+KF8（L66） | ⛳ 待排期 | `rust/legado-book/src/mobi.rs` 存在（2611 行）；commit `d994a4fdbb`（2026-08-05，HEAD 祖先）「[Rust] MOBI 解析补全：HUFF/CDIC + INDX/TAGX + KF8(AZW3) + NCX/封面」 | 已完成收口 | 随源文档归档 |
| AUDIT_FIX_ASSIGNMENT.md | L4 依据链接 PROJECT_AUDIT_REPORT.md | 引用（编写时路径已失效，后修正） | L4 现指向 `过期文档/PROJECT_AUDIT_REPORT.md`，文件实际存在（222 行，197608 字节） | 已失效或被现行规范取代（报告已归档、链接已有效） | 保留为历史参考（证据类型＝审计报告归档路径） |

补充：§2.1 验证码相关的**实网验收项**为 V1（`RESIDUAL_RISKS_2026-08-13.md` L97 ⛔ 待用户素材，Active P2-4 已登记），属验收矩阵而非本文档条目；本文档「验证码输入页/规则订阅页」UI 链路条目本身已收口。

## 二、docs/IOS_TRACK_FEASIBILITY_20260830.md（123 行，2026-08-30）

### 文档概述
iOS 轨可行性勘察 + P0–P3 实施计划（2026-08-30 用户授权立项，超出原版 Android 范围的新平台工程）。**含独立不可丢失证据**：§二 签名与安装方式矩阵（L43-55，含企业 In-House $299/年高风险结论）、§三 Android 缺口→iOS 插件对照表（L57-75，12 行）、§六 平台限制（L114-121）。归档须保留这些章节全文，不得摘取。

### 未结项交叉核验表
| 原文档 | 条目（原文编号/标题） | 原文状态 | 当前证据（commit hash / 文件:行 / Active编号 / CI） | 结论 | 处置建议 |
|---|---|---|---|---|---|
| IOS_TRACK_FEASIBILITY_20260830.md | §五 P1 FFI 接线 + CI 首包（L94-99） | 计划（里程碑：模拟器跑起来） | Active L486「iOS 轨 P1 里程碑达成：ios-build 工作流全绿，未签名 ipa artifact 产出，iOS 模拟器启动到书架（截图证据），Rust FFI 静态链接实测工作」；`.github/workflows/ios-build.yml` L17 macos-15、L99 `flutter build ios --release --no-codesign`、L314-330 app-unsigned.ipa artifact | 已完成收口 | 随源文档归档 |
| IOS_TRACK_FEASIBILITY_20260830.md | §五 P2 原生功能补齐（L101-107，含 L71/L105 自动任务 iOS 降级 workmanager） | 计划（2-4 天） | Active L485（P2-A 完成：TTS/通知/亮度/设备号/深链五通道插件化）/ L484（P2-B 完成：登录 Cookie 捕获 + 后台听书基础）/ L483（P2-C 完成：NowPlayingBridge.swift 锁屏控制；「P2 剩自动任务降级与真机走查」） | P2-A/B/C 已完成收口；P2 剩「自动任务降级 + 真机走查」仍有效 | 迁入 Active：建议编号 **P2-23**「iOS 自动任务降级（workmanager/前台定时）+ 真机走查」 |
| IOS_TRACK_FEASIBILITY_20260830.md | §五 P3 三端收敛（L109-112） | 计划（2-3 天，里程碑：三端同一套代码可构建） | Active L483「P3 三端收敛待启动」（2026-08-31 修订记录，当前 HEAD 未变） | 仍有效 | 迁入 Active：建议编号 **P3-8**「iOS 三端收敛（Windows 基线固化 / macos·linux FFI 接线 / CI 三产物矩阵）」 |
| IOS_TRACK_FEASIBILITY_20260830.md | §二 签名矩阵（L43-55） | 勘察证据（非任务项） | 企业签已出局：现行 CI 仅产出未签名 ipa（`ios-build.yml` L99 `--no-codesign`），仓库无企业/ad-hoc 签名配置 | 保留为历史参考（证据类型＝勘察结论表，不可丢失） | 随源文档归档时保留（L43-55 全文） |
| IOS_TRACK_FEASIBILITY_20260830.md | §三 插件对照表（L57-75） | 勘察证据 | P2-A/B/C 已插件化落地（Active L483-485）；表中 12 行仅自动任务 workmanager 降级行（L71）未做 | 保留为历史参考（证据类型＝对照表） | 随源文档归档时保留（L57-75 全文） |
| IOS_TRACK_FEASIBILITY_20260830.md | §六 风险与边界（L114-121） | 勘察证据 | 「无 macOS 本机、全迭代走 Actions」等约束仍成立（CI 现状未变） | 保留为历史参考 | 随源文档归档时保留（L114-121 全文） |

## 三、docs/PARSER_GAP_FIX_PROGRESS_20260815.md（287 行，2026-08-15~08-20）

### 文档概述
G1-G15 解析缺口修复进度 + A* 验收矩阵 + 搜索批量扫描引擎缺口修复（§七~§十三）的进度/交接文档。**含独立不可丢失证据**：G1-G15 逐条提交 + 测试数表（§二 L17-31）、搜索批扫各修复项「原版对齐依据」列（§七~§十三）、§四 A* 实网验收矩阵（L59-71）。G1-G15 全部 15/15 已完成（L8、L85），非未结项。

### 未结项交叉核验表
| 原文档 | 条目（原文编号/标题） | 原文状态 | 当前证据（commit hash / 文件:行 / Active编号 / CI） | 结论 | 处置建议 |
|---|---|---|---|---|---|
| PARSER_GAP_FIX_PROGRESS_20260815.md | §四 A* 实网验收矩阵（L59-71；L86「待真实书源环境执行」） | 待执行 | Active L151「P2-4 A* 验收矩阵（已关闭 2026-08-22）：WebDAV、音频/漫画/视频、ruleReview、真机媒体键、皮肤 zip、验证码等逐项登记素材、负责人、命令和证据；待验收不等同工程未实现，也不能销账为完成」（commit `cb81703fd`，HEAD 祖先）；`docs/RESIDUAL_RISKS_2026-08-13.md` L73-99 §A*：A1/A2/A3/A4/A5/A10/V1/V2/V3 共 9 项 ⛔ 待用户素材，A9 ✅ 已验证 2026-08-22 | 仍有效 → Active 已跟踪（P2-4） | 无需迁入 Active（已有编号 P2-4，9 项待用户素材）；随源文档归档 |
| PARSER_GAP_FIX_PROGRESS_20260815.md | §十三 L277「外部 WAF/限频测试标记人工诊断」 | 历史流程备注（wave2 扫描 2026-08-20） | WAF 三源修复批已交付：`83a8890aff`（2026-09-27，HEAD 祖先）「共享内存 Cookie store 修复 FFI 主链路与 JS 桥四池 cookie 脑裂（x81zws 根因）」+ `500941a6de`（2026-09-27，HEAD 祖先）「JS 桥共享客户端 cookie 落库持久化，修复 x81zws WAF 冷启动失忆」；`REFACTORING_ACTIVE_PLAN.md` 全文 grep 无 WAF/500941a6de/83a8890aff 命中（Active 未登记该历史备注） | 已失效或被现行规范取代（根因修复已交付并合入，「人工诊断」为当时流程备注） | 随源文档归档（理由：WAF 批已收口，Active 不跟踪此历史备注） |

## 四、docs/SEARCH_PARITY_REMEDIATION_PLAN_20260828.md（373 行，2026-08-28~09-20）

### 文档概述
搜索 parity 修复计划（P0/P1/P2 阶段计划 + §七 实施记录 + §八 续作执行记录）。**含独立不可丢失证据**：§7.2 armv7 quickjs=false 根因定位与决策点登记（L180-209）、§7.6 双包基线声明撤回（L302）、§8.6/8.8 S0-C 原版端环境阻断诊断（L341-372）。L3 状态头（2026-09-20）：「本计划 §三 各阶段已基本实施完毕……F1 loginCheckJs、错误八分类、S0-D 计时、三入口一致性测试已落地（提交 deb0e87005/473968bcaf）。仍开放：explore 链同模式、聚合下沉（可选）、重试/cookie/charset 逐项对齐评估。头部『开放，未实施』措辞作废。」

### 未结项交叉核验表
| 原文档 | 条目（原文编号/标题） | 原文状态 | 当前证据（commit hash / 文件:行 / Active编号 / CI） | 结论 | 处置建议 |
|---|---|---|---|---|---|
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | §三 主体（P0-1/P0-2/P0-3/P1-1：S0-C/S0-D/八分类/三入口等） | 开放，未实施（L3 已作废该措辞） | S0-C 收口：`docs/SEARCH_PARITY_S0C_CLOSURE_20260903.md` L12「S0-C 集合级 parity 通过」5/5 书、L67「P0-2 S0 / P0-1.4：解除 DEFERRED」；F1/八分类/S0-D/三入口：`deb0e87005` + `473968bcaf`（2026-09-20，HEAD 祖先）；Active L417 P3-6「剩余面基本收口 2026-09-20」 | 已完成收口 | 随源文档归档 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | §八 2026-08-29 续作（P0-3 e2e 双机 7/7、S0-B、S0-E、S0-C） | S0-C DEFERRED（环境阻断） | `c5f82a854`/`91e40dfad`（P0-3 e2e 双机 7/7）、`4330acaf9`（S0-E）、`511a0bb52`（S0-B）均 HEAD 祖先；S0-C 2026-09-03 收口（单机双包拓扑 5556，`SEARCH_PARITY_S0C_CLOSURE_20260903.md` L26/L32「5556 单机双包拓扑（本轮打通）」） | 已完成收口 | 随源文档归档 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | §7.4 multi_source_search 委托统一执行器（L238-253，commit 22a8df7d9） | 已实施（2026-08-28） | §7.4 自记验证（legado-ffi 非 quickjs 309 / quickjs 367 passed，0 failed）；后续跨源聚合下沉由 `c4712f4a7a`（2026-09-23，HEAD 祖先；Active L269「P1-1 项2 跨源聚合下沉 + 跨端夹具校验 已实施」）关闭 | 已完成收口 | 随源文档归档 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | §7.5 originOrder 透传（P1-1 项3，L255-273） | 已完成（2026-08-28） | `rust/legado-ffi/src/api/search.rs` L148-150 `SearchResult.origin_order`（serde rename `originOrder`）、L1615-1616/L1682 写 `source.custom_order`、L2323-2368 两条单测 | 已完成收口 | 随源文档归档 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | §7.2 armv7 quickjs=false 决策点（L180-209，决策 L207） | 决策点登记（超出纯搜索范围，属书源/书籍格式依赖治理） | L202 根因「当前 quickjs feature 集合含 rar crate，而 rar 无法在 32 位 armv7 编译（u64: ToUsize 未实现）」；L207 两方向：① 将 rar 拆为独立可选 feature ② 接受 armv7 为无 JS 遗留 ABI；Active 计划 grep 无 armv7/rar 登记（仅 L226 提及 armv7 陈旧 .so 问题已由指纹校验机制消除） | 涉及产品决策 | 迁入 Active 作决策项：建议编号 **P2-24**「armv7 JS ABI 治理」（待用户裁决后登记） |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | §7.6 双包基线声明撤回（L275-302） | 已撤回（改单包观察） | L302 文档自述「原『P0-1.4 双包基线 + S0 通用搜索路径验证通过』声明已撤回」；S0-C 后由单机双包拓扑收口 | 已失效或被现行规范取代 | 保留为历史参考（证据类型＝自我纠错过程记录） |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | 仍开放①：explore 链同模式对齐（L3 头；WebBook.kt L149/227/327/454） | 开放 | `rust/legado-ffi/src/api/explore_api.rs` L799-800 explore_login_check 双路径注释 + L1061 测试注释「loginCheckJs 返回 "false"（未登录）→ 二次 errResponse(500) eval 仍 false」——仍为谓词语义（trimmed=="false"/contains 未登录/needLogin），未对齐 F1 的 StrResponse cast 语义（FFI 搜索侧 `js_executor.rs` L203-275 已对齐） | 仍有效 | Active L417 已登记（P3-6「仍开放」），无需新编号，挂 P3-6 保留 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | 仍开放②：`legado-server/src/login_check.rs` 旧语义副本（L3 头） | 开放 | `rust/legado-server/src/login_check.rs` L79-80 `if trimmed == "false" \|\| trimmed.contains("未登录") \|\| trimmed.contains("needLogin")` 仍谓词语义；最近相关 commit `e2b8003dab`（2026-09-26，HEAD 祖先，能力对账批次2）仅做 globalThis 属性注入，未做语义对齐 | 仍有效 | Active L417 已登记（P3-6「仍开放」），无需新编号，挂 P3-6 保留 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | 仍开放③：AnnotatedCandidate 补 originOrder（L3 头） | 开放 | `rust/legado-ffi/src/api/search.rs` L1044-1075 `AnnotatedCandidate` 字段（book_name/author/cover_url/intro/latest_chapter/source_url/source_name/book_url/relevance_score/has_read_record/read_record_author/variable）**无 origin_order**（对照：内部 DTO `SearchResult` L148-150 已有该字段） | 仍有效 | Active L417 已登记（P3-6「仍开放」），无需新编号，挂 P3-6 保留 |
| SEARCH_PARITY_REMEDIATION_PLAN_20260828.md | 重试/cookie/charset 逐项对齐评估（L3 头「仍开放」） | 开放 | P2-19 已关闭：Active L248-260（三项已修 2026-09-22 + JS 侧跨源 cookie 泄漏 2026-09-23 修复闭环 + 同步上游 2026-09-23，13 门禁全绿）；Active L417 不再将其列为开放 | 已完成收口 | 随源文档归档 |

---

## 五、汇总清单一：建议归档文件（含理由）

| 文件 | 建议 | 理由 |
|---|---|---|
| `docs/AUDIT_FIX_ASSIGNMENT.md` | 归档至 `docs/过期文档/` | 4 条未结项全部收口（`08e731957e`/`d994a4fdbb`/`961a2d353`，均为 HEAD 祖先，对应源码文件实际存在）；无独立不可丢失证据（修复细节在提交与源码中）；L4 引用目标 `docs/过期文档/PROJECT_AUDIT_REPORT.md` 实际存在，可同置 |
| `docs/IOS_TRACK_FEASIBILITY_20260830.md` | 归档至 `docs/过期文档/`（**保留全文，不得摘取**） | P1/P2-A/B/C 收口，仅剩「P2 剩自动任务降级 + 真机走查」与「P3 三端收敛」仍有效（将迁入 Active P2-23/P3-8）；签名矩阵（L43-55）/插件对照表（L57-75）/平台限制（L114-121）为不可丢失勘察证据，须全文保留 |
| `docs/PARSER_GAP_FIX_PROGRESS_20260815.md` | 归档至 `docs/过期文档/`（**保留全文，不得摘取**） | A* 矩阵已由 Active P2-4 跟踪（`cb81703fd` + RESIDUAL_RISKS §A*，9 项待用户素材）；§十三 WAF 项已失效（`83a8890aff`/`500941a6de` 已交付）；G1-G15 15/15 与各节「原版对齐依据」列为历史证据，须全文保留 |
| `docs/SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` | 归档至 `docs/过期文档/`（**保留全文，不得摘取**） | 主体收口（S0-C 2026-09-03 / F1·八分类·S0-D·三入口 `deb0e87005`+`473968bcaf` / 跨源聚合 `c4712f4a7a` / 重试·cookie·charset P2-19）；3 条开放项已登记 Active L417（P3-6）；armv7 决策点待用户裁决后登记；§7.2 根因定位与 §8.6/8.8 阻断诊断为不可丢失历史证据，须全文保留 |

归档依据：`docs/REFACTORING_WORKFLOW.md` L18「历史计划或已结束 UI 批次 → docs/过期文档/……只提供来源证据，不得派发新任务」。

## 六、汇总清单二：建议迁入 Active 条目（含建议编号）

Active 现最大编号 P2-22 / P3-7，新编号自 P2-23 / P3-8 起（`REFACTORING_ACTIVE_PLAN.md` grep 实测）：

| 建议编号 | 条目 | 来源 | 一句话说明 |
|---|---|---|---|
| **P2-23** | iOS 自动任务降级 + 真机走查 | IOS §五 P2（L101-107、L71/L105）；Active L483「P2 剩自动任务降级与真机走查」 | workmanager iOS 降级（前台定时执行，对齐 L71）+ iOS 真机走查清单，iOS 轨 P2 收尾 |
| **P3-8** | iOS 三端收敛 | IOS §五 P3（L109-112）；Active L483「P3 三端收敛待启动」 | Windows 行为基线固化 + macos/linux FFI 接线冒烟（dylib/framework 装载）+ CI 三产物矩阵 |
| **P2-24（决策项）** | armv7 JS ABI 治理 | SEARCH PARITY §7.2 L202-207 | 用户裁决后（① 将 rar 从 quickjs feature 拆出为独立可选 feature；② 接受 armv7 为无 JS 遗留 ABI 或不再随 APK 分发 armv7）改 `legado-js/Cargo.toml` feature 结构 |
| —（无需新编号） | P3-6 三条开放项：explore 链同模式对齐 / server `login_check.rs` 旧语义副本 / `AnnotatedCandidate` 补 originOrder | SEARCH PARITY L3；Active L417 已登记为 P3-6「仍开放」 | 无需新编号，挂 P3-6 保留；源码证据 `explore_api.rs` L799-800/L1061、`login_check.rs` L79-80、`search.rs` L1044-1075 |

## 七、汇总清单三：待用户裁决条目

1. **armv7（armeabi-v7a）JS ABI 治理决策**（SEARCH PARITY §7.2 L207）：① 将 `rar`（及同类非 JS 归档依赖）从 quickjs feature 拆出为独立可选 feature → armv7 可装 JS 引擎；或 ② 接受并显式声明 armv7 为「无 JS」遗留 ABI，甚至不再随 APK 分发 armeabi-v7a。任一方向都需确认后才改 `legado-js/Cargo.toml` feature 结构；裁决后登记为 Active P2-24。
2. **A* 实网验收 9 项待用户素材**（`RESIDUAL_RISKS_2026-08-13.md` L90-99，Active P2-4；来源＝PARSER_GAP §四矩阵）：A1 WebDAV / A2 音频 / A3 媒体键 / A4 漫画视频 / A5 段评 / A10 皮肤 zip / V1 验证码 / V2 倒计时 / V3 外链 全部 ⛔，需用户提供真实书源/设备/素材。此为本轮非新增项（Active 既有），列此以保完整。
3. **iOS 签名与分发方式**（IOS §二 L43-55）：现仅产出未签名 ipa（自签 7 天过期）；如需长期正式分发，需用户决策（$99 开发者账号 + TestFlight CI 签名；企业 In-House 因吊销风险高已出局）。属 IOS 文档遗留决策点，非本轮新增。
