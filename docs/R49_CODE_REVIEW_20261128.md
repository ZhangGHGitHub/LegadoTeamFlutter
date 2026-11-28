# R49 字符级选区独立代码审查

- 审查对象（master，均未修改，只读审查）
  - `8ee2e43da7` feat(ui): R49 阶段A 选区模型与长按命中选择（步骤1-2） +1642/−7
  - `040957fc05` feat(ui): R49 阶段B 选区手柄与浮条非模态化（步骤3-4） +1426/−129
  - `b6ad6150bf` feat(ui): R49 阶段C 选区态翻页门控与点击抑制（步骤5-6） +809/−7
- 设计依据：`docs/R49_CHAR_SELECTION_DESIGN_20261128.md`
- 审查方式：逐提交 `git show`；承重约束逐条核对源码；对渲染/手势/Overlay 生命周期做静态推演；独立复跑门禁。
- 独立复验（本审查亲自执行，非引用）：
  - `flutter analyze` → `No issues found!`（0 诊断）
  - `flutter test` 聚焦 + 回归共 **197 例全绿**：
    - `reader_selection_turn_guard_test`（10）、`reader_char_selection_test`（17）、
      `reader_selection_mapping_test`（26）、`reader_wiring_1a_test`、`reader_pagination_overflow_test`
    - `reader_tap_zones_dispatch_test`、`reader_swipe_bookmark_test`、`reader_inline_image_render_test`、
      `reader_highlight_render_test`、`reader_scroll_highlight_render_test`、`md3_acceptance_matrix_test`、
      `text_selection_menu_test`、`reader_selection_toolbar_test`
  - 全量 6198 例本审查**未重跑**（引用主代理数据，仅作参考，不作为本报告的证明）。
- 重要声明：测试全绿 **不等于** 状态机与坐标映射没有漏洞。本报告 P0/P1 均可在现有测试全绿的前提下真实发生（见 §五）。

---

## 一、总体结论

**Summary: needs changes**

R49 的三段式落地在结构上是成立的：真正改变风险面的是「零布局改动 + 裸 Listener 门控 + 单选区状态单一通路」，这三点我逐条核实成立；状态复位与点击抑制的三重复位设计也比常见实现严谨。但存在 **1 个 P0**：手柄拖拽的坐标映射用了原始手指坐标而非「手柄逻辑中心」，在几乎每一页（多行正文）上都会把端点映射到**下一行**，即字符级选区最核心的手柄拖拽在主场景下是错的。另有 **1 个 P1**：执行浮条动作 / 进入「更多」面板后选区不清理，与设计 §5.5 明确要求相反，会造成高亮与手柄驻留并吞掉下一次点击。

因此结论为 `needs changes`：P0 修完后重跑本报告 §六 的实机场景，再走验收。

---

## 二、分级问题清单

### P0（必须修）

#### P0-1 手柄拖拽坐标映射错误：抓可见圆柄会落到下一行，起手即跳端点

**位置**
- `flutter_legado/lib/src/widgets/reader/reader_text_content.dart:718-739`（`_beginHandleDrag`：`grabOffset` 用 pan start 位置计算，并立即 `_applyHandleDrag`）
- `flutter_legado/lib/src/widgets/reader/reader_text_content.dart:751-770`（`_applyHandleDrag`：`_hitTestPage(globalPosition)` 用**原始手指坐标**）
- `flutter_legado/lib/src/widgets/reader/reader_text_content.dart:942-974`（`_hitTestPage`：按到行矩形的垂直距离取最近行）
- `flutter_legado/lib/src/widgets/reader/reader_text_content.dart:1604-1614`（圆心 = `行底 + 7`；热区 `行顶−28 … 行底+35`）

**为什么是问题（具体失效场景）**
1. 每一行是 `SizedBox(height: line.height)` 且行与行**零间隙**首尾相接，`RenderParagraph` 高度 = `line.height`。因此「末个选中行的行底 + 7dp」的圆心，**必然落在下一行的行矩形内部**（`dy = 0`），而当前行距离为 7。
2. `_hitTestPage` 用严格 `<` 比较距离：当前行 `dy=7` 先入，下一行 `dy=0` 覆盖 → 命中**下一行**；随后 `RenderParagraph.getPositionForOffset` 在同一 x 上取下一行的字符。
3. `_beginHandleDrag` 在 pan start 就 `_applyHandleDrag`（注释说为避免"起手这一下不更新端点"），所以**手指还没移动，端点就已经跳到下一行**；之后每次 move 都保持"领先一行"。选区是单行内时（中文单字最常见的选法），抓任意一只 pin 的圆都会命中下一行。
4. 另外 `onPanStart` 的 `globalPosition` 在 `DragStartBehavior.start`（`GestureDetector` 默认）下是**过完 slop 之后的位置**（`monodrag.dart:805-807` `_initialPosition += delta`），不是按下点；于是 `grabOffset` 也偏了约 18dp，抓柄瞬间 pin 会整体位移。
5. 设计文档 §5.5 自己写的是 `cursorY = global.dy - radius`（`:325`），参考实现 `ReaderCanvasSurface.kt:1156-1180` 还额外有 `handleHasMoved` 守卫、并用 `draggedHandleCenter = pointer - grabOffset` 再减半径。本实现两条都没做。

