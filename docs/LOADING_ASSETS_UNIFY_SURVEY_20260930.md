# 统一加载动画与图片素材调研报告（STAGE-R-P43UNIFY）

- 日期：2026-09-30 ｜ 作者：调研员（只读调研，未改任何代码/文档，除本报告）
- 范围：我方 `flutter_legado/`（工作仓）；参考版 `legado-with-MD3/`（只读视觉基准）；原版 Android `app/src/main/`（语义/素材交叉核对）
- 方法：全量 grep（指示器 107 处 / 74 文件）+ 分类抽样 25 个代表点 + 参考版逐件取证 + 素材 md5 比对

---

## 结论摘要（先看这里）

1. **我方加载指示器主体是「标准散用」**：74 文件、circular 家族 96 处中 89 处为标准（裸用 49 + 仅 `strokeWidth: 2` 38 + 显式 primary 1 + 封装组件内部 1，颜色均走主题槽 `primary`）+ `.adaptive()` 3 处，**无主题偏离**；真正硬编码颜色的只有 `reader_comic_screen.dart`（`2245`/`2399` 两行环 + `1769-1810` 骨架块，漫画阅读器固定深底 + 灰圈）。
2. **主代理预盘点有一处需更正**：参考版**并非**「未发现统一 Loading 封装」——参考版有专门组件目录 `progressIndicator/`，三件套封装 `AppCircularProgressIndicator`（默认 4dp 环、双引擎 Miuix/MD3、支持确定性 `progress`）/ `AppLinearProgressIndicator` / `AppContainedLoadingIndicator`（MD3 Expressive），被 39 个文件引用。我方统一的目标形态应**含封装层**，不是裸组件。
3. **我方已有 4 个自造/对齐组件**（`Md3LoadingIndicator` 波浪环、`SkeletonBox` 系列 shimmer、`ContainedLoadingIndicator`、`TopNetworkLoadingBar`），形态与参考版/HapeLee 签名一致（注释可证），**属于刻意对齐行为，勿误改**；缺的是「统一入口」把 74 文件散用的裸组件收拢。
4. **图片素材**：我方 `assets/images/default_book_cover.jpg` 与原版 `res/drawable/image_cover_default.jpg` **md5 完全一致**（已字节级对齐）；原版/参考版共有 `image_loading_error.png`（图片错误占位图）**我方未拷贝**，代码用 `Icons.broken_image`/`Icons.image` 代替（3 处）；我方 `assets/icons/` 8 个底栏 SVG **lib 内零引用**（疑似遗留，删除前须用户确认）。
5. **量级**：加载动画统一 = **M**（74 文件 110 行机械接线 + 偏离点裁决，组件 80% 已存在）；图片素材统一 = **S**（拷 1 张图 + 3 处替换 + SVG 清理确认）。合计 **M**，建议 4 批（资产先行、高频屏次之、设置页收尾、阅读器特例单独裁决）。

---

## 一、我方（flutter_legado）加载指示器用法全分类

> 全量实测：`grep -rnE "CircularProgressIndicator\(|LinearProgressIndicator\("` → **107 行**，另有 `.adaptive()` 3 行不在该基线内（括号紧跟 `.adaptive`），**circular 家族合计 96 行 + linear 14 行 = 110 行**，分布于 74 个 `.dart` 文件（screens 54 + widgets 20）。
>
> 93 行圆形指示器的互斥分桶（逐行核验）：裸用 49 + 同屏 `strokeWidth: 2` 39 + 多行带参 5 = 93；多行带参 5 行为 `audio_screen.dart:533`、`reader_comic_screen.dart:2399`、`toc_screen.dart:1035`、`contained_loading_indicator.dart:46`（组件内部）、`explore_book_list.dart:287`。

### 1.1 标准用法（主题槽自动着色，无硬编码）——计数 89/96（circular 家族）

