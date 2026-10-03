import 'dart:async';

import 'package:flutter/material.dart';

/// [P4-3 E5] 长按页操作底栏（保存图片 / 分享图片 / 复制链接）
///
/// 对齐参考版 ui/book/manga/\MangaReaderSheets.kt L179-252
/// MangaReaderPageActionsSheet（单页项：save_image / share / copy_text /
/// set_cover；图标在上、标签在下，横排方形按钮）：
/// - 本波取「超集」中的三项：参考版 分享图片/复制图片 + 原版 保存图片；
/// - 参考版 设置封面 项未移植（无封面更新入口，见汇报「未做」项）；
/// - 宽页/双页 spread 变体（save/share/copy_spread）不在本波范围。
///
/// 动作执行由调用方通过回调注入（先关菜单再执行，对齐参考版
/// executePageAction 先 `activeSheet = null` 再 launchAction）。
///
/// [cbz 批 D | 2026-10-03] [onCopy] 可空：本地 cbz 页的「复制链接」对象是
/// `cbz://<条目名>` 伪 URL（非可消费链接），调用方传 null 隐藏该项。
class MangaPageActionsSheet extends StatelessWidget {
  final Future<void> Function() onSave;
  final Future<void> Function() onShare;
  final Future<void> Function()? onCopy;

  const MangaPageActionsSheet({
    super.key,
    required this.onSave,
    required this.onShare,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xF01A1A1A),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Row(
        children: [
          _tile(context, Icons.save, '保存图片', onSave),
          _tile(context, Icons.share, '分享图片', onShare),
          // [P4-3 W2-fix P2-4] 本实现复制的是图片链接文本（URI 复制降级），
          // 文案对齐实际行为：「复制链接」；onCopy 为 null（cbz 页）时隐藏
          if (onCopy != null)
            _tile(context, Icons.content_copy, '复制链接', onCopy!),
        ],
      ),
    );
  }

  /// 单个动作方块（对齐参考版 ReaderMenuActionSquare 图标在上、标签在下）
  Widget _tile(
    BuildContext context,
    IconData icon,
    String label,
    Future<void> Function() action,
  ) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          // 对齐参考版：先关闭底栏再执行动作
          Navigator.of(context).pop();
          unawaited(action());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: Colors.white70),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹出长按页操作底栏
///
/// [onSave] 保存图片（用户选目录写入，对齐原版）；
/// [onShare] 分享图片（系统分享面板，对齐参考版 share 临时文件）；
/// [onCopy] 复制链接（图片链接文本，参考版 URI 复制的降级实现）；
/// 为 null 时隐藏「复制链接」项（本地 cbz 页伪 URL 无消费价值）。
Future<void> showMangaPageActionsSheet(
  BuildContext context, {
  required Future<void> Function() onSave,
  required Future<void> Function() onShare,
  Future<void> Function()? onCopy,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => MangaPageActionsSheet(
      onSave: onSave,
      onShare: onShare,
      onCopy: onCopy,
    ),
  );
}
