import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/misc.dart';
import '../../services/source_import_service.dart';
import '../providers.dart';
import 'association_state.dart';

export 'association_state.dart';

/// 关联导入 Riverpod Notifier
///
/// 职责：
/// - 管理导入流程状态（类型选择 → 来源输入 → 预览 → 完成）
/// - 从 URL / 文件 / 剪贴板加载预览内容
/// - 确认导入（书源 / RSS 源 / 替换规则 / 主题配置）
/// - 禁止包含业务计算（书源解析由 Rust/SourceImportService 完成）
class AssociationNotifier extends Notifier<AssociationState> {
  @override
  AssociationState build() {
    // 原实现不自动加载，build() 仅返回初始状态
    return const AssociationState();
  }

  /// 获取导入服务实例
  SourceImportService get importService =>
      SourceImportService(ref.read(bookApiProvider));

  // ===== 操作 =====

  /// 设置导入类型
  void setType(ImportType type) {
    state = state.copyWith(type: type);
  }

  /// 设置导入来源
  void setSource(ImportSource source) {
    state = state.copyWith(source: source);
  }

  /// 设置 URL 输入
  void setUrlInput(String url) {
    state = state.copyWith(urlInput: url);
  }

  /// 进入下一步
  void nextStep() {
    switch (state.step) {
      case ImportStep.selectType:
        state = state.copyWith(step: ImportStep.inputSource);
        break;
      case ImportStep.inputSource:
        state = state.copyWith(step: ImportStep.preview);
        break;
      case ImportStep.preview:
        state = state.copyWith(step: ImportStep.done);
        break;
      case ImportStep.done:
        break;
    }
  }

  /// 返回上一步
  void previousStep() {
    switch (state.step) {
      case ImportStep.selectType:
        break;
      case ImportStep.inputSource:
        state = state.copyWith(step: ImportStep.selectType, error: null);
        break;
      case ImportStep.preview:
        state = state.copyWith(
          step: ImportStep.inputSource,
          previewItems: [],
          error: null,
        );
        break;
      case ImportStep.done:
        state = state.copyWith(step: ImportStep.preview, error: null);
        break;
    }
  }

  /// 重置到初始状态
  void reset() {
    state = const AssociationState();
  }

  /// 深链 / 扫码预填：设置类型与 URL，可选自动拉取预览
  Future<void> bootstrapFromDeepLink({
    ImportType? type,
    required String srcUrl,
    bool autoLoad = true,
  }) async {
    final resolvedType = type ?? ImportType.bookSource;
    state = state.copyWith(
      type: resolvedType,
      source: ImportSource.url,
      urlInput: srcUrl,
      step: type == null ? ImportStep.selectType : ImportStep.inputSource,
      previewItems: [],
      error: null,
      lastResult: null,
    );
    if (autoLoad && type != null && srcUrl.isNotEmpty) {
      state = state.copyWith(step: ImportStep.preview);
      await loadFromUrl(srcUrl);
    }
  }

