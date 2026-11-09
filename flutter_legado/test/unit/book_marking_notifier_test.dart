/// 书签标记 Notifier 测试（契约 §2.52，批7b-2a）
///
/// 覆盖：同锚点原地更新保留 id/createdAt、不同锚点新建、文本归一化、
/// 列表加载、启停/删除、修订号自增、空文本拒绝。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/book_marking/book_marking_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 指定书名的加载恒失败（P2-3 切书不残留测试）
class _FailingBookApi extends MockBookApi {
  _FailingBookApi({required this.failBookName});

  final String failBookName;
  bool fail = true;

  @override
  Future<List<BookMarking>> getBookMarkingsByBook(
    String bookName,
    String bookAuthor,
  ) {
    if (fail && bookName == failBookName) {
      throw const BridgeError(message: 'B 书加载失败');
    }
    return super.getBookMarkingsByBook(bookName, bookAuthor);
  }
}

/// A 书请求挂起、B 书立即返回（P2-3 乱序完成测试）
class _OutOfOrderBookApi extends MockBookApi {
  _OutOfOrderBookApi({required this.bookBMarkings});

  final List<BookMarking> bookBMarkings;
  final Completer<List<BookMarking>> bookA = Completer();

  @override
  Future<List<BookMarking>> getBookMarkingsByBook(
    String bookName,
    String bookAuthor,
  ) {
    if (bookName == 'A书') return bookA.future;
    return Future.value(bookBMarkings);
  }
}

