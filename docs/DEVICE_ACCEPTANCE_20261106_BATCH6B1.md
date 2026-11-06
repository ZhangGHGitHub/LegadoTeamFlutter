# 批6b-1 设备验收报告（封面设置 + 封面渲染）

- 日期：2026-11-06
- 代码基线：`4b757d6a24`（`chore: 批6b-1 收尾（2.0.464+465 双日志与计划登记）`）
- 版本：2.0.464+465（versionCode 465）
- 验收范围：A 入口与页面 / B 默认封面文字 / C 网络封面与仅 WiFi / D 详情页 / E 回归与稳定性 / F 清理
- 结论：**FAIL**——批 6b-1 自身功能项（A/B/C/D）通过；回归项发现 **2 项 P2**（本地换封面不显示、本地选图 FATAL），另有 2 个子项因设备无蜂窝网络 **BLOCKED**
- 验收人：QA 子代理
- 证据目录：`docs/materials_1106c/`（截图、语义树 XML、prefs、备份 JSON、logcat 过滤稿、构建日志、HTTP 服务日志）

---

## 一、环境与构建

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例，guest 直连 `192.168.100.62:5555`（`MuMuManager info` index 1，`is_android_started=true`） |
| 机型/系统 | SM_G9900 / Android 15（API 35） |
| 显示 | 1080x1920 / 480dpi（`wm size` / `wm density`） |
| 网络 | guest `wlan0=192.168.100.62`；`dumpsys connectivity`：`Transports: WIFI`、SSID `Cisco_867e86440dc3`；无蜂窝网络接口 |
| 网络封面服务 | PC `192.168.100.52:18080`（`python -m http.server`），提供 `cover.jpg`（600x900）、`tall.jpg`（600x1800）、`square.jpg`（600x600） |
| 安装包（验收用） | `app-release.apk` 208,039,916 B，2.0.464（465），release（无 DEBUGGABLE） |
| release SHA256 | `31d6b4cb94e7c1ab8fe8e6c46856d318596b7863153030cdbd51d926e3338c26` |
| debug SHA256（仅播种/取证） | `b24a6bb4edf4264eea3fa4962b3ff31516f81c96798dda072cea8f2a425aef77`（320,523,959 B） |
| 构建命令 | `cd flutter_legado && flutter build apk --release`（EXIT=0，Gradle assembleRelease 100.1s）；`flutter build apk --debug`（EXIT=0，39.7s） |
| 构建日志 | `docs/materials_1106c/build_release.log`、`build_debug.log`、`apk_sha256.txt` |
| Rust | 无 Rust 改动，未重建 `.so`（沿用 `android/app/src/main/jniLibs` 现有产物） |

说明：

1. 测试书通过 **debug 变体** 导入/写入 DB 与读取 prefs（`run-as` 仅 debug 可用），随后覆盖安装 **release** 执行验收；release 与 debug 同签名（release 使用 debug keystore），`install -r` 保留数据。除特别注明外，所有截图均来自 release。
2. 测试书 6 本（UTF-8 TXT，经「添加本地」多选导入）：
   - `三体：黑暗森林中的史诗长卷与群星彼岸的最后决战` / 刘慈欣 / 无封面（超长中文名）
   - `白夜行` / 东野圭吾 / `coverUrl=http://192.168.100.52:18080/cover.jpg`（600x900 网络封面）
   - `活` / 余华 / 无封面（单字书名）
   - `无名之书` / 空作者 / 无封面
   - `Dune` / Frank Herbert / 无封面（英文名，强制横排）
   - `The Old Man and the Sea` / Ernest Hemingway / 无封面（英文名）
3. 为验证详情分组 chip，注入 1 个分组「测试组」并分配给《三体》，验收后删除。

---

## 二、逐项结果

### A 入口与页面

