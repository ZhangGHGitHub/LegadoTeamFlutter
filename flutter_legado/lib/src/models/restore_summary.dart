// 备份恢复结果摘要（契约 §2.11 `restore` 返回的 RestoreStats）
//
// 背景（P1-5，2026-11-17 审查）：自有 JSON 备份可对 `servers[].config` 做字段级
// 加密；未提供密码或密码错误时，恢复侧**保留本机既有配置**而不是清空它。
// 这会让「恢复成功」这句话失真——用户以为配置已恢复，实际是保留了旧值。
// Rust 侧在 `RestoreStats.skippedServerConfigs` 中带出该条数，本模型把
// 原始 JSON 转成强类型，UI 据此提示「部分配置未恢复」。
//
// 编写：全栈工程师（P1-5 审查回修） ｜ 2026-11-17
import 'dart:convert';

/// 恢复统计（只建模 UI 需要消费的字段）
///
/// Rust `RestoreStats` 的完整形状为
/// `{books, bookmarks, replaceRules, bookSources, rssSources, readRecords,
/// skippedServerConfigs}`；本模型只取 [skippedServerConfigs]，其余计数 UI
/// 不展示（保持模型最小、避免与 Rust 结构强耦合）。
class RestoreSummary {
  const RestoreSummary({this.skippedServerConfigs = 0});

  /// 空摘要（无统计可读时的安全默认值）
  static const RestoreSummary empty = RestoreSummary();

  /// 因「未提供备份密码 / 密码错误」而未解密、已保留本机值的服务器配置条数
  final int skippedServerConfigs;

  /// 是否发生了「部分配置未恢复」（UI 应提示而非单纯报成功）
  bool get hasSkippedServerConfigs => skippedServerConfigs > 0;

  /// 从 Rust `backupRestore` 返回的 JSON 文本解析
  ///
  /// 宽容策略：空文本 / 非对象 / 字段缺失或类型不符 → 返回 [empty]。
  /// 理由：这是**纯提示**用的附加信息，解析失败不得把已经落库的恢复
  /// 改判为失败（与「恢复后 refresh 失败不改写结果」同口径）。
  factory RestoreSummary.decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return empty;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return empty;
    }
    if (decoded is! Map) return empty;
    final value = decoded['skippedServerConfigs'];
    final count = switch (value) {
      final int v => v,
      final num v => v.toInt(),
      _ => 0,
    };
    return RestoreSummary(skippedServerConfigs: count < 0 ? 0 : count);
  }
}
