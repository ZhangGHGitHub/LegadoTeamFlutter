/// 书签标记模型（契约 §2.52，批7b-1）
///
/// 对齐参考版 `data/entities/BookMarking.kt:21-46`：用户划线/高亮笔记（标记）
/// 与书签（页面导航）、AI 正文处理独立，存 `book_marks` 表。
///
/// 字段语义：
/// - [id]：String 主键；空串表示尚未入库，`saveBookMarking` 时由 Rust 生成 UUID v4；
/// - [bookUrl]：创建时的源地址（跳转校验用，跨源关联不改写）；
/// - [bookName] + [bookAuthor]：跨源关联键（换源后标记仍可见可管理）；
/// - [chapterIndex]：可空（全书级标记）；
/// - [anchorJson]：章节内定位锚点 JSON，**必填非空**（Rust 侧校验）；
/// - [styleJson]：样式 JSON（可空；样式即类型，参考版 `TextProcessStyle`）；
/// - [note]：用户备注；
/// - [chapterName]：冗余章节标题（目录笔记页展示用）；
/// - [enabled]：是否启用，默认 `true`；
/// - [createdAt] / [updatedAt]：Unix 毫秒（保存时由 Rust 补/重写）。
///
/// JSON 键名 camelCase（与 Rust `BookMarking` 序列化一致）。
class BookMarking {
  const BookMarking({
    this.id = '',
    this.bookUrl = '',
    this.bookName = '',
    this.bookAuthor = '',
    this.chapterIndex,
    this.anchorJson = '',
    this.styleJson,
    this.note = '',
    this.chapterName = '',
    this.enabled = true,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  /// 从 Rust JSON 构造；字段缺失/类型不符按默认值降级（仅新表，无历史包袱）
  factory BookMarking.fromJson(Map<String, dynamic> json) {
    return BookMarking(
      id: (json['id'] ?? '').toString(),
      bookUrl: (json['bookUrl'] ?? '').toString(),
      bookName: (json['bookName'] ?? '').toString(),
      bookAuthor: (json['bookAuthor'] ?? '').toString(),
      chapterIndex: json['chapterIndex'] is num
          ? (json['chapterIndex'] as num).toInt()
          : null,
      anchorJson: (json['anchorJson'] ?? '').toString(),
      styleJson: json['styleJson'] is String ? json['styleJson'] as String : null,
      note: (json['note'] ?? '').toString(),
      chapterName: (json['chapterName'] ?? '').toString(),
      enabled: json['enabled'] != false,
      createdAt: json['createdAt'] is num
          ? (json['createdAt'] as num).toInt()
          : 0,
      updatedAt: json['updatedAt'] is num
          ? (json['updatedAt'] as num).toInt()
          : 0,
    );
  }

  /// 主键（空串=未入库）
  final String id;

  /// 创建时的源地址
  final String bookUrl;

  /// 书名（跨源关联键）
  final String bookName;

  /// 作者（跨源关联键）
  final String bookAuthor;

  /// 章节索引（可空）
  final int? chapterIndex;

  /// 章节内定位锚点 JSON（必填非空）
  final String anchorJson;

  /// 样式 JSON（可空）
  final String? styleJson;

  /// 用户备注
  final String note;

  /// 章节标题（冗余存储）
  final String chapterName;

  /// 是否启用
  final bool enabled;

  /// 创建时间（Unix 毫秒）
  final int createdAt;

  /// 更新时间（Unix 毫秒）
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookUrl': bookUrl,
        'bookName': bookName,
        'bookAuthor': bookAuthor,
        'chapterIndex': chapterIndex,
        'anchorJson': anchorJson,
        'styleJson': styleJson,
        'note': note,
        'chapterName': chapterName,
        'enabled': enabled,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  /// copyWith 的「未传参」哨兵：可空字段需要支持显式清空（null）
  static const _unset = Object();

  BookMarking copyWith({
    String? id,
    String? bookUrl,
    String? bookName,
    String? bookAuthor,
    Object? chapterIndex = _unset,
    String? anchorJson,
    Object? styleJson = _unset,
    String? note,
    String? chapterName,
    bool? enabled,
    int? createdAt,
    int? updatedAt,
  }) {
    return BookMarking(
      id: id ?? this.id,
      bookUrl: bookUrl ?? this.bookUrl,
      bookName: bookName ?? this.bookName,
      bookAuthor: bookAuthor ?? this.bookAuthor,
      chapterIndex: identical(chapterIndex, _unset)
          ? this.chapterIndex
          : chapterIndex as int?,
      anchorJson: anchorJson ?? this.anchorJson,
      styleJson: identical(styleJson, _unset)
          ? this.styleJson
          : styleJson as String?,
      note: note ?? this.note,
      chapterName: chapterName ?? this.chapterName,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
