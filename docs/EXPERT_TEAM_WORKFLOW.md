# 专家团工作要求与执行工作流参考

## 编写目的与来源说明

本文档整理专家团（Experts Mode）各角色的工作要求与可执行的工作流规范，作为本项目（Legado 重构）中分配、执行与验收专家任务的参考依据。

内容来源分为两部分：

1. **Qoder 官方公开文档**：专家团 7 角色分工契约，出处见 <https://docs.qoder.com/zh/user-guide/quest/experts-mode>。
2. **项目技能库逆向提炼**：对本仓库 `.agents/skills/`（技能权威路径，共 53 个技能）中 21 个高相关技能的 `SKILL.md` 全文精读后，抽取的 Debug / 故障诊断类与 Code Review / 审计类技能的结构化要素，并综合为两份 8 步通用工作流模板；2026-08-10 补充时又新增精读 11 个技能（调研/探索、编码实现、测试与 UI 设计类，见第九章新增卡片），据此整理出调研员、全栈工程师、QA、UI 操作者四个角色的执行工作流。

需要特别说明：**官方未公开内置专家的完整系统提示词**。本文档中的执行工作流均为从项目技能库逆向提炼的「工作要求参考」，用于通过 frontmatter 定制字段（`additionalPrompt` / `skills` / `model` / `mcpServers`）向内置专家注入行为约束，而非官方逐字声明。

---

## 一、专家团分工契约

出处：<https://docs.qoder.com/zh/user-guide/quest/experts-mode>

| 角色 | 英文名 | 工作要求 |
|---|---|---|
| Lead Agent | Lead Agent | 理解需求、拆解任务、协调调度、质量把关，动态拉起专家并行执行（该角色不支持自定义） |
| 调研员 | Researcher | 调研分析、代码定位、依赖梳理、环境检查与报告输出 |
| 全栈工程师 | Full-Stack Engineer | 实现和修改前后端代码，处理跨栈或通用编码任务 |
| QA | QA | 运行测试构建流程，收集并整理验证结果与证据 |
| 代码审查员 | Code Reviewer | 代码审查、风险识别与检测，提出改进建议 |
| UI 操作者 | UI Operator | 浏览器与 UI 端到端验证，可视化 Bug 复现 |
| 故障诊断工程师 | Debug Engineer | 故障复现、根因定位与缺陷诊断，给出修复建议 |

### 本项目 `.qoder/agents/builtin/` 现状

- 项目内 `.qoder/agents/builtin/` 下现有 5 个内置专家模板文件：`code-reviewer`、`full-stack-engineer`、`qa`、`researcher`、`ui-operator`，**仅含空 frontmatter，无正文提示词**（官方未公开完整内置提示词）。上述文件名与官方 7 角色的对应关系为按职责语义推断，非官方逐字声明；Lead Agent 与故障诊断工程师未见对应 builtin 模板文件。
- builtin 目录由产品自动维护，**勿手动编辑**。
- 需要项目专用 agent 时，应创建到 `.qoder/agents/` 根目录（非 builtin 目录）。
- 内置专家可通过 frontmatter 四个字段定制：`model`（模型）、`additionalPrompt`（追加提示词，上限 10,000 字符，**追加而非替换**内置提示词）、`skills`（挂载技能）、`mcpServers`（MCP 服务器）。

---

## 二、调研员执行工作流

**角色定位**：调研员的官方职责为调研分析、代码定位、依赖梳理、环境检查与报告输出。以下工作流提炼自 gitnexus-guide、gitnexus-exploring、gitnexus-cli、dart-run-static-analysis 等调研/探索类技能，遵循「准备 → 执行 → 验证反馈回路 → 证据固化」的共性骨架。

1. **统一入口起步（Always Start Here）**——任何代码理解/定位任务先读 `gitnexus://repo/{name}/context` 获取代码库概览并检查索引新鲜度；再按任务类型（exploring / debugging / impact-analysis / refactoring / cli）匹配对应子技能，读取该技能文件并严格遵循其工作流与清单。（来源：gitnexus-guide）
2. **索引新鲜度检查（Index hygiene）**——context 报告 "Index is stale" 时先跑 `npx gitnexus analyze` 重建索引，再重读 context 验证索引已加载；用 `npx gitnexus status` 查看最近更新时间与符号/关系数量，判断是否需要重新索引。（来源：gitnexus-cli、gitnexus-guide）
3. **功能域总览（Clusters first）**——读 `clusters` 资源获取全部功能域与内聚分数（约 300 tokens），再进 `cluster/{name}` 获取目标功能域成员文件（约 500 tokens），先建立整体地图再深入细节。（来源：gitnexus-exploring）
4. **概念查询与执行流定位（Query → processes）**——用 `gitnexus_query({query: "<想要理解的内容>"})` 找相关执行流，从返回的 processes 中识别嫌疑符号（按流程分组、附文件位置）。（来源：gitnexus-exploring）
5. **符号 360 度深挖（Context deep dive）**——对关键符号用 `gitnexus_context({name: "<符号>"})` 查看调用方/被调用方与参与的执行流；需要自定义调用链追踪时用 `gitnexus_cypher`（先读 `schema` 资源）。（来源：gitnexus-exploring、gitnexus-guide）
6. **源码确认（Read source to confirm）**——图谱结果只是导航：READ `gitnexus://repo/{name}/process/{name}` 追逐步执行流后，必须再读源码文件确认实现细节才能下结论。（来源：gitnexus-exploring）
7. **环境检查（Environment check）**——环境检查环节先确认项目根存在 `analysis_options.yaml`，再跑 `dart analyze` 确认零诊断（需 info 级也算失败则加 `--fatal-infos`），把项目静态健康度记入报告。（来源：dart-run-static-analysis）
8. **报告输出（Structured report）**——调研报告结论先行：每条结论附文件路径、行号与调用链引用，明确结论与推测的边界，并给出可供下游专家直接执行的入口建议。（来源：gitnexus-exploring、gitnexus-debugging）

### 调研陷阱清单

- 基于过期索引出结论（必须先 `npx gitnexus analyze`）（来源：gitnexus-cli、gitnexus-guide）
- 图谱导航结果当最终结论、不读源码确认（来源：gitnexus-exploring、gitnexus-debugging）
- 跳过 context/clusters 总览直接扎进细节（来源：gitnexus-exploring）
- 未读 schema 资源就写 cypher 查询（来源：gitnexus-guide）
- 未确认 analysis_options.yaml 就跑静态分析，环境结论不可复现（来源：dart-run-static-analysis）

---

## 三、全栈工程师执行工作流

**角色定位**：全栈工程师的官方职责为实现和修改前后端代码，处理跨栈或通用编码任务。以下工作流提炼自 flutter-apply-architecture-best-practices、flutter-implement-json-serialization、dart-use-pattern-matching、flutter-setup-localization、flutter-setup-declarative-routing、flutter-build-responsive-layout、dart-resolve-package-conflicts 等编码实现类技能。

1. **架构定位先行（Layer first）**——实现/修改功能前先确定分层归属：UI 层走 MVVM（精简 View + 继承 `ChangeNotifier` 且暴露不可变状态的 ViewModel）；Data 层走 Repository 模式（Service 无状态封装外部 API，Repository 作为单一数据源并转换为 Domain Model）；Use Case 层仅在复杂业务逻辑出现时才引入；永不混合 UI 渲染与业务逻辑或数据获取。（来源：flutter-apply-architecture-best-practices）
2. **功能实现顺序（Sequential workflow）**——按固定顺序推进：定义不可变 Domain Model → 实现 Service → 实现 Repository → 条件判断是否需要 Use Case（简单 CRUD 直接跳过）→ ViewModel（构造器注入 Repository，暴露状态与命令方法）→ View（`ListenableBuilder` 监听）→ 依赖注入容器注册（provider / get_it）→ 跑验证器。（来源：flutter-apply-architecture-best-practices）
3. **数据序列化（Type-safe JSON）**——模型实现 `fromJson` 工厂构造器与 `toJson` 方法（`dart:convert`）；`jsonDecode` 的 dynamic 结果必须显式转型为 `Map<String, dynamic>` / `List<dynamic>`；HTTP 状态码不成功时抛异常而非返回 null；大负载（解析 > 16ms）用 `compute()` 移交后台 isolate。（来源：flutter-implement-json-serialization）
4. **模式匹配优先（Pattern matching）**——JSON 校验与解构用 Map/List 模式；多返回值用 Record 模式解构；`sealed` 类配合 Object 模式保证穷举；产出值用 switch 表达式，产出副作用用 switch 语句；模式表达不了的逻辑用 `when` 守卫。（来源：dart-use-pattern-matching）
5. **路由与国际化基建（Routing & l10n）**——需要深链/浏览器历史时用 `go_router` + `MaterialApp.router`（`redirect` 处理状态路由、`errorBuilder` 兜底、`StatefulShellRoute.indexedStack` 实现嵌套导航）；国际化按四步：加 `flutter_localizations` / `intl` 依赖 → 启用 `generate: true` → 建 `l10n.yaml` → MaterialApp 注入 `AppLocalizations.delegate` 与三个 Global delegates。（来源：flutter-setup-declarative-routing、flutter-setup-localization）
6. **响应式布局（Adaptive layout）**——用 `LayoutBuilder` 按 `constraints.maxWidth` 断点（如 600）分支布局；大屏用 `ConstrainedBox` + `Center` 限宽防拉伸；长列表一律 `ListView.builder` / `GridView.builder` 懒渲染；一切布局决策基于可用窗口空间。（来源：flutter-build-responsive-layout）
7. **依赖冲突解决（Surgical fix）**——`pub get` 失败时打开 `pubspec.lock`，只外科式删除冲突包条目 → `dart pub get` 拉最新兼容版本 → `dart pub deps` 验证依赖图解析；失败则定位锁死的传递依赖并更新其约束后重试。（来源：dart-resolve-package-conflicts）
8. **验证反馈回路（Validate → Review → Fix loop）**——每步完成跑验证器（`dart analyze` / 单元测试）→ 审读类型不匹配与失败堆栈 → 修复 → 重跑直到通过；自动修复先 `dart fix --dry-run` 预览再 `--apply`；sealed 类 switch 报 "not exhaustively matched" 则补齐缺失模式或通配符。（来源：flutter-apply-architecture-best-practices、flutter-implement-json-serialization、dart-use-pattern-matching、dart-run-static-analysis）

