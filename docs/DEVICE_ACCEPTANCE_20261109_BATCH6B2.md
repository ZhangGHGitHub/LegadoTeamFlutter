# 批6b-2 设备验收报告（封面相册）

- 日期：2026-11-09
- 代码基线：`f469ad3768dc85b3f46409dc4796eb01f6ce205f`（`chore: 批6b-2 收尾（2.0.467+468 双日志与计划登记）`）
- 版本：2.0.467+468（versionCode 468）
- 验收范围：A 入口与页面 / B 图片管理 / C 默认封面渲染 / D 迁移与持久化 / E 并发、性能与回归 / F 清理
- 验收结论：**FAIL**（初测）→ **PASS**（2026-11-09 P2 回修复验后更新；原 P2-1 与 P3-1/P3-2 已关闭，见第八章）——release 功能项 A/B/C/D/E/F 全部通过；初测发现 **1 项 P2**（debug 构建打开「相册图片管理 Sheet」触发 `TabAlignment.start` 断言，红色错误页 + RenderFlex overflow），无 P1/P0；另有 2 项子项受测试数据限制未闭环（见「五、BLOCKED / 未闭环」）
- 验收人：QA 子代理（只验收，未修改 `lib/`）
- 证据目录：`docs/materials_1109a/`（279 个文件：截图、uiautomator 语义树、构建日志、APK 哈希、prefs/相册索引 JSON、PSS、logcat）

---

## 一、环境与构建

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例，guest 直连 `192.168.100.62:5555`（SM-G9900 / Android 15 / API 35，x86_64） |
| 显示 | 1080x1920 / 480dpi（`wm size` / `wm density`，验收全程未改动） |
| 系统字号/方向 | `font_scale=1.0`、`user_rotation=0`、`accelerometer_rotation=0`（竖屏） |
| 安装包（最终保留） | `io.legado.flutter_legado` 2.0.467（versionCode 468），release |
| release APK | 208,533,332 B；SHA256 `6db6cf72a57d81fcbd55ca68f4ae08184576ecdc4814082174a76a3d46549696`（`apk_sha256.txt`） |
| debug APK（仅播种/迁移/取证） | 320,649,315 B；SHA256 `eb7463bdc7c4c60f0748530005a1f5f19b1f261b59321298694f50d3669cfe6e` |
| 构建命令 | `cd flutter_legado && flutter build apk --release`（EXIT=0，assembleRelease 90.6s）；`flutter build apk --debug`（EXIT=0，16.5s） |
| 构建日志 | `build_release.log`、`build_debug.log` |
| Rust | 无 Rust/FFI 改动，未重建 `.so` |

说明：

- debug 与 release 同签名，`install -r` 覆盖安装保留数据；除特别注明外，所有验收截图来自 **release**。debug 仅用于：A2 目录清理取证、C4 文件移除、D1 旧偏好迁移播种、D2 失效 ID 播种。
- 测试书 6 本（UTF-8 TXT，经「添加本地」多选导入）：`星海拾遗/风起南洋/山城旧事/无声告白/长夜微光/纸上春秋`。实测 6 本书名不同，但本地 TXT 元数据解析未读取正文中的「作者：」行，作者均显示「未知作者」（既有限制，非本批改动）；相册图 seed 以书名为先，书名不同已足以验证不同书取图差异。
- 测试图片：`light_1_red`(1920x2880)、`light_2_green`、`light_3_blue`、`light_4_orange`、`dark_1_navy`、`dark_2_purple`、`dark_3_teal`（PNG，600x900 或 1200x1800）；`valid_large_25mb.png`（25.83MB，合法 PNG）；`invalid_image.png`（文本改名）；`oversize_33mb.png`（34.60MB，随机字节改名）。设备目录 `/sdcard/Download/qa6b2_images/` 及批量门槛目录 `qa6b2_batch64/`（3×25.83MB）、`qa6b2_batch20/`（21 张同内容小图）。

---

## 二、逐项结果

### A 入口与页面

