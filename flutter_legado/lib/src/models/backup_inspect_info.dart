import 'dart:convert';

/// 备份容器格式（契约 §2.11 `backupInspect` 的 `format` 字段）
enum BackupFormat {
  /// 原版多文件 zip 备份
  zip('zip'),

  /// 我方单文件 JSON 备份
  json('json');

  const BackupFormat(this.wireName);

  /// Rust 侧返回的格式名
  final String wireName;

  /// 解析 Rust 返回的格式名；未知格式属于契约破坏，明确报错
  static BackupFormat parse(Object? raw) {
    for (final format in BackupFormat.values) {
      if (format.wireName == raw) return format;
    }
    throw FormatException('backupInspect 返回未知的备份格式: $raw');
  }
}

/// 备份探测结果（契约 §2.11 `backupInspect`，批17a 契约 / 批17b Dart 封装）
///
/// Rust 侧只读探测备份文件，返回：
/// `{"format":"zip"|"json","passwordRequired":bool,"passwordProtectedFiles":[string]}`
///
/// [passwordProtectedFiles] 为「用空密码解不开」的加密条目（固定顺序：
/// `servers.json` / `cookies.json` / `runtimeSourceCache.json`；
/// 批44 起 JSON 容器的字段级加密为 `servers.json` / `directLinkUploadRule.json`），
/// [passwordRequired] 即该列表非空。UI 只消费本模型，不自行解析 JSON。
class BackupInspectInfo {
  const BackupInspectInfo({
    required this.format,
    required this.passwordRequired,
    required this.passwordProtectedFiles,
    this.encryption,
  });

  /// 备份容器格式
  final BackupFormat format;

  /// 是否需要备份密码
  final bool passwordRequired;

  /// 受密码保护的条目标识（zip 内文件名 / JSON 的逻辑字段名）
  final List<String> passwordProtectedFiles;

  /// 加密标记（批44；仅 JSON 容器可能返回，如 `aes-ecb-md5`）
  ///
  /// 仅供诊断展示，UI 行为只依赖 [passwordRequired]。
  final String? encryption;

  /// 是否为原版 zip 备份
  bool get isZip => format == BackupFormat.zip;

  /// 从已解码的 JSON 对象构造；形态不符时抛出带原因的 [FormatException]
  factory BackupInspectInfo.fromJson(Map<String, dynamic> json) {
    final format = BackupFormat.parse(json['format']);

    final rawRequired = json['passwordRequired'];
    if (rawRequired is! bool) {
      throw FormatException(
        'backupInspect 返回的 passwordRequired 不是布尔值: $rawRequired',
      );
    }

    final rawFiles = json['passwordProtectedFiles'];
    if (rawFiles is! List) {
      throw FormatException(
        'backupInspect 返回的 passwordProtectedFiles 不是数组: $rawFiles',
      );
    }
    final files = <String>[];
    for (var i = 0; i < rawFiles.length; i++) {
      final item = rawFiles[i];
      if (item is! String) {
        throw FormatException(
          'backupInspect 返回的 passwordProtectedFiles 第 $i 项不是字符串: $item',
        );
      }
      files.add(item);
    }

    // 批44：加密标记为可选字段（旧后端不返回）；非字符串按缺失处理，
    // 不让一个纯诊断字段阻断恢复流程。
    final rawEncryption = json['encryption'];

    return BackupInspectInfo(
      format: format,
      passwordRequired: rawRequired,
      passwordProtectedFiles: List.unmodifiable(files),
      encryption: rawEncryption is String && rawEncryption.isNotEmpty
          ? rawEncryption
          : null,
    );
  }

  /// 解析 `backupInspect` 的原始 JSON 文本
  ///
  /// 坏 JSON / 非对象 / 字段形态不符均抛 [FormatException]，消息带原因，
  /// 便于 UI 展示「检查备份失败」时定位问题。
  factory BackupInspectInfo.decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('backupInspect 返回的 JSON 无法解析: ${e.message}');
    }
    if (decoded is! Map) {
      throw FormatException('backupInspect 返回的 JSON 不是对象: $decoded');
    }
    return BackupInspectInfo.fromJson(
      decoded.map((key, value) => MapEntry('$key', value)),
    );
  }
}
