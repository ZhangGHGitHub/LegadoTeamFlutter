# Legado 后续重构执行计划（Active）

> 版本：2026-08-22
>
> 本文是当前重构开放项的唯一执行计划。历史阶段计划、审计报告和已完成批次仅作为证据保存在 `docs/过期文档/`，不得重新作为当前任务来源。
>
> 总体判断：Flutter + Rust Phase 0-4 主体已完成，但尚未达到“只剩 A* 素材验收”或“全库无桩”的状态。当前必须先处理入口功能空实现、分支集成和可复现验证，再处理契约与技术债。

## 一、状态口径

- **已完成**：有源码落点、测试证据和关闭提交；若尚未合入主线，标为“代码已完成、待集成”。
- **待验收**：实现已存在，但依赖真实设备、网络、书源或用户素材；不能计入工程缺口清零。
- **待决策**：存在多个合理架构方向，必须先记录决策再实施。
- **不纳入**：明确 N/A 或由平台能力等价覆盖，必须有原因和证据。
- **禁止口径**：不再使用“零 TODO/桩”“全部完成”“全量通过”等没有范围、HEAD、命令和提交号的绝对表述。

## 二、当前完成基线

| 范围 | 当前判断 | 证据 |
|---|---|---|
| Flutter + Rust 主链 | 主体完成 | Rust FFI、BookApi/RustApi/MockBookApi、Dart 阅读器排版链已存在 |
| 解析 parity | G8 已完成；当前分支还有搜索 parity 及书源修复 | 当前分支提交 `a779e1520`、`e74c2a6db`；见 `PARSER_GAP_FIX_PROGRESS_20260815.md` |
| FFI CI | 已配置 QuickJS 全量测试 | `.github/workflows/rust-ci.yml:26-31` |
| 主线集成 | 已关闭（P0-2，2026-08-22） | 合并提交 `81ad6e220`（父提交：master `75593d26c` + feature `5cf56a89c`）；3 处内容冲突全部解决；FRB codegen 重新生成补全 source_login_v1 绑定；全量门禁与双模拟器冒烟通过 |
| 真实环境 | 未完成 | A*：WebDAV、媒体源、真机按键、ruleReview、皮肤等仍需素材 |
| 本轮验证 | 可复现通过（`577e4ce04`，2026-08-22） | Rust `cargo test --workspace --features quickjs`：parser 249/0、js 497/0 + 2 ignored、ffi 355/0 + 27 ignored、server 171/0（`81ad6e220` 起 Rust 侧无变更）；flutter analyze 0 issues；flutter test +1217 全过 |

### 2026-08-19 执行进度

- P0-1 Rust 确认了原 `os error 5` 可通过独立 `CARGO_TARGET_DIR` 规避。
- `js_executor::tests::test_build_search_url_with_js_lib` 已修复并提交：`3f07f5de3`；parser 全量 `245 passed + 1 doctest`，相关 FFI 测试 `1 passed`，新增两个 parser 边界测试通过。
- QuickJS 全量门禁仍未通过：`356 ok`、`1 failed`、`20 ignored`，另有 `test_batch_search_scan_extended_wave2` 长时间运行后被停止；失败项已从环境问题收敛为源码/测试门禁问题。
- Flutter `analyze` 曾由 Cursor 得到 `84 issues`，主 Agent 后续复跑超过 10 分钟无输出；`flutter test` 尚未完成。
- P0-1 尚未关闭，P0-2 分支合流暂不启动。Cursor 当前因使用额度耗尽无法接收下一项实现任务。

### 2026-08-20 执行进度

- P0-3 已关闭（方案 B）：移除 Server `/api/search/multi` Noop 空实现路由，新增 4xx 防回归测试；`cargo test -p legado-server` 170/0。详见 P0-3 小节。
- P0-1 Flutter 门禁恢复可复现并通过：`flutter analyze` 不再挂起，3.3s；6 个 warning 已由 Cursor 清理并经主代理独立复核降为 `0 errors / 0 warnings / 78 info`（余为 info lint）；`flutter test` 全部通过 `+1190`。此前挂起为环境问题，现已可复现（`f5c29d036`、`f5e5862fa`）。
- P0-1 关闭：Rust 与 Flutter 门禁在当前 HEAD 均可复现通过。证据：Rust 分 crate parser 249/0、js 494/0、ffi 355/0（27 ignored）、server 170/0；flutter analyze `0 errors / 0 warnings / 78 info`（3.3s）、flutter test +1190 全过。
- P0-2 预检（merge-tree 干跑）：master 多出的 2 个提交为 `75593d26c`（七猫目录/正文修复）与 `25bab662c`（git 规范文档）；内容冲突仅 3 处：CHANGELOG.md、flutter_legado/pubspec.yaml、rust/legado-ffi/src/api/web_book.rs；js_executor.rs、quickjs_impl.rs 等可自动合并。
- 进行中：Cursor 清理剩余 78 个 info lint（完成后由主代理独立复核再提交）；P0-2 合流在 lint 清理落地后正式启动。

### 2026-08-22 执行进度