| 项 | 结果 | 证据 |
|---|---|---|
| A1 设置→封面设置→「默认封面」行副题「应用内置封面」 | **PASS** | `A1_cover_settings.png/.xml`：行副题「应用内置封面」 |
| A1 选择 Sheet 含「应用内置封面」、相册列表、管理入口 | **PASS** | `A1_album_select_empty.png/.xml`：Sheet 标题「选择封面相册」、管理相册按钮（`D:管理相册`）、「应用内置封面」项；空态无相册项 |
| A2 管理页空态 | **PASS** | `A2_manage_empty.png/.xml`：「暂无封面相册」+ 引导文案 |
| A2 新建相册：名称为空确定禁用 | **PASS** | `A2_create_dialog_empty.xml`：确定按钮 `enabled=false`；输入后 `A2_create_dialog_filled.png/.xml` 变为可点 |
| A2 新建相册成功 | **PASS** | `A2_album_created.png/.xml`：卡片「QA-Album-A 日间 0 · 夜间 0」+「已创建相册」提示 |
| A2 重名行为 | **PASS（记录）** | `A2_duplicate_album.png/.xml`：允许创建同名「QA-Album-A」（与源码注释「重名允许，对齐参考版」一致） |
| A2 重命名 | **PASS** | `A2_rename_dialog.xml`（预填旧名）→ `A2_renamed.xml`：名称变为 QA-Album-A2，提示「已重命名为…」 |
| A2 删除二次确认 + 目录清理 | **PASS** | `A2_delete_confirm.png/.xml`（标题/说明/取消/删除）；确认后 `A2_deleted.png/.xml`；`A2_dir_cleanup_runas.txt`：删除含图相册后 `files/cover_albums/` 仅剩 `albums.json` 且内容 `{"formatVersion":2,"albums":[]}`，相册目录已递归清理 |
| A2 当前使用标记 | **PASS** | `A2_current_use_marker.png/.xml`：卡片行「QA-Album-A2 日间 4 · 夜间 0 当前使用」 |
| A2 返回 | **PASS** | 顶栏 Back 返回封面设置页（`A2_current_use_marker.xml` 后的返回流程，无异常） |

### B 图片管理

| 项 | 结果 | 证据 |
|---|---|---|
| B1 日/夜 Tab 与空态 | **PASS** | `B1_editor_empty.png/.xml`：日间/夜间 Tab、「暂无图片，点击右上角导入」；`B1_night_empty.png/.xml` 夜间同 |
| B1 SAF 多选导入 4 张（含 1920x2880 大尺寸图） | **PASS** | `B1_after_import.png`：4 张缩略图 L1–L4（L1 为 1920x2880）；`B1_after_import.xml` 状态「已导入 4 张」 |
| B1 导入后计数/预览正确 | **PASS** | 关闭 Sheet 后管理卡「日间 4 · 夜间 0」；设置行副题「QA-Album-A2 · 日间 4 · 夜间 0」 |
| B1 重复导入同图提示「已存在」 | **PASS** | `B1_duplicate_status.png/.xml`：「4 张图片已存在，未重复导入」 |
| B1 单图删除 | **PASS（行为记录）** | `B1_night_after_delete.png`：点缩略图右上角 X 后立即删除（无二次确认弹窗，见 P3-1）；计数更新，切页正常 |
| B1 空态恢复 | **PASS** | `B1_night_empty_restored.png/.xml`：删空夜间后恢复「暂无图片，点击右上角导入」 |
| B1 日/夜引用同一图，删一侧不误删另一侧 | **PASS** | 将 L1 导入夜间→`B1_night_with_shared.png`（D1/D2/L1）；删除夜间 L1 后 `B1_night_shared_deleted.png` 仅剩 D1/D2，切日间 `B1_day_after_shared_delete.png` 仍有 L1–L4 四张，文件未被误删 |
| B2 超 32MB 跳过/可见提示 | **PASS** | `B2_skip_status.png/.xml`：「2 张跳过：oversize_33mb.png：图片过大（上限 32MB）」，不崩溃 |
| B2 无效图片拒绝/可见原因 | **PASS** | `B2_invalid_status.png/.xml`：「1 张跳过：invalid_image.png：不是可解码的图片：invalid_image.png」 |
| B2 取消选择 | **PASS** | `B2_after_cancel.png/.xml`：返回 Sheet，状态/计数不变，无异常 |
| B2 批量 20 张门槛 | **PASS** | 21 张全选后 `B2_batch20_result.png/.xml`：「单次最多导入 20 张图片」 |
| B2 批量 64MB 门槛 | **PASS** | 3×25.83MB 全选后 `B2_batch64_result.png/.xml`：「本次选择图片总大小超过 64MB」 |
| B3 导入结果/失败原因在弹层内可见 | **PASS** | 多次截图/XML 显示状态行位于 Tab 下方、网格上方（`B1_duplicate_status`、`B2_skip_status`、`B2_invalid_status`、`B2_batch20_result`、`B2_batch64_result`），未被 Sheet 遮挡 |
| B3 导入忙态可见、删除按钮禁用 | **PASS（部分交互未捕获）** | `B3_busy_progress.png`：25.83MB 大图导入过程中 Tab 下出现进度条、右上「+」置灰；`B3_busy_dump.xml` 为导入完成后状态。忙态约 <1s，未能实际点按删除按钮；源码 `_busy=true` 时传入 `onRemove=null`（`cover_album_manage_screen.dart:575-585`），删除入口禁用为代码确定行为 |

