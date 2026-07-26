/// Rust FFI 桥接服务
///
/// 通过 `dart:ffi` 直接加载 legado-ffi 动态库，绑定 C ABI 函数。
/// 所有底层 FFI 调用均使用 `catch_unwind` 在 Rust 侧保护，Dart 侧仅做指针与字符串转换。
///
/// 响应协议：
/// - 简单函数（`legado_init`、`legado_db_open`）返回 `int` 错误码
/// - 字符串函数（`legado_version`、`legado_parse_rule`、`legado_http_get`）
///   返回 `*mut c_char`，需用 `legado_free_string` 释放
/// - JSON 响应统一格式：`{"code": 0, "data": ..., "error": ...}`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

// ─── FFI 函数签名 typedef ─────────────────────────────────────

typedef _LegadoInitNative = Int32 Function();
typedef _LegadoInitDart = int Function();

typedef _LegadoVersionNative = Pointer<Utf8> Function();
typedef _LegadoVersionDart = Pointer<Utf8> Function();

typedef _LegadoFreeStringNative = Void Function(Pointer<Utf8>);
typedef _LegadoFreeStringDart = void Function(Pointer<Utf8>);

typedef _LegadoParseRuleNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _LegadoParseRuleDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _LegadoHttpGetNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _LegadoHttpGetDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _LegadoDbOpenNative = Int32 Function(Pointer<Utf8>);
typedef _LegadoDbOpenDart = int Function(Pointer<Utf8>);

// ─── 异常类型 ──────────────────────────────────────────────────

/// FFI 调用返回的错误
class LegadoFfiException implements Exception {
  final int code;
  final String message;

  LegadoFfiException(this.code, this.message);

  @override
  String toString() => 'LegadoFfiException(code=$code, message=$message)';
}

// ─── RustBridge ───────────────────────────────────────────────

/// Rust FFI 桥接服务
class RustBridge {
  bool _initialized = false;

  late final DynamicLibrary _lib;

  // FFI 函数引用（init 后绑定）
  late final _LegadoInitDart _nativeInit;
  late final _LegadoVersionDart _nativeVersion;
  late final _LegadoFreeStringDart _nativeFreeString;
  late final _LegadoParseRuleDart _nativeParseRule;
  late final _LegadoHttpGetDart _nativeHttpGet;
  late final _LegadoDbOpenDart _nativeDbOpen;

  /// 是否已完成初始化
  bool get isInitialized => _initialized;

  /// 初始化 Rust FFI 桥接
  ///
  /// 加载动态库并绑定所有 FFI 函数。应在 App 启动时调用一次。
  Future<void> init() async {
    if (_initialized) return;

    _lib = _openDynamicLibrary();

    // 绑定 FFI 函数
    _nativeInit =
        _lib.lookupFunction<_LegadoInitNative, _LegadoInitDart>('legado_init');
    _nativeVersion = _lib.lookupFunction<_LegadoVersionNative, _LegadoVersionDart>(
        'legado_version');
    _nativeFreeString = _lib.lookupFunction<_LegadoFreeStringNative,
        _LegadoFreeStringDart>('legado_free_string');
    _nativeParseRule = _lib.lookupFunction<_LegadoParseRuleNative,
        _LegadoParseRuleDart>('legado_parse_rule');
    _nativeHttpGet = _lib
        .lookupFunction<_LegadoHttpGetNative, _LegadoHttpGetDart>('legado_http_get');
    _nativeDbOpen = _lib.lookupFunction<_LegadoDbOpenNative, _LegadoDbOpenDart>(
        'legado_db_open');

    // 调用 Rust 侧初始化（触发 tokio runtime 创建）
    final code = _nativeInit();
    if (code != 0) {
      throw LegadoFfiException(code, 'legado_init failed with code $code');
    }

    _initialized = true;
    debugPrint('[RustBridge] Rust FFI 桥接初始化完成 v${await version()}');
  }

