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

- **P2-6 规则引擎 `{{…}}` 模板语义收敛的剩余面**（**已关闭 2026-09-18**，批次 2.0.285+286）：上一批（2.0.284+285，换源「新书源未解析到任何章节」两层根因）收敛时留下的 (a)~(h) 八项已全部处置：
  - **(a) `get_elements` 链内模板段** ✅：Extract 段同步模板语义（判定域取拆分后核心、段前 JS 步先 flush、模板字面结果作后续 JS 步的前置 result）；新增 2 条测试（模板段 / 模板段后接 JS 段）。
  - **(b) 非法正则回退口径三处不齐** ✅：parser `apply_hash_replace` 对齐上游（replaceFirst → `replacement`；全文替换 → **字面**替换），与 FFI `apply_regex_replace` 口径一致；补单测 + e2e 双形态。
  - **(c) `{{js表达式}}` + 选择器后缀/组合符** ✅：**对齐上游**（上游首个 `{{` 位于段首即 Mode.Regex → 字面返回）；逐条核对 526 源语料 52 条候选（8 条单跨度带后缀 / 18 条整段单跨度 / 26 条多跨度），其中 5 条真实 `tocUrl` 由「取空」变为正确 URL（清风小说网/对小说-夜明空/书文小说/笔趣阁/PO18），**无规则依赖旧 G11 后缀行为**；G11 收窄为「整规则恰为单个 JS 表达式跨度且无包装」。
  - **(d) 模板命中时 JS 表达式参数重复执行** ✅：`template_shape` 命中时跳过顶层 `expand_js_refs`；`test_template_hit_js_param_executes_once` 断言 `js_calls == 1`（含参数返回空的场景，此前为 2）。
  - **(e) `java.getString` 绑定层不做 JSONPath 分派** ✅：`legado-js` 新增 `dispatch_rule` 分派层（复用 parser 的 `parse_rule_prefix` / `detect_content_type`，避免与 parser 逻辑漂移），`getString(s)` / `getElement(s)` 同族一并对齐；松鹤真实 fixture 断言 kind 段 `298.6`（不再 `0.0万字`）、免费章 **0/712** 带 🔒。
  - **(f) 琐记四项** ✅：链段模板判定改用拆分后核心；`split_top_level_hash(rule, 0)` 返回空（与 `splitn(0)` 一致）；两段 `##regex###` 死分支移除并对齐上游/FFI；`@js:`/`<js>` 落在 `{{…}}` 跨度内不再误判为 JS 段（各配测试）。
  - **(g) 换源后书籍 `bookUrl` 未随新源更新** ✅：于换源事务内改键（走 `Repository::insert` 的 (name,author) 冲突路径 `remap_book_url_preserving_chapters`：迁移 chapters/highlights/cached_chapters/download_tasks + 删旧行 + 写新行），章节按新键重写、两键缓存清空；测试断言「新键有行 / 旧键无残留 / `toc_url` 为新解析值」。
  - **(h) `elem_analyzer` 缺 `book` JS 绑定** ✅：逐章解析器补 `with_js_binding("book", …)`（对齐上游 `BookChapterList.kt:236-245`），5 源（民间故事/涨姿势/华语中文/月亮小说/可阅文学）章节名恢复；`test_chapter_name_can_use_book_binding`。
  - **验证**：`cargo test --workspace` **exit 0 零失败**（parser 282 / ffi 358 / js 236·quickjs 531 / core 792 / db 302 / book 150）；`cargo clippy --workspace -- -D warnings` exit 0；`cargo fmt --check` 0 处；实机验证见 CHANGELOG [2.0.285]。
  - **顺带修复（非 P2-6 项）**：`legado-book` TXT 搜索测试临时文件名仅用时间戳，Windows 下 SystemTime 粒度约毫秒级会撞名 → 并行用例共用文件致 `test_search_case_insensitive` 偶发失败；改为时间戳 + 进程内原子序号。

- **P2-7 本批实测新发现的三条**（**全部关闭 2026-09-19**）：**(a) 已关闭**——根因是引擎两处缺陷（裸 `@attr` 取空 + 含 `=` 的括号被当索引区间），已在 `rust/legado-parser/src/html.rs` 修复（提交 `dd842e53d7`）：离线实测网阅小说目录由「1 章垃圾」恢复 **688 条互异 URL**、`meta[property="og:…"]` 由 19 行 junk 恢复 1 行；影响面 21 条规则/15 源；parser 287 测试全绿。**(b) 见 (c)**：
  - **(a) 网阅小说书源目录解析产出垃圾**：实机发现该书源的目录被解析成 **1 章**、章节名为网页文本（`斗罗大陆,唐家三少,斗罗大陆在线阅读,斗罗大…`），落库于 `chapters`（key=该书 bookUrl）。疑似该源 `ruleToc` 与响应形态不匹配（或 tocUrl 指向了 HTML 页而非目录接口）。**观测点**：2026-09-18 10:07 MuMu 实机（`.tmp/dbsrc/q7.db`：books 行 originName=📂网阅小说、chapters 仅 1 行）；本批修复后未再复现该状态（切回松鹤庭沐已恢复 712 章）。待用该源 + 真实响应离线复现后定性。
  - **(b) CI quickjs 步骤偶发 SIGSEGV**：提交 `54993b6246` 的 Rust CI 首跑在 `Cargo test (quickjs)` 段进程级崩溃（`signal: 11, SIGSEGV`，无断言失败、崩溃前若干 quickjs 用例皆 ok），**重跑同一 job 即通过**；本批在 `legado-js` 新增 15 条测试（分派层 8 + 绑定级 7）提高了并行内存压力。本机（Windows）连跑两次 531 全过、无法复现，判定为 Linux 运行器环境相关的 flake。建议后续：（i）为该步骤评估固定 `--test-threads` 或串行化重（内存）用例；（ii）若复现，用 `RUST_BACKTRACE=1` + 逐用例二分定位。**注意**：此前排查 §三.9「内存限制测试」时记录了 Linux CI 才跑的沙箱安全线用例，本次崩溃与该类用例的关联性未确认。
  - **(c) (b) 的根因与收口（已关闭 2026-09-19，提交 `d689584fef`）**：`engine::quickjs_tests::test_sandbox_memory_limit`（rust/legado-js/src/engine.rs）原脚本（`arr.push(new Array(1000).fill('x'))` 十万次）踩的是 **rquickjs-sys 0.9.0 内置 quickjs-ng 0.8 的 `build_backtrace` 重入 OOM use-after-free**（WSL gdb 硬件 watchpoint 实证、非推测）：首次 OOM 造出 InternalError 对象 E 挂上 `rt->current_exception` → 异常上抛走补栈回溯（quickjs.c:17439）→ `build_backtrace` 自身 `dbuf_printf` 再分配又 OOM → `JS_Throw` **无条件**释放 `current_exception`（quickjs.c:6471）——释放的正是**待补栈的 E 自己** → `free_object` 置 `E->shape = NULL`（quickjs.c:5567）→ `build_backtrace` 末行仍 `JS_DefinePropertyValue(E, "stack")`（quickjs.c:6792）→ `find_own_property` 读 `sh->prop_hash_mask`（quickjs.c:5337，偏移 0x20，sh==NULL）→ SIGSEGV。**推翻旧登记两处结论**：① 崩溃点不是 `JS_SetPropertyValue`/`class_id`（偏移 0x20 属 `JSShape.prop_hash_mask`）；②「间歇性来自并行内存压力」不成立——真正变量是「首次失败后剩余 JS 堆余量」这一**跨环境刀锋条件**：CI 同一二进制 3/3 全崩（run 35428715961 / 35421417710 / 35384930834），而 WSL 在 512KB 下单跑 8/8 通过、把上限提到 400000 字节即 **5/5 确定性崩溃**。故 `47552f1064` 的「串行单跑隔离」自始无效——隔离步骤自己就崩（run 35428715961 可见）。**处置（本版）**：用例改为单次巨量分配 `new Uint8Array(200 * 1024 * 1024)`——quickjs 默认 `malloc_limit = 0`（无限，quickjs.c:1787）且超限判定先于分配器直接拒绝（quickjs.c:1468），故该请求既保留「内存上限被强制执行」的判别力（无上限时会成功），又因被提前拒绝、堆内余量充足而必走干净 OOM 路径；WSL(Linux) 与 Windows 各 5 档上限（256KB/384KB/512KB/1MB/64MB）实测「返回 Err 且不崩」，错误消息恒为 `out of memory`。CI 侧撤销 `--skip` 与隔离步骤，用例回归主测试档（覆盖不减、结构复原）。**根治遗留 → P2-16**（生产 64MB 上限下同型崩溃理论可达）。

- **P2-8 换源改键（书籍 URL 随新源更新）**（**已关闭 2026-09-18**，提交 `dd842e53d7`）：**采用方案 A 落地**——书籍主键 `bookUrl` 保持稳定（持有者零改动），新增 `originBookUrl` 承载「当前书源详情页地址」（DB v108→v109），所有「抓取书籍页」路径统一走单一取址点（Rust `Book::book_page_fetch_url` / Dart `BookOpenUtils.bookFetchUrl`，空则回退 `bookUrl`）；换源事务写入该字段但 `bookUrl` 不变。实机闭环：迁移成功、连续两次换源主键不变、进详情页后 `tocUrl` 未被刷坏；写侧审查 P1-1（全行 UPDATE 静默清空）已修（`fill_origin_book_url_if_empty` + 自愈补列 + Dart 自动换源补字段），其余审查项转 P2-10。历史记录与旧方案取舍如下：P2-6(g) 曾按原版 `SearchBook.toBook()` 语义在换源事务内**把书籍主键从旧源地址迁到新源地址**（`54993b6246`），实机回归后**已回退**（本提交）。
  - **回归现象**：换源成功后，换源入口再次调用即报 `Database error: 书籍不存在`（对所有书源）——根因：应用内多处仍持有**旧地址**（书架内存列表的 Book 对象、详情页打开时传入的 URL），而 `switch_book_source_with` 用 `find_by_url(book_url)` 查书（`source_switch.rs:587`）。主键迁移使旧地址失效 → 全部换源入口报错。P0 级。
  - **正确做法（待重做，需整体设计）**：改键必须与「所有 URL 持有者同步」一起做——至少包括：换源返回的新 URL 已在 Dart 侧被用于重开详情页（`book_info_screen_builders.part.dart:2007-2013`）✅，但**书架/其它 provider 的内存对象**、`searchBooks` 候选、以及任何按 bookUrl 索引的缓存都需一并失效/刷新；或改键时保留一份「旧键 → 新键」的别名表供过渡期查询。
  - **回退后遗留的真实危害仍在**（即当初做改键的动机）：换源后书籍仍以旧源地址为键 → 详情页 U7 后台刷新（`book_info_screen_load.part.dart:210` 的 `webbookInfo(sourceJson, b.bookUrl)`）会用旧地址 + 新源规则解析 → `tocUrl` 被重推成 `…?bookId=` 退化值并「非空即覆盖」回写。**低成本缓解（建议下一步先做）**：在该刷新合并处对 `tocUrl` 加「解析值形态校验/退化值不覆盖」守卫（只动 Dart 合并层，不动主键）。

