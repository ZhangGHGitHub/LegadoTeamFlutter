# Rhino 形参转换探针证据（字符串 / 数值 / 布尔，2026-10-06）

> W-1 落实。来源：`docs/SEARCH_FIX_BATCH_CODE_REVIEW_20261006.md:133`——「Rhino 探针（JDK17 实测）无源码/输出入库」。
> 本文固化探针源码、可复现命令与原始输出，作为 `rust/legado-js/src/host_api/coerce.rs` 转换表
> （当前文件 :13-23，审查引用为 :20-33）与 `rust/legado-js/src/host_api/quickjs_impl.rs:80-93`
> 数组形参叙述、以及 P0-A 三处有意偏差的**可复核实测依据**。
>
> 本探针只测引擎（原版 Rhino LiveConnect）的转换行为，不测 Rust 实现；仅新增证据与文档，零运行时行为变更。
>
> **2026-10-06 W4 补充（§9）**：新增数值/布尔形参 + `java.ajax(Object)` 边界探针
> （`RhinoNumericParamProbe.java`，实跑输出 `probe_numeric_output.txt`）。§1-§8 为字符串形参部分
> （原始运行，不变）；§9 的实测结论已驱动 `coerce.rs` 数值转换层（`RhinoInt`/`RhinoLong`/
> `RhinoOptInt`/`RhinoOptLong`）与 17 个 API / 18 个形参的实现变更（见 §9.4）。

## 1. 目的

1. 复核 `coerce.rs:13-23` 转换表逐项（数组 join/递归、`[object Object]`、自定义 `toString`、
   数字/布尔、`undefined`、`null`、缺参）。
2. 复核 `quickjs_impl.rs:80-93` 对上游 `Array<String>` 形参（`ajaxAll`）的叙述：
   元素级转换、元素 `null`/`undefined`、整体 `null`/`undefined`（含 review §4 的「逗号分隔字符串 → 方法不存在」）。
3. 记录三处已登记偏差（标量 `null`→`"null"`；数组元素/整体 `null`→空串/空列表；`undefined`→空串）
   在探针中的对应实测行为，见 §7。
4. 结论要求：若实测与 `coerce.rs` 表不符，如实标出并停止改码（本次未出现，见 §6）。

## 2. 环境

| 项 | 值 |
|---|---|
| JDK | Eclipse Temurin `17.0.19+10`（`java.version=17.0.19`，`java.vendor=Eclipse Adoptium`），路径 `C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot` |
| 引擎 JAR | `third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar` |
| JAR md5 | `28e9486663d87d96178c9b918df4b32f` |
| JAR sha256 | `d720f34285515025e4ccc80a5b92aed42cb26c03a7715ca53583d2c74ae51df7`（与 `third_party/.../SOURCE.md` 记载一致） |
| 引擎版本 | `Rhino Snapshot`（`Context.getImplementationVersion()`） |
| 引擎包名 | `org.htmlunit.corejs.javascript`（原版 Android 所用 htmlunit-core-js fork；SOURCE.md 来源 `mgz0227/htmlunit-core-js`，即 Legado 作者 fork） |

探针文件哈希（本文嵌入内容与下列文件一一对应）：

| 文件 | sha256 |
|---|---|
| `docs/materials_rhino_probe_20261006/RhinoStringParamProbe.java` | `e2f7e12d8cde18ffd75f06e7a1475e13f2928ce65ebe2a41ac579902f76281cf` |
| `docs/materials_rhino_probe_20261006/probe_output.txt` | `ccc7f709377338ba6ed4c5fcf662c02e4626bf7cad7e3fa12487aa47d8453a86` |
| `docs/materials_rhino_probe_20261006/run_probe.sh` | `229c95027e701e8c9d77fa6d48ea29be8df5dbc43bfae6db57ac534ca1917eff` |

实现说明（供复现）：

- 该 fork 已做 Rhino 1.8 式类型重构：`TopLevel implements VarScope` 而非 `Scriptable`，
  故探针用 `TopLevel` + `ScriptableObject.putProperty(VarScope, ...)` + `Context.javaToJS(Object, VarScope)`。
- 探针中 Java 形参声明为可空 `String` / `String[]`；Kotlin 非空形参行为以显式 NPE 方法模拟
  （CASE 16/25，方法名带 `KotlinNonNull` 后缀），与「原版 Kotlin 非空形参 → NPE」的登记口径对应。
- 原始输出中「找不到方法 …」为 JVM 默认 locale（zh_CN）下的 Rhino 错误消息，**原样保留**。

## 3. 可复现命令

仓库根目录下（JDK 17；`JAVA_BIN` 可在脚本中覆盖）：

```bash
bash docs/materials_rhino_probe_20261006/run_probe.sh > docs/materials_rhino_probe_20261006/probe_output.txt 2>&1
```

`run_probe.sh` 内容即等价于：

