import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../models/models.dart';
import '../providers/replace_rule/replace_rule_notifier.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/legado_app_bar.dart';
import 'code_edit_screen.dart';

/// 替换规则整页编辑器（[A3 形态对齐 | full-stack-engineer + UI]）
///
/// 对标原版 `ReplaceEditActivity` + `activity_replace_edit.xml`：
/// 由弹窗表单升级为整页编辑，字段顺序与原版 layout 一一对齐：
/// 名称 / 分组 / 匹配规则（含「使用正则表达式」勾选 + 帮助图标）/ 替换为 /
/// 作用范围勾选（标题·书源·正文）/ 特定范围 / 排除范围 / 超时 /
/// 预览输入 → 预览输出。
///
/// 顶栏：保存（醒目，点击即存并返回）+ ⋮ 菜单（全屏编辑 / 复制规则 / 粘贴规则），
/// 对标原版 menu replace_edit.xml（menu_save always、menu_copy_rule /
/// menu_paste_rule never、menu_fullscreen_edit always → 归入 ⋮ 菜单）。
///
/// 保存链路沿用现有 `bookApi` 的 replaceRule 增删改方法（不新开数据链）；
/// 分组下拉复用现有分组数据来源（规则列表中的 group 字段，逗号分隔多分组）。
class ReplaceRuleEditScreen extends ConsumerStatefulWidget {
  /// 已有规则（编辑模式）；null 表示新建
  final ReplaceRule? rule;

  /// 新建时匹配规则预填（对标原版 startIntent pattern 预填，
  /// 阅读器长按选中文本传入）
  final String? prefillPattern;

  const ReplaceRuleEditScreen({super.key, this.rule, this.prefillPattern});

  /// 打开整页编辑器（新增/编辑共用同一页），保存后返回是否已保存
  static Future<bool> open(
    BuildContext context, {
    ReplaceRule? rule,
    String? prefillPattern,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReplaceRuleEditScreen(
          rule: rule,
          prefillPattern: prefillPattern,
        ),
      ),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<ReplaceRuleEditScreen> createState() =>
      _ReplaceRuleEditScreenState();
}

class _ReplaceRuleEditScreenState extends ConsumerState<ReplaceRuleEditScreen> {
  // ===== [A3 形态对齐 | full-stack-engineer + UI] 表单控制器与焦点 =====
  final _nameCtrl = TextEditingController();
  final _patternCtrl = TextEditingController();
  final _replacementCtrl = TextEditingController();
  final _scopeCtrl = TextEditingController();
  final _excludeScopeCtrl = TextEditingController();
  final _timeoutCtrl = TextEditingController();
  final _customGroupCtrl = TextEditingController();
  final _previewInputCtrl = TextEditingController();
  final _previewOutputCtrl = TextEditingController();
  // 各输入框独立焦点节点（全屏编辑据此反查目标控制器，对标原版
  // findFocus() + findParentTextInputLayout 的聚焦语义）
  final _nameFocus = FocusNode();
  final _patternFocus = FocusNode();
  final _replacementFocus = FocusNode();
  final _scopeFocus = FocusNode();
  final _excludeScopeFocus = FocusNode();
  final _previewInputFocus = FocusNode();

  /// 分组下拉选择（null = 无分组；_kGroupCustom = 自定义输入）
  String? _groupChoice;
  static const String _kGroupCustom = '__custom__';

  // [A3 形态对齐 | full-stack-engineer + UI] 勾选与开关状态
  bool _isRegex = true;
  bool _scopeTitle = false;
  bool _scopeContent = true;

  // 预览防抖（对标原版 PREVIEW_DEBOUNCE_MILLIS = 250ms）
  Timer? _previewJob;
  String? _previewError;

  bool get _isEdit => widget.rule != null;

