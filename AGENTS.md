# AGENTS.md — Legado 项目 Agent 工作入口

本文件为编码 agent 提供进入 Legado 代码库的统一入口：模块地图、验证命令与规范路由。
项目概览详见 [README.md](README.md)。

## 项目概览

Legado：Rust + Flutter 跨平台阅读器，与 Android 原版（gedoor/legado）保持双轨对齐的阅读应用。

## 模块地图

| 路径 | 内容 |
|---|---|
| `app/` | Kotlin Android 主模块（约 1000 个 .kt 源文件），含 `app/src/main/java/io/legado/app/` |
| `modules/book/`、`modules/rhino/`、`modules/web/` | Android 子模块（书源、Rhino JS 引擎、Web 辅助） |
| `flutter_legado/` | Flutter UI（Windows 构建主模块），`lib/` 为 Dart 源码 |
| `rust/` | Rust 工作区（legado-book / legado-core / legado-db / legado-ffi / legado-js / legado-net / legado-parser / legado-server） |
| `docs/` | 项目文档（计划、报告、规范、API 契约） |
| `.qoder/` | Qoder 配置（rules 规则、skills、agents、specs、repowiki） |

## 验证命令

- **Android 单元测试**：`./gradlew :app:testAppReleaseUnitTest`（CI：`.github/workflows/test.yml`）
- **Flutter**：在 `flutter_legado/` 下 `flutter analyze && flutter test`（CI：`.github/workflows/flutter-ci.yml`）
- **Rust**：在 `rust/` 下 `cargo test`（CI：`.github/workflows/rust-ci.yml`）
- **CI 总览**：`.github/workflows/`（test / rust-ci / flutter-ci / release / BetaRelease / web 等）

## 规范与文档路由（改动前必读）

1. [.qoder/rules/legado-dev-conventions.md](.qoder/rules/legado-dev-conventions.md) — 开发规范：优先级分类（P0/P1/P2）、验证优先工作流、Git 安全实践、Windows 编码处理、文档存放规范
2. [docs/TWO_TRACK_DEV_SPEC.md](docs/TWO_TRACK_DEV_SPEC.md) — 双轨开发规范：Rust+Flutter FFI 契约冻结、Mock 驱动、原子化工作流
3. [docs/UI_FIX_PLAN.md](docs/UI_FIX_PLAN.md) — UI 修复的权威执行依据（四步文档研读流程）
4. [docs/API_CONTRACT.md](docs/API_CONTRACT.md) — FFI API 契约（跨轨变更必须先冻结契约）
5. [docs/design_system.md](docs/design_system.md) — 设计系统
6. [docs/REFACTORING_ACTIVE_PLAN.md](docs/REFACTORING_ACTIVE_PLAN.md) — 当前唯一后续重构执行计划（历史阶段计划见 docs/过期文档/）

## 关键约束

