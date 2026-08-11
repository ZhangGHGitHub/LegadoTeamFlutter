import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../utils/book_open_utils.dart';
import '../widgets/loading_indicator.dart';

/// 离线缓存界面（对齐原版 CacheActivity）
///
/// 书架书籍的缓存状态列表：每项按原版 item_download.xml 三行布局
/// （书名 / 作者 / 「已缓存 N/总章节数」），右侧提供单本缓存下载
/// （播放/停止，对应原版 iv_download）与单本导出（对应原版 tv_export）；
/// 顶栏菜单提供全部缓存（download_all）、缓存当前章节之后
/// （download_after）、停止全部下载与下载队列入口。
///
/// 缓存章节数与任务状态 2s 轮询刷新（原版经 EventBus 实时刷新，
/// 重构版无事件总线，以轻量本地轮询等价实现，与队列页一致）。
///
/// [UI-fix v2.0.17 | 2026-08-11] 补齐 CacheActivity 对齐缺口：缓存管理
/// 独立页（书籍列表/缓存进度/单本导出入口）与缓存下载
/// （download_after/download_all），销记 bookshelf_screen TODO — Reasonix
class OfflineCacheScreen extends ConsumerStatefulWidget {
  const OfflineCacheScreen({super.key});

  @override
  ConsumerState<OfflineCacheScreen> createState() =>
      _OfflineCacheScreenState();
}

/// 缓存下载任务快照（camelCase 对齐 Rust CacheDownloadTask）
class _DownloadTask {
  final int taskId;
  final String bookUrl;
  final String status;
  final int total;
  final int completed;

  const _DownloadTask({
    required this.taskId,
    required this.bookUrl,
    required this.status,
    required this.total,
    required this.completed,
  });

  factory _DownloadTask.fromJson(Map<String, dynamic> json) => _DownloadTask(
        taskId: (json['taskId'] as num?)?.toInt() ?? 0,
        bookUrl: json['bookUrl'] as String? ?? '',
        status: json['status'] as String? ?? 'unknown',
        total: (json['total'] as num?)?.toInt() ?? 0,
        completed: (json['completed'] as num?)?.toInt() ?? 0,
      );

  bool get isRunning => status == 'running';
}

/// 书架书籍 + 缓存状态（对齐原版 CacheAdapter 的 cacheChapters 映射）
class _BookEntry {
  final Book book;

  /// 已缓存章节数（listCachedChapterUrls 快照）
  int cachedCount;

  /// 该书进行中的下载任务（无则 null）
  _DownloadTask? task;

  _BookEntry(this.book, this.cachedCount, this.task);
}

class _OfflineCacheScreenState extends ConsumerState<OfflineCacheScreen> {
  List<_BookEntry> _entries = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 2s 轮询（与队列页一致；原版经 EventBus 实时刷新）
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _refresh(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 加载书架书籍 + 每本缓存章节数 + 进行中任务
  Future<void> _refresh({bool silent = false}) async {
    try {
      final api = ref.read(bookApiProvider);
      final books = await api.getBooks();
      // 原版 initBookData 过滤音频书（音频书缓存走听书链路）
      final visible =
          books.where((b) => (b.bookType & BookType.audio) == 0).toList();

      // 任务快照：bookUrl → 进行中任务（对齐原版 CacheBook.cacheBookMap）
      final tasks = <String, _DownloadTask>{};
      try {
        final decoded = jsonDecode(await api.cacheDownloadList());
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final task = _DownloadTask.fromJson(item);
              if (task.isRunning) tasks[task.bookUrl] = task;
            }
          }
        }
      } catch (_) {
        // 任务表未初始化等场景静默降级（仅影响下载按钮状态）
      }

