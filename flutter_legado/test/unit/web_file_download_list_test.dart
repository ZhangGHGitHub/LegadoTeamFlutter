import 'dart:convert';

import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/utils/book_open_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// [批3 P1-3 UI 余项] 文件类书源（type=3）downloadUrls 接线单测
///
/// 覆盖：
/// 1. mergeWebInfo 解析 WebBookInfo.downloadUrls 数组 → Book JSON 字符串
///    落库形态（Rust Book serde `downloadUrls: Option<String>` 契约）；
/// 2. 首屏合并补全缺失 / 刷新更新式覆盖 / 缺键保留；
/// 3. 文件列表构建：URL 路径取名、作者后缀回退名、支持格式判定
///    （对齐原版 loadWebFile → WebFile(url,name) + bookFileRegex）；
/// 4. webFile 书判定（type 位 128）。
void main() {
  group('mergeWebInfo downloadUrls 接线', () {
    test('解析数组 → JSON 字符串写入 Book', () {
      final book = const Book(name: '测试书');
      final merged = BookOpenUtils.mergeWebInfo(book, jsonEncode({
        'name': '测试书',
        'toc_url': 'https://example.com/b',
        'downloadUrls': ['https://a.com/f/三国.epub', 'https://a.com/f/2.txt'],
      }));
      expect(merged.downloadUrls, isNotNull);
      final urls = BookOpenUtils.parseDownloadUrls(merged.downloadUrls);
      expect(urls, hasLength(2));
      expect(urls[0], 'https://a.com/f/三国.epub');
    });

    test('首屏合并：已有值不覆盖，缺失才补全', () {
      final existing = const Book(
        name: '测试书',
        downloadUrls: '["https://old.com/1.epub"]',
      );
      final merged = BookOpenUtils.mergeWebInfo(existing, jsonEncode({
        'name': '测试书',
        'downloadUrls': ['https://new.com/2.epub'],
      }));
      expect(BookOpenUtils.parseDownloadUrls(merged.downloadUrls),
          ['https://old.com/1.epub']);
    });

    test('刷新合并：新值非空覆盖', () {
      final existing = const Book(
        name: '测试书',
        downloadUrls: '["https://old.com/1.epub"]',
      );
      final merged = BookOpenUtils.mergeWebInfo(
        existing,
        jsonEncode({
          'name': '测试书',
          'downloadUrls': ['https://new.com/2.epub'],
        }),
        refresh: true,
      );
      expect(BookOpenUtils.parseDownloadUrls(merged.downloadUrls),
          ['https://new.com/2.epub']);
    });

    test('缺键/空数组不覆盖（null 保持原值）', () {
      final existing = const Book(
        name: '测试书',
        downloadUrls: '["https://old.com/1.epub"]',
      );
      final merged = BookOpenUtils.mergeWebInfo(
        existing,
        jsonEncode({'name': '测试书'}),
        refresh: true,
      );
      expect(merged.downloadUrls, '["https://old.com/1.epub"]');
    });
  });

  group('webFile 书判定与文件列表构建', () {
    test('type 位 128（webFile）判定', () {
      // 文件源书 = TEXT|WEB_FILE = 136（Rust book_type_of_source(FILE)）
      final webFileBook =
          const Book(name: '文件书').copyWith(bookType: 8 | 128);
      expect(BookOpenUtils.isWebFileBook(webFileBook), isTrue);
      expect(
        BookOpenUtils.isWebFileBook(const Book(name: '普通书').copyWith(
          bookType: 8,
        )),
        isFalse,
      );
    });

    test('URL 路径文件名优先（对齐 UrlUtil.getFileName 路径分支）', () {
      final book = const Book(name: '知轩藏书', author: '佚名')
          .copyWith(bookType: 136, downloadUrls: jsonEncode([
        'https://zxzj.org/d/202310/斗破苍穹.epub',
      ]));
      final files = BookOpenUtils.buildWebFileList(book);
      expect(files, hasLength(1));
      expect(files[0].name, '斗破苍穹.epub');
      expect(files[0].isSupported, isTrue);
      expect(files[0].isArchive, isFalse);
    });

    test('无路径文件名回退「书名 作者：author」（对齐 loadWebFile fallback）', () {
      final book = const Book(name: '某书', author: '某人')
          .copyWith(bookType: 136, downloadUrls: jsonEncode([
        'https://a.com/download?id=1',
      ]));
      final files = BookOpenUtils.buildWebFileList(book);
      expect(files[0].name, '某书 作者：某人');
      expect(files[0].isSupported, isFalse);
    });

    test('压缩包与不支持格式判定（对齐 bookFileRegex/archiveFileRegex）', () {
      final book = const Book(name: 'x').copyWith(bookType: 136);
      final supported = BookOpenUtils.buildWebFileEntry(
        book,
        'https://a.com/b.zip',
      );
      expect(supported.isArchive, isTrue);
      final mobi = BookOpenUtils.buildWebFileEntry(book, 'https://a.com/b.mobi');
      expect(mobi.isSupported, isTrue);
      final exe = BookOpenUtils.buildWebFileEntry(book, 'https://a.com/b.exe');
      expect(exe.isSupported, isFalse);
      expect(exe.isArchive, isFalse);
    });

    test('坏 JSON 容错返回空列表', () {
      expect(BookOpenUtils.parseDownloadUrls('not-json'), isEmpty);
      expect(BookOpenUtils.parseDownloadUrls(null), isEmpty);
      expect(BookOpenUtils.parseDownloadUrls('{"a":1}'), isEmpty);
    });
  });
}
