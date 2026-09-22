# 重构进度深度审计与计划修订建议（2026-08-19）

> 审计性质：源码、文档、提交与 CI 配置交叉核对。本报告仅新增审计文档，不修改业务代码。
>
> 审计基准：feature/rust-parser-gap-fix，HEAD e74c2a6dbe35fe875068e9c14a0205aeac4e37e7；master 为 75593d26c。
>
> 结论：Phase 0-4 的 Flutter + Rust 主链迁移已具备较高完成度，但“工程仅剩 A* 验收”的口径不成立。当前至少有一个真实服务端生产空实现、一个未集成的解析修复分支、FFI 流生成链路未做运行时证明，以及契约和状态台账漂移。应将 REFACTORING_REMAINING_PLAN.md 保留为历史归档，并另建单一 Active Ledger。

---

## 1. 证据范围

| 维度 | 已核对证据 | 判定 |
|---|---|---|
| 计划与规范 | REFACTORING_PLAN、REFACTORING_REMAINING_PLAN、TWO_TRACK_DEV_SPEC、API_CONTRACT、docs/README | 多份历史口径与当前状态相互覆盖 |
| Rust/Flutter 主链 | FFI 搜索、阅读器排版、BookApi/RustApi/MockBookApi、解析器提交 | 主应用 FFI 搜索和 Dart 排版主链存在，不是整体未迁移 |
| 服务端 | legado-server 的 search handler、路由及测试 | /api/search/multi 存在真实生产空实现 |
| 提交与集成 | git rev-list、近 25 条提交 | 当前分支落后 master 2、领先 49，未合流 |
| CI | .github/workflows/rust-ci.yml | FFI QuickJS 全量门禁已写入 CI |
| 本轮命令 | cargo test -p legado-ffi --features quickjs；flutter analyze | Rust 因 target 权限失败；Flutter analyze 无输出挂起后停止，均没有产生通过证据 |

### 已校正的历史判断

1. 08-16 审计登记的 G8 跨步分组缺口已经在当前分支提交 a779e1520 落地。rust/legado-parser/src/analyze_rule.rs:363-364、765-819、1571-1597、1876-1892 有实现及回归用例；API_CONTRACT.md:38 也记录了 08-18 销记。不得继续将 G8 排入待开发。
2. 词典和换封面 Provider 已经走真实 BookApi：dict_notifier.dart:103-114、change_cover_notifier.dart:23-39。旧审计中的 Mock 主链结论不可沿用。
3. Flutter 阅读器当前使用 Dart paragraph_layout_engine：reader_text_content.dart:12-18。Rust layout.rs 的旧 zh_layout 缺陷是死代码或备用 API 治理问题，不能直接说线上阅读器的标点避头尾已经失效。

---

## 2. Active Ledger 初始条目

### P0

| ID | 问题与证据 | 风险 | 修订计划和验收 |
|---|---|---|---|
| AL-P0-1 | 服务端 POST /api/search/multi 直接创建 NoopSourceSearcher，见 rust/legado-server/src/handlers/search.rs:92-121。该搜索器返回空结果；现有测试仅断言 HTTP 200，见 235-285。FFI 搜索却走真实 WebSourceSearcher，见 rust/legado-ffi/src/api/search.rs:87、259。 | 调用 server/MCP/HTTP API 的客户端会收到成功状态和空结果。 | 选择并记录架构：让 server 复用真实共享搜索服务，或明确废弃并移除路由。新增注入可控书源的集成测试，断言非空结果、取消和超时语义，不得只测 200。 |
| AL-P0-2 | 当前分支相对 master 为 2 49。HEAD 包含 parser parity、G1-G15 和书山修复，master 仍有两个未吸收提交。 | 主干与发布不能保证包含当前修复；URL、AES、JsonPath 同域合并可能回归。 | 建 integration/rust-parser-parity，先整合 master 再合当前分支，跑 QuickJS、Flutter、双 ABI FFI hash 和 5556/5558 冒烟后才更新主线完成口径。 |
| AL-P0-3 | 本轮 Rust 命令写 rust/target/debug/.fingerprint/.../lib-legado_net 时返回 Windows os error 5；flutter analyze 长期无输出。 | 无法证明当前 49 个分支提交未回归，历史测试数字不能替代本轮证据。 | 排查 target ACL、进程占用和 Flutter/Dart 缓存锁，在干净可写 target 重跑。记录 HEAD、命令、通过数和耗时。环境修复不应改业务逻辑。 |

### P1

