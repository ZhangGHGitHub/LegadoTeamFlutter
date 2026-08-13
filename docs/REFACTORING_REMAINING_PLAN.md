# 重构剩余工作计划

> ✅ **计划完成声明**：本计划 P0-P3 共 7 项遗留任务已于 **2026-07-31 全部完成并验证通过**，整合的 UI 一致性修复 13 项亦全部完成。文档转入归档核销状态，遗留项见文末「遗留项（转入后续迭代）」小节。
>
> ⚠️ **Doc8 口径修正（2026-08-13）**：文首「P0–P3 全部完成」仅指原 7 项计划任务；**后续开放残留**（schema 三表名、半接通、验收债等）以 [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md)、[GAP_AUDIT_2026-08-12.md](GAP_AUDIT_2026-08-12.md)、[USER_TEST_RESULTS_2026-08-13.md](USER_TEST_RESULTS_2026-08-13.md) 为准。
>
> **Doc7**：文档名「schema v102 专项」= 代码 `Migration103To104` / `SCHEMA_VERSION=104`（v102/v103 号段已占用）。

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
| 自定义字体族 | 用户自定义字体加载/切换 | ✅ **已闭合（2026-08-13 核销）**：`FontScreen` 导入 ttf/otf + `FontLoader`；阅读器 `reader_page_view._refreshFontFamily` 消费；设置入口对齐 FontSelect |
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

> ✅ **核销（2026-08-03）**：本节 10 项缺口已于 2026-08-03 全部完成并核验（相关提交：301b83b7f / 064999d63 / 90d197b6f / f008f5467 / cad00a257）。

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
   > ✅ 部分核销（2026-08-05，Task #161，6f5614e24）：`getVerificationCode`/`startBrowserAwait` 验证码 JS 钩子已交付（FFI 事件流 + 提交回传），其余项维持登记
   > ✅ 部分核销（2026-08-05，Task #164/#166/#168，缺口清单清零批次）：unzip 断线修复 + 6 个零星 API 已交付；RSA/SM2 非对称加密 JS API 已交付；`unrarFile` 正式降级（纯 Rust RAR 解压生态调研无可用 crate，见 rust/PROGRESS.md 已知降级项登记），其余项维持登记
   > ⚖️ Task #131 裁决（2026-08-05 审计）：原登记名单（configGet/threadPool/randomString 等）为登记失实（Kotlin 无此 API），实际交付真实（提交 249f95451：+15 函数），已在 rust/PROGRESS.md 纠正
7. **AnalyzeUrl 缺口**（`legado-parser/src/analyze_url.rs`）：`{{js:...}}`/`{{bookName}}` 内嵌 JS 执行、WebView 请求模式、data: URI、`getByteArrayAwait` 流式读取
8. **ReadBook 阅读器核心**：章节加载/阅读进度/继续阅读策略/阅读统计写入（现仅 `read_state.rs` 预加载窗口 + `layout.rs` 排版子集）
9. **书源校验简化**（`source_checker.rs`）：补验证码识别、重定向详情检测（对齐 `SourceVerificationHelp`）
   > ✅ 已核销（2026-08-05，Task #159，86c299923）：书源校验 FFI 已交付（sourceCheck/sourceCheckStream/sourceCheckCancel），本台账 §4.2.2 P1-1 同步销记
10. **HTTP TTS 简化**（`tts.rs`）：`list_engines` 从 `http_tts_repository` 读真实配置（现返回硬编码"示例引擎"）

#### 3.5 上游同步决策项（需用户拍板，前置）

| 选项 | 内容 | 影响 |
|------|------|------|
| A | 从 LegadoTeam/legado 合并 07/25 之后 123 提交到 app/ | 保持 Kotlin 主线；§3.1-3.3 部分修复可能被上游覆盖，应先合并再修 |
| B | 冻结 app/，聚焦 Flutter+Rust 轨（当前实际状态），正式声明停止 Kotlin 同步 | §3.1-3.3 按现状修复；放弃上游 8 个版本日新功能 |
| C | 选择性 cherry-pick 关键功能（MCP 套件、PDF 导出、高亮样式、定时任务分享、壁纸配色等） | 折中；需维护补丁集，与 Rust 轨同步评估 |

> 决策结果：**选项 A 已执行（2026-08-04）**——从 LegadoTeam/legado 同步 141 个提交（e1c102803 #396 → 308ac7b1e #543），提交 `b10285b8c`，424 文件 +31,710/-2,235 行。
>
> 后续口径（按选项 A 原定“先合并再修”）：
> - §3.1-3.3 的 Kotlin 修复需按新基线（308ac7b1e）逐条复核 file:line 后再执行（同步导致 89 条修复项的证据基线过期）
> - 注意：Kotlin 两项 P0（BaseReadBookActivity.kt 日期崩溃、DatabaseMigrations.kt migration_26_27）经同步仍未修复（上游同样带病）

#### 3.6 文档同步项

- `docs/README.md`：修正「所有已规划任务均已完成」「零 TODO/桩实现」表述；登记本计划为「进行中项」
- `docs/KOTLIN_SYNC_REPORT.md`：同步机制持续化（周更）；本次落后已按 §3.5 决策处理（2026-08-04 同步 141 个提交，见报告「同步窗口 2」）
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

## §4 2026-08-03 重构进度全面审计整合计划（新增）

> 本节为 2026-08-03 四路并行源码级审计（Rust 工作区实测 / Flutter 静态审计 / 数据库与 FFI 契约对照 / docs 文档梳理）结论的整合台账。登记原则与 §3 一致：只登记计划、不修改任何代码；新登记项一律不标核销，完成后逐项销记。涉及 FFI 边界的变更先更新 [API_CONTRACT.md](API_CONTRACT.md)，跨轨协作遵守 [TWO_TRACK_DEV_SPEC.md](TWO_TRACK_DEV_SPEC.md)。

### §4.1 审计总览

#### 4.1.1 审计方式

| 路 | 审计内容 | 方式 |
|---|---|---|
| 第一路 | Rust 各模块完成度（8 个活跃 crate + 1 个废弃模块） | 源码级实测：文件/行数统计、桩标记全量扫描、`cargo test` 实测（默认 workspace 约 1752 passed）、Kotlin 原版逐目录映射，并与 PROGRESS.md / README.md / DEVELOPMENT.md / MIGRATION_WORKFLOW.md 交叉核对 |
| 第二路 | Flutter 前端与 FFI 集成 | 纯只读代码/文档取证：架构分层、FFI 桥接链路、Mock vs 真实 FFI 接入清单、页面覆盖与 Android 原版对比、测试覆盖 |
| 第三路 | 数据库迁移与 FFI 契约 | 静态源码审计：legado-db 迁移链（v90→v96）× Room v95 基线（`app/schemas/.../95.json`）逐表对照、API_CONTRACT.md 35 模块 171 方法实现对照、桥接链路断裂点排查 |
| 第四路 | 重构文档梳理 | docs/ 下 25 份文档 + 3 个基线目录调查，跨文档矛盾与过期信息登记 |

#### 4.1.2 总体结论

| 维度 | 结论 |
|---|---|
| Rust 轨道 | 整体完成度约 **97-98%**；240 文件 / 约 79,197 行；26/26 表 Repository 100% 覆盖；189 个 FFI api 公开函数、72 个 HTTP/WS 路由实测；源码零 todo!/unimplemented!；实测测试约 1752 passed（高于文档记载的 1409） |
| Flutter 架构 | 分层与状态管理 **100%**（Riverpod Notifier + freezed 全量迁移，四层边界清晰）；FFI 桥接基础设施完成；真实 FFI 接入约 90% |
| FFI 主链路 | `rust/legado-ffi/src/ffi.rs` 166 个 frb 函数 ↔ `flutter_legado/lib/src/bridge/ffi/ffi.dart` 166 绑定完全对齐；API_CONTRACT.md 35 模块 171 方法契约层面全部满足（部分为 Dart 侧兜底实现） |
| 数据库 | 核心 10 张表（books/book_sources/chapters/book_groups/replace_rules/searchBooks/cookies/bookmarks/auto_task_rules/caches）对齐 Room v95 良好；**8 张表存在字段级偏离**（rssArticles/rssReadRecords/rssStars/readRecord/httpTTS/ruleSubs/dictRules/keyboardAssists）+ search_keywords 语义缺失；users 表与 Room servers 表不兼容 |
| 书源校验 | Rust 侧 `legado-net/src/source_checker.rs`（962 行）已实现，但仅被 legado-server HTTP handler 使用，**未暴露 FFI**；Flutter 侧无入口、BookApi 无方法 |
| 文档 | docs/README.md「全部完成 / 零 TODO/桩实现」声明与源码不符且 §3.6 要求修正后至今未改——当前最大文档矛盾；另有多处跨文档过期信息（见 §4.1.3） |

#### 4.1.3 关键矛盾登记

| # | 矛盾 | 证据与处置 |
|---|---|---|
| ① | docs/README.md「所有已规划任务均已完成」「零 TODO/桩实现」与源码不符 | §2.3（2026-08-02）已判定不实（platform.rs 12 桩、web_book Mock、7z/rar 桩化），§3.6 要求修正但 README 现状未改。处置：按 §3.6 执行 |
| ② | 本台账 §3.4 Rust 缺口清单与本次 Rust 实测冲突 | §3.4 P0-1 登记「WebBook 仅 trait+Mock」，但本次实测 `api/web_book.rs` 测试名（test_build_engine_creates_real_fetcher / test_real_fetcher_default）证实 StubFetcher 已替换为真实书源链路；§3.4 P2-9 登记「书源校验简化」，实测 `legado-net/src/source_checker.rs` 已实现 962 行（含验证码/重定向信息类型）。上述条目**标注「待复核」**：复核确认已完成者销记，确属部分完成者修订条目范围 |
| ③ | searchCover / dictLookup：Rust 已交付、UI 未切换 | API_CONTRACT.md 需求区标 ✅（Rust/bridge/BookApi/RustApi 均已实现）；UI_RESTRUCTURE_PLAN Phase 6 仍标「🟡 待 Rust 交付」；代码实测 `change_cover_notifier.dart` 仍用 `_mockSearch`、`dict_notifier.dart` 仍查 `_localDict`。处置：见 §4.3 P0-1 |

### §4.2 Rust 后端部分：后续解决方案与实施步骤

#### 4.2.1 P0（阻塞级）

**P0-1 legado-ffi 测试竞态隔离修复**——✅ 已完成（2026-08-05，Task #165：FFI 测试串行锁消除竞态，3 轮并行验证零 flaky）

| 项目 | 内容 |
|------|------|
| **问题** | `cargo test --workspace` 间歇性失败：第一轮 config_api::test_config_crud、bookmark_api::test_search_bookmarks_by_content 失败，第二轮 1 个失败，单独运行 0 失败。根因：所有 FFI 测试经 `db_state::ensure_test_db()` 共享同一个全局 OnceLock 内存数据库（`db_state.rs:57-66`），并行测试线程互相污染数据 |
| **证据** | `rust/legado-ffi/src/db_state.rs:57-66`；实测现象与 PROGRESS.md「cargo test 1409 passed 稳定通过」「bookmark 测试隔离已修复」声明不符 |
| **解决方案** | 改为每测试独立 DB（各测试用例各自创建独立内存库）或测试串行化 |
| **实施步骤** | ① 重构 `db_state.rs` 的测试库获取机制，提供按测试名/线程隔离的独立内存库实例（或 `serial_test` 串行化）；② 复跑 config_api / bookmark_api 测试多轮验证；③ 更新 PROGRESS.md 测试稳定性描述 |
| **验收** | `cargo test --workspace` 连续 3 轮全部通过，无间歇性失败 |

> ✅ 核销（2026-08-05，Task #165）：FFI 测试串行锁方案落地，消除共享内存库并行污染；3 轮并行验证零 flaky，验收标准（连续 3 轮全通过）已满足

**P0-2 数据库偏离表修复（v96→97 迁移对齐 Room v95 列名）**——✅ 列级偏离已完成（v101，users/servers 语义差异登记不改名）

| 项目 | 内容 |
|------|------|
| **问题** | 8 张表字段级偏离 Room v95 基线 + users/servers 不兼容 + SCHEMA_VERSION=96 自造语义未登记（详见下表） |
| **证据** | `rust/legado-db/src/schema.rs`（SCHEMA_VERSION=96，26 表 DDL）、`rust/legado-db/src/migration/migrations.rs`（现有 90→96 迁移链）、Room 基线 `app/schemas/io.legado.app.data.AppDatabase/95.json`、`app/src/main/java/io/legado/app/data/AppDatabase.kt`（version = 95） |
| **解决方案** | 新增 v96→97 迁移对齐 Room v95 列名；或明确登记「偏离表为新架构专用、不与 Android 遗留库互通」的决策。users vs servers 需补建迁移链；SCHEMA_VERSION=96 自造语义登记至 API_CONTRACT.md / TWO_TRACK_DEV_SPEC.md |

偏离明细（审计对照表）：

| Room 表 | Rust 表 | 偏离 |
|---|---|---|
| rssArticles | rssArticles | 缺 `group`、`read`、`type`、`durPos` 4 列 |
| rssStars | rssStars | 缺 `group`、`type`、`durPos` 3 列 |
| rssReadRecords | rssReadRecords | 结构偏离：Room `record/title/readTime/read/origin/sort/image/type/durPos/pubDate` vs Rust `id/origin/title/readTime/link/variable` |
| readRecord | readRecord | 缺 `deviceId`、`lastRead` 2 列 |
| httpTTS | http_tts | 严重偏离：Room 13 列（contentType/pauseDuration/concurrentRate/loginUrl…）vs Rust 仅 6 列且 `content_type` 为 snake_case |
| ruleSubs | rule_subs | 重新设计：Room 12 列（type/customOrder/autoUpdate/updateInterval/silentUpdate/js/showRule/sourceUrl）vs Rust 8 列 snake_case（sub_type/last_update/version/is_enabled/created_at），无法互读 |
| dictRules | dict_rules | 字段不对齐：Room `name/urlRule/showRule/enabled/sortNumber` vs Rust `name/url_rule/show_rule/is_enabled/sort_order` + 自增 id |
| keyboardAssists | keyboard_assists | 字段不对齐：Room `type/key/value/serialNo` vs Rust `name/key/value/is_enabled/sort_order` + id |
| search_keywords | search_keywords | Room `word/usage/lastUseTime` vs Rust `id/keyword/time`（DTO 已做字段名映射，但 usage 恒为 1，无真实使用次数语义） |
| txtTocRules | txtTocRules | 缺 `replacement` 1 列 |
| servers | users（替代） | 不兼容：Room v95 `servers(id/name/type/config/sortNumber)` vs Rust 自建 `users`（username/password_hash 模型），且迁移链未对旧库创建 users 表，打开 Android 遗留库时用户相关 API 会失败 |
| （视图）book_sources_part | 无 | Rust 未建该视图 |

