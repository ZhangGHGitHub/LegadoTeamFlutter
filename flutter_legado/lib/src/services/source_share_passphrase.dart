// 源分享口令编解码（批25）
//
// 逐字对齐 Android 原版 `io.legado.app.help.SourceSharePassphrase`
// （gedoor/legado，2026-10-27 基线）：
// - 映射表（`https://` / `http://` 标记、`.` `%` `/`、`zip` / `json`、
//   数字 4/5/6/0、域名后缀 com/cn/net/org/xyz/me，各带 emoji 同义词）；
// - 编码：按「长键优先」逐 UTF-16 码元替换，随机源与 Kotlin
//   `Random(time)` 完全一致（XorWow 算法），因此同一时间戳产出同一口令；
// - 口令格式：`复制口令到阅读导入<编码URL>！<类型code>©<过期token>¥Legado^`
// - 过期 token 为 `expiresAt` 十进制前 7 位（永久为 `0`），解码兼容
//   1/7/10/13 位数字；
// - URL 合法性沿用原版 `URI(url).toURL().host.isNotBlank()` 口径
//   （Java URI 的 ASCII 白名单 + `%HH` 转义校验，非 ASCII 字符放行）。
//
// 参考版 legado-with-MD3 已移除该功能（无 SourceSharePassphrase /
// shibboleth 文案），本文件属用户 2026-10-27 授权的超集实现。
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

/// 口令可承载的源类型（code 与原版 7 类逐字一致）
enum SourcePassphraseType {
  /// 书源 `sy`
  bookSource('sy'),

  /// RSS 订阅源 `dy`
  rssSource('dy'),

  /// 字典规则 `zd`
  dictRule('zd'),

  /// 替换净化规则 `jh`
  replaceRule('jh'),

  /// TXT 目录规则 `ml`
  tocRule('ml'),

  /// 朗读引擎（HTTP TTS）`ld`
  ttsRule('ld'),

  /// 自动任务 `rw`
  autoTask('rw');

  const SourcePassphraseType(this.code);

  /// 口令中的类型 code
  final String code;

