// WebViewLoginScreen.parseSourceHeaderMap 单元测试
//
// 登录域原版对齐重构（2026-08-28）：书源 header 字段解析为 WebView
// 附加请求头，对齐原版 toWebViewRequestConfig 的容错语义。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/webview_login_screen.dart';

void main() {
  group('parseSourceHeaderMap', () {
    test('JSON 对象解析', () {
      final map = WebViewLoginScreen.parseSourceHeaderMap(
        '{"User-Agent":"abc/1.0","Referer":"https://x.com"}',
      );
      expect(map, {
        'User-Agent': 'abc/1.0',
        'Referer': 'https://x.com',
      });
    });

    test('kv 串兜底（值可含 =）', () {
      final map = WebViewLoginScreen.parseSourceHeaderMap(
        'User-Agent=abc/1.0&Token=a=b',
      );
      expect(map, {'User-Agent': 'abc/1.0', 'Token': 'a=b'});
    });

    test('空串与 null 返回空 map', () {
      expect(WebViewLoginScreen.parseSourceHeaderMap(''), isEmpty);
      expect(WebViewLoginScreen.parseSourceHeaderMap(null), isEmpty);
    });

    test('非法内容返回空 map（不抛异常）', () {
      expect(WebViewLoginScreen.parseSourceHeaderMap(',,,&&'), isEmpty);
    });
  });
}
