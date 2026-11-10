# 批13 App 主题 12 色槽（主要/次要字体色）— 设备验收报告

验收日期：2026-11-10
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
证据目录：`D:/OH-WorkSpace/LegadoTeam/legado/docs/materials_1110d/`

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器，`192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | `ro.product.model=SM-G9900`（MuMu 模拟），Android 15（API 35） |
| 分辨率 / 密度 / 逻辑宽度 | 1080x1920，480dpi → **360dp 宽**（A2 的 360dp 条件即设备默认） |
| 系统字体缩放 | 初始 `font_scale=1.0`；A2 期间临时设 1.3，验收结束实测恢复为 `1.0` |
| 被测包 | `io.legado.flutter_legado` |
| 设备路径 / APK sha256 | `/data/app/~~_NIR0nbNLTrOOyROAJUbLA==/io.legado.flutter_legado-MxHxCuDL22qnBRllBYFGtg==/base.apk`，`sha256=11f858a460d892633bc90404763116af19d2f042ecf3e797fddc78104b6d0eeb`（与任务给定值一致，设备内 `sha256sum` 实测） |
| 设备实测版本（dumpsys） | `versionName=2.0.482`，`versionCode=483`，`lastUpdateTime=2026-11-10 15:58:41` |
| 声明目标版本 | `2.0.482+483`（`flutter_legado/pubspec.yaml` 第 4 行）——与设备一致 |
| 主题基线 | 色板「草野」，主题模式初始「跟随系统」（浅色外观）；期间按用例切「深色 / 浅色」 |
| 测试数据 | 主题色槽：白天主要字体色 `0xFF2196F3`（蓝）、白天次要字体色 `0xFFD32F2F`（红）、夜间主要字体色 `0xFF4CAF50`（绿）；自定义主题 `QA13-Day`、`QA13-Night`；导出文件 `legado_theme.json`（425 字节） |

版本核对：设备 APK sha256、`dumpsys` 版本、`pubspec.yaml` 三者一致，未发现版本漂移。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 11 |
| FAIL | 0 |
| BLOCKED | 0 |
| 合计 | 11 |

结论：批13「App 主题 12 色槽（主要/次要字体色）」在设备上验收项全部通过。白天/夜间各有 6 行色槽且顺序为 主色调 → 强调色 → 主要字体色 → 次要字体色 → 背景色 → 底部操作栏颜色；360dp + `font_scale=1.3` 下无布局溢出；主要/次要字体色改色即时作用于标题、正文与次要文本（设置页副标题/图标）；「恢复默认」可清除两色；夜间未设置时逐字段继承白天、设置后使用夜间独立值；`force-stop` 冷启动后颜色与主题模式保持；白天/夜间自定义主题可保存并在「主题管理」中应用；导出 JSON 含 `primaryText`/`secondaryText` 字段，导入同一文件后颜色不变；logcat 五项崩溃/异常计数均为 0；`pm clear` 清理后设备回到桌面终态。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1110d/`） | 说明 |
| --- | --- | --- | --- |
| A1 白天 6 行与顺序 | PASS | `tmp_qb13_A1_day_6rows.png`（组头「自定义主题 · 白天」+ 6 行）、`tmp_qb13_05_appearance_top.png`（入口）、`tmp_qb13_08_day_header.png`（同帧） | 顺序：主色调 → 强调色 → 主要字体色 → 次要字体色 → 背景色 → 底部操作栏颜色；每行值列均显示「默认」；主要/次要字体色行副标题为「与动态取色同时使用时可能影响对比度」 |
| A1 夜间 6 行与顺序 | PASS | `tmp_qb13_A1_night_6rows.png`（组头「自定义主题 · 夜间」+ 主色调/强调色/主要字体色）、`tmp_qb13_A1_night_6rows_b.png`（主要字体色/次要字体色/背景色/底部操作栏颜色 + 保存夜间主题） | 夜间组 6 行与白天同序（单屏容纳不下，分两张截图覆盖，重叠行可对齐）；uiautomator 语义树顺序一致 |
| A2 360dp + font_scale 1.3 不溢出 | PASS | `tmp_qb13_A2_font13_night.png`、`tmp_qb13_A2_font13_day.png`、`tmp_qb13_A2_font10_restored.png` | 设备本身即 360dp 宽（1080/3）；`settings put system font_scale 1.3` 后字体色行副标题自动换行为两行，无黄黑溢出条、无截断；结束恢复 `font_scale=1.0`（`settings get` 实测） |
| B3 白天主要字体色生效 | PASS | `tmp_qb13_B3_picker_dialog.png`（标题「主要字体色」）、`tmp_qb13_B3_day_primary_set.png`（选蓝后行尾蓝点）、`tmp_qb13_B3_settings_after.png`（设置页标题变蓝）、`tmp_qb13_B3_shelf_after2.png`（书架标题变蓝） | 改前基线见 `tmp_qb13_04_settings.png`、`tmp_qb13_01_launch.png`（标题为默认深色）；改后设置页「外观/高级/阅读界面…」与书架「书架」均为 #2196F3 |
| B4 白天次要字体色生效 | PASS | `tmp_qb13_B4_picker2.png`（标题「次要字体色」）、`tmp_qb13_B4_day_secondary_set.png`（选红后行尾红点、调色板图标变红）、`tmp_qb13_B4_settings_after.png`（设置页副标题与图标变红） | 与 B3 截图对比：标题保持蓝、副标题「主题配色与显示模式」等变为 #D32F2F，证明两槽独立映射 |
| B5 恢复默认 | PASS | `tmp_qb13_B5_defaults_restored.png`（两行值列回到「默认」、色点消失）、`tmp_qb13_B5_settings_reverted.png`（设置页文字回到默认深色） | 两行分别进入色盘点「恢复默认」；uiautomator 语义值由「已设置」回到「默认」；随后设置页与初始基线一致 |
| C6 夜间继承白天 + 夜间独立值 | PASS | `tmp_qb13_C6_night_group2.png`（夜间主要字体色=「默认」，同时深色界面标题为蓝色）、`tmp_qb13_C6_dark_settings_inherit.png`（深色设置页标题蓝）、`tmp_qb13_C6_night_set.png`（夜间改绿后行尾绿点）、`tmp_qb13_C6_dark_settings_nightcolor.png`（深色设置页标题变绿） | 只设白天蓝、夜间留空时切「深色」→ 标题为蓝（继承）；再设夜间绿 → 深色下标题变绿（夜间独立值覆盖），同一截图内可看到夜间行「默认」与蓝色标题并存的继承状态 |
| D7 force-stop 冷启动持久化 | PASS | `tmp_qb13_D7_coldstart.png`（首轮：深色+绿标题）、`tmp_qb13_D7b_coldstart_after_theme.png`（二轮：应用夜间主题后深色+绿标题）、`tmp_qb13_F10_clean_nav.png`（首轮主题冷启动后外观页蓝色标题） | `am force-stop` 后 `pidof` 为空，再冷启动；主题模式（深色）、白天蓝与夜间绿均保持；第二轮另外验证了「应用主题后」的持久化 |
| E8 保存自定义主题并应用 | PASS | 白天：`tmp_qb13_E8_save_day_dialog.png`、`tmp_qb13_E8_day_saved.png`（toast「已保存主题「QA13-Day」」）、`tmp_qb13_E8_theme_manage.png`（列表含 QA13-Day/QA13-Night）、`tmp_qb13_E8_apply_day.png`（toast「已应用主题「QA13-Day」」）、`tmp_qb13_E8_apply_day_settings.png`；夜间：`tmp_qb13_E8b_night_saved.png`、`tmp_qb13_E8b_manage.png`、`tmp_qb13_E8b_apply_night.png`（toast「已应用主题「QA13-Night」」）、`tmp_qb13_E8b_apply_night_settings.png` | 首轮保存 QA13-Day 与 QA13-Night 两份，并应用 QA13-Day（浅色下标题恢复蓝）；首轮 `pm clear` 后补做并复验夜间：保存 QA13-Night → 恢复默认（演示差异）→ 主题管理应用 → 深色设置页标题变绿。两轮均以实际显示色与 toast 取证 |
| E9 导出 JSON 字段 + 导入不变 | PASS | `tmp_qb13_E9_export_saf.png`、`tmp_qb13_E9_saf_folder.png`、`tmp_qb13_E9_saf_confirm.png`、`tmp_qb13_E9_after_allow.png`（toast「已保存到「下载/legado」：legado_theme.json」）、`tmp_qb13_E9_import_picker.png`、`tmp_qb13_E9_after_import.png`（toast「主题已导入」）、`theme_export_b13.json`（425 字节，从设备拉回） | `adb shell cat /sdcard/Download/legado/legado_theme.json` 实测内容：`day.primaryText=4280391411`（=0xFF2196F3 蓝）、`day.secondaryText=0`；`night.primaryText=0`、`night.secondaryText=0`；日夜两组均含 `primaryText`/`secondaryText` 键。导入同一文件后 toast「主题已导入」，白天主字色仍为蓝（设置标题与行尾色点未变，`tmp_qb13_E9_day_unchanged.png`） |
| F10 logcat 五项计数 | PASS | `logcat_b13_session.txt`（3,549 行，首轮全程累积）、`logcat_b13.txt`（597 行，最终「清空→force-stop→冷启动→进外观页」干净段） | 两个文件实测：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0 |
| F11 清理与终态 | PASS | `tmp_qb13_F11_terminal.png` | `adb shell pm clear io.legado.flutter_legado` 返回 `Success`；`pidof` 无输出（进程退出）；`mCurrentFocus=com.microsoft.launcher/.Launcher`；`font_scale=1.0`；截图显示桌面 |

