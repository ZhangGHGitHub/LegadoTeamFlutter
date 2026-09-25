# 阶段 1 侦察结论（能力面对账前置信息）

## 1. 生产引擎配置（quickjs_impl.rs / js_executor.rs）
- `QuickJsEngine::new(SandboxConfig)`；生产：`SandboxConfig::default().with_allow_script_run(true).with_memory_limit(64*1024*1024)`
- SandboxConfig 默认：timeout=5s、stack=512、mem=16MB（被 64MB 覆盖）、allow_file_access=false
- 每次 eval 前 `reset_deadline(timeout)`，超时会话被 interrupt handler 终止
- 全局 eval（非严格模式）；`check_syntax` 在 eval 内部

## 2. 已注册能力面（quickjs_impl.rs，`register_all_apis`）
- 共 164 个已注册函数名（完整清单见 report_02，从源码正则提取）
- **双挂载**：`mount_dual(java, globals, name)` → 每个函数同时挂在 `java.*` 与裸全局
- **文件 API 门控**（`if config.allow_file_access`，生产=false）：
  `cacheFile, deleteFile, downloadFile, fileExists, getFile, getTxtInFolder, readFile, readTxtFile, writeFile`
  → 这 9 个在生产配置下**未注册**，源引用即缺口
- **网络函数**（生产会真实联网）：`httpGet, httpPost, httpHead, ajax, putGlobalHeaders, ajaxAll, connect, connectNR, head, post`
- **threadSleep**：Rust 侧真实 `thread::sleep`（上限 30s），JS 中断处理器拦不住 → 干跑必须打桩
- `reportUnknownSymbol` 仅挂在 java 命名空间（P3 强化）
- Rust 侧 `cache` 对象：get/put/delete/getFile/putFile 等；setup 脚本 JS 侧 `cache`：get/put/remove
- 原生 `get`（单参）= 变量存储读取，不联网；裸全局 `get` 保持原生

## 3. Packages 已知树（`__pkRoot`，unknown → 记台账并抛错）
```
java.lang.{String, Integer, Long, Double, Boolean, Thread, System}
java.util.{UUID, Arrays, HashMap, zip.{Inflater, InflaterInputStream}}
java.io.{ByteArrayInputStream, ByteArrayOutputStream, InputStream}
java.nio.ByteBuffer
java.security.MessageDigest
android.util.Base64
cn.hutool.crypto.digest.DigestUtil
javax.crypto.{spec.{SecretKeySpec, IvParameterSpec}, Cipher}
org.jsoup.{Jsoup, parser.Parser}
```
- `Java.type(name)` / `importClass(name)` → 陷阱 → 台账
- unknown 成员访问 → `java.reportUnknownSymbol(full)` + 抛 `Error('此书源需要 Java 脚本能力（Packages.<full>），当前不支持')`
- `java.security` / `java.lang` 同时镜像到裸 `java` 对象
- **jsoup 桥**（`JSOUP_BRIDGE_JS` pub const，测试可复用）：`org.jsoup.Jsoup.parse(html).select(css)` 集合对象（attr/text/html/size/isEmpty/first/get/each/select/toString）+ `Parser.unescapeEntities`，镜像到 `Packages.org.jsoup`
- **注意：无裸全局 `JSoup`/`jsoup` 标识符**——源若裸用 `JSoup.parse(...)` 会 ReferenceError（潜在缺口，待静态扫描确认）
- **response 桥**（`RESPONSE_BRIDGE_JS` pub const）：`java.connect` 包装（注入时捕获原生 connectNR/connect）、`java.get`（2 参→Response；1 参→原生变量读）、`java.post`/`java.head` → Response 对象、`globalThis.connect = java.connect`
  → 干跑只需替换 `java.connect`（包装器捕获的是注入时的原生引用，替换后网络路径即断）

## 4. 能力台账（capability_ledger，process-global，pub）
`record_unknown_java_symbol` / `unknown_java_symbols() -> Vec<(String,u64)>` / `reset_unknown_java_symbols()` /
`record_jslib_load_failure` / `jslib_load_failures()` / `LEDGER_TEST_LOCK: Mutex<()>`
容量 256 条 / 120 字符截断 → 干跑**每源 reset** 防止跨源污染

## 5. 生产 JS setup（legado-ffi::api::source_js_bindings）
- `book_source_js_setup_script(&BookSource) -> LegadoResult<String>`（pub，line 189）
  注入 baseUrl/sourceUrl/loginUrl/__srcData/source/sourceApi + JS cookie 对象（getCookie/setCookie/clearCookies/removeCookie）+ JS cache 对象 + 源变量键 + `__mountBookSourceApi(source)`
- searchUrl JS 执行（legado-parser/src/analyze_url.rs）：
  正则 `(?i)<js>([\s\S]*?)</js>|@js:([\s\S]*)` + 私有 `js_variable_prologue`（绑定 key/page 等）
  + `js_eval_uri_fallback_prologue`（包裹 global eval，URI 型输入 eval 失败时回退原字符串）→ 测试内原样复制该 JS

## 6. 语料（.tmp/corpus/yckceo_1283.json，916 源）
- `BookSource` = `legado_core::models::BookSource`（camelCase serde），corpus 可直接反序列化
- 字段出现次数：jsLib 59 / searchUrl 915 / ruleSearch+ruleBookInfo 916 / ruleToc+ruleContent 915 / exploreUrl 690 / loginUrl 193
- 100 个 searchUrl 含 `@js:` 或 `<js>`；exploreUrl+loginUrl 另含 166 处 JS（任务范围外，仅记录）

## 7. 清扫入口设计（已定稿）
- 新文件 `rust/legado-ffi/tests/capability_sweep.rs`（integration test，不碰任何 src/**）
  - ffi 以 rlib 暴露 `legado_js`/`legado_core`/`legado_parser` re-export，`quickjs` feature 门控
  - `#![cfg(feature = "quickjs")]` → 默认档 `cargo test --workspace` 编译为空 crate，门禁 1 安全
  - 静态对账测试**不 ignore**（快、离线）；干跑测试 `#[ignore]`，`-- --ignored` 跑
- 离线断网（低成本方案）：setup 后 eval 一段 monkey-patch JS，把
  `java.ajax/ajaxAll/connect/connectNR/httpGet/httpPost/httpHead` 换为记录器（返回空 Response JSON），
  `java.get` 按参数量分派（≥2 参→记录器；1 参→保留原生变量读），`java.post/head`→记录器，
  `java.webView/webViewGetSource/webViewGetOverrideUrl`→返回 ''，
  `java.startBrowser*/openUrl/reLoginView/openVideoPlayer`→记录器，
  `java.threadSleep`→no-op；调用记入 `globalThis.__netCalls`
- 每源隔离：专用 `std::thread`（QuickJsEngine 是 unsafe Send），join Err → **d 类（引擎内部错误，最高优先）**
- 每源超时：引擎 deadline 5s 免费获得
- 分类：a 缺失 Java 能力（错误文案/台账符号）/ b JS 语法/引用错误 / c 触网（`__netCalls` 非空 → 离线不可判）/ d panic 或 setup 失败
- 输出：`.tmp/capability_sweep/dry_run_report.md` + `dry_run_details.json`（符号→源数排行榜，含 3 示例源）
