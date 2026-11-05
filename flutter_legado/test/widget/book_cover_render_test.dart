// BookCover 封面设置渲染 widget 测试（设置批6b-1）
//
// 覆盖：默认封面文字（仅无封面/失败/占位/总是默认封面时）、网络封面
// 成功不绘字、日夜叠层、竖排/横排/拉丁强制、描边阴影开关、限制比例、
// 仅 WiFi 蜂窝阻塞（不写缓存）与恢复 WiFi 后重试。
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/cover_aspect_ratio.dart';
import 'package:flutter_legado/src/services/cover_decode_loader.dart';
import 'package:flutter_legado/src/services/network_status_service.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';
import 'package:flutter_legado/src/widgets/cover_text_painter.dart';

import '../mocks/mocks.dart';

/// 真实 2×1 PNG（缓存命中走 Image.memory，模拟网络封面已加载成功）
const String _kPng2x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4z8AARAAI/gH/xp559wAAAABJRU5ErkJggg==';

/// 可注入的网络状态假实现
class _FakeNetworkStatus extends NetworkStatusService {
  bool wifi;

  _FakeNetworkStatus(this.wifi);

  @override
  Future<bool> isWifi({bool forceRefresh = false}) async => wifi;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'http://cover.test/book.jpg';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    coverSettingsListenable.value = CoverSettings.defaults;
    uiSettingsListenable.value = const UiSettingsState();
    CoverAspectRatio.clear();
    CoverDecodeLoader.clearForTest();
    NetworkStatusService.instance = NetworkStatusService();
  });

  tearDown(() {
    NetworkStatusService.instance = NetworkStatusService();
  });

  Widget host(
    Widget child, {
    Brightness brightness = Brightness.light,
    bool withScope = true,
  }) {
    final app = MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );
    if (!withScope) return app;
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(MockRustApi())],
      child: app,
    );
  }

  CoverTextLayout painterLayout(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('bookCoverText')),
    );
    return (paint.painter! as CoverTextPainter).layout;
  }

  testWidgets('无封面：默认封面绘制竖排书名/作者（日间无暗色叠层）', (tester) async {
    await tester.pumpWidget(
      host(
        const BookCover(
          bookName: '凡人修仙传',
          bookAuthor: '忘语',
          width: 80,
          height: 110,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('bookCoverDefault')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverDefaultNight')), findsNothing);
    final layout = painterLayout(tester);
    expect(layout.horizontal, isFalse);
    expect(layout.nameGlyphs.length, 5);
    expect(layout.authorGlyphs.length, 2);
    expect(layout.showStroke, isTrue);
  });

  testWidgets('夜间：同一内置图 + 暗色叠层，日夜显隐独立', (tester) async {
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      useDefaultColor: false,
      showNameDark: false,
    );
    await tester.pumpWidget(
      host(
        const BookCover(
          bookName: '凡人修仙传',
          bookAuthor: '忘语',
          width: 80,
          height: 110,
        ),
        brightness: Brightness.dark,
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('bookCoverDefaultNight')), findsOneWidget);
    // 夜间书名关闭 → 作者随书名关闭 → 不绘制文字层
    expect(find.byKey(const ValueKey('bookCoverText')), findsNothing);
  });

  testWidgets('拉丁书名强制横排', (tester) async {
    await tester.pumpWidget(
      host(
        const BookCover(
          bookName: 'Harry Potter',
          bookAuthor: 'J.K. Rowling',
          width: 80,
          height: 110,
        ),
      ),
    );
    await tester.pump();

    final layout = painterLayout(tester);
    expect(layout.horizontal, isTrue);
    expect(layout.horizontalName, 'Harry Potter');
    expect(layout.horizontalAuthor, 'J.K. Rowling');
  });

  testWidgets('信息方向横排：中文也横排绘制', (tester) async {
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      infoOrientation: CoverSettings.infoOrientationLandscape,
    );
    await tester.pumpWidget(
      host(const BookCover(bookName: '凡人修仙传', width: 80, height: 110)),
    );
    await tester.pump();

    expect(painterLayout(tester).horizontal, isTrue);
  });

  testWidgets('总是默认封面：忽略网络地址，不创建网络图片', (tester) async {
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      useDefaultCover: true,
    );
    await tester.pumpWidget(
      host(
        const BookCover(
          coverUrl: url,
          bookName: '凡人修仙传',
          width: 80,
          height: 110,
        ),
        withScope: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bookCoverDefault')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('网络封面已加载（缓存命中）：不绘制默认文字', (tester) async {
    CoverDecodeLoader.putCached('', url, base64Decode(_kPng2x1));
    await tester.pumpWidget(
      host(
        const BookCover(
          coverUrl: url,
          bookName: '凡人修仙传',
          bookAuthor: '忘语',
          width: 80,
          height: 110,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsNothing);
  });

  testWidgets('网络封面加载中/失败：占位绘制默认文字', (tester) async {
    await tester.pumpWidget(
      host(
        const BookCover(
          coverUrl: url,
          bookName: '凡人修仙传',
          width: 80,
          height: 110,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
  });

  testWidgets('仅 WiFi + 蜂窝：不发起网络加载、不写缓存、显示占位文字', (tester) async {
    final fake = _FakeNetworkStatus(false);
    NetworkStatusService.instance = fake;
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      loadOnlyOnWifi: true,
    );

    await tester.pumpWidget(
      host(
        const BookCover(
          coverUrl: url,
          bookName: '凡人修仙传',
          width: 80,
          height: 110,
        ),
      ),
    );
    await tester.pump();
    // 磁盘缓存探测有 500ms 超时，先推进到超时后再断言蜂窝阻塞
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    expect(CoverDecodeLoader.getCached('', url), isNull);

    // 恢复 WiFi：5s 定时重试 + 500ms 缓存探测超时 → 直连链路
    fake.wifi = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('仅 WiFi + 蜂窝但内存缓存命中：照常显示封面，不占位', (tester) async {
    // [审查 P2-1] 缓存检查先于网络门控：蜂窝下已解密封面继续显示
    CoverDecodeLoader.putCached('', url, base64Decode(_kPng2x1));
    NetworkStatusService.instance = _FakeNetworkStatus(false);
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      loadOnlyOnWifi: true,
    );

    await tester.pumpWidget(
      host(
        const BookCover(
          coverUrl: url,
          bookName: '凡人修仙传',
          width: 80,
          height: 110,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsNothing);
  });

  testWidgets('阴影开关：封面外 4dp 阴影随设置显示/隐藏', (tester) async {
    await tester.pumpWidget(
      host(const BookCover(bookName: '凡人修仙传', width: 80, height: 110)),
    );
    await tester.pump();
    // [审查 P3] 根节点固定存在，仅 boxShadow 条件变化（不重建网络封面）
    var shadowBox = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('bookCoverShadow')),
    );
    expect((shadowBox.decoration as BoxDecoration).boxShadow, isNull);

    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      showShadow: true,
    );
    await tester.pump();
    shadowBox = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('bookCoverShadow')),
    );
    final decoration = shadowBox.decoration as BoxDecoration;
    expect(decoration.boxShadow, isNotNull);
    expect(decoration.boxShadow!.single.blurRadius, 4);
  });

  testWidgets('限制比例关闭 + 原图比例 → 自适应高度；总是默认封面时忽略', (tester) async {
    CoverAspectRatio.remember(url, 0.5);
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      restrictCoverRatio: false,
    );
    uiSettingsListenable.value = const UiSettingsState().copyWith(
      restrictCoverRatio: false,
    );

    await tester.pumpWidget(
      host(
        const BookCover(
          coverUrl: url,
          bookName: '凡人修仙传',
          width: 70,
          height: 100,
          adaptAspectRatio: true,
          adaptiveMinHeight: 50,
          adaptiveMaxHeight: 200,
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(BookCover)).height, closeTo(140, 0.01));

    // 总是默认封面：忽略网络封面比例，保持声明高度
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      useDefaultCover: true,
    );
    await tester.pump();
    expect(tester.getSize(find.byType(BookCover)).height, closeTo(100, 0.01));
  });
}
