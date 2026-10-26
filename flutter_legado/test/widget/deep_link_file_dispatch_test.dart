import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/deep_link_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../mocks/mocks.dart';

/// 批16d：DeepLinkService 外部文件分流组件测试
///
/// 走真实 [DeepLinkService.handleFileUri]，仅替换：
/// - 平台通道 `legado/deep_link` 的 copyContentUri（返回临时文件路径）；
/// - associationNotifierProvider（记录 loadFromFile 并给出就绪态）；
/// - bookApiProvider（MockRustApi，压缩包列表桩）。
///
/// 覆盖 JSON → 关联导入、zip → 解压导入、7z → 明确不支持、未知文件 →
/// 「仍然导入」兜底、书籍文件 → 既有导入确认链。
class _RecordingAssociationNotifier extends AssociationNotifier {
  String? loadedFilePath;

  @override
  AssociationState build() => const AssociationState();

  @override
  Future<void> loadFromFile(String path, {ImportType? typeHint}) async {
    loadedFilePath = path;
    state = const AssociationState(
      type: ImportType.bookSource,
      items: [
        AssociationItem(
          raw: {'bookSourceName': '外部JSON源', 'bookSourceUrl': 'https://a'},
          name: '外部JSON源',
          status: ImportItemStatus.isNew,
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('legado/deep_link');
  late Directory tempDir;
  late String copiedPath;
  late List<String> importedPaths;
  late GlobalKey<NavigatorState> navKey;
  late _RecordingAssociationNotifier association;
  late MockRustApi api;
  late List<Map<Object?, Object?>> copyArgs;
  final stagedFiles = <String, String>{};
  var uriSeed = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('deep_link_dispatch_');
    copiedPath = '';
    importedPaths = [];
    copyArgs = [];
    navKey = GlobalKey<NavigatorState>();
    association = _RecordingAssociationNotifier();
    api = MockRustApi();
    // 真实文件 IO 必须在 testWidgets 之外完成（fake async 下 await 文件
    // 读写会一直挂起）；用例内只做纯路径赋值
    Future<void> stage(String name, String content) async {
      final file = File('${tempDir.path}${Platform.pathSeparator}$name');
      await file.writeAsString(content);
      stagedFiles[name] = file.path;
    }

    await stage(
      'sources.json',
      '[{"bookSourceUrl":"https://a","bookSourceName":"源A"}]',
    );
    await stage('books.zip', 'PK\u0003\u0004zip');
    await stage('books.7z', '7z-content');
    await stage('mystery.bin', 'hello');
    await stage('book.epub', 'epub-bytes');
    when(() => api.archiveListZipFiles(zipPath: any(named: 'zipPath')))
        .thenAnswer((_) async => ['a.txt']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'copyContentUri') {
        copyArgs.add(Map<Object?, Object?>.from(call.arguments as Map));
        return copiedPath;
      }
      return null;
    });
    DeepLinkService.instance
      ..navigatorKey = navKey
      // P2-7：真实嗅探为异步磁盘 IO，testWidgets 的 fake async 不推进真实
      // 回调 → 注入按后缀判定的纯内存嗅探器（真实读盘由
      // external_file_open_test.dart 覆盖）
      ..jsonSniffer = ((path) async => path.toLowerCase().endsWith('.json'))
      ..importLocalBook = (path) async {
        importedPaths.add(path);
        return Book(name: '外部书籍', bookUrl: 'file://$path');
      };
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    DeepLinkService.instance
      ..navigatorKey = null
      ..jsonSniffer = null
      ..importLocalBook = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } on FileSystemException {
      // 用例超时等异常路径下文件句柄可能未释放，清理失败不覆盖原始错误
    }
  });

  /// 固定步进泵帧（不用 pumpAndSettle：加载指示器等无限动画会拖满超时）
  Future<void> pumpUi(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          associationNotifierProvider.overrideWith(() => association),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: SizedBox.shrink()),
          onGenerateRoute: (settings) => settings.name == AppRoutes.bookInfo
              ? MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('详情页')),
                )
              : null,
        ),
      ),
    );
    await tester.pump();
  }

  /// 取 setUp 预置文件路径，并让平台通道返回该路径
  String stageCopiedFile(String name) {
    copiedPath = stagedFiles[name]!;
    return copiedPath;
  }

  /// 触发一次外部文件打开（URI 唯一，避免单例去重影响用例）
  ///
  /// [name] 用于让 Dart 侧按后缀决定落盘目录（书籍 → filesDir，
  /// JSON/压缩包/未知 → cacheDir）；无后缀时按「可能是书籍」持久落盘。
  Future<void> openFile(WidgetTester tester, {String? name}) async {
    uriSeed++;
    final uri = name == null
        ? 'content://test/$uriSeed'
        : 'content://test/$uriSeed/$name';
    unawaited(DeepLinkService.instance.handleFileUri(uri));
    await pumpUi(tester);
  }

  testWidgets('JSON 文件 → 关联导入（loadFromFile + 类型识别）', (tester) async {
    final path = stageCopiedFile('sources.json');
    await pumpApp(tester);
    await openFile(tester, name: 'sources.json');

    expect(association.loadedFilePath, path);
    expect(find.text('导入书源'), findsOneWidget);
    expect(find.text('外部JSON源'), findsOneWidget);
    // P2-6：JSON 落 cacheDir（persistent=false）
    expect(copyArgs.single['persistent'], isFalse);

    // 关闭对话框后一次性副本删除
    await tester.tap(find.text('取消'));
    await pumpUi(tester);
    expect(File(path).existsSync(), isFalse);
  });

  testWidgets('zip 压缩包 → 解压导入对话框', (tester) async {
    stageCopiedFile('books.zip');
    await pumpApp(tester);
    await openFile(tester, name: 'books.zip');

    expect(find.text('压缩包导入'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(association.loadedFilePath, isNull);
    expect(copyArgs.single['persistent'], isFalse);
  });

  testWidgets('7z 压缩包 → 明确提示暂不支持', (tester) async {
    stageCopiedFile('books.7z');
    await pumpApp(tester);
    await openFile(tester, name: 'books.7z');

    expect(find.text('压缩包导入'), findsOneWidget);
    expect(find.text('暂不支持 7z，请解压后导入'), findsOneWidget);
    expect(find.text('a.txt'), findsNothing);
    expect(copyArgs.single['persistent'], isFalse);
  });

  testWidgets('未知文件 → 「仍然导入」兜底对话框并强制按书籍导入', (tester) async {
    final path = stageCopiedFile('mystery.bin');
    await pumpApp(tester);
    await openFile(tester, name: 'mystery.bin');

    expect(find.text('提醒'), findsOneWidget);
    expect(find.text('文件 mystery.bin 不受支持，是否继续打开？'), findsOneWidget);
    expect(importedPaths, isEmpty);
    expect(copyArgs.single['persistent'], isFalse);

    await tester.tap(find.text('仍然导入'));
    await pumpUi(tester);

    expect(importedPaths, [path]);
    expect(find.text('详情页'), findsOneWidget);
    // P2-6：不支持分支强制导入后删除一次性副本
    expect(File(path).existsSync(), isFalse);
  });

  testWidgets('书籍文件 → 既有导入确认链', (tester) async {
    final path = stageCopiedFile('book.epub');
    await pumpApp(tester);
    await openFile(tester, name: 'book.epub');

    expect(find.text('导入本地书籍'), findsOneWidget);
    expect(find.text('book.epub'), findsOneWidget);
    // P2-6：书籍文件落 filesDir（persistent=true），导入后保留
    expect(copyArgs.single['persistent'], isTrue);

    await tester.tap(find.text('导入'));
    await pumpUi(tester);

    expect(importedPaths, [path]);
    expect(find.text('详情页'), findsOneWidget);
    expect(File(path).existsSync(), isTrue);
  });
}
