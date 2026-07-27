# JsExtensions 完整实现与引擎优化计划

## 关键发现（3 agent 综合）

### 阻塞性问题
1. **`java` 命名空间缺失**（Sam 发现）：Kotlin 书源 JS 通过 `java.ajax()`/`java.md5Encode()` 调用宿主 API，但 Rust 注册为裸全局（`ajax()`/`md5Encode()`），导致**所有标准书源 JS 脚本无法运行**
2. **ureq 独立网络栈**（Alex 发现）：JS 层使用同步 ureq，每次请求新建连接池，完全绕过 legado-net 的连接复用/限流/重试/代理
3. **超时中断缺陷**（Alex 发现）：`engine.rs:328-343` 用 `Instant::now().elapsed()` 而非绝对时间计算 deadline，超时判断基本失效
4. **HostApiRegistry 死代码**（Sam 发现）：`mod.rs:25-168` 的 11 个 register 方法全是空 TODO，真实注册在 `quickjs_impl.rs`

### 当前 API 覆盖率
- 已实现 42 个 JS 函数（编解码 10 + 字符串 8 + JSON 3 + 正则 3 + 时间 4 + 文件 4 + 变量 4 + 工具 2 + 网络 4）
- Kotlin 侧 70+ 公开方法
- 平台专属不可移植 ~15 个（webView/toast/openUrl 等）
- 目标：跨平台核心 55+ 方法

---

## 阶段 1：注册框架修复（最高优先级，阻塞性）

### Task 1.1: 清理死代码 + 创建 HostEnv
- **删除** `rust/legado-js/src/host_api/mod.rs:19-174` 的 `HostApiRegistry` 结构体及 11 个空方法
- **新建** `rust/legado-js/src/host_api/env.rs` — `HostEnv` 共享环境结构体
  ```rust
  pub struct HostEnv {
      source_tag: Option<String>,
      cookie_store: Arc<dyn CookieStore>,
      cache_dir: PathBuf,
      variables: Arc<Mutex<HashMap<String, String>>>,
      http: Arc<LegadoClient>,
  }
  ```
- **修改** `rust/legado-js/src/source_engine.rs` — 删除 `host_api` 字段，改由 HostEnv 承载
- 依赖：无
- 风险：低（删除死代码不影响任何功能）

### Task 1.2: java 命名空间 + 双挂载
- **修改** `rust/legado-js/src/host_api/quickjs_impl.rs:28-45`
  - 在 `register_all_apis` 开头创建 `java` 对象
  - 所有函数同时挂载到 `java` 对象和裸全局（保持现有测试兼容）
  - 结尾 `globals.set("java", java)?`
- **新建** `rust/legado-js/src/host_api/register.rs` — `define_fn!` 宏减少注册样板代码
- 依赖：1.1
- 风险：中（需确保现有 11 个 quickjs 引擎测试不回归，裸全局兼容是关键）
- 验证：`cargo test -p legado-js --features quickjs` 全绿 + 新增 `java.md5Encode()` 测试

### Task 1.3: 修复超时中断缺陷
- **修改** `rust/legado-js/src/engine.rs:328-343` — 改用 `Instant::now()` 绝对时刻存储 deadline
- 依赖：无
- 风险：低（独立修复）

---

## 阶段 2：网络栈统一（高优先级）

### Task 2.1: 引入 LegadoClient 桥接
- **新建** `rust/legado-js/src/host_api/runtime_bridge.rs`
  - 全局共享 tokio Runtime（`OnceLock<Runtime>`）
  - 注入 `Arc<LegadoClient>`
  - `block_on` 桥接函数（JS 在独立 OS 线程运行，安全调用）
- **修改** `rust/legado-js/Cargo.toml` — 添加 tokio（rt/sync）+ legado-net 可选依赖
- 依赖：1.1
- 风险：中（block_on 在非 tokio 上下文中安全，需断言检查）

### Task 2.2: 重写 network.rs
- **重写** `rust/legado-js/src/host_api/network.rs` — 删除 ureq，改用 LegadoClient
- 保留同步签名（JS 兼容），底层 I/O 走异步客户端
- 命名对齐 Kotlin：`ajax`/`get`/`post`/`head`/`connect`
- 实现 `ajaxAll` — `futures::stream::buffer_unordered` 有界并发
- **移除** ureq 依赖
- 依赖：2.1
- 风险：中（现有 8 个网络测试需适配，改为 mock server）
- 验证：新增 mock server 集成测试，ajaxAll 并发基准

