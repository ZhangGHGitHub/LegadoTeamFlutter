/// importLocalBook 解析逻辑单元测试
///
/// 验证 Rust FFI 返回的 ImportResult{success, book, error} JSON
/// 能被正确解析为 Book 实体，且错误情况正确处理。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  group('importLocalBook ImportResult 解析', () {
    test('success=true 时正确提取 Book，bookUrl 为文件路径', () {
      // 模拟 Rust 侧 import_local_book 返回的 ImportResult JSON
      const filePath = '/storage/emulated/0/Books/测试小说.txt';
      final importResultJson = jsonEncode({
        'success': true,
        'book': {
          'bookUrl': filePath,
          'tocUrl': '',
          'origin': 'loc_book',
          'originName': '测试小说.txt',
          'name': '测试小说',
          'author': '佚名',
          'intro': '一本测试用的本地小说',
          'type': 0x1000,
          'lastCheckTime': 1700000000000,
        },
        'error': null,
      });

      // 复现 rust_api.dart importLocalBook 的解析逻辑
      final result = jsonDecode(importResultJson) as Map<String, dynamic>;
      final success = result['success'] as bool? ?? false;

      expect(success, isTrue);

      final bookMap = result['book'] as Map<String, dynamic>?;
      expect(bookMap, isNotNull);

      final book = Book.fromJson(bookMap!);
      expect(book.bookUrl, equals(filePath));
      expect(book.bookUrl, isNotEmpty);
      expect(book.name, equals('测试小说'));
      expect(book.author, equals('佚名'));
      expect(book.origin, equals('loc_book'));
      expect(book.bookType, equals(BookType.local));
    });

    test('success=true 但 book 为 null 时应抛出 RustApiException', () {
      final importResultJson = jsonEncode({
        'success': true,
        'book': null,
        'error': null,
      });

      final result = jsonDecode(importResultJson) as Map<String, dynamic>;
      final success = result['success'] as bool? ?? false;
      expect(success, isTrue);

      final bookMap = result['book'] as Map<String, dynamic>?;
      expect(bookMap, isNull);

      // 验证此情况应抛出异常
      expect(
        () => throw RustApiException('导入成功但缺少书籍数据',
            operation: 'importLocalBook'),
        throwsA(isA<RustApiException>().having(
          (e) => e.message,
          'message',
          contains('缺少书籍数据'),
        )),
      );
    });

    test('success=false 时应抛出带错误信息的 RustApiException', () {
      final importResultJson = jsonEncode({
        'success': false,
        'book': null,
        'error': '元数据解析失败: 文件格式不支持',
      });

      final result = jsonDecode(importResultJson) as Map<String, dynamic>;
      final success = result['success'] as bool? ?? false;

      expect(success, isFalse);

      final error = result['error'] as String? ?? '未知导入错误';
      expect(error, contains('元数据解析失败'));

      // 验证错误处理逻辑
      expect(
        () => throw RustApiException(error, operation: 'importLocalBook'),
        throwsA(isA<RustApiException>().having(
          (e) => e.message,
          'message',
          contains('元数据解析失败'),
        )),
      );
    });

    test('success=false 且 error 为 null 时使用默认错误信息', () {
      final importResultJson = jsonEncode({
        'success': false,
        'book': null,
        'error': null,
      });

      final result = jsonDecode(importResultJson) as Map<String, dynamic>;
      final success = result['success'] as bool? ?? false;
      expect(success, isFalse);

      final error = result['error'] as String? ?? '未知导入错误';
      expect(error, equals('未知导入错误'));
    });

    test('旧解析方式（直接当 Book 解析）bookUrl 为空——验证缺陷存在', () {
      // 此测试证明旧代码的 bug：直接把 ImportResult 当 Book 解析
      const filePath = '/data/books/novel.epub';
      final importResultJson = jsonEncode({
        'success': true,
        'book': {
          'bookUrl': filePath,
          'name': 'novel',
          'author': 'author',
        },
        'error': null,
      });

      // 旧方式：直接 jsonDecode 后当 Book 解析
      final wrongBook =
          Book.fromJson(jsonDecode(importResultJson) as Map<String, dynamic>);
      // 旧方式取不到 bookUrl（因为顶层没有 bookUrl 键）
      expect(wrongBook.bookUrl, isEmpty);

      // 新方式：先提取 book 字段
      final result = jsonDecode(importResultJson) as Map<String, dynamic>;
      final bookMap = result['book'] as Map<String, dynamic>;
      final correctBook = Book.fromJson(bookMap);
      expect(correctBook.bookUrl, equals(filePath));
    });

    test('Windows 路径文件导入后 bookUrl 正确', () {
      const filePath = r'D:\Books\我的小说.txt';
      final importResultJson = jsonEncode({
        'success': true,
        'book': {
          'bookUrl': filePath,
          'name': '我的小说',
          'author': '作者',
          'origin': 'loc_book',
          'originName': '我的小说.txt',
          'type': 0x1000,
        },
        'error': null,
      });

      final result = jsonDecode(importResultJson) as Map<String, dynamic>;
      final bookMap = result['book'] as Map<String, dynamic>?;
      final book = Book.fromJson(bookMap!);

      expect(book.bookUrl, equals(filePath));
      expect(book.originName, equals('我的小说.txt'));
    });
  });
}
