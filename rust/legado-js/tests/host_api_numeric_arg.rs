//! 宿主 API 数值/布尔形参的 Rhino LiveConnect 语义回归测试（quickjs 档）
//!
//! 背景（W4）：`docs/JS_ENGINE_COERCE_CODE_REVIEW_20261006.md` 建议项 4——
//! 数值/布尔形参此前用 rquickjs 严格 `i32`/`i64`/`bool` 签名，JS 字符串数字
//! （`"5000"`）直接抛转换错误。原版 Rhino LiveConnect 对 Java/Kotlin **非空
//! 原始类型**（`int`/`long`）形参做 ToNumber 宽松转换（`"5000"`→5000、
//! `""`→0、`" 42 "`→42、`"0x10"`→16、`[5000]`→5000），NaN/Infinity/越界
//! /非数字串抛错；对 **装箱类型**（Kotlin 可空 `Int?`/`Long?` → JVM
//! `Integer`/`Long`）与 **布尔** 形参则严格（字符串/数字一律「方法不存在」）。
//!
//! 实测依据：`docs/materials_rhino_probe_20261006/probe_numeric_output.txt`
//! （原版引擎 JAR，JDK 17），完整转换表见
//! `docs/RHINO_STRING_PARAM_PROBE_20261006.md` 数值/布尔章节与
//! `host_api/coerce.rs` 模块文档。本测试锁定：
//! 1) 非空原始数值形参（`RhinoInt`/`RhinoLong`）：数字/字符串数字/数组/对象
//!    （ToString→ToNumber）按 Rhino 语义截断转换；NaN/Infinity/越界/非数字串
//!    /bool/undefined/null 抛错（与探针一致）；
//! 2) 可选数值形参（`RhinoOptInt`/`RhinoOptLong`）保留可选 arity（缺参 →
//!    None），显式 null/undefined → None，其余按 1) 宽松转换；
//! 3) 装箱数值（`connect` 的 `timeout_ms: Opt<i64>`，上游 `callTimeout: Long?`，
//!    JsExtensions.kt:214；jsHelp.md:212 的 `Int?` 系过时文档）
//!    与全部布尔形参**保持严格**（探针实测原版即抛错）——越权宽松化会引入
//!    原版没有的行为，本文件同时锁定这两类「不得变宽」。
//! 4) `java.ajax` 数组取首元素边界（探针 CASE 149-152）：`[]`/`[undefined]`
//!    /`[null]` 均收敛为 `"null"`（Kotlin `firstOrNull().toString()`），不抛
//!    转换错误。

#![cfg(feature = "quickjs")]

use legado_js::engine::{JsEngine, QuickJsEngine};
use legado_js::sandbox::SandboxConfig;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

fn eval(engine: &QuickJsEngine, code: &str) -> Result<String, String> {
    JsEngine::eval(engine, code).map_err(|e| e.to_string())
}

fn eval_ok(engine: &QuickJsEngine, code: &str) -> String {
    eval(engine, code).unwrap_or_else(|e| panic!("`{code}` 应宽松转换成功，实际报错: {e}"))
}

fn assert_err(engine: &QuickJsEngine, code: &str) {
    if let Ok(out) = eval(engine, code) {
        panic!("`{code}` 应保持严格（原版 Rhino 同形抛错），实际返回: {out}");
    }
}

