# A 组对齐发现报告（深色 A 组）— 2026-09-20

> 状态：**完成（门禁通过）**
> 范围：ledger A1/A2/A3/A4/A5/A6（`docs/DARK_THEME_PARITY_LEDGER_20260920.md` §六 用户裁决，line 197/201）
> 约束：禁止 commit；不使用设备（同机设备被另一任务占用）；红线 reader_screen.dart/排版测量/翻页动画/手势零改动（A5 只删菜单项）；不新增未授权 UI；参考语义不明处先报告不猜。
> 取证基座：`D:\tmp\md3_ref_legado`（HapeLee/legado-with-MD3 @9db5ae6，只读；其书架/主题页为 Compose 实现）+ `D:\OH-WorkSpace\Projects\legado_flutter`；代码闭环 = `flutter analyze` + 全量 `flutter test`。

## ① 可用性判定（analyze / test 前后）

- **改动前基线（本任务开工前）**：`flutter analyze` 0 问题；`flutter test` 全量 1580/1580 通过。
- **改动后（本次门禁复跑）**：`flutter analyze` **No issues found!（0 项，2.6s）**；`flutter test` **全量 1584/1584 通过（exit 0，All tests passed!）**。增量 +4 即新增的 A1 二维码解码回归测试（`test/unit/qrcode_gallery_decode_test.dart`，新文件）。
- **判定：可用。** 全部在途改动（qrcode_screen / reader_menu_panel / search_content_screen / pubspec / 新测试）均过门禁；`reader_screen.dart` 未出现在改动集中（红线零改动 ✓）。

## ② 新增依赖评估结论（zxing2 + image）

### 2.1 zxing2 ^0.2.4（lock 实际 0.2.4）
- **许可证**：BSD-3-Clause（Copyright zxing-dart / xvrh，仓库 github.com/xvrh/zxing-dart）。
- **维护状态**：0.2.4 为当前最新版（约 15 个月无新版本，累计下载约 377k，xaha.dev 发布）；纯 Dart 实现，**无 platform channel**。
- **依赖树**：`charcode 1.4.0` + `collection` + `fixnum 1.1.1` + `meta`（collection/meta 为 SDK 自带，fixnum 原依赖图已有）——唯一新增传递包是 charcode（纯 Dart 小工具包）。
- **三端可用性**：Android / iOS / Windows 全可用（纯 Dart，无原生层）。
- **备选对照**：相机路径已由 mobile_scanner 7.4.0（原生识别）覆盖，不受下述缺陷影响；纯 Dart 解 QR 只用于「相册选图 → 解码」路径（生产 `compute()` isolate + 测试），zxing2 是该场景纯 Dart 生态的标准选择（旧 `zxing` 包已弃用、并入 zxing2），无更优替代。
- **已知缺陷（已规避，代码内有注释）**：zxing2 0.2.4 的 `DecodedBitStreamParser._decodeByteSegment`（`decoded_bit_stream_parser.dart:191-220`）把字节段读入**有符号** `Int8List`，UTF-8 ECI（ECI 26，`character_set_eci.dart:8,56`）下 ≥0x80 的字节全变 U+FFFD（中文等 CJK 内容乱码）；0.2.4 为最新版、上游未修。规避：`QRCodeReader.decode()` 会把 `decoderResult.byteSegments` 存入 `result.resultMetadata[ResultMetadataType.byteSegments]`（`qrcode_reader.dart:54-57`，二者均由 zxing2.dart 导出）；生产 `qrcode_screen.dart` 的 `_recoverUtf8Text` 将其重建为 `Uint8List`（`seg[i] & 0xFF`）后以 `const Utf8Codec(allowMalformed: true)` 重解码，且「只升不降」（重建结果仍含 FFFD 时返回原文）。影响面：不修则相册导入 CJK 二维码内容全平台乱码；相机路径不受影响。

