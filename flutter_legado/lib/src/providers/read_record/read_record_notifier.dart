import 'dart:convert' show jsonDecode;

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/settings_service.dart';
import '../providers.dart';
import 'read_record_state.dart';

export 'read_record_state.dart';

/// 历史合并作者串前缀（对齐原版 `ReadRecordAuthors.PREFIX`）
const String _combinedAuthorsPrefix = '\u001Eauthors:';

/// 历史合并作者串聚合分隔符（对齐原版 `ReadRecordAuthors.AGGREGATE_SEPARATOR`）
const String _combinedAuthorsSeparator = '\u001F';

/// 解码历史合并作者串为展示文本（对齐原版 `ReadRecordAuthors.display`）
///
/// v113 前「同书不同作者共用一条记录」会把多个作者编码为
/// `\u001Eauthors:["作者B","作者C"]`，v113 迁移将其**原样保留不拆**。
/// 展示时按原版口径解码：
/// 1. 空白值 → 空串（调用方回退物理/解析作者）；
/// 2. 按聚合分隔符 `\u001F` 分段；
/// 3. 段值以 `\u001Eauthors:` 开头 → 剥前缀按 JSON 字符串数组解析，
///    去空白项；无前缀 → 原值即单一作者；
/// 4. 去重、按码位排序（对齐 Kotlin `sorted()`）后以「、」连接；
/// 5. 前缀后 JSON 非法 → 回退该段原文（不吞历史脏值）。
String decodeReadRecordAuthorsForDisplay(String value) {
  if (value.trim().isEmpty) return '';
  final authors = <String>{};
  for (final segment in value.split(_combinedAuthorsSeparator)) {
    _collectAuthorsForDisplay(segment, authors);
  }
  final sorted = authors.toList()..sort();
  return sorted.join('、');
}

/// 单段作者值解码并写入 [out]（见 [decodeReadRecordAuthorsForDisplay]）
void _collectAuthorsForDisplay(String segment, Set<String> out) {
  if (segment.trim().isEmpty) return;
  if (!segment.startsWith(_combinedAuthorsPrefix)) {
    out.add(segment);
    return;
  }
  final json = segment.substring(_combinedAuthorsPrefix.length);
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    out.add(segment); // 非法 JSON：回退原文
    return;
  }
  if (decoded is! List<Object?>) {
    out.add(segment); // 非数组形态：回退原文
    return;
  }
  for (final item in decoded) {
    if (item is String && item.trim().isNotEmpty) {
      out.add(item);
    }
  }
}

/// 阅读记录 Riverpod Notifier（对齐原版 ReadRecordActivity）
///
/// 职责：经 BookApi 读写 readRecord；搜索/排序在本层完成；
/// 偏好 `enableReadRecord` / `readRecordSort` 经 SettingsService 持久化。
class ReadRecordNotifier extends Notifier<ReadRecordState> {
  final SettingsService _settings = SettingsService();

  /// 全量原始记录（未过滤），供搜索重算
  List<ReadRecordShow> _all = const [];

  @override
  ReadRecordState build() => const ReadRecordState();

