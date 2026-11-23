# 台账二次回销核实报告（R43 剩余 30 屏）

- 核实日期：2026-11-23
- 核实角色：调研子代理（只读调研 + 台账文档回写；**未改任何产品代码**）
- 仓库 HEAD：`6f32c2e115`（`docs: R42 阶段1 全链路接通与 R34/R41 收口登记`），分支 `master`
- 前序报告：`docs/LEDGER_VERIFICATION_20261121.md`（首轮核实，11 屏回销 / 1 屏部分 / 30 屏待办）
- 环境门禁：`flutter_legado/analysis_options.yaml` 存在；`dart analyze` → **No issues found!**（0 诊断）
- 检索面：`docs/**` 全部 6702 张图片 + **仓库根级未入库目录**（`.tmp/` 535 图、`tmp_debug/` 3057 图、`tmp_qa7a/` 108 图、`tmp_qa_4a/`、`tmp_defect_c/`）

---

## 一、结论摘要

| 口径 | 数量 |
|---|---|
| 上一轮移交的「真待办」屏数 | 30 |
| **本轮新增全量回销** | **1 屏**（3-3 设置主页） |
| **本轮新增部分回销** | **1 屏**（1-6 搜索） |
| **仍为真待办** | **28 屏** |
| 台账「❌待补采」屏行计数变化 | 30 → 28（表内 29 行含 2-10 部分态，其中 3-3/1-6 已改） |

**核心结论：上一轮「30 屏真缺」的判断基本成立，仅漏掉 1 屏完整证据（3-3）与 1 屏限定证据（1-6）。** 两者的共同特点是**证据不在 `docs/` 下**——3-3 在 gitignore 的 `.tmp/`（**已于 2026-11-23 归档，见 §4.2**），1-6 在 `docs/` 内但被首轮「透明主题 + 灰底诊断帧」的异常亮度（lum 129.2，高于 90 阈值）过滤掉。

**关键限定（不可忽略）**：
- 3-3 的证据原为 `.tmp/b3_kazusa_settings.png`（位于 `.gitignore:89` 忽略的 `.tmp/`，未入库）——**已于 2026-11-23 归档为 `docs/parity_shots/ref_dark_20261123/b3_kazusa_settings.png`**（复制非移动），现为持久化证据，见该目录 `README.md`。
- 1-6 的 `07_ref_transparent_dark_search_graybg.png` 是「透明主题 + 人为注入 128 灰背景」的 **surfaceContainerLow 槽位诊断帧**（见 `parity_shots/ref_dark_20260921/RECAPTURE_20260921.md` §2），**不是自然深色整屏基线**，只能用于文字/图标角色核对。

---

## 二、判定方法（沿用首轮口径 + 本轮扩展）

1. **亮度扫描**：`docs/**` 全部 6702 张图片按 16×16 缩略灰度均值扫描，`< 90` 判深色（与 `DARK_DELTA_20260920.md` 的 `DARK_MEAN_THRESHOLD=90` 同口径）。得 850 张候选。
2. **剔除纯黑占位图**：对 `mean == 0.0` 的图做 RGB extrema 校验，识别出 **47 张纯黑占位文件**（`extrema=((0,0),(0,0),(0,0))`），全部剔除——这些是采集失败的坏图，若按亮度会被误判为「深色证据」。
3. **剔除我方截图**：经 `DEVICE_ACCEPTANCE_*.md` 反查目录归属（`materials_1031c/1031d/1031e`、`materials_1101e/1102/1104*/1106*/1107/1109*/1110*/1112*/1113*`、`gate_evidence_2026-08-13/`、`parity_shots/ours_*|pairs_*|verify_ui_*` 等均为我方 `io.legado.flutter_legado`）。
4. **扩展检索面（本轮新增）**：上一轮只扫 `docs/**`，本轮补扫仓库根级未入库目录 `.tmp/`（535 png / 252 xml）、`tmp_debug/`（3057 图 / 3928 xml）、`tmp_qa7a/`（108 图）。
5. **归属硬校验**：对候选逐张目视核对，并用同目录 `.xml` dump 的 `package="..."` 属性做机器校验（`io.legato.kazusa` = 参考版 / `io.legado.flutter_legado` = 我方）。
6. **归属不明一律维持待办**，不做推断式回销。

