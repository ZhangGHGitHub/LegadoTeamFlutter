# 长期队列收口报告（2026-09-22）

> 性质：本会话长期执行队列（用户 2026-09-20 指令「列一个计划，一次性按顺序处理掉…做完喊我」）的**交付索引与收口记录**。
> 编写：主代理（ZCode 本机通道）｜ 2026-09-22

---

## 一、队列完成度一览

| 序 | 任务 | 状态 | 关键提交 / 证据 |
|---|---|---|---|
| — | P2-7(b) 沙箱 SIGSEGV（quickjs-ng OOM UAF） | ✅ 已关闭 | `d689584fef` + `36bc435921`；原崩溃配方转正为回归断言，Windows+WSL 双端实证 |
| ① | A 组形态对齐（A1 全屏扫码 / A4 入口 / A5 菜单 5 键 / A6 输入盒） | ✅ | `058ccec1a3` 等；Flutter CI 绿；依赖评估含 **zxing2 CJK 乱码规避** |
| ② | M1 深色阅读背景 + 崩溃误报设备验证 | ✅ 全项通过 | `4923c69da6`；正文纯黑 Δlum=0、切主题即时生效、显式选择保留、chrome 对比度 10.3–13.2:1、崩溃弹窗消失 |
| ③ | A-4 死默认改必填 / A-5 删 `app_colors.dart` / N6 收起字体入口 | ✅ 过审后提交 | `14752aba63`（code-reviewer：可提交）；版本 2.0.302+303 |
| ③b | A4 书架"未读书"单击直达阅读（用户裁决 B 方案/重构版模式） | ✅ 过审 + 实机五项 | `acde3bda6b`；阅读器零进度**无需补丁**（代码+实机双证）；审查要求的两处硬化 + 3 测试已补 |
| ④ | 能力受限提示 + 未知类告警 + 搜索失败源 UI 横幅 | ✅ 审查退回修复后落地 | `af47fcb956`；删误伤预校验、探测安全哨兵、台账硬化、非阻断横幅；版本 2.0.305+306 |
| ⑤ | 真语料 jsLib 夹具 + 端到端测试 | ✅ | `0fbad7afdf`；七猫 588,700B / favcomic 16,184B；断言经双路确认；登记唯一缺口 `java.io.InputStream` |
| ⑥ | P2-3 Mock 书架样例脱敏化 | ✅ | `2a4795f8e7`；10 本虚构书 + 脱敏护栏测试；版本 2.0.306+307 |
| ⑦a | A2 主题页同步参考版（改名+排序+横滑一行） | ✅ | `1869dbb289`；版本 2.0.303+304 |
| ⑦b | 参考版深色三项重采（A3 基线 / Transparent sCL / A6 裁决） | ✅ | `742af2e475` + `a37a0cd1fd`；**Transparent sCL 与我方一致无需改**；A6 判定回退 `surfaceContainerLow` |
| ⑦c | A3 外观页 IA 对齐参考版 | ✅ | `e15f5767ca`；12 项参考独有功能**仅登记不实现** |
| ⑧ | 网阅小说 688 章 / 松鹤庭沐 712 章实机自证 | ✅ **P2-7(a) 缺口关闭** | `825005b074`；设备实态 DB 跑 App 同源链路：688/688 与 712/712 互异 URL、正文抽样 4/4 真实 |
| ⑨a | 目录治理"真实缺陷"三项（P1 假绿 / P2 tmp_* / P5 死流水线） | ✅ | `af47fcb956`（夹带）+ `0f6d1367a9`；ignored 42/21 |
| ⑨b | 目录治理"仓库卫生"（P3/P4/P6~P10） | ✅ | `659494abcf` + `92f574dc4d`；47 项文档归档 + 映射表 + 52 项残留清理 |
| ⑩b | 搜索 HTTP 层逐项对齐评估 | ✅（只评估） | 本报告 §三；发现三项确凿缺陷 → **登记 P2-19** |
| ⑫ | 书架从阅读器返回后不刷新（P3） | ✅ | `4d71234004`（消息后经 `--amend` 补全为 `659494abcf`）；先失败测试后修，全量 1601 过 |
| — | Flutter CI `setup-android` 基建修复（门禁长期被 skip） | ✅ | `f97efdfcb2`；`analyze`/`test` 恢复在 CI 执行 |
| — | 宿主环境：设备档位与 ROM 清单、第二车道 test2 | ✅ | `9fcf403514` / `f8f7832ac5` / `f4c5102d95` |
| — | 深色台账 / Rhino 实测统计 / 全域口径落档 | ✅ | `db512336aa` / `77ebca96e2` / `069c5aa723` |
| ⑩a | 跨源聚合下沉 + 跨端夹具校验（约 2 天量级） | ⏸ **未实施**（用户口径：可选排最后） | 见 §四 |

