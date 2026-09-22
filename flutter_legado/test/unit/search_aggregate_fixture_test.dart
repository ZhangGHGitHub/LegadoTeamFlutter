// 跨端夹具校验（队列⑩a P1-1 项2，2026-09-22）
//
// 与 Rust 侧集成测试 `rust/legado-ffi/tests/search_aggregate_fixture.rs` 读
// 同一夹具 `rust/legado-ffi/tests/fixtures/search_aggregate/cross_source_merge.json`：
// Dart 端用现行 `applyPrecisionSearch` + `SearchResult`（fromSearchBook 消费
// 加法式 `SearchBook.origins` 字段）跑同一 books 输入，逐条比对夹具 expected。
// 比对约定（两端一致）：
// - name/author/origin/originName/bookUrl/kind/hasReadRecord 按索引顺序敏感；
// - origins 按序比对（首次出现序为契约：Dart Set<String> 为 LinkedHashSet
//   保序输出，Rust 实现同保序去重）；
// - 不依赖真网络。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/search/search_state.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath =
    '../rust/legado-ffi/tests/fixtures/search_aggregate/cross_source_merge.json';

void main() {
  test('cross_source_merge 夹具：Dart applyPrecisionSearch ≡ Rust 聚合期望', () {
    final raw = File(_fixturePath).readAsStringSync();
    final fixture = jsonDecode(raw) as Map<String, dynamic>;

    for (final caseMap in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final caseId = caseMap['id'] as String;
      final key = caseMap['key'] as String;
      final keepOther = caseMap['keep_other'] as bool;
      final books = (caseMap['books'] as List).cast<Map<String, dynamic>>();
      final expected =
          (caseMap['expected'] as List).cast<Map<String, dynamic>>();

      // 与 Rust 聚合入口同一输入形态：books[] 逐条 fromJson + fromSearchBook
      // （hasReadRecord 从批次 JSON 透传，对齐 Rust CoreSearchBook.hasReadRecord）
      final results = [
        for (final e in books)
          SearchResult.fromSearchBook(
            SearchBook.fromJson(e),
            hasReadRecord: e['hasReadRecord'] == true,
          ),
      ];

      final out = applyPrecisionSearch(results, key, keepOther: keepOther);

      expect(out.length, expected.length, reason: '[$caseId] 输出条数');
      for (var i = 0; i < expected.length; i++) {
        final a = out[i];
        final e = expected[i];
        expect(a.book.name, e['name'], reason: '[$caseId] 第 $i 条 name（清洗值）');
        expect(a.book.author, e['author'],
            reason: '[$caseId] 第 $i 条 author（清洗值）');
        expect(a.book.origin, e['origin'],
            reason: '[$caseId] 第 $i 条 origin（首条到达元数据）');
        expect(a.sourceName, e['originName'],
            reason: '[$caseId] 第 $i 条 originName');
        expect(a.book.bookUrl, e['bookUrl'],
            reason: '[$caseId] 第 $i 条 bookUrl（首条到达元数据）');
        expect(
          a.book.kind,
          e['kind'] is String ? e['kind'] as String : null,
          reason: '[$caseId] 第 $i 条 kind（缺失/null 视同 null）',
        );
        expect(
          a.hasReadRecord,
          e['hasReadRecord'] == true,
          reason: '[$caseId] 第 $i 条 hasReadRecord（跨源 OR）',
        );
        final aOrigins = a.origins.toList();
        final eOrigins = (e['origins'] as List).cast<String>().toList();
        expect(
          aOrigins,
          eOrigins,
          reason: '[$caseId] 第 $i 条 origins（按序比对，首次出现序为契约，跨源累加）',
        );
      }
    }
  });

  test('加法式 origins 字段消费：非空优先 / 空回退 {origin} / 缺失回退', () {
    // 预填 origins（聚合入口产出形态）→ 优先于 origin 消费（对齐 Rust
    // effective_origins 规则）
    final withField = SearchResult.fromSearchBook(
      SearchBook.fromJson({
        'name': '重生',
        'author': '甲',
        'origin': 'https://s1.example',
        'origins': ['https://sA.example', 'https://sB.example'],
      }),
    );
    expect(
      withField.effectiveOrigins,
      {'https://sA.example', 'https://sB.example'},
      reason: '预填 origins 字段非空时优先（不含 origin）',
    );

    // 无 origins 字段（旧批次 JSON 形态）→ 回退 {origin}
    final legacy = SearchResult.fromSearchBook(
      SearchBook.fromJson({'name': 'x', 'origin': 'https://s2.example'}),
    );
    expect(legacy.effectiveOrigins, {'https://s2.example'});

    // origin 与 origins 均空 → 空集合（originsCount 下限 1）
    final bare = SearchResult.fromSearchBook(SearchBook.fromJson({'name': 'y'}));
    expect(bare.effectiveOrigins, const <String>{});
    expect(bare.originsCount, 1, reason: '空 origins 计数下限 1');
  });
}