| 项 | 结果 | 证据 |
|---|---|---|
| A1 设置主页一级「封面设置」 | **PASS** | `A1_settings_home.png/.xml`：设置主页第 4 项「封面设置 / 默认封面、书名作者、描边与阴影」，点击进入独立页 |
| A1 外观页旧「封面设置」行已移除 | **PASS** | `A1_appearance.png`、`A1_appearance_2/3.xml`：外观页三段滚动内 `封面设置` 出现次数 0；仅保留详情页背景设置「网络封面背景设置 / 默认封面背景设置」 |
| A1 页面 18 项分组 | **PASS** | 逐项计数：基础组 8（仅 WiFi/封面规则/总是默认封面/默认封面/字体阴影/字体描边/默认字体色/限制比例）+ 信息方向 1 + 网络角标 1 + 白天 4 + 夜间 4 = 18；`A1_cover_settings*.png/.xml` |
| A1 封面规则入口在新页 | **PASS** | `A1_cover_rule_dialog.png/.xml`：点击「封面规则」弹出规则编辑/按书名测试/删除/确定对话框（默认规则内容可见） |
| A2 18 项存在与默认值 | **PASS** | 默认值实测：仅 WiFi=false、默认封面=false、阴影=false、描边=true、默认字体色=true、限制比例=true、方向=竖向、日夜书名/作者=true、正文/阴影色日间黑夜间白（`A1_cover_settings*.xml`、`F1_defaults_*.xml`） |
| A2 作者随书名禁用 | **PASS** | 日间关闭「显示书名」后「显示作者」`enabled=false`、夜间仍 true（`B3_name_off.xml`）；夜间关闭书名后夜间作者 `enabled=false`、日间不受影响（`B3_night_name_off.xml`） |
| A2 相册/网络角标灰置 | **PASS** | `默认封面` 与 `网络书籍角标设置` 语义节点 `enabled="false"`（`A1_cover_settings_3.xml`） |
| A2 取色器可用 | **PASS** | 4 个颜色行均打开 ContainerColorDialog（HEX + 调色盘 + 恢复默认）；实测选绿/蓝/青/黄并回写（`B3_color_dialog.png`、`B3_night_color_dialog.png`） |
| A2 重启保持 | **PASS** | 设置非默认组合后 force-stop/重启：阴影=true、描边=false、默认字体色=false、限制比例=true、日间 #FF4CAF50/#FF2196F3、夜间 #FF00BCD4/#FFFFEB3B、夜间书名=false 全部保持（`A2_after_restart_1/2/3.xml`、`prefs_before_cleanup.xml`） |

### B 默认封面文字

| 项 | 结果 | 证据 |
|---|---|---|
| B1 默认竖排：逐列、超 0.8h 换列、作者右列、不越界 | **PASS** | `10_shelf_with_authors.png`、`B1_crop_santi.png`：24 字书名分 5 列（每列 5/5/5/5/4 字），列宽 `fontSize*1.2`，超 0.8h 换列；作者「刘慈欣」在 `0.84w` 右列；所有字形在封面内 |
| B1 长书名/单字/空作者不崩 | **PASS** | 三体（24 字）、活（单字）、无名之书（空作者）全部正常渲染，无异常/无 FATAL（`10_shelf_with_authors.png`、`B1_crop_huo.png`） |
| B2 信息方向=横排 | **PASS** | `B2_shelf_horizontal.png`：中文书名/作者横排（最多 3 行、超长省略号），设置切换后**无需重启即时生效**；`B2_dropdown3.png`、`B2_after_select.xml` |
| B2 英文书名强制横排 | **PASS** | 竖排设置下 `Dune`、`The Old Man and the Sea` 仍横排（拉丁字母占比 >30%，阈值与参考版一致），`10_shelf_with_authors.png` |
| B3 日间显示书名/作者独立 | **PASS** | 关书名：封面无任何文字（作者联动不绘制）`B3_day_name_off.png`；开书名/关作者：仅书名 `B3_author_off.png`；`B3_author_off.xml` |
| B3 夜间显示书名/作者独立 | **PASS** | 夜间关书名：夜间无文字、日间保持 `B3_night_name_off_shelf.png`；开关状态 `B3_night_name_off.xml`（日间 true、夜间 false、夜间作者 enabled=false） |
| B3 自定义正文/阴影色 | **PASS** | 日间绿字蓝影 `B3_custom_colors.png`；夜间青字黄影 `B3_night_custom_colors.png`；日/夜互不影响，重启保持（`prefs_before_cleanup.xml`） |
| B3 描边开关可见差异 | **PASS** | `B3_stroke_compare.png`：描边开=白色粗边（近白像素 11,613），关=无白边（2,024），左右对比明显 |
| B3 阴影开关（4px）可见差异 | **PASS** | `B3_shadow_compare.png`：文字出现 4px 模糊投影；详情页封面外阴影像素亮度 250.84→243.32（下缘）/184.12→175.71（右缘）；关闭后恢复 |
| B3 默认色=主题 secondary | **PASS** | 默认色开：文字取主题 secondary（当前主题红）；关闭后取自定义色（绿/青），对比 `10_shelf_with_authors.png` vs `B3_custom_colors.png` |
| B4 总是使用默认封面开 | **PASS** | `B4_use_default_cover.png`：《白夜行》有网络封面仍显示默认封面+书名/作者（竖排） |
| B4 关闭恢复网络封面 | **PASS** | `C2_network_cover_cached.png`：关闭后网络封面恢复，且无新增下载（HTTP 计数不变） |

