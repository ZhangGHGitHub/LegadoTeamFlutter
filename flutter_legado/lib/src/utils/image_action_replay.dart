// 图片动作 UI 副作用回放（契约 §2.21 evalImageAction，批21-A）
//
// Rust 侧把动作期间的 `java.toast` / `java.longToast` / `java.showBrowser` /
// `java.startBrowser` / `java.openUrl` 等经 `ui_action_queue` 收集，并在
// `actions` 非空时随返回值回传。本文件按动作类型回放：
// - `toast` / `longToast` → 调用方注入的 SnackBar 回调（支持动态拼接消息）；
// - `showBrowser` / `openBrowser` / `startBrowser` / `openUrl` →
//   `PlatformBridgeService.dispatchPayload`（既有桥接策略：尊重「拦截书源
//   打开浏览器」设置、openUrl 二次确认、legado:/yuedu: 深链分流、应用内/
//   外浏览器分流），**不再直接 launchUrl**；
// - 其余/坏数据 → debug 日志，不抛错、不打断阅读。
//
// [批21-A 回修 P1] 外链安全：浏览器类 action 先过 scheme 白名单（仅
// http/https/legado/yuedu），`javascript:`/`data:`/`file:`/`content:`/
// `intent:` 等一律拒绝，防止恶意书源在点图时静默外跳或触发本地能力。
// 无新增依赖：浏览器能力全部复用既有 platform_bridge_service。

import 'package:flutter/foundation.dart';

import '../services/image_action_outcome.dart';
import '../services/platform_bridge_service.dart';

/// toast 回放回调（[isLong] 对应 `java.longToast` 的长停留）
typedef ImageActionToast =
    void Function(String message, {required bool isLong});

/// 桥接载荷分发器（默认走 PlatformBridgeService；测试注入 Fake 断言）
typedef ImageActionPayloadDispatcher =
    Future<void> Function(Map<String, dynamic> payload);

/// 默认分发：复用既有平台桥接策略
///
/// `openBrowser`/`startBrowser`/`openUrl` 的拦截设置、二次确认、深链分流
/// 均由 `PlatformBridgeService.dispatchPayload` 统一执行。
Future<void> dispatchImageActionPayload(Map<String, dynamic> payload) async {
  await PlatformBridgeService.instance.dispatchPayload(payload);
}

/// 图片动作允许打开的 URL scheme 白名单
///
/// - `http`/`https`：交由 [PlatformBridgeService] 按用户设置与确认流程处理；
/// - `legado`/`yuedu`：站内关联导入深链（既有桥接豁免，不交浏览器）；
/// - 其余（`javascript`/`data`/`file`/`content`/`intent` 等）一律拒绝。
bool isAllowedImageActionScheme(String scheme) {
  switch (scheme.toLowerCase()) {
    case 'http':
    case 'https':
    case 'legado':
    case 'yuedu':
      return true;
    default:
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
  ImageActionPayloadDispatcher dispatchPayload = dispatchImageActionPayload,
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
        // legado-js/host_api/platform.rs），两者都走桥接浏览器策略。
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
          if (uri == null || !isAllowedImageActionScheme(uri.scheme)) {
            debugPrint(
              '[image-action] ${action.name} 拒绝非白名单 URL'
              '（scheme=${uri?.scheme ?? ''}）：$url',
            );
            continue;
          }
          // 载荷字段与 Rust action 同构（action/url/html/mimeType/title），
          // 由既有桥接统一执行拦截设置、openUrl 二次确认与深链分流。
          final payload = <String, dynamic>{
            ...action.data,
            'action': action.name == 'showBrowser'
                ? 'openBrowser'
                : action.name,
          };
          await dispatchPayload(payload);
        default:
          // 其余类型（refreshBookInfo/copyText 等）不在图片动作场景回放
          debugPrint('[image-action] 未回放的 UI action：${action.name}');
      }
    } catch (e) {
      debugPrint('[image-action] 回放 ${action.name} 失败（已忽略）：$e');
    }
  }
}