---

## 三、逐屏对照表（30 屏）

> 图例：✅ 已回销 ｜ 🔄 部分回销 ｜ ❌ 仍真缺

### 第 1 批（10 屏待核）

| 屏号 | 屏名 | 状态 | 证据 | 结论 |
|---|---|---|---|---|
| 1-2 | 首页页签 | ❌ | 无参考版深色。命中项均为我方或非本屏：`materials_1031b/33_kazusa_home.png`（参考侧但内容是**书架**非首页）、`kz1_home.png`（书架）、`materials_1107/s2_08_night_home.png`（我方）。`parity_shots/ref_dark_20261123/ref_20260914_home_overflow_light.png`（原 `.tmp/ref_home_menu.png`，已归档）为参考侧**浅色**首页（lum 236.7）；同批另有 `parity_shots/ref_dark_20261123/b3_kazusa_shelf_light.png`（**文件名含 shelf 但内容实为首页**，浅色 lum 231.9） | 真缺（参考侧仅浅色） |
| 1-4 | 书架溢出菜单 | ❌ | 深色命中项均为他屏：`materials_1031b/34_kz_menu.png` 是**阅读器菜单**（非书架溢出）、`materials_1031d/*` 是我方目录页菜单、`gate_evidence/gr_*_menu.png` 是我方书源管理菜单。`parity_shots/ref_dark_20261123/ref_20260914_shelf_overflow_dump_k3.xml` + `ref_20260914_shelf_overflow_dump_menu.xml`（原 `.tmp/k3.xml` / `.tmp/menu.xml`，已归档，`package=io.legato.kazusa`）有参考侧菜单 dump（「远程书籍/添加本地/更新目录/布局设置/分组管理/添加网址/选择模式/书架管理」）但**无对应深色截图** | 真缺（仅 dump 无图，按口径不计） |
| 1-5 | 书架批量多选态 | ❌ | 命中项全为我方：`materials_1031d/01_import_selected.png`、`08_long_selected.png`、`pairs_2.0.260/05_bookshelf_select_mode_diff.png`（差分图非实机） | 真缺 |
| **1-6** | **搜索** | **🔄 部分** | **`parity_shots/ref_dark_20260921/07_ref_transparent_dark_search_graybg.png` + `.xml`**（720×1280，`package=io.legato.kazusa` 实测，文本「搜索/搜索书名、作者/搜索历史/没有内容哦」）。同屏白底对照 `06_ref_transparent_dark_search.png` | **部分回销**：仅透明主题 sCL 诊断帧，可核文字/图标角色，非整屏深色基线 |
| 1-7 | 搜索结果页 | ❌ | 命中项全为我方：`materials_1031e/10_s6_search_results.png`（我方批次验收）、`pairs_2.0.260/07_search_results_diff.png`（差分）。`.tmp/fail_07_search_results.png` 为我方失败态（lum 174，**未归档**：属我方截图） | 真缺 |
| 1-9 | 目录页 | ❌ | 命中项全为我方：`materials_1031c/14_regress_toc.png`、`materials_1031d/04~07_gbk_toc*`（批次验收） | 真缺 |
| 1-12 | 正文长按菜单 | ❌ | `kz9_longpress.png` 是**我的页**（P43 报告 §五 明确记载「未观察到文本选择工具条」）；`w2_96_longpress_menu.png`（lum 12.9）是**漫画阅读器**长按菜单（保存图片/分享图片/复制链接），非正文长按；`pairs_*/12_reader_longpress_diff.png` 为差分图 | 真缺 |
| 1-14 | 目录·书签页签 | ❌ | 无参考版深色。已归档的参考版 `k*` dump（`parity_shots/ref_dark_20261123/ref_20260914_*`）中无书签页 dump | 真缺 |
| 1-15 | 章节跳转 | ❌ | 命中项全为我方：`materials_1031d/11~15_slider_*.png`、`materials_1102/65_cleanup_sliders.png`、`materials_1301/evidence/m1_after_chapter_jump.png`（我方漫画验收） | 真缺 |
| 1-16 | 自动翻页 | ❌ | 仅 `pairs_2.0.260/16_auto_flip_diff.png`（差分图，非实机） | 真缺 |