  /// 按 code 反查；未知 code 返回 null
  static SourcePassphraseType? fromCode(String code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// 解码成功的口令内容
@immutable
class SourcePassphraseValue {
  const SourcePassphraseValue({
    required this.url,
    required this.type,
    required this.expiresAt,
    required this.customWord,
  });

  /// 解码后的分享 URL（原版为直链上传的下载地址）
  final String url;

  /// 类型
  final SourcePassphraseType type;

  /// 过期时间戳（毫秒）；0 = 永久
  final int expiresAt;

  /// 校验字（原版固定 `Legado`）
  final String customWord;

  @override
  bool operator ==(Object other) =>
      other is SourcePassphraseValue &&
      other.url == url &&
      other.type == type &&
      other.expiresAt == expiresAt &&
      other.customWord == customWord;

  @override
  int get hashCode => Object.hash(url, type, expiresAt, customWord);

  @override
  String toString() =>
      'SourcePassphraseValue(url=$url, type=${type.code}, '
      'expiresAt=$expiresAt, customWord=$customWord)';
}

/// 解码结果（对应原版 sealed interface DecodeResult）
sealed class SourcePassphraseDecodeResult {
  const SourcePassphraseDecodeResult();
}

/// 成功
class SourcePassphraseSuccess extends SourcePassphraseDecodeResult {
  const SourcePassphraseSuccess(this.value);

  final SourcePassphraseValue value;

  @override
  bool operator ==(Object other) =>
      other is SourcePassphraseSuccess && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// 文本不含口令前缀（不是口令，静默忽略）
class SourcePassphraseNotFound extends SourcePassphraseDecodeResult {
  const SourcePassphraseNotFound();

  @override
  bool operator ==(Object other) => other is SourcePassphraseNotFound;

  @override
  int get hashCode => 0;
}

/// 含前缀但格式非法
class SourcePassphraseInvalid extends SourcePassphraseDecodeResult {
  const SourcePassphraseInvalid();

  @override
  bool operator ==(Object other) => other is SourcePassphraseInvalid;

  @override
  int get hashCode => 1;
}

/// 口令已过期
class SourcePassphraseExpired extends SourcePassphraseDecodeResult {
  const SourcePassphraseExpired();

  @override
  bool operator ==(Object other) => other is SourcePassphraseExpired;

  @override
  int get hashCode => 2;
}

/// 源分享口令编解码器（静态工具类）
class SourceSharePassphrase {
  SourceSharePassphrase._();

  /// 有效期上限（天），对齐原版 MAX_EXPIRY_DAYS
  static const int maxExpiryDays = 36500;

  /// 每天的毫秒数
  static const int millisecondsPerDay = 24 * 60 * 60 * 1000;

  /// 7 位过期 token 的放大倍数（1e6）
  static const int expiryPrecision = 1000000;

  static const String _httpsMarker = '#L:';
  static const String _httpMarker = '#L0:';

  /// 口令前缀（原版 PREFIX）
  static const String prefix = '复制口令到阅读导入';

  /// 校验字（原版 CUSTOM_WORD）
  static const String customWord = 'Legado';

  /// 映射表（插入顺序即原版 linkedMapOf 顺序）
  static const Map<String, List<String>> _mappings = <String, List<String>>{
    'https://': <String>[_httpsMarker],
    'http://': <String>[_httpMarker],
    '.': <String>['电', '店', '垫', '殿', '。'],
    '%': <String>['白', '百', '拜', '摆', '💯'],
    '/': <String>['杠', '刚', '钢', '岗', '🎹'],
    'zip': <String>['压', '亚', '呀', '牙', '🦆'],
    'json': <String>['串', '穿', '船', '传', '🚢'],
    '4': <String>['四', '是', '时', '丝', '🕓'],
    '5': <String>['五', '武', '误', '勿', '🕔'],
    '6': <String>['六', '刘', '留', '陆', '🕕'],
    '0': <String>['零', '另', '玲', '灵', '⏰'],
    'com': <String>['🛜1', '🌐1', '🌏1'],
    'cn': <String>['🛜2', '🌐2', '🌏2'],
    'net': <String>['🛜3', '🌐3', '🌏3'],
    'org': <String>['🛜7', '🌐7', '🌏7'],
    'xyz': <String>['🛜8', '🌐8', '🌏8'],
    'me': <String>['🛜9', '🌐9', '🌏9'],
  };

  /// 编码键：长度降序（等长保持原版 map 插入顺序，Kotlin sortedByDescending 稳定）
  static final List<String> _encodeKeys =
      _stableSortKeysByLengthDesc(_mappings.keys);

  /// 反查表：替换串 → 原串，按替换串长度降序（等长保持原版 flatMap 顺序）
  static final List<MapEntry<String, String>> _reverseMappings =
      _buildReverseMappings();

  /// 不可安全编码的 token：全部替换串 + 4 个分隔符
  static final List<String> _unsafeUrlTokens = <String>[
    for (final replacements in _mappings.values) ...replacements,
    '！',
    '©',
    '¥',
    '^',
  ];

  /// 文本是否带口令前缀（用于分流；是否可解码以 [decode] 为准）
  static bool looksLikePassphrase(String text) => text.contains(prefix);

  /// URL 能否安全编码（原版 canEncode：合法 http(s) 且不含保留 token）
  static bool canEncode(String url) {
    return isSupportedUrl(url) && !_unsafeUrlTokens.any(url.contains);
  }

  /// 编码口令
  ///
  /// [url] 不可安全编码时抛 [ArgumentError]（对应原版 `require`）。
  /// [expiryDays] 超出 `0..maxExpiryDays` 时按原版 `coerceIn` 截断，
  /// 0 表示永久有效。
  static String encode({
    required String url,
    required SourcePassphraseType type,
    int expiryDays = 0,
    int? time,
  }) {
    if (!canEncode(url)) {
      throw ArgumentError.value(
        url,
        'url',
        'URL cannot be safely shared as a passphrase',
      );
    }
    final now = time ?? DateTime.now().millisecondsSinceEpoch;
    final random = _XorWowRandom(
      _toInt32(now),
      _toInt32(now >> 32),
    );
    final encodedUrl = StringBuffer();
    var index = 0;
    while (index < url.length) {
      String? key;
      for (final candidate in _encodeKeys) {
        if (url.startsWith(candidate, index)) {
          key = candidate;
          break;
        }
      }
      if (key == null) {
        encodedUrl.write(url[index]);
        index++;
      } else {
        final replacements = _mappings[key]!;
        encodedUrl.write(replacements[random.nextIntBound(replacements.length)]);
        index += key.length;
      }
    }
    final safeExpiryDays = expiryDays < 0
        ? 0
        : (expiryDays > maxExpiryDays ? maxExpiryDays : expiryDays);
    final expiresAt = safeExpiryDays == 0
        ? 0
        : now + safeExpiryDays * millisecondsPerDay;
    final expiryToken = expiresAt.toString().substring(
      0,
      math.min(7, expiresAt.toString().length),
    );
    return '$prefix$encodedUrl！${type.code}©$expiryToken¥$customWord^';
  }

  /// 解码口令
  ///
  /// 语义逐条对齐原版：前缀可出现在任意位置；取最早的 `#L:`/`#L0:` 标记；
  /// 分隔符顺序与最小长度校验；过期 token 仅接受 1/7/10/13 位数字；
  /// 解码后的 URL 再做合法性与 host 校验。
  static SourcePassphraseDecodeResult decode(
    String text, {
    int? time,
  }) {
    final now = time ?? DateTime.now().millisecondsSinceEpoch;
    final prefixIndex = text.indexOf(prefix);
    if (prefixIndex < 0) return const SourcePassphraseNotFound();
    final markerSearchStart = prefixIndex + prefix.length;
    final httpsIndex = text.indexOf(_httpsMarker, markerSearchStart);
    final httpIndex = text.indexOf(_httpMarker, markerSearchStart);
    int? urlStart;
    if (httpsIndex >= 0) urlStart = httpsIndex;
    if (httpIndex >= 0 && (urlStart == null || httpIndex < urlStart)) {
      urlStart = httpIndex;
    }
    if (urlStart == null) return const SourcePassphraseInvalid();

    final typeSeparator = text.indexOf('！', urlStart);
    if (typeSeparator <= urlStart) return const SourcePassphraseInvalid();
    final metadataSeparator = text.indexOf('©', typeSeparator + 1);
    if (metadataSeparator <= typeSeparator + 1) {
      return const SourcePassphraseInvalid();
    }
    final expirySeparator = text.indexOf('¥', metadataSeparator + 1);
    if (expirySeparator <= metadataSeparator + 1) {
      return const SourcePassphraseInvalid();
    }
    final suffixEnd = text.indexOf('^', expirySeparator + 1);
    if (suffixEnd <= expirySeparator + 1) {
      return const SourcePassphraseInvalid();
    }

    final type = SourcePassphraseType.fromCode(
      text.substring(typeSeparator + 1, metadataSeparator),
    );
    if (type == null) return const SourcePassphraseInvalid();

    final expiryToken = text.substring(metadataSeparator + 1, expirySeparator);
    for (var i = 0; i < expiryToken.length; i++) {
      final code = expiryToken.codeUnitAt(i);
      if (code < 0x30 || code > 0x39) {
        return const SourcePassphraseInvalid();
      }
    }
    final int expiresAt;
    switch (expiryToken.length) {
      case 1:
        if (expiryToken != '0') return const SourcePassphraseInvalid();
        expiresAt = 0;
      case 7:
        expiresAt = int.parse(expiryToken) * expiryPrecision;
      case 10:
        expiresAt = int.parse(expiryToken) * 1000;
      case 13:
        expiresAt = int.parse(expiryToken);
      default:
        return const SourcePassphraseInvalid();
    }
    if (expiresAt > 0 && expiresAt < now) {
      return const SourcePassphraseExpired();
    }

    final url = _decodeUrl(
      text.substring(urlStart, typeSeparator).trim(),
    );
    if (!isSupportedUrl(url)) return const SourcePassphraseInvalid();
    return SourcePassphraseSuccess(
      SourcePassphraseValue(
        url: url,
        type: type,
        expiresAt: expiresAt,
        customWord: text.substring(expirySeparator + 1, suffixEnd),
      ),
    );
  }

  /// 反查替换（长 token 优先，保证 emoji+数字组合先于裸数字命中）
  static String _decodeUrl(String value) {
    final buffer = StringBuffer();
    var index = 0;
    while (index < value.length) {
      MapEntry<String, String>? mapping;
      for (final candidate in _reverseMappings) {
        if (value.startsWith(candidate.key, index)) {
          mapping = candidate;
          break;
        }
      }
      if (mapping == null) {
        buffer.write(value[index]);
        index++;
      } else {
        buffer.write(mapping.value);
        index += mapping.key.length;
      }
    }
    return buffer.toString();
  }

  /// URL 合法性：原版 `URL.startsWith("http(s)://")` + `URI(url).toURL().host`
  static bool isSupportedUrl(String url) {
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      return false;
    }
    if (!_isLegalJavaUri(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.host.trim().isNotEmpty;
  }

  /// Java `java.net.URI` 构造校验（ASCII 白名单 + `%HH` 转义）
  ///
  /// JDK 实测（2026-10-27，本仓库基线 JDK 17）：允许
  /// `!#$&'()*+,-./0-9:;=?@A-Z_a-z~` 与全部非 ASCII 字符；拒绝空格、
  /// 引号、`%` 非两位十六进制、`< > [ \ ] ^ ` { | }` 及控制字符。
  static bool _isLegalJavaUri(String url) {
    const allowedAscii =
        r"!#$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~";
    for (var i = 0; i < url.length; i++) {
      final code = url.codeUnitAt(i);
      if (code >= 0x80) continue;
      if (code == 0x25) {
        // '%' 必须后跟两位十六进制
        if (i + 2 >= url.length) return false;
        if (!_isHex(url.codeUnitAt(i + 1)) ||
            !_isHex(url.codeUnitAt(i + 2))) {
          return false;
        }
        i += 2;
        continue;
      }
      if (!allowedAscii.contains(url[i])) return false;
    }
    return true;
  }

  static bool _isHex(int code) {
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x46) ||
        (code >= 0x61 && code <= 0x66);
  }

  /// 稳定按长度降序排序（Kotlin sortedByDescending 为稳定排序）
  static List<String> _stableSortKeysByLengthDesc(Iterable<String> keys) {
    final indexed = <MapEntry<int, String>>[];
    var i = 0;
    for (final key in keys) {
      indexed.add(MapEntry<int, String>(i++, key));
    }
    indexed.sort((a, b) {
      final byLength = b.value.length.compareTo(a.value.length);
      return byLength != 0 ? byLength : a.key.compareTo(b.key);
    });
    return <String>[for (final entry in indexed) entry.value];
  }

  /// 反查映射：替换串 → 原串，稳定按替换串长度降序
  static List<MapEntry<String, String>> _buildReverseMappings() {
    final flat = <MapEntry<String, String>>[];
    _mappings.forEach((original, replacements) {
      for (final replacement in replacements) {
        flat.add(MapEntry<String, String>(replacement, original));
      }
    });
    final indexed = <MapEntry<int, MapEntry<String, String>>>[];
    for (var i = 0; i < flat.length; i++) {
      indexed.add(MapEntry<int, MapEntry<String, String>>(i, flat[i]));
    }
    indexed.sort((a, b) {
      final byLength =
          b.value.key.length.compareTo(a.value.key.length);
      return byLength != 0 ? byLength : a.key.compareTo(b.key);
    });
    return <MapEntry<String, String>>[for (final e in indexed) e.value];
  }

  /// 有符号 32 位截断（Kotlin Int 语义）
  static int _toInt32(int value) {
    final unsigned = value & 0xFFFFFFFF;
    return unsigned >= 0x80000000 ? unsigned - 0x100000000 : unsigned;
  }
}

/// Kotlin `Random(seed: Long)` 同款 XorWow 随机数生成器
///
/// Kotlin/JVM 的 `Random(seed)` 返回 `XorWowRandom(seed.toInt(),
/// seed.shr(32).toInt())`（非 `java.util.Random`）。口令「逐字对齐」要求
/// 随机序列一致，故按 Kotlin stdlib 2.x 实现重写。
class _XorWowRandom {
  _XorWowRandom(int seed1, int seed2)
      : _x = seed1,
        _y = seed2,
        _z = 0,
        _w = 0,
        _v = SourceSharePassphrase._toInt32(~seed1),
        _addend = SourceSharePassphrase._toInt32(
          (seed1 << 10) ^ ((seed2 & 0xFFFFFFFF) >> 4),
        ) {
    // Kotlin XorWowRandom 构造器固定预热 64 次 nextInt()，随机序列必须一致
    for (var i = 0; i < 64; i++) {
      nextInt();
    }
  }

  int _x;
  int _y;
  int _z;
  int _w;
  int _v;
  int _addend;

  /// 对应 Kotlin `Random.nextInt()`（XorWow 步进）
  ///
  /// 标准 XorWow：`v = t ^ (t << 1) ^ v0 ^ (v0 << 4)`，其中
  /// `t = x ^ (x ushr 2)`；再叠加 addend。
  int nextInt() {
    var t = _x;
    t = _s32(t ^ ((_x & 0xFFFFFFFF) >> 2));
    _x = _y;
    _y = _z;
    _z = _w;
    final oldV = _v;
    _w = oldV;
    final v = _s32(
      _s32(t ^ _s32(t << 1)) ^ oldV ^ _s32(oldV << 4),
    );
    _v = v;
    _addend = _s32(_addend + 362437);
    return _s32(v + _addend);
  }

  /// 对应 Kotlin `Random.nextInt(until)`（until > 0）
  int nextIntBound(int until) {
    if (until <= 0) {
      throw ArgumentError.value(until, 'until', 'must be positive');
    }
    if ((until & -until) == until) {
      // 2 的幂：取 nextInt() 高 fastLog2(until) 位
      final bitCount = until.bitLength - 1;
      return _takeUpperBits(nextInt(), bitCount);
    }
    int bits;
    int value;
    do {
      bits = (nextInt() & 0xFFFFFFFF) >> 1;
      value = bits % until;
    } while (bits - value + (until - 1) < 0);
    return value;
  }

  /// Kotlin RandomKt.takeUpperBits（bitCount = 0 时恒为 0）
  static int _takeUpperBits(int value, int bitCount) {
    if (bitCount <= 0) return 0;
    return (value & 0xFFFFFFFF) >> (32 - bitCount);
  }

  static int _s32(int value) => SourceSharePassphrase._toInt32(value);
}
