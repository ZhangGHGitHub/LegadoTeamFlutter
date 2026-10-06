# W4 数值/布尔形参宽松化批 独立代码审查报告

- 审查对象：`6e6fe62259` fix(js): 数值形参按 Rhino 语义宽松化（布尔经探针证伪保持严格）
- 审查代理：独立代码审查（只读，未改动被审代码；本报告为唯一新增文件）
- 审查日期：2026-10-06
- 审查方法：全量 diff 通读、166 case 探针输出逐行核对、rquickjs-core 0.12.2 源码核实、上游 Kotlin 签名逐一比对、独立补充 Rhino 边界探针实跑（i32/i64 边界）、先红后绿实测（临时回退旧实现跑新测试）、全量 cargo test 实跑

## 总体结论：通过（可合并），附 3 项 P2 建议登记

Summary: pass

无阻塞项（P0 空）。3 项 P2 均为窄侧边界/记载准确性问题，不影响本批「仅改探针证实的宽松方向」的核心正确性，可随后续批处理。

---

## P0 逐条核查结论

### 1. 探针证据真实性 —— 通过

- `docs/materials_rhino_probe_20261006/probe_numeric_output.txt`（745 行）经脚本解析：CASE 编号 1..166 **无缺漏、无越界编号**（166 个 `--- CASE n:` 标记齐全）。结构自洽：CASE 1-22 int / 23-44 long / 45-66 double（对照组）/ 67-88 Integer / 89-110 Long / 111-113 装箱边界 / 114-130 boolean / 131-148 Boolean / 149-160 ajax / 161-166 补充边界。
- JAR 哈希实测：md5 `28e9486663d87d96178c9b918df4b32f`、sha256 `d720f34285515025e4ccc80a5b92aed42cb26c03a7715ca53583d2c74ae51df7`，与 `docs/RHINO_STRING_PARAM_PROBE_20261006.md:31-32` 及 `third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/SOURCE.md:14-18` 记载**一致**。
- 探针材料三件 sha256（§9.2 表格记载）实测逐一吻合：
  - `RhinoNumericParamProbe.java` = `3f8a110e…28ae20`
  - `run_numeric_probe.sh` = `d414d498…f32a0f`
  - `probe_numeric_output.txt` = `80cb9c92…cf218e`
- 源码 + 运行脚本 + 原始输出全部入库，`run_numeric_probe.sh` 给出完整重跑命令（classpath 指向仓库内 JAR），**可复现**。探针源码 `RhinoNumericParamProbe.java:102-166` 的 case 清单与输出一一对应，无编造痕迹；输出文件为 GBK+CRLF（Windows JDK 17 控制台真实输出形态，与 `-encoding UTF-8` 编译源码、控制台 GBK 输出的组合吻合）。
- 代理自述的关键行逐一核对属实：`"5000"`→5000（CASE 2）、`"5000.7"`→5000（CASE 4）、`""`→0（CASE 12）、`" 42 "`→42（CASE 13）、`"0x10"`→16（CASE 165）、`[5000]`→5000（CASE 18）、自定义 toString→5000（CASE 162-163）、NaN/Infinity/越界抛错（CASE 15-16/21-22）、bool/undefined/null 抛错（CASE 7-10）、装箱只收 number（CASE 67-110）、null→Java null（CASE 76/98）、布尔全严格（CASE 114-148）、ajax `[]`/`[undefined]`/`[null]`→"null"（CASE 150-152）、`42`→"42.0"（CASE 155）。

### 2. 语义实现正确性（coerce.rs）—— 通过（附 P2-1 边界偏差）

`rust/legado-js/src/host_api/coerce.rs:148-177` `rhino_number_f64`：
- `bool`/`undefined`/`null` 显式抛错（:153-165）——与探针 CASE 7-10/29-32 同向。
- `Coerced<f64>`（= QuickJS `JS_ToFloat64` = JS 规范 ToNumber）：字符串数字/空白/十六进制/数组/自定义 toString 对象均转换——覆盖探针 CASE 2/4/12/13/14/18/162 全部宽松行。
- NaN/Infinity 显式拒绝（:167-175）——探针 CASE 15-16 同向。
- `RhinoInt` i32 范围校验（:188-196）：`5e9` 抛错（探针 CASE 21-22 同向）。
- `RhinoLong` i64 范围校验（:217-229）：下界含 `-2^63`、上界开区间 `2^63`——`i64::MAX` 本身不可被 f64 表示，开区间上界避免了 `2^63 as i64` 饱和回 `i64::MAX` 的假通过，写法正确。

**「rquickjs `i64::from_js` 把 NaN 静默转 0」声称核实：属实。**
`rquickjs-core-0.12.2/src/value/convert/from.rs:255` 宏展开 `f64: u32 u64 i64 usize isize` 臂：`i64::from_js` = `f64::from_js`（仅接受 Int/Float，字符串确实拒绝）→ `number_match_range(NaN, MIN, MAX)`（from.rs:143-155，`PartialOrd` 比较，`NaN < min` 与 `NaN > max` 均 false → 返回 Ok）→ `NaN as i64 = 0`。改前 `java.timeFormat(NaN)` 返回 `1970/01/01 08:00` 的链条成立。同源问题也影响 `i64::MAX as f64 = 2^63` 的上界饱和，新实现一并修正。

