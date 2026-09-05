# UI 一比一复刻计划（IA 结构层全量，含前后端与三端适配）

> 版本：v1.0 ｜ 日期：2026-09-05 ｜ 编写：Qoder UI
> 基线：参考仓 HapeLee/legado-with-MD3 main==9ce52559（已核无增量）
> 用户已定：全量 IA 一比一（S1–S7）｜只做 Material 引擎｜三端同步

## 〇、红线豁免授权记录（AGENTS 红线 2026-08-29 口径的例外授权）

**2026-09-05 用户授权**：纳入参考仓独有功能——① AI 摘要/改写（按钮位先落，功能链路需 AI 服务后端，独立排期）；② 角色卡 Characters 区块；③ 相关书 RelatedBooks 区块。后两项需 Rust/书源规则数据链支持：**先调研参考 ViewModel 数据源 → API_CONTRACT 契约先行 → Rust 轨独立排期；UI 先交付区块骨架 + 数据缺省降级（无数据隐藏）**。

**后端数据链调研登记（S3，2026-09-05）**：参考 Characters/RelatedBooks 数据出自 BookInfoViewModel 的 state.characters/knowledgeEntries/relatedBooks——来源为书源规则的角色分析管线（参考独有 rule 语义），本地 Rust webBook 解析链暂无对应字段。接通路径：API_CONTRACT 新增 getBookCharacters/getRelatedBooks FFI（依赖书源规则扩展）→ Rust 轨排期；UI 骨架已就位（_buildCharactersSection/_buildRelatedBooksSection，空数据隐藏），接通时替换常量列表为 state 数据即可。

## 一、原则

功能面保持原版对齐基线不动；一比一复制的是**布局/IA/动效/主题引擎**；本地既有功能全集保留。**不复制**：Miuix 引擎、liquid glass（SDK 限定，实色等效）、依赖参考私有组件族的实现（等效重写）。

## 二、IA 结构差（6 大块，实现依据）

1. **主框架**：顶栏未上收共享（Dynamic 搜索行仅书架）；底栏/Rail 未组件化；参考 MainScreen=HorizontalPager 滑动切页（与早前审计"IndexedStack"口径冲突，S1 实现时逐行核对定案）；Rail 头部搜索钮+长按分组菜单+expand 持久化。
2. **阅读菜单**：参考=单块底部面板五分区（DismissLayer/标题胶囊行+FloatingIconRow 17 按钮位/亮度竖条左右双位/ReadBookMenuSurface 多路由 AnimatedContent+SizeTransform/搜索 pill n-total 计数）+ 38 二级 Sheet；本地=顶栏+底栏两块 + 4 散配置入口。表面三档 None/Solid/Haze(BackdropFilter)；悬浮四角圆角 16 边距、非悬浮 morph 居中 dialog 28dp 最高 64% 屏高。
3. **详情**：缺 ActionCard 行（5 卡原版功能）、Characters/RelatedBooks（已授权）。
4. **主题引擎**：参考按 paletteStyle(9 档)/materialVersion(SPEC_2021/2025)/customContrast/isAmoled 参数化（material_color_utilities Scheme* 类）；本地固定 role 映射+4 自定义色。并存优先级：动态壁纸 > 自定义四色 > 参数化 seed > 内置色板。
5. **Sheet 体系**：参考统一 AppModalBottomSheet 壳（标题 titleMediumEmphasized+把手统一）；本地 33 处散点，渐进迁移（首批阅读域+主题域 10 处）。
6. **路由**：参考分域 NavGraph+沉浸域独立栈；本地扁平 Map 保留为源数据，渐进补沉浸栈。

## 三、批次（约 13.5 天）

