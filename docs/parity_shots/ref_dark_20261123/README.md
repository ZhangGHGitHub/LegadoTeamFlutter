# 参考版深色基线归档（ref_dark_20261123）

> 归档日期：2026-11-23 ｜ 归档动作：`docs:` 提交（只归档素材与文档，未改产品代码）
> 目的：把此前只存在于 `.tmp/`（`.gitignore:89` 忽略）的**参考版 `io.legato.kazusa` 实机截图**转为持久化证据，解决 R43 台账「3-3 设置主页」回销依赖非持久文件的问题。

## 一、来源与采集信息

| 项 | 值 |
|---|---|
| 来源目录 | 仓库根级 `.tmp/`（未入库临时目录，本次**复制**而非移动，`.tmp/` 原件保留不动） |
| 原始采集时间 | 2026-10-01 14:15–14:21（截图状态栏时间与文件 mtime 一致，本地时区 UTC+8；对应 UTC 06:15–06:21） |
| 采集批次 | 内部批次代号 `b3`（与同批 `b3_ours_*` 我方对照帧成对采集，我方帧 14:21–14:32，本目录**只收参考版**） |
| 包名 | `io.legato.kazusa`（参考版）。同批 `b3_ours_*` 为 `io.legado.flutter_legado`（我方），**未归档** |
| 分辨率 | 1080×1920（全屏帧）；裁剪帧为局部区域 |
| 设备 | **未留证**：该批次未保留 `uiautomator dump` 与设备序列号日志，无法确认具体实例（同仓库其他批次使用 MuMu 1080×1920，仅作参考不构成断言） |
| 归属校验 | 见 §四「归属校验的强度与缺口」 |

## 二、屏号映射（按 `docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md` 43 屏口径）

### 2.1 深色帧（16×16 灰度均值 < 90，可作深色基线）

