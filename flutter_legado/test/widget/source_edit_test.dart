// 书源编辑页 widget 测试
//
// 验证 Phase 5.1 书源编辑表单（对标 Android BookSourceEditActivity）：
// - [B2-C2 2-8] 扁平单列结构（对齐参考版 ref 09）：设置段 + 7 个规则
//   分组段（基本信息/搜索规则/发现规则/详情规则/目录规则/正文规则/
//   段评规则）同列顺序展开，无 Tab 页签与字段导航条
// - 各分组的字段与设置开关可见
// - 必填校验（书源名称/URL）与保存创建
// - 编辑模式回填发现/详情/评论规则
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/source/source_notifier.dart';
import 'package:flutter_legado/src/screens/source_edit_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 在底层页面上 push 书源编辑页，便于验证保存后的返回行为
  Future<void> pumpEdit(WidgetTester tester, {String? sourceUrl}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SourceEditScreen(sourceUrl: sourceUrl),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('SourceEditScreen 扁平单列结构', () {
    testWidgets('新建模式渲染 7 个规则分组段（扁平单列，调试为顶栏菜单）',
        (tester) async {
      // 加高可视区域，确保单滚动列内全部分组段标题完整构建
      await tester.binding.setSurfaceSize(const Size(800, 8000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpEdit(tester);

      expect(find.text('新建书源'), findsOneWidget);
      // [B2-C2 2-8] 取消 Tab 页签：7 个规则分组段以标题 Text 同列顺序展开
      for (final title in const [
        '基本信息',
        '搜索规则',
        '发现规则',
        '详情规则',
        '目录规则',
        '正文规则',
        '段评规则',
      ]) {
        expect(
          find.text(title),
          findsOneWidget,
          reason: '应包含「$title」分组段',
        );
      }
    });

    testWidgets('顶部设置段展示开关，各分组展示对应字段', (tester) async {
      // 加高可视区域，确保单滚动列内各分组字段完整构建
      await tester.binding.setSurfaceSize(const Size(800, 8000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpEdit(tester);

      // 设置段默认收起（优先展示表单字段）；展开后可见开关
      expect(find.text('设置'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('CookieJar'), findsOneWidget);
      expect(find.text('事件监听'), findsOneWidget);
      expect(find.text('定制按钮'), findsOneWidget);

      // [B2-C2 2-8] 扁平单列：各分组字段同列共存，无需切 Tab，直接断言。
      // 标签已上移为常显 Text，字段改以 ValueKey('sf_<field.key>') 稳定定位。
      expect(find.byKey(const ValueKey('sf_exploreUrl')), findsOneWidget);
      expect(find.byKey(const ValueKey('sf_i_tocUrl')), findsOneWidget);
      expect(find.byKey(const ValueKey('sf_i_canReName')), findsOneWidget);
      expect(find.byKey(const ValueKey('sf_r_reviewSummaryUrl')),
          findsOneWidget);
    });
  });

  group('SourceEditScreen 校验与保存', () {
    testWidgets('必填字段为空时阻止保存并提示', (tester) async {
      await pumpEdit(tester);

      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();

      expect(find.text('请输入源名称（sourceName）'), findsOneWidget);
      expect(find.text('请输入源 URL（sourceUrl）'), findsOneWidget);
      verifyNever(() => mockApi.addBookSource(any()));
    });

    testWidgets('填写名称与 URL 后保存成功创建书源', (tester) async {
      when(
        () => mockApi.addBookSource(any()),
      ).thenAnswer((inv) async => inv.positionalArguments[0] as BookSource);
      await pumpEdit(tester);

      // 标签已上移为常显 Text，字段改以 ValueKey('sf_<field.key>') 稳定定位。
      await tester.enterText(
        find.byKey(const ValueKey('sf_bookSourceName')),
        '测试书源',
      );
      await tester.enterText(
        find.byKey(const ValueKey('sf_bookSourceUrl')),
        'https://test.com',
      );
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();

      expect(find.text('书源已创建'), findsOneWidget);
      final captured =
          verify(() => mockApi.addBookSource(captureAny())).captured.single
              as BookSource;
      expect(captured.bookSourceName, '测试书源');
      expect(captured.bookSourceUrl, 'https://test.com');
      // 保存后返回上一页
      expect(find.byType(SourceEditScreen), findsNothing);
    });
  });

  group('SourceEditScreen 编辑模式回填', () {
    testWidgets('回填发现/详情/评论规则字段与开关', (tester) async {
      // 加高可视区域，确保单滚动列内全部分组字段（含末段段评）完整构建
      await tester.binding.setSurfaceSize(const Size(800, 8000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const source = BookSource(
        bookSourceUrl: 'https://edit.com',
        bookSourceName: '可编辑源',
        exploreUrl: '分类::https://edit.com/sort',
        ruleExplore: ExploreRule(bookList: '.explore-list', name: '.e-name'),
        ruleBookInfo: BookInfoRule(init: '.init', tocUrl: '.toc'),
        ruleReview: ReviewRule(enabled: true, reviewSummaryUrl: '.review-summary'),
      );
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [source]);
      // 预加载书源到 notifier 状态
      await container.read(sourceNotifierProvider.notifier).loadSources();

      await pumpEdit(tester, sourceUrl: 'https://edit.com');

      // 标题为编辑模式
      expect(find.text('编辑书源'), findsOneWidget);
      // 基本信息回填
      expect(find.text('可编辑源'), findsOneWidget);

      // [B2-C2 2-8] 扁平单列：发现/详情/段评规则字段同列共存，直接断言回填
      expect(find.text('分类::https://edit.com/sort'), findsOneWidget);
      expect(find.text('.explore-list'), findsOneWidget);
      expect(find.text('.init'), findsOneWidget);
      expect(find.text('.toc'), findsOneWidget);
      expect(find.text('.review-summary'), findsOneWidget);
      // 段评开关在顶部设置段（CheckboxListTile）并回填为开启；
      // 段默认收起，先展开再断言
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final reviewCheck = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '段评'),
      );
      expect(reviewCheck.value, isTrue);
    });
  });
}
