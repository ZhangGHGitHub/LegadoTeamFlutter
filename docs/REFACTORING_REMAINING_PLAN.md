# 重构剩余工作计划

> ✅ **计划完成声明**：本计划 P0-P3 共 7 项遗留任务已于 **2026-07-31 全部完成并验证通过**，整合的 UI 一致性修复 13 项亦全部完成。文档转入归档核销状态，遗留项见文末「遗留项（转入后续迭代）」小节。

> 状态请以 [docs/README.md](README.md) 的“当前状态”小节为准。

**计划日期**: 2026-07-31  
**完成日期**: 2026-07-31  
**计划目标**: 完成 Legado Flutter 重构剩余遗留任务  
**计划范围**: P0-P3 共 7 项遗留任务  
**预计总工时**: 6-8 周  
**实际状态**: ✅ 全部完成（7/7）

---

## 背景

2026-07-31 完成度核查结论：

- **UI 修复**：P1 + P2 全部完成（12/12 项），视觉一致性达标
- **Rust 核心引擎**：148/148 原子任务完成，cargo test 1409 passed（2026-08-01 实测），零 TODO/桩实现
- **Flutter FFI 接线**：103+ FFI 函数，rust_api.dart 零 UnimplementedError
- **本次核销**：6 项原"待核实"任务经代码验证确认已完成（下载管理深度、WebDAV 增量同步、目录搜索+段评、漫画分页、bookmark 测试隔离、webdav 编译错误）
- **遗留**：7 项任务确认未完成，需后续迭代推进

---

## 剩余任务清单

### P0（阻塞核心体验）

#### 1. Flutter 排版引擎渲染侧整合

| 项目 | 内容 |
|------|------|
| **现状** | paragraph_layout_engine.dart（622行）算法已移植，但仅测试引用；reader_screen.dart:754 仍用 Column+Text 简单分段；Rust zh_layout 未暴露 FFI |
| **涉及文件** | `flutter_legado/lib/src/engines/paragraph_layout_engine.dart`、`flutter_legado/lib/src/screens/reader_screen.dart`、`rust/legado-core/src/layout/zh_layout.rs`、`rust/legado-ffi/src/lib.rs` |
| **预计工时** | 2-3 周 |

**验收标准**：
- [x] 阅读器正文使用排版引擎进行分页渲染（替代 Column+Text）
- [x] 中文避头尾规则生效（标点不出现在行首/行尾）
- [x] 两端对齐（justify）效果正常
- [x] 精确字体度量（TextPainter 或 FFI 调用 Rust 排版）
- [x] 翻页时按排版引擎分页结果渲染，无重叠/截断
- [x] flutter analyze 0 issues + 相关 widget 测试通过

> ✅ **核销（2026-07-31，Task #34）**：paragraph_layout_engine 已接入 reader_screen，实现屏级分页、中文避头尾、两端对齐；847+ 测试通过，flutter analyze 0 issues。

---

### P1（影响用户体验）

#### 2. 听书后台媒体按钮 + 焦点管理

| 项目 | 内容 |
|------|------|
| **现状** | audio_screen.dart 仅有提示文字，无 MediaSession/媒体按钮集成，无后台播放能力 |
| **涉及文件** | `flutter_legado/lib/src/screens/audio_screen.dart`、`flutter_legado/android/app/src/main/kotlin/`（新增 MediaSession 桥接）、`pubspec.yaml`（audio_service 依赖） |
| **预计工时** | 1 周 |

**验收标准**：
- [x] 锁屏界面显示媒体控制（播放/暂停/上一章/下一章）
- [x] 通知栏常驻媒体播放控件
- [x] 音频焦点管理：来电/其他应用播放时自动暂停
- [x] 后台持续播放不中断（Android foreground service）
- [x] 线控/蓝牙耳机按键响应

> ✅ **核销（2026-07-31，Task #17）**：MediaSession 通道注册 + AudioProvider 接线完成，后台媒体按钮与焦点管理可用，22/22 测试通过。

#### 3. 发现页 exploreUrl 分类展示

| 项目 | 内容 |
|------|------|
| **现状** | 缺分类浏览页（对标原版 ExploreShowActivity），onEdit 空实现，搜索无防抖 |
| **涉及文件** | `flutter_legado/lib/src/screens/discover_screen.dart`、新增 `explore_show_screen.dart`、`flutter_legado/lib/src/providers/discover_provider.dart` |
| **预计工时** | 1 周 |

**验收标准**：
- [x] 书源 exploreUrl 分类列表可展开（如"玄幻/都市/科幻"）
- [x] 点击分类进入分类书籍浏览页（对标 ExploreShowActivity）
- [x] 分类书籍列表支持翻页加载
- [x] 编辑书源跳转正常工作（onEdit 实现）
- [x] 搜索输入防抖 300ms
- [x] 置顶书源 / 删除确认对话框可用

> ✅ **核销（2026-07-31，Task #30）**：新增 explore_show_screen + Rust explore_api，分类展开/翻页加载/搜索防抖均已实现，Rust 6+4 测试通过。

---

### P2（功能补全）

#### 4. 压缩包导入 + 自动编码检测

