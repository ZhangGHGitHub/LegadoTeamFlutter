import 'dart:io';

/// Web 服务可访问地址解析器
///
/// [M1 我的页信息架构 | full-stack-engineer + UI] 「我的」页 Web 服务运行中
/// 显示可访问地址（参考版 `MyUiState.webServiceAddress`），并提供「复制地址」
/// 「在浏览器中打开」两个操作。
///
/// 地址取**非回环局域网 IPv4**（手机/模拟器在局域网内的可访问地址，对齐
/// Rust 侧 `server_start` 绑定 `0.0.0.0` 的语义）；枚举不到可用网卡
/// （桌面仅回环 / 平台权限受限 / 抛异常）时回落 `http://127.0.0.1:<port>`，
/// 保证 UI 始终有可展示、可复制、可打开的地址。
///
/// 依赖 `dart:io NetworkInterface` 的实现抽成接口，经
/// `webServiceAddressResolverProvider` 注入：widget 测试在 FakeAsync 下
/// 真实网卡枚举不会完成，必须注入固定 IP（见 settings_test.dart）。
abstract class WebServiceAddressResolver {
  /// 解析 [port] 对应的可访问地址（含 scheme，形如 `http://192.168.1.20:1122`）
  Future<String> resolve(int port);
}

/// 局域网 IPv4 优先的默认实现
class LanWebServiceAddressResolver implements WebServiceAddressResolver {
  const LanWebServiceAddressResolver();

  /// 无可用非回环 IPv4 时的回环地址
  static const String loopbackHost = '127.0.0.1';

  /// Rust `getServerStatus()` 统一描述串 `running on port X` 的端口提取
  /// （见 rust_api_media_format.part.dart）。
  static final RegExp _statusPortPattern = RegExp(
    r'port\s+(\d+)',
    caseSensitive: false,
  );

  @override
  Future<String> resolve(int port) async {
    final host = await resolveHost();
    return format(host, port);
  }

  /// 取非回环 IPv4；优先私网网段（192.168/10/172.16-31），避免误选
  /// VPN/虚拟网卡作为「局域网地址」。枚举失败回落 [loopbackHost]。
  Future<String> resolveHost() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final candidates = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv4 ||
              address.isLoopback ||
              address.isLinkLocal) {
            continue;
          }
          candidates.add(address.address);
        }
      }
      if (candidates.isEmpty) return loopbackHost;
      candidates.sort(
        (a, b) => _privateNetworkRank(a).compareTo(_privateNetworkRank(b)),
      );
      return candidates.first;
    } catch (_) {
      // 平台不支持/权限不足/枚举异常：回落回环，不阻断 Web 服务 UI
      return loopbackHost;
    }
  }

  /// 私网网段排序权重（越小越优先）
  static int _privateNetworkRank(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return 3;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    if (first == null || second == null) return 3;
    if (first == 192 && second == 168) return 0;
    if (first == 10) return 1;
    if (first == 172 && second >= 16 && second <= 31) return 2;
    return 3;
  }

  /// 拼接访问地址
  static String format(String host, int port) => 'http://$host:$port';

  /// 从 `running on port X` 状态串解析端口；非运行态或解析失败返回 null
  static int? parsePort(String status) {
    final match = _statusPortPattern.firstMatch(status);
    if (match == null) return null;
    final port = int.tryParse(match.group(1) ?? '');
    if (port == null || port <= 0 || port > 65535) return null;
    return port;
  }
}
