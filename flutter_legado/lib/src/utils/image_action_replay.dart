// 图片动作 UI 副作用回放（契约 §2.21 evalImageAction，批21-A）
//
// Rust 侧把动作期间的 `java.toast` / `java.longToast` / `java.showBrowser` /
// `java.startBrowser` / `java.openUrl` 等经 `ui_action_queue` 收集，并在
// `actions` 非空时随返回值回传。本文件按动作类型回放：
// - `toast` / `longToast` → 调用方注入的 SnackBar 回调（支持动态拼接消息）；
// - `showBrowser` / `openBrowser` / `startBrowser` / `openUrl` → 系统浏览器；
// - 其余/坏数据 → debug 日志，不抛错、不打断阅读。
//
// 依赖说明：浏览器打开复用项目既有 `url_launcher`（pubspec 已声明，无新增
// 依赖）；测试可注入 [ImageActionExternalOpener] 断言，不真正拉系统浏览器。

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/image_action_outcome.dart';

/// toast 回放回调（[isLong] 对应 `java.longToast` 的长停留）
typedef ImageActionToast =
    void Function(String message, {required bool isLong});

/// 外链打开器（返回是否成功；测试注入 Fake）
typedef ImageActionExternalOpener = Future<bool> Function(Uri uri);

/// 默认外链打开器：交系统浏览器/关联应用（与项目其他外链入口同口径）
Future<bool> openImageActionUrlExternally(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('[image-action] 打开链接失败（已忽略）：$uri → $e');
    return false;
  }
}

/// 按动作类型回放图片动作的中途 UI 副作用
///
/// 每个 action 独立 try/catch：单条失败/未知类型只记日志，其余动作继续，
/// 任何异常都不上抛给阅读主链路。
Future<void> replayImageActionSideEffects(
  Iterable<ImageActionSideEffect> actions, {
  required ImageActionToast onToast,
  ImageActionExternalOpener openExternal = openImageActionUrlExternally,
}) async {
  for (final action in actions) {
    try {
      switch (action.name) {
        case 'toast':
          if (action.message.isNotEmpty) {
            onToast(action.message, isLong: false);
          }
        case 'longToast':
          if (action.message.isNotEmpty) {
            onToast(action.message, isLong: true);
          }
        // Rust `java.showBrowser` 入队名为 `openBrowser`（见
        // legado-js/host_api/platform.rs），两者都按打开浏览器处理。
        case 'showBrowser':
        case 'openBrowser':
        case 'startBrowser':
        case 'openUrl':
          final url = action.url.trim();
          if (url.isEmpty) {
            debugPrint('[image-action] ${action.name} 缺 url，跳过：$action');
            continue;
          }
          final uri = Uri.tryParse(url);
          if (uri == null) {
            debugPrint('[image-action] ${action.name} url 非法，跳过：$url');
            continue;
          }
          if (!await openExternal(uri)) {
            debugPrint('[image-action] ${action.name} 未能打开：$url');
          }
        default:
          // 其余类型（refreshBookInfo/copyText 等）不在图片动作场景回放
          debugPrint('[image-action] 未回放的 UI action：${action.name}');
      }
    } catch (e) {
      debugPrint('[image-action] 回放 ${action.name} 失败（已忽略）：$e');
    }
  }
}