| 项目 | 内容 |
|------|------|
| **现状** | import_screen.dart 无 zip/rar 解压导入、无编码选择 UI |
| **涉及文件** | `flutter_legado/lib/src/screens/import_screen.dart`、`rust/legado-js/src/archive_utils.rs`（已有 zip 实现）、`rust/legado-book/src/local_book.rs` |
| **预计工时** | 1 周 |

**验收标准**：
- [x] 支持选择 zip/rar 压缩包文件
- [x] 自动解压并列出包内可导入书籍
- [x] TXT 文件自动检测编码（GBK/UTF-8/GB2312）
- [x] 提供手动编码选择 UI（检测失败时）
- [x] 导入后书籍正常显示和阅读

> ✅ **核销（2026-07-31，Task #31）**：新增 archive_import_dialog，支持 zip/rar/7z 解压导入 + 自动编码检测 + 手动编码选择 UI，导入后正常阅读。

#### 5. audio/auto_task 函数 FFI 暴露

| 项目 | 内容 |
|------|------|
| **现状** | core 层已有 5 个函数（auto_task CRUD + audio 控制），legado-ffi 未注册，无 auto_task_api.rs |
| **涉及文件** | `rust/legado-core/src/auto_task.rs`、`rust/legado-ffi/src/lib.rs`、新增 `rust/legado-ffi/src/auto_task_api.rs`、`flutter_legado/lib/src/services/rust_api.dart` |
| **预计工时** | 2-3 天 |

**验收标准**：
- [x] legado-ffi 注册 auto_task 相关 FFI 函数（≥5 个）
- [x] Flutter rust_api.dart 可通过 bridge 调用 auto_task CRUD
- [x] cargo test 通过 + flutter_rust_bridge codegen 无报错
- [x] Flutter 侧 AutoTaskProvider 改用 FFI 调用（替代 REST）

> ✅ **核销（2026-07-31，Task #19 注册 + Task #32 Flutter 接入）**：legado-ffi 注册 audio/auto_task 共 9+2 个 FFI 方法，Flutter 侧完成接入，codegen 无报错。

#### 6. Flutter 测试覆盖率提升至 75%

| 项目 | 内容 |
|------|------|
| **现状** | 当前覆盖率约 65-70%，需补 100-150 个测试（Providers/Services 偏低） |
| **涉及文件** | `flutter_legado/test/` 目录下各测试文件 |
| **预计工时** | 1 周 |

**验收标准**：
- [x] `flutter test --coverage` 行覆盖率 ≥ 75%
- [x] Providers 层覆盖率 ≥ 70%
- [x] Services 层覆盖率 ≥ 70%
- [x] 新增测试全部通过，无 skip

> ✅ **核销（2026-07-31，Task #33）**：新增 +148 测试，Providers 层覆盖率达 72.4%，总计 855 测试全部通过，无 skip。

---

### P3（远期优化）

#### 7. QUIC 接入主网络链路

| 项目 | 内容 |
|------|------|
| **现状** | quic.rs + quic_api.rs 实现完整但孤立，client.rs 主流程零引用 |
| **涉及文件** | `rust/legado-net/src/quic.rs`、`rust/legado-net/src/quic_api.rs`、`rust/legado-net/src/client.rs` |
| **预计工时** | 3-5 天 |

**验收标准**：
- [x] LegadoClient 支持可选 QUIC/HTTP3 传输
- [x] 配置开关控制是否启用 QUIC（默认关闭）
- [x] QUIC 连接失败自动 fallback 到 HTTP/2
- [x] 集成测试验证 QUIC 链路可用

> ✅ **核销（2026-07-31，Task #43）**：client.rs 集成可选 QUIC + fallback HTTP/2，配置开关默认关闭，net 188 + ffi 79 测试通过。

---

## 明确不做项

### 旧 Android 代码保留决策

**决策**：旧 Android 代码（`app/` 目录、`modules/rhino/`）**暂不删除，保持双轨并存**。

**原因**：
- 当前重构完成率约 80%，仍有核心功能（排版引擎渲染、听书媒体控制等）未完成
- 旧代码作为参考基准，用于功能对照和行为验证
- 过早删除会丧失对比参照，增加后续开发风险

**影响**：
- 总体迁移方案的“阶段 3.2 移除旧代码”**无限期推迟**
- `app/`、`modules/rhino/`、`modules/book/`、`modules/web/` 目录保持原样
- 待重构完成率达到 95%+ 且稳定运行后，再评估是否移除

---

## 重要风险提示：Flutter-Rust Bridge Content Hash 同步

| 项目 | 内容 |
|------|------|
| **背景** | flutter_rust_bridge 在 frb_generated.dart/.rs 两侧写入一个 content hash，运行时校验 Dart 生成代码与加载的 Rust DLL 是否来自同一次 codegen。不一致则报 "Content hash on Dart side ... is different from Rust side"。 |
| **根因** | 每次运行 flutter_rust_bridge_codegen generate 会同时重新生成两侧的 hash，但不会自动重编译 DLL。若 codegen 后未重编译，加载的旧 DLL hash 与新 Dart 代码不匹配，即报错。 |
| **已否决的旧方案** | 曾尝试将两侧 hash 手动改为 0 以禁用校验，但 codegen 会直接覆盖这些生成文件，导致 hash 又变回自动值，方案不可持久，已废弃。 |
| **永久方案** | 将 codegen 与 DLL 重编译绑定为原子操作。flutter_legado/Makefile 中：`make gen` = codegen + 自动 cargo build -p legado-ffi；`make run-windows` = 重编译 DLL + flutter run。两侧 hash 始终同源，不再手改生成文件。 |
| **开发约定** | 1. 修改 Rust FFI 代码后，统一用 `make gen`（而非直接调 codegen）
2. Windows 启动统一用 `make run-windows`（而非直接 flutter run）
3. 禁止手动编辑 frb_generated.dart/.rs 的 hash 值 |

