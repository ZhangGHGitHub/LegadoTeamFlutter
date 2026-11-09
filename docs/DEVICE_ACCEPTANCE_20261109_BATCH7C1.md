# 批7c-1「文字处理 Sheet + 生效替换列表」设备验收报告

- 日期：2026-11-09
- 验收角色：主代理（设备验收）
- 代码基线：`b08bc2061c`（含审查回修）
- 应用版本：2.0.472+473
- APK SHA-256：`349e15c317caaabacbbf83d927a21f03e5bb3c318ba7dce5a7607944ccc43e61`
- 证据：`docs/materials_1109e/`（21 个文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 2.0.472（versionCode 473） |
| Rust | 沿用 2.0.471 的 release+quickjs `.so`（本批未改 Rust） |
| 测试数据 | `batch7a_replace.txt`；替换规则「批7c去广告」（正则：广告 → 空） |

## 二、总体结论

- 功能验收 12 项：**PASS 10 / BLOCKED 2（设备交互时序未捕获，Widget/单测覆盖）**；**P1=2（审查发现并回修）**；**P2=0**；P3=4。
- FATAL/ANR/E.flutter/overflow/E AndroidRuntime 均为 **0**（12,874 行 logcat）。
- 设备终态：`pm clear` 空书架，默认设置，可启动。

## 三、逐项结果

### A. 入口与 Sheet

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 阅读器「更多」新增「文字处理」「有效替换规则」 | PASS | `tmp_qa7c_04.png` | 菜单顺序：使用替换规则/重新分段/管理替换规则/文字处理/有效替换规则/查看目录… |
| A2 文字处理 Sheet 结构 | PASS | `tmp_qa7c_05.png` | 头部书名卡、「替换净化/内容处理」两 Tab、搜索、总开关、筛选 chips、规则列表、底部「管理替换规则」 |
| A3 筛选行 360dp 自适应 | PASS | `tmp_qa7c_14.png`、`tmp_qa7c_15.png` | 「全部/已启用/已停用」第一行、「生效」第二行换行排列，无 overflow |
| A4 内容处理页空态 | PASS | `tmp_qa7c_06.png` | 「暂无 AI 处理记录 / AI 内容处理暂未支持」，无伪造记录 |
| A5 筛选「生效」在规则停用时为空 | PASS | `tmp_qa7c_14.png` | 默认「生效」筛选显示「没有符合条件的规则」 |

### B. 规则启停与正文联动

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 行内关闭规则 → 正文即时恢复 | PASS | `tmp_qa7c_06.png` | 关闭「批7c去广告」后，背后正文由「繁體測試正文」恢复为「繁體測試广告正文」 |
| B2 重新启用 → 正文即时净化 | PASS | `tmp_qa7c_16.png` | 启用后正文再次变为「繁體測試正文」，无需切章/重开书 |
| B3 总开关/全局默认/图片书关闭态 | BLOCKED（设备） | Widget 测试 | 审查回修后生效谓词已叠加 `effectiveReplaceRuleEnabled`；设备未稳定构造「总开关关闭 + 有效列表」截图，Widget 用例覆盖 0 条+关闭提示 |
| B4 「有效替换规则」打开（禁用态） | PASS | `tmp_qa7c_07.png`、`tmp_qa7c_11.png` | 标题「本章生效 0 条」+「本章暂无生效替换规则」 |
| B5 「有效替换规则」有规则/合成项 | BLOCKED（设备） | Widget 测试 | 菜单坐标点击时序导致未稳定打开有数据的列表；Widget 用例覆盖规则/繁简/重新分段/行内 X/reload |
| B6 行内 X 禁用规则/繁简/重新分段 | BLOCKED（设备，同 B5） | Widget 测试 | 三路禁用与 reload 由 Widget 断言 |

### C. 稳定性与终态

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 崩溃/ANR/overflow | PASS | `logcat_7c.txt`（12,874 行） | FATAL=0、ANR=0、E/flutter=0、overflow=0、E AndroidRuntime=0 |
| C2 设备清理 | PASS | `tmp_qa7c_18.png` | `pm clear` 后空书架、默认设置 |

