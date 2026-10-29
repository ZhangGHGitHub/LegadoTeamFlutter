//! 书架管理 API
//!
//! 提供书籍的增删改查操作，通过 BookRepository 访问数据库。

use std::path::{Component, Path, PathBuf};

use legado_core::models::{book_type, Book};
use legado_core::{LegadoError, LegadoResult};
use legado_db::import::RoomImporter;
use legado_db::repository::Repository;
use legado_db::BookRepository;

use crate::db_state::{documents_root, resolve_local_book_path, with_database};

/// 获取书架上所有书籍
pub fn list_books() -> LegadoResult<Vec<Book>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        // Task#125 P0：仅返回已入书架的书，过滤 notShelf 临时书（搜索/发现打开的在线书）
        repo.find_all_in_shelf()
    })
}

/// [B-2 | P2-8 写侧防守 | 2026-09-18 审查 P1-1] 书源字段防陈旧快照回写合并：
/// `origin` / `originName` / `tocUrl` / `originBookUrl` 四列语义唯一——只由
/// 换源事务（source_switch.rs）与 preUpdateJs 钩子（reader.rs）写入，书架侧
/// **不存在合法的清空/改源场景**（改源走 `switch_book_source` API）。
/// Dart 侧持有的 Book 是陈旧内存快照（目录页/详情页 `_book` 对象不随换源
/// 更新），全行回写会把换源结果（origin/tocUrl/originBookUrl=新源）打回旧源，
/// 形成「origin=旧源 + 目录=新源章节」的不一致态，按旧源取正文必然失败。
///
/// 合并规则（书籍已存在时）：库内既有值非空 → 既有值优先（入参忽略）；
/// 既有值为空 → 用入参补齐（含 [P2-8 P1-1] 的 originBookUrl 入参为空补齐
/// 场景）。新建路径（无既有行）按入参原样落库。
/// `variable`/`customTag` 等**不参与**合并——用户可合法清空/修改，保持
/// 全行写入语义（入参为准）。
///
/// [批18c 设备复验 | 2026-10-27] origin 的例外：远程书库导入先把文件导入为
/// 本地书（`loc_book`），再用 `update_book` 改写为 `webDav::<url>`。这是
/// 「存储位置」变化而非换源，若沿用「既有非空即优先」会被打回 `loc_book`，
/// 导致远程书 origin 丢失。故入参为 WebDAV origin 且库内为本地/WebDAV
/// origin 时，允许入参覆盖；在线书源（http(s)）仍按 B-2 防回退。
fn merge_source_fields(repo: &BookRepository<'_>, book: &mut Book) -> LegadoResult<()> {
    use legado_core::models::book_type;

    let Ok(Some(existing)) = repo.find_by_url(&book.book_url) else {
        return Ok(());
    };
    let incoming_is_webdav = book_type::is_web_dav_origin(book.origin.trim());
    let existing_is_storage = existing.origin.trim() == book_type::LOCAL_TAG
        || book_type::is_web_dav_origin(existing.origin.trim());
    let allow_webdav_rewrite = incoming_is_webdav && existing_is_storage;
    if !existing.origin.trim().is_empty() && !allow_webdav_rewrite {
        book.origin = existing.origin;
    }
    if !existing.origin_name.trim().is_empty() {
        book.origin_name = existing.origin_name;
    }
    if !existing.toc_url.trim().is_empty() {
        book.toc_url = existing.toc_url;
    }
    if !existing.origin_book_url.trim().is_empty() {
        book.origin_book_url = existing.origin_book_url;
    }
    Ok(())
}

/// [批35b P2-2] 整书快照写的「用户可见开关」缺键合并：
///
/// `repo.update` 是全行 UPDATE（`disableReadRecord` 列参与 SET），整书
/// 载荷缺该键时 `#[serde(default)]` 会补成 `false`，把库内已置真的开关
/// 打回假。规则与 [`merge_source_fields`] 不同——这里**只认缺键**：
/// - 载荷显式携带 `disableReadRecord`（含 `false`）→ 以入参为准（用户
///   主动开启/关闭，或备份恢复的完整快照）；
/// - 载荷缺键或为 `null` → 保留库内既有值（新建路径按 `false` 落库）。
///
/// 扩展点：后续其它「用户可见开关」若加入整书快照载荷且存在陈旧的
/// Dart 快照回写风险，同样加入本函数的保留名单。
fn merge_missing_user_switches(
    repo: &BookRepository<'_>,
    book: &mut Book,
    disable_read_record_present: bool,
) -> LegadoResult<()> {
    if disable_read_record_present {
        return Ok(());
    }
    let Ok(Some(existing)) = repo.find_by_url(&book.book_url) else {
        return Ok(()); // 新建（或查询失败时保持入参默认值）
    };
    book.disable_read_record = existing.disable_read_record;
    Ok(())
}

/// 解析整书 JSON，并返回 `disableReadRecord` 键是否「显式携带」
///
/// `null` 视同缺键（便于 `Option` 语义的调用方），随后移除该键，避免
/// `bool` 反序列化因 `null` 失败。
fn parse_book_json_for_update(book_json: &str) -> LegadoResult<(Book, bool)> {
    let mut value: serde_json::Value = serde_json::from_str(book_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("Book JSON 解析失败: {e}")))?;
    let present = !matches!(
        value.get("disableReadRecord"),
        None | Some(serde_json::Value::Null)
    );
    if let Some(obj) = value.as_object_mut().filter(|_| !present) {
        // `null` 视同缺键：移除后按 bool 默认 false 反序列化，
        // 缺键语义由调用方的 merge_missing_user_switches 兜底
        obj.remove("disableReadRecord");
    }
    let book: Book = serde_json::from_value(value)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("Book JSON 解析失败: {e}")))?;
    Ok((book, present))
}

pub fn add_book(book_json: &str) -> LegadoResult<Book> {
    let (mut book, disable_read_record_present) = parse_book_json_for_update(book_json)?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        // Task#125 P0：用原地 UPDATE 语义的 upsert，避免对已存在的临时书
        // 触发 INSERT OR REPLACE 级联删除其章节目录（转正/重复加入书架时安全）
        merge_source_fields(&repo, &mut book)?; // [B-2 / P2-8 P1-1] 书源字段防回退
                                                // [批35b P2-2] 缺键时保留库内书级阅读记录开关（重复加入书架不回退）
        merge_missing_user_switches(&repo, &mut book, disable_read_record_present)?;
        repo.update(&book)?;
        Ok(book)
    })
}

/// 更新书籍信息（JSON 序列化传入）
pub fn update_book(book_json: &str) -> LegadoResult<()> {
    let (mut book, disable_read_record_present) = parse_book_json_for_update(book_json)?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        merge_source_fields(&repo, &mut book)?; // [B-2] 陈旧快照不得撤销换源结果
                                                // [批35b P2-2] 缺键时保留库内开关：整书全行写不得把 true 覆盖为 false
        merge_missing_user_switches(&repo, &mut book, disable_read_record_present)?;
        repo.update(&book)
    })
}