### 第 2 批（6 屏待核）

| 屏号 | 屏名 | 状态 | 证据 | 结论 |
|---|---|---|---|---|
| 2-2 | 发现溢出菜单 | ❌ | `materials_1031d/21_discover_tab.png` 是我方发现页；`pairs_b2/*_discover_overflow_diff.png` 为差分图。参考侧 `.tmp` 有 `06b_discover_overflow_menu` 同批次浅色（`ref_20260913/06b`，lum 244.5），无深色 | 真缺 |
| 2-4 | 发现源二级页（下拉） | ❌ | 维持首轮判定：`kz8b.png` 为 chips 型源展开态。本轮补查 `.tmp` 无下拉型源深色图 | 真缺 |
| 2-5 | 发现分类书单 | ❌ | 仅 `pairs_b2/06_booklist_diff.png`（差分）。参考侧浅色见 `ref_20260913/17_booklist_with_books.png`（lum 225.2） | 真缺 |
| 2-6 | 换源/书源 | ❌ | `pairs_b2/07_source_switch_diff.png`（差分）；`verify_ui_20260922/vui_35_switch_source.png`（我方） | 真缺 |
| 2-7 | 书源管理 | ❌ | `pairs_b2/08_source_manage_diff.png`（差分）；`gate_evidence/gr_c3_*.png`（我方书源管理，lum 18.6~26.6） | 真缺 |
| 2-9 | 替换净化编辑器 | ❌ | `pairs_b2/10_replace_rule_edit_diff.png`（差分）。`tmp_qa7a/63_editor.png`（我方，lum 227.5） | 真缺 |

### 第 3 批（8 屏待核）

| 屏号 | 屏名 | 状态 | 证据 | 结论 |
|---|---|---|---|---|
| 3-2 | 阅读记录 | ❌ | 仅 `pairs_b3/02_read_record_diff.png`（差分）。已归档的参考版 `k*` dump 有参考侧「阅读记录」入口但无该页深色截图 | 真缺 |
| **3-3** | **设置主页** | **✅** | **`docs/parity_shots/ref_dark_20261123/b3_kazusa_settings.png`**（1080×1920，lum 28.1；参考版深色「设置」主页：外观/高级/阅读界面/封面设置/下载与缓存/备份与恢复/AI 设置/翻译设置 八项**纯文字行 + 右 chevron，无图标无副题**；底色 `rgb(21,19,11)` 页面 / `rgb(30,27,19)` 卡片行）。同批对照 `.tmp/b3_ours_settings.png`（浅色，带图标+副题，未归档）。归属旁证 `parity_shots/ref_dark_20261123/attribution_20260916_settings_home_ui_set2.xml`（`package=io.legato.kazusa`，八项文本逐项吻合） | **已闭环**（2026-11-23 归档入库，持久化） |
| 3-6 | 设置·备份与恢复 | ❌ | `materials_1102/58_backup_done.png`（我方）；`pairs_b3/06_backup_diff.png`（差分）。`parity_shots/ref_dark_20261123/b3_kazusa_backup.png` 为参考侧但**浅色**（lum 239.1）；同目录 `b3_kazusa_webdav_dialog.png`（237.7）、`b3_kazusa_webdav_focus.png`（237.3）亦浅色（2026-11-23 已从 `.tmp/` 归档） | 真缺（参考侧仅浅色） |
| 3-7 | 字体（Tt 入口） | ❌ | `materials_1104/m1_24~25_font13_*`、`materials_1105/m2_15~19_font*` 均为我方；参考侧字体相关见 `materials_1031b/35_kz_readcfg1.png`（阅读界面 Sheet 的 Tt 按钮，非独立字体页） | 真缺 |
| 3-8 | 朗读 | ❌ | 仅 `materials_1104c/80_bg_start_readaloud.png`（我方，lum 65.2） | 真缺 |
| 3-9 | 分组管理 | ❌ | `materials_1110d/tmp_qb13_C6_night_group.png`（我方）；`m4b_01_group.png`（我方漫画书架视频组）；`ref_01_eye_group.png` 是外观页护眼组；`pairs_b3/09_group_mgmt_diff.png`（差分） | 真缺 |
| 3-10 | 定时任务 | ❌ | 仅 `materials_1104/m1_20_auto_tasks.png`（我方，lum 22.7）。**原文「`.tmp` 有参考侧定时任务 dump（`k*.xml` 含「定时任务」）」经 2026-11-23 复核为误记**：全 `.tmp/*.xml` 中「定时任务」仅命中 `b3v2_cur.xml`，其 `package=io.legado.flutter_legado`（**我方**）；已归档的参考版 `k*` dump 均无此文案 → 参考侧该入口未取到 dump，更无深色图 | 真缺 |
| 3-11 | 高亮标注列表 | ❌ | 仅 `pairs_b3/11_highlight_diff.png`（差分，lum 4.9）。`.tmp/b3_ours_highlight.png`（我方，**未归档**：属我方截图，非参考版） | 真缺 |

