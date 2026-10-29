// 阅读主题列表页（批38｜参考版阅读主题列表管理）
//
// 参考依据（legado-with-MD3）：
// - `ui/book/read/sheet/ThemeListContent.kt`：网格/流式两种布局、网格列数
//   2..6（⋮ 菜单原地翻页选择）、多选管理底栏（全选/反选/删除/导出/分享/
//   置顶置底）、删除二次确认、定位当前/回顶/回底悬浮钮、内置预设钉死
//   （不可删/不可拖/不可勾选）、新建 `+` 卡；
// - `ui/book/read/sheet/GlobalThemePage.kt`：阅读设置内「阅读主题」入口；
// - `ReadStyleDelegate.kt`：单份导出/分享、名称回落「阅读主题」；
// - `PreferKey.themeGridColumns`：列数持久化键。
//
// 与参考版的差异（本批 MVP 范围，见交付说明）：
// - 参考版「列表」是名字 chip 流式布局、网格是背景图预览卡；我方无背景图
//   能力，网格卡改为「背景色 + 文字色样张」，列表保持 chip 形态；
// - 搜索框/日夜切换钮/长按进背景文字配置不在本批范围，未实现；
// - 内置主题不可重命名/删除/排序（与参考版预设钉死一致）。
//
// 编写：全栈工程师（批38） ｜ 2026-10-29
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection, SliverConstraints;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_theme.dart';
import '../providers/reader/reader_notifier.dart';
import '../providers/reader/reader_theme_notifier.dart';
import '../services/export_file_service.dart';
import '../services/reader_theme_service.dart';
import 'reader_config_panel.dart';

/// 阅读主题列表页
class ReaderThemeScreen extends ConsumerStatefulWidget {
  const ReaderThemeScreen({super.key});

  @override
  ConsumerState<ReaderThemeScreen> createState() => _ReaderThemeScreenState();
}

class _ReaderThemeScreenState extends ConsumerState<ReaderThemeScreen> {
  final ScrollController _scrollController = ScrollController();

