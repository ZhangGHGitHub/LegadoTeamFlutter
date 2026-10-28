// 源分享口令编解码向量测试（批25）
//
// 向量来源：直接编译 Android 原版 `SourceSharePassphrase.kt`
// （gedoor/legado 基线，Kotlin stdlib 2.2.20 + JDK 17）并运行生成，
// 非手算/推演——因此同一时间戳下的口令字符串、随机替换、过期 token
// 与解码分支均与 Kotlin 实现逐字一致。
import 'package:flutter_legado/src/services/source_share_passphrase.dart';
import 'package:flutter_test/flutter_test.dart';

/// 解码结果比较串（便于表驱动断言）
String describe(SourcePassphraseDecodeResult result) => switch (result) {
      SourcePassphraseSuccess(:final value) =>
        'success|${value.url}|${value.type.code}|${value.expiresAt}|'
            '${value.customWord}',
      SourcePassphraseNotFound() => 'notFound',
      SourcePassphraseInvalid() => 'invalid',
      SourcePassphraseExpired() => 'expired',
    };

void main() {
  group('encode：Kotlin 原版向量（逐字对照）', () {
    // (case, url, type, days, time, passphrase, expiresAt)
    const cases = <(
      String,
      String,
      SourcePassphraseType,
      int,
      int,
      String,
      int,
    )>[
      (
        'A-https-booksource-permanent',
        'https://www.example.com/books/source.json',
        SourcePassphraseType.bookSource,
        0,
        1700000000000,
        '复制口令到阅读导入#L:www电example店🌐1岗books岗source店🚢！sy©0¥Legado^',
        0,
      ),
      (
        'B-https-chinese-rss-30d',
        'https://www.example.com/中文/书源.json',
        SourcePassphraseType.rssSource,
        30,
        1729999999999,
        '复制口令到阅读导入#L:www。example。🛜1刚中文钢书源垫穿！dy©1732591¥Legado^',
        1732591000000,
      ),
      (
        'C-http-zip-dict-1d',
        'http://example.com/a.zip',
        SourcePassphraseType.dictRule,
        1,
        1730000000000,
        '复制口令到阅读导入#L0:example垫🌏1钢a殿压！zd©1730086¥Legado^',
        1730086000000,
      ),
      (
        'D-https-json-digits-domains-replace-36500d',
        'https://cdn.example.com:8443/a-b_c~d.json?x=4&y=5&z=6',
        SourcePassphraseType.replaceRule,
        36500,
        1712345678901,
        '复制口令到阅读导入#L:cdn垫example电🌏1:8🕓时3钢a-b_c~d电串?x=时&y=五&z=留！jh©4865945¥Legado^',
        4865945000000,
      ),
      (
        'E-https-many-domains-toc-permanent',
        'https://a.b.com/1/2/3/4/5/6/0/me/net/org/xyz',
        SourcePassphraseType.tocRule,
        0,
        0,
        '复制口令到阅读导入#L:a殿b垫🛜1钢1钢2刚3钢🕓🎹勿🎹陆钢灵岗🌐9岗🌐3刚🌏7🎹🌏8！ml©0¥Legado^',
        0,
      ),
      (
        'F-https-emoji-chinese-tts-7d',
        'https://example.cn/书/😀?q=中文',
        SourcePassphraseType.ttsRule,
        7,
        1729999999999,
        '复制口令到阅读导入#L:example。🌏2钢书刚😀?q=中文！ld©1730604¥Legado^',
        1730604000000,
      ),
      (
        'G-https-net-autotask-100d',
        'https://example.net/abc',
        SourcePassphraseType.autoTask,
        100,
        1600000000000,
        '复制口令到阅读导入#L:example垫🛜3钢abc！rw©1608640¥Legado^',
        1608640000000,
      ),
      (
        'H-percent-encoded',
        'https://example.com/100%25.json',
        SourcePassphraseType.bookSource,
        0,
        1700000000000,
        '复制口令到阅读导入#L:example电🛜1刚1灵灵百2🕔垫船！sy©0¥Legado^',
        0,
      ),
      (
        'O-boundary--5',
        'https://example.com/a.json',
        SourcePassphraseType.bookSource,
        -5,
        1700000000000,
        '复制口令到阅读导入#L:example电🛜1刚a殿传！sy©0¥Legado^',
        0,
      ),
      (
        'O-boundary-0',
        'https://example.com/a.json',
        SourcePassphraseType.bookSource,
        0,
        1700000000000,
        '复制口令到阅读导入#L:example电🛜1刚a殿传！sy©0¥Legado^',
        0,
      ),
      (
        'O-boundary-1',
        'https://example.com/a.json',
        SourcePassphraseType.bookSource,
        1,
        1700000000000,
        '复制口令到阅读导入#L:example电🛜1刚a殿传！sy©1700086¥Legado^',
        1700086000000,
      ),
      (
        'O-boundary-36500',
        'https://example.com/a.json',
        SourcePassphraseType.bookSource,
        36500,
        1700000000000,
        '复制口令到阅读导入#L:example电🛜1刚a殿传！sy©4853600¥Legado^',
        4853600000000,
      ),
      (
        'O-boundary-36501',
        'https://example.com/a.json',
        SourcePassphraseType.bookSource,
        36501,
        1700000000000,
        '复制口令到阅读导入#L:example电🛜1刚a殿传！sy©4853600¥Legado^',
        4853600000000,
      ),
    ];

    for (final c in cases) {
      test(c.$1, () {
        final passphrase = SourceSharePassphrase.encode(
          url: c.$2,
          type: c.$3,
          expiryDays: c.$4,
          time: c.$5,
        );
        expect(passphrase, c.$6, reason: '口令字符串须与 Kotlin 逐字一致');

        final now = SourceSharePassphrase.decode(passphrase, time: c.$5);
        expect(describe(now), 'success|${c.$2}|${c.$3.code}|${c.$7}|Legado');

        // 早 1 秒仍在有效期内
        final early = SourceSharePassphrase.decode(
          passphrase,
          time: c.$5 - 1000,
        );
        expect(describe(early), startsWith('success|'));
      });
    }

    test('过期判定：超过有效期返回 expired', () {
      final passphrase = SourceSharePassphrase.encode(
        url: 'https://example.com/a.json',
        type: SourcePassphraseType.bookSource,
        expiryDays: 1,
        time: 1700000000000,
      );
      final late = SourceSharePassphrase.decode(
        passphrase,
        time: 1700000000000 + 400 * SourceSharePassphrase.millisecondsPerDay,
      );
      expect(describe(late), 'expired');
    });

    test('永久口令不随时间过期', () {
      final passphrase = SourceSharePassphrase.encode(
        url: 'https://example.com/a.json',
        type: SourcePassphraseType.bookSource,
        expiryDays: 0,
        time: 1700000000000,
      );
      final late = SourceSharePassphrase.decode(
        passphrase,
        time: 1700000000000 + 1000 * SourceSharePassphrase.millisecondsPerDay,
      );
      expect(describe(late), 'success|https://example.com/a.json|sy|0|Legado');
    });
  });

  group('canEncode：与原版 unsafe/URI 口径一致', () {
    const safe = <String>[
      'https://www.example.com/books/source.json',
      'https://www.example.com/中文/书源.json',
      'http://example.com/a.zip',
      'https://cdn.example.com:8443/a-b_c~d.json?x=4&y=5&z=6',
      'https://example.com/100%25.json',
      // 批25b P2-1：IPv6 字面量主机（JDK 17 `URI(...).toURL().host`
      // 对 `https://[::1]/a` 返回 `[::1]`，原版 canEncode 为 true）
      'https://[::1]/a',
      'https://[2001:db8::1]:8443/source.json',
    ];
    for (final url in safe) {
      test('safe $url', () {
        expect(SourceSharePassphrase.canEncode(url), isTrue);
      });
    }

    // Kotlin 原版向量 I~N：非法转义 / 保留分隔符 / 空格 / 无协议 / 大写协议 / 空 host
    const unsafe = <String>[
      'https://example.com/a.b%c/d',
      'https://example.com/a！b.json',
      'https://exa mple.com/a.json',
      'example.com/a.json',
      'HTTPS://example.com/a.json',
      'https:///a.json',
      // 批25b P3-1：Java URI 拒绝的 Unicode 空格类 / C1 控制字符
      'https://example.com/a\u00A0b.json', // NBSP
      'https://example.com/a\u3000b.json', // 表意空格 U+3000
      'https://example.com/a\u0080b.json', // C1 控制字符 U+0080
      'https://example.com/a\u0085b.json', // NEL（C1 控制字符）
      'https://example.com/a\u2028b.json', // LINE SEPARATOR
      'https://example.com/a\u2029b.json', // PARAGRAPH SEPARATOR
    ];
    for (final url in unsafe) {
      test('unsafe $url', () {
        expect(SourceSharePassphrase.canEncode(url), isFalse);
      });
      test('encode rejects $url', () {
        expect(
          () => SourceSharePassphrase.encode(
            url: url,
            type: SourcePassphraseType.bookSource,
            time: 1700000000000,
          ),
          throwsArgumentError,
        );
      });
    }
  });

  group('decode：Kotlin 原版手工向量', () {
    const cases = <(String, String, int, String)>[
      ('P-not-found', 'hello world', 1700000000000, 'notFound'),
      ('Q-prefix-only', '复制口令到阅读导入', 1700000000000, 'invalid'),
      (
        'R-https-marker-basic',
        '复制口令到阅读导入#L:example电com/a！sy©0¥Legado^',
        1700000000000,
        'success|https://example.com/a|sy|0|Legado',
      ),
      (
        'S-http-marker-basic',
        '复制口令到阅读导入#L0:example电com/a！dy©0¥Legado^',
        1700000000000,
        'success|http://example.com/a|dy|0|Legado',
      ),
      (
        'T-trailing-text',
        'prefix 复制口令到阅读导入#L:example电com/a！sy©0¥Legado^ suffix',
        1700000000000,
        'success|https://example.com/a|sy|0|Legado',
      ),
      (
        'U-dot-mapping',
        '复制口令到阅读导入#L:example电com/a店json！zd©0¥Legado^',
        1700000000000,
        'success|https://example.com/a.json|zd|0|Legado',
      ),
      (
        'V-percent-mapping-invalid-uri',
        '复制口令到阅读导入#L:example白com/a！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'W-percent-mapping-valid-uri',
        '复制口令到阅读导入#L:example电com/100百25店json！sy©0¥Legado^',
        1700000000000,
        'success|https://example.com/100%25.json|sy|0|Legado',
      ),
      (
        'X-unknown-type',
        '复制口令到阅读导入#L:example电com/a！xx©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'Y-non-digit-expiry',
        '复制口令到阅读导入#L:example电com/a！sy©abc¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'Z-7digit-expiry',
        '复制口令到阅读导入#L:example电com/a！sy©1712345¥Legado^',
        1700000000000,
        'success|https://example.com/a|sy|1712345000000|Legado',
      ),
      (
        'AA-10digit-expiry',
        '复制口令到阅读导入#L:example电com/a！sy©1712345678¥Legado^',
        1700000000000,
        'success|https://example.com/a|sy|1712345678000|Legado',
      ),
      (
        'AB-13digit-expired',
        '复制口令到阅读导入#L:example电com/a！sy©1234567890123¥Legado^',
        1700000000000,
        'expired',
      ),
      (
        'AC-13digit-future',
        '复制口令到阅读导入#L:example电com/a！sy©1712345678901¥Legado^',
        1700000000000,
        'success|https://example.com/a|sy|1712345678901|Legado',
      ),
      (
        'AD-13digit-future-at-zero-time',
        '复制口令到阅读导入#L:example电com/a！sy©1712345678901¥Legado^',
        0,
        'success|https://example.com/a|sy|1712345678901|Legado',
      ),
      (
        'AE-empty-expiry',
        '复制口令到阅读导入#L:example电com/a！sy©¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AF-empty-custom-word',
        '复制口令到阅读导入#L:example电com/a！sy©0¥^',
        1700000000000,
        'invalid',
      ),
      (
        'AG-no-end-marker',
        '复制口令到阅读导入#L:example电com/a！sy©0¥Legado',
        1700000000000,
        'invalid',
      ),
      (
        'AH-no-marker',
        '复制口令到阅读导入example电com/a！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AI-double-marker-min-index',
        '复制口令到阅读导入#L:example电com/a#L:extra！sy©0¥Legado^',
        1700000000000,
        'success|https://example.com/ahttps://extra|sy|0|Legado',
      ),
      (
        'AJ-expiry-1digit-nonzero',
        '复制口令到阅读导入#L:example电com/a！sy©1¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AK-8digit-expiry-invalid',
        '复制口令到阅读导入#L:example电com/a！sy©12345678¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AL-space-in-url-invalid',
        '复制口令到阅读导入#L:example电com/a b！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AM-pipe-in-url-invalid',
        '复制口令到阅读导入#L:example电com/a|b！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AN-uppercase-marker-url',
        '复制口令到阅读导入#L:EXAMPLE电com/a！sy©0¥Legado^',
        1700000000000,
        'success|https://EXAMPLE.com/a|sy|0|Legado',
      ),
      // 批25b P2-1：IPv6 字面量主机（方括号原样透传，Java URI host 有效）
      (
        'AO-ipv6-literal-host',
        '复制口令到阅读导入#L:[::1]/a！sy©0¥Legado^',
        1700000000000,
        'success|https://[::1]/a|sy|0|Legado',
      ),
      (
        'AP-ipv6-literal-host-with-port',
        '复制口令到阅读导入#L:[2001:db8::1]:8443/a！dy©0¥Legado^',
        1700000000000,
        'success|https://[2001:db8::1]:8443/a|dy|0|Legado',
      ),
      // 批25b P3-3：分隔符缺失
      (
        'AQ-missing-type-separator',
        '复制口令到阅读导入#L:example电com/a©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AR-missing-metadata-separator',
        '复制口令到阅读导入#L:example电com/a！sy0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AS-missing-expiry-separator',
        '复制口令到阅读导入#L:example电com/a！sy©0Legado^',
        1700000000000,
        'invalid',
      ),
      // 批25b P3-3：过期边界——刚好等于过期时刻仍有效，晚 1ms 才过期
      (
        'AT-expiry-equals-now',
        '复制口令到阅读导入#L:example电com/a！sy©1712345678901¥Legado^',
        1712345678901,
        'success|https://example.com/a|sy|1712345678901|Legado',
      ),
      (
        'AU-expiry-one-ms-past',
        '复制口令到阅读导入#L:example电com/a！sy©1712345678901¥Legado^',
        1712345678902,
        'expired',
      ),
      // 批25b P3-3：`-1` 不是本实现/原版的永久标记（仅 0 表示永久）
      (
        'AV-negative-expiry-token',
        '复制口令到阅读导入#L:example电com/a！sy©-1¥Legado^',
        1700000000000,
        'invalid',
      ),
      // 批25b P3-1：解码 URL 含 NBSP（Java URI 拒绝）
      (
        'AW-nbsp-in-url',
        '复制口令到阅读导入#L:example电com/a\u00A0b！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      // 批25b P3-1：解码 URL 含 C1 控制字符 U+0080 / NEL U+0085
      (
        'AX-c1-control-in-url',
        '复制口令到阅读导入#L:example电com/a\u0080b！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AY-nel-in-url',
        '复制口令到阅读导入#L:example电com/a\u0085b！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
      (
        'AZ-ideographic-space-in-url',
        '复制口令到阅读导入#L:example电com/a\u3000b！sy©0¥Legado^',
        1700000000000,
        'invalid',
      ),
    ];

    for (final c in cases) {
      test(c.$1, () {
        expect(
          describe(SourceSharePassphrase.decode(c.$2, time: c.$3)),
          c.$4,
        );
      });
    }
  });

  group('类型与辅助', () {
    test('7 类 code 与原版一致', () {
      expect(
        SourcePassphraseType.values.map((t) => t.code).toList(),
        ['sy', 'dy', 'zd', 'jh', 'ml', 'ld', 'rw'],
      );
      for (final type in SourcePassphraseType.values) {
        expect(SourcePassphraseType.fromCode(type.code), type);
      }
      expect(SourcePassphraseType.fromCode('xx'), isNull);
    });

    test('looksLikePassphrase 仅按前缀判定', () {
      expect(
        SourceSharePassphrase.looksLikePassphrase(
          '复制口令到阅读导入#L:example电com/a！sy©0¥Legado^',
        ),
        isTrue,
      );
      expect(
        SourceSharePassphrase.looksLikePassphrase('https://example.com/a'),
        isFalse,
      );
    });

    test('全部 7 类均可编码并解码回原类型', () {
      const url = 'https://example.com/a.json';
      for (final type in SourcePassphraseType.values) {
        final passphrase = SourceSharePassphrase.encode(
          url: url,
          type: type,
          time: 1700000000000,
        );
        final result = SourceSharePassphrase.decode(
          passphrase,
          time: 1700000000000,
        );
        expect(result, isA<SourcePassphraseSuccess>());
        expect((result as SourcePassphraseSuccess).value.type, type);
      }
    });
  });
}
