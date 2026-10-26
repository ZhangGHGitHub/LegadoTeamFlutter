import '../bridge/ffi.dart';

/// BridgeError 无 message（或全空白）时的兜底文案。
///
/// 避免 UI 出现「XX 失败: 」这类只有前缀、没有任何信息的空文案。
const String kUnknownErrorMessage = '未知错误';

/// 连接被拒绝/不可达时对用户展示的文案（详见 [friendlyErrorMessage]）。
const String kConnectionRefusedMessage = '无法连接服务器';

/// 连接被重置时对用户展示的文案。
const String kConnectionResetMessage = '连接被服务器中断';

/// 连接超时/网络不可用时对用户展示的文案。
const String kConnectionTimeoutMessage = '网络连接超时';

/// 提取异常的可读错误信息（原始文本，供详情行/复制使用）。
///
/// Rust FFI 统一以 [BridgeError] 抛错，它只有 `message` 字段且无自定义
/// toString()——直接 `e.toString()` / 字符串内插 `$e` 会显示
/// "Instance of 'BridgeError'"（用户看不到真实原因，iOS 实测：
/// 「MCP 服务切换失败: Instance of BridgeError」）。
///
/// 本函数对 [BridgeError] 返回其 `message`；message 为空或全空白时回落
/// [kUnknownErrorMessage]；其余异常保持 `e.toString()`。
///
/// 返回值**不做任何改写**：保留 `FFI error: ` 前缀与 `os error 111` 等
/// 底层串，供失败面板的次要行展示/复制排障（见 [errorDetailMessage]）。
String rawErrorMessage(Object e) {
  if (e is BridgeError) {
    final message = e.message;
    return message.trim().isEmpty ? kUnknownErrorMessage : message;
  }
  return e.toString();
}

/// 面向用户的错误文案（D4 最小映射）。
///
/// 在 [rawErrorMessage] 基础上做两步处理，原始文本仍可经
/// [errorDetailMessage] 取回：
/// 1. 剥离传输层包装前缀（`FFI error: `、`Network error: `，可重复出现）；
/// 2. 常见连接类底层错误映射为中文提示（`os error 111` /
///    `connection refused` → [kConnectionRefusedMessage] 等），
///    避免把 `os error 111` 直接抛给用户。
///
/// 使用约定：UI 展示桥接异常一律走本函数，不得再裸插值 `$e`。
String errorMessage(Object e) => friendlyErrorMessage(rawErrorMessage(e));

/// 失败面板的次要行/复制内容：保留原始底层文本（含前缀与错误码）。
///
/// 与 [errorMessage] 不同，本函数不改写内容；仅当其与友好文案不同时才
/// 建议展示为次要行。
String errorDetailMessage(Object e) => rawErrorMessage(e);

/// 把原始错误文本转换为用户可读文案（[errorMessage] 的纯函数内核）。
///
/// 规则刻意保持最小：
/// - 连接类错误优先映射（否则剥离前缀后剩下的仍是英文底层串）；
/// - 仅剥离**首个**连续出现的 `FFI error:` / `Network error:` 包装前缀，
///   业务文案（如 `上传失败,{...}`）原样保留。
String friendlyErrorMessage(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return kUnknownErrorMessage;

  final lower = trimmed.toLowerCase();
  for (final rule in _connectionRules) {
    if (rule.markers.any(lower.contains)) return rule.message;
  }

  var text = trimmed;
  final wrapper = RegExp(
    r'^(?:(?:ffi\s*error|network\s*error)\s*[:：]\s*)+',
    caseSensitive: false,
  );
  text = text.replaceFirst(wrapper, '').trim();
  return text.isEmpty ? kUnknownErrorMessage : text;
}

/// 连接类底层错误 → 中文提示（按顺序匹配，先具体后宽泛）
const List<_ConnectionErrorRule> _connectionRules = [
  _ConnectionErrorRule(
    markers: ['os error 111', 'connection refused', 'econnrefused'],
    message: kConnectionRefusedMessage,
  ),
  _ConnectionErrorRule(
    markers: ['os error 104', 'connection reset', 'econnreset'],
    message: kConnectionResetMessage,
  ),
  _ConnectionErrorRule(
    markers: [
      'os error 110',
      'os error 101',
      'timed out',
      'timeout',
      'network is unreachable',
    ],
    message: kConnectionTimeoutMessage,
  ),
];

/// 一条连接错误映射规则：命中任一标记即返回对应中文文案
class _ConnectionErrorRule {
  const _ConnectionErrorRule({required this.markers, required this.message});

  /// 小写匹配标记（调用方已把原文转小写）
  final List<String> markers;

  /// 面向用户的中文文案
  final String message;
}
