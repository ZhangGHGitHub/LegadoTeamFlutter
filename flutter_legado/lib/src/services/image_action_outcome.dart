// 图片动作返回值解析（契约 §2.21 evalImageAction，批21-A）
//
// Rust 侧在有 UI 副作用（java.toast / java.longToast / java.showBrowser /
// java.startBrowser / java.openUrl 等）时，把返回值扩展为结构化 JSON：
//   {"result": "动作返回值", "actions": [{"action": "toast", "message": "ab"}]}
// 无副作用时保持纯结果字符串（向后兼容）。本文件只做解析，不触发任何 UI。

import 'dart:convert';

import 'book_api.dart';

/// 单条 UI 副作用（Rust `ui_action_queue` 回传的 JSON 对象）
class ImageActionSideEffect {
  const ImageActionSideEffect({required this.name, required this.data});

  /// 动作名（`toast` / `longToast` / `openBrowser` / `startBrowser` /
  /// `openUrl` 等，对齐 `legado-js` 宿主 API 入队形态）
  final String name;

  /// 原始 JSON 字段（`message` / `url` / `text` 等按动作名取用）
  final Map<String, dynamic> data;

  /// `message` 字段（toast/longToast）
  String get message => (data['message'] ?? '').toString();

  /// `url` 字段（openBrowser/startBrowser/openUrl）
  String get url => (data['url'] ?? '').toString();

  /// 解析单条副作用；非对象/缺 action 名时返回 null（坏数据不抛错）
  static ImageActionSideEffect? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final data = Map<String, dynamic>.from(raw);
    final name = (data['action'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    return ImageActionSideEffect(name: name, data: data);
  }

  @override
  String toString() => 'ImageActionSideEffect($name, $data)';
}

/// `evalImageAction` 的解析结果（结果字符串 + 中途 UI 副作用）
class ImageActionOutcome {
  const ImageActionOutcome({
    required this.result,
    this.actions = const <ImageActionSideEffect>[],
  });

  /// 动作返回值（与无副作用时的纯字符串返回值一致）
  final String result;

  /// 中途 UI 副作用（按 Rust 入队顺序；无副作用时为空）
  final List<ImageActionSideEffect> actions;

  /// 解析 Rust `evalImageAction` 原始返回串
  ///
  /// 仅当返回值是 JSON 对象、含字符串 `result` 与**非空** `actions` 数组时
  /// 视为信封（Rust 只在有 action 时才包信封，非空判定可避免把书源动作
  /// 恰好返回的同形 JSON 误判）；其余情况一律按纯结果字符串处理。
  /// 解析失败不抛错（阅读主链路不因坏数据中断）。
  static ImageActionOutcome parse(String raw) {
    final text = raw.trim();
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic> &&
            decoded['result'] is String &&
            decoded['actions'] is List &&
            (decoded['actions'] as List).isNotEmpty) {
          final actions = <ImageActionSideEffect>[];
          for (final item in decoded['actions'] as List) {
            final parsed = ImageActionSideEffect.tryParse(item);
            if (parsed != null) actions.add(parsed);
          }
          return ImageActionOutcome(
            result: decoded['result'] as String,
            actions: actions,
          );
        }
      } catch (_) {
        // 非 JSON/结构不符：按纯字符串结果处理
      }
    }
    return ImageActionOutcome(result: raw);
  }
}

/// `BookApi.evalImageAction` 的信封解析扩展（批21-A）
///
/// 用扩展而非改接口签名：真实实现与 Mock/测试桩无需改动，旧 Rust 返回值
/// （纯字符串）也自动兼容。
extension ImageActionOutcomeApi on BookApi {
  /// 执行图片动作并按需拆分 UI 副作用
  Future<ImageActionOutcome> evalImageActionOutcome(
    String bookUrl,
    int chapterIndex,
    String action,
    String imgSrc,
  ) async => ImageActionOutcome.parse(
    await evalImageAction(bookUrl, chapterIndex, action, imgSrc),
  );
}
