import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import 'help_assets.dart';
import 'help_screen.dart';

/// 显示帮助文档（对标 Android AppCompatActivity.showHelp → TextDialog）
void showHelp(
  BuildContext context,
  String fileName, {
  String? title,
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => HelpScreen(
      assetPath: HelpAssets.mdPath(fileName),
      title: title ?? AppStrings.helpLabel,
    ),
  );
}

/// 显示 storageHelp.md（对标 BaseImportBookActivity / FileAssociationActivity）
void showStorageHelp(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => HelpScreen(
      assetPath: HelpAssets.storageHelp,
      title: AppStrings.helpLabel,
    ),
  );
}
