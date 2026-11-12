// 图片动作 UI 副作用回放单元测试（契约 §2.21 evalImageAction，批21-A）
//
// 锁定：
// 1. toast/longToast → SnackBar 回调，消息为 Rust 回传的实际值（动态拼接可见）；
// 2. 浏览器类 action → PlatformBridgeService 载荷分发器（字段同构断言），
//    不再直接 launchUrl（P1 回修：尊重拦截设置/二次确认/深链分流）；
// 3. 危险 scheme（javascript/data/file/content/intent）与无 scheme 一律拒绝，
//    分发器零调用；http/https/legado/yuedu 放行；
// 4. 未知 action / 缺 url / 非法 url → 不崩、不中断后续 action；
// 5. 分发器抛错 → 不向上抛（不打断阅读）。

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

class _PayloadRecorder {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  Future<void> call(Map<String, dynamic> payload) async {
    payloads.add(Map<String, dynamic>.from(payload));
  }
}

ImageActionSideEffect _action(
  String name, [
  Map<String, dynamic> data = const {},
]) => ImageActionSideEffect(name: name, data: data);

void main() {
  test('toast/longToast 回放为 SnackBar 回调（动态消息 ab）', () async {
    final toasts = _ToastRecorder();
    final dispatcher = _PayloadRecorder();
    await replayImageActionSideEffects(
      [
        _action('toast', {'message': 'ab'}),
        _action('longToast', {'message': '长提示'}),
      ],
      onToast: toasts.call,
      dispatchPayload: dispatcher.call,
    );
    expect(toasts.messages, ['ab', '长提示']);
    expect(toasts.longFlags, [false, true]);
    expect(dispatcher.payloads, isEmpty);
  });

  test('空消息 toast 不弹提示（不显示空 SnackBar）', () async {
    final toasts = _ToastRecorder();
    await replayImageActionSideEffects(
      [
        _action('toast', {'message': ''}),
        _action('longToast'),
      ],
      onToast: toasts.call,
      dispatchPayload: _PayloadRecorder().call,
    );
    expect(toasts.messages, isEmpty);
  });

  test('浏览器类 action 交桥接分发器，载荷字段保持同构', () async {
    final dispatcher = _PayloadRecorder();
    await replayImageActionSideEffects(
      [
        _action('showBrowser', {
          'action': 'showBrowser',
          'url': 'https://a.example.com/1',
          'html': '<h1/>',
        }),
        _action('openBrowser', {
          'action': 'openBrowser',
          'url': 'https://b.example.com/2',
          'html': '',
        }),
        _action('startBrowser', {
          'action': 'startBrowser',
          'url': 'https://c.example.com/3',
          'title': '下载',
          'html': '',
        }),
        _action('openUrl', {
          'action': 'openUrl',
          'url': 'https://d.example.com/4',
          'mimeType': 'text/html',
        }),
      ],
      onToast: _ToastRecorder().call,
      dispatchPayload: dispatcher.call,
    );
    expect(dispatcher.payloads, hasLength(4));
    expect(
      dispatcher.payloads.map((p) => p['action']),
      ['openBrowser', 'openBrowser', 'startBrowser', 'openUrl'],
      reason: 'showBrowser 入队名需归一为桥接认识的 openBrowser',
    );
    expect(dispatcher.payloads.map((p) => p['url']), [
      'https://a.example.com/1',
      'https://b.example.com/2',
      'https://c.example.com/3',
      'https://d.example.com/4',
    ]);
    expect(dispatcher.payloads[0]['html'], '<h1/>');
    expect(dispatcher.payloads[2]['title'], '下载');
    expect(dispatcher.payloads[3]['mimeType'], 'text/html');
  });

  test('危险 scheme 一律拒绝且分发器零调用（P1）', () async {
    const dangerous = [
      'javascript:alert(document.cookie)',
      'data:text/html,<script>alert(1)</script>',
      'file:///etc/passwd',
      'content://com.example.provider/secret',
      'intent://scan/#Intent;scheme=zxing;end',
      '//evil.example.com/no-scheme',
    ];
    for (final url in dangerous) {
      final dispatcher = _PayloadRecorder();
      await replayImageActionSideEffects(
        [
          _action('openUrl', {'action': 'openUrl', 'url': url}),
        ],
        onToast: _ToastRecorder().call,
        dispatchPayload: dispatcher.call,
      );
      expect(dispatcher.payloads, isEmpty, reason: '必须拒绝：$url');
    }
  });

  test('http/https/legado/yuedu 放行（大小写不敏感）', () async {
    final dispatcher = _PayloadRecorder();
    await replayImageActionSideEffects(
      [
        _action('openUrl', {
          'action': 'openUrl',
          'url': 'HTTPS://ok.example.com/1',
        }),
        _action('openUrl', {
          'action': 'openUrl',
          'url': 'http://ok.example.com/2',
        }),
        _action('openUrl', {
          'action': 'openUrl',
          'url': 'legado://import/bookSource',
        }),
        _action('openUrl', {
          'action': 'openUrl',
          'url': 'yuedu://import/booksource',
        }),
      ],
      onToast: _ToastRecorder().call,
      dispatchPayload: dispatcher.call,
    );
    expect(dispatcher.payloads, hasLength(4));
  });

  test('缺 url / 非法 url / 未知 action：不崩且继续后续动作', () async {
    final dispatcher = _PayloadRecorder();
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
      dispatchPayload: dispatcher.call,
    );
    expect(dispatcher.payloads, isEmpty);
    expect(toasts.messages, ['仍应回放']);
  });

  test('分发器抛错：不向上抛，后续动作继续', () async {
    final toasts = _ToastRecorder();
    final dispatched = <String>[];
    await replayImageActionSideEffects(
      [
        _action('openUrl', {
          'action': 'openUrl',
          'url': 'https://throw.example.com/1',
        }),
        _action('toast', {'message': '继续'}),
      ],
      onToast: toasts.call,
      dispatchPayload: (payload) async {
        dispatched.add(payload['url'] as String);
        throw StateError('注入失败');
      },
    );
    expect(dispatched, ['https://throw.example.com/1']);
    expect(toasts.messages, ['继续']);
  });
}
