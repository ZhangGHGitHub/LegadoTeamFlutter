// 分享口令生成对话框（批25）
//
// 对齐 Android 原版 `SourceSharePassphraseDialog.kt` 的交互形态：
// 生成后展示可编辑/可复制的口令文本，用户确认后复制到剪贴板。
//
// 差异登记（用户 2026-10-27 授权）：原版「复制口令」使用直链上传规则里的
// `expiryDate`（配置在设置页），本项目直链规则已按参考版口径冻结为 4 字段
// （不含 expiryDate，见 direct_link_upload_rule_service.dart），故改为在
// 本对话框内输入有效期天数，默认 0 = 永久，范围 0..36500。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/source_share_passphrase.dart';

/// 弹出「复制口令」对话框
///
/// [url] 必须是可编码的 http(s) 直链（调用方先经
/// [SourceSharePassphrase.canEncode] 判定；不可编码时不展示入口）。
Future<void> showSourceSharePassphraseDialog(
  BuildContext context, {
  required String url,
  required SourcePassphraseType type,
  int initialExpiryDays = 0,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SourceSharePassphraseDialog(
      url: url,
      type: type,
      initialExpiryDays: initialExpiryDays,
    ),
  );
}

/// 口令生成对话框
class SourceSharePassphraseDialog extends StatefulWidget {
  const SourceSharePassphraseDialog({
    super.key,
    required this.url,
    required this.type,
    this.initialExpiryDays = 0,
  });

  /// 分享 URL（直链上传返回的下载地址）
  final String url;

  /// 源类型
  final SourcePassphraseType type;

  /// 初始有效期天数（默认 0 = 永久）
  final int initialExpiryDays;

  @override
  State<SourceSharePassphraseDialog> createState() =>
      _SourceSharePassphraseDialogState();
}

class _SourceSharePassphraseDialogState
    extends State<SourceSharePassphraseDialog> {
  late final TextEditingController _expiryController;
  Timer? _copiedTimer;
  String? _passphrase;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialExpiryDays
        .clamp(0, SourceSharePassphrase.maxExpiryDays);
    _expiryController = TextEditingController(text: '$initial');
    _regenerate(initial, notify: false);
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _expiryController.dispose();
    super.dispose();
  }

  /// 按当前输入重算口令；[notify] 为 false 时用于 initState
  void _regenerate(int? days, {bool notify = true}) {
    void apply() {
      if (days == null) {
        _error = '请输入有效期天数';
        _passphrase = null;
        return;
      }
      if (days < 0 || days > SourceSharePassphrase.maxExpiryDays) {
        _error = '有效期需为 0~${SourceSharePassphrase.maxExpiryDays} 天';
        _passphrase = null;
        return;
      }
      _error = null;
      _passphrase = SourceSharePassphrase.encode(
        url: widget.url,
        type: widget.type,
        expiryDays: days,
      );
    }

    if (notify) {
      setState(() {
        _copied = false;
        apply();
      });
    } else {
      apply();
    }
  }

  void _onExpiryChanged(String raw) {
    _regenerate(int.tryParse(raw.trim()));
  }

  Future<void> _copy() async {
    final passphrase = _passphrase;
    if (passphrase == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: passphrase));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '复制失败：$e');
      return;
    }
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() {
      _copied = true;
      _error = null;
    });
    // 内联提示 2 秒后恢复，不使用可能被弹层遮挡的 SnackBar
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final passphrase = _passphrase;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Symbols.key_rounded, size: 22),
          SizedBox(width: 8),
          Text('复制口令'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _expiryController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '有效期（天）',
                  helperText: '0 表示永久有效，最长 '
                      '${SourceSharePassphrase.maxExpiryDays} 天',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onChanged: _onExpiryChanged,
              ),
              const SizedBox(height: 16),
              Text('口令', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  passphrase ?? '—',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontFamily: 'Menlo',
                    fontFamilyFallback: ['Consolas', 'monospace'],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '口令包含分享直链，仅发送给可信的人；过期后无法导入。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (_copied) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      Symbols.check_circle_rounded,
                      size: 18,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '已复制到剪贴板',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: passphrase == null ? null : _copy,
          icon: Icon(
            _copied ? Symbols.check_rounded : Symbols.content_copy_rounded,
            size: 18,
          ),
          label: Text(_copied ? '已复制' : '复制口令'),
        ),
      ],
    );
  }
}