  /// 每个主题一个 GlobalKey，供「定位当前」做 ensureVisible
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};

  /// 网格/列表布局（对齐参考版：本次打开有效，不持久化）
  bool _gridMode = true;

  /// 管理态（多选）
  bool _manageMode = false;

  /// 管理态勾选的主题 id（只允许自建主题）
  final Set<String> _selectedIds = <String>{};

  /// 应用主题进行中（防连点重复落盘）
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureConfigLoaded());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 主题页可能先于阅读页打开：排版配置未加载时兜底自加载
  Future<void> _ensureConfigLoaded() async {
    if (ref.read(readerAdvConfigProvider) != null) return;
    final cfg = await ReaderAdvancedConfig.load();
    if (!mounted) return;
    ref.read(readerAdvConfigProvider.notifier).apply(cfg);
  }

  // ===== 当前样式快照 =====

  /// 由当前阅读页状态构建样式快照（新建主题用；含 prefs 正文字体）
  Future<ReaderThemeStyle> _snapshotCurrentStyle() async {
    final readerState = ref.read(readerNotifierProvider);
    var adv = ref.read(readerAdvConfigProvider);
    adv ??= await ReaderAdvancedConfig.load();
    final prefs = await SharedPreferences.getInstance();
    final fontFamily = prefs.getString('reader_font_family') ?? '';
    return _styleFromCurrent(readerState, adv, fontFamily);
  }

  /// 由阅读页状态 + 排版配置组装主题样式
  ReaderThemeStyle _styleFromCurrent(
    ReaderState readerState,
    ReaderAdvancedConfig adv,
    String fontFamily,
  ) {
    return ReaderThemeStyle(
      fontSize: readerState.fontSize,
      lineHeight: readerState.lineHeight,
      backgroundColor: readerState.backgroundColor.toARGB32(),
      textColor: adv.customTextColor,
      fontFamily: fontFamily,
      titleFont: adv.titleFont,
      letterSpacing: adv.letterSpacing,
      paragraphIndent: adv.paragraphIndent,
      paragraphSpacing: adv.paragraphSpacing,
      marginTop: adv.pageMarginTop,
      marginBottom: adv.pageMarginBottom,
      marginLeft: adv.pageMarginLeft,
      marginRight: adv.pageMarginRight,
      textBold: adv.textBold,
      italic: adv.italic,
    );
  }

  // ===== 应用主题 =====

  /// 应用主题：字号/行距/背景走 ReaderNotifier，排版走 ReaderAdvancedConfig，
  /// 正文字体写 prefs（ReaderPageView 在下一次布局读取并重载自定义字体）
  ///
  /// [showMessage] 为 false 时不弹「已应用」提示（「恢复默认」等复合操作自己
  /// 汇总一条提示，避免连续两条 SnackBar 互相覆盖）。
  Future<void> _applyTheme(
    ReaderTheme theme, {
    bool showMessage = true,
  }) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final style = theme.style;
      // 先取主题亮度：后续 await 之后不再跨 async gap 使用 BuildContext
      final isNight = Theme.of(context).brightness == Brightness.dark;
      final readerNotifier = ref.read(readerNotifierProvider.notifier);
      readerNotifier.updateFontSize(style.fontSize);
      readerNotifier.updateLineHeight(style.lineHeight);

      // 背景：命中既有预设色走「预设索引」链路，否则走「自定义背景」链路，
      // 保证背景 chip 选中态与主题实际背景一致
      final background = Color(style.backgroundColor);
      final presetIndex = style.presetBackgroundIndex(
        ReaderBackground.presets.map((color) => color.toARGB32()),
      );
      if (presetIndex >= 0) {
        readerNotifier.updateBackgroundColor(
          ReaderBackground.presets[presetIndex],
        );
      } else {
        await readerNotifier.updateCustomBackgroundColor(background);
      }

      final base =
          ref.read(readerAdvConfigProvider) ??
          await ReaderAdvancedConfig.load();
      final adv = base.withThemeStyle(style);
      await adv.save(isNight: isNight);
      if (!mounted) return;
      ref.read(readerAdvConfigProvider.notifier).apply(adv);

      final prefs = await SharedPreferences.getInstance();
      if (style.fontFamily.isEmpty) {
        await prefs.remove('reader_font_family');
      } else {
        await prefs.setString('reader_font_family', style.fontFamily);
      }

      await ref.read(readerThemeProvider.notifier).markCurrent(theme.id);
      if (!mounted || !showMessage) return;
      _showSnack('已应用「${theme.name}」');
    } catch (e) {
      if (mounted) _showSnack('应用主题失败：$e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  // ===== 新建 / 重命名 / 删除 / 排序 =====

  Future<void> _createTheme() async {
    final themeName = await _askName(
      title: '新建主题',
      initialValue:
          '主题${ref.read(readerThemeProvider).customThemes.length + 1}',
      hint: '以当前阅读样式另存为',
    );
    if (themeName == null) return;
    final style = await _snapshotCurrentStyle();
    if (!mounted) return;
    final theme = await ref
        .read(readerThemeProvider.notifier)
        .addTheme(name: themeName, style: style);
    if (!mounted) return;
    _showSnack('已新建「${theme.name}」');
    _scrollToBottomSoon();
  }

  Future<void> _renameTheme(ReaderTheme theme) async {
    final newName = await _askName(
      title: '重命名主题',
      initialValue: theme.name,
      hint: '主题名称',
    );
    if (newName == null) return;
    final actualName = await ref
        .read(readerThemeProvider.notifier)
        .renameTheme(theme.id, newName);
    if (!mounted) return;
    _showSnack(
      actualName == null ? '重命名失败' : '已重命名为「$actualName」',
    );
  }

  Future<void> _confirmDelete(Set<String> ids) async {
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除主题'),
        content: Text('确定删除选中的 ${ids.length} 个主题？内置主题不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final count = await ref
        .read(readerThemeProvider.notifier)
        .deleteThemes(ids);
    if (!mounted) return;
    setState(() => _selectedIds.removeAll(ids));
    _showSnack('已删除 $count 个主题');
  }

  Future<void> _moveSelected(int delta) async {
    if (_selectedIds.length != 1) return;
    await ref
        .read(readerThemeProvider.notifier)
        .moveTheme(_selectedIds.single, delta);
  }

  Future<void> _moveSelectedToEdge({required bool toTop}) async {
    if (_selectedIds.isEmpty) return;
    await ref
        .read(readerThemeProvider.notifier)
        .moveThemesToEdge(_selectedIds, toTop: toTop);
  }

  /// 恢复默认主题
  ///
  /// 语义与字面一致（批38b 审查 P2-4）：「恢复默认」= 清空用户自建主题 +
  /// 把当前阅读样式应用为内置默认（预设1），而不是只删数据、阅读样式留在
  /// 用户最后一次的自定义状态。
  Future<void> _restoreDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认主题'),
        content: const Text('将删除全部自建主题，并把阅读样式恢复为内置「预设1」，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(readerThemeProvider.notifier).restoreDefaults();
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    // 内置默认 = 预设1（kBuiltInReaderThemes 顺序固定：微信读书、预设1..4）
    final defaultTheme = kBuiltInReaderThemes.firstWhere(
      (theme) => theme.id == 'builtin-preset-1',
      orElse: () => kBuiltInReaderThemes[1],
    );
    await _applyTheme(defaultTheme, showMessage: false);
    if (!mounted) return;
    _showSnack('已恢复默认主题，阅读样式已应用「${defaultTheme.name}」');
  }

  // ===== 导入 / 导出 / 分享 =====

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (!mounted) return;
      if (bytes == null) {
        _showSnack('读取文件失败');
        return;
      }
      await _doImport(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      if (mounted) _showSnack('导入失败：$e');
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _showSnack('剪贴板没有主题 JSON');
      return;
    }
    await _doImport(text);
  }

  Future<void> _doImport(String raw) async {
    try {
      final imported = await ref
          .read(readerThemeProvider.notifier)
          .importThemes(raw);
      if (!mounted) return;
      _showSnack('已导入 ${imported.length} 个主题');
      _scrollToBottomSoon();
    } on FormatException catch (e) {
      if (mounted) _showSnack('导入失败：${e.message}');
    } catch (e) {
      if (mounted) _showSnack('导入失败：$e');
    }
  }

  Future<void> _exportThemes(List<ReaderTheme> themes) async {
    if (themes.isEmpty) return;
    final content = themes.length == 1
        ? ReaderThemeCodec.encode(themes.single)
        : const JsonEncoder.withIndent('  ').convert(<Map<String, dynamic>>[
            for (final theme in themes) theme.toJson(),
          ]);
    final name = themes.length == 1 ? themes.single.name : '阅读主题';
    try {
      final saved = await const ExportFileService().saveToLocal(
        fileName: '${_safeFileName(name)}.json',
        content: content,
      );
      if (!mounted) return;
      if (saved == null) return; // 用户取消
      _showSnack('已导出「$name」');
    } catch (e) {
      if (mounted) _showSnack('导出失败：$e');
    }
  }

  Future<void> _shareThemes(List<ReaderTheme> themes) async {
    if (themes.isEmpty) return;
    final content = themes.length == 1
        ? ReaderThemeCodec.encode(themes.single)
        : const JsonEncoder.withIndent('  ').convert(<Map<String, dynamic>>[
            for (final theme in themes) theme.toJson(),
          ]);
    final name = themes.length == 1 ? themes.single.name : '阅读主题';
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_safeFileName(name)}.json',
      );
      try {
        await file.writeAsString(content);
        await Share.shareXFiles(<XFile>[
          XFile(file.path, mimeType: 'application/json'),
        ], subject: name);
      } finally {
        // 分享结束即清理临时文件（系统分享已拿到副本/句柄）；删除失败不影响
        // 分享结果，也不向用户报错
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) _showSnack('分享失败：$e');
    }
  }

  /// 文件名净化：去掉 Windows/Android 文件系统非法字符
  String _safeFileName(String name) {
    final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return sanitized.isEmpty ? '阅读主题' : sanitized;
  }

  // ===== 定位 / 回顶 / 回底 =====

  Future<void> _locateCurrent() async {
    final themeState = ref.read(readerThemeProvider);
    final id = themeState.currentId;
    if (id.isEmpty) return;
    final itemContext = _itemKeys[id]?.currentContext;
    if (itemContext != null) {
      await Scrollable.ensureVisible(
        itemContext,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
      return;
    }
    // 网格是惰性构建：目标卡未构建时没有 context，先按网格代理自身几何
    // 精确算出目标行偏移滚到附近，等目标卡构建出 context 后再居中
    if (!_gridMode || !_scrollController.hasClients) return;
    final index = themeState.themes.indexWhere((theme) => theme.id == id);
    if (index < 0) return;
    final position = _scrollController.position;
    final target = _gridItemCenterOffset(
      index: index,
      columns: themeState.gridColumns,
      position: position,
      crossAxisExtent: _gridViewportWidth(position),
    );
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    // 懒加载可能分帧构建目标卡：逐帧等待 context 出现再精确居中（最多 5 帧，
    // 目标行此时已在可视区内，正常 1~2 帧即命中）
    final builtContext = await _waitForItemContext(id);
    if (builtContext == null || !mounted) return;
    // builtContext 来自 GlobalKey 重新取到的目标卡，不是 State.context；
    // 上面的 mounted 已守住页面销毁，分析器的跨 async gap 提示属误报
    await Scrollable.ensureVisible(
      // ignore: use_build_context_synchronously
      builtContext,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: 0.5,
    );
  }

  /// 网格视口横向宽度（交叉轴）
  ///
  /// [ScrollPosition.viewportDimension] 是主轴（纵向）尺寸，不能当交叉轴用；
  /// 这里取滚动视图实际渲染宽度，网格代理据此算出与真实布局一致的列宽。
  double _gridViewportWidth(ScrollPosition position) {
    final renderObject = position.context.storageContext.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.size.width;
    }
    return MediaQuery.sizeOf(context).width;
  }

  /// 目标卡中心在滚动轴上的位置（用网格代理几何计算，含行距与名称行）
  ///
  /// 直接请求 [ReaderThemeGrid.delegateFor] 的 `SliverGridLayout`：
  /// 卡片高度由代理按宽高比算出（名称行在卡片内部，不再手工 `/0.62 + 32`
  /// 重复加名称行、也不漏 [ReaderThemeGrid.gridSpacing] 的主轴行距）。
  /// `crossAxisExtent` 取减去网格左右内边距后的内容宽度，与实际
  /// `SliverPadding` 内的网格 sliver 一致。
  double _gridItemCenterOffset({
    required int index,
    required int columns,
    required ScrollPosition position,
    required double crossAxisExtent,
  }) {
    final delegate = ReaderThemeGrid.delegateFor(columns);
    final contentWidth =
        crossAxisExtent - ReaderThemeGrid.gridPadding.horizontal;
    final layout = delegate.getLayout(
      SliverConstraints(
        axisDirection: AxisDirection.down,
        growthDirection: GrowthDirection.forward,
        userScrollDirection: ScrollDirection.idle,
        scrollOffset: position.pixels,
        precedingScrollExtent: 0,
        overlap: 0,
        remainingPaintExtent: position.viewportDimension,
        crossAxisExtent: contentWidth,
        crossAxisDirection: AxisDirection.right,
        viewportMainAxisExtent: position.viewportDimension,
        remainingCacheExtent: position.viewportDimension + 250,
        cacheOrigin: -250,
      ),
    );
    final geometry = layout.getGeometryForChildIndex(index);
    final itemCenter =
        ReaderThemeGrid.gridPadding.top +
        geometry.scrollOffset +
        geometry.mainAxisExtent / 2;
    return (itemCenter - position.viewportDimension / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
  }

  /// 逐帧等待目标卡的 [GlobalKey] 拿到 context（最多 [attempts] 帧）
  Future<BuildContext?> _waitForItemContext(
    String id, {
    int attempts = 5,
  }) async {
    for (var i = 0; i < attempts; i++) {
      final context = _itemKeys[id]?.currentContext;
      if (context != null) return context;
      if (!mounted) return null;
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
    return _itemKeys[id]?.currentContext;
  }

  Future<void> _scrollToEdge({required bool toBottom}) async {
    if (!_scrollController.hasClients) return;
    final target = toBottom ? _scrollController.position.maxScrollExtent : 0.0;
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ===== 交互辅助 =====

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _askName({
    required String title,
    required String initialValue,
    required String hint,
  }) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => _ThemeNameDialog(
        title: title,
        initialValue: initialValue,
        hint: hint,
      ),
    );
  }

  void _onThemeTap(ReaderTheme theme) {
    if (_manageMode) {
      // 内置主题钉死：管理态不可勾选
      if (theme.builtIn) return;
      setState(() {
        if (!_selectedIds.remove(theme.id)) _selectedIds.add(theme.id);
      });
      return;
    }
    // 应用进行中给出点击反馈，而不是静默吞掉（批38b 审查 P3-5）
    if (_applying) {
      _showSnack('正在应用主题…');
      return;
    }
    unawaited(_applyTheme(theme));
  }

  void _onThemeLongPress(ReaderTheme theme) {
    if (_manageMode) return;
    unawaited(_showThemeActions(theme));
  }

  Future<void> _showThemeActions(ReaderTheme theme) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                theme.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(theme.builtIn ? '内置主题' : '自建主题'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导出 JSON'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_exportThemes(<ReaderTheme>[theme]));
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享 JSON'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_shareThemes(<ReaderTheme>[theme]));
              },
            ),
            if (!theme.builtIn) ...[
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_renameTheme(theme));
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '删除',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_confirmDelete(<String>{theme.id}));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ===== 选中集合操作 =====

  List<ReaderTheme> _selectedThemes(ReaderThemeState themeState) =>
      <ReaderTheme>[
        for (final theme in themeState.themes)
          if (_selectedIds.contains(theme.id)) theme,
      ];

  void _selectAll(ReaderThemeState themeState) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(themeState.customThemes.map((theme) => theme.id));
    });
  }

  void _invertSelection(ReaderThemeState themeState) {
    setState(() {
      final inverted = <String>{
        for (final theme in themeState.customThemes)
          if (!_selectedIds.contains(theme.id)) theme.id,
      };
      _selectedIds
        ..clear()
        ..addAll(inverted);
    });
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(readerThemeProvider);
    // 清理已删除/已替换主题的 GlobalKey，避免 _itemKeys 随增删无限增长
    // （批38b 审查 P3-7）
    final liveIds = <String>{for (final theme in themeState.themes) theme.id};
    _itemKeys.removeWhere((id, _) => !liveIds.contains(id));
    // 首载完成前禁用菜单/列数/管理等入口：此时内存列表还是空的，任何变更
    // 都可能以空列表落盘覆盖磁盘主题库（批38b 审查 P2-1）
    final loaded = themeState.loaded;
    // 当前主题标记按已记录的 id（对齐参考版 styleSelect 语义：手动改样式
    // 不撤销「正在使用」标记，重新应用同一主题即再次对齐）
    final currentId = themeState.currentId;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读主题'),
        actions: <Widget>[
          IconButton(
            tooltip: _gridMode ? '切换为列表' : '切换为网格',
            icon: Icon(
              _gridMode ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
            onPressed: loaded
                ? () => setState(() => _gridMode = !_gridMode)
                : null,
          ),
          if (_gridMode)
            PopupMenuButton<int>(
              tooltip: '网格列数',
              icon: const Icon(Icons.view_column_rounded),
              enabled: loaded,
              initialValue: themeState.gridColumns,
              onSelected: (columns) {
                unawaited(
                  ref
                      .read(readerThemeProvider.notifier)
                      .setGridColumns(columns),
                );
              },
              itemBuilder: (menuContext) => <PopupMenuEntry<int>>[
                for (
                  var columns = ReaderThemeService.minGridColumns;
                  columns <= ReaderThemeService.maxGridColumns;
                  columns++
                )
                  CheckedPopupMenuItem<int>(
                    value: columns,
                    checked: columns == themeState.gridColumns,
                    child: Text('$columns 列'),
                  ),
              ],
            ),
          if (_manageMode)
            TextButton(
              onPressed: () => setState(() {
                _manageMode = false;
                _selectedIds.clear();
              }),
              child: const Text('完成'),
            )
          else
            IconButton(
              tooltip: '管理主题',
              icon: const Icon(Icons.checklist_rounded),
              onPressed: loaded ? () => setState(() => _manageMode = true) : null,
            ),
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: loaded,
            onSelected: (value) {
              switch (value) {
                case 'create':
                  unawaited(_createTheme());
                case 'import_file':
                  unawaited(_importFromFile());
                case 'import_clipboard':
                  unawaited(_importFromClipboard());
                case 'restore':
                  unawaited(_restoreDefaults());
              }
            },
            itemBuilder: (menuContext) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'create', child: Text('新建主题')),
              PopupMenuItem<String>(value: 'import_file', child: Text('从文件导入')),
              PopupMenuItem<String>(
                value: 'import_clipboard',
                child: Text('从剪贴板导入'),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(value: 'restore', child: Text('恢复默认主题')),
            ],
          ),
        ],
      ),
      body: loaded
          ? Stack(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    if (_manageMode) _buildManageHeader(themeState),
                    Expanded(
                      child: _gridMode
                          ? ReaderThemeGrid(
                              themes: themeState.themes,
                              columns: themeState.gridColumns,
                              currentId: currentId,
                              manageMode: _manageMode,
                              selectedIds: _selectedIds,
                              controller: _scrollController,
                              itemKeyBuilder: (id) =>
                                  _itemKeys.putIfAbsent(id, GlobalKey.new),
                              onTap: _onThemeTap,
                              onLongPress: _onThemeLongPress,
                              showAddTile: !_manageMode,
                              onAdd: () => unawaited(_createTheme()),
                            )
                          : _buildList(themeState, currentId),
                    ),
                  ],
                ),
                _buildFloatingActions(currentId, colorScheme),
                // 应用进行中：顶部细进度条给出反馈（点击已由 _onThemeTap 拦截）
                if (_applying)
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
      bottomNavigationBar: _manageMode ? _buildManageBar(themeState) : null,
    );
  }

  /// 列表布局：名字 chip（背景色圆点 + 名称），对齐参考版流式形态
  Widget _buildList(ReaderThemeState themeState, String currentId) {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final theme in themeState.themes)
            KeyedSubtree(
              key: _itemKeys.putIfAbsent(theme.id, GlobalKey.new),
              child: ReaderThemeChip(
                theme: theme,
                isCurrent: theme.id == currentId,
                manageMode: _manageMode,
                checked: _selectedIds.contains(theme.id),
                onTap: () => _onThemeTap(theme),
                onLongPress: () => _onThemeLongPress(theme),
              ),
            ),
          if (!_manageMode)
            ReaderThemeAddChip(onTap: () => unawaited(_createTheme())),
        ],
      ),
    );
  }

  Widget _buildManageHeader(ReaderThemeState themeState) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: <Widget>[
          Text(
            '已选 ${_selectedIds.length}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _selectAll(themeState),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: () => _invertSelection(themeState),
            child: const Text('反选'),
          ),
        ],
      ),
    );
  }

  Widget _buildManageBar(ReaderThemeState themeState) {
    final colorScheme = Theme.of(context).colorScheme;
    final selectedThemes = _selectedThemes(themeState);
    final hasSelection = selectedThemes.isNotEmpty;
    final single = selectedThemes.length == 1;

    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool danger = false,
    }) {
      final enabled = onTap != null;
      final color = danger
          ? colorScheme.error
          : enabled
          ? colorScheme.onSurface
          : colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 64,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              action(
                icon: Icons.arrow_upward_rounded,
                label: '上移',
                onTap: single ? () => unawaited(_moveSelected(-1)) : null,
              ),
              action(
                icon: Icons.arrow_downward_rounded,
                label: '下移',
                onTap: single ? () => unawaited(_moveSelected(1)) : null,
              ),
              action(
                icon: Icons.vertical_align_top_rounded,
                label: '置顶',
                onTap: hasSelection
                    ? () => unawaited(_moveSelectedToEdge(toTop: true))
                    : null,
              ),
              action(
                icon: Icons.vertical_align_bottom_rounded,
                label: '置底',
                onTap: hasSelection
                    ? () => unawaited(_moveSelectedToEdge(toTop: false))
                    : null,
              ),
              action(
                icon: Icons.upload_file_outlined,
                label: '导出',
                onTap: hasSelection
                    ? () => unawaited(_exportThemes(selectedThemes))
                    : null,
              ),
              action(
                icon: Icons.share_outlined,
                label: '分享',
                onTap: hasSelection
                    ? () => unawaited(_shareThemes(selectedThemes))
                    : null,
              ),
              action(
                icon: Icons.delete_outline,
                label: '删除',
                danger: true,
                onTap: hasSelection
                    ? () => unawaited(
                        _confirmDelete(<String>{
                          for (final theme in selectedThemes) theme.id,
                        }),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右下角悬浮纽：定位当前 / 回顶 / 回底（对齐参考版 ScrollFabButtons）
  Widget _buildFloatingActions(String currentId, ColorScheme colorScheme) {
    Widget fab({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Material(
          color: colorScheme.secondaryContainer,
          shape: const CircleBorder(),
          elevation: 1,
          child: IconButton(
            tooltip: tooltip,
            icon: Icon(
              icon,
              size: 20,
              color: onTap == null
                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                  : colorScheme.onSecondaryContainer,
            ),
            onPressed: onTap,
          ),
        ),
      );
    }

    return Positioned(
      right: 12,
      bottom: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          fab(
            icon: Icons.my_location_rounded,
            tooltip: '定位当前',
            onTap: currentId.isEmpty ? null : () => unawaited(_locateCurrent()),
          ),
          fab(
            icon: Icons.vertical_align_top_rounded,
            tooltip: '回到顶部',
            onTap: () => unawaited(_scrollToEdge(toBottom: false)),
          ),
          fab(
            icon: Icons.vertical_align_bottom_rounded,
            tooltip: '回到底部',
            onTap: () => unawaited(_scrollToEdge(toBottom: true)),
          ),
        ],
      ),
    );
  }
}