/// 非空原始 `long` 形参：字符串数字/浮点/空白/十六进制/对象按 Rhino ToNumber
/// 宽松转换并截断（探针 CASE 23-44、62-63、162-166）
#[test]
fn primitive_long_params_coerce_like_rhino() {
    let engine = production_engine();

    // timeFormat(time: Long)（上游 JsExtensions.kt:698 非空 Long）
    let base = eval_ok(&engine, "java.timeFormat(1730000000000)");
    assert_eq!(
        eval_ok(&engine, "java.timeFormat(\"1730000000000\")"),
        base,
        "字符串数字应经 ToNumber 转换（探针 CASE 24）"
    );
    assert_eq!(
        eval_ok(&engine, "java.timeFormat(\"1730000000000.7\")"),
        base,
        "字符串浮点应截断（探针 CASE 26/27）"
    );
    assert_eq!(
        eval_ok(&engine, "java.timeFormat(\" 1730000000000 \")"),
        base,
        "首尾空白应被 ToNumber 忽略（探针 CASE 35/166）"
    );
    assert_eq!(
        eval_ok(&engine, "java.timeFormat(\"0x10\")"),
        eval_ok(&engine, "java.timeFormat(16)"),
        "十六进制串应按 ToNumber 解析（探针 CASE 165）"
    );
    assert_eq!(
        eval_ok(&engine, "java.timeFormat(\"\")"),
        eval_ok(&engine, "java.timeFormat(0)"),
        "空串 ToNumber 为 0（探针 CASE 34）"
    );
    // 对象/数组经 ToString→ToNumber（探针 CASE 18/62/162-163）
    assert_eq!(
        eval_ok(
            &engine,
            "java.timeFormat({ toString: function () { return \"1730000000000\"; } })"
        ),
        base,
        "自定义 toString 对象应按探针 CASE 162 转换"
    );
    assert_eq!(
        eval_ok(&engine, "java.timeFormat([1730000000000])"),
        base,
        "单元素数组应按 ToString→ToNumber 转换（探针 CASE 40）"
    );

    // timeFormatUTC(time: Long, format, sh: Int)（上游 :686）
    let utc_base = eval_ok(
        &engine,
        "java.timeFormatUTC(1730000000000, \"yyyy-MM-dd\", 0)",
    );
    assert_eq!(
        eval_ok(
            &engine,
            "java.timeFormatUTC(\"1730000000000\", \"yyyy-MM-dd\", \"0\")"
        ),
        utc_base,
        "ts 与 sh 两个原始数值形参都应宽松（探针 CASE 24）"
    );

    // formatTime(ts, format)（宿主兼容 shim，模型同为原始 Long）
    let fmt_base = eval_ok(&engine, "java.formatTime(1730000000000, \"yyyy\")");
    assert_eq!(
        eval_ok(&engine, "java.formatTime(\"1730000000000\", \"yyyy\")"),
        fmt_base,
        "formatTime 的 ts 形参同样宽松"
    );

    // regExp(text, pattern, group: Int)（宿主兼容 shim，模型为原始 int）
    assert_eq!(
        eval_ok(&engine, "java.regExp(\"ab12cd\", \"(\\\\d+)\", \"1\")"),
        "12",
        "group 字符串数字应宽松（探针 CASE 2）"
    );

    // jsoup*N 的 i（模拟 Java Elements.get(int)，77读书 rows.get(i)）
    assert_eq!(
        eval_ok(
            &engine,
            "java.jsoupTextN(\"<div>a</div><div>b</div>\", \"div\", \"1\")"
        ),
        "b",
        "下标字符串数字应宽松（探针 CASE 2）"
    );

    // threadSleep/sleep（模型 java.lang.Thread.sleep(long)）
    assert_eq!(
        eval_ok(&engine, "String(java.threadSleep(\"0\"))"),
        "undefined",
        "threadSleep 字符串数字应宽松转换后正常返回"
    );
    assert_eq!(
        eval_ok(&engine, "String(java.sleep(\"0\"))"),
        "undefined",
        "sleep 字符串数字应宽松转换后正常返回"
    );

    // lock(name, timeoutMs: Long)（上游 :1270 非空 Long）
    assert_eq!(
        eval_ok(&engine, "java.lock(\"numeric-arg-lock-a\", \"0\")"),
        "true",
        "lock 的 timeoutMs 字符串数字应宽松（探针 CASE 24）"
    );

    // singleFlight(name, timeoutMs: Long, fJs)（上游 :1250 非空 Long）
    assert_eq!(
        eval_ok(
            &engine,
            "String(java.singleFlight(\"numeric-arg-sf-a\", \"0\", \"x\"))"
        ),
        "[flight:x]",
        "singleFlight 的 timeoutMs 字符串数字应宽松（探针 CASE 24）"
    );
}

