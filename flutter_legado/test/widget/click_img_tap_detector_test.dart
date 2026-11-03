// [批1b-2b | 2026-11-04] 图片点击手势分发 widget 测试（五档 + 双击时序）—
// 全栈工程师
//
// 覆盖：
// 1. "1" 预览：消费点击并打开预览
// 2. "2" 兼容：离线书/无动作穿透；在线书有动作且执行能力缺失 → 回退预览
// 3. "3" 关闭：不消费，点击穿透给页面
// 4. "4" 双击：单击消费不动作；双击窗口内第二击触发预览
// 5. "0" 默认行为：click 非空预览回退；无 click 穿透
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/click_img_way.dart';
import 'package:flutter_legado/src/widgets/reader/click_img_tap_detector.dart';

const _imgKey = Key('click-img');

class _Counters {
  int previews = 0;
  int pageTaps = 0;
}

Future<_Counters> _pumpDetector(
  WidgetTester tester, {
  required String way,
  bool online = true,
  ClickImgUrlOptions options =
      const ClickImgUrlOptions(url: 'https://cdn.example.com/a.jpg'),
}) async {
  final counters = _Counters();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          // 父级页面点击：对齐阅读页 onTap（穿透时应收到）
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => counters.pageTaps++,
            child: ClickImgTapDetector(
              clickImgWay: way,
              onlineText: online,
              options: options,
              onPreview: () => counters.previews++,
              child: Container(
                key: _imgKey,
                width: 200,
                height: 200,
                color: Colors.blue,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return counters;
}

Future<void> _tapOnce(WidgetTester tester) async {
  await tester.tap(find.byKey(_imgKey));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  const withClick = ClickImgUrlOptions(
    url: 'https://cdn.example.com/a.jpg',
    click: 'act()',
  );
  const withJs = ClickImgUrlOptions(
    url: 'https://cdn.example.com/a.jpg',
    js: 'legacy()',
  );

  group('"1" 预览图片', () {
    testWidgets('单击消费并打开预览（无动作也预览）', (tester) async {
      final c = await _pumpDetector(tester, way: '1');
      await _tapOnce(tester);
      expect(c.previews, 1);
      expect(c.pageTaps, 0, reason: '预览档必须消费点击');
    });

    testWidgets('有 click 动作时仍走预览（原版 "1" 分支）', (tester) async {
      final c = await _pumpDetector(tester, way: '1', options: withClick);
      await _tapOnce(tester);
      expect(c.previews, 1);
      expect(c.pageTaps, 0);
    });
  });

  group('"2" 兼容旧版', () {
    testWidgets('离线书（非在线文本）不消费 → 页面点击生效', (tester) async {
      final c = await _pumpDetector(
        tester,
        way: '2',
        online: false,
        options: withClick,
      );
      await _tapOnce(tester);
      expect(c.previews, 0);
      expect(c.pageTaps, 1, reason: '对齐原版 isOnLineTxt 门槛：非法/本地书 handled=false');
    });

    testWidgets('在线书无 click/js → 不消费', (tester) async {
      final c = await _pumpDetector(tester, way: '2');
      await _tapOnce(tester);
      expect(c.previews, 0);
      expect(c.pageTaps, 1);
    });

    testWidgets('在线书有 click、action 执行能力缺失 → 回退预览并消费', (tester) async {
      final c = await _pumpDetector(tester, way: '2', options: withClick);
      await _tapOnce(tester);
      expect(c.previews, 1, reason: '无 action 执行 FFI 时回退预览');
      expect(c.pageTaps, 0);
    });

    testWidgets('在线书仅 js（oldClickImg 路径）→ 回退预览', (tester) async {
      final c = await _pumpDetector(tester, way: '2', options: withJs);
      await _tapOnce(tester);
      expect(c.previews, 1);
      expect(c.pageTaps, 0);
    });
  });

  group('"3" 关闭点击', () {
    testWidgets('不消费，点击穿透给页面（任一动作均不触发预览）', (tester) async {
      final c = await _pumpDetector(tester, way: '3', options: withClick);
      await _tapOnce(tester);
      expect(c.previews, 0);
      expect(c.pageTaps, 1);
    });
  });

  group('"4" 双击生效（时序）', () {
    testWidgets('单击消费但不动作，也不穿透', (tester) async {
      final c = await _pumpDetector(tester, way: '4', options: withClick);
      await _tapOnce(tester);
      expect(c.previews, 0);
      expect(c.pageTaps, 0, reason: '双击档首击 handled=true');
    });

    testWidgets('双击窗口内第二击 → 预览（无执行能力回退）', (tester) async {
      final c = await _pumpDetector(tester, way: '4', options: withClick);
      await tester.tap(find.byKey(_imgKey));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(_imgKey));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.previews, 1);
      expect(c.pageTaps, 0);
    });

    testWidgets('无 click 的双击 → 预览（任务口径）', (tester) async {
      final c = await _pumpDetector(tester, way: '4');
      await tester.tap(find.byKey(_imgKey));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(_imgKey));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.previews, 1);
      expect(c.pageTaps, 0);
    });

    testWidgets('两次点击超出双击窗口 → 各自按单击消费，不触发预览', (tester) async {
      final c = await _pumpDetector(tester, way: '4', options: withClick);
      await tester.tap(find.byKey(_imgKey));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(_imgKey));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.previews, 0);
      expect(c.pageTaps, 0);
    });
  });

  group('"0" 默认行为', () {
    testWidgets('click 非空 → 预览回退并消费', (tester) async {
      final c = await _pumpDetector(tester, way: '0', options: withClick);
      await _tapOnce(tester);
      expect(c.previews, 1);
      expect(c.pageTaps, 0);
    });

    testWidgets('无 click → 穿透（js 不参与默认档，对齐原版 else 分支）',
        (tester) async {
      final c = await _pumpDetector(tester, way: '0', options: withJs);
      await _tapOnce(tester);
      expect(c.previews, 0);
      expect(c.pageTaps, 1);
    });
  });
}
