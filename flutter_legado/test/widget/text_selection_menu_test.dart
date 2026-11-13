// [批4c] 选择菜单浮条/面板/配置 Sheet 测试
//
// 编写：全栈工程师（批4c） ｜ 2026-11-04
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart';
import 'package:flutter_legado/src/widgets/reader/text_select_menu_config_sheet.dart';

ReaderAdvancedConfig _config({
  bool expand = false,
  bool showIcon = true,
  Map<String, int> states = const {},
}) {
  var config = SelectionMenuConfig.defaults();
  for (final entry in states.entries) {
    config = config.moveToState(entry.key, entry.value);
  }
  return ReaderAdvancedConfig()
    ..textSelectMenuConfig = config.encode()
    ..expandTextMenu = expand
    ..showSelectMenuIcon = showIcon;
}

ProviderContainer _container(
  ReaderAdvancedConfig cfg, {
  ReaderState? readerState,
  BookApi? api,
  AudioNotifier Function()? audioNotifier,
}) {
  final container = ProviderContainer(
    overrides: [
      bookApiProvider.overrideWithValue(api ?? MockBookApi()),
      if (readerState != null)
        readerNotifierProvider.overrideWith(
          () => _FixedReaderNotifier(readerState),
        ),
      if (audioNotifier != null)
        audioNotifierProvider.overrideWith(audioNotifier),
    ],
  );
  container.read(readerAdvConfigProvider.notifier).apply(cfg);
  addTearDown(container.dispose);
  return container;
}

/// 固定阅读状态（menu_mark 打开笔记 Sheet 需要书籍/章节上下文）
class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this._state);

  final ReaderState _state;

  @override
  ReaderState build() => _state;
}

/// 捕获朗读起始章号（P2-2 冻结帧快照测试）
class _CapturingAudioNotifier extends AudioNotifier {
  int? capturedChapterIndex;

  @override
  AudioState build() => AudioState(config: TtsConfig());

  @override
  Future<void> startReadAloud({
    required String bookUrl,
    required String bookName,
    int chapterIndex = 0,
    int? startChapterPos,
    String? startParagraphText,
    List<int>? pageStarts,
    bool fromReader = false,
  }) async {
    capturedChapterIndex = chapterIndex;
  }
}

const _testReaderState = ReaderState(
  currentBook: Book(
    bookUrl: 'https://src.com/book/1',
    name: '测试书',
    author: '作者A',
    origin: 'https://src.com',
  ),
  chapters: [
    BookChapter(
      url: 'u0',
      title: '第一章',
      index: 0,
      bookUrl: 'https://src.com/book/1',
    ),
  ],
  currentChapterIndex: 0,
  chapterContent: '选中文本',
);

Widget _toolbar(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    home: Scaffold(
      body: Center(
        child: ReaderSelectionToolbar(
          anchor: const Offset(200, 200),
          text: '选中文本',
          chapterPos: 0,
          onDismiss: () {},
        ),
      ),
    ),
  ),
);