```bash
JAR=third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar
"$JAVA_BIN/javac" -encoding UTF-8 -cp "$JAR" -d docs/materials_rhino_probe_20261006/_classes docs/materials_rhino_probe_20261006/RhinoStringParamProbe.java
"$JAVA_BIN/java" -cp "docs/materials_rhino_probe_20261006/_classes;$JAR" RhinoStringParamProbe
rm -rf docs/materials_rhino_probe_20261006/_classes
```

## 4. 探针源码全文

```java
import org.htmlunit.corejs.javascript.Context;
import org.htmlunit.corejs.javascript.RhinoException;
import org.htmlunit.corejs.javascript.ScriptableObject;
import org.htmlunit.corejs.javascript.TopLevel;
import org.htmlunit.corejs.javascript.WrappedException;

/**
 * Rhino String-parameter coercion probe (evidence for docs/RHINO_STRING_PARAM_PROBE_20261006.md).
 *
 * Purpose: measure how the original Legado JS engine (htmlunit-core-js, package
 * org.htmlunit.corejs.javascript) converts JavaScript argument values when calling
 * Java methods whose parameter is declared as java.lang.String, and as java.lang.String[].
 *
 * The probe mirrors the original app's setup: a Java/JVM host object is wrapped with
 * Context.javaToJS and published on the scope, then invoked from JS via evaluateString.
 *
 * Run (from repository root, JDK 17):
 *   JAR=third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar
 *   javac -encoding UTF-8 -cp "$JAR" -d <classes-dir> docs/materials_rhino_probe_20261006/RhinoStringParamProbe.java
 *   java -cp "<classes-dir>;$JAR" RhinoStringParamProbe
 *
 * This file is documentation material only: it is not part of any build.
 */
public final class RhinoStringParamProbe {

    /** Plain Java host object, mirroring the JVM methods exposed by the original app. */
    public static final class HostApi {

        public void takeString(String s) {
            System.out.println("      [java] takeString(String) reached: s = " + repr(s));
        }

        /**
         * Simulates a Kotlin non-null parameter (Intrinsics.checkNotNullParameter):
         * Java null triggers an NPE, which is how the original app's Kotlin functions
         * behave when Rhino passes a Java null for a non-null String parameter.
         */
        public void takeStringKotlinNonNull(String s) {
            if (s == null) {
                throw new NullPointerException(
                        "Parameter specified as non-null is null: method HostApi.takeStringKotlinNonNull, parameter s");
            }
            System.out.println("      [java] takeStringKotlinNonNull(String) reached: s = " + repr(s));
        }

        public void takeArray(String[] arr) {
            if (arr == null) {
                System.out.println("      [java] takeArray(String[]) reached: arr = <JAVA_NULL>");
                return;
            }
            StringBuilder sb = new StringBuilder();
            sb.append("      [java] takeArray(String[]) reached: arr(len=").append(arr.length).append(") = [");
            for (int i = 0; i < arr.length; i++) {
                if (i > 0) {
                    sb.append(", ");
                }
                sb.append(repr(arr[i]));
            }
            sb.append("]");
            System.out.println(sb);
        }

        /** Simulates a Kotlin non-null Array<String> parameter. */
        public void takeArrayKotlinNonNull(String[] arr) {
            if (arr == null) {
                throw new NullPointerException(
                        "Parameter specified as non-null is null: method HostApi.takeArrayKotlinNonNull, parameter arr");
            }
            System.out.println("      [java] takeArrayKotlinNonNull(String[]) reached: len=" + arr.length);
        }
    }

    private static String repr(String s) {
        return s == null ? "<JAVA_NULL>" : "\"" + s + "\" (len=" + s.length() + ")";
    }

    private static int caseNo = 0;

    public static void main(String[] args) {
        System.out.println("=== Rhino String-parameter coercion probe ===");
        System.out.println("java.version = " + System.getProperty("java.version"));
        System.out.println("java.vendor  = " + System.getProperty("java.vendor"));

        Context cx = Context.enter();
        try {
            System.out.println("rhino.impl   = " + cx.getImplementationVersion());
            System.out.println("classpath engine = htmlunit-core-js (org.htmlunit.corejs.javascript)");

            TopLevel scope = cx.initStandardObjects();
            ScriptableObject.putProperty(scope, "probe", Context.javaToJS(new HostApi(), scope));

            run(cx, scope, "setup: define plain object objPlain = {}",
                    "var objPlain = {};");
            run(cx, scope, "setup: define objCustom with custom toString",
                    "var objCustom = { toString: function () { return \"CUSTOM_TO_STRING\"; } };");

            run(cx, scope, "scalar String param <- JS array ['a','b']",
                    "probe.takeString([\"a\",\"b\"])");
            run(cx, scope, "scalar String param <- JS array [1,2,3]",
                    "probe.takeString([1,2,3])");
            run(cx, scope, "scalar String param <- empty JS array []",
                    "probe.takeString([])");
            run(cx, scope, "scalar String param <- nested array [['a'],'b']",
                    "probe.takeString([[\"a\"],\"b\"])");
            run(cx, scope, "scalar String param <- nested array [[1,2],[3]]",
                    "probe.takeString([[1,2],[3]])");
            run(cx, scope, "scalar String param <- plain object {}",
                    "probe.takeString(objPlain)");
            run(cx, scope, "scalar String param <- object with custom toString",
                    "probe.takeString(objCustom)");
            run(cx, scope, "scalar String param <- number 42",
                    "probe.takeString(42)");
            run(cx, scope, "scalar String param <- number 1.5",
                    "probe.takeString(1.5)");
            run(cx, scope, "scalar String param <- boolean true",
                    "probe.takeString(true)");
            run(cx, scope, "scalar String param <- undefined",
                    "probe.takeString(undefined)");
            run(cx, scope, "scalar String param <- null",
                    "probe.takeString(null)");
            run(cx, scope, "scalar String param <- missing argument",
                    "probe.takeString()");
            run(cx, scope, "scalar String param <- null into simulated Kotlin non-null param",
                    "probe.takeStringKotlinNonNull(null)");

            run(cx, scope, "String[] param <- JS array ['a','b']",
                    "probe.takeArray([\"a\",\"b\"])");
            run(cx, scope, "String[] param <- empty JS array []",
                    "probe.takeArray([])");
            run(cx, scope, "String[] param <- mixed elements ['a',null,undefined,42,true]",
                    "probe.takeArray([\"a\",null,undefined,42,true])");
            run(cx, scope, "String[] param <- nested array [[1,2],[3]]",
                    "probe.takeArray([[1,2],[3]])");
            run(cx, scope, "String[] param <- plain string 'a,b'",
                    "probe.takeArray(\"a,b\")");
            run(cx, scope, "String[] param <- number 42",
                    "probe.takeArray(42)");
            run(cx, scope, "String[] param <- undefined",
                    "probe.takeArray(undefined)");
            run(cx, scope, "String[] param <- null",
                    "probe.takeArray(null)");
            run(cx, scope, "String[] param <- null into simulated Kotlin non-null param",
                    "probe.takeArrayKotlinNonNull(null)");
            run(cx, scope, "String[] param <- missing argument",
                    "probe.takeArray()");
        } finally {
            Context.exit();
        }
        System.out.println();
        System.out.println("=== probe finished ===");
    }

    private static void run(Context cx, TopLevel scope, String description, String js) {
        caseNo++;
        System.out.println();
        System.out.println("--- CASE " + caseNo + ": " + description + " ---");
        System.out.println("    JS> " + js);
        try {
            Object result = cx.evaluateString(scope, js, "probe-case-" + caseNo, 1, null);
            System.out.println("    JS result: " + Context.toString(result));
        } catch (WrappedException we) {
            Throwable cause = we.getWrappedException();
            System.out.println("    ERROR (wrapped Java exception): " + cause.getClass().getName()
                    + ": " + cause.getMessage());
        } catch (RhinoException re) {
            System.out.println("    ERROR (" + re.getClass().getName() + "): " + re.getMessage());
        } catch (Throwable t) {
            System.out.println("    ERROR (" + t.getClass().getName() + "): " + t.getMessage());
        }
    }
}
```