### C 网络封面与仅 WiFi

| 项 | 结果 | 证据 |
|---|---|---|
| C1 WiFi 下网络封面加载 | **PASS** | `10_shelf_with_authors.png`、`D_detail_baiyexing.png`：《白夜行》600x900 封面正常显示；HTTP 服务日志有 1 次应用 GET |
| C1 仅 WiFi 开关切换/重启保持 | **PASS** | 开启后 switch=true（`C1_onlywifi_on_settings.png`），force-stop/重启后仍 true（`C1_wifi_only_on.png`、`prefs_before_cleanup.xml`）；WiFi 下封面照常加载 |
| C1 蜂窝/非 WiFi 阻塞态 | **BLOCKED** | MuMu 仅有 `wlan0`（`dumpsys connectivity` 为 `Transports: WIFI`，无 Telephony/Cellular 数据网络）；关闭 WiFi 会同时切断唯一 adb 通道，无法安全构造。已记录判定链：原生 `NetworkStatusBridge.queryIsWifi` 用 `hasTransport(WIFI)`，异常 fail-open 返回 true；仓内 `NetworkStatusBridgeTest.kt` 覆盖 Wi-Fi/蜂窝纯函数判定 |
| C2 已加载后切默认/重建列表不重复下载 | **PASS** | HTTP 日志总 `GET /cover.jpg` 计数保持 3（1 次 PC curl + 1 次设备 nc 探活 + 1 次应用首次加载）；之后多次重启、默认封面开关切换、仅 WiFi 开关均无新增请求（`cache_evidence.txt`、`http_server.log`） |
| C2 仅 WiFi 下缓存命中仍显示 | **BLOCKED** | 需「仅 WiFi 开 + 非 WiFi 网络」才能进入 `_wifiBlocked` 分支，设备无法构造（同上）；WiFi 下缓存命中已由上一项覆盖 |

### D 详情页

