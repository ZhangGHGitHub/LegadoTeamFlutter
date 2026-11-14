// P3-1 资源卫生守卫：9 个页面的快速滚动控制器必须在 State.dispose 释放。
//
// 说明：ScrollController 未 dispose 不会立刻崩溃，widget 测试无法直接观测；
// 这里沿用仓库既有「源码契约测试」口径（见 api_contract_test / app_font_notifier_test）
// 做静态守卫，防止后续回退。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const screens = <String, String>{
    'bookmark_screen.dart': '_fsController',
    'bookshelf_manage_screen.dart': '_fsController',
    'explore_screen.dart': '_listController',
    'highlight_rules_screen.dart': '_fsController',
    'read_record_screen.dart': '_listController',
    'replace_rules_screen.dart': '_ruleListController',
    'rss_source_manage_screen.dart': '_fsController',
    'search_content_screen.dart': '_fsController',
    'txt_toc_rules_screen.dart': '_fsController',
  };

  for (final entry in screens.entries) {
    test('${entry.key} 在 dispose 中释放 ${entry.value}', () {
      final source =
          File('lib/src/screens/${entry.key}').readAsStringSync();
      expect(source, contains('void dispose()'));
      expect(source, contains('${entry.value}.dispose();'));
    });
  }
}
