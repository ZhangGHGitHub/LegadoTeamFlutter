# Rhino 互操作详解调研（RHINO_INTEROP_ANALYSIS_20260920）

> 调研日期：2026-09-20。只读调研，不改代码。所有结论附文件:行号引用；「已确认」= 有代码/文档证据，「推测」= 需进一步验证。
> 素材：`modules/rhino`（上游 Rhino 沙箱）、`app/.../analyzeRule/AnalyzeRule.kt` + `model/jsSource/JsSourceEngine.kt`（上游调用链）、`rust/legado-js/src/host_api/**` + `rust/legado-ffi/src/js_executor.rs`（我方移植）、`docs/REFACTORING_ACTIVE_PLAN.md` P2-9 审计与 CHANGELOG。

---

## 1. Rhino 是什么，上游为何选它

### 1.1 Rhino 与 LiveConnect（已确认）

- Rhino 是纯 Java 实现的 JavaScript 引擎（Mozilla 起源，后归 Apache 基金会孵化），可嵌入 JVM/Android 进程，并允许 JS 直接 `new` 任意 Java 类、调用其实例/静态方法、访问静态字段——该跨语言能力称为 **LiveConnect**（通用背景知识，非本仓库证据）。
- 上游使用的不是原版 Rhino，而是 **vendored fork** `org.htmlunit:htmlunit-core-js:5.3.0-legado.4`：
  - `gradle/libs.versions.toml:62` `htmlunitCoreJs = "5.3.0-legado.4"`；`gradle/libs.versions.toml:206` `htmlunit-core-js = { module = "org.htmlunit:htmlunit-core-js", version.ref = "htmlunitCoreJs" }`
  - `modules/rhino/build.gradle:39` `api libs.htmlunit.core.js`
  - 旧版 `rhino-1.7.14.jar` 引用已注释：`modules/rhino/build.gradle:38` `// api(fileTree(dir: 'lib', include: ['rhino-1.7.14.jar']))`；jar 文件本身仍在磁盘：`modules/rhino/lib/rhino-1.7.14.jar`（1,442,544 字节，2026-07-30，已确认）。
- fork 版本后缀 `-legado.4`（已确认）：htmlunit-core-js 的定制分支（该 fork 内嵌并维护 Rhino 引擎），第 4 轮补丁。
- LiveConnect 在书源规则中的实际形态（已确认，证据在我方对照注释中）：
  - JS 经全局 `Packages` 对象引用 Java 包：`Packages.java.lang.String`、`Packages.android.util.Base64`、`new Packages.java.lang.String(bytes)` 等；我方模拟层注释枚举了真实命中面：`rust/legado-js/src/host_api/quickjs_impl.rs:122-139`（「Packages 全局模拟层……覆盖七猫四合一：java.lang.String / java.util.UUID|Arrays / android.util.Base64 / cn.hutool DigestUtil.md5Hex / javax.crypto Cipher」）。
  - **`java` 绑定 ≠ Java 包对象**：`java` 是 AnalyzeRule 实例本身（应用侧扩展方法面）：`app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt:895` `bindings["java"] = this`。因此 `java.ajax(...)`、`java.getStringList(...)`、`java.put(...)` 是应用方法；而 `java.lang.*` / `java.util.*` 不在 JsExtensions 方法面，走 LiveConnect 的 `Packages.java.*` 调真实 Java 标准库。我方对照注释同样确认这一边界：`rust/legado-js/src/host_api/quickjs_impl.rs:5181-5190`（「上游真值：Rhino LiveConnect 调真实 java.lang 方法（AnalyzeRule.kt L895 `bindings["java"] = this`；`java.lang` 不在 JsExtensions 字段面 → `Packages.java` classpath 设施，P2-9 ⑫ 类）」）。

### 1.2 上游为何选它（已确认 + 部分通用知识）

1. **Android 应用内没有可直接嵌入的 JS 引擎**（系统 V8 只经 WebView 桥暴露，无法作为进程内规则求值器，且没有 Java 互表面）——通用背景知识；结论：需要一个纯 Java、可打包进 APK 的引擎，且该引擎要能反向调 Java（LiveConnect）。Rhino 同时满足。
2. **书源语料依赖 Java 面**（已确认，详见第 3 节）：书源规则（searchRule / bookInfoRule / tocRule / contentRule 的 JS 规则，及 jsSource / jsLib）大量使用 `java.lang.*`、`java.util.*`、`android.util.Base64`、`cn.hutool`、`javax.crypto` 等 Java 类——只有 LiveConnect 型引擎能原生支持。
3. **上游为旧语料兼容性深度改造了引擎**（已确认，第 2 节给行号）：
   - `modules/rhino/src/main/java/com/script/rhino/RhinoContext.kt:143` `normalizeLegacySource`：对旧书源做 AST 重写，顶层/块级 `const/let` → `var`；L233 注释「旧书源会在块外读取 let/const；仅在同一执行层的未解析真实读取时恢复可见性」。
   - `modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt:306/309` 启用**上游自定义 feature**（标准 Rhino 没有，是 fork 加的）：`Context.FEATURE_LEGADO_DYNAMIC_DEFAULT_THIS`（非严格模式默认 `this = globalThis`）、`Context.FEATURE_LEGADO_DYNAMIC_EVAL_REALM`。
   - 这些改造的存在本身证明：选型 Rhino 的核心动因是**社区书源语料是按 Rhino 语义写成的**，引擎必须保持语义兼容。

### 1.3 我方移植要解决什么（承上启下，已确认）

我方跨平台核心是 Rust + QuickJS（rquickjs / quickjs-ng 0.8）：`rust/legado-ffi/src/js_executor.rs:629-779`（QuickJsExecutor，每次新引擎 / 按书源 LRU(8) 引擎池，64MB 内存上限）。Rust 进程内没有 JVM，书源 JS 的两类 Java 用法因此分裂成两条路径：

| 上游用法 | 本质 | 我方处理 |
|---|---|---|
| `java.ajax/get/put/...`（AnalyzeRule 实例方法） | 应用绑定，JS 只是调名 | 逐一移植为 Rust 宿主绑定，`mount_dual` 双挂 `java` 命名空间 + 裸全局（`rust/legado-js/src/host_api/register.rs:20-32`），详见第 4 节 |
| `Packages.*` / `new Java 类`（任意反射） | LiveConnect 真 JVM | 无法移植（无 JVM）：只能 (a) 针对已见类写 shim 模拟层（`quickjs_impl.rs:142-464`），或 (b) 明确放弃并登记「架构性限制」（`docs/REFACTORING_ACTIVE_PLAN.md:183` P2-9 ⑫），详见第 6 节 |

## 2. 上游引擎架构与沙箱

### 2.1 引擎调用链（AnalyzeRule / JsSourceEngine → RhinoScriptEngine）（已确认）

