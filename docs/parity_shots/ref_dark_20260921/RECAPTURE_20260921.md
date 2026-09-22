# 参考版深色三项设备重采报告（2026-09-21，Test2 并行车道）

> 设备：MuMu index 0 / 127.0.0.1:16384（SM-G9900，Android 15，override 1080x1920 @480 确认在位）
> 目标包：`io.legato.kazusa`（参考版）。本任务未触碰 `io.legado.flutter_legado` 与 `com.legado.app.release`，未触碰 Test/5554 设备。
> 取证方式：`uiautomator dump`（uiautomator 写盘后自杀 exit 139 为 ROM 已知噪声，不影响 XML 落盘）+ `exec-out screencap` + Python/PIL 像素采样 + root 读 `shared_prefs` 交叉验证。

## 0. 参考版当前配置基线（操作前，root 读 shared_prefs 原文）

`/data/data/io.legato.kazusa/shared_prefs/io.legato.kazusa_preferences.xml`：

```xml
<string name="app_theme">0</string>            <!-- 0 = 动态取色(Dynamic) = 默认主题（A2 枚举：0 动态/1 草野/2 柠檬/3 黑白/…/12 自定义/13 透明） -->
<string name="customMode">tonalSpot</string>
<string name="customContrast">Default</string>
<string name="themeMode">0</string>            <!-- 0 = 跟随系统（UI 分段：跟随系统/浅色/深色） -->
<string name="composeEngine">material</string> <!-- 标准 Material 引擎，非 Miuix -->
<string name="materialVersion">material3</string>
<string name="paletteStyle">tonalSpot</string>
```

- 系统 `settings get system ui_night_mode` = `null`（未设 → 默认亮），故「跟随系统」当时解析为浅色（页面背景实测 248,249,255）。
- **composeEngine = material** 已确认（持久化值 + 外观页「主题风格」行显示 "Material Design"，见 `04_appearance_clean_dark_mid.png/xml`）。
- 当前主题 = app_theme 0（动态取色，即默认主题），**未处于柠檬（2）主题**——即旧 04 图的柠檬污染来自当时的配置，本次基线从干净配置起采。

## 1. 项一 A3 干净基线：默认主题 + 深色「设置·外观」

**操作路径**
1. 启动 `am start -n io.legato.kazusa/io.legado.app.ui.main.MainActivity` → 书架页（空书架）。
2. 底部导航「我的」(tap 972,1822) → 页面下滚 → 点「设置」(tap 265,945)。
3. 设置页点「外观」(tap 145,564)。
4. 确认默认主题：root 读 prefs `app_theme=0`（动态取色=默认，A2 枚举 id 0）；外观页色卡行 4 可见卡「动态取色/草野/柠檬/黑白」+ 右侧可横滑（横滑至末端见「透明」，见项二）。Compose 色卡选中态不在 uiautomator 属性中，以持久化值为准（UI 侧无冲突信号）。
5. 点「主题模式」分段「深色」(tap 928,543，滚动后坐标) → prefs 复核 `themeMode` 0→2；页面即时转深色（背景 16,20,24 / 25,28,32）。
6. 页面滚回顶部，采顶部帧与中部帧。

**原始输出 / 证据**
- 顶部帧：`04_appearance_clean_dark.png` + `04_appearance_clean_dark.xml`（dump）
- 中部帧：`04_appearance_clean_dark_mid.png` + `04_appearance_clean_dark_mid.xml`（dump）
- 切深色后的即时帧：`03_ref_appearance_dark_switched.png`

**采样值（顶部帧）**
| 位置 | 值 |
|---|---|
| 页面背景 (540,450) | rgb(16,20,24) |
| 卡片/容器 (540,900) | rgb(16,20,24)（与背景同，动态深色底） |
| Compose 提示横幅底 (500,1390) | rgb(29,32,36) |
| 分段控件未选 (278/618,1742) | rgb(29,32,36) |
| 分段选中「深色」(928,1742) | rgb(158,202,252) |
| 页标题文字 (120,325) | rgb(76,80,84)（灰阶文字采样点，非纯黑） |

**判定**
- 选中态 accent = 浅蓝 (158,202,252)，**非柠檬橄榄色 (109,94,15)** → 本帧无柠檬强调色污染，可作为 A3 页面 IA 对齐的干净基线。
- Compose 提示横幅处于**默认可见**态（含「关闭」按钮 [882,1362][942,1422]），未替参考版关闭——它是页面 IA 的一部分（可关闭 GlassCard），基线如实记录默认形态。
- 注意：默认「动态取色」深色底 = 设备壁纸取色（本 MuMu 壁纸 → 蓝灰系 16,20,24），与固定主题套（如 Lemon #15130B）不同；做色值级对比时需按主题套分别对照，IA 级对比用本基线。

