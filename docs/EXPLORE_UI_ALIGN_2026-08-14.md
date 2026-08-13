# 发现页 UI 对齐原版说明（2026-08-14）

编写者：Auto（Cursor）｜ 2026-08-14  
Commits：`594c5e1cb` / `f10dcffbc` / `cd88582ed` / `2207e207e`（Rust 回归见 `b6707c1c8`）

## 基准

- Android：`ExploreFragment` + `item_explore.xml` / Flexbox 分类 Chip 网格
- Flutter：`ExploreScreen` + `explore_category_chip.dart` / `LegadoAppBar`

## 改动要点

| 屏幕 | 文件 | 对齐要点 |
|------|------|----------|
| 发现枢纽 | `explore_screen.dart` | Flexbox 换行分类 Chip；展开/收起 chevron 深浅色可见 |
| 分类 Chip | `explore_category_chip.dart` | 对齐 Android FlexboxLayoutManager 网格间距与行样式 |
| 书源行 | `explore_screen.dart` | 书源名称/分组行样式对齐 item 布局 |
| 分组列表 | `explore_screen.dart` | iOS 分组 inset 视觉（apple-ui-designer，功能结构不变） |
| 顶栏 | `legado_app_bar.dart` | Tab 根页不显示返回键；子页统一导航（`a56182f64`） |

## Rust 配套（非 UI 但影响发现页数据）

| 项 | commit | 说明 |
|---|---|---|
| 点号索引 | `6bb18abb9` | 发现列表 `$[0].books` 等点号路径解析，修复只显示 1 本 |
| @js 分类 | `b6707c1c8` / `2207e207e` | 分类规则 @js 上下文注入；空缓存重试 |
| 思路客卡顿 | `deca82748` | 详情 HTML 短缓存、目录 AnalyzeRule 复用、nextTocUrl 分页 |

## 差异表（诚实终态）

| 项 | 原版 | Flutter 现状 | 判定 |
|----|------|--------------|------|
| 分类布局 | Flexbox 网格 | Wrap + Chip，对齐间距 | ✅ |
| 展开 chevron | 可见 | 浅色主题修复 | ✅ |
| 书源行 | item_explore | 同行信息密度 | ✅ |
| 视觉 | Material | iOS 分组 inset | ✅ 允许 |
| @js 分类源 | Rhino 宽松 | QuickJS + 上下文注入 | ✅（实网 A\* 仍待用户源验收） |

## 验证

- 冒烟：`emulator_smoke_test.ps1 -Device emulator-5556`（本批未单独 `-CheckUI` 发现页探针）
- 功能回归：`2207e207e` 修复发现页分类解析空列表回归

编写者：Auto（Cursor）｜ 2026-08-14