**版本链**：2.0.301+302 → **2.0.306+307**（每批同步 CHANGELOG 与应用内更新日志）。
**CI**：每批均以 CI 结论为准；末次双绿 `52e569ace6`（Rust `35720049401` + Flutter `35720049275`），其后 `517b54c745` Flutter CI `35723649983` 绿（Rust 未触发，无 rust 路径改动）。**本地与远端一致（0/0）**。

---

## 二、关键工程修复（值得留档的根因）

1. **quickjs-ng OOM use-after-free**（P2-7(b)）：`build_backtrace` 重入 OOM 时 `JS_Throw` 释放的正是待补栈的 error object → 进程级 SIGSEGV。上游 `e1c1e416`（quickjs-ng ≥0.15.0）已修；本项目升级 rquickjs 至 0.12.2（内置 0.15.1）并**把原崩溃配方转正为回归断言**。
2. **顶层 `return` 的 `@js:` 规则被静默吞空**（P2-11 ④ 顺带根因）：旧求值包装按顶层 Script 编译，`return` 语法错误 → 整条规则静默变空；改为"函数体求值优先 + 表达式回退"。
3. **非致命布局告警被误报为崩溃**：`A RenderFlex overflowed …` 曾写崩溃记录并弹「上次运行发生崩溃」；现按特征分类，软告警只记 `[布局告警]` 日志。
4. **测试"缺夹具静默 PASS"假绿**（11 例）：静默跳过改为**响亮 panic** + 补 `#[ignore]`（原因写明夹具已删 + 实网诊断）。
5. **全局 store 测试竞态**：`GLOBAL_STORE_TEST_LOCK` 原为 `web_book` 测试模块私有 → 提为两处 crate 级 `#[cfg(test)]` 共享设施，**68 个持锁站点**；quickjs 整档 5/5 复跑全绿。
6. **能力受限静默失败**：未知 Java 类/成员调用改为**探测安全哨兵**（读取不抛、调用/取子成员告警）+ 台账登记 + 用户可见文案 + 搜索结果页**非阻断「失败书源」横幅**。
7. **会误伤纯 CSS 书源的预校验**：已删除（favcomic 类源曾被判死、永久 0 结果）。

---

## 三、⑩b 评估发现的**新缺陷（登记 P2-19，未修）**

| 级别 | 缺陷 | 位置 | 最小复现 |
|---|---|---|---|
| **P1** | cookie **域名键塌缩**（取 host 末两段，无 Public Suffix 判定） | `client.rs:738-749`、`cookie_store.rs` | 两个不同 `.com.cn` 站各 Set-Cookie 一次后访问任一站，Cookie 头会带另一站的 cookie |
| **P1** | 规则 Cookie 头**被 DB 整体覆盖**（上游为按键合并且规则优先；且我方无 per-source cookie 开关门控） | `client.rs:280-282` | 书源规则显式设 Cookie 时，DB 有该域名 cookie 的请求会丢规则 cookie |
| **P2** | `concurrentRate` **编辑不生效**（只有 `or_insert_with`，无刷新入口） | `source_rate_limit.rs:14-32` | 书源 concurrentRate 改小后保存，运行中仍按旧值限流（重启才生效） |