### 编码实现陷阱清单

- UI 渲染与业务逻辑/数据获取混写、View 里做数据请求（来源：flutter-apply-architecture-best-practices）
- `jsonDecode` 的 dynamic 结果不显式转型；HTTP 失败返回 null 而非抛异常（来源：flutter-implement-json-serialization）
- 大负载在主线程同步解析导致 UI 卡顿（应 `compute()`）（来源：flutter-implement-json-serialization）
- 删除整个 `pubspec.lock` 再 `pub get`（全依赖图不受控升级）（来源：dart-resolve-package-conflicts）
- 用屏幕方向或硬件类型（"手机"/"平板"）而非窗口空间判断布局；锁屏幕方向（来源：flutter-build-responsive-layout）
- sealed 类/枚举的 switch 不保证穷举性（来源：dart-use-pattern-matching）

---

## 四、QA 执行工作流

**角色定位**：QA 的官方职责为运行测试构建流程，收集并整理验证结果与证据。以下工作流提炼自 dart-run-static-analysis、dart-add-unit-test、dart-generate-test-mocks、flutter-add-widget-test、flutter-add-integration-test、dart-collect-coverage、flutter-mcp-cli-runtime-validation 等测试/验证类技能。

1. **静态分析门禁（Cheapest gate first）**——先跑 `dart analyze` 确认零诊断（需 info 级也算失败则加 `--fatal-infos`）；自动修复先 `dart fix --dry-run` 预览并审查提议修复与目标架构一致，再 `--apply`，随后 `dart format .` 并重跑分析验证。（来源：dart-run-static-analysis）
2. **单元测试组织与执行（Unit test）**——测试文件镜像 `lib/` 结构、后缀 `_test.dart`；`group()` 分组、`setUp()/tearDown()` 管理夹具；选对运行器：纯 Dart 用 `dart test`，Flutter 用 `flutter test`，集成测试需显式指定目录（默认运行器会忽略）。（来源：dart-add-unit-test）
3. **外部依赖隔离（Mock generation）**——被测类依赖外部服务（API/数据库）时用构造器注入 + `@GenerateNiceMocks([MockSpec<T>()])`，`dart run build_runner build` 生成 mock；`when()` stub → 执行被测方法 → `verify()` + `expect()`；返回 Future/Stream 的方法永远用 `thenAnswer((_) async => ...)`。（来源：dart-generate-test-mocks）
4. **组件级 Widget 验证（Widget test）**——`testWidgets` + `Finder` / `Matcher` 按九步验证：`pumpWidget` 构建（需要时包 MaterialApp/Directionality）→ expect 初始状态 → `tap` / `enterText` / `drag` 模拟交互 → `pump()`（单帧）或 `pumpAndSettle()`（动画/异步）重建树 → 再 expect；动态长列表先 `scrollUntilVisible` 滚入目标再交互。（来源：flutter-add-widget-test）
5. **端到端集成测试（Integration test）**——先用 MCP 交互探索 UI 路径，再固化为 integration_test：加依赖 → `runApp` 前注入 `enableFlutterDriverExtension()` → 关键 widget 加 `ValueKey` → 编写测试 → 按目标平台执行 `flutter drive`；失败按映射修复（`PumpAndSettleTimedOutException` → 查无限动画；widget not found → 懒加载未滚动入屏）。（来源：flutter-add-integration-test）
6. **运行时冒烟验证（Runtime validation）**——应用级运行时验证：debug 启动 → 单条 `validate-runtime` 命令（带 `--target`、`--timeout-ms`、`--after-reload`、`--save-images`）→ 以 `data.summary` 判 pass/fail、`data.steps` 作逐步证据、`data.doctor.checks` 解释阻塞项；doctor critical 项与 4 个 toolkit extension 为必须证明事项。（来源：flutter-mcp-cli-runtime-validation）
7. **覆盖率证据（Coverage）**——`dart pub add dev:coverage` 后 `dart run coverage:test_with_coverage`，验证 `coverage/coverage.json` 与 `coverage/lcov.info` 生成；目标文件缺失则确认被测试导入执行，或显式 `// coverage:ignore-file`。（来源：dart-collect-coverage）
8. **验证反馈回路与证据固化（Evidence & claim ceiling）**——跑测试 → 审读失败堆栈 → 修实现或断言 → 重跑直到通过；交付测试输出、覆盖率报告、validate-runtime JSON summary 作为证据；未验证或无法插桩的项不得声称通过，如实声明「检查不可用/未证明」。（来源：dart-add-unit-test、flutter-add-widget-test、flutter-mcp-cli-runtime-validation、mcp-harness-repo-maintainer）

### QA 陷阱清单

- 静态分析或结构门禁通过就声称行为已被证明（来源：skill-eval-improve、mcp-harness-repo-maintainer）
- 对异步 stub 用 `thenReturn`（应用 `thenAnswer`）（来源：dart-generate-test-mocks）
- 交互后忘记 `pump()` / `pumpAndSettle()` 重建树就断言（来源：flutter-add-widget-test、flutter-add-integration-test）
- 集成测试用默认运行器不显式指定目录（来源：dart-add-unit-test）
- coverage 包放进主依赖；隐式漏测而非显式 ignore（来源：dart-collect-coverage）
- 应用无法插桩时仍声称运行时检查成功（来源：flutter-mcp-cli-runtime-validation）

---

## 五、代码审查员执行工作流

以下「Code Review 工作流模板」综合 6 篇审查类技能（skill-authoring-lifecycle、skill-eval-improve、mixture-of-experts、flutter-mcp-boundary-audit、gitnexus-impact-analysis、mcp-harness-repo-maintainer）的共同结构抽取而成。

1. **改动前影响面评估（Blast radius first）**——审查非平凡改动前先跑 impact 分析：d=1 直接依赖者（WILL BREAK）逐一核对，按受影响符号数/流程数/关键路径定 LOW → CRITICAL 风险级；提交前用 detect_changes 映射 git diff 到受影响执行流。（来源：gitnexus-impact-analysis）
2. **跑最便宜的门禁层（Cheapest gate first，不许跳过 Layer 0）**——分层评估：lint/validate（秒级）→ 规则用例（秒级）→ 静态结构分析 → 人工行为验证（分钟级）→ 基准测量。用能回答问题的最便宜层级；机械门禁（linter、validate、schema 校验）先行，错误消息应教会修复方法。（来源：skill-eval-improve、mcp-harness-repo-maintainer）
3. **结构与契约清单审查（Checklist-driven audit）**——按固定清单逐项勾选：结构/命名/元数据合规；正文有清晰编号工作流且不超长；脚本可运行；注册项齐备。契约类改动追加边界审计：对每个触碰的工具追踪 authoring → discovery → validation → execute，确认每条网关都在 execute 前 validate 且 fail-closed，双路径模式一致，无空/宽松占位模式。（来源：skill-authoring-lifecycle、flutter-mcp-boundary-audit）
4. **多视角交叉审查（Multi-lens critique）**——复杂/高风险改动派生 2–3 个正交专家视角（各带 Role/Scope/Out of scope/Expected output/Fallback 契约），独立审查后交叉比对找结构性矛盾与维护陷阱；视角缺位时降级置信并显式标注（missing/partial/timed_out lens）。（来源：mixture-of-experts）
5. **行为验证（Real-run proof，不止静态）**——实质性修改必须跑真实场景：3–5 个代表性用例（含应触发与不应触发的负例），改前基线 vs 改后对比，60/40 训练/留出拆分；正向测试用全新执行线程，不泄漏预期答案。（来源：skill-eval-improve、skill-authoring-lifecycle）
6. **有界修改纪律（Bounded edits）**——审查引发的修改受预算约束：≤10% 行变动或一个新章节，禁止因单次失败整篇重写；先删/合并重复规则再考虑新增；只有留出集改善才保留修改。（来源：skill-eval-improve）
7. **证据分级与诚实声明（Proof levels & non-claims）**——每项结论声明证据等级与适用范围：区分「可发现性证明/冒烟通过/持久证明」；写明 limitations 与 non_claims；一次漂亮证明不得升格为「全面采纳/完全通过」；CI 不放主观 LLM judge。（来源：mcp-harness-repo-maintainer、skill-eval-improve）
8. **固定格式审查报告（Structured output）**——结论先行、证据附后：`Summary: pass | needs changes` → `Errors (blocking)` → `Warnings`；每条 finding 带 Severity（P0/P1/P2）、边界/网关归类、涉及文件、症状（期望 X vs 实际 Y）、修复建议、Proof（测试名或 grep 命令）；以唯一处置决定收尾（chat_only / promote_to_artifact / convert_to_check / compress_existing / delete_or_retire / leave_native）。（来源：skill-authoring-lifecycle、flutter-mcp-boundary-audit、mixture-of-experts）

