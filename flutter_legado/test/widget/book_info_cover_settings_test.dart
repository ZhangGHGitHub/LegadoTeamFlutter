// 详情页封面跟随封面设置测试（设置批6b-1）
//
// 覆盖：
// - 详情页封面阴影随「显示字体阴影」显示/隐藏（替换原硬编码 elevation 8），
//   默认封面绘制书名；
// - [审查 P1-2] 仅 WiFi + 蜂窝：背景退纯 surface、不加载网络封面、不取色；
// - [审查 P1-2] WiFi 允许：背景加载网络封面；useDefaultCover 后背景不再
//   加载网络封面。
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/services/cover_decode_loader.dart';
import 'package:flutter_legado/src/services/cover_disk_cache.dart';
import 'package:flutter_legado/src/services/cover_palette_service.dart';
import 'package:flutter_legado/src/services/network_status_service.dart';
import 'package:flutter_legado/src/widgets/cover_text_painter.dart';

import '../mocks/mocks.dart';

/// 可注入的网络状态假实现
class _FakeNetworkStatus extends NetworkStatusService {
  bool wifi;

  _FakeNetworkStatus(this.wifi);

  @override
  Future<bool> isWifi({bool forceRefresh = false}) async => wifi;
}

/// 测试 HTTP 客户端：openUrl 计数后抛错（图片走 errorWidget，避免真实 DNS）
int _httpOpenCalls = 0;

class _ThrowingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    _httpOpenCalls++;
    throw const SocketException('mock offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ThrowingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ThrowingHttpClient();
}

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    coverSettingsListenable.value = CoverSettings.defaults;
    uiSettingsListenable.value = const UiSettingsState();
    CoverDecodeLoader.clearForTest();
    // 磁盘缓存测试注入恒未命中：避免 DefaultCacheManager 在 widget 测试
    // 环境等待平台通道（真实命中/过期用例见 book_cover_render_test）
    CoverDiskCache.debugLoader = (_) async => null;
    CoverPaletteService.debugExtractor = null;
    _httpOpenCalls = 0;
    NetworkStatusService.instance = NetworkStatusService();
    HttpOverrides.global = _ThrowingHttpOverrides();
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  tearDown(() {
    HttpOverrides.global = null;
    NetworkStatusService.instance = NetworkStatusService();
    CoverDiskCache.reset();
    CoverPaletteService.debugExtractor = null;
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  Book stubBook({String? coverUrl}) {
    final book = Book(
      bookUrl: 'https://src.com/book/cover',
      name: '封面设置书',
      author: '作者甲',
      coverUrl: coverUrl,
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(any())).thenAnswer((_) async => const []);
    when(() => mockApi.getBooks()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(
      () => mockApi.sourceCallBackBtn(
        event: any(named: 'event'),
        bookUrl: any(named: 'bookUrl'),
        result: any(named: 'result'),
        bookType: any(named: 'bookType'),
      ),
    ).thenAnswer(
      (_) async => {'invoked': false, 'jsTrue': false, 'actions': <dynamic>[]},
    );
    return book;
  }

  testWidgets('详情页封面阴影/描边跟随封面设置，默认封面绘制书名', (tester) async {
    final book = stubBook();
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      showShadow: true,
    );

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bookCoverShadow')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('bookCoverText')),
    );
    final layout = (paint.painter! as CoverTextPainter).layout;
    expect(layout.nameGlyphs.map((g) => g.text).join(), '封面设置书');
    expect(layout.authorGlyphs.map((g) => g.text).join(), '作者甲');

    // 关闭阴影后详情页即时跟随（BookCover 监听全局设置；根节点固定，
    // 仅 boxShadow 置空，避免网络封面重建）
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      showShadow: false,
    );
    await tester.pump();
    final shadowBox = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('bookCoverShadow')),
    );
    expect((shadowBox.decoration as BoxDecoration).boxShadow, isNull);
  });

  testWidgets('仅 WiFi + 蜂窝：详情背景退纯 surface，零网络/零取色', (tester) async {
    final book = stubBook(coverUrl: 'https://cover.test/book.jpg');
    NetworkStatusService.instance = _FakeNetworkStatus(false);
    var paletteCalls = 0;
    CoverPaletteService.debugExtractor = (_) async {
      paletteCalls++;
      return Colors.red;
    };
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      loadOnlyOnWifi: true,
    );

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();

    // 背景直接纯 surface（不走 CachedNetworkImage），封面本身也保持占位；
    // openUrl 计数证明蜂窝下零网络请求，palette 计数证明零取色
    expect(
      find.byKey(const ValueKey('bookInfoBackdropSurface')),
      findsOneWidget,
    );
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    expect(_httpOpenCalls, 0);
    expect(paletteCalls, 0);
  });

  testWidgets('WiFi 允许：背景加载网络封面并取色；useDefaultCover 后停止', (tester) async {
    final book = stubBook(coverUrl: 'https://cover.test/book.jpg');
    NetworkStatusService.instance = _FakeNetworkStatus(true);
    var paletteCalls = 0;
    CoverPaletteService.debugExtractor = (_) async {
      paletteCalls++;
      return Colors.red;
    };
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      loadOnlyOnWifi: true,
    );

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();
    expect(find.byType(CachedNetworkImage), findsWidgets);
    expect(paletteCalls, greaterThan(0));

    final paletteBefore = paletteCalls;
    // 总是默认封面：背景与封面都不再发起网络请求、不再取色
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      loadOnlyOnWifi: true,
      useDefaultCover: true,
    );
    await tester.pumpAndSettle();
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    expect(paletteCalls, paletteBefore);
  });

  testWidgets('总是默认封面：即使 WiFi 也不加载网络背景/不取色', (tester) async {
    final book = stubBook(coverUrl: 'https://cover.test/book.jpg');
    NetworkStatusService.instance = _FakeNetworkStatus(true);
    var paletteCalls = 0;
    CoverPaletteService.debugExtractor = (_) async {
      paletteCalls++;
      return Colors.red;
    };
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      useDefaultCover: true,
    );

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    expect(_httpOpenCalls, 0);
    expect(paletteCalls, 0);
  });
}
