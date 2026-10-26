import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/book_source.dart';
import '../../models/misc.dart';
import '../../models/rss_source.dart';
import '../../services/book_api.dart';
import '../../services/bridge_http.dart';
import '../../services/source_import_service.dart';
import '../providers.dart';
import 'association_state.dart';

export 'association_state.dart';

/// 关联导入 Riverpod Notifier
///
/// 对齐原版 BaseAssociationViewModel.importJson 流程：
/// - 加载内容（URL / 文件 / 剪贴板）→ JSON 解析 → 类型自动识别
/// - 拉取本地快照，逐条计算新/更新/已存在状态
/// - 确认导入按类型走真实 FFI（书源/RSS/TTS 批量；替换规则按名 upsert；字典/TXT 规则配置合并）
class AssociationNotifier extends Notifier<AssociationState> {
  @override
  AssociationState build() => const AssociationState();

  BookApi get _api => ref.read(bookApiProvider);

  /// 书源导入服务（逐条校验 + FFI 批量导入）
  SourceImportService get importService => SourceImportService(_api);

  // ===== 加载阶段（对应原版各 ImportXxxViewModel.importSource）=====

  /// 深链 / 扫码预填：设置 URL，有内容时自动拉取并解析
  Future<void> bootstrapFromDeepLink({
    ImportType? type,
    required String srcUrl,
  }) async {
    state = state.copyWith(
      urlInput: srcUrl,
      items: [],
      error: null,
      lastResult: null,
    );
    if (srcUrl.isNotEmpty) {
      await loadFromUrl(srcUrl, typeHint: type);
    }
  }

  /// 从 URL 加载（对应原版 importSource → httpGet）
  Future<void> loadFromUrl(String url, {ImportType? typeHint}) async {
    state = state.copyWith(isLoading: true, error: null, items: []);
    try {
      final response = await bridgeHttpGet(
        _api,
        url,
        timeout: const Duration(seconds: 30),
      );
      if (!response.isSuccess) {
        state = state.copyWith(
          error: 'HTTP 请求失败：状态码 ${response.statusCode}',
          isLoading: false,
        );
        return;
      }
      await _parseAndSet(response.body, typeHint);
    } catch (e) {
      final msg = e is BridgeError ? e.message : '$e';
      state = state.copyWith(error: '从 URL 加载失败：$msg', isLoading: false);
    }
  }

  /// 从文件加载
  Future<void> loadFromFile(String path, {ImportType? typeHint}) async {
    state = state.copyWith(isLoading: true, error: null, items: []);
    try {
      final file = File(path);
      if (!await file.exists()) {
        state = state.copyWith(error: '文件不存在：$path', isLoading: false);
        return;
      }
      final content = await file.readAsString(encoding: utf8);
      await _parseAndSet(content, typeHint);
    } catch (e) {
      final msg = e is BridgeError ? e.message : '$e';
      state = state.copyWith(error: '读取文件失败：$msg', isLoading: false);
    }
  }

