// 阅读器顶栏动作池单测（批37）
//
// 覆盖：默认顺序/默认开关（对齐参考版 DEFAULT_TITLE_BAR_ACTION_IDS）、
// 最多 6 个（含固定「更多」）、书型过滤、持久化格式、更多菜单兜底、
// 备份收集/恢复。
//
// 编写：全栈工程师（批37） ｜ 2026-10-29
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar_actions.dart';

ReaderTopBarActionsState _config(Iterable<ReaderTopBarActionItem> items) =>
    ReaderTopBarActionsState(normalizeReaderTopBarActionItems(items));

List<String> _ids(List<ReaderTopBarActionDef> defs) => [
  for (final def in defs) def.id,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('动作池与默认配置', () {
    test('默认开启集合与顺序对齐参考版', () {
      final items = defaultReaderTopBarActionItems();
      final enabled = [
        for (final item in items)
          if (item.enabled) item.id,
      ];
      expect(enabled, [
        'download',
        'refresh',
        'change_source',
        'toc_rule',
        'charset',
        kReaderMoreActionsId,
      ], reason: '参考版 DEFAULT_TITLE_BAR_ACTION_IDS 按池顺序展开');
      expect(items.last.id, kReaderMoreActionsId, reason: '「更多」固定末位');
    });

    test('默认在线书顶栏 = 缓存/刷新/换源/更多（旧版写死四钮）', () {
      final actions = buildReaderTopBarActions(
        ReaderTopBarActionsState(defaultReaderTopBarActionItems()),
        traits: const ReaderBookTraits(),
      );
      expect(_ids(actions), [
        'download',
        'refresh',
        'change_source',
        kReaderMoreActionsId,
      ]);
    });

    test('书型过滤：本地 TXT 显示 TXT 目录规则/编码，不显示在线动作', () {
      final actions = buildReaderTopBarActions(
        ReaderTopBarActionsState(defaultReaderTopBarActionItems()),
        traits: const ReaderBookTraits(isLocal: true, isLocalTxt: true),
      );
      expect(_ids(actions), ['toc_rule', 'charset', kReaderMoreActionsId]);
    });

    test('书型过滤：本地 EPUB 只显示编码（toc_rule 仅本地 TXT）', () {
      final actions = buildReaderTopBarActions(
        ReaderTopBarActionsState(defaultReaderTopBarActionItems()),
        traits: const ReaderBookTraits(isLocal: true),
      );
      expect(_ids(actions), ['charset', kReaderMoreActionsId]);
    });

    test('最多 6 个且「更多」固定在末尾', () {
      final allOn = _config([
        for (final def in readerTopBarActionPool)
          ReaderTopBarActionItem(id: def.id, enabled: true),
      ]);
      final localTxt = buildReaderTopBarActions(
        allOn,
        traits: const ReaderBookTraits(isLocal: true, isLocalTxt: true),
      );
      expect(localTxt, hasLength(kReaderTopBarMaxActions));
      expect(_ids(localTxt), [
        'toc_rule',
        'charset',
        'catalog',
        'search',
        'auto_page',
        kReaderMoreActionsId,
      ]);
      expect(localTxt.where((e) => e.id == kReaderMoreActionsId), hasLength(1));

      final online = buildReaderTopBarActions(
        allOn,
        traits: const ReaderBookTraits(),
      );
      expect(online, hasLength(kReaderTopBarMaxActions));
      expect(online.last.id, kReaderMoreActionsId);
      expect(_ids(online), [
        'download',
        'refresh',
        'change_source',
        'catalog',
        'search',
        kReaderMoreActionsId,
      ]);
    });

    test('自定义顺序生效（目录前移）', () {
      final config = _config([
        const ReaderTopBarActionItem(id: 'catalog', enabled: true),
        const ReaderTopBarActionItem(id: 'change_source', enabled: true),
        const ReaderTopBarActionItem(id: 'download', enabled: false),
        ...defaultReaderTopBarActionItems(),
      ]);
      expect(config.items.last.id, kReaderMoreActionsId);
      final actions = buildReaderTopBarActions(
        config,
        traits: const ReaderBookTraits(),
      );
      expect(_ids(actions), [
        'catalog',
        'change_source',
        'refresh',
        kReaderMoreActionsId,
      ]);
    });

    test('全部关闭时仍保留「更多」', () {
      final config = _config([
        for (final def in readerTopBarActionPool)
          ReaderTopBarActionItem(id: def.id, enabled: false),
      ]);
      final actions = buildReaderTopBarActions(
        config,
        traits: const ReaderBookTraits(),
      );
      expect(_ids(actions), [kReaderMoreActionsId]);
    });

    test('长按二级动作登记：换源/缓存，其余未登记', () {
      expect(
        readerTopBarActionById['change_source']?.longPress,
        ReaderTopBarLongPress.changeSource,
      );
      expect(
        readerTopBarActionById['download']?.longPress,
        ReaderTopBarLongPress.cacheManage,
      );
      expect(readerTopBarActionById['refresh']?.longPress, isNull);
      expect(readerTopBarActionById['download']?.supportsLongPress, isTrue);
    });
  });

  group('持久化格式（对齐参考版 id,enabled;...）', () {
    test('编码/解码往返', () {
      final items = _config([
        const ReaderTopBarActionItem(id: 'catalog', enabled: true),
        const ReaderTopBarActionItem(id: 'download', enabled: true),
      ]);
      final raw = encodeReaderTopBarActions(items.items);
      expect(raw, contains('catalog,true'));
      expect(raw, endsWith('$kReaderMoreActionsId,true'));
      final decoded = decodeReaderTopBarActions(raw);
      expect(decoded.first.id, 'catalog');
      expect(decoded.first.enabled, isTrue);
      expect(decoded.last.id, kReaderMoreActionsId);
    });

    test('空值/非法值回退默认', () {
      expect(
        _ids(
          buildReaderTopBarActions(
            ReaderTopBarActionsState(decodeReaderTopBarActions(null)),
            traits: const ReaderBookTraits(),
          ),
        ),
        ['download', 'refresh', 'change_source', kReaderMoreActionsId],
      );
      expect(
        decodeReaderTopBarActions('unknown,true;garbage'),
        defaultReaderTopBarActionItems(),
      );
    });

    test('未知 id/重复项丢弃，缺失项补在末尾且默认关闭', () {
      final decoded = decodeReaderTopBarActions(
        'download,true;not_exist,true;download,false;more_actions,false',
      );
      expect(
        decoded.first,
        const ReaderTopBarActionItem(id: 'download', enabled: true),
      );
      expect(decoded.where((e) => e.id == 'download'), hasLength(1));
      expect(decoded.last.id, kReaderMoreActionsId);
      expect(decoded.last.enabled, isTrue, reason: '「更多」固定开启');
      expect(decoded.any((e) => e.id == 'not_exist'), isFalse);
      expect(
        decoded.firstWhere((e) => e.id == 'charset').enabled,
        isFalse,
        reason: '缺失项补默认关闭',
      );
    });
  });

  group('「更多」菜单兜底', () {
    test('顶栏未显示的动作全部可达', () {
      final config = _config([
        for (final def in readerTopBarActionPool)
          ReaderTopBarActionItem(id: def.id, enabled: def.id == 'download'),
      ]);
      final visible = buildReaderTopBarActions(
        config,
        traits: const ReaderBookTraits(),
      );
      final hidden = hiddenReaderTopBarActions(
        config,
        traits: const ReaderBookTraits(),
        visibleIds: _ids(visible).toSet(),
        excludeIds: const {'catalog', 'setting', 'addBookmark', 'replace'},
      );
      final hiddenIds = _ids(hidden);
      expect(hiddenIds, contains('change_source'));
      expect(hiddenIds, contains('refresh'));
      expect(hiddenIds, isNot(contains('download')), reason: '已显示不重复');
      expect(hiddenIds, isNot(contains(kReaderMoreActionsId)));
      expect(hiddenIds, isNot(contains('catalog')), reason: '菜单已有同义项');
      expect(hiddenIds, isNot(contains('setting')));
    });

    test('本地书兜底不含在线动作', () {
      final config = ReaderTopBarActionsState(defaultReaderTopBarActionItems());
      final hidden = hiddenReaderTopBarActions(
        config,
        traits: const ReaderBookTraits(isLocal: true),
        visibleIds: {kReaderMoreActionsId},
      );
      final hiddenIds = _ids(hidden);
      expect(hiddenIds, isNot(contains('change_source')));
      expect(hiddenIds, isNot(contains('refresh')));
      expect(hiddenIds, isNot(contains('download')));
      expect(hiddenIds, isNot(contains('toc_rule')), reason: '本地 epub 不适用');
    });
  });

  group('备份纳入', () {
    test('键名对齐参考版并受「忽略阅读配置」约束', () {
      expect(
        kReaderTopBarActionsPrefsKey,
        'title_bar_actions.actions',
        reason: '参考版 prefs 文件 title_bar_actions + 键 actions',
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
          PrefKeys.readerTopBarActions,
          const {},
        ),
        isTrue,
      );
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(PrefKeys.readerTopBarActions, const {
          'readConfig': true,
        }),
        isFalse,
      );
    });

    test('collectForBackup 导出本键，applyFromBackup 写回', () async {
      const raw = 'download,true;catalog,true;more_actions,true';
      SharedPreferences.setMockInitialValues({
        PrefKeys.readerTopBarActions: raw,
      });
      final collected = await RestoreIgnorePrefs.collectForBackup(const {});
      expect(collected[PrefKeys.readerTopBarActions], raw);

      SharedPreferences.setMockInitialValues({});
      await RestoreIgnorePrefs.applyFromBackup({
        PrefKeys.readerTopBarActions: raw,
      }, const {});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.readerTopBarActions), raw);
    });
  });
}