### 通用审查陷阱清单

- 只做静态分析从不跑真实用例
- 通过结构门禁就声称行为已被证明
- 无留出集的自我修改（过拟合）
- 一次观察就加规则/工具（删除或更小的 FAQ 就能解决时）
- 校验只存在于测试或单一路径
- 把咨询性发现当作执行授权
- 泄漏预期答案进验证 prompt

---

## 六、UI 操作者执行工作流

**角色定位**：UI 操作者的官方职责为浏览器与 UI 端到端验证、可视化 Bug 复现。以下工作流提炼自 flutter-mcp、flutter-mcp-toolkit-inspect、flutter-mcp-toolkit-control、flutter-fix-layout-issues、apple-ui-designer 等 UI 交互/检视类技能。

1. **预检（Preflight / doctor）**——永远先跑 `doctor` 预检确认 debug 目标可达；确认目标存在 4 个必备 toolkit extension（`app_errors` / `view_details` / `view_screenshots` / `inspect_widget_at_point`），缺失则停下报告插桩缺口并给出精确修复（加依赖 → `runApp` 前初始化 → hot restart）。（来源：flutter-mcp、flutter-mcp-cli-runtime-validation）
2. **只读当前状态（Inspect first）**——优先 `batch` 一次往返取 `semantic_snapshot` + `get_app_errors(count:5)` + `get_screenshots(mode: flutter_layer)`；读快照的 `interactionSurface` 判定界面类型（`flutter_widgets` 可按 ref 点击 / `hybrid` 语义稀疏 / `game_canvas` 改用表达式求值 + 截图）；按坐标用 `inspect_widget_at_point(x, y)` 找该处最深 widget。（来源：flutter-mcp-toolkit-inspect）
3. **定位目标元素（Locate by snapshot）**——`semantic_snapshot` 按 label/value/hint/tooltip/key/flags 过滤找 ref；屏幕外目标用 `reveal_search`（有界的 snapshot → match → scroll 循环）。（来源：flutter-mcp-toolkit-control、flutter-mcp）
4. **以用户方式驱动交互（User-like interaction）**——所有交互调用带 `snapshotId`，树变化时得到结构化 `stale_snapshot` 提示重新快照；`navigate(push)` 后必 `wait_for(text 谓词)` 等新路由渲染；批量输入用 `fill_form` 一次往返；`press_key` 无 Back 键，用 `navigate(pop)` / `handle_dialog(dismiss)` / `Escape` 替代。（来源：flutter-mcp-toolkit-control）
5. **Hot reload 验证闭环（Hot reload validation）**——代码编辑后优先 `hot_reload_and_capture` 一次返回 reload 状态 + 截图 + 新快照 + 错误；`compilation_error` 即验证不通过的信号；hot reload 后必等树稳定（`wait_for stable`）再取证。（来源：flutter-mcp、flutter-mcp-toolkit-control）
6. **视觉判据（Visual acceptance criteria）**——按 Apple 风格设计判据审视视觉问题：系统优先字体、用尺寸与权重而非颜色建立层级、中性调色板与克制的 accent、安全区默认感知、舒适触控目标、底部 sheet 优先模态；动效应解释层级而非装饰，疑惑时跟随 iOS 系统默认。（来源：apple-ui-designer）
7. **布局问题复现与定性（Layout repro）**——debug 模式抓 console 精确布局异常；识别主错误，忽略级联的 "RenderBox was not laid out"（沿堆栈向上找主约束违规）；以红/灰错误屏与黄黑溢出条纹消失为视觉判据，出现新布局错误则重复流程。（来源：flutter-fix-layout-issues）
8. **证据固化与诚实声明（Evidence & claim ceiling）**——UI 断言证明物 = 改动前后截图对比（before 用 `capture_ui_snapshot`，编辑后 `hot_reload_and_capture`）；每个视觉问题附坐标 + `inspect_widget_at_point` 输出；目标无法插桩时明确报告不可用，不得声称截图/布局/错误检查成功。（来源：flutter-mcp）

### UI 操作陷阱清单

- 带过期 snapshotId / ref 交互（ref 仅对最新快照有效）（来源：flutter-mcp-toolkit-control）
- 用 debug 技能读屏幕内容（应用 inspect）；用只读 inspect 做交互驱动（那是 control 职责）（来源：flutter-mcp-toolkit-debug、flutter-mcp-toolkit-inspect）
- navigate / hot reload 后不等渲染/树稳定就快照断言（来源：flutter-mcp-toolkit-control）
- 把级联布局错误当主因修（来源：flutter-fix-layout-issues）
- 以重渐变、霓虹色、生硬边框等花哨效果作为视觉验收标准（来源：apple-ui-designer）
- 在无法插桩的目标上虚构截图/布局/错误检查结果（来源：flutter-mcp）

---

## 七、故障诊断工程师执行工作流

以下「通用 Debug 诊断工作流模板」综合 15 篇 Debug / 验证类技能的共性结构抽取而成：**Preflight → 取证 → 分类 → 定位 → 条件修复 → 验证反馈回路 → 证据固化 → 边界声明**。

1. **预检（Preflight / doctor）**——任何依赖环境的操作前先跑健康检查（`doctor --json` / 确认工具在 PATH / 确认 debug 模式），确认 critical 检查项通过；失败则先修环境，不带病诊断。（来源：flutter-mcp、flutter-mcp-toolkit-setup、flutter-mcp-cli-runtime-validation）
2. **插桩完整性门禁（Instrumentation gating）**——确认目标具备必需的可观测 extension / 日志通道；缺失时停下报告缺口并给出精确修复（加依赖 → `runApp` 前初始化 → hot restart），绝不猜测。（来源：flutter-mcp、flutter-mcp-cli-runtime-validation）
3. **取证（Evidence collection，顺序固定）**——按「错误码/异常签名 → 日志（按时间戳找 stack trace 与 assertion）→ 运行态求值 → 语义快照/截图」顺序采集；识别主错误，忽略级联次生错误（如 "RenderBox was not laid out"）。（来源：flutter-mcp-toolkit-debug、flutter-fix-layout-issues、flutter-mcp-toolkit-inspect）
4. **分类分诊（Triage by code/signature）**——把错误映射到已知分类表：error envelope 按 `error.code` 查 playbook，先读 `error.descriptor.retryable` 决定可否重试；布局错误按错误签名匹配修复方案；症状（错误消息/返回值错/间歇失败/性能/回归）映射到不同追踪手法。（来源：flutter-mcp-toolkit-debug、flutter-fix-layout-issues、gitnexus-debugging）
5. **定位根因（Root cause tracing）**——用调用链工具追 callers/callees 与执行流；用 `get_app_errors` 顶层 stack frame（file/line/column）把缺陷映射回源码；图谱导航之后必须读源码确认。（来源：gitnexus-debugging、flutter-mcp）
6. **条件修复（Conditional fix）**——按错误类型走 if/else 分支修复（null safety → `?.` / `??` / `late`；类型不匹配 → 显式泛型；版本冲突 → 外科式删 lockfile 单条目）；优先自动修复（`dart fix --dry-run` 预览后 `--apply`），手动只处理剩余项。（来源：dart-fix-runtime-errors、dart-resolve-package-conflicts）
7. **验证反馈回路（Validate → Review → Fix loop）**——统一的收口模式：运行验证器（`dart analyze` / `dart test` / hot reload / `flutter drive` / validate-runtime）→ 审读输出 → 未过则按失败类型映射的处置再修 → 重跑直到通过。hot reload 后必须等树稳定（`wait_for stable`）再取证；UI 修复必须有改动前后截图对比。（来源：全部验证类技能）
8. **证据固化与诚实声明（Evidence & claim ceiling）**——产出前后截图、错误码回执、stack frame 行号、测试输出、JSON summary 作为证明物；可重试错误只重试一次，复发即上报（附 `error.details`）；无法插桩/验证被跳过时如实报告「检查不可用/未证明」，不得声称成功。（来源：flutter-mcp-toolkit-debug、flutter-mcp、mcp-harness-repo-maintainer）

### 通用陷阱清单

- 把级联错误当主因
- 无留出验证就宣布修复
- 用 hot reload 代替 hot restart 注册 extension
- 带过期 snapshotId/ref 交互
- 删整个 lockfile
- catch `Error`
- 对异步 stub 用 `thenReturn`
- 在无法插桩的目标上虚构检查结果

---

## 八、Lead Agent 调度职责（简述）

官方契约对 Lead Agent 的定义为：**理解需求、拆解任务、协调调度、质量把关**，动态拉起专家并行执行，且该角色**不支持自定义**（见第一章分工契约表）。

本文档不为其编写详细执行工作流，原因如下：

