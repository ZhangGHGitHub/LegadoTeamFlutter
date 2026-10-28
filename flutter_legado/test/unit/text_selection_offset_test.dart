/// 长按选区 → 章节偏移换算测试（批34b P3-2）
///
/// 段落渲染文本含首行缩进全角空格（不在章节正文中），高亮 chapterPos/
/// chapterPosEnd 必须扣除缩进列。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart';

void main() {
  group('chapterOffsetOfSelection', () {
    test('未精细选择（整段）直接取段落起点', () {
      expect(
        chapterOffsetOfSelection(
          paragraphText: '　　第一段正文',
          chapterPos: 120,
          selection: '',
          fineSelection: false,
        ),
        120,
      );
    });

    test('精细选区扣除首行缩进列', () {
      // 渲染文本：2 个全角空格缩进 + 正文；选区「第二」在渲染文本 index 4
      const paragraph = '　　第一段第二句';
      expect(
        chapterOffsetOfSelection(
          paragraphText: paragraph,
          chapterPos: 100,
          selection: '第二',
          fineSelection: true,
        ),
        100 + paragraph.indexOf('第二') - 2,
      );
      // 选区从缩进列开始（用户框住缩进）→ 仍落到段落正文起点
      expect(
        chapterOffsetOfSelection(
          paragraphText: paragraph,
          chapterPos: 100,
          selection: '　　第',
          fineSelection: true,
        ),
        100,
      );
    });

    test('选区不在段落文本内时回退段落起点（不越界）', () {
      expect(
        chapterOffsetOfSelection(
          paragraphText: '　　正文',
          chapterPos: 7,
          selection: '不存在的文本',
          fineSelection: true,
        ),
        7,
      );
    });
  });
}
