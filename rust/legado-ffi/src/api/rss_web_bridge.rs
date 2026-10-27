//! RSS 阅读 WebView `preloadJs` 宿主桥（契约 §2.5 `rssWebViewHostCall`，批21a）
//!
//! 对齐原版 `ReadRssActivity` 的 WebView JavaScript 接口（`WebJsExtensions`
//! + `RssJsExtensions`）：`java`/`source`/`cache` 三个全局对象只在
//! **`preloadJs` 作用域**注册（`initJavascriptInterface` 仅当
//! `viewModel.hasPreloadJs` 时 `addJavascriptInterface`），`injectJs` 与页面
//! 普通脚本无桥（`ReadRssActivity.kt:452-455,650-658,739-762`）。
//!
//! 无头 Rust 侧不再走 Java 同步接口，而是**异步优先**的单入口 RPC：
//!
//! - [`rss_web_view_host_call`]：`(sourceUrl, method, argsJson)` → JSON 信封
//!   `{"ok":bool,"value":<any>,"error":String?,"actions":[...]?}`；
//! - `__prepare`：按源 `preloadJs` 生成 WebView 侧 IIFE 头部（`java`/`source`/
//!   `cache` 垫片 + Dart 通道回调注册）与只读快照；源 `preloadJs` 为空/空白时
//!   `script` 为空串（**不注入桥**，1:1 对齐原版门控）；
//! - `__cookieSet`：Dart → Rust 回传 WebView Cookie 串，走
//!   [`legado_js::host_api::cookie_store::set_cookie_str`]（内存 + 持久化
//!   sink 合并 upsert，与 `submitWebviewResultWithCookies` 同一落库路径）；
//! - `__store`：`source` 变量 / 登录缓存 / `cache` 读写与 toast 动作；
//! - 对外方法白名单与 `WebJsExtensions.request` 的 funName 对齐，在 QuickJS
//!   引擎（键 `executor:<sourceUrl>`，绑定 `current_source`）中执行。
//!
//! ## 平台差异（契约 §2.5 批21a 补记已登记）
//!
//! - 同步网络 API（`java.ajax`/`connect`/`get`/`post`/`head`/`webView*`）在
//!   页面垫片中抛错并引导使用 `*Await`（原版经 `@JavascriptInterface` 同步可用）；
//! - `cache.get` 同步读基于页面镜像（跨页面首次 miss 返回 `null`，写异步落库）；
//! - `downloadFileAwait` 本批明确返回不支持（文件 API 后置）；
//! - `@js:`/`<js>` 形式的源 `header` 规则不求值（仅静态 JSON header）；
//! - `run` 在宿主引擎全局作用域执行，不注入 `*Await`（无事件循环）；
//!   其内嵌 `java.ajax` 也不经源级限流（限流按宿主调用粒度，网络类方法
//!   每次调用一许可）。
//!
//! ## 安全边界
//!
//! 方法白名单、参数 ≤1 MiB、结果 ≤4 MiB、单次执行 30s（QuickJS 中断预算）、
//! 源变量按 `v_<sourceUrl>_` / `sourceVariable_<sourceUrl>` 前缀隔离、
//! Cookie 只按 ETLD+1 归一落库。

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

#[cfg(feature = "quickjs")]
use legado_core::models::RssSource;
use legado_core::LegadoResult;
use serde_json::{json, Map, Value};

use crate::api::rss::load_rss_source;
use crate::db_state::with_database;

/// 参数 JSON 上限（1 MiB）
pub(crate) const MAX_ARGS_BYTES: usize = 1024 * 1024;
/// 单次调用结果上限（4 MiB，含信封）
#[cfg(feature = "quickjs")]
pub(crate) const MAX_RESULT_BYTES: usize = 4 * 1024 * 1024;
/// 错误文本截断上限（字符数，避免异常栈把信封撑爆）
const MAX_ERROR_CHARS: usize = 8_000;
/// 单次宿主调用中断预算（QuickJS 中断处理器只在字节码边界检查，
/// 原生网络调用返回后才会触发，故网络慢请求不会被误杀）
#[cfg(feature = "quickjs")]
const HOST_CALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// 对外方法白名单（与 `WebJsExtensions.request` 的 funName 对齐）
///
/// `downloadFileAwait` 保留在白名单内以便返回**明确的不支持**错误
/// （文件 API 后置，避免与「未知方法」混淆）。
const PUBLIC_METHODS: &[&str] = &[
    "run",
    "ajaxAwait",
    "connectAwait",
    "getAwait",
    "headAwait",
    "postAwait",
    "webViewAwait",
    "webViewGetSourceAwait",
    "decryptStrAwait",
    "encryptBase64Await",
    "encryptHexAwait",
    "createSignHexAwait",
    "downloadFileAwait",
    "readTxtFileAwait",
    "importScriptAwait",
    "getStringAwait",
];

/// 需要源级限流的网络类方法（`run` 内嵌网络调用不单独限流，已登记差异）
#[cfg(feature = "quickjs")]
const NETWORK_METHODS: &[&str] = &[
    "ajaxAwait",
    "connectAwait",
    "getAwait",
    "headAwait",
    "postAwait",
    "webViewAwait",
    "webViewGetSourceAwait",
];

/// `__prepare` 传入的 WebView UA（按源记忆，供后续宿主调用的请求头回落）
fn ua_slot() -> &'static RwLock<HashMap<String, String>> {
    static SLOT: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(HashMap::new()))
}

fn remember_ua(source_url: &str, ua: &str) {
    let mut guard = ua_slot().write().unwrap_or_else(|p| p.into_inner());
    guard.insert(source_url.to_string(), ua.to_string());
}

#[cfg(feature = "quickjs")]
fn remembered_ua(source_url: &str) -> Option<String> {
    ua_slot()
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .get(source_url)
        .cloned()
}

/// 有效 UA：`__prepare` 记忆值 → 共享客户端默认 UA
#[cfg(feature = "quickjs")]
fn effective_ua(source_url: &str) -> String {
    remembered_ua(source_url)
        .map(|ua| ua.trim().to_string())
        .filter(|ua| !ua.is_empty())
        .unwrap_or_else(|| legado_net::client::LegadoClientConfig::default().user_agent)
}

// ─── 信封 ────────────────────────────────────────────────────────────────────

fn truncate_error(message: impl Into<String>) -> String {
    let message = message.into();
    if message.chars().count() <= MAX_ERROR_CHARS {
        message
    } else {
        format!(
            "{}…（错误文本已截断）",
            message.chars().take(MAX_ERROR_CHARS).collect::<String>()
        )
    }
}

fn envelope(ok: bool, value: Value, error: Option<String>, actions: Vec<Value>) -> String {
    let mut obj = Map::new();
    obj.insert("ok".to_string(), Value::Bool(ok));
    obj.insert("value".to_string(), value);
    obj.insert(
        "error".to_string(),
        error.map(Value::String).unwrap_or(Value::Null),
    );
    if !actions.is_empty() {
        obj.insert("actions".to_string(), Value::Array(actions));
    }
    serde_json::to_string(&Value::Object(obj)).unwrap_or_else(|_| {
        r#"{"ok":false,"value":null,"error":"宿主桥信封序列化失败"}"#.to_string()
    })
}

