import 'package:freezed_annotation/freezed_annotation.dart';

import '../../services/source_import_service.dart';

part 'association_state.freezed.dart';

/// 导入类型（对应原版 7 类导入对话框；深度链接映射依赖该枚举）
enum ImportType {
  bookSource,
  rssSource,
  replaceRule,
  theme,
  httpTts,
  dictRule,
  txtTocRule,
}

/// 导入条目状态（对应原版 import_status_new / update / exist）
enum ImportItemStatus { isNew, isUpdate, exists, none }

/// 关联导入屏幕阶段
enum AssociationPhase { idle, loading, error, ready }

/// 单条导入候选项：持有原始 JSON + 展示字段 + 相对本地的状态
class AssociationItem {
  const AssociationItem({
    required this.raw,
    required this.name,
    this.group,
    this.comment,
    this.lastUpdateTime = 0,
    required this.status,
  });

  /// 原始 JSON（导入以此为准）
  final Map<String, dynamic> raw;

  /// 展示名称（按类型取 bookSourceName / sourceName / themeName / name）
  final String name;

  /// 分组（bookSource / replaceRule 行名后缀）
  final String? group;

  /// 注释（bookSourceComment / sourceComment / example）
  final String? comment;

  /// 更新时间戳（用于新/更新判定）
  final int lastUpdateTime;

  /// 相对本地数据的状态
  final ImportItemStatus status;

  @override
  String toString() => 'AssociationItem($name, $status)';
}

/// 关联导入状态
@freezed
class AssociationState with _$AssociationState {
  const factory AssociationState({
    /// 导入类型（由内容自动识别或深度链接指定）
    @Default(ImportType.bookSource) ImportType type,

    /// 内容地址输入
    @Default('') String urlInput,

    /// 正在加载
    @Default(false) bool isLoading,

    /// 错误消息（null = 无错误）
    String? error,

    /// 解析出的导入条目
    @Default([]) List<AssociationItem> items,

    /// 最近一次导入结果
    ImportResult? lastResult,
  }) = _AssociationState;
}

/// 展示辅助
extension AssociationStateDisplay on AssociationState {
  /// 当前屏幕阶段（驱动渲染）
  AssociationPhase get phase {
    if (isLoading) return AssociationPhase.loading;
    if (error != null) return AssociationPhase.error;
    if (items.isNotEmpty) return AssociationPhase.ready;
    return AssociationPhase.idle;
  }

  /// 页面标题：有条目时按类型显示（对应原版各对话框标题），否则为通用标题
  String get title {
    if (items.isEmpty) return '关联导入';
    return type.dialogTitle;
  }
}

/// 类型展示辅助
extension ImportTypeDisplay on ImportType {
  /// 对话框标题（对应原版 import_book_source / import_rss_source 等）
  String get dialogTitle => switch (this) {
        ImportType.bookSource => '导入书源',
        ImportType.rssSource => '导入 RSS 源',
        ImportType.replaceRule => '导入替换规则',
        ImportType.theme => '导入主题配置',
        ImportType.httpTts => '导入 HTTP TTS',
        ImportType.dictRule => '导入字典规则',
        ImportType.txtTocRule => '导入 TXT 目录规则',
      };

  /// 行名取哪个字段（对应原版各适配器 cbSourceName.text）
  String nameFieldOf(Map<String, dynamic> raw) {
    final field = switch (this) {
      ImportType.bookSource => 'bookSourceName',
      ImportType.rssSource => 'sourceName',
      ImportType.theme => 'themeName',
      _ => 'name',
    };
    return (raw[field] ?? '').toString();
  }

  /// 行注释取哪个字段（对应原版 showComment）
  String? commentFieldOf(Map<String, dynamic> raw) {
    final field = switch (this) {
      ImportType.bookSource => 'bookSourceComment',
      ImportType.rssSource => 'sourceComment',
      ImportType.txtTocRule => 'example',
      _ => null,
    };
    if (field == null) return null;
    final s = raw[field]?.toString() ?? '';
    return s.isEmpty ? null : s;
  }

  /// 行分组取哪个字段（replaceRule 行名后缀）
  String? groupFieldOf(Map<String, dynamic> raw) {
    final field = switch (this) {
      ImportType.bookSource => 'bookSourceGroup',
      ImportType.replaceRule => 'group',
      _ => null,
    };
    if (field == null) return null;
    final s = raw[field]?.toString() ?? '';
    return s.isEmpty ? null : s;
  }

  /// 更新时间戳字段（无则返回 null）
  int? lastUpdateTimeFieldOf(Map<String, dynamic> raw) {
    final field = switch (this) {
      ImportType.bookSource => 'lastUpdateTime',
      ImportType.rssSource => 'lastUpdateTime',
      ImportType.httpTts => 'lastUpdateTime',
      _ => null,
    };
    if (field == null) return null;
    final v = raw[field];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
