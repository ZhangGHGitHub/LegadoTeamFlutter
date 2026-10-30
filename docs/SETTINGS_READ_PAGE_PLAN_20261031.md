# 独立「阅读设置」页（批1）实施就绪方案（2026-10-31）

> 编写：调研员（只读核实）｜ 2026-10-31
> 依据：`docs/SETTINGS_GAP_SCOPE_20261030.md` P-1 与 §3.4、`docs/SETTINGS_WIRING_PLAN_20261030.md`（批9a 13 项接线，本方案不复做）。
> 三方对照：参考版 `legado-with-MD3`、原版 `legado-upstream`、我方 `flutter_legado`（当前 HEAD）。路径:行均为编写时点事实。
> 语义标注：〔参〕=参考版独有（原版无对应 PreferKey 或无消费方）；〔原〕=原版/参考版均有。

## 一、结论摘要

1. 参考版独立「阅读设置」页 = `ui/config/readConfig/` 四件套（Screen/ViewModel/Contract/PageKeySheet），三组（屏幕/页面控制/其他）共 **38 行控件**（含 3 个子 Sheet 入口），背后是 `ReadSettings`（102 字段 DataStore 快照，`ReadSettingsRepository.kt:364-496` 全量默认值）。入口在设置主页 `ConfigNavScreen.kt:68`「Reading Interface Settings」，路由 `MainNavGraph.kt:682-684`（`MainRouteSettingsRead`）。
2. 我方**无独立页**：设置主页「阅读界面」行（`settings_home_screen.dart:24-25`）当前弹 `ReaderSettingsSheet`（阅读器内四页签弹层）；阅读偏好存于 `ReaderAdvancedConfig`（`reader_config_panel_data.part.dart`，`reader_adv_*` + 原版键名混排）。
3. 逐项核对结论：参考版 38 行中我方**已有字段/模型约 22 项**（其中 19 项已有消费点、3 项仅有持久化）、**缺口 13 项**（无字段）、**6 项属参考版独有且我方无对应渲染/手势层**。缺口里需 Rust 的仅 2 类（无规则分章长度=纯 Rust 读取项；护眼=渲染叠加层，无需 Rust），其余均为纯 Dart；**无破坏性 FFI 变更**，若做无规则分章长度只需新增 1 个 config 读取点（`getConfig`/`setConfig` 通道已存在，`API_CONTRACT.md` §2.10）。
4. 实施拆 1a（纯 UI + 已有字段接线，约 5.5–6.5d）/ 1b（需 Rust/平台通道或渲染能力，约 4–5d）/ 1c（参考版独有无后端，暂缓），文件清单见 §五，批间文件不重叠。

---

## 二、参考版页面结构与语义（legado-with-MD3）

### 2.1 入口与骨架

| 项 | 位置 |
|---|---|
| 设置主页入口行 | `app/src/main/java/io/legado/app/ui/config/ConfigNavScreen.kt:68`（`R.string.read_config`＝"Reading Interface Settings"） |
| 路由注册 | `app/src/main/java/io/legado/app/ui/main/MainNavGraph.kt:682-684`（`entry<MainRouteSettingsRead> { ReadConfigRouteScreen(...) }`） |
| 页面骨架 | `app/src/main/java/io/legado/app/ui/config/readConfig/ReadConfigScreen.kt:28-468`：`AppScaffold` + `GlassMediumFlexibleTopAppBar` + `LazyColumn` 内 3 个 `SplicedColumnGroup` |
| 状态/意图契约 | `ReadConfigContract.kt:7-118`（`ReadConfigUiState` / `ReadConfigSheet{PageKeys,ClickActions,EyeProtection}` / `ReadConfigIntent`） |
| ViewModel | `ReadConfigViewModel.kt:17-104`（收集 `ReadSettingsGateway.settings` Flow；写经 `settingsGateway.update`，成功后 `ApplyReadSettingUseCase` 推运行时事件） |
| 生效事件 | `ApplyReadSettingUseCase.kt:12-54`（如 hideStatusBar→UpdateSystemUi、textFullJustify→loadContent、useUnderline→InvalidateTextPage、pageTouchSlop→UpdatePageSlopSquare） |
| 分组标题 | `strings.xml:1995`（screen_settings="Display and Brightness"）、`strings.xml:2000`（page_control="Page Turn Controls"）+ other |
| 持久化 | `data/repository/ReadSettingsRepository.kt:23-745`：DataStore `AppConfigStore`，键名与原版 PreferKey 同名；`toGatewayPrefMap()`（:630-745）全字段覆盖防丢写 |

