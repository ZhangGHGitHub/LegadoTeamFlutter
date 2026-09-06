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

## 五·六、T 批实施状态（2026-09-06 收口）

| 批次 | 提交 | 版本 | 内容 |
|---|---|---|---|
| T1 订阅页瓦片+双卡 | fa6f079883 | 2.0.196 | Adaptive 72dp 瓦片+头部双卡 |
| S1b 修正 | e65381b0e3 | 2.0.195 | 发现/订阅顶栏对齐 ListScaffold |
| T2 我的页分组卡 | c8c6260aaf | 2.0.197 | SplicedColumnGroup 反转+高亮标注入口 |
| T3 书架批量态 | 906537e899 | 2.0.198 | 选择模式+悬浮摘要+SelectionBottomBar |
| CI 修复 | aa6144480e | 2.0.197 | rss_screen null 断言清理版补提 |

三工作流全绿。登记遗留：Sheet 壳余 28 处渐进迁移；朗读并入面板路由页；Characters/RelatedBooks 数据链接通（等 Rust 契约）；Spec2025 Dart 无实现；组序微调；书架分组 HorizontalPager。

## 五·七、阅读导航 bug 登记（2026-09-06，待修）

1. **prevChapter 跳末页后点右翻变回退**：prevChapter 设 currentChapterPos=-1 哨兵跳末页 ✅，但跳完后点右侧翻页 → nextPageOrChapter 判定 _currentPageIndex+1 >= pages.length → nextChapter() → 回到原章。用户感知为"点右变成回退"。修复方案：prevChapter 跳末页后应进入"跨章过渡态"——此时点右 = 回到 prevChapter 前的章（即前进方向），需在 ReaderPageView 维护 crossChapterDirection 标志。
2. **换源失败不回退**：change_source_screen 选新源后如果加载失败，缺少回退到原章节的逻辑。需在 changeSource 回调中 catch 失败 → notifier 恢复原 chapterIndex/chapterPos。

## 五·八、正文吞字/章节切换动画/设置弹层三问题（2026-09-06）

| 问题 | 状态 | 说明 |
|---|---|---|
| A 正文右边吞字 | ✅ 已修（2.0.204+205） | 结构性根因两条：① ZhLayout 压缩模式（cps1/2/3）按原版语义允许行宽超出可用宽（原版绘制层压缩标点兜底），Flutter 渲染端 Text(maxLines:1, clip) 自然渲染无字形压缩 → 双标点行尾必被裁（探针实证：可用宽 50 时压缩行宽 60），8dp/5% 余量大字号下必被击穿；② 测量侧逐字单独建 TextPainter（未合并 DefaultTextStyle、未应用 textScaler）与渲染侧存在系统差。修复：整段 TextPainter.layout + getBoxesForSelection 同源测量 + DefaultTextStyle/textScaler 同参注入（ParagraphConfig.baseStyle/textScaler）+ _guardLineOverflow 行宽安全网（超宽行避头尾回退下移重排）；去掉分页宽 ×0.95 恢复满宽；双页不对称边距取两栏较小宽；两端对齐可用宽改实际布局约束（去屏宽-40 硬编码）。回归测试 line_overflow_guard_test 5 项。任务书原定"getLineBoundary 整段分行"方向未采用：会废弃对标原版的 useZhLayout/避头尾/悬挂特性（违反原版对齐红线），同源测量+安全网以更小改动达成同一目标（分页与渲染同引擎） |
| B 章节切换翻页动画不生效 | ✅ 已修（2.0.204+205） | 根因：切章经 isLoading 时 build 整树换 LoadingIndicator → cover 模式 AnimatedSwitcher 子树卸载重挂，过渡永不触发（与 T2/S2 菜单改造无关）；叠加键缺陷：键只含章内页索引，跨章页索引相同不触发、变小判反方向。修复：加载中保留上一章渲染冻结帧（跳过重分页，章题用分页同源快照 _paginatedChapterTitle），键改（章索引,屏索引）复合键、方向按章号比较 |
| C 设置弹层布局与参考版不一致 | ✅ 已修（2.0.205+206） | 参考截图（2026-09-06 用户提供）比对：参考版「阅读界面」弹层为四页签结构（全局/菜单/信息/更多），全局页=字号步进器+独立 Tt 卡/背景卡（长按自定义+月亮夜间切换+自定义与预设 chips）/翻页动画行+独立图标小卡，头部圆形返回按钮。ReaderSettingsSheet 重写为该结构；菜单/信息/更多页分别装载自动翻页+点击区域+亮度/页眉页脚提示/排版与更多配置+边距+共用布局（其余三页参考截图缺失，按控件性质归组，待参考截图后再校）。5556 实测截图比对通过，新增 reader_settings_sheet_test |

