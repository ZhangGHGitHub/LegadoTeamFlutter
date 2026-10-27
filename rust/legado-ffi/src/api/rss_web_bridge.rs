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
//!
//! 批21c 安全加固（独立复核 P0）：
//!
//! - **脚本自身不写页面全局**：`java`/`source`/`cache` 与 `*Await` 仅存在于
//!   生成的 IIFE 闭包（`preloadJs` 词法可见），不再写 `window`；页面桥对象
//!   读取后立即 `delete window[channelName]`；回填回调用
//!   `Object.defineProperty` 定义（`enumerable:false`、`configurable:false`）。
//!   **注意**：不可枚举 ≠ 不可发现，`Object.getOwnPropertyNames(window)`
//!   仍可看到属性名；Android 15 真机实测平台通道在删除前对 `Object.keys`
//!   也可见、`delete` 后不可见，iOS `webkit.messageHandlers` 待验收
//!   （契约 §2.5 批21d 真机结论）。
//! - **nonce 不作为安全边界**：仅防误用/重放。URL 模式桥能力与原版等价
//!   （页面可信假设）；脚本隔离只对文章 HTML 模式成立（Dart 侧剥离页面
//!   脚本，见契约 §2.5 批21d）。
//! - **降级不静默**：prepare 失败或 `bridgeAvailable:false` 时 Dart 注入带
//!   明确报错的 `java`/`source`/`cache` 桩（本文件不参与），避免
//!   `preloadJs` 因 TypeError 中断。
//! - **资源边界**：每源宿主调用并发上限 4（等待 10s 超时）；`__store` 每秒
//!   300 次；`importScriptAwait` 纳入源级 `concurrentRate` 限流；并发/限频/
//!   UA 记忆表均有条数上限（超出淘汰空闲/任意条目）。

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

#[cfg(feature = "quickjs")]
use std::sync::Arc;

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
///
/// 批21c：`importScriptAwait` 走网络下载脚本，纳入源级 `concurrentRate`
/// 限流（独立复核 P2-10）。
#[cfg(feature = "quickjs")]
const NETWORK_METHODS: &[&str] = &[
    "ajaxAwait",
    "connectAwait",
    "getAwait",
    "headAwait",
    "postAwait",
    "webViewAwait",
    "webViewGetSourceAwait",
    "importScriptAwait",
];

/// 每源宿主调用并发上限（批21c：独立复核 P2-10，取 2-4 区间的上界）
#[cfg(feature = "quickjs")]
const BRIDGE_MAX_CONCURRENCY: usize = 4;

/// 并发许可等待上限（批21d P2-2：超时明确回填错误，不无限阻塞）
#[cfg(feature = "quickjs")]
const BRIDGE_PERMIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// 进程内按源表的条数上限（并发信号量/限频窗口/UA 记忆；批21d P2-2）
///
/// 超出后优先淘汰空闲信号量，其次淘汰任意条目；被淘汰源下次调用会重建，
/// 只损失短期状态（限频窗口/UA 记忆），不会造成功能错误。
const MAX_TRACKED_SOURCES: usize = 256;

/// `__store` 每秒调用上限（每源；超出按 `ok:false` 拒绝，页面侧丢弃）
const STORE_MAX_PER_SECOND: u32 = 300;

/// `__store` 限频窗口（秒）
const STORE_RATE_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// 每源并发信号量（避免页面脚本瞬时并发把 QuickJS 引擎/网络打满）
#[cfg(feature = "quickjs")]
fn concurrency_slot() -> &'static RwLock<HashMap<String, Arc<tokio::sync::Semaphore>>> {
    static SLOT: OnceLock<RwLock<HashMap<String, Arc<tokio::sync::Semaphore>>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(HashMap::new()))
}

/// 获取一次宿主调用许可（每源 [`BRIDGE_MAX_CONCURRENCY`] 个并发）
///
/// 批21d P2-2：等待 [`BRIDGE_PERMIT_TIMEOUT`] 仍拿不到许可时返回明确错误，
/// 由调用方回填 `ok:false`（不再无限阻塞调用线程）。
#[cfg(feature = "quickjs")]
fn bridge_permit(source_url: &str) -> Result<tokio::sync::OwnedSemaphorePermit, String> {
    let semaphore = {
        let mut guard = concurrency_slot()
            .write()
            .unwrap_or_else(|p| p.into_inner());
        let semaphore = Arc::clone(
            guard
                .entry(source_url.to_string())
                .or_insert_with(|| Arc::new(tokio::sync::Semaphore::new(BRIDGE_MAX_CONCURRENCY))),
        );
        trim_idle_semaphores(&mut guard);
        semaphore
    };
    let outcome = crate::runtime::block_on(async move {
        tokio::time::timeout(BRIDGE_PERMIT_TIMEOUT, semaphore.acquire_owned()).await
    });
    match outcome {
        Ok(Ok(permit)) => Ok(permit),
        Ok(Err(_)) => Err("宿主桥并发许可获取失败（信号量已关闭）".to_string()),
        Err(_) => Err(format!(
            "宿主桥并发许可等待超时（{}s，每源并发上限 {BRIDGE_MAX_CONCURRENCY}）",
            BRIDGE_PERMIT_TIMEOUT.as_secs()
        )),
    }
}