## 5. 原始输出全文

以下为 `run_probe.sh` 于上述环境的一次完整运行 stdout+stderr 原文（未加工）：

```text
=== Rhino String-parameter coercion probe ===
java.version = 17.0.19
java.vendor  = Eclipse Adoptium
rhino.impl   = Rhino Snapshot
classpath engine = htmlunit-core-js (org.htmlunit.corejs.javascript)

--- CASE 1: setup: define plain object objPlain = {} ---
    JS> var objPlain = {};
    JS result: undefined

--- CASE 2: setup: define objCustom with custom toString ---
    JS> var objCustom = { toString: function () { return "CUSTOM_TO_STRING"; } };
    JS result: undefined

--- CASE 3: scalar String param <- JS array ['a','b'] ---
    JS> probe.takeString(["a","b"])
      [java] takeString(String) reached: s = "a,b" (len=3)
    JS result: undefined

--- CASE 4: scalar String param <- JS array [1,2,3] ---
    JS> probe.takeString([1,2,3])
      [java] takeString(String) reached: s = "1,2,3" (len=5)
    JS result: undefined

--- CASE 5: scalar String param <- empty JS array [] ---
    JS> probe.takeString([])
      [java] takeString(String) reached: s = "" (len=0)
    JS result: undefined

--- CASE 6: scalar String param <- nested array [['a'],'b'] ---
    JS> probe.takeString([["a"],"b"])
      [java] takeString(String) reached: s = "a,b" (len=3)
    JS result: undefined

--- CASE 7: scalar String param <- nested array [[1,2],[3]] ---
    JS> probe.takeString([[1,2],[3]])
      [java] takeString(String) reached: s = "1,2,3" (len=5)
    JS result: undefined

--- CASE 8: scalar String param <- plain object {} ---
    JS> probe.takeString(objPlain)
      [java] takeString(String) reached: s = "[object Object]" (len=15)
    JS result: undefined

--- CASE 9: scalar String param <- object with custom toString ---
    JS> probe.takeString(objCustom)
      [java] takeString(String) reached: s = "CUSTOM_TO_STRING" (len=16)
    JS result: undefined

--- CASE 10: scalar String param <- number 42 ---
    JS> probe.takeString(42)
      [java] takeString(String) reached: s = "42" (len=2)
    JS result: undefined

--- CASE 11: scalar String param <- number 1.5 ---
    JS> probe.takeString(1.5)
      [java] takeString(String) reached: s = "1.5" (len=3)
    JS result: undefined

--- CASE 12: scalar String param <- boolean true ---
    JS> probe.takeString(true)
      [java] takeString(String) reached: s = "true" (len=4)
    JS result: undefined

--- CASE 13: scalar String param <- undefined ---
    JS> probe.takeString(undefined)
      [java] takeString(String) reached: s = "undefined" (len=9)
    JS result: undefined

--- CASE 14: scalar String param <- null ---
    JS> probe.takeString(null)
      [java] takeString(String) reached: s = <JAVA_NULL>
    JS result: undefined

--- CASE 15: scalar String param <- missing argument ---
    JS> probe.takeString()
    ERROR (org.htmlunit.corejs.javascript.EvaluatorException): 找不到方法 “RhinoStringParamProbe$HostApi.takeString()”。 (probe-case-15#1)

--- CASE 16: scalar String param <- null into simulated Kotlin non-null param ---
    JS> probe.takeStringKotlinNonNull(null)
    ERROR (wrapped Java exception): java.lang.NullPointerException: Parameter specified as non-null is null: method HostApi.takeStringKotlinNonNull, parameter s

--- CASE 17: String[] param <- JS array ['a','b'] ---
    JS> probe.takeArray(["a","b"])
      [java] takeArray(String[]) reached: arr(len=2) = ["a" (len=1), "b" (len=1)]
    JS result: undefined

--- CASE 18: String[] param <- empty JS array [] ---
    JS> probe.takeArray([])
      [java] takeArray(String[]) reached: arr(len=0) = []
    JS result: undefined

--- CASE 19: String[] param <- mixed elements ['a',null,undefined,42,true] ---
    JS> probe.takeArray(["a",null,undefined,42,true])
      [java] takeArray(String[]) reached: arr(len=5) = ["a" (len=1), <JAVA_NULL>, "undefined" (len=9), "42" (len=2), "true" (len=4)]
    JS result: undefined

--- CASE 20: String[] param <- nested array [[1,2],[3]] ---
    JS> probe.takeArray([[1,2],[3]])
      [java] takeArray(String[]) reached: arr(len=2) = ["1,2" (len=3), "3" (len=1)]
    JS result: undefined

--- CASE 21: String[] param <- plain string 'a,b' ---
    JS> probe.takeArray("a,b")
    ERROR (org.htmlunit.corejs.javascript.EvaluatorException): 找不到方法 “RhinoStringParamProbe$HostApi.takeArray(string)”。 (probe-case-21#1)

--- CASE 22: String[] param <- number 42 ---
    JS> probe.takeArray(42)
    ERROR (org.htmlunit.corejs.javascript.EvaluatorException): 找不到方法 “RhinoStringParamProbe$HostApi.takeArray(number)”。 (probe-case-22#1)

--- CASE 23: String[] param <- undefined ---
    JS> probe.takeArray(undefined)
    ERROR (org.htmlunit.corejs.javascript.EvaluatorException): 找不到方法 “RhinoStringParamProbe$HostApi.takeArray(org.htmlunit.corejs.javascript.Undefined)”。 (probe-case-23#1)

--- CASE 24: String[] param <- null ---
    JS> probe.takeArray(null)
      [java] takeArray(String[]) reached: arr = <JAVA_NULL>
    JS result: undefined

--- CASE 25: String[] param <- null into simulated Kotlin non-null param ---
    JS> probe.takeArrayKotlinNonNull(null)
    ERROR (wrapped Java exception): java.lang.NullPointerException: Parameter specified as non-null is null: method HostApi.takeArrayKotlinNonNull, parameter arr

--- CASE 26: String[] param <- missing argument ---
    JS> probe.takeArray()
    ERROR (org.htmlunit.corejs.javascript.EvaluatorException): 找不到方法 “RhinoStringParamProbe$HostApi.takeArray()”。 (probe-case-26#1)

=== probe finished ===
```

