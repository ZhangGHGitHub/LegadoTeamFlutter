/// Web 服务访问地址解析假实现（M1 我的页测试）
///
/// 默认实现走 `dart:io NetworkInterface.list`，在 `testWidgets` 的
/// FakeAsync 区内真实 IO 不会完成——若不注入，设置页初始化/启动服务时
/// 地址解析 await 会悬挂（地址与后续状态更新都不落地）。测试统一注入
/// 固定 host 的同步实现。
library;

import 'dart:async';

import 'package:flutter_legado/src/services/web_service_address_resolver.dart';

class FakeWebServiceAddressResolver implements WebServiceAddressResolver {
  FakeWebServiceAddressResolver({
    this.host = '192.168.1.20',
    this.throwOnResolve = false,
  });

  /// 固定 host（测试可在用例中改写，模拟回到前台后 IP 变化）
  String host;

  /// 模拟枚举失败（验证地址为空时操作按钮隐藏）
  final bool throwOnResolve;

  /// 记录解析请求端口（断言端口取自状态串而非配置；逐用例新建实例）
  final List<int> resolvedPorts = [];

  @override
  Future<String> resolve(int port) async {
    resolvedPorts.add(port);
    if (throwOnResolve) {
      throw StateError('模拟网卡枚举失败');
    }
    return 'http://$host:$port';
  }
}

/// 永不完成的地址解析（模拟网卡枚举卡死）
///
/// 用于验证启动成功后开关/状态先落定、不出现 spinner，地址异步晚到。
class NeverCompletingWebServiceAddressResolver
    implements WebServiceAddressResolver {
  final Completer<String> _completer = Completer<String>();

  @override
  Future<String> resolve(int port) => _completer.future;
}
