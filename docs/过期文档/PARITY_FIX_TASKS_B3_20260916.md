# 批 3 修复任务书（B3-C1 外观与主题域）

> 依据：SCREEN_1TO1_PARITY_LEDGER_20260914.md「批 3 逐项细列」；基准 `docs/parity_shots/ref_batch3/`（含 `04_appearance.png` 全页、`04_appearance_dark.png` 深色、`07_font.png` 阅读界面页）。
> 设备：MuMu Test `192.168.1.19:5555`（adb=`D:/leidian/LDPlayer9/adb.exe`；断连先 connect；禁 android-emulator MCP 工具）。效率纪律：定点读码、单屏排查≤2 分钟、汇报≤12 行。

## B3-C1（版本 2.0.266+267 → 2.0.267+268）
1. **A1【P2】外观页补「外观预览」卡**：手机模型缩略图 + 当前色卡名（对齐 ref 04 顶部；我方外观页现无该区）。
2. **A2【P2】补「配色轮」**：彩虹环 + 「长按配色轮自定义配色」提示（参考 04 中部；如自定义配色能力未实现，先做视觉呈现+长按提示登记能力缺口，不得伪功能）。
3. **A3【P2】补「导出主题/导入主题」按钮**：先 grep 我方是否已有主题导入导出能力；有则接入口，无则最小实现（导出当前配色 JSON / 导入应用）或登记缺口（二选一汇报说明）。
4. **A6【P2】外观页分区形态**：参考=每区独立圆角卡（外观预览/主题模式/配色轮/内置主题四区）；我方改分区卡结构（内置主题 12 色卡网格保留，A4/A5 已一致勿动）。
5. **M4【P2 候选】「标签规则」入口核实**：grep 原版（legado-upstream）与 `flutter_legado/lib` 中标签规则（TagRule）实现；功能存在→在「我的」页补入口；确实无实现→登记缺口不新建。
6. **N6 授权核实**：「字体（Tt 入口）」独立页——grep docs/ 与 git 历史找授权记录；无记录则登记为待裁决项（勿删勿改，交主代理汇报）。
7. 深色域：外观页深色态 `04_appearance_dark` 已有基准（ref 36.2/ours 52.3）——本批**不做**配色值对齐（属阶段D），仅保证新加区块（预览卡/配色轮/导出导入）在深浅两态正常渲染色（走主题槽位，禁硬编码）。

**验证**：analyze 0；test 全过；release 装机 MuMu 截图 `docs/parity_shots/ours_2.0.267/{04_appearance,04_appearance_dark}.png`（深色用脚本 `--only 04_appearance_dark` 像素门控）+ 台账同步 + 双日志；fix(ui) commit **不 push**。

编写者：Qoder ｜ 2026-09-16
