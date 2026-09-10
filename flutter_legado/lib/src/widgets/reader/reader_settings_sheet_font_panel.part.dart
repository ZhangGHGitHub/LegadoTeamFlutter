// reader_settings_sheet.dart 的 part 文件（[C3 形态对齐 | full-stack-engineer + UI]）：
// Tt 行内字体面板（对齐参考版形态：正文字体/正文字距/标题字体 + 斜体开关/
// 字重/选择字体/简繁转换；不再跳转整页字体管理，「选择字体」入口保留在面板内）。
// 参照仓库既有拆法 reader_config_panel_*.part.dart（part 与主文件同 library，
// 可共享主文件 imports 与私有成员）。
//
// 原版控件语义基准（legado-upstream 源码实证，3.26.082823）：
// - ReadStyleDialog.kt / dialog_read_book_style.xml：
//   · tv_text_font「字体」→ FontSelectDialog（curFontPath=ReadBookConfig.textFont，
//     selectFont(path) 写回 textFont）；
//   · tv_text_indent「缩进」→ selector 5 档（R.array.indent 无/一/二/三/四字符，
//     paragraphIndent="　".repeat(index)）；
//   · text_font_weight_converter「中/粗/细」→ ReadBookConfig.textBold（0/1/2）；
//   · chinese_converter「简/繁」→ AppConfig.chineseConverterType
//     （R.array.chinese_mode：0关闭/1繁转简/2简转繁）；
//   · dsb_text_letter_spacing：progress 0-100 → letterSpacing=(p-50)/100（-0.5~1.0）；
//   · 原版 #1072 新增 titleFont（ReadBookConfig.titleFont，空值=跟随正文字体，
//     控件位于 TipConfigDialog/dialog_tip_config.xml，非 ReadStyleDialog）。
// - 参考版（io.legato.kazusa）Tt 行内面板另含「斜体开关」与「标题字体」页签：
//   · 斜体：开源版全仓无斜体配置字段（参考版自有增强），按重构红线**不放入
//     面板**（不新增原版不存在的功能）；
//   · 标题字体：对应原版 #1072 titleFont，我方暂无对应配置字段 →
//     以禁用行诚实标注「跟随正文」，登记为受阻项（不新增数据链）。

// 注：part 文件不得携带 import（依赖主文件 library 级 imports：
// material / shared_preferences / routes / providers / reader_config_panel）。
part of 'reader_settings_sheet.dart';

/// 行内字体面板配置提交回调（对标 _commitAdv：持久化 + 推送共享 Provider）
typedef ReaderFontPanelCommit = void Function(ReaderAdvancedConfig config);

/// Tt 行内字体面板（阅读界面弹层「全局」页 Tt 小卡展开后的行内区域）
///
/// [C3 形态对齐 | full-stack-engineer + UI] 对齐参考版行内面板形态：
/// 正文字体（选择字体入口）/ 正文字距 / 首行缩进 / 标题字体（跟随正文，
/// 受阻项诚实标注）/ 字重 / 简繁转换。全部控件绑定既有配置字段与持久化链路
/// （ReaderAdvancedConfig / SharedPreferences / 简繁 FFI）；「斜体」不在原版，
/// 按红线不放入面板。
class ReaderFontPanel extends ConsumerStatefulWidget {
  /// 当前高级配置快照（面板修改后经 [onChanged] 回传，主 Sheet 负责提交）
  final ReaderAdvancedConfig config;

  /// 配置变更提交（持久化 + 推送共享 Provider，对标 _commitAdv）
  final ReaderFontPanelCommit? onChanged;

  /// 正文重载回调（简繁转换后重新加载当前章，对标原版 postEvent UP_CONFIG[5]）
  final VoidCallback? onReload;

  const ReaderFontPanel({
    super.key,
    required this.config,
    this.onChanged,
    this.onReload,
  });

  @override
  ConsumerState<ReaderFontPanel> createState() => _ReaderFontPanelState();
}

