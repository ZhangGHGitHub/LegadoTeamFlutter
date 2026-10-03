//! 书源 JS 上下文 setup 脚本生成（P5 尾项：自
//! `legado-ffi/src/api/source_js_bindings.rs` 平移的纯格式化实现）
//!
//! 生成 `globalThis.source/baseUrl/loginUrl`、`__mountBookSourceApi`、
//! cookie/cache 绑定、infoMap 代理、登录缓存预置与 header 规则预求值等脚本，
//! 供执行器 `with_setup_script`（ffi/server 两宿主共用）在书源规则 JS 执行前
//! 注入。与 ffi 原实现逐字一致，差异仅在宿主数据改为入参注入：
//!
//! - `info_map`：explore infoMap 快照（ffi 查 `explore_info_map`，
//!   server 查 DB `caches` 键 `infoMap_<sourceUrl>`）；
//! - `login_header` / `login_info`：登录缓存（ffi 查 `source_login_cache`，
//!   server 查同一 DB 的 `loginHeader_<sourceUrl>` / `userInfo_<sourceUrl>` 键）。
//!
//! 函数本身不依赖 quickjs（纯字符串生成）；脚本的消费方（QuickJsExecutor /
//! 规则分析器）在未启用 quickjs 的构建下静默忽略，两档行为一致。

use std::collections::HashMap;

use legado_core::models::BookSource;
use legado_core::LegadoResult;

use crate::js_adapter::extract_js_lib_host_decl;

/// host 兜底脚本：jsLib 全失败时尽量提供 `host[0]`
fn explore_host_fallback_script(source: &BookSource) -> String {
    if let Some(decl) = source.js_lib.as_deref().and_then(extract_js_lib_host_decl) {
        return decl;
    }
    let url = source.book_source_url.trim();
    if url.starts_with("http://") || url.starts_with("https://") {
        format!(
            "globalThis.host = [{url_json}];",
            url_json = serde_json::to_string(url).unwrap_or_default()
        )
    } else {
        "globalThis.host = [];".to_string()
    }
}

