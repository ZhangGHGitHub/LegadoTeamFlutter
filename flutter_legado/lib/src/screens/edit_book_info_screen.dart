import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/book_api.dart';
import '../widgets/book_cover.dart';

/// 书籍信息编辑页面
///
/// 对齐 Android 原版 BookInfoEditActivity：可编辑书名、作者、封面地址与简介。
/// 保存时调用 [BookApi.updateBook]，成功后返回 `true` 以便上一页刷新。
class EditBookInfoScreen extends ConsumerStatefulWidget {
  /// 待编辑的书籍对象
  final Book book;

  const EditBookInfoScreen({super.key, required this.book});

  @override
  ConsumerState<EditBookInfoScreen> createState() => _EditBookInfoScreenState();
}

class _EditBookInfoScreenState extends ConsumerState<EditBookInfoScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _authorCtrl;
  late final TextEditingController _coverCtrl;
  late final TextEditingController _introCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final book = widget.book;
    _nameCtrl = TextEditingController(text: book.name);
    _authorCtrl = TextEditingController(text: book.author);
    // 封面优先展示自定义封面，其次原始封面
    _coverCtrl = TextEditingController(
      text: book.customCoverUrl ?? book.coverUrl ?? '',
    );
    // 简介优先展示自定义简介，其次原始简介
    _introCtrl = TextEditingController(
      text: book.customIntro ?? book.intro ?? '',
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _authorCtrl.dispose();
    _coverCtrl.dispose();
    _introCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('书籍信息编辑'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.check_rounded, size: 18),
            label: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildHeader(context),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '书名',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '书名不能为空' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _authorCtrl,
              decoration: const InputDecoration(
                labelText: '作者',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _coverCtrl,
              decoration: const InputDecoration(
                labelText: '封面地址',
                hintText: '输入封面图片 URL',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _introCtrl,
              decoration: const InputDecoration(
                labelText: '简介',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              minLines: 4,
              maxLines: 10,
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部封面预览（对齐原版：左侧封面 + 右侧书名/作者）
  Widget _buildHeader(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BookCover(
          coverUrl: _coverCtrl.text.isNotEmpty ? _coverCtrl.text : null,
          width: 90,
          height: 130,
          borderRadius: 8,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '编辑书籍信息',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '修改后点击保存生效',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 保存书籍信息
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    try {
      final book = widget.book;
      final name = _nameCtrl.text.trim();
      final author = _authorCtrl.text.trim();
      final coverUrl = _coverCtrl.text.trim();
      final intro = _introCtrl.text.trim();

      // 对齐原版逻辑：与原始值相同时置空自定义字段，避免冗余覆盖
      final customCoverUrl =
          (coverUrl.isEmpty || coverUrl == book.coverUrl) ? null : coverUrl;
      final customIntro =
          (intro.isEmpty || intro == book.intro) ? null : intro;

      final updated = book.copyWith(
        name: name,
        author: author,
        customCoverUrl: customCoverUrl,
        customIntro: customIntro,
      );

      final api = ref.read(bookApiProvider);
      await api.updateBook(updated);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书籍信息已保存')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
      setState(() => _saving = false);
    }
  }
}