/// 主题命名对话框（自带 controller 生命周期，避免页面侧临时 controller 泄漏）
class _ThemeNameDialog extends StatefulWidget {
  const _ThemeNameDialog({
    required this.title,
    required this.initialValue,
    required this.hint,
  });

  final String title;
  final String initialValue;
  final String hint;

  @override
  State<_ThemeNameDialog> createState() => _ThemeNameDialogState();
}

class _ThemeNameDialogState extends State<_ThemeNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) return;
    Navigator.pop(context, trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _confirm(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('确定')),
      ],
    );
  }
}

/// 网格布局：固定列数 2..6，最后追加「新建主题」卡
class ReaderThemeGrid extends StatelessWidget {
  const ReaderThemeGrid({
    super.key,
    required this.themes,
    required this.columns,
    required this.currentId,
    required this.manageMode,
    required this.selectedIds,
    required this.controller,
    required this.itemKeyBuilder,
    required this.onTap,
    required this.onLongPress,
    this.showAddTile = false,
    this.onAdd,
  });

  /// 网格内边距（渲染与「定位当前」的几何计算共用同一来源）
  static const EdgeInsets gridPadding = EdgeInsets.fromLTRB(16, 16, 16, 96);

  /// 卡片横纵间距（渲染与定位共用；主轴行距必须参与偏移计算）
  static const double gridSpacing = 10;

