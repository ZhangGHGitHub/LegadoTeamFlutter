/// 阅读记录「按天」视图分组纯函数测试（差异清单 C5）
///
/// 验证：今天/昨天/更早分组、组内日期倒序、零秒条目剔除、非法日期跳过。
/// — Qoder UI ｜ 2026-09-11
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/read_record_daily_view.dart';

void main() {
  group('groupDailyByDay 按天分组', () {
    final now = DateTime(2026, 9, 11, 10, 30);

    test('今天/昨天/更早分组且组内倒序', () {
      final data = [
        {'date': '2026-09-11', 'seconds': 600},
        {'date': '2026-09-10', 'seconds': 300},
        {'date': '2026-09-09', 'seconds': 900},
        {'date': '2026-09-01', 'seconds': 120},
      ];
      final groups = groupDailyByDay(data, now);
      expect(groups.map((g) => g.label).toList(), ['今天', '昨天', '更早']);
      expect(groups[0].entries.single.seconds, 600);
      expect(groups[1].entries.single.seconds, 300);
      // 更早组内倒序：09-09 在 09-01 前
      expect(groups[2].entries.first.date, DateTime(2026, 9, 9));
      expect(groups[2].entries.last.date, DateTime(2026, 9, 1));
    });

    test('零秒条目与非法日期剔除；全空返回空分组', () {
      final data = [
        {'date': '2026-09-11', 'seconds': 0},
        {'date': 'bad-date', 'seconds': 500},
        {'date': '', 'seconds': 500},
      ];
      expect(groupDailyByDay(data, now), isEmpty);
    });

    test('缺失 seconds 字段按 0 处理', () {
      final data = [
        {'date': '2026-09-11'},
      ];
      expect(groupDailyByDay(data, now), isEmpty);
    });
  });
}
