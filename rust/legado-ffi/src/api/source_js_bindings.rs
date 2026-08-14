//! 书源 evalJS 上下文绑定（对标 Android `BaseSource.evalJS` bindings）

use legado_core::models::BookSource;
use legado_core::LegadoResult;

/// 从书源 jsLib 提取 `var host = [...];`（大灰狼等聚合源 explore 依赖）
pub fn extract_js_lib_host_decl(js_lib: &str) -> Option<String> {
    let trimmed = js_lib.trim();
    let start = trimmed.find("var host")?;
    let slice = &trimmed[start..];
    let bracket = slice.find('[')?;
    let mut depth = 0usize;
    for (i, ch) in slice[bracket..].char_indices() {
        match ch {
            '[' => depth += 1,
            ']' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    let end = bracket + i + 1;
                    let mut decl_end = end;
                    if slice[end..].starts_with(';') {
                        decl_end = end + 1;
                    }
                    return Some(slice[..decl_end].trim().to_string());
                }
            }
            _ => {}
        }
    }
    None
}


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

/// explore/callback 上下文加载 jsLib：完整 → QuickJS 前缀 → 仅 host 声明
#[cfg(feature = "quickjs")]
pub fn load_js_lib_for_explore(
    guard: &legado_js::QuickJsEngine,
    js_lib: Option<&str>,
) {
    use legado_js::JsEngine;

    let Some(lib) = js_lib.map(str::trim).filter(|s| !s.is_empty()) else {
        return;
    };

    // 聚合源 jsLib 常在尾部含 Rhino `Packages.*`，QuickJS 整文件解析失败会导致
    // 首部 `var host` 也不执行；explore 优先加载 QuickJS 兼容前缀。
    let prefix = js_lib_quickjs_prefix(lib);
    if !prefix.is_empty() {
        match guard.eval(&prefix) {
            Ok(_) => return,
            Err(e) => eprintln!("[explore] jsLib 前缀加载失败: {e}"),
        }
    }

    if guard.eval(lib).is_ok() {
        return;
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

/// host 兜底脚本：jsLib 全失败时尽量提供 `host[0]`
fn explore_host_fallback_script(source: &BookSource) -> String {
    if let Some(decl) = source
        .js_lib
        .as_deref()
        .and_then(extract_js_lib_host_decl)
    {
        return decl;
    }
    let url = source.book_source_url.trim();
    if url.starts_with("http://") || url.starts_with("https://") {
        format!("var host = [{url_json}];", url_json = serde_json::to_string(url).unwrap_or_default())
    } else {
        "var host = [];".to_string()
    }
}

/// 生成 explore / action / login 等书源 JS 的 source/java 绑定脚本
#[cfg(feature = "quickjs")]
pub fn book_source_js_setup_script(source: &BookSource) -> LegadoResult<String> {
    let tag = source.book_source_url.clone();
    let source_json = serde_json::to_string(source)?;
    let base_url_json = serde_json::to_string(&tag)?;
    let source_url_json = base_url_json.clone();
    let login_url_json = serde_json::to_string(&source.login_url.as_deref().unwrap_or(""))?;
    let host_fallback = explore_host_fallback_script(source);
    let info_map = crate::api::explore_info_map::snapshot(&tag).unwrap_or_default();
    let info_map_json = serde_json::to_string(&info_map).unwrap_or_else(|_| "{}".to_string());
    let login_header_seed = match crate::api::source_login_cache::get_login_header(&tag) {
        Some(h) => serde_json::to_string(&h)?,
        None => "null".to_string(),
    };
    let login_info_seed = match crate::api::source_login_cache::get_login_info(&tag) {
        Some(i) => serde_json::to_string(&i)?,
        None => "null".to_string(),
    };

    Ok(format!(
        r#"
var baseUrl = {base_url_json};
var sourceUrl = {source_url_json};
var loginUrl = {login_url_json};
var __srcData = {source_json};
var source = Object.assign({{}}, __srcData);
var sourceApi = source;

// 对齐 Android BaseSource.evalJS：cookie / cache 全局（explore 脚本常用 cookie.getCookie）
var cookie = {{
  getCookie: function(url, key) {{
    if (key === undefined || key === null || key === '') {{
      return java.getCookie(String(url));
    }}
    return java.getCookie(String(url), String(key));
  }},
  setCookie: function(url, value) {{ return java.setCookie(String(url), String(value)); }},
  clearCookies: function(url) {{ return java.clearCookies(String(url)); }}
}};
var cache = {{
  get: function(k) {{ return get(String(k)) || null; }},
  put: function(k, v) {{ put(String(k), String(v)); return v; }},
  remove: function(k) {{ removeVariable(String(k)); return true; }}
}};

function __sourceVarKey(k) {{ return 'v_' + baseUrl + '_' + k; }}
function __loginHeaderKey() {{ return 'loginHeader_' + baseUrl; }}
function __userInfoKey() {{ return 'userInfo_' + baseUrl; }}
function __sourceVariableKey() {{ return 'sourceVariable_' + baseUrl; }}

function __mountBookSourceApi(obj) {{
  obj.get = function(k) {{ return get(__sourceVarKey(k)) || ''; }};
  obj.put = function(k, v) {{ put(__sourceVarKey(k), String(v)); return v; }};
  obj.getVariable = function() {{ return get(__sourceVariableKey()) || ''; }};
  obj.setVariable = function(v) {{ setVariable(__sourceVariableKey(), String(v)); return v; }};
  obj.putVariable = function(v) {{ return obj.setVariable(v); }};

  obj.getLoginHeader = function() {{
    var v = get(__loginHeaderKey());
    return v ? String(v) : null;
  }};
  obj.putLoginHeader = function(header) {{
    put(__loginHeaderKey(), String(header));
    try {{
      var map = JSON.parse(String(header));
      var cookie = map.Cookie || map.cookie;
      if (cookie) {{ java.setCookie(baseUrl, String(cookie)); }}
    }} catch (e) {{}}
    return;
  }};
  obj.removeLoginHeader = function() {{ removeVariable(__loginHeaderKey()); }};
  obj.getLoginHeaderMap = function() {{
    var raw = obj.getLoginHeader();
    if (!raw) return null;
    try {{ return JSON.parse(raw); }} catch (e) {{ return null; }}
  }};

  obj.getLoginInfo = function() {{
    var v = get(__userInfoKey());
    return v ? String(v) : null;
  }};
  obj.putLoginInfo = function(info) {{
    put(__userInfoKey(), String(info));
    return true;
  }};
  obj.removeLoginInfo = function() {{ removeVariable(__userInfoKey()); }};
  obj.getLoginInfoMap = function() {{
    var data = {{}};
    var raw = obj.getLoginInfo();
    if (raw) {{
      try {{ data = JSON.parse(raw) || {{}}; }} catch (e) {{ data = {{}}; }}
    }}
    return {{
      get: function(k) {{ return data[k] || null; }},
      put: function(k, v) {{
        data[k] = String(v);
        obj.putLoginInfo(JSON.stringify(data));
        return v;
      }}
    }};
  }};

  obj.hasLogin = function() {{
    return !!(obj.loginUrl || obj.loginUi);
  }};

  obj.login = function() {{
    var lj = (obj.loginUrl || obj.login_url || '').trim();
    if (!lj) return;
    if (lj.indexOf('function') === 0) {{
      eval(lj);
      if (typeof login === 'function') return login.apply(obj);
      return;
    }}
    if (lj.indexOf('function login') >= 0) {{
      eval(lj);
      if (typeof login === 'function') return login.apply(obj);
      return;
    }}
    return eval(lj);
  }};

  obj.putConcurrent = function(v) {{ put('concurrentRate_' + baseUrl, String(v)); return v; }};
}}

__mountBookSourceApi(source);
__mountBookSourceApi(sourceApi);

// 对齐 Android evalJS：java = BookSource（保留宿主 java.connect 等，仅补齐书源方法）
if (typeof java === 'object' && java !== null) {{
  __mountBookSourceApi(java);
}}

// infoMap：可读写 Map（对标 Android InfoMap 实例）
var __infoData = {info_map_json};
var infoMap = new Proxy(__infoData, {{
  get: function(target, prop) {{
    if (prop === 'get') {{
      return function(k) {{ return target[k] || null; }};
    }}
    if (prop === 'put') {{
      return function(k, v) {{ target[k] = String(v); return v; }};
    }}
    if (prop === 'save' || prop === 'saveNow') {{
      return function() {{ return; }};
    }}
    if (typeof prop === 'symbol') return target[prop];
    return target[prop];
  }},
  set: function(target, prop, value) {{
    if (typeof prop === 'symbol') return false;
    target[prop] = String(value);
    return true;
  }}
}});

// 预置登录缓存（与 CacheManager 对齐）
var __loginHeaderSeed = {login_header_seed};
if (__loginHeaderSeed) {{
  put(__loginHeaderKey(), String(__loginHeaderSeed));
}}
var __loginInfoSeed = {login_info_seed};
if (__loginInfoSeed) {{
  put(__userInfoKey(), String(__loginInfoSeed));
}}

// 大灰狼等聚合源：host 定义在 jsLib；若 jsLib 未成功加载则注入提取的 host 数组
if (typeof host === 'undefined') {{
  {host_fallback}
}}

// jsLib setArguments uses Rhino this.source
if (typeof setArguments === 'function') {{
  var __legadoSetArguments = setArguments;
  setArguments = function(key, value) {{
    return __legadoSetArguments.call({{ source: source, cookie: cookie, java: java }}, key, value);
  }};
}}
"#,
        base_url_json = base_url_json,
        source_url_json = source_url_json,
        login_url_json = login_url_json,
        source_json = source_json,
        info_map_json = info_map_json,
        login_header_seed = login_header_seed,
        login_info_seed = login_info_seed,
        host_fallback = host_fallback,
    ))
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
}

#[cfg(not(feature = "quickjs"))]
pub fn book_source_js_setup_script(_source: &BookSource) -> LegadoResult<String> {
    Ok(String::new())
}
