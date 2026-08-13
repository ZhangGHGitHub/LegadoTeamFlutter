import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';

import '../l10n/app_strings.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_indicator.dart';
import 'archive_import_dialog.dart';

/// 支持的导入格式（azw3/azw 为 KF8 MOBI，Rust LocalBook 已支持）
const _supportedFormats = ['epub', 'txt', 'mobi', 'azw3', 'azw', 'pdf', 'umd'];

/// 支持的压缩包格式
const _archiveFormats = ['zip', 'rar', '7z'];

/// 所有可浏览格式（书籍 + 压缩包）
const _allBrowsableFormats = [..._supportedFormats, ..._archiveFormats];

/// 单个文件的导入结果
class _ImportOutcome {
  final String name;
  final bool success;
  final bool skipped;
  final String? error;

  const _ImportOutcome({
    required this.name,
    required this.success,
    this.skipped = false,
    this.error,
  });
}

/// 本地书籍导入页面 — 文件浏览器模式
///
/// 提供目录导航、格式过滤、批量选择、导入进度与结果统计。
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  /// 可选的存储根目录（Android 可能有多个）
  List<Directory> _roots = [];

  Directory? _currentDir;
  List<Directory> _dirs = [];
  List<File> _files = [];
  bool _loading = true;
  String? _error;

  /// 启用的格式过滤集合
  final Set<String> _activeFormats = {..._allBrowsableFormats};

  /// 已选中的文件路径
  final Set<String> _selected = {};

  /// 导入状态
  bool _importing = false;
  int _importDone = 0;
  int _importTotal = 0;
  final List<_ImportOutcome> _outcomes = [];
  bool _showResult = false;

  @override
  void initState() {
    super.initState();
    _initRoots();
  }

  Future<void> _initRoots() async {
    try {
      final roots = <Directory>[];
      final docs = await getApplicationDocumentsDirectory();
      roots.add(docs);
      // Android 外置存储（可能为 null）
      final external = await getExternalStorageDirectory();
      if (external != null && external.path != docs.path) {
        roots.add(external);
      }
      if (!mounted) return;
      setState(() => _roots = roots);
      if (roots.length == 1) {
        await _enterDir(roots.first);
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _enterDir(Directory dir) async {
    setState(() {
      _currentDir = dir;
      _loading = true;
      _error = null;
    });
    try {
      final dirs = <Directory>[];
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          final name = entity.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .lastOrNull;
          // 跳过隐藏目录
          if (name != null && !name.startsWith('.')) {
            dirs.add(entity);
          }
        } else if (entity is File) {
          final ext = _extOf(entity.path);
          if (_allBrowsableFormats.contains(ext)) {
            files.add(entity);
          }
        }
      }
      dirs.sort((a, b) => _displayName(a.path).compareTo(_displayName(b.path)));
      files.sort((a, b) => _displayName(a.path).compareTo(_displayName(b.path)));
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '';
    return path.substring(i + 1).toLowerCase();
  }

  String _displayName(String path) {
    final segments = path.split(Platform.pathSeparator);
    return segments.where((s) => s.isNotEmpty).lastOrNull ?? path;
  }

  /// 当前过滤条件下可见的文件
  List<File> get _visibleFiles => _activeFormats.length == _allBrowsableFormats.length
      ? _files
      : _files.where((f) => _activeFormats.contains(_extOf(f.path))).toList();

  bool get _allVisibleSelected {
    final visible = _visibleFiles;
    return visible.isNotEmpty && visible.every((f) => _selected.contains(f.path));
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        for (final f in _visibleFiles) {
          _selected.remove(f.path);
        }
      } else {
        for (final f in _visibleFiles) {
          _selected.add(f.path);
        }
      }
    });
  }

  void _goUp() {
    final current = _currentDir;
    if (current == null) return;
    final parent = current.parent;
    // 已到达某个根目录，返回根选择
    if (_roots.any((r) => r.path == current.path)) {
      if (_roots.length > 1) {
        setState(() {
          _currentDir = null;
          _loading = false;
        });
      }
      return;
    }
    _enterDir(parent);
  }

  /// 判断文件是否已在书架（视为跳过）
  bool _isAlreadyImported(String path, BookshelfState state) {
    return state.books.any(
      (b) => b.bookUrl == path || b.originName == path,
    );
  }

  Future<void> _startImport() async {
    if (_selected.isEmpty || _importing) return;
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
    final paths = _selected.toList()..sort();

    setState(() {
      _importing = true;
      _importDone = 0;
      _importTotal = paths.length;
      _outcomes.clear();
      _showResult = false;
    });

    for (final path in paths) {
      final name = _displayName(path);
      // 逐次读取最新书架状态（导入会增量更新 state.books）
      if (_isAlreadyImported(path, ref.read(bookshelfNotifierProvider))) {
        _outcomes.add(_ImportOutcome(name: name, success: false, skipped: true));
      } else {
        try {
          await notifier.importLocalBook(path);
          _outcomes.add(_ImportOutcome(name: name, success: true));
        } catch (e) {
          _outcomes.add(_ImportOutcome(name: name, success: false, error: e.toString()));
        }
      }
      if (mounted) {
        setState(() => _importDone++);
      }
    }

    // 刷新书架确保与后端一致
    await notifier.refresh();

    if (mounted) {
      setState(() {
        _importing = false;
        _showResult = true;
        _selected.clear();
      });
    }
  }

  int get _successCount => _outcomes.where((o) => o.success).length;
  int get _failCount => _outcomes.where((o) => !o.success && !o.skipped).length;
  int get _skipCount => _outcomes.where((o) => o.skipped).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildFormatFilter(),
          if (_currentDir != null) _buildBreadcrumb(),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return LegadoAppBar(
      title: Text(AppStrings.addLocalBook),
      leading: _currentDir == null
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_upward),
              onPressed: _goUp,
            ),
      actions: [
        // 远程书籍导入入口（对标原版 RemoteBookActivity）
        IconButton(
          icon: const Icon(Icons.link),
          tooltip: '远程导入',
          onPressed: () =>
              Navigator.pushNamed(context, AppRoutes.remoteBooks),
        ),
        if (_currentDir != null)
          IconButton(
            icon: Icon(
              _allVisibleSelected ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            tooltip: '全选',
            onPressed: _visibleFiles.isEmpty ? null : _toggleSelectAll,
          ),
      ],
    );
  }

  /// 格式过滤条
  Widget _buildFormatFilter() {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final fmt in _allBrowsableFormats)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text('.${fmt.toUpperCase()}'),
                selected: _activeFormats.contains(fmt),
                onSelected: (on) {
                  setState(() {
                    if (on) {
                      _activeFormats.add(fmt);
                    } else {
                      _activeFormats.remove(fmt);
                    }
                  });
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 当前路径面包屑
  Widget _buildBreadcrumb() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: [
          Icon(Icons.folder_open, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _currentDir!.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingIndicator(message: '扫描文件...');
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: AppStrings.error,
        subtitle: _error,
        action: FilledButton(
          onPressed: () => _currentDir == null ? _initRoots() : _enterDir(_currentDir!),
          child: Text(AppStrings.retry),
        ),
      );
    }
    // 根目录选择
    if (_currentDir == null) {
      return _buildRootPicker();
    }
    if (_dirs.isEmpty && _visibleFiles.isEmpty) {
      return EmptyState(
        icon: Icons.folder_off,
        title: '当前目录没有可导入的书籍',
        subtitle: '切换格式过滤或返回上级目录',
      );
    }
    return ListView(
      children: [
        for (final dir in _dirs) _buildDirTile(dir),
        for (final file in _visibleFiles) _buildFileTile(file),
      ],
    );
  }

  Widget _buildRootPicker() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('选择存储目录', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final root in _roots)
          Card(
            child: ListTile(
              leading: const Icon(Icons.storage),
              title: Text(_displayName(root.path)),
              subtitle: Text(root.path, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _enterDir(root),
            ),
          ),
      ],
    );
  }

  Widget _buildDirTile(Directory dir) {
    return ListTile(
      leading: Icon(Icons.folder, color: Theme.of(context).colorScheme.primary),
      title: Text(_displayName(dir.path)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _enterDir(dir),
    );
  }

  Widget _buildFileTile(File file) {
    final path = file.path;
    final ext = _extOf(path);
    final isArchive = _archiveFormats.contains(ext);
    // 压缩包文件：点击直接打开压缩包导入对话框，不用 Checkbox 选择
    if (isArchive) {
      return FutureBuilder<FileStat>(
        future: file.stat(),
        builder: (context, snap) {
          final size = snap.data?.size ?? 0;
          return ListTile(
            leading: Icon(Icons.folder_zip, color: Theme.of(context).colorScheme.secondary),
            title: Text(
              _displayName(path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${ext.toUpperCase()} · ${_formatSize(size)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openArchiveImport(path),
          );
        },
      );
    }
    // 普通书籍文件：原有 Checkbox 多选逻辑
    final selected = _selected.contains(path);
    return FutureBuilder<FileStat>(
      future: file.stat(),
      builder: (context, snap) {
        final size = snap.data?.size ?? 0;
        return ListTile(
          leading: Checkbox(
            value: selected,
            onChanged: (_) => _toggleFile(path),
          ),
          title: Text(
            _displayName(path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          subtitle: Text('${ext.toUpperCase()} · ${_formatSize(size)}'),
          trailing: Icon(_iconForFormat(ext), size: 20),
          onTap: () => _toggleFile(path),
        );
      },
    );
  }

  /// 打开压缩包导入对话框
  ///
  /// 先通过 FFI 确认文件是压缩包格式，然后弹出 ArchiveImportDialog。
  Future<void> _openArchiveImport(String path) async {
    // 经 BookApi（Riverpod 注入层）确认是否为压缩包
    try {
      final isArchive =
          await ref.read(bookApiProvider).archiveIsArchive(filePath: path);
      if (!isArchive) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该文件不是有效的压缩包格式')),
          );
        }
        return;
      }
    } catch (_) {
      // FFI 调用失败时仍然尝试打开（可能是扩展名匹配但 FFI 未初始化）
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => ArchiveImportDialog(archivePath: path),
    );
  }

  void _toggleFile(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  IconData _iconForFormat(String ext) {
    switch (ext) {
      case 'epub':
        return Icons.menu_book;
      case 'txt':
        return Icons.description;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'mobi':
      case 'azw3':
        return Icons.auto_stories;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _buildBottomBar() {
    if (_showResult) return _buildResultBar();
    if (_importing) return _buildProgressBar();
    return _buildActionBar();
  }

  Widget _buildActionBar() {
    final count = _selected.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          onPressed: count == 0 ? null : _startImport,
          icon: const Icon(Icons.file_download),
          label: Text(count == 0 ? '未选择书籍' : '放入书架 ($count)'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    final progress = _importTotal == 0 ? 0.0 : _importDone / _importTotal;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('正在导入 $_importDone / $_importTotal ...'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
        ),
      ),
    );
  }

  Widget _buildResultBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _resultStat('成功', '$_successCount', colorScheme.primary),
                _resultStat('失败', '$_failCount', colorScheme.error),
                _resultStat('跳过', '$_skipCount', colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 12),
            if (_failCount > 0)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in _outcomes.where((o) => !o.success && !o.skipped))
                      Text(
                        '× ${o.name}',
                        style: TextStyle(color: colorScheme.error, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => setState(() => _showResult = false),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