- Lint 清理由主代理自行完成并提交 `5cf56a89c`（78 info → flutter analyze 0 issues）；Cursor 连续两次续期超时，不再依赖其执行。
- P0-2 合流落地：集成分支 `integration/rust-parser-gap-fix`，合并提交 `81ad6e220`（父提交 master `75593d26c` + feature `5cf56a89c`）。3 处内容冲突解决：web_book.rs（12 个 hunk，取 feature 侧 sanitize/set_element_content，parse_content_page_with_bindings 保留 master 签名并注入 sanitize）、pubspec.yaml（2.0.96+98）、CHANGELOG.md（master [2.0.92] 保留在底部，feature 块顺延为 [2.0.93]~[2.0.96]）。
- FRB codegen 同步：重新生成 frb_generated.rs / frb_generated.dart，补全 feature 侧新增的 source_login_v1 绑定（feature 分支产物滞后，content hash -52126686 → 28124110）；Android .so（aarch64/x86_64）重建后 verify-ffi-android PASSED。
- 合流后全量门禁：Rust parser 249/0、js 497/0 + 2 ignored、ffi 355/0 + 27 ignored、server 171/0；flutter analyze 0 issues；flutter test +1190 全过。
- 冒烟：本轮模拟器端口分配为 5554/5556（对应 AVD legado_5556 / legado_5558，第三实例受同机限制无法再开）；emulator-5554（子代理测试机）6/6 通过，emulator-5556（用户验收机，AVD legado_5558）6/6 通过含 -CheckUI 书架元素检查。
- 工具修复：build-android.ps1 的 rustup target add 在目标已装时向 stderr 输出 info 行，EAP=Stop 下误判为异常中止构建；改为与 cargo 块相同的 EAP 临时降级 + $LASTEXITCODE 判定。
- P1-2 关闭：`58b48484d`（fix(ui): AutoTask 保存原始 script 防止 action 丢失）——根因 toJson 按 taskType 生成占位脚本，新增 script 字段与 effectiveScript、旧 JSON 双向兼容，补 12 项 round-trip/导入/fallback 单测。
- P1-3 关闭：`6cbcea4f3`（test(ui): 新增 API 契约自动校验测试并同步文档计数基线）——新增 `api_contract_test.dart` 7 项程序化校验（BookApi⊆RustApi/MockBookApi、公共额外方法钉死、§1.7 等价对登记、§2.x 声明数==实际行、附录双射镜像、文档总数==程序化计数）；同步 API_CONTRACT.md 18 处（§1.7 登录等价对×4、章节计数×6、附录行×6、合计 251→263、BookApi 252→260）。门禁：契约测试 7/7 绿、analyze 0 issues、flutter test +1209 全过。
- P1 全部关闭：P1-1（`577e4ce04`，真实 DLL 8/8）、P1-2（`58b48484d`）、P1-3（`6cbcea4f3`）、P1-4（`e759bdd06`）。
- P2 进行中：P2-1 已关闭（`d1186c711`），P2-2 已关闭（`3b61f0883`，书架模糊搜索共享服务统一 Server 双入口），P2-5 已关闭（`9b645eab3`，桩/Fallback 四分类登记 + 零桩声明废止），P2-4 已关闭（`cb81703fd`，A* 验收矩阵登记 + A9 深链自测验证）；P2-3 口径登记（`856b9d322`，书架 JSON 待用户素材）——唯一余项为用户素材。
- P3 全部关闭（2026-08-23）：P3-1 规则订阅入口 `961a2d353`；P3-2 MockBookSourceFetcher 下沉 cfg(test) `b75426da3`；P3-3 词典注释与四分类台账更正 `a73e4a82b`（均独立复验通过）。

## 三、执行顺序

### P0：先恢复可交付性

#### P0-1 恢复可复现质量门禁（已关闭 2026-08-20）

**问题**：本轮 Rust 测试在写 `rust/target/debug/.fingerprint/.../lib-legado_net` 时返回 Windows `os error 5`；Flutter analyze 无输出挂起。

**行动**：

1. 检查 target 文件 ACL、占用进程和残留 Dart/Flutter 进程。
2. 在确认不影响用户未提交代码后，使用干净可写的 target 目录重跑 Rust QuickJS 门禁。
3. 重新运行 Flutter analyze、Flutter test，并记录 HEAD、通过数和耗时。
4. 将验证结果写入本计划或对应关闭报告，不以历史数字替代当前证据。

**关闭条件**：`cargo test -p legado-ffi --features quickjs`、`flutter analyze`、`flutter test` 在当前集成 HEAD 可复现通过；失败时记录真实失败，不得标绿。

#### P0-2 合流 parser/search parity 分支（已关闭 2026-08-22）

**问题**：当前分支包含 G1-G15、书山和搜索 parity 修复，但尚未合入 master；master 另有 2 个提交。

**行动**：

1. 从当前 master 创建集成分支。
2. 先合入 parser/search 分支，解决 URL、AES、JsonPath 和生成文件冲突。
3. 完成 Rust QuickJS、Flutter、FFI content hash、Android 双 ABI 和 5556/5558 冒烟。
4. 合流后更新 `docs/README.md` 与本计划的 HEAD/测试基线。

**关闭条件**：集成分支包含双方提交；全量门禁通过；发布构建使用同一批 codegen、Rust 二进制和 Dart 绑定。

**关闭记录（2026-08-22）**：合并提交 `81ad6e220` 同时包含 master（七猫 v2.0.92 + git 规范文档）与 feature（G1-G15、书山、搜索 parity、lint 清理）双方提交；全量门禁在合流后 HEAD 可复现通过（见「本轮验证」行）；同一批 codegen/二进制/绑定：frb_generated 双端重新生成（content hash 28124110）→ Android .so 双 ABI 重建 → verify-ffi-android PASSED → APK 构建安装冒烟双机通过。后续将集成分支合回 master。

#### P0-3 修复或下线 Server 多源搜索空实现（已关闭 2026-08-20，方案 B）