### 2.2 三组逐项清单（ReadConfigScreen.kt 行号即控件定义处）

**组1「屏幕」（screen_settings，18 行）**

| # | 项（键） | 控件 | 默认值 | 归属 |
|---|---|---|---|---|
| 1 | 屏幕方向 screenOrientation | 下拉 6 档（`:57-65`） | "0" | 〔原〕`pref_config_read.xml:7`（原版同键同默认） |
| 2 | 保持亮屏 keepLight | 下拉 5 档（Default/1/5/10 min/Always，`:67-75`） | "0" | 〔原〕`keep_light`，`ReadBookActivity.kt:3116` 秒→screenTimeOut |
| 3 | 隐藏状态栏 hideStatusBar | 开关（`:77-83`） | false | 〔原〕`ReadBookConfig.kt:451` |
| 4 | 隐藏导航栏 hideNavigationBar | 开关（`:85-91`） | false | 〔原〕`ReadBookConfig.kt:452` |
| 5 | 填充刘海 paddingDisplayCutouts | 开关（`:93-99`） | false | 〔原〕`AppConfig.kt:881-882` |
| 6 | 标题栏方式 titleBarMode | 下拉 4 档（顶栏/另一行/仅章节/不显示，`:101-109`） | "1" | 〔参〕原版 PreferKey 无此键（grep 0 命中） |
| 7 | 菜单透明度 readMenuBlurAlpha | 滑块 0–100 默认 60（`:111-120`） | 85（仓库默认）| 〔参〕 |
| 8 | 正文延伸到刘海 readBodyToLh | 开关（`:122-128`） | true | 〔原〕`ReadBookConfig.kt:387` |
| 9 | 换源默认全部 defaultSourceChangeAll | 开关（`:130-137`） | true | 〔参〕原版无此键；消费 `ReadBookViewModel.kt` |
| 10 | 两端对齐 textFullJustify | 开关（`:139-145`） | true | 〔原〕`ReadBookConfig.kt:431` |
| 11 | 底部对齐 textBottomJustify | 开关（`:147-153`） | true | 〔原〕`ReadBookConfig.kt:436` |
| 12 | 适配特殊样式 adaptSpecialStyle | 开关（`:155-161`） | true | 〔原〕`pref_config_read.xml`（原版同键） |
| 13 | 中文断行 useZhLayout | 开关（`:163-169`） | false | 〔原〕`ReadBookConfig.kt:453` |
| 14 | 护眼模式 | 行→EyeProtectionConfigSheet（`:171-179`；Sheet `:452-467`） | — | 〔参〕字段在 ThemeSettings.kt:67-72（开关/强度/自动夜间/定时/起止） |
| 15 | 亮度条模式 showBrightnessView | 下拉 3 档（关/横/竖，`:181-189`；键 `readBrightnessMode`） | "0" | 〔原〕布尔版 `pref_config_read.xml`（默认 true）；参考版改三档 |
| 16 | 亮度条位置 brightnessVwPos | 下拉 2 档，仅模式=竖时显示（`:191-201`） | "1" | 〔原〕布尔版 `AppConfig.kt:956-958`（brightnessVwPos）；参考版改 left/right |
| 17 | 使用下划线 useUnderline | 开关（`:203-209`） | false | 〔参〕原版 PreferKey 无；消费 `LegacyReaderPaginationStyleFactory.kt` |
| 18 | 翻页动画速度 | 本页无行（`SETTINGS_GAP_SCOPE` §3.4 已列，属阅读器弹层翻页动画档，参考版在 PageAnim；**未在 ReadConfig 页**，不列入本批缺口） | — | — |

**组2「页面控制」（page_control，8 行）**

| # | 项（键） | 控件 | 默认值 | 归属 |
|---|---|---|---|---|
| 19 | 滑动条模式 readSliderMode | 下拉 2 档 Always/Disable（`:213-221`） | "0" | 〔参〕 |
| 20 | 双页模式 doubleHorizontalPage（键 doublePageHorizontal） | 下拉 4 档（`:223-231`） | "0" | 〔原〕`AppConfig.kt:844-846` |
| 21 | 进度条行为 progressBarBehavior | 下拉 2 档 页/章（`:233-241`） | "page" | 〔原〕`AppConfig.kt:853-854` |
| 22 | 鼠标滚轮翻页 mouseWheelPage | 开关（`:243-249`） | true | 〔原〕`AppConfig.kt:865-866` |
| 23 | 音量键翻页 volumeKeyPage | 开关（`:251-257`） | true | 〔原〕`AppConfig.kt:859-860` |
| 24 | 朗读时音量键翻页 volumeKeyPageOnPlay | 开关（`:259-265`） | true | 〔原〕`AppConfig.kt:862-863`（原版默认 false，见 pref_config_read.xml） |
| 25 | 按键长按连续翻页 keyPageOnLongPress | 开关（`:267-273`） | false | 〔原〕`AppConfig.kt:856-857` |
| 26 | 翻页触摸阈值 pageTouchSlop | 滑块 0–1000 默认 0（`:275-287`） | 0 | 〔原〕`AppConfig.kt:896-901` |

