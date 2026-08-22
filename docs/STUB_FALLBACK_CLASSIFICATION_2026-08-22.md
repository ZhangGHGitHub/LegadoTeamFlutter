# 桩 / Fallback / Mock 分类登记（P2-5 审计轮）

> 任务出处：[REFACTORING_ACTIVE_PLAN.md](REFACTORING_ACTIVE_PLAN.md) §三-P2「生成代码和 feature fallback 治理」。
> 本轮为**审计与登记**：仅归类，不改动任何行为代码。审计基线 HEAD：`3b61f0883`（2026-08-22）。

## 一、分类口径

| 类别 | 定义 | 处置态度 |
|---|---|---|
| **生产路径** | 正式行为的一部分：防御性断言、平台条件分支、设计内降级数据 | 保留；降级点需可追踪 |
| **Mock** | 设计内假实现：双轨规范允许的 UI 轨独立开发开关与测试夹具 | 保留；非缺陷 |
| **feature-disabled** | Cargo/Dart feature 关闭时的合法分支：编译期剔除 + 运行时报错降级 | 保留；属生产路径合法分支 |
| **生成器不可达** | 代码生成器产出的守卫分支，正常调用图不可触达 | 保留；已论证不可达 |

审计方法：对 `rust/` 全工作区、`flutter_legado/lib`、生成代码（frb_generated*、*.freezed.dart）做 `unimplemented!/todo!/unreachable!`、`Mock`、`cfg(feature)`、`UnimplementedError/UnsupportedError`、条件导入全量检索，并逐点核读上下文定性。

## 二、分类总表

### A. 生成器不可达（6 组）

| # | 位置 | 证据与理由 |
|---|---|---|
| A1 | `flutter_legado/lib/src/bridge/frb_generated.dart:8830` | `dco_decode_StreamSink_String_Sse` 抛 `UnimplementedError()`；sink 恒由 Dart 侧创建单向传入 Rust（encode 方向），且 dco 编解码仅 Web 构建使用——P1-1 已以真实 DLL 运行时论证不可达 |
| A2 | `flutter_legado/lib/src/bridge/frb_generated.dart:8926` | `sse_decode_StreamSink_String_Sse` 抛 `UnimplementedError('Unreachable ()')`；5 个流 API 均只调用对应 `sse_encode_StreamSink_String_Sse`（L3394/L6969/L7342/L8218/L8760），解码方向零调用点 |
| A3 | `rust/legado-ffi/src/frb_generated.rs:9089` | `impl SseEncode for StreamSink` 内 `unimplemented!("")`——A1/A2 的 Rust 侧镜像：不存在 Rust 到 Dart 方向的 sink 序列化需求 |
| A4 | `rust/legado-ffi/src/frb_generated.rs:9048` | wire 分发表默认臂 `unreachable!()`；func_id 由 FRB 生成器成对生成，越界 id 无法经公开链路构造 |
| A5 | `rust/legado-ffi/src/frb_generated.rs:9060` | `pde_ffi_dispatcher_sync_impl` 空 match + `unreachable!()`；Pde 同步编解码为 Web 构建设计，io 绑定链路不调用该分发器 |
| A6 | `flutter_legado/lib/src/**/**.freezed.dart:14`（32 个文件） | freezed 生成器私有构造守卫 `_privateConstructorUsedError`（UnsupportedError）；仅当绕过工厂直接 new 私有构造时触达，正常使用不可达 |

### B. Mock（设计内，9 组）

| # | 位置 | 证据与理由 |
|---|---|---|
| B1 | `flutter_legado/lib/src/providers/providers.dart:15-18` | bookApiProvider 按 `bool.fromEnvironment('USE_MOCK')` 注入 MockBookApi/RustApi；编译期 dart-define 开关，默认 false=真实 FFI，双轨规范允许 |
| B2 | `flutter_legado/lib/main.dart:42-56` | 启动初始化同款 USE_MOCK 分支；默认走 RustApi 真实初始化 |
| B3 | `flutter_legado/lib/src/services/mock_book_api.dart:30` | MockBookApi implements BookApi 纯 Dart 假数据实现（UI 轨独立开发用，--dart-define=USE_MOCK=true 启用） |
| B4 | `rust/legado-core/src/web_book.rs:154` | pub struct MockBookSourceFetcher，doc 注释「用于单元测试的 Mock Fetcher」；全工作区 26 处引用全部位于本文件测试代码，无生产消费者 |
| B5 | `rust/legado-core/src/search_engine.rs:98` | NoopSourceSearcher 设计内空实现（trait 默认示例/单测泛型参数）；生产搜索使用 FFI 侧 WebSourceSearcher |
| B6 | `rust/legado-net/src/client.rs:928` | MockPersistence 内存 Cookie 后端，位于 L907 起的 #[cfg(test)] 测试模块 |
| B7 | `rust/legado-parser/src/analyze_url.rs:2335` | MockJsExecutor，位于 L1589 #[cfg(test)] 测试模块内 |
| B8 | `rust/legado-parser/src/analyze_rule.rs:1997` | MockJsExecutor，位于 L1809 #[cfg(test)] 测试模块内 |
| B9 | `rust/legado-core/src/content_processor.rs:745` | MockJs，位于 L701 #[cfg(test)] 测试模块内 |

### C. feature-disabled（quickjs 门控 182 处 cfg，归并 3 组）