### 第 4 批（6 屏待核）

| 屏号 | 屏名 | 状态 | 证据 | 结论 |
|---|---|---|---|---|
| 4-1 | TXT 目录规则 | ❌ | `materials_1031d/16_txtrule_dlg.png`（我方）；`pairs_b4/01_txt_toc_rule_diff.png`（差分） | 真缺 |
| 4-2 | 字典规则 | ❌ | `materials_1107/s1_08_dark50_dict.png`（我方容器不透明度验收）；`pairs_b4/02_dict_rule_diff.png`（差分） | 真缺 |
| 4-3 | 文件管理 | ❌ | `materials_1101e/03_filepicker.png`（我方，lum 87.2）、`materials_1102/08_file_picker_refreshed.png`（我方）；`pairs_b4/03_file_manage_diff.png`（差分）。**`parity_shots/ref_dark_20261123/ref_20260917_filemanager_dump_kz2.xml`（原 `.tmp/kz2.xml`，已归档，`package=io.legato.kazusa`）有参考版「筛选 • 文件管理」dump（root/cache/files）但无对应截图** | 真缺（仅 dump 无图） |
| 4-4 | 关于页 | ❌ | 无参考版深色。`parity_shots/ref_dark_20261123/b3_kazusa_my2.png`（原 `.tmp/`，已归档）深色我的页有「关于」入口，但非关于页本身；参考侧浅色见 `ref_20260913/02_about_page.png`（lum 241） | 真缺 |
| 4-5 | 首页模块管理二级页 | ❌ | 维持「随裁决」。`parity_shots/ref_dark_20261123/ref_20260914_home_overflow_light.png`（原 `.tmp/ref_home_menu.png`，已归档）为参考侧**浅色**首页 + 溢出菜单（含「首页组件」项），非深色二级页；`ref_20260914_home_menu_dump_k1.xml`（原 `.tmp/k1.xml`，已归档，`package=io.legato.kazusa`）有「首页组件」dump 但无深色图 | 真缺（随裁决） |
| 4-6 | 超低频深页 | ❌ | 无参考版深色 | 真缺 |

---

## 四、证据完整性问题（本轮新发现）

### 4.1 `docs/**` 内 47 张纯黑占位图（亮度扫描假阳性源）

以下文件 RGB extrema 全为 `(0,0)`，即**纯黑坏图**，但因 `mean=0.0 < 90` 会被亮度扫描误判为「深色证据」：

| 目录 | 文件 | 数量 |
|---|---|---|
| `docs/evidence/batch31/` | `A_shot_3.png`、`B1_shot_3.png`、`B2_shot_3.png`、`C1_shot_3.png`、`C2_shot_2.png`、`C3_shot_2.png`、`E_review_ch1.png`、`E_review_ch1_3.png`、`E_review_panel_3.png`、`final_shelf_3.png`、`probe_d56.png`、`probe_d56_b~d.png`、`probe_d57.png`、`release_1_home.png`、`shot_try2.png` | 17 |
| `docs/parity_shots/verify_ui_20260922/` | `d9_00_initial_state.png`、`p29b_b1_crash_dialog.png`、`p29b_b5_local_reader_menu.png`、`p29b_probe_d6.png`、`p29c_03_app_display11.png`、`p29_probe_*.png`、`probe_4619827581455741454.png`、`rf_01/02/03/06_*.png`、`sbd_diag_d7.png`、`swb_21_disp002.png`、`swd_1a_00/01_*.png`、`swd_imp0.png`、`swd_restore_boot.png`、`swd_s0/s1/s2/w2_*.png`、`vui2_20_*.png`、`vui2_sfcap_d8_new.png` | 20 |
| 其他 | `docs/evidence/batch34/sf_4619827581455741454.png`、`docs/evidence/batch39b/01_launch.png`、`docs/evidence/batch45c/ui/d_4619827293253378061.png`、`docs/materials_1101b/08_lockscreen_hold.png`、`docs/materials_1113e/b26_reader.png` | 5 |
| 参考侧（有意为之，非坏图） | `docs/parity_shots/ref_dark_20260921/bg_black_1080.png`（纯黑测试背景素材）、`_picked_light.png` | 2 |

