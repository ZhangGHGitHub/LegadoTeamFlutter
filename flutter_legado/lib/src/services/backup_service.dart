import 'dart:convert';

import '../models/models.dart';
import 'rust_api.dart';

/// 数据备份/恢复服务
class BackupService {
  final RustApi _api;

  BackupService(this._api);

  /// 导出书架数据为 JSON
  Future<String> exportBooks() async {
    final books = await _api.getBooks();
    return jsonEncode(books.map((b) => b.toJson()).toList());
  }

  /// 导出书源数据
  Future<String> exportSources() async {
    return await _api.exportBookSources();
  }

  /// 导出选中书源为 JSON
  ///
  /// [sourceUrls] 要导出的书源 URL 列表。
  /// 返回格式化的 JSON 字符串。
  Future<String> exportSelectedSources(List<String> sourceUrls) async {
    final allSources = await _api.getBookSources();
    final selected = allSources
        .where((s) => sourceUrls.contains(s.bookSourceUrl))
        .toList();

    if (selected.isEmpty) {
      return '[]';
    }

    final jsonList = selected.map((s) => s.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(jsonList);
  }

  /// 导出全部书源为格式化 JSON
  Future<String> exportAllSourcesFormatted() async {
    final allSources = await _api.getBookSources();
    final jsonList = allSources.map((s) => s.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(jsonList);
  }

  /// 导入书源数据，返回导入数量
  Future<int> importSources(String json) async {
    return await _api.importBookSources(json);
  }

  /// 完整备份（书籍 + 书源 + 元信息）
  Future<String> fullBackup() async {
    final books = await exportBooks();
    final sources = await exportSources();
    return jsonEncode({
      'version': 1,
      'timestamp': DateTime.now().toIso8601String(),
      'books': books,
      'sources': sources,
    });
  }

  /// 解析完整备份，返回备份元信息和载荷
  Future<Map<String, dynamic>> parseBackup(String backupJson) async {
    final data = jsonDecode(backupJson) as Map<String, dynamic>;
    return data;
  }

  /// 从备份恢复书源
  Future<int> restoreSourcesFromBackup(String backupJson) async {
    final data = await parseBackup(backupJson);
    final sources = data['sources'] as String? ?? '[]';
    return await importSources(sources);
  }

  /// 将书源列表序列化为 JSON
  String serializeSources(List<BookSource> sources) {
    final jsonList = sources.map((s) => s.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(jsonList);
  }
}
