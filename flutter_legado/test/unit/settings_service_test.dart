import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService 网络设置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('代理默认为 none', () async {
      final service = SettingsService();
      expect(await service.getProxyType(), 'none');
      expect(await service.getProxyHost(), '');
      expect(await service.getProxyPort(), 0);
    });

    test('代理配置读写一致', () async {
      final service = SettingsService();
      await service.setProxyType('http');
      await service.setProxyHost('127.0.0.1');
      await service.setProxyPort(7890);
      expect(await service.getProxyType(), 'http');
      expect(await service.getProxyHost(), '127.0.0.1');
      expect(await service.getProxyPort(), 7890);
    });

    test('SOCKS5 代理读写一致', () async {
      final service = SettingsService();
      await service.setProxyType('socks5');
      await service.setProxyHost('192.168.1.10');
      await service.setProxyPort(1080);
      expect(await service.getProxyType(), 'socks5');
      expect(await service.getProxyHost(), '192.168.1.10');
      expect(await service.getProxyPort(), 1080);
    });

    test('请求超时默认 30 秒且读写一致', () async {
      final service = SettingsService();
      expect(await service.getRequestTimeout(), 30);
      await service.setRequestTimeout(15);
      expect(await service.getRequestTimeout(), 15);
    });
  });
}