  /// 释放 Rust FFI 资源
  Future<void> dispose() async {
    if (!_initialized) return;
    // 当前 Rust 侧无显式 shutdown，仅标记状态
    debugPrint('[RustBridge] Rust FFI 桥接已释放');
    _initialized = false;
  }

  // ─── Dart 友好 API ───────────────────────────────────────────

  /// 获取 Rust 库版本号
  Future<String> version() async {
    _ensureInitialized();
    return _runGuarded(() {
      final ptr = _nativeVersion();
      try {
        return ptr.toDartString();
      } finally {
        if (ptr != nullptr) {
          _nativeFreeString(ptr);
        }
      }
    });
  }

  /// 规则解析（占位，待 Rust 侧接入 legado-parser）
  ///
  /// [content] 待解析内容
  /// [rule] 规则表达式
  /// [ruleType] 规则类型（如 "css"、"xpath"、"regex"）
  Future<Map<String, dynamic>> parseRule(
      String content, String rule, String ruleType) async {
    _ensureInitialized();
    return _runGuarded(() {
      final cContent = content.toNativeUtf8();
      final cRule = rule.toNativeUtf8();
      final cRuleType = ruleType.toNativeUtf8();
      try {
        final resultPtr = _nativeParseRule(cContent, cRule, cRuleType);
        return _decodeJsonResponse(resultPtr);
      } finally {
        calloc.free(cContent);
        calloc.free(cRule);
        calloc.free(cRuleType);
      }
    });
  }

  /// HTTP GET（占位，待 Rust 侧接入 legado-net）
  Future<Map<String, dynamic>> httpGet(String url) async {
    _ensureInitialized();
    return _runGuarded(() {
      final cUrl = url.toNativeUtf8();
      try {
        final resultPtr = _nativeHttpGet(cUrl);
        return _decodeJsonResponse(resultPtr);
      } finally {
        calloc.free(cUrl);
      }
    });
  }

  /// 打开数据库（占位，待 Rust 侧接入 legado-db）
  Future<void> dbOpen(String path) async {
    _ensureInitialized();
    return _runGuarded(() {
      final cPath = path.toNativeUtf8();
      try {
        final code = _nativeDbOpen(cPath);
        if (code != 0) {
          throw LegadoFfiException(code, 'legado_db_open failed with code $code');
        }
      } finally {
        calloc.free(cPath);
      }
    });
  }

  // ─── 内部辅助 ────────────────────────────────────────────────

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('RustBridge 尚未初始化，请先调用 init()');
    }
  }

  /// 加载平台对应的动态库
  DynamicLibrary _openDynamicLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('liblegado_ffi.so');
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('legado_ffi.dll');
    } else if (Platform.isMacOS) {
      return DynamicLibrary.open('liblegado_ffi.dylib');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('liblegado_ffi.so');
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  /// 将 FFI 调用放入 isolate 友好的 Future 中
  Future<T> _runGuarded<T>(T Function() fn) {
    return Future<T>.sync(() {
      try {
        return fn();
      } on LegadoFfiException {
        rethrow;
      } catch (e) {
        throw LegadoFfiException(-1, 'FFI call failed: $e');
      }
    });
  }

  /// 解码 FFI 返回的 JSON 响应，并释放底层 C 字符串
  Map<String, dynamic> _decodeJsonResponse(Pointer<Utf8> ptr) {
    if (ptr == nullptr) {
      throw LegadoFfiException(-1, 'FFI returned null pointer');
    }
    try {
      final jsonStr = ptr.toDartString();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final code = decoded['code'] as int? ?? -1;
      if (code != 0) {
        final error = decoded['error']?.toString() ?? 'unknown error';
        throw LegadoFfiException(code, error);
      }
      return decoded;
    } finally {
      _nativeFreeString(ptr);
    }
  }

  /// 调试用：打印日志
  static void debugPrint(String message) {
    // ignore: avoid_print
    print(message);
  }
}