/// 生成 explore / action / login 等书源 JS 的 source/java 绑定脚本
///
/// 宿主数据（infoMap / 登录缓存）由调用方查库后传入；见模块文档。
pub fn book_source_js_setup_script(
    source: &BookSource,
    info_map: &HashMap<String, String>,
    login_header: Option<&str>,
    login_info: Option<&str>,
) -> LegadoResult<String> {
    let tag = source.book_source_url.clone();
    let source_json = serde_json::to_string(source)?;
    let base_url_json = serde_json::to_string(&tag)?;
    let source_url_json = base_url_json.clone();
    let login_url_json = serde_json::to_string(&source.login_url.as_deref().unwrap_or(""))?;
    let host_fallback = explore_host_fallback_script(source);
    let info_map_json = serde_json::to_string(info_map).unwrap_or_else(|_| "{}".to_string());
    let login_header_seed = match login_header {
        Some(h) => serde_json::to_string(h)?,
        None => "null".to_string(),
    };
    let login_info_seed = match login_info {
        Some(i) => serde_json::to_string(i)?,
        None => "null".to_string(),
    };

    Ok(format!(
        r#"
// [能力对账批次 2 | #702/#850] 顶层 var → globalThis 属性注入：不注册 QuickJS
// 全局 var 条目，书源块顶层 `let baseUrl` 等不再触发 redeclaration（属性存在
// 对裸标识符读路径等价；写路径不变）
globalThis.baseUrl = {base_url_json};
globalThis.sourceUrl = {source_url_json};
globalThis.loginUrl = {login_url_json};
globalThis.__srcData = {source_json};
globalThis.source = Object.assign({{}}, __srcData);
globalThis.sourceApi = source;

// 对齐 Android BaseSource.evalJS：cookie / cache 全局（explore 脚本常用 cookie.getCookie）
globalThis.cookie = {{
  getCookie: function(url, key) {{
    if (key === undefined || key === null || key === '') {{
      return java.getCookie(String(url));
    }}
    return java.getCookie(String(url), String(key));
  }},
  // 对齐上游 CookieStore.getKey：按键读（域归属，miss → 空串不抛错）；
  // 无 key 形态返回全域串（上游 JsExtensions key 为 null 时取全串）
  getKey: function(url, key) {{
    if (key === undefined || key === null || key === '') {{
      return java.getCookie(String(url));
    }}
    return java.getCookie(String(url), String(key));
  }},
  setCookie: function(url, value) {{ return java.setCookie(String(url), String(value)); }},
  clearCookies: function(url) {{ return java.clearCookies(String(url)); }},
  removeCookie: function(url) {{ return java.removeCookie(String(url)); }},
  // 对齐上游 CookieStore.replaceCookie：现存域 cookie ∪ 新串（新值覆盖、
  // 旧键保留）后写回；空参 no-op — 3b-3（爱丽丝书屋）
  replaceCookie: function(url, value) {{ java.replaceCookie(String(url), String(value == null ? '' : value)); }},
  // 对齐上游 CookieStore.cookieToMap：';' 拆段 → 对象（键值 trim、空值段
  // 剔除、同名键覆盖）；宿主层返回 JSON 串，此处还原为对象 — 3b-3
  cookieToMap: function(str) {{
    try {{ return JSON.parse(java.cookieToMap(String(str == null ? '' : str))); }} catch (e) {{ return {{}}; }}
  }},
  // 对齐上游 CookieStore.mapToCookie：`k=v` 以 '; ' 连接；空/不可序列化
  // → null（上游返回 null；宿主层 Option.None → undefined，此处转 null）
  // — 3b-3
  mapToCookie: function(map) {{
    var json = (map === null || map === undefined) ? '' : (typeof map === 'string' ? map : JSON.stringify(map));
    if (!json) return null;
    var r = java.mapToCookie(json);
    return r === undefined ? null : r;
  }}
}};
globalThis.cache = {{
  get: function(k) {{ return get(String(k)) || null; }},
  put: function(k, v) {{ put(String(k), String(v)); return v; }},
  remove: function(k) {{ removeVariable(String(k)); return true; }},
  // 对齐上游 CacheManager memoryLruCache（WebCacheManager JS 面）：
  // 进程级内存缓存，与磁盘 cache 表 / 会话变量独立命名空间，无 TTL，
  // 跨书源共享（同进程），重启丢失；miss 显式 null（语料判缺式
  // `v === undefined || v === null`）
  putMemory: function(k, v) {{ java.cachePutMemory(String(k), v); }},
  getFromMemory: function(k) {{ return java.cacheGetFromMemory(String(k)); }},
  deleteMemory: function(k) {{ java.cacheDeleteMemory(String(k)); return true; }}
}};
// 语料 cache.dev_id（#25 听小说APP，设备标识读写）：属性式 getter/setter，
// 后端全局 cache 存储（saveTime=0 永久口径——put 默认无过期）；未写入前
// 读为 null。— 3b-3
Object.defineProperty(globalThis.cache, 'dev_id', {{
  get: function() {{
    var v = get('dev_id');
    return (v === undefined || v === null || v === '') ? null : String(v);
  }},
  set: function(v) {{
    if (v === undefined || v === null) return;
    put('dev_id', String(v));
  }}
}});

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
  // Rhino 将 Kotlin getKey() 暴露为 key 属性：新落秋/天悦等源 @js: 块用 source.key
  obj.key = sourceUrl;
  obj.url = sourceUrl;
  obj.bookSourceUrl = sourceUrl;
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

// ── 3b-4（#286 刚够小说网，对齐上游 AnalyzeUrl.evalJS java=this 口径）──
// 上游 URL 规则 JS 窗口内 java 即 AnalyzeUrl 实例：
// java.headerMap = 实例请求头 Map（put 即时生效于本次请求）；java.url =
// 实例 url 字段（@js:/{{{{}}}} 窗口未赋值 → ''、选项 js 窗口 = 已解析 URL）。
// Rust 侧经宿主 getCurrentUrl/headerMapPut 桥接 legado-parser 线程局部，
// parse_with_js 收尾把写入落进 AnalyzeUrl.headers → 请求组头生效。
if (typeof java.headerMap === 'undefined') {{
  Object.defineProperty(java, 'headerMap', {{
    value: {{
      put: function (k, v) {{ return java.headerMapPut(String(k), String(v == null ? '' : v)); }}
    }}
  }});
}}
try {{
  Object.defineProperty(java, 'url', {{
    get: function () {{
      var u = java.getCurrentUrl();
      // 非 URL 规则窗口（source evalJS，上游 java=source）回退 sourceUrl
      //（上游 BaseSource.evalJS 绑定 java=source，java.url = getUrl()）
      return u ? u : sourceUrl;
    }}
  }});
}} catch (__e) {{ /* 池化引擎二次 setup 时属性已存在且不可配置：跳过 */ }}

// infoMap：可读写 Map（对标 Android InfoMap 实例）
globalThis.__infoData = {info_map_json};
globalThis.infoMap = new Proxy(__infoData, {{
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
globalThis.__loginHeaderSeed = {login_header_seed};
if (__loginHeaderSeed) {{
  put(__loginHeaderKey(), String(__loginHeaderSeed));
  // 同步登录认证头到全局 Cookie（供 java.ajax 自动携带书山 X-Novel-Token 等）
  try {{
    globalThis.__lh = __loginHeaderSeed;
    if (typeof __lh === 'string') __lh = JSON.parse(__lh);
    if (__lh && typeof __lh === 'object') {{
      for (var __k in __lh) {{
        if (!Object.prototype.hasOwnProperty.call(__lh, __k)) continue;
        globalThis.__v = String(__lh[__k]);
        if (!__v) continue;
        globalThis.__lk = String(__k).toLowerCase();
        if (__lk === 'cookie') {{
          java.setCookie(baseUrl, __v);
        }} else if (__lk.indexOf('token') >= 0 || __lk.indexOf('session') >= 0 || __lk.indexOf('auth') >= 0) {{
          java.setCookie(baseUrl, __k + '=' + __v);
        }}
      }}
    }}
  }} catch (e) {{}}
}}
globalThis.__loginInfoSeed = {login_info_seed};
if (__loginInfoSeed) {{
  put(__userInfoKey(), String(__loginInfoSeed));
}}

// 执行书源 header 规则（对齐 Android BaseSource.getHeaderMap）：@js:/<js>
// 求值 → JSON 解析 → 写入全局请求头（java.putGlobalHeaders），java.ajax 自动
// 携带书山聚合固定 X-Novel-Token 等认证头（原版 AnalyzeUrl(source) 每次请求
// 都解析 header 规则；setup 阶段求值一次即可覆盖静态/登录态头）
try {{
  globalThis.__headerRule = String(source.header || '');
  globalThis.__headerJs = null;
  if (__headerRule.indexOf('@js:') === 0) {{
    __headerJs = __headerRule.substring(4);
  }} else if (__headerRule.indexOf('<js>') === 0) {{
    globalThis.__hend = __headerRule.lastIndexOf('<');
    __headerJs = __hend > 4 ? __headerRule.substring(4, __hend) : __headerRule.substring(4);
  }}
  if (__headerJs) {{
    globalThis.__headerFn = new Function('return (' + __headerJs + ');');
    globalThis.__headerResult = __headerFn.call({{ source: source, cookie: cookie, java: java }});
    globalThis.__headerJson = String(__headerResult);
    globalThis.__headerMap = JSON.parse(__headerJson);
    if (__headerMap && typeof __headerMap === 'object') {{
      java.putGlobalHeaders(__headerJson);
    }}
  }} else if (__headerRule) {{
    globalThis.__hmap = JSON.parse(__headerRule);
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
  globalThis.__legadoSetArguments = setArguments;
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

    /// 宿主数据注入面：baseUrl/loginUrl/source 绑定 + infoMap 快照 +
    /// 登录缓存预置（与 ffi 平移前逐字一致的内容骨架）。
    #[test]
    fn test_setup_script_binds_source_and_host_data() {
        let source = BookSource {
            book_source_url: "https://setup-unit.example.com".to_string(),
            book_source_name: "单元 setup 源".to_string(),
            login_url: Some("https://setup-unit.example.com/login".to_string()),
            ..BookSource::default()
        };
        let mut info_map = HashMap::new();
        info_map.insert("榜类".to_string(), "推荐".to_string());
        let script = book_source_js_setup_script(
            &source,
            &info_map,
            Some(r#"{"X-Token":"t"}"#),
            Some(r#"{"邮箱":"a@b.c"}"#),
        )
        .expect("setup 脚本生成");
        assert!(
            script.contains(r#"globalThis.baseUrl = "https://setup-unit.example.com";"#),
            "baseUrl 绑定"
        );
        assert!(
            script.contains(r#"globalThis.loginUrl = "https://setup-unit.example.com/login";"#),
            "loginUrl 绑定"
        );
        assert!(
            script.contains(r#"__infoData = {"榜类":"推荐"}"#),
            "infoMap 快照注入"
        );
        assert!(
            script.contains("__loginHeaderSeed") && script.contains("X-Token"),
            "登录头预置"
        );
        assert!(
            script.contains("__loginInfoSeed") && script.contains("邮箱"),
            "用户信息预置"
        );
        assert!(
            script.contains("__mountBookSourceApi"),
            "BookSource API 挂载"
        );
    }

    /// 无宿主数据：seed 为 null、infoMap 为空对象，脚本本身仍可 eval。
    #[test]
    fn test_setup_script_null_seeds_when_no_host_data() {
        let source = BookSource {
            book_source_url: "https://setup-unit2.example.com".to_string(),
            ..BookSource::default()
        };
        let script = book_source_js_setup_script(&source, &HashMap::new(), None, None)
            .expect("setup 脚本生成");
        assert!(script.contains("globalThis.__loginHeaderSeed = null;"));
        assert!(script.contains("globalThis.__loginInfoSeed = null;"));
        assert!(script.contains("globalThis.__infoData = {};"));
        // 无 jsLib 的源：host 兜底注入书源 URL
        assert!(
            script.contains(r#"globalThis.host = ["https://setup-unit2.example.com"];"#),
            "host 兜底（无 jsLib 时用书源 URL）"
        );
    }
}
