# M1 菜单 UI 装机采证草稿（STAGE-QA-P43M1）

- 日期：2026-09-30
- 设备：192.168.100.62:5555（MuMu「Test测试」，SM_G9900/r9q，竖屏 1080×1920，adb over network；adb=D:/Android/platform-tools/adb.exe）
- 被测包：io.legado.flutter_legado（HEAD=11a4ea3d9a，pubspec 2.0.328+329 → 装机显示 2.0.328，本批未升版本号属预期）
- 被测书：阅文漫画《全职高手》（共 101 章）；测试起点章 ch25「预告」（p4/24）
- 纪律：不改任何生产代码；设备操作只读/可恢复（仅切主题并还原、目录跳章属阅读器自身功能）；截图与 dump 存本目录（m1_* 前缀）
- 判定方法说明：当前模型不支持图像输入，结构断言以 uiautomator dump（content-desc/bounds）+ PIL 像素采样为证据；截图为人工视觉比对素材

## 0. 冒烟（emulator_smoke_test.ps1）

- 命令：`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File D:/OH-WorkSpace/LegadoTeam/legado/scripts/emulator_smoke_test.ps1 -Device 192.168.100.62:5555`
- **结果：7 PASS / 0 FAIL，退出码 0**（原始日志 `m1_smoke_raw.log`）：
  1. 设备在线
  2. FFI content hash 校验通过（rust/scripts/verify-ffi-android.ps1 -Mode release，aarch64/x86_64 指纹一致，复用现有 .so）
  3. APK 构建成功（flutter build apk --debug，322 MB，build\app\outputs\flutter-apk\app-debug.apk）
  4. APK 安装成功（adb install -r）
  5. 已装版本与 pubspec 一致（2.0.328）
  6. 应用进程存活（pid 5649）
  7. 无崩溃日志（FATAL/E/flutter 均未检出）
- 备注：logcat 中的 "Shutdown thread" SIGSEGV 为 uiautomator 已知无害现象，不计入崩溃判定

## 1. 菜单态（浅色主题）

- 路径：书架 → 点《全职高手》封面进漫画阅读器（续读 ch25 预告 p4/24，页脚 25/101、23.9%）→ 点屏幕中央呼出菜单 → 截图+dump
- 截图+dump：`m1_reader_open.png/xml`（收起态，仅页脚）、`m1_menu_open.png/xml`（展开态，浅色）
- 顶栏三段断言（bounds 均 84–204 行）：**通过**
  - 返回键 Button [48,84][168,204]，content-desc=「返回」
  - 标题胶囊 View [216,84][864,204]，desc=书名+章名（书名 14sp + 章名 11sp alpha0.7，视觉单行省略号）；⚠ desc 中混入书籍列表污染文本（见异常 1）
  - 刷新键 Button [912,84][1032,204]，content-desc=「刷新」
- 底栏两行断言（全部以 content-desc 语义验证）：**通过**
  - Row1：上一章 Button [99,1533][219,1653] desc=「上一章」；SeekBar [306,1521][450,1665] desc=「页数 4/24」（readingPageDescription=`页数 {_visiblePageIndex+1}/$pageCount`）；下一章 Button [861,1533][981,1653] desc=「下一章」
  - Row2：目录 Button [99,1683][219,1803] desc=「目录」；自动 Button [480,1683][600,1803] desc=「自动」（自动开起后变「停止」）；翻页设置 Button [861,1683][981,1803] desc=「翻页设置」
- 滑条语义：desc=「页数 4/24」与页脚一致（p4/24）；页脚控制栏可见时上抬 148px，画面不遮挡 ✓

## 2. 交互逐项

- 2a 目录：**通过**。证据 `m1_toc_sheet.png/xml`、`m1_toc_scrolled.png/xml`、`m1_toc_row25.png/xml`、`m1_after_chapter_jump.png/xml`
  - sheet 标题 desc=「目录(101)」；章节行「序号+标题」，最新在前（1=第93话 … 9=公告！… 24=00，25=预告=当前章，26=第01话）
  - 当前章（row25 预告）高亮：像素采样背景 (236,223,220)（primaryContainer alpha0.4 底+primary 文字 w600）vs 其他行 (226,226,226)，差异成立
  - 点 row26「第01话」→ 跳章成功：页脚=「第01话 被… 页数1/50 章节26/101 总进度24.8%」（原 25/101 23.9%），sheet 自动关闭