**问题**：`/api/search/multi` 直接使用 `NoopSourceSearcher`，返回成功但空结果；测试只断言 HTTP 200。

**决策**：方案 B（下线路由）。全仓检索确认无客户端调用该 HTTP 路由；`flutter_legado` 的 `search_multi` 是 FFI 桥同名函数，真实多源搜索走 `legado-ffi::api::search`（`WebSourceSearcher`）。Server 依赖 `legado-core`/`legado-net` 但不依赖 `legado-ffi`（会循环依赖），方案 A 需下沉搜索核心、超出本轮范围，故下线路由。

**实施**：移除 `/search/multi` 路由、`search_multi` handler、`MultiSearchRequest`/`MultiSearchResult`；删除仅断言 200 的两个测试；新增 `test_search_multi_route_removed` 断言 4xx 防回归。

**证据**：`cargo test -p legado-server` 170/0 + doctest；`cargo check -p legado-server -p legado-ffi --features quickjs` 无错误。`MultiSourceSearcher` 仍由 FFI 以真实 `WebSourceSearcher` 使用；`NoopSourceSearcher` 仅余 `legado-core` 内部单测引用。入口行为与 FFI 不再分叉。

### P1：跨轨契约和用户可见语义

#### P1-1 验证 FRB StreamSink 生成链路（已关闭 2026-08-22）

**问题**：生成代码中存在 StreamSink<String> 的 `unimplemented`/`UnimplementedError` 分支。静态代码不能证明其可达性。

**行动**：列出所有 StreamSink FFI 方法，在真实 DLL/so、非 Mock 模式下逐个验证订阅、事件、正常结束和取消；不得手改生成文件。若可达，修正源 API 或 codegen 配置后原子重生成、重编译、替换二进制。

**关闭条件**：每个流 API 有运行时证据和回归测试，或有生成器不可达性说明及版本固定证据。

**关闭记录（2026-08-22）**：提交 `577e4ce04`（test(ui): P1-1 验证 FRB StreamSink 流生成链路（真实 DLL），— Cursor Bridge）。新增 `test/ffi/ffi_stream_sink_runtime_test.dart`（277 行，8 项）：直接加载 `rust/target/debug/legado_ffi.dll`（quickjs 构建、非 Mock）+ 隔离临时 DB；5 个 StreamSink 流 API 逐个验证订阅/事件接收/正常结束；sourceCheck/debugBookSource 覆盖取消路径（wire 调用 + 干净结束 + 新一轮重置）；verification/webview 长期存活流验证 pending/submit/cancel 配套通道。UnimplementedError 分支不可达性四重证据：静态零调用点（decode 方向符号仅存定义、DcoCodec 实例化 0）+ sink 单向传入 Rust + 版本固定（pubspec 2.11.1 / lock sha256 / Cargo.toml =2.11.1 / codegenVersion 校验）+ 运行时（真实 DLL 8/8 全过，若可达必然抛 UnimplementedError）。门禁经主代理独立复跑：analyze 0 issues、flutter test +1217 全绿、cargo 三段 exit 0。已知行为：FRB RustStreamSink 长期存活流空闲时 cancel Future 不完成（应用代码不得 await 该取消，已记入测试注释）；kDefaultExternalLibraryLoaderConfig.ioDirectory 与工作区布局不符（rust_api.dart 显式搜索规避，既有项）。

#### P1-2 修复 AutoTask 原始 action 丢失（已关闭 2026-08-22）

**问题**：`AutoTask.toJson` 按 taskType 生成占位 script；在列表失败的降级路径中，真实 action 可能丢失，影响书名+作者匹配和任务导入。

**行动**：模型保存原始 script/action；展示字段与可执行载荷分离；为旧 JSON 增加迁移；补 refreshToc、更新源、备份、图书更新任务的 round-trip、导入和 fallback 测试。

**关闭条件**：任务创建、导出、导入、列表失败降级均保留真实 action，不再用展示模型覆盖执行脚本。

**关闭记录（2026-08-22）**：提交 `58b48484d`。根因：toJson 按 taskType 生成占位 script，复杂 JSON action 在创建/导出/导入/findBookUpdateTask fallback 路径丢失；新增 script 字段与 effectiveScript（展示与执行载荷分离），fromJson/toJson 双向兼容旧 JSON；12 项 round-trip/导入/fallback 单测全过，flutter test +1202。

#### P1-3 让 API 契约可自动校验（已关闭 2026-08-22）

**问题**：`API_CONTRACT.md` 仍记录 BookApi 252、附录 251，而当前源码统计为 BookApi 261、RustApi override 262。

**行动**：补一致性脚本/测试，比较 BookApi、RustApi、MockBookApi 方法集合和契约表项；明确 RustApi 多出的包装/兼容方法；更新契约正文、附录、变更记录。

**关闭条件**：新增 API 若缺 BookApi、RustApi、Mock 或契约条目，CI 失败；总数由脚本生成或校验，不再人工猜测。

**关闭记录（2026-08-22）**：提交 `6cbcea4f3`。新增 `flutter_legado/test/unit/api_contract_test.dart`（7 项校验，行扫描解析器，无正则依赖）；RustApi 公共额外方法钉死为 {toString}、MockBookApi 无额外公共方法；API_CONTRACT.md 同步 18 处：§1.7 补 4 对登录等价对、6 处章节标题计数（2.3/2.5/2.9/2.18/2.41/2.43）、附录 6 行计数，合计 251→263、BookApi 声明 252→260（程序化基线）。门禁：契约测试 7/7、analyze 0 issues、flutter test +1209。

#### P1-4 统一状态入口（已关闭 2026-08-22）