**证据（为什么测试没发现）**
- `reader_char_selection_test.dart:497/523/549`、`reader_selection_turn_guard_test.dart:226/473` 全部用 `tester.getCenter(handleFinder)` 起手 —— 那是 **热区矩形的中心**，按 `hitRect` 公式落在 `行顶 + 15.5`（行高 24），仍在当前行内，所以映射"恰好"正确。
- 同一测试 `:452-466` 明明算出了可见圆心（`行底 + 7`），却只用于断言绘制位置，**从未从该点起手拖拽**。
- 单行测试页没有"下一行"，天然掩盖该 bug。

**修复建议**
- 手柄 `GestureDetector` 加 `dragStartBehavior: DragStartBehavior.down`（取真实按下点）。
- 落点改为「逻辑中心」而非手指：`logical = pointer - grabOffset`，命中查询用 `Offset(logical.dx, logical.dy - kReaderSelectionHandleRadius)`（回到行底），与设计/参考一致。
- 起手不落点（或至少当解析结果与当前端点行相同才允许落点）；保留参考的 `handleHasMoved` 语义，避免"抓一下不动也改端点"。
- 新增回归用例：**多行页 + 从 `debugHandleCentersGlobal()` 起手**，断言 (a) 起手不动端点不变；(b) 水平拖 1 个字符宽度只前进 1 个字符；(c) 不跨行。

---

### P1（应修）

#### P1-1 执行浮条动作 / 打开「更多」面板后不清选区，高亮与手柄驻留且吞掉下一次点击

**位置**
- `flutter_legado/lib/src/widgets/reader/text_selection_panel.dart:1028`（`onDismiss: handle.dismiss`，只关 Overlay）
- `flutter_legado/lib/src/widgets/reader/text_selection_panel.dart:1178-1255`（10 项动作全部只传 `onDone: onDismiss`）
- `flutter_legado/lib/src/widgets/reader/text_selection_panel.dart:1086`（管理菜单）、`:1152-1166`（「更多」）同样只 `onDismiss()`
- `flutter_legado/lib/src/widgets/reader/reader_text_content.dart:807-856`（`_showSelectionToolbar` 没有"动作已执行"回调）
- `flutter_legado/lib/src/widgets/reader/reader_text_content.dart:632-636`（`_dismissToolbar` 只收起 Overlay，不动 `_selection`）

**为什么是问题**
- 设计 §5.5 明确："翻页开始/页面变化/**进面板/执行动作**：清"。
- 实际：长按选中「world」→ 点「复制」→ 浮条消失，但灰块 + 两只手柄仍在，`_selectionActive` 仍为 true。下一次点击正文：正文 Listener 先清选区并上报 suppressed，`ReaderScreen` 抑制 → **这一次点击什么也不做**（被吞）；「更多」面板关闭后同理。灰块会一直留到用户下一次触屏或翻页。
- `reader_char_selection_test.dart:596-627` 只断言"执行动作后浮条收起"，**没有断言选区被清**，所以测试全绿。

**修复建议**
- 给 `ReaderSelectionToolbar.show` 增加 `VoidCallback? onExecuted`（与 `onDismiss` 分离）：所有动作的 `onDone`、管理菜单、「更多」入口在收起浮条的同时回调正文 `_clearSelection()`；`TapRegion.onTapOutside` 与"抓手柄"路径保持只 dismiss（这两个路径的选区清理已由各自逻辑负责）。
- 补测试：复制后 `debugSelection == null` 且 `debugHandleCount == 0`；打开「更多」后同样清空。

---

### P2（建议修）

#### P2-1 短选区（单个汉字/窄字符）两只手柄热区重叠，末端热区永远赢，起点 pin 实际不可抓