> 另有 books 为超集（Rust 多 infoHtml/tocHtml/downloadUrls/coverOrigin，Kotlin `Book.kt` 中为 @Ignore 字段）、caches 多 created_at、rssSources 双列冗余（见 P0-3）。

| **实施步骤** | ① 在 `migration/migrations.rs` 新增 `Migration96To97`，按 Room v95 列名补列/重建上述偏离表，`schema.rs` SCHEMA_VERSION 升至 97；② 为旧库（user_version=95 的 Android 遗留库）补建 users 表（或 servers→users 数据搬迁）迁移；③ 同步修订对应 Repository 列名；④ 在 API_CONTRACT.md / TWO_TRACK_DEV_SPEC.md 登记 SCHEMA_VERSION=96 自造语义（books 4 个 @Ignore 字段持久化 + rssSources 补列）与 v97 决策；⑤ 用构造的 v95/v96 遗留库验证 95→96→97 全链路 |
| **验收** | 构造 Android 遗留库（user_version=95）打开后迁移成功、偏离表 Repository 查询不再因列名失配失败；migration 全链路单测通过 |

> ✅ **部分核销（2026-08-05，Task #94）**：4 张列级偏离表已修复（v101 迁移，幂等 `add_column_if_not_exists`）——rssArticles 补 `group`/`read`/`type`/`durPos`、rssStars 补 `group`/`type`/`durPos`、readRecord 补 `deviceId`/`lastRead`、txtTocRules 补 `replacement`；SCHEMA_VERSION 100→101，建表语句同步，四个 Repository 全字段读写适配。**users/servers 结论**：Room `servers` 表存 WebDAV 备份服务器配置（id/name/type/config/sortNumber），与 Rust 自建 `users`（用户账户）语义完全不同，非等价物，登记不改名。**遗留**：rssArticles 主键 (origin,title) vs Room (origin,link,sort)、readRecord 主键 (bookName) vs Room (deviceId,bookName) 为结构级偏离，仅补列不重建表；rssReadRecords/httpTTS/ruleSubs/dictRules/keyboardAssists/search_keywords 等结构偏离项待后续批次处置。验证：legado-db 281 通过、legado-ffi(quickjs) 175 通过。

> 📋 **schema v102 评估（批次3治理，Task #118，2026-08-06）：建议延后** → ✅ **已强制执行（2026-08-13）**。
> **剩余结构偏离（5 项）**：① rssArticles 主键 (origin,title) vs Room (origin,link,sort)；② readRecord 主键 (bookName) vs Room (deviceId,bookName)；③ rssReadRecords 结构偏离；④ httpTTS 严重偏离；⑤ rssSources enableCookieJar/enabledCookieJar 双列冗余。
> **落地说明**：文档名「schema v102」与代码链冲突（v102=cached_chapters、v103=book_sources.variable），故以 **Migration103To104 / SCHEMA_VERSION=104** 落地。实现：`rust/legado-db/src/migration/schema_align_v104.rs`（幂等主键/列形态检测 → 重建表 → 数据搬迁：空 link 回退 `legacy:origin:title:sort`；同主键 `INSERT OR IGNORE`+ORDER BY 保留较新行；http_tts→httpTTS；rssSources 合并 cookie jar 后 drop enableCookieJar；search_keywords→word/usage/lastUseTime；coverRules 入建表清单）。Repository 已适配。契约登记见 API_CONTRACT 更新记录。
> ✅ **核销（2026-08-13）**：上述 5 项 + rssStars 主键 (origin,link) + search_keywords + coverRules 入体系已完成；legado-db 297 单测通过（含 v103→v104 全链路）。
> **残留**：rule_subs / dict_rules / keyboard_assists 仍为 snake_case 表名与列名（与 Room ruleSubs/dictRules/keyboardAssists 未统一），default_data 侧 dictRules/keyboardAssists 仍可并行建表；users vs servers 语义差异维持不改名。后续若需 Android 遗留库全表互读再开批次。

**P0-3 rssSources 双列冗余处理**

| 项目 | 内容 |
|------|------|
| **问题** | rssSources 同时存在 `enableCookieJar` 与 `enabledCookieJar` 两个近似重复列，易造成读写错列 |
| **证据** | `rust/legado-db/src/schema.rs` CREATE_RSS_SOURCES；Room v95 基线 45 列对照 |
| **解决方案** | 确认 Room 基线列名，合并冗余列（保留与 Room 一致者），纳入 v96→97 迁移一并处理 |
| **实施步骤** | ① 核对 `95.json` rssSources 列名；② 迁移中删除冗余列并做数据回填；③ 修订 Repository/DTO 引用 |
| **验收** | rssSources 列集与 Room v95 一致（或登记超集决策），无重复语义列 |

#### 4.2.2 P1（功能缺口）

**P1-1 书源校验 FFI 暴露（跨轨）**——✅ 已完成（2026-08-05，Task #159，提交 86c299923：sourceCheck/sourceCheckStream/sourceCheckCancel 已交付，待 UI 轨接入）

| 项目 | 内容 |
|------|------|
| **问题** | `legado-net/src/source_checker.rs`（962 行）已实现 SourceChecker（含验证码/重定向信息类型），但仅被 legado-server HTTP handler 使用，未暴露 FFI；Flutter 无校验入口 |
| **证据** | `rust/legado-net/src/source_checker.rs`；本台账 §3.4 P2-9「书源校验简化」条目（待复核）；`flutter_legado/lib/src/services/book_api.dart` 无 source_check 方法 |
| **解决方案** | legado-ffi 新增 source_check 系列函数；按铁律先更新 API_CONTRACT.md 契约冻结，再实现，最后 codegen 生成绑定 |
| **实施步骤** | ① API_CONTRACT.md 需求区登记 source_check 契约（入参书源 JSON/批量、出分校验结果 JSON）并冻结；② `legado-ffi/src/api/` 新增校验 API 模块，委托 `SourceChecker`；③ `ffi.rs` 注册函数，`make gen` 生成绑定；④ 交付后 UI 轨接入口（见 §4.3 P1-4） |
| **验收** | Dart 侧可经 bridge 调用书源批量校验并取回结果；契约文档同步登记 |

**P1-2 txt_search 系列接入 frb 主链路**——✅ 已完成（2026-08-05，Task #165：frb 主链路接入，Dart 可达）

| 项目 | 内容 |
|------|------|
| **问题** | `txt_search / txt_search_regex / txt_search_in_chapter / txt_search_count` 仅存在于遗留 bridge.rs（C ABI），frb 主链路未暴露，Dart 不可达；`txt_search_api.rs` 存在但未接入 ffi.rs |
| **证据** | `rust/legado-ffi/src/bridge.rs`、`rust/legado-ffi/src/api/txt_search_api.rs`、`rust/legado-ffi/src/ffi.rs` |
| **解决方案** | 将 txt_search 系列接入 `ffi.rs` frb 主链路，同步补登记 API_CONTRACT.md |
| **实施步骤** | ① `ffi.rs` 新增 4 个 frb 函数包装 txt_search_api；② 契约补登记；③ `make gen` 生成 Dart 绑定 |
| **验收** | Dart 侧可调用 txt_search 系列；契约文档包含该组函数 |

**P1-3 契约外函数补登记 API_CONTRACT.md**

| 项目 | 内容 |
|------|------|
| **问题** | QUIC 系列（quic_create_client / quic_get / quic_post / quic_performance_test / quic_is_initialized / quic_cleanup / net_set_quic_enabled / net_is_quic_enabled）、`backup_list`、`cache_get_chapter`、`book_group_set_show` 等已实现并生成 Dart 绑定，但未登记契约，违反 API_CONTRACT.md §1.2「新增 API 须同步更新文档」规则 |
| **证据** | `rust/legado-ffi/src/ffi.rs`、`flutter_legado/lib/src/bridge/ffi/ffi.dart` |
| **解决方案** | 逐一补登记至 API_CONTRACT.md 对应模块 |
| **实施步骤** | 盘点 ffi.rs 与契约 35 模块差异 → 补写契约条目 → 评审确认 |
| **验收** | ffi.rs 导出函数与 API_CONTRACT.md 登记一一对应，无契约外函数 |

#### 4.2.3 P2（治理与收尾）

**P2-1 遗留 bridge.rs 去留决策**

| 项目 | 内容 |
|------|------|
| **问题** | `rust/legado-ffi/src/bridge.rs`（1746 行、155 个 `ffi_*` extern "C" 导出）与 frb 主链路漂移：缺 webbook/explore/review/book_export/cache 计数/auto_task_execute_with_id，多出 txt_search；Dart 完全不走 bridge.rs，实质半废弃 |
| **证据** | `rust/legado-ffi/src/bridge.rs` vs `rust/legado-ffi/src/ffi.rs` |
| **解决方案** | 决策废弃（在 lib.rs 标注）或补齐；若废弃，评估 txt_search 先行迁至 frb（见 P1-2）后整体移除 |
| **实施步骤** | ① 决策记录写入本节；② 废弃路线：lib.rs 标注废弃 + 移除导出；补齐路线：对齐 frb 函数集 |
| **验收** | bridge.rs 状态明确（废弃标注或函数集对齐），无半废弃漂移层 |

> ✅ **去留决策记录（批次3治理，Task #118，2026-08-06）**：决策为 **保留 + 计划性废弃**（本批次不改代码）。
> **现状事实**：bridge.rs 实测 2116 行、约 196 个 `ffi_*` extern "C" 导出（任务描述「62 个 C ABI」与 P2-1 表「155 个」为不同口径的历史快照计数，不影响结论）；Rust 侧零调用点；Dart 全量走 frb 主链路（ffi.rs 166 函数 ↔ ffi.dart 166 绑定 100% 对齐），bridge.rs 实质半废弃；原移除前置条件 txt_search 迁 frb 已满足（Task #165）。
> **保留理由**：① bridge.rs 属 cdylib 导出面，无法排除外部 C 消费者（历史 C ABI 接入方）依赖，直接删除会改变 .so 导出符号面且不可逆；② 保留无运行时成本（仅编译体积），废弃路线风险更低。
> **废弃计划（三步走）**：① ✅ 本批次完成决策记录；② 下一治理批次：lib.rs/bridge.rs 模块文档标注 DEPRECATED，冻结新增函数（新能力一律进 frb 主链路）；③ 下一大版本：确认无外部 C 消费者后物理移除 bridge.rs，同步销记本台账与 API_CONTRACT.md。

**P2-2 MOBI HUFF/CDIC 压缩与 KF8/INDX 解析移植**——✅ 已完成（2026-08-05，Task #158，提交 d994a4fdb）

| 项目 | 内容 |
|------|------|
| **问题** | `mobi.rs` 头部注释明确声明 HUFF/CDIC 压缩（compression=17480）与 INDX 章节结构解析未实现；KF8(AZW3) 仅检测并返回错误——全项目唯一经源码确认的实质性功能缺口 |
| **证据** | `rust/legado-book/src/mobi.rs`（591 行）；Kotlin 原版 `app/src/main/java/io/legado/app/lib/mobi/`（34 文件：HuffcdicDecompressor.kt、KF8Book.kt、IndexData.kt 等） |
| **解决方案** | 对标 Kotlin lib/mobi 移植 HUFF/CDIC 解压、INDX 章节结构、KF8 解析 |
| **实施步骤** | ① 移植 HuffcdicDecompressor；② 移植 INDX/IndexData 章节结构解析；③ KF8Book 解析接入 `LocalBook` 入口；④ 补测试（老式 MOBI/AZW3 样本） |
| **验收** | HUFF/CDIC 压缩 MOBI 与 AZW3 文件可正常导入阅读，测试通过 |

> ✅ 核销（2026-08-05，Task #158，d994a4fdb）：mobi.rs 677→2563 行，对照 Kotlin lib/mobi/ 34 文件移植 HUFF/CDIC + INDX/TAGX + KF8(AZW3) + NCX/封面，legado-book 140 测试通过，全项目唯一经源码确认的实质性功能缺口已闭合

**P2-3 §3.4 已登记项复核与衔接**

| 项目 | 内容 |
|------|------|
| **问题** | §3.4 登记的 JS 替换规则引擎（content_processor.rs）、漫画核心、视频核心（platform.rs open_video_player）、AnalyzeUrl 缺口（`legado-parser/src/analyze_url.rs` 1623 行基础上的内嵌 JS/WebView 模式/data URI）、HTTP TTS `list_engines`（tts.rs 现返回硬编码「示例引擎」）等条目，与本次审计结论需逐项对账 |
| **证据** | 本台账 §3.4；本次 Rust 审计报告（legado-core ~99%、legado-parser 100% 结论） |
| **解决方案** | 逐项复核：确认已完成者销记；部分完成者修订范围并给出行号级证据 |
| **实施步骤** | 按 §3.4 条目顺序逐一源码验证 → 更新条目状态（待复核 → 已完成/修订） |
| **验收** | §3.4 全部条目状态与源码一致，无悬置「待复核」 |

**P2-4 一次性脚本清理与过期注释修正**——✅ 已闭合（2026-08-06，批次3治理 Task #118）

| 项目 | 内容 |
|------|------|
| **问题** | rust/ 下存在已执行完毕的一次性脚本与历史快照文件；lib.rs 文档注释过期（写「v95，25 张表」，实际 v96、26 张表） |
| **证据** | `rust/update_schema.py`、`rust/add_migration.py`、`rust/update_schema_rss.py`、`rust/update_rss_schema.ps1`、`rust/legado-db/src/migration/fix_migration.py`、`fix_migration2.py`、`rust/legacy_db_temp.txt`（534 行历史快照）；`rust/legado-ffi/src/lib.rs` 注释；另有 `rust/test_migration.rs`（手工验证用例，未纳入 crate 构建）与仓库根 `check_db_version.py`（排障工具，可保留） |
| **解决方案** | 清理一次性脚本与 legacy_db_temp.txt；修正 lib.rs 注释为 v96/26 表 |
| **实施步骤** | ① 删除上表所列脚本/快照文件；② 修订 lib.rs 注释；③ test_migration.rs 一并决策保留或清理 |
| **验收** | rust/ 根目录无一次性脚本残留；lib.rs 注释与实际 schema 一致 |

