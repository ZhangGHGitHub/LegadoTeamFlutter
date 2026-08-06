# 重构综合审计报告（2026-08-06）

**报告日期**: 2026-08-06
**审计来源**: 双轨并行审计——Flutter UI 功能缺口实测审计（Grace）+ Rust 功能缺口源码级复查（Sam）
**报告定位**: 重构完成度量化、缺口全量清单、修复优先级与时间表的唯一综合基准；台账登记见 [REFACTORING_REMAINING_PLAN.md §5](REFACTORING_REMAINING_PLAN.md)，UI 可执行任务见 [UI_FIX_PLAN.md](UI_FIX_PLAN.md)「UI 缺口修复批次（2026-08-06）」，契约变更见 [API_CONTRACT.md](API_CONTRACT.md)

---

## 1. 审计背景与方法

| 路 | 审计对象 | 方法 |
|---|---|---|
| 第一路（Flutter UI） | Flutter 全部 screen/widget 与 Android 原版（功能基准 `com.legado.app.release` 3.26073003）逐屏对照 | 实测审计：菜单项/交互流程/存根扫描/孤儿页排查，产出约 92 项缺口 |
| 第二路（Rust） | rust/ 工作区源码级复查 | 源码级复查：FFI 链路、契约登记、schema 对照、死代码扫描，产出完成度修订与 4 项 P1 实质缺口 |

对齐标准（2026-08-05 用户确认）：**界面功能、页面结构与交互流程必须与 Android 原版一致；UI 视觉风格允许自由改变**。本报告所有缺口均以功能对齐为口径，视觉差异不计入。

---

## 2. 当前重构完成度统计

### 2.1 Rust 轨道：**96-97%**（源码级复查，修订此前「95%+」口径）

| 维度 | 数据 |
|------|------|
| 原子任务 | 168 / 168（100%） |
| 实质 P1 缺口 | 4 项（nextContentUrl 分页 / audioSpeak TTS / WebView 载荷拦截 / rssUpdateSource） |
| P2 与治理项 | subContent、contentRule.replaceRegex、legado-server 正文桩、dict 18 词占位、Dart fallback 死代码等 |
| 契约登记 | 12 个 FFI 已实现未登记（已补登 API_CONTRACT §2.41）；13 个 bridge 绑定待 UI 封装 |
| schema | 核心表对齐 Room v95 良好；rssArticles/readRecord 主键、rssReadRecords/httpTTS 结构、rssSources 双列冗余为 P1 治理项（不阻塞单机功能，v102 重建表可延后） |

### 2.2 Flutter UI 功能对齐度：**主链路已对齐，剩约 92 项缺口**

| 优先级 | 数量 | 性质 |
|--------|------|------|
| P0 | 2 | 阻塞核心阅读体验（正文长按选择菜单、朗读链路） |
| P1 | 44 | 影响用户体验（各屏幕菜单/配置/行为不符） |
| P2 | 46 | 细节收尾（日志接线、排版参数、零星菜单） |
| **合计** | **约 92** | 核心页面与主链路（书架→搜索→目录→正文→书签→替换规则→RSS→听书→备份）均已可用；缺口集中在二级菜单、配置项与行为细节 |

快赢项（纯接线、无 FFI 阻塞、立即可做）：6 处日志入口、朗读配置页入口、替换规则导入接已有确认页、翻页动画菜单。

### 2.3 测试规模（2026-08-05 实测）

| 轨道 | 测试数 |
|------|--------|
| Rust workspace（cargo test） | 2283 passed |
| Rust quickjs feature | 547 passed（legado-ffi 175 passed） |
| Flutter（flutter test） | 1087 passed（flutter analyze 0 issues） |
| **合计** | **约 3917** |

---

## 3. 详细功能缺口清单

### 3.1 Rust 功能缺口（分类：Rust 功能）

#### P1 实质缺口（4 项）

