import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'dict_state.dart';

export 'dict_state.dart';

/// 字典查询页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 在线词典规则经 BookApi.getConfig/setConfig 持久化到 Rust 配置库，键 `dict_rules`，
///   不再使用 SharedPreferences。
/// - 本地内置词典为静态占位数据，真实词典查询待 Rust 契约（见 API_CONTRACT.md 待办）。
/// - 在线跳转仅为 URL 构造，规则 CRUD 透传。
class DictNotifier extends Notifier<DictState> {
  /// 配置键
  static const _configKey = 'dict_rules';

  /// 默认在线词典（首次使用时写入）
  static const _defaultRules = [
    DictRule(
      name: '有道词典',
      urlRule: 'https://dict.youdao.com/w/{{key}}',
    ),
    DictRule(
      name: '剑桥词典',
      urlRule:
          'https://dictionary.cambridge.org/dictionary/english-chinese-simplified/{{key}}',
    ),
  ];

  /// 内置本地词典（占位数据，待 Rust 词典契约替换）
  static const _localDict = <String, DictEntry>{
    'chapter': DictEntry(
      word: 'chapter',
      phonetic: '/ˈtʃæptə(r)/',
      definitions: ['n. 章，章节', 'n. （人生的）一段时期'],
    ),
    'novel': DictEntry(
      word: 'novel',
      phonetic: '/ˈnɒvl/',
      definitions: ['n. 长篇小说', 'adj. 新奇的，异常的'],
    ),
    'author': DictEntry(
      word: 'author',
      phonetic: '/ˈɔːθə(r)/',
      definitions: ['n. 作者，作家', 'v. 编写，创作'],
    ),
    'bookmark': DictEntry(
      word: 'bookmark',
      phonetic: '/ˈbʊkmɑːk/',
      definitions: ['n. 书签', 'v. 将…加入书签'],
    ),
    'library': DictEntry(
      word: 'library',
      phonetic: '/ˈlaɪbrəri/',
      definitions: ['n. 图书馆，藏书室', 'n. 文库，（软件）库'],
    ),
    'fiction': DictEntry(
      word: 'fiction',
      phonetic: '/ˈfɪkʃn/',
      definitions: ['n. 小说，虚构作品', 'n. 虚构，想象'],
    ),
    'prologue': DictEntry(
      word: 'prologue',
      phonetic: '/ˈprəʊlɒɡ/',
      definitions: ['n. 序言，开场白'],
    ),
    'epilogue': DictEntry(
      word: 'epilogue',
      phonetic: '/ˈepɪlɒɡ/',
      definitions: ['n. 结语，尾声'],
    ),
    'paragraph': DictEntry(
      word: 'paragraph',
      phonetic: '/ˈpærəɡrɑːf/',
      definitions: ['n. 段落', 'n. （报刊的）短讯'],
    ),
    'volume': DictEntry(
      word: 'volume',
      phonetic: '/ˈvɒljuːm/',
      definitions: ['n. 卷，册', 'n. 音量', 'n. 体积，容量'],
    ),
  };

  @override
  DictState build() => const DictState();

  /// 加载在线词典规则；无持久化数据时写入默认规则
  Future<void> loadRules() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final raw = await api.getConfig(_configKey);
      List<DictRule> rules;
      if (raw == null || raw.isEmpty) {
        rules = _defaultRules;
        await api.setConfig(_configKey, _encode(rules));
      } else {
        rules = _decode(raw);
      }
      state = state.copyWith(rules: rules, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 添加在线词典规则
  Future<void> addRule(DictRule rule) async {
    final rules = [...state.rules, rule];
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 删除指定下标的在线词典规则
  Future<void> deleteRule(int index) async {
    if (index < 0 || index >= state.rules.length) return;
    final rules = [...state.rules]..removeAt(index);
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 查询单词（本地内置词典）
  void lookup(String word) {
    final key = word.trim().toLowerCase();
    if (key.isEmpty) return;
    state = state.copyWith(queriedWord: key, result: _localDict[key]);
  }

  /// 持久化全量规则到 Rust 配置库
  Future<void> _persist(List<DictRule> rules) async {
    try {
      await ref.read(bookApiProvider).setConfig(_configKey, _encode(rules));
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  String _encode(List<DictRule> rules) =>
      jsonEncode(rules.map((r) => r.toJson()).toList());

  List<DictRule> _decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(DictRule.fromJson)
        .toList();
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 字典查询 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(dictNotifierProvider);
/// ref.read(dictNotifierProvider.notifier).loadRules();
/// ```
final dictNotifierProvider = NotifierProvider<DictNotifier, DictState>(
  DictNotifier.new,
);
