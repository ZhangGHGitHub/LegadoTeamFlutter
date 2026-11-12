// 图片动作返回值解析单元测试（契约 §2.21 evalImageAction，批21-A）
//
// 锁定：
// 1. 无 UI action 的纯字符串返回值 → result 原样、actions 为空（向后兼容）；
// 2. 有 action 的信封 → 拆出 result 与 actions（含动态拼接 toast 消息）；
// 3. 空 actions 数组 / 普通 JSON 对象 / 坏 JSON → 一律按纯字符串处理；
// 4. `BookApi.evalImageActionOutcome` 扩展对真实实现与 Mock 均可用。

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/image_action_outcome.dart';

class _FakeImageActionApi implements BookApi {
  _FakeImageActionApi(this.raw);

  final String raw;
  final List<String> actions = <String>[];

  @override
  Future<String> evalImageAction(
    String bookUrl,
    int chapterIndex,
    String action,
    String imgSrc,
  ) async {
    actions.add(action);
    return raw;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('本桩未实现：${invocation.memberName}');
}

void main() {
  group('ImageActionOutcome.parse', () {
    test('纯字符串结果：result 原样、无 actions（向后兼容）', () {
      final outcome = ImageActionOutcome.parse('动作返回值');
      expect(outcome.result, '动作返回值');
      expect(outcome.actions, isEmpty);
    });

    test('空串结果：原样返回', () {
      final outcome = ImageActionOutcome.parse('');
      expect(outcome.result, '');
      expect(outcome.actions, isEmpty);
    });

    test('信封：拆出 result 与动态拼接 toast 消息（a+b → ab）', () {
      final outcome = ImageActionOutcome.parse(
        '{"result":"done","actions":[{"action":"toast","message":"ab"}]}',
      );
      expect(outcome.result, 'done');
      expect(outcome.actions, hasLength(1));
      expect(outcome.actions.single.name, 'toast');
      expect(outcome.actions.single.message, 'ab');
    });

    test('信封：longToast 与 openUrl 均保留原始字段', () {
      final outcome = ImageActionOutcome.parse(
        '{"result":"","actions":['
        '{"action":"longToast","message":"长提示"},'
        '{"action":"openUrl","url":"https://example.com/a","mimeType":"text/html"}'
        ']}',
      );
      expect(outcome.result, '');
      expect(outcome.actions.map((a) => a.name), ['longToast', 'openUrl']);
      expect(outcome.actions[0].message, '长提示');
      expect(outcome.actions[1].url, 'https://example.com/a');
      expect(outcome.actions[1].data['mimeType'], 'text/html');
    });

    test('actions 为空数组：不视为信封（防误判普通 JSON 结果）', () {
      const raw = '{"result":"x","actions":[]}';
      final outcome = ImageActionOutcome.parse(raw);
      expect(outcome.result, raw);
      expect(outcome.actions, isEmpty);
    });

    test('普通 JSON 对象（无 result/actions）：按纯字符串返回', () {
      const raw = '{"foo":"bar"}';
      final outcome = ImageActionOutcome.parse(raw);
      expect(outcome.result, raw);
      expect(outcome.actions, isEmpty);
    });

    test('坏 JSON（以 { 开头但不可解析）：不抛错，按纯字符串返回', () {
      const raw = '{"result": ';
      final outcome = ImageActionOutcome.parse(raw);
      expect(outcome.result, raw);
      expect(outcome.actions, isEmpty);
    });

    test('actions 中非对象/缺 action 名的条目被跳过，合法条目保留', () {
      final outcome = ImageActionOutcome.parse(
        '{"result":"r","actions":['
        '"not-a-map",'
        '{"message":"缺动作名"},'
        '{"action":"toast","message":"ok"}'
        ']}',
      );
      expect(outcome.result, 'r');
      expect(outcome.actions, hasLength(1));
      expect(outcome.actions.single.message, 'ok');
    });

    test('result 非字符串（如数字）：不视为信封', () {
      const raw = '{"result":1,"actions":[{"action":"toast","message":"x"}]}';
      final outcome = ImageActionOutcome.parse(raw);
      expect(outcome.result, raw);
      expect(outcome.actions, isEmpty);
    });
  });

  group('BookApi.evalImageActionOutcome 扩展', () {
    test('拆包并透传原参数', () async {
      final api = _FakeImageActionApi(
        '{"result":"ok","actions":[{"action":"toast","message":"ab"}]}',
      );
      final outcome = await api.evalImageActionOutcome(
        'https://book.example.com/1',
        7,
        "java.toast('a' + 'b')",
        'https://img.example.com/a.jpg',
      );
      expect(api.actions, ["java.toast('a' + 'b')"]);
      expect(outcome.result, 'ok');
      expect(outcome.actions.single.message, 'ab');
    });

    test('Mock 纯字符串返回值仍可用（无信封）', () async {
      final api = _FakeImageActionApi('mock:act()');
      final outcome = await api.evalImageActionOutcome('u', 1, 'act()', 's');
      expect(outcome.result, 'mock:act()');
      expect(outcome.actions, isEmpty);
    });
  });
}
