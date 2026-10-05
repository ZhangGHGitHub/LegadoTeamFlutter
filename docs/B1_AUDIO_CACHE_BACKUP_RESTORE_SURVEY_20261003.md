# B1「音频缓存备份/恢复」调研报告（2026-10-03）

编写者：调研员（子代理）｜ 2026-10-03
性质：只读调研 + 契约条文拟稿。**未修改任何代码与既有文档**；本文档为唯一新增文件。
承接：`docs/B1_AUDIO_CACHE_DATA_SURVEY_20261003.md`（上轮：缓存键/写入链/数据链调研与 §2.47 四方法拟稿）。本文只增不覆，上轮结论全部继续有效。
服务裁决：用户对 B1 已裁决——①写入双通道（Android 走 Dart SAF、桌面走 Rust 私有目录）；②播放链不写缓存，仅预下载服务写（按原版）；③旧孤儿键 `hash_i.audio` 默认不读、不迁移；④恢复方式 =「支持读取备份文件就行」；⑤孤儿模块 `rust/legado-core/src/audio_cache.rs` 删除重写；⑥「支持恢复原版备份文件，支持原版备份规则」。

---

## 结论摘要（先行）

1. **原版备份机制不覆盖音频缓存**：`help/storage/` 全包（Backup/Restore/BackupMedia/BackupConfig/BackupAES/LanBackupTransfer/ImportOldData）与备份相关 UI 中，`AudioCacheManager/AudioCacheService/LegadoAudioCache/AudioCacheKey/AudioCachePolicy` **grep 零命中**；备份项清单（`Backup.kt:52-98`）与媒体目录白名单（`BackupMedia.kt:6`，仅 `covers`/`bg`）均无音频缓存。原版**没有任何**「导出/导入/分享音频缓存」入口。唯一间接相关：备份会携带 `audioCacheTreeUri` 这个 pref 键（prefs 快照，`audioCacheTreeUri` 不在忽略清单 `BackupConfig.kt:101-116`）——恢复原版整包备份可拿到「缓存目录 URI 字符串」，但拿不到缓存文件。
2. **「读取原版缓存备份文件」判定：有条件可行**。原版缓存是「SAF 目录树 + 五段式文件名 + `.complete` 标记」，用户自行打包成 zip 后层级天然保留；我方按原版键规则解析即可归位，播放命中判定只看「key16 + `.complete` 存在 + size>0，取 lastModified 最新」。条件：① bookUrl 逐字符一致（原版无任何 bookUrl→目录映射表，唯一缓解 = 恢复原版书架备份使 bookUrl 同源）；② zip 条目名编码兼容（中文标题段，GBK 打包有乱码破坏正则的残余风险 → 校验不过即跳过并计数）；③ 五段式文件名 + `.complete` 校验通过才导入（缺标记跳过）。
3. **我方现有可复用能力**：备份/恢复 UI 与 FFI 已有但走**自有 JSON 格式**（不含原版 zip、不含音频缓存）；SAF 插件 2.1.0 读写列目录全齐；`archive 4.0.9` 纯 Dart 解 zip 有先例；Rust 已有 md5Encode16 逐字节对齐先例与 zip 2.x 依赖。**未发现「从原版 3.x 数据导入」的现成实现**（`import_old_data` 只认阅读 2.x）。
4. **导入需要新增 FFI（最小 1 个方法）**：键计算/文件名解析/`.complete` 校验是业务规则，按红线必须放 Rust；文件搬运（SAF 读、zip 解压、目标写）可留 Dart。拟 `audioCacheImportScan(sourceDir)`（只读扫描校验，返回导入计划 JSON），与上轮 §2.47 四方法合流；计数影响见任务 4。
5. **新增裁决点 G-1..G-8**（任务 5），核心三问：导入范围交互、bookUrl 不匹配策略、zip 编码容错口径。
6. `rust/legado-core/src/audio_cache.rs` **零调用核实成立**（全 Rust 工作区与 Dart bridge 无任何符号消费者）。
7. **kazusa 本源源码仍未找到**；新定位到 `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（HapeLee/legado-with-MD3，git HEAD `488a375`，即 docs/REFACTORING_ACTIVE_PLAN.md:602 所载本地快照）——**参考版系没有音频缓存模块**，本任务对齐基准只能是 Android 原版。

---

## 任务 1 — 原版「备份/恢复」机制全貌

### 1.1 代码位置

原版无 `ui/backup` 或顶层 `backup/` 包（已 `find` 全目录树核实）。备份实现集中在：

| 文件 | 职责 |
|---|---|
| `app/src/main/java/io/legado/app/help/storage/Backup.kt`（511 行） | 备份编排：JSON 导出 + prefs 快照 + zip 打包 + 目的地分发 + WebDAV 上传 |
| `app/src/main/java/io/legado/app/help/storage/Restore.kt`（620 行） | 恢复编排：zip 解压 + 逐文件入库 + prefs 回写 + 媒体目录原子换装 |
| `app/src/main/java/io/legado/app/help/storage/BackupConfig.kt`（217 行） | 备份项分组 key、prefs 忽略清单 |
| `app/src/main/java/io/legado/app/help/storage/BackupMedia.kt`（172 行） | covers/bg 两媒体目录的打包与恢复 |
| `app/src/main/java/io/legado/app/help/storage/BackupAES.kt`（8 行） | cookies/服务器等敏感项 AES 加密 |
| `app/src/main/java/io/legado/app/help/storage/ImportOldData.kt` | 阅读旧版（2.x）数据导入 |
| UI 入口 | `app/src/main/java/io/legado/app/ui/config/BackupConfigFragment.kt`（备份项勾选、备份、恢复、WebDAV、局域网备份） |

### 1.2 备份项清单

清单由 `selectedBackupFileNames`（`Backup.kt:52-98`）按用户勾选的分组 key（`BackupConfig.kt:30-42`）拼装；实际写文件在 `Backup.kt:268-345`：

| 分组 key（BackupConfig.kt） | 文件（备份根目录平铺） | 内容 |
|---|---|---|
| `backupBookshelf` | `bookshelf.json`、`bookGroup.json` | Book 全量（含 bookUrl 明文）、书组 |
| `backupAnnotations` | `bookmark.json`、`highlight.json`、`highlightRule.json` | 书签/高亮/高亮规则 |
| `backupSources` | `bookSource.json`、`rssSources.json`、`rssStar.json`、`sourceSub.json` | 书源/RSS 源/收藏/订阅 |
| `backupCookies` | `cookies.json`（BackupConfig.kt:40；AES 加密 Backup.kt:312-317） | Cookie DB |
| `backupSourceVariables` | `runtimeSourceCache.json`（AES 加密 Backup.kt:318-324） | 书源运行时变量缓存 |
| `backupRules` | `replaceRule.json`、`txtTocRule.json`、`httpTTS.json`、`keyboardAssists.json`、`dictRule.json`、`autoTask.json`、`servers.json`、直链上传规则、封面规则 | 各规则/服务器/封面配置 |
| `backupHistory` | `readRecord.json`、`searchHistory.json` | 阅读/搜索历史 |
| `backupSettings` | 阅读界面配置、分享配置、主题配置、`config.xml`（defaultSharedPreferences 快照，Backup.kt:347-373）、`videoConfig.xml`（Backup.kt:375-389） | 设置 |
| 媒体（跟 covers/bg 开关） | `covers/`、`bg/` 两个目录整树（BackupMedia.kt:6 `backupMediaDirectoryNames = listOf("covers", "bg")`；打包 Backup.kt:399-408 → prepareBackupMediaDirectories） | 封面图、阅读背景图 |

### 1.3 备份产物形态

- **单一 zip 文件**：先写平铺 JSON 到暂存目录 `filesDir/backup/`（Backup.kt:113-115），`ZipUtils.zipFiles(paths, workingZipFile)` 打包（Backup.kt:416）；完成后删暂存。
- **文件名规则**：`backup{yyyy-MM-dd}.zip` 或带设备名 `backup{yyyy-MM-dd}-{deviceName}.zip`（Backup.kt:122-131）；「仅保留最新」开启时固定 `backup.zip`（Backup.kt:411-415）。
- **目的地**（Backup.kt:419-430）：未配置 → app 外部私有目录；`content://` SAF tree（`AppConfig.backupPath`，DocumentFile 写入）；本地路径 → File 写入。随后可选上传 WebDAV（Backup.kt:431-439）。
- **zip 条目名**：`ZipUtils.kt:180` 用 `File.separator`（Android 上 `/`）拼**相对路径**，Java `ZipOutputStream` 默认 UTF-8；目录条目带 `/` 尾缀（ZipUtils.kt:184）。媒体目录以 `covers/xxx.jpg` 形式保留层级。
- 自动备份：每日一次（Backup.kt:133-156），走同一 `backup()`。