backlog（P2/P3）：`urlOption retry` 完全未消费、charset 无探测兜底、重定向跳数 10 vs 20、`followRedirects=false` 未消费、JS `setCookie` 不落 DB。
**保持现状**（评估明确不建议改）：concurrentRate 算法（与上游等价）、S0-E 非 2xx 语义、**显式 charset 解码（我方优于上游）**。

---

## 四、仍待用户输入 / 可选项

1. **⑩a 跨源聚合下沉 + 跨端夹具校验**（约 2 天量级）——按你"可选排最后"口径未实施，需要你决定是否投入。
2. **P2-19 三项缺陷**（P1×2/P2×1）——新发现、不在原队列内，各 2–8h；建议优先 P1 两项（cookie 键塌缩与优先级反转）。
3. **⑫ 的范围外补充**（既有行为，未改）：长按详情页是未 await 的 push（返回不刷新）；从首页/最近阅读等其他入口开书再切回书架属更宽的"全局返回刷新"问题。
4. **⑦c 的口径变化请确认**：外观页「主题模式」选择器从"只在『我的』枢纽暴露"改回页内展示（覆盖 2026-08-13 旧裁决，理由=IA 照参考版）。
5. **设备复核待做**（⑦c 列出 7 点；⑦b 结论已给）：外观页整页与深色基线并排比对、选择器选中态、通用组滚动观感、纯黑开关可见性条件（miuix 环境）、Windows 端「切换图标」整项隐藏。
6. **⑨b 遗留（已裁决 2026-09-22）**：`.qoder/specs/` 三份早期方案 → **归档**至 `docs/过期文档/qoder_specs/`（按 P7 先例）；109M `docs/parity_shots/songhe_template_fix_20260917/` → **不入库**（用户裁决：进 git 历史不可逆、且刚完成 302G 清理），保持 `.gitignore` 忽略、**仅本地证据**，台账/台账类引用按"本地证据（不入库）"标注。
7. **⑦c 口径（已裁决 2026-09-22）**：外观页「主题模式」选择器**按参考版做法保留在页内**（用户：根据参考版的做法），不回退旧裁决。
7. **外部输入（历史遗留，未变）**：Mock 素材已由合成方案解决；仅剩**网阅/松鹤之外**的特殊设备场景（如需真机复现某源）与 Rhino `java.io.InputStream`（favcomic 缺口的补/弃口径）。

---

## 五、证据索引（按批次）

- 深色：`docs/parity_shots/ref_dark_20260920/`、`ref_dark_20260921/`（含 `RECAPTURE_20260921.md`）、`ours_dark_20260920/`（含 `DARK_DELTA_20260920.md`）
- 批次冒烟与实机：`docs/parity_shots/queue_smoke_20260920/`（`mumu_*` 换档冒烟、`m1b_*`/`m1c_*`/`verify2_*` M1 验证 + `VERIFY_M1_20260920.md`、`a4b2_*` A4 五项、`s688_*` 688/712 自证、`logincheck_*` 能力探针）
- 规则引擎与搜索：`docs/RULE_TEMPLATE_SEGMENT_FIX_20260917.md`、`docs/SEARCH_PARITY_*`、`docs/RHINO_INTEROP_ANALYSIS_20260920.md`（含 §8 实测统计与 §8.5 缺口登记）
- 台账：`docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md`、`docs/DARK_THEME_PARITY_LEDGER_20260920.md`、`docs/REFACTORING_ACTIVE_PLAN.md`（P2-16~P2-19）
- 归档映射：`docs/过期文档/ARCHIVE_MAP_20260922.md`

---

## 六、2026-09-23 续批闭环（本次会话内完成，全部已推送）