| 项 | 结果 | 证据 |
|---|---|---|
| D1 封面阴影/描边跟随设置 | **PASS** | 默认无硬编码 elevation/边框（`D_detail_baiyexing.png`）；开阴影后详情封面外出现投影（`D1_detail_shadow_on.png`，像素亮度差见上）；描边为默认封面文字白边 |
| D1 useDefaultCover 详情背景退纯 surface | **PASS** | `D1_detail_use_default.png`：「总是默认封面」开时背景为纯 surface，无封面色板；关闭后带封面色板（`D2_detail_square_ratio_on.png` 绿、`D2_ratio_off_tall.png` 紫） |
| D1 仅 WiFi 蜂窝详情背景 | **BLOCKED** | 同 C1，无蜂窝网络；代码路径已核对（`book_info_screen.dart` `_extractCoverSeed` / `_wifiGateGen`） |
| D2 详情分组 chip | **PASS** | `D2_detail_group_chip.png/.xml`：分配「测试组」后详情显示 chip「测试组」 |
| D2 封面/比例正常 | **PASS** | 详情封面 110x160dp、圆角 3；比例开/关实测高度 484px vs 754px（`D2_ratio_on_tall.png` / `D2_ratio_off_tall.png`、`ratio_measurements.txt`） |
| D2 Hero 过渡 | **PASS（受限）** | 书架↔详情多次长按/返回，Hero tag（`book-cover:<bookUrl>`）正常完成过渡、无异常/无 FATAL；screencap 延迟无法抓取飞行中间帧（`D_hero_transition.png` 为完成帧），未做逐帧断言 |

### E 回归与稳定性

| 项 | 结果 | 证据 |
|---|---|---|
| E1 书架网格/列表 | **PASS** | 网格 3 列（`10_shelf_with_authors.png`）、列表（`E1_shelf_list.png`）；封面/书名/作者/进度正常；布局设置面板切换并恢复网格（`E1_layout_panel` 系列、`E1_grid_restored.png`） |
| E1 批量 | **PASS** | 进入选择模式→已选 6 本→删除（`F1_batch_all.png`、`F1_delete_confirm.xml`） |
| E1 搜索 | **PASS（受限）** | 搜索页正常打开（`E1_search_page.png`）；本机无书源，未执行真实搜索结果渲染 |
| E1 发现 | **PASS（受限）** | 发现页正常打开，显示「当前没有发现源！」（`E1_discover.png`）；无源可用，未验证发现列表封面 |
| E1 书签/阅读记录 | **PASS** | 书签页（空态，`E1_bookmarks.png`）；阅读记录页显示《白夜行》10 秒（`E1_read_record.png`） |
| E1 换封面 | **FAIL（P2-1）** | 更换封面页可打开、本地选图预览正常（`E1_change_cover.png`、`E1_after_pick_square.png`）；确认后详情/书架仍显示默认封面（`D2_detail_square_ratio_on.png`、`E1_shelf_local_cover_huo.png`、`E1_local_cover_after_restart.png`）；DB `customCoverUrl` 已写入本地路径 |
| E1 编辑信息封面文字 | **PASS** | `E1_edit_book_info.png`：预览封面绘制竖排书名「无名之书」，空作者不绘制 |
| E1 限制比例开/关 | **PASS** | 见 D2 实测 484px vs 754px |
| E1 横竖屏/字号 1.3/1.6/暗色 | **PASS** | 横屏书架/封面设置/详情（`E1_landscape_shelf.png`、`E1_landscape_cover_settings.png`、`E1_landscape_detail.png`）；字号 1.6（`E1_font16_shelf.png`、`E1_font16_detail.png`）、1.3（`E1_font13_shelf.png`）；暗色（`B3_night_*`）；`overflowed by` 计数 0 |
| E2 备份含封面键 | **PASS** | 本地备份 `legado_backup_1793922760687.json`（6,489 B）：`appPrefs` 含 14 个封面键（loadCoverOnlyWifi/useDefaultCover/coverShowShadow/coverShowStroke/coverDefaultColor/coverRestrictRatio/coverInfoOrientation/coverTextColor(N)/coverShadowColor(N)/coverShowName(N)/coverShowAuthor）；备份路径 `/storage/emulated/0/Download/legado_backup` |
| E2 忽略封面配置恢复不覆盖 | **PASS** | 备份后把阴影改为 false → 勾选「封面规则」忽略 → 恢复后阴影仍 false（`E2_restored_ignore2.png`、`E2_ignore_checked.xml`） |
| E2 恢复后同会话生效 | **PASS** | 取消忽略再恢复同一备份：未重启即阴影 true（`E2_restore_noignore_samesession.png`） |
| E3 FATAL/ANR/E.flutter/overflow | **FAIL（P2-2）** | 全程 **FATAL=1**、ANR=0、E/flutter=0、RenderFlex overflow=0（`logcat_relevant.txt`）；FATAL 为本地选图崩溃，详见 P2-2 |