**(a) AnalyzeRule —— 规则求值入口（`java` = AnalyzeRule 实例）**
- `AnalyzeRule.kt:85` `scriptCache = hashMapOf<String, CompiledScript>()`（实例级 HashMap）。
- `AnalyzeRule.kt:893-932` `evalJS(jsStr, result)`：
  - L895-910 绑定全集：`java`(=this) / `cookie`(CookieStore) / `cache`(CacheManager) / `source` / `book` / `result` / `baseUrl` / `chapter` / `title`(=chapter?.title) / `src`(=content) / `nextChapterUrl` / `rssArticle` / `fromBookInfo`(=isFromBookInfo)，加 localBindings 的 `paraIndex` / `paraData` / `page`。
  - L912 `sharedGlobalStateKey = source?.getSharedGlobalStateKey()`（按书源隔离共享全局态的 key）。
  - L913-916 **topScope 三级回退**：`source?.getShareScope(coroutineContext)`（书源级共享作用域）→ `topScopeRef?.get()`（实例级 WeakReference）→ `SharedJsScope.getCryptoScope(source ?: this, coroutineContext)`（`app/src/main/java/io/legado/app/model/SharedJsScope.kt:74`，全局 crypto 共享态）。
  - L917-927：topScope 为 null 时 `newStandardTopLevel()` 新建 TopLevel 并 `chainTo(fresh)`；其中 L918 `if (evalJSCallCount++ > 16)` 才把新 scope 提升为 `topScopeRef = WeakReference(fresh)`（同一实例累计 >16 次 eval 后才缓存，防止短命实例无界累积）；topScope 非 null 时 `chainTo(topScope, sharedGlobalStateKey)`（链式挂到共享作用域，共享全局态按 key 隔离——隔离含义为推测：防止不同书源间变量串扰）。
  - L929-930 `compileScriptCache(jsStr).eval(scope, coroutineContext)`。
- L934-938 `compileScriptCache` = `scriptCache.getOrPutLimit(jsStr, 16) { RhinoScriptEngine.compile(jsStr) }`。
- `app/src/main/java/io/legado/app/utils/MapExtensions.kt:21-32` `getOrPutLimit`：仅 **miss 且 size < maxSize** 时才 put（实例缓存封顶 16 条；实例级无并发，无需同步）。

**(b) JsSourceEngine —— jsSource 引擎（每次调用隔离）**
- `JsSourceEngine.kt:82-104` `buildScope`：每次新建 ScriptBindings（并发隔离：同书源两次并发 jsSource 调用互不串变量）；L96 `?: SharedJsScope.getCryptoScope(source, ...)` 兜底。
- L108-115 companion 级 `scriptCache = LruCache<String, CompiledScript>(64)`（L110-111 注释原文：「getOrPutLimit(16)（实例私有，天然无并发问题）；这里选 androidx LruCache(64) 是因为 scriptCache 挂在 companion object 上，被所有 JsSourceEngine 实例/线程全局共享，16 格易挤爆」）。
- L118-119 编译缓存读写；L129-141 `normalizeJsResult`（Wrapper unwrap / Undefined→null / Scriptable→NativeJSON.stringify→GSON 回退）；L156-186 `stringifyScriptable`（临时 Context 复用执行闸门与协程取消）。

**(c) RhinoScriptEngine —— 单例引擎（`modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt`）**
- 类注释 L32：「allowScriptRun 闸门与协程取消检查——脚本只能经本引擎入口运行」。
- L43-77 `eval(js, bindingsConfig)`：L75 执行前 `cx.allowScriptRun = true`，L92 执行后 `false`（闸门窗口）；L84 `cx.compileWithCompatibility(source, sourceName, 1, scope)`。
- L100-145 `evalSuspend(js/scope)` 与 `evalSuspend(reader, scope)`：L105-143 捕获 `ContinuationPending` 循环（协程挂起通道，供挂起宿主方法使用）。
- L148-155 `newStandardTopLevel()`；L158-161 `getRuntimeScope`：`bindings.chainTo(newStandardTopLevel())`。
- L39-40 `sourceCache = LruCache<String, String>(256)`（编译缓存，androidx LruCache 自带同步，单例引擎共享）；L164-198 `compile(jsStr)` 产出 `RhinoCompiledScript`。
- L235-244 `unwrapReturnValue`：`Wrapper.unwrap` / `ConsString`→String / `Undefined`→null（JS 值归一为 Kotlin 值）。
- L285-358 `init`：
  - L294 `cx.instructionObserverThreshold = 10000`（指令级观察器：每 10000 条指令触发一次检查，协程取消/超时的载体）；
  - L295 `cx.maximumInterpreterStackDepth = 1000`（解释器栈深度上限）；
  - L299-312 `hasFeature`：E4X（XML）、`ENABLE_JAVA_MAP_ACCESS`、L306 `FEATURE_LEGADO_DYNAMIC_DEFAULT_THIS`（非严格模式默认 this=globalThis）、L309 `FEATURE_LEGADO_DYNAMIC_EVAL_REALM`（均为 fork 自定义 feature）；
  - 安装 `RhinoClassShutter`（class shutter）与 `RhinoWrapFactory`（wrap factory）；
  - 解释模式 + `VERSION_ES6`（ES6 解释执行）。
- L320-356 `doTopCall` 两重载：L351-352 `if (!cx.allowScriptRun) error("Not allow run script in unauthorized way.")`（绕过引擎入口直接驱动 Context 会失败）+ `ensureActive`（协程取消 → `RhinoInterruptError`）。

**(d) 编译/执行细节（RhinoContext 与辅助类）**
- `RhinoContext.kt:118-134` `compileWithCompatibility`：保存/恢复 `compatibilityScope`（L44-45 字段，L124-132），内部 L68/L98 调 `normalizeLegacySource`。
- `RhinoContext.kt:143-258` `normalizeLegacySource`：AST 重写顶层/块级 `const/let` → `var`；L233 注释「旧书源会在块外读取 let/const；仅在同一执行层的未解析真实读取时恢复可见性」。
- `RhinoContext.kt:337-343` `ensureActive()`：L339 `coroutineContext?.ensureActive()`（取消时抛出，对应 `RhinoErrors.kt:3` `RhinoInterruptError(cause)`）。
- `RhinoContext.kt:345-350` `checkRecursive()`：`recursiveCount >= 10` → 抛 `RhinoRecursionError`（`RhinoErrors.kt:5`，"Maximum recursion depth exceeded."）。
- `RhinoCompiledScript.kt:15` 类声明；L21 `eval(scope, coroutineContext)`；L45-66 `evalSuspend` + `ContinuationPending` 捕获循环。
- `RhinoExtensions.kt:30` `runScriptWithContext`（inline）/ L42-43（suspend 重载）；L55 当前线程绑定错误 Context 类型时抛「线程已绑定非 Rhino Context」。
- `ClassNameMatcher.kt:6-20`：类名精确/前缀匹配（shutter 的匹配引擎）。
- `JavaObjectWrapFactory.kt:6-8`：`fun interface`（自定义对象包装注册点）。
- `CollectionExtensions.kt:3` `fastBinarySearch`。

