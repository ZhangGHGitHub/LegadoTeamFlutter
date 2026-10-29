/// 发现页「源内容模式」Notifier
///
/// 职责（对齐参考版 `ExploreMainViewModel`）：
/// - 恢复/持久化 [exploreMainContentKey]、[exploreMainSourceUrlKey]、
///   [exploreMainKindKey] 三个偏好键（键名与参考版逐字一致）；
/// - 书源被删除（或发现源列表为空）时回退源列表模式，避免停在失效源；
/// - 持久化发现书单布局模式与网格列数（列表/网格 + 列数，供书源选择
///   sheet 的「布局列数」控件使用）。
///
/// 业务计算（分类解析/书籍抓取）仍由 Rust + [ExploreNotifier] 负责，
/// 本类只做展示层状态编排与偏好读写。
///
/// 时序约定（批36b 启动恢复修复）：
/// - 偏好回读与书源加载是两条独立异步链，先后顺序不确定；
/// - 书源加载完成前不做任何「源被删除」判定；
/// - 书源加载失败（[ExploreState.error] 非空）时无法判定选择是否失效，
///   只回退 UI（源列表），不清持久化偏好——下次加载成功后可自愈恢复；
/// - 用户在偏好回读完成前的显式选择/布局改动优先，回读值不覆盖。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../services/settings_service.dart';
import '../providers.dart';
import 'explore_main_state.dart';
import 'explore_notifier.dart';

class ExploreMainNotifier extends Notifier<ExploreMainState> {
  late final SettingsService _settings = ref.read(settingsProvider);

  /// 偏好读取完成标记（读取完成前不做书源回退判断）
  bool _prefsLoaded = false;

  /// 偏好中的书源地址（用户本次选择会同步更新，避免异步回读覆盖）
  String _savedSourceUrl = '';

  /// 偏好中的模式开关（同上，用户选择优先）
  bool _savedShowContent = false;

  /// 偏好中的分类选择（同上，用户选择优先）
  Map<String, String> _kindSelections = {};

  /// 已落盘值缓存（空 = 尚未回读/尚未写入）：仅在与目标值不同时写盘，
  /// 避免每次书源列表变化都重复写同一份偏好
  bool? _persistedShowContent;
  String? _persistedSourceUrl;
  String? _persistedKinds;

  /// 用户本次显式切换模式/书源（优先于尚未完成的偏好回读）
  bool? _contentOverride;
  String? _sourceOverride;

  /// 用户在偏好回读完成前改动的布局（优先于回读值）
  bool? _gridModeOverride;
  int? _gridCountPortraitOverride;
  int? _gridCountLandscapeOverride;

  /// 偏好未回读时用户改过分类记忆：回读合并后再落盘
  bool _kindsDirty = false;

  bool _disposed = false;

  @override
  ExploreMainState build() {
    ref.onDispose(() => _disposed = true);
    // 发现源列表变化（导入/删除/停用/加载完成）时重新校验选中源是否仍存在。
    // fireImmediately：书源若已先于本 Notifier 加载完成，登记时立即补做一次
    // 恢复判定，避免错过「只通知一次」的加载完成事件。
    ref.listen(
      exploreNotifierProvider,
      (_, _) => _resolveSelection(),
      fireImmediately: true,
    );
    Future.microtask(_loadPrefs);
    return const ExploreMainState();
  }

