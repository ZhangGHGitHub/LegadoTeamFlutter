// source_edit_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SourceEditActions 承载：保存 / 登录 / 帮助等交互处理。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'source_edit_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SourceEditActions on _SourceEditScreenState {

  /// 将 [BookSource] 展平为 key→文本 映射，供 [_populateFields] 回填控制器。
  Map<String, String> _sourceToValues(BookSource source) {
    String v(String? value) => value ?? '';
    final sr = source.ruleSearch;
    final er = source.ruleExplore;
    final ir = source.ruleBookInfo;
    final tr = source.ruleToc;
    final cr = source.ruleContent;
    final rr = source.ruleReview;
    return {
      // 基本信息（对齐原版 sourceEntities）
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceName': source.bookSourceName,
      'bookSourceGroup': v(source.bookSourceGroup),
      'bookSourceComment': v(source.bookSourceComment),
      'loginUrl': v(source.loginUrl),
      'loginUi': v(source.loginUi),
      'loginCheckJs': v(source.loginCheckJs),
      'coverDecodeJs': v(source.coverDecodeJs),
      'bookUrlPattern': v(source.bookUrlPattern),
      'header': v(source.header),
      'variableComment': v(source.variableComment),
      'concurrentRate': v(source.concurrentRate),
      'jsLib': v(source.jsLib),
      // 搜索规则
      'searchUrl': v(source.searchUrl),
      's_checkKeyWord': v(sr?.checkKeyWord),
      's_bookList': v(sr?.bookList),
      's_name': v(sr?.name),
      's_author': v(sr?.author),
      's_kind': v(sr?.kind),
      's_wordCount': v(sr?.wordCount),
      's_lastChapter': v(sr?.lastChapter),
      's_intro': v(sr?.intro),
      's_coverUrl': v(sr?.coverUrl),
      's_bookUrl': v(sr?.bookUrl),
      // 发现规则
      'exploreUrl': v(source.exploreUrl),
      'e_bookList': v(er?.bookList),
      'e_name': v(er?.name),
      'e_author': v(er?.author),
      'e_kind': v(er?.kind),
      'e_wordCount': v(er?.wordCount),
      'e_lastChapter': v(er?.lastChapter),
      'e_intro': v(er?.intro),
      'e_coverUrl': v(er?.coverUrl),
      'e_bookUrl': v(er?.bookUrl),
      // 详情规则
      'i_init': v(ir?.init),
      'i_name': v(ir?.name),
      'i_author': v(ir?.author),
      'i_kind': v(ir?.kind),
      'i_wordCount': v(ir?.wordCount),
      'i_lastChapter': v(ir?.lastChapter),
      'i_intro': v(ir?.intro),
      'i_coverUrl': v(ir?.coverUrl),
      'i_tocUrl': v(ir?.tocUrl),
      'i_canReName': v(ir?.canReName),
      'i_downloadUrls': v(ir?.downloadUrls),
      // 目录规则
      't_preUpdateJs': v(tr?.preUpdateJs),
      't_chapterList': v(tr?.chapterList),
      't_chapterName': v(tr?.chapterName),
      't_chapterUrl': v(tr?.chapterUrl),
      't_formatJs': v(tr?.formatJs),
      't_isVolume': v(tr?.isVolume),
      't_updateTime': v(tr?.updateTime),
      't_isVip': v(tr?.isVip),
      't_isPay': v(tr?.isPay),
      't_nextTocUrl': v(tr?.nextTocUrl),
      // 正文规则
      'c_content': v(cr?.content),
      'c_nextContentUrl': v(cr?.nextContentUrl),
      'c_subContent': v(cr?.subContent),
      'c_replaceRegex': v(cr?.replaceRegex),
      'c_title': v(cr?.title),
      'c_sourceRegex': v(cr?.sourceRegex),
      'c_imageStyle': v(cr?.imageStyle),
      'c_imageDecode': v(cr?.imageDecode),
      'c_webJs': v(cr?.webJs),
      'c_payAction': v(cr?.payAction),
      'c_callBackJs': v(cr?.callBackJs),
      // 段评规则（对齐原版 reviewEntities）
      'r_reviewSummaryUrl': v(rr?.reviewSummaryUrl),
      'r_summaryListRule': v(rr?.summaryListRule),
      'r_summaryParagraphIndexRule': v(rr?.summaryParagraphIndexRule),
      'r_summaryCountRule': v(rr?.summaryCountRule),
      'r_summaryParagraphDataRule': v(rr?.summaryParagraphDataRule),
      'r_reviewDetailUrl': v(rr?.reviewDetailUrl),
      'r_reviewDetailNextPageUrl': v(rr?.reviewDetailNextPageUrl),
      'r_detailListRule': v(rr?.detailListRule),
      'r_detailIdRule': v(rr?.detailIdRule),
      'r_detailAvatarRule': v(rr?.detailAvatarRule),
      'r_detailNameRule': v(rr?.detailNameRule),
      'r_detailBadgeRule': v(rr?.detailBadgeRule),
      'r_detailContentRule': v(rr?.detailContentRule),
      'r_reviewQuoteUrl': v(rr?.reviewQuoteUrl),
      'r_replyListRule': v(rr?.replyListRule),
      'r_replyIdRule': v(rr?.replyIdRule),
      'r_replyAvatarRule': v(rr?.replyAvatarRule),
      'r_replyNameRule': v(rr?.replyNameRule),
      'r_replyBadgeRule': v(rr?.replyBadgeRule),
      'r_replyContentRule': v(rr?.replyContentRule),
    };
  }

  /// 从控制器收集字段，构建 [BookSource]。
  ///
  /// 对齐原版 BookSourceEditActivity.getSource：
  /// - 表单字段按 key 覆盖（空串 → null，即清空字段保存）；
  /// - 表单未展示的字段（updateTime 等）从 [_originalSource] 透传，
  ///   避免保存一次编辑即丢失既有规则数据。
  BookSource _buildSource() {
    // 文本（trim 后）
    String t(String key) => _ctrl(key).text.trim();
    // 可空文本：空串归一为 null（对齐原版 takeIf { isNotBlank }）
    String? n(String key) => t(key).isEmpty ? null : t(key);

    final orig = _originalSource;
    final oSr = orig?.ruleSearch;
    final oEr = orig?.ruleExplore;
    final oIr = orig?.ruleBookInfo;
    final oRr = orig?.ruleReview;

    return BookSource(
      bookSourceUrl: t('bookSourceUrl'),
      bookSourceName: t('bookSourceName'),
      bookSourceGroup: n('bookSourceGroup'),
      bookSourceType: _bookSourceType,
      enabled: _enabled,
      enabledCookieJar: _cookieJar,
      eventListener: _eventListener,
      customButton: _customButton,
      header: n('header'),
      loginUrl: n('loginUrl'),
      loginUi: n('loginUi'),
      loginCheckJs: n('loginCheckJs'),
      coverDecodeJs: n('coverDecodeJs'),
      bookUrlPattern: n('bookUrlPattern'),
      bookSourceComment: n('bookSourceComment'),
      variableComment: n('variableComment'),
      concurrentRate: n('concurrentRate'),
      jsLib: n('jsLib'),
      // 评审 C1：透传被编辑书源既有 variable（表单不编辑此字段，
      // 避免保存时把已设置的源变量抹掉为空串）
      variable: _preservedVariable,
      enabledExplore: _enabledExplore,
      // 搜索规则
      searchUrl: n('searchUrl'),
      ruleSearch: SearchRule(
        checkKeyWord: n('s_checkKeyWord'),
        bookList: n('s_bookList'),
        name: n('s_name'),
        author: n('s_author'),
        kind: n('s_kind'),
        wordCount: n('s_wordCount'),
        lastChapter: n('s_lastChapter'),
        intro: n('s_intro'),
        coverUrl: n('s_coverUrl'),
        bookUrl: n('s_bookUrl'),
        // 表单未展示字段透传（原版编辑页同样不展示 updateTime）
        updateTime: oSr?.updateTime,
      ),
      // 发现规则
      exploreUrl: n('exploreUrl'),
      ruleExplore: ExploreRule(
        bookList: n('e_bookList'),
        name: n('e_name'),
        author: n('e_author'),
        kind: n('e_kind'),
        wordCount: n('e_wordCount'),
        lastChapter: n('e_lastChapter'),
        intro: n('e_intro'),
        coverUrl: n('e_coverUrl'),
        bookUrl: n('e_bookUrl'),
        updateTime: oEr?.updateTime,
      ),
      // 详情规则
      ruleBookInfo: BookInfoRule(
        init: n('i_init'),
        name: n('i_name'),
        author: n('i_author'),
        kind: n('i_kind'),
        wordCount: n('i_wordCount'),
        lastChapter: n('i_lastChapter'),
        intro: n('i_intro'),
        coverUrl: n('i_coverUrl'),
        tocUrl: n('i_tocUrl'),
        canReName: n('i_canReName'),
        downloadUrls: n('i_downloadUrls'),
        updateTime: oIr?.updateTime,
      ),
      // 目录规则
      ruleToc: TocRule(
        preUpdateJs: n('t_preUpdateJs'),
        chapterList: n('t_chapterList'),
        chapterName: n('t_chapterName'),
        chapterUrl: n('t_chapterUrl'),
        formatJs: n('t_formatJs'),
        isVolume: n('t_isVolume'),
        updateTime: n('t_updateTime'),
        isVip: n('t_isVip'),
        isPay: n('t_isPay'),
        nextTocUrl: n('t_nextTocUrl'),
      ),
      // 正文规则
      ruleContent: ContentRule(
        content: n('c_content'),
        nextContentUrl: n('c_nextContentUrl'),
        subContent: n('c_subContent'),
        replaceRegex: n('c_replaceRegex'),
        title: n('c_title'),
        sourceRegex: n('c_sourceRegex'),
        imageStyle: n('c_imageStyle'),
        imageDecode: n('c_imageDecode'),
        webJs: n('c_webJs'),
        payAction: n('c_payAction'),
        callBackJs: n('c_callBackJs'),
      ),
      // 段评规则（对齐原版：仅编辑 reviewEntities 展示字段，其余透传）
      ruleReview: ReviewRule(
        enabled: _reviewEnabled,
        reviewUrl: oRr?.reviewUrl,
        avatarRule: oRr?.avatarRule,
        contentRule: oRr?.contentRule,
        postTimeRule: oRr?.postTimeRule,
        voteUpUrl: oRr?.voteUpUrl,
        voteDownUrl: oRr?.voteDownUrl,
        postReviewUrl: oRr?.postReviewUrl,
        postQuoteUrl: oRr?.postQuoteUrl,
        deleteUrl: oRr?.deleteUrl,
        reviewSummaryUrl: n('r_reviewSummaryUrl'),
        summaryListRule: n('r_summaryListRule'),
        summaryParagraphIndexRule: n('r_summaryParagraphIndexRule'),
        summaryCountRule: n('r_summaryCountRule'),
        summaryParagraphDataRule: n('r_summaryParagraphDataRule'),
        reviewDetailUrl: n('r_reviewDetailUrl'),
        reviewDetailNextPageUrl: n('r_reviewDetailNextPageUrl'),
        detailListRule: n('r_detailListRule'),
        detailIdRule: n('r_detailIdRule'),
        detailAvatarRule: n('r_detailAvatarRule'),
        detailNameRule: n('r_detailNameRule'),
        detailBadgeRule: n('r_detailBadgeRule'),
        detailContentRule: n('r_detailContentRule'),
        reviewQuoteUrl: n('r_reviewQuoteUrl'),
        replyListRule: n('r_replyListRule'),
        replyIdRule: n('r_replyIdRule'),
        replyAvatarRule: n('r_replyAvatarRule'),
        replyNameRule: n('r_replyNameRule'),
        replyBadgeRule: n('r_replyBadgeRule'),
        replyContentRule: n('r_replyContentRule'),
      ),
    );
  }

  /// 保存成功后刷新发现页书源缓存（对齐原版 setResult(RESULT_OK) 语义：
  /// 上层页面感知书源变更，立即反映新名称/开关等，避免内存旧对象
  /// 再次打开编辑页把已保存修改回退）
  void _afterSaveRefresh() {
    try {
      ref.read(exploreNotifierProvider.notifier).refresh();
    } catch (_) {}
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);
      _afterSaveRefresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(isNew ? '书源已创建' : '书源已保存')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// overflow 菜单项（对齐原版 source_edit.xml 顺序/内容；紧凑行高使 12 项
  /// 菜单在顶栏下方完整展示而不被屏幕底边顶回覆盖顶栏）
  List<PopupMenuEntry<String>> _buildMenuItems() {
    const itemHeight = 44.0;
    return [
      // 登录（对齐 menu_login：仅在配置了登录 URL 时显示）
      if (_ctrl('loginUrl').text.trim().isNotEmpty)
        const PopupMenuItem(
          value: 'login',
          height: itemHeight,
          child: Text('登录'),
        ),
      const PopupMenuItem(
        value: 'search',
        height: itemHeight,
        child: Text('搜索'),
      ),
      const PopupMenuItem(
        value: 'clear_cookie',
        height: itemHeight,
        child: Text('清除Cookie'),
      ),
      CheckedPopupMenuItem(
        value: 'auto_complete',
        height: itemHeight,
        checked: _autoComplete,
        child: const Text('自动补全'),
      ),
      const PopupMenuItem(
        value: 'copy_source',
        height: itemHeight,
        child: Text('拷贝源'),
      ),
      const PopupMenuItem(
        value: 'paste_source',
        height: itemHeight,
        child: Text('粘贴源'),
      ),
      const PopupMenuItem(
        value: 'set_source_variable',
        height: itemHeight,
        child: Text('设置源变量'),
      ),
      const PopupMenuItem(
        value: 'import_qr',
        height: itemHeight,
        child: Text('二维码导入'),
      ),
      const PopupMenuItem(
        value: 'share_qr',
        height: itemHeight,
        child: Text('二维码分享'),
      ),
      const PopupMenuItem(
        value: 'share_str',
        height: itemHeight,
        child: Text('字符串分享'),
      ),
      const PopupMenuItem(
        value: 'log',
        height: itemHeight,
        child: Text('日志'),
      ),
      const PopupMenuItem(
        value: 'help',
        height: itemHeight,
        child: Text('帮助'),
      ),
    ];
  }

  /// 在按钮下方弹出更多选项菜单（对齐原版：菜单在顶栏按钮下方、右对齐，
  /// 不覆盖顶栏操作按钮；底部留边使超长菜单滚动展示而非上移顶回工具栏）
  Future<void> _showOverflowMenu(BuildContext anchor) async {
    final overlay = Overlay.of(anchor).context.findRenderObject()! as RenderBox;
    const top = 156.0;
    const bottom = 48.0;
    const menuWidth = 300.0;
    final position = RelativeRect.fromLTRB(
      overlay.size.width - menuWidth - 8,
      top,
      8,
      bottom,
    );
    final value = await showMenu<String>(
      context: anchor,
      position: position,
      items: _buildMenuItems(),
    );
    if (value != null) {
      await _handleMenu(value);
    }
  }

  /// overflow 菜单分流（对标原版 source_edit.xml 折叠项）
  Future<void> _handleMenu(String value) async {
    switch (value) {
      case 'login':
        _openLogin();
      case 'search':
        await _searchWithSource();
      case 'clear_cookie':
        await _clearCookie();
      case 'auto_complete':
        setState(() => _autoComplete = !_autoComplete);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_autoComplete ? '自动补全已开启' : '自动补全已关闭'),
          ),
        );
      case 'copy_source':
        await _copySource();
      case 'paste_source':
        await _pasteSource();
      case 'set_source_variable':
        await _setSourceVariable();
      case 'import_qr':
        await _importFromQr();
      case 'share_qr':
        await _shareQr();
      case 'share_str':
        await _shareSource();
      case 'log':
        // [UI-FIX v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
      case 'help':
        _showHelp();
    }
  }

  /// 保存当前书源后，以该源为搜索范围打开搜索页
  /// （对标原版 menu_search → SearchActivity.start(this, source)）
  Future<void> _searchWithSource() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      await ref.read(sourceNotifierProvider.notifier).saveSource(source);
      _afterSaveRefresh();
      if (!mounted) return;
      final search = ref.read(searchNotifierProvider.notifier);
      search.clearAllFilter();
      search.toggleSource(source.bookSourceUrl);
      await Navigator.of(context).pushNamed(AppRoutes.search);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开搜索失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 清除 Cookie（对标原版 menu_clear_cookie → CookieStore.removeCookie）
  Future<void> _clearCookie() async {
    final url = _ctrl('bookSourceUrl').text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写书源 URL')),
      );
      return;
    }
    try {
      await ref.read(bookApiProvider).clearCookie(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cookie 已清除')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除 Cookie 失败：$e')),
        );
      }
    }
  }

  /// 设置源变量（对标原版 menu_set_source_variable + VariableDialog）
  Future<void> _setSourceVariable() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      await ref.read(sourceNotifierProvider.notifier).saveSource(source);
      _afterSaveRefresh();
      if (!mounted) return;
      final srcComment = (source.variableComment ?? '').trim();
      final comment = srcComment.isNotEmpty
          ? srcComment
          : '源变量可在js中通过source.getVariable()获取';
      final input = await showDialog<String>(
        context: context,
        builder: (ctx) => _SourceVariableDialog(
          title: '设置源变量',
          comment: comment,
          initialText: _preservedVariable,
        ),
      );
      if (input == null || !mounted) return;
      await ref.read(bookApiProvider).setSourceVariable(
            source.bookSourceUrl,
            input,
          );
      if (!mounted) return;
      setState(() => _preservedVariable = input);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(input.isEmpty ? '源变量已清除' : '源变量已保存')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置源变量失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 二维码分享（对标原版 menu_share_qr → shareWithQr）
  Future<void> _shareQr() async {
    final json = jsonEncode(_buildSource().toJson());
    if (json.length > 2000) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内容过长，无法生成二维码，请使用字符串分享')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => _QrShareDialog(
        title: '分享书源',
        payload: json,
      ),
    );
  }

  /// 登录（对标原版 menu_login → SourceLoginActivity：
  /// hasLoginForm → 登录表单对话框；否则 WebView/手动凭据页）
  void _openLogin() {
    final loginUrl = _ctrl('loginUrl').text.trim();
    if (loginUrl.isEmpty && _ctrl('loginUi').text.trim().isEmpty) return;
    // 统一登录入口（V2 动态对话框 / 经典 loginUi 表单 / 手动凭据页）
    // — DeepSeek Harness + UI（2026-08-14 登录表单对齐）
    showSourceLogin(context, ref, _buildSource());
  }

  /// 拷贝源（对标原版 menu_copy_source：JSON 写入剪贴板）
  Future<void> _copySource() async {
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert(_buildSource().toJson());
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  /// 粘贴源（对标原版 menu_paste_source：解析剪贴板 JSON 回填表单）
  Future<void> _pasteSource() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (text == null || text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('剪贴板为空')));
      return;
    }
    try {
      final decoded = jsonDecode(text);
      final map = decoded is List
          ? decoded.first as Map<String, dynamic>
          : decoded as Map<String, dynamic>;
      final source = BookSource.fromJson(map);
      _populateFields(source);
      messenger.showSnackBar(
        SnackBar(content: Text('已粘贴书源：${source.bookSourceName}')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('剪贴板内容不是有效的书源 JSON')),
      );
    }
  }

  /// 字符串分享（对标原版 menu_share_str：写缓存文件再分享）
  Future<void> _shareSource() async {
    try {
      final json = const JsonEncoder.withIndent('  ').convert(_buildSource().toJson());
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/bookSource_share.json');
      await file.writeAsString(json);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        text: '书源分享',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分享失败：$e')),
      );
    }
  }

  /// 二维码导入（对标原版 menu_qr_code_camera：扫码内容解析回填表单）
  Future<void> _importFromQr() async {
    // [fix Task#24 | 2026-08-08] 去掉 <String> 泛型，避免 routes 表
    // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
    final raw = await Navigator.of(context).pushNamed(AppRoutes.qrcode);
    final content = raw is String ? raw : null;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (content == null || content.trim().isEmpty) return;

    final trimmed = content.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        final map = decoded is List
            ? decoded.first as Map<String, dynamic>
            : decoded as Map<String, dynamic>;
        final source = BookSource.fromJson(map);
        _populateFields(source);
        messenger.showSnackBar(
          SnackBar(content: Text('已导入书源：${source.bookSourceName}')),
        );
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('扫码内容不是有效的书源 JSON')),
        );
      }
      return;
    }

    if (trimmed.startsWith('legado://')) {
      messenger.showSnackBar(
        const SnackBar(content: Text('legado 协议链接请使用「关联导入」页处理')),
      );
      return;
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('URL 内容请使用书源管理页的网络导入处理')),
    );
  }

  /// 显示规则帮助（对标原版 showHelp("ruleHelp")）
  void _showHelp() {
    showHelp(context, HelpAssets.ruleHelp);
  }

  /// 调试源（对标原版 menu_debug_source：保存后进入源调试页）
  Future<void> _debugSource() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);
      _afterSaveRefresh();
      if (!mounted) return;
      Navigator.of(context).pushNamed(
        AppRoutes.sourceDebug,
        arguments: source.bookSourceUrl,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('调试失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 全屏代码编辑（对标原版 menu_fullscreen_edit → CodeEditActivity）
  ///
  /// 需当前聚焦某一表单字段；无焦点时提示。JSON 整体编辑见 [_showJsonEdit]。
  Future<void> _showFullscreenEdit() async {
    final key = _focusedFieldKey;
    if (key == null || !_ctrls.containsKey(key)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先将光标放在要编辑的输入框')),
      );
      return;
    }
    await _openCodeEditForField(key, title: _fieldLabels[key] ?? key);
  }

  Future<void> _openCodeEditForField(String key, {required String title}) async {
    final ctrl = _ctrl(key);
    final focus = _focus(key);
    final cursor = ctrl.selection.baseOffset.clamp(0, ctrl.text.length);
    final result = await CodeEditScreen.open(
      context,
      title: title,
      initialText: ctrl.text,
      cursorPosition: cursor < 0 ? 0 : cursor,
    );
    if (result == null || !mounted) return;
    setState(() {
      ctrl.text = result;
      ctrl.selection = TextSelection.collapsed(offset: result.length);
    });
    focus.requestFocus();
  }
}