### 1.4 恢复（导入）流程

- **来源选择**：`BackupConfigFragment.kt:588-596` `restoreFromLocal()` → `restoreDoc.launch { mode = FILE; allowExtensions = arrayOf("zip") }`（自建文件浏览器 `HandleFileContract`/`HandleFileActivity`，`ui/file/HandleFileContract.kt:18`；返回 `file://` 或 `content://` uri）。另有 WebDAV 恢复（:413 restoreOrThrow 经 LanBackupTransfer 下载）与「导入旧版数据」（:182 restoreOld → ImportOldData）。
- **解压**：`Restore.extractBackup`（Restore.kt:193-206）——content scheme 用 `DocumentFile.fromSingleUri(...).openInputStream()`，否则按 File 路径；`ZipUtils.unZipToPath` 解压到 `filesDir/backup/`；zip-slip 防护在 `ArchivePathUtils.kt:10-22`（拒绝绝对路径/盘符/逃逸条目）。
- **解析**：`Restore.restore(path)`（Restore.kt:221-568）按**固定文件名**逐个读取：`bookshelf.json`（含封面路径重映射、本地书封面修正，:260-297）→ 各规则/历史/书源 JSON → prefs 快照回写（:452-513）→ `covers/`、`bg/` 媒体目录原子换装（restoreBackupMediaDirectory，BackupMedia.kt:106-172：staging → rename 换装 → 失败回滚 previous）。
- 全部按文件名约定解析，**无清单/索引文件**。

### 1.5 明确结论：原版备份机制【不覆盖】音频缓存

证据（三项独立核实）：

1. **引用零命中**：在 `help/storage/` 全包、`ui/config/`、`ui/association/` 范围 grep `LegadoAudioCache|AudioCacheManager|AudioCacheService|AudioCacheKey|AudioCachePolicy` → **零命中**（grep 退出码 1）。
2. **清单核对**：备份项全集 = §1.2 表格；`Backup.kt:52-98` 无任何音频项；媒体目录白名单仅 `covers`/`bg`（BackupMedia.kt:6，且恢复侧 `require(name in backupMediaDirectoryNames)` BackupMedia.kt:13 强校验，加目录必须改代码）。
3. **写入链无备份挂钩**：音频缓存写入全仓唯一调用点是 `service/AudioCacheService.kt:217`（`AudioCacheManager.cacheChapter`，前台预下载服务），该服务与 `Backup`/`Restore` 零调用关系。

