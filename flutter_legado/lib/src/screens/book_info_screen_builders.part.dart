// book_info_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _BookInfoBuilders 承载：build 之后的各构建方法与菜单/交互处理。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'book_info_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _BookInfoBuilders on _BookInfoScreenState {

  /// 页面主体：封面背景三档（off/off_for_default/on）+ seed 渐变 —— 内容叠层
  /// [UI_SYNC_REFACTOR B4] 对齐参考仓 BookInfoBackdrop：
  /// - on=480dp 顶部封面 + blur24 + seedOverlay(lerp(secondaryContainer,seed,0.42) α0.34)；
  /// - off=显示封面不模糊 + seed 叠加；off_for_default=全部隐藏（纯 surface）；
  /// - [G1 | 台账 0917 批六] 垂直渐变 stops 0/0.2/0.35/0.48/1：35% 起→48%
  ///   surface 渐隐至全覆盖，其下为纯 surface 底色区（明暗双态经 cs.surface 槽位）；
  ///   切换 Crossfade 800ms。
  Widget _buildPage(BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;
    final isDefaultCover = !hasCover;
    final ui = uiSettingsListenable.value;
    final mode = isDefaultCover
        ? ui.bookInfoDefaultCoverBackground
        : ui.bookInfoNetworkCoverBackground;
    // [UI-fix v2.0.166] 虚化源降采样：σ24 下 1/3 屏宽与全尺寸视觉无差，
    // 解码+滤波开销降一个量级（进详情转场掉帧根因之一）
    final blurWidth =
        (MediaQuery.sizeOf(context).width / 3).round().clamp(120, 480);
    final seed = _coverSeed;
    final seedOverlay = seed == null
        ? cs.secondaryContainer
        : Color.lerp(cs.secondaryContainer, seed, 0.42)!;
    // [UI_SYNC_REFACTOR R1] enableBlur 关闭时 on 档退化为不模糊显示（对齐参考仓全局开关语义）
    final useBlur = mode == 'on' && hasCover && ui.enableBlur;
    final showBackdrop = !(mode == 'off_for_default' && isDefaultCover);

    final Widget backdrop = !showBackdrop
        ? ColoredBox(color: cs.surface)
        : Stack(
            children: [
              if (hasCover)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 480,
                  child: RepaintBoundary(
                    child: useBlur
                        ? ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: 24,
                              sigmaY: 24,
                            ),
                            child: CachedNetworkImage(
                              imageUrl: coverUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: blurWidth,
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: coverUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: blurWidth,
                          ),
                  ),
                )
              else
                ColoredBox(color: cs.surfaceContainerHighest),
              if (hasCover)
                Positioned.fill(
                  child: ColoredBox(
                    color: seedOverlay.withValues(alpha: 0.34),
                  ),
                ),
            ],
          );

    // [G1 | 台账 0917 批六] hero 底部渐隐：≤35% 封面完整（仅 seed 10-18% 微染），
    // 35%→48% surface 由 α0 渐隐至全覆盖（亮态融入亮 surface / 暗态融入暗
    // surface，均走 cs.surface 槽位，明暗双态天然生效），48% 以下为纯 surface
    // 底色区——信息 chips/四按钮/在读·最新/标签/简介不再透封面，对齐 ref 08
    // 「模糊封面仅占顶部约 45%（y≈870/1920 完全消失）」
    final gradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.2, 0.35, 0.48, 1.0],
          colors: [
            cs.surface.withValues(alpha: 0),
            seedOverlay.withValues(alpha: 0.10),
            seedOverlay.withValues(alpha: 0.18),
            cs.surface,
            cs.surface,
          ],
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景层：封面/档位/seed 变化时 Crossfade 800（对齐参考仓 tween(800)）
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 800),
          child: KeyedSubtree(
            key: ValueKey('$coverUrl|$mode|${seed?.toARGB32()}'),
            child: backdrop,
          ),
        ),
        Positioned.fill(child: gradient),
        SafeArea(
          top: false,
          // [LAYOUT_PLAN P4 收尾] 下拉 M3 化：裸 RefreshIndicator → CustomRefreshIndicator
          child: CustomRefreshIndicator(
            onRefresh: () async => _reload(),
            child: _buildBody(context, book, chapters),
          ),
        ),
        // 顶栏加载条（对标原版 refreshProgressBar.isAutoLoading）
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopNetworkLoadingBar(
            isLoading: _networkLoading || _tocLoading,
          ),
        ),
      ],
    );
  }


  /// P2-2 自定义按钮：SourceCallBack.callBackBtn + 中途 UI 回放
  Future<void> _onCustomButton() async {
    final book = _loadedBook;
    if (book == null) return;
    final api = ref.read(bookApiProvider);
    try {
      final r = await api.sourceCallBackBtn(
        event: 'clickCustomButton',
        bookUrl: book.bookUrl,
        bookType: book.bookType,
      );
      final actions = r['actions'];
      if (actions is List) {
        await PlatformBridgeService.instance.dispatchActions(actions);
      }
      final invoked = r['invoked'] == true;
      final jsTrue = r['jsTrue'] == true;
      if (!invoked || !jsTrue) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未配置回调或回调未接管')),
          );
        }
      }
    } catch (e) {
      debugPrint('自定义按钮失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自定义按钮执行失败: $e')),
        );
      }
    }
  }
  /// 溢出菜单处理（对标原版 BookInfoActivity.onOptionsItemSelected）
  Future<void> _handleMenu(String value) async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    switch (value) {
      case 'customBtn':
        await _onCustomButton();
        break;
      case 'edit':
        // [U1 | 台账 0917] 菜单「编辑」项接通（逻辑同顶栏编辑图标：
        // 编辑保存成功 reload；顶栏图标保持仅架上书显示）
        {
          final b = book;
          if (b == null) break;
          try {
            final saved = await Navigator.pushNamed(
              context,
              AppRoutes.editBookInfo,
              arguments: b,
            );
            if (saved == true && mounted) {
              _reload();
            }
          } catch (e) {
            debugPrint('编辑书籍信息失败: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('书籍信息暂不可用，请稍后重试')),
              );
            }
          }
        }
        break;
      case 'readRecord':
        // [U1 | 台账 0917] 菜单「阅读记录」项（与详情页四图标卡同入口）
        if (!context.mounted) break;
        await Navigator.pushNamed(context, AppRoutes.readRecord);
        break;
      case 'refresh':
        // 对齐原版：刷新即含目录更新（在线书走 refreshToc，本地书仅重加载）
        if (book != null && _isOnlineBook(book)) {
          await _refreshToc();
        } else {
          _reload();
        }
        break;
      case 'copyBookUrl':
        if (book != null) {
          await ref.read(bookApiProvider).sourceCallBackBtn(
                event: 'clickCopyBookUrl',
                bookUrl: book.bookUrl,
                bookType: book.bookType,
                result: book.bookUrl,
              );
          await Clipboard.setData(ClipboardData(text: book.bookUrl));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已拷贝书籍URL')));
          }
        }
        break;
      case 'copyTocUrl':
        if (book != null) {
          await ref.read(bookApiProvider).sourceCallBackBtn(
                event: 'clickCopyTocUrl',
                bookUrl: book.bookUrl,
                bookType: book.bookType,
                result: book.tocUrl,
              );
          await Clipboard.setData(ClipboardData(text: book.tocUrl));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已拷贝目录URL')));
          }
        }
        break;
      case 'canUpdate':
        if (book == null) return;
        // 对齐原版 menu_can_update：内存切换，在架时 saveBook；关闭时清除 updateError
        // — Cursor UI
        final toggledCanUpdate =
            applyBookInfoCanUpdateToggle(book, inBookshelf: _inBookshelf);
        setState(() => _loadedBook = toggledCanUpdate);
        if (_inBookshelf) {
          await api.updateBook(toggledCanUpdate);
          if (mounted) _reload();
        }
        break;
      case 'splitLongChapter':
        if (book == null) return;
        // splitLongChapter 存于 ReadConfig；对齐原版 toggle 后 loadBookInfo 重载目录
        // — Cursor UI
        final cfg = book.readConfig ?? const ReadConfig();
        final toggledSplit = book.copyWith(
          readConfig: cfg.copyWith(
            splitLongChapter: !cfg.splitLongChapter,
          ),
        );
        if (_inBookshelf) {
          await api.updateBook(toggledSplit);
        } else {
          setState(() => _loadedBook = toggledSplit);
        }
        if (mounted) {
          if (!_inBookshelf) {
            _snack('拆分长章节将在加入书架后生效');
          } else {
            _reload();
          }
        }
        break;
      case 'log':
        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
        break;
      case 'login':
        // [UI-fix v2.0.2 | 2026-08-06] 登录接通书源登录链路（V2 动态协议/旧版凭据页） — Qoder
        await _loginSource();
        break;
      case 'top':
        // [UI-fix v2.0.2 | 2026-08-06] 置顶接通 topBook FFI（对标原版 topBook） — Qoder
        await _topBook();
        break;
      case 'clearCache':
        // [UI-fix v2.0.2 | 2026-08-06] 清缓存接通 clearCache FFI — Qoder
        await _clearCache();
        break;
      case 'cacheDownloads':
        // [UI-fix v2.0.16 | 2026-08-10] 缓存下载队列页（对齐原版 CacheActivity）— Reasonix
        if (!context.mounted) break;
        await Navigator.pushNamed(context, AppRoutes.cacheDownloads);
        break;
      case 'deleteAlert':
        // [UI-fix v2.0.3 | 2026-08-08] 删除提醒开关持久化（对齐原版
        // LocalConfig.deleteBookAlert：删除/移出书籍时是否弹确认框） — Qoder
        final next = !_deleteBookAlert;
        await _settingsService.setDeleteBookAlert(next);
        if (mounted) setState(() => _deleteBookAlert = next);
        break;
      case 'bookVariable':
        // [UI-fix v2.0.3 | 2026-08-09] 设置书籍变量接通保存链路（Task #39
        // §5.11-4，对齐原版 BookInfoActivity.setBookVariable + setVariable
        // 的 bookUrl 分支：putCustomVariable + saveBook） — Qoder
        await _setBookVariable();
        break;
      case 'sourceVariable':
        // [Task #63 冻结 / #64-65 实现 | 2026-08-10] 设置源变量接通（台账 §5.11-3，对齐原版
        // BookInfoActivity.setSourceVariable + setVariable 的 source 分支：
        // bookSource.setVariable 后保存） — Qoder
        await _setSourceVariable();
        break;
      case 'updateTask':
        // [UI-fix v2.0.3 | 2026-08-09] 创建书籍更新任务接通（Task #39
        // §5.11-2，对齐原版 BookInfoActivity.openBookUpdateTask：
        // findBookUpdateTask 已存在→编辑，否则 buildBookUpdateTask 新建） — Qoder
        await _openBookUpdateTask();
        break;
      case 'upload':
        // [Task #52 | 2026-08-10] §5.11-1：上传至远程接通（对齐原版
        // BookInfoActivity.menu_upload → RemoteBookWebDav.upload：
        // WebDav PUT 本地书籍文件 → book.origin = webDavTag+putUrl → update） — Qoder
        await _uploadToRemote();
        break;
      case 'group':
        // [B1 形态对齐 | full-stack-engineer + UI]「分组」由操作宫格收纳进
        // 顶栏 ⋮ 菜单，复用既有 _showChangeGroup（行为不变）
        await _showChangeGroup();
        break;
      default:
        _todo(value);
        break;
    }
  }

  /// 未移植功能提示（占位项，待后续版本对齐原版）
  void _todo(String value) {
    final feature = value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  /// 设置源变量（Task #63 冻结 / #64-65 实现，台账 §5.11-3，对齐原版 BookInfoActivity
  /// setSourceVariable + setVariable 的 source 分支）
  ///
  /// 原版语义：
  /// - 书源不存在时 toast「书源不存在」直接返回（菜单层已按 hasSource 隐藏，
  ///   此处为二次防护，对齐原版 setSourceVariable 的 source==null 分支）
  /// - 说明文案对齐 getDisplayVariableComment：书源 variableComment
  ///   非空优先展示，否则用默认文案
  /// - 输入框预填当前书源 variable；确认后 setSourceVariable（空串=清除）
  ///   单列 UPDATE 写库，成功后 Toast + 刷新本地书源状态
  Future<void> _setSourceVariable() async {
    final api = ref.read(bookApiProvider);
    final source = _bookSource;
    if (source == null) {
      _snack('书源不存在');
      return;
    }
    // 说明文案（对齐原版 getDisplayVariableComment：书源注释优先）
    final srcComment = (source.variableComment ?? '').trim();
    final comment = srcComment.isNotEmpty
        ? srcComment
        : '源变量可在js中通过source.getVariable()获取';
    // 输入框预填当前书源 variable（对齐原版 source.getVariable 初值；
    // 评审 C1 后 variable 为非空串，无需 ?? 兼容）
    // [Task #70 D1 修复 | 2026-08-10] 重构为自持 StatefulWidget 对话框
    //（_TextPromptDialog 范式）：原实现 controller 在外部作用域创建 +
    // pop 后立即 dispose，退场动画期间触发 _dependents.isEmpty 断言 +
    // OverlayEntry Duplicate GlobalKey 红屏；现 controller 生命周期
    // 绑定对话框子树，确定按钮先取值再 pop 回传 — Qoder
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => _VariableDialog(
        title: '设置源变量',
        comment: comment,
        initialText: source.variable,
      ),
    );
    // 取消（pop 无值）不保存；确定恒保存，空串=清除（对齐原版 setVariable）
    if (input == null || !mounted) return;
    try {
      // 单列 UPDATE 语义（契约 §2.3）：仅改 variable 列，空串=清除；
      // 规避 updateBookSource 全行更新覆盖其它字段的风险
      await api.setSourceVariable(source.bookSourceUrl, input);
      if (!mounted) return;
      // 刷新本地书源状态（重载页面数据，书源查询自然带出新 variable；
      // 评审 C1：variable 非空串语义，空串即已清除，不再传 null）
      setState(() {
        _bookSource = source.copyWith(
          variable: input,
        );
      });
      _reload();
      _snack(input.isEmpty ? '源变量已清除' : '源变量已保存');
    } catch (e) {
      debugPrint('设置源变量失败: $e');
      if (mounted) _snack('设置源变量失败: ${_errMsg(e)}');
    }
  }

  /// 上传至远程（Task #52 §5.11-1，对齐原版 RemoteBookWebDav.upload）
  ///
  /// 原版语义（BookInfoActivity.menu_upload → upLoadBook）：
  /// - 仅本地书可见（isLocal = localTag 或 webDavTag，菜单已限定）
  /// - 已有远程地址时先确认（sure_upload），否则直接上传
  /// - WebDav PUT 本地书籍文件到远程 books 目录（rootBookUrl + originName）
  /// - 成功后 book.origin = webDavTag + 远程地址，并刷新 lastCheckTime
  Future<void> _uploadToRemote() async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    if (book == null) return;
    // 防御：仅本地书支持上传（在线书无本地文件，按原版语义不支持）
    if (_isOnlineBook(book)) {
      _snack('上传至远程仅支持本地书籍');
      return;
    }
    // 前置：读取已保存的 WebDAV 配置（复用 SyncNotifier 既有配置链路）
    final syncNotifier = ref.read(syncNotifierProvider.notifier);
    await syncNotifier.loadConfig();
    if (!mounted) return;
    final sync = ref.read(syncNotifierProvider);
    if (!sync.isConfigured) {
      // 未配置 → 提示并引导跳转 WebDAV 设置（对齐原版「未配置webDav」异常提示）
      await _showWebDavNotConfiguredDialog();
      return;
    }
    // 已有远程地址 → 确认是否覆盖（对齐原版 sure_upload 对话框）
    if (book.origin.startsWith(BookType.webDavTag)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('提示'),
          content: const Text('已存在远程 webDav 地址，继续上传？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    // 本地书 bookUrl 即本地文件路径（对齐 Rust import_local_book 落库约定）
    final localPath = book.bookUrl;
    final fileName = book.originName.isNotEmpty
        ? book.originName
        : localPath.split(Platform.pathSeparator).last;
    // 远程路径规则对齐原版 RemoteBookWebDav：rootBookUrl(books/) + originName；
    // path 相对 remote_dir，Rust 侧 full_url = url + remote_dir + path
    final remotePath = 'books/$fileName';
    _snack('正在上传至远程…');
    // [Task #55 F9 | 2026-08-10] 上传与 origin 回写分两段 try/catch：
    // 回写失败时提示「上传成功但保存记录失败」而非误报「上传失败」 — Qoder
    try {
      await api.webdavUploadFile(
        syncNotifier.buildConfigJson(),
        remotePath,
        localPath,
      );
    } catch (e) {
      debugPrint('上传至远程失败: $e');
      if (mounted) _snack('上传失败: ${_errMsg(e)}');
      return;
    }
    if (!mounted) return;
    try {
      // 回写 book.origin（webDav 标记 + 远程完整地址）；从库中读回完整 Book
      // 再 copyWith，防全行覆盖（与 _setBookVariable 同模式）
      final full = await api.getBook(book.bookUrl) ?? book;
      final remoteUrl =
          '${sync.webDavUrl}${syncNotifier.normalizedRemoteDir}$remotePath';
      await api.updateBook(full.copyWith(
        origin: BookType.webDavTag + remoteUrl,
        // 对齐原版：刷新最后检查时间，使之比远程书籍的时间新
        lastCheckTime: DateTime.now().millisecondsSinceEpoch,
      ));
      if (!mounted) return;
      _reload();
      _snack('上传至远程成功');
    } catch (e) {
      debugPrint('上传成功但保存记录失败: $e');
      if (mounted) _snack('上传成功但保存记录失败，请重试');
    }
  }

  /// WebDAV 未配置引导对话框（确认后跳转 WebDAV 设置页）
  Future<void> _showWebDavNotConfiguredDialog() async {
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未配置 WebDAV'),
        content: const Text('上传至远程需要先配置 WebDAV 服务器信息'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    // 异步对话框返回后先检查 mounted，再跳转
    if (goSettings == true && mounted) {
      Navigator.pushNamed(context, AppRoutes.webdavSettings);
    }
  }

  /// SnackBar 轻提示（统一入口）
  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 设置书籍变量（对齐原版 setBookVariable + setVariable 的 bookUrl 分支）
  ///
  /// 弹输入对话框（含说明文案，对齐原版 VariableDialog 的 comment 展示：
  /// 书源 variableComment 非空优先，否则用默认提示），确认后把变量
  /// 写入 Book 并经 update_book 保存。
  ///
  /// [fix Task#45 | 2026-08-09] 对齐原版 BaseBook.putCustomVariable /
  /// getCustomVariable 语义（M4）：variable 为 JSON Map 串，自定义变量
  /// 挂 "custom" 键；输入框初值取 map['custom']，保存时回写该键
  /// （空输入移除键）后 jsonEncode 整体写回。另补原版 inBookshelf
  /// 守卫（M5）：非在架时不 saveBook，避免 upsert 进 books 表 — Qoder
  ///
  /// 防坑：update_book 为全行 UPDATE，保存前必须基于从库中读回的完整
  /// Book 对象（含 readConfig 等字段）仅修改 variable 后回写，
  /// 禁止用页面缓存的不完整对象覆盖。
  Future<void> _setBookVariable() async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    final source = _bookSource;
    if (book == null || source == null) {
      _snack('书源不存在');
      return;
    }
    // 说明文案（对齐原版 getDisplayVariableComment：书源注释优先）
    final srcComment = (source.variableComment ?? '').trim();
    final comment = srcComment.isNotEmpty
        ? srcComment
        : '书籍变量可在js中通过book.getVariable("custom")获取';
    // 输入框初值：解析 variable JSON Map 取 custom 键（解析失败视为空 Map）
    final customInit = _parseVariableMap(book.variable)['custom'];
    // [Task #70 D1 修复 | 2026-08-10] 同 _setSourceVariable：重构为自持
    // StatefulWidget 对话框，消除外部 controller 提前 dispose 隐患 — Qoder
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => _VariableDialog(
        title: '设置书籍变量',
        comment: comment,
        initialText: customInit?.toString() ?? '',
      ),
    );
    if (input == null || !mounted) return;
    // 原版 inBookshelf 守卫：仅在架时 saveBook，否则无条件 updateBook
    // 会把非在架书 upsert 进 books 表（M5）
    if (!_inBookshelf) {
      _snack('请先加入书架');
      return;
    }
    try {
      // 从库中读回完整 Book（含 readConfig 等）仅改 variable 后回写
      final full = await api.getBook(book.bookUrl) ?? book;
      // putCustomVariable 语义：其余键原样保留，仅回写 custom 键
      final varMap = _parseVariableMap(full.variable);
      if (input.isEmpty) {
        varMap.remove('custom');
      } else {
        varMap['custom'] = input;
      }
      await api.updateBook(full.copyWith(variable: jsonEncode(varMap)));
      if (!mounted) return;
      _reload();
      _snack('书籍变量已保存');
    } catch (e) {
      debugPrint('保存书籍变量失败: $e');
      if (mounted) _snack('保存书籍变量失败');
    }
  }

  /// 解析 variable 为可变 Map（非法/空串视为空 Map，
  /// 对齐原版 getVariableMap 解析失败回落空表的容错）
  Map<String, dynamic> _parseVariableMap(String? variable) {
    final raw = (variable ?? '').trim();
    if (raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 解析失败视为空 Map
    }
    return <String, dynamic>{};
  }

  /// 创建书籍更新任务（对齐原版 openBookUpdateTask）
  ///
  /// 先经 findBookUpdateTask 查该书是否已有更新任务：
  /// - 已存在 → 携 editTaskId 跳转 AutoTaskScreen 定位并进入该任务编辑；
  /// - 不存在 → 用 buildBookUpdateTask 构建默认任务（任务名对齐原版
  ///   auto_task_book_update_name：更新 %s），携 newTask 进入创建流程。
  Future<void> _openBookUpdateTask() async {
    final book = _loadedBook;
    if (book == null) return;
    final notifier = ref.read(autoTaskNotifierProvider.notifier);
    // findBookUpdateTask 基于 notifier 内任务列表匹配，先静默加载确保最新
    await notifier.loadTasks(silent: true);
    if (!mounted) return;
    final existing = await notifier.findBookUpdateTask(
      bookUrl: book.bookUrl,
      bookName: book.name,
      bookAuthor: book.author,
    );
    if (!mounted) return;
    if (existing != null) {
      final id = existing['id']?.toString() ?? '';
      await Navigator.pushNamed(
        context,
        AppRoutes.autoTasks,
        arguments: <String, dynamic>{'editTaskId': id},
      );
      return;
    }
    final built = await notifier.buildBookUpdateTask(
      bookUrl: book.bookUrl,
      bookName: book.name,
      bookAuthor: book.author,
      // [fix Task#45 | 2026-08-09] 文案对齐原版 auto_task_book_update_name
      // （「更新 %s」含空格）— Qoder
      name: '更新 ${book.name}',
    );
    if (!mounted) return;
    if (built == null) {
      _snack('创建任务失败');
      return;
    }
    await Navigator.pushNamed(
      context,
      AppRoutes.autoTasks,
      arguments: <String, dynamic>{'newTask': built},
    );
  }

  Widget _buildBody(BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    // [U10/U11/U12 | 台账 0917 批三] 版块顺序对齐参考 08：
    // ①信息聚合行 → ②四按钮卡 → ③在读/最新/共N章三行块 → ④标签行 →
    // ⑤简介 → ⑥分组/目录行（标签行置顶信息面板首行、分组/目录行后移至
    // 简介之后；聚合行并入 ① 信息行只现一次，U9 在读/最新与 U5 聚合行
    // 两处能力均保留）
    final kinds = _buildKindLabels(book);
    // [UI-fix v2.0.6 | 2026-08-08] 移除详情页内嵌「搜索章节」框与完整章节列表，
    // 对齐原版 activity_book_info（详情页不含目录列表，目录由 tv_toc_view 跳转
    // 独立 TocActivity 查看）。详情页仅保留封面卡 + 信息面板（含目录行显示当前
    // 章节名 + 查看目录按钮）。封面虚化背景层（见 _buildPage）仅透过顶部透明的
    // _buildHeader 封面区显现；信息面板起铺不透明 cs.surface 盖住虚化，底部用
    // SliverFillRemaining 续铺纯色，避免短内容时下方透出虚化封面。 — Qoder
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // [UI_SYNC_REFACTOR B4] 折叠顶栏（对标参考仓 BookInfoTransparentTopAppBar
        // 双态：顶部全透明 / 下滑 surfaceContainer 玻璃色；collapsedFraction 由
        // 滚动监听驱动，actions 经 TopBarActionStyler 统一注入样式）
        ValueListenableBuilder<double>(
          valueListenable: _topCollapse,
          builder: (context, t, _) {
            final topStyle =
                uiSettingsListenable.value.topBarButtonStyle;
            final topMerge =
                uiSettingsListenable.value.mergeTopBarActions;
            final barColor = Color.lerp(
              Colors.transparent,
              cs.surfaceContainer,
              t,
            );
            final fg = Color.lerp(cs.onPrimary, cs.onSurface, t);
            // [PARITY C1 D10] 三钮裸图标：参考 08 顶栏铅笔/分享/⋮ 为 hero 图上
            // 的裸图标（无圆形容器底，深色描边）；我方原为 tonal 圆钮
            // （surfaceContainerHigh 底）。→ 动作区强制 plain（复用书架页
            // actionsStyle: plain 机制，仅本详情页），并单独注入 onSurface
            // 前景：顶栏透明期 foregroundColor=onPrimary（近白）在浅色 hero
            // 上不可见，参考为深色图标。leading 返回钮仍走 glass 圆底（参考同）。
            final actionsFg = cs.onSurface;
            return SliverAppBar(
              pinned: true,
              automaticallyImplyLeading: false,
              backgroundColor: barColor,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              foregroundColor: fg,
              iconTheme: IconThemeData(color: fg),
              actionsIconTheme: IconThemeData(color: actionsFg),
              leading: LegadoAppBar.shouldShowBack(context)
                  ? TopBarActionStyler.styleActions(
                      context,
                      [
                        IconButton(
                          icon: const Icon(Symbols.arrow_back_rounded),
                          tooltip: MaterialLocalizations.of(context)
                              .backButtonTooltip,
                          onPressed: () => Navigator.maybePop(context),
                        ),
                      ],
                      style: t < 0.5
                          ? TopBarButtonStyle.glass
                          : topStyle,
                      merge: false,
                    ).first
                  : null,
              // 折叠后展示书名（对齐参考仓 TransparentTopAppBar title=书名）
              title: t > 0.5
                  ? Text(
                      book.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              // [PARITY C1 D10] 动作三钮固定 plain（参考=裸图标）；merge 仍随
              // 用户设置（与书架页 plain 机制一致）
              actions: TopBarActionStyler.styleActions(
                context,
                _buildTopBarActions(),
                style: TopBarButtonStyle.plain,
                merge: topMerge,
              ),
            );
          },
        ),
        // 头部两栏（封面左置 110×160 + 信息右置；[U10-U12] 版块顺序重排后
        // 头部仅保留两栏，标签行/在读最新块/聚合行按参考序独立成 sliver）
        SliverToBoxAdapter(child: _buildHeader(context, book, chapters)),
        // [U10 | 台账 0917 批三] ① 信息聚合行「评分 · 类型 · N章 · N字 · 完结态」
        //（U5 聚合行并入 ① 信息行位，参考 08 只现一次；缺项省略、整行无
        // 数据不渲染，位置不变仍在头部与四按钮之间）
        SliverToBoxAdapter(
          child: _buildAggregationLine(context, book, kinds, chapters),
        ),
        // ② 操作宫格（B1：四宫格：已在书架/查看目录/书源/阅读记录；
        // 「分组」收进 ⋮ 菜单）[PARITY C1 D2] 卡片行紧随 ① 信息行
        SliverToBoxAdapter(child: _buildActionCards(context, book)),
        // [U10 | 台账 0917 批三] ③ 在读/最新/共N章 三行块（原置于四按钮
        // 之前，参考 08 排在四按钮之后；U9 在读/最新行 + D4 共N章单行，
        // 缺数据行不渲染，共N章行恒渲染）
        SliverToBoxAdapter(
          child: Column(
            // 原头部 Column 为 start 对齐，此处保持逐行自带左距 13dp
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._buildReadLatestLines(context, book, chapters),
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 16, 0),
                child: _buildChapterStatLine(context, book, chapters),
              ),
            ],
          ),
        ),
        // [UI_SYNC_REFACTOR S3] Characters/RelatedBooks 区块骨架（已授权；
        // 数据链需后端调研——见 UI_ONE_TO_ONE_CLONE_PLAN_20260905.md §〇，
        // 无数据时整段隐藏=缺省降级）
        ..._buildCharactersSection(context, book),
        ..._buildRelatedBooksSection(context, book),
        // ④ 标签行 → ⑤ 简介 → ⑥ 分组/目录行（[U11/U12 | 台账 0917 批三]
        // 标签行置顶面板首行、分组/目录行后移至简介之后；书名/作者/来源
        // 两栏区在 _buildHeader）
        SliverToBoxAdapter(
          child: _buildSummaryPanel(context, book, chapters, kinds),
        ),
        // 底部续铺纯色：内容不足一屏时填满剩余视口，避免透出封面虚化层
        SliverFillRemaining(
          hasScrollBody: false,
          child: Container(color: cs.surface),
        ),
        // [LAYOUT_MOTION_AUDIT L3] 底部避让 88dp（FAB）+ 120dp：内容尾部留白防遮挡
        const SliverToBoxAdapter(child: SizedBox(height: 88 + 120)),
      ],
    );
  }

  /// 顶部头部区（B1 形态对齐：参考版「封面左置 + 信息右置」两栏）
  /// - 左：110×160 圆角 3 封面卡（点击换封面 / 长按预览大图行为不变）
  /// - 右：信息列（书名 titleLarge 加粗 / 作者 / 来源=书源名，交互行为不变）
  /// - [U10-U12 | 台账 0917 批三] 标签行/在读最新块/聚合行不再置于头部，
  ///   按参考 08 版块序独立成 sliver（_buildBody 中 ①③④ 位）
  /// — full-stack-engineer + UI
  Widget _buildHeader(
      BuildContext context, Book book, List<BookChapter> chapters) {
    final topPadding = MediaQuery.paddingOf(context).top + kToolbarHeight + 8;
    final cs = Theme.of(context).colorScheme;
    final ts = Theme.of(context).textTheme;
    // [U6 | 台账 0917 批二] 双（深+浅）柔阴影：去掉信息列浅底卡后，书名/作者/
    // 书源直排于 hero（参考 08 无卡底），此阴影保证任意（亮/暗）封面 hero 下
    // 深色文字对比可读（深色阴影压亮底、浅色光晕托暗底）
    // [F1 | 台账 0917 08 批] 强化为「深色文字 + 白色柔光」保底组合（历史）
    // [G3 | 台账 0917 批六] 改「深色为主」：三行文字保持完全不透明 onSurface
    // （亮态 hero 上即纯黑书名，对齐 ref 08 PIL 实测墨 L≤17）；深阴影升为
    // 主保障 α0.60/blur6/offset(0,1.5) 压亮底；白色柔光降权至 α0.25/blur12
    // 仅作暗 hero / 暗色主题保险，避免强白晕冲淡深色高对比观感
    final heroTextShadows = const [
      Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1.5)),
      Shadow(color: Color(0x40FFFFFF), blurRadius: 12),
    ];
    // [U10 | 台账 0917 批三] 版块重排后头部以两栏收尾，底距 12→4：
    // 与 ① 聚合行 top 8 合成 12dp 间隙（原 12dp 底距随移出的版块移除）
    return Padding(
      padding: EdgeInsets.only(top: topPadding, bottom: 4),
      child: Column(
        // [PARITY C1 D6] 信息流左对齐（参考 08：各信息行随封面左缘起排）；
        // Column 默认 center 会使收缩行居中 → start。
        // [U10-U12] 标签行/在读最新块/聚合行已移出头部（见 _buildBody 版块序）
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 两栏：封面左置 + 右侧信息列
          // [U2 | 台账 0917] 封面回缩至原版 XML 尺寸 110×160dp（ref 08 PIL
          // 实测 337×469px≈112×156dp，圆角 2-3dp）；左距 13dp、与右侧
          // 信息列间隙 17dp（PIL 实测 39-40px/52px），信息列垂直居中
          // （参考版书名顶距封面顶 44.7dp≈160dp 封面内居中，对齐参考位置）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // [G4 | 台账 0917 批六] 封面卡浮起观感：阴影保留（elevation 8），
                // 补 1px 浅描边（outlineVariant 槽位；ref 08 PIL 实测卡缘 ~1-2px
                // 浅灰线 L≈150-154）。G1 渐隐后卡下缘落在纯 surface 底色区，
                // 描边+阴影的浮起感清晰，对齐参考
                Material(
                  elevation: 8,
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(3),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: GestureDetector(
                      // 对齐原版 ivCover 点击换封面 / 长按预览大图 — Cursor UI
                      onTap: () => _openChangeCover(book),
                      onLongPress: () => _previewCover(book),
                      // [LAYOUT_PLAN P4] 外层 Hero 接管过渡，flightShuttle 走全局
                      // coverFlightShuttleBuilder（内层 heroTag 置空防嵌套），
                      // tag 统一 book-cover:
                      child: Hero(
                        tag: 'book-cover:${book.bookUrl}',
                        flightShuttleBuilder: coverFlightShuttleBuilder,
                        child: BookCover(
                          coverUrl: book.customCoverUrl ?? book.coverUrl,
                          // [U2 | 台账 0917] 110×160dp 圆角 3（原版
                          // activity_book_info.xml iv_cover 精确值 + ref PIL
                          // 实测 112×156dp；2.0.276 的 120×260 偏大，回缩）
                          width: 110,
                          height: 160,
                          borderRadius: 3,
                          sourceOrigin: book.origin,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 17),
                Expanded(
                  child: Container(
                    // [U6 | 台账 0917 批二] 去掉淡色护底卡：信息列（书名/作者/
                    // 书源）透明直排于 hero（对齐参考 08，其标题块无卡底，PIL
                    // 实测标题区背景=hero 透传 117-176 渐变，非浅底卡）。对比度
                    // 改由文字双（深+浅）柔阴影 heroTextShadows 保证，任意封面
                    // （亮/暗）hero 下均可读
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 书名（对齐原版 tvName 点击/长按 → SearchActivity）
                        GestureDetector(
                          onTap: () => _openSearch(
                              book.name, event: 'clickBookName'),
                          onLongPress: () => _sourceCallBackSearch(
                              'longClickBookName', book.name),
                          child: Text(
                            book.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            // [U3 | 台账 0917] 大字深色：ref 08 PIL 实测
                            // 墨高 65px≈22sp（任务估 28sp 为缩略预览误估，
                            // 以 PIL 量化为准）；主题 titleLarge=18sp 偏小，
                            // 此处显式定 22sp w700 onSurface 高对比
                            // [F2 | 台账 0917 08 批] 复测 ref 08 书名墨高
                            // 70px≈23.3sp → 24sp（22sp 偏小一档）
                            style: ts.titleLarge?.copyWith(
                              fontSize: 24,
                              height: 1.35,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                              shadows: heroTextShadows,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        // 作者（点击 → 搜索作者；长按 → JS 回调，行为不变）
                        GestureDetector(
                          onTap: () => _openSearch(book.author,
                              event: 'clickAuthor'),
                          onLongPress: () => _sourceCallBackSearch(
                              'longClickAuthor', book.author),
                          behavior: HitTestBehavior.opaque,
                          child: Text(
                            book.author.isNotEmpty ? book.author : '未知作者',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // [U3 | 台账 0917] 中等可读灰（ref PIL 实测
                            // 14-16sp）；[U6] 去护底卡后对比度由
                            // heroTextShadows 双柔阴影保证
                            // [F1 | 台账 0917 08 批] 过淡灰 onSurfaceVariant
                            // （wcag 2.08-3.36 <4.5）改完全不透明 onSurface +
                            // 强化白柔光阴影，任意 hero 下可读
                            style: ts.bodyMedium?.copyWith(
                              color: cs.onSurface,
                              shadows: heroTextShadows,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // 来源=书源名（点击 → 编辑书源；「换源」小按钮，行为不变）
                        Row(
                          children: [
                            // [F1 | 台账 0917 08 批] 图标随文字改 onSurface 高对比
                            Icon(Symbols.language_rounded,
                                size: 14, color: cs.onSurface),
                            const SizedBox(width: 6),
                            Expanded(
                              child: GestureDetector(
                                onTap: _isOnlineBook(book)
                                    ? () => _openSourceEdit(book)
                                    : null,
                                behavior: HitTestBehavior.opaque,
                                child: Text(
                                  '来源：${book.originName.isNotEmpty ? book.originName : book.origin}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  // [F1 | 台账 0917 08 批] onSurfaceVariant
                                  // → onSurface 高对比 + 白柔光阴影；
                                  // [F2] ref 08 来源行墨高 32px≈10.7sp → 11sp
                                  // （原 14sp 偏大一档）
                                  style: ts.bodyMedium?.copyWith(
                                    fontSize: 11,
                                    color: cs.onSurface,
                                    shadows: heroTextShadows,
                                  ),
                                ),
                              ),
                            ),
                            _smallAction(context, '换源',
                                () => _showChangeSourceDialog(book)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// [PARITY C1 D4] 章节信息单行：「共 N 章｜未读/已读」（对齐参考 08；
  /// 替代原「在读/最新/目录」三行强调排版）。
  /// 章数取 book.totalChapterNum 优先、回落实际章节数；
  /// 状态：有阅读进度（durChapterIndex > 0）为「已读」，否则「未读」。
  Widget _buildChapterStatLine(
      BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    final ts = Theme.of(context).textTheme;
    final chapterTotal =
        book.totalChapterNum > 0 ? book.totalChapterNum : chapters.length;
    if (chapterTotal <= 0) {
      return Text('暂无章节',
          style: ts.bodyLarge?.copyWith(color: cs.onSurfaceVariant));
    }
    final readState = book.durChapterIndex > 0 ? '已读' : '未读';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '共 $chapterTotal 章｜'),
          // 状态词绿色强调（参考 08 状态词绿调）
          TextSpan(
            text: readState,
            style: const TextStyle(color: Color(0xFF4CAF50)),
          ),
        ],
      ),
      // [H4 | 台账 0917 反馈批七] ref 08 共N章行墨高 35px/字宽 33px≈
      // 12sp → 13sp 偏大，显式定 12sp（保留 w600 强调与状态词绿色）
      style: ts.bodyLarge
          ?.copyWith(fontSize: 12, fontWeight: FontWeight.w600,
              color: cs.onSurface),
    );
  }

  /// [U5 | 台账 0917] 信息聚合行（对齐 ref 08「9.9分 · 轻小说 · 712章 ·
  /// 298.6万字 · 已完结」）：评分 · 类型 · 章数 · 字数 · 完结态，「·」连接，
  /// 缺项自动省略、整行无数据不渲染。
  ///
  /// 数据源：Book 模型无 score/status 字段——评分/完结态自分类标签解析
  /// （形如「9.9分」「已完结」的 kind 项），类型取首个非评分/非完结态/
  /// 非文件大小的 kind 项；章数与章节行同源（totalChapterNum 优先）；
  /// 字数取 Rust 预格式化 wordCount（「298.6万字」形态）经
  /// isMeaningfulText 守卫（[U4] 模板残留/NaN 不渲染）。
  Widget _buildAggregationLine(
      BuildContext context, Book book, List<String> kinds,
      List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    final ts = Theme.of(context).textTheme;
    String? score;
    String? type;
    String? status;
    for (final kind in kinds) {
      if (score == null && RegExp(r'^\d+(\.\d+)?\s*分$').hasMatch(kind)) {
        score = kind;
        continue;
      }
      if (status == null &&
          RegExp(r'^(已完结|完本|已完本|连载中|暂停更新|停更|断更)$')
              .hasMatch(kind)) {
        status = kind;
        continue;
      }
      if (type == null &&
          // 本地书追加的文件大小项（"2.3 MB"）不是类型
          !RegExp(r'^\d+(\.\d+)?\s*(B|KB|MB|GB)$').hasMatch(kind)) {
        type = kind;
      }
    }
    final chapterTotal =
        book.totalChapterNum > 0 ? book.totalChapterNum : chapters.length;
    final items = <String>[
      ?score,
      ?type,
      if (chapterTotal > 0) '$chapterTotal章',
      if (isMeaningfulText(book.wordCount)) book.wordCount!.trim(),
      ?status,
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    // ref 08 量化：12sp 灰（PIL 实测墨色 62-70 灰阶≈onSurfaceVariant）、
    // 左 22dp（x=66px @3x）、距章节行 8dp
    // [F1 | 台账 0917 08 批] 面板区聚合行 onSurfaceVariant（wcag 2.08）改
    // onSurface 高对比（像素断言 ≥4.5:1）；[F2] ref 墨高 38px≈12.7sp → 13sp
    return Padding(
      padding: const EdgeInsets.only(left: 22, top: 8),
      child: Text(
        items.join(' · '),
        style:
            ts.bodyMedium?.copyWith(fontSize: 13, color: cs.onSurface),
      ),
    );
  }

  /// [U9 | 台账 0917 批二] 标签行：「🏷️ 标签1, 标签2…」逗号连排自动换行
  /// （对齐参考 08 形态，替代原竖排 chip：去 chip 底色改纯文本内联连排，
  /// 超宽自动换行为多行）。每个标签独立挂 点击（对齐原版 lbKind →
  /// SearchActivity.start(source, kind)）与长按（JS 回调）手势，行为与原
  /// chip 行一致；本 SDK 无 TapAndHoldGestureRecognizer，故用「纯文本内联 +
  /// 逐 tag GestureDetector」等价实现（TextSpan 单 recognizer 无法双挂）
  Widget _buildTagLine(BuildContext context, Book book, List<String> kinds) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);
    final wrap = Wrap(
      spacing: 0,
      runSpacing: 2,
      children: [
        Text('🏷️ ', style: labelStyle),
        for (var i = 0; i < kinds.length; i++) ...[
          GestureDetector(
            onTap: () => _openSearch(
              kinds[i],
              sourceUrl: book.origin,
              event: 'clickBookLabel',
            ),
            onLongPress: () => _sourceCallBackLabel(
              'longClickBookLabel',
              kinds[i],
            ),
            child: Text(kinds[i], style: labelStyle),
          ),
          if (i < kinds.length - 1) Text(', ', style: labelStyle),
        ],
      ],
    );
    return wrap;
  }

  /// [U9 | 台账 0917 批二] 在读/最新两行（参考 08「在读·第1章…」、
  /// 「最新·第712章…」，置于「共 N 章」行上方；缺数据不渲染该行）：
  /// - 在读行 = 阅读记录进度 durChapterIndex（1 基章节序）→ 实际章节标题
  ///   （目录未加载/越界时降级为不带章节名，不显示脏索引）
  /// - 最新行 = info 的 latestChapterTitle + 总章数（totalChapterNum 优先，
  ///   回落实际章节数）；完结态（分类标签含 已完结/完本/已完本，与 U5
  ///   聚合行同源）追加「（全书完）」后缀
  List<Widget> _buildReadLatestLines(
      BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    final ts = Theme.of(context).textTheme;
    // [F1 | 台账 0917 08 批] 在读/最新行 onSurfaceVariant（wcag 2.79-2.92）
    // 改 onSurface 高对比；[H2/H3 | 台账 0917 反馈批七] ref 08 量化：
    // 在读行墨高 46px/字宽 45px≈16sp 且字框 fill 0.30-0.52 为粗体 →
    // 16sp w700；最新行墨高 40px/字宽 38px≈13sp 常规字重 → 13sp
    Widget line(String text, {double fontSize = 13, FontWeight? weight}) =>
        Padding(
          padding: const EdgeInsets.only(left: 13, top: 6),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts.bodyMedium?.copyWith(
              fontSize: fontSize,
              fontWeight: weight,
              color: cs.onSurface,
            ),
          ),
        );
    final lines = <Widget>[];
    // 在读行（阅读记录：durChapterIndex 为 1 基章节序）
    final durIdx = book.durChapterIndex;
    if (durIdx > 0) {
      var title = '';
      if (durIdx <= chapters.length) {
        title = chapters[durIdx - 1].title.trim();
      }
      // [H2 | 台账 0917 反馈批七] 在读行 16sp w700（ref 墨高 46px 粗体）
      lines.add(
        line(
          '在读·第$durIdx章${title.isEmpty ? '' : ' $title'}',
          fontSize: 16,
          weight: FontWeight.w700,
        ),
      );
    }
    // 最新行（info：latestChapterTitle + 总章数 + 完结态）
    // [E5 | 台账 0917 反馈批四] 部分书源的 latestChapterTitle 字段返回的是完结
    // 状态词（如「已完结」而非章节标题，参考版实测「最新·第51章 已完结」缺
    // 章节名），此时回落目录末章真实标题（与在读行同源 chapters 列表）并追加
    // 「（全书完）」；数据缺（字段为空）保持现状不渲染（D4 单行口径，不造占位），
    // 状态词且目录无标题数据时保持原值（不丢行）。
    final latestStatusRe =
        RegExp(r'^(已完结|完本|已完本|连载中|暂停更新|停更|断更)$');
    final latestRaw = (book.latestChapterTitle ?? '').trim();
    var latestTitle = latestRaw;
    var finished = (book.kind ?? '')
        .split(',')
        .map((e) => e.trim())
        .any((e) => e == '已完结' || e == '完本' || e == '已完本');
    if (latestStatusRe.hasMatch(latestTitle)) {
      final tocTotal =
          book.totalChapterNum > 0 ? book.totalChapterNum : chapters.length;
      final tocIdx = tocTotal > 0 ? tocTotal - 1 : chapters.length - 1;
      if (tocIdx >= 0 && tocIdx < chapters.length) {
        final tocTitle = chapters[tocIdx].title.trim();
        if (isMeaningfulText(tocTitle)) {
          latestTitle = tocTitle;
          finished = true;
        }
      }
    }
    if (isMeaningfulText(latestTitle)) {
      final chapterTotal =
          book.totalChapterNum > 0 ? book.totalChapterNum : chapters.length;
      var text =
          '最新·${chapterTotal > 0 ? '第$chapterTotal章 ' : ''}$latestTitle';
      if (finished) text = '$text（全书完）';
      // [H3 | 台账 0917 反馈批七] 最新行 13sp 常规字重（ref 墨高 40px）
      lines.add(line(text, fontSize: 13));
    }
    return lines;
  }

  /// 操作区四图标卡一行（[PARITY C1 D2]，对齐参考 08）
  /// - 四卡：已在书架/加书架（切换，_toggleShelf）/ 查看目录 / 书源（换源）/
  ///   阅读记录（全部现有能力，行为不变）
  /// - 「设置分组」不占卡位，并入次级入口：顶栏 ⋮ 溢出菜单
  ///   （_handleMenu 'group' → _showChangeGroup），功能不丢失
  /// [H1 | 台账 0917 反馈批七] 四按钮横向拓宽（近卡片横排）：ref 08 量化
  /// 单卡 229px≈76dp 宽 × 207px≈69dp 高、圆角 44.75px≈15dp、卡间距
  /// 24-25px≈8dp、左右页边距 39px≈13dp、横向跨度 989px≈329.7dp →
  /// Row + 4×Expanded 等分（卡宽 (360-26-30)/4=76dp，间距 10dp，边距
  /// 13dp）；图标 20dp + 间距 10dp + 标签 11sp（图标/标签字号随卡宽
  /// 比例微调，标签保持可读，与 ref 字宽 33px/墨高 34px≈11sp 一致）
  Widget _buildActionCards(BuildContext context, Book book) {
    final cs = Theme.of(context).colorScheme;
    Widget card(IconData icon, String label, VoidCallback onTap) {
      // [H1] 宽由 Expanded 等分（≈76dp）；高 69dp 固定（ref 207px≈69dp）
      return SizedBox(
        height: 69,
        child: Material(
          color: cs.surfaceContainerLow,
          // [H1 | 台账 0917 反馈批七] 卡宽 76dp 圆角 15dp（ref 实测
          // 44.75px≈15dp，R/w=0.196；原 52dp 卡 10dp 圆角随卡宽放大）
          borderRadius: BorderRadius.circular(15),
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: cs.primary),
                const SizedBox(height: 10),
                Text(
                  label,
                  // [F1 | 台账 0917 08 批] 四按钮标签在面板区（非 hero）：
                  // onSurfaceVariant（wcag 2.79）改 onSurface 高对比；
                  // [H1] 卡宽拓宽后标签 11sp 保持可读（ref 33px≈11sp）
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: cs.onSurface,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // [H1 | 台账 0917 反馈批七] 等分布局：左右页边距 13dp（ref 左
    // 39px≈13dp）、卡间距 10dp（ref 24-25px≈8-8.3dp，等分布局取 10
    // 使卡宽 (360-26-30)/4=76dp 对齐 ref 229px≈76dp，横向跨度 1002px
    // 对齐 ref 989px，偏差 +1.3%）
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 0),
      child: Row(
        children: [
          Expanded(
            child: card(
              _inBookshelf
                  ? Symbols.playlist_remove_rounded
                  : Symbols.playlist_add_rounded,
              _inBookshelf ? '已在书架' : '加书架',
              () => _toggleShelf(book),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: card(
              Symbols.format_list_bulleted_rounded,
              '查看目录',
              _openTocScreen,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: card(
              Symbols.swap_horiz_rounded,
              '书源',
              () => _showChangeSourceDialog(book),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: card(
              Symbols.history_rounded,
              '阅读记录',
              () => Navigator.pushNamed(context, AppRoutes.readRecord),
            ),
          ),
        ],
      ),
    );
  }

  /// [UI_SYNC_REFACTOR S3] Characters 区块骨架（已授权；数据链后端调研中，
  /// 无数据隐藏=缺省降级）
  List<Widget> _buildCharactersSection(BuildContext context, Book book) {
    // 数据源（参考 BookInfoViewModel.characters）后端调研登记：
    // UI_ONE_TO_ONE_CLONE_PLAN_20260905.md §〇；接通前恒为空
    const List<({String name, String role})> characters = [];
    if (characters.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('角色',
              style: Theme.of(context).textTheme.titleMedium),
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 120,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final c in characters)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Chip(label: Text(c.name)),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  /// [UI_SYNC_REFACTOR S3] RelatedBooks 区块骨架（同上，后端调研中）
  List<Widget> _buildRelatedBooksSection(BuildContext context, Book book) {
    const List<Book> relatedBooks = [];
    if (relatedBooks.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('相关书籍',
              style: Theme.of(context).textTheme.titleMedium),
        ),
      ),
    ];
  }

  /// 信息面板（[U11/U12 | 台账 0917 批三] 版块序对齐参考 08：
  /// ④ 标签行（置顶面板首行，surface 底保证对比）→ ⑤ 简介 →
  /// ⑥ 分组/目录行（upstream 能力，后移至简介之后）；
  /// 书名/作者/来源两栏区在 _buildHeader，B1 形态对齐）
  /// — full-stack-engineer + UI
  Widget _buildSummaryPanel(
      BuildContext context, Book book, List<BookChapter> chapters,
      List<String> kinds) {
    final cs = Theme.of(context).colorScheme;
    final isWebFile = _isWebFileBook(book);
    // 对齐原版 upLoading：加载中 / 失败 / 章节名 + 已读进度 — Cursor UI
    final tocTitle = _buildTocSummaryText(book, chapters);
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        // iOS sheet 风格大圆角顶部
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // [LAYOUT_MOTION_AUDIT L3] 内容边距 18→16（全局水平边距统一 16dp）
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // [U11 | 台账 0917 批三] ④ 标签行：由头部移入面板首行（参考 08 位于
          // 在读/最新块之后、简介之前；「🏷️ 前缀 + 逗号连排」形态与逐 tag
          // 点击搜索/长按 JS 回调行为不变；无 kind 不渲染）
          if (kinds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildTagLine(context, book, kinds),
            ),
          // [U12 | 台账 0917 批三] ⑤ 简介（对标 tv_intro_container +
          // tv_intro_toggle；upstream 的分组/目录行现置其后）
          _buildIntro(context, book),
          // [U12 | 台账 0917 批三] ⑥ 分组行（对标 ic_groups + tv_group，
          // 展示该书所属分组；upstream 能力保留，仅位置后移）
          // [PARITY C1 D2] 行内「设置分组」小按钮已移除，并入次级入口：
          // 顶栏 ⋮ 溢出菜单「设置分组」（_handleMenu 'group' → _showChangeGroup，
          // 行为不变，功能不丢失）
          _summaryRow(context, Symbols.groups_rounded, _groupText(book)),
          // ⑥ 目录行（webFile 书隐藏，对齐原版 ll_toc.gone() — Cursor UI）
          if (!isWebFile)
            _summaryRow(
              context,
              Symbols.folder_open_rounded,
              '目录：$tocTitle',
              action: _smallAction(context, '查看目录', _openTocScreen),
            ),
        ],
      ),
    );
  }

  /// 摘要行（对标原版：18dp 图标 + 6dp 间距 + 13sp 文本 + 可选小按钮）
  Widget _summaryRow(
    BuildContext context,
    IconData icon,
    String text, {
    Widget? action,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final cs = Theme.of(context).colorScheme;
    final summaryColor = cs.onSurfaceVariant;
    Widget label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13, color: summaryColor),
    );
    if (onTap != null || onLongPress != null) {
      label = GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: label,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: summaryColor),
          const SizedBox(width: 6),
          Expanded(child: label),
          // lint：?action 与 build_runner 内置分析器不兼容，用 if-element 等价表达 — Qoder
          // ignore: use_null_aware_elements
          if (action != null) action,
        ],
      ),
    );
  }

  /// 小按钮（对标原版 AccentBgTextView；iOS 风格胶囊小按钮）
  Widget _smallAction(BuildContext context, String text, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, color: cs.onPrimary)),
      ),
    );
  }

  /// 分组显示文本（对标原版 tv_group；book.group 为位掩码）
  /// [PARITY C1 D7] 无分组文案对齐原版 strings：网络书 no_group=「未分组」、
  /// 本地书 local_no_group=「本地未分组」（原实现写死「无」，与原版不一致）
  String _groupText(Book book) {
    final groups = ref.read(bookshelfNotifierProvider).groups;
    final names = groups
        .where((g) => g.groupId > 0 && (book.group & g.groupId) != 0)
        .map((g) => g.groupName)
        .toList();
    if (names.isNotEmpty) return '分组：${names.join('，')}';
    return '分组：${_isOnlineBook(book) ? '未分组' : '本地未分组'}';
  }

  /// 目录行摘要（对齐原版 upLoading + resolveBookInfoReadProgress）— Cursor UI
  String _buildTocSummaryText(Book book, List<BookChapter> chapters) {
    if (_tocLoading) return '加载中…';
    if (chapters.isEmpty) return '加载目录失败';
    final title = _resolveTocTitle(book, chapters);
    final percent = bookInfoReadProgressPercent(book);
    if (percent == null) return title;
    return '$title  ·  已读: $percent%';
  }

  /// 分类标签（本地书追加文件大小，对齐原版 upKinds）— Cursor UI
  List<String> _buildKindLabels(Book book) {
    final kinds = (book.kind ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        // [U4 | 台账 0917] 未渲染模板残留（{{$.xxx}}）/ NaN 脏数据视为
        // 无数据不渲染（Rust 解析层 normalize_js_rule_result 已同源拒收，
        // 此处为渲染层兜底：第三方书源 JS 字符串拼接产物可绕过清洗到达 UI）
        .where(isMeaningfulText)
        .toList();
    if (!_isOnlineBook(book)) {
      try {
        final file = File(book.bookUrl);
        if (file.existsSync()) {
          final size = file.lengthSync();
          if (size > 0) {
            kinds.add(_formatFileSize(size));
          }
        }
      } catch (_) {}
    }
    return kinds;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// 跳转搜索（对齐原版 SearchActivity.start；JS 回调接管时不执行默认搜索）
  Future<void> _openSearch(
    String query, {
    String? sourceUrl,
    String event = 'clickBookName',
  }) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final book = _loadedBook;
    final handled = await _sourceCallBackSearch(event, q);
    if (handled || !mounted) return;
    final args = <String, dynamic>{'query': q};
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      args['sourceUrl'] = sourceUrl;
    } else if (book != null && _isOnlineBook(book)) {
      args['sourceUrl'] = book.origin;
    }
    await Navigator.pushNamed(context, AppRoutes.search, arguments: args);
  }

  /// 返回 true 表示 JS 回调已接管，不应再执行默认动作
  Future<bool> _sourceCallBackSearch(String event, String result) async {
    final book = _loadedBook;
    if (book == null || result.trim().isEmpty) return false;
    try {
      final r = await ref.read(bookApiProvider).sourceCallBackBtn(
            event: event,
            bookUrl: book.bookUrl,
            bookType: book.bookType,
            result: result,
          );
      final actions = r['actions'];
      if (actions is List && mounted) {
        await PlatformBridgeService.instance.dispatchActions(actions);
      }
      return r['invoked'] == true && r['jsTrue'] == true;
    } catch (e) {
      debugPrint('SourceCallBack $event 失败: $e');
      return false;
    }
  }

  Future<void> _sourceCallBackLabel(String event, String kind) async {
    await _sourceCallBackSearch(event, kind);
  }

  /// 编辑书源（对齐原版 tvOrigin → BookSourceEditActivity）
  Future<void> _openSourceEdit(Book book) async {
    if (!_isOnlineBook(book)) return;
    final api = ref.read(bookApiProvider);
    BookSource? source = _bookSource;
    if (source == null || source.bookSourceUrl != book.origin) {
      source = await _findSourceByOrigin(api, book.origin);
    }
    if (source == null) {
      _snack('书源不存在');
      return;
    }
    if (!mounted) return;
    await Navigator.pushNamed(
      context,
      AppRoutes.sourceEdit,
      arguments: source,
    );
    if (mounted) _reload();
  }

  /// 更换封面（对齐原版 ivCover → ChangeCoverDialog.coverChangeTo）
  Future<void> _openChangeCover(Book book) async {
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.changeCover,
      arguments: book,
    );
    if (result is! String || result.isEmpty || !mounted) return;
    final updated = book.copyWith(customCoverUrl: result);
    setState(() => _loadedBook = updated);
    if (_inBookshelf) {
      try {
        await ref.read(bookApiProvider).updateBook(updated);
      } catch (e) {
        debugPrint('保存封面失败: $e');
      }
    }
  }

  /// 封面长按预览（对齐原版 PhotoDialog）
  Future<void> _previewCover(Book book) async {
    final url = book.customCoverUrl ?? book.coverUrl;
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          child: url.startsWith('http')
              ? CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)
              : Image.file(File(url), fit: BoxFit.contain),
        ),
      ),
    );
  }

  /// 目录行标题（对齐原版 BookInfoActivity.resolveBookInfoTocTitle）：
  /// durChapterTitle 非空优先，否则按 durChapterIndex 取章、末章兜底
  /// [UI-fix v2.0.6 | 2026-08-08] — Qoder
  String _resolveTocTitle(Book book, List<BookChapter> chapters) {
    final stored = (book.durChapterTitle ?? '').trim();
    if (stored.isNotEmpty) return stored;
    BookChapter? ch;
    final idx = book.durChapterIndex;
    if (idx >= 0 && idx < chapters.length) {
      ch = chapters[idx];
    } else if (chapters.isNotEmpty) {
      ch = chapters.last;
    }
    final title = (ch?.title ?? '').trim();
    return title.isNotEmpty ? title : '暂无最新章节';
  }

  Widget _buildIntro(BuildContext context, Book book) {
    final raw = book.customIntro ?? book.intro;
    if (raw == null || raw.isEmpty) return const SizedBox.shrink();
    // [UI-fix v2.0.7 | 2026-08-08] 展示层清洗：剥离书源 intro 自带的「简介：」前缀
    // （原版直接显示正文无前缀），清洗后为空则不渲染简介区 — Qoder
    final intro = _cleanIntro(raw);
    if (intro.isEmpty) return const SizedBox.shrink();
    return _ExpandableText(text: intro);
  }

  /// 清洗简介正文：剥离开头的「简介：」「简介 :」等前缀
  /// （兼容全/半角冒号及前后空白，仅剥离一次；对齐原版无前缀直接显示正文）
  /// [UI-fix v2.0.7 | 2026-08-08] — Qoder
  String _cleanIntro(String raw) {
    return raw.replaceFirst(
      RegExp(r'^[\s\u3000]*简介[\s\u3000]*[：:][\s\u3000]*'),
      '',
    );
  }

  // [B1 形态对齐 | full-stack-engineer + UI] 底部固定双按钮栏（加书架/阅读）已移除：
  // 阅读入口改右下浮动胶囊（_buildReadFab）；加书架/移出书架入口保留在四宫格第一格
  //（_buildActionCards），功能不丢失（原版 fl_action 双钮为参考版已替换形态）。

  /// 更新目录（对标原版 refreshToc；从底部按钮迁入溢出菜单）
  Future<void> _refreshToc() async {
    final book = _loadedBook;
    if (book == null || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final api = ref.read(bookApiProvider);
      final List<BookChapter> chapters;
      if (!_inBookshelf) {
        // 未入库：仅内存拉目录，不落库（对齐原版 loadChapter !inBookshelf）
        chapters = await _fetchWebChaptersOnline(api, book);
      } else {
        chapters = await api.refreshToc(book.bookUrl, book.origin);
      }
      if (!mounted) return;
      setState(() => _chapters = chapters);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录已更新，共 ${chapters.length} 章')),
      );
      if (_inBookshelf) {
        _reload();
      }
    } catch (e) {
      if (!mounted) return;
      BookSource? source;
      try {
        final sources = await ref.read(bookApiProvider).getBookSources();
        for (final s in sources) {
          if (s.bookSourceUrl == book.origin) {
            source = s;
            break;
          }
        }
      } catch (_) {}
      if (!mounted) return;
      if (isSourceLoginRequiredError(e)) {
        await promptSourceLoginIfNeeded(context, error: e, source: source);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 打开独立目录页（对齐原版 tv_toc_view → TocActivityResult），
  /// 未在架时先 saveBook（对齐原版点击目录会保存 book）— Cursor UI
  Future<void> _openTocScreen() async {
    final book = _loadedBook;
    if (book == null) return;
    if (_chapters.isEmpty) {
      _snack('目录为空');
      return;
    }
    if (!_inBookshelf) {
      try {
        final api = ref.read(bookApiProvider);
        await api.addBook(
          book.copyWith(bookType: book.bookType | BookType.notShelf),
        );
      } catch (e) {
        debugPrint('打开目录前保存书籍失败: $e');
      }
    }
    if (!mounted) return;
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.toc,
      arguments: book,
    );
    if (!mounted) return;
    if (result is int) {
      await _openReader(context, book, result);
    }
  }

  /// 加入书架 / 移出书架（对标原版 tv_shelf 切换逻辑）
  Future<void> _toggleShelf(Book book) async {
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
    if (_inBookshelf) {
      // [UI-fix v2.0.3 | 2026-08-08] 移出书架按「删除提醒」开关弹确认框
      // （对齐原版 deleteBook + LocalConfig.deleteBookAlert） — Qoder
      if (_deleteBookAlert) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('移出书架'),
            content: Text('确定将《${book.name}》移出书架吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await notifier.removeBook(book.bookUrl);
      if (!mounted) return;
      setState(() => _inBookshelf = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.name}》已移出书架')),
      );
    } else {
      // 清除 notShelf 位转正：之前阅读时可能已以 notShelf 临时落库，
      // addBook 走原地 UPDATE 安全 upsert（不会级联删章节），同时清掉标记进书架。
      await notifier
          .addBook(book.copyWith(bookType: book.bookType & ~BookType.notShelf));
      if (!mounted) return;
      setState(() => _inBookshelf = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.name}》已加入书架')),
      );
    }
  }

  /// 换组（对标原版 tv_change_group → BookGroupDialog，单选菜单实现）
  Future<void> _showChangeGroup() async {
    final book = _loadedBook;
    if (book == null) return;
    final groups = ref
        .read(bookshelfNotifierProvider)
        .groups
        .where((g) => g.groupId > 0)
        .toList();
    if (!mounted) return;
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: const Text('未分组'),
          ),
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g.groupId),
              child: Text(g.groupName),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final updated = book.copyWith(group: selected);
    // 对齐原版 upGroup：在架 saveBook；未在架且 groupId>0 则 addToBookshelf — Cursor UI
    if (_inBookshelf) {
      await ref.read(bookApiProvider).updateBook(updated);
    } else if (selected > 0) {
      await ref.read(bookshelfNotifierProvider.notifier).addBook(
            updated.copyWith(bookType: updated.bookType & ~BookType.notShelf),
          );
      if (mounted) setState(() => _inBookshelf = true);
    } else if (mounted) {
      setState(() => _loadedBook = updated);
    }
    if (mounted) _reload();
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 登录 / 置顶 / 清缓存 — Qoder =====

  /// 书源登录（对标 Kotlin BookInfoActivity menu_login）：
  /// 统一入口 showSourceLogin（V2 动态对话框 / 旧版手动凭据页）
  /// — 2026-08-14 发现页修复 R2 提取公共入口
  Future<void> _loginSource() async {
    final book = _loadedBook;
    if (book == null) return;
    if (book.origin == BookType.localTag ||
        book.origin.startsWith(BookType.webDavTag)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地书籍不支持书源登录')),
      );
      return;
    }
    final api = ref.read(bookApiProvider);
    BookSource? source;
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == book.origin) {
          source = s;
          break;
        }
      }
    } catch (e) {
      debugPrint('获取书源失败: $e');
    }
    if (!mounted) return;
    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到本书对应的书源')),
      );
      return;
    }
    final ok = await showSourceLogin(context, ref, source);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登录成功')),
      );
    }
  }

  /// 置顶（对标 Kotlin BookInfoViewModel.topBook；原版仅置顶无取消）
  Future<void> _topBook() async {
    final book = _loadedBook;
    if (book == null) return;
    try {
      await ref.read(bookApiProvider).topBook(book.bookUrl);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已置顶')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('置顶失败: $e')),
        );
      }
    }
  }

  /// 清除缓存（对标 Kotlin BookInfoViewModel.clearCache；原版无确认框）
  Future<void> _clearCache() async {
    final book = _loadedBook;
    if (book == null) return;
    try {
      final api = ref.read(bookApiProvider);
      await api.sourceCallBackBtn(
        event: 'clickClearCache',
        bookUrl: book.bookUrl,
        bookType: book.bookType,
      );
      final deleted = await api.clearBookCache(book.bookUrl);
      await CacheService.clearSameTitleRemovedFlags();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清除 $deleted 条章节缓存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除缓存失败: $e')),
        );
      }
    }
  }

  // ===== 操作 =====

  Future<void> _openReader(
      BuildContext context, Book book, int chapterIndex) async {
    // [UI-fix v2.0.3 | 2026-08-06] 对齐原版 readBook：未入库在线书阅读前先落库 — Qoder
    // 带正确 origin 落库，使阅读器 DB 依赖成立（get_chapter_content_full 按
    // book.origin 找书源取正文），规避「章节不存在 / 未配置书源」；已入库则幂等跳过。
    final api = ref.read(bookApiProvider);
    // [UI-fix v2.0.12 | 2026-08-10] 解析书籍类型位（对齐原版 BookType 位标记）：
    // 搜索输出不带 type（bookType=0）或旧库只有 notShelf 位时，按书源类型
    // （bookSourceType：1=音频/2=图片/3=文件/4=视频）映射补全，保证分流与
    // 落库类型正确（修复图片/音频/视频源「打不开」——类型位丢失致分流落回
    // 文本阅读器）— Reasonix
    // 分流逻辑抽至 BookOpenUtils，与书架 startActivityForBook 对齐 — Reasonix + UI
    const typeMask = BookOpenUtils.typeMask;
    var typeBits = BookOpenUtils.typeBitsOf(book);
    BookSource? matchedSource;
    if (_isOnlineBook(book)) {
      matchedSource = await _findSourceByOrigin(api, book.origin);
      // 书源媒体类型 / 视频启发式优先于抽图提升（非凡 type=0 MacCMS 等）
      // — Reasonix + UI
      typeBits = BookOpenUtils.resolveTypeBits(typeBits, matchedSource);
    }
    try {
      if (_isOnlineBook(book)) {
        final existing = await api.getBook(book.bookUrl);
        if (existing == null) {
          // 以正确类型位 + notShelf 位标记临时落库：阅读器 DB 依赖成立
          // （按 origin 取正文），但不进书架列表；用户显式「加入书架」时再
          // 清标记转正（见 _toggleShelf）。
          await api.addBook(
              book.copyWith(bookType: typeBits | BookType.notShelf));
        } else if (typeBits != 0 &&
            (existing.bookType & typeMask) != typeBits) {
          // 缺类型位，或文本→图片提升（必应漫画）→ 回填媒体位
          await api.updateBook(existing.copyWith(
              bookType: (existing.bookType & ~typeMask) | typeBits));
        }
        // 漫画/视频等非文本阅读器只收 bookUrl，不会走 ReaderNotifier 的
        // 空目录自愈；详情页「未入库」路径又不落库章节 → 必须在开读前
        // 把目录写入 DB，否则进 comic/video 仍是「暂无章节」。
        // 对齐原版 readBook 前确保目录可用。— Reasonix + UI
        if (!BookOpenUtils.needsReaderNotifier(
            BookOpenUtils.routeForTypeBits(typeBits))) {
          final existingChapters = await api.getChapters(book.bookUrl);
          if (existingChapters.isEmpty && book.origin.isNotEmpty) {
            await api.refreshToc(book.bookUrl, book.origin);
          }
        }
      }
    } catch (e) {
      debugPrint('阅读前落库失败: $e');
    }
    if (!context.mounted) return;
    final container = ProviderScope.containerOf(context);
    final bookToRead = chapterIndex != book.durChapterIndex
        ? book.copyWith(durChapterIndex: chapterIndex, bookType: typeBits)
        : book.copyWith(bookType: typeBits);
    // 按类型分流（对齐原版 BookInfoActivity.startReadActivity）— Reasonix + UI
    final route = BookOpenUtils.routeForTypeBits(typeBits);
    debugPrint(
      '[BookOpen] name=${book.name} origin=${book.origin} '
      'typeBits=$typeBits route=$route '
      'srcType=${matchedSource?.bookSourceType} '
      'videoLike=${BookOpenUtils.looksLikeVideoSource(matchedSource)}',
    );
    if (BookOpenUtils.needsReaderNotifier(route)) {
      container.read(readerNotifierProvider.notifier).openBook(bookToRead);
      // [UI-fix v2.0.11 | 2026-08-10] 阅读返回后重新加载详情数据 — Reasonix
      if (!context.mounted) return;
      await Navigator.pushNamed(context, route);
    } else {
      if (!context.mounted) return;
      await Navigator.pushNamed(
        context,
        route,
        arguments: BookOpenUtils.argumentsForRoute(route, bookToRead),
      );
    }
    if (mounted) {
      _reload();
    }
  }

  /// 打开换源页面，换源成功后用新的 bookUrl 重新加载详情页
  Future<void> _showChangeSourceDialog(Book book) async {
    // [fix Task#24 | 2026-08-08] routes 表统一生成 MaterialPageRoute<dynamic>，
    // pushNamed<String> 会触发运行时强转崩溃
    // （'MaterialPageRoute<dynamic>' is not a subtype of 'Route<String?>?'），
    // 表现为点「换源」无任何反应。改用无类型 pushNamed + is 判定（与 _openTocScreen 一致）— Qoder
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.changeSource,
      arguments: book,
    );
    if (!mounted) return;
    final newBookUrl = result is String ? result : null;
    // 换源成功后 bookUrl 会变化，需要用新 URL 替换当前详情页
    if (newBookUrl != null && newBookUrl.isNotEmpty) {
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.bookInfo,
        arguments: book.copyWith(bookUrl: newBookUrl),
      );
    }
  }
}
