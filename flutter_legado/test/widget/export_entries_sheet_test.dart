// 批16e：其余导出入口接入统一导出目标 Sheet 的 widget 测试
//
// 覆盖：
// - 书源管理「导出所选」：单源 JS 走 filePath 模式（text/javascript，
//   内容 = mainJs）、文件名非法字符归一、纯空白 mainJs 走 JSON 分支；
//   单源 JSON `bookSource_{name}.json` / 多源 `bookSource_yyyyMMddHHmm.json`
// - 替换规则「导出选中」：批量菜单触发 Sheet（exportReplaceRule.json），
//   规则数组内容且不含 previewText（已知差异）
// - 高亮规则「导出规则」：包装对象 {type: 'highlightRule', rules}，
//   导出保留 uuid/order/timeoutMillisecond/applyToBody
// - TXT 目录规则「导出规则」：数组 + exportTxtTocRule.json
// - 朗读引擎「导出全部 / 导出当前选中」：httpTts.json / httpTts_{name}.json，
//   未选中时提示「无法导出系统tts」
// - 书架「导出书单」/ 书架管理「导出所有使用书源」/ 定时任务「导出任务」
// - 底栏皮肤「导出」：zip 走 filePath 模式（application/zip）
//
// 临时文件清理：Sheet 关闭（dispose）时统一删除，本文件在关闭后等待
// 异步清理落定再断言（P2-1）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';

// path_provider 平台接口为传递依赖，测试直引以覆写 instance 保持 hermetic，
// 不改 pubspec（同 import_screen_cbz_test / reader_comic_click_actions_test 桩模式）
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/audio/http_tts_seed.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/txt_toc_rules/txt_toc_rules_notifier.dart';
import 'package:flutter_legado/src/screens/auto_task_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_manage_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/bottom_bar_skin_screen.dart';
import 'package:flutter_legado/src/screens/highlight_rules_screen.dart';
import 'package:flutter_legado/src/screens/read_aloud_config_screen.dart';
import 'package:flutter_legado/src/screens/replace_rules_screen.dart';
import 'package:flutter_legado/src/screens/source_screen.dart';
import 'package:flutter_legado/src/screens/txt_toc_rules_screen.dart';
import 'package:flutter_legado/src/services/bottom_bar_skin_format.dart';
import 'package:flutter_legado/src/services/direct_link_upload_rule_service.dart';

import '../mocks/mocks.dart';

/// path_provider 平台桩：临时目录 / 应用支持目录均指向测试临时目录
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider({required this.tempPath, required this.supportPath});

  final String tempPath;
  final String supportPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

/// 捕获 directLinkUpload 入参的上传桩
class _UploadCapture {
  Map<String, Object?>? call;

  /// 逐用例重置（避免上一用例的捕获串到下一用例）
  void reset() => call = null;

  void install(MockRustApi api, {String result = 'https://dl.example/file'}) {
    when(
      () => api.directLinkUpload(
        ruleJson: any(named: 'ruleJson'),
        fileName: any(named: 'fileName'),
        contentType: any(named: 'contentType'),
        content: any(named: 'content'),
        filePath: any(named: 'filePath'),
      ),
    ).thenAnswer((invocation) async {
      call = <String, Object?>{
        'ruleJson': invocation.namedArguments[#ruleJson],
        'fileName': invocation.namedArguments[#fileName],
        'contentType': invocation.namedArguments[#contentType],
        'content': invocation.namedArguments[#content],
        'filePath': invocation.namedArguments[#filePath],
      };
      return result;
    });
  }
}

void main() {
  late MockRustApi mockApi;
  late _FakePathProvider fakePathProvider;
  late Directory tempRoot;
  late Directory tempDir;
  late Directory supportDir;
  late PathProviderPlatform originalPathProvider;

  final upload = _UploadCapture();

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 跳过首启种子导入（各页有版本门控）
      kHttpTtsSeedVersionKey: kHttpTtsSeedVersion,
      kTxtTocRuleVersionKey: kTxtTocRuleVersion,
    });
    // rootBundle 缓存跨 FakeAsync 复用会永不完成 → 逐用例清除
    rootBundle.evict(DirectLinkUploadRuleService.defaultRulesAsset);
    upload.reset();

    mockApi = MockRustApi();
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    upload.install(mockApi);

    tempRoot = Directory.systemTemp.createTempSync('export_entries_test');
    tempDir = Directory('${tempRoot.path}${Platform.pathSeparator}tmp')
      ..createSync(recursive: true);
    supportDir = Directory('${tempRoot.path}${Platform.pathSeparator}support')
      ..createSync(recursive: true);
    fakePathProvider = _FakePathProvider(
      tempPath: tempDir.path,
      supportPath: supportDir.path,
    );
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = fakePathProvider;
    addTearDown(() {
      PathProviderPlatform.instance = originalPathProvider;
      try {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发句柄未释放；临时目录交由系统清理，不影响断言
      }
    });
  });

  /// 在真实事件循环中执行 [action]，并条件等待 [done] 成立
  ///
  /// testWidgets 的 fake async 时钟不驱动真实文件 IO（临时 .js 写入、
  /// 皮肤目录扫描/zip 压缩），需经 [WidgetTester.runAsync] 放行真实事件
  /// 循环并逐帧 pump；等待改为有界的条件轮询（默认 10 秒上限，全量并行
  /// 跑测时 IO 抖动较大），任一时刻条件成立即返回。
  Future<void> runReal(
    WidgetTester tester,
    Future<void> Function() action,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await tester.runAsync(() async {
      await action();
      final deadline = DateTime.now().add(timeout);
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      expect(done(), isTrue, reason: 'runReal 条件等待超时（$timeout）');
    });
    await tester.pumpAndSettle();
  }

  /// 等待 Sheet 关闭后的异步临时文件清理落定（P2-1）
  Future<void> waitForFileGone(WidgetTester tester, File file) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(file.existsSync(), isFalse);
  }

