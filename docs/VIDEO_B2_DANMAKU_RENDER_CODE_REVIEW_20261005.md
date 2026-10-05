# V-B2「视频弹幕渲染」代码审查报告

- 审查对象：`ca4b7c364c` feat(ui): 视频弹幕渲染（18 文件，+1983/-277）
- 审查基线：契约 §2.50（`82793ee669` 冻结）、§2.49（`39f6267e43`/`2c2d9a8c89`）、B1 脏值批（`60a1ab1fa6`）
- 原版语义基线：`app/src/main/java/io/legado/app/help/gsyVideo/BiliDanmukuParser.kt`、`help/gsyVideo/VideoPlayer.kt`、`model/VideoPlay.kt`（只读核对）
- 审查方式：只读 + 门禁复跑（cargo test / flutter test / flutter analyze / 真实 DLL e2e）
- 日期：2026-10-05

---

## Summary: needs changes（需修后合并）

P0 两项（切集后弹幕层监听失效、行分配无界增长）必须修复；P1 两项（同轨追尾重叠、两处偏离未登记）应修/应登记；其余为登记级与信息级。

---

## 逐项审查结论

### P0-A 确定性 Bug：弹幕层不响应 player 实例替换，切集后时间轴失联【阻塞】

- 位置：`flutter_legado/lib/src/widgets/video_danmaku_layer.dart:354`（initState 仅对初始 player addListener）、`:361-374`（didUpdateWidget 只处理 items / playbackSpeed，**不处理 player 变化**）、`:420-425`（dispose 只解绑当前 widget.player）
- 触发链（`flutter_legado/lib/src/screens/video_screen.dart`）：
  - `:332` `_loadDanmakuForChapter` 在切集时把 `_danmakuAvailable` 保持 true（相邻两集均有弹幕时的常态）→ 弹幕层**持续挂载**、State 保留；
  - `:364-367` `_startFromTarget` dispose 旧控制器；
  - `:446-477` `_initPlayer` 赋**新** `VideoPlayerController` 实例；
  - `:495` 随后 setState → 层收到 didUpdateWidget，但 `player` 身份变化被忽略 → 层仍监听**已 dispose 的旧控制器**，新控制器的事件永远收不到。
- 症状（期望 X vs 实际 Y）：
  - 期望：第 2 集起暂停冻结弹幕 / seek 重锚 / 倍速联动（对齐 `VideoPlayer.kt:156-174/:199-209/:135-141`）；
  - 实际：`_onPlayerChanged` 成为死监听。若切集时在播放，Ticker 持续跑，弹幕时钟退化为**墙钟插值**，暂停/seek 后弹幕照滚或漂移；若暂停中切集，时钟永久冻结在第 1 集锚点，第 2 集弹幕全不出现或位置错乱。
- 修复建议：didUpdateWidget 增加 `!identical(oldWidget.player, widget.player)` 分支：removeListener(旧) → addListener(新) → 用新 `widget.player.value` 重锚 `_anchorPositionMs/_clockMs/_wasPlaying/_anchorElapsed`，并按 isPlaying 启停 Ticker。
- 测试缺口：`test/widget/video_danmaku_layer_test.dart` 5 例全部单控制器，无 player 替换用例。补「替换 player 实例后时钟跟随新实例」测试（当前必红）。
- Proof：代码路径推演 + `video_screen.dart:364-386/:446-477` 与 `video_danmaku_layer.dart:361-374` 交叉核对；建议用例：挂载后 `pumpWidget` 换 host 中 player notifier 实例，断言 `debugClockMs` 跟随新实例。

### P0-B 性能：`_laneOf`/`_widthCache` 无界增长 + 行分配 O(历史总量) 扫描【阻塞（长视频性能退化）】

