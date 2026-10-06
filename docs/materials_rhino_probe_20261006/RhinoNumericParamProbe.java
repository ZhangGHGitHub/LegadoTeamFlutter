import org.htmlunit.corejs.javascript.Context;
import org.htmlunit.corejs.javascript.RhinoException;
import org.htmlunit.corejs.javascript.ScriptableObject;
import org.htmlunit.corejs.javascript.TopLevel;
import org.htmlunit.corejs.javascript.WrappedException;

/**
 * Rhino 数值/布尔形参 + java.ajax(Object) 边界 探针
 *
 * 证据文档：docs/RHINO_STRING_PARAM_PROBE_20261006.md（W4 章节）。
 *
 * 目的：实测原版 Legado JS 引擎（htmlunit-core-js，包名
 * org.htmlunit.corejs.javascript）在 Java 形参声明为 int/long/Integer/Long/
 * double/boolean/Boolean 时，对各类 JS 实参值（数字、字符串数字、浮点、布尔、
 * undefined、null、非数字串、数组、对象等）的实际到达值或抛错形态。
 *
 * 另复核 java.ajax(Object) 的上游 List 分支边界（空数组 / [undefined] /
 * [null]），以及 Object 形参下 JS 数组到底以什么 Java 类型到达。
 *
 * 运行（仓库根目录，JDK 17）：
 *   bash docs/materials_rhino_probe_20261006/run_numeric_probe.sh \
 *       > docs/materials_rhino_probe_20261006/probe_numeric_output.txt 2>&1
 *
 * 本文件仅为文档材料，不参与任何构建。
 */
public final class RhinoNumericParamProbe {

    /** 普通 Java 宿主对象，模拟原版暴露给 JS 的 JVM 方法。 */
    public static final class HostApi {

        public void takeInt(int v) {
            System.out.println("      [java] takeInt(int) reached: v = " + v);
        }

        public void takeLong(long v) {
            System.out.println("      [java] takeLong(long) reached: v = " + v);
        }

        public void takeDouble(double v) {
            System.out.println("      [java] takeDouble(double) reached: v = " + v);
        }

        public void takeIntObj(Integer v) {
            System.out.println("      [java] takeIntObj(Integer) reached: v = " + (v == null ? "<JAVA_NULL>" : v.toString()));
        }

        public void takeLongObj(Long v) {
            System.out.println("      [java] takeLongObj(Long) reached: v = " + (v == null ? "<JAVA_NULL>" : v.toString()));
        }

        /** 模拟 Kotlin 非空可空装箱形参 `Long`（Intrinsics.checkNotNullParameter）。 */
        public void takeLongObjKotlinNonNull(Long v) {
            if (v == null) {
                throw new NullPointerException(
                        "Parameter specified as non-null is null: method HostApi.takeLongObjKotlinNonNull, parameter v");
            }
            System.out.println("      [java] takeLongObjKotlinNonNull(Long) reached: v = " + v);
        }

        public void takeBool(boolean v) {
            System.out.println("      [java] takeBool(boolean) reached: v = " + v);
        }

        public void takeBoolObj(Boolean v) {
            System.out.println("      [java] takeBoolObj(Boolean) reached: v = " + (v == null ? "<JAVA_NULL>" : v.toString()));
        }

        /**
         * 模拟上游 `JsExtensions.kt:130-137` 的 `ajax(url: Any)`：
         * List → firstOrNull().toString()；其余 → url.toString()。
         * 同时打印实际到达的 Java 运行时类型，供判断 JS 数组的适配形态。
         */
        public String ajaxSim(Object url) {
            System.out.println("      [java] ajaxSim(Object) reached: class = "
                    + (url == null ? "<JAVA_NULL>" : url.getClass().getName()));
            Object f;
            if (url instanceof java.util.List) {
                java.util.List<?> list = (java.util.List<?>) url;
                f = list.isEmpty() ? null : list.get(0);
            } else {
                f = url;
            }
            return String.valueOf(f);
        }
    }

    private static int caseNo = 0;