## 6. 与 `coerce.rs` 转换表逐项对照

`coerce.rs:13-23` 转换表（标量 `String` 形参）逐项：

| `coerce.rs` 表项 | 探针 case | 实测到达 Java 侧的值 | 结论 |
|---|---|---|---|
| `[1,2,3]` → `"1,2,3"` | CASE 4 | `"1,2,3"` | 一致 |
| `['a','b']` → `"a,b"` | CASE 3 | `"a,b"` | 一致 |
| `[]` → `""` | CASE 5 | `""` | 一致 |
| `[[1,2],[3]]` → `"1,2,3"`（递归 toString） | CASE 7；另 CASE 6 `[['a'],'b']` → `"a,b"` | `"1,2,3"` | 一致 |
| `{a:1}` → `"[object Object]"` | CASE 8（实测 `{}`） | `"[object Object]"` | 一致 |
| 自定义 `toString` 对象 → 调用其 `toString()` | CASE 9 | `"CUSTOM_TO_STRING"` | 一致 |
| `123` → `"123"`；`1.5` → `"1.5"`；`true` → `"true"` | CASE 10 / 11 / 12 | `"42"` / `"1.5"` / `"true"` | 一致 |
| `undefined` → `"undefined"` | CASE 13 | `"undefined"` | 一致（与实现 `Coerced<String>` 同口径，无偏差） |
| `null` → Java `null` | CASE 14 | `<JAVA_NULL>` | 一致（实现取 JS 字符串 `"null"`，偏差已登记，见 §7） |
| 缺参 → 方法不存在（arity 错误） | CASE 15 / CASE 26 | `EvaluatorException: 找不到方法 …takeString()` / `…takeArray()` | 一致 |