fn envelope_ok(value: Value) -> String {
    envelope(true, value, None, Vec::new())
}

fn envelope_error(message: impl Into<String>) -> String {
    envelope(
        false,
        Value::Null,
        Some(truncate_error(message)),
        Vec::new(),
    )
}

// ─── 入口 ────────────────────────────────────────────────────────────────────

/// RSS 阅读 WebView `preloadJs` 宿主桥单入口（契约 §2.5，批21a）
///
/// `args_json` 必须是位置参数 JSON 数组；信封错误（未知方法/参数超限/
/// quickjs 未启用等）以 `ok:false` 返回而非 `Err`，`Err` 仅保留给
/// 无法构造信封的边界错误。
pub fn rss_web_view_host_call(
    source_url: &str,
    method: &str,
    args_json: &str,
) -> LegadoResult<String> {
    let source_url = source_url.trim();
    if source_url.is_empty() {
        return Ok(envelope_error("sourceUrl 不能为空"));
    }
    let method = method.trim();
    if method.is_empty() {
        return Ok(envelope_error("method 不能为空"));
    }
    if args_json.len() > MAX_ARGS_BYTES {
        return Ok(envelope_error(format!(
            "参数超限：{} 字节 > {} 字节上限",
            args_json.len(),
            MAX_ARGS_BYTES
        )));
    }
    let args: Value = match serde_json::from_str(args_json) {
        Ok(value) => value,
        Err(e) => return Ok(envelope_error(format!("argsJson 解析失败: {e}"))),
    };
    if !args.is_array() {
        return Ok(envelope_error("argsJson 必须是 JSON 数组"));
    }

    match method {
        "__prepare" => prepare(source_url, &args),
        "__cookieSet" => cookie_set(&args),
        "__store" => store(source_url, &args),
        other if PUBLIC_METHODS.contains(&other) => host_call(source_url, other, &args),
        other => Ok(envelope_error(format!("未知方法：{other}"))),
    }
}

// ─── __prepare ───────────────────────────────────────────────────────────────

/// 生成 WebView 侧桥脚本与只读快照
///
/// 参数：`args[0] = {"channelName","callbackName","ua"}`。
/// 返回 `value = {"script","snapshot"}`；`script` 为 IIFE 头部（以
/// `// __LEGADO_PRELOAD_JS__` 行结尾），Dart 拼接口径：
/// `script + preloadJs + "\n})();"`。
fn prepare(source_url: &str, args: &Value) -> LegadoResult<String> {
    let Some(source) = load_rss_source(source_url)? else {
        return Ok(envelope_error(format!("RSS 源不存在：{source_url}")));
    };
    let Some(params) = args.get(0).and_then(Value::as_object) else {
        return Ok(envelope_error(
            "__prepare 参数必须是对象：{\"channelName\",\"callbackName\",\"ua\"}",
        ));
    };
    let channel = params
        .get("channelName")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let callback = params
        .get("callbackName")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if channel.is_empty() || callback.is_empty() {
        return Ok(envelope_error(
            "__prepare 需要非空 channelName 与 callbackName",
        ));
    }
    if channel.chars().count() > 256 || callback.chars().count() > 256 {
        return Ok(envelope_error("__prepare 通道名/回调名长度不得超过 256"));
    }
    if let Some(ua) = params
        .get("ua")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|ua| !ua.is_empty())
    {
        remember_ua(source_url, ua);
    }

    #[cfg(not(feature = "quickjs"))]
    {
        // 非 quickjs 构建：无 JS 引擎可执行宿主调用，桥不可用（明确降级）。
        // `source` 已在上方完成存在性校验；`channel`/`callback` 校验同批执行。
        let _ = (source, channel, callback);
        Ok(envelope_error(
            "当前构建未启用 quickjs（JS 引擎不可用），RSS WebView 宿主桥不可用",
        ))
    }

    #[cfg(feature = "quickjs")]
    {
        let snapshot = build_snapshot(&source, effective_ua(source_url));
        let has_preload = source
            .preload_js
            .as_deref()
            .map(|js| !js.trim().is_empty())
            .unwrap_or(false);
        let script = if has_preload {
            build_prepare_script(channel, callback, &snapshot)
        } else {
            String::new()
        };
        Ok(envelope_ok(
            json!({ "script": script, "snapshot": snapshot }),
        ))
    }
}

/// 只读快照（Dart 同步面摊平用）
///
/// `vars` 为全部 `v_<sourceUrl>_*` 键（去前缀），DB 兜底、内存覆盖；
/// 登录头/信息/源变量取自内存 + DB 单实现（`source_login_cache`）。
#[cfg(feature = "quickjs")]
fn build_snapshot(source: &RssSource, user_agent: String) -> Value {
    let prefix = format!("v_{}_", source.source_url);
    let mut vars = Map::new();
    // DB 兜底（跨进程/跨页面）
    for (key, value) in db_cache_prefix(&prefix) {
        if let Some(rest) = key.strip_prefix(&prefix) {
            vars.insert(rest.to_string(), Value::String(value));
        }
    }
    // 进程内变量表覆盖（最新写优先）
    if let Ok(keys) = legado_js::host_api::variable_store::list_variable_keys() {
        for key in keys {
            if let Some(rest) = key.strip_prefix(&prefix) {
                if let Ok(Some(value)) = legado_js::host_api::variable_store::get_variable(&key) {
                    vars.insert(rest.to_string(), Value::String(value));
                }
            }
        }
    }

    let login_header = crate::api::source_login_cache::get_login_header(&source.source_url);
    let login_info = crate::api::source_login_cache::get_login_info(&source.source_url);
    let source_variable = source_variable_get(&source.source_url);

    json!({
        "sourceUrl": source.source_url,
        "sourceName": source.source_name,
        "loginUrl": source.login_url.clone().unwrap_or_default(),
        "loginUi": source.login_ui.clone().unwrap_or_default(),
        "loginHeader": login_header,
        "loginInfo": login_info,
        "sourceVariable": if source_variable.is_empty() { Value::Null } else { Value::String(source_variable) },
        "vars": vars,
        "userAgent": user_agent,
    })
}

/// JSON → JS 字面量（额外转义 U+2028/U+2029，避免旧解析器断句）
#[cfg(feature = "quickjs")]
fn js_literal(value: &Value) -> String {
    serde_json::to_string(value)
        .unwrap_or_else(|_| "null".to_string())
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}

