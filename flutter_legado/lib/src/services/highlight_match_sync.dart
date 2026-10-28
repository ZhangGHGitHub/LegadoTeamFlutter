/// 正文高亮匹配同步器（批34b）
///
/// 从阅读页 State 抽出的接线逻辑（P2-1）：键计算、缓存命中、换章清空、
/// 在途去重、规则修订号失效丢弃、失败退避与「每 key 最多重试一次」（P2-4）。
/// 阅读页只负责按已分页内容/书快照构造 [HighlightMatchRequest]，并在
/// [HighlightMatchSync.sync] 返回后直接渲染；异步结果经 `onLoaded` 通知
/// 调用方 `setState` 重建渲染层（不触发重分页）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/highlight_style.dart';
import 'highlight_match_cache.dart';

/// 跨 FFI 匹配加载器（签名与 `BookApi.highlightRuleMatch` 对齐，便于测试注入）
typedef HighlightMatchLoader =
    Future<String> Function({
      required String text,
      required String bookName,
      required String origin,
    });

/// 一次同步的输入快照
@immutable
class HighlightMatchRequest {
  const HighlightMatchRequest({
    required this.enabled,
    required this.bookUrl,
    required this.bookName,
    required this.origin,
    required this.chapterIndex,
    required this.content,
    required this.rulesRevision,
  });

  /// false = 滚动模式 / 无书：清空且不发起跨 FFI
  final bool enabled;

  /// 书籍 URL（缓存键组成部分）
  final String bookUrl;

  /// 书名（规则 scope 过滤）
  final String bookName;

  /// 书源 origin（规则 scope 过滤）
  final String origin;

  /// 章节索引（缓存键组成部分）
  final int chapterIndex;

  /// 待匹配正文（以已分页内容为准，加载冻结帧不串章）
  final String content;

  /// 高亮规则修订号（变化即失效旧结果与旧缓存）
  final int rulesRevision;
}

/// 正文高亮匹配同步器
///
/// 状态机（[sync] 在 build 内每帧调用）：
/// 1. 未启用 / 正文为空 → 清空当前命中与在途标记，不发起 FFI；
/// 2. key 未变 → 原样返回；
/// 3. 缓存命中 → 直接换值（本帧即用，无需 setState）；
/// 4. 未命中 → 先清旧命中（防新章短暂套用上一章区间），再按 key 去重发起
///    一次异步匹配；失败后清 key 并按 [retryDelay] 退避，单 key 最多尝试
///    [maxAttemptsPerKey] 次（首次 + 一次重试），避免坏章节每帧重试。
class HighlightMatchSync {
  HighlightMatchSync({
    HighlightMatchCache? cache,
    this.retryDelay = const Duration(milliseconds: 1500),
    DateTime Function()? now,
  }) : _cache = cache ?? HighlightMatchCache(),
       _now = now ?? DateTime.now;

  /// 单 key 最多尝试次数（首次 + 一次重试）
  static const int maxAttemptsPerKey = 2;

  final HighlightMatchCache _cache;

  /// 失败后的退避时长（到点前不重发同 key 请求）
  final Duration retryDelay;

  final DateTime Function() _now;

  List<HighlightMatch> _matches = const [];
  String _key = '';
  String _loadingKey = '';
  int _rulesRevision = 0;

  /// 各 key 已发起的尝试次数（成功/换 key 后不再关心）
  final Map<String, int> _attempts = {};

  /// 各 key 的下次允许重试时间（失败退避）
  final Map<String, DateTime> _retryAfter = {};

  /// 当前可渲染命中（章节全局 UTF-16 半开区间，互不重叠）
  List<HighlightMatch> get matches => _matches;

  /// 当前命中对应的缓存键（空=无）
  String get key => _key;

  /// 在途匹配的缓存键（空=无）
  String get loadingKey => _loadingKey;

  /// 匹配缓存键：书籍 + 章号 + 文本长度 + 文本 hash + 规则修订号
  ///
  /// 文本长度参与键（P3-3）：hash 碰撞时长度不同也不会误命中他章结果。
  static String cacheKey({
    required String bookUrl,
    required int chapterIndex,
    required String text,
    required int rulesRevision,
  }) {
    return '$bookUrl\u0000$chapterIndex\u0000${text.length}'
        '\u0000${text.hashCode}\u0000$rulesRevision';
  }

  /// 同步当前章命中，返回本帧直接可渲染的命中列表
  ///
  /// - [load]：跨 FFI 加载器（未命中缓存时调用一次）；
  /// - [onLoaded]：异步结果被采纳时回调（调用方据此 setState 重建渲染层）。
  List<HighlightMatch> sync(
    HighlightMatchRequest request, {
    required HighlightMatchLoader load,
    required void Function() onLoaded,
  }) {
    _rulesRevision = request.rulesRevision;
    if (!request.enabled || request.content.isEmpty) {
      _clear();
      return _matches;
    }

    final key = cacheKey(
      bookUrl: request.bookUrl,
      chapterIndex: request.chapterIndex,
      text: request.content,
      rulesRevision: request.rulesRevision,
    );
    if (key == _key) return _matches;

    final cached = _cache.lookup(key, request.rulesRevision);
    if (cached != null) {
      _key = key;
      _matches = cached;
      return _matches;
    }

    // 换章先清旧命中，防止新章文本短暂套用上一章区间
    _matches = const [];
    if (_loadingKey == key) {
      _key = key;
      return _matches;
    }

    final attempts = _attempts[key] ?? 0;
    if (attempts >= maxAttemptsPerKey) {
      // 重试预算耗尽：记为当前 key，后续帧不再重复查询/请求
      _key = key;
      return _matches;
    }
    final retryAfter = _retryAfter[key];
    if (retryAfter != null && _now().isBefore(retryAfter)) {
      // 失败退避中：保持 key 为空，退避结束后下一帧再试
      return _matches;
    }

    _attempts[key] = attempts + 1;
    _loadingKey = key;
    _key = key;
    unawaited(_run(request, key, load, onLoaded));
    return _matches;
  }

  /// 清空当前命中与键（停用/无书/空正文）
  void _clear() {
    if (_matches.isNotEmpty) _matches = const [];
    _key = '';
    // 在途请求作废：其结果到达时因 key 不匹配被丢弃
    _loadingKey = '';
  }

  /// 执行一次跨 FFI 匹配并按 key/修订号校验后采纳结果
  Future<void> _run(
    HighlightMatchRequest request,
    String key,
    HighlightMatchLoader load,
    void Function() onLoaded,
  ) async {
    try {
      final raw = await load(
        text: request.content,
        bookName: request.bookName,
        origin: request.origin,
      );
      final matches = parseHighlightMatches(raw);
      _attempts.remove(key);
      _retryAfter.remove(key);
      _cache.store(key, request.rulesRevision, matches);
      // 章节已切换/内容已变化（key 变）或请求已被作废 → 丢弃旧结果
      if (_loadingKey != key || _key != key) return;
      // 规则修订号已变 → 丢弃旧结果（缓存键亦含修订号，双保险）
      if (request.rulesRevision != _rulesRevision) return;
      _matches = matches;
      onLoaded();
    } catch (e) {
      // 高亮是增益能力：失败只降级为无高亮，不打断阅读
      _retryAfter[key] = _now().add(retryDelay);
      if (_key == key) _key = '';
      debugPrint(
        '[highlight] 正文高亮匹配失败（已降级为无高亮；'
        '同章最多尝试 $maxAttemptsPerKey 次）: $e',
      );
    } finally {
      if (_loadingKey == key) _loadingKey = '';
    }
  }
}