### 2.2 沙箱类逐个说明（防护目的 + 关键机制）（已确认）

1. **RhinoClassShutter.kt —— 类可见性黑名单（LiveConnect 防护核心）**
   - L49-121 `protectedClassNamesMatcher`（lazy 构建，基于 `ClassNameMatcher`）：约 70 条类名/前缀条目，代表项：
     - JVM 逃逸：`java.lang.{Class, ClassLoader, Runtime, ProcessBuilder}`、`java.lang.reflect.*`、`sun.misc.Unsafe`；
     - 文件系统：`java.io.File*`、`java.nio.file.*`；
     - 应用/Android 内部：`android.content.Intent`、`androidx.room.*` / sqlite、`io.legado.app.data.AppDatabase*` / dao、okio；
     - 第三方库逃逸：`cn.hutool` 反射/序列化类群；
     - 引擎/JDK 内部前缀：`com.script` / `org.mozilla` / `sun` / `libcore` / `dalvik`（防止 JS 直接操纵引擎自身与 JVM 内部）。
   - L123-125 `systemClassProtectedName = { load, loadLibrary, exit }`（System 类的危险静态方法名单，传入 `ProtectedNativeJavaClass`）。
   - L146-175 `visibleToScripts` 三重载（Any / 类名字符串 / Class）：类名命中 matcher 即对 JS 不可见。
   - L177-185 `wrapJavaClass`：`System` → `ProtectedNativeJavaClass`（保护壳，L180）；其余可见类走正常 wrap。
   - **防护目的**：收窄「JS 能 `new`/引用哪些 Java 类」的边界——正常业务类（如 jsoup `Elements`、加密类）可见，攻击面类完全不可见。
2. **RhinoWrapFactory.kt —— 包装工厂（Java 对象/类 → JS 包装对象）**
   - L53-86 `wrapAsJavaObject`：对象类对 shutter 不可见时 → **返回 null**（JS 侧表现为 undefined，而非报错）；L63-64 特例 `org.jsoup.select.Elements`（L123 常量）→ `CatchableNativeJavaList`（Elements 有数组语义，按下标 get）。
   - L88-100 `wrapJavaClass`：类不可见时 → L95 `NativeJavaPackage(javaClass.name, null)` **空包壳**（`new 不可见类`得到空对象而非硬错误，兼容旧语料容错习惯）；可见 → `RhinoClassShutter.wrapJavaClass`。
   - L117-121 `register(clazz, factory)`：注册自定义包装工厂（经 `JavaObjectWrapFactory`）。
3. **CatchableNativeJavaObject.kt —— 异常捕获包装（让 JS 能 try/catch Java 异常）**
   - L32-42 `catchJavaInvocation`：拦截 Java 异常（"Exception invoking " 前缀）→ `throwAsScriptRuntimeEx`（JS 侧可捕获的 `ScriptRuntimeEx`）。
   - L45-95 `CatchableNativeJavaList`：越界 `get` → **Undefined**（不抛 IndexOutOfBounds，宽容语义）；`append` / `ensureCapacity`。
   - L97-116 `CatchableNativeJavaMap`；L118-137 `CatchableNativeJavaArray`（同类宽容语义）。
   - L139-156 方法包装缓存（`wrappers[name]` 复用包装函数，避免重复包装）。
   - L158-184 `CatchableJavaFunction`（包装 Java 函数式对象）。
   - **防护目的**：Java 侧异常不再以「原生 Java 异常穿透 JS」形式出现，全部收敛为 JS 可 catch 的运行时异常，规则脚本可用 try/catch 兜底。
4. **ReadOnlyJavaObject.kt —— 只读对象视图**
   - L6 类声明；L9-17/L20 `has`/`get` 隐藏一切 `set*` 方法；L29-35 `put` 空操作。
   - **防护目的**：把 Java 对象只读暴露给 JS（JS 不能回写属性）。
5. **ProtectedNativeJavaClass.kt —— 受保护类壳（System 等）**
   - L10 `protectedName`（System 传入 `{load, loadLibrary, exit}`）；L19/L26/L39 `has`/`get`/`put` 过滤：被挡成员返回 Undefined/空操作；L47-49 `unwrap()` → `toString()`（阻止解包回原 System 对象，只给字符串表示）。
   - **防护目的**：`System` 类本身可见（旧语料可能引用）但危险静态方法被点名屏蔽。
6. **RhinoContext.kt —— 引擎 Context 扩展**：L41-45 字段 `allowScriptRun`(L42)/`recursiveCount`(L43)/`compatibilityScope`(L44-45)；L47-51 `initStandardObjects` 增加 E4X XML；`compileWithCompatibility`/`normalizeLegacySource`/`ensureActive`/`checkRecursive` 见 2.1(d)。
7. **RhinoErrors.kt / RhinoExtensions.kt / RhinoCompiledScript.kt / ClassNameMatcher.kt / JavaObjectWrapFactory.kt / CollectionExtensions.kt**：见 2.1(d)。

### 2.3 三级缓存与 scope 语义（已确认）

| 层 | 位置 | 数据结构 | 容量 | 并发语义 |
|---|---|---|---|---|
| 引擎编译缓存 | `RhinoScriptEngine.kt:39-40` `sourceCache` | androidx `LruCache` | 256 | 单例引擎共享，LruCache 自带同步 |
| 实例脚本缓存 | `AnalyzeRule.kt:85, 934-938` `scriptCache` | 实例 HashMap + `getOrPutLimit(16)` | 16 | 实例级私有，无并发（`MapExtensions.kt:21-32`） |
| jsSource 编译缓存 | `JsSourceEngine.kt:115` companion `scriptCache` | androidx `LruCache` | 64 | 全局共享（L110-111 注释：16 格易挤爆故选 64） |

scope 语义：
- 每次 `evalJS` 新建 `ScriptBindings`（调用级局部变量隔离）；
- topScope 三级回退（`AnalyzeRule.kt:913-916`）：书源级共享作用域 → 实例 WeakReference（`evalJSCallCount > 16` 后才提升，L918）→ 全局 crypto 作用域（`SharedJsScope.kt:74`）；
- `chainTo(topScope, sharedGlobalStateKey)`（L926）：共享全局态（crypto 等）跨实例/跨调用共享，但按 `getSharedGlobalStateKey()` 以书源为 key 隔离（隔离含义为推测：防止不同书源间全局变量串扰）。

## 3. 书源 JS 实际用到的 Java 面（实数）

> 数字来源分两类：**审计数字** = `docs/REFACTORING_ACTIVE_PLAN.md` P2-9 对照审计「526 源真实命中统计」（L176）；**自统计/代码注释** = 我方 `rust/` 代码注释与测试语料。两者口径不同，下表分别标注。

### 3.1 应用方法面（`java.*` = AnalyzeRule / JsSourceEngine 实例方法）（已确认，审计数字）

