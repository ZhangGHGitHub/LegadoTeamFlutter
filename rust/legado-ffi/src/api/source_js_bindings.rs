//! 书源 evalJS 上下文绑定（对标 Android `BaseSource.evalJS` bindings）

use legado_core::models::BookSource;
use legado_core::LegadoResult;

/// 从书源 jsLib 提取 `var host = [...];`（大灰狼等聚合源 explore 依赖）
///
/// [P5 尾项] 实现已平移 `legado_fetcher::js_adapter`（共享 crate 单一实现），
/// 本处保留同名 re-export（本模块内部调用与 ffi 调用方零改动）。
pub use legado_fetcher::js_adapter::extract_js_lib_host_decl;

/// 截断未闭合的 `{`：Rhino 标记常落在函数体中间，整段 eval 会语法失败
fn trim_js_to_balanced_prefix(s: &str) -> String {
    let mut depth = 0i32;
    let mut last_good = 0usize;
    for (i, ch) in s.char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    last_good = i + ch.len_utf8();
                }
            }
            _ => {}
        }
    }
    let trimmed = s.trim();
    if depth != 0 && last_good > 0 {
        trimmed[..last_good.min(trimmed.len())].trim().to_string()
    } else {
        trimmed.to_string()
    }
}

/// 截取 jsLib 中 QuickJS 可执行的前缀（遇 Rhino `Packages`/`importClass` 行即截断）
pub fn js_lib_quickjs_prefix(js_lib: &str) -> String {
    let markers = ["Packages.", "importClass(", "importPackage("];
    let mut cut = js_lib.len();
    for marker in markers {
        if let Some(idx) = js_lib.find(marker) {
            let line_start = js_lib[..idx].rfind('\n').map(|i| i + 1).unwrap_or(0);
            cut = cut.min(line_start);
        }
    }
    if cut >= js_lib.len() {
        return trim_js_to_balanced_prefix(js_lib);
    }
    trim_js_to_balanced_prefix(&js_lib[..cut])
}

/// explore 降级：host 声明 + 前缀内全部顶层函数（至 Rhino 行之前）
pub fn js_lib_explore_fallback(js_lib: &str) -> String {
    let mut parts = Vec::new();
    if let Some(host) = extract_js_lib_host_decl(js_lib) {
        parts.push(host);
    }
    let prefix = js_lib_quickjs_prefix(js_lib);
    if !prefix.is_empty() {
        parts.push(prefix);
    }
    parts.join("\n")
}

/// 非严格模式执行 JS 代码（对齐 Android Rhino 的 this 语义）
///
/// rquickjs `ctx.eval` 为严格模式：脚本内定义的函数裸调用时
/// `this=undefined`，书山等聚合源 jsLib 函数常用 `let { source } = this`
/// 访问书源 → `Cannot convert undefined or null to object`。
/// 经 `new Function` 参数传入 + 函数体内 `eval` 执行：代码在**非严格**
/// 作用域定义/执行，裸调用函数 `this=globalThis`（var source/java 已挂
/// 全局）✅ — 发现页修复（书山聚合等聚合源 ERROR）
#[cfg(feature = "quickjs")]
pub fn eval_js_non_strict(guard: &legado_js::QuickJsEngine, code: &str) -> Result<String, String> {
    use legado_js::JsEngine;
    let encoded = serde_json::to_string(code).map_err(|e| e.to_string())?;
    let wrapped = format!("new Function('__legadoCode', 'eval(__legadoCode);')({encoded})");
    guard.eval(&wrapped).map_err(|e| e.to_string())
}

/// 移除 jsLib 中 Rhino 特有行（`importClass`/`importPackage`/`Packages.` 行首），
/// 使 QuickJS 可**完整**加载 jsLib 并保留全部函数定义（含截断点之后的
/// `getConfig`/`getServerHost` 等）— 发现页修复（书山聚合等聚合源 ERROR）
///
/// P5 子批 2a：实现已随迁 `legado_fetcher::js_adapter`（共享 crate 单一实现），
/// 本处保留同名 re-export（本模块内部调用与 ffi 调用方零改动）。
pub use legado_fetcher::js_adapter::sanitize_js_lib_for_quickjs;