---

## 阶段 3：引擎性能优化（中优先级，可与阶段 4 并行）

### Task 3.1: 引擎池化
- **新建** `rust/legado-js/src/engine_pool.rs`
  - 按 `source_tag` 缓存 `QuickJsEngine`（`Arc<Mutex<>>` + LRU 淘汰）
  - 避免每源重复 `Context::full` + 全量 API 注册
- **修改** `rust/legado-js/src/source_engine.rs` — 使用引擎池替代每源新建
- 依赖：1.1, 1.2
- 风险：中（单 Context 非线程安全，需 Mutex 串行化 eval）

### Task 3.2: mainJs 求值缓存
- **修改** `rust/legado-js/src/source_engine.rs:188-200` — 首次 eval 后缓存已注入作用域
- 后续 `call_function` 仅 eval 调用表达式
- **替换** `rust/legado-js/src/scope.rs` 手写 O(n) LRU 为 `lru::LruCache`（O(1)）
- 依赖：3.1
- 风险：低

---

## 阶段 4：纯函数 API 补齐（低风险，可并行）

### Task 4.1: Crypto JS 桥接
- **新建** `rust/legado-js/src/host_api/crypto_api.rs`
  - 封装 `legado_core::crypto::{AesCrypto, DesCrypto, Rc4Crypto}` 为 JS 函数
  - `createSymmetricCrypto(transformation, key, iv)` — 解析 "AES/CBC/PKCS5Padding" 格式
  - `digestHex`/`digestBase64Str`/`HMacHex`/`HMacBase64` — 泛化现有 hmac
  - 16 个 @Deprecated 便捷方法（薄包装）
- **修改** `rust/legado-core/src/crypto.rs` — 新增 `parse_transformation()` 函数
- 依赖：1.2
- 风险：极低（纯新增，复用已有 14 个 crypto 测试）

### Task 4.2: Cookie API
- **新建** `rust/legado-js/src/host_api/cookie_store.rs`
  - `getCookie(tag)` / `getCookie(tag, key)` — 委托 legado-net CookieStore
  - 使用 `LazyLock<Mutex<HashMap>>` 模式（同 variable_store）
- 依赖：1.1, 2.1
- 风险：极低

### Task 4.3: 通用摘要 + 编解码扩展
- **修改** `rust/legado-js/src/host_api/encoding.rs` — 追加 `digest_hex`/`hmac_hex`（支持 SHA-1/SHA-256/SHA-512/MD5）
- **追加** `strToBytes`/`bytesToStr`（指定编码）
- Cargo.toml 追加 `sha1`/`sha3` 可选依赖
- 依赖：无
- 风险：极低

### Task 4.4: 字符串/文本扩展
- **新建** `rust/legado-js/src/host_api/html_format.rs` — `htmlFormat`（HTML 标签清理/格式化）
- **修改** `rust/legado-js/src/host_api/string_utils.rs` — 追加 `toNumChapter`（中文数字→阿拉伯数字）
- **新建** `rust/legado-js/src/host_api/chinese_utils.rs` — `t2s`/`s2t`（繁简转换，评估 crate 体积）
- 依赖：无
- 风险：极低（t2s/s2t 字典体积需评估，过大则桩化）

---

## 阶段 5：有状态 API + 安全修复（中风险）

### Task 5.1: 文件 API 沙箱化（安全优先）
- **修改** `rust/legado-js/src/host_api/file_utils.rs` — **所有路径操作添加沙箱校验**
  - 移植 Kotlin `isSameOrDescendantOf` 逻辑（`JsExtensions.kt:752-765`）
  - 路径 canonicalize 后前缀校验，越界抛错误
- **追加** `readTxtFile`/`downloadFile`/`cacheFile`/`importScript`/`getTxtInFolder`
- 依赖：2.1（downloadFile 需 LegadoClient）
- 风险：中（安全关键路径，需充分测试）

### Task 5.2: 解压缩 API
- **新建** `rust/legado-js/src/host_api/archive_utils.rs`
  - `unzipFile`/`getZipStringContent`（zip crate）
  - `un7zFile`/`unrarFile`（评估 sevenz-rust/unrar 可用性，不可行则桩化）
- Cargo.toml 追加 `zip` 依赖
- 依赖：5.1
- 风险：中（新依赖编译兼容性需验证）

---

