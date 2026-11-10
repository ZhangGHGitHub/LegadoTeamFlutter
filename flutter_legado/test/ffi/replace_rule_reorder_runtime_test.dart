/// 批12：替换规则排序与 scope 写链路真实 DLL 运行时验证（契约 §2.8）
///
/// 加载 `rust/target/debug/legado_ffi.dll`（解析策略对齐
/// `test/ffi/highlight_rule_match_runtime_test.dart`），经真实 FRB wire 验证：
/// - `reorderReplaceRules` 全量乱序重排后 `getReplaceRules` 顺序 = 传入顺序、
///   `sortOrder` 重编号 0..n-1；
/// - 重复/未知/缺失 id 一律抛错且零写入（逐条对比 id:order 快照）；
/// - `updateReplaceRule` 的 scope 扩参：Some(非空)=覆盖、Some("")=清除、
///   未提供=保留既有值。
///
/// 前置条件：先在 rust/ 下构建 DLL
/// （cargo build -p legado-ffi --features quickjs）。
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
import 'package:flutter_legado/src/bridge/ffi/ffi.dart' as bridge;
import 'package:flutter_legado/src/bridge/frb_generated.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 从 rust/target/debug 解析真实 DLL 路径（对齐 rust_api.dart 的搜索策略）
String _resolveDll() {
  const libName = 'legado_ffi.dll';
  final sep = Platform.pathSeparator;
  final candidates = <String>[
    '${Directory.current.parent.path}${sep}rust${sep}target${sep}debug$sep$libName',
    '${Directory.current.path}$sep..${sep}rust${sep}target${sep}debug$sep$libName',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('未找到 legado_ffi.dll，请先在 rust/ 下构建');
}

void main() {
  // 该测试依赖 Windows 构建的 DLL 产物（rust/target/debug），
  // CI（ubuntu/macOS）无产物：注册阶段整体跳过（仅留占位用例可见）
  if (!Platform.isWindows) {
    test('跳过 FFI 运行时替换规则排序测试：需要 Windows DLL 产物（仅本机验证）', () {});
    return;
  }

  late RustApi api;

  /// id:order 快照（零写入断言用）
  Future<List<String>> snapshot() async =>
      (await api.getReplaceRules()).map((r) => '${r.id}:${r.order}').toList();

  /// 按 id 重读规则（scope 写读断言用）
  Future<ReplaceRule> findById(int id) async =>
      (await api.getReplaceRules()).firstWhere((r) => r.id == id);

  setUpAll(() async {
    final lib = ExternalLibrary.open(_resolveDll());
    await RustLib.init(externalLibrary: lib);
    await bridge.init();
    final sep = Platform.pathSeparator;
    final dbDir = Directory('.dart_tool${sep}ffi_replace_rule_reorder_test');
    dbDir.createSync(recursive: true);
    final dbFile = File('${dbDir.path}${sep}replace_rule_reorder.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    await bridge.dbOpen(path: dbFile.path);
    api = RustApi();
  });

  group('替换规则排序真实 DLL 运行时验证（批12）', () {
    test('全量乱序重排：顺序与 sortOrder 0..n-1 落库', () async {
      await api.addReplaceRule(
        const ReplaceRule(name: 'rt_reorder_a', pattern: 'a'),
      );
      await api.addReplaceRule(
        const ReplaceRule(name: 'rt_reorder_b', pattern: 'b'),
      );
      await api.addReplaceRule(
        const ReplaceRule(name: 'rt_reorder_c', pattern: 'c'),
      );

      final ids = (await api.getReplaceRules()).map((r) => r.id).toList();
      expect(ids.length, greaterThanOrEqualTo(3));
      final target = ids.reversed.toList();

      expect(await api.reorderReplaceRules(target), target.length);

      final rules = await api.getReplaceRules();
      expect(rules.map((r) => r.id).toList(), target);
      expect(
        rules.map((r) => r.order).toList(),
        List.generate(target.length, (i) => i),
      );

      // 连续两次相同重排幂等
      expect(await api.reorderReplaceRules(target), target.length);
      expect((await api.getReplaceRules()).map((r) => r.id).toList(), target);
    });

    test('重复/未知/缺失 id：抛错且零写入', () async {
      final before = await snapshot();
      final ids = (await api.getReplaceRules()).map((r) => r.id).toList();
      expect(ids.length, greaterThanOrEqualTo(2));

      await expectLater(
        api.reorderReplaceRules([ids.first, ids.first]),
        throwsA(
          predicate((e) => e is BridgeError && e.message.contains('重复 id')),
        ),
      );
      await expectLater(
        api.reorderReplaceRules([...ids, 999999]),
        throwsA(
          predicate((e) => e is BridgeError && e.message.contains('未知 id')),
        ),
      );
      await expectLater(
        api.reorderReplaceRules(ids.sublist(0, ids.length - 1)),
        throwsA(
          predicate((e) => e is BridgeError && e.message.contains('缺失 id')),
        ),
      );

      expect(await snapshot(), before, reason: '非法集必须零写入');
      expect(await api.reorderReplaceRules(const []), 0, reason: '空数组返回 0');
      expect(await snapshot(), before);
    });

    test('update 扩参 scope：覆盖 / 清除 / 未提供保留', () async {
      final added = await api.addReplaceRule(
        const ReplaceRule(name: 'rt_scope_rule', pattern: 'x', scope: '旧范围'),
      );
      expect((await findById(added.id)).scope, '旧范围');

      // Some(非空) → 覆盖
      await api.updateReplaceRule(
        (await findById(added.id)).copyWith(scope: '新范围'),
      );
      expect((await findById(added.id)).scope, '新范围');

      // 未提供 scope → 保留既有值。BookApi 恒传空串表达「清除」，故必须
      // 直调生成的桥接函数并**省略**可选参，才能覆盖 Rust `Option::None` 分支
      final current = await findById(added.id);
      await bridge.replaceRuleUpdate(
        ruleId: current.id,
        name: current.name,
        pattern: 'y',
        replacement: current.replacement,
        isRegex: current.isRegex,
        isEnabled: current.isEnabled,
        group: current.group ?? '',
        scopeTitle: current.scopeTitle,
        scopeContent: current.scopeContent,
        excludeScope: current.excludeScope ?? '',
        timeoutMillisecond: current.timeoutMillisecond,
        scopeSource: current.scopeSource,
        // scope 省略：FFI 侧 None → 保留既有值
      );
      expect((await findById(added.id)).scope, '新范围');

      // Some("")：BookApi 以 null 表达清除（RustApi 透传空串）
      await api.updateReplaceRule(
        (await findById(added.id)).copyWith(scope: null),
      );
      expect((await findById(added.id)).scope, isNull);
    });
  });
}
