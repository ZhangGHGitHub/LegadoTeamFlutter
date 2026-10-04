import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/audio/http_tts_seed.dart';
import '../providers/providers.dart';
import '../widgets/app_progress_indicator.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';

/// 朗读引擎配置页面
///
/// 管理 HTTP TTS 朗读引擎：列表展示、新增、编辑、删除。
class ReadAloudConfigScreen extends ConsumerStatefulWidget {
  const ReadAloudConfigScreen({super.key});

  @override
  ConsumerState<ReadAloudConfigScreen> createState() => _ReadAloudConfigScreenState();
}

class _ReadAloudConfigScreenState extends ConsumerState<ReadAloudConfigScreen> {
  List<HttpTts> _engines = [];
  bool _loading = true;

  /// 当前选中引擎（归一后的裸 URL）；null = 未选中任何引擎
  ///
  /// 行点击只更新选中态（对齐原版 SpeakEngineDialog.kt:315-326 的 upTts：
  /// 仅对话框内选中，不持久化）；持久化由底部「书」/「全局」按钮显式触发
  /// （SpeakEngineDialog.kt:164-177）。
  String? _selectedUrl;

  /// 是否存在可写书级的当前书（「书」按钮可用性；无书时禁用）
  bool _hasBook = false;

  @override
  void initState() {
    super.initState();
    _loadEngines();
  }

