import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [STAGE-UI-P43UNIFY1] 漫画阅读器 widget 测试公共辅助
///
/// 供 reader_comic_error_placeholder_test（B1 失败占位/骨架块素材断言）与
/// reader_comic_loading_theme_test（B2 加载环/骨架块主题槽断言）复用：
/// 无书源直连（CachedNetworkImage）路径的加载占位断言需要一个「下载永远
/// 进行中」的受控环境——本辅助用本机回环 HTTP 服务器 + path_provider
/// mock 达成，不依赖外网。

/// 启动「挂起」本机 HTTP 服务器：接受连接但永不写响应、永不关闭，
/// 使 cached_network_image（flutter_cache_manager → dio → 真实 socket）
/// 的下载恒定处于「进行中」→ 加载占位（骨架块）在整个测试内驻留。
///
/// 端口随机（bind 0），不与其他测试冲突；监听订阅与服务器同寿命，
/// 进程退出即回收，无需 teardown。
Future<HttpServer> startPendingImageServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    // 故意持有连接：不写响应头、不关闭 → 客户端下载持续 pending
  });
  return server;
}

/// mock path_provider 方法通道（flutter_cache_manager 取缓存目录走
/// `getApplicationSupportPath`）。测试环境无插件实现，不 mock 会抛
/// MissingPluginException → 下载即刻出错 → 加载占位无法驻留断言。
///
/// 通道名/方法名取证：path_provider_platform_interface 2.1.3
/// `MethodChannel('plugins.flutter.io/path_provider')` +
/// `getApplicationSupportPath`（见该包 method_channel_path_provider.dart）。
void mockPathProvider(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('legado_cache_test');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => dir.path,
  );
}