- 位置：`flutter_legado/lib/src/widgets/video_danmaku_layer.dart:94-96`（`_laneOf`、`_widthCache` 只增不减）、`:238-262`（`_assignLane` 每个新条目遍历 `_laneOf.entries` 全量 × 最多 5 轨）
- 机制：每条弹幕首次出现写入 `_laneOf[i]`，**过期项永不移除**；可见窗口本身有 `_scanStart` 裁剪（`:149-155`，该部分合格），但行分配的占用检查不受窗口约束。
- 量化：1 小时视频、平均 30 条/秒 → `_laneOf` 约 10 万条；每个新弹幕 `_assignLane` 最坏 5×10 万次 Map 访问，×30 条/秒 = 千万级/秒，全部发生在 UI 线程 paint（`repaint: _clockMs` 每帧触发）。几千项的中等场景即开始可感，密集长视频可卡顿。审查项「长弹幕列表是否按 timeMs 窗口裁剪」结论：**绘制窗口已裁剪，行分配数据未裁剪**。
- 修复建议：在 `_scanStart` 前移循环中同步删除 `_laneOf`/`_widthCache` 中 `key < _scanStart` 的项（items 按 timeMs 升序、index 连续前移，指针化后 O(1) 摊销）；此举同时把 `_assignLane` 扫描集缩到活跃集。回退 seek <700ms 时被 prune 项重入窗口会重新分配行号，属可接受代价（>700ms 本就全量重排）。
- 证据等级：确定性（代码结构必然），未做 1 小时真机长跑（non-claim：未实测性能曲线，量化为推算值）。

### P1-C 同轨「长后车追短前车」确定性重叠 —— 防重叠算法不完备

- 位置：`flutter_legado/lib/src/widgets/video_danmaku_layer.dart:229-256`（`occupancyEnd = start + duration × W/(width+W)`，即「尾部完全入场」即放行同轨）
- 机制：滚动速度 = `(width + W) / duration`（`:186-189` 位置式推导），**与文本宽度成正比**。前车（短）尾部刚完全入场，后车（长）即获准入同一轨；后车头部速度 > 前车尾部速度 → 追及重叠，直至前车离场。
- 复算（width=400、dur=4560ms）：前车 W=40 @t=0，尾部完全入场于 414.5ms；后车 W=160 @t=500ms 获准入轨，t≈812ms 追及，重叠约 3.7s。审查项「R2L/TOP 禁重叠是否真的防重叠」结论：**入场期成立、巡航期不成立**（等宽场景成立，异宽不成立）。
- 边界声明（missing lens）：原版 DanmakuFlameMaster 0.9.25 防重叠内部实现（YRetainer 类）源码/字节码不在本仓库，**无法核实原版是否同样只做入场期判定**。若核实为同弱性 → 只需登记偏离；若原版全程防重叠 → 需扩展判据（后车更长时占用至前车完全离场，或按追及闭式解判定）。
- 修复方向：`_assignLane` 对同轨滚动前车增加条件——后车宽度 > 前车宽度时，要求后车起始不早于前车**完全离场**时刻（保守、一行可改），或精确解 `s_f ≥ s_l + dur×Wl/(W+Wl)` 且追及点晚于前车离场。
- 测试缺口：`test/unit/video_danmaku_layout_test.dart` 全部用例等宽文本（`'AAAA'`/`'AAAAAAAA'`），异宽追尾场景零覆盖。

### P1-D 两处自报偏离「未找到」in-code 登记

- 行为核实（偏离确实存在）：
  - 底部统一防重叠：`video_danmaku_layer.dart:238-261` 对**所有类型**统一做同轨防重叠；原版 `VideoPlayer.kt:294-297` `preventOverlapping` 仅配置 `TYPE_SCROLL_RL` 与 `TYPE_FIX_TOP`，底部固定（4）原版允许重叠；
  - L2R 不限 5 行：`video_danmaku_layer.dart:224-226` laneCount 仅 R2L 取 `min(5, viewportLanes)`；原版 `maxLinesPair` 仅登记 `TYPE_SCROLL_RL=5`（`VideoPlayer.kt:287`）——此项实为**与原版一致**（原版本就未限 L2R），严格说不构成偏离，登记为「对齐说明」更准确。
- 登记核实：`video_danmaku_layer.dart` 头注释（:49-59）与 `_assignLane` 注释（:214-216）**未找到**上述两处的偏离/对齐登记文字；commit message 亦只描述「顶部/底部固定弹幕居中分列」。三处自报偏离中仅「畸形 p 跳过该行」（`rust/legado-ffi/src/api/video_api.rs:180-183/:340`）与 type7 渲染边界（`:174-176`）有明确登记。
- 修复：在 layer 头注释补两行（底部防重叠=有意偏离、L2R 无上限=对齐原版说明），或登记进契约 §2.50「原版渲染配置」段备注。

### P1-E 其余 P1 项核实结论（通过）

