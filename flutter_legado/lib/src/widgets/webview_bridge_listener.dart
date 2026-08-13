import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../services/platform_bridge_service.dart';

/// 全局 BackstageWebView DOM 执行监听器（SOURCE_DIFF P1）
///
/// 挂载于 MaterialApp.builder：订阅 BookApi.webviewRequestStream，
/// Rust 侧 `@webjs` / 正文 webJs / `java.webView*` 挂起时用真实 WebView
/// 执行并经 [BookApi.submitWebviewResult] 回传。
///
/// 无可见 UI（后台 WebView）；桌面无 WebView 能力时回传错误串唤醒等待方。
///
/// — WebViewBridge + Bridge｜2026-08-13
class WebViewBridgeListener extends ConsumerStatefulWidget {
  final Widget child;

  const WebViewBridgeListener({super.key, required this.child});

  @override
  ConsumerState<WebViewBridgeListener> createState() =>
      _WebViewBridgeListenerState();
}

class _WebViewBridgeListenerState extends ConsumerState<WebViewBridgeListener> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  /// 串行执行，避免并发 WebView 抢主线程
  Future<void> _chain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(bookApiProvider)
        .webviewRequestStream()
        .listen(_onRequest, onError: (Object _) {});
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onRequest(Map<String, dynamic> event) {
    if (!mounted) return;
    final key = (event['key'] ?? '').toString();
    if (key.isEmpty) return;
    _chain = _chain.then((_) => _handle(event)).catchError((Object e) {
      debugPrint('[WebViewBridge] 处理失败：$e');
    });
  }

  Future<void> _handle(Map<String, dynamic> event) async {
    final api = ref.read(bookApiProvider);
    final key = (event['key'] ?? '').toString();
    // 将 snake_case 通道字段映射为 PlatformBridgeService 载荷
    final payload = <String, dynamic>{
      'action': (event['action'] ?? 'webView').toString(),
      'html': (event['html'] ?? '').toString(),
      'url': (event['url'] ?? '').toString(),
      'js': (event['js'] ?? '').toString(),
      'sourceRegex': (event['source_regex'] ?? '').toString(),
      'overrideUrlRegex': (event['override_url_regex'] ?? '').toString(),
      'cacheFirst': event['cache_first'] == true,
      'delayTime': event['delay_time'] ?? 0,
      'isRule': event['is_rule'] == true,
      'result': (event['result'] ?? '').toString(),
    };
    try {
      final out =
          await PlatformBridgeService.instance.dispatchPayload(payload);
      await api.submitWebviewResult(key, out);
    } catch (e, st) {
      debugPrint('[WebViewBridge] 执行/回传失败：$e\n$st');
      await api.submitWebviewResult(key, '[ERROR] $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
