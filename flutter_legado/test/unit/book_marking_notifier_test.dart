/// 书签标记 Notifier 测试（契约 §2.52，批7b-2a）
///
/// 覆盖：同锚点原地更新保留 id/createdAt、不同锚点新建、文本归一化、
/// 列表加载、启停/删除、修订号自增、空文本拒绝。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/book_marking/book_marking_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

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
  }) {
    return notifier().save(
      bookName: '测试书',
      bookAuthor: '作者A',
      bookUrl: 'https://src.com/book/1',
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

    expect(container.read(bookMarkingNotifierProvider), hasLength(1));
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
    expect(container.read(bookMarkingNotifierProvider), hasLength(1));

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
    expect(container.read(bookMarkingNotifierProvider), hasLength(4));
  });

  test('空选中文本（归一化后）拒绝保存', () async {
    await expectLater(
      save(selectedText: ' \u3000 \n\t '),
      throwsA(isA<FormatException>()),
    );
    expect(container.read(bookMarkingNotifierProvider), isEmpty);
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
    expect(fresh.read(bookMarkingNotifierProvider), hasLength(2));
  });

  test('setEnabled/delete 更新内存状态并自增修订号', () async {
    final saved = await save();
    final revisionBefore = container.read(bookMarkingsRevisionProvider);

    await notifier().setEnabled(saved.id, false);
    expect(container.read(bookMarkingNotifierProvider).single.enabled, isFalse);
    final revisionAfterEnable = container.read(bookMarkingsRevisionProvider);
    expect(revisionAfterEnable, greaterThan(revisionBefore));

    await notifier().delete(saved.id);
    expect(container.read(bookMarkingNotifierProvider), isEmpty);
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
}