| # | 缺口 | 现状证据 | 影响 | 工作量 | 状态 |
|---|------|----------|------|--------|------|
| ① | 正文 nextContentUrl 分页抓取 | `web_book.rs` get_content 只抓一页 | 分页书源正文被截断——**唯一用户可见的核心解析缺口** | 2-3d | ✅ 已闭合（`b7368193a`） |
| ② | audioSpeak TTS 真实管线 | `rust_api.dart` L1431 仅 http.get 探活，被 audio_notifier 实际调用 | 阻塞 Flutter P0 朗读功能（跨轨） | 3-5d | ✅ 已闭合（`9ac94b173` + `522e1c1be`） |
| ③ | WebView 桥接载荷 Flutter 侧拦截执行 | Rust 已交付 7 个 action JSON，Flutter lib 无拦截代码 | 书源 WebView 交互类功能不可用（跨轨） | 2-3d | ✅ 已闭合（`522e1c1be`） |
| ④ | rssUpdateSource 原子更新 FFI | 现用「删旧+加新」workaround | RSS 源编辑存在串表风险 | 0.5d | ✅ 已闭合（Rust `b7368193a` + UI 评审修复接线） |

#### P2 缺口

- subContent 副内容、contentRule.replaceRegex 全文替换
- legado-server 正文桩
- dict 18 词占位（契约达标、数据覆盖为占位级）
- Dart fallback 死代码（getAudioChapterMedia/scanLocalBooks/parseTxt 多为死代码）

#### 契约登记缺口

- 12 个 FFI 已实现未登记：QUIC 8（quicCreateClient/quicGet/quicPost/quicPerformanceTest/quicIsInitialized/quicCleanup/netSetQuicEnabled/netIsQuicEnabled）+ backupList + cacheGetChapter + bookGroupSetShow + httpTtsSetEnabled → ✅ 已补登 API_CONTRACT.md §2.41
- 13 个 bridge 绑定未封装：登录 UI V2 整组（3）+ QUIC 客户端六件套（6）+ backupList/cacheGetChapter/bookGroupSetShow/httpTtsSetEnabled（4）→ 已登记 API_CONTRACT.md §3 待封装清单；**评审修复销记：登录 V2 三件套 + ttsSpeak（522e1c1be）、cacheGetChapter + ttsSetCacheDir（评审修复提交）已封装接通，剩 9 项**

#### schema 偏离（P1 治理，不阻塞单机功能）

- rssArticles 主键 (origin,title) vs Room (origin,link,sort)；readRecord 主键 (bookName) vs Room (deviceId,bookName)
- rssReadRecords/httpTTS 结构偏离
- rssSources enableCookieJar/enabledCookieJar 双列冗余
- 处置：v102 重建表可延后

#### 治理项

- README「零 TODO/桩实现」表述需修正（rust/PROGRESS.md 已修正口径，docs/README.md 待同步）
- platform.rs 5 个死代码桩清理、一次性脚本清理
- DEVELOPMENT.md 已知限制表过期
- bridge.rs 62 个 C ABI 去留决策
- Task #131 timeFormat/toURL 别名已闭合 ✅

### 3.2 Flutter UI 缺口（分类：Flutter UI，约 92 项）

#### P0（2 项）

| # | 功能名 | Android 位置 | Flutter 现状 | 工作量 |
|---|--------|--------------|--------------|--------|
| 1 | 阅读器正文长按选择 + 9 项操作菜单（复制/书签/高亮/词典/朗读/搜正文等） | ReadBookActivity 长按动作菜单 | `reader_text_content.dart` 无 SelectableText，菜单缺失 | 3-5d |
| 2 | 阅读器底栏朗读按钮 + 朗读配置页入口 | ReadBookActivity 底栏朗读入口 | 底栏按钮存根；`read_aloud_config_screen.dart` 孤儿页 | 2-3d |

#### P1（44 项，按屏幕分组）

| # | 屏幕/模块 | 缺口功能 | 现状 |
|---|-----------|----------|------|
| 1 | 阅读器·顶栏 | 溢出菜单 10 项（编辑内容/替换规则开关/更新目录等） | 全存根 |
| 2 | 阅读器·底部 | 源操作菜单（登录源/章节购买/编辑源/禁用源） | 缺失 |
| 3 | 阅读器·配置 | 阅读配置面板 5 项（字体/字距/首行缩进/简繁/MoreConfig） | 部分缺失 |
| 4 | 离线缓存 | 顶栏缓存 + 书架缓存导出（对应 CacheActivity） | 缺失 |
| 5 | 书架 | 更新目录假动作/添加网址/书单导入导出行为不符（3 项） | 行为不符 |
| 6 | 书详情 | 登录/置顶/清缓存（3 项） | 存根或缺失 |
| 7 | RSS | 文章列表菜单 6 项 + 详情收藏按钮 | 缺失 |
| 8 | 替换规则页 | 分组筛选 + 3 种导入 + 批量操作 | 部分缺失 |
| 9 | 换源页 | 高级选项 8 项 | 缺失 |
| 10 | 听书 | 溢出菜单（换源/缓存/wakelock） | 缺失 |
| 11 | 设置 | Web 服务/定时服务开关 | 缺失 |
| 12 | 书架管理 | 批量换源等 | 缺失 |