> ✅ **核销（2026-08-06，Task #118）**：已删除 10 个文件——rust/ 下 9 个（update_schema.py、add_migration.py、update_schema_rss.py、update_rss_schema.ps1、fix_migration.py、fix_migration2.py、legacy_db_temp.txt、test_migration.rs，另含 rust/legado-net/src/fix_quic.ps1）+ 仓库根 fix_reader_provider.py；test_migration.rs 决策为清理（硬编码绝对路径、未纳入 crate 构建、无复用价值）；check_db_version.py 按台账建议保留（排障工具）。保留项见批次3治理报告；lib.rs 注释修正项待后续批次核对。

**P2-5 Rust 文档数据同步**

| 项目 | 内容 |
|------|------|
| **问题** | PROGRESS.md / README.md 测试数（记载 1409 vs 实测约 1752）、FFI 函数数（记载 103+ vs api 层实测 189）、路由数（记载 53 REST + 5 WS vs 实测 72 个 .route()）均滞后；DEVELOPMENT.md「已知限制」platform API 表格仍写「返回 [ERROR]」，实际 platform.rs 已升级为结构化 JSON 桥接载荷 |
| **证据** | `rust/PROGRESS.md`、`rust/README.md`、`rust/DEVELOPMENT.md`；本次实测数据 |
| **解决方案** | 按实测数据更新三处文档 |
| **实施步骤** | 逐文档替换过期数字与 platform API 表述 |
| **验收** | 文档数字与实测一致 |

#### 4.2.4 缺口清单核销记录（2026-08-05 缺口清单清零批次，Task #162~#168）

> 本批次对 §2.1/§3.4/§4.2 登记的缺口逐项处置，核销标注如下：

| 缺口项 | 处置 | 对应任务 |
|--------|------|----------|
| 图片书 PDF 导出（对齐 #483） | ✅ 已完成：图片提取 + 注入式获取管线 + A4 宽高比写入 | Task #162 |
| DB schema 偏离表 | ✅ 已完成：v101 补列 + **v104 结构对齐**（主键/重建表/httpTTS/rssSources/search_keywords/coverRules；users/servers 语义差异登记不改名；rule_subs/dict_rules/keyboard_assists 表名残留） | Task #163 + 2026-08-13 schema v102 专项 |
| JS 宿主 API 零星项 | ✅ 已完成：unzip 断线修复 + 6 个零星 API | Task #164（承接 §3.4 P2-6） |
| txt_search frb 主链路 | ✅ 已完成：接入 frb 主链路，Dart 可达 | Task #165（承接 §4.2.2 P1-2） |
| unzip 断线 | ✅ 已完成 | Task #164 |
| 测试竞态 | ✅ 已完成：串行锁方案，3 轮并行验证零 flaky | Task #165（承接 §4.2.1 P0-1） |
| RSA/SM2 非对称加密 | ✅ 已完成：加解密 + 签名验签 + 长文分段 JS API | Task #166 |
| unrar | ⚠️ 降级处置：纯 Rust RAR 解压生态调研无可用 crate，正式降级（见 rust/PROGRESS.md 已知降级项登记） | Task #168 |
| #473 复核 | ✅ 复核结论：Rust 结构天然免疫（阅读预下载静默失败不入队），无需同步 | 缺口清单清零批次 |
| Task #131 裁决 | ⚖️ 登记失实已纠正（原名单 configGet/threadPool/randomString 等 Kotlin 无此 API），交付真实（提交 249f95451，+15 函数），rust/PROGRESS.md 已同步纠正 | 2026-08-05 审计 |

### §4.3 Flutter 前端部分：后续解决方案与实施步骤

#### 4.3.1 P0（阻塞级）

**P0-1 切换真实 searchCover / dictLookup**

| 项目 | 内容 |
|------|------|
| **问题** | FFI 契约已交付但 UI Notifier 仍走 Mock：换封面用 `_mockSearch`（picsum 占位图）、词典查 `_localDict` 静态词典 |
| **证据** | `flutter_legado/lib/src/providers/change_cover/change_cover_notifier.dart:30-54`（TODO「Rust 轨交付 searchCover 后切换」）；`flutter_legado/lib/src/providers/dict/dict_notifier.dart:38,129-133`；Rust 侧 `api/search.rs::search_cover`（L201 起）→ `ffi.rs` L230 → `bridge.searchCover` → `rust_api.dart` L313，`api/dict_api.rs::dict_lookup` → `ffi.rs` L483 → `rust_api.dart` L693，链路已通 |
| **解决方案** | UI 轨替换两处调用为 `api.searchCover` / `api.dictLookup`，并回写 UI_RESTRUCTURE_PLAN.md Phase 6 决议块（6.4 待回写项） |
| **实施步骤** | ① ChangeCoverNotifier 移除 `_mockSearch`，调用 `api.searchCover` 并解析 url/width/height（注意 width/height 恒 0 的现状）；② DictNotifier 移除 `_localDict` 同步查询，改调 `api.dictLookup`（字段 word/phonetic/definitions）；③ 更新对应 Notifier 测试；④ 回写 UI_RESTRUCTURE_PLAN Phase 6 决议块为已完成 |
| **验收** | 换封面显示真实多源搜索封面候选、词典查询走 FFI；相关测试通过；Phase 6 决议块闭环 |
| **备注** | dictLookup 的 Rust 实现当前为 18 词静态内置词典（契约达标、离线可用，数据覆盖为占位级），真实词库为后续项 |

**P0-2 上游同步 A/B/C 决策登记（前置阻塞）**

| 项目 | 内容 |
|------|------|
| **问题** | §3.5 上游同步决策（A 合并 123 提交 / B 冻结 app/ 聚焦 Flutter+Rust / C 选择性 cherry-pick）仍为「待定」，决策前默认按 B 执行；该决策影响 §3.1-3.3 全部 Kotlin 修复与本节 Kotlin 侧条目的执行方式 |
| **证据** | 本台账 §3.5 |
| **解决方案** | 用户拍板后回写 §3.5 决策结果；未拍板期间维持默认 B（不引入上游） |
| **实施步骤** | ① 提交决策；② 回写 §3.5；③ 按决策调整 §3.1-3.3 与本节 Kotlin 条目执行口径 |
| **验收** | §3.5 决策结果非「待定」 |

#### 4.3.2 P1（功能与语义）

**P1-1 rust_api.dart 过期占位清理（服务器启停 / 备份）**

| 项目 | 内容 |
|------|------|
| **问题** | `startServer/stopServer` 仅写 config 占位（注释「待 FFI 实现」），实际 bridge.serverStart/serverStop 已存在；备份在 Dart 侧自行聚合 JSON，bridge 已有 `backupCreate/backupRestore/backupList` 未被使用 |
| **证据** | `flutter_legado/lib/src/services/rust_api.dart:1033-1052` vs `flutter_legado/lib/src/bridge/ffi/ffi.dart:713-720`；`rust_api.dart:701-780`（备份） |
| **解决方案** | startServer/stopServer 改用 bridge.serverStart/serverStop；备份改用 backupCreate/backupRestore/backupList |
| **实施步骤** | ① rust_api.dart 两处方法体替换；② 核对返回 JSON 字段与现有 State 解析；③ 更新服务层测试 |
| **验收** | 服务器启停真实驱动 Rust server；备份/恢复走 FFI；测试通过 |

**P1-2 RSS 语义修复**

| 项目 | 内容 |
|------|------|
| **问题** | ① FFI 无 rssUpdateSource，`rss_source_edit_screen` 用「删旧+加新」workaround（137-140 行），`rust_api.updateRssSource` 复用书源接口 `sourceUpdate`；② RSS 启停/导入导出全部复用书源接口（sourceEnable/sourceDisable/sourceImport/sourceExport），存在串表风险（Android 原版为 book_source / rss_source 两张独立表）；③ RSS 历史页未接（已读记录 FFI 已具备但无历史页面） |
| **证据** | `flutter_legado/lib/src/screens/rss_source_edit_screen.dart:137-140`；`flutter_legado/lib/src/screens/rss_screen.dart:132-138`（TODO）；Tina 审计 §5.2 风险提示 |
| **解决方案** | Rust 轨确认 `sourceUpdate(sourceJson: RssSource)` 的落表语义；新增 `rssUpdateSource` FFI 替代删+加 workaround；RSS 启停/导入导出按确认结果决定继续复用或分离；UI 轨接入 RSS 历史页 |
| **实施步骤** | ① Rust 轨核实 rssSources 与 book_sources 落表区分（契约登记）；② 契约新增 rssUpdateSource（先 API_CONTRACT 冻结）→ ffi.rs 注册 → codegen；③ rss_source_edit_screen 移除删+加 workaround；④ 新增 RSS 历史页面并接入 rssListReadRecords |
| **验收** | RSS 源更新为原子操作、无串表风险；RSS 历史页可浏览已读记录 |

**P1-3 书源校验 UI 入口（依赖 §4.2 P1-1 契约交付）**

| 项目 | 内容 |
|------|------|
| **问题** | Flutter 书源校验功能级缺失：无入口、BookApi 无方法、FFI 无 source_check 函数；编辑页「校验关键字」仅是表单字段（对应原版 checkKeyWord），不是校验功能 |
| **证据** | Tina 审计 §5.1；`flutter_legado/lib/src/screens/source_screen.dart`（无校验入口） |
| **解决方案** | 依赖 Rust P1-1 契约交付后：BookApi 新增校验方法（RustApi/MockBookApi 双实现）、新增 CheckSourceNotifier、source_screen 补校验入口 |
| **实施步骤** | ① 等待契约冻结 + FFI 交付；② book_api.dart 增方法 + mock_book_api.dart Mock 实现；③ 新增 CheckSourceNotifier（批量校验进度/结果状态）；④ source_screen 增「校验书源」入口与结果展示；⑤ 补 Notifier/widget 测试 |
| **验收** | 可批量校验书源并展示可用性结果，对标原版 CheckSourceActivity |

#### 4.3.3 P2（治理、补齐与对齐）

**P2-1 消除 4 个 screen 直调 bridge 违规（架构铁律 §0.2）**

| 项目 | 内容 |
|------|------|
| **问题** | 4 个 screen 直接 import bridge（UI 禁触 bridge 铁律违规） |
| **证据** | `source_edit_screen.dart:782-801`（直调 webbookSearch/Info/Chapters/Content）、`source_debug_screen.dart:119`（直调 webbookSearch）、`rss_source_edit_screen.dart:173`（直调 rssFetchArticles）、`other_settings_screen.dart:71/138`（直调 netIsQuicEnabled/netSetQuicEnabled） |
| **解决方案** | 将 webbook 四件套/rssFetchArticles/quic 开关上收进 BookApi，screen 改经 Notifier/BookApi 调用 |
| **实施步骤** | 逐 screen 上收：book_api.dart 补方法 → rust_api/mock 实现 → screen 去 bridge import |
| **验收** | 4 个 screen 无 `import '../bridge/...'`；flutter analyze 通过 |

**P2-2 缺失页面补齐清单**

| 项目 | 内容 |
|------|------|
| **问题（历史）** | 相对 Android 原版 54 个 Activity，曾登记缺失多项页面 |
| **Doc5 销记（2026-08-13）** | 对照 GAP/用户实测，下列**已交付**，勿再按「缺失」排期：③ 书架管理 `BookshelfManageScreen`；④ 远程书库 `RemoteBookScreen`；⑤ RSS 源调试；⑥ 规则订阅；⑦ JS/CodeEdit；⑧ 底栏皮肤 Assign/导出/分享；① 书源校验 FFI 已交付；② 验证码事件流已交付。⑨ HandleFile **N/A**（Flutter file_picker）。仍开放项见 [RESIDUAL_RISKS_2026-08-13.md](RESIDUAL_RISKS_2026-08-13.md) |
| **证据** | Tina 审计 §4；GAP_AUDIT；USER_TEST_RESULTS |
| **解决方案** | 已交付页不再立项；剩余按残留风险表推进 |
| **验收** | 以 GAP / USER_TEST 为准 |

**P2-3 UI 对齐收尾**

| 项目 | 内容 |
|------|------|
| **问题** | ① 主题色值实机复核：安卓棕褐 #6B4F43 顶栏 + 红 #E53935 强调 vs Flutter M3 蓝灰 seedColor + 白顶栏，FINAL_REPORT（2026-07-31）仍记为 -5% 差异项，决策 A 已定「M3 框架 + 安卓 colors.xml 色值」但无完全对齐核销记录；② UI_DIFF_REPORT_V2 §7 列 8 项取证缺口（阅读器 5 屏实机对比、书籍详情页取证、发现页/RSS 带数据状态、动画逐帧、字号精确测量、搜索历史行为核实、在线书差异）；③ 书架长按本地 txt bug（FINAL_REPORT 记为功能缺陷）；④ 响应式网格多尺寸验证 |
| **证据** | `docs/UI_DIFF_REPORT_V2.md`、`docs/UI_CONSISTENCY_FINAL_REPORT.md` |
| **解决方案** | 实机复核色值并按 colors.xml 修订 app_theme.dart；按 8 项缺口逐项取证；修复长按 bug；多尺寸网格验证 |
| **实施步骤** | ① 真机/模拟器取色对比 → 修订 seedColor/强调色；② 8 项取证逐个补截图对比；③ 复现并修复书架长按本地 txt 缺陷；④ 多分辨率窗口验证网格 |
| **验收** | 色值与原版一致并留核销记录；8 项取证补齐；长按 bug 修复 |

**P2-4 flutter_rust_bridge 版本统一与 FFI 集成测试引入**

| 项目 | 内容 |
|------|------|
| **问题** | ① pubspec 锁定 `flutter_rust_bridge: 2.11.1`，但 `bridge/lib.dart`、`api/*.dart` 头注释为 2.12.0 生成（`ffi.dart`/`frb_generated.dart` 为 2.11.1），codegen 版本不完全一致；② 测试全部基于 MockBookApi/mocktail（约 986 例），无任何真实 DLL 集成测试，bridge 生成代码覆盖率 0% |
| **证据** | `flutter_legado/pubspec.yaml`；`flutter_legado/lib/src/bridge/` 头注释；Tina 审计 §6 |
| **解决方案** | Rust 轨核对并统一 codegen 版本后重新生成；引入最小 FFI 集成测试（真实 DLL 冒烟） |
| **实施步骤** | ① Rust 轨统一 flutter_rust_bridge 版本并 `make gen` 重生成；② integration_test 增加真实 DLL 初始化 + 核心链路（dbOpen/书架/搜索）冒烟用例 |
| **验收** | bridge 生成文件版本头一致；存在可运行的 FFI 集成冒烟测试 |

**P2-5 Kotlin 侧 P0×2 修复（执行依赖上游同步决策）**