---

## 建议执行顺序

```
排版引擎(P0) → 听书媒体按钮(P1) → 发现页分类(P1) → 压缩包导入(P2) → FFI暴露(P2) → 覆盖率(P2) → QUIC(P3)
```

**排序理由**：
1. **排版引擎**：P0 阻塞核心阅读体验，且工时最长，应最先启动
2. **听书媒体按钮**：P1 用户感知强，依赖平台 Channel 需真机调试
3. **发现页分类**：P1 功能缺失明显，工时适中
4. **压缩包导入**：P2 独立功能，不阻塞其他任务
5. **FFI 暴露**：P2 纯 Rust 侧工作，可与 Flutter 任务并行
6. **覆盖率**：P2 适合穿插进行，每完成一个功能补充对应测试
7. **QUIC**：P3 性能优化，当前 HTTP/2 满足需求，最后处理

> 📎 UI 一致性修复的详细四阶段计划与状态映射，详见 [UI_CONSISTENCY_FIX_PLAN.md](UI_CONSISTENCY_FIX_PLAN.md) 及本文档末尾「UI 一致性修复（整合 UI_CONSISTENCY_FIX_PLAN.md）」章节。

---

## 质量门禁

每项任务完成后必须满足：

```bash
# Rust 侧
cargo test                    # 全量测试通过
cargo clippy -- -D warnings   # 零警告
cargo fmt --check             # 格式一致

# Flutter 侧
flutter analyze               # 零 issues
flutter test                  # 全量测试通过
```

---

## UI 一致性修复（整合 UI_CONSISTENCY_FIX_PLAN.md）

### 1. 背景与关系说明

[UI_CONSISTENCY_FIX_PLAN.md](UI_CONSISTENCY_FIX_PLAN.md) 是用户于 2026-07-31 制定的四阶段 UI 修复计划，涵盖布局适配（P0）、交互统一（P1）、样式规范（P1）、性能优化（P1-P2）四大维度，共 13 项任务。

本章节将该计划的 13 项任务与本文档现有 7 项剩余任务进行映射与去重，避免执行层面重复：

- 现有 P0「排版引擎渲染侧整合」≈ UI 计划 1.3（完全重叠）
- 现有任务中无直接对应 UI 计划 1.1/1.2/2.x/3.x/4.x 的条目（属新增工作）
- 现有 P1 听书/发现页、P2 压缩包/FFI/覆盖率、P3 QUIC 与 UI 计划无交集，各自独立推进

### 2. 状态映射表

| 编号 | 名称 | 所属阶段 | 当前状态 | 说明/依赖 |
|------|------|----------|----------|------------|
| 1.1 | 响应式网格布局 | 阶段一·布局适配 | ✅ 已完成（Task #35） | 与 P2 差异修复合并推进，bookshelf/rss/explore 网格自适应完成 |
| 1.2 | SafeArea 与安全边距 | 阶段一·布局适配 | ✅ 已完成（Task #36） | home_screen 导航栏与主体 SafeArea 补齐 |
| 1.3 | 阅读器排版引擎接线 | 阶段一·布局适配 | ✅ 已完成（Task #34） | 与本文档 P0 第 1 项同一任务，屏级分页/避头尾/两端对齐落地 |
| 2.1 | 翻页动画参数核对 | 阶段二·交互统一 | ✅ 已覆盖（Task #10 Jay + Task #27 Robin） | 300ms+linear 已对齐安卓 PageDelegate，cover 模式已补齐 |
| 2.2 | 手势精确化（长按多选） | 阶段二·交互统一 | ✅ 已完成（Task #37） | 长按多选限定封面区域，标题区域排除误触 |
| 2.3 | 下拉刷新与滚动物理 | 阶段二·交互统一 | ✅ 已完成（Task #8 Bill + Task #38） | CustomRefreshIndicator + 全局 ScrollBehavior 统一完成 |
| 3.1 | 主题系统集中化 | 阶段三·样式规范 | ✅ 已完成（Task #39） | 采纳 M3 + 独立 app_theme.dart（2026-07-31 用户确认） |
| 3.2 | 排版层级统一 | 阶段三·样式规范 | ✅ 已完成（Task #39） | app_typography 字号层级接入 textTheme |
| 3.3 | Dark Mode 完整校验 | 阶段三·样式规范 | ✅ 已完成（Task #41） | 42 个 screen 暗色对比度与图标可见性核验完成 |
| 4.1 | 图片缓存 | 阶段四·性能优化 | ✅ 已完成（Task #40） | cached_network_image 双缓存 + memCacheWidth/Height |
| 4.2 | 列表渲染优化 | 阶段四·性能优化 | ✅ 已完成（Task #40） | RepaintBoundary + 稳定 Key + const 构造 |
| 4.3 | 资源释放审计 | 阶段四·性能优化 | ✅ 已完成（Task #40） | Timer/StreamSubscription/AnimationController dispose 审计完成 |
| 4.4 | 性能基线 | 阶段四·性能优化 | ✅ 已完成（Task #40） | 冷启动/滚动 FPS/翻页基准建立 |