**位置** `reader_text_content.dart:1366-1371`（children 顺序 start→end）、`:1373-1391`（两个 `Positioned` + `GestureDetector`）、`:1608-1614`（热区宽 56dp）
**问题** `RenderStack` 命中的是**最后绘制的子节点**（end 热区）。当 `x_end − x_start < 28dp` 时（fontSize 20 的单个汉字约 20dp；长按中文默认就是单字），起点 pin 的可见位置落在 end 热区里 → 看到的是起点 pin，实际拖动的是 focus。功能上"反向拖过起点"常常能得到相同结果，但 pin 跟随、端点角色与用户意图不一致，且无法从可见位置抓起点。
**建议** 改成参考版做法：单一整页 pan 层，DOWN 时在两只手柄中按距离选最近者；或对两个热区做互斥裁剪（各自只保留远离对方的一侧）。补一条"单汉字选区左右两只 pin 都能抓"的用例。

#### P2-2 手柄圆与 28dp 热区被正文 ClipRect / Stack 边界裁掉：页面末行的 pin 不可见也不可点

**位置** `reader_text_content.dart:241-268`（`Expanded(child: ClipRect(child: ReaderTextContent))`）、`:1308-1337`（根 Stack，默认 `clipBehavior: Clip.hardEdge`）、`:1373-1391`、`:1604-1614`
**问题** 圆心在 `行底 + 7`，圆的下半 14dp 与热区向下 35dp 都可能在文本区高度之外；`RenderBox.hitTest` 要求点落在 Stack 自身 size 内，超出部分**不可命中**，绘制也会被 `ClipRect` 裁掉。分页通常把页面填满（末行行底距文本区底 < 一个行高），因此"选区末端落在本页最后一行"时 pin 会被截断——这是很常见的场景（向下拖选到页底）。参考版把 pin 画在整页 canvas（`clipRect(bottom = size.height)`）里，不存在此问题。
**建议** 把手柄绘制 + 热区移到 `ReaderTypographicPage` 的页面级 Stack（那里已有书签角标 Stack，且页面区域包含页边距），正文只上报几何；或在正文底部预留 ≥14dp 的不可裁剪区域。需实机截图确认。

#### P2-3 滚动模式：在其它 chunk 上按下/滚动不会清选区，选区驻留并吞掉下一次点击

**位置** `reader_text_content.dart:914-925`（`_selection.value == null && _toolbar == null` 直接 return，不向父级通报）、`reader_screen.dart:1353-1375`（只有 tapDown 兜底，拖拽若赢得竞技场则不触发）、`reader_page_view.dart:2523-2533`（滚动 chunk 接线）
**问题** 设计 §5.7 要求"滚动开始 → 清选区（down 非手柄时），滚动继续"。实际：选区在 chunk A，用户从 chunk B（或标题区）开始滚动 → B 的 down 早退，`_selectionActive` 保持 true；TapRegion 只收起浮条，灰块/手柄随内容一起滚走但仍活跃。下一次点击被 `hasActiveSelection` 兜底吞掉一次。若该次是快速拖拽，tapDown 不触发，则选区一直留到用户真正点一下。
**建议** 滚动模式下在页面级统一处理：`NotificationListener<ScrollStartNotification>` 或包一层 `Listener`，`hasActiveSelection` 时 `clearSelection()`；同时让 chunk 的 down 在"非本实例选区"时也上报（当前早退条件过窄）。补"跨 chunk 滚动清选区"用例。

#### P2-4 `_handleGeometry` 晚一帧且拖拽期间跳过同步：一帧内可能把普通点击误判为"按在手柄上"

**位置** `reader_text_content.dart:643-657`（postFrame + `_handleDrag != null` 跳过）、`:928-936`（`_isInHandleHitRegion`）
**问题** 清选区后 `_handleGeometry` 要等帧末才置空；同一帧内落在旧手柄热区的按下会被当作 onHandle：不清理、不动作，且 `ReaderScreen` 抑制本次点击（一次"空点击"）。长按拖选时热区也晚一帧（视觉 pin 由 painter 现算，因此 pin 与热区会短暂错位）。
**建议** `_clearSelection` 里同步置空 `_handleGeometry`（并 `setState`），或在同一个 `ValueNotifier` 里同时携带 selection 与几何，避免两套时序。

#### P2-5 「更多」面板里一次折叠点击会把字符级选区静默退回整段

**位置** `text_selection_panel.dart:444-470`（`onSelectionChanged` 先 `_useInitialSelection = false`，再判断 `isCollapsed`）
**问题** 从字符级选区打开「更多」后，用户只是点一下文本块（折叠选区）→ `_userSelected=''`、`_useInitialSelection=false` → 之后的高亮/笔记/复制作用对象**静默变成整段**，字数标签也随之变化。这与"面板打开即按选区执行"的承诺相反。
**建议** 只在"有效且非折叠"的新选区出现时才关闭 `_useInitialSelection`；折叠时保留初始选区（或显式提示"已退回整段"）。

---

### P3（登记）

