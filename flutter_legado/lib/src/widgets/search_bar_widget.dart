import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 搜索栏组件 — 带清除按钮和提交回调的搜索栏
class SearchBarWidget extends StatefulWidget {
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  final VoidCallback? onSubmit;

  const SearchBarWidget({
    super.key,
    this.hintText = '搜索',
    required this.onChanged,
    this.onClear,
    this.onSubmit,
  });

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleClear() {
    _controller.clear();
    widget.onChanged('');
    widget.onClear?.call();
  }

  void _handleSubmit(String value) {
    widget.onSubmit?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          Icon(Symbols.search_rounded, size: 20, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: widget.onChanged,
              onSubmitted: _handleSubmit,
              decoration: InputDecoration(
                hintText: widget.hintText,
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          if (_hasText)
            IconButton(
              icon: const Icon(Symbols.close_rounded, size: 20),
              onPressed: _handleClear,
              color: colorScheme.onSurfaceVariant,
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}
