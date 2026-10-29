// 阅读器顶栏动作配置的加载/保存（批37）
//
// 持久化落 SharedPreferences，键对齐参考版
// `ReadButtonConfigDelegate`（prefs 文件 `title_bar_actions` + 键 `actions`），
// 值格式 `id,true;id,false`。键名见
// `reader_top_bar_actions.dart::kReaderTopBarActionsPrefsKey`。
//
// 背景：参考版把顶栏按钮配置放在 SharedPreferences；我方备份的 `appPrefs`
// 段会遍历全部未排除键（见 RestoreIgnorePrefs.collectForBackup），故本键
// 自动纳入备份/恢复，无需改 Rust 契约。为让「忽略阅读配置」同时跳过本键，
// 已将其加入 `RestoreIgnorePrefs.readPrefKeys`。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/providers.dart' show settingsProvider;
import '../../widgets/reader/reader_top_bar_actions.dart';

/// 顶栏动作配置 Notifier：启动异步加载 + 修改即时持久化
class ReaderTopBarActionsNotifier extends Notifier<ReaderTopBarActionsState> {
  /// 变更代数：异步加载返回时若用户已改配置，丢弃旧值（对齐 ThemeNotifier）
  int _generation = 0;

  /// [批37b P3-10] provider 是否已销毁：异步 `_load` 返回时不得再读 ref /
  /// 写 state（Riverpod 销毁后写 state 会抛错）
  bool _disposed = false;

  @override
  ReaderTopBarActionsState build() {
    ref.onDispose(() => _disposed = true);
    Future.microtask(_load);
    return ReaderTopBarActionsState(defaultReaderTopBarActionItems());
  }

  Future<void> _load() async {
    if (_disposed) return;
    final generation = _generation;
    final raw = await ref
        .read(settingsProvider)
        .getStringPref(kReaderTopBarActionsPrefsKey);
    if (_disposed || generation != _generation) return;
    state = ReaderTopBarActionsState(decodeReaderTopBarActions(raw));
  }

  /// 保存完整配置（顺序 + 开关），归一化后落盘
  Future<void> save(List<ReaderTopBarActionItem> items) async {
    _generation++;
    final normalized = normalizeReaderTopBarActionItems(items);
    state = ReaderTopBarActionsState(normalized);
    await ref
        .read(settingsProvider)
        .setStringPref(
          kReaderTopBarActionsPrefsKey,
          encodeReaderTopBarActions(normalized),
        );
  }

  /// 切换单个动作开关（「更多」固定开启，调用无效）
  Future<void> toggle(String id) async {
    final item = state.itemFor(id);
    if (item == null) return;
    if (id == kReaderMoreActionsId) return;
    await save([
      for (final e in state.items)
        e.id == id ? e.copyWith(enabled: !e.enabled) : e,
    ]);
  }

  /// 上移/下移一位（[delta] 仅支持 -1/+1；越界忽略）
  ///
  /// 「更多」固定末位，不参与排序：只在其余动作组成的区间内交换。
  Future<void> move(String id, int delta) async {
    if (id == kReaderMoreActionsId) return;
    final others = [
      for (final e in state.items)
        if (e.id != kReaderMoreActionsId) e,
    ];
    final index = others.indexWhere((e) => e.id == id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= others.length) return;
    final moved = others.removeAt(index);
    others.insert(target, moved);
    await save(others);
  }

  /// 恢复默认顺序与默认开关（对齐参考版 DEFAULT_TITLE_BAR_ACTION_IDS）
  Future<void> restoreDefaults() async {
    await save(defaultReaderTopBarActionItems());
  }
}

/// 顶栏动作配置 Provider
final readerTopBarActionsProvider =
    NotifierProvider<ReaderTopBarActionsNotifier, ReaderTopBarActionsState>(
      ReaderTopBarActionsNotifier.new,
    );
