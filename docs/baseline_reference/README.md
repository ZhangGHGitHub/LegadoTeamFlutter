# Android 原版 UI 基准截图（重构前参考）

> **用途**：本目录为 UI 重构前的视觉参考基准，收录安卓原版应用全部主要界面与关键子页面的完整截图。
> 后续 Flutter 重构过程中，所有界面对齐工作均以本目录截图为视觉依据。
>
> **取证依据**：**com.legado.app.release**，版本号 **versionName=3.26073003**（本仓库构建的安卓 release 版）。
> 取证时间：2026-07-31；只读取证，未改任何代码。

## 0 环境与方法

| 项目 | 值 |
|------|-----|
| 模拟器 | 雷电 LDPlayer9 实例 emulator-5556 |
| Android 版本 | Android 9 (API 28)，x86_64 |
| 分辨率 | 720x1280 @320dpi |
| adb 路径 | D:\leidian\LDPlayer9\adb.exe |
| 基准包名 | com.legado.app.release（versionName=3.26073003） |
| 前台 Activity | MainActivity（主界面）/ ReadBookActivity（阅读器）/ SearchActivity / BookInfoActivity / ConfigActivity 等 |
| 启动命令 | `adb shell monkey -p com.legado.app.release -c android.intent.category.LAUNCHER 1` |

**取证方法**：
- 截图：设备端 `screencap -p` 后 `adb pull`
- 导航：`input tap` / `input swipe`（长按）/ `input keyevent BACK`
- 坐标：经 `uiautomator dump` 精确定位（弹出式菜单除外，dump 会将其关闭，改用估算坐标）
- 测试书籍：`test_book.txt`（548B，2 章）推送至 `/sdcard/Download/` 后经"添加本地"导入

**注意事项**：
- 取证期间曾禁用两个 Flutter 包（io.legado.flutter_legado / com.legado.legado_flutter）防止抢占前台，取证结束后已重新启用
- 底部导航 4 项坐标（720x1280）：书架(90,1230) / 发现(270,1230) / 订阅(450,1230) / 我的(630,1230)

## 1 截图清单

### 1.1 主界面（底部导航 4 Tab）

| 文件名 | 界面 | 说明 |
|--------|------|------|
| 01_bookshelf.png | 书架（空状态） | 顶栏「全部」分组+红下划线，中央灰字「书架还空着…」，底 4 图标导航 |
| 01b_bookshelf_with_book.png | 书架（有书） | 导入 test_book 后新增「本地」分组标签（全部/本地），横向书卡（封面+书名+最新章节） |
| 01c_bookshelf_menu.png | 书架三点菜单 | 更新目录/添加本地/远程书籍/添加网址/书架管理/缓存导出/分组管理/书架布局/导出书单/导入书单/日志 |
| 02_discover.png | 发现 | 内嵌「筛选发现源」框+筛选图标，空状态「当前没有发现源！」 |
| 03_rss.png | 订阅 | 4 列网格卡（方图标+标签）淡紫底，取证到 5 个订阅源 |
| 04_mine.png | 我的（上半） | 书源管理/定时任务/运行定时任务[开关]/TXT目录规则/替换净化/字典规则/主题模式 |
| 04b_mine_scrolled.png | 我的（下半，滚动后） | 主题模式/Web 服务/MCP 服务[开关]/设置标题/备份与恢复/主题设置/其它设置/其它 |

### 1.2 书籍与搜索

| 文件名 | 界面 | 说明 |
|--------|------|------|
| 05_book_detail.png | 书籍信息 | 书架长按直接进入；模糊封面背景+红徽章(201字/548b)+来源/最新/分组/目录+底栏「删除书籍」「阅读」 |
| 06_local_import.png | 本地导入 | ImportBookActivity，勾选 test_book.txt，底部「放入书架」 |
| 07_search.png | 搜索 | 内嵌框「搜索书名、作者」（左放大镜右「>」）+「搜索历史」（本会话为空） |

### 1.3 阅读器

