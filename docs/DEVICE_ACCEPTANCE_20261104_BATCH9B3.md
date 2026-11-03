# 批 9b-3「漫画图片保留数」设备验收报告

> 范围：版本 **2.0.445+446**（HEAD `ec0a146d09`）的漫画图片缓存保留能力：
> `imageRetainNum=0` 不清理；`N>0` 时保留窗口 `[dur-N, dur+preDownload]` 章节图片、
> 删除本书 `images/` 下窗口外文件；翻章窗口移动；重启设置保持；复合 URL /
> 卷章 / 缺正文不误删当前章；本地 cbz 不触发清理；FATAL=0。
> 核心实现：`rust/legado-ffi/src/api/image_cache_api.rs`
>（`retain_comic_images` / `retained_names_for_window` / `delete_unreferenced_images`）、
> `flutter_legado/lib/src/screens/reader_comic/manga_image_retention.dart`、
> `flutter_legado/lib/src/screens/reader_comic_screen.dart`。
>
> 设备：MuMu index 1「Test测试」（adb `192.168.100.62:5555`），
> Android 15 / x86_64；版本 2.0.445+446；APK sha256 `690767f1…`，
> x86_64 `.so` sha256 `5c29e4dd…`（release/quickjs=true，22:34:50）。
>
> **结论：C1~C5 全部 PASS（文件级清理行为均实测），FATAL/ANR/overflow=0。**
> 阅读器画面显示「图片加载失败」属夹具图片/缓存键限制（见 §4），不影响
> `retain_comic_images` 的文件增删断言；真实媒体加载未作为本批验收项。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu index 1「Test测试」） |
| 设备型号 / 系统 / ABI | SM-G9900（伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1920×1200 / 240（1280×800dp）；结束 reset 回 1080×1920 / 480 |
| 应用包名 / Activity | `io.legado.flutter_legado` / `io.legado.flutter.MainActivity` |
| 验收版本 | versionName **2.0.445** / versionCode **446** |
| APK | 200,697,868 B；sha256 **`690767f10584c978e07bce56cc44f7ff72376784828b8fe5c255113eab80e630`**；安装 Success，设备 base.apk 同哈希 |
| Rust x86_64 | 51,938,080 B；sha256 **`5c29e4dd963272bbe3355688c67adeb9e414cc33c155ba3b81a9d2a22982b68c`**；`quickjs=true`、`contentHash=51404204`、`rustFingerprint=e494bfeb…`；`build-android.ps1 -Mode release` EXIT=0 |
| 门禁 | `flutter analyze` 0；`flutter test` **4129 passed + 1 skipped**；`cargo test -p legado-ffi --test retain_comic_images --features quickjs` **8/8**；`cargo test -p legado-ffi --lib --features quickjs image_cache` **31 passed** |
| 验收时间 | 2026-11-03 22:56 ~ 23:09（宿主） |
| 证据目录 | `tmp_debug/device_acceptance_20261104/`；截图 `docs/materials_1109b/9b3_*.png` |

### 1.1 夹具构造方法（可复现）

1. **图片书（在线）**：DB 插入 `books.bookUrl=http://192.168.100.52:8899/comic/qa9b3`、`type=64`（IMAGE 位）、`durChapterIndex=5`、18 章；`chapters` 0~17 章，`url=http://192.168.100.52:8899/comic/chN.html`；`cached_chapters` 只写入窗口章 3~15 正文
   `<img src="http://192.168.100.52:8899/comic/imgN.png">`。
2. **图片缓存目录**：Dart 启动注入 `/data/user/0/io.legado.flutter_legado/cache/image_cache`；按 Rust `book_dir_name` 规则生成书目录
   `http___192.168.100.52_8899_comic_qa9b3_9f9d0124/images`；文件名按 `md5(url)[8:24].suffix` 生成 18 个 `imgN.png`，另放 `deadbeefdeadbeef.png`、`ffffffffffffffff.png`、`notimage.png`、`nested/` 子目录、`symlink.png`（指向 img0）。