`quickjs_impl.rs:80-93` 数组形参叙述（超出 `coerce.rs` 表的补充实测）：

| 叙述点 | 探针 case | 实测 | 结论 |
|---|---|---|---|
| JS 数组元素级转换不报错 | CASE 17 | `["a","b"]` → `{"a","b"}` | 一致 |
| `[1,false]` → `["1","false"]` 风格的元素 ToString | CASE 19（`42`/`true` 元素） | `"42"` / `"true"` | 一致 |
| 元素 `undefined` → `"undefined"` 字面量 | CASE 19 | 元素到达栈为 `"undefined"` | 一致 |
| 元素 `null` → Java `null` 元素（Kotlin 侧随后 NPE） | CASE 19 | 元素到达栈为 `<JAVA_NULL>` | 一致 |
| 嵌套元素按元素递归 toString | CASE 20 | `[[1,2],[3]]` → `{"1,2","3"}` | 一致（该点原文档未单列，本次补充） |
| 逗号分隔字符串 → 「方法不存在」（review §4） | CASE 21 | `EvaluatorException: 找不到方法 …takeArray(string)` | 一致 |
| 数字 → 方法不存在 | CASE 22 | `找不到方法 …takeArray(number)` | 一致 |
| 整体 `undefined` → 「方法不存在」 | CASE 23 | `找不到方法 …takeArray(org.htmlunit.corejs.javascript.Undefined)` | 一致 |
| 整体 `null` → Java `null`（Kotlin NPE） | CASE 24 / 25 | Java 可空形参收到 `<JAVA_NULL>`；Kotlin 非空模拟抛 NPE | 一致 |
| 空数组 → 空数组（无 arity/类型错误） | CASE 18 | `arr(len=0)` | 一致 |

**对照结论：全部一致，未发现与实现不符或未登记的语义差异。**

## 7. 三处已登记偏差在探针中的对应行为

1. **标量 `null` → 实现取 `"null"`（`coerce.rs:25-30` 已登记）**
   探针 CASE 14：`null` 到达 Java `String` 形参为 Java `null`；Kotlin 非空形参在 CASE 16（模拟）
   抛 `NullPointerException`。Rust 侧无法表达「Java null 到达后由 Kotlin 非空检查抛出 NPE」，
   故取 JS 规范字符串 `"null"`。偏差方向：宽容（原版 NPE 失败 → 我方得到 `"null"`）。

2. **数组元素 `null`/`undefined` → 实现取空串（`quickjs_impl.rs:85-88` 已登记）**
   探针 CASE 19：元素 `null` 到达为 Java `null` 元素、元素 `undefined` 到达为 `"undefined"`；
   实现（`quickjs_impl.rs` `LooseStrList`）两者均收敛为空串。偏差方向：宽容。

3. **数组形参整体 `null`/`undefined` → 实现取空列表（`quickjs_impl.rs:89-90` 已登记）**
   探针 CASE 24：`null` 到达 Java `String[]` 形参为 Java `null`（→ Kotlin 非空形参 NPE，CASE 25 模拟）；
   探针 CASE 23：`undefined` 直接「找不到方法」失败。实现两者均返回空列表/空串。偏差方向：宽容。

附带确认（非偏差，仅登记）：`coerce.rs` 表中 `undefined → "undefined"`、`null → Java null` 的分叉
（CASE 12/13）与实现一致；标量 `undefined` 在实现中同走 JS `ToString`，不属偏差。

## 8. 结论与界限