**问题**：`docs/README.md` 测试数字和当前分支成果滞后；旧剩余计划同时出现“全部完成”和大量开放项。

**行动**：`docs/README.md` 只保留完成基线、Active 计划、残余风险和当前验证入口；`REFACTORING_REMAINING_PLAN.md` 标为历史归档；所有新任务只进入本文。

**关闭条件**：任一当前文档不会把过期测试数字或历史开放项当作当前状态；链接全部指向有效文件。

**关闭记录（2026-08-22）**：提交 `e759bdd06`。docs/README.md 只保留完成基线、Active 计划、残余风险与当前验证入口（测试统计更新至 `6cbcea4f3`：flutter test +1209、analyze 0 issues，Rust 数字沿用 `81ad6e220`）；REFACTORING_REMAINING_PLAN.md 已归档 docs/过期文档/（AGENTS.md 计划路由同步收敛至本文）；四份当前文档链接审计全部指向有效文件。

### P2：技术债、边界和外部验收

- **P2-1 Rust 旧布局入口**（已关闭 2026-08-22）：核对 `layout.rs:232-326` 的 `char_from_index` 空实现是否有消费者；无消费者则删除/私有化，有消费者则改为真实文本输入并测试。Flutter 主阅读链仍以 Dart 排版为准。
  - **关闭记录（2026-08-22）**：提交 `d1186c711`（refactor(rust): 移除旧布局占位入口 zh_layout 与 char_from_index，— Cursor Bridge）。消费者检索经主代理独立复核：`zh_layout` 全 Rust 工作区零引用；FFI 导出面无暴露；Dart 绑定面无 crateFfi*Layout/charFromIndex（唯一命中为 Dart 本地排版模块 `zh_layout.dart`，按约束未动）。处置：删除共 187 行（根因：旧入口无文本入参、标点判断依赖恒空占位而恒退化为普通断行，属死代码）；新增源级守卫 `test_legacy_placeholder_entries_removed`（`include_str!` + `concat!` 编译期拼接防自匹配，锁定两符号不回潮且 `zh_layout_text` 保持导出）。门禁独立复跑：analyze 0 issues、flutter test +1217 全绿、cargo 三段 exit 0（SEG1 曾观测一次与 Flutter 全套并行负载下的瞬态失败，单独重跑各段全绿含 legado-core 789/0）。
- **P2-2 搜索实现统一**（已关闭 2026-08-22）：P0-3 完成后抽取 Server/FFI 共享搜索服务，避免两套入口长期分叉。
  - **关闭记录（2026-08-22）**：提交 `3b61f0883`（refactor(rust): 抽取书架模糊搜索共享服务统一 Server 双入口）。调研结论经主代理复核：FFI 网络多源搜索本已基于 MultiSourceSearcher 单一框架无分叉；真正分叉点是 Server REST /api/search 与 MCP 工具 search_books 各自内联同一书架模糊匹配谓词（书名/作者小写 contains），响应组装漂移（REST: intro/cover_url+total 包装；MCP: origin/latest_chapter + -32602 错误语义）。处置：新增 `legado_core::shelf_search::match_shelf_books` 纯函数服务（5 条单测），双入口委托、各自响应组装与错误语义逐字保留；FFI API 表面零改动（无 codegen/Dart 绑定触发，4 文件 +103/−15）。门禁独立复跑：cargo 三段 exit 0（core 794 / server 170 / js 497 / ffi 355）、analyze 0 issues、flutter test +1217 全绿。
- **P2-3 Mock 样本口径**（进行中）：书源/RSS/TTS 使用真实默认资产，但书架仍为占位数据；改文档为“部分真实样本”，后续补脱敏 Android 书架 JSON。进展（2026-08-22）：口径已登记 RESIDUAL_RISKS「其他待素材项」（核实 `mock_book_api.dart` L12-29/L58-63：书源/RSS/TTS = 原 Android defaultData 真实资产，书架 = 占位 TODO §6.4）；脱敏 Android 书架导出 JSON 待用户素材。
- **P2-4 A* 验收矩阵**（已关闭 2026-08-22）：WebDAV、音频/漫画/视频、ruleReview、真机媒体键、皮肤 zip、验证码等逐项登记素材、负责人、命令和证据；待验收不等同工程未实现，也不能销账为完成。
  - **关闭记录（2026-08-22）**：矩阵登记于 `RESIDUAL_RISKS_2026-08-13.md` §A* 验收矩阵（提交 `cb81703fd`）——10 项逐项（A1-A5、A9、A10 + V1 验证码实网 / V2 登录倒计时 / V3 外链确认），每行含素材/负责人/工程证据/验收命令。同日自测：**A9 深链 VIEW 已验证**（显式组件 `am start -n io.legado.flutter_legado/io.legado.flutter.MainActivity` 启动成功 + mCurrentFocus 确认）；并发现 emulator-5556 并存原版 `com.legado.app.release` 且双方注册 legado:// scheme，裸 VIEW 触发系统选择器（已记入命令块）。其余 9 项 ⛔ 待用户素材，不得以模拟器冒烟销账。
