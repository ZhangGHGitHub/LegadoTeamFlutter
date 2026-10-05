# JS 引擎修复批 代码审查报告（2026-10-06）

- 审查范围：`git log 103ee2b0e5..HEAD`（70fe279b7b / ba8ad0694e / e73cf37d8f / fd04ee1154，另 599ceff71d 纯文档、8156855288 iOS UI 不在范围）
- 审查方式：只读。全量 diff 逐块阅读 + 关键语义实机核对（rquickjs 0.12.2 源码、上游 Kotlin 基线、缓存/台账代码路径）+ 真实执行测试。
- 结论先行：**Summary: pass（可合并，附 4 条建议项，无阻塞）**

---

## 一、实际核实清单（证据均为真实执行或代码逐行核对）

| # | 核实项 | 证据 |
|---|---|---|
| 1 | Coerced\<String\> 语义 = `JS_ToString`（数组 join(',')、对象 "[object Object]"、自定义 toString、undefined→"undefined"、null→"null"） | rquickjs-core-0.12.2 `src/value/convert/coerce.rs:34-45`（直接调 `qjs::JS_ToString`），与 coerce.rs 探针表逐行一致 |
| 2 | 分派边界：LooseStrList 仅 `ajaxAll`/`ajaxTestAll` 两处；其余 180 处 RhinoStr/RhinoOptStr；无双重套用、无漏套 | git diff 全量逐块 + `grep -c`（quickjs_impl.rs 182 处 Rhino*）；裸 `String` 形参 grep 0 残留 |
| 3 | ajaxAll JSON 契约：JS 数组→元素逐项 ToString→serde_json 序列化→合法 JSON 数组文本；空/null/undefined→""→`network::ajax_all` 返回 "[]"（network.rs:726-729 新增空输入分支） | quickjs_impl.rs LooseStrList impl + network.rs:723-745 |
| 4 | ajaxTestAll 空串入参：serde_json 失败→split(',') 回退→空列表→"[]"，不报错 | misc_api.rs:76-84 |
| 5 | 上游形参对照：`ajaxAll(urlList: Array<String>)` JsExtensions.kt:154/157、`ajaxTestAll(urlList, timeout)` :173/176，与 LooseStrList 语义对应 | app/src/main/java/io/legado/app/help/JsExtensions.kt |
| 6 | 对象入参不过度宽松的护栏：java.get/post/head/connect 有 JS 垫片先 `JSON.stringify`（quickjs_impl.rs:1101/1107/1114-1131），对象 headers 不会以 "[object Object]" 落到原生层 | RESPONSE_BRIDGE_JS 逐行阅读 |
| 7 | jsLib 缓存不卡死：`engine_cache::get_or_create` 按 **jsLib 内容**比对（:152-161），书源编辑 jsLib 后内容变化→重建条目→可恢复 | engine_cache.rs 逐行 |
| 8 | jsLib 上抛传导：searchUrl 链路经 `legado-js-error://` → web_book.rs:1558 解码 → `LegadoError::JsEngine`（单源失败不崩 App）；`validate_js_lib`（js_executor.rs:280-282）同口径 | js_executor.rs 新增 E2E 测试 + web_book.rs 逐行 |
| 9 | source_engine.rs:145（`new_quickjs`）**不消费** js_lib_ok（mainJs 状态才驱动回评）——见建议项 2 | source_engine.rs 逐行 |
| 10 | data URI 两分支语义一致：判定/解码同为 parser 单一真源（`is_data_uri`/`get_byte_array_if_data_uri`）；type 非空→hex、否则文本；失败均 `Internal("data: URI 内容解码失败")`；status 合成 200 | analyze_request.rs:78-107/144-152/179-188 vs web_book.rs:863-874/1025-1039 |
| 11 | 第三请求路径排查：书源面仅 4 条（fetch_page:1025、fetch_simple_cached:1120/1170、search.rs:1264→send_raw、dict_api.rs:407→send_text、explore_api.rs:501），全部已短路；rss_api.rs:220 直连（非书源规则面，见建议项 3）；webdav/backup 用户显式配置 http(s)；cover_api 无直连请求 | 全仓 `client.get/post` + `send_raw/send_text` 调用点逐一核对 |
| 12 | interrupted 可恢复：`reset_deadline` 每次 eval 前清 `interrupted` 标志（engine.rs:425）；同一实例后续 eval 正常 | engine.rs + tests/interrupted_message.rs:71-77（实际跑过） |
| 13 | FFI 签名零变化：`git diff 103ee2b0e5..HEAD -- rust/legado-ffi/src/bridge.rs` 为 0 行；无 `no_mangle`/`pub extern` 增删 | git diff |
| 14 | unsafe：本批 diff 中新增 `unsafe` 块 0 处 | `git diff | grep -c unsafe` = 0 |
| 15 | 测试真实执行：cargo test -p legado-js --features quickjs（lib 659 过 0 败 + 18 个集成目标全绿，含 host_api_array_arg 5 例、interrupted_message 3 例、jslib_failure_visible 5 例）；legado-ffi --features quickjs 全绿 0 败；legado-fetcher 95 过、legado-parser 320 过；flutter test **2212 全过**（本审查机实际执行） | 本次审查现场运行输出 |
| 16 | URL 双重编码风险：RhinoStr 仅做 JS ToString（字符串恒等），不做任何编码；encodeURI/encodeURIComponent 语义不变 | coerce.rs 实现 + tests/uri_component_coercion.rs 既有锁定 |

