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
/// 执行并经 `submitWebviewResultWithCookies` 回传（B1：结果 + 域 cookie
/// 回流，cookie 为空时语义同 [BookApi.submitWebviewResult]）。
///
/// 无可见 UI（后台 WebView）；桌面无 WebView 能力时回传错误串唤醒等待方。
///
/// — WebViewBridge + Bridge｜2026-08-13｜项 B/B1 cookie 回流
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
      // B1 加法式字段（项 B/G4）：书源 key 随载荷下发，Android 原生路径
      // 按 isRule 同等口径注入 java/source/cache 接口；B4 起再补 `cookie`
      // （Rust 侧按请求域从 JS cookie store 预取的域 cookie 推入）
      'sourceKey': (event['source_key'] ?? '').toString(),
    };
    try {
      final outcome =
          await PlatformBridgeService.instance.dispatchPayloadWithCookies(
        payload,
      );
      await api.submitWebviewResultWithCookies(
        key,
        outcome.result,
        outcome.cookiesJson,
      );
    } catch (e, st) {
      debugPrint('[WebViewBridge] 执行/回传失败：$e\n$st');
      await api.submitWebviewResult(key, '[ERROR] $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
