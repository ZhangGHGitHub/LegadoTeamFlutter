# 批14 主题包 zip 与单条导出 — 设备验收报告

验收日期：2026-11-10
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
证据目录：`docs/materials_1110e/`

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器，`192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | `ro.product.model=SM-G9900`（MuMu 模拟），Android 15（API 35） |
| 分辨率 / 密度 / 逻辑宽度 | 1080x1920，480dpi → **360dp 宽** |
| 系统字体缩放 | `font_scale=1.0` |
| 被测包 | `io.legado.flutter_legado` |
| 设备路径 / APK sha256 | `/data/app/~~ceGLXaVH6nfhDO6lRb4wfA==/io.legado.flutter_legado-IST8q6l-Ce4W8L_G0vJl2A==/base.apk`，`sha256=0f9b9287407e3eefdf4168281de7a6c5bf28d1feb7089195723a1b1d319e2ac4`（与任务给定值一致，设备内 `sha256sum` 实测） |
| 设备实测版本（dumpsys） | `versionName=2.0.483`，`versionCode=484`，`lastUpdateTime=2026-11-10 18:29:45` |
| 声明目标版本 | `2.0.483+484`（`flutter_legado/pubspec.yaml` 第 4 行）——与设备一致 |
| 主题基线 | 色板「草野」，主题模式「跟随系统」（浅色外观），无自定义配色、无背景图 |
| 测试数据 | 自定义白天主题 `QA14`：主色调 `#2196F3`（`4280391411`）、主要字体色 `#D32F2F`（`4292030255`），其余 10 槽为 0（未设置），无背景图 |
| 导出产物 | `/sdcard/Download/legado/legado_theme_QA14_1794306955376.zip`，357 B，`sha256=ee08178ecff3c8f0789727108b53acf1f06ea453f8bd1cef38c1c451ac903afe` |
| 异常包 | `qa14_invalid.zip`（64 B，纯文本改名）；`qa14_v2.zip`（169 B，zip 内仅 `manifest.json={"formatVersion":2,"name":"x","config":{}}`） |

版本核对：设备 APK sha256、`dumpsys` 版本、`pubspec.yaml` 三者一致，未发现版本漂移。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 9 |
| FAIL | 0 |
| BLOCKED | 0 |
| 合计 | 9 |

结论：批14「主题包 zip 与单条导出」在设备上验收项全部通过。自定义主题 `QA14` 保存后于「主题管理」列表出现，单条导出图标可用；导出落盘 `Download/legado/legado_theme_QA14_*.zip`，zip 内 `manifest.json` 为 `formatVersion=1`、含 `name` / `config`（12 色槽）/ `assets`，颜色值与导出前实测一致；删除后重新导入同一 zip 提示「已导入主题包 QA14」并回列表，且**未自动应用**（导入后当前界面仍为恢复后的默认配色）；手动应用后主色调蓝 `#2196F3` 与主要字体色红 `#D32F2F` 与导出前截图一致，页面底色保持默认；非法 txt 改名 zip 与 `formatVersion=2` 伪造包均给出中文失败提示、未崩溃、列表未新增；logcat 五项崩溃/异常计数均为 0；`pm clear` 清理后设备回到桌面终态。补充验证：force-stop 冷启动后已应用主题（蓝顶栏 + 红标题）保持。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1110e/`） | 说明 |
| --- | --- | --- | --- |
| A1 保存自定义主题并显示导出图标 | PASS | `tmp_qb14_06_primary_picker.png`、`tmp_qb14_07_primary_blue.png`、`tmp_qb14_08_primarytext_red.png`（主色调蓝 + 主要字体色红）、`tmp_qb14_09_save_dialog.png`、`tmp_qb14_09b_save_named.png`、`tmp_qb14_10_saved.png`（toast「已保存主题「QA14」」）、`tmp_qb14_11_theme_manage_QA14.png`、`ui_b14_17.xml` | 外观页「自定义主题 · 白天」设置主色调蓝、主要字体色红后保存 `QA14`；「主题管理」列表出现 `QA14`（白天主题），右侧依次为导出（tooltip「导出主题包」，40dp 可点区）、重命名、删除三个图标 |
| A2 单条导出并校验 zip | PASS | `tmp_qb14_12_export_saf.png`、`tmp_qb14_13_saf_confirm.png`、`tmp_qb14_14_export_done.png`（toast「已保存到「下载/legado」：legado_theme_QA14_1794306955376.zip」）、`legado_theme_QA14_1794306955376.zip`、`theme_manifest_b14.json` | 点导出图标 → 系统保存器停在 `Download/legado` →「使用此文件夹」→「允许」；`adb shell ls -l` 实测 `357 B, 2026-11-10 18:36`；`adb pull` 取回后 sha256 见环境表；zip 仅含 `manifest.json`（无背景图故无 `assets/` 文件）；清单字段见「关键取证摘要」 |
| B3 删除后导入同一 zip | PASS | `tmp_qb14_15_theme_deleted.png`（「暂无保存的主题配置」）、`tmp_qb14_18_import_picker.png`、`tmp_qb14_19_import_search.png`、`tmp_qb14_20_imported.png`（toast「已导入主题包 QA14」+ 列表 QA14） | 删除后列表为空；「导入主题包」打开系统选择器（默认 `Download/legado`），经搜索选中 zip；解析成功写入列表。**重名条件未触发**：导入前已删除同名主题，故实际名称为 `QA14`；`X → X 2 → X 3` 递增由单测/组件测试覆盖（见门禁） |
| B4 导入后未自动应用 | PASS | `tmp_qb14_16_picker2.png`、`tmp_qb14_17_defaults_restored.png`（主色调/主要字体色均恢复「默认」，界面回到草野棕色）、`tmp_qb14_20_imported.png`（导入完成瞬间仍为默认棕色、深色文字） | 导入前先将主色调与主要字体色「恢复默认」作为差异基线；导入成功后当前界面保持默认草野棕色，未变为包内蓝/红，证明只入库、不自动应用 |
| B5 应用导入主题后配色一致 | PASS | `tmp_qb14_21_applied.png`（toast「已应用主题「QA14」」，顶栏蓝、标题红）、对比基线 `tmp_qb14_08_primarytext_red.png`、`ui_b14_33.xml` | 点击列表项应用后，顶栏 `#2196F3`、主要字体色 `#D32F2F`，与导出前截图一致；页面底色保持默认（包内 `assets.background` 为空，无背景图场景） |
| C6 非法文件导入 | PASS | `tmp_qb14_22_invalid_import.png`（toast「导入失败：无法读取主题包（文件格式不正确）」） | 64 B 纯文本改名 `qa14_invalid.zip`（`adb push` 到 `Download/legado`）可被选择；解析在 EOCD 预检即拒绝，中文提示，应用未崩溃，主题管理对话框保留、列表未新增 |
| C7 formatVersion=2 伪造包 | PASS | `tmp_qb14_23_v2_import.png`（toast「导入失败：不支持的主题包版本: 2」） | 宿主 python 生成 zip（仅 `manifest.json`，`formatVersion=2`）→ push → 导入；提示含「不支持的主题包版本」，未崩溃，列表未新增 |
| D8 logcat 五项崩溃计数 | PASS | `logcat_b14_session.txt`（5,765 行，全程采集）、`logcat_b14.txt`（801 行，「清空 → force-stop → 冷启动 → 进外观页」干净段） | 两个文件实测均为：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0 |
| D9 清理与终态 | PASS | `tmp_qb14_26_terminal.png` | `adb shell pm clear io.legado.flutter_legado` 返回 `Success`；`pidof` 无输出；`mCurrentFocus=com.microsoft.launcher/.Launcher`；`font_scale=1.0`；截图显示桌面 |

