import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/change_cover/change_cover_notifier.dart';
import '../services/container_image_picker.dart';
import '../utils/cover_local_path.dart';
import '../widgets/book_cover.dart';

/// 更换封面页面
///
/// 展示当前封面，支持从网络搜索候选封面或从本地选择图片，
/// 预览确认后通过 [Navigator.pop] 返回所选封面地址。
class ChangeCoverScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容）
  final String bookUrl;

  /// 书名（向后兼容）
  final String bookName;

  /// 当前封面（向后兼容）
  final String? currentCover;

  const ChangeCoverScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
    this.currentCover,
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  /// 获取有效的作者（设置批6b-1：默认封面绘制作者）
  String get effectiveBookAuthor => book?.author ?? '';

  /// 获取有效的当前封面
  String? get effectiveCurrentCover =>
      book != null ? (book!.customCoverUrl ?? book!.coverUrl) : currentCover;

  @override
  ConsumerState<ChangeCoverScreen> createState() => _ChangeCoverScreenState();
}

class _ChangeCoverScreenState extends ConsumerState<ChangeCoverScreen> {
  final _searchController = TextEditingController();
  String? _selectedUrl;

  @override
  void initState() {
    super.initState();
    _searchController.text = widget.effectiveBookName;
    // 进入页面即按书名搜索一次候选封面
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchCovers());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 触发网络封面搜索（委托 [ChangeCoverNotifier]，候选数据流经 Riverpod 状态）
  void _searchCovers() {
    ref
        .read(changeCoverNotifierProvider.notifier)
        .searchCovers(_searchController.text);
  }

  /// 从本地相册 / 文件选择封面
  ///
  /// [设备回归 P2-2] Android 改走 SAF（ContainerImagePicker），只读字节、
  /// 不经过 file_picker 的 Bitmap.compress 路径（陈旧缩略图 NPE/FATAL）；
  /// 选中后复制到应用支持目录 `custom_covers/`，DB 只保存稳定绝对路径。
  /// iOS/桌面仍由 ContainerImagePicker 内部走 file_picker（allowCompression
  /// = false）。
  Future<void> _pickLocal() async {
    try {
      final pick = await ContainerImagePicker.pick(
        dialogTitle: '选择封面图片',
      );
      if (pick == null || !mounted) return;
      final path = await _storePickedCover(pick);
      if (!mounted) return;
      if (path == null) {
        _showToast('保存封面失败，请重试');
        return;
      }
      setState(() => _selectedUrl = path);
      _showToast('已选择本地图片，点击底部按钮确认');
    } on ContainerImagePickException catch (e) {
      if (mounted) _showToast(e.message);
    } catch (e) {
      debugPrint('ChangeCoverScreen._pickLocal 异常: $e');
      if (mounted) _showToast('选择封面失败，请重试');
    }
  }

