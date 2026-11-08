// 批7a 闭环单元测试：替换净化总开关（replaceEnableDefault）prefs ↔ Rust 同步
//
// 背景：该开关此前只写 SharedPreferences，Rust 阅读链读 caches
// `config:replaceEnableDefault` 恒缺省 true，总开关对阅读净化无效。
// 覆盖口径：
// 1. 解析口径与 Rust `get_replace_enable_default` 一致（缺省/非法 true，
//    "false"/"0" 忽略大小写与空白 → false）；
// 2. 开关切换同时写 prefs 与 config（"true"/"false"）；
// 3. 启动同步：prefs false 且 Rust 缺省 → 写 "false"；值相同不写库；
//    默认 true 且 Rust 缺省 → 不写库且不抛错；USE_MOCK 跳过；失败静默。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/replace_default_sync.dart';

/// 记录 getConfig/setConfig 的桩 BookApi（仅实现被测面）
class _RecordingApi implements BookApi {
  _RecordingApi({
    this.rustValue,
    this.getThrows = false,
    this.setThrows = false,
  });

  String? rustValue;
  final bool getThrows;
  final bool setThrows;
  final List<String> getCalls = <String>[];
  final List<MapEntry<String, String>> setCalls = <MapEntry<String, String>>[];

  @override
  Future<String?> getConfig(String key) async {
    getCalls.add(key);
    if (getThrows) {
      throw StateError('读取配置失败（注入）');
    }
    return rustValue;
  }

  @override
  Future<void> setConfig(String key, String value) async {
    setCalls.add(MapEntry(key, value));
    if (setThrows) {
      throw StateError('写入配置失败（注入）');
    }
    rustValue = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('本桩未实现：${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('replaceEnableDefault 解析口径（对齐 Rust get_replace_enable_default）', () {
    test('缺省/空/非法 → true', () {
      for (final raw in <String?>[null, '', '   ', 'true', 'TRUE', '1', '2', 'yes']) {
        expect(
          parseReplaceEnableDefaultConfig(raw),
          isTrue,
          reason: 'raw=$raw 应回落 true',
        );
      }
    });

    test('"false"/"0"（忽略大小写与首尾空白）→ false', () {
      for (final raw in <String>['false', 'FALSE', '  False  ', '0', ' 0 ']) {
        expect(
          parseReplaceEnableDefaultConfig(raw),
          isFalse,
          reason: 'raw=$raw 应解析为 false',
        );
      }
    });
  });

  group('开关切换（saveReplaceEnableDefault）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('切到 false：prefs 与 config 同时写 false', () async {
      final api = _RecordingApi();

      await saveReplaceEnableDefault(api, false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.replaceEnableDefault), isFalse);
      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.key, PrefKeys.replaceEnableDefault);
      expect(api.setCalls.single.value, 'false');
    });

    test('切到 true：prefs 与 config 同时写 true', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final api = _RecordingApi(rustValue: 'false');

      await saveReplaceEnableDefault(api, true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.replaceEnableDefault), isTrue);
      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.key, PrefKeys.replaceEnableDefault);
      expect(api.setCalls.single.value, 'true');
    });
  });

  group('启动同步（syncReplaceEnableDefaultOnStartup）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('存量 prefs=false 且 Rust 缺省 → 补写 "false"', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final api = _RecordingApi(rustValue: null);

      await syncReplaceEnableDefaultOnStartup(api, useMock: false);

      expect(api.getCalls, [PrefKeys.replaceEnableDefault]);
      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.value, 'false');
    });

    test('prefs=false 且 Rust "true" → 覆盖为 "false"', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final api = _RecordingApi(rustValue: 'true');

      await syncReplaceEnableDefaultOnStartup(api, useMock: false);

      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.value, 'false');
    });

    test('默认 true 且 Rust 缺省 → 不写库且不抛错', () async {
      final api = _RecordingApi(rustValue: null);

      await expectLater(
        syncReplaceEnableDefaultOnStartup(api, useMock: false),
        completes,
        reason: '默认值缺省时启动同步不得产生错误',
      );
      expect(api.setCalls, isEmpty, reason: '有效值同为 true，不应产生无谓 DB 写');
    });

    test('prefs=true（未设置默认）且 Rust "false" → 修正为 "true"', () async {
      final api = _RecordingApi(rustValue: 'false');

      await syncReplaceEnableDefaultOnStartup(api, useMock: false);

      expect(api.setCalls, hasLength(1));
      expect(api.setCalls.single.value, 'true');
    });

    test('USE_MOCK → 不读不写（Mock 无 DB）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final api = _RecordingApi(rustValue: null);

      await syncReplaceEnableDefaultOnStartup(api, useMock: true);

      expect(api.getCalls, isEmpty);
      expect(api.setCalls, isEmpty);
    });

    test('读取配置失败 → 静默不崩（Future 正常完成）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final api = _RecordingApi(getThrows: true);

      await expectLater(
        syncReplaceEnableDefaultOnStartup(api, useMock: false),
        completes,
        reason: '启动同步失败不得阻断启动',
      );
      expect(api.setCalls, isEmpty);
    });

    test('写入配置失败 → 静默不崩（Future 正常完成）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.replaceEnableDefault: false,
      });
      final api = _RecordingApi(setThrows: true);

      await expectLater(
        syncReplaceEnableDefaultOnStartup(api, useMock: false),
        completes,
        reason: 'FFI/DB 失败不得阻断启动',
      );
      expect(api.setCalls, hasLength(1));
    });
  });
}