审计结论（`docs/REFACTORING_ACTIVE_PLAN.md:176`）：「20 组成对实验，14 组等价 / 0 处结构性偏差；526 源真实命中统计。**结论：不需要大修**，剩余 13 项偏差均可增量修补」。

| 缺口/方法面 | 用法处数/源数 | 后果（补前） | 状态（行号） |
|---|---|---|---|
| `java.getStringList` | 15 处 / 5 源 | **全部无守卫**（ReferenceError 致规则失败） | 已关闭 §196（L212，提交 `0fe222a3c8`） |
| `java.lang.*`（parse/toString 面） | 36 / 18 | 取值与 JDK 不一致 | 已关闭 §195 JDK 严格对齐（L211，提交 `d13d1a04e5`） |
| `java.setContent` | 13 / 7 | 规则失败 | ① 已落地（L176 历史记录） |
| 缓存内存三件套（cache.*） | 未单列 | 规则失败 | ① 已落地（L176） |
| `java.upLoginData` | 7 / 6 | 规则失败 | no-op 落地（L176） |
| `java.hexDecodeToByteArray` | 未单列 | 规则失败 | ① 已落地（L176） |
| 汇总「JS 宿主方法缺失」 | **~160 处用法 / 15–20 源** | — | 上行为 L177 条目 1 |
| `book` 绑定缺口 | 12–13 源 | `book.getVariable` 9 源（破坏性）；`book.bookUrl` 16 / `author` 11 / `name` 14 **静默空值** | L178 条目 2；P2-15 读桥已落地（`rust/legado-js/src/host_api/quickjs_impl.rs:1514-1566` `__lgBookVarSet/Del/Get` 等） |
| `java.put` ↔ `@get` 无桥 | 3 源（小米阅读/就去看网/手机小说） | 手机小说 `tocUrl` 取空回退 book_url → 目录页错 | L179 条目 3；2026-09-19 flow-scope 化桥关闭（L176） |
| `apply_put_map` 只取首值 | 4 源 | `@put:{y:#t@text##ab##XY}` 全损 | L180 条目 4（已关闭） |
| `%%` 定界 | 3 实现 / ~4 源 | 取值错位 | L181 条目 5（已关闭） |
| 登记项 6–13 | 多为 0–1 命中 | — | L182-183（含 ⑫ 见 3.3） |

### 3.2 Java 标准库面（LiveConnect / `Packages.*`）（已确认：命中清单来自我方 shim 注释与测试语料；处数/源数部分来自审计）

| Java 类/方法 | 书源 JS 中的用法形态 | 证据 |
|---|---|---|
| `java.lang.String`（`new String(bytes)`、`getBytes`） | 七猫 jsLib（587KB）：密文按 ISO-8859-1 探测解码 | CHANGELOG L2485；测试 `test_packages_java_string_new_bytes_returns_plaintext`（`quickjs_impl.rs:4012` 附近） |
| `java.lang.{Integer,Long,Double,Boolean}.parse*/toString` | 规则内数值解析/格式化（审计 36 处/18 源） | §195（L211）；测试 `test_packages_shim_lang_parse_strict_semantics` |
| `String.valueOf` | 七猫 jsLib | `quickjs_impl.rs:122-139` 注释 |
| `java.util.{UUID, Arrays, HashMap}` | 七猫等 7 源：upLoginData/请求头/评论偏好存储（JSHashMap 带 toJSON） | `quickjs_impl.rs:122-139, 204-225` 注释 |
| `java.util.zip.{Inflater, InflaterInputStream}` + `java.io.{ByteArrayInputStream, ByteArrayOutputStream}` + `java.nio.ByteBuffer` | zip/raw-deflate 解压（`wrInflateRaw` 委托 `java.inflateRawBytes`，flate2 实现） | `quickjs_impl.rs:122-139`；测试 `test_inflate_raw_bytes_and_zip_shim` |
| `android.util.Base64.decode/encodeToString` | 密文 Base64 编解码（P2-9 ⑫ 3 源，架构性限制） | `quickjs_impl.rs:438-441`（纯算法 shim，完整实现） |
| `cn.hutool.DigestUtil.md5Hex` 等 hutool 面 | 七猫 jsLib | `quickjs_impl.rs:442`（→ `java.md5Encode`） |
| `javax.crypto.Cipher`（AES-CBC/ECB） | 七猫 jsLib 密文解密 | `quickjs_impl.rs:443-461`（→ 新增 `java.aesDecryptBytes` 字节级实现 + `java.base64EncodeBytes`） |
| `org.jsoup.Jsoup.parse/select/attr/text/html` + `Elements` | 云霄小说/键盘小说/玄幻文学 searchUrl `@js:` 块（同时挂 `globalThis.org` 与 `Packages.org`） | JSOUP_BRIDGE_JS `quickjs_impl.rs:565-599`；上游特例 `RhinoWrapFactory.kt:123` |
| `Thread.sleep` / `System.currentTimeMillis` | 语料 8 命中（Thread.sleep） | `quickjs_impl.rs` 测试 `test_thread_sleep` 注释 |

### 3.3 架构性限制的 3 源（P2-9 ⑫）——具体源身份（推测/待验证）

审计原文（`docs/REFACTORING_ACTIVE_PLAN.md:183`）：「Rhino `Packages.*`/`android.util.Base64` 互操作（**3 源，架构性限制**）」——**未列源名**。与 L215 遗留登记「⑫ 类 Rhino LiveConnect 互操作维持架构限制」呼应。交叉 CHANGELOG 证据推断的 3 源（**源身份为推测，依据如下，需用户裁决确认**）：

1. **七猫（七猫小说四合一本地版）**——jsLib 587KB 依赖 `Packages`（AES 密文解密/Base64/MD5/UUID/String.getBytes），QuickJS 报 `Packages is not defined`（CHANGELOG L2485）。**已用 Packages 全局模拟层 + `java.aesDecryptBytes` 覆盖**（同 L2485），验证：CHANGELOG L2490 `cargo test legado-js` 485 全过。
2. **favcomic**——混淆 jsLib 依赖 Android Rhino 特有全局（`Packages` Java 桥、`decode` 等），QuickJS 无法完整执行（实测 `decode is not defined`）；jsLib 求值失败**降级为 eprintln 警告并继续**，正文规则不依赖 jsLib 的部分仍生效（favcomic 正文 2966B 图片列表恢复）（CHANGELOG L3179）；站点图片解密另由 `image_api` + `eval_bytes` 独立实现（L3188）。**当前为「已文档化降级」**。
3. **书山 或 番茄（聚合源，二选一/或两个都算——待验证）**——聚合源发现分类 ERROR 根治：① JS 引擎改非严格模式（书山 jsLib `let {source}=this`）；② jsLib 加载经 `sanitize_js_lib_for_quickjs` 预处理（移除 Rhino `importClass`/`Packages` 行）后完整加载（CHANGELOG L2597；实现 `rust/legado-ffi/src/api/source_js_bindings.rs:105`，测试 `test_sanitize_js_lib_keeps_functions_after_packages` L481 附近）。**已由 sanitize + 非严格模式对齐覆盖**。

