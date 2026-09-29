// [P4-2b V4] 书架视频分组（对齐原版 IdVideo 聚合语义）
//
// 原版依据：
// - `BookGroup.kt:39` `IdVideo = -6`（groupId 常量）
// - `AppDatabase.kt:241-244` DB 初始化种子「视频」组（order=-5, show=1）
// - `BookGroupDao.kt:36` show 查询：视频组仅当存在视频书时出现在分组列表
//   （`groupId = -6 and exists (select 1 from books where type & video > 0)`）
// - `BookshelfGroupItem.kt:61` 组内过滤：`IdVideo -> isVideo`（type & video > 0）
//
// 我方 book_groups 表无视频组行（Rust 无种子），由 Notifier 在数据层合成：
// 有视频书 → groups 补「视频」组；无视频书 → 不出现（空组不展示，对齐原版
// show 查询的动态显隐）。组内书籍过滤由 BookshelfStateGrouping.currentGroupBooks
// 既有 `BookGroupId.video` 分支完成（bookshelf_state.dart:81-82）。

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  // 测试数据：视频书（bookType 含 video 位）与非视频书
  const videoBook = Book(
    name: '测试视频',
    bookUrl: 'video://1',
    bookType: BookType.video,
  );
  const videoBook2 = Book(
    name: '测试视频2',
    bookUrl: 'video://2',
    bookType: BookType.video,
  );
  const textBook = Book(name: '测试小说', bookUrl: 'book://t1');

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    // 默认：无自定义分组、无视频书
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    when(() => mockApi.getBooks()).thenAnswer((_) async => [textBook]);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 等待 build() 中的异步初始化（_loadSettings/_loadBooks/_loadGroups）完成
  Future<void> pumpInit() async {
    container.read(bookshelfNotifierProvider);
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  BookshelfState readState() => container.read(bookshelfNotifierProvider);
  BookshelfNotifier readNotifier() =>
      container.read(bookshelfNotifierProvider.notifier);

  /// 当前 groups 中的视频组（groupId == -6）数量
  int videoGroupCount() =>
      readState().groups.where((g) => g.groupId == BookGroupId.video).length;

  group('书架视频分组（P4-2b V4）', () {
    test('视频书归入视频聚合分组：有视频书时 groups 出现「视频」组', () async {
      when(() => mockApi.getBooks())
          .thenAnswer((_) async => [videoBook, textBook]);

      await pumpInit();

      final groups = readState().groups;
      expect(videoGroupCount(), equals(1));
      final videoGroup =
          groups.firstWhere((g) => g.groupId == BookGroupId.video);
      expect(videoGroup.groupName, equals('视频'));
      expect(videoGroup.show, isTrue);
      // 组列表含「全部」+「视频」→ 顶栏出现 Tab（对齐原版 show 查询结果）
      expect(readState().hasGroupTabs, isTrue);
      // 「全部」组置顶（对齐原版种子 order=-10 早于视频组 order=-5）
      expect(
        groups.map((g) => g.groupName).toList(),
        containsAll(['全部', '视频']),
      );
    });

    test('非视频书不触发视频分组（空组形态：无视频书则无「视频」Tab）', () async {
      // getBooks 默认仅 textBook
      await pumpInit();

      expect(videoGroupCount(), equals(0));
      expect(readState().groups.map((g) => g.groupName).toList(), equals(['全部']));
      // 仅「全部」一组 → 不显示 TabBar（既有 hasGroupTabs 语义）
      expect(readState().hasGroupTabs, isFalse);
    });

    test('视频组内过滤：非视频书不入视频组（对齐原版 isVideo 位判定）', () async {
      when(() => mockApi.getBooks())
          .thenAnswer((_) async => [videoBook, textBook]);

      await pumpInit();

      final videoIndex = readState()
          .groups
          .indexWhere((g) => g.groupId == BookGroupId.video);
      expect(videoIndex, greaterThanOrEqualTo(0));
      await readNotifier().selectGroup(videoIndex);

      final names = readState().currentGroupBooks.map((b) => b.name).toList();
      expect(names, equals(['测试视频']));
      expect(names, isNot(contains('测试小说')));
    });

    test('幂等：数据源已含视频组行时不重复补组', () async {
      when(() => mockApi.getBooks())
          .thenAnswer((_) async => [videoBook]);
      when(() => mockApi.getBookGroups()).thenAnswer(
        (_) async => [
          const BookGroup(
            groupId: BookGroupId.video,
            groupName: '视频',
            order: -5,
          ),
        ],
      );

      await pumpInit();

      expect(videoGroupCount(), equals(1));
      expect(readState().groups, hasLength(2)); // 全部 + 视频
    });

    test('addBook 添加视频书后视频组立即出现', () async {
      // 初始仅非视频书 → 无视频组
      await pumpInit();
      expect(videoGroupCount(), equals(0));

      when(() => mockApi.addBook(any())).thenAnswer((_) async => videoBook);
      final ok = await readNotifier().addBook(videoBook);
      expect(ok, isTrue);

      expect(videoGroupCount(), equals(1));
      expect(
        readState().currentGroupBooks.map((b) => b.name).toList(),
        contains('测试视频'),
      );
    });

    test('removeBook 删尽视频书后视频组消失（对齐原版 show 查询动态隐藏）',
        () async {
      when(() => mockApi.getBooks())
          .thenAnswer((_) async => [videoBook, textBook]);
      await pumpInit();
      expect(videoGroupCount(), equals(1));

      when(() => mockApi.deleteBook('video://1')).thenAnswer((_) async {});
      final ok = await readNotifier().removeBook('video://1');
      expect(ok, isTrue);

      // 剩余 books 中无视频书 → 视频组被移除
      expect(videoGroupCount(), equals(0));
      expect(readState().groups.map((g) => g.groupName).toList(), equals(['全部']));
    });

    test('仍有视频书时视频组保留', () async {
      when(() => mockApi.getBooks())
          .thenAnswer((_) async => [videoBook, videoBook2, textBook]);
      await pumpInit();
      expect(videoGroupCount(), equals(1));

      when(() => mockApi.deleteBook('video://1')).thenAnswer((_) async {});
      await readNotifier().removeBook('video://1');

      // videoBook2 仍在 → 视频组保留
      expect(videoGroupCount(), equals(1));
      final videoIndex = readState()
          .groups
          .indexWhere((g) => g.groupId == BookGroupId.video);
      await readNotifier().selectGroup(videoIndex);
      expect(
        readState().currentGroupBooks.map((b) => b.name).toList(),
        equals(['测试视频2']),
      );
    });
  });
}
