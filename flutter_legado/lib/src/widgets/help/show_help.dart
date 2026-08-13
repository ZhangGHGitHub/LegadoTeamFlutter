import 'package:flutter/material.dart';

import 'help_assets.dart';
import 'help_screen.dart';

/// 显示帮助文档（对标 Android AppCompatActivity.showHelp → TextDialog）
void showHelp(
  BuildContext context,
  String fileName, {
  String title = '帮助',
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => HelpScreen(
      assetPath: HelpAssets.mdPath(fileName),
      title: title,
    ),
  );
}

/// 显示 storageHelp.md（对标 BaseImportBookActivity / FileAssociationActivity）
void showStorageHelp(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const HelpScreen(
      assetPath: HelpAssets.storageHelp,
      title: '帮助',
    ),
  );
}