### F 清理与设备终态

| 项 | 结果 | 证据 |
|---|---|---|
| F1 恢复默认 | **PASS** | 仅 WiFi=false、默认封面=false、阴影=false、描边=true、默认字体色=true、比例=true、方向=竖向、日夜书名/作者=true、四色恢复默认（#FF000000 / #FFFFFFFF）；`F1_final_cover_settings.png`、`F1_defaults_*.xml`、`prefs_final.xml` |
| F1 删除测试书 | **PASS** | 批量删除 6 本；DB `books`=0、`book_groups`=0；空书架 `F1_final_device.png`、`F1_shelf_empty.png` |
| F1 环境终态 | **PASS** | `font_scale=1.0`、`user_rotation=0`（竖屏）、1080x1920/480dpi；release 2.0.464（465）已安装；测试文件 `/sdcard/Download/qa6b1`、`square.jpg`、`tall.jpg`、本次备份 JSON、`/sdcard/ui.xml` 已删除；PC HTTP 服务已停止；`logcat -c` 已清空 |

---

## 三、缺陷与观察

### P2-1（功能缺陷，E1）：本地换封面不显示

- 复现步骤：
  1. 书架长按书籍 → 详情页 → 点击封面 → 「更换封面」；
  2. 右上「本地」→ 选一张已索引图片 → 预览显示所选图片（「已选择新封面」）；
  3. 点「使用该封面」返回详情。
- 期望：详情/书架显示所选图片。
- 实际：详情与书架仍显示默认封面+书名文字；force-stop/重启后仍不显示。
- 根因定位：
  - DB 已正确写入 `customCoverUrl = /data/user/0/io.legado.flutter_legado/cache/file_picker/.../JPEG_20261106_074045_535677486200002887.jpg`（debug `run-as sqlite3` 实测）；
  - `lib/src/widgets/book_cover.dart` 的 `_CoverImage` 对非空 coverUrl 只走 `CachedNetworkImage`（`book_cover.dart:642-665`），没有本地文件分支；`lib/src/screens/book_info_screen_builders.part.dart:932` 直接把 `customCoverUrl` 传入 `BookCover`；
  - `git show c6889c816a`（批39 基线）同样没有本地文件分支 → **非本批引入的历史缺口**；
  - 参考版 `CoilBookCover.kt` 用 Coil `AsyncImage(data = finalPath)` 可直接加载文件路径，参考版会正常显示。
- 附加风险：`customCoverUrl` 指向 file_picker **cache** 目录，系统清缓存后路径失效。
- 影响：E1「换封面」验收项不通过；用户本地选封面无效（预置 6b-2 相册功能前，本地选图是主要入口之一）。

### P2-2（稳定性，E3）：本地选图触发 FATAL（file_picker 压缩空指针）

- 复现步骤：`adb push` 一张图片到 `/sdcard/Download`（**未触发 MediaStore 扫描**）→ 更换封面 → 本地 → 选择该图。
- 实际：应用进程崩溃（退回 Launcher），`logcat`：
  ```
  11-06 07:39:17.709 E/AndroidRuntime(57370): FATAL EXCEPTION: Thread-7
  Process: io.legado.flutter_legado, PID: 57370
  java.lang.NullPointerException: Attempt to invoke virtual method 'boolean
  android.graphics.Bitmap.compress(android.graphics.Bitmap$CompressFormat, int,
  java.io.OutputStream)' on a null object reference
      at t3.z0.a(SourceFile:56)
      at P.e.run(SourceFile:389)
  ```
