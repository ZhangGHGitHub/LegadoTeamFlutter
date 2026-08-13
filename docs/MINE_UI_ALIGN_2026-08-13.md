# 「我的」设置树对齐原版说明（2026-08-13）

编写者：UI 子代理 ｜ 2026-08-13

## 基准

- Android：`MyFragment` + `pref_main.xml`；子页 `ConfigActivity` →
  `pref_config_theme.xml` / `pref_config_other.xml` / `pref_config_backup.xml`；
  `AboutFragment` + `about.xml`
- Flutter：`SettingsScreen` 及 `theme_config` / `other_settings` /
  `webdav_settings`（备份与恢复）/ `about` 等

## 改动屏幕

| 屏幕 | 文件 | 对齐要点 |
|------|------|----------|
| 我的枢纽 | `settings_screen.dart` | 文案对齐 values-zh；删「导出日志」；备份进全页；字典规则命名 |
| 备份与恢复 | `webdav_settings_screen.dart` | 全页结构对齐 pref_config_backup；菜单：帮助/导入旧版/日志；恢复长按本地 |
| 其他设置 | `other_settings_screen.dart` | 删创意「默认阅读/网络」分组；条目顺序对齐 XML；清理缓存；Cronet/直链占位 |
| 主题设置 | `theme_config_screen.dart` | 去掉重复「主题模式」；通用项顺序对齐；白天/夜间分组 |
| 关于 | `about_screen.dart` | 条目对齐 about.xml；去掉技术栈/捐赠等创意块 |

## 差异表（原版 vs 改后 Flutter）

| 项 | 原版 | 改前 Flutter | 改后 |
|----|------|--------------|------|
| 枢纽「导出日志」 | 无（在关于/备份菜单） | 有 | 已删 |
| 备份入口 | ConfigActivity 全页 | 底部 Sheet | 全页「备份与恢复」 |
| 定时任务开关标题 | 运行定时任务 | 定时任务服务 | 已对齐 |
| 字典规则 | 字典规则 | 词典规则 | 已对齐 |
| 其他设置阅读/网络分组 | 无 | 有（创意） | 已删 |
| 清理缓存 | Preference 动作 | 缓存管理子页入口 | 清理缓存动作 |
| Cronet / 直链上传 | 有 | 隐藏 | 诚实占位「暂不可用」 |
| 主题页主题模式 | 仅枢纽 | 枢纽+主题页双份 | 仅枢纽 |
| 关于 | 开发人员/更新日志/检查更新+其他 6 项 | 技术栈卡片+营销入口 | 对齐 about.xml |
| 创建堆转储 | Android 实现 | — | 诚实占位 Toast |
| 更新日志/免责 MD | assets | 无资产 | 内置占位文案 |

## 未接线 / 占位（勿当假功能）

1. **Cronet**、**直链上传规则**：无 Flutter/Rust 等价引擎 → UI 占位不可用
2. **创建堆转储**：无桌面/Flutter 堆转储 API → Toast 说明
3. **更新日志 / 免责声明** MD：未打包 assets → 占位正文
4. **仅保留最新备份 / 自动检查新备份**：已持久化偏好键；后台检查逻辑待 Bridge 行为接通
5. **默认阅读字体/代理超时**：已从「其他设置」移除；阅读器内设置与既有 SettingsService 仍保留数据

## 视觉

apple-ui-designer：`IosGroupedBody` / `IosGroup` / `IosSectionHeader` 分组 inset 列表；
枢纽主题模式用系统感 Bottom Sheet；配色/字体可与原版 Material 不同。
