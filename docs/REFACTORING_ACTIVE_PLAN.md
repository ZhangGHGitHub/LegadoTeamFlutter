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
| 本轮验证 | 可复现通过（`6cbcea4f3`，2026-08-22） | Rust `cargo test --workspace --features quickjs`：parser 249/0、js 497/0 + 2 ignored、ffi 355/0 + 27 ignored、server 171/0（`81ad6e220` 起 Rust 侧无变更）；flutter analyze 0 issues；flutter test +1209 全过 |

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
- 进行中：P1-1 FRB StreamSink 运行时验证（Cursor，逐流真实 DLL 证据）；P1-4 状态口径统一（本条目即其落地）。

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

#### P1-1 验证 FRB StreamSink 生成链路

**问题**：生成代码中存在 StreamSink<String> 的 `unimplemented`/`UnimplementedError` 分支。静态代码不能证明其可达性。

**行动**：列出所有 StreamSink FFI 方法，在真实 DLL/so、非 Mock 模式下逐个验证订阅、事件、正常结束和取消；不得手改生成文件。若可达，修正源 API 或 codegen 配置后原子重生成、重编译、替换二进制。

**关闭条件**：每个流 API 有运行时证据和回归测试，或有生成器不可达性说明及版本固定证据。

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

#### P1-4 统一状态入口

**问题**：`docs/README.md` 测试数字和当前分支成果滞后；旧剩余计划同时出现“全部完成”和大量开放项。

**行动**：`docs/README.md` 只保留完成基线、Active 计划、残余风险和当前验证入口；`REFACTORING_REMAINING_PLAN.md` 标为历史归档；所有新任务只进入本文。

**关闭条件**：任一当前文档不会把过期测试数字或历史开放项当作当前状态；链接全部指向有效文件。

### P2：技术债、边界和外部验收

- **P2-1 Rust 旧布局入口**：核对 `layout.rs:232-326` 的 `char_from_index` 空实现是否有消费者；无消费者则删除/私有化，有消费者则改为真实文本输入并测试。Flutter 主阅读链仍以 Dart 排版为准。
- **P2-2 搜索实现统一**：P0-3 完成后抽取 Server/FFI 共享搜索服务，避免两套入口长期分叉。
- **P2-3 Mock 样本口径**：书源/RSS/TTS 使用真实默认资产，但书架仍为占位数据；改文档为“部分真实样本”，后续补脱敏 Android 书架 JSON。
- **P2-4 A* 验收矩阵**：WebDAV、音频/漫画/视频、ruleReview、真机媒体键、皮肤 zip、验证码等逐项登记素材、负责人、命令和证据；待验收不等同工程未实现，也不能销账为完成。
- **P2-5 生成代码和 feature fallback**：按“生产路径/Mock/feature-disabled/生成器不可达”分类治理，取消全局零桩声明。

## 四、文档治理

| 文档 | 当前职责 |
|---|---|
| 本文 | 唯一当前开放项与执行顺序 |
| `docs/README.md` | 当前状态和文档索引 |
| `API_CONTRACT.md` | 跨轨接口契约 |
| `TWO_TRACK_DEV_SPEC.md` | 双轨与 codegen 纪律 |
| `RESIDUAL_RISKS_2026-08-13.md` | A* 和工程残余风险 |
| `SOURCE_DIFF_AUDIT_2026-08-13.md` | 原版源码差异证据 |
| `PARSER_GAP_FIX_PROGRESS_20260815.md` | 解析 parity 交接与证据 |
| `过期文档/README.md` | 历史文档目录和替代关系 |

新增计划、报告、交接文档必须放在 `docs/`；历史材料只允许放在 `docs/过期文档/`，不得再创建新的日期版计划散落在根目录。

编写者：Codex ｜ 2026-08-19
修订：主代理 ｜ 2026-08-20（P0-1 关闭；P0-2 merge-tree 预检与进度记录）
修订：主代理 ｜ 2026-08-22（P0-2 合流关闭：合并提交 81ad6e220、codegen 同步、门禁与冒烟基线更新）
