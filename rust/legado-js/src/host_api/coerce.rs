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
// 实测证据：docs/RHINO_STRING_PARAM_PROBE_20261006.md（原版引擎 JAR 探针）
//
// ---------------------------------------------------------------------------
// 数值 / 布尔形参（W4，2026-10-06）
//
// 原版 Rhino LiveConnect 对 Java 形参的宽松度**按声明类型分流**（JDK 17 探针
// `docs/materials_rhino_probe_20261006/probe_numeric_output.txt`，本模块
// [`RhinoInt`]/[`RhinoLong`] 只覆盖其中「非空原始类型」一列）：
//!
//! | JS 实参 | Java 原始 `int`/`long`（Kotlin 非空 `Int`/`Long`） | Java 装箱 `Integer`/`Long`（Kotlin 可空 `Int?`/`Long?`） | Java `boolean`/`Boolean` |
//! |---|---|---|---|
//! | `5000` | 5000 | 5000 | （不适用） |
//! | `"5000"` / `"5000.7"` | 5000（ToNumber 后截断） | **方法不存在（抛错）** | **方法不存在（抛错）** |
//! | `""` / `" 42 "` / `"1e3"` / `"0x10"` | 0 / 42 / 1000 / 16 | 同上抛错 | 同上抛错 |
//! | `5000.7` / `-5000.7` | 5000 / -5000（向零截断） | 5000 / -5000 | 同上抛错 |
//! | `true` / `false` | **方法不存在（抛错）** | **方法不存在** | true / false |
//! | `1` / `0` / `"true"` | 同上抛错 | 同上抛错 | **方法不存在（抛错）** |
//! | `[]` / `[5000]` / 自定义 `toString` 对象 | 0 / 5000 / 5000（ToString→ToNumber） | 方法不存在 | 方法不存在 |
//! | `[5000,6000]` / `{}` / `"abc"` | 抛错（"5000,6000"/"[object Object]" → NaN） | 方法不存在 | 方法不存在 |
//! | `NaN` / `Infinity` / `5000000000`（int 越界） | 抛错 | NaN/Infinity 抛错；越界抛错 | 方法不存在 |
//! | `undefined` | 方法不存在（抛错） | **方法不存在（抛错，不落 null）** | 方法不存在 |
//! | `null` | 方法不存在（抛错） | Java `null` | `Boolean` → Java `null`；`boolean` → 方法不存在 |
//!
//! 结论：只有**非空原始 `int`/`long`** 一列是「字符串数字宽松」；装箱数值
//! （本项目 `Opt<i32>`/`Opt<i64>` 所对应的上游可空类型）与布尔形参都严格。
//! 因此 [`RhinoInt`]/[`RhinoLong`] 仅用于上游非空原始类型形参；`Opt<i32>` /
//! `Opt<i64>` / `Opt<bool>`（如 `connect` 的 `callTimeout: Int?`、`cache.get`
//! 的 `onlyDisk: Boolean`）保持既有严格转换——越权宽松化会引入原版不存在的
//! 行为（探针同形在主基线抛「找不到方法」）。
//!
//! 注意 rquickjs 的 `i64::from_js` **不能**直接充当宽松转换：它只接受 JS
//! `number`（字符串拒绝，方向正确），但 `number_match_range` 对 `NaN` 的
//! 比较恒 false，会把 `NaN` 静默转成 0；本模块显式拒绝 NaN/Infinity/越界。

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

/// Rhino 数值转换的共同前置：`bool` / `undefined` / `null` 与 Rhino 同向抛错
/// （原版对原始数值形参报「找不到方法」），其余值走 QuickJS `JS_ToFloat64`
/// （= JS 规范 `ToNumber`：字符串数字/空白串/十六进制串/数组/自定义 toString
/// 对象均按探针实测转换），并显式拒绝 NaN / Infinity。
fn rhino_number_f64<'js>(
    ctx: &rquickjs::Ctx<'js>,
    value: &rquickjs::Value<'js>,
) -> rquickjs::Result<f64> {
    let value_type = value.type_of();
    if matches!(
        value_type,
        rquickjs::Type::Bool | rquickjs::Type::Undefined | rquickjs::Type::Null
    ) {
        return Err(rquickjs::Error::FromJs {
            from: value_type.as_str(),
            to: "number",
            message: Some(
                "Rhino LiveConnect: 布尔/undefined/null 不转入 Java 原始数值形参（原版同形报方法不存在）"
                    .to_string(),
            ),
        });
    }
    let n = rquickjs::Coerced::<f64>::from_js(ctx, value.clone())?.0;
    if !n.is_finite() {
        return Err(rquickjs::Error::FromJs {
            from: value_type.as_str(),
            to: "number",
            message: Some(
                "Rhino LiveConnect: NaN/Infinity 无法转换为 Java 整型（探针实测抛错）".to_string(),
            ),
        });
    }
    Ok(n)
}

/// Rhino 原始 `int` 形参（Kotlin 非空 `Int` → JVM `int`）
///
/// 宽松转换语义见模块文档数值/布尔表；字符串数字 → ToNumber 截断，
/// NaN/Infinity/越界/bool/undefined/null 抛错。
pub struct RhinoInt(pub i32);

