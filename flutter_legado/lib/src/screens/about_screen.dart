import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';

import '../providers/providers.dart';
import '../routes.dart';
import '../services/app_update_service.dart';
import '../widgets/update_dialog.dart';

/// 关于页面
///
/// 展示应用图标、版本、开源协议、仓库链接、检查更新、
/// 捐赠/反馈入口以及技术栈说明。
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen>
    with SingleTickerProviderStateMixin {
  static const _repoUrl = 'https://github.com/LegadoTeam/legado';
  static const _issueUrl = 'https://github.com/LegadoTeam/legado/issues';
  static const _sponsorUrl = 'https://github.com/gedoor/legado#赞助';

  late final AnimationController _controller;
  bool _checkingUpdate = false;
  String? _updateResult;
  String _appVersion = '';
  String _rustVersion = '';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAppVersion();
      _loadRustVersion();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    try {
      final v = await AppUpdateService.resolveCurrentVersionName();
      if (mounted) setState(() => _appVersion = v);
    } catch (e) {
      debugPrint('获取应用版本号失败: $e');
    }
  }

  Future<void> _loadRustVersion() async {
    try {
      final v = await ref.read(bookApiProvider).getVersion();
      if (mounted) setState(() => _rustVersion = v);
    } catch (e) {
      // [审计修复 §4.1] FFI 不可用时静默降级，debugPrint 留痕 — Qoder
      debugPrint('获取 Rust 版本号失败: $e');
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
    setState(() {
      _checkingUpdate = true;
      _updateResult = null;
    });
    final service = AppUpdateService();
    try {
      // 对齐 AppUpdateGitHub.check → UpdateDialog；版本走 PackageInfo
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
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('当前版本 v$version'),
            content: const Text('当前已是最新版本。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
        if (mounted) {
          setState(() => _updateResult = '当前已是最新版本 v$version');
        }
        return;
      }
      if (await service.isIgnored(info.tagName)) {
        if (!mounted) return;
        setState(() => _updateResult = '已忽略版本 ${info.tagName}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已忽略版本 ${info.tagName}')),
        );
        return;
      }
      if (!mounted) return;
      await showAppUpdateDialog(context, info: info, service: service);
      if (mounted) {
        setState(() => _updateResult = '发现新版本 ${info.tagName}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingUpdate = false;
        _updateResult = '检查失败';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _buildHeader(theme),
          const SizedBox(height: 8),
          _buildTechStack(theme),
          const SizedBox(height: 8),
          _buildActions(theme),
          const SizedBox(height: 24),
          _buildFooter(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
            .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.menu_book_rounded,
                  size: 52,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '阅读',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Legado · 自由阅读，随心所阅',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              // 系统感版本胶囊：加载完成前轻量占位，避免硬编码滞后
              AnimatedOpacity(
                opacity: _appVersion.isEmpty ? 0.45 : 1,
                duration: const Duration(milliseconds: 220),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _appVersion.isEmpty ? '版本…' : 'v$_appVersion',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTechStack(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(theme, '技术栈'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _techCard(
                  theme,
                  icon: Icons.precision_manufacturing_rounded,
                  title: 'Rust',
                  subtitle: _rustVersion.isEmpty ? '核心引擎' : '核心引擎 · $_rustVersion',
                  color: colorScheme.tertiaryContainer,
                  onColor: colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _techCard(
                  theme,
                  icon: Icons.flutter_dash,
                  title: 'Flutter',
                  subtitle: '跨平台界面',
                  color: colorScheme.primaryContainer,
                  onColor: colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _techCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required Color onColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: onColor, size: 28),
          const SizedBox(height: 12),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: onColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: onColor.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(theme, '更多'),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('检查更新'),
                  trailing: _checkingUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
                if (_updateResult != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 18, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _updateResult!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                // [审计修复 §1.2 第二批] 对齐原版 AppLogDialog 关于页入口 — Qoder
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('应用日志'),
                  subtitle: const Text('查看 message/crash/http 三级日志'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pushNamed(context, AppRoutes.appLog),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('开源协议'),
                  subtitle: const Text('GNU General Public License v3.0'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: '阅读 Legado',
                    applicationVersion: _appVersion,
                    applicationLegalese: 'GPL-3.0 License',
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('GitHub 仓库'),
                  subtitle: const Text('github.com/gedoor/legado'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _launch(_repoUrl),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.volunteer_activism_outlined),
                  title: const Text('捐赠支持'),
                  subtitle: const Text('支持项目持续开发'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _launch(_sponsorUrl),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.feedback_outlined),
                  title: const Text('意见反馈'),
                  subtitle: const Text('提交问题与建议'),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _launch(_issueUrl),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Center(
      child: Text(
        'Made with Rust ❤ Flutter',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
