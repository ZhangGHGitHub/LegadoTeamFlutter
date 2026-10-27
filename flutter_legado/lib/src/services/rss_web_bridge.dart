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
/// 批21c 安全加固（独立复核 P0）：
/// - 平台注入的 `JavaScriptChannel` 对象捕获后立即从全局删除（Android）；
///   页面桥对象不可枚举并在 Rust 桥头读取后删除；`java`/`source`/`cache`/
///   `*Await` 只在 IIFE 闭包内（Rust 桥头声明）。
/// - nonce 回调使用**独立随机名**，交付后立即删除；nonce **不是安全边界**
///   （仅防误用/重放）。URL 模式下桥能力与原版等价（页面可信假设），脚本
///   隔离只对文章 HTML 模式成立（契约 §2.5 批21d）。
/// - `__prepare` 失败或 `bridgeAvailable:false` 注入引导式降级桩（明确报错，
///   不因 TypeError 中断）。
///
/// 批21d 审查修复：
/// - 通道/桥对象/回填回调 **各自独立随机 token**（互不可推）；回填回调
///   `configurable:false`；nonce 回调独立随机名、用后删除；
/// - 握手改为「代数令牌 + 页面 ACK」：回填脚本携带单调代数，页面仅接受
///   不旧于当前的 nonce 并回发 `nonceAck`；Dart 以 ACK 置位 `_handshaken`，
///   ACK 缺失可经看门狗重试；
/// - 看门狗在回填在途时只顺延、不重置；新 hello 可覆盖在途握手。
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
const String kRssWebBridgeNonceAckMethod = 'nonceAck';
const String kRssWebBridgeActionMethod = '__action';
const String kRssWebBridgeStoreMethod = '__store';

/// 宿主调用默认超时（契约 §2.5：单次执行 30s；Dart 侧兜底回失败）
const Duration kRssWebBridgeDefaultTimeout = Duration(seconds: 30);

/// 握手超时（未收到 `hello` 或 nonce 无法回填时，排队的调用按失败回填，
/// 避免页面脚本无限挂起）
const Duration kRssWebBridgeHandshakeTimeout = Duration(seconds: 10);

/// 握手看门狗（批21c P1-1：导航后 4s 未完成握手 → 重置状态并重发 hello）
const Duration kRssWebBridgeHandshakeWatchdog = Duration(seconds: 4);

/// 看门狗最大重试次数（批21e P1-1：超过后停止并留明确日志，等待下一次导航）
const int kRssWebBridgeMaxWatchdogRetries = 3;

/// 页面动作（`__action`）每秒上限（超出丢弃并限频留痕）
const int kRssWebBridgeMaxActionsPerSecond = 200;

