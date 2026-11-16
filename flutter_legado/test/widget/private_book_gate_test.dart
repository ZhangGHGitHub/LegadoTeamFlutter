/// 媒体阅读器私密闸门测试（A3：漫画 / 听书 / 视频 + 浮窗入口）
///
/// 缺陷背景：批9c 只为文本阅读器接了 `PrivateReadGate`，漫画/听书/视频
/// 三条路由未接闸门；视频浮窗不经路由，需在创建点判定。
///
/// 覆盖：
/// 1. 漫画路由：私密书未授权 → 锁定页、不组合阅读器、不取书籍/目录；
/// 2. 听书路由：私密书未授权 → 锁定页、不组合播放器、不取章节；
/// 3. 视频路由：私密书未授权 → 锁定页、不组合播放器；
/// 4. 浮窗入口：私密书未授权 → 拒绝创建原生悬浮窗（零 show 调用）；
/// 5. 首帧竞态：策略/标记未就绪时不组合内容（不泄漏）；
/// 6. 非私密书：直接进入内容，不弹验证（防过度脱敏）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_content_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/screens/video_screen.dart';
import 'package:flutter_legado/src/utils/private_book_access.dart';
import 'package:flutter_legado/src/widgets/privacy/private_book_gate.dart';

import '../mocks/privacy_mock_book_api.dart';

const _privateBookUrl = 'https://a.com/private-comic';
const _publicBookUrl = 'https://a.com/public-comic';

final _privateBook = Book(
  bookUrl: _privateBookUrl,
  name: '私密漫画',
  author: '作者',
  origin: 'https://a.com',
  bookType: BookType.image,
  isPrivate: true,
);

