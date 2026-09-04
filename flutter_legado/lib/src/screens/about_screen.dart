import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';

import '../routes.dart';
import '../services/app_update_service.dart';
import '../services/crash_log_service.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/update_dialog.dart';

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
      messenger.showSnackBar(SnackBar(content: Text('已复制链接：$url')));
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
          SnackBar(content: Text('当前已是最新版本 v$version')),
        );
        return;
      }
      if (await service.isIgnored(info.tagName)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已忽略版本 ${info.tagName}')),
        );
        return;
      }
      if (!mounted) return;
      await showAppUpdateDialog(context, info: info, service: service);
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingUpdate = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新\n$e')),
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
    const placeholder =
        '更新日志正文尚未打包进 Flutter 资产（对标 Android assets/updateLog.md）。\n'
        '请前往 GitHub Releases 查看完整变更说明。';
    try {
      final md = await rootBundle.loadString('assets/updateLog.md');
      await _showTextSheet('更新日志', md);
    } catch (_) {
      await _showTextSheet('更新日志', placeholder);
    }
  }

  Future<void> _showDisclaimer() async {
    const placeholder =
        '免责声明正文尚未打包进 Flutter 资产（对标 Android assets/disclaimer.md）。\n'
        '本软件为开源阅读工具，使用者须遵守当地法律法规与网站服务条款。';
    try {
      final md = await rootBundle.loadString('assets/disclaimer.md');
      await _showTextSheet('免责声明', md);
    } catch (_) {
      await _showTextSheet('免责声明', placeholder);
    }
  }

  Future<void> _saveLog() async {
    try {
      final path = await CrashLogService.instance.exportLogsToFile();
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('未开启日志记录，请去其他设置里打开记录日志'),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已导出：$path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存日志失败：$e')),
      );
    }
  }

  void _createHeapDumpPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('创建堆转储暂不可用（需 Android 堆转储能力；请先开启「记录堆转储」）'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(title: const Text('关于')),
      body: IosGroupedBody(
        child: ListView(
          // [LAYOUT_PLAN P3] 底部 bottom32 保留；列表水平边距走 IosGroupedBody 16dp
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            IosGroup(flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              // [LAYOUT_PLAN P3] 分组行走 IosListTile 规范（扁平分组，行内边距由 ListTile 承担）
              children: [
                IosListTile(
                  title: '开发人员',
                  subtitle: 'gedoor、Invinciblelee 和 Xwite 等，详情请在 GitHub 中查看',
                  onTap: () => _launch(_contributorsUrl),
                ),
                IosListTile(
                  title: '更新日志',
                  subtitle: _appVersion.isEmpty
                      ? '版本 …'
                      : '版本 $_appVersion',
                  onTap: _showUpdateLog,
                ),
                IosListTile(
                  title: '检查更新',
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
            const IosSectionHeader('其他'),
            IosGroup(flat: true, // [LAYOUT_MOTION_AUDIT L2] 设置拆扁平
              // [LAYOUT_PLAN P3] 分组行走 IosListTile 规范（扁平分组，行内边距由 ListTile 承担）
              children: [
                IosListTile(
                  title: '崩溃日志',
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.appLog),
                ),
                IosListTile(
                  title: '保存日志',
                  onTap: _saveLog,
                ),
                IosListTile(
                  title: '创建堆转储',
                  onTap: _createHeapDumpPlaceholder,
                ),
                IosListTile(
                  title: '用户隐私与协议',
                  onTap: () => _launch(_privacyUrl),
                ),
                IosListTile(
                  title: '开源许可',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: '阅读',
                    applicationVersion: _appVersion,
                    applicationLegalese: 'GNU General Public License v3.0',
                  ),
                ),
                IosListTile(
                  title: '免责声明',
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
