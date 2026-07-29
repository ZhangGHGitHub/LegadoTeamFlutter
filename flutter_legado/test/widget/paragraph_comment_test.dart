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
    return 1;
  }

  @override
  Future<bool> reviewDelete(int id) async => true;

  @override
  Future<void> reviewLike(int id) async {}
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
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ParagraphCommentDialog(
          api: fakeApi,
          bookUrl: bookUrl,
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
        ),
      ),
    );
  }

  testWidgets('ParagraphCommentDialog 基本渲染', (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.pumpAndSettle();

    // 标题包含章节名 + "· 评论"
    expect(find.textContaining('第一章'), findsOneWidget);
    expect(find.textContaining('评论'), findsOneWidget);
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
}