**结论：原版「备份」产物（backup{date}.zip）里没有音频缓存文件；原版「恢复」也不会还原音频缓存。**

### 1.6 间接相关事实：备份携带缓存目录授权 URI

`audioCacheTreeUri` 不在 prefs 忽略清单（`BackupConfig.kt:101-116` ignorePrefKeys 共 13 键，无此键），因此：

- 备份时随 `config.xml` prefs 快照打包（Backup.kt:347-373 全量遍历 defaultSharedPreferences）；
- 恢复时回写（Restore.kt:452-513）。

含义：恢复原版整包备份后，**缓存目录 URI 字符串会跟着走**。但 SAF 授权按 app+URI 授予、不跨 app 继承（上轮 D4 已核实），该 URI 对我方只是「提示用户应授权哪个目录」的线索，不是可用授权。对本任务的价值：若将来实现「恢复原版整包备份」，可顺带获得目录线索；单做「音频缓存备份文件导入」则完全用不上此键。

### 1.7 原版有无「导出/导入/分享缓存」其他入口？

**无。** 全仓核实：

- `ui/book/cache/CacheActivity.kt:76-90`：唯一叫「导出」的缓存页是**文字书正文导出**（txt/epub/pdf，exportTypes，CacheActivity.kt:77），与音频缓存无关。
- 音频侧（`ui/book/audio/`、`help/audio/`、`service/AudioCacheService.kt`）grep `ACTION_SEND|createChooser|ShareCompat|导出|分享` → 零命中。
- 缓存「分享」仅存在文字章节分享/全书导出链路，不涉及 `LegadoAudioCache/`。

**因此「原版备份文件」若指官方备份 zip，里面根本没有音频缓存；用户裁决 4「支持读取备份文件」只能解释为：用户自行把原版缓存目录打包成文件（zip），我方读取导入。** 下文任务 2 按此口径评估。

---

## 任务 2 — 「读取原版缓存备份文件」技术可行性

### 2.1 格式：目录树打包成 zip 后层级与文件名天然保留吗？

原版缓存布局（上轮 A2 已核，本轮复核）：

```
<用户 SAF tree>/LegadoAudioCache/book_{md5Encode16(bookUrl)}/
    00001_<key16>_<safeTitle≤40>_<playUrlHash16>_<rev8>.mp3     ← 音频数据
    00001_<key16>_<safeTitle≤40>_<playUrlHash16>_<rev8>.mp3.complete  ← 完成标记
    ...
```

- 文件名生成 `AudioCachePolicy.buildFileName`（`help/audio/AudioCachePolicy.kt:67-98`）；解析正则 `^(\d{5,})_([0-9a-f]{16})_.+_([0-9a-f]{16})_([0-9a-f]{8})\.([a-z0-9]{2,6})$`（AudioCachePolicy.kt:11-13，扩展名白名单 :15-18、:104）。
- 用户用任意工具打包该目录成 zip：**条目相对路径（`LegadoAudioCache/book_xxx/00001_...mp3`）天然保留层级与文件名**，我方按路径逐段解析即可，无需任何转换。原版自己的 zip 工具条目名用 `/` 分隔（ZipUtils.kt:180，Android 平台 File.separator 即 `/`）。
- **坑（已识别，有缓解）**：
  1. **条目名编码**：`safeTitle` 段常含中文。第三方打包工具对未标 UTF-8（EFS 标志）的条目可能用 GBK——Dart `archive` 解码按 UTF-8，GBK 条目的 title 段会乱码。因 key 段/index 段/hash 段/revision 段均为 ASCII hex/数字，多数情况仍可解析；但 GBK 双字节可能落在 0x5F（`_`）等分隔符字节上破坏五段结构 → 正则失配。**缓解：解析失败的文件跳过并计入导入报告（与原版 parseFileName 失败跳过同语义，AudioCacheManager.kt:80）**；不建议引入 GBK 回退（`archive` 包不支持，自研解码器成本不值）。
  2. **`.complete` 标记是普通文件**，随目录打包即可；但用户若手工挑选文件可能漏掉 → 导入校验必须把「无标记」当无效（见 2.4）。
  3. zip 内根层级可能是 `LegadoAudioCache/` 或直接 `book_xxx/`（用户打包的根不同）→ 扫描时两种都识别（按目录名形态判定，不需用户指定）。

### 2.2 bookUrl 映射前提：md5Encode16 细节与「无缓解手段」确认

- `md5Encode16`（`utils/MD5Utils.kt:29-33`）= `md5Encode(str).substring(8, 24)`；`md5Encode` = hutool `DigestUtil.digester("MD5").digestHex(str)`（MD5Utils.kt:21-23）。即 **MD5 小写 hex 32 位的 [8..24) 中段 16 字符**。hutool 对 String 的摘要按 **UTF-8 字节、不 trim、大小写敏感**（hutool 库行为，源码不在本仓——此句为库事实标注，非本仓证据）。我方 Rust 侧已有两处逐字节对齐先例：`md5::compute(url)` 取 `[8..24]`（`rust/legado-ffi/src/api/image_cache_api.rs:148-151`，P4-2a 图片缓存已在用）、`md5_encode_16`（`rust/legado-js/src/host_api/encoding.rs:36-39`），均为 UTF-8 字节 + 小写 hex + 中段 16。
- 书级目录名 `book_${md5Encode16(bookUrl)}` 为**即时计算**，出现在 `AudioCacheManager.kt:210`（getBookFolder）、`:228`（requireBookFolder）；全文件核对**没有任何 bookUrl→目录的映射表或 DB 记录**（音频缓存无任何 DB 表，全靠文件系统形态）。
- **结论：我方必须持有与原版逐字符一致的 bookUrl 才能把 `book_{md5_16}` 目录映射回书。原版无缓解手段；唯一同源保障 = 恢复原版书架备份（`bookshelf.json` 含 bookUrl 明文）后，书与 URL 天然一致。** 反过来，音频缓存目录里只有 md5 不可逆——反向枚举不可行，只能「拿已知 bookUrl 算 md5 去匹配目录」。
- 我方 DB 同样以 bookUrl 原文为主键存储；同一书源对同一书推导的 bookUrl 字符串是否与用户原版一致，取决于书源规则与生成时机，**无法程序保证，只能导入时逐一匹配并在报告中呈现未匹配项**。