3. **复合 URL 书**：`books.bookUrl=http://192.168.100.52:8899/comic/qa9b3c`、`durChapterIndex=1`、5 章；章节 0/1 正文 `<img src='…/cc0.png,{"headers":{"Referer":"http://x"}}'>`（单引号外壳、JSON 双引号），章节 3 普通 `<img src="…/cc3.png">`；章节 2 为卷章（`isVolume=1`、无正文）；章节 4 无缓存正文（前窗缺正文）。图片目录预置 7 个文件：复合 URL 全串名（`.jpg`，后缀规则回退）、截断 URL 名（`.png`）、错误后缀名、普通图、窗口外图。
4. **本地 cbz**：用 Python zip 生成 2 页 `page1.png/page2.png` 的 `qa9b3_local.cbz`，推 `/sdcard/Download`，经应用「添加本地 → 文件选择器」导入；生成书籍 `qa9b3_local`（`bookType=4160`、`loc_book`、1 章、2 页）。另在 `image_cache/<bookDir>/images` 预置 `keep.png`、`outside.png` 作为「若清理发生必被删」的探针。
5. 所有夹具文件 `chown 10066:10066`（app uid）；DB 写入前后 `PRAGMA wal_checkpoint` 并归还 DB 属主；验收后删除全部夹具并清空书架。

> 说明：图片 1×1 PNG 仅用于「保留/删除」文件级断言；阅读器 UI 仍显示「图片加载失败」（缓存键/图片解码未命中），不作为本批通过条件。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 默认 0：读漫画 → `images/` 不清理（记录文件数） | **PASS** | `9b3_c01_comic_open_default0.png`；`data/c1_images_before.txt`、`data/c1_images_after.txt`（23 entries → 23 entries） |
| 2 | 设 N=2：窗口 `[dur-2, dur+preDownload]` 内保留、窗口外删除；翻章窗口移动 | **PASS** | `9b3_c02_comic_retain2.png`、`9b3_c03_comic_prev_ch4.png`；`data/c2_images_after.txt`（dur=5：保留 img3~15，删 img0/1/2/16/17+杂项）、`data/c2b_images_after_prev.txt`（dur=4：保留 img2~14，删 0/1/15/16/17） |
| 3 | 关闭阅读器/重启后设置保持；0=不清理 | **PASS** | `9b3_c04_restart.png`、`9b3_c05h_setting_persist2.png`（「保留已读章节数量 2」）、prefs `flutter.imageRetainNum=2`；`9b3_c07_comic_retain0.png` + `data/c3_images_after0.txt`（0 时 22 entries 不变） |
| 4 | 复合 URL / 卷章 / 缺正文：不误删当前章 | **PASS** | `9b3_c09_composite_reader.png`；`data/c4_images_after.txt`（7 文件 → 3 文件：full0/full1/plain3 保留；trunc0/trunc1/mismatch/outside 删除） |
| 5 | 本地 cbz 不触发清理；FATAL=0 | **PASS** | `9b3_c20_imported_cbz_reader.png`（`qa9b3_local 页数1/2 章节1/1`）；cbz 图片缓存 2 文件不变；`logcat/session_app.log` FATAL/ANR/overflow/E-flutter=0 |

## 三、逐场景证据

### 3.1 C1 默认 0 不清理（PASS）

- 打开漫画前：`images/` 目录 **23 entries** = 21 个常规文件（18 个 `imgN.png` + `deadbeef…png` + `ffffffff…png` + `notimage.png`）+ `nested/` + `symlink.png`（`data/c1_images_before.txt`）。
- `imageRetainNum` 未设置（默认 0）；点书架 `QA9B3_COMIC`（`dur=5`）进入漫画阅读器（`b2c` 同批 `c01` 截图；`9b3_c01_comic_open_default0.png`，标题「第6章 章节6/18」）。
- 等待 3s 后目录仍 **23 entries**，无删除（`data/c1_images_after.txt`）。
- 结论：`retain<=0` 直接返回，未调用删除（Rust `retain_comic_images_inner` 首行守卫）。

### 3.2 C2 N=2 窗口保留/删除与翻章（PASS）

**dur=5（第6章）**：窗口 `[5-2, 5+10] = [3,15]`。
- 进入阅读器触发 `MangaImageRetention.onChapterOpened(bookUrl, 5)` → `retain_comic_images`；
- 结果：**15 entries** = 13 个常规文件 + `nested/` + `symlink.png`；保留 img3~img15（13 张）；删除 img0/1/2、img16/17、`deadbeef…`、`ffffffff…`、`notimage.png`（共 8 个常规文件）。
- 证据：`9b3_c02_comic_retain2.png`、`data/c2_images_after.txt`。（`ls -la` 中 symlink 行显示目标名，解析时已排除；普通文件 13 个，索引 3~15。）