/// 单键更新书籍 `readConfig` JSON 中的指定键（契约 §2.2 `updateReadConfigField`）
///
/// [批32] 背景：`update_book` 是整书快照写，Dart `ReadConfig` 未建模的键
/// （`useGlobalAudioSkip` / `tocExpanded` / `manualReplaceRuleIds` 等）在
/// 「Dart → Rust 类型化模型 → 全行回写」往返中被丢弃——目录页每切一次
/// 「反转」就会把这些键清空。本方法在 DB 侧只合并目标键，其余键（含未建模
/// 键）原样保留，且不触碰其他列与进度列。
///
/// `value_json` 是**值本身**的 JSON 编码串（bool/string/number/对象/数组），
/// 直接经 `serde_json::Value` 合并进现有 readConfig 对象；`key` 为空白、
/// JSON 非法、书籍不存在一律报错（fail-closed，不静默成功）。
pub fn update_read_config_field(book_url: &str, key: &str, value_json: &str) -> LegadoResult<()> {
    let key = key.trim();
    if key.is_empty() {
        return Err(legado_core::LegadoError::Ffi(
            "readConfig 键名不能为空".to_string(),
        ));
    }
    let value: serde_json::Value = serde_json::from_str(value_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("readConfig 值 JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        if repo.find_by_url(book_url)?.is_none() {
            return Err(legado_core::LegadoError::Internal(format!(
                "书籍不存在: {book_url}"
            )));
        }
        repo.update_read_config_field(book_url, key, &value)
    })
}

/// 按 bookUrl 删除书籍
pub fn delete_book(book_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.delete_by_url(book_url)
    })
}

/// 可删除的本地书籍/媒体文件扩展名白名单（批35，路径安全 fail-safe）
///
/// 删除原文件是破坏性操作，而 `books.bookUrl` 来自 DB（可能被损坏的导入/
/// 手改数据污染）。只允许删除**明确属于书籍或本地媒体**的扩展名；其他路径
/// 一律跳过并提示，绝不把任意路径交给 `remove_file`。
const DELETABLE_LOCAL_FILE_EXTS: &[&str] = &[
    // 电子书
    "txt", "text", "epub", "mobi", "azw", "azw3", "pdf", "umd", "cbz",
    "zip", // 本地音频/视频书
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "mp4", "mkv", "webm", "avi", "mov", "3gp",
    "flv", "ts",
];

/// 是否为本地/WebDAV 存储书（批35，删除原文件的准入判断）
///
/// 对齐 Dart `BookType.isLocalBook` 的双分支：`type == 0` 按 origin
/// （`loc_book` / `webDav::` / 存量 `dav:`）判定；否则看 local 位
/// （Rust 域 0x1000 与原版 Kotlin 0x100 双标准）。
fn is_local_storage_book(book: &Book) -> bool {
    let origin = book.origin.trim();
    if book.book_type == 0 {
        return origin == book_type::LOCAL_TAG || book_type::is_web_dav_origin(origin);
    }
    book_type::is_local_type(book.book_type)
        || origin == book_type::LOCAL_TAG
        || book_type::is_web_dav_origin(origin)
}

/// 删除本地源文件的信任边界根（[批35b P2-1]）
///
/// `bookUrl` 来自 DB（可能被损坏的导入/手改数据污染），绝对路径与相对
/// 标识都不能无条件交给 `remove_file`。合法来源只有两处：
/// - 应用 `Documents` 根（= DB 文件父目录）：本地书导入副本 `Documents/books/`
///   与压缩包导入 `<Documents>/archive_import/` 都在其下；
/// - 应用 `Cache`/`tmp` 根：WebDAV 远程书导入的临时落盘（Dart
///   `Directory.systemTemp/legado_remote_books/<hash>/<file>`）；Rust 侧
///   `std::env::temp_dir()` 与 Dart 的 `Directory.systemTemp` 同源。
///
/// DB 未初始化（无法确定 Documents 根）时只保留 Cache 根；两者都取不到时
/// 返回空表，调用方一律拒绝删除（fail-closed）。
fn trusted_file_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(docs) = documents_root() {
        roots.push(docs);
    }
    roots.push(std::env::temp_dir());
    roots.sort();
    roots.dedup();
    roots
}

/// 根路径规范化：根可能尚不存在（相对比较）或不含连接，`canonicalize`
/// 失败时退回原样（仅用于前缀比较，不参与删除）
fn canonical_root(root: &Path) -> PathBuf {
    std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf())
}

/// 校验一个待删除的本地文件路径，返回可交给 `remove_file` 的规范路径
///
/// 校验顺序（任一失败即拒绝，调用方把原因拼进中文提示）：
/// 1. 空值 / 含 `://`（Web URL）→ 拒绝；
/// 2. **相对可迁移标识**：拒绝 `..` 组件（`books/../outside.txt` 可借
///    路径归一逃出 Documents，仅靠 canonical 后的根检查拦不住）→ 以
///    Documents 根拼接后进入第 3 步；
/// 3. `symlink_metadata`：不存在 → 提示；**符号链接 → 拒绝**（canonical
///    会跟随链接，删的是链接目标）；
/// 4. `canonicalize` 后必须在 [`trusted_file_roots`] 任一规范根内
///    （拦住「祖先目录是符号链接」「绝对路径指向任意目录」两类越界）；
/// 5. 必须是普通文件（目录/FIFO/设备文件一律拒绝）；
/// 6. 扩展名必须在 [`DELETABLE_LOCAL_FILE_EXTS`] 白名单。
fn validate_local_file_path(raw: &str, roots: &[PathBuf]) -> Result<PathBuf, String> {
    if raw.is_empty() || raw.contains("://") {
        return Err("原文件地址不是本地路径，已跳过文件删除".to_string());
    }
    let raw_path = Path::new(raw);
    let resolved = if raw_path.is_absolute() {
        raw_path.to_path_buf()
    } else {
        if raw_path
            .components()
            .any(|c| matches!(c, Component::ParentDir))
        {
            return Err("原文件地址包含上级目录（..），已跳过文件删除".to_string());
        }
        PathBuf::from(resolve_local_book_path(raw))
    };
    match std::fs::symlink_metadata(&resolved) {
        Ok(meta) if meta.file_type().is_symlink() => {
            return Err("原文件是符号链接，已跳过文件删除".to_string());
        }
        Ok(_) => {}
        Err(e) => return Err(format!("原文件不存在或不可访问（{e}），已跳过文件删除")),
    }
    let canonical = std::fs::canonicalize(&resolved)
        .map_err(|e| format!("原文件不存在或不可访问（{e}），已跳过文件删除"))?;
    if !roots
        .iter()
        .any(|root| canonical.starts_with(canonical_root(root)))
    {
        return Err("原文件不在应用 Documents/Cache 目录内，已跳过文件删除".to_string());
    }
    if !canonical.is_file() {
        return Err("原文件不是普通文件，已跳过文件删除".to_string());
    }
    let ext = canonical
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    if !DELETABLE_LOCAL_FILE_EXTS.contains(&ext.as_str()) {
        return Err(format!(
            "文件类型 .{} 不在可删除白名单，已跳过文件删除",
            if ext.is_empty() {
                "(无)"
            } else {
                ext.as_str()
            }
        ));
    }
    Ok(canonical)
}

/// 删除本地/WebDAV 书的原文件（批35，[批35b P2-1] 信任边界收敛）
///
/// - 非本地书：直接返回 `Ok(())`（非本地书不删任何文件）；
/// - 本地书：经 [`validate_local_file_path`] 做「相对标识 `..` 拒绝、
///   Documents/Cache 根内、非符号链接、普通文件、扩展名白名单」全套校验；
/// - 失败语义：返回中文提示字符串，**调用方继续删除书籍记录**（对齐任务
///   「失败不阻断删除记录并提示」，也贴近参考版 `runCatching` 不中断删除）。
fn delete_local_book_file(book: &Book, roots: &[PathBuf]) -> Result<(), String> {
    if !is_local_storage_book(book) {
        return Ok(());
    }
    let raw = book.book_url.trim();
    let canonical = validate_local_file_path(raw, roots)
        .map_err(|reason| format!("《{}》{reason}", book.name))?;
    std::fs::remove_file(&canonical).map_err(|e| format!("《{}》原文件删除失败：{e}", book.name))
}