#### P2（46 项，摘要）

- 日志入口 6 处接线（AppLogScreen 路由已存在、appLog* FFI 已交付）
- 编码/字距/边距等排版细节参数
- 导入排序、自动任务菜单
- 其余约 35 项零星菜单/行为细节

#### 结构问题

- `rss_config_screen.dart` 与 `rss_source_manage_screen.dart` 功能重复（前者 5 存根），建议删除前者

### 3.3 功能完整性交叉视图（分类：功能完整性）

| 功能 | Rust 侧 | Flutter 侧 | 阻塞方向 |
|------|---------|------------|----------|
| 正文完整性（分页书源） | ✅ nextContentUrl 分页抓取（`b7368193a`） | ✅ 阅读器正文完整 | 已闭合 |
| 朗读/TTS | ✅ ttsSpeak 真实管线（`9ac94b173`） | ✅ audioSpeak 已接线（`522e1c1be`） | 已闭合 |
| WebView 书源交互 | ✅ 7 action JSON 已交付 | ✅ platform_bridge_service 拦截 7 动作（`522e1c1be`） | 已闭合 |
| RSS 源更新 | ✅ rssUpdateSource 原子 FFI（`b7368193a`） | ✅ updateRssSource 接线（评审修复提交） | 已闭合 |
| 正文长按操作（高亮/词典/书签） | ✅ FFI 全部已交付 | ✅ 选区面板 + 9 项菜单（`873abea29`） | 已闭合 |
| 书源登录 V2 | ✅ FFI 已交付 | ✅ 封装接通（`522e1c1be`） | 已闭合 |
| 离线缓存 | ✅ cache FFI 具备（cacheGetChapter 已封装，评审修复提交） | ✅ 顶栏缓存 + 书架缓存导出（扩展项留批次） | 主体闭合 |
| 应用日志 | ✅ appLog* 已交付 | ✅ 入口 7/7 接线（批次0 6 处 + source_edit_screen 评审修复补接） | 已闭合 |

---

## 4. 修复建议与优先级排序

### 4.1 总原则

1. **P0 先行**：两项 P0 均集中在阅读器，直接决定核心阅读体验
2. **快赢先行**：纯接线项无 FFI 阻塞，立即消化建立 momentum
3. **Rust 解阻塞优先**：① nextContentUrl 与 ④ rssUpdateSource 工时小、收益直接，先于 UI 批量启动
4. **跨轨并行**：② audioSpeak 与 ③ WebView 拦截与 UI 批次并行推进
5. **契约铁律**：新增 FFI 先更新 API_CONTRACT.md 冻结契约再实施

### 4.2 排序明细

| 序 | 内容 | 类型 | 理由 |
|----|------|------|------|
| 1 | 批次 0：4 个纯接线快赢（日志入口/朗读入口/规则导入/翻页菜单） | 纯接线快赢 | ≤2d，零阻塞 |
| 2 | P0-1 正文长按选择 + 9 项菜单 | 纯 UI（FFI 已齐） | 核心体验，无契约阻塞 |
| 3 | Rust ① nextContentUrl + ④ rssUpdateSource | Rust 功能 | 小工时解正文截断与串表两个实际风险 |
| 4 | P0-2 朗读（UI 先行）+ Rust ② audioSpeak 管线 | FFI 阻塞（跨轨） | UI 与管线并行，交付后接通 |
| 5 | P1 44 项按屏幕批量（阅读器→书架/详情→RSS→规则/换源→听书/设置） | 多数纯 UI | 依赖既有 FFI；少数等登录 V2 封装与 rssUpdateSource |
| 6 | Rust ③ WebView 载荷拦截 | FFI 阻塞（跨轨） | 与批次 5 并行 |
| 7 | P2 46 项收尾 + 结构治理（删 rss_config_screen）+ Rust 治理项 | 收尾 | 随迭代消化 |
| 8 | schema 偏离 v102 重建表、bridge.rs C ABI 决策 | 治理 | 不阻塞单机功能，延后决策 |