/// 并发信号量表裁剪：优先淘汰无持有者的空闲项（Arc 仅剩表内引用）
#[cfg(feature = "quickjs")]
fn trim_idle_semaphores(guard: &mut HashMap<String, Arc<tokio::sync::Semaphore>>) {
    if guard.len() <= MAX_TRACKED_SOURCES {
        return;
    }
    let idle: Vec<String> = guard
        .iter()
        .filter(|(_, semaphore)| Arc::strong_count(semaphore) == 1)
        .map(|(key, _)| key.clone())
        .collect();
    for key in idle {
        if guard.len() <= MAX_TRACKED_SOURCES {
            return;
        }
        guard.remove(&key);
    }
    while guard.len() > MAX_TRACKED_SOURCES {
        let Some(key) = guard.keys().next().cloned() else {
            break;
        };
        guard.remove(&key);
    }
}

/// `__store` 固定窗口限频（每源每秒 [`STORE_MAX_PER_SECOND`] 次）
fn store_rate_allowed(source_url: &str) -> bool {
    static SLOT: OnceLock<RwLock<HashMap<String, (std::time::Instant, u32)>>> = OnceLock::new();
    let slot = SLOT.get_or_init(|| RwLock::new(HashMap::new()));
    let now = std::time::Instant::now();
    let mut guard = slot.write().unwrap_or_else(|p| p.into_inner());
    let entry = guard.entry(source_url.to_string()).or_insert((now, 0));
    if now.duration_since(entry.0) >= STORE_RATE_WINDOW {
        *entry = (now, 0);
    }
    if entry.1 >= STORE_MAX_PER_SECOND {
        return false;
    }
    entry.1 += 1;
    // 批21d P2-2：限频表条数上限（淘汰任意条目，最坏损失一个窗口状态）
    if guard.len() > MAX_TRACKED_SOURCES {
        if let Some(key) = guard.keys().find(|key| key.as_str() != source_url).cloned() {
            guard.remove(&key);
        }
    }
    true
}

/// `__prepare` 传入的 WebView UA（按源记忆，供后续宿主调用的请求头回落）
fn ua_slot() -> &'static RwLock<HashMap<String, String>> {
    static SLOT: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(HashMap::new()))
}

fn remember_ua(source_url: &str, ua: &str) {
    let mut guard = ua_slot().write().unwrap_or_else(|p| p.into_inner());
    guard.insert(source_url.to_string(), ua.to_string());
    // 批21d P2-2：UA 记忆表条数上限（淘汰任意非当前源条目）
    if guard.len() > MAX_TRACKED_SOURCES {
        if let Some(key) = guard.keys().find(|key| key.as_str() != source_url).cloned() {
            guard.remove(&key);
        }
    }
}

fn remembered_ua(source_url: &str) -> Option<String> {
    ua_slot()
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .get(source_url)
        .cloned()
}

/// 有效 UA：`__prepare` 记忆值 → 共享客户端默认 UA
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
        // 非 quickjs 构建：无 JS 引擎可执行宿主调用，`script` 为空串
        // （桥不可用，明确降级）；但快照仍返回——Dart 的 Cookie 预写与
        // 同步面摊平不依赖 JS 引擎（批21c P2-4：snapshot 生成与 quickjs 门控解耦）。
        let _ = (channel, callback);
        let snapshot = build_snapshot(&source, effective_ua(source_url));
        Ok(envelope_ok(json!({
            "script": "",
            "snapshot": snapshot,
            "bridgeAvailable": false,
        })))
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
        Ok(envelope_ok(json!({
            "script": script,
            "snapshot": snapshot,
            "bridgeAvailable": true,
        })))
    }
}