      final entries = <_BookEntry>[];
      for (final book in visible) {
        var cached = 0;
        try {
          cached = (await api.listCachedChapterUrls(book.bookUrl)).length;
        } catch (_) {
          // 单书缓存查询失败记 0，不阻断整页
        }
        entries.add(_BookEntry(book, cached, tasks[book.bookUrl]));
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (!silent) setState(() => _loading = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ===== 下载操作（对齐原版 CacheAdapter.registerListener / CacheActivity） =====

  /// 单本缓存下载：download_all（0..末章）或 download_after（当前章..末章）
  Future<void> _startBookCache(_BookEntry entry,
      {bool afterCurrent = false}) async {
    final book = entry.book;
    final total = book.totalChapterNum;
    if (total <= 0) {
      _snack('《${book.name}》章节数未知，无法缓存');
      return;
    }
    final start = afterCurrent ? book.durChapterIndex : 0;
    final end = total - 1;
    if (start > end) {
      _snack('《${book.name}》无可缓存的章节');
      return;
    }
    try {
      final api = ref.read(bookApiProvider);
      await api.cacheDownloadStart(book.bookUrl, start, end);
      _snack('《${book.name}》已加入缓存队列');
      _refresh(silent: true);
    } catch (e) {
      _snack('缓存启动失败：$e');
    }
  }

  /// 停止该书正在进行的下载
  Future<void> _stopBookCache(_BookEntry entry) async {
    final task = entry.task;
    if (task == null) return;
    try {
      await ref.read(bookApiProvider).cacheDownloadCancel(task.taskId);
      _snack('已停止《${entry.book.name}》下载');
      _refresh(silent: true);
    } catch (e) {
      _snack('停止失败：$e');
    }
  }

  /// 全部书籍批量缓存（对齐原版 startDownloadAll / startDownloadAfterCurrent）
  Future<void> _cacheAll({required bool afterCurrent}) async {
    final targets = _entries.where((e) => e.book.totalChapterNum > 0).toList();
    if (targets.isEmpty) {
      _snack('书架无可缓存的书籍');
      return;
    }
    // 原版 sureCacheBook 确认对话框
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(afterCurrent ? '缓存所有书籍当前章节之后' : '缓存所有书籍'),
        content: Text(
            '将缓存书架全部 ${targets.length} 本书${afterCurrent ? '（当前章节之后）' : ''}，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var started = 0;
    final api = ref.read(bookApiProvider);
    for (final e in targets) {
      final total = e.book.totalChapterNum;
      final start = afterCurrent ? e.book.durChapterIndex : 0;
      if (start > total - 1) continue;
      try {
        await api.cacheDownloadStart(e.book.bookUrl, start, total - 1);
        started++;
      } catch (_) {
        // 单本失败不阻断整体（原版 CacheBook.start 亦逐本尝试）
      }
    }
    _snack(started > 0 ? '已加入缓存队列：$started 本书' : '缓存启动失败');
    _refresh(silent: true);
  }

  /// 停止全部正在下载的任务
  Future<void> _stopAll() async {
    final running = _entries.where((e) => e.task != null).toList();
    if (running.isEmpty) {
      _snack('当前没有进行中的下载');
      return;
    }
    var stopped = 0;
    final api = ref.read(bookApiProvider);
    for (final e in running) {
      try {
        await api.cacheDownloadCancel(e.task!.taskId);
        stopped++;
      } catch (_) {
        // 单任务停止失败继续下一个
      }
    }
    _snack('已停止 $stopped 个下载任务');
    _refresh(silent: true);
  }

  // ===== 打开书籍（对齐原版 startActivityForBook：未读进书详，已读按类型分流） =====

  Future<void> _openBook(Book book) async {
    if (book.durChapterIndex <= 0 && book.durChapterPos <= 0) {
      await Navigator.pushNamed(context, AppRoutes.bookInfo, arguments: book);
      return;
    }
    // 与书架共用 BookOpenUtils，避免漫画/视频误进文本阅读器 — Reasonix + UI
    var typeBits = BookOpenUtils.typeBitsOf(book);
    if (BookOpenUtils.isOnlineBook(book)) {
      try {
        final sources = await ref.read(bookApiProvider).getBookSources();
        for (final s in sources) {
          if (s.bookSourceUrl == book.origin) {
            typeBits = BookOpenUtils.resolveTypeBits(typeBits, s);
            break;
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    final bookToOpen =
        typeBits != 0 ? book.copyWith(bookType: typeBits) : book;
    final route = BookOpenUtils.routeForTypeBits(typeBits);
    if (BookOpenUtils.needsReaderNotifier(route)) {
      ref.read(readerNotifierProvider.notifier).openBook(bookToOpen);
      await Navigator.pushNamed(context, route);
      return;
    }
    await Navigator.pushNamed(
      context,
      route,
      arguments: BookOpenUtils.argumentsForRoute(route, bookToOpen),
    );
  }

  // ===== 单本导出（对齐原版 CacheActivity 导出通道，原书架 _exportBookCache 迁移） =====

  /// 按章节顺序读取已缓存章节（cacheGetChapter），章节标题+正文拼 TXT，
  /// 文件名取书名，经分享通道保存（对齐原版 ExportBookService 单本导出语义）
  Future<void> _exportBook(Book book) async {
    final api = ref.read(bookApiProvider);
    final progress = ValueNotifier<String>('正在读取章节列表...');
    // 导出期间用户可能手动关闭进度对话框（系统返回键），
    // 以标志位防止 finally 里误 pop 页面本身（迁移自书架旧实现时顺手修复）
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (context, text, _) => AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    ).whenComplete(() => dialogOpen = false);

    final buffer = StringBuffer();
    var cached = 0;
    String? loadError;
    try {
      final chapters = await api.getChapters(book.bookUrl);
      for (var i = 0; i < chapters.length; i++) {
        progress.value = '正在读取缓存 ${i + 1}/${chapters.length}';
        String content;
        try {
          content = await api.getCachedChapter(book.bookUrl, i);
        } catch (e) {
          debugPrint('读取缓存失败《${book.name}》第 $i 章：$e');
          continue;
        }
        if (content.trim().isEmpty) continue; // 未缓存章节：跳过
        buffer.writeln(chapters[i].title);
        buffer.writeln();
        buffer.writeln(content.trim());
        buffer.writeln();
        cached++;
      }
    } catch (e) {
      loadError = '$e';
    } finally {
      if (mounted && dialogOpen) Navigator.pop(context); // 关闭进度对话框
      progress.dispose();
    }
    if (!mounted) return;
    if (loadError != null) {
      _snack('缓存导出失败：$loadError');
      return;
    }
    if (cached == 0) {
      _snack('《${book.name}》暂无已缓存章节');
      return;
    }
    final fileName =
        '${book.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.txt';
    await Share.shareXFiles([
      XFile.fromData(
        utf8.encode(buffer.toString()),
        name: fileName,
        mimeType: 'text/plain',
      ),
    ]);
    if (mounted) {
      _snack('已导出《${book.name}》$cached 章缓存');
    }
  }

  // ===== 顶栏菜单 =====

  void _handleMenu(String action) {
    switch (action) {
      case 'download_all':
        _cacheAll(afterCurrent: false);
      case 'download_after':
        _cacheAll(afterCurrent: true);
      case 'stop_all':
        _stopAll();
      case 'queue':
        Navigator.pushNamed(context, AppRoutes.cacheDownloads);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('离线缓存'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(),
          ),
          PopupMenuButton<String>(
            tooltip: '缓存操作',
            onSelected: _handleMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'download_all', child: Text('全部缓存')),
              PopupMenuItem(
                  value: 'download_after', child: Text('缓存当前章节之后')),
              PopupMenuItem(value: 'stop_all', child: Text('停止全部下载')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'queue', child: Text('下载队列')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const LoadingIndicator()
          : _entries.isEmpty
              ? _buildEmpty(cs)
              : RefreshIndicator(
                  onRefresh: () async => _refresh(),
                  child: ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: cs.outlineVariant.withValues(alpha: 0.3),
                    ),
                    itemBuilder: (context, index) =>
                        _buildTile(_entries[index]),
                  ),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 64, color: cs.outlineVariant),
          const SizedBox(height: 12),
          const Text('书架暂无书籍'),
          const SizedBox(height: 4),
          Text(
            '在书架添加书籍后，可在此缓存离线阅读',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// 列表项（对齐原版 item_download.xml 三行布局 + 下载/导出按钮）
  Widget _buildTile(_BookEntry entry) {
    final cs = Theme.of(context).colorScheme;
    final book = entry.book;
    final isLocal = book.bookType & BookType.local != 0;
    final total = book.totalChapterNum;
    // 进度行（原版 tv_download）：本地书显示「本地书籍」（原版 isLocal 短路），
    // 下载中显示任务进度，否则「已缓存 N/总章节数」（对齐原版 download_count）
    final String progressText;
    if (isLocal) {
      progressText = '本地书籍';
    } else if (entry.task != null) {
      progressText = '下载中 ${entry.task!.completed}/${entry.task!.total}';
    } else if (total > 0) {
      progressText = '已缓存 ${entry.cachedCount}/$total';
    } else {
      progressText = '已缓存 ${entry.cachedCount}';
    }
    return ListTile(
      onTap: () => _openBook(book),
      // 三行布局（书名/作者/进度），必须 isThreeLine 否则 subtitle 被钳到单行
      isThreeLine: true,
      title: Text(
        book.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            book.author.isEmpty ? '作者未知' : book.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            progressText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 原版 iv_download：播放/停止切换（本地书无缓存概念，隐藏）
          if (!isLocal)
            IconButton(
              tooltip: entry.task != null ? '停止下载' : '开始缓存',
              icon: Icon(
                entry.task != null
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                size: 28,
              ),
              color: entry.task != null ? cs.error : cs.primary,
              onPressed: () => entry.task != null
                  ? _stopBookCache(entry)
                  : _startBookCache(entry),
            ),
          // 原版 tv_export：单本导出
          TextButton(
            onPressed: () => _exportBook(book),
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }
}
