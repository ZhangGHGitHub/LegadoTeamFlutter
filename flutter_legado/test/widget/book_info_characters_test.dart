// [R42 阶段 2A | 2026-11-23] 书籍详情页「角色卡」区块接通回归守卫（契约 §2.56）
//
// 数据源：本地表 `book_character_profiles` → Rust `getBookCharacters` 返回
// **裸 JSON 数组**（camelCase 键），provider 解析为 `BookCharacter` 列表。
//
// UI 语义（对齐参考版 `BookInfoScreen.kt:2171-2239` `BookInfoCharacters`）：
// - 标题「角色」（我方 `AppStrings.charactersLabel`，用户裁决 D1=B）+ 横向卡片；
// - 卡片 160dp 宽、36dp 圆形占位头像（2A 不做头像）、角色中文、tags 竖线拼接；
// - `summary` / `personality` 卡片上不渲染；
// - 空数据 / 加载失败 → 区块整体不渲染（不崩、不影响主信息区）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

import '../mocks/mocks.dart';

/// 单条角色 JSON（Rust serde camelCase，契约 §2.56）
Map<String, dynamic> characterJson({
  required String id,
  required String name,
  String role = '',
  List<String> tags = const [],
  List<String> aliases = const [],
  String personality = '',
  String summary = '',
  int updatedAt = 0,
}) => {
  'id': id,
  'bookUrl': 'https://src.com/book/current',
  'name': name,
  'aliasesJson': jsonEncode(aliases),
  'avatarUri': null,
  'tagsJson': jsonEncode(tags),
  'role': role,
  'personality': personality,
  'summary': summary,
  'status': 1,
  'source': 'user',
  'confidence': 1.0,
  'schemaVersion': 1,
  'createdAt': 1000,
  'updatedAt': updatedAt,
};

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget themeWrap(Widget child) {
    return MaterialApp(
      theme: AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.wh,
      ),
      darkTheme: AppTheme.palette(
        brightness: Brightness.dark,
        palette: Md3Palettes.wh,
      ),
      themeMode: ThemeMode.light,
      home: child,
    );
  }

  /// 在线书（origin 非本地 → 详情页会请求角色卡）
  Book makeBook() => const Book(
    bookUrl: 'https://src.com/book/current',
    origin: 'https://src.com',
    originName: '测试书源',
    name: '当前书',
    author: '当前作者',
    tocUrl: 'https://src.com/toc/current',
  );

  Future<MockRustApi> pumpBookInfo(
    WidgetTester tester, {
    required Future<String> Function(String bookUrl) characters,
  }) async {
    tester.view.physicalSize = const Size(1080, 2260);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final book = makeBook();
    final mockApi = MockRustApi();
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [BookChapter(bookUrl: book.bookUrl, index: 0, title: '第一章')],
    );
    when(() => mockApi.getBooks()).thenAnswer((_) async => [book]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => '');
    when(
      () => mockApi.getBookCharacters(
        bookUrl: any(named: 'bookUrl'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (inv) async => characters(inv.namedArguments[#bookUrl]! as String),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: themeWrap(BookInfoScreen(book: book)),
      ),
    );
    await tester.pumpAndSettle();
    return mockApi;
  }

  group('角色卡区块（契约 §2.56）', () {
    testWidgets('有数据：2 个角色，姓名 / 角色中文 / tags 均渲染', (tester) async {
      final payload = jsonEncode([
        characterJson(
          id: 'c1',
          name: '林渊',
          role: 'male_lead',
          tags: ['冷静', '剑修'],
          personality: '沉稳',
          summary: '本书主角',
          updatedAt: 2000,
        ),
        characterJson(
          id: 'c2',
          name: '苏雪',
          role: 'female_lead',
          tags: ['温柔'],
          updatedAt: 1000,
        ),
      ]);
      await pumpBookInfo(tester, characters: (_) async => payload);

      // 区块与标题
      expect(find.byKey(const ValueKey('bookInfoCharacters')), findsOneWidget);
      expect(find.text('角色'), findsOneWidget);
      // 卡片内容
      expect(find.text('林渊'), findsOneWidget);
      expect(find.text('苏雪'), findsOneWidget);
      expect(find.text('男主'), findsOneWidget);
      expect(find.text('女主'), findsOneWidget);
      expect(find.text('冷静 | 剑修'), findsOneWidget);
      expect(find.text('温柔'), findsOneWidget);
      // 2A 明确：summary / personality 卡片上不渲染（参考版同样不渲染）
      expect(find.text('本书主角'), findsNothing);
      expect(find.text('沉稳'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空数据：返回 [] → 区块不出现', (tester) async {
      await pumpBookInfo(tester, characters: (_) async => '[]');

      expect(find.byKey(const ValueKey('bookInfoCharacters')), findsNothing);
      expect(find.text('角色'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('异常降级：请求抛错 → 区块不出现且不崩', (tester) async {
      await pumpBookInfo(
        tester,
        characters: (_) async => throw Exception('数据库读取失败'),
      );

      expect(find.byKey(const ValueKey('bookInfoCharacters')), findsNothing);
      expect(find.text('角色'), findsNothing);
      expect(tester.takeException(), isNull);
      // 详情页其余内容仍在（降级不得影响主信息区）
      expect(find.text('当前书'), findsWidgets);
    });
  });
}