## 四、P1 问题与回修

### P1-1 拖动排序的 `order` 从未落库（Mock 假通过）

- **根因**：`updateReplaceRule` 链路没有 order 参数，Rust `update_replace_rule` 固定 `order: existing.order`；排序只在本地/Mock 列表生效，重开 Sheet 还原。
- **处置**（本批不改 FFI）：`d5f7880a91` 移除 TextProcessingSheet 的 `ReorderableListView`/拖拽手柄/`_persistOrder`，不再写无效 order；CHANGELOG/updateLog/计划改为「排序暂不可用，待 replace-rule reorder FFI 另立项」；删除假通过用例并断言无拖拽入口/order 未变。
- **登记**：既有 `replace_rules_screen` 的 moveToTop/moveToBottom 同样走无效链路，已登记 P3，待专用 FFI 一并修。

### P1-2 「生效」列表/筛选未叠加书级/全局总开关

- **根因**：Rust 实际 `replace_rules_enabled = apply && use_replace_rule_for_book`；两个 Sheet 只看 enabled+scopeContent+scope。
- **回修**：`d5f7880a91` 新增 `isReplaceRuleEffectiveForBook`（总开关 + enabled + scopeContent + pattern 非空 + scope 匹配）；EffectiveReplacesSheet 读取 `replaceEnableDefaultProvider`，关闭时 0 条并显示「本书替换净化已关闭」；TextProcessingSheet「生效」筛选同步。补全局默认 false、图片书、空 pattern 用例。

### 同批 P2（已关闭）

- Sheet 内 SnackBar 被遮挡 → 改为底部固定内联状态条；`updateReaderBookConfig`/`toggleReaderReplaceRule` 返回 bool，失败不再追加成功提示。
- `_init/_loadRules/_load` 补 mounted 守卫，快速关闭不 setState after dispose。
- scope 谓词收紧到 Rust 口径（仅空串全局、仅精确小写 global、不整体 trim、bookName 不 trim、空 pattern 过滤），补 6 组单测。
- 头部 Flexible/ellipsis、筛选 Wrap、viewInsets padding、360dp+textScaler 2.0 无 overflow。
- Sheet 关闭后仍完成正文重载（await 前捕获 notifier）。

## 五、P3 / 未覆盖边界

1. **替换规则拖动排序暂不可用**：需 replace-rule reorder 专用 FFI（或 update 可选 order）另立项；`replace_rules_screen` 的置顶/置底同样受影响。
2. **「生效」为近似口径**：启用 + scopeContent + pattern 非空 + scope 匹配；未纳入 `excludeScope`/`scopeTitle`/`scopeSource`（与当前 Rust 阅读链一致），Rust 不返回实际命中规则集合。
3. **合成项点击**仅提示「请在阅读设置中调整」，未深链到具体繁简/分段控件。
4. **内容处理页无 AI 记录**（AI 后端未接），仅空态。
5. 设备未稳定捕获「有数据的有效替换列表」与「总开关关闭提示」截图（菜单点击时序问题，非功能崩溃）；这两项由 Widget 测试覆盖。
6. 生效计数含繁简/重新分段合成项；菜单项无 N（计划已同步）。
7. 繁简 setConfig 失败在 Rust 侧被吞（既有 API 语义），UI 仍按成功处理。

## 六、设备终态

- 应用 2.0.472+473 已安装，`pm clear` 后空书架、默认设置、可启动。
- 测试书/规则未在应用内保留；`/sdcard/Download` 测试文件保留。

## 七、门禁（代码基线）

- flutter analyze 0；flutter test **5063 通过 + 1 skipped**；本批 format 0 changed。
- 未改 Rust/FFI；契约计数不变。
- 独立审查 needs changes（2 P1+3 P2）→ 回修 → 定向关闭；设备复验核心路径通过。

---

编写：ZCode 主代理 ｜ 2026-11-09