| 文件 | 屏号 | 屏名 | lum | 帧内容（目视） | 用途 |
|---|---|---|---|---|---|
| `b3_kazusa_settings.png` | **3-3** | **设置主页** | **28.1** | 「设置」大标题 + 返回圆钮；八项**纯文字行 + 右 chevron**（外观 / 高级 / 阅读界面 / 封面设置 / 下载与缓存 / 备份与恢复 / AI 设置 / 翻译设置），**无图标、无副题** | **3-3 回销主证据**（本目录存在的首要原因） |
| `b3_kazusa_my.png` | 3-1 | 我的 | 30.2 | 「我的」大标题 + ? 圆钮；Web 服务卡（含开关）、「规则」分组（书源管理 / 替换净化 / TXT 目录规则 / 字典规则 / 订阅规则…）、底栏「我的」选中态 | 3-1 我的页深色基线（顶部段） |
| `b3_kazusa_my2.png` | 3-1 / 4-4 | 我的（下滚段） | 31.3 | 设置 / 书签 / 阅读记录 / 缓存管理 / 文件管理 / 关于 / 退出 七行，**每行带前置图标 + 右 chevron** | 3-1 深色（下半段）；**4-4 关于页仅可证「入口存在」，不可作关于页本身证据** |
| `b3_kazusa_home.png` | 1-3 | 书架 | 34.6 | 「书架」大标题 + 🔍/⋮；分组 tab 未读/小说/全部/**网络未分组**（选中，下划线）；两书封面网格（斗破苍穹 998、斗罗大陆 710）；底栏「书架」选中态 | 1-3 书架深色基线 |
| `b3_kazusa_home2.png` | 1-3 | 书架（重帧） | 34.6 | 与上一帧同屏同态（md5 不同，像素级几乎一致，属重复帧） | 冗余备份，不做独立结论 |
| `b3_kazusa_appearance.png` | 3-4 / 3-5 | 设置·外观 | 30.9 | 「外观」大标题；手机形态预览；「主题模式」分段（跟随系统 / 浅色 / **深色**选中）；主题色卡行可见 4 卡（动态取色 / 草野 / **柠檬**选中 / 黑白） | 3-4 外观深色；3-5 色卡行深色形态（**仅可见前 4 卡，非全 12 卡**） |

### 2.2 浅色帧（同批对照，非深色证据）

> 用途仅限「同屏浅色对照 / 结构形态参照」。**不可**计入深色回销。

| 文件 | 屏号 | 屏名 | lum | 帧内容（目视） |
|---|---|---|---|---|
| `b3_kazusa_settings2.png` | 3-3 | 设置主页（浅色） | 241.7 | 与 `settings.png` 同结构，浅色底；证明八项纯文字行结构不随明暗变化 |
| `b3_kazusa_my3.png` | 1-6 | 搜索（浅色） | 243.3 | 「搜索」标题 + ⚙/◯/≡ 三钮 + 胶囊输入条「搜索书名、作者」+ 搜索历史（全职高手 / 重生高考前99天 / 斗罗大陆） |
| `b3_kazusa_my4.png` | 3-1 | 我的（浅色，下滚段） | 238.0 | 与 `my2.png` 同结构，浅色底（图标 + 标题 + chevron） |
| `b3_kazusa_light.png` | 3-4 | 外观（浅色） | 239.7 | 与 `appearance.png` 同结构，主题模式「浅色」选中 |
| `b3_kazusa_shelf2.png` | 1-3 | 书架（浅色） | 230.3 | 与 `home.png` 同结构，浅色底 |
| `b3_kazusa_afterback.png` | 1-3 | 书架（浅色，返回后） | 230.3 | 返回书架后的浅色帧 |
| `b3_kazusa_shelf_light.png` | **1-2** | **首页**（浅色） | 231.9 | **文件名为 shelf_light 但内容是「首页」页签**：最近阅读（斗罗大陆 / 唐家三少 / 引子 穿越的唐家三少 / 0%）、累计阅读 1 本、阅读时长 0.2 小时、今日阅读目标 0/30 分钟、WebDAV 备份入口。**浅色，不可用于 1-2 深色回销** |
| `b3_kazusa_search.png` | 1-6 | 搜索（浅色） | 244.6 | 同 `my3.png` 内容 |
| `b3_kazusa_search_focus2.png` | 1-6 | 搜索（浅色，重帧） | 244.6 | 同 `search.png` 内容 |
| `b3_kazusa_search_typed.png` | 1-6 | 搜索（浅色，已输入） | 247.4 | 输入框键入 `abcd` + 清除 ✕；「搜索历史」下显示「没有内容哦」空态 |
| `b3_kazusa_nav1.png` | 3-1 | 我的（浅色，导航测试帧） | 238.0 | 同 `my4.png` 内容 |
| `b3_kazusa_nav2.png` | 1-6 | 搜索（浅色，导航测试帧） | 244.6 | 同 `search.png` 内容 |
| `b3_kazusa_search_focus.png` | **3-3 子页** | **翻译设置**（浅色） | 244.7 | **文件名为 search_focus 但内容是「翻译设置」页**：翻译提供商（提供商 / Google Translate）、翻译选项（目标语言 / 简体中文、每块最大字符数）。证明设置主页第 8 项「翻译设置」可达且为二级页 |
| `b3_kazusa_backup.png` | 3-6 | 设置·备份与恢复（浅色） | 239.1 | 「备份与恢复」+ WebDav 设置（服务器地址 / 账号 / 子文件夹 legado / 设备名称 / 测试 WebDav 配置 / 同步阅读进度） |
| `b3_kazusa_webdav_dialog.png` | 3-6 | 备份与恢复·地址展开（浅色） | 237.7 | WebDav 服务器地址行展开，含「编辑」输入框 + 默认/确认钮 |
| `b3_kazusa_webdav_focus.png` | 3-6 | 备份与恢复·地址聚焦（浅色） | 237.3 | 同上，「编辑」框内有焦点光标 |

### 2.3 局部裁剪帧（细节量化用）

| 文件 | 尺寸 | lum | 内容 | 归属 |
|---|---|---|---|---|
| `b3_crop_kazusa_search_field.png` | 1080×210 | 242.2 | 搜索胶囊输入条（🔍 + hint「搜索书名、作者」），未聚焦 | 1-6（浅色） |
| `b3_crop_kazusa_search_focus2.png` | 1080×320 | 244.9 | 搜索胶囊输入条，未聚焦（与上帧同态） | 1-6（浅色） |
| `b3_crop_kazusa_search_typed.png` | 1080×320 | 245.6 | 搜索胶囊输入条，已输入 `abcd` + ✕ | 1-6（浅色） |
| `b3_crop_kazusa_search_focus.png` | 980×200 | 245.8 | **实为「翻译提供商」分区标题 + 卡片上缘**（非搜索框） | 3-3 子页（浅色），**文件名有误导性** |
| `b3_crop_kazusa_edit_focused.png` | 980×200 | 225.3 | WebDav「编辑」输入框，有焦点光标 | 3-6（浅色） |
| `b3_crop_kazusa_edit_unfocused.png` | 980×200 | 228.6 | WebDav「编辑」输入框，无焦点 | 3-6（浅色） |
| `b3_nav1_top.png` | 1080×500 | 236.4 | 「我的」页顶部（大标题 + ? 钮 + 设置行） | 3-1（浅色） |
| `b3_nav2_top.png` | 1080×700 | 244.1 | 「搜索」页顶部（返回 + ⚙/◯/≡ + 大标题 + 输入条） | 1-6（浅色） |

## 三、随附归属/结构 dump（非同批，见说明）

| 文件 | 原名 | 采集时间 | 包名 | 内容 | 用途 |
|---|---|---|---|---|---|
| `attribution_20260916_settings_home_sr.xml` | `.tmp/sr.xml` | 2026-09-16 21:06 | `io.legato.kazusa` | 文本序列：外观 / 高级 / 阅读界面 / 封面设置 / 下载与缓存 / 备份与恢复 / AI 设置 / 翻译设置 / 实验室 / 设置 | 证明**设置主页八项结构属参考版**（多一项「实验室」，说明该次采集的构建比 10-01 截图多一个入口） |
| `attribution_20260916_settings_home_ui_set2.xml` | `.tmp/ui_set2.xml` | 2026-09-16 20:53 | `io.legato.kazusa` | 文本序列：外观 / 高级 / 阅读界面 / 封面设置 / 下载与缓存 / 备份与恢复 / AI 设置 / 翻译设置 / 设置 | 同上，**八项与 `b3_kazusa_settings.png` 完全一致**，是最贴近的归属旁证 |
| `ref_20260914_home_dump_k0.xml` | `.tmp/k0.xml` | 2026-09-14 09:30 | `io.legato.kazusa` | 首页文本（最近阅读 / 暂无阅读记录 / 累计阅读 / 阅读时长 / 今日阅读目标 / 0 / 30 / 分钟） | 1-2 首页**浅色**结构旁证（对应 `.tmp/ref_home_menu.png` 同批） |
| `ref_20260914_home_menu_dump_k1.xml` | `.tmp/k1.xml` | 2026-09-14 09:30 | `io.legato.kazusa` | 仅「首页组件」 | 4-5 首页模块管理：证明参考版存在该入口，**但无二级页截图** |
| `ref_20260914_shelf_overflow_dump_k3.xml` | `.tmp/k3.xml` | 2026-09-14 09:58 | `io.legato.kazusa` | 远程书籍 / 添加本地 / 更新目录 / 布局设置 / 分组管理 / 添加网址 / 选择模式 / 书架管理 / 导出书单 / 导入书单 / 日志 | 1-4 书架溢出菜单：**仅 dump 无深色截图** |
| `ref_20260914_shelf_overflow_dump_menu.xml` | `.tmp/menu.xml` | 2026-09-16 21:10 | `io.legato.kazusa` | 同上（同内容重复 dump） | 同上（冗余旁证） |
| `ref_20260917_filemanager_dump_kz2.xml` | `.tmp/kz2.xml` | 2026-09-17 06:24 | `io.legato.kazusa` | 筛选 • 文件管理 / root / cache / files | 4-3 文件管理：**仅 dump 无截图** |
| `ref_20260914_home_overflow_light.png` | `.tmp/ref_home_menu.png` | 2026-09-14 09:31 | 参考版（同批 k0/k1 dump） | 首页 + 溢出菜单「首页组件」（**浅色**，lum 236.7） | 1-2 / 4-5 的浅色对照，**不可作深色证据** |

> **重要**：上表 dump **不是** 2026-10-01 `b3` 批次的产物（该批次未保留 dump）。它们的作用是①以 `package="io.legato.kazusa"` 机器属性佐证**同一屏在参考版中的存在与结构**，②为台账中原本只引用 `.tmp/xxx.xml` 的结论提供持久旁证。引用时不得声称「与截图同帧」。

## 四、归属校验的强度与缺口（必须如实记录）

**有机器校验的部分**：
- 随附 7 个 dump 全部含 `package="io.legato.kazusa"`（逐文件实测），其中 `ui_set2.xml` 的八项文本与 `b3_kazusa_settings.png` 目视内容逐项吻合。

**缺口（不可省略）**：
1. **2026-10-01 `b3` 批次本身没有 `uiautomator dump`**——`.tmp/` 内 10-01 的唯一 dump 是 `b3v2_cur.xml`，其 `package="io.legado.flutter_legado"`（**我方**），不构成本批归属证据。
2. 本批归属的支撑来自三条**间接证据**：①文件名前缀 `b3_kazusa_*` 与同批 `b3_ours_*` 成对采集（14:15–14:21 vs 14:21–14:32，时间戳连续）；②画面内容与参考版特征一致且与我方明显不同——最典型是 `settings.png` 八项**纯文字行无图标**，而我方 `b3_ours_settings.png` 为「图标 + 标题 + 副题」卡片（同一屏、同一时段、形态差异显著）；③`ui_set2.xml`（参考版，09-16）的八项文本与 `settings.png` 完全同序同文。
3. 因此**建议**：后续若需更强归属，可对参考版重采一次带 dump 的设置主页帧并覆盖本目录同名文件；在此之前，`3-3` 的判定应表述为「参考版归属有强旁证、非机器直证」。

## 五、这批证据能支持什么 / 不能支持什么

**可以支持**
- **3-3 设置主页深色基线**（`b3_kazusa_settings.png`）：八项纯文字行 + 右 chevron、无图标无副题；底色实测 `rgb(21,19,11)`（页面）/ `rgb(30,27,19)`（卡片行），lum 28.1。这是 R43 台账 3-3 行的正式证据。
- 3-1 我的、1-3 书架、3-4 外观、3-5 色卡行的**深色形态参照**（各 1–2 帧）。
- 1-6 搜索、3-6 备份与恢复、3-3 子页翻译设置、1-2 首页的**浅色结构与文案**参照。

**不能支持（防误用）**
- ❌ **1-2 首页深色**：本批仅 `shelf_light.png` 一张浅色帧（且文件名易误读为书架）。
- ❌ **1-6 搜索深色整屏**：本批全部为浅色帧；台账 1-6 的「部分回销」依据是 `parity_shots/ref_dark_20260921/07_ref_transparent_dark_search_graybg.png`（透明主题 + 注入灰底的槽位诊断帧），**不是**本目录任何文件。
- ❌ **3-6 备份与恢复深色**：本批三帧全为浅色（lum 237–239），参考侧深色仍缺。
- ❌ **4-4 关于页**：`my2.png` 只有「关于」入口行，非关于页本身。
- ❌ **4-3 / 4-5 / 1-4**：只有 dump，无截图。
- ❌ **3-5 全 12 卡**：`appearance.png` 只可见前 4 卡（动态取色 / 草野 / 柠檬 / 黑白），其余需横滑，本批未采。

## 六、文件清单（本目录全部内容）

```
README.md                                         本说明
b3_kazusa_settings.png                            ★ 3-3 深色主证据
b3_kazusa_settings2.png                           3-3 浅色对照
b3_kazusa_my.png                                  3-1 深色（顶段）
b3_kazusa_my2.png                                 3-1 深色（下滚段，含 4-4 关于入口）
b3_kazusa_my3.png                                 1-6 搜索 浅色
b3_kazusa_my4.png                                 3-1 浅色（下滚段）
b3_kazusa_nav1.png                                3-1 浅色
b3_kazusa_nav2.png                                1-6 浅色
b3_kazusa_home.png                                1-3 书架 深色
b3_kazusa_home2.png                               1-3 书架 深色（重复帧）
b3_kazusa_shelf2.png                              1-3 书架 浅色
b3_kazusa_shelf_light.png                         1-2 首页 浅色（文件名与内容不符）
b3_kazusa_afterback.png                           1-3 书架 浅色（返回后）
b3_kazusa_appearance.png                          3-4/3-5 外观 深色（可见 4 色卡）
b3_kazusa_light.png                               3-4 外观 浅色
b3_kazusa_search.png                              1-6 搜索 浅色
b3_kazusa_search_focus.png                        3-3 子页 翻译设置 浅色（文件名与内容不符）
b3_kazusa_search_focus2.png                       1-6 搜索 浅色
b3_kazusa_search_typed.png                        1-6 搜索 浅色（已输入 abcd）
b3_kazusa_backup.png                              3-6 备份与恢复 浅色
b3_kazusa_webdav_dialog.png                       3-6 地址展开 浅色
b3_kazusa_webdav_focus.png                        3-6 地址聚焦 浅色
b3_crop_kazusa_search_field.png                   1-6 输入条裁剪
b3_crop_kazusa_search_focus.png                   3-3 子页「翻译提供商」裁剪（文件名与内容不符）
b3_crop_kazusa_search_focus2.png                  1-6 输入条裁剪
b3_crop_kazusa_search_typed.png                   1-6 输入条裁剪（已输入）
b3_crop_kazusa_edit_focused.png                   3-6 编辑框裁剪（聚焦）
b3_crop_kazusa_edit_unfocused.png                 3-6 编辑框裁剪（未聚焦）
b3_nav1_top.png                                   3-1 顶部裁剪
b3_nav2_top.png                                   1-6 顶部裁剪
attribution_20260916_settings_home_sr.xml         设置主页结构 dump（kazusa，09-16）
attribution_20260916_settings_home_ui_set2.xml    设置主页结构 dump（kazusa，09-16，八项吻合）
ref_20260914_home_dump_k0.xml                     首页 dump（kazusa，09-14）
ref_20260914_home_menu_dump_k1.xml                首页组件入口 dump（kazusa，09-14）
ref_20260914_shelf_overflow_dump_k3.xml           书架溢出菜单 dump（kazusa，09-14）
ref_20260914_shelf_overflow_dump_menu.xml         书架溢出菜单 dump（kazusa，09-16，重复）
ref_20260917_filemanager_dump_kz2.xml             文件管理 dump（kazusa，09-17）
ref_20260914_home_overflow_light.png              首页 + 溢出菜单 浅色（09-14）
```

统计：PNG 31 张（深色全屏 6 / 浅色全屏 16 / 裁剪 8 / 09-14 首页溢出浅色 1）+ XML 7 份 + 本 README。

## 七、与台账的关系

| 台账 | 行 | 原引用 | 现引用 |
|---|---|---|---|
| `docs/DARK_THEME_PARITY_LEDGER_20260920.md` | 3-3（§四 表） | `.tmp/b3_kazusa_settings.png` | `docs/parity_shots/ref_dark_20261123/b3_kazusa_settings.png` |
| `docs/DARK_THEME_PARITY_LEDGER_20260920.md` | §六 2026-11-23 执行记录 | `.tmp/b3_kazusa_settings.png` | 同上 |
| `docs/LEDGER_VERIFICATION_20261123.md` | §一 关键限定 / §三 3-3 行 / §六 建议 1 / §七 改动明细 | `.tmp/b3_kazusa_settings.png` | 同上 |

同批的其他帧（3-1 / 1-3 / 3-4 / 3-5 / 1-6 / 3-6）**不改变**其原有回销结论：3-1、1-3、3-4、3-5 已有更强的 `docs/` 内证据；1-6 的深色依据仍是 `ref_dark_20260921/07_*`；3-6 参考侧深色**仍然缺**。

## 八、已知瑕疵（照实登记，供后续清理）

1. **文件名与内容不符 3 处**：`b3_kazusa_shelf_light.png` 实为**首页**（1-2）；`b3_kazusa_search_focus.png` 实为**翻译设置**（3-3 子页）；`b3_kazusa_my3.png` 实为**搜索页**（1-6）。为保持与 `.tmp/` 原名一致（便于溯源与 diff），本次**未改名**，仅在 §二 表中标注。后续若重采可考虑改名。
2. **重复帧**：`b3_kazusa_home.png` / `home2.png`（md5 不同、像素几乎一致）；`b3_kazusa_search.png` / `search_focus2.png` / `my3.png` / `nav2.png` 内容同为搜索页。全部保留（证据冗余无害），但在 §二 表中注明不做独立结论。
3. **`.tmp/` 原件未删**：本目录为副本，`.tmp/` 保持原状。`.tmp/` 仍被 `.gitignore:89` 忽略，其清理不影响本目录证据。
4. **台账原述「21 张参考版深色截图」不准确**：实测该批 `b3_kazusa_*.png` 共 22 张，其中**仅 6 张为深色**（lum<90：settings 28.1 / my 30.2 / my2 31.3 / appearance 30.9 / home 34.6 / home2 34.6），其余 16 张为浅色对照帧。3-3 之外的深色帧（3-1 / 1-3 / 3-4）虽有价值，但对应屏此前已用 `docs/` 内更强证据回销，故本批**实际只新增 3-3 一屏**，与 `LEDGER_VERIFICATION_20261123.md` 的结论一致。
5. **本目录只收参考版**：同批 `b3_ours_*`（我方 `io.legado.flutter_legado`，如 `b3_ours_settings.png` / `b3_ours_highlight.png` / `b3_ours_search.png`）**一律未归档**；台账中引用它们时仍指 `.tmp/` 原路径（已标注「未归档」）。
6. **`b3v2_*` 未归档**：10-01 14:52–14:59 的 `b3v2_*` 系列是**我方**（`b3v2_cur.xml` 实测 `package=io.legado.flutter_legado`）输入框形态对比产物，与参考版深色基线无关，不属本次归档范围。
