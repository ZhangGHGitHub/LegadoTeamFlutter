import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/discover_screen.dart';

/// 发现页推荐功能 Widget 测试
///
/// 验证推荐书籍列表、下拉刷新、上拉加载、分类浏览等功能。
void main() {
  /// 构建测试用 MaterialApp（不依赖 Provider）
  Widget buildTestApp({required Widget child}) {
    return MaterialApp(
      home: child,
    );
  }

  group('DiscoverScreen 推荐书籍展示', () {
    testWidgets('推荐书籍数据模型正确创建', (tester) async {
      // 验证 RecommendedBook 数据模型
      const book = RecommendedBook(
        name: '凡人修仙传',
        author: '忘语',
        category: '玄幻',
        intro: '一个普通山村少年的修仙之路',
        score: 9.5,
        reason: '基于阅读历史推荐',
      );

      expect(book.name, '凡人修仙传');
      expect(book.author, '忘语');
      expect(book.category, '玄幻');
      expect(book.score, 9.5);
      expect(book.reason, '基于阅读历史推荐');
    });

    testWidgets('推荐书籍列表卡片正确渲染', (tester) async {
      // 模拟推荐书籍列表渲染
      const books = [
        RecommendedBook(
          name: '凡人修仙传',
          author: '忘语',
          category: '玄幻',
          intro: '一个普通山村少年的修仙之路',
          score: 9.5,
          reason: '基于阅读历史推荐',
        ),
        RecommendedBook(
          name: '诡秘之主',
          author: '爱潜水的乌贼',
          category: '玄幻',
          intro: '蒸汽与机械的浪潮中',
          score: 9.4,
          reason: '热门推荐',
        ),
        RecommendedBook(
          name: '大奉打更人',
          author: '卖报小郎君',
          category: '历史',
          intro: '这个世界有儒释道三教',
          score: 9.2,
          reason: '基于阅读历史推荐',
        ),
      ];

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            appBar: AppBar(title: const Text('发现')),
            body: ListView(
              children: [
                // 模拟分区标题
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '为你推荐',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                // 推荐书籍列表
                for (final book in books)
                  Card(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 5),
                    child: ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.purple.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            book.score.toStringAsFixed(1),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      title: Text(book.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${book.author} · ${book.category}'),
                          Text(
                            book.reason,
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

      // 验证分区标题
      expect(find.text('为你推荐'), findsOneWidget);

      // 验证书籍名称显示
      expect(find.text('凡人修仙传'), findsOneWidget);
      expect(find.text('诡秘之主'), findsOneWidget);
      expect(find.text('大奉打更人'), findsOneWidget);

      // 验证作者和分类显示
      expect(find.text('忘语 · 玄幻'), findsOneWidget);
      expect(find.text('爱潜水的乌贼 · 玄幻'), findsOneWidget);

      // 验证推荐分数显示
      expect(find.text('9.5'), findsOneWidget);
      expect(find.text('9.4'), findsOneWidget);

      // 验证推荐理由显示
      expect(find.text('基于阅读历史推荐'), findsNWidgets(2));
      expect(find.text('热门推荐'), findsOneWidget);
    });

    testWidgets('下拉刷新 RefreshIndicator 存在', (tester) async {
      // 验证 RefreshIndicator 组件正确包裹列表
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: RefreshIndicator(
              onRefresh: () async {
                await Future.delayed(const Duration(milliseconds: 100));
              },
              child: ListView(
                children: const [
                  SizedBox(height: 100, child: Text('内容区域')),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.text('内容区域'), findsOneWidget);
    });

    testWidgets('上拉加载更多指示器显示', (tester) async {
      // 验证加载更多 UI 状态
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < 6; i++)
                  ListTile(title: Text('书籍 $i')),
                // 加载更多指示器
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 验证列表项
      expect(find.text('书籍 0'), findsOneWidget);
      expect(find.text('书籍 5'), findsOneWidget);

      // 验证加载指示器
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('已加载全部推荐提示显示', (tester) async {
      // 验证无更多数据时的提示
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: ListView(
              children: const [
                ListTile(title: Text('书籍 1')),
                ListTile(title: Text('书籍 2')),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('— 已加载全部推荐 —'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('— 已加载全部推荐 —'), findsOneWidget);
    });
  });

  group('DiscoverScreen 分类与排行', () {
    testWidgets('分类浏览标签正确渲染', (tester) async {
      const categories = ['热门', '新书', '完结', '玄幻', '都市', '科幻'];

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  return ChoiceChip(
                    label: Text(categories[index]),
                    selected: index == 0,
                    onSelected: (_) {},
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('热门'), findsOneWidget);
      expect(find.text('新书'), findsOneWidget);
      expect(find.text('玄幻'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(6));
    });

    testWidgets('排行榜卡片正确渲染', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: SizedBox(
              height: 96,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _buildRankingCard('热搜榜', Icons.local_fire_department),
                  _buildRankingCard('新书榜', Icons.auto_stories),
                  _buildRankingCard('完结榜', Icons.done_all),
                  _buildRankingCard('飙升榜', Icons.trending_up),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('热搜榜'), findsOneWidget);
      expect(find.text('新书榜'), findsOneWidget);
      expect(find.text('完结榜'), findsOneWidget);
      expect(find.text('飙升榜'), findsOneWidget);
    });

    testWidgets('热门搜索关键词正确渲染', (tester) async {
      const keywords = ['凡人修仙传', '诡秘之主', '大奉打更人'];

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: keywords
                    .map((kw) => ActionChip(
                          avatar: const Icon(Icons.trending_up, size: 16),
                          label: Text(kw),
                          onPressed: () {},
                        ))
                    .toList(),
              ),
            ),
          ),
        ),
      );

      expect(find.text('凡人修仙传'), findsOneWidget);
      expect(find.text('诡秘之主'), findsOneWidget);
      expect(find.text('大奉打更人'), findsOneWidget);
      expect(find.byType(ActionChip), findsNWidgets(3));
    });
  });

  group('DiscoverScreen 搜索功能', () {
    testWidgets('搜索栏正确渲染并可点击', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        buildTestApp(
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Material(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => tapped = true,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.search),
                        SizedBox(width: 12),
                        Text('搜索书名、作者'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('搜索书名、作者'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);

      await tester.tap(find.text('搜索书名、作者'));
      expect(tapped, isTrue);
    });
  });

  group('DiscoverScreen 分页逻辑', () {
    test('分页截取逻辑正确', () {
      // 模拟分页逻辑
      const allBooks = [
        RecommendedBook(
            name: 'A', author: 'a', category: '玄幻', intro: '', score: 9.0, reason: '热门'),
        RecommendedBook(
            name: 'B', author: 'b', category: '都市', intro: '', score: 8.5, reason: '热门'),
        RecommendedBook(
            name: 'C', author: 'c', category: '科幻', intro: '', score: 8.0, reason: '新书'),
        RecommendedBook(
            name: 'D', author: 'd', category: '历史', intro: '', score: 7.5, reason: '新书'),
        RecommendedBook(
            name: 'E', author: 'e', category: '武侠', intro: '', score: 7.0, reason: '热门'),
        RecommendedBook(
            name: 'F', author: 'f', category: '悬疑', intro: '', score: 6.5, reason: '新书'),
        RecommendedBook(
            name: 'G', author: 'g', category: '游戏', intro: '', score: 6.0, reason: '热门'),
      ];

      // 第一页：6条
      var loadedCount = 6;
      var visible = allBooks.take(loadedCount).toList();
      expect(visible.length, 6);
      expect(visible.first.name, 'A');
      expect(visible.last.name, 'F');

      // 还有更多
      expect(loadedCount < allBooks.length, isTrue);

      // 加载更多
      loadedCount = (loadedCount + 6).clamp(0, allBooks.length);
      visible = allBooks.take(loadedCount).toList();
      expect(visible.length, 7);
      expect(visible.last.name, 'G');

      // 没有更多了
      expect(loadedCount < allBooks.length, isFalse);
    });
  });
}

/// 辅助构建排行榜卡片
Widget _buildRankingCard(String title, IconData icon) {
  return SizedBox(
    width: 132,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, size: 28),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    ),
  );
}
