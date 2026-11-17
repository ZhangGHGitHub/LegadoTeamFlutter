// 书源编辑保存「规则对象非表单字段被抹掉」回归测试（P1 缺陷 2）
//
// 设备症状：编辑 `ruleSearch.name = "$.name\n@js:...result"` 的源，只改源名后
// 保存 → DB 中 `ruleSearch.name` 退化为 `"$.name"`（`@js:` 后缀丢失），
// 随后搜索报 `JS engine error: source is not defined`。
//
// 根因链（本文件钉死）：
// 1. `_buildSource()` 用表单值**整体重建**规则对象（SearchRule/TocRule/...），
//    规则对象里每个建模字段都会被写入载荷；
// 2. 保存层 `patchSourceJson` 对 Map 递归深合，但「编辑值存在即覆盖」——
//    因此**表单里显示什么，库内就写什么**；
// 3. 表单内容来自 `_populateFields(source)`，而 `source` 可能来自
//    调用方传入 / notifier 内存列表中的**过期对象**（导入、备份恢复、
//    发现页旧缓存等都会留下过期副本）。过期副本里 `@js:` 已不在，
//    保存即把库内真实值覆盖掉。
//
// 修复：回填一律以「权威数据源」为准（原始 JSON 缓存 → `getBookSources()`
// 现拉 → 调用方传入的兜底），且仅当表单未被用户改动时才允许校正；
// 同时 `_buildSource()` 改为「以原稿规则对象为基底，只覆盖表单实际编辑过的
// 字段」，保证未编辑字段永远按原值保存。
//
// 编写：全栈工程师（批46 P1-2） ｜ 2026-11-17

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/source/source_notifier.dart';
import 'package:flutter_legado/src/screens/source_edit_screen.dart';
import 'package:flutter_legado/src/utils/source_json_patch.dart';

import '../mocks/mocks.dart';

/// 库内真实值：`ruleSearch.name` 带 `@js:` 后缀（设备证据形态）
const String _jsName = "\$.name\n@js:source.put('qa45b_var','V'); result";

const String _url = 'https://rule-keep.example.com';

/// 权威（最新）书源：规则带 `@js:` 与自定义目录规则
BookSource _freshSource() => BookSource.fromJson(<String, dynamic>{
      'bookSourceUrl': _url,
      'bookSourceName': '变量源',
      'ruleSearch': <String, dynamic>{
        'bookList': r'$.data[*]',
        'name': _jsName,
        'author': r'$.author',
      },
      'ruleToc': <String, dynamic>{
        'chapterList': r'$.chapters[*]',
        'chapterName': r'$.title',
      },
    });

