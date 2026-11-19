import 'package:flutter/material.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../services/app_update_service.dart';
import '../services/crash_log_service.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/update_dialog.dart';
import '../utils/error_message.dart';

/// 关于页面（对齐原版 about.xml + AboutFragment）
///
/// 条目：开发人员 / 更新日志 / 检查更新；
/// 「其他」：崩溃日志 / 保存日志 / 创建堆转储 / 用户隐私与协议 / 开源许可 / 免责声明。
/// 视觉：apple-ui-designer 分组 inset 列表，去掉创意技术栈卡片与营销文案。
///
/// — UI 子代理 + UI ｜ 2026-08-13
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  static const _contributorsUrl =
      'https://github.com/gedoor/legado/graphs/contributors';
  static const _privacyUrl =
      'https://gedoor.github.io/legado/#/md/privacyPolicy';

  bool _checkingUpdate = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAppVersion());
  }

  Future<void> _loadAppVersion() async {
    try {
      final v = await AppUpdateService.resolveCurrentVersionName();
      if (mounted) setState(() => _appVersion = v);
    } catch (e) {
      debugPrint('获取应用版本号失败: $e');
    }
  }

  Future<void> _launch(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.copiedLink(url))),
      );
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    final service = AppUpdateService();
    try {
      final version = _appVersion.isEmpty
          ? await AppUpdateService.resolveCurrentVersionName()
          : _appVersion;
      if (mounted && _appVersion.isEmpty) {
        setState(() => _appVersion = version);
      }
      final info = await service.check(currentVersion: version);
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      if (info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.latestVersion(version))),
        );
        return;
      }
      if (await service.isIgnored(info.tagName)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.versionIgnoredNamed(info.tagName))),
        );
        return;
      }
      if (!mounted) return;
      await showAppUpdateDialog(context, info: info, service: service);
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.checkUpdateError(errorMessage(e)))),
      );
    }
  }

  /// 展示 Markdown 正文（资产缺失时用内置占位，避免假功能）
  Future<void> _showTextSheet(String title, String body) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (_, controller) => Column(
          children: [
            Padding(
              // [LAYOUT_PLAN P3] Sheet 内水平边距 20→16（全局标尺）
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                // [LAYOUT_PLAN P3] Sheet 内水平边距 20→16（全局标尺）
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Text(body),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showUpdateLog() async {
    final placeholder = AppStrings.updateLogPlaceholder;
    try {
      final md = await rootBundle.loadString('assets/updateLog.md');
      await _showTextSheet(AppStrings.updateLog, md);
    } catch (_) {
      await _showTextSheet(AppStrings.updateLog, placeholder);
    }
  }

  Future<void> _showDisclaimer() async {
    final placeholder = AppStrings.disclaimerPlaceholder;
    try {
      final md = await rootBundle.loadString('assets/disclaimer.md');
      await _showTextSheet(AppStrings.disclaimer, md);
    } catch (_) {
      await _showTextSheet(AppStrings.disclaimer, placeholder);
    }
  }

  Future<void> _saveLog() async {
    try {
      final path = await CrashLogService.instance.exportLogsToFile();
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.logRecordingDisabled),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.logsExported(path))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.saveLogFailed(errorMessage(e)))),
      );
    }
  }

  /// 创建堆转储（P1-5 真实现，对齐原版 AboutFragment.createHeapDump）：
  /// ① 未开启「记录堆转储」先提示（原版 toast 后仍继续转储）；② 「开始创建
  /// 堆转储」；③ Debug.dumpHprofData 落盘（原生通道）；④ 落盘路径弹系统分享
  ///（原版为复制到备份目录，本轨以分享承载「取出文件」，批3裁决口径）。
  /// iOS/桌面无对应物：UnsupportedError → 明确文案（平台裁决口径）。
  Future<void> _createHeapDump() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final recordHeapDump =
          await CrashLogService.instance.getRecordHeapDump();
      if (!recordHeapDump) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(AppStrings.heapDumpRecordingDisabled),
          ),
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.creatingHeapDump)),
      );
      final path = await CrashLogService.instance.createHeapDump();
      if (!mounted) return;
      // 分享承载「取出堆转储文件」（share_plus 为既有依赖）
      await Share.shareXFiles(
        [XFile(path)],
        subject: AppStrings.heapDumpFile,
        text: AppStrings.heapDumpShareText,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.heapDumpCreated(path))),
      );
    } on UnsupportedError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? AppStrings.heapDumpUnsupported),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.heapDumpFailed(errorMessage(e)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(title: Text(AppStrings.aboutLabel)),
      body: IosGroupedBody(
        child: ListView(
          // [LAYOUT_PLAN P3] 底部 bottom32 保留；列表水平边距走 IosGroupedBody 16dp
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            IosGroup(flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              // [LAYOUT_PLAN P3] 分组行走 IosListTile 规范（扁平分组，行内边距由 ListTile 承担）
              children: [
                IosListTile(
                  title: AppStrings.contributors,
                  subtitle: AppStrings.contributorsSummary,
                  onTap: () => _launch(_contributorsUrl),
                ),
                IosListTile(
                  title: AppStrings.updateLog,
                  subtitle: _appVersion.isEmpty
                      ? AppStrings.versionPlaceholder
                      : AppStrings.versionLabel(_appVersion),
                  onTap: _showUpdateLog,
                ),
                IosListTile(
                  title: AppStrings.checkUpdate,
                  trailing: _checkingUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
              ],
            ),
            IosSectionHeader(AppStrings.otherSection),
            IosGroup(flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              // [LAYOUT_PLAN P3] 分组行走 IosListTile 规范（扁平分组，行内边距由 ListTile 承担）
              children: [
                IosListTile(
                  title: AppStrings.crashLog,
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.appLog),
                ),
                IosListTile(
                  title: AppStrings.saveLogs,
                  onTap: _saveLog,
                ),
                IosListTile(
                  title: AppStrings.createHeapDump,
                  onTap: _createHeapDump,
                ),
                IosListTile(
                  title: AppStrings.privacyPolicy,
                  onTap: () => _launch(_privacyUrl),
                ),
                IosListTile(
                  title: AppStrings.licenseLabel,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: AppStrings.appTitle,
                    applicationVersion: _appVersion,
                    applicationLegalese: 'GNU General Public License v3.0',
                  ),
                ),
                IosListTile(
                  title: AppStrings.disclaimer,
                  onTap: _showDisclaimer,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