补充说明（不计入 9 项）：冷启动持久化验证——`tmp_qb14_24_coldstart.png`（书架页蓝顶栏 + 红标题）、`tmp_qb14_25_coldstart_appearance.png`（外观页同配色）。`force-stop` 后冷启动，已应用主题保持。

### 关键取证摘要

导出的 zip（`legado_theme_QA14_1794306955376.zip`，357 B，sha256 `ee08178e…ac903afe`）条目：`['manifest.json']`；`manifest.json` 524 B（拉回证据文件 `theme_manifest_b14.json`，sha256 `e4fa37e9470d4eafe8320dd59376c7cd5fe16e99c500b31bfcf015567dfc8f12`）：

```json
{
  "formatVersion": 1,
  "name": "QA14",
  "appVersion": "2.0.483",
  "config": {
    "isNight": false,
    "paletteId": null,
    "colors": {
      "primary": 4280391411,
      "accent": 0,
      "background": 0,
      "bottomBackground": 0,
      "primaryText": 4292030255,
      "secondaryText": 0,
      "primaryNight": 0,
      "accentNight": 0,
      "backgroundNight": 0,
      "bottomBackgroundNight": 0,
      "primaryTextNight": 0,
      "secondaryTextNight": 0
    }
  },
  "assets": {
    "background": {}
  }
}
```

`4280391411 = 0xFF2196F3`（蓝，与主色调截图一致）；`4292030255 = 0xFFD32F2F`（红，与主要字体色截图一致）；`formatVersion` 为整数 `1`；`name`/`config`/`assets` 四个验收要求字段齐全。

## 四、发现的问题（分级）

### 问题 1（低，系统流程/环境行为）：Android 15 SAF 首次导出需选择子目录并授权
- 现象：点导出后系统保存器不允许直接使用 Download 根目录，本次停在 `Download/legado`，需点「使用此文件夹」并在系统对话框点「允许」；应用 toast 回显实际路径「下载/legado」。
- 影响：多一步系统授权，属 Android 15 存储策略与系统文件选择器行为，不是应用缺陷；未发生静默丢失。
- 建议：无需代码修改；验收文档可注明首次导出需授权 `Download/legado`。
- 证据：`tmp_qb14_12_export_saf.png`、`tmp_qb14_13_saf_confirm.png`、`tmp_qb14_14_export_done.png`。