### 3.4 统计口径说明（已确认）

- 3.1 全部处数/源数来自 **526 源真实命中统计**（审计口径，L176）。**逐源明细文件未在仓库找到**：`.tmp/` 仅有 `r1_sources.json`（本地 127.0.0.1 R1VA 测试源）、`source_1270.json`（代理书源🌍语料）及大量 UI 调试产物，无七猫/书山/番茄/favcomic 完整 jsLib 或书源规则 dump → 无法独立复算处数，本文以审计数字为准。
- 代码注释中列出的「已知命中源」（51漫画/Nhentai/快看/包子漫画/云霄/键盘/玄幻/天涯书库/新笔趣阁/新落秋/笔趣阁zdzn/天悦小说/松鹤/七猫/书山/番茄/favcomic/懒人听书/就去看网/小米阅读/手机小说等）来自测试语料与修复记录（CHANGELOG），是**已知命中子集**，不是 526 源全集统计。
- 自统计：`mount_dual` 调用点 138 处（`rust/legado-js/src/host_api/quickjs_impl.rs` 内，已确认 `grep -c`），即宿主方法面约 135+ 个（含 `java` 命名空间 + 裸全局双挂，`register.rs:20-32`）。

## 4. 我方移植现状（host_api 覆盖清单 + 与上游逐点差异表）

### 4.1 总体架构（已确认）

| 层 | 位置 | 职责 |
|---|---|---|
| 宿主方法面 | `rust/legado-js/src/host_api/quickjs_impl.rs`（单文件 5000+ 行） | 全部 `java.*` 宿主方法与 Packages shim；`mount_dual`（`register.rs:20-32`）把同一函数**同时**挂到 `java` 命名空间与裸全局（如 `java.getString` 与 `getString`），调用点 **138 处**（自统计 `grep -c`） |
| 规则解析/求值 | `rust/legado-js/src/host_api/html_parse.rs` | CSS 链式选择（L42-196）、单步分派 `dispatch_rule` 镜像上游（L200-260）、正则多级 `&&`（L262-281）、嵌套 `@js:`/`@webjs:` 求值 `eval_js_nested_typed`（L283-428，§196 函数体求值优先 `new Function(code)()` + 表达式回退，L311-318） |
| 引擎宿主 | `rust/legado-ffi/src/js_executor.rs`（1338 行） | QuickJsExecutor：64MB 内存上限、engine_cache 按源 LRU(8)、jsLib sanitize/降级、登录/搜索/发现求值入口 |
| jsLib 预处理 | `rust/legado-ffi/src/api/source_js_bindings.rs:105` `sanitize_js_lib_for_quickjs` | 移除 jsLib 中 Rhino `importClass`/`Packages` 行后注入 QuickJS（使用点 `explore_api.rs:560/1263/1352`；测试 `test_sanitize_js_lib_keeps_functions_after_packages` 同文件 L481 附近） |

### 4.2 覆盖清单（方法 + 语义 + 测试名）

**A. 应用方法面（`java.*`，对齐 AnalyzeRule/JsSourceEngine 实例面）**

| 方法 | 语义（上游对齐点） | 位置 | 测试名 |
|---|---|---|---|
| `java.getString(str, key)` 分派族 | ① JSON 键值 ② `key:value` ③ 单值回退；P2-6(e) 松鹤真实模板 | `quickjs_impl.rs:4681-4773`（L4766-4773） | `test_p26e_*` |
| `java.getStringList(str, key)` | 对齐上游 `AnalyzeRule.kt:202-292`（§196 根因修复：顶层 return 函数体优先求值） | `quickjs_impl.rs:2283-2326`（L2313-2315 注释引上游 L202-293） | getStringList 分派测试（§196 提交 `0fe222a3c8`） |
| `java.put` / `cache.put` | P2-9 ③ flow-scope 化：`java.put` 值可被 `@get` 读到 | `quickjs_impl.rs:1407-1435`、`2493` | `test_java_put_visible_to_analyze_rule_get` |
| `java.upLoginData` | no-op（上游 7 处/6 源命中） | `quickjs_impl.rs`（① 已落地，L176 历史记录） | `test_up_login_data_noop` |
| `java.hexDecodeToByteArray` / `setContent` | ① 已落地（CHANGELOG L176 历史） | `quickjs_impl.rs` | 含在 `cargo test legado-js` 485 全过（CHANGELOG L2490） |
| `book` 绑定桥 | `__lgBookVarSet L1518`、`__lgBookVarDel L1531`、`__lgBookVarGet L1538`（P2-15 读桥）、`__lgBookSetType L1550`、`__lgBookSetReverseToc L1557`；桥缺失时**静默退化、写路径永不阻断规则求值**（L1508-1512 降级注释：就去看网 `book.putVariable`→`java.get` 闭环） | `quickjs_impl.rs:1505-1566` | `test_p215_book_var_get_bridge_roundtrip` |

**B. LiveConnect / `Packages.*` shim（`quickjs_impl.rs:142-464`，L122-139 注释为七猫四合一覆盖清单）**

| Java 面 | shim 语义 | 位置 | 测试名 |
|---|---|---|---|
| `java.lang.String(bytes)` / `getBytes` | 字节↔串（ISO-8859-1 明文探测） | L142-159（L159 `[object Object]` 注释） | `test_packages_java_string_new_bytes_returns_plaintext`（L4012） |
| `java.lang.{Integer,Long,Double,Boolean}` parse 族 + `String.valueOf` | **JDK 严格 parse 语义**（§195；L5181-5190 注释：上游真值 = Rhino LiveConnect 调真实 java.lang，`java.lang` 不在 JsExtensions 字段面，属 P2-9 ⑫ 类） | L142-464 区段 | `test_packages_shim_lang_parse_strict_semantics` |
| `java.util.{UUID,Arrays,HashMap}` | JSHashMap（7 源命中，带 `toJSON`） | L204-225 | `test_packages_shim_lang_util` |
| `java.util.zip.Inflater(InflaterInputStream)` + `java.io.{ByteArrayInput,ByteArrayOutput}Stream` + `java.nio.ByteBuffer` | `wrInflateRaw` 委托 `java.inflateRawBytes`（flate2 纯算法）；JSInflater noWrap 场景**已文档化降级** | L266-272 及区段 | `test_inflate_raw_bytes_and_zip_shim` |
| `android.util.Base64.decode/encodeToString` | 纯算法完整实现（非 Android 真类） | L438-441 | Base64 相关测试 |
| `cn.hutool.DigestUtil.md5Hex` | API 替换 → `java.md5Encode` | L442 | — |
| `javax.crypto.Cipher`（AES-CBC/ECB） | API 替换 → 新增 `java.aesDecryptBytes`（字节级）+ `java.base64EncodeBytes` | L443-461 | aes 相关测试 |
| `Thread.sleep` / `System.currentTimeMillis` | 语料 8 命中 | 区段内 | `test_thread_sleep` |
| `org.jsoup.Jsoup.{parse,select,attr,text,html}` + `Elements` | JSOUP_BRIDGE_JS 双挂 `globalThis.org` 与 `Packages.org`（云霄/键盘/玄幻文学） | L565-649 | jsoup 相关测试 |
| `Packages` 根对象 | `globalThis.Packages = { java: { lang, util, io, nio } }` 模拟层（L301+） | L142-464 | `test_packages_shim_*` |

