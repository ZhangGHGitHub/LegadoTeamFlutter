// [R42 阶段 2A | 2026-11-23] 角色卡管理对话框测试（契约 §2.56）
//
// 覆盖手动建档最小闭环的两条写链路：
// 1. 新增角色 → 调 `saveBookCharacter(profileJson)`，且 JSON 字段正确
//    （camelCase、`aliasesJson`/`tagsJson` 为 JSON 字符串、role 原值）；
// 2. 删除角色 → 调 `deleteBookCharacter(bookUrl, characterId)`。
//
// 对话框同时是「书籍编辑页角色入口」打开的载体，故此处直接挂载对话框本体。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import 'package:flutter_legado/src/widgets/character_manage_dialog.dart';

import '../mocks/mocks.dart';

Map<String, dynamic> characterJson({
  required String id,
  required String name,
  String role = '',
  List<String> tags = const [],
  List<String> aliases = const [],
}) => {
  'id': id,
  'bookUrl': 'https://src.com/book/current',
  'name': name,
  'aliasesJson': jsonEncode(aliases),
  'avatarUri': null,
  'tagsJson': jsonEncode(tags),
  'role': role,
  'personality': '',
  'summary': '',
  'status': 1,
  'updatedAt': 1000,
};

void main() {
  setUpAll(registerFallbacks);

  Widget wrap(MockRustApi api) => ProviderScope(
    overrides: [bookApiProvider.overrideWithValue(api)],
    child: MaterialApp(
      theme: AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.wh,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const CharacterManageDialog(
                  bookUrl: 'https://src.com/book/current',
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('新增角色：调 saveBookCharacter 且 JSON 参数正确', (tester) async {
    final api = MockRustApi();
    when(
      () => api.getBookCharacters(
        bookUrl: any(named: 'bookUrl'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => '[]');
    String? savedJson;
    when(
      () => api.saveBookCharacter(profileJson: any(named: 'profileJson')),
    ).thenAnswer((inv) async {
      savedJson = inv.namedArguments[#profileJson]! as String;
      return jsonEncode(characterJson(id: 'new-id', name: '林渊'));
    });
    when(
      () => api.deleteBookCharacter(
        bookUrl: any(named: 'bookUrl'),
        characterId: any(named: 'characterId'),
      ),
    ).thenAnswer((_) async => true);

    await tester.pumpWidget(wrap(api));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 空态提示
    expect(find.text('还没有人物档案'), findsOneWidget);

    // 打开新增表单
    await tester.tap(find.text('新增角色'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '角色名'), '林渊');
    await tester.enterText(find.widgetWithText(TextField, '别名'), '小渊、阿渊');
    await tester.enterText(find.widgetWithText(TextField, '标签'), '冷静|剑修');

    // 选择定位「男主」
    await tester.tap(find.text('未设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('男主').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 断言：确实调用了保存，且参数为契约要求的 camelCase JSON
    expect(savedJson, isNotNull, reason: '应调用 saveBookCharacter');
    final decoded = jsonDecode(savedJson!) as Map<String, dynamic>;
    expect(decoded['bookUrl'], 'https://src.com/book/current');
    expect(decoded['name'], '林渊');
    expect(decoded['role'], 'male_lead');
    expect(decoded['id'], '');
    expect(jsonDecode(decoded['aliasesJson'] as String), ['小渊', '阿渊']);
    expect(jsonDecode(decoded['tagsJson'] as String), ['冷静', '剑修']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除角色：确认后调 deleteBookCharacter(bookUrl, characterId)', (
    tester,
  ) async {
    final api = MockRustApi();
    when(
      () => api.getBookCharacters(
        bookUrl: any(named: 'bookUrl'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => jsonEncode([
        characterJson(
          id: 'del-id',
          name: '待删角色',
          role: 'female_lead',
          tags: ['温柔'],
        ),
      ]),
    );
    String? deletedBookUrl;
    String? deletedId;
    when(
      () => api.deleteBookCharacter(
        bookUrl: any(named: 'bookUrl'),
        characterId: any(named: 'characterId'),
      ),
    ).thenAnswer((inv) async {
      deletedBookUrl = inv.namedArguments[#bookUrl]! as String;
      deletedId = inv.namedArguments[#characterId]! as String;
      return true;
    });
    when(
      () => api.saveBookCharacter(profileJson: any(named: 'profileJson')),
    ).thenAnswer((_) async => '{}');

    await tester.pumpWidget(wrap(api));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 列表中已有角色
    expect(find.text('待删角色'), findsOneWidget);
    expect(find.text('女主 · 温柔'), findsOneWidget);

    // 点删除 → 确认
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除角色'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deletedBookUrl, 'https://src.com/book/current');
    expect(deletedId, 'del-id');
    expect(tester.takeException(), isNull);
  });
}
