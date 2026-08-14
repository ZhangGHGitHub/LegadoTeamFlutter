//! 书源 evalJS 上下文绑定（对标 Android `BaseSource.evalJS` bindings）

use legado_core::models::BookSource;
use legado_core::LegadoResult;

/// 生成 explore / action / login 等书源 JS 的 source/java 绑定脚本
#[cfg(feature = "quickjs")]
pub fn book_source_js_setup_script(source: &BookSource) -> LegadoResult<String> {
    let tag = source.book_source_url.clone();
    let source_json = serde_json::to_string(source)?;
    let base_url_json = serde_json::to_string(&tag)?;
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
var __srcData = {source_json};
var source = Object.assign({{}}, __srcData);
var sourceApi = source;

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
"#,
        base_url_json = base_url_json,
        source_json = source_json,
        info_map_json = info_map_json,
        login_header_seed = login_header_seed,
        login_info_seed = login_info_seed,
    ))
}

#[cfg(not(feature = "quickjs"))]
pub fn book_source_js_setup_script(_source: &BookSource) -> LegadoResult<String> {
    Ok(String::new())
}