| 项目 | 内容 |
|------|------|
| **问题** | ① `BaseReadBookActivity.kt:298-303` 模拟阅读未开启时日期框点击崩溃（DateTimeParseException）；② `DatabaseMigrations.kt:176` migration_26_27 引用错列名 `pageIndex`（应为 `chapterPos`），v26 用户升级链中断 |
| **证据** | 本台账 §3.1（含逐条 file:line 与修改方案） |
| **解决方案** | 按 §3.1 方案修复；**执行前置依赖 §3.5 上游同步 A/B/C 决策**（若选 A 先合并上游再修，避免被覆盖） |
| **实施步骤** | ① §3.5 决策落定；② 按 §3.1 表格实施两处修复；③ 按表格验证方式验收 |
| **验收** | 日期框两种状态不崩溃；构造 v26 库执行 26→27 迁移成功 |

### §4.4 执行顺序与里程碑建议

#### 第一批（1-2 周，低成本收尾）

| 项 | 轨道 | 依赖 |
|---|---|---|
| UI 双切换：searchCover / dictLookup（§4.3 P0-1） | UI 轨 | 无（Rust 已交付），完成后回写 Phase 6 决议块 |
| FFI 测试竞态隔离（§4.2 P0-1） | Rust 轨 | 无 |
| 文档修正：README 表述（§3.6）、Rust 三文档数据同步（§4.2 P2-5）、lib.rs 注释（§4.2 P2-4）、契约外函数补登记（§4.2 P1-3） | 双轨 | 无 |
| 上游同步 A/B/C 决策拍板（§4.3 P0-2 → §3.5） | 决策项 | 前置阻塞，默认 B |

#### 第二批（2-4 周，数据兼容与功能补齐）

| 项 | 轨道 | 依赖 |
|---|---|---|
| v96→97 迁移：8 张偏离表 + users/servers 补建 + rssSources 双列合并 + SCHEMA_VERSION=96 语义登记（§4.2 P0-2/P0-3） | Rust 轨 | 无 |
| 书源校验跨轨链路：契约冻结 → Rust FFI 暴露 → UI 入口（§4.2 P1-1 → §4.3 P1-3） | 跨轨 | 严格串行：契约冻结 → Rust FFI → UI 入口 |
| RSS 语义修复：落表语义确认、rssUpdateSource、历史页（§4.3 P1-2） | 跨轨 | Rust 落表确认先行 |
| 过期占位清理：serverStart/serverStop、backup 三件套（§4.3 P1-1）、txt_search 接入 frb（§4.2 P1-2） | 双轨 | txt_search 属 Rust 轨，占位清理属 UI 轨，可并行 |

#### 第三批（排期推进）

| 项 | 轨道 | 依赖 |
|---|---|---|
| 架构治理：bridge.rs 去留决策、4 个 screen 违规上收、frb 版本统一、FFI 集成测试（§4.2 P2-1、§4.3 P2-1/P2-4） | 双轨 | txt_search 迁出后再处置 bridge.rs |
| 缺失页面补齐：验证码/书架管理/远程导入/RSS 调试/规则订阅/底栏皮肤（§4.3 P2-2） | UI 轨 | 书源校验页依赖第二批契约交付 |
| MOBI HUFF/CDIC + KF8/INDX 移植（§4.2 P2-2） | Rust 轨 | 无，可独立排期 |
| §3.4 已登记项复核与 Kotlin 侧修复批次（§4.2 P2-3、§4.3 P2-5） | 双轨 | Kotlin 修复依赖 §3.5 决策 |

> 质量门禁沿用本文档「质量门禁」章节；每批完成后同步更新 docs/README.md「当前状态」与本台账销记。

---

## §5 UI 细节与功能缺口专项（2026-08-06 实测审计）（新增）

> 本节为 2026-08-06 双轨缺口审计的整合台账：第一路为 Flutter UI 功能缺口实测审计（约 **92 项**：P0 2 / P1 44 / P2 46）；第二路为 Rust 功能缺口源码级复查（完成度修订为 **96-97%**，实质 P1 缺口 4 项）。登记原则与 §3/§4 一致：只登记计划、不修改代码，完成后逐项销记。可执行任务清单见 [UI_FIX_PLAN.md](UI_FIX_PLAN.md)「UI 缺口修复批次（2026-08-06）」；量化统计与时间表见综合报告 [REFACTORING_AUDIT_REPORT_20260806.md](REFACTORING_AUDIT_REPORT_20260806.md)。
>
> ✅ **闭合销记（2026-08-06，Task #119）**：批次 0-3 已全部完成，8 个提交——`0cde41a5c`（批次0快赢）/ `873abea29`（批次1 P0）/ `b7368193a`（Rust ①④）/ `9ac94b173`（Rust ② TTS 管线）/ `522e1c1be`（批次2 P1 批量+WebView 拦截+audioSpeak 接线）/ `6633c25e3`（Rust 批次3治理）/ `0c452f4b5`（Docs 批次3治理）/ `13a11220e`（批次3 P2 收尾）。Rust 4 项 P1 实质缺口与 UI 92 项缺口主体全部闭合；残留留项清单见审计报告 §7（章节内容保存 FFI、反转内容持久化、章节购买 payAction、段落级 TTS 起点、语速跟随系统通道、MoreConfig 其余项、schema v102、bridge.rs C ABI 三步废弃等）。

### §5.1 Flutter UI 缺口：P0（2 项，阻塞核心阅读体验）——✅ 已闭合（批次1，`873abea29`，2026-08-06）

| # | 功能名 | Android 原版位置 | Flutter 现状 | 优先级 | 工作量 |
|---|--------|------------------|--------------|--------|--------|
| 1 | 阅读器正文长按选择 + 9 项操作菜单（复制/书签/高亮/词典/朗读/搜正文等） | ReadBookActivity 正文长按动作菜单 | `reader_text_content.dart` 无 SelectableText / 选择区域与动作菜单均缺失 | P0 | 3-5d |
| 2 | 阅读器底栏朗读按钮 + 朗读配置页入口 | ReadBookActivity 底栏朗读入口 + ReadAloud 配置 | 底栏朗读按钮为存根；`read_aloud_config_screen.dart` 为孤儿页（无任何入口） | P0 | 2-3d |

**FFI 依赖标注**：① 高亮操作可复用已交付的 highlight* 11 方法（§2.36），词典可复用 dictLookup，书签可复用 bookmark* 系列——**无契约阻塞**，纯 UI 工程；② 朗读功能依赖 Rust P1 缺口「audioSpeak TTS 真实管线」（见 §5.6 ②），当前 `rust_api.dart` L1431 仅 http.get 探活，UI 可先做界面与状态机，管线交付后接通。

> ✅ **销记（2026-08-06）**：P0-1 长按选择 + 操作菜单已交付（段落选区面板，复制/书签/高亮5色/词典/浏览器/分享，对齐原版 content_select_action 顺序）；P0-2 底栏朗读按钮 + 朗读控制条已交付（章节切换/语速 0.5-3.0x/目录/朗读设置/转后台），真实 TTS 播报随批次 2 接通。均见 `873abea29`。

### §5.2 Flutter UI 缺口：P1（44 项，按屏幕分组）——✅ 已闭合（批次2，`522e1c1be`，2026-08-06）

| # | 屏幕/模块 | 缺口功能 | Android 原版位置 | Flutter 现状 | FFI 依赖 |
|---|-----------|----------|------------------|--------------|----------|
| 1 | 阅读器·顶栏 | 溢出菜单 10 项全存根（编辑内容/替换规则开关/更新目录等） | ReadBookActivity 顶栏溢出菜单 | 菜单项均为存根 | 替换规则开关用既有 replaceRule*；更新目录用 refreshToc；编辑内容需确认内容编辑契约 |
| 2 | 阅读器·底部 | 源操作菜单（登录源/章节购买/编辑源/禁用源） | ReadBookActivity 底部源菜单 | 缺失 | 登录 UI V2 三件套已交付未封装（见 API_CONTRACT §3 待封装清单） |
| 3 | 阅读器·配置 | 阅读配置面板 5 项（字体/字距/首行缩进/简繁/MoreConfig） | ReadBookConfig 对话框 | 部分缺失（简繁已有 setChineseConvertType 可调） | 无契约阻塞 |
| 4 | 离线缓存 | 顶栏缓存 + 书架缓存导出（对应 CacheActivity） | CacheActivity | ✅ 已交付（v2.0.17） | cache 系列 FFI 已具备（cacheGetChapter 待封装，见 API_CONTRACT §2.41） |
| 5 | 书架 | 3 项（更新目录假动作/添加网址/书单导入导出行为不符） | BookshelfActivity 菜单 | 行为不符/假动作 | 更新目录用 refreshToc；书单导入导出用既有 import/export |
| 6 | 书详情 | 登录/置顶/清缓存 3 项 | BookInfoActivity 菜单 | 存根或缺失 | topBook/clearCache 已有；登录依赖登录 UI V2 封装 |
| 7 | RSS | 文章列表菜单 6 项 + RSS 详情收藏按钮 | ReadRssActivity / RssArticle 列表 | 缺失 | 收藏用既有 rssStar* 系列；源更新依赖 rssUpdateSource 原子 FFI（§5.6 ④） |
| 8 | 替换规则页 | 分组筛选 + 3 种导入 + 批量操作 | ReplaceRuleActivity | 部分缺失 | 导入可接已有确认页（纯接线）；批量用既有 replaceRule* |
| 9 | 换源页 | 高级选项 8 项 | 换源对话框高级选项 | 缺失 | 用既有 searchSource/switchSource |
| 10 | 听书 | 溢出菜单（换源/缓存/wakelock） | AudioPlayActivity 菜单 | 缺失 | 换源用 searchSource；wakelock 为纯 Flutter 插件项 |
| 11 | 设置 | Web 服务/定时服务开关 | WebService / 定时服务设置 | 缺失 | serverStart/serverStop 已有（rust_api.dart 占位清理见 §4.3 P1-1） |
| 12 | 书架管理 | 批量换源等 | BookshelfManageActivity | 缺失 | 批量换源用既有 switchSource 循环 |

> 44 项逐条明细与验收标准见 [UI_FIX_PLAN.md](UI_FIX_PLAN.md)「UI 缺口修复批次（2026-08-06）」批次 2。
>
> ✅ **销记（2026-08-06）**：44 项按组 A（阅读器系 10 项菜单+源操作+配置 5 项）/组 B（离线缓存/书架书详 7 项）/组 C（RSS 规则换源听书设置 8 项）批量闭合，34 files，见 `522e1c1be`；前置依赖 Rust ①④（`b7368193a`）与 WebView 拦截、audioSpeak 接线同批闭合。留项：编辑内容持久化（待 saveChapterContent FFI）、反转内容持久化（同前）、章节购买（待 payAction FFI）、MoreConfig 其余项（显示标题/滚动条/音量键翻页等）。

### §5.3 Flutter UI 缺口：P2（46 项，摘要登记）——✅ 已闭合（批次3，`13a11220e` + 台账核验销记，2026-08-06）

| 类别 | 内容 | 备注 |
|------|------|------|
| 日志入口接线 | 7 处日志入口（含 source_edit_screen，评审修复补接；AppLogScreen 路由已存在、appLog* FFI 已交付） | 纯接线快赢 |
| 排版细节参数 | 编码/字距/边距等参数项对齐 | 随阅读器批次收尾 |
| 导入排序 | 导入页排序行为对齐原版 | 独立小项 |
| 自动任务菜单 | 自动任务页菜单项补齐 | 依赖既有 autoTask* FFI |
| 其余 | 约 35 项零星菜单/行为细节 | 逐条明细见综合报告附录 |

> ✅ **销记（2026-08-06）**：批次3 P2 收尾交付阅读页面四向边距、设置编码（book.charset 重载当前章）、定时任务导入导出菜单（本地/线上/导出/帮助），见 `13a11220e`；日志入口销记口径修正为 **7/7**：批次0 接通 6 处，source_edit_screen（书源编辑）为批次0 遗漏，随本次评审修复补接（补提交），全部核验可达 AppLogScreen；字距/段距/首行缩进/两端对齐（v2.0.2 已接入排版引擎）、书源导入排序（判定对齐）经台账核验无需改动，一并销记。P2 逐条处置明细见 [REFACTORING_AUDIT_REPORT_20260806.md §7.4](REFACTORING_AUDIT_REPORT_20260806.md)。

### §5.4 纯接线快赢项（立即可做，无 FFI 阻塞）——✅ 已闭合（批次0，`0cde41a5c`，2026-08-06）

| # | 快赢项 | 说明 | 工时 |
|---|--------|------|------|
| 1 | 7 处日志入口接线 | AppLogScreen 路由已存在，appLog* FFI 已交付（API_CONTRACT §2.38）；批次0 接通 6 处，source_edit_screen 遗漏项随评审修复补接（补提交），合计 7/7 | ≤0.5d |
| 2 | 朗读配置页入口 | `read_aloud_config_screen.dart` 孤儿页补入口（先于 P0-2 的管线接通） | ≤0.5d |
| 3 | 替换规则导入接已有确认页 | 3 种导入通道复用现有确认页组件 | ≤0.5d |
| 4 | 翻页动画菜单 | 菜单项接既有翻页模式配置 | ≤0.5d |

### §5.5 结构问题

- `rss_config_screen.dart` 与 `rss_source_manage_screen.dart` 功能重复（前者含 5 个存根）。**建议删除前者**，以 `rss_source_manage_screen.dart` 为准；删除前需核销 5 个存根的替代覆盖。

> ✅ **销记（2026-08-06）**：`rss_config_screen.dart` 及 rssConfig 路由已删除（原版无此页，订阅源管理统一走 rssSourceManage），见批次2 `522e1c1be`。

### §5.6 Rust P1 实质缺口（4 项，源码级复查）

| # | 缺口 | 现状证据 | 优先级 | 工作量 | 阻塞的 UI 项 |
|---|------|----------|--------|--------|--------------|
| ① | 正文 nextContentUrl 分页抓取 | `web_book.rs` get_content 只抓一页，分页书源正文被截断——**唯一用户可见的核心解析缺口** | P1 | 2-3d | 阅读器正文完整性（所有分页书源） |
| ② | audioSpeak TTS 真实管线 | `rust_api.dart` L1431 仅 http.get 探活，且被 audio_notifier 实际调用 | P1（跨轨） | 3-5d | P0-2 朗读按钮与朗读配置页 |
| ③ | WebView 桥接载荷 Flutter 侧拦截执行 | Rust 已交付 7 个 action JSON，Flutter lib 无拦截代码 | P1（跨轨） | 2-3d | 书源 WebView 交互类功能 |
| ④ | rssUpdateSource 原子更新 FFI | 现用「删旧+加新」workaround（承接 §4.3 P1-2） | P1 | 0.5d | RSS 源编辑（防串表） |

