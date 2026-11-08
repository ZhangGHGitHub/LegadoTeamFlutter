// 封面相册管理页（设置批6b-2）
//
// 对齐参考版 `CoverAlbumManageScreen.kt:135-418`：
// - 空态：图标 + 「暂无封面相册」提示；
// - 相册卡片：预览图 / 名称 / 日间与夜间数量 / 「当前使用」标记；
// - 新建（顶栏 +）、重命名、删除（二次确认 + 目录清理）；
// - 点入图片管理 Sheet：日/夜 Tab、SAF 多选导入、单图删除、空态；
// - 「设为默认封面」写 CoverSettings.defaultAlbumId（Night 回落同相册）。
//
// 视觉沿用项目 IosGroup / IosListTile 分组行；大图统一 cacheWidth 缩略。
//
// 编写：全栈工程师（设置批6b-2） ｜ 2026-11-09
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../providers/cover_settings/cover_settings_notifier.dart';
import '../services/cover_album_image_picker.dart';
import '../services/cover_album_store.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/cover_album_preview.dart';
import '../widgets/empty_state.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/legado_app_bar.dart';

/// 封面相册管理页
class CoverAlbumManageScreen extends ConsumerStatefulWidget {
  const CoverAlbumManageScreen({super.key});

  @override
  ConsumerState<CoverAlbumManageScreen> createState() =>
      _CoverAlbumManageScreenState();
}

