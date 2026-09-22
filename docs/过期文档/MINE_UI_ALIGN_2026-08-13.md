# 「我的」设置树对齐原版说明（2026-08-13）

编写者：UI 子代理 ｜ 2026-08-13  
Commit：`47d8e37a6`（主对齐）+ 分组标题 CJK 修正（若有后续 commit）

## 基准

- Android：`MyFragment` + `pref_main.xml`；子页 `ConfigActivity` →
  `pref_config_theme.xml` / `pref_config_other.xml` / `pref_config_backup.xml`；
  `AboutFragment` + `about.xml`
- Flutter：`SettingsScreen` 及 `theme_config` / `other_settings` /
  `webdav_settings`（备份与恢复）/ `about`

## 改动屏幕（整棵子树覆盖）

| 屏幕 | 文件 | 对齐要点 |
|------|------|----------|
| 我的枢纽 | `settings_screen.dart` | 文案/顺序对齐 pref_main；删「导出日志」；备份进全页；字典规则 |
| 备份与恢复 | `webdav_settings_screen.dart` | pref_config_backup 两组；菜单帮助/导入旧版/日志；恢复长按本地 |
| 其他设置 | `other_settings_screen.dart` | 删创意「默认阅读/网络」；XML 顺序；清理缓存；Cronet/直链占位 |
| 主题设置 | `theme_config_screen.dart` | 去掉重复主题模式；通用项顺序；白天/夜间 |
| 关于 | `about_screen.dart` | about.xml；去掉技术栈/捐赠创意块 |
| 叶子入口 | 书源/定时任务/TXT/替换/字典/书签/阅读记录/文件管理 | 仍为既有管理页，枢纽入口保留 |

## emulator-5556 验证（2026-08-13）

冒烟：`emulator_smoke_test.ps1 -Device emulator-5556 -CheckUI` → **PASSED**（构建/安装/存活/无崩溃/底栏四字）。

| 范围 | 结果 |
|------|------|
| 枢纽条目（滚动采集） | 书源…退出均出现；**无「导出日志」**；Web/MCP 小步滚动可见 |
| 备份与恢复 | WebDav 组 + 备份路径/备份/恢复/忽略/仅最新/自动检查 **均可见** |
| 其他设置 | 主界面/本地密码/Hosts/校验/直链占位/Cronet 占位/清理缓存 **有**；默认阅读/网络 **无** |
| 主题设置 | 切换图标…底栏图集/白天/夜间 **有**；页内主题模式 **无** |
| 关于 | 开发人员…免责声明 **有**；技术栈/捐赠 **无** |

## 差异表（诚实终态）

| 项 | 原版 | Flutter 现状 | 判定 |
|----|------|--------------|------|
| 枢纽信息架构 | pref_main | 同序同组 | ✅ |
| 备份入口 | 全页 Config | 全页（非 Sheet） | ✅ |
| 其他设置创意分组 | 无 | 已删除 | ✅ |
| 关于创意块 | 无 | 已删除 | ✅ |
| Cronet / 直链上传 | 有引擎 | **诚实占位「暂不可用」** | ⚠️ 占位 |
| 创建堆转储 | Android API | **Toast 占位** | ⚠️ 占位 |
| 更新日志/免责 MD | assets | **内置占位文案**（无打包 MD） | ⚠️ 占位 |
| 仅最新备份/自动检查 | 完整行为 | UI+偏好已存；后台检查待接通 | ⚠️ 半接线 |
| 默认阅读字体/代理 | 不在 OtherConfig | 已移出该页；数据仍在 SettingsService | ✅（不造创意项） |
| 视觉 | Material Pref | iOS 分组 inset（apple-ui-designer） | ✅ 允许 |

## 未接线 / 勿当假功能

1. Cronet、直链上传规则：无 Flutter/Rust 等价引擎  
2. 创建堆转储：无堆转储 API  
3. 更新日志 / 免责声明：未打包 `assets/*.md`  
4. 「仅保留最新备份 / 自动检查新备份」：偏好已落盘，后台检查逻辑待 Bridge  

视觉：`IosGroupedBody` / `IosGroup` / `IosSectionHeader`（含中文分组标题不再强制 upper）。