### 2.2 image ^4.8.0（lock 实际 4.10.1）
- **许可证**：MIT（Brendan Duncan，2013-2022）。
- **维护状态**：活跃（4.9.x/4.10.x 持续修复 WebP/JPEG 解码问题，4.10.1 为当前版）。
- **依赖树**：唯一传递依赖 `archive ^4.0.9`，而 **archive 4.0.9 本就是本项目 direct main 依赖**（lock 已有，`dart pub deps` 证实）→ image 带来的**新传递依赖为零**。
- **是否必需**：**必需**。相册路径需在纯 Dart 上下文（生产 `compute()` 后台 isolate + 单元测试）把任意图片字节（PNG/JPEG，来自 file_picker）解码为像素并构造 zxing2 的 `RGBLuminanceSource(width, height, pixels)`；Flutter 引擎侧解码 API（instantiateImageCodec 等）依赖引擎管线，无法在 isolate/测试中使用，`image` 是标准且事实唯一的纯 Dart 方案。API 面：`decodeImage`（自动探格式；对畸形字节会抛 RangeError → 生产代码整段 try/catch 返回 null）、`convert(numChannels: 4)`、`getBytes(order: ChannelOrder.rgba)`；`img.Image`/`fillRect`/`ColorUint8.rgba`/`encodePng` 仅测试 fixture 渲染用。
- **三端可用性**：纯 Dart，Android / iOS / Windows 全可用。
- **结论**：两个依赖均保留；zxing2 CJK 缺陷已在生产代码规避并有测试回归；image 仅用于相册解码路径（含测试 fixture），无其他用途。

### 2.3 lock 变更面（git diff --stat）
`pubspec.yaml +4`（zxing2 ^0.2.4、image ^4.8.0 及注释）；`pubspec.lock +24`（charcode/image/zxing2 各 8 行）。无其他包受影响，无版本升级连锁。

## ③ A1 / A5 / A6 逐项

### A1 全屏扫描器（`flutter_legado/lib/src/screens/qrcode_screen.dart`）— 完成
- **参考依据**：`ui/qrcode/QrCodeActivity.kt:18`（独立**全屏 Activity** `QrCodeActivity : BaseActivity<ActivityQrcodeCaptureBinding>()`）；`QrCodeFragment.kt:14-28`（`DecodeFormatManager.QR_CODE_HINTS` 仅 QR、`isFullAreaScan = true` 全区域识别、`areaRectRatio = 0.8f` 识别区 80%）。
- **diff 概要**：独立全屏路由页（标题「扫描二维码」+ 相册入口图标）；取景框 = 屏幕短边 80% 正方形（对齐参考 0.8 比例）+ 白 2px 边框（radius 12）；相机路径 mobile_scanner 原生识别，errorBuilder 降级「相机启动失败」200px 头 + 手动输入/粘贴/「使用该内容」；相册路径 file_picker 取图 → 字节 → `compute(_decodeQrInIsolate)` 纯 Dart 解码（含 `_recoverUtf8Text` CJK 规避）。Web/桌面无相机 → `_cameraSupported` 判定直接降级形态。
- **测试**：`test/unit/qrcode_gallery_decode_test.dart` 4/4 通过——① URL 往返（`https://legado.example.com/book-source.json`）；② CJK 回归（内容 `legado://import?data=测试口令`，未加 `_recoverUtf8Text` 时本用例得到一串 U+FFFD）；③ 64x64 红色 PNG 解码为 null；④ 4 字节畸形输入为 null。宿主平台降级渲染由 `test/widget/screens_overflow_regress_test.dart:184`（`QrcodeScreen`）覆盖。
- **红线合规**：reader 域文件零改动。

