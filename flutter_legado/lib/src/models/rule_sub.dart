/// 规则订阅模型（对齐 Rust RuleSubRecord JSON，契约 §2.39）
///
/// 对标 Android 原版 `RuleSub.kt` 实体 + DB v100 补全字段
/// （customOrder / autoUpdate / updateInterval / silentUpdate 等）。
class RuleSub {
  /// 自增主键（0 表示未入库）
  final int id;

  /// 订阅 URL（唯一）
  final String url;

  /// 订阅名称
  final String name;

  /// 订阅类型：bookSource / rssSource / replaceRule（契约 §2.39）
  final String subType;

  /// 最后更新时间戳（毫秒）
  final int lastUpdate;

  /// 远程版本号
  final String version;

  /// 是否启用（Rust 轨扩展字段）
  final bool isEnabled;

  /// 创建时间戳（毫秒）
  final int createdAt;

  /// 自定义排序（拖拽排序依据）
  final int customOrder;

  /// 是否自动更新
  final bool autoUpdate;

  /// 更新间隔（小时）
  final int updateInterval;

  /// 是否静默更新
  final bool silentUpdate;

  const RuleSub({
    this.id = 0,
    this.url = '',
    this.name = '',
    this.subType = bookSource,
    this.lastUpdate = 0,
    this.version = '',
    this.isEnabled = true,
    this.createdAt = 0,
    this.customOrder = 0,
    this.autoUpdate = false,
    this.updateInterval = 0,
    this.silentUpdate = false,
  });

  static const bookSource = 'bookSource';
  static const rssSource = 'rssSource';
  static const replaceRule = 'replaceRule';

  /// 类型标签（对标原版 arrays.xml rule_type：书源/订阅源/替换规则）
  String get typeLabel => switch (subType) {
        rssSource => '订阅源',
        replaceRule => '替换规则',
        _ => '书源',
      };

  factory RuleSub.fromJson(Map<String, dynamic> json) {
    return RuleSub(
      id: (json['id'] is num) ? (json['id'] as num).toInt() : 0,
      url: (json['url'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      subType: (json['sub_type'] ?? bookSource).toString(),
      lastUpdate: (json['last_update'] is num)
          ? (json['last_update'] as num).toInt()
          : 0,
      version: (json['version'] ?? '').toString(),
      isEnabled: json['is_enabled'] != false,
      createdAt: (json['created_at'] is num)
          ? (json['created_at'] as num).toInt()
          : 0,
      customOrder: (json['customOrder'] is num)
          ? (json['customOrder'] as num).toInt()
          : 0,
      autoUpdate: json['autoUpdate'] == true,
      updateInterval: (json['updateInterval'] is num)
          ? (json['updateInterval'] as num).toInt()
          : 0,
      silentUpdate: json['silentUpdate'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'sub_type': subType,
        'last_update': lastUpdate,
        'version': version,
        'is_enabled': isEnabled,
        'created_at': createdAt,
        'customOrder': customOrder,
        'autoUpdate': autoUpdate,
        'updateInterval': updateInterval,
        'silentUpdate': silentUpdate,
      };

  RuleSub copyWith({
    int? id,
    String? url,
    String? name,
    String? subType,
    int? lastUpdate,
    String? version,
    bool? isEnabled,
    int? createdAt,
    int? customOrder,
    bool? autoUpdate,
    int? updateInterval,
    bool? silentUpdate,
  }) {
    return RuleSub(
      id: id ?? this.id,
      url: url ?? this.url,
      name: name ?? this.name,
      subType: subType ?? this.subType,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      version: version ?? this.version,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
      customOrder: customOrder ?? this.customOrder,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      updateInterval: updateInterval ?? this.updateInterval,
      silentUpdate: silentUpdate ?? this.silentUpdate,
    );
  }
}