**组3「其他」（other，13 行 + 3 入口）**

| # | 项（键） | 控件 | 默认值 | 归属 |
|---|---|---|---|---|
| 27 | 滑动振动 sliderVibrator | 开关（`:291-297`） | false | 〔参〕 |
| 28 | 新目录弹层 useNewTocSheet | 开关（`:299-305`） | true | 〔参〕消费 `ReadBookViewModel.kt:203` |
| 29 | 无规则分章长度 maxLengthWithNoToc | 滑块 3000–100000 默认 3000（`:307-319`） | 3000 | 〔参〕消费 `TextFile.kt:363-364` |
| 30 | 选择振动 selectVibrator | 开关（`:321-327`） | false | 〔参〕消费 `ReadBookRouteScreen.kt:755` |
| 31 | 自动换源 autoChangeSource | 开关（`:329-335`） | true | 〔原〕`AppConfig.kt:637-638` |
| 32 | 自动日夜切换提醒 autoSuggestDayNight | 开关（`:337-344`） | false | 〔参〕 |
| 33 | 阅读锚点 readingAnchorEnabled | 开关（`:346-353`） | true | 〔参〕消费 `model/ReadBook.kt:753,760` |
| 34 | 朗读分离提醒 readAloudDetachReminderEnabled | 开关（`:355-362`） | false | 〔参〕消费 `model/ReadBook.kt:1041,1054` |
| 35 | 长按选择文本 selectText | 开关（`:364-370`） | true | 〔原〕`selectText`（PreferKey.kt:123） |
| 36 | 滚动翻页无动画 noAnimScrollPage | 开关（`:372-378`） | false | 〔原〕`AppConfig.kt:445-446` |
| 37 | 点击图片方式 clickImgWay | 下拉 5 档（新包行为/预览/经典/禁用/双击，`:380-388`） | "2" | 〔原〕`AppConfig.kt:747-748`；消费参考 `ReadBookController.kt:679`、原版 `ContentTextView.kt:398` |
| 38 | 优化渲染 optimizeRender | 开关（`:390-396`） | false | 〔原〕`AppConfig.kt:65`（原版受 `CanvasRecorderFactory.isSupport` 门控） |
| 39 | 点击区域配置 | 行→ClickActionConfigSheet（`:398-401`） | 9 宫格默认见 `ReadSettingsRepository.kt:437-445` | 〔原〕`AppConfig.kt:54-62` |
| 40 | 禁用返回键 disableReturnKey | 开关（`:403-409`） | false | 〔原〕`ReadBookActivity.kt:411` |
| 41 | 自定义翻页按键 | 行→PageKeySheet（`:411-414`，Sheet `:436-444`） | "" / "" | 〔原〕`prevKeyCodes/nextKeyCodes`（PreferKey.kt:74-75）；消费参考 `ReadBookController.kt:3245-3254` |
| 42 | 标题栏显示附加信息 showReadTitleAddition | 开关（`:416-422`） | true | 〔原〕`AppConfig.kt:943-945`（showReadTitleBarAddition） |
| 43 | 显示菜单图标 showMenuIcon | 开关（`:424-430`） | false | 〔参〕 |

> 注：参考版 ReadSettings 另有约 30 字段不在此页（菜单配色/毛玻璃等属批3「菜单系统页」，点击区域 9 宫格值虽在本模型但 Sheet 属批4 交互批），见 `SETTINGS_GAP_SCOPE_20261030.md` §二 P-2/P-3。

---

## 三、原版语义基准（legado-upstream）

