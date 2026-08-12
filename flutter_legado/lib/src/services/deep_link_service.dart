import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/association/association_state.dart';
import '../routes.dart';
import '../utils/legado_deep_link.dart';

/// 监听 Android `legado://` / `yuedu://` 深链并导航到关联导入页
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const _channel = MethodChannel('legado/deep_link');

  GlobalKey<NavigatorState>? navigatorKey;
  bool _attached = false;
  String? _lastHandled;

  /// 在 [LegadoApp] 首帧后调用；重复调用安全
  Future<void> attach(GlobalKey<NavigatorState> key) async {
    navigatorKey = key;
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null && initial.isNotEmpty) {
        await handleUrl(initial);
      }
    } catch (e) {
      debugPrint('[DeepLink] getInitialLink 失败：$e');
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onLink') {
      final url = call.arguments as String?;
      if (url != null && url.isNotEmpty) {
        await handleUrl(url);
      }
    }
  }

  /// 处理深链或平台桥 openUrl 转来的 legado/yuedu URI
  Future<void> handleUrl(String url) async {
    if (!LegadoDeepLink.isImportScheme(url)) return;
    if (_lastHandled == url) return;
    _lastHandled = url;

    final parsed = LegadoDeepLink.tryParse(url);
    final nav = navigatorKey?.currentState;
    if (nav == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _lastHandled = null;
        handleUrl(url);
      });
      return;
    }

    final type = parsed?.importType;
    final src = parsed?.srcUrl ?? '';
    final args = <String, dynamic>{
      'url': src,
      'raw': url,
      if (type != null) 'type': _typeName(type),
      'autoLoad': type != null && src.isNotEmpty,
    };
    nav.pushNamed(AppRoutes.association, arguments: args);
  }

  static String _typeName(ImportType type) => switch (type) {
        ImportType.bookSource => 'bookSource',
        ImportType.rssSource => 'rssSource',
        ImportType.replaceRule => 'replaceRule',
        ImportType.theme => 'theme',
      };
}