  @override
  void initState() {
    super.initState();
    final r = widget.rule;
    _nameCtrl.text = r?.name ?? '';
    final group = r?.group ?? '';
    if (group.isEmpty) {
      _groupChoice = null;
    } else {
      // 分组可能是逗号分隔多分组；命中已有分组则预选，否则走自定义
      final parts = group
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (parts.length == 1 && _collectGroups().contains(parts.single)) {
        _groupChoice = parts.single;
      } else {
        _groupChoice = _kGroupCustom;
        _customGroupCtrl.text = group;
      }
    }
    _patternCtrl.text = r?.pattern ?? widget.prefillPattern ?? '';
    _replacementCtrl.text = r?.replacement ?? '';
    _scopeCtrl.text = r?.scope ?? '';
    _excludeScopeCtrl.text = r?.excludeScope ?? '';
    _isRegex = r?.isRegex ?? true;
    _scopeTitle = r?.scopeTitle ?? false;
    _scopeContent = r?.scopeContent ?? true;
    // [A3 写链路补齐 | 2026-09-11] 超时回填（FFI 写接口已支持
    // timeoutMillisecond，输入框可编辑，见 _buildTimeoutField）
    _timeoutCtrl.text = (r?.timeoutMillisecond ?? 3000).toString();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPreview());
  }

  @override
  void dispose() {
    _previewJob?.cancel();
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    _scopeCtrl.dispose();
    _excludeScopeCtrl.dispose();
    _timeoutCtrl.dispose();
    _customGroupCtrl.dispose();
    _previewInputCtrl.dispose();
    _previewOutputCtrl.dispose();
    _nameFocus.dispose();
    _patternFocus.dispose();
    _replacementFocus.dispose();
    _scopeFocus.dispose();
    _excludeScopeFocus.dispose();
    _previewInputFocus.dispose();
    super.dispose();
  }

