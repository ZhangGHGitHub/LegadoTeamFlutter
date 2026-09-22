## 关联导入改弹出式对话框——功能对齐原版，视觉按 MD3 目标风格 — 实施计划（修订）

### 原则
- **功能/交互 = 原版**：弹出式对话框呈现 + 全部功能项（标题、自定义源分组、⋮ 菜单 6 项、勾选/全选（n/m）/取消/确认、打开、状态标签）。
- **视觉 = MD3 目标风格**（docs/design_system.md + M3 对话框规范），不照搬原版配色工具栏；颜色全部取 `colorScheme` token。

### 视觉规范（MD3 化要点）
- **容器**：继承全局 dialogTheme——`surfaceContainerHigh`、圆角 28、透明 surfaceTint（`app_theme.dart:328` 已有）；inset 24；宽近全宽（maxWidth = min(屏宽-48, 640)），maxHeight ≈ 85% 屏高；默认暗色 scrim 居中弹出。
- **头部**：M3 headline 区——标题 `titleLarge`/`onSurface`（左 24 上 24），右侧动作：自定义分组 `TextButton`（`primary` 色）、⋮ / 扫码 / 重置 `IconButton`（`onSurfaceVariant` 图标）；不使用原版实色 Toolbar 底。
- **列表行**：M3 Checkbox（圆角 2）+ 名称 `bodyLarge`/`onSurface` + 状态标签 `labelMedium`——**状态色改用 colorScheme 角色**：新增=`tertiary`、更新=`secondary`、已存在=`onSurfaceVariant`（替代现硬编码 hex）；行分隔用 1px `outlineVariant`；「打开」`TextButton`。
- **底部动作区**：M3 dialog actions 规范（padding 24/16）——左侧 全选（n/m）`TextButton`（0/0 时转「取消全选」语义不变）；右侧 取消 `TextButton` + 确认（n）`FilledButton`（StadiumBorder，0 勾选禁用，`primary` 底）。
- 空态/loading/error 均沿用现有 MD3 组件（ErrorView、CircularProgressIndicator）。

### 功能平移（不改逻辑层）
- `showAssociationImportDialog(context, {url, raw, type, autoLoad})` helper：经 `showDialog` 根导航器弹出，参数结构与现路由 args 一致。
- 新文件 `lib/src/screens/association_import_dialog.dart` 替代 `association_screen.dart`：**完整复用 AssociationNotifier/State 与现有加载/选择/导入逻辑**（选中新增源/选中更新源/保留原名/保留分组/保留启用状态/显示源注释、自定义分组对话框、扫码、重置、文件/剪贴板/地址输入 idle 态全部保留）；状态文案统一「新增/更新/已存在」（对齐原版）。
- 导入完成：结果汇总弹窗（unit 正确）确定后连动关闭导入对话框（对齐原版 importSelect 后 dismiss）。
- 删 `association_screen.dart` 与 `routes.dart` 的 association 路由项；更新 `deep_link_service.dart:98`、`source_screen.dart:1556` 两处调用。

### 验证
- `flutter analyze` 无问题；`flutter test`（现有关联测试仅断言状态解析不受影响；补 1 个对话框渲染冒烟 widget test）
- E2E（emulator-5556）：深链弹出对话框 → 书源/替换规则全流程（菜单项/勾选/全选/确认/结果汇总/自动关闭）
- 冒烟 5556 + 5558 `-CheckUI`；批次 30 / 版本 `2.0.148+149`；CHANGELOG + UI_UPDATE_LOG 行 30；commit `feat(ui)` + push fork

**不触碰**：rust/（后端轨）、provider/state 逻辑层（已 E2E 验证）。