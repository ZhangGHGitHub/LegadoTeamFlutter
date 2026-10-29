// 发现书单「加载上一页」滚动补偿计算单元测试（批36b）
//
// 列表形态沿用单行 76dp 估值；网格必须按「新增行数 ×（行高 + 行距）」
// 补偿，否则会在网格形态下跳到半行/错误位置。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/explore_book_list.dart';

void main() {
  group('explorePreviousPageShift', () {
    test('无新增时补偿为 0', () {
      expect(explorePreviousPageShift(addedCount: 0), 0);
      expect(explorePreviousPageShift(addedCount: -3), 0);
    });

    test('列表形态：新增条数 × 76', () {
      expect(explorePreviousPageShift(addedCount: 5), 5 * 76.0);
      // 未提供网格参数（列表模式）
      expect(
        explorePreviousPageShift(addedCount: 5, gridCount: null),
        5 * 76.0,
      );
    });

    test('网格形态：按行数与行高补偿（整行）', () {
      // 3 列 30 条 = 10 行；行高 200 + 行距 12
      expect(
        explorePreviousPageShift(
          addedCount: 30,
          gridCount: 3,
          gridRowExtent: 200,
        ),
        10 * 212.0,
      );
    });

    test('网格形态：不足一行按一行补偿', () {
      // 3 列 4 条 = 2 行
      expect(
        explorePreviousPageShift(
          addedCount: 4,
          gridCount: 3,
          gridRowExtent: 200,
        ),
        2 * 212.0,
      );
    });

    test('网格行高未知（首帧前）回退列表估值', () {
      expect(
        explorePreviousPageShift(addedCount: 5, gridCount: 3),
        5 * 76.0,
      );
    });
  });
}
