import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/models.dart';

/// 书签导出服务（对齐原版 TocViewModel.saveBookmark / saveBookmarkMd）
///
/// [Task #40 | 2026-08-09] 台账 §5.11-5 后置项接线：零契约变更，
/// 复用现有 BookApi.getBookmarks（契约 §2.7）数据，纯 Dart 序列化 +
/// file_picker 选目录写文件 — QoderCN
///
/// - 导出书签：Bookmark 列表 jsonEncode 为 JSON 数组（字段 camelCase，
///   与原版 GSON.toJson(bookmarks) 一致，可直接被原版导入链路识别）
/// - 导出 Markdown：文本拼装模板逐行对齐原版 saveBookmarkMd
/// - 文件名对齐原版约定：`bookmark-书名 作者.json/.md`
class BookmarkExport {
  BookmarkExport._();

  /// 导出书签为 JSON 文件，返回保存后的完整路径；
  /// 用户取消目录选择时返回 null；写入失败抛异常由调用方提示
  static Future<String?> exportJson({
    required Book book,
    required List<Bookmark> bookmarks,
    String? initialDirectory,
  }) {
    // 序列化对齐原版 GSON.toJson：Bookmark 数组（camelCase 字段）。
    // [fix Task#45 | 2026-08-09] 显式构造 8 字段 Map（Min2）：剔除原版
    // Bookmark 实体字段集之外的 id（模型侧本地主键，原版主键为 time），
    // 保证导出可被原版导入链路无损识别 — QoderCN
    final content = jsonEncode(bookmarks
        .map((b) => <String, dynamic>{
              'time': b.time,
              'bookName': b.bookName,
              'bookAuthor': b.bookAuthor,
              'chapterIndex': b.chapterIndex,
              'chapterPos': b.chapterPos,
              'chapterName': b.chapterName,
              'bookText': b.bookText,
              'content': b.content,
            })
        .toList());
    return _save(
      book: book,
      extension: 'json',
      content: content,
      initialDirectory: initialDirectory,
    );
  }

  /// 导出书签为 Markdown 文件，返回保存后的完整路径；
  /// 用户取消目录选择时返回 null；写入失败抛异常由调用方提示
  static Future<String?> exportMarkdown({
    required Book book,
    required List<Bookmark> bookmarks,
    String? initialDirectory,
  }) {
    // MD 模板逐行对齐原版 TocViewModel.saveBookmarkMd
    final buffer = StringBuffer('## ${book.name} ${book.author}\n\n');
    for (final b in bookmarks) {
      buffer.write('#### ${b.chapterName}\n\n');
      buffer.write('###### 原文\n ${b.bookText}\n\n');
      buffer.write('###### 摘要\n ${b.content}\n\n');
    }
    return _save(
      book: book,
      extension: 'md',
      content: buffer.toString(),
      initialDirectory: initialDirectory,
    );
  }

  /// 选择目录并写入文件（共用流程）
  static Future<String?> _save({
    required Book book,
    required String extension,
    required String content,
    String? initialDirectory,
  }) async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择书签导出目录',
      initialDirectory:
          (initialDirectory != null && initialDirectory.isNotEmpty)
              ? initialDirectory
              : null,
    );
    // 用户取消选择
    if (dir == null) return null;
    final fileName = _buildFileName(book, extension);
    final file = File(_joinPath(dir, fileName));
    await file.writeAsString(content, flush: true);
    return file.path;
  }

  /// 文件名对齐原版约定：`bookmark-${book.name} ${book.author}.ext`，
  /// 替换文件系统非法字符避免写入失败
  ///
  /// [fix Task#45 | 2026-08-09] 清洗范围补充控制字符 \x00-\x1F（Med4）— QoderCN
  static String _buildFileName(Book book, String extension) {
    final raw = 'bookmark-${book.name} ${book.author}';
    final sanitized = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    return '$sanitized.$extension';
  }

  /// 路径拼接（兼容末尾带/不带分隔符的目录路径）
  static String _joinPath(String dir, String fileName) {
    if (dir.endsWith(Platform.pathSeparator) || dir.endsWith('/')) {
      return '$dir$fileName';
    }
    return '$dir${Platform.pathSeparator}$fileName';
  }
}
