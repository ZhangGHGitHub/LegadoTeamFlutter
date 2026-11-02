/// Web 服务访问地址解析假实现（M1 我的页测试）
///
/// 默认实现走 `dart:io NetworkInterface.list`，在 `testWidgets` 的
/// FakeAsync 区内真实 IO 不会完成——若不注入，设置页初始化/启动服务时
/// 地址解析 await 会悬挂（地址与后续状态更新都不落地）。测试统一注入
/// 固定 host 的同步实现。
library;

import 'package:flutter_legado/src/services/web_service_address_resolver.dart';

class FakeWebServiceAddressResolver implements WebServiceAddressResolver {
  FakeWebServiceAddressResolver({
    this.host = '192.168.1.20',
    this.throwOnResolve = false,
  });

  /// 固定局域网 IP（测试断言 `http://<host>:<port>`）
  final String host;

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
