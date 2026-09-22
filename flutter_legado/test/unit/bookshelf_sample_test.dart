import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 书架合成脱敏样例（assets/mock_data/bookshelf_sample.json）校验
///
/// ① 样例可被 Book 模型全量解析（全部条目）；
/// ② 字段完整性抽检：必填非空 / bookType 合法位标记 / 进度三态齐备 /
///    字段分布代表性（网络书与本地书、封面有无、分组有无）；
/// ③ 脱敏护栏：样例内任何 http(s) 主机名必须为 example.com，
///    防止将来有人误贴真实书架数据。
void main() {
  // rootBundle（样例资产读取）需要 binding 先初始化（项目测试惯例）
  TestWidgetsFlutterBinding.ensureInitialized();

  const assetPath = 'assets/mock_data/bookshelf_sample.json';

  late String rawJson;
  late List<Book> books;

  setUp(() async {
    rawJson = await rootBundle.loadString(assetPath);
    final list = jsonDecode(rawJson) as List<dynamic>;
    books =
        list.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList();
  });

  group('① 样例可被模型解析', () {
    test('JSON 顶层为数组且规模在 8~12 本', () {
      final list = jsonDecode(rawJson) as List<dynamic>;
      expect(list.length, greaterThanOrEqualTo(8));
      expect(list.length, lessThanOrEqualTo(12));
    });

    test('全部条目均可解析为 Book（含必填字段非空）', () {
      final list = jsonDecode(rawJson) as List<dynamic>;
      for (final item in list) {
        expect(item, isA<Map<String, dynamic>>(),
            reason: '条目必须是 JSON 对象');
        final book = Book.fromJson(item as Map<String, dynamic>);
        expect(book.bookUrl, isNotEmpty, reason: 'bookUrl 非空');
        expect(book.name, isNotEmpty, reason: 'name 非空：${book.bookUrl}');
        expect(book.author, isNotEmpty, reason: 'author 非空：${book.name}');
      }
    });
  });

  group('② 字段完整性抽检', () {
    test('totalChapterNum 全部为正且 durChapterIndex 不越界', () {
      for (final b in books) {
        expect(b.totalChapterNum, greaterThan(0),
            reason: 'totalChapterNum>0：${b.name}');
        expect(b.durChapterIndex, greaterThanOrEqualTo(0),
            reason: 'durChapterIndex >= 0：${b.name}');
        expect(b.durChapterIndex, lessThanOrEqualTo(b.totalChapterNum - 1),
            reason: 'durChapterIndex 不越界：${b.name}');
      }
    });

    test('bookType 为合法位标记且覆盖 TEXT/IMAGE/AUDIO/LOCAL', () {
      const legal = {0, 4, 8, 16, 32, 64, 128, 1024, 4096};
      var hasText = false;
      var hasImage = false;
      var hasAudio = false;
      var hasLocal = false;
      for (final b in books) {
        expect(legal, contains(b.bookType),
            reason: 'bookType 非法位标记 ${b.bookType}：${b.name}');
        if (b.bookType & 8 != 0) hasText = true;
        if (b.bookType & 64 != 0) hasImage = true;
        if (b.bookType & 32 != 0) hasAudio = true;
        if (b.bookType & 4096 != 0) hasLocal = true;
      }
      expect(hasText, isTrue, reason: '至少一本 TEXT=8');
      expect(hasImage, isTrue, reason: '至少一本 IMAGE=64');
      expect(hasAudio, isTrue, reason: '至少一本 AUDIO=32');
      expect(hasLocal, isTrue, reason: '至少一本 LOCAL=0x1000');
    });

    test('阅读进度三态齐备（未读/在读/读完各至少一条）', () {
      var unread = 0;
      var reading = 0;
      var finished = 0;
      for (final b in books) {
        if (b.durChapterIndex == 0) {
          unread++;
        } else if (b.durChapterIndex < b.totalChapterNum - 1) {
          reading++;
        } else {
          finished++;
        }
      }
      expect(unread, greaterThanOrEqualTo(1), reason: '未读态缺失');
      expect(reading, greaterThanOrEqualTo(1), reason: '在读态缺失');
      expect(finished, greaterThanOrEqualTo(1), reason: '读完态缺失');
    });

    test('分布代表性：网络书/本地书、封面有无、分组有无', () {
      var web = 0;
      var local = 0;
      var withCover = 0;
      var withoutCover = 0;
      var ungrouped = 0;
      var grouped = 0;
      for (final b in books) {
        if (b.bookType & 4096 != 0) {
          local++;
          expect(b.canUpdate, isFalse,
              reason: '本地书不应可更新：${b.name}');
        } else {
          web++;
        }
        if ((b.coverUrl ?? '').isNotEmpty) {
          withCover++;
        } else {
          withoutCover++;
        }
        if (b.group == 0) {
          ungrouped++;
        } else {
          grouped++;
        }
      }
      expect(web, greaterThanOrEqualTo(2), reason: '网络书应有多本');
      expect(local, greaterThanOrEqualTo(2), reason: '本地书应有多本');
      expect(withCover, greaterThanOrEqualTo(1), reason: '应有带封面书');
      expect(withoutCover, greaterThanOrEqualTo(1), reason: '应有无封面书');
      expect(ungrouped, greaterThanOrEqualTo(1), reason: '应有未分组书');
      expect(grouped, greaterThanOrEqualTo(1), reason: '应有已分组书');
    });

    test('latestChapterTitle 形态：网络书有值，本地书为 null', () {
      for (final b in books) {
        final isLocal = b.bookType & 4096 != 0;
        if (isLocal) {
          expect(b.latestChapterTitle, isNull,
              reason: '本地书不应有 latestChapterTitle：${b.name}');
        } else {
          expect(b.latestChapterTitle, isNotNull,
              reason: '网络书应有 latestChapterTitle：${b.name}');
          expect(b.latestChapterTitle, isNotEmpty);
        }
      }
    });
  });

  group('③ 脱敏护栏', () {
    test('样例内任何 http(s) 主机名均为 example.com', () {
      final matches =
          RegExp(r'https?://([A-Za-z0-9.-]+)').allMatches(rawJson).toList();
      expect(matches, isNotEmpty,
          reason: '样例应含 http(s) 示例 URL 以便护栏持续生效');
      for (final m in matches) {
        expect(m.group(1)!.toLowerCase(), 'example.com',
            reason: '发现非 example.com 主机名：${m.group(0)}');
      }
    });

    test('本地书 bookUrl 仅用 file:// 协议、在线书 bookUrl 用 mock://', () {
      for (final b in books) {
        if (b.bookType & 4096 != 0) {
          expect(b.bookUrl, startsWith('file://'),
              reason: '本地书 bookUrl 应为 file://：${b.name}');
        } else {
          expect(b.bookUrl, startsWith('mock://'),
              reason: '在线书 bookUrl 应为 mock://：${b.name}');
        }
      }
    });
  });

  group('drop-in 集成（MockBookApi 消费样例）', () {
    test('MockBookApi.getBooks 返回样例全部 10 本且章节缓存就绪', () async {
      final api = MockBookApi();
      final loaded = await api.getBooks();
      expect(loaded.length, 10);
      expect(loaded.first.name, '示例书籍 01');
      expect(loaded.last.name, '示例书籍 10');
      final chapters = await api.getChapters('mock://book/1');
      expect(chapters.length, 10);
      final content = await api.getChapterContent('mock://book/1', 0);
      expect(content, contains('示例书籍 01'));
    });
  });
}