> 前 42 张为采集失败/占位坏图，建议清理或标注；后 2 张为参考侧测试素材，属正常。

### 4.2 `.tmp/` 参考版证据未入库（关键风险，**2026-11-23 已解除**）

`.tmp/` 被 `.gitignore:89` 忽略（`git ls-files .tmp` 返回 0）。其中含参考版截图（`b3_kazusa_*.png` 系列，2026-10-01 14:15~14:21 采集），是 3-3 回销的唯一证据源。若 `.tmp/` 被清理，3-3 回销将失去证据支撑。

**已处置（2026-11-23）**：全部参考版帧已**复制**归档到 `docs/parity_shots/ref_dark_20261123/`（`.tmp/` 原件保留不动），并附 7 份 `package="io.legato.kazusa"` 的 uiautomator dump 作归属旁证；来源、采集时间、逐张屏号映射、可用/不可用边界见该目录 `README.md`。

**数量更正**：实测该批 `b3_kazusa_*.png` 共 **22 张**，其中**深色仅 6 张**（`settings` 28.1 / `my` 30.2 / `my2` 31.3 / `appearance` 30.9 / `home` 34.6 / `home2` 34.6），其余 16 张为浅色对照帧。原文「21 张参考版深色截图」的表述不准确——深色帧只有 6 张，且其中 3-1 / 1-3 / 3-4 三屏此前已用 `docs/` 内更强证据回销，故本批**实际只新增 3-3 一屏**（与 §一 结论一致）。

**归属缺口（照实登记）**：10-01 该批次本身**未保留 dump**（`.tmp/` 内 10-01 唯一 dump `b3v2_cur.xml` 的 `package` 是 `io.legado.flutter_legado`，属我方），归属依靠三条间接证据（成对命名与时间戳连续、与我方同屏形态差异显著、09-16 参考版 `ui_set2.xml` 八项文本逐项吻合）。**非机器直证**，如需更强归属应重采带 dump 的设置主页帧。

### 4.3 同名不同内容（非重复文件，避免误判）

| 文件对 | md5 | 说明 |
|---|---|---|
| `materials_1031b/33_kazusa_home.png` vs `materials_1301/evidence/kz1_home.png` | 不同 | 均为参考版书架页，但**主题套不同**：前者 tab 选中为**蓝色**下划线，后者为**黄绿**下划线 + 底栏胶囊高亮。两者可互为「不同主题套」参考，不构成重复 |

### 4.4 首轮告警复核（仍然成立）

首轮 §2.5 记录的 `materials_1301/evidence/kz*.png` 文件名与内容不符问题，本轮 md5 复核**结论不变**：

| 文件 | md5(前8) | 实际内容 |
|---|---|---|
| `kz1_home.png` | `f22422f0` | 书架（深色）✅ 与文件名相符 |
| `kz2_reader_open.png` / `kz3_reader_menu.png` / `kz4_tap_top.png` | `17b573eb`（三者相同） | **均为书架**（非阅读器/工具条） |
| `kz5_reader_settings.png` / `kz7_settings_other.png` | `a97093c5`（二者相同） | **均为发现页** |
| `kz6_settings_night.png` / `kz7b_settings_other.png` | `edebb3f4`（二者相同） | **均为发现页** |
| `kz7d_settings_other.png` / `kz7e_settings_other.png` | `8c21a142`（二者相同） | **均为发现页·霹雳书屋展开态**（本轮新目视：与 `kz8b.png` 同内容不同帧，tab 高亮为橄榄黄） |
| `kz7c_settings_other.png` | `1c0f0d05` | 发现页·未展开态 |
| `kz8_other_tab.png` | `0942cd65` | 发现页·未展开态 |
| `kz8b.png` | `e5bfa193` | 发现页·霹雳书屋展开 chips ✅ |
| `kz9_longpress.png` | `a3bc312c` | 我的页（深色）✅ |

