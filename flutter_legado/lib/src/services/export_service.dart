import 'package:flutter/foundation.dart';
import 'rust_api.dart';

/// 导出服务
///
/// 提供书籍导出功能，对接 Rust 后端的 export_book API。
class ExportService {
  final RustApi _rustApi;

  ExportService(this._rustApi);

  // ========== 导出配置 ==========

  /// 支持的导出格式
  List<String> get supportedFormats => ['txt', 'epub', 'html'];

  /// 默认字符集
  static const String defaultEncoding = 'UTF-8';

  /// 支持的字符集列表
  List<String> get supportedEncodings => [
        'UTF-8',
        'GBK',
        'GB2312',
        'Big5',
        'ISO-8859-1',
        'ASCII',
      ];

  // ========== 导出方法 ==========

  /// 导出书籍
  ///
  /// # 参数
  /// - `bookUrl`: 书籍 URL
  /// - `format`: 导出格式（txt/epub/html）
  /// - `includeToc`: 是否包含目录
  /// - `encoding`: 字符集（可选，默认为 UTF-8）
  ///
  /// # 返回
  /// ExportResult，包含 success、data_base64、file_name、mime_type、error 等字段
  Future<Map<String, dynamic>> export({
    required String bookUrl,
    required String format,
    required bool includeToc,
    String? encoding,
  }) async {
    try {
      // 验证格式
      if (!supportedFormats.contains(format)) {
        throw ExportException('不支持的导出格式：$format');
      }

      // 调用 Rust API
      final result = await _rustApi.bookExport(
        bookUrl: bookUrl,
        format: format,
        includeToc: includeToc,
      );

      // 检查是否成功
      if (result['success'] == false) {
        final error = result['error'] as String? ?? '导出失败';
        throw ExportException(error);
      }

      return result;
    } catch (e) {
      rethrow;
    }
  }

  /// 获取导出预览信息
  ///
  /// 用于在导出前显示文件的预计大小和章节数量。
  Future<Map<String, dynamic>> getExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    try {
      // 验证格式
      if (!supportedFormats.contains(format)) {
        throw ExportException('不支持的导出格式：$format');
      }

      final result = await _rustApi.bookExportInfo(
        bookUrl: bookUrl,
        format: format,
      );

      return result;
    } catch (e) {
      rethrow;
    }
  }

  // ========== WebDAV 上传 ==========

  /// 将导出的文件上传到 WebDAV
  ///
  /// # 参数
  /// - `configJson`: WebDAV 配置（JSON 字符串）
  /// - `path`: 远程路径
  /// - `data`: 文件内容（base64 编码的字符串）
  ///
  /// # 返回
  /// true 表示上传成功
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

  // ========== 错误处理 ==========

  /// 检查是否为格式错误
  bool isFormatError(dynamic error) {
    if (error is String) {
      return error.contains('不支持的导出格式') ||
          error.contains('export_format');
    }
    return false;
  }

  /// 检查是否为网络错误
  bool isNetworkError(dynamic error) {
    if (error is String) {
      return error.contains('network') ||
          error.contains('connection') ||
          error.contains('timeout');
    }
    return false;
  }

  /// 检查是否为数据库错误
  bool isDatabaseError(dynamic error) {
    if (error is String) {
      return error.contains('database') ||
          error.contains('sql') ||
          error.contains('not found');
    }
    return false;
  }
}

/// 导出异常
class ExportException implements Exception {
  final String message;

  const ExportException(this.message);

  @override
  String toString() => 'ExportException: $message';
}