impl<'js> rquickjs::FromJs<'js> for RhinoInt {
    fn from_js(ctx: &rquickjs::Ctx<'js>, value: rquickjs::Value<'js>) -> rquickjs::Result<Self> {
        let n = rhino_number_f64(ctx, &value)?;
        if n < i32::MIN as f64 || n > i32::MAX as f64 {
            return Err(rquickjs::Error::FromJs {
                from: value.type_of().as_str(),
                to: "java.lang.Integer",
                message: Some(format!(
                    "Rhino LiveConnect: {n} 超出 int 范围（探针实测抛错）"
                )),
            });
        }
        Ok(RhinoInt(n as i32))
    }
}

impl Deref for RhinoInt {
    type Target = i32;
    fn deref(&self) -> &i32 {
        &self.0
    }
}

/// Rhino 原始 `long` 形参（Kotlin 非空 `Long` → JVM `long`）
///
/// P0-A 的 `RhinoStr` 数值对应体；转换语义与 [`RhinoInt`] 相同，范围放宽到
/// i64（探针 CASE 43-44：`5000000000` 在 long 形参正常、在 int 形参抛错）。
pub struct RhinoLong(pub i64);

impl<'js> rquickjs::FromJs<'js> for RhinoLong {
    fn from_js(ctx: &rquickjs::Ctx<'js>, value: rquickjs::Value<'js>) -> rquickjs::Result<Self> {
        let n = rhino_number_f64(ctx, &value)?;
        // ±2^63（f64 可精确表示），上界取开区间：i64::MAX 不能被 f64 表示
        const I64_MIN_F64: f64 = -9_223_372_036_854_775_808.0;
        const I64_UPPER_EXCL_F64: f64 = 9_223_372_036_854_775_808.0;
        if !(I64_MIN_F64..I64_UPPER_EXCL_F64).contains(&n) {
            return Err(rquickjs::Error::FromJs {
                from: value.type_of().as_str(),
                to: "java.lang.Long",
                message: Some(format!(
                    "Rhino LiveConnect: {n} 超出 long 范围（探针实测抛错）"
                )),
            });
        }
        Ok(RhinoLong(n as i64))
    }
}

impl Deref for RhinoLong {
    type Target = i64;
    fn deref(&self) -> &i64 {
        &self.0
    }
}

/// Rhino 可空原始数值入参（`RhinoInt` 的 arity 可选版）
///
/// 只实现 [`rquickjs::function::FromParam`]（不复用 `FromJs` 走 blanket
/// impl）——`FromParam::param_requirement` 必须保持 `optional()` 语义，
/// 否则 JS 少传参数会报 arity 错误（同 [`RhinoOptStr`] 的注意项）。
/// `null` / `undefined` → `None`（本项目合并上游重载的既有先例；上游原始
/// `int` 形参收 `null` 是「方法不存在」，此处按缺省语义更宽容一侧登记）。
pub struct RhinoOptInt(pub Option<i32>);

impl<'js> rquickjs::function::FromParam<'js> for RhinoOptInt {
    fn param_requirement() -> rquickjs::function::ParamRequirement {
        rquickjs::function::ParamRequirement::optional()
    }

    fn from_param<'a>(
        params: &mut rquickjs::function::ParamsAccessor<'a, 'js>,
    ) -> rquickjs::Result<Self> {
        if params.is_empty() {
            return Ok(RhinoOptInt(None));
        }
        let ctx = params.ctx().clone();
        let value = params.arg();
        if value.is_undefined() || value.is_null() {
            return Ok(RhinoOptInt(None));
        }
        Ok(RhinoOptInt(Some(RhinoInt::from_js(&ctx, value)?.0)))
    }
}

impl Deref for RhinoOptInt {
    type Target = Option<i32>;
    fn deref(&self) -> &Option<i32> {
        &self.0
    }
}

/// Rhino 可空原始数值入参（`RhinoLong` 的 arity 可选版），语义同
/// [`RhinoOptInt`]。
pub struct RhinoOptLong(pub Option<i64>);

impl<'js> rquickjs::function::FromParam<'js> for RhinoOptLong {
    fn param_requirement() -> rquickjs::function::ParamRequirement {
        rquickjs::function::ParamRequirement::optional()
    }

    fn from_param<'a>(
        params: &mut rquickjs::function::ParamsAccessor<'a, 'js>,
    ) -> rquickjs::Result<Self> {
        if params.is_empty() {
            return Ok(RhinoOptLong(None));
        }
        let ctx = params.ctx().clone();
        let value = params.arg();
        if value.is_undefined() || value.is_null() {
            return Ok(RhinoOptLong(None));
        }
        Ok(RhinoOptLong(Some(RhinoLong::from_js(&ctx, value)?.0)))
    }
}

impl Deref for RhinoOptLong {
    type Target = Option<i64>;
    fn deref(&self) -> &Option<i64> {
        &self.0
    }
}
