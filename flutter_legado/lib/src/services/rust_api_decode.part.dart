// rust_api.dart 的 part 文件（体检 §三.16 超长文件拆分）：JSON 解码辅助。
// 各分域 mixin 以 on RustApiDecode 获得解码辅助访问。
part of 'rust_api.dart';

mixin RustApiDecode {
  // [审计修复 §4.2] jsonDecode 守卫：类型不符时抛带上下文的 FormatException，
  // 避免 Rust 返回结构漂移时直接 TypeError 崩溃（契约 §1.4 历史教训） — QoderCN

  /// 解码 JSON 数组，类型不符时抛带方法上下文的 [FormatException]
  List<dynamic> _decodeList(String json, String method) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is List<dynamic>) return decoded;
    throw FormatException(
      AppStrings.rustApiDecodeListFailed(
        method,
        '${decoded.runtimeType}',
        json.length > 120 ? json.substring(0, 120) : json,
      ),
    );
  }

  /// 解码 JSON 对象，类型不符时抛带方法上下文的 [FormatException]
  Map<String, dynamic> _decodeMap(String json, String method) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException(
      AppStrings.rustApiDecodeMapFailed(
        method,
        '${decoded.runtimeType}',
        json.length > 120 ? json.substring(0, 120) : json,
      ),
    );
  }
}