- **FFI 面逐条 vs §2.50**：`ffi.rs:2025-2026` 纯函数导出 `parse_video_danmaku(raw) -> Result<Option<String>, BridgeError>`，无 IO/DB（`video_api.rs:299-402` 全程无 IO 调用）；返回字段 camelCase（`timeMs/type/textSizeRaw/color/text`，serde rename `:191-198`）；失败 null 不抛；升序稳定排序（`:400` sort_by_key 稳定）。✅
- **Rust 解析语义逐条**（vs `BiliDanmukuParser.kt`）：`time=(p0 as f32*1000) as i64`（`video_api.rs:214`，含 f32 截断口径，测试 `:1020-1023` 钉死）；`color=((0xFF000000|p3)&0xFFFFFFFF) as i32`（`:218`，p3 按 i64 解析对齐 Kotlin toLong）；类型映射 1/4/5/6/7 保留、2/3/8/0/9 丢弃（`:186` + 测试 `:1037-1050`）；type7 校验 JSON 数组且 [4] 非空字符串、保留原文（`:270-288` + 测试 `:1055-1077`）；四实体解码 + SAX 一层共双重还原（`:223-257` + 测试 `:1102-1119`）；未定义实体/多根/未闭合/根前文本 → None（测试 `:1123-1160`）；合法空 XML → "[]"。空/非 XML → null 不抛。✅
- **quick-xml 依赖**：`rust/legado-ffi/Cargo.toml:33` 独立声明 `quick-xml = "0.42"`，与 `legado-book/Cargo.toml:11`、`legado-net/Cargo.toml:18` 同版本串；`Cargo.lock` 单一 `0.42.0`（本批仅 legado-ffi deps 行 +1）。未走 workspace 继承（工程 P2 项，见下）。本批 diff **无 unsafe**（仅 `frb_generated.rs` FRB 机械 codegen 内标准 unsafe）。✅
- **BookApi 293 闭合**：`flutter test test/unit/api_contract_test.dart` 全绿（8/8）——含「文档声明 BookApi 总数 == 程序化计数」「附录 296 与 §2.x 双射」「每个 BookApi 方法契约登记」。✅
- **UI 对齐**：开关文案「关弹幕/开弹幕」（`video_screen.dart:908-921`）；控制器条顺序 总时长→弹幕开关→全屏，对齐 `video_layout_controller.xml:63-88`；无弹幕时层与开关均 `if (_danmakuAvailable)` 隐藏（GONE 等价）；弹幕层位于视频之上、控制层之下（`:782-789`）。✅
- **B1 交接（`60a1ab1fa6` 脏值修复后）**：本批未改 `get_video_danmaku` 查询面；e2e（真实 DLL，`test/ffi/video_danmaku_runtime_test.dart:121-204`）覆盖 refreshToc 链（不经 meta 缓存 → 走 sink DB 兜底反查）→ 捕获落库 → 读回原文 → 幂等 → 幽灵书 null，2/2 通过。✅
- **开关语义（切集）**：`_danmakuShow` 切集不重置（`video_screen.dart:117-119`），切集仅换 items——对齐原版 `VideoPlay.kt:130`（进程态开关）+ `:137-138`（切集只清弹幕数据）。跨会话不持久，两侧一致；差异见 P2-F1。
- **JSON 健壮性**：`video_screen.dart:270-299` getVideoDanmaku/parseVideoDanmaku 双层 try/catch；`rust_api_discovery_cache.part.dart:497-516` null/非 List/单项畸形 → 整体降级 null 不崩；type7 项进渲染层后在 `video_danmaku_layer.dart:197-199` `default: continue` 不绘制。✅（单项畸形拖垮整列表的粒度问题见 P2-F5）

### P2 登记级/可选