/// 只读快照（Dart 同步面摊平用）
///
/// `vars` 为全部 `v_<sourceUrl>_*` 键（去前缀），DB 兜底、内存覆盖；
/// 登录头/信息/源变量取自内存 + DB 单实现（`source_login_cache`）。
///
/// 批21c：`header` 一并回传（同步面 `source.header` 只读属性）；
/// 非 quickjs 构建跳过进程内变量表覆盖（仅 DB 兜底），快照仍可用。
fn build_snapshot(source: &RssSource, user_agent: String) -> Value {
    let prefix = format!("v_{}_", source.source_url);
    let mut vars = Map::new();
    // DB 兜底（跨进程/跨页面）
    for (key, value) in db_cache_prefix(&prefix) {
        if let Some(rest) = key.strip_prefix(&prefix) {
            vars.insert(rest.to_string(), Value::String(value));
        }
    }
    // 进程内变量表覆盖（最新写优先；非 quickjs 构建无该表）
    #[cfg(feature = "quickjs")]
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
        "header": source.header.clone().unwrap_or_default(),
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
///
/// 批21c 安全口径（独立复核 P0-1/P0-3）：
/// - `java`/`source`/`cache` 与 `*Await` 只在本 IIFE 闭包内声明，
///   **不写 `window`**（`preloadJs` 经词法作用域可见）；
/// - 页面桥对象（Dart bootstrap 创建）读取后立即从 `window` 删除；
/// - 回填回调用 `Object.defineProperty` 定义为不可枚举、不可重定义
///   （`Object.getOwnPropertyNames` 仍可见属性名，见契约真机结论）。
#[cfg(feature = "quickjs")]
fn build_prepare_script(channel: &str, callback: &str, snapshot: &Value) -> String {
    // 用占位符替换而非 format!（脚本包含大量 `{`/`}`，双花括号易漏；
    // 替换值仅来自随机通道名/回调名与 JSON 字面量，不会被二次扫描）。
    PREPARE_SCRIPT_TEMPLATE
        .replace(
            "__LG_CHANNEL_NAME_LITERAL__",
            &js_literal(&Value::String(channel.to_string())),
        )
        .replace(
            "__LG_CALLBACK_NAME_LITERAL__",
            &js_literal(&Value::String(callback.to_string())),
        )
        .replace("__LG_SNAPSHOT_LITERAL__", &js_literal(snapshot))
}

/// 桥脚本模板（`__LG_*_LITERAL__` 占位符由 [`build_prepare_script`] 替换）
#[cfg(feature = "quickjs")]
const PREPARE_SCRIPT_TEMPLATE: &str = r#"(() => {
  // [批21a/21c] RSS 阅读 WebView preloadJs 宿主桥（Rust 生成，Dart 追加 preloadJs 后闭合）
  // 拼接口径（契约 §2.5）：script + preloadJs + "\n})();"
  //
  // 安全加固（批21c/21d）：
  // - java/source/cache 与 *Await 仅存在于本 IIFE 闭包（preloadJs 词法可见），
  //   不写入 window；
  // - 页面桥对象读取后立即从 window 删除（Android 15 实测 delete 生效，
  //   删除后 getOwnPropertyNames 不可见；iOS 无该全局，待验收）；
  // - 回填回调不可枚举、不可重定义；getOwnPropertyNames 仍可见其名。
  var __lgChannelName = __LG_CHANNEL_NAME_LITERAL__;
  var __lgCallbackName = __LG_CALLBACK_NAME_LITERAL__;
  var __lgSnapshot = __LG_SNAPSHOT_LITERAL__;
  var __lgPending = Object.create(null);
  var __lgSeq = 0;
  var __lgChannel = null;

  var __lgReply = function (id, ok, payload) {
    var pending = __lgPending[id];
    if (!pending) return;
    delete __lgPending[id];
    if (ok) { pending.resolve(payload); } else { pending.reject(payload); }
  };

  if (typeof window !== 'undefined') {
    try {
      var __lgRawChannel = window[__lgChannelName];
      if (__lgRawChannel && typeof __lgRawChannel.request === 'function') {
        __lgChannel = __lgRawChannel;
      }
    } catch (e) {}
    // 通道对象仅本闭包持有：立即从页面全局移除
    try { delete window[__lgChannelName]; } catch (e) {}
    // 回填回调不可枚举且不可重定义（for..in/Object.keys 不可见；
    // Object.getOwnPropertyNames 仍可见，见契约 §2.5 批21d 真机结论）
    try {
      Object.defineProperty(window, __lgCallbackName, {
        value: __lgReply,
        enumerable: false,
        configurable: false,
        writable: false
      });
    } catch (e) {
      try { window[__lgCallbackName] = __lgReply; } catch (e2) {}
    }
  }

  function __lgCall(method, args) {
    return new Promise(function (resolve, reject) {
      if (!__lgChannel || typeof __lgChannel.request !== 'function') {
        reject('RSS WebView 宿主通道不可用：' + __lgChannelName);
        return;
      }
      var id = 'rss_' + (++__lgSeq) + '_' + Date.now();
      __lgPending[id] = { resolve: resolve, reject: reject };
      try {
        __lgChannel.request(method, JSON.stringify(args || []), id);
      } catch (e) {
        delete __lgPending[id];
        reject(String(e));
      }
    });
  }

  // 同步写转发（fire-and-forget；失败不阻断页面脚本）
  function __lgStore(op, key, value) {
    try {
      if (__lgChannel && typeof __lgChannel.request === 'function') {
        __lgChannel.request('__store', JSON.stringify({ op: op, key: key, value: value }), 'store_' + (++__lgSeq));
      }
    } catch (e) {}
  }

  // 动作转发（java.open/toast/... → Dart __action）
  function __lgEmitAction(payload) {
    try {
      if (__lgChannel && typeof __lgChannel.request === 'function') {
        __lgChannel.request('__action', JSON.stringify(payload || {}), 'act_' + (++__lgSeq));
      }
    } catch (e) {}
  }

  var __lgWarned = Object.create(null);
  function __lgWarnOnce(key, message) {
    if (__lgWarned[key]) return;
    __lgWarned[key] = true;
    __lgStore('log', null, message);
  }

  // 异步宿主函数（与原版 WebJsExtensions.request funName 同名；闭包内可见，不挂 window）
  var run = function (jsCode) { return __lgCall('run', [String(jsCode)]); };
  var ajaxAwait = function (url, callTimeout) {
    return __lgCall('ajaxAwait', [String(url), callTimeout == null ? null : String(callTimeout)]);
  };
  var connectAwait = function (url, header, callTimeout) {
    return __lgCall('connectAwait', [String(url), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
  };
  var getAwait = function (url, header, callTimeout) {
    return __lgCall('getAwait', [String(url), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
  };
  var headAwait = function (url, header, callTimeout) {
    return __lgCall('headAwait', [String(url), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
  };
  var postAwait = function (url, body, header, callTimeout) {
    return __lgCall('postAwait', [String(url), String(body), header == null ? null : String(header), callTimeout == null ? null : String(callTimeout)]);
  };
  var webViewAwait = function (html, url, js, cacheFirst) {
    return __lgCall('webViewAwait', [html == null ? null : String(html), url == null ? null : String(url), js == null ? null : String(js), cacheFirst == null ? null : !!cacheFirst]);
  };
  var webViewGetSourceAwait = function (html, url, js, sourceRegex, cacheFirst, delayTime) {
    return __lgCall('webViewGetSourceAwait', [
      html == null ? null : String(html),
      url == null ? null : String(url),
      js == null ? null : String(js),
      sourceRegex == null ? null : String(sourceRegex),
      cacheFirst == null ? null : !!cacheFirst,
      delayTime == null ? null : String(delayTime)
    ]);
  };
  var decryptStrAwait = function (transformation, key, iv, data) {
    return __lgCall('decryptStrAwait', [String(transformation), String(key), iv == null ? null : String(iv), String(data)]);
  };
  var encryptBase64Await = function (transformation, key, iv, data) {
    return __lgCall('encryptBase64Await', [String(transformation), String(key), iv == null ? null : String(iv), String(data)]);
  };
  var encryptHexAwait = function (transformation, key, iv, data) {
    return __lgCall('encryptHexAwait', [String(transformation), String(key), iv == null ? null : String(iv), String(data)]);
  };
  var createSignHexAwait = function (algorithm, publicKey, privateKey, data) {
    return __lgCall('createSignHexAwait', [String(algorithm), String(publicKey), String(privateKey), String(data)]);
  };
  var downloadFileAwait = function (url) { return __lgCall('downloadFileAwait', [String(url)]); };
  var readTxtFileAwait = function (path) { return __lgCall('readTxtFileAwait', [String(path)]); };
  var importScriptAwait = function (url) { return __lgCall('importScriptAwait', [String(url)]); };
  var getStringAwait = function (ruleStr, mContent) {
    return __lgCall('getStringAwait', [ruleStr == null ? null : String(ruleStr), mContent == null ? null : String(mContent)]);
  };

  // source 垫片：同步读内联快照，写异步转发（__store）
  var __lgVars = __lgSnapshot.vars || {};
  var __lgSourceVariable = __lgSnapshot.sourceVariable == null ? '' : String(__lgSnapshot.sourceVariable);
  var __lgLoginHeader = __lgSnapshot.loginHeader == null ? null : String(__lgSnapshot.loginHeader);
  var __lgLoginInfo = __lgSnapshot.loginInfo == null ? null : String(__lgSnapshot.loginInfo);
  var source = {
    get: function (k) {
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(__lgVars, key) ? String(__lgVars[key]) : '';
    },
    getKey: function () { return __lgSnapshot.sourceUrl; },
    getUrl: function () { return __lgSnapshot.sourceUrl; },
    getTag: function () { return __lgSnapshot.sourceName || ''; },
    key: __lgSnapshot.sourceUrl,
    url: __lgSnapshot.sourceUrl,
    put: function (k, v) {
      var key = String(k);
      var value = String(v);
      __lgVars[key] = value;
      __lgStore('sourcePut', key, value);
      return value;
    },
    getVariable: function () { return __lgSourceVariable; },
    setVariable: function (v) {
      var value = String(v);
      __lgSourceVariable = value;
      __lgStore('sourceVariableSet', null, value);
      return value;
    },
    putVariable: function (v) { return this.setVariable(v); },
    getLoginHeader: function () { return __lgLoginHeader ? String(__lgLoginHeader) : null; },
    putLoginHeader: function (h) {
      var value = String(h);
      __lgLoginHeader = value;
      __lgStore('loginHeaderSet', null, value);
    },
    removeLoginHeader: function () {
      __lgLoginHeader = null;
      __lgStore('loginHeaderRemove', null, null);
    },
    getLoginHeaderMap: function () {
      try { return __lgLoginHeader ? JSON.parse(__lgLoginHeader) : null; } catch (e) { return null; }
    },
    getLoginInfo: function () { return __lgLoginInfo ? String(__lgLoginInfo) : null; },
    putLoginInfo: function (i) {
      var value = String(i);
      __lgLoginInfo = value;
      __lgStore('loginInfoSet', null, value);
      return true;
    },
    removeLoginInfo: function () {
      __lgLoginInfo = null;
      __lgStore('loginInfoRemove', null, null);
    },
    getLoginInfoMap: function () {
      var data = {};
      try { data = __lgLoginInfo ? (JSON.parse(__lgLoginInfo) || {}) : {}; } catch (e) { data = {}; }
      data.get = function (k) { return this[k] == null ? null : this[k]; };
      data.put = function (k, v) {
        this[k] = String(v);
        source.putLoginInfo(JSON.stringify(this));
        return v;
      };
      return data;
    },
    hasLogin: function () { return !!(__lgSnapshot.loginUrl || __lgSnapshot.loginUi); },
    login: function () {
      __lgStore('log', 'rss-webview', 'source.login() 未在 WebView 宿主桥实现（请用 source.putLoginHeader/putLoginInfo）');
    }
  };
  // 只读源身份属性（批21c P2-5：缺失会让 preloadJs 抛 TypeError 中断）
  try {
    Object.defineProperty(source, 'sourceUrl', {
      get: function () { return __lgSnapshot.sourceUrl || ''; }, enumerable: true, configurable: false
    });
    Object.defineProperty(source, 'sourceName', {
      get: function () { return __lgSnapshot.sourceName || ''; }, enumerable: true, configurable: false
    });
    Object.defineProperty(source, 'loginUrl', {
      get: function () { return __lgSnapshot.loginUrl || ''; }, enumerable: true, configurable: false
    });
    Object.defineProperty(source, 'loginUi', {
      get: function () { return __lgSnapshot.loginUi || ''; }, enumerable: true, configurable: false
    });
    Object.defineProperty(source, 'header', {
      get: function () { return __lgSnapshot.header || ''; }, enumerable: true, configurable: false
    });
  } catch (e) {
    source.sourceUrl = __lgSnapshot.sourceUrl || '';
    source.sourceName = __lgSnapshot.sourceName || '';
    source.loginUrl = __lgSnapshot.loginUrl || '';
    source.loginUi = __lgSnapshot.loginUi || '';
    source.header = __lgSnapshot.header || '';
  }

  // cache 垫片：同步读页面镜像，写异步落 cache_store（与 run 内 cache 同源）
  var __lgCacheMirror = Object.create(null);
  var cache = {
    get: function (k) {
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(__lgCacheMirror, key) ? __lgCacheMirror[key] : null;
    },
    put: function (k, v) {
      var key = String(k);
      var value = String(v);
      __lgCacheMirror[key] = value;
      __lgStore('cachePut', key, value);
      return value;
    },
    remove: function (k) {
      var key = String(k);
      delete __lgCacheMirror[key];
      __lgStore('cacheRemove', key, null);
      return true;
    },
    putMemory: function (k, v) {
      var key = String(k);
      var value = String(v);
      __lgCacheMirror[key] = value;
      __lgStore('cachePutMemory', key, value);
    },
    getFromMemory: function (k) {
      var key = String(k);
      return Object.prototype.hasOwnProperty.call(__lgCacheMirror, key) ? __lgCacheMirror[key] : null;
    },
    deleteMemory: function (k) {
      var key = String(k);
      delete __lgCacheMirror[key];
      __lgStore('cacheDeleteMemory', key, null);
      return true;
    }
  };

  // java 垫片：同步网络/加密/解析面一律引导 *Await（平台差异已登记）
  function __lgSyncUnsupported(name, suggestion) {
    var msg = 'WebView 同步宿主调用不可用：java.' + name + '，请改用 ' + suggestion;
    __lgStore('log', 'rss-webview', msg);
    throw new Error(msg);
  }
  function __lgPad2(n) { return (n < 10 ? '0' : '') + n; }
  function __lgUUID() {
    var chars = '0123456789abcdef';
    var out = '';
    for (var i = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) out += '-';
      else if (i === 14) out += '4';
      else if (i === 19) out += chars.charAt(8 + (Math.random() * 4 | 0));
      else out += chars.charAt(Math.random() * 16 | 0);
    }
    return out;
  }
  var java = {
    request: function (funName, args, id) {
      try {
        __lgChannel.request(String(funName), JSON.stringify(args || []), String(id == null ? '' : id));
      } catch (e) {}
    },
    put: function (k, v) { return source.put(String(k), String(v)); },
    get: function (urlOrKey) {
      if (arguments.length <= 1) return source.get(String(urlOrKey));
      return __lgSyncUnsupported('get', 'getAwait');
    },
    ajax: function () { return __lgSyncUnsupported('ajax', 'ajaxAwait'); },
    connect: function () { return __lgSyncUnsupported('connect', 'connectAwait'); },
    post: function () { return __lgSyncUnsupported('post', 'postAwait'); },
    head: function () { return __lgSyncUnsupported('head', 'headAwait'); },
    webView: function () { return __lgSyncUnsupported('webView', 'webViewAwait'); },
    webViewGetSource: function () { return __lgSyncUnsupported('webViewGetSource', 'webViewGetSourceAwait'); },
    downloadFile: function () { return __lgSyncUnsupported('downloadFile', 'downloadFileAwait'); },
    readTxtFile: function () { return __lgSyncUnsupported('readTxtFile', 'readTxtFileAwait'); },
    importScript: function () { return __lgSyncUnsupported('importScript', 'importScriptAwait'); },
    getString: function () { return __lgSyncUnsupported('getString', 'getStringAwait'); },
    getStringList: function () { return __lgSyncUnsupported('getStringList', 'getStringAwait'); },
    createSymmetricCrypto: function () {
      return __lgSyncUnsupported('createSymmetricCrypto', 'decryptStrAwait/encryptBase64Await/encryptHexAwait');
    },
    createSign: function () { return __lgSyncUnsupported('createSign', 'createSignHexAwait'); },
    getCookie: function () { return __lgSyncUnsupported('getCookie', 'source.getLoginHeader()'); },
    setCookie: function () { return __lgSyncUnsupported('setCookie', 'source.putLoginHeader()'); },
    toast: function (msg) { __lgEmitAction({ action: 'toast', message: String(msg), long: false }); return String(msg); },
    longToast: function (msg) { __lgEmitAction({ action: 'toast', message: String(msg), long: true }); return String(msg); },
    log: function (msg) { __lgEmitAction({ action: 'log', message: String(msg) }); return String(msg); },
    // 批21c P2-5：常用工具引导桩（缺失会 TypeError 中断 preloadJs）
    randomUUID: function () { return __lgUUID(); },
    timeFormat: function (time) {
      var d = new Date(Number(time));
      if (isNaN(d.getTime())) return '';
      return d.getFullYear() + '/' + __lgPad2(d.getMonth() + 1) + '/' + __lgPad2(d.getDate()) +
        ' ' + __lgPad2(d.getHours()) + ':' + __lgPad2(d.getMinutes());
    },
    htmlFormat: function (str) {
      __lgWarnOnce('htmlFormat', 'java.htmlFormat 为本地简化实现（原样返回，不做 HTML 美化）');
      return String(str == null ? '' : str);
    },
    t2s: function (text) {
      __lgWarnOnce('t2s', 'java.t2s 为本地简化实现（原样返回，不做繁简转换）');
      return String(text == null ? '' : text);
    },
    s2t: function (text) {
      __lgWarnOnce('s2t', 'java.s2t 为本地简化实现（原样返回，不做简繁转换）');
      return String(text == null ? '' : text);
    }
  };

  // 不写 window.java/source/cache：三者只在本 IIFE 闭包（preloadJs 词法可见）。
  // 注意：这只保证「脚本自身不写全局」；URL 模式下页面脚本仍可经平台注入
  // 面（可枚举性见真机结论）触达桥能力，属已登记的原版等价语义。
  // __LEGADO_PRELOAD_JS__
"#;

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
    // 批21c P2-10：页面写穿限频（每源每秒 300 次，超出明确拒绝）
    if !store_rate_allowed(source_url) {
        return Ok(envelope_error(format!(
            "__store 调用过于频繁（>{STORE_MAX_PER_SECOND}/s），已拒绝"
        )));
    }
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
            // 批21d P2-3：同步写引擎变量表（与 Remove 对称）。已存在的
            // 引擎只在创建时跑 setup 种子，若不写变量表，`run` 内
            // `source.getLoginHeader()` 会读不到 WebView 刚写入的新值。
            let var_key = format!("loginHeader_{source_url}");
            if let Err(e) = legado_js::host_api::variable_store::set_variable(&var_key, value) {
                log::warn!("[rss-web-bridge] 写入登录头变量失败（{var_key}）: {e}");
            }
            Value::String(value.to_string())
        }
        "loginHeaderRemove" => {
            if let Err(e) = crate::api::source_login_cache::remove_login_header(source_url) {
                log::warn!("[rss-web-bridge] 清除登录头失败（{source_url}）: {e}");
            }
            // 批21c P2-8 / 批21d P2-3：同步清除引擎变量表（与 Set 对称；
            // 否则下次 setup 的 null seed 不会覆盖旧值，`source.getLoginHeader()`
            // 在 run 内仍读到旧登录头）。variable_store 无 quickjs 门控。
            let var_key = format!("loginHeader_{source_url}");
            if let Err(e) = legado_js::host_api::variable_store::remove_variable(&var_key) {
                log::warn!("[rss-web-bridge] 清除登录头变量失败（{var_key}）: {e}");
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
            let var_key = format!("userInfo_{source_url}");
            if let Err(e) = legado_js::host_api::variable_store::remove_variable(&var_key) {
                log::warn!("[rss-web-bridge] 清除用户信息变量失败（{var_key}）: {e}");
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
// 统一走 `java.connect`（RESPONSE_BRIDGE_JS 的 StrResponse 语义），显式透传
// callTimeout（批21c P2-6：此前 get/post/head 丢弃 callTimeout）。
function __lgConnect(method, url, headers, body, callTimeout) {
  var args = [String(url), String(method), headers];
  if (body !== null && body !== undefined) {
    args.push(String(body));
  }
  if (callTimeout !== null && callTimeout !== undefined && String(callTimeout) !== '') {
    var __timeoutMs = Number(callTimeout);
    if (isNaN(__timeoutMs)) __timeoutMs = 9000;
    if (args.length === 3) args.push('');
    args.push(__timeoutMs);
  }
  return java.connect.apply(null, args);
}
globalThis.__lgWebHost = {
  run: function (jsCode) {
    // 间接 eval（`(0, eval)`）在全局作用域执行：`var` 声明跨调用持久，
    // 对齐原版 evalJS 的全局语义（批21c P2-3：直接 eval 的 var 只活在
    // run 函数作用域，`run('var x=1')` 后再 `run('x')` 会 ReferenceError）。
    var __code = String(jsCode);
    var __indirectEval = eval;
    return String((0, __indirectEval)(__code));
  },
  ajaxAwait: function (url, callTimeout) {
    return String(java.ajax(String(url), callTimeout == null ? 9000 : Number(callTimeout)));
  },
  connectAwait: function (url, header, callTimeout) {
    var r = __lgConnect('GET', url, __lgHeadersJson(header), null, callTimeout);
    return JSON.stringify({
      statusCode: r.code(),
      body: r.body(),
      headers: r.raw().headers(),
      url: r.raw().request().url()
    });
  },
  getAwait: function (url, header, callTimeout) {
    // 走 java.get（jsoup 语义：不跟随重定向），可选 callTimeout 透传
    var args = [String(url), __lgHeadersJson(header)];
    if (callTimeout != null && String(callTimeout) !== '') args.push(callTimeout);
    var r = java.get.apply(null, args);
    return String(r.body());
  },
  headAwait: function (url, header, callTimeout) {
    var args = [String(url), __lgHeadersJson(header)];
    if (callTimeout != null && String(callTimeout) !== '') args.push(callTimeout);
    var r = java.head.apply(null, args);
    return JSON.stringify(r.headersMap());
  },
  postAwait: function (url, body, header, callTimeout) {
    var args = [String(url), String(body), __lgHeadersJson(header)];
    if (callTimeout != null && String(callTimeout) !== '') args.push(callTimeout);
    var r = java.post.apply(null, args);
    return String(r.body());
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
    // 批21c P2-10 / 批21d P2-2：每源并发上限（2-4；`run`/网络/加解密一律
    // 计入）。许可持有到本次调用结束；等待超时则明确回填错误。
    let _permit = match bridge_permit(&source.source_url) {
        Ok(permit) => permit,
        Err(message) => return Ok(envelope_error(message)),
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

    let ledger_tag = format!("rss-webview:{}", source.source_url);
    let js_lib_raw = source
        .js_lib
        .as_deref()
        .map(legado_fetcher::js_adapter::sanitize_js_lib_for_quickjs);
    // 批21c P2-2：URL 映射形态 jsLib（`{"k":"https://…js"}`）不是合法 JS，
    // 不能直接交给 engine_cache。先经 jslib_loader 解析为可 eval 脚本
    // （拉取 + 进程缓存 + 逐条降级台账），与 QuickJsExecutor 的 run_fresh
    // 路径同源；全失败则明确报错。
    let js_lib = match js_lib_raw {
        Some(lib) if legado_js::host_api::jslib_loader::parse_js_lib_url_map(&lib).is_some() => {
            match legado_js::host_api::jslib_loader::resolve_js_lib_url_map(
                &lib,
                &ledger_tag,
                &legado_js::host_api::jslib_loader::default_js_lib_fetcher,
            ) {
                Some(script) => Some(script),
                None => {
                    return Ok(envelope_error(
                        "RSS 源 jsLib（URL 映射）加载失败：宿主桥不可用",
                    ))
                }
            }
        }
        other => other,
    };
    let login_header = crate::api::source_login_cache::get_login_header(&source.source_url);
    let login_info = crate::api::source_login_cache::get_login_info(&source.source_url);
    let setup = legado_fetcher::source_setup::rss_source_js_setup_script(
        &source,
        login_header.as_deref(),
        login_info.as_deref(),
    )?;
    // 批21c P2-1：独立引擎键（避免与规则链 `executor:<sourceUrl>` 的
    // 5s 默认超时/不同 setup 相互抖动重建）
    let key = ledger_tag;
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
    #[cfg(feature = "quickjs")]
    use legado_js::JsEngine;

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
            "legadoChannel",
            "legadoCb",
            "delete window[__lgChannelName]",
            "Object.defineProperty(window, __lgCallbackName",
            "enumerable: false",
            "var java = {",
            "var source = {",
            "var cache = {",
            "var ajaxAwait = function",
            "randomUUID",
            "timeFormat",
            "// __LEGADO_PRELOAD_JS__",
        ] {
            assert!(script.contains(needle), "脚本缺少 {needle}: {script}");
        }
        for forbidden in [
            "window.java = java",
            "window.source = source",
            "window.cache = cache",
            "window[__lgName]",
        ] {
            assert!(
                !script.contains(forbidden),
                "桥对象不得写入页面全局：{forbidden}"
            );
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

        // 批21d P2-3：loginHeaderSet 必须同步写变量表（与 Remove 对称）
        let header = r#"{"X-Token":"t9"}"#;
        let env = call(
            url_a,
            "__store",
            json!([{ "op": "loginHeaderSet", "value": header }]),
        );
        assert_eq!(env["ok"], true, "{env}");
        let var_key = format!("loginHeader_{url_a}");
        assert_eq!(
            legado_js::host_api::variable_store::get_variable(&var_key).unwrap(),
            Some(header.to_string()),
            "loginHeaderSet 必须同步引擎变量表"
        );
        let env = call(url_a, "__store", json!([{ "op": "loginHeaderRemove" }]));
        assert_eq!(env["ok"], true, "{env}");
        assert_eq!(
            legado_js::host_api::variable_store::get_variable(&var_key).unwrap(),
            None,
            "loginHeaderRemove 必须清除变量表"
        );

        // 清理
        for key in [
            format!("v_{url_a}_token"),
            format!("sourceVariable_{url_a}"),
        ] {
            with_database(|db| legado_db::CacheRepository::new(db.connection()).delete(&key)).ok();
        }
        crate::api::source_login_cache::remove_login_header(url_a).ok();
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

    /// 非 quickjs 构建：`__prepare` 仍返回快照（Dart Cookie 预写/同步面），
    /// `script` 为空串；宿主方法明确降级（不静默假成功）
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn quickjs_off_degrades_explicitly() {
        let _guard = crate::db_state::ensure_test_db();
        let url = "https://rss-web-bridge-off.test/feed";
        add_source(url, json!({ "preloadJs": "1 + 1" }));
        let prepare = call(
            url,
            "__prepare",
            json!([{ "channelName": "ch", "callbackName": "cb", "ua": "UA-Off" }]),
        );
        assert_eq!(prepare["ok"], true, "{prepare}");
        assert_eq!(prepare["value"]["script"], "");
        assert_eq!(prepare["value"]["bridgeAvailable"], false);
        assert_eq!(prepare["value"]["snapshot"]["sourceUrl"], url);
        assert_eq!(prepare["value"]["snapshot"]["userAgent"], "UA-Off");
        for (method, args) in [
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

    /// 批21c P0-1 红→绿：在真实 QuickJS 中执行 Rust 生成的完整脚本，
    /// 断言 `window.java/source/cache/<channel>/<bridge>` 均不存在、
    /// 回填回调不可枚举、preloadJs 仍能经闭包访问宿主与快照。
    #[cfg(feature = "quickjs")]
    #[test]
    fn generated_script_keeps_bridge_in_closure_and_cleans_globals() {
        let _guard = crate::db_state::ensure_test_db();
        let url = "https://rss-web-bridge-closure.test/feed";
        add_source(
            url,
            json!({ "preloadJs": "probe", "header": "{\"X-H\":\"1\"}" }),
        );
        crate::api::source_login_cache::put_login_header(url, r#"{"Cookie":"sid=1"}"#).unwrap();
        let env = call(
            url,
            "__store",
            json!([{ "op": "sourcePut", "key": "k", "value": "v" }]),
        );
        assert_eq!(env["ok"], true, "{env}");

        let source = load_rss_source(url).unwrap().expect("源存在");
        let snapshot = build_snapshot(&source, "UA-Closure".to_string());
        let channel = "__lgTestChannel";
        let callback = "__lgTestCallback";
        let head = build_prepare_script(channel, callback, &snapshot);
        let preload = r#"
globalThis.__probe = {
  javaGlobal: typeof window.java,
  sourceGlobal: typeof window.source,
  cacheGlobal: typeof window.cache,
  channelGlobal: typeof window["__lgTestChannel"],
  ajaxGlobal: typeof window.ajaxAwait,
  callbackType: typeof window["__lgTestCallback"],
  callbackEnumerable: Object.getOwnPropertyDescriptor(window, "__lgTestCallback").enumerable,
  callbackConfigurable: Object.getOwnPropertyDescriptor(window, "__lgTestCallback").configurable,
  callbackInKeys: Object.keys(window).indexOf("__lgTestCallback") >= 0,
  sourceUrl: source.sourceUrl,
  sourceName: source.sourceName,
  loginUrl: source.loginUrl,
  sourceHeader: source.header,
  varGet: source.get("k"),
  loginHeader: source.getLoginHeader(),
  loginInfo: source.getLoginInfo(),
  uuidLen: java.randomUUID().length,
  timeFormat: java.timeFormat(0),
  htmlFormat: java.htmlFormat("<b>x</b>"),
  t2s: java.t2s("a"),
  awaitThen: typeof ajaxAwait("https://x").then,
  runType: typeof run
};
source.put("nk", "nv");
java.request("ajaxAwait", "[]", "id-1");
"#;
        let script = format!("{head}{preload}\n}})();");
        let engine = legado_js::QuickJsEngine::new(
            legado_js::SandboxConfig::default().with_allow_script_run(true),
        )
        .expect("创建 QuickJS 引擎");
        engine
            .eval(
                r#"var window = {};
window["__lgTestChannel"] = {
  request: function (m, a, i) {
    globalThis.__req = globalThis.__req || [];
    globalThis.__req.push([m, a, i]);
  }
};"#,
            )
            .expect("注入假通道");
        legado_js::JsEngine::eval(&engine, &script).expect("生成的脚本必须可执行");

        let raw = legado_js::JsEngine::eval(&engine, "JSON.stringify(globalThis.__probe)")
            .expect("读取探针");
        let probe: Value = serde_json::from_str(&raw).expect("探针 JSON");
        for key in [
            "javaGlobal",
            "sourceGlobal",
            "cacheGlobal",
            "channelGlobal",
            "ajaxGlobal",
        ] {
            assert_eq!(probe[key], "undefined", "桥对象不得残留全局：{key}");
        }
        assert_eq!(probe["callbackType"], "function");
        assert_eq!(probe["callbackEnumerable"], false, "回填回调必须不可枚举");
        assert_eq!(
            probe["callbackConfigurable"], false,
            "回填回调必须不可重定义（批21d P0-B）"
        );
        assert_eq!(probe["callbackInKeys"], false);
        assert_eq!(probe["sourceUrl"], url);
        assert_eq!(probe["sourceName"], "宿主桥测试源");
        assert_eq!(probe["loginUrl"], "");
        assert_eq!(probe["sourceHeader"], r#"{"X-H":"1"}"#);
        assert_eq!(probe["varGet"], "v");
        assert_eq!(probe["loginHeader"], r#"{"Cookie":"sid=1"}"#);
        assert_eq!(probe["loginInfo"], Value::Null);
        assert_eq!(probe["uuidLen"], 36);
        let time_text = probe["timeFormat"].as_str().unwrap_or_default();
        assert_eq!(time_text.len(), 16, "yyyy/MM/dd HH:mm: {time_text}");
        assert!(
            time_text.contains('/') && time_text.contains(':'),
            "{time_text}"
        );
        assert_eq!(probe["htmlFormat"], "<b>x</b>");
        assert_eq!(probe["t2s"], "a");
        assert_eq!(probe["awaitThen"], "function");
        assert_eq!(probe["runType"], "function");

        let req_raw = legado_js::JsEngine::eval(&engine, "JSON.stringify(globalThis.__req)")
            .expect("读取通道请求");
        let requests: Value = serde_json::from_str(&req_raw).expect("请求 JSON");
        let requests = requests.as_array().expect("请求数组");
        assert!(
            requests.iter().any(|item| item[0] == "__store"
                && item[1]
                    .as_str()
                    .unwrap_or_default()
                    .contains("\"op\":\"sourcePut\"")),
            "source.put 必须经 __store 转发：{requests:?}"
        );
        assert!(
            requests
                .iter()
                .any(|item| item[0] == "ajaxAwait" && item[2] == "id-1"),
            "java.request 必须转发到闭包捕获的通道：{requests:?}"
        );

        crate::api::source_login_cache::remove_login_header(url).ok();
        crate::api::rss::delete_rss_source(url).ok();
    }
}