- **P2-9 书源引擎对照审计结论与待补清单**（**①②③④⑤已关闭 2026-09-19**；⑥~⑬ 开放）：③④⑤ 已落地（flow-scope 化 `java.put`↔`@get` 桥 + 入口收口、`@put` 走完整管道、`%%` 首列表定界），证据见 CHANGELOG [2.0.291]；审查 P1/P2 全部修复。③ 残留（登记）：完整「一进程内两本书流程真并行」需 per-execution scope ID；`preciseSearch` 独立调用继承调用方 scope；`explore` raw-eval 按设计写裸键；server 无 JS 执行器；嵌套 `@put` 的 `}` 泄漏为已知限制。② 的首次详情 DB 兜底、② 的 `cache.*` 磁盘注入等仍见 P2-11。历史记录：①② 已落地——JS 宿主方法补齐（`getStringList`/`setContent`/`cache.*`/`java.lang`·`java.util` 最小面/`java.delete`/`hexDecodeToByteArray`/`upLoginData` no-op）+ `src` 重绑定（子步单参 `java.*` 重解析顶层原始响应，语料反例 0）+ `book` 绑定扩面与 `getVariable`（按 bookUrl 读 DB 用户变量，回退 `@put` 导出）；源级效果见 CHANGELOG。剩余 ③④⑤⑥~⑬ 仍开放：对上游 `app/.../analyzeRule/**` 做对照审计（20 组成对实验，14 组等价 / 0 处结构性偏差；526 源真实命中统计）。**结论：不需要大修**，剩余 13 项偏差均可增量修补，按命中排序：
  1. **JS 宿主方法缺失**（~160 处用法 / 15–20 源）：`java.getStringList` 15 处/5 源**全部无守卫**（ReferenceError 致规则失败）、`java.lang.*` 36/18、`setContent` 13/7、缓存内存三件套、`upLoginData` 7/6、`hexDecodeToByteArray` 等 → 批量注册 + 源级冒烟。
  2. **`book` 绑定缺口**（12–13 源）：我方只绑 `{name}`，上游为完整实体；`book.getVariable` 9 源（破坏性）、`book.bookUrl` 16/`author` 11/`name` 14 **静默空值** → 扩为字段子集（数据源现成）。
  3. **`java.put`（进程全局 store）↔ `@get`（analyzer 本地 store）无桥**（3 源：小米阅读/就去看网/手机小说）：手机小说 `tocUrl` 取空回退 book_url → 目录页错 → `get()` 兜底读全局 store 或流程入口 seed。
  4. **`apply_put_map` 只取首值**（4 源）：`@put:{y:#t@text##ab##XY}` 全损 → 改走完整 `get_strings` 管道。
  5. **`%%` 定界**（3 实现 / ~4 源）：我方 max_len vs 上游「首列表为界」→ 改 zip 边界 + 回归断言。
  6–13（登记）：越界 `$n` 回退（0 命中）、JS 单值数组 join（`a,b` vs `a
b`）、`nextChapterUrl` 未绑定（1 源）、search/explore 的 `book` null vs undefined（守卫式等价）、`fromBookInfo` 硬编码 false（0 命中）、Rhino `Packages.*`/`android.util.Base64` 互操作（3 源，架构性限制）、`source.refreshExplore`/`variableComment`（1|1）、全局 store 生命周期（随第 3 项处理）。
  - **新登记（2026-09-22，队列末项：Rhino `java.io` 最小 shim，取证驱动；同日 code-review 修后重校）**：语料 916 源中 `java.io` 面**字面**命中仅 `ByteArrayInputStream`/`ByteArrayOutputStream`（**5 源**：语料 #21/#36/#58/#304/#389，听友M/微信读书 wrInflateRaw 流，`quickjs_impl.rs` 已 shim）；**抽象基类 `InputStream` 字面 0 命中**，但 **favcomic（索引 703）混淆体在运行期解码后探测**（`.prototype`/`instanceof` Java 式类型探测，为 decode 路径的 Java 解密分支脚手架，经 `ruleContent.imageDecode` + `coverDecodeJs` → `decode(result)` 真实 content/cover 可达）。其**真实数据路径**是 `java.createSymmetricCrypto`（CryptoJS AES）+ `java.strToBytes`，`InputStream` 只搬运字节。**结论（用户口径「能力清单、只覆盖用到的类、用户提示必须保留」）**：**实施 `java.io.InputStream` 最小面**——纯内存字节缓冲读流（方法挂 **prototype** 使 `instanceof`/`.prototype` 成立，`new` 与普通调用双支持，无真实 JVM 对象/文件 IO/反射），走既有能力台账登记路径，**加法式、零 FFI 签名变更、零新依赖**（落点 `rust/legado-js/src/host_api/quickjs_impl.rs`）。**Java 语义（审查修）**：构造器**拷贝**输入字节（不别名调用方 buffer）；字符串/`java.lang.String` 输入经宿主 `java.strToBytes` 转字节（失败抛可读错误，**绝不**静默产生空流）；`read(b,off,len)` 的 buffer 参数覆盖全部 TypedArray（含 `Int8Array`）+ plain Array（一律就地写、不拷贝）；越界/负 off/len 抛可读 `RangeError`（不静默截断）；len==0 读 0 字节返回 0（即使 EOF）、EOF 且 c>0 返回 -1；`mark`/`reset` 按 Java 语义经 `_mark`（reset 回到 mark 位置、未 mark 即 0，与 `ByteArrayInputStream` 一致）——审查决策取「2 行 `_mark` 修复」而非「删除 no-op 实现」，依据：审查要求已实现成员行为不受影响，而 Java 语义修复仅 2 行成本。**实例哨兵（审查修）**：构造器返回 get 陷阱 Proxy——已知成员（read/available/skip/mark/reset/close/`_bytes`，含原型链继承）直通（`in` 语义不受影响，`instanceof`/`.prototype` 探测仍成立，favcomic 依赖）；未知字符串成员回落类级同款哨兵（读取安全并登记 `java.io.InputStream.<成员>` 前缀台账键、调用/new 抛 `此书源需要 Java 脚本能力（Packages.java.io.InputStream.<成员>），当前不支持`），未覆盖成员不再静默 `undefined`；`_bytes` 保留实例暴露（`JSInflaterInputStream` 的 `inStream._bytes` 提取依赖）。**显式不支持（登记 + 保留提示，非本次范围）**：`PrintStream`/`FileReader`/`FileWriter`/`StringReader`/`StringWriter`/`BufferedReader`/`BufferedWriter`/`DataInputStream`/`IOException`（语料 0 命中 + 语义依赖真实 JVM 类型系统/文件 IO/反射，强行模拟即违反「不照搬 JVM」红线）——命中时抛 `此书源需要 Java 脚本能力（Packages.<全名>），当前不支持` 并经 `record_unknown_java_symbol` 登记能力台账（首次登记 eprintln `[legado-js] 能力受限登记`）。**e2e 签名（审查修后诚实重校）**：IIFE 顶层返回值字面 `undefined` 在 shim 上线前后**同值、不具区分力**（审查实测：`delete Packages.java.io.InputStream` 的哨兵态同样完成加载并返回 `undefined`——字节码吞掉异常后回退路径不产生返回值）；真实区分点 = ① `java.io.InputStream` 解析为可用函数（isFn/`.prototype.read`/instanceof/read 探测全过）+ ② 台账**不再**登记 `java.io.InputStream` **前缀**键（台账负断言用**前缀匹配** `starts_with`——精确等值会漏掉 `java.io.InputStream.<成员>` 类后缀键）+ ③ 未覆盖符号（`java.io.PrintStream` 等）仍抛可读文案 + 登记（保护不放松）。测试：单测 `test_packages_shim_input_stream` / `test_packages_shim_input_stream_capability_ledger`（含实例哨兵段 + 前缀断言）/ **`test_packages_shim_input_stream_java_semantics`（审查修新增：构造拷贝/Int8Array 就地写/越界抛错/len==0/字符串输入/mark 复位/实例哨兵七个反例，JSON 解析后逐条 `assert_eq` 精确实断言）**（quickjs 档）+ e2e `favcomic_jslib_loads_with_resolved_input_stream`（台账负断言同改前缀匹配）。**输出对比局限（如实登记）**：缺真实 favcomic 密文与 AES 密钥/口令（探针 `createSymmetricCrypto(s:20,s:51,u8:7)`，值不外露），**无法**给出真实解密产物与参考实现的可复现对比；可复现的是上述 ①②③ 区分点，而非解密产物。
- **P2-10 P2-8 审查剩余项**（**已关闭 2026-09-18**）：P1-1 固化回归测试、P2-2 存量坏 `tocUrl` 自愈（单列回写）、P2-3 server 单一取址点、P2-4 Dart DB 优先、P3-1 trim、P3-3 注释如实化、P3-4 RoomImporter 保留字段均已完成；P3-2（裸 `@attr` 多子元素语义）经只读核查后判定应统一为「遍历全部子元素 + 去重」，作为独立小项并入 P2-11。历史记录：P1-1 已修（写侧 `fill_origin_book_url_if_empty` + Dart 自动换源补字段 + 自愈补列），**其固化回归测试待补**（「换源后以缺 `originBookUrl` 的 Book JSON 调 `updateBook` 不得清空列」）。其余：
  - P2-2 存量坏 `tocUrl` 不自愈：`reader.rs` 的 `refresh_toc` 在目录为空且 `book_page_fetch_url()` 与 `toc_url` 不同时应用书籍页重试一次并回写；
  - P2-3 服务器 `/api/toc/update` 未接入单一取址点（详情改 `book_page_fetch_url()`；目录优先 `toc_url`）；
  - P2-4 `_mergeDbBook` 对该字段的优先级反了（应 DB 优先，路由只兜底）；
  - P3-1 Dart 取址未 trim（与 Rust 不一致）；P3-2 裸 `@attr` 新分支只取首个子元素（与「裸 token」分支遍历全部不一致）；P3-3 `pre_update.rs` 头注释与「仅换源写入」的描述不符（`re_get_book_native` 是第二写者）；P3-4 RoomImporter 丢弃该字段；P3-5 送审材料与实际改动集不一致（流程：diff 应含生成物与全部改动文件）。