1. **`update()` 死代码且无法置空**：`text_selection_panel.dart:1383-1408` 无调用方；`_ReaderToolbarParams.copyWith`（`:1305-1340`）所有字段 `??`，无法把可空字段改回 null。将来若用它"就地更新浮条"，会踩坑。
2. **手柄形态细节未对齐参考**：拖动中的圆柄未淡出（设计 §5.5 要求），圆柄无参考版的白色 shadow 层（`ReaderCanvasSurface.kt:1760-1765`）。纯视觉。
3. **手柄拖拽松手多打一次振动**：`_endHandleDrag` → `_showSelectionToolbar` → `ReaderSelectionToolbar.show` 里 `selectVibrator` 分支再发一次 selectionClick（`text_selection_panel.dart:961-970`）。设计只要求"起选 + 拖动中节流"。`reader_wiring_1a_test` 的"恰好 1 次"只覆盖纯长按路径，不覆盖此路径。
4. **长按在词间空白/行内图片占位符上**：`readerWordRangeAt` 返回单字符空白/占位符 → 有灰块与手柄但 `readerSelectionText` 为空 → 不弹浮条（`reader_text_content.dart:811`）。参考版会吸附到邻近文本。
5. **拖到页面外仍会吸附最远行**：`_applyHandleDrag` 不判边界，手指拖到状态栏/页脚时按最近行映射（可能从第 30 行跳到第 1 行）；参考版 `pageAt(x,y)==null` 时保持端点不变。
6. **跨页切片的段落在「更多」面板内重新划选时 chapterPos 基线偏移**（既有问题）：`_showSelectionToolbar` 传 `paragraphText=本页切片`、`paragraphChapterPos=para.startIndex（整段起点）`（`reader_text_content.dart:844-853`），面板内 `_useInitialSelection=false` 后走 `chapterOffsetOfSelection` → `paragraphStart + 切片内下标`，整段被上一页切过时整体左移。R49 让该路径更容易触达，建议顺带修（用切片首行的 `chapterStartIndex` 作为基线）。
7. **`_handleSelectionActiveChanged` 缺 `_disposed` 守卫**（`reader_page_view.dart:487-489`）：同文件其它四处都有。当前依赖"子先于父 dispose"成立（SDK `framework.dart:2121-2131` 深度倒序 unmount），但一旦将来有 content 在 pageView 之后卸载就会写已 dispose 的 `ValueNotifier`。
8. **滚动 chunk 无 ValueKey、依赖 `!identical(pageInfo)`**：当前 `_paginatedPages` 复用实例，可靠；但如果将来分页改为"等值但新实例"每帧产出，`didUpdateWidget` 会每次都清选区（表现为"选区每帧消失"）。建议在 `PageInfo` 上加稳定身份或给 chunk 加 key，并在代码注释里写明该契约。
9. **跨段选区的笔记上下文长度按 `trimmedSelected.length` 推算**：CRLF 章节里段间是 `\r\n`（2 字符）而选区文本只含 `\n`，`markingContextAround` 的 after 片段会早 1 个字符（`text_selection_panel.dart:178-200, 114-135`）。R49 前整段选择不跨段，属新触达面。
10. **`ReaderTurnView` 的"选区态按下会中止进行中的 settle"**（`reader_turn_view.dart:449-463` → `PageTurnController.onPointerDown` → `_abortSettle`）：只有在 slide/cover 动画中长按起选（动画时长 < 500ms，实际很难触发）时可达；中止后由 `_finishGesture` 续作复位 `_overlayVisible`，不卡死，仅登记。
11. **`reader_wiring_1a_test` 的长按 finder 命中的是隐藏快照页副本**（运行期有 "would not hit test" 警告，实际由 live 页接收手势）：测试仍通过，但断言依赖"隐藏页与 live 页逐像素重叠"，较脆。
12. **`isCollapsed` 恒为 false**（`reader_text_selection.dart:66-71`）：含端语义下不可能成立，属保留分支；建议注释说明或删掉以免误导后续调用方。

---

## 三、六条承重约束逐条核实

### 1. 布局零改动 —— 成立

