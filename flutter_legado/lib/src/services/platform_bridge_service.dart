import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../routes.dart';

/// Rust 平台桥接载荷拦截执行服务（Task #114 批次2 跨轨管线③） — QoderCN
///
/// Rust 侧 `legado-js/src/host_api/platform.rs` 对 7 个平台交互 API 返回
/// 结构化 JSON 桥接载荷（无头运行时无法执行真实 WebView / Intent）：
///
/// | JS API | action | 语义 |
/// |---|---|---|
/// | webView | `webView` | 加载页面执行 JS，返回执行结果 |
/// | webViewGetSource | `webViewGetSource` | 嗅探匹配 sourceRegex 的资源 URL |
/// | webViewGetOverrideUrl | `webViewGetOverrideUrl` | 拦截匹配正则的跳转 URL |
/// | showBrowser | `openBrowser` | 应用内浏览器打开 |
/// | startBrowser | `startBrowser` | 外部浏览器打开 |
/// | openUrl | `openUrl` | 打开 URL（内置/外部） |
/// | openVideoPlayer | `openVideoPlayer` | 拉起视频播放器 |
///
/// # 拦截通道与回传机制
///
/// Rust 侧这些 API 将载荷作为 JS 调用返回值**同步返回**（无独立事件流、
/// 无等待回传通道，与验证码通道 Task #90 的挂起模式不同）。载荷因此随
/// FFI 解析类调用（webbook*/explore/reader/login/jsEval 等）的结果字符串
/// 抵达 Flutter 侧。本服务提供两个入口：
///
/// 1. [interceptResult]：FFI 结果管线拦截点。结果整体恰为桥接载荷时：
///    - 结果类 action（webView/webViewGetSource/webViewGetOverrideUrl）：
///      用真实 WebView 执行并以**真实结果替换载荷原样回传**，保持 Kotlin
///      `BackstageWebView` 同步取数语义（书源规则中此类调用通常即终端表达式）；
///    - 动作类 action（openBrowser/startBrowser/openUrl/openVideoPlayer）：
///      异步拉起 UI 动作，结果返回空串（Kotlin 对应 API 无有效返回值）。
/// 2. [dispatchPayload]：供任意持有载荷 Map 的调用方直接分发执行。
///
/// # 平台降级
///
/// webview_flutter 现依赖栈仅覆盖 Android / iOS / macOS（pubspec.lock 无
/// Windows/Linux 实现），结果类 action 在桌面端返回 `[ERROR] ...`（沿用
/// Rust 验证码通道的错误串约定）；动作类 action 的内置浏览器在桌面端由
/// BrowserScreen 自身降级为 url_launcher 方案。
class PlatformBridgeService {
  PlatformBridgeService._();

  /// 全局单例（服务层无依赖注入，对齐 CrashLogService 模式）
  static final PlatformBridgeService instance = PlatformBridgeService._();

  /// 全局 Navigator Key：服务层无 BuildContext，经此分发页面跳转 / SnackBar。
  ///
  /// 由 MaterialApp.navigatorKey 装配（见 app.dart）。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'platformBridge');

  /// Rust 侧 7 个桥接 action 的合法取值（openBrowser 对应 JS API showBrowser）
  static const Set<String> supportedActions = {
    'webView',
    'webViewGetSource',
    'webViewGetOverrideUrl',
    'openBrowser',
    'startBrowser',
    'openUrl',
    'openVideoPlayer',
  };

  /// 页面加载 / 嗅探总超时（对齐 Kotlin BackstageWebView withTimeout 60s）
  static const Duration _webViewTimeout = Duration(seconds: 60);

  /// 当前平台是否具备真实 WebView 能力（对齐 rss_article_detail_screen 判定）
  bool get _webViewSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  NavigatorState? get _navigator => navigatorKey.currentState;

  // ========== 拦截入口 ==========