| 批 | 内容 | 估时 |
|---|---|---|
| S0 | 本计划+授权记录+material_color_utilities 依赖+三端平台矩阵 | 0.5 |
| S1 | 主框架：顶栏上收（Glass 插值+Dynamic 搜索行+多选态+useCharMode 等效）、切页核对、底栏组件化、Rail 三件 | 2 |
| S2 | 阅读菜单收敛：单面板五分区+配置入口收敛+表面三档+readMenu* 键族 | 3.5 |
| S3 | 详情：ActionCard 行+Characters/RelatedBooks 骨架（后端调研/契约先行并行） | 1.5 |
| S4 | 主题引擎参数化：paletteStyle/materialVersion/contrast/AMOLED+选择器 UI | 2 |
| S5 | Sheet 统一壳 + 高频 10 处迁移 | 1.5 |
| S6 | 三端适配：dynamic_color iOS 口径修正、Windows 桌面适配、blur 策略矩阵 | 1.5 |
| S7 | 验收：渲染矩阵补页+双包对比+三端走查+归档 | 1 |

## 四、后端（Rust）结论

主题/UI 开关全走 SharedPreferences 透存 → **Rust 零改动、API_CONTRACT 不动**。授权功能（Characters/RelatedBooks）需后端数据链：调研参考数据源 → 契约先行 → Rust 轨独立排期；UI 缺省降级先行。AI 功能链：按钮占位先行，AI 服务后端独立立项。

## 五、三端要点

**blur/毛玻璃策略矩阵（S6 落盘，2026-09-05）**：

| 能力 | Android | iOS | Windows |
|---|---|---|---|
| BackdropFilter 毛玻璃 | 可用（默认关，低端机掉帧保护） | 可用（默认关） | 可用（Impeller 支持，默认关） |
| dynamic_color 动态色 | Android 12+ 系统色板 | iOS 动态色板（dynamic_color 实际可用，口径已修正） | 无系统色板（开关无效需提示） |
| WebView | 全功能 | 全功能（httpOnly Cookie 限制登记） | 不可用（降级提示统一） |
| 深链 legado:// | 通道 | app_links | 不可用（静默） |
| 亮度系统档 | 系统亮度 | application 亮度 | 不可用（降级） |
| 换图标 | 支持 | 支持（签名限制） | 不支持（入口隐藏） |
| Rail 宽窗 | sw≥600 | sw≥600 | 桌面窗口≥600 自动生效 |

S6 决策：blur 默认值三端统一**关**（保守，验证路径一致）；桌面高性能环境用户可手动开启（性能余量大）。

- Android：全量（含 edge-to-edge、动态色 12+、预测式返回维持登记）。
- iOS：dynamic_color 实际可用（修注释口径）；深链 app_links；锁屏桥已有。
- Windows：Rail 宽窗默认、悬停/键盘焦点态、WebView/深链/亮度降级提示统一、blur 可用（策略矩阵定默认值）。

## 五·五、实施状态（2026-09-06 收口）

| 批次 | 提交 | 版本 |
|---|---|---|
| S0 地基+授权 | `a87e324e5a` | — |
| S1a 滑动切页 | `7041fc44fc` | 2.0.184 |
| S1b 顶栏上收 | `c5cb2d2433` | 2.0.185 |
| S1c 导航组件化 | `5846ef1295` | 2.0.186 |
| S2-1 单面板 | `d934759d54` | 2.0.187 |
| S2-2 Haze+竖条 | `8feb2f3b22` | 2.0.188 |
| S3 详情补齐 | `74a2f3d1d0` | 2.0.189 |
| S4 主题引擎 | `8c53c975d1` | 2.0.190 |
| S5 弹层统一壳 | `686a5ce691` | 2.0.191 |
| S6 三端适配 | `21113a39d5` | 2.0.192 |
| S7 矩阵补页+归档 | 本提交 | 2.0.193 |

登记遗留：Sheet 壳余下 29 处散点渐进迁移；朗读并入面板路由页（S2-3 候选）；Characters/RelatedBooks 数据链接通（等 Rust 契约）；Spec2025 Dart 无实现（映射 2021）。

## 六、门禁

每批 analyze 0+test 全过+版本递增+CHANGELOG/updateLog 双同步+独立 commit；S7 统一验收（5556 冒烟+双包对比+5558 用户验收）。

---

编写者：Qoder UI ｜ 2026-09-05