/// 页面写穿（`__store`）每秒上限（Rust 侧另有同量级硬限）
const int kRssWebBridgeMaxStoresPerSecond = 300;

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
    this.bridgeAvailable = true,
  });

  /// Rust 桥头（未闭合 IIFE；为空串表示源未配置 `preloadJs` 或桥不可用）
  final String script;

  /// 只读快照（`sourceUrl`/`sourceName`/`loginHeader`/`vars`/`userAgent`…）
  final Map<String, dynamic> snapshot;

  /// 宿主桥是否可用（批21d P2-1：非 quickjs 构建返回 `false` + 空 `script`，
  /// Dart 必须走引导式降级桩，不得裸跑 `preloadJs`）
  final bool bridgeAvailable;

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
/// 批21c/21d 安全加固：
/// - 平台注入的通道对象捕获后立即从页面全局删除（Android `delete` 是否
///   真正生效、`getOwnPropertyNames` 是否仍可见，以真机结论为准）；
/// - 页面桥对象用 `Object.defineProperty(..., enumerable:false)` 定义，
///   且定时删除（Rust 桥头会先行 `delete`，此为兜底）；
/// - **nonce 回调使用独立随机名**（与通道/桥对象/回填回调互不可推），
///   交付后由 [rssBridgeNonceScript] 删除；每次 hello 前重新注册；
/// - 页面 nonce handler 接受**不旧于当前**的代数令牌（新 hello 可覆盖在途
///   握手），接受后回发 `nonceAck`；
/// - 排队请求上限 20，溢出/握手超时按失败回填（不无限挂起）。
///
/// **nonce 不是安全边界**：仅防误用/重放；URL 模式下桥能力与原版等价
/// （页面可信假设），脚本隔离只对文章 HTML 模式成立（契约 §2.5 批21d）。
String rssBridgeBootstrapScript({
  required String nativeChannelName,
  required String bridgeObjectName,
  required String callbackName,
  required String nonceCallbackName,
  required String bootstrapMarkerName,
  Duration handshakeTimeout = kRssWebBridgeHandshakeTimeout,
}) {
  final native = jsonEncode(nativeChannelName);
  final bridge = jsonEncode(bridgeObjectName);
  final callback = jsonEncode(callbackName);
  final nonceCallback = jsonEncode(nonceCallbackName);
  final bootMarker = jsonEncode(bootstrapMarkerName);
  final timeoutMs = handshakeTimeout.inMilliseconds;
  return '''
(function(){
  // [批21b/21c/21d] RSS WebView 宿主桥：通道适配 + hello/nonce 握手
  if (typeof window === 'undefined') return;
  var __lgNative = null;
  try { __lgNative = window[$native]; } catch (e) {}
  if (!__lgNative || typeof __lgNative.postMessage !== 'function') return;
  // [批21e P3-1] 同文档幂等标记：首次注入成功后再写；重复注入直接返回，
  // 避免二次 defineProperty/重发 hello 造成状态错乱（标记 configurable:false，
  // 不可被页面删除；新文档 window 重建后自然消失）。
  // 批21f P3-3：标记写入移到通道删除与桥对象安装**之后**——若首轮在安装
  // 途中异常，不能被标记永久判成「已注入」导致同文档无法重试。
  try { if (window[$bootMarker]) return; } catch (e) {}
  // 捕获后立即删除平台注入的全局对象（Android 15 真机实测 delete 生效，
  // 删除后 getOwnPropertyNames 不再可见；iOS 无该全局，以真机结论为准）。
  try { delete window[$native]; } catch (e) {}
  var __lgNonce = null;
  var __lgNonceGen = -1;
  var __lgSealed = false;
  var __lgQueue = [];
  var __lgMaxQueue = 20;
  var __lgSend = function (method, argsJson, id) {
    __lgNative.postMessage(JSON.stringify({
      nonce: __lgNonce,
      id: id,
      method: method,
      args: argsJson
    }));
  };
  // 失败回填：调用 Rust 桥头注册的回填回调（不可枚举；按名访问）
  var __lgDeliverError = function (id, message) {
    if (!id) return;
    try {
      var reply = window[$callback];
      if (typeof reply === 'function') reply(String(id), false, String(message));
    } catch (e) {}
  };
  var __lgFlushQueue = function () {
    var queue = __lgQueue;
    __lgQueue = [];
    for (var i = 0; i < queue.length; i++) {
      var item = queue[i];
      try { __lgSend(item.method, item.args, item.id); } catch (e) {}
    }
  };
  var __lgBridgeObject = {
    request: function (method, argsJson, id) {
      var m = (method === null || method === undefined) ? '' : String(method);
      var a = (argsJson === null || argsJson === undefined) ? '[]' : String(argsJson);
      var i = (id === null || id === undefined) ? '' : String(id);
      if (__lgNonce === null) {
        if (__lgSealed) {
          __lgDeliverError(i, '宿主桥握手超时：未获取 nonce');
          return;
        }
        if (__lgQueue.length >= __lgMaxQueue) {
          __lgDeliverError(i, '宿主桥请求队列已满（≥' + __lgMaxQueue + '）');
          return;
        }
        __lgQueue.push({ id: i, method: m, args: a });
        return;
      }
      try { __lgSend(m, a, i); } catch (e) { __lgDeliverError(i, String(e)); }
    }
  };
  // 桥对象不可枚举（页面脚本仍可经 getOwnPropertyNames 看到属性名）
  try {
    Object.defineProperty(window, $bridge, {
      value: __lgBridgeObject,
      enumerable: false,
      configurable: true,
      writable: false
    });
  } catch (e) {
    try { window[$bridge] = __lgBridgeObject; } catch (e2) {}
  }
  // 兜底清理：Rust 桥头读取后会立即 delete；若桥头缺失/抛错，本定时器兜底
  setTimeout(function () {
    try { delete window[$bridge]; } catch (e) {}
  }, 0);
  // 页面 nonce handler：允许更新到最新 nonce（代数令牌单调）；接受后回发
  // nonceAck（Dart 以 ACK 置位握手状态），随后由 Dart 删除本回调。
  var __lgNonceHandler = function (nonce, generation) {
    var gen = Number(generation);
    if (!isFinite(gen)) gen = 0;
    if (gen < __lgNonceGen) return;
    __lgNonceGen = gen;
    __lgNonce = String(nonce);
    __lgSealed = false;
    try { __lgSend('nonceAck', String(gen), ''); } catch (e) {}
    if (__lgQueue.length > 0) __lgFlushQueue();
  };
  // 每次 hello 前重新注册（Dart 交付 nonce 后会删除该回调）
  var __lgRegisterNonceCallback = function () {
    try {
      Object.defineProperty(window, $nonceCallback, {
        value: __lgNonceHandler,
        enumerable: false,
        configurable: true,
        writable: false
      });
    } catch (e) {
      try { window[$nonceCallback] = __lgNonceHandler; } catch (e2) {}
    }
  };
  __lgRegisterNonceCallback();
  var __lgHello = function () {
    __lgRegisterNonceCallback();
    try { __lgSend('hello', '[]', ''); } catch (e) {}
  };
  // Dart 看门狗重发入口：挂在（不可枚举的）回填回调上，不新增全局
  setTimeout(function () {
    try {
      var reply = window[$callback];
      if (typeof reply === 'function') {
        try {
          Object.defineProperty(reply, '__lgHello', {
            value: __lgHello,
            enumerable: false,
            configurable: true,
            writable: false
          });
        } catch (e) {}
      }
    } catch (e) {}
  }, 0);
  setTimeout(function () {
    if (__lgNonce !== null) return;
    __lgSealed = true;
    var queue = __lgQueue;
    __lgQueue = [];
    for (var i = 0; i < queue.length; i++) {
      __lgDeliverError(queue[i].id, '宿主桥握手超时：未收到 nonce');
    }
  }, $timeoutMs);
  // [批21f P3-3] 通道已删除、桥对象/nonce 回调/看门狗入口均已安装成功，
  // 此时才写幂等标记（安装途中异常可重试）。
  try {
    Object.defineProperty(window, $bootMarker, {
      value: 1,
      enumerable: false,
      configurable: false,
      writable: false
    });
  } catch (e) {
    try { window[$bootMarker] = 1; } catch (e2) {}
  }
  __lgHello();
})();
''';
}

