// 批11：远端备份列表 Sheet 纯函数/格式测试
//
// `formatRemoteBackupTime` 单独导出供列表项与单测共用；此处钉住固定格式，
// 避免 widget 测试里重复拼接字符串或断言过宽。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/remote_backup_list_sheet.dart';

void main() {
  test('formatRemoteBackupTime 输出 yyyy-MM-dd HH:mm（本地时区）', () {
    final millis = DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch;

    expect(formatRemoteBackupTime(millis), '2026-01-02 03:04');
  });

  test('formatRemoteBackupTime 补零（个位月/日/时/分）', () {
    final millis = DateTime(2026, 9, 8, 7, 6).millisecondsSinceEpoch;

    expect(formatRemoteBackupTime(millis), '2026-09-08 07:06');
  });
}