- **P2-11 本批审查剩余项**（开放，2026-09-18）：由 P2-9/P2-10 审查报告沉淀，均为「不阻塞合入、需登记或后续小修」：
  - `cache.*` 磁盘层无宿主注入点（默认 `temp_dir`，未验证可写；写盘失败会连带清内存层，JS 侧忽略返回值）→ FFI 初始化注入应用缓存目录 + 失败保留内存层 + 设备级 put→get 冒烟；
  - `book` 绑定为只读快照：`book.type = N`（~7 源切小说/音频/漫画模式）、`setReverseToc`（1 源）、`book.putVariable`（1 源）写入被静默丢弃；`type` 初值硬编码 0（可无损改真实值）→ 视影响面决定落存储或显式声明；
  - 正文阶段 `book` 反查只以章节 URL 为键（两书产生相同章节 URL 时理论上串键）→ `webbook_content` 增可选 bookUrl 或复合键；
  - `explore_api` 未套用 `src` 重绑定/`book` 绑定（链式 JS 的 src 仍为中间产物，同类残差）；
  - `java.lang` parse 面近似（`parseInt('12abc')`→12、`Double.parseDouble('NaN')` 抛错等）、`getStringList` 细分差异（上游按 `
` 拆分/`null` 语义/`get/isEmpty` 别名）；
  - `archive_utils::inflate_raw_bytes` 两个 attempt 的极性注释与实现相反（功能正确）；
  - `mergeDbBook` 的 DB 值纯空白时会压过路由有效值（与 `bookFetchUrl` 的 trim 语义不一致）；
  - `BookMeta`/`chapter_book_cache` 容量判定 `>=` 触发整体 clear（更新已有 key 也清空）；
  - 裸 `@attr` 多子元素语义（P3-2 移交）：应统一为「遍历全部子元素 + 去重」并修正注释；
  - 提交卫生：`rust/legado-ffi/tmp_diag/`、根目录 `nul`、`.tmp/`、`pnpm-lock.yaml` 等未跟踪物需在入库前定策略。
  - **[2026-09-19 关闭]** ①② 已落地（见 CHANGELOG [2.0.292]）；其余各项见 P2-15。
  - **[复审新增] P2-1 调用点回归测试缺口**：`test_refresh_toc_self_heals_bad_toc_url` 只能测「方法层」（变异实验：把 `update_toc_url` 换回「先 find 再全行 update」该测试仍 PASS），**调用点回退（保留方法、改回旧快照全行回写）无测试可发现**。补法（复审给的 recipe ~10 行）：在该测试的 `ScriptedTocFetcher.get_chapters` 首次抓坏 toc 时用 `with_database` 执行 `UPDATE books SET durChapterIndex=7 WHERE bookUrl=?`，刷新后断言 `dur_chapter_index == 7`。
  - **[复审新增] P1-1 首次详情解析无 DB 兜底**：`detail_book_binding` 解析期只查 meta 缓存 → 进程内对该 bookUrl 的**首次**详情解析取不到 DB 用户变量（目录/正文/第二次详情起可达）。若要让「首次打开即生效」成立需在该处补 DB 兜底（注意 `book_binding_expr(Some(meta))` 会忽略 `fallback_name`，需保留 changeSource 保名语义）。
  - **[复审新增 P3] DB 变量被清空后缓存旧值不被覆盖**（`merge_insert` 仅 Some 覆盖）→ 陈旧窗口持续到缓存淘汰。

  - **[2026-09-19 回头关闭 4 项]** ① `explore_api` 补 `src` 重绑定/`book` 绑定（提交 `59ef15cc99`；`book` 无上下文时取 null 与上游一致，2 个 quickjs 回归测试）；② 裸 `@attr` 统一为「遍历全部子元素 + 去重」（提交 `bef51973a9`；对齐上游 `AnalyzeByJSoup.getResultLast` L270-277，parser 304 passed，4 个新单测含「与裸 token 形态一致」断言）；③ `inflate_raw_bytes` 注释极性更正（提交 `b1bf5bfdcd`，flate2 `Decompress::new(true)`=zlib，仅改注释）；④ P2-1 调用点回归测试（提交 `b1da07dce2`；含变异验证——调用点退回全行 `update` 时新断言 FAIL `left:0/right:7`）。同批版本 2.0.296+297。
  - **[2026-09-19 关闭 §201]** 提交卫生：`nul`/`.fd.xml`/`.oh.xml`/`pnpm-lock.yaml`/`core.*`/`.tmp/`/`__pycache__/`/`tmp_diag/` 已删除或补入 `.gitignore`（提交 `548bbc5004` + 本次 `tmp_diag/`）；注意原 `/tmp_*` 为**根目录锚定**，覆盖不到 `rust/**/tmp_diag/`。
  - **[2026-09-20 关闭 §193/§195/§196/§198/§199]**（提交 `d13d1a04e5` / `16f6e09e92` / `0fe222a3c8`，版本 2.0.297+298）：
    - §193 正文阶段 book 反查改 **(source_url, chapter_url) 复合键**（选零契约面方案 (b)，FFI/API_CONTRACT 未动；回归 `test_chapter_book_cache_composite_key_no_cross_binding`）。
    - §195 `java.lang` parse 对齐 JDK 严格语义（成对实验法；空/空白/非法/越界抛 NumberFormatException，Double 收 NaN/Infinity/十六进制浮点，Boolean 仅 "true" 为真）。
    - §196 `getStringList` 逐条对齐 `AnalyzeRule.getStringList`（L202-292）+ **顺带根因修复：顶层 `return` 规则此前被静默吞空**（旧包装按顶层 Script 编译，顶层 return 语法错误；上游靠 Rhino legacy 兼容模式幸免——vendored rhino-1.7.14.jar 标准模式本机实证同错）。修法=函数体求值优先 + 表达式回退。已知边界（登记）：无 return 的表达式规则带副作用会执行两次；JS float64 使 parseLong >2^53 取最近 double。
    - §198 Dart `mergeDbBook` 纯空白 originBookUrl 让位路由值（取 DB 原值不 trim，4 例单测）。
    - §199 缓存改「仅新键溢出才清理」对齐 `getOrPutLimit`（更新既有键不清空，3 条回归）。
    - 遗留登记：⑫ 类 Rhino LiveConnect 互操作维持架构限制（**2026-09-20 实测订正**：最新 916 源合集中 `importClass`/`Java.type` 均 0 命中，Java 面集中在具名类/方法；涉事源实为 11 个 jsLib 命中源（七猫四合一本地版 588KB 等），**书山/番茄已从现网消失**——原"3 源"为审计时点数字且含已删源，详见 docs/RHINO_INTEROP_ANALYSIS_20260920.md §8）；`RealBookSourceFetcher::new()` 内部走 shared_client()，代理环境下回环可被劫持（CI 无影响，根治需注入 no_proxy 客户端）。

- **P2-12 本批实机验收新发现（3 条）**（**已关闭 2026-09-19**）：(C) 重进/U7 路径未展开 `books.variable` → Rust 侧按 bookUrl/书籍页地址双路读 DB 变量并注入详情/目录抓取（FFI 签名零变更）；实机前后：`/r1vb/detail?vid=`（空）→ `?vid=VID123`，正文 `/r1vb/content?i=0&tok=TK777`。(A) CrashLogDialog 启动崩溃循环 → 改挂 `navigatorKey`（+ 新发现的 A2：冷启动 `/welcome` 闪屏 `pushReplacementNamed` 会把首帧弹窗一起替换，改由 `NavigatorObserver.didChangeTop` 等闪屏退出再弹）；实机：清除后重启不再重写日志。(B) 夹具 `log_event` 参数冲突 → 修 + 自测 400 链路。门禁：`cargo test --workspace` 368/795/308/288/242… 全 0 failed、clippy/fmt 0、`flutter analyze` 0、`flutter test` 1483 全过。历史记录：
  - **(C)【优先】U7/重进详情路径未展开 `books.variable`**：实机（R1 夹具）换源 2 后 `books.variable = {"svid":"VID123","tok":"TK777"}` 已落库，但「回书架→重进详情」发出的是 `/r1vb/detail?vid=`（**空 vid**，server log ts1789755251.038）——期望 `/r1vb/detail?vid=VID123`。换源主链（候选 ⊕ 详情导出合并）已修，**重进/U7 路径疑似未读 `books.variable` 或走不同展开入口**；本次被「DB 目录缓存 + 夹具挂起」掩盖，真实源上会 400/详情失败。属历史 P0 的同型残留。
  - **(A) CrashLogDialog 启动崩溃循环（既有）**：`flutter_legado/lib/app.dart:51-56` 在 `postFrameCallback` 里 `CrashLogDialog.show(context, …)`，而 `LegadoApp` 在自身 `build()`（app.dart:143）内才构建 MaterialApp → State 的 context 无 Navigator 祖先 → `Null check operator used on a null value`（`crash_log_dialog.dart:19-25` 的 `showDialog`→`Navigator.of(context)`）。后果：崩溃日志弹窗永不显示，且 `crash_log.txt` 每次启动被重写时间戳（本会话起点即观察到 20:11/20:32 两条同栈记录）。修法：把弹窗挂到 MaterialApp 之后（如 `builder` 内的独立 Navigator/`addPostFrameCallback` 里用 `navigatorKey.currentContext`），或直接去掉该弹窗仅保留日志。
  - **(B) 夹具脚本缺陷**：`scripts/r1v_switch_server.py:200/213/221` 以 `log_event("reject", kind="detail", …)` 调用 `def log_event(kind, **fields)` → `TypeError: multiple values for argument 'kind'` → reject 分支未发 400 而是抛异常挂起（curl HTTP:000）。后果：夹具的「错误/空变量」路径表现为超时而非 400，掩盖真实错误码。修法：去掉重复的关键字实参（或把位置参数改名）。

- **P2-13 本批新登记（工具与既有项）**（**①③已关闭 2026-09-19；② 转入执行队列第五阶段**）：
  - **【工具陷阱·优先】已关闭（提交 `7a84235382`）**：`build-apk.ps1` 已改为按「Rust 源码树指纹」判定 `.so` 新鲜度——前置检查调 `rust/scripts/rust-fingerprint.ps1 -Check` 逐 ABI 比对 jniLibs 内 `.so` 记录的源码树指纹与当前 `rust/**`，返回 REUSE/REBUILD 决定是否重交叉编译；「FFI 导出面未变但源码已改」不再误判为 in sync。历史风险留档：旧校验只比对 FRB 生成码内容哈希，FFI 面未变的 Rust 改动会被跳过编译 → APK 打包旧 `.so`（曾致实机验证假失败/假通过，靠手工强制 `build-android.ps1` 才修正）。**"凡改 Rust 必须手工先跑 build-android.ps1"的临时纪律随之解除。**
  - debug 模式既有 `RenderFlex overflow`（右溢 12px）：非本轮引入，会被全局 `FlutterError.onError` 偶尔记入 crash_log（当前设备文件内容即此）；已列入执行队列第五阶段（UI 剩余）处理。
  - `armeabi-v7a` 的 `.so` 未随 (C) 强制重编（设备为 arm64，FFI 未变故不影响），下次全量构建会自然刷新——**随指纹校验落地，此情况已不可能再发生**（指纹不一致即 REBUILD）。

- **P2-14 门禁口径（流程，2026-09-19）**：`cargo test --workspace` **默认不含 quickjs**，JS 宿主/门控用例不在其中。**自本批起，Rust 门禁按两档报数**：`cargo test --workspace`（无 quickjs）与 `cargo test --workspace --features legado-ffi/quickjs`；提交说明须写明口径，仅报前者会漏掉全部 JS 行为证明。

