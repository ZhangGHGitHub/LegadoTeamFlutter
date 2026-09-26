//! QuickJS 宿主 API 注册实现
//!
//! 在 `quickjs` feature 启用时，将 Legado 提供的宿主函数
//! 注册到 rquickjs 的全局上下文中，供 JS 脚本直接调用。
//!
//! 当前实现：
//! - 编解码 API：md5Encode, md5Encode16, base64Encode, base64Decode,
//!   base64DecodeToByteArray, hexEncode, hexDecode, sha256, encodeURI,
//!   hmacMd5, hmacSha256
//! - 字符串工具：urlencode, urldecode, trimStart, trimEnd,
//!   substringBefore, substringAfter, replaceFirst, replaceAll
//! - JSON 工具：jsonPath, jsonGetString, toJson
//! - 正则工具：regExp, regExpReplace, regExpFindAll
//! - 时间工具：formatTime, timeFormat, currentTimeMillis, parseTime, timeFormatUTC
//! - 文件工具：readFile, writeFile, fileExists, deleteFile, getTxtInFolder
//! - 变量存储：getVariable, setVariable, removeVariable, clearVariables
//! - 网络 API：httpGet, httpPost, httpHead, ajax, ajaxAll, connect, head, post
//! - 平台桥接：webView, webViewGetSource, webViewGetOverrideUrl, startBrowser,
//!   showBrowser, openUrl, getVerificationCode
//! - 压缩解压：unzipFile, getZipStringContent, un7zFile, unrarFile, get7zStringContent, getRarStringContent
//! - 字体 API：queryTTF, queryBase64TTF, replaceFont
//! - 工具类：randomUUID, log, toast, longToast, toURL, upLoginData, threadSleep, inflateRawBytes
//! - HTML 解析：getElement(s), getString, getStrings, getStringList, jsoup*, setContent
//! - 全局缓存：cache.put/get/putMemory/getFromMemory/deleteMemory/putFile/getFile/delete

#![cfg(feature = "quickjs")]

use legado_core::LegadoError;

use crate::host_api::{
    archive_utils, asymmetric_crypto, cache_store, capability_ledger, chinese_utils,
    concurrency_api, config_api, cookie_store, crypto_api, encoding, file_utils, font_api,
    html_format, html_parse, json_utils, message_digest, misc_api, network, platform, regex_utils,
    register::mount_dual, string_utils, symmetric_crypto, time_utils, variable_store,
};
use crate::sandbox::SandboxConfig;
use rquickjs::function::Opt;

/// 可空字符串入参（rquickjs `Opt<T>` 只认 undefined、不认显式 null——
/// 上游 Kotlin `String?` 可空参语义下语料合法调用 `java.webView(null, url,
/// null)` 会报「Error converting from js 'null' into type 'string'」）。
/// null / undefined 均映射 None，其余按 String 转换。— 2026-09-26
struct NullStr(Option<String>);

impl<'js> rquickjs::FromJs<'js> for NullStr {
    fn from_js(_ctx: &rquickjs::Ctx<'js>, value: rquickjs::Value<'js>) -> rquickjs::Result<Self> {
        if value.is_undefined() || value.is_null() {
            return Ok(NullStr(None));
        }
        Ok(NullStr(Some(String::from_js(_ctx, value)?)))
    }
}

/// 可空布尔入参（语义同 [`NullStr`]）
struct NullBool(Option<bool>);

impl<'js> rquickjs::FromJs<'js> for NullBool {
    fn from_js(_ctx: &rquickjs::Ctx<'js>, value: rquickjs::Value<'js>) -> rquickjs::Result<Self> {
        if value.is_undefined() || value.is_null() {
            return Ok(NullBool(None));
        }
        Ok(NullBool(Some(bool::from_js(_ctx, value)?)))
    }
}

/// 将所有宿主 API 注册到 QuickJS 全局上下文
///
/// 每个函数同时挂载到 `java` 命名空间对象和裸全局，
/// 确保 `java.md5Encode("hello")` 和 `md5Encode("hello")` 都能工作。
///
/// 根据 `SandboxConfig.allow_file_access` 决定是否注册文件 API；
/// network 与 cookie API 始终注册（经 legado-net 受控通道，保持书源对等）。
pub fn register_all_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    config: &SandboxConfig,
) -> Result<(), LegadoError> {
    let globals = ctx.globals();

    // 创建 java 命名空间对象
    let java =
        rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    register_encoding_apis(ctx, &java, &globals)?;
    register_string_apis(ctx, &java, &globals)?;
    register_json_apis(ctx, &java, &globals)?;
    register_regex_apis(ctx, &java, &globals)?;
    register_time_apis(ctx, &java, &globals)?;
    // 文件 API 仅在 allow_file_access = true 时注册（安全门控）
    if config.allow_file_access {
        register_file_apis(ctx, &java, &globals)?;
    }
    register_variable_apis(ctx, &java, &globals)?;
    // P2-11 ①：book 绑定写路径桥（java-only；FFI web_book IIFE 经
    // `java.__lgBook*` 探测后落 variable_store 裸键持久层）
    register_book_binding_bridges(ctx, &java)?;
    register_utility_apis(ctx, &java, &globals)?;
    register_network_apis(ctx, &java, &globals)?;
    register_cookie_apis(ctx, &java, &globals)?;
    register_crypto_apis(ctx, &java, &globals)?;
    // java.security.MessageDigest（纯 Rust md-5/sha1/sha2）：Packages 模拟层
    // 的 security.MessageDigest.getInstance 依赖 messageDigestValidate/Digest
    // 宿主绑定，须先于 inject_packages_shim 注册（mount_dual 写入 java 对象，
    // 在 set("java", java) 移动 java 之前完成）
    register_message_digest_apis(ctx, &java, &globals)?;
    register_html_apis(ctx, &java, &globals)?;
    register_html_parse_apis(ctx, &java, &globals)?;
    register_chinese_apis(ctx, &java, &globals)?;
    register_config_apis(ctx, &java, &globals)?;
    register_concurrency_apis(ctx, &java, &globals)?;
    register_misc_apis(ctx, &java, &globals)?;
    register_archive_apis(ctx, &java, &globals)?;
    register_font_apis(ctx, &java, &globals)?;
    // 全局 cache 对象（P2-9 ① 记忆缓存三件套 + 磁盘缓存，对齐 WebCacheManager）
    register_cache_apis(ctx, &java, &globals)?;

    // 队列④ 能力受限台账：Packages 模拟层遇到未覆盖的 Java 类/成员时登记符号
    // （capability_ledger），供"下一批补什么"诊断查询。必须先于
    // inject_packages_shim 注册——shim 的 Proxy 陷阱与 Java.type/importClass
    // 哨兵经 `java.reportUnknownSymbol` 回调查用。
    // （须在 set("java", java) 移动 java 之前挂载）
    // P3 硬化：仅挂 java 命名空间、不再挂裸全局——此前 mount_dual 把
    // reportUnknownSymbol 同时写进 globalThis，污染全局作用域，可能与书源
    // jsLib / 用户脚本中的同名标识符碰撞。shim 内所有调用点均为
    // `java.reportUnknownSymbol`（trap / Java.type / importClass），java 专用即可。
    let report_unknown_symbol = rquickjs::Function::new(ctx.clone(), |sym: String| -> () {
        capability_ledger::record_unknown_java_symbol(&sym);
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("reportUnknownSymbol", report_unknown_symbol)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // 将 java 命名空间对象注册到全局
    globals
        .set("java", java)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // Rhino `Packages` Java 桥模拟层（QuickJS 无 Java 桥）：常用子集
    // 映射到 java.* 宿主绑定——七猫四合一等书源 jsLib 用 Packages 做
    // AES 密文解密 / Base64 / MD5 / UUID / String.getBytes，
    // 缺失时报 `Packages is not defined`（2026-08-15 用户反馈七猫报错）
    inject_packages_shim(ctx)?;
    // Rhino org.jsoup.Jsoup 包导入模拟（云霄/键盘等 searchUrl @js 依赖）
    inject_jsoup_shim(ctx)?;
    // java.get/post/head → connectNR（followRedirects=false）+ Response 对象
    // 必须在引擎创建时注入：否则书源 `java.post(...).header('location')` 会打到
    // 原生 post（跟随重定向 / headers 对象无法转 String）→ Location 丢失落 /null
    inject_response_bridge(ctx)?;

    Ok(())
}

/// 注入 `org.jsoup.Jsoup` 全局（及 Packages.org.jsoup）
#[cfg(feature = "quickjs")]
fn inject_jsoup_shim<'js>(ctx: &rquickjs::Ctx<'js>) -> Result<(), LegadoError> {
    let _: rquickjs::Value = ctx
        .eval(JSOUP_BRIDGE_JS)
        .map_err(|e| LegadoError::JsEngine(format!("Jsoup 模拟层注入失败: {e}")))?;
    Ok(())
}

/// 注入 java.get/post/head Response 语义桥
#[cfg(feature = "quickjs")]
fn inject_response_bridge<'js>(ctx: &rquickjs::Ctx<'js>) -> Result<(), LegadoError> {
    let _: rquickjs::Value = ctx
        .eval(RESPONSE_BRIDGE_JS)
        .map_err(|e| LegadoError::JsEngine(format!("Response 桥注入失败: {e}")))?;
    Ok(())
}

/// 注入 Rhino `Packages` Java 桥模拟层（QuickJS 全局）
///
/// 覆盖七猫四合一等书源 jsLib 用到的 Java 类常用子集：
/// - `java.lang.String` — toString/getBytes(charset)/new String(bytes, charset)
/// - `java.util.UUID.randomUUID` / `java.util.Arrays.copyOfRange`
/// - `android.util.Base64` — decode(→Uint8Array)/encodeToString
/// - `cn.hutool.crypto.digest.DigestUtil.md5Hex`
/// - `javax.crypto.spec.SecretKeySpec|IvParameterSpec` + `javax.crypto.Cipher`
///   （init/doFinal → `java.aesDecryptBytes` 字节级 AES-CBC/ECB 解密）
///
/// P2-9 ① 扩面（按语料实际用法）：
/// - `java.lang.{Integer/Long/Double/Boolean}.parse*/toString`、`String.valueOf`、
///   `Thread.sleep`（→ `java.threadSleep`）、`System.currentTimeMillis`
///   （→ `java.currentTimeMillis`）
/// - `java.util.{Arrays.copyOf, HashMap}`（HashMap 带 toJSON 供请求头 JSON 序列化）
/// - `java.util.zip.{Inflater, InflaterInputStream}` + `java.io.{ByteArray
///   InputStream, ByteArrayOutputStream}` + `java.nio.ByteBuffer.allocate(n).array()`
///   ——`wrInflateRaw` 流委托宿主 `java.inflateRawBytes`（flate2 raw-deflate）
#[cfg(feature = "quickjs")]
fn inject_packages_shim<'js>(ctx: &rquickjs::Ctx<'js>) -> Result<(), LegadoError> {
    let shim = r#"
(function () {
  function toU8(x) { return (x instanceof Uint8Array) ? x : new Uint8Array(x); }
  function toJsonBytes(u8) { var a = []; for (var i = 0; i < u8.length; i++) a.push(u8[i]); return JSON.stringify(a); }
  function fromJsonBytes(json) { return new Uint8Array(JSON.parse(json)); }
  function JSString(s) {
    return {
      toString: function () { return s; },
      valueOf: function () { return s; },
      getBytes: function (charset) { return fromJsonBytes(java.strToBytes(s, charset || 'UTF-8')); }
    };
  }
  function JavaString() {
    var a0 = arguments.length > 0 ? arguments[0] : undefined;
    var isBytes = (a0 instanceof Uint8Array) || Array.isArray(a0);
    // 注意：调用方以 `new Packages.java.lang.String(...)` 使用本构造器，
    // JS `new` 语义下若显式 return 原始值（字符串），表达式结果为 this
    // 空对象 → String(this) = "[object Object]"（2026-08-15 七猫正文
    // [object Object] 根因）。bytes 分支必须返回 JSString **对象**，
    // 让 new 保留对象，toString/valueOf 再取回明文字符串。
    // Java String(byte[], offset, length, charset) 重载（qmDecodeTextBytes
    // 用 `new String(bytes, 0, headSize, 'ISO-8859-1')` 做编码探测头）：
    // 取子数组按 charset 解码，而非把 offset 当 charset 名。
    if (arguments.length >= 4 && isBytes) {
      var off4 = Number(arguments[1]) || 0;
      var len4 = Number(arguments[2]) || 0;
      var sub4 = toU8(a0).slice(off4, off4 + len4);
      var r4 = java.bytesToStr(toJsonBytes(sub4), String(arguments[3]));
      return JSString(String(r4));
    }
    if (arguments.length === 3 && isBytes) {
      var off3 = Number(arguments[1]) || 0;
      var len3 = Number(arguments[2]) || 0;
      var sub3 = toU8(a0).slice(off3, off3 + len3);
      return JSString(String(java.bytesToStr(toJsonBytes(sub3), 'UTF-8')));
    }
    if (arguments.length >= 2 && isBytes) {
      var r = java.bytesToStr(toJsonBytes(toU8(a0)), String(arguments[1]));
      return JSString(String(r));
    }
    if (arguments.length === 1 && isBytes) { return JSString(String(java.bytesToStr(toJsonBytes(toU8(a0)), 'UTF-8'))); }
    return JSString(String(arguments[0]));
  }
  // String.valueOf 静态方法（P2-9 ① java.lang 最小静态面）：
  // 挂在 JavaString 构造器函数上，`new Packages.java.lang.String(...)` 语义不变
  JavaString.valueOf = function (x) {
    if (x === null) return 'null';
    if (x === undefined) return 'undefined';
    return String(x);
  };
  function uuidV4() {
    var d = new Uint8Array(16);
    for (var i = 0; i < 16; i++) d[i] = Math.floor(Math.random() * 256);
    d[6] = (d[6] & 0x0f) | 0x40; d[8] = (d[8] & 0x3f) | 0x80;
    var h = '';
    for (var i = 0; i < 16; i++) h += (d[i] < 16 ? '0' : '') + d[i].toString(16);
    return h.substr(0, 8) + '-' + h.substr(8, 4) + '-' + h.substr(12, 4) + '-' + h.substr(16, 4) + '-' + h.substr(20);
  }
  // P2-9 ① java.util 最小面（按语料实际用法）：
  // HashMap（7 源：upLoginData/请求头/评论偏好存储）——键经 JS 对象字符串化
  // （Java 键非 String 时行为为降级项）；toJSON 保证
  // JSON.stringify(map)（Response 桥请求头序列化路径）输出数据对象。
  function JSHashMap() {
    var m = {};
    return {
      put: function (k, v) { var old = (k in m) ? m[k] : null; m[k] = v; return old; },
      get: function (k) { return (k in m) ? m[k] : null; },
      containsKey: function (k) { return k in m; },
      containsValue: function (v) { for (var k in m) if (m[k] === v) return true; return false; },
      remove: function (k) { if (!(k in m)) return null; var old = m[k]; delete m[k]; return old; },
      size: function () { var n = 0; for (var k in m) n++; return n; },
      isEmpty: function () { return this.size() === 0; },
      clear: function () { for (var k in m) delete m[k]; },
      keySet: function () { return Object.keys(m); },
      values: function () { var a = []; for (var k in m) a.push(m[k]); return a; },
      entrySet: function () {
        var a = [];
        for (var k in m) a.push({ getKey: function () { return k; }, getValue: function () { return m[k]; } });
        return a;
      },
      toJSON: function () { return m; },
      toString: function () { var p = []; for (var k in m) p.push(k + '=' + m[k]); return '{' + p.join(', ') + '}'; }
    };
  }
  // P2-9 ① java.io / java.nio / java.util.zip 最小面（语料 wrInflateRaw 流程，2 源）
  function JSByteArrayInputStream(bytes) {
    var b = toU8(bytes || []);
    return {
      _bytes: b,
      available: function () { return b.length; },
      close: function () {}
    };
  }
  function JSByteArrayOutputStream() {
    var chunks = [];
    var len = 0;
    return {
      write: function (b, off, count) {
        if (arguments.length === 1 && (b instanceof Uint8Array || Array.isArray(b))) {
          var a = toU8(b);
          chunks.push(a); len += a.length;
          return;
        }
        var c = (arguments.length === 1) ? 1 : Math.max(0, Number(count) || 0);
        var o = Number(off) || 0;
        var src = (b instanceof Uint8Array || Array.isArray(b)) ? toU8(b) : null;
        var a2 = new Uint8Array(c);
        for (var i = 0; i < c; i++) a2[i] = (src && o + i < src.length) ? (src[o + i] & 255) : (Number(b) & 255);
        chunks.push(a2); len += c;
      },
      toByteArray: function () {
        var out = new Uint8Array(len);
        var p = 0;
        for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], p); p += chunks[i].length; }
        return out;
      },
      size: function () { return len; },
      close: function () {},
      toString: function () { return String(java.bytesToStr(toJsonBytes(this.toByteArray()), 'UTF-8')); }
    };
  }
  // P2-9 ① java.io.InputStream 最小面（语料 favcomic decode 路径，索引 703）：
  // 对内存字节缓冲的纯读流抽象，无真实 JVM 对象/文件 IO/反射——与
  // JSByteArrayInputStream/JSInflaterInputStream 同物种（宿主 java.inflateRawBytes
  // 覆盖解压，本类只搬运字节）。方法挂 **prototype**（非实例字面量），使
  // `x instanceof Packages.java.io.InputStream` 与 `.prototype` 直接访问均成立
  //（favcomic 混淆体对 InputStream.prototype 做 Java 式类型探测）；new 与普通调用
  // 双支持（无 new 时 Object.create(prototype) 显式构造，保住 instanceof 链）。
  // Java 语义（审查修）：构造器**拷贝**输入字节序列（不别名调用方 buffer，
  // 外部改动不污染流内容）；string / java.lang.String 输入经宿主 java.strToBytes
  // 转字节（不可行时抛可读错误，绝不静默产生空流）；read 的 buffer 参数必须是
  // 字节序列（ArrayBuffer.isView 覆盖 Int8Array 等全部 TypedArray + plain Array，
  // 一律就地写入——plain Array 不得拷贝，否则 nio ByteBuffer.array() 读缓冲
  // 收不到数据），非字节序列抛 TypeError；off/len 越界或负数按 Java
  // IndexOutOfBoundsException 抛可读错误（不静默截断）；len==0 读 0 字节返回 0
  //（即使 EOF）；mark/reset 按 Java 语义经 _mark 标记（reset 回到 mark 位置，
  // 未 mark 时 mark==0 即回到起点，与 ByteArrayInputStream 一致）。
  // 实例哨兵（审查修）：构造器返回 get 陷阱 Proxy（无 getPrototypeOf 陷阱 →
  // instanceof 不受影响；in 判定经目标原型链直通）。已知成员（read/close/
  // _bytes 等，含原型链继承）直通；未知字符串成员回落 makeUnknownClassSentinel
  // ('java.io.InputStream.' + prop)——与类级未知成员同一文案 + 台账登记路径
  //（读取安全并登记 `java.io.InputStream.<成员>`，调用/new 抛「此书源需要
  // Java 脚本能力（Packages.java.io.InputStream.<成员>），当前不支持」），
  // 未覆盖成员（readAllBytes/transferTo/markSupported 等）不再静默 undefined。
  // _bytes 保留实例暴露（JSInflaterInputStream 的 inStream._bytes 提取依赖，
  // 经陷阱 `in` 直通）。
  function toInputStreamBytes(bytes) {
    if (bytes === null || bytes === undefined) { return new Uint8Array(0); }
    if (bytes instanceof Uint8Array) { return new Uint8Array(bytes); } // 拷贝不别名
    if (ArrayBuffer.isView(bytes) || Array.isArray(bytes)) {
      return toU8(bytes); // TypedArray/Array 构造即拷贝
    }
    var str = null;
    if (typeof bytes === 'string') { str = bytes; }
    else if (typeof bytes === 'object' && typeof bytes.getBytes === 'function') {
      str = String(bytes); // java.lang.String（JSString 对象，toString 取回内容）
    }
    if (str !== null) {
      if (typeof globalThis.java !== 'undefined' && globalThis.java &&
          typeof globalThis.java.strToBytes === 'function') {
        var json = String(globalThis.java.strToBytes(str, 'UTF-8'));
        if (json.indexOf('[ERROR]') === 0) {
          throw new Error('java.io.InputStream: 字符串输入转字节失败（java.strToBytes: ' + json + '）');
        }
        return fromJsonBytes(json);
      }
      throw new Error('java.io.InputStream: 字符串输入需宿主 java.strToBytes 转换，当前不可用');
    }
    throw new TypeError('java.io.InputStream 构造参数须为字节序列（TypedArray/Array）、字符串或 java.lang.String，实际为 ' + typeof bytes);
  }
  function JSInputStream(bytes) {
    var self = (this instanceof JSInputStream) ? this : Object.create(JSInputStream.prototype);
    self._bytes = toInputStreamBytes(bytes);
    self._pos = 0;
    self._mark = 0;
    return new Proxy(self, {
      get: function (t, prop) {
        if (typeof prop !== 'string' || (prop in t)) { return Reflect.get(t, prop); }
        return makeUnknownClassSentinel('java.io.InputStream.' + prop);
      }
    });
  }
  JSInputStream.prototype.read = function (buffer, off, count) {
    var rem = this._bytes.length - this._pos;
    if (buffer === undefined || buffer === null) {
      if (rem <= 0) { return -1; }
      var v = this._bytes[this._pos];
      this._pos += 1;
      return v;
    }
    // 就地写入调用方 buffer（全部 TypedArray + plain Array，见类注释）
    var isSeq = ArrayBuffer.isView(buffer) || Array.isArray(buffer);
    if (!isSeq) {
      throw new TypeError('java.io.InputStream.read: 缓冲参数须为字节序列（TypedArray/Array），实际为 ' + (buffer === null ? 'null' : typeof buffer));
    }
    var o = (arguments.length >= 2) ? (Number(off) || 0) : 0;
    var c = (arguments.length >= 3) ? (Number(count) || 0) : buffer.length;
    if (c === 0) { return 0; } // Java：len==0 读 0 字节（即使 EOF）
    if (o < 0 || c < 0 || o + c > buffer.length) {
      throw new RangeError('java.io.InputStream.read: 越界（off=' + o + ', len=' + c + '，缓冲长度 ' + buffer.length + '）');
    }
    var n = Math.min(c, rem);
    if (n === 0) { return -1; } // EOF（c>0）
    for (var i = 0; i < n; i++) { buffer[o + i] = this._bytes[this._pos + i]; }
    this._pos += n;
    return n;
  };
  JSInputStream.prototype.available = function () { return this._bytes.length - this._pos; };
  JSInputStream.prototype.skip = function (n) {
    var k = Math.min(Math.max(0, Number(n) || 0), this._bytes.length - this._pos);
    this._pos += k;
    return k;
  };
  JSInputStream.prototype.mark = function () { this._mark = this._pos; };
  JSInputStream.prototype.reset = function () { this._pos = this._mark; };
  JSInputStream.prototype.close = function () {};
  // Inflater(true)：true 即 no-wrap（raw deflate）。本 shim 忽略该标志——
  // 宿主 java.inflateRawBytes 先按 raw 解压、未完整消费再按 zlib 封装宽容
  // 重试，两个构造标志的行为都被覆盖（降级项，已文档化）。
  function JSInflater(noWrap) {
    return {
      _noWrap: !!noWrap,
      end: function () {},
      close: function () {}
    };
  }
  function JSInflaterInputStream(inStream, _inflater) {
    // 语料面：stream.read(buffer) 填充 buffer 并返回读入字节数，EOF 返回 -1；
    // 惰性解压——首次 read 调宿主 java.inflateRawBytes 全量解压并缓存，
    // 之后按 8192 字节分块读出；非法数据抛可捕获错误（对齐 Java 抛
    // DataFormatException，JS 侧 try/catch 降级）。
    var data = null;
    var pos = 0;
    function ensure() {
      if (data === null) {
        var src = (inStream && inStream._bytes) ? inStream._bytes : toU8(inStream || []);
        data = java.inflateRawBytes(toU8(src)) || new Uint8Array(0);
      }
    }
    return {
      read: function (buffer) {
        ensure();
        if (pos >= data.length) return -1;
        var n = Math.min(8192, data.length - pos);
        if (buffer && buffer.length >= n) {
          for (var i = 0; i < n; i++) buffer[i] = data[pos + i];
        }
        pos += n;
        return n;
      },
      available: function () { ensure(); return data.length - pos; },
      close: function () {}
    };
  }
  // java.security.MessageDigest 最小面（语料 3 命中：七猫 MD5 一次性 /
  // 微信读书 SHA-256 一次性 / 酷狗 MD5 增量 update+digest）。
  // getInstance(algo) → 实例：update(bytes) 累积，digest(bytes?) 收尾并返回
  // 字节数组（Uint8Array，Java 语义；hex/base64 由书源 JS 侧负责）。
  // 算法名经宿主 java.messageDigestValidate 预校验（未知算法 → shim 的
  // getInstance 登记台账 + 抛可读文案，不静默产出空摘要）；纯 Rust 计算走
  // java.messageDigestDigest(algo, bytes)。Java 语义：digest() 复位状态
  // （本 shim 直接重置 buf，与「一次 digest 后实例即重置」一致）；
  // update/digest 均返回 this 以支持链式。
  function JSMMessageDigestInstance(algo) {
    var buf = new Uint8Array(0);
    function append(chunk) {
      var c = toU8(chunk || []);
      var nb = new Uint8Array(buf.length + c.length);
      nb.set(buf, 0);
      nb.set(c, buf.length);
      buf = nb;
    }
    return {
      update: function (input) { append(input); return this; },
      digest: function (input) {
        if (arguments.length > 0) { append(input); }
        var out = java.messageDigestDigest(algo, buf);
        // Java 语义：digest() 复位状态
        buf = new Uint8Array(0);
        return out;
      }
    };
  }
  // 队列④ 能力受限：未知 Java 类/成员访问 → 登记符号 + 抛带明确文案的错误。
  // P2-E 读取语义：读取未知成员只登记并返回"可继续探测的哨兵"（不抛错）——
  // 语料中的探测式代码（`typeof Packages.foo !== 'undefined'` 三元回退，
  // RHINO_INTEROP_ANALYSIS_20260920 §8 命中 1 处）不再因一次读取中断整段脚本；
  // 哨兵在**调用 / new / 取子成员**时才抛带明确文案的错误（用户口径"正常就是
  // 不能用必须有提示"——提示保留在真正使用点）。
  // 逐节点包 Proxy：get 陷阱对字符串属性若目标上查不到（`in` 查不到——
  // 即连原型链上也没有）则返回全名哨兵；继承来的方法
  // （toString/hasOwnProperty/valueOf 等）与 Symbol 属性直通，防误报。
  // 函数（构造器）同样包一层——new/call 语义由默认 construct/apply 陷阱
  // 原样保留，仅未知成员访问才告警。
  // org.jsoup 经宿主桥实现（JSOUP_BRIDGE_JS 会替换其值），不对其加陷阱。
  function makeUnknownClassSentinel(full) {
    java.reportUnknownSymbol(full);
    var msg = '此书源需要 Java 脚本能力（Packages.' + full + '），当前不支持';
    // 目标必须是函数：对象目标 Proxy 的 apply/construct 陷阱不会被引擎调用
    // （直接抛原生 "not a function" TypeError，丢可读文案）；函数目标天然
    // 可调用/可构造，陷阱接管语义。
    // ownKeys:[] + has:false 为一致的不变量组合——函数目标的 length/name 是
    // 不可配置自有属性，ownKeys 不列出时 has 必须对其返回 false。
    // set 恒返回 false（length/name 不可写 → 不变量要求；其余键静默丢弃）。
    return new Proxy(function () {}, {
      get: function (_t, prop) {
        if (typeof prop !== 'string') { return undefined; }
        var sub = full + '.' + prop;
        java.reportUnknownSymbol(sub);
        throw new Error('此书源需要 Java 脚本能力（Packages.' + sub + '），当前不支持');
      },
      has: function () { return false; },
      apply: function () {
        java.reportUnknownSymbol(full + '()');
        throw new Error(msg);
      },
      construct: function () {
        java.reportUnknownSymbol(full);
        throw new Error(msg);
      },
      set: function () { return false; },
      ownKeys: function () { return []; }
    });
  }
  function trapNode(node, path) {
    if (node === null || (typeof node !== 'object' && typeof node !== 'function')) {
      return node;
    }
    if (typeof node === 'object') {
      for (var k in node) {
        if (Object.prototype.hasOwnProperty.call(node, k)) {
          node[k] = trapNode(node[k], (path === '' ? '' : path + '.') + k);
        }
      }
    }
    return new Proxy(node, {
      get: function (t, prop) {
        if (typeof prop !== 'string' || (prop in t)) {
          return Reflect.get(t, prop);
        }
        var full = (path === '') ? prop : (path + '.' + prop);
        return makeUnknownClassSentinel(full);
      }
    });
  }
  var __pkRoot = {
    java: {
      // P2-9 ① java.lang 最小静态面（语料命中：Thread.sleep 8 /
      // System.currentTimeMillis 4；parseInt 等通用面一并提供）
      // P2-11 §195：parse 面按 JDK 严格语义对齐（上游 Rhino LiveConnect
      // 调真实 java.lang 类：Integer.parseInt 全串严格 / Long.parseLong
      // 严格十进制 + long64 范围 / Double.parseDouble 接受 NaN/±Infinity/
      // hex-float、拒空白下划线 / Boolean.parseBoolean 不 trim）
      lang: {
        String: JavaString,
        Integer: {
          // Java Integer.parseInt：可选 +/- 号 + 全部字符为 radix 内数字，
          // 无空白/小数点/后缀；radix 2..36 越界抛错；int32 溢出抛错
          //（旧版用 JS parseInt 前缀语义：'12abc'→12，Java 抛错）
          parseInt: function (s, radix) {
            var str = String(s);
            var r = (arguments.length >= 2) ? Number(radix) : 10;
            if (isNaN(r) || r < 2 || r > 36) {
              throw new Error('Integer.parseInt: 无效进制 ' + radix);
            }
            var m = str.match(/^([+-]?)([0-9a-zA-Z]+)$/);
            if (!m) throw new Error('Integer.parseInt: 无法解析 ' + s);
            var digits = m[2];
            for (var i = 0; i < digits.length; i++) {
              var code = digits.charCodeAt(i);
              var val;
              if (code >= 48 && code <= 57) val = code - 48;
              else if (code >= 65 && code <= 90) val = code - 65 + 10;
              else if (code >= 97 && code <= 122) val = code - 97 + 10;
              else throw new Error('Integer.parseInt: 无法解析 ' + s);
              if (val >= r) throw new Error('Integer.parseInt: 无法解析 ' + s);
            }
            var v = parseInt(str, r);
            if (isNaN(v)) throw new Error('Integer.parseInt: 无法解析 ' + s);
            if (v < -2147483648 || v > 2147483647) {
              throw new Error('Integer.parseInt: 溢出 ' + s);
            }
            return v;
          },
          toString: function (v) { return String(v); }
        },
        Long: {
          // Java Long.parseLong（1 参）：严格十进制（非 0x）+ 可选 +/- +
          // long64 范围（字符串比较精确判定）；无空白。JS 无 int64 → 返回
          // 最近 float64（> 2^53 的值为近似，与 Rhino LiveConnect 自动转
          // JS number 行为一致；残余近似已登记）
          parseLong: function (s) {
            var str = String(s);
            if (!/^([+-]?[0-9]+)$/.test(str)) {
              throw new Error('Long.parseLong: 无法解析 ' + s);
            }
            var mag = str.replace(/^[+-]/, '').replace(/^0+/, '');
            if (mag === '') mag = '0';
            var limit = (str.charAt(0) === '-') ? '9223372036854775808' : '9223372036854775807';
            if (mag.length > limit.length || (mag.length === limit.length && mag > limit)) {
              throw new Error('Long.parseLong: 溢出 ' + s);
            }
            return Number(str);
          },
          toString: function (v) { return String(v); }
        },
        Double: {
          // Java Double.parseDouble：NaN/±Infinity（大小写敏感 token）→
          // 值（非异常）；十进制可带单个 d/D/f/F 尾缀；hex-float
          // 0[xX]hex[.hex][p[+-]digits] 手算（JS Number 不解析）；
          // 拒空白/下划线/空串；十进制溢出 → ±Infinity（非异常）
          parseDouble: function (s) {
            var str = String(s);
            if (str.length === 0 || /\s/.test(str) || str.indexOf('_') >= 0) {
              throw new Error('Double.parseDouble: 无法解析 ' + s);
            }
            // 单个尾缀 d|D|f|F（十进制/NaN/Infinity 均适用）
            if (/[dDfF]$/.test(str)) str = str.slice(0, -1);
            // ±NaN token → NaN 值（Java 大小写敏感：'nan' 抛错）
            if (/^[+-]?NaN$/.test(str)) return NaN;
            // 十六进制浮点：值 = hexMantissa / 2^(4*小数hex位数) × 2^pExp
            var m = str.match(/^([+-])?0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]+))?(?:[pP]([+-]?[0-9]+))?$/);
            if (m && (m[2] || m[3])) {
              var mant = m[2] + (m[3] || '');
              var sign = m[1] === '-' ? -1 : 1;
              var pExp = m[4] ? parseInt(m[4], 10) : 0;
              var fracLen = (m[3] || '').length;
              return sign * (parseInt(mant, 16) / Math.pow(2, 4 * fracLen)) * Math.pow(2, pExp);
            }
            var v = Number(str);
            if (isNaN(v)) throw new Error('Double.parseDouble: 无法解析 ' + s);
            return v;
          }
        },
        Boolean: {
          // Java 语义：仅 "true"（忽略大小写）为 true；**不 trim**
          //（" true " → false，旧版误 trim）；null/undefined → false
          parseBoolean: function (s) { return String(s).toLowerCase() === 'true'; },
          toString: function (v) { return String(!!v); }
        },
        Thread: {
          // 委托宿主 java.threadSleep（30s 上限，阻塞当前执行线程，
          // 与上游 JS 线程 Thread.sleep 语义一致）
          sleep: function (ms) { java.threadSleep(Number(ms) || 0); }
        },
        System: {
          currentTimeMillis: function () { return java.currentTimeMillis(); }
        }
      },
      util: {
        UUID: { randomUUID: function () { return { toString: function () { return uuidV4(); } }; } },
        Arrays: {
          copyOfRange: function (a, from, to) { return toU8(a).slice(from, to); },
          // 语料 1 命中：Arrays.copyOf(input, input.length)
          copyOf: function (a, len) {
            var src = toU8(a);
            var n = Math.max(0, Number(len) || 0);
            var out = new Uint8Array(n);
            out.set(src.subarray(0, Math.min(src.length, n)));
            return out;
          }
        },
        HashMap: JSHashMap,
        zip: { Inflater: JSInflater, InflaterInputStream: JSInflaterInputStream }
      },
      io: {
        // 队列末项 java.io 最小面：抽象基类 InputStream（字节缓冲读流，
        // 实例哨兵 + Java 语义构造/读，见构造器注释）——
        // favcomic（索引 703）decode 路径经 imageDecode/coverDecodeJs 调用
        ByteArrayInputStream: JSByteArrayInputStream,
        ByteArrayOutputStream: JSByteArrayOutputStream,
        InputStream: JSInputStream
      },
      nio: {
        ByteBuffer: {
          // 语料面：ByteBuffer.allocate(n).array()（wrInflateRaw 读缓冲）
          allocate: function (n) {
            var len = Math.max(0, Number(n) || 0);
            return {
              array: function () { return new Array(len); },
              capacity: function () { return len; }
            };
          }
        }
      },
      // java.security.MessageDigest 最小面（语料 3 命中，见 JSMMessageDigestInstance）：
      // getInstance(algo) 经宿主 java.messageDigestValidate 预校验算法（未知算法 →
      // java.reportUnknownSymbol 登记台账 + 抛可读文案，不静默产出空摘要）；
      // 返回实例的 update(bytes) 累积 / digest(bytes?) 输出字节数组（Uint8Array）
      security: {
        MessageDigest: {
          getInstance: function (algo) {
            var a = (algo == null) ? '' : String(algo);
            if (!java.messageDigestValidate(a)) {
              var full = 'java.security.MessageDigest.getInstance("' + a + '")';
              java.reportUnknownSymbol(full);
              throw new Error('此书源需要 Java 脚本能力（Packages.' + full + '），当前不支持');
            }
            return JSMMessageDigestInstance(a);
          }
        }
      }
    },
    android: { util: { Base64: {
      decode: function (s, flags) { return java.base64DecodeToByteArray(String(s), flags || 0); },
      encodeToString: function (bytes, flags) { return java.base64EncodeBytes(toU8(bytes)); }
    } },
    // 语料 Packages.android.text.TextUtils.isEmpty（#135 阅文）——Kotlin 语义：
    // `cs == null || cs.length == 0`（空串/未传 → true，非空 → false）— 3b-5
    text: { TextUtils: {
      isEmpty: function (s) { return s === null || s === undefined || String(s).length === 0; }
    } } },
    cn: { hutool: { crypto: { digest: { DigestUtil: { md5Hex: function (s) { return java.md5Encode(String(s)); } } } } } },
    javax: { crypto: {
      spec: {
        SecretKeySpec: function (key, algo) { return { key: toU8(key), algo: algo }; },
        IvParameterSpec: function (iv) { return { iv: toU8(iv) }; }
      },
      Cipher: {
        getInstance: function (transformation) {
          var t = String(transformation);
          return {
            init: function (mode, key, ivSpec) { this._mode = mode; this._key = key; this._iv = ivSpec; },
            doFinal: function (data) {
              var key = this._key ? toU8(this._key.key) : null;
              var iv = this._iv ? toU8(this._iv.iv) : null;
              return java.aesDecryptBytes(toU8(data), key, iv, t);
            }
          };
        }
      }
    } },
    // org.jsoup 预定义空对象：JSOUP_BRIDGE_JS 会写
    // `Packages.org = Packages.org || {}` 并替换 jsoup 值——
    // 若顶层树缺 org 键，读取会触发未知键陷阱
    org: { jsoup: {} }
  };
  globalThis.Packages = trapNode(__pkRoot, '');

  // 裸 java 全局镜像 java.security / java.lang（语料酷狗命中：裸
  // `java.security.MessageDigest` / `new java.lang.String(...)`，无 Packages 前缀）。
  // 重新暴露**同一** trapped 节点（非新增类）——未知成员访问仍走
  // reportUnknownSymbol 登记 + 可读文案；仅当裸 java 尚无同名键时补 java.lang
  // （宿主函数命名空间无 lang/security 键，安全）。
  if (globalThis.java && typeof globalThis.java === 'object') {
    globalThis.java.security = globalThis.Packages.java.security;
    if (globalThis.java.lang === undefined) {
      globalThis.java.lang = globalThis.Packages.java.lang;
    }
  }

  // Java.type / importClass 哨兵（语料零命中，RHINO_INTEROP_ANALYSIS_20260920 §8，
  // 但书源可能探测）：不静默 undefined——登记符号 + 抛带明确文案的错误
  globalThis.Java = {
    type: function (name) {
      var n = String(name == null ? '' : name);
      java.reportUnknownSymbol('Java.type(' + n + ')');
      throw new Error('此书源需要 Java 脚本能力（Java.type(' + n + ')），当前不支持');
    }
  };
  globalThis.importClass = function (cls) {
    var n = String(cls == null ? '' : cls);
    java.reportUnknownSymbol('importClass(' + n + ')');
    throw new Error('此书源需要 Java 脚本能力（importClass(' + n + ')），当前不支持');
  };
})();
"#;
    let _: rquickjs::Value = ctx
        .eval(shim)
        .map_err(|e| LegadoError::JsEngine(format!("Packages 模拟层注入失败: {e}")))?;
    Ok(())
}

