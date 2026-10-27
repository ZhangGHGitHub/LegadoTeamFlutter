// 最小 WebViewPlatform 假实现（桌面测试宿主用）
//
// webview_flutter_platform_interface 是 webview_flutter 的传递依赖，
// 测试仅用它注入最小平台假实现（不改 pubspec）。
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:flutter/widgets.dart';

/// 最小 WebViewPlatform 假实现（仅满足控制器/组件创建与加载调用）
class FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      FakeWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      FakeWebViewWidget(params);

  /// Cookie 管理器假实现（批21b：Cookie 预写/回流用例）
  ///
  /// 复用单实例，便于用例在页面生命周期回调前预置 `cookies`。
  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) =>
      cookieManager ??= FakeWebViewCookieManager(params);

  static FakeWebViewCookieManager? cookieManager;

  /// 用例间隔离（重建 Cookie 管理器）
  static void resetCookieManager() {
    cookieManager = null;
  }

  /// 批21f P2-1：下一个控制器注册通道失败（用例在 pump 前置位）
  static bool failNextJavaScriptChannelAdd = false;
}

/// 假控制器：记录加载的 HTML/URL、JS 调用、JavaScriptChannel 注册
class FakeWebViewController extends PlatformWebViewController {
  FakeWebViewController(super.params) : super.implementation() {
    lastCreated = this;
  }

  /// 最近创建的控制器（供用例断言 UA/HTML/URL 等调用参数）
  static FakeWebViewController? lastCreated;

  String? loadedHtml;
  String? loadedBaseUrl;
  Uri? loadedUri;
  Map<String, String>? loadedHeaders;
  String? userAgent;

  /// 页面标题（供 `getTitle()` 读取；默认为空，模拟页面未就绪）
  String? title;

  /// 已注册的 JavaScriptChannel（批21b：宿主桥）
  final List<JavaScriptChannelParams> javaScriptChannels = [];

  /// `runJavaScript` 调用序列（批21b：注入顺序断言）
  final List<String> javaScriptCalls = [];

  /// `runJavaScriptReturningResult` 调用序列
  final List<String> javaScriptResultCalls = [];

  /// 导航代理（供组件测试模拟 onPageStarted/onPageFinished）
  PlatformNavigationDelegate? navigationDelegate;

  /// 批21f P2-1：注册通道失败注入（验证看门狗只在通道可用时臂）
  bool failAddJavaScriptChannel = false;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<String?> getTitle() async => title;

  @override
  Future<String?> getUserAgent() async => userAgent;

  @override
  Future<void> setUserAgent(String? userAgent) async {
    this.userAgent = userAgent;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    navigationDelegate = handler;
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    if (failAddJavaScriptChannel ||
        FakeWebViewPlatform.failNextJavaScriptChannelAdd) {
      throw StateError('addJavaScriptChannel failed (test)');
    }
    javaScriptChannels.add(params);
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    loadedHtml = html;
    loadedBaseUrl = baseUrl;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUri = params.uri;
    loadedHeaders = params.headers;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    javaScriptCalls.add(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    javaScriptResultCalls.add(javaScript);
    return '';
  }

  /// 按名查找已注册通道（未注册返回 null）
  JavaScriptChannelParams? channelNamed(String name) {
    for (final channel in javaScriptChannels) {
      if (channel.name == name) return channel;
    }
    return null;
  }

  /// 模拟页面经通道发消息（未注册通道时静默忽略）
  void emitChannelMessage(String name, String message) {
    channelNamed(name)?.onMessageReceived(JavaScriptMessage(message: message));
  }

  /// 模拟 onPageStarted（导航代理未挂载时静默忽略）
  void emitPageStarted(String url) {
    final delegate = navigationDelegate;
    if (delegate is FakeNavigationDelegate) delegate.emitPageStarted(url);
  }

  /// 模拟 onPageFinished（导航代理未挂载时静默忽略）
  void emitPageFinished(String url) {
    final delegate = navigationDelegate;
    if (delegate is FakeNavigationDelegate) delegate.emitPageFinished(url);
  }

  /// 模拟 onWebResourceError（批21f P2-1：主框架错误后同 URL 重试）
  void emitWebResourceError(String description, {bool isForMainFrame = true}) {
    final delegate = navigationDelegate;
    if (delegate is FakeNavigationDelegate) {
      delegate.emitWebResourceError(
        description,
        isForMainFrame: isForMainFrame,
      );
    }
  }
}

/// 假导航代理（记录回调，供用例手动触发页面生命周期）
class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation() {
    lastCreated = this;
  }

  static FakeNavigationDelegate? lastCreated;

  PageEventCallback? pageStartedCallback;
  PageEventCallback? pageFinishedCallback;
  UrlChangeCallback? urlChangeCallback;
  WebResourceErrorCallback? webResourceErrorCallback;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    pageStartedCallback = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    pageFinishedCallback = onPageFinished;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {
    urlChangeCallback = onUrlChange;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    webResourceErrorCallback = onWebResourceError;
  }

  void emitPageStarted(String url) => pageStartedCallback?.call(url);

  void emitPageFinished(String url) => pageFinishedCallback?.call(url);

  /// 批21f P2-1：模拟主框架/子资源加载错误
  void emitWebResourceError(String description, {bool isForMainFrame = true}) {
    webResourceErrorCallback?.call(
      WebResourceError(
        errorCode: -1,
        description: description,
        isForMainFrame: isForMainFrame,
      ),
    );
  }
}

/// 假 Cookie 管理器（记录预写/回流读取）
class FakeWebViewCookieManager extends PlatformWebViewCookieManager {
  FakeWebViewCookieManager(super.params) : super.implementation() {
    lastCreated = this;
  }

  static FakeWebViewCookieManager? lastCreated;

  /// `getCookies` 返回值（用例可预置）
  final List<WebViewCookie> cookies = [];

  /// `setCookie` 调用记录
  final List<WebViewCookie> setCookieCalls = [];

  bool clearCookiesCalled = false;

  @override
  Future<bool> clearCookies() async {
    clearCookiesCalled = true;
    final had = cookies.isNotEmpty;
    cookies.clear();
    return had;
  }

  @override
  Future<void> setCookie(WebViewCookie cookie) async {
    setCookieCalls.add(cookie);
  }

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) async => List.of(cookies);
}

/// 假 WebView 组件（占位，不创建原生视图）
class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