| ID | 问题与证据 | 风险 | 修订计划和验收 |
|---|---|---|---|
| AL-P1-1 | FRB 生成物的 StreamSink<String> 仍有 unimplemented 分支：rust/legado-ffi/src/frb_generated.rs:9051-9055；flutter_legado/lib/src/bridge/frb_generated.dart:8788-8792、8882-8888。 | 可能是生成器的不可达分支，也可能在流 API 编解码时触发；静态 grep 无法证明安全。 | 不手改生成文件。列出所有 StreamSink<String> FFI，在真实 DLL/so、非 Mock 模式逐个订阅、产生事件和取消；增加集成测试。若可达，修正 FFI/codegen 并全量重新生成。 |
| AL-P1-2 | AutoTask UI 模型不保存真实 script，toJson 按 taskType 重建 refreshToc 等占位脚本，见 auto_task_state.dart:69-92。findBookUpdateTask 已注明 list 失败降级会失去书名+作者匹配，见 auto_task_notifier.dart:480-513。 | 导入或降级路径可能覆盖真实 action，或者重复创建图书更新任务。 | 模型保存原始 script/action 元数据，禁止展示层重建可执行脚本；定义旧 JSON 迁移，补 refreshToc、更新源、备份和图书更新任务 round-trip、导入、fallback 测试。 |
| AL-P1-3 | API_CONTRACT.md:121-122、868-876 仍称 BookApi 252、附录 251；程序统计 BookApi 261、RustApi override 262。登录四方法已存在于正文和代码，但计数、附录未闭合。 | 双轨唯一契约基准失效，后续容易漏 Mock、漏文档。 | 新增可执行一致性检查，校验 BookApi/RustApi/Mock 方法集合、文档条目、例外和总数。本次先修正方法表和计数，并解释 261/262 差异。 |
| AL-P1-4 | docs/README.md:39-52 自称唯一权威入口，仍写 Rust 311、Flutter 1171，且没有 08-18/19 parser parity；REFACTORING_REMAINING_PLAN 的归档完成声明与旁证开放项混排。 | 接手者无法正确判断未合流、已修、待素材事项。 | docs/README 只呈现带 HEAD/CI 证据的摘要及 Active Ledger 链接；剩余计划冻结为历史归档，不再承载活跃任务。 |

### P2

| ID | 问题与证据 | 建议 |
|---|---|---|
| AL-P2-1 | rust/legado-core/src/layout.rs:232-326 使用 char_from_index，433-437 恒返回空字符；正确 zh_layout_text 在 451 行后并有测试。 | 先确认调用图。无生产消费者则删除/私有化旧入口；若需 FFI，改为传真实字符数组并补边界测试。 |
| AL-P2-2 | server 与 FFI 维护不同搜索实现，前者为空、后者真实。 | 提取可复用搜索服务并以依赖注入供 server、FFI 共用，避免继续分叉。 |
| AL-P2-3 | MockBookApi 的书源/RSS/TTS 为真实默认资产，但书架是调试占位，见 mock_book_api.dart:12-29、58-63。 | 状态改为“部分真实样本”；取得脱敏 Android 书架 JSON 后替换并版本化。 |
| AL-P2-4 | A* 实网/素材验收仍未完成，见 RESIDUAL_RISKS_2026-08-13.md:87-93，包括 WebDAV、音频、漫画、视频、ruleReview、真机媒体键、皮肤 zip。 | 独立保留为外部依赖；每项登记案例、素材、负责人、有效期和证据。未验收不能写“全库完成”。 |
| AL-P2-5 | 生成代码、feature fallback、Mock TODO 与历史计划旧计数使“零 TODO/桩”全局声明不可验证。 | 用范围化口径分别描述 Flutter FFI、server API、Mock、feature-disabled 和生成代码，禁止绝对性全局声明。 |

### P3

- 统一 docs/README、根 README、API_CONTRACT 的版本、Screen 数、测试数和分支状态，全部引用可追溯 HEAD/CI。
- 当前工作树已有 GeneratedPluginRegistrant.swift、package.json 以及多份 docs/skills/spec 未提交项；它们不属于本报告范围，集成 parser 分支时必须按归属分批处理。
- Active Ledger 中明确区分“代码已修但未集成”“已实现待真实环境验收”“确认 N/A”，避免单一完成标记误导。

---

## 3. 对计划的操作建议

1. 保留 REFACTORING_PLAN.md 作为历史架构纲领，不重写。
2. 冻结 REFACTORING_REMAINING_PLAN.md 为归档：原七项核销保留，但在文首声明不是当前开放项来源。
3. 新建唯一 Active Ledger，以 AL-P0-1 到 AL-P2-5 为初始条目，要求 owner、依赖、代码位置、验收命令、状态和关闭提交。
4. 执行顺序：先 AL-P0-3 恢复可复现门禁，再 AL-P0-2 分支集成；接着 AL-P0-1 server 搜索；随后验证 AL-P1-1，最后处理 AutoTask 与契约治理。A* 始终独立。
5. 为 FFI、server、MCP 等同能力补入口一致性门禁；HTTP 200 或编译成功不再作为功能完成标准。

---

## 4. 本轮验证状态

| 命令 | 状态 | 说明 |
|---|---|---|
| cargo test -p legado-ffi --features quickjs | 未完成 | 编译初期 target 指纹写入被拒绝访问，未产生测试结果。 |
| flutter analyze | 未完成 | 长期无输出且未结束，已停止，未使用历史 0 error 替代。 |
| Rust CI 静态检查 | 完成 | rust-ci.yml:26-31 已跑 cargo test -p legado-ffi --features quickjs。 |
| 源码、提交、文档交叉检查 | 完成 | 结论和定位均已登记。 |

---

编写者：Codex ｜ 2026-08-19