- 探针在原版引擎 JAR（sha256 与 SOURCE.md 一致）+ JDK 17 上真实运行，原始输出全文见 §5；
  与 `coerce.rs:13-23` 转换表、`quickjs_impl.rs:80-93` 数组形参叙述**逐项一致**，
  三处有意偏差均为已登记且方向一致（宽容侧），未发现需要改码的不一致。
- 证据升级：审查报告「Rhino 探针转换表 / 非可复核物证」的声明（`docs/SEARCH_FIX_BATCH_CODE_REVIEW_20261006.md:145`）
  经本文更新为**可复核**：源码 + 命令 + 原始输出 + 文件哈希齐备。
- 界限：探针模拟宿主对象与 Kotlin 非空检查（非真实 Kotlin 字节码）；`RhinoOptStr`
  的「先例口径」（`null`/`undefined` → `None`）属实现侧设计选择，不在引擎探针范围内。

---

## 9. W4 数值 / 布尔形参探针（2026-10-06 补充，实跑）

### 9.1 目的与范围

W4（`docs/JS_ENGINE_COERCE_CODE_REVIEW_20261006.md` 建议项 4 + 后续批）原假设
「Rhino LiveConnect 对 Java `int`/`long`/`boolean` 形参同样宽松（`"5000"`→5000、
`1`→true）」。本探针按**形参 JVM 声明类型**逐类实测，回答三个问题：

1. 非空原始 `int`/`long`/`double` 形参收字符串数字/浮点/布尔/`undefined`/`null`/非数字串
   时的实际到达值或抛错形态；
2. `boolean`/`Boolean` 形参收 `true`/`1`/`0`/`"true"`/`""`/`undefined`/`null`/`"abc"` 的行为；
3. `java.ajax(url: Any)` 的 List 分支边界（`[]` / `[undefined]` / `[null]`），以及 JS 数组
   实际以什么 Java 类型到达 `Object` 形参。

**预期证伪记录（先于实现，如实登记）**：

- 「`1`→true」**被证伪**：Rhino 布尔形参（原始与装箱）只接受 JS `true`/`false`，
  数字/字符串一律「找不到方法」。故 W4 **未**对任何布尔形参做宽松化（§9.4 B 组）。
- 「装箱数值同样宽松」**被证伪**：Kotlin 可空 `Int?`/`Long?` → JVM `Integer`/`Long`，
  只接受 JS number（`null` → Java null），字符串数字一律「找不到方法」。故 `connect` 的
  `timeout_ms`（上游 `callTimeout: Int?`，help/jsHelp.md:212）等可空数值形参**保持严格**。
- 「非空原始 `int`/`long` 收字符串数字宽松」**被证实**：`"5000"`→5000、`""`→0、
  `" 42 "`→42、`"0x10"`→16、浮点向零截断；NaN/Infinity/越界/非数字串抛错。
  这正是 W4 实际改码的方向（§9.4 A 组 18 个形参）。

### 9.2 环境、文件与复现命令

环境同 §2：JDK `17.0.19+10`（Temurin）、引擎 JAR
`third_party/maven/org/htmlunit/htmlunit-core-js/5.3.0-legado.4/htmlunit-core-js-5.3.0-legado.4.jar`
（md5 `28e9486663d87d96178c9b918df4b32f`，本次重跑复核一致）。

| 文件 | sha256 |
|---|---|
| `docs/materials_rhino_probe_20261006/RhinoNumericParamProbe.java` | `3f8a110ed9b027119a368ac5bbb5e2c621e0ebb521ee5edfdcc1cfa9b928ae20` |
| `docs/materials_rhino_probe_20261006/run_numeric_probe.sh` | `d414d4989411a289c17e61a9fa5bb95cdc3677624feadbe0708ade595bf32a0f` |
| `docs/materials_rhino_probe_20261006/probe_numeric_output.txt`（原始输出，166 个 case） | `80cb9c922c2ec825fcc595dccbcb46c46f24bc3aee22162d33fb11f0b9cf218e` |

```bash
bash docs/materials_rhino_probe_20261006/run_numeric_probe.sh \
    > docs/materials_rhino_probe_20261006/probe_numeric_output.txt 2>&1
```

补充说明：`javap` 复核确认本 fork 的
`org.htmlunit.corejs.javascript.NativeArray implements java.util.List`
——即 JS 数组传入 Java `Object` 形参后 `url instanceof List` 为真，上游
`JsExtensions.kt:130-137` 的 `firstOrNull()` 分支对 JS 数组确实生效（CASE 149-153）。

### 9.3 实测结果（关键行；完整输出见 `probe_numeric_output.txt`）

**A. 非空原始 `int`（CASE 1-22）/ `long`（CASE 23-44）——宽松**

