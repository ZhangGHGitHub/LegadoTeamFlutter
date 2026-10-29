// 阅读主题状态管理（批38｜参考版阅读主题列表管理）
//
// 职责边界（对齐 UI_RESTRUCTURE_PLAN.md §3.2）：
// - 只做「主题列表/当前 id/网格列数」的加载、增删改排序与持久化
// - 不直接改阅读器状态；应用主题（字号/行距/背景/排版落点）由主题页
//   `ReaderThemeScreen` 编排，调用既有 ReaderNotifier / ReaderAdvancedConfig
//
// 编写：全栈工程师（批38） ｜ 2026-10-29
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/reader_theme.dart';
import '../../services/reader_theme_service.dart';

/// 主题列表状态（不可变）
@immutable
class ReaderThemeState {
  const ReaderThemeState({
    required this.themes,
    this.currentId = '',
    this.gridColumns = ReaderThemeService.defaultGridColumns,
    this.loaded = false,
  });

  /// 内置 + 自建（内置恒在最前）
  final List<ReaderTheme> themes;

  /// 当前主题 id（空 = 未应用任何命名主题）
  final String currentId;

  /// 网格列数 2..6
  final int gridColumns;

  /// 是否已完成首次本地加载（UI 据此决定要不要显示占位）
  final bool loaded;

  /// 自建主题（管理/排序/删除只作用于这一段）
  List<ReaderTheme> get customThemes => <ReaderTheme>[
    for (final theme in themes)
      if (!theme.builtIn) theme,
  ];

  /// 当前主题（id 不存在时返回 null，例如主题被删除/备份清空）
  ReaderTheme? get currentTheme {
    for (final theme in themes) {
      if (theme.id == currentId) return theme;
    }
    return null;
  }

  /// 当前主题下标（-1 = 无；供「定位当前」使用）
  int get currentIndex {
    for (var i = 0; i < themes.length; i++) {
      if (themes[i].id == currentId) return i;
    }
    return -1;
  }

  ReaderThemeState copyWith({
    List<ReaderTheme>? themes,
    String? currentId,
    int? gridColumns,
    bool? loaded,
  }) {
    return ReaderThemeState(
      themes: themes ?? this.themes,
      currentId: currentId ?? this.currentId,
      gridColumns: gridColumns ?? this.gridColumns,
      loaded: loaded ?? this.loaded,
    );
  }
}

/// 阅读主题 Notifier：启动异步加载 + 修改即时持久化
class ReaderThemeNotifier extends Notifier<ReaderThemeState> {
  final ReaderThemeService _service = ReaderThemeService();

  /// 变更代数：异步加载返回时若用户已改数据，丢弃旧值
  int _generation = 0;

  /// provider 销毁后不再写 state
  bool _disposed = false;

  /// 首次加载任务（供变更操作等待）
  ///
  /// 变更前必须等首次加载完成：否则在磁盘主题库尚未读入时改内存状态并
  /// 落盘，会把磁盘上的自建主题整体覆盖掉（首载竞态，批38b 审查 P2-1）。
  Future<void>? _initialLoad;

  @override
  ReaderThemeState build() {
    ref.onDispose(() => _disposed = true);
    _initialLoad = _loadLoop();
    return ReaderThemeState(themes: ReaderThemeService.mergeThemes(const []));
  }

  /// 加载循环：加载期间若被变更打断（[_generation] 变化），丢弃本次结果
  /// 并重新读取，直到成功应用到 state（保证磁盘主题库不会因竞态缺失）。
  Future<void> _loadLoop() async {
    while (!_disposed) {
      final generation = _generation;
      final custom = await _service.loadCustomThemes();
      final currentId = await _service.loadCurrentId();
      final columns = await _service.loadGridColumns();
      if (_disposed) return;
      if (generation != _generation) continue;
      final themes = ReaderThemeService.mergeThemes(custom);
      state = ReaderThemeState(
        themes: themes,
        // 当前 id 必须真实存在，否则视为未应用（历史/备份脏数据自愈）
        currentId: themes.any((t) => t.id == currentId) ? currentId : '',
        gridColumns: columns,
        loaded: true,
      );
      return;
    }
  }

  /// 等待首次加载完成（未完成则等待；加载被丢弃时等待重试后的加载）
  Future<void> _ensureLoaded() async {
    while (!_disposed && !state.loaded) {
      final pending = _initialLoad ??= _loadLoop();
      await pending;
      if (identical(_initialLoad, pending)) _initialLoad = null;
    }
  }

  /// 名称占用表（内置 + 自建）
  Set<String> get _existingNames => <String>{
    for (final theme in state.themes) theme.name,
  };

  Future<void> _persist() async {
    await _service.saveCustomThemes(state.customThemes);
    await _service.saveCurrentId(state.currentId);
  }

  /// 应用主题后记录当前 id
  Future<void> markCurrent(String id) async {
    await _ensureLoaded();
    _generation++;
    if (!state.themes.any((theme) => theme.id == id)) return;
    state = state.copyWith(currentId: id);
    await _service.saveCurrentId(id);
  }

