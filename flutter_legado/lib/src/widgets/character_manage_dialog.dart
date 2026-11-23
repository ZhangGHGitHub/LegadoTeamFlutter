// 角色卡管理对话框（R42 阶段 2A，契约 §2.56）
//
// 参考版形态：书籍编辑页 `BookInfoEditScreen.kt:223` 的 `BookKnowledgeEditCard`
// 提供「人物」入口 → 人物列表页（新建 FAB + 列表 + 编辑 + 删除）。
// 2A 只做**手动建档最小闭环**，故把「列表 + 新增 + 编辑 + 删除」收敛进本对话框，
// 不新建独立页面（5 个知识/关系页面明确不在本轮范围）。
//
// 数据链路：`BookApi.getBookCharacters` / `saveBookCharacter` /
// `deleteBookCharacter`（契约 §2.56）。JSON 解析复用
// `providers/book_info/characters_provider.dart::parseBookCharactersJson`，
// 保存时由 `BookCharacter.toProfileJson()` 产出 camelCase 对象。
//
// 保存后 `ref.invalidate(bookCharactersProvider(bookUrl))` 让详情页角色区块
// 立即刷新（详情页与编辑页可能同时存在于导航栈）。
//
// 已知差异（用户裁决 D4=A / D5=A，照抄参考版）：换源后角色不迁移、不纳入
// 备份、删书不清理孤儿行。
//
// 编写：全栈工程师 ｜ 2026-11-23
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/book_info/characters_provider.dart';
import '../providers/providers.dart';
import '../utils/error_message.dart';

// TODO(l10n): 本轮按约束不改 app_strings.dart；以下文案待 AppStrings 补 key 后替换
// （清单见交付汇报）。
const String _title = '角色管理';
const String _addTitle = '新增角色';
const String _editTitle = '编辑角色';
const String _nameLabel = '角色名';
const String _nameRequired = '请输入角色名';
const String _roleLabel = '定位';
const String _roleUnset = '未设置';
const String _aliasesLabel = '别名';
const String _aliasesHint = '多个别名用「、」分隔';
const String _tagsLabel = '标签';
const String _tagsHint = '多个标签用「|」分隔';
const String _personalityLabel = '性格';
const String _summaryLabel = '简介';
const String _emptyHint = '还没有人物档案';
const String _loadFailed = '角色加载失败';
const String _saveFailed = '保存失败';
const String _deleteFailed = '删除失败';

/// 角色卡管理对话框
///
/// [bookUrl] 为书籍稳定主键（角色表以 bookUrl 为键，换源不迁移）。
class CharacterManageDialog extends ConsumerStatefulWidget {
  /// 书籍稳定主键
  final String bookUrl;

  const CharacterManageDialog({super.key, required this.bookUrl});

  @override
  ConsumerState<CharacterManageDialog> createState() =>
      _CharacterManageDialogState();
}