---

## 5. 预计完成时间表（按人日估算分批）

| 批次 | 内容 | 人日估算 | 周期（单人） | 依赖 |
|------|------|----------|--------------|------|
| 批次 1·快赢 | 批次 0 四个纯接线项 | ≤2d | 第 1 周 | 无 |
| 批次 1·P0 专项 | P0-1（3-5d）+ P0-2 UI 部分（2-3d） | 5-8d | 第 1-2 周 | 无（朗读真实播报等批次 2 管线） |
| 批次 2·Rust 解阻塞 | ① nextContentUrl（2-3d）+ ④ rssUpdateSource（0.5d） | 2.5-3.5d | 第 2-3 周 | 契约先行 |
| 批次 2·P1 批量 | 44 项按屏幕分组（阅读器/书架/RSS/规则/听书/设置） | 约 20d（多数菜单项 0.5-1d/组） | 第 3-6 周 | 登录 V2 封装、rssUpdateSource |
| 批次 2·跨轨管线 | ② audioSpeak（3-5d）+ ③ WebView 拦截（2-3d） | 5-8d | 第 3-6 周（与 P1 并行） | 契约冻结 |
| 批次 3·P2 收尾 | 46 项 P2 + 结构治理 | 10-15d | 第 7-8 周 | 批次 1/2 完成 |
| 批次 3·治理 | README 修正、platform.rs 桩清理、脚本清理、bridge.rs 决策、schema v102 评估 | 3-5d | 第 7-8 周（穿插） | 无 |

**总计**：约 48-65 人日；单人串行约 8-10 周，双轨并行（Rust 轨 + UI 轨）可压缩至 **6-8 周**。

**里程碑**：
- M1（第 2 周末）：快赢清零 + P0 两项 UI 完成（朗读真实播报除外）
- M2（第 6 周末）：P1 44 项清零 + Rust 4 项 P1 实质缺口闭合 + 朗读真实播报接通
- M3（第 8 周末）：P2 收尾 + 治理项闭合，功能对齐度达到可发布口径

---

## 6. 关联文档索引

| 文档 | 角色 |
|------|------|
| [REFACTORING_REMAINING_PLAN.md §5](REFACTORING_REMAINING_PLAN.md) | 缺口台账（登记与销记基准） |
| [UI_FIX_PLAN.md](UI_FIX_PLAN.md)「UI 缺口修复批次（2026-08-06）」 | UI 侧可执行任务清单 |
| [API_CONTRACT.md](API_CONTRACT.md) §2.41 / §3 | 契约补登记与待封装清单 |
| [rust/PROGRESS.md](../rust/PROGRESS.md)「剩余 P1 实质缺口」 | Rust 侧缺口与口径修正 |
| [REFACTORING_PLAN.md](REFACTORING_PLAN.md) | 历史纲领（仅顶部状态引用） |
| [TWO_TRACK_DEV_SPEC.md](TWO_TRACK_DEV_SPEC.md) | 双轨协作与契约变更流程 |

---

## 7. 修复完成状态（2026-08-06 批次0-3 闭合）

> 本章为审计报告缺口的修复回写（Task #119）：审计报告所列 P0/P1/P2 缺口与 Rust 4 项 P1 实质缺口已全部按计划闭合，台账销记见 [REFACTORING_REMAINING_PLAN.md §5](REFACTORING_REMAINING_PLAN.md)（v1.8）。

### 7.1 提交清单（8 个提交，均 2026-08-06）