**C. 响应/编码面**

| 面 | 语义 | 位置 | 测试名 |
|---|---|---|---|
| `java.connect`（RESPONSE_BRIDGE_JS） | 全参数连接；post/head **302 拦截对齐上游 `followRedirects(false)`** | L480-559（L522-538 参数、L550-557 302） | `test_response_bridge_post_location` |
| 编码 API 族 | `register_encoding_apis`（hex/base64 等） | L604-649 | — |
| 双挂语义 | 同一函数 `java.*` 与裸全局同义（`mount_dual`） | `register.rs:20-32` | `test_bare_global_still_works`、`test_java_and_bare_produce_same_result` |

**D. 引擎宿主层（`js_executor.rs`）**

| 机制 | 行为 | 位置 |
|---|---|---|
| 内存上限 | 64MB（防 jsLib/规则跑飞） | L678-745 |
| jsLib 求值失败 | `check_syntax` → `jslib_normalize::normalize` 重试 → 仍失败 **eprintln 警告并继续**（favcomic 场景，CHANGELOG L3179 决策） | L678-745 |
| lexical redeclaration | hash-set 检测后回落新引擎 | L747-749、L769-777 |
| engine_cache | key=`executor:{source_tag}`，LRU cap 8（1084µs→2µs，-99.8%，587KB jsLib 只 eval 一次，CHANGELOG L2354） | L750-768 |
| 登录检查 | `execute_login_check_js`（L123-167）；`execute_login_check_response` `CastFailed` 对齐 `ClassCastException`（L231-313） | 同左 |
| 搜索 URL | `@js:`/`<js>` 主模板失败**拒绝字面回退** → `legado-js-error://search?e=` 占位（L395-414） | L342-433 |
| 发现 URL | JS 失败**上抛真实错误**（懒人听书） | L454-497（L476-488） |

### 4.3 与上游逐点差异（等价 / 近似 / 缺失）

| 上游行为（Rhino/LiveConnect） | 我方现状 | 档位 |
|---|---|---|
| `java.getStringList` 全套（AnalyzeRule.kt:202-292） | 逐分支对齐 + 顶层 return 根因修复（§196） | **等价** |
| `java.lang.*` 标准 parse 语义 | §195 JDK 严格对齐（含 `Integer.parseInt` 前导 `+`/十六进制等边缘） | **等价** |
| jsoup `Elements` 特例包装（`RhinoWrapFactory.kt:123` → `CatchableNativeJavaList`） | JSOUP_BRIDGE_JS 等价面 + CSS 链式选择镜像（上游越界宽容 → 我方 undefined 回退，属有意差异） | **等价** |
| 响应 302/`followRedirects(false)` | RESPONSE_BRIDGE 302 拦截对齐 | **等价** |
| 非严格 this=globalThis（书山 `let {source}=this`） | 引擎非严格模式对齐（CHANGELOG L2597） | **等价** |
| `android.util.Base64`（Android 真类） | 纯算法 shim，输入输出语义一致但非真类、无 `NO_WRAP` 等全常量 | **近似** |
| `cn.hutool.DigestUtil` / `javax.crypto.Cipher` 真类调用 | API 替换为 `java.md5Encode` / `java.aesDecryptBytes`（仅覆盖语料命中用法，未覆盖其他成员） | **近似** |
| `java.util.zip` 真流式解压 | flate2 纯算法等价（raw/zip）；JSInflater noWrap 场景**已文档化降级** | **近似** |
| `Thread.sleep` 真阻塞 | shim 版（语料 8 命中） | **近似** |
| `Packages.*` 任意反射（`new` 任意 Java 类、任意方法） | **仅 shim 已登记的类/方法面**；未登记 Java 类一律不可用 | **缺失（架构性，P2-9 ⑫）** |
| `java.lang.*` classpath 任意成员（超出 parse 族/valueOf） | 不可用（L5181-5190 注释） | **缺失（架构性）** |
| favcomic 混淆 jsLib 的 `decode` 等 Rhino 特有全局 | 求值失败 eprintln 降级继续（正文非 jsLib 部分仍生效；图片解密走 `image_api` 独立实现，L3188） | **缺失→已文档化降级** |
| 协程取消 → `RhinoInterruptError` 中断（`RhinoContext.kt`） | QuickJS 无协程；引擎级取消/中断面与上游不等价（引擎行为差异，非方法面缺口） | **近似/架构差异** |

## 5. 缺口与涉事源（3 源）

> 对应 P2-9 ⑫「Rhino `Packages.*`/`android.util.Base64` 互操作（3 源，架构性限制）」（`docs/REFACTORING_ACTIVE_PLAN.md:183`，登记 L215）。审计**未列源名**，以下 3 源身份由 CHANGELOG 交叉推断（**推测/待验证**，需用户裁决确认）。规则片段细节：仓库 `.tmp/` 无这 3 源的 jsLib/规则 dump（仅 `r1_sources.json`、`source_1270.json` 及测试产物），片段以 CHANGELOG 原文引用为准。

### 5.1 七猫（七猫小说四合一本地版）——**已被 shim 完整覆盖（等价）**

| 项 | 内容 |
|---|---|
| 依赖 Java 面 | jsLib **587KB** 依赖 `Packages`：AES 密文解密（`javax.crypto`）、`android.util.Base64`、MD5（`cn.hutool.DigestUtil`）、`java.util.UUID`、`String.getBytes`（CHANGELOG L2485） |
| 规则片段 | 无 dump；CHANGELOG 原文：「jsLib(587KB) 依赖 Packages（AES 密文解密/Base64/MD5/UUID/String.getBytes）」 |
| 新引擎下后果（补 shim 前） | **报错**：QuickJS 报 `Packages is not defined` → jsLib 求值失败 → 依赖 jsLib 的搜索/正文规则整体失败 |
| 现状 | **已覆盖**：注入 `Packages` 全局模拟层 + 新增 `java.aesDecryptBytes`（AES-CBC/ECB）+ `java.base64EncodeBytes`（CHANGELOG L2485；实现 `quickjs_impl.rs:142-464`，含 L438-441 Base64、L442 hutool→`java.md5Encode`、L443-461 Cipher→`java.aesDecryptBytes`） |
| 可复现判断依据 | 有：`cargo test legado-js` 485 全过（CHANGELOG L2490），含 `test_packages_java_string_new_bytes_returns_plaintext`（`quickjs_impl.rs:4012` 附近）、`test_inflate_raw_bytes_and_zip_shim`、`test_packages_shim_lang_util`；真实端到端验证需 587KB jsLib 语料（仓库未存放，**待验证**） |

