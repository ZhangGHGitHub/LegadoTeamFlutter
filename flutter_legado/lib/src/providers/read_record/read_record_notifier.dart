import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/settings_service.dart';
import '../providers.dart';
import 'read_record_state.dart';

export 'read_record_state.dart';

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
      final filtered = _applyFilterAndSort(
        _all,
        state.searchQuery,
        sort,
      );
      state = state.copyWith(
        records: filtered,
        totalReadTimeMs: total,
        sortMode: sort,
        enableRecord: enable,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapError(e),
      );
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

  /// 删除单本书记录（对齐 deleteByName）
  Future<void> deleteByName(String bookName) async {
    try {
      await ref.read(bookApiProvider).deleteReadRecord(bookName);
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
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

  /// ReadRecord → ReadRecordShow；同名合并时长（对齐 Room group by bookName）
  static List<ReadRecordShow> _toShowList(List<ReadRecord> raw) {
    final map = <String, ReadRecordShow>{};
    for (final r in raw) {
      final prev = map[r.bookName];
      if (prev == null) {
        map[r.bookName] = ReadRecordShow(
          bookName: r.bookName,
          readTime: r.readTime,
          lastRead: r.lastRead,
        );
      } else {
        map[r.bookName] = prev.copyWith(
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
          .where((r) => r.bookName.toLowerCase().contains(lower))
          .toList();
    } else {
      list = List<ReadRecordShow>.from(list);
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