### 2.3 章节文件名里的 title / playUrlHash 段：不参与命中

- 播放查找：`AudioPlay.kt:388-392`（本轮复核 `AudioPlay.kt:379-413` 区段）→ `AudioCacheManager.getCachedAudio`（AudioCacheManager.kt:61-74）→ `findCachedFile`（:201-203）= 在 `committedCacheFiles(folder, key)` 里取 **lastModified 最新**。
- `committedCacheFiles`（:358-373）有效性 = ①`size > 0`；②存在同名 `.complete`；③`parseFileName(name)?.key == key`。
- 即：**命中判定只消费 key16 段 + `.complete` 存在性 + size；title 段、playUrlHash 段、revision 段都不参与**，仅受正则形状约束（title 段 `.+` 非空、扩展名白名单）。playUrlHash 只在写入时生成，revision 仅为多代共存 + 最新优先。
- **导入归位只需：把文件放进正确的 `book_{md5_16(bookUrl)}/` 目录即可**；无需还原/改写 title 或 hash 段。但文件名必须**整体**过五段式正则（不能只造 key 段，原版 parseFileName 是全名匹配）。

### 2.4 `.complete` 标记：导入必须校验

- 原版查找**强依赖**标记：`committedCacheFiles` 要求同名 `.complete` 存在（AudioCacheManager.kt:363-371）——**缺标记的数据文件永远不可见**（视为未完成，等效不存在）。
- 标记内容（`AudioCacheMetadata.encode`，AudioCachePolicy.kt:141-143）= `"1\n{md5Encode16(playUrl)}\n{playUrl}"`（UTF-8，AudioCacheManager.kt:270）；`decode`（AudioCachePolicy.kt:145-152）校验版本行与 md5 自洽，失败返回 null。
- 播放侧对标记的消费（本轮复核 `AudioPlay.kt:379-413`）：命中后 `durPlayUrl = cachedAudio.playUrl ?: chapter.resourceUrl.orEmpty()`（标记 decode 失败时 playUrl=null，回退章节地址）；`durMediaUrl = cachedAudio.mediaUri`（缓存文件 URI）。**即标记损坏不阻止播放文件本体，只丢失 playUrl 关联**。
- **导入口径（推荐）**：①无 `.complete` 的数据文件 → 跳过不导入（对齐原版「未提交不可见」语义，也避免导入半成品）；②`.complete` 存在但内容损坏 → 照原样导入（原版行为=可播、playUrl 回退），计入报告提示。标记文件的校验（md5 自洽）放 Rust。

### 2.5 可行性判定

**判定：有条件可行。**

| # | 条件 | 说明 | 未满足的后果 |
|---|---|---|---|
| C1 | **bookUrl 逐字符一致** | 用户须先在我方持有同一本书（同 bookUrl）。建议引导：先恢复原版书架备份/书源再导缓存 | 该书缓存无法映射，整目录跳过并报告 |
| C2 | **目标缓存目录已就位** | Android：我方授权同一 SAF 目录（或用户指定新目录）；桌面：Rust 私有目录固定 | 无法落盘，导入前置失败 |
| C3 | **zip 条目名可解析** | UTF-8 打包无坑；GBK 打包的个别文件 title 段乱码 → 正则失配 | 单文件跳过并计数，不阻断整批 |
| C4 | **五段式 + `.complete` 校验通过** | key 段为 16 位 hex、扩展名白名单、标记齐全 | 同上，跳过计数 |
| C5 | **导入布局 = 原版布局原样落位** | 不重命名、不迁移键（与用户裁决 3「不迁移」及上轮 D2-A 一致） | — |

无阻断性技术障碍：文件搬运 Dart 全套能力现成（任务 3），解析/校验/键计算 Rust 全套能力现成（md5/zip/正则先例齐备）。

---

## 任务 3 — 我方现有「备份/导入」基础设施盘点

### 3.1 已有备份/恢复能力（可复用的骨架）

