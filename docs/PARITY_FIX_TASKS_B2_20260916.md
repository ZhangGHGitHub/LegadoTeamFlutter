# 批 2 修复任务书（B2-C1 / B2-C2）

> 依据：SCREEN_1TO1_PARITY_LEDGER_20260914.md「批 2 差异登记」；基准 `docs/parity_shots/ref_batch2/`（含用户手动补采）。
> 设备：MuMu Test `192.168.1.19:5555`（adb=`D:/leidian/LDPlayer9/adb.exe`；断连先 connect；禁 android-emulator MCP）。串行派发；每批独立版本+双日志+实机截图（屏独有元素断言防错态）+ commit 不 push。

## B2-C1 发现域（版本 2.0.264+265 → 2.0.265+266）
1. 2-1【P1】**发现页源卡改单列列表行**：图标+源名+右箭头（对齐 ref 01_discover），分组 chips 行保留；点击展开行为不变。
2. 2-5 书单页细差：卡片补评分/热度行（若数据可取）；筛选漏斗按开启态着色（默认非实心）。
3. 2-3 复核：确认展开区对「chips 型源」渲染与 ref 03/12 一致（若差异属源数据类型，登记即可）。
**验证**：analyze/test/release 装机；截图 ours_<版本>/{01_discover,06_booklist,03_discover_expand}；台账同步。

## B2-C2 源管理域（版本顺延 +1）
1. 2-7【P2】书源管理：顶栏补**常显搜索框**（对齐 ref 08）；行右补**勾选圈**（保留开关与 ⋮）。
2. 2-8【P2】书源编辑器：表单改**扁平单列**结构（字段/顺序对齐 ref 09，分组卡取消或扁平化）。
3. 2-9【P2】替换净化编辑器：同上扁平化（对齐 ref 10：名称/分组/匹配规则/替换为/标题·内容 chips/正则/范围）。
4. 2-10【P3】Web 服务卡片化（图标+绿 accent 大卡）。
5. 2-2 由主代理修正采集断言后重采，本批不动代码。
**验证**：同 C1 规程；截图 {07_source_switch(回归),08_source_manage,09_source_editor,10_replace_rule_edit,12_web_service}。

编写者：Qoder ｜ 2026-09-16
