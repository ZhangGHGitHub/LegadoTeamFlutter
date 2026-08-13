// Flutter↔Rust end-to-end FFI smoke tests.
//
// Covers:
//   1. RustApi.initialize() — Rust runtime + DB open
//   2. getVersion() — FFI round-trip version string
//   3. getBookSources() — real DB query round-trip (no network)
//
// Limits:
//   - No live book-source search/download
//   - No JS engine execution (quickjs not required for DB path)
//   - Requires prebuilt legado_ffi (DLL/SO/DYLIB)
//
// Run:
//   flutter test integration_test/ffi_smoke_test.dart -d windows
//   (after: cargo build -p legado-ffi --features quickjs)
//
// Note: lives under integration_test/ so plain `flutter test` ignores it.
// CI Integration Smoke runs only this file (not e2e_search_read).

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Flutter-Rust FFI smoke', () {
    late RustApi api;

    setUpAll(() async {
      api = RustApi();
    });

    testWidgets('initialize() does not throw', (tester) async {
      await api.initialize();
    });

    testWidgets('getVersion() returns a dotted version', (tester) async {
      await api.initialize();
      final version = await api.getVersion();
      expect(version, isNotEmpty);
      expect(version, contains('.'));
    });

    testWidgets('getBookSources() FFI round-trip', (tester) async {
      await api.initialize();
      // Empty DB returning [] is valid.
      final sources = await api.getBookSources();
      expect(sources, isA<List>());
    });
  });
}