- **P2-5 生成代码和 feature fallback**（已关闭 2026-08-22）：按“生产路径/Mock/feature-disabled/生成器不可达”分类治理，取消全局零桩声明。
  - **关闭记录（2026-08-22）**：提交 `9b645eab3`（docs: 新增桩/Fallback/Mock 四分类登记，审计轮，零行为代码改动）。登记于 `docs/STUB_FALLBACK_CLASSIFICATION_2026-08-22.md`：生成器不可达 6 组（FRB StreamSink 解码方向 + wire 分发默认臂 + Pde 同步分发器 + 32 个 freezed 私有构造守卫）、Mock 9 组（USE_MOCK 双轨开关 + cfg(test) 测试夹具/设计内空实现）、quickjs 门控 182 处 cfg 归并 3 组（主代理复核计数准确）、生产路径防御/降级 5 组；不存在未登记的功能性空实现。全局零桩声明（原文在已归档 PROJECT_AUDIT_REPORT.md:14/:169/:219）废止，改用四分类可核查口径，新增桩/fallback 必须同步登记；归档文件已加历史注记。误归类提示：dict_state 内置词典 = 生产路径降级数据（非 Mock）；MockBookSourceFetcher pub 未挂 cfg(test)、当前仅测试消费（已核实），后续批次评估下沉 test 模块。

### P3：功能补齐与卫生项（2026-08-22 开启）

> P0/P1/P2 工程项全部关闭后的下一批。依据：AUDIT_FIX_ASSIGNMENT §2.1 旧阻塞项经复核——ruleSub FFI 已由 Task #89 交付（契约 §2.39，7 方法），剩余缺口为 **Flutter 管理页 UI**；另两项为 P2-5 审计标记的后续卫生项。

- **P3-1 规则订阅管理页 UI**（已关闭 2026-08-22）：对标原版 `app/.../ui/rss/subscription/RuleSubActivity.kt`（入口 `RssFragment.kt:136` 菜单）；FFI/契约已由 Task #89 交付（ruleSubList/Save/Delete/SetEnabled/UpdateOrder/CheckUpdate/ApplyUpdate，API_CONTRACT §2.39）。盘点发现：页面本体（`rule_sub_screen.dart` 778 行 / `rule_sub_notifier.dart` / `models/rule_sub.dart` / 路由 `/rule_sub` / 单测）已随此前批次（`8fd3a91af~5cf56a89c`）交付入库，唯一缺口 = 入口未接入。
  - **关闭记录（2026-08-22）**：提交 `961a2d353`（feat(ui)：规则订阅管理页入口接入订阅源管理菜单，署名「— Cursor UI」，版本 2.0.97+99 + CHANGELOG）。入口对标原版 RssFragment 头部条目 → Flutter 侧 `RssSourceManageScreen` 溢出菜单「规则订阅」（置于「导入默认规则」与「帮助」之间）→ `AppRoutes.ruleSub`（routes.dart L39/L72/L165，路由无需改动）。页面功能清单核验：customOrder 列表 / 拖拽重排（乐观更新+失败回滚）/ 表单联动（自动更新间隔，对齐原版）/ URL 校验 + findDuplicate 重复检查 / 删除确认 / 启用 Switch / 检查与应用更新 / 按类型导入。独立复验：flutter analyze 0 issues；flutter test +1217 全绿；冒烟 -SkipBuild PASSED EXIT=0（emulator-5556）。注：该提交顺带移除 rss_source_manage_screen.dart 首行 BOM（对 Dart 无影响）；并实证确认 Dart switch 无 fall-through，既有无 break 的 case 模式安全。
- **P3-2 MockBookSourceFetcher 下沉 test 模块**（已关闭 2026-08-23）：`rust/legado-core/src/web_book.rs` struct/inherent impl/trait impl 三个顶层项加 `#[cfg(test)]`。
  - **关闭记录（2026-08-23）**：提交 `b75426da3`（refactor(rust)，署名「— Cursor」，仅 web_book.rs +3 行）。grep 全 rust/ 确认 26 处引用均在本文件测试模块内、无跨文件/非测试消费者；不移动模块、不改路径、不改行为。独立复验：cargo 三段门禁 EXIT=0（workspace excl ffi / js quickjs / ffi quickjs，计数与基线一致）。
- **P3-3 dict_state 内置词典消费核验**（已关闭 2026-08-23）：核验结论 = **生产路径无静态内置词典**（非死 fallback，亦非降级数据点）。
  - **关闭记录（2026-08-23）**：提交 `a73e4a82b`（fix(ui)，署名「— Cursor UI」，版本 2.0.98+100 + CHANGELOG）。查询链 DictNotifier.lookup → BookApi.dictLookup → Rust FFI dict_lookup（dict_api.rs 真实规则执行，带单测）；Mock `_mockDict` 为合法 B 类夹具。三处过时文本更正：dict_state.dart:10 注释、STUB 台账 D3 行 + 易误标项①、docs/README.md L37 口径①。独立复验：flutter analyze 0 issues + flutter test +1217 全绿。

