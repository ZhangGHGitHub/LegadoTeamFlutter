import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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

  const ImportResult({
    required this.total,
    required this.success,
    required this.failed,
    required this.skipped,
    required this.errors,
  });

  /// 是否有错误
  bool get hasErrors => errors.isNotEmpty;

  /// 汇总信息
  String get summary {
    final parts = <String>[];
    if (success > 0) parts.add('成功 $success');
    if (failed > 0) parts.add('失败 $failed');
    if (skipped > 0) parts.add('跳过 $skipped');
    return '共 $total 个书源：${parts.join('，')}';
  }
}

/// 书源导入服务
class SourceImportService {
  final BookApi _api;

  SourceImportService(this._api);

  /// 从 JSON 字符串导入书源
  ///
  /// 支持单个书源对象或书源数组。
  Future<ImportResult> importFromJson(String jsonStr) async {
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
      );
    }

    return ImportResult(
      total: total,
      success: success,
      failed: failed,
      skipped: skipped,
      errors: errors,
    );
  }

  /// 从 URL 导入书源
  Future<ImportResult> importFromUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('请求超时（30秒）'),
      );

      if (response.statusCode != 200) {
        return ImportResult(
          total: 0,
          success: 0,
          failed: 0,
          skipped: 0,
          errors: ['HTTP 请求失败：状态码 ${response.statusCode}'],
        );
      }

      final body = utf8.decode(response.bodyBytes);
      return await importFromJson(body);
    } on TimeoutException catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['网络请求超时：$e'],
      );
    } catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['从 URL 导入失败：$e'],
      );
    }
  }

  /// 从文件导入书源
  Future<ImportResult> importFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return ImportResult(
          total: 0,
          success: 0,
          failed: 0,
          skipped: 0,
          errors: ['文件不存在：$filePath'],
        );
      }

      final content = await file.readAsString(encoding: utf8);
      return await importFromJson(content);
    } catch (e) {
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: ['读取文件失败：$e'],
      );
    }
  }

  /// 校验书源 JSON 格式
  ///
  /// 返回校验错误列表，空列表表示校验通过。
  List<String> validateSource(Map<String, dynamic> source) {
    final errors = <String>[];
    if (!source.containsKey('bookSourceUrl') ||
        (source['bookSourceUrl'] as String?)?.isEmpty == true) {
      errors.add('缺少 bookSourceUrl');
    }
    if (!source.containsKey('bookSourceName') ||
        (source['bookSourceName'] as String?)?.isEmpty == true) {
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