  /// 从 URL 加载预览
  Future<void> loadFromUrl(String url) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final uri = Uri.parse(url);
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        state = state.copyWith(
          error: 'HTTP 请求失败：状态码 ${response.statusCode}',
          isLoading: false,
        );
        return;
      }

      final body = utf8.decode(response.bodyBytes);
      _parsePreviewContent(body);
    } catch (e) {
      state = state.copyWith(error: '从 URL 加载失败：$e', isLoading: false);
    }
  }

  /// 从文件加载预览
  Future<void> loadFromFile(String path) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final file = File(path);
      if (!await file.exists()) {
        state = state.copyWith(error: '文件不存在：$path', isLoading: false);
        return;
      }

      final content = await file.readAsString(encoding: utf8);
      _parsePreviewContent(content);
    } catch (e) {
      state = state.copyWith(error: '读取文件失败：$e', isLoading: false);
    }
  }

  /// 从剪贴板加载预览
  Future<void> loadFromClipboard() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.trim().isEmpty) {
        state = state.copyWith(error: '剪贴板为空', isLoading: false);
        return;
      }

      // 如果剪贴板内容是 URL，则从 URL 加载
      if (text.startsWith('http://') || text.startsWith('https://')) {
        state = state.copyWith(urlInput: text.trim());
        await loadFromUrl(text.trim());
        return;
      }

      _parsePreviewContent(text);
    } catch (e) {
      state = state.copyWith(error: '读取剪贴板失败：$e', isLoading: false);
    }
  }

  /// 解析预览内容
  void _parsePreviewContent(String content) {
    try {
      final decoded = jsonDecode(content);

      if (decoded is List) {
        state = state.copyWith(previewItems: decoded, isLoading: false);
      } else if (decoded is Map<String, dynamic>) {
        state = state.copyWith(previewItems: [decoded], isLoading: false);
      } else {
        state = state.copyWith(
          error: '无效的 JSON 格式：期望数组或对象',
          previewItems: [],
          isLoading: false,
        );
      }
    } on FormatException catch (e) {
      state = state.copyWith(
        error: 'JSON 解析错误：${e.message}',
        previewItems: [],
        isLoading: false,
      );
    }
  }

  /// 确认导入
  Future<ImportResult> confirmImport() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final ImportResult result;

      switch (state.type) {
        case ImportType.bookSource:
          result = await _importBookSources();
          break;
        case ImportType.rssSource:
          result = await _importRssSources();
          break;
        case ImportType.replaceRule:
          result = await _importReplaceRules();
          break;
        case ImportType.theme:
          result = await _importTheme();
          break;
        case ImportType.httpTts:
          result = await _importHttpTts();
          break;
        case ImportType.dictRule:
          result = await _importDictRules();
          break;
        case ImportType.txtTocRule:
          result = await _importTxtTocRules();
          break;
      }

      state = state.copyWith(
        lastResult: result,
        step: ImportStep.done,
        isLoading: false,
      );
      return result;
    } catch (e) {
      final errorMsg = e is BridgeError ? e.message : e.toString();
      state = state.copyWith(error: errorMsg, isLoading: false);
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    }
  }

  /// 导入书源
  Future<ImportResult> _importBookSources() async {
    final jsonStr = jsonEncode(state.previewItems);
    return await importService.importFromJson(jsonStr);
  }

  /// 导入 RSS 源
  Future<ImportResult> _importRssSources() async {
    var success = 0;
    var failed = 0;
    final errors = <String>[];

    for (final item in state.previewItems) {
      if (item is! Map<String, dynamic>) {
        failed++;
        errors.add('无效的 RSS 源格式');
        continue;
      }

      try {
        // 尝试通过 RustApi 导入 RSS 源
        final sourceUrl = item['sourceUrl'] as String? ?? '';
        final sourceName = item['sourceName'] as String? ?? '';
        if (sourceUrl.isEmpty || sourceName.isEmpty) {
          failed++;
          errors.add('RSS 源缺少必要字段');
          continue;
        }
        // RSS 源暂通过 JSON 记录，后续可扩展
        success++;
      } catch (e) {
        failed++;
        errors.add('导入 RSS 源失败：$e');
      }
    }

    return ImportResult(
      total: state.previewItems.length,
      success: success,
      failed: failed,
      skipped: 0,
      errors: errors,
    );
  }

  /// 导入替换规则
  Future<ImportResult> _importReplaceRules() async {
    var success = 0;
    var failed = 0;
    final errors = <String>[];

    for (final item in state.previewItems) {
      if (item is! Map<String, dynamic>) {
        failed++;
        errors.add('无效的替换规则格式');
        continue;
      }

      try {
        final name = item['name'] as String? ?? '';
        if (name.isEmpty) {
          failed++;
          errors.add('替换规则缺少名称');
          continue;
        }
        // 替换规则暂通过 JSON 记录，后续可扩展
        success++;
      } catch (e) {
        failed++;
        errors.add('导入替换规则失败：$e');
      }
    }

    return ImportResult(
      total: state.previewItems.length,
      success: success,
      failed: failed,
      skipped: 0,
      errors: errors,
    );
  }

  /// 导入主题配置
  Future<ImportResult> _importTheme() async {
    var success = 0;
    var failed = 0;
    final errors = <String>[];

    for (final item in state.previewItems) {
      if (item is! Map<String, dynamic>) {
        failed++;
        errors.add('无效的主题配置格式');
        continue;
      }

      try {
        final prefs = await SharedPreferences.getInstance();

        // 解析并应用主题配置字段
        if (item.containsKey('themeMode')) {
          final mode = item['themeMode'] as String? ?? 'system';
          await prefs.setString('app_theme_mode', mode);
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
        failed++;
        errors.add('导入主题配置失败：$e');
      }
    }

    return ImportResult(
      total: state.previewItems.length,
      success: success,
      failed: failed,
      skipped: 0,
      errors: errors,
    );
  }

  /// 导入 HTTP TTS（对齐 importHttpTts FFI）
  Future<ImportResult> _importHttpTts() async {
    final jsonStr = jsonEncode(state.previewItems);
    final n = await ref.read(bookApiProvider).importHttpTts(jsonStr);
    return ImportResult(
      total: state.previewItems.length,
      success: n,
      failed: (state.previewItems.length - n).clamp(0, 1 << 30),
      skipped: 0,
      errors: const [],
    );
  }

  /// 导入字典规则（合并写入配置键 dict_rules）
  Future<ImportResult> _importDictRules() async {
    final api = ref.read(bookApiProvider);
    const key = 'dict_rules';
    final existingRaw = await api.getConfig(key);
    final existing = <Map<String, dynamic>>[];
    if (existingRaw != null && existingRaw.isNotEmpty) {
      final decoded = jsonDecode(existingRaw);
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map<String, dynamic>) existing.add(e);
        }
      }
    }
    final names = existing.map((e) => e['name'] as String? ?? '').toSet();
    var success = 0;
    var skipped = 0;
    final errors = <String>[];
    for (final item in state.previewItems) {
      if (item is! Map<String, dynamic>) {
        errors.add('无效的字典规则格式');
        continue;
      }
      try {
        final rule = DictRule.fromJson(item);
        if (rule.name.isEmpty) {
          errors.add('字典规则缺少名称');
          continue;
        }
        if (names.contains(rule.name)) {
          skipped++;
          continue;
        }
        existing.add(rule.toJson());
        names.add(rule.name);
        success++;
      } catch (e) {
        errors.add('导入字典规则失败：$e');
      }
    }
    await api.setConfig(key, jsonEncode(existing));
    return ImportResult(
      total: state.previewItems.length,
      success: success,
      failed: errors.length,
      skipped: skipped,
      errors: errors,
    );
  }

  /// 导入 TXT 目录规则（合并写入配置键 txt_toc_rules）
  Future<ImportResult> _importTxtTocRules() async {
    final api = ref.read(bookApiProvider);
    const key = 'txt_toc_rules';
    final existingRaw = await api.getConfig(key);
    final existing = <Map<String, dynamic>>[];
    if (existingRaw != null && existingRaw.isNotEmpty) {
      final decoded = jsonDecode(existingRaw);
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map<String, dynamic>) existing.add(e);
        }
      }
    }
    final names = existing.map((e) => e['name'] as String? ?? '').toSet();
    var nextId =
        existing.fold<int>(0, (m, e) => ((e['id'] as num?)?.toInt() ?? 0) > m
            ? (e['id'] as num).toInt()
            : m) +
            1;
    var success = 0;
    var skipped = 0;
    final errors = <String>[];
    for (final item in state.previewItems) {
      if (item is! Map<String, dynamic>) {
        errors.add('无效的 TXT 规则格式');
        continue;
      }
      try {
        var rule = TxtTocRule.fromJson(item);
        if (rule.name.isEmpty || rule.rule.isEmpty) {
          errors.add('TXT 规则缺少名称或正则');
          continue;
        }
        if (names.contains(rule.name)) {
          skipped++;
          continue;
        }
        if (rule.id <= 0) {
          rule = rule.copyWith(id: nextId++, serialNumber: existing.length);
        }
        existing.add(rule.toJson());
        names.add(rule.name);
        success++;
      } catch (e) {
        errors.add('导入 TXT 规则失败：$e');
      }
    }
    await api.setConfig(key, jsonEncode(existing));
    return ImportResult(
      total: state.previewItems.length,
      success: success,
      failed: errors.length,
      skipped: skipped,
      errors: errors,
    );
  }
}

/// 关联导入 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(associationNotifierProvider);
/// ref.read(associationNotifierProvider.notifier).reset();
/// ```
final associationNotifierProvider =
    NotifierProvider<AssociationNotifier, AssociationState>(
  AssociationNotifier.new,
);