/// 批量删除的计数结果（[批35b P3-5]，供 UI 使用实际删除数而非选中数）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DeleteBooksOutcome {
    /// 实际删除的书籍记录数（删除前在库中存在）
    pub deleted: usize,
    /// 请求删除但库中已不存在的数量（并发删除/重复请求）
    pub missing: usize,
    /// 文件删除失败提示（中文逐条；成功为空）
    pub warnings: Vec<String>,
}

/// 批量删除书架书籍，可选同时删除本地/WebDAV 原文件（批35，[批35b P3-2]）
///
/// 对齐参考版 `DeleteBooksUseCase.execute(bookUrls, deleteOriginal)`：
/// 分三阶段，文件 IO 不持有 DB 连接（[批35b P3-2] 审查：此前在
/// `with_database` 闭包内逐本查库 + 删文件，慢磁盘 IO 长期占用池连接）：
/// 1. **短连接查库**：逐本 `find_by_url` 收集待删记录，闭包立即归还连接；
/// 2. **文件删除**：仅本地/WebDAV 书，失败只收集中文提示、**不阻断**记录删除；
/// 3. **单事务删记录**：`in_transaction` 内逐本 `delete_by_url`（章节经外键
///    级联清理），任一条失败整体回滚，不出现「删一半」的部分成功态。
///
/// 返回 [`DeleteBooksOutcome`]：实际删除数、已不在库中的数量与文件删除提示。
pub fn delete_books(
    book_urls: &[String],
    delete_original: bool,
) -> LegadoResult<DeleteBooksOutcome> {
    let urls: Vec<String> = book_urls
        .iter()
        .map(|u| u.trim().to_string())
        .filter(|u| !u.is_empty())
        .collect();
    let mut outcome = DeleteBooksOutcome::default();
    if urls.is_empty() {
        return Ok(outcome);
    }
    let roots = trusted_file_roots();

    // 阶段1：短连接查库（不在此闭包内做任何文件 IO）
    let targets = with_database(|db| {
        let repo = BookRepository::new(db.connection());
        let mut targets = Vec::with_capacity(urls.len());
        for url in &urls {
            targets.push((url.clone(), repo.find_by_url(url)?));
        }
        Ok(targets)
    })?;

    // 阶段2：文件 IO（DB 连接已归还连接池）
    let mut existing_urls = Vec::with_capacity(targets.len());
    for (url, book) in targets {
        let Some(book) = book else {
            // 书籍不存在（可能已被并发删除）不阻断其余删除
            outcome.missing += 1;
            continue;
        };
        if delete_original {
            if let Err(message) = delete_local_book_file(&book, &roots) {
                outcome.warnings.push(message);
            }
        }
        existing_urls.push(url);
    }

    // 阶段3：单事务删记录（失败整体回滚，避免部分删除）
    let deleted = with_database(|db| {
        legado_db::connection::in_transaction(db.connection(), "批量删除书籍", |conn| {
            let repo = BookRepository::new(conn);
            for url in &existing_urls {
                repo.delete_by_url(url)?;
            }
            Ok(existing_urls.len())
        })
    })?;
    outcome.deleted = deleted;
    Ok(outcome)
}

/// 书籍级阅读记录开关（批35）
///
/// 对齐参考版 `BookInfoViewModel.toggleReadRecordDisabled`：单列 UPDATE
/// （不整书回写，防陈旧快照覆盖进度），成功返回更新后的整书；书籍不存在
/// 报错（fail-closed，UI 可提示而不是假装成功）。
pub fn set_read_record_disabled(book_url: &str, disabled: bool) -> LegadoResult<Book> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.set_read_record_disabled(book_url, disabled)?
            .ok_or_else(|| LegadoError::Internal(format!("书籍不存在: {book_url}")))
    })
}

/// 按 bookUrl 获取单本书籍详情
pub fn get_book(book_url: &str) -> LegadoResult<Option<Book>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.find_by_url(book_url)
    })
}

/// 批量导入书籍（JSON 数组）
///
/// `json_array` 中每个元素为一本书的 JSON 对象，返回成功导入的数量。
pub fn import_books(json_array: &str) -> LegadoResult<i32> {
    with_database(|db| {
        let count = RoomImporter::import_books(db.connection(), json_array)?;
        Ok(count as i32)
    })
}

/// 更新阅读进度
///
/// [B-8] 换源/刷新目录的写事务持锁期间，进度写入会等满 busy_timeout(5s)
/// 后以 `database is locked` 失败，Dart 侧 `_saveProgress` 用 `catch (_) {}`
/// 吞掉 → 进度静默丢失。Rust 侧加短重试：锁类错误（消息含 locked/busy）
/// 最多 3 次尝试、200/400ms 退避；非锁错误（书籍不存在等）立即返回。
/// FFI 同步函数运行在工作线程，`std::thread::sleep` 不阻塞 Dart 主 isolate。
///
/// [B-9] chapter_index 越界时按既有目录范围收敛（目录为空只保证非负）；
/// 章节查不到时不保留旧标题（写 NULL）。
pub fn update_reading_progress(
    book_url: &str,
    chapter_index: i32,
    chapter_pos: i32,
) -> LegadoResult<()> {
    const MAX_ATTEMPTS: u32 = 3;
    let mut attempt: u32 = 0;
    loop {
        attempt += 1;
        match write_reading_progress_once(book_url, chapter_index, chapter_pos) {
            Ok(()) => return Ok(()),
            Err(e) => {
                let msg = e.to_string().to_lowercase();
                let lock_error = msg.contains("locked") || msg.contains("busy");
                if !lock_error || attempt >= MAX_ATTEMPTS {
                    return Err(e);
                }
                // [B-8] 退避 200ms / 400ms：等换源事务的写锁释放
                std::thread::sleep(std::time::Duration::from_millis(200 * attempt as u64));
            }
        }
    }
}

/// 进度写入单次执行（一次 DB 访问 + 单条字段级 UPDATE）
fn write_reading_progress_once(
    book_url: &str,
    chapter_index: i32,
    chapter_pos: i32,
) -> LegadoResult<()> {
    with_database(|db| {
        let conn = db.connection();
        let repo = BookRepository::new(conn);
        // 书籍必须存在：进度不写入不存在的书（对齐原实现「书籍不存在」错误）
        if repo.find_by_url(book_url)?.is_none() {
            return Err(legado_core::LegadoError::Database("书籍不存在".into()));
        }
        // [B-9] 越界保护：按既有目录收敛（目录为空时不收敛，仅保证非负）
        let chapter_repo = legado_db::BookChapterRepository::new(conn);
        let count = chapter_repo.count_by_book_url(book_url)?;
        let (clamped_index, chapter_title) = if count > 0 {
            let upper = (count - 1).min(i32::MAX as i64) as i32;
            let idx = chapter_index.clamp(0, upper);
            let title = chapter_repo
                .find_by_book_url_and_index(book_url, idx)?
                .map(|ch| ch.title);
            (idx, title)
        } else {
            (chapter_index.max(0), None)
        };
        let chapter_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        // [B-3] 进度只走字段级 update_progress，不整行写（其他列不受影响）
        repo.update_progress(
            book_url,
            clamped_index,
            chapter_pos,
            chapter_title.as_deref(),
            chapter_time,
        )
    })
}

