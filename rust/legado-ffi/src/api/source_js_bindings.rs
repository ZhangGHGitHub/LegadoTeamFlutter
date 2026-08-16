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

/// 非严格模式执行 JS 代码（对齐 Android Rhino 的 this 语义）
///
/// rquickjs `ctx.eval` 为严格模式：脚本内定义的函数裸调用时
/// `this=undefined`，书山等聚合源 jsLib 函数常用 `let { source } = this`
/// 访问书源 → `Cannot convert undefined or null to object`。
/// 经 `new Function` 参数传入 + 函数体内 `eval` 执行：代码在**非严格**
/// 作用域定义/执行，裸调用函数 `this=globalThis`（var source/java 已挂
/// 全局）✅ — 发现页修复（书山聚合等聚合源 ERROR）
#[cfg(feature = "quickjs")]
pub fn eval_js_non_strict(
    guard: &legado_js::QuickJsEngine,
    code: &str,
) -> Result<String, String> {
    use legado_js::JsEngine;
    let encoded = serde_json::to_string(code).map_err(|e| e.to_string())?;
    let wrapped = format!("new Function('__legadoCode', 'eval(__legadoCode);')({encoded})");
    guard.eval(&wrapped).map_err(|e| e.to_string())
}

/// 移除 jsLib 中 Rhino 特有行（`importClass`/`importPackage`/`Packages.` 行首），
/// 使 QuickJS 可**完整**加载 jsLib 并保留全部函数定义（含截断点之后的
/// `getConfig`/`getServerHost` 等）— 发现页修复（书山聚合等聚合源 ERROR）
pub fn sanitize_js_lib_for_quickjs(js_lib: &str) -> String {
    let mut out = String::with_capacity(js_lib.len() + 64);
    for line in js_lib.lines() {
        let t = line.trim_start();
        if t.starts_with("importClass(")
            || t.starts_with("importPackage(")
            || t.starts_with("Packages.")
        {
            out.push_str("// [legado] Rhino 特有行已移除（QuickJS 兼容）\n");
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

/// explore/callback 上下文加载 jsLib：完整 → sanitize 后完整 → QuickJS 前缀 → 仅 host 声明
#[cfg(feature = "quickjs")]
pub fn load_js_lib_for_explore(
    guard: &legado_js::QuickJsEngine,
    js_lib: Option<&str>,
) {
    use legado_js::JsEngine;

    let Some(lib) = js_lib.map(str::trim).filter(|s| !s.is_empty()) else {
        return;
    };

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
  clearCookies: function(url) {{ return java.clearCookies(String(url)); }},
  removeCookie: function(url) {{ return java.removeCookie(String(url)); }}
}};
var cache = {{
  get: function(k) {{ return get(String(k)) || null; }},
  put: function(k, v) {{ put(String(k), String(v)); return v; }},
  remove: function(k) {{ removeVariable(String(k)); return true; }}
}};

// 对齐原版 getKey() = bookSourceUrl：登录缓存键用 sourceUrl 而非请求 baseUrl
//（书山 bookUrl 为 data: URI 或详情页 URL，与书源 URL 不同；此前用 baseUrl
// 导致 putLoginHeader 写入 loginHeader_<详情URL> 而读取 loginHeader_<书源URL>
// 错位 → getSecretKey 取不到 api_key → 正文密文）。— 书山正文修复
function __sourceVarKey(k) {{ return 'v_' + sourceUrl + '_' + k; }}
function __loginHeaderKey() {{ return 'loginHeader_' + sourceUrl; }}
function __userInfoKey() {{ return 'userInfo_' + sourceUrl; }}
function __sourceVariableKey() {{ return 'sourceVariable_' + sourceUrl; }}

function __mountBookSourceApi(obj) {{
  obj.get = function(k) {{ return get(__sourceVarKey(k)) || ''; }};
  // 对齐原版 BaseSource.getKey() = bookSourceUrl（新笔趣阁等源 searchUrl @js: 块用 source.getKey()）
  obj.getKey = function() {{ return sourceUrl; }};
  obj.getUrl = function() {{ return sourceUrl; }};
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
    // 对齐原版 Kotlin getLoginInfoMap(): MutableMap<String,String> ——
    // 直接返回真实对象（书山 login() 用 `loginInfo['邮箱']` 下标访问；
    // 此前返回 {{get,put}} 包装对象导致下标访问 undefined → 登录空凭据）
    data.get = function(k) {{ return this[k] ?? null; }};
    data.put = function(k, v) {{
      this[k] = String(v);
      obj.putLoginInfo(JSON.stringify(this));
      return v;
    }};
    return data;
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
  // 同步登录认证头到全局 Cookie（供 java.ajax 自动携带书山 X-Novel-Token 等）
  try {{
    var __lh = __loginHeaderSeed;
    if (typeof __lh === 'string') __lh = JSON.parse(__lh);
    if (__lh && typeof __lh === 'object') {{
      for (var __k in __lh) {{
        if (!Object.prototype.hasOwnProperty.call(__lh, __k)) continue;
        var __v = String(__lh[__k]);
        if (!__v) continue;
        var __lk = String(__k).toLowerCase();
        if (__lk === 'cookie') {{
          java.setCookie(baseUrl, __v);
        }} else if (__lk.indexOf('token') >= 0 || __lk.indexOf('session') >= 0 || __lk.indexOf('auth') >= 0) {{
          java.setCookie(baseUrl, __k + '=' + __v);
        }}
      }}
    }}
  }} catch (e) {{}}
}}
var __loginInfoSeed = {login_info_seed};
if (__loginInfoSeed) {{
  put(__userInfoKey(), String(__loginInfoSeed));
}}

// 执行书源 header 规则（对齐 Android BaseSource.getHeaderMap）：@js:/<js>
// 求值 → JSON 解析 → 写入全局请求头（java.putGlobalHeaders），java.ajax 自动
// 携带书山聚合固定 X-Novel-Token 等认证头（原版 AnalyzeUrl(source) 每次请求
// 都解析 header 规则；setup 阶段求值一次即可覆盖静态/登录态头）
try {{
  var __headerRule = String(source.header || '');
  var __headerJs = null;
  if (__headerRule.indexOf('@js:') === 0) {{
    __headerJs = __headerRule.substring(4);
  }} else if (__headerRule.indexOf('<js>') === 0) {{
    var __hend = __headerRule.lastIndexOf('<');
    __headerJs = __hend > 4 ? __headerRule.substring(4, __hend) : __headerRule.substring(4);
  }}
  if (__headerJs) {{
    var __headerFn = new Function('return (' + __headerJs + ');');
    var __headerResult = __headerFn.call({{ source: source, cookie: cookie, java: java }});
    var __headerJson = String(__headerResult);
    var __headerMap = JSON.parse(__headerJson);
    if (__headerMap && typeof __headerMap === 'object') {{
      java.putGlobalHeaders(__headerJson);
    }}
  }} else if (__headerRule) {{
    var __hmap = JSON.parse(__headerRule);
    if (__hmap && typeof __hmap === 'object') {{
      java.putGlobalHeaders(__headerRule);
    }}
  }}
}} catch (__he) {{}}

// 大灰狼等聚合源：host 定义在 jsLib；若 jsLib 未成功加载则注入提取的 host 数组
if (typeof host === 'undefined') {{
  {host_fallback}
}}

// 对齐 Android evalJS 顶层 this（Rhino ScriptableObject 含 source/cookie/java）：
// 书山聚合等 jsLib 函数 `let {{java, source, cookie}} = this` 解构全局 this
// （QuickJS 非严格模式 = globalThis）；仅挂载局部变量时解构得 undefined →
// getSecretKey() 取不到 loginHeader → X-Api-Key 空 → 正文密文。— 书山正文修复
globalThis.source = source;
globalThis.cookie = cookie;
globalThis.java = java;
globalThis.sourceApi = sourceApi;

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

    /// sanitize 应移除 Rhino 特有行但保留全部函数定义（含 Packages 行之后的
    /// getConfig 等）— 发现页修复（书山聚合等聚合源 ERROR）
    #[test]
    fn test_sanitize_js_lib_keeps_functions_after_packages() {
        let lib = "var host = [];\nimportClass(Packages.java.util.HashMap);\nfunction getConfig(){return {};}\nfunction getServerHost(){return 'https://a.test';}\n";
        let cleaned = sanitize_js_lib_for_quickjs(lib);
        assert!(!cleaned.contains("importClass"), "Rhino importClass 行应移除");
        assert!(cleaned.contains("function getConfig"), "getConfig 定义应保留");
        assert!(cleaned.contains("function getServerHost"), "getServerHost 定义应保留");
        assert!(cleaned.contains("var host"), "host 声明应保留");
    }
}

#[cfg(not(feature = "quickjs"))]
pub fn book_source_js_setup_script(_source: &BookSource) -> LegadoResult<String> {
    Ok(String::new())
}
