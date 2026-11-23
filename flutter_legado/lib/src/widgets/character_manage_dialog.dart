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

import '../l10n/app_strings.dart';
import '../providers/book_info/characters_provider.dart';
import '../providers/providers.dart';
import '../utils/error_message.dart';

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
        SnackBar(
          content: Text(
            '${AppStrings.characterSaveFailed}：${errorMessage(e)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete(BookCharacter character) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(AppStrings.characterDeleteConfirm(character.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.delete),
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
        SnackBar(
          content: Text(
            '${AppStrings.characterDeleteFailed}：${errorMessage(e)}',
          ),
        ),
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
      title: Text(AppStrings.characterManageTitle),
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
                        AppStrings.characterLoadFailed,
                        style: ts.bodySmall?.copyWith(color: cs.error),
                      ),
                    ),
                  if (characters.isEmpty)
                    Expanded(
                      child: Center(
                        child: Text(
                          AppStrings.characterEmptyHint,
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
                                  tooltip: AppStrings.characterEditTitle,
                                  onPressed: _busy
                                      ? null
                                      : () => _openEditor(c),
                                  icon: const Icon(
                                    Symbols.edit_rounded,
                                    size: 20,
                                  ),
                                ),
                                IconButton(
                                  tooltip: AppStrings.delete,
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
          child: Text(AppStrings.dialogClose),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : () => _openEditor(),
          icon: const Icon(Symbols.add_rounded, size: 18),
          label: Text(AppStrings.characterAddTitle),
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
      setState(() => _nameError = AppStrings.characterNameRequired);
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
      title: Text(
        widget.initial == null
            ? AppStrings.characterAddTitle
            : AppStrings.characterEditTitle,
      ),
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
                  labelText: AppStrings.characterNameLabel,
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
                decoration: InputDecoration(
                  labelText: AppStrings.characterRoleLabel,
                ),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(AppStrings.characterRoleUnset),
                  ),
                  DropdownMenuItem(
                    value: 'male_lead',
                    child: Text(AppStrings.roleMaleLead),
                  ),
                  DropdownMenuItem(
                    value: 'female_lead',
                    child: Text(AppStrings.roleFemaleLead),
                  ),
                  DropdownMenuItem(
                    value: 'male_supporting',
                    child: Text(AppStrings.roleMaleSupporting),
                  ),
                  DropdownMenuItem(
                    value: 'female_supporting',
                    child: Text(AppStrings.roleFemaleSupporting),
                  ),
                ],
                onChanged: (v) => setState(() => _role = v ?? ''),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _aliasesCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.characterAliasesLabel,
                  hintText: AppStrings.characterAliasesHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tagsCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.characterTagsLabel,
                  hintText: AppStrings.characterTagsHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _personalityCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.characterPersonalityLabel,
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _summaryCtrl,
                decoration: InputDecoration(
                  labelText: AppStrings.characterSummaryLabel,
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
          child: Text(AppStrings.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(AppStrings.save)),
      ],
    );
  }
}