- **P2-15 P2-11 ①② 审查沉淀**（部分关闭，2026-09-19）：
  - **[P1] ① 的能力边界与后续打通**（**已关闭 2026-09-19**，提交见 CHANGELOG [2.0.293]）：`get_flow_variable` 读链尾部加 bookVar 兜底（会话层→裸键→bookVar，按当前流程 scope 构键、天然按书隔离）+ `book.getVariable` 经 `__lgBookVarGet` 同阶段回读；「就去看网」闭环（测试以存储层为 oracle）；3 处注释已如实化。残留：`pre_update` 阶段 scope 用书籍页地址（换源后与稳定 bookUrl 不一致，优雅 miss）、bookVar 仅进程级、无墓碑、单 scope 槽并发。历史记录：`book.putVariable` 写入仅「下一次 `book` 绑定构造」后对 `book.getVariable` 可见；**同阶段跨规则不可见**、**`java.get`/`@get` 读不到**（三套命名空间不连通）。语料唯一消费者「就去看网」（写 `序/元/除/嗅/兜/查` 后全部经 `java.get` 回读）**未闭环**。最小实现：`get_flow_variable` 在裸键回退后再按当前 flow scope 拼 `bookVar::{scope}::{key}` 兜底，或写桥内同时 `put_flow_variable`；同时修正 `quickjs_impl.rs`/`web_book.rs`/`variable_store.rs` 三处不准确注释。
  - **[P1] ② 已关闭（2026-09-19，提交 `6d2a5c29cc`，版本 2.0.295+296）**：四步接线落地——`ffi.rs` 薄桥 `set_cache_dir` → `generate-bridge.ps1` 重新生成两端绑定（frb 2.11.1，消息 id 206）→ Dart 启动注入应用私有缓存目录（`getApplicationCacheDirectory()/js_cache`，取不到仅记日志不阻断）→ 写失败改为进程级一次性告警。**设备级冒烟通过**：`cache.put` 落 `/data/user/0/io.legado.flutter_legado/cache/js_cache/<sha256(key)>.json`（内容 `{"v":"disk-hit","d":0}`）、`/data/local/tmp/legado-js-cache` 不存在（未回落 temp）、logcat 有 `[RustApi] setCacheDir -> …`、UI dump 证明规则确在设备执行（首测未落盘系字典规则自身顶层 `return` 语法错误，纯 UI 改正后通过）。目录优先级：env `LEGADO_JS_CACHE_DIR` > 宿主注入 > `<temp_dir>/legado-js-cache`。历史登记：`set_cache_dir` 无生产调用者（Dart 接线属禁改区）；Android temp 多半不可写 → 未注入时每次 `cache.put` 打一行错误日志。
  - **[P2] `type` 写入不回流 DB/Dart**（**本批实现 2026-09-19**）：7 源（微信读书二合一/禁漫天堂/画涯爱子/爱妹子/HentaiCosplay/AsianPornImage/键盘小说）的「自动切模式」打通——`WebBookInfo` 增 `book_type: i32`（serde `type`，零值 `skip_serializing_if`）；详情解析 `parse_book_info_from_body` 在 overlay 回读后填值（JS 写值胜、缺失回落 `book_type_of_source` 书源换算，非硬编码 0）；JS 源路径同源换算兜底（marshaller 无 type 字段，不劣于旧常量 0）；Dart `mergeWebInfo` 两路经 `mergeBookType`（非零新值覆盖媒体位 typeMask、保留非媒体标记，零/缺键保留现值）写 `Book.bookType`，入架后既有 `api.updateBook` → `bookshelfUpdate` 落 `books.book_type`（列已存在、零迁移）。覆盖语义与上游 `analyzeBookInfo` 对齐（详情解析为书籍模式权威，JS 写值 > 书源声明值）。本应用当前无手动改模式 UI，无手动冲突面。回归：`test_p215_type_backflow_from_js_write`（IMAGE 源端到端 64 / TEXT 源 JS 写 64 胜书源 8 / TEXT 源无写回落 8）+ Dart `mergeBookType` 单测。
  - **[P2] `type` overlay 黏性（已关闭 2026-09-19，提交 `e5da605fd1`）**：新增 `clear_book_type_overlays(book_url)`，flow scope 切换（离开一本书）时清掉该书的 `bookType`/`bookReverseToc` overlay、**保留 `bookVar`**（书级绑定需跨 scope 存活）。上游 `removeAllBookType+addType` 的每阶段重置语义由此对齐（此前进程级存活 → 切到下本会读到上本的阅读模式/倒序目录）。新增 3 个单测（切 scope 清 type 保 bookVar / 同 scope 保留 / clear_flow_scope 清 type）。
  - **[P2] 陈旧 overlay 压过 DB 用户变量编辑（已关闭 2026-09-19，提交 `e5da605fd1`）**：换源合并新增 `yield_stale_overlay_to_db`——对 overlay 键域内、不在候选集、且 DB 已有值的键用 DB 值覆盖（让位）。**降级说明（如实登记）**：DB 无逐键更新时间戳（`rust/legado-db/**` 属禁改区），"陈旧"取「DB 有值 + key 不在候选」这一可判定近似，非精确时间比较；`merged` 非 JSON 时原样透传。新增 2 个单测（让位矩阵 + variable 路径端到端）。
  - **[P2] type 调用点接线无用例**（**本批已补 2026-09-19**）：新增 `test_p215_type_backflow_from_js_write`（quickjs 档，按最小配方扩为三阶段）——`record_book_meta_from_info` 播种 meta 后调 `parse_book_info_from_body`：A 阶段 IMAGE 源（`bookSourceType=2`）init `book.type=64` → 返回 `book_type==64` 且 `name=="64"`（**调用点回归硬编码 0 则本断言失败**）；B 阶段 TEXT 源（`bookSourceType=0`）同写 64 → 64（overlay 分支 + JS 写路径，胜书源换算 8）；C 阶段 TEXT 源无 JS 写 → 回落 8（书源换算，非 0）。播种 meta 的必要性：meta 缺时 `book` 绑定为无 type 访问器的字面量，探测恒 `undefined`。
  - **[P3]** `bookVar::{url}::{k}` 的 `::` 边界（URL 含 `::` 时可能串键）与键无限增长（每次绑定全表 `list_variable_keys()`）；写桥 add-only（源可写他人命名空间、`b.bookUrl` 被改写后错位丢写）；`merge_book_variable_json` 在 base 为数组/标量且 overlay 非空时丢弃 base；非 string 值 `JSON.stringify` vs 上游 `[object Object]`；大值上游走 `RuleBigDataHelp` 而本实现留在 `variable`（可能撑大 DB 列）；native `java.get` 读裸键 vs prelude 读 flow 优先（两套语义）；`java.clearVariables` 可整表清空（含 bookVar overlay，526 语料 0 使用）；`put_file` 无 TTL。

- **P2-16 升级 rquickjs 取回 quickjs-ng 的 OOM use-after-free 修复**（**已关闭 2026-09-20**，提交 `b662d71741` + `36bc435921`，版本 2.0.297+298 批次）：rquickjs 0.9.0 → **0.12.2**（内置 quickjs-ng 0.15.1）**零 API 断点**迁移；feature 集等效保留，rust-alloc/allocator 显式不启用并注释钉住（换分配器会使 JS_SetMemoryLimit 变 no-op）；**P2-7(c) 原崩溃配方转为常规回归断言** `test_sandbox_memory_limit_oom_backtrace_regression`（断言 Err + OOM 后引擎可用），Windows 与 WSL 双端实证不再 SIGSEGV——CI run 35459493775 曾红于消息断言过严（Linux 命中编译期 OOM 退化「语法错误」形态，进程未崩恰是修复生效的表现），`36bc435921` 放宽为两种合法形态。三 ABI 构建成功（v7a quickjs=false 降级不变）。历史登记（开放版）：现状 `rquickjs 0.9.0` / `rquickjs-sys 0.9.0`（`rust/Cargo.lock`）内置 **quickjs-ng 0.8**，其 `build_backtrace` 在重入 OOM 时释放自己正在补栈的回溯对象 → 进程级 SIGSEGV（完整 gdb 链路见 P2-7(c)）。上游已修：quickjs-ng 提交 `e1c1e416`（2026-05-16，"fix: heap-use-after-free in build_backtrace when dbuf OOM frees current_exception"，Fixes #1469），首个含它的版本 **v0.15.0**；`rquickjs-sys 0.12.1` 已内置 quickjs-ng **0.15.1**（已核实 `QJS_VERSION`）。**生产暴露面**：书源规则 JS 主路径（`rust/legado-ffi/src/js_executor.rs:532/645`、`rust/legado-js/src/engine_cache.rs:52`）均跑在 **64MB** 上限（`check_syntax` 为 16MB），而该崩溃机制**与上限值无关**、只取决于「首次失败后剩余余量是否小于补栈所需」，故**病态/恶意书源脚本理论上可致 app 进程崩溃**（本机 64MB 档未复现，属概率性；Windows 侧曾在 512KB 档实测同型 `0xC0000005`）。**建议处置**：升级至 rquickjs ≥0.12（API/feature 面变动较多，须单独立项：`set_memory_limit`/loader/macro 兼容性 + 两档测试 + Android 三 ABI 重编 + 实机冒烟）；升级前**不得**再把「打满内存上限」写成断言（新用例已按 P2-7(c) 的保守形态落地，勿改回）。暂不采用的替代缓解（留档）：引擎侧按 `malloc_size` 接近上限时主动熔断——需改分配/运行时层且成本高。

- **P2-17 真联网用例补 `#[ignore]`（CI 间歇红真因之二）**（**已关闭 2026-09-19**，提交 `de1803bc15` + `e5da605fd1`）：Rust CI 默认档 `cargo test --workspace` 里 `legado-ffi` 有 **11 个用例**会向真实第三方书站发 HTTP（`explore_api::test_explore_fetch_siluke_xuanhuan_live`；`s0_fixture_tests` 5 例；`toc_no_rederive_tests` 3 例；`web_book::test_siluke_full_rules_next_toc` / `test_siluke_book_info_chapters_timing_and_cache`），站点慢或超时即 panic——run 35441273557 即由后者拉 `http://www.silukezw.com/135/135188/` 超时致红（上一轮同档为 372 通过/0 失败，纯环境抖动）。
  - **判定方法（可复现，供后续同类排查）**：把全部流量导向死端口再跑全量档——`HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=… ALL_PROXY=… cargo test --workspace --no-fail-fast`，失败者即联网用例。**注意必须加 `--no-fail-fast`**：首轮未加时运行在 `legado-ffi` 处即中止，导致误判「其余 crate 全绿」。
  - **处置**：11 例统一补 `#[ignore = "requires network access"]`（沿用仓内既有 19 处同款约定），保留手工可跑：`cargo test -p legado-ffi --lib -- --ignored --exact <名> --nocapture`。改后死代理档 `legado-ffi` 0 failed（363 passed / 30 ignored），正常网全档 0 failed。
  - **方法论副产物（非 CI 风险，已登记勿误处理）**：同法筛出 `legado-net` 3 例（`test_gzip_response_decompressed` / `test_e2e_fallback_system_dns` / `test_connection_pool_reuses_keep_alive`）在死代理下失败——根因是这些用例自带 `127.0.0.1` 本地服务器，被 `HTTP_PROXY` 劫持了**回环**流量，**并非外网依赖**，故不得加 `#[ignore]`（会误删合法离线覆盖）；后续若要健壮化，应在这些用例内设 `NO_PROXY=127.0.0.1,localhost`。
  - **后续（部分完成 2026-09-20，提交 `f101b8f673`）**：11 例中 **9 例已夹具化转离线**（explore 1 例现抓 `silukezw.com/list1/1.html` 存仓内夹具经回环服务器投递；s0 5 例与 toc 3 例经侦察确认本即离线，属陈旧标注直接去 ignore；s0 执行器客户端换专用 no_proxy 客户端）——默认档 ignored 30→21，恢复 9 例覆盖。余 web_book.rs 2 例因该文件在途改动避让保持 ignore，待无冲突窗口。`legado-net` 3 例回环用例另修显式 `no_proxy`（`cda70a0c54`，修"死代理排查法"误报）；`cache_store` 测试改显式注入槽消除 env 互污（`b816977643`）。