## 阶段 6：ReadBook 状态机 + 多媒体（可与上述并行）

### Task 6.1: ReadBook 章节预加载
- **新建** `rust/legado-core/src/read_state.rs`
  - 三章滑动窗口（prev/cur/next）
  - `Semaphore(2)` 有界并发预下载
  - LRU 内存缓存 + 失败≥3 熔断
  - 章节切换时取消过期任务
- 参照 `ReadBook.kt:621-630, 95, 1029-1058`
- 依赖：2.1（需异步 LegadoClient 做章节下载）
- 风险：中

### Task 6.2: AudioPlay 预加载优化
- 升级 `AudioPlayUrlPreloadStore` 为有界 LRU（2-3 条）
- 流式播放（reqwest bytes_stream）+ 磁盘缓存
- 参照 `AudioPlay.kt:50-107, 483-525`
- 依赖：2.1
- 风险：中

---

## 阶段 7：平台桩 + 文档收尾

### Task 7.1: 平台专属 API 桩
- **新建** `rust/legado-js/src/host_api/platform.rs`
  - webView/toast/openUrl/startBrowser/getVerificationCode 等 ~15 个方法
  - 统一返回 `"[ERROR] xxx not supported in Rust runtime"` 字符串
- 依赖：1.2
- 风险：极低

### Task 7.2: 文档更新
- 更新 `rust/PROGRESS.md`、`rust/README.md`、`rust/DEVELOPMENT.md`
- 记录 java 命名空间约定、不支持方法清单、模块职责表
- 依赖：所有其他阶段

---

## 依赖图

```
阶段 1（框架修复）
  1.1 清理死代码 ──┐
  1.2 java 命名空间 ┤
  1.3 超时修复 ─────┘
        │
        ├──> 阶段 2（网络统一）──> 阶段 3（引擎优化）
        │     2.1 桥接 ──> 2.2 重写
        │
        ├──> 阶段 4（纯函数补齐，可并行）
        │     4.1 crypto / 4.2 cookie / 4.3 digest / 4.4 strings
        │
        ├──> 阶段 5（有状态 API）
        │     5.1 文件沙箱 ──> 5.2 解压
        │
        ├──> 阶段 6（多媒体，可并行）
        │     6.1 ReadBook / 6.2 AudioPlay
        │
        └──> 阶段 7（桩 + 文档）
```

**关键并行窗口**：
- 阶段 4 的 4 个子任务全部独立可并行
- 阶段 6 与阶段 2-5 可并行
- 阶段 1.3 独立可并行

## 并行开发分工（多 Agent 模式）

### 未完成任务的 Agent 分配

| 任务 | 分配 Agent | 分支 | 状态 |
|------|-----------|------|------|
| Task 5.2: 解压缩 API | **Rust-Infra** | `feature/rust-infra-archive-api` | 待开发 |
| Task 6.1: ReadBook 章节预加载 | **Rust-Core** | `feature/rust-core-read-preload` | 待开发 |
| Task 6.2: AudioPlay 预加载优化 | **Rust-Core** | `feature/rust-core-audio-preload` | 待开发 |

### 并行约束

- Task 5.2 和 Task 6.1/6.2 **完全独立**，可同时开发
- Task 6.1 和 6.2 均修改 `legado-core`，由同一 Agent (Rust-Core) 串行完成以避免冲突
- Task 5.2 修改 `legado-js`，由 Rust-Infra 独立处理
- 合并顺序：Rust-Core (6.1/6.2) 先合并 → Rust-Infra (5.2) 后合并（无依赖但减少冲突）

### 接口约定

Task 6.1/6.2 需在 `legado-core/src/lib.rs` 新增公开模块：
```rust
pub mod read_state;    // Task 6.1: ReadBook 三章滑动窗口
pub mod audio_preload; // Task 6.2: AudioPlay LRU 预加载
```

Task 5.2 需在 `legado-js/src/host_api/` 新增：
```rust
pub mod archive_utils; // unzipFile / getZipStringContent / un7zFile / unrarFile
```

## 预期成果
- java 命名空间修复 → 所有标准书源 JS 可运行
- 网络栈统一 → 连接复用 + 限流 + 重试，ajaxAll 并发提速 N 倍
- 引擎池化 → 避免每源重建 Runtime
- API 覆盖从 42 个提升到 ~55+ 个跨平台核心方法
- 590+ 已有测试不回归

