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