/// 非空原始数值形参：NaN/Infinity/越界/非数字串/布尔/undefined/null 保持抛错
/// （探针 CASE 7-11/15-16/21/29-33/37-38/51-55）
#[test]
fn primitive_long_params_reject_non_numeric_like_rhino() {
    let engine = production_engine();
    for code in [
        "java.timeFormat(\"abc\")",
        "java.timeFormat(NaN)",
        "java.timeFormat(Infinity)",
        "java.timeFormat(1e30)",
        "java.timeFormat(true)",
        "java.timeFormat(null)",
        "java.timeFormat(undefined)",
        "java.regExp(\"ab12\", \"(\\\\d+)\", \"abc\")",
        "java.jsoupTextN(\"<div>a</div>\", \"div\", \"abc\")",
        "java.threadSleep(\"abc\")",
        "java.lock(\"numeric-arg-lock-c\", \"abc\")",
    ] {
        assert_err(&engine, code);
    }
}

/// 非空原始 `int` 形参：字符串数字宽松 + i32 越界抛错（探针 CASE 2/4/21-22）
#[test]
fn primitive_int_params_coerce_and_check_range() {
    let engine = production_engine();

    // base64DecodeToByteArray(str, flags: Int)（上游 :648）
    assert_eq!(
        eval_ok(
            &engine,
            "String(java.base64DecodeToByteArray(\"aGVsbG8=\", \"0\")[0])"
        ),
        "104",
        "flags 字符串数字应宽松转换（\"hello\" 首字节 104）"
    );
    // 1 参调用仍可选（上游另有 1 参重载 :641）
    assert_eq!(
        eval_ok(
            &engine,
            "String(java.base64DecodeToByteArray(\"aGVsbG8=\")[0])"
        ),
        "104",
        "flags 缺参应保持可选语义"
    );
    // i32 越界 → 抛错（探针 CASE 21-22：int 形参收 5000000000 报错）
    assert_err(
        &engine,
        "java.base64DecodeToByteArray(\"aGVsbG8=\", \"5000000000\")",
    );
    assert_err(&engine, "java.timeFormatUTC(0, \"yyyy\", \"5000000000\")");
}

