// rust_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 RustApiContentExt mixin：音频播放模式 / 压缩包导入 / 正文高亮 / 规则订阅。
// RustApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 解码辅助来自 RustApiDecode（on 约束），同一 library 内私有成员可直接访问。
part of 'rust_api.dart';

mixin RustApiContentExt on RustApiDecode implements BookApi {
  // ========== 压缩包导入 ==========

  /// 导入 ZIP 压缩包中的书籍文件
  ///
  /// 解压 ZIP 文件，提取其中的书籍文件到 [outputDir]。
  /// 返回 ArchiveImportResult JSON 解析后的 Map。
  @override
  Future<Map<String, dynamic>> archiveImportZip({
    required String zipPath,
    required String outputDir,
  }) async {
    final json = await bridge.archiveImportZip(
      zipPath: zipPath,
      outputDir: outputDir,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 导入 RAR 压缩包中的书籍文件（支持加密）
  ///
  /// 解压 RAR 文件，提取其中的书籍文件到 [outputDir]。
  /// [password] 为可选密码，用于加密 RAR 文件。
  @override
  Future<Map<String, dynamic>> archiveImportRar({
    required String rarPath,
    required String outputDir,
    String? password,
  }) async {
    final json = await bridge.archiveImportRar(
      rarPath: rarPath,
      outputDir: outputDir,
      password: password,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 列出 ZIP 压缩包中的书籍文件名（不解压）
  ///
  /// 返回压缩包内符合书籍格式的文件名列表。
  @override
  Future<List<String>> archiveListZipFiles({required String zipPath}) async {
    final json = await bridge.archiveListZipFiles(zipPath: zipPath);
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e.toString()).toList();
  }

  /// 列出 RAR 压缩包中的书籍文件名（不解压）
  ///
  /// [password] 为可选密码，用于加密 RAR 文件。
  @override
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async {
    final json = await bridge.archiveListRarFiles(
      rarPath: rarPath,
      password: password,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e.toString()).toList();
  }

  /// 检测 TXT 文件编码
  ///
  /// 返回 EncodingResult JSON 解析后的 Map，包含：
  /// - encoding: 编码名称
  /// - has_bom: 是否通过 BOM 确定
  /// - confidence: 置信度（high/medium/low）
  @override
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  }) async {
    final json = await bridge.archiveDetectEncoding(filePath: filePath);
    return _decodeMap(json, 'bookApi');
  }

  /// 转换 TXT 文件编码
  ///
  /// 将文件从 [fromEncoding] 转换为 [toEncoding]，输出为新文件。
  /// 返回 ConvertResult JSON 解析后的 Map。
  @override
  Future<Map<String, dynamic>> archiveConvertEncoding({
    required String filePath,
    required String fromEncoding,
    required String toEncoding,
  }) async {
    final json = await bridge.archiveConvertEncoding(
      filePath: filePath,
      fromEncoding: fromEncoding,
      toEncoding: toEncoding,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 判断文件是否为压缩包格式
  ///
  /// 支持 .zip / .rar / .7z 等格式判断。
  @override
  Future<bool> archiveIsArchive({required String filePath}) =>
      bridge.archiveIsArchive(filePath: filePath);

  // ========== 正文高亮（highlight FFI） ==========

  /// 新增/更新高亮记录（BookHighlight JSON，time=0 时自动分配），返回 time
  @override
  Future<int> highlightAdd({required String highlightJson}) =>
      bridge.highlightAdd(highlightJson: highlightJson);

  /// 按主键 time 删除高亮记录，返回是否实际删除
  @override
  Future<bool> highlightDelete({required int time}) =>
      bridge.highlightDelete(time: time);

  /// 按书籍删除全部高亮记录，返回删除数量
  @override
  Future<int> highlightDeleteByBook({required String bookUrl}) =>
      bridge.highlightDeleteByBook(bookUrl: bookUrl);

  /// 按书籍获取高亮列表（BookHighlight 数组 JSON）
  @override
  Future<String> highlightListByBook({required String bookUrl}) =>
      bridge.highlightListByBook(bookUrl: bookUrl);

  /// 按书籍 + 章节索引获取高亮列表（BookHighlight 数组 JSON）
  @override
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  }) => bridge.highlightListByChapter(
    bookUrl: bookUrl,
    chapterIndex: chapterIndex,
  );

  /// 全局关键词搜索高亮（BookHighlight 数组 JSON）
  @override
  Future<String> highlightSearch({required String keyword}) =>
      bridge.highlightSearch(keyword: keyword);

  /// 获取所有高亮记录（BookHighlight 数组 JSON）
  @override
  Future<String> highlightListAll() => bridge.highlightListAll();

  /// 获取所有高亮规则（HighlightRule 数组 JSON，按 sortOrder 升序）
  @override
  Future<String> highlightRuleList() => bridge.highlightRuleList();

  /// 保存高亮规则（HighlightRule JSON，id=0 时自增新增），返回规则 ID
  @override
  Future<int> highlightRuleSave({required String ruleJson}) =>
      bridge.highlightRuleSave(ruleJson: ruleJson);

  /// 按 ID 删除高亮规则，返回是否实际删除
  @override
  Future<bool> highlightRuleDelete({required int id}) =>
      bridge.highlightRuleDelete(id: id);

  /// 按书籍查找启用的高亮规则（HighlightRule 数组 JSON）
  @override
  Future<String> highlightRuleFindEnabled({
    required String bookName,
    required String origin,
  }) => bridge.highlightRuleFindEnabled(bookName: bookName, origin: origin);

  // ========== 规则订阅（rule_sub FFI，Task #89） ==========

  /// 获取规则订阅列表（按 customOrder 排序）
  @override
  Future<List<Map<String, dynamic>>> ruleSubList() async {
    final json = await bridge.ruleSubList();
    return _decodeList(
      json,
      'ruleSubList',
    ).whereType<Map<String, dynamic>>().toList();
  }

  /// 新增/更新规则订阅
  @override
  Future<bool> ruleSubSave({required String subJson}) =>
      bridge.ruleSubSave(subJson: subJson);

  /// 删除规则订阅
  @override
  Future<bool> ruleSubDelete({required int id}) => bridge.ruleSubDelete(id: id);

  /// 切换规则订阅启用状态
  @override
  Future<bool> ruleSubSetEnabled({required int id, required bool enabled}) =>
      bridge.ruleSubSetEnabled(id: id, enabled: enabled);

  /// 拖拽排序：按新顺序 ID 列表重写 customOrder
  @override
  Future<bool> ruleSubUpdateOrder({required List<int> ids}) =>
      bridge.ruleSubUpdateOrder(idsJson: jsonEncode(ids));

  /// 检查更新（返回检查结果 Map）
  @override
  Future<Map<String, dynamic>> ruleSubCheckUpdate({required int id}) async {
    final json = await bridge.ruleSubCheckUpdate(id: id);
    return _decodeMap(json, 'ruleSubCheckUpdate');
  }

  /// 应用更新（返回应用结果 Map）
  @override
  Future<Map<String, dynamic>> ruleSubApplyUpdate({required int id}) async {
    final json = await bridge.ruleSubApplyUpdate(id: id);
    return _decodeMap(json, 'ruleSubApplyUpdate');
  }
}

/// RustApi 调用异常
class RustApiException implements Exception {
  final String message;
  final String? operation;

  const RustApiException(this.message, {this.operation});

  @override
  String toString() =>
      'RustApiException: $message${operation != null ? ' (operation: $operation)' : ''}';
}
