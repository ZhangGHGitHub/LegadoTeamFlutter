// RSS 源编辑页保存返回测试（D3 回修）
//
// 缺陷：订阅源管理页用 `Navigator.push<RssSource>` 打开编辑页，但 `_save()`
// 成功后 `pop(true)`——`MaterialRouteTransitionMixin.didPop` 把结果强转
// `RssSource?` 抛 TypeError，路由卡在 popping 态（页面不返回，后续返回键
// 全部失效）。
//
// 本测试用同类型的 `Route<RssSource>` 打开编辑页，锁定：
// 1. 新建保存成功后 pop 一次，结果回传已保存的 RssSource；
// 2. 保存失败不 pop，页面停留并提示失败。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/rss_source_edit_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// addRssSource 可注入失败的 Mock（沿用 MockBookApi 其余内存实现）
class _FailingAddBookApi extends MockBookApi {
  @override
  Future<RssSource> addRssSource(RssSource source) async {
    throw StateError('模拟落库失败');
  }
}

void main() {
  /// 以「订阅源管理页」同样的强类型路由打开编辑页，返回 pop 结果
  Future<RssSource? Function()> pumpEditAndOpen(
    WidgetTester tester,
    MockBookApi api, {
    RssSource? source,
  }) async {
    RssSource? popResult;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  popResult = await Navigator.of(context).push<RssSource>(
                    MaterialPageRoute(
                      builder: (_) => RssSourceEditScreen(source: source),
                    ),
                  );
                },
                child: const Text('打开编辑页'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑页'));
    await tester.pumpAndSettle();
    expect(find.byType(RssSourceEditScreen), findsOneWidget);
    return () => popResult;
  }

  Future<void> fillFields(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextField, '源名称'), '测试订阅源');
    await tester.enterText(
      find.widgetWithText(TextField, '源 URL'),
      'https://example.com/rss.xml',
    );
    await tester.pump();
  }

  testWidgets('新建保存成功后 pop 一次并回传已保存源', (tester) async {
    final api = MockBookApi();
    final result = await pumpEditAndOpen(tester, api);
    await fillFields(tester);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // pop 一次：编辑页消失、回到入口页
    expect(find.byType(RssSourceEditScreen), findsNothing);
    expect(find.text('打开编辑页'), findsOneWidget);
    // 回传的是已保存的 RssSource（强类型路由要求，不能是 bool）
    expect(result()?.sourceName, '测试订阅源');
    expect(result()?.sourceUrl, 'https://example.com/rss.xml');
    // 数据确实落库
    final sources = await api.getRssSources();
    expect(
      sources.map((s) => s.sourceUrl),
      contains('https://example.com/rss.xml'),
    );
  });

  testWidgets('保存失败不 pop，停留编辑页并提示失败', (tester) async {
    final api = _FailingAddBookApi();
    final result = await pumpEditAndOpen(tester, api);
    await fillFields(tester);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.byType(RssSourceEditScreen), findsOneWidget);
    expect(result(), isNull);
    expect(find.textContaining('保存失败'), findsOneWidget);
  });

  /// 批28b（P2-2①）：编辑保存必须透传表单未展示的既有字段
  ///
  /// `enableReadRecord` 是原版按源阅读历史开关（无 UI 开关）、
  /// `nextContentUrl` 不在编辑表单内；`_buildSource()` 重建对象时
  /// 若漏掉透传，一次保存即静默丢字段。
  testWidgets('编辑保存保留 enableReadRecord=false 与 nextContentUrl', (tester) async {
    const url = 'https://example.com/rss-edit.xml';
    final api = MockBookApi();
    final original = RssSource(
      sourceUrl: url,
      sourceName: '旧订阅源',
      enableReadRecord: false,
      nextContentUrl: '.next@href',
    );
    await api.addRssSource(original);

    final result = await pumpEditAndOpen(tester, api, source: original);
    await tester.enterText(find.widgetWithText(TextField, '源名称'), '新订阅源');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.byType(RssSourceEditScreen), findsNothing);
    expect(result()?.sourceName, '新订阅源');
    expect(result()?.enableReadRecord, isFalse, reason: '编辑保存必须透传按源阅读记录开关');
    expect(result()?.nextContentUrl, '.next@href', reason: '编辑保存必须透传正文下一页规则');

    final saved = (await api.getRssSources()).firstWhere(
      (s) => s.sourceUrl == url,
    );
    expect(saved.enableReadRecord, isFalse);
    expect(saved.nextContentUrl, '.next@href');
  });
}