### C 默认封面渲染

| 项 | 结果 | 证据 |
|---|---|---|
| C1 选择相册为默认封面 | **PASS** | `C1_set_default.png`、`C1_set_default_and_shot.xml`：Sheet 内「当前使用」+「已将「QA-Album-A2」设为默认封面」 |
| C1 书架默认封面使用相册图（日间） | **PASS** | `C1_shelf_album_day.png`：6 本书分别取 L3/L1/L3/L2/L4/L2（不同书可不同，允许碰撞），书名/作者文字叠层正常 |
| C1 详情页使用相册图 | **PASS** | `C1_book_info.png`：《星海拾遗》详情封面为 L3 相册图 + 文字叠层 |
| C1 重启后同一本书图片稳定 | **PASS** | `C1_shelf_after_restart.png` 与重启前映射完全一致（L3/L1/L3/L2/L4/L2） |
| C2 夜间无夜间图时回落 | **PASS（记录实际）** | `C2_night_no_nightimg.png`：夜间模式下相册夜间列表为空，回落**应用内置封面 + 夜间暗色叠层**（不是日间相册图） |
| C2 夜间使用夜间图 | **PASS** | 导入 D3 后 `C2_shelf_night_album.png`：6 本书夜间封面均为 D3 |
| C3 删除当前夜间图片→回落内置 | **PASS** | `C3_night_deleted_empty.png/.xml`（夜间列表变空）→ `C3_night_fallback_shelf.png`：夜间封面回落内置暗色封面 + 文字，不崩溃 |
| C3 删除默认相册→回落内置 + 文字 | **PASS** | `C3_delete_album_confirm.png` 确认删除→`C3_album_deleted.xml` 空态；设置行 `C3_settings_row_builtin.xml` 变回「应用内置封面」；夜间 `C3_dark_builtin_after_album_delete.png`、日间 `C3_light_builtin_shelf2.png` 均为内置封面 + 书名文字 |
| C3 useDefaultCover 行为不变 | **PASS（功能开关）/ 渲染差异未构造** | 开关在 `E2_use_default_on.xml` / `E2_use_default_off.xml` 中 `checked=true→false` 正常切换并持久化；测试书无网络封面，无法复验「有网络封面仍显示默认封面」的渲染差异（见 BLOCKED-1） |

### D 迁移/持久化

