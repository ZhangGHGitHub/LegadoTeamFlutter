import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'book_api.dart';

/// 导出服务
///
/// 提供书籍导出功能，对接 Rust `bookExport` / `bookExportWithOptions`。
class ExportService {
  final BookApi _rustApi;

  ExportService(this._rustApi);

  /// 支持的导出格式（对齐原版 CacheActivity：txt/epub/pdf；html 为重构版保留）
  List<String> get supportedFormats => ['txt', 'epub', 'pdf', 'html'];

  /// 默认字符集
  static const String defaultEncoding = 'UTF-8';

  /// 支持的字符集列表（对齐 AppConst.charsets 常用项）
  List<String> get supportedEncodings => [
        'UTF-8',
        'GBK',
        'GB2312',
        'GB18030',
        'Big5',
        'UTF-16',
        'UTF-16LE',
        'ASCII',
      ];

  /// 导出书籍（透传 options → bookExportWithOptions）
  Future<Map<String, dynamic>> export({
    required String bookUrl,
    required String format,
    required bool includeToc,
    String? encoding,
    int? startChapter,
    int? endChapter,
    String? fileNameTemplate,
  }) async {
    if (!supportedFormats.contains(format)) {
      throw ExportException('不支持的导出格式：$format');
    }

    final options = <String, dynamic>{};
    if (encoding != null && encoding.isNotEmpty) {
      options['encoding'] = encoding;
    }
    if (startChapter != null && startChapter >= 0) {
      options['startChapter'] = startChapter;
    }
    if (endChapter != null && endChapter >= 0) {
      options['endChapter'] = endChapter;
    }
    if (fileNameTemplate != null && fileNameTemplate.trim().isNotEmpty) {
      options['fileNameTemplate'] = fileNameTemplate.trim();
    }
    final optionsJson = options.isEmpty ? '' : jsonEncode(options);

    final result = await _rustApi.bookExportWithOptions(
      bookUrl: bookUrl,
      format: format,
      includeToc: includeToc,
      optionsJson: optionsJson,
    );

    if (result['success'] == false) {
      final error = result['error'] as String? ?? '导出失败';
      throw ExportException(error);
    }
    return result;
  }

  /// 获取导出预览信息
  Future<Map<String, dynamic>> getExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    if (!supportedFormats.contains(format)) {
      throw ExportException('不支持的导出格式：$format');
    }
    return _rustApi.bookExportInfo(bookUrl: bookUrl, format: format);
  }

  /// 将导出的文件上传到 WebDAV（文本路径，兼容旧调用）
  Future<bool> webdavUpload(
    String configJson,
    String path,
    String data,
  ) async {
    try {
      await _rustApi.webdavUpload(configJson, path, data);
      return true;
    } catch (e) {
      debugPrint('[ExportService] WebDAV 上传失败：$e');
      rethrow;
    }
  }

  /// 上传本地文件到 WebDAV（二进制，对齐 webdavUploadFile）
  Future<bool> webdavUploadFile(
    String configJson,
    String remotePath,
    String localFilePath,
  ) async {
    try {
      await _rustApi.webdavUploadFile(configJson, remotePath, localFilePath);
      return true;
    } catch (e) {
      debugPrint('[ExportService] WebDAV 文件上传失败：$e');
      rethrow;
    }
  }
}

/// 导出异常
class ExportException implements Exception {
  final String message;

  const ExportException(this.message);

  @override
  String toString() => 'ExportException: $message';
}