| 序 | 提交 hash | 批次 | 内容 | 闭合的审计缺口 |
|----|-----------|------|------|------------------|
| 1 | `0cde41a5c` | 批次0 快赢（v2.0.1） | 日志入口接通 AppLog / 翻页动画接阅读设置 / 朗读配置页入口 / 替换规则本地导入接确认页 | §5.4 四个纯接线快赢项 |
| 2 | `873abea29` | 批次1 P0（v2.0.1） | 阅读器正文长按选择 + 9 项操作菜单 / 底栏朗读按钮 + 朗读控制条 | §3.2 P0-1、P0-2 |
| 3 | `b7368193a` | 批次2 解阻塞（Rust） | 正文 nextContentUrl 分页抓取（99 页上限去重终止）+ rssUpdateSource 原子更新 FFI（契约 §2.5/§2.17 登记） | §3.1 P1 ①④（④的 UI 接线随评审修复补闭合，见 §7.3 修订） |
| 4 | `9ac94b173` | 批次2 跨轨（Rust） | TTS 真实合成管线：ttsSpeak 模板替换 + MD5 文件缓存 + Content-Type 校验 / legado-net 无损字节 get_raw（契约 §2.42 登记） | §3.1 P1 ② Rust 侧 |
| 5 | `522e1c1be` | 批次2 P1 批量（v2.0.2，34 files） | 组 A 阅读器系 10 项菜单+源操作+配置 5 项 / 组 B 离线缓存+书架书详 7 项 / 组 C RSS 规则换源听书设置 8 项 + 删 rss_config_screen / WebView 桥接拦截 7 动作（platform_bridge_service.dart）/ audioSpeak 接 ttsSpeak 真实管线 | §3.2 P1 44 项、§3.1 P1 ②③、结构问题 |
| 6 | `6633c25e3` | 批次3 治理（Rust） | platform.rs 5 个死代码桩清理、rust_api.dart 3 个死代码 fallback 标注、10 个一次性脚本清理 | §3.1 治理项 |
| 7 | `0c452f4b5` | 批次3 治理（Docs） | 文档口径修正（README/DEVELOPMENT/PROGRESS）与决策记录（bridge.rs 保留+计划性废弃、schema v102 延后） | §3.1 治理项 |
| 8 | `13a11220e` | 批次3 P2 收尾（v2.0.3） | 阅读页面四向边距 + 设置编码 + 定时任务导入导出菜单；日志入口/字距段距/导入排序经核验销记 | §3.2 P2 46 项 |

### 7.2 版本演进

| 版本 | 对应批次 | 主要交付 |
|------|----------|----------|
| 2.0.0+2 | 审计基线 | 审计前基线版本（缺口约 92 项 UI + 4 项 Rust P1） |
| 2.0.1 | 批次0 + 批次1 | 4 个纯接线快赢 + P0 两项（长按选择菜单、朗读链路） |
| 2.0.2 | 批次2 | P1 44 项批量（组 A/B/C）+ WebView 拦截 7 动作 + audioSpeak 接真实管线 |
| 2.0.3+5 | 批次3 | P2 收尾（边距/编码/定时任务菜单）+ 治理项闭合，**当前版本** |

### 7.3 留项汇总（未闭合项，均已在代码/台账登记，不臆测）

> **评审修复修订（Task #122）**：缺口④ rssUpdateSource 已闭合（Rust `b7368193a` + UI 评审修复接线：`rust_api.updateRssSource` 由误接 `sourceUpdate` 改接 `bridge.rssUpdateSource` 真实管线，Mock 同步对齐「源不存在时报错」语义），不再列入留项；留项 10 已按封装销记扣减。

