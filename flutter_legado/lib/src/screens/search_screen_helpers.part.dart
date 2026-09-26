// search_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SearchHelpers 承载：输入帮助显隐 / 结果滚动 / 停止 FAB 等。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/
// didChangeAppLifecycleState/build）留在主类。
part of 'search_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SearchHelpers on _SearchScreenState {

  /// 聚焦变化时更新输入帮助层显隐
  void _onFocusChanged() => _updateInputHelpVisibility();

  /// 对标原版 setOnQueryTextFocusChangeListener + visibleInputHelp
  ///
  /// [结果可见性口径修订 | 2026-09-26] 原口径「聚焦即帮助层」在桌面/模拟器
  /// 上键盘与焦点解耦（键盘已收而焦点滞留）会长期盖住已有结果——真机验收
  /// 连续两轮踩中（2.0.310 结果不可见 / 2.0.311 收起横幅后结果消失）。
  /// 新口径：**编辑新查询时才显示帮助层**——文字与已搜关键词不一致（正在
  /// 输入/联想场景）或无结果或空词时显示；结果一旦存在且对应当前关键词，
  /// 保持可见（含重新聚焦）。帮助层经「清空关键词 / 输入新词」可达，
  /// 原版聚焦绑定的语义在此登记为有意分叉（结果优先于历史层）。
  void _updateInputHelpVisibility() {
    final state = ref.read(searchNotifierProvider);
    final queryNotBlank = _searchController.text.trim().isNotEmpty;
    final editingNewQuery = _searchController.text.trim() != state.keyword;
    final shouldShow = !state.isLoading &&
        (queryNotBlank ? editingNewQuery || !state.hasResults : true);
    if (_showInputHelp != shouldShow && mounted) {
      setState(() => _showInputHelp = shouldShow);
    }
  }


}