- **P2-18 Flutter CI 门禁长期被 skip 的基建修复**（**已关闭 2026-09-19**，提交 `f97efdfcb2`）：`flutter-ci.yml` 的 `android-ffi-sync` 作业长期在 `Set up Android SDK` 一步失败（`android-actions/setup-android@v3` 默认安装列表含已被 SDK 仓库移除的 `tools` 包 → `Warning: Failed to find package 'tools'` → sdkmanager exit 1），下游 `analyze` 作业被 skip → **`flutter analyze` / `flutter test` 这两个门禁自建立起就没在 CI 跑过**（历史多次被记为"基建问题、非我方"）。修法：显式 `packages: 'platform-tools'`（runner 镜像自带 SDK/cmdline-tools，NDK 由下一步 sdkmanager 安装）。**验证**：workflow_dispatch run 35445292930 与推送 run 35445743433 两次均两作业全绿，`Flutter analyze`/`Flutter test` 步骤真实执行并通过。

- **P2-19 搜索 HTTP 层与上游逐项评估的发现（2026-09-22，队列⑩b；**三项已修 2026-09-22**，版本 2.0.307+308）**：修复内容=cookie 域名键 ETLD+1（含**清除/查询侧同步收敛**——审查发现的关键漏改）+ 规则 Cookie 按键合并且规则优先 + 同步修 concurrentRate 待评（未修，见下「仍开放」）。（原「未修」版登记如下，保留追溯）按上游 Kotlin 实读逐项对比「重试 / cookie / charset / 重定向 / concurrentRate」，结论=主体近似、**三项确凿缺陷**（附最小复现）：
  1. **[P1] cookie 域名键塌缩**：`client.rs:738-749`（与 `cookie_store.rs` 的 `extract_domain`）取 host **末两段**为键，无 Public Suffix 判定 → `a.example.com.cn` 与 `b.other.com.cn` 同键 `com.cn`，两站 cookie 互相覆盖并随任一请求发出（复现：两个不同 `.com.cn` 站各 Set-Cookie 一次后访问任一站，Cookie 头会带另一站的 cookie）。修法：引入 public suffix（`publicsuffix` crate 或内置高频多段 TLD 表 + IP 特判，对齐上游 `NetworkUtils.getSubDomain`），约 4–8h。
  2. **[P1] 规则 Cookie 头被 DB 覆盖**：`client.rs:280-282` 自定义头先应用、`apply_cookie_static` 后应用且**整体替换** Cookie 头；上游 `AnalyzeUrl.kt:733-735` 是**按键合并且规则优先**。且我方 DB cookie **无 per-source `enabledCookieJar` 门控**（上游仅启用 cookie 的书源才读写 DB）。修法：注入前按键合并（自定义优先）+ 按书源 cookie 开关门控，约 4–8h。
  3. **[P2] concurrentRate 编辑不生效**：`source_rate_limit.rs:14-32` 仅 `or_insert_with`、无刷新入口（上游 `BaseSource.kt:388` 编辑即 `updateConcurrentRate`）。约 2–4h（顺带把键统一为 source key）。
  - **backlog（P2/P3，未修）**：`urlOption retry` 字段已解析但**零消费者**（书源配置静默失效；修法=按上游"仅非 2xx/非 3xx 重发、无退避"模式接入，注意现 `RetryExecutor` 语义不同，约 4–8h）；charset 自动探测兜底缺失（无 header/meta 的非 UTF-8 页走 lossy，可引 `chardetng`，约 4–8h）；重定向跳数 10 vs 上游 20（1h）、`followRedirects=false` 未消费（4–8h）、JS 辅助请求上游**刻意不跟随**而我方跟随（2–4h）；JS `setCookie` 独立内存存储不落 DB、与客户端 CookieStore 不互通（8–16h，可缓）。
  - **保持现状（评估明确不建议改）**：concurrentRate 固定窗口算法（与上游逐行等价，含单测）、S0-E 非 2xx 语义、**显式 charset 解码响应（我方优于上游，勿改回）**、reqwest 默认头/UA 处理。
  - 未核实点：OkHttp "默认 20 跳"取自库文档未逐行核库源；`legado-db` cookie 表 schema 未复核；chardetng vs ICU4J 质量未做基准；语料中 urlOption `retry`/`followRedirects` 使用频率未统计。
  - **新登记（2026-09-22，P2-19 审查发现，面比 P1-1 更大）**：**JS 侧跨源 cookie 泄漏** —— `rust/legado-js/src/host_api/network.rs:279-289` 的 `merge_global_cookie` 把 `all_cookies()`（**全部 tag** 的 cookie）拼进 JS ajax 请求头，即书源 A 的脚本发请求会带上书源 B 的 cookie。本次 ETLD+1 隔离只作用于 HTTP 层（`legado-net`），**JS 宿主层未收敛**。修法建议：JS ajax 的 cookie 头按当前脚本所属书源 tag 过滤（或复用同一真源键）；需先确认 `tag` 在 JS 宿主层的取值来源（审查未追到），工作量待评估。
  - **P2-19 已知 limitation（审查归纳，随修提交写入台账/CHANGELOG）**：① 多段 TLD 表为人工子集 → **表外**后缀键粗一档（例 `gov.ae`/`org.za`/IDN 二级 `公司.cn`）；② **私有后缀**（`github.io`/`blogspot.com`/`pages.dev`/`vercel.app`/`netlify.app`/`workers.dev`）仍塌缩；③ **三段及以上**公共后缀（`pvt.k12.ma.us` 类）无法表达（表只查末两段）；④ 表内 `com.hu`/`com.it`/`com.es`/`com.se` 疑非真实 PSL 条目 → **方向安全**（只多隔离、不跨站泄漏）但键与上游不同；⑤ 尾点 host（`a.example.com.`）需归一化（随修 1 行）；⑥ 非 URL 输入的键不对称（既有）。**升级影响**：旧键孤儿化仅两类——多段 TLD host（旧 `com.cn`）与 **IP 字面量 host**（旧 `1.10`，影响自建/局域网书源，比前者更常见）；不做自动迁移（信息已丢失、不可逆推），建议 CHANGELOG 写明"这两类源的持久 cookie 首次请求不再携带，可能需要重新登录一次"。

  - **新登记（2026-09-22，P2-19 修复过程中发现）**：**上游 `enabledCookieJar` 的按书源 cookie 门控未接入网络层**。事实：我方模型与 DB **已具备等价字段**（`rust/legado-core/src/models/book_source.rs:127` 的 `enabled_cookie_jar: Option<bool>`（serde `enabledCookieJar`）、`rust/legado-db/src/schema.rs` 的 `enabledCookieJar` 列），缺的是**让网络请求路径携带书源上下文**——`rust/legado-ffi/src/api/net_api.rs` 的 `http_get_bytes(url, headers_json)` 等接口无书源参数，打通需 **FFI 签名/契约变更 + parser 变更**，触碰"契约先行 + 双方确认"红线 → **本次未实现，单独立项待裁决**。影响：所有书源的 DB cookie 目前无条件注入（上游仅启用该开关的书源才读写 DB cookie）。
  - **已实施（2026-09-23，原「可选排期：排最后」项收官）**：**P1-1 项2 跨源聚合下沉 + 跨端夹具校验**——`legado-core::search_aggregate` 单一真源（四桶分桶 / origins 保序去重累加 / hasReadRecord OR / 空 key 原样返回）+ `CoreSearchBook.origins` 加法式字段（空时序列化省略，批次 JSON 零变化）+ FFI 内 pub 入口（未暴露 FRB，方法数 17 不变）+ 跨端夹具 5 case（Rust/Dart 双读比对，origins 按序为契约）；聚合路径归一化改 ECMAScript 等价实现（Dart 探针实测三字符集）。提交 `c4712f4a7a`（版本 2.0.308+309），审查发现转登记 P2-20。

- **P2-20 Dart 搜索聚合双路径不一致：纯函数 `applyPrecisionSearch` 四独立桶 vs `SearchNotifier` 增量桶 `_seenKeys` 预去重**（2026-09-22 登记，队列⑩a「搜索跨源聚合下沉到 Rust」审查发现；**开放，待裁决，本台账不擅自决定以哪条为准**）：
  - **事实**：`search_state.dart` L144-207 纯函数 `applyPrecisionSearch` 用**四个独立 map**（equal→tags→contains→other）按清洗后 `name\u0000author` 键聚合，同一 `name+author` 键若因 `kind` 差异分落不同桶会各留 1 条；运行时增量路径 `SearchNotifier`（`search_notifier.dart` L307-310，`_seenKeys` 声明 L64）入桶前按 `'${name}|${author}|${origin}'` 预去重，同键同 origin 仅留首条。具体差异输入：同 name+author+origin 且 kind 分落不同桶（如「都市情缘+乙」：kind=`重生,都市` 落 tags 桶 + kind 缺失落 other 桶，同源 `https://s4.example`），纯函数/Rust `search_aggregate` 产出 **2 条**、增量路径仅 **1 条**。队列⑩a 的 Rust 实现与夹具均对齐**纯函数**语义（2 条），不覆盖增量路径。
  - **登记原因**：队列⑩a 审查要求对齐范围如实限定为纯函数；另 `search_state.dart` L141-143 注释「语义与增量路径完全一致」与上述事实不符——该注释位于本次任务允许改动范围之外，**未改，如实记录待裁决后统一处理**。
  - **影响面**：仅影响「同名同作者同 origin 且 kind 分落不同桶」的搜索结果条数（2 vs 1）；本轮 Dart 运行时仍走增量路径、UI 行为零变化，差异只会在后续批次把运行时聚合切到 Rust 入口（或按裁决改纯函数/增量路径之一）时显现。
  - **待裁决点**：① 语义取舍——以纯函数四独立桶（不同 kind 各自成条、信息更全）为准，还是以增量路径 `_seenKeys` 预去重（同 origin 仅首条、列表更紧凑）为准？② 裁决后需同步的落点：`search_state.dart` 纯函数 / `rust/legado-core/src/search_aggregate.rs` / 夹具 `cross_source_merge.json` expected / `search_state.dart` L141-143 注释 / 本台账 / `API_CONTRACT.md` 两处限定措辞。③ 若裁选增量语义：Rust `Bucket` 需引入跨桶 `_seenKeys` 等价预去重（键含 origin），与现「桶内独立合并」互斥，需改实现 + 夹具 + 单测。

