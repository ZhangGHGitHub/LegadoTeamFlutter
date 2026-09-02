import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'bridge_http.dart';
import 'package:path_provider/path_provider.dart';

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';
import 'book_api.dart';
import 'cover_decode_loader.dart';
import 'platform_bridge_service.dart';

part 'rust_api_decode.part.dart';
part 'rust_api_sources.part.dart';
part 'rust_api_search_rss.part.dart';
part 'rust_api_reader_data.part.dart';
part 'rust_api_discovery_cache.part.dart';
part 'rust_api_media_format.part.dart';
part 'rust_api_sync_tools.part.dart';
part 'rust_api_content_ext.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：RustApi 按域拆为 mixin 组合，
// 各 mixin 方法原样搬移、合集实现 BookApi，零行为变更。

/// Rust FFI 统一访问层
///
/// 所有数据库操作通过 flutter_rust_bridge 生成的桥接函数调用 Rust 侧。
/// 尚未在 Rust FFI 中暴露的方法使用 Dart 侧 fallback 实现。
class RustApi
    with RustApiDecode,
        RustApiSources,
        RustApiSearchRss,
        RustApiReaderData,
        RustApiDiscoveryCache,
        RustApiMediaFormat,
        RustApiSyncTools,
        RustApiContentExt
    implements BookApi {
  RustApi();

  bool _initialized = false;

  /// 初始化 Rust 运行时和数据库连接
  @override
  Future<void> initialize() async {
    if (_initialized) return;

    final lib = _resolveFfiLibrary();
    await bridge.RustLib.init(externalLibrary: lib);
    await bridge.init();

    final dbPath = await _defaultDbPath();
    await bridge.dbOpen(path: dbPath);

    // [UI-fix v2.0.2 | 2026-08-06] TTS 缓存目录初始化接线 — QoderCN
    await _initTtsCacheDir();

    // 注入真实设备 ID（书山聚合等源登录登记设备 + 正文 X-Device-Id 校验；
    // 对齐原版 AppConst.androidId = Settings.Secure.ANDROID_ID）
    await _injectDeviceId();

    _initialized = true;
  }

  /// 读取系统 ANDROID_ID 并注入 Rust（书山正文解密依赖设备匹配）
  Future<void> _injectDeviceId() async {
    // [iOS 轨 P2] iOS 用 identifierForVendor（ANDROID_ID 通道仅 Android 注册）
    if (Platform.isIOS) {
      try {
        final ios = await DeviceInfoPlugin().iosInfo;
        final idfv = ios.identifierForVendor;
        if (idfv != null && idfv.isNotEmpty) {
          await bridge.setDeviceId(deviceId: idfv);
          debugPrint('[RustApi] 设备 ID 注入完成（iOS IDFV）：$idfv');
        }
      } catch (e) {
        debugPrint('[RustApi] 设备 ID 注入失败（iOS）：$e');
      }
      return;
    }
    try {
      const channel = MethodChannel('legado/device_id');
      final androidId = await channel.invokeMethod<String>('getAndroidId');
      if (androidId != null && androidId.isNotEmpty) {
        await bridge.setDeviceId(deviceId: androidId);
        debugPrint('[RustApi] 设备 ID 注入完成：$androidId');
      }
    } catch (e) {
      debugPrint('[RustApi] 设备 ID 注入失败：$e');
    }
  }

  /// 设置 TTS 音频缓存目录（应用初始化时调用）— QoderCN
  ///
  /// Rust 默认落系统临时目录（Android 可能不可写），改指向应用支持目录
  /// 下的 tts_cache 子目录；取不到路径时保留默认并仅记日志，不阻断初始化。
  Future<void> _initTtsCacheDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}tts_cache');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final ok = await bridge.ttsSetCacheDir(path: dir.path);
      debugPrint('[RustApi] ttsSetCacheDir -> ${dir.path}（ok=$ok）');
    } catch (e) {
      debugPrint('[RustApi] ttsSetCacheDir 初始化失败，保留 Rust 默认目录：$e');
    }
  }

  /// 解析 FFI 动态库，支持多路径搜索
  ///
  /// flutter_rust_bridge 生成代码中的 ioDirectory 路径可能不正确（workspace 结构），
  /// 因此这里主动搜索 DLL 并传入 RustLib.init()。
  ExternalLibrary? _resolveFfiLibrary() {
    // Android 由系统加载 liblegado_ffi.so，无需指定路径
    if (Platform.isAndroid) return null;

    // [iOS 轨 P1] 静态链接：Rust staticlib（-force_load 进 Runner 可执行文件），
    // 符号经 process() 查找。FRB 默认 loader 只尝试 dylib/framework，不适用。
    if (Platform.isIOS) {
      return ExternalLibrary.process(iKnowHowToUseIt: true);
    }

    final String libName;
    if (Platform.isWindows) {
      libName = 'legado_ffi.dll';
    } else if (Platform.isMacOS) {
      libName = 'liblegado_ffi.dylib';
    } else {
      libName = 'liblegado_ffi.so';
    }

    final sep = Platform.pathSeparator;
    final searchPaths = <String>[];

    // 策略 1：exe 所在目录
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      searchPaths.add('$exeDir$sep$libName');
      // 从 exe 目录向上 5 级到 flutter_legado/，再找 rust/target
      final projectFromExe = File(
        Platform.resolvedExecutable,
      ).parent.parent.parent.parent.parent.path;
      // debug 优先（匹配 flutter run 默认 debug 模式）
      searchPaths.add(
        '$projectFromExe$sep..${sep}rust${sep}target${sep}debug$sep$libName',
      );
      searchPaths.add(
        '$projectFromExe$sep..${sep}rust${sep}target${sep}release$sep$libName',
      );
    } catch (_) {}

    // 策略 2：当前工作目录（flutter run 时通常为 flutter_legado/）
    try {
      final cwd = Directory.current.path;
      searchPaths.add(
        '$cwd$sep..${sep}rust${sep}target${sep}debug$sep$libName',
      );
      searchPaths.add(
        '$cwd$sep..${sep}rust${sep}target${sep}release$sep$libName',
      );
      // 也检查 cwd 本身是否就是项目根目录
      searchPaths.add('$cwd${sep}rust${sep}target${sep}debug$sep$libName');
      searchPaths.add('$cwd${sep}rust${sep}target${sep}release$sep$libName');
    } catch (_) {}

    for (final path in searchPaths) {
      try {
        if (File(path).existsSync()) {
          return ExternalLibrary.open(path);
        }
      } catch (_) {
        // DLL 存在但加载失败（缺少依赖等），继续尝试下一个
        continue;
      }
    }

    // 找不到时返回 null，让 flutter_rust_bridge 使用默认加载逻辑
    return null;
  }

  /// 获取默认数据库路径
  Future<String> _defaultDbPath() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}${Platform.pathSeparator}legado.db';
    }
    return '${Directory.current.path}${Platform.pathSeparator}legado.db';
  }

  /// 获取 Rust 引擎版本号
  @override
  Future<String> getVersion() => bridge.version();
}
