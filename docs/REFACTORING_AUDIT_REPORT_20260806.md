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

| # | 缺口 | 现状证据 | 影响 | 工作量 |
|---|------|----------|------|--------|
| ① | 正文 nextContentUrl 分页抓取 | `web_book.rs` get_content 只抓一页 | 分页书源正文被截断——**唯一用户可见的核心解析缺口** | 2-3d |
| ② | audioSpeak TTS 真实管线 | `rust_api.dart` L1431 仅 http.get 探活，被 audio_notifier 实际调用 | 阻塞 Flutter P0 朗读功能（跨轨） | 3-5d |
| ③ | WebView 桥接载荷 Flutter 侧拦截执行 | Rust 已交付 7 个 action JSON，Flutter lib 无拦截代码 | 书源 WebView 交互类功能不可用（跨轨） | 2-3d |
| ④ | rssUpdateSource 原子更新 FFI | 现用「删旧+加新」workaround | RSS 源编辑存在串表风险 | 0.5d |

#### P2 缺口

- subContent 副内容、contentRule.replaceRegex 全文替换
- legado-server 正文桩
- dict 18 词占位（契约达标、数据覆盖为占位级）
- Dart fallback 死代码（getAudioChapterMedia/scanLocalBooks/parseTxt 多为死代码）

#### 契约登记缺口

- 12 个 FFI 已实现未登记：QUIC 8（quicCreateClient/quicGet/quicPost/quicPerformanceTest/quicIsInitialized/quicCleanup/netSetQuicEnabled/netIsQuicEnabled）+ backupList + cacheGetChapter + bookGroupSetShow + httpTtsSetEnabled → ✅ 已补登 API_CONTRACT.md §2.41
- 13 个 bridge 绑定未封装：登录 UI V2 整组（3）+ QUIC 客户端六件套（6）+ backupList/cacheGetChapter/bookGroupSetShow/httpTtsSetEnabled（4）→ 已登记 API_CONTRACT.md §3 待封装清单

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
| 正文完整性（分页书源） | ❌ nextContentUrl 未抓取 | 等待 | Rust → UI |
| 朗读/TTS | ❌ audioSpeak 仅探活 | P0-2 UI 可先行 | Rust → UI |
| WebView 书源交互 | ✅ 7 action JSON 已交付 | ❌ 无拦截代码 | UI |
| RSS 源更新 | ⚠️ 删+加 workaround | 等待原子 FFI | Rust → UI |
| 正文长按操作（高亮/词典/书签） | ✅ FFI 全部已交付 | ❌ UI 缺失 | 纯 UI |
| 书源登录 V2 | ✅ FFI 已交付 | ❌ 未封装未接入 | 纯 UI |
| 离线缓存 | ✅ cache FFI 具备（cacheGetChapter 待封装） | ❌ UI 缺失 | 封装+UI |
| 应用日志 | ✅ appLog* 已交付 | ⚠️ 页面已有、6 处入口未接线 | 纯接线 |

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

**编写者**: Qoder
**日期**: 2026-08-06
**数据来源**: Grace（Flutter UI 缺口实测审计）、Sam（Rust 功能缺口源码级复查）两份审计结论，本报告不臆测审计外数据