- 变更是 `Column` → `Stack(fit: StackFit.passthrough, children:[Positioned.fill(IgnorePointer(CustomPaint)), Column, ...手柄层])`（`reader_text_content.dart:1303-1337`）。
- `StackFit.passthrough` 把父约束**原样**传给非定位子节点（SDK `rendering/stack.dart:634-638`），`Stack` 自身 size = `max(约束最小值, 最大非定位子尺寸)`（`:631-663`），因此 Column 拿到的约束与改造前完全一致。
- **三处调用点都给出紧约束**：分页 `Expanded(child: ClipRect(child: ReaderTextContent))`（`reader_text_content.dart:241-268`，Expanded → 紧高，ClipRect 透传）；滚动 `SingleChildScrollView` 视口宽为紧宽；单测 `SizedBox(320×240)` 紧约束。因此不存在"Column 收缩、Stack 撑满"的尺寸差。
- 逐提交扫描新增行：没有新增/修改 `SizedBox(height: line.height)`、`Padding`、`Text` 尺寸或 Column 结构；`_LineProbe` 是 `StatelessWidget`（无 RenderObject、无约束改动）；手柄热区尺寸只作用于独立 `Positioned`。
- 实证：`reader_pagination_overflow_test` 全绿；`reader_char_selection_test` "选区不改变布局：文字 rect 与行高前后一致"全绿；我复跑的 `reader_inline_image_render_test` / `reader_highlight_render_test` / `md3_acceptance_matrix_test` 全绿。
- 唯一"布局相关"的副作用是 P2-2（手柄被 ClipRect 裁切）和"有手柄时 Stack 因溢出多一层 clip"（`RenderStack._hasVisualOverflow`），不影响文本排版。

### 2. turn 翻页算法未被改动 —— 成立

- `reader_turn_view.dart` 净 +50/−2，全部 hunk 为：新增 `selectionActive` 参数/字段（`:75-83`）、`_pullDrag` 改读真实状态（`:396-407`）、`_selectionActive` getter（`:409-410`）、`_onPointerDown/Move/Up/Cancel` 四个门控分支（`:449-483, 574-580, 611-617`）。**没有**触碰章边界预载、位图快照作废、承接态（`_chapterTurning`）、`PageTurnController` 判定。
- 门控与 turn 内部状态机的互斥性：
  - down：先 `_resetPullState()`（清 `_pullDragging/_pullArmed/_pullReleased/_pullOffset`），再 `_controller.onPointerDown`，选区活跃时再 `resetGesture()`（清 `_isMoved/direction/isDragging/isSettling`）。
  - move：只要选区活跃，检测到任一非初态就同时复位 pull 与 controller 后 return；不会用陈旧 `_pullDown` 继续判定。
  - up/cancel：选区活跃 → 复位两者并 return，绝不提交翻页/书签。
  - 若手势中途选区被清除（例如页面边距按下后 100ms 的 tapDown 兜底），后续 move 从本次 down 的 `_pullDown` 起算，语义是"先清选区、本次拖拽照常翻页"，与设计一致。
- 唯一可观测副作用：`_controller.onPointerDown` 会 `_abortSettle`，即"选区活跃时按下会中止进行中的收尾动画"。由于 `_abortSettle` 会 complete 挂起的 completer，`_finishGesture` 的续作仍会 `_overlayVisible=false`（`reader_turn_view.dart:668-672`），不会卡遮罩。登记为 P3-10。

### 3. 门控状态复位完整性 —— 成立（见 §四 全表）

- 能上报 `true` 的路径只有一条：`_startSelectionAt` → `_setSelection(非空)` → `_syncSelectionActive` → `true`。而它**总是先** `onSelectionStartRequested` → `pageView.clearSelection()`（全实例清 + notifier=false），因此不存在"A、B 两个实例同时 true"。
- 能上报 `false` 的路径：`_setSelection(null)`（取消/空白按下/外部信号/几何变化/dispose）、`dispose` 无条件 `_reportSelectionActive(false)`、pageView 侧 `clearSelection`/`_clearSelectionForTurn`/换章 build 期直接置 false + 帧末信号。
- 用"反证"逐路径检查"永久 true"：内容 State 卸载前必 `dispose` → 上报 false（子先于父 unmount，`framework.dart:2121-2131`）；不可卸载而存活的内容实例只有 live 页/滚动 chunk，它们清选区的路径覆盖 down/信号/自身 dispose。
- **未发现**"清选区后门控仍为 true"的路径；P0 的红→绿实验中"清选区后首次拖拽仍可翻页"恒通过，与"门控读实时值（`_selectionActive.value`）而非快照"一致。

### 4. 点击抑制边界 —— 成立，附两处边界瑕疵

