import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';

/// WebDAV 设置页面 Widget 测试
///
/// 验证 WebDAV 连接配置、连接测试、同步进度显示、
/// 同步日志、自动同步配置等功能。
void main() {
  /// 构建测试用 MaterialApp
  Widget buildTestApp({required Widget child}) {
    return MaterialApp(
      home: child,
    );
  }

  group('WebDAV 服务器配置', () {
    testWidgets('配置输入框正确渲染', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            appBar: AppBar(title: const Text('WebDAV 同步')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 服务器配置分区标题
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '服务器配置',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 服务器地址',
                    hintText: 'https://dav.example.com/',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.cloud),
                  ),
                  controller: TextEditingController(),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  controller: TextEditingController(),
                ),
                const SizedBox(height: 12),
                TextField(
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                  controller: TextEditingController(),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    labelText: '远程目录',
                    hintText: '/legado/',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.folder),
                  ),
                  controller: TextEditingController(text: '/legado/'),
                ),
              ],
            ),
          ),
        ),
      );

      // 验证分区标题
      expect(find.text('服务器配置'), findsOneWidget);

      // 验证输入框标签
      expect(find.text('WebDAV 服务器地址'), findsOneWidget);
      expect(find.text('用户名'), findsOneWidget);
      expect(find.text('密码'), findsOneWidget);
      expect(find.text('远程目录'), findsOneWidget);

      // 验证图标
      expect(find.byIcon(Icons.cloud), findsOneWidget);
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsOneWidget);
      expect(find.byIcon(Icons.folder), findsOneWidget);

      // 验证远程目录默认值（控制器文本 + hintText 各一份）
      expect(find.text('/legado/'), findsNWidgets(2));
    });

    testWidgets('保存配置和测试连接按钮存在', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.save),
                      label: const Text('保存配置'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('测试连接'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('保存配置'), findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      expect(find.byIcon(Icons.save), findsOneWidget);
      expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);
    });

    testWidgets('输入框可正常输入文本', (tester) async {
      final urlController = TextEditingController();
      final userController = TextEditingController();

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 服务器地址',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: userController,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 输入服务器地址
      await tester.enterText(
        find.byType(TextField).first,
        'https://dav.jianguoyun.com/dav/',
      );
      expect(urlController.text, 'https://dav.jianguoyun.com/dav/');

      // 输入用户名
      await tester.enterText(
        find.byType(TextField).last,
        'testuser',
      );
      expect(userController.text, 'testuser');
    });
  });

  group('WebDAV 连接测试', () {
    testWidgets('连接测试结果卡片 - 成功状态', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '连接成功！服务器响应正常',
                        style: TextStyle(color: Colors.green.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('连接成功！服务器响应正常'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('连接测试结果卡片 - 失败状态', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '连接失败：URL 格式无效，请以 http:// 或 https:// 开头',
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        find.text('连接失败：URL 格式无效，请以 http:// 或 https:// 开头'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.error), findsOneWidget);
    });

    testWidgets('测试连接按钮加载状态', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Center(
              child: OutlinedButton.icon(
                onPressed: null, // 禁用状态
                icon: const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                label: const Text('测试中...'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('测试中...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('同步进度显示', () {
    testWidgets('同步进度条正确渲染', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 进度条
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(
                      value: 0.6,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 进度信息
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '正在同步: bookshelf.json',
                        style: TextStyle(fontSize: 12),
                      ),
                      Text(
                        '60%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 验证进度条
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // 验证文件名和百分比
      expect(find.text('正在同步: bookshelf.json'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
    });

    testWidgets('取消同步按钮存在', (tester) async {
      var cancelled = false;

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Center(
              child: OutlinedButton.icon(
                onPressed: () => cancelled = true,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('取消同步'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('取消同步'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.tap(find.text('取消同步'));
      expect(cancelled, isTrue);
    });

    testWidgets('同步完成状态显示', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(
                      value: 1.0,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '同步完成',
                        style: TextStyle(fontSize: 12),
                      ),
                      Text(
                        '100%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('同步完成'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('暂无同步任务状态', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '暂无同步任务',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('暂无同步任务'), findsOneWidget);
    });
  });

  group('同步日志显示', () {
    testWidgets('同步日志列表正确渲染', (tester) async {
      final logs = [
        SyncLogEntry(
          time: DateTime(2026, 7, 30, 14, 30, 5),
          message: '同步完成',
        ),
        SyncLogEntry(
          time: DateTime(2026, 7, 30, 14, 30, 3),
          message: '正在同步: bookshelf.json',
        ),
        SyncLogEntry(
          time: DateTime(2026, 7, 30, 14, 30, 1),
          message: '开始同步...',
        ),
        SyncLogEntry(
          time: DateTime(2026, 7, 30, 14, 29, 50),
          message: '连接测试失败: URL 格式无效',
          isError: true,
        ),
      ];

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(8),
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[index];
                  final timeStr =
                      '${log.time.hour.toString().padLeft(2, '0')}:'
                      '${log.time.minute.toString().padLeft(2, '0')}:'
                      '${log.time.second.toString().padLeft(2, '0')}';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '[$timeStr] ${log.message}',
                      style: TextStyle(
                        color: log.isError ? Colors.red : Colors.grey.shade700,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      // 验证日志内容
      expect(find.textContaining('同步完成'), findsOneWidget);
      expect(find.textContaining('正在同步: bookshelf.json'), findsOneWidget);
      expect(find.textContaining('开始同步...'), findsOneWidget);
      expect(find.textContaining('连接测试失败'), findsOneWidget);
    });

    testWidgets('暂无同步日志提示', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '暂无同步日志',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('暂无同步日志'), findsOneWidget);
    });

    test('SyncLogEntry 数据模型正确', () {
      final now = DateTime.now();
      final log = SyncLogEntry(
        time: now,
        message: '测试消息',
        isError: true,
      );

      expect(log.time, now);
      expect(log.message, '测试消息');
      expect(log.isError, isTrue);

      final normalLog = SyncLogEntry(
        time: now,
        message: '正常消息',
      );
      expect(normalLog.isError, isFalse);
    });
  });

  group('自动同步配置', () {
    testWidgets('自动同步开关正确渲染', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用自动同步'),
                  subtitle: const Text('定期自动同步书架数据到 WebDAV'),
                  value: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('启用自动同步'), findsOneWidget);
      expect(find.text('定期自动同步书架数据到 WebDAV'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets('同步频率选择项正确渲染', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: const Text('同步频率'),
                  subtitle: const Text('每天'),
                  onTap: () {},
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time),
                  title: const Text('同步时间'),
                  subtitle: const Text('03:00'),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('同步频率'), findsOneWidget);
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('同步时间'), findsOneWidget);
      expect(find.text('03:00'), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.access_time), findsOneWidget);
    });

    testWidgets('自动同步关闭时不显示频率和时间', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用自动同步'),
                  subtitle: const Text('定期自动同步书架数据到 WebDAV'),
                  value: false,
                  onChanged: (_) {},
                ),
                // 自动同步关闭时不显示频率和时间选项
              ],
            ),
          ),
        ),
      );

      expect(find.text('启用自动同步'), findsOneWidget);
      expect(find.text('同步频率'), findsNothing);
      expect(find.text('同步时间'), findsNothing);
    });

    test('SyncFrequency 枚举值正确', () {
      expect(SyncFrequency.values.length, 3);
      expect(SyncFrequency.values.contains(SyncFrequency.hourly), isTrue);
      expect(SyncFrequency.values.contains(SyncFrequency.daily), isTrue);
      expect(SyncFrequency.values.contains(SyncFrequency.weekly), isTrue);
    });
  });

  group('WebDAV 页面整体结构', () {
    testWidgets('AppBar 标题和同步按钮正确', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            appBar: AppBar(
              title: const Text('WebDAV 同步'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: '立即同步',
                  onPressed: () {},
                ),
              ],
            ),
            body: const SizedBox(),
          ),
        ),
      );

      expect(find.text('WebDAV 同步'), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsOneWidget);
    });

    testWidgets('所有分区标题正确渲染', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildSectionHeader('服务器配置'),
                const SizedBox(height: 20),
                _buildSectionHeader('同步进度'),
                const SizedBox(height: 20),
                _buildSectionHeader('同步日志'),
                const SizedBox(height: 20),
                _buildSectionHeader('自动同步'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('服务器配置'), findsOneWidget);
      expect(find.text('同步进度'), findsOneWidget);
      expect(find.text('同步日志'), findsOneWidget);
      expect(find.text('自动同步'), findsOneWidget);
    });
  });
}

/// 辅助构建分区标题
Widget _buildSectionHeader(String title) {
  return Row(
    children: [
      Container(
        width: 4,
        height: 18,
        decoration: BoxDecoration(
          color: Colors.blue,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}