/// P2-1 收口：i32 越界判定改为「先向零截断、再判截断值越界」（与上游
/// `NativeJavaObject.toInteger` 一致——字节码：`d > 0 ? floor(d) : ceil(d)`
/// 后比较 `[-2^31, 2^31-1]`），原版实测接受 `(i32::MAX, 2^31)` /
/// `(-2^31-1, i32::MIN)` 开区间内的浮点毫厘值；精确越界 `2147483648` /
/// `-2147483649` 仍抛错。
///
/// i64 对应边界（同法核对，无需改动）：上游域为 `[-2^63, 2^63-1024]`
/// （min 常量即 -2^63，max 为 2^63 以下最大可表示 f64），与本实现
/// `[-2^63, 2^63)` 在所有 f64 可表示值上等价——`2^63-1024` 与 `-2^63`
/// 均接受，`2^63`（含 `9223372036854775807` / `"9223372036854775806"`
/// 的舍入值）与 `-2^63-2048` 均抛错。
#[test]
fn truncation_then_range_check_matches_rhino_boundaries() {
    let engine = production_engine();

    // 正值毫厘区间 (i32::MAX, 2^31)：截断后落 i32::MAX，接受（改前误拒）
    assert_eq!(
        eval_ok(
            &engine,
            "String(java.base64DecodeToByteArray(\"aGVsbG8=\", 2147483647.5)[0])"
        ),
        "104",
        "2147483647.5 应向零截断为 2147483647 后接受（原版同形实测）"
    );
    assert_eq!(
        eval_ok(
            &engine,
            "String(java.base64DecodeToByteArray(\"aGVsbG8=\", \"2147483647.5\")[0])"
        ),
        "104",
        "字符串形态同样 ToNumber→截断后接受（探针 CASE 4 口径）"
    );

    // 负值毫厘区间 (-2^31-1, i32::MIN)：截断后落 i32::MIN，接受（改前误拒）
    assert_eq!(
        eval_ok(
            &engine,
            "String(cache.put(\"numeric-arg-bound-neg\", \"v\", -2147483648.5))"
        ),
        "true",
        "-2147483648.5 应向零截断为 -2147483648 后接受（saveTime<=0 仅内存）"
    );

    // 精确越界仍抛错（上界开区间 2^31、下界开区间 -2^31-1）
    assert_err(
        &engine,
        "java.base64DecodeToByteArray(\"aGVsbG8=\", 2147483648)",
    );
    assert_err(
        &engine,
        "java.base64DecodeToByteArray(\"aGVsbG8=\", \"2147483648\")",
    );
    assert_err(
        &engine,
        "java.base64DecodeToByteArray(\"aGVsbG8=\", -2147483649)",
    );

    // i64 对应边界：2^63-1024（最大可表示上界值）与 -2^63 接受；
    // 2^63 舍入值（字面量 9223372036854775807 / 字符串 9223372036854775806）
    // 抛错——与现状实现一致，此用例锁定不得回退。
    assert!(
        eval(&engine, "String(java.timeFormat(9223372036854774784))").is_ok(),
        "9223372036854774784（= 2^63-1024，最大可表示下界值）应接受转换"
    );
    assert!(
        eval(&engine, "String(java.timeFormat(-9223372036854775808))").is_ok(),
        "-9223372036854775808（= -2^63）应接受转换"
    );
    assert_err(&engine, "java.timeFormat(9223372036854775807)");
    assert_err(&engine, "java.timeFormat(\"9223372036854775806\")");
    assert_err(&engine, "java.timeFormat(-9223372036854777856)");
}

/// 可选数值形参（RhinoOptInt/RhinoOptLong）：缺参 → 缺省，显式 null/undefined
/// → 缺省，出现值按宽松转换（探针 CASE 24 + Kotlin `@JvmOverloads` 口径）
#[test]
fn optional_numeric_params_keep_arity_and_coerce_when_present() {
    let engine = production_engine();

    // cache.put(key, value, saveTime: Int = 0)（上游 CacheManager.kt:60）
    assert_eq!(
        eval_ok(&engine, "String(cache.put(\"numeric-arg-put-a\", \"v\"))"),
        "true",
        "saveTime 缺参应保持可选（Kotlin 默认 0）"
    );
    assert_eq!(
        eval_ok(
            &engine,
            "String(cache.put(\"numeric-arg-put-b\", \"v\", \"0\"))"
        ),
        "true",
        "saveTime 字符串数字应宽松"
    );
    assert_err(&engine, "cache.put(\"numeric-arg-put-c\", \"v\", \"abc\")");
    // P2-3 收口：saveTime 上游为原始 `Int`（CacheManager.kt:60；
    // WebCacheManager.put :172），i32 域外的 5e9 应与原版一致抛错
    //（改前 `RhinoOptLong` 按 i64 域误收）
    assert_err(
        &engine,
        "cache.put(\"numeric-arg-put-d\", \"v\", 5000000000)",
    );
    assert_err(
        &engine,
        "cache.put(\"numeric-arg-put-d\", \"v\", \"5000000000\")",
    );

    // webViewGetSource(..., cacheFirst?: Boolean, delayTime?: Long)（上游 :271
    // 重载 4/5/6 参，delayTime 非空 Long）
    assert!(
        eval(
            &engine,
            "String(java.webViewGetSource(null, null, null, \"re\", true, \"0\"))"
        )
        .is_ok(),
        "delayTime 字符串数字应宽松"
    );
    assert!(
        eval(
            &engine,
            "String(java.webViewGetSource(null, null, null, \"re\", true))"
        )
        .is_ok(),
        "delayTime 缺参应保持可选"
    );
    // cacheFirst 是布尔形参：字符串数字不得宽松（探针 CASE 120-125）
    assert_err(
        &engine,
        "java.webViewGetSource(null, null, null, \"re\", \"true\", \"0\")",
    );
}