| 层 | 位置 | 能力 | 与本任务的关系 |
|---|---|---|---|
| UI | `flutter_legado/lib/src/screens/webdav_settings_screen.dart:37-44`（「备份与恢复」区：备份路径/备份/恢复/恢复忽略/仅保留最新/自动检查；:43 顶栏含「导入旧版数据」） | 本地备份（file_picker 选路径，:166-193）、本地恢复（file_picker 选文件，:219-241）、WebDAV 恢复 | **交互骨架可直接套**（「恢复」入口旁加「导入音频缓存」或缓存页内加导入项） |
| FFI | `rust/legado-ffi/src/ffi.rs:2056-2073`（backup_create/backup_restore/backup_list/import_old_data）；实现 `rust/legado-ffi/src/api/backup_api.rs:69,152,259,300` | 备份/恢复为**自有 JSON 格式**（BackupData：books/bookmarks/replaceRules/bookSources/rssSources/readRecords，backup_api.rs:22-48）；**只认 .json 文件，不认原版 zip**（backup_restore 直接 `fs::read_to_string` + serde 解析，:152-157） | **不能复用其格式**；但其「FFI + file_picker 选路径 + 进度文案」模式可套 |
| 旧版导入 | `backup_api.rs:296-374` `import_old_data` | 只认**阅读 2.x** 的 `myBookShelf.json`/`myBookSource.json`/`myBookReplaceRule.json`（目录内扫描、缺文件记 message） | 「扫描目录+逐文件解析+统计报告」的**流程先例**，格式不同 |
| zip 处理（Dart） | `flutter_legado/lib/src/screens/archive_import_dialog.dart`（压缩包内书籍列表 + 多选 + 编码检测，对标原版 BaseImportBookActivity） | `archive` 包读 zip 条目列表 + 逐条解出 | **zip 导入交互与解压的现成先例** |
| 书架分享 | `flutter_legado/lib/src/screens/bookshelf_screen.dart:1076-1096` | 输出**原版格式** `bookshelf.json` 分享 | 我方 Book 模型 ↔ 原版 JSON 的序列化先例（bookUrl 原文保留） |
| 其他 | `services/backup_service.dart`（83 行，书源/书架 JSON 导出导入）、`services/export_service.dart`、`services/bookmark_export.dart`、`services/source_import_service.dart`（389 行） | 各类 JSON 导入导出 | 无音频缓存相关内容 |

**结论：没有现成的「从原版 3.x 备份/数据导入」实现；有格式无关的流程骨架（目录扫描+解析+统计、zip 导入交互、恢复入口 UI）可复用。音频缓存相关现仅有孤儿写（`audio_screen.dart:996` `'${bookUrl.hashCode}_$i.audio'`，行号本轮复核）与 pref 键（`audio_skip_policy.dart:18`）。**

### 3.2 SAF 能力现状（版本与 API 核实）

- **版本**：`flutter_legado/pubspec.yaml:35` → `saf: ^2.1.0`；`pubspec.lock` 实际解析 **2.1.0**（本机 pub cache 路径 `C:\Users\admin\AppData\Local\Pub\Cache\hosted\pub.dev\saf-2.1.0`，package_config.json:809-810 同证）。此前调研所报「2.1.0 有 writeFileStream/openFileDescriptor」**属实**。
- **v2 API 全清单**（`saf-2.1.0/lib/src/v2/saf.dart`，行号为该文件实测）：`pickDirectory`(:32)、`pickFile`(:45)、`releasePersistedPermission`(:73)、`stat`(:82)、`exists`(:85)、`child`(:90)、`mkdirp`(:95)、`delete`(:99)、`rename`(:102)、`copyTo`(:109)、`moveTo`(:116)、`readFileBytes`(:129)、`writeFileBytes`(:142)、**`writeFileStream`(:150)**、`copyToLocalFile`(:160)、`pasteLocalFile`(:165)、**`openFileDescriptor`(:198)**、`closeFileDescriptor`(:204)、`thumbnail`(:210)、`withFileDescriptor`(:216)。另有 legacy API `getFilesUri`（`lib/src/storage_access_framework/api.dart:114`，**列目录**）、`persistedUriPermissions`(:151)、`DocumentFile.listFiles`（`document_file.dart:38`，Stream 形式）。
- **能否读取 zip 并解压**：能，且不必经 SAF——`pubspec.yaml:36` `archive: ^4.0.9`（lock 解析 4.0.9）纯 Dart Zip 解码；路径 A = `saf.readFileBytes/copyToLocalFile` 把 zip 取到本地临时文件 → `archive` 解压到临时目录 → 交 Rust 校验。路径 B（zip 大时更稳）= `openFileDescriptor('r')` + fd 流读，避免全量驻内存。
- **能否列目录**：能（`getFilesUri` / `DocumentFile.listFiles` / `Saf().child`）。
- 我方现用先例：`audio_screen.dart:987-1004`（Saf().writeFileBytes 写缓存）、`bookmark_export.dart:105` 起（Saf 写出）。

### 3.3 原版数据互操作范围与 bookUrl 不一致先例

- **不存在**「从原版导入」的 3.x 数据链：`import_old_data` 是 2.x 格式且 bookUrl 由字段映射生成（非原文保留），**不构成**「原版 bookUrl 一致性」先例。
- 最接近的互通先例是 **bookshelf.json 分享输出**（bookshelf_screen.dart:1076-1096，原版格式、bookUrl 原文）与 WebDAV 层的 bookshelf.json 传输（`rust/legado-net/src/webdav.rs:537-545`，格式由调用方定）。
- 含义：本任务的「bookUrl 不匹配 → 跳过+报告」将是**该类功能的第一个先例**，交互模式需要在本轮裁决后沉淀（见 G-2）。

---

## 任务 4 — 契约拟稿增补（§2.47 续）

### 4.1 「从备份文件导入原版音频缓存」是否需要新 FFI？

**需要，但最小 1 个新方法；纯 Dart/SAF 方案否决。** 理由：