- **P3-4 JS 引擎逐调用重建性能回归**（已关闭 2026-08-25）：用户验收反馈——搜索速度与书籍详情加载明显慢于原版；退出搜索页返回书架后也变卡。根因已定位：js_executor.rs QuickJsExecutor::execute_js（L472–527）每次 JS 执行新建 QuickJS 引擎（实测中位 1.58ms/引擎，n=30）且每次调用重复 eval jsLib（最大 587KB）+ setup + Response/Jsoup bridge；legado-js compile 为 no-op（rquickjs 0.9 无字节码 API，每次重编译）。原版 AnalyzeRule.kt L891–936 = 单共享 RhinoScriptEngine + 编译脚本缓存（scriptCache.getOrPutLimit(jsStr, 16)，LRU 16）+ jsLib 只 eval 一次进共享作用域。
  - **行动**：按书源缓存引擎（进程级静态 LRU 淘汰，key=source_tag；jsLib/setup/bridge 建引擎时一次性 eval，保留降级告警语义）；逐脚本分类——含顶层 const/let 的脚本继续走新引擎路径（规避 redeclaration），其余走缓存快路径 + 运行时 redeclaration 错误回落新引擎并标记 lexical；保持 completion-value / non-strict / 64MB 内存上限 / 每次 eval 截止时间语义。双路径适用：QuickJsExecutor（@js: 规则）与 JsSourceEngine::new_quickjs（mainJs 编排器）。
  - **关闭条件**：cargo 三段门禁绿 + 新增回归测试（jsLib 跨 eval 持久、redeclaration 回落、completion-value 不变、LRU 淘汰）；真实书源搜索/详情耗时明显优于修复前；5556 冒烟 PASSED + 5558 用户验收（搜索速度、书架响应）。
  - **关闭记录（2026-08-25）**：批次 A 交付（版本 2.0.105+109，CHANGELOG [2.0.105]，署名「— Cursor」）。新增 `rust/legado-js/src/engine_cache.rs`（进程级按书源缓存引擎：key=executor:source_tag / mainjs:source_url:main_js，LRU cap 8，指纹变化重建；jsLib/setup/RESPONSE_BRIDGE_JS/JSOUP_BRIDGE_JS/mainJs 构建时一次性 eval）+ js_executor.rs lexical hash-set 回落（redeclaration → 标记脚本 + 新引擎重试）+ source_engine.rs main_js_loaded 按构建期 eval 实际结果判定。回归测试：jsLib 跨 eval 持久 / redeclaration 回落 / completion-value 不变 / LRU 淘汰（TEST_LOCK 串行化）。实测 debug n=30：中位 1084µs/eval → 2µs（-99.8%）。独立复验：cargo 三段门禁 EXIT=0（workspace excl ffi / js quickjs 499 pass / ffi quickjs 357 pass + 2 qibuge 环境失败基线）。
  - **关闭记录（2026-08-25 续，第二阶段）**：批次 A 交付后用户复测仍慢（「无很大或明显改变」+ 搜索结果页滚动卡死）。二次根因定位（真实测量）：① 模拟器 APK 打包了 **debug 编译的 liblegado_ffi.so**（emulator_smoke_test.ps1 L81 硬编码 -Mode debug），实测同 favcomic 正文 debug vs release：get_elements(36项) 73ms vs 8ms、单条5字段 ≈60ms/字段 vs ≈5ms/字段、解析 C≈12.0s vs ≈1.0s——Rust 侧慢约 10 倍，批次 A 的 ~80ms/源 引擎缓存收益被完全淹没；② CoverDecodeLoader 每个 origin miss 只缓存单条且每次 miss 触发整表 getBookSources FFI（~590KB/500源），滚动 N 个新封面 = N 次全量 FFI + 主 isolate jsonDecode → 卡死。修复：冒烟脚本 .so 改 release 编译；CoverDecodeLoader 重写为整表内存注册表（首次 miss 单次 FFI，并发共享 in-flight Future，RustApi 7 个变更方法集中失效，对齐原版 BookSourceRepository 内存语义）。批次 C 交付（版本 2.0.107+111，CHANGELOG [2.0.107]，提交 `83ff6a8a8`，署名「— Cursor UI + Tool」）。独立复验：flutter analyze 0 issues + flutter test 1243 全绿；cargo 三段门禁（workspace/js EXIT=0、ffi quickjs 357 pass + 2 qibuge HTTP 404 环境失败基线）；**两级模拟器验证 PASSED**——5556 冒烟 7/7（release .so content hash 校验 + 2.0.107 安装 + 存活 + 无崩溃）、5558 验收 7/7（-SkipBuild -CheckUI，书架/发现/订阅/我的元素齐全）。
  - **工具修复（2026-08-25）**：emulator_smoke_test.ps1 补 UTF-8 BOM——harness 的 pwsh 包装器实为 Windows PowerShell 5.1，按 GBK 解码无 BOM .ps1，脚本中文注释触发级联解析错误（L87/89/92/174）；补 BOM + 头部编码警告注释后 PS5.1/pwsh7 双兼容。
- **P3-5 换源页 UI 对齐原版**（已关闭 2026-08-25）：用户反馈——换源界面与原版不一致。对照 ChangeBookSourceDialog.kt（475 行）+ ChangeBookSourceAdapter.kt 与我方 change_source_screen.dart：① 原版列表项有 👍/👎 评分按钮（SearchBook.bookScore 持久化，影响展示）；我方为自创「匹配分」数字角标（原版不存在的创意功能 = 重构红线项，应移除）；② 原版支持长按列表项 → 操作菜单（置顶 / 置底 / 编辑书源 / 禁用书源 / 删除）；我方仅点按切换；③ 原版底部栏：当前源名（点按滚动定位）+ 上/下滚动按钮；我方无；④ 原版 Toolbar = 书名（title）+ 作者（subtitle）；我方单行「换源 - 书名」。
  - **行动**：加 👍/👎 评分（含小幅增量 FFI：score 持久化 searchBooks + 响应返回）、长按操作菜单（置顶/置底 = UI 本地重排；编辑书源 = 导航书源管理；禁用/删除 = 增量 FFI deleteSearchBook / disable-by-url，同步更新 API_CONTRACT.md）、底部栏、标题布局；移除自创数字角标。
  - **关闭条件**：flutter analyze/test 绿 + cargo 门禁（新 FFI 方法）+ 5556 冒烟 PASSED + 5558 用户验收（与原版逐项对照）。
  - **关闭记录（2026-08-25）**：批次 B 交付（版本 2.0.106+110，CHANGELOG [2.0.106]，署名「— Cursor UI + Bridge」）。① 👍/👎 评分（Red A200 / Blue A200）+ 增量 FFI updateSearchBookScore / deleteSearchBook + searchBooks.bookScore v106 迁移 + source_matcher book_score 优先排序 + sync_source_score_delta 书源聚合分；② 移除自创「匹配分」数字角标（红线项）；③ 长按五项菜单（置顶/置底/编辑书源/禁用书源/删除，删当前源自动切下一候选）；④ 底部栏（当前源标签点按滚动定位 + 上/下滚动按钮，hasClients 点按时判定）；⑤ title=书名 + subtitle=作者。独立复验：flutter analyze 0 issues + flutter test 全绿（api_contract_test 程序化校验 §2.4=16 / 合计 267）+ cargo 三段门禁 EXIT=0。