| JS 实参 | `int` 到达值 | `long` 到达值 | case |
|---|---|---|---|
| `5000` | 5000 | 5000 | 1 / 23 |
| `"5000"` | **5000** | **5000** | 2 / 24 |
| `5000.7` | 5000 | 5000 | 3 / 25 |
| `"5000.7"` | **5000** | **5000** | 4 / 26 |
| `-5000.7` / `"-42"` | -5000 / -42（向零截断） | 同 | 5-6 / 27-28 |
| `true` / `false` | 找不到方法（抛错） | 找不到方法 | 7-8 / 29-30 |
| `undefined` / `null` | 找不到方法（抛错） | 找不到方法 | 9-10 / 31-32 |
| `"abc"` | 无法将 abc 转换（抛错） | 同 | 11 / 33 |
| `""` / `" 42 "` / `"1e3"` / `"0x10"` | 0 / 42 / 1000 / 16 | 0 / 42 / 1000 / 16 | 12-14 / 34-36 / 165 / 166 |
| `NaN` / `Infinity` | 抛错 | 抛错 | 15-16 / 37-38 |
| `[]` / `[5000]` / `[5000.7]` | 0 / 5000 / 5000（ToString→ToNumber） | 0 / 5000 / 5000 | 17-19 / 39-41 |
| `{}` / `[5000,6000]` | 抛错（`[object Object]`/`"5000,6000"` → NaN） | 同 | 20 / 164 / 42 |
| `5000000000` / `"5000000000"` | **抛错（int 越界）** | 5000000000（不越界） | 21-22 / 43-44 |
| 自定义 `toString` → `"5000"` 的对象 | 5000 | 5000 | 162-163 |

`double` 形参（CASE 45-66）为对照：同样宽松但接受 NaN/Infinity（非本批 Rust 面）。

**B. 装箱 `Integer`（CASE 67-88）/ `Long`（CASE 89-113）——严格**

| JS 实参 | `Integer`/`Long` 到达 | case |
|---|---|---|
| `5000` / `5000.7` | 5000（截断） | 67/69/89/91 |
| `"5000"` / `"5000.7"` / `"-42"` / `""` / `"1e3"` / `"abc"` | **找不到方法（抛错）** | 68/70/72/78-80/90/92/94/99-102 |
| `true` / `false` / `[]` / `[5000]` / `{}` | 找不到方法 | 73-74/83-86/95-96/105-108 |
| `undefined` | 找不到方法（**不落 null**） | 75 / 97 |
| `null` | **Java null** | 76 / 98 |
| `NaN` / `Infinity` / `5000000000`(int 越界) | 抛错 | 81-82/87 / 103-104 |
| 装箱 `null` 入模拟 Kotlin 非空形参 | NPE | 112 |

**C. `boolean`（CASE 114-130）/ `Boolean`（CASE 131-148）——严格**

| JS 实参 | `boolean` | `Boolean` |
|---|---|---|
| `true` / `false` | true / false | true / false |
| `1` / `0` / `2` / `-1` | **找不到方法** | **找不到方法** |
| `"true"` / `"false"` / `""` / `"0"` / `"1"` / `"abc"` | **找不到方法** | **找不到方法** |
| `undefined` | 找不到方法 | 找不到方法 |
| `null` | 找不到方法 | **Java null** |
| `[]` / `[1]` / `{}` | 找不到方法 | 找不到方法 |

**D. `java.ajax(Object)` 边界（CASE 149-160）**

| JS 实参 | 到达 Java 类型 | `firstOrNull().toString()` 结果 | case |
|---|---|---|---|
| `["a","b"]` / `["a"]` | NativeArray（implements List） | `"a"` | 149 / 153 |
| `[]` | NativeArray（List） | `"null"`（Java null → valueOf） | 150 |
| `[undefined]` | NativeArray（List） | **`"null"`**（`get(0)` → Java null） | 151 |
| `[null]` | NativeArray（List） | **`"null"`** | 152 |
| `[["x"],"y"]` | NativeArray（List） | 首元素为 NativeArray → `NativeArray@<hash>` | 160 |
| `"str"` | java.lang.String | `"str"` | 154 |
| `42` | java.lang.Double | **`"42.0"`**（Java Double.toString） | 155 |
| `true` / `{}` | Boolean / NativeObject | `"true"` / `"[object Object]"` | 156-157 |
| `null` / `undefined` | Java null / java.lang.String | `"null"` / `"undefined"` | 158-159 |

### 9.4 与实现对照（W4 改码清单）

**A 组：确认宽松 → 已实现（17 API / 18 形参）**

新增 `coerce.rs` 的 `RhinoInt`/`RhinoLong`（含 `RhinoOptInt`/`RhinoOptLong` 可选 arity 版）：
`bool`/`undefined`/`null` 与 Rhino 同向抛错；其余值走 QuickJS `JS_ToFloat64`
（= JS `ToNumber`），并显式拒绝 NaN/Infinity/越界——修复了 rquickjs
`i64::from_js` 对 `NaN` 静默转 0 的既有偏差（红测实测：改前 `java.timeFormat(NaN)`
返回 `1970/01/01 08:00`）。