  /// 新建主题（名称冲突自动加后缀）
  Future<ReaderTheme> addTheme({
    required String name,
    required ReaderThemeStyle style,
  }) async {
    await _ensureLoaded();
    _generation++;
    final theme = ReaderThemeService.createTheme(
      name: name,
      style: style,
      existingNames: _existingNames,
    );
    state = state.copyWith(
      themes: ReaderThemeService.mergeThemes(<ReaderTheme>[
        ...state.customThemes,
        theme,
      ]),
      loaded: true,
    );
    await _persist();
    return theme;
  }

  /// 重命名（内置主题不可改；名称冲突自动加后缀，与新建/导入一致）
  ///
  /// 返回最终名称（可能带 ` (2)` 后缀），`null` = 重命名失败。
  Future<String?> renameTheme(String id, String name) async {
    await _ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final customs = state.customThemes;
    final index = customs.indexWhere((theme) => theme.id == id);
    if (index < 0) return null;
    // 自身原名称不参与冲突判定，否则改名成同名会被加多余后缀
    final otherNames = <String>{
      for (final theme in state.themes)
        if (theme.id != id) theme.name,
    };
    final finalName = uniqueReaderThemeName(trimmed, otherNames);
    _generation++;
    final updated = <ReaderTheme>[
      for (var i = 0; i < customs.length; i++)
        i == index ? customs[i].copyWith(name: finalName) : customs[i],
    ];
    state = state.copyWith(themes: ReaderThemeService.mergeThemes(updated));
    await _persist();
    return finalName;
  }

  /// 删除自建主题（内置忽略）；删除当前主题时清空当前 id
  Future<int> deleteThemes(Set<String> ids) async {
    await _ensureLoaded();
    final targets = <String>{
      for (final id in ids)
        if (state.customThemes.any((theme) => theme.id == id)) id,
    };
    if (targets.isEmpty) return 0;
    _generation++;
    final remain = <ReaderTheme>[
      for (final theme in state.customThemes)
        if (!targets.contains(theme.id)) theme,
    ];
    final currentRemoved = targets.contains(state.currentId);
    state = state.copyWith(
      themes: ReaderThemeService.mergeThemes(remain),
      currentId: currentRemoved ? '' : state.currentId,
    );
    await _persist();
    return targets.length;
  }

  /// 自建主题内上移/下移一位（[delta] 仅 -1/+1；越界忽略）
  Future<bool> moveTheme(String id, int delta) async {
    await _ensureLoaded();
    final customs = state.customThemes;
    final index = customs.indexWhere((theme) => theme.id == id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= customs.length) return false;
    _generation++;
    final moved = customs.removeAt(index);
    customs.insert(target, moved);
    state = state.copyWith(themes: ReaderThemeService.mergeThemes(customs));
    await _persist();
    return true;
  }

  /// 自建主题内批量置顶/置底（对齐参考版 MoveReadStylesToEdge）
  Future<bool> moveThemesToEdge(Set<String> ids, {required bool toTop}) async {
    await _ensureLoaded();
    final customs = state.customThemes;
    final selected = <ReaderTheme>[
      for (final theme in customs)
        if (ids.contains(theme.id)) theme,
    ];
    if (selected.isEmpty) return false;
    _generation++;
    final remain = <ReaderTheme>[
      for (final theme in customs)
        if (!ids.contains(theme.id)) theme,
    ];
    final ordered = toTop
        ? <ReaderTheme>[...selected, ...remain]
        : <ReaderTheme>[...remain, ...selected];
    state = state.copyWith(themes: ReaderThemeService.mergeThemes(ordered));
    await _persist();
    return true;
  }

  /// 导入 JSON（单份或数组），冲突名称自动加后缀；非法内容抛 [FormatException]
  Future<List<ReaderTheme>> importThemes(String raw) async {
    await _ensureLoaded();
    // 先解析再改状态：解析失败绝不落盘、不动现有列表
    final imported = ReaderThemeService.importThemes(
      raw,
      existingNames: _existingNames,
    );
    _generation++;
    state = state.copyWith(
      themes: ReaderThemeService.mergeThemes(<ReaderTheme>[
        ...state.customThemes,
        ...imported,
      ]),
      loaded: true,
    );
    await _persist();
    return imported;
  }

  /// 恢复默认（Notifier 层）：删除全部自建主题并清除当前主题（内置不可删）
  ///
  /// 页面层「恢复默认」还会随后把阅读样式应用为内置预设1
  /// （见 `ReaderThemeScreen._restoreDefaults`），此方法只负责主题库清理。
  Future<void> restoreDefaults() async {
    await _ensureLoaded();
    _generation++;
    state = state.copyWith(
      themes: ReaderThemeService.mergeThemes(const []),
      currentId: '',
      loaded: true,
    );
    await _persist();
  }

  /// 设置网格列数（2..6，持久化）
  Future<void> setGridColumns(int columns) async {
    await _ensureLoaded();
    _generation++;
    final normalized = ReaderThemeService.normalizeGridColumns(columns);
    state = state.copyWith(gridColumns: normalized);
    await _service.saveGridColumns(normalized);
  }
}

/// 阅读主题 Provider
final readerThemeProvider =
    NotifierProvider<ReaderThemeNotifier, ReaderThemeState>(
      ReaderThemeNotifier.new,
    );
