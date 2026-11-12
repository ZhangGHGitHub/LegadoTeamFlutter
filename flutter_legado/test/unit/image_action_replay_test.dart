// 图片动作 UI 副作用回放单元测试（契约 §2.21 evalImageAction，批21-A）
//
// 锁定：
// 1. toast/longToast → SnackBar 回调，消息为 Rust 回传的实际值（动态拼接可见）；
// 2. showBrowser/openBrowser/startBrowser/openUrl → 系统浏览器打开器（Fake 断言）；
// 3. 未知 action / 缺 url / 非法 url → 不崩、不中断后续 action；
// 4. 打开器抛错或返回 false → 不向上抛（不打断阅读）。

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/image_action_outcome.dart';
import 'package:flutter_legado/src/utils/image_action_replay.dart';

class _ToastRecorder {
  final List<String> messages = <String>[];
  final List<bool> longFlags = <bool>[];

  void call(String message, {required bool isLong}) {
    messages.add(message);
    longFlags.add(isLong);
  }
}

class _OpenerRecorder {
  final List<Uri> uris = <Uri>[];
  int calls = 0;

  Future<bool> call(Uri uri) async {
    calls++;
    uris.add(uri);
    return true;
  }
}

ImageActionSideEffect _action(
  String name, [
  Map<String, dynamic> data = const {},
]) => ImageActionSideEffect(name: name, data: data);

void main() {
  test('toast/longToast 回放为 SnackBar 回调（动态消息 ab）', () async {
    final toasts = _ToastRecorder();
    await replayImageActionSideEffects(
      [
        _action('toast', {'message': 'ab'}),
        _action('longToast', {'message': '长提示'}),
      ],
      onToast: toasts.call,
      openExternal: _OpenerRecorder().call,
    );
    expect(toasts.messages, ['ab', '长提示']);
    expect(toasts.longFlags, [false, true]);
  });

  test('空消息 toast 不弹提示（不显示空 SnackBar）', () async {
    final toasts = _ToastRecorder();
    await replayImageActionSideEffects(
      [
        _action('toast', {'message': ''}),
        _action('longToast'),
      ],
      onToast: toasts.call,
      openExternal: _OpenerRecorder().call,
    );
    expect(toasts.messages, isEmpty);
  });

  test('showBrowser/openBrowser/startBrowser/openUrl 均交外链打开器', () async {
    final opener = _OpenerRecorder();
    await replayImageActionSideEffects(
      [
        _action('showBrowser', {'url': 'https://a.example.com/1'}),
        _action('openBrowser', {
          'url': 'https://b.example.com/2',
          'html': '<h1/>',
        }),
        _action('startBrowser', {'url': 'https://c.example.com/3'}),
        _action('openUrl', {'url': 'https://d.example.com/4'}),
      ],
      onToast: _ToastRecorder().call,
      openExternal: opener.call,
    );
    expect(opener.calls, 4);
    expect(opener.uris.map((u) => u.toString()), [
      'https://a.example.com/1',
      'https://b.example.com/2',
      'https://c.example.com/3',
      'https://d.example.com/4',
    ]);
  });

  test('缺 url / 非法 url / 未知 action：不崩且继续后续动作', () async {
    final opener = _OpenerRecorder();
    final toasts = _ToastRecorder();
    await replayImageActionSideEffects(
      [
        _action('openUrl'),
        _action('openUrl', {'url': '   '}),
        _action('openUrl', {'url': 'http://[::1'}),
        _action('refreshBookInfo'),
        _action('copyText', {'text': 'x'}),
        _action('toast', {'message': '仍应回放'}),
      ],
      onToast: toasts.call,
      openExternal: opener.call,
    );
    expect(opener.calls, 0);
    expect(toasts.messages, ['仍应回放']);
  });

  test('打开器返回 false / 抛错：不向上抛，后续动作继续', () async {
    final toasts = _ToastRecorder();
    final uris = <Uri>[];
    await replayImageActionSideEffects(
      [
        _action('openUrl', {'url': 'https://fail.example.com/1'}),
        _action('openUrl', {'url': 'https://throw.example.com/2'}),
        _action('toast', {'message': '继续'}),
      ],
      onToast: toasts.call,
      openExternal: (uri) async {
        uris.add(uri);
        if (uri.host.startsWith('throw')) {
          throw StateError('注入失败');
        }
        return false;
      },
    );
    expect(uris, hasLength(2));
    expect(toasts.messages, ['继续']);
  });
}