### 关键取证摘要

导出的主题 JSON（`theme_export_b13.json`，md5 `2645cb155dbdeb20ccd293665cac6381`）：

```json
{
  "app": "legado", "type": "theme", "version": 1,
  "paletteId": "def", "themeMode": "light",
  "day": { "primary": null, "accent": null, "primaryText": 4280391411,
           "secondaryText": 0, "background": null, "bottomBackground": null },
  "night": { "primary": null, "accent": null, "primaryText": 0,
             "secondaryText": 0, "background": null, "bottomBackground": null }
}
```

`4280391411 = 0xFF2196F3`，与截图中所选蓝色一致；说明字体色槽真实落盘、序列化与导入解码链路可用。

## 四、发现的问题（分级）

### 问题 1（低，观察/命名差异，非缺陷）：色槽标签与验收清单措辞不同
- 现象：清单写作「主题色 / 底部操作栏色」，实际 UI 为「主色调 / 底部操作栏颜色」；区块标题为「自定义主题 · 白天 / 夜间」而非「主题配色」。
- 影响：仅文案差异，6 行数量与顺序、生效链路均正确；代码注释已登记第 6 槽我方为底栏色（参考版为标签容器色），本批不涉及。
- 建议：验收文档统一使用 UI 实际标签，或在 UI 文案表中固化命名。
- 证据：`tmp_qb13_A1_day_6rows.png`、`tmp_qb13_A1_night_6rows.png`。

