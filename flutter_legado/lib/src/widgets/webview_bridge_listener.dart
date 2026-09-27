import 'dart:async';
import 'dart:collection';

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
/// B3：执行并发池（对齐上游 WebViewPool 容量 5）——至多 5 个 WebView
/// 并行执行，超出并行度的请求按 FIFO 排队，任务结束后补位队头。
/// 各请求 key 唯一（Rust 侧按 key 唤醒等待方），并行不互相覆盖。
///
/// — WebViewBridge + Bridge｜2026-08-13｜项 B/B1 cookie 回流
/// ｜2026-09-26 项 B/B3 并发池（并行度 5 + FIFO）
class WebViewBridgeListener extends ConsumerStatefulWidget {
  final Widget child;

  const WebViewBridgeListener({super.key, required this.child});

  @override
  ConsumerState<WebViewBridgeListener> createState() =>
      _WebViewBridgeListenerState();
}

class _WebViewBridgeListenerState extends ConsumerState<WebViewBridgeListener> {
  StreamSubscription<Map<String, dynamic>>? _subscription;

  // ========== B3 并发池（对齐上游 WebViewPool 容量 5） ==========

  /// 并行度上限：至多 5 个 WebView 同时执行（对齐上游 WebViewPool 容量 5；
  /// 原单 `_chain` 全串行，多书源并发抓取时互相排队放大延迟）
  static const int _maxConcurrency = 5;

  /// 当前在途任务数（信号量计数）
  int _inFlight = 0;

  /// FIFO 排队：超出并行度的事件按到达顺序排队，槽位释放后补位队头
  final Queue<Map<String, dynamic>> _pending = Queue();

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
    if (_inFlight < _maxConcurrency) {
      _start(event);
    } else {
      _pending.add(event);
    }
  }

  /// 占用一个槽位执行任务；结束时释放槽位并补位队头（FIFO）
  void _start(Map<String, dynamic> event) {
    _inFlight++;
    _handle(event).whenComplete(() {
      _inFlight--;
      if (_pending.isNotEmpty) {
        _start(_pending.removeFirst());
      }
    }).catchError((Object e) {
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
      // 按 isRule 同等口径注入 java/source/cache 接口
      'sourceKey': (event['source_key'] ?? '').toString(),
      // B4（设计文档 §3 项 B）：Rust 按请求 URL 域从 JS cookie store
      // 预取的属域 cookie（"k1=v1; k2=v2"，无则空串）随载荷下发；
      // Android 原生路径 load 前 CookieManager.setCookie 逐对预写，
      // webview_flutter 回退路径 setCookie 等价预写
      'cookie': (event['cookie'] ?? '').toString(),
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
