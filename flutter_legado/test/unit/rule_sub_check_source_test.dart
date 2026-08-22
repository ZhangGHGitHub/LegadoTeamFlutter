/// 规则订阅 + 书源校验 + 失效分组回写 单元测试
///
/// 覆盖：
/// - RuleSub 模型（契约 §2.39 RuleSubRecord JSON：sub_type 字符串 /
///   is_enabled / last_update / customOrder 驼峰）
/// - RuleSubNotifier：loadSubs 排序 / findDuplicate / saveSub 排序追加 /
///   deleteSub / reorder 持久化 / setEnabled
/// - CheckSourceNotifier：初始状态 / 关键词持久化 / 空列表守卫 / clearMessages
/// - SourceNotifier.addGroupToUrls：校验失效分组回写（指定 URL、
///   已有分组跳过、不退出批量模式）
library;
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/source/source_notifier.dart';
import 'package:flutter_legado/src/providers/source_check/check_source_notifier.dart';
import 'package:flutter_legado/src/providers/rule_sub/rule_sub_notifier.dart';
import 'package:flutter_legado/src/models/models.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(<String>[]);
    registerFallbackValue('');
  });

  group('RuleSub 模型（契约 §2.39 RuleSubRecord JSON）', () {
    test('fromJson 解析 Rust 序列化字段', () {
      final sub = RuleSub.fromJson({
        'id': 3,
        'url': 'https://example.com/sub.json',
        'name': '测试订阅',
        'sub_type': 'rssSource',
        'last_update': 1700000000000,
        'version': '1.2',
        'is_enabled': false,
        'created_at': 1690000000000,
        'customOrder': 5,
        'autoUpdate': true,
        'updateInterval': 12,
        'silentUpdate': true,
      });
      expect(sub.id, equals(3));
      expect(sub.url, equals('https://example.com/sub.json'));
      expect(sub.name, equals('测试订阅'));
      expect(sub.subType, equals(RuleSub.rssSource));
      expect(sub.lastUpdate, equals(1700000000000));
      expect(sub.version, equals('1.2'));
      expect(sub.isEnabled, isFalse);
      expect(sub.createdAt, equals(1690000000000));
      expect(sub.customOrder, equals(5));
      expect(sub.autoUpdate, isTrue);
      expect(sub.updateInterval, equals(12));
      expect(sub.silentUpdate, isTrue);
    });

    test('fromJson 缺省字段：isEnabled 默认 true，subType 默认书源', () {
      final sub = RuleSub.fromJson({'id': 1, 'url': 'u', 'name': 'n'});
      expect(sub.isEnabled, isTrue);
      expect(sub.subType, equals(RuleSub.bookSource));
      expect(sub.customOrder, equals(0));
    });

    test('toJson/fromJson 往返一致', () {
      const original = RuleSub(
        id: 7,
        url: 'https://x.cn/r.json',
        name: '往返',
        subType: RuleSub.replaceRule,
        customOrder: 2,
        autoUpdate: true,
        updateInterval: 24,
        silentUpdate: true,
      );
      final round = RuleSub.fromJson(original.toJson());
      expect(round.id, equals(original.id));
      expect(round.subType, equals(original.subType));
      expect(round.customOrder, equals(original.customOrder));
      expect(round.autoUpdate, equals(original.autoUpdate));
      expect(round.updateInterval, equals(original.updateInterval));
      expect(round.silentUpdate, equals(original.silentUpdate));
    });

    test('typeLabel 三类映射（对标 arrays.xml rule_type）', () {
      expect(const RuleSub(subType: RuleSub.bookSource).typeLabel, equals('书源'));
      expect(const RuleSub(subType: RuleSub.rssSource).typeLabel, equals('订阅源'));
      expect(
        const RuleSub(subType: RuleSub.replaceRule).typeLabel,
        equals('替换规则'),
      );
    });
  });

  group('RuleSubNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    RuleSubState readState() => container.read(ruleSubNotifierProvider);
    RuleSubNotifier readNotifier() =>
        container.read(ruleSubNotifierProvider.notifier);

    Map<String, dynamic> subJson(int id, String url, int order) => {
          'id': id,
          'url': url,
          'name': '订阅$id',
          'sub_type': 'bookSource',
          'customOrder': order,
        };

    test('loadSubs 按 customOrder 排序', () async {
      when(() => mockApi.ruleSubList()).thenAnswer((_) async => [
            subJson(2, 'https://b', 2),
            subJson(1, 'https://a', 1),
            subJson(3, 'https://c', 0),
          ]);
      await readNotifier().loadSubs();

      final subs = readState().subs;
      expect(subs.map((s) => s.id), equals([3, 1, 2]));
      expect(readState().loading, isFalse);
    });

    test('findDuplicate 命中他人、排除自身', () async {
      when(() => mockApi.ruleSubList()).thenAnswer((_) async => [
            subJson(1, 'https://a', 1),
            subJson(2, 'https://b', 2),
          ]);
      await readNotifier().loadSubs();

      expect(readNotifier().findDuplicate('https://a')?.id, equals(1));
      expect(
        readNotifier().findDuplicate('https://a', excludeId: 1),
        isNull,
      );
      expect(readNotifier().findDuplicate('https://zzz'), isNull);
    });

    test('saveSub 新增时 customOrder 追加到末尾并持久化', () async {
      when(() => mockApi.ruleSubList()).thenAnswer((_) async => [
            subJson(1, 'https://a', 3),
          ]);
      when(() => mockApi.ruleSubSave(subJson: any(named: 'subJson')))
          .thenAnswer((_) async => true);
      await readNotifier().loadSubs();

      await readNotifier().saveSub(
        const RuleSub(url: 'https://new', name: '新订阅'),
      );

      final captured = verify(
        () => mockApi.ruleSubSave(subJson: captureAny(named: 'subJson')),
      ).captured.single as String;
      final saved = RuleSub.fromJson(
        jsonDecode(captured) as Map<String, dynamic>,
      );
      expect(saved.customOrder, equals(4)); // max(3) + 1
      expect(saved.createdAt, greaterThan(0));
    });

    test('deleteSub 移除条目', () async {
      when(() => mockApi.ruleSubList()).thenAnswer((_) async => [
            subJson(1, 'https://a', 1),
            subJson(2, 'https://b', 2),
          ]);
      when(() => mockApi.ruleSubDelete(id: any(named: 'id')))
          .thenAnswer((_) async => true);
      await readNotifier().loadSubs();

      await readNotifier().deleteSub(1);
      expect(readState().subs.map((s) => s.id), equals([2]));
    });

    test('reorder 重排并以新 ID 序列持久化', () async {
      when(() => mockApi.ruleSubList()).thenAnswer((_) async => [
            subJson(1, 'https://a', 0),
            subJson(2, 'https://b', 1),
            subJson(3, 'https://c', 2),
          ]);
      when(() => mockApi.ruleSubUpdateOrder(ids: any(named: 'ids')))
          .thenAnswer((_) async => true);
      await readNotifier().loadSubs();

      // 将末项拖到首位（ReorderableListView 语义：oldIndex=2, newIndex=0）
      await readNotifier().reorder(2, 0);

      expect(readState().subs.map((s) => s.id), equals([3, 1, 2]));
      final captured = verify(
        () => mockApi.ruleSubUpdateOrder(ids: captureAny(named: 'ids')),
      ).captured.single as List<int>;
      expect(captured, equals([3, 1, 2]));
    });

    test('setEnabled 切换启用状态', () async {
      when(() => mockApi.ruleSubList()).thenAnswer((_) async => [
            subJson(1, 'https://a', 1),
          ]);
      when(() => mockApi.ruleSubSetEnabled(
            id: any(named: 'id'),
            enabled: any(named: 'enabled'),
          )).thenAnswer((_) async => true);
      await readNotifier().loadSubs();
      expect(readState().subs.single.isEnabled, isTrue);

      await readNotifier().setEnabled(1, false);
      expect(readState().subs.single.isEnabled, isFalse);
    });
  });

  group('CheckSourceNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    CheckSourceState readState() => container.read(checkSourceNotifierProvider);
    CheckSourceNotifier readNotifier() =>
        container.read(checkSourceNotifierProvider.notifier);

    test('初始状态无会话', () {
      expect(readState().checking, isFalse);
      expect(readState().hasSession, isFalse);
      expect(readState().messages, isEmpty);
      expect(readState().invalidCount, equals(0));
    });

    test('loadKeyword 默认「我的」（对标原版默认关键词）', () async {
      expect(await readNotifier().loadKeyword(), equals('我的'));
    });

    test('start 空 URL 列表不启动会话', () async {
      await readNotifier().start(sourceUrls: const []);
      expect(readState().hasSession, isFalse);
      verifyNever(() => mockApi.checkSourcesStream(
            any(),
            configJson: any(named: 'configJson'),
          ));
    });

    test('start 持久化关键词并携带 configJson', () async {
      when(() => mockApi.checkSourcesStream(
            any(),
            configJson: any(named: 'configJson'),
          )).thenAnswer((_) => const Stream.empty());

      await readNotifier().start(
        sourceUrls: const ['https://a'],
        keyword: '测试词',
      );
      // 流微任务收尾
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('check_source_keyword'), equals('测试词'));
      final captured = verify(() => mockApi.checkSourcesStream(
            any(),
            configJson: captureAny(named: 'configJson'),
          )).captured.single as String;
      expect(captured, contains('测试词'));
      expect(readState().total, equals(1));
    });

    test('clearMessages 重置会话', () async {
      when(() => mockApi.checkSourcesStream(
            any(),
            configJson: any(named: 'configJson'),
          )).thenAnswer((_) => const Stream.empty());
      await readNotifier().start(sourceUrls: const ['https://a']);
      await Future.delayed(Duration.zero);
      expect(readState().hasSession, isTrue);

      readNotifier().clearMessages();
      expect(readState().hasSession, isFalse);
      expect(readState().messages, isEmpty);
    });
  });

  group('SourceNotifier.addGroupToUrls（校验失效分组回写）', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    SourceState readState() => container.read(sourceNotifierProvider);
    SourceNotifier readNotifier() =>
        container.read(sourceNotifierProvider.notifier);

    Future<void> loadWith(List<BookSource> sources) async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      when(() => mockApi.updateBookSource(any()))
          .thenAnswer((_) async {});
      await readNotifier().loadSources();
    }

    test('为指定 URL 追加分组', () async {
      await loadWith([
        const BookSource(bookSourceUrl: 'https://a', bookSourceName: 'A'),
        const BookSource(
          bookSourceUrl: 'https://b',
          bookSourceName: 'B',
          bookSourceGroup: '玄幻',
        ),
      ]);

      await readNotifier().addGroupToUrls({'https://b'}, '失效');

      final captured = verify(
        () => mockApi.updateBookSource(captureAny()),
      ).captured.single as BookSource;
      expect(captured.bookSourceGroup, equals('玄幻,失效'));
      expect(
        readState().sources.firstWhere((s) => s.bookSourceUrl == 'https://b')
            .bookSourceGroup,
        equals('玄幻,失效'),
      );
    });

    test('已有该分组时跳过持久化', () async {
      await loadWith([
        const BookSource(
          bookSourceUrl: 'https://a',
          bookSourceName: 'A',
          bookSourceGroup: '失效',
        ),
      ]);

      await readNotifier().addGroupToUrls({'https://a'}, '失效');
      verifyNever(() => mockApi.updateBookSource(any()));
    });

    test('不退出批量模式、不清空选择', () async {
      await loadWith([
        const BookSource(bookSourceUrl: 'https://a', bookSourceName: 'A'),
      ]);
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('https://a');

      await readNotifier().addGroupToUrls({'https://a'}, '失效');

      expect(readState().batchMode, isTrue);
      expect(readState().selectedUrls, equals({'https://a'}));
    });

    test('空分组名直接返回', () async {
      await loadWith([
        const BookSource(bookSourceUrl: 'https://a', bookSourceName: 'A'),
      ]);
      await readNotifier().addGroupToUrls({'https://a'}, '  ');
      verifyNever(() => mockApi.updateBookSource(any()));
    });
  });
}