  /// 卡片宽高比（宽:高）
  static const double gridChildAspectRatio = 0.62;

  /// 网格代理（渲染与「定位当前」共用，避免手写偏移与真实布局漂移）
  static SliverGridDelegateWithFixedCrossAxisCount delegateFor(int columns) {
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns.clamp(
        ReaderThemeService.minGridColumns,
        ReaderThemeService.maxGridColumns,
      ),
      crossAxisSpacing: gridSpacing,
      mainAxisSpacing: gridSpacing,
      childAspectRatio: gridChildAspectRatio,
    );
  }

  final List<ReaderTheme> themes;
  final int columns;
  final String currentId;
  final bool manageMode;
  final Set<String> selectedIds;
  final ScrollController controller;
  final GlobalKey Function(String id) itemKeyBuilder;
  final ValueChanged<ReaderTheme> onTap;
  final ValueChanged<ReaderTheme> onLongPress;
  final bool showAddTile;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final itemCount = themes.length + (showAddTile ? 1 : 0);
    return GridView.builder(
      controller: controller,
      padding: gridPadding,
      gridDelegate: delegateFor(columns),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= themes.length) {
          return ReaderThemeAddCard(onTap: onAdd);
        }
        final theme = themes[index];
        return KeyedSubtree(
          key: itemKeyBuilder(theme.id),
          child: ReaderThemeCard(
            theme: theme,
            isCurrent: theme.id == currentId,
            manageMode: manageMode,
            checked: selectedIds.contains(theme.id),
            onTap: () => onTap(theme),
            onLongPress: () => onLongPress(theme),
          ),
        );
      },
    );
  }
}

