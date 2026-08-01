import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/providers/auto_task/auto_task_notifier.dart';

void main() {
  group('AutoTask model', () {
    test('fromJson 解析服务端 AutoTaskRule 格式', () {
      // 服务端字段：enable / comment / lastRunAt(毫秒时间戳)
      final json = {
        'id': 'task-1',
        'name': '每日刷新目录',
        'enable': true,
        'cron': '0 8 * * *',
        'comment': 'refreshToc',
        'lastRunAt': 1735689600000, // 2025-01-01 08:00:00 (UTC+8 取决于时区)
        'lastResult': '成功',
      };

      final task = AutoTask.fromJson(json);

      expect(task.id, equals('task-1'));
      expect(task.name, equals('每日刷新目录'));
      expect(task.isEnabled, isTrue);
      expect(task.cron, equals('0 8 * * *'));
      expect(task.taskType, equals('refreshToc'));
      expect(task.lastResult, equals('成功'));
      // lastRunAt 毫秒时间戳应被格式化为字符串
      expect(task.lastRunAt, isNotNull);
      expect(task.lastRunAt, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')));
    });

    test('fromJson 兼容 Dart 风格字段', () {
      final json = {
        'id': '2',
        'name': '每周备份',
        'isEnabled': false,
        'taskType': 'backup',
        'cron': '0 2 * * 0',
        'lastRunAt': '2024-12-29 02:00:00',
      };

      final task = AutoTask.fromJson(json);

      expect(task.isEnabled, isFalse);
      expect(task.taskType, equals('backup'));
      expect(task.lastRunAt, equals('2024-12-29 02:00:00'));
    });

    test('fromJson lastRunAt 为 0 时返回 null', () {
      final task = AutoTask.fromJson({
        'id': '3',
        'name': 'x',
        'lastRunAt': 0,
      });
      expect(task.lastRunAt, isNull);
    });

    test('fromJson 缺失字段使用默认值', () {
      final task = AutoTask.fromJson({});
      expect(task.id, equals(''));
      expect(task.name, equals(''));
      expect(task.taskType, equals(''));
      expect(task.cron, equals(''));
      expect(task.isEnabled, isTrue);
      expect(task.lastRunAt, isNull);
      expect(task.lastResult, isNull);
    });

    test('toJson 输出服务端兼容格式', () {
      const task = AutoTask(
        id: 'task-9',
        name: '更新书源',
        taskType: 'updateSources',
        cron: '0 3 1 * *',
        isEnabled: false,
      );

      final json = task.toJson();

      expect(json['id'], equals('task-9'));
      expect(json['name'], equals('更新书源'));
      expect(json['enable'], isFalse);
      expect(json['cron'], equals('0 3 1 * *'));
      expect(json['comment'], equals('updateSources'));
      // run 端点要求 script 非空
      expect((json['script'] as String).isNotEmpty, isTrue);
    });

    test('toJson 与 fromJson 往返保持一致', () {
      const task = AutoTask(
        id: 'rt',
        name: '往返测试',
        taskType: 'backup',
        cron: '*/30 * * * *',
        isEnabled: true,
      );

      final restored = AutoTask.fromJson(task.toJson());

      expect(restored.id, equals(task.id));
      expect(restored.name, equals(task.name));
      expect(restored.taskType, equals(task.taskType));
      expect(restored.cron, equals(task.cron));
      expect(restored.isEnabled, equals(task.isEnabled));
    });

    test('taskTypeLabel 返回中文名称', () {
      const task = AutoTask(
        id: '1',
        name: 'x',
        taskType: 'refreshToc',
        cron: '',
      );
      expect(task.taskTypeLabel, equals('刷新目录'));
    });
  });
}
