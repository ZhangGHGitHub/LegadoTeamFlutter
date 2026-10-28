// ACTION_SEND / PROCESS_TEXT 文本路由 widget 测试（批25）
//
// 覆盖：口令 → 口令导入；legado:// → 关联导入；http(s) → 外跳确认；
// JSON → 关联导入（loadFromText）；其他 → 不支持提示。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/services/deep_link_service.dart';
import 'package:flutter_legado/src/utils/shared_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

class _RecordingAssociationNotifier extends AssociationNotifier {
  ImportType? bootstrappedType;
  String? bootstrappedUrl;
  String? loadedText;
  int bootstrapCalls = 0;

  @override
  AssociationState build() => const AssociationState();

  @override
  Future<void> bootstrapFromDeepLink({
    ImportType? type,
    required String srcUrl,
  }) async {
    bootstrapCalls++;
    bootstrappedType = type;
    bootstrappedUrl = srcUrl;
    _ready(type ?? ImportType.bookSource);
  }

  @override
  Future<void> loadFromText(String content, {ImportType? typeHint}) async {
    loadedText = content;
    _ready(typeHint ?? ImportType.bookSource);
  }

  void _ready(ImportType type) {
    state = AssociationState(
      type: type,
      items: const [
        AssociationItem(
          raw: {'name': '测试条目', 'bookSourceUrl': 'https://a'},
          name: '测试条目',
          status: ImportItemStatus.isNew,
        ),
      ],
    );
  }
}

void main() {
  late _RecordingAssociationNotifier notifier;
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    notifier = _RecordingAssociationNotifier();
    navKey = GlobalKey<NavigatorState>();
    DeepLinkService.instance.navigatorKey = navKey;
  });

  tearDown(() {
    DeepLinkService.instance.navigatorKey = null;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          associationNotifierProvider.overrideWith(() => notifier),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Center(child: Text('首页'))),
        ),
      ),
    );
  }

  testWidgets('分享口令 → 先确认 URL，确认后才按类型进入导入', (tester) async {
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText(
      '复制口令到阅读导入#L:example电com/a！sy©0¥Legado^',
    );
    await tester.pumpAndSettle();

    // 批25b P3-4：确认前不得发起网络拉取（关联导入打开即拉取）
    expect(find.text('跳转确认'), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);
    expect(notifier.bootstrapCalls, 0);

    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();

    expect(notifier.bootstrappedType, ImportType.bookSource);
    expect(notifier.bootstrappedUrl, 'https://example.com/a');
    expect(find.text('导入书源'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('分享口令 → 取消跳转确认则不拉取', (tester) async {
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText(
      '复制口令到阅读导入#L:example电com/a！sy©0¥Legado^',
    );
    await tester.pumpAndSettle();

    expect(find.text('跳转确认'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;

    expect(notifier.bootstrapCalls, 0);
    expect(find.text('导入书源'), findsNothing);
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('分享 legado:// 链接 → 先确认 src 再关联导入', (tester) async {
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText(
      'legado://import/dictRule?src=https://example.com/dict.json',
    );
    await tester.pumpAndSettle();

    expect(find.text('跳转确认'), findsOneWidget);
    expect(find.text('https://example.com/dict.json'), findsOneWidget);
    expect(notifier.bootstrapCalls, 0);

    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();

    expect(notifier.bootstrappedType, ImportType.dictRule);
    expect(notifier.bootstrappedUrl, 'https://example.com/dict.json');
    expect(find.text('导入字典规则'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('分享 http 链接 → 先弹外跳确认，取消不导航', (tester) async {
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText(
      'https://example.com/a',
    );
    await tester.pumpAndSettle();

    expect(find.text('跳转确认'), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;

    // 仍停留首页，未压入浏览器路由
    expect(find.text('首页'), findsOneWidget);
  });

  // 批25b：冷启动闪屏未退出时不得弹框（否则会被 pushReplacementNamed
  // 连同弹窗路由一起替换，表现为一闪即逝）
  testWidgets('闪屏未退出时等待，退出后才展示分享弹框', (tester) async {
    var splashVisible = true;
    DeepLinkService.instance.isSplashVisible = () => splashVisible;
    addTearDown(() => DeepLinkService.instance.isSplashVisible = null);
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText(
      'https://example.com/a',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('跳转确认'), findsNothing);

    splashVisible = false;
    await tester.pumpAndSettle();

    expect(find.text('跳转确认'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('分享 JSON → 关联导入 loadFromText', (tester) async {
    await pumpApp(tester);
    const json = '{"bookSourceName":"分享源","bookSourceUrl":"https://a"}';

    final future = DeepLinkService.instance.handleSharedText(json);
    await tester.pumpAndSettle();

    expect(notifier.loadedText, json);
    expect(find.text('导入书源'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('分享非法 JSON → 不支持提示', (tester) async {
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText('{not json');
    await tester.pumpAndSettle();

    expect(find.text('不支持的内容'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('分享普通文本 → 不支持提示', (tester) async {
    await pumpApp(tester);

    final future = DeepLinkService.instance.handleSharedText('hello world');
    await tester.pumpAndSettle();

    expect(find.text('不支持的内容'), findsOneWidget);
    expect(find.textContaining('分享内容不是分享口令'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await future;
  });

  // 批25b P3-2：超长 / 超深分享文本给出明确提示
  testWidgets('分享超过 1 MiB 的文本 → 「分享内容过大」提示', (tester) async {
    await pumpApp(tester);

    final over = String.fromCharCodes(
      List<int>.filled(maxSharedTextBytes + 1, 0x61),
    );
    final future = DeepLinkService.instance.handleSharedText(over);
    await tester.pumpAndSettle();

    expect(find.text('分享内容过大'), findsOneWidget);
    expect(find.textContaining('1 MiB'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('分享超深 JSON → 「JSON 层级过深」提示', (tester) async {
    await pumpApp(tester);

    final deep = '${List<String>.filled(maxJsonDepth + 1, '[').join()}'
        '${List<String>.filled(maxJsonDepth + 1, ']').join()}';
    final future = DeepLinkService.instance.handleSharedText(deep);
    await tester.pumpAndSettle();

    expect(find.text('JSON 层级过深'), findsOneWidget);
    expect(find.textContaining('$maxJsonDepth 层'), findsOneWidget);
    expect(notifier.loadedText, isNull);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('弹窗存续期重复投递去重', (tester) async {
    await pumpApp(tester);
    const text = '复制口令到阅读导入#L:example电com/a！sy©0¥Legado^';

    final first = DeepLinkService.instance.handleSharedText(text);
    await tester.pumpAndSettle();
    // 确认框存续期间再次投递同一文本不应叠加第二个确认框
    final second = DeepLinkService.instance.handleSharedText(text);
    await tester.pumpAndSettle();

    expect(find.text('跳转确认'), findsOneWidget);
    expect(notifier.bootstrapCalls, 0);

    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(notifier.bootstrapCalls, 1);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await Future.wait([first, second]);
  });
}