/// 看门狗重发 hello（调用挂在回填回调上的非枚举入口；未就绪时静默）
String rssBridgeHelloScript({required String callbackName}) {
  final callback = jsonEncode(callbackName);
  return 'try{var r=window[$callback];'
      'if(r&&typeof r.__lgHello==="function")r.__lgHello();}catch(e){}';
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
/// [bridgeObjectName]：保留参数以兼容既有调用；批21c 起动作通道改为
/// 闭包内的 `__lgEmitAction`（由 Rust 桥头声明，不残留 `window` 桥对象）。
/// [userAgent]：`java.getWebViewUA()` 返回值（`__prepare` 注入的 UA）。
String rssBridgeSyncShimScript({
  String? bridgeObjectName,
  String? userAgent,
}) {
  return '''
(function(){
  // 批21c：java 由 Rust 桥头在**同一 IIFE 闭包**内声明（不写 window）；
  // 这里经词法作用域直接引用，页面脚本无法取得。
  var __lgJava = (typeof java !== 'undefined' && java) ? java : null;
  if (!__lgJava) return;
  var __lgAction = function (payload) {
    try {
      if (typeof __lgEmitAction === 'function') {
        __lgEmitAction(payload || {});
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

// ─── JS：prepare 失败降级桩 ──────────────────────────────────────────────────

/// `__prepare` 失败时的降级注入（批21c P2-9）
///
/// 不注入宿主桥（无通道/无机密快照），只提供带明确报错的 `java`/`source`/
/// `cache` 桩：缺失常用属性会让 `preloadJs` 抛 TypeError 并中断后续语句，
/// 这里保证「调用存在、失败可读」，同步流程不被中断。
/// [syncShim] 为同步面（纯函数 + `java.log/toast` 摊平），仍可安全注入。
String rssBridgeDegradedScript(
  String preloadJs, {
  String? syncShim,
}) {
  return '''
(function(){
  // [批21c] RSS WebView 宿主桥 prepare 失败：引导式降级桩（不写 window 全局）
  var __lgWarned = Object.create(null);
  function __lgWarnOnce(key, message) {
    if (__lgWarned[key]) return;
    __lgWarned[key] = true;
    try { console.warn(message); } catch (e) {}
  }
  function __lgUnsupported(name) {
    var msg = 'RSS WebView 宿主桥不可用（prepare 失败或桥不可用）：java.' + name;
    __lgWarnOnce('unsupported:' + name, msg);
    throw new Error(msg);
  }
  function __lgRejected(name) {
    var msg = 'RSS WebView 宿主桥不可用（prepare 失败或桥不可用）：' + name;
    __lgWarnOnce('rejected:' + name, msg);
    return Promise.reject(new Error(msg));
  }
  function __lgNoopAction(payload) { return payload; }
  var __lgEmitAction = __lgNoopAction;
  var java = {
    request: function () {},
    put: function (k, v) { return String(v); },
    get: function () { return ''; },
    ajax: function () { return __lgUnsupported('ajax'); },
    connect: function () { return __lgUnsupported('connect'); },
    post: function () { return __lgUnsupported('post'); },
    head: function () { return __lgUnsupported('head'); },
    webView: function () { return __lgUnsupported('webView'); },
    webViewGetSource: function () { return __lgUnsupported('webViewGetSource'); },
    downloadFile: function () { return __lgUnsupported('downloadFile'); },
    readTxtFile: function () { return __lgUnsupported('readTxtFile'); },
    importScript: function () { return __lgUnsupported('importScript'); },
    getString: function () { return __lgUnsupported('getString'); },
    getStringList: function () { return __lgUnsupported('getStringList'); },
    createSymmetricCrypto: function () { return __lgUnsupported('createSymmetricCrypto'); },
    createSign: function () { return __lgUnsupported('createSign'); },
    getCookie: function () { return ''; },
    setCookie: function () {},
    ajaxAwait: function () { return __lgRejected('ajaxAwait'); },
    connectAwait: function () { return __lgRejected('connectAwait'); },
    getAwait: function () { return __lgRejected('getAwait'); },
    headAwait: function () { return __lgRejected('headAwait'); },
    postAwait: function () { return __lgRejected('postAwait'); },
    webViewAwait: function () { return __lgRejected('webViewAwait'); },
    webViewGetSourceAwait: function () { return __lgRejected('webViewGetSourceAwait'); },
    decryptStrAwait: function () { return __lgRejected('decryptStrAwait'); },
    encryptBase64Await: function () { return __lgRejected('encryptBase64Await'); },
    encryptHexAwait: function () { return __lgRejected('encryptHexAwait'); },
    createSignHexAwait: function () { return __lgRejected('createSignHexAwait'); },
    downloadFileAwait: function () { return __lgRejected('downloadFileAwait'); },
    readTxtFileAwait: function () { return __lgRejected('readTxtFileAwait'); },
    importScriptAwait: function () { return __lgRejected('importScriptAwait'); },
    getStringAwait: function () { return __lgRejected('getStringAwait'); },
    toast: function (msg) { __lgWarnOnce('toast', String(msg)); return String(msg); },
    longToast: function (msg) { __lgWarnOnce('longToast', String(msg)); return String(msg); },
    log: function (msg) { __lgWarnOnce('log', String(msg)); return String(msg); },
    randomUUID: function () { return '00000000-0000-4000-8000-000000000000'; },
    timeFormat: function () { return ''; },
    htmlFormat: function (str) { return String(str == null ? '' : str); },
    t2s: function (text) { return String(text == null ? '' : text); },
    s2t: function (text) { return String(text == null ? '' : text); }
  };
  var source = {
    get: function () { return ''; },
    getKey: function () { return ''; },
    getUrl: function () { return ''; },
    getTag: function () { return ''; },
    key: '',
    url: '',
    sourceUrl: '',
    sourceName: '',
    loginUrl: '',
    loginUi: '',
    header: '',
    put: function (k, v) { return String(v); },
    getVariable: function () { return ''; },
    setVariable: function (v) { return String(v); },
    putVariable: function (v) { return String(v); },
    getLoginHeader: function () { return null; },
    putLoginHeader: function () {},
    removeLoginHeader: function () {},
    getLoginHeaderMap: function () { return null; },
    getLoginInfo: function () { return null; },
    putLoginInfo: function () { return true; },
    removeLoginInfo: function () {},
    getLoginInfoMap: function () {
      var data = {};
      data.get = function (k) { return this[k] == null ? null : this[k]; };
      data.put = function (k, v) { this[k] = String(v); return v; };
      return data;
    },
    hasLogin: function () { return false; },
    login: function () { __lgWarnOnce('login', '宿主桥不可用：source.login() 已忽略'); }
  };
  var cache = {
    get: function () { return null; },
    put: function (k, v) { return String(v); },
    remove: function () { return true; },
    putMemory: function () {},
    getFromMemory: function () { return null; },
    deleteMemory: function () { return true; }
  };
${syncShim ?? ''}
$preloadJs
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

/// 回填握手 nonce：`window[nonceCallback](nonce, generation)`，交付后立即删除
///
/// 批21d P0-B/P1-1：nonce 回调用**独立随机名**（不从回填回调名推导），且
/// 每次交付后删除；页面每次 hello 前会重新注册。代数令牌单调递增，页面只
/// 接受不旧于当前的 nonce，避免旧文档/慢回填覆盖新状态。
String rssBridgeNonceScript({
  required String nonceCallbackName,
  required String nonce,
  required int generation,
}) {
  final callback = jsonEncode(nonceCallbackName);
  final nonceLiteral = jsonEncode(nonce);
  return 'try{window[$callback]($nonceLiteral, $generation);}catch(e){}'
      'finally{try{delete window[$callback];}catch(e){}}';
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

/// 固定 1s 窗口计数（页面动作/写穿限频）
class _PageRateWindow {
  _PageRateWindow({required this.limit});

  final int limit;
  DateTime _windowStart = DateTime.fromMillisecondsSinceEpoch(0);
  int _count = 0;

  /// 允许本次调用返回 true；超限返回 false
  bool allow() {
    final now = DateTime.now();
    if (now.difference(_windowStart) >= const Duration(seconds: 1)) {
      _windowStart = now;
      _count = 0;
    }
    if (_count >= limit) return false;
    _count++;
    return true;
  }
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
    this.handshakeWatchdog = kRssWebBridgeHandshakeWatchdog,
    void Function(RssWebBridgeAction action)? onAction,
    void Function(String message)? onLog,
    Random? random,
    Duration Function()? elapsedNow,
  })  : _api = api,
        _runJavaScript = runJavaScript,
        _onAction = onAction,
        _onLog = onLog,
        _random = random ?? _secureRandom(),
        // 批21f P2-2：看门狗用单调时钟（默认进程内 Stopwatch），注入面为
        // `Duration Function()`；墙钟回拨不会让在途时长变负/倒退。
        _elapsedNow = elapsedNow ?? _defaultElapsedNow {
    // 批21d P0-B：通道/桥对象/回填回调/nonce 回调各自独立随机 token，
    // 互不可推（此前四者共用一个 token，页面枚举到一个即可推导其余）。
    // 批21e P2-2：生产环境使用 `Random.secure()`（测试可注入确定性 Random）。
    channelName = '__legado_rss_${_randomToken(_random, 12)}';
    nativeChannelName = '__legado_rssNative_${_randomToken(_random, 12)}';
    callbackName = '__legado_rssCb_${_randomToken(_random, 12)}';
    nonceCallbackName = '__legado_rssNonce_${_randomToken(_random, 12)}';
    bootstrapMarkerName = '__legado_rssBoot_${_randomToken(_random, 12)}';
  }

  /// 加密安全随机源（Web 等不支持 `Random.secure()` 的平台回落伪随机）
  static Random _secureRandom() {
    try {
      return Random.secure();
    } on UnsupportedError {
      return Random();
    }
  }

  /// 默认单调时钟（进程内共享 Stopwatch；只取差值，不依赖墙钟）
  static final Stopwatch _monotonicClock = Stopwatch()..start();

  static Duration _defaultElapsedNow() => _monotonicClock.elapsed;

  /// RSS 源 URL（宿主调用/落库键）
  final String sourceUrl;

  /// 宿主调用超时（超时按失败回填页面 Promise）
  final Duration requestTimeout;

  /// 握手超时（页面排队请求的失败兜底）
  final Duration handshakeTimeout;

  /// 握手看门狗（批21c P1-1：4s 未握手 → 重置并重发 hello）
  final Duration handshakeWatchdog;

  /// 页面桥对象名（传给 `__prepare` 的 `channelName`）
  late final String channelName;

  /// 平台 `JavaScriptChannel` 名（`window[nativeChannelName].postMessage`）
  late final String nativeChannelName;

  /// Rust 桥头回填回调名（`window[callbackName](id, ok, payload)`）
  late final String callbackName;

  /// 页面 nonce 回调名（独立随机 token，不从 [callbackName] 推导；用后删除）
  late final String nonceCallbackName;

  /// 同文档 bootstrap 幂等标记名（批21e P3-1）
  late final String bootstrapMarkerName;

  final BookApi _api;
  final RssWebBridgeJsRunner _runJavaScript;
  final void Function(RssWebBridgeAction action)? _onAction;
  final void Function(String message)? _onLog;
  final Random _random;

  /// 单调时钟（批21f P2-2：默认 Stopwatch，测试可注入假时钟；
  /// 只用于在途时长差值，墙钟回拨不影响判定）
  final Duration Function() _elapsedNow;

  final Map<String, _PendingCall> _pending = <String, _PendingCall>{};

  /// `__store` 串行链：页面写操作有先后语义（如先 put 再读），
  /// 异步透传必须保序
  Future<void> _storeChain = Future<void>.value();

  RssWebBridgePrepareResult? _prepare;
  bool _handshaken = false;
  bool _handshakeInFlight = false;
  String? _nonce;
  bool _disposed = false;

  /// 平台 `JavaScriptChannel` 是否已注册（批21e P1-1：只有实际可注入桥的
  /// 文档才臂看门狗；未注册时页面无法回执，重试没有意义）
  bool _channelRegistered = false;

  /// 本代文档是否实际注入了桥（beginNavigation 入参决定；hello 到达也会置位）
  bool _bridgeActive = false;

  /// 看门狗已重试次数（上限 [kRssWebBridgeMaxWatchdogRetries]，成功后清零）
  int _watchdogRetries = 0;

  /// 看门狗是否已因重试上限停止（下一次导航/ACK 成功后恢复）
  bool _watchdogStopped = false;

  /// 本次 nonce 回填的起始时刻（单调时钟；批21e P1-1：在途顺延也受总时长
  /// 上限约束；批21f P2-2 改为 Duration 差值）
  Duration? _handshakeInFlightSince;

  /// 握手代数令牌（批21d P1-1）：每次 hello / 导航自增，随 nonce 回填下发；
  /// 页面只接受不旧于当前的令牌，Dart 只接受与当前令牌匹配的 `nonceAck`。
  int _handshakeToken = 0;

  /// 当前等待 ACK 的握手令牌（-1 = 无）
  int _nonceToken = -1;

  /// 握手看门狗计时器（每次导航重臂，握手成功取消）
  Timer? _handshakeWatchdogTimer;

  /// `__prepare` 是否失败（降级为引导式桩；见 [rssBridgeDegradedScript]）
  bool _prepareFailed = false;

  /// 页面动作/写穿限频窗口（批21c P2-10）
  final _PageRateWindow _actionRate =
      _PageRateWindow(limit: kRssWebBridgeMaxActionsPerSecond);
  final _PageRateWindow _storeRate =
      _PageRateWindow(limit: kRssWebBridgeMaxStoresPerSecond);

  /// `__prepare` 结果（未准备为 null）
  RssWebBridgePrepareResult? get prepareResult => _prepare;

  /// 是否完成 hello/nonce 握手
  bool get isHandshaken => _handshaken;

  /// 平台通道是否已注册（调用方在 `addJavaScriptChannel` 成功后置位）
  bool get isChannelRegistered => _channelRegistered;

  /// 标记平台通道已注册（仅调用方在注册成功后调用）
  void markChannelRegistered() {
    _channelRegistered = true;
  }

  /// 看门狗当前是否处于工作状态（测试可读）
  @visibleForTesting
  bool get isWatchdogActive =>
      _bridgeActive && !_watchdogStopped && !_handshaken;

  /// 看门狗已重试次数（测试可读）
  @visibleForTesting
  int get watchdogRetries => _watchdogRetries;

  /// `__prepare` 是否失败（调用方可据此选择降级桩；[composeInjection] 自动处理）
  bool get isDegraded => _prepareFailed;

  /// 当前 nonce（未握手为 null；测试可读）
  @visibleForTesting
  String? get nonce => _nonce;

  /// 当前握手代数令牌（测试可读；-1 = 无在途握手）
  @visibleForTesting
  int get handshakeToken => _nonceToken;

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
    _prepareFailed = false;
    try {
      final raw = await _api.rssWebViewHostCall(
        sourceUrl,
        '__prepare',
        jsonEncode([params]),
      );
      final envelope = RssWebBridgeEnvelope.parse(raw);
      if (!envelope.ok) {
        _prepareFailed = true;
        _log('__prepare 失败：${envelope.error ?? '未知错误'}');
        return null;
      }
      final value = envelope.value;
      if (value is! Map) {
        _prepareFailed = true;
        _log('__prepare 返回格式异常');
        return null;
      }
      final map = Map<String, dynamic>.from(value);
      final snapshot = map['snapshot'] is Map
          ? Map<String, dynamic>.from(map['snapshot'] as Map)
          : <String, dynamic>{};
      final script = map['script']?.toString() ?? '';
      final available = map['bridgeAvailable'] is bool
          ? map['bridgeAvailable'] as bool
          : script.trim().isNotEmpty;
      final result = RssWebBridgePrepareResult(
        script: script,
        snapshot: snapshot,
        bridgeAvailable: available,
      );
      _prepare = result;
      return result;
    } catch (e) {
      _prepareFailed = true;
      _log('__prepare 调用异常：$e');
      return null;
    }
  }

  /// 组合 WebView 注入脚本（不含 HTML 转义）
  ///
  /// 顺序：console 钩子 → 通道适配/握手 → Rust 桥头 → 同步面 → `preloadJs`
  /// → `})();`。
  ///
  /// 批21c P2-9 / 批21d P2-1：`__prepare` 失败、`bridgeAvailable:false`
  /// （非 quickjs 构建）或桥头为空时注入**引导式降级桩**（明确报错的
  /// `java`/`source`/`cache` + 同步面纯函数），不得裸跑 `preloadJs`
  /// （缺失属性抛 TypeError 会中断后续语句）；仅「完全未尝试 prepare」时
  /// 保持裸 `preloadJs`（1:1 旧行为）。
  String composeInjection(
    String preloadJs, {
    bool includeConsoleHook = false,
  }) {
    final head = preparedScript;
    if (head.trim().isEmpty) {
      // 已尝试 prepare（成功但桥不可用/桥头为空）或失败 → 降级桩
      final attempted = _prepareFailed || _prepare != null;
      if (attempted) {
        _log('宿主桥不可用：注入引导式降级桩');
        final buffer = StringBuffer();
        if (includeConsoleHook) buffer.write('$kRssConsoleHookScript\n');
        buffer.write(rssBridgeDegradedScript(
          preloadJs,
          syncShim: rssBridgeSyncShimScript(
            bridgeObjectName: channelName,
            userAgent: _prepare?.userAgent ?? '',
          ),
        ));
        return buffer.toString();
      }
      return preloadJs;
    }
    final buffer = StringBuffer();
    if (includeConsoleHook) buffer.write('$kRssConsoleHookScript\n');
    buffer.write(rssBridgeBootstrapScript(
      nativeChannelName: nativeChannelName,
      bridgeObjectName: channelName,
      callbackName: callbackName,
      nonceCallbackName: nonceCallbackName,
      bootstrapMarkerName: bootstrapMarkerName,
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
  /// 协议：`{nonce,id,method,args}`。`hello` 触发 nonce 回填；页面随后回发
  /// `nonceAck`（`args` 为握手代数令牌），Dart 以 ACK 置位握手状态；其余
  /// 消息必须携带正确 nonce（错误 nonce / 握手前消息一律拒绝）。
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
    if (method == kRssWebBridgeNonceAckMethod) {
      _handleNonceAck(nonce, args);
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
        if (!_actionRate.allow()) {
          _log('__action 超过每秒上限（$kRssWebBridgeMaxActionsPerSecond），已丢弃');
          return;
        }
        _dispatchPageAction(args);
        return;
      case kRssWebBridgeStoreMethod:
        if (!_storeRate.allow()) {
          _log('__store 超过每秒上限（$kRssWebBridgeMaxStoresPerSecond），已丢弃');
          return;
        }
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

  /// 页面导航开始：重置握手状态并结束旧文档的挂起调用
  ///
  /// URL 模式下每次主框架导航都会重新注入桥脚本（新文档重新 `hello`）；
  /// 若沿用首个文档的 nonce，新文档的消息会被判为「非预期 nonce」而全部
  /// 拒绝。旧文档的挂起调用按超时语义直接结束（页面已被替换）。
  ///
  /// [bridgeInjected]（批21e P1-1）：本代文档是否**实际注入**宿主桥
  /// （平台通道已注册 + 桥头非空 + 本页会执行组合脚本）。为 false 时只
  /// 重置状态、不臂看门狗——页面没有桥可回执，重试只会空转。
  void beginNavigation({bool bridgeInjected = true}) {
    if (_disposed) return;
    // 批21c P1-1 / 批21d：代数自增，使旧文档在途的 hello 回填/ACK 失效
    _handshakeToken++;
    _handshaken = false;
    _handshakeInFlight = false;
    _handshakeInFlightSince = null;
    _nonce = null;
    _nonceToken = -1;
    _watchdogRetries = 0;
    _watchdogStopped = false;
    _bridgeActive = bridgeInjected;
    for (final pending in _pending.values) {
      pending.completed = true;
      pending.timer?.cancel();
    }
    _pending.clear();
    if (bridgeInjected) {
      _armHandshakeWatchdog();
    } else {
      _handshakeWatchdogTimer?.cancel();
      _handshakeWatchdogTimer = null;
    }
  }

  /// 臂握手看门狗（每次导航/hello 调用；超时未握手则重发 hello）
  ///
  /// 批21d P1-1：回填在途时**只顺延、不重置**（重置会让页面已收到的新
  /// nonce 与 Dart 状态失步）；批21e P1-1 补充：
  /// - 仅在 `_bridgeActive`（本代文档实际注入桥）时工作；
  /// - 在途顺延受 `handshakeTimeout` 总时长上限约束，超限按失败进入重试；
  /// - 重试上限 [kRssWebBridgeMaxWatchdogRetries]，超过后停止并留明确日志。
  void _armHandshakeWatchdog() {
    _handshakeWatchdogTimer?.cancel();
    _handshakeWatchdogTimer = null;
    if (_disposed || !_bridgeActive || _watchdogStopped || _handshaken) return;
    _handshakeWatchdogTimer = Timer(handshakeWatchdog, _onWatchdogTick);
  }

  void _onWatchdogTick() {
    if (_disposed || !_bridgeActive || _handshaken) return;
    if (_handshakeInFlight) {
      final since = _handshakeInFlightSince;
      var elapsed = since == null ? Duration.zero : _elapsedNow() - since;
      // 批21f P2-2：单调时钟仍防御性钳制负值（注入时钟回拨/精度异常按 0）
      if (elapsed.isNegative) elapsed = Duration.zero;
      if (elapsed < handshakeTimeout) {
        _log(
          '握手回填仍在途（${elapsed.inMilliseconds}ms/'
          '${handshakeTimeout.inMilliseconds}ms），看门狗顺延',
        );
        _armHandshakeWatchdog();
        return;
      }
      // 总时长上限已到：本次回填视为失败（页面可能已失联/脚本被中断）
      _log(
        '握手回填在途超过总时长上限（${handshakeTimeout.inSeconds}s），'
        '按失败处理并重试',
      );
      _handshakeInFlight = false;
      _handshakeInFlightSince = null;
    }
    if (_watchdogRetries >= kRssWebBridgeMaxWatchdogRetries) {
      _watchdogStopped = true;
      _log(
        '握手看门狗已重试 $kRssWebBridgeMaxWatchdogRetries 次仍未完成，'
        '停止重试（等待下一次导航）',
      );
      _handshakeWatchdogTimer = null;
      return;
    }
    _watchdogRetries++;
    _handshakeToken++;
    _nonce = null;
    _nonceToken = -1;
    _log(
      '握手看门狗超时（${handshakeWatchdog.inSeconds}s，'
      '重试 $_watchdogRetries/$kRssWebBridgeMaxWatchdogRetries）：'
      '重置并重发 hello',
    );
    unawaited(_reissueHello());
    _armHandshakeWatchdog();
  }

  /// 重发 hello（页面侧挂载在回填回调上的非枚举入口；不可用时静默）
  Future<void> _reissueHello() async {
    if (_disposed) return;
    try {
      await _runJavaScript(rssBridgeHelloScript(callbackName: callbackName));
    } catch (e) {
      _log('重发 hello 失败：$e');
    }
  }

  /// 清洗并释放：取消所有超时计时器
  void dispose() {
    _disposed = true;
    _handshakeToken++;
    _nonceToken = -1;
    _bridgeActive = false;
    _handshakeInFlightSince = null;
    _handshakeWatchdogTimer?.cancel();
    _handshakeWatchdogTimer = null;
    for (final pending in _pending.values) {
      pending.completed = true;
      pending.timer?.cancel();
    }
    _pending.clear();
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  Future<void> _handleHello() async {
    if (_disposed) return;
    if (_handshaken) {
      _log('重复 hello 已被拒绝');
      await _replyError('', '重复 hello');
      return;
    }
    // 批21e P1-1：能收到 hello 说明本代文档确实注入了桥（无 preloadJs 的源
    // 不会走到这里），恢复看门狗工作状态。
    _bridgeActive = true;
    // 批21d P1-1：新 hello 可覆盖在途握手（旧回填的代数更小，
    // 页面按令牌拒绝旧值；Dart 也只接受最新令牌的 ACK）。
    final token = ++_handshakeToken;
    _nonceToken = token;
    _handshakeInFlight = true;
    _handshakeInFlightSince = _elapsedNow();
    _handshaken = false;
    final nonce = _randomToken(_random, 32);
    // nonce 先占位（页面尚未知悉），回填失败/被覆盖时回滚
    _nonce = nonce;
    _armHandshakeWatchdog();
    try {
      await _runJavaScript(
        rssBridgeNonceScript(
          nonceCallbackName: nonceCallbackName,
          nonce: nonce,
          generation: token,
        ),
      );
    } catch (e) {
      if (token == _nonceToken) {
        _handshakeInFlight = false;
        _handshakeInFlightSince = null;
        _handshaken = false;
        _nonce = null;
        _nonceToken = -1;
      }
      _log('握手 nonce 回填失败（可重试 hello）：$e');
      return;
    }
    if (_disposed || token != _nonceToken) {
      _log('握手已被更新的 hello/导航覆盖，丢弃旧回填结果');
      return;
    }
    // 回填已完成（不再算「在途」），但握手仍需页面 ACK 才置位；ACK 缺失时
    // 看门狗会重发 hello（批21d P1-1）。
    _handshakeInFlight = false;
    _handshakeInFlightSince = null;
    _log('nonce 已回填（token=$token），等待页面 ACK');
  }

  /// 页面 `nonceAck`：只有最新令牌 + 当前 nonce 才置位握手
  void _handleNonceAck(String? nonce, String args) {
    if (_disposed || _handshaken) return;
    final token = int.tryParse(args.trim());
    if (nonce == null || nonce != _nonce || token == null || token != _nonceToken) {
      _log('nonceAck 已过期（token=$args），忽略');
      return;
    }
    _handshakeInFlight = false;
    _handshakeInFlightSince = null;
    _handshaken = true;
    // 批21e P1-1：成功后清空重试计数并恢复看门狗（下一次导航重置）
    _watchdogRetries = 0;
    _watchdogStopped = false;
    _handshakeWatchdogTimer?.cancel();
    _handshakeWatchdogTimer = null;
    _log('握手 ACK 已确认（token=$token）');
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