| API（上游签名） | 形参 | 改前 | 改后 |
|---|---|---|---|
| `base64DecodeToByteArray`（JsExtensions.kt:648） | `flags: Int` | `Opt<i32>` 严格 | `RhinoOptInt` |
| `regExp`（宿主兼容 shim，模型 `group: Int`） | `group` | `i32` 严格 | `RhinoInt` |
| `formatTime`（宿主兼容 shim，模型 `ts: Long`） | `ts` | `i64` 严格 | `RhinoLong` |
| `timeFormat`（:698） | `ts: Long` | `i64` 严格 | `RhinoLong` |
| `timeFormatUTC`（:686） | `ts: Long` / `sh: Int` | `i64`/`i32` 严格 | `RhinoLong`/`RhinoInt` |
| `threadSleep`/`sleep`（模型 `Thread.sleep(long)`） | `ms` | `i64` 严格 | `RhinoLong` |
| `List.get(i)` 垫片（模型 JDK `List.get(int)`） | `i` | `i64` 严格 | `RhinoLong` |
| `jsoupAttrN`/`jsoupTextN`/`jsoupHtmlN`/`jsoupHtmlNExcluded`（模型 `Elements.get(int)`） | `i` | `i64` 严格 | `RhinoLong` |
| `cache.put`（CacheManager.kt:60，`@JvmOverloads`） | `saveTime: Int` | `Opt<i64>` 严格 | `RhinoOptLong` |
| `singleFlight`/`lock`（:1250/:1270） | `timeoutMs: Long` | `i64` 严格 | `RhinoLong` |
| `webViewGetSource`/`webViewGetOverrideUrl`（:271/:306） | `delayTime: Long` | `Opt<i64>` 严格 | `RhinoOptLong` |

**B 组：探针证明严格 → 保持原签名（6 API / 8 形参）**

| API（上游签名） | 形参 | 保持 | 探针依据 |
|---|---|---|---|
| `connect`（help/jsHelp.md:212，`callTimeout: Int?` 装箱） | `timeout_ms` | `Opt<i64>` | CASE 68/90 字符串→找不到方法 |
| `cache.get`（CacheManager.kt:108） | `onlyDisk: Boolean` | `Opt<bool>` | CASE 133-142 |
| `openVideoPlayer`（:343） | `isFloat: Boolean` | `Opt<bool>` | CASE 116-125 |
| `webViewGetSource`/`webViewGetOverrideUrl`（:271/:306） | `cacheFirst: Boolean` | `Opt<bool>` | CASE 120-125 |
| `startBrowserAwait`（:368） | `refetchAfterSuccess: Boolean` | `Opt<bool>` | CASE 120-125 |
| `queryTTF`（:1014） | `useCache: Boolean` | `Opt<bool>` | CASE 116-125 |
| `replaceFont`（:1105） | `filter: Boolean` | `Opt<bool>` | CASE 116-125 |

**登记偏差（宽容侧，与 P0-A `RhinoOptStr` 先例一致）**：`RhinoOptInt`/`RhinoOptLong`
把显式 `null`/`undefined` 收敛为 `None`（缺省），而 Rhino 原始数值形参收二者是「找不到方法」；
布尔 `Opt<bool>` 同样对 `null` 收敛 `None`（上游 `Boolean` 装箱为 Java null、原始为抛错）。
方向均为宽容，不会把原版可用书源变失败。

**`AjaxUrlStr` 复核结论（审查余量项①）**：CASE 149-152 证实
`[]`/`[undefined]`/`[null]` 三者在原版都收敛为字符串 `"null"`（Kotlin
`firstOrNull().toString()`），与 `quickjs_impl.rs` 现行 `AjaxUrlStr` 完全一致，
**无需微调**（`rust/legado-js/tests/host_api_numeric_arg.rs` 已锁定）。
附带登记一处标量偏差：`java.ajax(42)` 原版经 Java `Double.toString` 得 `"42.0"`，
我方 `RhinoStr` 得 `"42"`——非数组、非常见书源形态，本次不改，仅登记。

### 9.5 实现侧验证与界限

- 先红后绿：`rust/legado-js/tests/host_api_numeric_arg.rs`（6 例）在改码前 4 例红
  （字符串数字报 `Error converting from js 'string' into type 'i32'/'f64'`；`NaN` 静默为 0），
  实现后 6 例全绿；`cargo test -p legado-js --features quickjs` 全量通过
  （lib 660 passed / 0 failed，含本文件 6 例）。
- 界限：探针以普通 Java 宿主对象模拟 Kotlin 形参（非真实 Kotlin 字节码）；
  `regExp`/`formatTime`/`threadSleep`/`sleep`/`List.get`/`jsoup*N` 在上游基线中
  无同名 Kotlin 方法（宿主兼容 shim / Packages 桥），其「原始数值」建模依据是
  同形 Java 方法（`Thread.sleep(long)`、`List.get(int)`、`Elements.get(int)`）与
  Rhino 声明类型分流实测，不对上游符号存在性作声明。
- 探针重跑命令、文件哈希、原始输出如上；JAR md5 与 §2 记载一致。

