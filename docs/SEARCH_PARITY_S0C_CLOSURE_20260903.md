# S0-C 双包终态对比收口报告（2026-09-03）

> 性质：P0-2 S0 双包基线的终态证据采集与 parity 判定（接续 `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` §8.6/§8.8 三轮未闭环遗留）
> 设备：emulator-5556 单机双包串行（原版 `com.legado.app.release 3.26082623` + 重构版 `io.legado.flutter_legado`，均装于 5556）
> HEAD 基线：`4fc08cb977`；夹具：`scripts/s0c_server.py`（v4）；驱动：`scripts/s0c_run_same_device.py`
> 机读证据：`docs/evidence/search_parity_20260903/s0c_report_same_device.json`（原始 dump/XML/服务器 JSONL 见 `.e2e_s0c/`，不入库）

---

## 一、结论（TL;DR）

**S0-C 集合级 parity 通过。** 同一夹具 7 源、同一关键词 `s0e`、同机串行跑到终态：

| 断言 | 原版 | 重构版 | parity |
|---|---|---|---|
| 结果集合（5 本：书甲/乙/丙/丁/戊） | ✅ 5/5 | ✅ 5/5 | ✅ 一致 |
| s5 loginCheckJs 失败源被排除（无书己） | ✅ | ✅ | ✅ |
| s6 空结果源被排除 | ✅ | ✅ | ✅ |
| s1 HTTP 302 重定向（请求对 start+final） | ✅ | ✅ | ✅ 逐源一致 |
| s2 bookUrlPattern 命中详情 / s3 不命中列表 | ✅ | ✅ | ✅ |
| s4 空列表→详情回退（书戊） | ✅ | ✅ | ✅（08-29 重构端"缺书戊"证实为列表虚拟化采集假象） |
| 第 1 页逐源请求数（s1=2 其余=1） | ✅ | ✅ | ✅ 完全一致 |
| 第 1 页逐源结果（8 done / redirected 对） | ✅ | ✅ | ✅ 完全一致 |
| 结果顺序 | 甲乙丙**戊丁** | 甲乙丙丁戊 | ⚠️ 分化（已根因化，见 §三.2） |

04-29→08-29→09-03 迁移路径：5558 双机拓扑（reverse 阻断）→ **5556 单机双包拓扑（本轮打通）**。

## 二、环境突破：单机双包拓扑

08-29 三轮攻坚卡在 5558(LDPlayer) 原版端：reverse 僵死、直连被防火墙拦、release 无 run-as。本轮盘点发现：

1. **两台模拟器均装双包**——5556 的 reverse 经 P0-3 双机 e2e 验证稳定，原版端直接在 5556 跑，5558 网络问题整体绕开；
2. **原版端分组圈定可用**——08-29 记载"分组列表不含 S0C"实为**列表未滚动**（S0C 按 ASCII 序排在全部中文系统分组之后，滚动两屏可见），圈定后 7 夹具源 ~26s 终态，无需清数据/禁用真实源；
3. **"reverse 僵死"部分为误诊**——驱动脚本崩溃时夹具服务器被连带杀死，其后一切请求 connection reset/零请求，症状与隧道僵死完全一致（F4）。服务器独立于驱动生命周期启动后未再复现。

## 三、新发现（本轮产出，非缺陷项已注明）

### 3.1 F1【P1·待修】loginCheckJs 语义分叉
- **原版**（`WebBook.kt:78`）：`analyzeUrl.evalJS(checkJs, it) as StrResponse` —— JS **返回值必须可强转 StrResponse**（返回 `result` 本身=通过；返回布尔/字符串/null → ClassCastException → 错误路径再求值仍失败 → 整源失败）。
- **重构**（`rust/legado-ffi/src/js_executor.rs` `execute_login_check_js`）：注入 `result={body(),url(),code()}` 后按**布尔谓词**判定（仅 `false`/`未登录`/`needLogin` 视为失败）。
- **实测**：谓词式夹具 `loginCheckJs='result.code() == 200'` 重构端书甲正常、原版端书甲丢失（整源失败），与源码分析吻合。
- **处置**：夹具已改为双端兼容的返回式 `if (result.code() == 200) { result } else { null }`（两端均通过）。**重构侧对齐原版"返回 StrResponse 语义 + 错误路径 code!=500 放行"待后续批次**；真实书源中谓词式写法在原版同样会失败，故该对齐属正确性修复而非兼容负担。

### 3.2 F2【P2·记录不修】搜索并发策略差异 → 完成序聚合分化
两端均按**完成序**聚合结果，但原版搜索并发约 5-6（服务器日志实证：第 7 源 s3 等 s1 释放槽位后才派发），重构端 32 并发全量派发。源数 > 并发数时完成序必然不同（本轮：原版 戊(18s) 先于 丁(20s)，重构端 全按 2/6/10/14/18s 到达序）。**与解析/聚合正确性无关**；S0-C 顺序断言按此根因化豁免，parity 以集合级 + 逐源证据为准。

### 3.3 F3【P2·已修】夹具双端兼容修正（`scripts/s0c_server.py`）
- 规则语法：纯 CSS `.book-item` 原版解析器不认（实测 0 解析结果），改 legado 经典 `class.x@attr/@text`（双端支持）；
- 延迟间隔 2s→4s（2s 间隔两轮实测顺序漂移：丙丁乙戊 / 甲丙丁戊乙），s1 的 302 final 落地请求不再计延迟，到达序=甲乙丙丁戊 稳定可复现。

### 3.4 F4【P2·记录】"reverse 僵死"误诊修正
见 §二.3。后续 e2e 驱动须将夹具服务器生命周期与驱动进程解耦（本报告已按独立进程执行）。

## 四、复现方式

```powershell
# 1. 夹具服务器（独立进程,勿随驱动退出）
python scripts\s0c_server.py --port 8091 --log .e2e_s0c\server.jsonl
# 2. 驱动（双包均须已装于同设备;分组圈定沿用上次会话状态）
python scripts\s0c_run_same_device.py --device emulator-5556
```
原版端手动机位（如自动化断言失效）：搜索页 → 更多选项 → 多分组/书源 → 滚动至 S0C 勾选 → 确认；输入 `s0e` 提交；~30s 终态后 dump 采集（结果同时出现在 text 与 content-desc 两个通道）。

## 五、台账状态变更

- **S0-C 双包基线：闭合**（集合级 parity + 逐源机器证据；顺序差异按 §三.2 根因化豁免）；
- **P0-2 S0 / P0-1.4：解除 DEFERRED**，随本报告关闭；剩余 S0-D（性能剖析）解除环境依赖,可独立排期；
- **新增待办**：F1 loginCheckJs 语义对齐（P1，Rust 侧 `execute_login_check_js`）。

编写者：Qoder ｜ 2026-09-03