  /// 加载偏好 + 列表 + 总时长
  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final sort = _sortFromRaw(await _settings.getReadRecordSort());
      final enable = await _settings.getEnableReadRecord();
      final api = ref.read(bookApiProvider);
      final raw = await api.getReadRecords();
      _all = _toShowList(raw);
      final total = _all.fold<int>(0, (sum, r) => sum + r.readTime);
      final filtered = _applyFilterAndSort(_all, state.searchQuery, sort);
      state = state.copyWith(
        records: filtered,
        totalReadTimeMs: total,
        sortMode: sort,
        enableRecord: enable,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _mapError(e));
    }
  }

  /// 搜索（对齐原版 SearchView onQueryTextChange → initData）
  void setSearchQuery(String query) {
    final q = query.trim();
    state = state.copyWith(
      searchQuery: q,
      records: _applyFilterAndSort(_all, q, state.sortMode),
    );
  }

  /// 切换排序并持久化
  Future<void> setSortMode(ReadRecordSortMode mode) async {
    await _settings.setReadRecordSort(_sortToRaw(mode));
    state = state.copyWith(
      sortMode: mode,
      records: _applyFilterAndSort(_all, state.searchQuery, mode),
    );
  }

  /// 启用/关闭阅读时长记录（对齐菜单 menu_enable_record）
  Future<void> toggleEnableRecord() async {
    final next = !state.enableRecord;
    await _settings.setEnableReadRecord(next);
    state = state.copyWith(enableRecord: next);
  }

  /// 删除单本书记录（对齐原版 deleteByBook）
  ///
  /// `bookName` 为**物理书名**：v113 起 FFI `deleteReadRecord` 删除该书
  /// 全部作者的行（契约 §2.12 已登记该差异）。
  ///
  /// [批9c 回修 P1-1] 返回是否成功，供 UI 区分成功/失败提示（失败不静默）。
  Future<bool> deleteByName(String bookName) async {
    try {
      await ref.read(bookApiProvider).deleteReadRecord(bookName);
      await load();
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      return false;
    }
  }

  /// 清空全部（对齐 clear）
  Future<void> clearAll() async {
    try {
      await ref.read(bookApiProvider).clearReadRecords();
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 按书名在书架查找（对齐 bookDao.findByName(...).firstOrNull）
  Future<Book?> findBookByName(String bookName) async {
    final books = await ref.read(bookApiProvider).getBooks();
    for (final b in books) {
      if (b.name == bookName) return b;
    }
    return null;
  }

  static ReadRecordSortMode _sortFromRaw(int raw) {
    switch (raw) {
      case 1:
        return ReadRecordSortMode.readTime;
      case 2:
        return ReadRecordSortMode.lastRead;
      default:
        return ReadRecordSortMode.name;
    }
  }

  static int _sortToRaw(ReadRecordSortMode mode) {
    switch (mode) {
      case ReadRecordSortMode.readTime:
        return 1;
      case ReadRecordSortMode.lastRead:
        return 2;
      case ReadRecordSortMode.name:
        return 0;
    }
  }

  /// ReadRecord → ReadRecordShow（对齐原版 `ReadRecordDao.allShow`）
  ///
  /// v113 起阅读记录主键含作者：按「显示书名 + 显示作者」分组聚合
  /// （`displayBookName`/`displayAuthor` 为空回退物理 `bookName`/`author`），
  /// `readTime` 求和、`lastRead` 取最大。同名不同作者各自成行，不再互相覆盖时长。
  ///
  /// [批27b P2-1 | 2026-10-28] 作者展示值经
  /// [decodeReadRecordAuthorsForDisplay] 解码历史合并作者串
  /// （`\u001Eauthors:["作者B","作者C"]` → 「作者B、作者C」），
  /// 对齐原版 `ReadRecordShow.displayAuthor = ReadRecordAuthors.display(author)`；
  /// 契约 §2.12 声称的展示解码此前缺失，合并作者行会原样显示编码串。
  static List<ReadRecordShow> _toShowList(List<ReadRecord> raw) {
    final map = <String, ReadRecordShow>{};
    for (final r in raw) {
      final displayName = r.displayBookName.isNotEmpty
          ? r.displayBookName
          : r.bookName;
      final rawAuthor = r.displayAuthor.isNotEmpty
          ? r.displayAuthor
          : (r.author.isNotEmpty ? r.author : (r.resolvedAuthor ?? ''));
      final displayAuthor = decodeReadRecordAuthorsForDisplay(rawAuthor);
      final key = '$displayName\u0000$displayAuthor';
      final prev = map[key];
      if (prev == null) {
        map[key] = ReadRecordShow(
          bookName: displayName,
          author: displayAuthor,
          physicalBookName: r.bookName,
          readTime: r.readTime,
          lastRead: r.lastRead,
        );
      } else {
        map[key] = prev.copyWith(
          readTime: prev.readTime + r.readTime,
          lastRead: r.lastRead > prev.lastRead ? r.lastRead : prev.lastRead,
        );
      }
    }
    return map.values.toList();
  }

  static List<ReadRecordShow> _applyFilterAndSort(
    List<ReadRecordShow> source,
    String query,
    ReadRecordSortMode sort,
  ) {
    var list = source;
    if (query.isNotEmpty) {
      final lower = query.toLowerCase();
      list = list
          .where(
            (r) =>
                r.bookName.toLowerCase().contains(lower) ||
                r.author.toLowerCase().contains(lower),
          )
          .toList();
    } else {
      list = List<ReadRecordShow>.from(source);
    }
    switch (sort) {
      case ReadRecordSortMode.readTime:
        list.sort((a, b) => b.readTime.compareTo(a.readTime));
      case ReadRecordSortMode.lastRead:
        list.sort((a, b) => b.lastRead.compareTo(a.lastRead));
      case ReadRecordSortMode.name:
        list.sort((a, b) => a.bookName.compareTo(b.bookName));
    }
    return list;
  }

  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

final readRecordNotifierProvider =
    NotifierProvider<ReadRecordNotifier, ReadRecordState>(
      ReadRecordNotifier.new,
    );
