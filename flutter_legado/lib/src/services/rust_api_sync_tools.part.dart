// rust_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 RustApiSyncTools mixin：WebDAV / 下载管理 / 段评 / 书籍导出 / 自动任务。
// RustApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 解码辅助来自 RustApiDecode（on 约束），同一 library 内私有成员可直接访问。
part of 'rust_api.dart';

mixin RustApiSyncTools on RustApiDecode implements BookApi {
  // ========== WebDAV 云同步 ==========

  /// WebDAV 列出远程目录
  @override
  Future<String> webdavListDir(String configJson, String path) =>
      bridge.webdavListDir(configJson: configJson, path: path);

  /// WebDAV 上传文件
  @override
  Future<void> webdavUpload(String configJson, String path, String data) =>
      bridge.webdavUpload(configJson: configJson, path: path, data: data);

  /// WebDAV 从本地文件路径读取并上传（契约 §2.28.6，Task #50 加法式新增）
  @override
  Future<void> webdavUploadFile(
    String configJson,
    String path,
    String localFilePath,
  ) => bridge.webdavUploadFile(
    configJson: configJson,
    path: path,
    localFilePath: localFilePath,
  );

  /// WebDAV 下载文件
  @override
  Future<String> webdavDownload(String configJson, String path) =>
      bridge.webdavDownload(configJson: configJson, path: path);

  /// WebDAV 下载二进制到本地文件（契约 §2.28，2026-08-12 P1-5）
  @override
  Future<void> webdavDownloadFile(
    String configJson,
    String path,
    String localFilePath,
  ) => bridge.webdavDownloadFile(
    configJson: configJson,
    path: path,
    localFilePath: localFilePath,
  );

  /// WebDAV 删除远程文件
  @override
  Future<void> webdavDelete(String configJson, String path) =>
      bridge.webdavDelete(configJson: configJson, path: path);

  /// WebDAV 全量同步
  @override
  Future<String> webdavFullSync(
    String configJson,
    String localBooks,
    String localSources,
  ) => bridge.webdavFullSync(
    configJson: configJson,
    localBooks: localBooks,
    localSources: localSources,
  );

  // ========== 下载管理器 ==========

  /// 添加下载任务
  @override
  Future<String> downloadAddTask({
    required String bookUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int chapterIndex,
    int priority = 0,
  }) => bridge.downloadAddTask(
    bookUrl: bookUrl,
    chapterUrl: chapterUrl,
    chapterTitle: chapterTitle,
    chapterIndex: chapterIndex,
    priority: priority,
  );

  /// 获取下载统计信息
  @override
  Future<String> downloadGetStats() => bridge.downloadGetStats();

  /// 获取指定书籍的下载任务
  @override
  Future<String> downloadListByBook(String bookUrl) =>
      bridge.downloadListByBook(bookUrl: bookUrl);

  /// 暂停所有下载
  @override
  Future<void> downloadPauseAll() => bridge.downloadPauseAll();

  /// 恢复所有下载
  @override
  Future<void> downloadResumeAll() => bridge.downloadResumeAll();

  /// 移除下载任务
  @override
  Future<void> downloadRemoveTask(String taskId) =>
      bridge.downloadRemoveTask(taskId: taskId);

  /// 更新下载进度
  @override
  Future<void> downloadUpdateProgress(String taskId, double progress) =>
      bridge.downloadUpdateProgress(taskId: taskId, progress: progress);

  // ========== 段评（书源 ruleReview）==========

  /// 段评摘要（P2-9）
  @override
  Future<String> reviewGetSummary(String sourceJson, String requestJson) =>
      bridge.reviewGetSummary(sourceJson: sourceJson, requestJson: requestJson);

  /// 段评详情分页（P2-9）
  @override
  Future<String> reviewGetDetail(
    String sourceJson,
    String requestJson,
    int page,
  ) => bridge.reviewGetDetail(
    sourceJson: sourceJson,
    requestJson: requestJson,
    page: page,
  );

  /// 按需加载段评回复（上游 #519）
  ///
  /// 返回 JSON 对象字符串 `{"items": [回复列表], "nextPageUrl": String?}`。
  @override
  Future<String> reviewGetReplies(
    String sourceJson,
    String requestJson,
    int page,
  ) => bridge.reviewGetReplies(
    sourceJson: sourceJson,
    requestJson: requestJson,
    page: page,
  );

  // ========== 书籍导出 ==========

  /// 导出书籍（返回 ExportResult JSON）
  ///
  /// # 参数
  /// - `bookUrl`: 书籍 URL
  /// - `format`: 导出格式（txt/epub/html）
  /// - `includeToc`: 是否包含目录
  @override
  Future<Map<String, dynamic>> bookExport({
    required String bookUrl,
    required String format,
    required bool includeToc,
  }) async {
    final json = await bridge.bookExport(
      bookUrl: bookUrl,
      format: format,
      includeToc: includeToc,
    );
    return _decodeMap(json, 'bookApi');
  }

  @override
  Future<Map<String, dynamic>> bookExportWithOptions({
    required String bookUrl,
    required String format,
    required bool includeToc,
    String optionsJson = '',
  }) async {
    final json = await bridge.bookExportWithOptions(
      bookUrl: bookUrl,
      format: format,
      includeToc: includeToc,
      optionsJson: optionsJson,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 获取导出预览信息（返回 ExportResult JSON）
  @override
  Future<Map<String, dynamic>> bookExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    final json = await bridge.bookExportInfo(bookUrl: bookUrl, format: format);
    return _decodeMap(json, 'bookApi');
  }

  // ========== 自动任务（auto_task FFI） ==========

  /// 构建书籍更新定时任务（返回 AutoTaskRule JSON）
  ///
  /// 对应 Kotlin `AutoTask.buildBookUpdateTask`。
  @override
  Future<Map<String, dynamic>> autoTaskBuildBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String name,
  }) async {
    final json = await bridge.autoTaskBuildBookUpdate(
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
      name: name,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 批量更新 cron 表达式（返回更新后的 AutoTaskRule 数组）
  ///
  /// [rules] 为现有规则列表 JSON，[ids] 为待更新任务 ID 列表。
  @override
  Future<List<Map<String, dynamic>>> autoTaskUpdateCronBatch({
    required String rulesJson,
    required String idsJson,
    required String cron,
  }) async {
    final json = await bridge.autoTaskUpdateCronBatch(
      rulesJson: rulesJson,
      idsJson: idsJson,
      cron: cron,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 准备导入任务（合并本地运行时状态，返回合并后的任务数组）
  @override
  Future<List<Map<String, dynamic>>> autoTaskPrepareImported({
    required String localTasksJson,
    required String importedJson,
  }) async {
    final json = await bridge.autoTaskPrepareImported(
      localTasksJson: localTasksJson,
      importedJson: importedJson,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 执行任务协议（返回 TaskResult JSON）
  ///
  /// [protocolJson] 为 TaskProtocol 序列化字符串。
  @override
  Future<Map<String, dynamic>> autoTaskExecute({
    required String protocolJson,
  }) async {
    final json = await bridge.autoTaskExecute(protocolJson: protocolJson);
    return _decodeMap(json, 'bookApi');
  }

  /// 带任务 ID 执行任务协议（返回 TaskResult JSON）
  @override
  Future<Map<String, dynamic>> autoTaskExecuteWithId({
    required String protocolJson,
    required String taskId,
  }) async {
    final json = await bridge.autoTaskExecuteWithId(
      protocolJson: protocolJson,
      taskId: taskId,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 规范化脚本（去除 `@js:` 前缀或 `<js></js>` 包裹）
  @override
  Future<String> autoTaskNormalizeScript({required String script}) =>
      bridge.autoTaskNormalizeScript(script: script);

  /// 判断书籍是否允许刷新目录
  @override
  Future<bool> autoTaskCanRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) => bridge.autoTaskCanRefreshToc(
    canUpdate: canUpdate,
    respectCanUpdate: respectCanUpdate,
  );

  /// 查找书籍更新任务（返回匹配的 AutoTaskRule JSON，未找到返回 null）
  @override
  Future<Map<String, dynamic>?> autoTaskFindBookUpdateTask({
    required String tasksJson,
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  }) async {
    final json = await bridge.autoTaskFindBookUpdate(
      tasksJson: tasksJson,
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
    );
    if (json.isEmpty || json == 'null') return null;
    return _decodeMap(json, 'bookApi');
  }

  /// 解析 cron 表达式计算下次执行时间（Unix 毫秒，无法解析返回 -1）
  @override
  Future<int> autoTaskNextDueAt({
    required String cron,
    required int fromMs,
  }) async {
    final result = await bridge.autoTaskNextDueAt(cron: cron, fromMs: fromMs);
    return result.toInt();
  }

  // ========== 自动任务数据库 CRUD ==========

  /// 列出所有自动任务规则（按 customOrder 排序）
  @override
  Future<List<Map<String, dynamic>>> autoTaskListRules() async {
    final json = await bridge.autoTaskListRules();
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 创建自动任务规则（返回任务 ID）
  @override
  Future<String> autoTaskCreateRule({required String ruleJson}) async {
    return await bridge.autoTaskCreateRule(ruleJson: ruleJson);
  }

  /// 更新自动任务规则
  @override
  Future<void> autoTaskUpdateRule({required String ruleJson}) async {
    await bridge.autoTaskUpdateRule(ruleJson: ruleJson);
  }

  /// 删除自动任务规则
  @override
  Future<void> autoTaskDeleteRule({required String id}) async {
    await bridge.autoTaskDeleteRule(id: id);
  }

  /// 根据 ID 查询自动任务规则
  @override
  Future<Map<String, dynamic>?> autoTaskFindRuleById({
    required String id,
  }) async {
    final json = await bridge.autoTaskFindRuleById(id: id);
    if (json.isEmpty || json == 'null') return null;
    return _decodeMap(json, 'bookApi');
  }

  // ========== 音频播放模式（audio FFI） ==========

  /// 将播放模式写入 readConfig JSON（返回更新后的 JSON）
  ///
  /// 对应 Kotlin `String?.withAudioPlayMode`。
  @override
  Future<String> audioWithPlayMode({
    String? readConfig,
    required int playMode,
  }) => bridge.audioWithPlayMode(readConfig: readConfig, playMode: playMode);

  /// 解析听书书籍（返回 Book JSON，未找到返回 null）
  ///
  /// 请求 URL 为空时返回缓存书籍；缓存匹配时直接返回；否则按 URL 查库。
  @override
  Future<Map<String, dynamic>?> audioResolvePlayBook({
    String? requestedBookUrl,
    String? cachedBookJson,
  }) async {
    final json = await bridge.audioResolvePlayBook(
      requestedBookUrl: requestedBookUrl,
      cachedBookJson: cachedBookJson,
    );
    if (json.isEmpty || json == 'null') return null;
    return _decodeMap(json, 'bookApi');
  }
}