    public static void main(String[] args) {
        System.out.println("=== Rhino numeric/boolean parameter coercion probe ===");
        System.out.println("java.version = " + System.getProperty("java.version"));
        System.out.println("java.vendor  = " + System.getProperty("java.vendor"));

        Context cx = Context.enter();
        try {
            System.out.println("rhino.impl   = " + cx.getImplementationVersion());
            System.out.println("classpath engine = htmlunit-core-js (org.htmlunit.corejs.javascript)");

            TopLevel scope = cx.initStandardObjects();
            ScriptableObject.putProperty(scope, "probe", Context.javaToJS(new HostApi(), scope));

            String[] numericValues = {
                    "5000", "\"5000\"", "5000.7", "\"5000.7\"", "-5000.7", "\"-42\"",
                    "true", "false", "undefined", "null", "\"abc\"", "\"\"",
                    "\" 42 \"", "\"1e3\"", "NaN", "Infinity",
                    "[]", "[5000]", "[5000.7]", "{}",
                    "5000000000", "\"5000000000\"",
            };
            for (String v : numericValues) {
                run(cx, scope, "int param <- " + v, "probe.takeInt(" + v + ")");
            }
            for (String v : numericValues) {
                run(cx, scope, "long param <- " + v, "probe.takeLong(" + v + ")");
            }
            for (String v : numericValues) {
                run(cx, scope, "double param <- " + v, "probe.takeDouble(" + v + ")");
            }
            for (String v : numericValues) {
                run(cx, scope, "Integer(boxed) param <- " + v, "probe.takeIntObj(" + v + ")");
            }
            for (String v : numericValues) {
                run(cx, scope, "Long(boxed) param <- " + v, "probe.takeLongObj(" + v + ")");
            }
            run(cx, scope, "Long(boxed) param <- missing argument", "probe.takeLongObj()");
            run(cx, scope, "Long(boxed) param <- null into simulated Kotlin non-null param",
                    "probe.takeLongObjKotlinNonNull(null)");
            run(cx, scope, "Long(boxed) param <- undefined into simulated Kotlin non-null param",
                    "probe.takeLongObjKotlinNonNull(undefined)");

            String[] booleanValues = {
                    "true", "false", "1", "0", "2", "-1",
                    "\"true\"", "\"false\"", "\"\"", "\"0\"", "\"1\"", "\"abc\"",
                    "undefined", "null", "[]", "[1]", "{}",
            };
            for (String v : booleanValues) {
                run(cx, scope, "boolean param <- " + v, "probe.takeBool(" + v + ")");
            }
            for (String v : booleanValues) {
                run(cx, scope, "Boolean(boxed) param <- " + v, "probe.takeBoolObj(" + v + ")");
            }
            run(cx, scope, "Boolean(boxed) param <- missing argument", "probe.takeBoolObj()");

            String[] ajaxValues = {
                    "[\"a\",\"b\"]", "[]", "[undefined]", "[null]", "[\"a\"]",
                    "\"str\"", "42", "true", "{}", "null", "undefined",
                    "[[\"x\"],\"y\"]",
            };
            for (String v : ajaxValues) {
                run(cx, scope, "ajaxSim(Object) <- " + v,
                        "String(probe.ajaxSim(" + v + "))");
            }

            // 补充边界：对象走 ToString→ToNumber 的路径（自定义 toString / 多元素数组 /
            // 十六进制串 / 首尾空白串），用于判定宽松转换对 object 的处理。
            run(cx, scope, "setup: define objNumeric with custom toString -> \"5000\"",
                    "var objNumeric = { toString: function () { return \"5000\"; } };");
            run(cx, scope, "int param <- object with toString -> \"5000\"",
                    "probe.takeInt(objNumeric)");
            run(cx, scope, "long param <- object with toString -> \"5000\"",
                    "probe.takeLong(objNumeric)");
            run(cx, scope, "int param <- array [5000,6000]",
                    "probe.takeInt([5000,6000])");
            run(cx, scope, "int param <- \"0x10\"",
                    "probe.takeInt(\"0x10\")");
            run(cx, scope, "long param <- whitespace string \"\\t42\\n\"",
                    "probe.takeLong(\"\\t42\\n\")");
        } finally {
            Context.exit();
        }
        System.out.println();
        System.out.println("=== numeric probe finished ===");
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