- **原版对齐**：功能实现逻辑必须参照 Android 原版源码（功能基准：`com.legado.app.release` 3.26081008）；界面功能、页面结构与交互流程必须与原版保持一致；**视觉一比一（2026-09-14 用户修订，废止 2026-08-05「视觉风格自由」授权）**：UI 视觉（布局骨架/位置层级/间距圆角/图标文案形态/**配色/字体/明暗主题**）以参考版实机截图为准一比一对齐，原版仅作功能基准（双基准口径：功能=原版+参考版任一侧，视觉=参考版）；实现层仍遵循 Material Design 3（参考版即 M3 风格）；执行规范与台账见 docs/SCREEN_1TO1_PARITY_SPEC_20260914.md 与 docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md
- **双轨并存**：旧 Android 代码暂不删除，保持双轨并存；Rust 核心逻辑 + Flutter UI 为新架构
- **FFI 变更**：修改 Rust/Dart FFI 边界前，先更新 `docs/API_CONTRACT.md` 契约，再实施代码；跨轨阻塞项须 Rust 轨先行交付契约；契约修改需双方（Qoder/QoderCN）确认；Mock 数据使用从原 Android 应用抓取的真实 JSON
- **重构红线**：本项目为重构项目，**未经允许禁止新增 Android 原版不存在的功能**（用户明确授权的除外，如 LargeTitle 大标题、颜文字空态彩蛋、阅读热力图等，授权记录见提交与文档）；发现未授权的偏离项（如推荐算法等）必须清理，一切以不偏离重构核心为目标（2026-08-29 用户修订授权口径）
- **执行边界**：不得超范围删除或修改文件，删除/修改代码前必须先确认范围无误
- **计划驱动**：每阶段开发前先审查当前执行计划（docs/REFACTORING_ACTIVE_PLAN.md，唯一开放项台账；历史计划已归档 docs/过期文档/），确认进度符合度后按 P0/P1/P2 优先级顺序执行
- **UI 层职责边界**：UI 层只做界面渲染、交互与状态管理，不含业务逻辑；数据经 Rust Bridge 获取；遵循 UI 层与底层分离原则
- **文档存放**：新建计划/报告/交接类 `.md` 必须放 `docs/`；根目录仅保留 README.md、CHANGELOG.md、LICENSE、AGENTS.md 等约定文件
- **全中文规范**：汇报、代码注释全部使用中文；commit 描述/正文使用中文（类型/作用域按约定式提交用英文小写）
- **l10n 范围（D5=B，F4-7）**：维持中文主语言；UI 文案以 `AppStrings`/硬编码中文为主，不推进全面国际化；新增页面沿用中文，英文仅保留系统 locale 切换入口（其他设置页语言项）

## Git 纪律与版本控制

- 每次改动验证通过后立即 commit 到本地；阶段性成果须 commit 并 push
- **提交信息必须遵循约定式提交（Conventional Commits）**：`<类型>[作用域]: <中文描述>`，类型用 `fix`/`feat`/`docs`/`refactor`/`test`/`chore` 等英文小写，作用域用 `ui`/`rust`/`tool`（替代旧式 `[UI]`/`[Rust]`/`[Tool]` 前缀，如 `fix(ui): ...`、`fix(rust): ...`）；`fix` 必须在正文说明根因、脚注关联 `Fixes #编号`；描述 ≤72 字符、正文行 ≤100 字符、不得混用类型、不得用模糊描述；详细规则见 `.qoder/rules/legado-dev-conventions.md`「Git 提交规范」章节
- 分支策略：`feature/rust-*` 与 `feature/ui-*` 独立开发，集成使用 `integration/*` 分支；仅从当前 HEAD 创建规范分支，不得改动已提交历史
- 署名规范：UI 层代码署名「— 子代理名称 + UI」，Bridge 层代码署名「— 子代理名称 + Bridge」，文档末尾附编写者署名与日期
- 批次修复按 pubspec 版本 patch 递增（如 2.0.0+2 → 2.0.1+3），每批同步更新 CHANGELOG 与应用内更新日志 `flutter_legado/assets/updateLog.md`（关于页展示，仅记录用户可见变化，按日期条目格式），记录版本号与贡献者；版本号记录于 CHANGELOG 与提交正文，commit subject 不带版本号
- 进度文档（docs/ 下）须与 git 提交记录保持同步，任务编号不得重叠

## 验证与交付流程

- 每轮修复后的两级验证：子代理先在**测试档模拟器**测试，测试通过后再安装到**用户验收档**通知用户实测验收
- **模拟器验证档（2026-09-20 用户指令：改用 MuMu，弃用雷电）**：
  - **测试档 = MuMu 模拟器的「Test测试」实例**（guest 直连端点 **`192.168.1.19:5555`**，Android 15；该实例装有我方 `io.legado.flutter_legado`、原版 `com.legado.app.release`、**参考版 `io.legato.kazusa`** 三包，可做双/三包拓扑与参考采集）。启动：`"D:\Program Files\MuMuPlayer\nx_main\MuMuManager.exe" control -v 1 launch`（实例 index 1；`info -v all` 可查状态，`is_android_started` 为真后再 adb 连接；`127.0.0.1:16384/16416` 端点已失效，**只认 guest 直连**）。
  - **雷电模拟器已弃用**：emulator-5556（LDPlayer 实例 1）环境故障（VBox 栈无法拉起 VM 内核进程，2026-09-20 排查记录在案）；emulator-5554 为临时替代档（已停用）。**5558 验收档位待用户指定**，未指定前不得自行占用其它实例。
  - **冒烟脚本**（构建+安装+启动+崩溃检查）：`.\scripts\emulator_smoke_test.ps1 -Device 192.168.1.19:5555`（可加 `-CheckUI` 做书架主界面元素检查；复用 APK 加 `-SkipBuild`）；退出码 0=通过 1=失败。
  - **MuMu ROM 限制（2026-09-20 实测，派任务前告知子代理，免得白撞）**：设备伪装三星 SM-G9900/Android 15，模拟器特征 prop 全空；**中文输入被阻断**（IME 启用被安全策略 patch、`cmd clipboard` 无实现、`input text` 仅 ASCII——搜索类探针改用应用内搜索历史 chip）；`screencap` 不能写 `/sdcard`（须 `exec-out screencap -p` 重定向本地）；`uiautomator` 写转储后自杀（崩溃缓冲区噪声，非应用问题）；`content` 与 toybox `grep` 段错误（改本地 grep）；`settings put secure` 静默回滚（用 `global`）；logcat 被 `E MESA: Failed to find VkFence`（Vulkan）刷屏。
- **完成定义（DoD，2026-09-17 新增）**：判定「完成」的依据是**证据**，不是执行步骤：
  1. 代码改动须附「多代理协作规则」路由表中对应的证据，并在提交正文写明来源（CI 运行链接 / QA 报告路径 / 审查结论 / 截图路径）；
  2. **CI 能覆盖的验证不重复派角色**（`flutter analyze && flutter test`、`cargo test`、`./gradlew :app:testAppReleaseUnitTest` 一律以 CI 结果为准），角色只用于 CI 覆盖不到的场景（实机冒烟、UI 交互、跨模块手动复现）；
  3. **高风险改动**（跨模块 / FFI 契约 / 公共 API / 大范围重构）必须在提交前取得 `code-reviewer` 结论；一般小修不强制派审查；
  4. 子代理自述（无独立证据）不构成验收依据。
- 汇报纪律：确认问题彻底解决后才能汇报完成，如实汇报，不得夸大进度或完成度
- 反复出现的问题必须深挖根因、永久解决，禁止临时修补；发现的重大技术风险须正式写入重构计划文档并说明原因
- 当前开发环境为 Windows，无 make 命令：给用户的命令必须是可直接执行的 CMD 或 PowerShell 命令行，不要给 Makefile 目标

## 多代理协作规则

- 主 Agent（Qoder）职责：① 拆解并分发任务至子代理；② 推进任务，子代理卡住时主动跟进协助解困；③ 验收任务
- **（2026-09-11 用户明确）子代理执行原则**：
  - **主代理只做任务分解与审核**（拆解、派发、读 diff 复核、验收判定、文档与提交），**具体执行操作全部交给子代理**（编码、取证、构建、实机验证等），主代理不自行兜底实现
  - **禁止主代理兜底子代理**：子代理失败/超时/卡住时，须先向用户说明情况并**申请同意**后方可改由主代理接手；未获同意不得自行兜底
  - **子代理并行上限 = 2**：任意时刻最多两个子代理并行（原「可大规模并行」口径按此收敛）
- **子代理路由表**（2026-09-17 修订：角色名与 ZCode 实际类型名对齐，新增执行侧与触发条件）：

  | 触发条件 | 角色（须与 ZCode 类型名逐字一致） | 执行侧 | 证据形态 |
  |---|---|---|---|
  | 代码实现/修改 | `full-stack-engineer` | 本地 | 提交 + 自测输出 |
  | `flutter_legado/**`、`rust/**` 的常规验证 | 不派角色 | — | CI 结果（`flutter analyze && flutter test`、`cargo test`） |
  | 需实机验证（模拟器冒烟：测试档 MuMu Test `192.168.1.19:5555`） | `QA-engineer` | 本地 | 冒烟脚本退出码 + 日志 |
  | UI 布局/交互改动 | `UI-operator` | 本地 | 截图对比 |
  | 跨模块 / FFI 契约 / 公共 API 变更，或 diff 超阈值 | `code-reviewer` | 云端（只发 diff） | 审查结论（提交前） |
  | 有 bug 且 CI/本地复现不出根因 | `debug-engineer` | 云端 | 根因结论 + 最小复现 |
  | 引入新依赖 / 技术选型 / 大范围调研与依赖梳理 | `Researcher` | 本地 | 调研结论 + 出处 |

  - **角色名必须逐字一致**：ZCode 实际类型名为 `full-stack-engineer`、`QA-engineer`、`code-reviewer`、`debug-engineer`、`Researcher`、`UI-operator`。历史坑：本表旧版写的 `qa`/`researcher`/`ui-operator` 三个写法在 ZCode 中不存在，导致照文档派发失败、角色长期闲置（统计：除 full-stack-engineer 外其余角色使用次数为 0）
  - 云端角色（`code-reviewer`、`debug-engineer`）**只发最小上下文**（diff / 最小复现 + 错误栈），禁止整库读取
  - 常规任务先判断能否派发（可自包含、上下文隔离有价值、可并行），能派则派
- 冲突避让：多个子代理同时改代码时必须避让同一文件/模块；任务分配须满足文件不重叠、工作量平均、技能匹配三项原则
- 文档维护：每阶段结束须及时检查并更新所有相关文档（重构计划、进度、README 等），保证后续开发者可顺利接手
- 口头约定正式化：主动提示用户是否需要将对话中达成的口头约定整理成清单写入规则文件

## Qoder 配置说明

- `.qoder/agents/builtin/`：Qoder 产品内置专家团模板（code-reviewer、full-stack-engineer、qa、researcher、ui-operator），仅含 frontmatter，由产品自动维护，**勿手动编辑**；需要项目专用 agent 请创建到 `.qoder/agents/`（非 builtin 目录）
- `.agents/skills/`：**技能权威路径**，当前 53 个技能（资产清单与 lint 仅统计该处）
- `.qoder/skills/` 与 `.claude/skills/`：同源副本；以 `.agents/skills/` 为权威路径，修改技能后同步副本
- `.qoder/rules/legado-dev-conventions.md`：项目唯一规则文件，与本文档配合使用

编写者：Qoder ｜ 2026-08-10
修订：Reasonix ｜ 2026-08-10（更新上游版本基准 3.26081008、计划文档引用、app 文件数；精简技能同步说明）
修订：Qoder UI ｜ 2026-09-03（更新日志义务补全：应用内 assets/updateLog.md 纳入每批同步范围，杜绝仅更 CHANGELOG 的遗漏）
修订：ZCode（本机 27B 通道）｜ 2026-09-17（子代理路由表角色名与 ZCode 类型名对齐、新增执行侧与触发条件；新增完成定义 DoD）
修订：ZCode（本机 27B 通道）｜ 2026-09-20（**模拟器验证档改用 MuMu「Test测试」实例**：guest 直连 `192.168.1.19:5555`、启动方式与端点失效说明入档；雷电 5556/5554 弃用；5558 验收档位待用户指定；冒烟命令与路由表同步）
