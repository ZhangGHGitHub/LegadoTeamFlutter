//! 宿主 API 入参「Rhino LiveConnect 宽松转换」回归测试（quickjs 档）
//!
//! 背景（iOS 实机搜索失败分析 2026-10-06，3 号晋江文学）：
//! 书源 `java.ajaxAll(urls)`（`urls` 为 JS 数组）在 rquickjs 宿主函数
//! 严格 `String`/`Array` 入参签名下抛
//! `Error converting from js 'array' into type 'string'`，整条列表解析失败；
//! 原版 Rhino LiveConnect 对 Java/Kotlin 形参做宽松转换，同样的调用不报错。
//!
//! 语义以原版实际引擎（`third_party/maven/.../htmlunit-core-js-5.3.0-legado.4.jar`）
//! 探针实测为准，完整转换表见 `host_api/coerce.rs` 模块文档。本测试锁定：
//! 1) 数组专用入参（上游 `Array<String>`：ajaxAll / ajaxTestAll）：
//!    数组 → 元素逐项 JS ToString；空数组 → 空列表；null/undefined → 空列表；
//! 2) 标量 `String` 入参：数组 → `join(',')`、嵌套数组 → 递归 toString、
//!    对象 → `"[object Object]"`、自定义 toString、数字字面量、
//!    `undefined → "undefined"`、`null → "null"`；
//! 3) 可空 `String` 入参（`RhinoOptStr`）：null/undefined → 缺省（None）。

#![cfg(feature = "quickjs")]

use legado_js::engine::{JsEngine, QuickJsEngine};
use legado_js::host_api::current_source;
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

/// 晋江文学 bookList JS（`js_code` 前两个空行 → `java.ajaxAll(urls)` 在
/// 第 10 行 26 列，与 iOS 实机报错行号一致）数组入参形态回归：
/// 修复前 `Error converting from js 'array' into type 'string'`，修复后正常收敛。
#[test]
fn jinjiang_booklist_ajax_all_array_arg_accepts_array() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.jinjiang-ajaxall", || {
        // 与实机完全同形的调用点（空数组避免真实网络；仅验证入参收敛）
        let script = "\n\nlet urls = [];\nlet htmls = java.ajaxAll(urls);\nhtmls";
        let out = JsEngine::eval(&engine, script).unwrap_or_else(|e| {
            panic!("数组入参不应再抛转换错误（实机根因回归）: {e}");
        });
        assert_eq!(out, "[]", "空数组应收敛为空列表 JSON 文本，观测: {out}");
    });
}

/// null / undefined 入参 → 空（不在宿主边界报类型错误）
#[test]
fn ajax_all_null_and_undefined_coerce_to_empty_list() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.ajaxall-null", || {
        let null_out = JsEngine::eval(&engine, "java.ajaxAll(null)")
            .expect("null 入参应宽松收敛（不再抛转换错误）");
        assert_eq!(null_out, "[]", "null 应收敛为空列表；观测: {null_out}");

        let undef_out = JsEngine::eval(&engine, "java.ajaxAll(undefined)")
            .expect("undefined 入参应宽松收敛（不再抛转换错误）");
        assert_eq!(
            undef_out, "[]",
            "undefined 应收敛为空列表；观测: {undef_out}"
        );
    });
}

/// 数组元素按 JS ToString 收敛（对齐 Rhino LiveConnect 元素级转换）：
/// int/bool 元素 → "1"/"false"（`ajaxTestAll` 不发起真实请求：非法 URL
/// 逐条失败为 statusCode 0）
#[test]
fn ajax_test_all_array_elements_coerce_via_to_string() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.ajaxtestall", || {
        let out = JsEngine::eval(&engine, "java.ajaxTestAll([1, false])")
            .unwrap_or_else(|e| panic!("数组元素应逐项 ToString 收敛: {e}"));
        assert!(
            out.contains("\"url\":\"1\""),
            "int 元素应按 JS 语义转为 \"1\"；观测: {out}"
        );
        assert!(
            out.contains("\"url\":\"false\""),
            "bool 元素应按 JS 语义转为 \"false\"；观测: {out}"
        );
    });
}

/// 标量 `String` 入参宽松转换（3 号缺陷面）：数组/对象/数字/布尔/
/// undefined/null 一律按 Rhino 实测语义转换，不再抛 `converting from js`
///
/// 注：测试刻意选**无 JS 层包装**的宿主 API（`substringBefore/After`、
/// `encodeURI`）——`md5Encode`/`digestHex` 被小小阅读契约的 JS 包装先做了
/// `String()` 强转，红绿区分不出宿主边界（其宽松性另有 `md5Encode` 测试锁定）。
#[test]
fn scalar_string_params_coerce_js_values_like_rhino() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.loose-str", || {
        // (表达式, 期望值, 语义说明)
        let cases = [
            (
                "java.substringBefore(['a','b','c'], ',c')",
                "a,b",
                "数组 → join(',') = \"a,b,c\"（3 号实机同级形态）",
            ),
            (
                "java.substringAfter([[1,2],[3]], ',')",
                "2,3",
                "嵌套数组 → 递归 toString = \"1,2,3\"",
            ),
            (
                "java.substringBefore({a:1}, ' ')",
                "[object",
                "对象 → \"[object Object]\"（探针实测）",
            ),
            (
                "java.substringBefore({toString:function(){return 'custom-x';}}, '-')",
                "custom",
                "自定义 toString → 调用其 toString()",
            ),
            ("java.substringBefore(123, '2')", "1", "数字 → \"123\""),
            ("java.substringBefore(true, 'r')", "t", "布尔 → \"true\""),
            (
                "java.substringAfter(undefined, 'defin')",
                "ed",
                "undefined → \"undefined\"（探针实测）",
            ),
            (
                "java.substringAfter(null, 'nu')",
                "ll",
                "null → \"null\"（Coerced 先例；Rhino 实测为 Java null，见 coerce.rs 偏差说明）",
            ),
        ];
        for (expr, expect, why) in cases {
            let out = JsEngine::eval(&engine, expr).unwrap_or_else(|e| {
                panic!("{expr} 不得抛入参转换错误（{why}）: {e}");
            });
            assert_eq!(out, expect, "{expr}（{why}）");
        }
    });
}

/// 可空 `String` 入参（RhinoOptStr）：null/undefined → 缺省；同时覆盖
/// 同一次调用里标量入参为数组的宽松转换
#[test]
fn optional_string_param_null_and_array_coerce() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.loose-opt-str", || {
        // encodeURI(s, enc?)：enc 省略 → UTF-8 默认编码；数组 s → "a,b"
        let out = JsEngine::eval(&engine, "java.encodeURI(['a','b'], undefined)")
            .expect("数组 + undefined 可空参不得抛转换错误");
        assert_eq!(out, "a%2Cb", "数组应转 \"a,b\" 后编码；观测: {out}");

        let out_null = JsEngine::eval(&engine, "java.encodeURI(['a','b'], null)")
            .expect("显式 null 可空参不得抛转换错误");
        assert_eq!(out_null, "a%2Cb", "null 应视为缺省；观测: {out_null}");
    });
}
