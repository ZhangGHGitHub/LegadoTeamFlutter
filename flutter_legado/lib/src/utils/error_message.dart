import '../bridge/ffi.dart';

/// BridgeError 无 message（或全空白）时的兜底文案。
///
/// 避免 UI 出现「XX 失败: 」这类只有前缀、没有任何信息的空文案。
const String kUnknownErrorMessage = '未知错误';

/// 提取异常的可读错误信息，供 UI 层展示。
///
/// Rust FFI 统一以 [BridgeError] 抛错，它只有 `message` 字段且无自定义
/// toString()——直接 `e.toString()` / 字符串内插 `$e` 会显示
/// "Instance of 'BridgeError'"（用户看不到真实原因，iOS 实测：
/// 「MCP 服务切换失败: Instance of BridgeError」）。
///
/// 本函数对 [BridgeError] 返回其 `message`；message 为空或全空白时回落
/// [kUnknownErrorMessage]；其余异常保持 `e.toString()`。
///
/// 使用约定：UI 展示桥接异常一律走本函数，不得再裸插值 `$e`。
String errorMessage(Object e) {
  if (e is BridgeError) {
    final message = e.message;
    return message.trim().isEmpty ? kUnknownErrorMessage : message;
  }
  return e.toString();
}
