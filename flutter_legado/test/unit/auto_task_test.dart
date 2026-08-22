import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/providers/auto_task/auto_task_notifier.dart';

/// 书籍更新任务真实 script 样例（对齐 Rust build_book_update_task）
const _bookUpdateScript =
    '({"type":"refreshToc","bookUrl":"http://book/1","bookName":"测试书",'
    '"bookAuthor":"作者A","generatedBy":"bookUpdate","respectCanUpdate":true,'
    '"notify":{"enable":true,"minCount":1},"cache":{"enable":false}})';

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

    group('script 保真 round-trip', () {
      test('refreshToc 无 script 时 toJson 生成占位脚本', () {
        const task = AutoTask(
          id: '1',
          name: '刷新',
          taskType: 'refreshToc',
          cron: '0 8 * * *',
        );
        final json = task.toJson();
        expect(json['script'], equals('refreshToc()'));
        // toJson 输出占位脚本后，fromJson 视其为已保存 script（_parseScript 非空即保留）
        expect(AutoTask.fromJson(json).script, equals('refreshToc()'));
        expect(AutoTask.fromJson(json).effectiveScript, equals('refreshToc()'));
      });

      test('updateSources 无 script 时 toJson 生成占位脚本', () {
        const task = AutoTask(
          id: '2',
          name: '更新源',
          taskType: 'updateSources',
          cron: '0 3 1 * *',
        );
        expect(task.toJson()['script'], equals('updateSources()'));
      });

      test('backup 无 script 时 toJson 生成占位脚本', () {
        const task = AutoTask(
          id: '3',
          name: '备份',
          taskType: 'backup',
          cron: '0 2 * * 0',
        );
        expect(task.toJson()['script'], equals('backup()'));
      });

      test('书籍更新任务保留复杂 JSON action', () {
        final json = {
          'id': 'book_update:abc123',
          'name': '更新测试书',
          'enable': true,
          'cron': '0 */6 * * *',
          'comment': 'refreshToc',
          'script': _bookUpdateScript,
        };
        final task = AutoTask.fromJson(json);
        expect(task.script, equals(_bookUpdateScript));

        final exported = task.toJson();
        expect(exported['script'], equals(_bookUpdateScript));

        final roundTrip = AutoTask.fromJson(exported);
        expect(roundTrip.script, equals(_bookUpdateScript));
      });

      test('fromJson→toJson 四类任务 script 全程保留', () {
        final cases = <Map<String, dynamic>>[
          {
            'id': 't-refresh',
            'name': '刷新目录',
            'comment': 'refreshToc',
            'cron': '0 8 * * *',
            'script': 'refreshToc({"bookUrl":"http://a.com"})',
          },
          {
            'id': 't-sources',
            'name': '更新书源',
            'comment': 'updateSources',
            'cron': '0 3 1 * *',
            'script': 'updateSources()',
          },
          {
            'id': 't-backup',
            'name': '自动备份',
            'comment': 'backup',
            'cron': '0 2 * * 0',
            'script': 'backup()',
          },
          {
            'id': 'book_update:xyz',
            'name': '书籍更新',
            'comment': 'refreshToc',
            'cron': '0 */6 * * *',
            'script': _bookUpdateScript,
          },
        ];

        for (final original in cases) {
          final task = AutoTask.fromJson(original);
          final exported = task.toJson();
          expect(
            exported['script'],
            equals(original['script']),
            reason: '任务 ${original['id']} script 应在 toJson 中保留',
          );
          final restored = AutoTask.fromJson(exported);
          expect(restored.script, equals(original['script']));
        }
      });
    });

    group('旧 JSON 兼容', () {
      test('无 script 字段不报错且 toJson 按 taskType 兜底', () {
        final json = {
          'id': 'old-1',
          'name': '旧任务',
          'comment': 'refreshToc',
          'cron': '0 0 * * *',
          'enable': true,
        };
        final task = AutoTask.fromJson(json);
        expect(task.script, isNull);
        expect(task.toJson()['script'], equals('refreshToc()'));
      });

      test('空 script 字符串视为未设置', () {
        final task = AutoTask.fromJson({
          'id': 'old-2',
          'name': 'x',
          'taskType': 'backup',
          'cron': '',
          'script': '',
        });
        expect(task.script, isNull);
        expect(task.toJson()['script'], equals('backup()'));
      });
    });

    group('导入/导出保真', () {
      test('导入 JSON 经 fromJson→toJson 不丢失 script', () {
        final imported = [
          {
            'id': 'imp-1',
            'name': '导入书籍更新',
            'enable': true,
            'cron': '0 */6 * * *',
            'comment': 'refreshToc',
            'script': _bookUpdateScript,
          },
          {
            'id': 'imp-2',
            'name': '导入备份',
            'enable': true,
            'cron': '0 2 * * 0',
            'comment': 'backup',
            'script': 'backup()',
          },
        ];

        final tasks = imported.map(AutoTask.fromJson).toList();
        final exported = jsonEncode(tasks.map((t) => t.toJson()).toList());
        final decoded = (jsonDecode(exported) as List).cast<Map<String, dynamic>>();

        expect(decoded[0]['script'], equals(_bookUpdateScript));
        expect(decoded[1]['script'], equals('backup()'));
      });
    });

    group('copyWith 保留 script', () {
      test('修改展示字段不丢失 script', () {
        final task = AutoTask.fromJson({
          'id': 'cp-1',
          'name': '原名',
          'comment': 'refreshToc',
          'cron': '0 0 * * *',
          'script': _bookUpdateScript,
        });
        final updated = task.copyWith(name: '新名', cron: '0 1 * * *');
        expect(updated.script, equals(_bookUpdateScript));
        expect(updated.toJson()['script'], equals(_bookUpdateScript));
      });
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
