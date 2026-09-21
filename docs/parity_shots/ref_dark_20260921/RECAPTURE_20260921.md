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

（进行中，见后续补写）

## 3. 项三 A6 搜索输入盒

（进行中，见后续补写）
