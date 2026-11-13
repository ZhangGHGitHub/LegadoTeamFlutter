import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/screens/auto_task_screen.dart';

/// [P2-8] 自动任务批量导入写入失败可见性回归测试
///
/// 背景：旧实现 `try { await createTaskRaw(...); count++; } catch (_) {}`
/// 既忽略 `createTaskRaw` 的 false 返回值（DB 写入失败不抛异常），又只把
/// 「解析阶段无效任务」计入提示——写入失败完全静默。
///
/// 本用例直接覆盖抽出的写入循环：成功/失败分列、失败带任务名与可读原因。
void main() {
  group('writeImportedAutoTasks（P2-8）', () {
    test('部分写入失败：成功数 + 失败明细（含任务名与原因）', () async {
      var lastError = '创建任务失败: 主键冲突';
      final result = await writeImportedAutoTasks(
        tasks: const [
          {'name': '任务A', 'cron': '0 8 * * *', 'script': 'a()'},
          {'name': '任务B', 'cron': '0 9 * * *', 'script': 'b()'},
          {'name': '任务C', 'cron': '0 10 * * *', 'script': 'c()'},
        ],
        create: (ruleJson) async {
          if (ruleJson.contains('任务B')) return false;
          if (ruleJson.contains('任务C')) {
            throw const BridgeError(message: '字段超限');
          }
          return true;
        },
        lastError: () => lastError,
      );

      expect(result.count, 1);
      expect(result.failures, hasLength(2));
      expect(result.failures[0], contains('任务B'));
      expect(result.failures[0], contains('主键冲突'));
      expect(result.failures[1], contains('任务C'));
      expect(result.failures[1], contains('字段超限'));
      expect(result.failures.join('\n'), isNot(contains('Instance of')));
    });

    test('createTaskRaw 返回 false 且无 error 时给出兜底原因', () async {
      final result = await writeImportedAutoTasks(
        tasks: const [
          {'name': '任务A', 'cron': '0 8 * * *', 'script': 'a()'},
        ],
        create: (_) async => false,
        lastError: () => null,
      );

      expect(result.count, 0);
      expect(result.failures.single, '任务A：写入失败');
    });
  });

  group('importTasksResultMessage（P2-8）', () {
    test('全部成功', () {
      expect(
        importTasksResultMessage(
          count: 4,
          parseErrors: 0,
          writeFailures: const [],
        ),
        '已导入 4 个任务',
      );
    });

    test('解析阶段无效任务保持原有文案', () {
      expect(
        importTasksResultMessage(
          count: 4,
          parseErrors: 2,
          writeFailures: const [],
        ),
        '已导入 4 个任务，跳过 2 个无效任务',
      );
    });

    test('写入失败单独计数并展开首条原因', () {
      expect(
        importTasksResultMessage(
          count: 2,
          parseErrors: 1,
          writeFailures: const ['任务B：主键冲突', '任务C：字段超限'],
        ),
        '已导入 2 个任务，跳过 1 个无效任务，2 个写入失败：任务B：主键冲突（另有 1 个）',
      );
    });

    test('全部写入失败不再伪装成成功', () {
      expect(
        importTasksResultMessage(
          count: 0,
          parseErrors: 0,
          writeFailures: const ['任务A：主键冲突'],
        ),
        '未导入任何任务，1 个写入失败：任务A：主键冲突',
      );
    });
  });
}