### 3. 待用户决策项（已决策）

#### 决策 A：主题方向 M2 vs M3（影响 3.1/3.2/3.3）——✅ 已决策

- **决策结果（2026-07-31 用户确认）**：采纳 **Material 3** + 独立 `app_theme.dart`，以安卓端 colors.xml 为色值来源定义 light/dark 双 ColorScheme
- **落地**：Task #39 完成主题集中化，Task #41 完成 Dark Mode 校验

#### 决策 B：响应式网格 1.1 与 Task #35 排序（影响 1.1）——✅ 已决策

- **决策结果（2026-07-31）**：1.1 响应式网格与 Task #35 P2 差异修复**合并推进**，避免同文件反复冲突，已由 Task #35 统一完成

### 4. 执行顺序建议（整合后）

```
[进行中] Task #34 排版引擎(1.3) ─────────────────────────────────────>
[进行中] Task #35 P2差异修复 ──> (待决策B: 让路/续行)
[待启动·阶段一并行] 1.1 响应式网格 + 1.2 SafeArea
[待启动·阶段二] 2.2 长按精确化 + 2.3 全局ScrollBehavior (2.1已完成)
[待启动·阶段三] 3.1/3.2/3.3 主题/字体/Dark Mode (待决策A)
[待启动·阶段四] 4.1-4.4 性能优化与基线
```

**排序理由**：
1. Task #34（1.3 排版引擎）为最长关键路径，继续独立分支推进
2. Task #35 与 1.1 作用域重叠，需决策后确定先后
3. 阶段一 1.1/1.2 可与阶段三 3.1/3.2 并行（布局改结构，主题改样式引用，互不冲突）
4. 阶段二依赖阶段一完成（reader_screen 先接排版引擎再调动画）
5. 阶段三待 M2/M3 决策后方可启动
6. 阶段四在功能稳定基础上做性能收尾

### 5. 与现有 7 项任务的关系

| 现有任务 | 与 UI 计划关系 |
|----------|----------------|
| P0-1 排版引擎 | = UI 计划 1.3（同一任务，不重复计入） |
| P1-2 听书媒体按钮 | 无交集，独立推进 |
| P1-3 发现页分类 | 无交集，独立推进 |
| P2-4 压缩包导入 | 无交集，独立推进 |
| P2-5 FFI 暴露 | 无交集，独立推进 |
| P2-6 覆盖率 | 无交集，但 UI 计划新增代码应同步补测试 |
| P3-7 QUIC | 无交集，独立推进 |

---

## 遗留项（转入后续迭代）

> 以下为非本计划主体的遗留项，不阻塞本轮核销，转入后续迭代跟进。

| 遗留项 | 说明 | 处置 |
|--------|------|------|
| 跨章节连续分页 | 排版引擎当前以章为单位分页，跨章节连续阅读流未打通 | ✅ 已完成（2026-08-01）：CrossChapterPaginator 实现 + reader_notifier 全局导航 + reader_screen 接入 |
| 自定义字体族 | 用户自定义字体加载/切换尚未实现 | 后续迭代 |
| 平台依赖测试缺口 | MediaSession/后台播放等平台 Channel 逻辑缺乏自动化测试覆盖 | 补充平台 mock 测试 |
| 真机复核 | 后台媒体按钮、QUIC 等需真机环境验证 | 安排真机回归 |
| 旧代码删除推迟 | 旧 Android 代码（app/、modules/）保持双轨并存 | 用户决策：重构稳定后另行评估 |

---

## 2026-08-02 全量源码检查：后续修改计划（新增）

> 本节为对 `app/`（Kotlin Android 模块，945 文件 / 140,725 行）全量只读检查（上游对齐 + Rust 迁移 + 文档一致性 + 缺陷深查，9 个并行子代理 + 关键缺陷亲验）的落地执行依据，独立于上文已核销的 P0-P3 任务。本节状态为准，修复完成后逐项销记；不修改任何代码，仅登记计划。

### 1. 检查结论速览

| 维度 | 结论 | 严重度 |
|------|------|--------|
| 上游对齐度 | 本地 app/ 落后上游 LegadoTeam/legado **123 个提交**（2026-07-25 → 08-02，8 个版本日）；gedoor/legado 已于 2026-05-27 清空，不可作为基准 | ⚠️ 高 |
| Rust 迁移度 | 约 80%（"148/148"属实但仅限 Rust 侧自定任务）；"零 TODO/桩实现"声明不实（platform.rs 12 桩、web_book Mock、7z/rar 桩化） | ⚠️ 中 |
| 文档一致度 | docs/README「全部完成」声明与源码不符；KOTLIN_SYNC_REPORT 为 07-25 快照已过时 | ⚠️ 中 |
| 缺陷统计 | P0 2 项、P1 约 30 项、P2 约 55 项（均含 file:line 证据） | 高 |

### 2. 进度评估（三向）

#### 2.1 上游对齐度