| # | 位置 | 证据与理由 |
|---|---|---|
| C1 | `rust/legado-js/src/`（engine/engine_pool/sandbox/scope/source_engine/js_source_config/host_api 全家桶，约 120 处） | quickjs 真实引擎 vs 占位结构双轨：关闭时 JS eval 直接返回错误（源码自述「未启用 quickjs 时的降级实现：无法执行 JS，直接报错」，见 engine.rs L166 与 host_api/{encoding,file_utils,html_format,json_utils,regex_utils,string_utils,time_utils}.rs 各占位实现） |
| C2 | `rust/legado-ffi/src/`（js_executor 26 处、api/search 12、api/explore_api 14、api/image_api 7、api/pre_update 7、dict_api 3、source_callback_api 3、source_js_bindings 3、source_login_v2_api 2、pay_action_api 2、review_api/web_book/bridge/ffi 各 1） | 书源 JS 能力在 quickjs 关闭时编译期剔除、调用点报错降级（js_executor.rs L574/L579 的 QuickJsExecutor 导出与 fresh_engine/pool_engine 均挂门控） |
| C3 | `rust/legado-server/src/login_check.rs`（3 处）、`handlers/mcp.rs`（1 处） | 服务端书源登录检查/MCP 工具同受 quickjs 门控，语义同 C1/C2 |

### D. 生产路径（防御性断言 / 平台分支 / 设计内降级，5 组）

| # | 位置 | 证据与理由 |
|---|---|---|
| D1 | `rust/legado-net/src/webdav.rs:828` | 重试循环每条路径必 return 或 sleep 后 continue，循环出口不可达；unreachable!() 为循环不变量防御断言，非桩 |
| D2 | `flutter_legado/lib/main.dart:96/:110`、`screens/qrcode_screen.dart:32`、`app.dart:168` | kIsWeb / defaultTargetPlatform 平台条件分支（崩溃指引文案、扫码可用性、封面 URL 判定），平台差异化生产逻辑 |
| D3 | `flutter_legado/lib/src/providers/dict/dict_state.dart:10` | 核验（2026-08-22）：生产路径无静态内置词典，查询直达 Rust FFI dict_lookup；原注释过时已修；Mock _mockDict 为 B 类夹具 |
| D4 | `flutter_legado/lib/src/screens/about_screen.dart:100` | 关于页 Markdown 资产缺失时回退内置文本（避免假功能），UI 兜底 |
| D5 | `flutter_legado/lib/src/screens/qrcode_screen.dart:202` | 相机预览占位组件（桌面端无相机时的降级提示 UI），平台能力兜底 |

> 备注：Dart lib 内其余含「占位」字样的命中均为 UI 骨架屏/占位图/占位符文案等界面概念，不属桩范畴，未列入。lib 内仅有 2 处 `TODO(§6.4)` 书架真实数据替换标记（mock_book_api.dart:29/:62，P2-3 跟踪中），无其它 TODO/FIXME 标记。

## 三、「全局零桩声明」定位与替代口径

### 3.1 声明原文位置清单

| 位置 | 原文摘录 | 状态 |
|---|---|---|
| docs/过期文档/PROJECT_AUDIT_REPORT.md:14 | 「Rust 侧零 todo!()/unimplemented!() 桩」 | 需取消的全局声明（文件已归档过期目录，但表述仍可能被转引） |
| docs/过期文档/PROJECT_AUDIT_REPORT.md:169 | 「✅ 零 todo!()/unimplemented!()；错误处理统一 Result/BridgeError」 | 同上 |
| docs/过期文档/PROJECT_AUDIT_REPORT.md:219 | 「Rust 侧无桩实现、错误处理统一」 | 同上 |
| README.md | （grep 无命中） | 无需处理 |
| docs/REFACTORING_ACTIVE_PLAN.md:7/:15 | 「尚未达到……『全库无桩』的状态」「禁止口径：不再使用『零 TODO/桩』……绝对表述」 | 已是纠正口径，与本登记一致，维持不动 |
| docs/README.md:37 | Task #118 口径修正：「早期『零 TODO/桩实现』声明与源码不符，已废止……」 | 已是纠正口径，维持不动 |

### 3.2 替代口径（建议统一表述）

> 不再使用「零桩/无桩」绝对表述。现行口径（P2-5 四分类，基线 3b61f0883）：全部桩/fallback/Mock 点已按「生产路径 / Mock / feature-disabled / 生成器不可达」登记于本文档 §二——生成器不可达 6 组（FRB StreamSink 编解码方向、wire 分发默认臂、freezed 私有构造守卫）、Mock 9 组（USE_MOCK 双轨开关与 cfg(test)/设计内空实现）、feature-disabled 为 quickjs 门控 182 处（关闭时编译期剔除 + 运行时报错降级）、生产路径防御/降级 5 组；**不存在未登记的功能性空实现**。新增桩/fallback 必须同步更新本文档。

## 四、误归类提示与风险备注

1. **易误标项**：dict_state.dart:10 原注释称「本地内置词典为静态占位数据」已过时——核验（2026-08-22）：生产路径无静态内置词典，查询直达 Rust FFI dict_lookup；原注释过时已修；Mock _mockDict 为 B 类夹具。
2. **MockBookSourceFetcher 未挂 cfg(test)**（web_book.rs L154 pub）：当前仅测试消费，无风险；若未来被生产代码引用将绕过真实网络层，建议后续批次评估是否下沉至 test 模块（本轮不改行为，仅登记）。
3. P1-1 已论证的 FRB StreamSink 解码方向不可达（A1/A2/A3）在真实 DLL 上有运行时证据（test/ffi/ffi_stream_sink_runtime_test.dart 8 项全过）。

---

编写者：Cursor（Bridge 层子代理）｜ 2026-08-22