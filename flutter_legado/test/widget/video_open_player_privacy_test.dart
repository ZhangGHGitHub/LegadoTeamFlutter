/// 书源 JS `openVideoPlayer` 私密闸门回归（批42 审查 P2-7）
///
/// 缺陷：修复前 `PlatformBridgeService._openVideoPlayer` 两条分支都不做私密
/// 判定——
/// - `isFloat=true` 直接 `VideoFloatWindowBridge.show`，绕过
///   `VideoFloatWindowCoordinator.enterWindow` 的 `canEnterWindowForBook`；
/// - `isFloat=false` push `/video` 只带 `Map<String,String>`，路由层
///   `PrivateBookGate(bookUrl: '')` 因无书身份直接放行。
/// 书源 JS 持有当前书上下文，可对私密书无验证拉起全屏/浮窗播放。
///
/// 覆盖：
/// 1. 私密书未授权 + `isFloat=true` → 零 `show` 调用（不创建浮窗）；
/// 2. 私密书未授权 + `isFloat=false` → 不 push 播放页；
/// 3. 载荷携带 `bookUrl`（Rust 权威身份）时同样拒绝未授权私密书；
/// 4. EveryTime 下已授权该私密书 → 放行（防过度拦截）；
/// 5. 非私密书 → 放行且无拦截提示；
/// 6. 无书身份 + 会话级解锁 → 放行（退化方案 B 不误锁）；
/// 7. 隐私总开关关闭 → 放行。
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
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/services/video_float_window.dart';

import '../mocks/privacy_mock_book_api.dart';

const _privateBookUrl = 'https://a.com/private-video';
const _publicBookUrl = 'https://a.com/public-video';
const _videoUrl = 'https://cdn.example.com/ep1.m3u8';

/// 拦截提示文案（与实现保持一致；改动文案须同步本常量）
const _blockedMessage = '私密视频需先在应用内验证后再播放';

final _privateBook = Book(
  bookUrl: _privateBookUrl,
  name: '私密视频',
  author: '作者',
  origin: 'https://a.com',
  bookType: BookType.video,
  isPrivate: true,
);