- **P2-21 08 屏「在读 / 最新 / 共N章」三行块修正**（2026-09-23 设备复核轮发现 → 当日修正 + 实机验证，**已闭环**；提交 `04b367948e`）：
  - 根因：在读行把 0 基的 `durChapterIndex` 当 1 基解读（`chapters[durIdx-1]` + 显示「第$durIdx章」），用户在第二章时显示前一章；三行文本形态与双基准均不一致（自创「第N章」前缀、代码追加「（全书完）」、第三行缺已读章数计数与「已读完」态）。全应用口径取证：`home_tab_screen.dart:395` 用 `+1` 算百分比、`reader_notifier.dart:173` 直接索引 `chapters[]`。
  - 修正：在读行 `在读 · {标题}`（`durChapterTitle` → 目录 `chapters[durChapterIndex]` 0 基 → 不渲染）；最新行去前缀/去后缀（保留 E5 状态词回落）；第三行 `共 N 章` + `|` + `未读 / 已读 N 章 / 已读完`（主题角色色）。参考口径=实机 dump `ref_dark_20260920/08_book_info.xml` + `BookInfoScreen.kt` + 原版 `BookInfoActivity.kt:967-1000`。
  - 验证：`flutter analyze` 0 问题、`flutter test` +1613 全过（新增 10 例 off-by-one 回归/格式/三态）；实机双场景（存储值优先 / 目录回落）经种子本地书证明 off-by-one 修复（证据 `docs/parity_shots/verify_ui_20260922/b8_*`）；台账新增 P2-21 节。
- **P2-22 08 屏元信息区元素集对齐参考版**（2026-09-23，**已闭环**；提交 `95a6d65696`）：
  - 事实：我方有参考版**不存在**的三处独立行——「目录：… · 已读: X%」「分组：…」「🏷️ 标签行」；chips 行还重复了章数（参考章数只在「共 N 章」行）。
  - 证据：浅色截图 `ref_20260914/08_book_info.png` + 深色 dump `ref_dark_20260920/08_book_info.xml`（非空文本全集逐条核对）+ 参考源码 `BookInfoScreen.kt` chips LazyRow（分组 chip 条件显示裸名 + kind chips）与 `HighlightTagRow.kt`（用户高亮规则驱动，非标签行）。
  - 修正：三类行移除/收编（分组→chips 行条件 chip；kind→chips 逐项；逐 tag 点击搜索/长按 JS 回调迁至 chip 手势）；chips 行重构为参考 TextCard 形态（圆角 8/横8纵4/14sp w500）；面板内仅余简介。
  - 登记：原「已读: X%」百分比随目录行移除、无同等替入口（进度以「已读 N 章」+ 书架进度条 + 阅读器呈现，参考版即此形态）；**用户裁决 2026-09-23：接受移除、不补回**；台账追加「08 元信息区对齐修订」节并纠正 U5/U9/U10/U11/U12 旧表述。
  - 验证：`flutter analyze` 0 问题、`flutter test` +1617 全过（新增 `book_info_meta_rows_test.dart` 5 例：三类行不再渲染 / 分组 chip 条件 / chips 无章数 / chip 手势入口 / 目录入口唯一）。

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

- **P3-6 搜索速度与结果一致性修复**（**剩余面基本收口 2026-09-20**，提交 `deb0e87005`/`473968bcaf`，版本 2.0.298+299）：经只读调研逐项对提交核实，P0-1/2/3 与 P1-1 大部分早已落地；本批完成最后实质项——**F1 loginCheckJs 语义对齐**（三叉点：StrResponse 强转语义/JsFailed 不再降级放行/JS 修改后响应被采用；s5 谓词夹具 expected 改整源失败对齐原版实测）+ **每源错误八分类**（API_CONTRACT §2.4 加法式 error_class，error? 冻结不变）+ **S0-D 计时扩展**（session 关联）+ **三入口一致性测试**（tests/three_entry_parity.rs 双档全绿）。**实机探针补验（2026-09-20，5554 替代档）**：loginCheckJs 三要点（裸布尔→cast 失败→整源失败 / code≠500 二次结果放行采用 / JS 改写响应被采用）经 127.0.0.1 fixture + 自撰断言 JS 的确定性探针全部验证一致（DB searchBooks 行 + UI「结果 2·进度 4/4」+ fixture 请求日志三重取证，证据 `docs/parity_shots/queue_smoke_20260920/logincheck_*`）；真源（消消乐听书）失败路径客观无法确定性制造，语义等价覆盖并如实声明。批次冒烟（5554，7/7 PASSED）+ 本探针构成 F1 的实机验证闭环。仍开放（登记）：explore 链同模式对齐（WebBook.kt L149/227/327/454）、`legado-server/src/login_check.rs` 旧语义副本、`AnnotatedCandidate` 补 originOrder、跨源聚合下沉+跨端夹具校验（可选）、重试/cookie/charset 逐项对齐评估（半天）。原状态：源码审查确认 Flutter 主搜索走 `run_multi_stream -> search_single_source`，未复用较完整的规则搜索实现，导致登录检查、详情页回退、书源上下文 JS、单源去重等原版语义存在分叉；同时存在取消残留任务、入口语义不统一和 `originOrder=0` 风险。先完成离线原版响应夹具、QuickJS 产物 feature 核验和双包同库基线，再按“统一单源执行器 → 会话级取消 → 过滤/聚合/持久化一致性 → 性能剖析”实施。详细验收矩阵、依赖顺序与非目标见 `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md`。本项未实施，不得以已有审计文档或当前未提交代码宣称已关闭。

- **P3-7 readRecordDaily 单位放大 1000 倍**（已关闭 2026-09-11）：核实差异清单 C5（阅读记录按天视图）实测时发现——2026-08-29 上线的写路径（`upsert_read_record`，契约 `cb078cdd7e`）把毫秒增量写进契约声明为秒的 `durationSeconds` 列，当日聚合值放大 1000 倍，用户可见面为：热力图「每日时长」配色全天饱和、首页今日目标表盘恒满、按天视图显示「75天17小时」级时长（实机读数 2026-09-06 = 6,541,627）。处置：写路径改按整秒差值入账（`read_time/1000 − old/1000`，避免频繁小增量被反复截断丢秒）；新增 DB v107 迁移 `Migration106To107` 归一存量行（user_version 门禁保证仅一次，SCHEMA_VERSION 106→107）；契约 §2.12 与更新记录同步。**根因备注**：修复只能走 DB 迁移而非 UI 层除法兜底——旧写路径无时间戳可判新旧，且热力图/表盘为既有消费方，Dart 侧除 1000 会与修好后的新数据冲突。
  - **关闭记录（2026-09-11）**：实机证据双段——①归一：v107 迁移后 user_version=107、2026-09-06 行 6,541,627→6,541（1小时49分钟，按天视图读数一致）；②写路径：阅读约 51 秒后当日行 +51 秒，与书 readTime 增量 51,772ms 的整秒差值精确吻合。Rust 测试：legado-db 301 项（含 `daily_seconds_v107` 2 项：归一/幂等 + 懒建表跳过）、legado-ffi read_record 8 项全绿；fmt/clippy 零告警。

**整合审计 Rust 后端批次处置（2026-09-03，据 `REFACTOR_CONSOLIDATED_AUDIT_20260903.md` §八）**：UI/Android 侧（N1 manifest、N3 Web 服务决策簇、N6 生成代码）由 UI 轨负责；Rust 后端项全部处置并提交：
- ✅ **误报更正三处**：D4（JS 源 precision filter）与 D3（一次性入口落库）核实已由 `133914f0f1`（08-29）修复；§二.4（字体反爬 cmap）核实真实现自 `20bee32d1c`（08-07）即完整落地 `legado-js/host_api/query_ttf.rs`+`font_api.rs`（cmap 0/4/6 + glyf 轮廓签名 + java.replaceFont，对齐原版 QueryTTF.java 0/4/6——原版 Java 无 format 12）并接入 quickjs。整合报告第三轮核对把 legado-core 同名死桩误判为活实现。
- ✅ **core 死桩删除**（`9f58655`）：`legado-core/src/query_ttf.rs` 零消费方且连续误导两轮审计，删除；N2 `do_custom_js` 假成功改显式拒绝（`92c171182c`），server REST run_task 测试同步诚实化（该 REST 层属 §二.7 已决策删除簇）。
- ✅ **D4 回归单测**（`25c9e2a03a`）：quickjs `d4_js_precision_tests`——mainJs 静态夹具两书，precision=true 仅命中条目通过，防对齐回退。
- ✅ **§三.9 内存限制测试**（同上）：`#[cfg_attr(windows, ignore)]`——Windows 仍跳过（进程级崩溃），Linux CI 恢复沙箱安全线回归防护。
- ✅ **N7 cargo audit**（rust-ci.yml）：RustSec Advisory 扫描阻塞门禁 + 清理重复 test 步骤。
  - ✅ **N7 门禁首跑修复（2026-09-03）**：门禁首次运行暴露 6 漏洞（本地此前从未装过 cargo-audit，门禁上线后未在本机执行过）→ h2 lock 升至 0.4.19、quick-xml 0.37→0.42（epub/rss/webdav 三处 API 迁移）、lopdf 直接依赖 →0.42；余 2 项无升级路径按风险接受登记于 `rust/.cargo/audit.toml`（v0.22 起取代 .cargo-auditignore）：lopdf 0.26 被 genpdf 0.2.0/printpdf 锁死（上游无新版）、rsa RUSTSEC-2023-0071 官方无修复版，评估结论与 P2 跟进见该文件注释。
- ✅ **连带修复**（`b60efc101c`）：legado-net custom_hosts e2e 在有系统代理环境下 502（代理架空 hosts 直连语义）→ `LegadoClientConfig` 新增 `no_proxy` 开关 + e2e 测试启用；TEST_LOCK 中毒级联拖垮同模块 5 测试 → 9 处改 `into_inner()` 中毒恢复（§三.12 惯例）；web_book 两个失效站点诊断测试补 `#[ignore]`（同文件惯例）。
- ✅ **N5 评估登记**：source_checker.rs:511 / reader.rs:307 两处简化点均为设计内（有注释自述、无生产正确性影响），维持登记不修改，详见整合报告 §五.N5。
- 门禁：fmt 0 diff、clippy 双段 0 warning、`cargo test --workspace` 全绿（2237 passed / 51 ignored）、`legado-js quickjs` 513/0、`legado-ffi quickjs` 396/0（siluke 时序敏感测试在负载下偶发抖动，单跑/复跑通过，属环境基线非本轮回归）。

