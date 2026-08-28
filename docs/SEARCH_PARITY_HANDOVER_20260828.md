# 搜索 parity 修复 — 任务交接文档（2026-08-28）

> 本文档为「按审计意见修改 P0-2 S0 双包基线 + P0-3」任务的**完整交接**：已完成、未完成、当前状态、下一步与风险，供接手者无缝续作。
>
> **权威依据**：`docs/SEARCH_PARITY_S0_AUDIT_RESULT_20260828.md`（审计结论与修复计划）。
> **用户指令**：「P0-2 S0 双包基线审核不通过」「P0-3 审核不通过，请按审核意见修改」。

---

## 一、背景与审计结论

审计对 `docs/SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` 第 7.6 节及双包搜索汇报的复核结论：

- **P0-1.4 双包基线未完成**；
- **P0-2 S0 通用搜索路径不能标记为通过**，不允许据此关闭 P0-2 或解锁后续阶段；
- **P0-3（当前会话取消）阻塞**：会话级令牌已落地，但「取消任务中止、竞态隔离与真实重叠压力测试」未通过验收。

用户要求按审计意见修改上述两项。本 span 聚焦 **P0-3 的代码/测试/文档整改**（已全部完成并提交），并推进了门禁验证；**P0-2 S0 双包基线为较大工程，尚未开始**。

---

## 二、已完成（本 span，均已提交）

### 2.1 P0-3 代码重做 — commit `e630b3e28`
`fix(rust): P0-3 搜索会话取消重做——有界派发+中止在飞+竞态复检`（仅改 `rust/legado-ffi/src/api/search.rs`，277 ins / 109 del）

落实审计 §7.2 / §7.4 / §7.5：

| 审计项 | 实现 |
|---|---|
| **§7.2 P0 BLOCKER**（有界派发 + 中止在飞） | `drive_source_batches` 重写：在飞任务 ≤ `concurrency`；一个源完成即补位下一个；循环结束后**显式 `abort_all` + drain**；暂停时不持有并发许可。驱动侧不再向 on_source 投递「取消/sink 关闭后」的在飞结果。 |
| **§7.4**（竞态复检） | serialize / persist / `sink.add` 前统一复检「未取消 **且** 仍为当前会话」；三处生产 `on_source` 闭包内 `session_cb` 复检。 |
| **§7.5**（清理不误清新会话） | 新增 `clear_current_session_if_same(&Arc<SearchSession>)`，以 `Arc::ptr_eq` 保证 A 的清理绝不清 B；在三个生产入口的**所有退出路径**执行。 |

关键 helper：`is_current_session(&Arc)`、`clear_current_session_if_same(&Arc)`（各 6 处调用 / 3 处 session_cb 复检）。

### 2.2 P0-3 真实重叠测试 — commit `e630b3e28`
替换原先薄弱的 `test_search_session_isolation_a_then_b`，新增 3 个：

- **`test_search_overlap_a_replaced_by_b`**（§7.3 P0 BLOCKER）：A(concurrency=2, a1–a5) 运行中 → 置 A.cancel + spawn B；断言 `a_started==2`（排队源 0 请求）、`a_delivered==0`（在飞结果不进入流/状态/DB）、`b_started==5`（B 干净不受污染）。
- **`test_drive_source_batches_sink_err_aborts_remaining`**：6 源 conc=2，batch1 后 on_source Err；断言 `cancel==true`、`delivered==1`、`started==2`，剩余任务被中止。
- **`test_session_registration_and_cleanup_safety`**（§7.5）：A→B 注册断言 A 被取消/当前=B；`clear_...(&a)` 不清 B；`clear_...(&b)` 才清。

覆盖 §7.7 要求的三条取消入口：**显式停止 / sink 关闭 / 页面销毁**（前两者与页面销毁共用 cancel-flag 机制，由 overlap + registration 测试覆盖；sink-Err 单独覆盖）。

### 2.3 文档更正 — commit `657a0f670`
`docs: 复审修订搜索一致性计划 §7.6，撤回过度完成声明`（3 ins / 3 del）