- **P3-6 搜索速度与结果一致性修复**（开放，2026-08-28）：源码审查确认 Flutter 主搜索走 `run_multi_stream -> search_single_source`，未复用较完整的规则搜索实现，导致登录检查、详情页回退、书源上下文 JS、单源去重等原版语义存在分叉；同时存在取消残留任务、入口语义不统一和 `originOrder=0` 风险。先完成离线原版响应夹具、QuickJS 产物 feature 核验和双包同库基线，再按“统一单源执行器 → 会话级取消 → 过滤/聚合/持久化一致性 → 性能剖析”实施。详细验收矩阵、依赖顺序与非目标见 `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md`。本项未实施，不得以已有审计文档或当前未提交代码宣称已关闭。

**进度更新（2026-08-29）**：按 `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` §8 执行。
- ✅ **已完成**：离线原版响应夹具（S0-B，`511a0bb52`，七场景+主执行器消费测试）；统一单源执行器收敛（S0-E，`4330acaf9`，loginCheckJs/pattern 直连/空列表回退/bookUrl 回退/去重键/非 2xx 六项对齐）；会话级取消收尾（P0-3，`c5f82a854`+`91e40dfad`，双机实机 e2e 7/7，verdict 归档）；G4 修复（`bb521c366`）。
- ⛔ **未完成（标记）**：**S0-C 原版端终态证据采集**——5558(LDPlayer) 环境阻断（adb reverse 数分钟内静默僵死、设备→主机直达被防火墙拦截、原版 release 无 run-as、debug 变体缺 mavenLocal 构件），已三轮攻坚未闭环；续作三路径与实测窗口数据见该计划 §8.8。S0-C 未闭合前 P0-2 S0 与 P0-1.4 保持 DEFERRED。
- ✅ **阶段三已完成（2026-08-29）**：过滤/持久化一致性——precision filter 解析期对齐原版（`837516a08`，precision_filter_match 三字段或语义 + parse_search_response_ex，应用点=列表循环/pattern 直连/空列表回退，FFI 签名零变更经配置读取，p3f_tests 5 项；workspace 2479/0）。聚合一致性此前已由 fix34 批次对齐。
- ✅ **上游安卓源码同步完成（2026-08-29）**：upstream(LegadoTeam/legado) 506 提交(#397→#1072,v3.26.082823,cronet 152.0.7977.54) 已合入集成分支 `integration/upstream-3.26.082823`（合并提交 `6314f5b215`,161 冲突全部取上游版——本地安卓侧=#543 纯快照无本地修改需保留,README 取双轨版）。门禁：`assembleRelease -Pksp.incremental=false` BUILD SUCCESSFUL（R8 处理新 htmlunit MethodHandle;debug 变体 D8 在 minSdk 23 下无法 dex 新 htmlunit,上游 CI 亦仅构建 release）;`testAppReleaseUnitTest` 1809 中 1807 通过（2 个符号链接测试为 Windows 环境差异,上游 CI 为 Linux）;flutter_legado/rust 零触及。**合回 master 待 UI 轨提交其 49 个未提交文件后执行**（当前 checkout/merge 均会覆盖其 WIP,按协作规则避让）。
- ✅ **体检缺陷修复跟进（2026-08-29 续）**：REFACTOR_DEFECT_AUDIT 18 项中已闭环 9 项（§一.2 前台服务 `405e82a413`、§二.5 Custom JS `bde0dddfa2`、§二.6 PROPFIND `de4a69d3ea`、§三.10 CI 补强 `8ac2410a0c`、§三.12 热点锁、§三.14 缓存容量、§四.15 .gitignore、§五 口径 2 项）+ 上游 506 提交同步（集成分支待 UI 轨 WIP 提交后合回 master）。**仍开放**：§一.1 v7a（决策已登记：发布矩阵剔除 v7a JS）、§二.4 cmap（下一批次）、§二.7/§二.8（REST 通道产品决策）、§三.9、§四.16、S0-C 原版端（环境）、S0-D。
✅ **体检缺陷修复跟进（2026-08-29 续2）**：§一.1 v7a 决策=保留降级 v7a（原版支持 ARM32,剔除会断装;后续可评估 boa 补齐）;§二.7 REST 删除=对齐原版(原版无 REST 层,数据直查 DB;REST 属新增功能违反重构红线,整批删除约 150 行);§三.10 CI 补强已提交。
- ✅ **体检修复跟进决策（2026-08-29 用户确认）**：v7a=保留降级(原版支持 ARM32,不剔除);§二.7 REST 死路径=整批删除(原版无 REST 层,红线对齐);§一.1 v7a=保留降级(原版支持 ARM32);S0-C 原版端=LDPlayer 桥接模式浏览器可达但搜索不调度夹具源(千真实源阻塞遍历),需 debug 原版 run-as 或禁用真实源。
- ▶️ **剩余**：仅性能剖析（S0-D）——关闭条件依赖双包同基线分段计时，受 S0-C 原版端环境阻断约束，待环境问题解决后执行（分段计时探针 LEGADO_SEARCH_PHASE_TIMING 已存在）。


## 四、文档治理

| 文档 | 当前职责 |
|---|---|
| 本文 | 唯一当前开放项与执行顺序 |
| `docs/README.md` | 当前状态和文档索引 |
| `API_CONTRACT.md` | 跨轨接口契约 |
| `TWO_TRACK_DEV_SPEC.md` | 双轨与 codegen 纪律 |
| `RESIDUAL_RISKS_2026-08-13.md` | A* 和工程残余风险 |
| `SOURCE_DIFF_AUDIT_2026-08-13.md` | 原版源码差异证据 |
| `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` | 搜索速度与结果一致性当前修复计划 |
| `UI_MD3_PLAN.md` | Flutter UI 视觉迁移至 MD3 Expressive 的当前执行计划（UI 轨独立推进，不涉 Rust/FFI） |
| `PARSER_GAP_FIX_PROGRESS_20260815.md` | 解析 parity 交接与证据 |
| `过期文档/README.md` | 历史文档目录和替代关系 |

新增计划、报告、交接文档必须放在 `docs/`；历史材料只允许放在 `docs/过期文档/`，不得再创建新的日期版计划散落在根目录。

编写者：Codex ｜ 2026-08-19
修订：主代理 ｜ 2026-08-20（P0-1 关闭；P0-2 merge-tree 预检与进度记录）
修订：主代理 ｜ 2026-08-22（P0-2 合流关闭：合并提交 81ad6e220、codegen 同步、门禁与冒烟基线更新）
修订：主代理 ｜ 2026-08-22（P3-1 关闭：入口接入 `961a2d353`，独立复验通过）
修订：主代理 ｜ 2026-08-23（P3-2/P3-3 关闭：`b75426da3` / `a73e4a82b`，独立复验通过；STUB 台账 MockBookSourceFetcher 登记项同步关闭）
修订：主代理 ｜ 2026-08-25（P3-4/P3-5 开启：用户验收反馈——搜索/详情性能回归根因定位 + 换源 UI 对齐清单；两批并行实施，A→B 顺序交付）
修订：主代理 ｜ 2026-08-25（P3-4 关闭：批次 A `6e04cda43`（版本 2.0.105+109）；P3-5 关闭：批次 B 提交（版本 2.0.106+110），独立复验通过）
修订：主代理 ｜ 2026-08-25（P3-4 第二阶段关闭：双根因批次 C `83ff6a8a8`（版本 2.0.107+111）——debug .so + CoverDecodeLoader 整表注册表；冒烟脚本补 UTF-8 BOM（PS5.1 GBK 解码根因）；两级模拟器验证 5556/5558 全 PASSED）
修订：Codex ｜ 2026-08-28（P3-6 开放：搜索主路径与原版深度源码审查，专项修复计划和验收矩阵登记）
修订：Qoder UI ｜ 2026-08-28（治理步骤：UI 开发规范由 apple-ui-designer 技能切换为 Material Design 3 官方指南，AGENTS/design_system/本档三处同步，据 UI_MD3_PLAN.md 第十四节独立 commit；P3-6 搜索 parity 修复仍由后端轨并行推进，互不干扰）
修订：Qoder + Bridge ｜ 2026-08-30（iOS 轨立项——用户授权「Flutter+Rust 三端通用」，可行性勘察落盘 docs/IOS_TRACK_FEASIBILITY_20260830.md：ios 脚手架无 Podfile/FFI 静态链接待接线/10 原生桥插件对照（flutter_tts·audio_service·flutter_inappwebview 等）/macOS runner 未签名 ipa 方案；分 P0-P3 四阶段待用户确认启动）
修订：Qoder + Bridge ｜ 2026-08-30（GitHub CI 收敛：修复 fork 三处持续 workflow 错误（Sync Upstream 每日失败/flutter-ci 工具链 E0463/test.yml 无效文件 0 秒失败）；按用户指令「安卓源码不上传 GitHub」解除 app/modules 跟踪并从远端树移除、删除全部安卓工作流，本地 .gitignore 登记不上传名单）
修订：Qoder + Bridge ｜ 2026-08-29（搜索/换源 parity 审计 D1-D6 修复：分组分隔符全集/换源候选不再剔除空 bookUrl/multi_source_search 落库/JS 源 precision filter/筛选框书名口径/同名判定字面全等，据 SEARCH_CHANGE_SOURCE_PARITY_AUDIT_20260829.md，版本 2.0.127+132）
修订：Qoder + Bridge ｜ 2026-08-29（热力图每日时长契约交付：readRecordDaily 聚合表 + readRecordDailyList FFI（API_CONTRACT §2.12）+ putReadRecord 写路径增量聚合 + Dart 三层绑定；U 侧 UI_MD3_PLAN 登记项销记）
修订：Qoder UI ｜ 2026-08-28（MD3 UI 迁移 B0–B6 七批次完成：主题地基/12 套内置调色板/主框架/六功能域 token 收尾/验收矩阵自动化，版本 2.0.110–2.0.117，详见 UI_MD3_PLAN.md「实施状态」；遗留 LargeTitle 与 Material You 动态取色已登记，模拟器冒烟并入用户验收）
