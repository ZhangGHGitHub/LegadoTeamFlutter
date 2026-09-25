//! 书源引擎「能力对账 + 离线干跑清扫」测试入口（新增测试文件，不修改任何生产代码）
//!
//! 背景：七猫（缺 `java.security.MessageDigest`）、77读书（缺 jsoup Elements 集合 API）
//! 两次真实搜索失败均为引擎能力缺口，且都可在「无网络干跑」中提前暴露
//! （jsLib 与 searchUrl 的 JS 先于网络执行）。本测试对全语料做两件事：
//!
//! 1. **静态能力对账**（默认档运行，快、离线）：扫描全语料各源 JS 片段中的
//!    符号引用（`Packages.<路径>`、`java.<方法>(`、`cookie.<方法>(`、`cache.<方法>(`、
//!    裸宿主函数调用、`Java.type`/`importClass`、裸 `JSoup`/`javax`/`android` 等），
//!    与 quickjs_impl.rs 已注册能力面做差集，产出
//!    「符号 → 引用源数 → 示例源 → 是否提供 → 缺失时可实现性评估」。
//!
//! 2. **离线干跑**（`#[ignore]`，用 `-- --ignored` 运行）：逐源用生产同源引擎
//!    （`SandboxConfig::default().with_allow_script_run(true).with_memory_limit(64MB)`）
//!    执行 jsLib + searchUrl 的全部 JS 块；网络函数在 setup 后整体替换为记录器
//!    （零真实联网），逐源独立线程隔离 panic；按
//!    a) 缺失 Java 能力 / b) JS 语法·引用错误 / c) 触网·离线不可判 / d) 引擎内部错误
//!    分类聚合，缺失能力按「符号 → 源数」排行。
//!
//! 运行方式：
//! ```bash
//! # 静态对账（默认档，秒级）
//! cargo test -p legado-ffi --features quickjs --test capability_sweep
//! # 全量离线干跑（分钟级；语料缺失时优雅跳过）
//! cargo test -p legado-ffi --features quickjs --test capability_sweep -- --ignored
//! ```
//!
//! 输出（均写入仓库根 `.tmp/capability_sweep/`，不入库）：
//! - `static_report.md` / `static_report.json`：静态对账表
//! - `dry_run_report.md` / `dry_run_details.json`：干跑分类统计 + 缺失能力排行
//!
//! 语料路径：默认 `仓库根/.tmp/corpus/yckceo_1283.json`，可用环境变量
//! `LEGADO_CAP_SWEEP_CORPUS` 覆盖。

#![cfg(feature = "quickjs")]

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

use legado_ffi::api::source_js_bindings::book_source_js_setup_script;
use legado_ffi::legado_core::models::BookSource;
use legado_ffi::legado_js::engine::JsEngine;
use legado_ffi::legado_js::host_api::capability_ledger;
use legado_ffi::legado_js::host_api::current_source;
use legado_ffi::legado_js::sandbox::SandboxConfig;
use legado_ffi::legado_js::QuickJsEngine;

/// 能力面：quickjs_impl.rs 已注册的 164 个宿主函数（`java.*` 双挂载 + 裸全局）。
/// 提取自 `mount_dual(java, globals, "…")` / `java.set("…")` / `globals.set("…")`，
/// 与生产代码逐名一致（2026-09-25 快照，见 .tmp/capability_sweep/capability_names.txt）。
const CAPABILITY_NAMES: &[&str] = &[
    "__lgBookSetReverseToc",
    "__lgBookSetType",
    "__lgBookVarDel",
    "__lgBookVarGet",
    "__lgBookVarSet",
    "__lgStoreGet",
    "__lgStorePut",
    "aesBase64DecodeToString",
    "aesDecodeToString",
    "aesDecrypt",
    "aesDecryptBytes",
    "aesEncrypt",
    "ajax",
    "ajaxAll",
    "ajaxTestAll",
    "androidId",
    "base64Decode",
    "base64DecodeToByteArray",
    "base64Encode",
    "base64EncodeBytes",
    "bytesToStr",
    "cacheFile",
    "clearCookies",
    "clearTtsCache",
    "clearVariables",
    "connect",
    "connectNR",
    "copyText",
    "createAsymmetricCrypto",
    "createSign",
    "createSymmetricCrypto",
    "currentTimeMillis",
    "deleteFile",
    "desDecrypt",
    "desEncrypt",
    "digestBase64Str",
    "digestHex",
    "downloadFile",
    "encodeURI",
    "encodeURIComponent",
    "fileExists",
    "formatTime",
    "get",
    "get7zStringContent",
    "getCookie",
    "getElement",
    "getElements",
    "getFile",
    "getRarStringContent",
    "getReadBookConfig",
    "getReadBookConfigMap",
    "getSource",
    "getString",
    "getStringList",
    "getStrings",
    "getTag",
    "getThemeConfig",
    "getThemeConfigMap",
    "getThemeMode",
    "getTxtInFolder",
    "getVariable",
    "getVerificationCode",
    "getWebViewUA",
    "getZipStringContent",
    "head",
    "hexDecode",
    "hexDecodeToByteArray",
    "hexDecodeToString",
    "hexEncode",
    "hmacBase64",
    "hmacHex",
    "hmacMd5",
    "hmacSha256",
    "htmlFormat",
    "htmlFormatWithTags",
    "httpGet",
    "httpHead",
    "httpPost",
    "importScript",
    "inflateRawBytes",
    "jsonGetString",
    "jsonPath",
    "jsoupAttr",
    "jsoupAttrN",
    "jsoupHtml",
    "jsoupHtmlN",
    "jsoupHtmlNExcluded",
    "jsoupSize",
    "jsoupText",
    "jsoupTextN",
    "jsoupUnescapeEntities",
    "lock",
    "log",
    "logType",
    "longToast",
    "md5Encode",
    "md5Encode16",
    "messageDigestDigest",
    "messageDigestValidate",
    "openUrl",
    "openVideoPlayer",
    "parseTime",
    "post",
    "put",
    "putGlobalHeaders",
    "queryBase64TTF",
    "queryTTF",
    "randomUUID",
    "rc4Decrypt",
    "rc4Encrypt",
    "reGetBook",
    "reLoginView",
    "readFile",
    "readTxtFile",
    "refreshBookInfo",
    "refreshBookToc",
    "refreshContent",
    "refreshExplore",
    "refreshTocUrl",
    "regExp",
    "regExpFindAll",
    "regExpReplace",
    "removeCookie",
    "removeVariable",
    "replaceAll",
    "replaceFirst",
    "replaceFont",
    "reportUnknownSymbol",
    "s2t",
    "setContent",
    "setCookie",
    "setLocal",
    "setVariable",
    "sha256",
    "showBrowser",
    "singleFlight",
    "startBrowser",
    "startBrowserAwait",
    "strToBytes",
    "substringAfter",
    "substringBefore",
    "t2s",
    "threadSleep",
    "tick",
    "timeFormat",
    "timeFormatUTC",
    "toJson",
    "toNumChapter",
    "toURL",
    "toUrl",
    "toast",
    "trimEnd",
    "trimStart",
    "un7zFile",
    "unArchiveFile",
    "unrarFile",
    "unzipFile",
    "upLoginData",
    "urldecode",
    "urlencode",
    "webView",
    "webViewGetOverrideUrl",
    "webViewGetSource",
    "writeFile",
];