**Opt arity 核实**：`RhinoOptInt`/`RhinoOptLong` 实现 `FromParam` 且 `param_requirement() == optional()`（coerce.rs:249-266/280-297），`params.is_empty()` → `None`，少参考不报 arity 错误；测试 `optional_numeric_params_keep_arity_and_coerce_when_present`（base64 1 参调用、cache.put 2 参调用、webViewGetSource 5 参调用）实跑通过。

### 3. 8 个例外保持严格 —— 通过

全部核实为「注释登记 + 探针方向正确」，非漏改：

| 形参 | 位置 | 上游签名（已逐一比对） | 探针依据 |
|---|---|---|---|
| connect `timeout_ms` | quickjs_impl.rs:2721（注释 :2709-2710） | `callTimeout: Long?`（JsExtensions.kt:214，**装箱可空**） | CASE 68/90/103-104 |
| cache.get `only_disk` | :3742（注释 :3734） | `onlyDisk: Boolean`（CacheManager.kt:108） | CASE 133-142 |
| openVideoPlayer `is_float` | :4163（注释 :4156） | `isFloat: Boolean`（JsExtensions.kt:343） | CASE 116-125 |
| webViewGetSource `cache_first` | :4213（注释 :4199） | `cacheFirst: Boolean`（:271） | CASE 120-125 |
| webViewGetOverrideUrl `cache_first` | :4244（注释 :4231） | `cacheFirst: Boolean`（:306） | CASE 120-125 |
| startBrowserAwait `_refetch_after_success` | :4408（注释 :4399） | `refetchAfterSuccess: Boolean`（:368） | CASE 120-125 |
| queryTTF `use_cache` | :4666（注释 :4659） | `useCache: Boolean`（:1014） | CASE 116-125 |
| replaceFont `filter` | :4697（注释 :4687） | `filter: Boolean`（:1105） | CASE 116-125 |

### 4. 越界边界 —— 主方向通过，发现 P2-1 窄侧偏差

审查者用同一原版 JAR 独立跑了补充边界探针（不在本提交范围内）：

| 输入 | 原版 Rhino 实跑 | 本提交实现 |
|---|---|---|
| `int <- 2147483647.5` / `'2147483647.5'` | **接受 → 2147483647** | **抛错**（`2147483647.5 > 2147483647.0`） |
| `int <- -2147483648.5` | **接受 → -2147483648** | **抛错** |
| `int <- 2147483648` | 抛错 | 抛错（一致） |
| `long <- 9223372036854775295`（f64 实为 9223372036854774784） | 接受 → 9223372036854774784 | 接受 → 9223372036854774784（一致） |
| `long <- 9223372036854775807` / `'9223372036854775806'`（f64 均为 2^63） | 抛错 | 抛错（一致） |
| `long <- 1e300` | 抛错 | 抛错（一致） |

原版规则反推为「截断值落在目标范围内即接受」（开区间 `(−2^31−1, 2^31)`），实现的 i32 检查（:188）用了闭区间 `[i32::MIN, i32::MAX]`，在 `±2147483647.5` 型毫厘值上比原版窄。i64 侧因 f64 在 2^63 附近粒度为 2048，无可表示的中间值，实际无差异。详见 P2-1。

---

## P1 核查结论

### 5. 先红后绿 —— 通过（实测）

审查者将父提交 `6e6fe62259^` 的 `coerce.rs`/`quickjs_impl.rs` 临时放入工作树、保留新测试实跑：**4 红 2 绿**，失败信息与提交声称一致（`Error converting from js 'string' into type 'i32'/'f64'`；`java.timeFormat(NaN)` 在旧代码下不抛错——即 NaN 静默为 0 的既有偏差——`assert_err` 在 tests/host_api_numeric_arg.rs:52 处 panic）。恢复现版本后 6 绿。ajax 边界例与严格保持例在旧代码下即绿，合理（它们锁定的是既有/不得回退行为）。

断言质量：具体值断言（`"104"`、`"12"`、`"b"`、`"true"`、`"[flight:x]"`、`"[ERROR]"` 前缀），非空洞；负例覆盖 NaN/Infinity/1e30/"abc"/bool/null/undefined/i32 越界；`boxed_numeric_and_boolean_params_stay_strict` 锁定 8 个不得变宽形参。

### 6. 未换装数值形参清点 —— 通过

全量 grep 改后 `quickjs_impl.rs`：整型形参仅剩 `connect timeout_ms: Opt<i64>`（:2721，登记保持）；布尔 7 处 `Opt<bool>`（见第 3 节表）。**无遗漏**。18 个换装形参（flags、group、ts×2、sh、ms×2、i×5、save_time、wait_ms×2、delay_time×2、cacheFirst 外的其余）与提交清单一一吻合。

### 7. `java.ajax(42)` 标量偏差 —— 通过（仅登记，可接受）

