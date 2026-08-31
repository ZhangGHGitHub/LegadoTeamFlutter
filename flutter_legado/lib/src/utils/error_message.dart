import '../bridge/ffi.dart';

/// 提取异常的可读错误信息，供 UI 层展示。
///
/// Rust FFI 统一以 [BridgeError] 抛错，它只有 `message` 字段且无自定义
/// toString()——直接 `e.toString()` / 字符串内插 `$e` 会显示
/// "Instance of 'BridgeError'"（用户看不到真实原因）。
/// 本函数对 BridgeError 返回 `message`，其余异常保持 `e.toString()`。
String errorMessage(Object e) {
  if (e is BridgeError) return e.message;
  return e.toString();
}