- 原版无独立页，等价物是阅读器菜单「阅读设置」`MoreConfigDialog`（`ui/book/read/config/MoreConfigDialog.kt:79-244`）加载 `res/xml/pref_config_read.xml`（全量控件清单，行号即项）：screenOrientation(:7)/keep_light(:16)/hideStatusBar(:25)/hideNavigationBar(:33)/readBodyToLh(:41)/paddingDisplayCutouts(:49)/doubleHorizontalPage(:57)/progressBarBehavior(:65)/useZhLayout(:73)/textFullJustify(:81)/hangingPunctuation(:89)/punctuationCompress(:97)/textBottomJustify(:110)/adaptSpecialStyle(:118)/mouseWheelPage(:126)/mouseWheelScrollSpeed(:134)/volumeKeyPage(:146)/volumeKeyPageOnPlay(:154)/keyPageOnLongPress(:162)/pullToToggleBookmark(:170)/pullBookmarkDistance(:178)/pageTouchSlop(:186)/pageTouchClick(:194)/autoChangeSource(:202)/selectText(:210)/longPressSelectParagraph(:218)/twoFingerReplacePreview(:226)/showBrightnessView(:234)/noAnimScrollPage(:242)/clickImgWay(:250)/highlightActionTrigger(:258)/optimizeRender(:266)/clickRegionalConfig(:274)/disableReturnKey(:282)/customPageKey(:290)/customTextMenu(:298)/customReaderMenu(:306)/showReadTitleAddition(:314)/showReadTitleChapterNameOnly(:322)/readBarStyleFollowPage(:330)/showBookMemo(:338)。
- 原版默认值以 XML `android:defaultValue` 为准（如 volumeKeyPageOnPlay=false、showBrightnessView=true），参考版部分默认值已改（见 §二表）。
- 原版独有而参考版阅读设置页未收录：hangingPunctuation、punctuationCompress、mouseWheelScrollSpeed、pullToToggleBookmark、pullBookmarkDistance、pageTouchClick、longPressSelectParagraph、twoFingerReplacePreview、highlightActionTrigger、showReadTitleChapterNameOnly、showBookMemo（我方已有其中 hangingPunctuation/pageTouchClick 两键，见 §四）。
- 原版生效力：控件改动经 `MoreConfigDialog.onSharedPreferenceChanged`（`MoreConfigDialog.kt:114-183`）按键推事件（hideStatusBar→UP_CONFIG 重建沉浸式、keepLight→postEvent、screenOrientation→重设方向）。

---

## 四、我方现状逐项核对（flutter_legado）

模型唯一载体：`ReaderAdvancedConfig`（`flutter_legado/lib/src/screens/reader_config_panel_data.part.dart:6-656`；构造默认 `:197-247`，load `:258-468`，save `:481-585`）。UI 载体：`reader_config_panel.dart` + builders part（弹层），`reader_settings_sheet.dart`（四页签弹层）。共享态：`readerAdvConfigProvider`（data part `:620-656`），阅读器在 `reader_screen.dart:291-302 _loadAdvancedConfig` 加载、`didChangeDependencies` 按日夜重载。

