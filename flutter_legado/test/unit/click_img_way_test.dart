// [批1b-2b | 2026-11-04] 正文图片点击五档纯逻辑单测 — 全栈工程师
//
// 依据：
// - 原版 `ContentTextView.kt:398-444` 五档分流
// - 原版 `ImageColumn`/`AnalyzeUrl.paramPattern`：图片动作与 headers 编码在
//   复合 URL 的 `,{json}` 后缀（click/js/headers）
// - 参考版默认 "2"=兼容旧版
//
// 覆盖：
// 1. 档位钳制与文案（0..4，缺省/非法回落 "2"）
// 2. 复合 URL 解析（click/action/js/headers、空白、坏 JSON fail-closed）
// 3. resolveClickImgTap 五档矩阵（含 action 能力缺失回退预览、双击档首击消费）
// 4. 当前 action 能力常量锁（缺 FFI 的执行能力阻塞登记）
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/click_img_way.dart';

void main() {
  group('档位钳制与文案', () {
    test('合法 0..4 原样保留', () {
      for (final way in ['0', '1', '2', '3', '4']) {
        expect(clampClickImgWay(way), way);
        expect(clickImgWayLabel(way), kClickImgWayOptions[way]);
      }
    });

    test('缺省/空串/非法值回落参考版默认 "2"', () {
      for (final raw in [null, '', ' ', '5', '-1', 'compat', '99']) {
        expect(clampClickImgWay(raw), '2', reason: 'raw=$raw');
        expect(clickImgWayLabel(raw), '兼容旧版');
      }
    });

    test('五档文案对齐原版 click_image_way_title', () {
      expect(kClickImgWayOptions, {
        '0': '默认行为',
        '1': '预览图片',
        '2': '兼容旧版',
        '3': '关闭点击',
        '4': '双击生效',
      });
    });
  });

  group('parseClickImgUrlOptions 复合 URL', () {
    test('click/js/headers 完整解析并剥离为纯 URL', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.webp,'
        '{"click":"act()","js":"legacy()","headers":{"Referer":"https://x/"}}',
      );
      expect(opts.url, 'https://cdn.example.com/a.webp');
      expect(opts.click, 'act()');
      expect(opts.js, 'legacy()');
      expect(opts.headers, {'Referer': 'https://x/'});
      expect(opts.hasClick, isTrue);
      expect(opts.hasJs, isTrue);
      expect(opts.hasAction, isTrue);
    });

    test('参考版 action 键作为 click 别名', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.jpg,{"action":"doIt()"}',
      );
      expect(opts.click, 'doIt()');
      expect(opts.hasClick, isTrue);
    });

    test('click 优先于 action（两键并存时）', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.jpg,{"click":"c()","action":"a()"}',
      );
      expect(opts.click, 'c()');
    });

    test('空串动作视为非动作', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.jpg,{"click":"  ","js":""}',
      );
      expect(opts.hasClick, isFalse);
      expect(opts.hasJs, isFalse);
      expect(opts.hasAction, isFalse);
    });

    test('普通 URL 无动作', () {
      final opts = parseClickImgUrlOptions('https://cdn.example.com/a.jpg');
      expect(opts.url, 'https://cdn.example.com/a.jpg');
      expect(opts.hasAction, isFalse);
      expect(opts.headers, isEmpty);
    });

    test('参数分隔符允许空白（对齐 AnalyzeUrl.paramPattern）', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.jpg , {"click":"c()"}',
      );
      expect(opts.url, 'https://cdn.example.com/a.jpg');
      expect(opts.click, 'c()');
    });

    test('坏 JSON fail-closed：保留纯 URL，不抛错', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.jpg,{bad',
      );
      expect(opts.url, 'https://cdn.example.com/a.jpg');
      expect(opts.hasAction, isFalse);
    });

    test('非 ,{ 后缀不视为复合参数（URL 原样保留）', () {
      const raw = 'https://cdn.example.com/a.jpg,[1,2]';
      final opts = parseClickImgUrlOptions(raw);
      expect(opts.url, raw, reason: 'paramPattern 要求 JSON 以 { 开头');
      expect(opts.hasAction, isFalse);
    });

    test('headers 值统一转字符串（数字/布尔）', () {
      final opts = parseClickImgUrlOptions(
        'https://cdn.example.com/a.jpg,'
        '{"headers":{"X-Count":2,"X-Flag":true}}',
      );
      expect(opts.headers, {'X-Count': '2', 'X-Flag': 'true'});
    });
  });

  group('resolveClickImgTap 五档矩阵', () {
    ClickImgTapEffect resolve(
      String way, {
      bool online = true,
      bool click = false,
      bool js = false,
      bool doubleTap = false,
      bool actionAvailable = false,
    }) => resolveClickImgTap(
      way: way,
      onlineText: online,
      hasClick: click,
      hasJs: js,
      doubleTap: doubleTap,
      actionAvailable: actionAvailable,
    );

    test('"1" 预览：无论在线/动作/双击均预览', () {
      expect(resolve('1'), ClickImgTapEffect.preview);
      expect(
        resolve('1', online: false, click: true),
        ClickImgTapEffect.preview,
      );
      expect(resolve('1', doubleTap: true), ClickImgTapEffect.preview);
    });

    test('"2" 兼容：离线书不消费（对齐 isOnLineTxt 门槛）', () {
      expect(
        resolve('2', online: false, click: true, actionAvailable: true),
        ClickImgTapEffect.passThrough,
      );
      expect(
        resolve('2', online: false, js: true),
        ClickImgTapEffect.passThrough,
      );
    });

    test('"2" 在线书无 click/js → 不消费', () {
      expect(resolve('2'), ClickImgTapEffect.passThrough);
    });

    test('"2" 在线书 click 非空：有执行能力 action，无能力回退预览', () {
      expect(
        resolve('2', click: true, actionAvailable: true),
        ClickImgTapEffect.runAction,
      );
      expect(
        resolve('2', click: true, actionAvailable: false),
        ClickImgTapEffect.preview,
      );
    });

    test('"2" 在线书仅 js（oldClickImg 路径）：有 action 语义，无能力预览', () {
      expect(
        resolve('2', js: true, actionAvailable: true),
        ClickImgTapEffect.runAction,
      );
      expect(
        resolve('2', js: true, actionAvailable: false),
        ClickImgTapEffect.preview,
      );
    });

    test('"3" 关闭：始终不消费（穿透给页面）', () {
      expect(
        resolve('3', click: true, actionAvailable: true),
        ClickImgTapEffect.passThrough,
      );
      expect(resolve('3', doubleTap: true), ClickImgTapEffect.passThrough);
    });

    test('"4" 双击：首击消费不动作', () {
      expect(resolve('4', click: true), ClickImgTapEffect.consume);
      expect(
        resolve('4', js: true, doubleTap: false),
        ClickImgTapEffect.consume,
      );
    });

    test('"4" 双击：第二击 click 非空 → action/预览回退', () {
      expect(
        resolve('4', click: true, doubleTap: true, actionAvailable: true),
        ClickImgTapEffect.runAction,
      );
      expect(
        resolve('4', click: true, doubleTap: true, actionAvailable: false),
        ClickImgTapEffect.preview,
      );
    });

    test('"4" 双击：第二击无 click → 预览（任务口径）', () {
      expect(
        resolve('4', doubleTap: true, actionAvailable: true),
        ClickImgTapEffect.preview,
      );
      expect(
        resolve('4', js: true, doubleTap: true, actionAvailable: true),
        ClickImgTapEffect.preview,
        reason: '双击档只看 click，js 不触发（对齐原版分支）',
      );
    });

    test('"0" 默认行为：click 非空 → action/预览回退', () {
      expect(
        resolve('0', click: true, actionAvailable: true),
        ClickImgTapEffect.runAction,
      );
      expect(
        resolve('0', click: true, actionAvailable: false),
        ClickImgTapEffect.preview,
      );
    });

    test('"0" 默认行为：无 click（即使有 js）→ 不消费', () {
      expect(resolve('0'), ClickImgTapEffect.passThrough);
      expect(resolve('0', js: true), ClickImgTapEffect.passThrough);
    });

    test('非法档位按钳制后的 "2" 处理', () {
      expect(
        resolve('9', online: false, click: true),
        ClickImgTapEffect.passThrough,
      );
      expect(
        resolve('x', online: true, click: true, actionAvailable: false),
        ClickImgTapEffect.preview,
      );
    });
  });

  test('当前构建具备图片 action 执行能力（批20-A 契约 §2.21）', () {
    expect(
      kClickImgActionSupported,
      isTrue,
      reason:
          'Rust BookApi.evalImageAction + FFI eval_image_action 已交付；'
          '若回退能力须同步更新本断言与 image-dominant 回退说明',
    );
  });

  test('默认 actionAvailable 打开后，档位 0/2/4 命中动作走 runAction', () {
    expect(
      resolveClickImgTap(
        way: '0',
        onlineText: true,
        hasClick: true,
        hasJs: false,
        doubleTap: false,
      ),
      ClickImgTapEffect.runAction,
    );
    expect(
      resolveClickImgTap(
        way: '2',
        onlineText: true,
        hasClick: false,
        hasJs: true,
        doubleTap: false,
      ),
      ClickImgTapEffect.runAction,
    );
    expect(
      resolveClickImgTap(
        way: '4',
        onlineText: true,
        hasClick: true,
        hasJs: false,
        doubleTap: true,
      ),
      ClickImgTapEffect.runAction,
    );
  });
}
