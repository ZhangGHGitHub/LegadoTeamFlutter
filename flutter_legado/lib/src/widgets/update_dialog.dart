import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';

/// 更新说明 Dialog（对齐 UpdateDialog：版本号 / 日志 / 下载 / 忽略）
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateInfo info,
  required AppUpdateService service,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _UpdateDialog(info: info, service: service),
  );
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.info, required this.service});

  final AppUpdateInfo info;
  final AppUpdateService service;

  Future<void> _open(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBackup = info.backupDownloadUrl != null &&
        info.backupDownloadUrl!.isNotEmpty;

    return AlertDialog(
      title: Text(info.tagName),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(
            info.updateLog.trim().isEmpty ? '（无更新说明）' : info.updateLog,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await service.setIgnored(info.tagName);
            if (context.mounted) {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已忽略此版本')),
              );
            }
          },
          child: const Text('忽略此版本'),
        ),
        if (hasBackup)
          TextButton(
            onPressed: () => _open(info.backupDownloadUrl),
            child: const Text('备用下载'),
          ),
        TextButton(
          onPressed: () => _open(
            (info.backupDownloadUrl != null &&
                    info.backupDownloadUrl!.isNotEmpty)
                ? info.backupDownloadUrl
                : info.downloadUrl,
          ),
          child: const Text('浏览器打开'),
        ),
        FilledButton(
          onPressed: () async {
            await _open(info.downloadUrl);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('下载'),
        ),
      ],
    );
  }
}
