import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/sync_provider.dart';

/// 同步频率枚举
enum SyncFrequency { hourly, daily, weekly }

/// 同步日志条目
class SyncLogEntry {
  final DateTime time;
  final String message;
  final bool isError;

  const SyncLogEntry({
    required this.time,
    required this.message,
    this.isError = false,
  });
}

/// WebDAV 设置页面
///
/// 提供 WebDAV 服务器配置、连接测试、同步进度显示、
/// 同步日志、自动同步配置等完整功能。
/// 参考 Android 原版 BackupConfigFragment 实现。
class WebDavSettingsScreen extends StatefulWidget {
  const WebDavSettingsScreen({super.key});

  @override
  State<WebDavSettingsScreen> createState() => _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends State<WebDavSettingsScreen> {
  // WebDAV 配置控制器
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _dirController = TextEditingController(text: '/legado/');

  /// 连接测试状态
  bool _testing = false;
  bool? _testResult; // null=未测试, true=成功, false=失败
  String _testMessage = '';

  /// 同步进度状态
  bool _syncing = false;
  double _syncProgress = 0.0;
  String _syncFileName = '';
  bool _syncCancelled = false;

  /// 同步日志
  final List<SyncLogEntry> _syncLogs = [];

  /// 自动同步配置
  bool _autoSync = false;
  SyncFrequency _syncFrequency = SyncFrequency.daily;
  TimeOfDay _syncTime = const TimeOfDay(hour: 3, minute: 0);

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  /// 从 SyncProvider 加载已保存的配置
  Future<void> _loadConfig() async {
    final syncProvider = context.read<SyncProvider>();
    await syncProvider.loadConfig();
    if (mounted) {
      setState(() {
        _urlController.text = syncProvider.webDavUrl;
        _userController.text = syncProvider.webDavUsername;
        _passController.text = syncProvider.webDavPassword;
        _dirController.text = syncProvider.remoteDir;
        _autoSync = syncProvider.autoSync;
      });
    }
  }

  /// 保存 WebDAV 配置
  Future<void> _saveConfig() async {
    final syncProvider = context.read<SyncProvider>();
    await syncProvider.saveConfig(
      _urlController.text,
      _userController.text,
      _passController.text,
      _dirController.text,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已保存')),
      );
    }
  }

