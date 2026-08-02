import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';

/// 跨章节连续分页器单元测试
///
/// 测试 CrossChapterPaginator 的全局页索引 ↔ (章节, 章内页) 双向映射。
void main() {
  group('CrossChapterPaginator', () {
    late CrossChapterPaginator paginator;

    setUp(() {
      paginator = CrossChapterPaginator();
    });

    // ===== 基础功能测试 =====

    group('空列表', () {
      test('空列表 totalPages 为 0', () {
        expect(paginator.totalPages(), 0);
      });

      test('空列表 chapterForPage 返回 -1', () {
        expect(paginator.chapterForPage(0), -1);
        expect(paginator.chapterForPage(100), -1);
      });

      test('空列表 pageInChapter 返回 -1', () {
        expect(paginator.pageInChapter(0), -1);
      });

      test('空列表 globalIndexForChapterStart 返回 -1', () {
        expect(paginator.globalIndexForChapterStart(0), -1);
      });

      test('空列表 isValidGlobalIndex 返回 false', () {
        expect(paginator.isValidGlobalIndex(0), false);
        expect(paginator.isValidGlobalIndex(-1), false);
      });

      test('空列表 resolve 返回 null', () {
        expect(paginator.resolve(0), null);
      });
    });

    group('单章节', () {
      setUp(() {
        paginator.addChapter(0, 10); // 第0章，10页
      });

      test('totalPages 正确', () {
        expect(paginator.totalPages(), 10);
      });

      test('chapterForPage 正确映射', () {
        expect(paginator.chapterForPage(0), 0);
        expect(paginator.chapterForPage(5), 0);
        expect(paginator.chapterForPage(9), 0);
      });

      test('chapterForPage 越界返回 -1', () {
        expect(paginator.chapterForPage(10), -1);
        expect(paginator.chapterForPage(-1), -1);
      });

      test('pageInChapter 正确映射', () {
        expect(paginator.pageInChapter(0), 0);
        expect(paginator.pageInChapter(5), 5);
        expect(paginator.pageInChapter(9), 9);
      });

      test('globalIndexForChapterStart 正确', () {
        expect(paginator.globalIndexForChapterStart(0), 0);
      });

      test('globalIndexForChapterEnd 正确', () {
        expect(paginator.globalIndexForChapterEnd(0), 9);
      });

      test('isValidGlobalIndex 正确', () {
        expect(paginator.isValidGlobalIndex(0), true);
        expect(paginator.isValidGlobalIndex(9), true);
        expect(paginator.isValidGlobalIndex(10), false);
      });

      test('resolve 正确', () {
        final result = paginator.resolve(5);
        expect(result, isNotNull);
        expect(result!.chapterIndex, 0);
        expect(result.pageIndex, 5);
      });
    });

    group('多章节', () {
      setUp(() {
        // 第0章: 5页 (全局 0-4)
        // 第1章: 8页 (全局 5-12)
        // 第2章: 3页 (全局 13-15)
        paginator.addChapter(0, 5);
        paginator.addChapter(1, 8);
        paginator.addChapter(2, 3);
      });

      test('totalPages 为所有章节页数之和', () {
        expect(paginator.totalPages(), 16);
      });

      test('chapterForPage 正确映射', () {
        // 第0章范围: 0-4
        expect(paginator.chapterForPage(0), 0);
        expect(paginator.chapterForPage(4), 0);
        // 第1章范围: 5-12
        expect(paginator.chapterForPage(5), 1);
        expect(paginator.chapterForPage(12), 1);
        // 第2章范围: 13-15
        expect(paginator.chapterForPage(13), 2);
        expect(paginator.chapterForPage(15), 2);
      });

      test('pageInChapter 正确映射', () {
        // 第0章
        expect(paginator.pageInChapter(0), 0);
        expect(paginator.pageInChapter(4), 4);
        // 第1章
        expect(paginator.pageInChapter(5), 0);
        expect(paginator.pageInChapter(12), 7);
        // 第2章
        expect(paginator.pageInChapter(13), 0);
        expect(paginator.pageInChapter(15), 2);
      });

      test('globalIndexForChapterStart 正确', () {
        expect(paginator.globalIndexForChapterStart(0), 0);
        expect(paginator.globalIndexForChapterStart(1), 5);
        expect(paginator.globalIndexForChapterStart(2), 13);
      });

      test('globalIndexForChapterEnd 正确', () {
        expect(paginator.globalIndexForChapterEnd(0), 4);
        expect(paginator.globalIndexForChapterEnd(1), 12);
        expect(paginator.globalIndexForChapterEnd(2), 15);
      });

      test('resolve 正确映射', () {
        // 第0章中间
        var result = paginator.resolve(2);
        expect(result!.chapterIndex, 0);
        expect(result.pageIndex, 2);

        // 第1章开头
        result = paginator.resolve(5);
        expect(result!.chapterIndex, 1);
        expect(result.pageIndex, 0);

        // 第2章末尾
        result = paginator.resolve(15);
        expect(result!.chapterIndex, 2);
        expect(result.pageIndex, 2);
      });
    });

    // ===== 动态增删测试 =====

    group('动态增删', () {
      test('添加章节后 totalPages 更新', () {
        paginator.addChapter(0, 5);
        expect(paginator.totalPages(), 5);

        paginator.addChapter(1, 3);
        expect(paginator.totalPages(), 8);
      });

      test('更新已有章节页数', () {
        paginator.addChapter(0, 5);
        paginator.addChapter(1, 3);
        expect(paginator.totalPages(), 8);

        // 更新第0章页数为10
        paginator.addChapter(0, 10);
        expect(paginator.totalPages(), 13);
        expect(paginator.pageCountForChapter(0), 10);
      });

      test('移除章节后索引调整', () {
        paginator.addChapter(0, 5);
        paginator.addChapter(1, 8);
        paginator.addChapter(2, 3);
        expect(paginator.totalPages(), 16);

        // 移除第1章
        paginator.removeChapter(1);
        expect(paginator.totalPages(), 8);
        expect(paginator.chapterCount, 2);

        // 第2章的起始索引应该调整
        expect(paginator.globalIndexForChapterStart(2), 5);
      });

      test('移除不存在的章节无影响', () {
        paginator.addChapter(0, 5);
        paginator.removeChapter(99);
        expect(paginator.totalPages(), 5);
        expect(paginator.chapterCount, 1);
      });

      test('clear 清空所有', () {
        paginator.addChapter(0, 5);
        paginator.addChapter(1, 3);
        paginator.clear();
        expect(paginator.totalPages(), 0);
        expect(paginator.chapterCount, 0);
      });
    });

    // ===== 边界情况测试 =====

    group('边界情况', () {
      test('章节页数为 0', () {
        paginator.addChapter(0, 0);
        paginator.addChapter(1, 5);

        expect(paginator.totalPages(), 5);
        // 第0章没有页面，全局索引0应该映射到第1章
        expect(paginator.chapterForPage(0), 1);
        expect(paginator.pageInChapter(0), 0);
      });

      test('globalIndexForChapterEnd 对 0 页章节返回 -1', () {
        paginator.addChapter(0, 0);
        expect(paginator.globalIndexForChapterEnd(0), -1);
      });

      test('负数全局索引', () {
        paginator.addChapter(0, 5);
        expect(paginator.chapterForPage(-1), -1);
        expect(paginator.pageInChapter(-1), -1);
        expect(paginator.isValidGlobalIndex(-1), false);
        expect(paginator.resolve(-1), null);
      });

      test('最后一页的最后一页', () {
        paginator.addChapter(0, 5);
        paginator.addChapter(1, 3);

        final lastGlobalIndex = paginator.totalPages() - 1; // 7
        expect(paginator.chapterForPage(lastGlobalIndex), 1);
        expect(paginator.pageInChapter(lastGlobalIndex), 2);
      });

      test('非连续章节索引', () {
        // 模拟章节索引不连续的情况（如跳章）
        paginator.addChapter(0, 5);
        paginator.addChapter(5, 3); // 直接跳到第5章
        paginator.addChapter(10, 2);

        expect(paginator.totalPages(), 10);
        expect(paginator.globalIndexForChapterStart(0), 0);
        expect(paginator.globalIndexForChapterStart(5), 5);
        expect(paginator.globalIndexForChapterStart(10), 8);
      });

      test('乱序添加章节自动排序', () {
        // 乱序添加
        paginator.addChapter(2, 3);
        paginator.addChapter(0, 5);
        paginator.addChapter(1, 8);

        // 应该按章节索引排序
        expect(paginator.globalIndexForChapterStart(0), 0);
        expect(paginator.globalIndexForChapterStart(1), 5);
        expect(paginator.globalIndexForChapterStart(2), 13);
      });
    });

    // ===== 性能测试 =====

    group('性能', () {
      test('大量章节二分查找', () {
        // 添加1000章，每章10页
        for (var i = 0; i < 1000; i++) {
          paginator.addChapter(i, 10);
        }

        expect(paginator.totalPages(), 10000);

        // 验证二分查找正确性
        expect(paginator.chapterForPage(0), 0);
        expect(paginator.chapterForPage(9999), 999);
        expect(paginator.chapterForPage(5000), 500);

        // 验证边界
        expect(paginator.globalIndexForChapterStart(500), 5000);
        expect(paginator.globalIndexForChapterEnd(500), 5009);
      });
    });

    // ===== ChapterPageInfo 测试 =====

    group('ChapterPageInfo', () {
      test('toString 格式正确', () {
        const info = ChapterPageInfo(chapterIndex: 5, pageCount: 10);
        expect(info.toString(), 'ChapterPageInfo(chapter: 5, pages: 10)');
      });
    });
  });
}
