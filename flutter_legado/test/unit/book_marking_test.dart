/// 书签标记单元测试（契约 §2.52，批7b-1）
///
/// 覆盖：模型 fromJson 缺省/toJson 往返/copyWith 可空字段显式清空；
/// MockBookApi 内存 CRUD、排序（chapterIndex 升序 + createdAt 升序）、
/// 保存补 UUID/时间戳、启停/删除 no-op、空锚点报错、实例隔离。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

BookMarking _marking({
  String id = '',
  String bookUrl = 'https://a/book',
  String bookName = '标记测试书',
  String bookAuthor = '测试作者',
  int? chapterIndex = 0,
  int createdAt = 0,
}) {
  return BookMarking(
    id: id,
    bookUrl: bookUrl,
    bookName: bookName,
    bookAuthor: bookAuthor,
    chapterIndex: chapterIndex,
    anchorJson: '{"start":1,"end":3}',
    styleJson: '{"textColor":-1}',
    note: '备注',
    chapterName: '第一章',
    createdAt: createdAt,
  );
}

void main() {
  group('BookMarking 模型', () {
    test('fromJson 缺键默认值：enabled=true、chapterIndex/styleJson=null', () {
      final marking = BookMarking.fromJson(const {});
      expect(marking.id, '');
      expect(marking.bookUrl, '');
      expect(marking.anchorJson, '');
      expect(marking.chapterIndex, isNull);
      expect(marking.styleJson, isNull);
      expect(marking.enabled, isTrue, reason: 'enabled 缺键默认 true');
      expect(marking.createdAt, 0);
      expect(marking.updatedAt, 0);
    });

    test('toJson/fromJson 往返保真（camelCase 键名）', () {
      final original = _marking(
        id: 'm1',
        chapterIndex: null,
        createdAt: 100,
      ).copyWith(updatedAt: 200, enabled: false);

      final json = original.toJson();
      expect(json.keys, containsAll(<String>[
        'id',
        'bookUrl',
        'bookName',
        'bookAuthor',
        'chapterIndex',
        'anchorJson',
        'styleJson',
        'note',
        'chapterName',
        'enabled',
        'createdAt',
        'updatedAt',
      ]));

      final back = BookMarking.fromJson(json);
      expect(back.id, original.id);
      expect(back.bookUrl, original.bookUrl);
      expect(back.bookName, original.bookName);
      expect(back.bookAuthor, original.bookAuthor);
      expect(back.chapterIndex, isNull);
      expect(back.anchorJson, original.anchorJson);
      expect(back.styleJson, original.styleJson);
      expect(back.note, original.note);
      expect(back.chapterName, original.chapterName);
      expect(back.enabled, isFalse);
      expect(back.createdAt, 100);
      expect(back.updatedAt, 200);
    });

    test('copyWith 可空字段：不传保留，显式 null 清空', () {
      final base = _marking(chapterIndex: 3).copyWith(
        styleJson: '{"fill":1}',
      );
      final kept = base.copyWith(note: '新备注');
      expect(kept.chapterIndex, 3);
      expect(kept.styleJson, '{"fill":1}');
      expect(kept.note, '新备注');

      final cleared = base.copyWith(chapterIndex: null, styleJson: null);
      expect(cleared.chapterIndex, isNull);
      expect(cleared.styleJson, isNull);
    });
  });

  group('MockBookApi 书签标记（契约 §2.52）', () {
    late MockBookApi api;

    setUp(() => api = MockBookApi());

    test('save：空 id 生成唯一标识，createdAt<=0 补时间，updatedAt=now', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final saved = await api.saveBookMarking(_marking());
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(saved.id, isNotEmpty, reason: '空 id 应生成标识');
      expect(saved.createdAt, greaterThanOrEqualTo(before));
      expect(saved.createdAt, lessThanOrEqualTo(after));
      expect(saved.updatedAt, greaterThanOrEqualTo(before));
      expect(saved.updatedAt, lessThanOrEqualTo(after));
      expect(saved.enabled, isTrue);

      // 同 id 再次保存：id/createdAt 保留，updatedAt 重写
      final updated = await api.saveBookMarking(
        saved.copyWith(note: '更新备注', createdAt: 1, updatedAt: 1),
      );
      expect(updated.id, saved.id);
      expect(updated.createdAt, 1, reason: '显式 createdAt>0 予以保留');
      expect(updated.note, '更新备注');
      expect(updated.updatedAt, greaterThanOrEqualTo(saved.updatedAt));

      final listed = await api.getBookMarkingsByBook('标记测试书', '测试作者');
      expect(listed, hasLength(1));
      expect(listed.single.note, '更新备注');
    });

    test('getBookMarkingsByBook：chapterIndex 升序（NULL 在前）、createdAt 升序', () async {
      final late = await api.saveBookMarking(
        _marking(id: 'late', chapterIndex: 0, createdAt: 300),
      );
      final early = await api.saveBookMarking(
        _marking(id: 'early', chapterIndex: 0, createdAt: 200),
      );
      final nullChapter = await api.saveBookMarking(
        _marking(id: 'global', chapterIndex: null, createdAt: 400),
      );
      // 同名不同作者不混入
      await api.saveBookMarking(
        _marking(id: 'other-author', bookAuthor: '另一作者'),
      );

      final list = await api.getBookMarkingsByBook('标记测试书', '测试作者');
      expect(
        list.map((m) => m.id).toList(),
        [nullChapter.id, early.id, late.id],
      );
      expect(
        await api.getBookMarkingsByBook('标记测试书', '不存在'),
        isEmpty,
      );
    });

    test('getBookMarkingsForChapter：Some 含 NULL 章节，None 全书', () async {
      final c1 = await api.saveBookMarking(
        _marking(id: 'c1', chapterIndex: 1, createdAt: 100),
      );
      final c2 = await api.saveBookMarking(
        _marking(id: 'c2', chapterIndex: 2, createdAt: 200),
      );
      final global = await api.saveBookMarking(
        _marking(id: 'global', chapterIndex: null, createdAt: 300),
      );
      final otherSource = await api.saveBookMarking(
        _marking(id: 'other', bookUrl: 'https://b/book', chapterIndex: 1),
      );

      final chapter1 = await api.getBookMarkingsForChapter(
        'https://a/book',
        1,
      );
      expect(chapter1.map((m) => m.id).toList(), [c1.id, global.id]);
      expect(chapter1.any((m) => m.id == c2.id), isFalse);
      expect(chapter1.any((m) => m.id == otherSource.id), isFalse);

      final all = await api.getBookMarkingsForChapter('https://a/book', null);
      expect(all.map((m) => m.id).toList(), [c1.id, c2.id, global.id]);

      final noneFor9 = await api.getBookMarkingsForChapter(
        'https://a/book',
        9,
      );
      expect(noneFor9.map((m) => m.id).toList(), [global.id]);
    });

    test('setEnabled/delete：存在生效，不存在 no-op', () async {
      final saved = await api.saveBookMarking(_marking());

      await api.setBookMarkingEnabled(saved.id, false);
      var listed = await api.getBookMarkingsForChapter('https://a/book', 0);
      expect(listed.single.enabled, isFalse);
      expect(
        listed.single.updatedAt,
        greaterThanOrEqualTo(saved.updatedAt),
      );

      await api.setBookMarkingEnabled('不存在', true); // no-op 不抛错

      await api.deleteBookMarking(saved.id);
      expect(await api.getBookMarkingsForChapter('https://a/book', null), isEmpty);
      await api.deleteBookMarking('不存在'); // no-op 不抛错
    });

    test('空 anchorJson 报 BridgeError（对齐 Rust 参数错误）', () async {
      await expectLater(
        api.saveBookMarking(_marking().copyWith(anchorJson: '   ')),
        throwsA(
          isA<BridgeError>().having(
            (e) => e.message,
            'message',
            contains('anchorJson 不能为空'),
          ),
        ),
      );
    });

    test('实例隔离：新建 MockBookApi 自带空标记列表', () async {
      await api.saveBookMarking(_marking());
      final fresh = MockBookApi();
      expect(
        await fresh.getBookMarkingsByBook('标记测试书', '测试作者'),
        isEmpty,
      );
    });
  });
}