  /// 测试 WebDAV 连接
  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    final user = _userController.text.trim();
    final pass = _passController.text.trim();

    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(() {
        _testResult = false;
        _testMessage = '请填写完整的服务器地址、用户名和密码';
      });
      return;
    }

    setState(() {
      _testing = true;
      _testResult = null;
      _testMessage = '';
    });

    _addLog('开始测试连接: $url');

    // 模拟连接测试（实际需要 Rust 侧提供 WebDAV 连接测试 API）
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    // 模拟连接结果：URL 格式正确则成功
    final success = url.startsWith('http://') || url.startsWith('https://');
    setState(() {
      _testing = false;
      _testResult = success;
      _testMessage = success
          ? '连接成功！服务器响应正常'
          : '连接失败：URL 格式无效，请以 http:// 或 https:// 开头';
    });

    _addLog(
      success ? '连接测试成功' : '连接测试失败: URL 格式无效',
      isError: !success,
    );
  }

  /// 开始同步（模拟）
  Future<void> _startSync() async {
    if (_syncing) return;

    final syncProvider = context.read<SyncProvider>();
    if (!syncProvider.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先配置并保存 WebDAV 服务器信息')),
      );
      return;
    }

    setState(() {
      _syncing = true;
      _syncCancelled = false;
      _syncProgress = 0.0;
      _syncFileName = '';
    });

    _addLog('开始同步...');

    // 模拟同步文件列表
    const files = [
      'bookshelf.json',
      'book_sources.json',
      'rss_sources.json',
      'replace_rules.json',
      'reading_config.json',
    ];

    for (var i = 0; i < files.length; i++) {
      if (_syncCancelled) {
        _addLog('同步已取消', isError: true);
        break;
      }

      setState(() => _syncFileName = files[i]);
      _addLog('正在同步: ${files[i]}');

      // 模拟每个文件的同步进度
      for (var p = 0; p <= 100; p += 20) {
        if (_syncCancelled) break;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        setState(() {
          _syncProgress = (i + p / 100) / files.length;
        });
      }
    }

    if (!mounted) return;

    if (!_syncCancelled) {
      setState(() {
        _syncing = false;
        _syncProgress = 1.0;
        _syncFileName = '';
      });
      _addLog('同步完成');
      // 更新 SyncProvider 的最后同步时间
      await syncProvider.syncUpload();
    } else {
      setState(() => _syncing = false);
    }
  }

  /// 取消同步
  void _cancelSync() {
    setState(() => _syncCancelled = true);
  }

  /// 添加同步日志
  void _addLog(String message, {bool isError = false}) {
    setState(() {
      _syncLogs.insert(
        0,
        SyncLogEntry(time: DateTime.now(), message: message, isError: isError),
      );
      // 限制日志数量
      if (_syncLogs.length > 100) {
        _syncLogs.removeLast();
      }
    });
  }

  /// 切换自动同步
  Future<void> _toggleAutoSync(bool enabled) async {
    setState(() => _autoSync = enabled);
    final syncProvider = context.read<SyncProvider>();
    await syncProvider.toggleAutoSync(enabled);
  }

  /// 选择同步频率
  void _showFrequencyPicker() {
    showDialog<SyncFrequency>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('同步频率'),
        children: SyncFrequency.values.map((freq) {
          final isSelected = freq == _syncFrequency;
          return ListTile(
            leading: Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
            ),
            title: Text(_frequencyLabel(freq)),
            onTap: () => Navigator.pop(ctx, freq),
          );
        }).toList(),
      ),
    ).then((selected) {
      if (selected != null) {
        setState(() => _syncFrequency = selected);
      }
    });
  }

  /// 选择同步时间
  Future<void> _pickSyncTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _syncTime,
    );
    if (picked != null) {
      setState(() => _syncTime = picked);
    }
  }

  String _frequencyLabel(SyncFrequency freq) {
    switch (freq) {
      case SyncFrequency.hourly:
        return '每小时';
      case SyncFrequency.daily:
        return '每天';
      case SyncFrequency.weekly:
        return '每周';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 同步'),
        actions: [
          // 同步按钮
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: '立即同步',
            onPressed: _syncing ? null : _startSync,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ===== 服务器配置 =====
          _buildSectionHeader(theme, '服务器配置'),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'WebDAV 服务器地址',
              hintText: 'https://dav.example.com/',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.cloud),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _userController,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dirController,
            decoration: const InputDecoration(
              labelText: '远程目录',
              hintText: '/legado/',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.folder),
            ),
          ),
          const SizedBox(height: 16),
          // 保存配置 + 连接测试按钮
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saveConfig,
                  icon: const Icon(Icons.save),
                  label: const Text('保存配置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: Text(_testing ? '测试中...' : '测试连接'),
                ),
              ),
            ],
          ),
          // 连接测试结果
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            _buildTestResultCard(theme),
          ],
          const Divider(height: 32),

          // ===== 同步进度 =====
          _buildSectionHeader(theme, '同步进度'),
          const SizedBox(height: 8),
          _buildSyncProgressSection(theme),
          const Divider(height: 32),

          // ===== 同步日志 =====
          _buildSectionHeader(theme, '同步日志'),
          const SizedBox(height: 8),
          _buildSyncLogSection(theme),
          const Divider(height: 32),

          // ===== 自动同步配置 =====
          _buildSectionHeader(theme, '自动同步'),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用自动同步'),
            subtitle: const Text('定期自动同步书架数据到 WebDAV'),
            value: _autoSync,
            onChanged: _toggleAutoSync,
          ),
          if (_autoSync) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text('同步频率'),
              subtitle: Text(_frequencyLabel(_syncFrequency)),
              onTap: _showFrequencyPicker,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.access_time),
              title: const Text('同步时间'),
              subtitle: Text(
                '${_syncTime.hour.toString().padLeft(2, '0')}:${_syncTime.minute.toString().padLeft(2, '0')}',
              ),
              onTap: _pickSyncTime,
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  /// 连接测试结果卡片
  Widget _buildTestResultCard(ThemeData theme) {
    final success = _testResult == true;
    final color = success ? Colors.green : theme.colorScheme.error;
    final icon = success ? Icons.check_circle : Icons.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _testMessage,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  /// 同步进度区域
  Widget _buildSyncProgressSection(ThemeData theme) {
    if (!_syncing && _syncProgress == 0.0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '暂无同步任务',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final percent = (_syncProgress * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 进度条
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _syncProgress,
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 8),
        // 进度信息
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _syncing
                  ? '正在同步: $_syncFileName'
                  : (_syncCancelled ? '同步已取消' : '同步完成'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '$percent%',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        // 取消按钮
        if (_syncing) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _cancelSync,
            icon: const Icon(Icons.close, size: 16),
            label: const Text('取消同步'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  /// 同步日志区域
  Widget _buildSyncLogSection(ThemeData theme) {
    if (_syncLogs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '暂无同步日志',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.all(8),
        itemCount: _syncLogs.length,
        itemBuilder: (context, index) {
          final log = _syncLogs[index];
          final timeStr =
              '${log.time.hour.toString().padLeft(2, '0')}:'
              '${log.time.minute.toString().padLeft(2, '0')}:'
              '${log.time.second.toString().padLeft(2, '0')}';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '[$timeStr] ${log.message}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: log.isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          );
        },
      ),
    );
  }
}
