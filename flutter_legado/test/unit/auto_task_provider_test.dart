/// AutoTaskNotifier 单元测试
///
/// 覆盖：
/// - AutoTask 模型：fromJson/toJson/copyWith/taskTypeLabel/_defaultScript
/// - AutoTaskNotifier：loadTasks/createTask/toggleTask/deleteTask/runNow（纯 FFI）
/// - FFI 方法：buildBookUpdateTask/updateCronBatch/normalizeScript 等
///
/// [体检 §二.7] REST 降级路径已删除（legado-server 未接线，指向 127.0.0.1:8080
/// 永远失败且错误被吞），Notifier 为纯 FFI + 失败可见；FFI 缺失（rustApi=null）
/// 分支断言错误可见。
library;
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/auto_task/auto_task_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
  });

  List<Map<String, dynamic>> makeTaskList({int count = 2, String idStart = '1'}) {
    return List.generate(
      count,
      (i) => {
        'id': '$idStart${i + 1}',
        'name': 'Task${i + 1}',
        'taskType': i == 0 ? 'backup' : 'refreshToc',
        'cron': '0 * * * *',
      },
    );
  }

  /// FFI 缺失分支容器（rustApi 覆盖为 null，对齐生产 FFI 初始化失败场景）
  ProviderContainer nullApiContainer() {
    final c = ProviderContainer(overrides: [
      autoTaskRustApiProvider.overrideWithValue(null),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// FFI 容器（MockRustApi 打桩）
  ProviderContainer ffiContainer(MockRustApi rustApi) {
    final c = ProviderContainer(overrides: [
      autoTaskRustApiProvider.overrideWithValue(rustApi),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  AutoTaskState readState(ProviderContainer c) =>
      c.read(autoTaskNotifierProvider);
  AutoTaskNotifier readNotifier(ProviderContainer c) =>
      c.read(autoTaskNotifierProvider.notifier);

  // ═══════════════════════════════════════════════════════════
  // AutoTask 模型测试（纯逻辑）
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

    test('toJson 保留已保存 script', () {
      const savedScript = '({"bookUrl":"http://a.com","generatedBy":"bookUpdate"})';
      final task = AutoTask.fromJson({
        'id': 't2',
        'name': 'Book Update',
        'comment': 'refreshToc',
        'cron': '0 */6 * * *',
        'script': savedScript,
      });
      expect(task.toJson()['script'], equals(savedScript));
    });

    test('taskTypeLabel 返回中文标签', () {
      expect(const AutoTask(id: '', name: '', taskType: 'refreshToc', cron: '').taskTypeLabel, equals('刷新目录'));
      expect(const AutoTask(id: '', name: '', taskType: 'updateSources', cron: '').taskTypeLabel, equals('更新书源'));
      expect(const AutoTask(id: '', name: '', taskType: 'backup', cron: '').taskTypeLabel, equals('自动备份'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // AutoTaskNotifier 测试（纯 FFI + 失败可见）
  // ═══════════════════════════════════════════════════════════

  group('AutoTaskNotifier 初始状态', () {
    test('初始任务列表为空', () {
      final c = ffiContainer(MockRustApi());
      expect(readState(c).tasks, isEmpty);
      expect(readState(c).isLoading, isFalse);
      expect(readState(c).error, isNull);
    });
  });

  group('AutoTaskNotifier loadTasks', () {
    test('FFI 成功加载任务列表', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskListRules())
          .thenAnswer((_) async => makeTaskList(count: 2));
      final c = ffiContainer(mockApi);

      await readNotifier(c).loadTasks();

      expect(readState(c).tasks.length, equals(2));
      expect(readState(c).tasks[0].name, equals('Task1'));
      expect(readState(c).isLoading, isFalse);
      expect(readState(c).error, isNull);
    });

    test('FFI 失败时错误可见', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskListRules())
          .thenThrow(Exception('FFI list failed'));
      final c = ffiContainer(mockApi);

      await readNotifier(c).loadTasks();
      expect(readState(c).tasks, isEmpty);
      expect(readState(c).error, contains('加载任务失败'));
    });

    test('FFI 缺失（rustApi=null）时错误可见', () async {
      final c = nullApiContainer();

      await readNotifier(c).loadTasks();
      expect(readState(c).tasks, isEmpty);
      expect(readState(c).error, contains('FFI 不可用'));
    });

    test('silent 模式不触发 loading 状态', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskListRules()).thenAnswer((_) async => []);
      final c = ffiContainer(mockApi);
      var sawLoading = false;
      c.listen(autoTaskNotifierProvider, (prev, next) {
        if (next.isLoading) sawLoading = true;
      });

      await readNotifier(c).loadTasks(silent: true);
      expect(sawLoading, isFalse);
    });
  });

  group('AutoTaskNotifier createTask', () {
    test('创建成功后静默刷新', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskCreateRule(ruleJson: any(named: 'ruleJson')))
          .thenAnswer((_) async => 'ok');
      when(() => mockApi.autoTaskListRules()).thenAnswer((_) async => [
            {
              'id': '1',
              'name': 'New Task',
              'comment': 'backup',
              'cron': '',
              'script': 'backup()',
            },
          ]);
      final c = ffiContainer(mockApi);

      const task = AutoTask(id: '1', name: 'New Task', taskType: 'backup', cron: '');
      await readNotifier(c).createTask(task);

      expect(readState(c).error, isNull);
      expect(readState(c).tasks.length, equals(1));
    });

    test('创建失败时设置错误', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskCreateRule(ruleJson: any(named: 'ruleJson')))
          .thenThrow(Exception('FFI create failed'));
      final c = ffiContainer(mockApi);

      const task = AutoTask(id: '1', name: 'Fail', taskType: '', cron: '');
      await readNotifier(c).createTask(task);

      expect(readState(c).error, contains('创建任务失败'));
    });
  });

  group('AutoTaskNotifier toggleTask', () {
    test('乐观更新成功后刷新', () async {
      final mockApi = MockRustApi();
      // idStart='' 使 id 为 '1'/'2'（FFI 路径按 id firstWhere 定位任务）
      when(() => mockApi.autoTaskListRules())
          .thenAnswer((_) async => makeTaskList(idStart: ''));
      when(() => mockApi.autoTaskUpdateRule(ruleJson: any(named: 'ruleJson')))
          .thenAnswer((_) async => {});
      final c = ffiContainer(mockApi);
      await readNotifier(c).loadTasks();

      await readNotifier(c).toggleTask('1', false);
      expect(readState(c).error, isNull);
    });

    test('更新失败时回滚', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskListRules())
          .thenAnswer((_) async => makeTaskList(idStart: ''));
      when(() => mockApi.autoTaskUpdateRule(ruleJson: any(named: 'ruleJson')))
          .thenThrow(Exception('FFI update failed'));
      final c = ffiContainer(mockApi);
      await readNotifier(c).loadTasks();

      await readNotifier(c).toggleTask('1', false);

      expect(readState(c).tasks[0].isEnabled, isTrue);
      expect(readState(c).error, contains('更新任务失败'));
    });
  });

  group('AutoTaskNotifier deleteTask', () {
    test('删除成功后刷新', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskDeleteRule(id: any(named: 'id')))
          .thenAnswer((_) async => {});
      when(() => mockApi.autoTaskListRules()).thenAnswer((_) async => []);
      final c = ffiContainer(mockApi);

      await readNotifier(c).deleteTask('1');
      expect(readState(c).error, isNull);
    });

    test('删除失败时设置错误', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskDeleteRule(id: any(named: 'id')))
          .thenThrow(Exception('FFI delete failed'));
      final c = ffiContainer(mockApi);

      await readNotifier(c).deleteTask('1');
      expect(readState(c).error, contains('删除任务失败'));
    });
  });

  group('AutoTaskNotifier runNow', () {
    test('FFI 执行成功更新本地状态', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskListRules()).thenAnswer((_) async => [
            {'id': 't1', 'name': 'Task', 'taskType': 'backup', 'cron': ''},
          ]);
      when(() => mockApi.autoTaskExecuteWithId(
            protocolJson: any(named: 'protocolJson'),
            taskId: any(named: 'taskId'),
          )).thenAnswer((_) async => {'success': true});
      final c = ffiContainer(mockApi);
      await readNotifier(c).loadTasks();

      await readNotifier(c).runNow('t1');

      expect(readState(c).tasks.length, equals(1));
      expect(readState(c).tasks.first.lastResult, equals('成功'));
    });

    test('FFI 执行失败时错误可见', () async {
      final mockApi = MockRustApi();
      when(() => mockApi.autoTaskListRules()).thenAnswer((_) async => [
            {'id': 't1', 'name': 'Task', 'taskType': 'backup', 'cron': ''},
          ]);
      when(() => mockApi.autoTaskExecuteWithId(
            protocolJson: any(named: 'protocolJson'),
            taskId: any(named: 'taskId'),
          )).thenThrow(Exception('FFI execute failed'));
      final c = ffiContainer(mockApi);
      await readNotifier(c).loadTasks();

      await readNotifier(c).runNow('t1');
      expect(readState(c).error, contains('运行任务失败'));
    });
  });

  group('AutoTaskNotifier FFI 专属方法', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUp(() {
      mockApi = MockRustApi();
      container = ffiContainer(mockApi);
    });

    test('buildBookUpdateTask 成功', () async {
      final expected = {'id': 'new', 'name': 'Update Task'};
      when(() => mockApi.autoTaskBuildBookUpdateTask(
            bookUrl: any(named: 'bookUrl'),
            bookName: any(named: 'bookName'),
            bookAuthor: any(named: 'bookAuthor'),
            name: any(named: 'name'),
          )).thenAnswer((_) async => expected);

      final result = await readNotifier(container).buildBookUpdateTask(
        bookUrl: 'http://book.com', bookName: 'TestBook',
        bookAuthor: 'Author', name: 'Update',
      );
      expect(result, equals(expected));
    });

    test('buildBookUpdateTask 无 rustApi 返回 null', () async {
      final result = await readNotifier(nullApiContainer()).buildBookUpdateTask(
        bookUrl: '', bookName: '', bookAuthor: '', name: '',
      );
      expect(result, isNull);
    });

    test('normalizeScript 成功', () async {
      when(() => mockApi.autoTaskNormalizeScript(script: any(named: 'script')))
          .thenAnswer((_) async => 'cleaned()');

      final result = await readNotifier(container).normalizeScript('@js:cleaned()');
      expect(result, equals('cleaned()'));
    });

    test('canRefreshBookToc 成功', () async {
      when(() => mockApi.autoTaskCanRefreshBookToc(
            canUpdate: any(named: 'canUpdate'),
            respectCanUpdate: any(named: 'respectCanUpdate'),
          )).thenAnswer((_) async => true);

      final result = await readNotifier(container)
          .canRefreshBookToc(canUpdate: true, respectCanUpdate: true);
      expect(result, isTrue);
    });

    test('nextDueAt 成功', () async {
      when(() => mockApi.autoTaskNextDueAt(
            cron: any(named: 'cron'),
            fromMs: any(named: 'fromMs'),
          )).thenAnswer((_) async => 1735689600000);

      final result = await readNotifier(container).nextDueAt(cron: '0 0 3 * * *');
      expect(result, equals(1735689600000));
    });

    test('findBookUpdateTask list 失败时 fallback 保留 script', () async {
      const bookScript =
          '({"type":"refreshToc","bookUrl":"http://book/1","bookName":"测试书",'
          '"bookAuthor":"作者A","generatedBy":"bookUpdate"})';
      final expected = {'id': 'book_update:abc', 'name': '更新', 'script': bookScript};

      // list 失败 → 退化为 state.tasks 序列化（fromJson 保留 script）
      when(() => mockApi.autoTaskListRules()).thenThrow(Exception('FFI list failed'));
      final c = ffiContainer(mockApi);
      final seeded = AutoTask.fromJson({
        'id': 'book_update:abc',
        'name': '更新',
        'comment': 'refreshToc',
        'cron': '0 */6 * * *',
        'script': bookScript,
      });
      readNotifier(c).state =
          readNotifier(c).state.copyWith(tasks: [seeded]);

      when(() => mockApi.autoTaskFindBookUpdateTask(
            tasksJson: any(named: 'tasksJson'),
            bookUrl: any(named: 'bookUrl'),
            bookName: any(named: 'bookName'),
            bookAuthor: any(named: 'bookAuthor'),
          )).thenAnswer((invocation) async {
        final tasksJson = invocation.namedArguments[#tasksJson] as String;
        final list = jsonDecode(tasksJson) as List;
        expect(list.length, equals(1));
        expect(list[0]['script'], equals(bookScript));
        return expected;
      });

      final result = await readNotifier(c).findBookUpdateTask(
        bookUrl: 'http://book/1',
        bookName: '测试书',
        bookAuthor: '作者A',
      );
      expect(result, equals(expected));
    });
  });
}