| 项 | 结果 | 证据 |
|---|---|---|
| D1 旧 defaultCover/defaultCoverDark 路径迁移 | **PASS** | debug 播种 `/data/data/.../files/legacy_day.png`、`legacy_night.png` 与 `flutter.defaultCover/defaultCoverDark` 路径 → 启动日志 `D1_migration_logcat.txt`：「[CoverAlbumStore] 旧封面路径已迁移: 日间 1、夜间 1」；`D1_albums_after.json`：生成 `default-cover` 相册（日 1 / 夜 1）；`D1_prefs_after.xml`：`cover_album_migrated=true`、`defaultCover=default-cover`、`defaultCoverDark` 清空；`D1_settings_row_migrated.png`（默认封面 · 日间 1 · 夜间 1）、`D1_manage_migrated.png`（当前使用） |
| D2 默认封面选择/相册列表重启保持 | **PASS** | `D2_shelf_after_restart.png`（重启后仍用 QA-Album-C 的 25.83MB 大图/ L1）；`D2_settings_row_persist.xml`（QA-Album-C · 日间 2 · 夜间 0）；`D2_manage_persist.png`（列表存在且「当前使用」） |
| D2 备份恢复后选择回落/清理失效 ID | **PASS** | 备份 JSON `D2_backup_20261109.json` 的 `appPrefs` 不含 `defaultCover/defaultCoverDark`（设备级忽略）；删除相册 E 后设置行回落 `应用内置封面`（`D2_settings_builtin_after_e.xml`）；恢复该备份后 `D2_after_restore_cover_settings.png` 仍为应用内置封面、`D2_after_restore_manage.xml` 相册列表为空，不崩溃。另以 debug 播种失效 ID `missing-album-xyz`，启动后 `D2_stale_id_cleaned.xml` 显示「应用内置封面」，`D2_prefs_after_stale_cleanup.xml` 中 `defaultCover` 被清空 |

### E 并发/性能/回归

| 项 | 结果 | 证据 |
|---|---|---|
| E1 导入大图不 OOM/不卡死 | **PASS** | 25.83MB PNG 单张导入成功（`B1_large_imported.png/.xml`「已导入 1 张」）；PSS `pss_before.txt` 145,597KB → 导入中 `pss_after.txt` 179,825KB（+34MB，逐张读取）→ 2s 后 `pss_after2.txt` 131,399KB，无 OOM/无 ANR |
| E1 导入中关闭 Sheet 再删除相册不崩 | **PASS** | 2×25.83MB 导入后立即退出 Sheet（`E1_after_close_sheet.xml` 回到封面设置）并在第二次导入仍可能进行时删除相册；删除后 `E1_after_delete.png/.xml` 空态，`logcat_e1_race.txt`：FATAL 0 / ANR 0 / E flutter 0 / overflow 0 |
| E2 封面规则弹窗回归 | **PASS** | `E2_cover_rule_dialog.png/.xml`：启用开关、规则 JS、按书名测试、删除/取消/确定均存在 |
| E2 限制比例/仅 WiFi/阴影/描边/默认字体色回归 | **PASS** | `E2_cover_settings_baseline.xml`、`E2_use_default_on/off.xml`、`E2_wifi_on.xml`、`E2_ratio_off.xml`、`E2_shadow_stroke_toggled.xml`：`checked` 值按点击正确翻转；`E2_settings_restored` 后恢复默认组合（WiFi=false、默认封面=false、阴影=false、描边=true、默认色=true、限制比例=true） |
| E2 书籍详情/换封面回归 | **PASS** | `E2_book_info.png/.xml`：详情封面、换源、目录、阅读记录正常；点击封面进入 `E2_change_cover.png/.xml`「更换封面」（本地入口、候选区、使用按钮禁用态正常） |
| E2 搜索/发现回归 | **PASS** | `E2_search_page.png/.xml`：搜索页正常；`E2_discover_page3.png/.xml`：发现页正常（当前无发现源） |
| E2 FATAL/ANR/E flutter/overflow=0（release） | **PASS** | `logcat_e2_full.txt` 29,988 行：FATAL EXCEPTION 0、ANR in 0、` E flutter` 0、overflow 0；`logcat_e1_race.txt`、`logcat_final_startup.txt`、`logcat_final_startup2.txt` 同样为 0。crash buffer 仅见 `uiautomator`（uid 2000）Shutdown thread SIGSEGV，属 ROM/工具噪声，非应用崩溃（`logcat_crash_buffer.txt`） |