> ✅ **销记（2026-08-06）**：① nextContentUrl 分页抓取闭合（`b7368193a`，99 页上限去重终止，契约 §2.5 登记）；② audioSpeak Rust 侧闭合（`9ac94b173`，ttsSpeak 模板替换+MD5 文件缓存+Content-Type 校验+legado-net 无损字节 get_raw，契约 §2.42 登记），Flutter 侧接线闭合（`522e1c1be`，audioSpeak 改接 bridge.ttsSpeak）；③ WebView 桥接载荷 Flutter 侧拦截闭合（`522e1c1be`，platform_bridge_service.dart 承接 7 动作，rust_api.dart 11 处拦截接入）；④ rssUpdateSource 原子更新闭合（`b7368193a`，契约 §2.17 登记）；**④补记：UI 接线随评审修复补闭合（本次提交，`rust_api.updateRssSource` 由误接 sourceUpdate 改接 bridge.rssUpdateSource，Mock 同步对齐「源不存在时报错」语义，缺口④至此全链闭合）**。

### §5.7 Rust 治理与契约登记缺口（摘要）

| 类别 | 内容 | 处置去向 |
|------|------|----------|
| 契约补登 | 12 个 FFI 已实现未登记（QUIC 8 + backupList + cacheGetChapter + bookGroupSetShow + httpTtsSetEnabled） | ✅ 已补登至 API_CONTRACT.md §2.41（2026-08-06）；QUIC 8 项随后整体移除（见 §5.10，2026-08-07） |
| UI 封装 | 13 个 bridge 绑定已实现未被 UI 层封装（含登录 UI V2 整组 + QUIC 客户端六件套） | QUIC 客户端六件套：**已移除（用户决策，纯重构边界，2026-08-07，见 §5.10）**；其余已登记至 API_CONTRACT.md §3 待封装清单 |
| schema 偏离 | rssArticles/readRecord 主键、rssReadRecords/httpTTS 结构、rssSources 双列冗余 | ✅ 已完成（2026-08-13，SCHEMA_VERSION=104 / Migration103To104）；残留 rule_subs/dict_rules/keyboard_assists 表名（见 §4.2.1） |
| 文档治理 | README「零 TODO/桩实现」表述需修正、DEVELOPMENT.md 已知限制表过期 | ✅ 已闭合（Task #118）：docs/README.md + rust/PROGRESS.md + rust/DEVELOPMENT.md 均已按实际口径修正 |
| 代码治理 | platform.rs 5 个死代码桩清理、一次性脚本清理（承接 §4.2.3 P2-4）、bridge.rs C ABI 去留决策（承接 §4.2.3 P2-1） | ✅ 已随批次3闭合（Task #118）：platform.rs 5 桩已删除、10 个一次性脚本已清理、bridge.rs 决策为保留+计划性废弃（见 §4.2.3 P2-1 决策记录） |
| 已闭合 | Task #131 timeFormat/toURL 别名 | ✅ 已闭合 |

### §5.8 执行顺序建议

```
批次 1（快赢 + P0 专项，1-2 周）：§5.4 四个纯接线项 → P0-1 长按选择菜单 → P0-2 朗读入口（UI 先行）
批次 2（P1 批量 + Rust P1，3-4 周）：Rust ①④ 先行（0.5-3d，解除正文截断与 RSS 串表）
                                  → UI 按屏幕分组批量（阅读器 → 书架/详情 → RSS → 其余）
                                  → Rust ②③ 跨轨项与 UI 朗读批次并行
批次 3（P2 收尾 + 治理，2 周）：P2 46 项随迭代消化 + §5.7 治理项 + rss_config_screen 删除
```

- 跨轨项遵守 [TWO_TRACK_DEV_SPEC.md](TWO_TRACK_DEV_SPEC.md)：新增 FFI 先更新 [API_CONTRACT.md](API_CONTRACT.md) 冻结契约再实施
- 每批完成后同步更新 docs/README.md「当前状态」与本台账销记

### §5.9 TODO(留批次) 正式登记（2026-08-06 评审修复新增）

> 代码中 `TODO(留批次)` 标记项的台账登记处；与审计报告 §7.3 留项清单互为镜像。

| # | 留项 | 代码位置 | 说明 |
|---|------|----------|------|
| 1 | ~~searchSource 分组过滤~~（已闭合） | `flutter_legado/lib/src/screens/change_source_screen.dart` `_showGroupPicker` | ✅ Task #131（2026-08-07）销记：Rust `source_switch_search` 加 `source_urls_json` 参数复用 `load_search_sources` 过滤，换源页按分组过滤生效；另修复主搜索页选分组/书源后关闭面板不自动重搜（留项#12 闭合） |
| 2 | 定时服务后端 | `flutter_legado/lib/src/screens/auto_task_screen.dart` | ⚠️ 口径更正（2026-08-09，Task #44）：应用内调度器 `auto_task_scheduler.dart` 已落地，原「无后台调度」描述部分过时；原登记「autoTask 后台执行 FFI 未移植，开关仅持久化 `isEnabled`」保留备查 |
| 3 | 书架缓存导出扩展项 | `flutter_legado/lib/src/screens/bookshelf_screen.dart` | 缓存管理页/缓存下载/epub·pdf/模板/WebDav 等，已交付 TXT 导出（评审修复补登）。Rust 侧大头已随 R7/R8 闭合（缓存批量下载 4 方法 + bookExportWithOptions 四格式导出参数，见 §5.10）；剩余为 UI 页面与模板/WebDAV 接线 |

> ⚠️ **口径更正（2026-08-08/09，Task #44）**：留项 2 定时服务后端——应用内调度器 `auto_task_scheduler.dart` 已落地，原「无后台调度」描述部分过时；剩余决策仅为原生前台服务化的必要性与时机。

### §5.10 R 系列 Rust 剩余项全批闭合记录（2026-08-07，Task #140）

> ✅ **闭合销记（2026-08-07）**：Rust 剩余项全批（R1-R10+R12）已闭合并统一提交，对应留项评审 [REMAINING_ITEMS_DEV_REVIEW_20260806.md](REMAINING_ITEMS_DEV_REVIEW_20260806.md) 留项 1/3/8（步骤2）/9/11（Rust 大头）/13（QUIC 部分）。契约 §2.43 新增 7 方法（加法式、仅走 frb 主链路）+ §2.41 QUIC 移除记录；验证 cargo test --workspace 全绿、quickjs 213 全过、flutter analyze 0 error。

| R# | 内容 | 闭合方式 | 对应留项 |
|----|------|----------|----------|
| R1+R2 | web_book.rs subContent 副内容 + replaceRegex 全文替换 | 真实实现（对标 BookContent.kt L128-174，txt/http 分支） | 留项 9① |
| R3 | legado-server 正文接口 | 真实实现（接 RealBookSourceFetcher 正文链路） | 留项 9② |
| R4 | dict_api 字典数据源 | 重写为原版字典规则引擎（dict_rules 逐规则执行 + 表空注入原版默认 5 字典源 seed） | 留项 9③ |
| R5 | saveChapterContent 缓存写 FFI | 新增（契约 §2.43.1） | 留项 1 |
| R6 | chapterPayAction 章节购买 FFI | 新增（契约 §2.43.2） | 留项 3 |
| R7 | 缓存批量下载 4 方法 FFI | 新增（契约 §2.43.3） | 留项 11 Rust 大头 |
| R8 | bookExportWithOptions 导出参数扩展 | 新增（契约 §2.43.4，支持四格式） | 留项 11 Rust 大头 |
| R9 | font_api 字体反爬 cmap 真实替换 | 新增 query_ttf.rs 真实实现 | 引擎差异观察项 |
| R10 | JS 书源段评回复 | js_source_book.rs 真实实现 | 段评链路补齐 |
| R12 | bridge.rs C ABI DEPRECATED 标注 | 模块级标注 + 冻结新增（废弃三步走步骤2） | 留项 8 步骤2 |
| QUIC | QUIC 客户端六件套 + 总开关共 8+8 FFI 导出 | **已移除**（用户决策，纯重构边界：原版无对应能力）：legado-net/quic.rs、quic_api.rs 删除、quinn 等依赖删除、Dart UI 开关清理、契约 §2.41 登记移除、§3 待封装清单销记 | 留项 13（QUIC 部分） |

**R 系列闭合后 Rust 轨剩余项**：仅剩 schema v102 重建表（保持触发型延后，见留项 7 / §4.2.1）+ normalizeJsResult 引擎差异观察项；UI 侧留项（缓存管理页、MoreConfig、定时调度器等）不受本批影响、按原波次排期。

### §5.11 BookInfo/TocScreen 占位项与 FFI 接口建议登记（2026-08-08，模块 D+E 交付时新增）

> 独立目录页 TocScreen（对齐原版 TocActivity）与书籍详情页菜单收尾交付时，因 FFI 缺失或本批不实现而登记的占位项与接口建议。

| # | 项 | 代码位置 | 现状与建议 |
|---|-----|----------|------------|
| 1 | ~~上传至远程~~（已接线） | `flutter_legado/lib/src/screens/book_info_screen.dart` `_todo('upload')` | ✅ Task #57（2026-08-10）销记：已接线，契约 §2.28.6 webdavUploadFile（本地文件路径上传 + PUT 状态码校验）；详情页菜单对齐原版 RemoteBookWebDav.upload（origin 回写 webDavTag+远端地址、lastCheckTime 刷新、仅本地书） |
| 2 | ~~创建书籍更新任务~~（已接线） | 同上 `_todo('updateTask')` | ✅ Task #44（2026-08-08/09）销记：book_info_screen 菜单 → `findBookUpdateTask`（全量规则 JSON 匹配，FFI 失败退化模型输入）→ 已存在携 editTaskId 编辑 / 不存在 `buildBookUpdateTask` 新建；AutoTaskScreen 补 initialEditTaskId/initialNewTask 路由参数；新增 createTaskRaw/updateTaskRaw 保留完整 script；cron 合法性校验；失败按结果提示。原建议 FFI `create_update_task` 不再必要（既有 autoTask* 契约已满足） |
| 3 | ~~设置源变量~~（已接线） | 同上 `_todo('sourceVariable')` | ✅ Task #71（2026-08-10）销记：已接线，契约 §2.3 setSourceVariable（单列 UPDATE、lenient 序列化双保险）+ Migration102To103 补列；详情页 `_VariableDialog` 对话框对齐原版 setVariable 的 source 分支 |
| 4 | ~~设置书籍变量~~（已接线） | 同上 `_todo('bookVariable')` | ✅ Task #44（2026-08-08/09）销记：对齐原版 putCustomVariable 语义（variable 为 JSON Map，custom 键读写）；仅 inBookshelf 时 updateBook 落库，非在架提示先加入书架；保存前读回完整 Book 防全行覆盖。原建议 FFI `set_book_variable` 不再必要（既有 updateBook 已满足） |
| 5 | ~~导出书签 / 导出 Markdown~~（已接线） | `flutter_legado/lib/src/screens/toc_screen.dart` `_handleMenu('exportBookmark'/'exportMd')` | ✅ Task #44（2026-08-08/09）销记：新建 `services/bookmark_export.dart`，JSON 8 字段对齐原版 GSON 序列化（剔除 id），MD 模板对齐 saveBookmarkMd，file_picker 选目录，文件名 bookmark-书名 作者；原建议 FFI `export_bookmarks` 不必要（原版导出为纯 JSON/MD 序列化，已以纯 Flutter 实现闭合）。遗留差异登记：getBookmarks 契约 §2.7 仅按书名查询（原版按书名+作者），待后续契约批次补 bookAuthor 参数 |
| 6 | ~~章节缓存状态云图标~~（已闭合） | `toc_screen.dart` 目录 Tab 章节行 | ✅ 销记确认（Task #44 登记，2026-08-08/09）：契约 §2.43.5 `cacheListCachedChapterUrls` 已登记，toc_screen 已消费并提交（9cf205d8d/7fb6d1ba2） |
| 7 | ~~删除重复标题正文处理链路~~（已接线） | `flutter_legado/lib/src/widgets/reader/reader_top_bar.dart` `_toggleSameTitleRemoved` | ✅ Task #57（2026-08-10）销记：已接线，契约 §2.9.10 toggleSameTitleRemoved（caches KV 章级 opt-out 持久化、正文净化六链路按章应用、缓存清理复位对齐原版 .nr 语义）；顶栏开关接通并重载正文 |

> ✅ **销记（2026-08-08/09，Task #44 第一批后置项接线）**：6 项中 4 项闭合——②创建书籍更新任务、④设置书籍变量、⑤导出书签/导出 Markdown 接线完成（详见各行销记），⑥章节缓存云图标确认闭合（契约 §2.43.5 + 提交 9cf205d8d/7fb6d1ba2）；剩余 ①上传至远程、③设置源变量、⑦删除重复标题正文链路，待对应 FFI 交付后接通。
>
> ✅ **销记（2026-08-10，Task #57 第二批后置项接线）**：①上传至远程（契约 §2.28.6 webdavUploadFile）、⑦删除重复标题正文链路（契约 §2.9.10 toggleSameTitleRemoved）接线完成（详见各行销记）；§5.11 现仅剩 ③设置源变量（需 DB 迁移，列入第三批）。
>
> ✅ **销记（2026-08-10，Task #71 第三批后置项接线）**：③设置源变量（契约 §2.3 setSourceVariable + Migration102To103）接线完成（详见行内销记）；**§5.11 全部 7 项至此全部闭合**。

### §5.12 MoreConfig/界面面板「仅持久化待行为接线」集中清单（2026-08-08，三维度评审修复时新增）

> 以下开关/参数已按原版键名持久化（`reader_config_panel.dart` ReaderAdvancedConfig）且 UI 已诚实标注，但尚无行为消费方；后续接线时按建议位置接入，接通一项销记一项。

