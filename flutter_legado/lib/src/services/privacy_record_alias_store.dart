// 私密书改名别名存储（审查 P2-3）
//
// 背景：`readRecord` / `bookmarks` 表只存「书名 + 作者」，没有 `bookUrl`。
// `PrivacyContentService` 的脱敏反查以**当前** `books.name + author` 为键；
// 私密书改名/改作者后，旧记录仍持旧值 → 反查落空 → fail-open → 旧书名
// 明文显示，点击还会把旧书名作为关键词发给第三方书源搜索。
//
// 本存储把「旧书名 + 旧作者 → bookUrl」登记在 SharedPreferences，隐私快照
// 加载时按 bookUrl 找回当前书籍并入反查索引，使脱敏判定重新锚定稳定标识。
// 纯 Dart 侧修复，不改 Rust schema / API 契约，也不需要数据迁移。
//
// 失败语义：读写失败只 debugPrint 并按「无别名」处理（与隐私快照既有
// fail-open 同口径，绝不因一次偏好 IO 失败阻塞改名或误锁书架）。
//
// 编写：全栈工程师（审查 P2-3） ｜ 2026-11-13

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 一条改名别名：书籍曾经使用过的「书名 + 作者」
@immutable
class PrivacyRecordAlias {
  const PrivacyRecordAlias({
    required this.name,
    required this.author,
    required this.bookUrl,
  });

  /// 改名前的书名（阅读记录/书签落库时的物理书名）
  final String name;

  /// 改名前的作者（阅读记录/书签落库时的物理作者）
  final String author;

  /// 书籍稳定标识（`books.bookUrl`），改名/改作者不变
  final String bookUrl;

  /// 可入库判定：书名与 URL 均非空白
  bool get isValid => name.trim().isNotEmpty && bookUrl.trim().isNotEmpty;

  Map<String, Object?> toJson() => {
    'name': name,
    'author': author,
    'bookUrl': bookUrl,
  };

  /// 宽容解析单条别名；形态不符返回 null（跳过脏数据，不整表失效）
  static PrivacyRecordAlias? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final author = raw['author'];
    final bookUrl = raw['bookUrl'];
    if (name is! String || author is! String || bookUrl is! String) {
      return null;
    }
    final alias = PrivacyRecordAlias(
      name: name,
      author: author,
      bookUrl: bookUrl,
    );
    return alias.isValid ? alias : null;
  }

  @override
  bool operator ==(Object other) =>
      other is PrivacyRecordAlias &&
      other.name == name &&
      other.author == author &&
      other.bookUrl == bookUrl;

  @override
  int get hashCode => Object.hash(name, author, bookUrl);

  @override
  String toString() => 'PrivacyRecordAlias($name, $author -> $bookUrl)';
}

/// 改名别名存储（无状态；SharedPreferences 持久化）
class PrivacyRecordAliasStore {
  const PrivacyRecordAliasStore();

  /// 保留的最大条目数（超出按插入顺序丢弃最旧项，避免偏好无限增长）
  static const int maxEntries = 1000;

  /// 读取全部别名（损坏条目跳过；读取失败返回空表）
  Future<List<PrivacyRecordAlias>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PrefKeys.privacyRecordAliases);
      if (raw == null || raw.isEmpty) return const <PrivacyRecordAlias>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PrivacyRecordAlias>[];
      final aliases = <PrivacyRecordAlias>[];
      for (final item in decoded) {
        final alias = PrivacyRecordAlias.tryParse(item);
        if (alias != null) aliases.add(alias);
      }
      return aliases;
    } catch (e) {
      debugPrint('[隐私] 读取改名别名失败（按无别名处理）：$e');
      return const <PrivacyRecordAlias>[];
    }
  }

  /// 登记一条改名别名（精确重复不重复写入）
  ///
  /// 同名旧名可能先后属于不同书籍（删除后重建）：按完整三元组去重，
  /// 不覆盖既有条目，由反查侧按「任一候选私密即锁定」fail-closed 处理。
  Future<void> register({
    required String oldName,
    required String oldAuthor,
    required String bookUrl,
  }) async {
    try {
      final entry = PrivacyRecordAlias(
        name: oldName,
        author: oldAuthor,
        bookUrl: bookUrl,
      );
      if (!entry.isValid) return;
      final existing = await load();
      if (existing.contains(entry)) return;
      final next = <PrivacyRecordAlias>[...existing, entry];
      if (next.length > maxEntries) {
        next.removeRange(0, next.length - maxEntries);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PrefKeys.privacyRecordAliases,
        jsonEncode([for (final alias in next) alias.toJson()]),
      );
    } catch (e) {
      debugPrint('[隐私] 登记改名别名失败（不阻断改名）：$e');
    }
  }
}
