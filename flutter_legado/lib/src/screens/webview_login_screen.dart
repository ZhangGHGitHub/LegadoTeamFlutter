import 'dart:convert';
import 'dart:io';


import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/book_api.dart';
import '../services/platform_channel.dart';
import '../utils/url_utils.dart';
import '../widgets/legado_app_bar.dart';
import 'source_login_screen.dart';

/// WebView 登录页（对齐原版 WebViewLoginFragment，UI_MD3_PLAN.md 登录域重构）
///
/// 无 loginUi 表单的书源经 [SourceLoginEntry] 分流进入本页：
/// - 内置 WebView 打开 loginUrl（绝对化 + 书源 header 附加头）；
/// - 页面每次开始/结束加载时读取系统 CookieManager（CookieBridge 通道，
///   对齐原版 CookieManager.getCookie → CookieStore.setCookie 链路），
///   自动落库为书源 loginHeader（{"Cookie": ...}，请求路径由 Rust 自动合并）；
/// - 顶栏「检测」= 重载当前页校验 Cookie，加载完成后提示成功并返回；
/// - 非 http(s) 跳转提示后转外部打开；「手动编辑 Cookie」入口保留既有
///   手动凭据页（菜单次级入口，能力不删）。
class WebViewLoginScreen extends StatefulWidget {
  /// 书源 URL（loginHeader 落库键）
  final String sourceUrl;

  /// 书源名称（顶栏标题）
  final String sourceName;

  /// 登录链接（书源 loginUrl 字段）
  final String loginUrl;

  /// 书源 header 字段原始值（JSON 或 kv 串，解析失败忽略）
  final String? header;

  /// BookApi（putLoginHeader 落库）
  final BookApi api;

  const WebViewLoginScreen({
    super.key,
    required this.sourceUrl,
    required this.sourceName,
    required this.loginUrl,
    this.header,
    required this.api,
  });

  /// 解析书源 header 字段为附加请求头（对齐原版 toWebViewRequestConfig：
  /// JSON 对象优先，失败按 k=v&k=v 解析，均失败返回空）。
  /// 静态可测（source_login_screen_test 覆盖）。
  static Map<String, String> parseSourceHeaderMap(String? header) {
    final raw = header?.trim() ?? '';
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries)
            if (e.value != null) e.key.toString(): e.value.toString(),
        };
      }
    } catch (_) {}
    // kv 串兜底：k=v&k2=v2（v 可含 =）
    final map = <String, String>{};
    for (final pair in raw.split('&')) {
      final i = pair.indexOf('=');
      if (i <= 0) continue;
      final k = pair.substring(0, i).trim();
      final v = pair.substring(i + 1).trim();
      if (k.isNotEmpty) map[k] = v;
    }
    return map;
  }

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  late final WebViewController _controller;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final headers = WebViewLoginScreen.parseSourceHeaderMap(widget.header);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => _syncCookie(url),
          onPageFinished: (url) async {
            await _syncCookie(url);
            if (_checking && mounted) {
              setState(() => _checking = false);
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('登录检测完成')));
              Navigator.of(context).pop(true);
            }
          },
          onNavigationRequest: (request) {
            final scheme = Uri.tryParse(request.url)?.scheme ?? '';
            if (scheme != 'http' && scheme != 'https') {
              // 非 http(s) 跳转：提示后转外部打开（对齐原版 longSnackbar）
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('即将跳转到其他应用打开：${request.url}')),
                );
              }
              launchUrl(
                Uri.parse(request.url),
                mode: LaunchMode.externalApplication,
              );
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
    final initialUrl = resolveAbsoluteUrl(widget.sourceUrl, widget.loginUrl);
    if (headers.isEmpty) {
      _controller.loadRequest(Uri.parse(initialUrl));
    } else {
      _controller.loadRequest(Uri.parse(initialUrl), headers: headers);
    }
  }

  /// 读取系统 Cookie 并落库 loginHeader（对齐原版 onPageStarted/Finished
  /// 的 CookieManager.getCookie → CookieStore.setCookie）
  ///
  /// [iOS 轨 P2-B] iOS 的 WKWebView Cookie 存于 WKHTTPCookieStore，
  /// webview_flutter 不暴露读取接口——经 JS document.cookie 读取
  /// （局限：httpOnly Cookie 读不到，该类登录态需源在 JS 侧可续期；
  /// Android 通道含 httpOnly 无此限制）
  Future<void> _syncCookie(String url) async {
    if (Platform.isIOS) {
      try {
        final raw = await _controller
            .runJavaScriptReturningResult('document.cookie');
        final cookie = raw.toString();
        if (cookie.isEmpty || cookie == 'null') return;
        await widget.api.putLoginHeader(
          widget.sourceUrl,
          jsonEncode({'Cookie': cookie}),
        );
      } catch (_) {
        // Cookie 读取/落库失败不阻断页面（对齐原版尽力而为语义）
      }
      return;
    }
    try {
      final cookie = await PlatformChannel.getCookie(url);
      if (cookie.isEmpty) return;
      await widget.api.putLoginHeader(
        widget.sourceUrl,
        jsonEncode({'Cookie': cookie}),
      );
    } catch (_) {
      // Cookie 读取/落库失败不阻断页面（对齐原版尽力而为语义）
    }
  }

  /// 「检测」：重载当前页校验 Cookie，加载完成后返回成功
  Future<void> _verify() async {
    if (_checking) return;
    setState(() => _checking = true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('正在检测 Cookie…')));
    try {
      await _controller.reload();
    } catch (_) {
      setState(() => _checking = false);
    }
  }

  Future<void> _openManual() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SourceLoginScreen(
          sourceUrl: widget.sourceUrl,
          sourceName: widget.sourceName,
          loginUrl: widget.loginUrl,
        ),
      ),
    );
    if (saved == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(
        title: Text('登录 ${widget.sourceName}'),
        actions: [
          if (_checking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Symbols.fact_check_rounded),
            tooltip: '检测',
            onPressed: _checking ? null : _verify,
          ),
          PopupMenuButton<String>(
            tooltip: '更多选项',
            // [LAYOUT_PLAN P2] 菜单在顶栏下方展开，不覆盖顶栏
            position: PopupMenuPosition.under,
            onSelected: (value) {
              switch (value) {
                case 'manual':
                  _openManual();
                case 'open_external':
                  _openExternal();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'manual', child: Text('手动编辑 Cookie')),
              PopupMenuItem(
                value: 'open_external',
                child: Text('在浏览器中打开'),
              ),
            ],
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(resolveAbsoluteUrl(widget.sourceUrl, widget.loginUrl));
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