- P0-3「✅ 已完成并提交（07bd63089）」→ **撤回** + 重做说明 + 「e2e 待补后方可关闭」；
- §7.6 标题「重构版端到端验证通过」→「单包观察记录（复审后修订…已撤回）」；
- §7.6 状态「P0-1.4 双包基线 + S0 通用搜索路径验证通过」→ **撤回**（单包、PNG/XML 为旁证非搜索结果证据、四项 S0 未关闭、P0-2 不得标完成）。

### 2.4 G4（限速）隔离
G4 的 `SWITCH_SOURCE_TIMEOUT` / `source_rate_limit` 相关改动**未混入 P0-3 提交**，保持在工作树未暂存（详见 §五.3），符合审计 §7.6 第 4 点「与 P0-3 提交继续隔离」。

---

## 三、验证结果（门禁状态）

| 门禁 | 结果 |
|---|---|
| `cargo test`（非 QuickJS，`rust/`） | ✅ **314 passed / 0 failed** / 17 ignored |
| `cargo test --features quickjs` | ✅ **372 passed / 0 failed** / 27 ignored |
| 5556 冒烟（含本次整改的 `.so`） | ✅ **7/7，无崩溃**；FFI content hash 校验通过（arm64 + x86_64），APK 装为 2.0.109 |
| `flutter analyze`（`flutter_legado/`） | ✅ **No issues found** |
| `flutter test`（`flutter_legado/`） | ⚠️ **1273 passed / 2 FAILED**（见下） |

### flutter test 的 2 个失败（需接手者定性）
```
search_notifier_test.dart: SearchNotifier search 方法（mock API）
  - 全部批次失败时结果为空、error 仍为 null（UI 走无结果空态）
  - 失败批次静默不弹错误、仅 appLogPush 留痕（对齐原版 SearchModel）
```

**判定**：与本 span 的 P0-3 改动**无关**——P0-3 是 Rust-only（`search.rs`），且该 Dart 测试 **mock 掉 FFI API**，不会调用真实 Rust。git log 显示我的 P0-3 提交 `e630b3e28` **之后**有并行 UI 轨提交触及本测试/搜索错误日志：
- `5dd95d315 test(ui): 同步搜索错误日志级别断言 error 改为 message`
- `a08394d5d fix(ui): 书源搜索错误日志级别 error 改为 message，修复被 FFI 静默丢弃`

故这 2 个失败**很可能来自并行 UI/MD3 轨**（搜索错误日志级别改动），非 P0-3。**接手者请**：在 `e630b3e28` 处（或 UI 搜索错误改动之前）跑 `flutter test` 确认是否为遗留，再决定归属与修复。

---

## 四、未完成 / 剩余工作

### 4.1 P0-3 收尾（审计 §7.7 — 须**全部**满足才可关闭）
代码/测试/文档侧已满足：有界派发+中止在飞(§7.7.1)、A→B 重叠压力测试(§7.7.2)、三入口断言(§7.7.3)、暂停不占许可(§7.7.4)、清理不误清新会话(§7.7.5)。

**仍缺（关键）**：
- [ ] **5556 实机「搜索中停止并立即重新搜索」e2e**（§7.7.6）——P0-3 关闭的**决定性验证**。盲操作 uiautomator（无图像输入，Android 9），需捕获日志/UI 层级证明：A 在飞被中止、A 排队源不请求、B 干净运行。
- [ ] **5558 同场景**（用户验收前按项目流程执行）。
- [ ] 定性 flutter test 2 个失败归属（UI 轨 vs 遗留）。

> ⚠️ **不得提前宣称 P0-3 完成**——单测/冒烟已过，但实机重叠 e2e 未做。

### 4.2 P0-2 S0 双包基线（审计 §五 — **较大工程，尚未开始**）
关闭条件（§五，须全部满足）：
1. 四类响应夹具离线可复现，原版预期与 Rust 主路径字段/计数/错误分类一致；
2. 原版 + 重构版用同一快照/范围/关键词，均到终态；
3. 两端完成源数、失败分类、首批/最终时间、原始+聚合条数、top-20、origins、稳定排序——**可机读证据**；
4. `loginCheckJs` 成功/失败、HTTP 重定向最终 URL、`bookUrlPattern`、空列表详情回退——各独立断言；
5. 未完成项不标绿，保持 DEFERRED；
6. 复测结果/命令/设备/commit HEAD 写入计划并与实际提交一致。