### F 清理与设备终态

| 项 | 结果 | 证据 |
|---|---|---|
| F1 删除测试相册/图片/书 | **PASS** | 相册全部删除；书架空态 `F1_final_shelf_clean.png/.xml`；`/sdcard/Download/qa6b2_*` 全部删除（`env_final.txt`：qa6b2 dirs none）；测试备份 `legado_backup_1794168049610.json` 已删除 |
| F1 默认封面=应用内置封面 | **PASS** | `F1_final_cover_settings.png/.xml`：默认封面行副题「应用内置封面」；全部开关为默认（WiFi=false、默认封面=false、阴影=false、描边=true、默认色=true、限制比例=true） |
| F1 设备参数复位 | **PASS** | `env_final.txt`：1080x1920 / 480dpi、font_scale 1.0、user_rotation 0、accelerometer_rotation 0（竖屏） |
| F1 终态 | **PASS** | release 2.0.467（468）安装并启动，`pm clear` 后空书架、无测试相册/图片 |

---

## 三、问题清单

### P1（阻断）
无。

### P2（本批需修复）

**P2-1 debug 构建打开相册图片管理 Sheet 触发 TabBar 断言，红色错误页 + 超大 Overflow**

- 复现步骤：
  1. 安装 debug 变体（本报告 debug SHA256 `eb7463b…`）；
  2. 设置→封面设置→默认封面→管理相册→新建/点开任一相册；
  3. 相册图片管理 Sheet 弹出后，Tab 内容区渲染为红色错误页。
- 期望行为：Sheet 正常显示日间/夜间 Tab 与图片网格。
- 实际行为：Flutter 错误页显示 `TabAlignment.start is only valid for scrollable tab bars.`，底部 `BOTTOM OVERFLOWED BY 99586 PIXELS`；logcat 记录 `[AppLog] [布局告警] A RenderFlex overflowed by 99553 pixels on the bottom.`（`logcat_debug_album_editor_error.txt:2566`）。关闭后重新打开可稳定复现（`P2_debug_album_editor_tabbar.png`、`P2_debug_album_editor_reopen.png`）。
- 定位线索：全局主题 `lib/src/theme/app_theme.dart:461` 设置 `tabBarTheme.tabAlignment = TabAlignment.start`（仅 scrollable TabBar 合法）；`lib/src/screens/cover_album_manage_screen.dart:544-550` 的 `TabBar` 未覆盖 `tabAlignment`/未设置 `isScrollable: true`。仓库内已有同类修正先例：`app_log_screen.dart:127`、`toc_screen.dart:1070`、`source_login_screen.dart:169` 显式设置 `tabAlignment: TabAlignment.fill`。
- 影响范围：debug 构建（含开发/自动化调试、`validate-runtime` 等）相册编辑 Sheet 不可用；release 因断言关闭不显示错误页，日/夜 Tab 与导入删除功能实测正常，但存在同一布局约束风险，建议按上列先例修复并回归。
- 证据：`P2_debug_album_editor_tabbar.png`、`P2_debug_album_editor_reopen.png`、`logcat_debug_album_editor_error.txt`。

### P3（记录/待产品确认）

- **P3-1 单图删除无二次确认**：任务 B1 写作「单图删除（确认）」，实测点缩略图右上角 X 立即删除，无确认弹窗（`B1_night_after_delete.png` 前后对比）。相册整体删除有二次确认（A2 PASS），单图删除没有；参考版源码不在本仓库，未裁决是否为预期，建议产品/参考版对照后决定是否补确认。
- **P3-2 删除图片后导入状态行残留**：`B1_night_after_delete.xml` 中删除图片后仍显示上一次导入的「已导入 3 张」，直到下一次导入/重建才刷新；不误导关键操作但文案已过期，建议删除成功后清空或更新状态行。
- **P3-3 本地 TXT 正文「作者：」未解析**：6 本测试书作者均落为「未知作者」（`C1_book_info.png` 等）。属既有本地导入元数据解析行为，非 6b-2 改动；本批 seed 以书名为先，不影响相册取图验证。