### A5 阅读器菜单收敛（`flutter_legado/lib/src/widgets/reader/reader_menu_panel.dart`）— 完成
- **参考依据**（引用块 reader_menu_panel.dart:444-464）：① `ReadButtonConfigDelegate.kt:197-203` DEFAULT_ENABLED_BUTTON_IDS + `loadButtonConfig :148-154`（默认启用 5 键）；② `SystemMenuPage.kt:898-903` 键→图标映射；③ `values-zh-rCN/strings.xml` 全文搜索:1036 / 自动翻页:465 / 目录:184 / 朗读:189 / 设置:97；④ `ReadBookContract.kt:359-360` itemsPerRow=5 / rowCount=1（单行五键）+ `:390` showBrightnessView="0"（亮度不进菜单键）。
- **diff 概要**：菜单动作行（:508-521）收敛为参考 5 键——全文搜索（`Symbols.search_rounded` → onOpenContentSearch）/ 自动翻页（pause/play 随 autoPageActive 切换 → onToggleAutoPage）/ 目录（`format_list_bulleted_rounded` → onOpenCatalog）/ 朗读（`headphones_rounded` → onReadAloud）/ 设置（`settings_rounded` → onOpenSettings），`SizedBox(height: 76, Row(items))`；亮度/字号保留在 ReaderSettingsSheet / ReaderConfigPanel（参考版同样不在菜单键内，:390）。**只删菜单项**：reader_screen.dart、排版测量、翻页动画、手势零改动。
- **测试**：全量门禁通过（无专项回归用例，删除菜单项不影响既有断言）。

### A6 全文搜索输入盒（`flutter_legado/lib/src/screens/search_content_screen.dart:342-366`）— 源码级完成，**需设备重采对照**
- **参考依据**：参考 `SearchBar.kt:55/103-108/132-138` 输入盒填充取 `MiuixTheme.colorScheme.surfaceContainer`（Miuix 引擎，外部库 `top.yukonga.miuix.kmp`，色值**不在仓库内**）或标准 material 引擎的 `MaterialTheme.colorScheme.surfaceContainerLow`；仓库默认 `composeEngine = "material"`（`ThemePackageSettingsRepository.kt:14`、`FeatureSettingsRepositories.kt:283`）。
- **矛盾与裁决**：ref 13（13_search_content.png）亮盒 #E8E2D4 与 12 套参考深色 sCL 逐一比对均不匹配，唯一命中是 **Lemon 深色 onSurface**（`LemonColorScheme.kt:80`；其 sCL 为 `:104` #1E1B13）→ 该参考实例疑为 Miuix 引擎或残留柠檬强调色（与 ledger 3-4 疑点一致）。
- **现状**：代码**未改**（盒填充 = `isDark ? scheme.onSurface : scheme.surfaceContainerLow`，与 ledger 已裁定的采集一致），证据链 + [需设备重采对照] 已写入注释块。
- **后续动作**：设备空闲后核对该参考实例 composeEngine 设置，Lemon 深色下按两种引擎分别重采搜索盒像素；若确认标准引擎深色盒为 #1E1B13 则回退 `surfaceContainerLow`；重采前保留本在途实现。

## ④ A4 书架单击/长按取证 — 结论：**不改码**，记录建议改法与影响

- **参考语义（证据链）**：
  - 任务假定的 `ui/book/shelf/`（BookshelfFragment/Adapter）**不存在**：MD3 参考把书架整体重写为 Compose，实际路径 `ui/main/bookshelf/`。
  - 条目级：`ui/main/bookshelf/BookItem.kt:83-91` `.combinedClickable(role = Role.Button, onClick = onClick, onLongClick = onLongClick)`。
  - 事件接线：`ui/main/MainScreen.kt:556-568` 单击 `onOpenBookshelfBook`、长按 `onNavigateToBookInfo`。
  - 路由：`MainNavGraph.kt:338-351`——音频书 `startActivityForBook`；`!isLocal && isImage && showMangaUi` → `MainRouteReadManga`；其余 → `MainRouteReadBook(bookUrl, sharedCoverKey)`。**无读进检查，单击恒进阅读器**；长按 `:355-365` → `MainRouteBookInfo`。
  - 兜底：`utils/ContextExtensions.kt:72-89`（Book）`startActivityForBook` 音频/图片漫画/文本三分流；`MainNavGraph.kt:601-645` 阅读路由入口 `ReadBookInitRequest(bookUrl, inBookshelf, chapterChanged)`，零进度书由阅读器初始化处理。
