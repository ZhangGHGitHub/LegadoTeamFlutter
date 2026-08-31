import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/book_api.dart';
import '../../utils/error_message.dart';

/// 段评详情条目（对齐原版 ReviewRuleParser.DetailItem）
class ReviewDetailItem {
  final String? id;
  final String? avatar;
  final String? name;
  final List<String> badges;
  final String? content;
  final String? imageUrl;
  final String? audioUrl;
  final String? time;
  final int? likeCount;
  final int? replyCount;
  final List<ReviewDetailItem> replies;

  const ReviewDetailItem({
    this.id,
    this.avatar,
    this.name,
    this.badges = const [],
    this.content,
    this.imageUrl,
    this.audioUrl,
    this.time,
    this.likeCount,
    this.replyCount,
    this.replies = const [],
  });

  factory ReviewDetailItem.fromJson(Map<String, dynamic> json) {
    final rawReplies = json['replies'];
    return ReviewDetailItem(
      id: json['id']?.toString(),
      avatar: json['avatar'] as String?,
      name: json['name'] as String?,
      badges: (json['badges'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [],
      content: json['content'] as String?,
      imageUrl: json['imageUrl'] as String?,
      audioUrl: json['audioUrl'] as String?,
      time: json['time'] as String?,
      likeCount: (json['likeCount'] as num?)?.toInt(),
      replyCount: (json['replyCount'] as num?)?.toInt(),
      replies: rawReplies is List
          ? rawReplies
              .whereType<Map>()
              .map((e) =>
                  ReviewDetailItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }
}

/// 段评详情底部 Sheet（对齐原版 [ReviewDetailDialog]）
///
/// - 详情分页：`reviewGetDetail`
/// - 回复按需加载：`reviewGetReplies`（hasReplyUrl 时）
/// — UI · Auto ｜ 2026-08-13
class ReviewDetailSheet extends StatefulWidget {
  final BookApi api;
  final String sourceJson;
  final String bookUrl;
  final String chapterUrl;
  final int chapterIndex;
  final int paragraphIndex;
  final String paragraphData;
  final int totalCount;
  final Map<String, dynamic>? bookJson;
  final Map<String, dynamic>? chapterJson;

  const ReviewDetailSheet({
    super.key,
    required this.api,
    required this.sourceJson,
    required this.bookUrl,
    required this.chapterUrl,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.paragraphData,
    required this.totalCount,
    this.bookJson,
    this.chapterJson,
  });

  /// 弹出底部 Sheet
  static Future<void> show(
    BuildContext context, {
    required BookApi api,
    required String sourceJson,
    required String bookUrl,
    required String chapterUrl,
    required int chapterIndex,
    required int paragraphIndex,
    required String paragraphData,
    required int totalCount,
    Map<String, dynamic>? bookJson,
    Map<String, dynamic>? chapterJson,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReviewDetailSheet(
        api: api,
        sourceJson: sourceJson,
        bookUrl: bookUrl,
        chapterUrl: chapterUrl,
        chapterIndex: chapterIndex,
        paragraphIndex: paragraphIndex,
        paragraphData: paragraphData,
        totalCount: totalCount,
        bookJson: bookJson,
        chapterJson: chapterJson,
      ),
    );
  }

  @override
  State<ReviewDetailSheet> createState() => _ReviewDetailSheetState();
}

class _ReviewDetailSheetState extends State<ReviewDetailSheet> {
  final List<ReviewDetailItem> _items = [];
  final Set<String> _expandedParents = {};
  final Set<String> _replyLoading = {};
  final Map<String, List<ReviewDetailItem>> _loadedReplies = {};
  final Map<String, int> _replyPage = {};

  bool _loading = false;
  bool _hasMore = true;
  bool _hasReplyUrl = false;
  int _page = 1;
  String? _nextPageUrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetail(page: 1, append: false);
  }

  Map<String, dynamic> _baseRequest({String? detailUrl}) {
    return {
      'paraIndex': widget.paragraphIndex,
      'paraData': widget.paragraphData,
      'chapterUrl': widget.chapterUrl,
      if (detailUrl != null && detailUrl.isNotEmpty) 'detailUrl': detailUrl,
      if (widget.bookJson != null) 'book': widget.bookJson,
      if (widget.chapterJson != null) 'chapter': widget.chapterJson,
    };
  }

  Future<void> _loadDetail({required int page, required bool append}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (!append) _error = null;
    });
    try {
      final request = _baseRequest(
        detailUrl: page > 1 ? _nextPageUrl : null,
      );
      final raw = await widget.api.reviewGetDetail(
        widget.sourceJson,
        jsonEncode(request),
        page,
      );
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map['items'] as List?)
              ?.whereType<Map>()
              .map((e) =>
                  ReviewDetailItem.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const <ReviewDetailItem>[];
      final next = map['nextPageUrl'] as String?;
      final hasReply = map['hasReplyUrl'] == true;

      if (!mounted) return;
      setState(() {
        if (!append) _items.clear();
        _items.addAll(list);
        _page = page;
        _nextPageUrl = next;
        _hasReplyUrl = hasReply;
        _hasMore = list.isNotEmpty &&
            (next != null && next.isNotEmpty || page < 2 && list.isNotEmpty);
        if (list.isEmpty) _hasMore = false;
        _loading = false;
        if (!append && list.isEmpty) {
          _error = '暂无评论';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!append) _error = errorMessage(e);
      });
    }
  }

  Future<void> _loadReplies(ReviewDetailItem parent) async {
    final key = parent.id ?? parent.name ?? parent.content ?? '';
    if (key.isEmpty || _replyLoading.contains(key)) return;
    setState(() => _replyLoading.add(key));
    final page = (_replyPage[key] ?? 0) + 1;
    try {
      final request = {
        'reviewId': parent.id ?? '',
        'paraIndex': widget.paragraphIndex,
        'paraData': widget.paragraphData,
        'chapterUrl': widget.chapterUrl,
        if (widget.bookJson != null) 'book': widget.bookJson,
        if (widget.chapterJson != null) 'chapter': widget.chapterJson,
      };
      final raw = await widget.api.reviewGetReplies(
        widget.sourceJson,
        jsonEncode(request),
        page,
      );
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map['items'] as List?)
              ?.whereType<Map>()
              .map((e) =>
                  ReviewDetailItem.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const <ReviewDetailItem>[];
      if (!mounted) return;
      setState(() {
        final existing = _loadedReplies[key] ?? [];
        _loadedReplies[key] = [...existing, ...list];
        _replyPage[key] = page;
        _expandedParents.add(key);
        _replyLoading.remove(key);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _replyLoading.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = media.size.height * 0.62;
    final bg = CupertinoColors.systemBackground.resolveFrom(context);
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: CupertinoColors.systemGrey3.resolveFrom(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '段评 · ${widget.totalCount > 0 ? widget.totalCount : _items.length}',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.all(8),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Icon(CupertinoIcons.xmark_circle_fill, size: 22),
                ),
              ],
            ),
          ),
          Divider(
            height: 0.5,
            color: CupertinoColors.separator.resolveFrom(context),
          ),
          Expanded(child: _buildBody(secondary)),
        ],
      ),
    );
  }

  Widget _buildBody(Color secondary) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: secondary, fontSize: 15),
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 80 &&
            _hasMore &&
            !_loading) {
          _loadDetail(page: _page + 1, append: true);
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _items.length + (_loading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CupertinoActivityIndicator()),
            );
          }
          return _buildItem(_items[index], isReply: false);
        },
      ),
    );
  }

  Widget _buildItem(ReviewDetailItem item, {required bool isReply}) {
    final key = item.id ?? item.name ?? item.content ?? '';
    final label = CupertinoColors.label.resolveFrom(context);
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);
    final replies = _hasReplyUrl
        ? (_loadedReplies[key] ?? const <ReviewDetailItem>[])
        : item.replies;
    final expanded = _expandedParents.contains(key) ||
        (!_hasReplyUrl && replies.isNotEmpty);

    return Padding(
      padding: EdgeInsets.only(
        left: isReply ? 36 : 0,
        bottom: 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(item.avatar),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.name?.isNotEmpty == true
                                ? item.name!
                                : '匿名',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: label,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.badges.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          ...item.badges.take(2).map(
                                (b) => Container(
                                  margin: const EdgeInsets.only(right: 4),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: CupertinoColors.systemGrey5
                                        .resolveFrom(context),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    b,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: secondary,
                                    ),
                                  ),
                                ),
                              ),
                        ],
                      ],
                    ),
                    if (item.content?.isNotEmpty == true) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.content!,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: label,
                        ),
                      ),
                    ],
                    if (item.imageUrl?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: item.imageUrl!,
                          height: 120,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (item.time?.isNotEmpty == true)
                          Text(
                            item.time!,
                            style: TextStyle(fontSize: 12, color: secondary),
                          ),
                        if (!isReply &&
                            ((item.replyCount ?? 0) > 0 ||
                                replies.isNotEmpty ||
                                _hasReplyUrl)) ...[
                          const Spacer(),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            onPressed: () {
                              if (_hasReplyUrl &&
                                  !_expandedParents.contains(key)) {
                                _loadReplies(item);
                              } else {
                                setState(() {
                                  if (_expandedParents.contains(key)) {
                                    _expandedParents.remove(key);
                                  } else {
                                    _expandedParents.add(key);
                                  }
                                });
                              }
                            },
                            child: Text(
                              _replyLoading.contains(key)
                                  ? '加载中…'
                                  : expanded
                                      ? '收起回复'
                                      : '查看回复${(item.replyCount ?? replies.length) > 0 ? ' (${item.replyCount ?? replies.length})' : ''}',
                              style: TextStyle(
                                fontSize: 12,
                                color: CupertinoColors.activeBlue
                                    .resolveFrom(context),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (expanded)
            ...replies.map((r) => _buildItem(r, isReply: true)),
        ],
      ),
    );
  }

  Widget _avatar(String? url) {
    final placeholder = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        shape: BoxShape.circle,
      ),
      child: Icon(
        CupertinoIcons.person_fill,
        size: 16,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );
    if (url == null || url.isEmpty) return placeholder;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => placeholder,
        placeholder: (_, _) => placeholder,
      ),
    );
  }
}