### 5.2 favcomic——**已文档化降级（降级）**

| 项 | 内容 |
|---|---|
| 依赖 Java 面 | 混淆 jsLib 依赖 Android Rhino 特有全局（`Packages` Java 桥、`decode` 等）；站点图片 XOR 解码 |
| 规则片段 | 无 dump；CHANGELOG 原文：实测 `decode is not defined`（CHANGELOG L3179） |
| 新引擎下后果（现状即后果） | **降级**：jsLib 求值失败 → eprintln 警告并继续（v2.0.19 曾改为报错阻断导致全局回归，后修复为降级，L3179）；正文规则不依赖 jsLib 的部分仍生效（favcomic 正文 2966B 图片列表恢复）；图片解密改走 Rust `image_api` + `eval_bytes` Uint8Array 注入（L3188） |
| 可复现判断依据 | 有：CHANGELOG L3179 记录了「正文 2966B 图片列表恢复」的实测；jsLib 失败路径在 `js_executor.rs:678-745`（eprintln 降级分支）可复现触发 |

### 5.3 书山 或 番茄（聚合源）——**已被 sanitize + 非严格模式覆盖（等价）**

| 项 | 内容 |
|---|---|
| 依赖 Java 面 | jsLib 含 Rhino `importClass`/`Packages` 行；书山 jsLib 顶部 `let {source}=this`（依赖 Rhino 非严格 this=globalThis 语义） |
| 规则片段 | CHANGELOG 原文：「书山 jsLib `let {source}=this` 报 Cannot convert」（CHANGELOG L2597）——这是仓库中唯一有原文片段的 ⑫ 源 |
| 新引擎下后果（补前） | **报错**：书山聚合源发现分类 ERROR——非严格 this 语义缺失 → `let {source}=this` 转参失败；jsLib 含 `importClass`/`Packages` 行 → 语法/未定义错误 |
| 现状 | **已覆盖**：① JS 引擎 eval 改非严格模式（对齐 Rhino this=globalThis）② jsLib 经 `sanitize_js_lib_for_quickjs`（`source_js_bindings.rs:105`）移除 Rhino 行后完整加载 ③ exploreUrl 经 Function 参数执行（CHANGELOG L2597） |
| 可复现判断依据 | 有：`test_sanitize_js_lib_keeps_functions_after_packages`（`source_js_bindings.rs:481` 附近）；使用点 `explore_api.rs:560/1263/1352` |

### 5.4 后果分档汇总

| 源 | 新引擎下后果分档 | 依据 |
|---|---|---|
| 七猫 | 报错（补 shim 前）→ **已等价** | L2485 错误原文 + 485 测试全过 |
| favcomic | **降级**（静默 eprintln，功能部分可用） | L3179 实测记录 |
| 书山/番茄 | 报错（补前）→ **已等价** | L2597 修复记录 |

> 静默空值风险不在 ⑫ 3 源内，而在 P2-9 条目 2（`book.bookUrl` 16 / `author` 11 / `name` 14 静默空值，L178，12–13 源）——P2-15 读桥已落地（`quickjs_impl.rs:1538` `__lgBookVarGet`），属「静默空值→读桥回填」的已关闭项。

## 6. 口径选项分析（a/b/c/d，工作量/风险/覆盖度三列）

| 口径 | 工作量 | 风险 | 覆盖度 |
|---|---|---|---|
| **(a) JS shim 补齐**（现状主路径：语料命中 → 登记类/方法面 → 纯 Rust/JS 实现 + 测试） | **中**。增量式：单条 shim + 测试约 0.5–2 天（参照 §195/§196 与 ① 已落地的节奏，CHANGELOG L176 历史记录）。纯算法类（`android.util.Base64`）可**完整实现**（已做，`quickjs_impl.rs:438-441`）；API 替换类（hutool→`md5Encode`、Cipher→`aesDecryptBytes`）工作量低但需按命中用法枚举；**`Packages.*` 任意反射不可补齐**（无法枚举任意 Java 类/方法，shim 只能登记已知面） | **低**。shim 全在 QuickJS/Rust 侧，不动引擎语义；主要风险点是 API 替换类 shim 在边缘用法上与真类语义漂移（如 `Base64.NO_WRAP` 常量族、hutool 其他成员）——用「命中语料 + 测试锁语义」管控，漂移即测试红 | **语料内 ≈100%，语料外不可保证**。526 源审计 0 处结构性偏差（L176）→ 已知命中面全部可 shim；未登记的任意 Java 类长尾 = 0 覆盖（但 526 源语料内命中 0，见 3.1） |
| **(b) 明确放弃**（3 源标记不支持 + 文档登记） | **极低**：几行文档 + 源标记（沿用 L215 遗留登记机制） | **低**（无代码改动）；但**对 ⑫ 3 源是错误口径**：七猫/书山(番茄) 已 shim/sanitize 等价覆盖，放弃即回退已修复功能；仅对「任意反射长尾」有意义 | **低**：3 源中 1 源（favcomic）本就放弃到降级，另 2 源放弃 = 功能回退 |
| **(c) 引擎级 Java 桥**（跨平台 Rust 核心嵌 JVM 或 LiveConnect 等价物） | **高 / 基本不可行**。Rust 核心（`rust/legado-core` 等）是跨平台纯 native 产物，嵌 JVM = 每平台打包 JRE + JNI 层，工作量=重写一个 LiveConnect；**唯一真实边界**：FFI 回调桩——JS 经现有 FFI 通道调 Rust 侧「Java 类桩服务」，但这**就是 (a) shim 路线的工程化**（桩=登记的类/方法），拿不到「任意 Java 类」能力，因为最终仍是 Rust 实现类语义 | **高**：引入 JVM 依赖破坏跨平台纯 native 打包（Android/iOS/桌面/CI 全链路），与项目「跨平台 Rust 核心」架构决策冲突 | 理论 100%，但**代价是放弃跨平台纯 native**——覆盖度收益与成本不成比例 |
| **(d) 逐源降级**（best-effort + 明确错误文案，参照 favcomic 模式 `js_executor.rs:678-745`） | **中**：每源加「该源依赖 Rhino 互操作、功能受限」明确文案 + 文档（参照 L3179 决策路径） | **低-中**：不阻断、可预期；风险是降级文案若不够明确 → 用户误以为源坏了（需文案写清「受限功能清单」） | **部分**：best-effort 可用部分保留，失败部分从「静默空值/静默降级」升级为**明确报错文案**——把静默风险转成显性风险 |

## 7. 建议（推荐口径 + 理由 + 补 shim 覆盖比例量化估计）

### 7.1 推荐口径