- 复现条件收窄：`am broadcast MEDIA_SCANNER_SCAN_FILE` 让图片进入 MediaStore 后，同一入口选择同图成功（`E1_picker_after_scan.png`、`E1_after_pick_square.png`），无新 FATAL。
- 根因定位（第三方插件）：
  - `file_picker 8.3.7` 默认 `allowCompression=true`、`compressionQuality=30`（`lib/src/file_picker.dart:98-99`）；
  - 本地选图走 `FilePickerDelegate.java:141` → `FileUtils.compressImage`；
  - `FileUtils.java:102` 在 `BitmapFactory.decodeStream(imageStream)` 返回 null 时未判空直接 `originalBitmap.compress(...)` → NPE。
  - 我方 `change_cover_screen.dart:75-80` 未显式关闭压缩，默认进入该路径。
- 影响：E3「FATAL=0」不通过；属第三方插件缺陷 + 边缘文件状态（未索引/不可解码图片），非批 6b-1 代码引入。建议升级 file_picker 或本地选图传 `allowCompression:false`/自建解码并判空。

### P3（观察/优化建议）

1. **书架/列表封面外阴影被裁剪**：`BookGridItem`/`BookListItem` 在 `BookCover` 外再包一层 `ClipRRect`，导致 `showShadow` 产生的 4dp 封面外阴影在书架网格/列表不可见（仅文字阴影可见）；详情页无外层裁剪，阴影正常（已实测像素差）。参考版 `Modifier.shadow(4.dp, shape)` 在列表同样可见。建议外侧裁剪只包图片内容，或把阴影画在裁剪层之外。
2. **超长书名与作者列重叠**：24 字书名排到第 5 列（列中心约 `0.16w+4*1.2*fontSize`），右列作者从 `0.84w` 起，二者在 1080 宽封面下有约 6px 视觉重叠（`B1_crop_santi.png` 中「刘/慈/欣」压住「后/决/战」）。该几何与参考版 `CoverTextOverlay` 完全同式（`x=width*0.16f`、步进 `textSize*1.2f`、作者 `x=width*0.84f`），属参考行为，非本批偏离；建议后续与参考版一并评估是否限制列数。
3. **备份仅含「改动过」的封面键**：本次备份 `appPrefs` 有 14 个封面键；从未改动的默认键（如 `coverShowAuthorN`、`defaultCover`、`defaultCoverDark`、`explore_filter_state`）因懒持久化未写入。跨设备恢复时依赖两端默认值一致；如需完整快照可考虑写入全部 18 键。
4. **换封面网络候选未验证**：本机无书源，更换封面页显示「暂无候选封面」，网络候选选择链路 BLOCKED（网络封面渲染本身已通过注入 coverUrl 验证）。

---

## 四、BLOCKED 清单

| 项 | 原因 |
|---|---|
| C1 蜂窝/非 WiFi 阻塞态 UI | MuMu 仅有 `wlan0`（Transports: WIFI），无蜂窝数据网络；关闭 WiFi 会切断唯一 adb 控制通道，无法安全构造后再恢复。已记录 WiFi 判定实现与 fail-open 策略 |
| C2 仅 WiFi + 非 WiFi 缓存命中 | 同上，`_wifiBlocked` 分支不可达 |
| D1 仅 WiFi 蜂窝详情背景 | 同上 |
| E1 搜索结果/发现列表封面渲染 | 设备未安装可用书源，搜索/发现为空态 |
| E1 换封面网络候选 | 无书源候选，仅验证本地选图路径 |

---

## 五、FATAL / 稳定性统计

| 指标 | 次数 | 说明 |
|---|---|---|
| FATAL EXCEPTION | **1** | P2-2：file_picker 本地选图压缩 NPE（未索引图片），`logcat_relevant.txt` |
| ANR | 0 | — |
| E/flutter | 0 | — |
| RenderFlex overflow | 0 | 竖屏/横屏、字号 1.0/1.3/1.6、日/夜均无 overflow |