final _publicBook = Book(
  bookUrl: _publicBookUrl,
  name: '公开漫画',
  author: '作者',
  origin: 'https://a.com',
  bookType: BookType.image,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;
  late GlobalKey<NavigatorState> navigatorKey;

  Future<void> bootContainer({
    required List<Book> books,
    bool enabled = true,
    bool verifyOnOpenBook = true,
    PrivacyUnlockScope scope = PrivacyUnlockScope.everyTime,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: verifyOnOpenBook,
      PrefKeys.privateUnlockScope: scope.storageValue,
    });
    api = PrivacyMockBookApi(books: books);
    if (enabled) await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  }

  /// 挂载带真实路由表的 App（与生产同一 `AppRoutes.generateRoute`）
  Future<void> pumpApp(WidgetTester tester) async {
    navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          onGenerateRoute: AppRoutes.generateRoute,
          home: const Scaffold(body: Text('HOME')),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pushRoute(
    WidgetTester tester,
    String route,
    Object? arguments,
  ) async {
    navigatorKey.currentState!.pushNamed(route, arguments: arguments);
    await tester.pump();
    await tester.pumpAndSettle();
  }

  group('漫画路由 /reader-comic', () {
    testWidgets('私密书未授权：锁定页取代阅读器，且不取书籍/目录', (tester) async {
      await bootContainer(books: [_privateBook]);
      await pumpApp(tester);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      await container.read(privacyContentProvider.notifier).ensureLoaded();

      await pushRoute(tester, AppRoutes.readerComic, _privateBookUrl);

      expect(
        find.byType(ReaderComicScreen),
        findsNothing,
        reason: '未授权时阅读器不得进入组件树',
      );
      expect(
        find.byKey(const ValueKey('privateBookGateLocked')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);
      expect(api.getBookCalls, 0, reason: '不得加载书籍信息');
      expect(api.getChaptersCalls, 0, reason: '不得加载目录（联网取数）');

      await tester.tap(find.byKey(const ValueKey('privacyUnlockCancel')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderComicScreen), findsNothing);
    });

    testWidgets('非私密书：直接进入漫画阅读器，不弹验证', (tester) async {
      await bootContainer(books: [_publicBook]);
      await pumpApp(tester);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      await container.read(privacyContentProvider.notifier).ensureLoaded();

      await pushRoute(tester, AppRoutes.readerComic, _publicBookUrl);

      expect(find.byType(ReaderComicScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsNothing);
      expect(find.byKey(const ValueKey('privateBookGateLocked')), findsNothing);
    });
  });

  group('听书路由 /audio', () {
    testWidgets('私密书未授权：锁定页取代播放器，且不取章节', (tester) async {
      await bootContainer(books: [_privateBook]);
      await pumpApp(tester);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      await container.read(privacyContentProvider.notifier).ensureLoaded();

      await pushRoute(tester, AppRoutes.audio, _privateBook);

      expect(
        find.byType(AudioScreen),
        findsNothing,
        reason: '未授权时播放器不得进入组件树（不建媒体会话）',
      );
      expect(
        find.byKey(const ValueKey('privateBookGateLocked')),
        findsOneWidget,
      );
      expect(api.getChaptersCalls, 0, reason: '不得加载章节（联网取数）');
    });
  });

  group('视频路由 /video', () {
    testWidgets('私密书未授权：锁定页取代播放器', (tester) async {
      await bootContainer(books: [_privateBook]);
      await pumpApp(tester);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      await container.read(privacyContentProvider.notifier).ensureLoaded();

      await pushRoute(tester, AppRoutes.video, _privateBook);

      expect(
        find.byType(VideoScreen),
        findsNothing,
        reason: '未授权时视频播放器不得进入组件树',
      );
      expect(
        find.byKey(const ValueKey('privateBookGateLocked')),
        findsOneWidget,
      );
      expect(api.getChaptersCalls, 0);
    });

    testWidgets('悬浮窗回全屏（book 为私密书）同样被拦截', (tester) async {
      await bootContainer(books: [_privateBook]);
      await pumpApp(tester);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      await container.read(privacyContentProvider.notifier).ensureLoaded();

      await pushRoute(
        tester,
        AppRoutes.video,
        VideoScreenArgs(
          videoUrl: 'https://cdn.example.com/a.m3u8',
          title: '私密视频',
          book: _privateBook,
          presetUrl: 'https://cdn.example.com/a.m3u8',
        ),
      );

      expect(find.byType(VideoScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('privateBookGateLocked')),
        findsOneWidget,
      );
    });

    testWidgets('直链播放（无书籍身份）：闸门直接放行，不显示锁定页', (tester) async {
      await bootContainer(books: [_privateBook]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: PrivateBookGate(
              bookUrl: '',
              child: Text('DIRECT_LINK_PLAYER'),
            ),
          ),
        ),
      );
      // 无书身份：即使策略/标记未就绪也不得占位（避免给直链加无谓闪烁）
      expect(find.text('DIRECT_LINK_PLAYER'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('DIRECT_LINK_PLAYER'), findsOneWidget);
      expect(find.byKey(const ValueKey('privateBookGateLocked')), findsNothing);
    });
  });

  group('首帧竞态', () {
    testWidgets('策略/标记未就绪：只显示带锁占位，不组合内容；就绪后转锁定页', (tester) async {
      await bootContainer(books: [_privateBook]);
      // 刻意不等待 ensureLoaded：首帧 provider 尚未 loaded
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: PrivateBookGate(
              bookUrl: _privateBookUrl,
              child: Text('SECRET_CONTENT'),
            ),
          ),
        ),
      );
      expect(
        find.text('SECRET_CONTENT'),
        findsNothing,
        reason: '首帧不得先渲染内容（空快照会把私密书判成非私密）',
      );
      expect(
        find.byKey(const ValueKey('privateBookGateSplash')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      expect(find.text('SECRET_CONTENT'), findsNothing);
      expect(
        find.byKey(const ValueKey('privateBookGateLocked')),
        findsOneWidget,
      );
    });

    testWidgets('验证成功后放行内容；离开页面撤销 EveryTime 授权', (tester) async {
      await bootContainer(books: [_privateBook]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: PrivateBookGate(
              bookUrl: _privateBookUrl,
              child: Text('SECRET_CONTENT'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('privacyUnlockField')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
      await tester.pumpAndSettle();

      expect(find.text('SECRET_CONTENT'), findsOneWidget);
      expect(
        container.read(privacyNotifierProvider).grantedBookUrls,
        contains(_privateBookUrl),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        container.read(privacyNotifierProvider).grantedBookUrls,
        isEmpty,
        reason: '离开页面（gate dispose）必须撤销 EveryTime 授权',
      );
    });
  });

  group('浮窗入口静默判定', () {
    test('未授权私密书：不允许无提示放行', () async {
      await bootContainer(books: [_privateBook]);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      final privacy = container.read(privacyNotifierProvider);

      expect(
        isBookAllowedWithoutPrompt(_privateBook, privacy, content),
        isFalse,
      );
    });

    test('会话级解锁后允许', () async {
      await bootContainer(
        books: [_privateBook],
        scope: PrivacyUnlockScope.appSession,
      );
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      await container
          .read(privacyNotifierProvider.notifier)
          .verifyForTarget('pw', bookUrl: _privateBookUrl);
      final privacy = container.read(privacyNotifierProvider);

      expect(
        isBookAllowedWithoutPrompt(_privateBook, privacy, content),
        isTrue,
      );
    });

    test('非私密书始终允许', () async {
      await bootContainer(books: [_publicBook]);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      final privacy = container.read(privacyNotifierProvider);

      expect(isBookAllowedWithoutPrompt(_publicBook, privacy, content), isTrue);
    });

    test('总开关关闭时允许', () async {
      await bootContainer(books: [_privateBook], enabled: false);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      final privacy = container.read(privacyNotifierProvider);

      expect(
        isBookAllowedWithoutPrompt(_privateBook, privacy, content),
        isTrue,
      );
    });
  });
}
