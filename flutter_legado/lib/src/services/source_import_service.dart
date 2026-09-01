import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge_http.dart';

import '../bridge/ffi.dart' show BridgeError;
import 'book_api.dart';

/// 书源导入结果
class ImportResult {
  /// 总数
  final int total;

  /// 成功导入数
  final int success;

  /// 失败数
  final int failed;

  /// 跳过数（重复或无效）
  final int skipped;

  /// 错误信息列表
  final List<String> errors;

  /// 单位名（如「书源」「替换规则」），用于汇总文案
  final String unit;

  const ImportResult({
    required this.total,
    required this.success,
    required this.failed,
    required this.skipped,
    required this.errors,
    this.unit = '书源',
  });

  /// 是否有错误
  bool get hasErrors => errors.isNotEmpty;

  /// 汇总信息
  String get summary {
    final parts = <String>[];
    if (success > 0) parts.add('成功 $success');
    if (failed > 0) parts.add('失败 $failed');
    if (skipped > 0) parts.add('跳过 $skipped');
    return '共 $total 个$unit：${parts.join('，')}';
  }
}

/// 确认页预览条目：保留原始 JSON Map，仅轻量提取展示字段
///
/// 第三方书源常带不稳定类型字段（如 `"lastUpdateTime": "1785432524399"`
/// 字符串数字、`"isVolume": "false"` 字符串布尔），严格的 freezed
/// `BookSource.fromJson` 会抛 TypeError 导致整批书源被丢弃。
/// 因此预览阶段不做类型化解析：展示字段用 `?.toString()` 宽容读取，
/// 原始 [raw] Map 在确认导入时 jsonEncode 直传 Rust 侧宽松反序列化兜底。
class SourcePreview {
  /// 原始 JSON（确认导入时 jsonEncode 后直传 importBookSources）
  final Map<String, dynamic> raw;

  /// 展示字段（轻量提取，仅供确认页列表显示与状态判定）
  final String bookSourceUrl;
  final String bookSourceName;
  final String? bookSourceComment;
  final int lastUpdateTime;

  const SourcePreview({
    required this.raw,
    required this.bookSourceUrl,
    required this.bookSourceName,
    this.bookSourceComment,
    this.lastUpdateTime = 0,
  });

  /// 从原始 JSON Map 轻量构造预览条目（不做严格类型化解析）
  factory SourcePreview.fromRaw(Map<String, dynamic> raw) {
    return SourcePreview(
      raw: raw,
      bookSourceUrl: raw['bookSourceUrl']?.toString() ?? '',
      bookSourceName: raw['bookSourceName']?.toString() ?? '',
      bookSourceComment: raw['bookSourceComment']?.toString(),
      lastUpdateTime: _parseIntLenient(raw['lastUpdateTime']),
    );
  }
}