| 形态 | 计数 | 代表点（file:line） |
|---|---|---|
| 裸用 `CircularProgressIndicator()`（含 `const`，默认 primary） | 49 | `audio_screen.dart:281`、`auto_task_screen.dart:208`、`bookmark_screen.dart:58`、`rule_sub_screen.dart:223/253/339/386/442`、`rss_screen.dart:523`、`video_screen.dart:581/590`、`webdav_settings_screen.dart:343`、`search_content_screen.dart:515`、`source_login_screen.dart:127`、`help_screen.dart:169` |
| 仅 `strokeWidth: 2`（细环，颜色仍主题槽；其中 `reader_comic_screen.dart:2245` 同行加硬编码色，归 §1.2） | 38 | `bookshelf_screen.dart:1099`、`bookshelf_manage_screen.dart:257`、`about_screen.dart:224`、`cache_settings_screen.dart:339`、`change_cover_screen.dart:138`、`explore_screen.dart:607`、`font_screen.dart:268`、`settings_screen.dart:232/348`、`theme_config_screen.dart:2015/2097`、`rss_source_edit_screen.dart:538/575`、`webview_login_screen.dart:253`、`classic_login_dialog.dart:373`、`rss_group_manage_dialog.dart:220`、`replace_rule_group_manage_dialog.dart:217`、`book_source_group_manage_dialog.dart:222`、`verification_code_listener.dart:249`、`auto_task_debug_dialog.dart:202`、`reader/read_aloud_bar.dart:508` 等 |
| 显式 `color: cs.primary`（=默认，语义标注） | 1 | `toc_screen.dart:1035`（16px 小环，注释「对齐参考版 LOADING 态 16dp 转圈形态」） |
| 封装组件内部实现（`ContainedLoadingIndicator`，色默认 primary 可传参） | 1 | `contained_loading_indicator.dart:46` |

抽样点（覆盖书架/详情/搜索/漫画/视频/音频/阅读器/设置/对话框共 25 处）均确认：**色来自 `Theme.of(context).colorScheme.primary`（MD3 参数化色板 `lib/src/theme/md3_colors.dart`），无 `valueColor`/`backgroundBorder` 定制**（grep `valueColor` 仅命中 `custom_progress.dart:34` 与 `reader_comic_screen.dart:1798` 两处 linear）。

### 1.2 偏离用法（重点）——4 行硬编码/传色 + 3 行 `.adaptive()`

| 偏离 | 位置 | 性质 |
|---|---|---|
| 硬编码 `Color(0xFF666666)` 环 + `0xFF1A1A1A` 深底 | `reader_comic_screen.dart:2245`、`2399` | 漫画阅读器固定深色底（`1500` 行 `Colors.black`），圈内自洽；**但偏离参考版**（参考版漫画加载用主题色环，见 §2.1-5） |
| 骨架占位硬编码暗色 `0xFF2A2A2A`/`0xFF666666`/`0xFF888888`/`0xFF444444` | `reader_comic_screen.dart:1769-1810`（`_buildImageLoadingPlaceholder`）、`1815-1839`（`_buildImageErrorPlaceholder`） | 同上；参考版漫画图片错误用 `image_loading_error.png`（§2.4） |
| `color: onPrimaryContainer`（24px，FAB 底 primaryContainer 上） | `audio_screen.dart:533`（注释「MD3 Batch 5」） | **刻意行为，保留**（原硬编码白色改主题槽，方向正确） |
| `colorScheme.onSurfaceVariant` 18px 灰环 | `explore_book_list.dart:287` | 列表行内弱化环；参考版列表加载用 `AppContainedLoadingIndicator`（`LoadMoreFooter.kt:181`）→ **裁决点**（可保留灰环或换 Contained） |
| `.adaptive()` 3 处 | `welcome_config_screen.dart:140`、`change_chapter_source_sheet.dart:310/366` | Flutter 自适应风格（Windows 变体），参考版无对应 → 建议换标准环统一 |

### 1.3 LinearProgressIndicator 使用场景——14 处

**确定性进度（`value:` 指定，属数据反馈、非「加载动画」，统一时保留）**：

| 位置 | 场景 | 色 |
|---|---|---|
| `book_grid_item.dart:134`、`book_list_item.dart:121` | 书封底部阅读进度条（对标原版 `pb_read_progress`，2dp） | 主题 primary + 25%/20% 透明底 |
| `search_screen.dart:311` | 搜索顶部进度条（x/y，2dp） | 默认主题 |
| `cache_download_screen.dart:201` | 缓存下载进度 | 默认主题 |
| `import_screen.dart:601` | 导入进度 | 默认主题 |
| `audio_screen.dart:435` | 播放器进度（3dp） | 默认主题 |
| `reader_comic_screen.dart:1795` | 漫画页脚下载进度（120px，带 % 文本） | **硬编码 0xFF666666**（§1.2） |
| `export_dialog.dart:470` | 导出进度 | 默认主题 |
| `custom_progress.dart:31` | `CustomProgress` 组件（**全仓无调用方，疑似死代码**） | 主题 primary |