---

## 四、BLOCKED / 未闭环

| 编号 | 项 | 原因 | 影响 |
|---|---|---|---|
| BLOCKED-1 | E2「总是使用默认封面」的实际渲染差异（有网络封面书仍显示默认封面） | 测试书均为本地 TXT，无网络封面；无可用书源/网络封面服务（本批不重建网络书数据） | 仅验证了开关切换与持久化；渲染分支未复验，不声称通过 |
| BLOCKED-2 | C1「列表布局」默认封面 | 全程使用书架网格布局 + 详情页；未切换到书架列表样式构造相册封面样本 | 列表与网格共用 `BookCover` 组件，但本批未在列表布局下截图取证；不声称通过 |

---

## 五、FATAL / 崩溃统计

| 日志窗口 | FATAL EXCEPTION | ANR in | ` E flutter` | overflow |
|---|---|---|---|---|
| `logcat_e2_full.txt`（release 回归段，29,988 行） | 0 | 0 | 0 | 0 |
| `logcat_e1_race.txt`（release 并发段） | 0 | 0 | 0 | 0 |
| `logcat_final_startup.txt` / `logcat_final_startup2.txt`（release 启动段） | 0 | 0 | 0 | 0 |
| debug 相册编辑段（P2-1） | 0 | 0 | 0 | `RenderFlex overflowed by 99553 pixels`（debug 断言错误页已截屏） |

crash buffer：仅 `uiautomator`（uid 2000）Shutdown thread SIGSEGV（`logcat_crash_buffer.txt`），为 ROM/工具噪声，与本应用无关。

---

## 六、设备终态

- 应用：`io.legado.flutter_legado` 2.0.467（versionCode 468），release，已启动并停留书架页。
- 数据：`pm clear` 后空书架（`F1_final_shelf_clean.png/.xml`）；无测试相册、无测试书、无测试图片；默认封面=应用内置封面（`F1_final_cover_settings.png/.xml`）。
- 显示：1080x1920 / 480dpi；font_scale 1.0；竖屏（rotation 0，accelerometer 关闭）。
- 存储：`/sdcard/Download/qa6b2_images|qa6b2_books|qa6b2_batch20|qa6b2_batch64` 均已删除（`env_final.txt`）。
- 安装包：设备保留 release；debug 已于收尾前覆盖回 release。

---

## 七、证据索引（`docs/materials_1109a/`）

- 构建/包：`apk_sha256.txt`、`build_release.log`、`build_debug.log`
- 环境：`env.txt`、`env_final.txt`、`logcat_final_startup*.txt`
- A：`A1_*`、`A2_*`、`A2_dir_cleanup_runas.txt`
- B：`B1_*`、`B2_*`、`B3_*`、`B3_busy_progress.png`、`pss_before.txt`、`pss_after.txt`、`pss_after2.txt`
- C：`C1_*`、`C2_*`、`C3_*`、`C4_shelf_after_files_removed.png`、`album_c_files_before.txt`、`album_c_files_after.txt`、`album_index_before_c4.json`
- D：`D1_*`、`D2_*`、`album_index_before_c4.json`、`D2_backup_20261109.json`
- E：`E1_*`、`E2_*`、`logcat_e2_full.txt`、`logcat_e1_race.txt`、`logcat_crash_buffer.txt`
- F：`F1_final_shelf_clean.png/.xml`、`F1_final_cover_settings.png/.xml`、`env_final.txt`
- P2：`P2_debug_album_editor_tabbar.png`、`P2_debug_album_editor_reopen.png`、`logcat_debug_album_editor_error.txt`

---

- 编写：QA 子代理 ｜ 2026-11-09

---

## 八、P2 回修复验（2026-11-09）