  /// 从剪贴板加载（内容为 URL 时按 URL 拉取，否则直接解析）
  Future<void> loadFromClipboard({ImportType? typeHint}) async {
    state = state.copyWith(isLoading: true, error: null, items: []);
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text == null || text.trim().isEmpty) {
        state = state.copyWith(error: '剪贴板为空', isLoading: false);
        return;
      }
      final trimmed = text.trim();
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        state = state.copyWith(urlInput: trimmed);
        await loadFromUrl(trimmed, typeHint: typeHint);
        return;
      }
      await _parseAndSet(trimmed, typeHint);
    } catch (e) {
      final msg = e is BridgeError ? e.message : '$e';
      state = state.copyWith(error: '读取剪贴板失败：$msg', isLoading: false);
    }
  }

  /// 解析内容：JSON 解码 → 类型自动识别（原版 importJson 字段规则）→ 本地快照 → 条目列表
  Future<void> _parseAndSet(String content, ImportType? hint) async {
    final List<Map<String, dynamic>> maps;
    try {
      final decoded = jsonDecode(content);
      if (decoded is List) {
        maps = [
          for (final e in decoded)
            if (e is Map<String, dynamic>) Map<String, dynamic>.of(e),
        ];
      } else if (decoded is Map) {
        maps = [Map<String, dynamic>.from(decoded)];
      } else {
        state = state.copyWith(
          error: '格式错误：期望 JSON 数组或对象',
          isLoading: false,
        );
        return;
      }
    } on FormatException catch (e) {
      state = state.copyWith(error: 'JSON 解析错误：${e.message}', isLoading: false);
      return;
    }

    if (maps.isEmpty) {
      // 对应原版 successLiveData(0) → wrong_format
      state = state.copyWith(
        error: '格式错误，未解析到有效条目',
        items: [],
        isLoading: false,
      );
      return;
    }

    final type = hint ?? detectType(maps.first);
    if (type == null) {
      // 对应原版「格式不对」
      state = state.copyWith(error: '格式不对', isLoading: false);
      return;
    }

    // 高亮规则文件为 {type:"highlightRule", rules:[...]} 包装：候选项取 rules 数组
    final itemMaps =
        type == ImportType.highlightRule ? _highlightRuleEntryMaps(maps) : maps;
    if (itemMaps.isEmpty) {
      state = state.copyWith(
        error: '格式错误，未解析到有效条目',
        items: [],
        isLoading: false,
      );
      return;
    }

    // 本地快照用于新/更新判定；获取失败按空处理（不阻塞导入）
    final locals = await _fetchLocals(type);

    final items = [
      for (final m in itemMaps)
        AssociationItem(
          raw: m,
          name: type.nameFieldOf(m),
          group: type.groupFieldOf(m),
          comment: type.commentFieldOf(m),
          lastUpdateTime: type.lastUpdateTimeFieldOf(m) ?? 0,
          status: _statusOf(type, m, locals),
        ),
    ];

    state = state.copyWith(
      type: type,
      items: items,
      isLoading: false,
      error: null,
    );
  }

  /// 自动识别导入类型（对应原版 BaseAssociationViewModel.importJson 的字段规则）
  ///
  /// 顺序与原版逐条对齐：highlightRule（type 字段）→ 书源 → RSS 源 →
  /// 替换规则 → 主题 → 字典 → TXT 目录规则 → 自动任务（cron+script）→ HTTP TTS。
  /// 公开为静态方法便于单测直接覆盖字段规则。
  static ImportType? detectType(Map<String, dynamic> map) {
    if (map['type'] == 'highlightRule') return ImportType.highlightRule;
    if (map.containsKey('bookSourceUrl')) return ImportType.bookSource;
    if (map.containsKey('sourceUrl')) return ImportType.rssSource;
    if (map.containsKey('pattern')) return ImportType.replaceRule;
    if (map.containsKey('themeName')) return ImportType.theme;
    if (map.containsKey('showRule')) return ImportType.dictRule;
    if (map.containsKey('name') && map.containsKey('rule')) {
      return ImportType.txtTocRule;
    }
    if (map.containsKey('cron') && map.containsKey('script')) {
      return ImportType.autoTask;
    }
    if (map.containsKey('name') && map.containsKey('url')) {
      return ImportType.httpTts;
    }
    return null;
  }

  /// 高亮规则文件展开：取 rules 数组；兼容直接传入单条规则对象
  static List<Map<String, dynamic>> _highlightRuleEntryMaps(
    List<Map<String, dynamic>> maps,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final map in maps) {
      final rules = map['rules'];
      if (rules is List) {
        for (final e in rules) {
          if (e is Map<String, dynamic>) out.add(Map<String, dynamic>.of(e));
        }
      } else if (map.containsKey('uuid')) {
        out.add(Map<String, dynamic>.of(map));
      }
    }
    return out;
  }

  /// 拉取本地快照（按类型返回键值映射或列表；失败返回 null）
  Future<Object?> _fetchLocals(ImportType type) async {
    try {
      switch (type) {
        case ImportType.bookSource:
          final map = <String, BookSource>{};
          for (final s in await _api.getBookSources()) {
            map[s.bookSourceUrl] = s;
          }
          return map;
        case ImportType.rssSource:
          final map = <String, RssSource>{};
          for (final s in await _api.getRssSources()) {
            map[s.sourceUrl] = s;
          }
          return map;
        case ImportType.replaceRule:
          final map = <String, ReplaceRule>{};
          for (final r in await _api.getReplaceRules()) {
            map[r.name] = r;
          }
          return map;
        case ImportType.httpTts:
          final map = <String, HttpTts>{};
          for (final t in await _api.getHttpTts()) {
            map[t.name] = t;
          }
          return map;
        case ImportType.dictRule:
          return await _readConfigList('dict_rules');
        case ImportType.txtTocRule:
          return await _readConfigList('txt_toc_rules');
        case ImportType.highlightRule:
          return _decodeMapList(await _api.highlightRuleList());
        case ImportType.autoTask:
          return await _api.autoTaskListRules();
        case ImportType.theme:
          // Flutter 端无具名主题仓库，状态按 none 处理（默认全选）
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// 读取配置键中的 JSON 列表（失败返回空列表）
  Future<List<Map<String, dynamic>>> _readConfigList(String key) async {
    try {
      final raw = await _api.getConfig(key);
      return _decodeMapList(raw);
    } catch (_) {
      return const [];
    }
  }

  /// 解析 JSON 数组字符串为对象列表（容错：非法条目跳过）
  static List<Map<String, dynamic>> _decodeMapList(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'null') return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map<String, dynamic>) e,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 逐条计算状态（对应原版各对话框 tvSourceState 规则）
  ImportItemStatus _statusOf(
    ImportType type,
    Map<String, dynamic> item,
    Object? locals,
  ) {
    switch (type) {
      case ImportType.bookSource:
        // 按 URL 匹配；lastUpdateTime 更新 → 更新
        final url = item['bookSourceUrl']?.toString() ?? '';
        final local = (locals as Map<String, BookSource>?)?[url];
        if (local == null) return ImportItemStatus.isNew;
        final lu = type.lastUpdateTimeFieldOf(item);
        return ((lu ?? 0) > local.lastUpdateTime)
            ? ImportItemStatus.isUpdate
            : ImportItemStatus.exists;

      case ImportType.rssSource:
        // 按 URL 匹配；lastUpdateTime 更新 → 更新
        final url = item['sourceUrl']?.toString() ?? '';
        final local = (locals as Map<String, RssSource>?)?[url];
        if (local == null) return ImportItemStatus.isNew;
        final lu = type.lastUpdateTimeFieldOf(item);
        return ((lu ?? 0) > local.lastUpdateTime)
            ? ImportItemStatus.isUpdate
            : ImportItemStatus.exists;

      case ImportType.replaceRule:
        // 按名称匹配；pattern/replacement/isRegex/scope 任一不同 → 更新
        final name = item['name']?.toString() ?? '';
        final local = (locals as Map<String, ReplaceRule>?)?[name];
        if (local == null) return ImportItemStatus.isNew;
        bool eq(v, String localValue) =>
            (v?.toString() ?? '') == localValue;
        return !eq(item['pattern'], local.pattern) ||
                !eq(item['replacement'], local.replacement) ||
                !eq(item['isRegex'], _boolStr(local.isRegex)) ||
                !eq(item['scope'], local.scope ?? '')
            ? ImportItemStatus.isUpdate
            : ImportItemStatus.exists;

      case ImportType.theme:
        // 无本地快照 → none（默认全选）
        return ImportItemStatus.none;

      case ImportType.httpTts:
        // 按名称匹配；lastUpdateTime 更新 → 更新
        final name = item['name']?.toString() ?? '';
        final local = (locals as Map<String, HttpTts>?)?[name];
        if (local == null) return ImportItemStatus.isNew;
        final lu = type.lastUpdateTimeFieldOf(item);
        return ((lu ?? 0) > local.lastUpdateTime)
            ? ImportItemStatus.isUpdate
            : ImportItemStatus.exists;

      case ImportType.dictRule:
        // 仅新/已存在（无更新概念）
        final name = item['name']?.toString() ?? '';
        final exists = (locals as List<Map<String, dynamic>>?)
                ?.any((e) => e['name'] == name) ??
            false;
        return exists
            ? ImportItemStatus.exists
            : ImportItemStatus.isNew;

      case ImportType.txtTocRule:
        // 按名称匹配；rule/replacement/example 任一不同 → 更新
        final name = item['name']?.toString() ?? '';
        Map<String, dynamic>? local;
        final list = locals as List<Map<String, dynamic>>?;
        if (list != null) {
          for (final e in list) {
            if (e['name'] == name) {
              local = e;
              break;
            }
          }
        }
        if (local == null) return ImportItemStatus.isNew;
        String v(dynamic x) => x?.toString() ?? '';
        return v(item['rule']) != v(local['rule']) ||
                v(item['replacement']) != v(local['replacement']) ||
                v(item['example']) != v(local['example'])
            ? ImportItemStatus.isUpdate
            : ImportItemStatus.exists;

      case ImportType.highlightRule:
        // 按 uuid 匹配；规则内容任一字段不同 → 更新（对齐原版
        // compareImportedHighlightRules：忽略 id/order 后比较全字段）
        final uuid = (item['uuid']?.toString() ?? '').toLowerCase();
        Map<String, dynamic>? local;
        final ruleList = locals as List<Map<String, dynamic>>?;
        if (ruleList != null && uuid.isNotEmpty) {
          for (final e in ruleList) {
            if ((e['uuid']?.toString() ?? '').toLowerCase() == uuid) {
              local = e;
              break;
            }
          }
        }
        if (local == null) return ImportItemStatus.isNew;
        return isSameHighlightRule(item, local)
            ? ImportItemStatus.exists
            : ImportItemStatus.isUpdate;

      case ImportType.autoTask:
        // 按 id 匹配；任务配置任一字段不同 → 更新
        final id = item['id']?.toString() ?? '';
        Map<String, dynamic>? local;
        final taskList = locals as List<Map<String, dynamic>>?;
        if (taskList != null && id.isNotEmpty) {
          for (final e in taskList) {
            if ((e['id']?.toString() ?? '') == id) {
              local = e;
              break;
            }
          }
        }
        if (local == null) return ImportItemStatus.isNew;
        return _sameAutoTask(item, local)
            ? ImportItemStatus.exists
            : ImportItemStatus.isUpdate;
    }
  }

  /// 高亮规则内容比较（对齐原版 compareImportedHighlightRules：
  /// 排除 id/order 后逐字段比较；缺省布尔/数值按 Rust 契约默认值归一）
  ///
  /// P2-5：补齐 `timeoutMillisecond`（此前遗漏导致仅超时不同的规则被误判
  /// 为「已存在」而不导入）。
  static bool isSameHighlightRule(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    bool sameBool(String key, {required bool fallback}) =>
        _boolValue(a[key], fallback) == _boolValue(b[key], fallback);
    // 导入比较发生在归一之前：按 normalizeForRestore 口径先归一超时/样式
    int timeoutOf(Object? v) {
      final value = v is num ? v.toInt() : highlightRuleDefaultTimeoutMs;
      return value > 0 ? value : highlightRuleDefaultTimeoutMs;
    }

    String styleOf(Object? v) {
      final value = v?.toString() ?? '';
      return value.trim().isEmpty ? highlightRuleDefaultStyle : value;
    }

    return _text(a['name']) == _text(b['name']) &&
        _text(a['pattern']) == _text(b['pattern']) &&
        sameBool('isRegex', fallback: false) &&
        _text(a['scope']) == _text(b['scope']) &&
        sameBool('isEnabled', fallback: true) &&
        styleOf(a['style']) == styleOf(b['style']) &&
        timeoutOf(a['timeoutMillisecond']) == timeoutOf(b['timeoutMillisecond']) &&
        sameBool('applyToTitle', fallback: false) &&
        sameBool('applyToBody', fallback: true);
  }

  /// 自动任务配置比较（不含运行历史字段）
  static bool _sameAutoTask(Map<String, dynamic> a, Map<String, dynamic> b) {
    const fields = [
      'name',
      'cron',
      'script',
      'loginUrl',
      'loginUi',
      'loginCheckJs',
      'comment',
      'header',
      'jsLib',
      'concurrentRate',
    ];
    for (final f in fields) {
      if (_text(a[f]) != _text(b[f])) return false;
    }
    bool sameBool(String key) =>
        _boolValue(a[key], true) == _boolValue(b[key], true);
    return sameBool('enable') && sameBool('enabledCookieJar');
  }

  /// 文本归一（null → 空串）
  static String _text(Object? v) => v?.toString() ?? '';

  /// 布尔归一（缺失/非布尔按 [fallback]）
  static bool _boolValue(Object? v, bool fallback) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return fallback;
  }

  static String _boolStr(bool b) => b.toString();

  /// 结果汇总单位名（按类型区分，避免规则类导入显示「书源」）
  static String _unitName(ImportType type) => switch (type) {
        ImportType.bookSource => '书源',
        ImportType.rssSource => 'RSS 源',
        ImportType.replaceRule => '替换规则',
        ImportType.theme => '主题配置',
        ImportType.httpTts => 'HTTP TTS',
        ImportType.dictRule => '字典规则',
        ImportType.txtTocRule => 'TXT 目录规则',
        ImportType.highlightRule => '高亮规则',
        ImportType.autoTask => '自动任务',
      };

  // ===== 导入阶段（对应原版各 importSelect）=====

  /// 确认导入：[items] 为勾选行的原始 JSON（书源/替换规则的覆盖项由 UI 层先行应用）
  Future<ImportResult> confirmImport(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = switch (type) {
        ImportType.bookSource => await importService.importFromJson(
              jsonEncode(items),
            ),
        ImportType.rssSource => await _importRss(type, items),
        ImportType.replaceRule => await _importReplaceRules(type, items),
        ImportType.theme => await _importTheme(type, items),
        ImportType.httpTts => await _importHttpTts(type, items),
        ImportType.dictRule => await _importDictRules(type, items),
        ImportType.txtTocRule => await _importTxtTocRules(type, items),
        ImportType.highlightRule => await _importHighlightRules(type, items),
        ImportType.autoTask => await _importAutoTasks(type, items),
      };
      state = state.copyWith(lastResult: result, isLoading: false);
      return result;
    } catch (e) {
      final msg = e is BridgeError ? e.message : '$e';
      state = state.copyWith(isLoading: false, error: msg);
      return ImportResult(
        total: items.length,
        success: 0,
        failed: items.length,
        skipped: 0,
        errors: [msg],
        unit: _unitName(type),
      );
    }
  }

  /// 导入 RSS 源（FFI importRssSources 批量）
  Future<ImportResult> _importRss(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    final n = await _api.importRssSources(jsonEncode(items));
    return ImportResult(
      total: items.length,
      success: n.clamp(0, items.length),
      failed: items.length - n.clamp(0, items.length),
      skipped: 0,
      errors: const [],
      unit: _unitName(type),
    );
  }

  /// 导入替换规则（按名称 upsert，对应原版 importSelect）
  Future<ImportResult> _importReplaceRules(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    final locals = <String, ReplaceRule>{};
    try {
      for (final r in await _api.getReplaceRules()) {
        locals[r.name] = r;
      }
    } catch (_) {}
    var success = 0;
    final errors = <String>[];
    for (final item in items) {
      try {
        final rule = ReplaceRule.fromJson(item);
        if (rule.name.isEmpty) throw Exception('缺少名称');
        final local = locals[rule.name];
        if (local == null) {
          await _api.addReplaceRule(rule);
        } else {
          await _api.updateReplaceRule(rule.copyWith(id: local.id));
        }
        success++;
      } catch (e) {
        errors.add('导入替换规则「${item['name']}」失败：$e');
      }
    }
    return ImportResult(
      total: items.length,
      success: success,
      failed: errors.length,
      skipped: 0,
      errors: errors,
      unit: _unitName(type),
    );
  }

  /// 导入主题配置（写入 SharedPreferences，沿用既有映射）
  Future<ImportResult> _importTheme(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    var success = 0;
    final errors = <String>[];
    for (final item in items) {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (item.containsKey('themeMode')) {
          await prefs.setString(
            'app_theme_mode',
            item['themeMode']?.toString() ?? 'system',
          );
        }
        if (item.containsKey('fontSize')) {
          final size = (item['fontSize'] as num?)?.toDouble();
          if (size != null && size > 0) {
            await prefs.setDouble('reader_font_size', size);
          }
        }
        if (item.containsKey('lineHeight')) {
          final height = (item['lineHeight'] as num?)?.toDouble();
          if (height != null && height > 0) {
            await prefs.setDouble('reader_line_height', height);
          }
        }
        if (item.containsKey('bgColorIndex')) {
          final index = (item['bgColorIndex'] as num?)?.toInt();
          if (index != null && index >= 0) {
            await prefs.setInt('reader_bg_color_index', index);
          }
        }
        if (item.containsKey('brightness')) {
          final brightness = (item['brightness'] as num?)?.toDouble();
          if (brightness != null) {
            await prefs.setDouble('reader_brightness', brightness);
          }
        }
        success++;
      } catch (e) {
        errors.add('导入主题配置失败：$e');
      }
    }
    return ImportResult(
      total: items.length,
      success: success,
      failed: errors.length,
      skipped: 0,
      errors: errors,
      unit: _unitName(type),
    );
  }

  /// 导入 HTTP TTS（FFI importHttpTts 批量）
  Future<ImportResult> _importHttpTts(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    final n = await _api.importHttpTts(jsonEncode(items));
    return ImportResult(
      total: items.length,
      success: n.clamp(0, items.length),
      failed: items.length - n.clamp(0, items.length),
      skipped: 0,
      errors: const [],
      unit: _unitName(type),
    );
  }

  /// 导入字典规则（按名称 upsert 合并写入配置键 dict_rules）
  Future<ImportResult> _importDictRules(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    final existing = await _readConfigList('dict_rules');
    var success = 0;
    final errors = <String>[];
    for (final item in items) {
      try {
        final rule = DictRule.fromJson(item);
        if (rule.name.isEmpty) throw Exception('缺少名称');
        final idx = existing.indexWhere((e) => e['name'] == rule.name);
        if (idx >= 0) {
          existing[idx] = rule.toJson(); // 同名覆盖（对应原版 importSelect）
        } else {
          existing.add(rule.toJson());
        }
        success++;
      } catch (e) {
        errors.add('导入字典规则「${item['name']}」失败：$e');
      }
    }
    await _api.setConfig('dict_rules', jsonEncode(existing));
    return ImportResult(
      total: items.length,
      success: success,
      failed: errors.length,
      skipped: 0,
      errors: errors,
      unit: _unitName(type),
    );
  }

  /// 导入 TXT 目录规则（按名称 upsert 合并写入配置键 txt_toc_rules）
  Future<ImportResult> _importTxtTocRules(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    final existing = await _readConfigList('txt_toc_rules');
    var nextId = existing.fold<int>(
      0,
      (m, e) => ((e['id'] as num?)?.toInt() ?? 0) > m
          ? (e['id'] as num).toInt()
          : m,
    );
    var success = 0;
    final errors = <String>[];
    for (final item in items) {
      try {
        var rule = TxtTocRule.fromJson(item);
        if (rule.name.isEmpty || rule.rule.isEmpty) {
          throw Exception('缺少名称或正则');
        }
        final idx = existing.indexWhere((e) => e['name'] == rule.name);
        if (idx >= 0) {
          rule = rule.copyWith(id: (existing[idx]['id'] as num?)?.toInt() ?? 1);
          existing[idx] = rule.toJson(); // 同名覆盖（对应原版 importSelect）
        } else {
          if (rule.id <= 0) nextId++;
          rule = rule.copyWith(
            id: rule.id > 0 ? rule.id : nextId++,
            serialNumber: existing.length,
          );
          existing.add(rule.toJson());
        }
        success++;
      } catch (e) {
        errors.add('导入 TXT 规则「${item['name']}」失败：$e');
      }
    }
    await _api.setConfig('txt_toc_rules', jsonEncode(existing));
    return ImportResult(
      total: items.length,
      success: success,
      failed: errors.length,
      skipped: 0,
      errors: errors,
      unit: _unitName(type),
    );
  }

  /// 高亮规则默认超时（对齐 Kotlin `HighlightRule.DEFAULT_TIMEOUT_MILLISECONDS`）
  static const int highlightRuleDefaultTimeoutMs = 3000;

  /// 空白 style 的默认样式（对齐 Kotlin `HighlightStyle()` 的 Gson 序列化形态）
  static const String highlightRuleDefaultStyle =
      '{"fill":0,"textColor":0,"bold":false,"italic":false,"fontPath":""}';

  /// 标准 UUID 形态（8-4-4-4-12；大小写不敏感，归一小写）
  static final RegExp _canonicalUuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// 导入 uuid 归一（对齐原版 `UUID.fromString(raw).toString() == raw` 语义：
  /// 只接受标准形态并归一小写；非法形态明确抛错，不静默改写身份）。
  static String normalizeHighlightRuleUuid(Object? raw) {
    final text = (raw?.toString() ?? '').trim();
    if (!_canonicalUuidPattern.hasMatch(text)) {
      throw const FormatException('uuid 非法');
    }
    return text.toLowerCase();
  }

  /// 单条高亮规则导入前归一（对齐 Kotlin
  /// `HighlightRule.normalizeForRestore` + `isValid`）：
  /// - uuid 归一（非法明确报错）；
  /// - scope 空白 → null；
  /// - timeoutMillisecond <= 0 → 3000；
  /// - style 空白 → 默认样式 JSON；
  /// - pattern 为空或 isRegex 时正则不可编译 → 报错。
  static Map<String, dynamic> normalizeHighlightRuleForImport(
    Map<String, dynamic> item,
  ) {
    final rule = Map<String, dynamic>.of(item);
    rule['uuid'] = normalizeHighlightRuleUuid(rule['uuid']);
    // 原版导出字段为 order；合并阶段统一写入 Rust 契约字段 sortOrder
    rule.remove('order');

    final scope = (rule['scope']?.toString() ?? '').trim();
    if (scope.isEmpty) {
      rule.remove('scope'); // Rust Option<String>：缺省与 null 等价
    } else {
      rule['scope'] = scope;
    }

    final timeout = rule['timeoutMillisecond'] is num
        ? (rule['timeoutMillisecond'] as num).toInt()
        : 0;
    rule['timeoutMillisecond'] =
        timeout > 0 ? timeout : highlightRuleDefaultTimeoutMs;

    if ((rule['style']?.toString() ?? '').trim().isEmpty) {
      rule['style'] = highlightRuleDefaultStyle;
    }

    final pattern = rule['pattern']?.toString() ?? '';
    if (pattern.isEmpty) {
      throw const FormatException('匹配模式为空');
    }
    if (_boolValue(rule['isRegex'], false)) {
      try {
        RegExp(pattern);
      } on FormatException {
        throw FormatException('正则表达式无效: $pattern');
      }
    }
    return rule;
  }

  /// 合并导入高亮规则（对齐 Kotlin `mergeImportedHighlightRules`）：
  /// 本地顺序在前（同 uuid 用导入内容覆盖、保留本地 id），新规则按导入顺序
  /// 追加并清空 id，最后按合并顺序重排 `sortOrder`。
  static List<Map<String, dynamic>> mergeHighlightRulesForImport(
    List<Map<String, dynamic>> localRules,
    List<Map<String, dynamic>> importedRules,
  ) {
    final importedByUuid = <String, Map<String, dynamic>>{
      for (final rule in importedRules)
        (rule['uuid']?.toString() ?? '').toLowerCase(): rule,
    };
    final localUuids = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final local in localRules) {
      final localUuid = (local['uuid']?.toString() ?? '').toLowerCase();
      if (localUuid.isNotEmpty) localUuids.add(localUuid);
      final incoming = importedByUuid[localUuid];
      if (incoming != null) {
        merged.add(Map<String, dynamic>.of(incoming)..['id'] = local['id']);
      } else {
        merged.add(Map<String, dynamic>.of(local));
      }
    }
    for (final imported in importedRules) {
      final uuid = (imported['uuid']?.toString() ?? '').toLowerCase();
      if (!localUuids.contains(uuid)) {
        merged.add(Map<String, dynamic>.of(imported)..remove('id'));
      }
    }
    for (var i = 0; i < merged.length; i++) {
      merged[i]['sortOrder'] = i;
    }
    return merged;
  }

  /// 导入高亮规则（按 uuid 命中本地同条则覆盖 id，否则新增）
  ///
  /// 对齐原版 `HighlightRuleDao.importRules`：uuid 为规则身份；id 为本地
  /// 自增主键，导入时不得沿用来源设备的 id（否则会覆盖无关本地规则）。
  /// P2-5：导入前归一（uuid/超时/样式/正则可编译）、去重、合并后按序重排
  /// `sortOrder`。
  Future<ImportResult> _importHighlightRules(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    var localRules = <Map<String, dynamic>>[];
    try {
      localRules = _decodeMapList(await _api.highlightRuleList());
    } catch (_) {
      // 本地快照不可用时全部按新增处理
    }

    final imported = <Map<String, dynamic>>[];
    final seenUuids = <String>{};
    final errors = <String>[];
    for (final item in items) {
      final name = item['name']?.toString() ?? '';
      try {
        final rule = normalizeHighlightRuleForImport(item);
        final uuid = rule['uuid'] as String;
        if (!seenUuids.add(uuid)) {
          throw const FormatException('uuid 重复');
        }
        imported.add(rule);
      } catch (e) {
        errors.add('导入高亮规则「$name」失败：$e');
      }
    }

    var success = 0;
    if (imported.isNotEmpty) {
      final merged = mergeHighlightRulesForImport(localRules, imported);
      try {
        for (final rule in merged) {
          await _api.highlightRuleSave(ruleJson: jsonEncode(rule));
          final uuid = (rule['uuid']?.toString() ?? '').toLowerCase();
          if (seenUuids.contains(uuid)) success++;
        }
      } catch (e) {
        errors.add('写入高亮规则失败：$e');
      }
    }

    return ImportResult(
      total: items.length,
      success: success,
      failed: items.length - success,
      skipped: 0,
      errors: errors,
      unit: _unitName(type),
    );
  }

  /// 自动任务默认 cron（对齐 Kotlin `AutoTask.DEFAULT_CRON`）
  static const String autoTaskDefaultCron = '*/30 * * * *';

  /// 导入自动任务（FFI 合并本地运行时状态后逐条创建）
  ///
  /// 对齐原版 `ImportAutoTaskViewModel.importSelect` + `validateImportedTask`：
  /// - P2-3：调用 FFI **前**预生成缺失 id（Rust 合并会跳过空 id 条目，混合批
  ///   此前会静默丢条目）；
  /// - P2-4：cron 空白回退默认值、不可解析报错；script 归一后为空报错；
  /// - 名称空白剔除并记入失败明细。
  Future<ImportResult> _importAutoTasks(
    ImportType type,
    List<Map<String, dynamic>> items,
  ) async {
    final baseId = DateTime.now().microsecondsSinceEpoch;
    final errors = <String>[];
    final normalized = <Map<String, dynamic>>[];
    for (var i = 0; i < items.length; i++) {
      final task = Map<String, dynamic>.of(items[i]);
      final name = (task['name']?.toString() ?? '').trim();
      if (name.isEmpty) {
        errors.add('导入自动任务失败：缺少任务名称');
        continue;
      }
      task['name'] = name;

      // P2-3：FFI 合并按 id 索引，缺 id 条目会被丢弃 → 先补齐
      if ((task['id']?.toString() ?? '').trim().isEmpty) {
        task['id'] = '${baseId}_$i';
      }

      // P2-4：cron 空白回退默认值，不可解析明确失败
      final cron = (task['cron']?.toString() ?? '').trim();
      final effectiveCron = cron.isEmpty ? autoTaskDefaultCron : cron;
      task['cron'] = effectiveCron;
      final due = await _api.autoTaskNextDueAt(
        cron: effectiveCron,
        fromMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (due < 0) {
        errors.add('导入自动任务「$name」失败：请输入有效的五段 Cron 计划');
        continue;
      }

      // P2-4：script 非空校验（先按原版口径剥离 @js:/<js> 包裹）
      final rawScript = task['script']?.toString() ?? '';
      final normalizedScript =
          await _api.autoTaskNormalizeScript(script: rawScript);
      if (normalizedScript.trim().isEmpty) {
        errors.add('导入自动任务「$name」失败：请输入 JavaScript 任务脚本');
        continue;
      }
      task['script'] = normalizedScript;
      normalized.add(task);
    }

    var merged = normalized;
    if (normalized.isNotEmpty) {
      try {
        final locals = await _api.autoTaskListRules();
        final prepared = await _api.autoTaskPrepareImported(
          localTasksJson: jsonEncode(locals),
          importedJson: jsonEncode(normalized),
        );
        if (prepared.isNotEmpty) merged = prepared;
      } catch (_) {
        // FFI 合并不可用时退化为按原样导入
      }
    }

    var success = 0;
    for (var i = 0; i < merged.length; i++) {
      final task = Map<String, dynamic>.of(merged[i]);
      // 防御：合并结果仍缺 id 时补齐（不静默丢条目）
      if ((task['id']?.toString() ?? '').trim().isEmpty) {
        task['id'] = '${baseId}_m$i';
      }
      try {
        await _api.autoTaskCreateRule(ruleJson: jsonEncode(task));
        success++;
      } catch (e) {
        errors.add('导入自动任务「${task['name']}」失败：$e');
      }
    }

    return ImportResult(
      total: items.length,
      success: success,
      failed: items.length - success,
      skipped: 0,
      errors: errors,
      unit: _unitName(type),
    );
  }

  // ===== 其他操作 =====

  /// 设置 URL 输入
  void setUrlInput(String url) {
    state = state.copyWith(urlInput: url);
  }

  /// 重置到初始状态
  void reset() {
    state = const AssociationState();
  }
}

/// 关联导入 Notifier 全局 Provider
final associationNotifierProvider =
    NotifierProvider<AssociationNotifier, AssociationState>(
  AssociationNotifier.new,
);