### 问题 2（低，提示文案细节）：版本拒绝提示带数值与半角冒号
- 现象：`formatVersion=2` 包的提示为「不支持的主题包版本: 2」，验收措辞为「不支持的主题包版本」。
- 影响：语义一致、可读，非缺陷；仅文案与验收清单不完全逐字一致。
- 建议：如要求逐字一致，可将 `ThemePackageException('不支持的主题包版本: ${version ?? '未知'}')` 改为中文全角冒号或去掉版本号。
- 证据：`tmp_qb14_23_v2_import.png`；代码位置 `flutter_legado/lib/src/services/theme_package_service.dart:385-386`。

### 问题 3（低，导入器 UX 观察）：系统文件选择器首屏未显示目标 zip
- 现象：导入选择器默认列出 `Download/legado` 全部文件（按系统排序），本次 zip 不在首屏，需经右上角「搜索」输入文件名后选择。
- 影响：属系统 DocumentsUI 行为，非应用缺陷；搜索与选择均正常。
- 建议：无需代码修改；若后续需要更短路径，可考虑应用内最近主题包列表（超出本批范围）。
- 证据：`tmp_qb14_18_import_picker.png`、`tmp_qb14_19_import_search.png`。

### 结论
无中/高等级问题，无 FAIL / BLOCKED 项；以上 3 项均为低等级观察，不阻塞批14 验收。

## 五、设备终态

| 项目 | 终态 |
| --- | --- |
| `pm clear` | `Success`（`io.legado.flutter_legado` 应用数据已清空） |
| 应用进程 | `pidof io.legado.flutter_legado` 无输出，已退出 |
| 前台窗口 | `mCurrentFocus=Window{96da3b4 u0 com.microsoft.launcher/com.microsoft.launcher.Launcher}` |
| 系统字体缩放 | `font_scale=1.0` |
| 屏幕 | 桌面（`tmp_qb14_26_terminal.png`） |
| APK | 仍安装 `2.0.483+484`（未卸载、未降级），设备内 sha256 未变 |
| 残留测试产物 | 设备 `/sdcard/Download/legado/` 保留 `legado_theme_QA14_1794306955376.zip`、`qa14_invalid.zip`、`qa14_v2.zip`；应用内主题/颜色偏好随 `pm clear` 清除 |

## 六、门禁引用

| 门禁 | 命令 | 结果 | 备注 |
| --- | --- | --- | --- |
| 静态分析 | `flutter analyze`（`flutter_legado/` 下执行） | `No issues found! (ran in 15.8s)` | 2026-11-10 设备验收后本地复跑，0 诊断 |
| 单测 | `flutter test test/unit/theme_package_service_test.dart` | 通过 | 覆盖 zip 清单往返、非法路径/路径穿越、超大条目/总量超限、未知资源忽略、STORED/DEFLATE、重名递增 `X → X 2 → X 3`、文件名净化等 |
| 组件测试 | `flutter test test/widget/theme_config_package_test.dart` | 通过 | 覆盖导出图标/导入按钮、非法 zip 中文提示、重名加「 2」且不自动应用、无背景包应用后清除日夜旧壁纸、12 槽全量写入、paletteId 生效/无效、360dp/320dp + 1.3 倍字体不溢出等 |
| 单测+组件测试合计 | `flutter test test/unit/theme_package_service_test.dart test/widget/theme_config_package_test.dart` | **35 tests, All tests passed（00:13）** | 输出末尾「All tests passed!」；中间 `FormatException` 为负向用例预期日志 |
| 设备门禁 | 本报告第三节 9 项 + logcat 五项 | 9/9 PASS，五项计数 0 | 证据见 `docs/materials_1110e/` |
| CI 归属说明 | 按 `AGENTS.md` 第 77 行，`flutter analyze && flutter test`、`cargo test`、`:app:testAppReleaseUnitTest` 以 CI 结果为准 | —— | 本次仅针对性复跑批14 相关 2 个测试文件；未跑全量 Flutter 测试套件与 Rust/FFI 门禁（本批不涉及 Rust/FFI 改动），在此显式声明未覆盖 |
| 工作区状态 | `git status --short` | 仅 `.zcode/` 与 `docs/materials_1110e/` 未跟踪 | 未修改任何代码 |

### 验收边界与声明
- 本报告只证明设备运行时行为与 UI 证据；配色一致性基于截图目视对比（主色调 `#2196F3`、主要字体色 `#D32F2F`），未做像素级色值采样。
- 主题包**带背景图**的导出/导入/应用链路未在本轮设备覆盖（`QA14` 无背景，`assets.background` 为空）；设备端验证的是「无背景时页面底色与导出前一致」，带背景清除/还原由组件测试「应用无背景主题包：清除日/夜旧壁纸」覆盖。
- 重名「 2」后缀未在设备端触发（导入前已删除同名主题）；该行为由单测「重名递增：X → X 2 → X 3」与组件测试「导入主题包：重名加「 2」、写入列表但不自动应用」覆盖。
- 设备端仅验证 2026-11-10 安装的 `2.0.483+484` 版本；未验证旧版本升级/降级路径与其它 Android 版本。
