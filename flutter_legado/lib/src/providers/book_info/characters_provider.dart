// 书籍详情页「角色卡」数据 Provider（R42 阶段 2A）
//
// 契约 §2.56：`BookApi.getBookCharacters({bookUrl, limit}) → Future<String>`，
// 返回**裸 JSON 数组**（非包装对象），元素键为 camelCase（`id` / `bookUrl` /
// `name` / `aliasesJson` / `avatarUri` / `tagsJson` / `role` / `personality` /
// `summary` / `status` / `source` / `confidence` / `schemaVersion` /
// `createdAt` / `updatedAt`）。Rust 侧 `status != 3`、`ORDER BY updatedAt DESC`，
// 无数据返回 `[]`（**不抛错**）。
//
// 职责边界（UI 层不含业务逻辑）：
// - 本文件负责 FFI 调用 + JSON 解析 + 降级，产出不可变 Domain Model；
// - UI 只消费 `List<BookCharacter>`，不做任何 jsonDecode；
// - 角色中文映射（男主/女主/男配/女配）与 tags 拼接口径也在此层，UI 只读。
//
// 降级三层（与参考版 `BookInfoViewModel.loadBookCharacters` 的
// `catch (Throwable) → emptyList()` 一致）：
// 1. 请求异常（FFI / 桥错误）→ 空列表；
// 2. JSON 非法（空串 / 非 JSON）→ 空列表；
// 3. 结构不符（顶层不是数组 / 条目不是对象 / 缺 name）→ 空列表或跳过该条。
// 任何情况下都不向 UI 抛错——角色卡是详情页的可选区块，无数据即隐藏。
//
// 排序（参考版 `BookInfoViewModel:1892-1897`）：`roleOrder` 男主 0 / 女主 1 /
// 男配 2 / 女配 3 / 其他 99，**稳定排序**（相同 role 保持 SQL 的 updatedAt
// 降序相对序）。
//
// 已知差异（用户裁决 D4=A / D5=A，照抄参考版，须在 UI 明写）：换源后角色
// **不迁移**（表以 `bookUrl` 为键）、**不纳入备份**、删书**不清理孤儿行**。
//
// 编写：全栈工程师 ｜ 2026-11-23
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers.dart';

/// 角色定位 → 排序权重（参考版 `roleOrder`，未知角色排最后）
const Map<String, int> _roleOrder = {
  'male_lead': 0,
  'female_lead': 1,
  'male_supporting': 2,
  'female_supporting': 3,
};

/// 角色卡（不可变 Domain Model）
///
/// 对齐契约 §2.56 / Rust `BookCharacter`（`legado-core/src/models/
/// book_character.rs`）。`aliasesJson` / `tagsJson` 在 Rust 侧是 JSON 数组
/// 字符串（原样存取），此处解析为 `List<String>`，UI 不再碰 JSON。
@immutable
class BookCharacter {
  /// 主键（空串=尚未入库；保存时 Rust 按 `(bookUrl, name)` 查重复用或新建）
  final String id;

  /// 书籍稳定主键（换源不迁移）
  final String bookUrl;

  /// 角色名（与 bookUrl 组成唯一约束）
  final String name;

  /// 别名列表（原 `aliasesJson`）
  final List<String> aliases;

  /// 头像本地 URI（2A 只建模不填写；UI 恒走占位图标）
  final String? avatarUri;

  /// 标签列表（原 `tagsJson`）
  final List<String> tags;

  /// 角色定位：`male_lead` / `female_lead` / `male_supporting` /
  /// `female_supporting` / `''`
  final String role;

  /// 性格（卡片上不渲染，编辑页可编辑）
  final String personality;

  /// 简介（卡片上不渲染，编辑页可编辑）
  final String summary;

  /// 状态：0=DRAFT / 1=ACTIVE / 2=DISABLED / 3=DELETED（列表已排除 3）
  final int status;

  /// 更新时间（Unix 毫秒；列表排序键）
  final int updatedAt;

  const BookCharacter({
    this.id = '',
    required this.bookUrl,
    required this.name,
    this.aliases = const [],
    this.avatarUri,
    this.tags = const [],
    this.role = '',
    this.personality = '',
    this.summary = '',
    this.status = 1,
    this.updatedAt = 0,
  });

  /// 角色中文名（空 role 返回空串 → UI 不渲染该行）
  ///
  /// 参考版经 `when(role)` 映射 `R.string.role_male_lead` 等 4 个中文
  /// （`strings.xml:2987-2990`）。
  // TODO(l10n): 待 AppStrings 补 roleMaleLead/roleFemaleLead/roleMaleSupporting/
  // roleFemaleSupporting 后替换（本轮按约束不改 app_strings.dart）。
  String get roleLabel => switch (role) {
    'male_lead' => '男主',
    'female_lead' => '女主',
    'male_supporting' => '男配',
    'female_supporting' => '女配',
    _ => '',
  };

  /// 卡片标签行：`tags.join(' | ')`（参考版 `joinToString(" | ")`）
  String get tagsText => tags.join(' | ');

  /// 别名行：编辑态回显用（`、` 分隔，与中文列表分隔习惯一致）
  String get aliasesText => aliases.join('、');