1. **红线**：缓存键计算（`md5Encode16(chapterUrl.ifBlank{title})`）、书目录名（`book_{md5Encode16(bookUrl)}`）、五段式文件名正则、`.complete` 元数据（md5 自洽）校验都是**业务规则**，AGENTS.md「UI 层不含业务逻辑、数据经 Rust Bridge 获取」→ 必须在 Rust 层实现并被 FFI 消费。上一轮 F-9 已裁决「逐字节复刻」，单实现落 Rust 是唯一不漂移的形态（Rust 侧 md5Encode16 先例已两处，见 2.2）。
2. **可留 Dart 的部分**（不违反红线——纯文件搬运）：SAF 选文件/目录、zip 解压（`archive` 包）、把源目录拷到本地临时区、把校验通过的文件写入目标（Android SAF 写 / 桌面按裁决归 Rust）。「为什么这不违反红线」的边界判据：Dart 不做任何**键/名/有效性**的判断，只执行 Rust 给出的计划（目标文件名、是否导入均在 Rust 产出）。
3. **与上轮 §2.47 的关系**：上轮拟的 4 方法（audioCacheQuery/List/ClearChapter/ClearBook）覆盖查询/清理；导入复用其键与文件名实现，另加一个「扫描校验」入口即可，**不需要**把 md5Encode16 单独暴露给 Dart（避免增加暴露面）。

### 4.2 拟新增方法草案（与上轮 §2.47 合流为 N=5）

> | 方法 | 入参 | 返回 | 说明 |
> |------|------|------|------|
> | `audioCacheImportScan(String sourceDir)` | sourceDir：已解压到本地临时区的原版缓存根（内含 `LegadoAudioCache/` 或直接 `book_*` 层级均可识别） | `Future<String>` | **只读扫描校验**，返回 JSON 导入计划：`{"books":[{"bookDirName":"book_xxx","fileCount":n,"validCount":m,"files":[{"fileName":"00001_...mp3","key":"…","chapterIndex":1,"extension":"mp3","sizeBytes":123,"markerOk":true,"playUrl":"…","valid":true}]}],"skippedCount":k,"skippedReasons":["name-parse","no-marker",...]}`。逐文件判定 = 原版 parseFileName + 扩展名白名单 + `.complete` 存在与 md5 自洽；**不落盘、不改源**。Dart 据此执行搬运（Android SAF 写目标名；playUrl 字段供 Dart 决定标记照搬策略——默认照搬源标记） |

- 桌面通道可选增强（**方案乙，是否要请裁决 G-6**）：`audioCacheImportFromDir(sourceDir, bookUrl) → Future<String>` 由 Rust 直接落盘私有目录（两段式），免 Dart 中转。若采纳则 N=6。
- bookUrl 映射交互：`audioCacheImportScan` 返回的是 `bookDirName`（md5 形态），**不猜书**；UI 拿 `audioCacheList`/书架 bookUrl 现算比对（Dart 只比字符串，映射计算仍可全在 Rust——若采纳方案乙则映射在 Rust 内完成；方案甲下 Dart 需要算 `book_{md5_16(bookUrl)}` 吗？**不需要**：Dart 把书架 bookUrl 列表传给 Rust 比对，或 Scan 返回目录名后由 `audioCacheFileName` 类 FFI 反算——**这里留一个实现期决策**，避免 Dart 侧出现 md5 计算。干净的收口：`audioCacheImportScan` 增加**可选入参** `knownBookUrls: String`（JSON 数组），Rust 在计划里直接给出每个 bookDirName 匹配到的 bookUrl 或 `null`——零暴露、零 Dart 计算。**推荐此收口。**）

### 4.3 计数影响（承接上轮 C4 口径，现值以 docs/API_CONTRACT.md:176-177、:1026-1032 为准）

| 位置 | 现值 | 方案甲（+audioCacheImportScan，N=5，全封装 BookApi） | 方案乙（再 +audioCacheImportFromDir，N=6） |
|---|---|---|---|
| §2.47 节标题声明数 | 无（新节） | 5 | 6 |
| 总则模块数（:175） | 43 | 44 | 44 |
| BookApi 总数（:176） | 284 | **289** | **290** |
| 附录合计（:1026） | 287 | **292** | **293** |
| 同名口径（:1029） | 272 | **277** | **278** |
| 纯 FFI（:1031） | 2 | 2 不变 | 2 不变 |
| MockBookApi | — | 补 5 个假实现（否则 api_contract_test.dart BookApi⊆Mock 失败） | 补 6 个 |

- 若用户裁决导入走「纯 FFI 不封装 BookApi」（cbz 批 B 先例，docs/API_CONTRACT.md:11）：BookApi 284 不变，:1029-1031 登记「纯 FFI 2→3（或 4）」。
- **CI 提醒**：`flutter_legado/test/unit/api_contract_test.dart` 自动校验五件事（上轮 C0 已核：:152-168/:170-182/:184-200/:202-209/:211-263）——§2.47 节标题声明数、附录双射与合计、BookApi 程序计数、Mock 覆盖，**漏改任一处即 CI 失败**。
- 以上均为拟稿，**未写入 docs/API_CONTRACT.md**；冻结时点以实施批为准（契约先于代码）。

---

## 任务 5 — 风险与新增裁决点（G 系列，接上轮 F-1..F-10）