final _publicBook = Book(
  bookUrl: _publicBookUrl,
  name: '公开视频',
  author: '作者',
  origin: 'https://a.com',
  bookType: BookType.video,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;
  late _FakeFloatBridge floatBridge;
  late _RouteRecorder observer;

  PlatformBridgeService bridge() => PlatformBridgeService.instance;

  setUp(() {
    // Windows 宿主无法伪造 Platform.isAndroid：强制走 float 分支
    bridge().videoFloatPlatformOverride = true;
    floatBridge = _FakeFloatBridge()..supportedOverride = true;
    VideoFloatWindowBridge.instance = floatBridge;
  });

  tearDown(() {
    bridge().videoFloatPlatformOverride = null;
    VideoFloatWindowBridge.instance = VideoFloatWindowBridge();
  });

  Future<void> boot({
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

  /// 挂载带 [PlatformBridgeService.navigatorKey] 的宿主；播放页用 stub 路由，
  /// 避免拉起真实 VideoScreen（video_player 平台通道在测试宿主不可用）
  Future<void> pumpApp(WidgetTester tester) async {
    observer = _RouteRecorder();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: PlatformBridgeService.navigatorKey,
          navigatorObservers: [observer],
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('video-stub')),
          ),
          home: const Scaffold(body: Text('HOME')),
        ),
      ),
    );
    await tester.pump();
    // 判定链要求策略/标记就绪（与生产启动闸门一致）
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();
    await container.read(privacyContentProvider.notifier).ensureLoaded();
    await tester.pump();
  }

  Future<void> openVideo(
    WidgetTester tester, {
    String url = _videoUrl,
    String? bookUrl,
    bool isFloat = true,
  }) async {
    await bridge().dispatchPayload({
      'action': 'openVideoPlayer',
      'url': url,
      'title': '第1集',
      'isFloat': isFloat,
      'bookUrl': bookUrl ?? '',
    });
    await tester.pumpAndSettle();
  }

  group('私密书未授权', () {
    testWidgets('isFloat=true：不创建悬浮窗并提示', (tester) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);

      await openVideo(tester, isFloat: true);

      expect(floatBridge.shown, isEmpty, reason: '未授权私密书不得拉起浮窗');
      expect(find.text(_blockedMessage), findsOneWidget);
      expect(observer.pushedNames, isNot(contains(AppRoutes.video)));
    });

    testWidgets('isFloat=false：不 push 播放页并提示', (tester) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);

      await openVideo(tester, isFloat: false);

      expect(
        observer.pushedNames,
        isNot(contains(AppRoutes.video)),
        reason: '未授权私密书不得进入全屏播放页',
      );
      expect(find.text(_blockedMessage), findsOneWidget);
      expect(floatBridge.shown, isEmpty);
    });

    testWidgets('载荷携带 bookUrl（Rust 权威身份）同样拒绝', (tester) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);

      await openVideo(tester, bookUrl: _privateBookUrl, isFloat: true);

      expect(floatBridge.shown, isEmpty);
      expect(find.text(_blockedMessage), findsOneWidget);
    });

    testWidgets('无载荷 bookUrl 但视频页上下文是私密书：同样拒绝', (tester) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);
      // 模拟当前正停留在该私密视频页（书源 JS 在页内再调 openVideoPlayer）
      bridge().currentVideoBookUrl = _privateBookUrl;
      addTearDown(() => bridge().currentVideoBookUrl = '');

      await openVideo(tester, isFloat: true);

      expect(floatBridge.shown, isEmpty);
      expect(find.text(_blockedMessage), findsOneWidget);
    });

    testWidgets('无书身份 + 书架有私密内容 + 未解锁：拒绝（退化方案 B）', (
      tester,
    ) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);

      // 无 bookUrl、无视频页上下文 → 只能按「应用内已解锁」判定
      await openVideo(tester, isFloat: false);

      expect(observer.pushedNames, isNot(contains(AppRoutes.video)));
      expect(find.text(_blockedMessage), findsOneWidget);
    });

    testWidgets('无书身份 + 书架无私密内容：放行（不误锁普通直链）', (tester) async {
      await boot(books: [_publicBook]);
      await pumpApp(tester);

      await openVideo(tester, isFloat: true);

      expect(floatBridge.shown, hasLength(1));
      expect(find.text(_blockedMessage), findsNothing);
    });

    // 端到端：Rust `open_video_player` 真实载荷串（含 bookUrl）经
    // interceptResult 拦截管线（生产路径，非 dispatchPayload 直调）同样被拦
    testWidgets('interceptResult 管线：Rust 载荷串带 bookUrl 同样被拒', (
      tester,
    ) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);

      const rustPayload =
          '{"action":"openVideoPlayer","url":"$_videoUrl","title":"第1集",'
          '"isFloat":true,"bookUrl":"$_privateBookUrl"}';
      final result = await bridge().interceptResult(rustPayload);
      await tester.pumpAndSettle();

      expect(result, '', reason: '动作类载荷执行后回传空串');
      expect(floatBridge.shown, isEmpty);
      expect(find.text(_blockedMessage), findsOneWidget);
    });
  });

  group('防过度拦截', () {
    testWidgets('EveryTime 已授权该私密书：放行浮窗', (tester) async {
      await boot(books: [_privateBook]);
      await pumpApp(tester);
      await container
          .read(privacyNotifierProvider.notifier)
          .verifyForTarget('pw', bookUrl: _privateBookUrl);

      await openVideo(tester, bookUrl: _privateBookUrl, isFloat: true);

      expect(floatBridge.shown, hasLength(1));
      expect(find.text(_blockedMessage), findsNothing);
    });

    testWidgets('非私密书：放行浮窗且无提示', (tester) async {
      await boot(books: [_publicBook]);
      await pumpApp(tester);

      await openVideo(tester, bookUrl: _publicBookUrl, isFloat: true);

      expect(floatBridge.shown, hasLength(1));
      expect(find.text(_blockedMessage), findsNothing);
    });

    testWidgets('无书身份 + 会话级解锁：放行浮窗（退化方案 B 不误锁）', (
      tester,
    ) async {
      await boot(
        books: [_privateBook],
        scope: PrivacyUnlockScope.appSession,
      );
      await pumpApp(tester);
      await container.read(privacyNotifierProvider.notifier).unlock('pw');

      await openVideo(tester, isFloat: true);

      expect(floatBridge.shown, hasLength(1));
      expect(find.text(_blockedMessage), findsNothing);
    });

    testWidgets('隐私总开关关闭：放行浮窗', (tester) async {
      await boot(books: [_privateBook], enabled: false);
      await pumpApp(tester);

      await openVideo(tester, isFloat: true);

      expect(floatBridge.shown, hasLength(1));
      expect(find.text(_blockedMessage), findsNothing);
    });
  });
}

/// 假悬浮窗桥：只记录 show 调用（测试宿主无平台通道应答）
class _FakeFloatBridge extends VideoFloatWindowBridge {
  final List<VideoFloatWindowState> shown = [];

  @override
  Future<bool> show(VideoFloatWindowState state) async {
    shown.add(state);
    lastShowError = null;
    return true;
  }

  @override
  Future<VideoFloatWindowState?> getState() async => null;

  @override
  Future<void> requestOverlayPermission() async {}
}

class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushedNames = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedNames.add(route.settings.name);
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    pushedNames.add(newRoute?.settings.name);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