**对应审计 §四的落地子任务（均未开始）**：
- [ ] **P0-2-S0-B**：建四类离线响应夹具（脱敏请求参数 + 原始响应字节 + 编码 + 初始/最终 URL + 书源 JSON + 原版预期 JSON + 失败分类 + SHA-256）。最小样本：loginCheckJs 成功/失败各一、≥1 次 3xx 跳转、bookUrlPattern 命中详情/不命中列表各一、空 bookList 可解析详情 / 无法解析空结果各一。
- [ ] **P0-2-S0-E**：**主路径单源执行器收敛到原版 `WebBook` 语义**（大实现）——当前 Flutter 主搜索链走 `search_single_source → parse_search_response`（简化解析），完整 WebBook 路径（loginCheckJs / 重定向最终 URL / bookUrlPattern 详情判定 / 空列表详情回退）在另一执行器。需消除解析分叉、对齐原版行为顺序与错误分类。
- [ ] **P0-2-S0-C**：双包同快照/同关键词跑到**终态**，导出可机读对比指标（两端完成源数/失败分类/首批时间/原始+聚合条数/top-20 name·author/每项 origins 数 + 稳定排序）。

> ⚠️ P0-2 S0 的「修改」不是纯验证——需要先做离线夹具(S0-B)与主路径收敛(S0-E)的**代码实现**，再做双包对比(S0-C)。这是跨多轮的大工程。

### 4.3 §7.6.1：`SWITCH_SOURCE_TIMEOUT` 提交拆分（git hygiene）
建议从未集成的 `07bd63089` 中把 G4/换源范围的 `SWITCH_SOURCE_TIMEOUT` 拆出到独立 `fix(rust)`/`refactor(rust)`，保留既有消费者、勿破坏 `source_switch.rs` 编译。
- **风险较高**：需历史重写；`07bd63089` 现处 HEAD 下第 5 层（其上叠了 P0-3 重做 + docs + UI 轨提交）。本地分支领先 origin/master 692+ 提交、**全未 push**，重写可行但需谨慎。
- [ ] 待评估是否执行（可选/低优先）。

---

## 五、当前状态快照

### 5.1 Git（分支 `feature/rust-*`，领先 origin/master **692+ 提交，全本地未 push**）
最近提交（新 → 旧）：
```
281951dd0 feat(ui): MD3 迁移 Batch 0——主题地基切换 Material Design 3 Expressive   ← UI/MD3 轨
7d4e2f020 chore(ui): build_runner 重生成对齐 json_serializable 可空嵌套 toJson      ← UI/MD3 轨
5dd95d315 test(ui): 同步搜索错误日志级别断言 error 改为 message                      ← UI 轨（疑与 flutter test 2 失败相关）
e630b3e28 fix(rust): P0-3 搜索会话取消重做——有界派发+中止在飞+竞态复检              ← 本 span（P0-3）
657a0f670 docs: 复审修订搜索一致性计划 §7.6，撤回过度完成声明                        ← 本 span（文档）
63c197d59 docs: UI 开发规范切换为 Material Design 3 指南（治理步骤）                ← UI/MD3 轨
b855d9955 docs(rust): 记录 P0-3 取消并发审计结论                                    ← P0-3（先前 span）
6a7d8e8b4 docs(rust): P0-3 会话级取消完成记录 + S0 双包基线与四项 DEFERRED          ← P0-3（先前 span）
07bd63089 fix(rust): 搜索取消/暂停改为会话级，隔离重叠搜索防残留                    ← P0-3 原始实现（含待拆的 SWITCH_SOURCE_TIMEOUT）
```

