import 'dart:convert';

/// 私密列表 JSON 解码（契约 §2.53，批9a）
///
/// Rust FFI 返回**裸 JSON 数组**；这里显式校验数组与元素类型，
/// 形态不符抛 [FormatException]（不静默跳过），让契约漂移尽早暴露。
/// 抽成纯函数便于单测，RustApi 仅做 FFI 调用 + 委托解码。
class PrivacyApiJson {
  const PrivacyApiJson._();

  /// 解码 `getPrivateBookUrls` 返回值（JSON 字符串数组）
  static List<String> decodeBookUrls(String json) {
    final list = _decodeList(json, 'getPrivateBookUrls');
    return list
        .map((item) {
          if (item is! String) {
            throw FormatException(
              'getPrivateBookUrls: 数组元素应为字符串，实际为 ${item.runtimeType}',
            );
          }
          return item;
        })
        .toList(growable: false);
  }

  /// 解码 `getPrivateGroupIds` 返回值（JSON 整数数组）
  static List<int> decodeGroupIds(String json) {
    final list = _decodeList(json, 'getPrivateGroupIds');
    return list
        .map((item) {
          if (item is! int) {
            throw FormatException(
              'getPrivateGroupIds: 数组元素应为整数，实际为 ${item.runtimeType}',
            );
          }
          return item;
        })
        .toList(growable: false);
  }

  static List<dynamic> _decodeList(String json, String method) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is List<dynamic>) return decoded;
    throw FormatException('$method: 期望 JSON 数组，实际为 ${decoded.runtimeType}');
  }
}
