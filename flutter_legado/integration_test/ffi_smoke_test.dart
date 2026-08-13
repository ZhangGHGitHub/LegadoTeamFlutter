// Flutter鈫擱ust 绔埌绔?FFI 闆嗘垚鍐掔儫娴嬭瘯
//
// 瑕嗙洊鐐癸細
//   1. RustApi.initialize() 鈥?楠岃瘉 Rust 杩愯鏃跺垵濮嬪寲 + 鏁版嵁搴撴墦寮€
//   2. getVersion() 鈥?楠岃瘉 FFI 寰€杩旇皟鐢ㄨ繑鍥炴湁鏁堢増鏈彿
//   3. getBookSources() 鈥?楠岃瘉鐪熷疄 DB 鏌ヨ寰€杩旓紙涓嶄緷璧栧缃戯級
//
// 闄愬埗锛?
//   - 涓嶈鐩栫湡瀹炰功婧愯仈缃戞悳绱?涓嬭浇
//   - 涓嶈鐩?JS 寮曟搸鎵ц锛堥渶 quickjs feature 浣嗘澶勪粎楠岃瘉 DB 璺緞锛?
//   - 闇€瑕侀鏋勫缓鐨?legado_ffi 鍔ㄦ€佸簱锛圖LL/SO/DYLIB锛?
//
// 杩愯鏂瑰紡锛?
//   flutter test integration_test -d windows
//   锛堥渶瑕佸厛 cargo build -p legado-ffi --features quickjs锛?
//
// 娉ㄦ剰锛氭鏂囦欢浣嶄簬 integration_test/ 鐩綍锛屼笉浼氳 `flutter test` 鑷姩鎷惧彇锛?
// 鍥犳涓嶅奖鍝?test/ 鐩綍涓嬬殑鍗曞厓娴嬭瘯鍩虹嚎銆?

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Flutter鈫擱ust FFI 闆嗘垚鍐掔儫', () {
    late RustApi api;

    setUpAll(() async {
      api = RustApi();
    });

    testWidgets('initialize() 涓嶆姏寮傚父', (tester) async {
      // 楠岃瘉 Rust 杩愯鏃跺垵濮嬪寲 + tokio runtime 鍒涘缓 + DB 鎵撳紑
      await api.initialize();
      // 鏃犲紓甯稿嵆閫氳繃
    });

    testWidgets('getVersion() 杩斿洖鏈夋晥鐗堟湰鍙?, (tester) async {
      await api.initialize();
      final version = await api.getVersion();
      // 鐗堟湰鍙峰簲涓洪潪绌哄瓧绗︿覆锛屾牸寮忕被浼?"0.1.0"
      expect(version, isNotEmpty);
      expect(version, contains('.'));
    });

    testWidgets('getBookSources() FFI 寰€杩旀甯?, (tester) async {
      await api.initialize();
      // sourceList() 鏄函 DB 鏌ヨ锛屼笉渚濊禆澶栫綉
      // 绌烘暟鎹簱杩斿洖绌哄垪琛ㄤ篃鏄悎娉曠殑
      final sources = await api.getBookSources();
      expect(sources, isA<List>());
      // 涓嶆姏寮傚父 + 杩斿洖缁撴瀯鍚堢悊鍗抽€氳繃
    });
  });
}