/// 文件类 API：仅在 `allow_file_access=true` 时注册；**生产配置为 false**，
/// 即这 9 个名字在生产的 QuickJS 引擎里不存在——源引用即缺口。
const FILE_GATED_NAMES: &[&str] = &[
    "cacheFile",
    "deleteFile",
    "downloadFile",
    "fileExists",
    "getFile",
    "getTxtInFolder",
    "readFile",
    "readTxtFile",
    "writeFile",
];

/// Packages 已知树（quickjs_impl.rs `__pkRoot`，类级）。
/// 未知类/成员 → 记台账并抛「此书源需要 Java 脚本能力（Packages.…）」。
const PACKAGES_KNOWN: &[&str] = &[
    "java.lang.String",
    "java.lang.Integer",
    "java.lang.Long",
    "java.lang.Double",
    "java.lang.Boolean",
    "java.lang.Thread",
    "java.lang.System",
    "java.util.UUID",
    "java.util.Arrays",
    "java.util.HashMap",
    "java.util.zip.Inflater",
    "java.util.zip.InflaterInputStream",
    "java.io.ByteArrayInputStream",
    "java.io.ByteArrayOutputStream",
    "java.io.InputStream",
    "java.nio.ByteBuffer",
    "java.security.MessageDigest",
    "android.util.Base64",
    "cn.hutool.crypto.digest.DigestUtil",
    "javax.crypto.spec.SecretKeySpec",
    "javax.crypto.spec.IvParameterSpec",
    "javax.crypto.Cipher",
    "org.jsoup.Jsoup",
    "org.jsoup.parser.Parser",
];

/// 生产 Packages 树中的命名空间前缀（quickjs_impl.rs `__pkRoot`）：
/// 访问命名空间对象本身合法（仅未知成员触发 reportUnknownSymbol 陷阱），
/// 故「只引用到命名空间」的链不算缺失符号。
const PACKAGES_KNOWN_NS: &[&str] = &[
    "java.lang",
    "java.util",
    "java.util.zip",
    "java.io",
    "java.nio",
    "java.security",
    "javax.crypto",
    "javax.crypto.spec",
    "android.util",
    "cn.hutool",
    "cn.hutool.crypto",
    "org.jsoup",
];

/// 裸 java 全局镜像的命名空间（quickjs_impl.rs：`java.security` 与
/// `java.lang` 重新暴露同一 trapped 节点）
const BARE_JAVA_MIRROR_NS: &[&str] = &["java.lang", "java.security"];

/// 生产 setup 脚本 JS `cookie` 对象提供的方法（getCookie/setCookie/clearCookies/removeCookie）；
/// 原版 gedor CookieStore 的 `cookie.get/put/remove/clear` **未提供**。
const COOKIE_PROVIDED: &[&str] = &["getCookie", "setCookie", "clearCookies", "removeCookie"];

/// `cache` 对象提供的方法：setup 脚本 JS 对象（get/put/remove）∪ Rust 侧对象（get/put/delete/getFile/putFile）。
const CACHE_PROVIDED: &[&str] = &["get", "put", "remove", "delete", "getFile", "putFile"];

/// 裸调用观察名单（不在 164 能力面内、但书源常见的 Rhino/宿主符号）。
const BARE_WATCHLIST: &[&str] = &[
    "importClass",
    "print",
    "console",
    "require",
    "Runtime",
    "JSoup",
    "Jsoup",
    "jsoup",
    "JSOUP",
    "CryptoJS",
    "eval",
];

/// 离线干跑网络打补丁（测试专用）：把全部网络/浏览器/睡眠宿主函数替换为记录器，
/// 调用记入 `globalThis.__netCalls`。response 桥在注入时已捕获原生引用，
/// 此处整体替换 `java.connect`/`java.connectNR` 后原生路径即不可达 → 零真实联网。
const NETWORK_PATCH_JS: &str = r#"(function () {
  var netLog = (globalThis.__netCalls = globalThis.__netCalls || []);
  function argsOf() { var a = []; for (var i = 0; i < arguments.length; i++) a.push(typeof arguments[i] === 'string' ? arguments[i].slice(0, 120) : arguments[i]); return a.join(','); }
  function rec(name) { netLog.push(name + '(' + argsOf() + ')'); }
  function emptyResp() { return { header: '', headers: {}, body: '', statusCode: 200 }; }
  var j = globalThis.java;
  if (!j) return;
  j.ajax = function () { rec('ajax'); return ''; };
  j.ajaxAll = function () { rec('ajaxAll'); return []; };
  j.ajaxTestAll = function () { rec('ajaxTestAll'); return []; };
  j.httpGet = function () { rec('httpGet'); return ''; };
  j.httpPost = function () { rec('httpPost'); return ''; };
  j.httpHead = function () { rec('httpHead'); return ''; };
  j.connect = function () { rec('connect'); return emptyResp(); };
  j.connectNR = function () { rec('connectNR'); return ''; };
  j.head = function () { rec('head'); return emptyResp(); };
  j.post = function () { rec('post'); return emptyResp(); };
  var nativeGet = j.get;
  j.get = function () {
    if (arguments.length >= 2) { rec('get'); return emptyResp(); }
    return nativeGet.apply(null, arguments);
  };
  j.webView = function () { rec('webView'); return ''; };
  j.webViewGetSource = function () { rec('webViewGetSource'); return ''; };
  j.webViewGetOverrideUrl = function () { rec('webViewGetOverrideUrl'); return ''; };
  j.startBrowser = function () { rec('startBrowser'); return ''; };
  j.startBrowserAwait = function () { rec('startBrowserAwait'); return ''; };
  j.openUrl = function () { rec('openUrl'); return ''; };
  j.openVideoPlayer = function () { rec('openVideoPlayer'); return ''; };
  j.reLoginView = function () { rec('reLoginView'); return ''; };
  j.threadSleep = function () { rec('threadSleep'); };
  globalThis.connect = j.connect;
})();
"#;

