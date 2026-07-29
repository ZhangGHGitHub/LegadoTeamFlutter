import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/rust_api.dart';

/// 段评弹窗（参考 Kotlin 原版 ReviewColumn + onReviewClick）
///
/// 显示指定章节的评论列表，支持：
/// - 查看评论（按点赞数排序）
/// - 添加新评论
/// - 点赞评论
/// - 删除评论
class ParagraphCommentDialog extends StatefulWidget {
  final RustApi api;
  final String bookUrl;
  final int chapterIndex;
  final String chapterTitle;

  /// 段落索引（-1 表示章节级评论，>=0 表示指定段落的评论）
  final int paragraphIndex;

  const ParagraphCommentDialog({
    super.key,
    required this.api,
    required this.bookUrl,
    required this.chapterIndex,
    required this.chapterTitle,
    this.paragraphIndex = -1,
  });

  @override
  State<ParagraphCommentDialog> createState() => _ParagraphCommentDialogState();
}

class _ParagraphCommentDialogState extends State<ParagraphCommentDialog> {
  List<_ReviewItem> _reviews = [];
  bool _loading = true;
  String? _error;
  final _inputController = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadReviews();
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _loadReviews() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.api.reviewGetByChapter(
        widget.bookUrl,
        widget.chapterIndex,
      );
      final list = jsonDecode(json) as List<dynamic>;
      var reviews = list
          .map((e) => _ReviewItem.fromJson(e as Map<String, dynamic>))
          .toList();
      // 按段落索引过滤（paragraphIndex >= 0 时仅显示该段落的评论）
      if (widget.paragraphIndex >= 0) {
        reviews = reviews
            .where((r) => r.paragraphIndex == widget.paragraphIndex)
            .toList();
      }
      // 按点赞数降序排列
      reviews.sort((a, b) => b.likeCount.compareTo(a.likeCount));
      _reviews = reviews;
    } catch (e) {
      _error = e.toString();
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _submitReview() async {
    final content = _inputController.text.trim();
    if (content.isEmpty) return;

    setState(() => _submitting = true);
    try {
      await widget.api.reviewAdd(
        bookUrl: widget.bookUrl,
        chapterIndex: widget.chapterIndex,
        paragraphIndex: widget.paragraphIndex,
        content: content,
        author: 'user',
      );
      _inputController.clear();
      await _loadReviews();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('评论失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _likeReview(int id) async {
    try {
      await widget.api.reviewLike(id);
      await _loadReviews();
    } catch (_) {}
  }

  Future<void> _deleteReview(int id) async {
    try {
      await widget.api.reviewDelete(id);
      await _loadReviews();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.paragraphIndex >= 0
                        ? '${widget.chapterTitle} · 第${widget.paragraphIndex + 1}段评论'
                        : '${widget.chapterTitle} · 评论',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${_reviews.length} 条',
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _loadReviews,
                  tooltip: '刷新',
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 评论列表
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                size: 48, color: Colors.grey),
                            const SizedBox(height: 8),
                            Text('加载失败',
                                style: theme.textTheme.bodyMedium),
                            TextButton(
                              onPressed: _loadReviews,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : _reviews.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.chat_bubble_outline,
                                    size: 48, color: Colors.grey[400]),
                                const SizedBox(height: 8),
                                Text('暂无评论',
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(color: Colors.grey)),
                                const SizedBox(height: 4),
                                Text('来写第一条评论吧',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: Colors.grey)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            itemCount: _reviews.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, index) {
                              final review = _reviews[index];
                              return _buildReviewItem(context, review, theme);
                            },
                          ),
          ),

          // 输入栏
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border(
                top: BorderSide(color: theme.dividerColor),
              ),
            ),
            padding: EdgeInsets.only(
              left: 12,
              right: 4,
              top: 8,
              bottom: MediaQuery.of(context).padding.bottom + 8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: InputDecoration(
                      hintText: '写评论...',
                      hintStyle: TextStyle(color: Colors.grey[500]),
                      filled: true,
                      fillColor: theme.colorScheme.surface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      isDense: true,
                    ),
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submitReview(),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: _submitting ? null : _submitReview,
                  tooltip: '发送',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewItem(
      BuildContext context, _ReviewItem review, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像占位
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              review.author.isNotEmpty ? review.author[0].toUpperCase() : 'U',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 内容
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 用户名
                Text(
                  review.author.isEmpty ? '匿名' : review.author,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),

                // 评论内容
                Text(
                  review.content,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),

                // 操作栏
                Row(
                  children: [
                    // 时间
                    Text(
                      _formatTime(review.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),

                    // 点赞
                    InkWell(
                      onTap: () => _likeReview(review.id),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.thumb_up_outlined,
                                size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 2),
                            Text(
                              '${review.likeCount}',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 删除
                    InkWell(
                      onTap: () => _confirmDelete(context, review.id),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.delete_outline,
                            size: 14, color: Colors.grey[500]),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, int id) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('确定删除这条评论吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteReview(id);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  String _formatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

/// 评论数据模型（对应 Rust ChapterReview）
class _ReviewItem {
  final int id;
  final String bookUrl;
  final int chapterIndex;
  final int paragraphIndex;
  final String content;
  final String author;
  final int createdAt;
  final int likeCount;

  _ReviewItem({
    required this.id,
    required this.bookUrl,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.content,
    required this.author,
    required this.createdAt,
    required this.likeCount,
  });

  factory _ReviewItem.fromJson(Map<String, dynamic> json) {
    return _ReviewItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      bookUrl: json['book_url'] as String? ?? '',
      chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
      paragraphIndex: (json['paragraph_index'] as num?)?.toInt() ?? -1,
      content: json['content'] as String? ?? '',
      author: json['author'] as String? ?? '',
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 显示段评弹窗的便捷方法
Future<void> showParagraphCommentDialog(
  BuildContext context, {
  required RustApi api,
  required String bookUrl,
  required int chapterIndex,
  required String chapterTitle,
  int paragraphIndex = -1,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => ParagraphCommentDialog(
      api: api,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      paragraphIndex: paragraphIndex,
    ),
  );
}