| §二# | 项 | 我方状态 | 证据 |
|---|---|---|---|
| 1 | screenOrientation | 已实现（字段+UI+消费） | data part:109/222/519；消费 `reader_screen.dart:234` `_orientationsFor`（:246-262） |
| 2 | keepLight | 部分（有字段有 UI，**无消费**） | data part:112/223/520；`reader_screen.dart:235-238` 注释自认「项目未引入 wakelock 依赖，仅持久化」 |
| 3 | hideStatusBar | 已实现 | data part:115/224/521；`reader_screen.dart:230` |
| 4 | hideNavigationBar | 已实现 | data part:118/225/522；`reader_screen.dart:231` |
| 5 | paddingDisplayCutouts | 已实现 | data part:243/246/546；`reader_screen.dart:824-828` |
| 6 | titleBarMode | 无 | 全仓 grep 0（本项属批3 顶栏形态域，见 §五 1c 说明） |
| 7 | menuAlpha/readMenuBlurAlpha | 部分（我方有 `enableBlur`+硬编码 α85） | `reader_menu_panel.dart:148-152`；无可调 alpha 偏好 |
| 8 | readBodyToLh | 已实现 | data part:240/545；`reader_screen.dart:703/730/828/835` |
| 9 | defaultSourceChangeAll | 无 | grep 0（我方 autoChangeSource 已覆盖失败换源主路径） |
| 10 | textFullJustify | 已实现 | data part:30/205/403；消费 `paragraph_layout_engine.dart`（builders :568 传参） |
| 11 | textBottomJustify | 无 | grep 0 |
| 12 | adaptSpecialStyle | 无 | grep 0 |
| 13 | useZhLayout | 已实现 | data part:231/542；`paragraph_layout_engine.dart:155-157` |
| 14 | 护眼模式 | 无（仅背景色含「护眼」档位色） | `reader_state.dart:79` 是调色板标签，非叠加层 |
| 15 | showBrightnessView | 已实现（布尔版） | data part:133/236/455/533；`reader_bottom_bar.dart:36-37,294` |
| 16 | brightnessVwPos | 部分（无横竖模式选择；有 `readMenuBrightnessVertical/Pos` 两键但**零消费方**） | `pref_keys.dart:148-152`；`ui_settings_notifier.dart:162-165/395-396`；grep 消费 0 |
| 17 | useUnderline | 无 | grep 0 |
| 19 | readSliderMode | 无 | grep 0 |
| 20 | doubleHorizontalPage | 已实现 | data part:229/540；`reader_page_view.dart:88-91,463` |
| 21 | progressBarBehavior | 已实现 | data part:121/226/524；`reader_screen.dart:815` |
| 22 | mouseWheelPage | 已实现 | data part:150/538；`reader_page_view.dart:753-759` |
| 23 | volumeKeyPage | 已实现 | data part:145/536；`reader_screen.dart:277-283` |
| 24 | volumeKeyPageOnPlay | 已实现（默认 false=原版口径） | data part:148/239/537；`reader_screen.dart:283` |
| 25 | keyPageOnLongPress | 无 | grep 0 |
| 26 | pageTouchSlop | 已实现 | data part:236/543；`reader_page_view.dart:776-788,852` |
| 27 | sliderVibrator | 无 | grep 0 |
| 28 | useNewTocSheet | 无 | grep 0（我方 `_openToc` 恒路由 TocScreen，`reader_screen.dart:856-858`） |
| 29 | maxLengthWithNoToc | 无；Rust TXT 解析无按长分章回退（`rust/legado-book/src/txt.rs:124-171`：规则失败→内置正则→整文件单章，无 3000 字窗口切分） | grep rust 0 |
| 30 | selectVibrator | 无 | grep 0 |
| 31 | autoChangeSource | 已实现 | data part:127/232/527；`reader_screen.dart:1079` |
| 32 | autoSuggestDayNight | 无 | grep 0 |
| 33 | readingAnchorEnabled | 无 | grep 0 |
| 34 | readAloudDetachReminderEnabled | 无 | grep 0 |
| 35 | selectText | 已实现 | data part:130/233/528；`reader_text_content.dart:42-44,271-273` |
| 36 | noAnimScrollPage | 已实现 | data part:124/227/525；`reader_page_view.dart:69-70,276` |
| 37 | clickImgWay | 无（文本阅读器图片点击无分流） | grep 0 |
| 38 | optimizeRender | 无 | grep 0（Flutter 无 CanvasRecorder 等价物，1c） |
| 39 | 点击区域 9 宫格 | 部分（3 区×5 动作：left/center/rightAction，TapAction 5 值） | data part:13-17/29-50/202-204/407-409；`reader_screen.dart:937-978` |
| 40 | disableReturnKey | 无 | grep 0（我方 `reader_screen.dart:493` PopScope 恒可退出） |
| 41 | 自定义翻页按键 prevKeys/nextKeys | 无 | grep 0（Android 侧仅音量键捕获 `ReaderKeysBridge.kt:69-84`） |
| 42 | showReadTitleAddition | 部分（有字段有持久化；顶栏信息块 `reader_menu_panel.dart:644-668` 未读该开关恒显示；`reader_top_bar.dart:46-47,1368` 的 showTitleAddition 参数无调用方传值=死参数） | data part:136/237/534/560 |
| 43 | showMenuIcon | 无 | grep 0 |

另有我方已有而本页可复用/须纳入清单的：hangingPunctuation（data part:234/544，消费 `paragraph_layout_engine.dart:160-161`）、pageTouchClick（data part:239/547；`reader_screen.dart:943-951`）——原版独有键，本页补行即可零成本接线。

备份语义：以上原版键名键均已随 `appPrefs` 备份往返；「忽略阅读配置」白名单 `restore_ignore_prefs.dart:69-110 readPrefKeys` 需在批1 扩键时同步维护。

## 缺口计数（对照参考版 38 行 + 3 子页入口）

- **已实现 19 项**：#1/3/4/5/8/10/13/15/20/21/22/23/24/26/31/35/36 + 附加 2 项（hangingPunctuation、pageTouchClick）+ 点击区域基础版（#39 部分）。
- **部分 3 项**：#2 keepLight（有 UI 无消费）、#16 亮度条位置（有键无消费）、#42 showReadTitleAddition（有键无消费）。
- **无（可接线/可新增）13 项**：#11 textBottomJustify、#12 adaptSpecialStyle、#17 useUnderline、#25 keyPageOnLongPress、#27 sliderVibrator、#28 useNewTocSheet、#30 selectVibrator、#32 autoSuggestDayNight、#33 readingAnchor、#34 readAloudDetach、#37 clickImgWay、#40 disableReturnKey、#41 prevKeys/nextKeys。
- **无（依赖大/参考版独有，另批或暂缓）5 项**：#6 titleBarMode（批3 域）、#7 menuAlpha、#14 护眼（批2 域）、#29 maxLengthWithNoToc（需 Rust）、#38 optimizeRender（无等价物）、#9 defaultSourceChangeAll、#19 readSliderMode、#43 showMenuIcon（菜单系统域，批3）。

