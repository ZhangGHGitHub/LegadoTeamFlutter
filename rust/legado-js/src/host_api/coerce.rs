//! 宿主 API 入参的 Rhino LiveConnect 宽松转换
//!
//! 背景（iOS 实机搜索失败分析 2026-10-06，P0-A / 3 号晋江文学）：
//! rquickjs 对宿主函数 `String` 入参做**严格**类型检查，JS 数组/对象/数字
//! 一律抛 `Error converting from js 'array' into type 'string'`；原版
//! Android 走 Rhino LiveConnect，对 Java/Kotlin `String` 形参按
//! `ScriptRuntime.toString` 宽松转换，同样的调用不报错。
//!
//! 转换语义以原版实际引擎（HtmlUnit core-js，`third_party/maven/` 内
//! `htmlunit-core-js-5.3.0-legado.4.jar`）探针实测为准（2026-10-06，JDK 17
//! `Context.javaToJS` 包装对象 + `evaluateString` 调用 `String` 形参方法）：
//!
//! | JS 实参 | Rhino 传入 Java `String` 形参 |
//! |---|---|
//! | `[1,2,3]` / `['a','b']` | `"1,2,3"` / `"a,b"`（数组 `join(',')` 语义） |
//! | `[]` | `""` |
//! | `[[1,2],[3]]` | `"1,2,3"`（递归 toString） |
//! | `{a:1}` | `"[object Object]"` |
//! | 自定义 `toString` 对象 | 调用其 `toString()` |
//! | `123` / `1.5` / `true` | `"123"` / `"1.5"` / `"true"` |
//! | `undefined` | `"undefined"` |
//! | `null` | Java `null`（Kotlin 非空形参 → NPE；可空形参 → null） |
//! | 缺参 | 方法不存在（arity 错误，非本类型职责） |
//!
//! 实现映射：标量入参 `RhinoStr` 采用 JS `ToString`（`Coerced<String>`），
//! 与既有 `encodeURIComponent` 修复同源（`tests/uri_component_coercion.rs`
//! 已锁定 `null → "null"` / `undefined → "undefined"`）。唯一与探针的偏差：
//! 探针中 `null` 传给 Java 形参变为 Java `null`（Kotlin 非空形参随后 NPE），
//! 而本实现与 `encodeURIComponent` 一致取 JS 字符串 `"null"`——Rust 侧无法
//! 复现 Kotlin 的 NPE 语义，取 JS 规范字符串化作为确定性替代。
//!
//! 可空入参 `RhinoOptStr` 保持既有 `NullStr` / `Opt<String>` 先例：
//! `null` / `undefined` → `None`（语料 `java.webView(null, url, null)` 依赖），
//! 其余值按 `RhinoStr` 同口径宽松转换后包 `Some`。
//!
//! 数组专用入参（上游 Kotlin `Array<String>`，如 `ajaxAll` / `ajaxTestAll`）
//! 语义不同：数组元素逐项转换，见 `quickjs_impl::LooseStrList`。

use std::ops::Deref;

use rquickjs::FromJs as _;

/// Rhino LiveConnect 标量 `String` 入参（JS `ToString` 宽松转换）
///
/// 用法与 `String` 等价（`Deref<Target = String>`），需要取所有权时用 `.0`。
pub struct RhinoStr(pub String);

impl<'js> rquickjs::FromJs<'js> for RhinoStr {
    fn from_js(ctx: &rquickjs::Ctx<'js>, value: rquickjs::Value<'js>) -> rquickjs::Result<Self> {
        Ok(RhinoStr(
            rquickjs::Coerced::<String>::from_js(ctx, value)?.0,
        ))
    }
}

impl Deref for RhinoStr {
    type Target = String;
    fn deref(&self) -> &String {
        &self.0
    }
}

impl std::fmt::Display for RhinoStr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

/// Rhino LiveConnect 可空 `String` 入参（`null` / `undefined` → `None`，
/// 其余按 JS `ToString` 宽松转换）
///
/// 用法与 `Option<String>` 等价（`Deref<Target = Option<String>>`），
/// 需要按值消费 Option 时用 `.0`。
///
/// 注意：只实现 [`rquickjs::function::FromParam`]（不复用 `FromJs` 走 blanket
/// impl）——`FromParam::param_requirement` 必须保持 `optional()` 语义，
/// 否则 JS 少传参数会报
/// `Error calling function with 1 argument(s) while 2 where expected`
/// （原 `Opt<String>` 的可选语义丢失，26 个既有 API 回归）。
pub struct RhinoOptStr(pub Option<String>);

impl<'js> rquickjs::function::FromParam<'js> for RhinoOptStr {
    fn param_requirement() -> rquickjs::function::ParamRequirement {
        rquickjs::function::ParamRequirement::optional()
    }

    fn from_param<'a>(
        params: &mut rquickjs::function::ParamsAccessor<'a, 'js>,
    ) -> rquickjs::Result<Self> {
        if params.is_empty() {
            return Ok(RhinoOptStr(None));
        }
        let ctx = params.ctx().clone();
        let value = params.arg();
        if value.is_undefined() || value.is_null() {
            return Ok(RhinoOptStr(None));
        }
        Ok(RhinoOptStr(Some(
            rquickjs::Coerced::<String>::from_js(&ctx, value)?.0,
        )))
    }
}

impl Deref for RhinoOptStr {
    type Target = Option<String>;
    fn deref(&self) -> &Option<String> {
        &self.0
    }
}
