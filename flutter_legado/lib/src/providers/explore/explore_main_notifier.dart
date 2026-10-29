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
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

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

  /// 偏好中的分类选择（同上，用户选择优先）
  Map<String, String> _kindSelections = {};

  /// 用户本次显式切换模式/书源（优先于尚未完成的偏好回读）
  bool? _contentOverride;
  String? _sourceOverride;

  bool _disposed = false;

  @override
  ExploreMainState build() {
    ref.onDispose(() => _disposed = true);
    // 发现源列表变化（导入/删除/停用）时重新校验选中源是否仍存在
    ref.listen(exploreNotifierProvider, (_, _) => _resolveSelection());
    Future.microtask(_loadPrefs);
    return const ExploreMainState();
  }

  Future<void> _loadPrefs() async {
    final showContent = await _settings.getBoolPref(
      exploreMainContentKey,
      defaultValue: false,
    );
    final sourceUrl = await _settings.getStringPref(exploreMainSourceUrlKey);
    final kindsRaw = await _settings.getStringPref(exploreMainKindKey);
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

    _savedSourceUrl = sourceUrl;
    _kindSelections = parseExploreKindSelections(kindsRaw);
    _prefsLoaded = true;
    _emit(
      state.copyWith(
        loaded: true,
        // 偏好回读与用户操作竞态：用户已显式切换时以用户为准
        showContent: _contentOverride ?? showContent,
        kindSelections: _kindSelections,
        gridMode: layoutMode == 1,
        gridCountPortrait: portrait.clamp(
          exploreGridCountMin,
          exploreGridCountMax,
        ),
        gridCountLandscape: landscape.clamp(
          exploreGridCountMin,
          exploreGridCountMax,
        ),
      ),
    );
    _resolveSelection();
  }

  /// 切换源列表 ⇄ 源内容模式
  void setShowContent(bool enabled) {
    _contentOverride = enabled;
    if (state.showContent == enabled) {
      // 状态未变也要落盘：启动时偏好回读可能尚未完成
      unawaited(_settings.setBoolPref(exploreMainContentKey, enabled));
      return;
    }
    _emit(state.copyWith(showContent: enabled));
    unawaited(_settings.setBoolPref(exploreMainContentKey, enabled));
    // 无可用发现源时保持源列表（回退逻辑与源删除同口径）
    if (enabled) _resolveSelection();
  }

  /// 选择源内容模式的书源（并持久化）
  void selectSource(String sourceUrl) {
    if (sourceUrl.isEmpty) return;
    _sourceOverride = sourceUrl;
    _savedSourceUrl = sourceUrl;
    _emit(state.copyWith(selectedSourceUrl: sourceUrl));
    unawaited(_settings.setStringPref(exploreMainSourceUrlKey, sourceUrl));
  }

  /// 记录指定书源上次浏览的分类键（并持久化映射）
  void selectKind(String sourceUrl, String kindKey) {
    if (sourceUrl.isEmpty || kindKey.isEmpty) return;
    if (_kindSelections[sourceUrl] == kindKey) return;
    _kindSelections = {..._kindSelections, sourceUrl: kindKey};
    _emit(state.copyWith(kindSelections: _kindSelections));
    unawaited(
      _settings.setStringPref(
        exploreMainKindKey,
        encodeExploreKindSelections(_kindSelections),
      ),
    );
  }

  /// 切换列表/网格布局
  void setGridMode(bool enabled) {
    if (state.gridMode == enabled) return;
    _emit(state.copyWith(gridMode: enabled));
    unawaited(_settings.setIntPref(exploreLayoutModeKey, enabled ? 1 : 0));
  }

  /// 保存网格列数（按屏幕方向分别持久化，对齐参考版横竖屏两键）
  void setGridCount(int count, {required bool landscape}) {
    final clamped = count.clamp(exploreGridCountMin, exploreGridCountMax);
    if (landscape) {
      if (state.gridCountLandscape == clamped) return;
      _emit(state.copyWith(gridCountLandscape: clamped));
      unawaited(_settings.setIntPref(exploreLayoutGridLandscapeKey, clamped));
    } else {
      if (state.gridCountPortrait == clamped) return;
      _emit(state.copyWith(gridCountPortrait: clamped));
      unawaited(_settings.setIntPref(exploreLayoutGridPortraitKey, clamped));
    }
  }

  /// 校验选中书源是否仍有效；源被删/列表为空时回退源列表模式
  void _resolveSelection() {
    if (_disposed || !_prefsLoaded) return;
    final exploreNotifier = ref.read(exploreNotifierProvider.notifier);
    if (!exploreNotifier.sourcesLoaded) return;
    final sources = ref.read(exploreNotifierProvider).bookSources;

    bool exists(String url) =>
        url.isNotEmpty && sources.any((s) => s.bookSourceUrl == url);

    if (sources.isEmpty) {
      // 没有可用的发现源：内容模式无从展示，回退源列表并清空选择
      if (state.showContent || state.selectedSourceUrl.isNotEmpty) {
        _contentOverride = false;
        _emit(state.copyWith(showContent: false, selectedSourceUrl: ''));
      }
      if (_savedSourceUrl.isNotEmpty) {
        _savedSourceUrl = '';
        _sourceOverride = null;
        unawaited(_settings.setStringPref(exploreMainSourceUrlKey, ''));
      }
      unawaited(_settings.setBoolPref(exploreMainContentKey, false));
      return;
    }

    final preferred = _sourceOverride ?? _savedSourceUrl;
    if (exists(preferred)) {
      if (state.selectedSourceUrl != preferred) {
        _emit(state.copyWith(selectedSourceUrl: preferred));
      }
      return;
    }

    if (preferred.isNotEmpty) {
      // 选中源已被删除 → 回退源列表（用户可见行为按本批验收要求）
      _savedSourceUrl = '';
      _sourceOverride = null;
      _contentOverride = false;
      _emit(state.copyWith(showContent: false, selectedSourceUrl: ''));
      unawaited(_settings.setBoolPref(exploreMainContentKey, false));
      unawaited(_settings.setStringPref(exploreMainSourceUrlKey, ''));
      return;
    }

    // 从未选择过书源：默认第一个发现源（与参考版 resolveExploreMainSource 一致）
    final first = sources.first.bookSourceUrl;
    _savedSourceUrl = first;
    _emit(state.copyWith(selectedSourceUrl: first));
    unawaited(_settings.setStringPref(exploreMainSourceUrlKey, first));
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
