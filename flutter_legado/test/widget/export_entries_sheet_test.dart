// 批16e：其余导出入口接入统一导出目标 Sheet 的 widget 测试
//
// 覆盖：
// - 书源管理「导出所选」：单源 JS 走 filePath 模式（text/javascript），
//   上传成功后清理本页创建的临时文件；文件名做非法字符归一
// - 替换规则「导出选中」：批量菜单触发 Sheet（exportReplaceRule.json）
// - 高亮规则「导出规则」：包装对象 {type: 'highlightRule', rules}
// - TXT 目录规则「导出规则」：数组 + exportTxtTocRule.json
// - 朗读引擎「导出全部 / 导出当前选中」：httpTts.json / httpTts_{name}.json，
//   未选中时提示「系统TTS无法导出」
// - 底栏皮肤「导出」：zip 走 filePath 模式（application/zip）
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
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/audio/http_tts_seed.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/txt_toc_rules/txt_toc_rules_notifier.dart';
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
    SharedPreferences.setMockInitialValues(
      <String, Object>{
        // 跳过首启种子导入（各页有版本门控）
        kHttpTtsSeedVersionKey: kHttpTtsSeedVersion,
        kTxtTocRuleVersionKey: kTxtTocRuleVersion,
      },
    );
    // rootBundle 缓存跨 FakeAsync 复用会永不完成 → 逐用例清除
    rootBundle.evict(DirectLinkUploadRuleService.defaultRulesAsset);

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

  /// 在真实事件循环中执行 [action]，并轮询等待 [done] 成立
  ///
  /// testWidgets 的 fake async 时钟不驱动真实文件 IO（临时 .js 写入、
  /// 皮肤目录扫描/zip 压缩），需经 [WidgetTester.runAsync] 放行真实事件
  /// 循环并逐帧 pump（有界轮询，避免加载动画导致 settle 超时）。
  Future<void> runReal(
    WidgetTester tester,
    Future<void> Function() action,
    bool Function() done,
  ) async {
    await tester.runAsync(() async {
      await action();
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (done()) break;
      }
    });
    await tester.pumpAndSettle();
  }

  Widget wrap(Widget child, {List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        ...overrides,
      ],
      child: MaterialApp(home: child),
    );
  }

  /// 在导出 Sheet 中点击「上传直链」（上传桩同步返回，无需网络）
  Future<void> tapUpload(WidgetTester tester) async {
    expect(find.text('上传直链'), findsOneWidget);
    await tester.tap(find.text('上传直链'));
    await tester.pumpAndSettle();
  }

  group('书源导出（js 单源 filePath 模式）', () {
    testWidgets('单源 JS 导出 .js 文件、text/javascript，并清理临时文件', (tester) async {
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
      // 临时文件由书源页创建，上传成功后应被清理
      expect(File(filePath).existsSync(), isFalse);
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
    });
  });

  group('高亮规则导出', () {
    testWidgets('菜单「导出规则」触发 Sheet，内容为 {type,rules} 包装对象', (tester) async {
      when(() => mockApi.highlightRuleList()).thenAnswer(
        (_) async => jsonEncode([
          {
            'id': 1,
            'name': '关键词高亮',
            'pattern': '修炼',
            'isRegex': false,
            'applyToTitle': false,
            'scope': null,
            'isEnabled': true,
            'style': '{"textColor":-65536}',
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
  });

  group('TXT 目录规则导出', () {
    testWidgets('菜单「导出规则」触发 Sheet（exportTxtTocRule.json，数组内容）',
        (tester) async {
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

    testWidgets('未选中（系统 TTS）时提示「系统TTS无法导出」', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出当前选中'));
      await tester.pumpAndSettle();

      expect(find.text('系统TTS无法导出'), findsOneWidget);
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
      // buildZipBytes 读图并压缩为真实 IO
      const sheetTitle = '导出文件：测试皮肤.zip';
      await runReal(
        tester,
        () => tester.tap(find.text('导出')),
        () => false,
      );
      await runReal(
        tester,
        () async {},
        () => find.text(sheetTitle).evaluate().isNotEmpty,
      );

      expect(find.text(sheetTitle), findsOneWidget);

      await tapUpload(tester);
      final call = upload.call!;
      expect(call['contentType'], 'application/zip');
      expect(call['content'], isNull);
      final filePath = call['filePath'] as String;
      expect(filePath, endsWith('测试皮肤.zip'));
      expect(File(filePath).existsSync(), isFalse);
    });
  });
}
