var __lgActions = [];
var __lgJava = { get: function (key) { return 'V:' + String(key); } };
function __lgEmitAction(payload) { __lgActions.push(payload); }
var __lgAction = function (payload) {
  try { if (typeof __lgEmitAction === 'function') __lgEmitAction(payload || {}); } catch (e) {}
};
var __lgUserAgent = 'UA';

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
  // 批21h P1-1：本函数**不得**命名为 `__lgEmitAction`——Rust 桥头在同一
  // 外层 IIFE 声明了单参 `__lgEmitAction(payload)`，函数声明提升会让
  // 外层包装器 `__lgAction` 解析到本地两参版本，单参调用 → `payload` 为
  // undefined → 再次调用 `__lgAction` → 无限互递归 → RangeError 被
  // try/catch 吞掉，动作永不发送（java.log/toast/open/... 全部静默丢失）。
  function __lgActionEmit(name, payload) {
    var data = payload || {};
    data.action = name;
    __lgAction(data);
  }
  function __lgOptString(value) {
    return (value === null || value === undefined) ? null : String(value);
  }
  __lgJava.log = function (message) {
    var text = (message === null || message === undefined) ? '' : String(message);
    __lgActionEmit('log', { message: text });
    return text;
  };
  __lgJava.toast = function (message) {
    var text = (message === null || message === undefined) ? '' : String(message);
    __lgActionEmit('toast', { message: text, long: false });
    return text;
  };
  __lgJava.longToast = function (message) {
    var text = (message === null || message === undefined) ? '' : String(message);
    __lgActionEmit('toast', { message: text, long: true });
    return text;
  };
  __lgJava.open = function (name, url, title, origin) {
    __lgActionEmit('open', {
      name: __lgOptString(name) === null ? '' : __lgOptString(name),
      url: __lgOptString(url),
      title: __lgOptString(title),
      origin: __lgOptString(origin)
    });
  };
  __lgJava.searchBook = function (key, searchScope) {
    __lgActionEmit('searchBook', {
      key: __lgOptString(key) === null ? '' : __lgOptString(key),
      scope: __lgOptString(searchScope)
    });
  };
  __lgJava.addBook = function (bookUrl) {
    __lgActionEmit('addBook', {
      url: __lgOptString(bookUrl) === null ? '' : __lgOptString(bookUrl)
    });
  };
  __lgJava.showPhoto = function (src) {
    __lgActionEmit('showPhoto', {
      src: __lgOptString(src) === null ? '' : __lgOptString(src)
    });
  };
  __lgJava.openUrl = function (url) {
    __lgActionEmit('openUrl', {
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

__lgJava.log('RED_LOG');
__lgJava.toast('RED_TOAST');
JSON.stringify(__lgActions);
process.stdout.write(JSON.stringify({count: __lgActions.length, actions: __lgActions}));