- 顺序验证：内容根 `Listener`（`HitTestBehavior.translucent`，`reader_text_content.dart:1303-1307`）比 `ReaderScreen` 的 `GestureDetector` 深，down 时先清选区/上报"被消费"；`onTapDown` 在识别器 deadline/胜出时才触发，因此一定能读到标记。`reader_selection_turn_guard_test` "选区态点击空白：只清选区，不触发九宫格菜单" + "第二次点击正常分发" 已验证。
- 手柄：`_handleRootPointerDown` 判中热区时保留选区并上报 `onHandle=true`；`ReaderScreen.onTapDown` 因此不 `clearSelection()`；手柄 pan 由独立 `GestureDetector` 赢得竞技场。
- 浮条：位于根 Overlay，点击浮条内部不会进入 `ReaderScreen` 的 down（Material 不透明），动作不触发九宫格；`TapRegion` 只对浮条外部生效。
- 防粘滞有三重复位：`consumeSelectionTap()` 每次 tapDown 清标记（`reader_page_view.dart:449-459`）、页面级 `Listener` 在 pointer up/cancel 兜底（`:1362-1366`）、`_tapSuppressedBySelection` 每次 onTapDown/onTapCancel 复位（`reader_screen.dart:1358, 1388, 1752-1755`）。**未找到标记可永久粘滞的路径**（指针事件路由在 down 时确定，up/cancel 必经同一路径）。
- 瑕疵：P2-1（热区重叠）、P2-4（一帧陈旧几何）可能把正常点击误判为 onHandle（吞一次点击），但不影响"正常态九宫格不变"。

### 5. 滚动模式 —— 主路径成立，跨 chunk 清理有缺口

- 分页 chunk 全部接入选区通路（`reader_page_view.dart:2523-2533`）；`ReaderParagraphs` 回退路径保持段落级、不加选区/手柄（`reader_text_content.dart:1815-1847`），`selectText=false` 时两模式均无入口（测试覆盖）。
- chunk 清理可靠性：`didUpdateWidget` 以 `!identical(pageInfo)` + 几何键清选区（`:562-586`），`_paginatedPages` 当前复用同一批 `PageInfo` 实例，因此该判据成立；换章/重排另有 `_scheduleSelectionClear`（`reader_page_view.dart:1119-1136`）与信号总线兜底；chunk 被移出列表时 dispose 上报 false。
- 缺口：**在非持有选区的 chunk 上按下/滚动不清**（P2-3），与设计 §5.7 "滚动开始清选区"不符；由于 tapDown 兜底仍存在，最坏表现是"滚动后第一次点击被吞"，不是永久失效。

### 6. 浮条非模态化 / OverlayEntry 生命周期 —— 成立（P1-1 除外）

- `dismiss()` 幂等（`_dismissed` 置位），`_teardown` 先把 `_entry` 置 null 再 `remove()..dispose()`（`text_selection_panel.dart:1356-1381`）：
  - `OverlayEntry.remove()` 断言 `_overlay != null`（SDK `overlay.dart:226-228`），代码保证只调一次；
  - `remove()` 同步把 `_overlay` 置 null，`dispose()` 的断言 `_overlay == null`（`overlay.dart:277-281`）因此满足；
  - 即便首次 build 前就收起（`mounted=false` 但 `_overlay != null`），`remove()` 仍会置 null，随后 dispose 合法——代码注释的判断正确。
- 延后一帧：`persistentCallbacks`/`midFrameMicrotasks` 下改走 postFrame，覆盖了"build/layout 期间移除 Overlay"的风险；`transientCallbacks`（ticker 里由 `onPageChanged` 触发 dismiss）与 `postFrameCallbacks` 直接移除也是安全的（`OverlayState._markDirty` 只是 `setState`，`overlay.dart:848-852`）。
- `_params.dispose()` 发生在 entry 尚未 unmount 时也安全：`ChangeNotifier.removeListener` 明确允许 dispose 后调用（`change_notifier.dart:339-345`），`ValueNotifier.value` getter 无 dispose 断言。
- 重复 `dismiss` / `_dismissToolbar` + 重新 `show` 不会双浮条（dismiss 幂等、show 前显式收起；且 show 只在手势回调/非 build 期调用）。
- 缺口即 P1-1：执行动作只收浮条、不清页面选区；另有 P3-1（`update` 死代码）。

---

## 四、状态复位时机完整表

