/// RSS 阅读 WebView `preloadJs` 宿主桥（批21b，契约 §2.5 `rssWebViewHostCall`）
///
/// 分工（对齐原版 `ReadRssActivity` + `WebJsExtensions` + `RssJsExtensions`）：
///
/// - **Rust（批21a）**：`__prepare` 生成 IIFE 头（`java`/`source`/`cache` 垫片 +
///   通道调用 + 只读快照）、`__store` 落库、宿主方法白名单执行；
/// - **Dart（本文件）**：WebView `JavaScriptChannel` 注册、`hello` 握手与
///   nonce 校验、`{nonce,id,method,args}` 协议编解码、白名单方法转发、
///   30s 超时回失败、动作（toast/log/open/...）回传、Cookie 回流，
///   以及 Rust 桥头之外的**同步面**：
///   - 纯函数摊平：`base64Encode/Decode`、`md5Encode/16`、
///     `hexEncodeToString/hexDecodeToString`、`encodeURI`（不发起 RPC）；
///   - 同步网络（`java.ajax/connect/get/post/head/webView*`）明确抛错并
///     `java.log` 留痕（平台差异，引导使用 `*Await`）；
///   - 动作摊平：`java.open/searchBook/addBook/showPhoto/openUrl` 经
///     Dart 内部动作通道 `__action` 回传，`java.getWebViewUA` 返回注入 UA。
///
/// 注入顺序（拼接到 HTML `<head>` 或 URL 模式 `onPageStarted`）：
/// console 钩子 → 通道适配/握手 → Rust 桥头 → 同步面 → `preloadJs` → `})();`
///
/// 与 Rust 桥头的约定（契约 §2.5 批21a）：`__prepare` 的 `channelName`
/// 指向**页面桥对象**（`window[channelName].request(method, argsJson, id)`），
/// 该对象由 [rssBridgeBootstrapScript] 在 Rust 脚本执行前创建；平台注入的
/// `JavaScriptChannel` 使用独立随机名（`__legado_rssNative_*`），避免覆盖
/// 平台注入对象在 iOS/Android 上不可写的问题。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart'
    show WebViewCookie, WebViewCookieManager;

import 'book_api.dart';
import 'rss_web_config.dart' show kRssConsoleHookScript;

/// 对外方法白名单（与 Rust `rss_web_bridge::PUBLIC_METHODS` 对齐）
const Set<String> kRssWebBridgeHostMethods = <String>{
  'run',
  'ajaxAwait',
  'connectAwait',
  'getAwait',
  'headAwait',
  'postAwait',
  'webViewAwait',
  'webViewGetSourceAwait',
  'decryptStrAwait',
  'encryptBase64Await',
  'encryptHexAwait',
  'createSignHexAwait',
  'downloadFileAwait',
  'readTxtFileAwait',
  'importScriptAwait',
  'getStringAwait',
};

/// Dart 内部协议方法（不进入 Rust 白名单）
const String kRssWebBridgeHelloMethod = 'hello';
const String kRssWebBridgeActionMethod = '__action';
const String kRssWebBridgeStoreMethod = '__store';

/// 宿主调用默认超时（契约 §2.5：单次执行 30s；Dart 侧兜底回失败）
const Duration kRssWebBridgeDefaultTimeout = Duration(seconds: 30);

/// 握手超时（未收到 `hello` 或 nonce 无法回填时，排队的调用按失败回填，
/// 避免页面脚本无限挂起）
const Duration kRssWebBridgeHandshakeTimeout = Duration(seconds: 10);

/// JS 执行器（由页面传入 `WebViewController.runJavaScript`）
typedef RssWebBridgeJsRunner = Future<void> Function(String javaScript);

/// JS 字面量（`jsonEncode` + U+2028/U+2029 转义，避免旧引擎断句）
String rssJsLiteral(Object? value) {
  if (value == null) return 'null';
  final encoded = jsonEncode(value);
  return encoded.replaceAll('\u2028', '\\u2028').replaceAll('\u2029', '\\u2029');
}

// ─── 协议信封 ────────────────────────────────────────────────────────────────

/// Rust 宿主调用返回的信封
/// `{"ok":bool,"value":<any>,"error":String?,"actions":[...]?}`
class RssWebBridgeEnvelope {
  const RssWebBridgeEnvelope({
    required this.ok,
    this.value,
    this.error,
    this.actions = const <Map<String, dynamic>>[],
  });

  final bool ok;
  final Object? value;
  final String? error;
  final List<Map<String, dynamic>> actions;

  /// 解析信封；非 JSON / 非对象 / 缺 `ok` 一律按失败处理（不抛异常）
  static RssWebBridgeEnvelope parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return RssWebBridgeEnvelope(ok: false, error: '宿主信封不是合法 JSON');
    }
    if (decoded is! Map) {
      return const RssWebBridgeEnvelope(ok: false, error: '宿主信封必须是 JSON 对象');
    }
    final map = Map<String, dynamic>.from(decoded);
    final actions = <Map<String, dynamic>>[];
    final rawActions = map['actions'];
    if (rawActions is List) {
      for (final item in rawActions) {
        if (item is Map) actions.add(Map<String, dynamic>.from(item));
      }
    }
    return RssWebBridgeEnvelope(
      ok: map['ok'] == true,
      value: map['value'],
      error: map['error']?.toString(),
      actions: actions,
    );
  }
}