**进度更新（2026-08-29）**：按 `SEARCH_PARITY_REMEDIATION_PLAN_20260828.md` §8 执行。
- ✅ **已完成**：离线原版响应夹具（S0-B，`511a0bb52`，七场景+主执行器消费测试）；统一单源执行器收敛（S0-E，`4330acaf9`，loginCheckJs/pattern 直连/空列表回退/bookUrl 回退/去重键/非 2xx 六项对齐）；会话级取消收尾（P0-3，`c5f82a854`+`91e40dfad`，双机实机 e2e 7/7，verdict 归档）；G4 修复（`bb521c366`）。
- ✅→**S0-C 双包基线：已闭合（2026-09-03）**——5558→5556：实测双包均装于 emulator-5556，改单机双包串行拓扑绕开 5558 网络阻断；原版端"分组列表不含 S0C"实为列表未滚动（ASCII 序排在中文分组后），圈定后 7 夹具源 26s 终态；"reverse 僵死"部分为误诊（夹具服务器随驱动脚本崩溃被连带杀死，connection reset 症状相同，服务器独立进程后未复现）。夹具修正三处（原版不认纯 CSS 选择器改 class. 语法、2s→4s 延迟间隔防抖动、s1 302 final 不计时）。终态对比：**集合级 parity 双端 5/5 一致**（s5 loginCheckJs 失败/s6 空结果正确排除、s1 重定向、s2/s3 pattern 两分支、s4 空列表详情回退全命中），第 1 页逐源请求与结果完全一致；顺序分化（原版 甲乙丙戊丁 vs 重构 甲乙丙丁戊）根因=并发策略差异（原版约 5-6 并发 vs 重构 32，均按完成序聚合），非解析缺陷。详见 `SEARCH_PARITY_S0C_CLOSURE_20260903.md`。**P0-2 S0 与 P0-1.4 解除 DEFERRED**；新增待办 F1：loginCheckJs 语义对齐（原版 WebBook.kt:78 要求 evalJS 返回 StrResponse 本身，重构 js_executor 按布尔谓词判定，谓词式写法两端行为相反，P1）。
- ✅ **阶段三已完成（2026-08-29）**：过滤/持久化一致性——precision filter 解析期对齐原版（`837516a08`，precision_filter_match 三字段或语义 + parse_search_response_ex，应用点=列表循环/pattern 直连/空列表回退，FFI 签名零变更经配置读取，p3f_tests 5 项；workspace 2479/0）。聚合一致性此前已由 fix34 批次对齐。
- ✅ **上游安卓源码同步完成（2026-08-29）**：upstream(LegadoTeam/legado) 506 提交(#397→#1072,v3.26.082823,cronet 152.0.7977.54) 已合入集成分支 `integration/upstream-3.26.082823`（合并提交 `6314f5b215`,161 冲突全部取上游版——本地安卓侧=#543 纯快照无本地修改需保留,README 取双轨版）。门禁：`assembleRelease -Pksp.incremental=false` BUILD SUCCESSFUL（R8 处理新 htmlunit MethodHandle;debug 变体 D8 在 minSdk 23 下无法 dex 新 htmlunit,上游 CI 亦仅构建 release）;`testAppReleaseUnitTest` 1809 中 1807 通过（2 个符号链接测试为 Windows 环境差异,上游 CI 为 Linux）;flutter_legado/rust 零触及。**合回 master 待 UI 轨提交其 49 个未提交文件后执行**（当前 checkout/merge 均会覆盖其 WIP,按协作规则避让）。
- ✅ **体检缺陷修复跟进（2026-08-29 续）**：REFACTOR_DEFECT_AUDIT 18 项中已闭环 9 项（§一.2 前台服务 `405e82a413`、§二.5 Custom JS `bde0dddfa2`、§二.6 PROPFIND `de4a69d3ea`、§三.10 CI 补强 `8ac2410a0c`、§三.12 热点锁、§三.14 缓存容量、§四.15 .gitignore、§五 口径 2 项）+ 上游 506 提交同步（集成分支待 UI 轨 WIP 提交后合回 master）。**仍开放**：§一.1 v7a（决策已登记：发布矩阵剔除 v7a JS）、§二.4 cmap（下一批次）、§二.7/§二.8（REST 通道产品决策）、§三.9、§四.16、S0-C 原版端（环境）、S0-D。
✅ **体检缺陷修复跟进（2026-08-29 续2）**：§一.1 v7a 决策=保留降级 v7a（原版支持 ARM32,剔除会断装;后续可评估 boa 补齐）;§二.7 REST 删除=对齐原版(原版无 REST 层,数据直查 DB;REST 属新增功能违反重构红线,整批删除约 150 行);§三.10 CI 补强已提交。
- ✅ **体检修复跟进决策（2026-08-29 用户确认）**：v7a=保留降级(原版支持 ARM32,不剔除);§二.7 REST 死路径=整批删除(原版无 REST 层,红线对齐);§一.1 v7a=保留降级(原版支持 ARM32);S0-C 原版端=LDPlayer 桥接模式浏览器可达但搜索不调度夹具源(千真实源阻塞遍历),需 debug 原版 run-as 或禁用真实源。
- ▶️ **剩余（2026-09-03 更新）**：S0-D 性能剖析——环境依赖已随 S0-C 闭合解除（双包同机可跑同基线），可独立排期（分段计时探针 LEGADO_SEARCH_PHASE_TIMING 已存在）；F1 loginCheckJs 语义对齐（P1，rust/legado-ffi/src/js_executor.rs，对齐原版"evalJS 返回值须可强转 StrResponse + 错误路径 code!=500 放行"语义，见 `SEARCH_PARITY_S0C_CLOSURE_20260903.md` §3.1）。


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
| `UI_MD3_LAYOUT_PLAN.md` | 分批全量二三级重排+动效全补规划（UI 轨，2026-09-04 立项，四批已交付收口） |
| `PARSER_GAP_FIX_PROGRESS_20260815.md` | 解析 parity 交接与证据 |
| `过期文档/README.md` | 历史文档目录和替代关系 |

新增计划、报告、交接文档必须放在 `docs/`；历史材料只允许放在 `docs/过期文档/`，不得再创建新的日期版计划散落在根目录。

编写者：Codex ｜ 2026-08-19
修订：Qoder UI ｜ 2026-09-05（一比一复刻立项：IA 结构层全量 S0–S7（主框架收顶栏/阅读菜单收敛/详情补齐/主题引擎参数化/Sheet 统一壳/三端适配），Material 单引擎，用户授权纳入 AI 摘要改写/角色卡/相关书（红线豁免记录见 UI_ONE_TO_ONE_CLONE_PLAN_20260905.md §〇，后端数据链契约先行 Rust 轨另排）；R3⑥ 剩余 8 项归档至 UI_SYNC_REFACTOR_PLAN_20260905.md §七）
修订：Qoder UI ｜ 2026-09-05（全量同步重构当日交付：布局优先六批 B0+B2/B3/B4/B5/B1/B6+B7——顶栏 5 档按钮+merge 胶囊+Dynamic 搜索行、底栏三态+悬浮 64dp 胶囊+Rail 简版、详情取色换肤 400ms+折叠顶栏+背景三档+ExtendedFAB、阅读菜单 scale0.88+搜索 pill+r32、miuix 字阶拉齐+书架行 vertical12、详情与圆角开关组+对话框按钮规范；版本 2.0.168–2.0.173，门禁 analyze 0+test 1336 全过；剩余 blur 家族/dynamic_color/FastScroll 全站/朗读胶囊 morph 等登记于 UI_SYNC_REFACTOR_PLAN_20260905.md §七）
修订：Qoder UI ｜ 2026-09-05（布局规划 P1–P4 四批全量交付并完成收尾：主链二三级/书源规则链/设置系通用约 40 页重排 + 动效全补（转场分档/Hero 全链路/Skeleton/Contained 接线/裸下拉清零 10 页/空态收敛/阅读器 chrome/Sheet 28dp）；残页 3 处闭合（explore_show 经共享列表组件、reader_comic 顶栏动作行、other_settings 三 Dialog 主题级合规验证）；搜索 pill/胶囊独立 fade/predictiveBack 按登记口径保留；版本 2.0.161–2.0.165，门禁 analyze 0 + test 1321 全过；详见 UI_MD3_LAYOUT_PLAN.md「实施状态」与 UI_MD3_LAYOUT_PLAN_PROGRESS_20260905.md）
修订：Qoder + Bridge ｜ 2026-09-04（换源任务书 T6 流式化收口（任务书唯一 ⏸ 项销记）：Rust run_change_source_stream + StreamSink searchSourceStream（契约 §2.4）+ Dart 逐源渐显与 x/y 进度（U1 过渡反馈的永久替代）+ 首轮搜索/高级选项加载竞态修复；5556 实测 1024 源首候选 ≤2s、flutter test 1313 全过；版本 2.0.154+155；详见 TASK_HANDOFF_CHANGE_SOURCE_FIX_20260903.md §〇）
修订：Qoder + Bridge ｜ 2026-09-03（换源修复任务书 Rust 轨批次 1/2 收口——T1+T2 换源执行链对齐原版 getToc（真实 tocUrl + 失败保留旧源 + 章节保留 variable/isVolume，3a78afc049）；T3/T4/T5 变量链整体交付（WebBookInfo/SearchResult/SearchCandidate/SourceMatch additive variable + 元素级导出落库 + get_content/reader/audio 内容链 book⊕chapter 变量合并（章节优先）+ switchSource 候选⊕详情变量合并详情页优先）；契约先行 API_CONTRACT 2026-09-03 条；T6 流式化属 UI 侧移交 UI 轨；详见 TASK_HANDOFF_CHANGE_SOURCE_FIX_20260903.md §〇）
修订：Qoder + Bridge ｜ 2026-09-03（整合审计 Rust 后端批次处置：D3/D4/§二.4 三处误报核实更正（均在基线前已修）+ core query_ttf 死桩删除 + N2 假成功拒绝化 + D4 quickjs 回归单测 + §三.9 内存测试 Linux 启用 + N7 cargo audit + N5 评估登记 + 连带修复 hosts 代理架空/TEST_LOCK 中毒级联/失效站点诊断补 ignore；据 REFACTOR_CONSOLIDATED_AUDIT_20260903.md，UI 侧 N1/N3/N6 由 UI 轨在途）
修订：Qoder ｜ 2026-09-03（S0-C 双包基线闭合：5556 单机双包拓扑、夹具 class. 语法/loginCheckJs 返回式/4s 延迟修正、集合级 parity 双端 5/5 一致、逐源证据归档；P0-2 S0 与 P0-1.4 解除 DEFERRED；新增 F1 loginCheckJs 语义对齐 P1 待办；据 SEARCH_PARITY_S0C_CLOSURE_20260903.md）
修订：主代理 ｜ 2026-08-20（P0-1 关闭；P0-2 merge-tree 预检与进度记录）
修订：主代理 ｜ 2026-08-22（P0-2 合流关闭：合并提交 81ad6e220、codegen 同步、门禁与冒烟基线更新）
修订：主代理 ｜ 2026-08-22（P3-1 关闭：入口接入 `961a2d353`，独立复验通过）
修订：主代理 ｜ 2026-08-23（P3-2/P3-3 关闭：`b75426da3` / `a73e4a82b`，独立复验通过；STUB 台账 MockBookSourceFetcher 登记项同步关闭）
修订：主代理 ｜ 2026-08-25（P3-4/P3-5 开启：用户验收反馈——搜索/详情性能回归根因定位 + 换源 UI 对齐清单；两批并行实施，A→B 顺序交付）
修订：主代理 ｜ 2026-08-25（P3-4 关闭：批次 A `6e04cda43`（版本 2.0.105+109）；P3-5 关闭：批次 B 提交（版本 2.0.106+110），独立复验通过）
修订：主代理 ｜ 2026-08-25（P3-4 第二阶段关闭：双根因批次 C `83ff6a8a8`（版本 2.0.107+111）——debug .so + CoverDecodeLoader 整表注册表；冒烟脚本补 UTF-8 BOM（PS5.1 GBK 解码根因）；两级模拟器验证 5556/5558 全 PASSED）
修订：Codex ｜ 2026-08-28（P3-6 开放：搜索主路径与原版深度源码审查，专项修复计划和验收矩阵登记）
修订：主代理 ｜ 2026-09-11（P3-7 关闭：readRecordDaily 单位 1000 倍放大根治——写路径按秒入账 + DB v107 存量归一迁移；实机双段证据与 Rust 测试见条目）
修订：Qoder UI ｜ 2026-08-28（治理步骤：UI 开发规范由 apple-ui-designer 技能切换为 Material Design 3 官方指南，AGENTS/design_system/本档三处同步，据 UI_MD3_PLAN.md 第十四节独立 commit；P3-6 搜索 parity 修复仍由后端轨并行推进，互不干扰）
修订：Qoder + Bridge ｜ 2026-08-31（iOS 轨 P2-C 完成：NowPlayingBridge.swift 锁屏控制/远程命令对齐 MediaSessionBridge 协议，中断映射焦点事件，三轮 Swift 编译修正后 iOS Build 全绿；会话各批次汇报汇总落盘 docs/SESSION_REPORTS_20260829-31.md；P2 剩自动任务降级与真机走查，P3 三端收敛待启动；版本 2.0.131+132）
修订：Qoder + Bridge ｜ 2026-08-30（iOS 轨 P2-B 完成：登录 Cookie iOS 捕获（document.cookie，httpOnly 局限注明）+ 后台听书基础（UIBackgroundModes audio + AVAudioSession playback/spokenAudio）；saf 与 backstageEval 两项销记（既有实现已覆盖）；三工作流全绿；P2-C 待启动：audio_service 锁屏控制/自动任务降级/真机走查；版本 2.0.130+132）
修订：Qoder + Bridge ｜ 2026-08-30（iOS 轨 P2-A 完成：TTS/通知/亮度/设备号/深链五通道插件化（Android 桥零回归），三工作流全绿，模拟器实测 IDFV 注入；P2-B 待启动：flutter_inappwebview 反爬求值/Cookie、audio_service 后台听书、saf 条件化；版本 2.0.129+132）
修订：Qoder + Bridge ｜ 2026-08-30（iOS 轨 P1 里程碑达成：ios-build 工作流全绿，未签名 ipa artifact 产出，iOS 模拟器启动到书架（截图证据），Rust FFI 静态链接实测工作；连带修复 rust-toolchain 跨 target E0463（ios-build/flutter-ci）、rquickjs iOS bindgen、app/ 编译期依赖三处、unrar iOS 排除、Flutter 版本统一 3.44.8；P2 原生补齐待启动）
修订：Qoder + Bridge ｜ 2026-08-30（iOS 轨立项——用户授权「Flutter+Rust 三端通用」，可行性勘察落盘 docs/IOS_TRACK_FEASIBILITY_20260830.md：ios 脚手架无 Podfile/FFI 静态链接待接线/10 原生桥插件对照（flutter_tts·audio_service·flutter_inappwebview 等）/macOS runner 未签名 ipa 方案；分 P0-P3 四阶段待用户确认启动）
修订：Qoder + Bridge ｜ 2026-08-30（GitHub CI 收敛：修复 fork 三处持续 workflow 错误（Sync Upstream 每日失败/flutter-ci 工具链 E0463/test.yml 无效文件 0 秒失败）；按用户指令「安卓源码不上传 GitHub」解除 app/modules 跟踪并从远端树移除、删除全部安卓工作流，本地 .gitignore 登记不上传名单）
修订：Qoder + Bridge ｜ 2026-08-29（搜索/换源 parity 审计 D1-D6 修复：分组分隔符全集/换源候选不再剔除空 bookUrl/multi_source_search 落库/JS 源 precision filter/筛选框书名口径/同名判定字面全等，据 SEARCH_CHANGE_SOURCE_PARITY_AUDIT_20260829.md，版本 2.0.127+132）
修订：Qoder + Bridge ｜ 2026-08-29（热力图每日时长契约交付：readRecordDaily 聚合表 + readRecordDailyList FFI（API_CONTRACT §2.12）+ putReadRecord 写路径增量聚合 + Dart 三层绑定；U 侧 UI_MD3_PLAN 登记项销记）
修订：Qoder UI ｜ 2026-08-28（MD3 UI 迁移 B0–B6 七批次完成：主题地基/12 套内置调色板/主框架/六功能域 token 收尾/验收矩阵自动化，版本 2.0.110–2.0.117，详见 UI_MD3_PLAN.md「实施状态」；遗留 LargeTitle 与 Material You 动态取色已登记，模拟器冒烟并入用户验收）

修订：Qoder ｜ 2026-09-17（**截图一比一全程序收官进度回填**：依用户口径「视觉基准=参考版实机截图（含配色字体）」完成全屏差异清单批 1~4 共 43 屏的「列差异→分批修复→核图验收」全流程，交付 2.0.255~2.0.275；阶段D 配色对齐 kazusa 源码调色板（Δ≤1）；规范/台账/工具见 docs/SCREEN_1TO1_PARITY_{SPEC,LEDGER}_20260914.md 与 scripts/parity_*.py；剩余=视觉精修巡检（P3 级）+ 深色全域逐屏。与本计划内搜索一致性（P3-6/F1）等工作流相互独立）
修订：ZCode（本机 27B 通道）+ 工具链 ｜ 2026-09-20（**执行队列③④收口**：P2-16 关闭（rquickjs 0.12.2，零断点迁移，原崩溃配方转正为回归断言，b662d71741/36bc435921）；P3-6 剩余面收口（F1 loginCheckJs 三叉点对齐 + 错误八分类 + S0-D 计时 + 三入口一致性测试，deb0e87005/473968bcaf，版本 2.0.298+299）；5556 模拟器环境故障（LDPlayer 实例 1 的 VBox 栈无法拉起 VM 内核进程，主代理经 ldconsole 冷启动循环/关弹窗等多手段未能复活，需人工修复），批次冒烟改用 5554。队列下一阶段：⑤UI 剩余（RenderFlex overflow + 深色逐屏台账））
修订：ZCode（本机 27B 通道）+ 工具链 ｜ 2026-09-20（**执行队列①②收口**：P2-11 五小项全关（d13d1a04e5/16f6e09e92/0fe222a3c8，版本 2.0.297+298）——§196 配对实验顺带挖出「顶层 return 规则被静默吞空」的引擎级根因并修复；卫生批三项（legado-net 回环免代理 cda70a0c54、cache_store 测试注入 b816977643、9 例联网用例夹具化转离线 f101b8f673，ignored 30→21）；P2-13 销记（指纹校验 7a84235382 早已落地，「凡改 Rust 必须手工 build-android.ps1」临时纪律解除）。执行队列下一阶段：③P2-16 rquickjs 升级 + P3-6 剩余面调研 → ④搜索一致性实施 → ⑤UI 剩余）
修订：ZCode（本机 27B 通道）+ 工具链 ｜ 2026-09-19（**同批第二批收口**：P2-15 ② cache 宿主接线 + 第 3 条 overlay 收窄/陈旧让位（提交 `6d2a5c29cc`/`e5da605fd1`，版本 2.0.295+296，含设备级落盘冒烟）；**新增 P2-17**（`legado-ffi` 11 个真联网用例补 `#[ignore]`，判定法=死代理跑全量档且**必须加 `--no-fail-fast`**；附「`legado-net` 3 例系回环被代理劫持、不得误 ignore」的方法论提醒）；**新增 P2-18**（Flutter CI 的 `Set up Android SDK` 因 `tools` 包被 SDK 仓库移除而长期失败 → `analyze` 作业被 skip、Flutter 门禁从未在 CI 跑过；修为 `packages: 'platform-tools'`，两次 CI 运行两作业全绿）；P2-11 回头关闭 ①②③④ 与 §201。Rust CI 与 Flutter CI 均为绿（run 35445743451 / 35445743433）
修订：ZCode（本机 27B 通道）+ 工具链 ｜ 2026-09-19（**P2-7 三条全部关闭**：P2-7(b)/(c) 的 CI 间歇 SIGSEGV 定为 rquickjs-sys 0.9 内置 quickjs-ng 0.8 的 `build_backtrace` 重入 OOM use-after-free（WSL gdb 实证），用例改单次巨量分配 + CI 撤销无效隔离（提交 `d689584fef`）；旧登记中「崩溃点在 `JS_SetPropertyValue`」与「并行内存压力致间歇」两处结论据此更正。**新增 P2-16**：升级 rquickjs ≥0.12 取回上游修复（生产 64MB 上限下同型崩溃理论可达，定级中高）。同批另修 CI 间歇红第二个来源：`legado-ffi` 11 个真联网用例补 `#[ignore]`（判定方法=死代理跑全量档）

### P3 级新登记（2026-09-22，P2-19 修复过程中发现，未修）
- **`clippy --all-targets -D warnings` 的 3 处既有债务**：`rust/legado-net/src/custom_hosts.rs:279`、`:324`（`MutexGuard` 跨 await）与 `rust/legado-net/src/client.rs:796`（`test_connection_pool_reuses_keep_alive` 的 `never_loop`）。CI 不带 `--all-targets` 不拦，但 `rust/DEVELOPMENT.md` 记载的文档门禁会拦；清理各 1–3 行。→ **已清（2026-09-23，提交 `5b7962bf27`）**：`TEST_LOCK` 改 `tokio::sync::Mutex`（`const_new` + 9 处 `.lock().await`，7 个同步测试转 `#[tokio::test]`，互斥语义不变）；keep-alive 服务器按连接退出重构（`break 'conn`）。`cargo clippy -p legado-net --all-targets -- -D warnings` 归零、`cargo test -p legado-net` 247 ×3 连跑绿。
- **【新登记 2026-09-23，清上述 3 处时发现，未修】`cargo clippy --workspace --all-targets -- -D warnings`（`rust/DEVELOPMENT.md` L123/L592/L705 记载的文档门禁）仍有 45 处范围外既有报错**——非本次改动引入（多为工具链 clippy 0.1.97 新启用/增强 lint 对 test 目标的漂移）。分布：`legado-ffi` 28（`field_reassign_with_default` ×16、`useless_vec` ×3、`too_many_arguments` ×1、`items after a test module` ×2、`io::Error::other` ×2、`dead_code` ×2（quickjs feature 门控内，默认档天然 dead）、`unneeded Ok(?)` ×2、`get(0)`/`len()==0`/`format!` 等）、`legado-js` 10（`cache_store.rs`/`current_source.rs`/`font_api.rs` 的 `is_multiple_of`、`redundant_closure`、`useless_vec` 等）、`legado-core` 5（`book.rs`/`search_aggregate.rs` 的 `field_reassign_with_default`、`regex_safe.rs` 循环内编译正则）、`legado-parser` 1（`#[must_use]` 无消息）、`legado-server` 1（`login_check.rs`）。**其中 1 处（`legado-core/src/search_aggregate.rs:450`）为队列⑩a 引入**，其余为历史存量。CI 不带 `--all-targets` 故不拦（`cargo clippy --workspace` 两档均 0）。处置建议：单开一批机械清理（多为 1–3 行/处；`too_many_arguments` 与 `dead_code` 两型需逐个裁决 allow 或加 `#[cfg(feature)]`），或反之修订 `rust/DEVELOPMENT.md` 门禁口径与 CI 对齐——**待裁决，本台账不擅自决定**。
- **JS 侧跨源 cookie 泄漏**（`legado-js/src/host_api/network.rs:279-289`，见 P2-19 内「新登记」，面大于已修的 P1-1）。
