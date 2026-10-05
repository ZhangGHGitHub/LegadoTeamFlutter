import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/video_float_window.dart';

/// [V-B3] 视频悬浮窗 Dart 侧单测：
/// - 状态序列化（MethodChannel Map 往返）
/// - 同源判定（活动悬浮窗接管语义）
/// - 桥的平台门控降级（非 Android 一律安全降级）
/// - 协调器连播/播完/回全屏/进度落库状态机
/// （入口按钮 widget 测试见 test/widget/video_float_window_button_test.dart）

/// 假桥：记录调用与显示状态（不触 MethodChannel）
class _FakeBridge extends VideoFloatWindowBridge {
  final List<VideoFloatWindowState> shown = [];
  final List<String> calls = [];
  bool showResult = true;
  VideoFloatWindowState? probeState;

  @override
  Future<bool> show(VideoFloatWindowState state) async {
    shown.add(state);
    calls.add('show');
    return showResult;
  }

  @override
  Future<VideoFloatWindowState?> getState() async {
    calls.add('getState');
    return probeState;
  }

  @override
  Future<VideoFloatWindowState?> takeOver() async {
    calls.add('takeOver');
    final state = probeState;
    probeState = null;
    return state;
  }

  @override
  Future<void> dismiss() async {
    calls.add('dismiss');
  }

  @override
  Future<void> requestOverlayPermission() async {
    calls.add('requestOverlayPermission');
  }
}