/// `__prepare` 结果：Rust 生成的 IIFE 头 + 只读快照
class RssWebBridgePrepareResult {
  const RssWebBridgePrepareResult({
    required this.script,
    required this.snapshot,
  });

  /// Rust 桥头（未闭合 IIFE；为空串表示源未配置 `preloadJs`）
  final String script;

  /// 只读快照（`sourceUrl`/`sourceName`/`loginHeader`/`vars`/`userAgent`…）
  final Map<String, dynamic> snapshot;

  String get sourceUrl => snapshot['sourceUrl']?.toString() ?? '';
  String get sourceName => snapshot['sourceName']?.toString() ?? '';
  String get userAgent => snapshot['userAgent']?.toString() ?? '';
  String? get loginHeader => snapshot['loginHeader']?.toString();
  String? get sourceVariable => snapshot['sourceVariable']?.toString();

  /// 源变量镜像（`v_<sourceUrl>_*` 去前缀）
  Map<String, String> get vars {
    final raw = snapshot['vars'];
    if (raw is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in raw.entries)
        if (entry.key != null && entry.value != null)
          entry.key.toString(): entry.value.toString(),
    };
  }
}

/// 页面 → Dart 的动作（`java.open/toast/log/...`）
class RssWebBridgeAction {
  const RssWebBridgeAction(this.name, this.data);

  /// 动作名（`toast`/`longToast`/`log`/`open`/`searchBook`/`addBook`/
  /// `showPhoto`/`openUrl`）
  final String name;

  /// 原始载荷
  final Map<String, dynamic> data;

  String get message => (data['message'] ?? data['text'] ?? '').toString();

