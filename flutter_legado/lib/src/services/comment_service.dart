import 'dart:convert';

import 'book_api.dart';

/// 段评数据模型（对应 Rust ChapterReview）
class Comment {
  final int id;
  final String bookUrl;
  final int chapterIndex;
  final int paragraphIndex;
  final String content;
  final String author;
  final int createdAt;
  final int likeCount;

  const Comment({
    required this.id,
    required this.bookUrl,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.content,
    required this.author,
    required this.createdAt,
    required this.likeCount,
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_url': bookUrl,
        'chapter_index': chapterIndex,
        'paragraph_index': paragraphIndex,
        'content': content,
        'author': author,
        'created_at': createdAt,
        'like_count': likeCount,
      };

  Comment copyWith({int? likeCount}) => Comment(
        id: id,
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        paragraphIndex: paragraphIndex,
        content: content,
        author: author,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
      );
}

/// 段评缓存键
class _CacheKey {
  final String bookUrl;
  final int chapterIndex;

  const _CacheKey(this.bookUrl, this.chapterIndex);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _CacheKey &&
          bookUrl == other.bookUrl &&
          chapterIndex == other.chapterIndex;

  @override
  int get hashCode => Object.hash(bookUrl, chapterIndex);
}

/// 段评数据服务
///
/// 提供段评的获取、发布、点赞、删除功能，
/// 内置内存缓存避免重复请求（参考 Kotlin 原版 CommentService）。
class CommentService {
  final BookApi _api;

  /// 章节评论缓存（按 bookUrl + chapterIndex 索引）
  final Map<_CacheKey, List<Comment>> _cache = {};

  /// 缓存过期时间（默认 5 分钟）
  final Duration cacheExpiry;

  /// 缓存时间戳记录
  final Map<_CacheKey, DateTime> _cacheTimestamps = {};

  CommentService(this._api, {this.cacheExpiry = const Duration(minutes: 5)});

  /// 获取指定章节的所有评论（带缓存）
  Future<List<Comment>> getComments(String bookUrl, int chapterIndex) async {
    final key = _CacheKey(bookUrl, chapterIndex);

    // 检查缓存是否有效
    if (_cache.containsKey(key)) {
      final timestamp = _cacheTimestamps[key];
      if (timestamp != null &&
          DateTime.now().difference(timestamp) < cacheExpiry) {
        return _cache[key]!;
      }
    }

    // 从 Rust FFI 获取数据
    final json = await _api.reviewGetByChapter(bookUrl, chapterIndex);
    final list = jsonDecode(json) as List<dynamic>;
    final comments = list
        .map((e) => Comment.fromJson(e as Map<String, dynamic>))
        .toList();

    // 写入缓存
    _cache[key] = comments;
    _cacheTimestamps[key] = DateTime.now();

    return comments;
  }

  /// 获取指定段落的评论（从章节缓存中过滤）
  Future<List<Comment>> getParagraphComments(
    String bookUrl,
    int chapterIndex,
    int paragraphIndex,
  ) async {
    final all = await getComments(bookUrl, chapterIndex);
    return all.where((c) => c.paragraphIndex == paragraphIndex).toList();
  }

  /// 获取章节中每个段落的评论数量映射
  Future<Map<int, int>> getParagraphCommentCounts(
    String bookUrl,
    int chapterIndex,
  ) async {
    final all = await getComments(bookUrl, chapterIndex);
    final counts = <int, int>{};
    for (final comment in all) {
      if (comment.paragraphIndex >= 0) {
        counts[comment.paragraphIndex] =
            (counts[comment.paragraphIndex] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// 发布评论
  Future<Comment> postComment(
    String bookUrl,
    int chapterIndex,
    int paragraphIndex,
    String content, {
    String author = 'user',
  }) async {
    final id = await _api.reviewAdd(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      paragraphIndex: paragraphIndex,
      content: content,
      author: author,
    );

    final comment = Comment(
      id: id,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      paragraphIndex: paragraphIndex,
      content: content,
      author: author,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      likeCount: 0,
    );

    // 更新缓存
    _invalidateCache(bookUrl, chapterIndex);

    return comment;
  }

  /// 点赞评论
  Future<void> likeComment(String bookUrl, int chapterIndex, int commentId) async {
    await _api.reviewLike(commentId);
    // 更新缓存中的点赞数
    _updateCacheLikeCount(bookUrl, chapterIndex, commentId, 1);
  }

  /// 删除评论（仅作者可删除）
  Future<void> deleteComment(String bookUrl, int chapterIndex, int commentId) async {
    await _api.reviewDelete(commentId);
    // 从缓存中移除
    _removeFromCache(bookUrl, chapterIndex, commentId);
  }

  /// 使指定章节的缓存失效
  void invalidateChapter(String bookUrl, int chapterIndex) {
    _invalidateCache(bookUrl, chapterIndex);
  }

  /// 清空所有缓存
  void clearCache() {
    _cache.clear();
    _cacheTimestamps.clear();
  }

  // ===== 私有方法 =====

  void _invalidateCache(String bookUrl, int chapterIndex) {
    final key = _CacheKey(bookUrl, chapterIndex);
    _cache.remove(key);
    _cacheTimestamps.remove(key);
  }

  void _updateCacheLikeCount(
    String bookUrl,
    int chapterIndex,
    int commentId,
    int delta,
  ) {
    final key = _CacheKey(bookUrl, chapterIndex);
    final comments = _cache[key];
    if (comments == null) return;
    final updated = comments.map((c) {
      if (c.id == commentId) {
        return c.copyWith(likeCount: c.likeCount + delta);
      }
      return c;
    }).toList();
    _cache[key] = updated;
  }

  void _removeFromCache(String bookUrl, int chapterIndex, int commentId) {
    final key = _CacheKey(bookUrl, chapterIndex);
    final comments = _cache[key];
    if (comments == null) return;
    _cache[key] = comments.where((c) => c.id != commentId).toList();
  }
}