  Future<void> _loadPrefs() async {
    final persistedContent = await _settings.getBoolPref(
      exploreMainContentKey,
      defaultValue: false,
    );
    final persistedSourceUrl = await _settings.getStringPref(
      exploreMainSourceUrlKey,
    );
    final persistedKindsRaw = await _settings.getStringPref(exploreMainKindKey);
    final layoutMode = await _settings.getIntPref(
      exploreLayoutModeKey,
      defaultValue: 0,
    );
    final portrait = await _settings.getIntPref(
      exploreLayoutGridPortraitKey,
      defaultValue: 3,
    );
    final landscape = await _settings.getIntPref(
      exploreLayoutGridLandscapeKey,
      defaultValue: 7,
    );
    if (_disposed) return;

    // 用户操作优先：回读期间已发生的显式选择不回退；落盘缓存同样保留
    // 用户刚写入的值，避免后续「比较现值」时判断失真。
    if (_contentOverride != null) {
      _savedShowContent = _contentOverride!;
    } else {
      _savedShowContent = persistedContent;
      _persistedShowContent = persistedContent;
    }
    if (_sourceOverride != null) {
      _savedSourceUrl = _sourceOverride!;
    } else {
      _savedSourceUrl = persistedSourceUrl;
      _persistedSourceUrl = persistedSourceUrl;
    }
    // 分类记忆按源合并：磁盘值打底 + 本次用户选择覆盖同源条目
    final parsedKinds = parseExploreKindSelections(persistedKindsRaw);
    _kindSelections = {...parsedKinds, ..._kindSelections};
    // 用户回读前改过分类时不把磁盘值当作已落盘基准（合并结果需补写一次）
    if (!_kindsDirty) _persistedKinds = persistedKindsRaw;

    _prefsLoaded = true;
    _emit(
      state.copyWith(
        loaded: true,
        showContent: _savedShowContent,
        kindSelections: _kindSelections,
        gridMode: _gridModeOverride ?? (layoutMode == 1),
        gridCountPortrait: (_gridCountPortraitOverride ?? portrait).clamp(
          exploreGridCountMin,
          exploreGridCountMax,
        ),
        gridCountLandscape: (_gridCountLandscapeOverride ?? landscape).clamp(
          exploreGridCountMin,
          exploreGridCountMax,
        ),
      ),
    );
    // 用户先改分类、偏好后到：合并结果需要补写一次（否则同源旧条目丢失）
    if (_kindsDirty) {
      _kindsDirty = false;
      _persistKinds();
    }
    _resolveSelection();
  }

  /// 切换源列表 ⇄ 源内容模式
  void setShowContent(bool enabled) {
    _contentOverride = enabled;
    _savedShowContent = enabled;
    if (state.showContent != enabled) {
      _emit(state.copyWith(showContent: enabled));
    }
    _persistShowContent(enabled);
    // 已为 true 时也解析一次：启动恢复竞态可能留下空选中源
    //（书源先到/偏好先到两种时序都由本次自愈兜底）
    if (enabled) _resolveSelection();
  }

  /// 选择源内容模式的书源（并持久化）
  void selectSource(String sourceUrl) {
    if (sourceUrl.isEmpty) return;
    _sourceOverride = sourceUrl;
    _savedSourceUrl = sourceUrl;
    _emit(state.copyWith(selectedSourceUrl: sourceUrl));
    _persistSourceUrl(sourceUrl);
  }

  /// 记录指定书源上次浏览的分类键（并持久化映射）
  void selectKind(String sourceUrl, String kindKey) {
    if (sourceUrl.isEmpty || kindKey.isEmpty) return;
    if (_kindSelections[sourceUrl] == kindKey) return;
    _kindSelections = {..._kindSelections, sourceUrl: kindKey};
    _emit(state.copyWith(kindSelections: _kindSelections));
    if (!_prefsLoaded) {
      // 偏好尚未回读：先记录并延后落盘，回读后与磁盘映射合并再写，
      // 避免覆盖其他书源的分类记忆
      _kindsDirty = true;
      return;
    }
    _persistKinds();
  }

  /// 切换列表/网格布局
  void setGridMode(bool enabled) {
    _gridModeOverride = enabled;
    if (state.gridMode == enabled) return;
    _emit(state.copyWith(gridMode: enabled));
    unawaited(_settings.setIntPref(exploreLayoutModeKey, enabled ? 1 : 0));
  }

  /// 保存网格列数（按屏幕方向分别持久化，对齐参考版横竖屏两键）
  void setGridCount(int count, {required bool landscape}) {
    final clamped = count.clamp(exploreGridCountMin, exploreGridCountMax);
    if (landscape) {
      _gridCountLandscapeOverride = clamped;
      if (state.gridCountLandscape == clamped) return;
      _emit(state.copyWith(gridCountLandscape: clamped));
      unawaited(_settings.setIntPref(exploreLayoutGridLandscapeKey, clamped));
    } else {
      _gridCountPortraitOverride = clamped;
      if (state.gridCountPortrait == clamped) return;
      _emit(state.copyWith(gridCountPortrait: clamped));
      unawaited(_settings.setIntPref(exploreLayoutGridPortraitKey, clamped));
    }
  }