  /// 收集现有规则的分组名（复用列表页分组数据来源：group 逗号分隔多分组）
  List<String> _collectGroups() {
    final set = <String>{};
    for (final r in ref.read(replaceRuleNotifierProvider).rules) {
      final g = r.group;
      if (g == null || g.trim().isEmpty) continue;
      set.addAll(
        g.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    }
    return set.toList()..sort();
  }

  /// 当前表单 → ReplaceRule（对标原版 getReplaceRule 全字段组装）
  ReplaceRule _currentRule() {
    final base = widget.rule ?? const ReplaceRule();
    final group = _groupChoice == _kGroupCustom
        ? _customGroupCtrl.text.trim()
        : _groupChoice;
    final groupTrimmed = (group ?? '').trim();
    return base.copyWith(
      name: _nameCtrl.text,
      group: groupTrimmed.isEmpty ? null : groupTrimmed,
      pattern: _patternCtrl.text,
      isRegex: _isRegex,
      replacement: _replacementCtrl.text,
      scopeTitle: _scopeTitle,
      scopeContent: _scopeContent,
      scope: _scopeCtrl.text.isEmpty ? null : _scopeCtrl.text,
      excludeScope:
          _excludeScopeCtrl.text.isEmpty ? null : _excludeScopeCtrl.text,
      // [A3 写链路补齐 | 2026-09-11] 超时随表单落库（FFI 写接口已支持
      // timeoutMillisecond）；空/非法输入回退默认 3000（与 Rust 侧缺省一致）
      timeoutMillisecond: _parseTimeout(),
    );
  }

  /// 解析超时输入框（空或非法回退 3000，对标 Rust 侧默认 timeout_millisecond）
  int _parseTimeout() {
    final v = int.tryParse(_timeoutCtrl.text.trim());
    return (v == null || v <= 0) ? 3000 : v;
  }

  // ===== [A3 形态对齐 | full-stack-engineer + UI] 保存 =====

  /// 保存并返回（对标原版 menu_save：checkValid → insert/update → finish）
  Future<void> _save() async {
    final rule = _currentRule();
    // 对标原版 checkValid：pattern 不能为空；正则时校验语法
    if (rule.pattern.isEmpty) {
      _snack('匹配规则不能为空');
      return;
    }
    if (rule.isRegex && !_isValidPattern(rule.pattern)) {
      _snack('正则语法错误或不支持');
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final notifier = ref.read(replaceRuleNotifierProvider.notifier);
      if (_isEdit) {
        await notifier.updateRule(rule);
      } else {
        await notifier.addRule(rule);
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('保存失败，请重试');
      }
    }
  }

  bool _saving = false;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ===== [A3 形态对齐 | full-stack-engineer + UI] 全屏编辑 =====

  /// 全屏编辑（对标原版 menu_fullscreen_edit → CodeEditActivity：
  /// 编辑当前聚焦输入框的文本，返回后写回该框）
  Future<void> _fullscreenEdit() async {
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null || !focused.hasPrimaryFocus) {
      _snack('请先聚焦到要编辑的输入框');
      return;
    }
    // 焦点节点 → 控制器/标题 反查（各输入框独立 FocusNode，
    // 对标原版 window.decorView.findFocus() 语义）
    final target = _findEditable(focused);
    if (target == null) {
      _snack('请先聚焦到要编辑的输入框');
      return;
    }
    final result = await CodeEditScreen.openExtended(
      context,
      title: target.title,
      initialText: target.controller.text,
    );
    if (result == null || !mounted) return;
    target.controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.text.length),
    );
    _schedulePreview();
  }

  /// 焦点节点 → 目标编辑框（控制器 + 标题；未命中返回 null）
  _EditableTarget? _findEditable(FocusNode focused) {
    final nodes = [
      (_nameFocus, _nameCtrl, '规则名称'),
      (_patternFocus, _patternCtrl, '匹配规则'),
      (_replacementFocus, _replacementCtrl, '替换为'),
      (_scopeFocus, _scopeCtrl, '特定范围'),
      (_excludeScopeFocus, _excludeScopeCtrl, '排除范围'),
      (_previewInputFocus, _previewInputCtrl, '预览输入'),
    ];
    for (final (node, controller, title) in nodes) {
      if (node == focused || node.hasFocus) {
        return _EditableTarget(controller, title);
      }
    }
    return null;
  }

  // ===== [A3 形态对齐 | full-stack-engineer + UI] 复制/粘贴规则 =====

  /// 复制规则（对标原版 menu_copy_rule → sendToClip(GSON.toJson(rule))：
  /// 规则 JSON 到剪贴板，含预览样本 previewText）
  Future<void> _copyRule() async {
    final rule = _currentRule();
    final sample = _previewInputCtrl.text.trim();
    final exportJson = Map<String, dynamic>.from(rule.toJson());
    if (sample.isNotEmpty) exportJson['previewText'] = sample;
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder().convert(exportJson)),
    );
    _snack('规则已复制到剪贴板');
  }

  /// 粘贴规则（对标原版 menu_paste_rule → pasteRule：
  /// 从剪贴板读 JSON 填充表单；格式不对则提示）
  Future<void> _pasteRule() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _snack('剪贴板为空');
      return;
    }
    ReplaceRule? pasted;
    // previewText 非 ReplaceRule 模型字段（仅导出 JSON 携带），
    // 须从解析出的 JSON Map 直接提取，模型 toJson 里取不到
    String? previewText;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        pasted = ReplaceRule.fromJson(decoded);
        previewText = decoded['previewText'] as String?;
      } else if (decoded is List && decoded.isNotEmpty) {
        // 兼容数组（取第一条，对标列表导入容错策略）
        final first = decoded.first;
        if (first is Map<String, dynamic>) {
          pasted = ReplaceRule.fromJson(first);
          previewText = first['previewText'] as String?;
        }
      }
    } catch (_) {
      pasted = null;
    }
    if (pasted == null) {
      _snack('剪贴板内容不是有效的替换规则 JSON');
      return;
    }
    _fillFrom(pasted, previewText: previewText);
    _schedulePreview();
    _snack('已粘贴规则「${pasted.name.isEmpty ? '(未命名)' : pasted.name}」');
  }

  /// 用外部规则填充表单（粘贴/预填共用）
  void _fillFrom(ReplaceRule r, {String? previewText}) {
    setState(() {
      _nameCtrl.text = r.name;
      final group = r.group ?? '';
      if (group.isEmpty) {
        _groupChoice = null;
        _customGroupCtrl.clear();
      } else {
        final parts = group
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.length == 1 && _collectGroups().contains(parts.single)) {
          _groupChoice = parts.single;
          _customGroupCtrl.clear();
        } else {
          _groupChoice = _kGroupCustom;
          _customGroupCtrl.text = group;
        }
      }
      _patternCtrl.text = r.pattern;
      _isRegex = r.isRegex;
      _replacementCtrl.text = r.replacement;
      _scopeTitle = r.scopeTitle;
      _scopeContent = r.scopeContent;
      _scopeCtrl.text = r.scope ?? '';
      _excludeScopeCtrl.text = r.excludeScope ?? '';
      _timeoutCtrl.text = r.timeoutMillisecond.toString();
      if (previewText != null) _previewInputCtrl.text = previewText;
    });
  }

  // ===== [A3 形态对齐 | full-stack-engineer + UI] 预览 =====

  /// 防抖调度预览（对标原版 schedulePreview 250ms）
  void _schedulePreview() {
    _previewJob?.cancel();
    _previewJob = Timer(const Duration(milliseconds: 250), _runPreview);
  }

  /// 计算预览输出（纯 Dart 轻量近似，不依赖 FFI/Rust 引擎）：
  /// - 输入或匹配规则为空 → 原样输出
  /// - 非正则 → 字面量替换
  /// - 正则 → 内置 RegExp 替换；替换串以 `@js:` 开头时 JS 语义不可用，
  ///   输出区显示诚实提示（原版由 Rhino 引擎执行 JS，Pure 侧暂无该能力）
  void _runPreview() {
    final sample = _previewInputCtrl.text;
    final pattern = _patternCtrl.text;
    if (sample.isEmpty || pattern.isEmpty) {
      _updatePreview(sample, null);
      return;
    }
    final replacement = _replacementCtrl.text;
    try {
      if (!_isRegex) {
        // 非正则：字面量替换（对标原版 String.replace）
        _updatePreview(sample.replaceAll(pattern, replacement), null);
      } else if (replacement.startsWith('@js:')) {
        _updatePreview(sample, 'JS 替换预览不可用（Pure 侧暂无 JS 引擎）');
      } else {
        // 正则：对标原版 java.util.regex.Matcher.replaceAll(replacement)，
        // 支持 $& / $1..$9 / ${name} 组引用；Dart 的 replaceAll(RegExp,String)
        // 为字面替换不展开组引用，故用 replaceAllMapped + 手动展开
        final re = RegExp(pattern);
        final out = sample.replaceAllMapped(re, (m) => _expandGroups(m, replacement));
        _updatePreview(out, null);
      }
    } catch (_) {
      _updatePreview(sample, '正则语法错误或不支持');
    }
  }

  /// 展开替换串中的组引用（对标 Java Matcher.replaceAll 的 $ 语义）：
  /// `$$` → 字面 `$`；`$&` → 整个匹配；`$1`..`$9` → 编号捕获组；
  /// `${name}` → 命名捕获组；未命中/越界的组引用置空（未命中组
  /// 在 Java 中同样替换为空串）
  String _expandGroups(Match m, String replacement) {
    final buf = StringBuffer();
    var i = 0;
    while (i < replacement.length) {
      final ch = replacement[i];
      if (ch != r'$') {
        buf.write(ch);
        i++;
        continue;
      }
      final next = i + 1 < replacement.length ? replacement[i + 1] : null;
      if (next == null) {
        // 结尾孤立的 $
        buf.write(r'$');
        i++;
        continue;
      }
      if (next == r'$') {
        buf.write(r'$');
        i += 2;
        continue;
      }
      if (next == '&') {
        buf.write(m[0] ?? '');
        i += 2;
        continue;
      }
      if (next == '{') {
        // 命名组 ${name}（Match 接口无命名组方法，按运行时类型
        // 走 RegExpMatch.namedGroup；组不存在时 Java 亦替换为空串）
        final end = replacement.indexOf('}', i + 2);
        if (end > i + 2) {
          final name = replacement.substring(i + 2, end);
          String? g;
          try {
            g = (m as RegExpMatch).namedGroup(name);
          } catch (_) {
            g = null; // 组名不存在/未命中 → 空串
          }
          buf.write(g ?? '');
          i = end + 1;
          continue;
        }
        // 无闭合 }，按字面处理
        buf.write(ch);
        i++;
        continue;
      }
      // 编号捕获组 $1..$9（原版仅支持单位编号）
      final digit = next.codeUnitAt(0) - 48;
      if (digit >= 0 && digit <= 9) {
        buf.write(m[digit] ?? '');
        i += 2;
        continue;
      }
      // 其他 $x 保留字面
      buf.write(ch);
      i++;
    }
    return buf.toString();
  }

  void _updatePreview(String output, String? error) {
    _previewOutputCtrl.text = output;
    _previewError = error;
    if (!mounted) return;
    setState(() {});
  }

  // ===== [A3 形态对齐 | full-stack-engineer + UI] 构建 =====

  @override
  Widget build(BuildContext context) {
    final groups = _collectGroups();
    return Scaffold(
      appBar: LegadoAppBar(
        title: Text(_isEdit ? '编辑替换规则' : '添加替换规则'),
        actions: [
          // 保存（醒目，点即存并返回；对标原版 menu_save showAsAction=always）
          FilledButton.tonal(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
          // ⋮ 菜单（对标原版 replace_edit menu：全屏编辑/复制规则/粘贴规则）
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'fullscreen':
                  _fullscreenEdit();
                case 'copy':
                  _copyRule();
                case 'paste':
                  _pasteRule();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'fullscreen',
                child: Text('全屏编辑'),
              ),
              PopupMenuItem(value: 'copy', child: Text('复制规则')),
              PopupMenuItem(value: 'paste', child: Text('粘贴规则')),
            ],
          ),
        ],
      ),
      body: ListView(
        // [LAYOUT_PLAN P2] 页面水平边距统一 16dp（全局标尺）
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // 1. 名称（对标 et_name）
          _buildTextField(
            _nameCtrl,
            label: '规则名称',
            focusNode: _nameFocus,
          ),
          const SizedBox(height: 16),
          // 2. 分组（对标 et_group；参考版形态：分组下拉 + 自定义输入）
          _buildGroupField(groups),
          const SizedBox(height: 16),
          // 3. 匹配规则（对标 et_replace_rule）
          _buildTextField(
            _patternCtrl,
            label: '匹配规则',
            hint: '正则表达式或文本',
            onChanged: (_) => _schedulePreview(),
            focusNode: _patternFocus,
          ),
          // 3.1 使用正则表达式勾选 + 帮助图标（对标 cb_use_regex + iv_help）
          const SizedBox(height: 8),
          Row(
            children: [
              // Checkbox + 标签（本 SDK Checkbox 无 child/tooltip 参数，
              // 走仓库既有 Row(Checkbox, Text) 写法，如导入确认页）
              Checkbox(
                value: _isRegex,
                onChanged: (v) => setState(
                  () {
                    _isRegex = v ?? true;
                    _schedulePreview();
                  },
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                semanticLabel: '使用正则表达式',
              ),
              const Text('使用正则表达式'),
              const Spacer(),
              // 帮助图标（对标 iv_help → showHelp("regexHelp")；
              // 复用仓库既有帮助弹层组件，内容为正则语法静态说明）
              IconButton(
                icon: const Icon(Symbols.help_outline_rounded),
                tooltip: '帮助',
                onPressed: () => showHelp(context, HelpAssets.regexHelp),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 4. 替换为（对标 et_replace_to）
          _buildTextField(
            _replacementCtrl,
            label: '替换为',
            onChanged: (_) => _schedulePreview(),
            focusNode: _replacementFocus,
          ),
          const SizedBox(height: 16),
          // 5. 作用范围三勾选（对标 cb_scope_title / cb_scope_source /
          // cb_scope_content；书源 scope 受阻见 _buildScopeCheckboxes）
          _buildScopeCheckboxes(),
          const SizedBox(height: 16),
          // 6. 特定范围（对标 et_scope）
          _buildTextField(
            _scopeCtrl,
            label: '特定范围',
            hint: '留空为全局，输入书名为特定书籍',
            focusNode: _scopeFocus,
          ),
          const SizedBox(height: 16),
          // 7. 排除范围（对标 et_exclude_scope）
          _buildTextField(
            _excludeScopeCtrl,
            label: '排除范围',
            hint: '输入书名，多个用逗号分隔',
            focusNode: _excludeScopeFocus,
          ),
          const SizedBox(height: 16),
          // 8. 超时（对标 et_timeout；[A3 写链路补齐 2026-09-11] 可编辑，
          // 空/非法回退 3000ms）
          _buildTimeoutField(),
          const SizedBox(height: 16),
          // 9. 预览输入 → 预览输出（对标 et_preview_input / et_preview_output，
          // 原版为左右两列等宽；窄屏降为上下堆叠）
          _buildPreviewSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 字段输入框（走全局 inputDecorationTheme，不手写边框）
  Widget _buildTextField(
    TextEditingController controller, {
    required String label,
    String? hint,
    ValueChanged<String>? onChanged,
    FocusNode? focusNode,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: (v) => onChanged?.call(v),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
      ),
    );
  }

  /// 分组（下拉复用现有分组数据来源 + 自定义输入；对标 et_group 自由输入
  /// 语义，参考版形态为分组下拉）
  Widget _buildGroupField(List<String> groups) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Key 随 _groupChoice 变化强制重建（FormField 的 initialValue
        // 只在首建生效；粘贴回填等程序化改组需重建以同步选中项）
        DropdownButtonFormField<String?>(
          key: ValueKey<String?>('groupChoice$_groupChoice'),
          initialValue: _groupChoice,
          decoration: const InputDecoration(labelText: '分组'),
          isExpanded: true,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('（无分组）'),
            ),
            for (final g in groups)
              DropdownMenuItem<String?>(value: g, child: Text(g)),
            const DropdownMenuItem<String?>(
              value: _kGroupCustom,
              child: Text('自定义…'),
            ),
          ],
          onChanged: (v) {
            setState(() {
              _groupChoice = v;
              if (v != _kGroupCustom) _customGroupCtrl.clear();
            });
          },
        ),
        if (_groupChoice == _kGroupCustom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _customGroupCtrl,
            decoration: const InputDecoration(
              labelText: '输入分组名',
              hintText: '多个分组用逗号分隔',
            ),
          ),
        ],
      ],
    );
  }

  /// 作用范围三勾选（对标原版 cb_scope_title / cb_scope_source /
  /// cb_scope_content）
  ///
  /// [A3 受阻项 | full-stack-engineer + UI] 书源 scope（scopeSource）：
  /// 我方 Dart 模型 `ReplaceRule` 与 Rust 模型/DB 均无该字段（FFI 读写链路
  /// 缺失），此处以禁用行 + 诚实标注呈现（保留原版三勾选形态），
  /// 待 Rust 轨扩展 FFI 契约后接入。
  Widget _buildScopeCheckboxes() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ScopeCheckbox(
              label: '标题',
              value: _scopeTitle,
              onChanged: (v) => setState(() => _scopeTitle = v ?? false),
            ),
            const SizedBox(width: 16),
            // 书源 scope：字段受阻（模型/FFI 无 scopeSource），禁用 + 标注
            _ScopeCheckbox(
              label: '书源（暂不支持）',
              value: false,
              enabled: false,
            ),
            const SizedBox(width: 16),
            _ScopeCheckbox(
              label: '正文',
              value: _scopeContent,
              onChanged: (v) => setState(() => _scopeContent = v ?? true),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '勾选规则生效的内容范围；未勾选范围不受该规则影响',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 超时（对标 et_timeout；可编辑：
  /// [A3 写链路补齐 | 2026-09-11] FFI add/update 已支持 timeoutMillisecond，
  /// 输入随保存落库；空/非法输入回退默认 3000 毫秒）
  Widget _buildTimeoutField() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _timeoutCtrl,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: '超时时间（毫秒）',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '匹配/替换执行超时，空或非法输入回退 3000 毫秒',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 预览区（对标原版左右两列；宽屏 Row 并排，窄屏上下堆叠）
  Widget _buildPreviewSection() {
    final input = _buildPreviewBox(
      label: '预览输入',
      controller: _previewInputCtrl,
      focusNode: _previewInputFocus,
      onChanged: (_) => _schedulePreview(),
    );
    final output = _buildPreviewBox(
      label: '预览输出',
      controller: _previewOutputCtrl,
      isOutput: true,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        // 600px 断点：≥600 左右并排（原版 FlexboxLayout 横向两列），
        // 否则上下堆叠（长文本可用性优先）
        if (constraints.maxWidth >= 600) {
          return Row(
            children: [
              Expanded(child: input),
              const SizedBox(width: 8),
              Expanded(child: output),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            input,
            if (_previewError != null) ...[
              const SizedBox(height: 4),
              Text(
                _previewError!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            output,
          ],
        );
      },
    );
  }

  /// 预览输入/输出框（输出框只读可选，对标 et_preview_output
  /// keyListener=null + setTextIsSelectable）
  Widget _buildPreviewBox({
    required String label,
    required TextEditingController controller,
    ValueChanged<String>? onChanged,
    FocusNode? focusNode,
    bool isOutput = false,
  }) {
    return TextField(
      controller: controller,
      focusNode: isOutput ? null : focusNode,
      onChanged: isOutput ? null : onChanged,
      readOnly: isOutput,
      showCursor: !isOutput,
      maxLines: 4,
      minLines: 2,
      textInputAction: TextInputAction.newline,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(
        fontFamily: 'Menlo',
        fontFamilyFallback: ['Consolas', 'monospace'],
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: isOutput ? '（随输入实时更新）' : null,
      ),
    );
  }
}

/// 作用范围勾选（Checkbox + 标签；[A3 形态对齐 | full-stack-engineer + UI]）
class _ScopeCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool?>? onChanged;

  const _ScopeCheckbox({
    required this.label,
    required this.value,
    this.enabled = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          onChanged: enabled ? onChanged : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: enabled
                ? theme.colorScheme.onSurface
                : theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

/// [A3 形态对齐 | full-stack-engineer + UI] 全屏编辑目标
///（控制器 + 标题；对标原版 findParentTextInputLayout(view)?.hint
/// 取输入框标题的语义）
class _EditableTarget {
  const _EditableTarget(this.controller, this.title);
  final TextEditingController controller;
  final String title;
}

/// [A3 形态对齐 | full-stack-engineer + UI] 正则语法快速校验
///（对标原版 ReplaceRule.isValid 中 Pattern.compile 校验，
/// Dart 侧用 RegExp 构造器替代 Java Pattern）
bool _isValidPattern(String pattern) {
  try {
    RegExp(pattern);
    return true;
  } catch (_) {
    return false;
  }
}