原版 `"42.0"`（Java `Double.toString`）vs 我方 `"42"`（`RhinoStr`→JS ToString），已在文档 §9.2 D 表（docs/RHINO_STRING_PARAM_PROBE_20261006.md:547）与 §9.4 末（:596-598）登记「本次不改，仅登记」。标量数值 URL 形态罕见，不改决定合理。数组边界 `[]`/`[undefined]`/`[null]`→"null" 与 `AjaxUrlStr`（quickjs_impl.rs:139-155）实现一致并有测试锁定。

---

## P2 建议项（不阻塞合并）

### P2-1 i32 边界毫厘值窄侧偏差
- 位置：`rust/legado-js/src/host_api/coerce.rs:188`
- 症状：原版 `int` 形参收 `2147483647.5`（数学上 < 2^31，截断 = i32::MAX）接受；我方 `n > i32::MAX as f64` 抛错。同理 `-2147483648.5`。仅影响落在 `(i32::MAX, 2^31)` / `(-2^31-1, i32::MIN)` 开区间的浮点值（f64 在该处粒度约 2^-21，如 2147483647.5/2147483647.75）。
- 影响：极罕见输入上我方比原版严（原版可用的书源在我方失败），方向与「NaN 抛错」一致，风险低。
- 修法：i32 检查改为截断后必在范围的规则：`if !(n > -2147483649.0 && n < 2147483648.0)`（或 `n >= 2147483648.0 || n <= -2147483649.0` 时抛错）；i64 侧现有写法已等价正确，可保持。若采纳需补边界测试并注明审查依据（本报告补充探针）。

### P2-2 `callTimeout` 类型记载沿用了过时文档
- 位置：`docs/RHINO_STRING_PARAM_PROBE_20261006.md:581`（B 组表「`callTimeout: Int?`」）、`rust/legado-js/src/host_api/coerce.rs:64-65`（「connect 的 callTimeout: Int?」）、`rust/legado-js/src/host_api/quickjs_impl.rs:2709`（「可空 Int?」）
- 症状：上游实际代码 `app/src/main/java/io/legado/app/help/JsExtensions.kt:214` 为 `connect(urlStr: String, header: String?, callTimeout: Long?)`；`Int?` 出自 `app/src/main/assets/web/help/md/jsHelp.md:212` 的文档（该文档与代码不一致）。
- 影响：严格方向不受影响（装箱 Long 与装箱 Integer 探针同证严格，CASE 89-110），但证据链的引用源应指向代码而非文档。
- 修法：三处注释/表格把 `Int?` 更正为 `Long?`，引用 JsExtensions.kt:214。

### P2-3 `cache.put save_time` 范围口径比上游 Int 宽
- 位置：`rust/legado-js/src/host_api/quickjs_impl.rs:3635`（`save_time: RhinoOptLong`）
- 症状：上游 `CacheManager.put(key, value, saveTime: Int = 0)`（CacheManager.kt:60，原始 int）；原始 int 收 `5e9` 在原版抛错（探针 CASE 21），我方 `RhinoOptLong` 按 i64 校验会接受。
- 影响：`saveTime > i32::MAX` 秒（约 68 年）无业务意义，且属宽容侧偏差，实际风险趋零。
- 修法（可选）：改用 `RhinoOptInt`（cache_store::put 本就收 i64，`save_time.0.map(|v| v as i64)` 或直接在 `cache_store::put` 收 i32 上转型）；或维持现状并在 §9.4 登记此口径偏差。

---

## 提交卫生（P2-8）

- 7 文件与提交信息清单一致，无无关项混入；测试文件确为新增（父提交中不存在）。
- 文档 §9 表格与代码行为整体一致（除 P2-1/P2-2 两处）；coerce.rs 模块文档的数值/布尔转换表与探针逐行吻合。
- 门禁复跑：`cargo test -p legado-js --features quickjs` 全绿（合计 717 passed / 0 failed，含新文件 6 例）。提交信息所列 clippy/fmt/flutter test 门禁未在本审查中全部复跑（non-claim：仅声明 Rust 测试侧实测）。

## 证据分级与局限（non-claims）

- 探针证据等级：原版引擎 JAR 实跑（持久证据，可复现）+ 审查者独立补充边界探针实跑。
- 探针以普通 Java 宿主对象模拟 Kotlin 形参声明，未直接在真实 Android Kotlin 字节码上跑（文档 §9.5 已自我声明）；Kotlin 非空原始类型编译为 JVM 原始类型的等价性由 Kotlin 编译模型保证。
- 本审查未复跑 flutter test / clippy（non-claim）；未验证 iOS/Android 双端 FFI 行为（本批零 FFI 契约变更，风险面在 Rust 侧）。
- 「找不到方法」报错文案在我方表现为 FromJs 转换错误而非字面方法不存在，属实现层差异，抛错方向一致，不另计发现。

## 处置决定

leave_native（本报告以 docs/ 报告形式入库；3 项 P2 登记为后续批余量，不convert_to_check、不阻塞当前合并）。