  /// 校验选中书源是否仍有效；源被删/列表为空时回退源列表模式
  ///
  /// [persist] 见 [_fallbackToSourceList]：书源加载失败时只回退 UI。
  void _resolveSelection() {
    if (_disposed || !_prefsLoaded) return;
    final exploreNotifier = ref.read(exploreNotifierProvider.notifier);
    if (!exploreNotifier.sourcesLoaded) return;
    final exploreState = ref.read(exploreNotifierProvider);

    // 加载/刷新进行中：当前列表是上一轮快照（失败重载时可能为空），
    // 不能据此判定「无源/源被删」并清偏好——等本轮加载完成的通知再判定
    if (exploreState.isLoading) return;

    // 书源加载失败：列表为空是「未知」而非「无源」，不能据此清理偏好
    if (exploreState.error != null) {
      _fallbackToSourceList(persist: false);
      return;
    }

    final sources = exploreState.bookSources;
    bool exists(String url) =>
        url.isNotEmpty && sources.any((s) => s.bookSourceUrl == url);

    // 书源库已变化：清理已删除源留下的分类记忆（只保留仍存在的源）
    _pruneKindSelections(sources);

    if (sources.isEmpty) {
      // 确实没有可用的发现源：内容模式无从展示，回退源列表并清空选择
      _fallbackToSourceList(persist: true);
      return;
    }

    final preferred = _sourceOverride ?? _savedSourceUrl;
    if (exists(preferred)) {
      // 偏好/用户选择有效：模式以用户覆盖或持久化偏好为准
      final wantContent = _contentOverride ?? _savedShowContent;
      if (state.selectedSourceUrl != preferred ||
          state.showContent != wantContent) {
        _emit(
          state.copyWith(
            selectedSourceUrl: preferred,
            showContent: wantContent,
          ),
        );
      }
      return;
    }

    if (preferred.isNotEmpty) {
      // 选中源已被删除 → 回退源列表（用户可见行为按本批验收要求）
      _fallbackToSourceList(persist: true);
      return;
    }

    // 从未选择过书源：默认第一个发现源（与参考版 resolveExploreMainSource 一致）
    final first = sources.first.bookSourceUrl;
    _savedSourceUrl = first;
    _emit(
      state.copyWith(
        selectedSourceUrl: first,
        showContent: _contentOverride ?? _savedShowContent,
      ),
    );
    _persistSourceUrl(first);
  }

  /// 回退到源列表模式
  ///
  /// [persist] 为 true 时清空并落盘三键（源确实被删除/确实无源）；
  /// 为 false 时（书源加载失败）只回退 UI，保留偏好以便恢复后自愈。
  void _fallbackToSourceList({required bool persist}) {
    if (state.showContent || state.selectedSourceUrl.isNotEmpty) {
      _emit(state.copyWith(showContent: false, selectedSourceUrl: ''));
    }
    if (!persist) return;
    _contentOverride = false;
    _sourceOverride = null;
    _savedShowContent = false;
    _savedSourceUrl = '';
    _persistShowContent(false);
    _persistSourceUrl('');
  }

  /// 清理已不存在书源的分类记忆（删除源后不留孤儿条目）
  void _pruneKindSelections(List<BookSource> sources) {
    if (_kindSelections.isEmpty) return;
    final urls = {for (final s in sources) s.bookSourceUrl};
    final pruned = {
      for (final entry in _kindSelections.entries)
        if (urls.contains(entry.key)) entry.key: entry.value,
    };
    if (pruned.length == _kindSelections.length) return;
    _kindSelections = pruned;
    _emit(state.copyWith(kindSelections: pruned));
    _persistKinds();
  }

  /// 写模式偏好（仅当与已落盘值不同）
  void _persistShowContent(bool value) {
    if (_persistedShowContent == value) return;
    _persistedShowContent = value;
    unawaited(_settings.setBoolPref(exploreMainContentKey, value));
  }

  /// 写书源偏好（仅当与已落盘值不同）
  void _persistSourceUrl(String value) {
    if (_persistedSourceUrl == value) return;
    _persistedSourceUrl = value;
    unawaited(_settings.setStringPref(exploreMainSourceUrlKey, value));
  }

  /// 写分类记忆映射（仅当与已落盘值不同）
  void _persistKinds() {
    final encoded = encodeExploreKindSelections(_kindSelections);
    if (_persistedKinds == encoded) return;
    _persistedKinds = encoded;
    unawaited(_settings.setStringPref(exploreMainKindKey, encoded));
  }

  void _emit(ExploreMainState next) {
    if (_disposed) return;
    state = next;
  }
}

/// 发现页源内容模式 Provider
///
/// 使用方式：
/// ```dart
/// final main = ref.watch(exploreMainNotifierProvider);
/// ref.read(exploreMainNotifierProvider.notifier).setShowContent(true);
/// ```
final exploreMainNotifierProvider =
    NotifierProvider<ExploreMainNotifier, ExploreMainState>(
      ExploreMainNotifier.new,
    );