**indeterminate（顶栏/列表加载条）**：`change_source_screen.dart:989`、`browser_screen.dart:316`、`list_footer.dart:130`（`TopNetworkLoadingBar`，对标 Android RefreshProgressBar）、`change_chapter_source_sheet.dart:301`、`search_content_screen.dart:534`。

### 1.4 自造动画（非 Material 标准组件的加载形态）

| 组件 | 位置 | 形态 | 使用点 |
|---|---|---|---|
| `Md3LoadingIndicator` | `lib/src/widgets/md3_loading_indicator.dart:12` | **波浪环**（半径正弦调制+呼吸，3600ms；减少动画时退化为静态 240° 弧）；注释标注「对齐 Compose M3 Expressive LoadingIndicator 视觉签名 / UI_MD3_PLAN 参考风格目标」 | `loading_indicator.dart:25`（页面级统一入口）、`loading_overlay.dart:45`（全局遮罩）、`dict_dialog.dart:129/131` |
| `SkeletonBox` / `GridSkeletonItem` / `ListSkeletonItem` | `lib/src/widgets/skeleton.dart:24` | **shimmer**（1200ms LinearEasing，`surfaceContainerHighest→High` 渐变扫过）；注释「对齐 HapeLee SkeletonPlaceholders」 | `bookshelf_screen.dart:486/494`、`book_info_screen.dart:395`、`explore_screen.dart:145`、`explore_book_list.dart:175`、`search_screen.dart`（builders） |
| `ContainedLoadingIndicator` | `lib/src/widgets/contained_loading_indicator.dart:9` | 48dp 容器（surfaceContainer 全圆角）+ 内置 3dp primary 环；注释「对齐 Compose M3 Expressive ContainedLoadingIndicator / P4 高频小 spinner 统一入口」 | `list_footer.dart:39/76`、`empty_state.dart:68`（isLoading 分支） |
| `TopNetworkLoadingBar` | `lib/src/widgets/list_footer.dart:123` | 顶栏 2dp indeterminate 条 | `book_info_screen_builders.part.dart:179`、`explore_book_list.dart:227` |
| `LoadingIndicator` / `LoadingOverlay` | `loading_indicator.dart:11` / `loading_overlay.dart:9` | 居中波浪环+文案 / 全局模糊遮罩 | 页面级加载统一入口 |
| 纯文字「加载中...」 | `lib/src/l10n/app_strings.dart:27`（`AppStrings.loading`） | 无动画，配 spinner 使用 | 各屏消息位 |

> 结论：**我方加载形态谱系 = 标准环（88）+ 波浪环 + shimmer + Contained + 顶栏条 + 文字**，无 Lottie、无自转圈/三点脉冲类散点。自造件全部有「对齐参考仓签名」的注释依据，属授权 expressive 风格。

### 1.5 图片加载占位（CachedNetworkImage 自绘 placeholder）

| 位置 | 加载中形态 | 错误形态 |
|---|---|---|
| `lib/src/widgets/book_cover.dart:63/292-297`（**书封主组件**） | `assets/images/default_book_cover.jpg` 静态图（`_defaultCover()`） | 同左（placeholder 与 errorWidget 同为默认封面） |
| `change_cover_screen.dart:115-140` | 底色 `surfaceContainerHighest` + 24px 标准环（strokeWidth 2） | `errorWidget` 回落 `BookCover`（默认封面） |
| `rss_articles_screen.dart:180-198` | 底色 + 20px 标准环 | 纯色块 + 图标 |
| `rss_article_detail_screen.dart:441-452` | 底色 + 标准环 | `SizedBox.shrink()` |
| `reader_image_dominant_body.dart:164-172` | `SizedBox` + 标准环 | 底色块 |
| `rss_screen.dart:381-403` `_buildPlaceholderIcon` | **源名称首字母 + iOS 风柔和填充底**（favicon 不可取的自造占位） | 同左 |
| `explore_screen.dart:476-483` | 中性 24dp 圆角占位图标（台账已登记数据差异） | 同左 |
| `reader_comic_screen.dart:1744-1753` | 自绘骨架（§1.2 硬编码暗色） | 自绘错误块 + 重试按钮 |
| `verification_code_listener.dart:208`、`theme_config_screen.dart:1912` | `Image.network` 裸用（登录验证码/图标预览） | 无 errorBuilder |