**翻章到 dur=4（第5章）**：为使后窗完整，验收时补写 `cached_chapters[2]` 并重置图片目录为 23 entries，再点「上一章」。
- 窗口 `[2,14]`；结果保留 img2~img14（13 个普通文件），删除 img0/1/15/16/17 及杂项（`data/c2b_images_after_prev.txt`）。
- 证据：`9b3_c03_comic_prev_ch4.png`（标题「第5章 章节5/18」）；解析 kept=[2..14]、deleted=[0,1,15,16,17]。
- 说明：窗口外已删除的图片不会因窗口回移恢复；保留集合只决定「不删除」，不负责重建缓存。

### 3.3 C3 重启保持与 0=不清理（PASS）

| 子项 | 实际 / 证据 |
|---|---|
| 关闭阅读器/重启 | `am force-stop` + 启动；prefs `flutter.imageRetainNum=2` 保留；设置页「漫画保留数量 / 保留已读章节数量 2」（`9b3_c04_restart.png`、`9b3_c05h_setting_persist2.png`、`data/c05h_setting_persist2.xml`） |
| 设为 0 | 设置页对话框输入 0 → 副题「不清理已缓存图片（0=不清理）」，prefs `imageRetainNum=0`（`data/c06_set0.xml`） |
| 0 打开漫画 | 重置 `images/` 为 22 entries（21 常规 + nested；本次重置未重建 symlink）；打开漫画（dur=4）后仍 **22 entries / 21 常规**，无删除（`9b3_c07_comic_retain0.png`、`data/c3_images_after0.txt`） |

### 3.4 C4 复合 URL / 卷章 / 缺正文（PASS）

书 `QA9B3_COMPOSITE`：`dur=1`，5 章，窗口 `[0,11]`。章节 0/1 复合 URL、章节 2 卷章（无正文）、章节 3 普通图、章节 4 缺正文（前窗）。

初始 7 个文件：
- `425a06f4f803fa48.jpg` = 复合 full0（含 `,{json}`）的 md5_16 + `.jpg`（后缀规则回退）；
- `30f7b0cc1e84270c.jpg` = 复合 full1；
- `9ab189680bea0015.png` = 普通 cc3.png；
- `4a18ee285d000253.png` / `36d96926678956e3.png` = 截断 URL（去掉 `,{json}`）的错误命名；
- `425a06f4f803fa48.png` = 同 md5 但后缀错误的探针；
- `outside.png` = 无引用窗口外探针。

打开阅读器（第2章）后目录 **仅 3 个文件**：`425a06f4f803fa48.jpg`、`30f7b0cc1e84270c.jpg`、`9ab189680bea0015.png`（`data/c4_images_after.txt`）。
- 当前章（index 1）复合 URL 的完整尾被保留，未被截断命名误删；
- 后窗 index 0 复合 URL 保留；
- 卷章 index 2 无正文被跳过，不阻塞清理；
- 前窗 index 4 缺正文被跳过（仅跳过该章），窗口其余照常清理；
- 截断/错误后缀/窗口外探针全部删除。
- 证据：`9b3_c09_composite_reader.png`（「第2章 章节2/5」）；Rust 定向测试 `retain_comic_images` 8/8 + `image_cache` 单测 31 passed 交叉佐证。

### 3.5 C5 本地 cbz 不触发清理（PASS）

- 通过应用「更多 → 添加本地」从 `/sdcard/Download/qa9b3_local.cbz` 导入，生成书籍 `qa9b3_local`（`bookType=4160=LOCAL|IMAGE_BIT`、`origin=loc_book`、1 章）；打开后 `第1章 页数1/2 章节1/1`（`9b3_c20_imported_cbz_reader.png`），证明本地 cbz 正常进漫画阅读器。
- 预先在该书 `image_cache/<bookDir>/images` 放 `keep.png`、`outside.png`（`imageRetainNum=2` 时若清理发生，`outside.png` 必被删）。
- 打开 cbz 后 `ls -la` 仍仅 `keep.png`、`outside.png` 两项（终端实测输出；该导入 cbz 的临时缓存目录在验收清理时已删除，未单独落盘；同型探针的落盘快照见 `data/c5_images_after.txt`，对应手工种子 cbz 路径），无删除。
- 代码路径：`reader_comic_screen.dart:1709` `if (book == null || BookType.isLocalBook(book)) return;`；本地书不进入 `MangaImageRetention`，故不调用 `retain_comic_images`。
- 备注：另建的「手工种子 cbz」因章节语义不完整曾报 `书源不存在: loc_book`，不作为结论；结论以 UI 正式导入的 `qa9b3_local` 为准。

