import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/rust_api.dart';
import '../services/source_import_service.dart';

/// 导入类型枚举
enum ImportType {
  /// 书源
  bookSource,

  /// RSS 源
  rssSource,

  /// 替换规则
  replaceRule,

  /// 主题配置
  theme,
}

/// 导入来源方式
enum ImportSource {
  /// 从 URL 导入
  url,

  /// 从文件导入
  file,

  /// 从剪贴板导入
  clipboard,

  /// 扫码导入（预留）
  qrCode,
}

/// 导入步骤
enum ImportStep {
  /// 选择导入类型
  selectType,

  /// 输入来源
  inputSource,

  /// 预览导入内容
  preview,

  /// 导入完成
  done,
}

/// 关联导入状态管理
class AssociationProvider extends ChangeNotifier {
  final SourceImportService _importService;

  AssociationProvider(RustApi api)
      : _importService = SourceImportService(api);

  ImportType _type = ImportType.bookSource;
  ImportSource _source = ImportSource.url;
  ImportStep _step = ImportStep.selectType;
  List<dynamic> _previewItems = [];
  bool _isLoading = false;
  String? _error;
  ImportResult? _lastResult;

  // URL 输入
  String _urlInput = '';

  // ===== Getters =====

  ImportType get type => _type;
  ImportSource get source => _source;
  ImportStep get step => _step;
  List<dynamic> get previewItems => _previewItems;
  bool get isLoading => _isLoading;
  String? get error => _error;
  ImportResult? get lastResult => _lastResult;
  String get urlInput => _urlInput;
  SourceImportService get importService => _importService;

  /// 导入类型显示名称
  String get typeName {
    switch (_type) {
      case ImportType.bookSource:
        return '书源';
      case ImportType.rssSource:
        return 'RSS 源';
      case ImportType.replaceRule:
        return '替换规则';
      case ImportType.theme:
        return '主题配置';
    }
  }

  /// 导入来源显示名称
  String get sourceName {
    switch (_source) {
      case ImportSource.url:
        return 'URL';
      case ImportSource.file:
        return '文件';
      case ImportSource.clipboard:
        return '剪贴板';
      case ImportSource.qrCode:
        return '扫码';
    }
  }

  /// 预览项数量
  int get previewCount => _previewItems.length;

  /// 是否可以进入下一步
  bool get canProceed {
    switch (_step) {
      case ImportStep.selectType:
        return true;
      case ImportStep.inputSource:
        if (_source == ImportSource.url) {
          return _urlInput.trim().isNotEmpty;
        }
        return true;
      case ImportStep.preview:
        return _previewItems.isNotEmpty;
      case ImportStep.done:
        return false;
    }
  }

  // ===== 操作 =====

  /// 设置导入类型
  void setType(ImportType type) {
    _type = type;
    notifyListeners();
  }

  /// 设置导入来源
  void setSource(ImportSource source) {
    _source = source;
    notifyListeners();
  }

  /// 设置 URL 输入
  void setUrlInput(String url) {
    _urlInput = url;
    notifyListeners();
  }

  /// 进入下一步
  void nextStep() {
    switch (_step) {
      case ImportStep.selectType:
        _step = ImportStep.inputSource;
        break;
      case ImportStep.inputSource:
        _step = ImportStep.preview;
        break;
      case ImportStep.preview:
        _step = ImportStep.done;
        break;
      case ImportStep.done:
        break;
    }
    notifyListeners();
  }

  /// 返回上一步
  void previousStep() {
    switch (_step) {
      case ImportStep.selectType:
        break;
      case ImportStep.inputSource:
        _step = ImportStep.selectType;
        break;
      case ImportStep.preview:
        _step = ImportStep.inputSource;
        _previewItems.clear();
        break;
      case ImportStep.done:
        _step = ImportStep.preview;
        break;
    }
    _error = null;
    notifyListeners();
  }

  /// 重置到初始状态
  void reset() {
    _step = ImportStep.selectType;
    _previewItems.clear();
    _error = null;
    _lastResult = null;
    _urlInput = '';
    notifyListeners();
  }

  /// 从 URL 加载预览
  Future<void> loadFromUrl(String url) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse(url);
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _error = 'HTTP 请求失败：状态码 ${response.statusCode}';
        return;
      }

      final body = utf8.decode(response.bodyBytes);
      _parsePreviewContent(body);
    } catch (e) {
      _error = '从 URL 加载失败：$e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 从文件加载预览
  Future<void> loadFromFile(String path) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final file = File(path);
      if (!await file.exists()) {
        _error = '文件不存在：$path';
        return;
      }

      final content = await file.readAsString(encoding: utf8);
      _parsePreviewContent(content);
    } catch (e) {
      _error = '读取文件失败：$e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 从剪贴板加载预览
  Future<void> loadFromClipboard() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.trim().isEmpty) {
        _error = '剪贴板为空';
        return;
      }

      // 如果剪贴板内容是 URL，则从 URL 加载
      if (text.startsWith('http://') || text.startsWith('https://')) {
        _urlInput = text.trim();
        await loadFromUrl(text.trim());
        return;
      }

      _parsePreviewContent(text);
    } catch (e) {
      _error = '读取剪贴板失败：$e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 解析预览内容
  void _parsePreviewContent(String content) {
    try {
      final decoded = jsonDecode(content);

      if (decoded is List) {
        _previewItems = decoded;
      } else if (decoded is Map<String, dynamic>) {
        _previewItems = [decoded];
      } else {
        _error = '无效的 JSON 格式：期望数组或对象';
        _previewItems = [];
      }
    } on FormatException catch (e) {
      _error = 'JSON 解析错误：${e.message}';
      _previewItems = [];
    }
  }

  /// 确认导入
  Future<ImportResult> confirmImport() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final ImportResult result;

      switch (_type) {
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
      }

      _lastResult = result;
      _step = ImportStep.done;
      return result;
    } catch (e) {
      _error = e.toString();
      return ImportResult(
        total: 0,
        success: 0,
        failed: 0,
        skipped: 0,
        errors: [e.toString()],
      );
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 导入书源
  Future<ImportResult> _importBookSources() async {
    final jsonStr = jsonEncode(_previewItems);
    return await _importService.importFromJson(jsonStr);
  }

  /// 导入 RSS 源
  Future<ImportResult> _importRssSources() async {
    var success = 0;
    var failed = 0;
    final errors = <String>[];

    for (final item in _previewItems) {
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
      total: _previewItems.length,
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

    for (final item in _previewItems) {
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
      total: _previewItems.length,
      success: success,
      failed: failed,
      skipped: 0,
      errors: errors,
    );
  }

  /// 导入主题配置
  Future<ImportResult> _importTheme() async {
    // 主题配置导入（预留实现）
    return ImportResult(
      total: _previewItems.length,
      success: 0,
      failed: 0,
      skipped: _previewItems.length,
      errors: ['主题配置导入功能开发中'],
    );
  }
}
