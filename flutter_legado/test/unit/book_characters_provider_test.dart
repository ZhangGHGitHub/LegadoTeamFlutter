// [R42 阶段 2A | 2026-11-23] 角色卡 Provider 单元测试（契约 §2.56）
//
// 覆盖 JSON 解析与降级的边界：Rust 返回**裸 JSON 数组**（camelCase 键），
// `aliasesJson` / `tagsJson` 是**JSON 数组字符串**（原样存取），必须在此层
// 解析为 `List<String>`，UI 不碰 JSON。
//
// 排序口径（参考版 `BookInfoViewModel:1892-1897`）：roleOrder
// 男主 0 / 女主 1 / 男配 2 / 女配 3 / 其他 99，**稳定排序**。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/book_info/characters_provider.dart';

/// 单条角色 JSON（Rust serde camelCase）
Map<String, dynamic> characterJson({
  required String id,
  required String name,
  String role = '',
  List<String> tags = const [],
  List<String> aliases = const [],
  String? avatarUri,
  String personality = '',
  String summary = '',
  int updatedAt = 0,
}) => {
  'id': id,
  'bookUrl': 'https://src.com/book/current',
  'name': name,
  'aliasesJson': jsonEncode(aliases),
  'avatarUri': avatarUri,
  'tagsJson': jsonEncode(tags),
  'role': role,
  'personality': personality,
  'summary': summary,
  'status': 1,
  'source': 'user',
  'confidence': 1.0,
  'schemaVersion': 1,
  'createdAt': 1000,
  'updatedAt': updatedAt,
};

void main() {
  group('parseBookCharactersJson', () {
    test('解析两个角色：字段映射 + 角色中文 + tags 竖线拼接', () {
      final raw = jsonEncode([
        characterJson(
          id: 'c1',
          name: '林渊',
          role: 'male_lead',
          tags: ['冷静', '剑修'],
          aliases: ['小渊'],
          personality: '沉稳',
          summary: '主角',
          updatedAt: 2000,
        ),
        characterJson(
          id: 'c2',
          name: '苏雪',
          role: 'female_lead',
          tags: ['温柔'],
          updatedAt: 1000,
        ),
      ]);

      final characters = parseBookCharactersJson(raw);
      expect(characters, hasLength(2));

      final first = characters[0];
      expect(first.id, 'c1');
      expect(first.name, '林渊');
      expect(first.role, 'male_lead');
      expect(first.roleLabel, '男主');
      expect(first.aliases, ['小渊']);
      expect(first.tags, ['冷静', '剑修']);
      expect(first.tagsText, '冷静 | 剑修');
      // 卡片不渲染但模型保留（编辑页回显用）
      expect(first.personality, '沉稳');
      expect(first.summary, '主角');
      expect(first.avatarUri, isNull);

      expect(characters[1].roleLabel, '女主');
      expect(characters[1].tagsText, '温柔');
    });

    test('排序：男主 → 女主 → 男配 → 女配 → 其他（同权重保持原序）', () {
      final raw = jsonEncode([
        characterJson(id: 'a', name: '路人甲', role: '', updatedAt: 9000),
        characterJson(id: 'b', name: '女配乙', role: 'female_supporting'),
        characterJson(id: 'c', name: '男主丙', role: 'male_lead'),
        characterJson(id: 'd', name: '男配丁', role: 'male_supporting'),
        characterJson(id: 'e', name: '女主戊', role: 'female_lead'),
        characterJson(id: 'f', name: '路人己', role: 'unknown_role'),
      ]);

      final names = [for (final c in parseBookCharactersJson(raw)) c.name];
      expect(names, ['男主丙', '女主戊', '男配丁', '女配乙', '路人甲', '路人己']);
    });

    test('空 role → roleLabel 为空串（UI 不渲染该行）', () {
      final raw = jsonEncode([characterJson(id: 'x', name: '无名氏')]);
      expect(parseBookCharactersJson(raw).single.roleLabel, '');
      expect(parseBookCharactersJson(raw).single.tagsText, '');
    });

    test('无名角色被跳过，其余保留', () {
      final raw = jsonEncode([
        characterJson(id: 'x', name: ''),
        characterJson(id: 'y', name: '有名字'),
      ]);
      final characters = parseBookCharactersJson(raw);
      expect(characters, hasLength(1));
      expect(characters.single.name, '有名字');
    });

    test('数组字段非法 / 非字符串元素一律容错（不抛错）', () {
      final raw = jsonEncode([
        {
          'id': 'x',
          'bookUrl': 'b',
          'name': '角色',
          'aliasesJson': 'not json',
          'tagsJson': '{"a":1}',
        },
        {
          'id': 'y',
          'bookUrl': 'b',
          'name': '角色二',
          'aliasesJson': jsonEncode([1, null, '  ', '别名']),
          'tagsJson': jsonEncode(['标签']),
        },
      ]);
      final characters = parseBookCharactersJson(raw);
      expect(characters[0].aliases, isEmpty);
      expect(characters[0].tags, isEmpty);
      expect(characters[1].aliases, ['1', '别名']);
      expect(characters[1].tags, ['标签']);
    });

    test('空数组 / 非法 JSON / 结构不符一律返回空列表（不抛错）', () {
      expect(parseBookCharactersJson('[]'), isEmpty);
      expect(parseBookCharactersJson(''), isEmpty);
      expect(parseBookCharactersJson('not json'), isEmpty);
      expect(parseBookCharactersJson('{"characters":[]}'), isEmpty);
      expect(parseBookCharactersJson('[1,2,3]'), isEmpty);
      expect(parseBookCharactersJson('null'), isEmpty);
    });
  });

  group('BookCharacter.toProfileJson', () {
    test('产出 camelCase 键，数组字段序列化为 JSON 字符串', () {
      const character = BookCharacter(
        id: 'c1',
        bookUrl: 'https://src.com/book/current',
        name: '林渊',
        aliases: ['小渊'],
        tags: ['冷静', '剑修'],
        role: 'male_lead',
        personality: '沉稳',
        summary: '主角',
      );

      final json = character.toProfileJson();
      expect(json['id'], 'c1');
      expect(json['bookUrl'], 'https://src.com/book/current');
      expect(json['name'], '林渊');
      expect(json['role'], 'male_lead');
      expect(json['personality'], '沉稳');
      expect(json['summary'], '主角');
      expect(json['avatarUri'], isNull);
      expect(json['aliasesJson'], jsonEncode(['小渊']));
      expect(json['tagsJson'], jsonEncode(['冷静', '剑修']));
      expect(json['status'], 1);
    });

    test('往返：toProfileJson 的数组字段能被 parseBookCharactersJson 还原', () {
      const character = BookCharacter(
        id: 'c9',
        bookUrl: 'b',
        name: '往返',
        aliases: ['甲', '乙'],
        tags: ['标签一'],
        role: 'female_supporting',
      );
      final roundTrip = parseBookCharactersJson(
        jsonEncode([character.toProfileJson()]),
      ).single;
      expect(roundTrip.aliases, ['甲', '乙']);
      expect(roundTrip.tags, ['标签一']);
      expect(roundTrip.roleLabel, '女配');
      expect(roundTrip, character);
    });
  });
}