- **我方现状**（`flutter_legado/lib/src/screens/bookshelf_screen.dart`）：单击 :681-683 → `_openBook` :722-759（按 BookType 路由 video/audio/reader-comic/reader，:719-721 注释标明对标 `startActivityForBook` 语义）；长按 :899-900（封面/书名/信息卡 :708-712）→ `_openBookInfo` :761-768 书籍详情页。**语义与参考一致。**
- **唯一差异**：未读书（`durChapterIndex <= 0 && durChapterPos <= 0`）我方 :724-727 回退打开**详情页**（注释为有意设计「Reasonix + UI」）；参考无此检查、单击恒进阅读器。
- **建议改法（本次不实施）**：删除 :724-727 回退，使单击恒进阅读器。**影响**：阅读器需承接零进度书（跳首章/展示目录），当前阅读器无零进度处理（`durChapterIndex` 仅 model 与 bookshelf 引用），且属 **reader 红线区 + 无设备不可验证** → 按裁决「证据不足/改动越红线时先报告不猜」保留现状，仅登记差异。

## ⑤ A2 / A3 事实清单（本次不改码）

### A2 主题页 12 卡：名称 / 顺序 / 颜色 diff
**参考 14 个主题模式**（`ui/theme/AppThemeMode.kt` 枚举；`ThemeResolver.kt:17-31` 映射 "0"-"13"）：0 动态取色(Dynamic)、1 草野(GR)、2 柠檬(Lemon)、3 黑白(WH)、4 电子书(Elink)、5 晴空(Sora)、6 八月(August)、7 新浪潮(Carlotta)、8 春(Koharu)、9 千禧年(Yuuka)、10 隐海修会(Phoebe)、11 乐队(Mujika)、12 自定义(Custom)、13 透明(Transparent)。中文显示名：`values-zh-rCN/arrays.xml:160-175 themes_item`；英文 `values/arrays.xml:71-86`；12 个 colorScheme 文件在 `ui/theme/colorScheme/`（无 def 套）。

**我方 13 套**（`flutter_legado/lib/src/theme/md3_colors.dart`，header 注释「阶段D 2.0.270 起默认 def」）：纯白(wh :138)、森绿(gr :242)、柠檬(lemon :346)、小春(koharu :450)、优香(yuuka :554)、菲比(phoebe :658)、穹(sora :762)、八月(august :866)、卡洛塔(carlotta :970)、姆吉卡(mujika :1074)、墨水(elink :1178)、透明(transparent :1282)、默认(def :1400)。

**名称 diff（我方 label ↔ 参考 zh）**：

| 我方 | 参考 zh（id） | 一致 |
|---|---|---|
| 纯白 | 黑白（3 WH） | 名异 |
| 森绿 | 草野（1 GR） | 名异 |
| 柠檬 | 柠檬（2） | ✓ |
| 小春 | 春（8 Koharu） | 名异 |
| 优香 | 千禧年（9 Yuuka） | 名异 |
| 菲比 | 隐海修会（10 Phoebe） | 名异 |
| 穹 | 晴空（5 Sora） | 名异 |
| 八月 | 八月（6） | ✓ |
| 卡洛塔 | 新浪潮（7 Carlotta） | 名异 |
| 姆吉卡 | 乐队（11 Mujika） | 名异 |
| 墨水 | 电子书（4 Elink） | 名异 |
| 透明 | 透明（13） | ✓ |
| 默认(def) | 参考无（参考独有 0 动态取色 / 12 自定义） | 套系差 |

**顺序 diff**：参考 1-13 = 草野、柠檬、黑白、电子书、晴空、八月、新浪潮、春、千禧年、隐海修会、乐队、透明（0 动态取色 / 12 自定义 夹在 1 与 13 之间）；我方 = 纯白、森绿、柠檬、小春、优香、菲比、穹、八月、卡洛塔、姆吉卡、墨水、透明、默认（def 收尾）。两套顺序不一致，且我方把 def 放最后。