1. **无素材可依**：本文档各工作流均提炼自项目技能库 `SKILL.md` 原文；官方未公开 Lead Agent 的系统提示词，技能库中亦无对应的调度类技能可供逆向提炼，按「不得杜撰」原则不编写。
2. **无注入通道**：frontmatter 四字段定制（`model` / `additionalPrompt` / `skills` / `mcpServers`）仅对可定制的内置专家生效；Lead Agent 不支持自定义，即使编写工作流模板也无注入途径。
3. **质量把关标准可引用各章**：其质量把关职责落地为对各专家产出的验收——即第二至七章各工作流末尾的验证反馈回路与证据固化要求（证据齐备、声明不超出证明范围、未验证项诚实声明），验收时直接引用对应章节即可。

---

## 九、技能卡片速查

以下速查表收录调研报告精读的 21 个技能（其中 dart-add-unit-test 与 dart-collect-coverage 合并为一张卡片），以及本次补充工作流时新增精读并收录的 11 个技能（flutter-add-widget-test 补入 9.3，其余见 9.5–9.7）。每卡保留：核心任务一句话、关键工作流步骤摘要、判断标准、关键禁忌。

### 9.1 Debug / 故障诊断类

#### dart-fix-runtime-errors

- **核心任务**：通过「取堆栈 → 定位失败行 → 修复 → hot reload 验证」的闭环解决 Dart 静态分析与运行时错误。
- **工作流摘要**：`dart analyze . --fatal-infos` 定位全部错误 → `dart fix --dry-run` 预览后 `--apply` 自动修复 → 手动按类型分支处理剩余项（Null Safety：可能合法为 null 用 `?.`/`??`，初始化有保证用 `late`；类型不匹配：追溯初始化处补显式泛型如 `<int>[]`；非法 Override：放宽参数类型或显式 `covariant`）→ `dart analyze` + `dart test` 验证，未过则回退再修。
- **判断标准**：`dart analyze` 零错误、`dart test` 通过；`dart test` 失败且为 `TypeError` → 判定为修复本身引入的新缺陷。
- **关键禁忌**：永不显式 catch `Error` 及其子类型（`TypeError`、`ArgumentError`），错误必须修复而非捕获（建议启用 `avoid_catching_errors`）；避免隐式向下转型，禁止把 `List<dynamic>` 赋给类型化列表；用 `rethrow` 而非裸 `throw e` 保留原始堆栈。

#### flutter-mcp-toolkit-debug

- **核心任务**：运行中 Flutter 应用的故障分诊中枢——读日志、求值运行态、解析 error envelope（结构化错误返回体）。
- **工作流摘要（Triage flow）**：error envelope 先读 `error.code` 再读 `error.descriptor.retryable`（可重试性以 descriptor 为准）查 playbook → 可重试错误跑 `flutter-mcp-toolkit doctor --json`，失败转 setup → 需日志用 `get_recent_logs(count: 100)` 加级别过滤，按故障时间戳找 stack trace / assertion → 需运行态用 `evaluate_dart_expression`（先日志后求值）→ 与 inspect 链式使用固定顺序 `semantic_snapshot` → `evaluate_dart_expression` → `get_recent_logs` → 多目标返回 `connection_selection_required` 时调 `discover_debug_apps` 选 `targetId`，后续每次调用带 `connection`。
- **判断标准**：playbook 含 40+ 错误码的 Means/Causes/Recovery 三段式条目（如 `hotReloadFailed` → 先 `get_app_errors` 修编译错误再重试；`staleSnapshot` → 先求值验证应用可达再重新快照）；统一兜底命令 `doctor --json`，envelope 提供 `error.recovery.fix_command` 则直接执行。
- **关键禁忌**：不用本技能读屏幕内容（用 inspect）、不处理工具连不上（用 setup）；`evaluate_dart_expression` 在活 isolate 执行任意代码，避免副作用表达式且仅 Debug 模式可用；`get_recent_logs` 只返回自上次启动/hot restart 以来的缓冲行；目标变化后必须重新 discover，过期 URI 返回 `connect_failed`。

#### flutter-mcp

- **核心任务**：驱动运行中 Flutter 应用的黄金路径总纲——预检、交互循环、hot reload 验证与 error envelope 解析。
- **工作流摘要**：预检永远第一步（`doctor` / `flutter-mcp-toolkit doctor --json`）→ 确认目标存在 4 个必备 toolkit extension（`ext.mcp.toolkit.app_errors`、`view_details`、`view_screenshots`、`inspect_widget_at_point`），缺失则停下报告插桩缺口，修复三步：加 `mcp_toolkit` 依赖、`MCPToolkitBinding` 在 `runApp` 前初始化、hot restart（不是 reload）→ 交互循环：`semantic_snapshot` 取 ref + snapshot_id → 带 `snapshotId` tap/enter/scroll（树移动得结构化 `stale_snapshot`）→ `reveal_search` 找屏幕外目标 → `evaluate_dart_expression` 直读状态 → 代码编辑后优先 `hot_reload_and_capture`（一次返回 reload 状态 + 截图 + 新快照 + 错误）。
- **判断标准**：UI 断言证明物 = 改动前后截图对比（before 用 `capture_ui_snapshot`，编辑后 `hot_reload_and_capture`）；每个视觉问题附坐标 + `inspect_widget_at_point` 输出；缺陷定位到源码用 `get_app_errors` 顶层 stack frame（file/line/column）。
- **关键禁忌**：不使用 `debug_dump_*` 除非用户明确要求；目标无法插桩时明确报告不可用，不得声称截图/布局/错误检查成功；空截图先查服务端是否 `--no-images` 启动；工具名必须带 `fmt_` 前缀（v3.0.0 起）。

#### flutter-mcp-cli-runtime-validation

- **核心任务**：以最少操作步骤完成 agent 级端到端运行时验证（启动应用 → 一键 validate-runtime）。
- **工作流摘要**：debug 模式启动应用 → 单条 `validate-runtime` 命令（带 `--target ws://...`、`--timeout-ms`、`--after-reload`、`--save-images`）→ 逐条核对「必须证明」清单 → 按 Failure Rules 处理失败；首次显式 URI 连接失败时 retryable 连接错误自动重试。
- **判断标准（必须证明的事项）**：doctor 预检通过 critical 项；4 个必备 toolkit extension 全部存在；截图采集成功、view details 可用、app errors 可取回；启用 `--after-reload` 时 reload 后截图也成功；以 `data.summary` 为 pass/fail，`data.steps` 提供逐步证据，`data.doctor.checks` 解释 setup 阻塞项。
- **关键禁忌**：extension 缺失 → 停下报告插桩缺口 + 给出精确修复；截图空白 → 确认窗口可见后重试；应用无法插桩 → 不得声称检查成功；Challenge Cases 须显式指出（无 debug 应用、错误 URI/token、加 toolkit 仍缺 extension 需 hot restart、不可修改应用）。

#### flutter-mcp-toolkit-setup

- **核心任务**：工具链自身的安装验证、doctor 预检与连接问题排障。
- **工作流摘要**：验证安装（`flutter-mcp-toolkit --help` 与 `fmtk --help` 双名可用，command not found 则加 PATH 或 `make build` 重建）→ 依赖 VM 的命令前必跑 `fmtk doctor --json`（支持 `--target`、`--timeout-ms`）→ 分诊（`criticalFailures > 0` 表示 VM/setup 被阻塞；`dynamic_registry_available: pass` 但 `vm_target_reachable: fail` 常为 hot restart 后过期 URI → 重新 `discover_debug_apps`）→ 按错误码恢复（`binary_not_found`/`vm_not_connected`/`connect_failed`/`connection_selection_required`/`hot_reload_failed`/`visual_capture_unsupported`）→ 深度排障（端口冲突换 `--host-vmservice-port`；release/profile 无 VM service 必须 `--debug`；toolkit 未初始化用 `codegen-init` 生成样板后 hot restart）。
- **判断标准**：doctor 绿色 = `summary.criticalFailures: 0` 且 `vm_target_reachable`、`mcp_toolkit_extensions` 两个 critical 检查 pass；每个检查项自带 `fix_command`；重试策略与退出码读 `error.descriptor`。
- **关键禁忌**：`--target` 与全局 `--vm-service-uri` 同时设置时 `--target` 优先（stderr 告警）；不得把重复检查做成通用 MCP `run_tool`，可复用流程应沉淀为脚本或 `batch` 调用。

#### flutter-mcp-toolkit-inspect

- **核心任务**：运行中应用的只读状态检查——屏幕内容、最近错误、debug 目标、VM 元数据、widget 树。
- **工作流摘要**：快速检查循环优先 `batch` 一次往返（`semantic_snapshot` + `get_app_errors(count:5)` + `get_screenshots(mode: flutter_layer)`）→ 快照读 `interactionSurface` 判定界面类型（`flutter_widgets` 可按 ref 点击 / `hybrid` 语义稀疏 / `game_canvas` 改用表达式求值 + 截图）→ 按消息找错误（`get_app_errors(count: 10)` 逐条匹配 message/stack trace/timestamp）→ 按坐标找 widget（`inspect_widget_at_point(x, y)`）→ 代码编辑后优先 `hot_reload_and_capture` → 保存截图看 `meta.fileUrls` 非空即已落盘。
- **判断标准**：失败码明确——`vm_service_unavailable`（应用不可达）、`connection_selection_required`（多目标需 targetId）、`permission_denied`（以 `auto_request_once` 重试）、`invalid_argument`（坐标越界）。
- **关键禁忌**：只读检查不做交互驱动（那是 control 职责）；macOS 上优先 `mode: flutter_layer` 规避 Screen Recording 权限失败。