> **本轮新增发现**：`kz7d/kz7e` 也是「发现页·霹雳书屋展开态」，与 `kz8b.png` 内容同类（可作为 2-3 的第二证据帧，但**不能**用于 2-2 发现溢出菜单或 2-5 分类书单）。

---

## 五、仍真缺 28 屏清单（可直接派单补采）

**第 1 批（9 屏）**：1-2 首页页签、1-4 书架溢出菜单、1-5 书架批量多选态、1-7 搜索结果页、1-9 目录页、1-12 正文长按菜单、1-14 目录·书签页签、1-15 章节跳转、1-16 自动翻页

**第 2 批（6 屏）**：2-2 发现溢出菜单、2-4 发现源二级页（下拉型）、2-5 发现分类书单、2-6 换源/书源弹层、2-7 书源管理、2-9 替换净化编辑器

**第 3 批（7 屏）**：3-2 阅读记录、3-6 设置·备份与恢复、3-7 字体（Tt 入口）、3-8 朗读、3-9 分组管理、3-10 定时任务、3-11 高亮标注列表

**第 4 批（6 屏）**：4-1 TXT 目录规则、4-2 字典规则、4-3 文件管理、4-4 关于页、4-5 首页模块管理二级页（随裁决）、4-6 超低频深页

> **合计核对**：9 + 6 + 7 + 6 = **28 屏** ✅

---

## 六、给下游的可执行建议

1. **已完成（2026-11-23）**：`.tmp/b3_kazusa_settings.png` 已归档为 3-3 的持久证据 → `docs/parity_shots/ref_dark_20261123/b3_kazusa_settings.png`，同批 31 张参考帧 + 7 份 dump 一并入库，登记见该目录 `README.md`（含「参考版深色设置主页，八项纯文字行无图标」）。3-3 已从「✅（证据未入库）」升级为正式闭环。
2. **1-6 的使用边界**：`07_ref_transparent_dark_search_graybg.png` 只能用于「深色下文字/图标 onSurface 角色」核对（该报告 §3 已给出 hint `#EDE6FF`、返回图标同色等实测值），**不可**作为搜索页深色整屏基线；若需整屏基线，仍应补采标准板深色搜索页。
3. **补采优先序**（参考版设备补采，归档 `docs/parity_shots/ref_dark_<YYYYMMDD>/`）：
   - 第一波（高频）：1-2 首页、1-4 书架溢出、1-6 搜索整屏、1-7 搜索结果、1-9 目录（3-3 已完成归档，无需再采）
   - 第二波（发现域）：2-2、2-4（需下拉型源）、2-5、2-6、2-7、2-9
   - 第三波（设置/长尾）：3-2/3-6/3-7/3-8/3-9/3-10/3-11、4-1~4-6
4. **证据卫生**：清理或标注 `docs/**` 下 42 张纯黑占位图（§4.1 清单），避免后续亮度扫描再次误判；`.tmp/` 中参考版证据**已于 2026-11-23 归档**（`docs/parity_shots/ref_dark_20261123/`），`.tmp/` 清理不再威胁 3-3 证据；其余 `.tmp/` 内容（`corpus/`、`dbsrc/`、`legado-master/` 等）仍属可清理的临时物，清理前请复核 `REFACTORING_ACTIVE_PLAN.md` 中的活引用。
5. **无需再核的屏**：1-12 已确认参考侧「漫画长按菜单」与「正文长按菜单」是两回事（`w2_96` 为漫画），不要再把 `w2_96_longpress_menu.png` 误当 1-12 证据。

---

## 七、台账改动明细