/// 装箱数值与全部布尔形参保持严格——原版 Rhino 探针实测同形抛错，
/// 越权宽松化会引入原版不存在的行为（W4 边界）
#[test]
fn boxed_numeric_and_boolean_params_stay_strict() {
    let engine = production_engine();

    // connect(url, header, callTimeout: Long?)：上游 JsExtensions.kt:214 为
    // 可空 `Long?`（jsHelp.md:212 的 `Int?` 系过时文档）—
    // 探针 CASE 68/90：装箱 Integer/Long 收字符串 = 方法不存在。
    // 注：`java.connect` 有 JS 垫片（quickjs_impl RESPONSE_BRIDGE_JS），
    // 按上游 3 参形态 (url, header=null, timeout) 调用可直达原生第 5 参。
    assert_err(
        &engine,
        "java.connect(\"http://127.0.0.1:1/\", null, \"1000\")",
    );
    assert!(
        eval(
            &engine,
            "String(java.connect(\"http://127.0.0.1:1/\", null, 1000))"
        )
        .is_ok(),
        "数字实参应正常（连接失败按错误文本返回，不抛参数转换错误）"
    );

    // cache.get(key, onlyDisk?: Boolean)：上游 :108，(CASE 133-142) 数字/字符串不转布尔
    // 先写入（2 参 put，saveTime 缺参 → 默认 0），保证缓存用例自包含
    assert_eq!(
        eval_ok(
            &engine,
            "String(cache.put(\"numeric-arg-strict-a\", \"v\"))"
        ),
        "true",
        "前置写入应成功"
    );
    assert_eq!(
        eval_ok(&engine, "String(cache.get(\"numeric-arg-strict-a\", true))"),
        "v",
        "布尔实参应正常"
    );
    assert_err(&engine, "cache.get(\"numeric-arg-strict-a\", \"true\")");
    assert_err(&engine, "cache.get(\"numeric-arg-strict-a\", 1)");

    // openVideoPlayer(url, title, isFloat: Boolean)（上游 :343，CASE 116-124）
    assert!(
        eval(&engine, "String(java.openVideoPlayer(\"u\", \"t\", true))").is_ok(),
        "布尔实参应正常"
    );
    assert_err(&engine, "java.openVideoPlayer(\"u\", \"t\", \"true\")");
    assert_err(&engine, "java.openVideoPlayer(\"u\", \"t\", 1)");

    // queryTTF(data, useCache: Boolean) / replaceFont(..., filter: Boolean)
    // （上游 :1014/:1105；探针 CASE 116-124）
    assert_err(&engine, "java.queryTTF(\"x\", \"true\")");
    assert_err(&engine, "java.replaceFont(\"t\", \"a\", \"b\", \"true\")");

    // startBrowserAwait(url, title, refetchAfterSuccess: Boolean, html)
    // （上游 :368；探针 CASE 120-125）
    assert_err(&engine, "java.startBrowserAwait(\"u\", \"t\", \"true\")");
}

/// `java.ajax` 数组首元素边界（探针 CASE 149-152）：
/// `[]` / `[undefined]` / `[null]` 都收敛为 URL 字符串 `"null"`（Kotlin
/// `firstOrNull().toString()`），不抛参数转换错误；请求失败按既有
/// `[ERROR]` 文本返回。
#[test]
fn ajax_array_first_element_boundary_matches_probe() {
    let engine = production_engine();
    for code in [
        "String(java.ajax([]))",
        "String(java.ajax([undefined]))",
        "String(java.ajax([null]))",
    ] {
        let out = eval(&engine, code)
            .unwrap_or_else(|e| panic!("`{code}` 不应抛参数转换错误（首元素 → \"null\"）: {e}"));
        assert!(
            out.starts_with("[ERROR]"),
            "URL \"null\" 应进入请求失败路径（观测: {out}）"
        );
    }
}
