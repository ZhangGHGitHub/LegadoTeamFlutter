import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../widgets/empty_state.dart';
import '../widgets/loading_indicator.dart';

/// 文件管理页面
///
/// 对标 Android 原版 FileManageActivity（ui/file/FileManageActivity.kt）：
/// - 顶部横向路径面包屑（root + 子目录链，点击可回跳）
/// - 顶栏搜索框实时过滤当前目录文件名（queryHint「筛选 • 文件管理」）
/// - 文件列表：返回上级「..」+ 目录/文件项（图标区分）
/// - 点击目录进入；点击文件用系统方式打开（Flutter 侧以分享替代 openFileUri）
/// - 长按文件/目录弹出删除菜单（viewModel.delFile + 确认）
///
/// 根目录为应用沙盒文档目录（getApplicationDocumentsDirectory），
/// 对齐原版 rootDoc 的「应用可见文件」语义且不越出沙盒边界。
class FileManageScreen extends StatefulWidget {
  const FileManageScreen({super.key});

  @override
  State<FileManageScreen> createState() => _FileManageScreenState();
}

class _FileManageScreenState extends State<FileManageScreen> {
  final _searchCtrl = TextEditingController();
  String _filter = '';

  /// 根目录（沙盒文档目录）
  Directory? _rootDoc;

  /// 相对根目录的子目录链（面包屑）
  final List<Directory> _subDocs = [];

  List<FileSystemEntity> _files = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _filter = _searchCtrl.text.trim().toLowerCase());
    });
    _initRoot();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 当前目录（子目录链末端，空链时为根目录）
  Directory get _currentDir =>
      _subDocs.isNotEmpty ? _subDocs.last : _rootDoc!;

  Future<void> _initRoot() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _rootDoc = dir);
      await _upFiles();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 加载当前目录内容（目录优先，名称升序；对标原版排序行为）
  Future<void> _upFiles() async {
    setState(() => _loading = true);
    try {
      final entries = await _currentDir.list().toList();
      entries.sort((a, b) {
        final aDir = FileSystemEntity.isDirectorySync(a.path);
        final bDir = FileSystemEntity.isDirectorySync(b.path);
        if (aDir != bDir) return aDir ? -1 : 1;
        return _baseName(a.path)
            .toLowerCase()
            .compareTo(_baseName(b.path).toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _files = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _baseName(String path) => path.split(Platform.pathSeparator).last;

  /// 过滤后的列表（对标 updateFiles：搜索时保留「..」与匹配项）
  List<FileSystemEntity> get _filteredFiles => _filter.isEmpty
      ? _files
      : _files.where((f) {
          final name = _baseName(f.path);
          return name.toLowerCase().contains(_filter);
        }).toList();

  /// 返回上级目录（对标 gotoLastDir）
  void _gotoLastDir() {
    if (_subDocs.isEmpty) return;
    setState(() => _subDocs.removeLast());
    _upFiles();
  }

  /// 面包屑跳转到指定层级（对标 PathAdapter 点击：截断到该层）
  void _gotoBreadcrumb(int index) {
    if (index < 0) {
      // root
      setState(() => _subDocs.clear());
    } else {
      setState(() => _subDocs.removeRange(index + 1, _subDocs.length));
    }
    _upFiles();
  }

  Future<void> _openFile(File file) async {
    // 原版用 openFileUri 打开文件；Flutter 跨平台以系统分享面板替代
    try {
      await Share.shareXFiles([XFile(file.path)]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开文件: $e')),
      );
    }
  }

  /// 长按删除菜单（对标 popupActionMenu「删除」danger）
  Future<void> _showFileMenu(FileSystemEntity entity) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(
                '删除',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action != 'delete') return;
    await _confirmDelete(entity);
  }

  Future<void> _confirmDelete(FileSystemEntity entity) async {
    final name = _baseName(entity.path);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除「$name」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await entity.delete(recursive: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
      return;
    }
    await _upFiles();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      // 根目录时允许直接退出；子目录时拦截并回上级
      canPop: _subDocs.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _gotoLastDir();
      },
      child: Scaffold(
        appBar: LegadoAppBar(
          title: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              // 对标原版 queryHint：筛选 • 文件管理
              hintText: '筛选 · 文件管理',
              filled: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _filter.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => _searchCtrl.clear(),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        body: Builder(builder: (context) {
          if (_rootDoc == null && _error == null) {
            return const LoadingIndicator(message: '加载文件...');
          }
          if (_error != null) {
            return Center(child: Text('加载失败: $_error'));
          }
          return Column(
            children: [
              _buildBreadcrumb(context),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const LoadingIndicator()
                    : _buildFileList(context),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// 路径面包屑（对标 rvPath 横向 RecyclerView：root + 子目录链）
  Widget _buildBreadcrumb(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _subDocs.length + 1,
        separatorBuilder: (_, _) => Icon(Icons.chevron_right,
            size: 18, color: cs.onSurfaceVariant),
        itemBuilder: (context, index) {
          final label = index == 0
              ? 'root'
              : _baseName(_subDocs[index - 1].path);
          return Center(
            child: InkWell(
              onTap: () => _gotoBreadcrumb(index == 0 ? -1 : index - 1),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.primary,
                      ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFileList(BuildContext context) {
    final files = _filteredFiles;
    final cs = Theme.of(context).colorScheme;
    final atRoot = _subDocs.isEmpty;

    if (files.isEmpty && atRoot) {
      return const EmptyState(
        icon: Icons.folder_outlined,
        title: '当前目录为空',
        simple: true,
      );
    }

    return ListView.separated(
      itemCount: files.length + (atRoot ? 0 : 1),
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        // 非根目录首项为「..」（对标 dirParent 项）
        if (!atRoot && index == 0) {
          return ListTile(
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: const Text('..'),
            onTap: _gotoLastDir,
          );
        }
        final entity = files[atRoot ? index : index - 1];
        final isDir = FileSystemEntity.isDirectorySync(entity.path);
        final name = _baseName(entity.path);
        return ListTile(
          leading: Icon(
            isDir ? Icons.folder : Icons.insert_drive_file_outlined,
            color: isDir ? cs.primary : cs.onSurfaceVariant,
          ),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: isDir
              ? null
              : Text(
                  _formatSize(entity),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
          onTap: () {
            if (isDir) {
              setState(() => _subDocs.add(Directory(entity.path)));
              _upFiles();
            } else {
              _openFile(File(entity.path));
            }
          },
          onLongPress: () => _showFileMenu(entity),
        );
      },
    );
  }

  String _formatSize(FileSystemEntity entity) {
    try {
      final size = File(entity.path).lengthSync();
      if (size < 1024) return '$size B';
      if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }
}