- 代码基线：`2b20ae7615`（master，HEAD）；修复提交 `cd43ee2210`（`fix(ui): 修正封面相册 Sheet TabBar 对齐与删图确认`）+ 测试提交 `2b20ae7615`（`test(ui): 覆盖全局 tabAlignment 下相册 Sheet 与删图确认`）
- 版本：仍为 2.0.467+468（versionCode 468）
- 复验 APK：
  - debug：320,649,315 B，SHA256 `8bbb7b65df0e6f0c3d4792463db89ad26b4b5acf1c208849478f9e27f5f1edef`（`apk_sha256_reverify.txt`；`build_debug2.log`，EXIT=0，assembleDebug 12.9s）
  - release：208,533,332 B，SHA256 `9b5b7581e7a1737c90c5c587bd8ce9d2babd34434f96252ace2fc050d90fdc93`（`build_release2.log`，EXIT=0，assembleRelease 56.2s）
- 证据目录：`docs/materials_1109b/`（本次复验新增文件均以 `RV_` 前缀）

### 8.1 debug 相册图片管理 Sheet（原 P2-1）

| 项 | 结果 | 证据 |
|---|---|---|
| Sheet 正常渲染，无 `TabAlignment.start` 红屏 | **PASS** | `RV_debug_sheet_open.png/.xml`：Sheet 头部、日间/夜间 Tab、空态「暂无图片」正常；`logcat_debug_reverify.txt` / `logcat_debug_reverify2.txt` 中 `TabAlignment` 0 次 |
| 无 RenderFlex overflow | **PASS** | `logcat_debug_reverify*.txt`：`overflow` 0 次、FATAL 0、ANR 0、` E flutter` 0 |
| 日/夜 Tab 正常切换 | **PASS** | `RV_debug_tab_night.png`、`RV_debug_tab_day.xml`：点击夜间/日间 Tab 状态切换正常，无断言 |
| 导入后网格在 debug 正常渲染 | **PASS** | `RV_debug_sheet_imported.png/.xml`：导入 2 张后 L2/L3 网格显示，状态「已导入 2 张」 |

### 8.2 release Sheet、单图删除确认与状态行

| 项 | 结果 | 证据 |
|---|---|---|
| release 打开同一 Sheet 正常 | **PASS** | `RV_release_sheet_open.png/.xml`：日间/夜间 Tab 等宽、L2/L3 网格正常 |
| 单图删除弹二次确认 | **PASS** | `RV_release_delete_confirm2.png/.xml`：标题「删除图片」、正文「确定从相册中删除这张图片吗？」、取消/删除 |
| 取消删除保留图片 | **PASS** | `RV_release_delete_cancelled.png`：取消后 L2/L3 两张仍在，计数不变 |
| 确认删除 + 状态行「已删除 1 张图片」 | **PASS** | `RV_release_deleted_status.png/.xml`：仅剩 L3，状态行「已删除 1 张图片」 |
| 计数更新 | **PASS** | 关闭 Sheet 后管理卡 `RV_release_count_after_delete.xml`：「QA7B2-Reverify 日间 2 · 夜间 0」（删除 1 张后重新导入 1 张 L4，原 2 张 → 删 1 → 导 1 = 2） |
| 导入失败状态行替换旧文案 | **PASS** | `RV_release_status_invalid.png/.xml`：「1 张跳过：invalid_image.png：不是可解码的图片」，未残留「已删除 1 张图片」 |
| 导入成功状态行替换 | **PASS** | `RV_release_status_import_ok.png/.xml`：「已导入 1 张」 |
| 重复导入状态行替换 | **PASS** | `RV_release_status_duplicate.png/.xml`：「1 张图片已存在，未重复导入」 |

### 8.3 回归