/// 批量持久化书架排序（JSON 数组：`[{"bookUrl":"...", "order":1}, ...]`）
///
/// 对齐原版 `BookAdapter.swap` 结束后 `updateBook(*getItems())` 的 order 写回语义。
pub fn reorder_books(orders_json: &str) -> LegadoResult<()> {
    #[derive(serde::Deserialize)]
    struct BookOrderItem {
        #[serde(rename = "bookUrl")]
        book_url: String,
        order: i32,
    }
    let items: Vec<BookOrderItem> = serde_json::from_str(orders_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("排序 JSON 解析失败: {e}")))?;
    let orders: Vec<(String, i32)> = items.into_iter().map(|i| (i.book_url, i.order)).collect();
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.update_orders(&orders)
    })
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use crate::db_state::with_database;
    use legado_core::models::{book_type, Book, ReadConfig};
    use legado_db::repository::Repository;
    use legado_db::BookRepository;

    /// [漫画设置作用域 2026-10-01] `update_book`（Dart `updateBook` 的 FFI 入口）
    /// 全行回写必须保留 readConfig 书级字段 `mangaScrollMode` /
    /// `webtoonSidePaddingDp`（此前 Rust 类型化 ReadConfig 不含该键，会被
    /// serde 静默丢弃），且进度列按既有语义不被陈旧快照回滚。
    #[test]
    fn test_update_book_preserves_manga_scope_read_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://manga-scope-ffi.example.com/book/1";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "书名".to_string(),
                author: "作者".to_string(),
                read_config: Some(ReadConfig {
                    reverse_toc: true,
                    daily_chapters: 7,
                    manga_scroll_mode: Some(2),
                    webtoon_side_padding_dp: Some(20),
                    ..ReadConfig::default()
                }),
                ..Book::default()
            })?;
            repo.update_progress(book_url, 5, 9, Some("第五章"), 1_700_000_000_000)?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // Dart 侧 updateBook 载荷形态：书级字段更新 + 故意携带陈旧进度快照
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "改名",
            "author": "作者",
            "type": 0,
            "durChapterIndex": 0,
            "durChapterPos": 0,
            "readConfig": {
                "reverseToc": true,
                "dailyChapters": 7,
                "mangaScrollMode": 3,
                "webtoonSidePaddingDp": 45
            }
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let saved = repo.find_by_url(book_url)?.expect("书籍记录应仍存在");
            assert_eq!(saved.name, "改名");
            let rc = saved.read_config.expect("readConfig 应保留");
            assert_eq!(rc.manga_scroll_mode, Some(3), "书级翻页模式不得被静默丢弃");
            assert_eq!(
                rc.webtoon_side_padding_dp,
                Some(45),
                "书级侧边留白不得被静默丢弃"
            );
            assert!(rc.reverse_toc);
            assert_eq!(rc.daily_chapters, 7);
            // 进度列不回滚（唯一常规写入口仍是 update_progress）
            assert_eq!(saved.dur_chapter_index, 5);
            assert_eq!(saved.dur_chapter_pos, 9);
            assert_eq!(saved.dur_chapter_title.as_deref(), Some("第五章"));
            Ok(())
        })
        .expect("DB 终态断言失败");

        // 收尾清理（共享测试库不留固定行）
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18c 设备复验] 远程书库导入：本地书 `loc_book` → `webDav::` origin
    /// 必须生效（旧实现被 B-2 防回退合并打回 `loc_book`，设备上导入后
    /// `books.origin` 仍是 `loc_book`，远程页无法显示「已在书架」）。
    #[test]
    fn test_update_book_allows_local_to_webdav_origin() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18c-remote-import.example.com/tmp/txt-sample.txt";
        let webdav_origin = "webDav::http://192.168.100.52:18081/dav/books/txt-sample.txt,{\"serverID\":1793070940707}";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "txt-sample".to_string(),
                origin: "loc_book".to_string(),
                origin_name: "txt-sample.txt".to_string(),
                ..Book::default()
            })
        })
        .expect("本地书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "txt-sample",
            "origin": webdav_origin,
            "originName": "txt-sample.txt",
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, webdav_origin,
                "远程书库导入必须能把 loc_book 改写为 webDav:: origin"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// B-2 回归：在线书源（http）的 origin 仍按「库内既有值优先」，
    /// 陈旧快照不得撤销换源结果（批18c 放宽仅限本地/WebDAV 存储 origin）。
    #[test]
    fn test_update_book_keeps_online_origin_against_stale_snapshot() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18c-stale-snapshot.example.com/book/1";
        let new_origin = "https://batch18c-new-source.example.com";
        let old_origin = "https://batch18c-old-source.example.com";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "书名".to_string(),
                origin: new_origin.to_string(),
                ..Book::default()
            })
        })
        .expect("换源后状态入库失败");

        let stale_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "书名",
            "origin": old_origin,
            "type": 0
        })
        .to_string();
        super::update_book(&stale_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, new_origin,
                "在线书源换源结果不得被陈旧快照撤销"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18d P3] 存储 origin 的合并分支：库内为 `webDav::`、入参也是
    /// `webDav::` 时允许入参覆盖（后写胜）。注意该分支的已知语义：Dart 若持有
    /// 陈旧快照（旧 URL），可能把更新的远程 URL 回退为旧值——这是「存储位置
    /// 变化」场景下为支持 loc_book → webDav 改写而接受的取舍；换源（http）
    /// 仍由 B-2 防回退保护。
    #[test]
    fn test_merge_origin_webdav_to_webdav_later_write_wins() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18d-webdav-rewrite.example.com/tmp/a.txt";
        let existing_origin = "webDav::http://dav.example.com/books/old.txt";
        let incoming_origin = "webDav::http://dav.example.com/books/new.txt";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "远程书".to_string(),
                origin: existing_origin.to_string(),
                ..Book::default()
            })
        })
        .expect("既有 webDav 书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "远程书",
            "origin": incoming_origin,
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, incoming_origin,
                "webDav→webDav 属存储位置变更，允许入参覆盖（后写胜）"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18d P3] 入参为本地 origin、库内为 `webDav::` 时不得回退：
    /// 远程书导入后的陈旧快照（loc_book）不能覆盖已写入的 webDav origin。
    #[test]
    fn test_merge_origin_webdav_kept_against_local_incoming() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18d-webdav-keep.example.com/tmp/b.txt";
        let existing_origin = "webDav::http://dav.example.com/books/b.txt";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "远程书".to_string(),
                origin: existing_origin.to_string(),
                ..Book::default()
            })
        })
        .expect("既有 webDav 书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "远程书",
            "origin": legado_core::models::book_type::LOCAL_TAG,
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, existing_origin,
                "入参为本地 origin 时不得覆盖库内 webDav origin"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// [批18d P3] 库内 origin 为空时用入参补齐（空值不视为有效既有值）。
    #[test]
    fn test_merge_origin_empty_existing_uses_incoming() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch18d-empty-origin.example.com/book/1";
        let incoming_origin = "https://batch18d-source.example.com";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "空 origin 书".to_string(),
                origin: String::new(),
                ..Book::default()
            })
        })
        .expect("空 origin 书入库失败");

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "空 origin 书",
            "origin": incoming_origin,
            "type": 0
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin, incoming_origin,
                "库内 origin 为空时应采用入参补齐"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    // ─── 批32：readConfig 单键写（契约 §2.2 updateReadConfigField）──────────

    /// 造一本 readConfig 直接写**原始 JSON** 的书（绕过类型化模型，
    /// 可写入 Dart/Rust 均未建模的键）
    fn seed_read_config_raw(book_url: &str, raw_json: Option<&str>) {
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: "单键写测试书".to_string(),
                origin: "https://batch32.example.com".to_string(),
                ..Book::default()
            })?;
            if let Some(raw) = raw_json {
                db.connection()
                    .execute(
                        "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                        rusqlite::params![raw, book_url],
                    )
                    .map_err(|e| {
                        legado_core::LegadoError::Database(format!("写原始 readConfig 失败: {e}"))
                    })?;
            }
            Ok(())
        })
        .expect("原始 readConfig 入库失败");
    }

    /// 读回 readConfig 原始 JSON（用于断言未建模键保留）
    fn raw_read_config(book_url: &str) -> serde_json::Value {
        with_database(|db| {
            let raw: Option<String> = db
                .connection()
                .query_row(
                    "SELECT readConfig FROM books WHERE bookUrl = ?1",
                    rusqlite::params![book_url],
                    |row| row.get(0),
                )
                .map_err(|e| {
                    legado_core::LegadoError::Database(format!("查询 readConfig 失败: {e}"))
                })?;
            Ok(
                serde_json::from_str(&raw.unwrap_or_else(|| "{}".to_string()))
                    .expect("readConfig 应为合法 JSON"),
            )
        })
        .expect("读取 readConfig 失败")
    }

    fn cleanup_book(book_url: &str) {
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// 单键写只改目标键：Dart `ReadConfig` 未建模的键（`useGlobalAudioSkip` /
    /// `tocExpanded` / `manualReplaceRuleIds`）与其他键原样保留，进度列不受影响。
    ///
    /// 红→绿对照：旧路径 `update_book`（整书快照写）用 Dart 侧 `ReadConfig`
    /// JSON（不含未建模键）回写时，`useGlobalAudioSkip` 被 Rust 类型化默认值
    /// 覆盖为 false、`tocExpanded`/`manualReplaceRuleIds` 被直接丢弃；本用例
    /// 的断言在旧路径下失败（红），单键写后通过（绿）。
    #[test]
    fn test_update_read_config_field_preserves_unmodeled_keys() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-single-key.example.com/book/1";
        seed_read_config_raw(
            book_url,
            Some(
                r#"{"reverseToc":false,"reverseTocDisplay":false,"useGlobalAudioSkip":true,"tocExpanded":{"0":true},"manualReplaceRuleIds":[3,5]}"#,
            ),
        );
        with_database(|db| {
            BookRepository::new(db.connection()).update_progress(
                book_url,
                7,
                11,
                Some("第七章"),
                1_700_000_000_000,
            )?;
            Ok(())
        })
        .expect("进度写入失败");

        super::update_read_config_field(book_url, "reverseToc", "true").expect("单键写应成功");

        let cfg = raw_read_config(book_url);
        assert_eq!(cfg["reverseToc"], serde_json::json!(true), "目标键应被更新");
        assert_eq!(
            cfg["reverseTocDisplay"],
            serde_json::json!(false),
            "非目标键不得被改写"
        );
        assert_eq!(
            cfg["useGlobalAudioSkip"],
            serde_json::json!(true),
            "Dart 未建模的 useGlobalAudioSkip 必须原样保留"
        );
        assert_eq!(
            cfg["tocExpanded"],
            serde_json::json!({"0": true}),
            "未建模的对象键必须原样保留"
        );
        assert_eq!(
            cfg["manualReplaceRuleIds"],
            serde_json::json!([3, 5]),
            "未建模的数组键必须原样保留"
        );

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            let rc = saved.read_config.expect("readConfig 应保留");
            assert!(rc.reverse_toc, "单键写结果应对类型化模型可见");
            assert!(rc.use_global_audio_skip, "未建模键读出不应回退默认值");
            assert_eq!(saved.dur_chapter_index, 7, "进度列不得被触碰");
            assert_eq!(saved.dur_chapter_pos, 11, "进度列不得被触碰");
            Ok(())
        })
        .expect("类型化读回断言失败");

        cleanup_book(book_url);
    }

    /// JSON 值类型往返：bool / string / number / 对象 / 数组 均按 `valueJson` 原样落库
    #[test]
    fn test_update_read_config_field_json_value_types() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-value-types.example.com/book/1";
        seed_read_config_raw(book_url, Some(r#"{"reverseToc":true}"#));

        super::update_read_config_field(book_url, "flagKey", "false").expect("bool 写入失败");
        super::update_read_config_field(book_url, "stringKey", "\"你好, legado\"")
            .expect("string 写入失败");
        super::update_read_config_field(book_url, "numberKey", "3.5").expect("number 写入失败");
        super::update_read_config_field(book_url, "objectKey", r#"{"a":1,"b":["x"]}"#)
            .expect("对象写入失败");
        super::update_read_config_field(book_url, "arrayKey", r#"[1,"x",false]"#)
            .expect("数组写入失败");

        let cfg = raw_read_config(book_url);
        assert_eq!(cfg["flagKey"], serde_json::json!(false));
        assert_eq!(cfg["stringKey"], serde_json::json!("你好, legado"));
        assert_eq!(cfg["numberKey"], serde_json::json!(3.5));
        assert_eq!(cfg["objectKey"], serde_json::json!({"a": 1, "b": ["x"]}));
        assert_eq!(cfg["arrayKey"], serde_json::json!([1, "x", false]));
        assert_eq!(
            cfg["reverseToc"],
            serde_json::json!(true),
            "可选键写入不影响其他键"
        );

        cleanup_book(book_url);
    }

    /// 类型不符的值拒绝写入，DB 原键集不变且读取侧仍可解析（[批32b P2-3]）
    ///
    /// 红→绿：不校验时把 `reverseToc` 写成字符串 `"true"` 会落库，随后
    /// `find_by_url` 的整份 `ReadConfig` 反序列化失败 → `read_config = None`
    /// （`row_to_book` 静默 `None`），后续 updateBook 会把 NULL 写回、配置
    /// 永久丢失。校验后返回错误且 DB 保持原样。
    #[test]
    fn test_update_read_config_field_rejects_type_mismatch_and_keeps_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-type-mismatch.example.com/book/1";
        seed_read_config_raw(
            book_url,
            Some(r#"{"reverseToc":false,"useGlobalAudioSkip":true,"tocExpanded":{"0":true}}"#),
        );

        for (key, bad_value) in [
            ("reverseToc", "\"true\""),
            ("reverseTocDisplay", "1"),
            ("splitLongChapter", "\"yes\""),
            ("useReplaceRule", "[]"),
            ("playMode", "\"loud\""),
            ("pageAnim", "true"),
        ] {
            let err = super::update_read_config_field(book_url, key, bad_value).unwrap_err();
            assert!(
                err.to_string().contains("值类型不符"),
                "键 {key} 写入 {bad_value} 应报类型不符，实际：{err}"
            );
        }

        // DB 原键集与值保持不变（未留下任何半成品键）
        let cfg = raw_read_config(book_url);
        assert_eq!(cfg["reverseToc"], serde_json::json!(false));
        assert_eq!(cfg["useGlobalAudioSkip"], serde_json::json!(true));
        assert_eq!(cfg["tocExpanded"], serde_json::json!({"0": true}));

        // 读取侧仍可解析（未毒化）：类型化模型可见且未被默认值覆盖
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            let rc = saved.read_config.expect("readConfig 必须仍可解析");
            assert!(!rc.reverse_toc);
            assert!(rc.use_global_audio_skip);
            Ok(())
        })
        .expect("类型化读回断言失败");

        // 合法 bool 值照常写入
        super::update_read_config_field(book_url, "reverseToc", "true").expect("合法 bool 应写入");
        assert_eq!(
            raw_read_config(book_url)["reverseToc"],
            serde_json::json!(true)
        );

        cleanup_book(book_url);
    }

    /// 对照（红）：旧路径 `update_book` 整书快照写会丢弃 Dart 未建模键
    ///
    /// 与 `test_update_read_config_field_preserves_unmodeled_keys` 同一 DB 初态
    /// 下，用 **Dart `ReadConfig.toJson()` 形状**的 JSON（不含
    /// `useGlobalAudioSkip` / `tocExpanded` / `manualReplaceRuleIds`）整书回写：
    /// 未建模键被丢弃、`useGlobalAudioSkip` 被 Rust 类型化默认值 false 覆盖
    /// ——这就是批32 修复的真实缺陷路径，证明单键写用例的红→绿对照成立。
    #[test]
    fn test_update_book_whole_write_drops_unmodeled_read_config_keys() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-whole-write-control.example.com/book/1";
        seed_read_config_raw(
            book_url,
            Some(
                r#"{"reverseToc":false,"useGlobalAudioSkip":true,"tocExpanded":{"0":true},"manualReplaceRuleIds":[3,5]}"#,
            ),
        );

        // Dart ReadConfig.toJson() 形状：只含 Dart 建模字段（批32 前目录页
        // 每次切换都经 updateBook 发送该形状）
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "单键写测试书",
            "author": "",
            "origin": "https://batch32.example.com",
            "type": 0,
            "readConfig": {
                "reverseToc": true,
                "reverseTocDisplay": false,
                "useReplaceRule": true,
                "splitLongChapter": true,
                "delTag": 0,
                "reSegment": false,
                "readSimulating": false,
                "dailyChapters": 3,
                "openCredits": 0,
                "closeCredits": 0,
                "playMode": 0,
                "playSpeed": 1.0
            }
        })
        .to_string();
        super::update_book(&book_json).expect("update_book 应成功");

        let cfg = raw_read_config(book_url);
        assert_eq!(
            cfg["reverseToc"],
            serde_json::json!(true),
            "Dart 建模字段按快照写入（对照组前提）"
        );
        assert!(
            cfg.get("tocExpanded").is_none(),
            "整书快照写应丢弃未建模键 tocExpanded（红）"
        );
        assert!(
            cfg.get("manualReplaceRuleIds").is_none(),
            "整书快照写应丢弃未建模键 manualReplaceRuleIds（红）"
        );
        assert_eq!(
            cfg["useGlobalAudioSkip"],
            serde_json::json!(false),
            "未建模的 useGlobalAudioSkip 被类型化默认值覆盖（红）"
        );

        cleanup_book(book_url);
    }

    /// `readConfig` 为空（NULL）时新建对象并只写入目标键
    #[test]
    fn test_update_read_config_field_creates_config_when_empty() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-empty-config.example.com/book/1";
        seed_read_config_raw(book_url, None);

        super::update_read_config_field(book_url, "reverseTocDisplay", "true")
            .expect("空 readConfig 单键写应成功");

        let cfg = raw_read_config(book_url);
        assert_eq!(cfg, serde_json::json!({"reverseTocDisplay": true}));

        cleanup_book(book_url);
    }

    /// fail-closed：书籍不存在 / 键名为空白 / 值 JSON 非法 均报错
    #[test]
    fn test_update_read_config_field_rejects_missing_book_blank_key_and_bad_json() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch32-errors.example.com/book/1";
        seed_read_config_raw(book_url, Some(r#"{"reverseToc":false}"#));

        let err = super::update_read_config_field(
            "https://batch32-errors.example.com/book/missing",
            "reverseToc",
            "true",
        )
        .expect_err("书不存在必须报错");
        assert!(
            err.to_string().contains("书籍不存在"),
            "错误信息应指出书籍不存在，实际：{err}"
        );

        let err =
            super::update_read_config_field(book_url, "   ", "true").expect_err("空白键名必须报错");
        assert!(
            err.to_string().contains("键名不能为空"),
            "错误信息应指出键名为空，实际：{err}"
        );

        let err = super::update_read_config_field(book_url, "reverseToc", "not-json")
            .expect_err("非法 JSON 值必须报错");
        assert!(
            err.to_string().contains("JSON 解析失败"),
            "错误信息应指出 JSON 非法，实际：{err}"
        );

        // 失败调用不得留下半写状态
        let cfg = raw_read_config(book_url);
        assert_eq!(cfg, serde_json::json!({"reverseToc": false}));

        cleanup_book(book_url);
    }

    // ─── 批35：批量删除原文件 / 书籍级阅读记录开关 ──────────────────────

    /// 生成临时文件并返回其绝对路径（文件名带进程 id + 纳秒 + 原子序号）
    ///
    /// 原子序号是必需的：Windows `SystemTime::now()` 分辨率有限，同一测试内
    /// 连续两次调用可能拿到相同纳秒值，导致两次「造文件」命中同一路径/同一
    /// bookUrl（批35b 部分失败用例实测）。
    fn temp_book_file(ext: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "legado-batch35-{}-{unique}-{seq}.{ext}",
            std::process::id()
        ));
        std::fs::write(&path, b"batch35 fixture").expect("写临时书籍文件失败");
        path
    }

    /// 造一本测试书
    ///
    /// 书名带 bookUrl 后缀：`BookRepository::insert` 对「同名同作者」走
    /// URL 重映射（迁移章节后替换旧行），同名种子会让同用例的第二本书
    /// 顶掉第一本（批35b 部分失败用例实测 deleted 少 1）。
    fn seed_book(book_url: &str, origin: &str, book_type: i32) {
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&Book {
                book_url: book_url.to_string(),
                name: format!("批35测试书-{book_url}"),
                author: "作者".to_string(),
                origin: origin.to_string(),
                origin_name: "批35测试书.txt".to_string(),
                book_type,
                ..Book::default()
            })
        })
        .expect("批35测试书入库失败");
    }

    /// 本地书 + deleteOriginal=true：磁盘文件与书架记录一起删除
    #[test]
    fn test_delete_books_removes_local_file_and_record() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = temp_book_file("epub");
        let book_url = path.to_string_lossy().into_owned();
        seed_book(&book_url, book_type::LOCAL_TAG, book_type::LOCAL);

        let outcome =
            super::delete_books(std::slice::from_ref(&book_url), true).expect("批量删除应成功");
        assert!(
            outcome.warnings.is_empty(),
            "本地书文件正常删除不应有提示：{:?}",
            outcome.warnings
        );
        assert_eq!(outcome.deleted, 1, "应报告实际删除 1 本");
        assert_eq!(outcome.missing, 0);
        assert!(!path.exists(), "本地书原文件应被删除");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(repo.find_by_url(&book_url)?.is_none(), "书籍记录应被删除");
            Ok(())
        })
        .expect("DB 终态断言失败");
    }

    /// 非本地书：即使 deleteOriginal=true 也不删磁盘文件（只删记录）
    #[test]
    fn test_delete_books_keeps_non_local_file() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = temp_book_file("epub");
        let book_url = path.to_string_lossy().into_owned();
        seed_book(&book_url, "https://batch35.example.com", book_type::TEXT);

        let outcome =
            super::delete_books(std::slice::from_ref(&book_url), true).expect("批量删除应成功");
        assert!(outcome.warnings.is_empty());
        assert_eq!(outcome.deleted, 1);
        assert!(path.exists(), "非本地书不得删除磁盘文件");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(repo.find_by_url(&book_url)?.is_none());
            Ok(())
        })
        .expect("DB 终态断言失败");
        let _ = std::fs::remove_file(&path);
    }

    /// WebDAV 书：bookUrl 为本地缓存文件路径 → 删除缓存文件 + 记录
    ///
    /// WebDAV 书 origin 为 `webDav::`（bookType 无 local 位），仍属本地/远程
    /// 存储书；原文件即 `bookUrl` 指向的本机缓存（导入时落盘）。
    #[test]
    fn test_delete_books_removes_webdav_cached_file() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = temp_book_file("txt");
        let book_url = path.to_string_lossy().into_owned();
        seed_book(
            &book_url,
            "webDav::https://dav.example.com/books/x.txt",
            book_type::TEXT,
        );

        let outcome =
            super::delete_books(std::slice::from_ref(&book_url), true).expect("批量删除应成功");
        assert!(
            outcome.warnings.is_empty(),
            "WebDAV 缓存文件正常删除不应有提示：{:?}",
            outcome.warnings
        );
        assert_eq!(outcome.deleted, 1);
        assert!(!path.exists(), "WebDAV 书的本机缓存文件应被删除");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(repo.find_by_url(&book_url)?.is_none(), "书籍记录应被删除");
            Ok(())
        })
        .expect("DB 终态断言失败");
    }

    /// 路径安全：bookUrl 带 URL scheme → 不删任何文件、返回提示，记录照删
    #[test]
    fn test_delete_books_rejects_url_scheme_but_deletes_record() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch35-scheme.example.com/books/x.epub";
        seed_book(book_url, book_type::LOCAL_TAG, book_type::LOCAL);

        let outcome = super::delete_books(&[book_url.to_string()], true).expect("批量删除应成功");
        assert_eq!(
            outcome.warnings.len(),
            1,
            "应返回一条文件删除提示：{:?}",
            outcome.warnings
        );
        assert!(
            outcome.warnings[0].contains("不是本地路径"),
            "提示应说明 URL 非本地路径被跳过，实际：{}",
            outcome.warnings[0]
        );
        assert_eq!(outcome.deleted, 1, "文件被拒绝不得影响记录删除计数");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(
                repo.find_by_url(book_url)?.is_none(),
                "文件删除被拒绝不得阻断记录删除"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");
    }

    /// 路径安全：扩展名不在白名单 → 不删文件、返回提示，但记录照删
    #[test]
    fn test_delete_books_rejects_unlisted_extension_but_deletes_record() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = temp_book_file("db");
        let book_url = path.to_string_lossy().into_owned();
        seed_book(&book_url, book_type::LOCAL_TAG, book_type::LOCAL);

        let outcome =
            super::delete_books(std::slice::from_ref(&book_url), true).expect("批量删除应成功");
        assert_eq!(
            outcome.warnings.len(),
            1,
            "应返回一条文件删除提示：{:?}",
            outcome.warnings
        );
        assert!(
            outcome.warnings[0].contains("白名单"),
            "提示应说明白名单拒绝，实际：{}",
            outcome.warnings[0]
        );
        assert!(path.exists(), "白名单外文件不得被删除");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(
                repo.find_by_url(&book_url)?.is_none(),
                "文件删除失败不得阻断记录删除"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");
        let _ = std::fs::remove_file(&path);
    }

    /// 文件已不存在：返回提示（含书名），记录照删
    #[test]
    fn test_delete_books_missing_file_yields_warning() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = std::env::temp_dir()
            .join(format!(
                "legado-batch35-missing-{}.epub",
                std::process::id()
            ))
            .to_string_lossy()
            .into_owned();
        let _ = std::fs::remove_file(&book_url);
        seed_book(&book_url, book_type::LOCAL_TAG, book_type::LOCAL);

        let outcome =
            super::delete_books(std::slice::from_ref(&book_url), true).expect("批量删除应成功");
        assert_eq!(outcome.warnings.len(), 1);
        assert!(
            outcome.warnings[0].contains("原文件不存在"),
            "提示应说明文件不存在，实际：{}",
            outcome.warnings[0]
        );
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(repo.find_by_url(&book_url)?.is_none());
            Ok(())
        })
        .expect("DB 终态断言失败");
    }

    // ─── 批35b P2-1：删除源文件的信任边界 ────────────────────────────

    /// 生成唯一临时路径（不创建文件/目录；带进程 id + 纳秒 + 原子序号）
    fn temp_unique_path(ext: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "legado-batch35b-{}-{unique}-{seq}.{ext}",
            std::process::id()
        ))
    }

    /// 尽力创建文件符号链接；平台不允许（Windows 无开发者模式/权限）时返回 false
    fn try_symlink_file(target: &Path, link: &Path) -> bool {
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(target, link).is_ok()
        }
        #[cfg(windows)]
        {
            std::os::windows::fs::symlink_file(target, link).is_ok()
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (target, link);
            false
        }
    }

    fn local_book(book_url: &str) -> Book {
        Book {
            book_url: book_url.to_string(),
            name: "批35b边界书".to_string(),
            origin: book_type::LOCAL_TAG.to_string(),
            book_type: book_type::LOCAL,
            ..Book::default()
        }
    }

    /// [批35b P2-1] 相对标识含 `..`：无论 canonical 后是否落在 Documents 内
    /// 一律拒绝，文件保留、记录照删。
    ///
    /// 红→绿：旧实现直接 `canonicalize`，`books/../<file>` 归一后落在
    /// Documents 根内，会被当作合法本地书删除（文件消失）。
    #[test]
    fn test_delete_books_rejects_parent_dir_escape_keeps_file() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = temp_book_file("txt");
        let file_name = path.file_name().unwrap().to_string_lossy().into_owned();
        // 构造「看似在 Documents/books 下、实际用 .. 逃逸」的相对标识
        let book_url = format!("books/../{file_name}");
        seed_book(&book_url, book_type::LOCAL_TAG, book_type::LOCAL);

        let outcome =
            super::delete_books(std::slice::from_ref(&book_url), true).expect("批量删除应成功");
        assert_eq!(outcome.warnings.len(), 1, "{:?}", outcome.warnings);
        assert!(
            outcome.warnings[0].contains("上级目录"),
            "提示应说明 .. 越界被拒绝，实际：{}",
            outcome.warnings[0]
        );
        assert!(path.exists(), "含 .. 的相对标识不得删除任何文件");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(
                repo.find_by_url(&book_url)?.is_none(),
                "文件被拒绝不得阻断记录删除"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");
        let _ = std::fs::remove_file(&path);
    }

    /// [批35b P2-1] 绝对路径在信任根之外：拒绝删除、文件保留。
    ///
    /// 用显式根模拟「应用 Documents 子目录」，目标文件在根外（系统 temp
    /// 根内），验证 canonical 后的根包含检查生效。
    #[test]
    fn test_delete_books_rejects_absolute_path_outside_roots() {
        let _db_guard = crate::db_state::ensure_test_db();
        let path = temp_book_file("epub");
        let docs_root = temp_unique_path("rootdir");
        std::fs::create_dir_all(&docs_root).expect("创建模拟 Documents 根失败");
        let roots = vec![docs_root.clone()];

        let book = local_book(&path.to_string_lossy());
        let err = super::delete_local_book_file(&book, &roots).expect_err("根外绝对路径必须被拒绝");
        assert!(
            err.contains("不在应用 Documents/Cache 目录内"),
            "提示应说明根外拒绝，实际：{err}"
        );
        assert!(path.exists(), "根外绝对路径不得删除文件");

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir_all(&docs_root);
    }

    /// [批35b P2-1] 符号链接：删除前拒绝（canonical 会跟随链接删目标）。
    ///
    /// Windows 无 symlink 权限时跳过（不影响其他平台的红→绿证据）。
    #[test]
    fn test_delete_books_rejects_symlink() {
        let _db_guard = crate::db_state::ensure_test_db();
        let target = temp_book_file("txt");
        let link = temp_unique_path("txt");
        if !try_symlink_file(&target, &link) {
            eprintln!("跳过符号链接用例：当前环境不允许创建符号链接");
            let _ = std::fs::remove_file(&target);
            return;
        }
        seed_book(
            &link.to_string_lossy(),
            book_type::LOCAL_TAG,
            book_type::LOCAL,
        );

        let outcome = super::delete_books(&[link.to_string_lossy().into_owned()], true)
            .expect("批量删除应成功");
        assert_eq!(outcome.warnings.len(), 1, "{:?}", outcome.warnings);
        assert!(
            outcome.warnings[0].contains("符号链接"),
            "提示应说明符号链接被拒绝，实际：{}",
            outcome.warnings[0]
        );
        assert!(link.exists(), "符号链接本身不得被删除");
        assert!(target.exists(), "符号链接目标文件不得被删除");

        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_file(&target);
    }

    /// [批35b P3-7] 目录：扩展名伪装成白名单也不删（非普通文件拒绝）
    #[test]
    fn test_delete_books_rejects_directory() {
        let _db_guard = crate::db_state::ensure_test_db();
        let dir = temp_unique_path("epub");
        std::fs::create_dir_all(&dir).expect("创建目录夹具失败");
        let book_url = dir.to_string_lossy().into_owned();
        seed_book(&book_url, book_type::LOCAL_TAG, book_type::LOCAL);

        let outcome = super::delete_books(&[book_url], true).expect("批量删除应成功");
        assert_eq!(outcome.warnings.len(), 1, "{:?}", outcome.warnings);
        assert!(
            outcome.warnings[0].contains("不是普通文件"),
            "提示应说明非普通文件被拒绝，实际：{}",
            outcome.warnings[0]
        );
        assert!(dir.is_dir(), "目录不得被删除");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// [批35b P3-7] 设备文件：即便在信任根内也按「非普通文件」拒绝
    ///
    /// 仅 Unix 有稳定的字符设备路径（`/dev/null`）；Windows 设备名语义
    /// 不同，由目录用例覆盖文件类型检查。
    #[cfg(unix)]
    #[test]
    fn test_validate_local_file_path_rejects_device_file() {
        let roots = vec![std::path::PathBuf::from("/")];
        let err =
            super::validate_local_file_path("/dev/null", &roots).expect_err("设备文件必须被拒绝");
        assert!(
            err.contains("不是普通文件"),
            "提示应说明非普通文件，实际：{err}"
        );
    }

    /// [批35b P3-2/P3-7] 批量部分失败：好文件删除、坏文件保留并提示、
    /// 已不在库的 URL 计入 missing，记录全部删除且计数准确。
    #[test]
    fn test_delete_books_partial_failure_reports_counts() {
        let _db_guard = crate::db_state::ensure_test_db();
        let good = temp_book_file("epub");
        let bad = temp_book_file("db"); // 白名单外
        let missing_url = "https://batch35b-not-on-shelf.example.com/book/1";
        let good_url = good.to_string_lossy().into_owned();
        let bad_url = bad.to_string_lossy().into_owned();
        seed_book(&good_url, book_type::LOCAL_TAG, book_type::LOCAL);
        seed_book(&bad_url, book_type::LOCAL_TAG, book_type::LOCAL);
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete_by_url(missing_url);
            Ok(())
        })
        .ok();

        let outcome = super::delete_books(
            &[good_url.clone(), bad_url.clone(), missing_url.into()],
            true,
        )
        .expect("批量删除应成功");
        assert_eq!(outcome.deleted, 2, "两条在库记录应删除");
        assert_eq!(outcome.missing, 1, "不在库的 URL 应计入 missing");
        assert_eq!(outcome.warnings.len(), 1, "{:?}", outcome.warnings);
        assert!(!good.exists(), "合法文件应删除");
        assert!(bad.exists(), "白名单外文件应保留");
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            assert!(repo.find_by_url(&good_url)?.is_none());
            assert!(repo.find_by_url(&bad_url)?.is_none());
            Ok(())
        })
        .expect("DB 终态断言失败");
        let _ = std::fs::remove_file(&bad);
    }

    /// [批35b P2-2] 整书全行写缺 `disableReadRecord` 键：保留库内 true。
    ///
    /// 红→绿：旧实现 serde 默认补 `false`，整书 UPDATE 把开关打回假。
    /// add_book（重复加入书架）与 update_book 两条写路径都必须保留。
    #[test]
    fn test_update_and_add_book_preserve_disable_read_record_when_key_missing() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch35b-read-record-merge.example.com/book/1";
        seed_book(book_url, "https://batch35b.example.com", book_type::TEXT);
        super::set_read_record_disabled(book_url, true).expect("开关置真失败");

        // update_book：缺键载荷（Dart/Web 客户端未携带该键）
        let upd_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "改名",
            "author": "作者",
            "type": 8
        })
        .to_string();
        super::update_book(&upd_json).expect("update_book 应成功");
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍应仍存在");
            assert_eq!(saved.name, "改名", "其他字段应正常更新");
            assert!(
                saved.disable_read_record,
                "缺键整书写不得把库内 true 覆盖为 false"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        // add_book：重复加入书架（同样缺键）也不得回退开关
        let add_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "改名2",
            "origin": "https://batch35b.example.com",
            "type": 8
        })
        .to_string();
        super::add_book(&add_json).expect("add_book 应成功");
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍应仍存在");
            assert!(saved.disable_read_record, "重复加入书架不得回退开关");
            Ok(())
        })
        .expect("DB 终态断言失败");

        // 显式携带 false：用户主动开启阅读记录，按入参落库
        let explicit_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "改名2",
            "type": 8,
            "disableReadRecord": false
        })
        .to_string();
        super::update_book(&explicit_json).expect("显式 false 应成功");
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍应仍存在");
            assert!(!saved.disable_read_record, "显式携带的 false 应按入参落库");
            Ok(())
        })
        .expect("DB 终态断言失败");

        cleanup_book(book_url);
    }

    /// 单列写：只改 disableReadRecord，不覆盖阅读进度；书籍不存在报错
    #[test]
    fn test_set_read_record_disabled_single_column() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch35-read-record-disabled.example.com/book/1";
        seed_book(book_url, "https://batch35.example.com", book_type::TEXT);
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.update_progress(book_url, 7, 11, Some("第七章"), 1_700_000_000_000)
        })
        .expect("进度写入失败");

        let updated = super::set_read_record_disabled(book_url, true).expect("开关写入应成功");
        assert!(updated.disable_read_record, "返回值应携带新开关态");
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍应仍存在");
            assert!(saved.disable_read_record);
            assert_eq!(saved.dur_chapter_index, 7, "进度列不得被单列写覆盖");
            assert_eq!(saved.dur_chapter_pos, 11);
            Ok(())
        })
        .expect("DB 终态断言失败");

        let updated = super::set_read_record_disabled(book_url, false).expect("关闭应成功");
        assert!(!updated.disable_read_record);

        let err = super::set_read_record_disabled(
            "https://batch35-read-record-disabled.example.com/book/missing",
            true,
        )
        .expect_err("书籍不存在必须报错");
        assert!(
            err.to_string().contains("书籍不存在"),
            "错误信息应指出书籍不存在，实际：{err}"
        );

        cleanup_book(book_url);
    }
}