/// 生成 WebView 侧桥脚本（IIFE 头部，不闭合）
#[cfg(feature = "quickjs")]
fn build_prepare_script(channel: &str, callback: &str, snapshot: &Value) -> String {
    let channel = js_literal(&Value::String(channel.to_string()));
    let callback = js_literal(&Value::String(callback.to_string()));
    let snapshot = js_literal(snapshot);
    format!(
        r#"(() => {{
  // [批21a] RSS 阅读 WebView preloadJs 宿主桥（Rust 生成，Dart 追加 preloadJs 后闭合）
  // 拼接口径（契约 §2.5）：script + preloadJs + "\n}})();"
  var __lgChannelName = {channel};
  var __lgCallbackName = {callback};
  var __lgSnapshot = {snapshot};
  var __lgPending = Object.create(null);
  var __lgSeq = 0;
  var __lgChannel = (typeof window !== 'undefined') ? window[__lgChannelName] : null;

  function __lgReply(id, ok, payload) {{
    var pending = __lgPending[id];
    if (!pending) return;
    delete __lgPending[id];
    if (ok) {{ pending.resolve(payload); }} else {{ pending.reject(payload); }}
  }}
  if (typeof window !== 'undefined') {{ window[__lgCallbackName] = __lgReply; }}

  function __lgCall(method, args) {{
    return new Promise(function (resolve, reject) {{
      if (!__lgChannel || typeof __lgChannel.request !== 'function') {{
        reject('RSS WebView 宿主通道不可用：' + __lgChannelName);
        return;
      }}
      var id = 'rss_' + (++__lgSeq) + '_' + Date.now();
      __lgPending[id] = {{ resolve: resolve, reject: reject }};
      try {{
        __lgChannel.request(method, JSON.stringify(args || []), id);
      }} catch (e) {{
        delete __lgPending[id];
        reject(String(e));
      }}
    }});
  }}

  // 同步写转发（fire-and-forget；失败不阻断页面脚本）
  function __lgStore(op, key, value) {{
    try {{
      if (__lgChannel && typeof __lgChannel.request === 'function') {{
        __lgChannel.request('__store', JSON.stringify({{ op: op, key: key, value: value }}), 'store_' + (++__lgSeq));
      }}
    }} catch (e) {{}}
  }}

  // 异步宿主函数（与原版 WebJsExtensions 同名，参数/结果均为字符串）
  var __lgAsync = {{
    run: function (jsCode) {{ return __lgCall('run', [String(jsCode)]); }},
    ajaxAwait: function (url, callTimeout) {{
      return __lgCall('ajaxAwait', [String(url), callTimeout == null ? null : String(callTimeout)]);
    }},
    connectAwait: function (url, header, callTimeout) {{
      return __lgCall('connectAwait', [String(url), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
    }},
    getAwait: function (url, header, callTimeout) {{
      return __lgCall('getAwait', [String(url), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
    }},
    headAwait: function (url, header, callTimeout) {{
      return __lgCall('headAwait', [String(url), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
    }},
    postAwait: function (url, body, header, callTimeout) {{
      return __lgCall('postAwait', [String(url), String(body), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
    }},
    webViewAwait: function (html, url, js, cacheFirst) {{
      return __lgCall('webViewAwait', [html == null ? null : String(html), url == null ? null : String(url), js == null ? null : String(js), cacheFirst == null ? null : !!cacheFirst]);
    }},
    webViewGetSourceAwait: function (html, url, js, sourceRegex, cacheFirst, delayTime) {{
      return __lgCall('webViewGetSourceAwait', [
        html == null ? null : String(html),
        url == null ? null : String(url),
        js == null ? null : String(js),
        sourceRegex == null ? null : String(sourceRegex),
        cacheFirst == null ? null : !!cacheFirst,
        delayTime == null ? null : String(delayTime)
      ]);
    }},
    decryptStrAwait: function (transformation, key, iv, data) {{
      return __lgCall('decryptStrAwait', [String(transformation), String(key), iv == null ? null : String(iv), String(data)]);
    }},
    encryptBase64Await: function (transformation, key, iv, data) {{
      return __lgCall('encryptBase64Await', [String(transformation), String(key), iv == null ? null : String(iv), String(data)]);
    }},
    encryptHexAwait: function (transformation, key, iv, data) {{
      return __lgCall('encryptHexAwait', [String(transformation), String(key), iv == null ? null : String(iv), String(data)]);
    }},
    createSignHexAwait: function (algorithm, publicKey, privateKey, data) {{
      return __lgCall('createSignHexAwait', [String(algorithm), String(publicKey), String(privateKey), String(data)]);
    }},
    downloadFileAwait: function (url) {{ return __lgCall('downloadFileAwait', [String(url)]); }},
    readTxtFileAwait: function (path) {{ return __lgCall('readTxtFileAwait', [String(path)]); }},
    importScriptAwait: function (url) {{ return __lgCall('importScriptAwait', [String(url)]); }},
    getStringAwait: function (ruleStr, mContent) {{
      return __lgCall('getStringAwait', [ruleStr == null ? null : String(ruleStr), mContent == null ? null : String(mContent)]);
    }}
  }};
  if (typeof window !== 'undefined') {{
    for (var __lgName in __lgAsync) {{
      if (Object.prototype.hasOwnProperty.call(__lgAsync, __lgName)) {{
        window[__lgName] = __lgAsync[__lgName];
      }}
    }}
  }}

  // source 垫片：同步读内联快照，写异步转发（__store）
  var __lgVars = __lgSnapshot.vars || {{}};
  var __lgSourceVariable = __lgSnapshot.sourceVariable == null ? '' : String(__lgSnapshot.sourceVariable);
  var __lgLoginHeader = __lgSnapshot.loginHeader == null ? null : String(__lgSnapshot.loginHeader);
  var __lgLoginInfo = __lgSnapshot.loginInfo == null ? null : String(__lgSnapshot.loginInfo);
  var source = {{
    get: function (k) {{
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(__lgVars, key) ? String(__lgVars[key]) : '';
    }},
    getKey: function () {{ return __lgSnapshot.sourceUrl; }},
    getUrl: function () {{ return __lgSnapshot.sourceUrl; }},
    getTag: function () {{ return __lgSnapshot.sourceName || ''; }},
    key: __lgSnapshot.sourceUrl,
    url: __lgSnapshot.sourceUrl,
    put: function (k, v) {{
      var key = String(k);
      var value = String(v);
      __lgVars[key] = value;
      __lgStore('sourcePut', key, value);
      return value;
    }},
    getVariable: function () {{ return __lgSourceVariable; }},
    setVariable: function (v) {{
      var value = String(v);
      __lgSourceVariable = value;
      __lgStore('sourceVariableSet', null, value);
      return value;
    }},
    putVariable: function (v) {{ return this.setVariable(v); }},
    getLoginHeader: function () {{ return __lgLoginHeader ? String(__lgLoginHeader) : null; }},
    putLoginHeader: function (h) {{
      var value = String(h);
      __lgLoginHeader = value;
      __lgStore('loginHeaderSet', null, value);
    }},
    removeLoginHeader: function () {{
      __lgLoginHeader = null;
      __lgStore('loginHeaderRemove', null, null);
    }},
    getLoginHeaderMap: function () {{
      try {{ return __lgLoginHeader ? JSON.parse(__lgLoginHeader) : null; }} catch (e) {{ return null; }}
    }},
    getLoginInfo: function () {{ return __lgLoginInfo ? String(__lgLoginInfo) : null; }},
    putLoginInfo: function (i) {{
      var value = String(i);
      __lgLoginInfo = value;
      __lgStore('loginInfoSet', null, value);
      return true;
    }},
    removeLoginInfo: function () {{
      __lgLoginInfo = null;
      __lgStore('loginInfoRemove', null, null);
    }},
    getLoginInfoMap: function () {{
      var data = {{}};
      try {{ data = __lgLoginInfo ? (JSON.parse(__lgLoginInfo) || {{}}) : {{}}; }} catch (e) {{ data = {{}}; }}
      data.get = function (k) {{ return this[k] == null ? null : this[k]; }};
      data.put = function (k, v) {{
        this[k] = String(v);
        source.putLoginInfo(JSON.stringify(this));
        return v;
      }};
      return data;
    }},
    hasLogin: function () {{ return !!(__lgSnapshot.loginUrl || __lgSnapshot.loginUi); }},
    login: function () {{
      __lgStore('log', 'rss-webview', 'source.login() 未在 WebView 宿主桥实现（请用 source.putLoginHeader/putLoginInfo）');
    }}
  }};

  // cache 垫片：同步读页面镜像，写异步落 cache_store
  var __lgCacheMirror = Object.create(null);
  var cache = {{
    get: function (k) {{
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(__lgCacheMirror, key) ? __lgCacheMirror[key] : null;
    }},
    put: function (k, v) {{
      var key = String(k);
      var value = String(v);
      __lgCacheMirror[key] = value;
      __lgStore('cachePut', key, value);
      return value;
    }},
    remove: function (k) {{
      var key = String(k);
      delete __lgCacheMirror[key];
      __lgStore('cacheRemove', key, null);
      return true;
    }},
    putMemory: function (k, v) {{
      var key = String(k);
      var value = String(v);
      __lgCacheMirror[key] = value;
      __lgStore('cachePutMemory', key, value);
    }},
    getFromMemory: function (k) {{
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(__lgCacheMirror, key) ? __lgCacheMirror[key] : null;
    }},
    deleteMemory: function (k) {{
      var key = String(k);
      delete __lgCacheMirror[key];
      __lgStore('cacheDeleteMemory', key, null);
      return true;
    }}
  }};

  // java 垫片：同步网络/加密/解析面一律引导 *Await（平台差异已登记）
  function __lgSyncUnsupported(name, suggestion) {{
    var msg = 'WebView 同步宿主调用不可用：java.' + name + '，请改用 ' + suggestion;
    __lgStore('log', 'rss-webview', msg);
    throw new Error(msg);
  }}
  var java = {{
    request: function (funName, args, id) {{
      try {{
        __lgChannel.request(String(funName), JSON.stringify(args || []), String(id == null ? '' : id));
      }} catch (e) {{}}
    }},
    put: function (k, v) {{ return source.put(String(k), String(v)); }},
    get: function (urlOrKey) {{
      if (arguments.length <= 1) return source.get(String(urlOrKey));
      return __lgSyncUnsupported('get', 'getAwait');
    }},
    ajax: function () {{ return __lgSyncUnsupported('ajax', 'ajaxAwait'); }},
    connect: function () {{ return __lgSyncUnsupported('connect', 'connectAwait'); }},
    post: function () {{ return __lgSyncUnsupported('post', 'postAwait'); }},
    head: function () {{ return __lgSyncUnsupported('head', 'headAwait'); }},
    webView: function () {{ return __lgSyncUnsupported('webView', 'webViewAwait'); }},
    webViewGetSource: function () {{ return __lgSyncUnsupported('webViewGetSource', 'webViewGetSourceAwait'); }},
    downloadFile: function () {{ return __lgSyncUnsupported('downloadFile', 'downloadFileAwait'); }},
    readTxtFile: function () {{ return __lgSyncUnsupported('readTxtFile', 'readTxtFileAwait'); }},
    importScript: function () {{ return __lgSyncUnsupported('importScript', 'importScriptAwait'); }},
    getString: function () {{ return __lgSyncUnsupported('getString', 'getStringAwait'); }},
    getStringList: function () {{ return __lgSyncUnsupported('getStringList', 'getStringAwait'); }},
    createSymmetricCrypto: function () {{
      return __lgSyncUnsupported('createSymmetricCrypto', 'decryptStrAwait/encryptBase64Await/encryptHexAwait');
    }},
    createSign: function () {{ return __lgSyncUnsupported('createSign', 'createSignHexAwait'); }},
    getCookie: function () {{ return __lgSyncUnsupported('getCookie', 'source.getLoginHeader()'); }},
    setCookie: function () {{ return __lgSyncUnsupported('setCookie', 'source.putLoginHeader()'); }},
    toast: function (msg) {{ __lgStore('toast', null, String(msg)); return String(msg); }},
    longToast: function (msg) {{ __lgStore('longToast', null, String(msg)); return String(msg); }},
    log: function (msg) {{ __lgStore('log', null, String(msg)); return String(msg); }}
  }};

  if (typeof window !== 'undefined') {{
    window.java = java;
    window.source = source;
    window.cache = cache;
  }}
  // __LEGADO_PRELOAD_JS__
"#
    )
}

// ─── __cookieSet ─────────────────────────────────────────────────────────────

/// WebView Cookie 回流（Dart → Rust）
///
/// 参数：`args[0] = {"url","cookie"}`。`url` 可为 `http(s)` 页面 URL 或域名键
/// （`set_cookie_str` 内部 ETLD+1 归一）；cookie 为空即参数错误。
fn cookie_set(args: &Value) -> LegadoResult<String> {
    let Some(params) = args.get(0).and_then(Value::as_object) else {
        return Ok(envelope_error(
            "__cookieSet 参数必须是对象：{\"url\",\"cookie\"}",
        ));
    };
    let url = params.get("url").and_then(Value::as_str).unwrap_or("");
    let cookie = params.get("cookie").and_then(Value::as_str).unwrap_or("");
    if url.trim().is_empty() || cookie.trim().is_empty() {
        return Ok(envelope_error("__cookieSet 需要非空 url 与 cookie"));
    }
    let domain_key = legado_js::host_api::cookie_store::normalized_cookie_key(url);
    if domain_key.is_empty() {
        return Ok(envelope_error(
            "__cookieSet 需要 http(s) URL 或域名键（空域键拒绝落库）",
        ));
    }
    // 内存 + 持久化 sink 合并 upsert（与 submitWebviewResultWithCookies 同路径；
    // sink 未注册时仅内存，DB 未就绪不阻断页面会话）
    legado_js::host_api::cookie_store::set_cookie_str(url, cookie);
    Ok(envelope_ok(json!({ "domainKey": domain_key })))
}

// ─── __store ─────────────────────────────────────────────────────────────────

/// source 变量 / 登录缓存 / cache 读写与 toast 动作
///
/// 参数：`args[0] = {"op","key","value"}`；`op` 见
/// [`rss_web_view_host_call`] 文档。source 变量键前缀
/// `v_<sourceUrl>_` / `sourceVariable_<sourceUrl>` 与规则 JS 同键空间。
fn store(source_url: &str, args: &Value) -> LegadoResult<String> {
    let Some(params) = args.get(0).and_then(Value::as_object) else {
        return Ok(envelope_error(
            "__store 参数必须是对象：{\"op\",\"key\",\"value\"}",
        ));
    };
    let op = params
        .get("op")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let key = params.get("key").and_then(Value::as_str).unwrap_or("");
    let value = params.get("value").and_then(Value::as_str).unwrap_or("");

    let mut actions: Vec<Value> = Vec::new();
    let result = match op {
        "sourceGet" => Value::String(source_var_get(source_url, key)),
        "sourcePut" => {
            source_var_put(source_url, key, value);
            Value::String(value.to_string())
        }
        "sourceVariableGet" => Value::String(source_variable_get(source_url)),
        "sourceVariableSet" => {
            source_variable_set(source_url, value);
            Value::String(value.to_string())
        }
        "loginHeaderGet" => Value::String(
            crate::api::source_login_cache::get_login_header(source_url).unwrap_or_default(),
        ),
        "loginHeaderSet" => {
            put_login_header(source_url, value);
            Value::String(value.to_string())
        }
        "loginHeaderRemove" => {
            if let Err(e) = crate::api::source_login_cache::remove_login_header(source_url) {
                log::warn!("[rss-web-bridge] 清除登录头失败（{source_url}）: {e}");
            }
            Value::Null
        }
        "loginInfoGet" => Value::String(
            crate::api::source_login_cache::get_login_info(source_url).unwrap_or_default(),
        ),
        "loginInfoSet" => {
            if let Err(e) = crate::api::source_login_cache::put_login_info(source_url, value) {
                log::warn!("[rss-web-bridge] 写入用户信息失败（{source_url}）: {e}");
            }
            Value::String(value.to_string())
        }
        "loginInfoRemove" => {
            if let Err(e) = crate::api::source_login_cache::remove_login_info(source_url) {
                log::warn!("[rss-web-bridge] 清除用户信息失败（{source_url}）: {e}");
            }
            Value::Null
        }
        "cacheGet" => match legado_js::host_api::cache_store::get(key, false) {
            Some(v) => Value::String(v),
            None => Value::Null,
        },
        "cachePut" => {
            legado_js::host_api::cache_store::put(key, value, 0);
            Value::String(value.to_string())
        }
        "cacheRemove" => {
            legado_js::host_api::cache_store::delete(key);
            Value::Bool(true)
        }
        "cachePutMemory" => {
            legado_js::host_api::cache_store::put_memory(key, value);
            Value::Null
        }
        "cacheGetFromMemory" => match legado_js::host_api::cache_store::get_from_memory(key) {
            Some(v) => Value::String(v),
            None => Value::Null,
        },
        "cacheDeleteMemory" => {
            legado_js::host_api::cache_store::delete_memory(key);
            Value::Bool(true)
        }
        "log" => {
            log::info!("[rss-webview] {value}");
            Value::Null
        }
        "toast" | "longToast" => {
            actions.push(json!({
                "action": "toast",
                "text": value,
                "long": op == "longToast",
            }));
            Value::Null
        }
        other => return Ok(envelope_error(format!("__store 未知 op：{other}"))),
    };
    Ok(envelope(true, result, None, actions))
}

// ─── source 变量（内存 + DB 双写） ───────────────────────────────────────────

fn source_var_key(source_url: &str, key: &str) -> String {
    format!("v_{source_url}_{key}")
}

fn source_variable_key(source_url: &str) -> String {
    format!("sourceVariable_{source_url}")
}

fn source_var_get(source_url: &str, key: &str) -> String {
    let full = source_var_key(source_url, key);
    if let Ok(Some(value)) = legado_js::host_api::variable_store::get_variable(&full) {
        return value;
    }
    match db_cache_get(&full) {
        Some(value) => {
            let _ = legado_js::host_api::variable_store::set_variable(&full, &value);
            value
        }
        None => String::new(),
    }
}

fn source_var_put(source_url: &str, key: &str, value: &str) {
    let full = source_var_key(source_url, key);
    if let Err(e) = legado_js::host_api::variable_store::set_variable(&full, value) {
        log::warn!("[rss-web-bridge] 源变量内存写入失败（{full}）: {e}");
    }
    db_cache_put(&full, value);
}

fn source_variable_get(source_url: &str) -> String {
    let full = source_variable_key(source_url);
    if let Ok(Some(value)) = legado_js::host_api::variable_store::get_variable(&full) {
        return value;
    }
    match db_cache_get(&full) {
        Some(value) => {
            let _ = legado_js::host_api::variable_store::set_variable(&full, &value);
            value
        }
        None => String::new(),
    }
}

fn source_variable_set(source_url: &str, value: &str) {
    let full = source_variable_key(source_url);
    if let Err(e) = legado_js::host_api::variable_store::set_variable(&full, value) {
        log::warn!("[rss-web-bridge] 源变量内存写入失败（{full}）: {e}");
    }
    db_cache_put(&full, value);
}

/// 写登录头并同步 `Cookie` 键到 Cookie 存储（对齐 RSS setup 脚本
/// `putLoginHeader` 的 `java.setCookie(baseUrl, Cookie)` 行为）
fn put_login_header(source_url: &str, header: &str) {
    if let Err(e) = crate::api::source_login_cache::put_login_header(source_url, header) {
        log::warn!("[rss-web-bridge] 写入登录头失败（{source_url}）: {e}");
    }
    let Ok(map) = serde_json::from_str::<HashMap<String, String>>(header) else {
        return;
    };
    if let Some(cookie) = map
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("cookie"))
        .map(|(_, v)| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        legado_js::host_api::cookie_store::set_cookie_str(source_url, &cookie);
    }
}

// ─── DB 缓存辅助（DB 未就绪/失败仅告警，不阻断） ────────────────────────────

fn db_cache_get(key: &str) -> Option<String> {
    with_database(|db| legado_db::CacheRepository::new(db.connection()).get(key))
        .ok()
        .flatten()
}

fn db_cache_put(key: &str, value: &str) {
    if let Err(e) =
        with_database(|db| legado_db::CacheRepository::new(db.connection()).put(key, value, 0))
    {
        log::warn!("[rss-web-bridge] 变量落库失败（{key}）: {e}");
    }
}

#[cfg(feature = "quickjs")]
fn db_cache_prefix(prefix: &str) -> Vec<(String, String)> {
    with_database(|db| legado_db::CacheRepository::new(db.connection()).list_by_prefix(prefix))
        .unwrap_or_default()
}

// ─── 宿主调用（QuickJS） ────────────────────────────────────────────────────

/// 引擎侧垫片：把 `*Await` 映射到既有 `java.*` 宿主 API
///
/// 每次调用前重评（只赋值 `globalThis.__lgWebHost`，无顶层 `var`/`let`，
/// 不触发重声明），避免与引擎缓存的 setup 字符串（登录头种子随登录变化）
/// 相互影响。
#[cfg(feature = "quickjs")]
const HOST_SHIM_JS: &str = r#"
// 源静态请求头 + UA（Rust 每次调用前注入对象字面量；`java.get/post/head/
// connect` 不经过 java.ajax 的全局头合并路径，故由本垫片显式合并）
globalThis.__lgHeadersJson = function (header) {
  var source = globalThis.__lgSourceHeaders;
  var base = {};
  if (source && typeof source === 'object') {
    for (var sk in source) {
      if (Object.prototype.hasOwnProperty.call(source, sk)) base[sk] = String(source[sk]);
    }
  } else if (typeof source === 'string' && source !== '') {
    try { base = JSON.parse(source) || {}; } catch (e) { base = {}; }
  }
  if (header != null && header !== '') {
    try {
      var extra = (typeof header === 'string') ? JSON.parse(header) : header;
      if (extra && typeof extra === 'object') {
        for (var k in extra) {
          if (Object.prototype.hasOwnProperty.call(extra, k)) base[k] = String(extra[k]);
        }
      }
    } catch (e) {}
  }
  return JSON.stringify(base);
};
globalThis.__lgWebHost = {
  run: function (jsCode) {
    return String(eval(String(jsCode)));
  },
  ajaxAwait: function (url, callTimeout) {
    return String(java.ajax(String(url), callTimeout == null ? 9000 : Number(callTimeout)));
  },
  connectAwait: function (url, header, callTimeout) {
    var r = java.connect(
      String(url),
      __lgHeadersJson(header),
      callTimeout == null ? 9000 : Number(callTimeout)
    );
    return JSON.stringify({
      statusCode: r.code(),
      body: r.body(),
      headers: r.raw().headers(),
      url: r.raw().request().url()
    });
  },
  getAwait: function (url, header, callTimeout) {
    return String(java.get(String(url), __lgHeadersJson(header)).body());
  },
  headAwait: function (url, header, callTimeout) {
    return JSON.stringify(java.head(String(url), __lgHeadersJson(header)).headersMap());
  },
  postAwait: function (url, body, header, callTimeout) {
    return String(java.post(String(url), String(body), __lgHeadersJson(header)).body());
  },
  webViewAwait: function (html, url, js, cacheFirst) {
    return String(java.webView(
      html == null ? null : String(html),
      url == null ? null : String(url),
      js == null ? null : String(js),
      cacheFirst === true
    ));
  },
  webViewGetSourceAwait: function (html, url, js, sourceRegex, cacheFirst, delayTime) {
    return String(java.webViewGetSource(
      html == null ? null : String(html),
      url == null ? null : String(url),
      js == null ? null : String(js),
      sourceRegex == null ? '' : String(sourceRegex),
      cacheFirst === true,
      delayTime == null ? 0 : Number(delayTime)
    ));
  },
  decryptStrAwait: function (transformation, key, iv, data) {
    return String(java.createSymmetricCrypto(
      String(transformation),
      String(key),
      iv == null ? null : String(iv)
    ).decryptStr(String(data)));
  },
  encryptBase64Await: function (transformation, key, iv, data) {
    return String(java.createSymmetricCrypto(
      String(transformation),
      String(key),
      iv == null ? null : String(iv)
    ).encryptBase64(String(data)));
  },
  encryptHexAwait: function (transformation, key, iv, data) {
    return String(java.createSymmetricCrypto(
      String(transformation),
      String(key),
      iv == null ? null : String(iv)
    ).encryptHex(String(data)));
  },
  createSignHexAwait: function (algorithm, publicKey, privateKey, data) {
    return String(java.createSign(String(algorithm))
      .setPublicKey(String(publicKey))
      .setPrivateKey(String(privateKey))
      .signHex(String(data)));
  },
  readTxtFileAwait: function (path) {
    return String(java.readTxtFile(String(path)));
  },
  importScriptAwait: function (url) {
    return String(java.importScript(String(url)));
  },
  getStringAwait: function (ruleStr, mContent) {
    return String(java.getString(
      ruleStr == null ? '' : String(ruleStr),
      mContent == null ? null : String(mContent)
    ));
  }
};
"#;

/// 源静态请求头 + UA 回落（不含登录头：跨域安全）
#[cfg(feature = "quickjs")]
fn source_request_headers(source: &RssSource) -> HashMap<String, String> {
    let mut headers: HashMap<String, String> = source
        .header
        .as_deref()
        .and_then(|raw| serde_json::from_str(raw).ok())
        .unwrap_or_default();
    if !headers.keys().any(|k| k.eq_ignore_ascii_case("user-agent")) {
        let ua = effective_ua(&source.source_url);
        if !ua.trim().is_empty() {
            headers.insert("User-Agent".to_string(), ua);
        }
    }
    headers
}

/// 注入源静态 header + UA 到全局请求头（按 source tag 隔离）
///
/// 合并语义：保留脚本经 `java.putGlobalHeaders` 写入的键，源静态 header
/// 覆盖同名键（源配置为权威）。`@js:`/`<js>` 形式 header 不解析
/// （已登记差异，与 RSS 列表链现状一致）。**登录头不在此注入**：
/// 跨域安全（对齐原版 `Rss.kt:56 hasLoginHeader=false`）。
#[cfg(feature = "quickjs")]
fn apply_source_global_headers(source: &RssSource) {
    let headers = source_request_headers(source);
    let mut merged = legado_js::host_api::global_headers::headers_for(&source.source_url);
    merged.extend(headers);
    legado_js::host_api::global_headers::put_headers(&source.source_url, merged);
}

#[cfg(feature = "quickjs")]
fn host_call(source_url: &str, method: &str, args: &Value) -> LegadoResult<String> {
    if method == "downloadFileAwait" {
        return Ok(envelope_error(
            "downloadFileAwait 暂不支持：文件 API 后置（本批仅网络/加解密/解析宿主面）",
        ));
    }
    let Some(source) = load_rss_source(source_url)? else {
        return Ok(envelope_error(format!("RSS 源不存在：{source_url}")));
    };
    apply_source_global_headers(&source);
    // 源级 concurrentRate 限流（网络类方法每次调用一许可；与 RSS 列表/正文
    // 共享同一 limiter map 与固定窗口语义，空 / "0" / 非法不限流）
    if NETWORK_METHODS.contains(&method) {
        let registry = crate::api::source_rate_limit::registry();
        let url = source.source_url.clone();
        let rate = source.concurrent_rate.clone();
        crate::runtime::block_on(async move {
            registry.acquire_by_source(&url, rate.as_deref()).await;
        });
    }

    let js_lib = source
        .js_lib
        .as_deref()
        .map(legado_fetcher::js_adapter::sanitize_js_lib_for_quickjs);
    let login_header = crate::api::source_login_cache::get_login_header(&source.source_url);
    let login_info = crate::api::source_login_cache::get_login_info(&source.source_url);
    let setup = legado_fetcher::source_setup::rss_source_js_setup_script(
        &source,
        login_header.as_deref(),
        login_info.as_deref(),
    )?;
    let key = format!("executor:{}", source.source_url);
    let (engine, _, js_lib_ok) = legado_js::engine_cache::get_or_create_with_timeout(
        &key,
        js_lib.as_deref(),
        Some(&setup),
        None,
        Some(HOST_CALL_TIMEOUT),
    )?;
    if js_lib_ok == Some(false) {
        let reason =
            legado_js::host_api::capability_ledger::last_jslib_error(&key).unwrap_or_default();
        return Ok(envelope_error(format!(
            "RSS 源 jsLib 加载失败({})：宿主桥不可用",
            truncate_error(reason)
        )));
    }

    let args_json = serde_json::to_string(args)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("宿主桥参数序列化失败: {e}")))?;
    let method_json = serde_json::to_string(method).unwrap_or_else(|_| "\"\"".to_string());
    let headers_json = serde_json::to_string(&source_request_headers(&source))
        .unwrap_or_else(|_| "{}".to_string());
    let code = format!(
        "globalThis.__lgSourceHeaders = {headers_json};\n{HOST_SHIM_JS}\n\
         (function(){{ var __a = {args_json}; \
         var __f = globalThis.__lgWebHost[{method_json}]; \
         if (typeof __f !== 'function') {{ throw new Error('宿主方法未实现: ' + {method_json}); }} \
         var __r = __f.apply(null, __a); \
         return JSON.stringify({{value: (__r === undefined ? null : __r)}}); }})()"
    );

    let (result, collected) = legado_js::host_api::ui_action_queue::with_collect(|| {
        legado_js::host_api::current_source::with_current_source_tag(&source.source_url, || {
            let guard = engine
                .lock()
                .map_err(|_| legado_core::LegadoError::JsEngine("JS 引擎锁中毒".into()))?;
            legado_js::JsEngine::eval(&*guard, &code)
        })
    });
    let mut actions = collected.actions;
    if collected.refresh_explore {
        actions.push(json!({ "action": "refreshExplore" }));
    }

    match result {
        Ok(text) => {
            if text.len() > MAX_RESULT_BYTES {
                return Ok(envelope(
                    false,
                    Value::Null,
                    Some(format!(
                        "结果超限：{} 字节 > {} 字节上限",
                        text.len(),
                        MAX_RESULT_BYTES
                    )),
                    actions,
                ));
            }
            Ok(envelope(true, unwrap_value(&text), None, actions))
        }
        Err(e) => Ok(envelope(
            false,
            Value::Null,
            Some(truncate_error(e.to_string())),
            actions,
        )),
    }
}

/// 非 quickjs 构建：宿主调用不可用（明确降级，不静默假成功）
#[cfg(not(feature = "quickjs"))]
fn host_call(_source_url: &str, _method: &str, _args: &Value) -> LegadoResult<String> {
    Ok(envelope_error(
        "当前构建未启用 quickjs（JS 引擎不可用），RSS WebView 宿主桥不可用",
    ))
}

/// 解除 `{"value": ...}` 包装（`eval` 返回的 JSON 文本）
#[cfg(feature = "quickjs")]
fn unwrap_value(text: &str) -> Value {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(mut map)) => map.remove("value").unwrap_or(Value::Null),
        Ok(other) => other,
        Err(_) => Value::String(text.to_string()),
    }
}

// ─── 测试 ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(envelope: &str) -> Value {
        serde_json::from_str(envelope).expect("信封必须是合法 JSON")
    }

    fn add_source(url: &str, extra: Value) {
        let mut source = json!({
            "sourceUrl": url,
            "sourceName": "宿主桥测试源",
            "enabled": true,
        });
        if let (Some(obj), Some(extra)) = (source.as_object_mut(), extra.as_object()) {
            for (k, v) in extra {
                obj.insert(k.clone(), v.clone());
            }
        }
        crate::api::rss::add_rss_source(&source.to_string()).expect("写入 RSS 源");
    }

    fn call(source_url: &str, method: &str, args: Value) -> Value {
        decode(&rss_web_view_host_call(source_url, method, &args.to_string()).expect("宿主桥调用"))
    }

    /// 门控：`preloadJs` 为空/空白时 `script` 为空串（不注入桥），
    /// 且 snapshot 仍返回源身份字段
    #[cfg(feature = "quickjs")]
    #[test]
    fn prepare_gates_on_preload_js() {
        let _guard = crate::db_state::ensure_test_db();
        let url = "https://rss-web-bridge-gate.test/feed";
        add_source(url, json!({ "preloadJs": "   " }));

        let env = call(
            url,
            "__prepare",
            json!([{ "channelName": "ch", "callbackName": "cb", "ua": "UA-Gate" }]),
        );
        assert_eq!(env["ok"], true, "{env}");
        assert_eq!(env["value"]["script"], "", "空白 preloadJs 不得返回桥脚本");
        assert_eq!(env["value"]["snapshot"]["sourceUrl"], url);
        assert_eq!(env["value"]["snapshot"]["sourceName"], "宿主桥测试源");
        assert_eq!(env["value"]["snapshot"]["userAgent"], "UA-Gate");

        crate::api::rss::delete_rss_source(url).ok();
    }

    /// `__prepare` 脚本结构：IIFE 头 + java/source/cache 垫片 + 通道名 +
    /// 拼接口径标记；快照携带登录头与源变量
    #[cfg(feature = "quickjs")]
    #[test]
    fn prepare_script_contains_bridge_shims_and_snapshot() {
        let _guard = crate::db_state::ensure_test_db();
        let url = "https://rss-web-bridge-script.test/feed";
        add_source(
            url,
            json!({
                "preloadJs": "console.log('preload');",
                "loginUrl": "https://rss-web-bridge-script.test/login",
            }),
        );
        crate::api::source_login_cache::put_login_header(url, r#"{"X-Token":"t1"}"#).unwrap();
        let env = call(
            url,
            "__prepare",
            json!([{ "channelName": "legadoChannel", "callbackName": "legadoCb", "ua": "UA-Script" }]),
        );
        assert_eq!(env["ok"], true, "{env}");
        let script = env["value"]["script"].as_str().expect("script 字符串");
        for needle in [
            "(() => {",
            "window.java = java",
            "window.source = source",
            "window.cache = cache",
            "legadoChannel",
            "legadoCb",
            "ajaxAwait",
            "// __LEGADO_PRELOAD_JS__",
        ] {
            assert!(script.contains(needle), "脚本缺少 {needle}: {script}");
        }
        assert!(
            !script.trim_end().ends_with("})();"),
            "script 必须是未闭合的 IIFE 头（Dart 追加 preloadJs 后闭合）"
        );
        let snapshot = &env["value"]["snapshot"];
        assert_eq!(snapshot["loginHeader"], r#"{"X-Token":"t1"}"#);
        assert_eq!(
            snapshot["loginUrl"],
            "https://rss-web-bridge-script.test/login"
        );

        crate::api::source_login_cache::remove_login_header(url).ok();
        crate::api::rss::delete_rss_source(url).ok();
    }

    /// 未知方法 / 非数组参数 / 参数超限 → `ok:false` + 明确 error
    #[test]
    fn envelope_rejects_unknown_method_and_bad_args() {
        let url = "https://rss-web-bridge-envelope.test/feed";
        let env =
            decode(&rss_web_view_host_call(url, "notARealMethod", "[]").expect("调用返回信封"));
        assert_eq!(env["ok"], false);
        assert!(
            env["error"]
                .as_str()
                .unwrap_or_default()
                .contains("未知方法"),
            "{env}"
        );

        let env = decode(&rss_web_view_host_call(url, "run", "{\"k\":1}").expect("调用返回信封"));
        assert_eq!(env["ok"], false);
        assert!(
            env["error"]
                .as_str()
                .unwrap_or_default()
                .contains("JSON 数组"),
            "{env}"
        );

        let big = format!("[\"{}\"]", "x".repeat(MAX_ARGS_BYTES));
        let env = decode(&rss_web_view_host_call(url, "run", &big).expect("调用返回信封"));
        assert_eq!(env["ok"], false);
        assert!(
            env["error"]
                .as_str()
                .unwrap_or_default()
                .contains("参数超限"),
            "{env}"
        );
    }

    /// `__store`：source 变量跨源隔离 + 落库（DB 直读断言）
    #[test]
    fn store_isolates_and_persists_source_variables() {
        let _guard = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let url_a = "https://rss-web-bridge-vars-a.test/feed";
        let url_b = "https://rss-web-bridge-vars-b.test/feed";
        add_source(url_a, json!({}));
        add_source(url_b, json!({}));

        let env = call(
            url_a,
            "__store",
            json!([{ "op": "sourcePut", "key": "token", "value": "a-1" }]),
        );
        assert_eq!(env["ok"], true, "{env}");
        let env = call(
            url_b,
            "__store",
            json!([{ "op": "sourceGet", "key": "token" }]),
        );
        assert_eq!(env["value"], "", "跨源不得读到 A 的变量: {env}");
        let env = call(
            url_a,
            "__store",
            json!([{ "op": "sourceGet", "key": "token" }]),
        );
        assert_eq!(env["value"], "a-1");

        // 落库断言（DB 直读，键前缀 v_<url>_）
        let stored = with_database(|db| {
            legado_db::CacheRepository::new(db.connection()).get(&format!("v_{url_a}_token"))
        })
        .expect("读缓存");
        assert_eq!(stored.as_deref(), Some("a-1"), "source.put 必须同步落库");

        // sourceVariable
        let env = call(
            url_a,
            "__store",
            json!([{ "op": "sourceVariableSet", "value": "var-a" }]),
        );
        assert_eq!(env["ok"], true);
        let env = call(url_a, "__store", json!([{ "op": "sourceVariableGet" }]));
        assert_eq!(env["value"], "var-a");

        // 清理
        for key in [
            format!("v_{url_a}_token"),
            format!("sourceVariable_{url_a}"),
        ] {
            with_database(|db| legado_db::CacheRepository::new(db.connection()).delete(&key)).ok();
        }
        crate::api::rss::delete_rss_source(url_a).ok();
        crate::api::rss::delete_rss_source(url_b).ok();
    }

    /// `__store`：cache 内存面 put/get/delete 与 toast 动作
    #[test]
    fn store_cache_memory_and_toast_action() {
        let url = "https://rss-web-bridge-cache.test/feed";
        let key = "rss-web-bridge-memory-key";
        call(
            url,
            "__store",
            json!([{ "op": "cachePutMemory", "key": key, "value": "mv" }]),
        );
        let env = call(
            url,
            "__store",
            json!([{ "op": "cacheGetFromMemory", "key": key }]),
        );
        assert_eq!(env["value"], "mv");
        call(
            url,
            "__store",
            json!([{ "op": "cacheDeleteMemory", "key": key }]),
        );
        let env = call(
            url,
            "__store",
            json!([{ "op": "cacheGetFromMemory", "key": key }]),
        );
        assert_eq!(env["value"], Value::Null);

        let env = call(url, "__store", json!([{ "op": "toast", "value": "提示" }]));
        assert_eq!(env["ok"], true);
        assert_eq!(env["actions"][0]["action"], "toast");
        assert_eq!(env["actions"][0]["text"], "提示");
    }

    /// `__cookieSet`：内存 Cookie 可读（`cookies_for_url`），空参/空域键拒绝
    #[test]
    fn cookie_set_updates_cookie_store() {
        let _guard = crate::test_support::lock_global_store();
        let url = "https://rss-web-bridge-cookie.test/page";
        let env = call(
            url,
            "__cookieSet",
            json!([{ "url": url, "cookie": "sess=abc; theme=dark" }]),
        );
        assert_eq!(env["ok"], true, "{env}");
        let cookies = legado_js::host_api::cookie_store::cookies_for_url(url);
        assert!(
            cookies.contains("sess=abc"),
            "cookies_for_url 应可读: {cookies}"
        );
        assert!(cookies.contains("theme=dark"), "{cookies}");

        let env = call(url, "__cookieSet", json!([{ "url": "", "cookie": "a=1" }]));
        assert_eq!(env["ok"], false);
        let env = call(url, "__cookieSet", json!([{ "url": "   ", "cookie": "" }]));
        assert_eq!(env["ok"], false);

        legado_js::host_api::cookie_store::clear_cookies(url);
    }

    /// 非 quickjs 构建：`__prepare` 与宿主方法均明确降级（不静默假成功）
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn quickjs_off_degrades_explicitly() {
        let _guard = crate::db_state::ensure_test_db();
        let url = "https://rss-web-bridge-off.test/feed";
        add_source(url, json!({ "preloadJs": "1 + 1" }));
        for (method, args) in [
            (
                "__prepare",
                json!([{ "channelName": "ch", "callbackName": "cb" }]),
            ),
            ("ajaxAwait", json!(["https://example.com"])),
            ("run", json!(["1 + 1"])),
        ] {
            let env = call(url, method, args);
            assert_eq!(env["ok"], false, "quickjs-off 必须明确降级: {method} {env}");
            assert!(
                env["error"]
                    .as_str()
                    .unwrap_or_default()
                    .contains("quickjs"),
                "{method}: {env}"
            );
        }
        crate::api::rss::delete_rss_source(url).ok();
    }
}