/// 注入 java.get/post/head 的 jsoup Connection.Response 语义桥
///
/// 原版 JsExtensions.get(url, headers) 返回 jsoup Connection.Response，
/// 书源 @js: URL 模板常用 .header('Location') / .headers('Location')[0]
/// 拦截重定向。Rust 侧 java.get 单参绑定为变量表读取（原版无单参 get），
/// post/head 返回完整响应 JSON 字符串而非对象——JS 桥覆盖为对象语义：
/// 双参 get → 网络 GET Response；单参 get → 委托原生变量读取（兼容保留）。
/// — 新笔趣阁/新落秋/笔趣阁zdzn/天悦小说 搜索修复（2026-08-17）
#[cfg(feature = "quickjs")]
pub const RESPONSE_BRIDGE_JS: &str = r#"
(function () {
  function __resp(jsonStr) {
    var r = null;
    try { r = JSON.parse(jsonStr); } catch (e) { r = null; }
    var h = (r && r.headers) || {};
    return {
      header: function (name) {
        var lk = String(name).toLowerCase();
        for (var k in h) { if (String(k).toLowerCase() === lk) return h[k]; }
        return null;
      },
      headers: function (name) {
        if (arguments.length === 0) return h;
        var v = this.header(name);
        return v === null ? [] : [v];
      },
      body: function () { return (r && r.body) || ''; },
      statusCode: function () { return r ? r.status_code : 0; },
      headersMap: function () { return h; },
      // 辅助新增（非上游 OkHttp 面）：本响应最终 URL 的域归属 cookie 串
      //（响应 Set-Cookie 已在请求层落 cookie 存储，读即所得）— 3b-3
      cookies: function () { return java.getCookie((r && r.url) || ''); }
    };
  }
  var __nativeGetVariable = java.get;
  var __nativeConnect = java.connectNR;
  var __nativeConnectFull = java.connect;
  function __strResponse(jsonStr) {
    var r = null;
    try { r = JSON.parse(jsonStr); } catch (e) { r = null; }
    var finalUrl = (r && r.url) || '';
    var raw = {
      request: function () {
        return { url: function () { return finalUrl; } };
      },
      code: function () { return r ? r.status_code : 0; },
      headers: function () { return (r && r.headers) || {}; }
    };
    return {
      body: (r && r.body) || '',
      raw: function () { return raw; },
      callTime: function () { return 0; },
      // 辅助新增（非上游 OkHttp 面）：本响应最终 URL 的域归属 cookie 串 — 3b-3
      cookies: function () { return java.getCookie(finalUrl); }
    };
  }
  java.connect = function (url, arg2, arg3, arg4, arg5) {
    // rquickjs Opt<T> 不能接收显式 undefined；必须按实参数量调用原生函数。
    if (arguments.length <= 1) return __strResponse(__nativeConnectFull(String(url)));
    var isMethod = typeof arg2 === 'string' && /^(GET|POST|HEAD|PUT|DELETE)$/i.test(arg2);
    if (!isMethod) {
      var headerOnly = typeof arg2 === 'string' ? arg2 : JSON.stringify(arg2 || {});
      var timeoutOnly = arg3 == null ? undefined : arg3;
      return timeoutOnly === undefined
        ? __strResponse(__nativeConnectFull(String(url), 'GET', headerOnly))
        : __strResponse(__nativeConnectFull(String(url), 'GET', headerOnly, undefined, timeoutOnly));
    }
    var hs = arg3 == null ? undefined : (typeof arg3 === 'string' ? arg3 : JSON.stringify(arg3));
    if (arguments.length === 2) return __strResponse(__nativeConnectFull(String(url), arg2));
    if (arguments.length === 3) return __strResponse(__nativeConnectFull(String(url), arg2, hs));
    if (arguments.length === 4) return __strResponse(__nativeConnectFull(String(url), arg2, hs, String(arg4)));
    return __strResponse(__nativeConnectFull(String(url), arg2, hs, String(arg4), arg5));
  };
  globalThis.connect = java.connect;
  java.get = function (url, headers) {
    if (arguments.length >= 2) {
      var hs = typeof headers === 'string' ? headers : JSON.stringify(headers || {});
      return __resp(__nativeConnect(String(url), 'GET', hs));
    }
    return __nativeGetVariable(String(url));
  };
  // 对齐原版 JsExtensions.post/head：followRedirects(false)。
  // 天涯书库等源 java.post(...).header('location') 拦截 302；若跟随重定向则
  // Location 丢失 → String(null) → 请求落到 /null。
  java.post = function (url, body, headers) {
    var hs = typeof headers === 'string' ? headers : JSON.stringify(headers || {});
    return __resp(__nativeConnect(String(url), 'POST', hs, String(body)));
  };
  java.head = function (url, headers) {
    var hs = typeof headers === 'string' ? headers : JSON.stringify(headers || {});
    return __resp(__nativeConnect(String(url), 'HEAD', hs));
  };
})();

  // [可空入参垫片 | 2026-09-26] 原生 webView 已改 NullStr/NullBool 可空
  // 入参（null/undefined 均 None、上游 Kotlin String? 语义），换型后
  // arity=4 必填——垫片把缺参/undefined 补成 null，恒 4 参调用
  (function () {
    var nativeWebView = java.webView;
    java.webView = function (html, url, js, cacheFirst) {
      return nativeWebView(
        html === undefined ? null : html,
        url === undefined ? null : url,
        js === undefined ? null : js,
        cacheFirst === undefined ? null : cacheFirst === true
      );
    };
  })();

"#;

/// Rhino `org.jsoup.Jsoup` 模拟层（云霄小说/键盘小说/玄幻文学/77读书等
/// searchUrl `@js:` 块直接调用 `org.jsoup.Jsoup.parse(html).select(...)`）。
/// QuickJS 无 Java 包导入；经 `java.jsoupAttr/jsoupText/jsoupSize/jsoup*`
/// 宿主桥对齐 Jsoup 常用子集：
/// - **集合对象**（`select` 返回，对齐 `org.jsoup.select.Elements`）：
///   `attr/text/html`（首匹配语义）+ 集合 API `size()/get(i)/isEmpty()/first()/each()`
///   （77读书搜索规则 `rows.size()`/`rows.get(i)`——此前缺失，`rows.size()`
///   抛 `not a function`，整条搜索规则失败）；`select(sub)` 为集合内全部元素
///   的后代并集，扁平近似为 `css + ' ' + sub`（既有语义）。
/// - **单元素对象**（`get(i)/first()` 返回，对齐 `org.jsoup.Element` 常用面）：
///   `attr/text/html/select`（作用域为本元素 HTML 快照）+ `toString`；
///   `remove()` 登记到父元素 removed 列表 → 父元素 `html()/toString()` 不再
///   含被移除子块（字符串级近似移除，见 `jsoup_html_n_excluded` 文档）。
///   空集合 `get/first` 返回空元素（取值全空串），宽松偏离 jsoup 抛
///   IllegalStateException（书源侧普遍先 `size()` 守卫）。
/// - **`Packages.org.jsoup.parser.Parser.unescapeEntities(s, base)`**：
///   HTML 实体反转义（77读书正文规则；`base` 参数忽略，书源仅传 HTML base）。
#[cfg(feature = "quickjs")]
pub const JSOUP_BRIDGE_JS: &str = r#"
(function () {
  // 集合对象（select 返回值）：对齐 org.jsoup.select.Elements
  function __set(parent, html, css) {
    var h = String(html == null ? '' : html);
    var c = String(css || '');
    return {
      attr: function (name) { return java.jsoupAttrN(h, c, 0, String(name)); },
      text: function () { return java.jsoupTextN(h, c, 0); },
      html: function () { return java.jsoupHtmlN(h, c, 0); },
      size: function () { return java.jsoupSize(h, c); },
      isEmpty: function () { return java.jsoupSize(h, c) === 0; },
      first: function () { return __element(parent, h, c, 0); },
      last: function () { return __element(parent, h, c, Math.max(0, java.jsoupSize(h, c) - 1)); },
      get: function (i) { return __element(parent, h, c, i); },
      // 上游 Elements 继承 Java List：JS 侧 toArray() 返回元素数组
      //（语料笔趣阁/文学小说/晋江 bookList JS 首句 `result.toArray()`）
      // — 簇A 2026-09-26
      toArray: function () {
        var n = java.jsoupSize(h, c);
        var out = [];
        for (var j = 0; j < n; j++) out.push(__element(parent, h, c, j));
        return out;
      },
      each: function (fn) {
        var n = this.size();
        for (var j = 0; j < n; j++) { fn(this.get(j), j); }
      },
      select: function (sub) {
        var next = (c ? c + ' ' : '') + String(sub || '');
        return __set(parent, h, next.replace(/^\s+/, ''));
      },
      toString: function () { return java.jsoupHtmlN(h, c, 0); }
    };
  }
  // 单元素对象（get/first 返回值）：对齐 org.jsoup.Element 常用面
  function __element(parent, html, css, i) {
    var h = String(html == null ? '' : html);
    var c = String(css || '');
    var removed = [];
    function outerHtml() {
      if (removed.length === 0) return java.jsoupHtmlN(h, c, i);
      return java.jsoupHtmlNExcluded(h, c, i, removed.join('\n'));
    }
    var el = {
      attr: function (name) { return java.jsoupAttrN(h, c, i, String(name)); },
      text: function () { return java.jsoupTextN(h, c, i); },
      html: function () { return outerHtml(); },
      select: function (sub) { return __set(el, outerHtml(), String(sub || '')); },
      remove: function () {
        if (parent && typeof parent.__markRemoved === 'function') {
          parent.__markRemoved(c, i, removed);
        }
      },
      toString: function () { return outerHtml(); }
    };
    // 父元素登记：子块选择器 + 其内部已移除选择器（后代拼接传播）
    el.__markRemoved = function (subCss, subI, subRemoved) {
      removed.push(String(subCss));
      if (subRemoved) {
        for (var k = 0; k < subRemoved.length; k++) {
          removed.push(String(subCss) + ' ' + subRemoved[k]);
        }
      }
    };
    return el;
  }
  var Jsoup = {
    parse: function (html) {
      var h = String(html == null ? '' : html);
      return {
        select: function (css) { return __set(null, h, String(css || '')); },
        body: function () { return __element(null, h, 'body', 0); },
        // Document.text()（语料完本神站：doc.text() 取全文档文本）
        text: function () { return java.jsoupTextN(h, 'body', 0); },
        toString: function () { return h; }
      };
    }
  };
  // org.jsoup.parser.Parser.unescapeEntities(s, base)（HTML 实体反转义）
  var Parser = {
    unescapeEntities: function (s, _base) {
      return java.jsoupUnescapeEntities(String(s == null ? '' : s));
    }
  };
  // 链式规则引擎的「元素列表 → Elements」构造器：getElements 前缀选择器
  // 抽出的元素 HTML 列表（上游语义：JS 步的 result = 上一步的 Elements）。
  // 每个元素对象以自身 HTML 为内容（index 0），select/attr/text 就地求值。
  // — 簇A 2026-09-26
  globalThis.__jsoupElementsFromList = function (list) {
    var arr = [];
    for (var j = 0; j < list.length; j++) {
      arr.push(String(list[j] == null ? '' : list[j]));
    }
    var joined = arr.join(String.fromCharCode(10));
    return {
      toArray: function () {
        var out = [];
        for (var j = 0; j < arr.length; j++) out.push(__element(null, arr[j], '', 0));
        return out;
      },
      get: function (i) { return __element(null, arr[i] || '', '', 0); },
      size: function () { return arr.length; },
      isEmpty: function () { return arr.length === 0; },
      first: function () { return __element(null, arr[0] || '', '', 0); },
      last: function () { return __element(null, arr[arr.length - 1] || '', '', 0); },
      each: function (fn) {
        for (var j = 0; j < arr.length; j++) fn(__element(null, arr[j], '', 0), j);
      },
      select: function (sub) { return __set(null, joined, String(sub || '')); },
      attr: function (name) { return arr.length ? __element(null, arr[0], '', 0).attr(name) : ''; },
      text: function () { return java.jsoupTextN(joined, '', 0); },
      toString: function () { return joined; }
    };
  };
  globalThis.org = globalThis.org || {};
  globalThis.org.jsoup = globalThis.org.jsoup || {};
  globalThis.org.jsoup.Jsoup = Jsoup;
  globalThis.org.jsoup.parser = { Parser: Parser };
  if (globalThis.Packages) {
    globalThis.Packages.org = globalThis.Packages.org || {};
    globalThis.Packages.org.jsoup = globalThis.Packages.org.jsoup || {};
    globalThis.Packages.org.jsoup.Jsoup = Jsoup;
    globalThis.Packages.org.jsoup.parser = { Parser: Parser };
  }
})();
"#;