void main() {
  late MockBookApi api;
  late ProviderContainer container;

  setUp(() {
    api = MockBookApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  });

  BookMarkingNotifier notifier() =>
      container.read(bookMarkingNotifierProvider.notifier);

  Future<BookMarking> save({
    String selectedText = '选中文本',
    int chapterIndex = 0,
    int chapterPosition = 10,
    String note = '',
    String chapterName = '第一章',
    String bookName = '测试书',
    String bookAuthor = '作者A',
    String bookUrl = 'https://src.com/book/1',
  }) {
    return notifier().save(
      bookName: bookName,
      bookAuthor: bookAuthor,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      chapterName: chapterName,
      chapterPosition: chapterPosition,
      selectedText: selectedText,
      style: MarkingEffect.wave.toStyle(0xFF22C55E),
      note: note,
      contextBefore: '前文',
      contextAfter: '后文',
    );
  }

  test('新建：Rust 生成 id，锚点写入归一化文本与哈希', () async {
    final saved = await save(selectedText: '  选中\n文本  ', note: '备注');
    expect(saved.id, isNotEmpty);
    expect(saved.createdAt, greaterThan(0));
    expect(saved.updatedAt, greaterThan(0));
    expect(saved.enabled, isTrue);
    expect(saved.note, '备注');

    final anchor = BookMarkingAnchor.tryParse(saved.anchorJson)!;
    expect(anchor.chapterIndex, 0);
    expect(anchor.chapterPosition, 10);
    expect(anchor.selectedText, '选中\n文本');
    expect(anchor.normalizedTextHash, markingTextHash('选中\n文本'));
    expect(anchor.contextBefore, '前文');
    expect(anchor.contextAfter, '后文');

    final style = BookMarkingStyle.tryParse(saved.styleJson)!;
    expect(style.underlineMode, 3);
    expect(style.underlineColor, 0xFF22C55E);

    expect(container.read(bookMarkingNotifierProvider).items, hasLength(1));
  });

  test('同锚点再次保存：原地更新，保留 id/createdAt，enabled=true', () async {
    final first = await save(note: '旧备注');
    // 先停用，验证保存后重新启用
    await notifier().setEnabled(first.id, false);

    final second = await save(note: '新备注', chapterName: '第一章');
    expect(second.id, first.id);
    expect(second.createdAt, first.createdAt, reason: 'createdAt 不得重置');
    expect(second.updatedAt, greaterThanOrEqualTo(first.updatedAt));
    expect(second.note, '新备注');
    expect(second.enabled, isTrue);
    expect(container.read(bookMarkingNotifierProvider).items, hasLength(1));

    final listed = await api.getBookMarkingsByBook('测试书', '作者A');
    expect(listed, hasLength(1));
    expect(listed.single.note, '新备注');
  });

  test('不同章节/位置/文本 → 新建独立标记', () async {
    final a = await save();
    final b = await save(chapterIndex: 1);
    final c = await save(chapterPosition: 99);
    final d = await save(selectedText: '另一段文本');

    expect({a.id, b.id, c.id, d.id}, hasLength(4));
    expect(container.read(bookMarkingNotifierProvider).items, hasLength(4));
  });

  test('空选中文本（归一化后）拒绝保存', () async {
    await expectLater(
      save(selectedText: ' \u3000 \n\t '),
      throwsA(isA<FormatException>()),
    );
    expect(container.read(bookMarkingNotifierProvider).items, isEmpty);
  });

  test('loadByBook 加载并替换内存列表', () async {
    await save(note: 'A');
    await save(selectedText: '第二段', note: 'B');

    final fresh = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(fresh.dispose);
    await fresh
        .read(bookMarkingNotifierProvider.notifier)
        .loadByBook('测试书', '作者A');
    expect(fresh.read(bookMarkingNotifierProvider).items, hasLength(2));
  });

  test('setEnabled/delete 更新内存状态并自增修订号', () async {
    final saved = await save();
    final revisionBefore = container.read(bookMarkingsRevisionProvider);

    await notifier().setEnabled(saved.id, false);
    expect(
      container.read(bookMarkingNotifierProvider).items.single.enabled,
      isFalse,
    );
    final revisionAfterEnable = container.read(bookMarkingsRevisionProvider);
    expect(revisionAfterEnable, greaterThan(revisionBefore));

    await notifier().delete(saved.id);
    expect(container.read(bookMarkingNotifierProvider).items, isEmpty);
    expect(
      container.read(bookMarkingsRevisionProvider),
      greaterThan(revisionAfterEnable),
    );

    // Rust/Mock no-op：不存在 id 不抛错
    await notifier().setEnabled('不存在', true);
    await notifier().delete('不存在');
  });

  test('listForChapter 透传章节过滤（含 chapterIndex IS NULL）', () async {
    final c0 = await save(chapterIndex: 0);
    final c1 = await save(chapterIndex: 1);
    final global = await save(chapterIndex: -1);
    // 把 global 改成 chapterIndex=null（直接经 API 覆盖）
    await api.saveBookMarking(global.copyWith(chapterIndex: null));

    final list = await notifier().listForChapter('https://src.com/book/1', 0);
    final ids = list.map((m) => m.id).toSet();
    expect(ids.contains(c0.id), isTrue);
    expect(ids.contains(c1.id), isFalse);
    expect(list.any((m) => m.chapterIndex == null), isTrue);
  });

  test('P2-5 换源保存：既有行 bookUrl 不被改写', () async {
    final first = await save(bookUrl: 'https://a.com/book/1');
    final second = await save(bookUrl: 'https://b.com/book/2');
    expect(second.id, first.id);
    expect(second.bookUrl, 'https://a.com/book/1');
    final listed = await api.getBookMarkingsByBook('测试书', '作者A');
    expect(listed.single.bookUrl, 'https://a.com/book/1');
  });

  test('P2-6 findExisting 命中同锚点（归一化）', () async {
    final saved = await save(note: '旧备注', selectedText: '选中文本');
    final found = await notifier().findExisting(
      bookName: '测试书',
      bookAuthor: '作者A',
      chapterIndex: 0,
      chapterPosition: 10,
      selectedText: '  选中文本  ',
    );
    expect(found?.id, saved.id);
    expect(found?.note, '旧备注');

    final miss = await notifier().findExisting(
      bookName: '测试书',
      bookAuthor: '作者A',
      chapterIndex: 0,
      chapterPosition: 11,
      selectedText: '选中文本',
    );
    expect(miss, isNull);
  });

  test('P2-3 切书加载失败：清空旧书列表且状态标为失败', () async {
    final failingApi = _FailingBookApi(failBookName: 'B书');
    final failingContainer = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(failingApi)],
    );
    addTearDown(failingContainer.dispose);
    final failingNotifier = failingContainer.read(
      bookMarkingNotifierProvider.notifier,
    );

    // A 书先有数据
    await failingApi.saveBookMarking(
      BookMarking(
        bookUrl: 'https://a.com/book/1',
        bookName: 'A书',
        bookAuthor: '作者A',
        chapterIndex: 0,
        anchorJson: buildBookMarkingAnchor(
          chapterIndex: 0,
          chapterPosition: 0,
          selectedText: 'A 文本',
        ).encode(),
        styleJson: MarkingEffect.solid.toStyle(0xFF22C55E).encode(),
      ),
    );
    await failingNotifier.loadByBook('A书', '作者A');
    expect(
      failingContainer.read(bookMarkingNotifierProvider).items,
      hasLength(1),
    );

    await expectLater(
      failingNotifier.loadByBook('B书', '作者A'),
      throwsA(isA<BridgeError>()),
    );
    final state = failingContainer.read(bookMarkingNotifierProvider);
    expect(state.items, isEmpty, reason: '不得残留 A 书标记');
    expect(state.bookName, 'B书');
    expect(state.loaded, isFalse);
    expect(state.error, contains('B 书加载失败'));
    expect(state.isFor('A书', '作者A'), isFalse);

    // 重试成功清除陈旧 error（避免错误页残留）
    failingApi.fail = false;
    await failingNotifier.loadByBook('B书', '作者A');
    final recovered = failingContainer.read(bookMarkingNotifierProvider);
    expect(recovered.error, isNull);
    expect(recovered.loaded, isTrue);
  });

  test('P2-3 乱序：A 慢、B 先完成、A 迟到不覆盖 B', () async {
    final outOfOrderApi = _OutOfOrderBookApi(
      bookBMarkings: [
        BookMarking(
          id: 'b1',
          bookUrl: 'https://b.com/book/1',
          bookName: 'B书',
          bookAuthor: '作者A',
          chapterIndex: 0,
          anchorJson: buildBookMarkingAnchor(
            chapterIndex: 0,
            chapterPosition: 0,
            selectedText: 'B 文本',
          ).encode(),
          styleJson: MarkingEffect.solid.toStyle(0xFF22C55E).encode(),
        ),
      ],
    );
    final outOfOrderContainer = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(outOfOrderApi)],
    );
    addTearDown(outOfOrderContainer.dispose);
    final outOfOrderNotifier = outOfOrderContainer.read(
      bookMarkingNotifierProvider.notifier,
    );

    final slowA = outOfOrderNotifier.loadByBook('A书', '作者A');
    await outOfOrderNotifier.loadByBook('B书', '作者A');
    expect(
      outOfOrderContainer.read(bookMarkingNotifierProvider).items,
      hasLength(1),
    );

    outOfOrderApi.bookA.complete([
      BookMarking(
        id: 'a1',
        bookUrl: 'https://a.com/book/1',
        bookName: 'A书',
        bookAuthor: '作者A',
        chapterIndex: 0,
        anchorJson: buildBookMarkingAnchor(
          chapterIndex: 0,
          chapterPosition: 0,
          selectedText: 'A 文本',
        ).encode(),
        styleJson: MarkingEffect.solid.toStyle(0xFF22C55E).encode(),
      ),
    ]);
    await slowA;

    final state = outOfOrderContainer.read(bookMarkingNotifierProvider);
    expect(state.bookName, 'B书');
    expect(state.items.single.id, 'b1', reason: 'A 迟到结果不得覆盖 B');
  });
}
