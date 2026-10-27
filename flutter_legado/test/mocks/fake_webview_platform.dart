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
}

/// 假控制器：记录加载的 HTML/URL，JS 调用全部 no-op
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

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setUserAgent(String? userAgent) async {
    this.userAgent = userAgent;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

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
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => '';
}

/// 假导航代理（页面只把代理挂到控制器，不会回调）
class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

/// 假 WebView 组件（占位，不创建原生视图）
class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