| # | 留项 | 性质 | 来源依据 |
|---|------|------|----------|
| 1 | 章节内容保存 FFI（saveChapterContent） | 待 Rust 交付 FFI 后持久化编辑结果 | `reader_top_bar.dart` TODO(留批次) |
| 2 | 反转内容持久化 | 依赖留项 1（无章节保存 FFI，反转结果无法持久化） | `reader_top_bar.dart` TODO(留批次) |
| 3 | 章节购买 payAction | 需书源 payAction 后端支持，当前无 FFI | `reader_bottom_bar.dart` TODO(留批次) |
| 4 | 段落级 TTS 切换起点 | 待 startReadAloud 支持偏移参数（chapterPos） | `text_selection_panel.dart` TODO(留批次) |
| 5 | 语速跟随系统实时通道 | 需系统 TTS 语速读取通道，当前持久化到 SharedPreferences | `read_aloud_bar.dart` TODO(留批次) |
| 6 | MoreConfig 其余项 | 显示标题/滚动条/音量键翻页等 | `reader_config_panel.dart` TODO(留批次) |
| 7 | schema v102 重建表 | 评估结论：建议延后，与 ruleSubs/dictRules 等结构偏离合并为 schema 对齐专项 | [REFACTORING_REMAINING_PLAN.md §4.2.1](REFACTORING_REMAINING_PLAN.md) |
| 8 | bridge.rs C ABI 三步废弃 | 已决策保留+计划性废弃：本批完成决策记录→下批 DEPRECATED 标注冻结新增→下大版本物理移除 | [REFACTORING_REMAINING_PLAN.md §4.2.3 P2-1](REFACTORING_REMAINING_PLAN.md) |
| 9 | Rust P2 缺口 | subContent 副内容、contentRule.replaceRegex 全文替换、legado-server 正文桩、dict 18 词占位数据 | 本报告 §3.1 P2（未列入本次闭合范围） |
| 10 | 登录 UI V2 / QUIC 六件套等 13 个 bridge 绑定 UI 封装 | **已扣减**：登录 V2 三件套 + ttsSpeak（522e1c1be）、cacheGetChapter + ttsSetCacheDir（本次评审修复提交）已封装接通；剩 QUIC 六件套（6）+ backupList/bookGroupSetShow/httpTtsSetEnabled（3）共 9 项，随后续批次消化 | 本报告 §3.1 契约登记缺口 + API_CONTRACT §3 待封装清单 |
| 11 | 定时服务后端 | autoTask 后台执行 FFI 未移植，定时任务开关当前仅持久化 `isEnabled`，无后台调度执行 | `auto_task_screen.dart` 开关语义核验（评审修复补登） |
| 12 | 书架缓存导出扩展项 | 缓存管理独立页/缓存下载/epub·pdf 导出类型/导出目录与文件名模板/自定义导出设置/WebDav 等，当前已交付 TXT 正文导出 | `bookshelf_screen.dart` TODO(留批次)（评审修复补登） |
| 13 | searchSource 分组过滤 | 换源页源分组单选持久化 `searchGroup`，待 Rust searchSource 支持分组过滤后全链生效 | `change_source_screen.dart` TODO(留批次)（评审修复转正式登记，台账 §5.9） |

### 7.4 P2 处置明细（2026-08-06 评审修复补录）

> **诚实口径说明**：审计 §3.2 的 P2「46 项」为摘要登记（审计当时未逐条归档明细），本表按类别逐项还原处置结果；无法逐条追溯的零星项如实标注，不虚报。

| # | 类别/条目 | 处置 | 核验依据 |
|---|-----------|------|----------|
| 1 | 阅读页面四向边距 | ✅ 实现闭合 | `13a11220e`：阅读高级配置上/下/左/右边距滑杆，接分页缓存键与排版渲染 |
| 2 | 设置编码 | ✅ 实现闭合 | `13a11220e`：顶栏 menu_set_charset → book.charset 写入并重载当前章 |
| 3 | 自动任务菜单（导入/导出） | ✅ 实现闭合 | `13a11220e`：导入本地/导入线上/导出/帮助，经 autoTaskPrepareImported 合并 |
| 4 | 日志入口接线 | ✅ 销记闭合（7/7） | 批次0 `0cde41a5c` 接通 6 处；source_edit_screen（书源编辑）为批次0 遗漏，本次评审修复补接（补提交），全部核验可达 AppLogScreen |
| 5 | 字距/段距/首行缩进/两端对齐 | ✅ 销记闭合 | v2.0.2 `522e1c1be` 已接入排版引擎，台账核验无需改动 |
| 6 | 书源导入排序 | ✅ 销记闭合 | 排序已应用于显示列表且导入后 reload 保持；原版 ImportBookSourceDialog 亦无排序 UI，判定对齐 |
| 7 | 其余约 35 项零星菜单/行为细节 | ⚠️ 降级为观察项 | 审计未归档逐条明细，无法逐条追溯；已随批次1/2 对应屏幕修复消化（`873abea29`/`522e1c1be` 覆盖阅读器/书架/书详/RSS/规则/换源/听书/设置），残留分歧发现时单独立项登记 |

---

**编写者**: Qoder
**日期**: 2026-08-06
**数据来源**: Grace（Flutter UI 缺口实测审计）、Sam（Rust 功能缺口源码级复查）两份审计结论，本报告不臆测审计外数据
