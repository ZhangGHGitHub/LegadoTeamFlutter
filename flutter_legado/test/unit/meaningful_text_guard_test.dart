// [R-NaN / C2 N1 / U4 | 台账 0917] 跨页共享渲染层脏数据守卫单测
//
// 守卫与 Rust 解析层 `normalize_js_rule_result` 拒收判据同源对齐
//（空串 / NaN / 未渲染模板残留），渲染层兜底第三方书源 JS 字符串
// 拼接产物（"NaN : NaN"、"9.9分|{{$.categoryInfoV4}}"）与占位串。
//
// 编写：全栈工程师子代理 ｜ 2026-09-17

import 'package:flutter_legado/src/utils/meaningful_text_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hasUnrenderedTemplate', () {
    test('未渲染模板残留命中（成对形）', () {
      expect(hasUnrenderedTemplate(r'{{$.categoryInfoV4}}'), isTrue);
      expect(hasUnrenderedTemplate(r'9.9分|{{$.categoryInfoV4}}'), isTrue);
      expect(hasUnrenderedTemplate(r'{$xxx}'), isTrue);
      expect(hasUnrenderedTemplate(r'a {{$.b}} c {$d} e'), isTrue);
    });

    test('未闭合形亦命中（JS 规则截断产物，2.0.277 瀚海书阁实锤）', () {
      expect(hasUnrenderedTemplate(r'{{$.unclosed'), isTrue);
      expect(hasUnrenderedTemplate(r'{$unclosed'), isTrue);
    });

    test('合法数据不误判', () {
      expect(hasUnrenderedTemplate('9.9分'), isFalse);
      expect(hasUnrenderedTemplate('轻小说'), isFalse);
      // 单 { / 嵌套 JSON 对象 / 空串不命中（与 Rust 判据一致）
      expect(hasUnrenderedTemplate('{"a":{"b":1}}'), isFalse);
      expect(hasUnrenderedTemplate('{abc'), isFalse);
      expect(hasUnrenderedTemplate(''), isFalse);
    });
  });

  group('isMeaningfulText', () {
    test('空 / null / 空白 → 无数据', () {
      expect(isMeaningfulText(null), isFalse);
      expect(isMeaningfulText(''), isFalse);
      expect(isMeaningfulText('   '), isFalse);
    });

    test('精确 NAN 与 NaN 拼接形 → 无数据', () {
      expect(isMeaningfulText('NaN'), isFalse);
      expect(isMeaningfulText('NAN'), isFalse);
      expect(isMeaningfulText('NaN : NaN'), isFalse);
      expect(isMeaningfulText('nan,NaN'), isFalse);
    });

    test('第三方占位串 → 无数据', () {
      expect(isMeaningfulText('暂无专辑'), isFalse);
      expect(isMeaningfulText('暂无简介'), isFalse);
    });

    test('未渲染模板残留 → 无数据（U4）', () {
      expect(isMeaningfulText(r'{{$.categoryInfoV4}}'), isFalse);
      expect(isMeaningfulText(r'9.9分|{{$.x}}'), isFalse);
    });

    test('真实内容 → 有数据', () {
      expect(isMeaningfulText('唐家三少'), isTrue);
      expect(isMeaningfulText('9.9分'), isTrue);
      expect(isMeaningfulText('298.6万字'), isTrue);
    });
  });
}