  String? get url {
    final value = data['url']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  String? get title {
    final value = data['title']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  String? get origin {
    final value = data['origin']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  /// `java.open` 的目标类型（`sort`/`rss`/`login`）
  String get openName => (data['name'] ?? '').toString();

  bool get isLong => name == 'longToast' || data['long'] == true;

  @override
  String toString() => 'RssWebBridgeAction($name, $data)';
}

// ─── JS：通道适配与握手 ──────────────────────────────────────────────────────

/// 通道适配 + 握手脚本（必须在 Rust 桥头之前执行）
///
/// - 用独立桥对象 `window[bridgeObjectName]` 包装平台 `JavaScriptChannel`
///   （平台注入对象不可安全覆写）；
/// - 首次 `hello` 由页面主动发出；Dart 校验后经 `window[callbackName_nonce]`
///   回填 nonce，回填前排队的请求按序放行；10s 未拿到 nonce 时，
///   排队请求经桥回调按失败结束（避免无限挂起）。
String rssBridgeBootstrapScript({
  required String nativeChannelName,
  required String bridgeObjectName,
  required String callbackName,
  Duration handshakeTimeout = kRssWebBridgeHandshakeTimeout,
}) {
  final native = jsonEncode(nativeChannelName);
  final bridge = jsonEncode(bridgeObjectName);
  final callback = jsonEncode(callbackName);
  final nonceCallback = jsonEncode('${callbackName}_nonce');
  final timeoutMs = handshakeTimeout.inMilliseconds;
  return '''
(function(){
  // [批21b] RSS WebView 宿主桥：通道适配 + hello/nonce 握手
  var __lgNative = (typeof window !== 'undefined') ? window[$native] : null;
  if (!__lgNative || typeof __lgNative.postMessage !== 'function') return;
  var __lgNonce = null;
  var __lgQueue = [];
  var __lgSend = function (method, argsJson, id) {
    __lgNative.postMessage(JSON.stringify({
      nonce: __lgNonce,
      id: id,
      method: method,
      args: argsJson
    }));
  };
  window[$bridge] = {
    request: function (method, argsJson, id) {
      var m = (method === null || method === undefined) ? '' : String(method);
      var a = (argsJson === null || argsJson === undefined) ? '[]' : String(argsJson);
      var i = (id === null || id === undefined) ? '' : String(id);
      if (__lgNonce === null) {
        __lgQueue.push({ id: i, method: m, args: a });
        return;
      }
      try { __lgSend(m, a, i); } catch (e) {}
    },
    postMessage: function (message) { return __lgNative.postMessage(message); }
  };
  window[$nonceCallback] = function (nonce) {
    if (__lgNonce !== null) return;
    __lgNonce = String(nonce);
    var queue = __lgQueue;
    __lgQueue = [];
    for (var i = 0; i < queue.length; i++) {
      var item = queue[i];
      try { __lgSend(item.method, item.args, item.id); } catch (e) {}
    }
  };
  setTimeout(function () {
    if (__lgNonce !== null) return;
    var queue = __lgQueue;
    __lgQueue = [];
    for (var i = 0; i < queue.length; i++) {
      var item = queue[i];
      if (!item.id) continue;
      try {
        var reply = window[$callback];
        if (typeof reply === 'function') {
          reply(item.id, false, '宿主桥握手超时：未收到 nonce');
        }
      } catch (e) {}
    }
  }, $timeoutMs);
  try { __lgSend('hello', '[]', ''); } catch (e) {}
})();
''';
}

// ─── JS：同步面（纯函数 + 动作摊平，无 RPC） ─────────────────────────────────

/// 同步面函数体（可独立在 JS 引擎中执行；作用域约定：
/// `__lgJava`（页面 java 对象）、`__lgAction(payload)`、`__lgUserAgent`）。
///
/// 该常量被 [rssBridgeSyncShimScript] 包裹，也被单测直接注入 Node 做向量
/// 校验（纯函数不依赖 `window`）。
const String kRssBridgeSyncShimBody = r'''
  var __lgB64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  // UTF-8 编码（代理对按 code point 处理；孤立代理项按单字节 UTF-16 值编码）
  function __lgUtf8Bytes(value) {
    var s = (value === null || value === undefined) ? '' : String(value);
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var code = s.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
        var low = s.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      } else {
        out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
                 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return out;
  }

  function __lgUtf8String(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length;) {
      var b = bytes[i++] & 0xFF;
      if (b < 0x80) {
        out += String.fromCharCode(b);
      } else if (b < 0xE0) {
        out += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i++] & 0x3F));
      } else if (b < 0xF0) {
        out += String.fromCharCode(
          ((b & 0x0F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F)
        );
      } else {
        var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3F) << 12) |
                 ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F);
        cp -= 0x10000;
        out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
      }
    }
    return out;
  }

  // Hutool Base64（UTF-8，无换行，标准字母表；解码容忍 URL-safe 与空白）
  function __lgBase64Encode(value) {
    var bytes = __lgUtf8Bytes(value);
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i];
      var b1 = i + 1 < bytes.length ? bytes[i + 1] : -1;
      var b2 = i + 2 < bytes.length ? bytes[i + 2] : -1;
      out += __lgB64Chars.charAt(b0 >> 2);
      out += __lgB64Chars.charAt(((b0 & 0x03) << 4) | ((b1 < 0 ? 0 : b1) >> 4));
      out += b1 < 0
        ? '='
        : __lgB64Chars.charAt(((b1 & 0x0F) << 2) | ((b2 < 0 ? 0 : b2) >> 6));
      out += b2 < 0 ? '=' : __lgB64Chars.charAt(b2 & 0x3F);
    }
    return out;
  }

  function __lgBase64Decode(value) {
    var s = (value === null || value === undefined) ? '' : String(value);
    s = s.replace(/[\s\r\n\t]/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4 !== 0) s += '=';
    var bytes = [];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (ch === '=') break;
      var index = __lgB64Chars.indexOf(ch);
      if (index < 0) continue;
      buffer = (buffer << 6) | index;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes.push((buffer >> bits) & 0xFF);
      }
    }
    return __lgUtf8String(bytes);
  }

  var __lgMd5S = [
    7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
    5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
    4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
    6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
  ];
  var __lgMd5K = [
    0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,
    0xa8304613,0xfd469501,0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
    0x6b901122,0xfd987193,0xa679438e,0x49b40821,0xf61e2562,0xc040b340,
    0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
    0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,
    0x676f02d9,0x8d2a4c8a,0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
    0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,0x289b7ec6,0xeaa127fa,
    0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
    0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,
    0xffeff47d,0x85845dd1,0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
    0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
  ];

  function __lgMd5Hex(value) {
    var bytes = __lgUtf8Bytes(value);
    var bitLo = (bytes.length * 8) >>> 0;
    var bitHi = Math.floor((bytes.length * 8) / 0x100000000);
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    bytes.push(bitLo & 0xFF, (bitLo >>> 8) & 0xFF, (bitLo >>> 16) & 0xFF,
               (bitLo >>> 24) & 0xFF);
    bytes.push(bitHi & 0xFF, (bitHi >>> 8) & 0xFF, (bitHi >>> 16) & 0xFF,
               (bitHi >>> 24) & 0xFF);
    var a = 0x67452301;
    var b = 0xefcdab89;
    var c = 0x98badcfe;
    var d = 0x10325476;
    for (var offset = 0; offset < bytes.length; offset += 64) {
      var m = [];
      for (var j = 0; j < 16; j++) {
        var p = offset + j * 4;
        m[j] = bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16) |
               (bytes[p + 3] << 24);
      }
      var aa = a;
      var bb = b;
      var cc = c;
      var dd = d;
      for (var i = 0; i < 64; i++) {
        var f;
        var g;
        if (i < 16) {
          f = (bb & cc) | (~bb & dd);
          g = i;
        } else if (i < 32) {
          f = (dd & bb) | (~dd & cc);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = bb ^ cc ^ dd;
          g = (3 * i + 5) % 16;
        } else {
          f = cc ^ (bb | ~dd);
          g = (7 * i) % 16;
        }
        f = (f + aa + __lgMd5K[i] + m[g]) | 0;
        aa = dd;
        dd = cc;
        cc = bb;
        var shift = __lgMd5S[i];
        bb = (bb + ((f << shift) | (f >>> (32 - shift)))) | 0;
      }
      a = (a + aa) | 0;
      b = (b + bb) | 0;
      c = (c + cc) | 0;
      d = (d + dd) | 0;
    }
    return __lgMd5Hex32(a) + __lgMd5Hex32(b) + __lgMd5Hex32(c) + __lgMd5Hex32(d);
  }

  function __lgMd5Hex32(n) {
    var out = '';
    for (var i = 0; i < 4; i++) {
      var byte = (n >>> (i * 8)) & 0xFF;
      out += ('0' + byte.toString(16)).slice(-2);
    }
    return out;
  }

  function __lgHexEncode(value) {
    var bytes = __lgUtf8Bytes(value);
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += ('0' + bytes[i].toString(16)).slice(-2);
    }
    return out;
  }

  function __lgHexDecode(value) {
    var s = (value === null || value === undefined) ? '' : String(value);
    if (s.length % 2 !== 0 || /[^0-9a-fA-F]/.test(s)) {
      throw new Error('hexDecodeToString: 非法十六进制字符串');
    }
    var bytes = [];
    for (var i = 0; i < s.length; i += 2) {
      bytes.push(parseInt(s.substr(i, 2), 16));
    }
    return __lgUtf8String(bytes);
  }

  // Java URLEncoder 语义：空格 -> '+'，保留 A-Za-z0-9 与 -._*，其余按 UTF-8 百分号编码
  function __lgEncodeUri(value) {
    var bytes = __lgUtf8Bytes(value);
    var hex = '0123456789ABCDEF';
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      var byte = bytes[i];
      if ((byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) || byte === 0x2D || byte === 0x2E ||
          byte === 0x2A || byte === 0x5F) {
        out += String.fromCharCode(byte);
      } else if (byte === 0x20) {
        out += '+';
      } else {
        out += '%' + hex.charAt(byte >> 4) + hex.charAt(byte & 0x0F);
      }
    }
    return out;
  }

  // ── 绑定到 java（覆盖 Rust 桥头的占位实现） ──────────────────────────────
  __lgJava.base64Encode = function (value) { return __lgBase64Encode(value); };
  __lgJava.base64Decode = function (value) { return __lgBase64Decode(value); };
  __lgJava.md5Encode = function (value) { return __lgMd5Hex(value); };
  __lgJava.md5Encode16 = function (value) {
    return __lgMd5Hex(value).substring(8, 24);
  };
  __lgJava.hexEncodeToString = function (value) { return __lgHexEncode(value); };
  __lgJava.hexDecodeToString = function (value) { return __lgHexDecode(value); };
  __lgJava.encodeURI = function (value) {
    if (arguments.length > 1) {
      try {
        __lgJava.log('java.encodeURI(str, enc) 的平台字符集参数已忽略（固定 UTF-8）');
      } catch (e) {}
    }
    return __lgEncodeUri(value);
  };
  __lgJava.getWebViewUA = function () {
    return (__lgUserAgent === null || __lgUserAgent === undefined)
      ? '' : String(__lgUserAgent);
  };

  // ── 动作摊平（经 Dart 内部动作通道 __action 回传） ───────────────────────
  function __lgEmitAction(name, payload) {
    var data = payload || {};
    data.action = name;
    __lgAction(data);
  }
  function __lgOptString(value) {
    return (value === null || value === undefined) ? null : String(value);
  }
  __lgJava.log = function (message) {
    var text = (message === null || message === undefined) ? '' : String(message);
    __lgEmitAction('log', { message: text });
    return text;
  };
  __lgJava.toast = function (message) {
    var text = (message === null || message === undefined) ? '' : String(message);
    __lgEmitAction('toast', { message: text, long: false });
    return text;
  };
  __lgJava.longToast = function (message) {
    var text = (message === null || message === undefined) ? '' : String(message);
    __lgEmitAction('toast', { message: text, long: true });
    return text;
  };
  __lgJava.open = function (name, url, title, origin) {
    __lgEmitAction('open', {
      name: __lgOptString(name) === null ? '' : __lgOptString(name),
      url: __lgOptString(url),
      title: __lgOptString(title),
      origin: __lgOptString(origin)
    });
  };
  __lgJava.searchBook = function (key, searchScope) {
    __lgEmitAction('searchBook', {
      key: __lgOptString(key) === null ? '' : __lgOptString(key),
      scope: __lgOptString(searchScope)
    });
  };
  __lgJava.addBook = function (bookUrl) {
    __lgEmitAction('addBook', {
      url: __lgOptString(bookUrl) === null ? '' : __lgOptString(bookUrl)
    });
  };
  __lgJava.showPhoto = function (src) {
    __lgEmitAction('showPhoto', {
      src: __lgOptString(src) === null ? '' : __lgOptString(src)
    });
  };
  __lgJava.openUrl = function (url) {
    __lgEmitAction('openUrl', {
      url: __lgOptString(url) === null ? '' : __lgOptString(url)
    });
  };

  // ── 同步网络明确不可用（平台差异：引导 *Await） ─────────────────────────
  function __lgSyncUnsupported(name, suggestion) {
    var message = '同步网络在当前平台不可用，请使用 ' + suggestion;
    try {
      __lgJava.log('java.' + name + ': ' + message);
    } catch (e) {}
    throw new Error(message);
  }
  __lgJava.ajax = function () { return __lgSyncUnsupported('ajax', 'ajaxAwait'); };
  __lgJava.connect = function () {
    return __lgSyncUnsupported('connect', 'connectAwait');
  };
  __lgJava.post = function () { return __lgSyncUnsupported('post', 'postAwait'); };
  __lgJava.head = function () { return __lgSyncUnsupported('head', 'headAwait'); };
  __lgJava.webView = function () {
    return __lgSyncUnsupported('webView', 'webViewAwait');
  };
  __lgJava.webViewGetSource = function () {
    return __lgSyncUnsupported('webViewGetSource', 'webViewGetSourceAwait');
  };
  var __lgRustGet = __lgJava.get;
  __lgJava.get = function () {
    if (arguments.length <= 1 && typeof __lgRustGet === 'function') {
      return __lgRustGet.apply(__lgJava, arguments);
    }
    return __lgSyncUnsupported('get', 'getAwait');
  };
''';

/// 同步面注入脚本（Rust 桥头之后、`preloadJs` 之前）
///
/// [bridgeObjectName]：动作通道（`window[bridgeObjectName].request`）；
/// [userAgent]：`java.getWebViewUA()` 返回值（`__prepare` 注入的 UA）。
String rssBridgeSyncShimScript({
  required String bridgeObjectName,
  String? userAgent,
}) {
  final bridge = jsonEncode(bridgeObjectName);
  return '''
(function(){
  var __lgJava = (typeof window !== 'undefined' && window.java) ? window.java : null;
  if (!__lgJava) return;
  var __lgActSeq = 0;
  var __lgAction = function (payload) {
    try {
      var bridge = (typeof window !== 'undefined') ? window[$bridge] : null;
      if (bridge && typeof bridge.request === 'function') {
        bridge.request('__action', JSON.stringify(payload || {}), 'act_' + (++__lgActSeq));
      }
    } catch (e) {}
  };
  var __lgUserAgent = ${rssJsLiteral(userAgent ?? '')};
$kRssBridgeSyncShimBody
})();
''';
}

/// `shouldOverrideUrlLoading` 用的 `java` 快照桩（同步可用，写入仅本地快照）
///
/// 对齐原版 `ReadRssActivity.shouldOverrideUrlLoading` 传入的
/// `RssJsExtensions`：`java.get/put/getKey/getTag/getVariable/putVariable`
/// 同步读写内存快照（刷新页面即丢弃，已登记差异）；`java.getString` 等
/// 解析规则能力不提供。
String rssBridgeOverrideScript(Map<String, dynamic> snapshot) {
  final literal = rssJsLiteral(snapshot);
  return '''
(function(){
  if (typeof window === 'undefined') return;
  var snapshot = $literal;
  var vars = snapshot.vars || {};
  window.__legadoJava = {
    get: function (key) {
      var k = String(key);
      return Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : '';
    },
    put: function (key, value) {
      var k = String(key);
      var v = String(value);
      vars[k] = v;
      return v;
    },
    getKey: function () { return snapshot.sourceUrl || ''; },
    getTag: function () { return snapshot.sourceName || ''; },
    getVariable: function () {
      return (snapshot.sourceVariable === null || snapshot.sourceVariable === undefined)
        ? '' : String(snapshot.sourceVariable);
    },
    putVariable: function (value) {
      snapshot.sourceVariable = String(value);
      return snapshot.sourceVariable;
    },
    getWebViewUA: function () { return snapshot.userAgent || ''; },
    log: function (message) { try { console.log(String(message)); } catch (e) {} },
    toast: function () {},
    longToast: function () {},
    open: function () {},
    searchBook: function () {},
    addBook: function () {},
    showPhoto: function () {},
    openUrl: function () {}
  };
})();
''';
}

// ─── JS：协议回填 ────────────────────────────────────────────────────────────

/// 回填宿主调用结果：`window[callbackName](id, ok, payload)`
///
/// Rust 桥头注册的 `__lgReply(id, ok, payload)` 按 `ok` resolve/reject 页面
/// Promise；payload 为 JSON 字面量（字符串/对象/数组/null）。
String rssBridgeReplyScript({
  required String callbackName,
  required String id,
  required bool ok,
  Object? payload,
}) {
  final callback = jsonEncode(callbackName);
  final idLiteral = jsonEncode(id);
  final payloadLiteral = rssJsLiteral(payload);
  return 'try{window[$callback]($idLiteral, $ok, $payloadLiteral);}catch(e){}';
}

/// 回填握手 nonce：`window[callbackName_nonce](nonce)`
String rssBridgeNonceScript({
  required String callbackName,
  required String nonce,
}) {
  final callback = jsonEncode('${callbackName}_nonce');
  final nonceLiteral = jsonEncode(nonce);
  return 'try{window[$callback]($nonceLiteral);}catch(e){}';
}

// ─── Cookie 辅助 ─────────────────────────────────────────────────────────────

/// 从 `__prepare` 快照的 `loginHeader`（JSON map）取 `Cookie` 值
///
/// 对齐原版 `CookieManager.applyToWebView`：源登录头里的 Cookie 在加载
/// URL 前预写进 WebView cookie jar。解析失败/无 Cookie 返回 null。
String? rssBridgeCookieFromLoginHeader(Object? loginHeader) {
  final raw = loginHeader?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  for (final entry in decoded.entries) {
    if (entry.key.toString().toLowerCase() == 'cookie') {
      final value = entry.value?.toString().trim() ?? '';
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

/// 把 `k1=v1; k2=v2` cookie 串按目标 URL 域预写进 WebView cookie jar
///
/// 无 `=` 的坏段静默跳过（对齐 `CookieManager.setCookie` 对畸形串的忽略
/// 行为）；HTTP(S) 之外/无 host 直接跳过。失败仅调试输出，不阻断阅读。
Future<void> rssBridgeWriteCookiesToWebViewJar({
  required String url,
  required String cookie,
}) async {
  if (url.trim().isEmpty || cookie.trim().isEmpty) return;
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return;
  final domain = uri.host;
  final manager = WebViewCookieManager();
  for (final part in cookie.split(';')) {
    final pair = part.trim();
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1);
    if (name.isEmpty) continue;
    try {
      await manager.setCookie(
        WebViewCookie(name: name, value: value, domain: domain),
      );
    } catch (e) {
      debugPrint('[RSS WebView] Cookie 预写失败（$name）：$e');
    }
  }
}

// ─── 桥实例 ──────────────────────────────────────────────────────────────────

class _PendingCall {
  Timer? timer;
  bool completed = false;
}

/// RSS WebView 宿主桥实例（一个阅读页/一个 WebView 控制器一个实例）
///
/// 典型用法（阅读页）：
/// ```dart
/// final bridge = RssWebBridge(
///   sourceUrl: sourceUrl,
///   api: ref.read(bookApiProvider),
///   runJavaScript: controller.runJavaScript,
///   onAction: _handleBridgeAction,
/// );
/// final prepared = await bridge.prepare(userAgent: ua);
/// if (prepared != null && prepared.script.isNotEmpty) {
///   await controller.addJavaScriptChannel(
///     bridge.nativeChannelName,
///     onMessageReceived: (m) => unawaited(bridge.handleMessage(m.message)),
///   );
/// }
/// ```
class RssWebBridge {
  RssWebBridge({
    required this.sourceUrl,
    required BookApi api,
    required RssWebBridgeJsRunner runJavaScript,
    this.requestTimeout = kRssWebBridgeDefaultTimeout,
    this.handshakeTimeout = kRssWebBridgeHandshakeTimeout,
    void Function(RssWebBridgeAction action)? onAction,
    void Function(String message)? onLog,
    Random? random,
  })  : _api = api,
        _runJavaScript = runJavaScript,
        _onAction = onAction,
        _onLog = onLog,
        _random = random ?? Random() {
    final token = _randomToken(_random, 12);
    channelName = '__legado_rss_$token';
    nativeChannelName = '__legado_rssNative_$token';
    callbackName = '__legado_rssCb_$token';
  }

  /// RSS 源 URL（宿主调用/落库键）
  final String sourceUrl;

  /// 宿主调用超时（超时按失败回填页面 Promise）
  final Duration requestTimeout;

  /// 握手超时（页面排队请求的失败兜底）
  final Duration handshakeTimeout;

  /// 页面桥对象名（传给 `__prepare` 的 `channelName`）
  late final String channelName;

  /// 平台 `JavaScriptChannel` 名（`window[nativeChannelName].postMessage`）
  late final String nativeChannelName;

  /// Rust 桥头回填回调名（`window[callbackName](id, ok, payload)`）
  late final String callbackName;

  final BookApi _api;
  final RssWebBridgeJsRunner _runJavaScript;
  final void Function(RssWebBridgeAction action)? _onAction;
  final void Function(String message)? _onLog;
  final Random _random;

  final Map<String, _PendingCall> _pending = <String, _PendingCall>{};

  /// `__store` 串行链：页面写操作有先后语义（如先 put 再读），
  /// 异步透传必须保序
  Future<void> _storeChain = Future<void>.value();

  RssWebBridgePrepareResult? _prepare;
  bool _handshaken = false;
  String? _nonce;
  bool _disposed = false;

  /// `__prepare` 结果（未准备为 null）
  RssWebBridgePrepareResult? get prepareResult => _prepare;

  /// 是否完成 hello/nonce 握手
  bool get isHandshaken => _handshaken;

  /// 当前 nonce（未握手为 null；测试可读）
  @visibleForTesting
  String? get nonce => _nonce;

  /// Rust 桥头脚本（未准备为空串）
  String get preparedScript => _prepare?.script ?? '';

  /// 调用 `__prepare` 拿桥头与快照
  ///
  /// `userAgent` 非空时同步记忆到 Rust 侧（后续宿主调用请求头回落 +
  /// `java.getWebViewUA` 返回值）。失败返回 null（调用方降级为无宿主绑定）。
  Future<RssWebBridgePrepareResult?> prepare({String? userAgent}) async {
    final params = <String, dynamic>{
      // Rust 桥头用该名读取页面桥对象：window[channelName].request(...)
      'channelName': channelName,
      'callbackName': callbackName,
      if ((userAgent ?? '').trim().isNotEmpty) 'ua': userAgent!.trim(),
    };
    try {
      final raw = await _api.rssWebViewHostCall(
        sourceUrl,
        '__prepare',
        jsonEncode([params]),
      );
      final envelope = RssWebBridgeEnvelope.parse(raw);
      if (!envelope.ok) {
        _log('__prepare 失败：${envelope.error ?? '未知错误'}');
        return null;
      }
      final value = envelope.value;
      if (value is! Map) {
        _log('__prepare 返回格式异常');
        return null;
      }
      final map = Map<String, dynamic>.from(value);
      final snapshot = map['snapshot'] is Map
          ? Map<String, dynamic>.from(map['snapshot'] as Map)
          : <String, dynamic>{};
      final result = RssWebBridgePrepareResult(
        script: map['script']?.toString() ?? '',
        snapshot: snapshot,
      );
      _prepare = result;
      return result;
    } catch (e) {
      _log('__prepare 调用异常：$e');
      return null;
    }
  }

  /// 组合 WebView 注入脚本（不含 HTML 转义）
  ///
  /// 顺序：console 钩子 → 通道适配/握手 → Rust 桥头 → 同步面 → `preloadJs`
  /// → `})();`。未准备或 Rust 桥头为空时返回裸 `preloadJs`（1:1 旧行为）。
  String composeInjection(
    String preloadJs, {
    bool includeConsoleHook = false,
  }) {
    final head = preparedScript;
    if (head.trim().isEmpty) return preloadJs;
    final buffer = StringBuffer();
    if (includeConsoleHook) buffer.write('$kRssConsoleHookScript\n');
    buffer.write(rssBridgeBootstrapScript(
      nativeChannelName: nativeChannelName,
      bridgeObjectName: channelName,
      callbackName: callbackName,
      handshakeTimeout: handshakeTimeout,
    ));
    buffer.write(head);
    buffer.write(rssBridgeSyncShimScript(
      bridgeObjectName: channelName,
      userAgent: _prepare?.userAgent ?? '',
    ));
    buffer.write(preloadJs);
    buffer.write('\n})();\n');
    return buffer.toString();
  }

  /// 处理页面经 `JavaScriptChannel` 发来的消息
  ///
  /// 协议：`{nonce,id,method,args}`。首个 `hello` 接受并回填 nonce；
  /// 其余消息必须携带正确 nonce（错误 nonce / 重复 hello 一律拒绝）。
  Future<void> handleMessage(String raw) async {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      _log('页面消息不是合法 JSON：${_truncate(raw)}');
      return;
    }
    if (decoded is! Map) {
      _log('页面消息必须是 JSON 对象');
      return;
    }
    final map = Map<String, dynamic>.from(decoded);
    final method = map['method']?.toString() ?? '';
    final id = map['id']?.toString() ?? '';
    final nonce = map['nonce']?.toString();
    final args = map['args']?.toString() ?? '[]';

    if (method == kRssWebBridgeHelloMethod) {
      await _handleHello();
      return;
    }
    if (!_handshaken) {
      _log('握手未完成，拒绝方法：$method');
      await _replyError(id, '握手未完成');
      return;
    }
    if (nonce == null || nonce != _nonce) {
      _log('nonce 校验失败，拒绝方法：$method');
      await _replyError(id, 'nonce 校验失败');
      return;
    }
    switch (method) {
      case kRssWebBridgeActionMethod:
        _dispatchPageAction(args);
        return;
      case kRssWebBridgeStoreMethod:
        _enqueueStore(args);
        return;
      default:
        break;
    }
    if (!kRssWebBridgeHostMethods.contains(method)) {
      _log('未知宿主方法：$method');
      await _replyError(id, '未知宿主方法：$method');
      return;
    }
    if (id.isEmpty) {
      _log('宿主方法缺少 id：$method');
      return;
    }
    unawaited(_forwardHostCall(method, args, id));
  }

  /// `onPageFinished` Cookie 回流（`__cookieSet`）
  ///
  /// 不依赖 quickjs（Rust 侧只写 Cookie 存储），桥不可用时也可用。
  Future<void> pushCookies({required String url, required String cookie}) async {
    if (_disposed) return;
    if (url.trim().isEmpty || cookie.trim().isEmpty) return;
    try {
      final raw = await _api.rssWebViewHostCall(
        sourceUrl,
        '__cookieSet',
        jsonEncode([
          {'url': url, 'cookie': cookie},
        ]),
      );
      final envelope = RssWebBridgeEnvelope.parse(raw);
      if (!envelope.ok) _log('__cookieSet 失败：${envelope.error ?? '未知错误'}');
    } catch (e) {
      _log('__cookieSet 调用异常：$e');
    }
  }

  /// 清洗并释放：取消所有超时计时器
  void dispose() {
    _disposed = true;
    for (final pending in _pending.values) {
      pending.completed = true;
      pending.timer?.cancel();
    }
    _pending.clear();
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  Future<void> _handleHello() async {
    if (_handshaken) {
      _log('重复 hello 已被拒绝');
      await _replyError('', '重复 hello');
      return;
    }
    _handshaken = true;
    _nonce = _randomToken(_random, 32);
    try {
      await _runJavaScript(
        rssBridgeNonceScript(callbackName: callbackName, nonce: _nonce!),
      );
    } catch (e) {
      _log('握手 nonce 回填失败：$e');
    }
  }

  Future<void> _forwardHostCall(
    String method,
    String argsJson,
    String id,
  ) async {
    final pending = _PendingCall();
    _pending[id] = pending;
    pending.timer = Timer(requestTimeout, () {
      if (pending.completed) return;
      pending.completed = true;
      _pending.remove(id);
      unawaited(_replyError(id, '宿主调用超时（${requestTimeout.inSeconds}s）'));
    });
    try {
      final raw = await _api.rssWebViewHostCall(sourceUrl, method, argsJson);
      if (pending.completed) return;
      pending.completed = true;
      pending.timer?.cancel();
      final envelope = RssWebBridgeEnvelope.parse(raw);
      _dispatchActions(envelope.actions);
      if (envelope.ok) {
        await _reply(id, true, envelope.value);
      } else {
        await _replyError(id, envelope.error ?? '宿主调用失败');
      }
    } catch (e) {
      if (pending.completed) return;
      pending.completed = true;
      pending.timer?.cancel();
      await _replyError(id, '$e');
    } finally {
      _pending.remove(id);
    }
  }

  /// `__store` 写穿（source/cache/log/toast 落库）
  ///
  /// 页面侧已同步更新内存镜像，本方法只负责异步落库与动作回传；
  /// 失败仅日志（不阻断页面脚本）。经 [_storeChain] 串行保序。
  void _enqueueStore(String argsJson) {
    _storeChain = _storeChain.then((_) => _forwardStore(argsJson)).catchError(
      (Object e) {
        _log('__store 串行链异常：$e');
      },
    );
  }

  Future<void> _forwardStore(String argsJson) async {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(argsJson);
    } catch (_) {
      _log('__store 参数不是合法 JSON');
      return;
    }
    if (decoded is! Map) {
      _log('__store 参数必须是 JSON 对象');
      return;
    }
    try {
      final raw = await _api.rssWebViewHostCall(
        sourceUrl,
        kRssWebBridgeStoreMethod,
        jsonEncode([Map<String, dynamic>.from(decoded)]),
      );
      final envelope = RssWebBridgeEnvelope.parse(raw);
      _dispatchActions(envelope.actions);
      if (!envelope.ok) _log('__store 失败：${envelope.error ?? '未知错误'}');
    } catch (e) {
      _log('__store 转发异常：$e');
    }
  }

  /// 页面动作（`__action`）解析与分发
  void _dispatchPageAction(String argsJson) {
    Object? decoded;
    try {
      decoded = jsonDecode(argsJson);
    } catch (_) {
      _log('__action 参数不是合法 JSON');
      return;
    }
    if (decoded is! Map) {
      _log('__action 参数必须是 JSON 对象');
      return;
    }
    _dispatchActions([Map<String, dynamic>.from(decoded)]);
  }

  void _dispatchActions(List<Map<String, dynamic>> actions) {
    if (actions.isEmpty || _disposed) return;
    final handler = _onAction;
    for (final action in actions) {
      final name = action['action']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (handler == null) {
        _log('未注册动作处理器，忽略：$name');
        continue;
      }
      try {
        handler(RssWebBridgeAction(name, action));
      } catch (e) {
        _log('动作处理失败（$name）：$e');
      }
    }
  }

  Future<void> _reply(String id, bool ok, Object? payload) async {
    if (_disposed) return;
    try {
      await _runJavaScript(
        rssBridgeReplyScript(
          callbackName: callbackName,
          id: id,
          ok: ok,
          payload: payload,
        ),
      );
    } catch (e) {
      _log('回填宿主结果失败：$e');
    }
  }

  Future<void> _replyError(String id, String message) =>
      _reply(id, false, message);

  void _log(String message) {
    final handler = _onLog;
    if (handler != null) {
      handler(message);
    } else {
      debugPrint('[RSS WebView 桥] $message');
    }
  }

  static String _truncate(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  /// 随机令牌（小写字母 + 数字，长度固定；用于通道/回调名）
  static String _randomToken(Random random, int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }
}