## 2. 项二 Transparent（透明）主题深色 sCL 等效值

**配置基线（root 读 shared_prefs 原文，`prefs_transparent.xml`）**

```xml
<string name="app_theme">13</string>          <!-- 13 = 透明（A2 枚举） -->
<string name="themeMode">2</string>            <!-- 2 = 深色 -->
<string name="composeEngine">material</string> <!-- 标准 Material 引擎（外观页「主题风格」行同步显示 Material Design） -->
<string name="materialVersion">material3</string>
<int name="containerOpacity" value="0" />      <!-- 容器不透明度 0% -->
<string name="backgroundImageNight">/storage/emulated/0/Android/data/io.legato.kazusa/files/backgroundImageNight/ae11f763b907ecaf2603fedd67a24bba.png</string>
```

**取证设计**：原夜背景为白底（05e_picked_bg.png，255,255,255），白底上「背景透现」与「不透明白盒」无法区分，故本轮用一张 **1080x1920 纯灰 (128,128,128) 背景图**（`_bg_gray_1080.png`）替换夜背景后重采。判定逻辑：若某容器槽为 sCL 且 sCL=全透明，则该槽像素 = 背景灰 128；若为半透明/不透明色，则按 `128 + α·(fg−128)` 偏移。

**证据与采样值**

| 证据 | 位置 | 采样 | 结果 |
|---|---|---|---|
| `06_ref_transparent_dark_search.png`（白底，1080x1920） | 搜索盒 [48,432][1032,576] 内 40 点（避开 hint 区 [192,474][491,535]） | 全点 | 40/40 = (255,255,255)（白底透现）；hint 文字像素 = (237,230,255) = #EDE6FF = 透明板 dark onSurface |
| `07_ref_transparent_dark_search_graybg.png`（灰底，720x1280）+ `.xml` | 盒 [32,240][688,336] 内 55 点网格（避开 hint [128,268][328,308]） | 54/55 点 | = (128,128,128)（灰底透现）；1 点 (80,290) = (224,218,240) 为左侧搜索图标抗锯齿边缘。同页顶栏 (360,60)、标题行 (360,180)、历史行 (360,440)、内容下方 (360,700) 均 = 128；返回图标 (60,60) = (237,230,255) = onSurface |
| `08_ref_transparent_dark_appearance_graybg.png`（灰底，720x1280）+ `.xml` | 「主题模式」M3 分段控件：未选段（跟随系统/浅色）各 6 点；选中段（深色）6 点；段间 gap 2 点 | 12/12、6/6、2/2 | 未选段 12/12 = (128,128,128)（**未选容器填充 = sCL 槽 = 全透明**）；选中段 6/6 = (208,208,208)；gap 2/2 = 128 |
| 同 08 页 | 页面背景 4 点、Compose 横幅卡 [64,840][560,920] 5 点 | 3/4、4/5 | 页面背景 3 点 = 128（1 点 (360,400)=208，位于某 secondaryContainer 容器行内）；横幅卡 4/5 = 128（**无容器填充**，1 点 (72,910)=(237,230,255) 为 onSurface 文字） |

**alpha 合成自检（验证灰底判定逻辑自洽）**：透明板 dark `secondaryContainer = 0xA0FFFFFF`（α=160/255≈0.6275），在 128 灰底上理论合成值 = 128 + 0.6275×(255−128) = **207.7 ≈ 208**，与选中段实测 (208,208,208) 精确吻合 → 背景确为 128、半透明白色角色合成链路无误，未选段 128 即「α=0 全透现」的强证据。

**判定**

- **参考 Transparent 深色 sCL = 0x00FFFFFF（全透明，背景透现）**：material 引擎下 M3 SegmentedButton 未选容器填充槽与 SearchBar 填充槽均为 `surfaceContainerLow`，两处实测均为背景色透现（08 未选段 12/12=128；07 盒 54/55=128；白底 06 盒 40/40=255 交叉一致）。
- **我方现值 `surfaceContainerLow = 0x00FFFFFF`（`flutter_legado/lib/src/theme/md3_colors.dart` 透明板 dark，原资源缺 sCL 按 surface=0x00FFFFFF 回补，带注释）与参考一致 → 属允许值，无需改动。**
- 旧批（`docs/A_GROUP_FINDINGS_20260920.md` 12 板表）Transparent 行记录的 `0x8F000000（设备采，运行时兜底）` 在本配置（material 引擎 + containerOpacity=0 + 夜背景图在位）**不可复现**：若 sCL=0x8F000000（α≈0.557），灰底合成应 ≈ 128−0.557×128 ≈ **56**，实测为 128。推断（标注：非实测，为一致性解释）：0x8F000000 是**背景图缺失时的运行时兜底容器色**（半透明黑，垫在默认深底上保证可读性）；本次配置夜背景图在位且容器不透明度=0，槽值即全透明。两值分属不同运行条件，不矛盾。

