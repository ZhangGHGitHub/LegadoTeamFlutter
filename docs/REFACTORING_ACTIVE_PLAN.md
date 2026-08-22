# Legado 后续重构执行计划（Active）

> 版本：2026-08-19
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
| 主线集成 | 未完成 | `feature/rust-parser-gap-fix` 相对 `master` 为落后 2、领先 49 |
| 真实环境 | 未完成 | A*：WebDAV、媒体源、真机按键、ruleReview、皮肤等仍需素材 |
| 本轮验证 | 未完成 | Rust target 写入权限可由临时目录规避；Flutter analyze 在不同尝试中分别得到 84 issues 或长时间无输出，仍不可复现通过 |

### 2026-08-19 执行进度

- P0-1 Rust 确认了原 `os error 5` 可通过独立 `CARGO_TARGET_DIR` 规避。
- `js_executor::tests::test_build_search_url_with_js_lib` 已修复并提交：`3f07f5de3`；parser 全量 `245 passed + 1 doctest`，相关 FFI 测试 `1 passed`，新增两个 parser 边界测试通过。
- QuickJS 全量门禁仍未通过：`356 ok`、`1 failed`、`20 ignored`，另有 `test_batch_search_scan_extended_wave2` 长时间运行后被停止；失败项已从环境问题收敛为源码/测试门禁问题。
- Flutter `analyze` 曾由 Cursor 得到 `84 issues`，主 Agent 后续复跑超过 10 分钟无输出；`flutter test` 尚未完成。
- P0-1 尚未关闭，P0-2 分支合流暂不启动。Cursor 当前因使用额度耗尽无法接收下一项实现任务。

### 2026-08-20 执行进度

- P0-3 已关闭（方案 B）：移除 Server `/api/search/multi` Noop 空实现路由，新增 4xx 防回归测试；`cargo test -p legado-server` 170/0。详见 P0-3 小节。
- P0-1 Flutter 门禁恢复可复现并通过：`flutter analyze` 不再挂起，3.3s，`0 errors / 6 warnings / 78 info`（均 lint，无编译阻断）；`flutter test` 全部通过 `+1190`（23s）。此前挂起为环境问题，现已可复现。

## 三、执行顺序

### P0：先恢复可交付性

#### P0-1 恢复可复现质量门禁

**问题**：本轮 Rust 测试在写 `rust/target/debug/.fingerprint/.../lib-legado_net` 时返回 Windows `os error 5`；Flutter analyze 无输出挂起。

**行动**：

1. 检查 target 文件 ACL、占用进程和残留 Dart/Flutter 进程。
2. 在确认不影响用户未提交代码后，使用干净可写的 target 目录重跑 Rust QuickJS 门禁。
3. 重新运行 Flutter analyze、Flutter test，并记录 HEAD、通过数和耗时。
4. 将验证结果写入本计划或对应关闭报告，不以历史数字替代当前证据。

**关闭条件**：`cargo test -p legado-ffi --features quickjs`、`flutter analyze`、`flutter test` 在当前集成 HEAD 可复现通过；失败时记录真实失败，不得标绿。

#### P0-2 合流 parser/search parity 分支

**问题**：当前分支包含 G1-G15、书山和搜索 parity 修复，但尚未合入 master；master 另有 2 个提交。

**行动**：

1. 从当前 master 创建集成分支。
2. 先合入 parser/search 分支，解决 URL、AES、JsonPath 和生成文件冲突。
3. 完成 Rust QuickJS、Flutter、FFI content hash、Android 双 ABI 和 5556/5558 冒烟。
4. 合流后更新 `docs/README.md` 与本计划的 HEAD/测试基线。

**关闭条件**：集成分支包含双方提交；全量门禁通过；发布构建使用同一批 codegen、Rust 二进制和 Dart 绑定。

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

#### P1-2 修复 AutoTask 原始 action 丢失

**问题**：`AutoTask.toJson` 按 taskType 生成占位 script；在列表失败的降级路径中，真实 action 可能丢失，影响书名+作者匹配和任务导入。

**行动**：模型保存原始 script/action；展示字段与可执行载荷分离；为旧 JSON 增加迁移；补 refreshToc、更新源、备份、图书更新任务的 round-trip、导入和 fallback 测试。

**关闭条件**：任务创建、导出、导入、列表失败降级均保留真实 action，不再用展示模型覆盖执行脚本。

#### P1-3 让 API 契约可自动校验

**问题**：`API_CONTRACT.md` 仍记录 BookApi 252、附录 251，而当前源码统计为 BookApi 261、RustApi override 262。

**行动**：补一致性脚本/测试，比较 BookApi、RustApi、MockBookApi 方法集合和契约表项；明确 RustApi 多出的包装/兼容方法；更新契约正文、附录、变更记录。

**关闭条件**：新增 API 若缺 BookApi、RustApi、Mock 或契约条目，CI 失败；总数由脚本生成或校验，不再人工猜测。

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