**深色色值 diff（bg / onSurface / sCL；参考值来源：本任务 ledger 阶段采集 + WH 源码核验）**：

| 主题 | 参考深色 | 我方深色 | 判定 |
|---|---|---|---|
| WH/纯白 | #141313 / #E5E2E1 / #1C1B1B | 同 | ✓（WHColorScheme.kt:76-79 源码核验） |
| GR/森绿 | #12140E / #E2E3D8 / #1A1C16 | 同 | ✓ |
| Lemon/柠檬 | #15130B / #E8E2D4 / #1E1B13 | 同 | ✓（LemonColorScheme.kt:80,104） |
| Koharu/小春 | #1A1111 / #F0DEDE / #221919 | 同 | ✓ |
| Yuuka/优香 | #131318 / #E4E1E9 / #1B1B21 | 同 | ✓ |
| Phoebe/菲比 | #15130C / #E8E2D4 / #1E1C13 | 同 | ✓ |
| Sora/穹 | #111318 / #E1E2E9 / #191C20 | 同 | ✓ |
| August/八月 | #1A110F / #F1DFDA / #231917 | 同 | ✓ |
| Carlotta/卡洛塔 | #191114 / #EFDFE2 / #22191C | 同 | ✓ |
| Mujika/姆吉卡 | #191113 / #EFDEE0 / #22191B | 同 | ✓ |
| Elink/墨水 | #000000 / #FFFFFF / #1C1B1B | 同 | ✓ |
| Transparent/透明 | #00000000 / #EDE6FF / **0x8F000000（设备采，仓库源码未显式设 sCL，运行时 OpaqueColorScheme/ThemeColorSchemeOverride 兜底）** | #00000000 / #EDE6FF / **#00FFFFFF** | bg/onSurface ✓；**sCL 不一致**（参考 56% 黑 vs 我方全透明）→ 需设备重采复核 |
| def/默认 | 参考无此套 | #424242 / #EDE6E4 / #4A4A4A | 我方独有 |

> 11/12 色值完全一致；唯 Transparent 深色 sCL 与参考（设备采 0x8F000000）不一致，源码不可定（未显式设置）→ 登记「需设备重采」。A2「主题页同步风格版」（横滑一行布局 + 名称/顺序/颜色一并对齐）**本次未实施**（任务要求先采事实），事实清单已齐，后续按上表对齐即可。

