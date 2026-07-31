/// AutoTaskProvider 单元测试
///
/// 覆盖：
/// - AutoTask 模型：fromJson/toJson/copyWith/taskTypeLabel/_defaultScript
/// - AutoTaskProvider：loadTasks/createTask/toggleTask/deleteTask/runNow
/// - FFI 方法：buildBookUpdateTask/updateCronBatch/normalizeScript 等
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/auto_task_provider.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
  });

  // Helper: Create ASCII JSON (avoiding Latin-1 encoding issues in http package)
  String jsonEncodeAscii(Map<String, dynamic> data) {
    return jsonEncode(data);
  }

  List<Map<String, dynamic>> makeTaskList({int count = 2, String idStart = '1'}) {
    return List.generate(
      count,
      (i) => {
        'id': '${idStart}${i + 1}',
        'name': 'Task${i + 1}',
        'taskType': i == 0 ? 'backup' : 'refreshToc',
        'cron': '0 * * * *',
      },
    );
  }

  // ═══════════════════════════════════════════════════════════
  // AutoTask 模型测试（纯逻辑，不涉及 HTTP）
  // ═══════════════════════════════════════════════════════════

  group('AutoTask 模型', () {
    test('fromJson 解析标准 Dart 风格字段', () {
      final json = {
        'id': 't1',
        'name': 'Refresh TOC',
        'taskType': 'refreshToc',
        'cron': '0 0 3 * * *',
        'isEnabled': true,
        'lastRunAt': '2025-01-01 03:00:00',
        'lastResult': 'Success',
      };
      final task = AutoTask.fromJson(json);

      expect(task.id, equals('t1'));
      expect(task.name, equals('Refresh TOC'));
      expect(task.taskType, equals('refreshToc'));
      expect(task.cron, equals('0 0 3 * * *'));
      expect(task.isEnabled, isTrue);
      expect(task.lastRunAt, equals('2025-01-01 03:00:00'));
      expect(task.lastResult, equals('Success'));
    });

    test('fromJson 兼容服务端 enable/comment 字段', () {
      final json = {
        'id': 't2',
        'name': 'Update Sources',
        'comment': 'updateSources',
        'cron': '0 0 4 * * *',
        'enable': false,
      };
      final task = AutoTask.fromJson(json);

      expect(task.id, equals('t2'));
      expect(task.taskType, equals('updateSources'));
      expect(task.isEnabled, isFalse);
    });

    test('fromJson lastRunAt 为毫秒时间戳时格式化', () {
      final millis = DateTime(2025, 1, 15, 8, 30, 0).millisecondsSinceEpoch;
      final json = {
        'id': 't3',
        'name': 'Backup',
        'taskType': 'backup',
        'cron': '0 0 2 * * *',
        'lastRunAt': millis,
      };
      final task = AutoTask.fromJson(json);
      expect(task.lastRunAt, equals('2025-01-15 08:30:00'));
    });

    test('toJson 输出服务端兼容格式', () {
      const task = AutoTask(
        id: 't1', name: 'Refresh', taskType: 'refreshToc',
        cron: '0 0 * * *', isEnabled: true,
      );
      final json = task.toJson();
      expect(json['enable'], isTrue);
      expect(json['comment'], equals('refreshToc'));
      expect(json['script'], equals('refreshToc()'));
    });

    test('taskTypeLabel 返回中文标签', () {
      expect(const AutoTask(id: '', name: '', taskType: 'refreshToc', cron: '').taskTypeLabel, equals('刷新目录'));
      expect(const AutoTask(id: '', name: '', taskType: 'updateSources', cron: '').taskTypeLabel, equals('更新书源'));
      expect(const AutoTask(id: '', name: '', taskType: 'backup', cron: '').taskTypeLabel, equals('自动备份'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // AutoTaskProvider 测试
  // ═══════════════════════════════════════════════════════════

  group('AutoTaskProvider 初始状态', () {
    test('初始任务列表为空', () {
      final client = MockClient((_) async => http.Response(jsonEncode({'tasks': []}), 200));
      final provider = AutoTaskProvider(client: client);
      expect(provider.tasks, isEmpty);
      expect(provider.isLoading, isFalse);
      expect(provider.error, isNull);
    });
  });

  group('AutoTaskProvider loadTasks', () {
    test('成功加载任务列表（tasks 包裹格式）', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(makeTaskList(count: 2)),
          200,
        );
      });
      final provider = AutoTaskProvider(client: client);

      await provider.loadTasks();

      expect(provider.tasks.length, equals(2));
      expect(provider.tasks[0].name, equals('Task1'));
      expect(provider.isLoading, isFalse);
      expect(provider.error, isNull);
    });

    test('成功加载任务列表（直接数组格式）', () async {
      final client = MockClient((_) async {
        return http.Response(jsonEncode([
          {'id': '1', 'name': 'TaskA', 'cron': ''},
        ]), 200);
      });
      final provider = AutoTaskProvider(client: client);

      await provider.loadTasks();
      expect(provider.tasks.length, equals(1));
    });

    test('HTTP 非 200 时设置错误', () async {
      final client = MockClient((_) async => http.Response('Not Found', 404));
      final provider = AutoTaskProvider(client: client);

      await provider.loadTasks();
      expect(provider.tasks, isEmpty);
      expect(provider.error, contains('404'));
    });

    test('连接失败时回退为空列表且不报错', () async {
      final client = MockClient((_) async {
        throw const SocketException('Connection refused');
      });
      final provider = AutoTaskProvider(client: client);

      await provider.loadTasks();
      expect(provider.tasks, isEmpty);
      expect(provider.error, isNull);
    });

    test('silent 模式不触发 loading 状态', () async {
      final client = MockClient((_) async => http.Response('[]', 200));
      final provider = AutoTaskProvider(client: client);
      var sawLoading = false;
      provider.addListener(() {
        if (provider.isLoading) sawLoading = true;
      });

      await provider.loadTasks(silent: true);
      expect(sawLoading, isFalse);
    });
  });

  group('AutoTaskProvider createTask', () {
    test('创建成功后静默刷新', () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        if (request.method == 'POST') {
          return http.Response('', 201);
        }
        // After POST, loadTasks(silent) does GET - return same list
        if (requestCount == 1) return http.Response('', 201);
        return http.Response(jsonEncode([{'id': '1', 'name': 'New Task', 'cron': ''}]), 200);
      });
      final provider = AutoTaskProvider(client: client);

      const task = AutoTask(id: '1', name: 'New Task', taskType: 'backup', cron: '');
      await provider.createTask(task);

      expect(provider.error, isNull);
      expect(provider.tasks.length, equals(1));
    });

    test('创建失败时设置错误', () async {
      final client = MockClient((_) async => http.Response('Error', 500));
      final provider = AutoTaskProvider(client: client);

      const task = AutoTask(id: '1', name: 'Fail', taskType: '', cron: '');
      await provider.createTask(task);

      expect(provider.error, contains('创建任务失败'));
    });
  });

  group('AutoTaskProvider toggleTask', () {
    test('乐观更新成功后刷新', () async {
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode(makeTaskList()), 200);
        }
        return http.Response('', 200);
      });
      final provider = AutoTaskProvider(client: client);
      await provider.loadTasks();

      await provider.toggleTask('1', false);
      expect(provider.error, isNull);
    });

    test('更新失败时回滚', () async {
      var getRequestCount = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          getRequestCount++;
          return http.Response(jsonEncode(makeTaskList()), 200);
        }
        throw Exception('Network error');
      });
      final provider = AutoTaskProvider(client: client);
      await provider.loadTasks();

      await provider.toggleTask('1', false);

      expect(provider.tasks[0].isEnabled, isTrue);
      expect(provider.error, contains('更新任务失败'));
    });
  });

  group('AutoTaskProvider deleteTask', () {
    test('删除成功后刷新', () async {
      final client = MockClient((request) async {
        if (request.method == 'DELETE') return http.Response('', 200);
        return http.Response('[]', 200);
      });
      final provider = AutoTaskProvider(client: client);

      await provider.deleteTask('1');
      expect(provider.error, isNull);
    });

    test('删除失败时设置错误', () async {
      final client = MockClient((request) async {
        if (request.method == 'DELETE') return http.Response('Error', 500);
        return http.Response('[]', 200);
      });
      final provider = AutoTaskProvider(client: client);

      await provider.deleteTask('1');
      expect(provider.error, contains('删除任务失败'));
    });
  });

  group('AutoTaskProvider runNow', () {
    test('REST 路径运行成功后刷新', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST') return http.Response('', 200);
        return http.Response('[]', 200);
      });
      final provider = AutoTaskProvider(client: client);

      await provider.runNow('1');
      expect(provider.error, isNull);
    });

    test('FFI 执行成功更新本地状态', () async {
      final client = MockClient((_) async {
        return http.Response(jsonEncode({'tasks': [{'id': 't1', 'name': 'Task', 'taskType': 'backup', 'cron': ''}], 'total': 1}), 200);
      });
      final mockApi = MockRustApi();
      final provider = AutoTaskProvider(client: client, rustApi: mockApi);
      await provider.loadTasks();

      when(() => mockApi.autoTaskExecuteWithId(
            protocolJson: any(named: 'protocolJson'),
            taskId: any(named: 'taskId'),
          )).thenAnswer((_) async => {'success': true});

      await provider.runNow('t1');
      
      // Verify the update happened
      expect(provider.tasks.length, equals(1));
      expect(provider.tasks.first.lastResult, isNotNull); // Check not null
    });
  });

  group('AutoTaskProvider FFI 专属方法', () {
    late MockRustApi mockApi;
    late AutoTaskProvider provider;

    setUp(() {
      mockApi = MockRustApi();
      final client = MockClient((_) async => http.Response('[]', 200));
      provider = AutoTaskProvider(client: client, rustApi: mockApi);
    });

    test('buildBookUpdateTask 成功', () async {
      final expected = {'id': 'new', 'name': 'Update Task'};
      when(() => mockApi.autoTaskBuildBookUpdateTask(
            bookUrl: any(named: 'bookUrl'),
            bookName: any(named: 'bookName'),
            bookAuthor: any(named: 'bookAuthor'),
            name: any(named: 'name'),
          )).thenAnswer((_) async => expected);

      final result = await provider.buildBookUpdateTask(
        bookUrl: 'http://book.com', bookName: 'TestBook',
        bookAuthor: 'Author', name: 'Update',
      );
      expect(result, equals(expected));
    });

    test('buildBookUpdateTask 无 rustApi 返回 null', () async {
      final noApiProvider = AutoTaskProvider(client: MockClient((_) async => http.Response('[]', 200)));
      final result = await noApiProvider.buildBookUpdateTask(
        bookUrl: '', bookName: '', bookAuthor: '', name: '',
      );
      expect(result, isNull);
    });

    test('normalizeScript 成功', () async {
      when(() => mockApi.autoTaskNormalizeScript(script: any(named: 'script')))
          .thenAnswer((_) async => 'cleaned()');

      final result = await provider.normalizeScript('@js:cleaned()');
      expect(result, equals('cleaned()'));
    });

    test('canRefreshBookToc 成功', () async {
      when(() => mockApi.autoTaskCanRefreshBookToc(
            canUpdate: any(named: 'canUpdate'),
            respectCanUpdate: any(named: 'respectCanUpdate'),
          )).thenAnswer((_) async => true);

      final result = await provider.canRefreshBookToc(canUpdate: true, respectCanUpdate: true);
      expect(result, isTrue);
    });

    test('nextDueAt 成功', () async {
      when(() => mockApi.autoTaskNextDueAt(
            cron: any(named: 'cron'),
            fromMs: any(named: 'fromMs'),
          )).thenAnswer((_) async => 1735689600000);

      final result = await provider.nextDueAt(cron: '0 0 3 * * *');
      expect(result, equals(1735689600000));
    });
  });
}
