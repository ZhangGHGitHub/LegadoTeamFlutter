// 批11：远端备份文件列表 Sheet（网络恢复入口）
//
// 对齐参考版 `WebDavManager.kt:133-164`：列出远端 `backup` 前缀文件，
// **按名称降序**（时间序即名称序），每项显示名称与最后修改时间；选中返回
// 候选，点遮罩/返回键返回 null。
//
// 空列表在 Sheet 内也有「未找到远端备份」兜底（正常由调用方先判空并提示，
// 此处防御并发清空/数据竞态）。
import 'package:flutter/material.dart';

import '../services/webdav_backup_candidates.dart';
import 'ios_widgets.dart';

/// 展示远端备份列表
///
/// [candidates] 应已按名称降序排好（由
/// `WebDavBackupService.listRemoteBackups` 提供）；本组件不再二次排序，
/// 保持「数据层排序、视图层只渲染」的单一职责。
Future<RemoteBackupCandidate?> showRemoteBackupListSheet({
  required BuildContext context,
  required List<RemoteBackupCandidate> candidates,
}) {
  return showModalBottomSheet<RemoteBackupCandidate>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: IosGrabber()),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  '选择远端备份',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text('未找到远端备份'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      return IosListTile(
                        icon: Icons.cloud_outlined,
                        title: candidate.name,
                        subtitle: formatRemoteBackupTime(
                          candidate.lastModifiedMillis,
                        ),
                        onTap: () => Navigator.of(context).pop(candidate),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// 远端备份最后修改时间展示（`yyyy-MM-dd HH:mm`，本地时区）
///
/// 单独导出便于单测断言格式，避免在 widget 测试里硬编码字符串拼接。
String formatRemoteBackupTime(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year.toString().padLeft(4, '0')}-'
      '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