### A3 设置·外观页 IA（参考源码结构）
- **入口**：`MainNavGraph.kt:470-476` `entry<MainRouteSettingsTheme>` → `ThemeConfigRouteScreen`（`ui/config/themeConfig/ThemeConfigRouteScreen.kt`：3 个文件选择器——字体目录 OpenDocumentTree / 导航图标 GetContent image/png（MD5 内容摘要命名存 filesDir/nav_icons）/ 背景图 GetContent image/* + 6 类 effect 分发：ApplyDayNight / NotifyMain / ChangeLauncherIcon / OpenFontFolder / OpenNavigationIcon / OpenContainerBackgroundImage / ShowToast）→ 渲染 `ThemeConfigScreen`。
- **页面结构**（`ThemeConfigScreen.kt:91-727`，LazyColumn 单 item 序列）：
  1. 主题预览卡 `ThemeCard`（:1163，非 Miuix 引擎显示）+ 重构提示 GlassCard（:159-182，可关闭）；
  2. 组「主题」（:185-251）：主题模式选择器 `ThemeModeSelector`（:981）+ **12 色卡选择器 `ThemeColorSelector`（:1020，卡片 `ThemeColorButton` :1054，取色 `getThemeColorPalette` :1276 / `getThemeColors` :1307）——A2 的 12 卡页即此组件**；Miuix 引擎分支改下拉 + Monet 开关；
  3. 无题组（:253-334）：纯黑开关 / 字体设置 / 自定义主题色（仅 appTheme=12 显示）/ 组合引擎下拉 / 更换图标 / 预测式返回 / 字体缩放滑杆（8-16f 七档）/ 主题包入口 / 背景图入口；
  4. 组「主活动」（:336-381）：主导航设置 / 显示状态栏 / 显示滑动动画 / 上下栏设置 / 平板界面下拉；
  5. 组「书籍详情页」（:383-410）：跟随封面色 / 网络封面背景 / 默认封面背景（模糊档位下拉）；
  6. 组「护眼」（:412-486）：护眼开关 / 夜间自动护眼 / [已配置时] 色温滑杆 + 护眼日程 + 开始/结束时间选择；
  7. 组「模糊效果」（:488-503）：启用模糊 / 渐进式模糊；
  8. 组「主题管理·容器」（:508-710）：容器背景图（大容器/项目图 + 不透明度滑杆）/ 取消拼接组圆角 / 基础卡片圆角（override + 0-40dp 滑杆）/ 基础卡片描边（override + 宽度 + 日/夜色 `BaseCardBorderColorSettingItem` :951）/ 分隔线（宽度/长度/颜色）；
  9. 恢复默认设置（:712-724）+ 确认对话框 / 时间选择对话框（:729-756）；
  10. 关联 sheet（6 个文件）：BackgroundImageManageSheet / LauncherIconPickerSheet / MainNavigationSettingsSheet / NavIconManageSheet / TopBottomBarSettingsSheet / LabelColorManageSheet。
- **需设备重采**：现采集 `ref_batch3/04_appearance_dark.png` 疑被参考实例柠檬强调色污染（ledger 3-4 已记「均值 36.2 vs 52.3 待复验」）；A3 对齐页面 IA 前须先重采**参考默认主题的干净基线**（本任务不使用设备，登记待办）。

## ⑥ 需设备重采清单（汇总）
1. **A3 基线**：参考版默认主题下重采「设置·外观」页深色截图（现 04 图疑柠檬污染）——页面 IA 对齐前置。
2. **Transparent 深色 sCL**：仓库源码未显式设置（运行时兜底），参考设备采值为 0x8F000000 与我方 #00FFFFFF 不一致 → 重采复核（顺带覆盖 ledger 3-5「12 色卡深色形态」P1 项，theme_colors_ref.json 无 dark scheme）。
3. **A6 输入盒**：核对参考实例 composeEngine 设置；Lemon 深色下按 material / Miuix 两引擎分别重采搜索盒像素，确认标准引擎深色盒为 #1E1B13 后回退 `surfaceContainerLow`，否则保留现实现。

## ⑦ 门禁输出
- `flutter analyze`：**No issues found!（0 项，ran in 2.6s）**
- `flutter test`：**All tests passed!（1584/1584，exit 0）**
- `git status --short`（flutter_legado/ 内，本任务改动集）：
  ```
   M lib/src/screens/qrcode_screen.dart          (A1：_recoverUtf8Text CJK 规避 + 文档注释)
   M lib/src/screens/search_content_screen.dart  (A6：证据注释块，代码未改)
   M lib/src/widgets/reader/reader_menu_panel.dart (A5：菜单收敛 5 键 + 引用块)
   M pubspec.lock                                (+24：charcode/image/zxing2)
   M pubspec.yaml                                (+4：zxing2 ^0.2.4、image ^4.8.0)
  ?? test/unit/qrcode_gallery_decode_test.dart   (A1：4 个解码回归用例，新文件)
  ```
  其余未跟踪文件（docs/parity_shots/*、.zcode/、.agent-teams/ 等）属其他在途任务/环境产物，非本任务改动。
- 红线核验：`reader_screen.dart` 不在改动集；排版测量/翻页动画/手势文件零改动；未新增未授权 UI（A1 全屏扫描页为 ledger 裁决授权项）。
- 本任务**未执行 commit**（按约束）。