/// explore/callback 上下文加载 jsLib：URL 映射（cap 3）→ 完整 → sanitize 后完整 →
/// QuickJS 前缀 → 仅 host 声明
///
/// `source_tag` 用于 URL 映射拉取失败的台账键（`explore:{source_tag}`，与
/// 执行器路径 `executor:{source_tag}` 同构）
#[cfg(feature = "quickjs")]
pub fn load_js_lib_for_explore(
    guard: &legado_js::QuickJsEngine,
    source_tag: &str,
    js_lib: Option<&str>,
) {
    use legado_js::JsEngine;

    let Some(lib) = js_lib.map(str::trim).filter(|s| !s.is_empty()) else {
        return;
    };

    // 0) cap 3（URL 映射 jsLib）：经加载器解析（共享客户端拉取 + 进程缓存 +
    //    逐条降级台账登记）→ eval 拼接脚本；非 URL 映射形态走下列原始级联
    let is_url_map = legado_js::host_api::jslib_loader::parse_js_lib_url_map(lib).is_some();
    if is_url_map {
        let ledger_tag = format!("explore:{}", source_tag);
        match legado_js::host_api::jslib_loader::resolve_js_lib_url_map(
            lib,
            &ledger_tag,
            &legado_js::host_api::jslib_loader::default_js_lib_fetcher,
        ) {
            Some(script) => {
                if guard.eval(&script).is_ok() {
                    return;
                }
                eprintln!("[explore] URL 映射 jsLib eval 失败（降级继续）");
            }
            // 全条拉取失败：加载器内已逐条记台账（上游「下载jsLib-…失败」措辞）
            None => eprintln!(
                "[explore] 书源 {source_tag} URL 映射 jsLib 全条拉取失败（台账已登记，降级继续）"
            ),
        }
        // URL 映射形态不回退原始级联（原始 JSON 非合法 JS，级联只会重复失败）
        return;
    }

    // 1) 完整 jsLib（引擎 eval 已非严格：全局可见 + 函数裸调用 this=globalThis，
    //    对齐 Rhino 语义；书山等聚合源函数 `let { source } = this` 可用）
    if guard.eval(lib).is_ok() {
        return;
    }

    // 2) 移除 Rhino 特有行后完整加载：聚合源 jsLib 尾部常含 `Packages.*`，
    //    整文件解析失败导致首部变量也不执行；sanitize 后保留全部函数定义
    let sanitized = sanitize_js_lib_for_quickjs(lib);
    if !sanitized.trim().is_empty() && guard.eval(&sanitized).is_ok() {
        eprintln!("[explore] jsLib 完整加载失败，已 sanitize 后加载（保留函数定义）");
        return;
    }

    // 3) 前缀降级（host 声明 + 前缀内顶层函数）
    let prefix = js_lib_quickjs_prefix(lib);
    if !prefix.is_empty() {
        match guard.eval(&prefix) {
            Ok(_) => return,
            Err(e) => eprintln!("[explore] jsLib 前缀加载失败: {e}"),
        }
    }

    let fallback = js_lib_explore_fallback(lib);
    if !fallback.is_empty() && guard.eval(&fallback).is_ok() {
        eprintln!("[explore] jsLib 完整加载失败，已降级 explore 符号集");
        return;
    }

    if let Some(host_decl) = extract_js_lib_host_decl(lib) {
        if guard.eval(&host_decl).is_ok() {
            eprintln!("[explore] jsLib 完整加载失败，已预置 host 数组");
            return;
        }
    }

    eprintln!("[explore] jsLib 加载失败（降级继续）");
}

/// 生成 explore / action / login 等书源 JS 的 source/java 绑定脚本
///
/// [P5 尾项] 脚本生成实现已平移 `legado_fetcher::source_setup`（共享 crate
/// 单一实现）；本层保留宿主数据装配（explore infoMap 快照 + 登录缓存）与
/// 同名签名，ffi 调用方零改动。
#[cfg(feature = "quickjs")]
pub fn book_source_js_setup_script(source: &BookSource) -> LegadoResult<String> {
    let tag = source.book_source_url.clone();
    let info_map = crate::api::explore_info_map::snapshot(&tag).unwrap_or_default();
    let login_header = crate::api::source_login_cache::get_login_header(&tag);
    let login_info = crate::api::source_login_cache::get_login_info(&tag);
    legado_fetcher::source_setup::book_source_js_setup_script(
        source,
        &info_map,
        login_header.as_deref(),
        login_info.as_deref(),
    )
}

#[cfg(not(feature = "quickjs"))]
pub fn book_source_js_setup_script(_source: &BookSource) -> LegadoResult<String> {
    Ok(String::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_js_lib_host_decl() {
        let lib = r#"var host = ['https://a.test', 'https://b.test'];
function foo() { return host[0]; }"#;
        let decl = extract_js_lib_host_decl(lib).unwrap();
        assert!(decl.starts_with("var host = ["));
        assert!(decl.contains("https://a.test"));
    }

    #[test]
    fn test_js_lib_quickjs_prefix_trims_packages() {
        let lib = "var host = [1];\nfunction ok(){}\nnew Packages.foo.Bar();\nvar x=1;";
        let prefix = js_lib_quickjs_prefix(lib);
        assert!(prefix.contains("var host"));
        assert!(!prefix.contains("Packages"));
    }

    #[test]
    fn test_js_lib_quickjs_prefix_balanced_when_packages_inside_function() {
        let lib = "var host = [1];\nfunction ok() { return 1; }\nfunction bad() {\n  new Packages.foo();\n}\nvar tail=1;";
        let prefix = js_lib_quickjs_prefix(lib);
        assert!(prefix.contains("function ok"));
        assert!(!prefix.contains("Packages"));
        assert!(!prefix.contains("function bad"));
    }

    /// sanitize 应移除 Rhino 特有行但保留全部函数定义（含 Packages 行之后的
    /// getConfig 等）— 发现页修复（书山聚合等聚合源 ERROR）
    #[test]
    fn test_sanitize_js_lib_keeps_functions_after_packages() {
        let lib = "var host = [];\nimportClass(Packages.java.util.HashMap);\nfunction getConfig(){return {};}\nfunction getServerHost(){return 'https://a.test';}\n";
        let cleaned = sanitize_js_lib_for_quickjs(lib);
        assert!(
            !cleaned.contains("importClass"),
            "Rhino importClass 行应移除"
        );
        assert!(
            cleaned.contains("function getConfig"),
            "getConfig 定义应保留"
        );
        assert!(
            cleaned.contains("function getServerHost"),
            "getServerHost 定义应保留"
        );
        assert!(cleaned.contains("var host"), "host 声明应保留");
    }
}
