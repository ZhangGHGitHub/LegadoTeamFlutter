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
  /// 字体设置目标：`body` = 正文字体（既有 `reader_font_family` 链路，
  /// 默认值保持既有调用方兼容）；`title` = 标题字体（原版 #1072 titleFont，
  /// 空值=跟随正文，写 `titleFont` 键）— full-stack-engineer
  final String target;

  const FontScreen({super.key, this.target = 'body'});

  @override
  State<FontScreen> createState() => _FontScreenState();
}

class _FontScreenState extends State<FontScreen> {
  static const _keyFontFamily = 'reader_font_family';
  // [C3 标题字体] 标题字体键（与 ReaderAdvancedConfig.titleFont 同源）
  static const _keyTitleFont = 'titleFont';
  static const _keyCustomFonts = 'reader_custom_fonts'; // [{family, path}]
  // [iOS 视角F C3] 自定义字体持久子目录（相对应用 Documents 目录）。
  // 存「相对标识」而非绝对路径：iOS 容器 UUID 在重签名/重装后变化，绝对路径
  // 会失效；相对标识在读取侧用「当前容器 Documents 目录」运行时拼接重建。
  static const _fontSubDir = 'fonts';

  /// 当前 target 对应的字体家族键（body=既有链路，title=titleFont）
  String get _familyKey =>
      widget.target == 'title' ? _keyTitleFont : _keyFontFamily;

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
    final family = prefs.getString(_familyKey);
    final customRaw = prefs.getStringList(_keyCustomFonts) ?? [];
    final customs = <_FontOption>[];
    final missing = <String>[];
    // [iOS 视角F C3] Documents 根目录（运行时拼接相对标识用），惰性获取
    String? docsPath;
    bool docsFetched = false;
    final sep = Platform.pathSeparator;
    Future<String> docs() async {
      if (!docsFetched) {
        final d = await getApplicationDocumentsDirectory();
        docsPath = d.path;
        docsFetched = true;
      }
      return docsPath!;
    }

    var healedAny = false;
    for (var i = 0; i < customRaw.length; i++) {
      final parts = customRaw[i].split('|');
      if (parts.length != 2) continue;
      final fam = parts[0];
      final stored = parts[1];
      // [iOS 视角F C3] 解析真实路径：
      // - 相对标识（新格式，fonts/x.ttf）→ 当前 Documents 目录拼接；
      // - 绝对路径（旧格式）→ 原样；若已失效（容器 UUID 变化）则回退到
      //   Documents/fonts/<文件名> 自愈，并把该条目归一化为相对标识回写。
      late File file;
      String? healedRelative;
      if (File(stored).isAbsolute) {
        file = File(stored);
        if (!await file.exists()) {
          final base = await docs();
          final fallback =
              File('$base$sep$_fontSubDir$sep${_baseName(stored)}');
          if (await fallback.exists()) {
            file = fallback;
            healedRelative = '$_fontSubDir/${_baseName(stored)}';
          }
        }
      } else {
        final base = await docs();
        file = File('$base$sep${stored.replaceAll('/', sep)}');
      }
      if (!await file.exists()) {
        missing.add(fam);
        continue;
      }
      // 尝试重新注册字体（应用重启后需重新加载）
      try {
        final loader = FontLoader(fam)
          ..addFont(
            file.readAsBytes().then((b) => b.buffer.asByteData()),
          );
        await loader.load();
        customs.add(_FontOption(family: fam, label: fam));
        if (healedRelative != null) {
          // 自愈：把旧绝对路径条目归一化为相对可迁移标识
          customRaw[i] = '$fam|$healedRelative';
          healedAny = true;
        }
      } catch (_) {
        missing.add(fam);
      }
    }
    // [iOS 视角F C3] 自愈归一化后回写（仅确有变化时），使旧绝对路径不再依赖容器 UUID
    if (healedAny) {
      await prefs.setStringList(_keyCustomFonts, customRaw);
    }
    if (mounted) {
      setState(() {
        _currentFamily = family;
        _customFonts = customs;
      });
      if (missing.isNotEmpty) {
        // [iOS 视角F C3] 字体缺失须可见（不再静默跳过）
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content:
                  Text('部分自定义字体文件缺失，未加载：${missing.join('、')}'),
            ),
          );
      }
    }
  }

  Future<void> _selectFont(String? family) async {
    final prefs = await SharedPreferences.getInstance();
    if (family == null) {
      if (widget.target == 'title') {
        // 标题字体：默认字体=空值，语义为跟随正文（对齐原版 titleFont）
        await prefs.setString(_keyTitleFont, '');
      } else {
        await prefs.remove(_keyFontFamily);
      }
    } else {
      await prefs.setString(_familyKey, family);
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
      // [iOS 视角F C3] 存「相对 Documents 的可迁移标识」而非绝对路径：
      // 读取侧用当前容器 Documents 目录运行时拼接，跨重签名/重装仍有效。
      list.add('$family|$_fontSubDir/$family.ttf');
      await prefs.setStringList(_keyCustomFonts, list);

      if (mounted) {
        setState(() {
          _customFonts.add(_FontOption(family: family, label: name));
          _currentFamily = family;
        });
      }
      await prefs.setString(_familyKey, family);
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

  /// 取路径末段（不引入 package:path 直接依赖；兼容 `/` 与 `\` 分隔符）
  String _baseName(String p) {
    final parts = p.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? p : parts.last;
  }

  String get _currentLabel {
    final family = _currentFamily;
    if (widget.target == 'title') {
      // 标题字体：null/空 = 跟随正文（对齐原版 titleFont 语义）
      if (family == null || family.isEmpty) return '跟随正文';
    } else if (family == null) {
      return '默认字体';
    }
    for (final f in [..._systemFonts, ..._customFonts]) {
      if (f.family == family) return f.label;
    }
    return family;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: LegadoAppBar(
        title: Text(widget.target == 'title' ? '标题字体' : '字体管理'),
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
            child: Text(
              widget.target == 'title'
                  ? '当前标题字体：$_currentLabel'
                  : '当前字体：$_currentLabel',
              style: theme.textTheme.titleMedium,
            ),
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
    // [LAYOUT_PLAN P1] 分组标题走 IosSectionHeader 规范
    //（labelMedium/onSurfaceVariant，padding 16,24,16,8）
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
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
