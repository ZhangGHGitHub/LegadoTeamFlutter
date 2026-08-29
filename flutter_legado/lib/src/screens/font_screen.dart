import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 字体管理页面
///
/// 功能：显示当前阅读字体、切换系统字体、导入自定义 .ttf/.otf 字体、实时预览。
/// 自定义字体通过 [FontLoader] 动态加载，字体文件复制到应用文档目录持久化。
class FontScreen extends StatefulWidget {
  const FontScreen({super.key});

  @override
  State<FontScreen> createState() => _FontScreenState();
}

class _FontScreenState extends State<FontScreen> {
  static const _keyFontFamily = 'reader_font_family';
  static const _keyCustomFonts = 'reader_custom_fonts'; // [{family, path}]

  /// 内置/系统字体候选列表
  static const List<_FontOption> _systemFonts = [
    _FontOption(family: null, label: '默认字体'),
    _FontOption(family: 'serif', label: '衬线体 (Serif)'),
    _FontOption(family: 'monospace', label: '等宽体 (Monospace)'),
    _FontOption(family: 'Microsoft YaHei', label: '微软雅黑'),
    _FontOption(family: 'SimSun', label: '宋体'),
    _FontOption(family: 'KaiTi', label: '楷体'),
    _FontOption(family: 'SimHei', label: '黑体'),
    _FontOption(family: 'Source Han Serif SC', label: '思源宋体'),
    _FontOption(family: 'Source Han Sans SC', label: '思源黑体'),
    _FontOption(family: 'Noto Serif SC', label: 'Noto 宋体'),
    _FontOption(family: 'Georgia', label: 'Georgia'),
    _FontOption(family: 'Times New Roman', label: 'Times New Roman'),
    _FontOption(family: 'Consolas', label: 'Consolas'),
  ];

  String? _currentFamily;
  List<_FontOption> _customFonts = [];
  bool _importing = false;

  static const _previewText =
      '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。\n'
      'The quick brown fox jumps over the lazy dog. 0123456789';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final family = prefs.getString(_keyFontFamily);
    final customRaw = prefs.getStringList(_keyCustomFonts) ?? [];
    final customs = <_FontOption>[];
    for (final entry in customRaw) {
      final parts = entry.split('|');
      if (parts.length != 2) continue;
      // 尝试重新注册字体（应用重启后需重新加载）
      try {
        final file = File(parts[1]);
        if (await file.exists()) {
          final loader = FontLoader(parts[0])
            ..addFont(
              file.readAsBytes().then((b) => b.buffer.asByteData()),
            );
          await loader.load();
          customs.add(_FontOption(family: parts[0], label: parts[0]));
        }
      } catch (_) {
        // 字体文件失效则跳过
      }
    }
    if (mounted) {
      setState(() {
        _currentFamily = family;
        _customFonts = customs;
      });
    }
  }

  Future<void> _selectFont(String? family) async {
    final prefs = await SharedPreferences.getInstance();
    if (family == null) {
      await prefs.remove(_keyFontFamily);
    } else {
      await prefs.setString(_keyFontFamily, family);
    }
    if (mounted) setState(() => _currentFamily = family);
  }

  Future<void> _importFont() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final bytes = picked.bytes;
    final path = picked.path;
    if (bytes == null && path == null) return;

    setState(() => _importing = true);
    try {
      final data = bytes ?? await File(path!).readAsBytes();
      final name = (picked.name.split('.').first).replaceAll(' ', '');
      final family = 'Custom_$name';

      // 复制字体文件到应用文档目录，保证重启后仍可加载
      final dir = await getApplicationDocumentsDirectory();
      final fontDir = Directory('${dir.path}${Platform.pathSeparator}fonts');
      if (!await fontDir.exists()) await fontDir.create(recursive: true);
      final target =
          File('${fontDir.path}${Platform.pathSeparator}$family.ttf');
      await target.writeAsBytes(data);

      final loader = FontLoader(family)
        ..addFont(Future.value(data.buffer.asByteData()));
      await loader.load();

      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_keyCustomFonts) ?? [];
      list.add('$family|${target.path}');
      await prefs.setStringList(_keyCustomFonts, list);

      if (mounted) {
        setState(() {
          _customFonts.add(_FontOption(family: family, label: name));
          _currentFamily = family;
        });
      }
      await prefs.setString(_keyFontFamily, family);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入字体「$name」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('字体导入失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  String get _currentLabel {
    if (_currentFamily == null) return '默认字体';
    for (final f in [..._systemFonts, ..._customFonts]) {
      if (f.family == _currentFamily) return f.label;
    }
    return _currentFamily!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('字体管理'),
        actions: [
          IconButton(
            icon: _importing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.file_download_rounded),
            tooltip: '导入 .ttf / .otf 字体',
            onPressed: _importing ? null : _importFont,
          ),
        ],
      ),
      body: ListView(
        children: [
          // ===== 当前字体 + 预览 =====
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('当前字体：$_currentLabel',
                style: theme.textTheme.titleMedium),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _previewText,
                style: TextStyle(
                  fontFamily: _currentFamily,
                  fontSize: 18,
                  height: 1.6,
                ),
              ),
            ),
          ),
          const Divider(),

          // ===== 自定义字体 =====
          if (_customFonts.isNotEmpty) ...[
            _buildSectionHeader(theme, '自定义字体'),
            ..._customFonts.map((f) => _buildFontTile(theme, f)),
            const Divider(),
          ],

          // ===== 系统字体 =====
          _buildSectionHeader(theme, '系统字体'),
          ..._systemFonts.map((f) => _buildFontTile(theme, f)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildFontTile(ThemeData theme, _FontOption font) {
    final selected = _currentFamily == font.family;
    return ListTile(
      leading: Icon(
        selected ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded,
        color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      title: Text(
        font.label,
        style: TextStyle(fontFamily: font.family, fontSize: 16),
      ),
      subtitle: Text(
        '阅读字体预览 Aa 汉',
        style: TextStyle(fontFamily: font.family, fontSize: 13),
      ),
      selected: selected,
      onTap: () => _selectFont(font.family),
    );
  }
}

class _FontOption {
  final String? family;
  final String label;

  const _FontOption({required this.family, required this.label});
}