| # | 键（=原版键） | 语义 | 后续消费位置建议 |
|---|----------------|------|------------------|
| 1 | ~~`doubleHorizontalPage`~~（已接线） | 双页模式（0-3 档） | ✅（2026-08-10，v2.0.7 批）销记：`reader_page_view.dart` 档位判定（0=单页/1=双页/2=横屏双页/3=平板或横屏，滚动模式强制单页，桌面端窗口宽≥700 为平板语义）+ 每栏可用宽（屏宽-边距-16 栏间隙）/2 + 双栏整屏渲染（`_buildSpread` 左 2s 右 2s+1，末屏右栏留白）+ 屏索引翻页（步进 2）+ 分页缓存键；slide/simulate/none/cover 四翻页模式适配 |
| 2 | ~~`useZhLayout`~~（已接线） | 自定义中文分行 | ✅（2026-08-10，v2.0.7 批）销记：`paragraph_layout_engine.dart` `ParagraphConfig.useZhLayout`（默认 true 保持现行为）+ `_breakLines` 朴素按宽断行分支（无避头尾，对齐原版 useZhLayout=false StaticLayout 语义）+ 分页缓存键 |
| 3 | ~~`hangingPunctuation`~~（已接线） | 段首标点悬挂 | ✅（2026-08-10，v2.0.7 批）销记：`ChinesePunctuationRule.shouldHang`（缩进全角空格+起始引号判定，对齐原版 HangingPunctuationRule）+ `ZhLayout.compute` 首行宽度上限 + 悬挂宽（=缩进宽）+ `_breakLines` 两分支首行悬挂 + `LineInfo.hangingWidth` 标记 + 渲染侧 OverflowBox 放宽约束 + Transform.translate 左移（标点悬挂进缩进区） |
| 4 | ~~`pageTouchSlop`~~（已接线） | 滑动翻页阈值 px | ✅ Task #44（2026-08-08/09）销记：`reader_page_view.dart` 经 MediaQuery gestureSettings 覆写拖拽阈值，滚动模式除外（对齐原版仅横向翻页语义），即时生效 |
| 5 | ~~`pageTouchClick`~~（已接线） | 边缘点击阈值 px | ✅ Task #44（2026-08-08/09）销记：`reader_screen.dart` 点击边缘死区（钳制半屏以内防窄窗重叠），对齐原版 setRect9x 边缘条带语义，即时生效 |
| 6 | `readBodyToLh` | 正文延伸到刘海 | 仅 Android：`reader_screen.dart` SystemUiMode/SafeArea 接线 |
| 7 | `paddingDisplayCutouts` | 填充刘海区域 | 仅 Android：同上，AndroidManifest layoutInDisplayCutoutMode 配合 |
| 8 | `volumeKeyPage` / `volumeKeyPageOnPlay` | 音量键翻页/朗读时音量键翻页 | 仅 Android：平台通道拦截 KeyEvent 后接 `reader_page_view` 翻页 API |
| 9 | `shareLayout` | 日/夜配置共用布局 | 待日夜双配置体系接入（ReadBookConfig 双套布局参数）后在 `reader_settings_sheet.dart` 生效；UI 副标题已标注「暂不生效」 |

> ✅ **销记（2026-08-08/09，Task #44）**：4 `pageTouchSlop` / 5 `pageTouchClick` 两项行为接线完成（详见各行销记）。
>
> ✅ **销记（2026-08-10，v2.0.7 批）**：1 `doubleHorizontalPage` / 2 `useZhLayout` / 3 `hangingPunctuation` 三项行为接线完成（详见各行销记；原版语义对齐：双页档位/朴素分行/段首引号悬挂，差异注明：桌面端平板语义以窗口宽≥700 模拟）；**剩余 4 项**（6 `readBodyToLh` / 7 `paddingDisplayCutouts` 仅 Android、8 `volumeKeyPage` 仅 Android、9 `shareLayout` 待日夜双配置体系）登记延后。

### §5.13 主题设置页/其他设置页「缺跨轨支撑后置」集中清单（2026-08-08，任务 #8 原版对齐时新增）

> 以下原版（pref_config_theme.xml / pref_config_other.xml / pref_config_cover.xml）设置项依赖 WebView/Cronet/Room 数据库/JS 引擎等跨轨能力，经核查 `flutter_legado/lib/src/bridge` 与 `book_api.dart` 均无对应 FFI 支撑，按三分类原则 UI 不显示空壳项，登记待后续接线；接通一项销记一项。

| # | 项/原版键 | 原版代码位置 | 现状与建议 |
|---|-----------|--------------|------------|
| 1 | ~~自定义 hosts~~（`customHosts`，已接线） | OtherConfigFragment → HandleFileContract 导入 JSON | ✅ Task #78（2026-08-10）销记：已接线，契约 §2.20.3 setCustomHosts；legado-net Resolve DNS 覆盖（实时读全局映射 + 系统 DNS 回落）、持久化启动恢复；其他设置页 JSON 编辑对话框对齐原版。差异注明：非法输入拒绝保存而非原版清除。覆盖缺口见 §5.14-15 |
| 2 | ~~校验书源配置~~（`checkSource`，已接线） | OtherConfigFragment → CheckSourceConfig 对话框 | ✅ Task #44（2026-08-08/09）销记：`other_settings_screen.dart` 新增配置对话框，字段对齐契约 §2.3 CheckerConfig 7 项（keyword/step_timeout_ms/check_search/check_toc/check_content/detect_captcha/detect_redirect），级联约束与超时校验对齐原版 CheckSourceConfig，持久化并入 start() configJson |
| 3 | 直链上传规则（`directLinkUploadRule`） | OtherConfigFragment → DirectLinkUpload.getConfig | 依赖 JS 规则执行（上传接口规则解析）；建议随分享/上传功能批次一并设计 FFI |
| 4 | Cronet 开关（`Cronet`） | pref_config_other.xml（AppConst.isPlayChannel 才显示） | Android Play 渠道专属网络栈，桌面端 Rust reqwest 无对应物；长期不适用，仅登记不实现 |
| 5 | 视频播放设置（`videoSetting`） | OtherConfigFragment → VideoSettingDialog | 依赖视频播放器模块（Flutter 端尚未重构视频播放）；待播放器模块落地后补 |
| 6 | ~~MCP 服务端口~~（`mcpPort`，已接线） | OtherConfigFragment → MCPServerService | ✅ Task #78（2026-08-10）销记：已接线，契约 §2.22.5 setMcpPort 独立端口（对齐原版 McpService，默认 1236）；差异注明：区间 1024..65530 越界报错（原版无此校验）。评审加固：仅挂 /mcp/tools /mcp/call /health、127.0.0.1 回环绑定、DB 路径对齐主应用、状态机互斥 + 同端口重启竞态修复；实机验证监听地址与重启恢复。后续留项见 §5.14-14/17 |
| 7 | ~~JS Source API Token（`jsSourceApiToken`，已接线）~~ | pref_config_other.xml → SourceApi / McpService | ✅ 2026-08-13（F5）：`set_mcp_port` 前置非空 `config:jsSourceApiToken`；`/mcp/*` 校验 `X-Legado-Token`；LAN 绑定 `0.0.0.0`（对齐原版局域网可达） |
| 8 | 清除 WebView 数据（`clearWebViewData`） | OtherConfigFragment.clearWebViewData | 桌面端无 WebView 组件（未引入 webview_flutter/webf）；引入 WebView 方案后一并接入 |
| 9 | ~~压缩数据库~~（`shrinkDatabase`，已接线） | OtherConfigFragment → AppDatabase VACUUM | ✅ Task #57（2026-08-10）销记：已接线，契约 §2.16.6 shrinkDatabase（VACUUM + 释放字节统计、失败降级返回 0）；其他设置页对齐原版提示 |
| 10 | ~~封面规则~~（`coverRule`，封面设置子项，已接线） | CoverConfigDialog → BookCover.CoverRule（JS 规则搜封面） | ✅ Task #78（2026-08-10）销记：searchCoverRules；✅ 2026-08-13（F4）：契约 get/save/deleteCoverRule + 主题页配置对话框；coverRules DDL 已入 schema（§5.14-16） |

> ✅ **销记（2026-08-08/09，Task #44）**：2 校验书源配置接线完成（详见行内销记）；⚠️ 口径更正：6 mcpPort「Rust 侧无对应服务」描述已过时（legado-server 已有 MCP 路由），剩余决策为独立端口 vs 复用 setServerPort；其余 8 项维持后置登记。
>
> ✅ **销记（2026-08-10，Task #57 第二批后置项接线）**：9 压缩数据库接线完成（契约 §2.16.6 shrinkDatabase，详见行内销记）；其余 8 项维持后置登记。
>
> ✅ **销记（2026-08-10，Task #78 第四批后置项接线）**：1 自定义 hosts（契约 §2.20.3 setCustomHosts）、6 MCP 服务端口（契约 §2.22.5 setMcpPort 独立端口）、10 封面规则（契约 §2.4.8 searchCoverRules）三项接线完成（详见行内销记）；§5.13 剩余 5 项（3 直链上传规则/4 Cronet/5 视频播放/7 jsSourceApiToken/8 清除 WebView 数据）维持后置登记。
>
> ✅ **销记（2026-08-13，F4/F5）**：7 jsSourceApiToken（MCP 前置校验 + X-Legado-Token）、10 封面规则 CRUD（get/save/deleteCoverRule）闭合；§5.13 剩余故意后置 4 项（3 直链上传/4 Cronet N/A/5 视频播放/8 清除 WebView）。

### §5.14 第二批后置项与搜索崩溃根治遗留/风险登记（2026-08-10，Task #57 新增）

> 第二批后置项接线与搜索 native 崩溃根治过程中发现的遗留项与已知风险，登记备查，闭合一项销记一项。

| # | 遗留/风险 | 说明 |
|---|-----------|------|
| 1 | ✅ getSameTitleRemoved 权威查询 | 2026-08-13：`reader_get_same_title_removed` + `reader_can_remove_same_title` + UI 勾选态权威回读；「未找到可移除的重复标题」提示已复刻 |
| 2 | ~~getBookmarks 契约 §2.7 缺 bookAuthor 参数~~（已闭合） | ~~书签按书名查询（原版按书名+作者），同名书可能混入（§5.11-5 销记曾登记为遗留差异，此处正式立项）~~ ✅ Task #71（2026-08-10）销记：契约 §2.7 getBookmarksByBook（书名+作者双键，加法式）已冻结并实现；消费方全切换（bookmark_notifier/toc_screen/书签导出）；MCP 宿主加法式可选 book_author 参数；单键旧查询兼容保留（见 #11） |
| 3 | ~~BookRepository::insert OR REPLACE 重复插入隐患~~（已闭合） | ~~重复插入触发 chapters 外键级联删除风险，建议改 upsert（INSERT OR IGNORE + 按需 update）链路~~ ✅ Task #71（2026-08-10）销记：upsert 重构（主键判存在 + 原地 UPDATE / insert_replace）+ import_books 覆盖链路同步改造 + 新增重复插入保留 chapters 测试；残余见 #10 |
| 4 | ✅ webdav_upload_file 大文件流式 | 2026-08-13：`WebDavClient::put_file` ReaderStream 边读边 PUT；FFI 不再整文件读入内存 |
| 5 | FRB 内置隐藏 runtime 栈 | FRB 内置隐藏 runtime（flutter_rust_bridge rust_async）仍为默认 2MB 栈；根因已由 rule_analyzer 修复 + regex_safe 非递归预检消除，此项为纵深防御可选 |
| 6 | 个别书源 bookUrl 为空 | QQ阅读等个别书源 bookUrl 为空（「Parser error: bookUrl不能为空」），源数据问题，与代码无关，建议修源 |
| 7 | 搜索崩溃根治纪要 | （2026-08-10）四轮调查定位 rule_analyzer 零前进无限递归（移植时将原版 throw 改为 break 重试所致），已对齐原版 fail-fast + tailrec 修复并五轮复测零崩溃；正则安全编译统一入口（非递归嵌套预检 + LRU + logcat 诊断）作为纵深防御保留 |
| 8 | 69 实机回归 D1/D2 修复纪要（Task #70） | （2026-08-10）D1：设置源变量对话框「确定」100% 红屏，根因为 TextEditingController 在外部函数作用域创建 + Navigator.pop 后退场动画期间提前 dispose（`_dependents.isEmpty` 断言 + OverlayEntry Duplicate GlobalKey）；已按 _TextPromptDialog 范式重构为自持 StatefulWidget `_VariableDialog`（controller 在 State 内 late final 创建、dispose 随子树卸载、确定先取值再 pop），_setBookVariable 同式加固。D2：源列表偶发整表显示「暂无书源」（重启恢复、非数据丢失），根因为搜索框 filterKeyword 位于全局 provider 而搜索框 controller 随 State 重建，离屏返回后关键词残留致 filteredSources 恒空；已修复：source_screen dispose 同步 clearFilter + loadSources 空列表不覆盖非空内存的防御守卫 |
| 9 | 书签作者改写边界 | （Task #71 登记）书籍作者被元数据刷新改写后，旧书签（存旧 author）在书签 Tab/导出不可见；此为对齐原版双键查询语义的预期行为，验收知悉项，不另行修复 |
| 10 | 二级索引 (name,author) 冲突时 insert_replace 跨书级联残余 | （Task #71 登记）同 name+author 不同书的极端冲突下 insert_replace 仍可能跨书级联（与 upsert 改造前一致）；后续加固方向：插入前 find_by_name_author 预检 |
| 11 | getBookmarks 单键查询兼容保留 | （Task #71 登记）getBookmarks 单键（仅书名）查询已无生产消费方，为兼容既有调用保留；建议后续标注 @Deprecated 并择机移除 |
| 12 | ~~JS 链书源 bookUrl 为空~~ | ✅ 2026-08-13（T6）：CSS→`@js:` 链 `test_parse_search_book_url_css_js_chain`（quickjs）通过；空 bookUrl 回退书源主页（v1.26）已落地；个别源数据空链仍见 #6 |
| 13 | ~~coverRule 规则数据管理~~ | ✅ 2026-08-13（F4）：契约 get/save/deleteCoverRule + 主题设置配置对话框 |
| 14 | ~~MCP 服务局域网可达 + token 鉴权~~ | ✅ 2026-08-13（F5）：`0.0.0.0` LAN + 非空 `jsSourceApiToken` + `X-Legado-Token` |
| 15 | ✅ customHosts 覆盖缺口 | 2026-08-13：webdav / rule_update_client / legado-server source_update 直建 Client 均挂 `custom_hosts::resolver()` |
| 16 | coverRules 表 DDL 游离迁移体系 | ✅ 已完成（2026-08-13）：`CREATE_COVER_RULES` 纳入 `schema.rs` init_schema + Migration103To104 确保建表 |
| 17 | ~~MCP 前置 jsSourceApiToken 校验未实现~~ | ✅ 2026-08-13（F5）：与 §5.13-7 一并闭合 |
| 18 | ✅ loginCheckJs（含 server/UI） | 2026-08-13：legado-server fetcher 四链路接 loginCheckJs；Flutter 阅读器遇 LoginRequired 自动拉登录。此前 FFI 路径 v2.0.8 已闭合 |
| 19 | ✅ XPath 引擎 xmlns 声明根治（2026-08-10，v2.0.9） | 思兔 sto66 实测「未从书源解析到任何章节」根因：页面源码自带 `<html xmlns=...>` 时 HTML→XHTML 回退原样保留 xmlns 属性 → sxd-document 全部元素进命名空间 → 无前缀 XPath（//dd、//a）全部失配（仅 //* 与谓词字符串可命中）；`write_node_xhtml` 跳过 xmlns 属性根治；回归测试 test_xmlns_declaration_does_not_break_prefixed_xpath；legado-parser 178+1 全过。另确认思兔 loginCheckJs 为空（非登录问题）、tocUrl 链路各环节现状登记 |