class _CoverAlbumManageScreenState
    extends ConsumerState<CoverAlbumManageScreen> {
  @override
  void initState() {
    super.initState();
    CoverAlbumStore.instance.ensureLoaded();
  }

  CoverAlbumStore get _store => CoverAlbumStore.instance;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _promptName({required String title, String initial = ''}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _AlbumNameDialog(title: title, initialName: initial),
    );
  }

  Future<void> _createAlbum() async {
    final name = await _promptName(title: '新建相册');
    if (name == null || !mounted) return;
    try {
      await _store.createAlbum(name);
      _showMessage('已创建相册「$name」');
    } on CoverAlbumException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('新建相册失败：$e');
    }
  }

  Future<void> _renameAlbum(CoverAlbum album) async {
    final name = await _promptName(title: '重命名相册', initial: album.name);
    if (name == null || name == album.name || !mounted) return;
    try {
      await _store.renameAlbum(album.id, name);
      _showMessage('已重命名为「$name」');
    } on CoverAlbumException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('重命名失败：$e');
    }
  }

  Future<void> _deleteAlbum(CoverAlbum album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除相册'),
        content: Text('确定删除相册「${album.name}」？相册内图片会一并删除。'),
        actions: [
          TextButton(
            key: const ValueKey('coverAlbumDeleteCancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('coverAlbumDeleteConfirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _store.deleteAlbum(album.id);
      // 删除的是当前默认相册：回落应用内置封面（夜间同 ID 一并清理）
      final settings = ref.read(coverSettingsProvider);
      if (settings.defaultAlbumId == album.id ||
          settings.defaultAlbumIdDark == album.id) {
        await ref
            .read(coverSettingsProvider.notifier)
            .update(
              (current) => current.copyWith(
                defaultAlbumId: current.defaultAlbumId == album.id
                    ? null
                    : current.defaultAlbumId,
                defaultAlbumIdDark: current.defaultAlbumIdDark == album.id
                    ? null
                    : current.defaultAlbumIdDark,
              ),
            );
      }
      _showMessage('已删除相册「${album.name}」');
    } on CoverAlbumException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('删除失败：$e');
    }
  }

  Future<void> _setDefaultAlbum(CoverAlbum album) async {
    try {
      await ref
          .read(coverSettingsProvider.notifier)
          .update(
            (current) => current.copyWith(
              defaultAlbumId: album.id,
              defaultAlbumIdDark: null,
            ),
          );
      _showMessage('已将「${album.name}」设为默认封面');
    } catch (e) {
      _showMessage('设置默认封面失败：$e');
    }
  }

  Future<void> _openEditor(CoverAlbum album) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => CoverAlbumEditorSheet(albumId: album.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      topBar: LegadoAppBar(
        title: const Text('封面相册'),
        actions: [
          IconButton(
            key: const ValueKey('coverAlbumCreateAction'),
            tooltip: '新建相册',
            icon: const Icon(Symbols.add_rounded),
            onPressed: _createAlbum,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _store.revision,
        builder: (context, _) {
          if (!_store.isLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final albums = _store.albums;
          if (albums.isEmpty) {
            return const EmptyState(
              key: ValueKey('coverAlbumEmpty'),
              icon: Symbols.collections_bookmark,
              title: '暂无封面相册',
              subtitle: '点击右上角新建相册，导入日间/夜间封面图',
            );
          }
          final settings = ref.watch(coverSettingsProvider);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              for (final album in albums)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AlbumCard(
                    album: album,
                    selected: settings.defaultAlbumId == album.id,
                    onTap: () => _openEditor(album),
                    onRename: () => _renameAlbum(album),
                    onDelete: () => _deleteAlbum(album),
                    onSetDefault: () => _setDefaultAlbum(album),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 相册名称输入对话框（自持 TextEditingController，随路由销毁释放）
class _AlbumNameDialog extends StatefulWidget {
  final String title;
  final String initialName;

  const _AlbumNameDialog({required this.title, required this.initialName});

  @override
  State<_AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<_AlbumNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('coverAlbumNameField'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(hintText: '相册名称'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          key: const ValueKey('coverAlbumNameCancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton(
            key: const ValueKey('coverAlbumNameConfirm'),
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('确定'),
          ),
        ),
      ],
    );
  }
}

/// 相册卡片（IosGroup 单行卡：预览/名称/日间夜间数量/当前标记/菜单）
class _AlbumCard extends StatelessWidget {
  final CoverAlbum album;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onSetDefault;

  const _AlbumCard({
    required this.album,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IosGroup(
      children: [
        IosListTile(
          key: ValueKey('coverAlbumTile_${album.id}'),
          leading: CoverAlbumPreview(path: album.previewPath),
          title: album.name,
          subtitle: '日间 ${album.lightCount} · 夜间 ${album.darkCount}',
          showChevron: false,
          onTap: onTap,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '当前使用',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                  ),
                ),
              PopupMenuButton<String>(
                key: ValueKey('coverAlbumMenu_${album.id}'),
                tooltip: '相册操作',
                icon: const Icon(Symbols.more_vert_rounded, size: 20),
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      onRename();
                    case 'delete':
                      onDelete();
                    case 'select':
                      onSetDefault();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    key: ValueKey('coverAlbumRename_${album.id}'),
                    value: 'rename',
                    child: const Text('重命名'),
                  ),
                  PopupMenuItem(
                    key: ValueKey('coverAlbumSelect_${album.id}'),
                    value: 'select',
                    child: Text(selected ? '当前默认封面' : '设为默认封面'),
                  ),
                  PopupMenuItem(
                    key: ValueKey('coverAlbumDelete_${album.id}'),
                    value: 'delete',
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 相册图片管理 Sheet（日/夜 Tab + 多选导入 + 单图删除）
class CoverAlbumEditorSheet extends ConsumerStatefulWidget {
  final String albumId;

  const CoverAlbumEditorSheet({super.key, required this.albumId});

  @override
  ConsumerState<CoverAlbumEditorSheet> createState() =>
      _CoverAlbumEditorSheetState();
}

class _CoverAlbumEditorSheetState extends ConsumerState<CoverAlbumEditorSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  bool _busy = false;

  /// [审查回修 P2-3] Sheet 高度 78% 会遮挡根 ScaffoldMessenger 的 SnackBar；
  /// 改用 Sheet 内状态行展示导入/删除结果与失败原因。
  String? _statusMessage;

  bool get _isDark => _tabs.index == 1;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
  }

  Future<void> _importImages() async {
    if (_busy) return;
    final isDark = _isDark;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    var imported = 0;
    var duplicates = 0;
    final failures = <String>[];
    try {
      // 惰性句柄：逐张 readBytes → import → 释放，避免整批字节常驻内存
      final batch = await CoverAlbumImagePicker.pickImages();
      for (final failure in batch.failures) {
        failures.add('${failure.name}：${failure.message}');
      }
      for (final pick in batch.picks) {
        Uint8List bytes;
        try {
          bytes = await pick.readBytes();
        } catch (e) {
          failures.add('${pick.name}：读取失败（$e）');
          continue;
        }
        final result = await CoverAlbumStore.instance.importImages(
          widget.albumId,
          isDark: isDark,
          inputs: [CoverAlbumImageInput(displayName: pick.name, bytes: bytes)],
        );
        imported += result.imported.length;
        duplicates += result.duplicateCount;
        for (final failure in result.failures) {
          failures.add('${failure.displayName}：${failure.message}');
        }
      }
      final parts = <String>[];
      if (imported > 0) parts.add('已导入 $imported 张');
      if (duplicates > 0) parts.add('$duplicates 张图片已存在，未重复导入');
      if (failures.isNotEmpty) {
        parts.add('${failures.length} 张跳过：${failures.first}');
      }
      if (parts.isNotEmpty) _showMessage(parts.join('；'));
    } on CoverAlbumImagePickerException catch (e) {
      _showMessage(e.message);
    } on CoverAlbumException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeImage(CoverAlbumImage image, bool isDark) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除图片'),
        content: const Text('确定从相册中删除这张图片吗？'),
        actions: [
          TextButton(
            key: const ValueKey('coverAlbumRemoveImageCancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('coverAlbumRemoveImageConfirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await CoverAlbumStore.instance.removeImage(
        widget.albumId,
        isDark: isDark,
        fileName: image.fileName,
      );
      // 删除成功后刷新状态行，避免残留上一次导入的文案
      _showMessage('已删除 1 张图片');
    } on CoverAlbumException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('删除图片失败：$e');
    }
  }

  Future<void> _setDefault(CoverAlbum album) async {
    await ref
        .read(coverSettingsProvider.notifier)
        .update(
          (current) => current.copyWith(
            defaultAlbumId: album.id,
            defaultAlbumIdDark: null,
          ),
        );
    if (mounted) _showMessage('已将「${album.name}」设为默认封面');
  }

  @override
  Widget build(BuildContext context) {
    final store = CoverAlbumStore.instance;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        store.revision,
        coverSettingsListenable,
      ]),
      builder: (context, _) {
        final album = store.albumById(widget.albumId);
        if (album == null) {
          return const SizedBox(
            height: 160,
            child: Center(child: Text('相册不存在或已删除')),
          );
        }
        final selected =
            coverSettingsListenable.value.defaultAlbumId == album.id;
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (selected)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '当前使用',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      )
                    else
                      TextButton(
                        key: const ValueKey('coverAlbumSetDefaultButton'),
                        onPressed: () => _setDefault(album),
                        child: const Text('设为默认封面'),
                      ),
                    IconButton(
                      key: const ValueKey('coverAlbumAddImages'),
                      tooltip: '导入图片',
                      icon: const Icon(Symbols.add_rounded),
                      onPressed: _busy ? null : _importImages,
                    ),
                  ],
                ),
              ),
              TabBar(
                controller: _tabs,
                // 全局 tabBarTheme.tabAlignment=start 仅可滚动 TabBar 合法；
                // 非 scrollable 必须显式 fill，否则 debug 断言 + 布局溢出
                //（先例 app_log_screen.dart:127 / toc_screen.dart:1070）。
                tabAlignment: TabAlignment.fill,
                tabs: const [
                  Tab(key: ValueKey('coverAlbumDayTab'), text: '日间'),
                  Tab(key: ValueKey('coverAlbumNightTab'), text: '夜间'),
                ],
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_statusMessage != null)
                Container(
                  key: const ValueKey('coverAlbumStatus'),
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    _statusMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _AlbumImageGrid(
                      images: album.lightImages,
                      isDark: false,
                      onRemove: _busy
                          ? null
                          : (image) => _removeImage(image, false),
                    ),
                    _AlbumImageGrid(
                      images: album.darkImages,
                      isDark: true,
                      onRemove: _busy
                          ? null
                          : (image) => _removeImage(image, true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 图片网格（空态 / 3 列 5:7 缩略图 + 右上角删除）
class _AlbumImageGrid extends StatelessWidget {
  final List<CoverAlbumImage> images;
  final bool isDark;

  /// null = 导入忙态，禁用单图删除（P2-1）
  final ValueChanged<CoverAlbumImage>? onRemove;

  const _AlbumImageGrid({
    required this.images,
    required this.isDark,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return Center(
        key: ValueKey('coverAlbumImagesEmpty_${isDark ? 'dark' : 'light'}'),
        child: Text(
          '暂无图片，点击右上角导入',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final devicePixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
    return GridView.builder(
      key: ValueKey('coverAlbumGrid_${isDark ? 'dark' : 'light'}'),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 5 / 7,
      ),
      itemCount: images.length,
      itemBuilder: (context, index) {
        final image = images[index];
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(image.path),
                fit: BoxFit.cover,
                cacheWidth: (120 * devicePixelRatio).round().clamp(1, 512),
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Symbols.broken_image_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: scheme.surface.withValues(alpha: 0.82),
                shape: const CircleBorder(),
                child: InkWell(
                  key: ValueKey('coverAlbumRemoveImage_${image.fileName}'),
                  customBorder: const CircleBorder(),
                  onTap: onRemove == null ? null : () => onRemove!(image),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Symbols.close_rounded,
                      size: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
