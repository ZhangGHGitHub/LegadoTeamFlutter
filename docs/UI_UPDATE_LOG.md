# Legado Flutter UI 更新日志（MD3 迁移全记录）

> 本文档汇总 `docs/UI_MD3_PLAN.md`（Material Design 3 Expressive 迁移计划）的全部执行批次与后续增强，作为 UI 轨的独立更新日志。
> 逐条技术细节见根目录 `CHANGELOG.md` 对应版本；本文档面向「一次看全 UI 变了什么」。
>
> 执行者：Qoder UI ｜ 最后更新：2026-08-31（版本 2.0.136+137）

---

## 一、批次总览（按交付顺序）

| # | 版本 | 批次 | 核心内容 |
|---|------|------|----------|
| 0 | — | 治理步骤 | UI 开发规范由 apple-ui-designer 技能切换为 Material Design 3 官方指南（AGENTS/design_system/Active Plan 三处同步，独立可回滚） |
| 1 | 2.0.110 | Batch 0 主题地基 | 12 套内置 MD3 调色板（亮/暗 47 role，生成器可复现）；M3 ThemeData 装配（Expressive 大圆角/Tonal Surface/M3 组件主题）；ios_widgets 共享组件集中改造（消费屏零改动继承）；paletteId 本地持久化；design_system.md 重写为 MD3 单一事实源 |
| 2 | 2.0.111 | Batch 1 主框架 | Material Symbols 引入（底栏四图标，选中 FILL=1）；theme_config「内置主题 ×12」网格 +「自定义主题」双区并存；Hero 封面过渡基础设施（书架↔详情） |
| 3 | 2.0.112 | Batch 2 书架/书籍域 | 12 屏 token 化收尾；书架分组 TabBar 前景 token 化；toc 滑删 onError |
| 4 | 2.0.113 | Batch 3 搜索/发现域 | 8 屏收尾；源筛选分段按钮 M3 segmented 视觉；association onPrimary |
| 5 | 2.0.114 | Batch 4 源编辑/调试域 | 16 屏收尾；js_source_edit 编辑区底色 token 化；调试日志语义色登记例外 |
| 6 | 2.0.115 | Batch 5 RSS/音视频/缓存域 | 9 屏收尾；rss 阴影 shadow token；audio FAB 加载圈 onPrimaryContainer |
| 7 | 2.0.116 | Batch 6 设置长尾 | 9 屏收尾；「我的」页去 iOS 彩色图标底（统一 MD3 tonal 容器）；app_log TabBar token 化；12×亮暗对比度复核（自动化已覆盖） |
| 8 | 2.0.117 | 收尾·验收矩阵 | 新增 md3_acceptance_matrix_test（渲染矩阵/字体缩放/触控目标/语义）；修复 2 个真实溢出（调色板卡片/error_view）；.tmp_net 清理 |
| 9 | 2.0.118 | LargeTitle | 主 Tab 根页可折叠大标题：书架（无分组 SliverAppBar.large / 有分组 pinned TabBar 头）+「我的」；发现/订阅保持原版嵌入式搜索顶栏（原版对齐红线） |
| 10 | 2.0.119 | 全量清点 | 65 屏/路由对账（无缺失页面）；修复最后的 iOS 残留（CupertinoAlertDialog×1、CupertinoPicker 弹层×2、彩色图标底×9、Colors.grey×1）；manga_config_sheet 登记为阅读器沉浸域排除 |
| 11 | 2.0.120 | 登录域原版对齐 | 无表单分支重构为内置 WebView 登录（对齐原版 WebViewLoginFragment：新增 CookieBridge 原生通道，Cookie 自动落库 loginHeader，顶栏「检测」校验，手动页降级为次级入口） |
| 12 | 2.0.121 | 加载动画 | MD3 Expressive 波浪加载指示器（正弦波调制+呼吸+相位流动，CustomPainter 自绘）；页面级加载统一接入；减少动画偏好退化静态弧 |
| 13 | 2.0.122 | 风格细节 P1+P2+P3 | 大标题 28→24dp（对齐参考 LargeTopAppBar）；移除 88 处 iOS 式行尾箭头（原版列表无行尾「>」）；设置枢纽图标 Symbols 试点（~30 种） |
| 14 | 2.0.123 | 角标翻滚动画 | 搜索来源数角标对齐参考实现（TextCard + AnimatedTextLine：数字变化向上翻滚）；新增共享组件 md3_animated_text_line |
| 15 | 2.0.124 | 参考仓库优秀设计移植 | ① 翻滚数字推广（搜索页三处计数）；② Md3FastScroller 快速滚动条（书源管理千级列表，对齐原版 FastScroller）；③ 阅读热力图（52 周打卡风格，阅读记录页默认收起区块）；④ 颜文字空态彩蛋（EmptyState kaomoji，搜索空态接入，用户授权） |
| 16 | 2.0.125 | 图标全量 Symbols 化 | 非 reader 域 73 文件、177 种图标 100% 换用 Material Symbols rounded（513 处），阅读器域按计划保留 |
| 17 | 2.0.132 | 热力图时长模式 + 应用图标 | 热力图升级双模式（按时长 = readRecordDailyList Rust 契约 / 按本数）；应用图标替换为参考仓库 legado 图标（Android 自适应全套 + Windows ico） |
| 18 | 2.0.135 | 图标三端同步原版 | 用户指令「不要猫咪图标，同步原版图标」：Android 复用原版 app/ 资产逐字节拷贝；iOS AppIcon 由原版自适应矢量渲染（自研渲染器新增线性渐变 + 双圆心圆弧采样）；Windows ico 同步重生成 |
| 19 | 2.0.136 | 切换图标功能 | 对齐原版 change_icon + 用户指令「还需要支持 iOS 换图标」：主题设置页新增入口，7 选项点选即应用——Android setComponentEnabledSetting 切换 Launcher1~6（API 26+），iOS setAlternateIconName（重启后生效），Windows 整项隐藏；原版 7 图标全同步（Android 资产逐字节复用 / iOS 渲染 78 张 PNG 入 Info.plist CFBundleAlternateIcons） |
| 20 | 2.0.138 | iOS 换图标真机 -54 修复 | 用户真机报「osstatuserror-54」：CFBundleIconFiles 无扩展名条目由系统按 Assets.car imageset 名解析，原 PNG 为 bundle 根散文件、无 imageset → 78 张全量迁入 Assets.xcassets per-size imageset（Apple 官方范式）+ pbxproj 清理；门禁加固（集成测试 assetCount==78 断言 + CI Assets.car 全量校验） |