---

## 五、分步实施建议

### 1a 独立页 + 已有字段接线（纯 Dart，约 5.5–6.5d）

目标：新增独立路由页，把 §四「已实现 19 项 + 部分 3 项中的布尔接线」全部落到页面上，控件形态按参考版（开关行/下拉行/行内滑块行，视觉参考 `docs/SETTINGS_GAP_SCOPE_20261030.md` §六.6 裁决：拼接卡片组）。

文件清单（与批9a、批2、批3 均不重叠）：

| 动作 | 文件 | 内容 | 预估 |
|---|---|---|---|
| 新增 | `flutter_legado/lib/src/screens/read_config_screen.dart` | 三组页面（屏幕/页面控制/其他），复用 `ReaderAdvancedConfig` 模型；行组件复用 `IosGroup`/`SettingSwitchRow`（`widgets/ios_widgets.dart:117/359`）+ 新增 `SettingSliderRow`/`SettingDropdownRow`（放同文件或 ios_widgets，避免动批9a 触碰的 other_settings_screen） | 2.5d |
| 新增 | `flutter_legado/lib/src/screens/read_config_screen_data.part.dart`（如需拆分） | 行定义清单（键/控件/区间/默认值） | 含上 |
| 改 | `flutter_legado/lib/src/routes.dart` | `AppRoutes.readConfig = '/read_config'` + 路由表项 | 0.25d |
| 改 | `flutter_legado/lib/src/screens/settings_home_screen.dart` | 「阅读界面」行改 `Navigator.pushNamed(AppRoutes.readConfig)`（保留弹层在阅读器内入口不动） | 0.25d |
| 改 | `flutter_legado/lib/src/screens/reader_config_panel_data.part.dart` | 一次性补字段：textBottomJustify/adaptSpecialStyle/useUnderline/sliderVibrator/useNewTocSheet/selectVibrator/autoSuggestDayNight/keyPageOnLongPress/disableReturnKey/prevKeys/nextKeys/clickImgWay（布尔+枚举字段，键名对齐原版 PreferKey；load/save/copy 同步） | 1d |
| 改 | `flutter_legado/lib/src/services/restore_ignore_prefs.dart` | `readPrefKeys` 补上述新键（:70-110 白名单） | 0.25d |
| 改 | `flutter_legado/lib/src/widgets/reader/reader_menu_panel.dart` | showReadTitleAddition 接线：信息块（:644-668）按 `adv.showReadTitleAddition` 显隐（把死参数 showTitleAddition 或 provider 值传入） | 0.25d |
| 改 | `flutter_legado/lib/src/screens/reader_screen.dart` | ①disableReturnKey 接线：PopScope（:493 判定入口）菜单未开时拦截返回（对齐原版 `ReadBookActivity.kt:411`）；②keyPageOnLongPress：纯 Dart 无 Kotlin 改动可先登记「仅持久化+灰字」（见下 1b 备选） | 0.5d |
| 改 | `flutter_legado/lib/src/widgets/reader/reader_page_view.dart` / `reader_screen.dart`（仅传参行） | sliderVibrator/selectVibrator 接线：翻页成功/选词处 `HapticFeedback.selectionClick()`（Flutter 内建，无需新依赖） | 0.5d |
| 新增 | `flutter_legado/test/widget/read_config_screen_test.dart` 等 | 见 §六 | 0.75d |

- 不重做批9a 已裁决项（抗锯齿/图片缓存/漫画开关/自动更新/音频焦点/源编辑行数/预下载/语言 8 项均在 other_settings 域）。
- 「部分→已实现」三项中：keepLight 与亮度条位置涉及平台通道，留 1b；showReadTitleAddition 纯 Dart 已入 1a。
- 风险：低。新页面只读共享 `readerAdvConfigProvider`，弹层与独立页同写 `ReaderAdvancedConfig.save()`，无双源问题（同一模型同一持久化键）。

### 1b 需 Rust/平台通道/渲染能力（约 4–5d）