**(a)+(d) 组合，维持 P2-9 ⑫ 架构限制登记**：
1. **shim 增量补齐（a）作为主路径**：任何新语料命中的 Java 面走「登记 → 纯 Rust/JS 实现 → 测试锁语义」流水线（现有 ①~⑤、§195、§196、P2-15 均此节奏，L176）；
2. **逐源明确文案（d）兜底**：favcomic 类「已降级」源在源详情/错误处附**受限功能清单**（明确文案，非静默），新增降级源必须登记；
3. **任意反射长尾 = 登记而非实现**：维持 L215「⑫ 类 Rhino LiveConnect 互操作维持架构限制」，新源若用到未登记 Java 类 → 明确报错文案（指明依赖类名）+ 登记，**不建 (c) JVM 桥**；
4. (b) 仅用于「确认永久不支持且无降级方案」的源，当前 ⑫ 3 源均不适用（2 源已等价、1 源已降级）。

**一句理由**：526 源审计 0 处结构性偏差证明已知命中面 100% 可 shim 覆盖，而任意反射长尾在语料内 0 命中——为 0 命中的长尾引入 JVM 破坏跨平台纯 native 架构（c 不可行），对已覆盖的 2 源明确放弃（b）则是回退，故「shim 补齐 + 明确降级文案 + 登记限制」是唯一成本-收益匹配的口径。

### 7.2 「补 shim 能覆盖多少用法比例」量化估计

以 P2-9 审计 526 源真实命中为分母（L176）：

| 用法面 | 命中量 | 状态 | 覆盖 |
|---|---|---|---|
| 应用方法面（①~⑤ 类） | ~160 处 / 15–20 源 | 全部已关闭（①②③④⑤ 2026-09-19 关闭，L176；P2-15 读桥、flow-scope `java.put` 桥已落地） | **100%** |
| `java.lang.*` parse/valueOf 面 | 36 处 / 18 源 | §195 已关闭（`d13d1a04e5`） | **100%** |
| ⑫ LiveConnect 已知面（Base64/zip/io/nio/jsoup/Thread.sleep/UUID/hutool/Cipher/String 字节） | ⑫ 3 源 + 语料 8 命中（Thread.sleep）等 | 2 源等价（七猫、书山/番茄）+ 1 源降级（favcomic） | 源维度 **2/3 等价 + 1/3 降级**；用法维度 ≈100%（已知命中全有 shim/替代实现） |
| 任意反射长尾（未登记 Java 类） | **526 源语料内 0 命中**（0 处结构性偏差的反面证据） | 登记架构限制（L215） | 语料内 **N/A（无需求）**；语料外不可保证 |

**结论**：在 526 源语料内，shim 路线（含已落地 + 登记）对**全部已知 Java 面用法覆盖 ≈100%**，剩余不可覆盖部分在语料内命中为 0。量化边界：该 100% 是「语料内」口径——新源若使用未登记 Java 类则回落为明确报错 + 登记，这是架构限制的固有边界，而非 shim 能力缺口。

### 7.3 需用户裁决点

1. **⑫「3 源」身份确认**：本文推断为 七猫 / favcomic / 书山或番茄（L183 审计未列源名，CHANGELOG 交叉推断，标注推测）；
2. **favcomic 降级口径**：维持 eprintln 静默降级，还是升级为 7.1-2 的明确受限文案（建议升级）；
3. **书山/番茄是否算 2 个源**：若 ⑫「3 源」实为 七猫/favcomic/书山/番茄 中的 3 个，需按源名修正 5.3；
4. **(c) FFI 回调桩是否立项**：本文判定其 = (a) 的工程化、无增量收益，默认不立项（若未来出现「同一 Java 类被 >N 个新源命中且 shim 维护成本 > 桩服务成本」再议，建议 N=3）。

---

## 8. 实测统计（2026-09-20，用户提供最新书源合集）

**语料**：`https://www.yckceo.com/yuedu/shuyuans/json/id/1283.json`（2026-09-20 抓取，**916 个书源**，6.69MB，落 `.tmp/corpus/` 不入库）。本节数字为**实测**，取代 §3.3 的推测。

### 8.1 Java 互操作面（按"全字段含 jsLib" / "仅 jsLib 内"两种口径）
| 模式 | 全字段命中源数 | 仅 jsLib 命中源数 |
|---|---|---|
| `Packages.` | 22 | 10 |
| `importClass(` | **0** | **0** |
| `Java.type(` | **0** | **0** |
| `android.util.Base64` | 4 | 3 |
| `java.lang.` | 11 | 8 |
| `java.util.` | 5 | 4 |
| `javax.crypto` | 8 | 5 |
| `cn.hutool` | 4 | 4 |

**jsLib 内用到 Java 面的源并集 = 11 个**：🏷七猫四合一本地版（及其同人版）、🏷七猫小说·API、⚡📂得间免费小说、🏷微信读书二合一本地源、🏷长佩文学、🏷阅文集团、📂酷狗小说、🔊听友M、🔞Linpx、🔞兽人小说站。
**结论（对口径的直接影响）**：`importClass` 与 `Java.type` 在现网语料中 **0 命中** → 需要"任意 Java 反射"这一能力面的源**不存在**；实际需求集中在**具名类/方法的语义复刻**（Base64、javax.crypto、java.lang/java.util、hutool 几处），与 §6 建议的 (a) shim 路线完全吻合。

### 8.2 涉事源的现状（订正 §3.3 推断）
| 源 | 合集内条数 | jsLib 体积 | 说明 |
|---|---|---|---|
| 七猫 | **4** | 「四合一本地版」及其同人版均 **588,700 B**；「小说·API」12,195 B；「短剧」0 | 审计记的"587KB jsLib"即此，已导出 `.tmp/corpus/qimao_jslib.js`（1359 行） |
| favcomic | **1**（🎨🔞（favcomic）喜漫漫画） | 16,184 B | 仍在 |
| **书山 / 番茄** | **0 / 0** | — | **已从现网合集消失**（用户确认：失效后删除）→ §3.3 把它列为第三源属**推断过时**，本书更正 |

### 8.3 jsLib 体积分布
jsLib 非空 **45 源**；≥100KB **2 源**；≥500KB **2 源**（均为七猫四合一本地版）。→ "大 jsLib" 是极少数源的特性，夹具策略可按源定制。

### 8.4 七猫 588KB jsLib 的 Java 面明细（导出件实测）
`Packages.` 22 处、`android.util.Base64` 5 处、`javax.crypto` 3 处、`java.lang.` 8 处、`java.util.` 5 处、`cn.hutool` 1 处、`.getBytes(` 3 处、`UUID` 10 处；顶层函数含 `qmJavaOf` / `qmBase64Encode` / `qmHexDecodeAscii` / `qmMd5` / `qmSign` / `qmUrlSign` / `qmParamEncode` / `qmCacheOf` / `qmBookVariable` 等——是一套含签名与解码的 API 封装层。
