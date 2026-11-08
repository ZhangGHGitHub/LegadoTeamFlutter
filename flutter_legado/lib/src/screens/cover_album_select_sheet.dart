// 默认封面相册选择 Sheet（设置批6b-2）
//
// 对齐参考版 `CoverAlbumSelectSheet.kt:42-88`：
// - 首项「应用内置封面」= null（回落到内置默认图 + 书名/作者）；
// - 其后为相册列表（预览图 / 名称 / 日间与夜间数量 / 当前选中标记）；
// - 顶栏右侧「管理相册」入口打开 CoverAlbumManageScreen；
// - 点击任意项返回 [CoverAlbumSelection]（albumId=null 表示内置封面），
//   取消（下滑/点外部）返回 null，调用方据此区分「选内置」与「未选择」。
//
// 编写：全栈工程师（设置批6b-2） ｜ 2026-11-09
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../providers/cover_settings/cover_settings_notifier.dart';
import '../services/cover_album_store.dart';
import '../widgets/cover_album_preview.dart';
import '../widgets/ios_widgets.dart';

/// 选择结果（albumId=null → 应用内置封面）
class CoverAlbumSelection {
  final String? albumId;

  const CoverAlbumSelection({required this.albumId});
}

/// 默认封面选择 Sheet
class CoverAlbumSelectSheet extends StatelessWidget {
  /// 管理相册入口回调（通常 pop 后 push 管理页）
  final VoidCallback? onManage;

  const CoverAlbumSelectSheet({super.key, this.onManage});

  /// 弹出选择 Sheet；返回 null 表示用户取消
  static Future<CoverAlbumSelection?> show(
    BuildContext context, {
    VoidCallback? onManage,
  }) {
    return showModalBottomSheet<CoverAlbumSelection>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: CoverAlbumSelectSheet(
          onManage: onManage == null
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  onManage();
                },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        coverSettingsListenable,
        CoverAlbumStore.instance.revision,
      ]),
      builder: (context, _) {
        final selectedId = coverSettingsListenable.value.defaultAlbumId;
        final albums = CoverAlbumStore.instance.albums;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择封面相册',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (onManage != null)
                      IconButton(
                        key: const ValueKey('coverAlbumManageAction'),
                        tooltip: '管理相册',
                        icon: const Icon(Symbols.settings_rounded),
                        onPressed: onManage,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                IosGroup(
                  children: [
                    IosListTile(
                      key: const ValueKey('coverAlbumBuiltinOption'),
                      leading: const CoverAlbumPreview(path: null),
                      title: '应用内置封面',
                      subtitle: '使用应用内置默认封面',
                      showChevron: false,
                      trailing: selectedId == null
                          ? Icon(
                              Symbols.check_rounded,
                              key: const ValueKey('coverAlbumBuiltinCheck'),
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.pop(
                        context,
                        const CoverAlbumSelection(albumId: null),
                      ),
                    ),
                    for (final album in albums)
                      IosListTile(
                        key: ValueKey('coverAlbumOption_${album.id}'),
                        leading: CoverAlbumPreview(path: album.previewPath),
                        title: album.name,
                        subtitle:
                            '日间 ${album.lightCount} · 夜间 ${album.darkCount}',
                        showChevron: false,
                        trailing: selectedId == album.id
                            ? Icon(
                                Symbols.check_rounded,
                                key: ValueKey(
                                  'coverAlbumOptionCheck_${album.id}',
                                ),
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        onTap: () => Navigator.pop(
                          context,
                          CoverAlbumSelection(albumId: album.id),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