| 项 | 改造点 | Rust/平台影响 | 契约 | 预估 |
|---|---|---|---|---|
| 无规则分章长度 maxLengthWithNoToc | Dart 保存走既有 `api.setConfig('maxLengthWithNoToc', v)`（§2.10 通道）；Rust `rust/legado-book/src/txt.rs` `get_chapters_with_rule`（:124-171）内置规则零命中后按 3000–100000 字符窗口切分（对齐参考版 `TextFile.kt:363-364,464` 字节换算语义）；`rust/legado-ffi/src/ffi.rs:807 reader_get_chapters` 读 `config:maxLengthWithNoToc` 传入 | Rust legado-book + ffi 读取 config；**无签名变更**，行为契约登记 | `docs/API_CONTRACT.md` §2.9 `getChapters` 行补充说明（无需新 FFI） | 1.5–2d |
| keepLight 保持亮屏 | 复用音频唤醒锁模式：`audio_service.dart:246-257` 同通道加 `setKeepScreenOn(bool)`，Kotlin 侧 `MediaSessionBridge.kt:181-202` 同法新增 `FLAG_KEEP_SCREEN_ON`（对 Activity window，非 PARTIAL_WAKE_LOCK，对齐参考版 `ReadBookController.kt:3174-3204` 仅阅读页语义）；Dart 在 `reader_screen.dart:235` 处按 keepLight 值接线（-1/常量>0 恒亮，0 交还系统） | 仅 Android 平台通道方法新增；iOS 需另评（原版无 iOS） | 平台通道（非 FFI）；`docs/API_CONTRACT.md` 不涉 | 1d |
| 亮度条模式三档 + 位置 | `pref_keys.dart:148-152` 两键扩为 `readBrightnessMode("0"/"1"/"2")` + `readBrightnessVwPos("0"/"1")`（对齐参考版键），旧布尔键一次性迁移；消费：reader_bottom_bar（横条=现 showBrightnessView）与 reader_menu_panel（竖条 widget 新增，左/右 Positioned）；接 UiSettingsNotifier | 纯 Dart | 无 | 1d |
| 音量键长按连翻 keyPageOnLongPress | `ReaderKeysBridge.kt:69-84` 需上报 keyUp/长按计时；Dart `reader_screen.dart:_onHardwareKey` 扩长按重复翻页 | 仅 Android 平台通道 | 无 | 0.5–1d |
| selectText 已实现、clickImgWay（文本阅读器图片点击分流 5 档） | `reader_text_content.dart` 图片 tap 处按 clickImgWay 分流（预览/禁用/双击；「新包行为/经典」依赖图片动作解析，无后端先支持 禁用/预览/双击 三档并灰字标注） | 纯 Dart；图片 action 字段是否已随正文解析保留待验证（实现前先验证） | 无 | 1d |

> 批9b（`SETTINGS_WIRING_PLAN_20261030.md` §三）与本 1b 无文件交集，可并行排期；若同车次发布，`reader_comic_screen.dart`/`MediaSessionBridge.kt` 需协调（批9b-3/5 触及），本 1b keepLight 亦触 `MediaSessionBridge.kt` —— **建议 keepLight 的 Kotlin 侧与批9b-5 同一次提交落地**，避免同文件双改冲突。

### 1c 参考版独有且无后端/属后续批次（暂缓，不进批1）

| 项 | 原因 | 建议归属 |
|---|---|---|
| titleBarMode（#6） | 依赖阅读器菜单顶栏形态（参考版另一行/仅章节渲染在菜单系统内） | 批3 菜单系统页（GAP_SCOPE P-2） |
| menuAlpha/readMenuBlurAlpha（#7） | 同上，且需先有可调 alpha 表面参数 | 批3 |
| 护眼模式 EyeProtectionSheet（#14） | 渲染叠加层 + ThemeSettings 域（强度/定时/自动夜间） | 批2 外观补项（GAP_SCOPE P-3） |
| useNewTocSheet（#28） | 需先有「阅读页内目录 Sheet」形态（我方恒路由 TocScreen），属导航重构 | 批3/批4 |
| autoSuggestDayNight（#32）/readingAnchor（#33）/readAloudDetach（#34） | 参考版独有，依赖日夜建议弹层/锚点跳转/朗读分离状态机（`model/ReadBook.kt:753,1041`），我方无对应状态源 | 批4 之后按授权裁决 |
| defaultSourceChangeAll（#9）/readSliderMode（#19）/showMenuIcon（#43） | 参考版独有且挂在菜单/换源 UI 域 | 批3 |
| optimizeRender（#38） | 原版受 `CanvasRecorderFactory.isSupport` 门控，Flutter 无等价渲染缓存开关 | 登记平台差异，仅持久化+灰字（如需） |
| sliderVibrator（#27，若 1a 不做） | 无反馈 | 1a 可选 |