  /// 转成保存用 JSON（camelCase，与 Rust `BookCharacter` serde 对齐）
  ///
  /// 只写本阶段有 UI 的字段；`voiceGender` / `voiceAgeBand` / `confidence` /
  /// `schemaVersion` 等由 Rust `normalize_defaults` 回填默认值。
  Map<String, dynamic> toProfileJson() => {
    'id': id,
    'bookUrl': bookUrl,
    'name': name,
    'aliasesJson': jsonEncode(aliases),
    'avatarUri': avatarUri,
    'tagsJson': jsonEncode(tags),
    'role': role,
    'personality': personality,
    'summary': summary,
    'status': status,
  };

  BookCharacter copyWith({
    String? id,
    String? bookUrl,
    String? name,
    List<String>? aliases,
    String? avatarUri,
    List<String>? tags,
    String? role,
    String? personality,
    String? summary,
    int? status,
    int? updatedAt,
  }) => BookCharacter(
    id: id ?? this.id,
    bookUrl: bookUrl ?? this.bookUrl,
    name: name ?? this.name,
    aliases: aliases ?? this.aliases,
    avatarUri: avatarUri ?? this.avatarUri,
    tags: tags ?? this.tags,
    role: role ?? this.role,
    personality: personality ?? this.personality,
    summary: summary ?? this.summary,
    status: status ?? this.status,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookCharacter &&
          id == other.id &&
          bookUrl == other.bookUrl &&
          name == other.name &&
          avatarUri == other.avatarUri &&
          role == other.role &&
          personality == other.personality &&
          summary == other.summary &&
          status == other.status &&
          updatedAt == other.updatedAt &&
          listEquals(aliases, other.aliases) &&
          listEquals(tags, other.tags);

  @override
  int get hashCode => Object.hash(
    id,
    bookUrl,
    name,
    avatarUri,
    role,
    personality,
    summary,
    status,
    updatedAt,
    Object.hashAll(aliases),
    Object.hashAll(tags),
  );
}

/// 解析 `getBookCharacters` 返回的裸 JSON 数组
///
/// 纯函数（无 IO），便于单元测试；任何异常/非法结构一律返回空列表。
List<BookCharacter> parseBookCharactersJson(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    debugPrint('[角色卡] 返回 JSON 解析失败，按无数据处理：$e');
    return const [];
  }
  if (decoded is! List) return const [];

  final characters = <BookCharacter>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final character = _characterFromJson(item.cast<String, dynamic>());
    // 无名角色不渲染（对齐参考版「角色名必填」）
    if (character != null) characters.add(character);
  }
  if (characters.isEmpty) return const [];

  // 稳定排序：roleOrder 升序，同权重保持 SQL 的 updatedAt 降序相对序
  final indexed = <({int index, BookCharacter character})>[
    for (var i = 0; i < characters.length; i++)
      (index: i, character: characters[i]),
  ];
  indexed.sort((a, b) {
    final ra = _roleOrder[a.character.role] ?? 99;
    final rb = _roleOrder[b.character.role] ?? 99;
    if (ra != rb) return ra.compareTo(rb);
    return a.index.compareTo(b.index);
  });
  return List.unmodifiable([for (final e in indexed) e.character]);
}

/// 角色卡 Provider（family + autoDispose）
///
/// family key = 书籍稳定主键 `bookUrl`：不同书各自独立缓存，离开详情页
/// 即释放。空 bookUrl 不发请求（空态详情页不触发 FFI）。
final bookCharactersProvider = FutureProvider.autoDispose
    .family<List<BookCharacter>, String>((ref, bookUrl) async {
      final url = bookUrl.trim();
      if (url.isEmpty) return const [];
      try {
        final raw = await ref
            .read(bookApiProvider)
            .getBookCharacters(bookUrl: url, limit: 50);
        return parseBookCharactersJson(raw);
      } catch (e) {
        // 角色卡是可选内容：任何失败都降级为空（不向 UI 抛错）
        debugPrint('[角色卡] 加载失败，按无数据处理：$e');
        return const [];
      }
    });

// ─── 归一化辅助 ─────────────────────────────────────────────

/// 单条角色 JSON → [BookCharacter]；name 为空视为无效返回 null
BookCharacter? _characterFromJson(Map<String, dynamic> json) {
  final name = _str(json['name']).trim();
  if (name.isEmpty) return null;
  return BookCharacter(
    id: _str(json['id']),
    bookUrl: _str(json['bookUrl']),
    name: name,
    aliases: _stringList(json['aliasesJson']),
    avatarUri: _nullableStr(json['avatarUri']),
    tags: _stringList(json['tagsJson']),
    role: _str(json['role']),
    personality: _str(json['personality']),
    summary: _str(json['summary']),
    status: _intOf(json['status']),
    updatedAt: _intOf(json['updatedAt']),
  );
}

String _str(Object? v) => v?.toString() ?? '';

String? _nullableStr(Object? v) {
  final s = v?.toString() ?? '';
  return s.isEmpty ? null : s;
}

int _intOf(Object? v) {
  if (v is int) return v;
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// JSON 数组字符串 → `List<String>`（非法 JSON / 非数组 / 非字符串元素一律忽略）
List<String> _stringList(Object? v) {
  if (v is List) return _castStringList(v);
  if (v is! String || v.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(v);
    if (decoded is List) return _castStringList(decoded);
  } catch (e) {
    debugPrint('[角色卡] 数组字段解析失败，按空处理：$e');
  }
  return const [];
}

List<String> _castStringList(List<dynamic> raw) {
  final out = <String>[];
  for (final item in raw) {
    if (item == null) continue;
    final s = item.toString().trim();
    if (s.isNotEmpty) out.add(s);
  }
  return List.unmodifiable(out);
}