  Widget wrap(Widget child, {List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(mockApi), ...overrides],
      child: MaterialApp(home: child),
    );
  }

  /// 在导出 Sheet 中点击「上传直链」（上传桩同步返回，无需网络）
  Future<void> tapUpload(WidgetTester tester) async {
    expect(find.text('上传直链'), findsOneWidget);
    await tester.tap(find.text('上传直链'));
    await tester.pumpAndSettle();
  }

  group('书源导出', () {
    testWidgets('单源 JS 导出 .js 文件、text/javascript，内容为 mainJs，关闭后清理', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getBookSources()).thenAnswer(
        (_) async => [
          const BookSource(
            bookSourceUrl: 'https://js.example',
            bookSourceName: '测试/JS源',
            mainJs: '// main js body',
          ),
        ],
      );

      await tester.pumpWidget(wrap(const SourceScreen()));
      await tester.pumpAndSettle();

      // 全选（自动进入批量模式）→ 更多选项 → 导出所选
      await tester.tap(find.textContaining('全选（0/1）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多选项'));
      await tester.pumpAndSettle();
      const sheetTitle = '导出文件：测试_JS源.js';
      // 书源页写临时 .js 文件为真实 IO：在真实事件循环中点击并等待 Sheet
      await runReal(
        tester,
        () => tester.tap(find.text('导出所选')),
        () => find.text(sheetTitle).evaluate().isNotEmpty,
      );

      // 非法文件名（/）归一为 _；扩展名 .js
      expect(find.text(sheetTitle), findsOneWidget);

      await tapUpload(tester);

      final call = upload.call!;
      expect(call['contentType'], 'text/javascript');
      expect(call['content'], isNull);
      final filePath = call['filePath'] as String;
      expect(filePath, endsWith('测试_JS源.js'));
      expect(call['fileName'], '测试_JS源.js');
      // 单源 JS 内容必须等于 mainJs（P2-4）
      expect(File(filePath).readAsStringSync(), '// main js body');
      // 上传成功面板仍需可操作：文件保留到 Sheet 关闭（P2-1）
      expect(File(filePath).existsSync(), isTrue);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await waitForFileGone(tester, File(filePath));
    });

    testWidgets('单源 JSON：bookSource_{name}.json，内容为所选书源数组', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getBookSources()).thenAnswer(
        (_) async => const [
          BookSource(bookSourceUrl: 'https://a.example', bookSourceName: '源甲'),
          BookSource(bookSourceUrl: 'https://b.example', bookSourceName: '源乙'),
        ],
      );

      await tester.pumpWidget(wrap(const SourceScreen()));
      await tester.pumpAndSettle();

      // 长按单条进入批量模式并只选中该条
      await tester.longPress(find.text('源甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出所选'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：bookSource_源甲.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(1));
      expect((payload.single as Map<String, dynamic>)['bookSourceName'], '源甲');
      // 参考版批量上传固定 bookSource.json
      expect(upload.call!['fileName'], 'bookSource.json');
    });

    testWidgets('多源 JSON：bookSource_yyyyMMddHHmm.json', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getBookSources()).thenAnswer(
        (_) async => const [
          BookSource(bookSourceUrl: 'https://a.example', bookSourceName: '源甲'),
          BookSource(bookSourceUrl: 'https://b.example', bookSourceName: '源乙'),
        ],
      );

      await tester.pumpWidget(wrap(const SourceScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('全选（0/2）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出所选'));
      await tester.pumpAndSettle();

      final title = tester.widget<Text>(
        find.textContaining('导出文件：bookSource_'),
      );
      expect(title.data, matches(RegExp(r'^导出文件：bookSource_\d{12}\.json$')));

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(2));
    });

    testWidgets('mainJs 纯空白按 JSON 分支导出（对齐 isNullOrBlank）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getBookSources()).thenAnswer(
        (_) async => const [
          BookSource(
            bookSourceUrl: 'https://blank.example',
            bookSourceName: '空白源',
            mainJs: '  \n\t ',
          ),
        ],
      );

      await tester.pumpWidget(wrap(const SourceScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('全选（0/1）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出所选'));
      await tester.pumpAndSettle();

      // 纯空白不算 JS 源：走 JSON 分支而非生成空白 .js
      expect(find.text('导出文件：bookSource_空白源.json'), findsOneWidget);
    });
  });

  group('替换规则导出', () {
    testWidgets('批量菜单「导出选中」触发 Sheet（exportReplaceRule.json）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getReplaceRules()).thenAnswer(
        (_) async => [
          const ReplaceRule(
            id: 1,
            name: '广告替换',
            pattern: '广告',
            replacement: '',
          ),
        ],
      );

      await tester.pumpWidget(wrap(const ReplaceRulesScreen()));
      await tester.pumpAndSettle();

      // 长按进入批量模式 → 批量操作 → 导出选中
      await tester.longPress(find.text('广告替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出选中'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：exportReplaceRule.json'), findsOneWidget);

      // 内容为规则数组（P2-4），且登记差异：不含 previewText（P2-3）
      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(1));
      final rule = payload.single as Map<String, dynamic>;
      expect(rule['name'], '广告替换');
      expect(rule['pattern'], '广告');
      expect(rule['replacement'], '');
      expect(rule.containsKey('previewText'), isFalse);
      expect(upload.call!['fileName'], 'export_rules.json');
    });
  });

  group('高亮规则导出', () {
    testWidgets('菜单「导出规则」触发 Sheet，内容为 {type,rules} 包装对象', (tester) async {
      when(() => mockApi.highlightRuleList()).thenAnswer(
        (_) async => jsonEncode([
          {
            'id': 1,
            'uuid': '6f1d3b1e-6a1f-4c43-9d1b-2b9f0c1f4a11',
            'name': '关键词高亮',
            'pattern': '修炼',
            'isRegex': false,
            'applyToTitle': false,
            'applyToBody': true,
            'scope': null,
            'isEnabled': true,
            'style': '{"textColor":-65536}',
            'sortOrder': 0,
            'timeoutMillisecond': 3000,
          },
        ]),
      );

      await tester.pumpWidget(wrap(const HighlightRulesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出规则'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：HighlightRules.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as Map<String, dynamic>;
      // 原版 HighlightRuleFile.TYPE = "highlightRule"
      expect(payload['type'], 'highlightRule');
      final rules = payload['rules'] as List<dynamic>;
      expect(rules, hasLength(1));
      expect((rules.single as Map<String, dynamic>)['pattern'], '修炼');
      expect(upload.call!['fileName'], 'highlightRule.json');
    });

    testWidgets('导出保留 uuid/order/timeoutMillisecond/applyToBody，可被关联导入归一', (
      tester,
    ) async {
      const uuid = '0b946e46-a08b-4c41-bc61-0c57c31c93f8';
      when(() => mockApi.highlightRuleList()).thenAnswer(
        (_) async => jsonEncode([
          {
            'id': 7,
            'uuid': uuid,
            'name': '正文高亮',
            'pattern': '修炼',
            'isRegex': false,
            'applyToTitle': false,
            'applyToBody': true,
            'scope': '斗破苍穹',
            'isEnabled': true,
            'style': '{"textColor":-65536}',
            'sortOrder': 3,
            'timeoutMillisecond': 1500,
          },
        ]),
      );

      await tester.pumpWidget(wrap(const HighlightRulesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出规则'));
      await tester.pumpAndSettle();

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as Map<String, dynamic>;
      final rule =
          (payload['rules'] as List<dynamic>).single as Map<String, dynamic>;

      // 字段名对齐原版实体：order（Rust 契约名为 sortOrder）
      expect(rule['uuid'], uuid);
      expect(rule['order'], 3);
      expect(rule.containsKey('sortOrder'), isFalse);
      expect(rule['timeoutMillisecond'], 1500);
      expect(rule['applyToBody'], isTrue);

      // P1 回归：导出内容喂给关联导入归一必须不抛（缺 uuid 曾抛「uuid 非法」）
      final normalized = AssociationNotifier.normalizeHighlightRuleForImport(
        rule,
      );
      expect(normalized['uuid'], uuid);
      expect(normalized['timeoutMillisecond'], 1500);
      expect(normalized['applyToBody'], isTrue);
      expect(normalized.containsKey('order'), isFalse);
    });

    testWidgets('批量导出选中：点击入口仅导出选中项', (tester) async {
      when(() => mockApi.highlightRuleList()).thenAnswer(
        (_) async => jsonEncode([
          for (final id in [1, 2, 3])
            {
              'id': id,
              'uuid': '00000000-0000-4000-8000-00000000000$id',
              'name': '规则$id',
              'pattern': 'p$id',
              'isRegex': false,
              'isEnabled': true,
              'style': '{"textColor":-65536}',
              'sortOrder': id,
            },
        ]),
      );

      await tester.pumpWidget(wrap(const HighlightRulesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('highlight-rule-tile-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('highlight-batch-export')));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：HighlightRules.json'), findsOneWidget);
      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as Map<String, dynamic>;
      final rules = (payload['rules'] as List).cast<Map<String, dynamic>>();
      expect(rules, hasLength(1), reason: '仅导出选中项');
      expect(rules.single['id'], 2);
      expect(rules.single['pattern'], 'p2');
    });
  });

  group('TXT 目录规则导出', () {
    testWidgets('菜单「导出规则」触发 Sheet（exportTxtTocRule.json，数组内容）', (tester) async {
      when(() => mockApi.getConfig('txt_toc_rules')).thenAnswer(
        (_) async => jsonEncode([
          {
            'id': 1,
            'name': '章节',
            'rule': r'^第\d+章',
            'replacement': '',
            'example': null,
            'serialNumber': 0,
            'enable': true,
          },
        ]),
      );

      await tester.pumpWidget(wrap(const TxtTocRulesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出规则'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：exportTxtTocRule.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(1));
      expect((payload.single as Map<String, dynamic>)['name'], '章节');
      expect(upload.call!['fileName'], 'export_rules.json');
    });
  });

  group('朗读引擎导出', () {
    late MockAudioService audioService;
    late FakeStreamAudioPlayer fakePlayer;

    setUp(() {
      audioService = MockAudioService();
      fakePlayer = FakeStreamAudioPlayer();
      when(() => audioService.dispose()).thenAnswer((_) async {});
      when(() => mockApi.getHttpTts()).thenAnswer(
        (_) async => [
          const HttpTts(
            id: 1,
            name: '本地引擎',
            url: 'http://192.168.1.2:8770/tts?text={{text}}',
          ),
        ],
      );
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const ReadAloudConfigScreen(),
          overrides: [
            streamAudioPlayerProvider.overrideWithValue(fakePlayer),
            audioServiceProvider.overrideWithValue(audioService),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('导出当前选中：httpTts_{name}.json', (tester) async {
      await pumpScreen(tester);

      // 选中引擎行
      await tester.tap(find.text('本地引擎'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出当前选中'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：httpTts_本地引擎.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as Map<String, dynamic>;
      expect(payload['name'], '本地引擎');
    });

    testWidgets('未选中（系统 TTS）时提示「无法导出系统tts」', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出当前选中'));
      await tester.pumpAndSettle();

      // 原文案对齐 strings.xml:1652 is_system_tts_no_export
      expect(find.text('无法导出系统tts'), findsOneWidget);
      // 不打开导出 Sheet
      expect(find.text('保存到本地'), findsNothing);
      // 走完 SnackBar 计时器，避免用例结束残留 pending timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('导出全部：httpTts.json', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出全部'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：httpTts.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(1));
      expect(upload.call!['fileName'], 'httpTTS.json');
    });
  });

  group('书架 / 书架管理 / 定时任务导出接线', () {
    testWidgets('书架「导出书单」：bookshelf.json，简介按 getDisplayIntro 回退', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getBooks()).thenAnswer(
        (_) async => const [
          // customIntro 为 null → 回退 intro
          Book(bookUrl: 'u1', name: '书一', author: '作者一', intro: '原始简介一'),
          // customIntro 为空串 → 同样回退 intro（对齐 isNullOrEmpty）
          Book(
            bookUrl: 'u2',
            name: '书二',
            author: '作者二',
            intro: '原始简介二',
            customIntro: '',
          ),
          // 非空 customIntro 优先
          Book(
            bookUrl: 'u3',
            name: '书三',
            author: '作者三',
            intro: '原始简介三',
            customIntro: '自定义简介三',
          ),
        ],
      );
      when(
        () => mockApi.getBookGroups(),
      ).thenAnswer((_) async => <BookGroup>[]);

      await tester.pumpWidget(wrap(const BookshelfScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出书单'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：bookshelf.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(3));
      expect((payload[0] as Map<String, dynamic>)['intro'], '原始简介一');
      expect((payload[1] as Map<String, dynamic>)['intro'], '原始简介二');
      expect((payload[2] as Map<String, dynamic>)['intro'], '自定义简介三');
    });

    testWidgets('书架管理「导出所有使用书源」：bookSource.json', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.getBooks()).thenAnswer(
        (_) async => const [
          Book(bookUrl: 'u1', name: '书一', origin: 'https://used.example'),
        ],
      );
      when(() => mockApi.getBookSources()).thenAnswer(
        (_) async => const [
          BookSource(
            bookSourceUrl: 'https://used.example',
            bookSourceName: '在用源',
          ),
        ],
      );
      when(
        () => mockApi.getBookGroups(),
      ).thenAnswer((_) async => <BookGroup>[]);

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出所有使用书源'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：bookSource.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(1));
      expect((payload.single as Map<String, dynamic>)['bookSourceName'], '在用源');
    });

    testWidgets('定时任务「导出任务」：exportAutoTask.json', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      when(() => mockApi.autoTaskListRules()).thenAnswer(
        (_) async => [
          <String, dynamic>{
            'id': '1',
            'name': '每日刷新目录',
            'cron': '0 3 * * *',
            'enable': true,
            'comment': 'refreshToc',
            'script': 'refreshToc()',
          },
        ],
      );

      await tester.pumpWidget(wrap(const AutoTaskScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出任务'));
      await tester.pumpAndSettle();

      expect(find.text('导出文件：exportAutoTask.json'), findsOneWidget);

      await tapUpload(tester);
      final payload =
          jsonDecode(upload.call!['content'] as String) as List<dynamic>;
      expect(payload, hasLength(1));
      expect((payload.single as Map<String, dynamic>)['name'], '每日刷新目录');
    });
  });

  group('底栏皮肤导出（zip filePath 模式）', () {
    testWidgets('导出触发 Sheet：{name}.zip + application/zip', (tester) async {
      // 预置一个皮肤目录（4 个槽位的选中图）
      final skinDir = Directory(
        '${supportDir.path}${Platform.pathSeparator}bottomBarSkins'
        '${Platform.pathSeparator}测试皮肤',
      )..createSync(recursive: true);
      for (final slot in BottomBarSkinFormat.mappedSlots) {
        File(
          '${skinDir.path}${Platform.pathSeparator}${slot}_selected.png',
        ).writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47, 0x01]);
      }

      // 皮肤列表扫描为真实 IO：在真实事件循环中挂载并等待列表项出现
      await runReal(
        tester,
        () => tester.pumpWidget(wrap(const BottomBarSkinScreen())),
        () => find.text('测试皮肤').evaluate().isNotEmpty,
      );

      await tester.tap(find.byIcon(Symbols.more_horiz_rounded).first);
      await tester.pumpAndSettle();
      // buildZipBytes 读图并压缩为真实 IO：点击后条件等待 Sheet 出现
      //（全量并行跑测时压缩可能明显变慢，放宽到 20 秒）
      const sheetTitle = '导出文件：测试皮肤.zip';
      await runReal(
        tester,
        () => tester.tap(find.text('导出')),
        () => find.text(sheetTitle).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 20),
      );

      expect(find.text(sheetTitle), findsOneWidget);

      await tapUpload(tester);
      final call = upload.call!;
      expect(call['contentType'], 'application/zip');
      expect(call['content'], isNull);
      final filePath = call['filePath'] as String;
      expect(filePath, endsWith('测试皮肤.zip'));
      // 关闭 Sheet 后清理临时 zip（P2-1）
      expect(File(filePath).existsSync(), isTrue);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await waitForFileGone(tester, File(filePath));
    });
  });
}