#### flutter-mcp-toolkit-control

- **核心任务**：以用户方式驱动运行中应用——tap、scroll、type、fill forms、hot-reload、navigate，含 hot reload 验证闭环。
- **工作流摘要**：定位用 `semantic_snapshot` 按 label/value/hint/tooltip/key/flags 过滤找 ref，屏幕外用 `reveal_search`（有界 snapshot→match→scroll 循环）→ 所有交互带 `snapshotId`，树变化返回 `stale_snapshot` → `navigate(push)` 后必 `wait_for(text 谓词)` 等新路由渲染 → hot reload 后必 `wait_for(stable, stableWindowMs: 300)` 或直接用 `hot_reload_and_capture` → 批量输入用 `fill_form` 一次往返。
- **判断标准**：hot reload 失败码 `vm_not_connected`、`compilation_error`（编译错误即 reload 验证不通过）；`wait_for` 超时（`timeout`）即判定 UI 状态未达预期。
- **关键禁忌**：`press_key` 无 Back 键，用 `navigate(pop)` / `handle_dialog(dismiss)` / `Escape` 替代；ref 仅对最新快照有效；hover 仅桌面/web；`swipe`/`drag` 在 web 有手势支持限制。

#### gitnexus-debugging

- **核心任务**：基于代码知识图谱的错误溯源与根因定位流程。
- **工作流摘要**：理解症状 → `gitnexus_query({query: "<错误或症状>"})` 找相关执行流 → 从 processes 识别嫌疑函数 → `gitnexus_context({name: "<嫌疑>"})` 查调用方/被调用方 → READ `gitnexus://repo/{name}/process/{name}` 追执行流 → 必要时 `gitnexus_cypher` 自定义调用链追踪 → 读源码确认根因（索引过期先 `npx gitnexus analyze`）。
- **判断标准（症状→手法映射）**：错误消息 → query 错误文本后 context 抛出点；返回值错误 → context 函数追被调用方数据流；间歇性失败 → 找外部调用/异步依赖；性能问题 → 找调用者众多的热点符号；近期回归 → `detect_changes` 看变更影响面。
- **关键禁忌**：图谱结果只是导航，必须读源码确认根因后才能下结论；索引过期会误导结果，先重建索引。

#### flutter-fix-layout-issues

- **核心任务**：按错误签名分类诊断并修复 Flutter 布局约束违规（overflows、unbounded constraints）。
- **工作流摘要**：debug 模式运行应用抓 console 精确布局异常 → 识别主错误，忽略级联的 "RenderBox was not laid out"（沿堆栈向上找主约束违规）→ 按类型修复（unbounded height → 可滚动子件包 `Expanded` 或 `SizedBox`；InputDecorator unbounded width → TextField 包 `Expanded`/`Flexible`；RenderFlex overflowed → 溢出子件包 `Expanded`（强制适配）或 `Flexible`（允许缩小）；ParentData widget 误用 → 移到正确父级的直接子级）→ hot reload → 验证红/灰错误屏与黄黑溢出条纹是否消失，出现新布局错误则重复。
- **判断标准**：核心模型「Constraints go down. Sizes go up. Parent sets position.」，约束协商失败即布局错误；视觉判据为错误屏/溢出条纹消失。
- **关键禁忌**：把级联错误 "RenderBox was not laid out" 当主因修——必须先找上游主违规。

### 9.2 静态分析 / 构建 / 依赖类

#### dart-run-static-analysis

- **核心任务**：开发中保障代码质量、提交前必跑的静态分析与自动修复流程。
- **工作流摘要**：确认项目根存在 `analysis_options.yaml`（含标准规则集 include 与 strict-casts/strict-inference/strict-raw-types）→ `analyze_files` MCP 工具或 CLI `dart analyze <target_directory>` → 审查诊断输出 → 需 info 级也当失败则追加 `--fatal-infos` → 自动修复：`dart fix --dry-run` 预览 → 审查提议修复与目标架构一致 → 确认对应 lint 规则已启用 → `dart fix --apply` → `dart format .` → 重跑静态分析验证。
- **判断标准**：`dart analyze` 无输出/零诊断即达标；info 级是否算失败由 `--fatal-infos` 显式决定。
- **关键禁忌**：抑制诊断必须显式进行（`// ignore:`、`// ignore_for_file:`、`analyzer: exclude:` glob），生成代码用 `**/*.g.dart` 排除；`linter: rules:` 下不得混用 list 与 map 语法。

#### dart-resolve-package-conflicts

- **核心任务**：依赖审计、升级与版本冲突的外科式解决（`pub get` 失败时使用）。
- **工作流摘要**：打开 `pubspec.lock` → 定位冲突或被撤回包的 YAML 块 → 只删除该包条目（外科式删除）→ `dart pub get` 拉取最新兼容版本 → `dart pub deps` 验证依赖图解析，失败则定位锁死的传递依赖并更新约束重试。升级流：按 `dart pub outdated` 审计分支（Upgradable → `dart pub upgrade` + `--tighten`；Resolvable 大版本 → 手改 pubspec 约束再 upgrade）→ `dart analyze` 修破坏性 API 变更 → `dart test` 修回归。
- **判断标准**：`dart pub deps` 依赖图解析成功；`dart pub outdated` 四列（Current/Upgradable/Resolvable/Latest）读懂后再决策。
- **关键禁忌**：**NEVER 删除整个 pubspec.lock 再 pub get**——会导致全依赖图不受控升级；约束用 caret 语法（`^1.2.3`）；CI 用 `--enforce-lockfile`。

### 9.3 测试与验证类

#### flutter-add-integration-test

- **核心任务**：先用 MCP 交互探索 UI，再把探索路径固化为可回归的集成测试。
- **工作流摘要**：Setup（加 `integration_test`/`flutter_test` 依赖；入口注入 `enableFlutterDriverExtension()` 于 runApp 前；关键 widget 加 `ValueKey`）→ Exploration（MCP `launch_app` 获取 DTD URI → `get_widget_tree` 发现 Key/Text/Type → `tap`/`enter_text`/`scroll` 验证交互路径 → 导航/动画用 `waitFor` 或 `get_health`；widget 找不到可能是懒加载，先 scroll/scrollIntoView 强制 mount）→ Authoring（`integration_test/app_test.dart`：`ensureInitialized` → `pumpWidget` → 交互 → `pumpAndSettle` → `expect`；加 `test_driver/integration_test.dart` 的 `integrationDriver()`）→ Execution（Chrome 需 chromedriver、headless 用 web-server、Android 本地、Firebase Test Lab 需双 APK）→ 审读输出按失败映射修复（`PumpAndSettleTimedOutException` 查无限动画；widget not found 加 `scrollUntilVisible`）→ 重跑直到通过。
- **判断标准**：`flutter drive` 全绿；失败分类映射明确（超时 → 无限动画；找不到 → 懒加载未滚动入屏）。
- **关键禁忌**：交互后必须 `pumpAndSettle`；遗留 flutter_driver 测试用 driver API 而非 WidgetTester。

#### dart-generate-test-mocks

- **核心任务**：为依赖外部服务（API/数据库）的类用 `package:mockito` + `build_runner` 生成 mock 并编写隔离单测。
- **工作流摘要（10 步）**：确定要 mock 的外部依赖 → 构造器注入 → 测试文件加 `@GenerateNiceMocks([MockSpec<T>()])` → 导入 `.mocks.dart` → `dart run build_runner build` 生成 → `group()`/`test()` 写用例 → `when()` stub → 执行被测方法 → `verify()` + `expect()` → `dart test`。
- **判断标准（失败反馈回路）**：mock 方法抛意外 null → 确认用了 `@GenerateNiceMocks`；异步 stub 抛 `ArgumentError` → `thenReturn` 改 `thenAnswer((_) async => ...)`；build_runner 失败 → 检查 `.mocks.dart` 导入名与文件名精确匹配；循环直至全部通过。
- **关键禁忌**：**CRITICAL**——返回 Future/Stream 的方法永远用 `thenAnswer`，绝不用 `thenReturn`。

#### dart-add-unit-test / dart-collect-coverage（合并卡片）

- **核心任务**：用 `package:test` 编写组织良好的单测并回归；用 coverage 包采集覆盖率产出 LCOV 报告。
- **工作流摘要**：测试文件镜像 `lib/` 结构、后缀 `_test.dart`，`group()` 分组、`setUp()/tearDown()` 管理夹具 → 选运行器（纯 Dart 用 `dart test`，Flutter 用 `flutter test`，集成测试需显式指定目录）→ 反馈回路：跑测试 → 审读失败堆栈 → 修实现或断言 → 重跑直到通过 → 覆盖率：`dart pub add dev:coverage` → `dart run coverage:test_with_coverage` → 验证 `coverage/coverage.json` 与 `coverage/lcov.info` 生成；细粒度控制走手动三步（VM service 跑测试 → collect_coverage → format_coverage --check-ignore）。
- **判断标准**：测试全绿；覆盖率文件存在且目标文件未缺失（缺失则确认被测试导入执行，或显式 `// coverage:ignore-file`）。
- **关键禁忌**：coverage 只能放 `dev_dependencies`；ignore 指令须显式而非隐式漏测。

#### flutter-add-widget-test