Widget _overlayHost(ProviderContainer container, Offset anchor) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('open-selection-toolbar'),
                onPressed: () => ReaderSelectionToolbar.show(
                  context,
                  anchor: anchor,
                  text: '选中文本',
                  chapterPos: 0,
                ),
                child: const Text('打开浮条'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _openOverlayToolbar(
  WidgetTester tester,
  ProviderContainer container,
  Offset anchor,
) async {
  await tester.pumpWidget(_overlayHost(container, anchor));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('open-selection-toolbar')));
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('浮条', () {
    testWidgets('默认按配置顺序渲染已实现项 + 更多 + 管理', (tester) async {
      await tester.pumpWidget(_toolbar(_container(_config())));
      await tester.pump();
      for (final id in [
        SelectionMenuIds.copy,
        SelectionMenuIds.share,
        SelectionMenuIds.browser,
        SelectionMenuIds.aloud,
        SelectionMenuIds.bookmark,
        SelectionMenuIds.mark,
        SelectionMenuIds.dict,
        SelectionMenuIds.replace,
        SelectionMenuIds.edit,
        SelectionMenuIds.search,
      ]) {
        expect(
          find.byKey(ValueKey('selection-action-$id')),
          findsOneWidget,
          reason: id,
        );
      }
      expect(
        find.byKey(const ValueKey('selection-action-menu_more')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-menu-manage')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-action-menu_ai_clean')),
        findsNothing,
      );
      final xCopy = tester
          .getTopLeft(find.byKey(const ValueKey('selection-action-menu_copy')))
          .dx;
      final xShare = tester
          .getTopLeft(
            find.byKey(const ValueKey('selection-action-menu_share_str')),
          )
          .dx;
      final xBrowser = tester
          .getTopLeft(
            find.byKey(const ValueKey('selection-action-menu_browser')),
          )
          .dx;
      expect(xCopy < xShare && xShare < xBrowser, isTrue, reason: '参考默认顺序');
    });

    testWidgets('360dp 默认 10 项：更多/管理固定在滚动区外且可点', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _openOverlayToolbar(
        tester,
        _container(_config()),
        const Offset(180, 300),
      );

      expect(
        find.byKey(const ValueKey('selection-action-menu_copy')).hitTestable(),
        findsOneWidget,
        reason: '首个动作仍可见',
      );
      expect(
        find.byKey(const ValueKey('selection-action-menu_more')).hitTestable(),
        findsOneWidget,
        reason: '更多不得被横向滚动挤出屏幕',
      );
      expect(
        find.byKey(const ValueKey('selection-menu-manage')).hitTestable(),
        findsOneWidget,
        reason: '管理不得被横向滚动挤出屏幕',
      );
      final moreRect = tester.getRect(
        find.byKey(const ValueKey('selection-action-menu_more')),
      );
      final manageRect = tester.getRect(
        find.byKey(const ValueKey('selection-menu-manage')),
      );
      expect(moreRect.right, lessThanOrEqualTo(360));
      expect(manageRect.right, lessThanOrEqualTo(360));
    });

    testWidgets('展开模式屏底锚点 + 1.6 倍字号：菜单不越界且管理可点', (tester) async {
      tester.view.physicalSize = const Size(576, 1024);
      tester.view.devicePixelRatio = 1.6;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _openOverlayToolbar(
        tester,
        _container(_config(expand: true)),
        const Offset(180, 620),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('selection-action-menu_copy')).hitTestable(),
        findsOneWidget,
        reason: '首行仍可见',
      );
      expect(
        find.byKey(const ValueKey('selection-menu-manage')).hitTestable(),
        findsOneWidget,
        reason: '管理按钮仍可点',
      );
      final manageRect = tester.getRect(
        find.byKey(const ValueKey('selection-menu-manage')),
      );
      expect(manageRect.top, greaterThanOrEqualTo(0));
      expect(manageRect.bottom, lessThanOrEqualTo(640));
    });

    testWidgets('320dp 打开浮条不抛 clamp 参数错误且复制可见', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _openOverlayToolbar(
        tester,
        _container(_config()),
        const Offset(160, 300),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('selection-action-menu_copy')).hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('折叠项进更多；隐藏项不渲染', (tester) async {
      await tester.pumpWidget(
        _toolbar(
          _container(
            _config(
              states: {SelectionMenuIds.copy: 1, SelectionMenuIds.mark: 2},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('selection-action-menu_copy')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('selection-action-menu_mark')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('selection-action-menu_more')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextSelectionPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selection-panel-action-menu_copy')),
        findsOneWidget,
        reason: '折叠项在底部面板可见',
      );
      expect(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
        findsNothing,
        reason: '隐藏项不渲染',
      );
    });

    testWidgets('expandTextMenu=true：一级+折叠合并多行，隐藏不显示', (tester) async {
      await tester.pumpWidget(
        _toolbar(
          _container(
            _config(
              expand: true,
              states: {SelectionMenuIds.copy: 1, SelectionMenuIds.mark: 2},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('selection-action-menu_copy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-action-menu_mark')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('selection-action-menu_more')),
        findsNothing,
        reason: '多行模式不再需要更多',
      );
    });

    testWidgets('showSelectMenuIcon=false 隐藏动作图标；默认显示', (tester) async {
      await tester.pumpWidget(_toolbar(_container(_config(showIcon: false))));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('selection-action-menu_copy')),
          matching: find.byIcon(Icons.copy_outlined),
        ),
        findsNothing,
      );

      await tester.pumpWidget(_toolbar(_container(_config(showIcon: true))));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('selection-action-menu_copy')),
          matching: find.byIcon(Icons.copy_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('menu_mark 打开笔记 Sheet；管理打开配置 Sheet', (tester) async {
      await tester.pumpWidget(
        _toolbar(_container(_config(), readerState: _testReaderState)),
      );
      await tester.pump();
      expect(find.text('笔记'), findsOneWidget, reason: 'menu_mark 文案对齐参考版');
      await tester.tap(
        find.byKey(const ValueKey('selection-action-menu_mark')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('marking-sheet')), findsOneWidget);
      expect(find.text('编辑笔记'), findsNothing);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('marking-sheet'))),
      ).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('selection-menu-manage')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('select-menu-config-sheet')),
        findsOneWidget,
      );
    });

    testWidgets('浮条管理→保存：Sheet 关闭、配置落盘、重开回显且无异常', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = _container(_config());
      await _openOverlayToolbar(tester, container, const Offset(200, 300));

      // 真实 Overlay 路径：浮条先 dismiss，再打开配置 Sheet
      await tester.tap(find.byKey(const ValueKey('selection-menu-manage')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('select-menu-config-sheet')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('select-menu-move-menu_share_str')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('移至隐藏'));
      await tester.pumpAndSettle();
      expect(find.text('已隐藏项目（1）'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('select-menu-save')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('select-menu-config-sheet')),
        findsNothing,
        reason: '保存后 Sheet 必须关闭',
      );
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PrefKeys.textSelectMenuConfig);
      expect(raw, isNotNull, reason: '配置必须落盘');
      expect(
        SelectionMenuConfig.decode(raw).stateOf(SelectionMenuIds.share),
        2,
      );
      expect(
        container.read(readerAdvConfigProvider)?.textSelectMenuConfig,
        isNotNull,
      );

      // 再次从浮条打开，回显已保存的隐藏分区
      await tester.tap(find.byKey(const ValueKey('open-selection-toolbar')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('selection-menu-manage')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('select-menu-config-sheet')),
        findsOneWidget,
      );
      expect(find.text('已隐藏项目（1）'), findsOneWidget);
    });
  });

  group('底部选择面板', () {
    Widget panel(
      ProviderContainer container, {
      String text = '选中文本',
      int chapterPos = 0,
      int? chapterIndex,
      String? chapterTitle,
    }) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: TextSelectionPanel(
            text: text,
            chapterPos: chapterPos,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
          ),
        ),
      ),
    );

    testWidgets('360dp 默认 10 项：管理固定在滚动区外且可点', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(panel(_container(_config())));
      await tester.pump();

      expect(
        find
            .byKey(const ValueKey('selection-panel-action-menu_copy'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-panel-manage')).hitTestable(),
        findsOneWidget,
      );
      final manageRect = tester.getRect(
        find.byKey(const ValueKey('selection-panel-manage')),
      );
      expect(manageRect.right, lessThanOrEqualTo(360));
    });

    testWidgets('按配置渲染、隐藏过滤、mark 打开笔记 Sheet', (tester) async {
      await tester.pumpWidget(
        panel(
          _container(
            _config(
              states: {SelectionMenuIds.mark: 0, SelectionMenuIds.copy: 2},
            ),
            readerState: _testReaderState,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-panel-action-menu_copy')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('marking-sheet')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selection-panel-manage')),
        findsNothing,
        reason: '打开笔记 Sheet 前先收起段落面板（对齐参考版替换式 Sheet）',
      );
    });

    testWidgets('「高亮」二级入口保留手工高亮配色行', (tester) async {
      await tester.pumpWidget(panel(_container(_config())));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('selection-panel-highlight')));
      await tester.pump();
      expect(find.text('高亮颜色'), findsOneWidget);
    });

    testWidgets('P2-6 同段再次打开：编辑模式并预填旧备注', (tester) async {
      final api = MockBookApi();
      await api.saveBookMarking(
        BookMarking(
          bookUrl: 'https://src.com/book/1',
          bookName: '测试书',
          bookAuthor: '作者A',
          chapterIndex: 0,
          anchorJson: buildBookMarkingAnchor(
            chapterIndex: 0,
            chapterPosition: 0,
            selectedText: '选中文本',
          ).encode(),
          styleJson: MarkingEffect.wave.toStyle(0xFF22C55E).encode(),
          note: '旧备注',
          chapterName: '第一章',
        ),
      );
      await tester.pumpWidget(
        panel(_container(_config(), readerState: _testReaderState, api: api)),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
      );
      await tester.pumpAndSettle();

      expect(find.text('编辑笔记'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('marking-note-field')),
      );
      expect(field.controller?.text, '旧备注');
    });

    testWidgets('P2-2 分页快照章号/标题优先于实时阅读状态', (tester) async {
      final api = MockBookApi();
      await tester.pumpWidget(
        panel(
          _container(
            _config(),
            readerState: _testReaderState, // 实时状态：第 1 章
            api: api,
          ),
          chapterIndex: 5,
          chapterTitle: '第五章',
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
      );
      await tester.pumpAndSettle();
      expect(find.text('笔记'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('marking-note-field')),
        '快照章',
      );
      await tester.tap(find.byKey(const ValueKey('marking-save')));
      await tester.pumpAndSettle();

      final list = await api.getBookMarkingsByBook('测试书', '作者A');
      expect(list, hasLength(1));
      expect(list.single.chapterIndex, 5, reason: '应使用分页快照章号');
      expect(list.single.chapterName, '第五章');
    });

    testWidgets('P1-1 组件级：selection.start 捕获重复词第二次出现', (tester) async {
      final api = MockBookApi();
      await tester.pumpWidget(
        panel(
          _container(_config(), readerState: _testReaderState, api: api),
          text: '　　重复词和重复词',
          chapterPos: 100,
        ),
      );
      await tester.pump();
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      selectable.onSelectionChanged!(
        const TextSelection(baseOffset: 6, extentOffset: 9),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('marking-save')));
      await tester.pumpAndSettle();

      final list = await api.getBookMarkingsByBook('测试书', '作者A');
      expect(list, hasLength(1));
      final anchor = BookMarkingAnchor.tryParse(list.single.anchorJson)!;
      expect(anchor.selectedText, '重复词');
      expect(anchor.chapterPosition, 104, reason: '100 + (6 - 缩进2)');
    });

    testWidgets('P3-3 空白-only 选区回退整段文本', (tester) async {
      final api = MockBookApi();
      await tester.pumpWidget(
        panel(
          _container(_config(), readerState: _testReaderState, api: api),
          text: '　　重复词和重复词',
          chapterPos: 100,
        ),
      );
      await tester.pump();
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      selectable.onSelectionChanged!(
        const TextSelection(baseOffset: 0, extentOffset: 2),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('marking-save')));
      await tester.pumpAndSettle();

      final list = await api.getBookMarkingsByBook('测试书', '作者A');
      expect(list, hasLength(1));
      final anchor = BookMarkingAnchor.tryParse(list.single.anchorJson)!;
      expect(anchor.selectedText, '重复词和重复词');
      expect(anchor.chapterPosition, 100);
    });

    testWidgets('P2-2 高亮保存使用分页快照章号/标题', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = MockBookApi();
      await tester.pumpWidget(
        panel(
          _container(_config(), readerState: _testReaderState, api: api),
          chapterIndex: 5,
          chapterTitle: '第五章',
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('selection-panel-highlight')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('highlight-color-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存高亮'));
      await tester.pumpAndSettle();

      final raw = await api.highlightListByBook(
        bookUrl: 'https://src.com/book/1',
      );
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      expect(list, hasLength(1));
      expect(list.single['chapterIndex'], 5);
      expect(list.single['chapterName'], '第五章');
    });

    testWidgets('P2-2 书签使用分页快照章号/标题', (tester) async {
      final api = MockBookApi();
      await tester.pumpWidget(
        panel(
          _container(_config(), readerState: _testReaderState, api: api),
          chapterIndex: 5,
          chapterTitle: '第五章',
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_bookmark')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final list = await api.getAllBookmarks();
      expect(list, hasLength(1));
      expect(list.single.chapterIndex, 5);
      expect(list.single.chapterName, '第五章');
    });

    testWidgets('P2-2 朗读使用分页快照章号', (tester) async {
      final audio = _CapturingAudioNotifier();
      await tester.pumpWidget(
        panel(
          _container(
            _config(),
            readerState: _testReaderState,
            audioNotifier: () => audio,
          ),
          chapterIndex: 5,
          chapterTitle: '第五章',
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_aloud')),
      );
      await tester.pump();
      expect(audio.capturedChapterIndex, 5);
    });

    testWidgets('P2-2 滚动模式 ReaderParagraphs 使用快照章号/标题', (tester) async {
      final api = MockBookApi();
      final container = _container(
        _config(),
        readerState: _testReaderState,
        api: api,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ReaderParagraphs(
                  content: '选中文本',
                  chapterIndex: 5,
                  chapterTitle: '第五章',
                  fontSize: 16,
                  lineHeight: 1.5,
                  paragraphSpacing: 0,
                  textColor: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.longPress(find.text('选中文本'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_mark')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('marking-save')));
      await tester.pumpAndSettle();

      final list = await api.getBookMarkingsByBook('测试书', '作者A');
      expect(list, hasLength(1));
      expect(list.single.chapterIndex, 5);
      expect(list.single.chapterName, '第五章');
    });

    testWidgets('menu_edit 打开编辑内容对话框', (tester) async {
      await tester.pumpWidget(panel(_container(_config())));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('selection-panel-action-menu_edit')),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑内容'), findsOneWidget);
    });
  });

  // [设备验收缺陷 | 2026-11-13] 底部面板内容超屏时底部操作不可达。
  // 面板原来用不可滚动 Column 承载，内容（文本块 0.3 屏 + 操作行 +
  // 展开的「高亮颜色」行 + Sheet 走纸）一旦超过 Sheet 可用高度，超出
  // 部分会落在 Column 的 layout 尺寸之外：仍被绘制（看得见），但不参与
  // 命中测试（点不到）——手工高亮入口因此在真机上不可用。
  // 这里用真实 showModalBottomSheet 路径 + 应用主题（含 Sheet 走纸）
  // 覆盖三种场景：横屏小高度（会溢出）、竖屏设备尺寸（不溢出但贴底）、
  // 窄屏大字号（头部行横向挤压）。
  group('底部选择面板·可达性', () {
    // 足以把选区文本块顶到 0.3 屏上限的长段落
    final longParagraph = List.filled(
      40,
      '用于验证底部面板在内容超出可用高度时仍可操作的长段落文本。',
    ).join();

    Widget sheetHost(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-selection-panel-sheet'),
              onPressed: () =>
                  TextSelectionPanel.show(context, text: longParagraph),
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    );

    Future<void> openAndExpand(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(sheetHost(container));
      await tester.tap(
        find.byKey(const ValueKey('open-selection-panel-sheet')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selection-panel-highlight')));
      await tester.pumpAndSettle();
    }

    ScrollableState outerScrollable(WidgetTester tester) =>
        tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('selection-panel-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );

    testWidgets('横屏 640×360：内容超出 Sheet 高度时配色行可滚动到并点击', (tester) async {
      // 阅读器支持横屏（reader_screen 按设置在竖/横屏间切换）；横屏下
      // Sheet 可用高度不足，正是设备上「配色行被挤出屏幕」的触发条件。
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openAndExpand(tester, _container(_config()));

      // 先验证用户可见症状：配色行必须能被滚动揭示且可点。修复前
      // 面板不可滚动，该行整行落在 Column 的 layout 尺寸之外——可见
      // 但 hitTestable 为空，tap 会抛 "would not hit test" 警告且对话框
      // 不出现，这也是设备上手工高亮入口不可用的直接原因。
      final color0 = find.byKey(const ValueKey('highlight-color-0'));
      await tester.ensureVisible(color0);
      await tester.pumpAndSettle();
      expect(
        color0.hitTestable(),
        findsOneWidget,
        reason: '配色行必须进入可点击区域（修复前整行在 Column 尺寸外，点不到）',
      );
      final rect = tester.getRect(color0);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(
        rect.bottom,
        lessThanOrEqualTo(360 - 8),
        reason: '最后一个可交互元素下方须保留底部安全余量',
      );

      // 外层滚动容器：存在、有滚动量、能响应用户拖动（避开内层选区
      // 文本块：从面板左侧留白处起手）。
      expect(
        find.byKey(const ValueKey('selection-panel-scroll')),
        findsOneWidget,
        reason: '面板内容必须由可滚动容器承载（修复前为不可滚动 Column）',
      );
      final position = outerScrollable(tester).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: '内容高度超过 Sheet 可用高度时必须可纵向滚动',
      );
      position.jumpTo(0);
      await tester.pump();
      await tester.dragFrom(const Offset(8, 120), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0), reason: '外层滚动容器必须响应用户拖动');

      await tester.ensureVisible(color0);
      await tester.pumpAndSettle();
      await tester.tap(color0);
      await tester.pumpAndSettle();
      expect(find.text('保存高亮'), findsOneWidget, reason: '点色块应打开高亮对话框');
      expect(tester.takeException(), isNull);
    });

    testWidgets('360×640 设备尺寸：内容未超屏时保持紧凑且配色行可点', (tester) async {
      // 与设备 1080×1920@3.0 同逻辑尺寸；内容刚好放下时不得为滚动而
      // 强制整屏（避免每次长按都弹满屏），配色行仍须可点。
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await openAndExpand(tester, _container(_config()));

      final position = outerScrollable(tester).position;
      expect(
        position.maxScrollExtent,
        0,
        reason: '内容未超出时外层滚动范围为 0（面板保持内容自适应高度）',
      );

      final color0 = find.byKey(const ValueKey('highlight-color-0'));
      expect(color0.hitTestable(), findsOneWidget);
      final rect = tester.getRect(color0);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(640));
      await tester.tap(color0);
      await tester.pumpAndSettle();
      expect(find.text('保存高亮'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320dp + 1.5 倍字号：头部「高亮/关闭」仍可达', (tester) async {
      // 同属「可见不可点」类：字数文本固定宽度时头部 Row 在 320dp/大字号
      // 下横向溢出，「关闭」被推出 Row 尺寸而无法命中。
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openAndExpand(tester, _container(_config()));

      expect(tester.takeException(), isNull, reason: '头部行不得横向溢出');
      expect(
        find.byKey(const ValueKey('selection-panel-highlight')).hitTestable(),
        findsOneWidget,
      );
      final closeRect = tester.getRect(find.widgetWithText(TextButton, '关闭'));
      expect(closeRect.right, lessThanOrEqualTo(320));
      expect(closeRect.bottom, lessThanOrEqualTo(640));
    });
  });

  group('配置 Sheet', () {
    Widget sheet(
      ReaderAdvancedConfig cfg,
      ValueChanged<ReaderAdvancedConfig> changed,
    ) => MaterialApp(
      home: Scaffold(
        body: TextSelectMenuConfigSheet(config: cfg, onChanged: changed),
      ),
    );

    testWidgets('320×480@1.3 窄屏无横向溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(sheet(_config(), (_) {}));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('select-menu-config-sheet')),
        findsOneWidget,
      );
    });

    testWidgets('三组渲染、组间移动、上下移、保存 JSON', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ReaderAdvancedConfig? updated;
      await tester.pumpWidget(sheet(_config(), (v) => updated = v));
      await tester.pump();

      expect(find.text('一级菜单（10）'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('select-menu-item-menu_copy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('select-menu-item-menu_ai_clean')),
        findsNothing,
      );

      // 下移 copy
      await tester.tap(
        find.byKey(const ValueKey('select-menu-down-menu_copy')),
      );
      await tester.pump();
      // 将 share 移到隐藏
      await tester.tap(
        find.byKey(const ValueKey('select-menu-move-menu_share_str')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('移至隐藏'));
      await tester.pumpAndSettle();
      expect(find.text('已隐藏项目（1）'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('select-menu-expand-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-menu-icon-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-menu-save')));
      await tester.pumpAndSettle();

      expect(updated, isNotNull);
      expect(updated!.expandTextMenu, isTrue);
      expect(updated!.showSelectMenuIcon, isFalse);
      final config = SelectionMenuConfig.decode(updated!.textSelectMenuConfig);
      expect(config.stateOf(SelectionMenuIds.share), 2);
    });

    testWidgets('组内上下移保存顺序', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ReaderAdvancedConfig? updated;
      await tester.pumpWidget(sheet(_config(), (v) => updated = v));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('select-menu-down-menu_copy')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-menu-save')));
      await tester.pumpAndSettle();
      final primary = SelectionMenuConfig.decode(
        updated!.textSelectMenuConfig,
      ).view.primary.map((e) => e.id).toList();
      expect(primary.take(2), [SelectionMenuIds.share, SelectionMenuIds.copy]);
    });

    testWidgets('组内拖拽 onReorderItem 生效', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ReaderAdvancedConfig? updated;
      await tester.pumpWidget(sheet(_config(), (v) => updated = v));
      await tester.pump();
      final list = tester.widget<ReorderableListView>(
        find.byKey(const ValueKey('select-menu-group-0')),
      );
      list.onReorderItem!(0, 2);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-menu-save')));
      await tester.pumpAndSettle();
      final primary = SelectionMenuConfig.decode(
        updated!.textSelectMenuConfig,
      ).view.primary.map((e) => e.id).toList();
      expect(primary.take(3), [
        SelectionMenuIds.share,
        SelectionMenuIds.browser,
        SelectionMenuIds.copy,
      ]);
    });

    testWidgets('恢复默认与取消不改动', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ReaderAdvancedConfig? updated;
      final cfg = _config(states: {SelectionMenuIds.copy: 2});
      await tester.pumpWidget(sheet(cfg, (v) => updated = v));
      await tester.pump();
      expect(find.text('已隐藏项目（1）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-menu-restore')));
      await tester.pump();
      expect(find.text('一级菜单（10）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-menu-cancel')));
      await tester.pumpAndSettle();
      expect(updated, isNull);
      expect(cfg.textSelectMenuConfig, isNot(''), reason: '原配置未被改写');
    });
  });

  testWidgets('阅读器 more「选择菜单」入口打开 Sheet', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReaderConfigPanel(
                config: _config(),
                section: ReaderConfigSection.more,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final entry = find.byKey(const ValueKey('reader-select-menu-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('select-menu-config-sheet')),
      findsOneWidget,
    );
  });
}
