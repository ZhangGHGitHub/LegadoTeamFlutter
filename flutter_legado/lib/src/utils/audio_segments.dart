// 多段音频播放地址解析（对齐原版 AudioPlayService + ExoPlayerHelper）
//
// 原版 `AudioPlayService.kt:307-317`：`requestUrl.isJsonArray()` 为真时把整串
// 交给 `ExoPlayerHelper.getMediaSource`（`ExoPlayerHelper.kt:158-169`），后者
// `GSON.fromJsonArray<String>` 后逐段建 `ProgressiveMediaSource` 拼成一条媒体源；
// 非数组则按普通单地址走 `AnalyzeUrl`。
//
// 我方 `StreamAudioPlayer` 是单 `VideoPlayerController`，无媒体源拼接能力，
// 因此改为「逐段串播」：播完一段 → 间隙 → 下一段（编排在
// `AudioNotifier._onStreamCompleted` / `_advanceSegment`）。本文件只负责把
// 播放地址解析为段列表（含每段的 UrlOption headers 合并）。
//
// — Auto + UI｜2026-11-19（批3 多段音频播放支持）

import 'dart:convert';

import 'video_play_utils.dart';

/// 多段音频段间间隙（毫秒）——**0 = 零间隙连续播放（对齐原版）**
///
/// 原版 `ExoPlayerHelper.kt:163-167` 写作 `mediaSourceBuilder.add(source, 3000)`；
/// media3 `ConcatenatingMediaSource2.Builder.add(MediaSource, long)` 的第二参数
/// 是 **initialPlaceholderDurationMs（初始占位时长估计）**——媒体源加载前
/// 用于估算总时长，**不是静音间隙**。原版多段由播放器内部拼成一条连续
/// 时间轴，段与段之间零等待。
///
/// 我方 [StreamAudioPlayer] 只能逐段串播，故在段完成回调内**同步**起播
/// 下一段（不建定时器、不额外让出事件循环，见
/// `AudioNotifier._advanceToNextSegmentIfAny`）：换控制器时的加载耗时就是
/// 唯一的自然间隔。取 0 即关闭人为间隙；若将来确需人为留白，把本常量改为
/// 正数即可，串播编排会自动退回定时器路径。
const int kMultiSegmentAudioGapMs = 0;

/// 单段播放目标：纯 URL + 该段生效的请求头（空 Map = 无请求头）
typedef AudioPlaySegment = ({String url, Map<String, String> headers});

/// 播放地址是否为 JSON 数组形态
///
/// 语义对齐原版 `StringExtensions.kt:64-69` `isJsonArray()`：trim 后
/// 以 `[` 开头且以 `]` 结尾（不做语法校验，语法合法性由解析时判定）。
bool isJsonArrayPlayUrl(String raw) {
  final trimmed = raw.trim();
  return trimmed.length >= 2 &&
      trimmed.startsWith('[') &&
      trimmed.endsWith(']');
}

/// 解析播放地址为分段列表
///
/// - 非数组：整串作为单段（仍解析其 `,{json}` UrlOption 选项）；
/// - JSON 数组：逐元素解析，非字符串/空串元素丢弃；
/// - 形似数组但解析失败、或数组内无有效元素：返回空列表（调用方按
///   「未获取到资源链接」处理，对应原版 `getMediaSource` 返回 null →
///   `NoStackTraceException("url格式错误")`）。
///
/// [chapterHeaders] 为本章级请求头（契约 §2.26 `headers`）；每段都叠加，
/// 段内 UrlOption 的 headers 优先级更高（更具体，与 `mergeVideoHeaders`
/// 的 `{...sourceHeaders, ...optionHeaders}` 顺序一致）。
List<AudioPlaySegment> parseAudioPlaySegments(
  String raw, {
  Map<String, String>? chapterHeaders,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];

  final entries = <String>[];
  if (isJsonArrayPlayUrl(trimmed)) {
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    for (final item in decoded) {
      if (item is String && item.trim().isNotEmpty) {
        entries.add(item.trim());
      }
    }
    if (entries.isEmpty) return const [];
  } else {
    entries.add(trimmed);
  }

  final segments = <AudioPlaySegment>[];
  for (final entry in entries) {
    // 复用视频播放链的 UrlOption 解析（`url,{"headers":{...}}` 形态）
    final split = splitUrlOption(entry);
    final url = split.url.trim();
    if (url.isEmpty) continue;
    segments.add((
      url: url,
      headers: _mergeSegmentHeaders(chapterHeaders, split.headers),
    ));
  }
  return segments;
}

/// 合并章级 headers 与段内 UrlOption headers（段内优先，空合并返回空 Map）
Map<String, String> _mergeSegmentHeaders(
  Map<String, String>? chapterHeaders,
  Map<String, String> optionHeaders,
) {
  if (optionHeaders.isEmpty) {
    return chapterHeaders == null || chapterHeaders.isEmpty
        ? const {}
        : Map<String, String>.unmodifiable(chapterHeaders);
  }
  if (chapterHeaders == null || chapterHeaders.isEmpty) {
    return Map<String, String>.unmodifiable(optionHeaders);
  }
  return Map<String, String>.unmodifiable({
    ...chapterHeaders,
    ...optionHeaders,
  });
}