- **核心任务**：用 `WidgetTester` 实现组件级测试，验证 UI 渲染与用户交互（点击/滚动/输入）。
- **工作流摘要（9 步）**：`testWidgets` 定义测试 → `pumpWidget` 构建 widget（需要方向/主题数据时包 MaterialApp/Directionality）→ `Finder` 定位（`find.text` / `find.byType` / `find.byKey`）→ expect 初始状态 → 模拟交互（`tap` / `enterText` / `drag`）→ `pump()` / `pumpAndSettle()` 重建树 → expect 更新后状态 → `flutter test` 运行 → 反馈回路（审读失败 matcher → 修 widget 逻辑或断言 → 重跑）。
- **判断标准**：标准状态变化用 `pump()` 单帧；动画/过渡/异步 UI 更新用 `pumpAndSettle()` 泵帧至无新帧；动态长列表目标先 `scrollUntilVisible` 滚入屏再交互。
- **关键禁忌**：交互后不重建树就断言；测试文件不放 `test/` 目录或不以 `_test.dart` 后缀。

### 9.4 Code Review / 审计 / 治理类

#### skill-eval-improve

- **核心任务**：分层评估 + 有界修改 + 留出集门禁的可度量质量改进循环。
- **工作流摘要（分层评估栈，不许跳过 Layer 0）**：Layer 0 门禁 `pnpm run validate`（修掉所有 `error:`，认真对待 `warn:`）→ Layer 0b 规则 `pnpm run eval`（T1 行为关键技能的 YAML 用例）→ Layer 1 静态 `plugin-eval analyze` → Layer 2 人工（3–5 个代表性 prompt 在不带/带技能下运行对比，约 60% 训练集 / 40% 留出集）→ Layer 3 改进循环（基线 → 带技能对比 → 反思 1–3 个失败模式 → 有界修改 ≤10% 行变动或一个新章节 → 只重跑留出集，改进了才保留）→ Layer 5 运行时 dogfood（紧凑 trace 上定义确定性断言：期望动作轨迹、最大工具调用数、必需的 return_to_goal_step、负面检查）。
- **判断标准**：完成清单——validate 通过、T1 eval 用例更新、≥3 个 prompt eval 记录在案、有界修改且留出集改善、PR 说明 eval delta；典型修复顺序：name/description 路由 → 断链/缺 sources → 先删重复规则再加新内容 → 大块内容移入 references（SKILL.md < 500 行）→ 补错误处理步骤 → token 成本。
- **关键禁忌**：因一次失败重写整篇 SKILL.md；无留出集自编辑（过拟合）；一次观察就加规则/eval；只做静态分析从不跑真实 prompt；CI 中用 LLM judge；**通过 `pnpm run eval` 就声称 agent 行为已被证明**。

#### mcp-harness-repo-maintainer

- **核心任务**：以「薄适配器 + 厚核心」原则维护仓库级行动契约与验证体系，强调证据分级与诚实声明。
- **工作流摘要（冷启动证明循环 7 步）**：steward.yaml 声明 quick-safe 小契约（首个行动只检查状态不修改）→ 满足 quick 策略才暴露 probes（无确认、无 shell、无网络/机密/破坏性）→ 加场景清单 `steward/scenarios/*.yaml` → 跑证明循环：`doctor --json` → `schema check-outputs` → `schema drift` → `actions list` → `action inspect` → `probe --profile quick` → `benchmark --strict --output ...` → 诚实解读（doctor/actions 证明可发现性；benchmark 只有 `result: "pass"` 才算持久执行证明；`durability_blocked` 是真实受阻证据）→ 保护本地状态（strict 输入必须已跟踪且干净）→ 从证据成长（先捕获 unknown case；owner/影响/限制/脱敏/验证命令/基准证据齐备后才提升为 typed action；不得从发现问题的那次运行中直接提升诊断）。
- **判断标准（采纳成熟度阶梯 H0–H5）**：H0 技能已装 → H1 契约已声明 → H2 冒烟循环有持久 `result: "pass"` 基准 → H3 反馈循环积累 → H4 新 agent 无需 raw shell 摸索完成流程 → H5 重复证据（含留出基准）提升能力；「harness ready」声明前清单：agent 仅凭仓内文档能发现该跑什么、至少 H2、失败消息说明如何补救、契约门禁通过。
- **关键禁忌**：原始用户目标是验收标准，修复工具两次失败后停止修复、换原生命令、记录摩擦、回到任务；提升前先怀疑（原生命令/错误消息/FAQ/删除能否解决）；一次漂亮证明不得说成「完全采纳」，只说 capability-level H5 并点名能力；不得保存原始日志、机密、私有记忆作为证据。

#### skill-authoring-lifecycle

- **核心任务**：技能包的创建、正式评审与弃用生命周期，Phase 2 就是完整的 Code Review 清单。
- **工作流摘要（Phase 2 评审与审计清单）**：内聚性（覆盖完整旅程，抽象规则与机械工具捆绑）→ 结构（目录名 kebab-case 且与 frontmatter name 一致；文件名恰为 `SKILL.md` 大小写敏感；技能文件夹内不得有 README.md）→ Frontmatter（name 1–64 字符合规；description 说明能力与何时激活；license/version/author 齐备）→ 正文（清晰编号工作流；约 500 行内否则拆入 references/；相对链接一级深；外部声明有 sources.md 引用）→ 脚本（shebang、`set -euo pipefail`、stderr 记日志/stdout 机器可读；代表性脚本实际跑过或记录跳过原因）→ 注册（registry 条目、README 表格、validate 通过、T1 技能需 eval 用例）→ 前置测试（全新 subagent/线程 + 自然用户 prompt 正向测试；不得把预期答案、疑似 bug、计划修复泄漏进验证 prompt）。
- **判断标准**：每项清单项勾选制；`pnpm run validate` 零 error；T1 技能 `pnpm run eval` 通过；评审报告固定格式 `## Summary`（pass | needs changes）→ `## Errors (blocking)` → `## Warnings`。
- **关键禁忌**：不保留「墓碑」技能；重命名/合并按破坏性变更走 changeset 说明 why 与替代者。

#### mixture-of-experts

- **核心任务**：多专家视角并行审计 + 交叉比对，防止隧道视野。
- **工作流摘要**：确定审计主题 → 定义 2–3 个正交专家人设（默认上限 4），每个写所有权契约（Role / Scope / Out of scope / Expected output / Fallback / Integration contract）→ 派生子代理独立审计（无子代理能力时顺序执行并标注为非并行 MoE；只读视角保持只读）→ 交叉比对（找结构性矛盾、遗漏边缘情况、维护陷阱、意图重复；视角超时/部分证据时标注 `missing_lens`/`partial_lens`/`timed_out_lens`/`superseded_lens` 并给 lens-status 汇总表）→ 选择输出模式（只读批判 / 实施规划 / 执行需用户批准，跳过的验证必须记录未跑命令与未被证明的声明）→ 以关键发现与矛盾开头、唯一 disposition 收尾（chat_only / promote_to_artifact / convert_to_check / repeated 确定性真相转测试 / compress_existing / delete_or_retire / leave_native）。
- **判断标准**：紧凑规则「spawn for independence, synthesize for contradiction, persist only what changes future behavior」；lens-status 表（Lens / Status / Integration）在结果影响实施或就绪声明时必须给出。
- **关键禁忌**：不派生重复父计划的 agent；MoE 发现是咨询性输入，不授权写操作、不分配工作、不替代父级综合；只在下一步会改文件或扩大范围时才请求批准。

#### flutter-mcp-boundary-audit

- **核心任务**：契约/模式边界审计，专抓「客户端看到的 ≠ 运行时强制的」split-brain（脑裂）缺陷。
- **工作流摘要**：先填仓库适配的边界地图（Authoring / Discovery / Registry / Host gateway / Runtime callback / In-process / CLI / 共享模式模块 / Migrator / 平台文档）→ 对每个触碰的工具追踪 authoring → discovery → validation → execute 四段边界，逐行回答 14 项检查（规范输入模式是否到达注册描述类型？动态注册是否发送完整 inputSchema 而非 `{}`？每个网关是否 execute 前 validate？模式缺失是否 fail-closed？）→ 网关分歧检查（每条网关在 handler/execute/delegate 前校验且模式缺失即失败）→ 双路径一致性（对比 required 键、additionalProperties 严格度、host 独有字段、类型/枚举、默认值与 coercion；故意差异必须写进平台契约文档）→ Red-flag grep（`additionalProperties: true`、`schema: {}`、无 validate 的 `.execute(`、直接 invoke 旁路、迁移器剥离模式、重复注册、陈旧 "always permissive" 文档）→ E2E 证明（缺 required 调用得结构化失败、严格模式下额外属性同样失败、双路径都验证）。
- **判断标准**：Red flag——校验只存在于测试里/只在 catalog 路径/只在 listing 而非改动实际使用的路径；每项发现须附 Proof（测试名或 grep 命令）；报告固定模板含 Finding 标题、Severity（P0/P1/P2）、Boundary、Gateway、Files、Symptom（期望 X vs 实际 Y）、Fix、Proof。
- **关键禁忌**：审计前必须先填仓库适配地图；完成审计后补 2–3 条仓库专属 red-flag grep；不重开已完成项除非回归。

#### gitnexus-impact-analysis