  Future<void> _loadEngines() async {
    setState(() => _loading = true);
    try {
      final api = ref.read(bookApiProvider);
      // [D3 | 2026-10-03] 首启导入原版 httpTTS 种子（版本门控），
      // 与 dict/rss/txtToc 对齐：进入配置页即可见默认数据
      await ensureDefaultHttpTts(api);
      final list = await api.getHttpTts();
      final notifier = ref.read(audioNotifierProvider.notifier);
      // [引擎双持久化 | 2026-10-04] 初始选中态 = 有效引擎（书级优先、空则
      // 全局回退），对齐原版对话框 `ttsEngine = ReadAloud.ttsEngine`；
      // 有效值已不在引擎列表中（被删/失效）时不选中，避免把失效 URL 再写回。
      final effective = await notifier.loadEffectiveTtsEngineUrl();
      final listedUrls =
          list.map((e) => normalizeTtsEngineUrl(e.url)).toSet();
      setState(() {
        _engines = list;
        _selectedUrl =
            effective.isNotEmpty && listedUrls.contains(effective)
                ? effective
                : null;
        _hasBook = notifier.hasCurrentBook;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载朗读引擎失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteEngine(HttpTts engine) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(bookApiProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除朗读引擎'),
        content: Text('确定要删除「${engine.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await api.deleteHttpTts(engine.id);
      await _loadEngines();
      messenger.showSnackBar(
        const SnackBar(content: Text('已删除')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }

  Future<void> _addOrEditEngine([HttpTts? existing]) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(bookApiProvider);

    final result = await showDialog<HttpTts>(
      context: context,
      builder: (ctx) => _TtsEditDialog(engine: existing),
    );

    if (result == null) return;

    try {
      if (existing != null) {
        // 编辑：先删后加
        await api.deleteHttpTts(existing.id);
      }
      await api.addHttpTts(result);
      await _loadEngines();
      messenger.showSnackBar(
        SnackBar(content: Text(existing != null ? '已更新' : '已添加')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  /// 「书」按钮：只写当前书 readConfig.ttsEngine
  ///
  /// 对齐原版 SpeakEngineDialog.kt:164-170（`ReadBook.book?.setTtsEngine(...)`，
  /// 不改全局值）；无当前书时不写并如实提示（原版空安全 no-op，本项目页面
  /// 需要可见反馈）。
  Future<void> _applyBookEngine() async {
    final url = _selectedUrl;
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok =
        await ref.read(audioNotifierProvider.notifier).setBookTtsEngine(url);
    if (!mounted) return;
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('未打开书籍，无法设为本书引擎')),
      );
      return;
    }
    setState(() => _hasBook = true);
    messenger.showSnackBar(const SnackBar(content: Text('已设为本书引擎')));
  }

  /// 「全局」按钮：先清书级覆盖再写全局
  ///
  /// 对齐原版 SpeakEngineDialog.kt:171-177（`setTtsEngine(null)` +
  /// `AppConfig.ttsEngine = ttsEngine`）。
  Future<void> _applyGlobalEngine() async {
    final url = _selectedUrl;
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(audioNotifierProvider.notifier).setGlobalTtsEngine(url);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('已设为全局引擎')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: const Text('朗读引擎'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.help_rounded),
            tooltip: '帮助',
            onPressed: () => showHelp(context, HelpAssets.httpTtsHelp),
          ),
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: '刷新',
            onPressed: _loadEngines,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditEngine(),
        icon: const Icon(Symbols.add_rounded),
        label: const Text('添加引擎'),
      ),
      // [引擎双持久化 | 2026-10-04] 底部双按钮对齐原版 SpeakEngineDialog
      // 页脚（dialog_recycler_view.xml:94-141 左侧「书」/ 右侧「全局」）与
      // 文案（values-zh/strings.xml：book=书:264、general=全局:1207）。
      // 「取消」在页面形态下由系统返回承担，这里只呈现双持久化按钮。
      bottomBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              TextButton(
                onPressed: (_selectedUrl == null || !_hasBook)
                    ? null
                    : _applyBookEngine,
                child: const Text('书'),
              ),
              const Spacer(),
              TextButton(
                onPressed: _selectedUrl == null ? null : _applyGlobalEngine,
                child: const Text('全局'),
              ),
            ],
          ),
        ),
      ),
      body: _loading
          // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
          ? const Center(child: AppCircularProgressIndicator())
          : _engines.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Symbols.record_voice_over_rounded,
                          size: 64, color: theme.colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(
                        '暂无朗读引擎',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '点击右下角按钮添加 HTTP TTS 引擎',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                )
              // [LAYOUT_PLAN P1] 本页无开关行（SwitchListTile），无需 showChevron；
              // 引擎行无箭头（仅编辑/删除动作）；卡片分组间距 12dp
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _engines.length,
                  itemBuilder: (context, index) {
                    final engine = _engines[index];
                    final engineUrl = normalizeTtsEngineUrl(engine.url);
                    final isSelected =
                        _selectedUrl != null && engineUrl == _selectedUrl;
                    return Card(
                      // [LAYOUT_PLAN P1] 分组间距 12dp
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        // [引擎双持久化 | 2026-10-04] 行点击仅更新选中态
                        // （对齐原版 SpeakEngineDialog.kt:315-326 的 upTts：
                        // 不持久化、不关闭），持久化交底部「书」/「全局」。
                        selected: isSelected,
                        onTap: () =>
                            setState(() => _selectedUrl = engineUrl),
                        // 选中控件对齐原版行布局的 ThemeRadioButton
                        // （item_http_tts.xml:14-20），替代纯装饰性头像
                        leading: Icon(
                          isSelected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: isSelected ? theme.colorScheme.primary : null,
                        ),
                        title: Text(
                          engine.name,
                          // [LAYOUT_PLAN P1] 列表行字级走 M3 Type Scale
                          style: theme.textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          engine.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // [LAYOUT_PLAN P1] 列表行字级走 M3 Type Scale
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Symbols.edit_rounded, size: 20),
                              tooltip: '编辑',
                              onPressed: () => _addOrEditEngine(engine),
                            ),
                            IconButton(
                              icon: Icon(Symbols.delete_rounded,
                                  size: 20, color: theme.colorScheme.error),
                              tooltip: '删除',
                              onPressed: () => _deleteEngine(engine),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// TTS 引擎编辑对话框
class _TtsEditDialog extends StatefulWidget {
  final HttpTts? engine;

  const _TtsEditDialog({this.engine});

  @override
  State<_TtsEditDialog> createState() => _TtsEditDialogState();
}

class _TtsEditDialogState extends State<_TtsEditDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _headerCtrl;
  late TextEditingController _contentTypeCtrl;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final e = widget.engine;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _urlCtrl = TextEditingController(text: e?.url ?? '');
    _headerCtrl = TextEditingController(text: e?.header ?? '');
    _contentTypeCtrl = TextEditingController(text: e?.contentType ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _headerCtrl.dispose();
    _contentTypeCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final tts = HttpTts(
      id: widget.engine?.id ?? 0,
      name: _nameCtrl.text.trim(),
      url: _urlCtrl.text.trim(),
      header: _headerCtrl.text.trim().isNotEmpty ? _headerCtrl.text.trim() : null,
      contentType: _contentTypeCtrl.text.trim().isNotEmpty
          ? _contentTypeCtrl.text.trim()
          : null,
    );

    Navigator.pop(context, tts);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.engine != null ? '编辑朗读引擎' : '添加朗读引擎'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '名称 *',
                  hintText: '例如：Edge TTS',
                  isDense: true,
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'URL *',
                  hintText: 'http://localhost:1234/tts?text={{text}}',
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入 URL';
                  if (!v.trim().startsWith('http')) return 'URL 必须以 http(s) 开头';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _contentTypeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Content-Type',
                  hintText: '可选，例如 audio/mpeg',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _headerCtrl,
                decoration: const InputDecoration(
                  labelText: '请求头 (JSON)',
                  hintText: '可选，例如 {"Authorization":"Bearer xxx"}',
                  isDense: true,
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