- 2b 自动：**通过**。证据 `m1_auto_toggled.png`（ON 态截图）。desc 自动 →（tap 中央自动键）停止 →（再 tap）自动，切换语义往返正确；自动键长按=openMangaConfig（未单独点验长按）
- 2c 翻页设置：**通过**。证据 `m1_config_sheet.png/xml`。MangaConfigSheet（showModalBottomSheet，isScrollControlled）打开，desc 含「漫画设置」标题 + 阅读模式 / 翻页模式（页面适配：从上到下、全屏适配按钮）/ 自动翻页 Switch / 显示效果（灰度、电子纸）/ 色彩滤镜
- 2d 刷新：**通过**。证据 `m1_refresh_loading.png`、`m1_refresh_done.png/xml`。tap 刷新 → `_refreshChapter()` 先收起菜单（_toggleControls）再 `_loadChapterImages()`；内容缓存命中即时恢复，两帧截图 md5 相同（loading 中间帧未捕获，如实注明）；恢复后页脚/章/页状态正常，无 FATAL
- 2e 菜单收起态：**通过**。证据 `m1_menu_collapsed.png`（+ 该状态 xml 仅存页脚节点）。动画：代码 `_menuCtrl` AnimationController duration=200ms（reader_comic_screen.dart L225-227，淡入淡出）；录屏采证 `m1_anim_record.mp4`（screenrecord 3s，MuMu ROM 实际 13fps/12 帧）→ cv2 抽帧：`m1_menu_anim_mid.png`=中间帧（t≈0.62s，顶栏 alpha≈90%、底栏面板部分显现，t144=(231,231,231) vs 终态 (238,238,238)）、`m1_menu_anim_settled.png`=落定展开态；收起/展开两端点态互证 ✓

## 3. 暗色主题菜单

- 切换路径：**通过**。我的 tab → 设置页（SettingsScreen）主题模式行 → showModalBottomSheet（跟随系统/浅色/深色）→ 选「深色」→ 回书架重进阅读器（续读 ch26）→ 呼出菜单采证 → 切回「跟随系统」还原
- 截图+dump：`m1_dark_settings_page.png`（深色设置页）、`m1_menu_open_dark.png/xml`（暗色菜单展开）
- 断言：**通过**。暗色菜单结构 bounds 与浅色完全一致（顶栏三段/底栏两行/三键 desc 相同）；像素采样：标题胶囊底 (29,32,36)、底栏面板 (67,67,67)——均为暗色系，非恒黑 (0,0,0) 亦非纯白 (255,255,255)；浅色对照 (240,240,240)/(193,191,189)
- 还原验证：`m1_theme_restored.png` 设置页背景 (244,244,244)（浅色），主题已还原到初始态（跟随系统）

## 4. 结论

- **通过项（7/7）**：冒烟 / 顶栏三段 / 底栏两行（含三键语义）/ 目录 sheet（标题+高亮+跳章）/ 自动切换 / 翻页设置 sheet / 刷新重载 / 收起态+滑入动画 / 暗色主题菜单（含还原）
- **失败项**：无
- **阻塞项**：无
- 异常与环境陷阱（如实记录，均非 M1 菜单缺陷）：
  1. **章节标题数据污染（数据/源解析问题，非 UI 缺陷）**：标题胶囊 a11y desc 混入 15 个耽美书名×2 组列表。根因：阅文漫画《全职高手》章节的 chapter.title 字符串被污染源数据污染（形如「全职高手\n[书名列表×2]\n实际章节名」，真实章名在末尾，跳章后尾部随之变化）。菜单 UI 代码正确渲染 bookName+chapterName，视觉单行省略号只显示首行。建议后续在源解析/入库层清洗 chapter.title。
  2. **uiautomator dump 偶发 SIGSEGV**（Shutdown thread，exit 139）：无害但当次不写文件，用 for 循环重试（最多 5 次）规避。
  3. **MSYS 路径转换**：Git Bash 下 `/sdcard/...`、`/d/...` 被转换，全程 `export MSYS_NO_PATHCONV=1`；python 脚本参数须用 Windows 风格路径。
  4. **QA 侧误操作致章节回退（自查，非应用缺陷）**：暗色测试阶段，意图「设置页下滑找主题行」的指令（tap 324,1800 + swipe 540,1500→540,700）实际执行时仍处阅读器 → 快速上滑在 T2B 纵向分页=回退，读者 ch26(p1/50,24.8%)→ch25 预告(p1/24,23.8%)。核查 pid 5649 未变、无 FATAL/E/flutter，应用处理正确。
  5. **MangaConfigSheet 关闭路径**：scrim 仅顶部 86px 且被系统状态栏拦截（tap 540,43 无效），唯一下滑手势可关（isScrollControlled 近全屏 sheet 的共性特征）。
  6. **刷新 loading 中间帧未捕获**：内容缓存命中，恢复即时（两帧 md5 相同），未硬造 loading 证据。