## 被拒绝的方案
1. **1:1 复刻 Android 平台 API**（Sam 评估）：webView/toast/openUrl 等约 15 个方法在 Rust 端无法实现，采用明确错误提示桩化，避免虚假兼容
2. **保留 ureq 同步栈**（Alex 评估）：每请求新建连接池、无中间件、无并发，性能代价过高，必须统一为 legado-net
3. **直接修改已有测试添加 java 前缀**（Sam 评估）：破坏裸全局兼容性，采用双挂载方案保留两种调用方式
4. **升级 rquickjs 获取字节码**（Alex 评估）：0.9 字节码 API 不成熟，先做引擎池化+源码缓存作为兖底

---

## 实现状态审计（2026-07-26）

### 各阶段完成度

| 阶段 | 子任务 | 实际文件 | 状态 |
|------|--------|----------|------|
| 1.1 清理死代码 + HostEnv | `env.rs` 4.3KB | ✅ 完成 |
| 1.2 java 命名空间双挂载 | `quickjs_impl.rs` 36KB + `register.rs` | ✅ 完成 |
| 1.3 超时中断修复 | `engine.rs`（绝对 deadline） | ✅ 完成 |
| 2.1 LegadoClient 桥接 | `runtime_bridge.rs` 1.2KB | ✅ 完成 |
| 2.2 重写 network.rs | `network.rs` 12.7KB（LegadoClient） | ✅ 完成 |
| 3.1 引擎池化 | `engine_pool.rs` | ✅ 完成 |
| 3.2 LRU 作用域缓存 | `scope.rs`（lru crate） | ✅ 完成 |
| 4.1 Crypto JS 桥接 | `crypto_api.rs` 8KB | ✅ 完成 |
| 4.2 Cookie API | `cookie_store.rs` 3KB | ✅ 完成 |
| 4.3 摘要 + 编解码 | `encoding.rs` 20KB | ✅ 完成 |
| 4.4 字符串/文本 | `string_utils.rs` 14.6KB + `html_format.rs` 9.8KB + `chinese_utils.rs` 12.2KB | ✅ 完成 |
| 5.1 文件沙箱 | `file_utils.rs` 20.4KB | ✅ 完成 |
| **5.2 解压缩 API** | `archive_utils.rs` 13KB | ⚠️ zip 完成，**7z/rar 为桩** |
| 6.1 ReadBook 预加载 | `legado-core/read_state.rs` 15.6KB | ✅ 完成 |
| 6.2 AudioPlay 预加载 | `legado-core/audio_preload.rs` 12.3KB | ✅ 完成 |
| 7.1 平台桩 | `platform.rs` 2.6KB（12 个桩） | ✅ 完成 |
| 7.2 文档 | PROGRESS/README/DEVELOPMENT | ✅ 完成 |

### 总体完成度：~95%

**唯一未完成项**：Task 5.2 中的 7z/rar 解压缩为桩实现（依赖 sevenz-rust/unrar crate 成熟度评估）。

### 宿主 API 文件清单（实际）

```
host_api/
├── archive_utils.rs   13KB  — zip 解压 + 7z/rar 桩
├── chinese_utils.rs   12KB  — 繁简转换（~500 字映射表）
├── cookie_store.rs     3KB  — getCookie/setCookie
├── crypto_api.rs       8KB  — AES/DES/RC4 + transformation 解析
├── encoding.rs        20KB  — MD5/SHA/Base64/Hex/HMAC/URL
├── env.rs              4KB  — HostEnv 共享环境
├── file_utils.rs      20KB  — 沙箱文件操作
├── html_format.rs     10KB  — HTML 标签清理
├── json_utils.rs       6KB  — jsonPath/jsonGetString/toJson
├── mod.rs              1KB  — 模块导出
├── network.rs         13KB  — ajax/get/post/head/ajaxAll (LegadoClient)
├── platform.rs         3KB  — 12 个平台桩
├── quickjs_impl.rs    36KB  — QuickJS 注册主入口（java 命名空间）
├── regex_utils.rs      6KB  — regExp/regExpReplace/regExpFindAll
├── register.rs         1KB  — mount_dual 双挂载宏
├── runtime_bridge.rs   1KB  — tokio Runtime 桥接
├── source_callback.rs 10KB  — 书源回调 API
├── string_utils.rs    15KB  — 字符串工具 15+ 函数
├── time_utils.rs       5KB  — 时间格式化
└── variable_store.rs   4KB  — 变量存储
```