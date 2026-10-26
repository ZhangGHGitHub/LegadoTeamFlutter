import '../bridge/ffi.dart';
import '../services/file_save_channel.dart';

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

/// 写入被系统/provider 拒绝时对用户展示的文案（P2-3）。
const String kPermissionDeniedMessage = '没有写入权限，请换一个保存位置';

/// 提取异常的可读错误信息（原始文本，供详情行/复制使用）。
///
/// Rust FFI 统一以 [BridgeError] 抛错，它只有 `message` 字段且无自定义
/// toString()——直接 `e.toString()` / 字符串内插 `$e` 会显示
/// "Instance of 'BridgeError'"（用户看不到真实原因，iOS 实测：
/// 「MCP 服务切换失败: Instance of BridgeError」）。
///
/// [FileSaveException]（Android 系统另存）自带中文 `message`，这里同样
/// 返回它（技术详情另见 [errorDetailMessage]）。
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
  if (e is FileSaveException) return e.message;
  return e.toString();
}

/// 面向用户的错误文案（D4 最小映射）。
///
/// 在 [rawErrorMessage] 基础上做两步处理，原始文本仍可经
/// [errorDetailMessage] 取回：
/// 1. 剥离传输层包装前缀（`FFI error: `、`Network error: `，可重复出现）；
/// 2. 常见连接类/权限类底层错误映射为中文提示（`os error 111` /
///    `connection refused` / `Permission Denial ... requires
///    android.permission` 等），避免把英文底层串直接抛给用户。
///
/// 使用约定：UI 展示桥接异常一律走本函数，不得再裸插值 `$e`。
String errorMessage(Object e) {
  // FileSaveException 的 message 已是中文短句，细节走 errorDetailMessage
  if (e is FileSaveException) return e.message;
  return friendlyErrorMessage(rawErrorMessage(e));
}

/// 失败面板的次要行/复制内容：保留原始底层文本（含前缀与错误码）。
///
/// 与 [errorMessage] 不同，本函数不改写内容；[FileSaveException] 优先
/// 返回可复制的技术 [FileSaveException.detail]（如 `Permission Denial:
/// ... requires MANAGE_DOCUMENTS`）。
String errorDetailMessage(Object e) {
  if (e is FileSaveException) {
    final detail = e.detail?.trim();
    if (detail != null && detail.isNotEmpty) return detail;
    return e.message;
  }
  return rawErrorMessage(e);
}

/// 把原始错误文本转换为用户可读文案（[errorMessage] 的纯函数内核）。
///
/// 规则（D4 回修 P3-1 + P3-4：行首锚定 + 整串形态）：
/// 1. 先剥离开头连续出现的 `FFI error:` / `Network error:` 包装前缀；
/// 2. **底层错误形态**才参与映射，判定为二者之一：
///    - 整串纯 ASCII（原 P3-1 口径，`os error 111` 等均为 ASCII）；
///    - 行首锚定已知底层前缀（`Permission Denial` / `java.lang.*Exception`
///      / `open failed` / `Failed to` 等）。后者解决「底层前缀 + 中文文件名」
///      被误判为业务文案的问题——权限拒绝里常带中文文件名
///      （如 `Permission Denial: writing …/bookSource_QA本地音频B2.json`），
///      旧规则「含中文即放行」会把英文权限错误原样甩给用户；
/// 3. 命中形态后按低层标记映射（`os error 111` / `connection refused` /
///    `permission denied` 等只出现在传输层/系统层英文错误里）；
/// 4. 未命中形态的中文业务文案（如「上传超时(timeout)，请重试」）原样返回，
///    不会被底层映射吞掉。
String friendlyErrorMessage(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return kUnknownErrorMessage;

  var text = trimmed;
  final wrapper = RegExp(
    r'^(?:(?:ffi\s*error|network\s*error)\s*[:：]\s*)+',
    caseSensitive: false,
  );
  text = text.replaceFirst(wrapper, '').trim();
  if (text.isEmpty) return kUnknownErrorMessage;

  if (_isLowLevelShaped(text)) {
    for (final rule in _lowLevelErrorRules) {
      if (rule.pattern.hasMatch(text)) return rule.message;
    }
  }
  return text;
}

/// 是否底层错误形态：纯 ASCII，或以已知底层前缀开头（行首锚定）
bool _isLowLevelShaped(String text) => _isAscii(text) || _hasLowLevelPrefix(text);

/// 是否以已知底层错误前缀开头（P3-4：允许串内出现中文文件名）
bool _hasLowLevelPrefix(String text) =>
    _lowLevelPrefixes.any((pattern) => pattern.hasMatch(text));

/// 是否纯 ASCII（低层错误形态判定；`os error 111` 等均为 ASCII）
bool _isAscii(String text) => RegExp(r'^[\x00-\x7f]*$').hasMatch(text);

/// 底层错误行首前缀（锚定整串开头，避免把中文业务前缀的文案当底层错误）
///
/// 覆盖：系统权限拒绝、Java 异常类名、文件/IO 失败、底层网络请求失败。
final List<RegExp> _lowLevelPrefixes = [
  RegExp(
    r'^(?:permission denial|permission denied|security\s*exception|'
    r'java\.[a-z0-9_.$]*(?:exception|error)|'
    r'android\.system\.[a-z0-9_.$]+|[a-z.]*exception|'
    r'open failed|io error|ioexception|os error|errno|eacces|eperm|'
    r'operation not permitted|failed to|error sending request|request failed)\b',
    caseSensitive: false,
  ),
];

/// 底层错误 → 中文提示（按顺序匹配，先具体后宽泛）。
///
/// 调用方已用 [_isLowLevelShaped] 做形态锚定，因此规则本身的 `RegExp`
/// 只需描述低层错误标记。
final List<_LowLevelErrorRule> _lowLevelErrorRules = [
  _LowLevelErrorRule(
    pattern: RegExp(
      r'permission denial|permission denied|securityexception|eacces|'
      r'requires android\.permission',
      caseSensitive: false,
    ),
    message: kPermissionDeniedMessage,
  ),
  _LowLevelErrorRule(
    pattern: RegExp(
      r'\b(?:os error 111|connection refused|econnrefused)\b',
      caseSensitive: false,
    ),
    message: kConnectionRefusedMessage,
  ),
  _LowLevelErrorRule(
    pattern: RegExp(
      r'\b(?:os error 104|connection reset|econnreset)\b',
      caseSensitive: false,
    ),
    message: kConnectionResetMessage,
  ),
  _LowLevelErrorRule(
    pattern: RegExp(
      r'\b(?:os error 110|os error 101|timed out|timeout|network is unreachable)\b',
      caseSensitive: false,
    ),
    message: kConnectionTimeoutMessage,
  ),
];

/// 一条低层错误映射规则：整串锚定通过后命中标记即返回中文文案
class _LowLevelErrorRule {
  _LowLevelErrorRule({required this.pattern, required this.message});

  /// 低层错误标记（调用方已确保文本为纯 ASCII）
  final RegExp pattern;

  /// 面向用户的中文文案
  final String message;
}
