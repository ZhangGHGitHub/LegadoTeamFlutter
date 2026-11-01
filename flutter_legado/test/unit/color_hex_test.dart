// [设置批2b-1b-1-b | 2026-11-01] HEX 颜色解析/格式化单测 — 全栈工程师
//
// 覆盖：6/8 位、# 可省略、大小写、首尾空白、非法长度/字符、6 位补 FF、
// 格式化不补前导 0（参考版 Integer.toHexString 形态）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/color_hex.dart';

void main() {
  group('parseArgbHexColor', () {
    test('6 位 #RRGGBB 补 FF 前缀', () {
      expect(parseArgbHexColor('#112233'), 0xFF112233);
      expect(parseArgbHexColor('112233'), 0xFF112233);
      expect(parseArgbHexColor('  #AABBCC  '), 0xFFAABBCC);
    });

    test('8 位 #AARRGGBB 原样保留', () {
      expect(parseArgbHexColor('#80112233'), 0x80112233);
      expect(parseArgbHexColor('80112233'), 0x80112233);
      expect(parseArgbHexColor('#00000000'), 0x00000000);
    });

    test('大小写不敏感', () {
      expect(parseArgbHexColor('#aAbBcC'), 0xFFAABBCC);
      expect(parseArgbHexColor('#80abcdef'), 0x80ABCDEF);
    });

    test('非法长度/字符返回 null', () {
      expect(parseArgbHexColor(''), isNull);
      expect(parseArgbHexColor('#'), isNull);
      expect(parseArgbHexColor('#12345'), isNull);
      expect(parseArgbHexColor('#1234567'), isNull);
      expect(parseArgbHexColor('#123456789'), isNull);
      expect(parseArgbHexColor('#GGGGGG'), isNull);
      expect(parseArgbHexColor('red'), isNull);
    });
  });

  group('argbToHex', () {
    test('不补前导 0（参考版 Integer.toHexString 形态）', () {
      expect(argbToHex(0xFFFF0000), '#FFFF0000');
      expect(argbToHex(0x80112233), '#80112233');
      expect(argbToHex(0xFF000000), '#FF000000');
      // 低位字段短于 8 位时不补 0
      expect(argbToHex(0x00112233), '#112233');
      expect(argbToHex(0x00000001), '#1');
    });
  });
}