### 5.2 未暂存改动（工作树 = **P0-3 已提交** + **G4 hunk 未提交** + **UI/MD3 轨改动**）
- `rust/legado-ffi/src/api/search.rs`：**仅 G4 两行 acquire hunk**（L1000–1001，`search_single_source` 签名后）。P0-3 主体已提交。
- `rust/legado-ffi/src/api/mod.rs`：`pub mod source_rate_limit;`（G4）。
- `rust/legado-ffi/src/api/source_switch.rs`、`web_book.rs`、`examples/scan_search_sources.rs`（G4 / 先前 span，来源待确认——**勿并入 P0-3**）。
- `flutter_legado/lib/src/screens/home_screen.dart`、`theme_config_screen.dart`、`widgets/legado_app_bar.dart`、`pubspec.yaml`/`pubspec.lock`（**UI/MD3 轨**，非本 span 所改）。
- `CHANGELOG.md`。

### 5.3 G4（限速）隔离 — **必须保持未暂存**
- `rust/legado-ffi/src/api/source_rate_limit.rs`（**未跟踪**）。
- search.rs L1000–1001 acquire hunk + mod.rs `pub mod` + source_switch.rs。

### 5.4 模拟器
- **emulator-5556 / 5558 均在线**（device，Android 9）。
- 5556 已装**含本次 P0-3 整改的 APK**（2.0.109，冒烟 7/7 通过）——可直接用于 e2e。
- 双包：`com.legado.app.release`（原版基准 3.26081008）+ `io.legado.flutter_legado`（重构版）。

### 5.5 安全快照 / 临时文件（`rust/` 下未跟踪，建议保留至 P0-3 关闭再清理）
- `_p03_search_with_g4_v2.rs`（P0-3 + G4 字节级备份）、`search.rs.bak_p03`、`_p03_with_g4.rs`。
- `.tmp_*` / `_p03_*` 若干 pwsh 脚本与 rs 片段（拼接/修复用）。

---

## 六、下一步建议（优先级）

1. **P0-3 e2e（5556，盲操作「停止并立即重搜」）**——最接近关闭项，先做。捕获日志/UI 层级证明 A 中止 / B 干净。完成后按流程上 5558 复测。
2. **定性 flutter test 2 个失败**（UI 轨 vs 遗留）：在 `e630b3e28` 处跑 `flutter test` 比对。
3. **P0-2 S0**：先建离线夹具(S0-B，纯离线不依赖模拟器) → 主路径收敛(S0-E) → 双包对比(S0-C)。
4. **§7.6.1 SWITCH_SOURCE_TIMEOUT 拆分**（git hygiene，可选/高风险，最后评估）。

---

## 七、注意事项 / 风险

- **CRLF 约束**：`search.rs` 用 CRLF——编辑**必须**用 pwsh `.ps1`（文本替换 / 行号拼接），**不能**用 `str_replace_editor`/`edit`；`'static` 是生命周期（无引号闭合）；拼接块可能带 LF → 需归一化。
- **cargo/pwsh exit code 误报**：pwsh `2>&1 | Out-String` 会把 cargo stderr 进度误报为 `[exit code: 1]`，即使 PASS。**判断看文本**（`test result: ok` / `Finished dev profile`），勿信 `$LASTEXITCODE`。
- **G4 隔离**：`source_rate_limit.rs` 保持未暂存，勿混入 P0-3；后续任何 P0-3 验证须记录所测 HEAD，避免把当前工作树 G4 行为归因给 `07bd63089`。
- **盲操作 uiautomator**：模型无图像输入 → 只能读 content-desc / text（Flutter 用 content-desc，Kotlin 原版用 text）；Android 9。
- **双包证据缺口**：需两端同快照/同关键词到终态 + 导出可机读指标；当前截图是**书架页非搜索结果页**（无效 parity 证据）。
- **`.s0_booksource.json`**：996 源全启用，SHA-256 `05FC9DC0E337EEA455D43211C49A9084BB86509F227B86BCD6051D6055CCA03C`；**不能证明两端导入了同一快照**。
- **多轨并行**：当前仓库同时有 P0 搜索 parity 轨 + UI/MD3 治理轨在推进，接手者注意区分提交归属、避免文件冲突。

---

编写者：Qoder ｜ 2026-08-28