---

## 六、设备终态

- 应用：`io.legado.flutter_legado` 2.0.464（versionCode 465，release）已安装并启动在空书架
- 书架：空（`books=0`、`book_groups=0`；`F1_final_device.png`）
- 封面设置：全部默认（`prefs_final.xml`、`F1_final_cover_settings.png`）
- 忽略恢复项：全部 false（`prefs_final.xml`）；备份路径键已清除
- 系统：`font_scale=1.0`、竖屏（`user_rotation=0`）、1080x1920 / 480dpi
- 测试数据：6 本书、测试组、`/sdcard/Download/qa6b1`、`square.jpg`、`tall.jpg`、本次备份 JSON、`/sdcard/ui.xml` 均已删除
- 外部服务：PC `python -m http.server 18080` 已停止（`http_server.log` 已归档）
- 日志：验收后已 `logcat -c`
- 备注：应用私有 cache 下可能残留 file_picker 导入的临时 JPEG（`cache/file_picker/...`），属应用缓存，不影响书架/设置状态

---

## 七、结论

- 批 6b-1 交付的 **A 入口与 18 项设置、B 默认封面文字（竖/横、日夜、描边/阴影/颜色）、C 网络封面加载与缓存、D 详情页封面/背景/chip/比例** 均通过设备验证；重启持久化、备份键往返与「忽略封面配置」行为正确。
- 两项 P2 导致整体 **FAIL**：
  1. **P2-1 本地换封面不显示**（E1）——历史缺口，参考版可正常显示，需修 `BookCover` 本地文件分支；
  2. **P2-2 本地选图 FATAL**（E3）——file_picker 8.3.7 `compressImage` 空指针，需升级/规避压缩或加判空。
- 两项 P3 视觉/一致性观察（书架封面外阴影被裁剪、超长书名与作者列重叠）建议随 6b-2 或后续批次处理。
- 需在修复 P2-1/P2-2 后复测 E1 换封面与 E3 FATAL=0；蜂窝相关 3 个子项保持 BLOCKED，需真机/可切网环境补测。

---

编写：QA 子代理 ｜ 2026-11-06


---

## 九、P2 回修复验（2.0.465+466，主代理执行）

> 子代理配额未重置（19:20），本轮设备复验由主代理直接执行；仅验收，未改代码。

- 版本/APK：2.0.464+465（versionCode 465），当前 HEAD `5218191a28` + 版本收尾为 2.0.465+466；release 198.4MB，sha256 `656df12d31f2f961446389ad9b297440042874317e97018723a68ffe1cbce977`。
- **本地换封面（P2-1，PASS）**：SAF 选择刚 push 到 Download、未进入 MediaStore 的 `qa6b1b_cover.png` → 预览显示「已选择新封面」→「使用该封面」不崩溃；详情封面立即显示该图（`03_detail_local_cover.png`）；返回书架同会话显示（`04`）；force-stop 重启后书架仍显示（`05`）。
- **file_picker NPE（P2-2，PASS）**：同一未扫描图片走 Android SAF 路径，全程无 `FATAL EXCEPTION`、无应用崩溃记录；取消 SAF 不崩。
- **仅 WiFi 本地封面（PASS）**：设备仅 WiFi，开启仅 WiFi 时本地封面仍显示（不触发网络门控）；蜂窝场景此前已 BLOCKED。
- **书架阴影**：外层阴影代码已接；本轮未单独截图量测（设备清理前未切换该开关），保留为 P3 视觉复核项。
- **稳定性**：本轮 logcat FATAL/ANR/E.flutter/overflow=0（uiautomator 自身 SIGSEGV 不计）。
- 证据：`docs/materials_1106d/01..05`。
- 设备清理：删除测试书/图片、`pm clear io.legado.flutter_legado`、logcat 清空；应用恢复空书架默认态。

编写：ZCode 主代理 ｜ 2026-11-06