- **核心任务**：改动前爆炸半径评估与风险分级（Code Review 的前置安全分析）。
- **工作流摘要**：`gitnexus_impact({target, direction: "upstream"})` 找依赖方 → 先看 d=1 项（一定会坏）再看高置信度（>0.8）依赖 → READ processes 检查受影响执行流 → 提交前 `gitnexus_detect_changes()` 把 git 变更映射到受影响流程 → 评估风险级别并报告（索引过期先 `npx gitnexus analyze`）。
- **判断标准（量化分级）**：深度——d=1 WILL BREAK（直接调用方/导入方）、d=2 LIKELY AFFECTED、d=3 MAY NEED TESTING；影响面——<5 符号少量流程 LOW、5–15 符号 2–5 流程 MEDIUM、>15 符号或多流程 HIGH、关键路径（auth、payments）CRITICAL；产出带文件行号与置信度的依赖清单（如 `loginHandler (src/auth/login.ts:42) [CALLS, 100%]`）。
- **关键禁忌**：d=1 必须逐一核对；提交前检查是强制节点。

---

### 9.5 调研 / 代码库探索类

#### gitnexus-exploring

- **核心任务**：基于代码知识图谱理解代码行为、架构与执行流（"How does X work?" / "What calls this function?"）。
- **工作流摘要**：READ `gitnexus://repos` 发现已索引仓库 → READ `repo/{name}/context` 取概览并检查新鲜度（报 stale 先 `npx gitnexus analyze`）→ `gitnexus_query` 找概念相关执行流 → `gitnexus_context` 对关键符号取 360 度视图（incoming/outgoing calls、参与的 processes）→ READ `process/{name}` 追完整执行流 → 读源码文件确认实现细节。
- **判断标准**：按清单逐项勾选执行；clusters / cluster 成员为轻量读取（约 100–500 tokens），用于先建整体地图再深入。
- **关键禁忌**：图谱结果只是导航，必须读源码确认后才能下结论；不得跳过 context 新鲜度检查。

#### gitnexus-cli

- **核心任务**：GitNexus CLI 的索引构建/刷新、状态检查、清理与 wiki 生成（均经 npx，无需全局安装）。
- **工作流摘要**：`npx gitnexus analyze` 构建/刷新索引（项目根运行；`--force` 强制全量；`--embeddings` 启用语义搜索，默认关）→ `status` 查看索引新鲜度与符号/关系数量 → `clean` 删索引（损坏后重建前用）→ `wiki` 从图谱生成文档（需 API key）→ 索引后读 context 资源验证已加载。
- **判断标准**：analyze 运行时机 = 首次进项目 / 重大代码变更后 / context 报过期；重分析后仍报 stale 需重启 MCP 服务端重载。
- **关键禁忌**：embedding 生成默认关闭且慢，不要随意开启；必须在 git 仓库内运行（否则 "Not inside a git repository"）。

#### gitnexus-guide

- **核心任务**：GitNexus 工具/资源/图谱 schema 的总入口与速查——任何代码理解、调试、影响分析、重构任务由此起步。
- **工作流摘要（Always Start Here）**：先读 `gitnexus://repo/{name}/context`（概览 + 新鲜度检查，报 stale 先 `npx gitnexus analyze`）→ 按任务映射表选子技能（exploring / impact-analysis / debugging / refactoring / cli）→ 读该技能文件并遵循其工作流与清单。
- **判断标准**：工具速查表（query / context / impact / detect_changes / rename / cypher / list_repos）与资源速查表（约 100–500 tokens 的轻量导航读取）；图谱 schema：节点 File/Function/Class/Interface/Method/Community/Process，边 CALLS/IMPORTS/EXTENDS/IMPLEMENTS/DEFINES/MEMBER_OF/STEP_IN_PROCESS。
- **关键禁忌**：用 `cypher` 前必须先读 `schema` 资源；索引过期未重建就查询会误导结论。

### 9.6 编码实现 / 架构类

#### flutter-apply-architecture-best-practices

- **核心任务**：以 UI（MVVM）/ Data（Repository）/ Logic（Use Case）分层架构实现或重构 Flutter 功能。
- **工作流摘要（8 步）**：定义不可变 Domain Model（freezed/built_value）→ 实现 Service（无状态、封装外部 API）→ 实现 Repository（消费 Service、转换为 Domain Model、处理缓存/重试）→ 条件判断 Use Case（仅复杂逻辑或跨 ViewModel 复用时）→ ViewModel（继承 ChangeNotifier、构造器注入 Repository、暴露不可变状态与命令方法）→ View（`ListenableBuilder` 监听）→ 依赖注入容器注册（provider/get_it）→ 跑 ViewModel 与 Repository 单测（反馈回路：跑测试 → 审读失败 → 修逻辑 → 重跑）。
- **判断标准**：严格关注点分离——View 逻辑仅限 UI 专属操作（动画/布局/简单路由），全部数据由 ViewModel 传入；Repository 为单一数据源。
- **关键禁忌**：永不混合 UI 渲染与业务逻辑或数据获取；简单逻辑不要引入 Use Case 层。

#### flutter-implement-json-serialization

- **核心任务**：用 `dart:convert` 手动实现类型安全的 `fromJson`/`toJson` 模型并解析 HTTP JSON。
- **工作流摘要**：定义 final 属性的 plain model → 实现 `factory fromJson`（显式转型或模式匹配校验解构，不匹配抛 `FormatException`）→ 实现 `toJson` → 为两个方向写单测 → 跑验证器修类型不匹配；拉取流：执行请求 → 状态码非 200/201 抛异常 → 小负载同步解析、大负载 `compute()` 后台 isolate → 交给 `fromJson`。
- **判断标准**：`jsonDecode` 返回 dynamic 必须显式转型 `Map<String, dynamic>` / `List<dynamic>`；解析耗时 > 16ms 应移交 isolate。
- **关键禁忌**：HTTP 失败返回 null（应抛异常）；不转型直接使用 dynamic 结果。

#### dart-use-pattern-matching

- **核心任务**：恰当使用 switch 表达式与模式匹配（Map/List/Record/Object/关系/逻辑/通配符模式）。
- **工作流摘要**：识别数据结构（JSON/Record/Class/Enum）→ 选构造（产出值用 switch 表达式，副作用用 switch 语句）→ 定义模式 → 用变量模式（`var x` / `:var y`）提取数据 → `when` 守卫补模式表达不了的逻辑 → `_`/default 处理未匹配 → 跑穷举性验证（反馈回路：`dart analyze` 报 "not exhaustively matched" → 补缺失 Object 模式或通配符）。
- **判断标准**：JSON 校验解构用 Map/List 模式；多返回值用 Record 模式；`sealed` 类 + Object 模式保证穷举；`||` 两分支必须定义完全相同的变量集，`&&` 分支不得重叠变量。
- **关键禁忌**：sealed 类/枚举的 switch 不保证穷举性；混淆语句与表达式语义（语句空 case 会 fall through，非空 case 隐式 break）。

#### flutter-setup-localization

- **核心任务**：初始化 Flutter 国际化（`flutter_localizations` + `intl` + `.arb` 资源包 + 生成的 `AppLocalizations`）。
- **工作流摘要（Setup 4 步）**：`flutter pub add flutter_localizations --sdk=flutter` 与 `intl:any` → `pubspec.yaml` 启用 `flutter: generate: true` → 建 `l10n.yaml`（arb-dir / template-arb-file / output-localization-file / synthetic-package）→ MaterialApp 注入 `AppLocalizations.delegate` 与三个 Global delegates + supportedLocales；实现流：模板 arb 定义键（附 description）→ 各 locale arb 同步更新 → `flutter pub get` 触发代码生成 → widget 树内 `AppLocalizations.of(context)` 消费。
- **判断标准（反馈回路）**：`flutter pub get` 报 ARB 语法错误 → 修缺失逗号/占位符不匹配 → 重跑；placeholder/plural（other 必填）/select 用元数据声明类型。
- **关键禁忌**：在非 MaterialApp 后代 widget 调 `AppLocalizations.of(context)`；只改模板文件不同步其他 locale arb。

#### flutter-setup-declarative-routing

- **核心任务**：用 `go_router` + `MaterialApp.router` 配置声明式路由、深链与嵌套导航。
- **工作流摘要**：`flutter pub add go_router` → `usePathUrlStrategy()` 去掉 web URL 的 `#` → 定义顶层 `GoRouter`（`redirect` 处理认证/状态路由、`errorBuilder` 兜底、`pathParameters` 取参）→ 绑定 `MaterialApp.router`；平台深链：Android 加 intent-filter + 托管 `assetlinks.json`，iOS 配 `FlutterDeepLinkingEnabled` + entitlements + AASA 文件 → 用 adb / xcrun 验证深链；嵌套导航用 `StatefulShellRoute.indexedStack` + `StatefulShellBranch` + `goBranch`。
- **判断标准**：编程导航用 `context.go()`（声明式替换栈）/ `context.push()`（命令式压栈）/ `goNamed` / `pop`；验证回路：跑 validator → 审错 → 修。
- **关键禁忌**：用第三方深链插件时 iOS `FlutterDeepLinkingEnabled` 须设 NO 防冲突；漏配 `errorBuilder` 导致未知路由无兜底。

#### flutter-build-responsive-layout

