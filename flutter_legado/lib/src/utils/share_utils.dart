import '../models/models.dart';

/// 构建书籍分享文案（对齐 Android 原版：书名 + 作者 + 来源）
///
/// 纯函数，无副作用，便于单元测试。
String buildBookShareText(Book book) {
  final buffer = StringBuffer('《${book.name}》');
  if (book.author.isNotEmpty) {
    buffer.write(' 作者：${book.author}');
  }
  if (book.bookUrl.isNotEmpty) {
    buffer.write('\n来源：${book.bookUrl}');
  }
  return buffer.toString();
}
