// [批35] 书架展示标签工具单测：对齐参考版 `BookShelfItem.getDisplayTags`
// ——三项开关、逗号/换行拆分、去重、空白不展示。

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/utils/book_display_tags.dart';

void main() {
  const book = Book(
    bookUrl: 'book://tags',
    name: '标签书',
    customTag: '仙侠, 热血\n爽文,, ',
    kind: '玄幻，不是分隔符, 仙侠',
    wordCount: '123万字',
  );

  test('三项全开：自定义标签 + 书源分类（去重）+ 字数', () {
    expect(bookDisplayTags(book), ['仙侠', '热血', '爽文', '玄幻，不是分隔符', '123万字']);
  });

  test('仅自定义标签', () {
    expect(
      bookDisplayTags(book, showSourceTags: false, showWordCount: false),
      ['仙侠', '热血', '爽文'],
    );
  });

  test('仅书源分类（与自定义标签去重）', () {
    expect(
      bookDisplayTags(book, showCustomTags: false, showWordCount: false),
      ['玄幻，不是分隔符', '仙侠'],
    );
  });

  test('仅字数', () {
    expect(
      bookDisplayTags(book, showCustomTags: false, showSourceTags: false),
      ['123万字'],
    );
  });

  test('三项全关不产生标签', () {
    expect(
      bookDisplayTags(book,
          showCustomTags: false, showSourceTags: false, showWordCount: false),
      isEmpty,
    );
  });

  test('空值/空白串不展示（不渲染空标签）', () {
    const empty = Book(
      bookUrl: 'book://empty',
      name: '空标签',
      customTag: '   ',
      kind: '',
      wordCount: '   ',
    );
    expect(bookDisplayTags(empty), isEmpty);
    expect(bookDisplayTags(const Book(bookUrl: 'u', name: 'n')), isEmpty);
  });

  test('字数与已有标签重复时不重复添加', () {
    const dup = Book(
      bookUrl: 'book://dup',
      name: '重复',
      customTag: '12万字',
      wordCount: '12万字',
    );
    expect(bookDisplayTags(dup), ['12万字']);
  });

  test('自定义标签内重复项按原顺序保留（与参考版一致，仅源分类去重）', () {
    const dupCustom = Book(
      bookUrl: 'book://dup2',
      name: '重复2',
      customTag: '仙侠,仙侠',
      kind: '仙侠',
    );
    expect(bookDisplayTags(dupCustom), ['仙侠', '仙侠']);
  });
}