## 五·九、主菜单布局差异清单（2026-09-06 模拟器实测取证，后续批次）

参考版 = 5556 模拟器 `io.legato.kazusa`（浅色主题实测取证；截图存档会话）。逐屏比对结论：

**主菜单**（参考版为单一底部面板 + 顶部工具栏）：
1. 顶部工具栏：← / 换源⇄ / 刷新↻ / 下载⬇ / ⋮（书名与章题不占 chip）；正文区另有四个**浮动图标**（搜索/目录/朗读/设置，受「显示浮动图标」配置控制）；我方顶栏为 书名chip+章节chip+⋮，无浮动图标
2. 底部面板：亮度条（竖条形手柄）+ 章节滑条（**两侧箭头 ←→**，非文字标签）+ **可横滑两页的七项行动作行**（第1页：章节梗概/AI改写/全文搜索/自动翻页/目录；第2页：朗读/设置——用户此前截图三即第2页形态）；我方为 图标行（目录/朗读/界面/换源/设置）+ 全文搜索chip + 底部文字行（目录/朗读/界面/更多）
3. 章节梗概弹层：把手+章题+「未配置模型」+重试（AI 占位已授权）；AI 改写弹层：全高、刷新/保存头 + 更改前/更改后/历史页签 + 原文卡（展开）+ 改写要求单选列表（润色文风/精简段落…）+ 管理

**阅读界面弹层（2.0.205 已对齐四页签骨架，实测后登记细化项）**：
- 全局页背景 chips 为颜色预览卡（2.0.206 已补）；字号卡有展开形态（下方滑条）
- 菜单页签：参考版有**二级页签（菜单/底栏布局/顶栏布局）**，内容=工具栏样式/顶栏图标位置/显示浮动图标/显示亮度调节控件(横排)/边框/模糊半径；我方装的是自动翻页/点击区域/亮度控制 → 需重排补齐
- 信息页签：参考版二级页签（页眉/页脚/全局）+ 显示分隔线/页眉显隐/左中右项（标题/时间…）——与我方 ReaderTipConfigSheet 内容相近，形态需按二级页签改
- 更多页签：参考版为**全高独立弹层**（把手+居中标题，无底部页签栏），内容=屏幕方向/屏幕超时/隐藏状态栏/隐藏导航栏/填充刘海区域/扩展到刘海/文字两端对齐/文字底部对齐/适配特殊样式/使用自定义中文分行/下划线强调文本…；我方为页签内嵌排版组 → 需改全高形态并重排

处置：主菜单结构重做 + 设置弹层三页细化 合并为「主菜单一比一对齐」独立批次（含 AI 占位按钮，授权范围内），待用户确认后实施。

## 五·十、全屏差异清单（2026-09-07 实测取证，已收口）

双机实机配对取证**三批完成**（主框架五页签 + 搜索/设置主页/书籍详情 + 目录/换源/书源管理/缓存/外观/备份/字体/朗读/发现二级页/书架菜单 + 批量态/首页模块管理/替换编辑器/书源编辑器/主题设置/Web服务态），完整差异与处置建议见 [UI_SCREEN_DIFF_INVENTORY_20260907.md](UI_SCREEN_DIFF_INVENTORY_20260907.md)。要点：①缺「首页」页签（最近阅读+阅读统计+今日目标表盘+首页模块管理）；②我的页项基本齐全（复核修正首批评误判），真实差异为**高亮标注条目重复 bug**+无独立缓存管理页；③设置主页集中式 8 组 vs 分散式；④搜索历史整行卡 vs 流式 chip；⑤书籍详情宫格/封面布局差异；⑥目录页字数chip+FAB vs 下载态+进度条；⑦我方书架菜单缺导出/导入书单与日志。不可配对：RSS 源二级页（参考侧无源）。附带登记：朗读语速滑条交互疑点。

## 六、门禁

每批 analyze 0+test 全过+版本递增+CHANGELOG/updateLog 双同步+独立 commit；S7 统一验收（5556 冒烟+双包对比+5558 用户验收）。

---

编写者：Qoder UI ｜ 2026-09-05