## 3. 项三 A6 搜索输入盒

**前提**：`composeEngine = material` 已确认（§2 配置基线 + 外观页「主题风格」行 = Material Design，非 Miuix）→ 参考版搜索盒填充槽 = `MaterialTheme.colorScheme.surfaceContainerLow`（M3 SearchBar 默认槽位，源码级对照见 `flutter_legado/lib/src/screens/search_content_screen.dart` build 头部注释 SearchBar.kt:55/:103-108/:132-138 段）。

**参考深色搜索盒填充 = sCL 槽（多点像素采样）**

| 证据 | 采样 | 结果 |
|---|---|---|
| `06_ref_transparent_dark_search.png`（白底，1080x1920） | 盒内 40 点 | 40/40 = (255,255,255)，白底透现 |
| `07_ref_transparent_dark_search_graybg.png`（灰底，720x1280） | 盒内 55 点 | 54/55 = (128,128,128) 灰底透现（1 点 = 图标 AA 边缘 (224,218,240)） |
| hint 文字（06 白底，hint 区 [192,474][491,535] 内文字像素） | 多点 | (237,230,255) = #EDE6FF = 透明板 dark **onSurface**（非 onSurfaceVariant） |
| 标准板对照（12 板表，`docs/A_GROUP_FINDINGS_20260920.md`） | 色值表 | 12 板 dark sCL 全部为深色（Lemon #1E1B13、WH #1C1B1B、GR #1A1C16、Koharu #221919、Yuuka #1B1B21、Phoebe #1E1C13、Sora #191C20、August #231917、Carlotta #22191C、Mujika #22191B、Elink #1C1B1B） |

即：material 引擎下参考**标准板深色盒 = 深色盒**（sCL 深色值）；**透明板深色盒 = 全透明盒（背景透现）**。旧批采到的浅盒 #E8E2D4（= Lemon dark onSurface，LemonColorScheme.kt:80）当时归因于「参考实例运行 Miuix 引擎的 surfaceContainer 槽」——本批 composeEngine=material 确认 + sCL 槽像素证据使其归因失效，该浅盒不再作为对齐基准。

**我方现状（`flutter_legado/lib/src/screens/search_content_screen.dart` 442-474）**

```dart
hintStyle: WidgetStatePropertyAll(isDark ? TextStyle(color: scheme.surface) : null),
backgroundColor: WidgetStatePropertyAll(
  isDark ? scheme.onSurface : scheme.surfaceContainerLow,
),
leading: Icon(Symbols.search_rounded, size: 20,
  color: isDark ? scheme.surface : scheme.onSurfaceVariant),
```

差异分析：
1. **盒填充**：`isDark ? onSurface` 在透明板 dark 渲染**不透明白盒 #EDE6FF**（onSurface=0xFFEDE6FF），与参考（全透明盒、背景透现，06/07 实测）直接矛盾；在标准板 dark 渲染不透明白盒，与参考深色盒（sCL 深色值）矛盾。
2. **hint/图标**：`isDark ? scheme.surface` 在透明板 dark 取 surface=**0x00FFFFFF（全透明）→ 不可见**；参考 hint 实测 #EDE6FF = onSurface 角色（06 hint 文字像素 (237,230,255)）。

**判定（二选一）：回退 `surfaceContainerLow`**

- `backgroundColor` 统一为 `scheme.surfaceContainerLow`，删除 `isDark` 分支：
  - 标准板：深色盒 = sCL 深色值（与 12 板 dark sCL 表逐板一致）；亮色态维持 sCL 原行为不变；
  - 透明板：盒全透明、背景透现（与参考 06/07 实测一致）。
- 附带修正（对齐参考实测角色）：hint 与 leading 图标的深色态颜色由 `scheme.surface` 改为 **`scheme.onSurface`**（透明板 dark = #EDE6FF，与参考 hint 实测一致；标准板 dark onSurface 均为浅色调，深盒上对比正确；亮色态保持框架默认 onSurfaceVariant 不变，与参考亮色行为一致）。
- 理由：① 参考 material 引擎盒填充槽 = sCL（源码槽位 + 像素双证据）；② 统一 sCL 在透明板自动退化为全透明透现、在标准板为深色盒，两条路径同时与参考一致；③ 现 onSurface 方案在透明板渲染不透明白盒，是两条路径中唯一与参考矛盾的实现；④ 代码内「[需设备重采对照]」条件（核对参考实例 composeEngine 并在深色下重采搜索盒像素）已由本批 06/07 灰/白底重采 + `prefs_transparent.xml` 满足，执行注释预定的回退分支。代码改动由后续执行代理落码，本报告仅裁定量值与方向。
