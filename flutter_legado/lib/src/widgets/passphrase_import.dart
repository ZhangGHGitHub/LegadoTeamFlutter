// 分享口令导入入口（批25）
//
// 对齐 Android 原版 MainActivity 的口令自动读取链路（decode → 按类型路由
// 到各 ImportXxxDialog），但按用户 2026-10-27 要求**不做自动读剪贴板**
// （隐私）：改为用户主动点击「口令导入」菜单后读取剪贴板。
//
// 路由复用既有「关联导入」对话框（showAssociationImportDialog）：
// 传入解码 URL + 类型提示，由对话框拉取、逐条展示候选并要求用户确认，
// 因此「成功前确认」由既有导入确认流程承担。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/association/association_state.dart';
import '../screens/association_import_dialog.dart';
import '../services/source_share_passphrase.dart';

/// 从剪贴板读取并导入分享口令（用户主动触发）
Future<void> importPassphraseFromClipboard(BuildContext context) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text?.trim() ?? '';
  if (!context.mounted) return;
  if (text.isEmpty) {
    await _showMessage(
      context,
      title: '剪贴板为空',
      message: '请先复制分享口令（以「${SourceSharePassphrase.prefix}」开头）。',
    );
    return;
  }
  await importPassphraseText(context, text);
}

/// 解码 [text] 并按类型打开关联导入确认框
///
/// 失败分支给出明确中文提示；成功分支进入既有导入确认流程。
Future<void> importPassphraseText(BuildContext context, String text) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  final result = SourceSharePassphrase.decode(trimmed);
  switch (result) {
    case SourcePassphraseSuccess(:final value):
      await showAssociationImportDialog(
        context,
        url: value.url,
        type: passphraseImportType(value.type),
      );
    case SourcePassphraseNotFound():
      await _showMessage(
        context,
        title: '不是分享口令',
        message: '未识别到「${SourceSharePassphrase.prefix}」前缀，请确认已完整复制。',
      );
    case SourcePassphraseInvalid():
      await _showMessage(
        context,
        title: '口令无效',
        message: '口令格式或分享链接无效，可能复制不完整，请重新复制。',
      );
    case SourcePassphraseExpired():
      await _showMessage(
        context,
        title: '口令已过期',
        message: '该口令已超过分享有效期，请联系分享者重新生成。',
      );
  }
}

/// 口令类型 → 关联导入类型
ImportType passphraseImportType(SourcePassphraseType type) => switch (type) {
      SourcePassphraseType.bookSource => ImportType.bookSource,
      SourcePassphraseType.rssSource => ImportType.rssSource,
      SourcePassphraseType.dictRule => ImportType.dictRule,
      SourcePassphraseType.replaceRule => ImportType.replaceRule,
      SourcePassphraseType.tocRule => ImportType.txtTocRule,
      SourcePassphraseType.ttsRule => ImportType.httpTts,
      SourcePassphraseType.autoTask => ImportType.autoTask,
    };

Future<void> _showMessage(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