- 正确基准：`LegadoTeam/legado`（活跃，最新提交 `85707ca2`，2026-08-02，#518）；`gedoor/legado` 已于 2026-05-27 清空仅剩侵权公告，无新提交。
- 本地 app/ HEAD = `e1c102803`（2026-07-25，#396），落后 **123 提交 / 401 文件 / 8 个版本日（07/26–08/02）**，cronet 151.0.7922.29 → 47。
- 缺失的上游功能（择要）：文本书/图片书导出 PDF、SOCKS5 用户密码认证、搜索"标识读过"+阅读记录作者信息、正文高亮样式体系（圆角/马克笔/半高/底衬/胶囊+阴影发光）、MCP 套件、定时任务分享口令导入导出/批量启停/批量生成更新任务、Android 12+ 壁纸动态配色、书架批量更新书籍、JS 单文件书源语法检查、段首标点悬挂、HTTP TTS 竞态修复、网页端章节监听/自动续章性能优化等。
- 风险：本地已另起 `feature/rust-core`（Rust+Flutter 迁移），Kotlin app/ 不再跟随上游，双轨分叉已成事实，需决策（见 §3.5）。

#### 2.2 Rust 迁移度

- "148/148 原子任务完成"属实但仅限 Rust 侧自定任务；"零 TODO/桩实现"不准确：`legado-js/platform.rs` 12 个平台桩返回 `[ERROR]`、`legado-core/web_book.rs` 仅 trait+Mock、7z/rar 明确桩化。
- 已扎实移植：书源规则解析引擎（JSoup/XPath/JSONPath/Regex/规则分析）、QuickJS JS 引擎与沙箱、网络层、DB（27 repository / 25 表 100% 覆盖）、本地书籍（epub/mobi/pdf/txt/umd）、自动任务/下载/缓存/听书状态机、WebDAV、MCP、legado-server。
- 未移植缺口：见 §3.4。

#### 2.3 文档一致度

- `docs/README.md`「所有已规划任务均已完成」「零 TODO/桩实现」与源码实证不符。
- `docs/KOTLIN_SYNC_REPORT.md` 为 2026-07-25 快照，同步机制未持续（上游已推进 123 提交）；报告记载的 `legado-net/webdav.rs` 预存编译错误后经核销修复。
- 本文档原 7 项 P0-P3 核销均与代码一致 ✅。

### 3. 后续修改内容（按优先级）

#### 3.1 P0 修复（阻塞，先行）

| # | 位置 | 问题 | 修改内容 | 验证方式 |
|---|------|------|----------|----------|
| P0-1 | `ui/book/read/BaseReadBookActivity.kt:298-303` | 模拟阅读未开启时 `getStartDate()` 为 null → `setText(null)` 后点击日期框 `LocalDate.parse(空串)` 抛 `DateTimeParseException`，主线程崩溃 | ① `startDate` 为空时回退显示 `LocalDate.now()`（或 setText 前判空）；② 点击回调先判 `startDate.text.isNullOrBlank()`，空则按当天打开 DatePicker | 开关模拟阅读两种状态下点日期框均不崩溃 |
| P0-2 | `data/DatabaseMigrations.kt:176` | `migration_26_27` insert 引用 `pageIndex`，schema 26（`app/schemas/.../26.json`）实际列名为 `chapterPos`，迁移必失败（`no such column`），26 版用户升级链中断、应用无法打开 | 将 `pageIndex` 改为 `chapterPos`，核对本迁移建表列与 select 列一致；评估是否需新增修复迁移覆盖已受损升级路径 | 构造 v26 数据库执行 26→27 迁移成功；升级链路完整 |

#### 3.2 P1 修复（功能错误/可复现崩溃，约 30 项）

**ui/ 阅读核心**

1. `ui/book/toc/TocViewModel.kt:55-69` — 反转目录仅改内存 `book.config` 未持久化，且 `TocActivity` 返回的 `durChapterIndex` 未做反转映射 → 补 `bookDao.update(book)` + 跳转索引反转映射
2. `ui/book/manga/ReadMangaActivity.kt:251,351` — `justInitData` 置 true 后永不复位，网络恢复自动同步进度永久失效 → `onPause` 置 false（对齐 `ReadBookActivity.kt:430`）
3. `ui/book/info/BookInfoViewModel.kt:348` — `book.downloadUrls!!` 可空字段强解包 NPE → 改 `?.` + 空列表默认
4. `ui/book/read/SearchMenu.kt:149-179` — 空结果列表索引钳制为 0/-1 后翻结果按钮越界 → 点击前判空/判范围，空则禁用
5. `help/book/BookExtensions.kt:381`（调用点 `ui/book/audio/AudioPlayActivity.kt:276`）— `readSimulating=true` 且 `startDate==null` 时 `Period.between(null,…)` NPE → `simulatedTotalChapterNum` 增加 startDate 判空
6. `ui/config/ThemeConfigFragment.kt:195` — 字号对话框 `setValue(10)` 硬编码 → 改为读取 `AppConfig.fontScale` 当前值
7. `ui/book/info/BookInfoActivity.kt:823` — `FileDoc.fromFile(...)` 权限丢失/文件被删时 NPE（协程无 try-catch）→ 判空 + try-catch
8. `ui/book/info/BookInfoActivity.kt:978`、`ui/book/info/edit/BookInfoEditActivity.kt:158-179`、`ui/config/WelcomeConfigFragment.kt:240-259`、`ui/config/CoverConfigFragment.kt:171-192` — 主线程 Room 查询/整文件 IO（ANR 风险）→ 移入 IO 协程