---



**文档版本**: 1.30  
**最后更新**: 2026-08-11  
**维护人**: Qoder  
**最后修改**: Reasonix

**版本记录**：
- v1.42（2026-08-11）必应漫画 type=0 正文刷 `<img>` HTML 销记（v2.0.33，[UI]，Reasonix）：书源 type=0 + `.img@img@html`+FULL，图片直连 200 JPEG 无防盗链问题；文本阅读器不渲染 img → 裸标签。修复抽图规则提升为 image 走漫画阅读器 + 文本侧图片主导正文兜底。版本 2.0.33+35
- v1.41（2026-08-11）搜索相对 URL 绝对化 + 目录 `<js>$[*]` 链拆解 + `{{$.}}` 双花括号销记（v2.0.30，[Rust]，Reasonix）：批量探针 type=2 仅 12/89 有搜索命中；根因——parse 缺 baseUrl、无 path host 拼接命中 `://` 假域名、get_elements 误拆 `<js>+$[*]` 吞错、`{{$.id}}` 残留花括号。51 TOC 0→1；神漫画 TOC=61。版本 2.0.30+32
- v1.40（2026-08-11）51封面 coverDecodeJs + AnalyzeRule `@put`/`@js`链/`##`/`{$.}` URL 模板 + 神漫画/Nhentai TOC/正文 + 搜索去重含 origin 销记（v2.0.29，[Rust]+[UI]，Reasonix）：封面密文直连失败；神漫画 bookUrl 内嵌 `{$.comic_id}` 误当 JsonPath；目录 `@put`/`@js` 链与正文 chapter.index/totalChapterNum 缺口；Nhentai `//script@js`。探针：神漫画 TOC=61 CONTENT>2k、Nhentai TOC=1 CONTENT>7k。搜索未声称与原版全网数量完全一致。版本 2.0.29+31
- v1.39（2026-08-11）漫画空目录自愈销记（v2.0.27，[UI] 为主 + [Rust] 回归，Reasonix）：emulator-5558 取证——51漫画 DB `chapters=0` + `notShelf|image`，详情未落库目录，`ReaderComicScreen` 缺 `refreshToc` 自愈（文本 `ReaderNotifier` 已有）→「暂无章节」导致正文/图链路不可达。Rust 同书源实测搜索/TOC/正文/AES imageDecode 均通。修复 comic/video/audio 空目录 refreshToc + 开读前落库。搜索全网差距未完全对齐（page=1、去重无 addOrigin、部分源 QuickJS 失败），待用户同关键词对比。版本 2.0.27+29
- v1.38（2026-08-11）对称加密 JS 对象桥 + aesBase64DecodeToString + 图片魔数校验销记（v2.0.26，[Rust]+[UI]，Reasonix）：emulator-5558 实测——① 51漫画等 imageDecode 依赖 `java.createSymmetricCrypto(...).decrypt(Uint8Array)`，旧实现返回字符串致解密失败密文上屏；② 全网漫画等依赖 `java.aesBase64DecodeToString` 解 AES 目录/正文，缺桥致 404/空目录。版本 2.0.26+28
- v1.37（2026-08-11）书架 BookType 分流 + 复合图片 URL 抽取 + 漫画 FFI 预加载 + imageDecode 每次新引擎/Referer + 视频相对 URL/重试/进度 + 媒体 MPD 钩子销记（v2.0.25，[Rust]+[UI] 双轨，Reasonix 实施，Auto 协调交付）：① `BookOpenUtils` 统一书架/详情按位标记分流（含视频路由）；② HtmlFormatter/comic_image_utils 完整抽取 `url,{headers}` 复合 src；③ 漫画预加载与渲染统一 FFI；④ imageDecode 每次新建引擎（勿 pool redeclaration）+ 主页 Referer 兜底修正；⑤ 视频相对 URL 绝对化、重试当前章、进度写回；⑥ 媒体正文 MPD 跳过 HTML 净化并 normalize_content 钩子透传。版本 2.0.25+27。待用户以可用图片/视频源实测（避开 favcomic NXDOMAIN）
- v1.36（2026-08-11）规则 JS 执行引擎池复用 const redeclaration 修复登记（v2.0.24，[Rust] 轨，Reasonix 实施）：模拟器实测仍无目录、但 Rust 网络测试通过的差异根因——进程内引擎池复用：书源规则顶层 `const/let` 声明（51漫画 chapterList `const scripts`）在 QuickJS 同一引擎第二次执行报 redeclaration（全局词法环境残留，实测 FIRST OK/SECOND ERR）；测试每次新进程干净池通过，app 内多次刷新第二次执行失败。修复：QuickJsExecutor.execute_js 每次执行创建独立新引擎（用完即弃，对齐原版 Rhino 新作用域），移除 pool 字段（pool_engine 保留供 imageDecode 等）。测试：legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.24+26）。待用户实测 51漫画目录与正文图片
- v1.35（2026-08-11）漫画源目录「暂无章节」最终根治登记（v2.0.23，[Rust] 轨，Reasonix 实施）：51漫画真实链路实测打通（refresh_toc 出章节 url=/comic/5957/chapter/18465、正文 5395B 含真实图片 URL），四层根因——① QuickJS eval 严格模式禁止裸赋值（书源 `d = ...` ReferenceError，原版 Rhino 宽松允许）：prologue 预声明 var d/data/json/list/arr/obj/tmp（避开书源 const scripts/c/item 防冲突）；② get_elements 对 `<js>` 误路由（resolve_rule_type 判 Auto/Css 走 HTML 解析器）：开头显式识别 `<js>` 转 get_strings；③ `<js>...</js>\n$[*]` 复合规则 `</js>` 后 JSONPath 后缀被忽略：get_strings `<js>` 分支对 `$[...]` 逐元素拆解；④ java 桥 `@attr` 链（`.btn-read@href` 取属性非 CSS 选择器）：select_with_attr 拆分 selector@attr + @text。测试：legado-parser 182/182、legado-js 471/471、legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.23+25）。待用户实测 51漫画等目录与正文图片
- v1.34（2026-08-11）漫画源目录「暂无章节」根治登记（v2.0.22，[Rust] 轨，Reasonix 实施）：根因⑥——漫画书源目录/正文规则大量用原版 JsExtensions HTML 元素桥 `java.getElement/getString`（51漫画 chapterList `<js>Array.from(java.getElement("script"))</js>`、快看/爱优漫依赖），重构版 java 仅有工具函数 → ReferenceError → 目录空；且 get_chapters 未注入 book 绑定（51漫画规则 book.name）。修复：新增 legado-js host_api/html_parse.rs（getElement/getElements 返回元素对象数组[html()/text()/toString()/attr()]，getString/getStrings 取文本，内容源读 globalThis.src，getString 第二参 mContent 覆盖；仅挂 java 命名空间；legado-js 加 scraper 0.22）；web_book get_chapters 从 ruleBookInfo.name 提取书名注入 book 绑定。测试：legado-js 471/471（新增 html_parse 3 测试）、legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.22+24）。待用户实测 51漫画/快看等目录
- v1.33（2026-08-11）漫画站图片复合 URL 支持登记（v2.0.21，[Rust]+[UI] 双轨，Reasonix 实施）：根因⑤——favcomic.com 等漫画书源正文图片 URL 为原版复合格式 `url,{"headers":{...}}`（内嵌防盗链 header，对齐原版 AnalyzeUrl.kt analyzeUrl 切首个 `,` 前为 URL、后部 JSON 解析 headerMap），CachedNetworkImage 直连无法解析 → Invalid image data。修复：Rust `fetch_image_with_decode` 新增 `split_composite_image_url`（AnalyzeUrl 拆分 + 内嵌 headers 与书源 header 合并，内嵌优先）；Flutter `reader_comic_screen` 图片统一走 FFI 下载（无 imageDecode 原样返回 bytes），_bookSource==null 保留直连兜底。测试：Rust 264/264（新增 test_split_composite_image_url）、flutter 1153/1153、5556/5558 冒烟 6/6。书源侧遗留（非代码）：favcomic.net 图床 ccdeoo.ykxbo.cn NXDOMAIN、favcomic.com 连接失败，图片源以其他可用漫画源验证
- v1.32（2026-08-11）书源 jsLib 加载失败降级登记（v2.0.20，[Rust] 轨，Reasonix 实施）：根因——favcomic 等漫画/视频书源混淆 jsLib 依赖 Android Rhino 特有全局（Packages Java 桥/decode 等），QuickJS 无法完整执行（实测 "decode is not defined"）；v2.0.19 将 jsLib 求值失败改报错阻断 → 所有带 jsLib 书源正文解析失败（「能搜到但正文图片/视频无法显示」全局回归）。修复：jsLib 求值失败降级为 eprintln 警告继续执行（正文规则多为纯正则/CSS 不依赖 jsLib，favcomic 正文 2966B 恢复；引用缺失函数仍自然 ReferenceError 可排错）。实测 favcomic 搜索→目录→正文恢复；legado-ffi 263/263；5556/5558 冒烟 6/6。书源侧遗留（非代码）：favcomic 图床 ccdeoo.ykxbo.cn 已 NXDOMAIN，图片显示需书源更新/换源
- v1.31（2026-08-11）漫画/图片源 imageDecode 解码 + JS 注入严格模式根治登记（v2.0.19，[Rust]+[UI] 双轨，Reasonix 实施）：① 漫画/图片站图片无法显示根因③——**imageDecode 解密缺失**（favcomic 等站点图片 bytes 经加密，书源 `ruleContent.imageDecode` 配合 jsLib JS 解密后才可显示，重构版仅有字段无执行）。修复：Rust 新增 `image_api`（下载[书源 header 防盗链+兜底 Referer] → 注入 `result`(Uint8Array)/`src`(URL) 执行 imageDecode JS → base64），`legado-js` 新增 `eval_bytes`（`JsValue::Bytes` 改 Uint8Array 注入/结果读回，异常消息取 ctx.catch 真实文案），`ffi.rs` frb 模块新增 `fetch_image_with_decode`（上一版误加进已冻结的 `bridge.rs` 调不到，已移除恢复冻结约束）；Flutter `reader_comic_screen` 书源含 imageDecode 规则时走 FFI 解码下载（Image.memory，缓存+重试），无规则保持直连不回归；② JS 规则严格模式裸赋值根因④（上轮卡点）——绑定注入改 `globalThis.result = ...`（裸赋值在 QuickJS 严格模式抛 ReferenceError 致全部 @js:/jsLib 规则空，var 版本与 jsLib let/const 冲突，globalThis 两者兼得，对齐原版 ScriptableObject.put）；jsLib 求值失败不再静默吞；③ 修复 `_preloadVisibleImages` loading 态访问未 attach ScrollController 断言。测试：legado-ffi 263/263、legado-js 468/468、legado-parser 180/180、flutter analyze 0 error、flutter test 1153/1153。实机：重建 .so（x86_64+arm64-v8a quickjs）→ 5556 无崩溃 UI 完整渲染、5558 冒烟 6/6（此前 content hash 不匹配系 APK 旧 .so）。遗留：armv7 so 编译失败（NDK 28 链接问题，模拟器 x86_64/arm64 真机不受影响）；favcomic 图片解码实机端到端待用户以可读书源验收
- v1.30（2026-08-11）漫画/视频源正文与目录根治登记（v2.0.18，[Rust] 轨，Reasonix 实施）：双根因——① JS 规则执行零变量注入（原版 evalJS bindings result/src/baseUrl/chapter/title/source，AnalyzeRule.kt:893-908；重构版 execute_js_rule 裸执行 → 视频源 `String(result)`/漫画源 `src.match()` ReferenceError → 正文空）；② `@a` 后缀误判为属性提取（"a" 是标签选择链语义，非属性）→ 漫画 chapterList `.right_box:nth-child(2)@a` 目录 0 章。修复：AnalyzeRule 自动注入 result/src/baseUrl + with_js_binding 补充 chapter/title/source（web_book 正文解析传章节标题）；html.rs 常见标签名白名单。实测真实站点：伪七猫影视（视频）目录+正文 m3u8 ✅；favcomic（漫画）目录 8 章+正文 2966B `<img>` 列表 ✅（书源原规则可用）。legado-parser 180/180、legado-ffi 261/261。遗留：armv7 so 编译失败（NDK 28 链接问题，模拟器 x86_64/arm64 真机不受影响）
- v1.29（2026-08-11）离线缓存界面交付登记（v2.0.17，[UI] 轨，Reasonix 实施）：§5.2 #4 销记——新增 OfflineCacheScreen（路由 /offline_cache，对齐原版 CacheActivity）：书架书籍缓存状态列表（item_download.xml 三行布局：书名/作者/「已缓存 N/总章节数」+ 播放/停止下载按钮 + 单本导出按钮）；顶栏菜单全部缓存（download_all）/缓存当前章节之后（download_after，sureCacheBook 确认框）/停止全部下载/下载队列；缓存数 + 任务状态 2s 轮询（对齐 EventBus 语义）；书架菜单「缓存导出」替换为「离线缓存」（对齐 menu_download 入口，原选书导出对话框迁移为页内单本导出，功能等价）。新增 widget 测试 5 个，flutter analyze 0 error、flutter test 1150/1150。
- ✅ **v1.38（2026-08-13）schema v102 结构对齐专项强制落地（SCHEMA_VERSION 103→104）**：台账 §4.2.1 五项结构偏离 + rssStars 主键 + search_keywords + coverRules 入体系；Migration103To104 幂等重建；契约/台账同步销记。残留 rule_subs/dict_rules/keyboard_assists 表名未改。
- ✅ **v1.37（2026-08-13）增强遗留 C 批销记（v2.0.43）**：§5.14 #1 getSameTitleRemoved/`canRemoveSameTitle`；#4 webdav 流式 PUT；#15 customHosts 直建 Client；#18 loginCheckJs server+UI；缓存任务落库；自定义字体族核销（FontScreen）。schema v102 已于 v1.38 强制执行。
- v1.28（2026-08-10）缓存下载链路根治登记（v2.0.16，[UI] 轨，Reasonix 实施）：根因——阅读页缓存走 downloadAddTask（Rust download_api.rs 仅内存任务登记无下载执行，cached_chapters 永不写入→目录云图标不亮）；cacheDownloadStart/Progress/List/Cancel FFI 已生成但 Dart 零调用；无下载队列页。修复：BookApi/RustApi/MockBookApi 封装 4 方法；阅读页缓存对话框改 cacheDownloadStart（真实下载）；新增 CacheDownloadScreen 队列页（任务列表/进度/取消，2s 轮询，路由 /cache_downloads + 书籍信息页菜单入口）；目录页云图标 2s 轮询实时刷新（对齐原版 EventBus.SAVE_CONTENT）。新增 widget 测试 2 个，flutter test 1145/1145、analyze 0 error；5558 冒烟 5/5。✅ **2026-08-13 销记遗留①**：缓存任务落库 caches KV（`cacheDownloadTask:*`）+ 进程重启续传。
- v1.27（2026-08-10）图片源搜索 + 漫画正文 + 视频播放链路根治（v2.0.15，[Rust]+[UI] 双轨，Reasonix 实施）：① 图片书源分组搜不到——AnalyzeRule 不支持 `<js>` 标签（仅认 `@js:` 前缀，`<js>...</js>` 落入 CSS/Auto 解析返回空；原版 RuleAnalyzer 两者同视为 Mode.Js），get_strings 补 `<js>` 包裹识别执行；② 漫画正文图片不显示——正文/目录/信息/搜索解析全链路（web_book.rs 9 处 analyzer 调用点 + parse_content_page/fetch_paginated_content/fetch_sub_content/apply_content_replace_regex）注入书源 jsLib（漫画源 ruleContent 大量 `<js>eval(String(Reload('...')))</js>`，不注入 JS 抛错→空正文）；Flutter 漫画阅读器图片请求带书源防盗链 header（CDN 校验 Referer 否则 403）+ 相对路径以章节 URL 为 base 转绝对；③ 视频无法播放——正文 jsLib 注入 + `_extractVideoUrl` 支持 iframe/video/source/embed 标签 src（播放器页 HTML 场景）+ 播放请求带书源 header。新增 Rust 测试 3 个（`<js>`+jsLib 正文解析/无 jsLib 降级/web_book jsLib），cargo test legado-ffi 261 + legado-parser 178 全过，flutter analyze 0 error、flutter test 1143/1143，5558 实机待用户验证（图片源分组中文词搜索→点开→开始阅读看正文图；视频源同理看播放）
- v1.26（2026-08-10）搜索无结果根治（v2.0.14，[Rust] 轨，Reasonix 实施）：根因链三段——① yckceo 书源 896/968 源 searchUrl 含 `{{}}` 模板，大量 `{{encodeURIComponent(key)}}`（思兔 sto66 等）而 quickjs 宿主未注册该函数 → URL 残缺；② 漫画/视频/聚合源 searchUrl 用 `<js>eval(String(Reload('...')))` 动态加载与 jsLib 函数（getHosts 等），模板执行器不注入 jsLib 且沙箱禁 eval → URL 构建失败（图片/视频源搜索无结果主因）；③ bookUrl 空不回退、缺 UA 被反爬拒。修复：encodeURIComponent 注册（JS 标准语义）；QuickJsExecutor/construct_analyzer/build_search_url 支持 jsLib 注入（对齐原版每次 eval 前加载库）；EnginePool 默认允许 eval（对齐原版 Rhino 书源信任模型，js_eval 调试端点仍严格沙箱）；`<js>`/`@js:` 模板统一走 JS 求值路径；bookUrl 空回退书源主页；搜索请求补 Chrome UA。实测：思兔 URL 渲染正确、sto66 HTTP 200 出书条目。新增 10 个 Rust 测试，legado-ffi 259 + legado-js 468 全过；5558 重建 APK 冒烟 5/5（版本标签 2.0.14）
- v1.25（2026-08-10）图片/音频/视频源分流失效根治（v2.0.13，Reasonix 实施）：根因双断点——① Rust 搜索输出 AnnotatedCandidate 不带 type（Flutter bookType 恒 0）；② 阅读前落库 `0|notShelf` 致 8/32/64 类型位永久丢失（第二次起 `bt≠0` 兜底不触发→落回文本阅读器）。修复：_openReader 缺类型位时按书源类型映射补全位标记、落库/回填正确类型位、video 分支进 /video；VideoScreen 支持视频源书章节播放（章节列表+当前章链接+上/下集，对齐原版 VideoPlayerActivity）；新增 4 个分流 widget 测试（含缺类型位回归），全量 1143/1143。实机验证受限说明：5558 无法 adb 输入中文关键词（cmd clipboard 不可用），图片源真实书搜索交由用户验证（分组选「图片书源」→中文关键词→点开→开始阅读）
- v1.24（2026-08-10）阅读进度恢复 + 图片/音频源分流修复登记（v2.0.12，Reasonix 实施）：① 进度不恢复——详情页旧快照不刷新（Rust books 表已存 dur_chapter_index 但页面实例不重读），_openReader 阅读返回后 setState 重载 + openBook 恢复 durChapterPos，5558 实机验证「第5章跳转→返回→再进」正确恢复；② 图片/音频源——BookType 常量 0/1/2 枚举误义修正为位标记（text=8/audio=32/image=64，与 Rust 返回 type 一致）、_openReader 按位标记分流（audio→/audio、image→/reader-comic、文本→/reader，缺失兜底按 bookSourceType）、书架音频/视频分组改位运算；新增 3 个分流 widget 测试，全量 flutter test 1141/1141、5558 冒烟 5/5 通过
- v1.23（2026-08-10）搜索/阅读 UI 三问题修复登记（v2.0.11，Reasonix 实施）：① 搜索异常书源弹窗消除——批次 error 消费补齐（单源失败静默不弹 UI、appLogPush error 级留痕「书源搜索出错」，对齐原版 SearchModel 仅 AppLog.put；经原版源码核实「原版批次错误弹 SnackBar」为误判，原版单源失败无任何 UI 提示）；② 搜索框文字垂直裁切——isDense + textAlignVertical.center + suffixIcon 32×32 约束；③ 书籍信息页简介默认全部显示（_ExpandableText 默认展开保留收起）。新增 search_notifier 单测 2 个（失败批次静默留痕/全败空态），flutter analyze 0 error、相关测试 58/58 与全量 1138/1138 全过，模拟器冒烟 5556 通过
- v1.22（2026-08-10）搜索三修复登记（v2.0.10，Reasonix 实施）：① 排序对齐原版 mergeItems 四档分桶（默认搜索也按匹配度排序，精准丢 other+重搜）；② 卡顿修复（分桶移入批次回调，build 直接消费）；③ bookUrl 空校验文案可读化（legado-core 两处 + 测试断言更新）
- v1.21（2026-08-10）XPath 引擎 xmlns 修复登记（v2.0.9，Reasonix 实施）：§5.14 追加 #19——页面自带 xmlns 声明导致无前缀 XPath 全部失配（思兔 sto66 实测），`write_node_xhtml` 跳过 xmlns 属性根治，新增回归测试
- v1.20（2026-08-10）loginCheckJs 登录检测修复登记（v2.0.8，Reasonix 实施）：§5.14 追加 #18——FFI 路径三处语义修正（result 对象注入/判定剥引号/未登录双路径上抛+环境不兼容降级）已销记；遗留登记 legado-server fetcher 登录检测与 Flutter 登录自动跳转
- v1.19（2026-08-10）§5.12 销记三项纯 Flutter 行为接线（doubleHorizontalPage 双页 0-3 档/useZhLayout 中文分行开关/hangingPunctuation 段首标点悬挂，v2.0.7 批，Reasonix 实施）：`reader_page_view` 双栏整屏渲染+屏索引翻页+分页缓存键；`paragraph_layout_engine` 朴素断行分支+悬挂规则；`zh_layout` 首行悬挂放宽；渲染侧悬挂行左移；全量 flutter test 1135/1135 通过零回归；剩余 4 项（刘海×2/音量键×2 仅 Android、shareLayout 待日夜双配置）延后登记

