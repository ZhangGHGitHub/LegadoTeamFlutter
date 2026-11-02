import 'dart:io';

/// 网卡地址条目（纯数据，来源 `NetworkInterface` 枚举）
///
/// [M1 复核 P1-2 | 2026-11-03] 抽成纯数据后可对 host 选择策略做确定性单测；
/// 生产路径由默认枚举函数 `NetworkInterface.list` 映射而来。
class NetworkAddressEntry {
  const NetworkAddressEntry({
    required this.interfaceName,
    required this.address,
  });

  /// 网卡名（如 `wlan0` / `en0` / `tun0` / `vEthernet (Default Switch)`）
  final String interfaceName;

  /// 点分十进制 IPv4 地址
  final String address;

  @override
  String toString() => '$interfaceName=$address';
}

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
/// [M1 复核 P1-2] 接口选择策略（纯函数 [selectHost]）：
/// 1. 过滤 VPN/虚拟网卡（tun/utun/ppp/veth/docker/vEthernet/vmnet/rmnet 等），
///    避免把 Radmin/Hyper-V/WSL 地址展示给用户；
/// 2. 优先 `wlan`/`wifi`/`en0` 等真实无线/主网卡；
/// 3. 其次按私网网段（192.168 > 10 > 172.16-31 > 其他）；
/// 4. 同优先级按「网卡名 → IPv4 数值」升序确定性 tie-break。
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
  /// [enumerate] 为网卡枚举 seam：默认走 [NetworkInterface.list]；测试可
  /// 注入固定条目验证过滤/排序，无需依赖宿主真实网卡。
  const LanWebServiceAddressResolver({
    Future<List<NetworkAddressEntry>> Function()? enumerate,
  }) : _enumerate = enumerate;

  final Future<List<NetworkAddressEntry>> Function()? _enumerate;

  /// 无可用非回环 IPv4 时的回环地址
  static const String loopbackHost = '127.0.0.1';

  /// VPN/虚拟网卡接口名标记（小写包含匹配）
  static const List<String> virtualInterfaceMarkers = [
    'tun',
    'utun',
    'ppp',
    'veth',
    'docker',
    'vethernet',
    'vmnet',
    'rmnet',
    'tap',
    'wg',
    'tailscale',
    'zerotier',
    'zt',
  ];

  /// 优先选用的真实网卡接口名标记（小写包含匹配）
  static const List<String> preferredInterfaceMarkers = ['wlan', 'wifi', 'en0'];

  /// Rust `RustApi.getServerStatus()` 统一描述串 `running on port X` 的
  /// 端口提取（契约来源：`rust_api_media_format.part.dart`；
  /// `MockBookApi.getServerStatus()` 同格式，`mock_book_api_media_format.part.dart`）。
  /// 生产/测试两条状态串必须保持该契约，否则这里回落配置端口。
  static final RegExp _statusPortPattern = RegExp(
    r'port\s+(\d+)',
    caseSensitive: false,
  );

  @override
  Future<String> resolve(int port) async {
    final host = await resolveHost();
    return format(host, port);
  }

  /// 取可访问 host；枚举失败/无候选回落 [loopbackHost]
  Future<String> resolveHost() async {
    try {
      final entries = await (_enumerate ?? _enumerateNetworkInterfaces)();
      return selectHost(entries);
    } catch (_) {
      // 平台不支持/权限不足/枚举异常：回落回环，不阻断 Web 服务 UI
      return loopbackHost;
    }
  }

  /// 默认枚举：`NetworkInterface.list` → 纯数据条目
  static Future<List<NetworkAddressEntry>> _enumerateNetworkInterfaces() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (address.type == InternetAddressType.IPv4 &&
              !address.isLoopback &&
              !address.isLinkLocal)
            NetworkAddressEntry(
              interfaceName: interface.name,
              address: address.address,
            ),
    ];
  }

  /// 纯函数：从网卡条目中选择展示 host（测试直接覆盖该策略）
  static String selectHost(List<NetworkAddressEntry> entries) {
    final candidates = entries.where((entry) {
      if (_isVirtualInterface(entry.interfaceName)) return false;
      final parsed = InternetAddress.tryParse(entry.address);
      if (parsed == null || parsed.type != InternetAddressType.IPv4) {
        return false;
      }
      if (parsed.isLoopback || parsed.isLinkLocal) return false;
      return true;
    }).toList();
    if (candidates.isEmpty) return loopbackHost;
    candidates.sort(_compareEntries);
    return candidates.first.address;
  }

  static int _compareEntries(NetworkAddressEntry a, NetworkAddressEntry b) {
    final preferredA = _isPreferredInterface(a.interfaceName) ? 0 : 1;
    final preferredB = _isPreferredInterface(b.interfaceName) ? 0 : 1;
    if (preferredA != preferredB) return preferredA - preferredB;
    final rankA = _privateNetworkRank(a.address);
    final rankB = _privateNetworkRank(b.address);
    if (rankA != rankB) return rankA - rankB;
    final nameCompare = a.interfaceName.toLowerCase().compareTo(
      b.interfaceName.toLowerCase(),
    );
    if (nameCompare != 0) return nameCompare;
    return _ipv4Value(a.address).compareTo(_ipv4Value(b.address));
  }

  static bool _isVirtualInterface(String interfaceName) {
    final name = interfaceName.toLowerCase();
    return virtualInterfaceMarkers.any(name.contains);
  }

  static bool _isPreferredInterface(String interfaceName) {
    final name = interfaceName.toLowerCase();
    return preferredInterfaceMarkers.any(name.contains);
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

  static int _ipv4Value(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return -1;
    var value = 0;
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return -1;
      value = (value << 8) | octet;
    }
    return value;
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