| # | 时机 | 位置 | 设置/清除 | 结论 |
|---|---|---|---|---|
| 1 | 长按起选 | `reader_text_content.dart:660-678` → `reader_page_view.dart:461-468` | 先 `clearSelection()`（notifier=false + signal++，全实例清），再建新选区 → true | 正确（单选区保证） |
| 2 | 长按拖选扩展 | `:693-714` | 保持 true | 正确 |
| 3 | 长按取消（他者赢竞技场） | `:684-690` | 非手柄时清 → false；手柄上不清 | 正确 |
| 4 | 长按释放 | `:1290` `_showSelectionToolbar` | 只弹浮条，选区保留 | 正确（设计） |
| 5 | 点击正文非手柄位置 | `:914-925` | 清 + 上报 suppressed → false | 正确 |
| 6 | 点击页面边距（正文块外） | `reader_screen.dart:1353-1375` | 兜底 `clearSelection()` → false | 正确 |
| 7 | 点击/抓取手柄 | `:914-920`、`:718-739` | 保留 + 上报 onHandle；抓手柄收浮条 | 正确（但见 P2-1/P0-1） |
| 8 | 手柄松手 / 取消 | `:772-782` | 保留选区、重弹浮条 / 仅复位拖拽态 | 正确 |
| 9 | 页内翻页（手势完成） | `reader_page_view.dart:2389-2400` | `_clearSelectionForTurn()` + 旧页 dispose 上报 false | 正确 |
| 10 | 章边界翻页 | `reader_page_view.dart:2402-2415` | `_clearSelectionForTurn()` | 正确 |
| 11 | 程序化跳页 / 滚动翻屏 | `:660-675` | `_clearSelectionForTurn()` | 正确 |
| 12 | 音量键 / 自动阅读 / 滚轮 | `:708-755`、`_handlePointerSignal` | 经 `next/prevPageOrChapter` → 清 | 正确 |
| 13 | 换章 / 换源重排 | `:1119-1136` | build 期 notifier=false + 帧末 signal | 正确（避免 build 改 Overlay） |
| 14 | 字号/行高/字距/字体/对齐/字重/斜体变化 | `reader_text_content.dart:562-586` | `_clearSelection()` → false | 正确 |
| 15 | `selectText` true→false | 同上 | 清 → false | 正确 |
| 16 | `pageInfo` 变化（重排/滚动 chunk 复用） | 同上（`!identical`） | 清 → false | 正确（依赖实例复用，见 P3-8） |
| 17 | 正文组件失活/销毁 | `:588-598` | 去掉信号监听 + 收浮条 + 上报 false | 正确 |
| 18 | 模式切换 分页↔滚动 / imageDominant 切换 | 旧子树 dispose | 上报 false；新实例无选区 | 正确 |
| 19 | 打开「更多」面板 / 执行任一动作 | `text_selection_panel.dart:1028, 1152-1166, 1178-1255` | **只收浮条，不清选区** | **错误（P1-1）** |
| 20 | 滚动模式下在其它 chunk 上按下 / 开始滚动 | `reader_text_content.dart:914-925` | **不清**（早退），仅 tapDown 兜底 | **缺口（P2-3）** |

---

## 五、主代理红→绿证据覆盖不到的点（明确声明）

1. **P0-1 完全不在证据覆盖范围内**。主代理用"把 `_selectionActive` 恒置 false"证明门控有效；但门控只决定"翻不翻页"，不决定"拖到哪个字符"。现有 5 处手柄拖拽用例全部从 `hitRect` 中心（行内）起手，**从未从可见圆心起手**，因此 off-by-one-line 恒绿。
2. **P1-1 不在覆盖范围内**。`reader_char_selection_test` 的"复制"用例只断言浮条消失，未断言 `debugSelection` 为空；没有任何用例覆盖"执行动作后下一次点击应立即生效"。
3. **"清选区后首次拖拽仍可翻页"作为守卫是弱证明**：门控恒 false 时它依然通过（主代理也已承认）。它证明的是"没有把翻页永久关死"，不能证明复位路径在真实时序下都走了。
4. **跨页切片段落**（`ParagraphInfo.startIndex` 覆盖整段、`lines` 只是本页切片）没有任何用例；`_localIndexInParagraph` 的正确性只靠 substring 相等性兜底。
5. **视觉层无 golden**：手柄位置只用几何断言；圆被裁切、颜色、拖动中淡出等均无自动证明。
6. **滚动模式跨 chunk 清理**无用例（现有滚动用例都在同一 chunk 内起选和点击）。
7. 我复跑时发现 `reader_wiring_1a_test` 的长按 finder 实际命中隐藏快照页（有 "would not hit test" 警告），测试通过是因为 live 页在完全相同的位置接收了手势——结论没错，但断言比看上去脆。

---

## 六、必须在实机上验证的场景（按优先级）

1. **多行页面上的手柄拖拽（P0-1）**：字号 20、行高 1.5 的普通页，长按一个英文词/汉字，**用手指按住可见的末端圆柄**（不要按竖线），观察：(a) 起手不松手时选区是否立即多出下一行；(b) 水平拖 1 个字宽是否只前进 1 个字符；(c) 起点手柄同理。再对"选区末行为页面最后一行"重复一次（此时圆柄在页底，顺带验证 P2-2）。
2. **动作执行后的选区状态（P1-1）**：选中一个词 → 复制 → 观察灰块/手柄是否消失；不等待，直接点屏幕中央九宫格（默认菜单）→ 第一次点击是否生效。再用「更多」→ 直接关闭面板 → 同样观察。
3. **单汉字选区 + 中文默认长按（P2-1）**：长按单个汉字（默认单字选区）→ 分别从左右两只 pin 的圆柄起手拖动，确认"抓哪只就是哪只"、pin 跟随不跳变；再在「更多」面板里点一下文本块，确认操作对象不会静默变成整段（P2-5）。