**书封占位结论**：我方 = 静态默认封面图（对标原版 `image_cover_default.jpg`）；参考版 = 代码绘制 `Icons.Default.Book`（secondary 色）+ 用户可配置默认封面相册（§2.2），**两家形态不同**（图片占位 vs 图标占位），属既有对齐决策（`9ebc9cd62e`「默认书籍封面对齐原版」），不建议改回图标形态。

---

## 二、参考版（legado-with-MD3）对应形态取证

### 2.1 指示器封装与参数（抽样 10 屏）

**统一封装三件套**（`app/src/main/java/io/legado/app/ui/widget/components/progressIndicator/`）：

- `AppCircularProgressIndicator.kt:14` — `modifier / progress: Float? = null / strokeWidth: Dp = 4.dp`；Miuix 引擎走 `MiuixCircularProgressIndicator`，否则标准 MD3 `CircularProgressIndicator`（确定性用 `progress = { progress }`）。**色全部走主题槽，无硬编码。**
- `AppLinearProgressIndicator.kt:11` — 同双引擎结构。
- `AppContainedLoadingIndicator.kt:13` — MD3 Expressive `ContainedLoadingIndicator` / Miuix `InfiniteProgressIndicator`。

抽样屏（39 文件全量 grep `AppCircularProgressIndicator|CircularProgressIndicator(`）：

| # | 屏 | 位置 | 参数形态 |
|---|---|---|---|
| 1 | 书架 | `BookshelfScreen.kt:1512` | 默认（4dp 主题色） |
| 2 | 详情 | `BookInfoScreen.kt:2090` | 默认 |
| 3 | 关于 | `AboutScreen.kt:280` | 默认 |
| 4 | 漫画（overlay） | `MangaReaderOverlays.kt:754` | 裸 `CircularProgressIndicator()`（MD3 默认色） |
| 5 | 漫画（页脚） | `MangaReaderScreen.kt:1636` | **确定性** `progress = progress/100f` + 白字 % 文本，黑 45% 遮罩 16dp 圆角卡 |
| 6 | 搜索 | `SearchScreen.kt:893` | 确定性（ContentQualityPipeline 批处理） |
| 7 | 听读 | `ReadAloudCapsule.kt:345` | **特例**：40dp 盒 + 2dp 环（`mutedColor` + track 25%）+ 中心 Close 按钮，环即进度 |
| 8 | 引导 | `OnboardingScreen.kt:156` | 28dp 尺寸 |
| 9 | 登录 | `SourceLoginSheets.kt:76` | 裸 `CircularProgressIndicator()` |
| 10 | 目录 | `TocScreen.kt:1191` | `AppContainedLoadingIndicator` 20dp（LOADING 态） |

**与我方对照**：我方 88 处标准散用 ↔ 参考版「封装 + 默认参数」；我方 toc 16px 环（`toc_screen.dart:1035`，注释已声明对齐）↔ 参考版 20dp Contained；我方 `strokeWidth: 2` ↔ 参考版默认 4dp（**线宽口径差异**，统一时按参考版 4dp 或保持 2dp 二选一，建议随封装统一为 4dp 默认、特例传参）。

### 2.2 书封占位（CoilBookCover）

- `CoilBookCover.kt:177-190`：加载中（`showLoadingPlaceholder=true` 且未加载完）→ **`Icon(Icons.Default.Book)`，`tint = colorScheme.secondary`，35% 尺寸居中**（代码绘制图标，非图片素材）。
- `CoilBookCover.kt:114-124` + `BookCover.kt:66-100`：无封面/失败 → 用户配置的 `defaultCover/defaultCoverDark` 相册随机图（seed 哈希），未配置时回落 `R.drawable.image_cover_default`。
- `BookshelfCover.kt:111`：`isUpdating` → 封面底部 `AppLinearProgressIndicator`（`height(3.dp)`，横向内缩 4dp）——**与我方书封阅读进度条同语义**（我方 2dp `book_grid_item.dart:134`）。

