// 批28：源保存「原 JSON 补丁」工具
//
// 背景：Flutter 源编辑器的 `_buildSource()` 会从表单重建整个 `BookSource` 与
// 各规则对象，而 Dart 模型（`models/rule/rule.dart`）只建模了当前 UI 需要的键；
// `fromJson → toJson` 往返会丢弃未建模的规则键（例如原版
// `ContentRule.contentBatch` / `maxBatchSize`，以及后续新增字段）。
//
// 解决方式：保存时以「读取时拿到的原始 JSON」为底，把编辑后的模型 JSON 深合上去：
// - Map 逐键递归合并：编辑值覆盖、未出现的键（未编辑/未建模）原样保留；
// - 非 Map 值（null/List/标量）以编辑值为准（显式 null = 用户清空）；
// - 原始 JSON 缺失时退化为编辑值（新建源、缓存未命中）。
//
// 编写：全栈工程师（批28） ｜ 2026-10-28

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 以 [original] 为底、把 [edited] 深合上去，返回新 Map（不修改入参）。
///
/// 语义见文件头注释；`Map` 值只做键级递归，不做 List 元素级合并。
Map<String, dynamic> patchSourceJson(
  Map<String, dynamic>? original,
  Map<String, dynamic> edited,
) {
  if (original == null) return Map<String, dynamic>.from(edited);
  final merged = Map<String, dynamic>.from(original);
  for (final entry in edited.entries) {
    final base = merged[entry.key];
    final patch = entry.value;
    if (base is Map && patch is Map) {
      merged[entry.key] = patchSourceJson(
        _asStringKeyedMap(base),
        _asStringKeyedMap(patch),
      );
    } else {
      merged[entry.key] = patch;
    }
  }
  return merged;
}

/// 构造 `updateBookSource` 保存载荷（批28b P2-2③：抽函数便于注入测试）
///
/// 生产路径（[BookSourceRawCache] 命中/回拉 `sourceList`）与测试共用本函数：
/// [editedJson] 为编辑后的模型 JSON；[resolveOriginal] 负责按 URL 提供读取时
/// 的原始 JSON（未命中返回 null，退化为编辑值）。
///
/// 返回的 Map 就是传给 FFI `sourceUpdate` 的载荷（调用方负责 jsonEncode）。
Future<Map<String, dynamic>> buildPatchedSourcePayload(
  Map<String, dynamic> editedJson, {
  required Future<Map<String, dynamic>?> Function(String url) resolveOriginal,
}) async {
  final url = editedJson['bookSourceUrl'];
  final original = url is String && url.isNotEmpty
      ? await resolveOriginal(url)
      : null;
  return patchSourceJson(original, editedJson);
}

/// 把任意 `Map`（可能来自 `jsonDecode` 的 `Map<String, dynamic>` 或嵌套 `Map`）
/// 归一为 `Map<String, dynamic>`（键按字符串处理）。
Map<String, dynamic> _asStringKeyedMap(Map<dynamic, dynamic> source) {
  if (source is Map<String, dynamic>) return source;
  return source.map((key, value) => MapEntry(key.toString(), value));
}

/// 书源原始 JSON 缓存（按 `bookSourceUrl` 索引）
///
/// 数据来源：`getBookSources()` / `getEnabledBookSources()` 的 FFI JSON 响应。
/// 用途：`updateBookSource()` 保存时以缓存原文为底做 [`patchSourceJson`]，
/// 让编辑表单之外的字段（含未建模键）在保存后仍原样保留。
///
/// 进程内静态缓存、仅由 Dart 单 isolate 访问；保存成功后把补丁结果回写缓存，
/// 保证连续多次保存不退化。缓存未命中时由调用方回退到一次 `sourceList` 拉取。
class BookSourceRawCache {
  BookSourceRawCache._();

  static final Map<String, Map<String, dynamic>> _byUrl = {};

  /// 缓存条目上限（批28b P3-7）：超出后按插入顺序淘汰最旧条目
  ///
  /// 书源量级通常为数百；上限只防御异常大列表/长时间运行导致的内存增长。
  /// 淘汰仅影响「原 JSON 补丁」的底线，未命中仍会回拉 `sourceList`。
  static const int maxEntries = 2000;

  /// 解析并缓存书源列表 JSON（裸数组，`ffi::source_list` 原样输出）
  ///
  /// 非法 JSON / 非数组内容静默忽略（缓存只做尽力优化，不阻断主流程）。
  static void rememberAllJson(String jsonArray) {
    if (jsonArray.isEmpty) return;
    try {
      final decoded = jsonDecode(jsonArray);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is Map) remember(_asStringKeyedMap(item));
      }
    } catch (e) {
      debugPrint('BookSourceRawCache 解析书源列表失败（忽略）: $e');
    }
  }

  /// 缓存单个书源 JSON（按 `bookSourceUrl` 建索引；缺 URL 的条目跳过）
  ///
  /// 新键且已达 [maxEntries] 时先淘汰最旧条目（FIFO），防止无界增长。
  static void remember(Map<String, dynamic> source) {
    final url = source['bookSourceUrl'];
    if (url is! String || url.isEmpty) return;
    if (!_byUrl.containsKey(url) && _byUrl.length >= maxEntries) {
      _byUrl.remove(_byUrl.keys.first);
    }
    _byUrl[url] = source;
  }

  /// 移除单个书源的缓存（批28b P3-7：删除书源后不再保留其原始 JSON）
  static void forget(String bookSourceUrl) => _byUrl.remove(bookSourceUrl);

  /// 读取书源原始 JSON（未缓存返回 null）
  static Map<String, dynamic>? lookup(String bookSourceUrl) =>
      _byUrl[bookSourceUrl];

  /// 清空缓存（测试用；书源导入/全量重置后可调用）
  static void clear() => _byUrl.clear();
}