class _CharacterManageDialogState extends ConsumerState<CharacterManageDialog> {
  List<BookCharacter>? _characters;
  bool _loading = true;
  bool _busy = false;
  bool _loadFailedFlag = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailedFlag = false;
    });
    try {
      final raw = await ref
          .read(bookApiProvider)
          .getBookCharacters(bookUrl: widget.bookUrl, limit: 50);
      final parsed = parseBookCharactersJson(raw);
      if (!mounted) return;
      setState(() {
        _characters = parsed;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[角色卡] 管理对话框加载失败：$e');
      if (!mounted) return;
      setState(() {
        _characters = const [];
        _loading = false;
        _loadFailedFlag = true;
      });
    }
  }

  /// 打开新增/编辑表单；返回 null 表示用户取消
  Future<void> _openEditor([BookCharacter? initial]) async {
    final result = await showDialog<BookCharacter>(
      context: context,
      builder: (_) =>
          _CharacterEditDialog(bookUrl: widget.bookUrl, initial: initial),
    );
    if (result == null || !mounted) return;
    await _save(result);
  }

  Future<void> _save(BookCharacter character) async {
    setState(() => _busy = true);
    try {
      final profileJson = jsonEncode(character.toProfileJson());
      await ref
          .read(bookApiProvider)
          .saveBookCharacter(profileJson: profileJson);
      // 详情页角色区块立即刷新（编辑页与详情页可能同时在导航栈）
      ref.invalidate(bookCharactersProvider(widget.bookUrl));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$_saveFailed：${errorMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete(BookCharacter character) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('确定删除角色「${character.name}」？'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(bookApiProvider)
          .deleteBookCharacter(
            bookUrl: widget.bookUrl,
            characterId: character.id,
          );
      ref.invalidate(bookCharactersProvider(widget.bookUrl));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$_deleteFailed：${errorMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ts = Theme.of(context).textTheme;
    final characters = _characters ?? const <BookCharacter>[];
    return AlertDialog(
      title: Text(_title),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 360,
        height: 380,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_loadFailedFlag)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: Text(
                        _loadFailed,
                        style: ts.bodySmall?.copyWith(color: cs.error),
                      ),
                    ),
                  if (characters.isEmpty)
                    Expanded(
                      child: Center(
                        child: Text(
                          _emptyHint,
                          style: ts.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: characters.length,
                        itemBuilder: (context, index) {
                          final c = characters[index];
                          return ListTile(
                            dense: true,
                            leading: const Icon(
                              Symbols.person_rounded,
                              size: 24,
                            ),
                            title: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: _subtitleOf(c),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: _editTitle,
                                  onPressed: _busy
                                      ? null
                                      : () => _openEditor(c),
                                  icon: const Icon(
                                    Symbols.edit_rounded,
                                    size: 20,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  onPressed: _busy
                                      ? null
                                      : () => _confirmDelete(c),
                                  icon: Icon(
                                    Symbols.delete_rounded,
                                    size: 20,
                                    color: cs.error,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : () => _openEditor(),
          icon: const Icon(Symbols.add_rounded, size: 18),
          label: const Text(_addTitle),
        ),
      ],
    );
  }

  /// 列表副标题：角色中文 + 标签（均可能为空）
  Widget? _subtitleOf(BookCharacter c) {
    final parts = <String>[
      if (c.roleLabel.isNotEmpty) c.roleLabel,
      if (c.tagsText.isNotEmpty) c.tagsText,
    ];
    if (parts.isEmpty) return null;
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 角色新增/编辑表单（返回 [BookCharacter]，取消返回 null）
class _CharacterEditDialog extends StatefulWidget {
  final String bookUrl;
  final BookCharacter? initial;

  const _CharacterEditDialog({required this.bookUrl, this.initial});

  @override
  State<_CharacterEditDialog> createState() => _CharacterEditDialogState();
}

class _CharacterEditDialogState extends State<_CharacterEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _aliasesCtrl;
  late final TextEditingController _tagsCtrl;
  late final TextEditingController _personalityCtrl;
  late final TextEditingController _summaryCtrl;
  late String _role;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameCtrl = TextEditingController(text: initial?.name ?? '');
    _aliasesCtrl = TextEditingController(text: initial?.aliasesText ?? '');
    _tagsCtrl = TextEditingController(text: initial?.tagsText ?? '');
    _personalityCtrl = TextEditingController(text: initial?.personality ?? '');
    _summaryCtrl = TextEditingController(text: initial?.summary ?? '');
    _role = initial?.role ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _aliasesCtrl.dispose();
    _tagsCtrl.dispose();
    _personalityCtrl.dispose();
    _summaryCtrl.dispose();
    super.dispose();
  }

  /// 别名分隔：中英文顿号/逗号/分号/竖线
  static final RegExp _aliasSplit = RegExp(r'[、,，;；|]');

  /// 标签分隔：竖线/顿号/逗号
  static final RegExp _tagSplit = RegExp(r'[|、,，]');

  List<String> _split(String raw, RegExp pattern) => raw
      .split(pattern)
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = _nameRequired);
      return;
    }
    final initial = widget.initial;
    final character = BookCharacter(
      // 编辑保留 id（Rust 按 id 覆盖；空 id 走 (bookUrl,name) 查重）
      id: initial?.id ?? '',
      bookUrl: widget.bookUrl,
      name: name,
      aliases: _split(_aliasesCtrl.text, _aliasSplit),
      avatarUri: initial?.avatarUri,
      tags: _split(_tagsCtrl.text, _tagSplit),
      role: _role,
      personality: _personalityCtrl.text.trim(),
      summary: _summaryCtrl.text.trim(),
      status: initial?.status ?? 1,
      updatedAt: initial?.updatedAt ?? 0,
    );
    Navigator.pop(context, character);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? _addTitle : _editTitle),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _nameLabel,
                  errorText: _nameError,
                ),
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: _roleLabel),
                items: const [
                  DropdownMenuItem(value: '', child: Text(_roleUnset)),
                  DropdownMenuItem(value: 'male_lead', child: Text('男主')),
                  DropdownMenuItem(value: 'female_lead', child: Text('女主')),
                  DropdownMenuItem(value: 'male_supporting', child: Text('男配')),
                  DropdownMenuItem(
                    value: 'female_supporting',
                    child: Text('女配'),
                  ),
                ],
                onChanged: (v) => setState(() => _role = v ?? ''),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _aliasesCtrl,
                decoration: const InputDecoration(
                  labelText: _aliasesLabel,
                  hintText: _aliasesHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tagsCtrl,
                decoration: const InputDecoration(
                  labelText: _tagsLabel,
                  hintText: _tagsHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _personalityCtrl,
                decoration: const InputDecoration(labelText: _personalityLabel),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _summaryCtrl,
                decoration: const InputDecoration(
                  labelText: _summaryLabel,
                  alignLabelWithHint: true,
                ),
                minLines: 2,
                maxLines: 5,
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
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