- v1.18（2026-08-10）Task #78 第四批后置项接线销记与遗留登记：§5.13 销记 3 项（①自定义 hosts §2.20.3 setCustomHosts DNS 覆盖+持久化+JSON 编辑对话框、差异注明非法输入拒绝保存；⑥MCP 服务端口 §2.22.5 setMcpPort 独立端口默认 1236+区间越界报错差异注明，评审加固：仅挂 MCP 路由/回环绑定/DB 路径对齐/状态机互斥+同端口重启竞态修复；⑩封面规则 §2.4.8 searchCoverRules 执行启用规则+测试入口，CRUD 诚实标注待后续）；§5.14 追加登记 5 项（#13 coverRule 规则 CRUD 待契约、#14 MCP 局域网可达+token 鉴权待后续、#15 customHosts 对直建 reqwest::Client 链路不生效的覆盖缺口、#16 coverRules 表 DDL 游离迁移体系须入 schema 对齐专项、#17 原版 McpService 前置 jsSourceApiToken 校验未实现依赖 §5.13-7）
- v1.17（2026-08-10）Task #71 第三批后置项接线销记与遗留登记：§5.11 销记 ③设置源变量（契约 §2.3 setSourceVariable + Migration102To103 补列 + `_VariableDialog` 对齐原版 source 分支），**§5.11 全部 7 项至此闭合**；§5.14 销记 2 项（#2 getBookmarks 补 bookAuthor → 契约 §2.7 getBookmarksByBook 双键查询 + 消费方全切换 + MCP 加法式可选参数；#3 BookRepository upsert 重构根治级联删除 + import_books 覆盖 + 重复插入保留 chapters 测试）；§5.14 追加登记 4 项（#9 书签作者改写边界验收知悉项、#10 二级索引冲突 insert_replace 跨书级联残余与预检加固方向、#11 getBookmarks 单键查询兼容保留建议 @Deprecated、#12 JS 链书源 bookUrl 为空待查）；另 frb 配对纪律入 TWO_TRACK_DEV_SPEC §3.5
- v1.16（2026-08-10）Task #57 第二批后置项接线销记与遗留登记：§5.11 销记 2 项（①上传至远程 §2.28.6 webdavUploadFile、⑦删除重复标题 §2.9.10 toggleSameTitleRemoved）+ 小结更新为仅剩③设置源变量（需 DB 迁移，第三批）；§5.13 销记 1 项（⑨压缩数据库 §2.16.6 shrinkDatabase）；新增 §5.14 本轮遗留/风险登记 7 项（getSameTitleRemoved 权威查询契约缺位与原版提示未复刻、getBookmarks 缺 bookAuthor、BookRepository OR REPLACE 级联删除隐患、webdav_upload_file 大文件流式改造、FRB 隐藏 runtime 栈纵深防御、个别书源 bookUrl 为空的源数据问题、搜索崩溃根治纪要：rule_analyzer 零前进无限递归根因 + 对齐原版 fail-fast/tailrec 修复五轮复测零崩溃 + 正则安全编译统一入口纵深防御保留）
- v1.15（2026-08-08/09）Task #44 第一批后置项接线销记：§5.11 销记 3 项（创建书籍更新任务/设置书籍变量/导出书签·导出 Markdown）+ 章节缓存云图标闭合确认；§5.12 销记 2 项（pageTouchSlop/pageTouchClick）；§5.13 销记 1 项（校验书源配置）。口径更正 3 处：§5.13-6 mcpPort（legado-server 已有 MCP 路由，剩余决策为独立端口 vs 复用 setServerPort）、§5.9-2 定时服务后端（应用内调度器 auto_task_scheduler.dart 已落地）、§5.11-5 原建议 export_bookmarks FFI 不必要（原版导出为纯 JSON/MD 序列化，已以纯 Flutter 实现闭合）
- v1.14（2026-08-08）任务 #8 主题/其他设置页原版对齐登记：新增 §5.13「缺跨轨支撑后置」集中清单（10 项：customHosts/checkSource/uploadRule/Cronet/videoSetting/mcpPort/jsSourceApiToken/clearWebViewData/shrinkDatabase/coverRule）；主题页 24 项、其他页 33 项已按三分类落地（实现/仅 Android 标注/登记后置）
- v1.13（2026-08-08）三维度评审修复登记：§5.11 追加删除重复标题正文处理链路（建议 FFI `toggle_same_title_removed`）；新增 §5.12 MoreConfig/界面面板「仅持久化待行为接线」集中清单（9 项含后续消费位置建议）
- v1.12（2026-08-08）模块 D+E 交付登记：新增 §5.11 BookInfo 4 个占位项 + 导出书签/Markdown FFI 建议（set_source_variable/set_book_variable/upload_book_remote/create_update_task/export_bookmarks）+ 章节缓存云图标后置登记
- v1.11（2026-08-07）R 系列全批闭合销记（Task #140）：新增 §5.10 R1-R10+R12 销记明细；QUIC 客户端六件套由「待封装」改为「已移除（用户决策，纯重构边界）」；§5.9 留项 3 补记 R7/R8 Rust 大头已闭合；schema v102 保持触发型延后
- v1.10（2026-08-07）留项#12 闭合销记（Task #131）：§5.9 留项 1 searchSource 分组过滤全链修复（Rust sourceSwitchSearch 加 sourceUrlsJson 参数 + 换源页按分组过滤 + 主搜索页选分组自动重搜）
- v1.9（2026-08-06）评审修复口径修正（Task #122）：日志入口销记修正为 7/7（source_edit_screen 补接，补提交）、缺口④补记 UI 接线提交、新增 §5.9 TODO(留批次) 正式登记（searchSource 分组过滤等 3 项）
- v1.8（2026-08-06）批次0-3 缺口闭合销记（Task #119）：§5.1-§5.6 全部销记（8 提交：0cde41a5c/873abea29/b7368193a/9ac94b173/522e1c1be/6633c25e3/0c452f4b5/13a11220e），Rust 4 项 P1 实质缺口闭合，残留留项见审计报告 §7
- v1.7（2026-08-06）批次3治理闭合（Task #118）：bridge.rs 去留决策记录（保留+计划性废弃，§4.2.3 P2-1）、schema v102 评估（建议延后，§4.2.1）、一次性脚本清理销记（§4.2.3 P2-4）、§5.7 治理表更新
- v1.6（2026-08-06）新增 UI 细节与功能缺口专项章节（§5），整合 Flutter 92 项 UI 缺口与 Rust 4 项 P1 实质缺口双轨审计
- v1.5（2026-08-03）整合四路审计结论，新增审计整合章节（§4）
- v1.4（2026-08-02）新增全量源码检查后续修改计划（§3）
- v1.0（2026-07-31）初版：P0-P3 共 7 项遗留任务 + UI 一致性 13 项整合

---
编写者：Qoder
日期：2026-08-06
