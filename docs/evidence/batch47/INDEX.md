# 批47 证据索引（HLS 音频真机验证）

日期：2026-11-18
设备：MuMu 实例 0「Test2」，`192.168.100.63:5555`（guest 直连，Android 15 / SM-G9900 / x86_64）
宿主：`192.168.100.52`（与 guest 同网段，mock 服务端口 8099）
HEAD：`a08fea555f`（含批 0「播放链读缓存」）
版本：`2.0.510+511`
APK：`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`
sha256：`af2a5c6a0d48c95a519d07e416ffec3909ac403b2a7604d92853ad4abc674ad3`（218,295,472 字节）

## 文件清单

### 构建与冒烟
| 文件 | 内容 |
|---|---|
| `build_release_3abi.log` | 三 ABI release 重建全日志（Rust 指纹 0288169c…、FRB hash 780472602、三 ABI 校验 OK） |
| `apk_sha256.txt` | release APK sha256 |
| `smoke_debug_checkui.log` | debug 包冒烟（`-CheckUI`），8 PASS / 0 FAIL |

### 批 1：HLS 播放
| 文件 | 内容 |
|---|---|
| `mock_requests.jsonl` | 首次 HLS 测试请求日志（含 mock 路径 bug 导致的 404 阶段） |
| `mock_requests_batch0.jsonl` | 修正后完整请求时间线（MP3 / HLS-query / HLS-noext / gated） |
| `logcat_exo_full.txt` | ExoPlayer Init/Release、`UnrecognizedInputFormatException` 原始堆栈 |
| `logcat_exo_summary.txt` | ExoPlayer/HLS 相关日志摘要 |
| `audioflinger_live_hls.txt` | 播放中 AudioFlinger dump（活跃轨道 66：Active=yes、FrmCnt=FrmRdy=11328、输出 SPEAKER） |
| `audioflinger_history.txt` | AudioFlinger 全量历史（含 AT::add / AT::remove） |
| `audioflinger_track_events.txt` | AT::add / AT::remove 事件表（轨道生命周期） |

### 缺口 B：headers
| 文件 | 内容 |
|---|---|
| `mock_requests_gate_referer.jsonl` | Referer 门禁日志（`gated_denied`，referer=null） |
| `mock_requests_gate_ua.jsonl` | UA 门禁日志（`gated_denied`，ua=ExoPlayer） |

### UI 证据
| 文件 | 内容 |
|---|---|
| `shot_audio_page.png` | 听书页（4 章列表） |
| `qa47_ui_home.xml` | 书架（QA47 听书测试书 已出现） |
| `qa47_ui_book2.xml` | 听书页 UI 树（首章 1/4） |
| `qa47_playing_mp3.xml` | MP3 播放中，已自动推进至 2/4 |
| `qa47_hls_progress_1..3.xml` | HLS 第 2 章播完推进到 3/4（75%） |
| `qa47_after_noext_error.xml` | 无扩展名失败后 UI 卡在 3/4（75%） |
| `qa47_menu.xml` | 溢出菜单（缓存章节范围入口） |
| `qa47_cache_range_dialog.xml` / `qa47_cache_range_set.xml` | 缓存范围对话框（默认 4→4，改为 1→1） |

### 夹具与工具（可复现）
| 文件 | 内容 |
|---|---|
| `mock_media/ch_plain.mp3` | ffmpeg 生成 12s 440Hz MP3（96,592 字节） |
| `mock_media/hls/playlist.m3u8` + `seg_000..003.ts` | ffmpeg 生成 HLS（4s×3 + 0.02s，AAC 64k） |
| `mock_media/hls_gated/` | 同内容，用于 Referer/UA 门禁变体 |
| `mockserver/mock_audio_server.py` | mock 音频/书源服务器（`--gate none|referer|ua`） |
| `mockserver/inject_mock_db.py` | 设备 DB 注入/清理脚本（`--clean`） |
| `mockserver/_inject.sql` / `_clean.sql` | 实际执行的 SQL |

## 关键时间线（mock_requests_batch0.jsonl，宿主本地时间）

- `01:53:21` MP3 预下载完成（`/media/plain.mp3`，UA=Mozilla/5.0 即 Rust 抓取链）
- `01:54:41` 断网后播放缓存章：**该窗口内 mock 服务零请求**
- `01:55:18` HLS 第 2 章：m3u8 + 4 段 ts 全部拉取
- `01:55:30` 第 3 章 `hlsnoext`：仅 1 次请求后失败
- 每章音频轨生命周期稳定为 **12.12–12.21s**（等于夹具时长 12s）

## 清理状态

- mock 书源 / 书籍 / 章节已从设备 DB 删除（`books like 'QA47%'` = 0，`bookSourceGroup='QA47'` = 0）
- mock 服务器进程已停止
- 设备网络已恢复（wlan0 `192.168.100.63/24`，`wifi_on=1`，`mobile_data=1`）
- 应用未卸载（`io.legado.flutter_legado` 保留，当前为 debug 变体）
- 仓库代码零改动（`git status` 仅新增 `docs/evidence/batch47/`）