| # | 裁决点 | 推荐 | 理由 | 影响面 |
|---|---|---|---|---|
| G-1 | **导入范围交互**：全量静默导入，还是「扫描报告 → 用户勾选 → 执行」两段式？ | 两段式（先 audioCacheImportScan 出报告，用户按书勾选） | bookUrl 映射天然需要人确认（2.2 无自动保证）；避免一次导入把无法归属的目录静默丢弃 | 导入 UI、audioCacheImportScan 的分步使用方式 |
| G-2 | **bookUrl 不匹配处理**：跳过+报告 / 按书名标题模糊匹配 / 强制逐本人工配对？ | 跳过+报告；**不做标题模糊匹配**；「逐本人工配对」可作为 G-1 报告页的可选能力（用户手动指定某目录属于某书） | bookUrl 是 URL 语义，标题匹配易错绑（张冠李戴风险与上轮 D3 同源且不可事后校验）；人工配对成本可控 | 导入 UI 复杂度、audioCacheImportScan 入参（knownBookUrls） |
| G-3 | **导入落位布局**：原版布局原样落位（文件名/标记照搬），还是导入时重命名迁移成「我方新键」？ | 原样落位 | 我方新键**就是**原版键规则（用户裁决 6「支持原版备份规则」），不存在第二套键；重命名只会引入无意义的漂移风险；与裁决 3「不迁移」同口径 | 无（收敛项） |
| G-4 | **zip 编码容错口径**：GBK 条目乱码导致的解析失败，跳过+计数即可，还是要求支持 GBK 自动回退解码？ | 跳过+计数；不做 GBK 回退 | key/index/hash/rev 段全 ASCII，多数文件不受影响；`archive` 包不支持 GBK，自研解码器收益低；报告里用户可换工具重新打包（Windows 7-Zip 可强制 UTF-8） | 导入报告文案；无代码增量 |
| G-5 | **大文件导入的进度与取消**：首版按「逐书串行 + 每书完成回报」简化，还是复用 §2.43 任务表做完整进度/断点/取消？ | 首版简化（逐书回报）；任务表模式列后续增强 | 音频缓存单书体量通常 GB 级但导入只是本地搬运（无网络），耗时可控；任务表写入面会放大契约变更 | 契约（是否 +progress 方法）、导入 UI |
| G-6 | **桌面通道落盘归属**：桌面导入由 Rust 直写私有目录（+`audioCacheImportFromDir`，方案乙），还是统一 Dart 按 Scan 计划搬运（方案甲）？ | 方案乙（桌面 Rust 直写） | 与裁决 1「桌面走 Rust 私有目录」归属语义最一致；两段式落盘与既有 Rust 先例同构；方案甲会让 Dart 直写 Rust 属地目录，边界含糊 | §2.47 N=5 还是 6、计数（4.3 表） |
| G-7 | **反向「导出为备份文件」**：本期是否也做「把我方音频缓存导出成原版布局 zip」？ | 本期不做（仅导入） | 用户裁决 4 原文只要求「支持读取备份文件」；导出属未授权新功能风险（AGENTS.md 红线），确有需求另行授权 | 范围边界 |
| G-8 | **无标记/坏标记文件的处理细则**：无 `.complete` → 跳过（推荐）；`.complete` 存在但 md5 自洽失败 → 照原样导入还是也跳过？ | 照原样导入（原版行为=文件可播、playUrl 回退），报告中单列 | 与原版读取语义一致（AudioPlay.kt:400 回退 chapter.resourceUrl）；跳过会丢弃原版可播的数据 | audioCacheImportScan 的 markerOk 语义、导入报告 |

**新增风险提示（实施前必读，接上轮「最容易踩的坑」）**：

1. **zip 解压目标区容量**：音频缓存可能 GB 级，「先整体解压再扫描」会双倍占盘。缓解：Scan 支持直接扫**已解压目录**（G-1 报告阶段只读文件头/标记文件，数据文件校验 size 即可）；执行阶段逐文件搬运后即删临时副本。
2. **`.complete` 与数据文件的配对判定必须按「数据文件名 + `.complete` 后缀」精确匹配**（原版 AudioCacheManager.kt:284-288），不要按前缀/目录聚合——同名不同代的旧数据已被原版写入时清理，但用户手工整理过的目录可能出现孤儿标记。
3. **导入不触发徽标事件语义漂移**：原版预下载完成会发 `AUDIO_CACHE_CHANGED`（AudioCacheService.kt:220-225）；导入完成后我方目录徽标刷新应走同一条 UI 通知链（上轮任务 C 已把徽标数据源定为 §2.47 audioCacheList），不必新增事件 FFI。

---

## 附 A — `rust/legado-core/src/audio_cache.rs` 零调用核实（用户裁决 5 的删除前提）

**结论：零调用成立。** 证据：

1. 声明唯一：`rust/legado-core/src/lib.rs:26` `pub mod audio_cache;`（编译进 crate，但仅此一处出现模块名）。
2. 全 Rust 工作区 grep `AudioCache`（`--include="*.rs"`，覆盖 legado-core/legado-ffi/legado-server/legado-book/legado-db/legado-js/legado-net/legado-parser）：**唯一命中文件就是 `legado-core\src\audio_cache.rs` 自身**；`legado-ffi/`、`legado-server/` 等目录单独 grep 均 0 行。
3. Dart 侧：`lib/src/bridge`、`lib/src/rust`（FRB 生成物）grep `audio_cache|AudioCache` 零命中；全 `flutter_legado/lib` 命中仅为 pref 键字符串 `'audioCacheTreeUri'`（`lib/src/utils/audio_skip_policy.dart:18`、`lib/src/screens/audio_screen.dart:916,976`），与该模块无关。
4. 该模块 537 行、公开面 `AudioCacheEntry/AudioCachePolicy/AudioCacheStatus/CacheDownloadItem/AudioCacheManager`（audio_cache.rs:11-201），无任何外部消费者；删除仅需同步移除 `lib.rs:26` 声明（动作由实施代理执行，本轮不动）。

## 附 B — kazusa 参考版源码定位结果

**未找到 kazusa（`io.legato.kazusa`）本源源码。** 本轮搜索路径（均无 kazusa 命名命中）：