---

## 二、按严重程度分级的问题清单

### 阻塞（必须修）

无。四个提交均无确定性 Bug。

### 建议（应当修，合并前或紧随其后）

1. **[P1] `java.ajax(数组)` 与上游语义偏离（上游取首元素，我方 join(',')）**
   - 位置：rust/legado-js/src/host_api/quickjs_impl.rs:2588（`ajax` 注册为 `RhinoStr`）对照 app/src/main/java/io/legado/app/help/JsExtensions.kt:130-137（`ajax(url: Any)` 中 `if (url is List<*>) url.firstOrNull().toString()`）。
   - 症状：原版 Android 书源 `java.ajax([url1, url2])` 实际请求 url1；我方 RhinoStr 把数组 join 成 `"url1,url2"`，`network::ajax` 按「普通 URL」处理 → 请求无效 URL → 该调用失败。方向上不是"更宽容"，而是把原版可用的行为变成失败。
   - 为什么放建议级而非阻塞：传数组给 `ajax` 的书源极少（ajax 语义是单 URL）；且本批改前该形态直接抛转换错误，并未比改前更差——是"未完全对齐"而非回归。
   - 修法：给 `java.ajax` 加 JS 垫片（与 get/post 同款）：`Array.isArray(input) ? input[0] : input` 后再调原生；或在 coerce.rs/quickjs_impl.rs 文档登记该偏差并录入台账。

2. **[P2] `source_engine.rs` 路径 jsLib 失败仍静默，行为面不同步**
   - 位置：rust/legado-js/src/source_engine.rs:145（`let (pooled_engine, _js_lib_ok, main_js_status) = get_or_create(...)`，js_lib_ok 被丢弃）。
   - 症状：JS 源（JsSourceConfig）构造时 jsLib 求值失败只记台账、不报错，与 e73cf37d8f「失败带原因上抛」的统一口径不一致。提交信息只盘点 `validate_js_lib` 与 `QuickJsExecutor` 两处调用方。
   - 为什么放建议级：该路径 mainJs 状态仍驱动回评（错误语义与改前一致，无回归），且是否对 js_source 形态上抛属产品决策（原版 JsSource 与书源 jsLib 生命周期不同）。
   - 修法：二选一——对齐上抛；或在 source_engine.rs 注释明确豁免理由。

3. **[P2] `rss_api.rs:220` 直连 `client.get(&feed_url)` 无 data URI 短路**
   - 位置：rust/legado-ffi/src/api/rss.rs:220。
   - 症状：RSS 源 feedUrl 若为 data: URI 会报 reqwest builder error。但该值来自 rssSources.sourceUrl（源唯一标识），上游 RSS 源均为 http(s)，data: 形态不构成现实缺陷面。
   - 修法：登记豁免即可；如 RSS 源未来支持 `jsLib`/规则生成 feedUrl，再接入 `data_uri_content_of` 同款短路。

### 可选（可改进）

4. **[P2] 数值/布尔形参未做 Rhino 宽松转换（本批有意收窄，建议登记后续项）**
   - 位置：quickjs_impl.rs 中仍存 `Opt<i64>`/`Opt<i32>`/`i64`/`i32`/`Opt<bool>` 形参约 23 处（如 connect 的 `timeout_ms: Opt<i64>`、formatTime 的 `ts: i64`）。
   - 症状：Rhino LiveConnect 对 Java int/long/boolean 形参同样宽松（"5000"→5000、1→true）；JS 书源传字符串数字给 timeout 类参数在我方仍报转换错误。本批只收敛 String 面（commit 已声明），无回归，但属同一缺陷族的已知余量。
   - 修法：后续批用 `Coerced<i64>`/`Coerced<bool>` 收敛（rquickjs 已提供 JS 语义数值强转），并补矩阵测试。

5. **[P3] `hex_encode` 三处重复实现**
   - 位置：rust/legado-fetcher/src/analyze_request.rs:63、rust/legado-fetcher/src/web_book.rs:848（及 parser 侧既有实现）。
   - 建议：收敛到单一 util（行为已验证一致，纯工程整洁，不影响语义）。

6. **[P3] LooseStrList 元素级偏差确认（无需改码，仅存档）**
   - 元素 undefined→""（探针为 "undefined"）、元素 null→""（探针为 Java null→Kotlin NPE）：均为「比原版更宽容」方向、已写入 quickjs_impl.rs 文档，不会把原版可用书源变失败。审查确认接受。

---

## 三、重点项审查结论（对应任务书 P0 条目）