### 2.3 空态形态（EmptyMessage）

- `EmptyMessage.kt:31-100`：**颜文字 7 面池**（`(；′⌒`) (つ﹏⊂) (•̀ᴗ•́)و (๑•́ ₃ •̀๑) (눈‸눈) (ಥ﹏ಥ) (｡•́︿•̀｡)`，32sp）+ `AnimatedTextLine` 文案（labelMediumEmphasized，宽 240dp）+ `SmallTonalButton`；`isLoading` 分支 → `AppContainedLoadingIndicator()`（`AnimatedContent` 过渡，:61）。全仓 26 屏使用。
- **我方 `empty_state.dart` 已逐字对齐**（同 7 面池、`kaomoji` 分支、`isLoading` → `ContainedLoadingIndicator`，:68）→ 空态无需改动。

### 2.4 图片错误素材

`image_loading_error.png`（`res/drawable/`）：`ImageProvider.kt:39`（阅读器错误 bitmap）、`VerificationCodeDialog.kt:91` / `PhotoSheet.kt:57` / `PhotoDialog.kt:61`（Coil `.error()`）。**我方未拷贝此素材**，对应 3 处以 `Icons.broken_image`/`Icons.image` + 硬编码灰代替（§1.5）。

### 2.5 特色动画（Compose 代码 + AVD）

- `SkeletonPlaceholders.kt`（home 模块）：shimmer 1200ms LinearEasing，`surfaceContainerHighest→High→Highest` —— **与我方 `skeleton.dart` 参数逐项相同**（刻意对齐，注释可证）。
- AVD `ic_media_play_anim.xml`（play/pause 路径 morph，300ms）+ `ic_media_pause_anim.xml`；经 `res/values/drawables.xml:5-6` 别名 `play_anim/pause_anim` 引用，**未见 .kt 直接调用方**（低优先级）。`res/anim` 5 件进出场（readbook top/bottom in/out、anim_none）——我方路由转场已在 `lib/src/routes.dart:426`（分层转场时长）对齐，不涉素材。

---

## 三、图片素材清单对照

### 3.1 我方 `flutter_legado/assets/` 图片类素材（实测 9 个）

```
assets/images/default_book_cover.jpg   51572 B（唯一图片）
assets/icons/ic_bottom_books_e.svg  ic_bottom_books_s.svg
assets/icons/ic_bottom_explore_e.svg  ic_bottom_explore_s.svg
assets/icons/ic_bottom_person_e.svg   ic_bottom_person_e.svg
assets/icons/ic_bottom_rss_feed_e.svg ic_bottom_rss_feed_s.svg   （8 个 SVG，Material 图标矢量，fill=currentColor）
```

- `default_book_cover.jpg` **md5 `f93986f8…11ce0` = 原版 `app/src/main/res/drawable/image_cover_default.jpg` 完全一致**（字节级对齐，提交 `9ebc9cd62e`）。
- **8 个 `ic_bottom_*.svg` 在 `lib/` 全仓零引用**（`grep -rn "ic_bottom"` 无命中；`bottom_bar_skin_screen.dart` 走 file_picker 导入 zip 皮肤，不用内置 SVG）。pubspec 声明了 `assets/icons/` → **疑似遗留素材，删除属「超范围删除」红线，须用户裁决后处理**。

### 3.2 代码内 fallback 图标/占位

| 图标 | 位置 | 用途 |
|---|---|---|
| `Icons.image` | `reader_comic_screen.dart:1786` | 漫画加载骨架块 |
| `Icons.broken_image` | `reader_comic_screen.dart:1824/2280` | 漫画图片加载失败 |
| `Icons.article_outlined` | `reader_top_bar.dart:261` | 阅读器顶部菜单（非加载，保留） |

### 3.3 原版/参考版对应素材与可拷贝性

| 素材 | 原版 `res/drawable`（196 件） | 参考版 `res/drawable`（231 件） | 处置建议 |
|---|---|---|---|
| `image_cover_default` | `.jpg` 51572B | **`.png`**（同名改格式） | 我方已持 jpg 原件，**无需动作** |
| `image_loading_error.png` | 6933B | 同名存在 | **可直接拷贝**（原版或参考版均 1 图，png 6.8KB）→ 替换 §3.2 两处 broken_image + 验证码图错误位 |
| `image_legado.png` | 7656B | 存在 | 应用图标类，我方自有渠道，不动 |
| 179 个 `ic_*.xml` 矢量 | 有 | 有 | **无需转换**：均为 Material 图标，我方 `material_symbols_icons`（pubspec:40）等价覆盖 |
| shape 类（`bg_gradient_cover.xml`、`transparent_placeholder.xml`、`fastscroll_*.xml` 等） | 有 | 有 | Flutter 无 shape 资源通道；等价物已是代码（BoxDecoration/Container），**矢量 XML→SVG 转换无必要** |
| AVD `ic_media_*_anim.xml` | 无 | 有（2 件） | Flutter 无 AVD 运行时；如需等价用 `AnimatedPathPainter`/PathTween 重绘。参考版自身调用链也仅别名引用，**建议暂不迁** |
| `res/anim` 进出场 | 5 件 | 6 件 | 已由 `routes.dart:426` 分层转场对齐，不涉素材 |

---

## 四、统一方案建议（量级评估）

### 4.1 加载动画统一

**目标形态 = 参考版**：三件套封装（`AppCircular/AppLinear/AppContained`）+ 主题槽 MD3 primary，默认 4dp 环、确定性走 `progress` 参数；我方既有 expressive 件（`Md3LoadingIndicator` 波浪环 / `SkeletonBox` shimmer / `ContainedLoadingIndicator`）**保留**（对齐 HapeLee/UI_MD3_PLAN 签名，属授权风格），作为封装内部件或并列件。

改动清单：

1. 新增/扩展统一入口（约 1 个文件）：`AppLoadingIndicator` 三件套（circular 默认 4dp / linear / contained），内部按场景路由到 `CircularProgressIndicator` 或既有 `Md3LoadingIndicator`。
2. 74 文件 96 行 circular 家族接线到封装：裸用 49 + `strokeWidth: 2` 39 + 多行带参 5（§1.1 分桶）→ 默认参数；`.adaptive()` 3 处（`welcome_config_screen.dart:140`、`change_chapter_source_sheet.dart:310/366`）→ 标准环。
3. linear 14 处：indeterminate 5 处（`change_source_screen.dart:989`、`browser_screen.dart:316`、`list_footer.dart:130`、`change_chapter_source_sheet.dart:301`、`search_content_screen.dart:534`）→ 封装；确定性 9 处**保留现形**（书封进度/搜索/播放器/导入/缓存/漫画页脚/导出）。
4. 偏离 5 点裁决（§1.2）：
   - `reader_comic_screen.dart:2245/2399/1795-1810` 硬编码暗色 → 参考版漫画加载用**主题色环**（`MangaReaderOverlays.kt:754`），建议改主题槽（读者页深底不影响；`0xFF666666` 系唯一硬编码色，改后全仓零硬编码指示器色）；
   - `audio_screen.dart:533` `onPrimaryContainer` → **保留**（MD3 Batch 5 刻意行为）；
   - `explore_book_list.dart:287` onSurfaceVariant 灰环 → **裁决点**（参考版列表加载用 Contained，可保留灰环或换 `ContainedLoadingIndicator`）；
   - `CustomProgress`（`custom_progress.dart`，全仓无调用方）→ 死代码，随统一清理（删前确认）。

### 4.2 图片素材统一

1. **拷贝** `image_loading_error.png`（原版 `app/src/main/res/drawable/`，6933B）→ `flutter_legado/assets/images/`；映射替换：`reader_comic_screen.dart:1824/2280` `Icons.broken_image` → 素材图（或保留图标+主题色，二选一）、`reader_comic_screen.dart:1786` `Icons.image` 骨架块保留（非错误态）。
2. `default_book_cover.jpg` 已字节级对齐，**零改动**。
3. `assets/icons/` 8 SVG：确认零引用后**提请用户裁决删除**（pubspec `assets/icons/` 声明同步删）——不擅自删。
4. 书封占位「静态默认封面图」（我方）vs「Book 图标」（参考版）：**维持现状**（既有对齐决策 + 原版素材同源，改回图标反而偏离原版语义）。

### 4.3 风险与特例（勿误改清单）

| 项 | 判断 | 依据 |
|---|---|---|
| 书封阅读进度条（`book_grid_item.dart:134`/`book_list_item.dart:121`） | **保留**（=参考版 `BookshelfCover.kt:111` isUpdating 条；线宽 2dp vs 参考版 3dp 可顺手对齐） | 原版 `item_bookshelf_*.xml pb_read_progress` |
| toc 16px 环（`toc_screen.dart:1035`） | **保留**（=参考版 `TocScreen.kt:1191`） | 代码注释已声明对齐 |
| `Md3LoadingIndicator`/`SkeletonBox`/`ContainedLoadingIndicator` | **保留**（对齐 HapeLee 签名，授权 expressive） | `md3_loading_indicator.dart:1-8`、`skeleton.dart:1-6`、`contained_loading_indicator.dart:1-9` 注释 |
| `audio_screen.dart:533` onPrimaryContainer | **保留**（MD3 Batch 5） | 行内注释 |
| `reader_comic_screen` 暗色占位 | **唯一真偏离**（参考版用主题色环 + `image_loading_error.png`） | §2.1-5、§2.4 |
| 空态（`empty_state.dart`） | **零改动**（颜文字池逐字同参考版 `EmptyMessage.kt:36-38`） | §2.3 |
| 8 SVG 删除 | **红线**（资产删除须用户确认，AGENTS 执行边界） | §3.1 |

### 4.4 量级与批次

- **加载动画统一：M**（74 文件/110 行机械替换 + 偏离点裁决 + 1 新封装；无架构变更、无 FFI 影响；回归面 = 74 屏加载态走查）。
- **图片素材统一：S**（拷 1 张 6.8KB png + 2-3 处替换 + SVG 裁决）。
- **合计 M。建议 4 批**：
  1. **B1（S）素材**：拷 `image_loading_error.png` + 错误占位映射替换 + `CustomProgress` 死代码清理确认；
  2. **B2（M）封装+高频屏**：三件套封装落地，接线书架/详情/搜索/发现/漫画（约 20 文件）；
  3. **B3（S）长尾**：设置页/对话框/规则/RSS 等剩余 54 文件机械接线（可脚本化 diff 复核）；
  4. **B4（S）特例**：`reader_comic_screen` 主题化 + 线宽口径（2dp→4dp）统一 + `explore_book_list` 灰环裁决落地；每批按 AGENTS 规范 patch 版本递增 + CHANGELOG + 台账回写。

---

## 附：证据索引（关键 file:line）

**我方**
- 全量 107 处：`grep -rnE "CircularProgressIndicator\(|LinearProgressIndicator\(" flutter_legado/lib`（74 文件，本报告 §1 逐行引用）
- 硬编码色：`flutter_legado/lib/src/screens/reader_comic_screen.dart:1772/1795/1797/1818/2243/2245/2397/2399/2417`
- 自造件：`flutter_legado/lib/src/widgets/{md3_loading_indicator,skeleton,contained_loading_indicator,custom_progress,loading_indicator,loading_overlay,list_footer,empty_state,book_cover}.dart`
- 素材：`flutter_legado/assets/images/default_book_cover.jpg`（md5 同原版 `app/src/main/res/drawable/image_cover_default.jpg`）；`flutter_legado/assets/icons/`（8 SVG 零引用）
- 主题槽：`flutter_legado/lib/src/theme/md3_colors.dart`（MD3 参数化色板）

**参考版**
- 封装三件套：`legado-with-MD3/app/src/main/java/io/legado/app/ui/widget/components/progressIndicator/{AppCircularProgressIndicator,AppLinearProgressIndicator,AppContainedLoadingIndicator}.kt`
- 书封：`…/widget/components/image/cover/{CoilBookCover,BookshelfCover}.kt`、`…/model/BookCover.kt:66-100`
- 空态：`…/widget/components/EmptyMessage.kt:31-100`（26 屏引用）
- 骨架：`…/ui/main/homepage/modules/SkeletonPlaceholders.kt`
- 素材：`res/drawable/{image_cover_default,image_legado,image_loading_error}.png`、`ic_media_{play,pause}_anim.xml`、`res/values/drawables.xml:5-6`、`res/anim/`

**原版**
- `legado/app/src/main/res/drawable/`（196 件）、`res/anim/`（5 件）、`layout/item_bookshelf_{grid,list}*.xml`（`pb_read_progress`）

编写者：调研员 ｜ 2026-09-30（STAGE-R-P43UNIFY 只读调研）