/// 网格主题卡：背景色 + 文字色样张 + 名称
class ReaderThemeCard extends StatelessWidget {
  const ReaderThemeCard({
    super.key,
    required this.theme,
    required this.isCurrent,
    required this.manageMode,
    required this.checked,
    required this.onTap,
    required this.onLongPress,
  });

  final ReaderTheme theme;
  final bool isCurrent;
  final bool manageMode;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 样张文字色：主题文字色优先，0=自动时按背景明暗取黑/白
  Color get _foreground {
    if (theme.style.textColor != 0) return Color(theme.style.textColor);
    final background = Color(theme.style.backgroundColor);
    return background.computeLuminance() > 0.5
        ? const Color(0xDD000000)
        : const Color(0xCCFFFFFF);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = Color(theme.style.backgroundColor);
    final borderColor = isCurrent
        ? colorScheme.primary
        : colorScheme.outlineVariant;
    // 整卡（含名称行）一个 InkWell：名称区此前在点击区域外，点名称无反应
    // （批38b 审查 P2-3）
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: borderColor,
                    width: isCurrent ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Material(
                  color: background,
                  child: Stack(
                    children: <Widget>[
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          // 6 列窄卡下 22pt 样张会超宽：统一缩放到卡片内
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  '阅读',
                                  style: TextStyle(
                                    color: _foreground,
                                    fontSize: 22,
                                    height: 1.15,
                                    fontWeight: theme.style.textBold == 1
                                        ? FontWeight.w700
                                        : theme.style.textBold == 2
                                        ? FontWeight.w300
                                        : FontWeight.w500,
                                    fontStyle: theme.style.italic
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Aa',
                                  style: TextStyle(
                                    color: _foreground.withValues(alpha: 0.6),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (isCurrent && !manageMode)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            key: ValueKey<String>(
                              'theme-current-${theme.id}',
                            ),
                            height: 3,
                            color: colorScheme.primary,
                          ),
                        ),
                      if (manageMode && theme.builtIn)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Icon(
                            Icons.lock_outline_rounded,
                            size: 12,
                            color: _foreground.withValues(alpha: 0.7),
                          ),
                        ),
                      if (manageMode && checked)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.check_rounded,
                              size: 13,
                              color: colorScheme.onPrimary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              theme.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isCurrent
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 网格「新建主题」卡
class ReaderThemeAddCard extends StatelessWidget {
  const ReaderThemeAddCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 整卡（含「新建主题」名称行）可点，与主题卡一致（批38b 审查 P2-3）
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Material(
                color: colorScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: 24,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '新建主题',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表布局 chip：背景色圆点 + 名称（对齐参考版流式布局）
class ReaderThemeChip extends StatelessWidget {
  const ReaderThemeChip({
    super.key,
    required this.theme,
    required this.isCurrent,
    required this.manageMode,
    required this.checked,
    required this.onTap,
    required this.onLongPress,
  });

  final ReaderTheme theme;
  final bool isCurrent;
  final bool manageMode;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final highlight = manageMode ? checked : isCurrent;
    return Material(
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(
          color: highlight ? colorScheme.primary : colorScheme.outlineVariant,
          width: highlight ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Color(theme.style.backgroundColor),
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
              ),
              const SizedBox(width: 8),
              Text(theme.name, style: Theme.of(context).textTheme.labelLarge),
              if (manageMode && theme.builtIn) ...<Widget>[
                const SizedBox(width: 4),
                Icon(
                  Icons.lock_outline_rounded,
                  size: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
              if (manageMode && checked) ...<Widget>[
                const SizedBox(width: 4),
                Icon(
                  Icons.check_circle_rounded,
                  size: 15,
                  color: colorScheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表布局「新建主题」chip
class ReaderThemeAddChip extends StatelessWidget {
  const ReaderThemeAddChip({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.add_rounded,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text('新建主题', style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}