### P0-1 双结构分派边界 —— 通过
RhinoStr（标量 ToString）与 LooseStrList（数组→JSON 文本）边界清晰：LooseStrList 是 `FromJs` 私有结构、仅 `ajaxAll`/`ajaxTestAll` 两个上游 `Array<String>` 契约点使用；其余全部 RhinoStr/RhinoOptStr。无交叉套用。JSON 契约完好：数组→元素逐项 ToString→`serde_json::to_string` 保证合法 JSON（`unwrap_or_else "[]"` 兜底实际不可达）；null/undefined→空串→`network::ajax_all` 空输入分支返回 "[]"。上游 JsExtensions.kt:154/173 对照一致（除建议项 1 的 ajax 单独形）。

### P0-2 过度宽松风险 —— 通过（有一处登记级偏差）
RhinoStr = `Coerced<String>` = QuickJS `JS_ToString`，与探针表（数组 join、对象 "[object Object]"、自定义 toString、数字/布尔、undefined）完全一致——这正是 Rhino LiveConnect 的行为，**不是**过度宽松。对象 headers 的护栏由既有 JS 垫片承担（get/post/head/connect 均先 JSON.stringify）。唯一实质偏差 `java.ajax(数组)` 已列为建议项 1。

### P0-3 jsLib 上抛行为面 —— 通过
- 调用点盘点：executor.rs（fresh/缓存两路径）、validate_js_lib（js_executor.rs:280）、source_engine.rs:145（未同步，见建议项 2）。URL 映射形态改走 fresh 路径避免"映射 JSON 被 init_engine 误判失败"的放大——路由判断 `parse_js_lib_url_map` 与加载器实现在 jslib_loader.rs:59，逻辑自洽。
- 传导：searchUrl 链路经 `legado-js-error://` 编解码保真（web_book.rs:1558，error_class 仍 js_error），单源失败、App 不崩（js_executor.rs E2E 测试锁定）；直接 execute_js 调用方（pre_update/dict/web_book）均走 `Result<String,String>` → LegadoError，同为单源级失败。
- 缓存卡死：**不存在**。get_or_create 按 jsLib/setup/mainJs 内容逐字比对（engine_cache.rs:152-161），书源编辑修复 jsLib 后内容变化即重建引擎，重试可恢复。`js_lib_ok==Some(false)` 读台账 `last_jslib_error` 取当次构造刚登记的原因，无陈旧错因污染路径。

### P0-4 data URI 双分支 —— 通过（未发现第三条书源面路径）
- 两分支（fd04 搜索 send_raw/send_text 短路 vs ba8a explore `data_uri_content_of`）判定与解码同为 parser 单一真源，type 语义、错误文案、合成 status=200 全部一致；send_raw 原始字节（无损）比 from_utf8_lossy 更宽，方向正确。
- 全仓 `client.get/post` 直连点逐一核对：书源规则面 4 条路径全部短路覆盖；rss_api.rs:220 为唯一漏网点但不在书源规则面（建议项 3）；webdav/backup 为用户显式 http(s) 配置；cover_api 无直连请求。

### P0-5 interrupted 文案与可恢复性 —— 通过
文案保留 `interrupted` 关键字 + 可读中文 + 预算值取配置（非硬编码）；`reset_deadline` 每次 eval 前清中断标志（engine.rs:425），同一缓存引擎实例中断后继续服务后续请求，无全局状态残留（标志为引擎实例内 Arc<AtomicBool>，deadline 同理）。测试实际执行通过（含中断后恢复用例）。

### P1-6/7/8 —— 通过
URL 模板无双重编码（ToString 对字符串恒等）；FFI 导出面 0 变化（bridge.rs diff 0 行）；flutter 全量 2212 例本机实跑全绿。

### P2-9/10 —— 通过
FRB 无 codegen 面（FFI 未动）；coerce 矩阵经 host_api_array_arg.rs 8 形态 + 可空参 + 数组专用 5 例覆盖，三个新测试文件无命名冲突；新增 unsafe 0 处；RhinoOptStr 保持 NullStr/Opt 先例（null/undefined→None、可选 arity 经 FromParam::optional 保留），未破坏既有兼容先例。

---

## 四、局限与 non-claims

- flutter test 2212 全绿为本次审查 Windows 实机执行；未在 iOS 实机复测 5 个原始缺陷（1/2/3/11/15 号）——「实机修复」结论采纳提交内红绿记录 + 本地同形 E2E，**不升格为实机证明**。
- 未逐条审阅 599ceff71d 文档内容与 8156855288（不在范围）。
- 探针表（htmlunit-core-js 5.3.0-legado.4）为提交方声明并写入 coerce.rs，本次未重跑 JDK 探针，仅核对了 Rust 侧实现与该表的自洽性。

## 五、处置决定

**pass —— 可合并**（建议项 1-3 可合并后紧随修复或登记豁免；建议项 1 涉及"原版可用→我方失败"方向，建议排入下一批）。