/// 宽容解析整数：支持数字与字符串数字（第三方书源 lastUpdateTime
/// 常为字符串），无法解析时返回 0
int _parseIntLenient(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

/// 书源导入服务
class SourceImportService {
  final BookApi _api;

  SourceImportService(this._api);

  /// 从 URL 拉取并解析书源列表（仅预览，不写入数据库）
  ///
  /// 对标原版 ImportBookSourceViewModel.importSourceUrl + comparisonSource：
  /// 先拉取解析出全部候选书源，由 UI 层展示确认页供用户选择后再导入。
  Future<List<SourcePreview>> fetchSourcesFromUrl(String url) async {
    final response = await bridgeHttpGet(
      _api,
      url,
      timeout: const Duration(seconds: 30),
    );
    if (!response.isSuccess) {
      throw FormatException('HTTP 请求失败：状态码 ${response.statusCode}');
    }
    return parseSourcesText(response.body);
  }

  /// 从本地文件拉取并解析书源列表（仅预览，不写入数据库）
  Future<List<SourcePreview>> fetchSourcesFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FormatException('文件不存在：$filePath');
    }
    final content = await file.readAsString(encoding: utf8);
    return parseSourcesText(content);
  }

  /// 解析书源 JSON 文本为预览条目列表（仅预览，不写入数据库）
  ///
  /// 支持单个书源对象或书源数组。不做严格 freezed 类型化解析（第三方书源
  /// 的字符串数字/字符串布尔字段会抛 TypeError），仅轻量提取展示字段；
  /// 原始 JSON 保留到 [SourcePreview.raw]，确认导入时直传 Rust 兜底。
  /// 失败项累计计数，全部失败时抛出携带首个错误信息的 FormatException。
  List<SourcePreview> parseSourcesText(String jsonStr) {
    final decoded = jsonDecode(jsonStr.trim());
    final List<dynamic> sourceList;
    if (decoded is List) {
      sourceList = decoded;
    } else if (decoded is Map<String, dynamic>) {
      sourceList = [decoded];
    } else {
      throw const FormatException('无效的 JSON 格式：期望数组或对象');
    }

    final sources = <SourcePreview>[];
    var failed = 0;
    String? firstError;
    for (var i = 0; i < sourceList.length; i++) {
      final item = sourceList[i];
      if (item is! Map<String, dynamic>) {
        failed++;
        firstError ??= '第 ${i + 1} 项不是有效的 JSON 对象';
        continue;
      }
      final validationErrors = validateSource(item);
      if (validationErrors.isNotEmpty) {
        failed++;
        firstError ??= '第 ${i + 1} 项校验失败：${validationErrors.join('；')}';
        continue;
      }
      sources.add(SourcePreview.fromRaw(item));
    }
    if (sources.isEmpty) {
      // 不再静默吞掉失败：全部失败时抛出明确错误，由调用方提示用户
      throw FormatException(
          '未解析到有效书源（失败 $failed 项）${firstError == null ? '' : '：$firstError'}');
    }
    return sources;
  }

  /// 从 JSON 字符串导入书源
  ///
  /// 支持单个书源对象或书源数组。[unit] 用于结果汇总文案（默认「书源」）。
  Future<ImportResult> importFromJson(
    String jsonStr, {
    String unit = '书源',
  }) async {
    final errors = <String>[];
    var total = 0;
    var success = 0;
    var failed = 0;
    var skipped = 0;

    try {
      final decoded = jsonDecode(jsonStr);

      final List<dynamic> sourceList;
      if (decoded is List) {
        sourceList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        sourceList = [decoded];
      } else {
        return ImportResult(
          total: 0,
          success: 0,
          failed: 0,
          skipped: 0,
          errors: ['无效的 JSON 格式：期望数组或对象'],
          unit: unit,
        );
      }

      total = sourceList.length;

      for (var i = 0; i < sourceList.length; i++) {
        final item = sourceList[i];
        if (item is! Map<String, dynamic>) {
          failed++;
          errors.add('第 ${i + 1} 项不是有效的 JSON 对象');
          continue;
        }

        final validationErrors = validateSource(item);
        if (validationErrors.isNotEmpty) {
          skipped++;
          errors.add(
              '第 ${i + 1} 项校验失败：${validationErrors.join('；')}');
          continue;
        }

        try {
          final json = jsonEncode(item);
          await _api.importBookSources('[$json]');
          success++;
        } catch (e) {
          failed++;
          final name = item['bookSourceName'] ?? '未知书源';
          // BridgeError 取 message，避免显示 "Instance of 'BridgeError'"
          final msg = e is BridgeError ? e.message : e.toString();
          errors.add('导入「$name」失败：$msg');
        }
      }
    } on FormatException catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['JSON 解析错误：${e.message}'],
        unit: unit,
      );
    }

    return ImportResult(
      total: total,
      success: success,
      failed: failed,
      skipped: skipped,
      errors: errors,
      unit: unit,
    );
  }

  /// 从 URL 导入书源
  Future<ImportResult> importFromUrl(
    String url, {
    String unit = '书源',
  }) async {
    try {
      final response = await bridgeHttpGet(
        _api,
        url,
        timeout: const Duration(seconds: 30),
      );

      if (!response.isSuccess) {
        return ImportResult(
          total: 0,
          success: 0,
          failed: 0,
          skipped: 0,
          errors: ['HTTP 请求失败：状态码 ${response.statusCode}'],
          unit: unit,
        );
      }

      return await importFromJson(response.body, unit: unit);
    } on TimeoutException catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['网络请求超时：$e'],
        unit: unit,
      );
    } catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['从 URL 导入失败：$e'],
        unit: unit,
      );
    }
  }

  /// 从文件导入书源
  Future<ImportResult> importFromFile(
    String filePath, {
    String unit = '书源',
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return ImportResult(
          total: 0,
          success: 0,
          failed: 0,
          skipped: 0,
          errors: ['文件不存在：$filePath'],
          unit: unit,
        );
      }

      final content = await file.readAsString(encoding: utf8);
      return await importFromJson(content, unit: unit);
    } catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['读取文件失败：$e'],
        unit: unit,
      );
    }
  }

  /// 校验书源 JSON 格式
  ///
  /// 返回校验错误列表，空列表表示校验通过。
  List<String> validateSource(Map<String, dynamic> source) {
    final errors = <String>[];
    // 用 toString 宽容判空，避免第三方书源非字符串类型触发 cast 异常
    final url = source['bookSourceUrl']?.toString();
    if (url == null || url.isEmpty) {
      errors.add('缺少 bookSourceUrl');
    }
    final name = source['bookSourceName']?.toString();
    if (name == null || name.isEmpty) {
      errors.add('缺少 bookSourceName');
    }
    return errors;
  }
}

/// 超时异常
class TimeoutException implements Exception {
  final String message;
  const TimeoutException(this.message);
  @override
  String toString() => message;
}