- **核心任务**：用 `LayoutBuilder`/`MediaQuery`/`Expanded`/`Flexible` 构建随窗口尺寸自适应的布局。
- **工作流摘要**：目标 widget 包 `LayoutBuilder` → 取 `constraints.maxWidth` → 定义断点（如 600）→ 大屏返回并排 Row 布局、小屏返回 Column → 跑验证器、缩放窗口审布局过渡、修 overflow；大屏优化：列表转 `GridView.builder` + `SliverGridDelegateWithMaxCrossAxisExtent` 自动调列数，表单/文本包 `ConstrainedBox(maxWidth)` + `Center`。
- **判断标准**：核心规则 "Constraints go down. Sizes go up. Parent sets position."；空间测量用 `MediaQuery.sizeOf(context)`（应用窗口尺寸），布局决策基于父级分配空间。
- **关键禁忌**：不用屏幕方向（orientationOf/OrientationBuilder）或硬件类型（"手机"/"平板"）作布局判断依据；不锁屏幕方向（折叠屏会 letterboxing）；长列表不用 `.builder` 懒渲染。

### 9.7 UI 设计类

#### apple-ui-designer

- **核心任务**：把移动端 UI 重设计为「毫无疑问的 Apple 感」（iOS 优先、SF Pro 风格、半透明、系统级组件）。
- **工作流摘要**：对每个重设计屏幕依次输出——简述设计意图 → 描述布局结构 → 说明字体用法 → 解释交互与动效行为 → 用 iOS 原生推论论证决策；设计哲学：native over custom、subtle over expressive、"Feels obvious" 而非 "looks fancy"。
- **判断标准**：系统优先字体、用尺寸与权重而非颜色建立层级、中性调色板 + 克制 accent、无生硬边框靠间距与分组、安全区默认感知、垂直滚动为主导航、模态底部 sheet 优先并尊重拖拽关闭、动效平滑自然且解释层级。
- **关键禁忌（Absolute Avoid）**：过度设计的自定义组件、潮流 UI 噱头、重渐变或霓虹色、生硬边框、密集杂乱信息布局、非标准导航模式；疑惑时跟随 iOS 系统默认，优先删减而非添加。

---

## 十、如何将这些要求注入专家

官方不公开内置专家的完整系统提示词，但内置专家可通过 `.qoder/agents/builtin/` 模板 frontmatter 的四个字段定制；项目专用 agent 则通过 `/create-agent`（create-subagent 技能）创建到 `.qoder/agents/` 根目录。

### 10.1 定制内置专家（frontmatter 四字段）

| 字段 | 作用 | 注意事项 |
|---|---|---|
| `model` | 指定该专家使用的模型 | 按任务复杂度选择 |
| `additionalPrompt` | 追加行为约束提示词（上限 10,000 字符） | **追加而非替换**内置提示词；适合注入工作流模板与项目约束 |
| `skills` | 挂载技能供专家调用 | 如给故障诊断工程师挂 `flutter-mcp-toolkit-debug`、`dart-fix-runtime-errors`，给代码审查员挂 `gitnexus-impact-analysis`、`flutter-mcp-boundary-audit` |
| `mcpServers` | 配置 MCP 服务器 | 如 flutter-mcp-toolkit、gitnexus 等 |

典型做法：

- **调研员**：`additionalPrompt` 写入本文档第二章 8 步调研工作流与陷阱清单；`skills` 挂 `gitnexus-guide`、`gitnexus-exploring`、`gitnexus-cli`、`dart-run-static-analysis`；`mcpServers` 配 gitnexus。
- **全栈工程师**：`additionalPrompt` 写入第三章 8 步实现工作流与陷阱清单；`skills` 挂编码实现类技能（架构、序列化、模式匹配、路由、国际化、响应式布局、依赖冲突解决）。
- **QA**：`additionalPrompt` 写入第四章 8 步验证工作流与陷阱清单，强调证据固化与诚实声明（未验证不得声称通过）；`skills` 挂测试验证类技能（见 9.3）及 `flutter-mcp-cli-runtime-validation`。
- **代码审查员**：`additionalPrompt` 写入第五章 8 步 Code Review 工作流与审查陷阱清单、固定格式审查报告模板；`skills` 挂审查类技能。
- **UI 操作者**：`additionalPrompt` 写入第六章 8 步 UI 验证工作流与陷阱清单；`skills` 挂 `flutter-mcp`、`flutter-mcp-toolkit-control`、`flutter-mcp-toolkit-inspect`、`flutter-fix-layout-issues`、`apple-ui-designer`；`mcpServers` 配 flutter-mcp-toolkit。
- **故障诊断工程师**：`additionalPrompt` 写入本文档第七章 8 步 Debug 工作流与陷阱清单；`skills` 挂调试类技能（见附录索引）。

### 10.2 创建项目专用 agent

`.qoder/agents/builtin/` 由产品自动维护、勿手动编辑；需要项目专用 agent（如 Legado 专属的「Rust-FFI 契约审查员」）时，用 `/create-agent` 创建到 `.qoder/agents/` 根目录（非 builtin 目录）。

### 10.3 本项目语境下的建议注入约束

结合 Legado 项目开发规范（`.qoder/rules/legado-dev-conventions.md` 与 AGENTS.md），建议在 `additionalPrompt` 中追加以下项目约束：

- **全中文规范**：汇报、commit 说明、代码注释全部使用中文。
- **两级模拟器验证**：每轮修复后先在安卓模拟器（端口 5556）测试，通过后再安装到安卓模拟器（端口 5558）通知用户实测验收。
- **署名规范**：UI 层代码署名「— 子代理名称 + UI」，Bridge 层代码署名「— 子代理名称 + Bridge」。
- **汇报纪律**：确认问题彻底解决后才能汇报完成，如实汇报，不得夸大进度或完成度。
- **原版对齐**：功能实现逻辑参照 Android 原版源码；界面功能、页面结构与交互流程与原版保持一致（UI 视觉风格可自由演进，UI 开发须使用 apple-ui-designer 技能）。
- **执行边界**：不得超范围删除或修改文件；删除/修改代码前先确认范围无误。
- **Git 纪律**：跨轨改动分批提交并使用 `[Rust]` / `[UI]` 前缀；验证通过后立即 commit。
- **环境约束**：Windows 开发环境无 make 命令，给用户的命令必须是可直接执行的 CMD 或 PowerShell 命令行。

---

## 附录：相关文档与技能路径索引

### A.1 官方文档

- Qoder 专家团模式：<https://docs.qoder.com/zh/user-guide/quest/experts-mode>

### A.2 技能文件路径索引（均位于 `d:\OH-WorkSpace\LegadoTeam\legado\` 下）

- **调试类**：`.agents\skills\dart-fix-runtime-errors\SKILL.md`、`.agents\skills\flutter-mcp\SKILL.md`、`.agents\skills\flutter-mcp-toolkit-debug\SKILL.md`、`.agents\skills\flutter-mcp-toolkit-inspect\SKILL.md`、`.agents\skills\flutter-mcp-toolkit-control\SKILL.md`、`.agents\skills\flutter-mcp-toolkit-setup\SKILL.md`、`.agents\skills\flutter-mcp-cli-runtime-validation\SKILL.md`、`.agents\skills\flutter-fix-layout-issues\SKILL.md`、`.agents\skills\gitnexus-debugging\SKILL.md`
- **验证类**：`dart-run-static-analysis`、`dart-resolve-package-conflicts`、`dart-add-unit-test`、`dart-generate-test-mocks`、`dart-collect-coverage`、`flutter-add-integration-test`、`flutter-add-widget-test`（路径同上，`.agents\skills\<技能名>\SKILL.md`）
- **审查类**：`skill-eval-improve`、`mcp-harness-repo-maintainer`、`skill-authoring-lifecycle`、`mixture-of-experts`、`flutter-mcp-boundary-audit`、`gitnexus-impact-analysis`（路径同上）
- **调研/探索类**：`gitnexus-guide`、`gitnexus-exploring`、`gitnexus-cli`（路径同上）
- **编码实现类**：`flutter-apply-architecture-best-practices`、`flutter-implement-json-serialization`、`dart-use-pattern-matching`、`flutter-setup-localization`、`flutter-setup-declarative-routing`、`flutter-build-responsive-layout`（路径同上）
- **UI 设计类**：`apple-ui-designer`（路径同上）

### A.3 项目内相关文档

- 开发规范：`.qoder/rules/legado-dev-conventions.md`
- 双轨开发规范：`docs/TWO_TRACK_DEV_SPEC.md`
- FFI API 契约：`docs/API_CONTRACT.md`
- 设计系统：`docs/design_system.md`
- 内置专家模板目录：`.qoder/agents/builtin/`（5 个空 frontmatter 模板，勿手编）

### A.4 补充说明

本次补充（2026-08-10）已将调研报告中未精读的 apple-ui-designer、gitnexus-guide/exploring/cli、flutter-add-widget-test 及 6 个编码实现类技能全文精读并收录为第九章卡片；其余仍未精读的低相关技能（如 gitnexus-refactoring、repository-governance-lifecycle、harness-engineering-lifecycle、multi-agent-handoff 等）若后续需要可补充抽取；其中 `gitnexus-refactoring`（安全重命名/提取/移动）与 `repository-governance-lifecycle`（ADR 与文档格治理）对代码审查员也有参考价值。

---

— Lee（全栈工程师）
2026-08-10

— Taylor（全栈工程师）补充其余专家工作流，2026-08-10