| 文件名 | 界面 | 说明 |
|--------|------|------|
| 08_reader_text.png | 阅读器正文 | 沉浸式；章首大标题+正文两端对齐+首行缩进；微信读书绿底黑字；底细进度条「test_book 1/2 50.0%」 |
| 10_reader_menu.png | 控制菜单（点中央唤起） | 顶浮层返回+书名+菜单；左亮度滑条；底面板 4 圆形按钮+章节滑条+目录/朗读/界面/设置 |
| 11_reader_settings.png | 设置面板 | 屏幕方向/屏幕超时/隐藏状态栏/隐藏导航栏/扩展到刘海(开)/填充刘海区域 |
| 12_reader_appearance.png | 界面面板 | 字号24/字距/行距/段距滑条；翻页动画 5 选（覆盖✓/滑动/仿真/滚动/无动画）；预设色环 |
| 13_tap_zones.png | 点击区域设置 | 3x3 网格浮层：上排上一页/上一页/下一页，中排上一页/菜单/下一页，下排上一页/下一页/下一页 |

### 1.4 设置子页面

| 文件名 | 界面 | 说明 |
|--------|------|------|
| 14_theme_settings.png | 主题设置 | 切换图标/启动界面样式/沉浸式状态栏(开)/沉浸式导航栏(开)/导航栏阴影:8/字体大小:1.0/封面设置/主题列表 |
| 15_other_settings.png | 其它设置 | 语言(跟随系统)/自动刷新(关)/自动跳转最近阅读(关)/显示发现(开)/显示订阅(开)/默认主页:书架/设置本地密码 |
| 16_book_source_manage.png | 书源管理 | 搜索书源+AZ 排序+视图切换+三点菜单；空状态；底栏全选(0/0)/反选/删除 |
| 16b_book_source_help.png | 书源管理帮助 | 书源右上角标志说明（绿点/红点/无点）+分组菜单+更多菜单项说明 |
| 17_backup_restore.png | 备份与恢复 | WebDav 服务器地址/账号/密码+子文件夹:legado+设备名称:SM-S9420+同步阅读进度(开)/同步增强(关) |
| 17b_backup_webdav_help.png | WebDav 备份教程 | 坚果云配置步骤+自动备份说明（进入备份与恢复时自动弹出） |

## 2 全局视觉规范

- 顶栏深棕褐（约 #6B4F43）；强调/选中红（约 #E53935）；内容背景浅灰白（约 #F2F2F2）
- 底部导航 4 项 书架/发现/订阅/我的，**仅图标无文字标签**；选中=红色填充，未选中=灰色描边
- 顶栏白色线性图标；搜索=顶栏内嵌圆角深色框
- 中文无衬线；顶栏标题 18-20sp，列表 16sp，次灰 13-14sp；卡边距 12-16dp，圆角 8-12dp
- 设置页结构：红图标+标题+灰副标题；分组标题为红色小字

## 3 关键交互基准

- 书架：单击=继续阅读；长按=直接打开书籍信息（无中间菜单）；顶搜索=全局搜索
- 阅读器：点左 1/3=上一页、右 1/3=下一页、中央=唤/隐菜单；左右滑=翻页（默认「覆盖」动画）
- 本地导入：书架三点菜单→「添加本地」→选文件夹（自带选择器，选 Download→确认）→勾选 txt→「放入书架」
- 备份与恢复：首次进入自动弹出 WebDav 备份教程帮助页

## 4 局限与说明

- 阅读收据（READING RECEIPT）未复现：本地书首开直接进正文，收据或仅在线书/特定条件出现，基准**待补**
- 发现页无导入源，仅取证空状态；带源列表待补
- 书架仅 1 本本地书（test_book.txt，2 章）；多书网格/列表及在线书差异未覆盖
- 订阅详情页、替换净化、字典规则、定时任务等深层子页面未单独截图
- 颜色为目测近似 hex，精确值以 Android 主题资源为准

## 5 相关文档

- [docs/baseline_android/ANDROID_UI_BASELINE.md](../baseline_android/ANDROID_UI_BASELINE.md) — Android 原版界面文字基准（同版本取证）
- [docs/baseline_flutter/FLUTTER_UI_CAPTURE.md](../baseline_flutter/FLUTTER_UI_CAPTURE.md) — Flutter 版界面取证与差异记录
- [docs/UI_COMPARISON_REPORT.md](../UI_COMPARISON_REPORT.md) — UI 对比分析报告
- [docs/UI_FIX_PLAN.md](../UI_FIX_PLAN.md) — UI 修复详细计划