| 批次 | 内容 | 版本 | 提交 | 证据 |
|---|---|---|---|---|
| ⑩a | 搜索跨源聚合下沉为 Rust 单一真源（加法式 origins 字段 + 跨端夹具 5 case + ECMAScript 等价归一化）+ 审查 5 项修正 + P2-20 登记 | 2.0.308+309 | `c4712f4a7a` | Rust/Dart 双端夹具绿、`cargo test --workspace` 两档 0 failed、`flutter test` +1603、code-reviewer 审查（无阻断）→ 全修 |
| 设备补验 | 种子本地书补验项 4（阅读器菜单 5 键）/项 6（书架单击直达阅读 + 返回定向刷新）：全通过（原「待裁决 1/3」撤销） | — | `5053da2544` | `docs/parity_shots/verify_ui_20260922/vui2_*`（49 文件）+ 报告补验节 |
| P2-21 | 08 屏「在读/最新/共N章」三行块：off-by-one（0 基误当 1 基）+ 双基准形态对齐（去「第N章」前缀/去「（全书完）」代码后缀/三态=未读·已读N章·已读完） | 2.0.308+309 | `04b367948e` `dcfbdd24fc` | 实机双场景（存储值优先 / 目录回落）经种子书证明 off-by-one 修复；`b8_*` 证据 + 与参考 dump/截图对照；`flutter test` +1613 |
| Rhino 末项 | 书源脚本 `java.io.InputStream` 最小能力面（实例哨兵 Proxy + Java 语义修正）+ 诚实化 e2e 断言 + 台账登记 | 2.0.308+309 | `70932519bc` | 真实夹具由「加载必失败」→「加载完成 + InputStream 解析可用」；quickjs 档 `js_lib_corpus` 2 passed；code-reviewer 两轮（3 重要 + 2 提示全采纳，另反证审查 spec 一处 off-by-one） |
| P2-22 | 08 屏元信息区元素集对齐参考版：移除参考版不存在的「目录：」「分组：」「🏷️」三处独立行，分组→chips 条件 chip、kind→chips 逐项、chips 行去重复章数 | 2.0.308+309 | `95a6d65696` | 浅色截图 + 深色 dump + 参考源码三重取证；`flutter test` +1617（新增 5 例）；台账「08 元信息区对齐修订」节纠正 U5/U9/U10/U11/U12 旧表述 |
| 卫生批 | 清 `clippy --all-targets` 三处既有债务（legado-net：`await_holding_lock` ×2 + `never_loop`） | 2.0.308+309 | `5b7962bf27` | `cargo clippy -p legado-net --all-targets -- -D warnings` 归零；`legado-net` 247 测试 ×3 连跑绿 |

**本轮新登记（待裁决，均已写入 `docs/REFACTORING_ACTIVE_PLAN.md`）**：
1. **P2-20**：Dart 搜索聚合双路径自身不一致（纯函数四独立桶 vs 增量桶 `_seenKeys` 预去重）——未来把运行时切到 Rust 聚合前须先裁决以哪条为准。
2. **workspace 级 `clippy --all-targets -- -D warnings` 仍有 45 处既有报错**（工具链 clippy 0.1.97 lint 漂移；含 1 处为队列⑩a 引入）——建议单开一批清理，或修订 `rust/DEVELOPMENT.md` 门禁口径与 CI 对齐（CI 不带 `--all-targets`，`cargo clippy --workspace` 两档均 0）。
3. **JS 侧跨源 cookie 泄漏** → **已闭环（2026-09-23）**：先按「当前书源」收敛作用域（P2-19），随后按用户裁决**同步上游语义**（cookie 按**域名**归属、同域跨书源共享、异域绝不携带），注入点下沉到请求级，并补 CI 的 `legado-server --features quickjs` 覆盖面。仅剩**持久化**差距（上游落 DB / 我方内存态）待裁决，见 `REFACTORING_ACTIVE_PLAN.md`。
4. **D9 深色背景底色**：#4A4A4A（我方内置色板）vs #101418（参考）——属主题引擎/色板取值，需确认基线引擎要求（登记见 `docs/parity_shots/verify_ui_20260922/VERIFY_UI_20260922.md`）。
5. **08 屏遗留（低优）**：三行左缘 13dp vs 参考 `BookInfoSummary` `start=16dp`（3dp），宜与全页 padding 一并复核。

---

编写者：主代理（ZCode 本机通道）｜ 2026-09-22（§六 续批回填 2026-09-23）