  /// 判定字符串是否整体为一个平台桥接载荷
  ///
  /// 仅当 trim 后可解析为 JSON 对象且 `action` 属于 [supportedActions] 时成立；
  /// 嵌入在更大结果中的载荷不触发（结构化结果无法安全回填）。
  bool isPlatformBridgePayload(String? raw) => parsePayload(raw) != null;

  /// 解析桥接载荷；非载荷返回 null
  Map<String, dynamic>? parsePayload(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty || !text.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> &&
          supportedActions.contains(decoded['action'])) {
        return decoded;
      }
    } catch (_) {
      // 非 JSON：正常解析结果，忽略
    }
    return null;
  }

  /// FFI 结果管线拦截点：载荷则执行并回传真实结果，否则原样返回
  ///
  /// 供 [RustApi] 解析类方法包装返回值使用；内部异常全捕获，
  /// 任何失败均不抛出、退化为返回原文（保证既有链路不因桥接中断）。
  Future<String> interceptResult(String raw) async {
    final payload = parsePayload(raw);
    if (payload == null) return raw;
    try {
      return await dispatchPayload(payload);
    } catch (e, stack) {
      debugPrint('[PlatformBridge] 执行载荷失败：$e\n$stack');
      return raw;
    }
  }

  /// 分发执行一个桥接载荷，返回应回传给 Rust 调用链的结果字符串
  ///
  /// - 结果类 action：真实 WebView 执行结果（或 `[ERROR] ...`）
  /// - 动作类 action：空串（fire-and-forget，UI 动作已异步拉起）
  Future<String> dispatchPayload(Map<String, dynamic> payload) async {
    final action = (payload['action'] ?? '').toString();
    debugPrint('[PlatformBridge] 拦截动作：$action');
    switch (action) {
      case 'webView':
      case 'webViewGetSource':
      case 'webViewGetOverrideUrl':
        return _runWebViewAction(action, payload);
      case 'openBrowser':
        _showBrowser(
          url: (payload['url'] ?? '').toString(),
          html: (payload['html'] ?? '').toString(),
        );
        return '';
      case 'startBrowser':
        _startBrowser(
          url: (payload['url'] ?? '').toString(),
          title: (payload['title'] ?? '').toString(),
          html: (payload['html'] ?? '').toString(),
        );
        return '';
      case 'openUrl':
        _openUrl(
          url: (payload['url'] ?? '').toString(),
          mimeType: (payload['mimeType'] ?? '').toString(),
        );
        return '';
      case 'openVideoPlayer':
        _openVideoPlayer(
          url: (payload['url'] ?? '').toString(),
          title: (payload['title'] ?? '').toString(),
          isFloat: payload['isFloat'] == true,
        );
        return '';
      default:
        return '';
    }
  }

  // ========== 结果类 action：真实 WebView 执行（对齐 Kotlin BackstageWebView） ==========

  /// 执行 webView / webViewGetSource / webViewGetOverrideUrl
  Future<String> _runWebViewAction(
    String action,
    Map<String, dynamic> payload,
  ) async {
    if (!_webViewSupported) {
      // 桌面无 WebView：返回错误串（对齐 Rust 验证码通道 [ERROR] 约定），
      // 由规则链路按失败处理（Kotlin 此路径会抛异常使规则失败）
      return '[ERROR] WebView 能力在当前平台不可用（仅 Android/iOS/macOS）';
    }
    final url = (payload['url'] ?? '').toString();
    final html = (payload['html'] ?? '').toString();
    final js = (payload['js'] ?? '').toString();
    if (url.isEmpty && html.isEmpty) return '';
    try {
      switch (action) {
        case 'webView':
          return await _webViewEval(url: url, html: html, js: js,
              delayMs: _delayOf(payload));
        case 'webViewGetSource':
          return await _webViewSniffSource(
            url: url,
            html: html,
            js: js,
            sourceRegex: (payload['sourceRegex'] ?? '').toString(),
            delayMs: _delayOf(payload),
          );
        case 'webViewGetOverrideUrl':
          return await _webViewSniffOverrideUrl(
            url: url,
            html: html,
            js: js,
            overrideUrlRegex: (payload['overrideUrlRegex'] ?? '').toString(),
            delayMs: _delayOf(payload),
          );
      }
    } catch (e) {
      debugPrint('[PlatformBridge] $action 执行失败：$e');
      return '[ERROR] $action 执行失败：$e';
    }
    return '';
  }

  /// delayTime 解析（毫秒；Kotlin 无 js 时默认 900ms 等待渲染）
  int _delayOf(Map<String, dynamic> payload) {
    final raw = payload['delayTime'];
    final ms = raw is int ? raw : int.tryParse('$raw') ?? 0;
    return ms < 0 ? 0 : ms;
  }

  /// 构建基础控制器（启用 JS，对齐 Kotlin javaScriptEnabled = true）
  WebViewController _newController() => WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted);

  /// 加载 html（优先）或 url；两者语义对齐 Kotlin loadDataWithBaseURL / loadUrl
  void _load(WebViewController controller, {
    required String url,
    required String html,
  }) {
    if (html.isNotEmpty) {
      final base = Uri.tryParse(url);
      controller.loadHtmlString(
        html,
        baseUrl: base != null && base.hasScheme ? url : null,
      );
    } else {
      final uri = Uri.tryParse(url);
      if (uri != null) controller.loadRequest(uri);
    }
  }

  /// webView：加载页面 → 延时 → 执行 JS（缺省取 outerHTML）→ 返回结果
  Future<String> _webViewEval({
    required String url,
    required String html,
    required String js,
    required int delayMs,
  }) async {
    final controller = _newController();
    await _loadAndWaitFinished(controller, url: url, html: html);
    // 对齐 Kotlin：无 js 时默认等待 900ms 渲染；有 js 时等待 100ms + delayTime
    final waitMs = js.isEmpty ? (delayMs > 0 ? delayMs : 900) : 100 + delayMs;
    await Future<void>.delayed(Duration(milliseconds: waitMs));
    final script =
        js.isNotEmpty ? js : 'document.documentElement.outerHTML';
    final result = await controller.runJavaScriptReturningResult(script);
    return _normalizeJsResult(result);
  }

  /// webViewGetSource：嗅探匹配 sourceRegex 的资源 URL（尽力对齐 Kotlin
  /// SnifferWebClient.onLoadResource：Flutter 无资源加载回调，改为页面
  /// 完成后经 JS 收集 performance 资源条目与 DOM 引用 URL 后按正则匹配；
  /// 若提供 js 先执行以触发动态资源加载）
  Future<String> _webViewSniffSource({
    required String url,
    required String html,
    required String js,
    required String sourceRegex,
    required int delayMs,
  }) async {
    if (sourceRegex.isEmpty) return '';
    final regex = RegExp(sourceRegex);
    final controller = _newController();
    await _loadAndWaitFinished(controller, url: url, html: html);
    if (js.isNotEmpty) {
      // 触发型 JS（如点击播放按钮），fire-and-forget 后等待资源出现
      await controller.runJavaScript(js);
    }
    await Future<void>.delayed(
      Duration(milliseconds: delayMs > 0 ? delayMs : 900),
    );
    // 页面 URL 本身命中优先返回
    final currentUrl = await controller.currentUrl();
    if (currentUrl != null && regex.hasMatch(currentUrl)) return currentUrl;
    final collected = await controller.runJavaScriptReturningResult('''
(function(){
  var urls = [];
  try {
    performance.getEntriesByType('resource').forEach(function(r){ urls.push(r.name); });
  } catch (e) {}
  try {
    document.querySelectorAll('a[href],link[href],img[src],script[src],source[src],iframe[src],video[src],audio[src],embed[src],object[data]')
      .forEach(function(el){
        var u = el.src || el.href || el.data;
        if (u) urls.push(u);
      });
  } catch (e) {}
  return JSON.stringify(urls);
})()
''');
    final urls = _decodeUrlList(collected);
    for (final candidate in urls) {
      if (regex.hasMatch(candidate)) return candidate;
    }
    debugPrint(
      '[PlatformBridge] webViewGetSource：sourceRegex($sourceRegex) 未匹配到资源',
    );
    return '';
  }

  /// webViewGetOverrideUrl：拦截匹配 overrideUrlRegex 的跳转 URL
  /// （对齐 Kotlin SnifferWebClient.shouldOverrideUrlLoading）
  ///
  /// [UI-fix v2.0.2 | 2026-08-06] 合并为单个 NavigationDelegate：
  /// 旧实现在 js 非空时二次调用 _loadAndWaitFinished 重设委托，
  /// 覆盖了 onNavigationRequest 捕获委托并二次加载，导致 JS 分支
  /// 嗅探必超时；现拦截捕获与加载完成等待共用同一委托，
  /// 不重设、不二次 _load。 — QoderCN
  Future<String> _webViewSniffOverrideUrl({
    required String url,
    required String html,
    required String js,
    required String overrideUrlRegex,
    required int delayMs,
  }) async {
    if (overrideUrlRegex.isEmpty) return '';
    final regex = RegExp(overrideUrlRegex);
    final capture = Completer<String>();

    // 初始 URL 即命中：直接返回（对齐 Kotlin loadUrl 前的嗅探路径）
    if (url.isNotEmpty && regex.hasMatch(url)) return url;

    final controller = _newController();
    final finished = Completer<void>();
    void completeFinished() {
      if (!finished.isCompleted) finished.complete();
    }

    // 单一委托：跳转拦截（capture）与加载终态等待共用，避免相互覆盖
    controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (request) {
        if (!capture.isCompleted && regex.hasMatch(request.url)) {
          capture.complete(request.url);
          return NavigationDecision.prevent;
        }
        return NavigationDecision.navigate;
      },
      onPageFinished: (_) => completeFinished(),
      onWebResourceError: (_) => completeFinished(),
      onHttpError: (_) => completeFinished(),
    ));
    _load(controller, url: url, html: html);
    if (js.isNotEmpty) {
      // 触发型 JS：首次加载到达终态后执行以诱发目标跳转（无二次加载）
      unawaited(finished.future
          .timeout(_webViewTimeout, onTimeout: () {})
          .then((_) =>
              Future<void>.delayed(Duration(milliseconds: 100 + delayMs)))
          .then((_) => controller.runJavaScript(js))
          .catchError((Object _) {}));
    }
    try {
      return await capture.future.timeout(_webViewTimeout);
    } on TimeoutException {
      debugPrint(
        '[PlatformBridge] webViewGetOverrideUrl：等待跳转超时'
        '（overrideUrlRegex=$overrideUrlRegex）',
      );
      return '[ERROR] webViewGetOverrideUrl 等待跳转超时';
    }
  }

  /// 加载并等待 onPageFinished（超时/资源错误均按「已到达终态」放行，
  /// 交由后续 JS 阶段兜底，对齐 Kotlin 失败路径由 callback 报错的语义）
  Future<void> _loadAndWaitFinished(
    WebViewController controller, {
    required String url,
    required String html,
  }) {
    final finished = Completer<void>();
    void completeOnce() {
      if (!finished.isCompleted) finished.complete();
    }

    controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) => completeOnce(),
      onWebResourceError: (_) => completeOnce(),
      onHttpError: (_) => completeOnce(),
    ));
    _load(controller, url: url, html: html);
    return finished.future.timeout(_webViewTimeout, onTimeout: () {});
  }

  /// 解析嗅探 JS 返回的 URL 列表（runJavaScriptReturningResult 返回 JSON 串）
  List<String> _decodeUrlList(Object? raw) {
    final text = _normalizeJsResult(raw);
    if (text.isEmpty) return const [];
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {/* 非法 JSON 忽略 */}
    return const [];
  }

  /// 归一化 JS 返回值（对齐 Kotlin StringEscapeUtils.unescapeJson + 去首尾引号）
  String _normalizeJsResult(Object? result) {
    if (result == null) return '';
    if (result is String) {
      var s = result;
      if (s.isEmpty || s == 'null') return '';
      if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is String) return decoded;
        } catch (_) {
          s = s.substring(1, s.length - 1);
        }
      }
      return s;
    }
    return result.toString();
  }

  // ========== 动作类 action：UI 分发（fire-and-forget） ==========

  /// showBrowser → 应用内浏览器（对齐 Kotlin 应用内 WebView 对话框语义）
  void _showBrowser({required String url, required String html}) {
    final navigator = _navigator;
    if (navigator == null) {
      debugPrint('[PlatformBridge] openBrowser：Navigator 未装配，忽略 url=$url');
      return;
    }
    navigator.pushNamed(AppRoutes.browser, arguments: <String, String>{
      'url': url,
      'html': html,
    });
  }

  /// startBrowser → 外部浏览器；携带 html 时外部浏览器无法承载，改走应用内
  void _startBrowser({
    required String url,
    required String title,
    required String html,
  }) {
    if (html.isNotEmpty || url.isEmpty) {
      _showBrowser(url: url, html: html);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showSnackBar('无效的链接：$url');
      return;
    }
    launchUrl(uri, mode: LaunchMode.externalApplication).then((ok) {
      if (!ok) {
        // 外部浏览器拉起失败：降级应用内浏览器
        _showBrowser(url: url, html: '');
      }
    }).catchError((Object e) {
      debugPrint('[PlatformBridge] startBrowser 外部打开失败：$e');
      _showBrowser(url: url, html: '');
    });
    if (title.isNotEmpty) {
      debugPrint('[PlatformBridge] startBrowser：$title');
    }
  }

  /// openUrl → http/https 走应用内浏览器；其他协议（legado:// / yuedu:// 等）
  /// 交由系统处理。
  /// TODO(QoderCN，批次3)：legado:// / yuedu:// 导入协议接入 AssociationScreen
  /// 书源识别流程（需要 UI 轨配合路由参数）。
  void _openUrl({required String url, required String mimeType}) {
    if (url.isEmpty) return;
    if (url.startsWith('http://') || url.startsWith('https://')) {
      _showBrowser(url: url, html: '');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showSnackBar('无效的链接：$url');
      return;
    }
    launchUrl(uri).then((ok) {
      if (!ok) _showSnackBar('无法打开：$url');
    }).catchError((Object e) {
      debugPrint('[PlatformBridge] openUrl 失败：$e');
      _showSnackBar('无法打开：$url');
    });
    if (mimeType.isNotEmpty) {
      debugPrint('[PlatformBridge] openUrl mimeType=$mimeType（平台 Intent 降级为通用打开）');
    }
  }

  /// openVideoPlayer → 内置视频播放页（video_player 已接通）
  ///
  /// isFloat（悬浮窗）当前无对应组件，降级为全屏播放并提示。
  void _openVideoPlayer({
    required String url,
    required String title,
    required bool isFloat,
  }) {
    if (url.isEmpty) return;
    final navigator = _navigator;
    if (navigator == null) {
      debugPrint('[PlatformBridge] openVideoPlayer：Navigator 未装配，忽略');
      return;
    }
    navigator.pushNamed(AppRoutes.video, arguments: <String, String>{
      'videoUrl': url,
      'title': title.isNotEmpty ? title : '视频播放',
    });
    if (isFloat) {
      _showSnackBar('悬浮窗播放暂不支持，已改为全屏播放');
    }
  }

  /// 全局 SnackBar（经 navigatorKey 上下文）
  void _showSnackBar(String message) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