| 项 | 结果 | 证据 |
|---|---|---|
| 默认封面选择 | **PASS** | `RV_final_album_default.png/.xml`：Sheet 内「当前使用」+「已将「QA7B2-Final」设为默认封面」；`RV_reg_settings_row.xml`：「QA7B2-Final · 日间 2 · 夜间 0」 |
| 相册新建/重命名/删除 | **PASS** | `RV_reg_create.xml`（新建 QA-Temp）、`RV_reg_rename.xml`（重命名为 QA-Temp2）、`RV_reg_delete_confirm.xml`（删除二次确认）、`RV_reg_deleted.xml`（删除完成）；过程中误删当时默认相册 `QA7BQA-Temp2` 后，设置行回落「应用内置封面」（`RV_cleanup_settings_builtin.xml`），符合删除默认相册回落预期 |
| 书架默认封面渲染 | **PASS** | `RV_reg_shelf_album.png`：3 本书使用相册图 L3 + 书名文字 |
| 重启后选择与渲染保持 | **PASS** | `RV_reg_shelf_after_restart.png`：重启后 3 本书仍为 L3；`RV_reg_settings_after_restart.xml`：默认封面仍为 QA7B2-Final · 日间 2 · 夜间 0 |
| FATAL/ANR/E flutter/overflow | **PASS** | `logcat_release_reverify.txt`、`logcat_final_reverify.txt`：FATAL 0、ANR 0、` E flutter` 0、overflow 0、TabAlignment 0 |

### 8.4 清理与设备终态

| 项 | 结果 | 证据 |
|---|---|---|
| 删除测试书/相册/图片 | **PASS** | `RV_cleanup_shelf_empty.png`（3 本书删除后空书架）、`RV_cleanup_album_empty.xml`（相册空态）；`/sdcard/Download/qa6b2_images|qa6b2_books` 已删除（`env_final_reverify.txt`：qa6b2 dirs none） |
| 恢复内置封面与默认值 | **PASS** | `RV_final_cover_settings.png/.xml`：默认封面「应用内置封面」；`pm clear` 后开关恢复默认 |
| 设备参数 | **PASS** | `env_final_reverify.txt`：1080x1920 / 480dpi、font_scale 1.0、竖屏（rotation 0 / accelerometer 0） |
| 最终安装包 | **PASS** | release 2.0.467（versionCode 468），已启动停留空书架（`RV_final_shelf.png/.xml`） |

### 8.5 复验结论

- **P2-1 关闭**：debug Sheet 红屏与本批 RenderFlex overflow 不再出现；日/夜 Tab 与网格渲染正常。
- **P3-1 关闭**：单图删除已有二次确认，取消保留、确认删除并刷新状态行。
- **P3-2 关闭**：删除后状态行为「已删除 1 张图片」，导入成功/失败/重复均替换旧文案，不再残留。
- 未发现新增 P1/P2。原 BLOCKED-1（网络封面 useDefaultCover 渲染差异）与 BLOCKED-2（书架列表布局相册封面）未在本次定向复验范围内，仍保留未闭环。
- 观察项（非缺陷）：修复后日/夜 Tab 由 `TabAlignment.start` 左对齐改为 `TabAlignment.fill` 等宽铺满（与 `app_log_screen.dart`/`toc_screen.dart` 先例一致）；本次未做参考版截图像素比对，若产品期望左对齐窄 Tab，需另行裁决。
- **批6b-2 总体结论更新为 PASS。**

### 8.6 复验证据索引（`docs/materials_1109b/`）

- 构建/包：`apk_sha256_reverify.txt`、`build_release2.log`、`build_debug2.log`
- debug：`RV_debug_sheet_open.png/.xml`、`RV_debug_sheet_imported.png/.xml`、`RV_debug_tab_night.png`、`RV_debug_tab_day.xml`、`logcat_debug_reverify.txt`、`logcat_debug_reverify2.txt`
- release：`RV_release_sheet_open.png/.xml`、`RV_release_delete_confirm2.png/.xml`、`RV_release_delete_cancelled.png`、`RV_release_deleted_status.png/.xml`、`RV_release_status_invalid.png/.xml`、`RV_release_status_import_ok.png/.xml`、`RV_release_status_duplicate.png/.xml`
- 回归：`RV_reg_*`、`RV_final_album_default.png/.xml`、`logcat_release_reverify.txt`
- 清理/终态：`RV_cleanup_*`、`RV_final_shelf.png/.xml`、`RV_final_cover_settings.png/.xml`、`env_final_reverify.txt`、`logcat_final_reverify.txt`

---

- 复验编写：QA 子代理 ｜ 2026-11-09