/// 与 legado-parser `js_eval_uri_fallback_prologue` 逐字一致的 eval 包装
/// （URI 字面量 eval 失败时回退原字符串，兼容 `eval(String(Reload('…')))` 模式）。
const EVAL_URI_FALLBACK_JS: &str = r#"(function(){
  var __legadoNativeEval = globalThis.eval;
  if (typeof __legadoNativeEval !== 'function') return;
  if (globalThis.__legadoEvalUriFallback) return;
  globalThis.__legadoEvalUriFallback = true;
  globalThis.eval = function(code) {
    try {
      return __legadoNativeEval(code);
    } catch (err) {
      if (typeof code === 'string') {
        var t = code.replace(/^\s+|\s+$/g, '');
        if (/^(https?:|ftp:|data:|legado:|file:|\/\/)/i.test(t) || t.charAt(0) === '/') {
          return code;
        }
      }
      throw err;
    }
  };
})();
"#;

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sweep_dir() -> PathBuf {
    let dir = repo_root().join(".tmp").join("capability_sweep");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn corpus_path() -> PathBuf {
    if let Ok(p) = std::env::var("LEGADO_CAP_SWEEP_CORPUS") {
        return PathBuf::from(p);
    }
    repo_root()
        .join(".tmp")
        .join("corpus")
        .join("yckceo_1283.json")
}

fn load_corpus() -> Option<Vec<BookSource>> {
    let path = corpus_path();
    let raw = std::fs::read_to_string(&path).ok()?;
    serde_json_parse_sources(&raw)
}

/// 解析语料：语料是 `Vec<BookSource>` 的 JSON 数组，`BookSource` 自带 lenient
/// 反序列化器（未知字段/错型容忍），`serde_json` 是 legado-ffi 的直接依赖，
/// 集成测试可直接使用。
fn serde_json_parse_sources(raw: &str) -> Option<Vec<BookSource>> {
    serde_json::from_str(raw).ok()
}

/// JS 字符串字面量转义（等价 `serde_json::to_string(&String)` 的输出，供 `var x = …;` 前导）。
fn js_string_lit(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// 缺失符号的可实现性静态评估（先验启发式；干跑排行榜给出运行时实证）。
fn feasibility_hint(symbol: &str) -> &'static str {
    let s = symbol.to_lowercase();
    if s.contains("file")
        || s.contains("stream")
        || s.contains("network")
        || s.contains("http")
        || s.contains("connect")
        || s.contains("webview")
        || s.contains("browser")
        || s.contains("process")
        || s.contains("runtime")
        || s.contains("socket")
        || s.contains("thread")
        || s.contains("zip")
        || s.contains("rar")
        || s.contains("7z")
        || s.contains("login")
        || s.contains("cookie")
        || s.contains("url")
        || s.contains("localstorage")
    {
        "难：需真实 JVM/IO/网络栈（建议宿主桥接或标记不支持）"
    } else if s.contains("cipher")
        || s.contains("crypto")
        || s.contains("digest")
        || s.contains("hash")
        || s.contains("aes")
        || s.contains("des")
        || s.contains("hmac")
        || s.contains("md5")
        || s.contains("sha")
        || s.contains("rc4")
        || s.contains("base64")
        || s.contains("sign")
    {
        "可：纯计算/加解密（Rust crypto 库可实现）"
    } else if s.contains("json") || s.contains("string") || s.contains("map") || s.contains("list")
    {
        "可：纯计算/字符串（Rust 可实现）"
    } else {
        "可评估：默认按纯计算/字符串处理"
    }
}

// ---------------------------------------------------------------------------
// 静态符号扫描
// ---------------------------------------------------------------------------

fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$'
}

/// 扫描一段 JS 文本中的最大点链 token（`a.b.c` 形式，2 段以上，至多 6 段）。
/// 返回所有点链（不含前导 `Packages` 的完整链）。
fn scan_dotted_chains(text: &str, out: &mut BTreeSet<String>) {
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut i = 0;
    while i < n {
        if chars[i].is_ascii_alphabetic() || chars[i] == '_' || chars[i] == '$' {
            let mut segs: Vec<String> = Vec::new();
            let mut cur = String::new();
            // 第一段
            while i < n && is_ident_char(chars[i]) {
                cur.push(chars[i]);
                i += 1;
            }
            if cur.is_empty() {
                continue;
            }
            segs.push(cur.clone());
            // 后续点分段
            while i < n && chars[i] == '.' {
                // 前瞻下一段是否合法标识符（避免吃掉数字字面量 1.5 之类——前段以字母结尾才允许）
                let j = i + 1;
                if j >= n || !is_ident_char(chars[j]) {
                    break;
                }
                if segs.len() >= 6 {
                    break;
                }
                cur.clear();
                i += 1;
                while i < n && is_ident_char(chars[i]) {
                    cur.push(chars[i]);
                    i += 1;
                }
                if cur.is_empty() {
                    break;
                }
                segs.push(cur.clone());
            }
            if segs.len() >= 2 {
                out.insert(segs.join("."));
            }
        } else {
            i += 1;
        }
    }
}

/// 扫描所有「标识符(」裸调用 token（单段标识符紧跟左括号，允许中间空白）。
fn scan_bare_calls(text: &str, out: &mut BTreeSet<String>) {
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut i = 0;
    while i < n {
        if chars[i] == '(' {
            // 向左回扫标识符
            let mut j = i;
            while j > 0
                && (chars[j - 1] == ' '
                    || chars[j - 1] == '\t'
                    || chars[j - 1] == '\r'
                    || chars[j - 1] == '\n')
            {
                j -= 1;
            }
            let mut end = j;
            while end > 0 && is_ident_char(chars[end - 1]) {
                end -= 1;
            }
            if end < j {
                let name: String = chars[end..j].iter().collect();
                if !name.is_empty()
                    && name
                        .chars()
                        .next()
                        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_' || c == '$')
                {
                    out.insert(name);
                }
            }
        }
        i += 1;
    }
}

