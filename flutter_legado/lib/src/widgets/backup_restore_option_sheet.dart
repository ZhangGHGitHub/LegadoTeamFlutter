// 批11：备份/恢复选项 Sheet（对齐参考版 BackupRestoreOptionSheets.kt）
//
// 参考版语义：
// - 备份：行点击弹出三选（备份至本地 / 备份至网络 / 备份至本地与网络），
//   图标 PhoneAndroid / Cloud / Lan；**无取消按钮**，点遮罩或返回键关闭；
// - 恢复：参考版两项（本地恢复 / 网络恢复）。本仓库按用户裁决（2026-11-10）
//   增加「本地最新」「远端最新」两个快捷项（授权例外，已登记
//   `docs/REFACTORING_ACTIVE_PLAN.md` 设置批11），顺序固定在参考两项之后。
//
// 交互约定：
// - 选项禁用时不关闭 Sheet，只提示禁用原因（如未配置 WebDAV / 备份恢复忙）；
// - 备份/恢复进行中（`isBusy` 回调）在点按瞬间再次判定，避免 Sheet 打开后
//   自动备份/恢复启动导致并发写库。
import 'package:flutter/material.dart';

import 'ios_widgets.dart';

/// 备份方式（顺序即参考版展示顺序）
enum BackupOption {
  /// 备份至本地
  local,

  /// 备份至网络（WebDAV）
  webDav,

  /// 备份至本地与网络
  localAndWebDav,
}

/// 恢复方式（前两项对齐参考版；后两项为用户裁决新增快捷项）
enum RestoreOption {
  /// 本地恢复（文件选择器）
  localFile,

  /// 网络恢复（远端列表 → 选文件 → 下载覆盖本地）
  remoteFile,

  /// 本地最新（备份目录内最新 `legado_backup_<millis>.json`）
  latestLocal,

  /// 远端最新（WebDAV 上 mtime 最大的 `backup*` 文件）
  latestRemote,
}

/// 忙碌提示（与设置页既有文案一致）
const String kBackupRestoreBusyHint = '正在备份或恢复，请稍候';

/// WebDAV 未配置提示
const String kWebDavNotConfiguredHint = '请先配置 WebDAV';

/// 备份选项 Sheet
///
/// 返回用户选择；点遮罩/返回键返回 null（不执行任何操作）。
Future<BackupOption?> showBackupOptionSheet({
  required BuildContext context,
  required bool webDavConfigured,
  bool busy = false,
  bool Function()? isBusy,
}) {
  return _showOptionSheet<BackupOption>(
    context: context,
    title: '备份',
    busy: busy,
    isBusy: isBusy,
    options: [
      const _OptionEntry(
        value: BackupOption.local,
        icon: Icons.phone_android,
        label: '备份至本地',
      ),
      _OptionEntry(
        value: BackupOption.webDav,
        icon: Icons.cloud_outlined,
        label: '备份至网络',
        disabledReason: webDavConfigured ? null : kWebDavNotConfiguredHint,
      ),
      const _OptionEntry(
        value: BackupOption.localAndWebDav,
        icon: Icons.lan_outlined,
        label: '备份至本地与网络',
      ),
    ],
  );
}

/// 恢复选项 Sheet（四项：本地恢复 / 网络恢复 / 本地最新 / 远端最新）
///
/// 返回用户选择；点遮罩/返回键返回 null（不执行任何操作）。
Future<RestoreOption?> showRestoreOptionSheet({
  required BuildContext context,
  required bool webDavConfigured,
  bool busy = false,
  bool Function()? isBusy,
}) {
  final remoteDisabledReason = webDavConfigured
      ? null
      : kWebDavNotConfiguredHint;
  return _showOptionSheet<RestoreOption>(
    context: context,
    title: '恢复',
    busy: busy,
    isBusy: isBusy,
    options: [
      const _OptionEntry(
        value: RestoreOption.localFile,
        icon: Icons.phone_android,
        label: '本地恢复',
      ),
      _OptionEntry(
        value: RestoreOption.remoteFile,
        icon: Icons.cloud_outlined,
        label: '网络恢复',
        disabledReason: remoteDisabledReason,
      ),
      const _OptionEntry(
        value: RestoreOption.latestLocal,
        icon: Icons.history,
        label: '本地最新',
      ),
      _OptionEntry(
        value: RestoreOption.latestRemote,
        icon: Icons.cloud_download_outlined,
        label: '远端最新',
        disabledReason: remoteDisabledReason,
      ),
    ],
  );
}

/// 单个选项配置
@immutable
class _OptionEntry<T> {
  const _OptionEntry({
    required this.value,
    required this.icon,
    required this.label,
    this.disabledReason,
  });

  final T value;
  final IconData icon;
  final String label;

  /// 非 null 时选项禁用并显示原因（如「请先配置 WebDAV」）
  final String? disabledReason;
}

Future<T?> _showOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<_OptionEntry<T>> options,
  required bool busy,
  bool Function()? isBusy,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: IosGrabber()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              title,
              style: Theme.of(
                sheetContext,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: IosGroup(
                flat: true,
                children: [
                  for (final option in options)
                    _OptionRow<T>(option: option, busy: busy, isBusy: isBusy),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 选项行：图标 + 文案；禁用时灰显，点按只提示原因不关闭 Sheet
class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({required this.option, required this.busy, this.isBusy});

  final _OptionEntry<T> option;
  final bool busy;
  final bool Function()? isBusy;

  @override
  Widget build(BuildContext context) {
    final busyNow = busy || (isBusy?.call() ?? false);
    final disabledReason = busyNow
        ? kBackupRestoreBusyHint
        : option.disabledReason;
    final enabled = disabledReason == null;
    return GestureDetector(
      // 禁用行仍需接收点按以给出原因提示；ListTile 的 enabled=false 会吞掉
      // 点击，因此禁用态由外层 GestureDetector 兜底。
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? null
          : () {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(SnackBar(content: Text(disabledReason)));
            },
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: IosListTile(
          icon: option.icon,
          title: option.label,
          subtitle: disabledReason,
          enabled: enabled,
          showChevron: enabled,
          onTap: enabled ? () => Navigator.of(context).pop(option.value) : null,
        ),
      ),
    );
  }
}