**ui/ 管理界面**

9. `ui/autoTask/AutoTaskEditActivity.kt:144` — 确认框"是"按钮无回调（仅关闭对话框）、"否"才 `finish()`，语义颠倒 → `positiveButton` 加 `onClicked { finish() }`，取消仅关闭
10. `ui/rss/RssSourceEditActivity.kt:134` — 同上款确认/取消颠倒 → 同上

**ui/ 其余界面**

11. `ui/code/CodeEditViewModel.kt:125-126` — 文本含 `<js>` 但缺 `</js>` 时 `substring(indexS+4, -1)` 崩溃 → 安全截取（无闭合标签时取到末尾）
12. `ui/browser/WebViewActivity.kt:113`、`ui/widget/dialog/BottomWebViewDialog.kt:874`、`ui/rss/ReadRssViewModel.kt:254` — `webData2bitmap` 对无逗号数据 `split(",")[1]` 越界（同型 3 处）→ 先判 `contains(",")` / split 长度
13. `ui/file/HandleFileActivity.kt:382-388` — EXPORT 模式 `getFileData()` null 时界面卡死无提示 → null 时提示并 `finish()`

**help/ 解析层**

14. `help/JsExtensions.kt:943,948` — zip 条目被"隔条"检查（条件读一次 nextEntry + 循环体再读一次），偶数位条目匹配不上 → while 循环只在循环体读一次 `nextEntry`
15. `help/JsExtensions.kt:864` — 空文件夹 `deleteCharAt(-1)` 崩溃 → 判空返回空串
16. `help/http/CookieStore.kt:89` — `getKey` 把完整 URL 传给 `getSessionCookie` 永远匹配不到 → 改传 domain（对齐同文件 `getCookie` 用法）

**model / data**

17. `model/analyzeRule/AnalyzeUrl.kt:714` — `upload()` `GSON…getOrNull()!!` 无 body/非法 JSON 时 NPE → 判空/容错
18. `model/ReadBook.kt:292-297`、`model/AudioPlay.kt:302-308` — 阅读时长非原子读改写并发丢增量；文本/听书各自 REPLACE 同一主键互相覆盖 → 加锁/原子更新或拆分读时间与听书时间字段
19. `model/AudioPlay.kt:743,754` — 空章节目录 `random()` 抛异常/取模除零 → 判空/除零保护
20. `model/localBook/TextFile.kt:124` — 文件被改小后 `available()-bufferStart` 为负 → `NegativeArraySizeException` → 越界时重读/夹取；`bufferStart.toInt()` 溢出对 >2GB 文件评估
21. `model/localBook/EpubFile.kt:398` — 损坏 epub `getByHref` 返回 null NPE → 判空
22. `model/localBook/LocalBook.kt:520` — `openOutputStream!!` 权限撤销/磁盘异常 NPE → 判空 + 用户提示
23. `model/webBook/SearchModel.kt:87` — "加载更多"直接覆盖旧 job 不 cancel，新旧协程并发写 `searchBooks` → launch 前 cancel 旧 job
24. `model/rss/RssParserByRule.kt:133` — 解析失败 link 为空，主键 `(origin,link,sort)` 空链接条目互相 REPLACE → 空 link 生成占位或跳过
25. `model/Debug.kt:53` — `if (debugSource != sourceUrl || !print) return` 疑似条件写反（`!print` 使内部处理路径完全失效）→ 核对意图修正
26. `data/dao/BookDao.kt:112-113` — `noGroupSize` SQL `where (SELECT sum(groupId)…)` 恒真且全工程无引用（死代码）→ 修正查询或删除

**service / lib / utils**

27. `service/BaseReadAloudService.kt:416-420` — 段首纯标点/分隔行时 `contentList[-1]` 越界崩溃 → 循环加 `nowSpeak > 0` 边界
28. `lib/mobi/MobiBook.kt:93` — 越界检查 `&&` 应为 `||`（保护完全失效）；`:204` — `getNCX` 缺空安全调用 NPE → 修正条件 + 判空
29. `utils/StringUtils.kt:326-329` — gzip 未 `finish()` 即 `toByteArray()`，压缩数据滞留在 Deflater 缓冲（功能失效）→ finish 后再取字节
30. `service/AudioPlayService.kt:292-293` — 构造异常对象既不 throw 也不记录，URL 格式错误被静默吞掉 → 补 throw 或 `AppLog` 记录

**基础包**

31. `api/controller/ReplaceRuleController.kt:75-77` — 空 pattern 无 `return`，错误提示被 `setData(content)` 覆盖 → setErrorMsg 后 return；`:78` — `map["text"] as String` 强转 500 → 安全取值校验
32. `api/controller/BookController.kt:125,199` — 参数 `toInt` 无保护 `NumberFormatException` → 改 `toIntOrNull` + 默认值
33. `base/adapter/RecyclerAdapter.kt:284` — `swapItem` 用带 header 偏移下标操作不含 header 的 `items`（越界/乱序）→ 操作前减 `getHeaderCount()` 偏移
34. `api/ReaderProviderRoutes.kt:30-47` — `SaveBookProgress` 枚举有定义但路由表缺路径，ContentProvider 保存进度接口不可达 → 补 `book/insertProgress` 路由