/// 从 BookSource 收集全部 JS 片段（label, text）。
fn collect_fragments(src: &BookSource) -> Vec<(&'static str, String)> {
    let mut out: Vec<(&'static str, String)> = Vec::new();
    if let Some(js_lib) = &src.js_lib {
        if !js_lib.is_empty() {
            out.push(("jsLib", js_lib.clone()));
        }
    }
    if let Some(search_url) = &src.search_url {
        if !search_url.is_empty() {
            out.push(("searchUrl", search_url.clone()));
        }
    }
    if let Some(rule) = &src.rule_search {
        let texts: &[&Option<String>] = &[
            &rule.check_key_word,
            &rule.book_list,
            &rule.name,
            &rule.author,
            &rule.intro,
            &rule.kind,
            &rule.last_chapter,
            &rule.update_time,
            &rule.book_url,
            &rule.cover_url,
            &rule.word_count,
        ];
        push_rule_texts(&mut out, "ruleSearch", texts);
    }
    if let Some(rule) = &src.rule_book_info {
        let texts: &[&Option<String>] = &[
            &rule.init,
            &rule.name,
            &rule.author,
            &rule.intro,
            &rule.kind,
            &rule.last_chapter,
            &rule.update_time,
            &rule.cover_url,
            &rule.toc_url,
            &rule.word_count,
            &rule.can_re_name,
            &rule.download_urls,
        ];
        push_rule_texts(&mut out, "ruleBookInfo", texts);
    }
    if let Some(rule) = &src.rule_toc {
        let texts: &[&Option<String>] = &[
            &rule.pre_update_js,
            &rule.chapter_list,
            &rule.chapter_name,
            &rule.chapter_url,
            &rule.format_js,
            &rule.is_volume,
            &rule.is_vip,
            &rule.is_pay,
            &rule.update_time,
            &rule.next_toc_url,
        ];
        push_rule_texts(&mut out, "ruleToc", texts);
    }
    if let Some(rule) = &src.rule_content {
        let texts: &[&Option<String>] = &[
            &rule.content,
            &rule.sub_content,
            &rule.title,
            &rule.next_content_url,
            &rule.web_js,
            &rule.source_regex,
            &rule.replace_regex,
            &rule.image_style,
            &rule.image_decode,
            &rule.pay_action,
            &rule.call_back_js,
        ];
        push_rule_texts(&mut out, "ruleContent", texts);
    }
    if let Some(explore_url) = &src.explore_url {
        if !explore_url.is_empty() {
            out.push(("exploreUrl", explore_url.clone()));
        }
    }
    if let Some(login_url) = &src.login_url {
        if !login_url.is_empty() {
            out.push(("loginUrl", login_url.clone()));
        }
    }
    out
}

fn push_rule_texts(
    out: &mut Vec<(&'static str, String)>,
    label: &'static str,
    texts: &[&Option<String>],
) {
    for s in texts.iter().filter_map(|t| t.as_ref()) {
        if !s.is_empty() {
            out.push((label, s.clone()));
        }
    }
}

/// 分类一条点链引用，返回 (符号键, 状态)。
fn classify_chain(chain: &str) -> Option<(String, &'static str)> {
    let path = chain;
    if let Some(rest) = path.strip_prefix("Packages.") {
        // 类级判定：完整路径或某已知类前缀（成员访问）命中
        let mut provided = false;
        for known in PACKAGES_KNOWN {
            if rest == *known || rest.starts_with(&format!("{known}.")) {
                provided = true;
                break;
            }
        }
        // 命名空间前缀：只引用到命名空间本身（生产树节点存在，不触发陷阱）
        let mut ns = false;
        if !provided {
            for k in PACKAGES_KNOWN_NS {
                if rest == *k || rest.starts_with(&format!("{k}.")) {
                    ns = true;
                    break;
                }
            }
        }
        let status = if provided {
            "提供（类级；成员级缺口由干跑台账实证）"
        } else if ns {
            "提供（命名空间前缀；叶子类级缺口由干跑台账实证）"
        } else {
            "缺失"
        };
        return Some((format!("Packages.{rest}"), status));
    }
    let seg0 = path.split('.').next().unwrap_or("");
    match seg0 {
        "java" | "javax" | "android" | "cn" | "org" | "com" => {
            // java.<宿主函数>( → 164 能力面
            if let Some(name) = path.strip_prefix("java.") {
                if !name.contains('.') {
                    if CAPABILITY_NAMES.contains(&name) {
                        let status = if FILE_GATED_NAMES.contains(&name) {
                            "提供*（文件门控，生产未注册）"
                        } else {
                            "提供"
                        };
                        return Some((format!("java.{name}"), status));
                    }
                    if name == "type" {
                        return Some((String::from("Java.type"), "缺失（受控：记台账并友好报错）"));
                    }
                    return Some((format!("java.{name}"), "缺失"));
                }
            }
            // 镜像命名空间（java.security / java.lang 同时挂在裸 java 下；
            // javax/android/cn/org/com 仅存在于 Packages 树）
            let mut provided = false;
            for known in PACKAGES_KNOWN {
                if known.starts_with(seg0)
                    && (path == *known || path.starts_with(&format!("{known}.")))
                {
                    provided = true;
                    break;
                }
            }
            // 裸 java 镜像命名空间（仅 java.lang / java.security 两个）
            if !provided && BARE_JAVA_MIRROR_NS.contains(&seg0) {
                for ns in BARE_JAVA_MIRROR_NS {
                    if path == *ns || path.starts_with(&format!("{ns}.")) {
                        provided = true;
                        break;
                    }
                }
            }
            let status = if provided {
                "提供（命名空间镜像）"
            } else {
                "缺失（仅 Packages. 前缀可用）"
            };
            Some((path.to_string(), status))
        }
        "Java" => Some((path.to_string(), "缺失（受控：记台账并友好报错）")),
        "cookie" => {
            let name = path.trim_start_matches("cookie.");
            let status = if COOKIE_PROVIDED.contains(&name) {
                "提供"
            } else {
                "缺失"
            };
            Some((path.to_string(), status))
        }
        "cache" => {
            let name = path.trim_start_matches("cache.");
            let status = if CACHE_PROVIDED.contains(&name) {
                "提供"
            } else {
                "缺失"
            };
            Some((path.to_string(), status))
        }
        "JSoup" | "Jsoup" | "jsoup" | "JSOUP" => Some((
            path.to_string(),
            "缺失（无裸全局 jsoup 标识符，需 org.jsoup. 前缀）",
        )),
        _ => None,
    }
}

/// 静态能力对账：全语料符号差集 → 报告。
#[test]
fn test_static_capability_reconciliation() {
    let corpus = match load_corpus() {
        Some(c) => c,
        None => {
            eprintln!(
                "[cap-sweep][static] 语料缺失（{}），跳过静态对账",
                corpus_path().display()
            );
            return;
        }
    };
    let started = Instant::now();
    let total = corpus.len();

    // symbol -> (引用源数, 示例[(源名, url)], 状态)
    let mut symbols: BTreeMap<String, (usize, Vec<String>, Option<&'static str>)> = BTreeMap::new();
    let mut bare_used: BTreeMap<&'static str, (usize, Vec<String>)> = BTreeMap::new();
    let mut bare_watch: BTreeMap<&'static str, (usize, Vec<String>)> = BTreeMap::new();
    let mut fragment_hits: BTreeMap<&'static str, usize> = BTreeMap::new();
    let mut src_has_js: usize = 0;

    for (idx, src) in corpus.iter().enumerate() {
        let frags = collect_fragments(src);
        if frags.is_empty() {
            continue;
        }
        src_has_js += 1;
        let mut chains: BTreeSet<String> = BTreeSet::new();
        let mut calls: BTreeSet<String> = BTreeSet::new();
        for (label, text) in &frags {
            *fragment_hits.entry(label).or_insert(0) += 1;
            scan_dotted_chains(text, &mut chains);
            scan_bare_calls(text, &mut calls);
        }
        // 裸调用：164 能力面 + 观察名单
        for name in CAPABILITY_NAMES {
            if calls.contains(*name) {
                let entry = bare_used.entry(name).or_insert((0, Vec::new()));
                entry.0 += 1;
                if entry.1.len() < 3 {
                    entry.1.push(format!("#{} {}", idx, src.book_source_name));
                }
            }
        }
        for name in BARE_WATCHLIST {
            if calls.contains(*name) {
                let entry = bare_watch.entry(name).or_insert((0, Vec::new()));
                entry.0 += 1;
                if entry.1.len() < 3 {
                    entry.1.push(format!("#{} {}", idx, src.book_source_name));
                }
            }
        }
        // 点链：去重后按源聚合
        let mut seen_in_src: BTreeSet<String> = BTreeSet::new();
        for chain in &chains {
            if let Some((sym, status)) = classify_chain(chain) {
                if seen_in_src.insert(sym.clone()) {
                    let entry = symbols.entry(sym).or_insert((0, Vec::new(), None));
                    entry.0 += 1;
                    if entry.1.len() < 3 {
                        entry.1.push(format!(
                            "#{} {} / {}",
                            idx, src.book_source_name, src.book_source_url
                        ));
                    }
                    entry.2 = Some(status);
                }
            }
        }
    }

    // —— 静态缺失符号排行（仅「缺失」状态，按源数降序）——
    let mut missing: Vec<(&String, SymbolRow<'_>)> = Vec::new();
    struct SymbolRow<'a> {
        count: usize,
        examples: &'a [String],
        status: &'static str,
    }
    for (sym, (count, examples, status_opt)) in &symbols {
        let status = status_opt.unwrap_or("缺失");
        if status.starts_with("缺失") {
            missing.push((
                sym,
                SymbolRow {
                    count: *count,
                    examples: examples.as_slice(),
                    status,
                },
            ));
        }
    }
    missing.sort_by(|a, b| b.1.count.cmp(&a.1.count).then_with(|| a.0.cmp(b.0)));

    // —— 报告落盘 ——
    let dir = sweep_dir();
    let mut md = String::new();
    md.push_str(&format!(
        "# 静态能力对账报告\n\n- 语料：`{}`（{} 源）\n- 含 JS 片段源数：{}\n- 耗时：{:.2}s\n- 能力面快照：quickjs_impl.rs 164 个宿主函数（双挂载 java.*/裸全局）\n- 文件门控（生产未注册）：{}\n\n",
        corpus_path().display(),
        total,
        src_has_js,
        started.elapsed().as_secs_f64(),
        FILE_GATED_NAMES.len()
    ));
    md.push_str("## 片段命中\n\n| 片段 | 出现源数 |\n|---|---|\n");
    for (label, count) in &fragment_hits {
        md.push_str(&format!("| {label} | {count} |\n"));
    }

    md.push_str("\n## 缺失符号排行（静态，按引用源数）\n\n| 符号 | 源数 | 状态 | 可实现性评估 | 示例源 |\n|---|---|---|---|---|\n");
    for (sym, row) in &missing {
        let examples = row.examples.join("；");
        md.push_str(&format!(
            "| `{sym}` | {} | {} | {} | {} |\n",
            row.count,
            row.status,
            feasibility_hint(sym),
            if examples.is_empty() {
                "-".into()
            } else {
                examples
            }
        ));
    }

    md.push_str(
        "\n## 已提供但被引用的裸宿主函数（TOP 40）\n\n| 函数 | 源数 | 示例源 |\n|---|---|---|\n",
    );
    let mut provided_bare: Vec<(&str, &(usize, Vec<String>))> =
        bare_used.iter().map(|(k, v)| (*k, v)).collect();
    provided_bare.sort_by_key(|e| std::cmp::Reverse(e.1 .0));
    for (name, (count, examples)) in provided_bare.iter().take(40) {
        let marked = if FILE_GATED_NAMES.contains(name) {
            format!("{name}*")
        } else {
            name.to_string()
        };
        md.push_str(&format!(
            "| `{marked}` | {count} | {} |\n",
            examples.join("；")
        ));
    }

    md.push_str("\n## 观察名单命中（未注册符号）\n\n| 符号 | 源数 | 示例源 |\n|---|---|---|\n");
    let mut watch: Vec<(&str, &(usize, Vec<String>))> =
        bare_watch.iter().map(|(k, v)| (*k, v)).collect();
    watch.sort_by_key(|e| std::cmp::Reverse(e.1 .0));
    for (name, (count, examples)) in &watch {
        md.push_str(&format!(
            "| `{name}(` | {count} | {} |\n",
            examples.join("；")
        ));
    }
    md.push_str(
        "\n\\* 文件门控：`allow_file_access=false`（生产），该函数实际未注册，源引用即缺口。\n",
    );

    std::fs::write(dir.join("static_report.md"), &md).expect("static_report.md 写入失败");

    // JSON（手工序列化，避免 serde_json dev-dep）
    let mut js = String::from("{\"corpus\":\"");
    js.push_str(js_string_lit(&corpus_path().display().to_string()).trim_matches('"'));
    js.push_str(&format!("\",\"sources\":{total},\"missing\":["));
    let mut first = true;
    for (sym, row) in &missing {
        if !first {
            js.push(',');
        }
        first = false;
        js.push_str(&format!(
            "{{\"symbol\":{},\"sources\":{},\"status\":{},\"examples\":[",
            js_string_lit(sym),
            row.count,
            js_string_lit(row.status)
        ));
        for (i, ex) in row.examples.iter().enumerate() {
            if i > 0 {
                js.push(',');
            }
            js.push_str(&js_string_lit(ex));
        }
        js.push_str("]}");
    }
    js.push_str("]}");
    std::fs::write(dir.join("static_report.json"), js).expect("static_report.json 写入失败");

    // —— stdout 摘要 ——
    println!(
        "[cap-sweep][static] 语料 {} 源 / 含 JS {} 源 / 缺失符号 {} 个 / 耗时 {:.2}s",
        total,
        src_has_js,
        missing.len(),
        started.elapsed().as_secs_f64()
    );
    println!("[cap-sweep][static] TOP 缺失符号：");
    for (sym, row) in missing.iter().take(15) {
        println!("  {:4} 源  {}", row.count, sym);
    }
    println!(
        "[cap-sweep][static] 报告：{}static_report.md / .json",
        dir.display()
    );
    assert!(
        total == 0 || !fragment_hits.is_empty(),
        "语料非空但片段收集为零，collect_fragments 异常"
    );
}

// ---------------------------------------------------------------------------
// 离线干跑
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum DryRunClass {
    /// a) 缺失 Java 能力（台账/错误文案命中）
    MissingCapability,
    /// b) JS 语法/引用错误（非能力缺失）
    JsError,
    /// c) 触网/需登录——离线不可判
    NeedsNetwork,
    /// d) 引擎内部错误（panic / setup 失败）
    EngineInternal,
    /// 离线可跑通
    Ok,
}

impl DryRunClass {
    fn label(&self) -> &'static str {
        match self {
            DryRunClass::MissingCapability => "a-缺失Java能力",
            DryRunClass::JsError => "b-JS错误",
            DryRunClass::NeedsNetwork => "c-需网络/登录(离线不可判)",
            DryRunClass::EngineInternal => "d-引擎内部错误",
            DryRunClass::Ok => "ok-离线可跑",
        }
    }
}

#[derive(Debug, Clone)]
struct SourceDryRun {
    index: usize,
    name: String,
    url: String,
    class: DryRunClass,
    /// a 类：台账记录的缺失符号
    symbols: Vec<String>,
    /// b/d 类：首个错误摘要
    error: String,
    net_calls: usize,
    ms: u128,
    jslib_failed: bool,
}

/// 提取 searchUrl 中的 JS 块（与 legado-parser 同语义：`<js>…</js>` 或 `@js:` 至末尾）。
fn extract_js_blocks(search_url: &str) -> Vec<String> {
    let mut blocks = Vec::new();
    let mut rest = search_url;
    loop {
        // 找最近的 <js>（大小写不敏感）或 @js:
        let lower = rest.to_ascii_lowercase();
        let js_tag = lower.find("<js>").map(|p| (p, "tag"));
        let at_js = lower.find("@js:").map(|p| (p, "at"));
        let (pos, kind): (usize, &'static str) = match (js_tag, at_js) {
            (Some(a), Some(b)) if a.0 <= b.0 => a,
            (Some(_a), Some(b)) => b,
            (Some(a), None) => a,
            (None, Some(b)) => b,
            (None, None) => break,
        };
        match kind {
            "tag" => {
                let code_start = pos + 4;
                let code = &rest[code_start..];
                let lower_code = code.to_ascii_lowercase();
                let end = match lower_code.find("</js>") {
                    Some(e) => e,
                    None => break,
                };
                blocks.push(code[..end].to_string());
                rest = &rest[code_start + end + 5..];
            }
            "at" => {
                // @js: 后至本段末尾（生产正则是 `[\s\S]*` 贪心至串尾；
                // 多行 `@js:` 块以换行分隔，生产逐块替换语义下此处取至串尾即可）
                let code_start = pos + 4;
                blocks.push(rest[code_start..].to_string());
                break;
            }
            _ => unreachable!(),
        }
    }
    blocks
}

/// 解析 `source.variable`（`name=value` 行/分号分隔）→ 前导 var 注入（与生产 js_variable_prologue 同语义）。
fn variable_prologue(src: &BookSource) -> String {
    let mut out = String::new();
    for line in src.variable.split(['\n', '\r', ';']) {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        let name = name.trim();
        let valid = name
            .chars()
            .next()
            .is_some_and(|c| c == '_' || c == '$' || c.is_ascii_alphabetic())
            && name
                .chars()
                .all(|c| c == '_' || c == '$' || c.is_ascii_alphanumeric());
        if !valid {
            continue;
        }
        out.push_str(&format!("var {name} = {};\n", js_string_lit(value.trim())));
    }
    out
}

/// 单源干跑（在独立线程内执行：引擎创建 + setup + 补丁 + jsLib + searchUrl JS 块）。
fn run_source_dry(idx: usize, src: &BookSource) -> SourceDryRun {
    let base = SourceDryRun {
        index: idx,
        name: src.book_source_name.clone(),
        url: src.book_source_url.clone(),
        class: DryRunClass::Ok,
        symbols: Vec::new(),
        error: String::new(),
        net_calls: 0,
        ms: 0,
        jslib_failed: false,
    };
    let tag = if src.book_source_url.is_empty() {
        format!("idx{idx}")
    } else {
        src.book_source_url.clone()
    };
    let t0 = Instant::now();
    current_source::with_current_source_tag(&tag, || {
        capability_ledger::reset_unknown_java_symbols();

        let engine = QuickJsEngine::new(
            SandboxConfig::default()
                .with_allow_script_run(true)
                .with_memory_limit(64 * 1024 * 1024)
                .with_timeout(Duration::from_secs(5)),
        );
        let state: Result<SourceDryRun, String> = (|| {
            let engine = match engine {
                Ok(e) => e,
                Err(e) => return Err(format!("engine 创建失败：{e}")),
            };
            let setup =
                book_source_js_setup_script(src).map_err(|e| format!("setup 脚本生成失败：{e}"))?;
            engine
                .eval(&setup)
                .map_err(|e| format!("setup eval 失败：{e}"))?;
            engine
                .eval(NETWORK_PATCH_JS)
                .map_err(|e| format!("网络补丁 eval 失败：{e}"))?;
            engine
                .eval(EVAL_URI_FALLBACK_JS)
                .map_err(|e| format!("eval 包装 eval 失败：{e}"))?;

            let mut out = base.clone();
            let mut first_err: Option<String> = None;
            let mut result = String::new();

            // jsLib
            if let Some(js_lib) = &src.js_lib {
                if !js_lib.is_empty() {
                    if let Err(e) = engine.eval(js_lib) {
                        out.jslib_failed = true;
                        first_err = Some(format!("jsLib：{e}"));
                    }
                }
            }

            // searchUrl JS 块（每源最多 8 块，防病态超时累计）
            if let Some(search_url) = &src.search_url {
                let blocks = extract_js_blocks(search_url);
                let prologue = variable_prologue(src);
                for block in blocks.into_iter().take(8) {
                    let code = format!(
                        "{prologue}var key = \"测试\"; var page = 1; var result = {};\n{EVAL_URI_FALLBACK_JS}{block}",
                        js_string_lit(&result)
                    );
                    match engine.eval(&code) {
                        Ok(r) => result = r,
                        Err(e) => {
                            if first_err.is_none() {
                                first_err = Some(format!("searchUrl JS：{e}"));
                            }
                        }
                    }
                }
            }

            // 网络调用记录 + 台账快照
            if let Ok(len) = engine.eval("(globalThis.__netCalls || []).length") {
                out.net_calls = len.trim().parse().unwrap_or(0);
            }
            for (sym, _count) in capability_ledger::unknown_java_symbols() {
                if !out.symbols.contains(&sym) {
                    out.symbols.push(sym);
                }
            }
            out.error = first_err.unwrap_or_default();

            // 分类（优先级 d > a > c > b > ok）
            let cap_hit = !out.symbols.is_empty() || out.error.contains("此书源需要 Java 脚本能力");
            if cap_hit {
                out.class = DryRunClass::MissingCapability;
            } else if out.net_calls > 0 {
                out.class = DryRunClass::NeedsNetwork;
            } else if out.error.contains("登录") || out.error.contains("login") {
                // 登录型源：报错文案明确要求登录（如微信读书「缺少 APP 登录参数」）
                // → 离线不可判，并入 c 类（分诊桶一致）
                out.class = DryRunClass::NeedsNetwork;
            } else if !out.error.is_empty() {
                out.class = DryRunClass::JsError;
            } else {
                out.class = DryRunClass::Ok;
            }
            Ok(out)
        })();

        match state {
            Ok(mut out) => {
                out.ms = t0.elapsed().as_millis();
                out
            }
            Err(e) => {
                let mut out = base.clone();
                out.class = DryRunClass::EngineInternal;
                out.error = e;
                out.ms = t0.elapsed().as_millis();
                out
            }
        }
    })
}

/// 在独立线程中创建并运行单源干跑（引擎线程内创建/析构，panic 由 join 捕获）。
fn spawn_source_worker(
    idx: usize,
    src: &BookSource,
) -> Result<thread::JoinHandle<SourceDryRun>, String> {
    let src_ref = src.clone();
    thread::Builder::new()
        .name(format!("cap-sweep-{idx}"))
        .spawn(move || run_source_dry(idx, &src_ref))
        .map_err(|e| format!("线程创建失败：{e}"))
}

/// 4 路并发池中单个在途任务：(源序号, 源名, 源 URL, 工作线程句柄)。
type InFlightTask = (
    usize,
    String,
    String,
    Result<thread::JoinHandle<SourceDryRun>, String>,
);

/// 全量离线干跑：每源独立线程（4 路并发池，panic 隔离 → d 类），聚合分类与缺失能力排行。
#[test]
#[ignore]
fn test_offline_dry_run_sweep() {
    let corpus = match load_corpus() {
        Some(c) => c,
        None => {
            eprintln!(
                "[cap-sweep][dry] 语料缺失（{}），跳过干跑",
                corpus_path().display()
            );
            return;
        }
    };
    let total = corpus.len();
    let started = Instant::now();
    println!("[cap-sweep][dry] 开始全量干跑：{total} 源（离线，网络函数已打桩）");

    let mut results: Vec<SourceDryRun> = Vec::with_capacity(total);
    let mut symbol_sources: BTreeMap<String, (usize, Vec<String>)> = BTreeMap::new();
    let mut error_signatures: BTreeMap<String, (usize, Vec<String>)> = BTreeMap::new();
    let mut internal_errors: Vec<String> = Vec::new();
    let mut net_examples: Vec<String> = Vec::new();

    // 4 路并发池：每源仍独立线程（引擎线程内创建/析构，panic 被 join 捕获 → d 类），
    // 池化仅为压缩墙钟时间（最坏 916 源 × 45s 串行 ≈ 2.3h → 并发后约 35min 封顶）
    const WORKERS: usize = 4;
    let mut i = 0;
    while i < total {
        let end = (i + WORKERS).min(total);
        let mut in_flight: Vec<InFlightTask> = Vec::with_capacity(end - i);
        for (idx, src) in corpus.iter().enumerate().take(end).skip(i) {
            in_flight.push((
                idx,
                src.book_source_name.clone(),
                src.book_source_url.clone(),
                spawn_source_worker(idx, src),
            ));
        }
        for (idx, name, url, h) in in_flight {
            let r = match h {
                Ok(handle) => match handle.join() {
                    Ok(r) => r,
                    Err(panic_payload) => {
                        // 线程 panic → d 类（引擎内部错误，最高优先）
                        let msg = if let Some(s) = panic_payload.downcast_ref::<String>() {
                            s.clone()
                        } else {
                            panic_payload
                                .downcast_ref::<&str>()
                                .map_or("未知 panic".to_string(), |s| s.to_string())
                        };
                        internal_errors.push(format!("#{} {}：{msg}", idx, name));
                        SourceDryRun {
                            index: idx,
                            name: name.clone(),
                            url: url.clone(),
                            class: DryRunClass::EngineInternal,
                            symbols: Vec::new(),
                            error: format!("线程 panic：{msg}"),
                            net_calls: 0,
                            ms: 0,
                            jslib_failed: false,
                        }
                    }
                },
                Err(e) => {
                    internal_errors.push(format!("#{} {}：线程创建失败 {e}", idx, name));
                    SourceDryRun {
                        index: idx,
                        name: name.clone(),
                        url: url.clone(),
                        class: DryRunClass::EngineInternal,
                        symbols: Vec::new(),
                        error: format!("线程创建失败：{e}"),
                        net_calls: 0,
                        ms: 0,
                        jslib_failed: false,
                    }
                }
            };

            // 聚合
            match &r.class {
                DryRunClass::MissingCapability => {
                    for sym in &r.symbols {
                        let entry = symbol_sources.entry(sym.clone()).or_insert((0, Vec::new()));
                        entry.0 += 1;
                        if entry.1.len() < 3 {
                            entry.1.push(format!("#{} {}", r.index, r.name));
                        }
                    }
                    if r.symbols.is_empty() {
                        // 错误文案命中但台账为空（符号可能被 256 容量截断或文案直抛）
                        let sym = format!(
                            "<未解析符号> {}",
                            r.error.chars().take(80).collect::<String>()
                        );
                        let entry = symbol_sources.entry(sym).or_insert((0, Vec::new()));
                        entry.0 += 1;
                        if entry.1.len() < 3 {
                            entry.1.push(format!("#{} {}", r.index, r.name));
                        }
                    }
                }
                DryRunClass::JsError => {
                    let sig: String = r.error.chars().take(160).collect();
                    let entry = error_signatures.entry(sig).or_insert((0, Vec::new()));
                    entry.0 += 1;
                    if entry.1.len() < 3 {
                        entry.1.push(format!("#{} {}", r.index, r.name));
                    }
                }
                DryRunClass::NeedsNetwork if net_examples.len() < 20 => {
                    net_examples.push(format!(
                        "#{} {}（{} 次网络调用）",
                        r.index, r.name, r.net_calls
                    ));
                }
                _ => {}
            }
            results.push(r);

            if idx % 100 == 99 {
                println!(
                    "[cap-sweep][dry] 进度 {}/{}（已耗时 {:.1}s）",
                    idx + 1,
                    total,
                    started.elapsed().as_secs_f64()
                );
            }
        }
        i = end;
    }

    let elapsed = started.elapsed().as_secs_f64();

    // —— 分类统计 ——
    let mut class_counts: HashMap<&'static str, usize> = HashMap::new();
    for r in &results {
        *class_counts.entry(r.class.label()).or_insert(0) += 1;
    }

    // —— 缺失能力排行 ——
    let mut ranking: Vec<(&String, &(usize, Vec<String>))> = symbol_sources.iter().collect();
    ranking.sort_by(|a, b| b.1 .0.cmp(&a.1 .0).then_with(|| a.0.cmp(b.0)));

    let mut err_ranking: Vec<(&String, &(usize, Vec<String>))> = error_signatures.iter().collect();
    err_ranking.sort_by_key(|e| std::cmp::Reverse(e.1 .0));

    // —— 报告落盘 ——
    let dir = sweep_dir();
    let mut md = String::new();
    md.push_str(&format!(
        "# 离线干跑报告（全语料 {total} 源，耗时 {elapsed:.1}s）\n\n- 引擎：生产同源 QuickJsEngine（allow_script_run=true，64MB，5s/eval）\n- 网络：全部宿主网络/浏览器/睡眠函数替换为记录器（零真实联网）\n- 隔离：每源独立线程，panic → d 类\n\n## 分类统计\n\n| 类别 | 源数 |\n|---|---|\n",
    ));
    let mut sorted_classes: Vec<(&str, &usize)> =
        class_counts.iter().map(|(k, v)| (*k, v)).collect();
    sorted_classes.sort_by(|a, b| b.1.cmp(a.1));
    for (label, count) in &sorted_classes {
        md.push_str(&format!("| {label} | {count} |\n"));
    }

    md.push_str("\n## 缺失 Java 能力排行（a 类，按源数）\n\n| # | 符号 | 源数 | 可实现性 | 示例源 |\n|---|---|---|---|---|\n");
    for (i, (sym, (count, examples))) in ranking.iter().take(30).enumerate() {
        md.push_str(&format!(
            "| {} | `{sym}` | {count} | {} | {} |\n",
            i + 1,
            feasibility_hint(sym),
            examples.join("；")
        ));
    }

    md.push_str(
        "\n## JS 错误签名 TOP 20（b 类）\n\n| # | 错误签名 | 源数 | 示例源 |\n|---|---|---|---|\n",
    );
    for (i, (sig, (count, examples))) in err_ranking.iter().take(20).enumerate() {
        let escaped = sig.replace('|', "\\|");
        md.push_str(&format!(
            "| {} | `{escaped}` | {count} | {} |\n",
            i + 1,
            examples.join("；")
        ));
    }

    if !internal_errors.is_empty() {
        md.push_str("\n## 引擎内部错误（d 类，最高优先）\n\n");
        for e in &internal_errors {
            md.push_str(&format!("- {e}\n"));
        }
    }
    if !net_examples.is_empty() {
        md.push_str("\n## 触网示例（c 类，离线不可判）\n\n");
        for e in &net_examples {
            md.push_str(&format!("- {e}\n"));
        }
    }
    std::fs::write(dir.join("dry_run_report.md"), &md).expect("dry_run_report.md 写入失败");

    // JSON 明细（逐源分类 + 排行）
    let mut js = String::from("{\"total\":");
    js.push_str(&total.to_string());
    js.push_str(&format!(",\"elapsed_s\":{elapsed},\"class_counts\":{{"));
    let mut first = true;
    for (label, count) in &sorted_classes {
        if !first {
            js.push(',');
        }
        first = false;
        js.push_str(&format!("{}:{}", js_string_lit(label), count));
    }
    js.push_str("},\"missing_ranking\":[");
    for (i, (sym, (count, examples))) in ranking.iter().take(50).enumerate() {
        if i > 0 {
            js.push(',');
        }
        js.push_str(&format!(
            "{{\"symbol\":{},\"sources\":{},\"examples\":[",
            js_string_lit(sym),
            count
        ));
        for (j, ex) in examples.iter().enumerate() {
            if j > 0 {
                js.push(',');
            }
            js.push_str(&js_string_lit(ex));
        }
        js.push_str("]}");
    }
    js.push_str("],\"per_source\":[");
    for (i, r) in results.iter().enumerate() {
        if i > 0 {
            js.push(',');
        }
        js.push_str(&format!(
            "{{\"index\":{},\"name\":{},\"url\":{},\"class\":{},\"net_calls\":{},\"ms\":{},\"jslib_failed\":{},\"symbols\":[",
            r.index,
            js_string_lit(&r.name),
            js_string_lit(&r.url),
            js_string_lit(r.class.label()),
            r.net_calls,
            r.ms,
            r.jslib_failed
        ));
        for (j, sym) in r.symbols.iter().enumerate() {
            if j > 0 {
                js.push(',');
            }
            js.push_str(&js_string_lit(sym));
        }
        js.push_str(&format!("],\"error\":{}}}", js_string_lit(&r.error)));
    }
    js.push_str("]}");
    std::fs::write(dir.join("dry_run_details.json"), js).expect("dry_run_details.json 写入失败");

    // —— stdout 摘要 ——
    println!("[cap-sweep][dry] 完成：{total} 源 / 耗时 {elapsed:.1}s");
    for (label, count) in &sorted_classes {
        println!("  {label}: {count}");
    }
    println!("[cap-sweep][dry] 缺失能力 TOP 10：");
    for (sym, (count, _examples)) in ranking.iter().take(10) {
        println!("  {:4} 源  {sym}", count);
    }
    println!(
        "[cap-sweep][dry] 报告：{}dry_run_report.md / dry_run_details.json",
        dir.display()
    );
}