/// 注册编解码类 API
///
/// 对应 Kotlin 端 `JsEncodeUtils` + `JsExtensions` 中的编解码方法。
fn register_encoding_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // md5Encode(str) -> String（32 位）
    mount_dual(
        java,
        globals,
        "md5Encode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::md5_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // md5Encode16(str) -> String（16 位）
    mount_dual(
        java,
        globals,
        "md5Encode16",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::md5_encode_16(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64Encode(str) -> String
    mount_dual(
        java,
        globals,
        "base64Encode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::base64_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64Decode(str) -> String
    mount_dual(
        java,
        globals,
        "base64Decode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::base64_decode(&s).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64Decoder(str) -> String — base64Decode 别名（#561 语料期望；
    // 上游无此符号，登记为兼容 shim：解码口径与 base64Decode 完全一致）
    mount_dual(
        java,
        globals,
        "base64Decoder",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::base64_decode(&s).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64DecodeToByteArray(str, flags?) -> Uint8Array（字节数组）
    // 对应 Kotlin: base64DecodeToByteArray(str?, flags=0): ByteArray?
    // 空白输入返回 null（对齐 Kotlin 的 null 返回）；flags 兼容 Android URL_SAFE(8)
    mount_dual(
        java,
        globals,
        "base64DecodeToByteArray",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             s: String,
             flags: Opt<i32>|
             -> rquickjs::Result<rquickjs::Value<'js>> {
                use rquickjs::IntoJs;
                if s.trim().is_empty() {
                    // 对齐 Kotlin：isNullOrBlank -> null
                    return Ok(rquickjs::Value::new_null(ctx.clone()));
                }
                let bytes = encoding::base64_decode_bytes_with_flags(&s, flags.0.unwrap_or(0))
                    .map_err(|e| rquickjs::Error::FromJs {
                        from: "String",
                        to: "Uint8Array",
                        message: Some(e),
                    })?;
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), bytes)?;
                arr.into_js(&ctx)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexDecodeToByteArray(str) -> Uint8Array（字节数组）
    // P2-9 ①：语料 `java.hexDecodeToByteArray`（8/5），上游
    // JsExtensions.kt:666-668 `hexDecodeToByteArray(str): ByteArray?`。
    // 与 base64DecodeToByteArray 同一字节数组约定（空输入 → null，
    // 非法 hex → 可捕获的 FromJs 错误，JS 侧 try/catch 降级）。
    mount_dual(
        java,
        globals,
        "hexDecodeToByteArray",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, s: String| -> rquickjs::Result<rquickjs::Value<'js>> {
                use rquickjs::IntoJs;
                if s.trim().is_empty() {
                    return Ok(rquickjs::Value::new_null(ctx.clone()));
                }
                let bytes =
                    encoding::hex_decode_bytes(&s).map_err(|e| rquickjs::Error::FromJs {
                        from: "String",
                        to: "Uint8Array",
                        message: Some(e),
                    })?;
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), bytes)?;
                arr.into_js(&ctx)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexEncode(str) -> String
    mount_dual(
        java,
        globals,
        "hexEncode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::hex_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexEncodeToString(str) -> String — hexEncode 别名（#324 长佩语料，
    // 对齐上游 HexUtil.encodeHexStr 命名；输出同为小写 hex）
    mount_dual(
        java,
        globals,
        "hexEncodeToString",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            encoding::hex_encode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexDecode(str) -> String
    mount_dual(
        java,
        globals,
        "hexDecode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            // 容错：非合法 hex 原样返回（书山等源可能传入已解码文本）
            match encoding::hex_decode(&s) {
                Ok(v) => v,
                Err(_) => s,
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // sha256(str) -> String
    mount_dual(
        java,
        globals,
        "sha256",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String { encoding::sha256(&s) })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // encodeURI(str, enc?) -> String（对齐原版双参重载：燃文等源
    // java.encodeURI(String(key), "UTF8") 依赖；缺第二参默认 UTF-8）
    mount_dual(
        java,
        globals,
        "encodeURI",
        rquickjs::Function::new(ctx.clone(), |s: String, enc: Opt<String>| -> String {
            match enc.0 {
                Some(e) => encoding::encode_uri_charset(&s, &e),
                None => encoding::encode_uri(&s),
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // encodeURIComponent(value) -> String（JS 标准语义：保留 -_.!~*'()）
    // [UI-fix 2026-08-10 | Reasonix] 对齐原版 Rhino 内建：yckceo 书源
    // （思兔 sto66 等）searchUrl 模板 {{encodeURIComponent(key)}} 依赖此函数，
    // 缺失致表达式求值失败 → URL 残缺 → 搜索无结果
    // [MessageDigest 批次 2026-09-25] 入参由严格 String 改为 JS 语义 Coerced 强转：
    // 七猫 jsLib 的 qmUrl 对非字符串值（page:1 为 JS int）调用
    // encodeURIComponent(params[k])，Rhino/JS 原生 encodeURIComponent(1) 会 ToString
    // 成 "1"，而宿主严格 String 签名抛 `Error converting from js 'int' into type
    // 'string'` → qmSearch('测试',1) 整条 searchUrl 失败。改用 Coerced<String>
    //（JS_ToString）对齐 JS 规范 ToString 语义（int/bool/null/undefined 均强转）。
    mount_dual(
        java,
        globals,
        "encodeURIComponent",
        rquickjs::Function::new(
            ctx.clone(),
            |s: rquickjs::Coerced<std::string::String>| -> String {
                encoding::encode_uri_component(&s.0)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacMd5(data, key) -> String
    mount_dual(
        java,
        globals,
        "hmacMd5",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            encoding::hmac_md5(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacSha256(data, key) -> String
    mount_dual(
        java,
        globals,
        "hmacSha256",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            encoding::hmac_sha256(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // digestHex(data, algorithm) -> String
    mount_dual(
        java,
        globals,
        "digestHex",
        rquickjs::Function::new(ctx.clone(), |data: String, algorithm: String| -> String {
            encoding::digest_hex(&data, &algorithm).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // digestBase64Str(data, algorithm) -> String
    mount_dual(
        java,
        globals,
        "digestBase64Str",
        rquickjs::Function::new(ctx.clone(), |data: String, algorithm: String| -> String {
            encoding::digest_base64_str(&data, &algorithm)
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacHex(data, algorithm, key) -> String
    mount_dual(
        java,
        globals,
        "hmacHex",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, algorithm: String, key: String| -> String {
                encoding::hmac_hex(&data, &algorithm, &key)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hmacBase64(data, algorithm, key) -> String
    mount_dual(
        java,
        globals,
        "hmacBase64",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, algorithm: String, key: String| -> String {
                encoding::hmac_base64(&data, &algorithm, &key)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // HMacBase64(data, algorithm, key) -> String
    // #135 阅文 QDSign：java.HMacBase64(sign, "HMAC-SHA1", aid).slice(0, -4)
    // 对齐上游 JsExtensions 的 JCA 风格命名（JS 属性访问大小写敏感，
    // 与 hmacBase64 共存）；算法名归一支持 "HMAC-SHA1"/"HmacSHA1"
    // （见 encoding::normalize_hmac_algorithm）。
    mount_dual(
        java,
        globals,
        "HMacBase64",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, algorithm: String, key: String| -> String {
                encoding::hmac_base64(&data, &algorithm, &key)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // strToBytes(str, charset?) -> String (JSON array)
    mount_dual(
        java,
        globals,
        "strToBytes",
        rquickjs::Function::new(ctx.clone(), |s: String, charset: Opt<String>| -> String {
            encoding::str_to_bytes(&s, charset.0.as_deref())
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // bytesToStr(bytesJson, charset?) -> String
    mount_dual(
        java,
        globals,
        "bytesToStr",
        rquickjs::Function::new(
            ctx.clone(),
            |bytes_json: String, charset: Opt<String>| -> String {
                encoding::bytes_to_str(&bytes_json, charset.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // base64EncodeBytes(bytes) -> String（字节数组 → Base64）
    // Packages 模拟层 android.util.Base64.encodeToString 依赖
    mount_dual(
        java,
        globals,
        "base64EncodeBytes",
        rquickjs::Function::new(ctx.clone(), |bytes: rquickjs::TypedArray<u8>| -> String {
            encoding::base64_encode_bytes(bytes.as_ref())
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // hexDecodeToString(hex) -> String（书山聚合等源把 hex 编码响应还原为 JSON；
    // 对应 Kotlin HexUtil.decodeHexStr / hexDecodeToString）
    // 容错：输入非合法 hex 时**原样返回**（书山 toc_body 可能是 hex 或已解码文本；
    // 绝不可返回 "[ERROR]..." 前缀——会被 JS 当源码执行报 syntax error）
    mount_dual(
        java,
        globals,
        "hexDecodeToString",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            match encoding::hex_decode(&s) {
                Ok(v) => v,
                Err(_) => s,
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册字符串工具 API
fn register_string_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "urlencode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::urlencode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "urldecode",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::urldecode(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "trimStart",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::trim_start(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "trimEnd",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::trim_end(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "substringBefore",
        rquickjs::Function::new(ctx.clone(), |s: String, d: String| -> String {
            string_utils::substring_before(&s, &d).to_string()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "substringAfter",
        rquickjs::Function::new(ctx.clone(), |s: String, d: String| -> String {
            string_utils::substring_after(&s, &d).to_string()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "replaceFirst",
        rquickjs::Function::new(
            ctx.clone(),
            |s: String, old: String, new: String| -> String {
                string_utils::replace_first(&s, &old, &new)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "replaceAll",
        rquickjs::Function::new(
            ctx.clone(),
            |s: String, old: String, new: String| -> String {
                string_utils::replace_all(&s, &old, &new)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toNumChapter(s) -> String
    mount_dual(
        java,
        globals,
        "toNumChapter",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            string_utils::to_num_chapter(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 JSON 工具 API
fn register_json_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "jsonPath",
        rquickjs::Function::new(ctx.clone(), |json: String, path: String| -> String {
            match json_utils::json_path(&json, &path) {
                Ok(results) => results.join("\n"),
                Err(e) => format!("[ERROR] {}", e),
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "jsonGetString",
        rquickjs::Function::new(ctx.clone(), |json: String, key: String| -> String {
            json_utils::json_get_string(&json, &key).unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "toJson",
        rquickjs::Function::new(ctx.clone(), |json: String| -> String {
            json_utils::to_json(&json).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册正则工具 API
fn register_regex_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "regExp",
        rquickjs::Function::new(
            ctx.clone(),
            |text: String, pattern: String, group: i32| -> String {
                regex_utils::reg_exp(&text, &pattern, group as usize).unwrap_or_default()
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "regExpReplace",
        rquickjs::Function::new(
            ctx.clone(),
            |text: String, pattern: String, replacement: String| -> String {
                regex_utils::reg_exp_replace(&text, &pattern, &replacement)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "regExpFindAll",
        rquickjs::Function::new(ctx.clone(), |text: String, pattern: String| -> String {
            regex_utils::reg_exp_find_all(&text, &pattern)
                .map(|v| v.join("\n"))
                .unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册时间工具 API
fn register_time_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "formatTime",
        rquickjs::Function::new(ctx.clone(), |ts: i64, format: String| -> String {
            let fmt = if format.is_empty() {
                None
            } else {
                Some(format.as_str())
            };
            time_utils::format_time(ts, fmt).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // timeFormat(ts) -> String
    // 对应 Kotlin: timeFormat(time: Long)，格式为 AppConst.dateFormat "yyyy/MM/dd HH:mm"。
    // 保留上方 formatTime(ts, format) 注册名，兼容已按该名调用的现有书源。
    mount_dual(
        java,
        globals,
        "timeFormat",
        rquickjs::Function::new(ctx.clone(), |ts: i64| -> String {
            time_utils::format_time(ts, Some("%Y/%m/%d %H:%M"))
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "timeFormatUTC",
        rquickjs::Function::new(ctx.clone(), |ts: i64, format: String, sh: i32| -> String {
            // 对齐 Kotlin SimpleTimeZone(sh, "UTC")：sh 为毫秒偏移
            let fmt = if format.is_empty() {
                None
            } else {
                Some(format.as_str())
            };
            time_utils::format_time_utc(ts, fmt, sh).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "currentTimeMillis",
        rquickjs::Function::new(ctx.clone(), || -> i64 { time_utils::current_time_millis() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "parseTime",
        rquickjs::Function::new(ctx.clone(), |time_str: String, format: String| -> i64 {
            let fmt = if format.is_empty() {
                None
            } else {
                Some(format.as_str())
            };
            time_utils::parse_time(&time_str, fmt).unwrap_or(-1)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册文件工具 API
fn register_file_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "readFile",
        rquickjs::Function::new(ctx.clone(), |path: String| -> String {
            file_utils::read_file(&path).unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "writeFile",
        rquickjs::Function::new(ctx.clone(), |path: String, content: String| -> bool {
            file_utils::write_file(&path, &content).is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "fileExists",
        rquickjs::Function::new(ctx.clone(), |path: String| -> bool {
            file_utils::file_exists(&path).unwrap_or(false)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "deleteFile",
        rquickjs::Function::new(ctx.clone(), |path: String| -> bool {
            file_utils::delete_file(&path).unwrap_or(false)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // readTxtFile(path, charset?) -> String
    mount_dual(
        java,
        globals,
        "readTxtFile",
        rquickjs::Function::new(
            ctx.clone(),
            |path: String, charset: Opt<String>| -> String {
                file_utils::read_txt_file(&path, charset.0.as_deref()).unwrap_or_default()
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // downloadFile 重载对齐 Kotlin JsExtensions：
    // - downloadFile(url) / downloadFile(url, fileName?)
    // - downloadFile(contentHex, url)（@Deprecated：十六进制内容落盘）
    mount_dual(
        java,
        globals,
        "downloadFile",
        rquickjs::Function::new(ctx.clone(), |arg1: String, arg2: Opt<String>| -> String {
            match arg2.0.as_deref() {
                None => file_utils::download_file(&arg1, None)
                    .unwrap_or_else(|e| format!("[ERROR] {}", e)),
                Some(second)
                    if second.starts_with("http://")
                        || second.starts_with("https://")
                        || second.contains(",{") =>
                {
                    // 废弃重载：content(hex) + url
                    file_utils::download_file_from_hex(&arg1, second)
                        .unwrap_or_else(|e| format!("[ERROR] {}", e))
                }
                Some(file_name) => file_utils::download_file(&arg1, Some(file_name))
                    .unwrap_or_else(|e| format!("[ERROR] {}", e)),
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getFile(path) -> File 风格对象（exists/getName/getAbsolutePath/toString）
    // 对齐 Kotlin JsExtensions.getFile(path): File（沙箱路径）
    mount_dual(
        java,
        globals,
        "getFile",
        rquickjs::Function::new(ctx.clone(), |ctx, path: String| {
            let abs = match file_utils::resolve_safe_path(&path) {
                Ok(p) => p,
                Err(e) => {
                    return Err(rquickjs::Exception::throw_message(
                        &ctx,
                        &format!("getFile: {e}"),
                    ));
                }
            };
            let abs_str = abs.to_string_lossy().into_owned();
            let name = abs
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let exists = abs.exists();
            let obj = rquickjs::Object::new(ctx.clone())?;
            obj.set("path", abs_str.clone())?;
            obj.set(
                "exists",
                rquickjs::Function::new(ctx.clone(), move || exists)?,
            )?;
            let name_c = name.clone();
            obj.set(
                "getName",
                rquickjs::Function::new(ctx.clone(), move || name_c.clone())?,
            )?;
            let abs_c = abs_str.clone();
            obj.set(
                "getAbsolutePath",
                rquickjs::Function::new(ctx.clone(), move || abs_c.clone())?,
            )?;
            let abs_c2 = abs_str;
            obj.set(
                "toString",
                rquickjs::Function::new(ctx.clone(), move || abs_c2.clone())?,
            )?;
            Ok(obj)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // cacheFile(url) -> String
    mount_dual(
        java,
        globals,
        "cacheFile",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            file_utils::cache_file(&url).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // importScript(url) -> String
    mount_dual(
        java,
        globals,
        "importScript",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            file_utils::import_script(&url).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getTxtInFolder(folderPath) -> String
    mount_dual(
        java,
        globals,
        "getTxtInFolder",
        rquickjs::Function::new(ctx.clone(), |folder_path: String| -> String {
            file_utils::get_txt_in_folder(&folder_path).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册变量存取 API
fn register_variable_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    mount_dual(
        java,
        globals,
        "getVariable",
        rquickjs::Function::new(ctx.clone(), |key: String| -> String {
            variable_store::get_variable(&key)
                .ok()
                .flatten()
                .unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "setVariable",
        rquickjs::Function::new(ctx.clone(), |key: String, value: String| -> bool {
            variable_store::set_variable(&key, &value).is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "removeVariable",
        rquickjs::Function::new(ctx.clone(), |key: String| -> bool {
            variable_store::remove_variable(&key)
                .ok()
                .flatten()
                .is_some()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "clearVariables",
        rquickjs::Function::new(ctx.clone(), || -> bool {
            variable_store::clear_variables().is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // 对齐 AnalyzeRule.put / get / setLocal（与 getVariable 共用全局表作 JS 会话变量）
    mount_dual(
        java,
        globals,
        "put",
        rquickjs::Function::new(ctx.clone(), |key: String, value: String| -> String {
            let _ = variable_store::set_variable(&key, &value);
            value
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "get",
        rquickjs::Function::new(ctx.clone(), |key: String| -> String {
            variable_store::get_variable(&key)
                .ok()
                .flatten()
                .unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "setLocal",
        rquickjs::Function::new(ctx.clone(), |key: String, value: String| -> bool {
            variable_store::set_variable(&key, &value).is_ok()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // P2-9 ③：进程级全局变量表桥接。解析器 JS 前导（AnalyzeRule::execute_js_rule）
    // 会把 java.put/java.get 覆盖为 eval 内 __lgVars 本地快照（注入的会话变量
    // 优先）；引擎注册这两个桥接函数后，前导的 java.put 同步写全局表、java.get
    // 本地未命中兜底读全局表（本地优先）——恢复原版「java.put → @get 跨规则
    // 可见」的会话变量语义（手机小说 init `java.put("url",…)` 须被 tocUrl
    // `@get:{url}` 读到，否则目录页回退 book_url）。仅挂 java 命名空间
    //（前导统一经 `java.__lgStore*` 引用），不上全局裸名。
    //
    // P1-1/P1-2（P2-9 ③ 审查修复）：桥读写改走 **flow scope** 会话层
    //（`lgflow::{scope}{key}` 命名空间，scope 由 FFI 各书籍流程入口
    // `begin_book_flow` 设置）：换书只清旧 scope 前缀（持久裸键
    // `v_*`/`sourceVariable_*`/登录缓存/`cache.*` 不受影响，P1-1），
    // 跨书源/跨书会话键互不可见（P1-2）。未设 scope 的直用引擎/残留
    // 入口回落裸键（与 P2-9 ③ 引入前一致）。裸 `put`/`get`/`setVariable`
    // 等源上下文挂载（source.put/cache.put 等持久键写入者）保持不变。
    let store_put = rquickjs::Function::new(ctx.clone(), |key: String, value: String| {
        let _ = variable_store::put_flow_variable(&key, &value);
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgStorePut", store_put)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    let store_get = rquickjs::Function::new(ctx.clone(), |key: String| -> String {
        variable_store::get_flow_variable(&key).unwrap_or_default()
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgStoreGet", store_get)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    Ok(())
}

/// P2-11 ①：`book` 绑定写路径宿主桥（java-only，不上裸全局）
/// P2-15：追加读桥 `__lgBookVarGet`（同阶段跨规则可见性的读路径）
///
/// FFI 侧 `web_book.rs` 的 `book` 绑定 IIFE 中，`book.putVariable` /
/// `book.type=` / `book.setReverseToc` 等写操作经本模块的桥落到
/// [`variable_store`] 的**裸键持久层**（键格式由
/// [`variable_store::book_var_key`] / [`variable_store::book_type_key`] /
/// [`variable_store::book_reverse_toc_key`] 构造，两侧共用防漂移）：
///
/// - `__lgBookVarSet(bookUrl, key, value)` / `__lgBookVarDel(bookUrl, key)`
///   → `bookVar::{bookUrl}::{key}`（`putVariable(k,null)` 走删除路径）
/// - `__lgBookSetType(bookUrl, typeStr)` → `bookType::{bookUrl}`
///   （语料 `book.type=8/32/64` 切小说/音频/漫画模式的落点）
/// - `__lgBookSetReverseToc(bookUrl, flagStr)` → `bookReverseToc::{bookUrl}`
/// - 【P2-15】`__lgBookVarGet(bookUrl, key)` → 读 `bookVar::{bookUrl}::{key}`，
///   未命中返回 `""`。供 IIFE `book.getVariable` 在本地字面量（构造期
///   快照）未命中时兜底，闭合**同阶段跨规则**读路径：同阶段规则 B 的
///   新 IIFE 实例字面量是构造时点快照（不含规则 A 在构造后的写入），
///   经本桥回读 store 才可见（对齐上游同书 `Book.variable` 活对象语义）。
///   bookUrl 由 IIFE 以 `b.bookUrl`（本书）传入，跨书不串读。
///
/// **生命周期**：进程级（`GLOBAL_VARIABLES`，进程重启即失——降级项，
/// 未做 DB 持久化）。**可见性**（P2-15 修正，此前「同书后续规则/请求
/// 均能看到」表述不准确——同阶段**同字面量**只含构造时点值）：
/// 1. **绑定构造期**：同 `bookUrl` 的详情 → 目录 → 正文 / 二次详情 /
///    换源各阶段**新构造**的绑定，经 `web_book::book_write_overlays`
///    读回本层并合并进字面量 → 后续阶段的绑定初值含前面阶段的写入；
/// 2. **同阶段跨规则**（P2-15）：同阶段规则 B 的新 IIFE 实例经
///    `__lgBookVarGet` 兜底读 store，对规则 A 在构造后的写入可见；
/// 3. **`java.get`/`@get`**（P2-15）：经 `variable_store::get_flow_variable`
///    链尾 bookVar 兜底（flow scope = 本书 bookUrl 时），同书同流程内
///    可见（就去看网 `book.putVariable` → `java.get` 闭环）。
///
/// 跨书以 `bookUrl` 隔离，不串读。
/// **降级说明**：引擎未注入这些桥（非 QuickJS 引擎 / 旧引擎实例）时
/// IIFE 内的探测函数 `hb` 返回 null，写操作静默退化为仅改本地副本
/// （等价改造前行为，不抛错）；读桥缺失时 `getVariable` 回退改造前
/// 的纯本地字面量行为；桥写入失败（store 锁异常等）同样 `let _ =`
/// 吞掉——写路径永不阻断规则求值。
#[cfg(feature = "quickjs")]
fn register_book_binding_bridges<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    let var_set = rquickjs::Function::new(
        ctx.clone(),
        |book_url: String, key: String, value: String| {
            let _ = variable_store::set_variable(
                &variable_store::book_var_key(&book_url, &key),
                &value,
            );
        },
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgBookVarSet", var_set)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    let var_del = rquickjs::Function::new(ctx.clone(), |book_url: String, key: String| {
        let _ = variable_store::remove_variable(&variable_store::book_var_key(&book_url, &key));
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgBookVarDel", var_del)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // P2-15：读桥——IIFE `book.getVariable` 本地字面量未命中时回读本层
    // （同阶段跨规则可见性；未命中/锁失败返回空串，不抛错）
    let var_get = rquickjs::Function::new(ctx.clone(), |book_url: String, key: String| -> String {
        variable_store::get_variable(&variable_store::book_var_key(&book_url, &key))
            .ok()
            .flatten()
            .unwrap_or_default()
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgBookVarGet", var_get)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    let set_type = rquickjs::Function::new(ctx.clone(), |book_url: String, value: String| {
        let _ = variable_store::set_variable(&variable_store::book_type_key(&book_url), &value);
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgBookSetType", set_type)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    let set_reverse_toc = rquickjs::Function::new(ctx.clone(), |book_url: String, flag: String| {
        let _ =
            variable_store::set_variable(&variable_store::book_reverse_toc_key(&book_url), &flag);
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("__lgBookSetReverseToc", set_reverse_toc)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    Ok(())
}

/// 注册工具类 API
fn register_utility_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // randomUUID() -> String
    mount_dual(
        java,
        globals,
        "randomUUID",
        rquickjs::Function::new(ctx.clone(), || -> String {
            uuid::Uuid::new_v4().to_string()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // log(msg) -> msg（打印并返回）
    mount_dual(
        java,
        globals,
        "log",
        rquickjs::Function::new(ctx.clone(), |msg: String| -> String {
            eprintln!("[legado-js] {}", msg);
            msg
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // reGetBook() — 仅 preUpdateJs（对齐 AnalyzeRule.reGetBook）
    mount_dual(
        java,
        globals,
        "reGetBook",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>| -> rquickjs::Result<()> {
                apply_pre_update_book_json(
                    &ctx,
                    crate::host_api::pre_update_hooks::call_re_get_book(),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // refreshTocUrl() — 仅 preUpdateJs（对齐 AnalyzeRule.refreshTocUrl）
    mount_dual(
        java,
        globals,
        "refreshTocUrl",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>| -> rquickjs::Result<()> {
                apply_pre_update_book_json(
                    &ctx,
                    crate::host_api::pre_update_hooks::call_refresh_toc_url(),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // upLoginData(data?) — P2-9 ①：语料 `java.upLoginData`（7/6，
    // 形态：upLoginData() / upLoginData(map) / upLoginData(saved)）。
    // 上游 SourceLoginJsExtensions.kt:35-37 经 WebView 登录回调上报登录态。
    // 本宿主无 WebView/登录回调通道：提供「注册 + 显式降级」——仅记录日志
    // 并正常返回（永不抛异常），不中断书源脚本流程（降级项，已在交付
    // 报告列出；若未来有登录态存储层，可在此接上真实上报）。
    mount_dual(
        java,
        globals,
        "upLoginData",
        rquickjs::Function::new(
            ctx.clone(),
            |_ctx: rquickjs::Ctx<'js>, _data: Opt<rquickjs::Value>| -> () {
                eprintln!("[legado-js] upLoginData: 无登录回调通道，降级为 no-op");
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // threadSleep(ms) — P2-9 ①：语料 `Packages.java.lang.Thread.sleep`（8 命中）
    // 由 Packages shim 的 lang.Thread.sleep 委托到本宿主方法。
    // std::thread::sleep 阻塞当前执行线程（与上游 JS 线程语义一致）；
    // 上限 30s 防止书源写死超大 sleep 卡死引擎（降级，已文档化）。
    mount_dual(
        java,
        globals,
        "threadSleep",
        rquickjs::Function::new(ctx.clone(), |ms: i64| -> () {
            let ms = ms.clamp(0, 30_000);
            std::thread::sleep(std::time::Duration::from_millis(ms as u64));
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // sleep(ms) — threadSleep 别名（#45 露西弗俱乐部语料 java.sleep(1000)）。
    // 风险口径与 threadSleep 完全一致（#45 可行性评估结论）：
    // 阻塞的是 JS 执行工作线程而非 UI 线程，0..=30000ms 钳制；
    // #45 的调用点均包在 }catch(e){} 内，上限降级可被 JS 捕获。
    mount_dual(
        java,
        globals,
        "sleep",
        rquickjs::Function::new(ctx.clone(), |ms: i64| -> () {
            let ms = ms.clamp(0, 30_000);
            std::thread::sleep(std::time::Duration::from_millis(ms as u64));
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // inflateRawBytes(bytes) -> Uint8Array — P2-9 ①：语料
    // `java.util.zip.Inflater` 流程（2 源）的 raw-deflate 解压宿主桥，
    // Packages shim 的 util.zip.Inflater/InflaterInputStream 委托到本方法。
    // 非法数据抛可捕获错误（JS 侧 try/catch 降级为空结果，不炸整条规则）。
    mount_dual(
        java,
        globals,
        "inflateRawBytes",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             bytes: rquickjs::TypedArray<u8>|
             -> rquickjs::Result<rquickjs::Value<'js>> {
                use rquickjs::IntoJs;
                let data: Vec<u8> = bytes.as_bytes().map(|b| b.to_vec()).unwrap_or_default();
                let out = archive_utils::inflate_raw_bytes(&data).map_err(|e| {
                    rquickjs::Error::FromJs {
                        from: "Uint8Array",
                        to: "Uint8Array",
                        message: Some(e),
                    }
                })?;
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), out)?;
                arr.into_js(&ctx)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 将钩子返回的 book JSON 合并进 globalThis.book（对齐原版原地改 Book）
fn apply_pre_update_book_json<'js>(
    ctx: &rquickjs::Ctx<'js>,
    result: Result<String, String>,
) -> rquickjs::Result<()> {
    let json = result.map_err(|e| rquickjs::Error::FromJs {
        from: "preUpdateHook",
        to: "unit",
        message: Some(e),
    })?;
    let updated = json_string_to_object(ctx, &json)?;
    let globals = ctx.globals();
    if let Ok(book) = globals.get::<_, rquickjs::Object>("book") {
        for entry in updated.props::<String, rquickjs::Value>() {
            let (k, v) = entry?;
            book.set(k, v)?;
        }
    }
    Ok(())
}

/// JSON 对象字符串 → QuickJS Object（ConfigMap / preUpdate 共用）
fn json_string_to_object<'js>(
    ctx: &rquickjs::Ctx<'js>,
    json: &str,
) -> rquickjs::Result<rquickjs::Object<'js>> {
    let globals = ctx.globals();
    let json_mod: rquickjs::Object = globals.get("JSON")?;
    let parse: rquickjs::Function = json_mod.get("parse")?;
    parse.call((json,))
}

/// 注册网络类 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 ajax/ajaxAll/connect/get/post/head 等方法。
fn register_network_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // httpGet(url, headers?) -> String
    mount_dual(
        java,
        globals,
        "httpGet",
        rquickjs::Function::new(ctx.clone(), |url: String, headers: Opt<String>| -> String {
            network::http_get(&url, headers.0.as_deref())
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // httpPost(url, body, headers?) -> String
    mount_dual(
        java,
        globals,
        "httpPost",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, body: String, headers: Opt<String>| -> String {
                network::http_post(&url, &body, headers.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // httpHead(url) -> String（响应头 JSON）
    mount_dual(
        java,
        globals,
        "httpHead",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            network::http_head(&url).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // ajax(options_json) -> String（HttpResponse JSON）
    mount_dual(
        java,
        globals,
        "ajax",
        rquickjs::Function::new(ctx.clone(), |options: String| -> String {
            network::ajax(&options).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // putGlobalHeaders(headers_json) -> bool
    // 书源 header @js 规则执行结果写入全局请求头（按当前书源 tag 隔离），
    // java.ajax 自动携带（对齐 AnalyzeUrl.getHeaderMap；书山固定 X-Novel-Token）
    mount_dual(
        java,
        globals,
        "putGlobalHeaders",
        rquickjs::Function::new(ctx.clone(), |headers_json: String| -> bool {
            match serde_json::from_str::<std::collections::HashMap<String, String>>(&headers_json) {
                Ok(map) => {
                    let tag =
                        crate::host_api::current_source::current_source_tag().unwrap_or_default();
                    crate::host_api::global_headers::put_headers(&tag, map);
                    true
                }
                Err(_) => false,
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getCurrentUrl() -> String（`java.url` 属性后端）
    // 读 legado-parser 的 CURRENT_URL 线程局部（对齐上游 AnalyzeUrl.evalJS
    // `bindings["java"] = this` 口径：URL 规则 JS 窗口内 java 即 AnalyzeUrl
    // 实例）——`@js:`/`{{}}` 窗口为空串（上游 url 字段未赋值）、URL 选项
    // js 窗口为已解析绝对 URL；非 URL 窗口返回空串（setup 脚本 java.url
    // getter 再回退 sourceUrl，对齐上游 BaseSource.evalJS java=source）
    mount_dual(
        java,
        globals,
        "getCurrentUrl",
        rquickjs::Function::new(ctx.clone(), || -> String {
            legado_parser::analyze_url::current_url().unwrap_or_default()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // headerMapPut(key, value) -> bool（`java.headerMap.put` 后端）
    // 上游 URL 规则窗口内 java.headerMap 即 AnalyzeUrl 实例的请求头 Map
    //（写入直接生效于本次请求）；Rust 侧经 legado-parser 线程局部收集器
    // 暂存，parse_with_js 收尾并入 AnalyzeUrl.headers → fetch_page 组头生效。
    // 非 URL 窗口写入会被下次窗口收尾丢弃（上游同款：无 AnalyzeUrl 上下文
    // 则无 headerMap 可写；语料 #286 仅在选项 js 窗口使用）。
    mount_dual(
        java,
        globals,
        "headerMapPut",
        rquickjs::Function::new(ctx.clone(), |key: String, value: String| -> bool {
            legado_parser::analyze_url::push_pending_request_header(key, value);
            true
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // ajaxAll(urls_json) -> String（JSON 数组，并发请求多个 URL）
    // 对应 Kotlin: ajaxAll(urlList: Array<String>): Array<StrResponse>
    mount_dual(
        java,
        globals,
        "ajaxAll",
        rquickjs::Function::new(ctx.clone(), |urls: String| -> String {
            network::ajax_all(&urls).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // connect(url, method?, headers?, body?, timeoutMs?) -> String（完整响应 JSON）
    // 对应 Kotlin: connect(urlStr, header, callTimeout): StrResponse
    // 增强：支持指定 HTTP 方法（GET/POST/HEAD/PUT/DELETE）
    mount_dual(
        java,
        globals,
        "connect",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String,
             method: Opt<String>,
             headers: Opt<String>,
             body: Opt<String>,
             timeout_ms: Opt<i64>|
             -> String {
                network::connect_full(
                    &url,
                    method.0.as_deref(),
                    headers.0.as_deref(),
                    body.0.as_deref(),
                    timeout_ms.0.map(|t| t as u64),
                )
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // connectNR(url, method?, headers?, body?) -> String（完整响应 JSON，不跟随重定向）
    // 对齐原版 jsoup followRedirects(false)：java.get/post/head 拦截重定向需读 Location 头
    mount_dual(
        java,
        globals,
        "connectNR",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, method: Opt<String>, headers: Opt<String>, body: Opt<String>| -> String {
                network::connect_no_redirect(
                    &url,
                    method.0.as_deref(),
                    headers.0.as_deref(),
                    body.0.as_deref(),
                )
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // head(url, headers?) -> String（完整响应 JSON）
    // 对应 Kotlin: head(urlStr, headers): Connection.Response
    mount_dual(
        java,
        globals,
        "head",
        rquickjs::Function::new(ctx.clone(), |url: String, headers: Opt<String>| -> String {
            network::head_full(&url, headers.0.as_deref())
                .unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // post(url, body, headers?) -> String（完整响应 JSON）
    // 对应 Kotlin: post(urlStr, body, headers): Connection.Response
    mount_dual(
        java,
        globals,
        "post",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, body: String, headers: Opt<String>| -> String {
                network::post_full(&url, &body, headers.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 Cookie API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 getCookie/setCookie/clearCookies 方法。
fn register_cookie_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // getCookie(url, key?) -> String
    // 参数名为历史遗留（曾按书源 tag 口径命名）：上游同步后（2026-09-23 用户裁决）
    // 该参数语义为**请求/写入 URL**（或 URL 形态原始串键），归一与取用下沉在
    // cookie_store 内部（写侧 `getSubDomain(url)` 等价域名键，读侧按 URL 属域 +
    // 原始串兼容键，详见 [`cookie_store`] 模块文档）。
    mount_dual(
        java,
        globals,
        "getCookie",
        rquickjs::Function::new(ctx.clone(), |url: String, key: Opt<String>| -> String {
            match key.0 {
                Some(k) => cookie_store::get_cookie_by_key(&url, &k),
                None => cookie_store::get_cookie(&url),
            }
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // setCookie(url, cookieStr) -> bool
    // 第一参为 **URL**（非书源 tag）：对齐上游 `CookieStore.setCookie(url, cookie)`
    // （归一为 `getSubDomain(url)` 域名键后落存储）；非 http(s) / 解析失败的原始串
    // 保留原键（镜像上游回退）。
    // cookieStr 格式: "key=value" 或 "key=value; key2=value2"——解析口径
    // （`;` 拆段、首个 `=` 分界、无 `=` 段 / 空键跳过、各 trim 一次）下沉在
    // `cookie_store::set_cookie_str`：多段串一次锁内更新 + 至多一次持久化
    // upsert（逐段 `set_cookie` 则每段一次锁 + 一次 upsert——高频写放大）。
    mount_dual(
        java,
        globals,
        "setCookie",
        rquickjs::Function::new(ctx.clone(), |url: String, cookie_str: String| -> bool {
            cookie_store::set_cookie_str(&url, &cookie_str);
            true
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // clearCookies(url) -> bool（清该 URL 归一域名键 + 原始串键的全部 cookie）
    mount_dual(
        java,
        globals,
        "clearCookies",
        rquickjs::Function::new(ctx.clone(), |url: String| -> bool {
            cookie_store::clear_cookies(&url);
            true
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // removeCookie(url) -> String（对齐原版 CookieStore.removeCookie(url)
    // 返回 Unit → Rhino null → evalJS 兜底空串；若返回 bool true 会被
    // @js: URL 模板 {{url=source.getKey();cookie.removeCookie(url)}} 内联
    // 成 /true/search/ → 404（企鹅小说实测）。删除该域全部 cookie。
    // — 2026-08-17
    mount_dual(
        java,
        globals,
        "removeCookie",
        rquickjs::Function::new(ctx.clone(), |url: String| -> String {
            cookie_store::clear_cookies(&url);
            String::new()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // replaceCookie(url, cookieStr) -> String
    // 对齐上游 `CookieStore.replaceCookie`（CookieManagerInterface）：现存域
    // cookie ∪ 新串按键合并（新值覆盖、旧键保留）后写回；空参 no-op。
    // 返回空串（上游返回 Unit → Rhino null → evalJS 兜底空串；沿用
    // removeCookie 同款口径，防 URL 模板内联 true）。— 3b-3
    mount_dual(
        java,
        globals,
        "replaceCookie",
        rquickjs::Function::new(ctx.clone(), |url: String, cookie_str: String| -> String {
            cookie_store::replace_cookie_str(&url, &cookie_str);
            String::new()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // cookieToMap(cookieStr) -> String（有序键值对的 JSON 串）
    // 对齐上游 `CookieStore.cookieToMap`（`;` 拆段、首个 `=` 分界、键值
    // trim、空值段剔除、同名键覆盖）；rquickjs 闭包不便直构 JS 对象，
    // 返回 JSON 串、setup 脚本 cookie 对象包装层 JSON.parse 还原
    //（键序以手拼 JSON 保留首次出现序，不经 serde BTreeMap 重排）。— 3b-3
    mount_dual(
        java,
        globals,
        "cookieToMap",
        rquickjs::Function::new(ctx.clone(), |cookie_str: String| -> String {
            let pairs = cookie_store::cookie_str_to_map(&cookie_str);
            let body = pairs
                .iter()
                .map(|(k, v)| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(k).unwrap_or_else(|_| "\"\"".into()),
                        serde_json::to_string(v).unwrap_or_else(|_| "\"\"".into())
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{body}}}")
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // mapToCookie(mapJson) -> Option<String>
    // 对齐上游 `CookieStore.mapToCookie`：空表/不可解析 → null（上游返回
    // null），否则 `k=v` 以 `; ` 连接；入参为 JS 侧 JSON.stringify 后的
    // 对象串。— 3b-3
    mount_dual(
        java,
        globals,
        "mapToCookie",
        rquickjs::Function::new(ctx.clone(), |map_json: String| -> Option<String> {
            let value: serde_json::Value = serde_json::from_str(&map_json).ok()?;
            let obj = value.as_object()?;
            let pairs: Vec<(String, String)> = obj
                .iter()
                .map(|(k, v)| {
                    let v = match v {
                        serde_json::Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    (k.clone(), v)
                })
                .collect();
            cookie_store::map_to_cookie_str(&pairs)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册加密 API
///
/// 对应 Kotlin 端 `JsEncodeUtils` + `JsExtensions` 中的 AES/DES/RC4 加解密方法。
fn register_crypto_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // aesDecryptBytes(data, key, iv?, transformation?) -> Uint8Array
    // 字节级 AES 解密（Rhino `Packages.javax.crypto.Cipher.doFinal` 模拟层依赖；
    // 七猫四合一等书源 jsLib 用 Packages 解密章节/榜单 AES-CBC 密文，
    // key/iv/data 均为字节数组，与字符串级 aesDecrypt 不同）
    mount_dual(
        java,
        globals,
        "aesDecryptBytes",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             data: rquickjs::TypedArray<u8>,
             key: rquickjs::TypedArray<u8>,
             iv: Opt<rquickjs::TypedArray<u8>>,
             transformation: Opt<String>|
             -> rquickjs::Result<rquickjs::Value<'js>> {
                use rquickjs::IntoJs;
                let t = transformation
                    .0
                    .unwrap_or_else(|| "AES/CBC/PKCS5Padding".to_string());
                let key_b: Vec<u8> = key.as_bytes().unwrap_or(&[]).to_vec();
                let data_b: Vec<u8> = data.as_bytes().unwrap_or(&[]).to_vec();
                let iv_b: Option<Vec<u8>> = iv.0.map(|a| a.as_bytes().unwrap_or(&[]).to_vec());
                let plain =
                    legado_core::crypto::symmetric_decrypt(&t, &key_b, iv_b.as_deref(), &data_b)
                        .map_err(|e| rquickjs::Error::FromJs {
                            from: "Uint8Array",
                            to: "Uint8Array",
                            message: Some(e.to_string()),
                        })?;
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), plain)?;
                arr.into_js(&ctx)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // aesEncrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "aesEncrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::aes_encrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // aesDecrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "aesDecrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::aes_decrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // desEncrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "desEncrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::des_encrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // desDecrypt(data, key, iv?) -> String
    mount_dual(
        java,
        globals,
        "desDecrypt",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, iv: Opt<String>| -> String {
                crypto_api::des_decrypt(&data, &key, iv.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // rc4Encrypt(data, key) -> String
    mount_dual(
        java,
        globals,
        "rc4Encrypt",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            crypto_api::rc4_encrypt(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // rc4Decrypt(data, key) -> String
    mount_dual(
        java,
        globals,
        "rc4Decrypt",
        rquickjs::Function::new(ctx.clone(), |data: String, key: String| -> String {
            crypto_api::rc4_decrypt(&data, &key).unwrap_or_else(|e| format!("[ERROR] {}", e))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // createSymmetricCrypto(transformation, key, iv?) -> SymmetricCrypto 对象
    // 对齐 Kotlin JsEncodeUtils.createSymmetricCrypto（hutool SymmetricCrypto）
    // 返回对象含 decrypt/decryptStr/encrypt/encryptBase64/encryptHex/setIv
    // 漫画 imageDecode：cipher.decrypt(Uint8Array) → Uint8Array — Reasonix
    mount_dual(
        java,
        globals,
        "createSymmetricCrypto",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             transformation: String,
             key: rquickjs::Value<'js>,
             iv: Opt<rquickjs::Value<'js>>|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                let (key_bytes, iv_bytes) = symmetric_crypto::parse_key_iv_args(key, iv)?;
                symmetric_crypto::build_symmetric_crypto_object(
                    ctx,
                    &transformation,
                    &key_bytes,
                    iv_bytes.as_deref(),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // tripleDESEncodeBase64Str(data, key, mode, padding, iv) -> String
    // 对齐 JsEncodeUtils.tripleDESEncodeBase64Str（#135 阅文 QDSign 加密）：
    // createSymmetricCrypto("DESede/{mode}/{padding}", key, iv).encryptBase64(data)
    mount_dual(
        java,
        globals,
        "tripleDESEncodeBase64Str",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, mode: String, padding: String, iv: String| -> String {
                crypto_api::triple_des_encode_base64_str(&data, &key, &mode, &padding, &iv)
                    .unwrap_or_else(|e| format!("[ERROR] {e}"))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // aesBase64DecodeToString(str, key, transformation, iv) — 全网漫画等目录/正文 AES
    // 对齐 JsEncodeUtils.aesBase64DecodeToString（deprecated 但仍被大量书源使用）
    mount_dual(
        java,
        globals,
        "aesBase64DecodeToString",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, transformation: String, iv: String| -> String {
                symmetric_crypto::aes_base64_decode_to_string(&data, &key, &transformation, &iv)
                    .unwrap_or_else(|e| format!("[ERROR] {e}"))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // aesDecodeToString(str, key, transformation, iv) — 同语义别名
    mount_dual(
        java,
        globals,
        "aesDecodeToString",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, key: String, transformation: String, iv: String| -> String {
                // 非 Base64 原始密文场景较少；与 aesBase64 共用入口时先试 Base64
                symmetric_crypto::aes_base64_decode_to_string(&data, &key, &transformation, &iv)
                    .unwrap_or_else(|e| format!("[ERROR] {e}"))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // createAsymmetricCrypto(transformation) -> RSA 对象
    // 对应 Kotlin JsEncodeUtils.createAsymmetricCrypto（AsymmetricCrypto）
    // 返回对象含 setPublicKey/setPrivateKey/encrypt/encryptHex/encryptBase64/decrypt/decryptStr
    mount_dual(
        java,
        globals,
        "createAsymmetricCrypto",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             transformation: String|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                asymmetric_crypto::build_asymmetric_crypto_object(ctx, &transformation)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // createSign(algorithm) -> 签名对象
    // 对应 Kotlin JsEncodeUtils.createSign（Sign / hutool Sign）
    // 返回对象含 setPublicKey/setPrivateKey/sign/signHex/signBase64/verify
    mount_dual(
        java,
        globals,
        "createSign",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             algorithm: String|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                asymmetric_crypto::build_sign_object(ctx, &algorithm)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 `java.security.MessageDigest` 摘要 API
///
/// QuickJS 无 JVM，`java.security.MessageDigest` 经纯 Rust（md-5/sha1/sha2）模拟：
/// - `messageDigestValidate(algo) -> bool` — 算法是否受支持（供 Packages shim 的
///   `getInstance` 前置校验；未知算法由 shim 抛「当前不支持」文案并登记台账）
/// - `messageDigestDigest(algo, bytes) -> Uint8Array` — 一次性摘要，字节数组输出
///   （Java `digest(byte[])` 语义，非 hex/base64 字符串）；增量 `update()` 由
///   shim 侧 `JSMMessageDigestInstance` 累积字节、`digest()` 收尾时一次性传入
///   本宿主函数（与 Java 增量语义等价）。
///
/// 支持 MD5/SHA-1/SHA-256/SHA-512（语料 3 命中实际用法，见 message_digest 模块）；
/// 未知算法在本函数返回 Err、shim 侧转可读文案 + 台账，不静默产出空摘要。
#[cfg(feature = "quickjs")]
fn register_message_digest_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // messageDigestValidate(algo) -> bool
    mount_dual(
        java,
        globals,
        "messageDigestValidate",
        rquickjs::Function::new(ctx.clone(), |algo: String| -> bool {
            message_digest::is_supported_algorithm(&algo)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // messageDigestDigest(algo, bytes) -> Uint8Array（字节数组，非 hex 串）
    mount_dual(
        java,
        globals,
        "messageDigestDigest",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             algo: String,
             data: rquickjs::TypedArray<u8>|
             -> rquickjs::Result<rquickjs::Value<'js>> {
                use rquickjs::IntoJs;
                let data_b: Vec<u8> = data.as_bytes().unwrap_or(&[]).to_vec();
                let out = message_digest::digest_bytes(&algo, &data_b).map_err(|e| {
                    rquickjs::Error::FromJs {
                        from: "MessageDigest",
                        to: "Uint8Array",
                        message: Some(e),
                    }
                })?;
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), out)?;
                arr.into_js(&ctx)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 HTML 格式化 API
///
/// 对应 Kotlin 端 `HtmlFormatter` 中的格式化方法。
fn register_html_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // htmlFormat(html) -> String
    mount_dual(
        java,
        globals,
        "htmlFormat",
        rquickjs::Function::new(ctx.clone(), |html: String| -> String {
            html_format::html_format(&html)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // htmlFormatWithTags(html, keepTags?) -> String
    mount_dual(
        java,
        globals,
        "htmlFormatWithTags",
        rquickjs::Function::new(
            ctx.clone(),
            |html: String, keep_tags: Opt<String>| -> String {
                html_format::html_format_with_tags(&html, keep_tags.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册 HTML 解析桥 API（java.getElement/getString 等）
///
/// 对齐原版 AnalyzeRule.evalJS 注入 `bindings["java"] = this`：
/// 漫画/图片书源目录/正文规则依赖 CSS 元素选择（51漫画等）。
/// 仅挂到 `java` 命名空间（getElement 等为 AnalyzeRule 方法语义，
/// 裸全局无此方法，避免污染书源自定义函数名）— Reasonix
fn register_html_parse_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    _globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // java.getElement(css) -> 元素数组（对当前 src 解析）
    java.set(
        "getElement",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, css: String| -> rquickjs::Result<rquickjs::Array<'js>> {
                let src = ctx.globals().get::<_, String>("src").unwrap_or_default();
                html_parse::get_element(&ctx, css, src).map_err(|e| rquickjs::Error::FromJs {
                    from: "String",
                    to: "Array<Element>",
                    message: Some(e.to_string()),
                })
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.getElements(css) -> 元素数组
    java.set(
        "getElements",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, css: String| -> rquickjs::Result<rquickjs::Array<'js>> {
                let src = ctx.globals().get::<_, String>("src").unwrap_or_default();
                html_parse::get_elements(&ctx, css, src).map_err(|e| rquickjs::Error::FromJs {
                    from: "String",
                    to: "Array<Element>",
                    message: Some(e.to_string()),
                })
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.getString(rule, mContent?) -> 首条文本
    // P2-6(e)：rule 按规则类型分派（CSS/JSONPath/XPath/Regex/@js:/@webjs:/@@），
    // 对齐上游 AnalyzeRule.getString 语义；HTML 内容 + CSS 规则行为保持不变。
    java.set(
        "getString",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, css: String, m_content: Opt<String>| -> String {
                let src = ctx.globals().get::<_, String>("src").unwrap_or_default();
                html_parse::get_string(&ctx, css, m_content, src)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.getStrings(rule, mContent?) -> 文本列表（换行连接）
    java.set(
        "getStrings",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, css: String, m_content: Opt<String>| -> String {
                let src = ctx.globals().get::<_, String>("src").unwrap_or_default();
                html_parse::get_strings(&ctx, css, m_content, src)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.getStringList(rule, mContent?) -> 数组或 null（多值列表，不连接）
    // P2-9 ①（P2-11 ④ §196 对齐 null 语义）：语料 `java.getStringList`（15/5），
    // 上游 AnalyzeRule.kt:202-293 getStringList：
    // - L203 空规则 → null；L275 JS 求值错误 / null|undefined 结果 → null；
    //   L292 JS 数字/布尔/对象（非 List）结果 → null（宿主面返回 JS null，
    //   显式 new_null——rquickjs 的 Option 转换会给 undefined，与 Kotlin null 不符）
    // - L276-278 JS 字符串结果按 "\n" 拆分（保留尾部空段，"" → [""]）
    // - JS 原生数组 / JSON 数组字符串：P2-6(e) 展开（元素逐个保留）
    // - CSS/JSONPath/XPath/Regex：List 结果，零命中 → 空数组（非 null）
    // 数组附加 size() / get(i) / isEmpty()（Java List 面别名，兼容语料
    // `list.size()` / `list.get(i)` / `list.isEmpty()` 用法；get(i) 越界
    // （含负数）抛错，对齐 JDK List.get → IndexOutOfBoundsException）。
    java.set(
        "getStringList",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             rule: String,
             m_content: Opt<String>|
             -> rquickjs::Result<rquickjs::Value<'js>> {
                let src = ctx.globals().get::<_, String>("src").unwrap_or_default();
                let items = html_parse::get_string_list(&ctx, rule, m_content, src);
                match items {
                    None => Ok(rquickjs::Value::new_null(ctx)),
                    Some(items) => {
                        let arr = rquickjs::Array::new(ctx.clone())?;
                        for (i, item) in items.iter().enumerate() {
                            arr.set(i, item.clone())?;
                        }
                        // 兼容语料 `list.size()`（Java List.size() 语义）；
                        // This 接收 this 绑定（arr.size() 零位置参数调用）
                        let size_fn = rquickjs::Function::new(
                            ctx.clone(),
                            |this: rquickjs::prelude::This<rquickjs::Array>| -> u32 {
                                this.0.len() as u32
                            },
                        )
                        .map_err(|e| rquickjs::Error::FromJs {
                            from: "Array",
                            to: "Function",
                            message: Some(e.to_string()),
                        })?;
                        arr.clone().into_object().set("size", size_fn)?;
                        // `list.get(i)`——Java List.get(i) 别名：越界（含负数）
                        // 抛错（JDK List.get → IndexOutOfBoundsException）
                        let get_fn = rquickjs::Function::new(
                            ctx.clone(),
                            |this: rquickjs::prelude::This<rquickjs::Array>,
                             i: i64|
                             -> rquickjs::Result<String> {
                                let len = this.0.len();
                                if i < 0 || (i as usize) >= len {
                                    return Err(rquickjs::Error::FromJs {
                                        from: "IndexOutOfBoundsException",
                                        to: "List.get",
                                        message: Some(format!(
                                            "Index {i} out of bounds for length {len}"
                                        )),
                                    });
                                }
                                this.0.get(i as usize)
                            },
                        )
                        .map_err(|e| rquickjs::Error::FromJs {
                            from: "Array",
                            to: "Function",
                            message: Some(e.to_string()),
                        })?;
                        arr.clone().into_object().set("get", get_fn)?;
                        // `list.isEmpty()`——Java List.isEmpty() 别名
                        let is_empty_fn = rquickjs::Function::new(
                            ctx.clone(),
                            |this: rquickjs::prelude::This<rquickjs::Array>| -> bool {
                                this.0.is_empty()
                            },
                        )
                        .map_err(|e| rquickjs::Error::FromJs {
                            from: "Array",
                            to: "Function",
                            message: Some(e.to_string()),
                        })?;
                        arr.clone().into_object().set("isEmpty", is_empty_fn)?;
                        // Array → Value（rquickjs `From<Array> for Value`，
                        // 链式 Array->Object->Value 的 into_value）
                        Ok(arr.into())
                    }
                }
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.setContent(content, baseUrl?) — P2-9 ①：语料 `java.setContent`
    // （13/7，形态：单参为主，含 setContent(m, baseUrl) 双参 2 例），上游
    // AnalyzeRule.kt:101：setContent 更新分析器当前内容（mContent）。
    // 本宿主分析器当前内容 = 全局变量 `src`（getElement/getString 等
    // 规则链读取），故写入 globals.src；双参形式同时更新 `baseUrl`
    // （上游无 baseUrl 参数，属兼容超集，已文档化）。
    // 注意：不改动 `result`——上游 setContent 只动 mContent，`result`
    // 是上一条规则的结果，语料中存在 `java.setContent(src)` 之后仍读
    // 原 result 拼接的用法，覆盖 result 会破坏既有语义。
    java.set(
        "setContent",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             content: String,
             base_url: Opt<String>|
             -> rquickjs::Result<()> {
                ctx.globals().set("src", content)?;
                if let Some(b) = base_url.0 {
                    ctx.globals().set("baseUrl", b)?;
                }
                Ok(())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupAttr(html, css, attr) — org.jsoup.Jsoup 模拟层底层
    java.set(
        "jsoupAttr",
        rquickjs::Function::new(
            ctx.clone(),
            |html: String, css: String, attr: String| -> String {
                html_parse::jsoup_attr(&html, &css, &attr)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    java.set(
        "jsoupText",
        rquickjs::Function::new(ctx.clone(), |html: String, css: String| -> String {
            html_parse::jsoup_text(&html, &css)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    java.set(
        "jsoupHtml",
        rquickjs::Function::new(ctx.clone(), |html: String, css: String| -> String {
            html_parse::jsoup_html(&html, &css)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupSize(html, css) — org.jsoup.select.Elements 集合计数
    // （JSOUP_BRIDGE_JS Elements 模拟层集合 API 底层；77读书搜索规则
    // `rows.size()` 此前因缺失抛 `not a function`）
    java.set(
        "jsoupSize",
        rquickjs::Function::new(ctx.clone(), |html: String, css: String| -> u32 {
            html_parse::jsoup_size(&html, &css)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupAttrN(html, css, i, attr) — 第 i 个匹配元素属性
    // （shim `rows.get(i).attr(name)`；i 为 i64，负数按 0、越界空串）
    java.set(
        "jsoupAttrN",
        rquickjs::Function::new(
            ctx.clone(),
            |html: String, css: String, i: i64, attr: String| -> String {
                html_parse::jsoup_attr_n(&html, &css, i, &attr)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupTextN(html, css, i) — 第 i 个匹配元素文本
    java.set(
        "jsoupTextN",
        rquickjs::Function::new(ctx.clone(), |html: String, css: String, i: i64| -> String {
            html_parse::jsoup_text_n(&html, &css, i)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupHtmlN(html, css, i) — 第 i 个匹配元素 innerHTML
    java.set(
        "jsoupHtmlN",
        rquickjs::Function::new(ctx.clone(), |html: String, css: String, i: i64| -> String {
            html_parse::jsoup_html_n(&html, &css, i)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupHtmlNExcluded(html, css, i, excludes) — 第 i 个元素 innerHTML
    // 并移除子元素（换行分隔选择器列表；shim `Element.remove()`，
    // 77读书正文规则 `tp.get(0).remove()` 后 `e.html()` 的移除视图）
    java.set(
        "jsoupHtmlNExcluded",
        rquickjs::Function::new(
            ctx.clone(),
            |html: String, css: String, i: i64, excludes: String| -> String {
                html_parse::jsoup_html_n_excluded(&html, &css, i, &excludes)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // java.jsoupUnescapeEntities(s) — HTML 实体反转义
    // （shim `Packages.org.jsoup.parser.Parser.unescapeEntities`，
    // 77读书正文规则 `Parser.unescapeEntities(htm, true)`）
    java.set(
        "jsoupUnescapeEntities",
        rquickjs::Function::new(ctx.clone(), |s: String| -> String {
            html_parse::jsoup_unescape_entities(&s)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    Ok(())
}

/// 注册全局 `cache` 对象（P2-9 ① 记忆缓存三件套 + 磁盘缓存）
///
/// 对齐上游 WebCacheManager（help/WebCacheManager.kt:171-206）JS 面：
/// put / putMemory / getFromMemory / deleteMemory / get(onlyDisk) /
/// putFile / getFile / delete。后端为 `cache_store` 模块的进程级
/// LRU 内存 + 磁盘文件，语义对齐 CacheManager.kt:60-98：
/// - saveTime <= 0 → 仅内存（putMemory），永久有效
/// - saveTime > 0  → 磁盘条目 + 截止时间，读取时过期即删
/// - putFile/getFile：磁盘裸文件，无过期
///
/// 值统一字符串化后存储（上游 WebCacheManager 存 String；对象值
/// 走 JSON.stringify 为兼容超集）；缺失键返回显式 **null**
/// （对齐 Kotlin 的 null 返回，而非 undefined）。
#[cfg(feature = "quickjs")]
fn register_cache_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    let cache =
        rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // put(key, value, saveTime?) -> bool
    // saveTime<=0 语义对齐 CacheManager.kt:60-98：仅内存、无过期
    cache
        .set(
            "put",
            rquickjs::Function::new(
                ctx.clone(),
                |ctx: rquickjs::Ctx<'js>,
                 key: String,
                 value: rquickjs::Value<'js>,
                 save_time: Opt<i64>|
                 -> bool {
                    let v = stringify_cache_value(&ctx, &value);
                    cache_store::put(&key, &v, save_time.0.unwrap_or(0))
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // putMemory(key, value)
    cache
        .set(
            "putMemory",
            rquickjs::Function::new(
                ctx.clone(),
                |ctx: rquickjs::Ctx<'js>, key: String, value: rquickjs::Value<'js>| -> () {
                    cache_store::put_memory(&key, &stringify_cache_value(&ctx, &value));
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // getFromMemory(key) -> String | null
    cache
        .set(
            "getFromMemory",
            rquickjs::Function::new(
                ctx.clone(),
                |ctx: rquickjs::Ctx<'js>, key: String| -> rquickjs::Result<rquickjs::Value<'js>> {
                    cache_value_or_null(&ctx, cache_store::get_from_memory(&key))
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // deleteMemory(key)
    cache
        .set(
            "deleteMemory",
            rquickjs::Function::new(ctx.clone(), |_ctx: rquickjs::Ctx<'js>, key: String| -> () {
                cache_store::delete_memory(&key);
            })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // ─── 书源 setup 脚本内存缓存桥（cap 2：cookie/cache 全局桥面补齐）──────
    // 书源 setup 脚本（source_js_bindings::book_source_js_setup_script）以
    // `var cache = {...}` 遮蔽本全局 cache 对象，其 putMemory/getFromMemory/
    // deleteMemory 经下列 java.* 宿主桥落 cache_store 内存层（与 setup 的
    // get/put/remove → 会话变量层、磁盘 cache 表互不串键，对齐上游
    // CacheManager memoryLruCache 的独立命名空间）。
    mount_dual(
        java,
        globals,
        "cachePutMemory",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, key: String, value: rquickjs::Value<'js>| -> () {
                cache_store::put_memory(&key, &stringify_cache_value(&ctx, &value));
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // 缺失键返回显式 null（setup 侧判缺式 `v === undefined || v === null`）
    mount_dual(
        java,
        globals,
        "cacheGetFromMemory",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>, key: String| -> rquickjs::Result<rquickjs::Value<'js>> {
                cache_value_or_null(&ctx, cache_store::get_from_memory(&key))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    mount_dual(
        java,
        globals,
        "cacheDeleteMemory",
        rquickjs::Function::new(ctx.clone(), |key: String| -> () {
            cache_store::delete_memory(&key);
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // get(key, onlyDisk?) -> String | null
    cache
        .set(
            "get",
            rquickjs::Function::new(
                ctx.clone(),
                |ctx: rquickjs::Ctx<'js>,
                 key: String,
                 only_disk: Opt<bool>|
                 -> rquickjs::Result<rquickjs::Value<'js>> {
                    cache_value_or_null(&ctx, cache_store::get(&key, only_disk.0.unwrap_or(false)))
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // putFile(key, value) -> bool（磁盘裸文件，无过期）
    cache
        .set(
            "putFile",
            rquickjs::Function::new(
                ctx.clone(),
                |ctx: rquickjs::Ctx<'js>, key: String, value: rquickjs::Value<'js>| -> bool {
                    cache_store::put_file(&key, &stringify_cache_value(&ctx, &value))
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // getFile(key) -> String | null
    cache
        .set(
            "getFile",
            rquickjs::Function::new(
                ctx.clone(),
                |ctx: rquickjs::Ctx<'js>, key: String| -> rquickjs::Result<rquickjs::Value<'js>> {
                    cache_value_or_null(&ctx, cache_store::get_file(&key))
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // delete(key)（磁盘条目 + 文件缓存 + 内存）
    cache
        .set(
            "delete",
            rquickjs::Function::new(ctx.clone(), |_ctx: rquickjs::Ctx<'js>, key: String| -> () {
                cache_store::delete(&key);
            })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    globals
        .set("cache", cache)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    Ok(())
}

/// 缓存缺失键 → 显式 null（rquickjs 的 `Option` IntoJs 会把 None
/// 转成 undefined，与 Kotlin null 语义不符，故显式构造）
#[cfg(feature = "quickjs")]
fn cache_value_or_null<'js>(
    ctx: &rquickjs::Ctx<'js>,
    v: Option<String>,
) -> rquickjs::Result<rquickjs::Value<'js>> {
    use rquickjs::IntoJs;
    match v {
        Some(s) => s.into_js(ctx),
        None => Ok(rquickjs::Value::new_null(ctx.clone())),
    }
}

/// 缓存值字符串化：字符串原样、数字/布尔转字面量、对象走
/// JSON.stringify（对齐 engine.rs 的 CStr → String 容错写法）
#[cfg(feature = "quickjs")]
fn stringify_cache_value<'js>(ctx: &rquickjs::Ctx<'js>, v: &rquickjs::Value<'js>) -> String {
    if v.is_string() {
        return v
            .as_string()
            .map(|s| s.to_string().unwrap_or_default())
            .unwrap_or_default();
    }
    if v.is_bool() {
        return match v.as_bool() {
            Some(true) => "true".to_string(),
            _ => "false".to_string(),
        };
    }
    if let Some(n) = v.as_int() {
        return n.to_string();
    }
    if let Some(f) = v.as_float() {
        return f.to_string();
    }
    if v.is_null() || v.is_undefined() {
        return String::new();
    }
    match ctx.json_stringify(v.clone()) {
        Ok(Some(js)) => js.to_string().unwrap_or_else(|_| {
            js.to_cstring()
                .map(|c| c.as_str().to_string())
                .unwrap_or_default()
        }),
        _ => String::new(),
    }
}

/// 注册中文工具 API
///
/// 对应 Kotlin 端 `ChineseUtils` 中的繁简转换方法。
fn register_chinese_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // t2s(text) -> String
    mount_dual(
        java,
        globals,
        "t2s",
        rquickjs::Function::new(ctx.clone(), |text: String| -> String {
            chinese_utils::t2s(&text)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // s2t(text) -> String
    mount_dual(
        java,
        globals,
        "s2t",
        rquickjs::Function::new(ctx.clone(), |text: String| -> String {
            chinese_utils::s2t(&text)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册配置读取 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 getReadBookConfig / getThemeConfig / getThemeMode /
/// getWebViewUA / androidId 等方法。
fn register_config_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // getReadBookConfig() -> String
    mount_dual(
        java,
        globals,
        "getReadBookConfig",
        rquickjs::Function::new(ctx.clone(), || -> String {
            config_api::get_read_book_config()
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getThemeConfig() -> String
    mount_dual(
        java,
        globals,
        "getThemeConfig",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_theme_config() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getReadBookConfigMap() -> Object（对齐 JsExtensions.getReadBookConfigMap）
    mount_dual(
        java,
        globals,
        "getReadBookConfigMap",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>| -> rquickjs::Result<rquickjs::Object<'js>> {
                json_string_to_object(&ctx, &config_api::get_read_book_config())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getThemeConfigMap() -> Object（对齐 JsExtensions.getThemeConfigMap）
    mount_dual(
        java,
        globals,
        "getThemeConfigMap",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>| -> rquickjs::Result<rquickjs::Object<'js>> {
                json_string_to_object(&ctx, &config_api::get_theme_config())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getThemeMode() -> String
    mount_dual(
        java,
        globals,
        "getThemeMode",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_theme_mode() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getWebViewUA() -> String
    mount_dual(
        java,
        globals,
        "getWebViewUA",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_web_view_ua() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // androidId() -> String
    mount_dual(
        java,
        globals,
        "androidId",
        rquickjs::Function::new(ctx.clone(), || -> String { config_api::get_android_id() })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册并发控制 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 singleFlight / lock / tick 方法。
fn register_concurrency_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // singleFlight(key, waitMs, fJs) -> String
    mount_dual(
        java,
        globals,
        "singleFlight",
        rquickjs::Function::new(
            ctx.clone(),
            |key: String, wait_ms: i64, f_js: String| -> String {
                concurrency_api::single_flight(key, wait_ms, f_js)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // lock(key, waitMs) -> Boolean
    mount_dual(
        java,
        globals,
        "lock",
        rquickjs::Function::new(ctx.clone(), |key: String, wait_ms: i64| -> bool {
            concurrency_api::lock(key, wait_ms)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // tick(key) -> Int
    mount_dual(
        java,
        globals,
        "tick",
        rquickjs::Function::new(ctx.clone(), |key: String| -> i64 {
            concurrency_api::tick(key)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册杂项 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 getSource / getTag /
/// ajaxTestAll / toUrl / toast / logType 等方法，
/// 以及需要平台能力的桥接 API（webView / startBrowser / openUrl 等）。
fn register_misc_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // getSource(sourceUrl) -> String
    mount_dual(
        java,
        globals,
        "getSource",
        rquickjs::Function::new(ctx.clone(), |source_url: String| -> String {
            misc_api::get_source(&source_url)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getTag(tagName) -> String
    mount_dual(
        java,
        globals,
        "getTag",
        rquickjs::Function::new(ctx.clone(), |tag_name: String| -> String {
            misc_api::get_tag(&tag_name)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // ajaxTestAll(urls) -> String
    mount_dual(
        java,
        globals,
        "ajaxTestAll",
        rquickjs::Function::new(ctx.clone(), |urls: String| -> String {
            misc_api::ajax_test_all(&urls)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toUrl(path, query) -> String
    mount_dual(
        java,
        globals,
        "toUrl",
        rquickjs::Function::new(ctx.clone(), |path: String, query: Opt<String>| -> String {
            misc_api::to_url(&path, query.0.as_deref().unwrap_or(""))
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toast(msg) -> String
    mount_dual(
        java,
        globals,
        "toast",
        rquickjs::Function::new(ctx.clone(), |msg: String| -> String {
            misc_api::toast(&msg)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // longToast(msg) -> String
    // 对应 Kotlin: longToast(msg)（长停留 toast）；
    // 与现有 toast 处理保持一致：stderr 日志输出 + 原样返回
    mount_dual(
        java,
        globals,
        "longToast",
        rquickjs::Function::new(ctx.clone(), |msg: String| -> String {
            misc_api::long_toast(&msg)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // toURL(urlStr, baseUrl?) -> Object（JsURL）
    // 对应 Kotlin: toURL(urlStr, baseUrl?) -> JsURL（host/origin/pathname/searchParams）
    mount_dual(
        java,
        globals,
        "toURL",
        rquickjs::Function::new(
            ctx.clone(),
            |ctx: rquickjs::Ctx<'js>,
             url_str: String,
             base_url: Opt<String>|
             -> rquickjs::Result<rquickjs::Object<'js>> {
                let parts = misc_api::parse_js_url(&url_str, base_url.0.as_deref().unwrap_or(""))
                    .map_err(|e| rquickjs::Error::FromJs {
                    from: "String",
                    to: "Object<JsURL>",
                    message: Some(e),
                })?;
                let obj = rquickjs::Object::new(ctx.clone())?;
                obj.set("host", parts.host)?;
                obj.set("origin", parts.origin)?;
                obj.set("pathname", parts.pathname)?;
                match parts.search_params {
                    Some(params) => {
                        let map = rquickjs::Object::new(ctx.clone())?;
                        for (k, v) in params {
                            map.set(k, v)?;
                        }
                        obj.set("searchParams", map)?;
                    }
                    None => {
                        // 对齐 Kotlin JsURL：无 query 时 searchParams 为 null
                        obj.set("searchParams", rquickjs::Null)?;
                    }
                }
                Ok(obj)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // logType(value) -> String
    mount_dual(
        java,
        globals,
        "logType",
        rquickjs::Function::new(ctx.clone(), |value: String| -> String {
            misc_api::log_type(&value)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // openVideoPlayer(url, title?, isFloat?) -> String
    // 对齐 Kotlin JsExtensions.openVideoPlayer：返回结构化桥接载荷，
    // 由 Flutter / 平台侧拦截并拉起内置视频播放器。
    mount_dual(
        java,
        globals,
        "openVideoPlayer",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, title: Opt<String>, is_float: Opt<bool>| -> String {
                platform::open_video_player(
                    &url,
                    title.0.as_deref().unwrap_or(""),
                    is_float.0.unwrap_or(false),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // webView(html?, url?, js?, cacheFirst?) -> String
    // 对应 Kotlin: webView(html: String?, url: String?, js: String?, cacheFirst: Boolean)
    // [可空入参修复 | 2026-09-26] rquickjs `Opt<T>` 只认 undefined、不认显式
    // null——语料听笔趣阁/棉花糖/17k 调 `java.webView(null, url, null)`（上游
    // Kotlin String? 可空参合法）报「Error converting from js 'null' into
    // type 'string'」。改用 NullStr/NullBool 入参（null/undefined → None），
    // 配 JS 垫片恒定 4 参调用（undefined 补 null），见 RESPONSE_BRIDGE_JS。
    mount_dual(
        java,
        globals,
        "webView",
        rquickjs::Function::new(
            ctx.clone(),
            |html: NullStr, url: NullStr, js: NullStr, cache_first: NullBool| -> String {
                platform::web_view_ex(
                    html.0.as_deref().unwrap_or(""),
                    url.0.as_deref().unwrap_or(""),
                    js.0.as_deref().unwrap_or(""),
                    cache_first.0.unwrap_or(false),
                    0,
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // webViewGetSource(html?, url?, js?, sourceRegex?, cacheFirst?, delayTime?)
    mount_dual(
        java,
        globals,
        "webViewGetSource",
        rquickjs::Function::new(
            ctx.clone(),
            |html: Opt<String>,
             url: Opt<String>,
             js: Opt<String>,
             source_regex: Opt<String>,
             cache_first: Opt<bool>,
             delay_time: Opt<i64>|
             -> String {
                platform::web_view_get_source_ex(
                    html.0.as_deref().unwrap_or(""),
                    url.0.as_deref().unwrap_or(""),
                    js.0.as_deref().unwrap_or(""),
                    source_regex.0.as_deref().unwrap_or(""),
                    cache_first.0.unwrap_or(false),
                    delay_time.0.unwrap_or(0),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // webViewGetOverrideUrl(html?, url?, js?, overrideUrlRegex, cacheFirst?, delayTime?)
    // -> String（桥接载荷）
    // 对应 Kotlin: webViewGetOverrideUrl(html, url, js, overrideUrlRegex, cacheFirst, delayTime)
    // Rust 无头运行时返回桥接载荷，由 Flutter 侧用真实 WebView 拦截跳转 URL
    mount_dual(
        java,
        globals,
        "webViewGetOverrideUrl",
        rquickjs::Function::new(
            ctx.clone(),
            |html: Opt<String>,
             url: Opt<String>,
             js: Opt<String>,
             override_url_regex: String,
             cache_first: Opt<bool>,
             delay_time: Opt<i64>|
             -> String {
                platform::web_view_get_override_url(
                    html.0.as_deref().unwrap_or(""),
                    url.0.as_deref().unwrap_or(""),
                    js.0.as_deref().unwrap_or(""),
                    &override_url_regex,
                    cache_first.0.unwrap_or(false),
                    delay_time.0.unwrap_or(0),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // showBrowser(url, html?, preloadJs?, config?) -> String（桥接载荷）
    // 对应 Kotlin: showBrowser(url, html, preloadJs, config)（应用内 WebView 对话框）；
    // Rust 无头运行时返回 {"action":"openBrowser",...}，由 Flutter 侧拦截并打开浏览器
    mount_dual(
        java,
        globals,
        "showBrowser",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String,
             html: Opt<String>,
             preload_js: Opt<String>,
             config: Opt<String>|
             -> String {
                platform::show_browser(
                    &url,
                    html.0.as_deref().unwrap_or(""),
                    preload_js.0.as_deref().unwrap_or(""),
                    config.0.as_deref().unwrap_or(""),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // SourceLoginJsExtensions 中途 UI（callBackBtn 会话经 ui_action_queue 回放）
    mount_dual(
        java,
        globals,
        "refreshBookInfo",
        rquickjs::Function::new(ctx.clone(), || {
            crate::host_api::ui_action_queue::source_login_ext::refresh_book_info();
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;
    mount_dual(
        java,
        globals,
        "refreshBookToc",
        rquickjs::Function::new(ctx.clone(), || {
            crate::host_api::ui_action_queue::source_login_ext::refresh_book_toc();
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;
    mount_dual(
        java,
        globals,
        "refreshContent",
        rquickjs::Function::new(ctx.clone(), || {
            crate::host_api::ui_action_queue::source_login_ext::refresh_content();
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;
    mount_dual(
        java,
        globals,
        "copyText",
        rquickjs::Function::new(ctx.clone(), |text: String| {
            crate::host_api::ui_action_queue::source_login_ext::copy_text(&text);
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;
    mount_dual(
        java,
        globals,
        "clearTtsCache",
        rquickjs::Function::new(ctx.clone(), || {
            crate::host_api::ui_action_queue::source_login_ext::clear_tts_cache();
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;
    mount_dual(
        java,
        globals,
        "refreshExplore",
        rquickjs::Function::new(ctx.clone(), || {
            crate::host_api::ui_action_queue::source_login_ext::refresh_explore();
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;
    mount_dual(
        java,
        globals,
        "reLoginView",
        rquickjs::Function::new(ctx.clone(), || {
            crate::host_api::ui_action_queue::source_login_ext::refresh_explore();
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // startBrowser(url, title?, html?) -> String（桥接载荷）
    // 对应 Kotlin: startBrowser(url, title, html?)
    mount_dual(
        java,
        globals,
        "startBrowser",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, title: Opt<String>, html: Opt<String>| -> String {
                platform::start_browser(
                    &url,
                    title.0.as_deref().unwrap_or(""),
                    html.0.as_deref().unwrap_or(""),
                )
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // openUrl(url, mimeType?) -> String（桥接载荷）
    // 对应 Kotlin: openUrl(url, mimeType?)
    mount_dual(
        java,
        globals,
        "openUrl",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, mime_type: Opt<String>| -> String {
                platform::open_url(&url, mime_type.0.as_deref().unwrap_or(""))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getVerificationCode(imageUrl) -> String（验证码交互通道，阻塞等待用户输入）
    // 对应 Kotlin: getVerificationCode(imageUrl): String
    mount_dual(
        java,
        globals,
        "getVerificationCode",
        rquickjs::Function::new(ctx.clone(), |image_url: String| -> String {
            platform::get_verification_code(&image_url)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // startBrowserAwait(url, title, refetchAfterSuccess?, html?) -> String
    // 对应 Kotlin: startBrowserAwait 三个重载（useBrowser=true）；
    // 桌面端无内置浏览器，一律降级为图片验证码流程（Task #90）
    mount_dual(
        java,
        globals,
        "startBrowserAwait",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String,
             title: Opt<String>,
             _refetch_after_success: Opt<bool>,
             _html: Opt<String>|
             -> String {
                platform::start_browser_await(&url, title.0.as_deref().unwrap_or(""))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// 注册压缩解压 API
///
/// 对应 Kotlin 端 `JsExtensions` / `ArchiveUtils` 中的
/// unzipFile / getZipStringContent / un7zFile / unrarFile /
/// get7zStringContent / getRarStringContent 方法。
fn register_archive_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // unzipFile / unArchiveFile(zipPath) -> String（解压目标目录）
    // 对应 Kotlin: unzipFile → unArchiveFile；空路径返回空串
    let unarchive = rquickjs::Function::new(ctx.clone(), |zip_path: String| -> String {
        if zip_path.is_empty() {
            return String::new();
        }
        archive_utils::un_archive_file(&zip_path, None).unwrap_or_else(|e| format!("[ERROR] {}", e))
    })
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("unzipFile", unarchive.clone())
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    globals
        .set("unzipFile", unarchive.clone())
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    java.set("unArchiveFile", unarchive.clone())
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    globals
        .set("unArchiveFile", unarchive)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // getZipStringContent(url, path, charsetName?) -> String
    // 对应 Kotlin: getZipStringContent(url, path[, charsetName])；
    // url 可为本地 ZIP 路径 / 网络 URL / 十六进制字符串；失败返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "getZipStringContent",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, entry: String, charset: Opt<String>| -> String {
                get_zip_string_content_js(&url, &entry, charset.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // un7zFile(7zPath, outputPath?) -> String（解压目标目录）
    // 使用 sevenz-rust2 纯 Rust 实现解压 7z 格式
    mount_dual(
        java,
        globals,
        "un7zFile",
        rquickjs::Function::new(
            ctx.clone(),
            |seven_z_path: String, output_path: Opt<String>| -> String {
                archive_utils::un7z_file(&seven_z_path, output_path.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // unrarFile(rarPath, outputPath?) -> String
    // 纯 Rust RAR4/RAR5 解压（rar crate），失败返回 [ERROR] 前缀错误信息
    mount_dual(
        java,
        globals,
        "unrarFile",
        rquickjs::Function::new(
            ctx.clone(),
            |rar_path: String, output_path: Opt<String>| -> String {
                archive_utils::unrar_file(&rar_path, output_path.0.as_deref())
                    .unwrap_or_else(|e| format!("[ERROR] {}", e))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // get7zStringContent(url, path, charsetName?) -> String
    // 对应 Kotlin: get7zStringContent(url, path[, charsetName])；
    // url 可为本地 7z 路径 / 网络 URL / 十六进制字符串；失败返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "get7zStringContent",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, entry: String, charset: Opt<String>| -> String {
                get_7z_string_content_js(&url, &entry, charset.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // getRarStringContent(url, path, charsetName?) -> String
    // 对应 Kotlin: getRarStringContent(url, path[, charsetName])；
    // url 可为本地 RAR 路径 / 网络 URL / 十六进制字符串；失败返回空串（对齐 Kotlin）
    mount_dual(
        java,
        globals,
        "getRarStringContent",
        rquickjs::Function::new(
            ctx.clone(),
            |url: String, entry: String, charset: Opt<String>| -> String {
                get_rar_string_content_js(&url, &entry, charset.0.as_deref())
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

/// getZipStringContent 的 JS 入口实现：解析 ZIP 来源并读取指定条目的字符串内容
///
/// 对应 Kotlin `getZipByteArrayContent` + `getZipStringContent`：
/// - 绝对 URL → 经 legado-net 下载 ZIP 字节
/// - 本地存在的文件路径 → 直接读取
/// - 其余按十六进制字符串解码
///   失败时记录日志并返回空串（对齐 Kotlin `log("getZipContent 未发现内容")` + `return ""`）
fn get_zip_string_content_js(url: &str, entry: &str, charset: Option<&str>) -> String {
    let bytes = match resolve_zip_bytes(url) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[getZipStringContent] ZIP 来源解析失败: {e}");
            return String::new();
        }
    };
    match archive_utils::zip_entry_bytes(&bytes, entry) {
        Ok(b) => decode_bytes_with_charset(&b, charset),
        Err(e) => {
            eprintln!("[getZipStringContent] {e}");
            String::new()
        }
    }
}

/// 解析 getZipStringContent 的 ZIP 来源为字节数据
fn resolve_zip_bytes(source: &str) -> Result<Vec<u8>, String> {
    resolve_archive_bytes(source, "ZIP")
}

/// get7zStringContent 的 JS 入口实现：解析 7z 来源并读取指定条目的字符串内容
///
/// 对应 Kotlin `get7zByteArrayContent` + `get7zStringContent`；
/// 失败时记录日志并返回空串（对齐 Kotlin `?: return ""`）
fn get_7z_string_content_js(url: &str, entry: &str, charset: Option<&str>) -> String {
    let bytes = match resolve_archive_bytes(url, "7z") {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[get7zStringContent] 7z 来源解析失败: {e}");
            return String::new();
        }
    };
    match archive_utils::seven_z_entry_bytes(&bytes, entry) {
        Ok(b) => decode_bytes_with_charset(&b, charset),
        Err(e) => {
            eprintln!("[get7zStringContent] {e}");
            String::new()
        }
    }
}

/// getRarStringContent 的 JS 入口实现：解析 RAR 来源并读取指定条目的字符串内容
///
/// 对应 Kotlin `getRarByteArrayContent` + `getRarStringContent`；
/// 失败时记录日志并返回空串（对齐 Kotlin `?: return ""`）
fn get_rar_string_content_js(url: &str, entry: &str, charset: Option<&str>) -> String {
    let bytes = match resolve_archive_bytes(url, "RAR") {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[getRarStringContent] RAR 来源解析失败: {e}");
            return String::new();
        }
    };
    match archive_utils::rar_entry_bytes(&bytes, entry) {
        Ok(b) => decode_bytes_with_charset(&b, charset),
        Err(e) => {
            eprintln!("[getRarStringContent] {e}");
            String::new()
        }
    }
}

/// 解析压缩档案来源为字节数据（ZIP / 7z / RAR 共用）
fn resolve_archive_bytes(source: &str, kind: &str) -> Result<Vec<u8>, String> {
    // 网络 URL：经 legado-net 二进制通道下载（尽力支持；
    // legado-net 响应体当前经 String 中转，纯二进制压缩包可能受影响）
    if source.starts_with("http://") || source.starts_with("https://") {
        use crate::host_api::runtime_bridge::block_on;
        return block_on(async {
            // 进程级共享池（2026-09-24 性能专项：不再每调用新建连接池）
            let client = crate::host_api::network::shared_client_for_url(source)
                .map_err(|e| format!("网络客户端初始化失败: {e}"))?;
            client
                .get_bytes(source, None)
                .await
                .map_err(|e| format!("{kind} 下载失败: {e}"))
        });
    }
    // 本地文件路径
    let path = std::path::Path::new(source);
    if path.exists() {
        return std::fs::read(path).map_err(|e| format!("读取本地 {kind} 文件失败: {e}"));
    }
    // 十六进制字符串（对齐 Kotlin HexUtil.decodeHex 分支）
    hex::decode(source).map_err(|e| format!("十六进制 {kind} 数据解析失败: {e}"))
}

/// 按指定字符集解码 ZIP 条目字节
///
/// Kotlin 侧默认用 EncodingDetect 自动探测编码；Rust 侧未指定字符集时
/// 优先按严格 UTF-8 解码，非法则 lossy 回退；指定字符集时用 encoding_rs 解码
fn decode_bytes_with_charset(bytes: &[u8], charset: Option<&str>) -> String {
    match charset {
        Some(cs) if !cs.trim().is_empty() => {
            match encoding_rs::Encoding::for_label(cs.trim().as_bytes()) {
                Some(enc) => {
                    let (decoded, _, _) = enc.decode(bytes);
                    decoded.into_owned()
                }
                None => String::from_utf8_lossy(bytes).into_owned(),
            }
        }
        _ => String::from_utf8(bytes.to_vec())
            .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()),
    }
}

/// 注册字体 API
///
/// 对应 Kotlin 端 `JsExtensions` 中的 queryTTF / queryBase64TTF / replaceFont 方法。
fn register_font_apis<'js>(
    ctx: &rquickjs::Ctx<'js>,
    java: &rquickjs::Object<'js>,
    globals: &rquickjs::Object<'js>,
) -> Result<(), LegadoError> {
    // queryTTF(data, useCache?) -> String（字体句柄 JSON）
    // 对应 Kotlin: queryTTF(data: Any?, useCache: Boolean): QueryTTF?
    mount_dual(
        java,
        globals,
        "queryTTF",
        rquickjs::Function::new(
            ctx.clone(),
            |data: String, use_cache: Opt<bool>| -> String {
                font_api::query_ttf(&data, use_cache.0.unwrap_or(true))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // queryBase64TTF(data) -> String（已废弃，等价于 queryTTF）
    // 对应 Kotlin: @Deprecated queryBase64TTF(data): QueryTTF?
    mount_dual(
        java,
        globals,
        "queryBase64TTF",
        rquickjs::Function::new(ctx.clone(), |data: String| -> String {
            font_api::query_base64_ttf(&data)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    // replaceFont(text, errorFontData, correctFontData, filter?) -> String
    // 对应 Kotlin: replaceFont(text, errorQueryTTF, correctQueryTTF, filter): String
    mount_dual(
        java,
        globals,
        "replaceFont",
        rquickjs::Function::new(
            ctx.clone(),
            |text: String, error_font: String, correct_font: String, filter: Opt<bool>| -> String {
                font_api::replace_font(&text, &error_font, &correct_font, filter.0.unwrap_or(false))
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::engine::{JsEngine, QuickJsEngine};
    use crate::sandbox::SandboxConfig;
    use std::io::{Read, Write};

    fn make_engine() -> QuickJsEngine {
        QuickJsEngine::new(SandboxConfig::permissive()).expect("Failed to create QuickJsEngine")
    }

    #[test]
    fn test_java_namespace_md5() {
        let engine = make_engine();
        let result = engine.eval("java.md5Encode('hello')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_java_namespace_base64() {
        let engine = make_engine();
        let result = engine.eval("java.base64Encode('hello')").unwrap();
        assert_eq!(result, "aGVsbG8=");
    }

    /// [P2-9 ③] JS 侧真实闭环：真实 QuickJS 引擎执行 `java.put`（写进程级
    /// 全局变量表 `variable_store`）→ 经 FFI 注入的全局兜底读取器，
    /// `legado_parser::AnalyzeRule::get`（规则 `@get:{k}` 的底层）可见该值。
    /// 即「JS 写变量、规则读变量」链路（小米阅读/就去看网/手机小说三源
    /// 偏差的真实机制测试；端到端 FFI 对照见 web_book 手机小说测试）。
    ///
    /// P1-1/P1-2 后分两相：
    /// - **裸键相**（无 flow scope）：裸 `java.put` 挂载写裸键 + 裸读者
    ///   （P2-9 ③ 原始路径，直用引擎/无流程入口上下文）；
    /// - **scope 相**（P1-1/P1-2）：`set_flow_scope` 后 `java.__lgStorePut`
    ///   写 `lgflow::{scope}{key}`，FFI 实际注册的 `get_flow_variable`
    ///   读者（scoped 层 → 裸层）对 `AnalyzeRule::get` 可见；换 scope 只
    ///   清旧前缀、持久裸键不受影响（P1-1 验收同构）。
    ///
    /// P2-2：串行锁统一用 `variable_store::lock_variables()`（与 StoreGuard
    /// 同一把；原本测试私有的 P29_LOCK 与 StoreGuard 互不互斥，已删除）。
    #[test]
    fn test_java_put_visible_to_analyze_rule_get() {
        use std::sync::Arc;

        use crate::host_api::variable_store;
        use legado_parser::{set_global_variable_reader, AnalyzeRule};

        // 全局状态（读取器 + 全局变量表 + flow scope）与所有其他触碰方串行
        let _lock = variable_store::lock_variables();
        let _guard = variable_store::StoreGuard::new();
        struct ResetReader;
        impl Drop for ResetReader {
            fn drop(&mut self) {
                set_global_variable_reader(None);
            }
        }
        variable_store::clear_variables().expect("清全局变量表");

        // ── 相一：裸键（无 scope）──
        set_global_variable_reader(Some(Arc::new(|key: &str| -> Option<String> {
            variable_store::get_variable(key).ok().flatten()
        })));
        let _reset = ResetReader;

        // 真实 QuickJS 引擎执行真实 `java.put` 宿主方法
        let engine = make_engine();
        engine
            .eval(r#"java.put('p29_js_k', 'p29_js_v')"#)
            .expect("java.put 应执行成功");

        // AnalyzeRule::get：本地未命中 → 兜底全局读取器 → 命中
        let analyzer = AnalyzeRule::new(String::new(), String::new());
        assert_eq!(
            analyzer.get("p29_js_k"),
            "p29_js_v",
            "java.put 写入应经全局 store 桥对规则 @get 可见"
        );
        assert_eq!(
            analyzer.get("p29_never_exists"),
            "",
            "未写入的键兜底后仍应空"
        );

        // 本地非空值优先于全局 store（既有优先级不变）
        analyzer.put("p29_js_k", "local_v");
        assert_eq!(analyzer.get("p29_js_k"), "local_v");

        // ── 相二：flow scope（P1-1/P1-2 会话层）──
        variable_store::set_flow_scope("p29_scope_a").expect("设 scope A");
        set_global_variable_reader(Some(Arc::new(|key: &str| -> Option<String> {
            variable_store::get_flow_variable(key)
        })));
        // 引擎内 __lgStorePut（解析器前导 java.put 的桥目标）
        engine
            .eval(r#"java.__lgStorePut('p29_sc_k', 'p29_sc_v')"#)
            .expect("__lgStorePut 应执行成功");
        // 持久裸键（模拟 source.put 搜索期写入）
        variable_store::set_variable("v_src_k", "persistent").expect("写持久键");

        assert_eq!(
            analyzer.get("p29_sc_k"),
            "p29_sc_v",
            "scoped 会话键应经 get_flow_variable 兜底对规则 @get 可见"
        );
        // 换 scope：旧 scope 会话键清、持久裸键存活（P1-1 验收同构）
        variable_store::set_flow_scope("p29_scope_b").expect("换 scope B");
        assert_eq!(analyzer.get("p29_sc_k"), "", "换 scope 后会话键不可见");
        assert_eq!(
            analyzer.get("v_src_k"),
            "persistent",
            "换 scope 不触碰持久裸键（P1-1）"
        );
        variable_store::clear_flow_scope().expect("清 scope");
    }

    /// P2-15：`__lgBookVarGet` 读桥闭环——`__lgBookVarSet` 写入后同
    /// bookUrl 读回、跨 bookUrl 不串读、未写键返回空串。
    #[test]
    fn test_p215_book_var_get_bridge_roundtrip() {
        use crate::host_api::variable_store;
        let _lock = variable_store::lock_variables();
        let _guard = variable_store::StoreGuard::new();
        let engine = make_engine();
        let url_a = "https://p215-bridge.example.com/b/bridge-a";
        let url_b = "https://p215-bridge.example.com/b/bridge-b";
        engine
            .eval(&format!(
                r#"java.__lgBookVarSet("{url_a}", 'k', 'v-a'); 'ok'"#
            ))
            .expect("__lgBookVarSet A 应执行成功");
        assert_eq!(
            engine
                .eval(&format!(r#"java.__lgBookVarGet("{url_a}", 'k')"#))
                .unwrap(),
            "v-a",
            "同 bookUrl 读回写入值"
        );
        assert_eq!(
            engine
                .eval(&format!(r#"java.__lgBookVarGet("{url_b}", 'k')"#))
                .unwrap(),
            "",
            "跨 bookUrl 不串读"
        );
        assert_eq!(
            engine
                .eval(&format!(r#"java.__lgBookVarGet("{url_a}", 'missing')"#))
                .unwrap(),
            "",
            "未写键返回空串"
        );
        // 删除路径（putVariable(k,null) 走 __lgBookVarDel）
        engine
            .eval(&format!(r#"java.__lgBookVarDel("{url_a}", 'k'); 'ok'"#))
            .expect("__lgBookVarDel 应执行成功");
        assert_eq!(
            engine
                .eval(&format!(r#"java.__lgBookVarGet("{url_a}", 'k')"#))
                .unwrap(),
            ""
        );
    }

    /// P2-15：`__lgStoreGet`（解析器前导 `java.get` 的桥目标，底层
    /// `get_flow_variable`）在 flow scope = 本书 bookUrl 时对 bookVar 层
    /// 兜底可见——就去看网 `book.putVariable` → `java.get` 闭环的
    /// 桥层等价测试（跨规则端到端闭环见 web_book 测试）。
    #[test]
    fn test_p215_store_get_falls_back_to_bookvar_in_flow() {
        use crate::host_api::variable_store;
        let _lock = variable_store::lock_variables();
        let _guard = variable_store::StoreGuard::new();
        let engine = make_engine();
        let book_url = "https://p215-cloop.example.com/b/loop";
        variable_store::set_flow_scope(book_url).expect("设 flow scope = bookUrl");
        // 模拟规则 A：book.putVariable 的宿主桥写入（IIFE 内触发路径）
        engine
            .eval(&format!(
                r#"java.__lgBookVarSet("{book_url}", 'seq', '7'); 'ok'"#
            ))
            .expect("__lgBookVarSet 应执行成功");
        // 模拟规则 B：java.get 的前导覆盖经 __lgStoreGet 读（同流程新 eval）
        assert_eq!(
            engine.eval(r#"java.__lgStoreGet('seq')"#).unwrap(),
            "7",
            "scope 内 __lgStoreGet 应经 bookVar 兜底读回"
        );
        // 优先级不回归：会话层（__lgStorePut 写入的 scoped 键）仍优先于 bookVar
        engine
            .eval(r#"java.__lgStorePut('seq', 'session-v'); 'ok'"#)
            .expect("__lgStorePut 应执行成功");
        assert_eq!(
            engine.eval(r#"java.__lgStoreGet('seq')"#).unwrap(),
            "session-v"
        );
        variable_store::remove_variable(&variable_store::book_var_key(book_url, "seq"))
            .expect("收尾清 bookVar 键");
        variable_store::clear_flow_scope().expect("清 scope");
    }

    #[test]
    fn test_java_namespace_http_get_exists() {
        let engine = make_engine();
        // 只验证 java.httpGet 存在且是函数，不实际调用
        let result = engine.eval("typeof java.httpGet").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_response_headers_map_and_list_bridge() {
        let engine = make_engine();
        engine.eval(r#"java.get = function(){ return ''; }; java.connectNR = function(){ return JSON.stringify({status_code:302,body:'',headers:{Location:'https://final.example/r'},url:'https://start.example'}); };"#).unwrap();
        engine.eval(super::RESPONSE_BRIDGE_JS).unwrap();
        let result = engine.eval(r#"JSON.stringify({map:java.get('https://x',{}).headers().Location,list:java.get('https://x',{}).headers('location')[0],missing:java.get('https://x',{}).headers('missing').length})"#).unwrap();
        assert_eq!(
            result,
            r#"{"map":"https://final.example/r","list":"https://final.example/r","missing":0}"#
        );
    }

    #[test]
    fn test_connect_str_response_raw_request_url_bridge() {
        let engine = make_engine();
        engine.eval(r#"java.connect = function(){ return JSON.stringify({status_code:200,body:'ok',headers:{},url:'https://final.example/result'}); };"#).unwrap();
        engine.eval(super::RESPONSE_BRIDGE_JS).unwrap();
        let result = engine.eval(r#"JSON.stringify({body:java.connect('https://start.example').body,url:java.connect('https://start.example').raw().request().url()})"#).unwrap();
        assert_eq!(
            result,
            r#"{"body":"ok","url":"https://final.example/result"}"#
        );
    }

    /// 最小本地回环 HTTP/1.1 搜索 mock 服务器（connectNR / Response bridge
    /// POST 用例的确定性替身，替代外网 tianyashuku.net —— CI 中该站行为
    /// 变化/反爬会改变 302 响应导致用例偶发失败，P2-17 类真联网隐患）。
    ///
    /// 行为忠实复刻帝国 CMS 真站签名：
    /// - POST body 含 `tbname=bookname` → `302 Found` + `Location: /result/?searchid=1`；
    /// - body 丢失（connectNR 未把第 4 参传到宿主）→ `200` + 短提示页、无 Location。
    ///
    /// 用例断言保持不变，仍能捕获 body 丢失回归。
    ///
    /// 用 std `TcpListener` + 单线程（legado-js 的 quickjs tokio feature 无 net）；
    /// 回环流量经 `no_proxy` 豁免系统/环境变量代理（见 network.rs `connect_no_redirect`）。
    fn spawn_search_loopback_server(max_conns: usize) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                let Some(body) = read_http_request_body(&mut sock) else {
                    continue;
                };
                let resp = if body.contains("tbname=bookname") {
                    "HTTP/1.1 302 Found\r\nLocation: /result/?searchid=1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .to_string()
                } else {
                    let notice = "<html><body>请输入查询条件</body></html>";
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        notice.len(),
                        notice
                    )
                };
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// 逐字节读取一个完整 HTTP/1.1 请求（头到 `\r\n\r\n` + Content-Length body），返回 body。
    fn read_http_request_body(sock: &mut std::net::TcpStream) -> Option<String> {
        let mut buf: Vec<u8> = Vec::new();
        let mut byte = [0u8; 1];
        while !buf.ends_with(b"\r\n\r\n") {
            sock.read_exact(&mut byte).ok()?;
            buf.push(byte[0]);
        }
        let content_length = String::from_utf8_lossy(&buf)
            .lines()
            .find_map(|line| {
                line.to_ascii_uppercase()
                    .strip_prefix("CONTENT-LENGTH:")?
                    .trim()
                    .parse::<usize>()
                    .ok()
            })
            .unwrap_or(0);
        let mut body = vec![0u8; content_length];
        if content_length > 0 {
            sock.read_exact(&mut body).ok()?;
        }
        Some(String::from_utf8_lossy(&body).into_owned())
    }

    #[test]
    fn test_connectnr_passes_body() {
        let addr = spawn_search_loopback_server(8);
        let engine = make_engine();
        // java.connectNR 四参须把 body 传到宿主；丢 body 时服务器返回 200 提示页无 Location
        let js = format!(
            r#"
var url = 'http://{addr}/e/search/index.php';
var body = 'show=title,writer&keyboard=%E4%B8%80%E5%BF%B5&tbname=bookname&tempid=1';
var hs = JSON.stringify({{'User-Agent':'Mozilla/5.0','Content-Type':'application/x-www-form-urlencoded'}});
var raw = java.connectNR(url, 'POST', hs, body);
var r = JSON.parse(raw);
JSON.stringify({{status: r.status_code, loc: (r.headers.location||r.headers.Location||null), bodyLen: (r.body||'').length}});
"#
        );
        let result = engine.eval(&js).expect("eval");
        assert!(
            result.contains("\"status\":302") || result.contains("result/?searchid"),
            "got {result}"
        );
    }

    #[test]
    fn test_response_bridge_post_location() {
        let addr = spawn_search_loopback_server(8);
        let engine = make_engine();
        let js = format!(
            r#"
var url = 'http://{addr}/e/search/index.php';
var body = 'show=title,writer&keyboard=%E4%B8%80%E5%BF%B5&tbname=bookname&tempid=1';
var hs = {{'User-Agent':'Mozilla/5.0','Content-Type':'application/x-www-form-urlencoded'}};
var loc = java.post(url, body, hs).header('location');
String(loc);
"#
        );
        let result = engine.eval(&js).expect("eval");
        assert!(
            result.contains("searchid") || result.contains("result"),
            "got {result}"
        );
    }

    #[test]
    fn test_bare_global_still_works() {
        let engine = make_engine();
        let result = engine.eval("md5Encode('hello')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_java_namespace_sha256() {
        let engine = make_engine();
        let result = engine.eval("java.sha256('hello')").unwrap();
        assert_eq!(
            result,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn test_java_namespace_urlencode() {
        let engine = make_engine();
        let result = engine.eval("java.urlencode('hello world')").unwrap();
        assert!(result.contains("%20") || result.contains("+"));
    }

    #[test]
    fn test_java_and_bare_produce_same_result() {
        let engine = make_engine();
        let java_result = engine.eval("java.md5Encode('test123')").unwrap();
        let bare_result = engine.eval("md5Encode('test123')").unwrap();
        assert_eq!(java_result, bare_result);
    }

    #[test]
    fn test_java_open_video_player_bridge() {
        let engine = make_engine();
        // 书源 JS 调用 java.openVideoPlayer(url, title) 应返回结构化桥接载荷
        let result = engine
            .eval("java.openVideoPlayer('http://v.com/x.mp4', '第1集')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "openVideoPlayer");
        assert_eq!(parsed["url"], "http://v.com/x.mp4");
        assert_eq!(parsed["title"], "第1集");
        assert_eq!(parsed["isFloat"], false);
    }

    #[test]
    fn test_bare_open_video_player_with_float() {
        let engine = make_engine();
        // 裸全局调用 + isFloat 参数
        let result = engine
            .eval("openVideoPlayer('http://v.com/y.m3u8', '标题', true)")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["isFloat"], true);
    }

    // ---- 新增 API 集成测试 ----

    #[test]
    fn test_java_aes_encrypt_decrypt() {
        let engine = make_engine();
        // AES 加密后解密应还原
        let result = engine
            .eval(
                "java.aesDecrypt(java.aesEncrypt('hello', '0123456789abcdef'), '0123456789abcdef')",
            )
            .unwrap();
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_java_aes_encrypt_returns_base64() {
        let engine = make_engine();
        let result = engine
            .eval("java.aesEncrypt('hello', '0123456789abcdef')")
            .unwrap();
        // 应为非空 Base64 字符串
        assert!(!result.is_empty());
        assert!(!result.starts_with("[ERROR]"));
    }

    /// createSymmetricCrypto 必须返回对象（含 decrypt），不能是 "AES/CBC" 字符串
    #[test]
    fn test_create_symmetric_crypto_returns_object_with_decrypt() {
        let engine = make_engine();
        let ty = engine
            .eval("typeof java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','fedcba9876543210')")
            .unwrap();
        assert_eq!(ty, "object", "createSymmetricCrypto 应返回对象而非字符串");
        let has = engine
            .eval(
                "typeof java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','fedcba9876543210').decrypt",
            )
            .unwrap();
        assert_eq!(has, "function");
    }

    /// 对齐 51漫画 imageDecode：AES/CBC/NoPadding + decrypt(Uint8Array)
    #[test]
    fn test_create_symmetric_crypto_image_decode_nopadding() {
        use crate::engine::JsEngine;
        use crate::JsValue;
        use base64::Engine as _;
        use legado_core::crypto::AesCrypto;

        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        // JPEG 魔数 + 填充到 16 对齐
        let mut plain = vec![0xFFu8, 0xD8, 0xFF, 0xE0];
        plain.resize(32, 0x41);
        let ct = AesCrypto::encrypt_cbc_nopadding(key, iv, &plain).unwrap();

        let engine = make_engine();
        // 与 51 书源 imageDecode 同构：createSymmetricCrypto(...).decrypt(result)
        let rule = r#"
function decryptImage(src) {
    const key = "0123456789abcdef";
    const iv  = "fedcba9876543210";
    const cipher = java.createSymmetricCrypto("AES/CBC/NoPadding", key, iv);
    return cipher.decrypt(src);
}
decryptImage(result);
"#;
        let out = JsEngine::eval_bytes(&engine, rule, &[("result", JsValue::Bytes(ct))])
            .expect("imageDecode 风格 decrypt 应成功");
        assert_eq!(out, plain);
        assert_eq!(&out[..2], &[0xFF, 0xD8]);
        let _ = base64::engine::general_purpose::STANDARD.encode(&out);
    }

    /// aesBase64DecodeToString：全网漫画目录/正文 AES 解密
    #[test]
    fn test_aes_base64_decode_to_string_host() {
        use base64::Engine as _;
        use legado_core::crypto::AesCrypto;

        let key = "0123456789abcdef";
        let iv = "fedcba9876543210";
        let plain = "{\"chapters\":[{\"chapter_name\":\"1\"}]}";
        let ct = AesCrypto::encrypt_cbc(key.as_bytes(), iv.as_bytes(), plain.as_bytes()).unwrap();
        let b64 = base64::engine::general_purpose::STANDARD.encode(&ct);

        let engine = make_engine();
        let js = format!(
            "java.aesBase64DecodeToString('{b64}', '{key}', 'AES/CBC/PKCS5Padding', '{iv}')"
        );
        let out = engine.eval(&js).unwrap();
        assert_eq!(out, plain);
        assert!(!out.starts_with("[ERROR]"));
    }

    #[test]
    fn test_java_rc4_roundtrip() {
        let engine = make_engine();
        let result = engine
            .eval("java.rc4Decrypt(java.rc4Encrypt('secret data', 'mykey'), 'mykey')")
            .unwrap();
        assert_eq!(result, "secret data");
    }

    /// #135 阅文 QDSign 链路：tripleDESEncodeBase64Str 加密 →
    /// createSymmetricCrypto("DESede/CBC/PKCS5Padding").decryptStr 还原
    #[test]
    fn test_java_desede_chain_qdsign() {
        let engine = make_engine();
        let js = r#"
const data = 'QDSign sign payload';
const key = '0123456789abcdef'; // 16 字节密钥 → 双密钥 EDE
const iv  = '00000000';
const b64 = java.tripleDESEncodeBase64Str(data, key, 'CBC', 'PKCS5Padding', iv);
const cipher = java.createSymmetricCrypto('DESede/CBC/PKCS5Padding', key, iv);
cipher.decryptStr(b64);
"#;
        let out = engine.eval(js).expect("DESede 加密-解密链路应成功");
        assert_eq!(out, "QDSign sign payload");
    }

    /// tripleDESEncodeBase64Str 错误模式应返回 [ERROR] 前缀而非抛异常
    #[test]
    fn test_java_desede_bad_mode_returns_error_prefix() {
        let engine = make_engine();
        let out = engine
            .eval(
                "java.tripleDESEncodeBase64Str('x', '0123456789abcdef', 'OFB', 'NoPadding', '00000000')",
            )
            .unwrap();
        assert!(out.starts_with("[ERROR]"), "应为 [ERROR] 前缀: {out}");
    }

    // ── 3b-3/3b-4/3b-5 引擎级测试（2026-09-26）──

    #[test]
    fn test_cookie_replace_to_map_roundtrip() {
        let engine = make_engine();
        // replaceCookie：现存域 cookie ∪ 新串（新值覆盖、旧键保留）
        engine
            .eval("java.setCookie('https://b233.test/', 'a=1; keep=2')")
            .unwrap();
        engine
            .eval("java.replaceCookie('https://b233.test/', 'a=9; new=x')")
            .unwrap();
        let full = engine.eval("java.getCookie('https://b233.test/')").unwrap();
        assert!(full.contains("a=9"), "新值覆盖: {full}");
        assert!(full.contains("keep=2"), "旧键保留: {full}");
        assert!(full.contains("new=x"), "新键写入: {full}");
        // cookieToMap：';' 拆段 → JSON 串（键值 trim、空值段剔除、同名覆盖）
        let map_json = engine
            .eval("java.cookieToMap('x = 1 ;; y=2; x=3; bad; e=')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&map_json).unwrap();
        assert_eq!(parsed["x"], "3", "同名键后值覆盖");
        assert_eq!(parsed["y"], "2");
        assert!(parsed.get("bad").is_none() && parsed.get("e").is_none());
        // mapToCookie：'; ' 连接；空/不可解析 → null
        let joined = engine
            .eval("java.mapToCookie(JSON.stringify({a:'1', b:'2'}))")
            .unwrap();
        assert_eq!(joined, "a=1; b=2");
        // 裸 java 面：宿主 Option.None → JS undefined（rquickjs 转换口径）；
        // setup 脚本 cookie.mapToCookie 包装层负责转 null（对齐上游返回 null）
        let none = engine.eval("java.mapToCookie('{}')").unwrap();
        assert_eq!(none, "undefined", "裸 java.mapToCookie 空表 → undefined");
        // 收尾
        engine
            .eval("java.clearCookies('https://b233.test/')")
            .unwrap();
    }

    #[test]
    fn test_get_current_url_and_header_map_put() {
        let engine = make_engine();
        // 非 URL 窗口（未设置）→ 空串
        assert_eq!(engine.eval("java.getCurrentUrl()").unwrap(), "");
        // URL 规则窗口（模拟 parser 状态机置值）
        legado_parser::analyze_url::set_current_url(Some("https://cur.test/s?k=1".into()));
        assert_eq!(
            engine.eval("java.getCurrentUrl()").unwrap(),
            "https://cur.test/s?k=1"
        );
        // headerMapPut → parser 线程局部收集器
        engine
            .eval("java.headerMapPut('Cookie', 'is_human=x')")
            .unwrap();
        engine.eval("java.headerMapPut('X-T', '1')").unwrap();
        let pending = legado_parser::analyze_url::take_pending_request_headers();
        assert_eq!(
            pending,
            vec![
                ("Cookie".to_string(), "is_human=x".to_string()),
                ("X-T".to_string(), "1".to_string()),
            ]
        );
        // 复位（对齐 parse_with_js 退出语义）
        legado_parser::analyze_url::set_current_url(None);
        assert_eq!(engine.eval("java.getCurrentUrl()").unwrap(), "");
    }

    #[test]
    fn test_packages_android_text_utils_is_empty() {
        let engine = make_engine();
        assert_eq!(
            engine
                .eval("Packages.android.text.TextUtils.isEmpty('')")
                .unwrap(),
            "true",
            "Kotlin 语义：空串 → true"
        );
        assert_eq!(
            engine
                .eval("Packages.android.text.TextUtils.isEmpty(null)")
                .unwrap(),
            "true",
            "Kotlin 语义：null → true"
        );
        assert_eq!(
            engine
                .eval("Packages.android.text.TextUtils.isEmpty('a')")
                .unwrap(),
            "false",
            "非空 → false"
        );
    }

    #[test]
    fn test_web_view_nullable_args() {
        let engine = make_engine();
        engine.eval(super::RESPONSE_BRIDGE_JS).unwrap();
        // 显式 null 入参（上游 Kotlin String? 语义）不得再报
        // 「Error converting from js 'null' into type 'string'」——语料
        // 听笔趣阁/棉花糖/17k 的 searchUrl 形态 `java.webView(null, url, null)`
        let out = engine
            .eval("java.webView(null, 'https://x.test/', null)")
            .expect("null 入参调用不得抛转换错误");
        // 桌面桩可能返回 [ERROR] 前缀或空串；关键断言是调用本身成功
        assert!(
            !out.contains("converting from js"),
            "不得出现入参转换错误: {out}"
        );
        // 缺参形态（1 参）经垫片补 null 后同样可调
        let _ = engine.eval("java.webView('x')");
    }

    #[test]
    fn test_response_bridge_cookies_helper() {
        let engine = make_engine();
        // 桥注入**前**伪造 java.connect（桥按当前引用捕获原生实现）——
        // 返回罐头响应 JSON，全程零联网
        engine
            .eval(
                "java.connect = function () { return JSON.stringify({ status_code: 200, body: 'x', headers: {}, url: 'https://resp-ck.test/x' }); };",
            )
            .unwrap();
        engine.eval(super::RESPONSE_BRIDGE_JS).unwrap();
        // 响应 JSON 带 url：cookies() 读该 URL 域归属 cookie（请求层已落存储）
        engine
            .eval("java.setCookie('https://resp-ck.test/x', 'ck=9')")
            .unwrap();
        let got = engine
            .eval("java.connect('https://resp-ck.test/x').cookies()")
            .unwrap();
        assert_eq!(got, "ck=9", "response.cookies() 读响应 URL 域 cookie");
        engine
            .eval("java.clearCookies('https://resp-ck.test/x')")
            .unwrap();
    }

    #[test]
    fn test_java_get_cookie() {
        let engine = make_engine();
        // 先 setCookie 再 getCookie
        engine
            .eval("java.setCookie('test_tag', 'session=abc123')")
            .unwrap();
        let result = engine
            .eval("java.getCookie('test_tag', 'session')")
            .unwrap();
        assert_eq!(result, "abc123");
        // 清理
        engine.eval("java.clearCookies('test_tag')").unwrap();
    }

    #[test]
    fn test_java_html_format() {
        let engine = make_engine();
        let result = engine.eval("java.htmlFormat('<p>hello</p>')").unwrap();
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_java_html_format_complex() {
        let engine = make_engine();
        let result = engine
            .eval("java.htmlFormat('<div>正文</div><script>alert(1)</script><div>结尾</div>')")
            .unwrap();
        assert!(result.contains("正文"));
        assert!(result.contains("结尾"));
        assert!(!result.contains("script"));
    }

    #[test]
    fn test_java_t2s() {
        let engine = make_engine();
        let result = engine.eval("java.t2s('國')").unwrap();
        assert_eq!(result, "国");
    }

    #[test]
    fn test_java_s2t() {
        let engine = make_engine();
        let result = engine.eval("java.s2t('国')").unwrap();
        assert_eq!(result, "國");
    }

    #[test]
    fn test_java_to_num_chapter() {
        let engine = make_engine();
        let result = engine.eval("java.toNumChapter('第一百二十三章')").unwrap();
        assert_eq!(result, "第123章");
    }

    #[test]
    fn test_java_digest_hex() {
        let engine = make_engine();
        let result = engine.eval("java.digestHex('hello', 'MD5')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_java_str_to_bytes() {
        let engine = make_engine();
        let result = engine.eval("java.strToBytes('Hello')").unwrap();
        assert_eq!(result, "[72,101,108,108,111]");
    }

    #[test]
    fn test_java_bytes_to_str() {
        let engine = make_engine();
        let result = engine
            .eval("java.bytesToStr('[72,101,108,108,111]')")
            .unwrap();
        assert_eq!(result, "Hello");
    }

    // 七猫正文 [object Object] 回归（2026-08-15）：`new Packages.java.lang.String
    // (bytes, charset)` 在 JS `new` 语义下，构造器显式 return 原始值（字符串）时
    // 表达式结果为 this 空对象 → String(this)="[object Object]"；bytes 分支必须
    // 返回 JSString 对象，toString/valueOf 再取回明文。含 4 参数重载
    // String(bytes, offset, length, charset)（qmDecodeTextBytes 编码探测头）。
    #[test]
    fn test_packages_java_string_new_bytes_returns_plaintext() {
        let engine = make_engine();
        // 2 参数：new String(bytes, 'UTF-8') → String(...) 应为明文而非 [object Object]
        let result = engine
            .eval(
                "String(new Packages.java.lang.String(new Uint8Array([72,101,108,108,111]), 'UTF-8'))",
            )
            .unwrap();
        assert_eq!(
            result, "Hello",
            "new String(bytes, charset) 应返回明文，实际: {result}"
        );
        // 4 参数：new String(bytes, offset, length, charset) 取子数组解码
        let result = engine
            .eval(
                "String(new Packages.java.lang.String(new Uint8Array([0,72,101,108,108,111,0]), 1, 5, 'UTF-8'))",
            )
            .unwrap();
        assert_eq!(
            result, "Hello",
            "4 参数重载应取 [offset, offset+length) 子数组解码，实际: {result}"
        );
        // 1 参数（非 bytes）：new String('text') 保持字符串语义
        let result = engine
            .eval("String(new Packages.java.lang.String('abc'))")
            .unwrap();
        assert_eq!(result, "abc");
        // getBytes 仍可用（new 保留 JSString 对象）
        let result = engine
            .eval("String(new Packages.java.lang.String('abc').getBytes('UTF-8').length)")
            .unwrap();
        assert_eq!(result, "3");
    }

    #[test]
    fn test_bare_global_new_apis() {
        let engine = make_engine();
        // 裸全局调用新 API
        let result = engine.eval("t2s('國')").unwrap();
        assert_eq!(result, "国");
        let result = engine.eval("htmlFormat('<b>bold</b>')").unwrap();
        assert_eq!(result, "bold");
        let result = engine.eval("toNumChapter('第一章')").unwrap();
        assert_eq!(result, "第1章");
    }

    // ---- P2-6 新增 API 集成测试 ----

    #[test]
    fn test_java_web_view_bridge() {
        let engine = make_engine();
        let result = engine
            .eval("java.webView('', 'http://test.com', 'document.title')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webView");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["js"], "document.title");
    }

    #[test]
    fn test_java_web_view_get_source_bridge() {
        let engine = make_engine();
        let result = engine
            .eval("java.webViewGetSource('', 'http://test.com', '', 'content')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webViewGetSource");
        assert_eq!(parsed["sourceRegex"], "content");
    }

    #[test]
    fn test_java_start_browser_bridge() {
        let engine = make_engine();
        let result = engine
            .eval("java.startBrowser('http://test.com', '标题')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "startBrowser");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["title"], "标题");
    }

    #[test]
    fn test_java_open_url_bridge() {
        let engine = make_engine();
        let result = engine.eval("java.openUrl('legado://import')").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "openUrl");
        assert_eq!(parsed["url"], "legado://import");
    }

    #[test]
    fn test_java_get_verification_code_channel() {
        use std::time::{Duration, Instant};

        let engine = std::sync::Arc::new(make_engine());
        let image_url = "http://img.com/captcha-quickjs-test.png";
        let rx = legado_core::verification_channel::verification_manager().subscribe();

        // JS eval 在后台线程阻塞等待（模拟 JS 工作线程）
        let eng = engine.clone();
        let worker = std::thread::spawn(move || {
            eng.eval("java.getVerificationCode('http://img.com/captcha-quickjs-test.png')")
                .unwrap()
        });

        // UI 侧：定位事件并提交
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut key = None;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == image_url => {
                    key = Some(req.key);
                    break;
                }
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        let key = key.expect("应收到验证码请求事件");
        assert!(legado_core::verification_channel::submit_verification_result(&key, "q777"));
        assert_eq!(worker.join().unwrap(), "q777");
    }

    #[test]
    fn test_java_start_browser_await_degraded() {
        use std::time::{Duration, Instant};

        let engine = std::sync::Arc::new(make_engine());
        let url = "http://verify.example.com/quickjs-browser-degrade";
        let rx = legado_core::verification_channel::verification_manager().subscribe();

        let eng = engine.clone();
        let worker = std::thread::spawn(move || {
            eng.eval("java.startBrowserAwait('http://verify.example.com/quickjs-browser-degrade', '验证', true)")
                .unwrap()
        });

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut key = None;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == url => {
                    assert!(!req.use_browser);
                    key = Some(req.key);
                    break;
                }
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        let key = key.expect("应收到降级验证请求事件");
        assert!(legado_core::verification_channel::submit_verification_result(&key, "b555"));
        assert_eq!(worker.join().unwrap(), "b555");
    }

    #[test]
    fn test_java_query_ttf() {
        let engine = make_engine();
        let result = engine
            .eval("java.queryTTF('https://example.com/font.ttf')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "url");
        // 真实实现：字体下载/解析失败时句柄标记 valid=false（降级）
        assert_eq!(parsed["valid"], false);
    }

    #[test]
    fn test_java_query_ttf_empty() {
        let engine = make_engine();
        let result = engine.eval("java.queryTTF('')").unwrap();
        assert_eq!(result, "null");
    }

    #[test]
    fn test_java_query_base64_ttf() {
        let engine = make_engine();
        let result = engine.eval("java.queryBase64TTF('AAECAwQF')").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        // 真实实现：非法 base64 字体解析失败 → valid=false
        assert_eq!(parsed["valid"], false);
    }

    #[test]
    fn test_java_replace_font_null_handles() {
        let engine = make_engine();
        let result = engine
            .eval("java.replaceFont('hello', 'null', 'null')")
            .unwrap();
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_java_replace_font_stub() {
        let engine = make_engine();
        // 句柄无效（下载失败）时降级原样返回，与 Kotlin null 句柄分支一致
        let result = engine
            .eval(
                "var e = java.queryTTF('https://e.com/f.ttf'); \
                 var c = java.queryTTF('https://c.com/f.ttf'); \
                 java.replaceFont('测试', e, c)",
            )
            .unwrap();
        assert_eq!(result, "测试");
    }

    #[test]
    fn test_java_replace_font_real_cmap() {
        // 端到端：真实 cmap/glyf 解析，经 JS 契约完成防爬字体替换
        use crate::host_api::font_api::tests::{build_minimal_ttf, Segment};
        use base64::Engine;
        let err_font = build_minimal_ttf(
            &[Segment {
                start: 0xE001,
                end: 0xE003,
                id_delta: 0x2000,
            }],
            false,
        );
        let ok_font = build_minimal_ttf(
            &[Segment {
                start: 0x41,
                end: 0x43,
                id_delta: -0x40,
            }],
            false,
        );
        let err_b64 = base64::engine::general_purpose::STANDARD.encode(&err_font);
        let ok_b64 = base64::engine::general_purpose::STANDARD.encode(&ok_font);

        let engine = make_engine();
        let script = format!(
            "var e = java.queryTTF('{}'); \
             var c = java.queryTTF('{}'); \
             java.replaceFont('\\uE001\\uE002\\uE003结尾', e, c)",
            err_b64, ok_b64
        );
        let result = engine.eval(&script).unwrap();
        assert_eq!(result, "ABC结尾");
    }

    #[test]
    fn test_java_ajax_all_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.ajaxAll").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_head_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.head").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_post_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.post").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_connect_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.connect").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_un7z_file_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.un7zFile").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_unrar_file_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.unrarFile").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_unrar_file_missing_file_error() {
        // 真实实现（rar crate）：不存在的文件返回 [ERROR] 前缀错误信息
        let engine = make_engine();
        let result = engine.eval("java.unrarFile('test.rar')").unwrap();
        assert!(result.contains("[ERROR]"));
    }

    #[test]
    fn test_java_get7z_string_content_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.get7zStringContent").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_get_rar_string_content_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.getRarStringContent").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_java_get7z_string_content_local_file() {
        use std::io::Write;

        // 构造测试 7z 文件
        let dir = std::env::temp_dir().join(format!(
            "legado_js_7z_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let src_dir = dir.join("src");
        std::fs::create_dir_all(&src_dir).unwrap();
        let entry_path = src_dir.join("inner.txt");
        let mut f = std::fs::File::create(&entry_path).unwrap();
        f.write_all("7z 内部文本内容".as_bytes()).unwrap();
        drop(f);
        let seven_z_path = dir.join("test.7z");
        sevenz_rust2::compress_to_path(&src_dir, &seven_z_path).unwrap();

        // JS 侧调用：本地路径 + 条目名
        let path_js = seven_z_path.to_str().unwrap().replace('\\', "\\\\");
        let engine = make_engine();
        let script = format!("java.get7zStringContent('{path_js}', 'inner.txt')");
        let result = engine.eval(&script).unwrap();
        assert_eq!(result, "7z 内部文本内容");

        // 不存在的条目 → 空串（对齐 Kotlin 失败语义）
        let script = format!("java.get7zStringContent('{path_js}', 'no-such.txt')");
        let result = engine.eval(&script).unwrap();
        assert_eq!(result, "");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ============================================================
    // Task #95：unzipFile / getZipStringContent / 零星 API 宿主集成测试
    // ============================================================

    /// 辅助：创建测试 ZIP 文件，返回路径
    fn create_zip_for_js(entries: &[(&str, &[u8])]) -> String {
        use std::io::Write;
        use zip::write::SimpleFileOptions;
        use zip::ZipWriter;

        let dir = std::env::temp_dir().join(format!(
            "legado_js_host_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("host_test.zip");

        let file = std::fs::File::create(&zip_path).unwrap();
        let mut writer = ZipWriter::new(file);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (name, content) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap();

        zip_path.to_string_lossy().to_string()
    }

    /// 辅助：把路径转为 JS 字符串字面量（转义 Windows 反斜杠）
    fn js_str(s: &str) -> String {
        format!("'{}'", s.replace('\\', "\\\\"))
    }

    #[test]
    fn test_java_unzip_file_exists() {
        let engine = make_engine();
        let result = engine.eval("typeof java.unzipFile").unwrap();
        assert_eq!(result, "function");
    }

    #[test]
    fn test_js_unzip_file_round_trip() {
        // unzip 往返：创建 ZIP → JS 调用 unzipFile → 验证解压产物
        let zip_path = create_zip_for_js(&[
            ("hello.txt", b"unzip round trip"),
            ("sub/data.bin", &[0x01, 0x02]),
        ]);
        let engine = make_engine();
        let code = format!("java.unzipFile({})", js_str(&zip_path));
        let out_dir = engine.eval(&code).unwrap();
        assert!(
            !out_dir.starts_with("[ERROR]"),
            "unzipFile 失败: {}",
            out_dir
        );
        assert!(std::path::Path::new(&out_dir).join("hello.txt").exists());
        assert!(std::path::Path::new(&out_dir).join("sub/data.bin").exists());

        let _ = std::fs::remove_dir_all(&out_dir);
        let _ = std::fs::remove_dir_all(std::path::Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_js_unzip_file_empty_path() {
        // 对齐 Kotlin：空路径返回空串
        let engine = make_engine();
        let result = engine.eval("java.unzipFile('')").unwrap();
        assert_eq!(result, "");
    }

    #[test]
    fn test_js_get_zip_string_content() {
        let content = "ZIP 文本内容";
        let zip_path = create_zip_for_js(&[("content.txt", content.as_bytes())]);
        let engine = make_engine();

        let code = format!(
            "java.getZipStringContent({}, 'content.txt')",
            js_str(&zip_path)
        );
        let result = engine.eval(&code).unwrap();
        assert_eq!(result, content);

        // 不存在的条目返回空串（对齐 Kotlin return ""）
        let code = format!("java.getZipStringContent({}, 'no.txt')", js_str(&zip_path));
        assert_eq!(engine.eval(&code).unwrap(), "");

        let _ = std::fs::remove_dir_all(std::path::Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_js_get_zip_string_content_hex_source() {
        // 十六进制字符串来源（对齐 Kotlin HexUtil.decodeHex 分支）
        let zip_path = create_zip_for_js(&[("h.txt", b"hex source")]);
        let hex_str = hex::encode(std::fs::read(&zip_path).unwrap());
        let engine = make_engine();

        let code = format!("java.getZipStringContent('{}', 'h.txt')", hex_str);
        assert_eq!(engine.eval(&code).unwrap(), "hex source");

        let _ = std::fs::remove_dir_all(std::path::Path::new(&zip_path).parent().unwrap());
    }

    /// 辅助：创建包含指定文件的测试 7z 压缩包，返回 7z 文件路径
    fn create_7z_for_js(entries: &[(&str, &[u8])]) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let src_dir = std::env::temp_dir().join(format!("legado_js_7z_src_{:x}", nanos));
        std::fs::create_dir_all(&src_dir).unwrap();
        for (name, content) in entries {
            let file_path = src_dir.join(name);
            if let Some(parent) = file_path.parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::write(&file_path, content).unwrap();
        }

        let seven_z_path = std::env::temp_dir()
            .join(format!("legado_js_7z_arc_{:x}", nanos))
            .join("host_test.7z");
        if let Some(parent) = seven_z_path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        sevenz_rust2::compress_to_path(&src_dir, &seven_z_path).unwrap();
        let _ = std::fs::remove_dir_all(&src_dir);

        seven_z_path.to_string_lossy().to_string()
    }

    #[test]
    fn test_js_get_7z_string_content() {
        // 7z 本地文件来源往返（对齐 getZipStringContent 模式）
        let content = "第七章 7z 文本内容";
        let seven_z_path = create_7z_for_js(&[("chapter.txt", content.as_bytes())]);
        let engine = make_engine();

        let code = format!(
            "java.get7zStringContent({}, 'chapter.txt')",
            js_str(&seven_z_path)
        );
        let result = engine.eval(&code).unwrap();
        assert_eq!(result, content);

        // 不存在的条目返回空串（对齐 Kotlin return ""）
        let code = format!(
            "java.get7zStringContent({}, 'no.txt')",
            js_str(&seven_z_path)
        );
        assert_eq!(engine.eval(&code).unwrap(), "");

        let _ = std::fs::remove_dir_all(std::path::Path::new(&seven_z_path).parent().unwrap());
    }

    #[test]
    fn test_js_get_rar_string_content_hex_source() {
        // RAR 十六进制来源往返：RAR5 STORE 单文件 fixture（与 archive_utils 测试同源）
        const RAR5_HELLO: &[u8] = &[
            0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, 0xc5, 0x1a, 0x33, 0x32, 0x03, 0x01,
            0x00, 0x00, 0xe4, 0xf8, 0x02, 0x48, 0x16, 0x02, 0x02, 0x10, 0x04, 0x10, 0x20, 0xec,
            0x68, 0x08, 0x45, 0x00, 0x01, 0x09, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78,
            0x74, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x52, 0x41, 0x52, 0x20, 0x57, 0x6f, 0x72,
            0x6c, 0x64, 0x21, 0x19, 0xb2, 0x3a, 0x35, 0x03, 0x05, 0x00, 0x00,
        ];
        let hex_str = hex::encode(RAR5_HELLO);
        let engine = make_engine();

        let code = format!("java.getRarStringContent('{}', 'hello.txt')", hex_str);
        assert_eq!(engine.eval(&code).unwrap(), "Hello RAR World!");

        // 不存在的条目返回空串（对齐 Kotlin return ""）
        let code = format!("java.getRarStringContent('{}', 'no.txt')", hex_str);
        assert_eq!(engine.eval(&code).unwrap(), "");
    }

    #[test]
    fn test_js_web_view_get_override_url_payload() {
        let engine = make_engine();
        let result = engine
            .eval("java.webViewGetOverrideUrl('', 'http://t.com', '', 'legado://.*')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webViewGetOverrideUrl");
        assert_eq!(parsed["url"], "http://t.com");
        assert_eq!(parsed["overrideUrlRegex"], "legado://.*");
        assert_eq!(parsed["cacheFirst"], false);
    }

    #[test]
    fn test_js_show_browser_payload() {
        let engine = make_engine();
        let result = engine
            .eval("java.showBrowser('http://t.com', '<h/>')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "openBrowser");
        assert_eq!(parsed["url"], "http://t.com");
        assert_eq!(parsed["html"], "<h/>");
    }

    #[test]
    fn test_js_long_toast() {
        let engine = make_engine();
        let result = engine.eval("java.longToast('长提示')").unwrap();
        assert_eq!(result, "长提示");
        // 裸全局同样可用
        let result = engine.eval("longToast('bare')").unwrap();
        assert_eq!(result, "bare");
    }

    #[test]
    fn test_js_base64_decode_to_byte_array() {
        let engine = make_engine();
        // 'aGVsbG8=' = "hello"
        let result = engine
            .eval("Array.from(java.base64DecodeToByteArray('aGVsbG8=')).join(',')")
            .unwrap();
        assert_eq!(result, "104,101,108,108,111");
        // 空白输入返回 null（对齐 Kotlin isNullOrBlank -> null）
        let result = engine
            .eval("java.base64DecodeToByteArray('') === null")
            .unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn test_js_time_format() {
        let engine = make_engine();
        let result = engine.eval("java.timeFormat(1704067200000)").unwrap();
        // Kotlin dateFormat = "yyyy/MM/dd HH:mm"
        let re = regex::Regex::new(r"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$").unwrap();
        assert!(re.is_match(&result), "timeFormat 结果不匹配: {}", result);
        // formatTime 兼容名保留（双参形式）
        let result = engine.eval("java.formatTime(1704067200000, '%Y')").unwrap();
        assert_eq!(result, "2024");
    }

    #[test]
    fn test_js_to_url_fields() {
        let engine = make_engine();
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com:8080/a/b?x=1&y=%E4%B8%AD').host")
                .unwrap(),
            "ex.com"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com:8080/a/b').origin")
                .unwrap(),
            "https://ex.com:8080"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a/b').pathname")
                .unwrap(),
            "/a/b"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a?x=1').searchParams.x")
                .unwrap(),
            "1"
        );
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a?y=%E4%B8%AD').searchParams.y")
                .unwrap(),
            "中"
        );
        // 无 query 时 searchParams 为 null（对齐 Kotlin JsURL）
        assert_eq!(
            engine
                .eval("java.toURL('https://ex.com/a').searchParams === null")
                .unwrap(),
            "true"
        );
    }

    #[test]
    fn test_js_to_url_relative_base() {
        let engine = make_engine();
        assert_eq!(
            engine
                .eval("java.toURL('c.html', 'https://ex.com/a/b.html').pathname")
                .unwrap(),
            "/a/c.html"
        );
        assert_eq!(
            engine
                .eval("java.toURL('/c', 'https://ex.com/a/b.html').pathname")
                .unwrap(),
            "/c"
        );
    }

    #[test]
    fn test_bare_web_view_bridge() {
        let engine = make_engine();
        // [可空入参修复 | 2026-09-26] 原生 webView 换 NullStr/NullBool 后
        // arity=4；生产环境 RESPONSE_BRIDGE_JS 垫片恒在（补 null 至 4 参），
        // 本测试对齐生产形态先注入桥，裸全局 3 参调用经垫片照常工作
        engine.eval(super::RESPONSE_BRIDGE_JS).unwrap();
        let engine = engine;
        // 裸全局调用 webView（垫片同时镜像到裸全局：java.webView 被覆盖，
        // 裸 webView 仍指原生——此处经 java 面验证垫片，再验裸全局原生）
        let result = engine
            .eval("java.webView('', 'http://bare.com', 'js_code')")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["action"], "webView");
        assert_eq!(parsed["url"], "http://bare.com");
    }

    #[test]
    fn test_bare_query_ttf() {
        let engine = make_engine();
        let result = engine.eval("queryTTF('/fonts/test.ttf')").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "file");
    }

    // ===== P2-6(e) java.getString 规则分派：绑定级回归测试 =====
    // fixture 位于 workspace 内 rust/legado-ffi/tests/fixtures/songhe/（书源 + curl 生成的真实响应体）。

    fn fixture_path(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../legado-ffi/tests/fixtures/songhe")
            .join(name)
    }

    /// 类1：JSON 内容 + `$.a` 顶层 JSONPath 取值（数值/布尔归一为字符串）
    #[test]
    fn test_binding_get_string_jsonpath_top_level() {
        let engine = make_engine();
        engine
            .eval(r#"globalThis.src = JSON.stringify({"a": "x", "n": 42, "b": true});"#)
            .unwrap();
        assert_eq!(engine.eval("java.getString('$.a')").unwrap(), "x");
        assert_eq!(engine.eval("java.getString('$.n')").unwrap(), "42");
        assert_eq!(engine.eval("java.getString('$.b')").unwrap(), "true");
    }

    /// 类2：JSON 内容 + 嵌套 JSONPath（`$.a.b.c` 与 `$.list[*].k` 多结果换行连接）
    #[test]
    fn test_binding_get_string_jsonpath_nested() {
        let engine = make_engine();
        engine
            .eval(
                r#"globalThis.src = JSON.stringify({"a": {"b": {"c": "deep"}}, "list": [{"k": "x"}, {"k": "y"}]});"#,
            )
            .unwrap();
        assert_eq!(engine.eval("java.getString('$.a.b.c')").unwrap(), "deep");
        assert_eq!(
            engine.eval("java.getString('$.list[*].k')").unwrap(),
            "x\ny"
        );
    }

    /// 类3（反回归）：HTML 内容 + CSS 规则维持既有 CSS 行为，不被分派改变
    #[test]
    fn test_binding_get_string_html_css_unchanged() {
        let engine = make_engine();
        engine
            .eval(
                r#"globalThis.src = '<html><body><h1 class="title">书名</h1><a id="read" href="/read">读</a></body></html>';"#,
            )
            .unwrap();
        assert_eq!(engine.eval("java.getString('.title')").unwrap(), "书名");
        assert_eq!(
            engine.eval("java.getString('#read@href')").unwrap(),
            "/read"
        );
    }

    /// 类4：HTML（非 JSON）内容下 `$.x` 按上游 JSONPath 无结果 → 空串，不 panic/报错
    #[test]
    fn test_binding_get_string_jsonpath_on_html_yields_empty() {
        let engine = make_engine();
        engine
            .eval(r#"globalThis.src = '<html><body><h1 class="t">x</h1></body></html>';"#)
            .unwrap();
        assert_eq!(engine.eval("java.getString('$.x')").unwrap(), "");
        // 显式 @json: 前缀在 HTML 内容下同样无结果
        assert_eq!(engine.eval("java.getString('@json:$.x')").unwrap(), "");
    }

    /// 类5（真实源·🏷松鹤庭沐·言璃 详情）：ruleBookInfo.kind 各段不再产出 "0.0万字"
    /// 书源 `init` 规则为 `$.data.bookInfo`，故 getString 内容即 data.bookInfo 节点。
    #[test]
    fn test_binding_songhe_detail_kind_no_zero_words() {
        let raw = std::fs::read_to_string(fixture_path("detail.json")).expect("detail fixture");
        let v: serde_json::Value = serde_json::from_str(&raw).expect("detail json");
        let book_info = v
            .get("data")
            .and_then(|d| d.get("bookInfo"))
            .cloned()
            .expect("data.bookInfo 节点");
        // 生产语义：src 是内容**字符串**（执行器 prologue 注入 JSON 字面量串），
        // 绑定层按 String 读取 → 这里注入 JSON 文本而非 JS 对象
        let src_js = format!("globalThis.src = JSON.stringify({book_info});");
        let engine = make_engine();
        engine.eval(&src_js).unwrap();

        // ruleBookInfo.kind 原文（{{}} 模板由 parser 层展开，此处逐段验证 JS 表达式）：
        // {{$.userscore}}分 · {{$.subject}} · {{$.serialnum}}章 ·
        // {{(Number(java.getString('$.contentsize'))/10000).toFixed(1)}}万字 ·
        // {{java.getString('$.isfinish')=='true'?'已完结':'连载中'}}
        assert_eq!(engine.eval("java.getString('$.userscore')").unwrap(), "9.9");
        assert_eq!(
            engine.eval("java.getString('$.subject')").unwrap(),
            "轻小说"
        );
        assert_eq!(engine.eval("java.getString('$.serialnum')").unwrap(), "712");
        // 核心修复点：修复前 java.getString 只做 CSS 解析 → 空串 → Number('')=0 → "0.0万字"
        assert_eq!(
            engine
                .eval("(Number(java.getString('$.contentsize'))/10000).toFixed(1)")
                .unwrap(),
            "298.6"
        );
        assert_eq!(
            engine
                .eval("java.getString('$.isfinish')=='true'?'已完结':'连载中'")
                .unwrap(),
            "已完结"
        );
        assert_eq!(
            engine
                .eval("String(java.getString('$.tag')).replace(/\\|/g,'、')")
                .unwrap(),
            "影视原著、学院流、穿越、升级流、热血"
        );
    }

    /// 类5（真实源·目录）：ruleToc.chapterName 的 🔒 前缀对免费章（isFree=true）应为空。
    /// 上游对 isFree 布尔 true 归一为 "true"，故 712 章全部不加锁。
    #[test]
    fn test_binding_songhe_chapters_no_free_lock() {
        let raw = std::fs::read_to_string(fixture_path("chapters.json")).expect("chapters fixture");
        let v: serde_json::Value = serde_json::from_str(&raw).expect("chapters json");
        let rows_json = serde_json::to_string(
            &v.get("rows")
                .and_then(|r| r.as_array())
                .cloned()
                .expect("rows 数组"),
        )
        .unwrap();
        let script = format!(
            "var rows = {rows_json};\nvar locked = 0;\nfor (var i = 0; i < rows.length; i++) {{\n  globalThis.src = JSON.stringify(rows[i]);\n  var isFree = java.getString('$.isFree');\n  if (isFree !== 'true') {{ locked++; }}\n  if (i === 0) {{ globalThis.__name0 = java.getString('$.serialName'); }}\n}}\nlocked + '|' + rows.length"
        );
        let engine = make_engine();
        assert_eq!(engine.eval(&script).unwrap(), "0|712");
        assert_eq!(
            engine.eval("globalThis.__name0").unwrap(),
            "第1章 引子 穿越的唐家三少"
        );
    }

    /// 类5 补充（真实源·搜索）：ruleSearch 条目字段 `$.categoryInfoV4` 直取
    #[test]
    fn test_binding_songhe_search_category() {
        let raw = std::fs::read_to_string(fixture_path("search.json")).expect("search fixture");
        let v: serde_json::Value = serde_json::from_str(&raw).expect("search json");
        let item = &v["booklist"][0];
        let engine = make_engine();
        engine
            .eval(&format!("globalThis.src = JSON.stringify({item});"))
            .unwrap();
        assert_eq!(
            engine.eval("java.getString('$.categoryInfoV4')").unwrap(),
            "20000:小说:小说,20001:玄幻:玄幻,20003:异世大陆:异世"
        );
    }

    // ===== P2-9 ① 宿主方法补齐测试 =====

    /// java.getStringList（上游 AnalyzeByJSoup.kt:72）：多值不连接，数组附 size()
    #[test]
    fn test_java_getstringlist_function_and_size() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                src = '{"list":["a","b","c"]}';
                var arr = java.getStringList('$.list[*]');
                JSON.stringify({ items: arr, size: arr.size() });
                "#,
            )
            .unwrap();
        assert!(
            result.contains("\"items\":[\"a\",\"b\",\"c\"]"),
            "got: {result}"
        );
        assert!(result.contains("\"size\":3"), "got: {result}");
        // 独立 mContent 覆盖全局 src
        let result2 = engine
            .eval(
                r#"
                JSON.stringify(java.getStringList('$.x[*]', '{"x":["p","q"]}'));
                "#,
            )
            .unwrap();
        assert!(result2.contains("[\"p\",\"q\"]"), "got: {result2}");
    }

    /// P2-11 ④（§196）：getStringList 细分差异对齐上游
    /// AnalyzeRule.kt:202-293 null 语义 + \n 拆分 + get/isEmpty 别名
    ///
    /// 配对实验（旧实现 → 新实现，上游依据）：
    /// - 空规则：旧 `[]` → 新 `null`（上游 L203 isNullOrEmpty → null）
    /// - `@js: return null`：旧 `[]` → 新 `null`（L275 result == null → null）
    /// - JS 求值异常（`missingVar`）：旧 `[]` → 新 `null`（L274-275 catch → null）
    /// - `@js: return 42`：旧 `["42"]` → 新 `null`（L292 `42 as? List` → null）
    /// - `@js: return "a\nb"`：旧 `["a\nb"]`（join 后单元素）→ 新 `["a","b"]`
    ///   （L276-278 `result.split("\n")`）
    /// - `@js: return ""`：旧 `[]` → 新 `[""]`（Kotlin `"".split("\n")` → `[""]`）
    /// - `@js: return ["x","y"]`：旧 `["x\ny"]`（join 后单元素）→ 新 `["x","y"]`
    ///   （P2-6(e) 展开，元素逐个保留）
    /// - JSON 数组字符串 `JSON.stringify(["p","q"])`：`["p","q"]`（P2-6(e) 既有不变）
    /// - CSS 零命中：`[]` 且 `isEmpty() === true`（上游 List 结果，零命中非 null）
    /// - 新别名 `get(i)` / `isEmpty()`（Java List 面；越界 get 抛错，
    ///   对齐 JDK List.get → IndexOutOfBoundsException）
    #[test]
    fn test_java_getstringlist_null_semantics_and_aliases() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var out = {};
                out.emptyRule = java.getStringList('') === null;
                out.jsNull = java.getStringList('@js: return null') === null;
                out.jsErr = java.getStringList('@js: return missingVar') === null;
                out.jsNumber = java.getStringList('@js: return 42') === null;
                out.split = java.getStringList('@js: return "a\\nb"');
                out.emptyStr = java.getStringList('@js: return ""');
                out.jsArray = java.getStringList('@js: return ["x","y"]');
                out.jsonArr = java.getStringList('@js: return JSON.stringify(["p","q"])');
                JSON.stringify(out);
                "#,
            )
            .unwrap();
        assert!(result.contains("\"emptyRule\":true"), "got: {result}");
        assert!(result.contains("\"jsNull\":true"), "got: {result}");
        assert!(result.contains("\"jsErr\":true"), "got: {result}");
        assert!(result.contains("\"jsNumber\":true"), "got: {result}");
        assert!(result.contains("\"split\":[\"a\",\"b\"]"), "got: {result}");
        assert!(result.contains("\"emptyStr\":[\"\"]"), "got: {result}");
        assert!(
            result.contains("\"jsArray\":[\"x\",\"y\"]"),
            "got: {result}"
        );
        assert!(
            result.contains("\"jsonArr\":[\"p\",\"q\"]"),
            "got: {result}"
        );

        // get(i)/isEmpty() 别名：拆分列表 ["a","b"]
        let result2 = engine
            .eval(
                r#"
                var l = java.getStringList('@js: return "a\\nb"');
                var oob = false; var neg = false;
                try { l.get(2); } catch (e) { oob = true; }
                try { l.get(-1); } catch (e) { neg = true; }
                JSON.stringify({
                    g0: l.get(0) === 'a',
                    g1: l.get(1) === 'b',
                    oob: oob, neg: neg,
                    isEmpty: l.isEmpty(),
                    size: l.size(),
                    len: l.length,
                });
                "#,
            )
            .unwrap();
        assert!(result2.contains("\"g0\":true"), "got: {result2}");
        assert!(result2.contains("\"g1\":true"), "got: {result2}");
        assert!(result2.contains("\"oob\":true"), "got: {result2}");
        assert!(result2.contains("\"neg\":true"), "got: {result2}");
        assert!(result2.contains("\"isEmpty\":false"), "got: {result2}");
        assert!(result2.contains("\"size\":2"), "got: {result2}");
        assert!(result2.contains("\"len\":2"), "got: {result2}");

        // CSS 零命中 → 空数组（非 null），isEmpty() === true，get(0) 抛错
        let result3 = engine
            .eval(
                r#"
                var e = java.getStringList('a.miss@href', '<div></div>');
                var threw = false;
                try { e.get(0); } catch (err) { threw = true; }
                JSON.stringify({
                    isNull: e === null,
                    isEmpty: e.isEmpty(),
                    size: e.size(),
                    threw: threw,
                });
                "#,
            )
            .unwrap();
        assert!(result3.contains("\"isNull\":false"), "got: {result3}");
        assert!(result3.contains("\"isEmpty\":true"), "got: {result3}");
        assert!(result3.contains("\"size\":0"), "got: {result3}");
        assert!(result3.contains("\"threw\":true"), "got: {result3}");
    }

    /// java.setContent（上游 AnalyzeRule.kt:101）：更新分析器内容（src），不动 result
    #[test]
    fn test_java_set_content_updates_src() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                src = '{"a":"old"}';
                var before = java.getString('$.a');
                java.setContent('{"a":"new"}');
                var after = java.getString('$.a');
                java.setContent('{"b":1}', 'https://base.example/');
                JSON.stringify({ before: before, after: after, base: String(baseUrl) });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"before\":\"old\""), "got: {result}");
        assert!(result.contains("\"after\":\"new\""), "got: {result}");
        assert!(result.contains("https://base.example/"), "got: {result}");
    }

    /// java.hexDecodeToByteArray（上游 JsExtensions.kt:666）：十六进制 → Uint8Array
    #[test]
    fn test_hex_decode_to_byte_array() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var b = java.hexDecodeToByteArray('48656c6c6f');
                JSON.stringify({
                    len: b.length,
                    c0: b[0],
                    empty: java.hexDecodeToByteArray('') === null
                });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"len\":5"), "got: {result}");
        assert!(result.contains("\"c0\":72"), "got: {result}");
        assert!(result.contains("\"empty\":true"), "got: {result}");
        // 非法 hex → 抛异常（可被 try/catch 捕获）
        let threw = engine
            .eval(
                r#"
                var t = false;
                try { java.hexDecodeToByteArray('zz'); } catch (e) { t = true; }
                t;
                "#,
            )
            .unwrap();
        assert_eq!(threw, "true");
    }

    /// java.upLoginData（上游 SourceLoginJsExtensions.kt:35）：无回调通道 → no-op 不抛
    #[test]
    fn test_up_login_data_noop() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var r1 = java.upLoginData();
                var r2 = java.upLoginData({a: 'b'});
                JSON.stringify({
                    r1: r1 === undefined,
                    r2: r2 === undefined,
                    fns: typeof java.upLoginData
                });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"r1\":true"), "got: {result}");
        assert!(result.contains("\"r2\":true"), "got: {result}");
        assert!(result.contains("\"fns\":\"function\""), "got: {result}");
    }

    /// java.threadSleep（上游 Thread.sleep shim）：真实休眠但不阻塞 UI
    #[test]
    fn test_thread_sleep() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var t0 = java.currentTimeMillis();
                java.threadSleep(30);
                var dt = java.currentTimeMillis() - t0;
                JSON.stringify({ ok: dt >= 25, fns: typeof java.threadSleep });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"ok\":true"), "got: {result}");
    }

    /// 第二批兼容别名：HMacBase64 / base64Decoder / hexEncodeToString / sleep
    #[test]
    fn test_alias_batch_hmac_base64_decoder_hex_sleep() {
        let engine = make_engine();
        // HMacBase64：JCA 风格算法名 "HMAC-SHA1" 必须与 hmacBase64("SHA1") 等价
        // （#135 阅文 QDSign：java.HMacBase64(sign, "HMAC-SHA1", aid).slice(0, -4)）
        let eq = engine
            .eval(
                "java.HMacBase64('hello', 'HMAC-SHA1', 'key') === java.hmacBase64('hello', 'SHA1', 'key')",
            )
            .unwrap();
        assert_eq!(
            eq, "true",
            "HMacBase64(HMAC-SHA1) 应与 hmacBase64(SHA1) 等价"
        );
        let sliced = engine
            .eval("java.HMacBase64('hello', 'HMAC-SHA1', 'key').slice(0, -4)")
            .unwrap();
        assert!(!sliced.starts_with("[ERROR]"), "got: {sliced}");

        // base64Decoder == base64Decode（#561 兼容 shim）
        assert_eq!(
            engine.eval("java.base64Decoder('aGVsbG8=')").unwrap(),
            "hello"
        );
        assert_eq!(
            engine
                .eval("java.base64Decoder('aGVsbG8=') === java.base64Decode('aGVsbG8=')")
                .unwrap(),
            "true"
        );

        // hexEncodeToString == hexEncode（#324 长佩，小写 hex）
        assert_eq!(engine.eval("java.hexEncodeToString('hi')").unwrap(), "6869");
        assert_eq!(
            engine
                .eval("java.hexEncodeToString('hi') === java.hexEncode('hi')")
                .unwrap(),
            "true"
        );

        // sleep（#45 露西弗俱乐部）：真实休眠 + 负值钳制为 0 立即返回
        // （30s 上限与 threadSleep 同一 clamp 表达式，负值路径覆盖钳制下界）
        let r = engine
            .eval(
                r#"
                var t0 = java.currentTimeMillis();
                java.sleep(30);
                var dt = java.currentTimeMillis() - t0;
                var t1 = java.currentTimeMillis();
                java.sleep(-5);
                var dt2 = java.currentTimeMillis() - t1;
                JSON.stringify({ ok: dt >= 25, fast: dt2 < 500 });
                "#,
            )
            .unwrap();
        assert!(r.contains("\"ok\":true"), "got: {r}");
        assert!(r.contains("\"fast\":true"), "got: {r}");
    }

    /// java.inflateRawBytes（上游 zip Inflater 流宿主）+ 完整 wrInflateRaw 流程
    #[test]
    fn test_inflate_raw_bytes_and_zip_shim() {
        let engine = make_engine();
        let payload = b"01234567890123456789"; // 20 字节
        let mut enc = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::fast());
        enc.write_all(payload).unwrap();
        let compressed = enc.finish().unwrap();
        let bytes_js: String = compressed
            .iter()
            .map(|b| b.to_string())
            .collect::<Vec<_>>()
            .join(",");

        // 宿主直接调用
        use std::io::Write;
        let r1 = engine
            .eval(&format!(
                r#"
                var bytes = new Uint8Array([{}]);
                var out = java.inflateRawBytes(bytes);
                JSON.stringify({{ len: out.length, head: out[0] }});
                "#,
                bytes_js
            ))
            .unwrap();
        assert!(r1.contains("\"len\":20"), "got: {r1}");
        assert!(r1.contains("\"head\":48"), "got: {r1}");

        // 上游语料 wrInflateRaw 的完整 Packages 流（L6134-6148）
        let r2 = engine
            .eval(&format!(
                r#"
                var P = Packages.java;
                var bytes = new Uint8Array([{}]);
                var inflater = new P.util.zip.Inflater(true);
                var bin = new P.io.ByteArrayInputStream(bytes);
                var stream = new P.util.zip.InflaterInputStream(bin, inflater);
                var output = new P.io.ByteArrayOutputStream();
                var buffer = P.nio.ByteBuffer.allocate(8192).array();
                var n;
                var total = 0;
                while ((n = stream.read(buffer)) !== -1) {{
                    output.write(buffer, 0, n);
                    total += n;
                }}
                var res = output.toByteArray();
                stream.close();
                inflater.end();
                output.close();
                JSON.stringify({{ total: total, len: res.length, head: res[0], tail: res[res.length - 1] }});
                "#,
                bytes_js
            ))
            .unwrap();
        assert!(r2.contains("\"total\":20"), "got: {r2}");
        assert!(r2.contains("\"len\":20"), "got: {r2}");
        assert!(r2.contains("\"head\":48"), "got: {r2}");
        assert!(r2.contains("\"tail\":57"), "got: {r2}");

        // 非 deflate 数据 → 可捕获异常
        let r3 = engine
            .eval(
                r#"
                var t = false;
                try { java.inflateRawBytes(new Uint8Array([1, 2, 3, 4])); } catch (e) { t = true; }
                t;
                "#,
            )
            .unwrap();
        assert_eq!(r3, "true");
    }

    /// 队列末项 java.io.InputStream 最小面（favcomic decode 路径，索引 703）：
    /// 内存字节缓冲读流——new/普通调用双 instanceof、.prototype.read 直接访问
    ///（favcomic 混淆体的 Java 式类型探测点）、read(buffer) 就地填充、
    /// read() 单字节、read(b,off,len) 子区间、plain-Array 就地写（nio ByteBuffer
    /// .array() 读缓冲）、skip/reset/available/EOF/空输入/超大 count 截断、
    /// null buffer 退化为单字节。Java 语义边界（构造拷贝/TypedArray 就地写/
    /// 越界抛错/len==0/字符串输入/mark 复位）与实例哨兵（未覆盖成员回落可读
    /// 文案+台账登记）见 test_packages_shim_input_stream_java_semantics 与
    /// test_packages_shim_input_stream_capability_ledger。
    #[test]
    fn test_packages_shim_input_stream() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var P = Packages.java;
                var IS = P.io.InputStream;
                // 构造 + instanceof（new 与普通调用双支持）
                var sNew = new IS(new Uint8Array([1,2,3,4,5,6,7,8]));
                var sCall = IS(new Uint8Array([9,10,11]));
                var viaNew = sNew instanceof IS;
                var viaCall = sCall instanceof IS;
                // favcomic 混淆体探测点：.prototype 直接访问
                var protoRead = typeof IS.prototype.read === 'function';
                var protoCtorName = IS.name === 'JSInputStream';
                // read() 单字节序列
                var b0 = sNew.read();
                var b1 = sNew.read();
                // read(buffer) 就地填充 Uint8Array
                var buf = new Uint8Array(3);
                var n1 = sNew.read(buf);
                var bufVals = [buf[0], buf[1], buf[2]];
                // read(buffer, off, count) 子区间（off=1 count=2）
                var s3 = new IS(new Uint8Array([100,200,150,50]));
                var sub = new Uint8Array(4);
                var n2 = s3.read(sub, 1, 2);
                var subVals = [sub[0], sub[1], sub[2], sub[3]];
                // plain-Array 就地写（nio ByteBuffer.array() 读缓冲场景）
                var s4 = new IS(new Uint8Array([7,8,9]));
                var arr = new Array(3);
                var n3 = s4.read(arr);
                var arrVals = [arr[0], arr[1], arr[2]];
                // skip / available / reset / EOF
                var s5 = new IS(new Uint8Array([1,2,3]));
                var skipped = s5.skip(1);
                var availAfterSkip = s5.available();
                var nextByte = s5.read();
                s5.reset();
                var availAfterReset = s5.available();
                s5.read(); s5.read(); s5.read();
                var nEof = s5.read();
                // 空输入：available 0，read 立即 -1
                var sEmpty = new IS(new Uint8Array([]));
                var emptyAvail = sEmpty.available();
                var emptyRead = sEmpty.read();
                // 超大 count 截断到剩余量
                var s6 = new IS(new Uint8Array([1,2]));
                var big = new Uint8Array(10);
                var nBig = s6.read(big, 0, 10);
                var bigVals = [big[0], big[1]];
                // null buffer 退化为单字节读
                var s7 = new IS(new Uint8Array([42,43]));
                var singleFromNull = s7.read(null);
                JSON.stringify({
                    viaNew: viaNew, viaCall: viaCall,
                    protoRead: protoRead, ctorName: protoCtorName,
                    b0: b0, b1: b1, n1: n1, bufVals: bufVals,
                    n2: n2, subVals: subVals,
                    n3: n3, arrVals: arrVals,
                    skipped: skipped, availAfterSkip: availAfterSkip,
                    nextByte: nextByte, availAfterReset: availAfterReset,
                    nEof: nEof, emptyAvail: emptyAvail, emptyRead: emptyRead,
                    nBig: nBig, bigVals: bigVals, singleFromNull: singleFromNull
                });
                "#,
            )
            .unwrap();
        assert!(
            result.contains("\"viaNew\":true"),
            "new 实例应 instanceof：{result}"
        );
        assert!(
            result.contains("\"viaCall\":true"),
            "普通调用实例应 instanceof：{result}"
        );
        assert!(
            result.contains("\"protoRead\":true"),
            ".prototype.read 应可直接访问（favcomic 探测点）：{result}"
        );
        assert!(
            result.contains("\"ctorName\":true"),
            "构造器应为 JSInputStream：{result}"
        );
        assert!(
            result.contains("\"b0\":1") && result.contains("\"b1\":2"),
            "单字节序列：{result}"
        );
        assert!(
            result.contains("\"n1\":3"),
            "read(buffer) 应读入 3 字节：{result}"
        );
        assert!(
            result.contains("[3,4,5]"),
            "read(buffer) 就地填充 [3,4,5]：{result}"
        );
        assert!(
            result.contains("\"n2\":2"),
            "read(b,off,len) 子区间读 2 字节：{result}"
        );
        assert!(
            result.contains("[0,100,200,0]"),
            "子区间 off=1 写 [·,100,200,·]：{result}"
        );
        assert!(
            result.contains("\"n3\":3"),
            "plain-Array 就地写 3 字节：{result}"
        );
        assert!(
            result.contains("[7,8,9]"),
            "plain-Array 收到 [7,8,9]：{result}"
        );
        assert!(result.contains("\"skipped\":1"), "skip(1)：{result}");
        assert!(
            result.contains("\"availAfterSkip\":2"),
            "skip 后可读 2：{result}"
        );
        assert!(
            result.contains("\"nextByte\":2"),
            "skip 后读 index1=2：{result}"
        );
        assert!(
            result.contains("\"availAfterReset\":3"),
            "reset 后可读 3：{result}"
        );
        assert!(
            result.contains("\"nEof\":-1"),
            "耗尽后 read 应 -1：{result}"
        );
        assert!(
            result.contains("\"emptyAvail\":0"),
            "空流 available 0：{result}"
        );
        assert!(
            result.contains("\"emptyRead\":-1"),
            "空流 read 立即 -1：{result}"
        );
        assert!(
            result.contains("\"nBig\":2"),
            "超大 count 截断到剩余 2：{result}"
        );
        assert!(result.contains("[1,2]"), "截断后读入 [1,2]：{result}");
        assert!(
            result.contains("\"singleFromNull\":42"),
            "null buffer 退化单字节：{result}"
        );
    }

    /// 能力清单断言：`java.io.InputStream` 已实现面（类级读取 / new /
    /// read/close 等已实现成员）不登记、不抛；实例未覆盖成员（readAllBytes
    /// 等）经实例哨兵回落「读取安全 + 调用可读文案 + 台账登记」（`java.io.InputStream.`
    /// 前缀键）；真正未实现的符号（`java.io.PrintStream`）仍走「可读文案 +
    /// 台账登记」路径。
    #[test]
    fn test_packages_shim_input_stream_capability_ledger() {
        use crate::host_api::capability_ledger as ledger;
        let _lock = ledger::LEDGER_TEST_LOCK.lock().unwrap();
        ledger::reset_unknown_java_symbols();
        let engine = make_engine();

        // 已实现面：类级读取 / new / 已实现成员（read/close）均不登记、不抛错
        let ok = engine
            .eval(
                r#"
                var P = Packages.java;
                var t = false;
                try {
                  var s = new P.io.InputStream(new Uint8Array([1]));
                  s.read(); s.close();
                } catch (e) { t = true; }
                JSON.stringify({ threw: t, isFn: typeof P.io.InputStream === 'function' });
                "#,
            )
            .unwrap();
        assert!(
            ok.contains("\"threw\":false"),
            "InputStream 应可用不抛：{ok}"
        );
        assert!(ok.contains("\"isFn\":true"), "InputStream 应为函数：{ok}");
        // 前缀匹配（审查修）：类级/实例级未覆盖成员登记键形如
        // `java.io.InputStream.<成员>`，精确等值断言会漏掉后缀键。
        assert!(
            !ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym.starts_with("java.io.InputStream")),
            "已实现的 java.io.InputStream 面不应登记进能力台账"
        );

        // 实例哨兵（审查修）：实例未覆盖成员读取安全（登记
        // `java.io.InputStream.readAllBytes`），调用抛「可读文案」（登记
        // `java.io.InputStream.readAllBytes()`）——不再静默 undefined。
        let inst = engine
            .eval(
                r#"
                var s = new Packages.java.io.InputStream(new Uint8Array([1]));
                var tt = typeof s.readAllBytes;
                var m = '';
                try { s.readAllBytes(); } catch (e) { m = String(e); }
                JSON.stringify({ tt: tt, m: m });
                "#,
            )
            .unwrap();
        assert!(
            inst.contains("\"tt\":\"function\""),
            "实例未覆盖成员读取应返回哨兵函数（探针安全）：{inst}"
        );
        assert!(
            inst.contains("此书源需要 Java 脚本能力（Packages.java.io.InputStream.readAllBytes）"),
            "实例未覆盖成员调用应抛可读文案：{inst}"
        );
        assert!(
            ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym == "java.io.InputStream.readAllBytes"),
            "实例未覆盖成员读取应登记 java.io.InputStream.readAllBytes"
        );

        // 未实现符号：读取即登记（P2-E 读取语义，哨兵不抛）；new/调用才抛「可读文案」。
        // 这里用 `new` 触发 construct 陷阱 → 抛可读文案 + 台账登记。
        let msg = engine
            .eval(
                r#"
                var m = '';
                try { new Packages.java.io.PrintStream(); } catch (e) { m = String(e); }
                m;
                "#,
            )
            .unwrap();
        assert!(
            msg.contains("Java 脚本能力"),
            "未实现符号 new 应抛可读文案（能力清单提示）：{msg}"
        );
        assert!(
            msg.contains("java.io.PrintStream"),
            "可读文案应点名缺失符号：{msg}"
        );
        assert!(
            ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym == "java.io.PrintStream"),
            "未实现符号 java.io.PrintStream 应登记进能力台账"
        );
        ledger::reset_unknown_java_symbols();
    }

    /// Java 语义边界（审查修，精确实断言）：① 构造拷贝不别名（调用方篡改
    /// buffer 不污染流内容）；② 全部 TypedArray（Int8Array）就地写；
    /// ③ 越界（off+len>长度）抛可读 RangeError 而非静默截断；④ len==0 读 0
    /// 字节（即使 EOF），EOF 且 c>0 读 -1；⑤ 字符串 / java.lang.String 输入
    /// 经 java.strToBytes 转 UTF-8 字节（绝不静默空流）；⑥ mark/reset 按
    /// Java 语义回到 mark 位置（ByteArrayInputStream 同款，未 mark 即 0）；
    /// ⑦ 实例未覆盖成员（transferTo/markSupported）回落类级同款哨兵文案，
    /// 台账登记 `java.io.InputStream.` 前缀键。
    #[test]
    fn test_packages_shim_input_stream_java_semantics() {
        use crate::host_api::capability_ledger as ledger;
        let _lock = ledger::LEDGER_TEST_LOCK.lock().unwrap();
        let engine = make_engine();
        ledger::reset_unknown_java_symbols();

        let result = engine
            .eval(
                r#"
                var P = Packages.java;
                var IS = P.io.InputStream;
                // ① 构造拷贝不别名
                var src = new Uint8Array([1, 2, 3]);
                var s1 = new IS(src);
                src[0] = 99;
                var copyOk = s1.read() === 1;
                // ② Int8Array（非 Uint8Array 的 TypedArray）就地写
                var s2 = new IS(new Uint8Array([5, 6, 7]));
                var t8 = new Int8Array(3);
                var typedN = s2.read(t8);
                var typedVals = [t8[0], t8[1], t8[2]];
                // ③ 越界（off=1, len=5, 缓冲长度 2）抛可读 RangeError
                var s3 = new IS(new Uint8Array([1, 2, 3]));
                var oobMsg = '';
                try { s3.read(new Uint8Array(2), 1, 5); } catch (e) { oobMsg = e.message; }
                // ④ len==0 读 0 字节（流中 / EOF 均 0）；EOF 且 c>0 读 -1
                var s4 = new IS(new Uint8Array([7]));
                var zeroMid = s4.read(new Uint8Array(4), 0, 0);
                var consumed = s4.read();
                var zeroAtEof = s4.read(new Uint8Array(4), 0, 0);
                var eofRead = s4.read(new Uint8Array(4), 0, 4);
                // ⑤ 字符串 / java.lang.String 输入转字节（绝不静默空流）
                var sStr = new IS('abc');
                var strVals = [sStr.read(), sStr.read(), sStr.read(), sStr.read()];
                var sJStr = new IS(new P.lang.String('ab'));
                var jStrVals = [sJStr.read(), sJStr.read(), sJStr.read()];
                // ⑥ mark/reset 回到 mark 位置（Java ByteArrayInputStream 语义）：
                // read→10(pos=1)、mark(mark=1)、read→20(pos=2)、reset(pos=1)、
                // read→_bytes[1]=20。区别于 no-op（pos 停 2 → 30）与 reset→0（→10）。
                var s5 = new IS(new Uint8Array([10, 20, 30]));
                s5.read(); s5.mark(); s5.read(); s5.reset();
                var markResetVal = s5.read();
                // ⑦ 实例未覆盖成员回落类级同款哨兵
                var s8 = new IS(new Uint8Array([1]));
                var ttType = typeof s8.transferTo;
                var ttMsg = '';
                try { s8.transferTo(null); } catch (e) { ttMsg = e.message; }
                var msType = typeof s8.markSupported;
                JSON.stringify({
                    copyOk: copyOk,
                    typedN: typedN, typedVals: typedVals,
                    oobMsg: oobMsg,
                    zeroMid: zeroMid, consumed: consumed,
                    zeroAtEof: zeroAtEof, eofRead: eofRead,
                    strVals: strVals, jStrVals: jStrVals,
                    markResetVal: markResetVal,
                    ttType: ttType, ttMsg: ttMsg, msType: msType
                });
                "#,
            )
            .expect("InputStream Java 语义探测失败");

        let v: serde_json::Value = serde_json::from_str(&result).expect("JSON 解析失败: {result}");
        assert_eq!(
            v["copyOk"], true,
            "构造应拷贝输入（调用方篡改不污染流）：{result}"
        );
        assert_eq!(v["typedN"], 3, "Int8Array 应就地读入 3 字节：{result}");
        assert_eq!(
            v["typedVals"],
            serde_json::json!([5, 6, 7]),
            "Int8Array 应就地收到 [5,6,7]：{result}"
        );
        assert_eq!(
            v["oobMsg"], "java.io.InputStream.read: 越界（off=1, len=5，缓冲长度 2）",
            "越界应抛可读 RangeError（不静默截断）：{result}"
        );
        assert_eq!(v["zeroMid"], 0, "len==0 应读 0 字节（流中）：{result}");
        assert_eq!(v["consumed"], 7, "单字节读应得 7：{result}");
        assert_eq!(
            v["zeroAtEof"], 0,
            "len==0 在 EOF 也应返回 0（Java 语义）：{result}"
        );
        assert_eq!(v["eofRead"], -1, "EOF 且 c>0 应读 -1：{result}");
        assert_eq!(
            v["strVals"],
            serde_json::json!([97, 98, 99, -1]),
            "字符串输入应转 UTF-8 字节 [97,98,99]（非静默空流）：{result}"
        );
        assert_eq!(
            v["jStrVals"],
            serde_json::json!([97, 98, -1]),
            "java.lang.String 输入应转字节 [97,98]（非静默空流）：{result}"
        );
        assert_eq!(
            v["markResetVal"], 20,
            "mark/reset 应回到 mark 位置：{result}"
        );
        assert_eq!(
            v["ttType"], "function",
            "实例未覆盖成员（transferTo）读取应返回哨兵函数：{result}"
        );
        assert_eq!(
            v["ttMsg"],
            "此书源需要 Java 脚本能力（Packages.java.io.InputStream.transferTo），当前不支持",
            "实例未覆盖成员调用应抛可读文案：{result}"
        );
        assert_eq!(
            v["msType"], "function",
            "实例未覆盖成员（markSupported）读取应返回哨兵函数：{result}"
        );
        assert!(
            ledger::unknown_java_symbols()
                .iter()
                .any(|(sym, _)| sym == "java.io.InputStream.transferTo"),
            "实例未覆盖成员读取应登记 java.io.InputStream.transferTo"
        );
        ledger::reset_unknown_java_symbols();
    }

    /// Packages shim 扩面：java.lang.* / java.util.* / java.nio / zip / io
    #[test]
    fn test_packages_shim_lang_util() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var P = Packages.java;
                var map = new P.util.HashMap();
                map.put('k', 'v');
                map.put('k2', 2);
                var ts = P.lang.System.currentTimeMillis();
                var cp = P.util.Arrays.copyOf(new Uint8Array([1, 2, 3, 4, 5]), 3);
                var threw = false;
                try { P.lang.Integer.parseInt('abc'); } catch (e) { threw = true; }
                JSON.stringify({
                    mapGet: map.get('k'),
                    mapSize: map.size(),
                    mapJson: JSON.stringify(map),
                    valueOf: P.lang.String.valueOf(123),
                    parseInt: P.lang.Integer.parseInt('42'),
                    parseLong: P.lang.Long.parseLong('99'),
                    parseDouble: P.lang.Double.parseDouble('3.5'),
                    parseBoolean: P.lang.Boolean.parseBoolean('TRUE'),
                    isNow: typeof ts === 'number',
                    cpLen: cp.length,
                    cp0: cp[0],
                    parseIntThrows: threw,
                    nioLen: P.nio.ByteBuffer.allocate(4).array().length
                });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"mapGet\":\"v\""), "got: {result}");
        assert!(result.contains("\"mapSize\":2"), "got: {result}");
        assert!(result.contains("\"valueOf\":\"123\""), "got: {result}");
        assert!(result.contains("\"parseInt\":42"), "got: {result}");
        assert!(result.contains("\"parseLong\":99"), "got: {result}");
        assert!(result.contains("\"parseDouble\":3.5"), "got: {result}");
        assert!(result.contains("\"parseBoolean\":true"), "got: {result}");
        assert!(result.contains("\"isNow\":true"), "got: {result}");
        assert!(result.contains("\"cpLen\":3"), "got: {result}");
        assert!(result.contains("\"cp0\":1"), "got: {result}");
        assert!(result.contains("\"parseIntThrows\":true"), "got: {result}");
        assert!(result.contains("\"nioLen\":4"), "got: {result}");
    }

    /// P2-11 §195：java.lang parse 近似对齐——配对实验（旧 shim 值 → JDK 严格值）
    ///
    /// 上游真值：Rhino LiveConnect 调真实 java.lang 方法（AnalyzeRule.kt
    /// L895 `bindings["java"] = this`；`java.lang` 不在 JsExtensions 字段
    /// 面 → `Packages.java` classpath 设施，P2-9 ⑫ 类；JDK javadoc 语义）：
    /// - `Integer.parseInt("12abc")` → NumberFormatException（旧 shim 用
    ///   JS 前缀解析 → 12）；int32 溢出抛错；radix 越界抛错
    /// - `Long.parseLong("12abc")` → 抛错（旧 shim → 12）；"0x10" → 抛错
    ///   （1 参仅十进制；旧 shim → 16）；long64 范围字符串精确判定
    /// - `Double.parseDouble("NaN")` → NaN 值（旧 shim 抛错）；" 3.5" →
    ///   抛错（JS Number 容忍前导空白，旧 shim → 3.5）；"0x1.8p1" → 3.0
    ///   （JS Number 返回 NaN，旧 shim 抛错）；"1e400" → Infinity（非抛错）
    /// - `Boolean.parseBoolean(" true ")` → false（Java 不 trim；旧 shim
    ///   误 trim → true）
    #[test]
    fn test_packages_shim_lang_parse_strict_semantics() {
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var L = Packages.java.lang;
                function thr(fn) { try { fn(); return false; } catch (e) { return true; } }
                function val(fn) { try { return fn(); } catch (e) { return null; } }
                JSON.stringify({
                    // Integer.parseInt 严格全串 + int32 范围
                    pInt12abcThrows: thr(function(){ L.Integer.parseInt('12abc'); }),
                    pIntWsThrows: thr(function(){ L.Integer.parseInt(' 12'); }),
                    pIntPlus: val(function(){ return L.Integer.parseInt('+42'); }),
                    pIntHex16: val(function(){ return L.Integer.parseInt('ff', 16); }),
                    pIntOctal8: val(function(){ return L.Integer.parseInt('17', 8); }),
                    pIntOverflowThrows: thr(function(){ L.Integer.parseInt('2147483648'); }),
                    pIntMinOk: val(function(){ return L.Integer.parseInt('-2147483648'); }),
                    pIntRadixThrows: thr(function(){ L.Integer.parseInt('42', 1); }),
                    // Long.parseLong 严格十进制 + long64 范围
                    pLong12abcThrows: thr(function(){ L.Long.parseLong('12abc'); }),
                    pLongHexThrows: thr(function(){ L.Long.parseLong('0x10'); }),
                    pLongWsThrows: thr(function(){ L.Long.parseLong(' 12'); }),
                    pLongZeroPad: val(function(){ return L.Long.parseLong('0007'); }),
                    // long64 边界：float64 近似值（JS 无 int64；Rhino LiveConnect
                    // 也自动把 Long 转 JS number——登记残余近似）。用引擎内 ===
                    // 与 ±2^63 精确比较（QuickJS 的 JSON.stringify 按 15 位有效
                    // 数字显示 2^63 → 9223372036854776000，不可用于断言原文）
                    pLongMax: L.Long.parseLong('9223372036854775807') === 9223372036854775808,
                    pLongOverflowThrows: thr(function(){ L.Long.parseLong('9223372036854775808'); }),
                    pLongNegMin: L.Long.parseLong('-9223372036854775808') === -9223372036854775808,
                    // Double.parseDouble NaN/Infinity/hex-float/空白/下划线/尾缀
                    pdNaNIsNaN: isNaN(L.Double.parseDouble('NaN')),
                    pdPosInf: L.Double.parseDouble('Infinity') === Infinity,
                    pdNegInf: L.Double.parseDouble('-Infinity') === -Infinity,
                    pdWsThrows: thr(function(){ L.Double.parseDouble(' 3.5'); }),
                    pdUnderThrows: thr(function(){ L.Double.parseDouble('1_000'); }),
                    pdSuffixOk: val(function(){ return L.Double.parseDouble('3.5f'); }),
                    pdHexFloat: val(function(){ return L.Double.parseDouble('0x1.8p1'); }),
                    pdHexNoP: val(function(){ return L.Double.parseDouble('0x10'); }),
                    pdHexFracOnly: val(function(){ return L.Double.parseDouble('0x.8p1'); }),
                    pdOverflowInf: L.Double.parseDouble('1e400') === Infinity,
                    pdEmptyThrows: thr(function(){ L.Double.parseDouble(''); }),
                    pdLowerNaNThrows: thr(function(){ L.Double.parseDouble('nan'); }),
                    // Boolean.parseBoolean 不 trim + null → false
                    pbTrimmedFalse: L.Boolean.parseBoolean(' true ') === false,
                    pbUpperTrue: L.Boolean.parseBoolean('TRUE') === true,
                    pbNullFalse: L.Boolean.parseBoolean(null) === false
                });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"pInt12abcThrows\":true"), "got: {result}");
        assert!(result.contains("\"pIntWsThrows\":true"), "got: {result}");
        assert!(result.contains("\"pIntPlus\":42"), "got: {result}");
        assert!(result.contains("\"pIntHex16\":255"), "got: {result}");
        assert!(result.contains("\"pIntOctal8\":15"), "got: {result}");
        assert!(
            result.contains("\"pIntOverflowThrows\":true"),
            "got: {result}"
        );
        assert!(
            result.contains("\"pIntMinOk\":-2147483648"),
            "got: {result}"
        );
        assert!(result.contains("\"pIntRadixThrows\":true"), "got: {result}");
        assert!(
            result.contains("\"pLong12abcThrows\":true"),
            "got: {result}"
        );
        assert!(result.contains("\"pLongHexThrows\":true"), "got: {result}");
        assert!(result.contains("\"pLongWsThrows\":true"), "got: {result}");
        assert!(result.contains("\"pLongZeroPad\":7"), "got: {result}");
        assert!(result.contains("\"pLongMax\":true"), "got: {result}");
        assert!(
            result.contains("\"pLongOverflowThrows\":true"),
            "got: {result}"
        );
        assert!(result.contains("\"pLongNegMin\":true"), "got: {result}");
        assert!(result.contains("\"pdNaNIsNaN\":true"), "got: {result}");
        assert!(result.contains("\"pdPosInf\":true"), "got: {result}");
        assert!(result.contains("\"pdNegInf\":true"), "got: {result}");
        assert!(result.contains("\"pdWsThrows\":true"), "got: {result}");
        assert!(result.contains("\"pdUnderThrows\":true"), "got: {result}");
        assert!(result.contains("\"pdSuffixOk\":3.5"), "got: {result}");
        assert!(result.contains("\"pdHexFloat\":3"), "got: {result}");
        assert!(result.contains("\"pdHexNoP\":16"), "got: {result}");
        assert!(result.contains("\"pdHexFracOnly\":1"), "got: {result}");
        assert!(result.contains("\"pdOverflowInf\":true"), "got: {result}");
        assert!(result.contains("\"pdEmptyThrows\":true"), "got: {result}");
        assert!(
            result.contains("\"pdLowerNaNThrows\":true"),
            "got: {result}"
        );
        assert!(result.contains("\"pbTrimmedFalse\":true"), "got: {result}");
        assert!(result.contains("\"pbUpperTrue\":true"), "got: {result}");
        assert!(result.contains("\"pbNullFalse\":true"), "got: {result}");
    }

    /// 全局 cache 对象（对齐 WebCacheManager）：记忆三件套 + 磁盘/文件缓存
    ///
    /// P2-11 ②：取磁盘层测试串行锁——cache_store 注入目录测试会切换
    /// INJECTED_DIR/env/清理临时目录，互斥防止目录切换/清理干扰本测试
    /// 磁盘读写。
    #[test]
    fn test_cache_global_roundtrip() {
        let _lock = crate::host_api::cache_store::lock_cache_for_test();
        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var K = 'p29-test-' + java.currentTimeMillis() + '-' + Math.floor(Math.random() * 1e9);
                cache.putMemory(K, 'mem-val');
                var m = cache.getFromMemory(K);
                cache.put(K, 'disk-val', 3600);
                var d = cache.get(K);
                cache.deleteMemory(K);
                var m2 = cache.getFromMemory(K);
                var f = cache.getFile(K);
                cache.putFile(K, 'file-val');
                var f2 = cache.getFile(K);
                cache.delete(K);
                var d2 = cache.get(K);
                var f3 = cache.getFile(K);
                JSON.stringify({
                    m: m, d: d, m2: m2, f: f, f2: f2, d2: d2, f3: f3,
                    tPut: typeof cache.put, tGet: typeof cache.get
                });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"m\":\"mem-val\""), "got: {result}");
        assert!(result.contains("\"d\":\"disk-val\""), "got: {result}");
        assert!(result.contains("\"m2\":null"), "got: {result}");
        assert!(result.contains("\"f\":null"), "got: {result}");
        assert!(result.contains("\"f2\":\"file-val\""), "got: {result}");
        assert!(result.contains("\"d2\":null"), "got: {result}");
        assert!(result.contains("\"f3\":null"), "got: {result}");
        assert!(result.contains("\"tPut\":\"function\""), "got: {result}");
    }

    /// 队列④①：未知 Java 符号 → 能力台账登记 + 可读错误文案
    ///
    /// 能力清单未覆盖的类/成员被访问时：
    /// 1) 符号全名登记进 `capability_ledger`（进程可查询，供"下一批补什么"决策）；
    /// 2) P2-E 读取语义：读取未知成员只登记并返回可探测哨兵（不抛错）；
    ///    调用 / new / 取子成员才抛带明确文案的错误「此书源需要 Java 脚本能力（…），
    ///    当前不支持」，经 `LegadoError::JsEngine` 进入搜索批次错误通道向用户可见。
    #[test]
    fn test_unknown_java_symbol_recorded_and_message() {
        use crate::host_api::capability_ledger;

        let _lock = capability_ledger::LEDGER_TEST_LOCK.lock().unwrap();
        capability_ledger::reset_unknown_java_symbols();

        let engine = make_engine();

        // Packages 根下未知类：读取只登记 `foo`（哨兵，不抛错）；
        // 取子成员 `.bar` 才抛带文案错误（错误串含完整路径 Packages.foo.bar）
        assert!(
            engine.eval("var s = Packages.foo;").is_ok(),
            "P2-E：读取未知类应只登记哨兵、不抛错"
        );
        let err = engine.eval("Packages.foo.bar;").unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（Packages.foo.bar）"),
            "got: {err}"
        );
        assert!(
            capability_ledger::unknown_java_symbols()
                .iter()
                .any(|(k, _)| k == "foo"),
            "未知符号 foo 应登记台账：{:?}",
            capability_ledger::unknown_java_symbols()
        );
        assert!(
            capability_ledger::unknown_java_symbols()
                .iter()
                .any(|(k, _)| k == "foo.bar"),
            "取子成员符号 foo.bar 应登记台账：{:?}",
            capability_ledger::unknown_java_symbols()
        );

        // 已知子树下的未知成员：读取只登记完整路径（哨兵）；
        // new 实例化才抛带文案错误
        assert!(
            engine
                .eval("var s2 = Packages.java.lang.NoSuchClass;")
                .is_ok(),
            "P2-E：已知子树下未知成员读取应只登记、不抛错"
        );
        let err = engine
            .eval("new Packages.java.lang.NoSuchClass();")
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（Packages.java.lang.NoSuchClass）"),
            "got: {err}"
        );
        assert!(capability_ledger::unknown_java_symbols()
            .iter()
            .any(|(k, _)| k == "java.lang.NoSuchClass"));

        // Java.type 哨兵：登记 `Java.type(<name>)` + 抛错
        let err = engine.eval("Java.type('com.x.Y');").unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（Java.type(com.x.Y)）"),
            "got: {err}"
        );
        assert!(capability_ledger::unknown_java_symbols()
            .iter()
            .any(|(k, _)| k == "Java.type(com.x.Y)"));

        // importClass 哨兵：登记 `importClass(<cls>)` + 抛错
        let err = engine.eval("importClass('com.x.Z');").unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（importClass(com.x.Z)）"),
            "got: {err}"
        );
        assert!(capability_ledger::unknown_java_symbols()
            .iter()
            .any(|(k, _)| k == "importClass(com.x.Z)"));

        // 四个未知符号各登记一次——以上四个 contains 断言即逐符号验证；
        // 不做精确全量计数断言：同进程并行测试可能并发登记其他未知符号
        // （噪声免疫），本测试结束也不做 reset（避免抹掉并行测试的登记）
    }

    /// 队列④ P2-E：未知类哨兵的探测安全语义
    ///
    /// 读取探测（typeof / 真值 / in / 探测三元）不抛错——语料命中 1 处
    /// `typeof Packages` 三元回退式代码（RHINO_INTEROP_ANALYSIS_20260920 §8）；
    /// 调用 / new / 取子成员仍抛带明确文案的错误（提示保留在真正使用点）。
    #[test]
    fn test_unknown_class_sentinel_probe_safe() {
        use crate::host_api::capability_ledger;

        let _lock = capability_ledger::LEDGER_TEST_LOCK.lock().unwrap();

        let engine = make_engine();

        // typeof 探测：哨兵目标为函数 → 'function'，不抛错
        let r = engine
            .eval("typeof Packages.foo === 'function' ? 'fn' : 'other'")
            .unwrap();
        assert!(r.contains("fn"), "哨兵 typeof 应为 function: {r}");

        // 真值探测：对象代理为 truthy，不抛错
        let r = engine
            .eval("if (Packages.foo) { 'truthy' } else { 'falsy' }")
            .unwrap();
        assert!(r.contains("truthy"), "哨兵应为 truthy: {r}");

        // in 检查：has 陷阱返回 false，不抛错
        let r = engine.eval("'x' in Packages.foo ? 1 : 2").unwrap();
        assert!(r.contains("2"), "'x' in 哨兵 应为 false: {r}");

        // 语料命中的探测三元形态（`typeof Packages` 回退式）：整式完成不中断
        let r = engine
            .eval("typeof Packages.foo === 'undefined' ? 'absent' : 'present'")
            .unwrap();
        assert!(r.contains("present"), "探测三元应正常完成: {r}");

        // 调用：apply 陷阱抛带文案错误 + 登记 `foo()`
        let err = engine.eval("Packages.foo();").unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（Packages.foo）"),
            "got: {err}"
        );
        assert!(capability_ledger::unknown_java_symbols()
            .iter()
            .any(|(k, _)| k == "foo()"));

        // 实例化：construct 陷阱抛带文案错误
        let err = engine.eval("new Packages.foo();").unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（Packages.foo）"),
            "got: {err}"
        );

        // 取子成员：get 陷阱抛带文案错误（含子路径）
        let err = engine.eval("Packages.foo.bar;").unwrap_err();
        assert!(
            err.to_string()
                .contains("此书源需要 Java 脚本能力（Packages.foo.bar）"),
            "got: {err}"
        );
    }

    /// 队列④③：已知能力面不误报——能力清单覆盖的类/成员访问不产生任何未知登记
    ///
    /// 若已知面误触陷阱，台账会被误报灌满、用户反复收到"需要 Java 能力"
    /// 告警。访问前后台账计数不变即为通过（相对断言，不受并行测试噪声影响）。
    #[test]
    fn test_known_java_surface_records_nothing() {
        use crate::host_api::capability_ledger;

        let _lock = capability_ledger::LEDGER_TEST_LOCK.lock().unwrap();
        let before = capability_ledger::unknown_java_symbol_count();

        let engine = make_engine();
        let result = engine
            .eval(
                r#"
                var P = Packages;
                JSON.stringify({
                    pInt: P.java.lang.Integer.parseInt('42', 10),
                    now: P.java.lang.System.currentTimeMillis() > 0,
                    b64Len: P.android.util.Base64.decode('aGk=', 0).length === 2,
                    uuidLen: P.java.util.UUID.randomUUID().toString().length === 36,
                    hasCopyOf: P.java.util.Arrays.hasOwnProperty('copyOf') === true,
                    intFn: typeof P.java.lang.Integer.parseInt === 'function',
                    jsoupObj: typeof P.org.jsoup === 'object'
                });
                "#,
            )
            .unwrap();
        assert!(result.contains("\"pInt\":42"), "got: {result}");
        assert!(result.contains("\"now\":true"), "got: {result}");
        assert!(result.contains("\"b64Len\":true"), "got: {result}");
        assert!(result.contains("\"uuidLen\":true"), "got: {result}");
        assert!(result.contains("\"hasCopyOf\":true"), "got: {result}");
        // 注意：`typeof … === '…'` 是布尔表达式，JSON 里是 true 而非类型名字符串
        assert!(result.contains("\"intFn\":true"), "got: {result}");
        assert!(result.contains("\"jsoupObj\":true"), "got: {result}");

        let after = capability_ledger::unknown_java_symbol_count();
        assert_eq!(
            before,
            after,
            "已知能力面不应登记任何未知符号：{:?}",
            capability_ledger::unknown_java_symbols()
        );
    }
}
