import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/sync/sync_notifier.dart';

/// WebDAV 设置页面
///
/// 对齐 Android 原版 BackupConfigFragment 的 WebDAV 设置组：
/// 服务器地址 / 账号 / 密码 / 子目录 / 设备名 / 同步书籍进度（含增强），
/// 以及备份/恢复操作（真实对接 BookApi.webdavFullSync）。
class WebDavSettingsScreen extends ConsumerStatefulWidget {
  const WebDavSettingsScreen({super.key});

  @override
  ConsumerState<WebDavSettingsScreen> createState() =>
      _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends ConsumerState<WebDavSettingsScreen> {
  // 本地编辑态（确认后整体写回 SyncNotifier）
  String _url = '';
  String _user = '';
  String _pass = '';
  String _dir = '/legado/';
  String _device = '';

  /// 备份/恢复进行中
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  /// 从 SyncNotifier 加载已保存的配置
  Future<void> _loadConfig() async {
    final notifier = ref.read(syncNotifierProvider.notifier);
    await notifier.loadConfig();
    if (mounted) {
      final state = ref.read(syncNotifierProvider);
      setState(() {
        _url = state.webDavUrl;
        _user = state.webDavUsername;
        _pass = state.webDavPassword;
        _dir = state.remoteDir;
        _device = state.deviceName;
      });
    }
  }

  /// 整体保存当前配置
  Future<void> _saveAll() async {
    final notifier = ref.read(syncNotifierProvider.notifier);
    await notifier.saveConfig(
      _url,
      _user,
      _pass,
      _dir,
      deviceName: _device,
    );
  }

  /// 通用文本配置编辑对话框（对齐原版 EditTextPreference）
  Future<void> _editTextPref({
    required String title,
    required String initial,
    required ValueChanged<String> onSaved,
    bool obscure = false,
    String? hint,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: obscure,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => onSaved(result));
    await _saveAll();
  }

  /// 备份到 WebDAV
  Future<void> _backup() async {
    final notifier = ref.read(syncNotifierProvider.notifier);
    if (!ref.read(syncNotifierProvider).isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先配置并保存 WebDAV 服务器信息')),
      );
      return;
    }
    await _runWithProgress('备份中…', () => notifier.backupToWebDav());
    if (!mounted) return;
    final error = ref.read(syncNotifierProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? '备份成功')),
    );
  }

  /// 从 WebDAV 恢复
  Future<void> _restore() async {
    final notifier = ref.read(syncNotifierProvider.notifier);
    if (!ref.read(syncNotifierProvider).isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先配置并保存 WebDAV 服务器信息')),
      );
      return;
    }
    var message = '';
    await _runWithProgress(
      '恢复中…',
      () async => message = await notifier.restoreFromWebDav(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message.isEmpty ? '恢复完成' : message)),
    );
  }

  /// 显示不可关闭的进度对话框并执行任务（对齐原版 WaitDialog）
  Future<void> _runWithProgress(String label, Future<void> Function() task) async {
    setState(() => _busy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
    try {
      await task();
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // 关闭进度对话框
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncNotifierProvider);
    final notifier = ref.read(syncNotifierProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 设置')),
      body: ListView(
        children: [
          // ===== WebDAV 设置组 =====
          _buildSectionHeader('WebDAV 设置'),
          ListTile(
            title: const Text('WebDAV 服务器地址'),
            subtitle: Text(_url.isEmpty ? '输入你的服务器地址' : _url),
            onTap: () => _editTextPref(
              title: 'WebDAV 服务器地址',
              initial: _url,
              hint: 'https://dav.example.com/',
              onSaved: (v) => _url = v,
            ),
          ),
          ListTile(
            title: const Text('WebDAV 账号'),
            subtitle: Text(_user.isEmpty ? '输入你的 WebDAV 账号' : _user),
            onTap: () => _editTextPref(
              title: 'WebDAV 账号',
              initial: _user,
              onSaved: (v) => _user = v,
            ),
          ),
          ListTile(
            title: const Text('WebDAV 密码'),
            subtitle: Text(_pass.isEmpty ? '输入你的密码' : '*' * _pass.length),
            onTap: () => _editTextPref(
              title: 'WebDAV 密码',
              initial: _pass,
              obscure: true,
              onSaved: (v) => _pass = v,
            ),
          ),
          ListTile(
            title: const Text('子目录'),
            subtitle: Text(_dir.isEmpty ? 'legado' : _dir),
            onTap: () => _editTextPref(
              title: '子目录',
              initial: _dir,
              hint: 'legado',
              onSaved: (v) => _dir = v,
            ),
          ),
          ListTile(
            title: const Text('设备名称'),
            subtitle: Text(_device.isEmpty ? '用于区分不同设备的备份' : _device),
            onTap: () => _editTextPref(
              title: '设备名称',
              initial: _device,
              onSaved: (v) => _device = v,
            ),
          ),
          SwitchListTile(
            title: const Text('同步书籍进度'),
            subtitle: const Text('在多设备间同步书籍阅读进度'),
            value: syncState.syncBookProgress,
            onChanged: (v) => notifier.setSyncBookProgress(v),
          ),
          SwitchListTile(
            title: const Text('同步书籍进度增强'),
            subtitle: const Text('同步更详细的阅读进度信息'),
            value: syncState.syncBookProgressPlus,
            onChanged: syncState.syncBookProgress
                ? (v) => notifier.setSyncBookProgressPlus(v)
                : null,
          ),
          const Divider(height: 1),

          // ===== 备份/恢复组 =====
          _buildSectionHeader('备份与恢复'),
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text('备份'),
            subtitle: const Text('备份书架与书源到 WebDAV'),
            enabled: !_busy,
            onTap: _backup,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download),
            title: const Text('恢复'),
            subtitle: const Text('从 WebDAV 恢复数据'),
            enabled: !_busy,
            onTap: _restore,
          ),
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('最后同步时间'),
            subtitle: Text(syncState.lastSyncTimeLabel),
            enabled: false,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
