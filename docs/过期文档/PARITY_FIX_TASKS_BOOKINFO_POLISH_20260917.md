# 详情页精修尾批任务书（D6/D7/D10/D11 + 菜单采集修复）

> 版本 2.0.275+276 → 2.0.276+277；基准图 `docs/parity_shots/pairs_latest/08_book_info_pair.png`（左参考右我方）。
> 设备 MuMu Test `192.168.1.19:5555`（adb=`D:/leidian/LDPlayer9/adb.exe`）。

## 四项修复
1. **D6【P2】「共 N 章｜已读/未读」左对齐**：参考=信息流内左对齐；我方=居中独立行 → 融入信息流（随在读/最新行节奏）。
2. **D7【P3】核实「分组: 无」「目录: 第X章 已读1%」两行**：grep 原版（legado-upstream 详情布局）与授权；原版有→保留/并入信息流；原版无→红线移除（先确认能力另有入口：设置分组/查看目录）。
3. **D10【P3】顶栏三钮裸图标**：参考=hero 图上裸图标（无容器底）；我方=圆形容器 → 复用书架页 `actionsStyle: plain` 机制（仅详情页）。
4. **D11【P3】⋮ 钮红色小角标溯源**：参考无 → 疑 Material Badge/未读计数误挂，非原版能力则移除。

## 采集脚本修复
`scripts/parity_capture_ours.py` 屏 11（reader_menu）唤菜单未命中：改 dump 驱动（点中心后断言菜单特征「退出阅读/全文搜索」，未命中换 y 960→1400→600 重试≤3，仍失败打印节点）。

## 验证
analyze 0；test 全过；双日志 + 台账 D6/D7/D10/D11 行；真机采 `docs/parity_shots/ours_2.0.276/{08_book_info,11_reader_menu}.png` 含断言；commit `fix(ui)` 不 push。

编写者：Qoder ｜ 2026-09-17