  /// 写入应用支持目录 `custom_covers/cover_<book 哈希>.<ext>`
  ///
  /// 固定文件名避免重复选择累积垃圾文件；覆盖写（writeAsBytes 截断）。
  /// 返回绝对路径；IO 异常返回 null（调用方 toast，不崩溃）。
  Future<String?> _storePickedCover(ContainerImagePick pick) async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}custom_covers',
      );
      await dir.create(recursive: true);
      final key = widget.effectiveBookUrl.isNotEmpty
          ? widget.effectiveBookUrl
          : widget.effectiveBookName;
      final digest =
          sha1.convert(utf8.encode(key)).toString().substring(0, 16);
      final file = File(
        '${dir.path}${Platform.pathSeparator}cover_$digest'
        '${_coverExtension(pick.name)}',
      );
      await file.writeAsBytes(pick.bytes, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('ChangeCoverScreen._storePickedCover 异常: $e');
      return null;
    }
  }

  static String _coverExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '.jpg';
    final ext = name.substring(dot).toLowerCase();
    const allowed = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
    return allowed.contains(ext) ? ext : '.jpg';
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  void _confirm() {
    if (_selectedUrl == null) return;
    Navigator.pop(context, _selectedUrl);
  }

  Widget _coverImage(String url, {double? width, double? height}) {
    final localPath = localCoverFilePath(url);
    if (localPath != null) {
      return Image.file(
        File(localPath),
        width: width,
        height: height,
        fit: BoxFit.cover,
        // [LAYOUT_PLAN P4] 补 heroTag（book-cover: + bookUrl，与详情页同 tag）
        errorBuilder: (_, _, _) => BookCover(
          bookName: widget.effectiveBookName,
          bookAuthor: widget.effectiveBookAuthor,
          width: 240,
          height: 320,
          heroTag: 'book-cover:${widget.effectiveBookUrl}',
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      // 限制解码宽度为实际显示像素宽度（候选网格约 120），避免大图解码
      memCacheWidth: ((width ?? 120) *
              (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0))
          .round(),
      errorWidget: (_, _, _) => BookCover(
        bookName: widget.effectiveBookName,
        bookAuthor: widget.effectiveBookAuthor,
        // [LAYOUT_PLAN P4] 补 heroTag（book-cover: + bookUrl，与详情页同 tag）
        width: 240,
        height: 320,
        heroTag: 'book-cover:${widget.effectiveBookUrl}',
      ),
      placeholder: (_, _) => Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final coverState = ref.watch(changeCoverNotifierProvider);
    final previewUrl = _selectedUrl ?? widget.effectiveCurrentCover;

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: const Text('更换封面'),
        actions: [
          // 顶栏统一 36dp 图标槽位（TopBarActionStyler），带文字按钮会超出槽位
          // 造成右溢：与其它屏一致用 IconButton，「本地」语义保留在 tooltip
          IconButton(
            tooltip: '本地',
            icon: const Icon(Symbols.photo_library_rounded),
            onPressed: _pickLocal,
          ),
        ],
      ),
      bottomBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            icon: const Icon(Symbols.check_rounded),
            label: const Text('使用该封面'),
            onPressed: _selectedUrl == null ? null : _confirm,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: colorScheme.primary,
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // [LAYOUT_PLAN P1] 预览区进 Card 分组（卡内 16dp）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _buildPreviewBody(theme, previewUrl),
              ),
            ),
          ),
          _buildSearchBar(theme, coverState),
          _buildSectionHeader(theme, '网络封面'),
          _buildCandidateGrid(theme, coverState),
        ],
      ),
    );
  }

  Widget _buildPreviewBody(ThemeData theme, String? previewUrl) {
    final colorScheme = theme.colorScheme;
    final isSelected = _selectedUrl != null;
    return Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
            child: (previewUrl != null && previewUrl.isNotEmpty)
                ? _coverImage(previewUrl, width: 120, height: 160)
                // [LAYOUT_PLAN P4] 补 heroTag（book-cover: + bookUrl，与详情页同 tag）
                : BookCover(
                    bookName: widget.effectiveBookName,
                    bookAuthor: widget.effectiveBookAuthor,
                    width: 120,
                    height: 160,
                    heroTag: 'book-cover:${widget.effectiveBookUrl}',
                  ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.effectiveBookName.isEmpty ? '未命名书籍' : widget.effectiveBookName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isSelected ? '已选择新封面' : '当前封面',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isSelected
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '从下方选择网络封面，或点击右上角「本地」从相册选取。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
  }

  Widget _buildSearchBar(ThemeData theme, ChangeCoverState coverState) {
    final colorScheme = theme.colorScheme;
    // [LAYOUT_PLAN P1] 搜索框走 SearchBar 标准（32dp + surfaceContainerLow）
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: SearchBar(
        controller: _searchController,
        hintText: '输入书名搜索封面',
        constraints: const BoxConstraints(minHeight: 40),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(
          colorScheme.surfaceContainerLow,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        leading: Icon(
          Symbols.search_rounded,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
        trailing: [
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            onPressed: coverState.isSearching ? null : _searchCovers,
          ),
        ],
        onSubmitted: (_) => _searchCovers(),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildCandidateGrid(ThemeData theme, ChangeCoverState coverState) {
    if (coverState.isSearching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (coverState.candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            '暂无候选封面',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          mainAxisExtent: 160,
          // [LAYOUT_PLAN P1] 网格间距统一 8dp（全局标尺）
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: coverState.candidates.length,
        itemBuilder: (context, index) {
          final url = coverState.candidates[index].url;
          final selected = url == _selectedUrl;
          return _CandidateTile(
            url: url,
            selected: selected,
            image: _coverImage(url),
            onTap: () => setState(() => _selectedUrl = url),
          );
        },
      ),
    );
  }
}

/// 候选封面格子
class _CandidateTile extends StatelessWidget {
  final String url;
  final bool selected;
  final Widget image;
  final VoidCallback onTap;

  const _CandidateTile({
    required this.url,
    required this.selected,
    required this.image,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          width: selected ? 3 : 1,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(selected ? 9 : 11),
            child: image,
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
            ),
          ),
          if (selected)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Symbols.check_rounded,
                  size: 16,
                  color: colorScheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
