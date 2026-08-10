import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/backup_service.dart';
import '../../services/source_import_service.dart';
import '../providers.dart';
import 'source_state.dart';

export 'source_state.dart';

/// 书源管理 Riverpod Notifier
///
/// 职责（对标 Android BookSourceActivity）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data 三态）
/// - 管理搜索过滤、分组筛选、排序
/// - 批量操作（启用/禁用/删除/导出）
/// - 导入（URL/文件/JSON/扫码）
/// - 禁止包含业务计算（书源解析由 Rust 完成）
class SourceNotifier extends Notifier<SourceState> {
  @override
  SourceState build() {
    // 原实现不自动加载（由屏幕 initState 触发 loadSources），build() 仅返回初始状态
    return const SourceState();
  }

  /// 获取导入服务实例
  SourceImportService get importService =>
      SourceImportService(ref.read(bookApiProvider));

  /// 获取备份服务实例
  BackupService get backupService =>
      BackupService(ref.read(bookApiProvider));

  // ===== CRUD 操作 =====

  /// 加载书源列表
  Future<void> loadSources() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      // [Task #70 D2 加固 | 2026-08-10] 防御性守卫：内存已有书源时，
      // 空列表返回视为异常时序（如 DB 未就绪）不覆盖，避免显示层
      // 偶发整表清空（69 实机回归 D2 观察项；真实删除走
      // deleteSource/batchDelete 增量路径，不受此守卫影响） — Qoder
      if (sources.isEmpty && state.sources.isNotEmpty) {
        debugPrint('loadSources: 空列表返回，保留现有 ${state.sources.length} 个书源');
        state = state.copyWith(loading: false);
        return;
      }
      state = state.copyWith(sources: sources, loading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 切换书源启用状态
  Future<void> toggleSource(String sourceUrl) async {
    final index =
        state.sources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (index == -1) return;
    final source = state.sources[index];
    final updated = source.copyWith(enabled: !source.enabled);
    try {
      final api = ref.read(bookApiProvider);
      await api.updateBookSource(updated);
      final newSources = List<BookSource>.of(state.sources);
      newSources[index] = updated;
      state = state.copyWith(sources: newSources);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 删除书源
  Future<void> deleteSource(String sourceUrl) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.deleteBookSource(sourceUrl);
      state = state.copyWith(
        sources: state.sources
            .where((s) => s.bookSourceUrl != sourceUrl)
            .toList(),
        selectedUrls: {...state.selectedUrls}..remove(sourceUrl),
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 保存书源（新建或更新）
  Future<void> saveSource(BookSource source) async {
    try {
      final api = ref.read(bookApiProvider);
      final index = state.sources
          .indexWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
      if (index == -1) {
        // 新建
        final added = await api.addBookSource(source);
        state = state.copyWith(sources: [...state.sources, added]);
      } else {
        // 更新
        await api.updateBookSource(source);
        final newSources = List<BookSource>.of(state.sources);
        newSources[index] = source;
        state = state.copyWith(sources: newSources);
      }
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  /// 获取单个书源
  BookSource? getSource(String sourceUrl) {
    try {
      return state.sources.firstWhere((s) => s.bookSourceUrl == sourceUrl);
    } catch (_) {
      return null;
    }
  }

  // ===== 导入 =====

  /// 导入书源（原始 JSON）
  Future<void> importSources(String jsonContent) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      await api.importBookSources(jsonContent);
      // 重新加载书源列表
      final sources = await api.getBookSources();
      state = state.copyWith(sources: sources, loading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 使用导入服务导入 JSON
  Future<ImportResult> importFromJson(String jsonStr) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final result = await importService.importFromJson(jsonStr);
      final api = ref.read(bookApiProvider);
      // 重新加载书源列表
      final sources = await api.getBookSources();
      state = state.copyWith(
        sources: sources,
        lastImportResult: result,
        loading: false,
      );
      return result;
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    }
  }

  /// 从 URL 导入书源
  Future<ImportResult> importFromUrl(String url) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final result = await importService.importFromUrl(url);
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      state = state.copyWith(
        sources: sources,
        lastImportResult: result,
        loading: false,
      );
      return result;
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    }
  }

  /// 从文件导入书源
  Future<ImportResult> importFromFile(String filePath) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final result = await importService.importFromFile(filePath);
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      state = state.copyWith(
        sources: sources,
        lastImportResult: result,
        loading: false,
      );
      return result;
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    }
  }

  // ===== 分组筛选 =====

  /// 设置分组筛选
  void setGroup(String? group) {
    state = state.copyWith(selectedGroup: group);
  }

  // ===== 排序 =====

  /// 设置排序方式（对标 Android menu_sort_manual/auto/name/url 等）
  void setSort(SourceSort sort) {
    state = state.copyWith(sort: sort);
  }

  /// 切换升序/降序（对标 Android menu_sort_desc）
  void toggleSortDirection() {
    state = state.copyWith(sortAscending: !state.sortAscending);
  }

  // ===== 批量操作 =====

  /// 进入批量模式
  void enterBatchMode() {
    state = state.copyWith(batchMode: true, selectedUrls: {});
  }

  /// 退出批量模式
  void exitBatchMode() {
    state = state.copyWith(batchMode: false, selectedUrls: {});
  }

  /// 切换选中状态
  void toggleSelection(String sourceUrl) {
    final newSet = {...state.selectedUrls};
    if (newSet.contains(sourceUrl)) {
      newSet.remove(sourceUrl);
    } else {
      newSet.add(sourceUrl);
    }
    state = state.copyWith(selectedUrls: newSet);
  }

  /// 全选当前过滤结果
  void selectAll() {
    final newSet = {...state.selectedUrls};
    for (final s in state.filteredSources) {
      newSet.add(s.bookSourceUrl);
    }
    state = state.copyWith(selectedUrls: newSet);
  }

  /// 取消全选
  void deselectAll() {
    state = state.copyWith(selectedUrls: {});
  }

  /// 反选当前过滤结果（对标原版 SelectActionBar 反选）
  void revertSelection() {
    final newSet = <String>{};
    for (final s in state.filteredSources) {
      if (!state.selectedUrls.contains(s.bookSourceUrl)) {
        newSet.add(s.bookSourceUrl);
      }
    }
    state = state.copyWith(selectedUrls: newSet);
  }

  /// 切换单个书源的发现启用状态（对标长按菜单 启用/禁用发现）
  Future<void> toggleExplore(String sourceUrl) async {
    final index =
        state.sources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (index == -1) return;
    final source = state.sources[index];
    final updated = source.copyWith(enabledExplore: !source.enabledExplore);
    try {
      final api = ref.read(bookApiProvider);
      await api.updateBookSource(updated);
      final newSources = List<BookSource>.of(state.sources);
      newSources[index] = updated;
      state = state.copyWith(sources: newSources);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 批量启用选中的书源
  Future<void> batchEnable() async {
    state = state.copyWith(loading: true);
    try {
      final api = ref.read(bookApiProvider);
      final newSources = List<BookSource>.of(state.sources);
      for (final url in state.selectedUrls) {
        final index =
            newSources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = newSources[index];
        if (!source.enabled) {
          final updated = source.copyWith(enabled: true);
          await api.updateBookSource(updated);
          newSources[index] = updated;
        }
      }
      state = state.copyWith(
        sources: newSources,
        batchMode: false,
        selectedUrls: {},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 批量禁用选中的书源
  Future<void> batchDisable() async {
    state = state.copyWith(loading: true);
    try {
      final api = ref.read(bookApiProvider);
      final newSources = List<BookSource>.of(state.sources);
      for (final url in state.selectedUrls) {
        final index =
            newSources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = newSources[index];
        if (source.enabled) {
          final updated = source.copyWith(enabled: false);
          await api.updateBookSource(updated);
          newSources[index] = updated;
        }
      }
      state = state.copyWith(
        sources: newSources,
        batchMode: false,
        selectedUrls: {},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 批量删除选中的书源
  Future<void> batchDelete() async {
    state = state.copyWith(loading: true);
    try {
      final api = ref.read(bookApiProvider);
      final newSources = List<BookSource>.of(state.sources);
      for (final url in state.selectedUrls) {
        await api.deleteBookSource(url);
        newSources.removeWhere((s) => s.bookSourceUrl == url);
      }
      state = state.copyWith(
        sources: newSources,
        batchMode: false,
        selectedUrls: {},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 批量启用/禁用选中书源的发现（对标 book_source_sel.xml
  /// menu_enable_select_explore / menu_disable_select_explore）
  Future<void> batchToggleExplore(bool enable) async {
    state = state.copyWith(loading: true);
    try {
      final api = ref.read(bookApiProvider);
      final newSources = List<BookSource>.of(state.sources);
      for (final url in state.selectedUrls) {
        final index =
            newSources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = newSources[index];
        if (source.enabledExplore != enable) {
          final updated = source.copyWith(enabledExplore: enable);
          await api.updateBookSource(updated);
          newSources[index] = updated;
        }
      }
      state = state.copyWith(
        sources: newSources,
        batchMode: false,
        selectedUrls: {},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 置顶/置底选中书源（对标 menu_top_select / menu_bottom_select）
  ///
  /// 纯 UI 层编排：通过重排 customOrder 并逐条 updateBookSource 持久化，
  /// 不依赖 Rust FFI 新增接口。
  Future<void> batchMoveSelection({required bool toTop}) async {
    if (state.selectedUrls.isEmpty) return;
    await _moveSources(state.selectedUrls, toTop, exitBatch: true);
  }

  /// 置顶/置底单个书源（对标长按菜单 topSource/bottomSource，仅手动排序可用）
  Future<void> moveSource(String sourceUrl, {required bool toTop}) async {
    await _moveSources({sourceUrl}, toTop, exitBatch: false);
  }

  Future<void> _moveSources(
    Set<String> urls,
    bool toTop, {
    required bool exitBatch,
  }) async {
    state = state.copyWith(loading: true);
    try {
      final api = ref.read(bookApiProvider);
      final ordered = List<BookSource>.of(state.sources)
        ..sort((a, b) => a.customOrder.compareTo(b.customOrder));
      final selected = ordered
          .where((s) => urls.contains(s.bookSourceUrl))
          .toList();
      final rest = ordered
          .where((s) => !urls.contains(s.bookSourceUrl))
          .toList();
      final rearranged =
          toTop ? [...selected, ...rest] : [...rest, ...selected];

      final newSources = List<BookSource>.of(state.sources);
      for (var i = 0; i < rearranged.length; i++) {
        final source = rearranged[i];
        if (source.customOrder != i) {
          final updated = source.copyWith(customOrder: i);
          await api.updateBookSource(updated);
          final index = newSources
              .indexWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
          if (index != -1) newSources[index] = updated;
        }
      }
      state = state.copyWith(
        sources: newSources,
        batchMode: exitBatch ? false : state.batchMode,
        selectedUrls: exitBatch ? <String>{} : state.selectedUrls,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 为选中书源添加分组（对标 menu_add_group；分组串逗号分隔）
  Future<void> batchAddGroup(String group) async {
    final name = group.trim();
    if (name.isEmpty) return;
    await _mutateSelectedGroups((groups) {
      if (!groups.contains(name)) groups.add(name);
    });
  }

  /// 从选中书源移除分组（对标 menu_remove_group）
  Future<void> batchRemoveGroup(String group) async {
    await _mutateSelectedGroups((groups) => groups.remove(group.trim()));
  }

  Future<void> _mutateSelectedGroups(
    void Function(List<String> groups) mutate,
  ) async {
    state = state.copyWith(loading: true);
    try {
      final api = ref.read(bookApiProvider);
      final newSources = List<BookSource>.of(state.sources);
      for (final url in state.selectedUrls) {
        final index =
            newSources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = newSources[index];
        final groups = (source.bookSourceGroup ?? '')
            .split(',')
            .map((g) => g.trim())
            .where((g) => g.isNotEmpty)
            .toList();
        mutate(groups);
        final updated = source.copyWith(
          bookSourceGroup: groups.isEmpty ? null : groups.join(','),
        );
        await api.updateBookSource(updated);
        newSources[index] = updated;
      }
      state = state.copyWith(
        sources: newSources,
        batchMode: false,
        selectedUrls: {},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 为指定 URL 的书源追加分组（校验失效回写等场景）
  ///
  /// 与 [batchAddGroup] 的差异：操作显式传入的 [urls] 集合，
  /// 不依赖批量选择状态，也不退出批量模式；已有该分组的书源跳过。
  /// 单个书源持久化失败不中断整体（后续书源继续处理）。
  Future<void> addGroupToUrls(Set<String> urls, String group) async {
    final name = group.trim();
    if (name.isEmpty || urls.isEmpty) return;
    try {
      final api = ref.read(bookApiProvider);
      final newSources = List<BookSource>.of(state.sources);
      for (final url in urls) {
        final index =
            newSources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = newSources[index];
        final groups = (source.bookSourceGroup ?? '')
            .split(',')
            .map((g) => g.trim())
            .where((g) => g.isNotEmpty)
            .toList();
        if (groups.contains(name)) continue;
        groups.add(name);
        final updated = source.copyWith(
          bookSourceGroup: groups.join(','),
        );
        try {
          await api.updateBookSource(updated);
          newSources[index] = updated;
        } catch (_) {
          // 单源持久化失败不中断整体（校验副作用为尽力而为）
        }
      }
      state = state.copyWith(sources: newSources);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 导出选中的书源为 JSON
  Future<String> exportSelectedSources() async {
    return await backupService
        .exportSelectedSources(state.selectedUrls.toList());
  }

  /// 导出全部书源为 JSON
  Future<String> exportAllSources() async {
    return await backupService.exportAllSourcesFormatted();
  }

  // ===== 搜索过滤 =====

  /// 设置搜索关键词
  void setFilter(String keyword) {
    state = state.copyWith(filterKeyword: keyword);
  }

  /// 清除搜索关键词
  void clearFilter() {
    state = state.copyWith(filterKeyword: '');
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书源管理 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(sourceNotifierProvider);
/// ref.read(sourceNotifierProvider.notifier).loadSources();
/// ```
final sourceNotifierProvider =
    NotifierProvider<SourceNotifier, SourceState>(
  SourceNotifier.new,
);