### 问题 2（低，观察/映射副作用，非缺陷）：主要字体色同时覆盖 onPrimary 等角色
- 现象：主要字体色映射 `onSurface / onPrimary / onPrimaryContainer`，次要字体色映射 `onSurfaceVariant / onSecondary / onSecondaryContainer / onTertiary`。因此：①「外观 / 我的」页的列表副标题（IosListTile 副标题取 `onSurface@70%`）跟随主要字体色，而「设置」首页副标题跟随次要字体色；②填充按钮文字跟随主要字体色——深色 + 绿色主字色时，「保存主题」对话框「确定」为绿字粉底，可读但对比度偏低。
- 影响：不影响功能与验收项；属于映射口径带来的观感差异，页面副标题已有「与动态取色同时使用时可能影响对比度」提示。
- 建议：若后续要求副标题严格随「次要字体色」，可将 IosListTile 副标题改走 `onSurfaceVariant`，或对 `onPrimary` 采用对比度校正；需产品裁决。
- 证据：`tmp_qb13_B3_day_primary_set.png`、`tmp_qb13_B4_day_secondary_set.png`、`tmp_qb13_E8_save_day_dialog.png`（深色下「确定」为绿字）。

### 问题 3（低，环境行为）：Android 15 SAF 不允许直接使用 Download 根目录
- 现象：导出时系统文件选择器停在 Download，提示「无法使用此文件夹（为保护您的隐私，请选择其他文件夹）」，需进入子目录（本次 `Download/legado`）并授权「允许」。
- 影响：属 Android 15 系统策略，不是应用缺陷；应用 toast 明确回显实际保存路径「下载/legado」，未静默丢失。
- 证据：`tmp_qb13_E9_export_saf.png`、`tmp_qb13_E9_saf_confirm.png`、`tmp_qb13_E9_after_allow.png`。

