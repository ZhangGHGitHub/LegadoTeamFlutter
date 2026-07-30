import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/rust_api.dart';
import '../bridge/ffi.dart';
import '../services/source_import_service.dart';
import '../services/backup_service.dart';

/// 书源管理状态
class SourceProvider extends ChangeNotifier {
  final RustApi _api;
  final SourceImportService _importService;
  final BackupService _backupService;

  SourceProvider(this._api)
      : _importService = SourceImportService(_api),
        _backupService = BackupService(_api);

  List<BookSource> _sources = [];
  bool _loading = false;
  String? _error;
  String _filterKeyword = '';

  // 分组筛选
  String? _selectedGroup; // null = 全部

  // 批量选择模式
  bool _batchMode = false;
  final Set<String> _selectedUrls = {};

  // 最近一次导入结果
  ImportResult? _lastImportResult;

  // ===== Getters =====

  List<BookSource> get sources => _sources;
  bool get loading => _loading;
  String? get error => _error;
  String get filterKeyword => _filterKeyword;
  String? get selectedGroup => _selectedGroup;
  bool get batchMode => _batchMode;
  Set<String> get selectedUrls => Set.unmodifiable(_selectedUrls);
  int get selectedCount => _selectedUrls.length;
  ImportResult? get lastImportResult => _lastImportResult;
  SourceImportService get importService => _importService;
  BackupService get backupService => _backupService;

  /// 所有分组名称列表
  List<String> get groups {
    final set = <String>{};
    for (final source in _sources) {
      set.add(source.bookSourceGroup ?? '未分组');
    }
    return set.toList()..sort();
  }

  List<BookSource> get enabledSources =>
      _applyGroupFilter(_sources.where((s) => s.enabled).toList());

  List<BookSource> get disabledSources =>
      _applyGroupFilter(_sources.where((s) => !s.enabled).toList());

  List<BookSource> get filteredSources {
    var list = _sources;
    if (_filterKeyword.isNotEmpty) {
      final kw = _filterKeyword.toLowerCase();
      list = list.where((s) {
        return s.bookSourceName.toLowerCase().contains(kw) ||
            (s.bookSourceGroup?.toLowerCase().contains(kw) ?? false) ||
            s.bookSourceUrl.toLowerCase().contains(kw);
      }).toList();
    }
    return _applyGroupFilter(list);
  }

  List<BookSource> _applyGroupFilter(List<BookSource> list) {
    if (_selectedGroup == null) return list;
    return list.where((s) {
      final group = s.bookSourceGroup ?? '未分组';
      return group == _selectedGroup;
    }).toList();
  }

  Map<String, List<BookSource>> get groupedSources {
    final map = <String, List<BookSource>>{};
    for (final source in filteredSources) {
      final group = source.bookSourceGroup ?? '未分组';
      map.putIfAbsent(group, () => []).add(source);
    }
    return map;
  }

  /// 判断书源是否被选中
  bool isSelected(String sourceUrl) => _selectedUrls.contains(sourceUrl);

  /// 是否全选
  bool get isAllSelected {
    final filtered = filteredSources;
    if (filtered.isEmpty) return false;
    return filtered.every((s) => _selectedUrls.contains(s.bookSourceUrl));
  }

  // ===== 操作 =====

  Future<void> loadSources() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _sources = await _api.getBookSources();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> toggleSource(String sourceUrl) async {
    final index = _sources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (index == -1) return;
    final source = _sources[index];
    final updated = source.copyWith(enabled: !source.enabled);
    try {
      await _api.updateBookSource(updated);
      _sources[index] = updated;
      notifyListeners();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      notifyListeners();
    }
  }

  Future<void> deleteSource(String sourceUrl) async {
    try {
      await _api.deleteBookSource(sourceUrl);
      _sources.removeWhere((s) => s.bookSourceUrl == sourceUrl);
      _selectedUrls.remove(sourceUrl);
      notifyListeners();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      notifyListeners();
    }
  }

