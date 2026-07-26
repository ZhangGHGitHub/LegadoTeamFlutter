import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/rust_api.dart';

/// 推荐书源分类
class DiscoverCategory {
  final String name;
  final String label;
  final IconDataData? icon;

  const DiscoverCategory({
    required this.name,
    required this.label,
    this.icon,
  });
}

/// 简单图标数据（避免依赖 material 的 IconData）
class IconDataData {
  final int codePoint;
  const IconDataData(this.codePoint);
}

/// 推荐书源条目
class RecommendedSource {
  final String name;
  final String description;
  final String category;
  final BookSource source;

  const RecommendedSource({
    required this.name,
    required this.description,
    required this.category,
    required this.source,
  });
}

/// 书源发现状态管理
class DiscoverProvider extends ChangeNotifier {
  final RustApi _api;

  DiscoverProvider(this._api);

  List<RecommendedSource> _recommended = [];
  Set<String> _installedUrls = {};
  bool _loading = false;
  String? _error;
  String _filterKeyword = '';
  String _selectedCategory = '全部';

  // ===== Getters =====

  List<RecommendedSource> get recommended => _recommended;
  Set<String> get installedUrls => _installedUrls;
  bool get loading => _loading;
  String? get error => _error;
  String get filterKeyword => _filterKeyword;
  String get selectedCategory => _selectedCategory;

  /// 分类列表
  static const categories = [
    '全部',
    '精选',
    '小说',
    '漫画',
    '新闻',
  ];

  /// 过滤后的书源列表
  List<RecommendedSource> get filteredSources {
    var list = _recommended;
    if (_selectedCategory != '全部') {
      list = list.where((s) => s.category == _selectedCategory).toList();
    }
    if (_filterKeyword.isNotEmpty) {
      final kw = _filterKeyword.toLowerCase();
      list = list.where((s) {
        return s.name.toLowerCase().contains(kw) ||
            s.description.toLowerCase().contains(kw);
      }).toList();
    }
    return list;
  }

  /// 判断书源是否已安装
  bool isInstalled(String sourceUrl) => _installedUrls.contains(sourceUrl);

  // ===== 操作 =====

  /// 加载推荐书源和已安装书源
  Future<void> loadSources() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // 加载已安装书源
      final installed = await _api.getBookSources();
      _installedUrls = installed.map((s) => s.bookSourceUrl).toSet();

      // 加载推荐书源（从本地配置或远程）
      _recommended = _buildDefaultRecommendations();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 安装书源
  Future<bool> installSource(RecommendedSource recommended) async {
    try {
      await _api.addBookSource(recommended.source);
      _installedUrls.add(recommended.source.bookSourceUrl);
      notifyListeners();
      return true;
    } catch (e) {
      _error = '安装失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 卸载书源
  Future<bool> uninstallSource(String sourceUrl) async {
    try {
      await _api.deleteBookSource(sourceUrl);
      _installedUrls.remove(sourceUrl);
      notifyListeners();
      return true;
    } catch (e) {
      _error = '卸载失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 设置分类筛选
  void setCategory(String category) {
    _selectedCategory = category;
    notifyListeners();
  }

  /// 设置搜索过滤
  void setFilter(String keyword) {
    _filterKeyword = keyword;
    notifyListeners();
  }

  /// 清除过滤
  void clearFilter() {
    _filterKeyword = '';
    notifyListeners();
  }

  /// 构建默认推荐书源列表
  List<RecommendedSource> _buildDefaultRecommendations() {
    return [
      RecommendedSource(
        name: '起点中文网',
        description: '国内最大的原创文学网站，海量正版小说',
        category: '精选',
        source: BookSource(
          bookSourceUrl: 'https://www.qidian.com',
          bookSourceName: '起点中文网',
          bookSourceGroup: '精选',
          searchUrl: 'https://www.qidian.com/so/{key}',
        ),
      ),
      RecommendedSource(
        name: '纵横中文网',
        description: '知名网络文学平台，精品完本小说',
        category: '小说',
        source: BookSource(
          bookSourceUrl: 'https://www.zongheng.com',
          bookSourceName: '纵横中文网',
          bookSourceGroup: '小说',
          searchUrl: 'https://search.zongheng.com/s?keyword={key}',
        ),
      ),
      RecommendedSource(
        name: '晋江文学城',
        description: '女性原创文学基地',
        category: '小说',
        source: BookSource(
          bookSourceUrl: 'https://www.jjwxc.net',
          bookSourceName: '晋江文学城',
          bookSourceGroup: '小说',
          searchUrl: 'https://www.jjwxc.net/bookbase.php?fw0=0&t0=0&b0=0&v=0&p=1&wd={key}',
        ),
      ),
      RecommendedSource(
        name: '腾讯动漫',
        description: '国漫日漫热门漫画',
        category: '漫画',
        source: BookSource(
          bookSourceUrl: 'https://ac.qq.com',
          bookSourceName: '腾讯动漫',
          bookSourceType: BookSourceType.image,
          bookSourceGroup: '漫画',
          searchUrl: 'https://ac.qq.com/Comic/search/key/{key}',
        ),
      ),
      RecommendedSource(
        name: '澎湃新闻',
        description: '专注时政与思想的媒体平台',
        category: '新闻',
        source: BookSource(
          bookSourceUrl: 'https://www.thepaper.cn',
          bookSourceName: '澎湃新闻',
          bookSourceGroup: '新闻',
          exploreUrl: 'https://www.thepaper.cn/',
        ),
      ),
      RecommendedSource(
        name: '36氪',
        description: '科技商业新媒体',
        category: '新闻',
        source: BookSource(
          bookSourceUrl: 'https://36kr.com',
          bookSourceName: '36氪',
          bookSourceGroup: '新闻',
          exploreUrl: 'https://36kr.com/',
        ),
      ),
      RecommendedSource(
        name: '笔趣阁',
        description: '免费全本小说阅读',
        category: '精选',
        source: BookSource(
          bookSourceUrl: 'https://www.biquge.com.cn',
          bookSourceName: '笔趣阁',
          bookSourceGroup: '精选',
          searchUrl: 'https://www.biquge.com.cn/search.php?q={key}',
        ),
      ),
      RecommendedSource(
        name: '有妖气漫画',
        description: '原创漫画平台',
        category: '漫画',
        source: BookSource(
          bookSourceUrl: 'https://www.u17.com',
          bookSourceName: '有妖气漫画',
          bookSourceType: BookSourceType.image,
          bookSourceGroup: '漫画',
          searchUrl: 'https://so.u17.com/s/{key}',
        ),
      ),
    ];
  }
}