/// 过期副本：`@js:` 后缀已丢失（导入/恢复前的旧对象）
BookSource _staleSource() => BookSource.fromJson(<String, dynamic>{
      'bookSourceUrl': _url,
      'bookSourceName': '变量源',
      'ruleSearch': <String, dynamic>{
        'bookList': r'$.data[*]',
        'name': r'$.name',
        'author': r'$.author',
      },
      'ruleToc': <String, dynamic>{
        'chapterList': r'$.data[*]',
        'chapterName': r'$.name',
      },
    });

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    BookSourceRawCache.clear();
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpEdit(
    WidgetTester tester, {
    String? sourceUrl,
    BookSource? source,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 8000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
                      builder: (_) => SourceEditScreen(
                        sourceUrl: sourceUrl,
                        source: source,
                      ),
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

  /// 只改源名后保存，返回落库的 BookSource
  Future<BookSource> renameAndSave(WidgetTester tester, String newName) async {
    await tester.enterText(
      find.byKey(const ValueKey('sf_bookSourceName')),
      newName,
    );
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    return verify(() => mockApi.updateBookSource(captureAny())).captured.single
        as BookSource;
  }

  /// 预载 notifier，使 saveSource 走「更新」而非「新增」路径
  Future<void> preload(List<BookSource> sources) async {
    when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
    await container.read(sourceNotifierProvider.notifier).loadSources();
  }

  group('规则对象非表单字段保留（P1 缺陷 2）', () {
    /// 主回归：notifier 内存列表是过期副本、API 已是新值。
    ///
    /// 修复前：`_loadSource` 优先取 notifier 内存对象 → 表单显示无 `@js:`
    /// 的旧规则 → 保存把库内 `@js:` 覆盖掉（设备症状）。
    testWidgets('notifier 过期副本不得覆盖库内 @js 规则', (tester) async {
      // 先让 notifier 持有过期副本
      await preload([_staleSource()]);
      // 随后权威数据源已更新（导入/恢复后的真实状态）
      when(() => mockApi.getBookSources())
          .thenAnswer((_) async => [_freshSource()]);

      await pumpEdit(tester, sourceUrl: _url);
      final saved = await renameAndSave(tester, '变量源改名');

      expect(saved.bookSourceName, '变量源改名', reason: '表单字段按编辑值保存');
      expect(
        saved.ruleSearch?.name,
        contains('@js:'),
        reason: '未编辑的 ruleSearch.name 必须原样保留 @js: 后缀',
      );
      expect(
        saved.ruleToc?.chapterList,
        r'$.chapters[*]',
        reason: '未编辑的 ruleToc.chapterList 必须原样保留',
      );
    });

    /// 同机制的第二入口：发现页/路由直接传入过期 BookSource 对象。
    testWidgets('调用方传入的过期 BookSource 不得抹掉 @js 规则', (tester) async {
      await preload([_freshSource()]);

      await pumpEdit(tester, source: _staleSource());
      final saved = await renameAndSave(tester, '变量源改名2');

      expect(
        saved.ruleSearch?.name,
        contains('@js:'),
        reason: '传入过期对象时也须按权威数据源回填规则',
      );
      expect(saved.ruleToc?.chapterList, r'$.chapters[*]');
    });

    /// 反向用例：用户显式清空某规则字段 → 必须真的清空（防过度保留）。
    testWidgets('显式清空规则字段必须写入空值', (tester) async {
      await preload([_freshSource()]);

      await pumpEdit(tester, sourceUrl: _url);
      // 用户把「书名」规则整段清空
      await tester.enterText(find.byKey(const ValueKey('sf_s_name')), '');
      final saved = await renameAndSave(tester, '清空测试');

      expect(
        saved.ruleSearch?.name,
        isNull,
        reason: '用户显式清空的规则字段必须写入空值（不得被原值补回）',
      );
      // 同组其它未编辑字段仍保留
      expect(saved.ruleSearch?.bookList, r'$.data[*]');
      expect(saved.ruleSearch?.author, r'$.author');
    });

    /// 反向用例：只改一个规则字段，同组其它字段不受影响。
    testWidgets('只改一个规则字段时同组其它字段保留', (tester) async {
      await preload([_freshSource()]);

      await pumpEdit(tester, sourceUrl: _url);
      await tester.enterText(
        find.byKey(const ValueKey('sf_s_author')),
        r'$.writer',
      );
      final saved = await renameAndSave(tester, '改作者规则');

      expect(saved.ruleSearch?.author, r'$.writer', reason: '编辑过的字段生效');
      expect(
        saved.ruleSearch?.name,
        contains('@js:'),
        reason: '同组未编辑字段必须保留',
      );
    });
  });

  group('载荷层：规则对象 null 不得清空原值', () {
    test('编辑值 ruleSearch 为 null 时保留原规则对象', () {
      final original = <String, dynamic>{
        'bookSourceUrl': _url,
        'ruleSearch': <String, dynamic>{'name': _jsName},
      };
      final edited = <String, dynamic>{
        'bookSourceUrl': _url,
        'ruleSearch': null,
      };
      final patched = patchSourceJson(original, edited);
      expect(
        (patched['ruleSearch'] as Map)['name'],
        _jsName,
        reason: '规则对象整体缺失（null）应视为「未携带」而非「清空」',
      );
    });
  });
}
