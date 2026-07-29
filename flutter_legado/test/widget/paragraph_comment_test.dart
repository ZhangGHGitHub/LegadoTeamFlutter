import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/widgets/paragraph_comment_dialog.dart';

/// RustApi 桩实现，仅覆盖段评相关方法，避免真实 FFI 调用
class _FakeRustApi extends RustApi {
  /// 预设的评论 JSON 数据
  String reviewsJson = '[]';
  bool shouldThrow = false;

  /// 记录点赞调用
  final List<int> likedIds = [];

  /// 记录删除调用
  final List<int> deletedIds = [];

  /// 记录添加评论调用
  final List<Map<String, dynamic>> addedReviews = [];

  @override
  Future<String> reviewGetByChapter(String bookUrl, int chapterIndex) async {
    if (shouldThrow) throw Exception('网络错误');
    return reviewsJson;
  }

  @override
  Future<int> reviewAdd({
    required String bookUrl,
    required int chapterIndex,
    int paragraphIndex = -1,
    required String content,
    String author = '',
  }) async {
    if (shouldThrow) throw Exception('提交失败');
    addedReviews.add({
      'bookUrl': bookUrl,
      'chapterIndex': chapterIndex,
      'paragraphIndex': paragraphIndex,
      'content': content,
      'author': author,
    });
    return addedReviews.length;
  }

  @override
  Future<bool> reviewDelete(int id) async {
    deletedIds.add(id);
    return true;
  }

  @override
  Future<void> reviewLike(int id) async {
    likedIds.add(id);
  }
}

void main() {
  late _FakeRustApi fakeApi;

  setUp(() {
    fakeApi = _FakeRustApi();
  });

  Widget buildDialog({
    String bookUrl = 'https://example.com/book',
    int chapterIndex = 0,
    String chapterTitle = '第一章',
    int paragraphIndex = -1,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ParagraphCommentDialog(
          api: fakeApi,
          bookUrl: bookUrl,
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
          paragraphIndex: paragraphIndex,
        ),
      ),
    );
  }

  testWidgets('ParagraphCommentDialog 基本渲染', (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 标题显示："第一章 · 评论"
    expect(find.text('第一章 · 评论'), findsOneWidget);
  });

  testWidgets('空评论列表显示"暂无评论"', (tester) async {
    fakeApi.reviewsJson = '[]';

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(find.text('暂无评论'), findsOneWidget);
    expect(find.text('来写第一条评论吧'), findsOneWidget);
  });

  testWidgets('输入框存在且可输入', (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 验证输入框
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('写评论...'), findsOneWidget);

    // 输入文字
    await tester.enterText(find.byType(TextField), '好文章！');
    await tester.pump();

    expect(find.text('好文章！'), findsOneWidget);
  });

  testWidgets('发送按钮存在', (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('刷新按钮存在', (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('有评论时渲染评论列表', (tester) async {
    fakeApi.reviewsJson = jsonEncode([
      {
        'id': 1,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': -1,
        'content': '写得太好了',
        'author': '读者甲',
        'created_at': 1700000000000,
        'like_count': 5,
      },
      {
        'id': 2,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': -1,
        'content': '期待后续',
        'author': '读者乙',
        'created_at': 1700001000000,
        'like_count': 2,
      },
    ]);

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 评论内容可见
    expect(find.text('写得太好了'), findsOneWidget);
    expect(find.text('期待后续'), findsOneWidget);

    // 作者可见
    expect(find.text('读者甲'), findsOneWidget);
    expect(find.text('读者乙'), findsOneWidget);

    // 评论计数显示
    expect(find.textContaining('2 条'), findsOneWidget);
  });

  testWidgets('加载失败显示错误视图', (tester) async {
    fakeApi.shouldThrow = true;

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('评论数量显示', (tester) async {
    fakeApi.reviewsJson = '[]';

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 空评论时显示 "0 条"
    expect(find.textContaining('0 条'), findsOneWidget);
  });

  testWidgets('段落级评论标题显示段落信息', (tester) async {
    fakeApi.reviewsJson = '[]';

    await tester.pumpWidget(buildDialog(paragraphIndex: 2));
    await tester.pumpAndSettle();

    // 段落级标题："第一章 · 第3段评论"
    expect(find.text('第一章 · 第3段评论'), findsOneWidget);
  });

  testWidgets('段落级评论仅显示对应段落的评论', (tester) async {
    fakeApi.reviewsJson = jsonEncode([
      {
        'id': 1,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': 0,
        'content': '第一段评论',
        'author': '读者甲',
        'created_at': 1700000000000,
        'like_count': 3,
      },
      {
        'id': 2,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': 1,
        'content': '第二段评论',
        'author': '读者乙',
        'created_at': 1700001000000,
        'like_count': 1,
      },
    ]);

    // 仅查看第 0 段的评论
    await tester.pumpWidget(buildDialog(paragraphIndex: 0));
    await tester.pumpAndSettle();

    expect(find.text('第一段评论'), findsOneWidget);
    expect(find.text('第二段评论'), findsNothing);
    expect(find.textContaining('1 条'), findsOneWidget);
  });

  testWidgets('点赞评论触发 API 调用', (tester) async {
    fakeApi.reviewsJson = jsonEncode([
      {
        'id': 42,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': -1,
        'content': '精彩段落',
        'author': '读者丙',
        'created_at': 1700000000000,
        'like_count': 10,
      },
    ]);

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 点击点赞图标
    await tester.tap(find.byIcon(Icons.thumb_up_outlined));
    await tester.pumpAndSettle();

    expect(fakeApi.likedIds, contains(42));
  });

  testWidgets('删除评论弹出确认对话框', (tester) async {
    fakeApi.reviewsJson = jsonEncode([
      {
        'id': 7,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': -1,
        'content': '待删除评论',
        'author': 'user',
        'created_at': 1700000000000,
        'like_count': 0,
      },
    ]);

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 点击删除图标
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // 确认对话框出现
    expect(find.text('删除评论'), findsOneWidget);
    expect(find.text('确定删除这条评论吗？'), findsOneWidget);

    // 点击确认删除
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(fakeApi.deletedIds, contains(7));
  });

  testWidgets('发送评论触发 API 调用并携带段落索引', (tester) async {
    fakeApi.reviewsJson = '[]';

    await tester.pumpWidget(buildDialog(paragraphIndex: 3));
    await tester.pumpAndSettle();

    // 输入评论内容
    await tester.enterText(find.byType(TextField), '这段写得好');
    await tester.pump();

    // 点击发送
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(fakeApi.addedReviews.length, 1);
    expect(fakeApi.addedReviews[0]['content'], '这段写得好');
    expect(fakeApi.addedReviews[0]['paragraphIndex'], 3);
  });

  testWidgets('评论按点赞数降序排列', (tester) async {
    fakeApi.reviewsJson = jsonEncode([
      {
        'id': 1,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': -1,
        'content': '低赞评论',
        'author': '读者甲',
        'created_at': 1700000000000,
        'like_count': 1,
      },
      {
        'id': 2,
        'book_url': 'https://example.com/book',
        'chapter_index': 0,
        'paragraph_index': -1,
        'content': '高赞评论',
        'author': '读者乙',
        'created_at': 1700001000000,
        'like_count': 99,
      },
    ]);

    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 高赞评论应排在前面
    final highPos = tester.getTopLeft(find.text('高赞评论'));
    final lowPos = tester.getTopLeft(find.text('低赞评论'));
    expect(highPos.dy, lessThan(lowPos.dy));
  });
}