| 位置 | 改动 |
|---|---|
| `§一` 结论段 | 追加「2026-11-23 二次核实」段：说明检索面扩展到根级未入库目录、新增 1 屏全量 + 1 屏部分、28 屏仍真缺、`.tmp/` 未入库风险 |
| `§四` 1-6 行 | ❌待补采 → 🔄部分已补采（`07_ref_transparent_dark_search_graybg.png` + `.xml`，注明透明主题灰底诊断帧限定） |
| `§四` 3-3 行 | ❌待补采 → ✅已补采（`.tmp/b3_kazusa_settings.png`，注明 `.gitignore` 未入库缺口）→ **2026-11-23 归档后改指 `docs/parity_shots/ref_dark_20261123/b3_kazusa_settings.png`，缺口解除** |
| `§五` B-1 行 | 「30 屏 ❌待补采 + 2-10 部分 + 3-4 复验」→「28 屏 ❌待补采 + 1-6 部分 + 2-10 部分 + 3-4 复验」 |
| `§六` 执行记录末尾 | 追加 2026-11-23 条目（逐屏结论、口径扩展、三项证据完整性告警） |

未改动：`SCREEN_1TO1_PARITY_LEDGER_20260914.md`、`REMAINING_WORK_INVENTORY_20261120.md`、`REFACTORING_ACTIVE_PLAN.md`、任何产品代码/版本号/CHANGELOG。

---

## 八、2026-11-23 归档动作补记（本报告后的追加提交）

> 本节由归档批次追加，记录把 §4.2 风险实际消解的过程。**只做文件归档与文档更新，未改任何产品代码/版本号/CHANGELOG/ACTIVE_PLAN/契约。**

| 项 | 内容 |
|---|---|
| 归档目标 | `docs/parity_shots/ref_dark_20261123/`（新建） |
| 归档方式 | 从 `.tmp/` **复制**（非移动），`.tmp/` 原件全部保留 |
| 归档内容 | 参考版 PNG 31 张（深色全屏 6 / 浅色全屏 16 / 裁剪 8 / 09-14 首页溢出浅色 1）+ XML 7 份（均 `package="io.legato.kazusa"`）+ `README.md` |
| 主证据 | `b3_kazusa_settings.png`（3-3 设置主页深色，lum 28.1） |
| 归属旁证 | `attribution_20260916_settings_home_ui_set2.xml`（八项文本与截图逐项吻合）+ `attribution_20260916_settings_home_sr.xml`（同屏多一项「实验室」） |
| 顺带归档 | 台账原本只引 `.tmp/` 的 5 份 dump：`ref_20260914_home_dump_k0.xml`（1-2）、`ref_20260914_home_menu_dump_k1.xml`（4-5）、`ref_20260914_shelf_overflow_dump_k3.xml` + `_menu.xml`（1-4）、`ref_20260917_filemanager_dump_kz2.xml`（4-3）；另 `ref_20260914_home_overflow_light.png`（原 `.tmp/ref_home_menu.png`） |
| 结论变更 | **3-3 由「✅（证据未入库）」升级为持久化闭环**；其余屏结论不变（1-6 仍为部分回销、3-6/4-4 等仍真缺） |
| 数据更正 1 | 该批 `b3_kazusa_*.png` 实测 **22 张**，深色仅 **6 张**（原报告「21 张参考版深色截图」表述不准确）；本批实际新增回销仍只有 3-3 一屏 |
| 数据更正 2 | §三 3-10 行原述「`.tmp` 有参考侧定时任务 dump（`k*.xml` 含「定时任务」）」**为误记**：全 `.tmp/*.xml` 中「定时任务」仅命中 `b3v2_cur.xml`，其 `package=io.legado.flutter_legado`（我方） |
| 文档同步 | `docs/DARK_THEME_PARITY_LEDGER_20260920.md` 的 §一 追加归档段、§四 3-3 行改指归档路径、§六 执行记录两条改路径与张数；本文件 §一/§三/§四/§六/§七 同步 |
| 未改 | `.tmp/` 内任何文件；`flutter_legado/lib/**`；`rust/**`；版本号；CHANGELOG；`REFACTORING_ACTIVE_PLAN.md`；`docs/API_CONTRACT.md`（工作区既有改动，与本次无关） |