### 结论
无中/高等级问题，无 FAIL / BLOCKED 项；以上 3 项均为低等级观察，不阻塞批13 验收。

## 五、设备终态

| 项目 | 终态 |
| --- | --- |
| `pm clear` | `Success`（`io.legado.flutter_legado` 应用数据已清空） |
| 应用进程 | `pidof io.legado.flutter_legado` 无输出，已退出 |
| 前台窗口 | `mCurrentFocus=Window{96da3b4 u0 com.microsoft.launcher/com.microsoft.launcher.Launcher}` |
| 系统字体缩放 | `font_scale=1.0`（A2 后已恢复） |
| 屏幕 | 桌面（`tmp_qb13_F11_terminal.png`） |
| APK | 仍安装 `2.0.482+483`（未卸载、未降级） |
| 残留测试产物 | 设备 `/sdcard/Download/legado/legado_theme.json` 保留（已拉回证据目录，md5 见上）；应用内主题/颜色偏好随 `pm clear` 清除 |

## 六、门禁引用

| 门禁 | 命令 | 结果 | 备注 |
| --- | --- | --- | --- |
| 静态分析 | `flutter analyze`（`flutter_legado/` 下执行） | `No issues found! (ran in 14.5s)` | 2026-11-10 设备验收后本地复跑，0 诊断 |
| 单测 | `flutter test test/unit/theme_text_colors_test.dart test/unit/theme_config_json_test.dart` | 通过（含「未设置保留内置 palette」「主要/次要字体色映射」「旧 JSON 无字段」「12 槽往返」「夜间继承」等） | 与 widget 测试合并执行：**31 tests, All tests passed（00:03）** |
| 组件测试 | `flutter test test/widget/theme_text_colors_screen_test.dart` | 通过，覆盖「日夜各 6 行」「改白天/夜间主字色」「恢复默认」「旧 themeConfigList 应用不崩」「360dp + textScale 1.3 不溢出」「保存白天主题→修改→应用往返」 | 同上 31 项合计 |
| 设备门禁 | 本报告第三节 11 项 + logcat 五项 | 11/11 PASS，五项计数 0 | 见 `docs/materials_1110d/` |
| CI 归属说明 | 按 `AGENTS.md` 第 77 行，`flutter analyze && flutter test`、`cargo test`、`:app:testAppReleaseUnitTest` 以 CI 结果为准 | —— | 本次仅针对性复跑批13 相关 3 个测试文件；未跑全量 Flutter 测试套件与 Rust/FFI 门禁（本批不改 Rust/FFI、不新增依赖），在此显式声明未覆盖 |
| 工作区状态 | `git status --short` | 仅 `.zcode/` 与 `docs/materials_1110d/` 未跟踪 | 未修改任何代码 |

### 验收边界与声明
- 本报告只证明设备运行时行为与 UI 证据；布局溢出判断基于截图与 uiautomator 语义树，未做像素级对比度测量。
- E9 的 JSON 校验为设备文件原文（`adb shell cat` + 拉回文件 md5），字段存在且数值与所选颜色一致。
- 颜色主观观感（如深色下绿字按钮对比度）未做量化评分，仅作为低等级观察登记。
