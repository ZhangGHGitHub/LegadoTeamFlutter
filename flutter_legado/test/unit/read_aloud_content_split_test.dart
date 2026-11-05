// 朗读内容划分纯函数测试（设置批5b）
//
// 覆盖：
// 1) default 运行时归一整段（不是句级）、未知存储值回退 default；
// 2) paragraph：有空行时空行分段并保留段内单换行；无空行（TXT/在线书）
//    逐行切分，CRLF 同样覆盖；
// 3) symbols：选中标点切分、连续标点同单元、保留标点、非法字符过滤、
//    空集合回退句末标点；
// 4) page：按页首偏移切分、补齐 0/章末、越界过滤、空页跳过、
//    无分页信息回退整段；
// 5) 所有模式：start/end 与 substring 一致、不重叠、除首尾空白外不丢字。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/utils/read_aloud_content_split.dart';

void main() {
  group('模式解析', () {
    test('fromStorage：四个合法值 + 未知值回退 default', () {
      expect(
        ReadAloudContentSplitMode.fromStorage('default'),
        ReadAloudContentSplitMode.defaultMode,
      );
      expect(
        ReadAloudContentSplitMode.fromStorage('paragraph'),
        ReadAloudContentSplitMode.paragraph,
      );
      expect(
        ReadAloudContentSplitMode.fromStorage('page'),
        ReadAloudContentSplitMode.page,
      );
      expect(
        ReadAloudContentSplitMode.fromStorage('symbols'),
        ReadAloudContentSplitMode.symbols,
      );
      expect(
        ReadAloudContentSplitMode.fromStorage('bogus'),
        ReadAloudContentSplitMode.defaultMode,
      );
      expect(
        ReadAloudContentSplitMode.fromStorage(null),
        ReadAloudContentSplitMode.defaultMode,
      );
    });

    test('default 运行时归一为 paragraph，其余保持自身', () {
      expect(
        ReadAloudContentSplitMode.defaultMode.resolved,
        ReadAloudContentSplitMode.paragraph,
      );
      expect(
        ReadAloudContentSplitMode.paragraph.resolved,
        ReadAloudContentSplitMode.paragraph,
      );
      expect(
        ReadAloudContentSplitMode.page.resolved,
        ReadAloudContentSplitMode.page,
      );
      expect(
        ReadAloudContentSplitMode.symbols.resolved,
        ReadAloudContentSplitMode.symbols,
      );
    });
  });

  group('标点解析', () {
    test('空/全非法回退句末标点 。！？…', () {
      expect(
        resolveReadAloudSymbols(null),
        kReadAloudDefaultSentenceEndSymbols,
      );
      expect(resolveReadAloudSymbols(''), kReadAloudDefaultSentenceEndSymbols);
      expect(
        resolveReadAloudSymbols('abc123'),
        kReadAloudDefaultSentenceEndSymbols,
      );
    });

    test('过滤非法字符并按展示顺序去重', () {
      expect(resolveReadAloudSymbols('！a。x，。'), '。！，');
    });

    test('编码：过滤非法、去重、按展示顺序；空集合返回空串', () {
      expect(encodeReadAloudSymbols(['！', '。', '，', '。']), '。！，');
      expect(encodeReadAloudSymbols([]), '');
      expect(encodeReadAloudSymbols(['a', 'b']), '');
      expect(
        readAloudSymbolSet(''),
        kReadAloudDefaultSentenceEndSymbols.split('').toSet(),
      );
    });

    test('decode：兼容历史 String 与参考版 List<String>/StringSet 形态', () {
      expect(decodeReadAloudSymbols('。！'), '。！');
      expect(decodeReadAloudSymbols(<String>['。', '！']), '。！');
      expect(decodeReadAloudSymbols(<Object?>['。', 1, '！']), '。！');
      expect(decodeReadAloudSymbols(null), '');
      expect(decodeReadAloudSymbols(42), '');
    });
  });

  group('paragraph（整段）', () {
    test('空行分段，段内换行保留', () {
      const content = '第一段\n第二行\n\n第二段';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.paragraph,
      );
      expect(units.map((u) => u.text).toList(), ['第一段\n第二行', '第二段']);
      expect(units[0].start, 0);
      expect(units[0].end, 7);
      expect(units[1].start, 9);
      expect(units[1].end, content.length);
    });

    test('存在空行时 default 与 paragraph 一致（段内单换行保留）', () {
      const content = '甲\n乙\n\n丙\n丁';
      final byDefault = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.defaultMode,
      );
      final byParagraph = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.paragraph,
      );
      expect(byDefault, byParagraph);
      expect(byDefault.map((u) => u.text).toList(), ['甲\n乙', '丙\n丁']);
    });

    test('无空行（TXT/在线书单换行）：按每个换行切，不整章合成一个单元', () {
      const content = '第一行\n第二行\n第三行';
      for (final mode in [
        ReadAloudContentSplitMode.defaultMode,
        ReadAloudContentSplitMode.paragraph,
      ]) {
        final units = splitReadAloudUnits(content, mode);
        expect(units.map((u) => u.text).toList(), ['第一行', '第二行', '第三行']);
        expect(units[1].start, content.indexOf('第二行'));
      }
    });

    test('CRLF：空行分段优先；无空行时按 CRLF 逐行切', () {
      const blankLine = '甲\r\n乙\r\n\r\n丙';
      expect(
        splitReadAloudUnits(
          blankLine,
          ReadAloudContentSplitMode.paragraph,
        ).map((u) => u.text).toList(),
        ['甲\r\n乙', '丙'],
      );
      const singleLines = '第一行\r\n第二行\r\n第三行';
      expect(
        splitReadAloudUnits(
          singleLines,
          ReadAloudContentSplitMode.paragraph,
        ).map((u) => u.text).toList(),
        ['第一行', '第二行', '第三行'],
      );
    });

    test('首尾空白剔除，纯空白段不产生单元', () {
      const content = '  甲  \n\n \n\n  乙  ';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.paragraph,
      );
      expect(units.map((u) => u.text).toList(), ['甲', '乙']);
      expect(units[0].start, 2);
      expect(units[0].end, 3);
      expect(units[1].start, content.lastIndexOf('乙'));
    });

    test('纯空白内容返回空列表', () {
      expect(
        splitReadAloudUnits('  \n\n  ', ReadAloudContentSplitMode.paragraph),
        isEmpty,
      );
      expect(
        splitReadAloudUnits('', ReadAloudContentSplitMode.defaultMode),
        isEmpty,
      );
    });
  });

  group('symbols（按标点）', () {
    test('按选中标点切分并保留标点', () {
      const content = '第一句。第二句！第三句';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.symbols,
        symbols: '。！',
      );
      expect(units.map((u) => u.text).toList(), ['第一句。', '第二句！', '第三句']);
    });

    test('连续标点归入同一单元（…… / ！？）', () {
      const content = '甲……乙！？丙';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.symbols,
        symbols: '…！？',
      );
      expect(units.map((u) => u.text).toList(), ['甲……', '乙！？', '丙']);
    });

    test('先按行再逐行按标点：无标点行不跨行合并（参考 lineParagraphs）', () {
      const content = '无标点第一行\n无标点第二行\n带标点。结尾';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.symbols,
        symbols: '。',
      );
      expect(units.map((u) => u.text).toList(), [
        '无标点第一行',
        '无标点第二行',
        '带标点。',
        '结尾',
      ]);
      expect(units[1].start, content.indexOf('无标点第二行'));
      expect(units[3].start, content.indexOf('结尾'));
    });

    test('未选择标点 → 回退句末标点，不按逗号切分', () {
      const content = '甲，乙。丙！丁';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.symbols,
        symbols: '',
      );
      expect(units.map((u) => u.text).toList(), ['甲，乙。', '丙！', '丁']);
    });

    test('非法标点被忽略，仅按合法选中标点切分', () {
      const content = '甲，乙。丙';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.symbols,
        symbols: 'a，z',
      );
      expect(units.map((u) => u.text).toList(), ['甲，', '乙。丙']);
    });

    test('标点后紧跟换行/空白时，下一单元剔除前导空白', () {
      const content = '甲。\n 乙。';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.symbols,
        symbols: '。',
      );
      expect(units.map((u) => u.text).toList(), ['甲。', '乙。']);
      expect(units[1].start, content.indexOf('乙'));
    });
  });

  group('page（按页）', () {
    test('按页首偏移切分，0/章末自动补齐', () {
      const content = '0123456789';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.page,
        pageStarts: const [0, 4, 8],
      );
      expect(units.map((u) => u.text).toList(), ['0123', '4567', '89']);
      expect(units.map((u) => u.start).toList(), [0, 4, 8]);
      expect(units.last.end, content.length);
    });

    test('越界页首过滤；只给章内偏移也能补齐首尾', () {
      const content = '0123456789';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.page,
        pageStarts: const [-5, 4, 20],
      );
      expect(units.map((u) => u.text).toList(), ['0123', '456789']);
    });

    test('页内纯空白页跳过，不产生空单元', () {
      const content = '甲  乙';
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.page,
        pageStarts: const [0, 1, 2],
      );
      expect(units.map((u) => u.text).toList(), ['甲', '乙']);
      expect(units[1].start, content.indexOf('乙'));
    });

    test('页首落在代理对中间：向前对齐，substring 不切开 emoji', () {
      const content = '甲😀乙';
      // 😀 占 UTF-16 两个 code unit（索引 1-2），页首 2 落在代理对中间
      final units = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.page,
        pageStarts: const [2],
      );
      expect(units.map((u) => u.text).toList(), ['甲', '😀乙']);
      for (final unit in units) {
        expect(content.substring(unit.start, unit.end), unit.text);
      }
      expect(units[1].start, 1, reason: '低代理项位置向前对齐到高代理项');
    });

    test('无分页信息（null/空）回退整段', () {
      const content = '甲\n\n乙';
      final fallbackNull = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.page,
      );
      final fallbackEmpty = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.page,
        pageStarts: const [],
      );
      final paragraph = splitReadAloudUnits(
        content,
        ReadAloudContentSplitMode.paragraph,
      );
      expect(fallbackNull, paragraph);
      expect(fallbackEmpty, paragraph);
      expect(fallbackNull.map((u) => u.text).toList(), ['甲', '乙']);
    });
  });

  group('偏移不变量', () {
    const contents = <String>[
      '第一段。\n第二行！\n\n第二段……结束',
      '  前导空白\n\n中间 空格  \n\n尾随空白  ',
      '甲，乙。丙！丁？戊…己；庚，辛、壬：癸.',
    ];
    final modes = ReadAloudContentSplitMode.values;

    test('text == substring(start, end)，单元不重叠、除空白外不丢字', () {
      for (final content in contents) {
        for (final mode in modes) {
          final units = splitReadAloudUnits(
            content,
            mode,
            symbols: '。！？…；，、：',
            pageStarts: const [0, 5, 12, 20],
          );
          var previousEnd = 0;
          for (final unit in units) {
            expect(unit.start, greaterThanOrEqualTo(previousEnd));
            expect(unit.end, greaterThan(unit.start));
            expect(content.substring(unit.start, unit.end), unit.text);
            previousEnd = unit.end;
          }
          String withoutWhitespace(String value) =>
              value.replaceAll(RegExp(r'\s'), '');
          expect(
            units.map((u) => u.text).join().replaceAll(RegExp(r'\s'), ''),
            withoutWhitespace(content),
            reason: '$mode 模式除首尾空白外不得丢字',
          );
        }
      }
    });
  });

  group('备份忽略阅读配置', () {
    test('五个内容分析键均命中 readPrefKeys（勾选忽略时不覆盖本机）', () {
      for (final key in [
        PrefKeys.readAloudContentSplitMode,
        PrefKeys.readAloudContentSplitSymbols,
        PrefKeys.ttsParagraphInterval,
        PrefKeys.speechAnalysisMode,
        PrefKeys.speechAnalysisReasoningLevel,
      ]) {
        expect(
          RestoreIgnorePrefs.readPrefKeys.contains(key),
          isTrue,
          reason: '$key 应随「忽略阅读配置」过滤',
        );
      }
    });
  });
}