> 附：治理提交「重构红线口径修订」（未经允许禁止新增原版不存在的功能，授权除外）随 2.0.124 批次落地。

---

## 二、主题系统（用户可见能力）

- **12 套内置主题**（主题设置 → 内置主题网格，点按即时切换）：
  纯白 wh（默认）/ 森绿 gr / 柠檬 lemon / 小春 koharu / 优香 yuuka / 菲比 phoebe /
  穹 sora / 八月 august / 卡洛塔 carlotta / 姆吉卡 mujika / 墨水 elink / 透明 transparent
- 每套 = 亮/暗 tonal 配对（47 个 M3 role，着色暗面非纯黑；elink 墨水屏纯黑例外）；
- **自定义主题完整保留**：主色调/强调色/背景色/底栏色（日/夜）+ 背景图片，与内置主题并存（自定义已应用色优先）；
- **底栏皮肤完整保留**：无皮肤 = Material Symbols，激活皮肤 = 用户图；
- 持久化：`app_palette_id`（SharedPreferences，免 FFI）；未知 id 回退纯白。

## 三、设计语言要点

| 维度 | 落地 |
|------|------|
| 字阶 | M3 type scale，跟随系统字体 |
| 圆角 | 卡片 20 / 控件 12 / 弹窗·底板 28 / 按钮 StadiumBorder |
| 图标 | Material Symbols rounded 全量（阅读器沉浸域除外） |
| 大标题 | 书架/我的可折叠 LargeTitle（展开 24dp） |
| 转场 | M3 Zoom（Android）+ 书架↔详情封面 Hero |
| 加载 | Expressive 波浪环（页面级）/ 标准 spinner（操作级） |
| 数字动效 | AnimatedTextLine 翻滚（来源数角标/搜索计数） |
| 空态 | 颜文字彩蛋（点击切换，搜索无结果页） |
| 快速滚动 | 书源管理右侧拖拽滑块 |

## 四、质量守护

- `flutter analyze` 0 issues、`flutter test` 全绿（1312+，含：12×亮暗 WCAG AA 对比度全矩阵、调色板锚点守护、关键页渲染矩阵、字体缩放边界、触控目标、各组件回归）；
- 两级模拟器验证：5556 冒烟（子代理）/ 5558 -CheckUI（用户验收），历批次均 PASSED；
- 阅读器沉浸式域（reader_screen/reader_comic/漫画配置面板）按计划保持不动；
- 数据经 Rust Bridge 获取，UI 轨全程零 rust/ 文件变更（热力图时长模式消费后端契约 `readRecordDailyList`，见 API_CONTRACT §2.12）。

## 五、已登记待办

| 项 | 状态 |
|----|------|
| Material You 动态取色 | 计划内后续批次（需 Android seed-color 平台通道） |
| P4 硬编码字号收敛字阶（~135 处） | 待用户决策（建议分批） |
| P5 可选三选（分组标题去大写/列表字重/卡片圆角 28） | 待用户决策 |
| ~~应用图标三端同步~~ | ✅ 完成（2.0.135）：全部换为原版 legado 图标——Android 原版资产逐字节复用；iOS 矢量渲染全套 19 尺寸；Windows ico 重生成 |

---

编写者：Qoder UI ｜ 2026-08-29
修订：Qoder UI ｜ 2026-08-31（iOS 应用图标待办销账，2.0.134）
修订：Qoder UI ｜ 2026-08-31（切换图标功能批次 19，2.0.136）
修订：Qoder UI ｜ 2026-08-31（iOS 换图标真机 -54 修复批次 20，2.0.138）