| # | 位置 | 问题 | 建议 |
|---|------|------|------|
| F1 | `video_screen.dart:117-119` | `_danmakuShow` 为视图态 State，退出视频页重进复位 true；原版 `VideoPlay.kt:130` 为进程级 static（进程内跨页面保持） | 登记差异或提升为会话级单例 |
| F2 | `video_screen.dart:331-332` | 弹幕加载 `await` 串行插在正文与 `_startFromTarget` 之间，阻塞切集起播（DB+文件+FFI 解析延迟）；且新 items 在新控制器就绪前短暂绘制于旧画面 | `unawaited`/并行化；或起播前置空 items 对齐原版 startPlay 清空语义（`VideoPlay.kt:137-138`） |
| F3 | `video_danmaku_layer.dart:368-373` | 倍速变更只重锚时钟，不清 `_laneOf`；行占用区间按旧 duration 计算（时长变化 ±20% 内，重叠风险低）；factor clamp(0.2,3.0) 为未登记轻微偏离（原版 speed≥8.2 因子≤0） | 倍速变化时同步清 `_laneOf`；clamp 补登记 |
| F4 | `video_danmaku_layer.dart:88-92/:145` | 行高网格固定按 25 号字（×1.35），18/36/45 号弹幕纵横向与行格不匹配，大字号纵向溢出、底部行下缘可能越界（视觉级） | 登记或按条高度占格 |
| F5 | `rust_api_discovery_cache.part.dart:497-516` | 单项 JSON 畸形 → 整列表降级 null（形状有 Rust 契约保证，可接受） | 可选逐项容错 |
| F6 | `rust/legado-ffi/Cargo.toml:33` | quick-xml 未走 workspace 继承（三 crate 各自 `"0.42"`，lock 已收敛单一版本，无实际漂移风险） | 可选：迁 workspace.dependencies |
| F7（信息） | `video_api.rs:346-351` | `<d/>` 自闭合：原版 SAX 遗留 stale item，后续相邻 `<d>` 文本会错误填入前一条（原版怪癖/bug）；我方直接丢弃，行为更正确但未登记 | 建议补一行注释登记 |
| F8（信息） | `video_api.rs:362-391` | 文本多段回调：原版 fillText 后到覆盖，我方拼接——契约冻结口径（双重转义还原两层）即拼接语义，我方按契约实现且更合理；根外已定义实体原版致命、我方忽略（病态输入级） | 知悉即可 |

### 工程项核实

- FRB codegen：`frb_generated.rs`/`frb_generated.dart` 差异全部围绕 `parse_video_danmaku` 注册 + content hash，机械。✅
- 引擎解耦：`DanmakuLayoutEngine` 纯 Dart 无 widget 依赖（measureText 可注入），布局 9 例脱离 widget 运行。✅
- Ticker 泄漏：dispose 顺序 removeListener → `_ticker.dispose()` → `_clockMs.dispose()`，无泄漏。✅
- painter 复用：`repaint: _clockMs` 驱动帧重绘（不经 setState）；`shouldRepaint` 比对 engine/show/speed/dpr（`video_danmaku_layer.dart:531-537`）；engine 以 `identical(oldWidget.items, widget.items)` 判定重建（`:364`），`_danmakuItems` 由 State 持有仅在加载完成时替换，判定可靠。✅
- 逐帧绘制成本：每可见弹幕每帧创建 2 个 TextPainter 并 layout（`:519-528`），密集场景 60fps 下千次级 layout/秒，属自绘弹幕已知成本；建议后续批缓存 per-item TextPainter（未计入必须修）。

---

## 门禁复跑记录（本机 Windows，2026-10-05）

| 门禁 | 结果 |
|------|------|
| `cargo test -p legado-ffi --lib video_danmaku` | 11/11 ok |
| `flutter test`（layout 9 + widget 5 + api 5 + api_contract 8） | 27/27 ok |
| `flutter test test/ffi/video_danmaku_runtime_test.dart`（真实 DLL） | 2/2 ok |
| `flutter analyze` | No issues found |

## 证据分级与 non-claims

- P0-A/P0-B：代码路径确定性推演 + 可复算模型；**未**真机复现切集场景与 1 小时长跑（non-claim：性能量化为推算值，非实测曲线）。
- P1-C：我方模型下确定性；原版 DFM 同弱性未核实（missing lens：库源码/字节码不在仓库）。
- 本审查复跑定向 + 契约 + e2e 门禁；未复跑全量 2149 flutter test（以提交声明为准）。
- 解析器与原版逐字段核对基于 `BiliDanmukuParser.kt` 源码；DanmakuFactory 类型映射仍以提交声明的字节码核对为准（未在本仓库内复验字节码）。

## 需修项清单（编号 + 严重度）

1. 【P0】弹幕层 didUpdateWidget 处理 player 实例替换（remove/add listener + 重锚 + 启停 ticker），并补 widget 测试用例。
2. 【P0】`_laneOf`/`_widthCache` 随 `_scanStart` 前移同步裁剪，行分配扫描限定活跃集。
3. 【P1】`_assignLane` 异宽追尾：扩展判据或核实原版同弱性后登记偏离；补异宽测试。
4. 【P1】补两处偏离/对齐登记（底部统一防重叠、L2R 无上限）。

## 总体结论：需修后合并