### 3.6 稳定性

- `logcat/session_app.log`（6454 行）：`FATAL EXCEPTION`=0、`ANR in io.legado.flutter_legado`=0、`overflowed by`=0、`E/flutter`=0。
- 首次漫画加载时（23:00:55）夹具未提供 `/comic/imgN.png`，图片 404 被应用记录为
  `HttpException: Invalid statusCode: 404, uri = http://192.168.100.52:8899/comic/img4.png`
  （`9b3_c04_restart.png` 可见崩溃提示）；补齐静态图后未再新增该记录。**此为夹具环境问题，不计入产品缺陷**；A 批发现页 P1 的 `Bad state: Too many elements` 另见 2b-2c 报告。

## 四、问题与观察清单

| 编号 | 级别 | 描述 | 影响 / 建议 |
|---|---|---|---|
| 9B3-O1 | P3（夹具） | 1×1 PNG 缓存文件 + 缓存键/网络未命中，阅读器显示「图片加载失败」 | 只影响画面显示，不影响文件级保留/删除；真实漫画图片加载未在本批断言 |
| 9B3-O2 | P3（夹具） | 首次漫画夹具未提供 `/comic/imgN.png`（404），应用记录一次 `HttpException` 崩溃日志 | 补齐静态图后复测无新增；建议正式源图片 404 也按可恢复错误处理（非本批范围） |
| 9B3-O3 | P2（既有构建） | armeabi-v7a `.so` `quickjs=false`（`rar` 0.4.0 32 位编译失败回退） | x86_64 设备不受影响；32 位 JS 能力待依赖修复（同 2b-2c P2-O1） |

**未覆盖 / 声明**：
- 真实在线漫画源图片下载成功后再清理的完整链路（本批用预置缓存文件直接验证文件级规则）。
- 本地 cbz 的「图片缓存目录」清理语义：本地书代码直接跳过，未进入 Rust；已用正式 UI 导入的 cbz 验证目录不变。
- 并发清理/预载竞态（Rust 已登记「不加去抖」）；本批未构造并发翻章压力。
- 复合 URL 含字面 `>`、协议相对 URL/端口差异等极端解析差异未在设备构造，Rust 单测/审查已登记。

## 五、证据与产物索引

| 类别 | 路径 |
|---|---|
| 构建/安装 | `tmp_debug/device_acceptance_20261104/logcat/rust_build.log`、`build_release.log`、`install.log`；`data/so_evidence.txt`、`apk_sha256.txt`、`version_installed.txt` |
| 夹具生成脚本 | `tmp_debug/device_acceptance_20261104/scripts/make_fixture.py`、`make_composite.py`；`fixture_payload/seed*.sql`、`meta*.json` |
| 目录快照 | `tmp_debug/device_acceptance_20261104/data/c1_images_before.txt`、`c1_images_after.txt`、`c2_images_after.txt`、`c2b_images_after_prev.txt`、`c3_images_after0.txt`、`c4_images_after.txt`、`c5_images_after.txt` |
| 语义树 | `tmp_debug/device_acceptance_20261104/data/c01_*.xml`、`c02_*.xml`、`c03_*.xml`、`c05h_*.xml`、`c07_*.xml`、`c09_*.xml`、`c20_*.xml` |
| 截图 | `docs/materials_1109b/9b3_*.png`（`c00`~`c20`） |
| 会话日志 | `tmp_debug/device_acceptance_20261104/logcat/session_app.log`（FATAL/ANR/overflow/E-flutter=0） |
| Rust 测试 | `rust/legado-ffi/tests/retain_comic_images.rs`（8/8）；`legado-ffi` image_cache 单测 31 passed |

---

编写：QA（设备验收子代理） · 2026-11-03