### 文件不重叠声明

- 1a 新文件 + routes/settings_home + reader_config_panel_data/builders + reader_menu_panel（仅 showReadTitleAddition 行）+ reader_screen（PopScope 行）；
- 1b 改 txt.rs / ffi.rs / ReaderKeysBridge.kt / MediaSessionBridge.kt / reader_bottom_bar.dart / reader_menu_panel.dart（竖条 widget，与 1a 的 :644 行改动同文件但不同函数，**建议 1a 先合**）；
- 与批9a（main.dart/app.dart/audio_notifier/source_edit_screen/book_open_utils/image painters）零交集；与批9b 共享 `MediaSessionBridge.kt`（上面已给协调方案）。

---

## 六、测试与验收

### 单元/widget 测试（CI 覆盖：flutter analyze && flutter test；涉 Rust 走 cargo test）

| 步 | 测试点 | 文件建议 |
|---|---|---|
| 1a | 独立页渲染：三组标题、行数、每行控件类型、默认值与 `ReaderAdvancedConfig.load()` 一致 | `test/widget/read_config_screen_test.dart` |
| 1a | 路由与入口：settings_home「阅读界面」→ readConfig 路由；返回不丢状态 | 同上 |
| 1a | 字段往返：新 12 键 save→load 幂等（含 prevKeys/nextKeys 逗号串、clickImgWay 档位钳制） | `test/unit/reader_advanced_config_roundtrip_test.dart` |
| 1a | showReadTitleAddition=false 时菜单顶栏信息块不渲染 | `test/widget/reader_menu_title_addition_test.dart` |
| 1a | disableReturnKey=true 且菜单未开时 PopScope 不放行、菜单开时放行 | `test/widget/reader_back_key_test.dart` |
| 1a | 振动接线：翻页/选词回调触发 `HapticFeedback`（可注入 mock channel 断言） | `test/unit/haptic_wiring_test.dart` |
| 1a | 备份白名单：新键命中 `readPrefKeys`，勾选「忽略阅读配置」后被过滤 | `test/unit/restore_ignore_prefs_test.dart`（既有文件追加用例） |
| 1b | Rust：`get_chapters_with_rule` 对无规则长文按 N 字符切分、边界（N=3000 最小/100000 最大/规则命中时不切分） | `rust/legado-book/src/txt.rs` 测试模块追加 |
| 1b | Rust：`reader_get_chapters` 读 `config:maxLengthWithNoToc` 缺省 3000、非法值回落 | `rust/legado-ffi` 测试 |
| 1b | 亮度条三档：模式 0/1/2 显隐、竖条左右位置 | `test/widget/reader_brightness_bar_test.dart` |

### 真机验收（MuMu Test 档，按 AGENTS.md 测试档流程）

1. 独立页各控件改值 → 返回阅读器即时生效（方向/隐藏栏/进度条行为/双页/音量键/滚轮/touchSlop 手感）。
2. keepLight：设「常亮」锁屏等待 >系统超时，屏不灭；退出阅读器恢复系统策略。
3. 音量键长按连翻：长按音量键连续翻页不松手（1b）。
4. clickImgWay 三档：在线书正文图片点按行为（预览弹层/无响应/双击预览）。
5. 亮度条竖条：左/右位置贴边滑动调亮度不与翻页手势冲突。
6. 无规则分章：导入无章节规则长 TXT（>10000 字），切长度后重进目录按新长度分章（1b，验证后需清目录缓存重解析）。
7. 备份恢复回归：勾选「忽略阅读配置」恢复备份，本机阅读设置不被覆盖。

---

## 七、遗留/待验证（实现前必查）

1. **clickImgWay 的图片 action 字段**：参考版 `ReadBookController.kt:679-694` 依赖 `image.action`（书源解析产物）；我方 Rust 正文解析是否保留该字段未核实（`grep rust 0`），实现 1b 前先以在线书实测，缺失则首期只接「禁用/预览」两档并如实标注。
2. **keepLight 的 iOS 侧**：无对应 API（iOS 需 `isIdleTimerDisabled`，可顺带做但原版/参考版均无 iOS 基准，建议只做 Android+灰字）。
3. **1a 中 reader_menu_panel.dart 与 1b 竖条同文件**：排期上 1a 先合并，1b 基于其上改。
4. 批9a 若先行落地「预下载数」接线，其改动在 `reader_notifier.dart`（1a/1b 均不触该文件），无冲突。

编写：调研员 ｜ 2026-10-31