补充建议同批复验：滚动模式跨 chunk 滚动是否清选区（P2-3）；1.6 倍字号 + 320dp 窄屏下浮条锚点与手柄热区；`selectVibrator` 开/关时的振动次数（应只多出"拖动中节流 + 松手一次"）。

---

## 七、处置决定

**promote_to_artifact** —— 本报告落盘为 `docs/R49_CODE_REVIEW_20261128.md`，作为 P0/P1 修复与新增回归用例的输入；P0-1 与 P1-1 修复后需按 §六 的实机场景复验并回写本报告（不因测试转绿而升格为"全面通过"）。

---

编写：代码审核员（独立子代理）｜ 2026-11-28

---

## 十、回修记录（2026-11-28，提交 `68e8669a5b`）

### P0-1 已修（主代理独立复验红→绿）

**修复三点**（对应本报告的三条建议，全部落地）：

| # | 建议 | 落地位置 |
|---|---|---|
| 1 | `dragStartBehavior: down` | `reader_text_content.dart:1489` |
| 2 | 命中点 `pointer - grabOffset - radius` | `:788`（`Offset(logical.dx, logical.dy - kReaderSelectionHandleRadius)`） |
| 3 | 起手不落点 | `:739` 只记 `grabOffset`，`:760` move 时才落点 |

**主代理独立复验方法**：临时把 `:788` 的 `- kReaderSelectionHandleRadius` 去掉（行为回退到修复前），跑 `reader_char_selection_test`：

```
Expected: <3>
  Actual: <11>          ← 11 = 下一行章节起点 8 + 行内 3
Expected: <2>
  Actual: <8>           ← 同样跳到下一行
```

恢复修正后 21 例全绿。**本报告的 P0 判定成立，修复有效。**

### P1-1 已修

`text_selection_panel.dart:916` 新增 `VoidCallback? onExecuted`（与 `onDismiss` 分离）；
10 项动作 + 「更多」入口 + 管理按钮全部走 `onExecuted`；
`reader_text_content.dart:893` 传 `onExecuted: () { if (mounted) _clearSelection(); }`。
`TapRegion.onTapOutside` 与抓手柄仍只 `dismiss`（选区清理由各自路径负责）。

红→绿：修复前 `Expected: null Actual: ReaderTextSelection(anchor: 6, focus: 10)`（两条用例），修复后全绿。

### P2-1 已修（并发现同类变体）

`_resolveHandleHitRects`（`:1451`）按「按下点归最近圆心」切分重叠热区：
同行短选区按 x 切、相邻两行 x 相近按 y 切。
**修这条时额外发现**：相邻两行且两 pin x 相近时（跨行选区起点行底圆心 vs 下一行）热区纵向也重叠——
由同一规则（按 y 切分）覆盖。

### P2-2 已修

实测 `圆心 y + 半径 = 254 > 正文框底 240`（圆整体在框外 14dp 被 `ClipRect` 裁掉且 hitTest 不达）。
`_handleCircleCenterY`（`:1120`）把圆心钳到 `正文框底 − 半径`，竖线仍画在原行框，正文仅一行高时不内缩。
**取舍登记**：内缩 14dp 会在末行下缘压住部分字形，属视觉取舍，待实机确认观感。

### 未修项（保留登记）

P2-3（滚动模式跨 chunk 按下/滚动不清选区）、P2-4（`_handleGeometry` 晚一帧）、
P2-5（「更多」面板一次折叠点击静默退回整段）、P3-1 ~ P3-12 全部保留。
其中 P3-5（拖到页面外仍吸附最远行）本次未加边界判定。

### 回修后门禁（主代理独立复跑）

| 命令 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `reader_char_selection_test` | **21 passed**（原 15 + 新 6） |
| `flutter test test/widget/` | **2402 passed**（基线 2396 + 6） |
| `flutter test test/unit/` | 3802 passed + 1 skipped |

### 仍需实机复验（本报告 §九 三场景的精化）

1. 多行页按住可见末端圆柄：起手不跳、拖 1 字宽只走 1 字符（**已有自动化用例覆盖，实机看观感**）
2. 选中→复制→立刻点九宫格：灰块/手柄消失、第一次点击生效（**已有自动化用例**）
3. 单汉字选区从左右两只 pin 分别拖：抓哪只就是哪只（**已有自动化用例**）
4. **纯视觉项（无 golden，必须实机看）**：拖动中手柄跟手观感、P2-2 内缩后 pin 与末行文字的叠压观感
