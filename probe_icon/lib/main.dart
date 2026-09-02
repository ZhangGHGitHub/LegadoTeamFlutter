import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 最小探针 UI：判定旁载语境下能否切换桌面图标。
///
/// - 「切换为 probe 图标」→ setAlternateIconName("probe")（纯 legacy）；
/// - 「恢复主图标」→ setAlternateIconName(nil)；
/// - 顶部状态区展示自检（系统版本 / supportsAlt / 磁盘声明 / 散文件）。
///
/// 结果判读：切换成功后重启 App，桌面图标应变为 probe 图案；
/// 若仍报 OSStatus -54 → 旁载语境问题（与本 app 结构无关）。
const MethodChannel _channel = MethodChannel('probe/icon');

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '图标探针',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const ProbeHome(),
    );
  }
}

class ProbeHome extends StatefulWidget {
  const ProbeHome({super.key});

  @override
  State<ProbeHome> createState() => _ProbeHomeState();
}

class _ProbeHomeState extends State<ProbeHome> {
  String _status = '加载中…';
  String _result = '尚未操作';

  Future<void> _loadStatus() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      setState(() => _status =
          'iOS ${map?['systemVersion']} / supportsAlt=${map?['supportsAlt']} / 磁盘声明=${map?['diskHasProbe']} / 散文件${map?['looseFiles']}');
    } catch (e) {
      setState(() => _status = 'status 异常：$e');
    }
  }

  Future<void> _switch() async {
    try {
      await _channel.invokeMethod('set');
      setState(() => _result = '✓ set 成功——重启 App 后桌面图标应变为 probe 图案。');
    } on PlatformException catch (e) {
      setState(() => _result = '✗ set 失败：${e.code} ${e.message}\n详情：${e.details}');
    } catch (e) {
      setState(() => _result = '✗ set 异常：$e');
    }
  }

  Future<void> _reset() async {
    try {
      await _channel.invokeMethod('reset');
      setState(() => _result = '✓ reset 成功——重启 App 后桌面图标应恢复为主图标。');
    } on PlatformException catch (e) {
      setState(() => _result = '✗ reset 失败：${e.code} ${e.message}\n详情：${e.details}');
    } catch (e) {
      setState(() => _result = '✗ reset 异常：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('iOS 图标切换探针')),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(_status, style: TextStyle(fontSize: 15)),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(_result, style: TextStyle(fontSize: 15)),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _switch,
              child: const Text('切换为 probe 图标'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _reset,
              child: const Text('恢复主图标'),
            ),
          ],
        ),
      ),
    );
  }
}