class _ReaderFontPanelState extends ConsumerState<ReaderFontPanel> {
  /// 面板内可编辑配置副本（提交经 onChanged 回传主 Sheet）
  late ReaderAdvancedConfig _config;

  /// 当前正文字体显示名（与 FontScreen 持久化键 reader_font_family 同步，
  /// 读取方式对标 reader_config_panel._loadFontLabel）
  String _fontLabel = '默认字体';

  /// 简繁转换类型（0=不转换 1=繁转简 2=简转繁，
  /// 对标原版 AppConfig.chineseConverterType / FFI setChineseConvertType）
  int _convertType = 0;

  @override
  void initState() {
    super.initState();
    _config = widget.config.copy();
    unawaited(_loadFontLabel());
    unawaited(_loadConvertType());
  }

  @override
  void didUpdateWidget(covariant ReaderFontPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 主 Sheet 重建（如切主题分桶重载）时同步外部配置快照
    if (oldWidget.config != widget.config) {
      _config = widget.config.copy();
    }
  }

  /// 从 SharedPreferences 读取当前阅读字体显示名
  Future<void> _loadFontLabel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString('reader_font_family');
      if (!mounted || family == null) return;
      setState(() => _fontLabel = family.replaceFirst('Custom_', ''));
    } catch (_) {
      // 读取失败保持默认字体标签
    }
  }

  /// 从 FFI 读取当前简繁转换类型（不可用时保持不转换）
  Future<void> _loadConvertType() async {
    try {
      final type = await ref.read(bookApiProvider).getChineseConvertType();
      if (!mounted) return;
      setState(() => _convertType = type.clamp(0, 2));
    } catch (_) {
      // FFI 不可用时保持不转换
    }
  }

  /// 提交配置（持久化 + 共享 Provider 推送）
  void _commit() {
    widget.onChanged?.call(_config.copy());
  }

  /// 面板卡片容器（圆角 20，与主 Sheet _panelCard 视觉一致）
  Widget _card(Widget child) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  /// 面板内分组标题行
  Widget _sectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// 面板内跳转/选择行（标题 + 副标题 + 当前值 + chevron）
  Widget _row({
    required String title,
    String? subtitle,
    String? value,
    VoidCallback? onTap,
    bool disabled = false,
    IconData? leading,
  }) {
    return InkWell(
      onTap: disabled ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            if (leading != null) ...[
              Icon(
                leading,
                size: 20,
                color: disabled
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: disabled
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : null,
                        ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            if (value != null)
              Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: disabled
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.primary,
                    ),
              ),
            const SizedBox(width: 4),
            if (!disabled)
              Icon(Icons.chevron_right_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('字体', Icons.font_download_outlined),
          // ===== 正文字体 / 选择字体（既有字体管理页链路，不重写） =====
          _row(
            title: '选择字体',
            subtitle: '正文字体',
            value: _fontLabel,
            leading: Icons.text_fields_outlined,
            onTap: () async {
              await Navigator.pushNamed(context, AppRoutes.fonts);
              if (!mounted) return;
              // 返回后重读字体标签并通知主 Sheet 推送共享配置
              // （ReaderPageView.didUpdateWidget 重读字体配置）
              await _loadFontLabel();
              _commit();
            },
          ),
          // ===== 正文字距（对标原版 dsb_text_letter_spacing，
          // letterSpacing em -0.5~1.0，(p-50)/100 语义） =====
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              children: [
                Text('正文字距', style: Theme.of(context).textTheme.bodyMedium),
                Expanded(
                  child: Slider(
                    value: _config.letterSpacing.clamp(-0.5, 1.0),
                    min: -0.5,
                    max: 1.0,
                    divisions: 75,
                    label: _config.letterSpacing.toStringAsFixed(2),
                    onChanged: (v) {
                      _config.letterSpacing = v;
                      _commit();
                      setState(() {});
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    _config.letterSpacing.toStringAsFixed(2),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
          // ===== 首行缩进（对标原版 tv_text_indent，5 档 无/一/二/三/四字符；
          // 我方既有字段 paragraphIndent 档位 0-3，按我方取值范围取前 4 档） =====
          _row(
            title: '首行缩进',
            value: _indentLabel(_config.paragraphIndent),
            onTap: () => _showChoiceDialog(
              title: '首行缩进',
              current: _config.paragraphIndent,
              options: const {
                0: '无缩进',
                1: '一字符',
                2: '二字符',
                3: '三字符',
              },
              onPick: (v) {
                _config.paragraphIndent = v;
                _commit();
                setState(() {});
              },
            ),
          ),
          // ===== 标题字体（对标原版 #1072 titleFont：空值=跟随正文字体） =====
          // [受阻项 | C3] 我方暂无独立标题字体配置字段（ReaderAdvancedConfig
          // 无 titleFont；Rust 阅读配置 'font' 亦未分正文/标题），按任务约束
          // 不新增数据链，仅保留跟随语义的诚实标注行。
          _row(
            title: '标题字体',
            subtitle: '独立标题字体设置未支持（待配置字段/FFI 对齐后开放）',
            value: '跟随正文',
            disabled: true,
          ),
          // ===== 斜体：不实施（重构红线）=====
          // [C3 核实结论] 参考版行内面板含「斜体」开关，但开源版源码与
          // ReadBookConfig 全仓无斜体配置字段（参考版自有增强）。按项目红线
          // （禁止新增原版不存在功能）不放入面板；若后续原版对齐放开，
          // 需新增配置字段并贯通分页/渲染参数（见 docs 建议文档受阻项登记）。
          // ===== 字重（对标原版 TextFontWeightConverter：0中/1粗/2细，
          // 既有字段 ReaderAdvancedConfig.textBold） =====
          Row(
            children: [
              Text('字重', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 16),
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('中')),
                    ButtonSegment(value: 1, label: Text('粗')),
                    ButtonSegment(value: 2, label: Text('细')),
                  ],
                  selected: {_config.textBold.clamp(0, 2)},
                  onSelectionChanged: (sel) {
                    _config.textBold = sel.first;
                    _commit();
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
          // ===== 简繁转换（对标原版 ChineseConverter：
          // 0关闭/1繁转简/2简转繁；既有 FFI setChineseConvertType/
          // getChineseConvertType，契约 §2.9） =====
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Text('简繁转换', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('关闭')),
                      ButtonSegment(value: 1, label: Text('繁→简')),
                      ButtonSegment(value: 2, label: Text('简→繁')),
                    ],
                    selected: {_convertType},
                    onSelectionChanged: (sel) => _onConvertTypeChanged(sel.first),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 缩进档位显示文案（对标 reader_config_panel._indentLabel）
  String _indentLabel(int v) {
    const labels = ['无缩进', '一字符', '二字符', '三字符'];
    if (v < 0 || v >= labels.length) return '二字符';
    return labels[v];
  }

  /// 单选对话框（对标原版 selector 交互，形态与既有面板一致）
  void _showChoiceDialog<T>({
    required String title,
    required T current,
    required Map<T, String> options,
    required ValueChanged<T> onPick,
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          for (final entry in options.entries)
            ListTile(
              title: Text(entry.value),
              trailing: current == entry.key
                  ? Icon(Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(dialogContext);
                onPick(entry.key);
              },
            ),
        ],
      ),
    );
  }

  /// 简繁转换类型变更：写 FFI 持久化并重载当前章正文
  /// （对标原版 postEvent UP_CONFIG[5] → ReadBook.loadContent）
  Future<void> _onConvertTypeChanged(int type) async {
    setState(() => _convertType = type);
    try {
      await ref.read(bookApiProvider).setChineseConvertType(type);
      // 转换类型变更后重新加载当前章正文
      widget.onReload?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('简繁转换设置失败: $e')),
        );
      }
    }
  }
}