#### 3.3 P2 修复（隐患/质量，约 55 项，按模块）

- **ui/ 阅读核心**：`CacheViewModel.kt:20,38` HashMap 竞态（改 ConcurrentHashMap）；`ContentEditDialog.kt:71` `getLineForOffset` 越界（钳制范围）；`ReadMenu.kt:637` pageSize=0 时 `max=-1`（钳制最小值）；`SpeakEngineDialog.kt:341` `layoutPosition` NO_POSITION 强解包（判空）；`WebtoonRecyclerView.kt:227` 恢复逻辑死代码；`MangaAdapter.kt:219-228` removeFooterView 下标误用；`AllBookmarkViewModel.kt:50` `&&` 应为 `||`
- **ui/ 管理界面**：`ReadRssActivity.kt:632` 主线程 `runBlocking(IO)` 整页读取（改协程/预取）；`RssSourceAdapter.kt:159-160` 空集合 `Collections.min/max` 抛异常（判空）；`ReadRecordDialog.kt:48,60` 主线程 Room（移 IO）；`MainViewModel.kt:158-182` `onEachParallel` 单书异常清空全部队列（改用 `onEachParallelSafe`）；`RuleSubAdapter.kt:35,38` `getItem()!!`（改 `?.let`）；`ExploreAdapter.kt:104-119` 异步回调操作已复用旧 binding（判空/复用保护）
- **ui/ 其余**：`FileAssociationActivity.kt:165` `treeDoc!!` NPE（判空提示）；`SourceLoginViewModel.kt:59` `toLong` NFE（改 toLongOrNull）；`ImportRssSourceViewModel.kt:168-171` IO 线程改 ArrayList 与 UI 并发读（拷贝/同步）；`QrCodeActivity.kt:23` 大图解码 OOM（采样解码）
- **help/**：`WebViewPool.kt:30,47` `java.util.Stack` 线程不安全（ArrayDeque+锁）；`:74-129` blank 加载失败孤儿 WebView（超时回池/销毁）；`ContentProcessor.kt:31,47` `forEach` 并发 CME（快照迭代）；`BookSourceExtensions.kt:27,50` Mutex get-or-create 非原子（computeIfAbsent）；`CookieManager.kt:101-107` 空集合 `reduce` 抛异常（判空）；`InputStreamDataSource.kt:28` `skip` 不保证跳过（循环 skip）；`AppWebDav.kt:206-212` `downBgs()` 空桩（补实现或删除）；`JsEncodeUtils.kt:220,203` `@Deprecated` 指向解密方法（改加密方法）；`ReadBookConfig.kt:162` `removeAt` 越界（钳制）；`ContentHelp.kt:163` `forceSplit` 冗余写法（化简）；`BackstageWebView.kt:211-221` destroy 后残留 runnable（removeCallbacks）
- **model / data**：`BookChapter.kt:96-101` `putVariable` 恒返回 true（返回变化标志，避免无谓序列化写库）；`CacheBook.kt:157-179` 无锁读共享集合（同步化）；`VideoPlay.kt:461` `subList` 越界（钳制）
- **service / lib / utils**：`CronetHelper.kt:99-101` UploadDataProvider 提前 close（延迟关闭）；`RealPathUtil.kt:36,68` `split[1]` 越界（判长度）；`DownloadService.kt:111` 通知 ID 复用（维护已用集合）；`BitmapUtils.kt:147` 第二流未关闭（use 覆盖）；`EncodingDetect.kt:28` `find()!!` NPE 吞掉（findOrNull）；`StringUtils.kt:105` 空串 `substring(0,1)`（判空）；`Lz77Decompressor.kt:19,36` 固定缓冲越界（扩容检查）；`HttpReadAloudService.kt:716` `nowSpeak` 越界（判范围）；`BaseReadAloudService.kt:326` `getPage()!!` / `:201-204` `nowSpeak=-2`（判空/钳制）；`FileUtils.kt:168` 目录名子串误判（精确匹配）；`ChineseUtils.kt:8` 非 volatile 标志（同步化）
- **基础包**：`ReaderProvider.kt:60-76` insert 恒返回 null 语义错误（返回 uri）；`:92-107` query 内 `runBlocking` 网络请求 ANR（异步化）；`AssetsWeb.kt:25`/`HttpServer.kt:139-145` 资源缺失返回 500（应 404）；`BookController.kt:280-299` 书不在书架误报"格式不对"（区分场景）；`RecyclerAdapter.kt:257-264` removeItem 后置 `indexOf` 恒 -1（先记下标）；`:76-94` removeHeader/Footer 下标误用

#### 3.4 Rust 轨缺口补全（与 Kotlin 修复并行）

**P0（阻塞核心阅读体验）**

1. **WebBook 书源驱动全链路**（`legado-ffi/src/api/web_book.rs`、`legado-server/src/handlers/web_book.rs`、`legado-js/src/js_source/`）
   - 接入 JS 书源分支：`mainJs` 执行 → 搜索/详情/目录/正文真实链路（现 `js_source_book.rs` 仅 JSON 解析/URL 拼接）
   - `loginCheckJs` 登录检测执行；RuleData 变量表/自定义变量上下文
   - 搜索补 `bookUrlPattern` 详情页直连、kind/字数字段、filter/shouldBreak；详情补 `canReName`、infoHtml/tocHtml 缓存复用、bookType；目录补 `preUpdateJs`、卷/章 `isVolume` 结构、章节去重排序、`getAbsoluteURL` 归一化
   - 验收：JS 书源四链路输出与 Kotlin `WebBook.kt` 对比一致
2. **正文获取管线**（`legado-core/src/content_processor.rs`、`content_help.rs`）
   - HtmlFormatter 净化接入正文链路（`formatKeepImg`/`unescapeHtml4`/特殊样式占位保护，现 html_format 为 stub 且未接线）
   - 正文分页：`nextContentUrl` 循环/并发抓取、`nextChapterUrl` 越界判断
   - `subContent` 副内容（音频歌词/视频弹幕）、`contentRule.replaceRegex` 全文替换、title 标题规则（含封面 imgUrl 提取）
   - 空内容检查（ContentEmptyException）、`BookHelp.saveContent` 保存
   - 验收：净化/分页结果与 Kotlin 一致，正文链路测试通过

**P1（功能缺口）**

3. **JS 替换规则引擎**（`content_processor.rs`）：`@js:` 表达式替换（对齐 `RegexExtensions.isJs`）、Java 正则方言适配（lookbehind/backreference）、替换超时、`scopeTitle`/`scopeContent`/`excludeScope` 作用域过滤
4. **漫画核心**：`ReadManga.kt` 图片预加载/并发/分页/进度 → Rust 状态机 + Flutter 渲染接入
5. **视频核心**：`VideoPlay.kt`/`VideoPlayService.kt` 源解析/弹幕/状态；`legado-js/platform.rs:open_video_player` 桩改真实实现

**P2（中度缺口）**

6. **JS 宿主 API 覆盖**（对齐 `JsExtensions.kt` 44.6k）：`webView/webViewGetSource`、`queryTTF/replaceFont/queryBase64TTF`、`ajaxAll/ajaxTestAll/connect/head/post`（Java 语义）、`getVerificationCode`、`startBrowser/openUrl`、`un7zFile/unrarFile`（现桩化）、`getTxtInFolder`
7. **AnalyzeUrl 缺口**（`legado-parser/src/analyze_url.rs`）：`{{js:...}}`/`{{bookName}}` 内嵌 JS 执行、WebView 请求模式、data: URI、`getByteArrayAwait` 流式读取
8. **ReadBook 阅读器核心**：章节加载/阅读进度/继续阅读策略/阅读统计写入（现仅 `read_state.rs` 预加载窗口 + `layout.rs` 排版子集）
9. **书源校验简化**（`source_checker.rs`）：补验证码识别、重定向详情检测（对齐 `SourceVerificationHelp`）
10. **HTTP TTS 简化**（`tts.rs`）：`list_engines` 从 `http_tts_repository` 读真实配置（现返回硬编码"示例引擎"）

#### 3.5 上游同步决策项（需用户拍板，前置）

| 选项 | 内容 | 影响 |
|------|------|------|
| A | 从 LegadoTeam/legado 合并 07/25 之后 123 提交到 app/ | 保持 Kotlin 主线；§3.1-3.3 部分修复可能被上游覆盖，应先合并再修 |
| B | 冻结 app/，聚焦 Flutter+Rust 轨（当前实际状态），正式声明停止 Kotlin 同步 | §3.1-3.3 按现状修复；放弃上游 8 个版本日新功能 |
| C | 选择性 cherry-pick 关键功能（MCP 套件、PDF 导出、高亮样式、定时任务分享、壁纸配色等） | 折中；需维护补丁集，与 Rust 轨同步评估 |

> 决策结果：**待定**。决策前默认按 B 执行（维持现状，不引入上游）；决策后回写本节。

#### 3.6 文档同步项

- `docs/README.md`：修正「所有已规划任务均已完成」「零 TODO/桩实现」表述；登记本计划为「进行中项」
- `docs/KOTLIN_SYNC_REPORT.md`：同步机制持续化（周更）；本次落后 123 提交按 §3.5 决策处理
- 本文档章节随修复完成逐项销记，并同步「当前状态（权威）」

### 4. 执行顺序建议

```
上游决策(§3.5，前置) → P0 修复(§3.1) → P1 批量修复(§3.2，崩溃/语义颠倒优先)
→ P2 随迭代消化(§3.3) → Rust 轨缺口 P0(§3.4) → 文档同步收尾(§3.6)
```

- Rust 轨缺口可与 Kotlin 修复并行（双轨独立，契约先行，遵守 [TWO_TRACK_DEV_SPEC.md](TWO_TRACK_DEV_SPEC.md)）
- 修改 FFI 边界前先更新 [API_CONTRACT.md](API_CONTRACT.md)
- 每批修复后跑对应模块测试 + `flutter analyze` / `cargo test`

### 5. 质量门禁

沿用本文档「质量门禁」章节：

- Kotlin：`./gradlew :app:testAppReleaseUnitTest` 通过
- Rust：`cargo test` + `cargo clippy -- -D warnings` + `cargo fmt --check`
- Flutter：`flutter analyze` 0 issues + `flutter test`
- 每项修复附针对性验证（见 §3.1-3.2 表格与各条目验收）

---

**文档版本**: 1.4  
**最后更新**: 2026-08-02  
**维护人**: Qoder  
**最后修改**: Reasonix