  /// 保存书源（新建或更新）
  Future<void> saveSource(BookSource source) async {
    try {
      final index =
          _sources.indexWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
      if (index == -1) {
        // 新建
        final added = await _api.addBookSource(source);
        _sources.add(added);
      } else {
        // 更新
        await _api.updateBookSource(source);
        _sources[index] = source;
      }
      notifyListeners();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      notifyListeners();
      rethrow;
    }
  }

  /// 获取单个书源
  BookSource? getSource(String sourceUrl) {
    try {
      return _sources.firstWhere((s) => s.bookSourceUrl == sourceUrl);
    } catch (_) {
      return null;
    }
  }

  Future<void> importSources(String jsonContent) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _api.importBookSources(jsonContent);
      // 重新加载书源列表
      _sources = await _api.getBookSources();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 使用导入服务导入 JSON
  Future<ImportResult> importFromJson(String jsonStr) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _importService.importFromJson(jsonStr);
      _lastImportResult = result;
      // 重新加载书源列表
      _sources = await _api.getBookSources();
      return result;
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 从 URL 导入书源
  Future<ImportResult> importFromUrl(String url) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _importService.importFromUrl(url);
      _lastImportResult = result;
      _sources = await _api.getBookSources();
      return result;
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 从文件导入书源
  Future<ImportResult> importFromFile(String filePath) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _importService.importFromFile(filePath);
      _lastImportResult = result;
      _sources = await _api.getBookSources();
      return result;
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ===== 分组筛选 =====

  void setGroup(String? group) {
    _selectedGroup = group;
    notifyListeners();
  }

  // ===== 批量操作 =====

  void enterBatchMode() {
    _batchMode = true;
    _selectedUrls.clear();
    notifyListeners();
  }

  void exitBatchMode() {
    _batchMode = false;
    _selectedUrls.clear();
    notifyListeners();
  }

  void toggleSelection(String sourceUrl) {
    if (_selectedUrls.contains(sourceUrl)) {
      _selectedUrls.remove(sourceUrl);
    } else {
      _selectedUrls.add(sourceUrl);
    }
    notifyListeners();
  }

  void selectAll() {
    for (final s in filteredSources) {
      _selectedUrls.add(s.bookSourceUrl);
    }
    notifyListeners();
  }

  void deselectAll() {
    _selectedUrls.clear();
    notifyListeners();
  }

  /// 批量启用选中的书源
  Future<void> batchEnable() async {
    _loading = true;
    notifyListeners();
    try {
      for (final url in _selectedUrls) {
        final index = _sources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = _sources[index];
        if (!source.enabled) {
          final updated = source.copyWith(enabled: true);
          await _api.updateBookSource(updated);
          _sources[index] = updated;
        }
      }
      _batchMode = false;
      _selectedUrls.clear();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 批量禁用选中的书源
  Future<void> batchDisable() async {
    _loading = true;
    notifyListeners();
    try {
      for (final url in _selectedUrls) {
        final index = _sources.indexWhere((s) => s.bookSourceUrl == url);
        if (index == -1) continue;
        final source = _sources[index];
        if (source.enabled) {
          final updated = source.copyWith(enabled: false);
          await _api.updateBookSource(updated);
          _sources[index] = updated;
        }
      }
      _batchMode = false;
      _selectedUrls.clear();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 批量删除选中的书源
  Future<void> batchDelete() async {
    _loading = true;
    notifyListeners();
    try {
      for (final url in _selectedUrls) {
        await _api.deleteBookSource(url);
        _sources.removeWhere((s) => s.bookSourceUrl == url);
      }
      _batchMode = false;
      _selectedUrls.clear();
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 导出选中的书源为 JSON
  Future<String> exportSelectedSources() async {
    return await _backupService.exportSelectedSources(_selectedUrls.toList());
  }

  /// 导出全部书源为 JSON
  Future<String> exportAllSources() async {
    return await _backupService.exportAllSourcesFormatted();
  }

  void setFilter(String keyword) {
    _filterKeyword = keyword;
    notifyListeners();
  }

  void clearFilter() {
    _filterKeyword = '';
    notifyListeners();
  }
}