- `D:\OH-WorkSpace\Projects`（发现 `legado_flutter`——**另一个**基于 Jingshiro/legado 的独立重构项目，非 kazusa；其 `reference/Jingshiro-legado` 是 Jingshiro 分叉源码，applicationId `io.legado.app`）
- `D:\` 根目录枚举、`D:\Downloads`、`D:\OH-WorkSpace` 全树 `find -iname "*kazusa*"`（maxdepth 3）零命中
- 本仓文档内 grep：kazusa 仅以「实机 APK 3.26.15 基准」出现（docs/REFACTORING_ACTIVE_PLAN.md:558,585,602）

**新定位（对本任务有价值）**：`D:\OH-WorkSpace\LegadoTeam\legado-with-MD3` = HapeLee/legado-with-MD3 的本地克隆（git HEAD `488a375`，与 docs/REFACTORING_ACTIVE_PLAN.md:602 所载「本地 legado-with-MD3 源码快照（09-28，488a375）」一致）——即参考版系的本地源码快照。**其内无音频缓存模块**（`find .../audio` 仅有 Compose 版 AudioPlay* UI；grep `AudioCacheManager|LegadoAudioCache|audioCacheTreeUri` 零命中）→ **参考版系没有音频缓存功能**，本任务（含备份/恢复）的对齐基准只能是 Android 原版（gedoor/legado），不存在「参考版备份机制」可供核对。

## 附 C — 证据文件清单（绝对路径）

原版基线：
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\storage\Backup.kt`（:52-98 清单、:122-131 zip 名、:268-345 写入、:347-389 prefs 快照、:391-439 打包与分发、:419-430 目的地）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\storage\Restore.kt`（:149-164 入口、:193-206 解压、:221-568 逐项恢复、:452-513 prefs 回写、:540-552 媒体恢复）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\storage\BackupConfig.kt`（:30-42 分组 key、:101-116 忽略清单、:166-178 keyIsNotIgnore）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\storage\BackupMedia.kt`（:6 目录白名单、:106-172 原子恢复）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\ui\config\BackupConfigFragment.kt`（:99-110 备份目录、:102-110 恢复入口、:588-596 restoreFromLocal zip 选择）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\ui\file\HandleFileContract.kt`（:18 自建文件选择器）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\utils\compress\ZipUtils.kt`（:101-113 zipFiles、:171-203 条目名拼接、:242-263 解压）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\utils\compress\ArchivePathUtils.kt`（:10-22 zip-slip 防护）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\utils\MD5Utils.kt`（:21-33）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\audio\AudioCacheManager.kt`（:41 目录常量、:61-74 查找、:77-82 listKeys、:201-203 最新优先、:205-212/:223-230 书目录、:266-295 标记读写、:358-373 有效性）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\audio\AudioCachePolicy.kt`（:11-13 正则、:15-18 白名单、:67-98 文件名、:100-110 解析、:137-153 标记元数据）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\model\AudioCacheKey.kt`（:8-10 校验、:18-27 生成/parse）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\model\AudioPlay.kt`（:379-413 播放查缓存）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\service\AudioCacheService.kt`（:205-234 预下载循环，:217 唯一写调用）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\ui\book\cache\CacheActivity.kt`（:76-90 文字书导出，非音频）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\help\config\AppConfig.kt`（:728-735 audioCacheTreeUri）
- `D:\OH-WorkSpace\LegadoTeam\legado\app\src\main\java\io\legado\app\constant\PreferKey.kt`（:215 audioCacheTreeUri）

我方现状：
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\pubspec.yaml`（:14 file_picker、:35 saf、:36 archive）；`pubspec.lock`（saf 2.1.0 / archive 4.0.9 / file_picker 8.3.7）
- `C:\Users\admin\AppData\Local\Pub\Cache\hosted\pub.dev\saf-2.1.0\lib\src\v2\saf.dart`（:32-217 API 面）、`lib\src\storage_access_framework\api.dart`（:114 列目录、:151 授权列表）、`document_file.dart`（:38 listFiles）
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\screens\webdav_settings_screen.dart`（:37-44、:157-193、:196-241、:259-269 备份/恢复/旧版导入 UI）
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\services\backup_service.dart`（自有 JSON 备份服务）
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\screens\archive_import_dialog.dart`（zip 导入先例）
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\screens\bookshelf_screen.dart`（:1076-1096 原版 bookshelf.json 输出）
- `D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\screens\audio_screen.dart`（:996 孤儿键写）
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\backup_api.rs`（:22-48 自有格式、:152-157 仅 JSON、:296-374 import_old_data 2.x）
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\ffi.rs`（:2056-2073）
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-ffi\src\api\image_cache_api.rs`（:148-151 md5Encode16 对齐先例）
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-js\src\host_api\encoding.rs`（:36-39 md5_encode_16）
- `D:\OH-WorkSpace\LegadoTeam\legado\rust\legado-core\src\audio_cache.rs`（孤儿模块，537 行）与 `rust\legado-core\src\lib.rs:26`
- `D:\OH-WorkSpace\LegadoTeam\legado\docs\API_CONTRACT.md`（:11 cbz 先例、:175-177 计数、:620 cbzReadPage 行、:1026-1032 附录口径）
- `D:\OH-WorkSpace\LegadoTeam\legado\docs\B1_AUDIO_CACHE_DATA_SURVEY_20261003.md`（上轮报告：任务 C/D/E/F）
- `D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`（HapeLee 快照，无音频缓存模块）

（编写者：调研员（子代理）｜ 2026-10-03）
