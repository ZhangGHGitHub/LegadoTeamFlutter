// search_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SearchHelpers 承载：输入帮助显隐 / 结果滚动 / 停止 FAB 等。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/
// didChangeAppLifecycleState/build）留在主类。
part of 'search_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SearchHelpers on _SearchScreenState {

  /// 刷新溢出菜单用的书源缓存（加载失败时动态分组条目隐藏，静态条目不受影响）
  Future<void> _refreshMenuSources() async {
    try {
      final list = await ref.read(bookApiProvider).getEnabledBookSources();
      if (!mounted) return;
      setState(() => _menuSources = list);
    } catch (_) {
      // 静默：菜单仍显示静态条目
    }
  }

  /// 聚焦变化时更新输入帮助层显隐
  void _onFocusChanged() => _updateInputHelpVisibility();

  /// 对标原版 setOnQueryTextFocusChangeListener + visibleInputHelp
  void _updateInputHelpVisibility() {
    final state = ref.read(searchNotifierProvider);
    final hasFocus = _focusNode.hasFocus;
    final queryNotBlank = _searchController.text.trim().isNotEmpty;
    final shouldShow = !state.isLoading &&
        !(!hasFocus && state.hasResults && queryNotBlank);
    if (_showInputHelp != shouldShow && mounted) {
      setState(() => _showInputHelp = shouldShow);
    }
  }


}