/// 假 BookApi：只承接协调器用到的读章节/落库/进度配置方法
class _FakeBookApi implements BookApi {
  final Map<String, String> chapterContents = {};
  final List<Map<Symbol, dynamic>> progressCalls = [];
  final List<Map<Symbol, dynamic>> configWrites = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name == 'Symbol("fetchChapterContent")') {
      final url = invocation.positionalArguments[1].toString();
      return Future<String>.value(chapterContents[url] ?? '');
    }
    if (name == 'Symbol("getChapterContent")') {
      final index = invocation.positionalArguments[1] as int;
      return Future<String>.value(chapterContents['#$index'] ?? '');
    }
    if (name == 'Symbol("updateReadingProgress")') {
      progressCalls.add(Map<Symbol, dynamic>.from(invocation.namedArguments));
      return Future<void>.value();
    }
    if (name == 'Symbol("setConfig")') {
      // setConfig(key, value) 为位置参数（BookApi:633）
      configWrites.add({
        #key: invocation.positionalArguments.isNotEmpty
            ? invocation.positionalArguments[0]
            : null,
        #value: invocation.positionalArguments.length > 1
            ? invocation.positionalArguments[1]
            : null,
      });
      return Future<void>.value();
    }
    if (name == 'Symbol("getConfig")') {
      return Future<String?>.value(null);
    }
    if (name == 'Symbol("deleteConfig")') {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

VideoFloatWindowState _state({
  String url = 'https://cdn.example/1.m3u8',
  String? bookUrl,
  String? directUrl,
  int chapterIndex = 0,
  int positionMs = 0,
}) =>
    VideoFloatWindowState(
      url: url,
      title: '第1集',
      bookName: '测试书',
      bookUrl: bookUrl,
      directUrl: directUrl,
      chapterIndex: chapterIndex,
      positionMs: positionMs,
      headers: const {'Referer': 'https://example.com'},
    );

void main() {
  group('VideoFloatWindowState', () {
    test('toMap/fromMap 往返保留全部字段', () {
      final state = VideoFloatWindowState(
        url: 'https://cdn.example/v.m3u8',
        title: '第2集',
        bookName: '书',
        headers: const {'User-Agent': 'ua'},
        positionMs: 5000,
        playing: false,
        speed: 2.0,
        bookUrl: 'book://1',
        chapterIndex: 1,
        chapterTitle: '第2集',
        directUrl: 'https://cdn.example/direct',
        hasPrev: true,
        hasNext: false,
        mpdTempPath: '/tmp/x.mpd',
      );
      final restored = VideoFloatWindowState.fromMap(state.toMap())!;
      expect(restored.url, state.url);
      expect(restored.title, state.title);
      expect(restored.bookName, state.bookName);
      expect(restored.headers, state.headers);
      expect(restored.positionMs, state.positionMs);
      expect(restored.playing, isFalse);
      expect(restored.speed, 2.0);
      expect(restored.bookUrl, state.bookUrl);
      expect(restored.chapterIndex, 1);
      expect(restored.chapterTitle, state.chapterTitle);
      expect(restored.directUrl, state.directUrl);
      expect(restored.hasPrev, isTrue);
      expect(restored.hasNext, isFalse);
      expect(restored.mpdTempPath, state.mpdTempPath);
    });

    test('fromMap 拒绝空 url，缺失字段降级默认值', () {
      expect(VideoFloatWindowState.fromMap(null), isNull);
      expect(VideoFloatWindowState.fromMap({'url': ''}), isNull);
      final minimal = VideoFloatWindowState.fromMap({
        'url': 'file:///tmp/a.mpd',
      })!;
      expect(minimal.positionMs, 0);
      expect(minimal.playing, isTrue);
      expect(minimal.speed, 1.0);
      expect(minimal.chapterIndex, -1);
      expect(minimal.headers, isEmpty);
    });

    test('isSameContent 按书籍/直链模式判定同源', () {
      final bookState = _state(bookUrl: 'book://1', chapterIndex: 3);
      expect(bookState.isSameContent(bookUrl: 'book://1', videoUrl: null), isTrue);
      expect(bookState.isSameContent(bookUrl: 'book://2', videoUrl: null), isFalse);

      final direct = _state(directUrl: 'https://cdn.example/direct');
      expect(
        direct.isSameContent(bookUrl: null, videoUrl: 'https://cdn.example/direct'),
        isTrue,
      );
      expect(
        direct.isSameContent(bookUrl: null, videoUrl: 'https://cdn.example/other'),
        isFalse,
      );
      // 书籍态对直链查询 / 直链态对书籍查询 → 不同源
      expect(bookState.isSameContent(bookUrl: null, videoUrl: 'x'), isFalse);
      expect(direct.isSameContent(bookUrl: 'book://1', videoUrl: null), isFalse);
    });
  });

  group('VideoFloatWindowBridge 平台门控', () {
    test('非 Android 全部安全降级为 false/null', () async {
      final bridge = VideoFloatWindowBridge()..supportedOverride = false;
      expect(bridge.isSupported, isFalse);
      expect(await bridge.canDrawOverlays(), isFalse);
      expect(await bridge.show(_state()), isFalse);
      expect(await bridge.getState(), isNull);
      expect(await bridge.takeOver(), isNull);
      await bridge.requestOverlayPermission();
      await bridge.dismiss();
    });
  });

  group('VideoFloatWindowCoordinator', () {
    test('enterWindow 成功后捕获上下文', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final ok = await coord.enterWindow(
        state: _state(bookUrl: 'book://1'),
        book: Book(name: '书', bookUrl: 'book://1', origin: 'o'),
        chapters: [BookChapter(url: 'c1', title: '第1集')],
        api: _FakeBookApi(),
      );
      expect(ok, isTrue);
      expect(coord.isCapturing, isTrue);
      expect(bridge.shown, hasLength(1));
    });

    test('enterWindow 失败（无权限）不捕获', () async {
      final bridge = _FakeBridge()..showResult = false;
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final ok = await coord.enterWindow(state: _state(), api: _FakeBookApi());
      expect(ok, isFalse);
      expect(coord.isCapturing, isFalse);
    });

    test('onCompleted 推进下一集并 ACTION_REPLACE 续播', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final api = _FakeBookApi()
        ..chapterContents['c2'] = 'https://cdn.example/2.m3u8';
      final book = Book(name: '书', bookUrl: 'book://1', origin: 'o');
      final chapters = [
        BookChapter(url: 'c1', title: '第1集'),
        BookChapter(url: 'c2', title: '第2集'),
      ];
      await coord.enterWindow(
        state: _state(bookUrl: 'book://1', chapterIndex: 0, positionMs: 1000),
        book: book,
        chapters: chapters,
        api: api,
      );

      await coord.handleNativeEvent(MethodCall('onCompleted', {
        'url': 'https://cdn.example/1.m3u8',
        'bookUrl': 'book://1',
        'chapterIndex': 0,
        'positionMs': 60000,
      }));

      expect(bridge.shown, hasLength(2));
      final next = bridge.shown.last;
      expect(next.url, 'https://cdn.example/2.m3u8');
      expect(next.chapterIndex, 1);
      expect(next.title, '第2集');
      expect(next.positionMs, 0);
      expect(next.hasPrev, isTrue);
      expect(next.hasNext, isFalse);
      expect(next.bookUrl, 'book://1');
      // 切集前旧集进度已落库（chapterPos = 完成位置）
      expect(api.progressCalls, isNotEmpty);
      expect(api.progressCalls.single[#chapterPos], 60000);
      expect(coord.isCapturing, isTrue);
    });

    test('onCompleted 无下一集 → 提示已播放完并关闭悬浮窗', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final notices = <String>[];
      coord.onNotice = notices.add;
      final api = _FakeBookApi();
      await coord.enterWindow(
        state: _state(bookUrl: 'book://1'),
        book: Book(name: '书', bookUrl: 'book://1', origin: 'o'),
        chapters: [BookChapter(url: 'c1', title: '第1集')],
        api: api,
      );

      await coord.handleNativeEvent(MethodCall('onCompleted', {
        'url': 'https://cdn.example/1.m3u8',
        'bookUrl': 'book://1',
        'chapterIndex': 0,
        'positionMs': 60000,
      }));

      expect(notices, contains('已播放完'));
      expect(bridge.calls, contains('dismiss'));
      expect(bridge.shown, hasLength(1));
      expect(coord.isCapturing, isFalse);
      expect(api.progressCalls, isNotEmpty);
    });

    test('onSkipNext 卷标题跳过（对齐 upDurIndex 跳过卷）', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final api = _FakeBookApi()
        ..chapterContents['c3'] = 'https://cdn.example/3.m3u8';
      final book = Book(name: '书', bookUrl: 'book://1', origin: 'o');
      final chapters = [
        BookChapter(url: 'c1', title: '第1集'),
        BookChapter(url: 'c2', title: '第一卷', isVolume: true),
        BookChapter(url: 'c3', title: '第3集'),
      ];
      await coord.enterWindow(
        state: _state(bookUrl: 'book://1', chapterIndex: 0),
        book: book,
        chapters: chapters,
        api: api,
      );

      await coord.handleNativeEvent(const MethodCall('onSkipNext', null));

      expect(bridge.shown.last.chapterIndex, 2);
      expect(bridge.shown.last.url, 'https://cdn.example/3.m3u8');
    });

    test('onClosed 落库进度并清会话（直链写 video_pos_）', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final api = _FakeBookApi();
      await coord.enterWindow(
        state: _state(directUrl: 'https://cdn.example/direct'),
        api: api,
      );

      await coord.handleNativeEvent(MethodCall('onClosed', {
        'url': 'https://cdn.example/1.m3u8',
        'directUrl': 'https://cdn.example/direct',
        'positionMs': 7000,
      }));

      expect(api.configWrites, isNotEmpty);
      expect(api.configWrites.single[#key].toString(), contains('direct'));
      expect(coord.isCapturing, isFalse);
      expect(bridge.calls, isNot(contains('dismiss')));
    });

    test('handleReturnState 落库并回调 openFullscreen（带书籍上下文）', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final api = _FakeBookApi();
      final book = Book(name: '书', bookUrl: 'book://1', origin: 'o');
      await coord.enterWindow(
        state: _state(bookUrl: 'book://1'),
        book: book,
        chapters: [BookChapter(url: 'c1', title: '第1集')],
        api: api,
      );
      VideoFloatWindowState? captured;
      Book? capturedBook;
      coord.openFullscreen = (state, b) {
        captured = state;
        capturedBook = b;
      };

      await coord.handleReturnState({
        'url': 'https://cdn.example/1.m3u8',
        'bookUrl': 'book://1',
        'chapterIndex': 0,
        'positionMs': 4000,
        'playing': false,
      });

      expect(captured, isNotNull);
      expect(captured!.positionMs, 4000);
      expect(captured!.playing, isFalse);
      expect(capturedBook?.bookUrl, 'book://1');
      expect(api.progressCalls, isNotEmpty);
      expect(coord.isCapturing, isFalse);
    });

    test('probeAndTakeOver 同源接管 / 异源关闭并落库', () async {
      final bridge = _FakeBridge();
      final coord = VideoFloatWindowCoordinator(bridge: bridge);
      final api = _FakeBookApi();

      bridge.probeState = _state(bookUrl: 'book://1', positionMs: 9000);
      final taken = await coord.probeAndTakeOver(bookUrl: 'book://1', api: api);
      expect(taken, isNotNull);
      expect(taken!.positionMs, 9000);
      expect(bridge.calls, contains('takeOver'));

      bridge.probeState = _state(
        directUrl: 'https://cdn.example/old',
        positionMs: 3000,
      );
      final notTaken = await coord.probeAndTakeOver(
        videoUrl: 'https://cdn.example/new',
        api: api,
      );
      expect(notTaken, isNull);
      expect(bridge.calls, contains('dismiss'));
      expect(api.configWrites, isNotEmpty);

      bridge.probeState = null;
      expect(await coord.probeAndTakeOver(bookUrl: 'book://1'), isNull);
    });
  });
}
